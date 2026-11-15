extends Node

## `--check-caverns` / `--check-dungeons`: the Blackweb Caverns or a dungeon
## map drawn where the server's ground and walls are, and what it costs
## (build/logs/dup6_caverns.sh, dup6_dungeons.sh; one map per run, the one
## the character joined: --map spider_caverns | dng_trial | dng_sealed_wing |
## dng_spider_lair). Short and fail-fast (TOTAL_TIMEOUT); no long walks:
##
##   land    joined and drawn: the map view's build; the player's feet on the
##           drawn floor (|feet - drawn surface under them| <= FEET_TOLERANCE)
##           and on the server's (session.pick)
##   walk    a few metres forward, then the feet again
##   spots   the map's fixed places (SPOTS; a dungeon's at the copy's offset):
##           the drawn floor against the server's under it, the drawn walls
##           against the server's along eight level rays EYE over the floor
##           (the nearest surface each way within WALL_REACH, solids such as
##           stalagmites, pilasters and statues included); a fixed camera view
##           captured to --capture-dir with its frame times (vsync off: fps,
##           frame ms, worst frame, GPU ms, draws, primitives). The last spot
##           is the map's busiest view.
##   memory  the process's working set, Godot's static and video memory, on
##           landing (playing) and at the end (with the probes' copies)
##
## With --placeholder-world the same probes and views run over the pack's
## grey terrain and walls (the comparison the drawn map must match). The
## verdict line says what was seen; it quits 0 only when every step was.

const TOTAL_TIMEOUT := 85.0
const STEP_TIMEOUT := 25.0
const FEET_TOLERANCE := 0.05
const FLOOR_TOLERANCE := 0.05
## A level ray's drawn and server hits may differ this much (a pilaster's
## moulding, a stalagmite's rough flank round its box).
const WALL_TOLERANCE := 0.35
const WALL_REACH := 30.0
## realm_sim's TERRAIN_LINE_STEP: the stride of its line test over a height
## grid.
const TERRAIN_STEP := 1.0
## realm_sim's LINE_RADIUS: the line test sweeps a bead this round, so it
## stops this short of a collider.
const LINE_RADIUS := 0.04
const GRAZE := 0.3
const EYE := 1.4
const WALK_SECONDS := 1.4
const SETTLE := 0.7
const SAMPLE := 1.2
## map -> [[name, probe (x, z) and a height above the floor there, camera
## at, camera looks at]] (a dungeon's local to its copy).
const SPOTS := {
	"spider_caverns": [
		["camp", Vector3(-160.0, 1580.0, -168.0), Vector3(-153.0, 1556.0, -161.0), Vector3(-175.0, 1551.0, -181.0)],
		["camp_gate", Vector3(-172.0, 1580.0, -163.0), Vector3(-171.0, 1551.9, -163.5), Vector3(-174.8, 1552.2, -155.6)],
		["crypt_stair", Vector3(-203.0, 1580.0, -203.0), Vector3(-193.0, 1556.5, -193.0), Vector3(-213.0, 1552.0, -213.0)],
		["webbed_gallery", Vector3(-10.0, 1580.0, -150.0), Vector3(22.0, 1558.0, -128.0), Vector3(-20.0, 1548.0, -162.0)],
		["egg_caverns", Vector3(-50.0, 1560.0, 60.0), Vector3(-18.0, 1535.0, 84.0), Vector3(-56.0, 1526.0, 54.0)],
		["sealed_gate", Vector3(172.0, 1560.0, 197.0), Vector3(158.0, 1530.0, 182.0), Vector3(188.0, 1523.0, 213.0)],
		["venom_pools", Vector3(150.0, 1560.0, 95.0), Vector3(122.0, 1534.0, 70.0), Vector3(155.0, 1524.0, 100.0)],
	],
	"dng_trial": [
		["entry_hall", Vector3(0.0, 1003.0, 2.0), Vector3(0.0, 1005.5, 10.0), Vector3(0.0, 1002.0, -24.0)],
		["corridor", Vector3(0.0, 1003.0, -24.0), Vector3(0.0, 1003.5, -14.0), Vector3(-12.0, 1002.0, -26.0)],
		["arena", Vector3(0.0, 1003.0, -126.0), Vector3(0.0, 1007.0, -103.0), Vector3(0.0, 1001.5, -150.0)],
		["pillared_hall", Vector3(0.0, 1003.0, -58.0), Vector3(0.0, 1006.5, -38.0), Vector3(0.0, 1002.0, -80.0)],
	],
	"dng_sealed_wing": [
		["corridor", Vector3(0.0, 1203.0, -20.0), Vector3(0.0, 1203.4, 8.0), Vector3(0.0, 1201.5, -50.0)],
		["armour_gallery", Vector3(0.0, 1203.0, -78.0), Vector3(0.0, 1204.5, -58.0), Vector3(0.0, 1201.5, -98.0)],
		["vine_cellar", Vector3(0.0, 1203.0, -120.0), Vector3(0.0, 1204.5, -102.0), Vector3(0.0, 1201.0, -138.0)],
		["hounds_hall", Vector3(0.0, 1203.0, -188.0), Vector3(0.0, 1209.0, -163.0), Vector3(0.0, 1202.0, -212.0)],
	],
	"dng_spider_lair": [
		["entry_hall", Vector3(0.0, 1703.0, 2.0), Vector3(0.0, 1705.0, 9.0), Vector3(0.0, 1702.0, -30.0)],
		["egg_chamber", Vector3(0.0, 1703.0, -75.0), Vector3(0.0, 1705.0, -52.0), Vector3(0.0, 1701.5, -98.0)],
		["brood_hall", Vector3(0.0, 1703.0, -120.0), Vector3(0.0, 1704.0, -102.0), Vector3(0.0, 1701.5, -138.0)],
		["mothers_nest", Vector3(0.0, 1703.0, -176.0), Vector3(0.0, 1710.0, -143.0), Vector3(0.0, 1702.0, -205.0)],
	],
}

