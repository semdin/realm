extends Node
class_name DayNight

## Day and night on the grounds, the rain's darkening of them, and the
## character fill everywhere (the old client's DayNight).
##
## Time of day follows the realm's clock in GMT+3 (the players' time zone),
## read from the machine's UTC clock so every client agrees without a protocol
## field. Settings > Graphics > Time of day can hold it instead
## (GameSettings.time_of_day: "system" or a held time - "dawn", "noon",
## "afternoon", "sunset", "night"); `--time HH:MM` (captures) and the light
## check (`forced_hour`) pin an hour.
##
## The day has five faces and the hours between blend them: dawn (pink and
## cold), noon (high white sun), afternoon (warm gold), sunset (orange and red,
## then the blue hour) and night (moon and stars). The sun crosses the sky from
## east to west between sunrise and sunset, the moon by night; each light fades
## out at the horizon, so the hand-over is never seen. The sky is
## assets/shaders/sky_day_night.gdshader: gradient, sun or moon disc, drifting
## clouds (noise), stars.
##
## The rain is RealmWeather's (the server's weather, a GA's `/ga rain on`):
## while it rains the clouds thicken and darken, the sun dims, the fog
## thickens and the ambient greys, eased with the weather's rain_amount.
##
## Only an outdoor map (RealmWeather.OUTDOOR_MAPS) is lit here. Inside (the
## castle, the caverns, a dungeon) the map's own atmosphere holds: its
## environment and lights are its own and the outdoor sun stays out.
##
## An outdoor map may follow the hour too (`apply_daylight(night)`, as the
## lamps change: the grounds' clock faces glow only at night).
##
## Character fill: the shadowless light on the camera that lights only the
## character layer (HeroAppearance.add_character_fill / CHARACTER_LAYER: the
## heroes and the creatures) follows the hour on every map, so dark bodies in
## a cliff's shadow, at night or in a dim hall stay readable without lifting
## the whole scene. Presentation only.

const SKY_SHADER := preload("res://assets/shaders/sky_day_night.gdshader")
const UTC_OFFSET_HOURS := 3.0
const UPDATE_PERIOD := 0.25
## Sun up and down (GMT+3, the year's middle); the moon has the night.
const SUNRISE := 5.9
const SUNSET := 19.4
const SUN_MAX_ELEVATION := 62.0
const MOON_MAX_ELEVATION := 48.0
## The grey the rain pulls the light, the fog and the clouds towards.
const STORM_GREY := Color(0.36, 0.39, 0.43)
## The lamps' group (their authored energy is kept in metadata).
const LAMP_GROUP := "grounds_torch_lights"

# i18n-begin
const CHOICES := {"system": "Server time (GMT+3)", "dawn": "Always dawn (Sabah)", "noon": "Always noon (Öğle)",
	"afternoon": "Always afternoon (İkindi)", "sunset": "Always sunset (Akşam)", "night": "Always night (Yatsı)"}
# i18n-end
## The hour each held choice shows: the sun just up, high, low and gold, on
## the horizon, and the moon.
const HELD_HOURS := {"dawn": 6.2, "noon": 12.5, "afternoon": 15.8, "sunset": 18.7, "night": 0.5}

