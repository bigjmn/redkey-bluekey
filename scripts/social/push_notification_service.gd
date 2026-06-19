extends Node
## PushNotificationService (autoload) — client side of Firebase Cloud Messaging
## push for social events (friend requests, accepted friends, challenges).
##
## DESIGN
##  - Receiving push on iOS needs a NATIVE Godot plugin (FCM/APNs); there is no
##    pure-GDScript path. None is installed yet, so every plugin call is isolated
##    behind a wrapper and gated by Engine.has_singleton(...). On desktop/editor
##    or when the plugin is absent, the whole service safely NO-OPS (one warning).
##  - When a token is obtained AND a user is signed in, the device is registered
##    with the backend, which writes users/{uid}/devices/{deviceId} in Firestore
##    (clients never touch Firestore directly — see docs/social_backend_contract.md).
##  - Sending notifications is BACKEND-ONLY (a trusted server / Cloud Function);
##    never ship FCM server keys or APNs secrets in the client.
##
## ADJUST-AFTER-INSTALL: the candidate singleton/method/signal names below are
## best-guesses. After installing a plugin, set them to its actual API — that's
## the only place that should need changes. See docs/ios_push_setup.md.

signal push_token_updated(token: String)
signal notification_opened(data: Dictionary)
signal push_registration_failed(error: String)

# Godotx Firebase plugin (github.com/godot-x/firebase) — iOS-native singletons,
# absent on desktop/editor.
const CORE_SINGLETON := "GodotxFirebaseCore"
const MESSAGING_SINGLETON := "GodotxFirebaseMessaging"

var _core: Object = null
var _msg: Object = null
var _device_id: String = ""
var _fcm_token: String = ""
var _user_id: String = ""

## User preference (Settings → Notifications), persisted to user://. Mirrored to
## the backend device doc as `notificationsEnabled`; the server skips sends to
## devices where it's false, so turning this off stops push even while iOS still
## "allows" notifications for the app.
const PREFS_PATH := "user://push_prefs.cfg"
var _notifications_enabled: bool = true

func _ready() -> void:
	_device_id = _stable_device_id()
	_load_prefs()   # before any registration so the device doc reflects the saved choice
	# Track sign-in so we can (re)register whenever a user is present.
	FirebaseSocial.auth_changed.connect(_on_auth_changed)
	_init_plugin()   # kicks off Core -> Messaging -> permission -> token (iOS only)
	# Already signed in at startup? (FirebaseSocial emitted auth_changed before
	# we connected, during its own _ready.)
	if FirebaseSocial.is_signed_in():
		register_current_device_for_push(str(FirebaseSocial.auth.get("uid", "")))

# =============================================================================
# Public API
# =============================================================================
## Remember the signed-in user and register this device once a token exists.
## Safe to call repeatedly (e.g. after sign-in or profile creation).
func register_current_device_for_push(user_id: String) -> void:
	if user_id.is_empty():
		return
	_user_id = user_id
	await _try_register()

## Logout / account switch: mark this device's push disabled on the backend so
## sends skip it. Keeps the doc (notificationsEnabled=false) rather than deleting.
## `user_id` is accepted for API symmetry; the backend uses the authed uid.
@warning_ignore("unused_parameter")
func clear_current_device_push_token(user_id: String) -> void:
	_user_id = ""
	if _device_id.is_empty():
		return
	await FirebaseSocial.disable_device(_device_id)

## True when the user wants push (Settings → Notifications). Persisted across runs.
func notifications_enabled() -> bool:
	return _notifications_enabled

## Apply the Settings → Notifications choice. Persists it and syncs the backend
## device doc so sends start/stop immediately — independent of the iOS-level
## permission (which only governs whether the OS will DISPLAY a delivered push).
func set_notifications_enabled(enabled: bool) -> void:
	if enabled == _notifications_enabled:
		return
	_notifications_enabled = enabled
	_save_prefs()
	if not FirebaseSocial.is_signed_in():
		return  # nothing registered yet; the saved pref is applied at next register
	if enabled:
		await _try_register()                          # re-register with notificationsEnabled=true
	elif not _device_id.is_empty():
		await FirebaseSocial.disable_device(_device_id)  # flip the doc to false; keep the token

# =============================================================================
# Registration
# =============================================================================
func _try_register() -> void:
	if _user_id.is_empty() or _fcm_token.is_empty():
		return  # need BOTH a signed-in user and an FCM token
	var ok: bool = await FirebaseSocial.register_device({
		fcmToken = _fcm_token,
		platform = "ios",
		deviceId = _device_id,
		appVersion = _app_version(),
		notificationsEnabled = _notifications_enabled,
	})
	if not ok:
		push_registration_failed.emit("device push registration failed")

