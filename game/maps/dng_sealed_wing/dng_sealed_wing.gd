extends "res://maps/dng_common/dungeon_view.gd"

## The Brine Vaults drawn (maps.json "dng_sealed_wing"), entered through the
## flood door in the castle's east corridor: vaults under the east wing, shut
## for a long time - the castle's warm sandstone gone grey with dust and damp,
## worn runners and faded plum cloths, rubble where the vaults have shed their
## stone, cobwebs in the corners - and below them a cellar the damp has taken
## (moss, wet cobbles) and the great engine hall
## (the creature's own art: res://assets/dungeons/sealed_wing).
##
## Rooms, north (entry, local z +12) to south:
##   corridor         z  12 ..  -56   galelings + two sentries         gate_a
##   armour gallery   z -56 .. -100   the Brinebriar                   gate_b
##   deep cellar      z -100 .. -140  the Hollow Castellan
##   stair            z -140 .. -160  galeling swarm                   gate_c
##   the engine hall  z -160 .. -216  Wheelwarden, the sluice wheel    gate_d
##   reward room      z -216 .. -232  the chest, the way out
## Positions are local to the copy (the scene stands at the copy's offset).

const WHEEL := Vector3(18, 0, -172)
const ARMOUR := "res://assets/models/monsters/armour_guard.glb"
const VINE := "res://assets/models/monsters/strangling_vine.glb"
const ART := "res://assets/dungeons/sealed_wing/"
## The wing's cloths: a faded plum banded in undyed linen (house-neutral).
const PLUM := Color(0.52, 0.4, 0.47)
const LINEN := Color(0.82, 0.78, 0.7)

var _wood: Material
var _cellar_wall: Material
var _cellar_floor: Material
var _hall_wall: Material
var _hall_floor: Material

func _materials() -> void:
	# the castle's sandstone, dulled by dust and damp
	_stone = surf("large_sandstone_blocks_01", Color(0.74, 0.7, 0.64), 3.5,
		{"second": "stone_wall", "tint2": Color(0.6, 0.57, 0.52), "metres2": 2.8, "cover": 0.22, "streaks": 0.45, "grime": 0.6})
	_floor_mat = surf("floor_flagstone_01", Color(0.5, 0.48, 0.46), 3.0,
		{"second": "dirt_ground_01", "tint2": Color(0.7, 0.64, 0.58), "metres2": 2.5, "cover": 0.3, "macro": 0.22})
	_vault = surf("plaster_grey_04", Color(0.74, 0.7, 0.64), 3.0, {"grime": 0.0, "streaks": 0.5})
	_vault_uv = surf("plaster_grey_04", Color(0.7, 0.66, 0.6), 3.5,
		{"mapping": 1, "grime": 0.0, "streaks": 0.0, "macro": 0.22, "second": "large_sandstone_blocks_01",
			"tint2": Color(0.62, 0.58, 0.52), "metres2": 3.5, "cover": 0.2})
	_trim = surf("sandstone_blocks_08", Color(0.72, 0.68, 0.62), 2.0, {"wear": 1.0, "grime": 0.5})
	_trim_uv = surf("sandstone_blocks_08", Color(0.68, 0.64, 0.58), 2.0, {"mapping": 1, "grime": 0.0})
	_base = surf("stone_wall", Color(0.55, 0.52, 0.48), 2.2, {"grime": 0.75, "grime_height": 1.4, "streaks": 0.0})
	_rubble_mat = surf("large_sandstone_blocks_01", Color(0.62, 0.58, 0.53), 1.2, {"grime": 0.2, "streaks": 0.0})
	_boards = surf("wooden_planks", Color(0.78, 0.66, 0.56), 2.0, {"grime": 0.0, "streaks": 0.0, "macro": 0.35})
	_beam = surf("medieval_wood", Color(0.7, 0.58, 0.48), 1.2, {"grime": 0.0, "streaks": 0.0, "wear": 0.6})
	_wood = _beam
	var moss := {"moss": 0.85, "moss_color": Color(0.2, 0.25, 0.12), "moss_height": 2.4, "streaks": 0.55, "grime": 0.7}
	_cellar_wall = surf("mossy_stone_wall", Color(0.62, 0.66, 0.58), 3.0, moss)
	_cellar_floor = surf("cobblestone_floor_04", Color(0.74, 0.74, 0.68), 2.6,
		{"second": "mossy_stone_wall", "tint2": Color(0.62, 0.66, 0.56), "metres2": 3.0, "cover": 0.3, "moss": 0.35,
			"moss_color": Color(0.24, 0.28, 0.14), "macro": 0.3})
	_hall_wall = surf("castle_wall_varriation", Color(0.66, 0.64, 0.62), 3.2,
		{"second": "large_sandstone_blocks_01", "tint2": Color(0.62, 0.58, 0.52), "metres2": 3.5, "cover": 0.3, "streaks": 0.4})
	_hall_floor = surf("cobblestone_large_01", Color(0.56, 0.54, 0.5), 3.5,
		{"second": "floor_flagstone_01", "tint2": Color(0.45, 0.44, 0.42), "metres2": 3.0, "cover": 0.45})