const LOOKS := {
	"dawn": {
		"sun_color": Color(1.0, 0.70, 0.55), "sun_energy": 0.62,
		"sky_top": Color(0.20, 0.25, 0.44), "sky_horizon": Color(0.95, 0.64, 0.60),
		"ground_bottom": Color(0.14, 0.14, 0.17), "ground_horizon": Color(0.52, 0.44, 0.47),
		"ambient_color": Color(0.86, 0.76, 0.82), "ambient_sky": 0.8, "ambient_energy": 0.62,
		"fog_color": Color(0.78, 0.66, 0.68), "exposure": 1.05, "stars": 0.25,
		"cloud_lit": Color(1.0, 0.74, 0.70), "cloud_shade": Color(0.44, 0.38, 0.50),
		"fill_energy": 0.65, "fill_color": Color(1.0, 0.88, 0.86), "torch": 1.3,
	},
	"morning": {
		"sun_color": Color(1.0, 0.93, 0.82), "sun_energy": 0.9,
		"sky_top": Color(0.25, 0.39, 0.57), "sky_horizon": Color(0.66, 0.73, 0.81),
		"ground_bottom": Color(0.20, 0.23, 0.22), "ground_horizon": Color(0.47, 0.53, 0.57),
		"ambient_color": Color(1, 1, 1), "ambient_sky": 1.0, "ambient_energy": 0.62,
		"fog_color": Color(0.68, 0.75, 0.82), "exposure": 1.0, "stars": 0.0,
		"cloud_lit": Color(1.0, 0.98, 0.95), "cloud_shade": Color(0.60, 0.66, 0.74),
		"fill_energy": 0.55, "fill_color": Color(1.0, 0.97, 0.94), "torch": 1.0,
	},
	"noon": {
		"sun_color": Color(1.0, 0.97, 0.91), "sun_energy": 1.0,
		"sky_top": Color(0.22, 0.36, 0.54), "sky_horizon": Color(0.60, 0.68, 0.76),
		"ground_bottom": Color(0.20, 0.23, 0.22), "ground_horizon": Color(0.46, 0.52, 0.55),
		"ambient_color": Color(1, 1, 1), "ambient_sky": 1.0, "ambient_energy": 0.62,
		"fog_color": Color(0.66, 0.73, 0.80), "exposure": 1.0, "stars": 0.0,
		"cloud_lit": Color(1.0, 1.0, 1.0), "cloud_shade": Color(0.62, 0.67, 0.74),
		"fill_energy": 0.55, "fill_color": Color(1.0, 0.97, 0.92), "torch": 1.0,
	},
	"afternoon": {
		"sun_color": Color(1.0, 0.86, 0.64), "sun_energy": 0.92,
		"sky_top": Color(0.24, 0.35, 0.52), "sky_horizon": Color(0.78, 0.73, 0.64),
		"ground_bottom": Color(0.20, 0.21, 0.19), "ground_horizon": Color(0.52, 0.50, 0.47),
		"ambient_color": Color(1.0, 0.95, 0.88), "ambient_sky": 0.92, "ambient_energy": 0.62,
		"fog_color": Color(0.74, 0.72, 0.68), "exposure": 1.0, "stars": 0.0,
		"cloud_lit": Color(1.0, 0.93, 0.80), "cloud_shade": Color(0.60, 0.58, 0.60),
		"fill_energy": 0.58, "fill_color": Color(1.0, 0.94, 0.85), "torch": 1.05,
	},
	"sunset": {
		"sun_color": Color(1.0, 0.55, 0.30), "sun_energy": 0.75,
		"sky_top": Color(0.20, 0.21, 0.38), "sky_horizon": Color(0.98, 0.52, 0.32),
		"ground_bottom": Color(0.15, 0.13, 0.14), "ground_horizon": Color(0.55, 0.38, 0.32),
		"ambient_color": Color(0.92, 0.70, 0.60), "ambient_sky": 0.8, "ambient_energy": 0.62,
		"fog_color": Color(0.80, 0.56, 0.46), "exposure": 1.02, "stars": 0.1,
		"cloud_lit": Color(1.0, 0.60, 0.40), "cloud_shade": Color(0.42, 0.30, 0.38),
		"fill_energy": 0.72, "fill_color": Color(1.0, 0.84, 0.74), "torch": 1.3,
	},
	"blue_hour": {
		"sun_color": Color(0.70, 0.70, 0.90), "sun_energy": 0.4,
		"sky_top": Color(0.07, 0.10, 0.24), "sky_horizon": Color(0.34, 0.30, 0.46),
		"ground_bottom": Color(0.05, 0.05, 0.07), "ground_horizon": Color(0.20, 0.19, 0.26),
		"ambient_color": Color(0.52, 0.52, 0.72), "ambient_sky": 0.5, "ambient_energy": 0.85,
		"fog_color": Color(0.24, 0.24, 0.34), "exposure": 1.14, "stars": 0.55,
		"cloud_lit": Color(0.46, 0.42, 0.58), "cloud_shade": Color(0.16, 0.16, 0.24),
		"fill_energy": 1.1, "fill_color": Color(0.84, 0.84, 1.0), "torch": 1.45,
	},
	"night": {
		"sun_color": Color(0.62, 0.72, 1.0), "sun_energy": 0.5,
		"sky_top": Color(0.012, 0.02, 0.05), "sky_horizon": Color(0.07, 0.10, 0.17),
		"ground_bottom": Color(0.02, 0.025, 0.03), "ground_horizon": Color(0.05, 0.07, 0.10),
		"ambient_color": Color(0.38, 0.46, 0.68), "ambient_sky": 0.35, "ambient_energy": 1.1,
		"fog_color": Color(0.09, 0.12, 0.20), "exposure": 1.22, "stars": 1.0,
		"cloud_lit": Color(0.20, 0.23, 0.32), "cloud_shade": Color(0.05, 0.06, 0.09),
		"fill_energy": 1.45, "fill_color": Color(0.74, 0.82, 1.0), "torch": 1.55,
	},
}
## (hour, look): the hours between two keys blend them.
const KEYS := [[0.0, "night"], [4.6, "night"], [5.6, "dawn"], [7.2, "morning"], [12.0, "noon"],
	[15.3, "afternoon"], [18.3, "sunset"], [19.4, "blue_hour"], [20.6, "night"], [24.0, "night"]]

