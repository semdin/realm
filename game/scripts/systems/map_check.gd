extends Node

## `--check-map`: way-finding as a player uses it, on a dev join
## (build/logs/aup_map.sh: the coordinator and the grounds server; character
## 900901 from make_prepared_character.py, standing in the castle
## courtyard). Keys and clicks go in as real input events:
##
##   land      the minimap shows the painted sheet round the player with its
##             markers, the place's name and the coordinates (capture);
##             frame times with the minimap hidden and shown
##   map       the world map key opens the world map: the sheet, the player
##             on it, NPCs, doors and gates, travel objects, a quest target
##             (capture); frame times with it open
##   click     a click on the map ~50 m off sets the waypoint: the route on
##             the map (capture), then, the map closed, the footprints on the
##             ground and the route and pin on the minimap (capture)
##   walk      the check walks the route (steering along it as a player
##             would) until the waypoint clears on arrival with its notice;
##             leaving the courtyard on the way brings up the zone banner
##             (capture)
##   guide     the dungeon guide key opens the guide; its "Show the way to
##             the gate" lays the waypoint at the Trial Hall's gate and
##             closes the guide; the footprints and the beacon lead there
##             (capture with the map open, and in the world)
##
## On another map (`aup_map.sh castle` / `caverns` and `--map
## castle_interior` / `--map spider_caverns`) it surveys instead: the
## minimap, the world map (in the castle the ground floor, the dungeons and
## the third floor's plans), a click on the map that sets a waypoint and its
## route (captures).
##
## Captures in build/captures/map/ (the survey's under its map's name). The
## verdict line says what was seen and quits 0 only when each was.

const TIMEOUT := 180.0
const STEP_TIMEOUT := 20.0
const WALK_TIMEOUT := 60.0
## Where the click lands (grounds x, z): out of the courtyard, toward the
## training yard.
const CLICK_AT := Vector2(60.0, 31.0)
const TRIAL_GATE := Vector3(70.0, 58.0, 69.0)
## Frames each frame-time sample averages.
const SAMPLE_FRAMES := 180
const SURVEY := ["land", "minimap", "place", "coords", "map_open", "map_sheet", "map_player", "waypoint", "map_route"]
const WANTED := ["land", "minimap", "minimap_markers", "place", "coords", "map_open", "map_sheet", "map_player",
	"map_markers", "map_quest", "waypoint", "map_route", "footprints", "minimap_route", "beacon", "banner",
	"arrived", "guide_open", "gate_waypoint", "guide_closed", "gate_trail"]

var game: Node
var _seen: Dictionary = {}
var _captures: Array = []
var _started := 0.0
var _done := false
var _walk := 0.0
var _steer := false
var _frames: Dictionary = {}

func _ready() -> void:
	_started = _now()
	_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func walk_intent() -> float:
	return _walk

func _process(_delta: float) -> void:
	if not _done and _now() - _started > TIMEOUT:
		_verdict("timed out")
		return
	_walk = 0.0
	if _steer and WayFinder.has_target() and game.way.finder.path.size() >= 2:
		_follow_route()

## Steer as a player would: toward a point a few metres along the route
## from where the body is.
func _follow_route() -> void:
	var finder: WayFinder = game.way.finder
	var me: Vector3 = game.session.own_position()
	var s := finder._project(me).x
	var ahead: Vector3 = finder._at(s + 3.0)[0]
	var flat := Vector2(ahead.x - me.x, ahead.z - me.z)
	if flat.length() > 0.2:
		game.cam_yaw = atan2(-flat.x, -flat.y)
	_walk = 1.0

func _see(what: String, detail: Variant = true) -> void:
	if not _seen.has(what):
		print("realm check map: seen %s: %s" % [what, detail])
	_seen[what] = detail

func _until(test: Callable, seconds := STEP_TIMEOUT) -> bool:
	var end := _now() + seconds
	while _now() < end:
		if not is_inside_tree():
			return false
		if test.call():
			return true
		await get_tree().process_frame
	return false

func _frames_wait(count: int) -> void:
	for i in count:
		await get_tree().process_frame

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

func _capture(tag: String) -> void:
	await _frames_wait(3)
	if DisplayServer.get_name() == "headless":
		return
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/map")))
	if String(game.map_name) != "grounds":
		dir = dir.path_join(String(game.map_name))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check map: captured %s" % path)

func _key(keycode: int) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = down
		Input.parse_input_event(event)
		await _frames_wait(2)

