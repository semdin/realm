extends Node
class_name MapWay

## Way-finding on the client (slice 5.14), as MapTravel and MapDungeon are
## travel and dungeons: it builds and runs
##
##   * the minimap (HudMinimap, top right) with the place's name and the
##     coordinates under it;
##   * the world map window (HudWorldMap, GameSettings "world_map", M);
##   * the waypoint (WayFinder): set from the world map, from a quest's
##     target on it, or by the dungeon guide's "Show the way to the gate"
##     (show_way_to_dungeon); its footprints in the world, cleared on arrival
##     with a notice;
##   * the zone banner (HudZoneBanner) when the player crosses into another
##     named place (MapPlaces).
##
## The painted map comes from the map pack the session already holds
## (MapSheets, RealmSession.map_image); the route from its walkable mesh
## (RealmSession.path_to). Presentation only: nothing here asks the server.

## How often the place under the player is looked up (seconds).
const PLACE_EVERY := 0.25

## main.gd (session, player, hud, npcs, quests, others, drawn, cam_yaw).
var game: Node
var map_name := ""
var finder: WayFinder
var minimap: HudMinimap
var world_map: HudWorldMap
var banner: HudZoneBanner
## The English name of the place the player stands in, and its hunting
## region ({} when none).
var place := ""
var hunt: Dictionary = {}
## The script time way-finding took a frame, averaged (ms; the check
## reports it): the waypoint, the minimap's follow and the place lookup.
var cost_ms := 0.0

var _sheet: Dictionary = {}
var _sheet_level := 1000
var _place_wait := 0.0
var _party: Dictionary = {}
var _party_wait := 0.0
var _place_y: Dictionary = {}

func setup(main: Node, map_id: String, ui_root: Control) -> void:
	game = main
	map_name = map_id
	name = "MapWay"
	var hud_at: int = game.hud.get_index()
	banner = HudZoneBanner.new()
	ui_root.add_child(banner)
	ui_root.move_child(banner, hud_at + 1)
	minimap = HudMinimap.new()
	minimap.way = self
	minimap.visible = false
	ui_root.add_child(minimap)
	ui_root.move_child(minimap, hud_at + 1)
	world_map = HudWorldMap.new()
	world_map.way = self
	ui_root.add_child(world_map)
	game.dungeon.guide_window.show_way = show_way_to_dungeon

## The map is drawn: the waypoint's guide stands in it (and picks up a mark
## made before the trip), the minimap shows.
func on_map_built() -> void:
	finder = WayFinder.new()
	game.add_child(finder)
	finder.setup(game, map_name)
	finder.arrived.connect(_on_arrived)
	if WayFinder.has_target():
		finder._reroute()
	minimap.visible = true

## Every frame once the map is drawn.
func tick(delta: float) -> void:
	if finder == null:
		return
	var started := Time.get_ticks_usec()
	finder.tick(delta)
	var me: Vector3 = game.session.own_position()
	var offset: Vector3 = game.session.copy_offset()
	var level := MapPlaces.castle_level(me.y - offset.y) if map_name == "castle_interior" else 0
	if level != _sheet_level or _sheet.is_empty():
		# the storey's sheet is painted on a thread: the old one stays up
		# until it is handed over
		var next := MapSheets.sheet(game.session, map_name, level)
		if not next.is_empty():
			_sheet = next
			_sheet_level = level
	if minimap.visible:
		minimap.tick(me, _sheet, float(game.player.facing), float(game.cam_yaw))
		var coords := MapPlaces.coords_text(map_name, Vector2(me.x, me.z), offset)
		if minimap.coords_label.text != coords:
			minimap.coords_label.text = coords
	_place_wait -= delta
	if _place_wait <= 0.0:
		_place_wait = PLACE_EVERY
		_update_place(me - offset)
	cost_ms = lerpf(cost_ms, (Time.get_ticks_usec() - started) / 1000.0, 0.05)

func _update_place(local: Vector3) -> void:
	place = MapPlaces.place_at(map_name, local)
	hunt = MapPlaces.hunting_region(map_name, local)
	var title := I18n.t(String(hunt.get("display", place)) if not hunt.is_empty() else place)
	if minimap.place_label.text != title:
		minimap.place_label.text = title
	banner.show_place(title, hunt, int(game.sheet_view.level))

