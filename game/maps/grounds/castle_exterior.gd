extends RefCounted

## The castle as seen from the grounds: a walled fortress of halls, wings and
## towers on the promontory (plateau ~58 m). Nothing here is enterable except
## the great doors, which are the portal into the castle interior map.
##
## The look (world overhaul step 6, the user's pick "sert kale"): heavy round
## towers with machicolated crowns and battlements, flat tops with a banner, a
## low slate cap only on the three great towers; halls behind crenellated
## parapets on corbel tables, their roofs set back behind a wall walk, string
## courses at every floor, pilaster buttresses and a stepped plinth; a
## machicolated bretèche over the great doors. Warm grey stone, lead-grey slate.
##
## Layout is in castle-local metres with the origin at ORIGIN and +z pointing at
## the courtyard (south). The entrance front is at local z = 55, i.e. world z = 5,
## which is where maps.json puts the castle_door portal.
##
## Every block's foundation is extended down to the lowest ground under its
## footprint, so a hall on the plateau edge sits on masonry, never on air.

const PBR := preload("res://maps/grounds/grounds_pbr.gd")
const Layout := preload("res://maps/grounds/grounds_layout.gd")
const ArchKit := preload("res://maps/grounds/arch_kit.gd")

const ORIGIN := Vector3(0.0, 0.0, -50.0)
## Door opening (world): centre of the threshold, and the doorway size.
const DOOR_CENTER := Vector3(0.0, 0.0, 5.0)
const DOOR_SIZE := Vector2(6.0, 9.0)

## [name, centre x, centre z, size x, size z, wall height, roof height, roof axis ("x"/"z"/"pyr")]
const HALLS := [
	["EntranceHall", 0.0, 46.0, 28.0, 18.0, 24.0, 11.0, "z"],
	["FeastHall", -37.0, 40.0, 40.0, 18.0, 22.0, 12.0, "x"],
	["CentralKeep", 0.0, 18.0, 22.0, 26.0, 32.0, 14.0, "pyr"],
	["EastWing", 38.0, 36.0, 40.0, 16.0, 20.0, 9.0, "x"],
	["NorthRange", 0.0, -30.0, 96.0, 18.0, 26.0, 10.0, "x"],
	["WestRange", -56.0, 4.0, 16.0, 52.0, 22.0, 9.0, "z"],
	["Library", 40.0, 0.0, 26.0, 18.0, 24.0, 10.0, "x"],
]
## [name, x, z, radius, height, cap height (0: a flat top with a banner), windows per ring]
const TOWERS := [
	["StarTower", -46.0, -52.0, 8.05, 63.6, 7.0, 6],
	["VelkarTower", 42.0, -54.0, 8.05, 53.3, 6.1, 6],
	["IlvaneTower", 64.0, 6.0, 7.5, 48.2, 5.4, 6],
	["HighTower", 0.0, -48.0, 6.3, 46.4, 0.0, 5],
	["EntranceTowerW", -17.0, 54.0, 5.3, 29.2, 0.0, 4],
	["EntranceTowerE", 17.0, 54.0, 5.3, 29.2, 0.0, 4],
	["WestTowerS", -64.0, 46.0, 5.75, 34.4, 0.0, 4],
	["WestTowerN", -66.0, -18.0, 6.0, 37.8, 0.0, 4],
	["EastTowerS", 62.0, 44.0, 5.3, 31.0, 0.0, 4],
	["NorthEastTower", 62.0, -34.0, 5.75, 39.6, 0.0, 4],
	["KeepTowerW", -12.0, 4.0, 4.15, 41.3, 0.0, 3],
	["KeepTowerE", 12.0, 4.0, 4.15, 41.3, 0.0, 3],
]
## Curtain wall ring (local x, z), closed.
const CURTAIN := [[-64.0, 46.0], [-66.0, -18.0], [-46.0, -52.0], [0.0, -48.0], [42.0, -54.0], [62.0, -34.0], [64.0, 6.0], [62.0, 44.0]]
const CURTAIN_HEIGHT := 14.0
const CURTAIN_THICK := 3.0
## The clock tower: square, beside the east wing, facing the courtyard.
const CLOCK := [30.0, 56.0, 9.0, 46.0, 16.0]
## The clock tower's four faces (outward normals).
const CLOCK_FACES := [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, -1)]
## How far a hall's roof stands back from its parapet (the wall walk).
const WALK := 1.0
## A floor of the halls (string courses, window rows).
const FLOOR_H := 8.0


