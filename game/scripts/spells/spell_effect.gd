extends Node3D
class_name SpellEffect

## One stage (cast / travel / impact) of one spell, built from the composition
## table in VFXLibrary and driven over time. Presentation only: the server has
## already decided every outcome before the effect exists.
##
## Lifecycle: the node frees itself when the stage has played out; `cancel()`
## stops emission, fades fast and frees; an effect whose caster was freed
## cancels itself, so it never outlives its caster; a travel stage that
## follows a bolt lives as long as the bolt, and `retire_travel()` lets its
## wake fade where the bolt ended. Every sound it started stops on exit.

const SHADER_ALPHA := preload("res://assets/shaders/spell_layer.gdshader")
const SHADER_ADD := preload("res://assets/shaders/spell_layer_add.gdshader")
const ENERGY_SHADER := preload("res://assets/shaders/wand_energy.gdshader")
const RIBBON_SHADER := preload("res://assets/shaders/spell_ribbon.gdshader")
const ARC_SHADER := preload("res://assets/shaders/spell_arc.gdshader")
const TRAIL_SHADER := preload("res://assets/shaders/energy_trail.gdshader")
const EMBER_PROCESS := preload("res://assets/shaders/ember_particles.gdshader")
const EMBER_DRAW := preload("res://assets/shaders/ember_spark.gdshader")
## Depth fade of a ground mark (m); its `lift` keeps it clear of open ground.
const FLAT_SOFT_FADE := 0.12
## No floor known under the effect: sparks fall through.
const NO_FLOOR := -100000.0

## Everything an effect is built from stays loaded for the session: a texture
## or shader read (and compiled) again on the cast's frame was a visible hitch.
## Particle draw passes, the fade ramp and the process materials of non-aimed
## particle layers are shared the same way.
static var _resources: Dictionary = {}
static var _particle_parts: Dictionary = {}
static var _fade_ramp: GradientTexture1D = null

static func asset(path: String) -> Resource:
	var res: Resource = _resources.get(path)
	if res == null and path != "" and ResourceLoader.exists(path):
		res = load(path)
		_resources[path] = res
	return res

var spell_id := "basic_cast"
var stage := "cast"
var quality := "low"
var caster: Node3D
## The aim; CombatView keeps a travel stage's current with its bolt.
var direction := Vector3.FORWARD
var base_position := Vector3.ZERO
var follow_target: Node3D
var target_position := Vector3.ZERO
var aoe_radius := 0.0
var floor_y := NO_FLOOR
## The ground's slope there: ground marks lie along it.
var floor_normal := Vector3.UP
var cancelled := false
var _has_caster := false

var _layers: Array = []
var _elapsed := 0.0
var _duration := 0.6
var _audio_started: Array[String] = []
var _audio_key := ""
var _audio_manager: Node = null
var _audio_looping := false
## The follow target's position on the last tick. A following effect is
## translated BY the target's motion, so the offset it was placed with (an
## impact at chest height, a flash at the wand tip) survives.
var _follow_anchor := Vector3.ZERO
## Set for a travel stage that follows a bolt: the bolt owns that stage and
## ends it, a fixed timer would clip the flight short.
var _follow_owned := false
var _retiring := false
var _retire_at := 0.0
## The spell's second colour (layers with `"colour": "accent"`).
var _accent := Color.WHITE

## Build this stage. `opts` may carry follow_target, target_position,
## aoe_radius, floor_y and floor_normal (the ground under the effect) and
## house (the caster's, for a spell drawn in its house colours).
func setup(p_spell: String, p_stage: String, p_quality: String, p_origin: Vector3,
		p_dir: Vector3, p_caster: Node3D = null, opts: Dictionary = {}) -> void:
	spell_id = p_spell
	stage = p_stage
	quality = p_quality
	base_position = p_origin
	global_position = p_origin
	direction = p_dir.normalized() if p_dir.length_squared() > 0.0001 else Vector3.FORWARD
	caster = p_caster
	_has_caster = p_caster != null
	follow_target = opts.get("follow_target", null)
	target_position = opts.get("target_position", p_origin)
	floor_y = float(opts.get("floor_y", NO_FLOOR))
	floor_normal = (opts.get("floor_normal", Vector3.UP) as Vector3).normalized()
	aoe_radius = float(opts.get("aoe_radius", 0.0))
	if aoe_radius <= 0.0 and p_stage == "impact":
		# a blast's ground ring is the gameplay area: the radius the server uses
		aoe_radius = float(HudActionBar.spells().get(p_spell, {}).get("radius", 0.0))
	if _live(follow_target):
		_follow_anchor = follow_target.global_position
	var colours := VFXLibrary.colours_for(spell_id, String(opts.get("house", "")))
	var colour: Color = colours[0]
	_accent = colours[1]
	for layer: Dictionary in VFXLibrary.layers_for(spell_id, stage, quality):
		var node := _build_layer(layer, colour)
		if node == null:
			continue
		var offset := float(layer.get("delay", 0.0))
		node.visible = offset <= 0.0
		_layers.append({"node": node, "layer": layer, "offset": offset})
		var life := float(layer.get("life", 0.0))
		if life > 0.0:
			_duration = maxf(_duration, life + offset)
	_duration = maxf(_duration, float(_stage_data().get("length", 0.0)))
	if stage == "travel":
		if follow_target == null:
			_duration = maxf(_duration, 2.5)
		else:
			_follow_owned = true
	_start_audio()

