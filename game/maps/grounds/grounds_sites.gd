extends RefCounted

## Buildings and set dressing at the grounds' landmarks: Orvell (its square
## built from VillageKit's kit buildings), Ombrek's hut, the greenhouses, the
## boathouse and its stair, the station, the skyring pitch, the highland stone
## circle, the smugglers' camp, the ruined crypt and the spider hollow.
##
## Positions come from GroundsLayout (the same layout.json the old world's
## terrain was built from, and the server's pack compiled from that world).
## Each site is one ArchKit batch: a few draw calls. Every footing is founded
## down to the lowest ground under it.

const Layout := preload("res://maps/grounds/grounds_layout.gd")
const PBR := preload("res://maps/grounds/grounds_pbr.gd")
const ArchKit := preload("res://maps/grounds/arch_kit.gd")
const Mats := preload("res://maps/grounds/grounds_mats.gd")
const VillageKit := preload("res://maps/grounds/village_kit.gd")
const Scatter := preload("res://maps/grounds/grounds_scatter.gd")
const PumpkinMesh := preload("res://maps/grounds/pumpkin_mesh.gd")
## The ground's render layer bit (GroundsTerrain.RENDER_BIT): the pitch's
## chalk decal paints only the ground.
const GROUND_RENDER_BIT := 1 << 17


