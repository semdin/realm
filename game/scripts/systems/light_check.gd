extends Node

## `--check-light`: light, sky, day and night and the quality presets, short
## (well under 90 s, no walking). build/logs/lup6_light.sh starts a
## coordinator (admin surface 127.0.0.1:8160, token check-token) with the
## grounds (127.0.0.1:7861) and the castle (127.0.0.1:7862):
##
##   grounds (`--server 127.0.0.1:7861 --character 906401 --check-admin
##   127.0.0.1:8160 --shader-warmup`):
##     warmup   the shader warm-up ran (bodies, spell stages, pipelines)
##     times    06:00, 12:00, 19:30 and 00:00 pinned (DayNight.forced_hour),
##              each captured: the sun or the moon, the sky, the fill
##     rain     becomes a GA and types "/ga rain on": the rain sets in and the
##              day darkens (dimmer sun, thicker fog, more cloud), captured;
##              "/ga rain off": the clear values come back
##     presets  low, medium and high picked in Settings > Graphics (saved,
##              applied live): each timed (vsync off) and captured; the
##              player's own choice is put back after
##   castle (`--map castle_interior --server 127.0.0.1:7862 --character
##   906402`):
##     indoor   the outdoor sun out, the castle's own environment untouched
##              by the hour (noon and midnight captured), the character fill
##              on the camera lighting the hero (the hero's pixels brighter
##              with it than without), timed
##
## Captures in build/captures/light/. The verdict line quits 0 only when every
## part passed; any part that cannot finish fails at once.

const TIMEOUT := 80.0
const JOIN_TIMEOUT := 30.0
const STEP_TIMEOUT := 15.0
const SAMPLE_FRAMES := 90
const CAPTURES := "build/captures/light"
const TIMES := ["06:00", "12:00", "19:30", "00:00"]

var game: Node
var _started := 0.0
var _done := false
var _results: Dictionary = {}
var _failures: Array = []
var _original_quality := ""


func _ready() -> void:
	_started = _now()
	_run.call_deferred()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	if not _done and _now() - _started > TIMEOUT:
		_fail("timeout")


func _fail(why: String) -> void:
	if _done:
		return
	_failures.append(why)
	_verdict()


func _root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


func _wait(seconds: float) -> void:
	var until := _now() + seconds
	while _now() < until and not _done:
		await get_tree().process_frame


## Waits until `cond` holds (true) or `timeout` passes (false).
func _until(cond: Callable, timeout: float) -> bool:
	var until := _now() + timeout
	while not _done:
		if cond.call():
			return true
		if _now() > until:
			return false
		await get_tree().process_frame
	return false


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_root().path_join(CAPTURES))
	var joined := await _until(func(): return game.session != null and String(game.session.status()) == "joined" \
		and bool(game.built) and not (game.session.sheet() as Dictionary).is_empty(), JOIN_TIMEOUT)
	if not joined:
		_fail("not joined: %s" % (game.session.status() if game.session != null else "no session"))
		return
	_results["map"] = game.map_name
	_results["quality_start"] = QualityPreset.current()
	_original_quality = GameSettings.instance().graphics_quality
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if game.map_name == "castle_interior":
		await _castle()
	else:
		await _grounds()
	if not _done:
		_verdict()


# ---------------------------------------------------------------- grounds

