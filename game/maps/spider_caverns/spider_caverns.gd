extends Node3D

## The Blackweb Caverns drawn (Phase 6.3; maps.json `spider_caverns`): the
## old game's grinding map under the crypt (scripts/world/caverns/
## spider_caverns.gd) without its collision. main.gd instances this scene
## (the caverns hold no copies: offset 0) and calls setup(session, main).
##
## The ground is the heightfield the map server's pack was compiled from
## (assets/maps/spider_caverns: cavern_height.res, 513 x 513 samples at
## y 1550): its chunked render mesh (cavern_terrain.glb, LODs from the
## importer) under the cave ground shader (CC0 cave sets: rock on the slopes,
## web dust, bone gravel and slime from the splat, wall tops sunk into the
## dark). The dressing is the old one, room by room from cavern_layout.json
## and in the same seeded order (so every prop stands where it stood):
## stalagmite crags, dew webs, glowing mushrooms, drifting spores, bone heaps,
## egg clutches, venom pools under their mist (FlipbookFX), hanging cocoons,
## the explorers' camp, the stair up to the crypt and the two web gates of
## the Web Mother's Lair. The heights are read for placing it only.
##
## Drawn solids the old game gave no collider and no creature is placed near
## (the crypt stair's steps, the gates' arches, the camp's tent) are recorded
## in `solids`, the big stalagmite spires in `spires`
## (world/patches/spider_caverns.json gives them their boxes).
##
## Low-preset look: lite materials, no shadows, the old cave atmosphere at
## low (cold ambient, depth fog, no glow).

const LAYOUT_PATH := "res://assets/maps/spider_caverns/cavern_layout.json"
const TERRAIN_PATH := "res://assets/maps/spider_caverns/cavern_terrain.glb"
const HEIGHT_PATH := "res://assets/maps/spider_caverns/cavern_height.res"
const GROUND_SHADER := preload("res://assets/shaders/cavern_ground.gdshader")
const WEB_SHADER := preload("res://assets/shaders/cobweb.gdshader")
const SLIME_SHADER := preload("res://assets/shaders/slime_pool.gdshader")
const WEB_TEX := "res://assets/vfx/tex/cobweb_1024.png"
const PROP := "res://assets/models/caverns/cavern_%s.glb"
## The drifting spores (_spores, spore_mote.gdshader: a small core and a faint
## halo): their quad's size range (m), their glow's peak (alpha of the
## additive speck) and the camera distances they fade over (gone nearer than
## NEAR, whole beyond FAR).
const SPORE_SHADER := preload("res://assets/shaders/spore_mote.gdshader")
const SPORE_SCALE := Vector2(0.18, 0.32)
const SPORE_GLOW := 0.85
const SPORE_FADE_NEAR := 2.5
const SPORE_FADE_FAR := 7.0
const TEX := "res://assets/terrain/textures/%s.png"
const CastleFire = preload("res://maps/castle_interior/castle_fire.gd")
const DungeonView = preload("res://maps/dng_common/dungeon_view.gd")
## The baked arch (cavern_arch.glb, mesh space; its facade faces +z): two
## piers, and between them a stair of twelve 0.37 m steps climbing back
## along -z to a landing 4.3 m up under the arch's head, walled on both
## sides (the open iron gate leaf on the right). [x0, x1, z0, z1, top],
## all inside the drawn stone: the piers and passage walls are the largest
## rectangles under the mesh's top surface (DungeonView.top_raster, 96
## cells; a pier's finials and the head over the passage left open), the
## treads its upward faces (x -1.2..1.07), each a centimetre under its face.
const ARCH_PARTS := [
	[-2.39, -1.62, 0.91, 1.74, 4.82], [-1.86, -1.56, 0.2, 0.85, 3.59], [-2.16, -1.74, 1.8, 2.09, 3.18],
	[1.01, 1.72, 0.03, 1.45, 3.93], [1.78, 2.56, 1.33, 2.21, 4.22], [1.78, 1.96, 0.56, 1.27, 3.62],
	[1.84, 2.26, 2.27, 2.63, 2.96], [1.13, 1.3, 1.5, 2.09, 3.85],
	[-1.86, -1.26, -2.81, 0.15, 4.56], [1.13, 1.66, -2.81, 0.09, 4.54],
	[-1.2, 1.05, 1.27, 1.95, 0.36], [-1.2, 1.05, 0.86, 1.27, 0.72], [-1.2, 1.05, 0.42, 0.86, 1.11],
	[-1.2, 1.05, 0.03, 0.42, 1.48], [-1.2, 1.05, -0.27, 0.03, 1.86], [-1.2, 1.05, -0.56, -0.27, 2.23],
	[-1.2, 1.05, -0.94, -0.56, 2.55], [-1.2, 1.05, -1.31, -0.94, 2.91], [-1.2, 1.05, -1.8, -1.31, 3.24],
	[-1.2, 1.05, -2.2, -1.8, 3.56], [-1.2, 1.05, -2.62, -2.2, 3.96], [-1.2, 1.05, -2.81, -2.62, 4.26]]
