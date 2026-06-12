extends SceneTree
## Dependency-free headless test runner for the rules engine.
##
##   godot --headless --path . -s res://test/run_tests.gd
##
## gdUnit4/GUT are not installed, so this is a tiny self-contained harness. It
## asserts the deterministic logic layer (a fixed ASCII board + a move sequence
## produces a known board) and PROD behaviour: boards default invincible=false,
## so tests never lean on the INVINCIBLE dev default. Exits non-zero if any check
## fails.

var _passed: int = 0
var _failed: int = 0
var _checks: int = 0
var _current: String = ""

func _initialize() -> void:
	_run_all()
	print("\n========================================")
	print("RESULT: %d passed, %d failed" % [_passed, _failed])
	print("========================================")
	quit(1 if _failed > 0 else 0)

func _run_all() -> void:
	# grid-core
	_t("grid_core_parse", test_grid_core_parse)
	# player-movement
	_t("move_into_empty", test_move_into_empty)
	_t("move_into_wall_blocked", test_move_into_wall_blocked)
	_t("dig_on_entry", test_dig_on_entry)
	# push-mechanic
	_t("push_rock", test_push_rock)
	_t("push_blocked_by_wall", test_push_blocked_by_wall)
	_t("cannot_push_falling_object", test_cannot_push_falling_object)
	_t("cannot_push_upward", test_cannot_push_upward)
	_t("push_key_into_teleporter", test_push_key_into_teleporter)
	_t("blue_key_first_color", test_blue_key_first_color)
	_t("pushed_object_slides_before_falling", test_pushed_object_slides_before_falling)
	# gravity
	_t("gravity_fall_to_ground", test_gravity_fall_to_ground)
	_t("gravity_crush_player", test_gravity_crush_player)
	_t("player_can_dodge_falling_rock", test_player_can_dodge_falling_rock)
	# barrels
	_t("barrel_detonation_by_fall", test_barrel_detonation_by_fall)
	_t("barrel_chain_reaction", test_barrel_chain_reaction)
	_t("barrel_destroys_key_unwinnable", test_barrel_destroys_key_unwinnable)
	_t("push_into_barrel_does_not_detonate", test_push_into_barrel_no_detonate)
	_t("falling_barrel_detonates_on_landing", test_falling_barrel_detonates_on_landing)
	_t("breakable_wall_blocks_movement", test_breakable_wall_blocks_movement)
	_t("rock_rests_on_breakable_wall", test_rock_rests_on_breakable_wall)
	_t("falling_barrel_breaks_wall", test_falling_barrel_breaks_wall)
	# switch / flip walls
	_t("switch_walkable_toggle_solidifies", test_switch_walkable_toggle_solidifies)
	_t("flip_wall_inactive_is_passable", test_flip_wall_inactive_is_passable)
	_t("object_falls_through_inactive_flip_wall", test_object_falls_through_inactive_flip_wall)
	_t("object_rests_on_active_flip_wall", test_object_rests_on_active_flip_wall)
	_t("cannot_toggle_when_flip_wall_occupied", test_cannot_toggle_when_flip_wall_occupied)
	_t("cannot_toggle_off_switch", test_cannot_toggle_off_switch)
	_t("active_flip_wall_starts_solid", test_active_flip_wall_starts_solid)
	_t("active_flip_wall_supports_then_drops", test_active_flip_wall_supports_then_drops)
	# gravity switch
	_t("gravity_switch_reverses_fall", test_gravity_switch_reverses_fall)
	_t("reversed_gravity_blocks_push_down", test_reversed_gravity_blocks_push_down)
	# win-lose
	_t("win_sequence", test_win_sequence)
	# level-data
	_t("level_validate", test_level_validate)
	_t("level_resource_roundtrip", test_level_resource_roundtrip)
	# mobile-controls (swipe mapping only)
	_t("swipe_mapping", test_swipe_mapping)

