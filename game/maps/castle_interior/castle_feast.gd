extends RefCounted

## The Feast Hall's tables and the laid tables of the castle: gold plates and
## goblets, bread, fruit and roasts on the Feast Hall's tables and the high
## table, vegetables, fish and tools on the kitchen work tables. NVIDIA
## SimReady scans (CC BY 4.0, res://assets/models/feast/LICENSE.txt)
## decimated onto one atlas; feast.glb holds every dressing piece as one mesh:
##   hall_a..c     6 m of a hall table, places on both sides
##   staff         the whole high table, places on the chair side (+z)
##   kitchen_a..c  2 m of a kitchen work table
## Piece frame: x along the table, the table top at y = 0. No shadows (the
## low preset's measure: tableware shadows doubled the triangles for little).
##
## The hall's own arrangement (not the glb's): the high table on the dais
## and, below it, short trestle tables set at an angle either side of the
## central aisle, chevrons pointing up the hall to the dais; the hearth's
## corner by the doors stays open. The glb's old long table rows (their tops,
## benches and the banners hung over them) are taken out of the drawn build
## here, and out of the map pack by world/patches/castle_interior.json
## (`remove`), which also gives every table and bench below its box: keep
## HALL_TABLES and the patch file in step (`realm_worldc patch`).

const Kit = preload("res://maps/castle_interior/castle_kit.gd")

const FEAST := "res://assets/models/feast/feast.glb"
const HALL_PIECES := ["hall_a", "hall_b", "hall_c"]
const KITCHEN_PIECES := ["kitchen_a", "kitchen_b", "kitchen_c"]
const HALL_PIECE_LENGTH := 6.0
const KITCHEN_PIECE_LENGTH := 2.0
## Kitchen work tables (not layout blocks): two tables along z, 5.5 m in from
## the room's x walls, from z0 + 6 to z1 - 5, top 0.9 m above the floor.
const KITCHEN_TABLE_INSET := 5.5
const KITCHEN_TABLE_Z := [6.0, 5.0]
const KITCHEN_TABLE_TOP := 0.9
## Of the eight 2 m lengths of a kitchen table, this many stay bare.
const KITCHEN_BARE := 2

## The hall tables, layout space: [x, z, yaw degrees] of each table's centre
## (yaw turns the table's length off +x; north of the aisle +30, south -30).
## The castle check's Feast Hall probe (-60, 50) stands in a gap.
const HALL_TABLES := [
	[-81.0, 49.0, 30.0], [-67.0, 49.0, 30.0], [-53.0, 49.0, 30.0], [-39.0, 49.0, 30.0],
	[-81.0, 63.0, -30.0], [-67.0, 63.0, -30.0], [-53.0, 63.0, -30.0],
]
const TABLE_LENGTH := 12.0
const TABLE_WIDTH := 1.4
const TABLE_TOP := 0.85
const BENCH_LENGTH := 11.4
const BENCH_WIDTH := 0.4
const BENCH_TOP := 0.46
## Bench centre line from the table's.
const BENCH_OFFSET := 1.0
## The glb's old long tables and their benches (layout space): every drawn
## triangle of the hall's wood under this box goes.
const OLD_ROWS := AABB(Vector3(-88.5, -0.1, 45.0), Vector3(62.0, 1.3, 22.0))
## The glb's old banner rods over the rows.
const OLD_RODS := AABB(Vector3(-81.0, 12.0, 44.0), Vector3(30.0, 11.0, 24.0))
const OLD_NODES := ["V_house_wood", "D_feast_hall_banner_red", "D_feast_hall_banner_green",
	"D_feast_hall_banner_blue", "D_feast_hall_banner_yellow"]
## The house banners on the dais wall, flanking the west window: [z, slot].
const DAIS_BANNERS := [[44.6, "banner_red"], [47.7, "banner_blue"], [64.3, "banner_green"],
	[67.4, "banner_yellow"]]
const DAIS_WALL_X := -104.9
const BANNER_SIZE := Vector2(2.3, 9.2)
const BANNER_TOP := 19.5

