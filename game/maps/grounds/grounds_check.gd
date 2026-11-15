extends Node

## `--check-grounds`: the grounds drawn with the old art, short (well under
## 90 s, no long walks, no teleports). With build/logs/gup_grounds.sh (the
## coordinator and the grounds server on their own ports) and
## `--server 127.0.0.1:7821 --character 900951`, standing at the courtyard
## spawn:
##
##   built     the scene built (its parts' times) and the player joined
##   feet      the feet on the drawn ground at the spawn: the drawn surface
##             under them (the terrain, or a drawn mesh above it: the paving)
##             within FEET_TOLERANCE of the predicted body
##   align     the drawn world against the server's pack (RealmSession.pick)
##             at fixed spots: the courtyard, the lake shore, Orvell, the
##             Trial gate, a hill: vertical probes (the top surface) and
##             horizontal ones (where a wall blocks)
##   views     five fixed camera views round the spawn, each captured and
##             timed (vsync off: frame time, fps, GPU time); two of them again
##             with the pack's shapes laid over the art (magenta)
##   survey    the camera alone (the player stays) over the lake shore,
##             Orvell, the Trial gate and a hill: the art, and the pack's
##             shapes over it
##   walk      a few metres down the lake walk (W held), the feet sampled on
##             the way and where it stops
##   memory    the process's working set, the video memory in use and the
##             grounds' own textures by folder (an estimate from their size
##             and format)
##
## Captures in build/captures/grounds/. The verdict line quits 0 only when
## every part passed; any part that cannot finish fails at once.

const Layout := preload("res://maps/grounds/grounds_layout.gd")
const TIMEOUT := 85.0
const JOIN_TIMEOUT := 25.0
const FEET_TOLERANCE := 0.10
## Where a horizontal probe may differ (m): the old builders and the export
## ran the same code, so only float noise is left.
const WALL_TOLERANCE := 0.15
const SAMPLE_FRAMES := 90
## RealmSession.pick's bead radius (realm_sim LINE_RADIUS): a collider is met
## this far before its surface.
const BEAD := 0.04
## The village houses' colliders (village_kit.json, the old build script's
## walls box) stand 0.2 m proud of the walls all round: over the timber
## frames, sills and doorsteps the walls carry.
const VILLAGE_MARGIN := 0.2
## Collision layer (bit) the probe bodies built from the drawn meshes use.
const PROBE_LAYER := 1 << 19
const CAPTURES := "build/captures/grounds"
## [name, cam_yaw, cam_pitch, cam_distance]
const VIEWS := [
	["castle", 0.0, -0.22, 14.0],
	["lake", PI, -0.30, 12.0],
	["trial", -PI * 0.5, -0.18, 12.0],
	["valley", -PI * 0.5 - 0.6, -0.55, 60.0],
	["fountain", 0.35, -0.08, 5.0],
]
## Camera-only survey spots: [name, landmark (or x, z), camera offset from
## its ground point, look-at height over that point].
const SURVEY := [
	["shore", "boathouse", Vector3(-26.0, 14.0, 34.0), 2.0],
	["orvell", "orvell_square", Vector3(30.0, 22.0, 46.0), 3.0],
	["trial_gate", Vector2(70.0, 69.0), Vector3(-10.0, 6.0, -16.0), 3.0],
	["hill", "stone_circle", Vector3(28.0, 12.0, 30.0), 2.0],
]

var game: Node
var map: Node3D
var _started := 0.0
var _done := false
var _results: Dictionary = {}
var _failures: Array = []
var _probe_root: Node3D
var _probed: Dictionary = {}
## While set, the camera stands here (after main placed it behind the player).
var _camera_at: Variant = null


func _ready() -> void:
	_started = _now()
	_run.call_deferred()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	if not _done and _now() - _started > TIMEOUT:
		_fail("timeout")
	if _camera_at != null and game.camera != null:
		game.camera.global_transform = _camera_at


