extends SceneTree

## Godot side of the world compiler. Boots the old game's headless world
## server (it builds every map collision-only, exactly as the live server
## does), adds one copy of each instanced dungeon, then writes everything a
## body can stand on or bump into, per map, for `realm_worldc`:
##
##   godot --headless --path ../server/world -s <abs>/world_export.gd -- --out <abs dir>
##
## Per map it writes <map>.json (shapes, transforms, terrain grids, water,
## triggers, staircase anchors) and <map>.bin (the large float arrays the
## JSON points into). Only bodies on a layer the player collides with are
## taken (the player's mask). Bodies a rule moves or switches (the castle's
## staircase decks and landing gates) are left out: the staircase rule in
## realm_sim rebuilds them from the anchors. Nothing in the old project
## changes.

const PLAYER_MASK := 39
## Loaded at run time: naming the old project's global classes here would
## compile them before its autoloads exist.
var HPMaps = null
var GroundsLake = null
const SETTLE_FRAMES := 240

var _out := ""
var _frames := 0
var _instances := {}
var _maps := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
	if _out == "":
		var args := OS.get_cmdline_user_args()
		var i := args.find("--out")
		if i >= 0 and i + 1 < args.size():
			_out = args[i + 1]
	if _out == "":
		printerr("world_export: --out <dir> is required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	HPMaps = load("res://addons/hpmmo_sim/maps.gd")
	GroundsLake = load("res://scripts/world/grounds/grounds_lake.gd")
	OS.set_environment("HPMMO_WORLD_PORT", "7799")
	change_scene_to_file("res://server/world_server.tscn")

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 60:
		_add_instances()
	if _frames == SETTLE_FRAMES:
		var started := Time.get_ticks_msec()
		_export()
		print("world_export: done in %d ms" % (Time.get_ticks_msec() - started))
		quit(0)
	return false

## One copy of each instanced map (dungeons), built the way MapHost builds
## them, at instance slot 1; its offset is removed again on export.
func _add_instances() -> void:
	var world := root.get_node_or_null("WorldServer/GameWorld")
	if world == null:
		world = _find_world()
	for map_id in HPMaps.map_ids():
		var info: Dictionary = HPMaps.map_info(String(map_id))
		if not bool(info.get("instanced", false)):
			continue
		var path := String(info.get("scene", ""))
		if path == "" or not ResourceLoader.exists(path):
			printerr("world_export: %s has no scene" % map_id)
			continue
		var node: Node3D = (load(path) as PackedScene).instantiate()
		var slot_id := "%s#1" % map_id
		node.name = "Export_" + String(map_id)
		if node.has_method("setup"):
			node.call("setup", slot_id, true)
		world.add_child(node)
		_instances[String(map_id)] = HPMaps.instance_origin(slot_id)

func _find_world() -> Node:
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_method("_setup_npcs"):
			return node
	return root

## Which map a world-space point belongs to, by the maps' y bands; instanced
## maps are also told apart by their slot's x offset.
func _map_of(point: Vector3) -> String:
	for map_id in HPMaps.map_ids():
		var info: Dictionary = HPMaps.map_info(String(map_id))
		var y_min := float(info.get("y_min", -1e9))
		var y_max := float(info.get("y_max", 1e9))
		if point.y < y_min or point.y > y_max:
			continue
		if _instances.has(String(map_id)):
			var origin: Vector3 = _instances[String(map_id)]
			if absf(point.x - origin.x) > HPMaps.instance_stride(String(map_id)) * 0.5:
				continue
		return String(map_id)
	return ""

func _offset(map_id: String) -> Vector3:
	return _instances.get(map_id, Vector3.ZERO)

func _map_entry(map_id: String) -> Dictionary:
	if not _maps.has(map_id):
		_maps[map_id] = {"colliders": [], "terrain": [], "water": [], "triggers": [], "staircases": [],
			"blob": PackedByteArray(), "skipped": {}, "ruled": {}}
	return _maps[map_id]

func _blob(map_id: String, floats: PackedFloat32Array) -> Dictionary:
	var entry := _map_entry(map_id)
	var bytes := floats.to_byte_array()
	var at: int = entry.blob.size()
	entry.blob.append_array(bytes)
	return {"offset": at, "floats": floats.size()}

func _xform(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z, t.basis.y.x, t.basis.y.y, t.basis.y.z,
		t.basis.z.x, t.basis.z.y, t.basis.z.z, t.origin.x, t.origin.y, t.origin.z]

func _export() -> void:
	var bodies := 0
	for node in root.find_children("*", "CollisionObject3D", true, false):
		var body := node as CollisionObject3D
		if body is CharacterBody3D or body is RigidBody3D:
			continue
		var is_area := body is Area3D
		if not is_area and (body.collision_layer & PLAYER_MASK) == 0:
			continue
		# Bodies a rule moves or switches (staircase decks and the gates that
		# close a landing while its flight is away) are rebuilt by the rule from
		# the staircase anchors below, never baked as scenery.
		if body is AnimatableBody3D or String(body.name).begins_with("TongueGate"):
			_map_entry(_map_of(body.global_position)).ruled[String(body.name).left(10)] = true
			continue
		var kind := "trigger" if is_area else "static"
		for owner_id in body.get_shape_owners():
			if body.is_shape_owner_disabled(owner_id):
				continue
			var owner_xform := body.global_transform * body.shape_owner_get_transform(owner_id)
			for i in body.shape_owner_get_shape_count(owner_id):
				var shape := body.shape_owner_get_shape(owner_id, i)
				_add_shape(body, kind, owner_xform, shape)
				bodies += 1
	_export_terrain()
	_export_water()
	_export_staircases()
	for map_id in _maps:
		_write(String(map_id))
	print("world_export: %d shapes over %d maps -> %s" % [bodies, _maps.size(), _out])

func _add_shape(body: CollisionObject3D, kind: String, xform: Transform3D, shape: Shape3D) -> void:
	var map_id := _map_of(xform.origin)
	if map_id == "":
		_map_entry("_unassigned").skipped[str(body.get_path())] = true
		return
	var local := Transform3D(xform.basis, xform.origin - _offset(map_id))
	var item := {"kind": kind, "path": str(body.get_path()), "layer": body.collision_layer, "xform": _xform(local)}
	if shape is BoxShape3D:
		item.shape = {"type": "box", "size": [shape.size.x, shape.size.y, shape.size.z]}
	elif shape is SphereShape3D:
		item.shape = {"type": "sphere", "radius": shape.radius}
	elif shape is CapsuleShape3D:
		item.shape = {"type": "capsule", "radius": shape.radius, "height": shape.height}
	elif shape is CylinderShape3D:
		item.shape = {"type": "cylinder", "radius": shape.radius, "height": shape.height}
	elif shape is ConvexPolygonShape3D:
		var pts := PackedFloat32Array()
		for p in (shape as ConvexPolygonShape3D).points:
			pts.append_array([p.x, p.y, p.z])
		item.shape = {"type": "convex", "points": _blob(map_id, pts)}
	elif shape is ConcavePolygonShape3D:
		var faces := PackedFloat32Array()
		for p in (shape as ConcavePolygonShape3D).get_faces():
			faces.append_array([p.x, p.y, p.z])
		item.shape = {"type": "trimesh", "faces": _blob(map_id, faces)}
	elif shape is HeightMapShape3D:
		var hm := shape as HeightMapShape3D
		_map_entry(map_id).terrain.append({
			"source": str(body.get_path()), "xform": _xform(local),
			"cols": hm.map_width, "rows": hm.map_depth, "heights": _blob(map_id, hm.map_data)})
		return
	elif shape is WorldBoundaryShape3D:
		var plane := (shape as WorldBoundaryShape3D).plane
		item.shape = {"type": "plane", "normal": [plane.normal.x, plane.normal.y, plane.normal.z], "d": plane.d}
	else:
		_map_entry(map_id).skipped[shape.get_class()] = true
		return
	if kind == "trigger":
		item.name = String(body.name)
		_map_entry(map_id).triggers.append(item)
	else:
		_map_entry(map_id).colliders.append(item)

## Terrain3D stores the grounds as 1 m vertices in regions; it builds its own
## collision, so it is sampled here vertex by vertex (NaN = hole).
func _export_terrain() -> void:
	for node in root.find_children("*", "Terrain3D", true, false):
		var terrain = node
		var data = terrain.data
		if data == null:
			continue
		var spacing: float = terrain.vertex_spacing
		var region_size: int = terrain.region_size
		var locations: Array = data.get_region_locations()
		if locations.is_empty():
			continue
		var min_loc := Vector2i(1 << 30, 1 << 30)
		var max_loc := Vector2i(-(1 << 30), -(1 << 30))
		for loc in locations:
			min_loc = Vector2i(mini(min_loc.x, loc.x), mini(min_loc.y, loc.y))
			max_loc = Vector2i(maxi(max_loc.x, loc.x), maxi(max_loc.y, loc.y))
		var cols := (max_loc.x - min_loc.x + 1) * region_size + 1
		var rows := (max_loc.y - min_loc.y + 1) * region_size + 1
		var x0 := float(min_loc.x * region_size) * spacing
		var z0 := float(min_loc.y * region_size) * spacing
		var heights := PackedFloat32Array()
		heights.resize(rows * cols)
		for r in rows:
			var z := z0 + float(r) * spacing
			for c in cols:
				heights[r * cols + c] = data.get_height(Vector3(x0 + float(c) * spacing, 0.0, z))
		var map_id := "grounds"
		_map_entry(map_id).terrain.append({
			"source": "Terrain3D", "min_x": x0, "min_z": z0, "spacing": spacing,
			"cols": cols, "rows": rows, "heights": _blob(map_id, heights)})
		print("world_export: Terrain3D %dx%d samples from (%.0f, %.0f) at %.2f m" % [cols, rows, x0, z0, spacing])

## Where each moving staircase stands: its catalog entry (`spec_index`) and
## the transform its flight poses are relative to.
func _export_staircases() -> void:
	for node in root.find_children("*", "Node3D", true, false):
		if not node.has_method("platform_transform_at"):
			continue
		var xform: Transform3D = node.global_transform
		var map_id := _map_of(xform.origin)
		var local := Transform3D(xform.basis, xform.origin - _offset(map_id))
		_map_entry(map_id).staircases.append({"spec_index": int(node.get("spec_index")),
			"id": int(node.get("object_id")), "xform": _xform(local)})

## The grounds lake: water wherever the terrain lies deeper than SWIM_DEPTH
## under the water line inside DEPTH_RECT (GroundsLake.is_water_at).
func _export_water() -> void:
	var rect: Rect2 = GroundsLake.DEPTH_RECT
	_map_entry("grounds").water.append({
		"min_x": rect.position.x, "min_z": rect.position.y, "max_x": rect.end.x, "max_z": rect.end.y,
		"surface_y": GroundsLake.WATER_Y, "min_depth": GroundsLake.SWIM_DEPTH})

func _write(map_id: String) -> void:
	var entry: Dictionary = _maps[map_id]
	var doc := {
		"map": map_id, "colliders": entry.colliders, "terrain": entry.terrain, "water": entry.water,
		"triggers": entry.triggers, "staircases": entry.staircases, "skipped": entry.skipped.keys(),
		"ruled": entry.ruled.keys(),
		"source": "old game server world, exported %s" % Time.get_datetime_string_from_system(true),
	}
	var json := FileAccess.open(_out.path_join(map_id + ".json"), FileAccess.WRITE)
	json.store_string(JSON.stringify(doc))
	json.close()
	var bin := FileAccess.open(_out.path_join(map_id + ".bin"), FileAccess.WRITE)
	bin.store_buffer(entry.blob)
	bin.close()
	print("world_export: %s: %d colliders, %d terrain grids, %d triggers, %d staircases, %.1f MB data, skipped %s, ruled %s" % [
		map_id, entry.colliders.size(), entry.terrain.size(), entry.triggers.size(), entry.staircases.size(),
		entry.blob.size() / 1048576.0, entry.skipped.keys().slice(0, 5), entry.ruled.keys()])
