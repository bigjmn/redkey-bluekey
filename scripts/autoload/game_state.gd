extends Node
## GameState — run-wide progression (autoload singleton): the level library, the
## selected level, and the player's PERSISTED progress. Progress (how far they've
## unlocked) is saved to user:// so it survives across sessions. Honours the
## UNLOCK_ALL_LEVELS / START_LEVEL dev toggles via Tuning.

const SAVE_PATH := "user://progress.cfg"

var levels: Array[LevelData] = []
var current_index: int = 0

## Set just before entering game.tscn to play a friend's challenge instead of a
## regular level ({} = regular). The game controller consumes it on _ready.
var active_challenge: Dictionary = {}

## The frontier: the highest level id the player has unlocked (can play). Levels
## below it are completed; the level equal to it is "current"; higher are locked.
## Persisted to user://; defaults to 1 (only the first level open).
var highest_unlocked: int = 1

## Whether the player has seen the how-to-play instructions (drives the first-run
## auto-popup on the level selector). Persisted to user://.
var instructions_seen: bool = false

func _ready() -> void:
	reload_levels()
	load_progress()
	current_index = index_of_id(highest_unlocked)

func reload_levels() -> void:
	levels = LevelLoader.load_all()

# =============================================================================
# Persistence (user://)
# =============================================================================
func load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		highest_unlocked = maxi(1, int(cfg.get_value("progress", "highest_unlocked", 1)))
		instructions_seen = bool(cfg.get_value("progress", "instructions_seen", false))

func save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "highest_unlocked", highest_unlocked)
	cfg.set_value("progress", "instructions_seen", instructions_seen)
	cfg.save(SAVE_PATH)

## Remember that the how-to-play screen has been shown (so it won't auto-popup again).
func mark_instructions_seen() -> void:
	if not instructions_seen:
		instructions_seen = true
		save_progress()

# =============================================================================
# Progress queries
# =============================================================================
## Highest level id present in the library (0 if none).
func max_level_id() -> int:
	var m := 0
	for level: LevelData in levels:
		m = maxi(m, level.id)
	return m

func level_by_id(id: int) -> LevelData:
	for level: LevelData in levels:
		if level.id == id:
			return level
	return null

func is_unlocked_id(id: int) -> bool:
	return Tuning.unlock_all_levels or id <= highest_unlocked

func is_completed_id(id: int) -> bool:
	return id < highest_unlocked

func is_current_id(id: int) -> bool:
	return id == highest_unlocked

## Record a clear: unlock the next level and persist. No-op if already past it.
func mark_cleared(level: LevelData) -> void:
	if level == null:
		return
	if level.id >= highest_unlocked:
		highest_unlocked = level.id + 1
		save_progress()

# =============================================================================
# Level selection
# =============================================================================
func level_count() -> int:
	return levels.size()

func current_level() -> LevelData:
	if levels.is_empty():
		return null
	return levels[clampi(current_index, 0, levels.size() - 1)]

func index_of_id(id: int) -> int:
	for i: int in range(levels.size()):
		if levels[i].id == id:
			return i
	return 0

func get_by_code(code: String) -> LevelData:
	var wanted := code.strip_edges().to_upper()
	for level: LevelData in levels:
		if level.code.to_upper() == wanted:
			return level
	return null

func select(level: LevelData) -> void:
	var idx := levels.find(level)
	if idx >= 0:
		current_index = idx
