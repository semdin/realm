extends Node3D
class_name WardShield

## The ward round its caster for the ward's duration, drawn as a living energy
## shell: a sphere under ward_surface(_back).gdshader, far side then near side
## (plasma filaments flowing over it on a warp field, a soft fresnel limb,
## glints), a few motes drifting over it (ward_motes.gdshader, ember_spark
## draw pass), the hum / ping / collapse sounds and a restrained light above
## the low preset. Presentation only: the server applies the ward's damage
## reduction and decides a reflect.
##
##   raise    the shell is woven outward from the wand in RAISE_SECONDS, a hot
##            front sweeping round it, motes thrown out to it, a settling flare;
##   sustain  the surface flows and breathes, motes ride it;
##   a blow   (`on_hit` / `impact`): a flare where it met the shell, a wave
##            through the filaments, a sprung dent, a few sparks;
##   reflect  (`flash_reflect`): a white parry flare and star flash on the side
##            the bolt came from, a stronger double wave, the shell punched
##            outward and a spray of sparks thrown back along the bolt's path;
##   end      it burns away along the erosion noise in END_SECONDS, shedding
##            motes.
## `WardShield.of(hero)` is the ward raised round a hero, while it holds.

## The shell is a 1 m sphere drawn SHELL_RADIUS round a centre CENTRE_LIFT
## above the caster's feet.
const SHELL_RADIUS := 1.7
const CENTRE_LIFT := 1.0
const RAISE_SECONDS := 0.32
const END_SECONDS := 0.55
const MAX_HITS := 4
## A blow's marks on the shell are over after this long (the shader's own
## windows are shorter).
const HIT_SECONDS := 1.0
const REFLECT_POWER := 2.6
const REFLECT_FLARE_SECONDS := 0.32
const META := &"ward_shield"
const NOISE := "res://assets/vfx/tex/ward_noise_512.png"
const SURFACE := preload("res://assets/shaders/ward_surface.gdshader")
const SURFACE_BACK := preload("res://assets/shaders/ward_surface_back.gdshader")
const MOTES := preload("res://assets/shaders/ward_motes.gdshader")

## Shared across wards (several warded players at once draw with one set).
static var _sphere: SphereMesh = null
static var _mote_draw: QuadMesh = null
static var _mote_ramp: GradientTexture1D = null
static var _spark_ramp: GradientTexture1D = null

var caster: Node3D
var duration := 3.5
## The ward spell this shell is (its colour and sounds).
var spell_id := "ward_shield"
var elapsed := 0.0
var _colour := Color(0.25, 0.62, 1.0)
var _shell: MeshInstance3D
## The near side; its far side (`_back`) draws first.
var _material: ShaderMaterial
var _back: ShaderMaterial
var _light: OmniLight3D
var _drift: GPUParticles3D
var _hits := PackedVector4Array()
var _powers := PackedFloat32Array()
var _next_hit := 0
var _flash := 0.0
var _punch_age := 10.0
var _ending := false
var _end_age := 0.0
## Reflect flares riding the shell: [MeshInstance3D, age, life].
var _flares: Array = []

## A ward on `hero` for `seconds`, under `world`.
static func raise(world: Node3D, hero: Node3D, seconds: float, p_spell_id := "ward_shield") -> WardShield:
	var ward := WardShield.new()
	ward.name = "WardShield"
	ward.caster = hero
	ward.duration = seconds
	ward.spell_id = p_spell_id
	world.add_child(ward)
	ward.global_position = hero.global_position + Vector3.UP * CENTRE_LIFT
	ward._aim_raise()
	hero.set_meta(META, ward)
	return ward

## The ward raised round `hero` while it still holds (not once it is
## breaking up), else null.
static func of(hero: Node) -> WardShield:
	if hero == null or not is_instance_valid(hero) or not hero.has_meta(META):
		return null
	var ward: Variant = hero.get_meta(META)
	if not is_instance_valid(ward) or (ward as WardShield)._ending or (ward as WardShield).is_queued_for_deletion():
		return null
	return ward as WardShield