static func build_all(parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "Sites"
	parent.add_child(root)
	_orvell(root)
	_borin(root)
	_greenhouses(root)
	_boathouse(root)
	_station(root)
	_skyring(root)
	_stone_circle(root)
	_smugglers_camp(root)
	_crypt(root)
	_spider_hollow(root)
	# Village and site meshes end at the preset's site range (QualityPreset.apply):
	# a signal pillar 900 m off is a few pixels and still a draw call.
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		node.add_to_group("grounds_site_geometry")


# --------------------------------------------------------------- buildings

## An Orvell cottage: stone ground floor, plastered timber-framed upper floor,
## steep slate roof, chimney, lit windows, a door on the street side (+z local).
static func cottage(kit: ArchKit, c: Vector2, rot: float, w: float, d: float, floors: int, roof_key: String = "roof", tall: bool = false) -> Vector3:
	var span := Layout.ground_span(c, Vector2(w + 1, d + 1), rot)
	var floor_y := span.y + 0.1
	var basis := Basis(Vector3.UP, rot)
	var at := func(x: float, y: float, z: float) -> Vector3:
		return Vector3(c.x, 0, c.y) + basis * Vector3(x, 0, z) + Vector3.UP * y
	var storey := 3.3
	var base := span.x - 1.0
	# plinth/ground floor in stone, founded into the slope
	kit.box(at.call(0, (base + floor_y + storey) * 0.5, 0), Vector3(w, floor_y + storey - base, d), rot, "stone")
	var y := floor_y + storey
	for f in floors - 1:
		kit.box(at.call(0, y + storey * 0.5, 0), Vector3(w + 0.5, storey, d + 0.5), rot, "plaster")
		# timber frame: posts and a rail
		for i in 5:
			var x := -w * 0.5 - 0.25 + i * (w + 0.5) / 4.0
			kit.box(at.call(x, y + storey * 0.5, d * 0.5 + 0.28), Vector3(0.22, storey, 0.1), rot, "timber", false)
			kit.box(at.call(x, y + storey * 0.5, -d * 0.5 - 0.28), Vector3(0.22, storey, 0.1), rot, "timber", false)
		kit.box(at.call(0, y + 0.1, d * 0.5 + 0.3), Vector3(w + 0.6, 0.25, 0.12), rot, "timber", false)
		kit.box(at.call(0, y + 0.1, -d * 0.5 - 0.3), Vector3(w + 0.6, 0.25, 0.12), rot, "timber", false)
		y += storey
	var roof_h := (d * 0.85) if not tall else d * 1.15
	kit.gable(at.call(0, y, 0), Vector2(w + 0.6, d + 0.6), roof_h, rot, roof_key, "plaster" if floors > 1 else "stone", 0.9)
	# chimney
	kit.box(at.call(w * 0.32, y + roof_h * 0.7, -d * 0.18), Vector3(0.9, roof_h * 1.1, 0.9), rot, "stone")
	# door and windows on the street face, windows at the back and the ends
	kit.box(at.call(0, floor_y + 1.15, d * 0.5 + 0.06), Vector3(1.3, 2.3, 0.15), rot, "wood", false)
	kit.box(at.call(0, floor_y + 2.45, d * 0.5 + 0.1), Vector3(1.7, 0.25, 0.25), rot, "timber", false)
	var n_front := basis * Vector3(0, 0, 1)
	var n_back := basis * Vector3(0, 0, -1)
	for f in floors:
		var wy := floor_y + 1.7 + f * storey
		for sx in [-1, 1]:
			var x: float = sx * w * 0.3
			if f == 0 and absf(x) < 1.2:
				continue
			kit.window(at.call(x, wy, d * 0.5 + (0.25 if f > 0 else 0.0)), n_front, 0.9, 1.2, "timber", "glass")
			kit.window(at.call(x, wy, -d * 0.5 - (0.25 if f > 0 else 0.0)), n_back, 0.9, 1.2, "timber", "glass")
	# doorstep
	kit.box(at.call(0, floor_y - 0.12, d * 0.5 + 0.7), Vector3(1.8, 0.3, 1.0), rot, "stone")
	return at.call(0, floor_y, d * 0.5 + 1.5)


# ----------------------------------------------------------------- Orvell

static func _orvell(parent: Node3D) -> void:
	var sq := Layout.landmark("orvell_square")
	if sq == Vector3.INF:
		return
	var kit := ArchKit.new()
	var centre := Vector2(sq.x, sq.z)
	var placed: Array[Rect2] = []
	# Kit buildings (VillageKit) shoulder to shoulder round the square, every
	# door to it: the inn on the north side and Kestrin's smithy on the west
	# fixed, shops and houses clockwise between, narrow alleys, gaps where the
	# roads come in. Then houses with fenced front gardens along the roads out.
	var buildings: Array = []
	var arcs: Array = []   # [from, to] angles the fixed buildings hold
	for fixed in [["inn", -PI * 0.5], ["smithy", SMITHY_ANGLE]]:
		var sz := VillageKit.size(fixed[0])
		var dir := Vector2(cos(fixed[1]), sin(fixed[1]))
		var p: Vector2 = centre + dir * (SQUARE_FRONT + sz.y * 0.5)
		buildings.append(VillageKit.found(kit, fixed[0], p, atan2(-dir.x, -dir.y)))
		var reach := maxf(sz.x, sz.y) * 0.5 + 1.0
		placed.append(Rect2(p - Vector2(reach, reach), Vector2(reach, reach) * 2.0))
		var half := (sz.x * 0.5 + ALLEY) / SQUARE_FRONT
		arcs.append([fixed[1] - half, fixed[1] + half])
	var inn_half: float = arcs[0][1] - (-PI * 0.5)
	var theta := -PI * 0.5 + inn_half
	var stop := -PI * 0.5 + TAU - inn_half
	var smithy_arc: Array = arcs[1]
	if smithy_arc[0] < theta:
		smithy_arc = [smithy_arc[0] + TAU, smithy_arc[1] + TAU]
	var built := 0
	while built < 64:
		var id: String = RING[built % RING.size()]
		var sz := VillageKit.size(id)
		var at := theta + (sz.x * 0.5) / SQUARE_FRONT
		var end := at + (sz.x * 0.5) / SQUARE_FRONT
		if end > stop:
			break
		if end > smithy_arc[0] and theta < smithy_arc[1]:
			theta = smithy_arc[1]   # the smithy's stretch of the ring
			continue
		var dir := Vector2(cos(at), sin(at))
		var p := centre + dir * (SQUARE_FRONT + sz.y * 0.5)
		if _try_building(kit, id, p, -dir, placed, buildings):
			theta = at + (sz.x * 0.5 + ALLEY) / SQUARE_FRONT
			built += 1
		else:
			theta += 3.0 / SQUARE_FRONT   # a road: step past it with the same building
	var fences: Array = []
	var gardens: Array = []
	_road_houses(kit, centre, placed, buildings, fences, gardens)
	# square: a well and four lamp posts
	kit.cylinder(sq + Vector3(0, -0.5, 0), 1.6, 1.4, "stone", 14)
	kit.cylinder(sq + Vector3(0, 0.9, 0), 1.35, 0.1, "dark", 14, false)
	for sx in [-1, 1]:
		kit.box(sq + Vector3(sx * 1.2, 1.9, 0), Vector3(0.18, 2.2, 0.18), 0.0, "timber", false)
	kit.gable(sq + Vector3(0, 2.9, 0), Vector2(3.0, 2.4), 0.9, 0.0, "roof", "timber", 0.2)
	var root := kit.finish(parent, Mats.materials(), "OrvellVillage")
	VillageKit.place(root, buildings, Mats.materials())
	VillageKit.place_fences(root, fences, Mats.materials())
	_gardens(root, _clear_gardens(gardens, buildings))
	for i in 4:
		var a := TAU * (i + 0.5) / 4.0
		_lamp_post(root, Layout.ground(sq.x + cos(a) * 26.0, sq.z + sin(a) * 26.0))
	var inn: Vector2 = centre + Vector2(0, -SQUARE_FRONT)
	Mats.lamp_light(root, Vector3(inn.x, sq.y + 3.0, inn.y + 3.0), 1.6, 12.0)


## The square's ring of kit buildings, clockwise from the inn's east.
const RING := ["shop_bakery", "house_tall", "shop_tailor", "house_gable", "house_tower", "shop_wide", "cottage",
	"house_sample", "storybook", "shop_tailor", "house_tall", "shop_bakery", "house_gable", "house_sample",
	"house_tower", "shop_wide", "storybook", "cottage"]
## Radius of the square's building fronts (its paving ends at 32 m) and the
## alley left between two buildings.
const SQUARE_FRONT := 35.0
const ALLEY := 1.5
## Kestrin's smithy: the west side of the square, a little north of west
## (where his old open forge stood).
const SMITHY_ANGLE := -2.891
## Houses along the roads out of the square: mostly homes, now and then a shop.
const ROAD_TYPES := ["house_sample", "cottage", "house_wood", "house_gable", "cottage_long", "storybook",
	"house_tall", "cottage", "house_tower", "house_sample", "shop_bakery", "cottage_long", "house_wood",
	"house_gable", "cottage", "storybook", "shop_tailor", "house_sample"]
const ROADS := ["castle_east", "orvell_station", "highlands_path"]
## Front garden: grass verge from the road edge to the fence, then the yard.
const VERGE := 1.0
const YARD := 3.5
## How far a garden bush / flower keeps from its house and the crates before
## its door (m: the bush's spread, a flower's leaves).
const BUSH_CLEAR := 1.0
const FLOWER_CLEAR := 0.6


## Kestrin's smithy: its centre (x, z) and turn, door to the square.
static func smithy_site() -> Array:
	var sq := Layout.landmark("orvell_square")
	var dir := Vector2(cos(SMITHY_ANGLE), sin(SMITHY_ANGLE))
	var c := Vector2(sq.x, sq.z) + dir * (SQUARE_FRONT + VillageKit.size("smithy").y * 0.5)
	return [c, atan2(-dir.x, -dir.y)]


## Houses with fenced front gardens along both sides of the roads leaving the
## square, between the square's ring and 160 m out; a garden gap of 3-7 m
## between neighbours. Fills `fences` with the fence pieces' transforms (their
## colliders go into kit) and `gardens` with bush and flower spots.
static func _road_houses(kit: ArchKit, centre: Vector2, placed: Array[Rect2], out: Array, fences: Array, gardens: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6870
	var lamps := Scatter.instances("lamp")
	var pick := 0
	for road_id in ROADS:
		var r := Layout.road(road_id)
		if r.is_empty():
			continue
		var half := float(r["width"]) * 0.5
		var pts: Array = r["points"]
		for k in pts.size() - 1:
			var a := Vector2(pts[k][0], pts[k][1])
			var b := Vector2(pts[k + 1][0], pts[k + 1][1])
			var length := a.distance_to(b)
			var dir := (b - a) / length
			var nrm := Vector2(-dir.y, dir.x)
			for side in [-1.0, 1.0]:
				var s := 2.0
				while s < length - 4.0:
					var id: String = ROAD_TYPES[pick % ROAD_TYPES.size()]
					var sz := VillageKit.size(id)
					var mid := a + dir * (s + sz.x * 0.5)
					var dist := mid.distance_to(centre)
					if dist < SQUARE_FRONT + 14.0 or dist > 160.0 or s + sz.x > length:
						s += 4.0
						continue
					var p: Vector2 = mid + nrm * side * (half + VERGE + YARD + sz.y * 0.5)
					if not _try_building(kit, id, p, -nrm * side, placed, out, true):
						s += 3.0
						continue
					pick += 1
					var gap := rng.randf_range(3.0, 7.0)
					# the fence along the garden front, a gate gap before the door
					var fence_line := half + VERGE
					var from := s - gap * 0.5
					var to := s + sz.x + gap * 0.5
					var x := from
					while x + 2.06 <= to:
						var c := x + 1.03
						if absf(c - (s + sz.x * 0.5)) > 1.6:
							var at: Vector2 = a + dir * c + nrm * side * fence_line
							if _clear_of(lamps, at, 1.2) and Layout.road_distance(at) > 0.6:
								fences.append(VillageKit.found_fence(at, atan2(-dir.y, dir.x)))
						x += 2.06
					# a bush or two and a flower bed in the yard (_clear_gardens
					# keeps them off every building and its crates)
					for j in rng.randi_range(1, 2):
						var along := s + rng.randf_range(0.6, sz.x - 0.6)
						if absf(along - (s + sz.x * 0.5)) < 1.4:
							continue
						gardens.append(["bush", a + dir * along + nrm * side * (fence_line + rng.randf_range(1.2, YARD - 0.8)), rng.randf() * TAU, rng.randf_range(2.2, 3.0)])
					for j in 6:
						var along := s + rng.randf_range(0.4, sz.x - 0.4)
						if absf(along - (s + sz.x * 0.5)) < 1.2:
							continue
						gardens.append(["flower", a + dir * along + nrm * side * (fence_line + 0.5), rng.randf() * TAU, rng.randf_range(0.9, 1.3)])
					s += sz.x + gap


## The garden spots clear of every building and the crates before its door
## (VillageKit.covers): a yard's bush grew out of the next house's crates or
## plinth (2026-11-16, placement_check.gd). Filtered after all the draws, so
## everything else stays where it was.
static func _clear_gardens(gardens: Array, buildings: Array) -> Array:
	var out: Array = []
	for g: Array in gardens:
		var margin := BUSH_CLEAR if g[0] == "bush" else FLOWER_CLEAR
		var clear := true
		for b: Array in buildings:
			if not b.is_empty() and VillageKit.covers(b[0], Vector2(b[1].x, b[1].z), b[2], g[1], margin):
				clear = false
				break
		if clear:
			out.append(g)
	return out


static func _clear_of(lamps: PackedFloat32Array, at: Vector2, r: float) -> bool:
	for i in lamps.size() / 5:
		if Vector2(lamps[i * 5], lamps[i * 5 + 2]).distance_to(at) < r:
			return false
	return true


## The gardens' bushes (rooibos) and flowers (gazania, ursinia), the courtyard's plants.
static func _gardens(root: Node3D, spots: Array) -> void:
	var bushes: Array = []
	var flowers: Array = []
	for g in spots:
		var p := Layout.ground(g[1].x, g[1].y)
		(bushes if g[0] == "bush" else flowers).append([p, g[2], g[3]])
	Mats.plant(root, "GardenBush", Mats.plant_meshes("wild_rooibos_bush"), bushes, 180.0)
	var blooms: Array = Mats.plant_meshes("flower_gazania") + Mats.plant_meshes("flower_ursinia")
	Mats.plant(root, "GardenFlowers", blooms, flowers, 70.0)


## Kit building `id` at p, door toward `toward`, unless it would sit on a
## road, straddle a slope or (check_overlap) overlap a placed building
## (VillageKit). Returns whether it was built.
static func _try_building(kit: ArchKit, id: String, p: Vector2, toward: Vector2, placed: Array[Rect2], out: Array,
		check_overlap: bool = false) -> bool:
	var sz := VillageKit.size(id)
	var rot := atan2(toward.x, toward.y)
	var reach := maxf(sz.x, sz.y) * 0.5 + 1.0
	var rect := Rect2(p - Vector2(reach, reach), Vector2(reach, reach) * 2.0)
	if check_overlap:
		for r in placed:
			if r.intersects(rect):
				return false
	# the road may pass any corner of the footprint, not just its middle
	var basis := Basis(Vector3.UP, rot)
	for corner in [Vector3(0, 0, 0), Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1)]:
		var c: Vector3 = basis * (corner * Vector3(sz.x * 0.5, 0, sz.y * 0.5))
		if Layout.road_distance(p + Vector2(c.x, c.z)) < 1.5:
			return false
	var span := Layout.ground_span(p, sz, rot)
	if span.y - span.x > 3.0:
		return false
	placed.append(rect)
	out.append(VillageKit.found(kit, id, p, rot))
	return true


static func _lamp_post(parent: Node3D, at: Vector3) -> void:
	var kit := ArchKit.new()
	kit.box(at + Vector3(0, 1.6, 0), Vector3(0.16, 3.2, 0.16), 0.0, "metal")
	kit.box(at + Vector3(0, 3.35, 0), Vector3(0.5, 0.5, 0.5), 0.0, "glass", false)
	kit.pyramid(at + Vector3(0, 3.6, 0), Vector2(0.6, 0.6), 0.35, 0.0, "metal", 0.05)
	kit.finish(parent, Mats.materials(), "Lamp")
	Mats.lamp_light(parent, at + Vector3(0, 3.3, 0), 1.0, 8.0)


# -------------------------------------------------------------- Ombrek's hut

static func _borin(parent: Node3D) -> void:
	var h := Layout.landmark("borin_hut")
	if h == Vector3.INF:
		return
	var kit := ArchKit.new()
	var span := Layout.ground_span(Vector2(h.x, h.z), Vector2(10, 10))
	var fy := span.y + 0.1
	kit.cylinder(Vector3(h.x, span.x - 1.0, h.z), 4.6, fy + 3.6 - span.x + 1.0, "rubble", 18)
	kit.cone(Vector3(h.x, fy + 3.6, h.z), 4.6, 4.2, "roof_warm", 18, 1.2)
	kit.box(Vector3(h.x + 2.2, fy + 5.0, h.z - 1.5), Vector3(1.0, 4.0, 1.0), 0.0, "rubble")
	kit.box(Vector3(h.x, fy + 1.3, h.z + 4.62), Vector3(1.6, 2.6, 0.3), 0.0, "wood", false)
	kit.window(Vector3(h.x + 3.2, fy + 1.9, h.z + 3.2), Vector3(0.7, 0, 0.7), 0.8, 1.0, "timber", "glass")
	kit.window(Vector3(h.x - 3.2, fy + 1.9, h.z + 3.2), Vector3(-0.7, 0, 0.7), 0.8, 1.0, "timber", "glass")
	# pumpkin patch with a low post-and-rail fence: pumpkins of every size that
	# never overlap, a few giants among them, leaves on the ground between
	var patch := Vector2(h.x + 10.0, h.z + 4.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 280
	var placed: Array = []   # [Vector2 at, float diameter]
	for attempt in 400:
		if placed.size() >= 16:
			break
		var d := rng.randf_range(0.55, 1.0) if placed.size() >= 3 else rng.randf_range(1.25, 1.5)
		var p := patch + Vector2(rng.randf_range(-4.6, 4.6), rng.randf_range(-3.3, 3.3))
		if pow((p.x - patch.x) / 5.0, 2.0) + pow((p.y - patch.y) / 3.7, 2.0) > 1.0:
			continue
		var free := true
		for other in placed:
			if p.distance_to(other[0]) < (d + float(other[1])) * 0.55:
				free = false
				break
		if free:
			placed.append([p, d])
	var pumpkins: Array[Transform3D] = []
	for item in placed:
		var p: Vector2 = item[0]
		var d: float = item[1]
		var g := Layout.ground(p.x, p.y)
		var tilt := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.12))
		var squash := Vector3(d, d * rng.randf_range(0.85, 1.1), d)
		pumpkins.append(Transform3D(tilt * Basis(Vector3.UP, rng.randf() * TAU).scaled(squash), g + Vector3(0, -0.03 * d, 0)))
	var leaves: Array[Transform3D] = []
	for i in 34:
		var p := patch + Vector2(rng.randf_range(-4.7, 4.7), rng.randf_range(-3.4, 3.4))
		if pow((p.x - patch.x) / 5.2, 2.0) + pow((p.y - patch.y) / 3.9, 2.0) > 1.0:
			continue
		var g := Layout.ground(p.x, p.y)
		var tip := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.25))
		leaves.append(Transform3D(tip * Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.8, 1.35)), g + Vector3(0, 0.02, 0)))
	var posts: Array[Vector3] = []
	for i in 14:
		var a := TAU * i / 14.0
		var p := patch + Vector2(cos(a) * 6.0, sin(a) * 4.6)
		var g := Layout.ground(p.x, p.y)
		posts.append(g)
		kit.box(g + Vector3(0, 0.55, 0), Vector3(0.16, 1.1, 0.16), a, "timber", false)
	for i in posts.size():
		var a := posts[i]
		var b := posts[(i + 1) % posts.size()]
		var mid := (a + b) * 0.5
		var run := Vector2(b.x - a.x, b.z - a.z)
		for rail_y in [0.42, 0.86]:
			kit.box(mid + Vector3(0, rail_y, 0), Vector3(run.length() + 0.1, 0.09, 0.07), atan2(-run.y, run.x), "timber", false)
	var root := kit.finish(parent, Mats.materials(), "BorinsHut")
	Mats.lamp_light(root, Vector3(h.x, fy + 2.4, h.z + 5.5), 1.2, 9.0)
	_pumpkin_patch(root, pumpkins, leaves, rng)


