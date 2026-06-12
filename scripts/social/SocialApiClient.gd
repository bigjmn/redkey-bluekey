class_name SocialApiClient
extends Node
## Transport layer for the social backend. Owns the HTTPRequest plumbing and the
## backend route shapes; holds NO auth state (FirebaseSocial injects a token
## provider). Every public method is awaitable and never throws — failures
## return an empty Dictionary/Array and emit `api_error`.
##
## Expected backend routes (see res://docs/social_backend_contract.md):
##   GET    /me
##   PATCH  /me
##   POST   /me/levels                              (post a beaten custom level)
##   GET    /friends
##   GET    /friends/requests
##   POST   /friends/requests                       {friendCode}
##   POST   /friends/requests/{requestId}/respond   {accept}
##   GET    /challenges
##   POST   /challenges                             {toUserId, payload}
##   POST   /challenges/{challengeId}/respond       {accept}
##   POST   /challenges/{challengeId}/complete      {result}
##
## All calls send:  Authorization: Bearer <firebase id token>
##                  Content-Type: application/json
##
## Mock mode (SocialConfig.USE_MOCK_API): an in-memory fake backend with the
## fixture data the spec asks for — current user, two friends, one incoming
## friend request, one incoming + one outgoing challenge. Mutations update the
## fake state so the whole UI is exercisable offline.

signal api_error(message: String)

## Async Callable installed by FirebaseSocial; returns a valid bearer token or "".
var token_provider: Callable = Callable()

# =============================================================================
# Public API (route wrappers)
# =============================================================================
func get_profile() -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		return await _mock_result(_mock.profile.duplicate(true))
	return await _call_dict(HTTPClient.METHOD_GET, "/me")

func update_profile(display_name: String) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		_mock.profile.displayName = display_name
		return await _mock_result(_mock.profile.duplicate(true))
	return await _call_dict(HTTPClient.METHOD_PATCH, "/me", {displayName = display_name})

## Post a beaten custom level to the player's own profile (shows on their page).
func post_level_to_profile(payload: Dictionary) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		_mock.profile.postedLevels.append(payload)
		return await _mock_result({ok = true, count = _mock.profile.postedLevels.size()})
	return await _call_dict(HTTPClient.METHOD_POST, "/me/levels", payload)

func get_friends() -> Array:
	if SocialConfig.USE_MOCK_API:
		return await _mock_result(_mock.friends.duplicate(true))
	return await _call_array(HTTPClient.METHOD_GET, "/friends")

func get_friend_requests() -> Array:
	if SocialConfig.USE_MOCK_API:
		return await _mock_result(_mock.requests.duplicate(true))
	return await _call_array(HTTPClient.METHOD_GET, "/friends/requests")

## The backend resolves the friend code server-side (clients never see uid<->code maps).
func send_friend_request(friend_code: String) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		var req := {
			id = "req-out-%d" % (_mock.requests.size() + 1),
			fromUserId = _mock.profile.uid, fromDisplayName = _mock.profile.displayName,
			toUserId = "mock-resolved-%s" % friend_code, toDisplayName = "Player %s" % friend_code,
			status = "pending", direction = "outgoing",
		}
		_mock.requests.append(req)
		return await _mock_result(req.duplicate(true))
	return await _call_dict(HTTPClient.METHOD_POST, "/friends/requests", {friendCode = friend_code})

func respond_to_friend_request(request_id: String, accept: bool) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		for i: int in range(_mock.requests.size()):
			var r: Dictionary = _mock.requests[i]
			if r.id == request_id:
				r.status = "accepted" if accept else "rejected"
				_mock.requests.remove_at(i)
				if accept:  # the fake backend creates the friendship
					_mock.friends.append({uid = r.fromUserId, displayName = r.fromDisplayName, friendCode = "??-????"})
				return await _mock_result(r)
		return await _mock_result({})
	return await _call_dict(HTTPClient.METHOD_POST,
		"/friends/requests/%s/respond" % request_id, {accept = accept})

func get_challenges() -> Array:
	if SocialConfig.USE_MOCK_API:
		return await _mock_result(_mock.challenges.duplicate(true))
	return await _call_array(HTTPClient.METHOD_GET, "/challenges")

func create_challenge(to_user_id: String, payload: Dictionary) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		var to_name := "?"
		for f: Dictionary in _mock.friends:
			if f.uid == to_user_id:
				to_name = f.displayName
		var ch := {
			id = "ch-out-%d" % (_mock.challenges.size() + 1),
			fromUserId = _mock.profile.uid, fromDisplayName = _mock.profile.displayName,
			toUserId = to_user_id, toDisplayName = to_name,
			status = "pending", payload = payload,
		}
		_mock.challenges.append(ch)
		return await _mock_result(ch.duplicate(true))
	return await _call_dict(HTTPClient.METHOD_POST, "/challenges", {toUserId = to_user_id, payload = payload})

func respond_to_challenge(challenge_id: String, accept: bool) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		for ch: Dictionary in _mock.challenges:
			if ch.id == challenge_id:
				ch.status = "accepted" if accept else "declined"
				return await _mock_result(ch.duplicate(true))
		return await _mock_result({})
	return await _call_dict(HTTPClient.METHOD_POST,
		"/challenges/%s/respond" % challenge_id, {accept = accept})

