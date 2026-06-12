extends Node
## Level editor: paint any tile onto a grid, set its size, validate,
## save (writes a .tres under res://levels/ and emits its code), and playtest —
## a successful clear auto-saves and shows the code. Editor UX; the save/serialize
## roundtrip is covered by the level-data loader tests. Built in code so the
## scene stays trivial.

const LevelScene := preload("res://scenes/levels/level.tscn")
const DUNGEON_BG := preload("res://assets/dungeonbackground.png")

const C_PANEL := Color("0f1f17")
const C_TEXT := Color("e9f5ee")
const C_ACCENT := Color("52ffb8")
const C_WARN := Color("ef476f")
const C_BTN := Color("2a4a3a")
const C_SEL := Color("52ffb8")
const C_CELL := Color(0, 0, 0, 0.95)   ## board cell — matches the in-game board backdrop
const C_GRID_LINE := Color("7c92a8")   ## bright dividing lines between cells

# Placeable glyphs (tile_types + spawn).
const PALETTE := [
	{g = ".", name = "Empty"}, {g = "#", name = "Wall"}, {g = "B", name = "Breakable"},
	{g = "D", name = "Dirt"}, {g = "R", name = "Rock"}, {g = "X", name = "Barrel"},
	{g = "T", name = "Teleporter"}, {g = "1", name = "Red Key"}, {g = "2", name = "Blue Key"},
	{g = "W", name = "Switch"}, {g = "P", name = "Flip Off"}, {g = "Q", name = "Flip On"},
	{g = "G", name = "Gravity"}, {g = "A", name = "Francis Scott"},
]

# Glyphs that are terrain or empty — these support click-and-drag painting.
# Objects and Francis Scott (placed individually) are tap-only.
const DRAG_PAINT := [".", "#", "B", "D", "T", "W", "P", "Q", "G"]

var _w: int = 10
var _h: int = 12
var _grid: Array = []          ## _grid[y][x] -> glyph String
var _selected: String = "#"

var _grid_box: GridContainer
var _cell_buttons: Array = []  ## flat list of Buttons, row-major
var _cell_visuals: Array = []  ## parallel CellVisual tile previews
var _status: Label
var _palette_buttons: Dictionary = {}  ## glyph -> Button
var _play_root: Control
var _edit_ui: Control                  ## the editing UI; hidden during playtest

var _dragging: bool = false                  ## a drag-paint stroke is in progress
var _last_cell: Vector2i = Vector2i(-1, -1)  ## last cell painted this stroke (avoid re-paints)

func _ready() -> void:
	_new_grid()
	_build_ui()

# =============================================================================
# Grid data
# =============================================================================
func _new_grid() -> void:
	_grid = []
	for y: int in range(_h):
		var row: Array = []
		for x: int in range(_w):
			var border := x == 0 or y == 0 or x == _w - 1 or y == _h - 1
			row.append("#" if border else ".")
		_grid.append(row)
	# Seed a spawn, an exit, and both teleporter keys so a fresh board validates.
	# if _h >= 3 and _w >= 6:
	# 	_grid[1][1] = "A"
	# 	_grid[1][_w - 2] = "T"
	# 	_grid[1][_w / 2 - 1] = "1"
	# 	_grid[1][_w / 2 + 1] = "2"

func _layout_string() -> String:
	var rows: PackedStringArray = []
	for row: Array in _grid:
		rows.append("".join(PackedStringArray(row)))
	return "\n".join(rows)

# =============================================================================
# UI
# =============================================================================
func _build_ui() -> void:
	var bg := TextureRect.new()
	bg.texture = DUNGEON_BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED   # fill the screen, no distortion
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_edit_ui = bg

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	bg.add_child(root)

	var title := Label.new()
	title.text = "Level Editor"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", C_ACCENT)
	title.add_theme_font_size_override("font_size", 40)
	root.add_child(title)

	_build_palette(root)
	_build_grid(root)
	_build_controls(root)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", C_TEXT)
	_status.add_theme_font_size_override("font_size", 26)
	root.add_child(_status)

	_play_root = Control.new()
	_play_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_play_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_play_root)

# A rendered tile preview (CellVisual) scaled to fit `size`, centred at (cx,cy).
func _tile_visual(glyph: String, size: float, cx: float, cy: float) -> CellVisual:
	var cv := CellVisual.new()
	cv.setup(CellVisual.kind_for_glyph(glyph))
	var s := size / float(Tuning.TILE_SIZE)
	cv.scale = Vector2(s, s)
	cv.position = Vector2(cx, cy)
	return cv

