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

## Per-level progress (offline-first): id -> {attempts, cleared, cleared_at, updated_at}.
## Persisted to user:// and mirrored to users/{uid}/levels/LEVEL_<id> in Firestore
## via fire-and-forget sync (bump_attempt / _sync_level). `_unsynced` holds the ids
## whose latest local change hasn't been confirmed pushed yet — flushed on the next
## sign-in/reconnect, so progress made offline still reaches the backend.
var _levels: Dictionary = {}
var _unsynced: Dictionary = {}

## Per-challenge attempt counts (challengeId -> int). Tracked like level attempts —
## cumulative across leave/return — but only reported to the backend when the
## challenge is completed, so it's local-only (no sync queue).
var _challenge_attempts: Dictionary = {}

func _ready() -> void:
	reload_levels()
	load_progress()
	current_index = index_of_id(highest_unlocked)
	_init_sync.call_deferred()   # wire reconnect-sync once all autoloads exist

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
		_levels = cfg.get_value("levels", "data", {})
		_unsynced = {}
		for id: int in cfg.get_value("levels", "unsynced", []):
			_unsynced[id] = true
		_challenge_attempts = cfg.get_value("challenges", "attempts", {})

func save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "highest_unlocked", highest_unlocked)
	cfg.set_value("progress", "instructions_seen", instructions_seen)
	cfg.set_value("levels", "data", _levels)
	cfg.set_value("levels", "unsynced", _unsynced.keys())
	cfg.set_value("challenges", "attempts", _challenge_attempts)
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

## Record a clear: mark the level cleared (per-level record + sync), unlock the
## next level, and persist.
func mark_cleared(level: LevelData) -> void:
	if level == null:
		return
	mark_level_cleared(level.id)
	if level.id >= highest_unlocked:
		highest_unlocked = level.id + 1
		save_progress()

# =============================================================================
# Per-level progress (attempts + cleared) — offline-first, fire-and-forget sync
# =============================================================================
func level_attempts(id: int) -> int:
	return int((_levels.get(id, {}) as Dictionary).get("attempts", 0))

func is_level_cleared(id: int) -> bool:
	return bool((_levels.get(id, {}) as Dictionary).get("cleared", false))

## Count the start of a new try at `id` (a level entry or a restart). The count is
## CUMULATIVE — it keeps growing across sessions, even if the player leaves the
## level and comes back. Persists locally and pushes fire-and-forget. Returns the
## new cumulative attempt count.
func bump_attempt(id: int) -> int:
	var rec: Dictionary = _levels.get(id, {})
	rec["attempts"] = int(rec.get("attempts", 0)) + 1
	rec["updated_at"] = _now()
	_levels[id] = rec
	_unsynced[id] = true
	save_progress()
	_sync_level(id)   # fire-and-forget; never awaited, so gameplay can't stall offline
	return rec["attempts"]

## Record that `id` has been cleared (idempotent; keeps the first clear time).
func mark_level_cleared(id: int) -> void:
	var rec: Dictionary = _levels.get(id, {})
	if not bool(rec.get("cleared", false)):
		rec["cleared"] = true
		rec["cleared_at"] = _now()
	rec["updated_at"] = _now()
	_levels[id] = rec
	_unsynced[id] = true
	save_progress()
	_sync_level(id)

# =============================================================================
# Challenge attempts — local-only, cumulative across leave/return. Reported to the
# backend only when the challenge is completed (see game.gd _on_challenge_won).
# =============================================================================
func challenge_attempts(cid: String) -> int:
	return int(_challenge_attempts.get(cid, 0))

## Count the start of a new try at challenge `cid`. Returns the cumulative count.
func bump_challenge_attempt(cid: String) -> int:
	var n := challenge_attempts(cid) + 1
	_challenge_attempts[cid] = n
	save_progress()
	return n

# =============================================================================
# Backend sync — fire-and-forget + offline-resilient. Local data is authoritative;
# pushes are best-effort and any that fail stay queued in `_unsynced`, flushed on
# the next sign-in/reconnect. The backend merges monotonically, so push order
# doesn't matter and replays are harmless.
# =============================================================================
func _fs() -> Node:
	return get_node_or_null("/root/FirebaseSocial")

func _now() -> int:
	return int(Time.get_unix_time_from_system())

## Connect reconnect-flush once every autoload exists (GameState loads before
## FirebaseSocial, so this can't run inside _ready directly).
func _init_sync() -> void:
	var fs := _fs()
	if fs == null:
		return
	if not fs.auth_changed.is_connected(_on_auth_changed):
		fs.auth_changed.connect(_on_auth_changed)
	if fs.is_signed_in():
		_flush_pending()

func _on_auth_changed(_user: Dictionary) -> void:
	_flush_pending()   # reconnected / signed in -> push whatever queued offline

func _flush_pending() -> void:
	for id: int in _unsynced.keys():
		_sync_level(id)

## Push one level's record. Fire-and-forget: callers don't await it. On success the
## record leaves the queue; on failure (offline/signed out) it stays queued for the
## next flush. Only clears the queue entry if the record didn't change mid-push.
func _sync_level(id: int) -> void:
	var fs := _fs()
	if fs == null or not fs.is_signed_in() or not _levels.has(id):
		return
	var rec: Dictionary = _levels[id]
	var pushed_at: int = int(rec.get("updated_at", 0))
	var ok: bool = await fs.sync_level_progress("LEVEL_%d" % id, {
		attempts = int(rec.get("attempts", 0)),
		cleared = bool(rec.get("cleared", false)),
		clearedAt = int(rec.get("cleared_at", 0)),
	})
	if ok and int((_levels.get(id, {}) as Dictionary).get("updated_at", 0)) == pushed_at:
		_unsynced.erase(id)
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
