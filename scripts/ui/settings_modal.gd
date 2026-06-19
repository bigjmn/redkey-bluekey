class_name SettingsModal
extends Control
## The gear-menu modal: a centred card with three tabs (About / Settings /
## Privacy). Opened by the GearMenu autoload; frees itself (and emits `closed`)
## on dismiss. Toggle state lives on GearMenu so it persists between opens.

signal closed

const C_DIM := Color(0, 0, 0, 0.72)
const C_PANEL := Color("13241b")
const C_EDGE := Color("315140")
const C_HEAD := Color("ffe08a")
const C_TEXT := Color("e9f5ee")
const C_SUB := Color("a7c6b5")
const C_BTN := Color("294a39")

const CARD_W := 600
const CONTENT_MIN_H := 380

const TABS := ["About", "Settings", "Privacy"]

## Toggle state lives here (static -> persists between opens within a session).
## `sounds_on` gates all sound effects (read by the Sfx autoload); `notifications_on`
## is inert for now.
static var sounds_on: bool = true
static var notifications_on: bool = true

var _tab: int = 0
var _tab_buttons: Array[Button] = []
var _content: VBoxContainer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # block the screen behind us
	_build()
	_render()

func _build() -> void:
	# Tap-anywhere-outside backdrop.
	var dim := Button.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.focus_mode = Control.FOCUS_NONE
	dim.flat = true
	for s: String in ["normal", "hover", "pressed"]:
		dim.add_theme_stylebox_override(s, _solid(C_DIM))
	dim.pressed.connect(_close)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", _card_style())
	center.add_child(card)

	var pad := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 30)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(CARD_W, 0)
	col.add_theme_constant_override("separation", 16)
	pad.add_child(col)

	# Tab bar.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	col.add_child(tabs)
	for i: int in range(TABS.size()):
		var idx := i
		var b := _tab_button(TABS[i], func(): _select(idx))
		_tab_buttons.append(b)
		tabs.add_child(b)

	var rule := ColorRect.new()
	rule.color = C_EDGE
	rule.custom_minimum_size = Vector2(0, 2)
	col.add_child(rule)

	# Swapped per tab; min height keeps the card stable between tabs.
	_content = VBoxContainer.new()
	_content.custom_minimum_size = Vector2(0, CONTENT_MIN_H)
	_content.add_theme_constant_override("separation", 10)
	col.add_child(_content)

	col.add_child(_action_button("Close", _close))

# =============================================================================
# Tabs
# =============================================================================
func _select(i: int) -> void:
	_tab = i
	_render()

func _render() -> void:
	for i: int in range(_tab_buttons.size()):
		var on := i == _tab
		_tab_buttons[i].add_theme_stylebox_override("normal", _solid(C_HEAD.darkened(0.15) if on else C_BTN, 10))
		_tab_buttons[i].add_theme_color_override("font_color", Color("17241c") if on else C_TEXT)
	for c: Node in _content.get_children():
		c.queue_free()
	match _tab:
		0: _build_about()
		1: _build_settings()
		2: _build_privacy()

func _build_about() -> void:
	_content.add_child(_label("Red Key, Blue Key", 36, C_HEAD))
	_content.add_child(_label("Version 1.0", 22, C_SUB))
	_content.add_child(_spacer(8))
	_content.add_child(_label(
		"Red Key, Blue Key is brought to you by J Nicks Productions. It was inspired by games like Acno's Energizer and similar arcade puzzle games.",
		24, C_TEXT))
	_content.add_child(_spacer(4))
	_content.add_child(_label(
		"For feedback, questions, and bug reports, please send me an email. I typically respond within 25 - 35 seconds.",
		24, C_TEXT))

