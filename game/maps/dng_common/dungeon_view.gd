extends Node3D

## Shared base of the drawn dungeon maps (Phase 6.3): the old game's
## code-built dungeons (scripts/world/dungeons/dungeon_greybox.gd) drawn as
## places - dressed and weathered stone, vaulted or timbered or rock
## ceilings, iron sconces and braziers with living flames, the ways out as
## pools of light - without any of its collision. main.gd instances a
## dungeon's scene at the copy's offset (the server keeps 8 copies 240 m
## apart) and calls setup(session, main).
##
## The map server's pack was exported from the very same room code, so every
## floor, wall and doorway sill drawn here stands where the server's box is.
## The gates are not drawn here: DungeonGates draws the portcullises from the
## server's gate schedule (the old greybox's bars and straps).
##
##   Structure   floors, walls and sills (the server's boxes), cut into
##               pieces and batched per material on a CELL grid so no batch
##               touches more lights than the Mobile renderer's per-object
##               limit (8) and frustum culling still drops far rooms
##   Trim        what the server has no collider for: plinths, base courses,
##               cornices, pilasters with their capitals (pilasters stand
##               0.7 m proud of the wall: world/patches/<map>.json gives them
##               their boxes), and the ceilings (_ceiling): barrel vaults with
##               lunettes and arched ribs, timber beams, or a cave's rock dome
##               - all above head height; a cave's rock skins over its walls
##               (under a body's radius proud); built shapes are batched per
##               cell and material as they are made (_batch)
##   Dressing    torches on brackets and braziers (their light flickers),
##               plain cloths in house-neutral colours, chains, rubble,
##               webs, props, the ways out, lights
##
## Every surface is dungeon_surface.gdshader over the project's PBR sets: a
## second set laid through the first by noise, broad patches, grime and damp
## at the walls' feet, seep stains, moss, worn arrises on dressed trim.
## Light: the torches and braziers, a soft bounce under every big room's
## ceiling, the ambient raised by `ambient_scale`, a little depth fog.
##
## Low-preset look throughout (the old game's iGPU path): no shadows from the
## torches, glow by the quality preset.

const StaticMerge = preload("res://maps/castle_interior/static_merge.gd")
const CastleFire = preload("res://maps/castle_interior/castle_fire.gd")
const StandingCards = preload("res://maps/dng_common/standing_cards.gd")
const PORTAL_POOL := preload("res://assets/shaders/portal_pool.gdshader")
const PORTAL_NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const PORTAL_RIPPLE := "res://assets/vfx/atlases/ripple_blue_8x8_1k.png"
const PORTAL_AURA := "res://assets/vfx/atlases/waylink_aura_8x8_1k.png"
const PORTAL_TINT := Color(0.42, 0.72, 1.0)
const Shapes = preload("res://maps/dng_common/dungeon_shapes.gd")
const SURFACE := preload("res://assets/shaders/dungeon_surface.gdshader")
const BANNER := preload("res://assets/shaders/dungeon_banner.gdshader")
const WEB_SHADER := preload("res://assets/shaders/cobweb.gdshader")
const WEB_TEX := "res://assets/vfx/tex/cobweb_1024.png"
const NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const HESSIAN := "res://assets/textures/pbr/hessian_230/hessian_230_%s_1k.jpg"

## Batches (and the pieces cut before batching) on this grid, metres.
const CELL := 12.0
const PIECE := 6.0
const SIDE_DOOR := 6.0

## Set by the subclass's _build.
var map_id := ""
var floor_y := 1000.0
var wall_h := 8.0
## Pilaster spacing along a room's long walls (0 = none).
var bay := 6.0
## "castle" (the castle's indoor look) or "cavern".
var atmosphere := "castle"
## What closes a room overhead (_ceiling): "barrel" (a stone barrel vault
## with its end lunettes and an arched rib over every pilaster pair),
## "timber" (beams and boarding over a frieze) or "rock" (a cave's rough
## dome). A subclass may change it between rooms.
var ceiling := "barrel"
## The highest a wide room's segmental vault rises over its springing (m).
var vault_rise_max := 7.0
## Rock skins over the flat walls (a cave's rooms): the walls' faces drawn
## as rough rock up to 0.25 m proud (under a body's radius).
var rock_walls := false
## The ambient fill (environment_for) times this: a map's own darkness.
var ambient_scale := 1.0
## Every big room's soft bounce light under its ceiling (_ceiling).
var fill_color := Color(1.0, 0.78, 0.58)
var fill_energy := 0.45
## Every surface the view made (dungeon_surface.gdshader): floor_y is set on
## them once the subclass has said where the floor is.
var _surfaces: Dictionary = {}
var _noise_img: FastNoiseLite
## The torches' and braziers' lights, flickering: [light, base energy, phase].
var _flicker: Array = []
var _flicker_t := 0.0
## The rock ceilings built: [{area: Rect2, spring, rise}].
var _rock_rooms: Array = []
## The structure's walls and pillars as boxes (view space): torches and
## cloths find their wall here.
var _walls: Array = []
var _chunks: Array = []
var _vault_uv: Material
var _trim_uv: Material
var _rubble_mat: Material
var _boards: Material
var _beam: Material
## Built shapes waiting to be made into one mesh per cell and material.
var _batches: Dictionary = {}
## A cave's rock in mesh UVs (rock skins, rock ceilings); null elsewhere.
var _rock_uv: Material
## The base course along every wall's foot (rougher stone than the wall).
var _base: Material

var structure: Node3D
var trim: Node3D
var dressing: Node3D
## What was built (the check prints it).
var built_stats: Dictionary = {}
## Drawn solids the old game gave no collider: [{note, center, half, yaw_deg}]
## in the map's own (pack) coordinates; tools write them as patches.
var solids: Array = []
## The old game's colliders for things drawn otherwise now: [{note, min,
## max}], world boxes the export's colliders inside are taken out by (the
## patch's `remove`, realm_worldc patch.rs); `solids` gives the drawn shape.
var removed: Array = []
## Baked stalagmites placed as solids: [{xform: the stalag mesh's placement
## (pack coordinates), note}]. map_solids.gd boxes each inside its drawn rock
## from the mesh (the caverns' spires' raster, DungeonView.raster_solids) as
## ordinary colliders.
var stalagmites: Array = []

var _stone: Material
var _floor_mat: Material
var _vault: Material
var _trim: Material
var _iron: StandardMaterial3D
var _lights := 0
var _occluders := 0
var _sun: DirectionalLight3D
var _env: WorldEnvironment
var _env_before: Environment
var _occlusion_before := false

func _ready() -> void:
	name = "MapView"
	build()

func build() -> void:
	if structure != null:
		return
	var started := Time.get_ticks_msec()
	structure = Node3D.new()
	structure.name = "Structure"
	add_child(structure)
	trim = Node3D.new()
	trim.name = "Trim"
	add_child(trim)
	dressing = Node3D.new()
	dressing.name = "Dressing"
	add_child(dressing)
	_iron = _mat(Color(0.16, 0.15, 0.15), 0.5, 0.6)
	_noise_img = FastNoiseLite.new()
	_noise_img.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise_img.frequency = 0.22
	_noise_img.fractal_octaves = 3
	_materials()
	_build()
	built_stats["layout_ms"] = Time.get_ticks_msec() - started
	for m: ShaderMaterial in _surfaces.values():
		m.set_shader_parameter("floor_y", floor_y)
	_portal_sigils()
	set_process(not _flicker.is_empty())
	var pieces := structure.get_child_count() + trim.get_child_count()
	built_stats["structure_batches"] = StaticMerge.merge(structure, structure.get_children(), "Stone", CELL)
	built_stats["trim_batches"] = StaticMerge.merge(trim, trim.get_children(), "Trim", CELL)
	built_stats["shape_batches"] = _commit_batches()
	var small: Array = dressing.get_children().filter(func(n): return n is MeshInstance3D and String(n.name) == "Cup")
	built_stats["cup_batches"] = StaticMerge.merge(dressing, small, "Cups", CELL)
	built_stats["pieces"] = pieces
	built_stats["lights"] = _lights
	built_stats["occluders"] = _occluders
	built_stats["solids"] = solids.size()
	built_stats["meshes"] = find_children("*", "GeometryInstance3D", true, false).size()
	built_stats["build_ms"] = Time.get_ticks_msec() - started

