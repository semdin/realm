extends Node3D
class_name StoneView

## A Dark Shard (or a Webbound Seal Stone) as the server reports it: a
## carved standing stone (creature_views.json `stone_<type>`) whose emerald
## runes and cracks are painted into its albedo, breathing in its own green
## light, motes drifting up off it and a light column over it, its name, level
## and health over its head. It never moves or attacks.
##
##   a blow      the stone flashes and the label counts down (on_hit)
##   a wave      its light flares and a ring of its glow runs over the ground
##               as the creatures it calls come up around it (on_wave)
##   shattered   the replicated death: it bursts into shards (MonolithShatter)
##               and is gone
##   back        the same entity alive again on a new spot: it falls out of
##               the sky (FALL_HEIGHT over FALL_TIME) with a tail of its glow,
##               lands with a shockwave and dust and shakes the camera of a
##               player within SHAKE_RANGE
##
## The health shown is exact: the hits it is seen to take, kept inside what
## the snapshot's hp byte allows. Presentation only.

const FALL_HEIGHT := 70.0
const FALL_TIME := 0.85
## The respawn's new spot rides in with the state; the fall waits this long so
## the interpolated position has settled on it.
const FALL_DELAY := 0.25
const SHAKE_RANGE := 45.0
const SHAKE_STRENGTH := 0.6
const MOTE_TEX := "res://assets/vfx/spark_01.png"
const BEAM_SHADER := preload("res://assets/shaders/stone_beam.gdshader")
const LANDING_SOUND := "spell_shockwave_impact"
## A hit's hp byte stands this long before the (older) snapshot byte may
## correct the count again.
const HIT_HOLD_SECONDS := 0.5
## The plate's first line, screen pixels (the Label3D it replaced was about
## 19 px at 1080p), and its reach (metres).
const LABEL_PX := 19.0
const LABEL_RANGE := 60.0

var species := ""
var view := {}
var stone_type := ""
var glow := Color(0.35, 1.0, 0.45)
var stone_name := ""
var level := 1
var max_hp := 1
## The health the label shows (exact while hits are seen).
var hp := 1
## Read by StatusFX, CombatView and main.gd.
var visuals: Node3D
var head_height := 0.0
var is_dead := false
var body_radius := 1.5
var elite := false
var is_boss := false
var enraged := false
## The local player (the landing's shake is felt within SHAKE_RANGE of it) and
## what shakes the camera (main.gd).
var observer: Node3D
var shake := Callable()

var model: Node3D
var _light: OmniLight3D
var _label_height := 0.0
var _body_height := 7.0
var _burst := 0.0
var _seen := false
var _hit_hold_until := 0.0
var _fall: Tween