## The clock faces' material (clock_face.gdshader): the painted dial with
## Roman numerals (assets/maps/grounds/clock_dial.png, tools/art/clock_dial.py)
## and two hands showing the realm's hour (DayNight.hour(), set every
## CLOCK_TICK seconds), the enamel lit from behind at night
## (GroundsMap.apply_daylight -> daylight()).
static var clock_material: ShaderMaterial = null
## Its glow at night.
const CLOCK_GLOW := 0.9
const CLOCK_DIAL := preload("res://assets/maps/grounds/clock_dial.png")
const CLOCK_SHADER := preload("res://assets/shaders/clock_face.gdshader")
## The dial's diameter (m) on its 5.2 m stone plaque, and how often the
## hands move (s).
const CLOCK_DIAL_SIZE := 4.6
const CLOCK_TICK := 1.0


static func materials() -> Dictionary:
	var glass := ShaderMaterial.new()
	# Leaded glass mirroring the sky, with warm rooms behind some of the panes
	# (per-window random from ArchKit.window()).
	glass.shader = preload("res://assets/shaders/castle/window_lit.gdshader")
	glass.set_shader_parameter("quarry_m", 0.32)
	var clock := ShaderMaterial.new()
	clock.shader = CLOCK_SHADER
	clock.set_shader_parameter("dial", CLOCK_DIAL)
	clock.set_shader_parameter("glow", CLOCK_GLOW)
	clock.set_shader_parameter("hour", DayNight.hour())
	clock_material = clock
	var door := PBR.surface("medieval_wood", Color(0.55, 0.42, 0.32), {"metres": 2.0})
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.09, 0.085, 0.08)
	iron.metallic = 0.75
	iron.roughness = 0.5
	var banner := StandardMaterial3D.new()
	banner.albedo_color = Color(0.12, 0.22, 0.52)
	banner.roughness = 0.9
	banner.cull_mode = BaseMaterial3D.CULL_DISABLED
	return {
		"stone": PBR.surface("castle_wall_varriation", Color(0.70, 0.67, 0.62), {"metres": 6.0}),
		"trim": PBR.surface("stone_wall", Color(0.665, 0.63, 0.57), {"metres": 3.0}),
		"roof": PBR.surface("roof_slates_02", Color(0.40, 0.42, 0.45), {"metres": 3.0}),
		"banner": banner,
		"glass": glass,
		"door": door,
		# the doors' backing boards (dark in the gaps between the planks)
		"door_back": PBR.surface("medieval_wood", Color(0.22, 0.16, 0.12), {"metres": 2.0}),
		"iron": iron,
		# the porch floor and the apron: worn castle flags, a sandstone kerb
		"paving": PBR.surface("medieval_blocks_03", Color(0.92, 0.9, 0.86), {"metres": 3.0}),
		"kerb": PBR.surface("sandstone_blocks_08", Color(0.86, 0.83, 0.78), {"metres": 1.5}),
		"dark": _flat(Color(0.03, 0.03, 0.035)),
	}


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


static func _w(x: float, z: float) -> Vector3:
	return ORIGIN + Vector3(x, 0, z)


## Lowest and highest ground under a footprint rectangle (world).
static func _ground_span(c: Vector3, size: Vector2) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in 5:
		for j in 5:
			var p := c + Vector3((i / 4.0 - 0.5) * size.x, 0, (j / 4.0 - 0.5) * size.y)
			var h := Layout.height_at(p.x, p.z)
			if is_nan(h):
				continue
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return Vector2(lo, hi) if lo != INF else Vector2(58.0, 58.0)


static func build(parent: Node3D) -> Node3D:
	var kit := ArchKit.new()
	# The castle floor is the ground at the doors, so the threshold is flush with
	# the approach; blocks on higher ground are simply founded into it.
	var at_door := Layout.height_at(DOOR_CENTER.x, DOOR_CENTER.z + 3.0)
	var top := (at_door if not is_nan(at_door) else 58.0) + 0.05
	for h in HALLS:
		_hall(kit, h, top)
	for t in TOWERS:
		_tower(kit, t, top)
	_curtain(kit, top)
	_clock_tower(kit, top)
	_entrance(kit, top)
	var mats := materials()
	var node := kit.finish(parent, mats, "Castle")
	node.set_meta("floor_y", top)
	_clock_dials(node, top)
	_lights(node, top)
	return node


