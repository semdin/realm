extends RefCounted

## The living dressing of the castle (the old game's castle_decor.gd): what
## the static glb cannot carry because it moves, glows or is a light.
##   * Long Table: two rows of iron wheel chandeliers hung on chains over the
##     tables, each with its warm light; the tables, the house banners on the
##     dais wall and the laid tableware (castle_feast.gd);
##   * Entrance Hall: two iron ring chandeliers, a torch per bay and two iron
##     fire bowls on stone pedestals by the east wall (where the glb's
##     hourglasses stood, castle_kit.gd LEFT_OUT);
##   * moonlight through the windows (a shadowed directional light);
##   * the rooms' light sources, authored in the glb as FX_<kind>_<n> empties
##     (sconces, hearths, green braziers, lanterns, chandeliers; the tower
##     loft's FX_owl perches stay empty);
##   * the hero props (two suits of armour).
## Built at the low preset the old game picked for Intel iGPUs (the only
## preset of this renderer): no chandelier shadows, a 2-split
## moon. Nothing here collides: the props' boxes are in the map pack.

const CastleFire = preload("res://maps/castle_interior/castle_fire.gd")
const CastleFeast = preload("res://maps/castle_interior/castle_feast.gd")
const StaticMerge = preload("res://maps/castle_interior/static_merge.gd")
const FLAME_SHADER := preload("res://assets/shaders/castle/candle_flame.gdshader")

## Long Table chandeliers (layout space): a row over each side's tables
## (castle_feast.gd HALL_TABLES), the wheel this high over the floor.
const HALL_CHANDELIER_X := [-81.0, -67.0, -53.0, -39.0]
const HALL_CHANDELIER_Z := [49.0, 63.0]
const HALL_CHANDELIER_Y := 11.0

## Hero props (res://assets/castle/props/), layout space: `height` scales the
## model, `yaw` turns it (0 = its front faces +z).
const PROPS := [
	{"name": "armour", "at": Vector3(-17.15, 0.0, 49.6), "yaw": 90.0, "height": 2.45},
	{"name": "armour", "at": Vector3(-17.15, 0.0, 62.4), "yaw": 90.0, "height": 2.45},
]

## The Entrance Hall's fire bowls (layout space, the pedestal's foot): by the
## east wall either side of the bay's portrait, clear of the wall shafts
## (x > 17.36) and of the marble stair (x < 14). Their boxes are in
## world/patches/castle_interior.json: keep the two in step.
const ENTRANCE_BRAZIERS := [Vector3(16.5, 0.0, 38.5), Vector3(16.5, 0.0, 45.5)]
## Pedestal: square, this wide at its foot and this tall to the bowl.
const BRAZIER_BASE := 0.9
const BRAZIER_TOP := 1.0
## Iron bowl: rim radius and depth over the pedestal.
const BOWL_RADIUS := 0.45
const BOWL_DEPTH := 0.3
const EMBER_NOISE := "res://assets/vfx/tex/noise_erosion_512.png"

const FX_WARM := Color(1.0, 0.64, 0.34)
const FX_COLD := Color(0.62, 0.95, 0.82)

## What was built (the check prints it).
static var stats: Dictionary = {}

static func build(parent: Node3D, map_y: float, layout: Dictionary) -> Node3D:
	stats = {}
	var root := Node3D.new()
	root.name = "CastleDecor"
	parent.add_child(root)
	for x in HALL_CHANDELIER_X:
		for z in HALL_CHANDELIER_Z:
			_chandelier(root, Vector3(x, map_y + HALL_CHANDELIER_Y, z), 2.2, 14, 12.0)
	# two shadowed omni lights re-render a cube shadow map every frame anyone
	# moves under them: the low preset keeps the light, not its shadow
	for z in [31.0, 52.0]:
		_chandelier(root, Vector3(0.0, map_y + 15.0, z), 3.2, 18)
	# Entrance Hall wall sconces: a torch per bay on both long walls
	for z in [27.3, 42.0, 56.7]:
		for side in [-1.0, 1.0]:
			_sconce(root, Vector3(side * 17.6, map_y + 7.0, z), -side)
	for at: Vector3 in ENTRANCE_BRAZIERS:
		_brazier(root, at + Vector3(0.0, map_y, 0.0))
	_moonlight(root)
	_build_fx(parent, root)
	for p in PROPS:
		_prop(root, String(p.name), (p.at as Vector3) + Vector3(0.0, map_y, 0.0), float(p.yaw), float(p.height))
	stats["feast_pieces"] = CastleFeast.build(root, map_y, layout)
	stats["batches"] = _batch(root)
	return root