func _build() -> void:
	map_id = "dng_sealed_wing"
	floor_y = 1200.0
	ambient_scale = 2.2
	var f := floor_y
	var stone := _stone
	var floor_mat := _floor_mat
	_room(Vector2(0, -22), Vector2(10, 68), [-56.0], 8.0, INF, [Vector2(-1, -30)])
	# Side slots: optional packs off the way.
	_room(Vector2(-15, -30), Vector2(18, 16), [], 8.0, INF, [], 1)
	ceiling = "timber"
	_room(Vector2(0, -78), Vector2(30, 44), [-56.0, -100.0])
	ceiling = "barrel"
	_stone = _cellar_wall
	_floor_mat = _cellar_floor
	_room(Vector2(0, -120), Vector2(30, 40), [-100.0, -140.0])
	_stone = stone
	_floor_mat = floor_mat
	_room(Vector2(0, -150), Vector2(10, 20), [-140.0, -160.0], 8.0, INF, [Vector2(1, -150)])
	_room(Vector2(15, -150), Vector2(18, 16), [], 8.0, INF, [], -1)
	wall_h = 14.0
	_stone = _hall_wall
	_floor_mat = _hall_floor
	_room(Vector2(0, -188), Vector2(48, 56), [-160.0, -216.0])
	_stone = stone
	_floor_mat = floor_mat
	wall_h = 8.0
	_room(Vector2(0, -224), Vector2(16, 16), [-216.0])
	# The hall is taller than the rooms either side: wall over their doorways.
	_box(Vector3(0, f + 11.0, -160), Vector3(8.2, 6.0, 1), _hall_wall)
	_box(Vector3(0, f + 11.0, -216), Vector3(8.2, 6.0, 1), _hall_wall)
	# (The sluice wheel stands on its own round foot: _dress_hall.)
	_dress_corridor(f)
	_dress_gallery(f)
	_dress_cellar(f)
	_dress_hall(f)
	_dress_reward(f)

## A worn cloth runner on the floor (the cloth shader laid flat: moth holes,
## frayed ends, paler where feet went).
func _runner(center: Vector3, width: float, length: float) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Runner"
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, length)
	var m := ShaderMaterial.new()
	m.shader = BANNER
	m.set_shader_parameter("weave_tex", load(HESSIAN % "diff"))
	m.set_shader_parameter("weave_normal", load(HESSIAN % "nor_gl"))
	m.set_shader_parameter("noise_tex", load(NOISE))
	m.set_shader_parameter("dye", PLUM * 0.82)
	m.set_shader_parameter("band", PLUM * 0.82)
	m.set_shader_parameter("band_at", Vector2.ZERO)
	m.set_shader_parameter("size", Vector2(width, length))
	m.set_shader_parameter("seed", fposmod(center.z * 0.13, 1.0))
	m.set_shader_parameter("sway", 0.0)
	m.set_shader_parameter("hang", 0.0)
	plane.material = m
	mesh.mesh = plane
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = center
	dressing.add_child(mesh)

