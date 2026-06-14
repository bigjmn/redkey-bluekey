extends Node2D
## Level renderer + input + tick driver for ONE room. Owns a headless Board and
## reflects it: terrain is rebuilt each turn, while Francis Scott and falling objects are
## persistent CellVisual nodes tweened by replaying board.events.
## Emits high-level signals; the Game controller handles progression/UI.

const CellVisualScene := preload("res://scripts/render/cell_visual.gd")

signal turn_taken
signal state_changed
signal won
signal lost(reason: String)
signal became_unwinnable

var TILE: int = Tuning.TILE_SIZE

var board: Board = null
var _initial_snapshot: Dictionary = {}
var _gravity_accum: float = 0.0    ## drives one gravity square per FALL_DURATION

var _terrain_root: Node2D
var _occ_root: Node2D
var _entity_root: Node2D
var occ_nodes: Dictionary = {}     ## Vector2i -> CellVisual
var _player_node: CellVisual = null

## How many attempts this level has taken — 1 on first load, +1 on every restart
## (a death or a manual restart). Reported in the level-complete message.
var attempts: int = 1

var _input_lock: float = 0.0       ## brief lock so rapid input can't skip a player tween
var _status_signaled: bool = false
var _unwinnable_signaled: bool = false

# Batch tween bookkeeping (one tween per node per event batch).
var _pend: Dictionary = {}
var _durs: Dictionary = {}
var _node_tweens: Dictionary = {}   ## node -> active movement Tween
var _pending_deferred: Array = []   ## destruction waiting for movement to finish
var _deferred_tween: Tween = null   ## timer tween that will fire it

func _ready() -> void:
	_ensure_built()
	set_process(true)

## Create the render roots once. Called from _ready and setup() because node
## _ready timing isn't guaranteed before the controller calls setup().
func _ensure_built() -> void:
	if _terrain_root != null:
		return
	_terrain_root = Node2D.new()
	_terrain_root.name = "Terrain"
	add_child(_terrain_root)
	_occ_root = Node2D.new()
	_occ_root.name = "Occupants"
	add_child(_occ_root)
	_entity_root = Node2D.new()
	_entity_root.name = "Entities"
	add_child(_entity_root)

# =============================================================================
# Setup / rebuild
# =============================================================================
func setup(b: Board) -> void:
	_ensure_built()
	board = b
	_initial_snapshot = b.snapshot()
	_gravity_accum = 0.0
	_status_signaled = false
	_unwinnable_signaled = false
	_rebuild_all()
	state_changed.emit()

func _rebuild_all() -> void:
	for d: Node in [_occ_root, _entity_root]:
		for c: Node in d.get_children():
			c.queue_free()
	occ_nodes.clear()
	_node_tweens.clear()
	_cancel_deferred()
	_rebuild_terrain()
	# Occupants
	for y: int in range(board.height):
		for x: int in range(board.width):
			var cell := Vector2i(x, y)
			var occ := board.occupant_at(cell)
			var kind := _occ_kind(occ)
			if kind != "":
				var node := _spawn(_occ_root, kind, cell)
				occ_nodes[cell] = node
	# Player
	_player_node = _spawn(_entity_root, "player", board.player)
	_player_node.set_facing(board.facing)
	queue_redraw()

func _rebuild_terrain() -> void:
	for c: Node in _terrain_root.get_children():
		c.queue_free()
	var active := board.teleporter_active()
	for y: int in range(board.height):
		for x: int in range(board.width):
			var cell := Vector2i(x, y)
			var kind := _terrain_kind(board.terrain_at(cell))
			if kind == "":
				continue
			var node := _spawn(_terrain_root, kind, cell)
			if kind == "teleporter":
				node.set_teleporter(board.first_color, active)
			elif kind == "switch" or kind == "flip_wall" or kind == "flip_wall_active":
				node.set_active(board.flip_active)
			elif kind == "gravity_switch":
				node.set_active(board.gravity_reversed)

func _spawn(parent: Node2D, kind: String, cell: Vector2i) -> CellVisual:
	var node := CellVisualScene.new() as CellVisual
	node.setup(kind)
	node.position = _world(cell)
	parent.add_child(node)
	return node

func _world(cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * TILE, (cell.y + 0.5) * TILE)