## The night's glow behind the clock dials (0 day .. 1 night).
static func daylight(night: float) -> void:
	if clock_material != null:
		clock_material.set_shader_parameter("glow", CLOCK_GLOW * lerpf(0.0, 1.0, night))


static func _hall(kit: ArchKit, h: Array, top: float) -> void:
	var c := _w(h[1], h[2])
	var size := Vector2(h[3], h[4])
	var wall_h: float = h[5]
	var span := _ground_span(c, size)
	var base := minf(span.x, top) - 3.0
	var height := top + wall_h - base
	kit.box(Vector3(c.x, base + height * 0.5, c.z), Vector3(size.x, height, size.y), 0.0, "stone")
	# a stepped plinth: two courses, the lower one wider
	kit.box(Vector3(c.x, (base + top + 1.4) * 0.5, c.z), Vector3(size.x + 2.0, top + 1.4 - base, size.y + 2.0), 0.0, "trim")
	kit.box(Vector3(c.x, top + 1.8, c.z), Vector3(size.x + 1.0, 0.8, size.y + 1.0), 0.0, "trim")
	# string courses at every floor
	var floors := maxi(1, int(wall_h / FLOOR_H))
	for f in range(1, floors):
		kit.box(Vector3(c.x, top + f * FLOOR_H + 0.5, c.z), Vector3(size.x + 0.5, 0.4, size.y + 0.5), 0.0, "trim", false)
	# the parapet: a corbel table under a crenellated wall head, the roof set
	# back behind a wall walk
	_parapet(kit, c, size, top + wall_h)
	var roof_base := Vector3(c.x, top + wall_h, c.z)
	var inner := size - Vector2(WALK, WALK) * 2.0
	match String(h[7]):
		"x":
			kit.gable(roof_base, inner, h[6], 0.0, "roof", "stone", 0.0)
		"z":
			kit.gable(roof_base, Vector2(inner.y, inner.x), h[6], PI * 0.5, "roof", "stone", 0.0)
		_:
			kit.pyramid(roof_base, inner, h[6], 0.0, "roof", 0.0)
	_chimneys(kit, h, c, size, top + wall_h)
	# windows: rows on the long faces, tall lancets
	for f in floors:
		var y := top + 4.5 + f * FLOOR_H
		var tall := 4.5 if f == floors - 1 and String(h[0]) == "FeastHall" else 2.6
		for side in [-1, 1]:
			var nx := int(size.x / 6.0)
			for i in nx:
				var x := c.x - size.x * 0.5 + (i + 0.5) * size.x / nx
				kit.window(Vector3(x, y, c.z + side * (size.y * 0.5 + 0.02)), Vector3(0, 0, side), 1.3, tall, "trim", "glass")
			var nz := int(size.y / 6.0)
			for i in nz:
				var z := c.z - size.y * 0.5 + (i + 0.5) * size.y / nz
				kit.window(Vector3(c.x + side * (size.x * 0.5 + 0.02), y, z), Vector3(side, 0, 0), 1.2, 2.4, "trim", "glass")
	# corner buttresses and pilasters between the window bays
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var p := Vector3(c.x + sx * size.x * 0.5, 0, c.z + sz * size.y * 0.5)
			kit.box(Vector3(p.x, base + (top + wall_h - 1.6 - base) * 0.5, p.z), Vector3(2.6, top + wall_h - 1.6 - base, 2.6), 0.0, "trim")
	var pil_top := top + wall_h - 1.8
	for side in [-1, 1]:
		var nx := int(size.x / 6.0)
		for i in range(1, nx):
			var x := c.x - size.x * 0.5 + i * size.x / nx
			kit.box(Vector3(x, (base + pil_top) * 0.5, c.z + side * (size.y * 0.5 + 0.35)), Vector3(1.2, pil_top - base, 0.7), 0.0, "trim", false)
		var nz := int(size.y / 6.0)
		for i in range(1, nz):
			var z := c.z - size.y * 0.5 + i * size.y / nz
			kit.box(Vector3(c.x + side * (size.x * 0.5 + 0.35), (base + pil_top) * 0.5, z), Vector3(0.7, pil_top - base, 1.2), 0.0, "trim", false)


