extends Node
## Game controller / flow state machine. Loads levels into a Level renderer,
## owns the HUD + overlay screens (level complete, lost), and tracks progression
## via GameState. UI is built in code so the scene files stay trivial.
## Presentation layer — covered by the logic subtasks it displays.

const LevelScene := preload("res://scenes/levels/level.tscn")
const DUNGEON_BG := preload("res://assets/dungeonbackground.png")
const KEY_RED := preload("res://assets/redkey.png")
const KEY_BLUE := preload("res://assets/bluekey.png")

# Palette (matches the renderer's earthy/retro scheme).
const C_PANEL := Color("0f1f17")
const C_BAR := Color("0c1812")
const C_TEXT := Color("e9f5ee")
const C_ACCENT := Color("52ffb8")
const C_BTN := Color("2a4a3a")

var _playfield: Node2D
var _level: Node2D = null
var _hud_root: Control
var _overlay_root: Control

var _lbl_title: Label      ## "Level 8"  or  "<id> (Challenger)"
var _key_red: TextureRect
var _key_blue: TextureRect
var _lbl_attempts: Label
var _btn_switch: Button     ## contextual — shown only when Francis Scott can toggle a switch

## The friend's challenge being played ({} = a regular level).
var _challenge: Dictionary = {}

func _ready() -> void:
	_build_background()
	_playfield = Node2D.new()
	_playfield.name = "Playfield"
	add_child(_playfield)
	_build_hud()
	_build_overlay()
	get_viewport().size_changed.connect(_relayout)
	# Defensive: if the autoload raced its level scan at init, reload now that the
	# class registry is fully available.
	if GameState.level_count() == 0:
		GameState.reload_levels()
	# Consume the challenge context (if any) so it can't leak into a later regular run.
	var challenge: Dictionary = GameState.active_challenge
	GameState.active_challenge = {}
	if not challenge.is_empty():
		load_challenge(challenge)
		return
	# Otherwise play the level chosen on the selector screen.
	var start := GameState.current_level()
	if start != null:
		load_level(start)
	else:
		_show_message("No levels found", "Add level resources under res://levels/", [])

# =============================================================================
# Level lifecycle
# =============================================================================
func load_level(level: LevelData) -> void:
	_challenge = {}
	GameState.select(level)
	_clear_overlay()
	if _level != null:
		_level.queue_free()
		_level = null
	var board := LevelLoader.build_board(level)
	if board == null:
		_show_message("Invalid level", "Level %d failed validation." % level.id, [])
		return
	# Copy the live dev toggle into the headless board (prod value when shipped).
	board.invincible = Tuning.invincible

	_level = LevelScene.instantiate()
	_playfield.add_child(_level)
	_level.setup(board)
	_level.state_changed.connect(_refresh_hud)
	_level.won.connect(_on_won)
	_level.lost.connect(_on_lost)
	_level.restarted.connect(_on_level_restarted)
	# Entering the level is the start of a new try; the count is cumulative across
	# sessions (persisted + synced by GameState), so leaving and coming back keeps
	# growing it rather than resetting to 1.
	_level.attempts = GameState.bump_attempt(level.id)
	_relayout()
	_refresh_hud()

## Each in-place restart (death/manual) is another attempt — for both regular
## levels and challenges, the count is cumulative.
func _on_level_restarted() -> void:
	if not _challenge.is_empty():
		_level.attempts = GameState.bump_challenge_attempt(str(_challenge.get("id", "")))
	else:
		var lvl: LevelData = GameState.current_level()
		if lvl != null:
			_level.attempts = GameState.bump_attempt(lvl.id)

## Play a friend's challenge: build the board from its layout and report the
## result back to the backend on a clear (the server decides the winner).
func load_challenge(challenge: Dictionary) -> void:
	_challenge = challenge
	_clear_overlay()
	if _level != null:
		_level.queue_free()
		_level = null
	var layout: String = str(challenge.get("payload", {}).get("layout", ""))
	if LevelLoader.validate(layout) != "":
		_show_message("Invalid challenge", "This challenge level can't be loaded.",
			[{text = "Back", cb = _go_to_challenges}])
		return
	var board := Board.from_ascii(layout)
	board.invincible = Tuning.invincible

	_level = LevelScene.instantiate()
	_playfield.add_child(_level)
	_level.setup(board)
	_level.state_changed.connect(_refresh_hud)
	_level.won.connect(_on_challenge_won)
	_level.lost.connect(_on_lost)
	_level.restarted.connect(_on_level_restarted)
	# Challenges track attempts like normal levels — cumulative across leave/return.
	_level.attempts = GameState.bump_challenge_attempt(str(challenge.get("id", "")))
	_relayout()
	_refresh_hud()