## The stone: cold cut blocks over a base of rubble masonry, worn flags
## through packed dirt, a plastered vault, dressed trim with worn arrises (the
## dungeons are castle rooms). A map in other stone overrides this.
func _materials() -> void:
	_stone = surf("medieval_blocks_03", Color(0.8, 0.83, 0.86), 3.0,
		{"second": "castle_wall_varriation", "tint2": Color(0.62, 0.64, 0.66), "metres2": 2.6, "cover": 0.3, "streaks": 0.35})
	_floor_mat = surf("large_floor_tiles_02", Color(0.86, 0.85, 0.83), 4.0,
		{"second": "floor_flagstone_01", "tint2": Color(0.5, 0.5, 0.5), "metres2": 3.2, "cover": 0.4, "macro": 0.32})
	_vault = surf("plaster_grey_04", Color(0.7, 0.72, 0.75), 3.0, {"grime": 0.0, "streaks": 0.45})
	_vault_uv = surf("medieval_blocks_03", Color(0.62, 0.64, 0.68), 2.6, {"mapping": 1, "grime": 0.0, "streaks": 0.0, "macro": 0.35})
	_trim = surf("sandstone_blocks_08", Color(0.74, 0.76, 0.8), 2.0, {"wear": 1.0, "grime": 0.45})
	_trim_uv = surf("sandstone_blocks_08", Color(0.7, 0.72, 0.76), 2.0, {"mapping": 1, "grime": 0.0})
	_base = surf("castle_wall_varriation", Color(0.6, 0.62, 0.64), 2.4, {"grime": 0.75, "grime_height": 1.4, "streaks": 0.0})
	_rubble_mat = surf("castle_wall_varriation", Color(0.66, 0.67, 0.68), 1.2, {"grime": 0.2, "streaks": 0.0})
	_boards = surf("medieval_wood", Color(0.78, 0.66, 0.56), 1.6, {"grime": 0.0, "streaks": 0.0, "macro": 0.3})
	_beam = surf("medieval_wood", Color(0.7, 0.58, 0.48), 1.2, {"grime": 0.0, "streaks": 0.0, "wear": 0.6})

## A PBR set's [albedo, normal]: a Poly Haven set under assets/textures/pbr
## (diff + nor_gl, or albedo + normal) or a terrain set under
## assets/terrain/textures (alb_ht + nrm_rgh).
static func pbr_maps(set_id: String) -> Array:
	for pair: Array in [["diff_2k.jpg", "nor_gl_2k.jpg"], ["albedo_2k.png", "normal_2k.png"],
			["albedo_1k.png", "normal_1k.png"], ["diff_1k.jpg", "nor_gl_1k.jpg"]]:
		var a := "res://assets/textures/pbr/%s/%s_%s" % [set_id, set_id, pair[0]]
		if ResourceLoader.exists(a):
			return [load(a), load("res://assets/textures/pbr/%s/%s_%s" % [set_id, set_id, pair[1]])]
	var t := "res://assets/terrain/textures/%s_%s.png"
	if ResourceLoader.exists(t % [set_id, "alb_ht"]):
		return [load(t % [set_id, "alb_ht"]), load(t % [set_id, "nrm_rgh"])]
	push_warning("dungeon: no PBR set %s" % set_id)
	return [null, null]

## A dungeon surface (dungeon_surface.gdshader) from a PBR set, `metres` a
## tile. `opts`: second (set), tint2, metres2, cover (its share), mapping (0
## world triplanar, 1 mesh UVs in metres), grime, grime_height, streaks,
## moss, moss_color, moss_height, wear (worn arrises), macro, rough, normal.
func surf(set_id: String, tint: Color, metres: float, opts: Dictionary = {}) -> ShaderMaterial:
	var key := "%s|%s|%.2f|%s" % [set_id, tint.to_html(), metres, var_to_str(opts)]
	if _surfaces.has(key):
		return _surfaces[key]
	var maps := pbr_maps(set_id)
	var m := ShaderMaterial.new()
	m.shader = SURFACE
	m.set_shader_parameter("albedo_tex", maps[0])
	m.set_shader_parameter("normal_tex", maps[1])
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("world_scale", 1.0 / metres)
	m.set_shader_parameter("uv_scale", 1.0 / metres)
	m.set_shader_parameter("noise_tex", load(NOISE))
	m.set_shader_parameter("mapping", int(opts.get("mapping", 0)))
	if opts.has("second"):
		var second := pbr_maps(String(opts["second"]))
		m.set_shader_parameter("use_second", true)
		m.set_shader_parameter("albedo2_tex", second[0])
		m.set_shader_parameter("normal2_tex", second[1])
		m.set_shader_parameter("tint2", opts.get("tint2", Color.WHITE))
		m.set_shader_parameter("world_scale2", 1.0 / float(opts.get("metres2", metres)))
		m.set_shader_parameter("second_cover", float(opts.get("cover", 0.35)))
	m.set_shader_parameter("grime_amount", float(opts.get("grime", 0.55)))
	m.set_shader_parameter("grime_height", float(opts.get("grime_height", 1.6)))
	m.set_shader_parameter("streak_amount", float(opts.get("streaks", 0.3)))
	m.set_shader_parameter("moss_amount", float(opts.get("moss", 0.0)))
	m.set_shader_parameter("moss_color", opts.get("moss_color", Color(0.2, 0.24, 0.12)))
	m.set_shader_parameter("moss_height", float(opts.get("moss_height", 1.0)))
	m.set_shader_parameter("edge_wear", float(opts.get("wear", 0.0)))
	m.set_shader_parameter("macro_amount", float(opts.get("macro", 0.28)))
	m.set_shader_parameter("roughness", float(opts.get("rough", 0.86)))
	m.set_shader_parameter("normal_strength", float(opts.get("normal", 1.0)))
	_surfaces[key] = m
	return m

## Subclasses lay their rooms out here (the old game's _build, positions local
## to the copy).
func _build() -> void:
	pass

func setup(_session: Node, main: Node) -> void:
	var viewport := get_viewport()
	_occlusion_before = viewport.use_occlusion_culling
	viewport.use_occlusion_culling = true
	_sun = main.get_node_or_null("Sun") as DirectionalLight3D
	if _sun != null:
		_sun.visible = false
	_env = main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if _env != null:
		_env_before = _env.environment
		_env.environment = dungeon_environment()

## The map's atmosphere (environment_for) with the dungeon's own fill: the
## ambient raised by `ambient_scale` so a room reads between its torches,
## the dark kept in the vaults by a little depth fog.
func dungeon_environment() -> Environment:
	var env := environment_for(atmosphere)
	env.ambient_light_energy *= ambient_scale
	env.tonemap_exposure *= 1.12
	if atmosphere != "cavern":
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		env.fog_light_color = Color(0.05, 0.05, 0.065)
		env.fog_light_energy = 1.0
		env.fog_density = 0.007
		env.fog_sky_affect = 1.0
	return env

## QualityPreset.apply_map: the preset's glow (the old game's indoor glow
## on medium and high, none on low).
func apply_quality(preset: Dictionary) -> void:
	apply_glow(_env, _env_before, preset)

static func apply_glow(env_node: WorldEnvironment, before: Environment, preset: Dictionary) -> void:
	if is_instance_valid(env_node) and before != null and env_node.environment != null:
		env_node.environment.glow_enabled = bool(preset.get("glow", false))

func _exit_tree() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.use_occlusion_culling = _occlusion_before
	if is_instance_valid(_sun):
		_sun.visible = true
	if is_instance_valid(_env) and _env_before != null:
		_env.environment = _env_before

## The old game's indoor atmospheres at the low preset: the castle's (a dim
## warm ambient, the torches light the rooms) or the caverns' (a cold
## green-grey ambient, depth fog that swallows the far rock).
static func environment_for(kind: String) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	# glow follows the quality preset (apply_quality; off on low)
	env.glow_enabled = false
	env.glow_intensity = 0.7 if kind == "cavern" else 0.55
	env.glow_bloom = 0.06 if kind == "cavern" else 0.04
	env.glow_hdr_threshold = 0.9 if kind == "cavern" else 1.1
	if kind == "cavern":
		env.background_color = Color(0.008, 0.01, 0.012)
		env.ambient_light_color = Color(0.46, 0.54, 0.56)
		env.ambient_light_energy = 1.5
		env.tonemap_exposure = 1.15
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		env.fog_light_color = Color(0.07, 0.1, 0.1)
		env.fog_light_energy = 1.0
		env.fog_density = 0.009
		env.fog_sky_affect = 1.0
		env.fog_height = -1000.0
		env.fog_height_density = 0.0
	else:
		env.background_color = Color(0.04, 0.045, 0.06)
		env.ambient_light_color = Color(0.34, 0.32, 0.36)
		env.ambient_light_energy = 0.6
		env.tonemap_exposure = 1.05
		env.fog_enabled = false
	return env

