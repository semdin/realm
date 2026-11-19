extends Node3D
class_name WardShield

## The ward round its caster for the ward's duration: the authored shell
## (shield_shell.glb) with a flowing noise field, a hex lattice and a bright
## rim (ward_surface.gdshader), a positional ripple per blow it takes, an
## erosion fracture when it ends, a restrained light above the low preset and
## the hum / ping / collapse sounds. Presentation only: the server applies the
## ward's damage reduction.
##
## Shardglass Ward (`spell_id` shardglass_ward) raises the same shell a little
## wider in its own colour, its surface broken into glinting glass shards
## (shardglass_surface.gdshader) instead of the hex lattice, with its own
## sound keys.

## The shell mesh is 2 m round; drawn 1.8 m in radius.
const SHELL_SCALE := 1.8
## Shardglass Ward's shell is drawn 2 m in radius.
const SHARD_SCALE := 2.0
const MAX_RIPPLES := 4
const RIPPLE_SECONDS := 0.65
const FRACTURE_SECONDS := 0.45

var caster: Node3D
var duration := 3.5
## The ward spell this shell is (its colour, surface and sounds).
var spell_id := "ward_shield"
var elapsed := 0.0
var _shell: MeshInstance3D
var _light: OmniLight3D
var _ripples: Node3D
var _fracturing := false
var _last_hit_age := 10.0

## A ward on `hero` for `seconds`, under `world`.
static func raise(world: Node3D, hero: Node3D, seconds: float, p_spell_id := "ward_shield") -> WardShield:
	var ward := WardShield.new()
	ward.name = "WardShield"
	ward.caster = hero
	ward.duration = seconds
	ward.spell_id = p_spell_id
	world.add_child(ward)
	ward.global_position = hero.global_position + Vector3.UP
	return ward

func _shard() -> bool:
	return spell_id == "shardglass_ward"

func _sound(stage: String) -> String:
	return "spell_%s_%s" % [spell_id, stage]

func _ready() -> void:
	var colour := VFXLibrary.spell_colour(spell_id)
	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.scale = Vector3.ONE * 0.01
	var packed := SpellEffect.asset(VFXLibrary.asset_path("vfx_shield_mesh")) as PackedScene
	if packed != null:
		var source := packed.instantiate()
		var found := source.find_children("*", "MeshInstance3D", true, false)
		if not found.is_empty():
			_shell.mesh = (found[0] as MeshInstance3D).mesh
		source.free()
	var material := ShaderMaterial.new()
	if _shard():
		material.shader = preload("res://assets/shaders/shardglass_surface.gdshader")
		material.set_shader_parameter("flow_noise", SpellEffect.asset(VFXLibrary.asset_path("vfx_noise_flow")))
		material.set_shader_parameter("tint", Color(colour.r, colour.g, colour.b, 0.26))
		material.set_shader_parameter("opacity", 0.85)
	else:
		material.shader = preload("res://assets/shaders/ward_surface.gdshader")
		material.set_shader_parameter("flow_noise", SpellEffect.asset(VFXLibrary.asset_path("vfx_noise_flow")))
		material.set_shader_parameter("tint", Color(colour.r, colour.g, colour.b, 0.26))
		# hex lattice over the dome: the classic force-field read
		material.set_shader_parameter("hex_lattice", SpellEffect.asset(VFXLibrary.asset_path("vfx_hex_shield")))
		material.set_shader_parameter("use_hex", true)
		material.set_shader_parameter("opacity", 0.85)
	_shell.material_override = material
	add_child(_shell)
	_ripples = Node3D.new()
	_ripples.name = "Ripples"
	add_child(_ripples)
	if SkillFX.quality != "low":
		_light = OmniLight3D.new()
		_light.light_color = colour
		_light.omni_range = 5.0
		_light.shadow_enabled = false
		add_child(_light)
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.loop_sound(_sound("sustain"), self)

func _process(delta: float) -> void:
	elapsed += delta
	_last_hit_age += delta
	if not is_instance_valid(caster):
		queue_free()
		return
	global_position = caster.global_position + Vector3.UP
	rotate_y(delta * 0.6)
	var material := _shell.material_override as ShaderMaterial
	material.set_shader_parameter("clock", elapsed)
	if elapsed >= duration:
		_expire()
		return
	var pulse := sin(elapsed * 8.0) * 0.2 + 0.8
	if _light != null:
		# a restrained pulse: never a strobing light over the player's eyes
		_light.light_energy = 1.6 * pulse
	material.set_shader_parameter("hit_age", _last_hit_age)
	material.set_shader_parameter("opacity", 0.7 + 0.25 * pulse)
	_shell.scale = Vector3.ONE * (SHARD_SCALE if _shard() else SHELL_SCALE) * maxf(0.01, smoothstep(0.0, 0.18, elapsed))
	for ripple: MeshInstance3D in _ripples.get_children():
		var age := float(ripple.get_meta("age")) + delta
		ripple.set_meta("age", age)
		var ripple_material := ripple.mesh.surface_get_material(0) as ShaderMaterial
		ripple_material.set_shader_parameter("opacity", clampf(1.0 - age / RIPPLE_SECONDS, 0.0, 1.0))
		ripple_material.set_shader_parameter("frame", floorf(clampf(age / RIPPLE_SECONDS, 0.0, 0.999) * 64.0))
		if age >= RIPPLE_SECONDS:
			ripple.queue_free()

## One blow the ward took at `point`: a ripple on the shell there, a brief
## light and the ping.
func on_hit(point: Vector3) -> void:
	if _fracturing:
		return
	_last_hit_age = 0.0
	(_shell.material_override as ShaderMaterial).set_shader_parameter("hit_point", point)
	if _ripples.get_child_count() >= MAX_RIPPLES:
		_ripples.get_child(0).queue_free()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.4, 1.4)
	var material := ShaderMaterial.new()
	material.shader = SpellEffect.SHADER_ADD
	material.set_shader_parameter("atlas", SpellEffect.asset(VFXLibrary.asset_path("vfx_ripple_blue")))
	material.set_shader_parameter("grid", Vector2(8, 8))
	material.set_shader_parameter("billboard", true)
	material.set_shader_parameter("soft_fade", 0.0)
	if _shard():
		var colour := VFXLibrary.spell_colour(spell_id)
		material.set_shader_parameter("tint", colour.lightened(0.3))
	quad.material = material
	var ripple := MeshInstance3D.new()
	ripple.mesh = quad
	ripple.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ripple.set_meta("age", 0.0)
	_ripples.add_child(ripple)
	ripple.global_position = point
	if _light != null:
		_light.light_energy = 3.2
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_sound_at(_sound("impact"), point, self)

## The ward ends: the shell fractures along the same erosion noise the clips
## were eroded with, then clears.
func _expire() -> void:
	if _fracturing:
		return
	_fracturing = true
	var fracture := create_tween()
	fracture.tween_method(_set_fracture, 0.05, 1.0, FRACTURE_SECONDS)
	fracture.tween_callback(_finish)

func _set_fracture(v: float) -> void:
	var material := _shell.material_override as ShaderMaterial
	material.set_shader_parameter("erode", v)
	if _shard():
		var colour := VFXLibrary.spell_colour(spell_id).lightened(0.25)
		material.set_shader_parameter("tint", Color(colour.r, colour.g, colour.b, 0.4 * (1.0 - v)))
	else:
		material.set_shader_parameter("tint", Color(0.55, 0.85, 1.0, 0.4 * (1.0 - v)))

func _finish() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_sound_at(_sound("end"), global_position, self)
	queue_free()

func _exit_tree() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.stop_sound(_sound("sustain"), self)
