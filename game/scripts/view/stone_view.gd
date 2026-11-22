extends Node3D
class_name StoneView

## A Dark Shard (or a Webbound Seal Stone, a Venomcap or Broodclutch Stone) as
## the server reports it: its body (creature_views.json `stone_<type>`: a
## carved standing stone whose runes are painted into its albedo, or a scene
## composed from the caverns' own art) breathing in its own light, its name,
## level and health over its head. It never moves or attacks.
##
## Its light rises off it into the sky so it can be found from afar: a soft
## shaft of its glow standing on its crown (stone_beam.gdshader: the erosion
## cloud climbing through a haze, ragged at its sides, thinning with height,
## never thinner on screen than a few pixels), and embers lifting off its
## crown into the shaft and off the ground round its foot (RisingMotes). The
## embers and the light are for the near eye only: they rest past MOTE_RANGE
## and LIGHT_FADE.
##
##   a blow      the stone flashes and the label counts down (on_hit)
##   a wave      its light flares, the shaft surges higher and a ring of its
##               glow runs over the ground as the creatures it calls come up
##               around it (on_wave)
##   shattered   the replicated death: it bursts (MonolithShatter, or with
##               creature_views `burst` "silk" the silk splitting open with
##               its `fluid`, SilkBurst) and is gone
##   back        the same entity alive again on a new spot: it falls out of
##               the sky (FALL_HEIGHT over FALL_TIME) with a tail of its glow,
##               lands with a shockwave and dust, its shaft surging up out of
##               it, and shakes the camera of a player within SHAKE_RANGE
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
const BEAM_SHADER := preload("res://assets/shaders/stone_beam.gdshader")
const BEAM_NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const LANDING_SOUND := "spell_shockwave_impact"
## The embers rest farther than this from the camera (m; they are specks by
## then), and the stone's light fades out over LIGHT_FADE (begin, length).
const MOTE_RANGE := 55.0
const LIGHT_FADE := Vector2(40.0, 15.0)
## How often the camera's distance is read for that (s).
const RANGE_PERIOD := 0.3
## The shaft's surge on a wave and on landing, and how fast it settles (/s).
const WAVE_SURGE := 1.5
const LAND_SURGE := 1.2
const SURGE_DECAY := 0.55
## The shafts' quads (and materials) by look: stones of one kind share one.
static var _beams: Dictionary = {}
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
var _shaft: MeshInstance3D
var _motes: Array[GPUParticles3D] = []
var _label_height := 0.0
var _body_height := 7.0
var _burst := 0.0
var _surge := 0.0
var _range_in := 0.0
var _motes_on := true
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

## The breathing light, the embers and the shaft of light (eyes only).
func _build_glow() -> void:
	_light = OmniLight3D.new()
	_light.light_color = glow
	_light.light_energy = 2.2
	_light.omni_range = 11.0
	_light.shadow_enabled = false
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = LIGHT_FADE.x
	_light.distance_fade_length = LIGHT_FADE.y
	_light.position = Vector3(0, float(view.get("light_height", 3.0)), body_radius + 0.1)
	add_child(_light)
	var share := clampf(float(QualityPreset.value("particle_scale", 1.0)), 0.25, 1.0)
	var crown := _body_height * 0.8
	# off the crown, up into the shaft
	var rising := RisingMotes.make(body_radius * 0.45, 4.0, glow, maxi(4, int(round(18.0 * share))), 4.5,
		Vector2(1.0, 2.8), Vector2(0.035, 0.085))
	rising.name = "CrownEmbers"
	rising.position.y = crown
	(rising.process_material as ShaderMaterial).set_shader_parameter("inner", 0.75)
	# off the ground round its foot, drifting up its sides
	var drifting := RisingMotes.make(body_radius * 1.05, 4.0, glow, maxi(4, int(round(16.0 * share))), 3.6,
		Vector2(0.3, 1.0), Vector2(0.025, 0.06))
	drifting.name = "FootEmbers"
	for motes: GPUParticles3D in [rising, drifting]:
		motes.emitting = true
		add_child(motes)
		_motes.append(motes)
	var height := float(view.get("beam_height", 160.0))
	_shaft = _beam(height, float(view.get("beam_radius", 2.2)), false)
	_shaft.name = "SkyBeam"
	_shaft.position.y = crown
	add_child(_shaft)

