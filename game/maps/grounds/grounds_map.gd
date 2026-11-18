extends Node3D

## The grounds drawn with the old game's approved art (Phase 6.1): the
## Terrain3D ground and its forest, the lake, the castle shell, the courtyard,
## the precinct (Trial Hall, Ember Pavilion, training yard, cave mouth), the
## sites (Orvell and its roads, Ombrek's hut, greenhouses, boathouse, station,
## the skyring pitch, the stone circle, the camp, the crypt, the hollow), road
## lamps, the broom landing and the far horizon. The sky, the sun, the fog's
## colour and the ambient follow the hour and the rain (DayNight); the quality
## preset (QualityPreset) reaches the grounds' own parts through
## apply_quality().
##
## main.gd instances this scene at the copy offset once the session has
## joined and calls setup(session, main). Every builder is the old world's,
## reading the same layout.json, scatter files, terrain data and content
## positions the old world was built from; the server's map pack was compiled
## from that world, so walls stand where they block and the drawn ground is
## the ground the feet stand on. Nothing here collides: the server and the
## prediction collide with the pack, clicks pick through RealmSession.pick.
## `--placeholder-world` shows the pack's grey shapes instead (alignment).
##
## Headless (the checks without a screen) nothing is built.

const Layout := preload("res://maps/grounds/grounds_layout.gd")
const Pbr := preload("res://maps/grounds/grounds_pbr.gd")
const Mats := preload("res://maps/grounds/grounds_mats.gd")
const ArchKit := preload("res://maps/grounds/arch_kit.gd")
const Castle := preload("res://maps/grounds/castle_exterior.gd")
const Courtyard := preload("res://maps/grounds/grounds_courtyard.gd")
const Precinct := preload("res://maps/grounds/grounds_precinct.gd")
const Sites := preload("res://maps/grounds/grounds_sites.gd")
const Lake := preload("res://maps/grounds/grounds_lake.gd")
const Horizon := preload("res://maps/grounds/grounds_horizon.gd")
const Scatter := preload("res://maps/grounds/grounds_scatter.gd")
const TERRAIN_SCENE := "res://maps/grounds/grounds_terrain.tscn"
## `--check-grounds` (GroundsCheck).
const CHECK_SCRIPT := "res://maps/grounds/grounds_check.gd"

## The broom landing pad (maps.json spawn `castle_landing_pad`).
const LANDING_PAD := Vector2(40.0, 15.0)
const LANDING_RADIUS := 4.0

var session: Node
var main: Node
var terrain: Node3D
var quality := "low"
var preset: Dictionary = {}
## What each part of the build cost (ms), for the log and the check.
var build_ms: Dictionary = {}



