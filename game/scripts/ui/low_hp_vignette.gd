extends ColorRect
class_name LowHpVignette

## The screen's edge when health runs low (the old game's low-HP vignette):
## from below 35 % health the edge darkens, and at 0 % it reaches furthest
## (the old curve began at 45 %; that reached well into the picture at a
## quarter health, so it starts lower and stays at the edges here). Drawn by low_hp_vignette.gdshader from the cloud map; it
## eases toward the target so a hit does not flash it. Health is the
## snapshot's (RealmSession.vitals); dead or not yet joined, it is off.

const SHADER := "res://assets/shaders/low_hp_vignette.gdshader"
const NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
## Where it starts (share of health missing) and how fast it eases.
const FROM := 0.65
const EASE := 4.0

var session: Node
var _material: ShaderMaterial
## The strength drawn now (0..1; the check reads it).
var strength := 0.0

func _init() -> void:
	name = "LowHpVignette"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color.WHITE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_material = ShaderMaterial.new()
	_material.shader = load(SHADER) as Shader
	_material.set_shader_parameter("noise", SpellEffect.asset(NOISE))
	material = _material
	visible = false

## How strong it should be at `hp` of `max_hp` (0..1).
static func target_strength(hp: int, max_hp: int) -> float:
	if max_hp <= 0 or hp <= 0:
		return 0.0
	var missing := 1.0 - float(hp) / float(max_hp)
	return clampf((missing - FROM) / (1.0 - FROM), 0.0, 1.0)

func _process(delta: float) -> void:
	if session == null:
		return
	var vitals: PackedInt32Array = session.vitals()
	var want := target_strength(vitals[0], vitals[1]) if vitals.size() >= 2 else 0.0
	strength = move_toward(strength, want, delta * EASE * maxf(0.15, absf(want - strength)))
	visible = strength > 0.005
	if visible:
		var view := get_viewport_rect().size
		_material.set_shader_parameter("aspect", view.x / maxf(1.0, view.y))
		_material.set_shader_parameter("strength", strength)
