class_name Instructions
extends Control
## Click-through how-to-play modal. Builds a full-screen dim overlay with a single
## centred card; tap anywhere (or Next / arrow keys) to page forward, Back / ✕ /
## Esc to go back or dismiss. Each page renders real game tiles (CellVisual) beside
## their rules so the legend always matches what's on the board.
##
## Drop-in: `add_child(Instructions.new())` over any screen. Emits `closed` and
## frees itself when dismissed.

signal closed

# Palette — dark green card, cream text, gold accents (matches the selector).
const C_DIM := Color(0, 0, 0, 0.4)   ## light tint over the blurred screen behind the card
const C_PANEL := Color("13241b")
const C_EDGE := Color("315140")
const C_HEAD := Color("ffe08a")
const C_TEXT := Color("e9f5ee")
const C_SUB := Color("a7c6b5")
const C_TILEBG := Color("0c1611")
const C_DOT := Color("ffe08a")
const C_DOT_OFF := Color(1, 1, 1, 0.22)
const C_BTN := Color("294a39")

const CARD_W := 600
const TILE_BOX := 76
const ICON_GAP := 8   ## horizontal gap between two icons in a legend row

# Gaussian-ish blur of whatever is drawn behind the modal (a BackBufferCopy feeds
# the screen texture). 5x5 weighted taps — cheap enough for a static overlay.
const BLUR_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float radius = 4.0;
void fragment() {
	vec2 ps = SCREEN_PIXEL_SIZE * radius;
	vec3 c = vec3(0.0);
	float total = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			float w = 1.0 / (1.0 + float(x * x + y * y));
			c += texture(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * ps).rgb * w;
			total += w;
		}
	}
	COLOR = vec4(c / total, 1.0);
}
"

# Page model. `legend` rows pair real tiles with their rules; `goal` renders a
# highlighted call-out under the intro.
const PAGES := [
	{
		title = "Francis Scott",
		intro = "Meet Francis Scott. Swipe in any direction — or use the arrow keys — to move him one tile at a time. He's quick, so you can dart around hazards and shove objects out of the way.",
		legend = [
			{tiles = [{kind = "player"}], name = "Francis Scott", desc = "That's you. Steer him through each room to the exit."},
			{tiles = [{kind = "teleporter"}], name = "Gate", desc = "The exit. Locked until both keys are inside — then step in to clear the level."},
		],
		goal = "Push the red and blue keys into the gate, then step inside to clear the level. Solve each one in as few tries as you can — getting crushed just sends you back to the start.",
	},
	{
		title = "Objects",
		intro = "Objects are loose items on the grid. Gravity pulls each one straight down, one square at a time, whenever the tile below is empty — pausing a beat on every square. Walk into an object to push it sideways if the tile beyond is clear. You can't push upward, or push something while it's falling.",
		legend = [
			{tiles = [{kind = "rock"}], name = "Rock", desc = "A heavy boulder. Shove it or drop it down shafts. A rock that falls onto Francis Scott crushes him."},
			{tiles = [{kind = "barrel"}], name = "Barrel", desc = "Volatile. Blows up when something drops onto it, or when it lands after a fall — never from a sideways push. The blast clears a 3×3 area and chains to nearby barrels."},
			{tiles = [{kind = "red_key"}, {kind = "blue_key"}], name = "Red & Blue Key", desc = "Push or drop both into the gate to unlock it. A key caught in a blast is lost — the level becomes unwinnable, so restart."},
		],
	},
	{
		title = "Terrains",
		intro = "Terrain is the fixed structure of a room. It never falls and can't be pushed.",
		legend = [
			{tiles = [{kind = "wall"}], name = "Wall", desc = "Solid steel. Blocks Francis Scott and every object. Indestructible."},
			{tiles = [{kind = "breakable_wall"}], name = "Breakable Wall", desc = "Acts like a wall, but a barrel blast shatters it — detonate one nearby to open a path."},
			{tiles = [{kind = "dirt"}], name = "Dirt", desc = "Soft ground. Walk into it to clear it. Objects rest on top, and blasts wipe it away."},
			{tiles = [{kind = "flip_wall", active = true, caption = "Solid"}, {kind = "flip_wall", active = false, caption = "Open"}], name = "Toggle Wall", desc = "Two states: solid (a real wall) or faded (empty space you and objects pass through). A wall switch swaps them — but it won't flip while something sits inside a faded one, so nothing gets trapped."},
		],
	},
	{
		title = "Other",
		intro = "Special fixtures. They're all indestructible — blasts leave them untouched — and phaseable: Francis Scott and falling objects pass straight through them. Stand on a switch and a Switch button appears in the controls; press it to throw the switch.",
		legend = [
			{tiles = [{kind = "switch"}], name = "Wall Switch", desc = "Flips every toggle wall in the room at once."},
			{tiles = [{kind = "gravity_switch", active = false, caption = "Off"}, {kind = "gravity_switch", active = true, caption = "On"}], name = "Gravity Switch", desc = "Reverses gravity. While it's on, every object falls UP instead of down — use it to lift rocks and keys to places you couldn't reach. Throw it again to drop them back down."},
			{tiles = [{kind = "teleporter"}], name = "Gate", desc = "The exit. Stays locked (both locks shut) until both keys are delivered, then opens — step in to clear the level."},
		],
	},
]