## The iron, glass and wax of every sconce, lantern and chandelier are ~500
## primitive meshes: batched per material on a 16 m grid (a batch still culls
## with its room). Flames (cards facing the camera), the candle MultiMeshes and
## the glb props stay as they are.
static func _batch(root: Node3D) -> int:
	var pieces: Array = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not (mi.mesh is PrimitiveMesh) or mi.mesh is QuadMesh:
			continue
		var plain := true
		for s in mi.mesh.get_surface_count():
			plain = plain and mi.get_active_material(s) is StandardMaterial3D
		if plain:
			pieces.append(mi)
	stats["batched_pieces"] = pieces.size()
	return StaticMerge.merge(root, pieces, "DecorBatch", 16.0)

## A prop glb scaled to `height` metres, standing on `at`, turned `yaw_deg`.
static func _prop(root: Node3D, prop_name: String, at: Vector3, yaw_deg: float, height: float) -> void:
	var path := "res://assets/castle/props/%s.glb" % prop_name
	if not ResourceLoader.exists(path):
		return
	var scene := (load(path) as PackedScene).instantiate() as Node3D
	var holder := Node3D.new()
	holder.name = prop_name.to_pascal_case()
	root.add_child(holder)
	holder.add_child(scene)
	var box := _visual_aabb(scene)
	if box.size.y <= 0.001:
		return
	var s := height / box.size.y
	scene.scale = Vector3.ONE * s
	scene.position = -Vector3(box.get_center().x, box.position.y, box.get_center().z) * s
	holder.position = at
	holder.rotation_degrees.y = yaw_deg

static func _visual_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var local := node.global_transform.affine_inverse() * mi.global_transform if mi.is_inside_tree() else mi.transform
		var box: AABB = local * mi.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out

static func _multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm

# --------------------------------------------------------------- chandeliers

static func _iron() -> StandardMaterial3D:
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.08, 0.07, 0.07)
	iron.metallic = 0.8
	iron.roughness = 0.5
	return iron