var game: Node
var _tag := "map"
var _map := ""
var _offset := Vector3.ZERO
var _step := "land"
var _since := 0.0
var _started := 0.0
var _walk := 0.0
var _spot := 0
var _phase := ""
var _camera: Camera3D
var _probe: Array = []   # [[world AABB, Mesh, world transform]]
var _triangles: Dictionary = {}
var _seen := {}
var _problems: Array = []
var _captures: Array = []
var _start_at := Vector3.ZERO
var _frames := 0
var _gpu_ms := 0.0
var _sample_from := 0.0
var _worst_frame := 0.0

func _ready() -> void:
	_tag = "caverns" if OS.get_cmdline_user_args().has("--check-caverns") else "dungeons"
	_started = _now()
	_since = _now()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func walk_intent() -> float:
	return _walk

func _go(step: String) -> void:
	print("realm check %s: step %s at %s" % [_tag, step,
		(game.session.own_position() as Vector3).snapped(Vector3(0.01, 0.01, 0.01))])
	_step = step
	_since = _now()
	_phase = ""

func _see(what: String, detail: Variant) -> void:
	print("realm check %s: %s: %s" % [_tag, what, detail])
	_seen[what] = detail

func _fail(what: String) -> void:
	print("realm check %s: PROBLEM %s" % [_tag, what])
	_problems.append(what)

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null or not game.built or String(game.session.status()) != "joined":
		if _now() - _started > TOTAL_TIMEOUT:
			_verdict("never joined")
		return
	var now := _now()
	if now - _started > TOTAL_TIMEOUT:
		_verdict("timed out in step " + _step)
		return
	if now - _since > STEP_TIMEOUT:
		_verdict("step %s timed out" % _step)
		return
	var me: Vector3 = game.session.own_position()
	match _step:
		"land":
			if now - _since < 1.5:
				return
			_map = String(game.map_name)
			if not SPOTS.has(_map):
				_verdict("no spots for map %s" % _map)
				return
			if (_tag == "caverns") != (_map == "spider_caverns"):
				_verdict("--check-%s on map %s" % [_tag, _map])
				return
			_offset = game.session.copy_offset()
			_see("map", "%s, copy offset %s" % [_map, _offset])
			# what playing the map costs, before the probes build their own
			# triangle copies of it
			_memory("memory_land")
			_index_drawn()
			if _probe.is_empty():
				_verdict("nothing drawn to probe")
				return
			var view: Node = game.map_view
			_see("drawn", "%s, %d probe meshes" % [str(view.get("built_stats")) if view != null else "placeholder",
				_probe.size()])
			_feet("feet_spawn", me)
			_start_at = me
			_go("walk")
		"walk":
			if now - _since < WALK_SECONDS:
				_walk = 1.0
				return
			if now - _since < WALK_SECONDS + 0.6:
				return
			var moved := Vector2(me.x - _start_at.x, me.z - _start_at.z).length()
			_see("walked", "%.2f m" % moved)
			if moved < 2.0:
				_fail("walked only %.2f m" % moved)
			_feet("feet_walked", me)
			_camera = Camera3D.new()
			_camera.far = 600.0
			_camera.fov = 70.0
			game.add_child(_camera)
			_go("spots")
		"spots":
			_spots(now, delta)

