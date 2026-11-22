extends Node3D
class_name ShaderWarmup

## Draws the map's creature bodies, a remote hero, the loot chests, the target
## ring, a ground warning, the status looks and every spell stage once, in
## front of the camera while the loading screen still covers it, so the GPU
## driver compiles their pipelines there instead of in play (the old client's
## ShaderWarmup).
##
## It goes in steps so the frames keep coming while the graphics driver works.
## A draw that needs a pipeline not yet ready waits for it on the main thread,
## and on a first start on Metal that can be minutes of a frozen screen (Apple's
## compiler, godot#123481). So while the loading screen covers the world nothing
## is drawn (WorldHold): the world and then these bodies, a few at a time, only
## enter the scene, which queues their pipelines on the worker pool, and each
## group waits for the pool to run dry (PipelineDrain) with the bar moving. Only
## then is everything drawn once, behind the screen, for what could not be
## foreseen. A long wait says so on the screen, and on a Mac's first start the
## message is up before the first possible wait.
##
## What it loaded stays loaded while the map is played (`_kept`, replaced by
## the next map's warm-up): freed with the warm-up's bodies, a creature's model
## was read from disk again on its first appearance (50-460 ms a species on the
## Intel iGPU, w11 2026-11-16), and its materials' shaders were freed with it,
## so their pipelines compiled a second time in play. Only the map's own
## creatures are drawn (its packs, Dark Shards and dungeon spawns,
## `map_kinds`): every species on every map cost ~2 s of loads per trip, and
## ~80 MB of video memory if all were kept.
##
## A first fight compiled ~170 pipelines in its first 30 s on the Intel iGPU
## (old client, 2026-10-30); warmed, half of them moved to the loading screen
## and the fight's p95 frame went 21 -> 15 ms. On a Mac (Metal keeps no
## pipeline cache) each new material froze the first frame it was drawn.
##
## MapTravel starts it when a trip's (or the front door's) new map is drawn
## behind the loading screen and lifts the screen once it is done:
##
##   if ShaderWarmup.wanted(): warmup = ShaderWarmup.start(main)
##   ... wait for warmup.done ...
##
## `--no-shader-warmup` skips it (comparisons); `--shader-warmup` runs it on a
## dev join too, where no loading screen covers it (the light check).

const DISTANCE := 7.0       # metres in front of the camera
const SPACING := 1.4
const SCALE := 0.35         # big creatures still fit the view; scale changes no shader
## The drawn pass ends once every spell stage has fired and been drawn
## (DRAWN_FRAMES after the last firing) and no pipeline was asked for in QUIET
## seconds, or after REVEAL_LIMIT (whatever is left compiles in play). No fixed
## minimum: a warm pipeline cache finishes in about a second; the loading screen
## stays up for MapTravel's settle frames after it, so nothing flashes.
const QUIET := 0.35
const DRAWN_FRAMES := 3
const REVEAL_LIMIT := 30.0
const REFIRE := [0.0, 0.5]  # spell stages fire twice: short layers die fast
## Frames the screen is drawn before the first step may take long (it has been
## presented by then, whatever the swap chain's depth).
const PRESENTED_FRAMES := 3
## A minimized window draws nothing: the wait for those frames ends anyway.
const ANNOUNCE_LIMIT := 1.5
## The groups grow while they are quick and fall to one thing at a time when
## the driver is slow, so a cold start moves the bar in small steps.
const BATCH_FIRST := 2
const BATCH_MAX := 12
const QUICK_STEP := 0.15
const SLOW_STEP := 1.0
## One group's wait for the compiler, and the whole queueing part: beyond them
## the warm-up goes on to the drawn pass rather than hold the player forever.
const STEP_LIMIT := 300.0
const WORK_LIMIT := 1200.0
## This long into the work the screen says it is taking a while.
const NOTICE_AFTER := 4.0
const PROGRESS_FROM := 60.0
const PROGRESS_TO := 96.0
## Which machine and build have been through a whole warm-up.
const READY_FILE := "user://graphics_ready.cfg"
# i18n-begin
const TEXT_PREPARING := "Preparing graphics…"
const TEXT_PERCENT := "Preparing graphics… %d%%"
const TEXT_FIRST_START := "First start: preparing graphics. This can take several minutes, please do not close the game."
const TEXT_SLOW := "Preparing graphics is taking a while. Please do not close the game."
# i18n-end
const HeroViewScript := "res://scripts/view/hero_view.gd"
## The Warden's thrown boulder (CombatView keeps it once thrown).
const BOULDER_MODEL := "res://assets/models/vegetation/rock_boulder.glb"