func _fail(why: String) -> void:
	if _done:
		return
	_failures.append(why)
	_verdict()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_root().path_join(CAPTURES))
	# join and build
	while game.session == null or String(game.session.status()) != "joined" or not bool(game.built):
		if _done:
			return
		if _now() - _started > JOIN_TIMEOUT:
			_fail("not joined: %s" % (game.session.status() if game.session != null else "no session"))
			return
		await get_tree().process_frame
	_results["built_ms"] = map.get("build_ms")
	_results["quality"] = map.get("quality")
	if map.get("terrain") == null:
		_fail("the grounds scene built nothing")
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# settle: the body lands, shaders compile on the first frames
	await _wait(2.5)
	# the drawn meshes round the spawn as probe bodies first (a body added in
	# a frame is not met by a ray until a physics step has run)
	_results["memory_settled"] = _memory_now()
	var me: Vector3 = game.session.own_position()
	await _probes_for([AABB(me - Vector3(40, 10, 40), Vector3(80, 30, 80))])
	_feet("feet_spawn")
	await _align()
	for view: Array in VIEWS:
		await _view(view)
	await _overlay()
	await _survey()
	await _walk()
	# the probe bodies are the check's own: gone before the last measure
	if _probe_root != null:
		_probe_root.queue_free()
		_probe_root = null
	await _wait(0.5)
	_memory()
	_verdict()


func _root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


func _wait(seconds: float) -> void:
	var until := _now() + seconds
	while _now() < until and not _done:
		await get_tree().process_frame


# ------------------------------------------------------------------ feet

## The drawn surface under (x, z), looking down from `from_y`: the terrain or
## the highest drawn mesh between it and from_y.
func drawn_surface(x: float, z: float, from_y: float) -> float:
	var ground := Layout.height_at(x, z)
	var hit := _drawn_ray(Vector3(x, from_y, z), Vector3(x, (ground if not is_nan(ground) else from_y - 50.0) - 0.5, z))
	if not hit.is_empty():
		return maxf(float(hit["position"].y), ground if not is_nan(ground) else -INF)
	return ground


## The pack's top surface under (x, z) from `from_y` (a whole number; NAN when
## none within 600 m). RealmSession.pick sweeps a bead (BEAD) against the
## colliders, exact, and walks the terrain grid in 1 m steps (the last step
## above it): a collider's surface is the bead's contact less its radius; the
## terrain's is found by halving the last step with millimetre picks.
func pack_surface(x: float, z: float, from_y: float) -> float:
	var hit: Dictionary = game.session.pick(Vector3(x, from_y, z), Vector3.DOWN, 600.0)
	if hit.is_empty():
		return NAN
	var p: Vector3 = hit["point"]
	if p.y <= from_y - 599.9:
		return NAN
	var fall := from_y - p.y
	if absf(fall - roundf(fall)) > 0.002:
		return p.y - BEAD
	var hi := p.y
	var lo := p.y - 1.0
	for i in 24:
		var mid := (lo + hi) * 0.5
		var probe: Dictionary = game.session.pick(Vector3(x, mid, z), Vector3.DOWN, 0.001)
		if (probe["point"] as Vector3).y > mid - 0.0009:
			lo = mid
		else:
			hi = mid
	return hi - 0.001


func _feet(key: String) -> float:
	var me: Vector3 = game.session.own_position()
	var drawn := drawn_surface(me.x, me.z, me.y + 1.5)
	var delta := me.y - drawn
	_results[key] = {"at": _v(me), "drawn": snappedf(drawn, 0.001), "delta": snappedf(delta, 0.001)}
	if is_nan(drawn) or absf(delta) > FEET_TOLERANCE:
		_failures.append("%s: feet %.3f vs drawn %.3f" % [key, me.y, drawn])
	return delta


# ------------------------------------------------------------------ align

