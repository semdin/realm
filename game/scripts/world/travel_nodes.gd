extends Node3D
class_name TravelNodes

## The travel objects of this map in the world (travel.json `nodes`): the
## Hearthway's fireplaces, the Twinned Cabinets and the Stone Raven's passage
## (and its Orvell end, the sweetshop's cellar hatch).
## A hearth is the fireplace model with a small fire in it, and the green
## flames (`burst`) a traveller steps into and out of. The server decides
## every trip; MapTravel asks this node which object the local body stands at.

const FIREPLACE := "res://assets/models/travel/hearth_fireplace.glb"
const MODELS := {
	"hearthway": FIREPLACE,
	"cabinet": "res://assets/models/travel/twinned_cabinet.glb",
}
## Departure/arrival effect per kind: flame tint and sound.
const KIND_FX := {
	"hearthway": [Color(0.35, 1.0, 0.45), "hearth_whoosh"],
	"cabinet": [Color(0.55, 0.25, 0.85), "cabinet_vanish"],
	"passage": [Color(0.75, 0.68, 0.55), "passage_stone"],
	"waylink": [Color(0.5, 0.75, 1.0), "waylink_whoosh"],
}
## The baked model is 2.7 m tall; a walk-in hearth a wizard steps into is ~4.6 m.
const HEARTH_SCALE := 1.7
## The cabinet must read as a walk-in wardrobe beside a 1.8 m wizard.
const CABINET_SCALE := 1.4
## A node set on the ground (_seat): its plinth reaches this far past the
## model's footprint all round and this far under the lowest ground; a
## hearth's hearthstone rises this much over the highest and runs this far
## out in front of the mouth; the ground is sampled on this grid.
const SEAT_MARGIN := 0.25
const PLINTH_SINK := 0.3
const HEARTHSTONE := 0.12
const HEARTH_APRON := 0.45
const SEAT_GRID := 5
const PLINTH_STONE := "res://assets/textures/pbr/castle_wall_varriation/castle_wall_varriation_%s_2k.jpg"

## node id -> Node3D (this map's only).
var roots: Dictionary = {}

## Build this map's nodes; `ground` (x, z) -> Vector3 puts a node authored at
## y 0 on the grounds onto the terrain.
func build(map_id: String, ground: Callable) -> void:
	name = "TravelNodes"
	var all := TravelData.nodes()
	for id: String in all:
		var data: Dictionary = all[id]
		if String(data.get("map", "")) != map_id:
			continue
		var kind := String(data.get("kind", "hearthway"))
		var root := Node3D.new()
		root.name = "Travel_" + id
		root.set_meta("kind", kind)
		add_child(root)
		root.global_position = point(data, ground)
		root.rotation.y = deg_to_rad(float(data.get("yaw", 0.0)))
		var look := String(data.get("model", kind))
		if look == "hatch":
			_trapdoor(root)
		elif MODELS.has(look) and ResourceLoader.exists(String(MODELS[look])):
			var body: Node3D = (load(String(MODELS[look])) as PackedScene).instantiate()
			body.scale = Vector3.ONE * (HEARTH_SCALE if kind == "hearthway" else CABINET_SCALE)
			root.add_child(body)
		elif kind == "passage":
			_passage_mark(root)
		if _on_ground(data) and ground.is_valid():
			_seat(root, ground, kind)
		if kind == "hearthway":
			_hearth_fire(root)
		elif kind == "cabinet":
			_seam_glow(root)
		roots[id] = root

## Where a node stands: its authored point; y 0 on the grounds is the terrain.
static func point(data: Dictionary, ground: Callable) -> Vector3:
	var raw: Array = data.get("pos", [0.0, 0.0, 0.0])
	var at := Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	if is_zero_approx(at.y) and ground.is_valid():
		at = ground.call(at.x, at.z)
	return at

static func _on_ground(data: Dictionary) -> bool:
	var raw: Array = data.get("pos", [0.0, 0.0, 0.0])
	return is_zero_approx(float(raw[1]))