## A hall's wall head: a row of corbels carrying a projecting crenellated
## parapet round all four sides.
static func _parapet(kit: ArchKit, c: Vector3, size: Vector2, y: float) -> void:
	var out := 0.5
	kit.box(Vector3(c.x, y - 0.35, c.z), Vector3(size.x + out * 2.0, 0.7, size.y + out * 2.0), 0.0, "trim")
	for side in [-1, 1]:
		for i in int(size.x / 1.4):
			var x := c.x - size.x * 0.5 + (i + 0.5) * 1.4
			kit.box(Vector3(x, y - 1.2, c.z + side * (size.y * 0.5 + 0.25)), Vector3(0.45, 1.0, 0.5), 0.0, "trim", false)
		for i in int(size.y / 1.4):
			var z := c.z - size.y * 0.5 + (i + 0.5) * 1.4
			kit.box(Vector3(c.x + side * (size.x * 0.5 + 0.25), y - 1.2, z), Vector3(0.5, 1.0, 0.45), 0.0, "trim", false)
	var hx := size.x * 0.5 + out - 0.4
	var hz := size.y * 0.5 + out - 0.4
	var corners := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	for i in 4:
		var a: Vector3 = c + corners[i] + Vector3.UP * y
		var b: Vector3 = c + corners[(i + 1) % 4] + Vector3.UP * y
		kit.battlements(a, b, 0.8, "trim", 1.3, 2.2)


## Chimney stacks rising from a hall's ridge roof.
static func _chimneys(kit: ArchKit, h: Array, c: Vector3, size: Vector2, eave: float) -> void:
	var axis := String(h[7])
	if axis != "x" and axis != "z":
		return
	var roof_h: float = h[6]
	var along := Vector3(1, 0, 0) if axis == "x" else Vector3(0, 0, 1)
	var across := Vector3(0, 0, 1) if axis == "x" else Vector3(1, 0, 0)
	var length: float = size.x if axis == "x" else size.y
	var depth: float = size.y if axis == "x" else size.x
	for t in [-0.3, 0.32]:
		var at: Vector3 = c + along * (length * float(t)) + across * (depth * 0.18)
		var y0 := eave + roof_h * 0.6
		kit.box(at + Vector3.UP * (y0 + 2.4), Vector3(1.6, 4.8 + roof_h * 0.4, 1.2), 0.0, "trim")
		kit.box(at + Vector3.UP * (y0 + 4.9), Vector3(2.0, 0.4, 1.6), 0.0, "stone", false)


## The towers' base drum: the bevel at its top (m), within reach of the
## collider's flat top.
const WEATHERING := 0.15


static func _tower(kit: ArchKit, t: Array, top: float) -> void:
	var c := _w(t[1], t[2])
	var r: float = t[3]
	var h: float = t[4]
	var cap: float = t[5]
	var span := _ground_span(c, Vector2(r * 2, r * 2))
	var base := minf(span.x, top) - 3.0
	var foot := Vector3(c.x, base, c.z)
	# the base drum, shaft, machicolated crown. The drum stands straight to a
	# sloped weathering 4 m over the castle floor: the server's collider for it
	# is that straight drum (the old world's cylinder took the batter's widest
	# radius), and a battered face left a hand's breadth to half a metre of air
	# where a body stopped short of the wall. The collider's top is flat at
	# 4 m out to the drum's edge, so the weathering is a shallow bevel just
	# under it (WEATHERING): the 0.8 m slope it was left a ring of air up to
	# 0.8 m deep that a broom rider landed on (placement_check.gd, 2026-11-16).
	kit.cylinder(foot, r * 1.18, top - base + 4.0 - WEATHERING, "stone", 20)
	kit.cylinder(Vector3(c.x, top + 4.0 - WEATHERING, c.z), r * 1.18, WEATHERING, "trim", 20, false, r * 1.02)
	kit.cylinder(Vector3(c.x, top + 4.0, c.z), r, h - 4.0, "stone", 20)
	kit.cylinder(Vector3(c.x, top + h - 1.2, c.z), r * 1.14, 1.6, "trim", 20)
	var n := int(r * 3.0)
	for i in n:
		var a := TAU * (i + 0.5) / n
		kit.box(Vector3(c.x + cos(a) * r * 1.07, top + h - 2.4, c.z + sin(a) * r * 1.07), Vector3(0.5, 1.4, 0.7), -a, "trim", false)
	kit.tower_battlements(Vector3(c.x, top + h + 0.4, c.z), r * 1.08, "trim", int(r * 2.2))
	var at := Vector3(c.x, top + h + 3.6, c.z)
	if cap > 0.0:
		# the great towers keep a drum and a low slate cap
		kit.cylinder(Vector3(c.x, top + h + 0.4, c.z), r * 0.86, 3.2, "stone", 18)
		kit.cone(at, r * 0.9, cap, "roof", 18, 1.12)
	else:
		# a lead flat behind the merlons and a banner on a pole
		kit.cylinder(Vector3(c.x, top + h + 0.4, c.z), r * 0.86, 0.4, "trim", 18)
		kit.cylinder(Vector3(c.x, top + h + 0.8, c.z), 0.1, 6.0, "trim", 6, false)
		kit.box(at + Vector3(0.75, 2.4, 0), Vector3(1.4, 0.9, 0.05), 0.0, "banner", false)
	var rings := maxi(2, int(h / 11.0))
	for k in rings:
		kit.tower_windows(Vector3(c.x, top, c.z), r, 8.0 + k * (h - 12.0) / maxf(1, rings - 1), int(t[6]), "trim", "glass", 0.9, 2.1, k * 0.4)