## Vertical probes [name, x, z] (the top surface from 300 m) and horizontal
## ones [name, from (x, height over the ground, z), direction].
func _align() -> void:
	var lm := func(id: String, fallback: Vector2) -> Vector2:
		var p := Layout.landmark(id)
		return Vector2(p.x, p.z) if p != Vector3.INF else fallback
	var court: Vector2 = lm.call("courtyard", Vector2(0, 65))
	var square: Vector2 = lm.call("orvell_square", Vector2(680, -140))
	var boat: Vector2 = lm.call("boathouse", Vector2(0, 200))
	var circle: Vector2 = lm.call("stone_circle", Vector2(-600, -600))
	var vertical := [
		["courtyard_flagstones", court.x + 12.0, court.y + 3.0],
		["courtyard_lawn", court.x + 26.0, court.y + 14.0],
		["courtyard_spawn", 0.0, 78.0],
		["castle_apron", 0.0, 9.0],
		["castle_roof", 0.0, -4.0],
		["lake_jetty", boat.x, boat.y + 18.0],
		["lake_beach", boat.x + 30.0, boat.y + 4.0],
		["orvell_square", square.x + 14.0, square.y + 6.0],
		["orvell_well", square.x, square.y],
		["trial_porch", 70.0, 66.0],
		["hill_circle", circle.x + 6.0, circle.y + 3.0],
		["hill_open", circle.x + 60.0, circle.y - 40.0],
	]
	var horizontal := [
		["castle_front", Vector3(-8.0, 1.5, 22.0), Vector3(0, 0, -1)],
		["castle_tower", Vector3(-30.0, 1.5, 12.0), Vector3(13.0, 0, -8.0)],
		["balustrade", Vector3(court.x + 20.0, 0.1, court.y + 20.0), Vector3(1, 0, 1)],
		["trial_hall", Vector3(64.0, 2.0, 60.0), Vector3(0.25, 0, 1)],
		["orvell_inn", Vector3(square.x, 1.5, square.y - 6.0), Vector3(0, 0, -1), VILLAGE_MARGIN],
		["orvell_ring", Vector3(square.x + 6.0, 1.5, square.y + 3.0), Vector3(1, 0, 0.4), VILLAGE_MARGIN],
		["boathouse", Vector3(boat.x - 8.0, 1.5, boat.y + 4.0), Vector3(1, 0, 0)],
	]
	var boxes: Array = []
	for p: Array in vertical:
		boxes.append(AABB(Vector3(p[1], -50.0, p[2]), Vector3(0, 350.0, 0)))
	for p: Array in horizontal:
		var at: Vector3 = p[1]
		var g := Layout.height_at(at.x, at.z)
		var from := Vector3(at.x, (g if not is_nan(g) else 0.0) + at.y, at.z)
		boxes.append(AABB(from, Vector3.ZERO).expand(from + (p[2] as Vector3).normalized() * 80.0))
	await _probes_for(boxes)
	var worst_v := 0.0
	var rows: Dictionary = {}
	for p: Array in vertical:
		var x: float = p[1]
		var z: float = p[2]
		var pack := pack_surface(x, z, 300.0)
		var drawn := drawn_surface(x, z, 300.0)
		var d := absf(pack - drawn)
		rows[p[0]] = {"pack": snappedf(pack, 0.001), "drawn": snappedf(drawn, 0.001), "delta": snappedf(pack - drawn, 0.001)}
		if is_nan(pack) or is_nan(drawn) or d > FEET_TOLERANCE:
			_failures.append("align %s: pack %.3f drawn %.3f" % [p[0], pack, drawn])
		elif d > worst_v:
			worst_v = d
	var worst_h := 0.0
	for p: Array in horizontal:
		var at: Vector3 = p[1]
		var g := Layout.height_at(at.x, at.z)
		var from := Vector3(at.x, (g if not is_nan(g) else 0.0) + at.y, at.z)
		var dir: Vector3 = (p[2] as Vector3).normalized()
		var hit: Dictionary = game.session.pick(from, dir, 80.0)
		var pack_t := from.distance_to(hit["point"]) + BEAD if not hit.is_empty() else INF
		if pack_t >= 79.9:
			pack_t = INF
		var drawn_hit := _drawn_ray(from, from + dir * 80.0)
		var drawn_t := from.distance_to(drawn_hit["position"]) if not drawn_hit.is_empty() else INF
		# the terrain rising ahead blocks too
		drawn_t = minf(drawn_t, _terrain_ray(from, dir, 80.0))
		# a village house's collider stands its margin proud of the plaster
		var margin: float = p[3] if p.size() > 3 else 0.0
		var d := absf(pack_t + margin - drawn_t) if pack_t < INF and drawn_t < INF else (0.0 if pack_t == drawn_t else INF)
		rows[p[0]] = {"pack_m": snappedf(pack_t, 0.001) if pack_t < INF else -1.0, "drawn_m": snappedf(drawn_t, 0.001) if drawn_t < INF else -1.0}
		if d > WALL_TOLERANCE:
			_failures.append("align %s: wall at %.3f (pack) vs %.3f (drawn)" % [p[0], pack_t, drawn_t])
		elif d > worst_h:
			worst_h = d
	_results["align"] = rows
	_results["align_worst_vertical"] = snappedf(worst_v, 0.001)
	_results["align_worst_horizontal"] = snappedf(worst_h, 0.001)


