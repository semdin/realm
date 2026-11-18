extends RefCounted
class_name MapPlaces

## Where the player is, in the words the maps use (the old game's place
## names): the zone banner, the name under the minimap, the world map's
## labels and the coordinates readout all read this.
##
##   * The quest places (quests.json `places`, scoped to their map) come
##     first: the banner names the same area the server counts for a visit.
##   * On the grounds, the old layout's landmarks: the castle courtyard, the
##     boathouse and the landing by their spots, the lake by its water, the
##     castle promontory, the greenhouses and Ombrek's hut by their features,
##     the woods, the moors and Orvell by their regions, the mountain pass at
##     the rim; anywhere else is the valley.
##   * In the castle, the room the player stands in (the old castle layout's
##     rooms, by storey), else the storey; in the caverns the hunting floor;
##     elsewhere the map's own name (maps.json `display`).
##
## The coordinates are the map's own (maps.json `coord_origin`): two positive
## whole metres, X east and Y south, from its north-west corner; a dungeon
## copy's offset is taken off first.

## The lake's shore (the old layout's ellipse).
const LAKE_CENTRE := Vector2(0, 330)
const LAKE_RADII := Vector2(560, 300)
## Below this height in the bowl is the water (its surface stands at 0).
const LAKE_SHORE_Y := 2.0
## The castle's storeys stand every STOREY metres from CASTLE_Y.
const CASTLE_Y := 200.0
const STOREY := 10.0
const LEVEL_MIN := -1
const LEVEL_MAX := 7
# i18n-begin
const FLOOR_NAMES := {-1: "Dungeons", 0: "Ground", 1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 5: "5th", 6: "6th", 7: "7th"}
## The world map's place names on the grounds: [name, centre (x, z), size].
const GROUNDS_LABELS := [
	["Kaf Castle", Vector2(30, -70), 1.25],
	["Lake Lunra", Vector2(0, 360), 1.15],
	["Raven Woods", Vector2(-650, 160), 1.2],
	["Orvell", Vector2(680, -140), 1.0],
	["Northern Moors", Vector2(420, -720), 1.0],
	["Ombrek's Lookout", Vector2(-330, -10), 0.8],
	["Greenhouses", Vector2(-190, -185), 0.8],
	["Courtyard", Vector2(0, 92), 0.75],
	["Patrol Field", Vector2(330, -330), 0.8],
	["Orvell Landing", Vector2(610, 270), 0.75],
	["Blackweb Caverns", Vector2(-805, 392), 0.7],
]
## Spots by the water: [name, centre, radius].
const GROUNDS_SPOTS := [
	["Castle Courtyard", Vector2(0, 65), 34.0],
	["Boathouse", Vector2(-190, 64), 24.0],
	["Orvell Landing", Vector2(610, 260), 45.0],
]
## The layout's features: [name, centre, radius].
const GROUNDS_FEATURES := [
	["Kaf Castle", Vector2(0, 20), 150.0],
	["Greenhouses", Vector2(-175, -120), 55.0],
	["Ombrek's Lookout", Vector2(-280, -20), 55.0],
]
## The layout's regions: [name, polygon (x, z)].
const GROUNDS_REGIONS := [
	["Raven Woods", [Vector2(-300, -450), Vector2(-1024, -560), Vector2(-1024, 1024), Vector2(-120, 1024),
		Vector2(-230, 690), Vector2(-330, 140), Vector2(-330, -160)]],
	["Northern Moors", [Vector2(-150, -520), Vector2(1024, -520), Vector2(1024, -1024), Vector2(-150, -1024)]],
	["Orvell", [Vector2(540, -280), Vector2(820, -280), Vector2(820, 0), Vector2(540, 0)]],
]
## The castle's rooms: [name, storey level, x min, x max, z min, z max].
const CASTLE_ROOMS := [
	["Entrance Hall", 0, -18, 18, 20, 64],
	["Long Table", 0, -105, -21, 42, 70],
	["Duel Hall", 0, 21, 57, 40, 72],
	["Tidewheel Stair", 0, -23, 23, -29, 17],
	["Service Stair", 0, 89, 99, -28, -4],
	["East Corridor", 0, 26, 86, -12, -4],
	["East Corridor", 1, 26, 86, -12, -4],
	["Assay Hall", 1, 28, 54, -42, -15],
	["East Corridor", 2, 26, 86, -12, -4],
	["Muster Hall", 2, 28, 54, -42, -15],
	["Weaving Loft", 2, 57, 83, -42, -15],
	["East Corridor", 3, 26, 86, -12, -4],
	["Hall of Rolls", 3, -80, -26, -45, -5],
	["East Corridor", 4, 26, 86, -12, -4],
	["East Corridor", 5, 26, 86, -12, -4],
	["Torvan Quarters", 5, -56, -26, -35, -9],
	["East Corridor", 6, 26, 86, -12, -4],
	["Signal Loft", 6, -10, 10, -84, -64],
	["Upper Corridor", 7, 26, 86, -12, -4],
	["Nisera Quarters", 7, 28, 54, -42, -15],
	["Quartermaster's Loft", 7, 57, 83, -42, -15],
	["Dungeon Stair", -1, -4, 4, 20, 40],
	["Dungeon Crossing", -1, -15, 15, -21, 17],
	["Dungeon West", -1, -90, -18, -10, -4],
	["Dungeon East", -1, 18, 70, -10, -4],
	["Still Room", -1, -50, -26, -40, -13],
	["Ilvane Quarters", -1, -84, -56, -38, -13],
	["Kitchens", -1, 20, 40, -40, -13],
	["Velkar Quarters", -1, 43, 70, -38, -13],
]
# i18n-end