func _grounds() -> void:
	var day_night: DayNight = game.day_night
	if day_night == null or not day_night.outdoors:
		_fail("no outdoor DayNight on the grounds")
		return
	game.cam_yaw = 0.0
	game.cam_pitch = -0.12
	game.cam_distance = 7.0
	# the warm-up (--shader-warmup) draws its bodies in front of the camera
	var travel: Node = game.travel
	if not await _until(func(): return not is_instance_valid(travel.get("warmup")) or bool(travel.get("warmup").done), 35.0):
		_fail("the shader warm-up did not finish")
		return
	_results["warmup"] = ShaderWarmup.last_report
	if ShaderWarmup.last_report.is_empty() or int(ShaderWarmup.last_report.get("bodies", 0)) < 2 \
			or int(ShaderWarmup.last_report.get("stages", 0)) < 1:
		_failures.append("warmup drew too little: %s" % ShaderWarmup.last_report)
	await _wait(1.0)
	var fill := game.camera.get_node_or_null("CharacterFill") as DirectionalLight3D
	if fill == null:
		_fail("no character fill on the camera")
		return
	var env: Environment = (game.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sun := game.get_node("Sun") as DirectionalLight3D
	if not (env.sky != null and env.sky.sky_material is ShaderMaterial):
		_failures.append("the grounds' sky is not the day-night sky")
	# --- times of day
	for time: String in TIMES:
		DayNight.forced_hour = DayNight.parse_time(time)
		day_night.snap()
		await _wait(0.9)
		var light := DayNight.sky_light(DayNight.hour())
		var tag := "time_" + time.replace(":", "")
		_results[tag] = {"sun": snappedf(sun.light_energy, 0.01), "moon": bool(light["moon"]),
			"elevation": snappedf(float(light["elevation"]), 0.1), "exposure": snappedf(env.tonemap_exposure, 0.01),
			"ambient": snappedf(env.ambient_light_energy, 0.01), "fill": snappedf(fill.light_energy, 0.01),
			"stars": snappedf(day_night.night_amount, 0.01), "torch": snappedf(day_night.torch_scale, 0.01)}
		_capture(tag)
	var noon: Dictionary = _results["time_1200"]
	var night: Dictionary = _results["time_0000"]
	if bool(noon["moon"]) or not bool(night["moon"]):
		_failures.append("sun and moon on the wrong side of the day")
	if float(night["fill"]) <= float(noon["fill"]) or float(night["stars"]) < 0.9:
		_failures.append("the night is not darker-and-filled: %s / %s" % [noon, night])
	# --- rain: the day darkens and clears again
	DayNight.forced_hour = DayNight.parse_time("12:00")
	day_night.snap()
	await _wait(0.5)
	var clear := {"sun": day_night.sun_energy, "fog": day_night.fog_density, "cloud": day_night.cloud_cover}
	_results["rain_clear"] = _rounded(clear)
	await _rain(true)
	if _done:
		return
	var wet := {"sun": day_night.sun_energy, "fog": day_night.fog_density, "cloud": day_night.cloud_cover}
	_results["rain_wet"] = _rounded(wet)
	if not (wet["sun"] < clear["sun"] * 0.6 and wet["fog"] > clear["fog"] * 2.0 and wet["cloud"] > 0.9):
		_failures.append("the rain did not darken the day: %s -> %s" % [clear, wet])
	var weather: RealmWeather = game.weather
	if weather.rain == null or not weather.rain.emitting:
		_failures.append("no rain falling")
	_capture("rain_1200")
	await _rain(false)
	if _done:
		return
	var dry := {"sun": day_night.sun_energy, "fog": day_night.fog_density, "cloud": day_night.cloud_cover}
	_results["rain_dry"] = _rounded(dry)
	if absf(dry["sun"] - clear["sun"]) > 0.01 or absf(dry["fog"] - clear["fog"]) > 0.00001:
		_failures.append("the clear day did not come back: %s -> %s" % [clear, dry])
	_capture("rain_off_1200")
	# --- presets, picked in Settings > Graphics
	var settings: SettingsWindow = game.settings_window
	for preset: String in QualityPreset.NAMES:
		settings.choose_quality(preset)
		await _wait(1.5)
		var problems := _preset_problems(preset)
		var timing := await _time_frames()
		timing["problems"] = problems
		_results["preset_" + preset] = timing
		_capture("preset_" + preset)
		if not problems.is_empty():
			_failures.append("%s: %s" % [preset, ", ".join(problems)])
	settings.choose_quality(_original_quality)
	_results["quality_restored"] = GameSettings.instance().graphics_quality
	# the Graphics tab as the player sees it
	settings.open()
	settings.show_page("graphics")
	await _wait(0.4)
	if settings.page_shown() != "graphics" or settings.quality_picker == null \
			or settings.quality_picker.selected != GameSettings.GRAPHICS_CHOICES.find(_original_quality):
		_failures.append("the Graphics tab does not show the choice")
	_capture("settings_graphics")
	settings.close()
	DayNight.forced_hour = -1.0


## What does not match `preset` after it was picked.
func _preset_problems(preset: String) -> Array:
	var problems: Array = []
	var want := QualityPreset.PRESETS[preset] as Dictionary
	if QualityPreset.current() != preset:
		problems.append("current %s" % QualityPreset.current())
	var config := ConfigFile.new()
	if config.load(GameSettings.SETTINGS_PATH) != OK or String(config.get_value(GameSettings.GENERAL, "graphics_quality", "")) != preset:
		problems.append("not saved")
	var viewport := get_viewport()
	if viewport.use_taa or viewport.msaa_3d != Viewport.MSAA_DISABLED:
		problems.append("TAA or MSAA on")
	var scale := QualityPreset.render_scale((viewport as Window).size)
	if not is_equal_approx(viewport.scaling_3d_scale, scale):
		problems.append("render scale %.2f" % viewport.scaling_3d_scale)
	var sun := game.get_node("Sun") as DirectionalLight3D
	if not is_equal_approx(sun.directional_shadow_max_distance, float(want["shadow_max_distance"])):
		problems.append("shadow distance %.0f" % sun.directional_shadow_max_distance)
	if not is_equal_approx(game.camera.far, float(want["view_distance"])):
		problems.append("view distance %.0f" % game.camera.far)
	var env: Environment = (game.get_node("WorldEnvironment") as WorldEnvironment).environment
	if env.glow_enabled != bool(want["glow"]):
		problems.append("glow %s" % env.glow_enabled)
	if game.map_view != null and String(game.map_view.get("quality")) != preset:
		problems.append("grounds on %s" % game.map_view.get("quality"))
	if SkillFX.quality != preset:
		problems.append("spell effects on %s" % SkillFX.quality)
	return problems


## GA on (once), then "/ga rain on|off" typed into the chat; waits for the
## weather to settle fully.
func _rain(on: bool) -> void:
	if not game.own_ga:
		var name := String(game.session.sheet()["name"])
		_post("/admin/ga", {"name": name, "on": true})
		if not await _until(func(): return bool(game.own_ga), STEP_TIMEOUT):
			_fail("not made a GA")
			return
	var chat: HudChat = game.hud.chat
	chat.open()
	var line := "/ga rain on" if on else "/ga rain off"
	chat.input.text = line
	chat.input.text_submitted.emit(line)
	var weather: RealmWeather = game.weather
	var goal := 1.0 if on else 0.0
	if not await _until(func(): return is_equal_approx(weather.rain_amount, goal), STEP_TIMEOUT):
		_fail("the rain did not %s (amount %.2f)" % ["set in" if on else "stop", weather.rain_amount])
		return
	await _wait(0.5)


func _post(path: String, body: Dictionary) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
		print("light check: %s -> %d %s" % [path, code, bytes.get_string_from_utf8()])
		http.queue_free())
	var admin := String(game._arg("--check-admin", "127.0.0.1:8160"))
	var token := String(game._arg("--check-token", "check-token"))
	if http.request("http://%s%s" % [admin, path], ["x-service-token: %s" % token, "Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		_fail("%s could not be sent" % path)


func _rounded(values: Dictionary) -> Dictionary:
	var out := {}
	for key: String in values:
		out[key] = snappedf(float(values[key]), 0.00001)
	return out


# ----------------------------------------------------------------- castle

func _castle() -> void:
	var day_night: DayNight = game.day_night
	game.cam_yaw = PI
	game.cam_pitch = -0.18
	game.cam_distance = 3.6
	await _wait(1.5)
	var sun := game.get_node("Sun") as DirectionalLight3D
	var env: Environment = (game.get_node("WorldEnvironment") as WorldEnvironment).environment
	var indoor := {"sun_visible": sun.visible, "outdoors": day_night.outdoors,
		"background": env.background_mode, "ambient": snappedf(env.ambient_light_energy, 0.01),
		"glow": env.glow_enabled}
	_results["indoor"] = indoor
	if sun.visible:
		_failures.append("the outdoor sun lights the castle")
	if day_night.outdoors or env.background_mode == Environment.BG_SKY:
		_failures.append("the day's sky reached indoors")
	var fill := game.camera.get_node_or_null("CharacterFill") as DirectionalLight3D
	if fill == null or not fill.visible or fill.light_energy <= 0.0:
		_fail("no character fill on the camera indoors")
		return
	var on_layer := 0
	for mesh: Node in game.player.find_children("*", "MeshInstance3D", true, false):
		if (mesh as MeshInstance3D).layers & HeroAppearance.CHARACTER_LAYER != 0:
			on_layer += 1
	if on_layer == 0:
		_failures.append("the hero is not on the character layer")
	var ambient_before := env.ambient_light_energy
	for time: String in ["12:00", "00:00"]:
		DayNight.forced_hour = DayNight.parse_time(time)
		day_night.snap()
		await _wait(0.6)
		if not is_equal_approx(env.ambient_light_energy, ambient_before) or env.background_mode == Environment.BG_SKY \
				or sun.visible:
			_failures.append("the hour %s changed the castle's own light" % time)
		_results["castle_" + time.replace(":", "")] = {"fill": snappedf(fill.light_energy, 0.01)}
		_capture("castle_" + time.replace(":", ""))
	# the fill lights the hero: its pixels are brighter with it than without
	var lit := _hero_luminance()
	fill.visible = false
	await _wait(0.3)
	var unlit := _hero_luminance()
	fill.visible = true
	_capture("castle_nofill_compare")
	_results["fill_on_hero"] = {"with": snappedf(lit, 0.001), "without": snappedf(unlit, 0.001)}
	if lit <= unlit + 0.01:
		_failures.append("the fill does not light the hero (%.3f vs %.3f)" % [lit, unlit])
	DayNight.forced_hour = -1.0
	day_night.snap()
	_results["castle_timing"] = await _time_frames()


## Mean luminance of the hero's middle on screen.
func _hero_luminance() -> float:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return 0.0
	var chest: Vector3 = game.player.global_position + Vector3(0, 1.1, 0)
	var at: Vector2 = game.camera.unproject_position(chest)
	var scale := Vector2(image.get_size()) / get_viewport().get_visible_rect().size
	var centre := Vector2i(at * scale)
	var total := 0.0
	var count := 0
	for y in range(-40, 41, 4):
		for x in range(-16, 17, 4):
			var p := centre + Vector2i(x, y)
			if p.x < 0 or p.y < 0 or p.x >= image.get_width() or p.y >= image.get_height():
				continue
			total += image.get_pixelv(p).get_luminance()
			count += 1
	return total / maxf(1.0, float(count))


# ----------------------------------------------------------------- shared

## Frame time (ms, average and worst), fps and GPU time over SAMPLE_FRAMES.
func _time_frames() -> Dictionary:
	await _wait(0.3)
	var rid := get_viewport().get_viewport_rid()
	var total := 0.0
	var worst := 0.0
	var gpu := 0.0
	var last := Time.get_ticks_usec()
	for i in SAMPLE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		last = now
		total += ms
		worst = maxf(worst, ms)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	var avg := total / SAMPLE_FRAMES
	return {"ms": snappedf(avg, 0.01), "fps": snappedf(1000.0 / avg, 0.1), "worst_ms": snappedf(worst, 0.1),
		"gpu_ms": snappedf(gpu / SAMPLE_FRAMES, 0.01),
		"draws": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))}


func _capture(tag: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := _root().path_join(CAPTURES).path_join("%s_%s.png" % [game.map_name, tag])
	if image == null or image.save_png(path) != OK:
		_failures.append("capture %s" % tag)
	else:
		print("light check: captured %s" % path)


func _verdict() -> void:
	if _done:
		return
	_done = true
	DayNight.forced_hour = -1.0
	if _original_quality != "" and GameSettings.instance().graphics_quality != _original_quality:
		GameSettings.instance().set_graphics_quality(_original_quality)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	_results["seconds"] = snappedf(_now() - _started, 0.1)
	print("light check: ", JSON.stringify(_results))
	if _failures.is_empty():
		print("light check verdict: PASS")
		get_tree().quit(0)
	else:
		printerr("light check verdict: FAIL - ", "; ".join(_failures))
		get_tree().quit(1)
