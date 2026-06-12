class_name LevelLoader
extends RefCounted
## ASCII -> Board loader, validation, and discovery of the level resources.

const LEVELS_DIR := "res://levels/"

## Returns "" when the layout is valid, else a human-readable reason.
## Rule: exactly one 'A', at least one 'T', and both teleporter keys ('1' red,
## '2' blue) so the exit can be unlocked.
static func validate(layout: String) -> String:
	var a := layout.count("A")
	if a != 1:
		return "layout must contain exactly one 'A' (Francis Scott spawn); found %d" % a
	if layout.count("T") < 1:
		return "layout must contain at least one 'T' (teleporter)"
	if layout.count("1") < 1:
		return "layout must contain a red key ('1')"
	if layout.count("2") < 1:
		return "layout must contain a blue key ('2')"
	return ""

## Build a Board from a LevelData. Returns null and pushes an error if the layout
## fails validation.
static func build_board(level: LevelData) -> Board:
	var err := validate(level.layout)
	if err != "":
		push_error("Invalid level %d (%s): %s" % [level.id, level.code, err])
		return null
	return Board.from_ascii(level.layout)

## Discover every level resource under res://levels/, sorted by id.
static func load_all() -> Array[LevelData]:
	var out: Array[LevelData] = []
	var dir := DirAccess.open(LEVELS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir():
			var clean := file.trim_suffix(".remap").trim_suffix(".import")
			if clean.ends_with(".tres") or clean.ends_with(".res"):
				var res := ResourceLoader.load(LEVELS_DIR + clean)
				if res is LevelData:
					out.append(res)
		file = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a: LevelData, b: LevelData) -> bool: return a.id < b.id)
	return out