const PIPELINE_INFOS := [
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION,
]

## The last warm-up's report {bodies, stages, compiled, seconds} (the light
## check reads it after the node is gone).
static var last_report: Dictionary = {}
## What the last warm-up loaded (models, shaders), held for its map.
static var _kept: Array = []

var done := false
## What it drew and compiled (the light check prints it).
var bodies := 0
var stages := 0
var compiled := 0
var seconds := 0.0
var _t := 0.0
var _quiet := 0.0
var _fired := 0
var _frames_since_fire := 0
var _start_count := 0
var _last_count := 0
var _mute_was := false
var _slot := 0
## The warm-up hero (the wards are raised on it).
var _hero: Node3D = null
## The body that carries every status look.
var _first_body: Node3D = null
## What the flight stages follow: a trail or ribbon only takes geometry, and so
## is only drawn, when the thing it follows moves.
var _movers: Array[Node3D] = []
const MOVER_SPEED := 2.5
## A creature kind on this map: a second body of it is drawn burning away (a
## fallen creature's dissolve, CreatureView.warm_burn).
var _burn_kind := -1
enum Stage { ANNOUNCE, WORK, REVEAL }
var _stage := Stage.ANNOUNCE
## What is left to bring in, one call per body, extra or spell stage.
var _work: Array[Callable] = []
var _next := 0
var _batch := BATCH_FIRST
var _drain: PipelineDrain = null
var _drain_started := false
var _step_began := 0
var _work_began := 0
var _waited_ms := 0
var _presented := 0
var _notice_shown := false
var _reveal_t := 0.0
var _draw_count := 0
var _counting_stages := false
var _screen: MapLoadingScreen = null
## Set by MapTravel: keeps the world undrawn until the drawn pass.
var hold: WorldHold = null

static func wanted() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not OS.get_cmdline_user_args().has("--no-shader-warmup")

static func start(main: Node, world_hold: WorldHold = null) -> ShaderWarmup:
	var warmup := ShaderWarmup.new()
	warmup.name = "ShaderWarmup"
	warmup.hold = world_hold
	main.add_child(warmup)
	return warmup

## This machine has not been through a warm-up with this build.
static func first_start() -> bool:
	var file := ConfigFile.new()
	return file.load(READY_FILE) != OK or String(file.get_value("graphics", "key", "")) != _graphics_key()

static func _graphics_key() -> String:
	return "%s|%s|%s|%s" % [ProjectSettings.get_setting("application/config/version", ""),
		Engine.get_version_info().get("string", ""), RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()]

## Before anything that may wait: on a Mac's first start the screen says what
## is coming (a wait there can stop the frames, so it must already be up).
static func announce(screen: MapLoadingScreen) -> void:
	if OS.has_feature("macos") and first_start():
		screen.set_notice(screen.tr(TEXT_FIRST_START))

static func pipeline_count() -> int:
	var total := 0
	for info: int in PIPELINE_INFOS:
		total += int(RenderingServer.get_rendering_info(info))
	return total

func _ready() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_finish("no camera")
		return
	# In front of the camera, facing it.
	var basis := camera.global_transform.basis
	global_position = camera.global_position - basis.z * DISTANCE
	global_basis = basis
	_mute_was = AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0, true)
	_start_count = pipeline_count()
	_last_count = _start_count
	var screen := get_tree().root.get_node_or_null("MapLoadingScreen") as MapLoadingScreen
	if screen != null and screen.is_open():
		_screen = screen
		_screen.set_progress(PROGRESS_FROM, tr(TEXT_PREPARING))
	if hold != null:
		hold.cover_lights()
	# the world first: it entered the scene with the map, its step only waits
	_work.append(func() -> void: pass)
	_plan_creatures(String(get_parent().get("map_name")) if get_parent() != null else "")
	_work.append(_add_hero)
	_work.append(_add_combat_extras)
	for spell: Array in _spell_stages():
		_work.append(_fire_stage.bindv(spell))
	RenderingServer.frame_post_draw.connect(_on_frame_presented)
	print("[ShaderWarmup] started: %d steps" % _work.size())

func _exit_tree() -> void:
	if hold != null:
		hold.release()
	if not done:
		AudioServer.set_bus_mute(0, _mute_was)

func _on_frame_presented() -> void:
	_presented += 1

