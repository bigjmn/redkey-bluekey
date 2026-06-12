class_name SocialScreenBase
extends Control
## Shared chrome for the social screens (Profile / Friends / Challenges): the
## dungeon background, a title, a tab bar that navigates between the three
## screens, a scrollable content column, and a status line for async feedback.
## Subclasses override _screen_title() and _build_content(), and rebuild their
## lists from the FirebaseSocial signals. Deliberately plain Control UI —
## functional, easy to restyle or replace later.

const DUNGEON_BG := preload("res://assets/dungeonbackground.png")

const C_TEXT := Color("e9f5ee")
const C_SUB := Color("a7c6b5")
const C_ACCENT := Color("ffe08a")
const C_GREEN := Color("52ffb8")
const C_WARN := Color("ef476f")
const C_PANEL := Color(0, 0, 0, 0.78)
const C_BTN := Color("2a4a3a")

const TABS := [
	{label = "Profile", scene = "res://scenes/social/ProfileScreen.tscn"},
	{label = "Friends", scene = "res://scenes/social/FriendsScreen.tscn"},
	{label = "Challenges", scene = "res://scenes/social/ChallengesScreen.tscn"},
]

var content: VBoxContainer        ## subclasses build into this (inside a ScrollContainer)
var status_label: Label
var _chrome: VBoxContainer        ## whole screen UI (hidden by overlays like challenge play)

func _ready() -> void:
	_build_chrome()
	FirebaseSocial.social_error.connect(_on_social_error)
	_on_open()

func _exit_tree() -> void:
	if FirebaseSocial.social_error.is_connected(_on_social_error):
		FirebaseSocial.social_error.disconnect(_on_social_error)

## Override points -----------------------------------------------------------
func _screen_title() -> String:
	return "SOCIAL"

## Called once after the chrome exists — connect signals + kick off refreshes.
func _on_open() -> void:
	pass

# =============================================================================
# Chrome
# =============================================================================
func _build_chrome() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := TextureRect.new()
	bg.texture = DUNGEON_BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_chrome = VBoxContainer.new()
	_chrome.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chrome.offset_left = 20
	_chrome.offset_right = -20
	_chrome.offset_top = 20
	_chrome.offset_bottom = -20
	_chrome.add_theme_constant_override("separation", 12)
	add_child(_chrome)

	var title := _label(_screen_title(), 44, C_ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chrome.add_child(title)

	# Tab bar: the three social screens + back to the level selector.
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 8)
	_chrome.add_child(tabs)
	for tab: Dictionary in TABS:
		var current: bool = tab.label.to_upper() == _screen_title()
		var b := _button(tab.label, func(): _goto(tab.scene))
		if current:
			b.disabled = true
			b.add_theme_stylebox_override("disabled", _flat(C_ACCENT.darkened(0.45), 10))
		tabs.add_child(b)
	var back := _button("Back", func(): _goto("res://scenes/level_select.tscn"))
	tabs.add_child(back)

	status_label = _label("", 22, C_SUB)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chrome.add_child(status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chrome.add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 14)
	scroll.add_child(content)

func _goto(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)

func _on_social_error(message: String) -> void:
	set_status(message, true)

func set_status(msg: String, is_error: bool = false) -> void:
	status_label.text = msg
	status_label.add_theme_color_override("font_color", C_WARN if is_error else C_SUB)

# =============================================================================
# Small builders shared by the screens
# =============================================================================
func _label(text: String, size_px: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size_px)
	return l

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 60)
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_stylebox_override("normal", _flat(C_BTN, 10))
	b.add_theme_stylebox_override("hover", _flat(C_BTN.lightened(0.12), 10))
	b.add_theme_stylebox_override("pressed", _flat(C_GREEN.darkened(0.4), 10))
	b.pressed.connect(cb)
	return b

## A titled dark panel with a VBox inside; returns the VBox to fill.
func _section(title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(C_PANEL, 14))
	content.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var head := _label(title, 26, C_ACCENT)
	box.add_child(head)
	return box

## One list row: left-aligned text + optional action buttons on the right.
func _row(parent: Control, text: String, buttons: Array = []) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	parent.add_child(h)
	var l := _label(text, 23, C_TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	for spec: Dictionary in buttons:
		h.add_child(_button(spec.text, spec.cb))

func _clear(node: Control) -> void:
	for c: Node in node.get_children():
		c.queue_free()

func _flat(color: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	for m: String in ["left", "right", "top", "bottom"]:
		s.set("content_margin_" + m, 14)
	s.set_corner_radius_all(radius)
	return s
