extends RefCounted

## Orvell's buildings: shops, houses and the inn assembled from the Quaternius
## Medieval Village MegaKit (CC0) by art/village/scripts/build_village_kit.py,
## plus the crooked "storybook" house (build_hand_house.py). The kit's walls,
## timber, stone and roofs wear our own world-space PBR materials (REMAP), so
## they match the castle and the courtyard; each building gets its plaster
## colour and roof from a hash of its position, so repeats differ.
##
## A building is placed in two halves: found() adds its founded plinth to the
## site's ArchKit batch (the walls' and roof's colliders, from
## village_kit.json, are the server's map pack); place() instances the model
## once the batch's root exists. The door side is the model's +z. Both build
## scripts write their building's footprint and colliders to village_kit.json.

const Layout := preload("res://maps/grounds/grounds_layout.gd")
const ArchKit := preload("res://maps/grounds/arch_kit.gd")

const DIR := "res://assets/models/village/"
const MANIFEST := DIR + "village_kit.json"
## kit material -> GroundsSites.materials() key ("plaster"/"roof" pick a variant per building)
const REMAP := {
	"MI_Plaster": "plaster", "MI_Brick": "plaster", "MI_UnevenBrick": "rubble", "MI_RockTrim": "stone",
	"MI_WoodTrim": "timber", "MI_WoodTrim_Wear": "wood", "MI_RoundTiles": "roof", "MI_MetalOrnaments": "metal",
	"MI_WindowGlass": "glass",
}
## _footings: a collider hull whose foot is this low (model metres) stands on
## the floor; its footing reaches this much (negative: past) inside the hull (the prop's own
## faces overhang the hull a little: the footing reaches past it).
const FOOTING_FOOT := 0.3
const FOOTING_INSET := -0.03
const PLASTERS :=["plaster", "plaster_cream", "plaster_ochre", "plaster_rose", "plaster_sage"]
const ROOFS := ["roof", "roof", "roof_warm"]

static var _manifest := {}
static var _loaded := false
static var _scenes := {}


static func manifest() -> Dictionary:
	if not _loaded:
		_loaded = true
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if parsed is Dictionary:
			_manifest = parsed
		else:
			push_error("VillageKit: %s is missing or broken - no village buildings" % MANIFEST)
	return _manifest


## Footprint (width along the door side, depth) in metres.
static func size(id: String) -> Vector2:
	var m: Dictionary = manifest().get(id, {})
	return Vector2(float(m.get("w", 8)), float(m.get("d", 6)))


## Found building `id` at c with its door turned along rot (atan2 of the
## door's direction x, z): a rubble plinth down to the lowest ground under it
## goes into `kit`. Returns the placement for place().
static func found(kit: ArchKit, id: String, c: Vector2, rot: float) -> Array:
	var m: Dictionary = manifest().get(id, {})
	if m.is_empty():
		return []
	var sz := size(id)
	var span := Layout.ground_span(c, sz + Vector2(1.0, 1.0), rot)
	var floor_y := span.y + 0.15
	var base := span.x - 1.0
	var origin := Vector3(c.x, floor_y, c.y)
	kit.box(Vector3(c.x, (base + floor_y) * 0.5, c.y), Vector3(sz.x + 0.6, floor_y - base, sz.y + 0.6), rot, "rubble")
	_footings(kit, m, c, rot, floor_y, sz)
	return [id, origin, rot]


## Whether `at` (x, z) is within `margin` of building `id` founded at c turned
## rot: its plinth, or a prop of it standing out in front (a low collider
## hull: the shops' crates). Garden plants keep clear of it.
static func covers(id: String, c: Vector2, rot: float, at: Vector2, margin: float) -> bool:
	var m: Dictionary = manifest().get(id, {})
	if m.is_empty():
		return false
	var local := Basis(Vector3.UP, rot).inverse() * Vector3(at.x - c.x, 0.0, at.y - c.y)
	var half := size(id) * 0.5 + Vector2(0.3 + margin, 0.3 + margin)
	if absf(local.x) < half.x and absf(local.z) < half.y:
		return true
	for hull: Variant in (m.get("colliders", {}) as Dictionary).get("hulls", []):
		if not (hull is Array) or (hull as Array).is_empty():
			continue
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for p: Array in hull:
			var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
			lo = lo.min(v)
			hi = hi.max(v)
		if lo.y <= FOOTING_FOOT and local.x > lo.x - margin and local.x < hi.x + margin \
				and local.z > lo.z - margin and local.z < hi.z + margin:
			return true
	return false