## Where a ray first meets the drawn terrain (stepped, then bisected), INF
## when it does not within `reach`.
func _terrain_ray(from: Vector3, dir: Vector3, reach: float) -> float:
	var prev := 0.0
	var t := 0.25
	while t <= reach:
		var p := from + dir * t
		var h := Layout.height_at(p.x, p.z)
		if not is_nan(h) and p.y <= h:
			var lo := prev
			var hi := t
			for i in 20:
				var mid := (lo + hi) * 0.5
				var q := from + dir * mid
				if q.y <= Layout.height_at(q.x, q.z):
					hi = mid
				else:
					lo = mid
			return hi
		prev = t
		t += 0.25
	return INF


## The drawn meshes whose bounds meet any of `boxes` as probe bodies (their
## triangles), then two physics steps so rays meet them.
func _probes_for(boxes: Array) -> void:
	for box: AABB in boxes:
		_ensure_probes(box.grow(0.05))
	await get_tree().physics_frame
	await get_tree().physics_frame


## A ray against the drawn meshes made probe bodies (_probes_for).
func _drawn_ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, PROBE_LAYER)
	query.hit_back_faces = true
	return map.get_world_3d().direct_space_state.intersect_ray(query)


func _ensure_probes(segment: AABB) -> void:
	if _probe_root == null:
		_probe_root = Node3D.new()
		_probe_root.name = "GroundsProbes"
		map.add_child(_probe_root)
	for node: Node in map.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if _probed.has(mi) or mi.mesh == null or not _solid(mi):
			continue
		var box := mi.global_transform * mi.get_aabb()
		if not box.intersects(segment):
			continue
		_probed[mi] = true
		var faces := mi.mesh.get_faces()
		if faces.is_empty():
			continue
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(faces)
		var body := StaticBody3D.new()
		body.collision_layer = PROBE_LAYER
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		_probe_root.add_child(body)
		body.global_transform = mi.global_transform


## Surfaces a body stands on or is stopped by: not water, glass, flowers,
## labels or webs.
func _solid(mi: MeshInstance3D) -> bool:
	var name := String(mi.name)
	for skip: String in ["Water", "Floor_", "Stream", "Lake", "glass", "Horizon", "Bed_", "ember", "banner", "cloth"]:
		if name.contains(skip):
			return false
	return mi.is_visible_in_tree() and mi.get_parent() != _probe_root


# ------------------------------------------------------------------ views

func _view(view: Array) -> void:
	game.cam_yaw = float(view[1])
	game.cam_pitch = float(view[2])
	game.cam_distance = float(view[3])
	await _wait(1.2)
	var timing := await _time_frames()
	_capture(String(view[0]))
	_results["view_" + String(view[0])] = timing


