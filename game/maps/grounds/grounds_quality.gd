extends RefCounted

## The grounds' graphics presets: the old client's QualityPreset, the parts
## that touch the outdoor map. Low is the integrated-GPU profile (the
## reference machine's Intel iGPU), medium and high the rest; Auto reads the
## adapter (integrated -> low, discrete -> high, anything else -> medium) and
## `--quality=low|medium|high` wins over it.
##
## What a preset sets, presentation only:
##   * the 3D render scale (of at most a 1080p frame; FSR 1 upscales on
##     Forward+, the Mobile renderer bilinearly) and
##     FXAA; TAA stays off on every preset (it smeared the ground and the trees
##     whenever the camera moved);
##   * sun shadow cascades, reach and atlas size; glow and SSAO;
##   * view distance (camera far plane) with fog density matched to it;
##   * how far the sites and the village are drawn (the castle keeps the full
##     view distance);
##   * vegetation: how much of the small stuff, how far every LOD reaches,
##     which LODs cast shadows; terrain mesh detail;
##   * lamp light reach and fade distance; the triplanar surfaces' light path.
## The root viewport's settings and the shadow atlas are given back when the
## grounds leave (restore()).

const PRESETS := {
	"low": {
		"render_scale": 0.77,
		"fxaa": true,
		"shadow_max_distance": 45.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow_atlas": 2048,
		"glow": false,
		"ssao": false,
		"view_distance": 1600.0,
		"site_view_distance": 650.0,
		"fog_density": 0.00060,
		"foliage_density": 0.5,
		"vegetation_lod_scale": 0.6,
		"vegetation_far_scale": 0.4,
		"vegetation_shadow_lod": 1,
		"small_plant_shadows": false,
		"terrain_mesh_size": 32,
		"particle_scale": 0.5,
		"torch_range_scale": 0.85,
		"lamp_fade_begin": 50.0,
		"lite_surfaces": true,
	},
	"medium": {
		"render_scale": 0.87,
		"fxaa": true,
		"shadow_max_distance": 90.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
		"glow": true,
		"ssao": false,
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
		"lite_surfaces": false,
	},
	"high": {
		"render_scale": 1.0,
		"fxaa": true,
		"shadow_max_distance": 120.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
		"glow": true,
		"ssao": true,
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
		"lite_surfaces": false,
	},
}

## The most pixels a 3D frame is drawn at before the preset's render scale (a
## 1080p frame), and the floor below which upscaling turns to mush.
const RENDER_PIXEL_BUDGET := 1920.0 * 1080.0
const MIN_RENDER_SCALE := 0.5


## The preset this run uses: `--quality=` on the command line, else what the
## adapter suggests.
static func resolve() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			var wanted := arg.trim_prefix("--quality=").to_lower()
			if PRESETS.has(wanted):
				return wanted
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU, RenderingDevice.DEVICE_TYPE_CPU:
			return "low"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
			return "high"
	return "medium"


static func settings(name: String) -> Dictionary:
	return PRESETS.get(name, PRESETS["low"])


## The 3D frame's scale: the preset's render scale applies to a frame of at
## most RENDER_PIXEL_BUDGET pixels, so a Retina or 4K screen renders about
## what a 1080p one does; FSR upscales the rest and the UI stays native.
static func render_scale(preset: Dictionary, pixels: Vector2i) -> float:
	var scale := float(preset["render_scale"])
	var count := float(pixels.x) * float(pixels.y)
	if count > RENDER_PIXEL_BUDGET:
		scale *= sqrt(RENDER_PIXEL_BUDGET / count)
	return maxf(scale, MIN_RENDER_SCALE)


## The viewport's settings before the grounds changed them (restore()).
static func viewport_state(viewport: Viewport) -> Dictionary:
	return {"mode": viewport.scaling_3d_mode, "scale": viewport.scaling_3d_scale,
		"sharpness": viewport.fsr_sharpness, "aa": viewport.screen_space_aa, "taa": viewport.use_taa,
		"atlas": int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 4096))}


static func apply_viewport(viewport: Viewport, preset: Dictionary) -> void:
	if viewport == null:
		return
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(preset["fxaa"]) else Viewport.SCREEN_SPACE_AA_DISABLED
	var pixels := (viewport as Window).size if viewport is Window else Vector2i(1920, 1080)
	var scale := render_scale(preset, pixels)
	# FSR 1 is Forward+ only; the Mobile renderer scales bilinearly
	var fsr := scale < 1.0 and RenderingServer.get_current_rendering_method() == "forward_plus"
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if fsr else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = scale
	# FSR sharpening off (2.0 = none): without TAA it made stone and foliage
	# shimmer in motion
	viewport.fsr_sharpness = 2.0
	RenderingServer.directional_shadow_atlas_set_size(int(preset["shadow_atlas"]), true)


static func restore(viewport: Viewport, state: Dictionary) -> void:
	if viewport == null or state.is_empty():
		return
	viewport.scaling_3d_mode = int(state["mode"])
	viewport.scaling_3d_scale = float(state["scale"])
	viewport.fsr_sharpness = float(state["sharpness"])
	viewport.screen_space_aa = int(state["aa"])
	viewport.use_taa = bool(state["taa"])
	RenderingServer.directional_shadow_atlas_set_size(int(state["atlas"]), true)


## Sun, environment and camera.
static func apply_lighting(preset: Dictionary, sun: DirectionalLight3D, env: Environment, camera: Camera3D) -> void:
	if sun != null:
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = float(preset["shadow_max_distance"])
		sun.directional_shadow_mode = int(preset["shadow_splits"])
	if env != null:
		env.glow_enabled = bool(preset["glow"])
		env.ssao_enabled = bool(preset["ssao"])
		if env.fog_enabled:
			env.fog_density = float(preset["fog_density"])
	if camera != null:
		camera.far = float(preset["view_distance"])


## The grounds' own lamps and site geometry under `root`.
static func apply_scenery(preset: Dictionary, root: Node) -> void:
	var range_scale := float(preset["torch_range_scale"])
	var fade_begin := float(preset["lamp_fade_begin"])
	for light: Node in root.get_tree().get_nodes_in_group("grounds_torch_lights"):
		if light is OmniLight3D and root.is_ancestor_of(light):
			var omni := light as OmniLight3D
			if not omni.has_meta("base_range"):
				omni.set_meta("base_range", omni.omni_range)
			omni.omni_range = float(omni.get_meta("base_range")) * range_scale
			omni.distance_fade_enabled = true
			omni.distance_fade_begin = fade_begin
			omni.distance_fade_length = fade_begin * 0.35
	var site_range := float(preset["site_view_distance"])
	for node: Node in root.get_tree().get_nodes_in_group("grounds_site_geometry"):
		if node is GeometryInstance3D and root.is_ancestor_of(node):
			var geo := node as GeometryInstance3D
			geo.visibility_range_begin = 0.0
			geo.visibility_range_begin_margin = 0.0
			geo.visibility_range_end = site_range
			geo.visibility_range_end_margin = site_range * 0.1
			geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	var ratio := float(preset["particle_scale"])
	for node: Node in root.find_children("*", "CPUParticles3D", true, false):
		var particles := node as CPUParticles3D
		particles.amount = maxi(1, int(round(float(particles.amount) * ratio)))
