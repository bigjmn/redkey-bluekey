extends SceneTree
## Headless smoke test for the SCENE layer (level.gd / game.gd / cell_visual.gd),
## which the pure-logic suite can't reach. Instantiates the real scenes, drives
## the renderer's public actions, and asserts the node bookkeeping tracks the
## board. No display required: we only check state + that nothing crashes.
##
##   godot --headless --path . -s res://test/run_render_smoke.gd
##
## The Game controller relies on _ready, which fires a frame AFTER add_child in a
## custom main loop, so the controller check is deferred a few frames via
## _process. The Level renderer builds lazily in setup(), so it is tested inline.

var _passed: int = 0
var _failed: int = 0
var _checks: int = 0
var _current: String = ""

var _game: Node = null
var _editor: Node = null
var _select: Node = null
var _title: Node = null
var _instr: Node = null
var _settings: Node = null
var _frames: int = 0

func _initialize() -> void:
	_t("level_drive_push_restart", test_level_drive)
	_t("switch_and_flip_wall_scene", test_switch_scene)
	_t("explosion_spares_survivors", test_explosion_spares_survivors)
	_t("level_drafts_roundtrip", test_level_drafts)
	_t("game_state_progress_persistence", test_progress)
	# Boot the controller + editor + selector; assertions run once _ready fired.
	var gs: Node = root.get_node_or_null("GameState")
	if gs != null:
		gs.reload_levels()
	_game = load("res://scenes/game.tscn").instantiate()
	root.add_child(_game)
	_editor = load("res://scenes/editor.tscn").instantiate()
	root.add_child(_editor)
	_select = load("res://scenes/level_select.tscn").instantiate()
	root.add_child(_select)
	_title = load("res://scenes/title_screen.tscn").instantiate()
	root.add_child(_title)
	_instr = Instructions.new()
	root.add_child(_instr)
	_settings = SettingsModal.new()
	root.add_child(_settings)

var _async_done: bool = false

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	if _frames == 3:
		_t("game_boots_into_level", test_game_boots)
		_t("challenge_hud_title", test_challenge_hud)
		_t("editor_boots", test_editor_boots)
		_t("editor_drag_paint", test_editor_drag_paint)
		_t("level_select_builds", test_level_select)
		_t("title_screen_builds", test_title_screen)
		_t("instructions_modal_pages", test_instructions)
		_t("settings_modal_tabs", test_settings_modal)
		_t("sfx_autoload_and_click", test_sfx)
		_run_async_tests()   # social layer awaits frames; tallied when done
	if not _async_done:
		return false
	print("\n========================================")
	print("RENDER SMOKE: %d passed, %d failed" % [_passed, _failed])
	print("========================================")
	quit(1 if _failed > 0 else 0)
	return true

## Awaitable tests (the social mock API yields a frame per call).
func _run_async_tests() -> void:
	await _t_async("social_mock_flow", test_social_mock_flow)
	await _t_async("social_screens_build", test_social_screens)
	_async_done = true

func _t(name: String, fn: Callable) -> void:
	_current = name
	var fail_before := _failed
	var checks_before := _checks
	fn.call()
	_tally(name, fail_before, checks_before)

func _t_async(name: String, fn: Callable) -> void:
	_current = name
	var fail_before := _failed
	var checks_before := _checks
	await fn.call()
	_tally(name, fail_before, checks_before)

func _tally(name: String, fail_before: int, checks_before: int) -> void:
	if _checks == checks_before:
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

# =============================================================================
func test_progress() -> void:
	var gs: Node = root.get_node_or_null("GameState")
	_check(gs != null, "GameState autoload present")
	if gs == null:
		return
	var orig: int = gs.highest_unlocked
	# Frontier logic: below = completed, equal = current.
	gs.highest_unlocked = 2
	_check(gs.is_completed_id(1), "level below the frontier is completed")
	_check(gs.is_current_id(2), "the frontier level is current")
	var l2: Resource = gs.level_by_id(2)
	if l2 != null:
		gs.mark_cleared(l2)
		_check(gs.highest_unlocked == 3, "clearing the frontier unlocks the next level")
	# Persistence roundtrip through user://.
	gs.highest_unlocked = 7
	gs.save_progress()
	gs.highest_unlocked = 1
	gs.load_progress()
	_check(gs.highest_unlocked == 7, "progress persists across save/load on user://")
	# Restore so the test doesn't clobber real progress.
	gs.highest_unlocked = orig
	gs.save_progress()

func test_level_select() -> void:
	_check(_select.get_child_count() >= 2, "selector built its UI")
	_check(_count_texture_buttons(_select) >= 12, "selector populated a grid of level buttons")

