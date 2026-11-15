extends Node3D
class_name GroundWarning

## A creature's telegraphed attack, burning on the ground where it will land:
## the old game's warning, drawn from what the server's telegraph says (shape,
## centre, facing, release tick). CombatView makes one per telegraph, drives
## `set_progress` from the server tick clock and calls `release` on the
## release tick or `cancel` when the server calls the attack off.
##
## It is the ground that burns, built from the game's own fire and not from
## drawn shapes:
##   * the ground: one disc with ground_telegraph.gdshader, projected on the
##     surfaces inside it (it lies on slopes and kerbs), the exact hit area
##     charred and seamed with fire cut from the erosion noise map, a line of
##     fire on its boundary and a ragged front crawling out to the boundary
##     as the countdown;
##   * embers lifting off the boundary (RisingMotes), and a burst of them when
##     it goes off;
##   * a flickering light, the charge and release sounds and the release
##     blast running out to the boundary.
## No flames stand on it and nothing in it is a ruled line or a flat fill.
## Presentation only: the server decides who the attack hits.
##
## The dungeon curses' marks (DungeonHazards) are the same ground in their
## own tint: a ring that fills to its release tick and bursts, or a held
## patch (`held`: the whole area burns at once, no front, no charge sound)
## that cools away (`expire`) when it runs out.

const SHADER := preload("res://assets/shaders/ground_telegraph.gdshader")
const TINT := Color(1.0, 0.38, 0.08)
## The cloud map the fire is cut from (the spell effects' erosion map).
const NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const APPEAR_S := 0.16
const BLAST_S := 0.34
## How long the embers already in the air are left to burn out after a release.
const AFTERGLOW_S := 0.8
const CANCEL_S := 0.15
## A held patch running out cools over this long.
const EXPIRE_S := 0.7
const CHARGE_SOUND := "boss_slam_cast"
const RELEASE_SOUND := "boss_slam_release"

## The material every disc copies, kept for the whole process: a shader freed
## with its last user is compiled again by the next telegraph, mid-fight.
static var _material: ShaderMaterial = null

var reach := 5.0
## A cone's half angle in radians; 4.0 is the whole circle.
var sector := 4.0
var progress := 0.0
## The fire's colour (TINT for a creature's telegraph).
var tint := TINT
## A lasting patch: no countdown, no charge, no blast.
var held := false
var _disc: MeshInstance3D = null
var _embers: GPUParticles3D = null
var _light: OmniLight3D = null
var _appear := 0.0
var _released := false
var _charge: Node = null

static func base_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		_material.set_shader_parameter("tint", TINT)
		if DisplayServer.get_name() != "headless":
			_material.set_shader_parameter("noise", SpellEffect.asset(NOISE))
	return _material

## A warning under `parent`, centred on `center` (the attack's feet point):
## `reach` metres to the boundary (an area's radius, a cone's range),
## `half_angle` > 0 for a cone opening along `facing` (radians, 0 = +Z).
## `colour`: the fire's tint; `lasting`: a held patch (see `held`).
static func spawn(parent: Node, center: Vector3, reach_m: float, half_angle: float, facing: float,
		colour: Color = TINT, lasting := false) -> GroundWarning:
	var warning := GroundWarning.new()
	warning.name = "GroundWarning"
	warning.reach = maxf(0.5, reach_m)
	warning.sector = half_angle if half_angle > 0.0 else 4.0
	warning.tint = colour
	warning.held = lasting
	parent.add_child(warning)
	warning.global_position = center
	warning.rotation.y = facing
	warning._build()
	return warning

