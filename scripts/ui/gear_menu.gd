extends Node
## GearMenu (autoload): a gear button pinned to the bottom-right of EVERY screen
## (it lives on its own high CanvasLayer, which survives scene changes). Tapping
## it opens the SettingsModal. (The modal owns its own toggle state.)

const GEAR := preload("res://assets/gearicon.png")
const SettingsModalScript := preload("res://scripts/ui/settings_modal.gd")

var _layer: CanvasLayer
var _modal: Control = null

func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 120   # above every scene's own HUD/overlay layers
	add_child(_layer)

	# Full-rect, click-through holder so only the gear button itself catches input.
	var holder := Control.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(holder)

	var gear := TextureButton.new()
	gear.texture_normal = GEAR
	gear.ignore_texture_size = true
	gear.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	gear.focus_mode = Control.FOCUS_NONE
	gear.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	gear.offset_left = -90    # 72px box, 18px from the corner
	gear.offset_top = -90
	gear.offset_right = -18
	gear.offset_bottom = -18
	gear.pressed.connect(open)
	holder.add_child(gear)

## Show the settings modal (no-op if one is already up).
func open() -> void:
	if _modal != null and is_instance_valid(_modal):
		return
	_modal = SettingsModalScript.new()
	_layer.add_child(_modal)   # added after the gear -> drawn above it, dim covers it
