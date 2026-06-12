class_name Board
extends RefCounted
## Headless rules engine for one room. Pure logic + an ordered `events` log for
## the renderer; no nodes, no real-time. Drive it through discrete entry points —
## move_player(), toggle_switch(), gravity_step(). The renderer replays `events`
## to animate; tests assert the resulting board (often via to_ascii()).
##
## Prod behaviour is the default: `invincible` starts false, so tests never depend
## on the INVINCIBLE dev toggle. The game scene copies the live Tuning toggle in
## before play.

enum Terrain { EMPTY, WALL, DIRT, TELEPORTER, BREAKABLE_WALL, SWITCH, FLIP_WALL, FLIP_WALL_ACTIVE, GRAVITY_SWITCH }
enum Occupant { NONE, ROCK, BARREL, RED_KEY, BLUE_KEY }
enum Status { PLAYING, WON, LOST }

var width: int = 0
var height: int = 0
var terrain: Array = []            ## terrain[y][x] -> Terrain
var occupant: Array = []           ## occupant[y][x] -> Occupant
var player: Vector2i = Vector2i.ZERO
var facing: Vector2i = Vector2i.RIGHT

# Teleporter keys: a red and a blue key must both be pushed/dropped into the
# teleporter to unlock it. `first_color` records which arrived first (drives the
# multilock -> redopen/blueopen art).
var red_delivered: bool = false
var blue_delivered: bool = false
var first_color: String = ""       ## "red" | "blue" | ""
var keys_lost: int = 0             ## a teleporter key destroyed before delivery
var unwinnable: bool = false       ## a teleporter key was destroyed -> can't finish; offer restart

var status: int = Status.PLAYING
var lose_reason: String = ""

var invincible: bool = false
var explosion_radius: int = Tuning.EXPLOSION_RADIUS

## Flip-wall phase, toggled by standing on a switch. When false (the start state)
## FLIP_WALL tiles are open and FLIP_WALL_ACTIVE tiles are solid; throwing the
## switch flips the phase and swaps every toggle wall to its other state.
var flip_active: bool = false

## Gravity phase, toggled by standing on a gravity switch. When true, objects
## fall UP instead of down.
var gravity_reversed: bool = false

var events: Array[Dictionary] = []
## Positions of objects that moved DOWN on the previous gravity tick (have
## downward momentum). Only a moving object reacts on impact, so a rock resting
## above Francis Scott is safe but one that drops onto him is not.
var _falling: Dictionary = {}

# =============================================================================
# Construction
# =============================================================================
## Build a board from an ASCII layout. Used directly by tests and by the level
## loader.
static func from_ascii(layout: String) -> Board:
	var b := Board.new()
	var lines: PackedStringArray = layout.replace("\r", "").split("\n")
	# Drop leading/trailing fully-empty lines so a """ block """ layout parses cleanly.
	while lines.size() > 0 and lines[0].strip_edges() == "":
		lines.remove_at(0)
	while lines.size() > 0 and lines[lines.size() - 1].strip_edges() == "":
		lines.remove_at(lines.size() - 1)

	b.height = lines.size()
	b.width = 0
	for line: String in lines:
		b.width = maxi(b.width, line.length())

	for y: int in range(b.height):
		var trow: Array = []
		var orow: Array = []
		trow.resize(b.width)
		orow.resize(b.width)
		var line: String = lines[y]
		for x: int in range(b.width):
			var glyph: String = line.substr(x, 1) if x < line.length() else "."
			b._place_glyph(Vector2i(x, y), glyph, trow, orow)
		b.terrain.append(trow)
		b.occupant.append(orow)

	return b