## `rise`: how far the chains climb to the vault.
static func _chandelier(root: Node3D, centre: Vector3, radius: float, candles: int, rise := 8.0) -> void:
	var node := Node3D.new()
	node.name = "Chandelier"
	node.position = centre
	root.add_child(node)
	var iron := _iron()
	var ring := TorusMesh.new()
	ring.inner_radius = radius - 0.09
	ring.outer_radius = radius + 0.09
	ring.rings = 48
	ring.ring_segments = 8
	ring.material = iron
	var ring_mi := MeshInstance3D.new()
	ring_mi.mesh = ring
	node.add_child(ring_mi)
	# chains up to the vault
	for k in 4:
		var ang := k * TAU / 4.0
		var chain := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.03
		cyl.bottom_radius = 0.03
		var top := Vector3(0.0, rise, 0.0)
		var foot := Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
		cyl.height = (top - foot).length()
		cyl.material = iron
		chain.mesh = cyl
		chain.position = (foot + top) * 0.5
		chain.basis = Basis(Quaternion(Vector3.UP, (top - foot).normalized()))
		node.add_child(chain)
	var body := CylinderMesh.new()
	body.top_radius = 0.05
	body.bottom_radius = 0.055
	body.height = 0.32
	body.radial_segments = 8
	var wax := StandardMaterial3D.new()
	wax.albedo_color = Color(0.93, 0.89, 0.78)
	body.material = wax
	var flame := QuadMesh.new()
	flame.size = Vector2(0.1, 0.2)
	var fire := ShaderMaterial.new()
	fire.shader = FLAME_SHADER
	fire.set_shader_parameter("bob_height", 0.0)
	flame.material = fire
	var bodies := _multimesh(body, candles)
	var flames := _multimesh(flame, candles)
	for i in candles:
		var ang := i * TAU / candles
		var p := Vector3(cos(ang) * radius, 0.25, sin(ang) * radius)
		bodies.set_instance_transform(i, Transform3D(Basis(), p))
		flames.set_instance_transform(i, Transform3D(Basis(), p + Vector3(0, 0.25, 0)))
		bodies.set_instance_custom_data(i, Color(float(i) / candles, 0, 0, 0))
		flames.set_instance_custom_data(i, Color(float(i) / candles, 0, 0, 0))
	for mm: MultiMesh in [bodies, flames]:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mmi)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.74, 0.45)
	light.light_energy = 3.4
	light.omni_range = 26.0
	light.omni_attenuation = 1.1
	light.position = Vector3(0, 0.8, 0)
	_fade(light, 60.0)
	node.add_child(light)

## A wall torch: iron bracket, a flame card and a warm light, facing `facing_x`.
static func _sconce(root: Node3D, at: Vector3, facing_x: float) -> void:
	var node := Node3D.new()
	node.name = "Sconce"
	node.position = at
	root.add_child(node)
	var iron := _iron()
	var arm := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.08, 0.08)
	box.material = iron
	arm.mesh = box
	arm.position = Vector3(facing_x * 0.35, 0.0, 0.0)
	node.add_child(arm)
	var cup := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.16
	cone.bottom_radius = 0.06
	cone.height = 0.3
	cone.material = iron
	cup.mesh = cone
	cup.position = Vector3(facing_x * 0.7, 0.12, 0.0)
	node.add_child(cup)
	CastleFire.make(node, Vector3(facing_x * 0.7, 0.55, 0.0), Vector2(0.42, 0.7))
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.62, 0.32)
	light.light_energy = 2.6
	light.omni_range = 14.0
	light.omni_attenuation = 1.3
	light.position = Vector3(facing_x * 1.0, 0.8, 0.0)
	node.add_child(light)

# --------------------------------------------------------------- braziers