## The arch's own stair climbs this high to its back landing (mesh space).
const ARCH_LANDING := 4.27

var base_y := 1550.0
## The ground as drawn (the check probes it).
var ground: Node3D
## What was built (the check prints it).
var built_stats: Dictionary = {}
## Drawn solids the old game gave no collider: [{note, center, half, yaw_deg}]
## in the map's (pack) coordinates.
var solids: Array = []
## Where the big stalagmite spires stand (the baked stalag mesh placed):
## map_solids.gd boxes them as obstacles.
var spires: Array = []
## Placed props boxed inside their drawn shape by map_solids.gd
## (DungeonView.raster_solids, the raster turned to fit the shape best):
## [{prop: path, xform, bands, note}].
var shaped: Array = []
## A small crag (_crags) stands only where the ground within this reach of
## it falls no more than this (m).
const SMALL_CRAG_REACH := 1.2
const SMALL_CRAG_DROP := 0.6

var _layout: Dictionary = {}
var _heights: PackedFloat32Array
var _n := 0
var _rng := RandomNumberGenerator.new()
var _rock: StandardMaterial3D
var _lights := 0
var _meshes: Dictionary = {}   # prop|glow -> Mesh
var _bounds: Dictionary = {}   # prop -> AABB of its mesh
var _sun: DirectionalLight3D
var _env: WorldEnvironment
var _env_before: Environment

func _ready() -> void:
	name = "MapView"
	build()

func build() -> void:
	if ground != null:
		return
	var started := Time.get_ticks_msec()
	var raw := FileAccess.get_file_as_string(LAYOUT_PATH)
	var parsed: Variant = JSON.parse_string(raw) if raw != "" else null
	_layout = parsed if parsed is Dictionary else {}
	base_y = float(_layout.get("meta", {}).get("base_y", 1550.0))
	var shape := load(HEIGHT_PATH) as HeightMapShape3D
	if shape != null:
		_heights = shape.map_data
		_n = shape.map_width
	_rng.seed = int(_layout.get("meta", {}).get("seed", 2410))
	_rock = StandardMaterial3D.new()
	_rock.albedo_texture = load(TEX % "cave_wall_alb_ht")
	_rock.albedo_color = Color(0.85, 0.82, 0.85)
	_rock.normal_enabled = true
	_rock.normal_texture = load(TEX % "cave_wall_nrm_rgh")
	_rock.uv1_triplanar = true
	_rock.uv1_world_triplanar = true
	_rock.uv1_scale = Vector3(0.3, 0.3, 0.3)
	_rock.roughness = 0.9
	_build_ground()
	for room in _layout.get("rooms", []):
		_dress_room(room as Dictionary)
	_build_crypt_stair()
	_build_web_gates()
	built_stats["lights"] = _lights
	built_stats["solids"] = solids.size()
	built_stats["meshes"] = find_children("*", "GeometryInstance3D", true, false).size()
	built_stats["build_ms"] = Time.get_ticks_msec() - started

func setup(_session: Node, main: Node) -> void:
	_sun = main.get_node_or_null("Sun") as DirectionalLight3D
	if _sun != null:
		_sun.visible = false
	_env = main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if _env != null:
		_env_before = _env.environment
		_env.environment = DungeonView.environment_for("cavern")

## QualityPreset.apply_map: the preset's glow (none on low).
func apply_quality(preset: Dictionary) -> void:
	DungeonView.apply_glow(_env, _env_before, preset)

func _exit_tree() -> void:
	if is_instance_valid(_sun):
		_sun.visible = true
	if is_instance_valid(_env) and _env_before != null:
		_env.environment = _env_before

# ----------------------------------------------------------------- ground

