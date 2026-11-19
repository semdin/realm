extends SceneTree

## Placement check: one drawn map laid against its server pack, offline (no
## server, no session), short and fail-fast. Run with a window (the grounds
## build only with one):
##
##   build/w1_target/release/realm_worldc dump world/maps grounds build/w1/grounds.colliders.json
##   godot --path game -s res://maps/dng_common/placement_check.gd -- --map grounds \
##       --dump ../build/w1/grounds.colliders.json --quality=low [--out ../build/w1] \
##       [--shot name,x,y,z,look_x,look_y,look_z ...]
##
## The map view is built as the game builds it (the grounds on the quality
## preset given), with the map's travel objects (TravelNodes) on the ground
## the game puts them on. Then:
##
##   terrain    the pack's terrain grid against the drawn ground (Terrain3D)
##              at every TERRAIN_STRIDE-th sample: the feet stand on the pack,
##              the eye sees the drawn one
##   invisible  every pack collider's top surface (sampled on a grid) against
##              the drawn surfaces under the same point: a solid the server
##              has where nothing is drawn (a body stands on air). The
##              grounds' tree and rock obstacles are the Terrain3D instancer's
##              instances: each obstacle's instance (its note) must be planted
##              on this preset
##   seats      every drawn model (an instanced scene: the fireplaces, the
##              greenhouses, a dungeon's props; every MultiMesh instance) on
##              what is drawn under its foot: a foot more than FLOAT_TOL over
##              the ground floats, one more than SINK_TOL under it is sunk (a
##              flat base on a slope is both: tilted into it)
##   npcs       the NPCs (npcs.json) stand on the pack's first surface from
##              the sky; that must be the drawn surface there
##
## Every finding is written to <out>/placement_<map>.json; the verdict line
## quits 0 only when nothing was found. `--shot` captures a camera view
## (PNG in <out>/<name>.png) after the checks; `--show 12,40` draws those
## pack colliders see-through red in it; `--explain 12,40` prints their
## invisible samples one by one.

const Layout := preload("res://maps/grounds/grounds_layout.gd")
const Scatter := preload("res://maps/grounds/grounds_scatter.gd")
const TIMEOUT := 85.0
const PACK_LAYER := 1 << 20
const DRAWN_LAYER := 1 << 21
## MultiMesh instances (flowers, bones, fungi): drawn, but not the ground a
## model's foot is measured against.
const SCATTER_LAYER := 1 << 22
## Pack terrain against the drawn ground (m).
const TERRAIN_TOL := 0.05
const TERRAIN_STRIDE := 4
## A collider's top this far over the drawn surface is not drawn.
const INVISIBLE_TOL := 0.3
## A collider is reported when this share of its top samples (and at least
## INVISIBLE_MIN of them) is not drawn.
const INVISIBLE_SHARE := 0.4
const INVISIBLE_MIN := 3
const MAX_SAMPLES := 64
## A sample also looks this far round it for a thin drawn solid (m).
const NEAR := 0.15
## A collider longer than this (m) is a map boundary wall.
const BOUNDARY := 1000.0
## A model's foot over / under what is drawn beneath it (m).
const FLOAT_TOL := 0.08
const SINK_TOL := 0.2
## The share of a model's feet that must be off for it to count, and the
## tolerance for scattered MultiMesh instances (flowers, leaves and pumpkins
## are tipped on purpose).
const FEET_SHARE := 0.2
const SCATTER_TOL := 0.3
## Vertices this close to a model's lowest point are its foot.
const FOOT_BAND := 0.03
## A foot this close to the edge of a surface stands on it (m).
const EDGE := 0.06
const MAX_FOOT := 48
## Only models whose foot is this close to the ground under their centre are
## seated (a lamp on a wall bracket is not).
const SEAT_REACH := 1.5
const NPC_TOL := 0.1

