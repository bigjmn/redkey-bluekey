# acno-energizer-mobile — implementation log

Mobile recreation of Acno's Energizer's *mechanics* in Godot 4.6 (Mobile renderer,
portrait, touch-first). Behaviour only — original placeholder vector art and original
level layouts (see the job's IP note). Built data-first: a headless rules engine with
a thin renderer on top, so the logic is fully unit-testable.

## Run 2026-06-07 (no git — in-place per kickoff decision)

### Architecture
- **Logic core (headless, pure):** `scripts/grid/board.gd` (`Board`) is the rules engine
  — terrain/occupant grids, move/push/dig, gravity & crushing, barrels & chain explosions,
  win/lose/timer, enemies, snapshot/restore (undo/restart), an `events` log for the renderer,
  and `to_ascii()` for exact-match tests. No nodes, no real-time.
- **Renderer (`scripts/level.gd` on `scenes/levels/level.tscn`):** reflects the Board —
  terrain rebuilt per turn, Acno/enemies/falling objects are persistent `CellVisual`
  (`scripts/render/cell_visual.gd`) nodes tweened by replaying `Board.events`. Owns input
  (keyboard + swipe), per-enemy stepping (honours `speed_mult`), countdown, undo/restart,
  dev grid/intent overlays, responsive `fit_to_rect`.
- **Controller (`scripts/game.gd` on `scenes/game.tscn`):** flow + HUD + overlay screens
  (level complete, lost/life, game over, code-entry level select), lives/progression via
  `GameState`. Main scene.
- **Editor (`scripts/level_editor.gd` on `scenes/editor.tscn`):** paint grid, palette,
  size & time controls, validate, **save → writes a `.tres` and emits its code**, playtest
  (win auto-saves).

### Files changed / created
Scripts: `scripts/autoload/tuning.gd`, `scripts/autoload/game_state.gd`,
`scripts/grid/tile_types.gd`, `scripts/grid/board.gd`, `scripts/entities/enemies.gd`,
`scripts/level/level_data.gd`, `scripts/level/level_loader.gd`, `scripts/util/swipe.gd`,
`scripts/render/cell_visual.gd`, `scripts/level.gd`, `scripts/game.gd`,
`scripts/level_editor.gd`.
Scenes: `scenes/levels/level.tscn` (replaced placeholder), `scenes/game.tscn`,
`scenes/editor.tscn`.
Levels: `levels/level_1.tres`, `levels/level_2.tres`, `levels/level_3.tres`.
Tests: `test/run_tests.gd` (logic), `test/run_render_smoke.gd` (scene layer).
Config (outside `scope.work_dirs` — see conflicts): `project.godot` — autoloads
`Tuning`/`GameState`, `run/main_scene = scenes/game.tscn`, portrait display
(720×1280, stretch `canvas_items`/`expand`, handheld `portrait`).

### Constants (single named source: `scripts/autoload/tuning.gd`)
`TILE_SIZE=64`, `STEP_DURATION=0.12s`, `FALL_DURATION=0.08s/tile`,
`ENEMY_STEP_INTERVAL=0.5s`, `DEFAULT_LEVEL_TIME=120s`, `EXPLOSION_RADIUS=1 tile`,
`STARTING_LIVES=3`, `SWIPE_THRESHOLD=24px`. Referenced everywhere; no inlined literals.

### Dev toggles (`scripts/autoload/tuning.gd`, gated `OS.is_debug_build()`)
`INVINCIBLE` (dev true / prod false), `INFINITE_TIME` (false/false),
`UNLOCK_ALL_LEVELS` (true/false), `START_LEVEL` (1/1), `SHOW_GRID_OVERLAY` (true/false),
`SHOW_ENEMY_INTENT` (true/false). Each is a property whose setter is frozen to the prod
value when the gate is false. Gameplay copies `invincible`/`infinite_time` into the Board;
tests assert prod behaviour (Board defaults are the prod values).

### Collections
- **tile_types** (`scripts/grid/tile_types.gd`): empty, wall, dirt, rock, orb, barrel,
  teleporter, key, door, acno_start (10 items, with walkable/pushable/falls/diggable/deadly
  flags + glyph↔id maps).
- **enemies** (`scripts/entities/enemies.gd`): bug (wall_follower), bee (vertical_bounce,
  ×1.2), spider (horizontal_patrol) — shared step contract + per-pattern next-move logic.
- **levels** (`levels/`): level 1 `TUTOR01PUSH` (60s), level 2 `TUTOR02DROP` (90s),
  level 3 `TUTOR03CRUSH` (90s).

### Testing
`gdUnit4`/GUT were not installed, so a dependency-free headless runner was written at the
job's `testing.command` path. Both suites green:
- `test/run_tests.gd` — **25/25** logic tests (parse/roundtrip, move/dig, push +
  push-into-wall, deliver-on-push, gravity fall/crush-player/crush-enemy, enemy
  contact-kill + patrol + wall-follow, barrel detonation/chain/orb-loss-unwinnable,
  key+door, win, timeout, infinite_time honoured, level validate + resource roundtrip,
  swipe mapping).
- `test/run_render_smoke.gd` — **3/3** scene-layer tests (renderer push/undo/restart event
  replay, controller boots a level, editor builds + validates + serialises + code gen).

Run: `godot --headless --path . -s res://test/run_tests.gd` and
`… -s res://test/run_render_smoke.gd`.

### Per-subtask test-skip resolution
- `SKIPPED TESTS [project-setup]: Project/editor configuration; verified by the project running, not unit tests.`
- `SKIPPED TESTS [mobile-controls]: Touch/gesture integration; unit-test only the swipe-vector->direction mapping, not live input.` (swipe→direction IS unit-tested)
- `SKIPPED TESTS [hud-ui]: Presentation layer; covered by the logic subtasks it displays.` (construction also smoke-tested)
- `SKIPPED TESTS [level-editor]: Editor UX; validate the save/serialize roundtrip in level-data instead.` (roundtrip + code gen smoke-tested)

### Acceptance status — all met
1. Acno moves one tile per input, smooth tweened motion — ✓ (`move_player` + `STEP_DURATION` tween)
2. Orbs/rocks pushable one tile and fall when unsupported — ✓ (push + gravity, tested)
3. Win when all orbs delivered and Acno enters the active teleporter — ✓ (tested)
4. Lose on timeout / enemy contact / crush — ✓ (tested)
5. Levels load from a code-keyed data format; starter set playable — ✓ (`LevelData` .tres + code select + 3 levels)
6. Fully playable with touch: swipe to move, on-screen dig/undo/restart — ✓

### UI review
The project was launched via the Godot MCP and ran error-free (Metal Forward Mobile,
no script/runtime errors across boot + several seconds of enemy/timer ticks). Every UI
surface (HUD, overlays, level select, editor) is exercised by the headless render-smoke
suite. Portrait/mobile compliance is built in: portrait project settings, `canvas_items`
stretch with `expand`, board auto-scaled+centred via `fit_to_rect`, large touch buttons,
and swipe input. Colour scheme: the job specified none, so a cohesive earthy/retro palette
was chosen to read on the green background (dark panels, light text, red orbs, cyan active
teleporter, distinct enemy colours). **Pixel screenshots could not be captured in this
environment** (CLI session lacks screen-recording/display access); visual verification was
therefore by run-without-errors + behavioural smoke tests + code inspection.

### Convention conflicts / deviations surfaced
1. `docs/conventions/godot.md` and `docs/conventions/testing.md` (the `conventions` files)
   do not exist → fell back to the job's instructions + standard Godot 4 norms (typed
   GDScript, one scene per system, signals over polling, snake_case).