func _build_ground() -> void:
	if not ResourceLoader.exists(TERRAIN_PATH):
		push_error("caverns: %s is missing from this build" % TERRAIN_PATH)
		return
	ground = (load(TERRAIN_PATH) as PackedScene).instantiate()
	ground.name = "Ground"
	ground.position = Vector3(0, base_y, 0)
	add_child(ground)
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	mat.set_shader_parameter("rock_alb", load(TEX % "cave_wall_alb_ht"))
	mat.set_shader_parameter("rock_nrm", load(TEX % "cave_wall_nrm_rgh"))
	mat.set_shader_parameter("dust_alb", load(TEX % "cave_dust_alb_ht"))
	mat.set_shader_parameter("dust_nrm", load(TEX % "cave_dust_nrm_rgh"))
	mat.set_shader_parameter("gravel_alb", load(TEX % "cave_gravel_alb_ht"))
	mat.set_shader_parameter("gravel_nrm", load(TEX % "cave_gravel_nrm_rgh"))
	mat.set_shader_parameter("base_y", base_y)
	var chunks := 0
	for mesh in ground.find_children("*", "MeshInstance3D", true, false):
		(mesh as MeshInstance3D).material_override = mat
		(mesh as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chunks += 1
	built_stats["ground_chunks"] = chunks

## Ground height (world y) at x/z, bilinear on the heightfield's samples
## (the same samples the server's ground is).
func ground_y(x: float, z: float) -> float:
	if _n == 0:
		return base_y
	var half := float(_n - 1) * 0.5
	var fx := clampf(x + half, 0.0, float(_n - 1) - 0.001)
	var fz := clampf(z + half, 0.0, float(_n - 1) - 0.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var h00 := _heights[iz * _n + ix]
	var h10 := _heights[iz * _n + ix + 1]
	var h01 := _heights[(iz + 1) * _n + ix]
	var h11 := _heights[(iz + 1) * _n + ix + 1]
	return base_y + lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

func _on_ground(x: float, z: float) -> Vector3:
	return Vector3(x, ground_y(x, z), z)

## How far the ground falls within `reach` of `p` (highest less lowest of a
## ring of samples and the centre).
func _ground_drop(p: Vector2, reach: float) -> float:
	var lo := ground_y(p.x, p.y)
	var hi := lo
	for k in 8:
		var a := TAU * k / 8.0
		var h := ground_y(p.x + cos(a) * reach, p.y + sin(a) * reach)
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return hi - lo

# ---------------------------------------------------------------- dressing

func _dress_room(room: Dictionary) -> void:
	var c: Array = room.get("c", [0, 0])
	var center := Vector2(float(c[0]), float(c[1]))
	var r := float(room.get("r", 20.0))
	var kind := String(room.get("kind", "web"))
	if kind == "camp":
		_build_camp(center)
		return
	if kind == "stair":
		return
	_crags(center, r, 6 if kind != "slime" else 4, "Crags_" + String(room.get("id", "")))
	_webs(center, r, 7 if kind == "web" else 3)
	_fungi(center, r, kind)
	_spores(center, r, kind)
	match kind:
		"bone":
			_bones(center, r * 0.7, 4)
		"egg":
			_egg_clusters(center, r, 3)
		"slime":
			_slime_pools(center, r)
	if String(room.get("id", "")) == "f1_cocoons":
		_cocoons(center, r, 9)

## A point near the rim of a room (inside it), angle random.
func _rim_point(center: Vector2, r: float, inset: float) -> Vector2:
	var a := _rng.randf() * TAU
	var d := r - inset - _rng.randf() * 3.0
	return center + Vector2(cos(a), sin(a)) * d

## The mesh of a baked prop (assets/models/caverns), cached; with `glow` its
## materials also light up their own albedo.
func _prop_mesh(prop: String, glow: Color = Color(0, 0, 0, 0), energy: float = 1.0) -> Mesh:
	var key := "%s|%s" % [prop, glow]
	if _meshes.has(key):
		return _meshes[key]
	var path := PROP % prop
	var mesh: Mesh = null
	if ResourceLoader.exists(path):
		var scene: Node = (load(path) as PackedScene).instantiate()
		var found := scene.find_children("*", "MeshInstance3D", true, false)
		if not found.is_empty():
			mesh = (found[0] as MeshInstance3D).mesh
		scene.free()
	else:
		push_error("caverns: %s is missing from this build" % path)
	if mesh != null and glow.a > 0.0:
		mesh = mesh.duplicate()
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			var lit := src.duplicate() as BaseMaterial3D
			lit.emission_enabled = true
			lit.emission = glow
			lit.emission_texture = src.albedo_texture
			lit.emission_energy_multiplier = energy
			mesh.surface_set_material(i, lit)
	if mesh != null and not _bounds.has(prop):
		_bounds[prop] = mesh.get_aabb()
	_meshes[key] = mesh
	return mesh

## One MultiMesh of a prop at `xforms`.
func _scatter(prop: String, xforms: Array, node_name: String, glow: Color = Color(0, 0, 0, 0), energy: float = 1.0) -> void:
	var mesh := _prop_mesh(prop, glow, energy)
	if mesh == null or xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = node_name
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

## A prop standing on the ground at `p`, turned `yaw`, sunk `sink` metres.
func _stand(p: Vector2, yaw: float, s: float, sink: float = 0.15, tilt: float = 0.0) -> Transform3D:
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
	if tilt > 0.0:
		basis = Basis(Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized(), tilt) * basis
	return Transform3D(basis, _on_ground(p.x, p.y) - Vector3(0, sink, 0))

## A stood prop (_stand) turned to lie along the ground's slope under it
## (the normal over SLOPE_REACH metres either way), about its foot.
const SLOPE_REACH := 1.0

func _on_slope(xform: Transform3D) -> Transform3D:
	var o := xform.origin
	var dx := ground_y(o.x + SLOPE_REACH, o.z) - ground_y(o.x - SLOPE_REACH, o.z)
	var dz := ground_y(o.x, o.z + SLOPE_REACH) - ground_y(o.x, o.z - SLOPE_REACH)
	var normal := Vector3(-dx, 2.0 * SLOPE_REACH, -dz).normalized()
	var axis := Vector3.UP.cross(normal)
	if axis.length() < 1e-4:
		return xform
	return Transform3D(Basis(axis.normalized(), Vector3.UP.angle_to(normal)) * xform.basis, o)

## A placed prop to be boxed inside its drawn shape, by height band
## (`shaped`; bands as DungeonView.raster_solids takes them).
func _record_solid(prop: String, xform: Transform3D, bands: Array, note: String) -> void:
	shaped.append({"prop": PROP % prop, "xform": xform, "bands": bands, "note": note})

## An arch's piers and passage sides as patch boxes (ARCH_PARTS).
func _record_arch(xform: Transform3D, note: String, down: float) -> void:
	solids.append_array(DungeonView.part_solids(xform, ARCH_PARTS, down, note))

## Stalagmite clumps along the rim: one big spire group and a small one.
## The big ones are solid (Phase 6.6): their placements are kept in
## `spires`, and map_solids.gd boxes each inside its drawn rock as
## `obstacle` patch boxes, which bodies hit and the navmesh goes round but
## the ground the server places packs, Seal Stone waves and arrivals on looks
## through (World::ground_height), so no creature stands on a spire. The
## small ones stay walk-through, as the old game had them all.
func _crags(center: Vector2, r: float, count: int, node_name: String) -> void:
	var xforms: Array = []
	for i in count:
		var p := _rim_point(center, r, 3.5)
		var spire := _stand(p, _rng.randf() * TAU, _rng.randf_range(0.55, 1.05), 0.5, _rng.randf_range(0.0, 0.08))
		xforms.append(spire)
		spires.append(spire)
		var q := p + Vector2(_rng.randf_range(-4.0, 4.0), _rng.randf_range(-4.0, 4.0))
		var small := _stand(q, _rng.randf() * TAU, _rng.randf_range(0.2, 0.35), 0.2, _rng.randf_range(0.0, 0.15))
		# not on the rim's cliff: a clump set on the bilinear height half-way
		# up a rock face hung in the air in front of it (placement_check.gd,
		# 2026-11-16); the draws are made either way, so the rest stays put
		if _ground_drop(q, SMALL_CRAG_REACH) <= SMALL_CRAG_DROP:
			xforms.append(small)
	_scatter("stalag", xforms, node_name)

## Dew-beaded orb webs strung along the rim, facing the room's centre.
func _webs(center: Vector2, r: float, count: int) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WEB_SHADER
	mat.set_shader_parameter("web", load(WEB_TEX))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = mat
	mm.mesh = quad
	mm.instance_count = count
	for i in count:
		var p := _rim_point(center, r, 1.5)
		var s := _rng.randf_range(5.0, 10.0)
		var g := _on_ground(p.x, p.y)
		var to_center := Vector3(center.x - p.x, 0, center.y - p.y).normalized()
		var basis := Basis.looking_at(-to_center, Vector3.UP)
		basis = basis * Basis(Vector3.RIGHT, _rng.randf_range(-0.45, 0.1)) * Basis(Vector3.FORWARD, _rng.randf() * TAU)
		mm.set_instance_transform(i, Transform3D(basis.scaled_local(Vector3(s, s, 1)), g + Vector3(0, s * 0.5 + _rng.randf_range(0.5, 3.0), 0)))
		mm.set_instance_custom_data(i, Color(_rng.randf(), 0, 0, 0))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Webs"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

## Bioluminescent mushroom clumps at the room's edge; one carries a light.
func _fungi(center: Vector2, r: float, kind: String) -> void:
	var glow := Color(0.35, 1.0, 0.8) if kind != "egg" else Color(0.75, 0.5, 1.0)
	var xforms: Array = []
	for i in 4:
		var p := _rim_point(center, r, 3.0)
		xforms.append(_stand(p, _rng.randf() * TAU, _rng.randf_range(1.2, 2.2), 0.1))
		if i == 0:
			_light(_on_ground(p.x, p.y) + Vector3(0, 2.6, 0), glow, 1.2, 14.0)
	_scatter("mushrooms", xforms, "Fungi", glow, 0.14)

## Glowing spores drifting slowly up through the room's air (GPU motes):
## small soft specks in the room's colour, never white discs: they fade out
## nearer the camera than SPORE_FADE_FAR and are gone inside SPORE_FADE_NEAR
## (a third-person camera sits a few metres behind the hero, so a spore
## drifting past the lens never fills the screen), and their glow peaks at
## SPORE_GLOW so the additive core keeps its tint under the glow pass.
func _spores(center: Vector2, r: float, kind: String) -> void:
	var tint := Color(0.55, 1.0, 0.8) if kind != "egg" else Color(0.85, 0.6, 1.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(r * 0.8, 3.0, r * 0.8)
	pm.direction = Vector3.UP
	pm.spread = 60.0
	pm.initial_velocity_min = 0.08
	pm.initial_velocity_max = 0.3
	pm.gravity = Vector3(0, 0.03, 0)
	pm.scale_min = SPORE_SCALE.x
	pm.scale_max = SPORE_SCALE.y
	var ramp := Gradient.new()
	ramp.set_color(0, Color(tint, 0.0))
	ramp.set_color(1, Color(tint, 0.0))
	ramp.add_point(0.25, Color(tint, SPORE_GLOW))
	ramp.add_point(0.75, Color(tint, SPORE_GLOW))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	var mote := ShaderMaterial.new()
	mote.shader = SPORE_SHADER
	mote.set_shader_parameter("fade_near", SPORE_FADE_NEAR)
	mote.set_shader_parameter("fade_far", SPORE_FADE_FAR)
	var quad := QuadMesh.new()
	quad.material = mote
	var p := GPUParticles3D.new()
	p.name = "Spores"
	p.amount = int(r * 1.8)
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.process_material = pm
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-r, -4.0, -r), Vector3(r * 2.0, 14.0, r * 2.0))
	p.position = _on_ground(center.x, center.y) + Vector3(0, 3.5, 0)
	add_child(p)

## Bone heaps scattered over the floor (the bone rooms).
func _bones(center: Vector2, r: float, count: int) -> void:
	var xforms: Array = []
	for i in count:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * sqrt(_rng.randf()) * r
		xforms.append(_stand(p, _rng.randf() * TAU, _rng.randf_range(0.8, 1.4), 0.05))
	_scatter("bones", xforms, "Bones")

## Silk-wrapped egg clutches with a faint violet pulse, lying along the
## floor's slope (a soft clutch settles on it; stood upright, a big one by
## the rim sank a third of a metre into the rise on one side).
func _egg_clusters(center: Vector2, r: float, count: int) -> void:
	var xforms: Array = []
	for i in count:
		var p := _rim_point(center, r, 5.0)
		xforms.append(_on_slope(_stand(p, _rng.randf() * TAU, _rng.randf_range(1.0, 1.5), 0.1)))
		var q := p + Vector2(_rng.randf_range(-3.5, 3.5), _rng.randf_range(-3.5, 3.5))
		xforms.append(_on_slope(_stand(q, _rng.randf() * TAU, _rng.randf_range(0.5, 0.75), 0.05)))
		_light(_on_ground(p.x, p.y) + Vector3(0, 1.8, 0), Color(0.7, 0.4, 1.0), 1.8, 12.0)
	_scatter("eggs", xforms, "EggSacs", Color(0.55, 0.3, 0.8), 0.35)

## Venom pools: a shoreline-cut glossy quad each, a green mist over them.
func _slime_pools(center: Vector2, r: float) -> void:
	for i in 4:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * _rng.randf_range(0.0, r * 0.6)
		var rad := _rng.randf_range(3.0, 6.0)
		var mat := ShaderMaterial.new()
		mat.shader = SLIME_SHADER
		mat.set_shader_parameter("seed", _rng.randf() * 10.0)
		var quad := QuadMesh.new()
		quad.size = Vector2(rad * 2.0, rad * 2.0)
		quad.orientation = PlaneMesh.FACE_Y
		var m := MeshInstance3D.new()
		m.name = "VenomPool"
		m.mesh = quad
		m.material_override = mat
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.scale = Vector3(1.0, 1.0, _rng.randf_range(0.65, 1.0))
		m.rotation.y = _rng.randf() * TAU
		m.position = _on_ground(p.x, p.y) + Vector3(0, 0.06, 0)
		add_child(m)
		var delay := -_rng.randf() * 5.0
		FlipbookFX.play(self, m.position, [
			{"atlas": "toxic_mist_8x8_1k", "size": Vector2(rad * 2.2, rad * 1.1), "height": rad * 0.4, "fps": 9.0,
				"loop": true, "opacity": 0.28, "tint": Color(0.6, 1.0, 0.45), "delay": delay, "fade_in": 0.01},
		], {"life": 0.0, "name": "VenomMist"})
	_light(_on_ground(center.x, center.y) + Vector3(0, 2.5, 0), Color(0.4, 1.0, 0.3), 1.6, 20.0)

## Silk-wrapped victims hanging from the dark above the room.
func _cocoons(center: Vector2, r: float, count: int) -> void:
	var silk := StandardMaterial3D.new()
	silk.albedo_color = Color(0.75, 0.76, 0.74)
	silk.roughness = 0.9
	var line := CylinderMesh.new()
	line.top_radius = 0.02
	line.bottom_radius = 0.03
	line.height = 20.0
	line.radial_segments = 4
	line.material = silk
	var xforms: Array = []
	var threads: Array = []
	for i in count:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * _rng.randf_range(4.0, r - 4.0)
		var s := _rng.randf_range(0.9, 1.25)
		var base := _on_ground(p.x, p.y) + Vector3(0, _rng.randf_range(2.5, 5.0), 0)
		var basis := Basis(Vector3.UP, _rng.randf() * TAU) * Basis(Vector3.RIGHT, _rng.randf_range(-0.12, 0.12))
		xforms.append(Transform3D(basis.scaled(Vector3.ONE * s), base))
		threads.append(Transform3D(Basis.IDENTITY, base + Vector3(0, 2.3 * s + 10.0, 0)))
	_scatter("cocoon", xforms, "Cocoons")
	# the threads they hang by: one MultiMesh, one draw
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = line
	mm.instance_count = threads.size()
	for i in threads.size():
		mm.set_instance_transform(i, threads[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = "CocoonThreads"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

# ------------------------------------------------------------------- camp

func _build_camp(center: Vector2) -> void:
	# The explorers' tent with its crates and barrels, facing the fire.
	var tent_at := center + Vector2(-9.0, -6.0)
	var to_fire := center - tent_at
	var tent := _stand(tent_at, atan2(to_fire.x, to_fire.y), 1.0, 0.1)
	_scatter("camp", [tent], "Camp")
	# the A-frame stepped in along its ridge, the crates beside it
	_record_solid("camp", tent, [[0.0, 0.25], [0.25, 0.5], [0.5, 0.75]],
		"the explorers' tent at the camp: drawn canvas, no collider")
	_scatter("bones", [_stand(center + Vector2(10.0, 9.0), 1.1, 0.9, 0.05)], "CampBones")
	# Campfire: stones, embers and a warm light.
	var fire_at := _on_ground(center.x, center.y)
	var ember := StandardMaterial3D.new()
	ember.albedo_color = Color(1.0, 0.45, 0.15)
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.45, 0.12)
	ember.emission_energy_multiplier = 1.6
	var coals := MeshInstance3D.new()
	coals.name = "Coals"
	var dome := SphereMesh.new()
	dome.radius = 0.6
	dome.height = 0.5
	dome.is_hemisphere = true
	coals.mesh = dome
	coals.material_override = ember
	coals.position = fire_at
	add_child(coals)
	# Flames over the coals: three flipbook cards of different heights.
	for k in 3:
		var off := Vector3(cos(TAU * k / 3.0), 0.0, sin(TAU * k / 3.0)) * 0.22
		CastleFire.make(self, fire_at + off + Vector3(0, 0.55, 0), Vector2(0.75, 1.15) * (1.0 - 0.15 * k), Color(1, 1, 1), 1.5)
	var stone := SphereMesh.new()
	stone.radius = 0.28
	stone.height = 0.4
	stone.material = _rock
	var ring := MultiMesh.new()
	ring.transform_format = MultiMesh.TRANSFORM_3D
	ring.mesh = stone
	ring.instance_count = 8
	for i in 8:
		var a := TAU * float(i) / 8.0
		ring.set_instance_transform(i, Transform3D(Basis.IDENTITY, fire_at + Vector3(cos(a) * 0.95, 0.12, sin(a) * 0.95)))
	var stones := MultiMeshInstance3D.new()
	stones.name = "FireStones"
	stones.multimesh = ring
	stones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stones)
	_light(fire_at + Vector3(0, 1.2, 0), Color(1.0, 0.62, 0.32), 3.0, 22.0)
	# Lanterns on posts around the camp.
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.3, 0.2, 0.12)
	wood.roughness = 0.9
	for a in [0.6, 2.4, 4.1]:
		var p := center + Vector2(cos(a), sin(a)) * 13.0
		var g := _on_ground(p.x, p.y)
		var post := MeshInstance3D.new()
		post.name = "LanternPost"
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.07
		cyl.bottom_radius = 0.09
		cyl.height = 2.4
		cyl.material = wood
		post.mesh = cyl
		post.position = g + Vector3(0, 1.2, 0)
		add_child(post)
		CastleFire.make(self, g + Vector3(0, 2.52, 0), Vector2(0.34, 0.52), Color(1, 1, 1), 1.4)
		_light(g + Vector3(0, 2.4, 0), Color(1.0, 0.7, 0.4), 1.4, 11.0)

