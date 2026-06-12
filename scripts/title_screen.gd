extends Control
## Title screen — the game's entry point. Title card art on top, then the four
## image buttons: Play (level selector), Rules (instructions modal over this
## screen), Social (profile page), and Level Editor. Built in code so the scene
## file stays trivial.

const DUNGEON_BG := preload("res://assets/dungeonbackground.png")
const TITLECARD := preload("res://assets/titlecard.png")
const BTN_PLAY := preload("res://assets/playbutton.png")
const BTN_RULES := preload("res://assets/rulesbutton.png")
const BTN_SOCIAL := preload("res://assets/socialbutton.png")
const BTN_EDITOR := preload("res://assets/leveleditbutton.png")

const CARD_SIZE := Vector2(660, 440)   ## titlecard.png is 3:2
const BTN_SIZE := Vector2(460, 140)    ## button art is ~10:3

func _ready() -> void:
	var bg := TextureRect.new()
	bg.texture = DUNGEON_BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	center.add_child(col)

	var card := TextureRect.new()
	card.texture = TITLECARD
	card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	card.custom_minimum_size = CARD_SIZE
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(card)

	col.add_child(_image_button(BTN_PLAY, _go_play))
	col.add_child(_image_button(BTN_RULES, _open_rules))
	col.add_child(_image_button(BTN_SOCIAL, _go_social))
	col.add_child(_image_button(BTN_EDITOR, _go_editor))

func _image_button(tex: Texture2D, cb: Callable) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = tex
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.custom_minimum_size = BTN_SIZE
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _go_play() -> void:
	get_tree().change_scene_to_file("res://scenes/level_select.tscn")

func _open_rules() -> void:
	# The modal blurs/overlays this screen and frees itself when dismissed.
	add_child(Instructions.new())

func _go_social() -> void:
	get_tree().change_scene_to_file("res://scenes/social/ProfileScreen.tscn")

func _go_editor() -> void:
	get_tree().change_scene_to_file("res://scenes/editor.tscn")
