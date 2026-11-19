extends Node

## `--hitch-log`: what play costs, frame by frame (QualityPreset.apply adds it
## to main once). Prints every frame over HITCH_MS with the pipelines the
## driver compiled in it (by source: canvas, mesh, surface, draw,
## specialization) and the GPU time, and every SUMMARY_SECONDS a line with
## the average and worst frame, the 1 % low, the GPU time, draws and the
## compiles in that span. Vsync is turned off while it runs, so the numbers
## are what the machine can do, not the display's rate.
##
## A frame with draw-source compiles is a first-sight hitch the warm-up
## missed (ShaderWarmup); one with none is a load, a build or the CPU.
##
## `--hitch-mem`: once the map is built (and again at the end of a cycle),
## the memory monitors (video, textures, buffers, static).
##
## `--hitch-appear`: once the map is built and any warm-up is done, each of
## the map's creatures (ShaderWarmup.map_kinds) appears once as main.gd makes
## it (CreatureView.setup) and the time it took on the main thread is printed:
## the first-sight cost of a creature in play. `--hitch-drop-kept` lets go of
## what the warm-up kept first (the warm-up as it was before it kept anything).
##
## Without `--hitch-log` it runs quiet, in every game: vsync and the render
## timing are left alone, and only a frame over QUIET_MS once the map is built
## is written to the log (at most QUIET_LINES a session), with what compiled in
## it and where. A player's log then says what a freeze was (a Mac reported
## "a stutter the first time I mounted, cast, attacked" with nothing to show).
##
## `--hitch-cycle=low,medium,high`: the presets in turn, CYCLE_SECONDS each,
## switched live as Settings does but for this session only (nothing is
## saved), then the game quits; the summaries say what each one costs.

const HITCH_MS := 33.0
const SUMMARY_SECONDS := 5.0
const SOURCES := ["canvas", "mesh", "surface", "draw", "spec"]
const CYCLE_SECONDS := 10.0
const QUIET_MS := 250.0
const QUIET_LINES := 40

## Set before it enters the tree: the player's quiet log.
var quiet := false
var _quiet_left := QUIET_LINES

var _infos: Array = []
var _last: Array = []
var _span: Array = []
var _frames: PackedFloat32Array = PackedFloat32Array()
var _gpu := 0.0
var _draws := 0
var _since := 0.0
var _last_usec := 0
var _skip := 3
var _cycle: Array = []
var _cycle_at := 0.0
var _mem_at := -1.0
var _appear_at := -1.0

func _ready() -> void:
	process_priority = 1000
	_infos = ShaderWarmup.PIPELINE_INFOS
	_last = _counts()
	_span = _zeros()
	if quiet:
		_last_usec = Time.get_ticks_usec()
		return
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_last_usec = Time.get_ticks_usec()
	print("[HitchLog] on, preset %s" % QualityPreset.current())
	if OS.get_cmdline_user_args().has("--hitch-mem"):
		_mem_at = 8.0
	if OS.get_cmdline_user_args().has("--hitch-appear"):
		_appear_at = 3.0
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--hitch-cycle="):
			_cycle = Array(arg.trim_prefix("--hitch-cycle=").split(",", false))
			_cycle_at = CYCLE_SECONDS   # the joined preset first

func _counts() -> Array:
	var out: Array = []
	for info: int in _infos:
		out.append(int(RenderingServer.get_rendering_info(info)))
	return out

func _zeros() -> Array:
	var out: Array = []
	out.resize(SOURCES.size())
	out.fill(0)
	return out

func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var ms := (now - _last_usec) / 1000.0
	_last_usec = now
	var counts := _counts()
	var delta_counts := _zeros()
	var compiled := 0
	for i in counts.size():
		delta_counts[i] = int(counts[i]) - int(_last[i])
		_span[i] = int(_span[i]) + int(delta_counts[i])
		compiled += int(delta_counts[i])
	_last = counts
	if _skip > 0:
		_skip -= 1
		return
	if quiet:
		if ms > QUIET_MS and _quiet_left > 0 and bool(get_parent().get("built")) \
				and get_parent().get_node_or_null("ShaderWarmup") == null and not _loading():
			_quiet_left -= 1
			print("[hitch] %d ms, compiled %s, %s" % [int(ms), _named(delta_counts), _where()])
		return
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	_frames.append(ms)
	_gpu += gpu
	_draws += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	_since += ms / 1000.0
	if ms > HITCH_MS:
		print("[HitchLog] hitch %.1f ms (gpu %.1f ms) compiled %s at %s" % [ms, gpu, _named(delta_counts),
			_where()])
	if _since >= SUMMARY_SECONDS:
		_summary()
	if _appear_at > 0.0 and bool(get_parent().get("built")) and get_parent().get_node_or_null("ShaderWarmup") == null:
		_appear_at -= ms / 1000.0
		if _appear_at <= 0.0:
			_appear()
	if _mem_at > 0.0 and bool(get_parent().get("built")):
		_mem_at -= ms / 1000.0
		if _mem_at <= 0.0:
			memory_report()
	if (not _cycle.is_empty() or _cycle_at > 0.0) and bool(get_parent().get("built")):
		_cycle_at -= ms / 1000.0
		if _cycle_at <= 0.0:
			_next_preset()

