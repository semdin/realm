extends Node3D
class_name ShaderWarmup

## Draws every creature body, a remote hero, the loot chests, the target ring,
## a ground warning, the status looks and every spell stage once, in front of
## the camera while the loading screen still covers it, so the GPU driver
## compiles their pipelines there instead of in play (the old client's
## ShaderWarmup).
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
const QUIET := 0.75         # done once no pipeline compiled for this long...
const MIN_TIME := 2.5
const MAX_TIME := 30.0      # ...or after this, whatever is left compiles in play
const REFIRE := [0.0, 0.9]  # spell stages fire twice: short layers die fast
const HeroViewScript := "res://scripts/view/hero_view.gd"

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

var done := false
## What it drew and compiled (the light check prints it).
var bodies := 0
var stages := 0
var compiled := 0
var seconds := 0.0
var _t := 0.0
var _quiet := 0.0
var _fired := 0
var _start_count := 0
var _last_count := 0
var _mute_was := false
var _slot := 0

static func wanted() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not OS.get_cmdline_user_args().has("--no-shader-warmup")

static func start(main: Node) -> ShaderWarmup:
	var warmup := ShaderWarmup.new()
	warmup.name = "ShaderWarmup"
	main.add_child(warmup)
	return warmup

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
	_add_creatures()
	_add_hero()
	_add_combat_extras()
	print("[ShaderWarmup] started: %d bodies" % bodies)

## Every species with a model, and every authored boss body.
func _add_creatures() -> void:
	var kind := 1
	while kind < CreatureView.SPECIES_MASK:
		var species := CreatureView.species_for_kind(kind)
		if species == "":
			break
		var view := CreatureView.view_of(species)
		if String(view.get("object", "")) == "" and String(view.get("model", "")) != "":
			_add_creature(kind)
			if String(view.get("boss_model", "")) != "":
				_add_creature(kind | CreatureView.BOSS_BIT)
		kind += 1

func _add_creature(kind: int) -> void:
	var body := CreatureView.new()
	add_child(body)
	if not body.setup(kind):
		body.queue_free()
		return
	_place(body)

func _add_hero() -> void:
	var hero: Node3D = load(HeroViewScript).new()
	add_child(hero)
	hero.call("setup", Color(0.85, 0.4, 0.11))
	_place(hero)

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
	FloatingText.spawn(self, global_position + global_basis * (_grid(_slot) + Vector3.UP), "1234!",
		Color(1.0, 0.8, 0.3), 1.3)
	_slot += 1

func _grid(i: int) -> Vector3:
	const COLUMNS := 7
	return Vector3((i % COLUMNS - COLUMNS / 2) * SPACING, (i / COLUMNS) * SPACING - 1.0, 0.0)

func _fire_spells() -> void:
	var i := 0
	for spell_id: String in VFXLibrary.SPELLS:
		for stage: String in VFXLibrary.stages_for(spell_id):
			var at := global_transform * Vector3(((i % 9) - 4) * 0.8, 1.5, -1.0)
			if SkillFX.spawn_stage(self, spell_id, stage, at, -global_basis.z) != null:
				stages += 1
			i += 1

func _process(delta: float) -> void:
	if done:
		return
	_t += delta
	if _fired < REFIRE.size() and _t >= float(REFIRE[_fired]):
		_fire_spells()
		_fired += 1
	var count := pipeline_count()
	if count != _last_count:
		_last_count = count
		_quiet = 0.0
	else:
		_quiet += delta
	if (_t >= MIN_TIME and _quiet >= QUIET) or _t >= MAX_TIME:
		_finish("")

func _finish(reason: String) -> void:
	done = true
	seconds = _t
	compiled = _last_count - _start_count
	AudioServer.set_bus_mute(0, _mute_was)
	last_report = {"bodies": bodies, "stages": stages, "compiled": compiled, "seconds": snappedf(seconds, 0.1),
		"reason": reason}
	print("[ShaderWarmup] %s%d bodies, %d spell stages, %d pipelines compiled in %.1f s" % [
		(reason + ": ") if reason != "" else "", bodies, stages, compiled, _t])
	queue_free()
