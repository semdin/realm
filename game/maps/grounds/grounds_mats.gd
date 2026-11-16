extends RefCounted

## The grounds' shared material set (the old GroundsSites.materials): the PBR
## stone, plaster, timber and roofs every site and the village wear, leaded
## glass, glasshouse panes, cloth in the four house colours, and the plant
## helpers the courtyard and the gardens share (cooked plant meshes scattered
## as MultiMeshes).

const PBR := preload("res://maps/grounds/grounds_pbr.gd")
const WorldSign := preload("res://scripts/world/world_sign.gd")
## How far a place's name over it shows (metres).
const LABEL_REACH := 110.0

static var _mats: Dictionary = {}


static func materials() -> Dictionary:
	if not _mats.is_empty():
		return _mats
	var glass := ShaderMaterial.new()
	# Leaded glass mirroring the sky, with warm rooms behind some of the panes
	# (per-window random from ArchKit.window()).
	glass.shader = preload("res://assets/shaders/castle/window_lit.gdshader")
	glass.set_shader_parameter("quarry_m", 0.22)
	var glasshouse := StandardMaterial3D.new()
	glasshouse.albedo_color = Color(0.70, 0.82, 0.78, 0.28)
	glasshouse.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glasshouse.roughness = 0.05
	glasshouse.metallic_specular = 0.9
	glasshouse.cull_mode = BaseMaterial3D.CULL_DISABLED
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.16, 0.16, 0.17)
	metal.metallic = 0.8
	metal.roughness = 0.45
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.85, 0.66, 0.25)
	gold.metallic = 0.9
	gold.roughness = 0.3
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.03, 0.03, 0.035)
	dark.roughness = 1.0
	_mats = {
		"stone": PBR.surface("castle_wall_varriation", Color(0.95, 0.93, 0.90), {"metres": 4.0}),
		"rubble": PBR.surface("stone_wall", Color(0.85, 0.84, 0.82), {"metres": 4.0}),
		"mossy": PBR.surface("mossy_stone_wall", Color(0.9, 0.92, 0.88), {"metres": 3.0}),
		"plaster": PBR.surface("white_rough_plaster", Color(0.93, 0.90, 0.84), {"metres": 3.0}),
		# village limewash colours (VillageKit picks one per building)
		"plaster_cream": PBR.surface("white_rough_plaster", Color(0.97, 0.89, 0.72), {"metres": 3.0}),
		"plaster_ochre": PBR.surface("white_rough_plaster", Color(0.93, 0.78, 0.55), {"metres": 3.0}),
		"plaster_rose": PBR.surface("white_rough_plaster", Color(0.94, 0.80, 0.74), {"metres": 3.0}),
		"plaster_sage": PBR.surface("white_rough_plaster", Color(0.80, 0.86, 0.76), {"metres": 3.0}),
		"timber": PBR.surface("medieval_wood", Color(0.46, 0.38, 0.31), {"metres": 2.0}),
		"wood": PBR.surface("wooden_planks", Color(0.80, 0.70, 0.60), {"metres": 2.5}),
		"roof": PBR.surface("roof_slates_02", Color(0.46, 0.50, 0.60), {"metres": 3.0}),
		"roof_warm": PBR.surface("grey_roof_tiles", Color(0.80, 0.70, 0.62), {"metres": 3.0}),
		"cobble": PBR.surface("cobblestone_floor_04", Color(0.9, 0.9, 0.9), {"metres": 4.0}),
		"trim": PBR.surface("stone_wall", Color(0.86, 0.86, 0.86), {"metres": 3.0}),
		"glass": glass,
		"glasshouse": glasshouse,
		"metal": metal,
		"gold": gold,
		"dark": dark,
		"ember": _ember(),
		# the houses' own colours (house_colors.gd)
		"cloth_red": _cloth(preload("res://scripts/content/house_colors.gd").cloth("cloth_red")),
		"cloth_blue": _cloth(preload("res://scripts/content/house_colors.gd").cloth("cloth_blue")),
		"cloth_green": _cloth(preload("res://scripts/content/house_colors.gd").cloth("cloth_green")),
		"cloth_yellow": _cloth(preload("res://scripts/content/house_colors.gd").cloth("cloth_yellow")),
		"canvas": _cloth(Color(0.55, 0.50, 0.40)),
	}
	return _mats


## Extra materials a site adds to the set (the greenhouse model's slots).
static func put(key: String, material: Material) -> void:
	materials()[key] = material


## The coals of a forge hearth.
static func _ember() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.45, 0.12)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.45, 0.12)
	m.emission_energy_multiplier = 3.0
	return m


static func _cloth(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func clear_cache() -> void:
	_mats.clear()


# ------------------------------------------------------------------ plants

## The cooked variant meshes of one plant (assets/models/plants/cooked/<id>_<n>.res).
static func plant_meshes(id: String) -> Array:
	var out: Array = []
	while ResourceLoader.exists("res://assets/models/plants/cooked/%s_%d.res" % [id, out.size()]):
		out.append(load("res://assets/models/plants/cooked/%s_%d.res" % [id, out.size()]))
	return out


## Scatter `meshes` at `spots` ([position, yaw, scale]): one MultiMesh per
## mesh, the spots dealt round the variants.
static func plant(root: Node3D, node_name: String, meshes: Array, spots: Array, range_end: float) -> void:
	if meshes.is_empty() or spots.is_empty():
		return
	var buckets: Array = []
	for m: Variant in meshes:
		buckets.append([])
	for i in spots.size():
		buckets[i % meshes.size()].append(spots[i])
	for k in meshes.size():
		var list: Array = buckets[k]
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[k]
		mm.instance_count = list.size()
		for i in list.size():
			var s: Array = list[i]
			mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, float(s[1])).scaled(Vector3.ONE * float(s[2])), s[0]))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d" % [node_name, k]
		mmi.multimesh = mm
		mmi.visibility_range_end = range_end
		# small flowers cast no shadow; bushes do
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if range_end < 100.0 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mmi)


## A floating name over a place (already translated), with an optional hint
## line under it: never smaller than readable on screen, faded out past
## LABEL_REACH (WorldSign).
static func label(parent: Node3D, text: String, sub: String, at: Vector3) -> void:
	var sign: Label3D = WorldSign.new()
	sign.text = I18n.upper(text)
	sign.font = HudKit.deco()
	sign.font_size = 44
	sign.outline_size = 10
	sign.modulate = Color(1.0, 0.86, 0.55)
	sign.outline_modulate = Color(0.05, 0.03, 0.02, 0.9)
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign.pixel_size = 0.006
	sign.position = at
	sign.call("setup", LABEL_REACH)
	parent.add_child(sign)
	if sub == "":
		return
	var line := Label3D.new()
	line.text = sub
	line.font = HudKit.bold()
	line.font_size = 30
	line.outline_size = 8
	line.modulate = Color(0.85, 0.9, 1.0)
	line.outline_modulate = Color(0.05, 0.03, 0.02, 0.9)
	line.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	line.pixel_size = 0.005
	# under the name, as its child: it grows with it
	line.position = Vector3(0, -0.55, 0)
	WorldSign.fade_line(line, LABEL_REACH)
	sign.add_child(line)


## A warm lamp light (torch_lights: the quality preset scales its reach).
static func lamp_light(parent: Node3D, pos: Vector3, energy: float = 1.2, reach: float = 9.0) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.76, 0.46)
	l.light_energy = energy
	l.omni_range = reach
	l.shadow_enabled = false
	l.position = pos
	l.add_to_group("grounds_torch_lights")
	parent.add_child(l)
	return l
