extends "res://maps/dng_common/dungeon_view.gd"

## The Silk Queen's Lair drawn (maps.json "dng_spider_lair"), behind the web
## gates of the Blackweb Caverns: the old game's code-built lair in the
## caverns' own stone, light and dressing. Its rooms are the server's boxes,
## drawn as a cave: rough rock skins over the walls (under a body's radius
## proud), low rock domes overhead with stalactites, silk everywhere - webs
## across the tunnels and the corners, cocoons hung from the rock - egg
## clutches, bones, glowing mushrooms and spores drifting in the violet light.
##
## Rooms, north (entry, local z +10) to south:
##   entry hall      z  10 ..  -10   the way back                     start
##   web tunnel      z -10 ..  -50   spiders; the silk nest east (side slot)
##   egg chamber     z -50 .. -100   egg sacs to burn                 gate_a
##   brood hall      z -100 .. -140  the Brood Guardian; the bone pit west  gate_b
##   mother's nest   z -140 .. -212  the Silk Queen                   gate_c
##   hoard           z -212 .. -228  the chest, the way out
## Positions are local to the copy (the scene stands at the copy's offset).

const PROP := "res://assets/models/caverns/cavern_%s.glb"
const SILK := Color(0.72, 0.74, 0.8)

## The rooms' inner rects (center, size) for the webs and the stalactites.
const ROOMS := [
	[Vector2(0, 0), Vector2(20, 20), 8.0], [Vector2(0, -30), Vector2(10, 40), 8.0], [Vector2(15, -30), Vector2(18, 16), 8.0],
	[Vector2(0, -75), Vector2(36, 50), 8.0], [Vector2(0, -120), Vector2(24, 40), 8.0], [Vector2(-21, -120), Vector2(18, 16), 8.0],
	[Vector2(0, -176), Vector2(56, 72), 14.0], [Vector2(0, -220), Vector2(16, 16), 8.0]]

func _materials() -> void:
	# the caverns' brown rock, its bedding darker where the damp runs
	var rock := {"grime": 0.5, "grime_height": 2.0, "streaks": 0.45, "macro": 0.32, "moss": 0.15,
		"moss_color": Color(0.22, 0.22, 0.2), "moss_height": 1.2}
	_stone = surf("cave_wall", Color(0.8, 0.76, 0.74), 3.4, rock)
	var uv := rock.duplicate()
	uv["mapping"] = 1
	_rock_uv = surf("cave_wall", Color(0.8, 0.76, 0.74), 3.4, uv)
	_floor_mat = surf("cave_gravel", Color(0.72, 0.7, 0.72), 3.6,
		{"second": "cave_dust", "tint2": Color(0.7, 0.68, 0.7), "metres2": 4.2, "cover": 0.5, "macro": 0.42})
	_vault = _stone
	_vault_uv = _rock_uv
	_trim = surf("cave_dust", Color(0.6, 0.58, 0.62), 2.5, {"grime": 0.3})
	_trim_uv = _rock_uv
	_base = _stone
	_rubble_mat = surf("cave_wall", Color(0.62, 0.58, 0.56), 1.6, {"grime": 0.3, "streaks": 0.0})
	fill_color = Color(0.7, 0.6, 0.95)
	fill_energy = 0.4

func _build() -> void:
	map_id = "dng_spider_lair"
	atmosphere = "cavern"
	floor_y = 1700.0
	bay = 0.0   # rock walls carry no pilasters
	ceiling = "rock"
	rock_walls = true
	ambient_scale = 1.25
	var f := floor_y
	_room(Vector2(0, 0), Vector2(20, 20), [-10.0])
	_room(Vector2(0, -30), Vector2(10, 40), [-10.0, -50.0], 8.0, INF, [Vector2(1, -30)])
	_room(Vector2(15, -30), Vector2(18, 16), [], 8.0, INF, [], -1)
	_room(Vector2(0, -75), Vector2(36, 50), [-50.0, -100.0])
	_room(Vector2(0, -120), Vector2(24, 40), [-100.0, -140.0], 8.0, INF, [Vector2(-1, -120)])
	_room(Vector2(-21, -120), Vector2(18, 16), [], 8.0, INF, [], 1)
	wall_h = 14.0
	_room(Vector2(0, -176), Vector2(56, 72), [-140.0, -212.0])
	wall_h = 8.0
	_room(Vector2(0, -220), Vector2(16, 16), [-212.0])
	# The nest is taller than the rooms either side: wall over their doorways.
	_box(Vector3(0, f + 11.0, -140), Vector3(8.2, 6.0, 1))
	_box(Vector3(0, f + 11.0, -212), Vector3(8.2, 6.0, 1))
	_dress(f)
	_silk(f)
	_hanging_rock(f)
	_talus(f)

