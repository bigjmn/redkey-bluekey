extends Node
## Tuning — global tunables and dev toggles (autoload singleton).
##
## Constants are the hand-feel knobs of the game; reference them everywhere
## instead of inlining the literal value. Dev toggles are live (editable) in
## debug builds and frozen to their prod value in shipped builds, gated on
## OS.is_debug_build(). Gameplay code that must honour a toggle reads it from
## here and copies it into the headless Board, so tests can assert prod
## behaviour without touching these dev defaults.

# =============================================================================
# CONSTANTS — tunables you'll want to feel out by hand.
# =============================================================================
const TILE_SIZE: int = 64            ## px (logical): grid cell size before responsive scaling.
const STEP_DURATION: float = 0.08    ## sec: tween time for one tile of movement/push.
const FALL_DURATION: float = 0.16    ## sec/tile: per-tile fall speed for rocks and orbs.
const ENEMY_STEP_INTERVAL: float = 0.5  ## sec: how often enemies advance one tile.
const EXPLOSION_RADIUS: int = 1      ## tiles: square radius cleared by a detonating barrel (1 = 3x3).
const SWIPE_THRESHOLD: int = 24      ## px: minimum swipe/drag distance to register a move.
const MOVE_REPEAT_DELAY: float = 0.2 ## sec: a held direction (drag/key) waits this long after its first move before auto-repeating — the "initial move buffer" so a quick flick moves once.
const MOVE_REPEAT_INTERVAL: float = 0.09 ## sec: time between auto-repeat moves while a direction stays held (≈ STEP_DURATION for fluid motion).

# =============================================================================
# DEV TOGGLES — live while building, frozen in shipped builds.
# Gate: OS.is_debug_build(). When the gate is false each toggle is fixed to its
# prod value (writes are ignored). When true the toggle starts at its dev
# default and can be changed at runtime.
# =============================================================================
const INVINCIBLE_DEV: bool = false            ## Francis Scott ignores enemy contact and crushing.
const INVINCIBLE_PROD: bool = false
const UNLOCK_ALL_LEVELS_DEV: bool = true     ## Open every level in the level-select without codes.
const UNLOCK_ALL_LEVELS_PROD: bool = false
const START_LEVEL_DEV: int = 1               ## Which level id to boot straight into.
const START_LEVEL_PROD: int = 1
const SHOW_GRID_OVERLAY_DEV: bool = true     ## Draw tile gridlines and coordinates.
const SHOW_GRID_OVERLAY_PROD: bool = false
const SHOW_ENEMY_INTENT_DEV: bool = true     ## Render each enemy's next-move arrow.
const SHOW_ENEMY_INTENT_PROD: bool = false
const DEV_LEVELS_DEV: bool = true            ## Editor: beating a playtest saves it as a game level
const DEV_LEVELS_PROD: bool = false          ## (the designer flow); false = the social share dialog.

var _invincible: bool = INVINCIBLE_DEV
var _unlock_all_levels: bool = UNLOCK_ALL_LEVELS_DEV
var _start_level: int = START_LEVEL_DEV
var _show_grid_overlay: bool = SHOW_GRID_OVERLAY_DEV
var _show_enemy_intent: bool = SHOW_ENEMY_INTENT_DEV
var _dev_levels: bool = DEV_LEVELS_DEV

## True when dev toggles are live. Centralised so it is trivial to fake in a
## test or force off for a smoke build.
func dev_mode() -> bool:
	return OS.is_debug_build()

var invincible: bool:
	get: return _invincible if dev_mode() else INVINCIBLE_PROD
	set(value):
		if dev_mode():
			_invincible = value

var unlock_all_levels: bool:
	get: return _unlock_all_levels if dev_mode() else UNLOCK_ALL_LEVELS_PROD
	set(value):
		if dev_mode():
			_unlock_all_levels = value

var start_level: int:
	get: return _start_level if dev_mode() else START_LEVEL_PROD
	set(value):
		if dev_mode():
			_start_level = value

var show_grid_overlay: bool:
	get: return _show_grid_overlay if dev_mode() else SHOW_GRID_OVERLAY_PROD
	set(value):
		if dev_mode():
			_show_grid_overlay = value

var show_enemy_intent: bool:
	get: return _show_enemy_intent if dev_mode() else SHOW_ENEMY_INTENT_PROD
	set(value):
		if dev_mode():
			_show_enemy_intent = value

var dev_levels: bool:
	get: return _dev_levels if dev_mode() else DEV_LEVELS_PROD
	set(value):
		if dev_mode():
			_dev_levels = value
