class_name SafeArea
extends RefCounted
## Device safe-area insets (notch / Dynamic Island / status bar / home indicator /
## rounded corners) expressed in the game's LOGICAL coordinate space, so UI built
## against the 720x1280 base stays clear of them on iOS.
##
## DisplayServer.get_display_safe_area() reports the safe rect in PHYSICAL pixels.
## We scale it into logical units with the live viewport/window ratio — and that
## ratio is exactly the iOS screen-scale factor, so this doubles as the per-device
## scale adjustment. On desktop the safe area == the whole window, so every inset
## is 0 and `apply()` becomes a no-op (nothing changes off-device).

## {left, top, right, bottom} in logical pixels, for a given logical viewport size.
static func insets_for(logical_size: Vector2) -> Dictionary:
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0 or logical_size.x <= 0.0 or logical_size.y <= 0.0:
		return {left = 0.0, top = 0.0, right = 0.0, bottom = 0.0}
	var safe := DisplayServer.get_display_safe_area()   # physical px
	var sx := logical_size.x / float(win.x)
	var sy := logical_size.y / float(win.y)
	return {
		left = maxf(0.0, float(safe.position.x)) * sx,
		top = maxf(0.0, float(safe.position.y)) * sy,
		right = maxf(0.0, float(win.x - (safe.position.x + safe.size.x))) * sx,
		bottom = maxf(0.0, float(win.y - (safe.position.y + safe.size.y))) * sy,
	}

## Insets using the root viewport's current logical size (for callers without a node).
static func insets() -> Dictionary:
	var size := Vector2(DisplayServer.window_get_size())
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		size = tree.root.get_visible_rect().size
	return insets_for(size)

## Anchor `control` to the full rect and inset it by the safe area (+ optional
## uniform extra padding). Use on a screen's UI/content root — NOT on full-bleed
## backgrounds, which should still reach the screen edges.
static func apply(control: Control, pad: float = 0.0) -> void:
	var i := insets()   # root-viewport based, so it works before `control` enters the tree
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.offset_left = i.left + pad
	control.offset_top = i.top + pad
	control.offset_right = -(i.right + pad)
	control.offset_bottom = -(i.bottom + pad)
