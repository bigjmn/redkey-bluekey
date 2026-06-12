extends Node
## Game controller / flow state machine. Loads levels into a Level renderer,
## owns the HUD + overlay screens (level complete, lost), and tracks progression
## via GameState. UI is built in code so the scene files stay trivial.
## Presentation layer — covered by the logic subtasks it displays.

const LevelScene := preload("res://scenes/levels/level.tscn")
const DUNGEON_BG := preload("res://assets/dungeonbackground.png")

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

var _lbl_keys_left: Label
var _lbl_code: Label
var _btn_switch: Button   ## contextual — shown only when Francis Scott can toggle a switch

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
	# Play the level chosen on the selector screen.
	var start := GameState.current_level()
	if start != null:
		load_level(start)
	else:
		_show_message("No levels found", "Add level resources under res://levels/", [])

# =============================================================================
# Level lifecycle
# =============================================================================
func load_level(level: LevelData) -> void:
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
	_level.became_unwinnable.connect(_on_unwinnable)
	_relayout()
	_refresh_hud()

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

func _on_unwinnable() -> void:
	_show_message("Stuck!", "A teleporter key was destroyed — the level can't be finished.", [
		{text = "Restart", cb = _retry},
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
	get_tree().change_scene_to_file("res://scenes/level_select.tscn")

# =============================================================================
# Layout
# =============================================================================
func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size

func _relayout() -> void:
	if _level == null:
		return
	var vp := _viewport_size()
	var top := vp.y * 0.11
	var bottom := vp.y * 0.20
	var pad := vp.x * 0.03
	var rect := Rect2(pad, top + pad, vp.x - pad * 2.0, vp.y - top - bottom - pad * 2.0)
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

	# Top status bar.
	var bar := PanelContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.add_theme_stylebox_override("panel", _flat_style(C_BAR))
	_hud_root.add_child(bar)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 18)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_child(hbox)
	_lbl_keys_left = _stat_label(hbox, "Keys 0/2")
	_lbl_code = _stat_label(hbox, "")

	# Bottom control pad.
	var pad := HBoxContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	pad.offset_top = -_viewport_size().y * 0.17
	pad.alignment = BoxContainer.ALIGNMENT_CENTER
	pad.add_theme_constant_override("separation", 14)
	_hud_root.add_child(pad)
	_btn_switch = _pad_button(pad, "Switch", func(): if _level: _level.request_switch())
	_btn_switch.add_theme_stylebox_override("normal", _flat_style(C_ACCENT.darkened(0.2), 12))
	_btn_switch.visible = false
	_pad_button(pad, "Restart", _retry)
	_pad_button(pad, "Levels", _go_to_select)

func _stat_label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", C_TEXT)
	l.add_theme_font_size_override("font_size", 30)
	parent.add_child(l)
	return l

func _pad_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE  # don't let arrow keys drive UI focus instead of the game
	b.text = text
	b.custom_minimum_size = Vector2(150, 96)
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _flat_style(C_BTN, 12))
	b.add_theme_stylebox_override("hover", _flat_style(C_BTN.lightened(0.1), 12))
	b.add_theme_stylebox_override("pressed", _flat_style(C_ACCENT.darkened(0.3), 12))
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _refresh_hud() -> void:
	if _level == null or _level.board == null:
		return
	var b: Board = _level.board
	var delivered: int = 2 - b.keys_remaining()
	_lbl_keys_left.text = "Keys %d/2" % delivered
	_lbl_keys_left.add_theme_color_override("font_color", C_ACCENT if delivered == 2 else C_TEXT)
	_btn_switch.visible = _level.can_switch()
	var lvl := GameState.current_level()
	_lbl_code.text = lvl.code if lvl != null else ""

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

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat_style(C_PANEL, 16))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dim.add_child(panel)
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