# --------------------------------------------------------------- building

func _mat(color: Color, roughness: float, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

## A world-space triplanar PBR surface on the lite path from a 2k Poly Haven
## set (diff + nor_gl) under res://assets/textures/pbr.
func _pbr(set_id: String, tint: Color, metres: float) -> ShaderMaterial:
	return surf(set_id, tint, metres)

## A box of `size` centred on `center` under `parent`, cut into pieces no
## longer than PIECE along x and z (so the batches stay on their cells).
func _pieces(parent: Node3D, center: Vector3, size: Vector3, material: Material) -> void:
	var nx := maxi(1, ceili(size.x / PIECE - 0.01))
	var nz := maxi(1, ceili(size.z / PIECE - 0.01))
	var piece := Vector3(size.x / nx, size.y, size.z / nz)
	var mesh := BoxMesh.new()
	mesh.size = piece
	mesh.material = material
	for i in nx:
		for k in nz:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = center + Vector3((i + 0.5) * piece.x - size.x * 0.5, 0.0, (k + 0.5) * piece.z - size.z * 0.5)
			parent.add_child(mi)

## A box the server has too (floor, wall, sill): drawn into the structure.
func _box(center: Vector3, size: Vector3, material: Material = null) -> void:
	_pieces(structure, center, size, material if material != null else _stone)
	if size.y >= 3.0 and (size.x >= 2.0 or size.z >= 2.0):
		_occluder(center, size)
	if size.y >= 3.0:
		_walls.append(AABB(center - size * 0.5, size))
	if rock_walls and size.y >= 3.0 and (material == null or material == _stone) and minf(size.x, size.z) <= 1.01:
		_rock_skins(center, size)

## Rough rock over both long faces of a wall box (a cave's rooms), cut into
## PIECE lengths like the stone behind it.
func _rock_skins(center: Vector3, size: Vector3) -> void:
	var along_z := size.z > size.x
	var length := size.z if along_z else size.x
	var half_t := (size.x if along_z else size.z) * 0.5
	var u_mid := center.z if along_z else center.x
	var plane_mid := center.x if along_z else center.z
	var end0 := u_mid - length * 0.5
	var end1 := u_mid + length * 0.5
	var y0 := center.y - size.y * 0.5 - 0.3
	var y1 := center.y + size.y * 0.5
	var n := maxi(1, ceili(length / PIECE - 0.01))
	for side in [-1.0, 1.0]:
		for k in n:
			var u0 := end0 + length * float(k) / n
			var u1 := end0 + length * float(k + 1) / n
			var um := (u0 + u1) * 0.5
			Shapes.origin = Vector3(plane_mid + side * half_t, (y0 + y1) * 0.5, um) if along_z else Vector3(um, (y0 + y1) * 0.5, plane_mid + side * half_t)
			var skin_mat := _rock_uv if _rock_uv != null else _stone
			_add_mesh(trim, Shapes.rock_skin(_noise_img, along_z, plane_mid + side * half_t, side, u0, u1, end0, end1,
				y0, y1, 0.6, skin_mat), "RockSkin", skin_mat)

## Built mesh arrays (Shapes, relative to Shapes.origin) added to the
## batch of their CELL and material (`parent`'s layer): one mesh per batch,
## made once at the end of the build (_commit_batches).
func _add_mesh(parent: Node3D, arrays: Array, piece_name: String, material: Material) -> void:
	var at := Shapes.origin
	Shapes.origin = Vector3.ZERO
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return
	_batch(parent, piece_name, material, Transform3D(Basis(), at), arrays)

## Mesh arrays placed by `xform` into the batch of their cell (by where
## they stand) and material under `parent`.
func _batch(parent: Node3D, piece_name: String, material: Material, xform: Transform3D, arrays: Array) -> void:
	var cell := xform.origin / CELL
	var key := "%s|%d,%d,%d|%d" % [parent.name, floori(cell.x), floori(cell.y), floori(cell.z), material.get_instance_id()]
	if not _batches.has(key):
		var origin := Vector3(floorf(cell.x) + 0.5, floorf(cell.y) + 0.5, floorf(cell.z) + 0.5) * CELL
		_batches[key] = {"parent": parent, "name": piece_name, "material": material, "origin": origin, "parts": [],
			"tangents": arrays[Mesh.ARRAY_TANGENT] != null}
	var b: Dictionary = _batches[key]
	var local := Transform3D(Basis(), -(b["origin"] as Vector3)) * xform
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if xform.basis != Basis():
		normals = Transform3D(xform.basis.inverse().transposed(), Vector3.ZERO) * normals
	(b["parts"] as Array).append([local * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array), normals,
		arrays[Mesh.ARRAY_TEX_UV], arrays[Mesh.ARRAY_TANGENT]])