## Dust-grey cobwebs strung across the upper corners of a room's inner
## rect (`center`, `size`) under the springing.
func _corner_webs(center: Vector2, size: Vector2, y: float, s: float = 2.6) -> Array:
	var out: Array = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var at := Vector3(center.x + sx * (size.x * 0.5 - s * 0.32), y, center.y + sz * (size.y * 0.5 - s * 0.32))
			out.append([at, Vector3(-sx, -0.6, -sz), s])
	return out

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
	for at in [Vector3(4.8, f + 7.0, 1.0), Vector3(-4.8, f + 7.0, -15.0), Vector3(4.8, f + 7.0, -29.0), Vector3(-4.8, f + 7.0, -48.0)]:
		_banner(at, Vector2(1.5, 3.6), PLUM, LINEN)
	_rubble(Vector3(-4.0, f, 9.5), 0.8, 6)
	_rubble(Vector3(3.9, f, -46.5), 1.0, 8)
	_rubble(Vector3(-20.5, f, -36.0), 1.1, 9)
	var webs := _corner_webs(Vector2(0, -22), Vector2(10, 68), f + 6.4)
	webs.append_array(_corner_webs(Vector2(-15, -30), Vector2(18, 16), f + 6.6))
	_webs(webs, Color(0.6, 0.6, 0.58), 0.4)

