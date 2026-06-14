extends Node
## Sfx (autoload): fire-and-forget sound effects. `play(name)` grabs a free
## pooled AudioStreamPlayer (so effects can overlap). Keys match the file names
## in assets/audio. Also auto-plays a click on EVERY UI button press: any
## BaseButton entering the tree gets its `pressed` wired here, unless it's in the
## "no_click" group (e.g. the editor's paint grid, which isn't a UI button).
##
## Registered first among the autoloads so it sees every node added afterwards.

const STREAMS := {
	"click": preload("res://assets/audio/click.ogg"),
	"explosion": preload("res://assets/audio/explosion.ogg"),
	"itemFall": preload("res://assets/audio/itemFall.ogg"),
	"powerUp": preload("res://assets/audio/powerUp.ogg"),
	"win": preload("res://assets/audio/win.ogg"),
	"lose": preload("res://assets/audio/lose.ogg"),
	"switch": preload("res://assets/audio/switch.ogg"),
	"gravityUp": preload("res://assets/audio/gravityUp.ogg"),
	"gravityDown": preload("res://assets/audio/gravityDown.ogg"),
}
const POOL_SIZE := 8

var _players: Array[AudioStreamPlayer] = []
var _next: int = 0

func _ready() -> void:
	_ensure_pool()
	# Global UI click: wire every button as it enters the tree.
	get_tree().node_added.connect(_on_node_added)

func _ensure_pool() -> void:
	if not _players.is_empty():
		return
	for _i: int in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

## Play a one-shot effect by name (unknown names are ignored).
func play(sound: String) -> void:
	if not is_inside_tree():
		return   # too early (autoload not yet in the tree) — pooled voices can't play
	if not SettingsModal.sounds_on:
		return   # muted via the gear menu's Sounds toggle
	var stream: AudioStream = STREAMS.get(sound)
	if stream == null:
		return
	_ensure_pool()
	var p: AudioStreamPlayer = null
	for pl: AudioStreamPlayer in _players:   # prefer a free voice
		if not pl.playing:
			p = pl
			break
	if p == null:                            # all busy -> reuse round-robin
		p = _players[_next]
		_next = (_next + 1) % _players.size()
	p.stream = stream
	p.play()

func _on_node_added(node: Node) -> void:
	if node is BaseButton and not node.is_in_group("no_click"):
		var btn := node as BaseButton
		if not btn.pressed.is_connected(_click):
			btn.pressed.connect(_click)

func _click() -> void:
	play("click")