func _dress(f: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7311
	# Entry and tunnel: silk-hung walls, cold light.
	for z in [4.0, -4.0]:
		_torch(Vector3(-9.3, f + 3.0, z), Color(0.6, 0.85, 1.0), 1.2)
		_torch(Vector3(9.3, f + 3.0, z), Color(0.6, 0.85, 1.0), 1.2)
	for z in [-18.0, -40.0]:
		_torch(Vector3(-4.3, f + 3.0, z), Color(0.7, 0.9, 0.6), 1.2)
	_torch(Vector3(4.3, f + 3.0, -46.0), Color(0.7, 0.9, 0.6), 1.2)
	for z in [-14.0, -26.0, -38.0, -47.0]:
		_prop(PROP % "cocoon", Vector3(-4.2 if int(z) % 2 == 0 else 4.2, f, z), rng.randf_range(0, 360), rng.randf_range(0.8, 1.1))
	# The silk nest and the bone pit (side slots).
	_prop(PROP % "eggs", Vector3(21, f, -24), 40.0, 0.7)
	_prop(PROP % "cocoon", Vector3(22, f, -36), 10.0, 1.0)
	_torch(Vector3(23.3, f + 3.0, -30), Color(0.8, 0.55, 1.0), 1.3)
	_prop(PROP % "bones", Vector3(-26, f, -116), 120.0, 1.1)
	_prop(PROP % "bones", Vector3(-24, f, -126), 300.0, 0.9)
	_torch(Vector3(-29.3, f + 3.0, -120), Color(1.0, 0.6, 0.35), 1.3)
	# The egg chamber: clutches along the walls, glowing mushrooms.
	for at in [Vector3(-16, 0, -54), Vector3(16, 0, -56), Vector3(-16, 0, -97), Vector3(16, 0, -97)]:
		_prop(PROP % "eggs", Vector3(at.x, f, at.z), rng.randf_range(0, 360), rng.randf_range(0.6, 0.8))
	for at in [Vector3(-17, 0, -70), Vector3(17, 0, -88), Vector3(-6, 0, -98)]:
		_prop(PROP % "mushrooms", Vector3(at.x, f, at.z), rng.randf_range(0, 360), 0.9)
	for z in [-58.0, -76.0, -94.0]:
		_torch(Vector3(-17.3, f + 3.2, z), Color(0.8, 0.55, 1.0), 1.4, 13.0)
		_torch(Vector3(17.3, f + 3.2, z), Color(0.8, 0.55, 1.0), 1.4, 13.0)
	# The brood hall: stalagmites and bones.
	for at in [Vector3(-10, 0, -106), Vector3(10, 0, -134)]:
		_stalagmite(_prop(PROP % "stalag", Vector3(at.x, f, at.z), rng.randf_range(0, 360), 0.8),
			"stalagmite in the brood hall at (%.0f, %.0f)" % [at.x, at.z])
	_prop(PROP % "bones", Vector3(8, f, -112), 60.0, 1.0)
	for z in [-110.0, -130.0]:
		_torch(Vector3(11.3, f + 3.2, z), Color(1.0, 0.6, 0.35), 1.4)
	# The Mother's nest: a ring of clutches and cocoons, crags at the rim, one
	# great violet light over the arena so she reads at range.
	for i in 10:
		var a := TAU * float(i) / 10.0
		var at := Vector3(cos(a) * 23.0, 0, -176.0 + sin(a) * 30.0)
		_prop(PROP % ("eggs" if i % 2 == 0 else "cocoon"), Vector3(at.x, f, at.z), rng.randf_range(0, 360), rng.randf_range(0.7, 1.0))
	for at in [Vector3(-24, 0, -146), Vector3(24, 0, -148), Vector3(-25, 0, -206), Vector3(25, 0, -204)]:
		_stalagmite(_prop(PROP % "stalag", Vector3(at.x, f, at.z), rng.randf_range(0, 360), 1.2),
			"stalagmite at the nest's rim at (%.0f, %.0f)" % [at.x, at.z])
	for z in [-150.0, -176.0, -202.0]:
		_torch(Vector3(-27.3, f + 5.0, z), Color(0.8, 0.5, 1.0), 2.0, 16.0)
		_torch(Vector3(27.3, f + 5.0, z), Color(0.8, 0.5, 1.0), 2.0, 16.0)
	_light(Vector3(0, f + 12.0, -176), Color(0.72, 0.5, 1.0), 2.2, 36.0)
	# Crags standing out of the corners and the long walls, so no room
	# reads as a box (solids: map_solids.gd boxes them from the mesh).
	for c: Array in [[Vector3(-7.6, 0, 7.6), 0.55], [Vector3(7.8, 0, 7.4), 0.5], [Vector3(-7.4, 0, -7.6), 0.45],
			[Vector3(7.6, 0, -7.5), 0.5], [Vector3(16.2, 0, -66.5), 0.55], [Vector3(-16.4, 0, -66.0), 0.5],
			[Vector3(-11.5, 0, -97.6), 0.5], [Vector3(11.5, 0, -97.6), 0.5], [Vector3(-26.0, 0, -163.0), 0.75],
			[Vector3(26.0, 0, -189.0), 0.75], [Vector3(-26.0, 0, -190.0), 0.7], [Vector3(26.2, 0, -163.5), 0.7]]:
		var at: Vector3 = c[0]
		_stalagmite(_prop(PROP % "stalag", Vector3(at.x, f, at.z), rng.randf_range(0, 360), float(c[1])),
			"crag at (%.0f, %.0f)" % [at.x, at.z])
	# The hoard.
	_prop(PROP % "bones", Vector3(-5, f, -222), 0.0, 0.8)
	_torch(Vector3(-7.3, f + 3.0, -220), Color(1.0, 0.75, 0.4), 1.6)
	_torch(Vector3(7.3, f + 3.0, -220), Color(1.0, 0.75, 0.4), 1.6)
	# Broken rock at the walls' feet.
	for r: Array in [[Vector3(-8.6, f, 8.4), 1.0], [Vector3(8.4, f, -8.6), 0.8], [Vector3(-3.9, f, -24.0), 0.6],
			[Vector3(16.6, f, -51.6), 1.3], [Vector3(-16.8, f, -84.0), 1.0], [Vector3(10.8, f, -101.6), 1.0],
			[Vector3(-10.8, f, -138.4), 0.9], [Vector3(26.4, f, -160.0), 1.4], [Vector3(-26.6, f, -190.0), 1.4],
			[Vector3(6.6, f, -226.6), 0.9]]:
		_rubble(r[0], r[1], int(r[1] * 9.0))
	# Spores drifting in the violet air of the egg chamber and the nest.
	if DisplayServer.get_name() != "headless":
		for s: Array in [[Vector3(0, f + 2.0, -75), 14.0, 30], [Vector3(0, f + 3.0, -176), 22.0, 46]]:
			var motes := RisingMotes.make(float(s[1]), 4.0, Color(0.78, 0.6, 1.0), int(s[2]), 9.0, Vector2(0.05, 0.22), Vector2(0.012, 0.03))
			motes.position = s[0]
			dressing.add_child(motes)
			motes.emitting = true

## Silk: orb webs across every room's upper corners, sheets slung under the
## tunnel's rock and over the nest's doorways, strands down the walls.
func _silk(f: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4402
	var webs: Array = []
	for room: Array in ROOMS:
		var c: Vector2 = room[0]
		var size: Vector2 = room[1]
		var top := f + float(room[2]) - 1.6
		var s := clampf(minf(size.x, size.y) * 0.22, 2.6, 6.0)
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var at := Vector3(c.x + sx * (size.x * 0.5 - s * 0.3), top, c.y + sz * (size.y * 0.5 - s * 0.3))
				webs.append([at, Vector3(-sx, -0.5, -sz), s])
		# webs on the long walls, high up
		var count := int(size.y / 9.0)
		for i in count:
			var z := c.y - size.y * 0.5 + (float(i) + 0.5) * size.y / count + rng.randf_range(-1.5, 1.5)
			var side := -1.0 if i % 2 == 0 else 1.0
			webs.append([Vector3(c.x + side * (size.x * 0.5 - 0.35), top - rng.randf_range(0.0, 1.5), z),
				Vector3(-side, rng.randf_range(-0.2, 0.2), rng.randf_range(-0.3, 0.3)), rng.randf_range(2.5, 4.5)])
	# sheets under the tunnel's rock, facing down
	for z in [-16.0, -27.0, -39.0, -46.0]:
		webs.append([Vector3(rng.randf_range(-1.5, 1.5), f + 7.2, z), Vector3(0, -1, 0.15), 5.5])
	webs.append([Vector3(0, f + 13.0, -141.0), Vector3(0, -0.3, -1), 9.0])
	webs.append([Vector3(0, f + 13.0, -211.0), Vector3(0, -0.3, 1), 9.0])
	_webs(webs, SILK, 0.6)

## Stalactites from the rock domes (the caverns' stalag mesh hung tip down,
## tips at least 4.5 m over the floor) and cocoons hung on silk.
func _hanging_rock(f: float) -> void:
	var source := (load(PROP % "stalag") as PackedScene).instantiate() as Node3D
	var found := source.find_children("*", "MeshInstance3D", true, false)
	if found.is_empty():
		source.free()
		return
	var mesh := (found[0] as MeshInstance3D).mesh
	source.free()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var xforms: Array = []
	for room: Array in ROOMS:
		var c: Vector2 = room[0]
		var size: Vector2 = room[1]
		var n := int(size.x * size.y / 70.0)
		for i in n:
			var x := c.x + rng.randf_range(-0.42, 0.42) * size.x
			var z := c.y + rng.randf_range(-0.42, 0.42) * size.y
			var top := rock_ceiling_at(x, z)
			if top == INF:
				continue
			var room_top := (top - (f + 4.5)) / 7.0
			var s := minf(rng.randf_range(0.14, 0.4), room_top)
			if s < 0.1:
				continue
			# hung tip down, its root sunk into the rock
			var basis := Basis(Vector3.RIGHT, PI) * Basis(Vector3.UP, rng.randf() * TAU)
			xforms.append(Transform3D(basis.scaled(Vector3(s, s, s)), Vector3(x, top + 0.5 * s + 0.25, z)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = "Stalactites"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dressing.add_child(inst)
	# cocoons hung from the rock on a strand of silk
	for at: Vector2 in [Vector2(-12, -64), Vector2(10, -86), Vector2(-14, -160), Vector2(16, -170), Vector2(-6, -196),
			Vector2(9, -122), Vector2(18, -200)]:
		var top := rock_ceiling_at(at.x, at.y)
		if top == INF:
			continue
		var s := rng.randf_range(0.75, 1.0)
		var bottom := maxf(f + 4.2, top - 4.5)
		var cocoon := _prop(PROP % "cocoon", Vector3(at.x, bottom, at.y), rng.randf_range(0, 360), s)
		if cocoon != null:
			var strand := MeshInstance3D.new()
			strand.name = "Strand"
			var bm := BoxMesh.new()
			var length := top - (bottom + 2.4 * s) + 0.3
			bm.size = Vector3(0.025, maxf(length, 0.1), 0.025)
			var silk := StandardMaterial3D.new()
			silk.albedo_color = Color(0.75, 0.76, 0.8)
			silk.roughness = 0.6
			bm.material = silk
			strand.mesh = bm
			strand.position = Vector3(at.x, bottom + 2.4 * s + length * 0.5 - 0.15, at.y)
			strand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			dressing.add_child(strand)

## Broken rock along the foot of every wall (where a wall stands: doorways
## stay clear), so no room meets its floor on a straight line. Low enough to
## step over, no further out than a body's width.
func _talus(f: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6101
	for room: Array in ROOMS:
		var c: Vector2 = room[0]
		var size: Vector2 = room[1]
		var hx := size.x * 0.5 - 0.3
		var hz := size.y * 0.5 - 0.3
		var edges: Array = [[Vector2(c.x - hx, c.y - hz), Vector2(c.x + hx, c.y - hz)], [Vector2(c.x - hx, c.y + hz), Vector2(c.x + hx, c.y + hz)],
			[Vector2(c.x - hx, c.y - hz), Vector2(c.x - hx, c.y + hz)], [Vector2(c.x + hx, c.y - hz), Vector2(c.x + hx, c.y + hz)]]
		for e: Array in edges:
			var a: Vector2 = e[0]
			var b: Vector2 = e[1]
			var n := int(a.distance_to(b) / 1.1)
			for i in n:
				var p := a.lerp(b, (float(i) + rng.randf()) / n)
				if _nearest_wall(Vector3(p.x, f + 1.0, p.y), 0.6).is_empty():
					continue
				_rubble(Vector3(p.x, f, p.y), 0.45, 3, 0.38, rng.randi() % 100000 + 1)