## Findings looked at and meant (map, part, field, substring, why[, kind]):
## listed under counts.allowed, not failed. With a kind, only findings of
## that kind (a seat's "sunk", "floats", "tilted") are allowed.
const ALLOW := [
	# spider_caverns.gd _crags: the stalagmite clumps are planted into the
	# floor on purpose (a spire 0.5 m, a small clump 0.2 m, each tipped up to
	# 0.08 / 0.15 rad): a flat-footed rock clump on the uneven cave floor
	["spider_caverns", "seats", "unit", "Crags_", "stalagmite clumps planted into the floor (_crags)", "sunk"],
	# dng_sealed_wing.gd _dress_hall: the hound's trapdoor (0.69 m of frame
	# and door at 1.35x) is set 0.3 m into the hall's floor, a lip showing
	["dng_sealed_wing", "seats", "unit", "(fc_trapdoor.glb)", "the trapdoor is set into the floor", "sunk"],
	# castle_interior.gd _dress_portals: the Sealed Wing's door stands in the
	# third-floor corridor's wall, the back of its frame over the wall's
	# 0.55 m skirting, which runs on behind it
	["castle_interior", "seats", "unit", "(fc_door.glb)", "the Sealed Wing's door set into the corridor wall, over its skirting", "sunk"],
	["grounds", "seats", "unit", "(boar.glb)",
		"the gate boars' pedestals stand against the balustrade's piers (the pier's top is over the pedestal's corner)"],
	# the crooked storybook house's chimney: its collider (village_kit.json,
	# build_hand_house.py) is the convex hull of a leaning stack with two
	# pots, wider than the stack at the top; it is drawn there, on a roof
	["grounds", "invisible", "drawn_near", "(storybook.glb)", "the hull of the drawn leaning chimney, 12 m up on a roof"],
]

var map_id := ""
var out_dir := ""
var view: Node3D
var _started := 0
var _dump: Dictionary = {}
## pack terrain grids: [{min_x, min_z, sx, sz, rows, cols, h: PackedFloat32Array}]
var _grids: Array = []
## collider index -> its pack record
var _colliders: Dictionary = {}
## unit id -> {name, rids: Array[RID], verts: PackedVector3Array, model: bool}
var _units: Dictionary = {}
var _space: PhysicsDirectSpaceState3D
var _findings: Dictionary = {}
var _counts: Dictionary = {}
var _probe_root: Node3D
## Pack collider indices whose invisible samples are printed one by one
## (`--explain 12,40`).
var _explain: Dictionary = {}


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if (Time.get_ticks_msec() - _started) / 1000.0 > TIMEOUT:
		printerr("placement check verdict: FAIL - timed out after %.0f s" % TIMEOUT)
		quit(1)
		return true
	return false