## The map's creatures (`map_kinds`): each species' body, an authored boss
## body where the map fields a boss of it, a Dark Shard's model. A map the
## content does not place (no y-band in maps.json) gets every species.
func _plan_creatures(map_id: String) -> void:
	var kinds := map_kinds(map_id)
	if kinds.is_empty() and not _has_band(map_id):
		kinds = _all_kinds()
	for kind: int in kinds:
		var view := CreatureView.view_for_kind(kind)
		match String(view.get("object", "")):
			"":
				_work.append(_add_creature.bind(kind))
			"stone":
				_work.append(_add_model.bind(String(view.get("model", ""))))
				# and its light: the shaft and the embers (StoneView)
				_work.append(func() -> void:
					var stone := StoneView.new()
					add_child(stone)
					if not stone.setup(kind):
						stone.queue_free()
						return
					stone.visible = true
					Nameplates.hide_own(stone, true)
					_place(stone))

func _add_creature(kind: int, burning := false) -> void:
	var body := CreatureView.new()
	add_child(body)
	if not body.setup(kind):
		body.queue_free()
		return
	_place(body)
	if burning:
		body.warm_burn()
	elif _burn_kind < 0:
		_burn_kind = kind

## A bare model (a Dark Shard's, the boulder): its materials drawn once.
func _add_model(path: String) -> void:
	if path == "" or not ResourceLoader.exists(path):
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var model := scene.instantiate() as Node3D
	if model == null:
		return
	add_child(model)
	_place(model)

## Every species with a model and every authored boss body (a map without a
## band).
static func _all_kinds() -> Array:
	var out: Array = []
	var kind := 1
	while kind < CreatureView.SPECIES_MASK:
		var species := CreatureView.species_for_kind(kind)
		if species == "":
			break
		var view := CreatureView.view_of(species)
		if String(view.get("object", "")) == "" and String(view.get("model", "")) != "":
			out.append(kind)
			if String(view.get("boss_model", "")) != "":
				out.append(kind | CreatureView.BOSS_BIT)
		kind += 1
	return out

static func _band(map_id: String) -> Dictionary:
	var maps: Variant = RealmContent.table("maps")
	if not (maps is Dictionary):
		return {}
	return ((maps as Dictionary).get("maps", {}) as Dictionary).get(map_id, {})

static func _has_band(map_id: String) -> bool:
	return _band(map_id).has("y_min")

## The creature kinds `map_id` can show (snapshot kinds: the species, with
## BOSS_BIT for an authored boss body): its packs (spawn_tables.json, roster
## or mob; a boss pack's boss body), the Dark Shards standing in its y-band,
## and every creature its dungeon's steps name (dungeons.json: spawns,
## hatchlings, cocoons; a boss's or miniboss's boss body).
static func map_kinds(map_id: String) -> Array:
	var species := {}   # species -> wants its boss body
	var tables: Variant = RealmContent.table("spawn_tables")
	if tables is Dictionary:
		for pack: Dictionary in (tables as Dictionary).get("packs", []):
			if String(pack.get("map", "")) != map_id:
				continue
			for mob: Variant in pack.get("roster", [pack.get("mob", "")]):
				species[String(mob)] = bool(species.get(String(mob), false))
			if bool(pack.get("boss", false)) or bool(pack.get("world_boss", false)):
				species[String(pack.get("mob", ""))] = true
		var band := _band(map_id)
		if band.has("y_min"):
			var low := float(band["y_min"])
			var high := float(band.get("y_max", low))
			for stone: Dictionary in (tables as Dictionary).get("monoliths", []):
				var at: Array = stone.get("pos", [0.0, -INF, 0.0])
				if float(at[1]) >= low and float(at[1]) <= high:
					species["stone_" + String(stone.get("type", "dark"))] = false
	var dungeon := DungeonData.for_map(map_id)
	if not dungeon.is_empty():
		_dungeon_mobs(dungeon[1], species)
	species.erase("")
	var out: Array = []
	var kind := 1
	while kind < CreatureView.SPECIES_MASK:
		var name := CreatureView.species_for_kind(kind)
		if name == "":
			break
		if species.has(name):
			out.append(kind)
			if bool(species[name]) and String(CreatureView.view_of(name).get("boss_model", "")) != "":
				out.append(kind | CreatureView.BOSS_BIT)
		kind += 1
	return out