## Frame time (ms, average and worst), fps and GPU time over SAMPLE_FRAMES.
func _time_frames() -> Dictionary:
	var rid := get_viewport().get_viewport_rid()
	var total := 0.0
	var worst := 0.0
	var gpu := 0.0
	var last := Time.get_ticks_usec()
	for i in SAMPLE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		last = now
		total += ms
		worst = maxf(worst, ms)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	var avg := total / SAMPLE_FRAMES
	return {"ms": snappedf(avg, 0.01), "fps": snappedf(1000.0 / avg, 0.1), "worst_ms": snappedf(worst, 0.1),
		"gpu_ms": snappedf(gpu / SAMPLE_FRAMES, 0.01), "draws": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))}


func _capture(view_name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := _root().path_join(CAPTURES).path_join("%s.png" % view_name)
	if image == null or image.save_png(path) != OK:
		_failures.append("capture %s" % view_name)


## The castle and trial views again with the pack's shapes laid over the art
## (alignment by eye).
func _overlay() -> void:
	var shapes := _pack_overlay()
	for view: Array in [VIEWS[0], VIEWS[2]]:
		game.cam_yaw = float(view[1])
		game.cam_pitch = float(view[2])
		game.cam_distance = float(view[3])
		await _wait(0.8)
		_capture("overlay_" + String(view[0]))
	shapes.queue_free()


## The camera alone over each SURVEY spot: the art, then the pack over it.
func _survey() -> void:
	for spot: Array in SURVEY:
		var at: Vector2
		if spot[1] is String:
			var p := Layout.landmark(String(spot[1]))
			at = Vector2(p.x, p.z)
		else:
			at = spot[1]
		var ground := Layout.ground(at.x, at.y)
		var eye: Vector3 = ground + (spot[2] as Vector3)
		var look := ground + Vector3.UP * float(spot[3])
		_camera_at = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
		await _wait(1.5)
		_capture("survey_" + String(spot[0]))
		var shapes := _pack_overlay()
		await _wait(0.3)
		_capture("survey_%s_pack" % spot[0])
		shapes.queue_free()
	_camera_at = null


## The pack's colliders, translucent magenta, over the art.
func _pack_overlay() -> Node3D:
	var shapes := Node3D.new()
	shapes.name = "PackOverlay"
	map.add_child(shapes)
	var tint := StandardMaterial3D.new()
	tint.albedo_color = Color(1.0, 0.2, 0.8, 0.28)
	tint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tint.cull_mode = BaseMaterial3D.CULL_DISABLED
	var walls: ArrayMesh = game.session.collider_mesh()
	if walls != null:
		var mi := MeshInstance3D.new()
		mi.name = "PackWalls"
		mi.mesh = walls
		mi.material_override = tint
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		shapes.add_child(mi)
		mi.global_position = game.session.copy_offset()
	return shapes


# ------------------------------------------------------------------ walk

## W held for a little over two seconds down the lake walk (south), the feet
## sampled every few frames on the way, then where it stops.
func _walk() -> void:
	game.cam_yaw = PI
	game.cam_pitch = -0.3
	game.cam_distance = 9.0
	var start: Vector3 = game.session.own_position()
	# the lake walk ahead as probe bodies (the cover is already)
	await _probes_for([AABB(start + Vector3(-8, -10, -5), Vector3(16, 30, 40))])
	var key := InputEventKey.new()
	key.physical_keycode = GameSettings.key("move_forward")
	key.keycode = key.physical_keycode
	key.pressed = true
	Input.parse_input_event(key)
	var worst := 0.0
	var samples := 0
	var until := _now() + 2.2
	while _now() < until and not _done:
		await get_tree().process_frame
		if Engine.get_process_frames() % 4 != 0:
			continue
		var me: Vector3 = game.session.own_position()
		var drawn := drawn_surface(me.x, me.z, me.y + 1.5)
		if not is_nan(drawn):
			worst = maxf(worst, absf(me.y - drawn))
			samples += 1
	var up := key.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)
	await _wait(0.8)
	var end: Vector3 = game.session.own_position()
	var walked := Vector2(end.x - start.x, end.z - start.z).length()
	_results["walk"] = {"metres": snappedf(walked, 0.01), "samples": samples, "worst_delta": snappedf(worst, 0.001)}
	if walked < 3.0:
		_failures.append("walk: only %.2f m" % walked)
	if worst > FEET_TOLERANCE:
		_failures.append("walk: feet off the drawn ground by %.3f" % worst)
	_feet("feet_walked")
	_capture("walked")