func _build_palette(parent: Control) -> void:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	parent.add_child(flow)
	for item: Dictionary in PALETTE:
		var glyph: String = item["g"]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.button_pressed = glyph == _selected
		b.custom_minimum_size = Vector2(80, 92)
		b.clip_contents = true
		b.tooltip_text = item["name"]
		b.add_theme_stylebox_override("normal", _flat(C_BTN, 8))
		b.add_theme_stylebox_override("hover", _flat(C_BTN.lightened(0.12), 8))
		b.add_theme_stylebox_override("pressed", _flat(C_SEL.darkened(0.25), 8))
		b.pressed.connect(func(): _select_glyph(glyph))
		# rendered tile in the upper area + name beneath
		b.add_child(_tile_visual(glyph, 50.0, 40.0, 30.0))
		var name_lbl := Label.new()
		name_lbl.text = item["name"]
		name_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		name_lbl.offset_top = -26
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.add_theme_font_size_override("font_size", 16)
		name_lbl.add_theme_color_override("font_color", C_TEXT)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(name_lbl)
		flow.add_child(b)
		_palette_buttons[glyph] = b

func _select_glyph(glyph: String) -> void:
	_selected = glyph
	for g: String in _palette_buttons:
		_palette_buttons[g].button_pressed = g == glyph

func _build_grid(parent: Control) -> void:
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(center)
	# A bright backing whose colour shows through the cell gaps (and the 2px content
	# margin) as the dividing lines, so the dark cells read like the in-game board.
	var backing := PanelContainer.new()
	var line_box := StyleBoxFlat.new()
	line_box.bg_color = C_GRID_LINE
	line_box.set_content_margin_all(2)
	line_box.set_corner_radius_all(4)
	backing.add_theme_stylebox_override("panel", line_box)
	center.add_child(backing)
	_grid_box = GridContainer.new()
	_grid_box.columns = _w
	_grid_box.add_theme_constant_override("h_separation", 2)
	_grid_box.add_theme_constant_override("v_separation", 2)
	backing.add_child(_grid_box)
	_populate_grid_buttons()

func _populate_grid_buttons() -> void:
	for c: Node in _grid_box.get_children():
		c.queue_free()
	_cell_buttons.clear()
	_cell_visuals.clear()
	_grid_box.columns = _w
	var cell_size: float = clampf(620.0 / float(_w), 36.0, 64.0)
	for y: int in range(_h):
		for x: int in range(_w):
			var b := Button.new()
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size = Vector2(cell_size, cell_size)
			b.clip_contents = true
			# Painting is driven by _input (so a press OR a drag places tiles, by mouse
			# or finger); the button is kept only for its hover/press visuals.
			var cv := _tile_visual(_grid[y][x], cell_size, cell_size * 0.5, cell_size * 0.5)
			b.add_child(cv)
			_grid_box.add_child(b)
			_cell_buttons.append(b)
			_cell_visuals.append(cv)
			_refresh_cell(x, y)

# =============================================================================
# Pointer painting — a press places one tile; for terrain/empty a drag keeps
# painting cells the pointer passes over. Works for mouse and touch (_input runs
# before GUI routing, so the cell buttons' visuals are untouched).
# =============================================================================
func _input(event: InputEvent) -> void:
	if _edit_ui == null or not _edit_ui.visible:
		return  # not editing (e.g. mid-playtest) — leave input alone
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_stroke(event.position)
		else:
			_dragging = false
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_stroke(event.position)
		else:
			_dragging = false
	elif _dragging and (event is InputEventMouseMotion or event is InputEventScreenDrag):
		_drag_to(event.position)