## The pumpkins and their leaves as two MultiMeshes of the Blender-baked
## PumpkinMesh, each a shade apart (instance colour multiplies the skin).
static func _pumpkin_patch(parent: Node3D, xforms: Array[Transform3D], leaves: Array[Transform3D], rng: RandomNumberGenerator) -> void:
	for layer in [["Pumpkins", PumpkinMesh.mesh(), xforms], ["PumpkinLeaves", PumpkinMesh.leaf_mesh(), leaves]]:
		if layer[1] == null:
			continue
		var list: Array[Transform3D] = layer[2]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = layer[1]
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
			var v := rng.randf_range(0.88, 1.1)
			mm.set_instance_color(i, Color(v, v * rng.randf_range(0.94, 1.04), v * rng.randf_range(0.9, 1.0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = String(layer[0])
		mmi.multimesh = mm
		parent.add_child(mmi)


# ------------------------------------------------------------- greenhouses

static func _greenhouses(parent: Node3D) -> void:
	var g := Layout.landmark("greenhouses")
	if g == Vector3.INF:
		return
	# Founded on a stone plinth that follows the ground; the greenhouse itself
	# is the Blender model (art/greenhouse/greenhouse_work.blend). Its glass
	# shell's plain box collider is the server's.
	var kit := ArchKit.new()
	var tops: Array[Vector3] = []
	for i in 3:
		var c := Vector2(g.x - 14.0 + i * 14.0, g.z)
		var span := Layout.ground_span(c, Vector2(9, 18))
		var fy := span.y + 0.05
		kit.box(Vector3(c.x, (span.x - 1.0 + fy + 0.6) * 0.5, c.y), Vector3(9.4, fy + 0.6 - span.x + 1.0, 18.4), 0.0, "stone")
		tops.append(Vector3(c.x, fy + 0.6, c.y))
	var root := kit.finish(parent, Mats.materials(), "Greenhouses")
	if not ResourceLoader.exists(GREENHOUSE):
		return
	for at in tops:
		var house: Node3D = (load(GREENHOUSE) as PackedScene).instantiate()
		house.name = "Greenhouse"
		root.add_child(house)
		house.global_position = at
		_greenhouse_materials(house)


const GREENHOUSE := "res://assets/models/grounds/greenhouse.glb"

## The model's slots (GH_*) painted with the site's own PBR stone and wood,
## dark green painted iron, clear sky-tinted glass, terracotta and leaves.
static func _greenhouse_materials(house: Node3D) -> void:
	var mats := Mats.materials()
	if not mats.has("gh_frame"):
		var frame := StandardMaterial3D.new()
		frame.albedo_color = Color(0.09, 0.2, 0.14)
		frame.metallic = 0.55
		frame.roughness = 0.42
		var glass := StandardMaterial3D.new()
		glass.albedo_color = Color(0.78, 0.9, 0.86, 0.16)
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.roughness = 0.04
		glass.metallic = 0.2
		glass.metallic_specular = 1.0
		glass.rim_enabled = true
		glass.rim = 0.6
		glass.rim_tint = 0.8
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		var pot := StandardMaterial3D.new()
		pot.albedo_color = Color(0.62, 0.3, 0.16)
		pot.roughness = 0.85
		var leaf := StandardMaterial3D.new()
		leaf.albedo_color = Color(0.16, 0.38, 0.12)
		leaf.roughness = 0.6
		leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
		Mats.put("gh_frame", frame)
		Mats.put("gh_glass", glass)
		Mats.put("gh_pot", pot)
		Mats.put("gh_leaf", leaf)
	var by_name := {"GH_Stone": mats["stone"], "GH_Frame": mats["gh_frame"], "GH_Glass": mats["gh_glass"],
		"GH_Wood": mats["wood"], "GH_Floor": mats["cobble"], "GH_Pot": mats["gh_pot"], "GH_Leaf": mats["gh_leaf"]}
	for node in house.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if m != null and by_name.has(m.resource_name):
				mi.set_surface_override_material(i, by_name[m.resource_name])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


# -------------------------------------------------- boathouse and lake stair

static func _boathouse(parent: Node3D) -> void:
	var b := Layout.landmark("boathouse")
	if b == Vector3.INF:
		return
	var kit := ArchKit.new()
	# boathouse on the shore, its open end towards the lake (south)
	var c := Vector2(b.x, b.z + 4.0)
	var span := Layout.ground_span(c, Vector2(8, 10))
	var fy := maxf(span.y, 0.6) + 0.1
	for sx in [-1, 1]:
		kit.box(Vector3(c.x + sx * 3.8, (span.x - 1.0 + fy + 3.4) * 0.5, c.y), Vector3(0.5, fy + 3.4 - span.x + 1.0, 10.0), 0.0, "rubble")
	kit.box(Vector3(c.x, (span.x - 1.0 + fy + 3.4) * 0.5, c.y - 5.0), Vector3(8.1, fy + 3.4 - span.x + 1.0, 0.5), 0.0, "rubble")
	kit.gable(Vector3(c.x, fy + 3.4, c.y), Vector2(10.6, 8.6), 3.0, PI * 0.5, "roof", "wood", 0.5)
	# jetty out over the water
	for k in 10:
		var z := c.y + 6.0 + k * 2.0
		kit.box(Vector3(c.x, 0.55, z), Vector3(3.0, 0.2, 2.0), 0.0, "wood")
		for sx in [-1, 1]:
			kit.box(Vector3(c.x + sx * 1.4, -2.0, z), Vector3(0.25, 5.0, 0.25), 0.0, "timber", false)
	# the stair down the cliff from the castle side
	var stair := Layout.road("boathouse_stairs")
	if not stair.is_empty():
		_stair(kit, stair["points"], float(stair.get("width", 3.0)))
	var mats := Mats.materials().duplicate()
	mats.merge(_stair_materials())
	var root := kit.finish(parent, mats, "Boathouse")
	Mats.lamp_light(root, Vector3(c.x, fy + 2.6, c.y + 5.2), 1.0, 8.0)


## Treads along a polyline that follow the ground downhill: every tread is a
## solid block from its top down to the ground, rises are at most 0.3 m (under
## the player's 0.45 m step-up), so the whole flight is walkable both ways.
## The blocks are the server's (the pack was compiled from this same layout);
## each is drawn as a body of big weathered ashlar under a paler tread slab
## STAIR_CAP thick, the slab overhanging the step below by STAIR_NOSE and the
## flanks by STAIR_LIP: the nosings' shadow lines and the light treads over
## the darker risers read as steps from the shore, not as one slab.
## Where the flight stands high over the cliff its flanks are buttressed every
## STAIR_PIER_EVERY treads: piers STAIR_PIER_OUT proud of the flank, under the
## tread level (outside the walked space).
const STAIR_CAP := 0.12
const STAIR_NOSE := 0.06
const STAIR_LIP := 0.06
const STAIR_PIER_EVERY := 14
const STAIR_PIER_OUT := 0.45
const STAIR_PIER_MIN := 2.5
static func _stair(kit: ArchKit, pts: Array, width: float) -> void:
	var samples: Array = []
	for i in pts.size() - 1:
		var a := Vector2(pts[i][0], pts[i][1])
		var b := Vector2(pts[i + 1][0], pts[i + 1][1])
		var n := maxi(1, int(a.distance_to(b) / 0.5))
		for k in n:
			samples.append(a.lerp(b, float(k) / n))
	samples.append(Vector2(pts[-1][0], pts[-1][1]))
	# the treads first (top, ground, ends), then their drawing: a nosing needs
	# its neighbours' heights
	var treads: Array = []
	var prev_top := INF
	for i in samples.size() - 1:
		var p: Vector2 = samples[i]
		var q: Vector2 = samples[i + 1]
		var g := Layout.height_at(p.x, p.y)
		if is_nan(g):
			continue
		var top := g + 0.15
		if prev_top != INF and prev_top - top > 0.3:
			top = prev_top - 0.3
		prev_top = top
		treads.append([p, q, top, g - 1.2])
	for i in treads.size():
		var p: Vector2 = treads[i][0]
		var q: Vector2 = treads[i][1]
		var top: float = treads[i][2]
		var bottom: float = treads[i][3]
		var mid := (p + q) * 0.5
		var rot := atan2(-(q - p).y, (q - p).x)
		var along := Vector3((q - p).x, 0.0, (q - p).y).normalized()
		var length := p.distance_to(q) + 0.02
		kit.box(Vector3(mid.x, (top - STAIR_CAP + bottom) * 0.5, mid.y), Vector3(length, top - STAIR_CAP - bottom, width), rot, "ashlar")
		# the tread slab, nosed over whichever neighbour stands lower
		var ahead := i + 1 < treads.size() and float(treads[i + 1][2]) < top - 0.02
		var behind := i > 0 and float(treads[i - 1][2]) < top - 0.02
		var nose_a := STAIR_NOSE if ahead else 0.0
		var nose_b := STAIR_NOSE if behind else 0.0
		var cap_at := Vector3(mid.x, top - STAIR_CAP * 0.5, mid.y) + along * (nose_a - nose_b) * 0.5
		kit.box(cap_at, Vector3(length + nose_a + nose_b, STAIR_CAP, width + STAIR_LIP * 2.0), rot, "tread")
		# a buttress pier on each flank where the flight stands high
		var pier_top := top - STAIR_CAP - 0.2
		if i % STAIR_PIER_EVERY == STAIR_PIER_EVERY / 2 and pier_top - bottom > STAIR_PIER_MIN:
			var across := Vector3(-along.z, 0.0, along.x)
			for sx: float in [-1.0, 1.0]:
				var at := Vector3(mid.x, (pier_top + bottom) * 0.5, mid.y) + across * sx * (width * 0.5 + STAIR_PIER_OUT * 0.5)
				kit.box(at, Vector3(1.2, pier_top - bottom, STAIR_PIER_OUT + 0.02), rot, "ashlar")
				# a weathered cap over the pier's head
				kit.box(at + Vector3.UP * ((pier_top - bottom) * 0.5 + 0.06) + across * sx * 0.02, Vector3(1.35, 0.12, STAIR_PIER_OUT + 0.1), rot, "tread")


## The lake stair's own surfaces (merged over the shared set for the boathouse
## batch): the treads' pale sandstone and the flanks' big ashlar.
static func _stair_materials() -> Dictionary:
	return {
		"tread": PBR.surface("medieval_blocks_03", Color(0.9, 0.88, 0.84), {"metres": 2.0}),
		"ashlar": PBR.surface("large_sandstone_blocks_01", Color(0.7, 0.68, 0.64), {"metres": 4.5}),
	}


# ------------------------------------------------------------------ landing

static func _station(parent: Node3D) -> void:
	var s := Layout.landmark("station")
	if s == Vector3.INF:
		return
	var kit := ArchKit.new()
	var fy := s.y + 0.9
	kit.box(Vector3(s.x, fy - 1.5, s.z), Vector3(6.0, 3.0, 70.0), 0.0, "stone")
	kit.box(Vector3(s.x - 0.0, fy + 0.02, s.z), Vector3(5.6, 0.06, 69.6), 0.0, "cobble", false)
	cottage(kit, Vector2(s.x - 7.5, s.z), PI * 0.5, 14.0, 7.0, 1, "roof")
	for k in 3:
		kit.box(Vector3(s.x + 2.2, fy + 1.6, s.z - 20.0 + k * 20.0), Vector3(0.25, 3.2, 0.25), 0.0, "metal")
	kit.box(Vector3(s.x + 1.0, fy + 3.3, s.z), Vector3(3.4, 0.2, 46.0), 0.0, "roof")
	var root := kit.finish(parent, Mats.materials(), "OrvellStation")
	for k in 3:
		Mats.lamp_light(root, Vector3(s.x + 1.0, fy + 3.0, s.z - 20.0 + k * 20.0), 0.9, 9.0)


# ---------------------------------------------------------- patrol field

## The Sky Patrol's mustering field: an oval (PITCH_SHORT x PITCH_LONG
## half-axes) ringed by ten stepped stone terraces with an arcaded back wall
## hung with banners in the four Watches' colours, and three signal pillars
## at each end.
const PITCH_LONG := 70.0
const PITCH_SHORT := 30.0
## Terraces: their depth, rows and the gap between the field and the first row.
const TERRACE_DEPTH := 12.0
const TERRACE_ROWS := 10
const TERRACE_GAP := 6.0
const PITCH_CLOTHS := ["cloth_red", "cloth_yellow", "cloth_blue", "cloth_green"]


static func _skyring(parent: Node3D) -> void:
	var q := Layout.landmark("skyring")
	if q == Vector3.INF:
		return
	var kit := ArchKit.new()
	_pitch_hoops(kit, q)
	_pitch_terraces(kit, q)
	var root := kit.finish(parent, Mats.materials(), "SkyringPitch")


## The point on the field's oval at angle a, pushed `out` metres beyond it.
static func _pitch_oval(q: Vector3, a: float, out: float) -> Vector2:
	return Vector2(q.x + cos(a) * (PITCH_SHORT + out), q.z + sin(a) * (PITCH_LONG + out))


## Three carved signal pillars per end (14 / 17 / 14 m), capped in gilt.
static func _pitch_hoops(kit: ArchKit, q: Vector3) -> void:
	for end in [-1, 1]:
		for k in 3:
			var x: float = q.x + (k - 1) * 9.0
			var z: float = q.z + end * PITCH_LONG
			var g := Layout.ground(x, z)
			var hgt: float = [14.0, 17.0, 14.0][k]
			kit.box(g + Vector3(0, 0.4, 0), Vector3(2.4, 1.4, 2.4), 0.0, "trim")
			kit.cylinder(g + Vector3(0, 1.1, 0), 0.75, hgt - 2.0, "stone", 12, true, 0.5)
			kit.cylinder(g + Vector3(0, hgt - 1.0, 0), 0.7, 0.6, "trim", 12, false)
			kit.cylinder(g + Vector3(0, hgt - 0.4, 0), 1.05, 0.35, "gold", 12, false)


## Stone terraces all round the oval in straight segments tangent to it, each
## founded on the lowest ground under it, an arcaded back wall behind, a banner
## in every fifth bay.
static func _pitch_terraces(kit: ArchKit, q: Vector3) -> void:
	var n := 40
	for i in n:
		var p0 := _pitch_oval(q, TAU * i / n, TERRACE_GAP)
		var p1 := _pitch_oval(q, TAU * (i + 1) / n, TERRACE_GAP)
		var mid := (p0 + p1) * 0.5
		var along := p1 - p0
		var length := along.length() + 0.4
		var outward := Vector2(along.y, -along.x).normalized()
		if outward.dot(mid - Vector2(q.x, q.z)) < 0:
			outward = -outward
		var rot := atan2(-along.y, along.x)
		var span := Layout.ground_span(mid + outward * TERRACE_DEPTH * 0.5, Vector2(length, TERRACE_DEPTH), rot)
		var floor_y := span.y + 0.1
		var depth := TERRACE_DEPTH / TERRACE_ROWS
		for k in TERRACE_ROWS:
			var c2 := mid + outward * (depth * (k + 0.5))
			var hgt := 0.5 + k * 0.55
			kit.box(Vector3(c2.x, (span.x - 0.5 + floor_y + hgt) * 0.5, c2.y), Vector3(length, floor_y + hgt - span.x + 0.5, depth), rot, "stone")
		var back := mid + outward * (TERRACE_DEPTH + 0.3)
		var wall_top := floor_y + 0.5 + TERRACE_ROWS * 0.55 + 2.0
		kit.box(Vector3(back.x, (span.x - 0.5 + wall_top) * 0.5, back.y), Vector3(length, wall_top - span.x + 0.5, 0.6), rot, "stone")
		var n3 := Vector3(outward.x, 0, outward.y)
		kit.window(Vector3(back.x, wall_top - 2.6, back.y) - n3 * 0.32, -n3, 1.6, 2.4, "trim", "dark")
		kit.box(Vector3(back.x, wall_top + 0.5, back.y), Vector3(length, 1.0, 1.0), rot, "trim")
		if i % 5 == 0:
			var size := Vector3(1.4, 3.4, 0.05) if absf(n3.z) > absf(n3.x) else Vector3(0.05, 3.4, 1.4)
			kit.box(Vector3(back.x, wall_top - 2.0, back.y) - n3 * 0.36, size, 0.0, PITCH_CLOTHS[(i / 5) % 4], false)


## Chalk lines (the oval, the centre circle and line, the scoring arcs) drawn
## into one texture and projected onto the field by a Decal: a strip draped on
## the terrain dipped under the far terrain's coarser LOD and showed dashed.
const PITCH_LINE_PX := 14.0   # texels per metre


# -------------------------------------------------------- stone circle etc.

## The highland stone circle: thirteen standing stones and an altar slab, each
## the server's box (1.6 x 3.2-5.2 x 0.9 m, the altar 3.0 x 1.2 x 1.6) drawn
## as a weathered monolith inside it (_monolith: rounded arrises, a tapering
## crown, a chipped and pitted face) in the hills' own cliff rock, darker at
## its foot and greened where rain lies on it. One mesh, one draw.
const CLIFF_ALBEDO := "res://assets/terrain/textures/cliff_rock_alb_ht.png"
const CLIFF_NORMAL := "res://assets/terrain/textures/cliff_rock_nrm_rgh.png"
static func _stone_circle(parent: Node3D) -> void:
	var c := Layout.landmark("stone_circle")
	if c == Vector3.INF:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7601
	var noise := FastNoiseLite.new()
	noise.seed = 7601
	noise.frequency = 1.6
	noise.fractal_octaves = 3
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 13:
		var a := TAU * i / 13.0
		var g := Layout.ground(c.x + cos(a) * 16.0, c.z + sin(a) * 16.0)
		var hgt := rng.randf_range(3.2, 5.2)
		_monolith(st, noise, g + Vector3(0, hgt * 0.5 - 0.6, 0), Vector3(1.6, hgt, 0.9), -a + rng.randf_range(-0.15, 0.15), 0.84, 0.6)
	_monolith(st, noise, c + Vector3(0, 0.4, 0), Vector3(3.0, 1.2, 1.6), 0.3, 0.97, 0.6)
	st.index()
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "StoneCircle"
	mi.mesh = st.commit()
	mi.material_override = _cliff_rock()
	parent.add_child(mi)


## A standing stone inside the box `size` centred at `centre` (yaw `rot`):
## a rounded box (arrises rounded to a radius, never outside the box), its
## crown narrowed to `taper` of its width, its faces pitted inward by noise;
## the part `buried` metres under its foot gets no bottom face. Vertex colour:
## a darker foot and a green cast on the faces the rain lies on.
static func _monolith(st: SurfaceTool, noise: FastNoiseLite, centre: Vector3, size: Vector3, rot: float, taper: float, buried: float) -> void:
	var h := size * 0.5
	var bevel := minf(0.16, minf(h.x, h.z) * 0.4)
	var inner := h - Vector3.ONE * bevel
	var basis := Basis(Vector3.UP, rot)
	var seed_off := centre * 0.37
	var cells := Vector3i(maxi(4, ceili(size.x / 0.22)), maxi(4, ceili(size.y / 0.25)), maxi(4, ceili(size.z / 0.22)))
	# faces: [axis (0 x, 1 y, 2 z), sign]; no bottom
	for face: Array in [[0, 1.0], [0, -1.0], [2, 1.0], [2, -1.0], [1, 1.0]]:
		var axis: int = face[0]
		var sgn: float = face[1]
		var ua := (axis + 1) % 3
		var va := (axis + 2) % 3
		var nu: int = cells[ua]
		var nv: int = cells[va]
		var grid: Array = []
		for iu in nu + 1:
			var row: Array = []
			for iv in nv + 1:
				var p := Vector3.ZERO
				p[axis] = h[axis] * sgn
				p[ua] = -h[ua] + size[ua] * iu / nu
				p[va] = -h[va] + size[va] * iv / nv
				row.append(_monolith_point(p, h, inner, bevel, taper, noise, seed_off))
			grid.append(row)
		for iu in nu:
			for iv in nv:
				var quad := [grid[iu][iv], grid[iu + 1][iv], grid[iu + 1][iv + 1], grid[iu][iv + 1]]
				# a quad entirely under the ground is never seen
				if (quad[0] as Vector3).y < -h.y + buried - 0.2 and (quad[2] as Vector3).y < -h.y + buried - 0.2:
					continue
				# Godot's front faces are clockwise seen from outside: for (a, b, c)
				# the outward normal is (c - a) x (b - a)
				var n := ((quad[2] as Vector3) - (quad[0] as Vector3)).cross((quad[1] as Vector3) - (quad[0] as Vector3))
				var outward := Vector3.ZERO
				outward[axis] = sgn
				var order := [0, 1, 2, 0, 2, 3] if n.dot(outward) > 0.0 else [0, 2, 1, 0, 3, 2]
				for k: int in order:
					var v: Vector3 = quad[k]
					var foot := clampf((v.y + h.y - buried) / 1.2, 0.0, 1.0)
					var shade := lerpf(0.55, 1.0, foot)
					var wet := clampf((v.y + h.y) / size.y, 0.0, 1.0) * (0.5 + 0.5 * noise.get_noise_3dv(v * 0.7 + seed_off))
					var tint := Color(shade, shade, shade).lerp(Color(shade * 0.78, shade * 0.92, shade * 0.66), clampf(wet, 0.0, 1.0) * 0.6)
					st.set_color(tint)
					st.add_vertex(centre + basis * v)


## One surface point of a monolith (box-local): pulled onto the rounded box,
## narrowed toward the crown, pitted inward.
static func _monolith_point(p: Vector3, h: Vector3, inner: Vector3, bevel: float, taper: float, noise: FastNoiseLite, seed_off: Vector3) -> Vector3:
	var q := p.clamp(-inner, inner)
	var d := p - q
	var v := q + d.normalized() * bevel if d.length_squared() > 1e-8 else p
	var t := clampf((v.y + h.y) / (h.y * 2.0), 0.0, 1.0)
	var s := lerpf(1.0, taper, t * t)
	v.x *= s
	v.z *= s
	# a crown broken off on a slant, lower on one side (by the stone's own
	# noise): still inside the box. The altar (barely tapered) stays level.
	if taper < 0.9:
		var slant := (0.18 + 0.3 * (0.5 + 0.5 * noise.get_noise_1d(seed_off.x * 3.1 + seed_off.z))) * minf(h.y, 1.2)
		v.y = minf(v.y, h.y - slant * (0.5 + 0.5 * v.x / maxf(h.x, 0.01)))
	var out := (v - Vector3(0, v.y, 0) * 0.3).normalized()
	var pit := 0.5 + 0.5 * noise.get_noise_3dv(p + seed_off)
	return v - out * pit * 0.06


static var _rock_mat: ShaderMaterial = null


## The hills' cliff rock (Terrain3D's packed albedo/normal; no roughness or
## AO maps), world-space triplanar like every other grounds surface; the
## vertex colour darkens and greens it.
static func _cliff_rock() -> ShaderMaterial:
	if _rock_mat != null:
		return _rock_mat
	var m := ShaderMaterial.new()
	m.shader = PBR.SHADER
	m.set_shader_parameter("albedo_tex", load(CLIFF_ALBEDO))
	m.set_shader_parameter("normal_tex", load(CLIFF_NORMAL))
	m.set_shader_parameter("tint", Color(0.86, 0.86, 0.82))
	m.set_shader_parameter("world_scale", 1.0 / 2.6)
	m.set_shader_parameter("normal_strength", 1.2)
	m.set_shader_parameter("rough_min", 0.75)
	m.set_shader_parameter("rough_max", 0.92)
	m.set_shader_parameter("lite", true)
	m.set_shader_parameter("lite_roughness", 0.86)
	m.set_shader_parameter("use_baked_instance_ao", true)
	_rock_mat = m
	return m


static func _smugglers_camp(parent: Node3D) -> void:
	var c := Layout.landmark("smugglers_camp")
	if c == Vector3.INF:
		return
	var kit := ArchKit.new()
	for i in 5:
		var a := TAU * i / 5.0 + 0.4
		var g := Layout.ground(c.x + cos(a) * 11.0, c.z + sin(a) * 11.0)
		kit.gable(g + Vector3(0, -0.1, 0), Vector2(4.4, 3.4), 2.5, -a, "canvas", "canvas", 0.0)
	for i in 8:
		var a := TAU * i / 8.0
		var g := Layout.ground(c.x + cos(a) * 5.0, c.z + sin(a) * 5.0)
		kit.box(g + Vector3(0, 0.45, 0), Vector3(0.9, 0.9, 0.9), a, "wood")
	# palisade
	for i in 40:
		var a := TAU * i / 40.0
		if absf(wrapf(a - PI * 0.5, -PI, PI)) < 0.25:
			continue
		var g := Layout.ground(c.x + cos(a) * 20.0, c.z + sin(a) * 20.0)
		kit.cylinder(g + Vector3(0, -0.5, 0), 0.22, 3.3, "timber", 6)
	var root := kit.finish(parent, Mats.materials(), "SmugglersCamp")
	Mats.lamp_light(root, c + Vector3(0, 1.0, 0), 2.0, 12.0)


## The old crypt of Crypt Hollow, now a roofless ruin: the walls stand broken
## to different heights, the roof lies in slabs on the floor and the doorway is
## walled up. The Saltwights climbed out through its split floor; the way
## down to the caverns is the cave mouth in Spider Hollow (GroundsPrecinct).
static func _crypt(parent: Node3D) -> void:
	var c := Layout.landmark("crypt")
	if c == Vector3.INF:
		return
	var kit := ArchKit.new()
	var span := Layout.ground_span(Vector2(c.x, c.z), Vector2(10, 14))
	var fy := span.y + 0.1
	var base := span.x - 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 640
	# the floor: a platform founded down the knoll's slope
	kit.box(Vector3(c.x, (base + fy) * 0.5, c.z), Vector3(9.0, fy - base, 13.0), 0.0, "mossy")
	# walls: [from, to] in local x/z, broken into stretches of uneven height
	var walls := [[Vector2(-4.5, -6.5), Vector2(4.5, -6.5)], [Vector2(4.5, -6.5), Vector2(4.5, 6.5)],
		[Vector2(4.5, 6.5), Vector2(-4.5, 6.5)], [Vector2(-4.5, 6.5), Vector2(-4.5, -6.5)]]
	for w in walls:
		var a: Vector2 = w[0]
		var b: Vector2 = w[1]
		var n := int(ceil(a.distance_to(b) / 1.6))
		for k in n:
			var p0 := a.lerp(b, float(k) / n)
			var p1 := a.lerp(b, float(k + 1) / n)
			var mid := (p0 + p1) * 0.5
			var hgt := rng.randf_range(0.6, 4.2) if rng.randf() > 0.15 else 0.0
			if hgt <= 0.0:
				continue
			var rot := atan2(p1.x - p0.x, p1.y - p0.y)
			kit.box(Vector3(c.x + mid.x, (base + fy + hgt) * 0.5, c.z + mid.y), Vector3(0.9, fy + hgt - base, p0.distance_to(p1) + 0.05), rot, "mossy")
	# the walled-up doorway in the south wall, between two pillars (one broken)
	kit.box(Vector3(c.x, (base + fy + 3.4) * 0.5, c.z + 6.6), Vector3(2.6, fy + 3.4 - base, 0.7), 0.0, "rubble")
	kit.cylinder(Vector3(c.x - 3.0, fy, c.z + 7.2), 0.45, 4.6, "trim", 10)
	kit.cylinder(Vector3(c.x + 3.0, fy, c.z + 7.2), 0.45, 1.7, "trim", 10)
	kit.cylinder(Layout.ground(c.x + 4.6, c.z + 9.4), 0.45, 0.9, "trim", 10, false)
	# fallen roof slabs inside
	for i in 4:
		var p := Vector3(c.x + rng.randf_range(-2.6, 2.6), fy, c.z + rng.randf_range(-4.5, 4.5))
		var tilt := Basis(Vector3.UP, rng.randf() * TAU) * Basis(Vector3.RIGHT, rng.randf_range(0.15, 0.4))
		kit.obox(p + Vector3(0, 0.35, 0), Vector3(2.6, 0.4, 1.8), tilt, "mossy")
	for i in 16:
		var p := Vector2(c.x + rng.randf_range(-16, 16), c.z + rng.randf_range(9, 22))
		var g := Layout.ground(p.x, p.y)
		kit.box(g + Vector3(0, 0.5, 0), Vector3(0.7, 1.2, 0.18), rng.randf_range(-0.2, 0.2), "mossy")
	kit.finish(parent, Mats.materials(), "Crypt")


## The Matriarch's webs: the caverns' dew-beaded orb web (cobweb.gdshader over
## a silk photo) strung between the real trunks round the hollow, plus a few
## sagging over the open floor. (Flat translucent boxes read as white cards.)
static func _hollow_webs(root: Node3D, c: Vector3) -> void:
	var trunks: Array = []
	for variant in ["fir_a", "fir_b", "fir_c", "pine_a", "pine_b", "pine_c", "broadleaf_a", "broadleaf_b"]:
		var data := Scatter.instances(variant)
		for i in data.size() / 5:
			var p := Vector2(data[i * 5], data[i * 5 + 2])
			if p.distance_to(Vector2(c.x, c.z)) < 26.0:
				trunks.append(Vector3(p.x, data[i * 5 + 1], p.y))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7004
	var xforms: Array = []
	var used := {}
	for i in trunks.size():
		if xforms.size() >= 12:
			break
		for j in range(i + 1, trunks.size()):
			var a: Vector3 = trunks[i]
			var b: Vector3 = trunks[j]
			var span := Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
			if span < 2.5 or span > 8.0 or used.has(i) or used.has(j):
				continue
			used[i] = true
			used[j] = true
			var mid := (a + b) * 0.5
			var across := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
			var s := span * 1.05
			var basis := Basis(across, Vector3.UP, across.cross(Vector3.UP)) * Basis(Vector3.RIGHT, rng.randf_range(-0.25, 0.25))
			var g := Layout.ground(mid.x, mid.z)
			xforms.append(Transform3D(basis.scaled_local(Vector3(s, s * 0.85, 1.0)), g + Vector3(0, s * 0.42 + rng.randf_range(0.6, 2.2), 0)))
			break
	# open-floor webs facing the hollow's heart, low and tilted back
	while xforms.size() < 16:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(9.0, 19.0)
		var g := Layout.ground(c.x + cos(ang) * r, c.z + sin(ang) * r)
		var to_c := Vector3(c.x - g.x, 0.0, c.z - g.z).normalized()
		var basis := Basis.looking_at(-to_c, Vector3.UP) * Basis(Vector3.RIGHT, rng.randf_range(-0.5, -0.1)) * Basis(Vector3.FORWARD, rng.randf() * TAU)
		var s := rng.randf_range(3.0, 5.5)
		xforms.append(Transform3D(basis.scaled_local(Vector3(s, s, 1.0)), g + Vector3(0, s * 0.45 + 0.2, 0)))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/cobweb.gdshader")
	mat.set_shader_parameter("web", load("res://assets/vfx/tex/cobweb_1024.png"))
	mat.set_shader_parameter("tint", Color(0.6, 0.8, 0.55))
	mat.set_shader_parameter("opacity", 0.7)
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
		mm.set_instance_custom_data(k, Color(rng.randf(), 0, 0, 0))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Webs"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(inst)


static func _spider_hollow(parent: Node3D) -> void:
	var c := Layout.landmark("spider_hollow")
	if c == Vector3.INF:
		return
	var root := Node3D.new()
	root.name = "SpiderHollow"
	parent.add_child(root)
	_hollow_webs(root, c)
	var l := OmniLight3D.new()
	l.light_color = Color(0.5, 0.75, 0.45)
	l.light_energy = 1.4
	l.omni_range = 18.0
	l.position = c + Vector3(0, 3.0, 0)
	root.add_child(l)