func test_settings_modal() -> void:
	_check(root.get_node_or_null("GearMenu") != null, "GearMenu autoload present")
	_check(_settings._tab_buttons.size() == 3, "settings modal has three tabs")
	_check(_settings._content.get_child_count() >= 1, "About tab populated")
	_settings._select(1)   # Settings — reads GearMenu toggle state
	_check(_settings._content.get_child_count() >= 1, "Settings tab built")
	_settings._select(2)   # Privacy
	_check(_settings._content.get_child_count() >= 1, "Privacy tab built")

func test_title_screen() -> void:
	_check(_title.get_child_count() >= 2, "title screen built its UI")
	# Play / Rules / Social / Level Editor image buttons.
	_check(_count_texture_buttons(_title) == 4, "title screen has the four menu buttons")

func test_instructions() -> void:
	# _ready built the first page; page forward/back through the deck.
	_check(_instr._title_lbl != null and _instr._title_lbl.text == "Francis Scott", "first page is Francis Scott")
	_instr._advance()
	_check(_instr._title_lbl.text == "Objects", "advances to the Objects page")
	_instr._go_back()
	_check(_instr._title_lbl.text == "Francis Scott", "Back returns to the previous page")
	# Advancing past the last page closes (frees) the modal.
	for _i: int in range(_instr.PAGES.size()):
		_instr._advance()
	_check(_instr.is_queued_for_deletion(), "advancing past the last page closes the modal")

func _count_texture_buttons(node: Node) -> int:
	var n := 0
	if node is TextureButton:
		n += 1
	for c: Node in node.get_children():
		n += _count_texture_buttons(c)
	return n

func test_game_boots() -> void:
	_check(_game._playfield != null, "controller built its playfield")
	_check(_game._level != null, "a level was instanced on boot")
	if _game._level != null:
		_check(_game._level.board != null, "level has a board")
		var before: Vector2i = _game._level.board.player
		_game._level.request_move(Vector2i.RIGHT)
		_check(_game._level.board.player == before + Vector2i.RIGHT, "boot level accepted a move")
	# HUD: regular level shows "Level N"; both key icons exist.
	_check(_game._lbl_title.text.begins_with("Level "), "HUD title reads 'Level N' for a regular level")
	_check(_game._key_red != null and _game._key_blue != null, "HUD has red + blue key icons")
	_check(_game._lbl_attempts.text == "Attempt 1", "HUD shows the attempt number")

func test_challenge_hud() -> void:
	# A challenge routed through the controller titles itself "<id> (Challenger)".
	_game.load_challenge({
		id = "ch-test", fromDisplayName = "Rocky",
		payload = {levelId = "rk-1", layout = "#####\n#A12T#\n#####"},
	})
	_check(_game._lbl_title.text == "rk-1 (Rocky)", "challenge HUD shows the level id and challenger")
	_check(not _game._challenge.is_empty(), "controller is in challenge mode")

func test_editor_boots() -> void:
	_check(_editor._cell_buttons.size() == _editor._w * _editor._h, "editor built its paint grid")
	# Exercise the paint -> serialize -> validate path by painting a valid level.
	_editor._selected = "A"; _editor._paint(1, 1)
	_editor._selected = "T"; _editor._paint(_editor._w - 2, 1)
	_editor._selected = "1"; _editor._paint(3, 1)
	_editor._selected = "2"; _editor._paint(5, 1)
	# Single-instance tiles: a second gate replaces the first (like the spawn).
	_editor._selected = "T"; _editor._paint(6, 1)
	_check(_editor._layout_string().count("T") == 1, "only one gate can exist on the grid")
	_check(LevelLoader.validate(_editor._layout_string()) == "", "painted grid validates")
	var code: String = _editor._make_code(99, _editor._layout_string())
	_check(code.begins_with("LV99"), "editor generates a level code")

func test_editor_drag_paint() -> void:
	# Terrain/empty glyphs drag-paint; objects/Francis Scott are tap-only.
	_check(_editor.DRAG_PAINT.has("#") and _editor.DRAG_PAINT.has("Q"), "terrain glyphs drag-paint")
	_check(not _editor.DRAG_PAINT.has("R") and not _editor.DRAG_PAINT.has("A"), "objects/Francis Scott are tap-only")
	# Drive the real press+drag path via cell geometry (hit-tested in _cell_at).
	var a: Vector2 = _cell_center(2, 2)
	var b2: Vector2 = _cell_center(5, 2)
	_editor._selected = "#"
	_editor._begin_stroke(a)
	_check(_editor._grid[2][2] == "#", "press paints the first cell")
	_check(_editor._dragging, "a terrain selection arms drag painting")
	_editor._drag_to(b2)
	_check(_editor._grid[2][5] == "#", "dragging paints cells the pointer crosses")
	# An object selection paints on press but does NOT arm a drag.
	_editor._selected = "R"
	_editor._begin_stroke(_cell_center(2, 4))
	_check(_editor._grid[4][2] == "R", "press still places a tap-only tile")
	_check(not _editor._dragging, "objects don't arm drag painting")
	# The perimeter wall is locked — painting it is a no-op.
	_editor._selected = "."
	_editor._paint(0, 0)
	_check(_editor._grid[0][0] == "#", "border walls can't be erased or modified")

