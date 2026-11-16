extends "res://maps/dng_common/dungeon_view.gd"

## The Sealed Wing drawn (maps.json "dng_sealed_wing"), entered through the
## locked door on the castle's third-floor east corridor: the old game's
## code-built dungeon with its generated dressing (carpet, tapestries, bones,
## the harp and the trapdoor; res://assets/dungeons/sealed_wing).
##
## Rooms, north (entry, local z +12) to south:
##   corridor         z  12 ..  -56   pixies + two armours             gate_a
##   armour gallery   z -56 .. -100   the Cursed Armour Commander      gate_b
##   vine cellar      z -100 .. -140  the Strangling Vine
##   stair            z -140 .. -160  pixie swarm                      gate_c
##   the hound's hall z -160 .. -216  Threehead, the harp, the trapdoor gate_d
##   reward room      z -216 .. -232  the chest, the way out
## Positions are local to the copy (the scene stands at the copy's offset).

const HARP := Vector3(18, 0, -172)
const ARMOUR := "res://assets/models/monsters/armour_guard.glb"
const VINE := "res://assets/models/monsters/strangling_vine.glb"
const ART := "res://assets/dungeons/sealed_wing/"

var _carpet: StandardMaterial3D
var _moss: Material
var _wood: StandardMaterial3D

func _build() -> void:
	map_id = "dng_sealed_wing"
	floor_y = 1200.0
	_carpet = _mat(Color(0.85, 0.8, 0.78), 0.92)
	if ResourceLoader.exists(ART + "carpet.jpg"):
		_carpet.albedo_texture = load(ART + "carpet.jpg")
	_moss = _pbr("mossy_stone_wall", Color(0.62, 0.72, 0.58), 3.0)
	_wood = _mat(Color(0.30, 0.19, 0.10), 0.85)
	var f := floor_y
	_room(Vector2(0, -22), Vector2(10, 68), [-56.0], 8.0, INF, [Vector2(-1, -30)])
	# Side slots: optional packs off the way.
	_room(Vector2(-15, -30), Vector2(18, 16), [], 8.0, INF, [], 1)
	_room(Vector2(0, -78), Vector2(30, 44), [-56.0, -100.0])
	_room(Vector2(0, -120), Vector2(30, 40), [-100.0, -140.0])
	_room(Vector2(0, -150), Vector2(10, 20), [-140.0, -160.0], 8.0, INF, [Vector2(1, -150)])
	_room(Vector2(15, -150), Vector2(18, 16), [], 8.0, INF, [], -1)
	wall_h = 14.0
	_room(Vector2(0, -188), Vector2(48, 56), [-160.0, -216.0])
	wall_h = 8.0
	_room(Vector2(0, -224), Vector2(16, 16), [-216.0])
	# The hall is taller than the rooms either side: wall over their doorways.
	_box(Vector3(0, f + 11.0, -160), Vector3(8.2, 6.0, 1))
	_box(Vector3(0, f + 11.0, -216), Vector3(8.2, 6.0, 1))
	# (The harp stands on its own round foot: _dress_hall.)
	_dress_corridor(f)
	_dress_gallery(f)
	_dress_cellar(f)
	_dress_hall(f)

## A carpet runner on the floor: the texture repeats every 4.5 m of length.
func _runner(center: Vector3, width: float, length: float) -> void:
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, length)
	var m: StandardMaterial3D = _carpet.duplicate()
	m.uv1_scale = Vector3(1.0, length / 4.5, 1.0)
	plane.material = m
	mesh.mesh = plane
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = center
	dressing.add_child(mesh)

## A woven tapestry hung flat on a wall; `facing` is the yaw it looks along.
func _tapestry(file: String, at: Vector3, facing: float, size: Vector2 = Vector2(3.2, 4.8)) -> void:
	if not ResourceLoader.exists(ART + file):
		return
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(ART + file)
	m.roughness = 0.95
	quad.material = m
	mesh.mesh = quad
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = at
	mesh.rotation.y = deg_to_rad(facing)
	dressing.add_child(mesh)
	var along_x := absf(facing) < 1.0 or absf(facing - 180.0) < 1.0
	_deco(at + Vector3(0, size.y * 0.5 + 0.08, 0), Vector3(size.x + 0.4, 0.1, 0.1) if along_x else Vector3(0.1, 0.1, size.x + 0.4), _wood)

func _dress_corridor(f: float) -> void:
	_runner(Vector3(0, f + 0.02, -21), 3.0, 64)
	for z in [4.0, -12.0, -22.0, -44.0]:
		_torch(Vector3(-4.3, f + 3.2, z))
	for z in [-4.0, -20.0, -36.0, -52.0]:
		_torch(Vector3(4.3, f + 3.2, z))
	for z in [-6.0, -20.0, -38.0]:
		_solid_prop(ARMOUR, Vector3(-4.0, f, z), 90.0, 1.0, "suit of armour on the corridor's west wall, z %.0f" % z)
		_solid_prop(ARMOUR, Vector3(4.0, f, z - 7.0), -90.0, 1.0, "suit of armour on the corridor's east wall, z %.0f" % (z - 7.0))
	# The armour niche and the pantry off the stair.
	for at in [Vector3(-23.3, f + 3.2, -26.0), Vector3(-23.3, f + 3.2, -34.0), Vector3(23.3, f + 3.2, -150.0)]:
		_torch(at, Color(1.0, 0.68, 0.35), 1.3)