## Every batch as one mesh on its cell.
func _commit_batches() -> int:
	var made := 0
	for key: String in _batches:
		var b: Dictionary = _batches[key]
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var uv := PackedVector2Array()
		var t := PackedFloat32Array()
		var with_uv := true
		var with_t := bool(b["tangents"])
		for part: Array in b["parts"]:
			v.append_array(part[0])
			n.append_array(part[1])
			if part[2] == null:
				with_uv = false
			else:
				uv.append_array(part[2])
			if part[3] == null:
				with_t = false
			elif with_t:
				t.append_array(part[3])
		if v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		if with_uv:
			arrays[Mesh.ARRAY_TEX_UV] = uv
		if with_t:
			arrays[Mesh.ARRAY_TANGENT] = t
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, b["material"])
		var mi := MeshInstance3D.new()
		mi.name = "%s%d" % [b["name"], made]
		mi.mesh = mesh
		mi.position = b["origin"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(b["parent"] as Node3D).add_child(mi)
		made += 1
	_batches.clear()
	return made

## A decorative box (the server has none).
func _deco(center: Vector3, size: Vector3, material: Material) -> void:
	_pieces(trim, center, size, material)

## A drawn solid the old game gave no collider: drawn as trim and recorded
## for world/patches/<map>.json.
func _solid(center: Vector3, size: Vector3, material: Material, note: String) -> void:
	_deco(center, size, material)
	if size.y >= 3.0:
		_walls.append(AABB(center - size * 0.5, size))
	solids.append({"note": note, "center": [snappedf(center.x, 0.001), snappedf(center.y, 0.001), snappedf(center.z, 0.001)],
		"half": [snappedf(size.x * 0.5, 0.001), snappedf(size.y * 0.5, 0.001), snappedf(size.z * 0.5, 0.001)], "yaw_deg": 0})

## A wall's box occluder (rooms hide each other behind their walls).
func _occluder(center: Vector3, size: Vector3) -> void:
	var occ := OccluderInstance3D.new()
	var box := BoxOccluder3D.new()
	# a little inside the drawn stone, so it never hides its own face
	box.size = Vector3(maxf(size.x - 0.1, 0.05), maxf(size.y - 0.1, 0.05), maxf(size.z - 0.1, 0.05))
	occ.occluder = box
	occ.position = center
	structure.add_child(occ)
	_occluders += 1

## A room's floor and four walls, `size` (x, z) centred on `center` (x, z),
## leaving an 8 m doorway wherever an opening point lies on a wall.
## `side_doors` (Vector2(side, z): side -1 west, +1 east) cut SIDE_DOOR wide
## doorways into the long x walls; `open_side` (-1 / +1) leaves that x wall
## out - a side room joined to the room whose wall already stands there.
func _room(center: Vector2, size: Vector2, openings: Array, door: float = 8.0, y: float = INF,
		side_doors: Array = [], open_side: int = 0) -> void:
	var fy := floor_y if y == INF else y
	_box(Vector3(center.x, fy - 0.5, center.y), Vector3(size.x, 1, size.y), _floor_mat)
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var wy := fy + wall_h * 0.5
	var gaps := {}   # z wall side -> has a doorway
	for side in [-1.0, 1.0]:
		if int(side) != open_side:
			_wall_x(center.x + side * (hx + 0.5), wy, center.y - hz - 1.0, center.y + hz + 1.0, _doors_on(side_doors, int(side)))
		var wz: float = center.y + side * (hz + 0.5)
		var gap := false
		for o in openings:
			if absf(float(o) - (center.y + side * hz)) < 0.6:
				gap = true
		gaps[side] = gap
		if not gap:
			_box(Vector3(center.x, wy, wz), Vector3(size.x, wall_h, 1))
		else:
			var seg := (size.x - door) * 0.5
			if seg > 0.0:
				_box(Vector3(center.x - (door * 0.5 + seg * 0.5), wy, wz), Vector3(seg, wall_h, 1))
				_box(Vector3(center.x + (door * 0.5 + seg * 0.5), wy, wz), Vector3(seg, wall_h, 1))
	var ribs := _dress_room(center, size, fy, open_side, side_doors, gaps, door)
	_ceiling(center, size, fy + wall_h, ribs)

static func _doors_on(side_doors: Array, side: int) -> Array:
	var out: Array = []
	for d in side_doors:
		if int((d as Vector2).x) == side:
			out.append((d as Vector2).y)
	out.sort()
	return out

## A wall along z at `x`, from `z_from` to `z_to`, with a SIDE_DOOR doorway
## centred on each z in `doors` (ascending); a sill floors each doorway.
func _wall_x(x: float, wy: float, z_from: float, z_to: float, doors: Array) -> void:
	var z := z_from
	for d in doors:
		var a := float(d) - SIDE_DOOR * 0.5
		if a > z:
			_box(Vector3(x, wy, (z + a) * 0.5), Vector3(1, wall_h, a - z))
		_box(Vector3(x, wy - wall_h * 0.5 - 0.5, float(d)), Vector3(1, 1, SIDE_DOOR), _floor_mat)
		z = float(d) + SIDE_DOOR * 0.5
	if z_to > z:
		_box(Vector3(x, wy, (z + z_to) * 0.5), Vector3(1, wall_h, z_to - z))

## A run of plinth along an axis from `a` to `b` (metres along it), cut where
## a doorway opens (`holes`: [from, to] spans). The old game laid it right
## across every doorway: a kerb the server never had, drawn where everyone
## walks.
func _plinth_run(fixed: Vector3, along_x: bool, a: float, b: float, holes: Array, depth: float,
		material: Material = null, height: float = 0.5) -> void:
	if material == null:
		material = _trim
	var spans: Array = [[a, b]]
	for h in holes:
		var out: Array = []
		for s in spans:
			if float(h[1]) <= float(s[0]) or float(h[0]) >= float(s[1]):
				out.append(s)
				continue
			if float(h[0]) > float(s[0]):
				out.append([s[0], h[0]])
			if float(h[1]) < float(s[1]):
				out.append([h[1], s[1]])
		spans = out
	for s in spans:
		var length := float(s[1]) - float(s[0])
		if length < 0.2:
			continue
		var mid := (float(s[0]) + float(s[1])) * 0.5
		if along_x:
			_deco(Vector3(mid, fixed.y, fixed.z), Vector3(length, height, depth), material)
		else:
			_deco(Vector3(fixed.x, fixed.y, mid), Vector3(depth, height, length), material)

## Dressed stone on a plain room: a plinth along every wall (open at the
## doorways) under a base course of rougher stone, pilasters every `bay`
## metres down the long walls with a capital at the springing, and a cornice
## where wall meets vault. Returns the z of every pilaster pair: the arched
## ribs of the vault spring from them (_ceiling).
func _dress_room(center: Vector2, size: Vector2, fy: float, open_side: int, side_doors: Array,
		gaps: Dictionary, door: float) -> Array:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var course_h := 0.8
	for side in [-1.0, 1.0]:
		if int(side) != open_side:
			var holes: Array = []
			for d in _doors_on(side_doors, int(side)):
				holes.append([float(d) - SIDE_DOOR * 0.5, float(d) + SIDE_DOOR * 0.5])
			_plinth_run(Vector3(center.x + side * (hx - 0.15), fy + 0.25, 0), false, center.y - hz, center.y + hz, holes, 0.3)
			_plinth_run(Vector3(center.x + side * (hx - 0.06), fy + 0.5 + course_h * 0.5, 0), false, center.y - hz, center.y + hz,
				holes, 0.12, _base, course_h)
			_deco(Vector3(center.x + side * (hx - 0.2), fy + wall_h - 0.3, center.y), Vector3(0.4, 0.6, size.y), _trim)
		var z_holes: Array = []
		if bool(gaps.get(side, false)):
			z_holes.append([center.x - door * 0.5, center.x + door * 0.5])
		_plinth_run(Vector3(0, fy + 0.25, center.y + side * (hz - 0.15)), true, center.x - hx, center.x + hx, z_holes, 0.3)
		_plinth_run(Vector3(0, fy + 0.5 + course_h * 0.5, center.y + side * (hz - 0.06)), true, center.x - hx, center.x + hx,
			z_holes, 0.12, _base, course_h)
	var ribs: Array = []
	if bay <= 0.0:
		return ribs
	var count := int(floor(size.y / bay))
	for i in range(1, count + 1):
		var z := center.y + hz - i * bay
		if z <= center.y - hz + 0.5:
			break
		var stood := 0
		for side in [-1.0, 1.0]:
			var in_door := _doors_on(side_doors, int(side)).any(func(d): return absf(float(d) - z) < SIDE_DOOR * 0.5 + 0.5)
			if int(side) != open_side and not in_door:
				_solid(Vector3(center.x + side * (hx - 0.35), fy + wall_h * 0.5, z), Vector3(0.7, wall_h, 0.9), _trim,
					"pilaster at (%.1f, %.1f): drawn 0.7 m proud of the wall, no collider" % [center.x + side * (hx - 0.35), z])
				# its capital: a moulded block at the springing, above every head
				_deco(Vector3(center.x + side * (hx - 0.45), fy + wall_h - 0.35, z), Vector3(0.9, 0.5, 1.15), _trim)
				stood += 1
		if stood > 0:
			ribs.append(z)
	return ribs

# --------------------------------------------------------------- ceilings

## What closes a room overhead: `center`/`size` (x, z) the room's inner
## area between its walls' faces, `spring` the walls' top (world y). The
## kind is `ceiling` (barrel, timber, rock). A frieze of stone runs along the
## wall lines over the springing, so no doorway leaves a slot open to the
## dark between two rooms' ceilings.
func _ceiling(center: Vector2, size: Vector2, spring: float, ribs: Array = []) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var frieze := 2.0 if ceiling == "timber" else 0.8
	for side in [-1.0, 1.0]:
		_deco(Vector3(center.x + side * (hx + 0.5), spring + frieze * 0.5, center.y), Vector3(1.0, frieze, size.y + 2.0), _stone)
		_deco(Vector3(center.x, spring + frieze * 0.5, center.y + side * (hz + 0.5)), Vector3(size.x, frieze, 1.0), _stone)
	if size.x * size.y >= 250.0 and fill_energy > 0.0:
		# a soft bounce from the room's own fires: no specular, no hot spot
		var fill := _light(Vector3(center.x, spring - 1.0, center.y), fill_color, fill_energy,
			Vector2(size.x, size.y).length() * 0.62)
		fill.light_specular = 0.0
		fill.omni_attenuation = 0.6
	match ceiling:
		"timber":
			_timber(center, size, spring)
		"rock":
			_rock_ceiling(center, size, spring)
		_:
			_barrel(center, size, spring, ribs)

## A barrel vault along the room's longer side: a full half-round over a
## corridor, a segmental arch (rising at most vault_rise_max) over a hall;
## the half-moon lunettes close its ends over the end walls; an arched rib
## springs from every pilaster pair (`ribs`: their z) when it runs along z.
func _barrel(center: Vector2, size: Vector2, spring: float, ribs: Array) -> void:
	var along_z := size.y >= size.x
	var span := size.x if along_z else size.y
	var length := size.y if along_z else size.x
	var rise := span * 0.5 if span <= 10.5 else clampf(span * 0.24, 5.0, vault_rise_max)
	var profile := Shapes.arc_profile(span, rise)
	var origin := Vector3(center.x, spring, center.y)
	var n := maxi(1, ceili(length / PIECE - 0.01))
	for k in n:
		var l0 := -length * 0.5 + length * float(k) / n
		var l1 := -length * 0.5 + length * float(k + 1) / n
		Shapes.origin = Shapes.vault_point(origin, along_z, 0.0, rise * 0.5, (l0 + l1) * 0.5)
		_add_mesh(trim, Shapes.vault_shell(origin, along_z, profile, l0, l1, _vault_uv), "Vault", _vault_uv)
	for end in [-1.0, 1.0]:
		Shapes.origin = Shapes.vault_point(origin, along_z, 0.0, rise * 0.5, end * length * 0.5)
		_add_mesh(trim, Shapes.lunette(origin, along_z, profile, end * length * 0.5, -end, _vault_uv), "Lunette", _vault_uv)
	if along_z:
		for z in ribs:
			Shapes.origin = Shapes.vault_point(origin, true, 0.0, rise * 0.5, float(z) - center.y)
			_add_mesh(trim, Shapes.rib(origin, true, profile, float(z) - center.y, 0.55, 0.38, _trim_uv), "Rib", _trim_uv)
	# a ridge rib down the crown of a long vault
	if length >= 14.0:
		var at := Shapes.vault_point(origin, along_z, 0.0, rise - 0.1, 0.0)
		_deco(at, Vector3(0.45, 0.24, length) if along_z else Vector3(length, 0.24, 0.45), _trim)

## Dark timber: beams across the short span every 2.4 m on corbels, over a
## boarded ceiling 2 m above the springing.
func _timber(center: Vector2, size: Vector2, spring: float) -> void:
	var along_z := size.y >= size.x
	var span := size.x if along_z else size.y
	var length := size.y if along_z else size.x
	_deco(Vector3(center.x, spring + 2.15, center.y), Vector3(size.x + 2.0, 0.3, size.y + 2.0), _boards)
	# wall plates along the long walls
	for side in [-1.0, 1.0]:
		var plate := Vector3(center.x + side * (span * 0.5 - 0.2), spring + 0.25, center.y) if along_z 			else Vector3(center.x, spring + 0.25, center.y + side * (span * 0.5 - 0.2))
		_deco(plate, Vector3(0.4, 0.5, length) if along_z else Vector3(length, 0.5, 0.4), _beam)
	var count := maxi(1, floori(length / 2.4))
	for i in count:
		var l := -length * 0.5 + (float(i) + 0.5) * length / count
		var at := Vector3(center.x, spring + 0.9, center.y + l) if along_z else Vector3(center.x + l, spring + 0.9, center.y)
		_deco(at, Vector3(span, 0.5, 0.42) if along_z else Vector3(0.42, 0.5, span), _beam)
		# corbels under each beam's ends
		for side in [-1.0, 1.0]:
			var c := Vector3(center.x + side * (span * 0.5 - 0.35), spring - 0.2, center.y + l) if along_z 				else Vector3(center.x + l, spring - 0.2, center.y + side * (span * 0.5 - 0.35))
			_deco(c, Vector3(0.7, 0.5, 0.5) if along_z else Vector3(0.5, 0.5, 0.7), _trim)

## A cave's rough dome: the room's area and a margin into the walls, rising
## up to a fifth of the span, in PIECE chunks.
func _rock_ceiling(center: Vector2, size: Vector2, spring: float) -> void:
	var area := Rect2(center - size * 0.5, size)
	var rise := clampf(minf(size.x, size.y) * 0.2, 1.5, 5.0)
	_rock_rooms.append({"area": area, "spring": spring, "rise": rise})
	var x0 := area.position.x - 0.8
	var z0 := area.position.y - 0.8
	var w := size.x + 1.6
	var d := size.y + 1.6
	var nx := maxi(1, ceili(w / PIECE - 0.01))
	var nz := maxi(1, ceili(d / PIECE - 0.01))
	for i in nx:
		for j in nz:
			Shapes.origin = Vector3(x0 + w * (i + 0.5) / nx, spring, z0 + d * (j + 0.5) / nz)
			_add_mesh(trim, Shapes.rock_ceiling(_noise_img, area, spring, rise, x0 + w * i / nx, x0 + w * (i + 1) / nx,
				z0 + d * j / nz, z0 + d * (j + 1) / nz, 0.9, _rock_uv), "RockCeiling", _rock_uv)

## The rock ceiling's underside over (x, z) (view space), or INF where none.
func rock_ceiling_at(x: float, z: float) -> float:
	for r: Dictionary in _rock_rooms:
		var area: Rect2 = r["area"]
		if area.has_point(Vector2(x, z)):
			return Shapes.rock_height(_noise_img, area, float(r["spring"]), float(r["rise"]), x, z)
	return INF

# --------------------------------------------------------------- dressing

## Where a way out of the copy stands: a pool of light turning on the floor,
## the Waystake's aura standing over it and lights lifting off it. One for
## every portal of this map (maps.json), at its trigger and nearly as wide.
func _portal_sigils() -> void:
	var maps: Variant = RealmContent.table("maps")
	if not (maps is Dictionary):
		return
	for portal: Dictionary in (maps as Dictionary).get("portals", []):
		if String(portal.get("map_id", "")) != map_id:
			continue
		var trigger: Dictionary = portal.get("trigger", {})
		var c: Array = trigger.get("center", [])
		if c.size() != 3:
			continue
		_portal_ring(Vector3(float(c[0]), floor_y + 0.05, float(c[2])), float(trigger.get("radius", 2.5)) * 0.92)

func _portal_ring(at: Vector3, radius: float) -> void:
	var root := Node3D.new()
	root.name = "Portal"
	root.position = at
	dressing.add_child(root)
	var pool_mat := ShaderMaterial.new()
	pool_mat.shader = PORTAL_POOL
	pool_mat.set_shader_parameter("tint", PORTAL_TINT)
	if ResourceLoader.exists(PORTAL_NOISE):
		pool_mat.set_shader_parameter("noise", load(PORTAL_NOISE))
	if ResourceLoader.exists(PORTAL_RIPPLE):
		pool_mat.set_shader_parameter("ripple", load(PORTAL_RIPPLE))
	var plane := PlaneMesh.new()
	plane.size = Vector2(radius, radius) * 2.0
	plane.material = pool_mat
	var pool := MeshInstance3D.new()
	pool.name = "Pool"
	pool.mesh = plane
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pool)
	# the light standing over it: one tall column and two lesser beside it
	var spots := PackedVector3Array([Vector3.ZERO, Vector3(radius * 0.42, 0, radius * 0.18), Vector3(-radius * 0.36, 0, -radius * 0.3)])
	var aura := StandingCards.make(PORTAL_AURA, spots, Vector2(radius * 1.1, radius * 1.45), Vector2(2.2, 3.0), 18.0,
		Color(1, 1, 1), int(absf(at.z) * 10.0) + 7)
	if aura != null:
		aura.name = "Aura"
		(aura.material_override as ShaderMaterial).set_shader_parameter("lick", 0.06)
		# faint enough to stand in: whoever is on the pool stays visible
		(aura.material_override as ShaderMaterial).set_shader_parameter("intensity", 0.42)
		root.add_child(aura)
	if DisplayServer.get_name() != "headless":
		var motes := RisingMotes.make(radius * 0.86, 4.0, PORTAL_TINT, 26, 2.4, Vector2(0.25, 1.0), Vector2(0.008, 0.02))
		root.add_child(motes)
		motes.emitting = true