static func _curtain(kit: ArchKit, top: float) -> void:
	for i in CURTAIN.size():
		var a: Array = CURTAIN[i]
		var b: Array = CURTAIN[(i + 1) % CURTAIN.size()]
		var pa := _w(a[0], a[1])
		var pb := _w(b[0], b[1])
		var mid := (pa + pb) * 0.5
		var d := pb - pa
		var length := Vector2(d.x, d.z).length()
		var rot := atan2(-d.z, d.x)
		var span := _ground_span(mid, Vector2(length * 0.7, 4.0))
		var base := minf(span.x, top) - 3.0
		var height := top + CURTAIN_HEIGHT - base
		kit.box(Vector3(mid.x, base + height * 0.5, mid.z), Vector3(length, height, CURTAIN_THICK), rot, "stone")
		kit.battlements(Vector3(pa.x, top + CURTAIN_HEIGHT, pa.z), Vector3(pb.x, top + CURTAIN_HEIGHT, pb.z), CURTAIN_THICK * 0.4, "trim")


static func _clock_tower(kit: ArchKit, top: float) -> void:
	var c := _w(CLOCK[0], CLOCK[1])
	var s: float = CLOCK[2]
	var h: float = CLOCK[3]
	var span := _ground_span(c, Vector2(s, s))
	var base := minf(span.x, top) - 3.0
	kit.box(Vector3(c.x, base + (top + h - base) * 0.5, c.z), Vector3(s, top + h - base, s), 0.0, "stone")
	# a machicolated parapet round the foot of its slate spire
	_parapet(kit, Vector3(c.x, 0, c.z), Vector2(s, s), top + h)
	kit.pyramid(Vector3(c.x, top + h, c.z), Vector2(s - 2.0, s - 2.0), CLOCK[4], 0.0, "roof", 0.0)
	for n: Vector3 in CLOCK_FACES:
		var face := Vector3(c.x, top + h - 6.0, c.z) + n * (s * 0.5 + 0.06)
		# the stone plaque the round dial is set in (_clock_dials), and a
		# moulded frame round it
		kit.box(face, Vector3(5.2, 5.2, 0.2) if n.z != 0 else Vector3(0.2, 5.2, 5.2), 0.0, "trim", false)
		var across := Vector3.UP.cross(n)
		for k: float in [-1.0, 1.0]:
			kit.box(face + n * 0.14 + Vector3.UP * k * 2.68, across.abs() * 5.7 + n.abs() * 0.22 + Vector3.UP * 0.32, 0.0, "trim", false)
			kit.box(face + n * 0.14 + across * k * 2.68, across.abs() * 0.32 + n.abs() * 0.22 + Vector3.UP * 5.04, 0.0, "trim", false)
		kit.window(Vector3(c.x, top + 10.0, c.z) + n * (s * 0.5 + 0.02), n, 1.2, 3.0, "trim", "glass")
		kit.window(Vector3(c.x, top + 20.0, c.z) + n * (s * 0.5 + 0.02), n, 1.2, 3.0, "trim", "glass")


