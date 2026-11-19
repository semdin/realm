extends RefCounted
class_name QualityPreset

## Graphics quality presets, one source for every map: low (integrated GPUs,
## the reference machine's Intel iGPU), medium and high (the old client's
## QualityPreset).
##
## The player picks one in Settings > Graphics (GameSettings.graphics_quality:
## "auto" or a preset name). Auto reads the adapter (integrated -> low,
## discrete -> high, anything else -> medium); `--quality=low|medium|high` on
## the command line wins over a saved choice, and a choice made in this
## session wins over both.
##
## What a preset sets, presentation only (nothing here can alter what the
## server decides):
##   * the 3D render scale (of at most a 1080p frame; the Mobile renderer
##     scales bilinearly) and FXAA; TAA stays off on every preset (it smeared
##     the ground and the trees whenever the camera moved, and its first use
##     compiled pipelines for a 3.6 s frame); no MSAA (the hero eye's NaN
##     flare under MSAA, and alpha-AA panics NAK under Mobile);
##   * the sun's shadow cascades, reach and atlas size; glow;
##   * view distance (camera far plane) with fog density matched to it, so the
##     far plane always sits inside the haze;
##   * the map's own parts through its `apply_quality(preset)` (the grounds:
##     vegetation, terrain detail, site draw distance, lamps, the triplanar
##     surfaces' light path; the castle: its glow);
##   * the spell effects' quality (SkillFX.quality) and the rain's density.
##
## `apply(main)` can run at any time: a change in Settings applies to the live
## world without a reload (main.gd listens to GameSettings.changed).

const NAMES := ["low", "medium", "high"]

const PRESETS := {
	"low": {
		"render_scale": 0.77,
		"fxaa": true,
		"shadow_max_distance": 45.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow_atlas": 2048,
		"glow": false,
		"view_distance": 1600.0,
		"site_view_distance": 650.0,
		"fog_density": 0.00060,
		"foliage_density": 0.5,
		"vegetation_lod_scale": 0.6,
		"vegetation_far_scale": 0.4,
		# every preset casts tree shadows from LOD1 only (the shadow impostor):
		# LOD0-only shadows appeared and vanished at 22 m
		"vegetation_shadow_lod": 1,
		"small_plant_shadows": false,
		"terrain_mesh_size": 32,
		"particle_scale": 0.5,
		"torch_range_scale": 0.85,
		"lamp_fade_begin": 50.0,
		"tonemap_exposure": 0.86,
		"lite_surfaces": true,
	},
	"medium": {
		"render_scale": 0.87,
		"fxaa": true,
		"shadow_max_distance": 90.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
		"glow": true,
		"view_distance": 2600.0,
		"site_view_distance": 1000.0,
		"fog_density": 0.00042,
		"foliage_density": 0.8,
		"vegetation_lod_scale": 0.8,
		"vegetation_far_scale": 0.7,
		"vegetation_shadow_lod": 1,
		"small_plant_shadows": true,
		"terrain_mesh_size": 48,
		"particle_scale": 0.75,
		"torch_range_scale": 1.0,
		"lamp_fade_begin": 70.0,
		"tonemap_exposure": 0.86,
		"lite_surfaces": false,
	},
	"high": {
		"render_scale": 1.0,
		"fxaa": true,
		"shadow_max_distance": 120.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
		"glow": true,
		"view_distance": 3800.0,
		"site_view_distance": 1500.0,
		"fog_density": 0.00032,
		"foliage_density": 1.0,
		"vegetation_lod_scale": 1.0,
		"vegetation_far_scale": 1.0,
		"vegetation_shadow_lod": 1,
		"small_plant_shadows": true,
		"terrain_mesh_size": 48,
		"particle_scale": 1.0,
		"torch_range_scale": 1.0,
		"lamp_fade_begin": 90.0,
		"tonemap_exposure": 0.86,
		"lite_surfaces": false,
	},
}

## The most pixels a 3D frame is drawn at before the preset's render scale (a
## 1080p frame), and the floor below which upscaling turns to mush.
const RENDER_PIXEL_BUDGET := 1920.0 * 1080.0
const MIN_RENDER_SCALE := 0.5

static var _current := ""
## A choice made in Settings this session (wins over `--quality=`).
static var _chosen_here := false


## The preset this run uses: a choice made this session, `--quality=` on the
## command line, the saved choice, then Auto.
static func current() -> String:
	if _current == "":
		_current = _resolve()
	return _current


static func _resolve() -> String:
	var chosen := GameSettings.instance().graphics_quality
	if not _chosen_here:
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--quality="):
				var wanted := arg.trim_prefix("--quality=").to_lower()
				if PRESETS.has(wanted):
					return wanted
	return chosen if PRESETS.has(chosen) else detect()


