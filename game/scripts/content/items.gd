extends RefCounted
class_name Items

## Item definitions from content/data/items.json (through RealmContent).

static var _table: Dictionary = {}

static func item(id: String) -> Dictionary:
	if _table.is_empty():
		var loaded: Variant = RealmContent.table("items")
		if loaded is Dictionary:
			_table = loaded
	return _table.get(id, {})