func _cell_center(x: int, y: int) -> Vector2:
	var idx: int = y * _editor._w + x
	var b: Button = _editor._cell_buttons[idx]
	return b.get_global_rect().get_center()

# =============================================================================
# Social layer (mock mode end-to-end: auth -> profile -> friends -> challenges)
# =============================================================================
func test_social_mock_flow() -> void:
	var fs: Node = root.get_node_or_null("FirebaseSocial")
	_check(fs != null, "FirebaseSocial autoload present")
	if fs == null:
		return
	if not SocialConfig.USE_MOCK_API:
		# Live mode: don't create real accounts from the test runner. Just sanity-
		# check the wiring; flip USE_MOCK_API to re-enable the full offline flow.
		_check(SocialConfig.API_BASE_URL.begins_with("https://"), "live API base URL configured")
		print("    (mock mode off — live backend not exercised from tests)")
		return
	_check(await fs.ensure_signed_in(), "mock anonymous sign-in succeeds")
	_check(fs.is_signed_in(), "auth state populated")
	await fs.refresh_profile()
	_check(str(fs.profile.get("friendCode", "")) != "", "profile carries a friend code")
	await fs.set_display_name("Smoke Tester")
	_check(fs.profile.get("displayName", "") == "Smoke Tester", "display name update round-trips")
	await fs.refresh_friends()
	_check(fs.friends.size() == 2, "mock backend has two friends")
	_check(fs.friend_requests.size() == 1, "one pending friend request")
	# Accept the incoming request -> friendship is created by the (mock) backend.
	var rid: String = fs.friend_requests[0].get("id", "")
	await fs.respond_to_friend_request(rid, true)
	_check(fs.friends.size() == 3, "accepting a request adds a friend")
	await fs.refresh_challenges()
	_check(fs.incoming_challenges().size() == 1, "one incoming challenge")
	_check(fs.outgoing_challenges().size() == 1, "one outgoing challenge")
	var ch: Dictionary = fs.incoming_challenges()[0]
	_check(LevelLoader.validate(str(ch.payload.get("layout", ""))) == "", "incoming challenge layout is playable")
	# Accept then complete it; the client reports tries, backend decides winner.
	await fs.respond_to_challenge(ch.id, true)
	await fs.complete_challenge(ch.id, {tries = 2})
	_check(fs.completed_challenges().size() == 1, "completing a challenge moves it to completed")
	_check(await fs.post_level_to_profile({levelId = "smoke", layout = "", triesToBeat = 1}),
		"posting a level to the profile succeeds")

func test_social_screens() -> void:
	if not SocialConfig.USE_MOCK_API:
		_check(true, "skipped in live mode (screens would call the real backend)")
		print("    (mock mode off — social screens not booted from tests)")
		return
	for path: String in [
		"res://scenes/social/ProfileScreen.tscn",
		"res://scenes/social/FriendsScreen.tscn",
		"res://scenes/social/ChallengesScreen.tscn",
	]:
		var screen: Control = load(path).instantiate()
		root.add_child(screen)
		for _i: int in range(3):  # let _ready + the mock awaits settle
			await process_frame
		_check(screen.get_child_count() >= 2, "%s built its UI" % path.get_file())
		_check(screen.content.get_child_count() >= 1, "%s populated content" % path.get_file())
		screen.free()

func test_level_drafts() -> void:
	# Drafts are local, need NOT be valid, and round-trip through the editor parser.
	var before: int = LevelDrafts.load_all().size()
	var layout := "###\n#A#\n###"   # deliberately not a winnable level
	_check(LevelLoader.validate(layout) != "", "the draft layout is intentionally invalid")
	var d: Dictionary = LevelDrafts.save_draft(layout, 3, 3)
	var all: Array = LevelDrafts.load_all()
	_check(all.size() == before + 1, "save_draft appends without validating")
	_check(str(all.back().get("layout", "")) == layout, "draft stores the raw layout")
	# The editor reconstructs its grid from a draft layout.
	var ed: Node = load("res://scenes/editor.tscn").instantiate()
	ed._load_layout(layout)
	_check(ed._layout_string() == layout, "editor _load_layout round-trips the draft")
	ed.free()
	# Remove only the draft we added (leave any real ones intact).
	LevelDrafts.delete_draft(int(d.get("id", -1)))
	_check(LevelDrafts.load_all().size() == before, "delete_draft removes it")

