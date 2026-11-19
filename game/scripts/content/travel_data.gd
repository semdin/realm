extends RefCounted
class_name TravelData

## The travel tables as the interface reads them: maps.json (each map's
## display name and flight rule, the doors between maps) and travel.json (the
## hearths, the Twinned Cabinets, the passages and the Waylink rules). Loaded
## once from RealmContent; the server decides every trip, this only says what
## stands where.

static var _maps: Dictionary = {}
static var _travel: Dictionary = {}

static func _load() -> void:
	if _maps.is_empty():
		var maps: Variant = RealmContent.table("maps")
		if maps is Dictionary:
			_maps = maps
	if _travel.is_empty():
		var travel: Variant = RealmContent.table("travel")
		if travel is Dictionary:
			_travel = travel

## One map's entry (display, flight_allowed, spawn_points, ...).
static func map(map_id: String) -> Dictionary:
	_load()
	return (_maps.get("maps", {}) as Dictionary).get(map_id, {})

## A map's name as players read it (translated).
static func display_name(map_id: String) -> String:
	return I18n.t(String(map(map_id).get("display", map_id)))

static func flight_allowed(map_id: String) -> bool:
	return bool(map(map_id).get("flight_allowed", false))

static func instanced(map_id: String) -> bool:
	return bool(map(map_id).get("instanced", false))

## The doors of `map_id` (maps.json `portals` whose `map_id` is it).
static func portals(map_id: String) -> Array:
	_load()
	return (_maps.get("portals", []) as Array).filter(func(p): return String(p.get("map_id", "")) == map_id)

## Every travel node by id (hearths, cabinets, passages).
static func nodes() -> Dictionary:
	_load()
	return _travel.get("nodes", {})

static func node(id: String) -> Dictionary:
	return nodes().get(id, {})

## A node kind's rules (travel.json `hearthway`, `cabinet`, `passage`), or the
## Waylink's (`waylink`).
static func rules(kind: String) -> Dictionary:
	_load()
	return _travel.get(kind, {})

## The hearth a trip costs: [item, how many].
static func hearth_price() -> Array:
	var r := rules("hearthway")
	return [String(r.get("item", "hearth_dust")), int(r.get("cost", 1))]

## How far from a node of `kind` its prompt shows (the server's radius).
static func radius(kind: String) -> float:
	return float(rules(kind).get("radius", 3.0))

## The direction a node faces (its `yaw`, degrees; the room side of a hearth).
static func facing(data: Dictionary) -> Vector3:
	var yaw := deg_to_rad(float(data.get("yaw", 0.0)))
	return Vector3(sin(yaw), 0.0, cos(yaw))