## A fire bowl on a stone pedestal, its foot at `at`: a stepped sandstone
## pedestal, a wide iron bowl on it, a bed of coals glowing through noise, a
## flame, embers lifting off it and a warm light.
static func _brazier(root: Node3D, at: Vector3) -> void:
	var node := Node3D.new()
	node.name = "Brazier"
	node.position = at
	root.add_child(node)
	var stone := preload("res://maps/castle_interior/castle_kit.gd").surface("sandstone_blocks_08", Color(0.78, 0.74, 0.68), 1.5)
	# foot, shaft and cap, the cap's top BRAZIER_TOP over the floor
	for part: Array in [[BRAZIER_BASE, 0.0, 0.2], [BRAZIER_BASE * 0.7, 0.2, BRAZIER_TOP - 0.32],
			[BRAZIER_BASE * 0.84, BRAZIER_TOP - 0.12, BRAZIER_TOP]]:
		var block := MeshInstance3D.new()
		var box := BoxMesh.new()
		var lo: float = part[1]
		var hi: float = part[2]
		box.size = Vector3(float(part[0]), hi - lo, float(part[0]))
		block.mesh = box
		block.material_override = stone
		block.position = Vector3(0.0, (lo + hi) * 0.5, 0.0)
		node.add_child(block)
	var collar := MeshInstance3D.new()
	var neck := CylinderMesh.new()
	neck.top_radius = BOWL_RADIUS * 0.45
	neck.bottom_radius = BOWL_RADIUS * 0.55
	neck.height = 0.2
	neck.material = _iron()
	collar.mesh = neck
	collar.position = Vector3(0.0, BRAZIER_TOP - 0.12 + 0.1, 0.0)
	node.add_child(collar)
	var bowl := MeshInstance3D.new()
	var cup := CylinderMesh.new()
	cup.top_radius = BOWL_RADIUS
	cup.bottom_radius = BOWL_RADIUS * 0.55
	cup.height = BOWL_DEPTH
	cup.radial_segments = 24
	cup.material = _iron()
	bowl.mesh = cup
	bowl.position = Vector3(0.0, BRAZIER_TOP + 0.08 + BOWL_DEPTH * 0.5, 0.0)
	node.add_child(bowl)
	var rim := MeshInstance3D.new()
	var lip := TorusMesh.new()
	lip.inner_radius = BOWL_RADIUS - 0.03
	lip.outer_radius = BOWL_RADIUS + 0.04
	lip.rings = 24
	lip.ring_segments = 6
	lip.material = _iron()
	rim.mesh = lip
	rim.position = Vector3(0.0, BRAZIER_TOP + 0.08 + BOWL_DEPTH, 0.0)
	node.add_child(rim)
	# the coals: a low mound whose glow is noise (hot cracks between dark lumps)
	var coals := MeshInstance3D.new()
	var bed := SphereMesh.new()
	bed.radius = BOWL_RADIUS * 0.92
	bed.height = 0.22
	bed.radial_segments = 20
	bed.rings = 6
	var ember := StandardMaterial3D.new()
	var noise: Texture2D = load(EMBER_NOISE)
	ember.albedo_color = Color(0.08, 0.05, 0.04)
	ember.roughness = 1.0
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.38, 0.1)
	ember.emission_energy_multiplier = 1.5
	ember.emission_texture = noise
	ember.uv1_scale = Vector3(2.0, 1.0, 1.0)
	bed.material = ember
	coals.mesh = bed
	coals.position = Vector3(0.0, BRAZIER_TOP + 0.08 + BOWL_DEPTH - 0.04, 0.0)
	coals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(coals)
	var flame_at := Vector3(0.0, BRAZIER_TOP + 0.08 + BOWL_DEPTH + 0.02, 0.0)
	CastleFire.make(node, flame_at, Vector2(0.8, 1.1), Color(1, 1, 1), 1.6)
	CastleFire.make(node, flame_at + Vector3(0.12, -0.04, 0.08), Vector2(0.55, 0.8), Color(1, 1, 1), 1.3)
	var sparks := RisingMotes.make(BOWL_RADIUS * 0.6, 4.0, Color(1.0, 0.5, 0.18), 14, 1.8,
		Vector2(0.5, 1.1), Vector2(0.012, 0.024))
	RisingMotes.set_inner(sparks, 0.8)
	sparks.position = flame_at
	node.add_child(sparks)
	sparks.emitting = true
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.3)
	light.light_energy = 2.2
	light.omni_range = 9.0
	light.omni_attenuation = 1.3
	light.position = flame_at + Vector3(-0.6, 0.6, 0.0)
	_fade(light, 45.0)
	node.add_child(light)

# --------------------------------------------------------------- moonlight

## Cool moonlight from the south-west, low enough to come in through the long
## south windows of the Long Table and the Entrance Hall's front lights;
## shadowed (an unshadowed moon floods the floors evenly).
static func _moonlight(root: Node3D) -> void:
	var moon := DirectionalLight3D.new()
	moon.name = "Moonlight"
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.light_energy = 1.3
	moon.rotation_degrees = Vector3(-32.0, -20.0, 0.0)   # travels north-east
	moon.shadow_enabled = true
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	moon.directional_shadow_max_distance = 60.0
	moon.shadow_bias = 0.04
	root.add_child(moon)