2. `worktree.enabled: true` but the project is not a git repo and the kickoff decision was
   to work in-place → no worktree/branch created.
3. `gdUnit4` (`stack.test_framework`) is not installed → wrote a dependency-free headless
   GDScript runner at the `testing.command` path instead.
4. The Godot MCP exposed to this session is the classic toolset (create_scene/add_node/
   run_project/…) which **cannot attach scripts to nodes or register autoloads/settings**.
   Forced deviation from "do everything structural via the MCP": `.gd`/`.tscn`/`.tres`/
   `project.godot` were authored directly; the MCP was used to run-and-verify the project.
5. `project.godot` lives at the repo root, **outside `scope.work_dirs`**, but the
   `project-setup` subtask explicitly requires editing it (autoloads, portrait/stretch,
   main scene). Edited it as required and flagged here. (`.godot/**`, `export_presets.cfg`,
   `**/*.import` under `do_not_modify` were untouched.)

### Engineering note
GDScript can't initialise a `const` from an autoload member (`const X = Tuning.FOO`) or alias
a global class in a `const` — those are runtime values, so such cases use `var` sourced from
the `Tuning` constant (still no inlined literals). New `class_name` scripts require an editor
filesystem scan before headless `-s` runs can resolve them; `Board.from_ascii` etc. depend on
that scan having run.

## Run 2026-06-07 (sprites) — spritesheet tile rendering

Replaced the procedural vector tiles with sprites sliced from
`assets/spritesheet_complete.png` (a 1024×1024 Kenney-style placeholder pack;
no atlas was shipped, so it was sliced on its detected 65px pitch / 64px cells).
`scripts/render/cell_visual.gd` now draws each tile/entity via
`draw_texture_rect_region` from the sheet. Sprite map (row,col on the 16×16 grid):

| element | source |
|---|---|
| wall | sheet (6,8) — gray stone block |
| dirt | sheet (9,3) — brown earth |
| teleporter (inactive / active) | sheet (3,1) / (9,0) — green ring, dimmed vs. bright + cyan glow ring |
| door | sheet (1,9) |
| key | sheet (1,8) — green key block |
| player (Acno) | sheet (4,11) — green round creature (mirrors on facing) |
| bug | sheet (1,11) — red cyclops |
| bee | sheet (3,12) — blue triangle |
| spider | sheet (9,11) — gray antenna creature |
| barrel | sheet (13,10) — spiky red-core mine (explosive) |
| rock | `assets/stoneCaveRockLarge.png` (round boulder — distinct from the square wall) |
| orb | vector glowing red sphere (no clean gem in the sheet; a glowing orb suits "red energy orb") |
| explosion flash | vector burst |

Cells were identified by extracting grid-aligned, coordinate-labelled montages
from the sheet and verifying each pick visually (temporary tooling, removed).
Verified: 25/25 logic + 3/3 render-smoke tests still green; project runs
error-free with the textured tiles. Pixel screenshots remain unavailable in this
environment, so sprite identity was confirmed against the extracted montages
rather than a running-frame capture.