## A shaft of the stone's light (stone_beam.gdshader) standing `height`
## metres on its foot, `radius` its half width; with `tail` the falling
## stone's comet tail. One quad turned to the eye in the shader; stones of one
## look share its mesh and material, a stone's own surge is an instance
## uniform.
func _beam(height: float, radius: float, tail: bool) -> MeshInstance3D:
	var key := "%s|%.1f|%.2f|%s" % [glow.to_html(false), height, radius, tail]
	var quad: QuadMesh = _beams.get(key)
	if quad == null:
		var material := ShaderMaterial.new()
		material.shader = BEAM_SHADER
		material.set_shader_parameter("colour", glow)
		material.set_shader_parameter("erosion", load(BEAM_NOISE))
		material.set_shader_parameter("height", height)
		material.set_shader_parameter("radius", radius)
		material.set_shader_parameter("tail", tail)
		material.set_shader_parameter("strength", 1.6 if tail else 1.0)
		# in a cave (a short shaft) the light is spent under the roof
		material.set_shader_parameter("falloff", clampf(height * 0.3, 6.0, 38.0))
		quad = QuadMesh.new()
		quad.size = Vector2.ONE
		quad.center_offset = Vector3(0, 0.5, 0)
		quad.subdivide_depth = 12
		quad.material = material
		_beams[key] = quad
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# the shader places the quad: its bounds are the whole shaft's
	var side := radius * 7.0
	node.custom_aabb = AABB(Vector3(-side, -radius * 1.5, -side), Vector3(side * 2.0, height + radius * 2.5, side * 2.0))
	return node

func _set_surge(node: MeshInstance3D, surge: float) -> void:
	if node != null and is_instance_valid(node):
		node.set_instance_shader_parameter("flare", surge)

## The near eye's parts (the embers) on or off; they finish their flight.
func _show_motes(on: bool) -> void:
	_motes_on = on
	for motes in _motes:
		motes.emitting = on

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
	_surge = WAVE_SURGE
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
	_drop_tail()
	visible = false
	if String(view.get("burst", "")) == "silk":
		# a web thing splits open: torn silk and what was inside it
		var tint: Variant = view.get("fluid", null)
		var fluid := Color(float(tint[0]), float(tint[1]), float(tint[2])) if tint is Array and (tint as Array).size() >= 3 \
			else Color(0, 0, 0, 0)
		FlipbookFX.play(get_parent(), global_position, [
			{"atlas": "burst_green_8x8_2k", "size": _body_height * 1.7, "height": _body_height * 0.45, "fps": 30.0,
				"tint": glow.lightened(0.2)},
			{"atlas": "shockwave_8x8_1k", "size": _body_height * 2.8, "flat": true, "height": 0.15, "fps": 26.0, "tint": glow},
		], {"life": 3.0, "light": glow, "light_energy": 8.0, "light_range": 18.0, "light_height": _body_height * 0.5,
			"sound": MonolithShatter.SOUND})
		SilkBurst.play(get_parent(), global_position, Vector2(body_radius * 1.8, _body_height * 0.85), fluid)
		return
	MonolithShatter.play(get_parent(), global_position, glow, _body_height)

## Down out of the sky onto where it stands now: a falling tail of its glow,
## then the landing; its shaft and embers wait for it to land.
func _fall_in(yaw: float) -> void:
	if _fall != null:
		_fall.kill()
	_drop_tail()
	visible = false
	model.position.y = FALL_HEIGHT
	model.rotation.y = yaw - 0.6
	model.scale = Vector3.ONE
	Nameplates.hide_own(self, true)
	if _shaft != null:
		_shaft.visible = false
		_show_motes(false)
	var tail := _beam(26.0, maxf(1.0, body_radius * 1.3), true)
	tail.name = "FallStreak"
	tail.position.y = _body_height * 0.75
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

## A fall cut short (broken again on the way down) leaves no tail behind.
func _drop_tail() -> void:
	var tail := model.get_node_or_null("FallStreak")
	if tail != null:
		model.remove_child(tail)
		tail.queue_free()

func _land() -> void:
	FlipbookFX.play(get_parent(), global_position, [
		{"atlas": "shockwave_8x8_1k", "size": _body_height * 3.0, "flat": true, "height": 0.15, "fps": 26.0, "tint": glow},
		{"atlas": "smoke_puff_8x8_1k", "size": _body_height * 1.6, "height": 1.4, "fps": 16.0, "opacity": 0.7,
			"tint": Color(0.5, 0.48, 0.44)},
	], {"life": 2.6, "light": glow, "light_energy": 7.0, "light_range": 20.0, "light_height": _body_height * 0.4,
		"sound": LANDING_SOUND})
	_burst = 4.0
	_surge = LAND_SURGE
	if _shaft != null:
		_shaft.visible = true
		_show_motes(true)
		_range_in = 0.0
	if shake.is_valid() and observer != null and is_instance_valid(observer) \
			and observer.global_position.distance_to(global_position) < SHAKE_RANGE:
		shake.call(SHAKE_STRENGTH)

func _process(delta: float) -> void:
	if _light == null or not visible:
		return
	# The runes breathe: a slow pulse on the green light.
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.0021)
	_burst = maxf(0.0, _burst - delta * 5.0)
	_light.light_energy = 1.2 + 0.8 * pulse + _burst
	if _surge > 0.0:
		_surge = maxf(0.0, _surge - delta * SURGE_DECAY)
		_set_surge(_shaft, _surge)
	# the embers only for an eye near enough to see them
	_range_in -= delta
	if _range_in <= 0.0 and _shaft != null and _shaft.visible:
		_range_in = RANGE_PERIOD
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			var near := camera.global_position.distance_to(global_position) < MOTE_RANGE
			if near != _motes_on:
				_show_motes(near)