# =============================================================================
# Harness helpers
# =============================================================================
func _t(name: String, fn: Callable) -> void:
	_current = name
	var fail_before := _failed
	var checks_before := _checks
	fn.call()
	if _checks == checks_before:
		# Test aborted (e.g. a runtime error before any assertion) — never a pass.
		_failed += 1
		print("  FAIL  %s (no assertions ran — aborted?)" % name)
	elif _failed == fail_before:
		_passed += 1
		print("  PASS  %s" % name)
	else:
		print("  FAIL  %s" % name)

func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("    [%s] %s" % [_current, msg])

func _eq(a: Variant, b: Variant, msg: String) -> void:
	_check(a == b, "%s (got %s, expected %s)" % [msg, str(a), str(b)])

func _board(rows: Array) -> Board:
	return Board.from_ascii("\n".join(PackedStringArray(rows)))

## Run gravity to rest — the renderer ticks gravity_step() one square at a time
## on a timer; tests fast-forward to the settled state. Returns every event
## emitted along the way (b.events only holds the final, empty tick).
func _gravity_settle(b: Board) -> Array:
	var all: Array = []
	var guard := 0
	while b.gravity_step() and guard < 1000:
		all.append_array(b.events)
		guard += 1
	return all

func _has_in(evs: Array, type: String) -> bool:
	for e: Dictionary in evs:
		if e.get("t", "") == type:
			return true
	return false

func _ascii_eq(b: Board, rows: Array, msg: String) -> void:
	var expected := "\n".join(PackedStringArray(rows))
	_check(b.to_ascii() == expected, "%s\n--- got ---\n%s\n--- expected ---\n%s" % [msg, b.to_ascii(), expected])

# =============================================================================
# grid-core
# =============================================================================
func test_grid_core_parse() -> void:
	var b := _board(["##########", "#A.1.2..T#", "##########"])
	_eq(b.width, 10, "width")
	_eq(b.height, 3, "height")
	_eq(b.player, Vector2i(1, 1), "player spawn")
	_eq(b.keys_remaining(), 2, "both keys undelivered")
	_ascii_eq(b, ["##########", "#A.1.2..T#", "##########"], "to_ascii roundtrip")

