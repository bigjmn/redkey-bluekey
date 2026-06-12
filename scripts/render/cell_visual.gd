class_name CellVisual
extends Node2D
## A single drawn tile or entity. Most kinds come from the placeholder
## spritesheet (assets/spritesheet_complete.png, a Kenney-style pack, sliced on
## its 65px pitch / 64px cells); walls, dirt, the rock, the red/blue teleporter
## keys and the teleporter's multilock art use standalone assets. Origin is the
## CENTRE of the cell so the level renderer can tween one between cells. The
## explosion flash is drawn as a vector.

const SHEET := preload("res://assets/spritesheet_complete.png")
const BOULDER := preload("res://assets/stoneCaveRockLarge.png")
const METAL_WALL := preload("res://assets/metal_wall.png")
const GREEN_FLOOR := preload("res://assets/background_green.png")
const BREAKABLE := preload("res://assets/breakable_wall.png")
const REDKEY := preload("res://assets/redkey.png")
const BLUEKEY := preload("res://assets/bluekey.png")
const MULTILOCKS := preload("res://assets/multilocks.png")   ## both locks closed
const REDOPEN := preload("res://assets/redopen.png")         ## red lock opened
const BLUEOPEN := preload("res://assets/blueopen.png")       ## blue lock opened
const PLATFORM := preload("res://assets/purplePlatform.png") ## flip wall
const PURPLESWITCH := preload("res://assets/purpleswitch.png")
const GRAVITY_OFF := preload("res://assets/gravityreverseinactive.png")  ## gravity switch, inactive
const GRAVITY_ON := preload("res://assets/gravityreverseactive.png")     ## gravity switch, active
const JETPACK := preload("res://assets/jetpackBoy.png")      ## Francis Scott
const PITCH := 65   ## sheet cell pitch (64px cell + 1px gap)
const SRC := 64     ## sheet cell size

# Sourced from the Tuning constant (autoload access can't be a const expression).
var TILE: int = Tuning.TILE_SIZE
var HALF: float = Tuning.TILE_SIZE / 2.0

const C_TELE_GLOW := Color("52ffb8")

var kind: String = "floor"
var active: bool = false                ## teleporter fully unlocked (both keys in)
var tele_first: String = ""             ## "" | "red" | "blue" — which key arrived first
var facing: Vector2i = Vector2i.RIGHT   ## entity facing (sprites flip horizontally)

func setup(p_kind: String) -> void:
	kind = p_kind
	queue_redraw()

## Map a level-layout glyph to the draw kind (used by the editor to preview tiles).
## "." / unknown -> "" (nothing drawn, empty floor).
static func kind_for_glyph(g: String) -> String:
	match g:
		"#": return "wall"
		"B": return "breakable_wall"
		"D": return "dirt"
		"R": return "rock"
		"X": return "barrel"
		"T": return "teleporter"
		"W": return "switch"
		"G": return "gravity_switch"
		"P": return "flip_wall"
		"Q": return "flip_wall_active"
		"1": return "red_key"
		"2": return "blue_key"
		"A": return "player"
		_: return ""

## Teleporter art: multilocks (none), redopen/blueopen (first key), + glow once active.
func set_teleporter(first_color: String, is_active: bool) -> void:
	if tele_first != first_color or active != is_active:
		tele_first = first_color
		active = is_active
		queue_redraw()

## Phase flag for the switch (flipped when active) and flip walls (solid vs faint).
func set_active(v: bool) -> void:
	if active != v:
		active = v
		queue_redraw()

func set_facing(dir: Vector2i) -> void:
	if dir != Vector2i.ZERO and dir != facing:
		facing = dir
		queue_redraw()

## Sheet region for a (row, col) cell.
func _reg(row: int, col: int) -> Rect2:
	return Rect2(col * PITCH, row * PITCH, SRC, SRC)

func _draw() -> void:
	match kind:
		"wall": _tex(METAL_WALL, 1.0)
		"breakable_wall": _tex(BREAKABLE, 1.0)
		"dirt": _tex(GREEN_FLOOR, 1.0)
		"flip_wall": _draw_flip_wall(active)            # starts open; solid when phase is active
		"flip_wall_active": _draw_flip_wall(not active)  # starts solid; open when phase is active
		"switch": _draw_switch()
		"gravity_switch": _tex(GRAVITY_ON if active else GRAVITY_OFF, 0.98)
		"teleporter":
			if tele_first == "red":
				_tex(REDOPEN, 1.0)
			elif tele_first == "blue":
				_tex(BLUEOPEN, 1.0)
			else:
				_tex(MULTILOCKS, 1.0)
			if active:  # both keys in — glow to invite Francis Scott
				draw_arc(Vector2.ZERO, HALF * 0.82, 0, TAU, 28, C_TELE_GLOW, 4.0, true)
		"red_key": _tex(REDKEY, 0.92)
		"blue_key": _tex(BLUEKEY, 0.92)
		"player": _tex_facing(JETPACK, 0.98)
		"barrel": _sheet(_reg(13, 10), 0.92)
		"rock": _tex(BOULDER, 0.96)
		"flash": _draw_flash()
		_:
			pass  # floor / empty -> show background

func _dest(scale_factor: float) -> Rect2:
	var s := TILE * scale_factor
	return Rect2(-s / 2.0, -s / 2.0, s, s)

func _sheet(region: Rect2, scale_factor: float) -> void:
	draw_texture_rect_region(SHEET, _dest(scale_factor), region)

func _tex(tex: Texture2D, scale_factor: float) -> void:
	draw_texture_rect(tex, _dest(scale_factor), false)

## Like _tex but mirrors horizontally when facing left (art faces right by default).
func _tex_facing(tex: Texture2D, scale_factor: float) -> void:
	if facing.x < 0:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1, 1))
	draw_texture_rect(tex, _dest(scale_factor), false)
	if facing.x < 0:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_flash() -> void:
	draw_circle(Vector2.ZERO, HALF * 1.4, Color(1.0, 0.85, 0.3, 0.9))
	draw_circle(Vector2.ZERO, HALF * 0.9, Color(1.0, 0.45, 0.1, 0.95))
	draw_circle(Vector2.ZERO, HALF * 0.4, Color(1.0, 1.0, 0.9, 1.0))

## Flip wall: solid purple platform when raised, faint (low opacity) when open.
func _draw_flip_wall(solid: bool) -> void:
	var a: float = 1.0 if solid else 0.3
	draw_texture_rect(PLATFORM, _dest(1.0), false, Color(1, 1, 1, a))

## Switch: purpleswitch art, mirrored horizontally when active (lever flips sides).
func _draw_switch() -> void:
	if active:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1, 1))
	draw_texture_rect(PURPLESWITCH, _dest(0.98), false)
	if active:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