# --------------------------------------------------------------- FX points

static func _build_fx(scan_root: Node, root: Node3D) -> void:
	var green_count := 0
	var kinds := {}
	for node in scan_root.find_children("FX_*", "Node3D", true, false):
		var n := node as Node3D
		var parts := String(n.name).split("_")
		if parts.size() < 3:
			continue
		var kind := "_".join(parts.slice(1, parts.size() - 1))
		if kind == "owl":
			continue   # the tower loft's perches stay empty
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		var xf := n.global_transform
		var scale := xf.basis.get_scale().x
		var holder := Node3D.new()
		holder.name = "FX_" + kind
		root.add_child(holder)
		holder.global_transform = Transform3D(Basis(Vector3.UP, xf.basis.get_euler().y), xf.origin)
		match kind:
			"sconce":
				_fx_sconce(holder, FX_WARM)
			"sconce_cold":
				_fx_sconce(holder, FX_COLD)
			"fire":
				_fx_fire(holder, scale)
			"green_fire":
				# a light at every third brazier is the low preset's share
				_fx_green_fire(holder, false)
				green_count += 1
			"lamp":
				_fx_lamp(holder)
			"chandelier":
				_chandelier(holder, Vector3.ZERO, scale, int(scale * 7.0))
	stats["fx"] = kinds

## Far torches cost nothing: they fade out instead of shading the far rooms.
static func _fade(light: Light3D, begin: float = 38.0) -> void:
	light.distance_fade_enabled = true
	light.distance_fade_begin = begin
	light.distance_fade_length = 10.0
	light.distance_fade_shadow = 20.0

## A flipbook flame; `intensity` is the old card's scale, halved for the
## clip's own brightness.
static func _flame(parent: Node3D, pos: Vector3, size: Vector2, tint: Color = Color(1, 1, 1),
		intensity: float = 3.0) -> void:
	CastleFire.make(parent, pos, size * Vector2(1.1, 1.15), tint, intensity * 0.5)

## A wall torch facing local +Z: bracket, cup, flame, light.
static func _fx_sconce(holder: Node3D, colour: Color) -> void:
	var iron := _iron()
	var arm := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.08, 0.08, 0.7)
	box.material = iron
	arm.mesh = box
	arm.position = Vector3(0, 0, 0.35)
	holder.add_child(arm)
	var cup := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.16
	cone.bottom_radius = 0.06
	cone.height = 0.3
	cone.material = iron
	cup.mesh = cone
	cup.position = Vector3(0, 0.12, 0.7)
	holder.add_child(cup)
	_flame(holder, Vector3(0, 0.55, 0.7), Vector2(0.36, 0.6),
		Color(1, 1, 1) if colour == FX_WARM else Color(0.55, 1.0, 0.75))
	var light := OmniLight3D.new()
	light.light_color = colour
	light.light_energy = 2.4
	light.omni_range = 13.0
	light.omni_attenuation = 1.3
	light.position = Vector3(0, 0.8, 1.0)
	_fade(light)
	holder.add_child(light)

## A hearth fire: a few flame cards across the hearth (`scale` ~ width / 4 m),
## staggered in depth and height so the fire has body from any angle.
static func _fx_fire(holder: Node3D, scale: float) -> void:
	for k in 4:
		var x := (float(k) - 1.5) * 0.24 * scale
		var z := 0.08 * float((k * 7) % 3 - 1)
		_flame(holder, Vector3(x, 0.3 + 0.08 * (k % 2), z),
			Vector2(0.6, 0.95) * (0.8 + 0.2 * scale) * (1.0 - 0.12 * (k % 2)), Color(1, 1, 1), 3.2)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.25)
	light.light_energy = 3.2
	light.omni_range = 11.0
	light.omni_attenuation = 1.2
	light.position = Vector3(0, 0.9, 0.9)
	_fade(light, 45.0)
	holder.add_child(light)

