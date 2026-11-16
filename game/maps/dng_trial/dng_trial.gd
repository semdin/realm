extends "res://maps/dng_common/dungeon_view.gd"

## The Trial Hall drawn (maps.json "dng_trial"): the old game's first dungeon
## (scripts/world/dungeons/dungeon_trial.gd), a proving hall on the east
## terrace where the dead are set against the living: cold cut stone over a
## rubble base course, barrel vaults on pilasters and arched ribs, plain
## ash-and-linen cloths, braziers on stone drums, bone shelves in the
## ossuaries and a sand-and-flag fighting floor under a hanging fire basket.
##
## Rooms, north (entry, local z +12) to south:
##   entry hall    z  12 ..  -12   the way back                         start
##   corridor      z -12 ..  -36   a pack; side rooms west/east          gate_h
##   pillared hall z -36 ..  -80   packs between pillars; ossuaries west/east
##   passage       z -80 .. -100   a pack                               gate_a
##   arena         z -100 .. -152  the Trial Warden                     gate_x
##   way out       z -152 .. -168  the exit once the trial is complete
## Positions are local to the copy (the scene stands at the copy's offset).

const BONES := "res://assets/dungeons/sealed_wing/fc_bones.glb"
const CAVE_BONES := "res://assets/models/caverns/cavern_bones.glb"
## The cloths: undyed linen banded in ash grey (house-neutral).
const ASH := Color(0.47, 0.45, 0.43)
const LINEN := Color(0.84, 0.8, 0.72)

var _arena_floor: Material
var _side_floor: Material

func _materials() -> void:
	super._materials()
	_arena_floor = surf("dirt_ground_01", Color(0.62, 0.56, 0.48), 3.0,
		{"second": "cobblestone_large_01", "tint2": Color(0.62, 0.62, 0.6), "metres2": 3.5, "cover": 0.45, "macro": 0.35})
	_side_floor = surf("stone_tiles_02", Color(0.55, 0.56, 0.56), 3.0,
		{"second": "dirt_ground_01", "tint2": Color(0.45, 0.42, 0.38), "metres2": 2.5, "cover": 0.3, "moss": 0.35,
			"moss_color": Color(0.17, 0.2, 0.13)})

func _build() -> void:
	map_id = "dng_trial"
	floor_y = 1000.0
	ambient_scale = 2.4
	fill_energy = 0.55
	var f := floor_y
	var wy := f + wall_h * 0.5
	_room(Vector2(0, 0), Vector2(24, 24), [-12.0])
	# Corridor with the side rooms off it.
	_box(Vector3(0, f - 0.5, -24), Vector3(8, 1, 24), _floor_mat)
	_wall_x(-4.5, wy, -36, -12, [-24.0])
	_wall_x(4.5, wy, -36, -12, [-24.0])
	_ceiling(Vector2(0, -24), Vector2(8, 22), f + wall_h)
	var hall_floor := _floor_mat
	_floor_mat = _side_floor
	_room(Vector2(-12.5, -24), Vector2(15, 14), [], 8.0, INF, [], 1)
	_room(Vector2(12.5, -24), Vector2(15, 14), [], 8.0, INF, [], -1)
	_floor_mat = hall_floor
	# The pillared hall and its ossuaries.
	_room(Vector2(0, -58), Vector2(34, 44), [-36.0, -80.0], 8.0, INF, [Vector2(-1, -58), Vector2(1, -58)])
	_floor_mat = _side_floor
	_room(Vector2(-25, -58), Vector2(16, 18), [], 8.0, INF, [], 1)
	_room(Vector2(25, -58), Vector2(16, 18), [], 8.0, INF, [], -1)
	_floor_mat = hall_floor
	for x in [-8.0, 8.0]:
		for z in [-48.0, -68.0]:
			_box(Vector3(x, wy, z), Vector3(1.6, wall_h, 1.6), _trim)
			_pillar_dress(Vector3(x, f, z))
	# The passage to the arena.
	_box(Vector3(0, f - 0.5, -90), Vector3(8, 1, 20), _floor_mat)
	_wall_x(-4.5, wy, -100, -80, [])
	_wall_x(4.5, wy, -100, -80, [])
	_ceiling(Vector2(0, -90), Vector2(8, 18), f + wall_h)
	_floor_mat = _arena_floor
	_room(Vector2(0, -126), Vector2(40, 52), [-100.0, -152.0])
	_floor_mat = hall_floor
	# Behind the arena: the way out, opened when the trial is complete.
	_room(Vector2(0, -160), Vector2(16, 16), [-152.0])
	for z in [8.0, -8.0]:
		for x in [-10.0, 10.0]:
			_torch(Vector3(x, f + 3.5, z))
	for z in [-16.0, -32.0, -84.0, -96.0]:
		for x in [-3.5, 3.5]:
			_torch(Vector3(x, f + 3.5, z))
	for z in [-42.0, -58.0, -74.0]:
		for x in [-16.0, 16.0]:
			if z != -58.0:
				_torch(Vector3(x, f + 3.5, z))
	for x in [-19.5, 19.5]:
		_torch(Vector3(x, f + 3.5, -24), Color(0.75, 0.85, 1.0), 1.3)
	for x in [-32.0, 32.0]:
		_torch(Vector3(x, f + 3.5, -58), Color(0.6, 1.0, 0.7), 1.3)
	for z in [-110.0, -126.0, -142.0]:
		for x in [-18.0, 18.0]:
			_torch(Vector3(x, f + 3.5, z))
	_dress(f)

