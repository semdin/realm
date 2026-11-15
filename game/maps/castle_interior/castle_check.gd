extends Node

## `--check-castle`: the castle interior drawn where the server's colliders
## are, and what it costs (build/logs/kup_castle.sh; --map castle_interior
## --character 901301). Short and fail-fast (TOTAL_TIMEOUT); no long walks:
##
##   land    joined and drawn: the map view's build (meshes, lights,
##           occluders, feast pieces); the player's feet on the drawn floor
##           (|feet - drawn surface under them| <= FEET_TOLERANCE) and on the
##           server's (session.pick)
##   walk    a few metres forward, then the feet again
##   spots   five fixed places (SPOTS): the drawn floor against the server's
##           floor under it, the drawn walls against the server's along eight
##           level rays EYE over the floor (the nearest surface each
##           way, within WALL_REACH); a fixed camera view of the place,
##           captured to --capture-dir (default build/captures/castle) with
##           its frame times (vsync off: fps, frame ms, worst frame, GPU ms)
##   memory  the process's working set, Godot's static and video memory, on
##           landing (playing) and at the end (with the probes' copies)
##
## With --placeholder-world the same probes and views run over the pack's
## grey terrain and walls (the comparison the drawn castle must match).
## The verdict line says what was seen; it quits 0 only when every step was.

const TOTAL_TIMEOUT := 85.0
const STEP_TIMEOUT := 25.0
const FEET_TOLERANCE := 0.10
const FLOOR_TOLERANCE := 0.10
## A level ray's drawn and server hits may differ this much (dressing such as
## a banner or a moulding stands proud of the wall it hangs on).
const WALL_TOLERANCE := 0.35
const WALL_REACH := 30.0
const GRAZE := 0.3
const EYE := 1.4
const WALK_SECONDS := 1.6
const SETTLE := 0.7
const SAMPLE := 1.2
## [name, probe (x, z) and storey y, camera at, camera looks at]
const SPOTS := [
	["entrance_hall", Vector3(0.0, 200.0, 50.0), Vector3(0.0, 206.5, 63.0), Vector3(0.0, 202.0, 26.0)],
	["feast_hall", Vector3(-60.0, 200.0, 50.0), Vector3(-23.0, 207.0, 56.0), Vector3(-80.0, 203.0, 56.0)],
	["stairwell", Vector3(-18.0, 200.0, -6.0), Vector3(-17.0, 204.0, 12.0), Vector3(4.0, 212.0, -14.0)],
	["sealed_wing_door", Vector3(65.0, 230.0, -8.0), Vector3(59.0, 232.4, -4.6), Vector3(65.1, 232.0, -11.8)],
	["corridor", Vector3(50.0, 200.0, -8.0), Vector3(28.0, 202.6, -8.0), Vector3(86.0, 201.6, -8.0)],
]

var game: Node
var _step := "land"
var _since := 0.0
var _started := 0.0
var _walk := 0.0
var _spot := 0
var _phase := ""
var _camera: Camera3D
var _probe: Array = []   # [[world AABB, MeshInstance3D]]
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
	_started = _now()
	_since = _now()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func walk_intent() -> float:
	return _walk

func _go(step: String) -> void:
	print("realm check castle: step %s at %s" % [step,
		(game.session.own_position() as Vector3).snapped(Vector3(0.01, 0.01, 0.01))])
	_step = step
	_since = _now()
	_phase = ""

func _see(what: String, detail: Variant) -> void:
	print("realm check castle: %s: %s" % [what, detail])
	_seen[what] = detail

func _fail(what: String) -> void:
	print("realm check castle: PROBLEM %s" % what)
	_problems.append(what)

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null or not game.built or String(game.session.status()) != "joined":
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
			game.cam_yaw = 0.0
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

## The drawn surfaces the probes test: the castle's own glb meshes (the
## dressing - candles, props, tableware - is not architecture), or the pack's
## grey terrain and walls with --placeholder-world.
func _index_drawn() -> void:
	_probe.clear()
	var roots: Array = []
	var view: Node = game.map_view
	if view != null and view.get("structure") != null:
		roots.append(view.get("structure"))
	else:
		for name in ["Terrain", "Walls"]:
			var node: Node = game.get_node_or_null(name)
			if node != null:
				roots.append(node)
	# the moving flights as drawn (StairView): the server's decks and gates
	if game.stairs != null:
		roots.append(game.stairs)
	for root: Node in roots:
		var meshes: Array = root.find_children("*", "MeshInstance3D", true, false)
		if root is MeshInstance3D:
			meshes.append(root)
		for mi: MeshInstance3D in meshes:
			if mi.mesh == null or _under_decor(mi, root):
				continue
			_probe.append([mi.global_transform * mi.get_aabb(), mi])

static func _under_decor(node: Node, root: Node) -> bool:
	var at := node.get_parent()
	while at != null and at != root:
		if String(at.name) == "CastleDecor":
			return true
		at = at.get_parent()
	return false