func setup(p_session: Node, p_main: Node) -> void:
	session = p_session
	main = p_main
	if DisplayServer.get_name() == "headless":
		if OS.get_cmdline_user_args().has("--check-grounds"):
			printerr("grounds check verdict: FAIL - headless: nothing is drawn (run it with a window)")
			main.get_tree().quit(1)
		return
	quality = QualityPreset.current()
	preset = QualityPreset.settings()
	Pbr.set_lite(bool(preset.get("lite_surfaces", false)))
	var started := Time.get_ticks_usec()
	var last := [started]
	# Each part says when it starts, so a build that never finishes on some
	# machine (a driver stall) names the part in the log (flushed per line).
	var lap := func(part: String, next: String = "") -> void:
		var now := Time.get_ticks_usec()
		build_ms[part] = (now - int(last[0])) / 1000.0
		last[0] = now
		if next != "":
			print("[grounds] building %s" % next)
	print("[grounds] building terrain")
	terrain = (load(TERRAIN_SCENE) as PackedScene).instantiate() as Node3D
	add_child(terrain)
	Layout.terrain = terrain
	lap.call("terrain", "castle")
	await main.travel.build_pause(0.15)
	var sun := main.get_node_or_null("Sun") as DirectionalLight3D
	var env_node := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env: Environment = env_node.environment if env_node != null else null
	_sky_and_sun(sun, env)
	Castle.build(self)
	lap.call("castle", "courtyard")
	await main.travel.build_pause(0.3)
	Courtyard.build(self)
	lap.call("courtyard", "precinct")
	await main.travel.build_pause(0.4)
	Precinct.build(self)
	_broom_landing()
	lap.call("precinct", "sites")
	await main.travel.build_pause(0.5)
	Sites.build_all(self)
	lap.call("sites", "lake+horizon+lamps")
	await main.travel.build_pause(0.75)
	var lake := Node3D.new()
	lake.name = "Lake"
	add_child(lake)
	Lake.build(lake)
	print("[grounds] building horizon")
	Horizon.build(self)
	print("[grounds] building road lamps")
	_road_lamps()
	lap.call("lake+horizon+lamps", "vegetation")
	await main.travel.build_pause(0.85)
	terrain.call("plant", preset)
	lap.call("vegetation", "quality")
	_apply_scenery(preset)
	lap.call("quality")
	build_ms["total"] = (Time.get_ticks_usec() - started) / 1000.0
	var parts: Array = []
	for part: String in build_ms:
		parts.append("%s %.0f" % [part, build_ms[part]])
	print("[grounds] built on %s (ms): %s" % [quality, ", ".join(parts)])
	if OS.get_cmdline_user_args().has("--check-grounds"):
		var check: Node = load(CHECK_SCRIPT).new()
		check.name = "GroundsCheck"
		check.set("game", main)
		check.set("map", self)
		add_child(check)


func _exit_tree() -> void:
	if Layout.terrain == terrain:
		Layout.terrain = null


## Ground height under (x, z) from the drawn terrain (NAN when none).
func height_at(x: float, z: float) -> float:
	return Layout.height_at(x - position.x, z - position.z) + position.y


## The quality preset (QualityPreset.apply_map, at join and on a switch in
## Settings): the vegetation, the terrain's detail, the surfaces' light path,
## the lamps and how far the sites are drawn.
func apply_quality(p_preset: Dictionary) -> void:
	if terrain == null:
		return
	var same := p_preset == preset
	preset = p_preset
	quality = QualityPreset.current()
	if same:
		return
	Pbr.set_lite(bool(preset.get("lite_surfaces", false)))
	terrain.call("plant", preset)
	_apply_scenery(preset)


## The hour's light (DayNight, as the lamps change): the clock dials glow
## from behind as the night comes and are a plain painted dial by day.
func apply_daylight(night: float) -> void:
	Castle.daylight(night)


## The grounds' own lamps and site geometry, and their particles.
func _apply_scenery(p_preset: Dictionary) -> void:
	var range_scale := float(p_preset["torch_range_scale"])
	var fade_begin := float(p_preset["lamp_fade_begin"])
	for light: Node in get_tree().get_nodes_in_group("grounds_torch_lights"):
		if light is OmniLight3D and is_ancestor_of(light):
			var omni := light as OmniLight3D
			if not omni.has_meta("base_range"):
				omni.set_meta("base_range", omni.omni_range)
			omni.omni_range = float(omni.get_meta("base_range")) * range_scale
			omni.distance_fade_enabled = true
			omni.distance_fade_begin = fade_begin
			omni.distance_fade_length = fade_begin * 0.35
	var site_range := float(p_preset["site_view_distance"])
	for node: Node in get_tree().get_nodes_in_group("grounds_site_geometry"):
		if node is GeometryInstance3D and is_ancestor_of(node):
			var geo := node as GeometryInstance3D
			geo.visibility_range_begin = 0.0
			geo.visibility_range_begin_margin = 0.0
			geo.visibility_range_end = site_range
			geo.visibility_range_end_margin = site_range * 0.1
			geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	QualityPreset.tune_particles(self)


# ------------------------------------------------------------------ sky