var _page: int = 0
var _title_lbl: Label
var _body: VBoxContainer
var _dots: HBoxContainer
var _next_btn: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # block the screen behind us
	_build()
	_render()

# =============================================================================
# Construction
# =============================================================================
func _build() -> void:
	# Blur the screen behind the modal: copy what's been drawn so far (everything
	# below this overlay) into the back buffer, then draw a full-screen blurred
	# sample of it. Sits at the bottom so the dim + card layer over it.
	var bbc := BackBufferCopy.new()
	bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(bbc)
	var blur := ColorRect.new()
	blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = BLUR_SHADER
	blur.material = mat
	add_child(blur)

	# Dim backdrop — tapping anywhere on it pages forward.
	var dim := Button.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.flat = true
	dim.add_theme_stylebox_override("normal", _solid(C_DIM))
	dim.add_theme_stylebox_override("hover", _solid(C_DIM))
	dim.add_theme_stylebox_override("pressed", _solid(C_DIM))
	dim.pressed.connect(_advance)
	add_child(dim)

	# Centred card (ignores the mouse so taps fall through to the dim → advance;
	# only the explicit buttons inside catch their own clicks).
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", _card_style())
	center.add_child(card)

	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 34)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.custom_minimum_size = Vector2(CARD_W, 0)
	col.add_theme_constant_override("separation", 16)
	pad.add_child(col)

	# Header: "HOW TO PLAY" eyebrow + page title.
	var eyebrow := Label.new()
	eyebrow.text = "HOW TO PLAY"
	eyebrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eyebrow.add_theme_color_override("font_color", C_SUB)
	eyebrow.add_theme_font_size_override("font_size", 22)
	col.add_child(eyebrow)

	_title_lbl = Label.new()
	_title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_lbl.add_theme_color_override("font_color", C_HEAD)
	_title_lbl.add_theme_font_size_override("font_size", 50)
	col.add_child(_title_lbl)

	var rule := ColorRect.new()
	rule.color = C_EDGE
	rule.custom_minimum_size = Vector2(0, 3)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(rule)

	# Per-page body (rebuilt each turn).
	_body = VBoxContainer.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_constant_override("separation", 14)
	col.add_child(_body)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)

	# Footer: Back | dots | Next.
	var footer := HBoxContainer.new()
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.add_theme_constant_override("separation", 12)
	col.add_child(footer)

	var back := _footer_button("‹ Back", _go_back)
	footer.add_child(back)

	_dots = HBoxContainer.new()
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots.add_theme_constant_override("separation", 10)
	_dots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_dots)

	_next_btn = _footer_button("Next ›", _advance)
	_next_btn.add_theme_stylebox_override("normal", _solid(C_HEAD.darkened(0.1), 10))
	_next_btn.add_theme_color_override("font_color", Color("17241c"))
	footer.add_child(_next_btn)

	# Close ✕ — pinned to the card's top-right corner.
	var close := Button.new()
	close.text = "✕"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(56, 56)
	close.add_theme_font_size_override("font_size", 30)
	close.add_theme_color_override("font_color", C_TEXT)
	close.add_theme_stylebox_override("normal", _solid(Color(1, 1, 1, 0.06), 10))
	close.add_theme_stylebox_override("hover", _solid(Color(1, 1, 1, 0.14), 10))
	close.add_theme_stylebox_override("pressed", _solid(Color(1, 1, 1, 0.2), 10))
	var sa: Dictionary = SafeArea.insets()   # clear the notch / Dynamic Island
	close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close.offset_left = -(76 + sa.right)
	close.offset_top = 20 + sa.top
	close.offset_right = -(20 + sa.right)
	close.offset_bottom = 76 + sa.top
	close.pressed.connect(_close)
	add_child(close)

# =============================================================================
# Page rendering
# =============================================================================
func _render() -> void:
	var page: Dictionary = PAGES[_page]
	_title_lbl.text = page["title"]

	for c: Node in _body.get_children():
		c.queue_free()

	_body.add_child(_paragraph(page.get("intro", ""), C_TEXT, 25))

	if page.has("legend"):
		_body.add_child(_legend(page["legend"]))

	if page.has("goal"):
		_body.add_child(_goal_callout(page["goal"]))

	_rebuild_dots()
	var last := _page == PAGES.size() - 1
	_next_btn.text = "Got it ✓" if last else "Next ›"