func _dress_gallery(f: float) -> void:
	_runner(Vector3(0, f + 0.02, -78), 4.0, 42)
	for z in [-72.0, -84.0]:
		_tapestry("tapestry_knight.jpg", Vector3(-14.9, f + 4.2, z), 90.0)
		_tapestry("tapestry_knight.jpg", Vector3(14.9, f + 4.2, z), -90.0)
	for z in [-66.0, -78.0, -90.0]:
		_solid_prop(ARMOUR, Vector3(-14.0, f, z), 90.0, 1.0, "suit of armour in the gallery's west row, z %.0f" % z)
		_solid_prop(ARMOUR, Vector3(14.0, f, z), -90.0, 1.0, "suit of armour in the gallery's east row, z %.0f" % z)
		_torch(Vector3(-14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)
		_torch(Vector3(14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)

func _dress_cellar(f: float) -> void:
	_deco(Vector3(0, f + 0.01, -120), Vector3(28, 0.02, 38), _moss)
	# Vine growth climbing every wall: the creature's own vines, posed still.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1999
	for i in range(10):
		var x := -13.2 if i % 2 == 0 else 13.2
		var z := -104.0 - (i / 2) * 7.5 - (3.5 if i % 2 else 0.0)
		_prop(VINE, Vector3(x, f, z), rng.randf_range(0, 360), rng.randf_range(0.55, 0.8))
	for z in [-108.0, -124.0, -136.0]:
		_torch(Vector3(-14.2, f + 3.0, z), Color(0.75, 1.0, 0.6), 1.3, 14.0)
		_torch(Vector3(14.2, f + 3.0, z), Color(0.75, 1.0, 0.6), 1.3, 14.0)

func _dress_hall(f: float) -> void:
	# The trapdoor the hound guards, gnawed bones, the tapestry of the hound.
	_prop(ART + "fc_trapdoor.glb", Vector3(0, f - 0.3, -205), 0.0, 1.35)
	_light(Vector3(0, f + 4.5, -205), Color(1.0, 0.75, 0.45), 1.6, 9.0)
	for b in [[Vector3(-7, 0, -181), 20.0], [Vector3(8, 0, -198), 140.0], [Vector3(-10, 0, -207), 250.0], [Vector3(5, 0, -186), 300.0]]:
		_prop(ART + "fc_bones.glb", Vector3(b[0].x, f, b[0].z), b[1], 1.4)
	_tapestry("tapestry_threehead.jpg", Vector3(-23.9, f + 6.0, -190), 90.0, Vector2(4.4, 6.6))
	_tapestry("tapestry_threehead.jpg", Vector3(23.9, f + 6.0, -190), -90.0, Vector2(4.4, 6.6))
	for z in [-168.0, -184.0, -200.0, -212.0]:
		_torch(Vector3(-23.3, f + 5.0, z), Color(1.0, 0.62, 0.3), 2.2, 16.0)
		_torch(Vector3(23.3, f + 5.0, z), Color(1.0, 0.62, 0.3), 2.2, 16.0)
	# A great hanging brazier light over the arena so the hound reads at range.
	_light(Vector3(0, f + 12.0, -190), Color(1.0, 0.7, 0.42), 2.4, 34.0)
	# The harp on its round foot (fc_harp.glb: a 0.38 m drum 1.1 m across,
	# the strung frame over it in its x-y plane, turned to run along z). The
	# old game's 1 m pedestal box (1.6 m square) is not drawn: it goes, and
	# the drum and the frame get boxes inside them.
	removed.append({"note": "the old harp pedestal (1 m box, 1.6 m square): the harp's drum is drawn",
		"min": [HARP.x - 0.9, f - 0.1, HARP.z - 0.9], "max": [HARP.x + 0.9, f + 1.1, HARP.z + 0.9]})
	solids.append({"note": "the harp's drum: drawn, inside its round foot",
		"center": [HARP.x, f + 0.185, HARP.z], "half": [0.38, 0.185, 0.38], "yaw_deg": 0})
	solids.append({"note": "the harp's strung frame: drawn",
		"center": [HARP.x, f + 0.9, HARP.z], "half": [0.05, 0.9, 0.6], "yaw_deg": 0})
	var harp := Node3D.new()
	harp.name = "Harp"
	harp.position = Vector3(HARP.x, f + 1.0, HARP.z)
	dressing.add_child(harp)
	if ResourceLoader.exists(ART + "fc_harp.glb"):
		var model: Node3D = (load(ART + "fc_harp.glb") as PackedScene).instantiate()
		model.position = Vector3(0, -1.0, 0)
		model.rotation.y = deg_to_rad(-90.0)
		harp.add_child(model)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.5)
	glow.light_energy = 1.2
	glow.omni_range = 6.0
	glow.position = Vector3(0, 1.5, 0)
	harp.add_child(glow)
	_lights += 1