func _sound(stage: String) -> String:
	return "spell_%s_%s" % [spell_id, stage]

func _ready() -> void:
	_colour = VFXLibrary.spell_colour(spell_id)
	for i in MAX_HITS:
		_hits.append(Vector4(0, 0, 1, 10.0))
		_powers.append(0.0)
	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.scale = Vector3.ONE * 0.01
	_shell.mesh = _sphere_mesh()
	_back = ShaderMaterial.new()
	_back.shader = SURFACE_BACK
	_back.render_priority = -1
	_material = ShaderMaterial.new()
	_material.shader = SURFACE
	_back.next_pass = _material
	_shade("noise_tex", SpellEffect.asset(NOISE))
	_shade("tint", _colour)
	_shade("bloom", 0.0)
	_shade("hits", _hits)
	_shade("hit_power", _powers)
	_shell.material_override = _back
	add_child(_shell)
	# the shell's light comes from its shader; a moving light is a cost the
	# low preset does not pay
	if SkillFX.quality != "low":
		_light = OmniLight3D.new()
		_light.light_color = _colour
		_light.omni_range = 5.0
		_light.shadow_enabled = false
		_light.light_energy = 0.0
		add_child(_light)
	_drift = _motes(0, int(round(lerpf(10.0, 20.0, _particle_share()))), 2.2)
	_drift.emitting = false
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.loop_sound(_sound("sustain"), self)

## The raise sweeps out of the wand (or the way the caster faces: HeroView
## models look along +Z).
func _aim_raise() -> void:
	var from := caster.global_transform.basis.z if is_instance_valid(caster) else Vector3.FORWARD
	var tip := SkillFX.wand_tip(caster)
	if tip != null and tip.global_position.distance_to(global_position) > 0.15:
		from = tip.global_position - global_position
	from = from.normalized() if from.length_squared() > 0.0001 else Vector3.FORWARD
	_shade("bloom_dir", from)
	var burst := _motes(1, 26, 0.75)
	burst.one_shot = true
	burst.explosiveness = 0.85
	(burst.process_material as ShaderMaterial).set_shader_parameter("origin_dir", from)
	burst.emitting = true

func _particle_share() -> float:
	return float((VFXLibrary.QUALITY.get(SkillFX.quality, VFXLibrary.QUALITY["low"]) as Dictionary)["particles"])

func _process(delta: float) -> void:
	elapsed += delta
	if not is_instance_valid(caster):
		queue_free()
		return
	global_position = caster.global_position + Vector3.UP * CENTRE_LIFT
	if not _ending and elapsed >= duration:
		_begin_end()
	if _ending:
		_end_age += delta
		if _end_age >= END_SECONDS:
			_finish()
			return
	_flash = maxf(0.0, _flash - delta * 3.2)
	_punch_age += delta
	if elapsed > RAISE_SECONDS and not _ending and not _drift.emitting:
		_drift.emitting = true
	# raise: an overshooting grow, the sweep and a flare that settles
	var raise_k := clampf(elapsed / RAISE_SECONDS, 0.0, 1.0)
	var grow := lerpf(0.42, 1.0, _ease_out_back(clampf(elapsed / (RAISE_SECONDS * 1.1), 0.0, 1.0)))
	var settle := 0.55 * exp(-maxf(0.0, elapsed - RAISE_SECONDS * 0.6) * 5.0) if elapsed > RAISE_SECONDS * 0.6 else 0.55 * raise_k
	var breathe := 0.93 + 0.07 * sin(elapsed * TAU * 0.6)
	# a reflect punches the shell out and lets it spring back
	var punch := 0.09 * exp(-_punch_age * 8.0) * cos(_punch_age * 22.0) if _punch_age < 0.8 else 0.0
	var end_k := clampf(_end_age / END_SECONDS, 0.0, 1.0) if _ending else 0.0
	var radius := SHELL_RADIUS * grow * (1.0 + punch + 0.07 * end_k * end_k)
	_shell.scale = Vector3.ONE * maxf(0.01, radius)
	_shade("clock", elapsed)
	_shade("bloom", 1.0 - pow(1.0 - raise_k, 2.2))
	_shade("intensity", breathe * (1.0 + 0.3 * end_k))
	_shade("flash", _flash + settle)
	_shade("erode", end_k)
	_shade("floor_local", -CENTRE_LIFT / maxf(0.01, radius))
	var live := false
	for i in MAX_HITS:
		var hit := _hits[i]
		if hit.w < HIT_SECONDS:
			hit.w += delta
			_hits[i] = hit
			live = true
	if live:
		_shade("hits", _hits)
	for entry: Array in _flares.duplicate():
		_tick_flare(entry, delta)
	if _light != null:
		# a restrained pulse: never a strobing light over the player's eyes
		_light.light_energy = (0.9 * breathe + 2.6 * _flash) * (1.0 - end_k) * raise_k