static func build(parent: Node3D, map_y: float, layout: Dictionary) -> int:
	var structure := parent.get_parent() as Node3D
	if structure != null:
		_clear_old_rows(structure)
	_hall_tables(parent, map_y)
	_dais_banners(parent, map_y)
	if not ResourceLoader.exists(FEAST):
		return 0
	var meshes := _meshes()
	if meshes.is_empty():
		return 0
	var root := Node3D.new()
	root.name = "Feast"
	parent.add_child(root)
	var placed := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 1991
	for t: Array in HALL_TABLES:
		var yaw := deg_to_rad(float(t[2]))
		var along := Vector3(cos(yaw), 0.0, -sin(yaw))
		var centre := Vector3(float(t[0]), map_y + TABLE_TOP, float(t[1]))
		var count := int(TABLE_LENGTH / HALL_PIECE_LENGTH)
		var last := ""
		for k in count:
			var at := centre + along * ((k + 0.5) * HALL_PIECE_LENGTH - TABLE_LENGTH * 0.5)
			last = _pick(HALL_PIECES, rng, last)
			_place(root, meshes[last], at, yaw + (PI if rng.randf() < 0.5 else 0.0))
			placed += 1
	for b in layout.get("blocks", []):
		if String(b.get("id", "")) == "staff_table":
			var lo: Array = b.get("min", [])
			var hi: Array = b.get("max", [])
			# along z with the chairs on its -x side: the piece's +z (diners) turns to -x
			var at := Vector3((float(lo[0]) + float(hi[0])) * 0.5, map_y + float(hi[1]),
				(float(lo[2]) + float(hi[2])) * 0.5)
			_place(root, meshes["staff"], at, -PI * 0.5)
			placed += 1
	for room in layout.get("rooms", []):
		if String(room.get("id", "")) != "kitchens":
			continue
		var rect: Array = room["rect"]
		var top := map_y + float(room["y"]) + KITCHEN_TABLE_TOP
		var z0 := float(rect[2]) + KITCHEN_TABLE_Z[0]
		var z1 := float(rect[3]) - KITCHEN_TABLE_Z[1]
		var count := int(floor((z1 - z0) / KITCHEN_PIECE_LENGTH))
		for x in [float(rect[0]) + KITCHEN_TABLE_INSET, float(rect[1]) - KITCHEN_TABLE_INSET]:
			var bare := []
			while bare.size() < mini(KITCHEN_BARE, count - 1):
				var k := rng.randi() % count
				if not bare.has(k):
					bare.append(k)
			var last := ""
			for k in count:
				if bare.has(k):
					last = ""
					continue
				var at := Vector3(x, top, z0 + (k + 0.5) * KITCHEN_PIECE_LENGTH)
				var yaw := -PI * 0.5 if rng.randf() < 0.5 else PI * 0.5
				last = _pick(KITCHEN_PIECES, rng, last)
				_place(root, meshes[last], at, yaw)
				placed += 1
	return placed

## The glb's old hall rows out of the drawn build: the table tops and the
## banners over them as whole nodes, the benches and legs (merged into the
## hall's wood) and the banner rods (in its brass) triangle by triangle.
static func _clear_old_rows(structure: Node3D) -> void:
	for node in structure.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var id := String(mi.name)
		if id in OLD_NODES:
			mi.visible = false
		elif id == "D_feast_hall_wood" or id == "D_feast_hall_wood_dark":
			mi.mesh = _without(mi.mesh, mi.transform, OLD_ROWS)
		elif id == "D_feast_hall_brass":
			mi.mesh = _without(mi.mesh, mi.transform, OLD_RODS)

## `mesh` without the triangles whose centre (in the structure's frame) lies
## in `box`; surfaces keep their order (the materials are overrides by index).
static func _without(mesh: Mesh, xform: Transform3D, box: AABB) -> Mesh:
	if mesh == null:
		return mesh
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if index.is_empty():
			index = PackedInt32Array(range(verts.size()))
		var kept := PackedInt32Array()
		for t in range(0, index.size(), 3):
			var c := xform * ((verts[index[t]] + verts[index[t + 1]] + verts[index[t + 2]]) / 3.0)
			if not box.has_point(c):
				kept.append_array([index[t], index[t + 1], index[t + 2]])
		arrays[Mesh.ARRAY_INDEX] = kept
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, mesh.surface_get_material(s))
	return out