func _legend(rows: Array) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 12)
	# Reserve a fixed icon-column width (sized to the row with the most tiles) so
	# every row's name/description starts at the same x — vertically aligned even
	# when some rows show two icons instead of one.
	var max_tiles := 1
	for row: Dictionary in rows:
		max_tiles = maxi(max_tiles, (row["tiles"] as Array).size())
	var icon_col_w := max_tiles * TILE_BOX + (max_tiles - 1) * ICON_GAP
	for row: Dictionary in rows:
		var line := HBoxContainer.new()
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_theme_constant_override("separation", 16)
		line.add_child(_icons(row["tiles"], icon_col_w))

		var text := VBoxContainer.new()
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text.add_theme_constant_override("separation", 2)
		text.add_child(_paragraph(row["name"], C_HEAD, 26))
		text.add_child(_paragraph(row["desc"], C_SUB, 22))
		line.add_child(text)
		box.add_child(line)
	return box

## A horizontal strip of one or more rendered tiles (each optionally captioned),
## padded to `col_width` so single- and double-icon rows align their text.
func _icons(tiles: Array, col_width: float) -> Control:
	var strip := HBoxContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_theme_constant_override("separation", ICON_GAP)
	strip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	strip.custom_minimum_size = Vector2(col_width, 0)   # reserve the widest-row width
	for spec: Dictionary in tiles:
		strip.add_child(_tile_box(spec))
	return strip

func _tile_box(spec: Dictionary) -> Control:
	var holder := VBoxContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_theme_constant_override("separation", 3)

	var frame := Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(TILE_BOX, TILE_BOX)
	frame.add_theme_stylebox_override("panel", _solid(C_TILEBG, 10))
	holder.add_child(frame)

	var cv := CellVisual.new()
	cv.setup(spec["kind"])
	if spec.has("active"):
		cv.set_active(spec["active"])
	var s := (TILE_BOX - 12) / float(Tuning.TILE_SIZE)
	cv.scale = Vector2(s, s)
	cv.position = Vector2(TILE_BOX / 2.0, TILE_BOX / 2.0)
	frame.add_child(cv)

	if spec.has("caption"):
		var cap := Label.new()
		cap.text = spec["caption"]
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.add_theme_color_override("font_color", C_SUB)
		cap.add_theme_font_size_override("font_size", 17)
		holder.add_child(cap)
	return holder

## Highlighted goal box (a tinted strip with a small heading).
func _goal_callout(text: String) -> Control:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _solid(Color("18301f"), 12, C_HEAD))
	var inner := VBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 4)
	for side: String in ["left", "right", "top", "bottom"]:
		inner.add_theme_constant_override("margin_" + side, 6)
	panel.add_child(inner)
	var head := Label.new()
	head.text = "🎯 THE GOAL"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_color_override("font_color", C_HEAD)
	head.add_theme_font_size_override("font_size", 22)
	inner.add_child(head)
	inner.add_child(_paragraph(text, C_TEXT, 24))
	return panel

func _rebuild_dots() -> void:
	for c: Node in _dots.get_children():
		c.queue_free()
	for i: int in range(PAGES.size()):
		var dot := Panel.new()
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var on := i == _page
		dot.custom_minimum_size = Vector2(14 if on else 11, 11)
		dot.add_theme_stylebox_override("panel", _solid(C_DOT if on else C_DOT_OFF, 6))
		_dots.add_child(dot)

# =============================================================================
# Navigation
# =============================================================================
func _advance() -> void:
	if _page >= PAGES.size() - 1:
		_close()
	else:
		_page += 1
		_render()

func _go_back() -> void:
	if _page > 0:
		_page -= 1
		_render()

func _close() -> void:
	closed.emit()
	queue_free()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				accept_event(); _close()
			KEY_LEFT, KEY_BACKSPACE:
				accept_event(); _go_back()
			KEY_RIGHT, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				accept_event(); _advance()

# =============================================================================
# Style helpers
# =============================================================================
func _paragraph(text: String, color: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	return l

func _footer_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _solid(C_BTN, 10))
	b.add_theme_stylebox_override("hover", _solid(C_BTN.lightened(0.12), 10))
	b.add_theme_stylebox_override("pressed", _solid(C_BTN.lightened(0.2), 10))
	b.pressed.connect(cb)
	return b

func _solid(color: Color, radius: int = 0, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	for m: String in ["left", "right", "top", "bottom"]:
		s.set("content_margin_" + m, 14)
	if radius > 0:
		s.corner_radius_top_left = radius
		s.corner_radius_top_right = radius
		s.corner_radius_bottom_left = radius
		s.corner_radius_bottom_right = radius
	if border.a > 0.0:
		s.set_border_width_all(2)
		s.border_color = border
	return s

func _card_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_PANEL
	s.set_border_width_all(2)
	s.border_color = C_EDGE
	s.set_corner_radius_all(22)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 18
	for m: String in ["left", "right", "top", "bottom"]:
		s.set("content_margin_" + m, 0)
	return s
