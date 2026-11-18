extends Node3D

## Kaf Castle's interior drawn (Phase 6): the old game's approved Gothic build
## in place of the pack's grey walls. main.gd instances this scene at the
## map copy's offset when the map is joined and calls setup(session, main).
##
##   InteriorStructure   res://assets/castle/castle_interior.glb with its layout
##                       L0 at y = 200 (castle_kit.gd: surfaces, occluders,
##                       room lights); the map server's pack was compiled from
##                       the same glb's colliders, so floors, walls, doorways
##                       and landings stand where the server's do; the parts
##                       the realm left out (Kit.LEFT_OUT) are gone
##     CastleDecor       candles, chandeliers, torches, braziers, hearths,
##                       moonlight, props and the laid tables (castle_decor.gd)
##   PortalDoor_<id>     a portal that is a place (maps.json `dressing`
##                       "locked_door"): the Brine Vaults' door in its wall bay,
##                       its warning sign and two torches
##
## The turning stairs are not here: StairView draws them from the client
## core's own staircase poses (the ones the player's body stands on).
##
## Indoors the old game's atmosphere holds: a dim warm ambient (the candles
## and the moon light the rooms), glow on the flames as the quality preset
## allows (off on low, as outdoors: QualityPreset.apply_map calls
## apply_quality); the outdoor sun is put out while this map is drawn and the
## day's light (DayNight) leaves the castle alone, only the character fill on
## the camera follows the hour. Occlusion culling (the walls' box occluders)
## is on for the viewport while the castle stands and off again after.

const Kit = preload("res://maps/castle_interior/castle_kit.gd")
const Decor = preload("res://maps/castle_interior/castle_decor.gd")
const CastleFire = preload("res://maps/castle_interior/castle_fire.gd")
const DOOR_MODEL := "res://assets/dungeons/sealed_wing/fc_door.glb"
## The door model's depth (its stone frame's relief), metres; its frame
## stands flush on the corridor's inner wall (z = -12).
const DOOR_DEPTH := 0.71
const DOOR_WALL_Z := -12.0

## Layout L0 in world space.
const MAP_Y := 200.0
const AMBIENT := Color(0.34, 0.32, 0.36)
const AMBIENT_ENERGY := 0.6

var structure: Node3D
## What was built (the check prints it).
var built_stats: Dictionary = {}

var _occlusion_before := false
var _sun: DirectionalLight3D
var _env: WorldEnvironment
var _env_before: Environment

func _ready() -> void:
	name = "MapView"
	build()

func build() -> void:
	if structure != null:
		return
	var started := Time.get_ticks_msec()
	structure = Kit.instantiate()
	if structure == null:
		push_error("castle: %s is missing from this build" % Kit.GOTHIC)
		return
	structure.name = "InteriorStructure"
	structure.position.y = MAP_Y
	add_child(structure)
	Kit.restyle(structure)
	var layout := Kit.load_layout()
	# A low fill only: the candles, chandeliers and moonlight carry the rooms.
	Kit.add_room_lights(structure, layout, 0.0, 0.55)
	Decor.build(structure, 0.0, layout)
	built_stats = Decor.stats.duplicate()
	built_stats["doors"] = _dress_portals()
	built_stats["occluders"] = Kit.add_occluders(structure)
	built_stats["bodies_dropped"] = Kit.drop_bodies(structure)
	built_stats["lights"] = structure.find_children("*", "Light3D", true, false).size()
	built_stats["meshes"] = structure.find_children("*", "GeometryInstance3D", true, false).size()
	built_stats["build_ms"] = Time.get_ticks_msec() - started

func setup(_session: Node, main: Node) -> void:
	var viewport := get_viewport()
	_occlusion_before = viewport.use_occlusion_culling
	viewport.use_occlusion_culling = true
	_sun = main.get_node_or_null("Sun") as DirectionalLight3D
	if _sun != null:
		_sun.visible = false
	_env = main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if _env != null:
		_env_before = _env.environment
		_env.environment = _indoor_environment()

## Portals that are a place in the map, not just a trigger (maps.json
## `dressing`): the locked door of the Brine Vaults gets its door, its warning
## sign and its torches. Presentation only (the trigger is the server's).
func _dress_portals() -> int:
	var maps: Variant = RealmContent.table("maps")
	if not (maps is Dictionary):
		return 0
	var made := 0
	for entry: Dictionary in (maps as Dictionary).get("portals", []):
		if String(entry.get("map_id", "")) != "castle_interior" or String(entry.get("dressing", "")) != "locked_door":
			continue
		var c: Array = (entry.get("trigger", {}) as Dictionary).get("center", [0, 0, 0])
		var door := Node3D.new()
		door.name = "PortalDoor_" + String(entry.get("id", ""))
		add_child(door)
		door.position = Vector3(float(c[0]), float(c[1]) - 0.5, DOOR_WALL_Z + DOOR_DEPTH * 0.5)
		if ResourceLoader.exists(DOOR_MODEL):
			door.add_child((load(DOOR_MODEL) as PackedScene).instantiate())
		var sign: Label3D = preload("res://scripts/world/world_sign.gd").new()   # readable from afar, faded past 60 m
		sign.call("setup", 60.0, 15.0)
		sign.text = I18n.upper(tr("Out of bounds"))
		sign.font = UITheme.world_font(UITheme.W_DECO)
		sign.font_size = 40
		sign.outline_size = 8
		sign.modulate = Color(1.0, 0.86, 0.6)
		sign.position = Vector3(0, 5.6, DOOR_DEPTH * 0.5)
		door.add_child(sign)
		for side in [-1.0, 1.0]:
			var torch := OmniLight3D.new()
			torch.light_color = Color(1.0, 0.66, 0.36)
			torch.light_energy = 1.4
			torch.omni_range = 7.0
			torch.position = Vector3(side * 2.35, 3.4, 0.9)
			door.add_child(torch)
			var cup := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.16
			cone.bottom_radius = 0.06
			cone.height = 0.26
			var iron := StandardMaterial3D.new()
			iron.albedo_color = Color(0.14, 0.13, 0.13)
			iron.metallic = 0.6
			iron.roughness = 0.5
			cone.material = iron
			cup.mesh = cone
			cup.position = Vector3(side * 2.35, 3.08, 0.75)
			door.add_child(cup)
			CastleFire.make(door, Vector3(side * 2.35, 3.3, 0.75), Vector2(0.3, 0.5))
		made += 1
	return made

## The quality preset indoors (the old castle_atmosphere.gd): glow for the
## flames follows the preset like outdoors (off on low: the flames read
## without it, and its blur passes cost the iGPU ~0.1-0.25 ms a frame
## indoors). The Mobile renderer has no SSAO, SSIL, SDFGI or volumetric fog,
## so the old medium and high extras are not here, and the ambient keeps the
## low preset's level on every preset (the old lower one leaned on SSIL).
func apply_quality(preset: Dictionary) -> void:
	if not is_instance_valid(_env) or _env.environment == null or _env.environment == _env_before:
		return
	var env := _env.environment
	env.glow_enabled = bool(preset.get("glow", false))
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1

## The castle's own environment (the old castle_atmosphere.gd at low): a
## night sky beyond the windows, a dim warm ambient, ACES.
func _indoor_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.045, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT
	env.ambient_light_energy = AMBIENT_ENERGY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.glow_enabled = false
	env.fog_enabled = false
	return env

func _exit_tree() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.use_occlusion_culling = _occlusion_before
	if is_instance_valid(_sun):
		_sun.visible = true
	if is_instance_valid(_env) and _env_before != null:
		_env.environment = _env_before