## The old grounds' fog and sun on main's environment and light: light
## exponential fog plus aerial perspective with a height falloff (a 2 km
## valley seen from a broom stays clear above the haze), a softer sun with a
## weak specular lobe (the bare rock faces blew out at grazing angles). The
## sky itself, the sun's place and colour, the fog's colour and density, the
## ambient and the exposure are DayNight's (the hour and the rain).
func _sky_and_sun(sun: DirectionalLight3D, env: Environment) -> void:
	if env != null:
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = 0.62
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		env.fog_light_energy = 1.0
		env.fog_height = 40.0
		env.fog_height_density = 0.004
		env.fog_aerial_perspective = 0.35
		env.fog_sky_affect = 0.25
		env.glow_intensity = 0.16
		env.glow_bloom = 0.0
		env.glow_hdr_threshold = 1.35
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	if sun != null:
		sun.light_specular = 0.25
		sun.shadow_enabled = true
		sun.directional_shadow_blend_splits = true
		sun.shadow_normal_bias = 0.8


# ------------------------------------------------------------- landing pad

func _broom_landing() -> void:
	var p := Layout.ground(LANDING_PAD.x, LANDING_PAD.y)
	var pad := Node3D.new()
	pad.name = "BroomLanding"
	pad.position = p
	add_child(pad)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = LANDING_RADIUS
	cm.bottom_radius = LANDING_RADIUS + 0.2
	cm.height = 0.5
	cm.material = Pbr.surface("stone_tiles_02")
	disc.mesh = cm
	disc.position.y = -0.18
	pad.add_child(disc)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = LANDING_RADIUS - 0.6
	tm.outer_radius = LANDING_RADIUS - 0.3
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.95, 0.75, 0.25)
	gold.metallic = 0.9
	gold.roughness = 0.25
	gold.emission_enabled = true
	gold.emission = Color(0.9, 0.65, 0.2)
	gold.emission_energy_multiplier = 0.4
	tm.material = gold
	ring.mesh = tm
	ring.position.y = 0.1
	pad.add_child(ring)
	var label: Label3D = Mats.WorldSign.new()   # readable from afar, faded past 80 m
	label.call("setup", 80.0, 15.0)
	label.text = I18n.upper(I18n.t("Broom landing"))
	label.font = UITheme.world_font(UITheme.W_DECO)
	label.font_size = 30
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 3.2, 0)
	pad.add_child(label)


# ------------------------------------------------------------- road lamps

## Lamp posts along the roads near the castle and Orvell (positions baked by
## the old art pipeline into scatter/lamp.bin), each with its warm light.
func _road_lamps() -> void:
	var data := Scatter.instances("lamp")
	if data.is_empty():
		push_warning("grounds: no road lamps (assets/terrain/grounds/scatter/lamp.bin is missing)")
		return
	var root := Node3D.new()
	root.name = "RoadLamps"
	add_child(root)
	var kit := ArchKit.new()
	for i in data.size() / 5:
		var o := i * 5
		var at := Vector3(data[o], data[o + 1], data[o + 2])
		if Courtyard.encloses(Vector2(at.x, at.z)):
			continue
		kit.box(at + Vector3(0, 1.6, 0), Vector3(0.16, 3.2, 0.16), 0.0, "metal")
		kit.box(at + Vector3(0, 3.35, 0), Vector3(0.45, 0.5, 0.45), 0.0, "glass")
		kit.pyramid(at + Vector3(0, 3.6, 0), Vector2(0.55, 0.55), 0.35, 0.0, "metal", 0.05)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.78, 0.48)
		l.light_energy = 0.9
		l.omni_range = 9.0
		l.distance_fade_enabled = true
		l.distance_fade_begin = 90.0
		l.distance_fade_length = 30.0
		l.position = at + Vector3(0, 3.3, 0)
		l.add_to_group("grounds_torch_lights")
		root.add_child(l)
	kit.finish(root, Mats.materials(), "LampPosts")