## The next preset of --hitch-cycle, applied live for this session.
func _next_preset() -> void:
	if _cycle.is_empty():
		_summary()
		if OS.get_cmdline_user_args().has("--hitch-mem"):
			memory_report()
		print("[HitchLog] cycle done")
		get_tree().quit(0)
		return
	var preset := String(_cycle.pop_front())
	_summary()
	QualityPreset.use_for_session(preset)
	QualityPreset.apply(get_parent())
	print("[HitchLog] preset -> %s" % QualityPreset.current())
	_cycle_at = CYCLE_SECONDS

## A loading screen is up: what happens behind it is loading, not a hitch.
func _loading() -> bool:
	var screen := get_tree().root.get_node_or_null("MapLoadingScreen") as MapLoadingScreen
	return screen != null and screen.is_open()

func _named(counts: Array) -> String:
	var parts: Array = []
	for i in counts.size():
		if int(counts[i]) != 0:
			parts.append("%s %d" % [SOURCES[i], int(counts[i])])
	return "[%s]" % ", ".join(parts)

func _where() -> String:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return "-"
	return str(camera.global_position.snapped(Vector3(0.1, 0.1, 0.1)))

func _summary() -> void:
	var n := _frames.size()
	if n == 0:
		return
	var sorted := _frames.duplicate()
	sorted.sort()
	var total := 0.0
	for ms: float in _frames:
		total += ms
	var low_index := clampi(int(floor(n * 0.99)), 0, n - 1)
	print("[HitchLog] %.1f s: %d frames, avg %.2f ms (%.0f fps), 1%% low %.1f ms, worst %.1f ms, gpu %.2f ms, draws %d, compiled %s at %s" % [
		_since, n, total / n, 1000.0 * n / total, sorted[low_index], sorted[n - 1], _gpu / n, _draws / n,
		_named(_span), _where()])
	_frames.clear()
	_gpu = 0.0
	_draws = 0
	_since = 0.0
	_span = _zeros()


## The memory monitors and the process's working set.
func memory_report() -> void:
	var out: Array = []
	if OS.get_name() == "Windows":
		OS.execute("powershell", ["-NoProfile", "-Command", "(Get-Process -Id %d).WorkingSet64" % OS.get_process_id()], out)
	var working := String(out[0]).strip_edges() if not out.is_empty() else ""
	print("[HitchLog] memory (%s): working set %s MB, video %.0f MB, textures %.0f MB, buffers %.0f MB, static %.0f MB" % [
		QualityPreset.current(), str(roundi(float(working) / 1048576.0)) if working.is_valid_float() else "?",
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0])

## Each of the map's creatures made once, timed (see --hitch-appear).
func _appear() -> void:
	var map_id := String(get_parent().get("map_name"))
	if OS.get_cmdline_user_args().has("--hitch-drop-kept"):
		ShaderWarmup._kept = []
	var total := 0.0
	var parts: Array = []
	for kind: int in ShaderWarmup.map_kinds(map_id):
		if String(CreatureView.view_for_kind(kind).get("object", "")) != "":
			continue
		var started := Time.get_ticks_usec()
		var body := CreatureView.new()
		get_parent().add_child(body)
		body.setup(kind)
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		body.queue_free()
		total += ms
		parts.append("%s%s %.1f" % [CreatureView.species_for_kind(kind),
			" (boss)" if kind & CreatureView.BOSS_BIT != 0 else "", ms])
	for kind: int in [ChestView.KIND_CHEST, ChestView.KIND_CHEST_RARE, ChestView.KIND_CHEST]:
		var chest_started := Time.get_ticks_usec()
		var chest := ChestView.new()
		get_parent().add_child(chest)
		chest.setup(kind)
		var chest_ms := (Time.get_ticks_usec() - chest_started) / 1000.0
		chest.queue_free()
		total += chest_ms
		parts.append("loot chest %.1f" % chest_ms)
	print("[HitchLog] appear on %s: %.0f ms for %d creatures: %s" % [map_id, total, parts.size(), ", ".join(parts)])
