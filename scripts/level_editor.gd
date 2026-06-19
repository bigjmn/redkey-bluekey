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
	{g = "T", name = "Gate"}, {g = "1", name = "Red Key"}, {g = "2", name = "Blue Key"},
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
var _playtest_dead: bool = false       ## a death/stuck modal is up (one at a time)

var _dragging: bool = false                  ## a drag-paint stroke is in progress
var _last_cell: Vector2i = Vector2i(-1, -1)  ## last cell painted this stroke (avoid re-paints)

func _ready() -> void:
	# Resume a saved draft if one was queued from the profile screen, else start fresh.
	if LevelDrafts.pending_layout != "":
		_load_layout(LevelDrafts.pending_layout)
		LevelDrafts.pending_layout = ""
	else:
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

## Rebuild the grid from an ASCII layout (a saved draft). Sizes follow the text.
func _load_layout(layout: String) -> void:
	var lines := layout.replace("\r", "").split("\n")
	while lines.size() > 0 and lines[lines.size() - 1] == "":
		lines.remove_at(lines.size() - 1)
	if lines.is_empty():
		_new_grid()
		return
	_h = lines.size()
	_w = 0
	for line: String in lines:
		_w = maxi(_w, line.length())
	_grid = []
	for y: int in range(_h):
		var row: Array = []
		for x: int in range(_w):
			row.append(lines[y].substr(x, 1) if x < lines[y].length() else ".")
		_grid.append(row)

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
	root.add_theme_constant_override("separation", 10)
	bg.add_child(root)
	SafeArea.apply(root, 8)   # keep editor controls clear of notch/home indicator

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

const PAL_COLS := 7                   ## 14 items -> two even rows of seven
const PAL_BTN := Vector2(92, 118)     ## tall enough for a two-line name ("Francis Scott")

func _build_palette(parent: Control) -> void:
	var center := CenterContainer.new()
	parent.add_child(center)
	var grid := GridContainer.new()
	grid.columns = PAL_COLS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	center.add_child(grid)
	for item: Dictionary in PALETTE:
		var glyph: String = item["g"]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.button_pressed = glyph == _selected
		b.custom_minimum_size = PAL_BTN
		b.clip_contents = true
		b.tooltip_text = item["name"]
		b.add_theme_stylebox_override("normal", _flat(C_BTN, 8))
		b.add_theme_stylebox_override("hover", _flat(C_BTN.lightened(0.12), 8))
		b.add_theme_stylebox_override("pressed", _flat(C_SEL.darkened(0.25), 8))
		b.pressed.connect(func(): _select_glyph(glyph))
		# rendered tile in the upper area + name beneath
		b.add_child(_tile_visual(glyph, 50.0, PAL_BTN.x / 2.0, 32.0))
		var name_lbl := Label.new()
		name_lbl.text = item["name"]
		name_lbl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		name_lbl.offset_top = -56    # room for up to two wrapped lines
		name_lbl.offset_bottom = -8  # lift off the bottom edge so it isn't clipped
		name_lbl.offset_left = 2
		name_lbl.offset_right = -2
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_lbl.add_theme_font_size_override("font_size", 16)
		name_lbl.add_theme_color_override("font_color", C_TEXT)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(name_lbl)
		grid.add_child(b)
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
			b.add_to_group("no_click")   # board painting isn't a UI click (no click sfx)
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
	# Single-instance tiles: a new spawn ('A') or gate ('T') clears the old one.
	if _selected == "A" or _selected == "T":
		for yy: int in range(_h):
			for xx: int in range(_w):
				if _grid[yy][xx] == _selected:
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
	_mk_button(row, "Clear", _clear_board)
	_mk_button(row, "Save", _do_save_draft)
	_mk_button(row, "Play", _do_playtest)
	_mk_button(row, "Back", _go_back)

## Empty the board back to a fresh bordered grid (the edge walls stay locked).
func _clear_board() -> void:
	_new_grid()
	_populate_grid_buttons()
	_set_status("Board cleared", C_TEXT)

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

## Save the current grid as a local draft — no validation, so works-in-progress
## are fine. Drafts appear in the profile's "Saved Levels" section.
func _do_save_draft() -> void:
	var draft := LevelDrafts.save_draft(_layout_string(), _w, _h)
	_set_status("Saved %s — find it under Saved Levels on your profile." % draft.name, C_ACCENT)

## Write the current grid as a real, validated game level (.tres). Used by the
## dev-mode playtest-clear flow, not the editor button.
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
	_playtest_dead = false
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
	level.won.connect(func(): _on_playtest_won(level))
	level.lost.connect(func(reason: String): _show_playtest_dead(level, "You died!", _death_body(reason)))

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
	_playtest_dead = false
	for c: Node in _play_root.get_children():
		c.queue_free()
	_play_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit_ui.visible = true

func _death_body(reason: String) -> String:
	match reason:
		"crush": return "Francis Scott was crushed."
		"explosion": return "Francis Scott was caught in the blast."
		_: return "Francis Scott didn't make it."