func _arg(name: String, fallback: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _path(p: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join(p).simplify_path() if p.is_relative_path() else p


func _fail(why: String) -> void:
	printerr("placement check verdict: FAIL - " + why)
	quit(1)


func _run() -> void:
	map_id = _arg("--map", "grounds")
	for k in _arg("--explain").split(",", false):
		_explain[int(k)] = true
	out_dir = _path(_arg("--out", "../build/w1"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var content := _path("../content/data")
	if not ClassDB.class_call_static("RealmContent", "load", content):
		return _fail("content/data could not be read")
	if not _load_dump(_path(_arg("--dump", "../build/w1/%s.colliders.json" % map_id))):
		return
	var t := Time.get_ticks_msec()
	_build_view()
	# a plain noon light for the captures (DayNight is the game's)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(35.0), 0.0)
	sun.light_energy = 1.2
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.68, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.78, 0.82)
	env.environment.ambient_light_energy = 0.6
	root.add_child(env)
	# a camera for the views that stream round one (the grounds' vegetation)
	var cam := Camera3D.new()
	cam.name = "CheckCamera"
	cam.far = 4000.0
	root.add_child(cam)
	cam.current = true
	for i in 3:
		await process_frame
	print("[placement] %s built in %d ms" % [map_id, Time.get_ticks_msec() - t])
	t = Time.get_ticks_msec()
	_probe_root = Node3D.new()
	_probe_root.name = "PlacementProbes"
	root.add_child(_probe_root)
	_pack_bodies()
	_drawn_bodies()
	for i in 2:
		await physics_frame
	_space = root.world_3d.direct_space_state
	print("[placement] probe bodies in %d ms: %d pack colliders, %d drawn units" % [
		Time.get_ticks_msec() - t, _colliders.size(), _units.size()])
	for part: String in ["terrain", "invisible", "seats", "npcs"]:
		t = Time.get_ticks_msec()
		call("_check_" + part)
		print("[placement] %s: %d found (%d ms)" % [part, (_findings.get(part, []) as Array).size(), Time.get_ticks_msec() - t])
	await _shots(cam)
	_report()


# ----------------------------------------------------------------- inputs

func _load_dump(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_fail("no collider dump at %s (realm_worldc dump)" % path)
		return false
	_dump = parsed
	var bin := FileAccess.get_file_as_bytes(path + ".terrain.bin")
	for g: Dictionary in _dump.get("terrain", []):
		var n := int(g["rows"]) * int(g["cols"])
		var off := int(g["offset"])
		_grids.append({"min_x": float(g["min_x"]), "min_z": float(g["min_z"]), "sx": float(g["spacing_x"]),
			"sz": float(g["spacing_z"]), "rows": int(g["rows"]), "cols": int(g["cols"]),
			"h": bin.slice(off, off + n * 4).to_float32_array()})
	for c: Dictionary in _dump.get("colliders", []):
		_colliders[int(c["index"])] = c
	return true


## The pack's terrain height at (x, z) (NAN: none), as realm_sim samples it:
## each cell split into two triangles along its x = z diagonal.
func pack_terrain(x: float, z: float) -> float:
	for g: Dictionary in _grids:
		var fx := (x - float(g["min_x"])) / float(g["sx"])
		var fz := (z - float(g["min_z"])) / float(g["sz"])
		var cols: int = g["cols"]
		var rows: int = g["rows"]
		if fx < 0.0 or fz < 0.0 or fx > cols - 1 or fz > rows - 1:
			continue
		var c := mini(int(fx), cols - 2)
		var r := mini(int(fz), rows - 2)
		var u := fx - c
		var v := fz - r
		var h: PackedFloat32Array = g["h"]
		var h00 := h[r * cols + c]
		var h10 := h[r * cols + c + 1]
		var h01 := h[(r + 1) * cols + c]
		var h11 := h[(r + 1) * cols + c + 1]
		if is_nan(h00) or is_nan(h10) or is_nan(h01) or is_nan(h11):
			return NAN
		if u >= v:
			return h00 + (h10 - h00) * u + (h11 - h10) * v
		return h00 + (h11 - h01) * u + (h01 - h00) * v
	return NAN


## The drawn ground (Terrain3D) at (x, z), NAN where none.
func drawn_terrain(x: float, z: float) -> float:
	return Layout.height_at(x, z) if map_id == "grounds" else NAN


# ------------------------------------------------------------------ build

func _build_view() -> void:
	var scene := "res://maps/%s/%s.tscn" % [map_id, map_id]
	view = (load(scene) as PackedScene).instantiate()
	root.add_child(view)
	if map_id == "grounds":
		var stub := Node3D.new()
		stub.name = "CheckMain"
		root.add_child(stub)
		view.call("setup", null, stub)
	elif view.has_method("build"):
		view.call("build")
	# the map's travel objects, on the ground the game puts them on
	var nodes: Node3D = (load("res://scripts/world/travel_nodes.gd") as GDScript).new()
	view.add_child(nodes)
	# (loaded here: a -s script cannot name a script that names an autoload)
	var travel: GDScript = load("res://scripts/world/map_travel.gd")
	nodes.build(map_id, Callable(travel, "floor_on").bind(view, null))


func _faces_shape(faces: PackedVector3Array) -> ConcavePolygonShape3D:
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape


func _body(shape: Shape3D, xform: Transform3D, layer: int, meta: Variant) -> RID:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.set_meta("id", meta)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	_probe_root.add_child(body)
	body.global_transform = xform
	return body.get_rid()


## Every pack collider as its own body (its index in the body's meta). The
## grounds' tree and rock obstacles are checked against the instancer.
func _pack_bodies() -> void:
	for index: int in _colliders:
		var c: Dictionary = _colliders[index]
		if map_id == "grounds" and String(c["source"]) == "obstacle":
			continue
		var v: Array = c["vertices"]
		var faces := PackedVector3Array()
		for k: int in c["indices"]:
			faces.append(Vector3(v[k * 3], v[k * 3 + 1], v[k * 3 + 2]))
		_body(_faces_shape(faces), Transform3D.IDENTITY, PACK_LAYER, index)


## The unit a drawn mesh belongs to: the outermost instanced scene under the
## view that is a prop (no wider than MODEL_SPAN: a fireplace, a greenhouse),
## else the mesh itself (a kit building, a piece of the castle's structure).
const MODEL_SPAN := 16.0
var _spans := {}

func _unit_of(node: Node) -> Node:
	var unit: Node = null
	var n := node.get_parent()
	while n != null and n != view:
		if n.scene_file_path != "" and n is Node3D and _span(n as Node3D) <= MODEL_SPAN:
			unit = n
		n = n.get_parent()
	return unit if unit != null else node


func _span(n: Node3D) -> float:
	if not _spans.has(n):
		var box := AABB()
		var first := true
		for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null:
				continue
			var b := mi.global_transform * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
		_spans[n] = maxf(box.size.x, box.size.z) if not first else INF
	return _spans[n]


func _drawn_bodies() -> void:
	var shapes := {}
	# the grounds' Terrain3D draws the ground (drawn_terrain) and, through its
	# instancer and the impostor tiles, the trees and rocks (checked against
	# their instances, not as meshes)
	var terrain: Variant = view.get("terrain") if map_id == "grounds" else null
	for gi: GeometryInstance3D in view.find_children("*", "GeometryInstance3D", true, false):
		if not gi.is_visible_in_tree():
			continue
		if terrain is Node and (terrain == gi or (terrain as Node).is_ancestor_of(gi)):
			continue
		if gi is MeshInstance3D:
			var mi := gi as MeshInstance3D
			if mi.mesh == null:
				continue
			# a skinned body (a suit of armour standing in its pose) is where
			# its bones put it: its rest vertices can be another size entirely
			# (armour_guard.glb: a 1 cm figure under a 100x armature)
			var drawn_mesh: Mesh = mi.mesh
			if mi.skin != null and mi.get_node_or_null(mi.skeleton) is Skeleton3D:
				var posed := mi.bake_mesh_from_current_skeleton_pose()
				if posed != null:
					drawn_mesh = posed
			var faces := drawn_mesh.get_faces()
			if faces.is_empty():
				continue
			var unit := _unit_of(mi)
			var id := unit.get_instance_id()
			if not _units.has(id):
				_units[id] = {"name": _describe(unit), "rids": [], "verts": PackedVector3Array(),
					"model": unit != mi or mi.scene_file_path != "", "origin": (unit as Node3D).global_position.y}
			var rid := _body(_faces_shape(faces), mi.global_transform, DRAWN_LAYER, id)
			(_units[id]["rids"] as Array).append(rid)
			_units[id]["verts"] = (_units[id]["verts"] as PackedVector3Array) + _world_verts(drawn_mesh, mi.global_transform)
		elif gi is MultiMeshInstance3D:
			var mmi := gi as MultiMeshInstance3D
			var mm := mmi.multimesh
			if mm == null or mm.mesh == null:
				continue
			if not shapes.has(mm.mesh):
				shapes[mm.mesh] = _faces_shape(mm.mesh.get_faces())
			var local := _world_verts(mm.mesh, Transform3D.IDENTITY)
			# a flat card (a candle's flame, a web) has no foot to seat
			var extent := mm.mesh.get_aabb().size
			var card := minf(extent.x, minf(extent.y, extent.z)) < 0.001
			var count := mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
			for i in count:
				var xform := mmi.global_transform * mm.get_instance_transform(i)
				var id := "%d#%d" % [mmi.get_instance_id(), i]
				var rid := _body(shapes[mm.mesh], xform, SCATTER_LAYER, id)
				_units[id] = {"name": "%s[%d]" % [_describe(mmi), i], "rids": [rid], "verts": xform * local, "model": not card,
					"scatter": true, "origin": xform.origin.y}


func _world_verts(mesh: Mesh, xform: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		out.append_array(xform * v)
	return out


func _describe(node: Node) -> String:
	var path := String(view.get_path_to(node))
	if node.scene_file_path != "":
		path += " (" + node.scene_file_path.get_file() + ")"
	return path


# ----------------------------------------------------------------- probes

## The highest surface of `layer` hit by a ray from `from` straight down
## `reach` metres: [y, the body's id] or [] when none.
func _down(from: Vector3, reach: float, layer: int, exclude: Array = []) -> Array:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * reach, layer, exclude)
	q.hit_back_faces = true
	q.hit_from_inside = false
	var hit := _space.intersect_ray(q)
	if hit.is_empty():
		return []
	return [(hit["position"] as Vector3).y, (hit["collider"] as Object).get_meta("id")]


## What is drawn under `from` within `reach`: the drawn meshes (and the
## scattered MultiMesh instances with `scatter`) and the drawn terrain (NAN:
## nothing).
func _drawn_under(from: Vector3, reach: float, exclude: Array = [], scatter := true) -> float:
	var best := -INF
	var hit := _down(from, reach, DRAWN_LAYER | (SCATTER_LAYER if scatter else 0), exclude)
	if not hit.is_empty():
		best = hit[0]
	var t := drawn_terrain(from.x, from.z)
	if not is_nan(t) and t <= from.y and t >= from.y - reach:
		best = maxf(best, t)
	return best if best > -INF else NAN


func _add(part: String, entry: Dictionary) -> void:
	for a: Array in ALLOW:
		if String(a[0]) == map_id and String(a[1]) == part and String(entry.get(a[2], "")).contains(String(a[3])) \
				and (a.size() < 6 or String(entry.get("kind", "")) == String(a[5])):
			entry["allowed"] = a[4]
			if not _counts.has("allowed"):
				_counts["allowed"] = []
			(_counts["allowed"] as Array).append(entry)
			return
	if not _findings.has(part):
		_findings[part] = []
	(_findings[part] as Array).append(entry)


## The HUD's coordinates of a point (MapPlaces.coords_text: maps.json
## `coord_origin` off).
func _hud(p: Vector3) -> String:
	var maps: Variant = RealmContent.table("maps")
	var o: Array = (maps as Dictionary).get("maps", {}).get(map_id, {}).get("coord_origin", [0.0, 0.0]) if maps is Dictionary else [0.0, 0.0]
	return "%d, %d" % [roundi(p.x - float(o[0])), roundi(p.z - float(o[1]))]


# ---------------------------------------------------------------- terrain

func _check_terrain() -> void:
	if map_id != "grounds" or _grids.is_empty():
		return
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var off := 0
	var tested := 0
	for g: Dictionary in _grids:
		var h: PackedFloat32Array = g["h"]
		var cols: int = g["cols"]
		for r in range(0, int(g["rows"]), TERRAIN_STRIDE):
			for c in range(0, cols, TERRAIN_STRIDE):
				var p := h[r * cols + c]
				if is_nan(p):
					continue
				var x := float(g["min_x"]) + c * float(g["sx"])
				var z := float(g["min_z"]) + r * float(g["sz"])
				var d := drawn_terrain(x, z)
				if is_nan(d):
					continue
				tested += 1
				var e := absf(d - p)
				if e > TERRAIN_TOL:
					off += 1
					if off <= 40:
						_add("terrain", {"at": [x, p, z], "hud": _hud(Vector3(x, 0, z)), "pack": p, "drawn": d})
				if e > worst:
					worst = e
					worst_at = Vector3(x, p, z)
	_counts["terrain"] = {"tested": tested, "off": off, "worst": snappedf(worst, 0.001), "worst_at": _hud(worst_at)}


# -------------------------------------------------------------- invisible

func _check_invisible() -> void:
	var reported := 0
	var tested := 0
	for index: int in _colliders:
		var c: Dictionary = _colliders[index]
		if map_id == "grounds" and String(c["source"]) == "obstacle":
			continue
		var mn: Array = c["min"]
		var mx: Array = c["max"]
		# the map's edge walls (the old world's 2 km boundary boxes): meant
		# unseen
		if float(mx[0]) - float(mn[0]) > BOUNDARY or float(mx[2]) - float(mn[2]) > BOUNDARY:
			continue
		tested += 1
		var size := Vector2(float(mx[0]) - float(mn[0]), float(mx[2]) - float(mn[2]))
		var step := maxf(0.3, maxf(size.x, size.y) / 7.0)
		while (floorf(size.x / step) + 1.0) * (floorf(size.y / step) + 1.0) > MAX_SAMPLES:
			step *= 1.25
		var samples := 0
		var bare := 0
		var worst := 0.0
		var worst_at := Vector3.ZERO
		var nx := int(floorf(size.x / step)) + 1
		var nz := int(floorf(size.y / step)) + 1
		for i in nx:
			for j in nz:
				var x := float(mn[0]) + (size.x * (i + 0.5) / nx)
				var z := float(mn[2]) + (size.y * (j + 0.5) / nz)
				var hit := _down(Vector3(x, float(mx[1]) + 0.05, z), float(mx[1]) - float(mn[1]) + 0.1, PACK_LAYER)
				if hit.is_empty() or int(hit[1]) != index:
					continue
				var top: float = hit[0]
				var under := pack_terrain(x, z)
				# a top inside the pack's own terrain is not one anyone stands on
				if not is_nan(under) and under >= top - 0.05:
					continue
				samples += 1
				var drawn := _drawn_under(Vector3(x, top + 0.5, z), 3.5)
				# a thin solid (a fence rail, a post) drawn a hand's width off
				# the sample: the nearest drawn top round it
				for o: Vector3 in [Vector3(NEAR, 0, 0), Vector3(-NEAR, 0, 0), Vector3(0, 0, NEAR), Vector3(0, 0, -NEAR)]:
					if not is_nan(drawn) and top - drawn <= INVISIBLE_TOL:
						break
					var d2 := _drawn_under(Vector3(x, top + 0.5, z) + o, 3.5)
					if not is_nan(d2) and (is_nan(drawn) or d2 > drawn):
						drawn = d2
				var gap := top - drawn if not is_nan(drawn) else 3.0
				var enclosed := gap > INVISIBLE_TOL and _enclosed(Vector3(x, top + 0.05, z))
				if enclosed:
					gap = 0.0
				if _explain.has(index):
					var up := _ray(Vector3(x, top + 0.05, z), Vector3(x, top + 5.05, z))
					var down := _ray(Vector3(x, top + 5.05, z), Vector3(x, top + 0.05, z))
					print("[placement] explain #%d sample %.2f, %.2f top %.3f drawn %.3f enclosed %s up %s down %s" % [
						index, x, z, top, drawn, enclosed, [up.get("position"), up.get("normal")] if not up.is_empty() else "-",
						[down.get("position"), down.get("normal")] if not down.is_empty() else "-"])
				if gap > INVISIBLE_TOL:
					bare += 1
					if gap > worst:
						worst = gap
						worst_at = Vector3(x, top, z)
		if bare >= INVISIBLE_MIN and float(bare) / maxf(1.0, samples) >= INVISIBLE_SHARE:
			reported += 1
			# what is drawn in the collider's column (for the reader, and ALLOW)
			var cx := (float(mn[0]) + float(mx[0])) * 0.5
			var cz := (float(mn[2]) + float(mx[2])) * 0.5
			var near := _down(Vector3(cx, float(mx[1]) + 5.0, cz), float(mx[1]) - float(mn[1]) + 5.0, DRAWN_LAYER)
			var drawn_near := String(_units.get(near[1], {}).get("name", "")) if not near.is_empty() else ""
			_add("invisible", {"index": index, "drawn_near": drawn_near, "source": c["source"], "note": c["note"], "shape": c["shape"],
				"min": mn, "max": mx, "hud": _hud(worst_at), "at": [worst_at.x, worst_at.y, worst_at.z],
				"bare": bare, "samples": samples, "worst_gap": snappedf(worst, 0.01)})
	_counts["invisible"] = {"colliders": tested, "reported": reported}
	if map_id == "grounds":
		_check_planted_obstacles()


## Whether `at` is inside something drawn (a collider's top hidden in a
## drawn roof or wall): drawn surfaces over it and on three sides of four.
## Each way is a small fan of rays, any of which may meet it: a model built
## of loose shards (the caverns' stalagmite clumps) lets a single ray
## through the gaps between them.
func _enclosed(at: Vector3) -> bool:
	if not _fan_hits(at, Vector3.UP, 5.0):
		return false
	var sides := 0
	for d: Vector3 in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		if _fan_hits(at, d, 8.0):
			sides += 1
	return sides >= 3


## Whether any ray of a fan round `dir` meets something drawn: the straight
## one within `reach`, four FAN_TILT off it within FAN_REACH (a hand's width
## aside at most: the shards round the point, not a wall beside it).
const FAN_TILT := 0.15
const FAN_REACH := 2.0

func _fan_hits(at: Vector3, dir: Vector3, reach: float) -> bool:
	if not _ray(at, at + dir * reach).is_empty():
		return true
	var a := dir.cross(Vector3.FORWARD if absf(dir.z) < 0.9 else Vector3.RIGHT).normalized()
	var b := dir.cross(a).normalized()
	for off: Vector3 in [a, -a, b, -b]:
		if not _ray(at, at + (dir + off * FAN_TILT).normalized() * minf(reach, FAN_REACH)).is_empty():
			return true
	return false


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, DRAWN_LAYER | SCATTER_LAYER)
	q.hit_back_faces = true
	return _space.intersect_ray(q)


## The grounds' obstacles are the instancer's trees and rocks: every one
## (its patch note "<variant> tree|rock <k>") must be planted on this preset.
func _check_planted_obstacles() -> void:
	var terrain: Node = view.get("terrain")
	var cells: Dictionary = terrain.get("_cells")
	var assets: Resource = terrain.get("assets")
	var planted := {}   # variant -> {"x,z" (dm): true}
	for mesh_id: int in cells:
		var variant := String(assets.call("get_mesh_asset", mesh_id).get("name"))
		var keys := {}
		for global: Vector2i in cells[mesh_id]:
			var cell: Array = cells[mesh_id][global]
			var offset: Vector3 = cell[4]
			for xf: Transform3D in cell[2]:
				var o := xf.origin + offset
				keys["%d,%d" % [roundi(o.x * 10.0), roundi(o.z * 10.0)]] = true
		planted[variant] = keys
	var raw := {}
	var missing := 0
	var tested := 0
	var by_variant := {}
	for index: int in _colliders:
		var c: Dictionary = _colliders[index]
		if String(c["source"]) != "obstacle":
			continue
		var parts := String(c["note"]).split(" ")
		if parts.size() < 3 or not parts[2].is_valid_int():
			continue
		var variant := parts[0]
		var k := int(parts[2])
		if not raw.has(variant):
			raw[variant] = Scatter.instances(variant)
		var data: PackedFloat32Array = raw[variant]
		if k * 5 + 4 >= data.size():
			continue
		tested += 1
		var key := "%d,%d" % [roundi(data[k * 5] * 10.0), roundi(data[k * 5 + 2] * 10.0)]
		if (planted.get(variant, {}) as Dictionary).has(key):
			continue
		missing += 1
		by_variant[variant] = int(by_variant.get(variant, 0)) + 1
		var at := Vector3(data[k * 5], data[k * 5 + 1], data[k * 5 + 2])
		if missing <= 60:
			_add("invisible", {"index": index, "source": "obstacle", "note": c["note"], "hud": _hud(at),
				"at": [at.x, at.y, at.z], "why": "instance not planted on this preset", "max": c["max"]})
	_counts["obstacle_instances"] = {"tested": tested, "not_planted": missing, "by_variant": by_variant}


# ------------------------------------------------------------------ seats

func _check_seats() -> void:
	var tested := 0
	for id: Variant in _units:
		var u: Dictionary = _units[id]
		if not bool(u["model"]):
			continue
		var verts: PackedVector3Array = u["verts"]
		if verts.is_empty():
			continue
		var low := INF
		var centre := Vector3.ZERO
		for v in verts:
			low = minf(low, v.y)
			centre += v
		centre /= verts.size()
		if u.has("origin"):
			u["below_origin"] = float(u["origin"]) - low
		var feet := PackedVector3Array()
		for v in verts:
			if v.y < low + FOOT_BAND:
				feet.append(v)
		if feet.size() > MAX_FOOT:
			var thin := PackedVector3Array()
			for i in MAX_FOOT:
				thin.append(feet[i * feet.size() / MAX_FOOT])
			feet = thin
		var rids: Array = u["rids"]
		var ground_c := _drawn_under(Vector3(centre.x, low + SEAT_REACH, centre.z), SEAT_REACH * 2.0, rids, false)
		if is_nan(ground_c) or absf(ground_c - low) > SEAT_REACH:
			continue
		tested += 1
		var most_float := -INF
		var most_sunk := -INF
		var float_at := Vector3.ZERO
		var sunk_at := Vector3.ZERO
		var n_float := 0
		var n_sunk := 0
		var sunk_by := ""
		var scatter := u.has("scatter")
		var float_tol := SCATTER_TOL if scatter else FLOAT_TOL
		var sink_tol := SCATTER_TOL if scatter else SINK_TOL
		for f in feet:
			var g := _drawn_under(f + Vector3.UP * 0.75, 2.75, rids, false)
			# a foot on the very edge of what it stands on (a wall's foot flush
			# with its plinth's side) stands on it
			for o: Vector3 in [Vector3(EDGE, 0, 0), Vector3(-EDGE, 0, 0), Vector3(0, 0, EDGE), Vector3(0, 0, -EDGE)]:
				var g2 := _drawn_under(f + o + Vector3.UP * 0.75, 2.75, rids, false)
				if not is_nan(g2) and (is_nan(g) or (g2 > g and g2 <= f.y + FLOAT_TOL)):
					g = g2
			var burial := (g - f.y) if not is_nan(g) else -2.0
			# nothing under a foot buried deeper than the probe's start (a
			# base set into a slope): the surface over it says how deep
			if is_nan(g):
				var q := PhysicsRayQueryParameters3D.create(f, f + Vector3.UP * 3.0, DRAWN_LAYER, rids)
				q.hit_back_faces = true
				var over := _space.intersect_ray(q)
				if not over.is_empty():
					burial = (over["position"] as Vector3).y - f.y
			n_float += 1 if -burial > float_tol else 0
			n_sunk += 1 if burial > sink_tol else 0
			if -burial > most_float:
				most_float = -burial
				float_at = f
			if burial > most_sunk:
				most_sunk = burial
				sunk_at = f
				var by := _down(f + Vector3.UP * 0.75, 2.75, DRAWN_LAYER, rids)
				sunk_by = String(_units.get(by[1], {}).get("name", "")) if not by.is_empty() else "terrain"
		# a few feet off is a foot on a neighbour's edge; a model built to
		# stand in the ground (its foot under its origin: a cellar, a sunk
		# base) is not sunk
		var need := maxi(2, ceili(feet.size() * FEET_SHARE))
		var floats := n_float >= need
		var sunk := n_sunk >= need and float(u.get("below_origin", 0.0)) < SINK_TOL
		if floats or sunk:
			_add("seats", {"unit": u["name"], "hud": _hud(centre), "at": [centre.x, low, centre.z],
				"floats": snappedf(maxf(most_float, 0.0), 0.01), "float_at": [float_at.x, float_at.y, float_at.z],
				"sunk": snappedf(maxf(most_sunk, 0.0), 0.01), "sunk_at": [sunk_at.x, sunk_at.y, sunk_at.z], "sunk_by": sunk_by,
				"kind": "tilted" if floats and sunk else ("floats" if floats else "sunk")})
	_counts["seats"] = {"models": tested}


# ------------------------------------------------------------------- npcs

func _check_npcs() -> void:
	var table: Variant = RealmContent.table("npcs")
	if not (table is Dictionary):
		return
	var tested := 0
	for id: String in (table as Dictionary).get("npcs", {}):
		var data: Dictionary = table["npcs"][id]
		if String(data.get("map", "")) != map_id:
			continue
		var p: Array = data.get("pos", [0.0, 0.0])
		var x := float(p[0])
		var z := float(p[1])
		var hit := _down(Vector3(x, 1500.0, z), 3000.0, PACK_LAYER)
		var pack := float(hit[0]) if not hit.is_empty() else -INF
		var t := pack_terrain(x, z)
		if not is_nan(t):
			pack = maxf(pack, t)
		if pack == -INF:
			_add("npcs", {"npc": id, "why": "no pack surface"})
			continue
		tested += 1
		var drawn := _drawn_under(Vector3(x, pack + 0.6, z), 3.0)
		if is_nan(drawn) or absf(drawn - pack) > NPC_TOL:
			_add("npcs", {"npc": id, "hud": _hud(Vector3(x, 0, z)), "pack": pack, "drawn": drawn})
	_counts["npcs"] = {"tested": tested}


# ------------------------------------------------------------------ shots

func _shots(cam: Camera3D) -> void:
	var args := OS.get_cmdline_user_args()
	# `--show 12,40`: those pack colliders drawn see-through red in the shots
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.1, 0.1, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for k in _arg("--show").split(",", false):
		var c: Dictionary = _colliders.get(int(k), {})
		if c.is_empty():
			continue
		var v: Array = c["vertices"]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for idx: int in c["indices"]:
			st.add_vertex(Vector3(v[idx * 3], v[idx * 3 + 1], v[idx * 3 + 2]))
		var shown := MeshInstance3D.new()
		shown.mesh = st.commit()
		shown.material_override = mat
		root.add_child(shown)
	for i in args.size() - 1:
		if args[i] != "--shot":
			continue
		var s := args[i + 1].split(",")
		if s.size() < 7:
			continue
		cam.global_position = Vector3(float(s[1]), float(s[2]), float(s[3]))
		cam.look_at(Vector3(float(s[4]), float(s[5]), float(s[6])))
		for f in 12:
			await process_frame
		var image := root.get_texture().get_image()
		var path := out_dir.path_join(s[0] + ".png")
		if image != null and image.save_png(path) == OK:
			print("[placement] shot %s -> %s" % [s[0], path])


func _report() -> void:
	var quality: String = (load("res://scripts/world/quality_preset.gd") as GDScript).call("current")
	var doc := {"map": map_id, "quality": quality, "counts": _counts, "findings": _findings}
	var path := out_dir.path_join("placement_%s.json" % map_id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "  ") + "\n")
		f.close()
	var total := 0
	for part: String in _findings:
		total += (_findings[part] as Array).size()
	print("[placement] counts %s" % JSON.stringify(_counts))
	print("placement check verdict: %s - %s on %s, %d finding(s) -> %s" % [
		"PASS" if total == 0 else "FAIL", map_id, quality, total, path])
	quit(0 if total == 0 else 1)
