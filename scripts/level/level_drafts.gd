class_name LevelDrafts
extends RefCounted
## Local work-in-progress editor saves ("drafts"). Unlike published levels these
## need NOT be valid — they hold the raw editor grid only. Stored in user:// so
## they survive across sessions and surface in the profile's "Saved Levels"
## section. Purely local; nothing here touches the social backend.

const PATH := "user://level_drafts.json"

## A layout queued to load into the level editor on its next open ("" = fresh
## grid). Set by the profile screen's "Edit" action, consumed by the editor.
static var pending_layout: String = ""

## All saved drafts, newest last: [{id, name, layout, w, h, savedAt}].
static func load_all() -> Array:
	if not FileAccess.file_exists(PATH):
		return []
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	return data if data is Array else []

## Append a new draft (no validation) and return it.
static func save_draft(layout: String, w: int, h: int) -> Dictionary:
	var drafts := load_all()
	var next_id := 1
	for d: Dictionary in drafts:
		next_id = maxi(next_id, int(d.get("id", 0)) + 1)
	var draft := {
		id = next_id,
		name = "Draft %d" % next_id,
		layout = layout,
		w = w,
		h = h,
		savedAt = Time.get_datetime_string_from_system(),
	}
	drafts.append(draft)
	_write(drafts)
	return draft

static func delete_draft(id: int) -> void:
	_write(load_all().filter(func(d: Dictionary) -> bool: return int(d.get("id", -1)) != id))

static func _write(drafts: Array) -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(drafts))