# =============================================================================
# Preference persistence (user://) — survives restarts so a disabled user stays
# disabled until they turn it back on.
# =============================================================================
func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) == OK:
		_notifications_enabled = bool(cfg.get_value("push", "notifications_enabled", true))

func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("push", "notifications_enabled", _notifications_enabled)
	cfg.save(PREFS_PATH)

func _on_auth_changed(user: Dictionary) -> void:
	var uid := str(user.get("uid", ""))
	if not uid.is_empty():
		register_current_device_for_push(uid)

# =============================================================================
# Plugin wrappers — Godotx Firebase. Isolated + fully guarded: nothing runs (or
# crashes) off-device or if the plugin is absent. Flow:
#   Core.initialize() -> core_initialized -> Messaging.initialize() +
#   request_permission() -> messaging_permission_granted -> get_token() ->
#   messaging_token_received -> register with the backend.
# =============================================================================
func _is_ios() -> bool:
	return OS.get_name() == "iOS"

func _init_plugin() -> void:
	if not _is_ios():
		return  # iOS-native singletons only; stay silent on desktop/editor
	if not Engine.has_singleton(CORE_SINGLETON) or not Engine.has_singleton(MESSAGING_SINGLETON):
		push_warning("[Push] Godotx Firebase singletons not found — is Messaging enabled in the iOS export preset? See docs/ios_push_setup.md.")
		return
	_core = Engine.get_singleton(CORE_SINGLETON)
	_msg = Engine.get_singleton(MESSAGING_SINGLETON)
	_connect(_core, "core_initialized", _on_core_initialized)
	_connect(_msg, "messaging_permission_granted", _on_permission_granted)
	_connect(_msg, "messaging_permission_denied", _on_permission_denied)
	_connect(_msg, "messaging_token_received", _on_plugin_token)
	_connect(_msg, "messaging_message_received", _on_message_received)
	if _core.has_method("initialize"):
		_core.initialize()

func _on_core_initialized(success: bool) -> void:
	if not success:
		push_registration_failed.emit("Firebase Core init failed")
		return
	if _msg.has_method("initialize"):
		_msg.initialize()
	if _msg.has_method("request_permission"):
		_msg.request_permission()   # iOS shows the system permission prompt

func _on_permission_granted() -> void:
	if _msg != null and _msg.has_method("get_token"):
		_msg.get_token()            # token arrives via messaging_token_received

func _on_permission_denied() -> void:
	push_registration_failed.emit("notifications permission denied")

func _on_plugin_token(token: Variant) -> void:
	var t := str(token)
	if t.is_empty() or t == _fcm_token:
		return
	_fcm_token = t
	push_token_updated.emit(t)
	_try_register()

## Foreground message. This plugin's signal carries title/body only (no data
## payload / tap event), so type-based routing isn't available from it — we just
## surface it. (iOS still shows the banner from the APNs payload when backgrounded.)
func _on_message_received(title: String, body: String) -> void:
	var d := {title = title, body = body}
	notification_opened.emit(d)
	_route_notification(d)

## Connect `cb` to `obj`'s signal `sig` if present (warn if the plugin API differs).
func _connect(obj: Object, sig: String, cb: Callable) -> void:
	if obj.has_signal(sig):
		if not obj.is_connected(sig, cb):
			obj.connect(sig, cb)
	else:
		push_warning("[Push] plugin missing signal '%s' — API may have changed." % sig)

# =============================================================================
# Routing — emit the signal (primary) + a defensive default route by `type`.
# =============================================================================
func _route_notification(d: Dictionary) -> void:
	var scene := ""
	match str(d.get("type", "")):
		"challenge": scene = "res://scenes/social/ChallengesScreen.tscn"
		"friend_request", "friend_accepted": scene = "res://scenes/social/FriendsScreen.tscn"
	if scene.is_empty() or get_tree() == null or not ResourceLoader.exists(scene):
		return
	get_tree().change_scene_to_file(scene)

# =============================================================================
# Helpers
# =============================================================================
func _app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))

## A stable per-install id. OS.get_unique_id() on device; else a persisted random.
func _stable_device_id() -> String:
	var uid := OS.get_unique_id()
	if not uid.is_empty():
		return uid
	const PATH := "user://push_device_id.txt"
	if FileAccess.file_exists(PATH):
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f != null:
			var saved := f.get_as_text().strip_edges()
			if not saved.is_empty():
				return saved
	var gen := "dev-"
	for _i: int in range(16):
		gen += "%x" % (randi() % 16)
	var w := FileAccess.open(PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(gen)
	return gen
