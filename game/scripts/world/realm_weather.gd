extends Node3D
class_name RealmWeather

## The realm's weather on this map (the rain layer of the old game's
## DayNight; the day and night themselves come later). The server says
## whether it rains (RealmSession.raining(): realm-wide, a GA's `/ga rain
## on|off`); `rain_amount` eases toward it over a few seconds.
##
## Outdoors (OUTDOOR_MAPS) rain falls round the camera: GPU particles whose
## streaks are soft, tapered drops of varying weight, thinned and thickened by
## a drifting noise map so the rain comes in gusts and sheets rather than as an
## even grid; the light dims a little and the sky goes grey, and the rain loop
## plays. Indoors (the castle, the caverns, a dungeon) nothing falls and the
## loop is heard softly, as through the walls.

const OUTDOOR_MAPS := ["grounds"]
const RAIN_SOUND := "res://assets/audio/ambience/rain.wav"
const RAIN_SHADER := "res://assets/shaders/rain_streak.gdshader"
## Seconds the rain takes to set in or stop.
const EASE_SECONDS := 6.0
## How much the sun dims and the sky greys at full rain.
const SUN_DIM := 0.38
const STORM_SKY := Color(0.36, 0.40, 0.45)
const STORM_AMBIENT := Color(0.42, 0.45, 0.50)
const INDOOR_VOLUME := 0.25
const OUTDOOR_VOLUME := 0.8

var session: Node
var outdoors := false
## 0..1, eased toward the server's weather.
var rain_amount := 0.0
var rain: GPUParticles3D
var rain_sound: AudioStreamPlayer

var _sun: DirectionalLight3D
var _env: Environment
var _sun_energy := 1.0
var _sky := Color.BLACK
var _ambient := Color.BLACK
## Until then (the first moments on the map) the rain snaps to the server's
## word: a map joined while it rains starts wet, not easing in.
var _fresh_until := 0.0

func _init() -> void:
	name = "Weather"

## `sun` and `env` are the map's light and environment (their clear-weather
## values are kept and the rain dims them).
func setup(p_session: Node, map_name: String, sun: DirectionalLight3D, env: Environment) -> void:
	session = p_session
	outdoors = OUTDOOR_MAPS.has(map_name)
	_sun = sun
	_env = env
	if _sun != null:
		_sun_energy = _sun.light_energy
	if _env != null:
		_sky = _env.background_color
		_ambient = _env.ambient_light_color
	rain_amount = 1.0 if raining() else 0.0
	_apply()

## The map is joined: for a moment the rain follows the server's word at once.
func on_joined() -> void:
	_fresh_until = Time.get_ticks_msec() / 1000.0 + 2.0

func raining() -> bool:
	return session != null and session.has_method("raining") and bool(session.raining())

func _process(delta: float) -> void:
	if session == null:
		return
	var goal := 1.0 if raining() else 0.0
	if not is_equal_approx(rain_amount, goal):
		var fresh := Time.get_ticks_msec() / 1000.0 < _fresh_until
		rain_amount = goal if fresh else move_toward(rain_amount, goal, delta / EASE_SECONDS)
		_apply()
	_follow_camera()

func _apply() -> void:
	var shown := rain_amount if outdoors else 0.0
	if _sun != null:
		_sun.light_energy = _sun_energy * (1.0 - SUN_DIM * shown)
	if _env != null:
		_env.background_color = _sky.lerp(STORM_SKY, shown * 0.75)
		_env.ambient_light_color = _ambient.lerp(STORM_AMBIENT, shown * 0.6)
	if shown > 0.01:
		if rain == null:
			_build_rain()
		rain.emitting = true
		rain.amount_ratio = clampf(shown, 0.05, 1.0)
	elif rain != null:
		rain.emitting = false
	var volume := rain_amount * (OUTDOOR_VOLUME if outdoors else INDOOR_VOLUME)
	if volume > 0.005:
		if rain_sound == null:
			_build_sound()
		if rain_sound != null:
			rain_sound.volume_db = linear_to_db(volume)
			if not rain_sound.playing:
				rain_sound.play()
	elif rain_sound != null and rain_sound.playing:
		rain_sound.stop()

func _build_rain() -> void:
	rain = GPUParticles3D.new()
	rain.name = "Rain"
	rain.amount = 6000
	rain.lifetime = 1.1
	rain.preprocess = 1.0
	rain.local_coords = false
	rain.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 60, 80))
	rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(20, 1, 20)
	process.direction = Vector3(0.12, -1, 0.05)
	process.spread = 2.0
	process.initial_velocity_min = 24.0
	process.initial_velocity_max = 30.0
	process.gravity = Vector3(0, -9.8, 0)
	# drops of different weight: some fine, some heavy
	process.scale_min = 0.6
	process.scale_max = 1.25
	rain.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.035, 0.95)
	var mat := ShaderMaterial.new()
	mat.shader = load(RAIN_SHADER)
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	var gusts := NoiseTexture2D.new()
	gusts.width = 256
	gusts.height = 256
	gusts.seamless = true
	gusts.noise = noise
	mat.set_shader_parameter("gust_noise", gusts)
	quad.material = mat
	rain.draw_pass_1 = quad
	add_child(rain)
	_follow_camera()

func _build_sound() -> void:
	if not ResourceLoader.exists(RAIN_SOUND):
		return
	var stream: AudioStream = load(RAIN_SOUND)
	if stream is AudioStreamWAV:
		var wav := (stream as AudioStreamWAV).duplicate() as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = int(wav.get_length() * wav.mix_rate)
		stream = wav
	rain_sound = AudioStreamPlayer.new()
	rain_sound.name = "RainSound"
	rain_sound.stream = stream
	rain_sound.bus = "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"
	rain_sound.volume_db = -60.0
	add_child(rain_sound)

## The rain falls from above the camera wherever it goes.
func _follow_camera() -> void:
	if rain == null or not rain.emitting:
		return
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		rain.global_position = camera.global_position + Vector3(0, 16, 0)