## The way back up: worn steps climbing north-west into the rock to the
## crypt's undercroft gate (maps.json `caverns_ascend`, dressing
## "crypt_stair": its trigger is at the stair foot). Four steps up to a
## landing the crypt gate stands on level (the arch is flat underneath and
## climbs on its own stair inside), then the upper landing at the height of
## the arch's back landing, running on into the rock.
const CRYPT_STEP := 0.9
const CRYPT_RISE := 0.42
const CRYPT_STEPS := 4
## The gate's centre along the stair (m from the foot) and the landings'
## widths (the arch is 5.73 m across).
const CRYPT_GATE_AT := 6.0
const CRYPT_GATE_WIDTH := 6.0
const CRYPT_TOP_END := 12.15

func _build_crypt_stair() -> void:
	var foot := Vector2(-209.0, -209.0)
	var dir := Vector2(-1, -1).normalized()
	var y0 := ground_y(foot.x, foot.y)
	var basis := Basis.looking_at(Vector3(dir.x, 0, dir.y), Vector3.UP)
	# a block of the stair: [from, to] metres along it from the foot, its top
	# over the foot's ground, its width; each stands on footing under the
	# ground there
	var blocks: Array = []
	for i in CRYPT_STEPS:
		blocks.append([(float(i) - 0.5) * CRYPT_STEP, (float(i) + 0.5) * CRYPT_STEP, 0.25 + float(i) * CRYPT_RISE, 5.0])
	var gate_y := 0.25 + float(CRYPT_STEPS) * CRYPT_RISE
	var gate_from := (float(CRYPT_STEPS) - 0.5) * CRYPT_STEP
	var gate_to := 2.0 * CRYPT_GATE_AT - gate_from
	blocks.append([gate_from, gate_to, gate_y, CRYPT_GATE_WIDTH])
	blocks.append([gate_to, CRYPT_TOP_END, gate_y + ARCH_LANDING, 5.0])
	for i in blocks.size():
		var b: Array = blocks[i]
		var from := float(b[0])
		var to := float(b[1])
		var p := foot + dir * ((from + to) * 0.5)
		var step := MeshInstance3D.new()
		step.name = "Step%d" % i
		var box := BoxMesh.new()
		box.size = Vector3(float(b[3]), float(b[2]) + 0.2, to - from)
		box.material = _rock
		step.mesh = box
		step.basis = basis
		step.position = Vector3(p.x, y0 + box.size.y * 0.5 - 0.2, p.y)
		add_child(step)
		# the block's stone as a collider, 2 cm inside the drawn faces
		var what := "step %d" % i if i < CRYPT_STEPS else ("gate landing" if i == CRYPT_STEPS else "upper landing")
		solids.append({"note": "crypt stair %s: drawn stone, no collider" % what,
			"center": [snappedf(step.position.x, 0.001), snappedf(step.position.y - 0.01, 0.001), snappedf(step.position.z, 0.001)],
			"half": [snappedf(box.size.x * 0.5 - 0.02, 0.001), snappedf(box.size.y * 0.5 - 0.01, 0.001),
				snappedf(box.size.z * 0.5 - 0.01, 0.001)],
			"yaw_deg": snappedf(rad_to_deg(atan2(-dir.x, -dir.y)), 0.01)})
	# The crypt gate (its front faces back down the stair) level on its
	# landing, and a faint daylight spill from above.
	var top := foot + dir * 13.5
	var top_y := y0 + gate_y + ARCH_LANDING + 0.3
	var gate_at := foot + dir * CRYPT_GATE_AT
	var gate := Transform3D(basis, Vector3(gate_at.x, y0 + gate_y, gate_at.y))
	_scatter("arch", [gate], "CryptGate")
	_record_arch(gate, "the crypt gate's arch on the stair: drawn stone, no collider", 0.1)
	_light(Vector3(top.x, top_y + 3.0, top.y) - Vector3(dir.x, 0, dir.y) * 2.0, Color(0.7, 0.78, 0.95), 2.2, 16.0)
	_light(Vector3(foot.x, y0 + 2.5, foot.y), Color(1.0, 0.66, 0.38), 1.4, 10.0)