## Every "mob" a dungeon's data names, at any depth (spawns, hatchlings,
## cocoons); a boss's or miniboss's wants its boss body.
static func _dungeon_mobs(data: Variant, species: Dictionary) -> void:
	if data is Dictionary:
		var entry := data as Dictionary
		if entry.has("mob"):
			var mob := String(entry["mob"])
			var boss := String(entry.get("role", "")) in ["boss", "miniboss"] or entry.has("boss_key")
			species[mob] = bool(species.get(mob, false)) or boss
		for value: Variant in entry.values():
			_dungeon_mobs(value, species)
	elif data is Array:
		for value: Variant in data:
			_dungeon_mobs(value, species)

func _add_hero() -> void:
	var hero: Node3D = load(HeroViewScript).new()
	add_child(hero)
	hero.call("setup", Color(0.85, 0.4, 0.11))
	_place(hero)
	_hero = hero
	# a body rising from a death: the spirit worn, and its outline over a
	# solid body (HeroView.ghost_rise), their pipelines on every kind of piece
	for phase in [1, 2]:
		var rising: Node3D = load(HeroViewScript).new()
		add_child(rising)
		rising.call("setup", Color(0.85, 0.4, 0.11))
		_place(rising)
		rising.call("ghost_hold", phase)

func _place(body: Node3D) -> void:
	body.position = _grid(_slot)
	body.scale = Vector3.ONE * SCALE
	_slot += 1
	bodies += 1

## What first shows in a fight: the status looks on a body, the loot chests,
## the target ring, a ground warning, a damage number.
func _add_combat_extras() -> void:
	var first: Node3D = null
	for child: Node in get_children():
		if child is CreatureView:
			first = child as Node3D
			break
	if first != null:
		var all := 0
		for bit: int in StatusFX.BITS:
			all |= bit
		(first as CreatureView).set_status(all)
		_first_body = first
	if _burn_kind >= 0:
		_add_creature(_burn_kind, true)
	for kind: int in [ChestView.KIND_CHEST, ChestView.KIND_CHEST_RARE]:
		var chest := ChestView.new()
		add_child(chest)
		chest.setup(kind)
		chest.position = _grid(_slot)
		_slot += 1
	var ring := TargetRing.new()
	add_child(ring)
	ring.follow(-1, global_position + global_basis * _grid(_slot), 1.4, TargetRing.GOLD)
	_slot += 1
	GroundWarning.spawn(self, global_position + global_basis * _grid(_slot), 2.0, 0.0, 0.0)
	_slot += 1
	# the floating combat text (every style, every glyph: canvas, one pass)
	FloatingText.warm()
	# a duelist's mark: the one label that keeps one size on screen and is
	# drawn over bodies (its own material)
	var mark := Label3D.new()
	mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mark.double_sided = false
	mark.fixed_size = true
	mark.no_depth_test = true
	mark.pixel_size = 0.001
	mark.font = UITheme.world_font(UITheme.W_BOLD)
	mark.font_size = 34
	mark.outline_size = 10
	mark.text = "1234"
	add_child(mark)
	mark.position = _grid(_slot) + Vector3.UP
	_slot += 1
	_add_model(BOULDER_MODEL)
	_add_blood()
	_add_wards()
	# the level-up moment's own shaders (its column, comets, ground light,
	# glitter, and the light it lays over the body)
	if is_instance_valid(_hero):
		LevelUpFX.warm(self, _hero)

## A bleeding body's spot of blood on the ground (StatusFX): the warmed body
## carries every status, knocked down included, and a knocked body leaves no
## spot, so the spot is laid here as StatusFX lays it.
func _add_blood() -> void:
	var spot := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.4, 0.35)
	quad.orientation = PlaneMesh.FACE_Y
	quad.material = StatusFX._material("splat")
	spot.mesh = quad
	spot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spot.transparency = 0.15
	add_child(spot)
	spot.position = _grid(_slot)
	spot.rotation.x = 0.7   # turned toward the camera, not edge-on
	_slot += 1

## The moments of a fight that last half a second, so they go into the drawn
## pass (in the work steps nothing is drawn and they would be over unseen): a
## bleeding wound's drops, the ice bursting off a body when a freeze ends, and
## the low-health edge of the screen (under the loading screen's layer).
func _fight_moments() -> void:
	if is_instance_valid(_first_body):
		for node: Node in _first_body.find_children("*", "", true, false):
			if node is StatusFX:
				(node as StatusFX)._spurt()
				(node as StatusFX)._shatter()
				break
	var layer := CanvasLayer.new()
	layer.layer = 80
	add_child(layer)
	var edge := LowHpVignette.new()
	layer.add_child(edge)
	edge.visible = true
	(edge.material as ShaderMaterial).set_shader_parameter("strength", 0.5)