## A wall torch: its light (flickering), a living flame (the castle's
## flipbook card; a cold or green torch keeps its hue) in an iron cup on a
## bracket. A torch authored off the wall is set 0.4 m from the nearest wall
## face within reach (the old layout left some hanging in the air).
func _torch(at: Vector3, color: Color = Color(1.0, 0.68, 0.35), energy: float = 1.6, reach: float = 11.0) -> void:
	var wall := _nearest_wall(at, 2.6)
	if not wall.is_empty():
		at = (wall["point"] as Vector3) + (wall["normal"] as Vector3) * 0.4
	var light := _light(at + (wall.get("normal", Vector3.ZERO) as Vector3) * 0.15, color, energy * 1.15, reach * 1.1)
	_flicker.append([light, light.light_energy, at.x * 1.7 + at.z * 0.9])
	var warm := color.r > 0.9 and color.g < 0.8
	CastleFire.make(dressing, at + Vector3(0, 0.12, 0), Vector2(0.42, 0.68), Color(1, 1, 1) if warm else color, 1.5)
	var cup := MeshInstance3D.new()
	cup.name = "Cup"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.2
	cm.bottom_radius = 0.08
	cm.height = 0.3
	cm.radial_segments = 10
	cm.material = _iron
	cup.mesh = cm
	cup.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cup.position = at - Vector3(0, 0.25, 0)
	dressing.add_child(cup)
	if not wall.is_empty():
		# the bracket: an arm from the wall to the cup, a stay under it and
		# the plate it is bolted through
		var n: Vector3 = wall["normal"]
		_iron_bar(at - Vector3(0, 0.36, 0) - n * 0.4, at - Vector3(0, 0.36, 0), 0.05)
		_iron_bar(at - Vector3(0, 0.95, 0) - n * 0.4, at - Vector3(0, 0.4, 0) - n * 0.12, 0.04)
		_iron_bar(at - Vector3(0, 0.55, 0) - n * 0.38, at - Vector3(0, 0.12, 0) - n * 0.38, 0.09)