## The web gates of the Web Mother's Lair (maps.json portals with dressing
## "web_gate"): an arch in the wall of the room, hung with cocoons, egg
## clutches at its feet and a violet glow; the dungeon gate window opens here.
func _build_web_gates() -> void:
	var maps: Variant = RealmContent.table("maps")
	if not (maps is Dictionary):
		return
	# each gate's room: the old game's two (the sealed one deep on floor 2,
	# the one at the camp)
	var rooms := {"lair_entry": Vector2(175.0, 200.0), "lair_entry_camp": Vector2(-170.0, -175.0)}
	for portal: Dictionary in (maps as Dictionary).get("portals", []):
		if String(portal.get("map_id", "")) != "spider_caverns" or String(portal.get("dressing", "")) != "web_gate":
			continue
		var id := String(portal.get("id", ""))
		if not rooms.has(id):
			push_error("caverns: web gate %s has no room" % id)
			continue
		var c: Array = (portal.get("trigger", {}) as Dictionary).get("center", [0, 0, 0])
		_build_web_gate(Vector2(float(c[0]), float(c[2])), rooms[id], id)

func _build_web_gate(at: Vector2, room: Vector2, id: String) -> void:
	var out := (at - room).normalized()
	# its facade to the room, its passage back into the rock (the old
	# placement turned it round: the room saw the passage's blank back)
	var basis := Basis.looking_at(Vector3(out.x, 0, out.y), Vector3.UP)
	var y := ground_y(at.x, at.y)
	var arch_at := at + out * 4.0
	# On the ground: the floor's lowest point under its footprint (the old
	# placement, the door's ground + 1.7 m, left it hovering 1.7 m over the
	# camp's flat floor; the far side is sunk in the wall's ramp).
	var arch := Transform3D(basis, Vector3(arch_at.x, 0.0, arch_at.y))
	var foot := INF
	for lz in [2.5, 1.0, 0.0, -1.5, -3.0]:
		for lx in [-2.8, -1.4, 0.0, 1.4, 2.8]:
			var p: Vector3 = arch * Vector3(lx, 0.0, lz)
			foot = minf(foot, ground_y(p.x, p.z))
	arch.origin.y = foot
	_scatter("arch", [arch], "WebGate_" + id)
	_record_arch(arch, "the %s web gate's arch: drawn stone, no collider" % id, 0.1)
	var side := Vector2(-out.y, out.x)
	# the left one a step out of the wall's foot (set in line with the arch it
	# stood 0.7 m deep in the deep gate's rising wall)
	_scatter("cocoon", [_stand(arch_at + side * 3.2, 0.3, 1.1), _stand(arch_at - side * 3.4 - out * 1.2, 2.1, 1.0)],
		"WebGateCocoons")
	_scatter("eggs", [_stand(at + side * 4.5 - out * 1.5, 0.8, 0.6), _stand(at - side * 4.8 - out * 1.0, 2.6, 0.55)],
		"WebGateEggs", Color(0.55, 0.3, 0.8), 0.35)
	_light(Vector3(at.x, y + 3.2, at.y), Color(0.72, 0.5, 1.0), 2.0, 14.0)
	built_stats["gate_" + id] = arch_at

func _light(at: Vector3, color: Color, energy: float, reach: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = reach
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	l.position = at
	add_child(l)
	_lights += 1
