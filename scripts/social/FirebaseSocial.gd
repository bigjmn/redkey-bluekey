extends Node
## FirebaseSocial — autoload coordinator for the social layer.
##
## Owns: persisted anonymous Firebase auth (sign-up, token storage, refresh),
## the cached profile/friends/challenges state, and the orchestration between
## the UI screens and SocialApiClient. UI screens call the methods below and
## listen to the signals; they never touch tokens or HTTP directly.
##
## Auth flow (Firebase REST):
##   sign-up:  POST https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=API_KEY
##             body {"returnSecureToken": true}            -> localId/idToken/refreshToken/expiresIn
##   refresh:  POST https://securetoken.googleapis.com/v1/token?key=API_KEY
##             form "grant_type=refresh_token&refresh_token=..." -> id_token/refresh_token/expires_in
## Tokens persist in user://social_auth.json and refresh automatically before
## any backend call once within SocialConfig.TOKEN_REFRESH_MARGIN_SEC of expiry.
##
## FUTURE (Game Center): when GC linking lands, sign-in will exchange a Game
## Center credential via accounts:signInWithGameCenter and link it to this
## anonymous account so progress/friends carry over. Keep uid stable until then.

signal auth_changed(user: Dictionary)
signal profile_loaded(profile: Dictionary)
signal friends_loaded(friends: Array)
signal friend_requests_loaded(requests: Array)
signal challenges_loaded(challenges: Array)
signal social_error(message: String)

var client: SocialApiClient

## {uid, idToken, refreshToken, expiresAt(unix sec)} — empty until signed in.
var auth: Dictionary = {}
var profile: Dictionary = {}
var friends: Array = []
var friend_requests: Array = []
var challenges: Array = []

func _ready() -> void:
	client = SocialApiClient.new()
	client.name = "ApiClient"
	client.token_provider = _get_valid_token
	client.api_error.connect(func(msg: String): social_error.emit(msg))
	add_child(client)
	_load_auth()

func is_signed_in() -> bool:
	return not auth.is_empty()

# =============================================================================
# Auth — anonymous sign-in + token lifecycle
# =============================================================================
## Make sure we have a usable account, signing up anonymously on first run.
## Safe to call before every operation; cheap when already signed in.
func ensure_signed_in() -> bool:
	if SocialConfig.USE_MOCK_API:
		if auth.is_empty():
			auth = {uid = "mock-uid-1", idToken = "mock-token", refreshToken = "mock-refresh",
				expiresAt = Time.get_unix_time_from_system() + 3600.0, mock = true}
			_save_auth()
			auth_changed.emit(auth)
		return true
	if not auth.is_empty():
		return await _get_valid_token() != ""
	var res: Dictionary = await client.http_json(HTTPClient.METHOD_POST,
		SocialConfig.AUTH_SIGNUP_URL % SocialConfig.firebase_api_key(),
		JSON.stringify({returnSecureToken = true}))
	if not res.ok or not (res.data is Dictionary):
		social_error.emit("Anonymous sign-in failed: %s" % res.error)
		return false
	auth = {
		uid = res.data.get("localId", ""),
		idToken = res.data.get("idToken", ""),
		refreshToken = res.data.get("refreshToken", ""),
		expiresAt = Time.get_unix_time_from_system() + float(res.data.get("expiresIn", "3600")),
		mock = false,
	}
	_save_auth()
	auth_changed.emit(auth)
	return true

## Returns a non-expired ID token (refreshing if needed) or "" on failure.
## Installed into SocialApiClient as its token provider.
func _get_valid_token() -> String:
	if SocialConfig.USE_MOCK_API:
		return "mock-token"
	if auth.is_empty():
		if not await ensure_signed_in():
			return ""
	var margin := float(SocialConfig.TOKEN_REFRESH_MARGIN_SEC)
	if Time.get_unix_time_from_system() < float(auth.get("expiresAt", 0)) - margin:
		return auth.idToken
	# Expired (or close): refresh. Form-encoded per the securetoken API.
	var body := "grant_type=refresh_token&refresh_token=%s" % str(auth.get("refreshToken", "")).uri_encode()
	var res: Dictionary = await client.http_json(HTTPClient.METHOD_POST,
		SocialConfig.AUTH_REFRESH_URL % SocialConfig.firebase_api_key(),
		body, "", "application/x-www-form-urlencoded")
	if not res.ok or not (res.data is Dictionary):
		# A 4xx means the refresh token itself is invalid/revoked (e.g. stale
		# state from another mode) — unrecoverable, so start a fresh anonymous
		# account. Network blips (status 0/5xx) keep the tokens for retry.
		if res.status >= 400 and res.status < 500:
			_clear_auth()
			if await ensure_signed_in():
				return auth.idToken
		social_error.emit("Token refresh failed: %s" % res.error)
		return ""
	auth.idToken = res.data.get("id_token", "")
	auth.refreshToken = res.data.get("refresh_token", auth.refreshToken)
	auth.uid = res.data.get("user_id", auth.uid)
	auth.expiresAt = Time.get_unix_time_from_system() + float(res.data.get("expires_in", "3600"))
	_save_auth()
	auth_changed.emit(auth)
	return auth.idToken