## The party's other members standing on this map: entity -> name.
func party_ids() -> Dictionary:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _party_wait:
		return _party
	_party_wait = now + 0.5
	_party = {}
	var names := {}
	for m: Dictionary in game.hud.party_frames.shown_members():
		names[String(m.get("name", ""))] = true
	if names.is_empty():
		return _party
	for id: int in game.player_names:
		if id != int(game.session.own_entity()) and names.has(String(game.player_names[id])) and game.heroes.has(id):
			_party[id] = String(game.player_names[id])
	return _party

## Mark a waypoint (`point`: world coordinates on this map, the map's own
## elsewhere).
func set_waypoint(map_id: String, point: Vector3, label: String) -> void:
	if finder == null:
		return
	finder.set_target(map_id, point, label)

## The dungeon guide's "Show the way to the gate": the waypoint goes to the
## gate of dungeon `id` fewest doors away (the nearest of those); from
## another map the footprints lead to the door toward it. False when there
## is no way (inside the dungeon itself).
func show_way_to_dungeon(id: String) -> bool:
	var dungeon := DungeonData.dungeon(id)
	if dungeon.is_empty() or finder == null:
		return false
	var dungeon_map := String(dungeon.get("map", ""))
	var me: Vector3 = game.session.own_position()
	var best: Dictionary = {}
	var best_score := INF
	var all: Variant = RealmContent.table("maps")
	var portals: Array = (all as Dictionary).get("portals", []) if all is Dictionary else []
	for portal: Dictionary in portals:
		var from := String(portal.get("map_id", ""))
		if String(portal.get("to_map", "")) != dungeon_map or TravelData.instanced(from):
			continue
		var steps := WayFinder.hops(map_name, from)
		if steps < 0:
			continue
		var at := WayFinder.door_point(portal)
		var score := float(steps) * 100000.0
		if steps == 0:
			score += me.distance_to(at + (game.session.copy_offset() as Vector3))
		if score < best_score:
			best_score = score
			best = portal
	if best.is_empty():
		game.hud.show_notice(tr("No way leads from here to that gate."), "warn")
		return false
	var map_id := String(best["map_id"])
	var point := WayFinder.door_point(best)
	if map_id == map_name:
		point += game.session.copy_offset() as Vector3
	set_waypoint(map_id, point, I18n.t(String(dungeon.get("display", id))))
	game.hud.show_notice(tr("The footprints lead to the gate of %s.") % I18n.t(String(dungeon.get("display", id))), "info")
	return true

## The open quests' targets on this map, for the world map: the NPC to
## speak with, the place to visit, the dungeon's gate ({at, kind "quest" or
## "place", label, radius, quest}).
func quest_targets() -> Array:
	var out: Array = []
	var offset: Vector3 = game.session.copy_offset()
	var places := MapPlaces.quest_places()
	for q: Dictionary in game.quests.open_quests():
		var id := String(q.get("id", ""))
		if game.quests.is_ready(id):
			continue
		var title := I18n.t(String(q.get("title", "")))
		var target := String(q.get("target", ""))
		match String(q.get("type", "")):
			"talk":
				for npc: NpcView in game.npcs:
					if npc.npc_name == target:
						out.append({"at": npc.position, "kind": "quest", "label": title, "quest": id})
			"visit":
				var spot: Dictionary = places.get(target, {})
				if String(spot.get("map", "")) == map_name:
					var c: Array = spot.get("center", [0.0, 0.0])
					out.append({"at": _place_point(target, Vector2(float(c[0]), float(c[1])) + Vector2(offset.x, offset.z)),
						"kind": "place", "label": title, "radius": float(spot.get("radius", 0.0)), "quest": id})
			"dungeon":
				var dungeon_map := String(DungeonData.dungeon(target).get("map", ""))
				var door := WayFinder.door_to(map_name, dungeon_map)
				if not door.is_empty():
					out.append({"at": WayFinder.door_point(door) + offset, "kind": "quest", "label": title, "quest": id})
	return out

## A place's centre on the walkable ground (once per place).
func _place_point(key: String, at: Vector2) -> Vector3:
	if not _place_y.has(key):
		var me: Vector3 = game.session.own_position()
		_place_y[key] = game.session.nav_point(Vector3(at.x, me.y, at.y))
	return _place_y[key]

func _on_arrived() -> void:
	game.hud.show_notice(tr("You have reached your waypoint."), "good")