func test_sfx() -> void:
	var sfx: Node = root.get_node_or_null("Sfx")
	_check(sfx != null, "Sfx autoload present")
	if sfx == null:
		return
	sfx.play("win")              # known sound -> no crash
	sfx.play("does-not-exist")   # unknown -> silently ignored
	_check(true, "play() tolerates known and unknown sounds")
	var b := Button.new()
	root.add_child(b)
	_check(b.pressed.is_connected(Callable(sfx, "_click")), "buttons auto-wire the click sound")
	var cell := Button.new()
	cell.add_to_group("no_click")
	root.add_child(cell)
	_check(not cell.pressed.is_connected(Callable(sfx, "_click")), "'no_click' buttons stay silent")
	b.free()
	cell.free()
	# The gear menu's Sounds toggle gates playback (defensive: only assert the
	# muting if headless audio actually reports a voice playing when enabled).
	for pl: AudioStreamPlayer in sfx._players:
		pl.stop()
	SettingsModal.sounds_on = true
	sfx.play("win")
	var played_when_on: bool = sfx._players.any(func(p: AudioStreamPlayer) -> bool: return p.playing)
	for pl: AudioStreamPlayer in sfx._players:
		pl.stop()
	SettingsModal.sounds_on = false
	sfx.play("win")
	var played_when_off: bool = sfx._players.any(func(p: AudioStreamPlayer) -> bool: return p.playing)
	SettingsModal.sounds_on = true   # restore default
	if played_when_on:
		_check(not played_when_off, "Sounds toggle off mutes effects")
	else:
		_check(not played_when_off, "no playback while muted (headless)")

func test_switch_scene() -> void:
	# Build a level with a switch + flip wall; render terrain, then toggle it.
	var lvl: Node2D = load("res://scenes/levels/level.tscn").instantiate()
	root.add_child(lvl)
	var b := Board.from_ascii("#####\n#AWP#\n#####")
	lvl.setup(b)
	_check(lvl._terrain_root.get_child_count() >= 2, "switch + flip wall terrain built")
	lvl.request_move(Vector2i.RIGHT)            # onto the switch
	lvl._process(0.2)                           # let the brief post-move input lock clear
	_check(lvl.can_switch(), "switch option exposed by the renderer")
	lvl.request_switch()
	_check(b.flip_active, "toggling the switch flips the walls")
	lvl.free()

func test_explosion_spares_survivors() -> void:
	# Regression: an explode event paints the flash but must NOT dissolve occupant
	# nodes merely because they sit over a blast cell — only objects the board
	# actually removed (via "remove") should vanish. A rock that survives the blast
	# (or falls into a cleared cell afterward) must keep its node.
	var lvl: Node2D = load("res://scenes/levels/level.tscn").instantiate()
	root.add_child(lvl)
	var b := Board.from_ascii("#####\n#R..#\n#A..#\n#####")  # rock at (1,1)
	lvl.setup(b)
	var rock: CellVisual = lvl.occ_nodes[Vector2i(1, 1)]
	# An explosion whose blast covers the rock's cell, but with NO "remove" for it
	# (the rock is a survivor, not a blast victim). max_dur 0 -> deferred runs now.
	lvl._apply_events([{t = "explode", center = Vector2i(1, 1), cells = [Vector2i(1, 1)]}])
	_check(is_instance_valid(rock) and lvl.occ_nodes.has(Vector2i(1, 1)),
		"explode flash leaves a survivor over the blast intact")
	# A real "remove" still dissolves its target (so barrels/victims vanish).
	lvl._apply_events([{t = "remove", at = Vector2i(1, 1)}])
	_check(not lvl.occ_nodes.has(Vector2i(1, 1)), "remove dissolves the targeted occupant")
	lvl.free()

func test_level_drive() -> void:
	var lvl: Node2D = load("res://scenes/levels/level.tscn").instantiate()
	root.add_child(lvl)
	var b := Board.from_ascii("#####\n#AR.#\n#####")
	lvl.setup(b)
	_check(lvl.occ_nodes.size() == 1, "one occupant node for the rock")
	_check(lvl.attempts == 1, "fresh level starts on attempt 1")

	lvl.request_move(Vector2i.RIGHT)  # push rock right, Francis Scott follows
	_check(b.player == Vector2i(2, 1), "player advanced")
	_check(lvl.occ_nodes.has(Vector2i(3, 1)), "rock node relocated to pushed cell")

	lvl.restart()
	_check(b.player == Vector2i(1, 1), "restart restored initial state")
	_check(lvl.occ_nodes.has(Vector2i(2, 1)), "restart rebuilt occupant nodes")
	_check(lvl.attempts == 2, "restart counts as another attempt")
	lvl.free()