## A left click at viewport point `at` (a press and a release, no motion).
func _click(at: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = at
	move.global_position = at
	Input.parse_input_event(move)
	await _frames_wait(2)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = down
		Input.parse_input_event(event)
		await _frames_wait(2)

## Mean frame time and the GPU's and the CPU's render time over
## SAMPLE_FRAMES frames (ms); way-finding's own script time is measured where
## it runs (MapWay.cost_ms, HudMinimap.cost_ms, HudWorldMap.cost_ms).
func _sample(tag: String) -> void:
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	await _frames_wait(10)
	var sums := [0.0, 0.0, 0.0]
	for i in SAMPLE_FRAMES:
		await get_tree().process_frame
		sums[0] += get_process_delta_time() * 1000.0
		sums[1] += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		sums[2] += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var n := float(SAMPLE_FRAMES)
	_frames[tag] = "frame %.2f, gpu %.2f, render cpu %.2f" % [sums[0] / n, sums[1] / n, sums[2] / n]
	print("realm check map: frame times %s: %s ms" % [tag, _frames[tag]])

func _run() -> void:
	if not await _until(func(): return game.built and String(game.session.status()) == "joined" \
			and not (game.session.sheet() as Dictionary).is_empty() and game.way.finder != null):
		_verdict("never joined (status %s)" % game.session.status())
		return
	var way: MapWay = game.way
	var me: Vector3 = game.session.own_position()
	_see("land", "at %s, map %s" % [me.snapped(Vector3(0.1, 0.1, 0.1)), way.map_name])
	WayFinder.target_local = Vector3.INF
	await _wait(1.5)
	if way.map_name != "grounds":
		await _survey(way)
		return
	# --- the minimap
	if await _until(func(): return not way._sheet.is_empty() and way.minimap._disc.visible):
		_see("minimap", "sheet %s px, painted in %.1f ms on its thread, handed over after %.1f ms, upload %.1f ms" % [
			str((way._sheet["texture"] as Texture2D).get_size()), float(way._sheet["ms"]), float(way._sheet["wait_ms"]),
			float(way._sheet["upload_ms"])])
	if await _until(func(): return int(way.minimap.drawn.get("npc", 0)) + int(way.minimap.drawn.get("mob", 0)) > 0, 8.0):
		_see("minimap_markers", way.minimap.drawn)
	if await _until(func(): return way.minimap.place_label.text != ""):
		_see("place", way.minimap.place_label.text)
	if way.minimap.coords_label.text.contains(","):
		_see("coords", way.minimap.coords_label.text)
	await _capture("minimap")
	await _capture_sheet(way._sheet, "sheet_castle", Rect2(-200, -200, 400, 400))
	for round in 2:
		way.minimap.visible = false
		await _sample("minimap hidden %d" % (round + 1))
		way.minimap.visible = true
		await _sample("minimap shown %d" % (round + 1))
	_frames["way script"] = "tick %.3f, minimap markers draw %.3f" % [way.cost_ms, way.minimap.cost_ms]
	# --- the world map
	await _key(GameSettings.key("world_map"))
	var window: HudWorldMap = way.world_map
	if await _until(func(): return window.visible and window.view.size.x > 100.0):
		_see("map_open", "mode %s, view %s" % [window.mode, window.view.size])
	await _frames_wait(4)
	if window.sheet.has("texture"):
		_see("map_sheet", "%s, rect %s" % [str((window.sheet["texture"] as Texture2D).get_size()), window.sheet["rect"]])
	var at: Vector2 = window.view.world_to_screen(Vector2(me.x, me.z))
	if Rect2(Vector2.ZERO, window.view.size).has_point(at):
		_see("map_player", "at %s on the map" % at.round())
	var kinds := {}
	for m: Dictionary in window.markers:
		kinds[String(m["kind"])] = int(kinds.get(String(m["kind"]), 0)) + 1
	if kinds.has("npc") and kinds.has("gate") and kinds.has("hearth"):
		_see("map_markers", kinds)
	if kinds.has("quest") or kinds.has("place"):
		_see("map_quest", window.markers.filter(func(m): return String(m["kind"]) in ["quest", "place"]).map(
			func(m): return String(m["label"])))
	await _capture("world_map")
	await _sample("world map open")
	_frames["map script"] = "process %.3f, draw %.3f" % [window.cost_ms, window.view.cost_ms]
	# --- a click on open ground sets the waypoint there
	await _click_waypoint(window, CLICK_AT)
	await _capture("waypoint_set")
	await _key(GameSettings.key("world_map"))
	await _until(func(): return not window.visible, 3.0)
	if await _until(func(): return way.finder._prints.multimesh.visible_instance_count > 0, 5.0):
		_see("footprints", way.finder._prints.multimesh.visible_instance_count)
	if await _until(func(): return int(way.minimap.drawn.get("route", 0)) > 0 and way.minimap.drawn.has("pin"), 3.0):
		_see("minimap_route", way.minimap.drawn)
	if way.finder._beacon.visible:
		_see("beacon", way.finder._beacon.global_position.snapped(Vector3(0.1, 0.1, 0.1)))
	# face along the route for the trail's picture
	_follow_route()
	await _wait(0.6)
	await _capture("trail")
	# --- walk the route until the waypoint clears
	var arrivals := way.finder.arrivals
	var notices_before: String = game.hud.notices.last_text
	_steer = true
	var banner_seen := false
	var end := _now() + WALK_TIMEOUT
	while _now() < end and way.finder.arrivals == arrivals:
		await get_tree().process_frame
		if not banner_seen and way.banner.is_showing():
			banner_seen = true
			_see("banner", "%s (%s)" % [way.banner.title_label.text, ", ".join(way.banner.announced)])
			await _capture("banner")
	_steer = false
	_frames["way script walking"] = "tick %.3f, minimap markers draw %.3f" % [way.cost_ms, way.minimap.cost_ms]
	if way.finder.arrivals > arrivals and not WayFinder.has_target():
		me = game.session.own_position()
		_see("arrived", "at %s, notice \"%s\" (was \"%s\")" % [me.snapped(Vector3(0.1, 0.1, 0.1)), game.hud.notices.last_text, notices_before])
	else:
		print("realm check map: walk ended at %s, %.0f m left" % [game.session.own_position(), way.finder.remaining()])
	await _wait(0.5)
	# --- the dungeon guide shows the way to the Trial Hall's gate
	await _key(GameSettings.key("dungeon_guide"))
	var guide: HudDungeonGuide = game.dungeon.guide_window
	if await _until(func(): return guide.visible, 3.0):
		_see("guide_open", guide.dungeon_id)
	guide.pick_dungeon("trial")
	await _frames_wait(3)
	var show_way := guide.find_child("ShowWay", true, false) as Button
	if show_way != null:
		show_way.pressed.emit()
	if await _until(func(): return WayFinder.has_target() and WayFinder.target_map == "grounds" \
			and WayFinder.target_local.distance_to(TRIAL_GATE) < 2.0, 3.0):
		_see("gate_waypoint", "%s \"%s\", route %d points, %.0f m" % [WayFinder.target_local.snapped(Vector3(0.1, 0.1, 0.1)),
			WayFinder.target_label, way.finder.path.size(), way.finder.remaining()])
	if not guide.visible:
		_see("guide_closed")
	await _key(GameSettings.key("world_map"))
	await _until(func(): return window.visible, 3.0)
	await _frames_wait(4)
	await _capture("gate_map")
	await _key(GameSettings.key("world_map"))
	_follow_route()
	await _wait(0.8)
	if way.finder._prints.multimesh.visible_instance_count > 0 and way.finder._beacon.visible:
		_see("gate_trail", "%d prints, beacon at %s" % [way.finder._prints.multimesh.visible_instance_count,
			way.finder.goal.snapped(Vector3(0.1, 0.1, 0.1))])
	await _capture("gate_trail")
	_verdict("")

## A click on the map at world `at` (on open ground: no marker under it);
## the waypoint must land on the walkable ground within a few metres.
func _click_waypoint(window: HudWorldMap, at: Vector2) -> void:
	var local := window.view.world_to_screen(at)
	if not window.view.marker_at(local).is_empty():
		print("realm check map: a marker lies under %s" % at)
		return
	await _click(window.view.get_global_transform_with_canvas() * local)
	if await _until(func(): return WayFinder.has_target() and game.way.finder.path.size() >= 2, 5.0):
		var goal: Vector3 = game.way.finder.goal
		var off := Vector2(goal.x - at.x, goal.z - at.y).length()
		if off < 6.0:
			_see("waypoint", "at %s (clicked %s, %.1f m off), route %d points, %.0f m" % [goal.snapped(Vector3(0.1, 0.1, 0.1)),
				at, off, game.way.finder.path.size(), game.way.finder.remaining()])
			_see("map_route", window.coords_of(Vector2(goal.x, goal.z)))
		else:
			print("realm check map: the waypoint landed %.1f m from the click (%s)" % [off, goal])

## A region of the painted sheet (world `rect`) as a picture, for review.
func _capture_sheet(sheet: Dictionary, tag: String, rect: Rect2) -> void:
	if sheet.is_empty() or DisplayServer.get_name() == "headless":
		return
	var image := (sheet["texture"] as Texture2D).get_image()
	var whole: Rect2 = sheet["rect"]
	var scale := image.get_width() / whole.size.x
	var region := Rect2i(Vector2i(((rect.position - whole.position) * scale).floor()), Vector2i((rect.size * scale).floor())) \
		.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if region.size.x <= 0:
		return
	if image.has_mipmaps():
		image.clear_mipmaps()
	var part := image.get_region(region)
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/map")))
	if String(game.map_name) != "grounds":
		dir = dir.path_join(String(game.map_name))
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if part.save_png(path) == OK:
		_captures.append(path)
		print("realm check map: captured %s" % path)

## Another map than the grounds: the minimap, the world map (the castle's
## storeys), a waypoint by a click and its route.
func _survey(way: MapWay) -> void:
	if await _until(func(): return not way._sheet.is_empty() and way.minimap._disc.visible):
		_see("minimap", "sheet %s px, %s, painted in %.1f ms" % [str((way._sheet["texture"] as Texture2D).get_size()),
			way._sheet["style"], float(way._sheet["ms"])])
	if await _until(func(): return way.minimap.place_label.text != ""):
		_see("place", way.minimap.place_label.text)
	if way.minimap.coords_label.text.contains(","):
		_see("coords", way.minimap.coords_label.text)
	await _capture("minimap")
	await _key(GameSettings.key("world_map"))
	var window: HudWorldMap = way.world_map
	if await _until(func(): return window.visible and not window.sheet.is_empty()):
		_see("map_open", "mode %s, level %d" % [window.mode, window.castle_level])
		_see("map_sheet", "%s, rect %s" % [str((window.sheet["texture"] as Texture2D).get_size()), window.sheet["rect"]])
	await _frames_wait(4)
	var me: Vector3 = game.session.own_position()
	if Rect2(Vector2.ZERO, window.view.size).has_point(window.view.world_to_screen(Vector2(me.x, me.z))):
		_see("map_player")
	await _capture("world_map")
	if window.mode == "castle":
		for lv: int in [-1, 3, 0]:
			window.show_level(lv)
			await _until(func(): return not window.sheet.is_empty(), 5.0)
			# the whole storey's plan
			window.view.zoom = window.view._min_zoom()
			window.view._clamp()
			await _frames_wait(4)
			await _capture("floor_%d" % lv)
		await _capture_sheet(window.sheet, "sheet_floor_0", window.sheet["rect"])
	# a click a little way off on the floor shown
	var target := Vector2(me.x, me.z) + Vector2(14.0, -18.0)
	var snapped: Vector3 = game.session.nav_point(Vector3(target.x, window.shown_floor_y() + 0.5, target.y))
	await _click_waypoint(window, Vector2(snapped.x, snapped.z))
	await _frames_wait(4)
	await _capture("waypoint_set")
	await _key(GameSettings.key("world_map"))
	_follow_route()
	await _wait(0.8)
	await _capture("trail")
	_verdict("")

func _verdict(failure: String) -> void:
	if _done:
		return
	_done = true
	set_process(false)
	_steer = false
	var stats: Dictionary = game.session.stats()
	var missing := (WANTED if String(game.map_name) == "grounds" else SURVEY).filter(func(k): return not _seen.has(k))
	var ok := failure == "" and missing.is_empty()
	print("realm check map: %s | seen {%s} | missing [%s] | frame times {%s} | sheet painted in %.1f ms | captures %d | corrections %d, snapshots %d" % [
		"ok" if ok else (failure if failure != "" else "incomplete"),
		" ; ".join(_seen.keys().map(func(k): return "%s: %s" % [k, _seen[k]])), ", ".join(missing),
		" ; ".join(_frames.keys().map(func(k): return "%s: %s" % [k, _frames[k]])), float(MapSheets.last.get("ms", 0.0)),
		_captures.size(), int(stats.get("corrections", 0)), int(stats.get("snapshots", 0))])
	for path in _captures:
		print("realm check map: capture ", path)
	get_tree().quit(0 if ok else 1)