## A pillar's foot and head: a moulded base and a capital, both drawn (the
## base 0.2 m proud of the shaft: under a body's radius).
func _pillar_dress(at: Vector3) -> void:
	_deco(at + Vector3(0, 0.3, 0), Vector3(2.0, 0.6, 2.0), _trim)
	_deco(at + Vector3(0, 0.75, 0), Vector3(1.8, 0.3, 1.8), _base)
	_deco(at + Vector3(0, wall_h - 0.45, 0), Vector3(2.1, 0.5, 2.1), _trim)

func _dress(f: float) -> void:
	# Cloths: one each side of the entry hall, between the pillared hall's
	# pilasters, down the arena's long walls and on its far wall.
	for x in [-11.8, 11.8]:
		for z in [3.0, -3.0]:
			_banner(Vector3(x, f + 6.6, z), Vector2(1.6, 4.4), LINEN, ASH)
	for z in [-45.0, -51.0, -69.0]:
		for x in [-16.8, 16.8]:
			_banner(Vector3(x, f + 6.8, z), Vector2(1.6, 4.4), LINEN, ASH)
	for z in [-115.0, -133.0]:
		for x in [-19.8, 19.8]:
			_banner(Vector3(x, f + 7.0, z), Vector2(2.0, 5.0), LINEN * 0.92, ASH)
	for x in [-12.0, 12.0]:
		_banner(Vector3(x, f + 7.0, -151.8), Vector2(2.0, 5.2), LINEN, ASH)
	# Braziers on stone drums: either side of the way into the corridor, the
	# pillared hall's corners, the arena's four corners.
	for x in [-8.0, 8.0]:
		_brazier(Vector3(x, f, -9.0), Color(1.0, 0.62, 0.3), 2.0, 11.0, true)
	for x in [-14.5, 14.5]:
		for z in [-39.5, -76.5]:
			_brazier(Vector3(x, f, z), Color(1.0, 0.62, 0.3), 2.2, 12.0, true)
		for z in [-103.5, -148.5]:
			_brazier(Vector3(x * 1.17, f, z), Color(1.0, 0.6, 0.28), 2.6, 14.0, true)
	# The fire basket over the arena, hung on three chains from the crown.
	_fire_basket(Vector3(0, f + 7.2, -126), f + wall_h + 7.0)
	# The ossuaries: bone shelves down the end wall, heaps in the corners.
	for side in [-1.0, 1.0]:
		_bone_shelves(Vector3(side * 33.0, f, -58.0), side)
		_prop(CAVE_BONES, Vector3(side * 28.5, f, -65.0), 40.0 * side, 0.7)
		_prop(BONES, Vector3(side * 21.5, f, -51.5), 200.0 * side, 0.8)
	# Fallen stone in the corners and against the walls.
	_rubble(Vector3(-10.6, f, 10.6), 1.2, 9)
	_rubble(Vector3(10.8, f, -10.4), 0.9, 6)
	_rubble(Vector3(-15.8, f, -78.6), 1.3, 11)
	_rubble(Vector3(15.9, f, -37.2), 1.0, 7)
	_rubble(Vector3(-19.0, f, -128.0), 1.0, 8)
	_rubble(Vector3(18.8, f, -101.2), 1.2, 9)
	_rubble(Vector3(-3.3, f, -98.0), 0.6, 5)
	_rubble(Vector3(-6.8, f, -166.6), 0.9, 7)
	_rubble(Vector3(-19.0, f, -30.0), 0.9, 6)
	_rubble(Vector3(31.8, f, -66.0), 0.8, 6)
	# Chains slung between rings on the corridor's and the passage's walls.
	for x in [-4.0, 4.0]:
		for z in [-18.5, -29.5]:
			_chain(Shapes.sag_points(Vector3(x - signf(x) * 0.05, f + 5.6, z - 1.5), Vector3(x - signf(x) * 0.05, f + 5.6, z + 1.5), 0.5))
		_chain(Shapes.sag_points(Vector3(x - signf(x) * 0.05, f + 5.4, -92.2), Vector3(x - signf(x) * 0.05, f + 5.4, -87.8), 0.75))

## Stone shelves of bones on an ossuary's end wall (`at` on the wall's
## inner face, `side` -1 west / +1 east), three high in each bay between
## the wall's pilasters: drawn, and one box round each stack for the patches
## (it stands 0.5 m out at knee height).
func _bone_shelves(at: Vector3, side: float) -> void:
	var depth := 0.55
	var x := at.x - side * depth * 0.5
	# the bays: the room's 18 m end wall, pilasters 0.9 m wide at z -55, -61
	for bay: Vector2 in [Vector2(-66.8, -61.6), Vector2(-60.4, -55.6), Vector2(-54.4, -49.2)]:
		var mid := (bay.x + bay.y) * 0.5
		var length := bay.y - bay.x
		# a shelf every 0.95 m (the bones on one are clear of the next one up)
		for i in 3:
			var y := at.y + 0.6 + float(i) * 0.95
			_deco(Vector3(x, y, mid), Vector3(depth, 0.12, length), _trim)
			for k in 2:
				var z := mid + (float(k) - 0.5) * length * 0.5 + (0.4 if i % 2 == 1 else -0.2)
				_prop(BONES, Vector3(x, y + 0.06, z), 180.0 * float((k + i) % 2), 0.18)
		for e in [-1.0, 1.0]:
			_deco(Vector3(x, at.y + 0.27, mid + e * (length * 0.5 - 0.2)), Vector3(depth, 0.54, 0.3), _trim)
		solids.append({"note": "bone shelves on the %s ossuary's end wall, z %.0f: drawn, no collider" % ["west" if side < 0.0 else "east", mid],
			"center": [snappedf(x, 0.01), snappedf(at.y + 1.3, 0.01), snappedf(mid, 0.01)],
			"half": [depth * 0.5, 1.3, snappedf(length * 0.5, 0.01)], "yaw_deg": 0})