func _place_glyph(pos: Vector2i, glyph: String, trow: Array, orow: Array) -> void:
	trow[pos.x] = Terrain.EMPTY
	orow[pos.x] = Occupant.NONE
	match TileTypes.id_from_glyph(glyph):
		TileTypes.Id.WALL: trow[pos.x] = Terrain.WALL
		TileTypes.Id.BREAKABLE_WALL: trow[pos.x] = Terrain.BREAKABLE_WALL
		TileTypes.Id.DIRT: trow[pos.x] = Terrain.DIRT
		TileTypes.Id.TELEPORTER: trow[pos.x] = Terrain.TELEPORTER
		TileTypes.Id.SWITCH: trow[pos.x] = Terrain.SWITCH
		TileTypes.Id.GRAVITY_SWITCH: trow[pos.x] = Terrain.GRAVITY_SWITCH
		TileTypes.Id.FLIP_WALL: trow[pos.x] = Terrain.FLIP_WALL
		TileTypes.Id.FLIP_WALL_ACTIVE: trow[pos.x] = Terrain.FLIP_WALL_ACTIVE
		TileTypes.Id.ROCK: orow[pos.x] = Occupant.ROCK
		TileTypes.Id.BARREL: orow[pos.x] = Occupant.BARREL
		TileTypes.Id.RED_KEY: orow[pos.x] = Occupant.RED_KEY
		TileTypes.Id.BLUE_KEY: orow[pos.x] = Occupant.BLUE_KEY
		TileTypes.Id.FRANCIS_SCOTT_START:
			player = pos
		_:
			pass  # EMPTY / spaces / unknown -> empty floor

# =============================================================================
# Queries
# =============================================================================
func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.x < width and p.y >= 0 and p.y < height

func terrain_at(p: Vector2i) -> int:
	return terrain[p.y][p.x]

func occupant_at(p: Vector2i) -> int:
	return occupant[p.y][p.x]

func _set_occ(p: Vector2i, v: int) -> void:
	occupant[p.y][p.x] = v

func player_at(p: Vector2i) -> bool:
	return player == p

## Is this terrain a toggle wall that is currently in its SOLID state? FLIP_WALL is
## solid once the switch is thrown; FLIP_WALL_ACTIVE is solid until it is thrown.
func _flip_wall_solid(t: int) -> bool:
	if t == Terrain.FLIP_WALL:
		return flip_active
	if t == Terrain.FLIP_WALL_ACTIVE:
		return not flip_active
	return false

## Open terrain an object can rest in or fall through: empty, teleporter, switch
## (physics-wise empty), and a toggle wall while it is OPEN.
func _is_floor(t: int) -> bool:
	if t == Terrain.EMPTY or t == Terrain.TELEPORTER or t == Terrain.SWITCH or t == Terrain.GRAVITY_SWITCH:
		return true
	if t == Terrain.FLIP_WALL or t == Terrain.FLIP_WALL_ACTIVE:
		return not _flip_wall_solid(t)
	return false

## A cell nothing currently occupies: open floor, no occupant, no player.
func is_open(p: Vector2i) -> bool:
	return in_bounds(p) and _is_floor(terrain_at(p)) \
		and occupant_at(p) == Occupant.NONE and not player_at(p)

## How many teleporter keys are still undelivered (0, 1, or 2).
func keys_remaining() -> int:
	return (0 if red_delivered else 1) + (0 if blue_delivered else 1)

## Locked until BOTH keys are delivered, then ACTIVE.
func teleporter_active() -> bool:
	return red_delivered and blue_delivered

func _is_teleporter_key(occ: int) -> bool:
	return occ == Occupant.RED_KEY or occ == Occupant.BLUE_KEY

func _occ_falls(occ: int) -> bool:
	return occ == Occupant.ROCK or occ == Occupant.BARREL or _is_teleporter_key(occ)

## The direction objects currently fall — down, or up while gravity is reversed.
func gravity_dir() -> Vector2i:
	return Vector2i.UP if gravity_reversed else Vector2i.DOWN

# =============================================================================
# Turn entry points
# =============================================================================
func _begin_turn() -> void:
	events = []