## The nearest drawn surface on the segment, or null.
func _drawn_hit(from: Vector3, to: Vector3) -> Variant:
	var seg := AABB(from, Vector3.ZERO).expand(to).grow(0.05)
	var best: Variant = null
	var best_d := INF
	for entry: Array in _probe:
		if not (entry[0] as AABB).intersects(seg):
			continue
		var mi: MeshInstance3D = entry[1]
		if not _triangles.has(mi):
			_triangles[mi] = mi.mesh.generate_triangle_mesh()
		var tm: TriangleMesh = _triangles[mi]
		if tm == null:
			continue
		var inv := mi.global_transform.affine_inverse()
		var hit: Dictionary = tm.intersect_segment(inv * from, inv * to)
		if hit.is_empty():
			continue
		var at: Vector3 = mi.global_transform * (hit["position"] as Vector3)
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
			return point
		left -= start.distance_to(point) + 0.6
		start = point + dir * 0.6
		if left <= 0.0:
			return null
	return null

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
	if _spot >= SPOTS.size():
		_memory("memory")
		_verdict("")
		return
	var spot: Array = SPOTS[_spot]
	var name: String = spot[0]
	match _phase:
		"":
			# the staircases' wards are made as their gates first shut
			_index_drawn()
			_align(name, spot[1])
			_camera.global_position = spot[2]
			_camera.look_at(spot[3])
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

## The drawn floor and walls at a spot against the server's.
func _align(name: String, at: Vector3) -> void:
	var top := at + Vector3.UP * 3.0
	var drawn: Variant = _drawn_hit(top, at - Vector3.UP * 3.0)
	var server: Variant = _server_hit(top, Vector3.DOWN, 6.0)
	if drawn == null or server == null:
		_fail("%s: floor drawn %s, server %s" % [name, drawn, server])
		return
	var floor_gap := (drawn as Vector3).y - (server as Vector3).y
	if absf(floor_gap) > FLOOR_TOLERANCE:
		_fail("%s: drawn floor %+.3f m off the server's" % [name, floor_gap])
	# 1.4 m: clear of the tops of tables (0.85 m) and plinths (1 m), whose
	# top planes a ray at their very height only grazes
	var eye := Vector3(at.x, (server as Vector3).y + EYE, at.z)
	var walls: Array = []
	var worst := 0.0
	for k in 8:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, k * TAU / 8.0)
		var side := dir.cross(Vector3.UP)
		# the ray and two beside it (GRAZE m either side): a ray that grazes a
		# column's corner meets the server's box there and misses the drawn
		# round shaft; the wall is where any of the three agree
		var best: Array = []
		for lateral in [0.0, -GRAZE, GRAZE]:
			var from: Vector3 = eye + side * lateral
			var s_hit: Variant = _server_hit(from, dir, WALL_REACH)
			# the drawn ray runs a little farther: a wall right at the server
			# ray's reach (its collider 4 cm proud) is still met
			var d_hit: Variant = _drawn_hit(from, from + dir * (WALL_REACH + 1.0))
			var s_far := from.distance_to(s_hit) if s_hit != null else INF
			var d_far := from.distance_to(d_hit) if d_hit != null else INF
			if is_inf(s_far) and d_far > WALL_REACH:
				d_far = INF
			var off := 0.0 if is_inf(s_far) and is_inf(d_far) 				else (INF if is_inf(s_far) or is_inf(d_far) else absf(d_far - s_far))
			if best.is_empty() or off < float(best[2]):
				best = [s_far, d_far, off]
		var sd: float = best[0]
		var dd: float = best[1]
		var gap: float = best[2]
		if is_inf(sd) and is_inf(dd):
			walls.append("-")
			continue
		walls.append("%.2f/%.2f" % [sd, dd])
		if gap > WALL_TOLERANCE:
			_fail("%s: wall %d server %.2f m, drawn %.2f m" % [name, k, sd, dd])
		elif gap > worst:
			worst = gap
	_see("align_" + name, "floor drawn %.3f server %.3f (%+.3f); walls server/drawn m [%s], worst %.2f m" % [
		(drawn as Vector3).y, (server as Vector3).y, floor_gap, ", ".join(walls), worst])

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", "build/captures/castle"))
	if dir.is_relative_path():
		dir = root.path_join(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check castle: captured %s" % path)

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
	var wanted := ["drawn", "memory_land", "feet_spawn", "walked", "feet_walked", "memory"]
	for spot: Array in SPOTS:
		wanted.append("align_" + String(spot[0]))
		wanted.append("view_" + String(spot[0]))
	var missing := wanted.filter(func(k): return not _seen.has(k))
	var headless := DisplayServer.get_name() == "headless"
	var ok := failure == "" and missing.is_empty() and _problems.is_empty() \
		and (headless or _captures.size() == SPOTS.size())
	print("realm check castle: %s | problems [%s] | missing [%s] | captures %d" % [
		"ok" if ok else (failure if failure != "" else "incomplete"), "; ".join(_problems),
		", ".join(missing), _captures.size()])
	get_tree().quit(0 if ok else 1)