## The drawn surfaces the probes test: the map's architecture (a dungeon's
## structure and trim, the caverns' ground, stair, arches and tent; not the
## caverns' crags, which nothing collides with by design),
## or the pack's grey terrain and walls with --placeholder-world. Each
## MultiMesh instance is a probe of its own.
func _index_drawn() -> void:
	_probe.clear()
	var roots: Array = []
	var view: Node = game.map_view
	if view != null and view.get("structure") != null:
		roots.append(view.get("structure"))
		roots.append(view.get("trim"))
		# the solid props the patch boxes stand for (statues, stalagmites)
		for node in (view.get("dressing") as Node).get_children():
			if node is Node3D and String((node as Node3D).scene_file_path).get_file() in ["armour_guard.glb", "cavern_stalag.glb"]:
				roots.append(node)
	elif view != null and view.get("ground") != null:
		roots.append(view.get("ground"))
		for node in view.get_children():
			if String(node.name).begins_with("Step") or String(node.name).begins_with("WebGate_") 					or String(node.name) in ["Camp", "CryptGate"]:
				roots.append(node)
	else:
		for name in ["Terrain", "Walls"]:
			var node: Node = game.get_node_or_null(name)
			if node != null:
				roots.append(node)
	for root: Node in roots:
		var nodes: Array = root.find_children("*", "GeometryInstance3D", true, false)
		if root is GeometryInstance3D:
			nodes.append(root)
		for node in nodes:
			if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
				var mi := node as MeshInstance3D
				var xform := mi.global_transform
				# a skinned statue: its body where its bones pose it, as a box
				var skeleton := mi.get_node_or_null(mi.skeleton) as Skeleton3D if mi.skin != null else null
				if skeleton != null and skeleton.get_bone_count() > 0:
					var box := AABB(skeleton.global_transform * skeleton.get_bone_global_pose(0).origin, Vector3.ZERO)
					for b in skeleton.get_bone_count():
						box = box.expand(skeleton.global_transform * skeleton.get_bone_global_pose(b).origin)
					var body := BoxMesh.new()
					body.size = box.size
					_probe.append([box, body, Transform3D(Basis.IDENTITY, box.get_center())])
					continue
				_probe.append([xform * mi.get_aabb(), mi.mesh, xform])
			elif node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh != null:
				var mmi := node as MultiMeshInstance3D
				var mm := mmi.multimesh
				for i in mm.instance_count:
					var xform := mmi.global_transform * mm.get_instance_transform(i)
					_probe.append([xform * mm.mesh.get_aabb(), mm.mesh, xform])

## The nearest drawn surface on the segment, or null.
func _drawn_hit(from: Vector3, to: Vector3) -> Variant:
	var seg := AABB(from, Vector3.ZERO).expand(to).grow(0.05)
	var best: Variant = null
	var best_d := INF
	for entry: Array in _probe:
		if not (entry[0] as AABB).intersects(seg):
			continue
		var mesh: Mesh = entry[1]
		if not _triangles.has(mesh):
			_triangles[mesh] = mesh.generate_triangle_mesh()
		var tm: TriangleMesh = _triangles[mesh]
		if tm == null:
			continue
		var xform: Transform3D = entry[2]
		var inv := xform.affine_inverse()
		var hit: Dictionary = tm.intersect_segment(inv * from, inv * to)
		if hit.is_empty():
			continue
		var at: Vector3 = xform * (hit["position"] as Vector3)
		var d := from.distance_to(at)
		if d < best_d:
			best_d = d
			best = at
	return best

## The server's nearest static collider along `dir` from `from` (creatures
## and players looked through), or null.
func _server_hit(from: Vector3, dir: Vector3, reach: float) -> Variant:
	var start := from
	var left := reach
	for attempt in 4:
		var hit: Dictionary = game.session.pick(start, dir, left)
		if hit.is_empty():
			return null
		var point: Vector3 = hit["point"]
		if start.distance_to(point) >= left - 0.01:
			return null   # the ray's end: nothing met
		if int(hit["entity"]) == 0:
			return _refine(point, dir, minf(TERRAIN_STEP + 0.05, left - start.distance_to(point)))
		left -= start.distance_to(point) + 0.6
		start = point + dir * 0.6
		if left <= 0.0:
			return null
	return null