## The trestle tables and their benches, two meshes for all of them (tops and
## seats in oak, trestles and rails darker).
static func _hall_tables(parent: Node3D, map_y: float) -> void:
	var tops := SurfaceTool.new()
	var frames := SurfaceTool.new()
	tops.begin(Mesh.PRIMITIVE_TRIANGLES)
	frames.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t: Array in HALL_TABLES:
		var basis := Basis(Vector3.UP, deg_to_rad(float(t[2])))
		var at := Transform3D(basis, Vector3(float(t[0]), map_y, float(t[1])))
		# the board, a trestle under each end and one in the middle, a stretcher
		_box(tops, at, Vector3(0.0, TABLE_TOP - 0.05, 0.0), Vector3(TABLE_LENGTH, 0.1, TABLE_WIDTH))
		for x in [-TABLE_LENGTH * 0.5 + 0.6, 0.0, TABLE_LENGTH * 0.5 - 0.6]:
			_box(frames, at, Vector3(x, (TABLE_TOP - 0.1) * 0.5, 0.0), Vector3(0.14, TABLE_TOP - 0.1, TABLE_WIDTH * 0.7))
			_box(frames, at, Vector3(x, 0.05, 0.0), Vector3(0.22, 0.1, TABLE_WIDTH * 0.85))
		_box(frames, at, Vector3(0.0, 0.25, 0.0), Vector3(TABLE_LENGTH - 1.2, 0.1, 0.1))
		for side in [-1.0, 1.0]:
			var z: float = side * BENCH_OFFSET
			_box(tops, at, Vector3(0.0, BENCH_TOP - 0.04, z), Vector3(BENCH_LENGTH, 0.08, BENCH_WIDTH))
			for x in [-BENCH_LENGTH * 0.5 + 0.4, 0.0, BENCH_LENGTH * 0.5 - 0.4]:
				_box(frames, at, Vector3(x, (BENCH_TOP - 0.08) * 0.5, z), Vector3(0.1, BENCH_TOP - 0.08, BENCH_WIDTH * 0.8))
	for pair in [[tops, Kit.surface("medieval_wood", Color(0.9, 0.78, 0.66), 2.5), "HallTables"],
			[frames, Kit.surface("medieval_wood", Color(0.5, 0.4, 0.34), 2.5), "HallTrestles"]]:
		var st: SurfaceTool = pair[0]
		st.generate_normals()
		var mi := MeshInstance3D.new()
		mi.name = String(pair[2])
		mi.mesh = st.commit()
		mi.material_override = pair[1]
		parent.add_child(mi)

static func _box(st: SurfaceTool, at: Transform3D, centre: Vector3, size: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = size
	st.append_from(box, 0, at * Transform3D(Basis(), centre))

## The four house banners on the dais wall, two either side of the west
## window, each on a gilt rod.
static func _dais_banners(parent: Node3D, map_y: float) -> void:
	var rod_mat := StandardMaterial3D.new()
	rod_mat.albedo_color = Color(0.83, 0.64, 0.3)
	rod_mat.metallic = 1.0
	rod_mat.roughness = 0.38
	for b: Array in DAIS_BANNERS:
		var cloth := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = BANNER_SIZE
		cloth.mesh = quad
		cloth.material_override = Kit.kit_material(String(b[1]))
		cloth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cloth.name = "DaisBanner"
		# facing +x, into the hall
		cloth.transform = Transform3D(Basis(Vector3.UP, PI * 0.5),
			Vector3(DAIS_WALL_X + 0.12, map_y + BANNER_TOP - BANNER_SIZE.y * 0.5, float(b[0])))
		parent.add_child(cloth)
		var rod := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.05
		cyl.bottom_radius = 0.05
		cyl.height = BANNER_SIZE.x + 0.4
		cyl.radial_segments = 8
		cyl.material = rod_mat
		rod.mesh = cyl
		rod.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5),
			Vector3(DAIS_WALL_X + 0.16, map_y + BANNER_TOP + 0.05, float(b[0])))
		parent.add_child(rod)

## A random piece name other than `last` (neighbours would repeat).
static func _pick(names: Array, rng: RandomNumberGenerator, last: String) -> String:
	var k := rng.randi() % names.size()
	if names[k] == last:
		k = (k + 1) % names.size()
	return names[k]

static func _place(root: Node3D, mesh: Mesh, at: Vector3, yaw: float) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation.y = yaw
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)

## Piece name -> mesh, from the glb's MeshInstance3D nodes.
static func _meshes() -> Dictionary:
	var scene := (load(FEAST) as PackedScene).instantiate()
	var out := {}
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		out[String(node.name)] = (node as MeshInstance3D).mesh
	scene.free()
	return out