func _on_challenge_won() -> void:
	var n: int = _level.attempts
	FirebaseSocial.complete_challenge(str(_challenge.get("id", "")), {attempts = n})
	var word := "attempt" if n == 1 else "attempts"
	_show_message("Challenge complete!",
		"You completed the puzzle from %s in %d %s!" % [_challenge.get("fromDisplayName", "a friend"), n, word], [
		{text = "Back to Challenges", cb = _go_to_challenges},
	])

func _on_won() -> void:
	GameState.mark_cleared(GameState.current_level())   # unlocks the next level + saves
	var tries: int = _level.attempts
	var word := "try" if tries == 1 else "tries"
	_show_message("Level %d complete!" % GameState.current_level().id,
		"You solved it in %d %s!" % [tries, word], [
		{text = "Continue", cb = _go_to_select},
	])

func _on_lost(reason: String) -> void:
	_show_message("Oops!", _death_text(reason), [
		{text = "Try Again", cb = _retry},
		{text = "Levels", cb = _go_to_select},
	])

## Restart the current level in place (counts as another attempt).
func _retry() -> void:
	_clear_overlay()
	if _level != null:
		_level.restart()
		_refresh_hud()

func _death_text(reason: String) -> String:
	match reason:
		"crush": return "Francis Scott was crushed. Give it another go!"
		"explosion": return "Francis Scott was caught in the blast. Give it another go!"
		_: return "Francis Scott didn't make it. Give it another go!"

func _go_to_select() -> void:
	GameState.active_challenge = {}
	get_tree().change_scene_to_file("res://scenes/level_select.tscn")

func _go_to_challenges() -> void:
	GameState.active_challenge = {}
	get_tree().change_scene_to_file("res://scenes/social/ChallengesScreen.tscn")

# =============================================================================
# Layout
# =============================================================================
func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size

func _relayout() -> void:
	if _level == null:
		return
	var vp := _viewport_size()
	var sa: Dictionary = SafeArea.insets()
	var top: float = vp.y * 0.17 + sa.top     # two HUD rows, below the notch
	var bottom: float = vp.y * 0.14 + sa.bottom  # Switch band, above the home indicator
	var pad := vp.x * 0.03
	var rect := Rect2(pad + sa.left, top + pad,
		vp.x - pad * 2.0 - sa.left - sa.right, vp.y - top - bottom - pad * 2.0)
	_level.fit_to_rect(rect)

# =============================================================================
# Background + HUD
# =============================================================================
func _build_background() -> void:
	var layer := CanvasLayer.new()
	layer.layer = -10
	add_child(layer)
	var bg := TextureRect.new()
	bg.texture = DUNGEON_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED   # fill the screen, no distortion
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bg)

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_hud_root = Control.new()
	_hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud_root)

	# Two stacked rows anchored to the top of the screen.
	var sa: Dictionary = SafeArea.insets()
	var top_box := VBoxContainer.new()
	top_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_box.offset_top = sa.top         # below the notch / Dynamic Island
	top_box.offset_left = sa.left
	top_box.offset_right = -sa.right
	top_box.add_theme_constant_override("separation", 4)
	_hud_root.add_child(top_box)
	top_box.add_child(_build_title_row())
	top_box.add_child(_build_status_row())

	# Contextual Switch button, centred in the band below the grid (above the
	# home indicator).
	var sw := CenterContainer.new()
	sw.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	sw.offset_top = -_viewport_size().y * 0.13 - sa.bottom
	sw.offset_bottom = -_viewport_size().y * 0.02 - sa.bottom
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_root.add_child(sw)
	_btn_switch = _bar_button("Switch", func(): if _level: _level.request_switch())
	_btn_switch.custom_minimum_size = Vector2(220, 88)
	_btn_switch.add_theme_stylebox_override("normal", _flat_style(C_ACCENT.darkened(0.2), 12))
	_btn_switch.visible = false
	sw.add_child(_btn_switch)

## Top row: back button (left) + centred level title.
func _build_title_row() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _flat_style(C_BAR))
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	bar.add_child(hbox)
	hbox.add_child(_bar_button("←", _go_to_select))
	_lbl_title = Label.new()
	_lbl_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_title.add_theme_color_override("font_color", C_TEXT)
	_lbl_title.add_theme_font_size_override("font_size", 34)
	hbox.add_child(_lbl_title)
	var spacer := Control.new()    # mirrors the back button width so the title stays centred
	spacer.custom_minimum_size = Vector2(108, 0)
	hbox.add_child(spacer)
	return bar