## Centred modal over a dead playtest: Try Again restarts the level, Return to
## Editor stops the playtest.
func _show_playtest_dead(level: Node2D, title: String, body: String) -> void:
	if _playtest_dead:
		return  # one modal at a time (a blast can fire lost + became_unwinnable together)
	_playtest_dead = true
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # block input to the frozen level behind
	_play_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(C_PANEL, 16))
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var t := Label.new()
	t.text = title
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_color", C_ACCENT)
	t.add_theme_font_size_override("font_size", 40)
	box.add_child(t)

	var b := Label.new()
	b.text = body
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_font_size_override("font_size", 26)
	box.add_child(b)

	_mk_button(box, "Try Again", func(): _playtest_dead = false; dim.queue_free(); level.restart())
	_mk_button(box, "Return to Editor", _stop_playtest)

# =============================================================================
# Post-clear flow: dev mode keeps the original "beating it makes it a game
# level" behaviour (gated by the SocialConfig.DEV_LEVELS_ENV environment
# variable); otherwise the player can send the beaten level as a challenge to a
# friend and/or post it to their profile.
# =============================================================================
func _on_playtest_won(level: Node2D) -> void:
	var tries: int = level.attempts
	# Designer flow when the Tuning dev toggle is on (debug builds, default ON)
	# or the ACNO_DEV_LEVELS env var is set (works for exported/CLI runs too).
	if Tuning.dev_levels or SocialConfig.dev_levels_mode():
		_do_save()
		_set_status("Cleared! Saved. " + _status.text, C_ACCENT)
		_stop_playtest()
		return
	_stop_playtest()
	_set_status("Cleared in %d %s!" % [tries, "try" if tries == 1 else "tries"], C_ACCENT)
	_open_share_dialog(tries)

var _share_dialog: Control = null
var _friends_list: VBoxContainer = null   ## holds one CheckBox per friend
var _friend_checks: Array = []            ## [{check: CheckBox, uid: String}]

## The challenge/post payload for the just-beaten board (contract shape).
func _share_payload(tries: int) -> Dictionary:
	var layout := _layout_string()
	return {
		levelId = _make_code(0, layout), seed = 0, scoreToBeat = 0,
		triesToBeat = tries, layout = layout,
	}

func _open_share_dialog(tries: int) -> void:
	_close_share_dialog()
	_share_dialog = ColorRect.new()
	_share_dialog.color = Color(0, 0, 0, 0.6)
	_share_dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_share_dialog)

	# A CenterContainer centres the panel at its real (content-driven) size — unlike
	# PRESET_CENTER, which anchors before the panel has sized itself and lands off-centre.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_share_dialog.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(C_PANEL, 16))
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(480, 0)
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var head := Label.new()
	head.text = "Level cleared in %d %s!" % [tries, "try" if tries == 1 else "tries"]
	head.add_theme_color_override("font_color", C_ACCENT)
	head.add_theme_font_size_override("font_size", 30)
	box.add_child(head)

	box.add_child(_dialog_label("Challenge friends:", C_TEXT, 22))

	# Scrollable, multi-select friend list.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_friends_list = VBoxContainer.new()
	_friends_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friends_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_friends_list)
	_friends_list.add_child(_dialog_label("Loading friends…", C_TEXT.darkened(0.25), 20))

	FirebaseSocial.friends_loaded.connect(_on_share_friends)
	FirebaseSocial.refresh_friends()

	var payload := _share_payload(tries)
	_mk_button(box, "Send Challenge", func(): _share_challenge(payload))
	_mk_button(box, "Post to Profile", func(): _share_post(payload))
	_mk_button(box, "Done", _close_share_dialog)

func _dialog_label(text: String, color: Color, size_px: int) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size_px)
	return l

func _on_share_friends(friends: Array) -> void:
	if _friends_list == null:
		return
	for c: Node in _friends_list.get_children():
		c.queue_free()
	_friend_checks = []
	if friends.is_empty():
		_friends_list.add_child(_dialog_label("No friends yet — add some on the Friends screen.", C_TEXT.darkened(0.25), 20))
		return
	for f: Dictionary in friends:
		var cb := CheckBox.new()
		cb.text = str(f.get("displayName", "?"))
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_size_override("font_size", 22)
		cb.add_theme_color_override("font_color", C_TEXT)
		_friends_list.add_child(cb)
		_friend_checks.append({check = cb, uid = str(f.get("uid", ""))})

func _share_challenge(payload: Dictionary) -> void:
	var uids: Array = []
	for entry: Dictionary in _friend_checks:
		if entry.check.button_pressed:
			uids.append(entry.uid)
	if uids.is_empty():
		_set_status("Pick at least one friend", C_WARN)
		return
	var sent: int = await FirebaseSocial.create_challenges(uids, payload)
	if sent > 0:
		_set_status("Challenge sent to %d %s!" % [sent, "friend" if sent == 1 else "friends"], C_ACCENT)
		_close_share_dialog()
	else:
		_set_status("Challenge failed", C_WARN)

func _share_post(payload: Dictionary) -> void:
	var ok: bool = await FirebaseSocial.post_level_to_profile(payload)
	_set_status("Posted to your profile!" if ok else "Post failed", C_ACCENT if ok else C_WARN)
	if ok:
		_close_share_dialog()

func _close_share_dialog() -> void:
	if FirebaseSocial.friends_loaded.is_connected(_on_share_friends):
		FirebaseSocial.friends_loaded.disconnect(_on_share_friends)
	if _share_dialog != null:
		_share_dialog.queue_free()
		_share_dialog = null
	_friends_list = null
	_friend_checks = []

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