func _stage_data() -> Dictionary:
	return VFXLibrary.stages_for(spell_id).get(stage, {})

## The stage's sound, started once the emission point is known. A looping
## stage keeps its voice on the effect (see `_process`).
func _start_audio() -> void:
	_audio_key = String(_stage_data().get("audio", ""))
	_audio_manager = get_node_or_null("/root/AudioManager")
	if _audio_key == "" or _audio_manager == null:
		return
	if bool(_stage_data().get("loop_audio", false)):
		_audio_looping = true
		_audio_manager.loop_sound(_audio_key, self)
	else:
		_audio_manager.play_sound_at(_audio_key, global_position, self)
	_audio_started.append(_audio_key)

# ------------------------------------------------------------------ building

func _build_layer(layer: Dictionary, colour: Color) -> Node3D:
	match String(layer.get("kind", "")):
		"flipbook", "sprite":
			return _build_flipbook(layer, colour)
		"particles":
			return _build_particles(layer, colour)
		"ribbon":
			return _build_ribbon(layer, colour)
		"arc":
			return _build_arc(layer, colour)
		"trail":
			return _build_trail(layer, colour)
		"light":
			return _build_light(layer, colour)
	return null

func _layer_colour(layer: Dictionary, colour: Color) -> Color:
	var wanted: Variant = layer.get("colour", false)
	if wanted is String and wanted == "accent":
		return _accent
	if bool(wanted):
		return colour
	return Color.WHITE