## Second row: collected keys (left), attempt number (centre), restart (right).
func _build_status_row() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _flat_style(C_BAR.lightened(0.05)))
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	bar.add_child(hbox)

	var keys := HBoxContainer.new()
	keys.add_theme_constant_override("separation", 6)
	_key_red = _key_icon(KEY_RED)
	_key_blue = _key_icon(KEY_BLUE)
	keys.add_child(_key_red)
	keys.add_child(_key_blue)
	hbox.add_child(keys)

	hbox.add_child(_expand_spacer())
	_lbl_attempts = Label.new()
	_lbl_attempts.add_theme_color_override("font_color", C_TEXT)
	_lbl_attempts.add_theme_font_size_override("font_size", 30)
	hbox.add_child(_lbl_attempts)
	hbox.add_child(_expand_spacer())

	hbox.add_child(_bar_button("Restart", _retry))
	return bar

func _key_icon(tex: Texture2D) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(54, 54)
	return t

func _expand_spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s

func _bar_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE  # don't let arrow keys drive UI focus instead of the game
	b.text = text
	b.custom_minimum_size = Vector2(108, 76)
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _flat_style(C_BTN, 12))
	b.add_theme_stylebox_override("hover", _flat_style(C_BTN.lightened(0.1), 12))
	b.add_theme_stylebox_override("pressed", _flat_style(C_ACCENT.darkened(0.3), 12))
	b.pressed.connect(cb)
	return b

## "Level 8" for a regular level, or "<id> (Challenger)" for a friend's challenge.
func _level_title() -> String:
	if not _challenge.is_empty():
		var lid: String = str(_challenge.get("payload", {}).get("levelId", ""))
		if lid == "" or lid == "placeholder":
			lid = "Challenge"
		return "%s (%s)" % [lid, _challenge.get("fromDisplayName", "a friend")]
	var lvl := GameState.current_level()
	return "Level %d" % lvl.id if lvl != null else "Level"

func _refresh_hud() -> void:
	if _level == null or _level.board == null:
		return
	var b: Board = _level.board
	_lbl_title.text = _level_title()
	_key_red.modulate.a = 1.0 if b.red_delivered else 0.3
	_key_blue.modulate.a = 1.0 if b.blue_delivered else 0.3
	_lbl_attempts.text = "Attempt %d" % _level.attempts
	_btn_switch.visible = _level.can_switch()

# =============================================================================
# Overlay screens
# =============================================================================
func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_overlay_root = Control.new()
	_overlay_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Pass touches through when no screen is up — otherwise this full-rect Control
	# (default MOUSE_FILTER_STOP) eats every tap/swipe before the HUD or the level
	# can see it. Each overlay adds its own dim ColorRect to block input behind it.
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_overlay_root)

func _clear_overlay() -> void:
	for c: Node in _overlay_root.get_children():
		c.queue_free()

func _show_message(title: String, body: String, buttons: Array) -> void:
	_clear_overlay()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay_root.add_child(dim)

	# CenterContainer keeps the panel centred as it grows to fit its content —
	# PRESET_CENTER on the panel itself anchors to its (zero) size before layout.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat_style(C_PANEL, 16))
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	vbox.custom_minimum_size = Vector2(540, 0)
	panel.add_child(vbox)
	_margin(vbox, 36)

	var t := Label.new()
	t.text = title
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_color", C_ACCENT)
	t.add_theme_font_size_override("font_size", 48)
	vbox.add_child(t)

	var body_label := Label.new()
	body_label.text = body
	body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_label.add_theme_color_override("font_color", C_TEXT)
	body_label.add_theme_font_size_override("font_size", 30)
	vbox.add_child(body_label)

	for spec: Dictionary in buttons:
		_dialog_button(vbox, spec["text"], spec["cb"])

func _dialog_button(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.custom_minimum_size = Vector2(0, 84)
	b.add_theme_font_size_override("font_size", 32)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _flat_style(C_BTN, 12))
	b.add_theme_stylebox_override("hover", _flat_style(C_BTN.lightened(0.1), 12))
	b.add_theme_stylebox_override("pressed", _flat_style(C_ACCENT.darkened(0.3), 12))
	b.pressed.connect(cb)
	parent.add_child(b)

# =============================================================================
# Small UI helpers
# =============================================================================
func _flat_style(color: Color, radius: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	if radius > 0:
		s.corner_radius_top_left = radius
		s.corner_radius_top_right = radius
		s.corner_radius_bottom_left = radius
		s.corner_radius_bottom_right = radius
	return s

func _margin(box: Control, m: int) -> void:
	box.add_theme_constant_override("margin_left", m)
	box.add_theme_constant_override("margin_right", m)