## Attempt to move Francis Scott one tile. Returns true if the move was accepted. Handles
## dirt-dig-on-entry, pushing and teleporter win. Gravity is NOT resolved here —
## it runs independently on its own tick, so the (faster) player can push or
## dodge things mid-fall.
func move_player(dir: Vector2i) -> bool:
	if status != Status.PLAYING:
		return false
	_begin_turn()
	facing = dir
	var dest: Vector2i = player + dir
	if not in_bounds(dest):
		return false

	var t: int = terrain_at(dest)
	if t == Terrain.WALL or t == Terrain.BREAKABLE_WALL or _flip_wall_solid(t):
		return false

	var occ: int = occupant_at(dest)
	if occ != Occupant.NONE:
		if occ == Occupant.ROCK or occ == Occupant.BARREL or _is_teleporter_key(occ):
			# Objects can't be pushed against gravity (up normally, down while
			# reversed), nor while they're mid-fall.
			if dir == -gravity_dir() or _falling.has(dest):
				return false
			var beyond: Vector2i = dest + dir
			if not is_open(beyond):
				return false
			_push(dest, beyond)
			_step_onto(dest)
		else:
			return false
	else:
		if t == Terrain.DIRT:
			terrain[dest.y][dest.x] = Terrain.EMPTY
			_emit({t = "dig", at = dest})
		_step_onto(dest)

	_check_win()
	return true

# =============================================================================
# Switches — flip walls and gravity reversal
# =============================================================================
## True when Francis Scott is standing on a switch (either kind) and toggling it is safe.
## A wall switch is refused while any toggle wall that WOULD become solid is
## occupied — you can't trap an object inside a wall. The gravity switch is always
## safe to flip.
func can_toggle_switch() -> bool:
	if status != Status.PLAYING:
		return false
	match terrain_at(player):
		Terrain.SWITCH:
			var next_phase: bool = not flip_active
			for y: int in range(height):
				for x: int in range(width):
					var c := Vector2i(x, y)
					var tc: int = terrain_at(c)
					# Would this toggle wall be solid AFTER the flip?
					var solid_after: bool = (tc == Terrain.FLIP_WALL and next_phase) \
						or (tc == Terrain.FLIP_WALL_ACTIVE and not next_phase)
					if solid_after and (occupant_at(c) != Occupant.NONE or player_at(c)):
						return false
			return true
		Terrain.GRAVITY_SWITCH:
			return true
	return false

## Throw the switch Francis Scott is standing on: flip every flip wall, or reverse gravity.
## Returns true if it toggled.
func toggle_switch() -> bool:
	if not can_toggle_switch():
		return false
	_begin_turn()
	match terrain_at(player):
		Terrain.SWITCH:
			flip_active = not flip_active
			_emit({t = "flip_toggled", active = flip_active})
		Terrain.GRAVITY_SWITCH:
			gravity_reversed = not gravity_reversed
			_falling = {}   # drop stale momentum; objects re-evaluate in the new direction
			_emit({t = "gravity_toggled", reversed = gravity_reversed})
	_check_win()
	return true

# =============================================================================
# Movement helpers
# =============================================================================
func _step_onto(dest: Vector2i) -> void:
	var from: Vector2i = player
	player = dest
	_emit({t = "player_move", from = from, to = dest})

## Move the pushable occupant from src to dst (already validated open). A red or
## blue key pushed into a teleporter is delivered instead of placed.
func _push(src: Vector2i, dst: Vector2i) -> void:
	var occ: int = occupant_at(src)
	_set_occ(src, Occupant.NONE)
	if terrain_at(dst) == Terrain.TELEPORTER and _is_teleporter_key(occ):
		_emit({t = "push", from = src, to = dst, kind = occ})
		_deliver_key(occ, dst)
		return
	_set_occ(dst, occ)
	_emit({t = "push", from = src, to = dst, kind = occ})

func _deliver_key(occ: int, at: Vector2i) -> void:
	var color: String = "red" if occ == Occupant.RED_KEY else "blue"
	if color == "red":
		red_delivered = true
	else:
		blue_delivered = true
	if first_color == "":
		first_color = color
	_emit({t = "deliver", at = at, color = color})
	if teleporter_active():
		_emit({t = "teleporter_active"})

