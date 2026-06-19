extends Control
## Level selector — the main screen. A grid of level buttons keyed to the level
## library (level_<n>.tres). Completed levels are green, the current (next-to-play)
## level is blue, levels the player hasn't reached are locked. Progress lives in
## GameState (persisted to user://). Buttons beyond the existing levels are shown
## locked as "coming soon" placeholders — their links would be broken, but locked
## buttons aren't clickable so it doesn't matter.

const COMPLETED := preload("res://assets/completedlevelbutton.png")
const CURRENT := preload("res://assets/currentlevelbutton.png")
const LOCKED := preload("res://assets/lockedlevelbutton.png")
const MORESOON := preload("res://assets/moresoonbutton.png")
const DUNGEON_BG := preload("res://assets/dungeonbackground.png")

const COLS := 3
const MIN_BUTTONS := 12        ## fill the grid like the reference even with few levels
const CELL := Vector2(200, 210)

const C_TEXT := Color("fdf6e3")
const C_ACCENT := Color("ffe08a")

func _ready() -> void:
	if GameState.level_count() == 0:
		GameState.reload_levels()
		GameState.load_progress()
	_build()
	# First-time players get the how-to-play card automatically.
	if not GameState.instructions_seen:
		GameState.mark_instructions_seen()
		_open_instructions()

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = DUNGEON_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED   # fill the screen, no distortion
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	add_child(root)
	var sa: Dictionary = SafeArea.insets_for(get_viewport_rect().size)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = sa.left + 20
	root.offset_right = -(sa.right + 20)
	root.offset_top = sa.top + 24
	root.offset_bottom = -(sa.bottom + 32)   # padding under the bottom row; matches the gear baseline (gear_menu.gd)

	var title := Label.new()
	title.text = "LEVEL SELECTOR"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", C_ACCENT)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	title.add_theme_constant_override("outline_size", 10)
	title.add_theme_font_size_override("font_size", 56)
	root.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 18)
	center.add_child(grid)

	var total := maxi(GameState.max_level_id(), MIN_BUTTONS)
	if total % COLS != 0:
		total += COLS - (total % COLS)
	for id: int in range(1, total + 1):
		grid.add_child(_make_cell(id))

	root.add_child(_bottom_bar())

func _make_cell(id: int) -> Control:
	var level := GameState.level_by_id(id)
	var unlocked := GameState.is_unlocked_id(id) and level != null
	var completed := GameState.is_completed_id(id) and level != null

	var cell := TextureButton.new()
	cell.custom_minimum_size = CELL
	cell.ignore_texture_size = true
	cell.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	cell.focus_mode = Control.FOCUS_NONE
	cell.texture_normal = COMPLETED if completed else (CURRENT if unlocked else LOCKED)
	cell.disabled = not unlocked
	if unlocked:
		cell.pressed.connect(func(): _play(level))

	var num := Label.new()
	num.text = str(id)
	num.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.add_theme_font_size_override("font_size", 66)
	num.add_theme_color_override("font_color", C_TEXT if unlocked else Color(0.85, 0.85, 0.85, 0.7))
	num.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	num.add_theme_constant_override("outline_size", 8)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(num)
	return cell

const GEAR_SLOT := 72   ## footprint reserved for the global gear button (gear_menu.gd)

func _bottom_bar() -> Control:
	# One evenly-spaced, bottom-aligned row: back (left), "more soon" (centre), and
	# a reserved slot on the right that the global gear button (GearMenu autoload,
	# pinned bottom-right) sits over. Two expanding spacers give the three items
	# equal gaps. Half-screen-width banner; height follows its own aspect ratio.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var more_w: float = vp.x * 0.5
	var more_h: float = more_w * float(MORESOON.get_height()) / float(MORESOON.get_width())

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)
	bar.custom_minimum_size = Vector2(0, more_h)

	var back := Button.new()
	back.text = "←"
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size = Vector2(96, 84)
	back.size_flags_vertical = Control.SIZE_SHRINK_END   # sit on the row's baseline
	back.add_theme_font_size_override("font_size", 40)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title_screen.tscn"))
	bar.add_child(back)

	bar.add_child(_hspacer())

	# Play / Rules / Social / Level Editor all live on the title screen now; the
	# selector just teases what's coming next.
	var more := TextureButton.new()
	more.texture_normal = MORESOON
	more.ignore_texture_size = true
	more.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	more.custom_minimum_size = Vector2(more_w, more_h)
	more.focus_mode = Control.FOCUS_NONE
	more.size_flags_vertical = Control.SIZE_SHRINK_END
	more.pressed.connect(_open_more_soon)
	bar.add_child(more)

	bar.add_child(_hspacer())

	# Invisible slot the global gear overlays, so the row reads as three even items.
	var gear_slot := Control.new()
	gear_slot.custom_minimum_size = Vector2(GEAR_SLOT, 84)
	gear_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(gear_slot)
	return bar

## A horizontal expanding gap, used to space the bottom-row items evenly.
func _hspacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

func _open_instructions() -> void:
	add_child(Instructions.new())

const MORE_SOON_MESSAGE := "If you’ve enjoyed these puzzles, let me know! I’m thinking of either adding to this bank of puzzles or making a “puzzle of the day”. If I do either, you’ll have a chance to submit your own puzzles, and if I use it I’ll credit you. You won’t get money, but I’m not making any either.\n\nJ Nicks"

## A simple centred message modal: dim backdrop (tap to close) + a panel.
func _open_more_soon() -> void:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP   # block the grid behind us
	add_child(overlay)

	var dim := Button.new()   # tapping the backdrop dismisses
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.flat = true
	dim.add_theme_stylebox_override("normal", _modal_style(Color(0, 0, 0, 0.7)))
	dim.add_theme_stylebox_override("hover", _modal_style(Color(0, 0, 0, 0.7)))
	dim.add_theme_stylebox_override("pressed", _modal_style(Color(0, 0, 0, 0.7)))
	dim.pressed.connect(overlay.queue_free)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _modal_style(Color("13241b"), 18, Color("315140")))
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 34)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(560, 0)
	vbox.add_theme_constant_override("separation", 22)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "More Coming Soon"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", C_ACCENT)
	title.add_theme_font_size_override("font_size", 40)
	vbox.add_child(title)

	var msg := Label.new()
	msg.text = MORE_SOON_MESSAGE
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_color_override("font_color", C_TEXT)
	msg.add_theme_font_size_override("font_size", 26)
	vbox.add_child(msg)

	var close := Button.new()
	close.text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(0, 72)
	close.add_theme_font_size_override("font_size", 28)
	close.add_theme_color_override("font_color", C_TEXT)
	close.add_theme_stylebox_override("normal", _modal_style(Color("2a4a3a"), 10))
	close.add_theme_stylebox_override("hover", _modal_style(Color("2a4a3a").lightened(0.12), 10))
	close.add_theme_stylebox_override("pressed", _modal_style(Color("52ffb8").darkened(0.4), 10))
	close.pressed.connect(overlay.queue_free)
	vbox.add_child(close)

func _modal_style(color: Color, radius: int = 0, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	for m: String in ["left", "right", "top", "bottom"]:
		s.set("content_margin_" + m, 14)
	if radius > 0:
		s.set_corner_radius_all(radius)
	if border.a > 0.0:
		s.set_border_width_all(2)
		s.border_color = border
	return s

func _play(level: LevelData) -> void:
	GameState.active_challenge = {}   # ensure a regular level, not a stale challenge
	GameState.select(level)
	get_tree().change_scene_to_file("res://scenes/game.tscn")