## `result` is advisory — the backend re-validates and decides the winner.
func complete_challenge(challenge_id: String, result: Dictionary) -> Dictionary:
	if SocialConfig.USE_MOCK_API:
		for ch: Dictionary in _mock.challenges:
			if ch.id == challenge_id:
				ch.status = "completed"
				ch.result = result
				return await _mock_result(ch.duplicate(true))
		return await _mock_result({})
	return await _call_dict(HTTPClient.METHOD_POST,
		"/challenges/%s/complete" % challenge_id, {result = result})

# =============================================================================
# Raw HTTP (also used by FirebaseSocial for the Firebase Auth endpoints)
# =============================================================================
## One-shot JSON request. Returns {ok, status, data, error}; never throws.
## `content_type` lets the auth token refresh send form-encoded bodies.
func http_json(method: int, url: String, body: String = "",
		bearer: String = "", content_type: String = "application/json") -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	var headers := PackedStringArray(["Content-Type: %s" % content_type])
	if bearer != "":
		headers.append("Authorization: Bearer %s" % bearer)
	var err := req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {ok = false, status = 0, data = null, error = "request failed to start (%s)" % error_string(err)}
	var res: Array = await req.request_completed
	req.queue_free()
	var result: int = res[0]
	var status: int = res[1]
	var body_bytes: PackedByteArray = res[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {ok = false, status = status, data = null, error = "network error (result %d)" % result}
	var data: Variant = null
	var text := body_bytes.get_string_from_utf8()
	if not text.is_empty():
		data = JSON.parse_string(text)  # null on parse failure — treated as no payload
	if status < 200 or status >= 300:
		var msg := "HTTP %d" % status
		if data is Dictionary and data.has("error"):
			msg += ": %s" % str(data.error)
		return {ok = false, status = status, data = data, error = msg}
	return {ok = true, status = status, data = data, error = ""}

# =============================================================================
# Internals
# =============================================================================
## Authenticated call against the backend; returns the parsed JSON or null.
func _call(method: int, path: String, body: Dictionary = {}) -> Variant:
	var token := ""
	if token_provider.is_valid():
		token = await token_provider.call()
	if token.is_empty():
		api_error.emit("Not signed in")
		return null
	var body_text := "" if body.is_empty() else JSON.stringify(body)
	var res: Dictionary = await http_json(method, SocialConfig.API_BASE_URL + path, body_text, token)
	if not res.ok:
		api_error.emit("%s %s — %s" % [_method_name(method), path, res.error])
		return null
	return res.data

func _call_dict(method: int, path: String, body: Dictionary = {}) -> Dictionary:
	var data: Variant = await _call(method, path, body)
	return data if data is Dictionary else {}

func _call_array(method: int, path: String, body: Dictionary = {}) -> Array:
	var data: Variant = await _call(method, path, body)
	return data if data is Array else []

func _method_name(method: int) -> String:
	match method:
		HTTPClient.METHOD_GET: return "GET"
		HTTPClient.METHOD_POST: return "POST"
		HTTPClient.METHOD_PATCH: return "PATCH"
		_: return "HTTP"

## Mock calls still yield one frame so callers exercise the same await path
## (and UI code can't accidentally depend on synchronous completion).
func _mock_result(value: Variant) -> Variant:
	await get_tree().process_frame
	return value

# =============================================================================
# Mock fixture state (mutable, so the UI flows work end-to-end offline)
# =============================================================================
var _mock: Dictionary = {
	profile = {
		uid = "mock-uid-1",
		displayName = "Francis Scott",
		friendCode = "FS-2486",
		createdAt = "2026-06-12T00:00:00Z",
		stats = {levelsCleared = 3, challengesWon = 1},
		postedLevels = [],
	},
	friends = [
		{uid = "mock-uid-2", displayName = "Rocky", friendCode = "RK-7777"},
		{uid = "mock-uid-3", displayName = "Barrelina", friendCode = "BL-1357"},
	],
	requests = [
		{id = "req-1", fromUserId = "mock-uid-4", fromDisplayName = "KeyMaster",
			toUserId = "mock-uid-1", toDisplayName = "Francis Scott",
			status = "pending", direction = "incoming"},
	],
	challenges = [
		{id = "ch-in-1", fromUserId = "mock-uid-2", fromDisplayName = "Rocky",
			toUserId = "mock-uid-1", toDisplayName = "Francis Scott", status = "pending",
			payload = {
				levelId = "rocky-custom-1", seed = 0, scoreToBeat = 0, triesToBeat = 2,
				layout = "########\n#A.....#\n#.1.2..#\n#..T...#\n########",
			}},
		{id = "ch-out-1", fromUserId = "mock-uid-1", fromDisplayName = "Francis Scott",
			toUserId = "mock-uid-3", toDisplayName = "Barrelina", status = "pending",
			payload = {levelId = "my-custom-1", seed = 0, scoreToBeat = 0, triesToBeat = 1, layout = ""}},
	],
}