## The four dials, one mesh with UVs (the dial is painted, not triplanar):
## each a quad just proud of its plaque; a timer moves the hands with the
## realm's hour.
static func _clock_dials(node: Node3D, top: float) -> void:
	var c := _w(CLOCK[0], CLOCK[1])
	var s: float = CLOCK[2]
	var h: float = CLOCK[3]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := CLOCK_DIAL_SIZE * 0.5
	for n: Vector3 in CLOCK_FACES:
		var centre := Vector3(c.x, top + h - 6.0, c.z) + n * (s * 0.5 + 0.06 + 0.1 + 0.02)
		var right := Vector3.UP.cross(n)
		var corners := [centre - right * half + Vector3.UP * half, centre + right * half + Vector3.UP * half,
			centre + right * half - Vector3.UP * half, centre - right * half - Vector3.UP * half]
		var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		# clockwise seen from the front (Godot's front faces)
		for i: int in [0, 1, 2, 0, 2, 3]:
			st.set_normal(n)
			st.set_tangent(Plane(right, 1.0))
			st.set_uv(uvs[i])
			st.add_vertex(corners[i])
	var dials := MeshInstance3D.new()
	dials.name = "ClockDials"
	dials.mesh = st.commit()
	dials.material_override = clock_material
	dials.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(dials)
	var timer := Timer.new()
	timer.name = "ClockTick"
	timer.wait_time = CLOCK_TICK
	timer.autostart = true
	var mat := clock_material
	timer.timeout.connect(func() -> void: mat.set_shader_parameter("hour", DayNight.hour()))
	node.add_child(timer)


## The great doors: a deep arched porch in the entrance hall's south face. The
## porch floor is open (no collider in the doorway) so a player can walk up to
## the doors; the doors themselves are a solid slab at the back of the porch.
## Over the porch a bretèche: a machicolated box on corbels.
##
## Drawn over the server's solids (the piers, lintel, door slab and apron are
## the pack's boxes; everything added here stands over head height, inside
## the piers' footprint or within a few centimetres of a collider's face): a
## pointed arch carried on jamb shafts, its spandrels and soffit filling the
## porch head; two oak leaves of vertical planks with iron straps, studs and
## ring pulls on the slab; the porch floor and apron paved with worn flags
## inside a sandstone kerb, following the higher of the ground and the
## apron's top (the server's ground there), so no other surface shows
## through.
static func _entrance(kit: ArchKit, top: float) -> void:
	var front_z := DOOR_CENTER.z
	var w := DOOR_SIZE.x
	var h := DOOR_SIZE.y
	# porch: two piers and a lintel projecting 3 m from the facade
	for sx in [-1, 1]:
		kit.box(Vector3(sx * (w * 0.5 + 1.2), top + (h + 2.0) * 0.5, front_z + 1.5), Vector3(2.4, h + 2.0, 3.0), 0.0, "trim")
	kit.box(Vector3(0, top + h + 2.6, front_z + 1.5), Vector3(w + 4.8, 3.2, 3.0), 0.0, "trim")
	# the bretèche over the porch: corbels, a box with dark drop holes, merlons
	var by := top + h + 4.2
	for i in 6:
		var x := -w * 0.5 - 0.6 + i * (w + 1.2) / 5.0
		kit.box(Vector3(x, by + 0.5, front_z + 2.4), Vector3(0.5, 1.0, 1.2), 0.0, "trim", false)
	kit.box(Vector3(0, by + 2.6, front_z + 2.2), Vector3(w + 3.2, 3.2, 2.4), 0.0, "stone")
	for i in 4:
		kit.box(Vector3(-w * 0.5 + 0.4 + i * (w - 0.8) / 3.0, by + 1.05, front_z + 3.42), Vector3(0.7, 0.12, 0.06), 0.0, "dark", false)
	kit.battlements(Vector3(-w * 0.5 - 1.4, by + 4.2, front_z + 3.1), Vector3(w * 0.5 + 1.4, by + 4.2, front_z + 3.1), 0.6, "trim", 1.1, 1.8)
	# the doors stand at the back of the porch, just proud of the hall's plinth
	# (a door face level with the plinth face z-fought with it across the
	# bottom of the doors): the slab is the backing the planks are nailed to
	kit.box(Vector3(0, top + h * 0.5, front_z + 1.05), Vector3(w, h, 0.4), 0.0, "door_back")
	var door_face := front_z + 1.25
	var porch_front := front_z + 3.0
	_door_leaves(kit, top, w, h, door_face)
	_porch_arch(kit, top, w, h, door_face, porch_front)
	# a flush stone apron in front (its top is the threshold height)
	var g := Layout.height_at(DOOR_CENTER.x, DOOR_CENTER.z + 6.0)
	var apron_bottom := (g if not is_nan(g) else top) - 1.5
	kit.box(Vector3(0, (top + apron_bottom) * 0.5, front_z + 5.0), Vector3(w + 6.0, top - apron_bottom, 10.0), 0.0, "trim")
	_apron_paving(kit, top, Rect2(-(w + 6.0) * 0.5, front_z, w + 6.0, 10.0))


