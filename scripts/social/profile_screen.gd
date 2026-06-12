extends SocialScreenBase
## Profile screen: auth/profile status, editable display name, friend code,
## and any custom levels the player has posted to their profile.

var _name_edit: LineEdit
var _code_label: Label
var _levels_box: VBoxContainer

func _screen_title() -> String:
	return "PROFILE"

func _on_open() -> void:
	FirebaseSocial.profile_loaded.connect(_on_profile)
	var box := _section("Identity")
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Display name"
	_name_edit.custom_minimum_size = Vector2(0, 56)
	_name_edit.add_theme_font_size_override("font_size", 24)
	box.add_child(_name_edit)
	box.add_child(_button("Save Name", _save_name))
	_code_label = _label("Friend code: …", 24, C_GREEN)
	box.add_child(_code_label)

	_levels_box = _section("Posted Levels")
	_levels_box.add_child(_label("None yet — beat one of your own editor levels to post it.", 21, C_SUB))

	set_status("Signing in…")
	FirebaseSocial.refresh_profile()

func _exit_tree() -> void:
	super()
	if FirebaseSocial.profile_loaded.is_connected(_on_profile):
		FirebaseSocial.profile_loaded.disconnect(_on_profile)

func _on_profile(profile: Dictionary) -> void:
	if profile.is_empty():
		set_status("Profile unavailable", true)
		return
	set_status("Signed in anonymously as %s" % profile.get("uid", "?"))
	if not _name_edit.has_focus():
		_name_edit.text = str(profile.get("displayName", ""))
	_code_label.text = "Friend code: %s" % profile.get("friendCode", "—")
	# Posted levels (mock mode keeps these in-memory; backend will persist them).
	var posted: Array = profile.get("postedLevels", [])
	if not posted.is_empty():
		_clear(_levels_box)
		_levels_box.add_child(_label("Posted Levels", 26, C_ACCENT))
		for lvl: Dictionary in posted:
			_row(_levels_box, "%s  (beaten in %s tries)" % [lvl.get("levelId", "level"), str(lvl.get("triesToBeat", "?"))])

func _save_name() -> void:
	set_status("Saving…")
	FirebaseSocial.set_display_name(_name_edit.text)