## One blow the ward took at `point` (world): a flare where the blow met the
## shell, a wave through it, a sprung dent, a few sparks and the ping.
func on_hit(point: Vector3) -> void:
	if _ending:
		return
	# the contact is on the body at chest height: the blow crossed the shell
	# level with it, on the side it came from
	var offset := point - global_position
	var flat := Vector3(offset.x, 0.0, offset.z)
	if flat.length_squared() > 0.0025:
		offset = flat.normalized() * SHELL_RADIUS + Vector3(0.0, offset.y, 0.0)
	var dir := _shell_dir(offset)
	_mark(dir, 1.0)
	_flash = maxf(_flash, 0.35)
	_sparks(dir, 14, Vector2(1.5, 4.5), 60.0, 0.45, 0.022)
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_sound_at(_sound("impact"), global_position + dir * SHELL_RADIUS, self)

## An ordinary blow absorbed at `world_pos` (the same as `on_hit`).
func impact(world_pos: Vector3) -> void:
	on_hit(world_pos)

## A perfect reflect: the bolt that came from `from_dir` (world direction
## from the ward toward where the bolt came from) is thrown back. A white
## parry flare and star flash on that side of the shell, a strong double wave
## over it, the shell punched outward and a spray of sparks back along the
## bolt's path.
func flash_reflect(from_dir: Vector3) -> void:
	if _ending:
		return
	var dir := _shell_dir(from_dir)
	_mark(dir, REFLECT_POWER)
	_flash = 1.0
	_punch_age = 0.0
	# a hot, fast spray back at the caster, and slower embers spilling round
	# the shell
	_sparks(dir, 48, Vector2(5.0, 13.0), 55.0, 0.5, 0.032, 0.012, 6.0)
	_sparks(dir, 26, Vector2(1.5, 4.0), 100.0, 0.9, 0.022, 0.008, 3.0)
	_flare(dir, "vfx_wand_flash", 1.8, REFLECT_FLARE_SECONDS)
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		var at := global_position + dir * SHELL_RADIUS
		var ping: Node = audio.play_sound_at(_sound("impact"), at, self)
		if ping != null:
			ping.set("pitch_scale", 1.35)
		var ring: Node = audio.play_sound_at(_sound("cast"), at, self)
		if ring != null:
			ring.set("pitch_scale", 1.2)

## Where a blow coming from `from_dir` (world direction from the ward toward
## its source) meets the shell, in world space: the place for a bolt's own
## impact on a warded body.
func shell_point(from_dir: Vector3) -> Vector3:
	return global_position + _shell_dir(from_dir) * _shell.scale.x

## A unit direction in the shell's space (the world's axes) toward `offset`.
func _shell_dir(offset: Vector3) -> Vector3:
	if offset.length_squared() < 0.0001:
		offset = caster.global_transform.basis.z if is_instance_valid(caster) else Vector3.FORWARD
	return offset.normalized()