## An iron bar from `a` to `b`, `thick` square (batched with the cups).
func _iron_bar(a: Vector3, b: Vector3, thick: float) -> void:
	var length := a.distance_to(b)
	if length < 0.01:
		return
	var bar := MeshInstance3D.new()
	bar.name = "Cup"
	var bm := BoxMesh.new()
	bm.size = Vector3(thick, thick, length)
	bm.material = _iron
	bar.mesh = bm
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bar.position = (a + b) * 0.5
	var dir := (b - a) / length
	var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	bar.basis = Basis.looking_at(dir, up)
	dressing.add_child(bar)

## The nearest wall face (a wall box of the structure, the height of `at`
## inside it) within `reach` metres on the ground plane:
## {point: on the face, normal: out of it} or {}.
func _nearest_wall(at: Vector3, reach: float) -> Dictionary:
	var best := {}
	var best_d := reach
	for box: AABB in _walls:
		if at.y < box.position.y or at.y > box.end.y:
			continue
		var inside_x := at.x >= box.position.x and at.x <= box.end.x
		var inside_z := at.z >= box.position.z and at.z <= box.end.z
		if inside_z and not inside_x:
			var face := box.position.x if at.x < box.position.x else box.end.x
			var d := absf(at.x - face)
			if d < best_d:
				best_d = d
				best = {"point": Vector3(face, at.y, at.z), "normal": Vector3(signf(at.x - face), 0, 0)}
		elif inside_x and not inside_z:
			var face := box.position.z if at.z < box.position.z else box.end.z
			var d := absf(at.z - face)
			if d < best_d:
				best_d = d
				best = {"point": Vector3(at.x, at.y, face), "normal": Vector3(0, 0, signf(at.z - face))}
	return best

func _light(at: Vector3, color: Color, energy: float, reach: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = at
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	light.omni_attenuation = 1.1
	light.shadow_enabled = false
	dressing.add_child(light)
	_lights += 1
	return light

## The flames' light breathes: two slow waves and a quick one per light, out
## of phase with its neighbours (no node per light: one pass a frame).
func _process(delta: float) -> void:
	_flicker_t += delta
	var t := _flicker_t
	for f: Array in _flicker:
		var light := f[0] as OmniLight3D
		var ph := float(f[2])
		var k := 1.0 + 0.09 * sin(t * 2.1 + ph) + 0.06 * sin(t * 5.3 + ph * 1.7) + 0.04 * sin(t * 11.7 + ph * 2.3)
		light.light_energy = float(f[1]) * k

## A standing brazier: an iron bowl on three legs (on a stone drum where
## `drum`), its fire (the flipbook card), embers lifting off it and its
## flickering light. A solid: its box goes to world/patches.
func _brazier(at: Vector3, color: Color = Color(1.0, 0.62, 0.3), energy: float = 2.4, reach: float = 13.0,
		drum: bool = false) -> void:
	var base := 0.0
	if drum:
		base = 0.55
		var d := MeshInstance3D.new()
		var dm := CylinderMesh.new()
		dm.top_radius = 0.5
		dm.bottom_radius = 0.56
		dm.height = base
		dm.radial_segments = 12
		dm.material = _trim
		d.mesh = dm
		d.position = at + Vector3(0, base * 0.5, 0)
		trim.add_child(d)
	var top := at + Vector3(0, base + 1.0, 0)
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.4
		var foot := at + Vector3(cos(a) * 0.38, base, sin(a) * 0.38)
		_iron_bar(foot, top + Vector3(cos(a) * 0.22, -0.18, sin(a) * 0.22), 0.06)
	var bowl := MeshInstance3D.new()
	bowl.name = "Cup"
	var bm := CylinderMesh.new()
	bm.top_radius = 0.48
	bm.bottom_radius = 0.22
	bm.height = 0.32
	bm.radial_segments = 14
	bm.material = _iron
	bowl.mesh = bm
	bowl.position = top - Vector3(0, 0.08, 0)
	dressing.add_child(bowl)
	var warm := color.r > 0.9 and color.g < 0.8
	CastleFire.make(dressing, top + Vector3(0, 0.05, 0), Vector2(0.85, 1.15), Color(1, 1, 1) if warm else color, 1.7)
	var light := _light(top + Vector3(0, 0.7, 0), color, energy, reach)
	_flicker.append([light, energy, at.x * 0.7 + at.z * 1.3])
	if DisplayServer.get_name() != "headless":
		var embers := RisingMotes.make(0.28, 4.0, color.lerp(Color(1.0, 0.55, 0.2), 0.5), 14, 2.2, Vector2(0.5, 1.3), Vector2(0.01, 0.022))
		embers.position = top + Vector3(0, 0.15, 0)
		dressing.add_child(embers)
		embers.emitting = true
	var h := base + 1.15
	var half := 0.5 if drum else 0.42
	solids.append({"note": "brazier at (%.1f, %.1f): drawn, no collider" % [at.x, at.z],
		"center": [snappedf(at.x, 0.01), snappedf(at.y + h * 0.5, 0.01), snappedf(at.z, 0.01)],
		"half": [half, snappedf(h * 0.5, 0.01), half], "yaw_deg": 0})

## A plain cloth hung on a wall from an iron rod: `at` near the face
## (_nearest_wall finds it; the rod's height), `size` (width, drop), its dye
## and a lighter woven band (alpha 0: none). House-neutral colours only.
func _banner(at: Vector3, size: Vector2, dye: Color, band: Color = Color(0, 0, 0, 0)) -> void:
	var wall := _nearest_wall(at, 3.0)
	if wall.is_empty():
		return
	var n: Vector3 = wall["normal"]
	var rod := (wall["point"] as Vector3) + n * 0.12
	var quad := QuadMesh.new()
	quad.size = size
	quad.subdivide_width = maxi(6, int(size.x * 6.0))
	quad.subdivide_depth = maxi(6, int(size.y * 2.0))
	var m := ShaderMaterial.new()
	m.shader = BANNER
	m.set_shader_parameter("folds", maxf(2.0, roundf(size.x * 1.6)))
	m.set_shader_parameter("weave_tex", load(HESSIAN % "diff"))
	m.set_shader_parameter("weave_normal", load(HESSIAN % "nor_gl"))
	m.set_shader_parameter("noise_tex", load(NOISE))
	m.set_shader_parameter("dye", dye)
	m.set_shader_parameter("band", band if band.a > 0.0 else dye)
	m.set_shader_parameter("band_at", Vector2(0.8, 0.87) if band.a > 0.0 else Vector2.ZERO)
	m.set_shader_parameter("size", size)
	m.set_shader_parameter("seed", fposmod(rod.x * 0.37 + rod.z * 0.21, 1.0))
	quad.material = m
	var cloth := MeshInstance3D.new()
	cloth.name = "Banner"
	cloth.mesh = quad
	cloth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the quad faces +z: turned to face out of the wall, hanging from the rod
	cloth.basis = Basis.looking_at(-n, Vector3.UP)
	cloth.position = rod - Vector3(0, size.y * 0.5 + 0.06, 0)
	dressing.add_child(cloth)
	var side := n.cross(Vector3.UP).normalized()
	_iron_bar(rod - side * (size.x * 0.5 + 0.18), rod + side * (size.x * 0.5 + 0.18), 0.05)
	for e in [-1.0, 1.0]:
		_iron_bar(rod + side * e * (size.x * 0.5 + 0.1) - n * 0.12, rod + side * e * (size.x * 0.5 + 0.1), 0.04)

## A fire basket hung over a hall: an iron bowl on three chains from the
## vault's crown, its fire, embers and a warm light reaching the whole floor
## (above every head: drawn only).
func _fire_basket(at: Vector3, crown: float, color: Color = Color(1.0, 0.64, 0.34), reach: float = 30.0) -> void:
	for i in 3:
		var a := TAU * float(i) / 3.0
		_chain(PackedVector3Array([Vector3(at.x + cos(a) * 0.25, crown, at.z + sin(a) * 0.25),
			at + Vector3(cos(a) * 0.62, 0.15, sin(a) * 0.62)]), 0.16)
	var bowl := MeshInstance3D.new()
	bowl.name = "Cup"
	var bm := CylinderMesh.new()
	bm.top_radius = 0.75
	bm.bottom_radius = 0.3
	bm.height = 0.45
	bm.radial_segments = 16
	bm.material = _iron
	bowl.mesh = bm
	bowl.position = at
	dressing.add_child(bowl)
	CastleFire.make(dressing, at + Vector3(0, 0.15, 0), Vector2(1.3, 1.7), Color(1, 1, 1), 1.8)
	var light := _light(at + Vector3(0, 1.0, 0), color, 2.6, reach)
	_flicker.append([light, 2.6, 0.4])
	if DisplayServer.get_name() != "headless":
		var embers := RisingMotes.make(0.5, 4.0, Color(1.0, 0.55, 0.22), 22, 2.8, Vector2(0.6, 1.5), Vector2(0.012, 0.026))
		embers.position = at + Vector3(0, 0.25, 0)
		dressing.add_child(embers)
		embers.emitting = true

## Iron chain along `points` (view space): hung from a vault, slung between
## wall rings. Drawn only: a chain hangs above every head or lies on a wall.
func _chain(points: PackedVector3Array, link: float = 0.13) -> void:
	Shapes.origin = points[0] if not points.is_empty() else Vector3.ZERO
	_add_mesh(dressing, Shapes.chain(points, link, _iron), "Chain", _iron)

## A heap of fallen stone against a wall or in a corner: `count` rough
## chunks within `radius` of `at`, none higher than `top` (low enough to step
## over; a heap that would stop a body is a solid and goes to the patches).
func _rubble(at: Vector3, radius: float, count: int, top: float = 0.32, seed_: int = 0) -> void:
	if _chunks.is_empty():
		for k in 5:
			_chunks.append(Shapes.chunk(9001 + k))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_ if seed_ != 0 else int(absf(at.x * 131.0 + at.z * 71.0)) + 3
	for i in count:
		var r := radius * sqrt(rng.randf())
		var a := rng.randf() * TAU
		var p := at + Vector3(cos(a) * r, 0.0, sin(a) * r)
		var falloff := 1.0 - 0.6 * r / maxf(radius, 0.01)
		var s := rng.randf_range(0.18, 0.55) * falloff
		var h := minf(s * 0.7, top)
		var basis := Basis.from_euler(Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3))) 			.scaled(Vector3(s, h / 0.7, s * rng.randf_range(0.8, 1.2)))
		# sunk into the floor: it lies, it does not perch
		_batch(trim, "Rubble", _rubble_mat, Transform3D(basis, p + Vector3(0, h * 0.18, 0)), _chunks[rng.randi() % _chunks.size()])