# =============================================================================
# player-movement
# =============================================================================
func test_move_into_empty() -> void:
	var b := _board(["#####", "#A..#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "move accepted")
	_ascii_eq(b, ["#####", "#.A.#", "#####"], "player advanced one tile")

func test_move_into_wall_blocked() -> void:
	var b := _board(["###", "#A#", "###"])
	_check(not b.move_player(Vector2i.RIGHT), "move into wall rejected")
	_eq(b.player, Vector2i(1, 1), "player did not move")

func test_dig_on_entry() -> void:
	# Francis Scott still clears dirt by walking into it (there's no stationary dig action).
	var b := _board(["####", "#AD#", "####"])
	_check(b.move_player(Vector2i.RIGHT), "walk into dirt accepted")
	_eq(b.terrain_at(Vector2i(2, 1)), Board.Terrain.EMPTY, "dirt cleared on entry")
	_eq(b.player, Vector2i(2, 1), "player moved onto dug tile")

# =============================================================================
# push-mechanic
# =============================================================================
func test_push_rock() -> void:
	var b := _board(["#####", "#AR.#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "push accepted")
	_ascii_eq(b, ["#####", "#.AR#", "#####"], "rock pushed one tile")

func test_push_blocked_by_wall() -> void:
	var b := _board(["####", "#AR#", "####"])
	_check(not b.move_player(Vector2i.RIGHT), "push into wall rejected")
	_ascii_eq(b, ["####", "#AR#", "####"], "nothing moved")

func test_cannot_push_falling_object() -> void:
	# A rock drops one square so it's beside Francis Scott and mid-fall; the push is refused.
	var b := _board(["####", "#R.#", "#.A#", "#..#", "####"])
	b.gravity_step()
	_eq(b.occupant_at(Vector2i(1, 2)), Board.Occupant.ROCK, "rock fell beside Francis Scott")
	_check(not b.move_player(Vector2i.LEFT), "cannot push a falling rock")
	_eq(b.occupant_at(Vector2i(1, 2)), Board.Occupant.ROCK, "rock stayed put")
	_eq(b.player, Vector2i(2, 2), "Francis Scott did not move into it")

func test_cannot_push_upward() -> void:
	# A rock sits on Francis Scott's head; trying to push it up is blocked.
	var b := _board(["####", "#R.#", "#A.#", "####"])
	_check(not b.move_player(Vector2i.UP), "cannot push a rock upward")
	_eq(b.player, Vector2i(1, 2), "Francis Scott stayed put")
	_eq(b.occupant_at(Vector2i(1, 1)), Board.Occupant.ROCK, "rock did not move")

func test_push_key_into_teleporter() -> void:
	var b := _board(["#####", "#A1T#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "push-deliver accepted")
	_check(b.red_delivered, "red key delivered")
	_eq(b.first_color, "red", "red recorded as first")
	_check(not b.teleporter_active(), "not active until the blue key is in too")
	_eq(b.keys_remaining(), 1, "one key left")
	_ascii_eq(b, ["#####", "#.AT#", "#####"], "red key consumed at teleporter")

# =============================================================================
# gravity
# =============================================================================
func test_gravity_fall_to_ground() -> void:
	var b := _board(["#####", "#.R.#", "#...#", "#A..#", "#####"])
	_gravity_settle(b)  # rock drops one square at a time to the floor
	_ascii_eq(b, ["#####", "#...#", "#...#", "#AR.#", "#####"], "rock fell to floor")

func test_gravity_crush_player() -> void:
	var b := _board(["#####", "#R..#", "#...#", "#A..#", "#####"])
	_gravity_settle(b)  # rock falls down column 1 onto Francis Scott
	_eq(b.status, Board.Status.LOST, "player crushed -> lost")
	_eq(b.lose_reason, "crush", "lose reason crush")

func test_player_can_dodge_falling_rock() -> void:
	# Gravity moves one square per tick, so a quick step in the gap dodges a drop.
	var b := _board(["#####", "#R..#", "#...#", "#A..#", "#####"])
	b.gravity_step()                                 # rock -> (1,2), above Francis Scott
	_check(b.move_player(Vector2i.RIGHT), "Francis Scott steps aside before it lands")
	_gravity_settle(b)                               # rock falls into the vacated cell
	_eq(b.status, Board.Status.PLAYING, "dodged the rock -> still playing")

# =============================================================================
# barrels
# =============================================================================
func test_barrel_detonation_by_fall() -> void:
	var b := _board(["#######", "#..R..#", "#.....#", "#..X..#", "#..D..#", "#A....#", "#######"])
	var evs := _gravity_settle(b)  # rock drops onto the barrel and detonates it
	_eq(b.occupant_at(Vector2i(3, 3)), Board.Occupant.NONE, "barrel consumed")
	_eq(b.terrain_at(Vector2i(3, 4)), Board.Terrain.EMPTY, "dirt cleared by blast")
	_check(_has_in(evs, "explode"), "explode event emitted")

func test_barrel_chain_reaction() -> void:
	var b := _board(["######", "#R...#", "#....#", "#XX..#", "#....#", "#....A#", "######"])
	_gravity_settle(b)  # rock drops onto a barrel, which chains to its neighbour
	_eq(b.occupant_at(Vector2i(1, 3)), Board.Occupant.NONE, "first barrel gone")
	_eq(b.occupant_at(Vector2i(2, 3)), Board.Occupant.NONE, "chained barrel gone")

func test_push_into_barrel_no_detonate() -> void:
	# Pushing a rock into a barrel is just blocked — it must NOT detonate.
	var b := _board(["######", "#ARX.#", "######"])
	_check(not b.move_player(Vector2i.RIGHT), "push into barrel is blocked")
	_eq(b.occupant_at(Vector2i(3, 1)), Board.Occupant.BARREL, "barrel intact")
	_eq(b.occupant_at(Vector2i(2, 1)), Board.Occupant.ROCK, "rock did not move")
	_check(not _has_event(b, "explode"), "no detonation from a push")

func test_falling_barrel_detonates_on_landing() -> void:
	# A floating barrel falls and detonates when it lands on the floor.
	var b := _board(["########", "#.X....#", "#......#", "#......#", "#.....A#", "########"])
	var evs := _gravity_settle(b)
	_eq(b.occupant_at(Vector2i(2, 4)), Board.Occupant.NONE, "landed barrel detonated")
	_check(_has_in(evs, "explode"), "explode emitted on landing")
	_eq(b.status, Board.Status.PLAYING, "Francis Scott is clear of the blast")

func test_breakable_wall_blocks_movement() -> void:
	var b := _board(["#####", "#AB.#", "#####"])
	_check(not b.move_player(Vector2i.RIGHT), "breakable wall blocks like a wall")
	_eq(b.player, Vector2i(1, 1), "player did not move")

func test_rock_rests_on_breakable_wall() -> void:
	# A falling rock lands on a breakable wall but does NOT destroy it.
	var b := _board(["#####", "#.R.#", "#...#", "#.B.#", "#A..#", "#####"])
	_gravity_settle(b)  # rock falls onto the breakable wall and rests
	_eq(b.terrain_at(Vector2i(2, 3)), Board.Terrain.BREAKABLE_WALL, "breakable wall survives a rock")
	_eq(b.occupant_at(Vector2i(2, 2)), Board.Occupant.ROCK, "rock rests on top")

func test_falling_barrel_breaks_wall() -> void:
	# A falling barrel detonates on the breakable wall and destroys it.
	var b := _board(["#######", "#.X....#", "#......#", "#.B....#", "#......#", "#.....A#", "#######"])
	var evs := _gravity_settle(b)
	_eq(b.terrain_at(Vector2i(2, 3)), Board.Terrain.EMPTY, "breakable wall destroyed by the blast")
	_check(_has_in(evs, "explode"), "barrel detonated")
	_eq(b.status, Board.Status.PLAYING, "Francis Scott is clear of the blast")

func test_pushed_object_slides_before_falling() -> void:
	# Push a key onto a ledge tile, off which it falls. Pushing (a move) and
	# falling (gravity) are now separate steps, so the key finishes its horizontal
	# slide in one step and only begins falling on a later gravity tick — it never
	# cuts diagonally through the cell below.
	var b := _board(["#####", "#A1.#", "#.#.#", "#...#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "push accepted")
	var push_to := Vector2i(-1, -1)
	for e: Dictionary in b.events:
		if e["t"] == "push":
			push_to = e["to"]
			_check(e["from"].y == e["to"].y, "push step is horizontal")
	_check(push_to != Vector2i(-1, -1), "object was pushed")
	_check(not _has_in(b.events, "fall"), "it does not fall in the same step as the push")
	# Next gravity tick: it drops one square, starting exactly where the push ended.
	b.gravity_step()
	var fell := false
	for e: Dictionary in b.events:
		if e["t"] == "fall":
			fell = true
			_check(e["from"].x == e["to"].x, "fall step is vertical")
			_eq(e["from"], push_to, "fall begins exactly where the push ended")
	_check(fell, "object falls on the following gravity tick")

func test_blue_key_first_color() -> void:
	var b := _board(["#####", "#A2T#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "push blue into teleporter")
	_check(b.blue_delivered, "blue key delivered")
	_eq(b.first_color, "blue", "blue recorded as first (drives blueopen art)")
	_check(not b.teleporter_active(), "still locked without the red key")

func test_barrel_destroys_key_unwinnable() -> void:
	var b := _board(["######", "#R...#", "#....#", "#X1..#", "#....#", "#....A#", "######"])
	_gravity_settle(b)  # rock detonates the barrel, whose blast destroys the red key
	_check(b.unwinnable, "destroying a teleporter key makes the level unwinnable")
	_check(not b.red_delivered, "the red key was lost, not delivered")

# =============================================================================
# switch / flip walls
# =============================================================================
func test_switch_walkable_toggle_solidifies() -> void:
	# Walk onto a switch, toggle it; the adjacent flip wall becomes a solid wall.
	var b := _board(["#####", "#AWP#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "switch is walkable")
	_eq(b.player, Vector2i(2, 1), "Francis Scott on the switch")
	_check(b.can_toggle_switch(), "switch option available")
	_check(b.toggle_switch(), "toggled the switch")
	_check(b.flip_active, "flip walls now active")
	_check(not b.move_player(Vector2i.RIGHT), "the now-solid flip wall blocks Francis Scott")

func test_flip_wall_inactive_is_passable() -> void:
	# A flip wall starts inactive — physics-wise empty, so Francis Scott walks right through.
	var b := _board(["#####", "#AP.#", "#####"])
	_check(b.move_player(Vector2i.RIGHT), "inactive flip wall is passable")
	_eq(b.player, Vector2i(2, 1), "Francis Scott walked onto it")

func test_object_falls_through_inactive_flip_wall() -> void:
	var b := _board(["#####", "#.R.#", "#.P.#", "#...#", "#A..#", "#####"])
	_gravity_settle(b)
	_eq(b.occupant_at(Vector2i(2, 2)), Board.Occupant.NONE, "rock did not rest on the inactive flip wall")
	_eq(b.occupant_at(Vector2i(2, 4)), Board.Occupant.ROCK, "it fell through to the floor")

func test_object_rests_on_active_flip_wall() -> void:
	var b := _board(["#####", "#.R.#", "#.P.#", "#...#", "#A..#", "#####"])
	b.flip_active = true  # flip walls active -> solid
	_gravity_settle(b)
	_eq(b.occupant_at(Vector2i(2, 1)), Board.Occupant.ROCK, "rock rests on the active flip wall")

func test_cannot_toggle_when_flip_wall_occupied() -> void:
	# A rock settles inside an inactive flip wall (solid floor beneath it); toggling
	# would trap it, so the option is withheld.
	var b := _board(["######", "#R....#", "#P....#", "##....#", "#A.W..#", "######"])
	_gravity_settle(b)
	_eq(b.occupant_at(Vector2i(1, 2)), Board.Occupant.ROCK, "rock settled in the flip wall cell")
	b.move_player(Vector2i.RIGHT)
	b.move_player(Vector2i.RIGHT)  # Francis Scott -> switch at (3,4)
	_eq(b.player, Vector2i(3, 4), "Francis Scott on the switch")
	_check(not b.can_toggle_switch(), "can't toggle while an object overlaps an inactive flip wall")

func test_active_flip_wall_starts_solid() -> void:
	# 'Q' is a toggle wall that starts SOLID (the mirror of 'P', which starts open).
	var b := _board(["#####", "#AQ.#", "#####"])
	_check(not b.move_player(Vector2i.RIGHT), "active flip wall is solid at the start")
	b.flip_active = true  # throw the switch
	_check(b.move_player(Vector2i.RIGHT), "active flip wall opens once the phase flips")
	_eq(b.player, Vector2i(2, 1), "Francis Scott walked onto the now-open wall")

func test_active_flip_wall_supports_then_drops() -> void:
	# A rock rests on the solid active wall; opening it lets the rock fall through.
	var b := _board(["#####", "#.R.#", "#.Q.#", "#...#", "#A..#", "#####"])
	_gravity_settle(b)
	_eq(b.occupant_at(Vector2i(2, 1)), Board.Occupant.ROCK, "rock rests on the solid active wall")
	b.flip_active = true
	_gravity_settle(b)
	_eq(b.occupant_at(Vector2i(2, 4)), Board.Occupant.ROCK, "opening the wall drops the rock to the floor")

func test_cannot_toggle_off_switch() -> void:
	var b := _board(["####", "#AW#", "####"])
	_check(not b.can_toggle_switch(), "no switch option unless standing on a switch")

# =============================================================================
# gravity switch
# =============================================================================
func test_gravity_switch_reverses_fall() -> void:
	# Step onto the gravity switch (G), throw it; the rock then falls UP.
	var b := _board(["######", "#....#", "#.R..#", "#AG..#", "######"])
	_check(b.move_player(Vector2i.RIGHT), "step onto the gravity switch")
	_check(b.can_toggle_switch(), "gravity switch exposes the switch option")
	_check(b.toggle_switch(), "throw the gravity switch")
	_check(b.gravity_reversed, "gravity is now reversed")
	_gravity_settle(b)
	_eq(b.occupant_at(Vector2i(2, 1)), Board.Occupant.ROCK, "rock fell UP to the ceiling")
	_eq(b.occupant_at(Vector2i(2, 2)), Board.Occupant.NONE, "rock left its old cell")

func test_reversed_gravity_blocks_push_down() -> void:
	# Reversed gravity makes "down" the fall direction, so pushing down is refused
	# (the mirror of the normal no-push-up rule).
	var b := _board(["####", "#A.#", "#R.#", "####"])
	b.gravity_reversed = true
	_check(not b.move_player(Vector2i.DOWN), "can't push an object the way it falls under reversed gravity")
	_eq(b.occupant_at(Vector2i(1, 2)), Board.Occupant.ROCK, "rock stayed put")

# =============================================================================
# win-lose
# =============================================================================
func test_win_sequence() -> void:
	# Both keys drop into the teleporter, then Francis Scott enters to win.
	var b := _board(["####", "#1.#", "#2.#", "#T.#", "#A.#", "####"])
	b.move_player(Vector2i.RIGHT)  # step aside so the column is clear
	_gravity_settle(b)             # both keys fall into the teleporter
	_check(b.teleporter_active(), "both keys delivered -> teleporter active")
	b.move_player(Vector2i.LEFT)
	b.move_player(Vector2i.UP)     # enter the active teleporter
	_eq(b.status, Board.Status.WON, "both delivered + entered -> won")

# =============================================================================
# level-data
# =============================================================================
func test_level_validate() -> void:
	_eq(LevelLoader.validate("######\n#A12T#\n######"), "", "valid layout passes")
	_check(LevelLoader.validate("######\n#.12T#\n######").contains("'A'"), "missing A flagged")
	_check(LevelLoader.validate("######\n#AA2T#\n#1...#\n######").contains("'A'"), "two A flagged")
	_check(LevelLoader.validate("######\n#A12.#\n######").contains("'T'"), "missing T flagged")
	_check(LevelLoader.validate("######\n#A2.T#\n######").contains("red key"), "missing red key flagged")
	_check(LevelLoader.validate("######\n#A1.T#\n######").contains("blue key"), "missing blue key flagged")

func test_level_resource_roundtrip() -> void:
	var levels := LevelLoader.load_all()
	_check(levels.size() >= 3, "discovered starter levels")
	if levels.size() >= 3:
		_eq(levels[0].id, 1, "sorted by id")
		_eq(levels[2].id, 3, "sorted by id")
	var res := ResourceLoader.load("res://levels/level_1.tres")
	_check(res is LevelData, "level_1 loads as LevelData")
	if res is LevelData:
		var b := LevelLoader.build_board(res)
		_check(b != null, "board built from resource")
		if b != null:
			_eq(b.keys_remaining(), 2, "level 1 has both keys to deliver")
			_check(b.in_bounds(b.player), "level 1 spawn parsed in bounds")

# =============================================================================
# mobile-controls — swipe vector -> direction only
# =============================================================================
func test_swipe_mapping() -> void:
	var th := float(Tuning.SWIPE_THRESHOLD)
	_eq(Swipe.to_dir(Vector2(50, 0), th), Vector2i.RIGHT, "right swipe")
	_eq(Swipe.to_dir(Vector2(-50, 0), th), Vector2i.LEFT, "left swipe")
	_eq(Swipe.to_dir(Vector2(0, 50), th), Vector2i.DOWN, "down swipe")
	_eq(Swipe.to_dir(Vector2(0, -50), th), Vector2i.UP, "up swipe")
	_eq(Swipe.to_dir(Vector2(10, 5), th), Vector2i.ZERO, "below threshold ignored")
	_eq(Swipe.to_dir(Vector2(30, 40), th), Vector2i.DOWN, "dominant axis wins")

# =============================================================================
func _has_event(b: Board, type: String) -> bool:
	for e: Dictionary in b.events:
		if e.get("t", "") == type:
			return true
	return false