## The ward's shell on the warm-up hero (its own meshes and shaders; the
## first ward raised in play compiled them).
func _add_wards() -> void:
	if not is_instance_valid(_hero):
		return
	if HudActionBar.spells().has("ward_shield"):
		WardShield.raise(self, _hero, REVEAL_LIMIT, "ward_shield")

func _grid(i: int) -> Vector3:
	const COLUMNS := 7
	return Vector3((i % COLUMNS - COLUMNS / 2) * SPACING, (i / COLUMNS) * SPACING - 1.0, 0.0)

## [spell, stage, index] of every spell stage.
func _spell_stages() -> Array:
	var out: Array = []
	for spell_id: String in VFXLibrary.SPELLS:
		for stage: String in VFXLibrary.stages_for(spell_id):
			out.append([spell_id, stage, out.size()])
	return out

func _fire_stage(spell_id: String, stage: String, i: int) -> void:
	var at := global_transform * Vector3(((i % 9) - 4) * 0.8, 1.5, -1.0)
	var opts := {}
	if stage == "travel":
		var mover := Node3D.new()
		add_child(mover)
		mover.global_position = at
		_movers.append(mover)
		opts["follow_target"] = mover
	if SkillFX.spawn_stage(self, spell_id, stage, at, -global_basis.z, null, opts) != null and _counting_stages:
		stages += 1

func _fire_spells() -> void:
	for spell: Array in _spell_stages():
		_fire_stage.callv(spell)

func _process(delta: float) -> void:
	if done:
		return
	_t += delta
	for mover: Node3D in _movers:
		if is_instance_valid(mover):
			mover.position += Vector3.RIGHT * MOVER_SPEED * delta
	match _stage:
		Stage.ANNOUNCE:
			if _presented >= PRESENTED_FRAMES or _t >= ANNOUNCE_LIMIT:
				_stage = Stage.WORK
				_work_began = Time.get_ticks_msec()
		Stage.WORK:
			_process_work()
		Stage.REVEAL:
			_process_reveal(delta)

## One group at a time: bring it in, let its frame queue its pipelines, wait for
## the pool to run dry.
func _process_work() -> void:
	var now := Time.get_ticks_msec()
	if _screen != null and not _notice_shown and now - _work_began > int(NOTICE_AFTER * 1000.0):
		_show_notice()
	if _drain == null:
		if _next >= _work.size() or now - _work_began > int(WORK_LIMIT * 1000.0):
			_begin_reveal()
			return
		var count := mini(_batch, _work.size() - _next)
		for i in count:
			(_work[_next + i] as Callable).call()
		_next += count
		_step_began = now
		_drain = PipelineDrain.new()
		_drain_started = false
		RealmGuard.set_phase("warmup %d/%d" % [_next, _work.size()])
		_dev_stall()
		return
	if not _drain_started:
		# this group's surfaces were handed to the renderer in the last frame
		_drain_started = true
		_drain.start()
		return
	var state := _drain.poll()
	var took := now - _step_began
	if state == PipelineDrain.MISSED:
		_drain.start()
	if state != PipelineDrain.PASSED and took < int(STEP_LIMIT * 1000.0):
		return
	_drain = null
	_waited_ms += took
	if took < int(QUICK_STEP * 1000.0):
		_batch = mini(_batch * 2, BATCH_MAX)
	elif took > int(SLOW_STEP * 1000.0):
		_batch = 1
		if _screen != null and not _notice_shown:
			_show_notice()
	if _screen != null:
		var share := float(_next) / float(_work.size())
		_screen.set_progress(lerpf(PROGRESS_FROM, PROGRESS_TO, share), tr(TEXT_PERCENT) % int(share * 100.0))

## The long wait is said once; a first start says what it is.
func _show_notice() -> void:
	_notice_shown = true
	_screen.set_notice(tr(TEXT_FIRST_START) if first_start() else tr(TEXT_SLOW))

## `--warmup-stall SECONDS` (not in a release): the main thread is held once, as
## a blocked draw would hold it.
func _dev_stall() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--warmup-stall")
	if _next >= 2 and i >= 0 and i + 1 < args.size() and not RealmPaths.is_release() \
			and not has_meta(&"stalled"):
		set_meta(&"stalled", true)
		print("[ShaderWarmup] holding the main thread for %s s" % args[i + 1])
		OS.delay_msec(int(float(args[i + 1]) * 1000.0))

