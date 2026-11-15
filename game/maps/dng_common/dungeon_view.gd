extends Node3D

## Shared base of the drawn dungeon maps (Phase 6.3): the old game's
## code-built dungeons (scripts/world/dungeons/dungeon_greybox.gd) drawn the
## way it drew them - dressed cold stone, plinths, pilasters and ribs, iron
## sconces with living flames, the ways out as pools of light - without any
## of its collision. main.gd instances a dungeon's scene at the copy's offset
## (the server keeps 8 copies 240 m apart) and calls setup(session, main).
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
##   Trim        what the old game drew with no collider: vaults, plinths,
##               cornices, ribs and pilasters (pilasters stand 0.7 m proud of
##               the wall: world/patches/<map>.json gives them their boxes)
##   Dressing    torches, props, the ways out, lights
##
## Low-preset look throughout (the old game's iGPU path): lite PBR, no
## shadows from the torches, glow and fog by the map's atmosphere.

const Kit = preload("res://maps/castle_interior/castle_kit.gd")
const StaticMerge = preload("res://maps/castle_interior/static_merge.gd")
const CastleFire = preload("res://maps/castle_interior/castle_fire.gd")
const StandingCards = preload("res://maps/dng_common/standing_cards.gd")
const PBR_SHADER := preload("res://assets/shaders/triplanar_pbr.gdshader")
const PORTAL_POOL := preload("res://assets/shaders/portal_pool.gdshader")
const PORTAL_NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const PORTAL_RIPPLE := "res://assets/vfx/atlases/ripple_blue_8x8_1k.png"
const PORTAL_AURA := "res://assets/vfx/atlases/waylink_aura_8x8_1k.png"
const PORTAL_TINT := Color(0.42, 0.72, 1.0)
const PBR_DIR := "res://assets/textures/pbr/%s/%s_%s_2k.jpg"

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

var structure: Node3D
var trim: Node3D
var dressing: Node3D
## What was built (the check prints it).
var built_stats: Dictionary = {}
## Drawn solids the old game gave no collider: [{note, center, half, yaw_deg}]
## in the map's own (pack) coordinates; tools write them as patches.
var solids: Array = []

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
	_materials()
	_build()
	_portal_sigils()
	var pieces := structure.get_child_count() + trim.get_child_count()
	built_stats["structure_batches"] = StaticMerge.merge(structure, structure.get_children(), "Stone", CELL)
	built_stats["trim_batches"] = StaticMerge.merge(trim, trim.get_children(), "Trim", CELL)
	var small: Array = dressing.get_children().filter(func(n): return n is MeshInstance3D and String(n.name) == "Cup")
	built_stats["cup_batches"] = StaticMerge.merge(dressing, small, "Cups", CELL)
	built_stats["pieces"] = pieces
	built_stats["lights"] = _lights
	built_stats["occluders"] = _occluders
	built_stats["solids"] = solids.size()
	built_stats["meshes"] = find_children("*", "GeometryInstance3D", true, false).size()
	built_stats["build_ms"] = Time.get_ticks_msec() - started

## The stone: the castle's cold kit (the dungeons are castle rooms). A map
## in other stone overrides this.
func _materials() -> void:
	_stone = Kit.kit_material("stone_cold")
	_floor_mat = Kit.kit_material("stone_floor")
	_vault = Kit.kit_material("stone_vault_cold")
	_trim = Kit.kit_material("trim_cold")

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
		_env.environment = environment_for(atmosphere)

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
	var m := ShaderMaterial.new()
	m.shader = PBR_SHADER
	m.set_shader_parameter("albedo_tex", load(PBR_DIR % [set_id, set_id, "diff"]))
	m.set_shader_parameter("normal_tex", load(PBR_DIR % [set_id, set_id, "nor_gl"]))
	m.set_shader_parameter("lite", true)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("world_scale", 1.0 / metres)
	return m

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

## A decorative box (the server has none).
func _deco(center: Vector3, size: Vector3, material: Material) -> void:
	_pieces(trim, center, size, material)

## A drawn solid the old game gave no collider: drawn as trim and recorded
## for world/patches/<map>.json.
func _solid(center: Vector3, size: Vector3, material: Material, note: String) -> void:
	_deco(center, size, material)
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
	# A ceiling keeps the light in (short of a joined room's).
	var lip := 1.0 if open_side != 0 else 2.0
	_deco(Vector3(center.x - float(open_side) * 0.5, fy + wall_h + 0.25, center.y), Vector3(size.x + lip, 0.5, size.y + 2), _vault)
	_dress_room(center, size, fy, open_side, side_doors, gaps, door)

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
func _plinth_run(fixed: Vector3, along_x: bool, a: float, b: float, holes: Array, depth: float) -> void:
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
			_deco(Vector3(mid, fixed.y, fixed.z), Vector3(length, 0.5, depth), _trim)
		else:
			_deco(Vector3(fixed.x, fixed.y, mid), Vector3(depth, 0.5, length), _trim)

