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
const EDITOR := preload("res://assets/leveleditorbutton.png")
const DUNGEON_BG := preload("res://assets/dungeonbackground.png")

const COLS := 3
const MIN_BUTTONS := 12        ## fill the grid like the reference even with few levels
const CELL := Vector2(200, 210)

const C_TEXT := Color("fdf6e3")
const C_ACCENT := Color("ffe08a")
const C_STAR := Color("ffcc33")

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
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 16)
	root.offset_left = 20
	root.offset_right = -20
	root.offset_top = 24
	root.offset_bottom = -24
	add_child(root)

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

	if unlocked:
		var stars := Label.new()
		stars.text = "★★★"
		stars.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		stars.offset_top = -38
		stars.offset_bottom = 2
		stars.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stars.add_theme_font_size_override("font_size", 32)
		stars.add_theme_color_override("font_color", C_STAR if completed else Color(0, 0, 0, 0.35))
		stars.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(stars)
	return cell

func _bottom_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)

	var back := Button.new()
	back.text = "←"
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size = Vector2(96, 84)
	back.add_theme_font_size_override("font_size", 40)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title_screen.tscn"))
	bar.add_child(back)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var help := Button.new()
	help.text = "? How to Play"
	help.focus_mode = Control.FOCUS_NONE
	help.custom_minimum_size = Vector2(0, 84)
	help.add_theme_font_size_override("font_size", 30)
	help.add_theme_color_override("font_color", C_TEXT)
	help.pressed.connect(_open_instructions)
	bar.add_child(help)

	var social := Button.new()
	social.text = "Social"
	social.focus_mode = Control.FOCUS_NONE
	social.custom_minimum_size = Vector2(0, 84)
	social.add_theme_font_size_override("font_size", 30)
	social.add_theme_color_override("font_color", C_TEXT)
	social.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/social/ProfileScreen.tscn"))
	bar.add_child(social)

	var editor := TextureButton.new()
	editor.texture_normal = EDITOR
	editor.ignore_texture_size = true
	editor.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	editor.custom_minimum_size = Vector2(220, 84)
	editor.focus_mode = Control.FOCUS_NONE
	editor.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/editor.tscn"))
	bar.add_child(editor)
	return bar

func _open_instructions() -> void:
	add_child(Instructions.new())

func _play(level: LevelData) -> void:
	GameState.select(level)
	get_tree().change_scene_to_file("res://scenes/game.tscn")