## Auto: what the adapter suggests.
static func detect() -> String:
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU, RenderingDevice.DEVICE_TYPE_CPU:
			return "low"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
			return "high"
	return "medium"


static func settings() -> Dictionary:
	return PRESETS[current()]


static func value(key: String, fallback: Variant = null) -> Variant:
	return settings().get(key, fallback)


## The Settings choice changed (GameSettings.set_graphics_quality): resolve
## again; main.gd then applies it to the live world.
static func choice_changed() -> void:
	_chosen_here = true
	_current = ""


## A preset for this session only, saved nowhere (HitchLog's --hitch-cycle).
static func use_for_session(preset: String) -> void:
	if PRESETS.has(preset):
		_chosen_here = true
		_current = preset


## Apply the preset to main's world: the viewport, the sun, the camera, the
## spell effects, the map's own parts, the weather and the day's light.
static func apply(main: Node) -> void:
	var preset := settings()
	if main.get_node_or_null("HitchLog") == null:
		var hitch_log: Node = load("res://scripts/world/hitch_log.gd").new()
		hitch_log.name = "HitchLog"
		hitch_log.set("quiet", not OS.get_cmdline_user_args().has("--hitch-log"))
		main.add_child(hitch_log)
	SkillFX.quality = current()
	var viewport := main.get_viewport()
	if viewport != null:
		apply_viewport(viewport)
	var sun := main.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = float(preset["shadow_max_distance"])
		sun.directional_shadow_mode = int(preset["shadow_splits"])
	var env_node := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node != null and env_node.environment != null:
		env_node.environment.glow_enabled = bool(preset["glow"])
	var camera: Variant = main.get("camera")
	if camera is Camera3D:
		(camera as Camera3D).far = float(preset["view_distance"])
	apply_map(main.get("map_view") as Node)
	for part: String in ["weather", "day_night"]:
		var node: Variant = main.get(part)
		if node is Node and (node as Node).has_method("apply_quality"):
			(node as Node).call("apply_quality", preset)


## The map's own parts (its `apply_quality`), once it is built and again on a
## switch.
static func apply_map(map_view: Node) -> void:
	if map_view != null and is_instance_valid(map_view) and map_view.has_method("apply_quality"):
		map_view.call("apply_quality", settings())


static func apply_viewport(viewport: Viewport) -> void:
	var preset := settings()
	viewport.use_taa = false
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(preset["fxaa"]) else Viewport.SCREEN_SPACE_AA_DISABLED
	apply_render_scale(viewport)
	# resizing the window or going fullscreen changes the pixel count
	if not viewport.size_changed.is_connected(apply_render_scale):
		viewport.size_changed.connect(apply_render_scale.bind(viewport))
	RenderingServer.directional_shadow_atlas_set_size(int(preset["shadow_atlas"]), true)


## The 3D frame's scale: the preset's render scale applies to a frame of at
## most RENDER_PIXEL_BUDGET pixels, so a Retina or 4K screen renders about
## what a 1080p one does; the rest is upscaled and the UI stays native.
static func render_scale(pixels: Vector2i) -> float:
	# the player's own choice (Settings > Graphics) is taken as it is
	var chosen := GameSettings.instance().chosen_render_scale()
	if chosen > 0.0:
		return chosen
	var scale := float(settings()["render_scale"])
	var count := float(pixels.x) * float(pixels.y)
	if count > RENDER_PIXEL_BUDGET:
		scale *= sqrt(RENDER_PIXEL_BUDGET / count)
	return maxf(scale, MIN_RENDER_SCALE)


static func apply_render_scale(viewport: Viewport) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var pixels := (viewport as Window).size if viewport is Window else Vector2i(1920, 1080)
	var scale := render_scale(pixels)
	# FSR 1 is Forward+ only; the Mobile renderer scales bilinearly
	var fsr := scale < 1.0 and RenderingServer.get_current_rendering_method() == "forward_plus"
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if fsr else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = scale
	# FSR sharpening off (2.0 = none): without TAA it made stone and foliage
	# shimmer in motion
	viewport.fsr_sharpness = 2.0


## CPU particles under `root` at the preset's budget; the authored amount is
## kept in metadata so switching presets never compounds.
static func tune_particles(root: Node) -> void:
	var ratio := float(settings()["particle_scale"])
	for node: Node in root.find_children("*", "CPUParticles3D", true, false):
		var particles := node as CPUParticles3D
		if not particles.has_meta("base_amount"):
			particles.set_meta("base_amount", particles.amount)
		particles.amount = maxi(1, int(round(float(particles.get_meta("base_amount")) * ratio)))