## A node set on the ground (authored at y 0) stands level on the highest
## ground under its footprint (and a hearth on its hearthstone over that),
## and a stone plinth under it reaches PLINTH_SINK below the lowest: on a
## slope no side is buried and none floats, and a hearth on a floor laid over
## the terrain (the Hearth Pavilion's paving) stands on it, not in it. Only a
## model with a footprint is seated (the passage mark is dust).
func _seat(root: Node3D, ground: Callable, kind: String) -> void:
	var box := _local_bounds(root)
	if box.size.x <= 0.0 or box.size.z <= 0.0:
		return
	var lo := Vector2(box.position.x - SEAT_MARGIN, box.position.z - SEAT_MARGIN)
	var hi := Vector2(box.end.x + SEAT_MARGIN, box.end.z + SEAT_MARGIN)
	if kind == "hearthway":
		hi.y += HEARTH_APRON
	var top := -INF
	var low := INF
	for i in SEAT_GRID:
		for j in SEAT_GRID:
			var local := Vector3(lerpf(lo.x, hi.x, i / float(SEAT_GRID - 1)), 0.0, lerpf(lo.y, hi.y, j / float(SEAT_GRID - 1)))
			var at := root.global_transform * local
			var g: Vector3 = ground.call(at.x, at.z)
			top = maxf(top, g.y)
			low = minf(low, g.y)
	var stone := HEARTHSTONE if kind == "hearthway" else 0.0
	root.global_position.y = top + stone
	var plinth := MeshInstance3D.new()
	plinth.name = "Plinth"
	var mesh := BoxMesh.new()
	var depth := root.global_position.y - (low - PLINTH_SINK)
	mesh.size = Vector3(hi.x - lo.x, depth, hi.y - lo.y)
	plinth.mesh = mesh
	plinth.position = Vector3((lo.x + hi.x) * 0.5, -depth * 0.5, (lo.y + hi.y) * 0.5)
	plinth.material_override = _plinth_material()
	root.add_child(plinth)

## The model's bounds in `root`'s own space (its meshes; the effects have
## none yet).
static func _local_bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var inv := root.global_transform.affine_inverse()
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var b := (inv * mi.global_transform) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

static var _stone: Material

## The castle's grey wall stone, world-space (the plinths are all sizes).
static func _plinth_material() -> Material:
	if _stone == null:
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/shaders/triplanar_pbr.gdshader")
		m.set_shader_parameter("albedo_tex", load(PLINTH_STONE % "diff"))
		m.set_shader_parameter("normal_tex", load(PLINTH_STONE % "nor_gl"))
		m.set_shader_parameter("lite", true)
		m.set_shader_parameter("tint", Color(0.78, 0.76, 0.74))
		m.set_shader_parameter("world_scale", 1.0 / 1.6)
		_stone = m
	return _stone

## The travel object (any kind) the body at `pos` stands at, or "".
func node_at(pos: Vector3) -> String:
	for id: String in roots:
		var root: Node3D = roots[id]
		var d := pos - root.global_position
		if Vector2(d.x, d.z).length() <= TravelData.radius(String(root.get_meta("kind"))) and absf(d.y) < 3.5:
			return id
	return ""

## Where a traveller steps in: the hearth's mouth / the cabinet's doors, just
## in front of the object.
func mouth(id: String) -> Vector3:
	var root: Node3D = roots.get(id)
	if root == null:
		return Vector3.ZERO
	var depth := 0.7 if String(root.get_meta("kind")) == "hearthway" else 0.5
	return root.global_position + TravelData.facing(TravelData.node(id)) * depth

## The Orvell end of the Stone Raven's passage: a heavy wooden cellar trapdoor
## with iron straps set in a stone kerb, a dim lantern beside it.
func _trapdoor(root: Node3D) -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.42, 0.4, 0.38)
	stone.roughness = 0.95
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.28, 0.19, 0.11)
	wood.roughness = 0.85
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.1, 0.1, 0.1)
	iron.metallic = 0.7
	iron.roughness = 0.5
	var kerb := MeshInstance3D.new()
	var kb := BoxMesh.new()
	kb.size = Vector3(1.9, 0.22, 1.9)
	kerb.mesh = kb
	kerb.material_override = stone
	kerb.position = Vector3(0, 0.08, 0)
	root.add_child(kerb)
	var door := MeshInstance3D.new()
	var db := BoxMesh.new()
	db.size = Vector3(1.4, 0.08, 1.4)
	door.mesh = db
	door.material_override = wood
	door.position = Vector3(0, 0.22, 0)
	root.add_child(door)
	for z in [-0.4, 0.4]:
		var strap := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(1.42, 0.03, 0.12)
		strap.mesh = sb
		strap.material_override = iron
		strap.position = Vector3(0, 0.27, z)
		root.add_child(strap)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.08
	tm.outer_radius = 0.12
	ring.mesh = tm
	ring.material_override = iron
	ring.position = Vector3(0, 0.29, 0.55)
	root.add_child(ring)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.7, 0.4)
	light.light_energy = 1.0
	light.omni_range = 5.0
	light.position = Vector3(1.3, 1.2, 0)
	root.add_child(light)