func _mark(dir: Vector3, power: float) -> void:
	_hits[_next_hit] = Vector4(dir.x, dir.y, dir.z, 0.0)
	_powers[_next_hit] = power
	_next_hit = (_next_hit + 1) % MAX_HITS
	_shade("hits", _hits)
	_shade("hit_power", _powers)

## Both sides of the shell take every parameter.
func _shade(param: StringName, value: Variant) -> void:
	_back.set_shader_parameter(param, value)
	_material.set_shader_parameter(param, value)

## A smooth unit sphere: the silhouette and the dents stay round up close.
static func _sphere_mesh() -> SphereMesh:
	if _sphere == null:
		_sphere = SphereMesh.new()
		_sphere.radius = 1.0
		_sphere.height = 2.0
		_sphere.radial_segments = 64
		_sphere.rings = 32
	return _sphere

## Motes in `mode` (ward_motes.gdshader), local to the ward.
func _motes(mode: int, amount: int, life: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "Motes%d" % mode
	particles.amount = maxi(1, amount)
	particles.lifetime = life
	particles.local_coords = true
	particles.randomness = 0.3
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-4, -2, -4), Vector3(8, 6, 8))
	particles.draw_pass_1 = _mote_quad()
	var process := ShaderMaterial.new()
	process.shader = MOTES
	process.set_shader_parameter("mode", mode)
	process.set_shader_parameter("radius", SHELL_RADIUS)
	process.set_shader_parameter("floor_y", -CENTRE_LIFT)
	process.set_shader_parameter("ramp", _mote_gradient(_colour))
	match mode:
		0:
			process.set_shader_parameter("size_min", 0.008)
			process.set_shader_parameter("size_max", 0.02)
			process.set_shader_parameter("energy", 0.8)
		1:
			process.set_shader_parameter("size_min", 0.008)
			process.set_shader_parameter("size_max", 0.02)
			process.set_shader_parameter("stretch", 0.006)
			process.set_shader_parameter("energy", 1.0)
		2:
			process.set_shader_parameter("size_min", 0.01)
			process.set_shader_parameter("size_max", 0.026)
			process.set_shader_parameter("stretch", 0.04)
			process.set_shader_parameter("energy", 1.0)
	particles.process_material = process
	add_child(particles)
	return particles

static func _mote_quad() -> QuadMesh:
	if _mote_draw == null:
		_mote_draw = QuadMesh.new()
		var draw := ShaderMaterial.new()
		draw.shader = SpellEffect.EMBER_DRAW
		_mote_draw.material = draw
	return _mote_draw

## White-hot -> pale ward blue -> ward blue -> a dim deep blue, fading.
static func _mote_gradient(colour: Color) -> GradientTexture1D:
	if _mote_ramp == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.1, 0.45, 1.0])
		gradient.colors = PackedColorArray([Color(0.9, 0.97, 1.0, 1.0), colour.lerp(Color.WHITE, 0.45),
			colour, Color(colour.r * 0.4, colour.g * 0.55, colour.b * 0.8, 0.0)])
		_mote_ramp = GradientTexture1D.new()
		_mote_ramp.gradient = gradient
		_mote_ramp.width = 64
	return _mote_ramp

static func _spark_gradient(colour: Color) -> GradientTexture1D:
	if _spark_ramp == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.05, 0.25, 0.8, 1.0])
		gradient.colors = PackedColorArray([Color(1.0, 1.0, 1.0, 1.0), colour.lerp(Color.WHITE, 0.55), colour,
			Color(colour.r * 0.35, colour.g * 0.5, colour.b * 0.75, 0.7), Color(colour.r * 0.2, colour.g * 0.3, colour.b * 0.5, 0.0)])
		_spark_ramp = GradientTexture1D.new()
		_spark_ramp.gradient = gradient
		_spark_ramp.width = 64
	return _spark_ramp