func _material_for(layer: Dictionary, colour: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	if layer.has("energy_shape"):
		material.shader = ENERGY_SHADER
		material.set_shader_parameter("shape", int(layer["energy_shape"]))
		material.set_shader_parameter("tint", _layer_colour(layer, colour))
		material.set_shader_parameter("aim", direction)
		material.set_shader_parameter("opacity", float(layer.get("opacity", 1.0)))
		return material
	var flat := bool(layer.get("flat", false))
	material.shader = SHADER_ADD if String(layer.get("blend", "alpha")) == "add" else SHADER_ALPHA
	var entry := VFXLibrary.asset(String(layer.get("atlas", layer.get("tex", ""))))
	var texture_path := String(entry.get("path", ""))
	if texture_path != "":
		material.set_shader_parameter("atlas", asset(texture_path))
	material.set_shader_parameter("grid", entry.get("grid", Vector2.ONE))
	material.set_shader_parameter("frame", float(layer.get("frame", 0)))
	material.set_shader_parameter("billboard", not flat)
	material.set_shader_parameter("tint", _layer_colour(layer, colour))
	material.set_shader_parameter("opacity", float(layer.get("opacity", 1.0)))
	# a ground mark fades out where a bump of the ground rises through it
	# instead of being cut along the terrain's triangles
	material.set_shader_parameter("soft_fade", FLAT_SOFT_FADE if flat else 0.35)
	if bool(layer.get("roll", false)):
		material.set_shader_parameter("roll", randf() * TAU)
	return material

func _build_flipbook(layer: Dictionary, colour: Color) -> Node3D:
	var quad := QuadMesh.new()
	var size := float(layer.get("size", 1.0))
	quad.size = Vector2(size * float(layer.get("stretch", 1.0)), size)
	quad.material = _material_for(layer, colour)
	var node := MeshInstance3D.new()
	node.name = "Layer_Flipbook"
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_place(node, layer, size)
	return node

## `forward` is metres along the aim direction; `true` means one metre.
func _forward_of(layer: Dictionary) -> float:
	var raw: Variant = layer.get("forward", 0.0)
	if raw is bool:
		return 1.0 if raw else 0.0
	return float(raw)

func _place(node: Node3D, layer: Dictionary, size: float) -> void:
	if bool(layer.get("flat", false)):
		# ground marks lie on the floor under the effect, along its slope (a
		# level disc on a hillside goes into the hill along a hard line)
		var ground := floor_y if floor_y > NO_FLOOR else base_position.y
		var tilt := Basis(Quaternion(Vector3.UP, floor_normal)) if floor_normal.dot(Vector3.UP) < 0.9999 else Basis()
		node.global_basis = tilt * Basis(Vector3.RIGHT, -PI * 0.5)
		node.global_position = Vector3(base_position.x, ground, base_position.z) + floor_normal * float(layer.get("lift", 0.05))
		if aoe_radius > 0.0 and bool(layer.get("core", false)):
			node.scale = Vector3.ONE * maxf(1.0, aoe_radius * 2.0 / maxf(0.001, size))
	elif bool(layer.get("at_hit", false)):
		node.global_position = target_position
	else:
		node.global_position = base_position + direction * _forward_of(layer)
	if bool(layer.get("spin", false)):
		node.set_meta("spin", randf_range(-1.4, 1.4))
	if bool(layer.get("flicker", false)):
		node.set_meta("flicker", true)

func _build_particles(layer: Dictionary, colour: Color) -> Node3D:
	var particles := GPUParticles3D.new()
	particles.name = "Layer_Particles"
	particles.amount = int(layer.get("amount", 12))
	particles.lifetime = float(layer.get("life", 0.5))
	var continuous := bool(layer.get("continuous", false))
	particles.one_shot = not continuous
	particles.explosiveness = 0.0 if continuous else 0.92
	particles.randomness = 0.8
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if bool(layer.get("embers", false)):
		return _build_embers(particles, layer, colour)
	var size := float(layer.get("size", 0.1))
	var tex := String(layer.get("tex", "vfx_star_flare"))
	var blend := String(layer.get("blend", "alpha"))
	var pass_key := "pass|%s|%s|%s" % [size, blend, tex]
	var quad: QuadMesh = _particle_parts.get(pass_key)
	if quad == null:
		quad = QuadMesh.new()
		quad.size = Vector2(size, size)
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if blend == "add" else BaseMaterial3D.BLEND_MODE_MIX
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.vertex_color_use_as_albedo = true
		material.albedo_texture = asset(VFXLibrary.asset_path(tex))
		quad.material = material
		_particle_parts[pass_key] = quad
	particles.draw_pass_1 = quad
	# A process material that does not point down this cast's aim is the same
	# for every cast of the layer in the same colour: shared.
	var aimed := bool(layer.get("forward", false))
	var tint := _layer_colour(layer, colour)
	var process_key := "process|%s|%s|%s|%s" % [layer.get("spread", 45.0), layer.get("speed", 2.0),
		layer.get("gravity", -3.0), tint.to_html()]
	var process: ParticleProcessMaterial = null if aimed else _particle_parts.get(process_key)
	if process == null:
		process = ParticleProcessMaterial.new()
		process.direction = direction if aimed else Vector3.UP
		process.spread = float(layer.get("spread", 45.0))
		process.initial_velocity_min = float(layer.get("speed", 2.0)) * 0.6
		process.initial_velocity_max = float(layer.get("speed", 2.0))
		process.gravity = Vector3(0.0, float(layer.get("gravity", -3.0)), 0.0)
		process.scale_min = 0.6
		process.scale_max = 1.4
		process.color = tint
		if _fade_ramp == null:
			var gradient := Gradient.new()
			gradient.set_color(0, Color(1, 1, 1, 1))
			gradient.set_color(1, Color(1, 1, 1, 0))
			_fade_ramp = GradientTexture1D.new()
			_fade_ramp.gradient = gradient
		process.color_ramp = _fade_ramp
		if not aimed:
			_particle_parts[process_key] = process
	particles.process_material = process
	add_child(particles)
	particles.global_position = base_position + direction * _forward_of(layer)
	particles.emitting = true
	return particles

## Real sparks (ember_particles.gdshader + ember_spark.gdshader): thrown into a
## cone round `dir` ("back" = toward the caster, "up", "aim" or "any"), they arc
## under `gravity`, slow with `drag`, wander with `turbulence`, bounce on the
## floor under the stage (`floor`) and cool along white -> accent -> colour ->
## ember. `speed` and `size` are [min, max]. A `continuous` layer trails its
## moving emitter (a bolt's sparks).
func _build_embers(particles: GPUParticles3D, layer: Dictionary, colour: Color) -> Node3D:
	particles.explosiveness = 0.0 if bool(layer.get("continuous", false)) else 1.0
	particles.randomness = 0.0
	particles.fixed_fps = 0
	particles.visibility_aabb = AABB(Vector3(-12, -12, -12), Vector3(24, 24, 24))
	var quad: QuadMesh = _particle_parts.get("embers|draw")
	if quad == null:
		quad = QuadMesh.new()
		var draw := ShaderMaterial.new()
		draw.shader = EMBER_DRAW
		quad.material = draw
		_particle_parts["embers|draw"] = quad
	particles.draw_pass_1 = quad
	particles.process_material = _ember_process(layer, _layer_colour(layer, colour))
	add_child(particles)
	particles.global_position = base_position + direction * _forward_of(layer)
	particles.emitting = true
	return particles

func _ember_process(layer: Dictionary, tint: Color) -> ShaderMaterial:
	var process := ShaderMaterial.new()
	process.shader = EMBER_PROCESS
	var aim := Vector3.UP
	match String(layer.get("dir", "any")):
		"back":
			aim = (-direction + Vector3.UP * float(layer.get("lift", 0.5))).normalized()
		"aim":
			aim = direction
	process.set_shader_parameter("dir", aim)
	process.set_shader_parameter("spread_deg", float(layer.get("spread", 60.0)))
	var speed: Array = layer.get("speed", [2.0, 8.0])
	process.set_shader_parameter("speed_min", float(speed[0]))
	process.set_shader_parameter("speed_max", float(speed[1]))
	var size: Array = layer.get("size", [0.008, 0.02])
	process.set_shader_parameter("size_min", float(size[0]))
	process.set_shader_parameter("size_max", float(size[1]))
	process.set_shader_parameter("gravity", float(layer.get("gravity", 9.0)))
	process.set_shader_parameter("drag", float(layer.get("drag", 1.0)))
	process.set_shader_parameter("turbulence", float(layer.get("turbulence", 0.0)))
	process.set_shader_parameter("stretch", float(layer.get("stretch", 0.012)))
	process.set_shader_parameter("emit_radius", float(layer.get("radius", 0.05)))
	process.set_shader_parameter("bounce", float(layer.get("bounce", 0.35)))
	process.set_shader_parameter("energy", float(layer.get("energy", 1.0)))
	process.set_shader_parameter("ramp", _ember_ramp(tint, _accent))
	if bool(layer.get("floor", false)):
		process.set_shader_parameter("floor_y", floor_y)
	return process

## White-hot -> accent -> spell colour -> a dull ember, fading out at the end.
func _ember_ramp(tint: Color, accent: Color) -> GradientTexture1D:
	var key := "ramp|%s|%s" % [tint.to_html(), accent.to_html()]
	var cached: GradientTexture1D = _particle_parts.get(key)
	if cached != null:
		return cached
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.03, 0.12, 0.75, 1.0])
	gradient.colors = PackedColorArray([Color(1.0, 0.97, 0.92, 1.0), accent, tint,
		Color(tint.r * 0.45, tint.g * 0.3, tint.b * 0.3, 0.8), Color(tint.r * 0.25, tint.g * 0.12, tint.b * 0.12, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	ramp.width = 64
	_particle_parts[key] = ramp
	return ramp

## A strip in world space (its vertices are world positions), so it inherits
## neither the effect's translation nor its rotation.
func _world_strip(node_name: String, material: ShaderMaterial) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = ImmediateMesh.new()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.top_level = true
	node.material_override = material
	add_child(node)
	node.global_transform = Transform3D.IDENTITY
	return node

func _build_ribbon(layer: Dictionary, colour: Color) -> Node3D:
	var material := ShaderMaterial.new()
	material.shader = RIBBON_SHADER
	material.set_shader_parameter("streak", asset(VFXLibrary.asset_path(String(layer.get("tex", "vfx_energy_streak")))))
	material.set_shader_parameter("tint", _layer_colour(layer, colour))
	material.set_shader_parameter("edge_softness", 0.6)
	material.set_shader_parameter("kinked", bool(layer.get("kinked", false)))
	material.set_shader_parameter("seed", randf() * 100.0)
	var node := _world_strip("Layer_Ribbon", material)
	node.set_meta("width", float(layer.get("width", 0.1)))
	node.set_meta("max_length", float(layer.get("length", 3.0)))
	node.set_meta("history", PackedVector3Array())
	return node

## Electric arcs: `amount` jagged polylines thrown out of the stage's point,
## `length` [min, max], re-struck `strike_hz` times a second and drawn as
## camera-facing strips (spell_arc.gdshader). A strike stores a seed, not
## points, so the shape only changes on a new strike.
func _build_arc(layer: Dictionary, colour: Color) -> Node3D:
	var material := ShaderMaterial.new()
	material.shader = ARC_SHADER
	material.set_shader_parameter("tint", _layer_colour(layer, colour))
	material.set_shader_parameter("core_px", float(layer.get("core_px", 1.6)))
	material.set_shader_parameter("glow", float(layer.get("glow", 0.55)))
	var node := _world_strip("Layer_Arc", material)
	node.set_meta("seed", randi())
	node.set_meta("next_strike", 0.0)
	return node

func _update_arc(node: MeshInstance3D, layer: Dictionary, age: float, fade: float) -> void:
	if age >= float(node.get_meta("next_strike")):
		node.set_meta("seed", randi())
		node.set_meta("next_strike", age + 1.0 / maxf(1.0, float(layer.get("strike_hz", 18.0))))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(node.get_meta("seed"))
	var width := float(layer.get("width", 0.3))
	var jag := float(layer.get("jag", 0.16))
	var span_len: Array = layer.get("length", [0.6, 1.4])
	var bolts: Array = []  # [points, width, alpha at the far end]
	for i in int(layer.get("amount", 5)):
		var dir := (_random_unit(rng) - direction * 0.6).normalized()
		var reach := rng.randf_range(float(span_len[0]), float(span_len[1]))
		bolts.append([_bolt_points(global_position, global_position + dir * reach, rng, jag),
			width * rng.randf_range(0.6, 1.0), 0.0])
	var opacity := fade * float(layer.get("opacity", 1.0)) * rng.randf_range(0.7, 1.0)
	if _retiring:
		opacity *= 1.0 - smoothstep(0.0, 0.22, _elapsed - _retire_at)
	(node.material_override as ShaderMaterial).set_shader_parameter("opacity", opacity)
	_draw_arcs(node.mesh as ImmediateMesh, bolts)

## A lightning path from `a` to `b` by midpoint displacement: each halving
## bends the middle sideways by up to `jag` of that piece's length, down to
## pieces about 0.25 m long.
func _bolt_points(a: Vector3, b: Vector3, rng: RandomNumberGenerator, jag: float) -> PackedVector3Array:
	var points := PackedVector3Array([a, b])
	var depth := clampi(int(ceil(log(maxf(a.distance_to(b), 0.26) / 0.25) / log(2.0))), 1, 6)
	for d in depth:
		var next := PackedVector3Array()
		for i in points.size() - 1:
			var p := points[i]
			var q := points[i + 1]
			var side := (q - p).normalized().cross(_random_unit(rng)).normalized()
			next.append(p)
			next.append((p + q) * 0.5 + side * p.distance_to(q) * rng.randf_range(-jag, jag) * 2.0)
		next.append(points[points.size() - 1])
		points = next
	return points

static func _random_unit(rng: RandomNumberGenerator) -> Vector3:
	var v := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
	return v.normalized() if v.length_squared() > 0.0001 else Vector3.UP

func _camera_position(fallback: Vector3) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	return camera.global_position if camera != null else fallback + Vector3.UP

func _draw_arcs(mesh: ImmediateMesh, bolts: Array) -> void:
	mesh.clear_surfaces()
	if bolts.is_empty():
		return
	var eye := _camera_position(global_position)
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for bolt: Array in bolts:
		var points: PackedVector3Array = bolt[0]
		var width: float = bolt[1]
		var far_alpha: float = bolt[2]
		var count := points.size()
		var sides := PackedVector3Array()
		for i in count:
			var dir := (points[mini(i + 1, count - 1)] - points[maxi(i - 1, 0)]).normalized()
			var side := dir.cross((eye - points[i]).normalized())
			sides.append((side.normalized() if side.length_squared() > 0.0001 else Vector3.RIGHT) * width * 0.5)
		for i in count - 1:
			var a0 := lerpf(1.0, far_alpha, float(i) / float(count - 1))
			var a1 := lerpf(1.0, far_alpha, float(i + 1) / float(count - 1))
			var quad := [[points[i] - sides[i], 0.0, a0], [points[i] + sides[i], 1.0, a0],
				[points[i + 1] + sides[i + 1], 1.0, a1], [points[i + 1] - sides[i + 1], 0.0, a1]]
			for corner in [0, 1, 2, 0, 2, 3]:
				var v: Array = quad[corner]
				mesh.surface_set_color(Color(1, 1, 1, v[2]))
				mesh.surface_set_uv(Vector2(0.0, v[1]))
				mesh.surface_add_vertex(v[0])
	mesh.surface_end()

## A trail left in the world (energy_trail.gdshader): the bolt drops a point
## every `spacing` metres and each lives `span` seconds where it fell, so the
## trail hangs in the air behind the bolt and dissolves there. With age a
## point drifts up by `rise` m/s and sideways on a per-point swirl by `wander`
## m/s, and the strip widens from `width`[0] to `width`[1].
func _build_trail(layer: Dictionary, colour: Color) -> Node3D:
	var material := ShaderMaterial.new()
	material.shader = TRAIL_SHADER
	material.set_shader_parameter("tint", _layer_colour(layer, colour))
	material.set_shader_parameter("flow", asset(VFXLibrary.asset_path("vfx_noise_flow")))
	material.set_shader_parameter("hot", float(layer.get("hot", 0.6)))
	material.set_shader_parameter("erosion", float(layer.get("erosion", 0.8)))
	material.set_shader_parameter("noise_scale", float(layer.get("noise_scale", 1.2)))
	material.set_shader_parameter("opacity", float(layer.get("opacity", 1.0)))
	material.set_shader_parameter("seed", randf() * 10.0)
	var node := _world_strip("Layer_Trail", material)
	node.set_meta("points", PackedVector3Array())
	node.set_meta("swirl", PackedVector3Array())
	node.set_meta("born", PackedFloat32Array())
	node.set_meta("metres", PackedFloat32Array())
	node.set_meta("seed", randf() * 100.0)
	node.set_meta("travelled", 0.0)
	node.set_meta("emitted", 0.0)
	return node

func _update_trail(node: MeshInstance3D, layer: Dictionary, delta: float) -> void:
	var points: PackedVector3Array = node.get_meta("points")
	var swirl: PackedVector3Array = node.get_meta("swirl")
	var born: PackedFloat32Array = node.get_meta("born")
	var metres: PackedFloat32Array = node.get_meta("metres")
	var span := float(layer.get("span", 0.25))
	var seed := float(node.get_meta("seed"))
	if _live(follow_target):
		var head := follow_target.global_position
		var travelled := float(node.get_meta("travelled"))
		var last: Vector3 = node.get_meta("last_head", head)
		var seg := head - last
		var dist := seg.length()
		if dist > 0.0001:
			var dir := seg / dist
			var side := dir.cross(Vector3.UP)
			side = side.normalized() if side.length_squared() > 0.0001 else Vector3.RIGHT
			var up := side.cross(dir).normalized()
			var spacing := float(layer.get("spacing", 0.08))
			var at := float(node.get_meta("emitted")) + spacing
			while at <= travelled + dist:
				var k := (at - travelled) / dist
				var turn := at * 2.1 + seed * 1.9 + sin(at * 0.9 + seed) * 2.0
				points.append(last.lerp(head, k))
				swirl.append(side * cos(turn) + up * sin(turn))
				born.append(_elapsed - (1.0 - k) * delta)
				metres.append(at)
				at += spacing
			node.set_meta("emitted", at - spacing)
			node.set_meta("travelled", travelled + dist)
		node.set_meta("last_head", head)
	var drop := 0
	while drop < born.size() and _elapsed - born[drop] > span:
		drop += 1
	if drop > 0:
		points = points.slice(drop)
		swirl = swirl.slice(drop)
		born = born.slice(drop)
		metres = metres.slice(drop)
	node.set_meta("points", points)
	node.set_meta("swirl", swirl)
	node.set_meta("born", born)
	node.set_meta("metres", metres)
	var mesh := node.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var count := points.size()
	if count < 2:
		return
	var width: Array = layer.get("width", [0.2, 0.5])
	var rise := float(layer.get("rise", 0.0))
	var wander := float(layer.get("wander", 0.0))
	var newest := metres[count - 1]
	var eye := _camera_position(points[count - 1])
	var drawn := PackedVector3Array()
	drawn.resize(count)
	for i in count:
		var age_s := _elapsed - born[i]
		drawn[i] = points[i] + Vector3.UP * rise * age_s + swirl[i] * wander * age_s
	var opacity := 1.0
	if _retiring:
		opacity = 1.0 - smoothstep(0.0, span, _elapsed - _retire_at) * 0.5
	(node.material_override as ShaderMaterial).set_shader_parameter("opacity", float(layer.get("opacity", 1.0)) * opacity)
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in count:
		var age := clampf((_elapsed - born[i]) / span, 0.0, 1.0)
		var tangent := (drawn[mini(i + 1, count - 1)] - drawn[maxi(i - 1, 0)]).normalized()
		var side := tangent.cross((eye - drawn[i]).normalized())
		side = side.normalized() if side.length_squared() > 0.0001 else Vector3.RIGHT
		var half := lerpf(float(width[0]), float(width[1]), age) * 0.5
		# the strip grows out of the head instead of starting at full width
		var alpha := smoothstep(0.0, 0.35, newest - metres[i]) if _live(follow_target) else 1.0
		for edge in [-1.0, 1.0]:
			mesh.surface_set_color(Color(1, 1, 1, alpha))
			mesh.surface_set_uv(Vector2(age, 0.0 if edge < 0.0 else 1.0))
			mesh.surface_set_uv2(Vector2(metres[i], 0.0))
			mesh.surface_add_vertex(drawn[i] + side * half * edge)
	mesh.surface_end()

func _build_light(layer: Dictionary, colour: Color) -> Node3D:
	var light := OmniLight3D.new()
	light.name = "Layer_Light"
	light.light_color = _layer_colour(layer, colour)
	light.light_energy = float(layer.get("energy", 2.0))
	light.omni_range = float(layer.get("range", 6.0))
	light.shadow_enabled = false
	light.set_meta("peak_energy", light.light_energy)
	add_child(light)
	light.global_position = base_position + Vector3.UP * 0.4
	return light

# ------------------------------------------------------------------ lifecycle

func _process(delta: float) -> void:
	if cancelled:
		return
	_elapsed += delta
	if _has_caster and not is_instance_valid(caster):
		cancel()
		return
	if _live(follow_target):
		var anchor := follow_target.global_position
		global_position += anchor - _follow_anchor
		_follow_anchor = anchor
	if _audio_looping and is_instance_valid(_audio_manager):
		# the pooled voice is placed once, so it has to be told to ride along
		_audio_manager.move_loop(_audio_key, self, global_position)
	for entry: Dictionary in _layers:
		_tick_layer(entry, delta)
	if _follow_owned:
		# the bolt is gone: nothing owns this stage any more
		if not _live(follow_target):
			_finish()
		return
	if _elapsed >= _duration:
		_finish()

## A follow target that left the tree can no longer be read; it counts as gone.
static func _live(node: Variant) -> bool:
	return node != null and is_instance_valid(node) and (node as Node).is_inside_tree()

func _tick_layer(entry: Dictionary, delta: float) -> void:
	var node: Node3D = entry["node"]
	if not is_instance_valid(node):
		return
	var layer: Dictionary = entry["layer"]
	var age: float = _elapsed - float(entry["offset"])
	if age < 0.0 or bool(layer.get("hidden", false)):
		return
	node.visible = true
	var life := float(layer.get("life", 0.0))
	# fade curves: nothing pops, everything is a curve
	var fade := _fade_for(layer, age, life)
	match String(layer.get("kind", "")):
		"flipbook", "sprite":
			var material := (node as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
			if layer.has("energy_shape"):
				material.set_shader_parameter("phase", clampf(age / maxf(life, 0.01), 0.0, 1.0))
				material.set_shader_parameter("aim", direction)
			else:
				# a flipbook walks its atlas; a sprite holds the cell it was placed on
				var frame := float(layer.get("frame", 0)) if layer["kind"] == "sprite" else _flipbook_frame(layer, age)
				material.set_shader_parameter("frame", frame)
			material.set_shader_parameter("opacity", fade * float(layer.get("opacity", 1.0)))
			if node.has_meta("spin"):
				node.rotate_y(delta * float(node.get_meta("spin")))
			if layer.has("grow"):
				# scale over life: a burst blooms, a flash pops and shrinks
				var span: Array = layer["grow"]
				var k := clampf(age / maxf(life, 0.01), 0.0, 1.0)
				node.scale = Vector3.ONE * lerpf(float(span[0]), float(span[1]), 1.0 - pow(1.0 - k, 2.2))
			if node.has_meta("flicker"):
				node.scale = Vector3.ONE * (0.85 + 0.3 * sin(_elapsed * 47.0) * randf())
		"particles":
			var particles := node as GPUParticles3D
			if not bool(layer.get("continuous", false)) and age > life and particles.emitting:
				particles.emitting = false
			var trailing := particles.process_material as ShaderMaterial
			if trailing != null and bool(layer.get("continuous", false)):
				var here := particles.global_position
				trailing.set_shader_parameter("emit_motion", here - (particles.get_meta("last_pos", here) as Vector3))
				particles.set_meta("last_pos", here)
		"ribbon":
			_update_ribbon(node as MeshInstance3D)
			if _retiring:
				((node as MeshInstance3D).material_override as ShaderMaterial).set_shader_parameter("opacity",
					1.0 - smoothstep(0.0, 0.24, _elapsed - _retire_at))
		"arc":
			_update_arc(node as MeshInstance3D, layer, age, fade)
		"trail":
			_update_trail(node as MeshInstance3D, layer, delta)
		"light":
			(node as OmniLight3D).light_energy = float(node.get_meta("peak_energy", 2.0)) * fade

## The atlas cell a flipbook shows at `age`: it walks the sheet from the layer's
## start frame (in steps of `frame_step` cells, the low preset's coarser
## stepping) and holds the last cell when the layer does not loop.
func _flipbook_frame(layer: Dictionary, age: float) -> float:
	var entry := VFXLibrary.asset(String(layer.get("atlas", layer.get("tex", ""))))
	var frames := float(entry.get("frames", 1))
	var fps := float(layer.get("fps", entry.get("fps", 20)))
	if bool(layer.get("fit", false)) and float(layer.get("life", 0.0)) > 0.0:
		# play the whole sequence over the layer's life (a short impact, a long burn)
		fps = frames / float(layer["life"])
	var base := float(layer.get("frame", 0))
	if frames <= 1.0 or fps <= 0.0:
		return base
	var advance := age * fps
	if bool(layer.get("loop", false)):
		advance = fmod(advance, maxf(1.0, frames - base))
	var step := maxf(1.0, float(layer.get("frame_step", 1)))
	return minf(base + floorf(advance / step + 0.5) * step, frames - 1.0)

func _fade_for(layer: Dictionary, age: float, life: float) -> float:
	if life <= 0.0:
		return 1.0
	var k := clampf(age / life, 0.0, 1.0)
	match String(layer.get("fade", "out")):
		"in":
			return smoothstep(0.0, 0.35, k) * (1.0 - smoothstep(0.8, 1.0, k))
		"hold":
			return smoothstep(0.0, 0.12, k) * (1.0 - smoothstep(0.82, 1.0, k))
		"slow":
			return smoothstep(0.0, 0.2, k) * (1.0 - smoothstep(0.65, 1.0, k))
	return 1.0 - smoothstep(0.55, 1.0, k)

## A tapered strip along the followed body's last ~0.5 s of motion.
func _update_ribbon(node: MeshInstance3D) -> void:
	var history: PackedVector3Array = node.get_meta("history")
	var origin := follow_target.global_position if _live(follow_target) else global_position
	if history.is_empty() or history[history.size() - 1].distance_squared_to(origin) > 0.0001:
		history.push_back(origin)
	# decimated so a slow frame cannot grow the strip
	while history.size() > 32:
		history.remove_at(0)
	# a retired wake draws in toward where the bolt ended as it fades
	if _retiring and history.size() > 3:
		history.remove_at(0)
		history.remove_at(0)
	node.set_meta("history", history)
	var max_length := float(node.get_meta("max_length"))
	var width := float(node.get_meta("width"))
	var mesh := node.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var count := history.size()
	if count < 3:
		return
	var eye := _camera_position(origin)
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var travelled := 0.0
	for i in count:
		var idx := count - 1 - i
		var point := history[idx]
		if i > 0:
			travelled += point.distance_to(history[idx + 1])
		var age := float(i) / float(count)
		var dir := (point - history[idx - 1]).normalized() if idx > 0 else direction
		var side := dir.cross((eye - point).normalized())
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		side = side.normalized() * width * lerpf(1.0, 0.06, age)
		var fade := (1.0 - age) * (1.0 - clampf(travelled / max_length, 0.0, 1.0))
		for edge in [-1.0, 1.0]:
			mesh.surface_set_color(Color(1, 1, 1, fade))
			mesh.surface_set_uv(Vector2(age, 0.0 if edge < 0.0 else 1.0))
			mesh.surface_set_uv2(Vector2(travelled, 0.0))
			mesh.surface_add_vertex(point + side * edge)
	mesh.surface_end()

## The bolt ended: the travel stage stops following it, its heart goes out and
## the wake fades where the bolt ended.
func retire_travel() -> void:
	if _retiring or cancelled:
		return
	_retiring = true
	_retire_at = _elapsed
	_follow_owned = false
	follow_target = null
	_duration = _elapsed + 0.26
	_stop_audio()
	for entry: Dictionary in _layers:
		var layer: Dictionary = entry["layer"]
		var node: Node = entry["node"]
		match String(layer.get("kind", "")):
			"trail":
				# a trail left in the air dissolves at its own pace
				_duration = maxf(_duration, _elapsed + float(layer.get("span", 0.25)))
			"ribbon":
				# a kinked filament holds its last shape while it fades: re-struck
				# kinks on a wake that no longer moves jittered from side to side
				var ribbon := (node as MeshInstance3D).material_override as ShaderMaterial
				ribbon.set_shader_parameter("strike_hold", floorf(float(Time.get_ticks_msec()) / 1000.0 * 14.0))
				ribbon.set_shader_parameter("strike_hz", 0.0)
			"particles":
				(node as GPUParticles3D).emitting = false
			"flipbook", "sprite":
				# the bolt's heart is spent on impact: only the wake fades out
				(node as Node3D).visible = false
				entry["layer"] = layer.duplicate()
				entry["layer"]["hidden"] = true

## Stop emitting, hide, and free after one short beat (so a quad does not
## vanish between two frames).
func cancel() -> void:
	if cancelled:
		return
	cancelled = true
	_stop_audio()
	for entry: Dictionary in _layers:
		var node: Node3D = entry["node"]
		if not is_instance_valid(node):
			continue
		if node is GPUParticles3D:
			(node as GPUParticles3D).emitting = false
		else:
			node.visible = false
	var tween := create_tween()
	tween.tween_interval(0.08)
	tween.tween_callback(_finish)

func _finish() -> void:
	_stop_audio()
	queue_free()

func _stop_audio() -> void:
	if _audio_started.is_empty() or not is_instance_valid(_audio_manager):
		return
	for key in _audio_started:
		_audio_manager.stop_sound(key, self)
	_audio_started.clear()

func _exit_tree() -> void:
	_stop_audio()