# =============================================================================
# Gravity — real-time, ONE square per tick (driven by the renderer on a timer).
# =============================================================================
## Advance gravity by a single square: every unsupported movable moves one tile in
## the gravity direction (down, or UP while a gravity switch is active). Objects
## carry momentum (`_falling`) between ticks, so they react on impact the tick
## AFTER they land — which gives the (faster) player a window to dodge or push
## things clear. A falling rock/key crushes Francis Scott and detonates a barrel it lands
## on; a falling BARREL that lands on anything detonates itself.
## Returns true if anything moved or changed this tick.
func gravity_step() -> bool:
	if status != Status.PLAYING:
		return false
	_begin_turn()
	var gdir: Vector2i = gravity_dir()
	# Process rows so a column resolves one square per tick: nearest-to-the-floor
	# first (bottom-up when falling down, top-down when falling up).
	var rows: Array = range(height - 2, -1, -1) if gdir == Vector2i.DOWN else range(1, height)
	var moved_any: bool = false
	var next_falling: Dictionary = {}
	for y: int in rows:
		for x: int in range(width):
			var p: Vector2i = Vector2i(x, y)
			var occ: int = occupant_at(p)
			if occ == Occupant.NONE or not _occ_falls(occ):
				continue
			var dest: Vector2i = p + gdir
			var can_fall: bool = in_bounds(dest) and _is_floor(terrain_at(dest)) and is_open(dest)
			if can_fall:
				_set_occ(p, Occupant.NONE)
				if terrain_at(dest) == Terrain.TELEPORTER and _is_teleporter_key(occ):
					_emit({t = "fall", from = p, to = dest, kind = occ})
					_deliver_key(occ, dest)   # consumed -> no momentum
				else:
					_set_occ(dest, occ)
					_emit({t = "fall", from = p, to = dest, kind = occ})
					next_falling[dest] = true
				moved_any = true
			elif _falling.has(p):
				# Was in motion and is now blocked -> impact.
				if occ == Occupant.BARREL:
					_detonate(p)
					moved_any = true
				elif in_bounds(dest) and _resolve_impact(dest):
					moved_any = true
			if status != Status.PLAYING:
				_falling = next_falling
				return true
	_falling = next_falling
	_check_win()
	return moved_any

## A falling object is blocked by the content at `below`. Resolve the impact.
## Returns true if the board changed (so settling continues).
func _resolve_impact(below: Vector2i) -> bool:
	if player_at(below):
		if invincible:
			return false
		_kill_player("crush")
		return true
	if occupant_at(below) == Occupant.BARREL:
		_detonate(below)
		return true
	return false  # resting on a rock/key — supported, no impact

# =============================================================================
# Explosions
# =============================================================================
## Detonate the barrel at `center`, clearing a square of EXPLOSION_RADIUS:
## destroys dirt, breakable walls, rocks and keys, kills Francis Scott, and chain-detonates
## other barrels caught in the blast. Walls and teleporters survive.
func _detonate(center: Vector2i) -> void:
	var queue: Array[Vector2i] = [center]
	var detonated: Dictionary = {center: true}
	var blast_cells: Array[Vector2i] = []
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		_set_occ(c, Occupant.NONE)  # the barrel itself is consumed
		_emit({t = "remove", at = c})  # so the renderer dissolves THIS barrel, not whatever later occupies the cell
		for dy: int in range(-explosion_radius, explosion_radius + 1):
			for dx: int in range(-explosion_radius, explosion_radius + 1):
				var cell: Vector2i = c + Vector2i(dx, dy)
				if not in_bounds(cell):
					continue
				if not blast_cells.has(cell):
					blast_cells.append(cell)
				_clear_cell(cell)
				if occupant_at(cell) == Occupant.BARREL and not detonated.has(cell):
					detonated[cell] = true
					queue.append(cell)
	_emit({t = "explode", center = center, cells = blast_cells})

## Apply a single blast cell's effect. Barrels are left for the chain queue.
func _clear_cell(cell: Vector2i) -> void:
	if player_at(cell) and not invincible:
		_kill_player("explosion")
	# Explosions clear dirt and breakable walls (regular walls survive).
	if terrain_at(cell) == Terrain.DIRT or terrain_at(cell) == Terrain.BREAKABLE_WALL:
		terrain[cell.y][cell.x] = Terrain.EMPTY
		_emit({t = "dig", at = cell})
	match occupant_at(cell):
		Occupant.ROCK:
			_set_occ(cell, Occupant.NONE)
			_emit({t = "remove", at = cell})
		Occupant.RED_KEY, Occupant.BLUE_KEY:
			# Destroying a teleporter key before delivery makes the level unwinnable.
			_set_occ(cell, Occupant.NONE)
			keys_lost += 1
			unwinnable = true
			_emit({t = "remove", at = cell})