func setup(kind: int) -> bool:
	species = CreatureView.species_for_kind(kind)
	view = CreatureView.view_of(species)
	var path := String(view.get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		return false
	var scene := load(path) as PackedScene
	if scene == null:
		return false
	stone_type = species.trim_prefix("stone_")
	glow = Color.html(String(view.get("glow", "#59ff73")))
	_body_height = float(view.get("body_height", 7.0))
	body_radius = float(view.get("body_radius", 1.5))
	head_height = maxf(0.0, float(view.get("label_height", _body_height)) - 0.45)
	var tables: Variant = RealmContent.table("spawn_tables")
	var type: Dictionary = (tables as Dictionary).get("monolith_types", {}).get(stone_type, {}) if tables is Dictionary else {}
	stone_name = String(type.get("name", "Dark Shard"))
	level = int(type.get("level", 1))
	max_hp = maxi(1, int(type.get("max_hp", 1)))
	hp = max_hp
	model = scene.instantiate() as Node3D
	model.name = "Model"
	add_child(model)
	visuals = model
	if DisplayServer.get_name() != "headless":
		_build_glow()
	# the old game's screen-space world label: the same size at any distance
	_label_height = float(view.get("label_height", _body_height + 0.8))
	_update_label()
	visible = false
	return true

## The breathing light, the motes and the light column (eyes only).
func _build_glow() -> void:
	_light = OmniLight3D.new()
	_light.light_color = glow
	_light.light_energy = 2.2
	_light.omni_range = 11.0
	_light.position = Vector3(0, float(view.get("light_height", 3.0)), body_radius + 0.1)
	add_child(_light)
	var motes := CPUParticles3D.new()
	motes.name = "AuraParticles"
	motes.position.y = _body_height * 0.36
	motes.amount = 28
	motes.lifetime = 2.4
	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	var mote := StandardMaterial3D.new()
	mote.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mote.vertex_color_use_as_albedo = true
	mote.albedo_color = glow
	mote.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	if ResourceLoader.exists(MOTE_TEX):
		mote.albedo_texture = load(MOTE_TEX)
	quad.material = mote
	motes.mesh = quad
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	motes.emission_box_extents = Vector3(body_radius * 0.87, _body_height * 0.34, body_radius * 0.67)
	motes.direction = Vector3.UP
	motes.spread = 25.0
	motes.gravity = Vector3(0, 0.6, 0)
	motes.initial_velocity_min = 0.2
	motes.initial_velocity_max = 0.6
	motes.scale_amount_min = 0.5
	motes.scale_amount_max = 1.4
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	ramp.colors = PackedColorArray([Color(glow, 0.0), Color(glow, 0.8), Color(glow.darkened(0.4), 0.0)])
	motes.color_ramp = ramp
	add_child(motes)
	var radius := float(view.get("beam_radius", 2.2))
	var beam := _column(float(view.get("beam_height", 160.0)), radius, radius * 0.35, 0.4)
	beam.name = "SkyBeam"
	beam.position.y += 5.5
	add_child(beam)

## An open light column `height` tall from its base, `bottom` and `top` wide
## (stone_beam.gdshader).
func _column(height: float, bottom: float, top: float, alpha: float) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 16
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	var material := ShaderMaterial.new()
	material.shader = BEAM_SHADER
	material.set_shader_parameter("colour", Color(glow.r, glow.g, glow.b, alpha))
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = Vector3(0, height * 0.5, 0)
	return node

## What the server said it is (its own name and level).
func apply_info(info: Dictionary) -> void:
	if String(info.get("name", "")) != "":
		stone_name = String(info["name"])
	if int(info.get("level", 0)) > 0:
		level = int(info["level"])
	_update_label()

func set_kind(_kind: int) -> void:
	pass

func set_status(bits: int) -> void:
	StatusFX.update(self, bits)

func drive(drawn: Vector3, yaw: float, state: int, _delta: float) -> void:
	position = drawn
	var dead := state == CreatureView.STATE_DEAD
	if not _seen:
		# Already standing (or already broken) when it came into view.
		_seen = true
		is_dead = dead
		visible = not dead
		model.rotation.y = yaw
		return
	if dead and not is_dead:
		is_dead = true
		_shatter()
	elif not dead and is_dead:
		is_dead = false
		hp = max_hp
		_update_label()
		_fall_in(yaw)

## A blow landed (CombatView's hit event): the count goes down and the hit
## sounds (the spell's own impact plays on the stone's face).
func on_hit(event: Dictionary, _own: bool) -> void:
	if is_dead:
		return
	hp = _within_byte(hp - int(event.get("amount", 0)), int(event.get("hp", 255)))
	_hit_hold_until = Time.get_ticks_msec() / 1000.0 + HIT_HOLD_SECONDS
	_update_label()
	AudioManager.play_hit()

## The snapshot's hp byte, every frame.
func set_health(byte: int) -> void:
	if is_dead or Time.get_ticks_msec() / 1000.0 < _hit_hold_until:
		return
	var kept := _within_byte(hp, byte)
	if kept != hp:
		hp = kept
		_update_label()

## `value` kept inside what hp byte `byte` (ceil(hp / max * 255)) allows.
func _within_byte(value: int, byte: int) -> int:
	if byte <= 0:
		return 0
	var high := int(floor(float(byte) / 255.0 * max_hp))
	var low := int(floor(float(byte - 1) / 255.0 * max_hp)) + 1
	return clampi(value, low, maxi(low, high))

## A wave answered the stone's call (the stone_wave notice): its light flares
## and a ring of its glow runs out over the ground. Its number follows from
## take_wave.
func on_wave() -> void:
	_burst = 6.0
	FlipbookFX.play(get_parent(), global_position, [
		{"atlas": "shockwave_8x8_1k", "size": _body_height * 3.4, "flat": true, "height": 0.2, "fps": 22.0, "tint": glow},
	], {"life": 2.2, "light": glow, "light_energy": 6.0, "light_range": 18.0, "light_height": _body_height * 0.5})

func _update_label() -> void:
	var pct := int(float(hp) / float(max_hp) * 100.0)
	var tint := Color(0.45, 1.0, 0.55)
	if pct <= 25:
		tint = Color(1.0, 0.2, 0.2)
	elif pct <= 50:
		tint = Color(1.0, 0.5, 0.2)
	# a 2D plate (Nameplates.put), crisp on every quality preset (a Label3D
	# was drawn at the 3D frame's render scale)
	var lines := (tr("%s (Lv.%d)\n%d / %d (%d%%)") % [I18n.t(stone_name), level, hp, max_hp, pct]).split("\n")
	var plate: Array = []
	for i in lines.size():
		plate.append([lines[i], LABEL_PX if i == 0 else LABEL_PX - 2.0, tint, true])
	Nameplates.put(self, _label_height, LABEL_RANGE, plate)

func _shatter() -> void:
	if _fall != null:
		_fall.kill()
	visible = false
	MonolithShatter.play(get_parent(), global_position, glow, _body_height)

## Down out of the sky onto where it stands now: a falling tail of its glow,
## then the landing.
func _fall_in(yaw: float) -> void:
	if _fall != null:
		_fall.kill()
	visible = false
	model.position.y = FALL_HEIGHT
	model.rotation.y = yaw - 0.6
	model.scale = Vector3.ONE
	Nameplates.hide_own(self, true)
	var tail := _column(26.0, 1.1, 0.05, 0.5)
	tail.name = "FallStreak"
	tail.position.y = _body_height + 13.0
	model.add_child(tail)
	_fall = create_tween()
	_fall.tween_interval(FALL_DELAY)
	_fall.tween_callback(func(): visible = true)
	_fall.tween_property(model, "position:y", 0.0, FALL_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_fall.parallel().tween_property(model, "rotation:y", yaw, FALL_TIME)
	_fall.tween_callback(func():
		tail.queue_free()
		_land())
	# a little settle after the thump
	_fall.tween_property(model, "scale", Vector3(1.06, 0.9, 1.06), 0.07)
	_fall.tween_property(model, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_fall.tween_callback(func(): Nameplates.hide_own(self, false))

func _land() -> void:
	FlipbookFX.play(get_parent(), global_position, [
		{"atlas": "shockwave_8x8_1k", "size": _body_height * 3.0, "flat": true, "height": 0.15, "fps": 26.0, "tint": glow},
		{"atlas": "smoke_puff_8x8_1k", "size": _body_height * 1.6, "height": 1.4, "fps": 16.0, "opacity": 0.7,
			"tint": Color(0.5, 0.48, 0.44)},
	], {"life": 2.6, "light": glow, "light_energy": 7.0, "light_range": 20.0, "light_height": _body_height * 0.4,
		"sound": LANDING_SOUND})
	_burst = 4.0
	if shake.is_valid() and observer != null and is_instance_valid(observer) \
			and observer.global_position.distance_to(global_position) < SHAKE_RANGE:
		shake.call(SHAKE_STRENGTH)

func _process(delta: float) -> void:
	if _light == null:
		return
	# The runes breathe: a slow pulse on the green light.
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.0021)
	_burst = maxf(0.0, _burst - delta * 5.0)
	_light.light_energy = 1.2 + 0.8 * pulse + _burst