## A building's props that stand on the ground outside its plinth (the crates
## in front of the shops and the inn: their colliders' hulls whose foot is at
## the floor) get a rubble footing each, from under the prop down to the
## lowest ground beneath it: the floor is the highest ground under the plinth,
## so on a falling street they floated up to 0.9 m over it (2026-11-16,
## placement_check.gd). A footing is exactly the prop's own footprint, which
## its collider already fills from the floor up: no body can stand where the
## footing is, so it needs no collider of its own.
static func _footings(kit: ArchKit, m: Dictionary, c: Vector2, rot: float, floor_y: float, sz: Vector2) -> void:
	var basis := Basis(Vector3.UP, rot)
	var half := sz * 0.5 + Vector2(0.3, 0.3)
	for hull: Variant in (m.get("colliders", {}) as Dictionary).get("hulls", []):
		if not (hull is Array) or (hull as Array).is_empty():
			continue
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for p: Array in hull:
			var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
			lo = lo.min(v)
			hi = hi.max(v)
		if lo.y > FOOTING_FOOT:
			continue
		# wholly on the plinth: it stands on it
		if lo.x >= -half.x and hi.x <= half.x and lo.z >= -half.y and hi.z <= half.y:
			continue
		var mid := basis * Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.z + hi.z) * 0.5)
		var size := Vector2(hi.x - lo.x, hi.z - lo.z) - Vector2(FOOTING_INSET, FOOTING_INSET) * 2.0
		var span := Layout.ground_span(Vector2(c.x + mid.x, c.y + mid.z), size, rot)
		# the props are drawn on the floor (their hulls reach a little under it)
		var top := floor_y + maxf(lo.y, 0.0)
		var bottom := span.x - 0.3
		if top - bottom <= 0.31:
			continue
		kit.box(Vector3(c.x + mid.x, (top + bottom) * 0.5, c.y + mid.z), Vector3(size.x, top - bottom, size.y), rot, "rubble")


## Instance the founded buildings under root, wearing `mats` (GroundsSites.materials()).
static func place(root: Node3D, placements: Array, mats: Dictionary) -> void:
	for entry in placements:
		if entry.is_empty():
			continue
		var id: String = entry[0]
		if not _scenes.has(id):
			_scenes[id] = load(DIR + id + ".glb")
		var scene: PackedScene = _scenes[id]
		if scene == null:
			continue
		var pick := absi(int(entry[1].x * 7.0) * 31 + int(entry[1].z * 7.0) * 17)
		var plaster: String = PLASTERS[pick % PLASTERS.size()]
		var roof: String = ROOFS[(pick / 7) % ROOFS.size()]
		# One model at every distance. Its meshes import with Godot's own LOD
		# (generate_lods): the engine draws a coarser index set only while the
		# difference stays under a pixel on screen. The hand-made far model
		# (a 12 % collapse decimation, swapped in at 60 m) lost the eaves and
		# roof overhangs, so a house visibly grew as you walked up to it
		# (2026-11-09). Measured on the village without it: GPU time the same
		# (8.1 vs 8.2 ms at 200 m and 450 m, Intel iGPU).
		var house: Node3D = scene.instantiate()
		house.name = id.to_pascal_case()
		root.add_child(house)
		house.position = entry[1]
		house.rotation.y = entry[2]
		for mi in house.find_children("*", "MeshInstance3D", true, false):
			_dress(mi as MeshInstance3D, mats, plaster, roof)


## A garden fence piece at `at` (x, z) turned `yaw`, standing on the ground:
## its transform for place_fences().
static func found_fence(at: Vector2, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), Layout.ground(at.x, at.y))


## Draw the fence pieces (one MultiMesh of the kit's fence, in our timber).
static func place_fences(root: Node3D, xforms: Array, mats: Dictionary) -> void:
	if xforms.is_empty() or not ResourceLoader.exists(DIR + "fence.glb"):
		return
	var scene: Node = (load(DIR + "fence.glb") as PackedScene).instantiate()
	var found := scene.find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = (found[0] as MeshInstance3D).mesh.duplicate() if not found.is_empty() else null
	scene.free()
	if mesh == null:
		return
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		var key: String = REMAP.get(mat.resource_name if mat != null else "", "")
		if mats.has(key):
			mesh.surface_set_material(s, mats[key])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GardenFences"
	mmi.multimesh = mm
	root.add_child(mmi)


static func _dress(m: MeshInstance3D, mats: Dictionary, plaster: String, roof: String) -> void:
	for s in m.mesh.get_surface_count():
		var mat := m.mesh.surface_get_material(s)
		var name := mat.resource_name if mat != null else ""
		# the storybook house names its materials after our keys directly
		var key: String = REMAP.get(name, name)
		if key == "plaster":
			key = plaster
		elif key == "roof":
			key = roof
		if mats.has(key):
			m.set_surface_override_material(s, mats[key])