func _dress_gallery(f: float) -> void:
	_runner(Vector3(0, f + 0.02, -78), 4.0, 42)
	for z in [-72.0, -84.0]:
		_banner(Vector3(-14.8, f + 7.2, z), Vector2(2.4, 4.6), PLUM, LINEN)
		_banner(Vector3(14.8, f + 7.2, z), Vector2(2.4, 4.6), PLUM, LINEN)
	for z in [-66.0, -78.0, -90.0]:
		_solid_prop(ARMOUR, Vector3(-14.0, f, z), 90.0, 1.0, "suit of armour in the gallery's west row, z %.0f" % z)
		_solid_prop(ARMOUR, Vector3(14.0, f, z), -90.0, 1.0, "suit of armour in the gallery's east row, z %.0f" % z)
		_torch(Vector3(-14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)
		_torch(Vector3(14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)
	# The Brinebriar's growth up the gallery walls: its own stems, posed still.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1999
	for i in range(8):
		var x := -11.2 if i % 2 == 0 else 11.2
		var z := -62.0 - (i / 2) * 9.5 - (4.5 if i % 2 else 0.0)
		_prop(VINE, Vector3(x, f, z), rng.randf_range(0, 360), rng.randf_range(0.55, 0.8))
	# a beam end fallen from the ceiling and the plaster it brought down
	_rubble(Vector3(12.6, f, -97.6), 1.4, 12)
	_rubble(Vector3(-12.8, f, -58.6), 1.0, 8)
	_webs(_corner_webs(Vector2(0, -78), Vector2(30, 44), f + 7.6, 3.2), Color(0.6, 0.6, 0.58), 0.4)

func _dress_cellar(f: float) -> void:
	for z in [-108.0, -124.0, -136.0]:
		_torch(Vector3(-14.2, f + 3.0, z), Color(0.75, 1.0, 0.6), 1.3, 14.0)
		_torch(Vector3(14.2, f + 3.0, z), Color(0.75, 1.0, 0.6), 1.3, 14.0)
	_rubble(Vector3(-13.4, f, -138.4), 1.3, 11)
	_rubble(Vector3(13.6, f, -101.6), 0.9, 7)
	_rubble(Vector3(6.0, f, -139.0), 0.7, 5)
	var webs := _corner_webs(Vector2(0, -120), Vector2(30, 40), f + 7.0, 3.0)
	_webs(webs, Color(0.56, 0.62, 0.54), 0.4)

func _dress_hall(f: float) -> void:
	# A lamp over the drain at the hall's far end, and old bones.
	_light(Vector3(0, f + 4.5, -205), Color(1.0, 0.75, 0.45), 1.6, 9.0)
	for b in [[Vector3(-7, 0, -181), 20.0], [Vector3(8, 0, -198), 140.0], [Vector3(-10, 0, -207), 250.0], [Vector3(5, 0, -186), 300.0]]:
		_prop(ART + "fc_bones.glb", Vector3(b[0].x, f, b[0].z), b[1], 1.4)
	# Great plain cloths on the long walls where the old tapestries hung.
	for z in [-180.0, -198.0]:
		_banner(Vector3(-23.8, f + 11.5, z), Vector2(3.2, 7.0), PLUM, LINEN)
		_banner(Vector3(23.8, f + 11.5, z), Vector2(3.2, 7.0), PLUM, LINEN)
	for z in [-168.0, -184.0, -200.0, -212.0]:
		_torch(Vector3(-23.3, f + 5.0, z), Color(1.0, 0.62, 0.3), 2.2, 16.0)
		_torch(Vector3(23.3, f + 5.0, z), Color(1.0, 0.62, 0.3), 2.2, 16.0)
	# A fire basket hung from the vault so the Wheelwarden reads at range, and
	# braziers on drums in the corners.
	_fire_basket(Vector3(0, f + 11.0, -188), f + wall_h + 7.0, Color(1.0, 0.68, 0.4), 34.0)
	for x in [-20.0, 20.0]:
		for z in [-164.5, -211.5]:
			_brazier(Vector3(x, f, z), Color(1.0, 0.6, 0.28), 2.4, 14.0, true)
	# The engine's chains: slung from rings high on the end walls, the free
	# ends hanging to the hall's floor rings.
	for x in [-14.0, 14.0]:
		_chain(Shapes.sag_points(Vector3(x, f + 9.0, -160.15), Vector3(x * 0.5, f + 9.0, -160.15), 1.2), 0.22)
		_chain(PackedVector3Array([Vector3(x * 0.75, f + 7.8, -160.15), Vector3(x * 0.75, f + 2.2, -160.15)]), 0.22)
	_rubble(Vector3(-22.4, f, -176.0), 1.4, 12)
	_rubble(Vector3(22.6, f, -207.0), 1.2, 10)
	_rubble(Vector3(-14.0, f, -214.6), 1.0, 8)
	_webs(_corner_webs(Vector2(0, -188), Vector2(48, 56), f + 12.5, 4.0), Color(0.6, 0.6, 0.58), 0.4)
	# The sluice wheel's stone foot and post (SluiceWheel draws the wheel
	# itself). The old 1 m pedestal box is not drawn: it goes, and the foot and
	# the post get boxes inside them.
	removed.append({"note": "the old pedestal (1 m box, 1.6 m square): the sluice wheel's foot is drawn",
		"min": [WHEEL.x - 0.9, f - 0.1, WHEEL.z - 0.9], "max": [WHEEL.x + 0.9, f + 1.1, WHEEL.z + 0.9]})
	solids.append({"note": "the sluice wheel's foot: drawn, inside its round base",
		"center": [WHEEL.x, f + 0.185, WHEEL.z], "half": [0.38, 0.185, 0.38], "yaw_deg": 0})
	solids.append({"note": "the sluice wheel's post: drawn",
		"center": [WHEEL.x, f + 0.9, WHEEL.z], "half": [0.05, 0.9, 0.6], "yaw_deg": 0})
	var post := Node3D.new()
	post.name = "SluiceFoot"
	post.position = Vector3(WHEEL.x, f, WHEEL.z)
	dressing.add_child(post)
	var foot := MeshInstance3D.new()
	var drum := CylinderMesh.new()
	drum.top_radius = 0.5
	drum.bottom_radius = 0.56
	drum.height = 0.37
	foot.mesh = drum
	foot.material_override = _trim
	foot.position.y = 0.185
	post.add_child(foot)
	var pillar := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(0.1, 1.5, 0.2)
	pillar.mesh = bar
	pillar.material_override = _base
	pillar.position.y = 1.05
	post.add_child(pillar)
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.62, 0.92, 0.86)
	glow.light_energy = 1.2
	glow.omni_range = 6.0
	glow.position = Vector3(0, 2.0, 0)
	post.add_child(glow)
	_lights += 1

func _dress_reward(f: float) -> void:
	_banner(Vector3(0.0, f + 7.0, -231.8), Vector2(2.6, 4.8), PLUM, LINEN)
	_rubble(Vector3(-6.6, f, -230.4), 0.9, 7)
	_webs(_corner_webs(Vector2(0, -224), Vector2(16, 16), f + 6.6), Color(0.6, 0.6, 0.58), 0.4)