## Orb webs (the caverns' cobweb card): each [at, facing (normal out of the
## web), size m] in view space, one MultiMesh.
func _webs(webs: Array, tint: Color = Color(0.7, 0.75, 0.8), opacity: float = 0.7) -> void:
	if webs.is_empty():
		return
	var mat := ShaderMaterial.new()
	mat.shader = WEB_SHADER
	mat.set_shader_parameter("web", load(WEB_TEX))
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("silk", tint * 0.75)
	mat.set_shader_parameter("glint", 0.15)
	mat.set_shader_parameter("opacity", opacity)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = mat
	mm.mesh = quad
	mm.instance_count = webs.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = webs.size() * 31 + int(floor_y)
	for i in webs.size():
		var w: Array = webs[i]
		var facing: Vector3 = (w[1] as Vector3).normalized()
		var up := Vector3.UP if absf(facing.y) < 0.9 else Vector3.FORWARD
		var basis := Basis.looking_at(-facing, up) * Basis(Vector3.FORWARD, rng.randf() * TAU)
		var s := float(w[2])
		mm.set_instance_transform(i, Transform3D(basis.scaled_local(Vector3(s, s, 1)), w[0]))
		mm.set_instance_custom_data(i, Color(rng.randf(), 0, 0, 0))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Webs"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dressing.add_child(inst)

## An authored model as static scenery, standing in its bind pose.
func _prop(path: String, at: Vector3, yaw_deg: float = 0.0, scale_by: float = 1.0) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("dungeon %s: %s is missing" % [map_id, path])
		return null
	var node: Node3D = (load(path) as PackedScene).instantiate()
	node.position = at
	node.rotation.y = deg_to_rad(yaw_deg)
	node.scale = Vector3.ONE * scale_by
	dressing.add_child(node)
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

## A prop that is a solid the server has no collider for: drawn, and its
## solid core recorded as a patch box: `core` of the model's horizontal
## extent (scaled and turned; the trunk of a spire rather than its spread
## base), from its foot to its top.
func _solid_prop(path: String, at: Vector3, yaw_deg: float, scale_by: float, note: String, core: float = 0.8) -> Node3D:
	var node := _prop(path, at, yaw_deg, scale_by)
	if node == null:
		return null
	var box := _model_bounds(node)
	if box.size == Vector3.ZERO:
		return node
	var half := Vector3(box.size.x * 0.5 * core, box.size.y * 0.5, box.size.z * 0.5 * core)
	if half.x <= 0.05 or half.z <= 0.05:
		return node
	var c := box.get_center()
	solids.append({"note": note, "center": [snappedf(c.x, 0.01), snappedf(c.y, 0.01), snappedf(c.z, 0.01)],
		"half": [snappedf(half.x, 0.01), snappedf(half.y, 0.01), snappedf(half.z, 0.01)], "yaw_deg": 0})
	return node

## A placed model's solid parts as patch boxes: `parts` are rectangles in
## the mesh's own space, [x0, x1, z0, z1, top] (metres; the box rises from
## `down` metres under the mesh's origin to `top`). `xform` places the mesh
## (yaw and uniform scale).
static func part_solids(xform: Transform3D, parts: Array, down: float, note: String) -> Array:
	var out: Array = []
	var scale := xform.basis.x.length()
	var yaw := atan2(-xform.basis.x.z, xform.basis.x.x)
	var flat := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale), xform.origin)
	for part: Array in parts:
		var bottom := -down / maxf(scale, 0.001)
		var top := float(part[4])
		var at := flat * Vector3((float(part[0]) + float(part[1])) * 0.5, (bottom + top) * 0.5,
			(float(part[2]) + float(part[3])) * 0.5)
		out.append({"note": "%s (part %d)" % [note, out.size() + 1],
			"center": [snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01)],
			"half": [snappedf((float(part[1]) - float(part[0])) * 0.5 * scale, 0.01), snappedf((top - bottom) * 0.5 * scale, 0.01),
				snappedf((float(part[3]) - float(part[2])) * 0.5 * scale, 0.01)],
			"yaw_deg": snappedf(rad_to_deg(yaw), 0.01)})
	return out