func _load_auth() -> void:
	if not FileAccess.file_exists(SocialConfig.AUTH_SAVE_PATH):
		return
	var f := FileAccess.open(SocialConfig.AUTH_SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary and data.has("refreshToken")):
		return
	# Discard state saved under the other mode: mock tokens poison real refresh
	# calls (and vice versa). Old mock-era files lack the flag, so also sniff
	# the fixture uid.
	var was_mock: bool = bool(data.get("mock", false)) or str(data.get("uid", "")).begins_with("mock-")
	if was_mock != SocialConfig.USE_MOCK_API:
		_clear_auth()
		return
	auth = data
	auth_changed.emit(auth)

## Forget the persisted account (used when its refresh token is unrecoverable).
func _clear_auth() -> void:
	auth = {}
	if FileAccess.file_exists(SocialConfig.AUTH_SAVE_PATH):
		DirAccess.remove_absolute(SocialConfig.AUTH_SAVE_PATH)

func _save_auth() -> void:
	var f := FileAccess.open(SocialConfig.AUTH_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		social_error.emit("Could not persist auth state")
		return
	f.store_string(JSON.stringify(auth))

# =============================================================================
# Profile
# =============================================================================
## GET /me — the backend get-or-creates the profile (and friend code) on first
## call, so "create profile" and "fetch profile" are the same client operation.
func refresh_profile() -> void:
	if not await ensure_signed_in():
		return
	var p: Dictionary = await client.get_profile()
	if not p.is_empty():
		profile = p
	profile_loaded.emit(profile)

func set_display_name(display_name: String) -> void:
	if not await ensure_signed_in():
		return
	var p: Dictionary = await client.update_profile(display_name.strip_edges())
	if not p.is_empty():
		profile = p
	profile_loaded.emit(profile)

## Post a beaten custom level to the player's own profile page.
func post_level_to_profile(payload: Dictionary) -> bool:
	if not await ensure_signed_in():
		return false
	var res: Dictionary = await client.post_level_to_profile(payload)
	return not res.is_empty()

# =============================================================================
# Push devices — used by PushNotificationService; the backend writes the
# users/{uid}/devices/{deviceId} doc (clients never touch Firestore directly).
# =============================================================================
func register_device(payload: Dictionary) -> bool:
	if not await ensure_signed_in():
		return false
	var res: Dictionary = await client.register_device(payload)
	return not res.is_empty()

func disable_device(device_id: String) -> bool:
	if device_id.is_empty():
		return false
	if not await ensure_signed_in():
		return false
	var res: Dictionary = await client.disable_device(device_id)
	return not res.is_empty()

# =============================================================================
# Per-level progress (users/{uid}/levels/LEVEL_<n>). GameState owns the local
# source of truth and calls these fire-and-forget; they return false on any
# failure (offline / signed out) so GameState can keep the record queued.
# =============================================================================
func sync_level_progress(level_id: String, payload: Dictionary) -> bool:
	if not await ensure_signed_in():
		return false
	var res: Dictionary = await client.set_level_progress(level_id, payload)
	return not res.is_empty()

func fetch_level_progress() -> Array:
	if not await ensure_signed_in():
		return []
	return await client.get_level_progress()

# =============================================================================
# Friends
# =============================================================================
func refresh_friends() -> void:
	if not await ensure_signed_in():
		return
	friends = await client.get_friends()
	friends_loaded.emit(friends)
	friend_requests = await client.get_friend_requests()
	friend_requests_loaded.emit(friend_requests)

func send_friend_request(friend_code: String) -> bool:
	if friend_code.strip_edges().is_empty():
		social_error.emit("Enter a friend code first")
		return false
	if not await ensure_signed_in():
		return false
	var res: Dictionary = await client.send_friend_request(friend_code.strip_edges())
	if res.is_empty():
		return false
	await refresh_friends()
	return true

func respond_to_friend_request(request_id: String, accept: bool) -> void:
	if not await ensure_signed_in():
		return
	await client.respond_to_friend_request(request_id, accept)
	await refresh_friends()

# =============================================================================
# Challenges
# =============================================================================
func refresh_challenges() -> void:
	if not await ensure_signed_in():
		return
	challenges = await client.get_challenges()
	challenges_loaded.emit(challenges)

## payload follows the contract: {levelId, seed, scoreToBeat, triesToBeat, layout}.
func create_challenge(to_user_id: String, payload: Dictionary) -> bool:
	if not await ensure_signed_in():
		return false
	var res: Dictionary = await client.create_challenge(to_user_id, payload)
	if res.is_empty():
		return false
	await refresh_challenges()
	return true

func respond_to_challenge(challenge_id: String, accept: bool) -> void:
	if not await ensure_signed_in():
		return
	await client.respond_to_challenge(challenge_id, accept)
	await refresh_challenges()

## `result` is advisory (e.g. {tries = 3}) — the backend decides the winner.
func complete_challenge(challenge_id: String, result: Dictionary) -> void:
	if not await ensure_signed_in():
		return
	await client.complete_challenge(challenge_id, result)
	await refresh_challenges()

# =============================================================================
# Convenience splits for the UI
# =============================================================================
func incoming_challenges() -> Array:
	return challenges.filter(func(c: Dictionary) -> bool:
		return c.get("toUserId", "") == auth.get("uid", "") and c.get("status", "") != "completed")

func outgoing_challenges() -> Array:
	return challenges.filter(func(c: Dictionary) -> bool:
		return c.get("fromUserId", "") == auth.get("uid", "") and c.get("status", "") != "completed")

func completed_challenges() -> Array:
	return challenges.filter(func(c: Dictionary) -> bool: return c.get("status", "") == "completed")