# ------------------------------------------------------------------ memory

func _memory() -> void:
	var mem := _memory_now()
	mem["grounds_textures"] = _texture_census()
	mem["grounds_meshes"] = _mesh_census()
	_results["memory"] = mem


func _memory_now() -> Dictionary:
	var mem := {"static_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1),
		"video_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"texture_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1)}
	if OS.get_name() == "Windows":
		var out: Array = []
		OS.execute("tasklist", ["/FI", "PID eq %d" % OS.get_process_id(), "/FO", "CSV", "/NH"], out)
		if not out.is_empty():
			var cells := String(out[0]).strip_edges().split("\",\"")
			if cells.size() >= 5:
				var kb := cells[4].replace("\"", "").replace(".", "").replace(",", "").replace(" K", "").replace(" KB", "").strip_edges()
				mem["working_set_mb"] = snappedf(kb.to_float() / 1024.0, 0.1)
	return mem


## The grounds' own geometry: drawn triangles (each mesh once) and vertices,
## and the instance counts the multimeshes draw.
func _mesh_census() -> Dictionary:
	var meshes := {}
	var instances := 0
	for node: Node in map.find_children("*", "GeometryInstance3D", true, false):
		var mesh: Mesh = null
		if node is MeshInstance3D:
			mesh = (node as MeshInstance3D).mesh
		elif node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh != null:
			mesh = (node as MultiMeshInstance3D).multimesh.mesh
			instances += (node as MultiMeshInstance3D).multimesh.instance_count
		if mesh != null and mesh is ArrayMesh:
			meshes[mesh.get_rid()] = mesh
	var verts := 0
	var tris := 0
	for rid: RID in meshes:
		var mesh: ArrayMesh = meshes[rid]
		for i in mesh.get_surface_count():
			var n := mesh.surface_get_array_len(i)
			var idx := mesh.surface_get_array_index_len(i)
			verts += n
			tris += (idx if idx > 0 else n) / 3
	return {"meshes": meshes.size(), "vertices_k": verts / 1000, "triangles_k": tris / 1000, "multimesh_instances": instances}


## The grounds' textures (every material under the map and the terrain's
## assets), MB by folder, from each texture's size, format and mipmaps.
func _texture_census() -> Dictionary:
	var seen := {}
	var materials: Array = []
	for node: Node in map.find_children("*", "GeometryInstance3D", true, false):
		var geo := node as GeometryInstance3D
		if geo.material_override != null:
			materials.append(geo.material_override)
		var mesh: Mesh = null
		if geo is MeshInstance3D:
			mesh = (geo as MeshInstance3D).mesh
			for i in (geo as MeshInstance3D).get_surface_override_material_count():
				materials.append((geo as MeshInstance3D).get_surface_override_material(i))
		elif geo is MultiMeshInstance3D and (geo as MultiMeshInstance3D).multimesh != null:
			mesh = (geo as MultiMeshInstance3D).multimesh.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				materials.append(mesh.surface_get_material(i))
	var terrain: Node = map.get("terrain")
	if terrain != null:
		var assets: Variant = terrain.get("assets")
		for i in assets.get_texture_count():
			var t: Variant = assets.get_texture(i)
			if t != null:
				_count_texture(t.get("albedo_texture"), seen)
				_count_texture(t.get("normal_texture"), seen)
		for i in assets.get_mesh_count():
			var m: Variant = assets.get_mesh_asset(i)
			if m == null:
				continue
			for l in m.get_lod_count():
				var lod_mesh: Mesh = m.get_mesh(l)
				if lod_mesh != null:
					for k in lod_mesh.get_surface_count():
						materials.append(lod_mesh.surface_get_material(k))
	for mat: Variant in materials:
		if mat is BaseMaterial3D:
			for prop: String in ["albedo_texture", "normal_texture", "roughness_texture", "orm_texture", "metallic_texture", "ao_texture", "emission_texture"]:
				_count_texture((mat as BaseMaterial3D).get(prop), seen)
		elif mat is ShaderMaterial and (mat as ShaderMaterial).shader != null:
			for u: Dictionary in (mat as ShaderMaterial).shader.get_shader_uniform_list():
				_count_texture((mat as ShaderMaterial).get_shader_parameter(u["name"]), seen)
	var by_dir := {}
	var total := 0.0
	for key: Variant in seen:
		var entry: Array = seen[key]
		var dir := String(entry[0]).get_base_dir().trim_prefix("res://")
		by_dir[dir] = float(by_dir.get(dir, 0.0)) + float(entry[1])
		total += float(entry[1])
	var out := {"total_mb": snappedf(total / 1048576.0, 0.1)}
	var dirs := by_dir.keys()
	dirs.sort_custom(func(a, b): return by_dir[a] > by_dir[b])
	for dir: String in dirs.slice(0, 12):
		out[dir] = snappedf(by_dir[dir] / 1048576.0, 0.1)
	return out