## The light check pins an hour here (-1: none).
static var forced_hour := -1.0

## main.gd: its Sun, WorldEnvironment and weather.
var main: Node
var outdoors := false
## The look on screen now (eases towards the hour's look).
var current: Dictionary = {}
var night_amount := 0.0
## How bright the lamps burn at this hour (1.0 by day, ~1.5 at night).
var torch_scale := 1.0
## The rain shown in the light (the weather's rain_amount outdoors).
var wet := 0.0
## What the last update set (the light check reads it).
var sun_energy := 0.0
var fog_density := 0.0
var cloud_cover := 0.0
var _timer := 0.0
var _sky: ShaderMaterial = null
var _torch_applied := -1.0

func _init() -> void:
	name = "DayNight"

func setup(p_main: Node, map_name: String) -> void:
	main = p_main
	outdoors = RealmWeather.OUTDOOR_MAPS.has(map_name)
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return
	snap()

## The hour shown, 0-24 (fractional): pinned, held by the setting, or GMT+3
## from the UTC clock.
static func hour() -> float:
	if forced_hour >= 0.0:
		return fposmod(forced_hour, 24.0)
	var args := OS.get_cmdline_user_args()
	var i := args.find("--time")
	if i >= 0 and i + 1 < args.size():
		var pinned := parse_time(args[i + 1])
		if pinned >= 0.0:
			return pinned
	for arg: String in args:
		if arg.begins_with("--hour="):
			return fposmod(float(arg.trim_prefix("--hour=")), 24.0)
	var held := GameSettings.instance().time_of_day
	if HELD_HOURS.has(held):
		return float(HELD_HOURS[held])
	return fposmod(Time.get_unix_time_from_system() / 3600.0 + UTC_OFFSET_HOURS, 24.0)

## "19:30" -> 19.5 (-1 when it is not a time).
static func parse_time(text: String) -> float:
	var parts := text.split(":")
	if parts.is_empty() or not parts[0].is_valid_int():
		return -1.0
	var h := float(parts[0].to_int())
	if parts.size() > 1 and parts[1].is_valid_int():
		h += float(parts[1].to_int()) / 60.0
	return fposmod(h, 24.0)