func _build_settings() -> void:
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 28)
	center.add_child(col)
	col.add_child(_toggle_block(
		"Sounds", "Really?", "Obviously.",
		sounds_on, func(on: bool): sounds_on = on))
	# Notifications reflect the persisted, backend-synced preference owned by
	# PushNotificationService — flipping it off actually stops push, not just the
	# on-device permission.
	var ps := _push_service()
	if ps != null and ps.has_method("notifications_enabled"):
		notifications_on = ps.notifications_enabled()
	col.add_child(_toggle_block(
		"Notifications", "We're in this one together.", "Come on, these sucked to implement.",
		notifications_on, _on_notifications_toggled))

## The PushNotificationService autoload (null in contexts where it isn't loaded).
func _push_service() -> Node:
	return get_node_or_null("/root/PushNotificationService")

func _on_notifications_toggled(on: bool) -> void:
	notifications_on = on
	var ps := _push_service()
	if ps != null and ps.has_method("set_notifications_enabled"):
		ps.set_notifications_enabled(on)

func _build_privacy() -> void:
	# Direct VBox children fill the card width (so the text lays out horizontally);
	# expanding spacers above/below centre it vertically. A CenterContainer here
	# would instead collapse the autowrapping label to its min width -> vertical text.
	var top := Control.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(top)
	_content.add_child(_label("I will not share your data. I don't care what they do to me. Does that make me a hero?", 28, C_TEXT))
	var bottom := Control.new()
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(bottom)

# =============================================================================
# Navigation
# =============================================================================
func _close() -> void:
	closed.emit()
	queue_free()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		accept_event()
		_close()

# =============================================================================
# Builders
# =============================================================================
func _label(text: String, size_px: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if size_px >= 28 else HORIZONTAL_ALIGNMENT_LEFT
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size_px)
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

## Footprint of the (unscaled) switch row; scaled up so the toggle reads big.
const TOGGLE_BASE := Vector2(320, 56)
const TOGGLE_SCALE := 1.5

## A large switch toggle: a scaled CheckButton (caption + switch) with live helper
## text below it that reflects the current on/off state. The default switch glyph
## is a fixed size, so we scale the whole control and reserve its scaled footprint
## in a holder, keeping each row centred and clear of its neighbour.
func _toggle_block(caption: String, on_text: String, off_text: String, value: bool, cb: Callable) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)

	var t := CheckButton.new()
	t.text = caption
	t.button_pressed = value
	t.focus_mode = Control.FOCUS_NONE
	t.custom_minimum_size = TOGGLE_BASE
	t.add_theme_font_size_override("font_size", 26)
	t.add_theme_color_override("font_color", C_TEXT)
	t.pivot_offset = TOGGLE_BASE * 0.5          # scale about the centre so it stays put
	t.scale = Vector2(TOGGLE_SCALE, TOGGLE_SCALE)

	var holder := CenterContainer.new()
	holder.custom_minimum_size = TOGGLE_BASE * TOGGLE_SCALE
	holder.add_child(t)
	block.add_child(holder)

	var helper := Label.new()
	helper.text = on_text if value else off_text
	helper.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	helper.add_theme_color_override("font_color", C_SUB)
	helper.add_theme_font_size_override("font_size", 20)
	block.add_child(helper)

	t.toggled.connect(func(on: bool):
		cb.call(on)
		helper.text = on_text if on else off_text)
	return block

func _tab_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 26)
	b.pressed.connect(cb)
	return b

func _action_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 68)
	b.add_theme_font_size_override("font_size", 28)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _solid(C_BTN, 10))
	b.add_theme_stylebox_override("hover", _solid(C_BTN.lightened(0.12), 10))
	b.add_theme_stylebox_override("pressed", _solid(C_HEAD.darkened(0.3), 10))
	b.pressed.connect(cb)
	return b

func _solid(color: Color, radius: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	for m: String in ["left", "right", "top", "bottom"]:
		s.set("content_margin_" + m, 12)
	if radius > 0:
		s.set_corner_radius_all(radius)
	return s

func _card_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_PANEL
	s.set_border_width_all(2)
	s.border_color = C_EDGE
	s.set_corner_radius_all(20)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 16
	return s
