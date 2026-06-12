extends SocialScreenBase
## Challenges screen: send a placeholder challenge to a friend, act on incoming
## challenges (accept / decline / play / complete), and review outgoing +
## completed ones. "Play" loads the challenge's level layout in an overlay
## (same pattern as the editor playtest) and reports the result on win.

const LevelScene := preload("res://scenes/levels/level.tscn")

var _friend_pick: OptionButton
var _incoming_box: VBoxContainer
var _outgoing_box: VBoxContainer
var _done_box: VBoxContainer
var _play_root: Control = null   ## non-null while a challenge level is being played

func _screen_title() -> String:
	return "CHALLENGES"

func _on_open() -> void:
	FirebaseSocial.friends_loaded.connect(_on_friends)
	FirebaseSocial.challenges_loaded.connect(_on_challenges)

	var send_box := _section("Challenge a Friend")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	send_box.add_child(row)
	_friend_pick = OptionButton.new()
	_friend_pick.custom_minimum_size = Vector2(0, 56)
	_friend_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_pick.add_theme_font_size_override("font_size", 22)
	_friend_pick.focus_mode = Control.FOCUS_NONE
	row.add_child(_friend_pick)
	row.add_child(_button("Send Challenge", _send_placeholder))

	_incoming_box = _section("Incoming")
	_outgoing_box = _section("Outgoing")
	_done_box = _section("Completed")

	set_status("Loading…")
	FirebaseSocial.refresh_friends()
	FirebaseSocial.refresh_challenges()

func _exit_tree() -> void:
	super()
	if FirebaseSocial.friends_loaded.is_connected(_on_friends):
		FirebaseSocial.friends_loaded.disconnect(_on_friends)
	if FirebaseSocial.challenges_loaded.is_connected(_on_challenges):
		FirebaseSocial.challenges_loaded.disconnect(_on_challenges)

# =============================================================================
# Sending
# =============================================================================
## Placeholder payload per the contract — a real flow sends a beaten custom
## level from the editor (see level_editor.gd's social clear path).
func _send_placeholder() -> void:
	var idx := _friend_pick.selected
	if idx < 0 or idx >= FirebaseSocial.friends.size():
		set_status("Pick a friend first", true)
		return
	var friend: Dictionary = FirebaseSocial.friends[idx]
	set_status("Sending challenge…")
	var ok: bool = await FirebaseSocial.create_challenge(friend.get("uid", ""), {
		levelId = "placeholder", seed = 0, scoreToBeat = 0, triesToBeat = 1, layout = "",
	})
	if ok:
		set_status("Challenge sent to %s" % friend.get("displayName", "?"))

# =============================================================================
# Lists
# =============================================================================
func _on_friends(friends: Array) -> void:
	_friend_pick.clear()
	for f: Dictionary in friends:
		_friend_pick.add_item(str(f.get("displayName", "?")))

func _on_challenges(_challenges: Array) -> void:
	set_status("")
	_rebuild(_incoming_box, "Incoming", FirebaseSocial.incoming_challenges(), true)
	_rebuild(_outgoing_box, "Outgoing", FirebaseSocial.outgoing_challenges(), false)
	_rebuild(_done_box, "Completed", FirebaseSocial.completed_challenges(), false)

func _rebuild(box: VBoxContainer, title: String, list: Array, actionable: bool) -> void:
	_clear(box)
	box.add_child(_label(title, 26, C_ACCENT))
	if list.is_empty():
		box.add_child(_label("Nothing here.", 21, C_SUB))
		return
	for ch: Dictionary in list:
		var cid: String = ch.get("id", "")
		var who: String = ch.get("fromDisplayName", "?") if actionable else ch.get("toDisplayName", "?")
		var text := "%s %s — %s" % [("From" if actionable else "To"), who, ch.get("status", "?")]
		if title == "Completed":
			text += "  (result: %s)" % JSON.stringify(ch.get("result", {}))
		var buttons: Array = []
		if actionable:
			match ch.get("status", ""):
				"pending":
					buttons = [
						{text = "Accept", cb = func(): FirebaseSocial.respond_to_challenge(cid, true)},
						{text = "Decline", cb = func(): FirebaseSocial.respond_to_challenge(cid, false)},
					]
				"accepted":
					var payload: Dictionary = ch.get("payload", {})
					if str(payload.get("layout", "")) != "":
						buttons = [{text = "Play", cb = func(): _play_challenge(ch)}]
					else:
						# No layout to play (placeholder challenge) — complete directly.
						buttons = [{text = "Complete", cb = func(): FirebaseSocial.complete_challenge(cid, {tries = 1})}]
		_row(box, text, buttons)

# =============================================================================
# Playing a challenge level (overlay, mirrors the editor's playtest)
# =============================================================================
func _play_challenge(ch: Dictionary) -> void:
	var layout: String = str(ch.get("payload", {}).get("layout", ""))
	if LevelLoader.validate(layout) != "":
		set_status("Challenge level is invalid", true)
		return
	_chrome.visible = false
	_play_root = Control.new()
	_play_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_play_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_play_root)

	var field := Node2D.new()
	_play_root.add_child(field)
	var level := LevelScene.instantiate()
	field.add_child(level)
	level.setup(Board.from_ascii(layout))
	var vp := get_viewport().get_visible_rect().size
	level.fit_to_rect(Rect2(vp.x * 0.05, vp.y * 0.12, vp.x * 0.9, vp.y * 0.72))
	var cid: String = ch.get("id", "")
	level.won.connect(func():
		var tries: int = level.attempts
		_stop_play()
		set_status("Challenge cleared in %d %s!" % [tries, "try" if tries == 1 else "tries"])
		FirebaseSocial.complete_challenge(cid, {tries = tries})
	)

	var quit_btn := _button("Give Up", _stop_play)
	quit_btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	quit_btn.offset_top = -90
	quit_btn.offset_bottom = -20
	quit_btn.offset_left = -110
	quit_btn.offset_right = 110
	_play_root.add_child(quit_btn)
	get_viewport().gui_release_focus()

func _stop_play() -> void:
	if _play_root != null:
		_play_root.queue_free()
		_play_root = null
	_chrome.visible = true