static func look_at_hour(h: float) -> Dictionary:
	for i in range(KEYS.size() - 1):
		var a: Array = KEYS[i]
		var b: Array = KEYS[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var t := 0.0 if float(b[0]) == float(a[0]) else (h - float(a[0])) / (float(b[0]) - float(a[0]))
			return _blend(LOOKS[String(a[1])], LOOKS[String(b[1])], smoothstep(0.0, 1.0, t))
	return (LOOKS["noon"] as Dictionary).duplicate()

static func _blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key: String in a:
		var va: Variant = a[key]
		out[key] = (va as Color).lerp(b[key], t) if va is Color else lerpf(float(va), float(b[key]), t)
	return out

## Where the sky light is at hour `h`: {rot (degrees for the DirectionalLight),
## elevation (degrees), moon (bool)}. The sun rises in the east and sets in the
## west; the moon takes the opposite arc through the night.
static func sky_light(h: float) -> Dictionary:
	var moon := h < SUNRISE or h > SUNSET
	var t := 0.0
	var max_elev := SUN_MAX_ELEVATION
	if moon:
		var night_len := 24.0 - SUNSET + SUNRISE
		t = fposmod(h - SUNSET, 24.0) / night_len
		max_elev = MOON_MAX_ELEVATION
	else:
		t = (h - SUNRISE) / (SUNSET - SUNRISE)
	var elevation := sin(PI * clampf(t, 0.0, 1.0)) * max_elev
	var yaw := lerpf(-100.0, 100.0, t) + (180.0 if moon else 0.0)
	return {"rot": Vector3(-maxf(elevation, 4.0), yaw, 0.0), "elevation": elevation, "moon": moon}

## Show the hour's look at once (joining, the map built, a pinned hour), no
## easing; the lamps take the hour's brightness again (new ones were built).
func snap() -> void:
	if DisplayServer.get_name() == "headless":
		return
	current = look_at_hour(hour()).duplicate()
	wet = _rain()
	_torch_applied = -1.0
	_apply()

## A preset switch: fog density and exposure follow it at once.
func apply_quality(_preset: Dictionary) -> void:
	if not current.is_empty():
		_apply()

func _rain() -> float:
	if not outdoors or main == null:
		return 0.0
	var weather: Variant = main.get("weather")
	return float((weather as Node).get("rain_amount")) if weather is Node else 0.0

func _process(delta: float) -> void:
	_timer -= delta
	var rain := _rain()
	# the rain eases in RealmWeather; the light follows it every frame it moves
	if _timer > 0.0 and is_equal_approx(rain, wet):
		return
	if _timer <= 0.0:
		_timer = UPDATE_PERIOD
		# ease so a settings switch fades instead of snapping (~2 s)
		current = _blend(current, look_at_hour(hour()), 0.3)
	wet = rain
	_apply()

func _apply() -> void:
	night_amount = clampf(float(current.get("stars", 0.0)), 0.0, 1.0)
	var fill := _fill()
	if fill != null:
		fill.light_energy = float(current["fill_energy"]) * (1.0 + wet * 0.15)
		fill.light_color = current["fill_color"]
		# the characters' rim light follows the fill, cooler
		var rim := HeroAppearance.character_rim(fill.get_parent() as Camera3D)
		if rim != null:
			rim.light_energy = minf(fill.light_energy * HeroAppearance.RIM_SHARE, 0.7)
			rim.light_color = HeroAppearance.RIM_COLOR.lerp(fill.light_color, 0.3)
	if not outdoors or main == null:
		return   # inside: the map's own atmosphere holds
	var env_node := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env := env_node.environment if env_node != null else null
	if env == null:
		return
	var preset := QualityPreset.settings()
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = float(current["ambient_sky"])
	env.ambient_light_color = (current["ambient_color"] as Color).lerp(STORM_GREY * 1.6, wet * 0.5)
	env.ambient_light_energy = float(current["ambient_energy"]) * (1.0 - wet * 0.15)
	var fog := current["fog_color"] as Color
	env.fog_light_color = fog.lerp(fog.lerp(STORM_GREY, 0.6), wet)
	env.tonemap_exposure = float(preset["tonemap_exposure"]) * float(current["exposure"])
	fog_density = float(preset["fog_density"]) * (1.0 + wet * 2.5)
	if env.fog_enabled:
		env.fog_density = fog_density
	_update_sky(env)
	var sun := main.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		var light := sky_light(hour())
		sun.rotation_degrees = light["rot"]
		# Each light fades out over its last degrees above the horizon, so the
		# sun-to-moon hand-over happens in the dark of the blue hour.
		var fade := smoothstep(0.0, 9.0, float(light["elevation"]))
		sun.light_color = current["sun_color"]
		sun_energy = float(current["sun_energy"]) * fade * (1.0 - wet * 0.55)
		sun.light_energy = sun_energy
	torch_scale = float(current["torch"]) * (1.0 + wet * 0.2)
	if absf(torch_scale - _torch_applied) > 0.005:
		_torch_applied = torch_scale
		for node: Node in get_tree().get_nodes_in_group(LAMP_GROUP):
			var lamp := node as Light3D
			if lamp == null:
				continue
			if not lamp.has_meta("base_energy"):
				lamp.set_meta("base_energy", lamp.light_energy)
			lamp.light_energy = float(lamp.get_meta("base_energy")) * torch_scale
		var map_view: Variant = main.get("map_view")
		if is_instance_valid(map_view) and map_view is Node and (map_view as Node).has_method("apply_daylight"):
			(map_view as Node).call("apply_daylight", night_amount)

## The camera's character fill (made once on whichever camera draws the world).
func _fill() -> DirectionalLight3D:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return null
	return HeroAppearance.add_character_fill(camera)

func _update_sky(env: Environment) -> void:
	if env.sky == null:
		env.sky = Sky.new()
	if _sky == null:
		_sky = ShaderMaterial.new()
		_sky.shader = SKY_SHADER
	if env.sky.sky_material != _sky:
		env.sky.sky_material = _sky
		env.sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		env.sky.radiance_size = Sky.RADIANCE_SIZE_64
	var storm := STORM_GREY * (0.55 + 0.45 * (1.0 - night_amount))
	_sky.set_shader_parameter("top_color", (current["sky_top"] as Color).lerp(storm * 0.8, wet * 0.75))
	_sky.set_shader_parameter("horizon_color", (current["sky_horizon"] as Color).lerp(storm, wet * 0.75))
	_sky.set_shader_parameter("ground_bottom", current["ground_bottom"])
	_sky.set_shader_parameter("ground_horizon", (current["ground_horizon"] as Color).lerp(storm * 0.7, wet * 0.5))
	_sky.set_shader_parameter("night", night_amount * (1.0 - wet * 0.8))
	cloud_cover = lerpf(0.42, 1.0, wet)
	_sky.set_shader_parameter("cloud_cover", cloud_cover)
	_sky.set_shader_parameter("cloud_dark", wet * 0.55)
	_sky.set_shader_parameter("cloud_lit", (current["cloud_lit"] as Color).lerp(storm * 1.3, wet * 0.7))
	_sky.set_shader_parameter("cloud_shade", (current["cloud_shade"] as Color).lerp(storm * 0.6, wet * 0.7))
	_sky.set_shader_parameter("wind", 0.006 + wet * 0.012)