## A mesh's top surface sampled on an n x n grid over its footprint (mesh
## space): each cell centre's highest point of the mesh (its triangles, and
## its vertices for cells no triangle lands on whole), then cells far under
## the median of their neighbours (a scan's cracks) raised to it. With
## `yaw` the grid is the mesh's space turned that much about its up axis (a
## model whose shape runs on a diagonal, a tent's ridge): the mesh turned by
## -yaw is sampled.
## {top: PackedFloat32Array (row z, column x; -INF off the mesh), n, box, yaw}.
static func top_raster(mesh: Mesh, n: int, yaw: float = 0.0) -> Dictionary:
	var turn := Transform3D(Basis(Vector3.UP, -yaw), Vector3.ZERO)
	var surfaces: Array = []
	var box := AABB()
	var first := true
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = turn * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
		surfaces.append([verts, arrays[Mesh.ARRAY_INDEX]])
		for v in verts:
			box = AABB(v, Vector3.ZERO) if first else box.expand(v)
			first = false
	if yaw == 0.0:
		box = mesh.get_aabb()
	var top := PackedFloat32Array()
	top.resize(n * n)
	top.fill(-INF)
	var cell := Vector2(box.size.x / n, box.size.z / n)
	for surface: Array in surfaces:
		var verts: PackedVector3Array = surface[0]
		var index: PackedInt32Array = surface[1] if surface[1] != null else PackedInt32Array()
		for v in verts:
			var at := clampi(floori((v.z - box.position.z) / cell.y), 0, n - 1) * n \
				+ clampi(floori((v.x - box.position.x) / cell.x), 0, n - 1)
			top[at] = maxf(top[at], v.y)
		var count := index.size() if not index.is_empty() else verts.size()
		for k in range(0, count - 2, 3):
			var a := verts[index[k] if not index.is_empty() else k]
			var b := verts[index[k + 1] if not index.is_empty() else k + 1]
			var c := verts[index[k + 2] if not index.is_empty() else k + 2]
			var a2 := Vector2(a.x, a.z)
			var b2 := Vector2(b.x, b.z)
			var c2 := Vector2(c.x, c.z)
			var area := (b2 - a2).cross(c2 - a2)
			if absf(area) < 1e-12:
				continue
			var i0 := clampi(floori((minf(a.x, minf(b.x, c.x)) - box.position.x) / cell.x), 0, n - 1)
			var i1 := clampi(floori((maxf(a.x, maxf(b.x, c.x)) - box.position.x) / cell.x), 0, n - 1)
			var j0 := clampi(floori((minf(a.z, minf(b.z, c.z)) - box.position.z) / cell.y), 0, n - 1)
			var j1 := clampi(floori((maxf(a.z, maxf(b.z, c.z)) - box.position.z) / cell.y), 0, n - 1)
			for i in range(i0, i1 + 1):
				for j in range(j0, j1 + 1):
					var p := Vector2(box.position.x + (i + 0.5) * cell.x, box.position.z + (j + 0.5) * cell.y)
					var w1 := (c2 - b2).cross(p - b2) / area
					var w2 := (a2 - c2).cross(p - c2) / area
					var w3 := 1.0 - w1 - w2
					if w1 < -1e-5 or w2 < -1e-5 or w3 < -1e-5:
						continue
					top[j * n + i] = maxf(top[j * n + i], w1 * a.y + w2 * b.y + w3 * c.y)
	for pass_ in 3:
		var filled := top.duplicate()
		for j in range(1, n - 1):
			for i in range(1, n - 1):
				var around: Array = []
				for dj in [-1, 0, 1]:
					for di in [-1, 0, 1]:
						if di != 0 or dj != 0:
							around.append(top[(j + dj) * n + i + di])
				around.sort()
				var median: float = around[4]
				if median > -INF and top[j * n + i] < median - box.size.y * 0.1:
					filled[j * n + i] = median
		top = filled
	return {"top": top, "n": n, "box": box, "yaw": yaw}

## The largest rectangle of a raster's cells whose top reaches `t`, as
## mesh-space [x0, x1, z0, z1] from cell centre to cell centre (half a cell
## inside), or [] when none is three cells across both ways.
static func raster_rect(raster: Dictionary, t: float) -> Array:
	var top: PackedFloat32Array = raster["top"]
	var n: int = raster["n"]
	var box: AABB = raster["box"]
	var heights := PackedInt32Array()
	heights.resize(n)
	var best := 0
	var found: Array = []
	for j in n:
		for i in n:
			heights[i] = heights[i] + 1 if top[j * n + i] >= t else 0
		for i in n:
			var h := heights[i]
			if h == 0:
				continue
			var l := i
			while l > 0 and heights[l - 1] >= h:
				l -= 1
			var r := i
			while r < n - 1 and heights[r + 1] >= h:
				r += 1
			if r - l >= 2 and h >= 3 and (r - l) * (h - 1) > best:
				best = (r - l) * (h - 1)
				found = [l, r, j - h + 1, j]
	if found.is_empty():
		return []
	var cx := box.size.x / n
	var cz := box.size.z / n
	return [box.position.x + (found[0] + 0.5) * cx, box.position.x + (found[1] + 0.5) * cx,
		box.position.z + (found[2] + 0.5) * cz, box.position.z + (found[3] + 0.5) * cz]

## A placed model's solid as stacked upright patch boxes inside its drawn
## shape: for each band [from, to] (fractions of the mesh's height from its
## foot) the largest rectangle under its top surface at the band's top
## (raster_rect), from the band's bottom (the first from the mesh's foot) to
## that top. `xform` places the mesh (yaw, uniform scale, a slight tilt: each
## box stands on the tilted axis, narrowed by what the tilt leans over its
## height; a raster sampled turned (top_raster's `yaw`) turns its boxes the
## same). Bands stop at the first one the shape is too thin for.
static func raster_solids(raster: Dictionary, xform: Transform3D, bands: Array, note: String) -> Array:
	var out: Array = []
	var box: AABB = raster["box"]
	var turn := float(raster.get("yaw", 0.0))
	xform = xform * Transform3D(Basis(Vector3.UP, turn), Vector3.ZERO)
	var scale := xform.basis.x.length()
	var yaw := atan2(-xform.basis.x.z, xform.basis.x.x)
	var lean := tan(acos(clampf(xform.basis.y.normalized().y, -1.0, 1.0)))
	for band: Array in bands:
		var y0 := box.position.y + box.size.y * float(band[0])
		var y1 := box.position.y + box.size.y * float(band[1])
		var rect := raster_rect(raster, y1)
		if rect.is_empty():
			break
		var half_y := (y1 - y0) * 0.5 * scale
		var hx := (float(rect[1]) - float(rect[0])) * 0.5 * scale - lean * half_y
		var hz := (float(rect[3]) - float(rect[2])) * 0.5 * scale - lean * half_y
		if hx < 0.05 or hz < 0.05:
			break
		var at := xform * Vector3((float(rect[0]) + float(rect[1])) * 0.5, (y0 + y1) * 0.5,
			(float(rect[2]) + float(rect[3])) * 0.5)
		out.append({"note": "%s (band %.0f-%.0f %%)" % [note, float(band[0]) * 100.0, float(band[1]) * 100.0],
			"center": [snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01)],
			"half": [snappedf(hx, 0.01), snappedf(half_y, 0.01), snappedf(hz, 0.01)],
			"yaw_deg": snappedf(rad_to_deg(yaw), 0.01)})
	return out

## A placed baked stalagmite (a `_prop` of cavern_stalag) kept in
## `stalagmites` for map_solids.gd to box from its mesh.
func _stalagmite(node: Node3D, note: String) -> void:
	if node == null:
		return
	var found := node.find_children("*", "MeshInstance3D", true, false)
	if found.is_empty():
		return
	var mi := found[0] as MeshInstance3D
	stalagmites.append({"xform": global_transform.affine_inverse() * mi.global_transform, "note": note})

## A model's bounds in this view's space (axis aligned; the view is in the
## tree, so a skinned model's nodes give their real placement).
func _model_bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var to_view := global_transform.affine_inverse()
	for vi in node.find_children("*", "VisualInstance3D", true, false):
		var v := vi as VisualInstance3D
		var box := (to_view * v.global_transform) * v.get_aabb()
		# a skinned body is where its bones put it, not its mesh's own space
		var skeleton := (v as MeshInstance3D).get_node_or_null((v as MeshInstance3D).skeleton) as Skeleton3D 			if v is MeshInstance3D and (v as MeshInstance3D).skin != null else null
		if skeleton != null and skeleton.get_bone_count() > 0:
			var bones := to_view * skeleton.global_transform
			box = AABB(bones * skeleton.get_bone_global_pose(0).origin, Vector3.ZERO)
			for b in skeleton.get_bone_count():
				box = box.expand(bones * skeleton.get_bone_global_pose(b).origin)
			box = box.grow(0.12)
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out