## The world's line test walks a height grid in TERRAIN_STEP strides and
## answers the last stride above it (realm_sim World::line_hit); a collider
## it meets exactly. The crossing within the stride past `point`: halve the
## reach until a hit and no hit are a millimetre apart (a short line is one
## stride, its end tested alone).
func _refine(point: Vector3, dir: Vector3, span: float) -> Vector3:
	# a collider: a short line backed off 0.1 m stops at the same point (the
	# bead meets it; the surface is a bead's radius on), where the height
	# grid's one-stride test answers its start
	var back := point - dir * 0.1
	var touch: Dictionary = game.session.pick(back, dir, 0.2)
	if not touch.is_empty() and absf(back.distance_to(touch["point"]) - 0.1) < 0.01:
		return point + dir * LINE_RADIUS
	var lo := 0.0
	var hi := span
	var hit_hi: Dictionary = game.session.pick(point, dir, hi)
	if hit_hi.is_empty() or point.distance_to(hit_hi["point"]) >= hi - 0.0005:
		return point   # nothing past it within the stride: the point is exact
	for i in 14:
		var mid := (lo + hi) * 0.5
		var hit: Dictionary = game.session.pick(point, dir, mid)
		var met := not hit.is_empty() and point.distance_to(hit["point"]) < mid - 0.0005
		if met:
			hi = mid
		else:
			lo = mid
		if hi - lo < 0.001:
			break
	return point + dir * hi

func _feet(what: String, me: Vector3) -> void:
	var drawn: Variant = _drawn_hit(me + Vector3.UP * 1.0, me - Vector3.UP * 3.0)
	var server: Variant = _server_hit(me + Vector3.UP * 1.0, Vector3.DOWN, 4.0)
	if drawn == null:
		_fail("%s: no drawn floor under the feet at %s" % [what, me])
		return
	var gap := me.y - (drawn as Vector3).y
	_see(what, "feet %.3f, drawn floor %.3f (%+.3f), server floor %s" % [me.y, (drawn as Vector3).y, gap,
		"%.3f" % (server as Vector3).y if server != null else "none"])
	if absf(gap) > FEET_TOLERANCE:
		_fail("%s: feet %+.3f m off the drawn floor" % [what, gap])

func _spots(now: float, delta: float) -> void:
	var spots: Array = SPOTS[_map]
	if _spot >= spots.size():
		_memory("memory")
		_verdict("")
		return
	var spot: Array = spots[_spot]
	var name: String = spot[0]
	match _phase:
		"":
			_align(name, (spot[1] as Vector3) + _offset)
			_camera.global_position = (spot[2] as Vector3) + _offset
			_camera.look_at((spot[3] as Vector3) + _offset)
			_camera.make_current()
			_phase = "settle"
			_sample_from = now
		"settle":
			if now - _sample_from >= SETTLE:
				_phase = "sample"
				_sample_from = now
				_frames = 0
				_gpu_ms = 0.0
				_worst_frame = 0.0
		"sample":
			_frames += 1
			_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
			_worst_frame = maxf(_worst_frame, delta * 1000.0)
			if now - _sample_from >= SAMPLE:
				var span := now - _sample_from
				var info := "%.0f fps (%.2f ms a frame, worst %.1f ms), gpu %.2f ms, draws %d, prims %d" % [
					_frames / span, span * 1000.0 / maxf(_frames, 1), _worst_frame, _gpu_ms / maxf(_frames, 1),
					Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
					Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)]
				_see("view_" + name, info)
				_phase = "capture"
		"capture":
			_capture(name)
			_spot += 1
			_phase = ""