## The content tables read here, once: RealmContent.table builds a whole
## table's Variant on every call (the spawn table holds every pack), far too
## much for a per-frame lookup.
static var _places: Dictionary = {}
static var _regions: Array = []
static var _loaded := false

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var quests: Variant = RealmContent.table("quests")
	if quests is Dictionary:
		_places = (quests as Dictionary).get("places", {})
	var spawns: Variant = RealmContent.table("spawn_tables")
	if spawns is Dictionary:
		_regions = (spawns as Dictionary).get("regions", [])

## The quest places (quests.json `places`): name -> {map, center, radius}.
static func quest_places() -> Dictionary:
	_load()
	return _places

## The map's coordinate origin (maps.json `coord_origin`).
static func origin(map_id: String) -> Vector2:
	var o: Array = TravelData.map(map_id).get("coord_origin", [0.0, 0.0])
	return Vector2(float(o[0]), float(o[1])) if o.size() >= 2 else Vector2.ZERO

## "1010, 1088": a point (world x, z; `offset` the copy's, taken off first)
## in the map's own coordinates.
static func coords_text(map_id: String, at: Vector2, offset := Vector3.ZERO) -> String:
	var local := at - Vector2(offset.x, offset.z) - origin(map_id)
	return "%d, %d" % [roundi(local.x), roundi(local.y)]

## The castle storey at height `y` (-1 the dungeons .. 7).
static func castle_level(y: float) -> int:
	return clampi(floori((y - CASTLE_Y + 3.0) / STOREY), LEVEL_MIN, LEVEL_MAX)

## A storey's floor height.
static func storey_y(level: int) -> float:
	return CASTLE_Y + float(level) * STOREY

## "Ground floor", "3rd floor", "The Dungeons".
static func floor_title(level: int) -> String:
	if level < 0:
		return I18n.t("The Dungeons")
	return I18n.t("%s floor") % I18n.t(String(FLOOR_NAMES.get(level, "")))

## The quest place at `pos` on `map_id` (quests.json `places`), "" when none.
static func quest_place_at(map_id: String, pos: Vector3) -> String:
	var places := quest_places()
	var best := ""
	var best_r := INF
	for name: String in places:
		var place: Dictionary = places[name]
		if String(place.get("map", "")) != map_id:
			continue
		var c: Array = place.get("center", [0.0, 0.0])
		var r := float(place.get("radius", 0.0))
		# the smallest place that holds the point (a camp inside a wood)
		if Vector2(pos.x - float(c[0]), pos.z - float(c[1])).length() <= r and r < best_r:
			best_r = r
			best = name
	return best

## The English name of the place at `pos` (world; a copy's offset already
## taken off) on `map_id`; translate it where it is shown.
static func place_at(map_id: String, pos: Vector3) -> String:
	match map_id:
		"grounds":
			return _grounds_place(pos)
		"castle_interior":
			var level := castle_level(pos.y)
			for room: Array in CASTLE_ROOMS:
				if int(room[1]) == level and pos.x >= float(room[2]) and pos.x <= float(room[3]) \
						and pos.z >= float(room[4]) and pos.z <= float(room[5]):
					return String(room[0])
			return "Kaf Castle"
	var quest_place := quest_place_at(map_id, pos)
	if quest_place != "":
		return quest_place
	return String(TravelData.map(map_id).get("display", map_id))

static func _grounds_place(pos: Vector3) -> String:
	var xz := Vector2(pos.x, pos.z)
	var quest_place := quest_place_at("grounds", pos)
	if quest_place != "":
		return quest_place
	for spot: Array in GROUNDS_SPOTS:
		if xz.distance_to(spot[1]) < float(spot[2]):
			return String(spot[0])
	# on the lake: in its bowl and down at the water (the castle's rock and
	# the shore paths stand well above it)
	if pos.y < LAKE_SHORE_Y and ((xz - LAKE_CENTRE) / LAKE_RADII).length_squared() <= 1.0:
		return "Lake Lunra"
	for feature: Array in GROUNDS_FEATURES:
		if xz.distance_to(feature[1]) < float(feature[2]):
			return String(feature[0])
	for region: Array in GROUNDS_REGIONS:
		if Geometry2D.is_point_in_polygon(xz, PackedVector2Array(region[1])):
			return String(region[0])
	if xz.length() > 760.0:
		return "Mountain Pass"
	return "Kaf Valley"

## The hunting region (spawn_tables.json `regions` with a level band) at
## `pos` on `map_id`, or {}.
static func hunting_region(map_id: String, pos: Vector3) -> Dictionary:
	_load()
	for region: Dictionary in _regions:
		if not region.has("level_min") or String(region.get("map", "grounds")) != map_id:
			continue
		var c: Array = region.get("center", [0.0, 0.0])
		if Vector2(pos.x - float(c[0]), pos.z - float(c[1])).length() <= float(region.get("radius", 0.0)):
			return region
	return {}

## The hunting regions of `map_id` (with a level band).
static func hunting_regions(map_id: String) -> Array:
	_load()
	return _regions.filter(func(r: Dictionary):
		return r.has("level_min") and String(r.get("map", "grounds")) == map_id)

## A level band's colour against the player's level: grey far below, green
## fair, gold a stretch, red dangerous.
static func band_color(player_level: int, band_min: int, band_max: int) -> Color:
	if player_level > band_max + 5:
		return Color(0.62, 0.62, 0.62)
	if player_level >= band_min:
		return Color(0.55, 0.9, 0.5)
	if player_level >= band_min - 4:
		return Color(1.0, 0.82, 0.35)
	return Color(1.0, 0.4, 0.33)