# =============================================================================
# Win / lose
# =============================================================================
func _check_win() -> void:
	if status != Status.PLAYING:
		return
	if terrain_at(player) == Terrain.TELEPORTER and teleporter_active():
		status = Status.WON
		_emit({t = "won"})

func _kill_player(reason: String) -> void:
	if invincible:
		return
	_lose(reason)

func _lose(reason: String) -> void:
	status = Status.LOST
	lose_reason = reason
	_emit({t = "lost", reason = reason})

func _emit(e: Dictionary) -> void:
	events.append(e)

# =============================================================================
# Snapshot / restore (used by restart) and debug rendering
# =============================================================================
func snapshot() -> Dictionary:
	var t_copy: Array = []
	var o_copy: Array = []
	for row: Array in terrain:
		t_copy.append(row.duplicate())
	for row: Array in occupant:
		o_copy.append(row.duplicate())
	return {
		terrain = t_copy, occupant = o_copy, player = player, facing = facing,
		red_delivered = red_delivered, blue_delivered = blue_delivered,
		first_color = first_color, keys_lost = keys_lost, flip_active = flip_active,
		gravity_reversed = gravity_reversed,
		unwinnable = unwinnable, status = status, lose_reason = lose_reason,
	}

func restore(s: Dictionary) -> void:
	terrain = []
	occupant = []
	for row: Array in s["terrain"]:
		terrain.append(row.duplicate())
	for row: Array in s["occupant"]:
		occupant.append(row.duplicate())
	player = s["player"]
	facing = s["facing"]
	red_delivered = s["red_delivered"]
	blue_delivered = s["blue_delivered"]
	first_color = s["first_color"]
	keys_lost = s["keys_lost"]
	flip_active = s["flip_active"]
	gravity_reversed = s["gravity_reversed"]
	unwinnable = s["unwinnable"]
	status = s["status"]
	lose_reason = s["lose_reason"]
	_falling = {}
	events = []

## Render the current state back to ASCII (player > occupant > terrain),
## mirroring the input legend. Invaluable for exact-match assertions in tests.
func to_ascii() -> String:
	var rows: PackedStringArray = []
	for y: int in range(height):
		var line: String = ""
		for x: int in range(width):
			var p: Vector2i = Vector2i(x, y)
			line += _glyph_at(p)
		rows.append(line)
	return "\n".join(rows)

func _glyph_at(p: Vector2i) -> String:
	if player_at(p):
		return TileTypes.glyph_of(TileTypes.Id.FRANCIS_SCOTT_START)
	match occupant_at(p):
		Occupant.ROCK: return TileTypes.glyph_of(TileTypes.Id.ROCK)
		Occupant.BARREL: return TileTypes.glyph_of(TileTypes.Id.BARREL)
		Occupant.RED_KEY: return TileTypes.glyph_of(TileTypes.Id.RED_KEY)
		Occupant.BLUE_KEY: return TileTypes.glyph_of(TileTypes.Id.BLUE_KEY)
	match terrain_at(p):
		Terrain.WALL: return TileTypes.glyph_of(TileTypes.Id.WALL)
		Terrain.BREAKABLE_WALL: return TileTypes.glyph_of(TileTypes.Id.BREAKABLE_WALL)
		Terrain.DIRT: return TileTypes.glyph_of(TileTypes.Id.DIRT)
		Terrain.TELEPORTER: return TileTypes.glyph_of(TileTypes.Id.TELEPORTER)
		Terrain.SWITCH: return TileTypes.glyph_of(TileTypes.Id.SWITCH)
		Terrain.GRAVITY_SWITCH: return TileTypes.glyph_of(TileTypes.Id.GRAVITY_SWITCH)
		Terrain.FLIP_WALL: return TileTypes.glyph_of(TileTypes.Id.FLIP_WALL)
		Terrain.FLIP_WALL_ACTIVE: return TileTypes.glyph_of(TileTypes.Id.FLIP_WALL_ACTIVE)
	return TileTypes.glyph_of(TileTypes.Id.EMPTY)