## The door's two leaves on the slab's face (z = `face`): vertical oak planks
## (the dark backing shows in the joints), a batten over the meeting stiles,
## three iron straps across each leaf with hinge flares and studs, and a ring
## pull on each leaf. All within 0.12 m of the slab.
static func _door_leaves(kit: ArchKit, top: float, w: float, h: float, face: float) -> void:
	var planks := 12
	var pw := w / planks
	for i in planks:
		var x := -w * 0.5 + (i + 0.5) * pw
		# a few centimetres of height difference keep the plank ends ragged
		var ph := h - 0.04 - 0.05 * float(i % 3)
		kit.box(Vector3(x, top + ph * 0.5, face + 0.03), Vector3(pw - 0.035, ph, 0.06), 0.0, "door", false)
	kit.box(Vector3(0, top + h * 0.5, face + 0.08), Vector3(0.2, h - 0.1, 0.05), 0.0, "door", false)
	for sx: float in [-1.0, 1.0]:
		for y: float in [1.0, 3.7, 6.0]:
			var cx := sx * w * 0.25
			kit.box(Vector3(cx, top + y, face + 0.075), Vector3(w * 0.5 - 0.35, 0.17, 0.035), 0.0, "iron", false)
			# the hinge's flared end at the leaf's outer edge
			kit.box(Vector3(sx * (w * 0.5 - 0.3), top + y, face + 0.08), Vector3(0.34, 0.36, 0.04), 0.0, "iron", false)
			var n := 6
			for k in n:
				var x := cx - (w * 0.5 - 0.7) * 0.5 + k * (w * 0.5 - 0.7) / (n - 1)
				kit.box(Vector3(x, top + y, face + 0.1), Vector3(0.07, 0.07, 0.04), 0.0, "iron", false)
		# ring pull: a boss and a ring of short bars
		var at := Vector3(sx * 0.42, top + 2.9, face + 0.1)
		kit.box(at, Vector3(0.16, 0.16, 0.05), 0.0, "iron", false)
		var ring_c := at + Vector3(0, -0.2, 0.03)
		var segs := 10
		for k in segs:
			var a0 := TAU * k / segs
			var a1 := TAU * (k + 1) / segs
			var p0 := ring_c + Vector3(cos(a0), sin(a0), 0) * 0.15
			var p1 := ring_c + Vector3(cos(a1), sin(a1), 0) * 0.15
			var y_axis := (p1 - p0).normalized()
			kit.obox((p0 + p1) * 0.5, Vector3(0.035, p0.distance_to(p1) + 0.01, 0.035),
				Basis(y_axis.cross(Vector3.BACK).normalized(), y_axis, Vector3.BACK), "iron")