## Press: paint the cell under the pointer. If the selected glyph supports drag
## painting (terrain/empty), arm the stroke so motion keeps painting.
func _begin_stroke(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	if cell.x < 0:
		return
	_paint(cell.x, cell.y)
	_last_cell = cell
	_dragging = DRAG_PAINT.has(_selected)

func _drag_to(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	if cell.x < 0 or cell == _last_cell:
		return
	_paint(cell.x, cell.y)
	_last_cell = cell

## Grid coordinates of the cell under a viewport-space point, or (-1,-1).
func _cell_at(pos: Vector2) -> Vector2i:
	for i: int in range(_cell_buttons.size()):
		var b: Button = _cell_buttons[i]
		if b.get_global_rect().has_point(pos):
			@warning_ignore("integer_division")
			return Vector2i(i % _w, i / _w)
	return Vector2i(-1, -1)

## The fixed perimeter wall — never paintable, so the room always stays enclosed.
func _is_border(x: int, y: int) -> bool:
	return x == 0 or y == 0 or x == _w - 1 or y == _h - 1

func _paint(x: int, y: int) -> void:
	if _is_border(x, y):
		return  # the edge walls are locked
	# Keep a single spawn: painting a new 'A' clears the old one.
	if _selected == "A":
		for yy: int in range(_h):
			for xx: int in range(_w):
				if _grid[yy][xx] == "A":
					_grid[yy][xx] = "."
					_refresh_cell(xx, yy)
	_grid[y][x] = _selected
	_refresh_cell(x, y)

func _refresh_cell(x: int, y: int) -> void:
	var idx := y * _w + x
	if idx >= _cell_buttons.size():
		return
	var b: Button = _cell_buttons[idx]
	var cv: CellVisual = _cell_visuals[idx]
	cv.setup(CellVisual.kind_for_glyph(_grid[y][x]))
	b.add_theme_stylebox_override("normal", _flat(C_CELL, 0))
	b.add_theme_stylebox_override("hover", _flat(Color(0.16, 0.19, 0.24, 0.95), 0))
	b.add_theme_stylebox_override("pressed", _flat(C_SEL.darkened(0.3), 0))

func _build_controls(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_mk_button(row, "Validate", _do_validate)
	_mk_button(row, "Save", _do_save)
	_mk_button(row, "Playtest", _do_playtest)
	_mk_button(row, "Back", _go_back)

# =============================================================================
# Validate / save / playtest
# =============================================================================
func _do_validate() -> bool:
	var err := LevelLoader.validate(_layout_string())
	if err == "":
		_set_status("Valid ✓", C_ACCENT)
		return true
	_set_status("Invalid: " + err, C_WARN)
	return false

func _do_save() -> void:
	if not _do_validate():
		return
	var level := _make_level()
	var path := "res://levels/level_%d.tres" % level.id
	_write_tres(level, path)
	GameState.reload_levels()
	_set_status("Saved %s  code: %s" % [path.get_file(), level.code], C_ACCENT)

func _make_level() -> LevelData:
	var level := LevelData.new()
	level.id = _next_id()
	level.layout = _layout_string()
	level.code = _make_code(level.id, level.layout)
	return level

func _next_id() -> int:
	var maxid := 0
	for lvl: LevelData in GameState.levels:
		maxid = maxi(maxid, lvl.id)
	return maxid + 1

## Deterministic, readable code from id + a base36 hash of the layout.
func _make_code(id: int, layout: String) -> String:
	var h := absi(hash(layout))
	var suffix := ""
	const ALPHABET := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for i: int in range(4):
		suffix += ALPHABET[h % 36]
		h /= 36
	return "LV%02d%s" % [id, suffix]

func _write_tres(level: LevelData, path: String) -> void:
	var text := "[gd_resource type=\"Resource\" script_class=\"LevelData\" load_steps=2 format=3]\n\n"
	text += "[ext_resource type=\"Script\" path=\"res://scripts/level/level_data.gd\" id=\"1\"]\n\n"
	text += "[resource]\n"
	text += "script = ExtResource(\"1\")\n"
	text += "id = %d\n" % level.id
	text += "code = \"%s\"\n" % level.code
	text += "layout = \"%s\"\n" % level.layout
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("Write failed: %s" % error_string(FileAccess.get_open_error()), C_WARN)
		return
	f.store_string(text)
	f.close()

func _do_playtest() -> void:
	if not _do_validate():
		return
	var board := Board.from_ascii(_layout_string())
	board.invincible = Tuning.invincible

	for c: Node in _play_root.get_children():
		c.queue_free()
	# Hide the editing UI rather than covering it with a STOP control — a STOP
	# control would also swallow the swipes the level reads via _unhandled_input.
	_edit_ui.visible = false
	_play_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dim := TextureRect.new()
	dim.texture = DUNGEON_BG
	dim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dim.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_play_root.add_child(dim)

	var field := Node2D.new()
	_play_root.add_child(field)
	var level := LevelScene.instantiate()
	field.add_child(level)
	level.setup(board)
	var vp := get_viewport().get_visible_rect().size
	level.fit_to_rect(Rect2(vp.x * 0.05, vp.y * 0.12, vp.x * 0.9, vp.y * 0.72))
	level.won.connect(func():
		_do_save()
		_set_status("Cleared! Saved. " + _status.text, C_ACCENT)
		_stop_playtest()
	)

	var stop := Button.new()
	stop.text = "Stop Playtest"
	stop.focus_mode = Control.FOCUS_NONE
	stop.add_theme_font_size_override("font_size", 28)
	stop.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	stop.offset_top = -90
	stop.offset_bottom = -20
	stop.pressed.connect(_stop_playtest)
	_play_root.add_child(stop)

	# Drop any UI focus so arrow keys reach the playtest immediately.
	get_viewport().gui_release_focus()

func _stop_playtest() -> void:
	for c: Node in _play_root.get_children():
		c.queue_free()
	_play_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit_ui.visible = true

func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/level_select.tscn")

# =============================================================================
# Helpers
# =============================================================================
func _mk_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE  # keep arrow keys flowing to the playtest, not UI focus
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _flat(C_BTN, 10))
	b.add_theme_stylebox_override("hover", _flat(C_BTN.lightened(0.1), 10))
	b.add_theme_stylebox_override("pressed", _flat(C_ACCENT.darkened(0.3), 10))
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _set_status(msg: String, color: Color) -> void:
	_status.text = msg
	_status.add_theme_color_override("font_color", color)

func _flat(color: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	return s