func _terrain_kind(t: int) -> String:
	match t:
		Board.Terrain.WALL: return "wall"
		Board.Terrain.BREAKABLE_WALL: return "breakable_wall"
		Board.Terrain.DIRT: return "dirt"
		Board.Terrain.TELEPORTER: return "teleporter"
		Board.Terrain.SWITCH: return "switch"
		Board.Terrain.GRAVITY_SWITCH: return "gravity_switch"
		Board.Terrain.FLIP_WALL: return "flip_wall"
		Board.Terrain.FLIP_WALL_ACTIVE: return "flip_wall_active"
		_: return ""  # EMPTY -> show background

func _occ_kind(o: int) -> String:
	match o:
		Board.Occupant.ROCK: return "rock"
		Board.Occupant.BARREL: return "barrel"
		Board.Occupant.RED_KEY: return "red_key"
		Board.Occupant.BLUE_KEY: return "blue_key"
		_: return ""

# =============================================================================
# Responsive fit — scale + centre the board into a screen rect.
# =============================================================================
func fit_to_rect(rect: Rect2) -> void:
	if board == null:
		return
	var board_px := Vector2(board.width * TILE, board.height * TILE)
	if board_px.x <= 0.0 or board_px.y <= 0.0:
		return
	var s: float = minf(rect.size.x / board_px.x, rect.size.y / board_px.y)
	scale = Vector2(s, s)
	position = rect.position + (rect.size - board_px * s) * 0.5

# =============================================================================
# Public actions (also wired to on-screen buttons by the Game controller)
# =============================================================================
func request_move(dir: Vector2i) -> void:
	if not _can_act():
		return
	if board.move_player(dir):
		_input_lock = Tuning.STEP_DURATION
		_apply_events(board.events)
		_post_action()

## True when Francis Scott can toggle the switch he's standing on (drives the UI option).
func can_switch() -> bool:
	return board != null and board.can_toggle_switch()

func request_switch() -> void:
	if board == null or _input_lock > 0.0:
		return
	if board.toggle_switch():
		_input_lock = Tuning.STEP_DURATION
		_apply_events(board.events)
		_post_action()

func restart() -> void:
	Sfx.play("lose")
	attempts += 1
	board.restore(_initial_snapshot)
	_gravity_accum = 0.0
	_status_signaled = false
	_unwinnable_signaled = false
	_rebuild_all()
	state_changed.emit()

func _can_act() -> bool:
	return board != null and board.status == Board.Status.PLAYING and _input_lock <= 0.0

func _post_action() -> void:
	turn_taken.emit()
	state_changed.emit()
	_check_unwinnable()
	_check_status()

# =============================================================================
# Per-frame: gravity ticks.
# =============================================================================
func _process(delta: float) -> void:
	if board == null:
		return
	if _input_lock > 0.0:
		_input_lock -= delta
	if board.status != Board.Status.PLAYING:
		return

	# Gravity ticks once per FALL_DURATION: each unsupported object drops one
	# square, independent of the player's (much faster) steps.
	_gravity_accum += delta
	if _gravity_accum >= Tuning.FALL_DURATION:
		_gravity_accum -= Tuning.FALL_DURATION
		if board.gravity_step():
			_apply_events(board.events)
		_check_unwinnable()
		_check_status()
		if board.status != Board.Status.PLAYING:
			return

	queue_redraw()

func _check_status() -> void:
	if _status_signaled or board.status == Board.Status.PLAYING:
		return
	_status_signaled = true
	if board.status == Board.Status.WON:
		won.emit()
	else:
		lost.emit(board.lose_reason)

func _check_unwinnable() -> void:
	if board.unwinnable and not _unwinnable_signaled:
		_unwinnable_signaled = true
		became_unwinnable.emit()

