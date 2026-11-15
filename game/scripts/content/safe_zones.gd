extends RefCounted
class_name SafeZones

## The protected grounds as the interface reads them: safe_zones.json's
## upright cylinders and each map's list of them (maps.json `safe_zones`),
## the same rule the server enforces (realm_rules Rules::protected): inside
## one nobody takes or deals damage. The client only shows it.

static var _zones: Array = []
static var _by_map: Dictionary = {}

static func _load() -> void:
	if not _zones.is_empty() or not _by_map.is_empty():
		return
	var table: Variant = RealmContent.table("safe_zones")
	if table is Dictionary:
		_zones = (table as Dictionary).get("zones", [])
	var maps: Variant = RealmContent.table("maps")
	if maps is Dictionary:
		var all: Dictionary = (maps as Dictionary).get("maps", {})
		for id: String in all:
			_by_map[id] = (all[id] as Dictionary).get("safe_zones", [])

## The zones of `map` ([{id, center, radius, y_min, y_max}]).
static func of_map(map: String) -> Array:
	_load()
	var ids: Array = _by_map.get(map, [])
	return _zones.filter(func(z): return ids.has(String((z as Dictionary).get("id", ""))))

## The id of the zone of `map` that holds `at` ("" when none).
static func zone_at(map: String, at: Vector3) -> String:
	for zone: Dictionary in of_map(map):
		var c: Array = zone.get("center", [0.0, 0.0, 0.0])
		var r := float(zone.get("radius", 0.0))
		if at.y < float(zone.get("y_min", -1.0e6)) or at.y > float(zone.get("y_max", 1.0e6)):
			continue
		if Vector2(at.x - float(c[0]), at.z - float(c[2])).length_squared() <= r * r:
			return String(zone.get("id", ""))
	return ""
