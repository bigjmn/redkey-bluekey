class_name LevelData
extends Resource
## A single playable level, stored as a .tres resource. The board is parsed from
## the ASCII `layout` at load time (glyphs -> tile_types, 'A' = Francis Scott).

@export var id: int = 0
@export var code: String = ""
@export_multiline var layout: String = ""