func _count_texture(tex: Variant, seen: Dictionary) -> void:
	if not (tex is Texture) or seen.has((tex as Texture).get_rid()):
		return
	var bytes := 0.0
	if tex is Texture2D:
		var t := tex as Texture2D
		bytes = _texture_bytes(t.get_width(), t.get_height(), t.has_mipmaps(), t.get_format())
	elif tex is TextureLayered:
		var t := tex as TextureLayered
		bytes = _texture_bytes(t.get_width(), t.get_height(), t.has_mipmaps(), t.get_format()) * t.get_layers()
	seen[(tex as Texture).get_rid()] = [(tex as Resource).resource_path, bytes]


## A texture's video memory: bits per pixel by format, a third more with mipmaps.
static func _texture_bytes(w: int, h: int, mipmaps: bool, format: int) -> float:
	var bits := 32.0
	match format:
		Image.FORMAT_DXT1, Image.FORMAT_RGTC_R, Image.FORMAT_ETC, Image.FORMAT_ETC2_R11, Image.FORMAT_ETC2_R11S, 				Image.FORMAT_ETC2_RGB8, Image.FORMAT_ETC2_RGB8A1:
			bits = 4.0
		Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGTC_RG, Image.FORMAT_BPTC_RGBA, Image.FORMAT_BPTC_RGBF, 				Image.FORMAT_BPTC_RGBFU, Image.FORMAT_ETC2_RG11, Image.FORMAT_ETC2_RG11S, Image.FORMAT_ETC2_RGBA8, 				Image.FORMAT_ASTC_4x4, Image.FORMAT_L8, Image.FORMAT_R8:
			bits = 8.0
		Image.FORMAT_LA8, Image.FORMAT_RG8, Image.FORMAT_RH:
			bits = 16.0
		Image.FORMAT_RGB8:
			bits = 24.0
		Image.FORMAT_RGBAH, Image.FORMAT_RGF:
			bits = 64.0
		Image.FORMAT_RGBAF:
			bits = 128.0
	return float(w) * float(h) * bits / 8.0 * (4.0 / 3.0 if mipmaps else 1.0)


# ------------------------------------------------------------------ verdict

func _verdict() -> void:
	if _done:
		return
	_done = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	var worst_fps := INF
	for key: String in _results:
		if key.begins_with("view_"):
			worst_fps = minf(worst_fps, float(_results[key].get("fps", INF)))
	_results["worst_fps"] = worst_fps if worst_fps < INF else -1.0
	_results["seconds"] = snappedf(_now() - _started, 0.1)
	var passed := _failures.is_empty()
	print("grounds check: ", JSON.stringify(_results))
	print("grounds check verdict: %s%s" % ["PASS" if passed else "FAIL", "" if passed else " - " + "; ".join(_failures)])
	get_tree().quit(0 if passed else 1)


static func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.001), snappedf(p.z, 0.01)]