## Everything is compiled that could be asked for ahead: now it is drawn once.
func _begin_reveal() -> void:
	_stage = Stage.REVEAL
	if hold != null:
		hold.release()
	_draw_count = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW))
	_fight_moments()
	_counting_stages = true
	_last_count = pipeline_count()
	RealmGuard.set_phase("warmup drawn pass")
	if _screen != null:
		_screen.set_progress(PROGRESS_TO, tr("Almost there…"))

func _process_reveal(delta: float) -> void:
	_reveal_t += delta
	if _fired < REFIRE.size() and _reveal_t >= float(REFIRE[_fired]):
		_fire_spells()
		_fired += 1
		_frames_since_fire = 0
	else:
		_frames_since_fire += 1
	var count := pipeline_count()
	if count != _last_count:
		_last_count = count
		_quiet = 0.0
	else:
		_quiet += delta
	var drawn := _fired >= REFIRE.size() and _frames_since_fire >= DRAWN_FRAMES
	if drawn and _quiet >= QUIET:
		_finish("")
	elif _reveal_t >= REVEAL_LIMIT:
		_finish("out of time")

func _finish(reason: String) -> void:
	done = true
	seconds = _t
	compiled = _last_count - _start_count
	var at_draw := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW)) - _draw_count
	if hold != null:
		hold.release()
	_keep()
	AudioServer.set_bus_mute(0, _mute_was)
	if reason == "":
		var file := ConfigFile.new()
		file.set_value("graphics", "key", _graphics_key())
		file.save(READY_FILE)
	last_report = {"bodies": bodies, "stages": stages, "compiled": compiled, "seconds": snappedf(seconds, 0.1),
		"reason": reason, "steps": _work.size(), "at_draw": at_draw}
	print("[ShaderWarmup] %s%d bodies, %d spell stages, %d pipelines compiled in %.1f s (%.1f s waiting on the driver, %d asked for while drawing)" % [
		(reason + ": ") if reason != "" else "", bodies, stages, compiled, _t, _waited_ms / 1000.0, at_draw])
	queue_free()

## Holds what the bodies were built from (each model's scene, the materials
## and shaders their meshes, overlays and particles use) until the next warm-up, so the map's creatures,
## chests and boulders reuse it in play: no disk read on a first appearance,
## and the warmed pipelines stay with their live shaders. The previous map's
## set is let go here, behind the loading screen.
func _keep() -> void:
	var kept := {}
	for node: Node in find_children("*", "", true, false):
		if node.scene_file_path != "" and not kept.has(node.scene_file_path):
			kept[node.scene_file_path] = load(node.scene_file_path)
		if node is GeometryInstance3D:
			var geometry := node as GeometryInstance3D
			_keep_material(geometry.material_override, kept)
			_keep_material(geometry.material_overlay, kept)
			if geometry is MeshInstance3D:
				var mesh_instance := geometry as MeshInstance3D
				for i in mesh_instance.get_surface_override_material_count():
					_keep_material(mesh_instance.get_surface_override_material(i), kept)
				_keep_mesh(mesh_instance.mesh, kept)
			elif geometry is CPUParticles3D:
				_keep_mesh((geometry as CPUParticles3D).mesh, kept)
			elif geometry is GPUParticles3D:
				var particles := geometry as GPUParticles3D
				_keep_material(particles.process_material, kept)
				for i in particles.draw_passes:
					_keep_mesh(particles.get_draw_pass_mesh(i), kept)
	_kept = kept.values()

## A mesh's own surface materials (a PlaneMesh's or QuadMesh's material).
static func _keep_mesh(mesh: Mesh, kept: Dictionary) -> void:
	if mesh == null:
		return
	for i in mesh.get_surface_count():
		_keep_material(mesh.surface_get_material(i), kept)

## A material made in code (a chest's motes, a pool's glow) is kept itself:
## a StandardMaterial3D's shader is shared by every material with its
## features and freed with the last of them.
static func _keep_material(material: Material, kept: Dictionary) -> void:
	if material == null:
		return
	kept[str(material.get_instance_id())] = material
	if material is ShaderMaterial and (material as ShaderMaterial).shader != null:
		var shader := (material as ShaderMaterial).shader
		kept[shader.resource_path if shader.resource_path != "" else str(shader.get_instance_id())] = shader
	if material.next_pass != null:
		_keep_material(material.next_pass, kept)
