extends SocialScreenBase
## Challenges screen. Three sections, each row showing a board PREVIEW of the
## puzzle (cf. a chess app):
##   Active    — challenges sent to me, not yet completed → Play them.
##   Sent      — challenges I sent that the recipient hasn't completed yet.
##   Completed — finished ones (both directions), with the right wording per side.
## Challenges are complete/incomplete — there's no winner. New challenges are
## created from the level editor (multi-select friends); see level_editor.gd.

const BoardPreviewScene := preload("res://scripts/render/board_preview.gd")
const PREVIEW := 220.0

var _active_box: VBoxContainer
var _sent_box: VBoxContainer
var _done_box: VBoxContainer

func _screen_title() -> String:
	return "CHALLENGES"

func _on_open() -> void:
	FirebaseSocial.challenges_loaded.connect(_on_challenges)
	_active_box = _section("Active")
	_sent_box = _section("Sent")
	_done_box = _section("Completed")
	set_status("Loading…")
	FirebaseSocial.refresh_challenges()

func _exit_tree() -> void:
	super()
	if FirebaseSocial.challenges_loaded.is_connected(_on_challenges):
		FirebaseSocial.challenges_loaded.disconnect(_on_challenges)

# =============================================================================
# Lists
# =============================================================================
func _on_challenges(_challenges: Array) -> void:
	set_status("")
	_fill(_active_box, "Active", FirebaseSocial.active_challenges(), "No active challenges.")
	_fill(_sent_box, "Sent", FirebaseSocial.sent_challenges(), "Nothing sent yet.")
	_fill(_done_box, "Completed", FirebaseSocial.completed_challenges(), "Nothing completed yet.")

func _fill(box: VBoxContainer, title: String, list: Array, empty_text: String) -> void:
	_clear(box)
	box.add_child(_label(title, 26, C_ACCENT))
	if list.is_empty():
		box.add_child(_label(empty_text, 21, C_SUB))
		return
	var me := str(FirebaseSocial.auth.get("uid", ""))
	for ch: Dictionary in list:
		_challenge_row(box, ch, _row_text(ch, title, me), _row_buttons(ch, title))

## The line shown beside the preview, tailored to the section + viewer.
func _row_text(ch: Dictionary, section: String, me: String) -> String:
	match section:
		"Active":
			return "From %s" % ch.get("fromDisplayName", "?")
		"Sent":
			return "To %s — waiting" % ch.get("toDisplayName", "?")
		_:  # Completed
			var res: Dictionary = ch.get("result") if ch.get("result") is Dictionary else {}
			var n := int(res.get("attempts", 0))
			var word := "attempt" if n == 1 else "attempts"
			if str(ch.get("toUserId", "")) == me:
				return "You completed the puzzle from %s in %d %s" % [ch.get("fromDisplayName", "?"), n, word]
			return "%s completed your challenge in %d %s" % [ch.get("toDisplayName", "?"), n, word]

func _row_buttons(ch: Dictionary, section: String) -> Array:
	if section == "Active":
		return [{text = "Play", cb = func(): _play_challenge(ch)}]
	return []

## A challenge row: board preview on the left, text (+ optional buttons) on the right.
func _challenge_row(box: VBoxContainer, ch: Dictionary, text: String, buttons: Array) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	box.add_child(h)

	var preview := BoardPreviewScene.new()
	h.add_child(preview)
	preview.setup(str(ch.get("payload", {}).get("layout", "")), PREVIEW)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 8)
	h.add_child(col)
	col.add_child(_label(text, 22, C_TEXT))
	if not buttons.is_empty():
		var brow := HBoxContainer.new()
		brow.add_theme_constant_override("separation", 8)
		col.add_child(brow)
		for spec: Dictionary in buttons:
			brow.add_child(_button(spec.text, spec.cb))

# =============================================================================
# Playing a challenge — handed to the full game scene (game.gd reads
# GameState.active_challenge, tracks attempts, and completes it on a clear).
# =============================================================================
func _play_challenge(ch: Dictionary) -> void:
	if LevelLoader.validate(str(ch.get("payload", {}).get("layout", ""))) != "":
		set_status("Challenge level is invalid", true)
		return
	GameState.active_challenge = ch
	get_tree().change_scene_to_file("res://scenes/game.tscn")