## The Stone Raven's end of the passage has no model in this client yet: its
## spot is marked by drifting dust and a few motes rising off the floor.
func _passage_mark(root: Node3D) -> void:
	FlipbookFX.play(root, root.global_position, [
		{"atlas": "smoke_puff_8x8_1k", "size": 1.8, "height": 0.7, "fps": 10.0, "loop": true,
			"tint": Color(0.75, 0.68, 0.55), "opacity": 0.25},
	], {"life": 0.0, "name": "PassageMark"})
	var motes := RisingMotes.make(1.1, 4.0, Color(0.85, 0.75, 0.55), 10, 2.2, Vector2(0.15, 0.5), Vector2(0.008, 0.016))
	RisingMotes.set_rate(motes, 0.5)
	root.add_child(motes)

## The cabinet's door seam breathes a faint violet light.
func _seam_glow(root: Node3D) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(0.6, 0.3, 1.0)
	light.light_energy = 0.9
	light.omni_range = 3.5
	light.position = Vector3(0, 1.3, 0.7)
	root.add_child(light)

## A low fire in the hearth: three looping flame flipbooks staggered in depth
## and a warm light.
func _hearth_fire(root: Node3D) -> void:
	var layers: Array = []
	for k in 3:
		var at := Vector3((float(k) - 1.0) * 0.26, 0.36 + 0.05 * (k % 2), 0.05 - 0.05 * (k % 2)) * HEARTH_SCALE
		var size := Vector2(0.48, 0.72) * HEARTH_SCALE * (1.0 - 0.15 * (k % 2))
		layers.append({"atlas": "flame_loop_8x8_1k", "size": size, "offset": at + Vector3(0, size.y * 0.12, 0),
			"fps": 20.0 + 3.0 * k, "loop": true, "delay": 0.11 * k})
	FlipbookFX.play(root, root.global_position, layers,
		{"life": 0.0, "light": Color(1.0, 0.55, 0.25), "light_energy": 1.6, "light_range": 7.0, "light_height": 0.8,
			"name": "HearthFire"})

## The effect a traveller steps into and out of, by kind (flipbooks): the
## Hearthway's pinch of dust and roaring emerald column, the Twinned Cabinet's
## violet smoke, the passage's dust, the Waylink's whirlwind. `sound` false:
## the flames without their sound (a trip sounds once).
static func burst(parent: Node, at: Vector3, kind: String = "hearthway", sound := true) -> void:
	var fx: Array = KIND_FX.get(kind, KIND_FX["hearthway"])
	if not sound:
		fx = [fx[0], ""]
	var tint: Color = fx[0]
	match kind:
		"hearthway":
			FlipbookFX.play(parent, at, [
				{"atlas": "hearth_dust_8x8_1k", "size": 2.4, "height": 1.0, "fps": 33.0},
				{"atlas": "hearth_column_8x8_2k", "size": Vector2(2.6, 4.8), "height": 2.3, "fps": 24.0, "delay": 0.12},
				{"atlas": "hearth_column_8x8_2k", "size": Vector2(1.9, 3.6), "height": 1.7, "fps": 20.0, "delay": 0.3,
					"opacity": 0.65},
			], {"life": 3.4, "light": tint, "light_energy": 6.0, "light_range": 10.0, "sound": String(fx[1])})
		"cabinet":
			FlipbookFX.play(parent, at, [
				{"atlas": "cabinet_smoke_8x8_1k", "size": 3.4, "height": 1.5, "fps": 22.0},
				{"atlas": "cabinet_smoke_8x8_1k", "size": 2.4, "height": 1.0, "fps": 18.0, "delay": 0.25, "roll": 1.2, "opacity": 0.8},
			], {"life": 3.2, "light": tint, "light_energy": 3.0, "sound": String(fx[1])})
		"waylink":
			FlipbookFX.play(parent, at, [
				{"atlas": "waylink_vortex_8x8_2k", "size": 3.6, "height": 1.6, "fps": 30.0},
			], {"life": 2.4, "light": tint, "light_energy": 4.0, "sound": String(fx[1])})
		_:
			FlipbookFX.play(parent, at, [
				{"atlas": "cabinet_smoke_8x8_1k", "size": 3.0, "height": 1.2, "fps": 20.0,
					"tint": Color(0.9, 0.82, 0.65), "opacity": 0.45},
				{"atlas": "smoke_puff_8x8_1k", "size": 2.6, "height": 0.6, "fps": 20.0, "delay": 0.15,
					"tint": Color(0.75, 0.68, 0.55), "opacity": 0.5},
			], {"life": 3.0, "light": tint, "light_energy": 1.2, "sound": String(fx[1])})