# =============================================================================
# Event replay -> tweens. One tween per node per batch.
# =============================================================================
func _apply_events(evs: Array) -> void:
	# Complete any destruction still pending from the previous turn before mutating
	# the view again, so a fast follow-up move can't desync. Input is NOT locked for
	# the fall/explosion — only for the player's own step — so controls stay snappy.
	_flush_deferred()
	_pend = {}
	_durs = {}
	var deferred: Array = []
	for e: Dictionary in evs:
		_apply_one(e, deferred)
	# Start movement tweens; track the longest so consequences wait for it.
	var max_dur: float = 0.0
	for node: CellVisual in _pend:
		if is_instance_valid(node):
			_animate(node, _pend[node])
			max_dur = maxf(max_dur, _durs[node])
	_rebuild_terrain()
	# Destruction (deliveries, pickups, kills, explosions) plays AFTER the objects
	# have visibly moved — e.g. a barrel falls all the way down, THEN detonates.
	if not deferred.is_empty():
		if max_dur <= 0.0:
			_run_deferred(deferred)
		else:
			_pending_deferred = deferred
			_deferred_tween = create_tween()
			_deferred_tween.tween_interval(max_dur)
			_deferred_tween.tween_callback(_fire_deferred)

## Run the destruction queued for the current turn (called by the timer tween).
func _fire_deferred() -> void:
	var d: Array = _pending_deferred
	_pending_deferred = []
	_deferred_tween = null
	_run_deferred(d)

## Force any pending destruction to complete now (new turn starting).
func _flush_deferred() -> void:
	if _deferred_tween != null and is_instance_valid(_deferred_tween):
		_deferred_tween.kill()
		_deferred_tween = null
	if not _pending_deferred.is_empty():
		_fire_deferred()

## Drop pending destruction without running it (board was reset via undo/restart).
func _cancel_deferred() -> void:
	if _deferred_tween != null and is_instance_valid(_deferred_tween):
		_deferred_tween.kill()
	_deferred_tween = null
	_pending_deferred = []

## Tween a node along its path — one segment per push/fall event, played in
## order — so a pushed object completes its HORIZONTAL slide before it starts to
## fall (no diagonal cut through the cell below). Linear so multi-tile falls flow
## at constant speed. Replaces any tween already running on the node; each
## segment starts from where the previous left off (its current position).
func _animate(node: CellVisual, segments: Array) -> void:
	if _node_tweens.has(node) and is_instance_valid(_node_tweens[node]):
		_node_tweens[node].kill()
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_LINEAR)
	for seg: Dictionary in segments:
		tw.tween_property(node, "position", seg["to"], seg["dur"])
	_node_tweens[node] = tw

func _apply_one(e: Dictionary, deferred: Array) -> void:
	match e["t"]:
		"player_move":
			_player_node.set_facing(e["to"] - e["from"])
			_queue_tween(_player_node, e["to"], Tuning.STEP_DURATION)
		"push", "fall":
			_relocate_occ(e["from"], e["to"])
			if occ_nodes.has(e["to"]):
				# A push slides over STEP_DURATION; a one-square fall drops quickly
				# and then sits, so it visibly pauses each square (the gravity timer
				# only ticks again after FALL_DURATION).
				var is_fall: bool = e["from"].y != e["to"].y
				var dur: float = Tuning.FALL_DURATION * 0.4 if is_fall else Tuning.STEP_DURATION
				_queue_tween(occ_nodes[e["to"]], e["to"], dur)
		"deliver", "remove":
			if e["t"] == "deliver":
				Sfx.play("powerUp")        # a needed key reached the gate
			# Capture the node being destroyed NOW (by board-event order), not by a
			# cell lookup when the deferred fires — otherwise an unrelated object that
			# falls into this cell meanwhile would be dissolved in its place.
			var node := _detach_occ(e["at"])
			if node != null:
				deferred.append({k = "node", node = node})
		"land":
			Sfx.play("itemFall")           # a rock/key came to rest
		"explode":
			Sfx.play("explosion")
			# Just the flash. The objects/barrels actually destroyed each emit their
			# own "remove" above, so we never dissolve survivors caught over the blast.
			deferred.append({k = "flash", cells = e["cells"]})
		"flip_toggled":
			Sfx.play("switch")
		"gravity_toggled":
			Sfx.play("gravityUp" if e["reversed"] else "gravityDown")
		"won":
			Sfx.play("win")
		"lost":
			Sfx.play("lose")

## Run the destruction phase once movement has settled.
func _run_deferred(actions: Array) -> void:
	for a: Dictionary in actions:
		match a["k"]:
			"node":
				if is_instance_valid(a["node"]):
					_dissolve(a["node"])
			"flash":
				_spawn_flash(a["cells"])

