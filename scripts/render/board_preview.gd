class_name BoardPreview
extends Control
## A small, STATIC thumbnail of a puzzle's initial state, rendered from its ASCII
## layout by reusing CellVisual tiles (no Board, no gravity, no animation). Shown
## on challenge rows so each challenge previews its board (cf. a chess app showing
## the position next to the game).
##
## Grid look matches the level editor: a bright backing shows between dark, inset
## cells as distinct dividing lines (C_GRID_LINE / C_CELL, same as level_editor.gd).

const CellVisualScene := preload("res://scripts/render/cell_visual.gd")
const C_CELL := Color(0, 0, 0, 0.95)     ## dark board cell (matches the in-game/editor board)
const C_GRID_LINE := Color("7c92a8")     ## bright dividing lines between cells

var _w := 0
var _h := 0
var _box := 0.0
var _cell := 0.0          ## pixels per cell
var _off := Vector2.ZERO  ## top-left of the board area inside the square box
var _gap := 0.0           ## half the dividing-line width (inset on each cell edge)

## Render `layout` into a `box`×`box` square. Safe to call again to re-render.
func setup(layout: String, box: float = 240.0) -> void:
	custom_minimum_size = Vector2(box, box)
	clip_contents = true
	_box = box
	for c: Node in get_children():
		c.queue_free()

	var rows := layout.split("\n", false)
	_h = rows.size()
	_w = 0
	for r: String in rows:
		_w = maxi(_w, r.length())
	if _w == 0 or _h == 0:
		queue_redraw()
		return

	_cell = box / float(maxi(_w, _h))   # fit the longer axis
	_gap = maxf(1.0, _cell * 0.06)       # bright line = 2*_gap between cells
	# Centre the (possibly non-square) board inside the square box.
	_off = Vector2((box - _w * _cell) * 0.5, (box - _h * _cell) * 0.5)

	var holder := Node2D.new()
	add_child(holder)
	var tile := float(Tuning.TILE_SIZE)
	var fit := (_cell - 2.0 * _gap) / tile   # scale tiles to fill the inset (dark) cell
	for y: int in range(_h):
		var line: String = rows[y]
		for x: int in range(line.length()):
			var kind := CellVisual.kind_for_glyph(line[x])
			if kind == "":
				continue   # "." / spaces -> the dark cell shows through
			var cv := CellVisualScene.new() as CellVisual
			cv.setup(kind)
			cv.position = _off + Vector2((x + 0.5) * _cell, (y + 0.5) * _cell)
			cv.scale = Vector2(fit, fit)
			holder.add_child(cv)
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(_box, _box)), C_CELL)   # letterbox/base
	if _w == 0 or _h == 0:
		return
	# Bright backing across the board, then dark cells inset by _gap so the backing
	# reads as crisp dividing lines (the editor's technique).
	draw_rect(Rect2(_off, Vector2(_w, _h) * _cell), C_GRID_LINE)
	for y: int in range(_h):
		for x: int in range(_w):
			var p := _off + Vector2(x * _cell + _gap, y * _cell + _gap)
			draw_rect(Rect2(p, Vector2(_cell - 2.0 * _gap, _cell - 2.0 * _gap)), C_CELL)