## The disc is only the volume the mark falls in: a low drum round the centre
## (taller for a wide area, as a slope climbs further across it), never a flat
## plate a hillside would cut through.
func _build() -> void:
	var half_height := clampf(reach * 0.25, 0.6, 1.4)
	var mesh := CylinderMesh.new()
	mesh.top_radius = reach
	mesh.bottom_radius = reach
	mesh.height = half_height * 2.0
	mesh.radial_segments = 24
	mesh.rings = 1
	# a copy: the fill follows this telegraph's own progress
	var material := base_material().duplicate() as ShaderMaterial
	material.set_shader_parameter("radius", reach)
	material.set_shader_parameter("half_height", half_height)
	material.set_shader_parameter("sector", sector)
	material.set_shader_parameter("fade", 0.0)
	material.set_shader_parameter("tint", tint)
	material.set_shader_parameter("held", 1.0 if held else 0.0)
	mesh.material = material
	_disc = MeshInstance3D.new()
	_disc.name = "Area"
	_disc.mesh = mesh
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_disc.position.y = 0.08
	add_child(_disc)
	var low := SkillFX.quality == "low"
	_embers = RisingMotes.make(reach, sector, tint, 16 if low else 36, 1.5, Vector2(0.4, 1.7), Vector2(0.011, 0.026))
	RisingMotes.set_rate(_embers, 0.45 if held else 0.3)
	add_child(_embers)
	_embers.emitting = true
	if not low:
		_light = OmniLight3D.new()
		_light.name = "WarningLight"
		_light.light_color = tint.lerp(Color(1.0, 0.75, 0.45), 0.3)
		_light.light_energy = 0.0
		_light.omni_range = maxf(4.5, reach * 1.5)
		_light.omni_attenuation = 1.4
		_light.shadow_enabled = false
		_light.position = Vector3(0, 1.1, reach * 0.5 if sector < 3.1 else 0.0)
		add_child(_light)
	var audio := _audio()
	if audio != null and not held:
		_charge = audio.call("play_sound_at", CHARGE_SOUND, global_position, self)

func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")

func _param(parameter: String, value: Variant) -> void:
	if _disc != null and is_instance_valid(_disc):
		((_disc.mesh as CylinderMesh).material as ShaderMaterial).set_shader_parameter(parameter, value)

## The warning burns in over APPEAR_S instead of popping on.
func _process(delta: float) -> void:
	if _released:
		return
	if _appear < 1.0:
		_appear = minf(1.0, _appear + delta / APPEAR_S)
		_param("fade", _appear)
	if _light != null:
		var t := Time.get_ticks_msec() * 0.001
		var p := 0.35 if held else progress
		_light.light_energy = (0.5 + 2.4 * p) * _appear * (0.86 + 0.14 * sin(t * 17.0) * sin(t * 7.3))

## 0 at the telegraph's start, 1 on its release tick: the fire's front is
## exactly the server's countdown. The embers thicken with it.
func set_progress(p: float) -> void:
	if _released:
		return
	progress = clampf(p, 0.0, 1.0)
	_param("progress", progress)
	if not held:
		RisingMotes.set_rate(_embers, 0.3 + 0.7 * progress)

## The attack went off: the fire flashes, a blast runs out to the boundary,
## embers are thrown up, and it is gone.
func release() -> void:
	if _released:
		return
	_released = true
	_param("progress", 1.0)
	_param("flash", 1.0)
	_param("fade", 1.0)
	if _embers != null:
		_embers.emitting = false
	if SkillFX.quality != "low":
		var burst := RisingMotes.make(reach, sector, tint, 46, 0.95, Vector2(1.6, 4.6), Vector2(0.012, 0.034), true)
		add_child(burst)
		burst.emitting = true
	var audio := _audio()
	if audio != null:
		audio.call("play_sound_at", RELEASE_SOUND, global_position, self)
	var material := (_disc.mesh as CylinderMesh).material as ShaderMaterial
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(material, "shader_parameter/shock", 1.0, BLAST_S).from(0.001) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(material, "shader_parameter/flash", 0.0, BLAST_S).set_ease(Tween.EASE_OUT)
	tween.tween_property(material, "shader_parameter/fade", 0.0, BLAST_S).set_ease(Tween.EASE_IN) \
		.set_trans(Tween.TRANS_QUAD)
	if _light != null:
		_light.light_energy = 5.0
		tween.tween_property(_light, "light_energy", 0.0, BLAST_S)
	tween.set_parallel(false)
	tween.tween_interval(AFTERGLOW_S)
	tween.tween_callback(queue_free)

## Called off before its release (the creature was stunned, thrown, died or
## gave up): the ground cools at once, the charge falls silent, no blast.
func cancel() -> void:
	_cool(CANCEL_S)

## A held patch ran out: it cools away over EXPIRE_S.
func expire() -> void:
	_cool(EXPIRE_S)

func _cool(over_s: float) -> void:
	if _released:
		return
	_released = true
	if _embers != null:
		_embers.emitting = false
	if _charge != null and is_instance_valid(_charge) and _charge.get("playing") == true:
		_charge.call("stop")
	var material := (_disc.mesh as CylinderMesh).material as ShaderMaterial
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(material, "shader_parameter/fade", 0.0, over_s)
	if _light != null:
		tween.tween_property(_light, "light_energy", 0.0, over_s)
	tween.set_parallel(false)
	tween.tween_interval(0.6)
	tween.tween_callback(queue_free)