## The drawn floor and walls at a spot against the server's: the floor under
## `at` (x, z; y is a height above it to start from), then eight level rays
## EYE over it.
func _align(name: String, at: Vector3) -> void:
	var drawn: Variant = _drawn_hit(at, at - Vector3.UP * 80.0)
	var server: Variant = _server_hit(at, Vector3.DOWN, 80.0)
	if drawn == null or server == null:
		_fail("%s: floor drawn %s, server %s" % [name, drawn, server])
		return
	var floor_gap := (drawn as Vector3).y - (server as Vector3).y
	if absf(floor_gap) > FLOOR_TOLERANCE:
		_fail("%s: drawn floor %+.3f m off the server's" % [name, floor_gap])
	var eye := Vector3(at.x, (server as Vector3).y + EYE, at.z)
	var walls: Array = []
	var worst := 0.0
	for k in 8:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, k * TAU / 8.0)
		var side := dir.cross(Vector3.UP)
		# the ray and two beside it (GRAZE m either side): a ray that grazes a
		# corner meets one side's box and misses the other's rounded shape;
		# the wall is where any of the three agree
		var best: Array = []
		for lateral in [0.0, -GRAZE, GRAZE]:
			var from: Vector3 = eye + side * lateral
			var s_hit: Variant = _server_hit(from, dir, WALL_REACH)
			var d_hit: Variant = _drawn_hit(from, from + dir * (WALL_REACH + 1.0))
			var s_far := from.distance_to(s_hit) if s_hit != null else INF
			var d_far := from.distance_to(d_hit) if d_hit != null else INF
			if is_inf(s_far) and d_far > WALL_REACH:
				d_far = INF
			var off := 0.0 if is_inf(s_far) and is_inf(d_far) \
				else (INF if is_inf(s_far) or is_inf(d_far) else absf(d_far - s_far))
			if best.is_empty() or off < float(best[2]):
				best = [s_far, d_far, off]
		var sd: float = best[0]
		var dd: float = best[1]
		var gap: float = best[2]
		if is_inf(sd) and is_inf(dd):
			walls.append("-")
			continue
		# a closed gate: DungeonGates draws its portcullis from the server's
		# schedule, not this map's art
		if not is_inf(sd) and _on_gate(eye + dir * sd):
			walls.append("gate %.2f" % sd)
			continue
		walls.append("%.2f/%.2f" % [sd, dd])
		if gap > WALL_TOLERANCE:
			_fail("%s: wall %d server %.2f m, drawn %.2f m" % [name, k, sd, dd])
		elif gap > worst:
			worst = gap
	_see("align_" + name, "floor drawn %.3f server %.3f (%+.3f); walls server/drawn m [%s], worst %.2f m" % [
		(drawn as Vector3).y, (server as Vector3).y, floor_gap, ", ".join(walls), worst])

## Whether `point` lies on a closed gate's box (the copy's gates).
func _on_gate(point: Vector3) -> bool:
	for g: Dictionary in game.session.gates():
		if bool(g.get("open", false)):
			continue
		var box := AABB((g["center"] as Vector3) - (g["size"] as Vector3) * 0.5, g["size"]).grow(0.1)
		if box.has_point(point):
			return true
	return false

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", "build/captures/" + _tag))
	if dir.is_relative_path():
		dir = root.path_join(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var prefix := "" if _tag == "caverns" else _map.trim_prefix("dng_") + "_"
	var path := dir.path_join("%s%02d_%s.png" % [prefix, _captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check %s: captured %s" % [_tag, path])

func _memory(what: String) -> void:
	var out: Array = []
	var pid := OS.get_process_id()
	OS.execute("powershell", ["-NoProfile", "-Command", "(Get-Process -Id %d).WorkingSet64" % pid], out)
	var working := float(String(out[0]).strip_edges()) / 1048576.0 if not out.is_empty() and String(out[0]).strip_edges().is_valid_float() else -1.0
	_see(what, "working set %.0f MB, static %.0f MB, video %.0f MB, textures %.0f MB, buffers %.0f MB" % [
		working, Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0])

func _verdict(failure: String) -> void:
	set_process(false)
	var wanted := ["map", "drawn", "memory_land", "feet_spawn", "walked", "feet_walked", "memory"]
	for spot: Array in SPOTS.get(_map, []):
		wanted.append("align_" + String(spot[0]))
		wanted.append("view_" + String(spot[0]))
	var missing := wanted.filter(func(k): return not _seen.has(k))
	var headless := DisplayServer.get_name() == "headless"
	var ok: bool = failure == "" and missing.is_empty() and _problems.is_empty() \
		and (headless or _captures.size() == SPOTS.get(_map, []).size())
	print("realm check %s: %s %s | problems [%s] | missing [%s] | captures %d" % [_tag, _map,
		"ok" if ok else (failure if failure != "" else "incomplete"), "; ".join(_problems),
		", ".join(missing), _captures.size()])
	get_tree().quit(0 if ok else 1)