## The porch head: a two-centred pointed arch springing ARCH_SPRING over the
## threshold up to the door's top, carried on a jamb shaft each side; its
## spandrels and a course over its apex fill the porch to the lintel, from the
## door's face to the piers' front, and a soffit of voussoirs runs under
## them. All of it is over head height or in the piers' corners.
const ARCH_SPRING := 6.2
static func _porch_arch(kit: ArchKit, top: float, w: float, h: float, face: float, front: float) -> void:
	var a := w * 0.5
	var ys := top + ARCH_SPRING
	var rise := h - ARCH_SPRING
	var radius := (a * a + rise * rise) / (2.0 * a)
	var depth := front - face
	var zc := (face + front) * 0.5
	var lintel_bottom := top + h + 1.0
	# spandrels: thin courses from the arch's edge out to the piers
	var courses := 14
	for k in courses:
		var y0 := ys + rise * k / courses
		var y1 := ys + rise * (k + 1) / courses
		var x0 := _arch_edge(y1 - ys, a, radius, rise)
		for sx: float in [-1.0, 1.0]:
			kit.box(Vector3(sx * (x0 + a) * 0.5, (y0 + y1) * 0.5, zc), Vector3(a - x0 + 0.02, y1 - y0 + 0.01, depth), 0.0, "trim", false)
	# the course over the apex, up to the lintel
	kit.box(Vector3(0, (top + h + lintel_bottom) * 0.5, zc), Vector3(w + 0.02, lintel_bottom - top - h + 0.02, depth), 0.0, "trim", false)
	# the soffit and two orders of voussoirs along both arcs
	var segs := 9
	for sx: float in [-1.0, 1.0]:
		for k in segs:
			var y0 := ys + rise * k / segs
			var y1 := ys + rise * (k + 1) / segs
			var p0 := Vector3(sx * _arch_edge(y0 - ys, a, radius, rise), y0, 0.0)
			var p1 := Vector3(sx * _arch_edge(y1 - ys, a, radius, rise), y1, 0.0)
			var y_axis := (p1 - p0).normalized()
			var x_axis := y_axis.cross(Vector3.BACK).normalized()
			# away from the opening (out of the arch's curve)
			var out := x_axis if x_axis.dot(Vector3(sx, 0.4, 0)) > 0.0 else -x_axis
			var basis := Basis(x_axis, y_axis, Vector3.BACK)
			var mid := (p0 + p1) * 0.5
			var length := p0.distance_to(p1) + 0.06
			# soffit: covers the courses' steps, the full depth of the porch
			kit.obox(mid + out * 0.1 + Vector3(0, 0, zc), Vector3(0.24, length, depth - 0.02), basis, "trim")
			# outer order: a moulded ring standing proud of the piers' front
			kit.obox(mid + out * 0.32 + Vector3(0, 0, front + 0.08), Vector3(0.42, length, 0.16), basis, "trim")
			# inner order, a step back toward the door
			kit.obox(mid + out * 0.06 + Vector3(0, 0, face + 0.45), Vector3(0.2, length, 0.3), basis, "trim")
	# jamb shafts with a base and a capital, in the piers' inner corners
	for sx: float in [-1.0, 1.0]:
		var x := sx * (a - 0.15)
		var z := front - 0.35
		kit.box(Vector3(x, top + 0.2, z), Vector3(0.42, 0.4, 0.42), 0.0, "trim", false)
		kit.cylinder(Vector3(x, top + 0.4, z), 0.15, ARCH_SPRING - 0.75, "trim", 10, false)
		kit.box(Vector3(x, ys - 0.2, z), Vector3(0.5, 0.4, 0.5), 0.0, "trim", false)


## |x| of a two-centred arch's edge `dy` over its spring: `a` (half span) at
## the spring, 0 at the apex `rise` higher.
static func _arch_edge(dy: float, a: float, radius: float, rise: float) -> float:
	var d := clampf(dy, 0.0, rise)
	return a - radius + sqrt(maxf(radius * radius - d * d, 0.0))


## Paving over `area` (world x, z): flags following the higher of the ground
## and the apron's top (`top`) two centimetres over it, a kerb round the open
## edges.
static func _apron_paving(kit: ArchKit, top: float, area: Rect2) -> void:
	var step := 0.5
	var kerb := 0.4
	var nx := ceili(area.size.x / step)
	var nz := ceili(area.size.y / step)
	for i in nx:
		for j in nz:
			var x0 := area.position.x + i * area.size.x / nx
			var x1 := area.position.x + (i + 1) * area.size.x / nx
			var z0 := area.position.y + j * area.size.y / nz
			var z1 := area.position.y + (j + 1) * area.size.y / nz
			var cx := (x0 + x1) * 0.5
			var cz := (z0 + z1) * 0.5
			var edge := minf(minf(cx - area.position.x, area.end.x - cx), area.end.y - cz) < kerb
			var a := _paved(x0, z0, top)
			var b := _paved(x1, z0, top)
			var c := _paved(x1, z1, top)
			var d := _paved(x0, z1, top)
			kit.quad("kerb" if edge else "paving", a, b, c, d, (a + c) * 0.5 + Vector3.DOWN)


static func _paved(x: float, z: float, top: float) -> Vector3:
	var g := Layout.height_at(x, z)
	return Vector3(x, maxf(top, g if not is_nan(g) else top) + 0.02, z)


static func _lights(node: Node3D, top: float) -> void:
	for sx in [-1, 1]:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.72, 0.42)
		l.light_energy = 1.6
		l.omni_range = 12.0
		l.position = Vector3(sx * 4.4, top + 6.5, DOOR_CENTER.z + 3.4)
		l.add_to_group("grounds_torch_lights")
		node.add_child(l)