static func _fx_green_fire(holder: Node3D, with_light: bool) -> void:
	_flame(holder, Vector3(0, 0.12, 0), Vector2(0.28, 0.32), Color(0.4, 1.0, 0.5), 3.0)
	if with_light:
		var light := OmniLight3D.new()
		light.light_color = Color(0.45, 1.0, 0.55)
		light.light_energy = 1.6
		light.omni_range = 8.0
		light.position = Vector3(0, 0.8, 0)
		_fade(light, 30.0)
		holder.add_child(light)

## A hanging lantern: iron cage, chain, flame, warm light.
static func _fx_lamp(holder: Node3D) -> void:
	_lantern(holder, Vector3.ZERO, 1.0)
	var chain := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.02
	cyl.bottom_radius = 0.02
	cyl.height = 4.0
	cyl.material = _iron()
	chain.mesh = cyl
	chain.position = Vector3(0, 2.25, 0)
	holder.add_child(chain)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.4)
	light.light_energy = 2.0
	light.omni_range = 10.0
	light.position = Vector3(0, -0.3, 0)
	_fade(light)
	holder.add_child(light)

## A lantern body centred on `at`: iron cap and base, four corner posts, smoky
## amber glass panes, the candle and its flame.
static func _lantern(parent: Node3D, at: Vector3, s: float = 1.0) -> void:
	var iron := _iron()
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.95, 0.72, 0.4, 0.22)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.15
	glass.emission_enabled = true
	glass.emission = Color(1.0, 0.62, 0.3)
	glass.emission_energy_multiplier = 0.35
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pane := MeshInstance3D.new()
	var pb := BoxMesh.new()
	pb.size = Vector3(0.3, 0.4, 0.3) * s
	pb.material = glass
	pane.mesh = pb
	pane.position = at
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(pane)
	for spec in [[Vector3(0.38, 0.05, 0.38), 0.225], [Vector3(0.34, 0.05, 0.34), -0.225]]:
		var plate := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = (spec[0] as Vector3) * s
		b.material = iron
		plate.mesh = b
		plate.position = at + Vector3(0, float(spec[1]) * s, 0)
		parent.add_child(plate)
	var cap := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.03 * s
	cone.bottom_radius = 0.22 * s
	cone.height = 0.14 * s
	cone.radial_segments = 4
	cone.material = iron
	cap.mesh = cone
	cap.position = at + Vector3(0, 0.32 * s, 0)
	cap.rotation.y = PI * 0.25
	parent.add_child(cap)
	for c in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var post := MeshInstance3D.new()
		var pbox := BoxMesh.new()
		pbox.size = Vector3(0.025, 0.42, 0.025) * s
		pbox.material = iron
		post.mesh = pbox
		post.position = at + Vector3(c.x * 0.155, 0.0, c.y * 0.155) * s
		parent.add_child(post)
	var candle := MeshInstance3D.new()
	var wax := CylinderMesh.new()
	wax.top_radius = 0.035 * s
	wax.bottom_radius = 0.04 * s
	wax.height = 0.14 * s
	wax.radial_segments = 8
	var wax_mat := StandardMaterial3D.new()
	wax_mat.albedo_color = Color(0.93, 0.89, 0.78)
	wax_mat.emission_enabled = true
	wax_mat.emission = Color(1.0, 0.6, 0.3)
	wax_mat.emission_energy_multiplier = 0.25
	wax.material = wax_mat
	candle.mesh = wax
	candle.position = at + Vector3(0, -0.13 * s, 0)
	parent.add_child(candle)
	var flame := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.1, 0.18) * s
	var fire := ShaderMaterial.new()
	fire.shader = FLAME_SHADER
	fire.set_shader_parameter("bob_height", 0.0)
	fire.set_shader_parameter("intensity", 2.4)
	quad.material = fire
	flame.mesh = quad
	flame.position = at
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(flame)
