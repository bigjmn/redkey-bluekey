class_name TileTypes
extends RefCounted
## Collection: tile_types — every kind of cell on the board.
##
## Shared behaviour: tiles are DATA, not nodes; the board renders them.
## Movement, pushing and gravity all consult these flags. A tile may hold at
## most one movable occupant (rock/barrel/key) above an empty floor — the
## Board splits these ids into a terrain layer and an occupant layer at load,
## but the glyph<->id vocabulary lives here as the single source of truth.

enum Id {
	EMPTY,          ## "." walkable floor
	WALL,           ## "#" immovable boundary/obstacle
	DIRT,           ## "D" walkable, diggable
	ROCK,           ## "R" pushable, falls
	BARREL,         ## "X" pushable, falls, detonates on impact
	TELEPORTER,     ## "T" locked until both keys delivered, then active exit
	FRANCIS_SCOTT_START,     ## "A" Francis Scott's spawn; treated as empty floor after load
	BREAKABLE_WALL, ## "B" solid like a wall, but an explosion destroys it
	RED_KEY,        ## "1" pushable, falls, delivered to the teleporter (red lock)
	BLUE_KEY,       ## "2" pushable, falls, delivered to the teleporter (blue lock)
	SWITCH,         ## "W" stand on it to toggle the flip walls; physics-wise empty
	FLIP_WALL,      ## "P" toggle wall that starts OPEN (solid once the switch is thrown)
	FLIP_WALL_ACTIVE, ## "Q" toggle wall that starts SOLID (opens once the switch is thrown)
	GRAVITY_SWITCH, ## "G" stand on it to reverse gravity; physics-wise empty
}

## Per-tile flags keyed by Id. Mirrors the job's tile_types fields with their
## defaults (walkable/pushable/falls/diggable/deadly default false).
const DATA: Dictionary = {
	Id.EMPTY:      {glyph = ".", walkable = true,  pushable = false, falls = false, diggable = false, deadly = false},
	Id.WALL:       {glyph = "#", walkable = false, pushable = false, falls = false, diggable = false, deadly = false},
	Id.DIRT:       {glyph = "D", walkable = true,  pushable = false, falls = false, diggable = true,  deadly = false},
	Id.ROCK:       {glyph = "R", walkable = false, pushable = true,  falls = true,  diggable = false, deadly = false},
	Id.BARREL:     {glyph = "X", walkable = false, pushable = true,  falls = true,  diggable = false, deadly = false},
	Id.TELEPORTER: {glyph = "T", walkable = true,  pushable = false, falls = false, diggable = false, deadly = false},
	Id.FRANCIS_SCOTT_START: {glyph = "A", walkable = true,  pushable = false, falls = false, diggable = false, deadly = false},
	Id.BREAKABLE_WALL: {glyph = "B", walkable = false, pushable = false, falls = false, diggable = false, deadly = false},
	Id.RED_KEY:    {glyph = "1", walkable = false, pushable = true,  falls = true,  diggable = false, deadly = false},
	Id.BLUE_KEY:   {glyph = "2", walkable = false, pushable = true,  falls = true,  diggable = false, deadly = false},
	Id.SWITCH:     {glyph = "W", walkable = true,  pushable = false, falls = false, diggable = false, deadly = false},
	Id.FLIP_WALL:  {glyph = "P", walkable = false, pushable = false, falls = false, diggable = false, deadly = false},
	Id.FLIP_WALL_ACTIVE: {glyph = "Q", walkable = false, pushable = false, falls = false, diggable = false, deadly = false},
	Id.GRAVITY_SWITCH: {glyph = "G", walkable = true, pushable = false, falls = false, diggable = false, deadly = false},
}

static func glyph_of(id: int) -> String:
	return DATA[id]["glyph"]

static func id_from_glyph(glyph: String) -> int:
	for id: int in DATA:
		if DATA[id]["glyph"] == glyph:
			return id
	return -1

static func is_walkable(id: int) -> bool:
	return DATA.has(id) and DATA[id]["walkable"]

static func is_pushable(id: int) -> bool:
	return DATA.has(id) and DATA[id]["pushable"]

static func falls(id: int) -> bool:
	return DATA.has(id) and DATA[id]["falls"]

static func is_diggable(id: int) -> bool:
	return DATA.has(id) and DATA[id]["diggable"]