## Real sparks (ember_particles.gdshader) thrown off the shell at `dir` into
## a cone round it, in world space so they fly on when the caster moves.
func _sparks(dir: Vector3, amount: int, speed: Vector2, spread: float, life: float, size_max: float,
		size_min := 0.008, gravity := 4.0) -> void:
	var world := get_parent() as Node3D
	if world == null:
		return
	var particles := GPUParticles3D.new()
	particles.name = "WardSparks"
	particles.amount = amount
	particles.lifetime = life
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	particles.draw_pass_1 = _mote_quad()
	var process := ShaderMaterial.new()
	process.shader = SpellEffect.EMBER_PROCESS
	process.set_shader_parameter("dir", (dir + Vector3.UP * 0.15).normalized())
	process.set_shader_parameter("spread_deg", spread)
	process.set_shader_parameter("speed_min", speed.x)
	process.set_shader_parameter("speed_max", speed.y)
	process.set_shader_parameter("size_min", size_min)
	process.set_shader_parameter("size_max", size_max)
	process.set_shader_parameter("gravity", gravity)
	process.set_shader_parameter("drag", 2.2)
	process.set_shader_parameter("turbulence", 1.5)
	process.set_shader_parameter("stretch", 0.016)
	process.set_shader_parameter("emit_radius", 0.12)
	process.set_shader_parameter("floor_y", global_position.y - CENTRE_LIFT)
	process.set_shader_parameter("energy", 1.0)
	process.set_shader_parameter("ramp", _spark_gradient(_colour))
	particles.process_material = process
	world.add_child(particles)
	particles.global_position = global_position + dir * _shell.scale.x * 1.02
	particles.emitting = true
	particles.finished.connect(particles.queue_free)

## A flipbook flash on the shell at `dir`, facing the camera, riding the
## shell (one quad, SpellEffect's additive layer shader).
func _flare(dir: Vector3, atlas: String, size: float, life: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var material := ShaderMaterial.new()
	material.shader = SpellEffect.SHADER_ADD
	material.set_shader_parameter("atlas", SpellEffect.asset(VFXLibrary.asset_path(atlas)))
	material.set_shader_parameter("grid", Vector2(8, 8))
	material.set_shader_parameter("billboard", true)
	material.set_shader_parameter("roll", randf() * TAU)
	material.set_shader_parameter("soft_fade", 0.0)
	material.set_shader_parameter("tint", _colour.lerp(Color.WHITE, 0.45))
	quad.material = material
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	node.position = dir * _shell.scale.x * 1.02
	_flares.append([node, 0.0, life])
	_tick_flare(_flares[-1], 0.0)

func _tick_flare(entry: Array, delta: float) -> void:
	var node := entry[0] as MeshInstance3D
	var age := float(entry[1]) + delta
	entry[1] = age
	var k := clampf(age / float(entry[2]), 0.0, 1.0)
	var material := (node.mesh as QuadMesh).material as ShaderMaterial
	# from its sixth cell: the clip opens on a plain white disc
	material.set_shader_parameter("frame", floorf(6.0 + k * 57.0))
	material.set_shader_parameter("opacity", 1.0 - smoothstep(0.55, 1.0, k))
	if k >= 1.0:
		_flares.erase(entry)
		node.queue_free()

## The ward ends: the shell burns away along the erosion noise, shedding
## motes, then clears.
func _begin_end() -> void:
	if _ending:
		return
	_ending = true
	_end_age = 0.0
	_drift.emitting = false
	var shed := _motes(2, 48, 0.9)
	shed.one_shot = true
	shed.explosiveness = 0.35
	(shed.process_material as ShaderMaterial).set_shader_parameter("radius", _shell.scale.x)
	shed.emitting = true

func _finish() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_sound_at(_sound("end"), global_position, self)
	queue_free()

func _exit_tree() -> void:
	if is_instance_valid(caster) and caster.get_meta(META, null) == self:
		caster.remove_meta(META)
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.stop_sound(_sound("sustain"), self)

static func _ease_out_back(x: float) -> float:
	const C1 := 1.9
	const C3 := C1 + 1.0
	return 1.0 + C3 * pow(x - 1.0, 3.0) + C1 * pow(x - 1.0, 2.0)