## Append one path segment for this node (each push/fall is its own segment, so
## the animation traces the actual route rather than a straight diagonal).
func _queue_tween(node: CellVisual, cell: Vector2i, dur: float) -> void:
	if not _pend.has(node):
		_pend[node] = []
	_pend[node].append({to = _world(cell), dur = maxf(dur, 0.01)})
	_durs[node] = _durs.get(node, 0.0) + dur

func _relocate_occ(from: Vector2i, to: Vector2i) -> void:
	if not occ_nodes.has(from):
		return
	var node: CellVisual = occ_nodes[from]
	occ_nodes.erase(from)
	occ_nodes[to] = node

## Detach the occupant node at `at` from the live grid and return it (or null).
## Caller dissolves it later; detaching now means a subsequent relocation into this
## cell rebinds occ_nodes to the NEW node, leaving the captured one untouched.
func _detach_occ(at: Vector2i) -> CellVisual:
	if not occ_nodes.has(at):
		return null
	var node: CellVisual = occ_nodes[at]
	occ_nodes.erase(at)
	_pend.erase(node)
	_durs.erase(node)
	return node

func _dissolve(node: CellVisual) -> void:
	if _node_tweens.has(node) and is_instance_valid(_node_tweens[node]):
		_node_tweens[node].kill()
	_node_tweens.erase(node)
	var tw := node.create_tween()
	tw.tween_property(node, "scale", Vector2.ZERO, Tuning.STEP_DURATION)
	tw.tween_callback(node.queue_free)

func _spawn_flash(cells: Array) -> void:
	for c: Vector2i in cells:
		var f := _spawn(_entity_root, "flash", c)
		f.scale = Vector2(0.3, 0.3)
		var tw := f.create_tween()
		tw.set_parallel(true)
		tw.tween_property(f, "scale", Vector2.ONE, Tuning.FALL_DURATION * 3.0)
		tw.tween_property(f, "modulate:a", 0.0, Tuning.FALL_DURATION * 3.0)
		tw.chain().tween_callback(f.queue_free)

# =============================================================================
# Input
# =============================================================================
var _touch_start: Vector2 = Vector2.ZERO
var _touch_index: int = -1     ## id of the finger driving the current swipe (-1 = none)
var _saw_touch: bool = false   ## a real touch arrived -> ignore emulated mouse events

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_UP, KEY_W: request_move(Vector2i.UP)
			KEY_DOWN, KEY_S: request_move(Vector2i.DOWN)
			KEY_LEFT, KEY_A: request_move(Vector2i.LEFT)
			KEY_RIGHT, KEY_D: request_move(Vector2i.RIGHT)
			KEY_SPACE, KEY_ENTER: request_switch()
			KEY_R: restart()
	elif event is InputEventScreenTouch:
		_saw_touch = true
		_handle_pointer(event.pressed, event.position, event.index)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not _saw_touch:
		# Desktop mouse-drag swipe (only when the device isn't sending real touch).
		_handle_pointer(event.pressed, event.position, 0)

## Track a single pointer: the first finger down starts the swipe, other fingers
## are ignored, and the release of that finger resolves the direction.
func _handle_pointer(pressed: bool, pos: Vector2, index: int) -> void:
	if pressed:
		if _touch_index == -1:
			_touch_index = index
			_touch_start = pos
	elif index == _touch_index:
		_touch_index = -1
		var dir := Swipe.to_dir(pos - _touch_start, float(Tuning.SWIPE_THRESHOLD))
		if dir != Vector2i.ZERO:
			request_move(dir)

# =============================================================================
# Board backdrop + dev overlay — drawn in board-local space, behind the tiles
# (a Node2D's own _draw renders beneath its children).
# =============================================================================
func _draw() -> void:
	if board == null:
		return
	# Semi-opaque black panel under the whole grid so the board reads as its own
	# surface over the dungeon background.
	draw_rect(Rect2(Vector2.ZERO, Vector2(board.width * TILE, board.height * TILE)), Color(0, 0, 0, 0.95))
	if Tuning.show_grid_overlay:
		var grid := Color(1, 1, 1, 0.08)
		for x: int in range(board.width + 1):
			draw_line(Vector2(x * TILE, 0), Vector2(x * TILE, board.height * TILE), grid, 1.0)
		for y: int in range(board.height + 1):
			draw_line(Vector2(0, y * TILE), Vector2(board.width * TILE, y * TILE), grid, 1.0)