## Dressed stone on a plain room: a plinth along every wall (open at the
## doorways), pilasters every `bay` metres down the long walls carrying
## transverse ribs under the ceiling, and a cornice where wall meets vault.
func _dress_room(center: Vector2, size: Vector2, fy: float, open_side: int, side_doors: Array,
		gaps: Dictionary, door: float) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	for side in [-1.0, 1.0]:
		if int(side) != open_side:
			var holes: Array = []
			for d in _doors_on(side_doors, int(side)):
				holes.append([float(d) - SIDE_DOOR * 0.5, float(d) + SIDE_DOOR * 0.5])
			_plinth_run(Vector3(center.x + side * (hx - 0.15), fy + 0.25, 0), false, center.y - hz, center.y + hz, holes, 0.3)
			_deco(Vector3(center.x + side * (hx - 0.2), fy + wall_h - 0.3, center.y), Vector3(0.4, 0.6, size.y), _trim)
		var z_holes: Array = []
		if bool(gaps.get(side, false)):
			z_holes.append([center.x - door * 0.5, center.x + door * 0.5])
		_plinth_run(Vector3(0, fy + 0.25, center.y + side * (hz - 0.15)), true, center.x - hx, center.x + hx, z_holes, 0.3)
	if bay <= 0.0:
		return
	var count := int(floor(size.y / bay))
	for i in range(1, count + 1):
		var z := center.y + hz - i * bay
		if z <= center.y - hz + 0.5:
			break
		for side in [-1.0, 1.0]:
			var in_door := _doors_on(side_doors, int(side)).any(func(d): return absf(float(d) - z) < SIDE_DOOR * 0.5 + 0.5)
			if int(side) != open_side and not in_door:
				_solid(Vector3(center.x + side * (hx - 0.35), fy + wall_h * 0.5, z), Vector3(0.7, wall_h, 0.9), _trim,
					"pilaster at (%.1f, %.1f): drawn 0.7 m proud of the wall, no collider" % [center.x + side * (hx - 0.35), z])
		_deco(Vector3(center.x, fy + wall_h - 0.2, z), Vector3(size.x, 0.4, 0.6), _trim)

# --------------------------------------------------------------- dressing

## Where a way out of the copy stands: a pool of light turning on the floor,
## the Waylink's aura standing over it and lights lifting off it. One for
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

## A wall torch: its light, a living flame (the castle's flipbook card; a cold
## or green torch keeps its hue) and the iron cup under it.
func _torch(at: Vector3, color: Color = Color(1.0, 0.68, 0.35), energy: float = 1.6, reach: float = 11.0) -> void:
	_light(at, color, energy, reach)
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

func _light(at: Vector3, color: Color, energy: float, reach: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = at
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	light.shadow_enabled = false
	dressing.add_child(light)
	_lights += 1
	return light

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

## A placed model's solid as patch boxes, one per height band: `layers` are
## [from, to, core] - the band as fractions of the mesh's height from its
## foot (below 0 reaches under it), `core` the share of its width the box
## keeps (a spire's flank narrows as it rises). `xform` places the mesh
## (yaw and uniform scale; a slight tilt is ignored); `bounds` is the mesh's
## own AABB. Map (pack) coordinates when `xform` is.
static func layered_solids(bounds: AABB, xform: Transform3D, layers: Array, note: String) -> Array:
	var out: Array = []
	var scale := xform.basis.x.length()
	var yaw := atan2(-xform.basis.x.z, xform.basis.x.x)
	var flat := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale), xform.origin)
	var c := bounds.get_center()
	for layer: Array in layers:
		var y0 := bounds.position.y + bounds.size.y * float(layer[0])
		var y1 := bounds.position.y + bounds.size.y * float(layer[1])
		var core := float(layer[2])
		var at := flat * Vector3(c.x, (y0 + y1) * 0.5, c.z)
		out.append({"note": "%s (band %.0f-%.0f %%)" % [note, float(layer[0]) * 100.0, float(layer[1]) * 100.0],
			"center": [snappedf(at.x, 0.01), snappedf(at.y, 0.01), snappedf(at.z, 0.01)],
			"half": [snappedf(bounds.size.x * 0.5 * core * scale, 0.01), snappedf((y1 - y0) * 0.5 * scale, 0.01),
				snappedf(bounds.size.z * 0.5 * core * scale, 0.01)],
			"yaw_deg": snappedf(rad_to_deg(yaw), 0.01)})
	return out

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

## A baked stalagmite's bands: a broad foot, the flank at eye height, the
## spire.
const STALAG_LAYERS := [[0.0, 0.17, 0.82], [0.17, 0.42, 0.6], [0.42, 0.85, 0.38]]

## A static prop's solid as layered patch boxes (layered_solids) in this
## view's (the pack's) coordinates.
func _solid_layers(node: Node3D, layers: Array, note: String) -> void:
	if node == null:
		return
	var found := node.find_children("*", "MeshInstance3D", true, false)
	if found.is_empty():
		return
	var mi := found[0] as MeshInstance3D
	var xform := global_transform.affine_inverse() * mi.global_transform
	solids.append_array(layered_solids(mi.mesh.get_aabb(), xform, layers, note))

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
