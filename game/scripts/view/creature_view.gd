extends Node3D
class_name CreatureView

## One creature drawn from interpolated snapshots: its model and clips come from
## content/data/creature_views.json, the clip it plays from the replicated state
## (idle, moving, attacking, dead), the speed it is seen to cover and its
## replicated status (StatusFX draws the look; a stunned or thrown body plays
## its stun clip, a frozen one holds its pose, a slowed one moves at the slowed
## pace). A telegraphed ability (CombatView hands it over) plays the ability's
## own clip pair, its windup stretched to end on the server's release tick and
## its strike over the recovery. It decides nothing.
##
## A multi-part boss (creature_views.json `rig` threehead_boss / snare_boss)
## wears its parts on its own model: its heads or vines are separate creatures
## on the wire (rig boss_part, drawn by nothing of their own: main.gd targets
## and hits them where the server holds them on the body). A part that is down
## bends that head or vine on the model (PartDroop: Threehead's head slumps,
## the Strangling Vine's vine withers and shrinks). Threehead's stun is the
## sleep the chime lulls it into: its Sleep clip, a slow pale haze drifting up
## off each head still standing, no stun stars (and no word over it).
##
## A web thing (rig web_object: the Web Mother's egg sacs and cocoons) has no
## clips: its death is the silk splitting open (SilkBurst, with the fluid
## inside it, creature_views.json `fluid`) while the model swells, slumps
## flat into the floor and is gone. `stretch` widens or heightens a model
## past its uniform `scale` (a cocoon fitted round a player), `silk_alpha`
## draws it as thin silk the body inside shows through.
##
## A fallen body plays its death clip to the end, lies a beat, then burns away
## (creature_dissolve.gdshader: a noise front eating it from the top, charring
## ahead of a glowing ember edge, embers rising off it, a breath of ash). The
## server keeps a corpse in its snapshots only CORPSE_TICKS (2 s): when it
## drops one still burning, main.gd hands the body over (`linger`) and forgets
## it - no table holds it, so nothing targets, names or voices it - and the
## body frees itself once burnt out.

## Snapshot states (realm_server sim.rs).
const STATE_IDLE := 0
const STATE_MOVING := 1
const STATE_ATTACKING := 2
const STATE_DEAD := 3

## Which clip plays for each slot, per animation set; a clip the body lacks
## falls back to Idle.
const ANIM_SETS := {
	"spider": {"idle": "Idle", "walk": "Walk", "run": "Walk",
		"anticipation": "Bite_Anticipation", "attack": "Bite_Attack", "hit": "Hit", "stun": "Stun", "death": "Death"},
	"troll": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"caster": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Charge2_Anticipation", "attack": "Charge2_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"undead": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"goblin": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"goblin_caster": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Cast_Anticipation", "attack": "Cast_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"wraith": {"idle": "Idle", "walk": "Float", "run": "Float",
		"anticipation": "Reach_Anticipation", "attack": "Reach_Attack", "hit": "Hit", "stun": "Stun", "death": "Death"},
	"hound": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Bite_Anticipation", "attack": "Bite_Attack", "hit": "Hit", "stun": "Sleep", "death": "Death"},
	"snare": {"idle": "Idle", "walk": "Idle", "run": "Idle",
		"anticipation": "Lash_Anticipation", "attack": "Lash_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"knight": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"pixie": {"idle": "Idle", "walk": "Idle", "run": "Idle",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "stun": "Hit", "death": "Death"},
	"generic": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Idle", "attack": "Idle", "hit": "Hit", "stun": "Hit", "death": "Death"},
}

## Seen ground speed (m/s) above which the body counts as moving, with
## hysteresis so a body on the threshold does not flicker.
const MOVING_ON := 0.35
const MOVING_OFF := 0.15
const TURN_RATE := 10.0
## Where in a one-clip move (no _Anticipation/_Attack pair) the blow lands.
const SINGLE_STRIKE := 0.55
## A stun played on the hit clip (no stun clip of its own) holds the recoil
## this far into it, the body reeling, for as long as the stun lasts.
const STUN_HOLD := 0.4
## A snapshot creature kind: the low 13 bits are its species index + 1
## (RealmContent.species_of_kind), the marks above them say it rolled elite (a
## stronger copy of the same species), is enraged or is a boss.
const ELITE_BIT := 0x8000
const ENRAGED_BIT := 0x4000
const BOSS_BIT := 0x2000
const SPECIES_MASK := 0x1FFF
## The multi-part rigs: the bone chain each part key bends when the part is
## down (root first; as the old game bent them), how far it
## bends and the size it shrinks to, and whether the stun is a sleep.
## (Threehead's bend is negative: a positive turn about this rig's neck X
## lifts the head.)
const MULTIPART := {
	"threehead_boss": {"chains": {"L": ["Neck.L", "Head.L"], "M": ["Neck.M", "Head.M"], "R": ["Neck.R", "Head.R"]},
		"degrees": -35.0, "shrink": 1.0, "sleeps": true, "heads": {"L": "Head.L", "M": "Head.M", "R": "Head.R"}},
	"snare_boss": {"chains": {"L": ["VineL1", "VineL2", "VineL3", "VineL4"], "R": ["VineR1", "VineR2", "VineR3", "VineR4"],
		"T": ["VineT1", "VineT2", "VineT3", "VineT4"]}, "degrees": 16.0, "shrink": 0.82, "sleeps": false, "heads": {}},
}
## A part's own rig: no model, targeted where the server holds it.
const PART_RIG := "boss_part"
## The egg sacs' and cocoons' rig, and how long its split-open slump takes.
const WEB_RIG := "web_object"
const SPLIT_SWELL := 0.08
const SPLIT_SLUMP := 0.42
## The sleep haze off a sleeping head.
const SLEEP_TINT := Color(0.78, 0.8, 1.0)
## The corpse lies this long after its death clip ends (a clip-less body:
## DISSOLVE_NO_CLIP after it fell), then burns away over DISSOLVE_SECONDS; a
## clip is waited for at most DEATH_CLIP_MAX.
const DISSOLVE_HOLD := 0.3
const DISSOLVE_NO_CLIP := 0.5
const DISSOLVE_SECONDS := 1.6
const DEATH_CLIP_MAX := 3.6
const DISSOLVE_SHADER := preload("res://assets/shaders/creature_dissolve.gdshader")
## A blow's flinch (`flinch`): the body jolts away from the blow and springs
## back through a small overshoot (a damped swing, FLINCH_PUSH metres at
## strength 1, gone in ~0.3 s); a heavy blow (a combo's finisher, a critical
## hit) also shakes it from side to side and holds its clip a few frames. It
## never stops what the creature does: no clip changes, no hold.
const FLINCH_PUSH := 0.16
const FLINCH_DAMP := 12.0
const FLINCH_SWING := 26.0
const FLINCH_SECONDS := 0.32
const SHAKE_PUSH := 0.05
const SHAKE_RATE := 62.0
const HITSTOP_SECONDS := 0.055
## Heavy bodies give less (a boss barely rocks, a troll a little).
const FLINCH_BOSS := 0.3
## The struck surface's hot rim (hit_flash.gdshader), fading over this long.
const FLASH_SECONDS := 0.16
const FLASH_SHADER := preload("res://assets/shaders/hit_flash.gdshader")
const EMBER_TINT := Color(1.0, 0.42, 0.1)

static var _views := {}
## The burning look of a surface without a material (each imported material
## keeps its own: dissolve_material); how far each body has burnt is its own
## (an instance uniform), so one look serves every body that falls.
static var _plain_dissolve: ShaderMaterial = null

var species := ""
var view := {}
var model: Node3D
var anim_player: AnimationPlayer
var facing := 0.0
var _speed := 0.0
var _moving := false
var _last := Vector3.ZERO
var _has_last := false
var _attack_phase := ""
## Read by StatusFX: the drawn meshes, the head's height over the feet and
## whether the body died.
var visuals: Node3D
var head_height := 0.0
var is_dead := false
## The replicated status bits (StatusFX.STATUS_*).
var status := 0
## The clip pace the replicated state asks for, and the status pace over it
## (StatusFX: 0 frozen, the slowed pace, 1).
var _anim_speed := 1.0
var _cc_pace := 1.0
## The stun on the hit clip: "" none, "recoil" playing in, "held" at STUN_HOLD.
var _stun_phase := ""
## The snapshot kind rolled elite, is a boss, is enraged (the target card
## reads these).
var elite := false
var is_boss := false
var enraged := false
## The body's own scale (the boss body's `boss_scale`), before boss_overrides.
var _body_scale := 1.0
## Where a blow lands on the body's side (CombatView), from its middle.
var body_radius := 0.45
## The telegraphed ability playing: {clip, release_at, recovery_at, phase} in
## seconds of Time.get_ticks_msec (empty: none).
var _ability := {}
## A multi-part boss: its MULTIPART entry (empty: not one), its parts as the
## server named them (part entity -> key L / M / R / T) and the keys down.
var multipart := {}
var parts: Dictionary = {}
var parts_down: Array = []
var _droop: PartDroop = null
var _skeleton: Skeleton3D = null
## Threehead asleep: the haze over each standing head (key -> GPUParticles3D).
var asleep := false
var _haze: Dictionary = {}
## Seen standing before it died (a web thing already dead when it came into
## view does not burst again), and whether it split open.
var _seen_alive := false
## The replicated state this frame (STATE_*; -1 before the first) and how many
## times the body went into an attack: WorldAudio voices both.
var state := -1
var attack_starts := 0
var split_open := false
## The burn: when it starts (seconds of Time.get_ticks_msec; -1: none
## planned), how far it is (0..1, -1 before it starts), the surfaces it took
## over [mesh, surface, override before], the overlays it lifted [mesh,
## overlay], its embers, and whether main.gd let go of the body.
var _burn_at := -1.0
var _burn := -1.0
var _burnt: Array = []
var _lifted_overlays: Array = []
var _embers: GPUParticles3D = null
var _lingering := false
static var _flash_material: ShaderMaterial = null
var _flinch_dir := Vector3.ZERO
var _flinch_push := 0.0
var _flinch_shake := 0.0
var _flinch_t := FLINCH_SECONDS
var _model_rest := Vector3.ZERO
var _hitstop_until := 0.0
var _flashed: Array = []
var _flash_t := FLASH_SECONDS

## The rig a species is drawn with (creature_views.json `rig`, "" none).
static func rig_of(id: String) -> String:
	return String(view_of(id).get("rig", ""))

static func is_part_kind(kind: int) -> bool:
	return rig_of(species_for_kind(kind)) == PART_RIG

## The species of a snapshot creature kind, in the server's own order (the
## mobs, then the Dark Shard bodies and the training dummy); "" when unknown.
static func species_for_kind(kind: int) -> String:
	return String(RealmContent.species_of_kind(kind))

## The view entry a creature kind is drawn from (creature_views.json); an entry
## with "object" (stone, dummy) is drawn by its own view, not this one.
static func view_for_kind(kind: int) -> Dictionary:
	return view_of(species_for_kind(kind))

static func view_of(id: String) -> Dictionary:
	if _views.is_empty():
		var loaded: Variant = RealmContent.table("creature_views")
		if loaded is Dictionary:
			_views = loaded
	return _views.get(id, {})

## False when the species has no model in this client yet. A boss (BOSS_BIT)
## wears its species' authored boss body (`boss_model` at `boss_scale`), not a
## scaled-up ordinary one; its boss_overrides entry (apply_info) sizes it.
func setup(kind: int) -> bool:
	species = species_for_kind(kind)
	elite = is_elite(kind)
	is_boss = kind & BOSS_BIT != 0
	enraged = kind & ENRAGED_BIT != 0
	view = view_of(species).duplicate()
	var path := String(view.get("boss_model", "")) if is_boss else ""
	if path == "" or not ResourceLoader.exists(path):
		path = String(view.get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		return false
	var scene := load(path) as PackedScene
	if scene == null:
		return false
	model = scene.instantiate() as Node3D
	_body_scale = float(view.get("boss_scale", 1.0)) if is_boss else float(view.get("scale", 1.0))
	model.scale = Vector3.ONE * _body_scale
	var stretch: Variant = view.get("stretch", null)
	if stretch is Array and (stretch as Array).size() >= 3:
		model.scale = Vector3(float(stretch[0]), float(stretch[1]), float(stretch[2])) * _body_scale
	if view.has("silk_alpha"):
		_thin_silk(float(view["silk_alpha"]))
	model.position.y = float(view.get("offset_y", 0.0)) + float(view.get("hover_height", 0.0))
	_model_rest = model.position
	# the character fill (DayNight) lights the character layer: the meshes
	# join it before they enter the world (HeroAppearance.set_character_layer)
	HeroAppearance.set_character_layer(model)
	add_child(model)
	visuals = model
	# the name label's height (creature_views.json) sits just over the head
	head_height = maxf(0.0, float(view.get("label_height", 0.0)) * (_body_scale if is_boss else 1.0) - 0.45)
	var found := model.find_child("AnimationPlayer", true, false)
	anim_player = found as AnimationPlayer
	if anim_player != null:
		for clip in ["Idle", "Walk", "Run", "Float", "Stun", "Sleep"]:
			if anim_player.has_animation(clip):
				anim_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_play("idle")
	multipart = MULTIPART.get(String(view.get("rig", "")), {})
	if not multipart.is_empty():
		_build_droop()
	# only a sleeping head's haze follows the model
	set_process(false)
	return true

## The part chains' modifier on the model's skeleton.
func _build_droop() -> void:
	for found in model.find_children("*", "Skeleton3D", true, false):
		_skeleton = found as Skeleton3D
		break
	if _skeleton == null:
		return
	_droop = PartDroop.new()
	_droop.name = "PartDroop"
	_droop.chains = multipart["chains"]
	_droop.bend_degrees = float(multipart["degrees"])
	_droop.shrink = float(multipart["shrink"])
	_skeleton.add_child(_droop)

## The model drawn as thin silk: its materials see-through to `alpha`.
func _thin_silk(alpha: float) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		for i in mesh.get_surface_override_material_count():
			var source := mesh.get_active_material(i) as BaseMaterial3D
			if source == null:
				continue
			var silk := source.duplicate() as BaseMaterial3D
			silk.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			silk.albedo_color.a = alpha
			mesh.set_surface_override_material(i, silk)

## A web thing dies: the silk bursts (SilkBurst) and the model swells, then
## slumps flat and wide into the floor and is hidden.
func _split_open() -> void:
	if split_open or model == null:
		return
	split_open = true
	if not _seen_alive or DisplayServer.get_name() == "headless":
		model.visible = false
		return
	var rest := model.scale
	var box := AABB()
	var first := true
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var b := mesh.transform * mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var size := Vector2(maxf(box.size.x * rest.x, box.size.z * rest.z), box.size.y * rest.y)
	var fluid := Color(0, 0, 0, 0)
	var tint: Variant = view.get("fluid", null)
	if tint is Array and (tint as Array).size() >= 3:
		fluid = Color(float(tint[0]), float(tint[1]), float(tint[2]))
	SilkBurst.play(get_parent(), global_position, size, fluid)
	var tween := create_tween()
	tween.tween_property(model, "scale", rest * Vector3(1.08, 1.1, 1.08), SPLIT_SWELL)
	tween.tween_property(model, "scale", rest * Vector3(1.3, 0.04, 1.3), SPLIT_SLUMP) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(model, "visible", false, 0.0)

## Which parts are down (keys L / M / R / T): their chains bend on the model,
## a sleeping head that went down stops breathing its haze.
func set_parts_down(keys: Array) -> void:
	if keys == parts_down:
		return
	parts_down = keys.duplicate()
	if _droop != null:
		_droop.down = parts_down
	_update_haze()

## How far part `key` has slumped on the model (0..1; the check reads it).
func part_sag(key: String) -> float:
	return _droop.sag(key) if _droop != null else 0.0

static func is_elite(kind: int) -> bool:
	return kind & ELITE_BIT != 0

## What the server said this creature is (RealmSession.take_creature_info):
## a boss takes its boss_overrides entry - the whole body scaled by `scale`
## (on top of the boss body's own), the label (and so the status looks over
## the head) at `label_y`, and the ground speed its walk cycle is played for.
func apply_info(info: Dictionary) -> void:
	if info.get("parts") is Array:
		parts.clear()
		for p: Variant in info["parts"]:
			if p is Dictionary:
				parts[int(p.get("entity", 0))] = String(p.get("name", ""))
	var key := String(info.get("boss_key", ""))
	if key == "" or model == null:
		return
	var tables: Variant = RealmContent.table("spawn_tables")
	var data: Dictionary = (tables as Dictionary).get("boss_overrides", {}).get(key, {}) if tables is Dictionary else {}
	if data.is_empty():
		return
	var size := float(data.get("scale", 1.0))
	model.scale = Vector3.ONE * _body_scale * size
	if data.has("label_y"):
		head_height = maxf(0.0, float(data["label_y"]) * size - 0.45)
	if data.has("walk_speed"):
		view["walk_speed"] = float(data["walk_speed"])
	# A status look already on the body was fitted to its old size.
	var fx := get_node_or_null("StatusFX")
	if fx != null:
		remove_child(fx)
		fx.queue_free()
		StatusFX.update(self, status)

## The kind's marks can change while the body lives (a commander enrages when a
## pack mate falls); only the enrage is read here.
func set_kind(kind: int) -> void:
	enraged = kind & ENRAGED_BIT != 0

## The replicated status (main.gd hands it over when it changes): the look on
## the body, and through set_cc_anim_scale the pace of its clips.
func set_status(bits: int) -> void:
	if bits == status:
		return
	status = bits
	if bool(multipart.get("sleeps", false)):
		# Threehead's stun is the chime's sleep: its own look, not stars.
		StatusFX.update(self, bits & ~StatusFX.STATUS_STUN)
		_set_asleep(bits & StatusFX.STATUS_STUN != 0)
		return
	StatusFX.update(self, bits)

func _set_asleep(on: bool) -> void:
	if on == asleep:
		return
	asleep = on
	_update_haze()

## A haze of slow pale motes drifting up off every standing head while it
## sleeps; it thins out as it wakes or the head goes down.
func _update_haze() -> void:
	var heads: Dictionary = multipart.get("heads", {})
	for key: String in heads.keys():
		var wanted := asleep and not is_dead and not parts_down.has(key)
		var haze: GPUParticles3D = _haze.get(key)
		if wanted and haze == null and _skeleton != null and DisplayServer.get_name() != "headless":
			haze = RisingMotes.make(0.7, 4.0, SLEEP_TINT, 26, 3.2, Vector2(0.25, 0.75), Vector2(0.045, 0.1))
			haze.name = "SleepHaze" + key
			RisingMotes.set_rate(haze, 0.8)
			add_child(haze)
			_haze[key] = haze
		if haze != null:
			haze.emitting = wanted
	set_process(not _haze.is_empty() or _burn_at >= 0.0)

func _process(delta: float) -> void:
	if _flinch_t < FLINCH_SECONDS or _flash_t < FLASH_SECONDS or _hitstop_until > 0.0:
		_tick_flinch(delta)
	if _burn_at >= 0.0:
		_tick_burn()
	if _skeleton == null or _haze.is_empty():
		return
	var heads: Dictionary = multipart.get("heads", {})
	for key: String in _haze.keys():
		var idx := _skeleton.find_bone(String(heads[key]))
		if idx >= 0:
			(_haze[key] as Node3D).global_position = _skeleton.global_transform * _skeleton.get_bone_global_pose(idx).origin

## StatusFX: hold the pose (0, frozen) or play at the slowed pace.
func set_cc_anim_scale(pace: float) -> void:
	_cc_pace = pace
	_apply_speed()

func drive(drawn: Vector3, yaw: float, state: int, delta: float) -> void:
	if state == STATE_ATTACKING and self.state != STATE_ATTACKING:
		attack_starts += 1
	self.state = state
	if _has_last and delta > 0.0:
		var seen := Vector2(drawn.x - _last.x, drawn.z - _last.z).length() / delta
		_speed = lerpf(_speed, seen, minf(1.0, delta * 8.0))
	_last = drawn
	_has_last = true
	_moving = _speed > (MOVING_OFF if _moving else MOVING_ON)
	position = drawn
	if state == STATE_DEAD:
		if not is_dead:
			is_dead = true
			_stun_phase = ""
			_ability.clear()
			_play("death", 0.1)
			_update_haze()
			if String(view.get("rig", "")) == WEB_RIG:
				_split_open()
			else:
				_plan_burn()
		return
	if is_dead:
		_unburn()
	is_dead = false
	_seen_alive = true
	if _cc_pace <= 0.0:
		# frozen solid: the pose and the facing it was caught in are held
		return
	# Snapshot yaw 0 looks along -Z; the models look along +Z.
	facing = rotate_toward(facing, yaw + PI, TURN_RATE * delta)
	rotation.y = facing
	if status & (StatusFX.STATUS_STUN | StatusFX.STATUS_KNOCKED):
		_ability.clear()
		_play_stunned()
		return
	_stun_phase = ""
	if _play_ability():
		return
	if state == STATE_ATTACKING:
		_play_attack()
		return
	_attack_phase = ""
	if _moving:
		var run := float(view.get("run_speed", 0.0))
		var walk := float(view.get("walk_speed", 0.0))
		# The walk carries a chase up to 3.2x its own pace and below half the
		# run's; past that the run cycle plays (a troll sprint is authored at
		# ~10 m/s, and run at its 0.4x floor slid the feet).
		var walk_carries := walk > 0.0 and _speed <= walk * 3.2 and _speed < run * 0.5
		var slot := "run" if run > 0.0 and not walk_carries else "walk"
		var authored := run if slot == "run" else walk
		_play(slot, 0.18, clampf(_speed / authored, 0.4, 3.0) if authored > 0.0 else 1.0)
	else:
		_play("idle")

## Stunned or thrown: a body with a stun clip of its own loops it; one without
## plays its hit clip into the recoil and holds it there.
func _play_stunned() -> void:
	if anim_player == null:
		return
	_attack_phase = ""
	var clip := _clip("stun")
	var looping := anim_player.get_animation(clip).loop_mode != Animation.LOOP_NONE
	if looping:
		_stun_phase = ""
		_play("stun", 0.12)
		return
	if _stun_phase == "":
		_stun_phase = "recoil"
		_play("stun", 0.08)
	elif _stun_phase == "recoil" and anim_player.current_animation_position 			>= anim_player.get_animation(clip).length * STUN_HOLD:
		_stun_phase = "held"
		_anim_speed = 0.0
		_apply_speed()

## A telegraphed ability begins: `clip` is the ability's clip slot ("Slam" ->
## Slam_Anticipation / Slam_Attack), the strike lands `release_in` seconds
## from now and the recovery ends `recovery_in` seconds from now.
func begin_ability(clip: String, release_in: float, recovery_in: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_ability = {"clip": clip, "start": now, "release_at": now + maxf(0.05, release_in),
		"recovery_at": now + maxf(release_in + 0.1, recovery_in), "phase": ""}

## The server called the ability off before its release.
func cancel_ability() -> void:
	if not _ability.is_empty() and float(_ability["release_at"]) > Time.get_ticks_msec() / 1000.0:
		_ability.clear()
		_attack_phase = ""

## The windup plays until the release, stretched over the time left to it; the
## strike plays from the release over the recovery (only ever sped up). A body
## without the ability's pair plays its own attack slots. False when no
## ability is playing.
func _play_ability() -> bool:
	if _ability.is_empty() or anim_player == null:
		return false
	var now := Time.get_ticks_msec() / 1000.0
	var release_at := float(_ability["release_at"])
	var recovery_at := float(_ability["recovery_at"])
	if now >= recovery_at:
		_ability.clear()
		# the plain swing cycle picks up from a finished strike
		_attack_phase = "attack"
		return false
	var phase := "anticipation" if now < release_at else "attack"
	if phase == String(_ability["phase"]):
		return true
	_ability["phase"] = phase
	_attack_phase = phase
	# A body with one clip for the move (the troll's Stomp, Roar): its first
	# SINGLE_STRIKE over the windup, the rest over the recovery.
	var base := String(_ability["clip"])
	if not anim_player.has_animation(base + "_Anticipation") and anim_player.has_animation(base):
		var length := anim_player.get_animation(base).length
		if phase == "anticipation":
			_anim_speed = clampf(length * SINGLE_STRIKE / maxf(0.05, release_at - now), 0.5, 3.0)
			anim_player.play(base, 0.08)
		else:
			_anim_speed = clampf(length * (1.0 - SINGLE_STRIKE) / maxf(0.05, recovery_at - release_at), 1.0, 3.0)
			if anim_player.current_animation != base:
				anim_player.play(base, 0.06)
				anim_player.seek(length * SINGLE_STRIKE, true)
		_apply_speed()
		return true
	var clip := "%s_%s" % [base, "Anticipation" if phase == "anticipation" else "Attack"]
	if not anim_player.has_animation(clip):
		clip = _clip(phase)
	var span := (release_at - now) if phase == "anticipation" else (recovery_at - release_at)
	var speed := clampf(anim_player.get_animation(clip).length / maxf(0.05, span), 0.5, 3.0)
	if phase == "attack":
		speed = maxf(1.0, speed)   # a follow-through only ever speeds up
	_anim_speed = speed
	anim_player.play(clip, 0.08 if phase == "anticipation" else 0.06)
	_apply_speed()
	return true

## Where the body's right hand is in the world (what it throws leaves from);
## over the head when the rig has no hand.
func hand_position() -> Vector3:
	if model != null:
		for found in model.find_children("*", "Skeleton3D", true, false):
			var skeleton := found as Skeleton3D
			var bone := skeleton.find_bone("RightHand")
			if bone >= 0:
				return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
	return global_position + Vector3.UP * maxf(1.5, head_height + 0.4)

## An attack is anticipation then the strike, repeated while the state holds.
func _play_attack() -> void:
	if anim_player == null:
		return
	if _attack_phase == "" or not anim_player.is_playing():
		_attack_phase = "attack" if _attack_phase == "anticipation" else "anticipation"
		_play(_attack_phase, 0.08)

func _clip(slot: String) -> String:
	var table: Dictionary = ANIM_SETS.get(String(view.get("anim_set", "generic")), ANIM_SETS["generic"])
	var clip := String(table.get(slot, "Idle"))
	if anim_player != null and not anim_player.has_animation(clip):
		clip = "Idle"
	return clip

func _play(slot: String, blend := 0.18, speed := 1.0) -> void:
	if anim_player == null:
		return
	var clip := _clip(slot)
	if not anim_player.has_animation(clip):
		return
	_anim_speed = speed
	if anim_player.current_animation == clip and anim_player.is_playing():
		_apply_speed()
		return
	anim_player.play(clip, blend)
	_apply_speed()

func _apply_speed() -> void:
	if anim_player != null:
		# the corpse falls at the normal pace, frozen or not; a heavy blow
		# holds the clip a few frames
		var held := _hitstop_until > Time.get_ticks_msec() / 1000.0 and not is_dead
		anim_player.speed_scale = 0.0 if held else _anim_speed * (1.0 if is_dead else _cc_pace)

## ------------------------------------------------------------------ the flinch

## A blow landed on the body: `travel` is the way the blow was going (world),
## `strength` how hard it jolts (1 = a plain bolt), `shake` how much it
## shakes from side to side (0 = none; a combo's finisher ~1).
func flinch(travel: Vector3, strength: float, shake := 0.0) -> void:
	if is_dead or model == null or not is_inside_tree():
		return
	var flat := Vector3(travel.x, 0.0, travel.z)
	if flat.length_squared() < 0.0001:
		flat = -global_transform.basis.z
	var weight := FLINCH_BOSS if is_boss else (0.6 if body_radius > 1.0 else 1.0)
	# the way in the body's own frame (it turns with its facing)
	_flinch_dir = (global_transform.basis.inverse() * flat.normalized()).normalized()
	_flinch_push = maxf(_flinch_push * (1.0 - _flinch_t / FLINCH_SECONDS), strength * weight)
	_flinch_shake = maxf(_flinch_shake * (1.0 - _flinch_t / FLINCH_SECONDS), shake * weight)
	_flinch_t = 0.0
	if shake > 0.0:
		_hitstop_until = Time.get_ticks_msec() / 1000.0 + HITSTOP_SECONDS * minf(shake, 1.5)
		_apply_speed()
	_flash(minf(1.0, 0.55 + 0.3 * strength))
	set_process(true)

func _tick_flinch(delta: float) -> void:
	if _hitstop_until > 0.0 and Time.get_ticks_msec() / 1000.0 >= _hitstop_until:
		_hitstop_until = 0.0
		_apply_speed()
	if _flinch_t < FLINCH_SECONDS:
		_flinch_t = minf(FLINCH_SECONDS, _flinch_t + delta)
		var t := _flinch_t
		var fade := exp(-FLINCH_DAMP * t)
		var swing := fade * sin(FLINCH_SWING * t) * 1.6 * FLINCH_PUSH * _flinch_push
		var side := Vector3(-_flinch_dir.z, 0.0, _flinch_dir.x)
		var jitter := exp(-10.0 * t) * sin(SHAKE_RATE * t) * SHAKE_PUSH * _flinch_shake
		var done := _flinch_t >= FLINCH_SECONDS
		model.position = _model_rest if done else _model_rest + _flinch_dir * swing + side * jitter \
			+ Vector3.UP * absf(jitter) * 0.35
		if done:
			_flinch_push = 0.0
			_flinch_shake = 0.0
	if _flash_t < FLASH_SECONDS:
		_flash_t = minf(FLASH_SECONDS, _flash_t + delta)
		var left := 1.0 - _flash_t / FLASH_SECONDS
		for entry: Array in _flashed:
			var mesh := entry[0] as GeometryInstance3D
			if is_instance_valid(mesh):
				mesh.set_instance_shader_parameter("hit_flash", float(entry[1]) * left * left)
		if _flash_t >= FLASH_SECONDS:
			_end_flash()
	if _flinch_t >= FLINCH_SECONDS and _flash_t >= FLASH_SECONDS and _hitstop_until <= 0.0:
		set_process(not _haze.is_empty() or _burn_at >= 0.0)

## The hot rim over every surface that wears no other overlay (a status look
## keeps its own).
func _flash(amount: float) -> void:
	if DisplayServer.get_name() == "headless" or _burn >= 0.0:
		return
	if _flash_material == null:
		_flash_material = ShaderMaterial.new()
		_flash_material.shader = FLASH_SHADER
	if _flashed.is_empty():
		for node in model.find_children("*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			if mesh.visible and mesh.mesh != null and mesh.material_overlay == null:
				mesh.material_overlay = _flash_material
				_flashed.append([mesh, amount])
	else:
		for entry: Array in _flashed:
			entry[1] = maxf(float(entry[1]) * (1.0 - _flash_t / FLASH_SECONDS), amount)
	_flash_t = 0.0

func _end_flash() -> void:
	for entry: Array in _flashed:
		var mesh := entry[0] as GeometryInstance3D
		if is_instance_valid(mesh) and mesh.material_overlay == _flash_material:
			mesh.material_overlay = null
	_flashed.clear()

# ------------------------------------------------------------------ the burn

## The body fell: it burns once its death clip has played out (a body already
## dead when it came into view lies in the clip's last pose and burns now).
func _plan_burn() -> void:
	if model == null or DisplayServer.get_name() == "headless":
		return
	var wait := DISSOLVE_NO_CLIP
	var clip_name := _clip("death")
	if anim_player != null and clip_name != "Idle" and anim_player.has_animation(clip_name):
		var clip := anim_player.get_animation(clip_name)
		if clip.loop_mode == Animation.LOOP_NONE:
			if not _seen_alive:
				anim_player.seek(clip.length, true)
				wait = 0.0
			else:
				wait = minf(clip.length, DEATH_CLIP_MAX) + DISSOLVE_HOLD
	_burn_at = Time.get_ticks_msec() / 1000.0 + wait
	_burn = -1.0
	set_process(true)

## main.gd: the snapshot no longer carries this body. A corpse that has not
## burnt out yet stays to finish and frees itself (true); false: free it now.
func linger() -> bool:
	if not is_dead or _burn_at < 0.0 or model == null or not model.visible or not is_inside_tree():
		return false
	_lingering = true
	return true

func _tick_burn() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _burn_at:
		return
	if _burn < 0.0:
		_start_burn()
	_burn = clampf((now - _burn_at) / DISSOLVE_SECONDS, 0.0, 1.0)
	var done := {}
	for entry: Array in _burnt:
		var mesh := entry[0] as GeometryInstance3D
		if is_instance_valid(mesh) and not done.has(mesh):
			done[mesh] = true
			mesh.set_instance_shader_parameter("dissolve", _burn)
	if _embers != null and is_instance_valid(_embers):
		# thick while the front sweeps the body, thinning as little is left
		RisingMotes.set_rate(_embers, clampf(1.0 - _burn * _burn, 0.15, 1.0))
		_embers.emitting = _burn < 0.92
	if _burn >= 1.0:
		_burn_at = -1.0
		model.visible = false
		set_process(not _haze.is_empty())
		if _lingering:
			# the last embers rise and fade before the node goes
			var tween := create_tween()
			tween.tween_interval(1.4)
			tween.tween_callback(queue_free)

## Every surface of the body takes its burning look (its own textures and
## values), the overlays (a status look) come off, the embers and the ash
## breath start.
func _start_burn() -> void:
	_end_flash()
	_flash_t = FLASH_SECONDS
	_burn = 0.0
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.visible or mesh.mesh == null:
			continue
		if mesh.material_overlay != null:
			_lifted_overlays.append([mesh, mesh.material_overlay])
			mesh.material_overlay = null
		for i in mesh.get_surface_override_material_count():
			_burnt.append([mesh, i, mesh.get_surface_override_material(i)])
			mesh.set_surface_override_material(i, dissolve_material(mesh.get_active_material(i)))
		mesh.set_instance_shader_parameter("dissolve", 0.0)
	_light_embers()

## Back from the dead (the server stood the body up again in view): its own
## look back, whole.
func _unburn() -> void:
	_burn_at = -1.0
	_burn = -1.0
	for entry: Array in _burnt:
		var mesh := entry[0] as MeshInstance3D
		if is_instance_valid(mesh):
			mesh.set_surface_override_material(int(entry[1]), entry[2])
			mesh.set_instance_shader_parameter("dissolve", 0.0)
	_burnt.clear()
	for entry: Array in _lifted_overlays:
		var mesh := entry[0] as GeometryInstance3D
		if is_instance_valid(mesh) and mesh.material_overlay == null:
			mesh.material_overlay = entry[1]
	_lifted_overlays.clear()
	if _embers != null and is_instance_valid(_embers):
		_embers.queue_free()
	_embers = null
	if model != null and String(view.get("rig", "")) != WEB_RIG:
		model.visible = true
	set_process(not _haze.is_empty())

## Embers rise off the corpse where it lies (its bones' footprint as the death
## clip left it) and a breath of dark ash leaves it.
func _light_embers() -> void:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for found in model.find_children("*", "Skeleton3D", true, false):
		var skeleton := found as Skeleton3D
		for bone in skeleton.get_bone_count():
			var at := skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
			lo = lo.min(at)
			hi = hi.max(at)
	if not is_finite(lo.x) or (hi - lo).length() > 20.0:
		lo = global_position - Vector3(0.4, 0.0, 0.4)
		hi = global_position + Vector3(0.4, 0.6, 0.4)
	var centre := (lo + hi) * 0.5
	var half := Vector2(maxf(0.15, (hi.x - lo.x) * 0.5), maxf(0.15, (hi.z - lo.z) * 0.5))
	var size := clampf(maxf(half.x, half.y) * 2.0, 0.6, 4.0)
	_embers = RisingMotes.make(maxf(half.x, half.y), 4.0, EMBER_TINT, int(clampf(size * 22.0, 18.0, 60.0)), 1.3,
		Vector2(0.3, 1.1), Vector2(0.01, 0.026))
	_embers.name = "BurnEmbers"
	RisingMotes.set_band(_embers, half)
	add_child(_embers)
	_embers.global_position = Vector3(centre.x, lo.y + (hi.y - lo.y) * 0.35, centre.z)
	_embers.emitting = true
	FlipbookFX.play(get_parent(), Vector3(centre.x, lo.y + 0.1, centre.z), [
		{"atlas": "smoke_puff_8x8_1k", "size": size * 1.3, "height": size * 0.35, "fps": 20.0,
			"tint": Color(0.16, 0.13, 0.12), "opacity": 0.32},
	], {"life": 2.6, "name": "BurnAsh"})

## The burning look of `source` (one per imported material, kept on it as
## metadata, so it goes when the model's materials go - a map's creatures
## are let go on the next trip): its textures and values copied into
## creature_dissolve.gdshader.
static func dissolve_material(source: Material) -> ShaderMaterial:
	if source == null:
		if _plain_dissolve == null:
			_plain_dissolve = ShaderMaterial.new()
			_plain_dissolve.shader = DISSOLVE_SHADER
		return _plain_dissolve
	if source.has_meta(&"dissolve"):
		return source.get_meta(&"dissolve")
	var burning := ShaderMaterial.new()
	burning.shader = DISSOLVE_SHADER
	if source is BaseMaterial3D:
		var base := source as BaseMaterial3D
		burning.set_shader_parameter("albedo", base.albedo_color)
		burning.set_shader_parameter("albedo_tex", base.albedo_texture)
		if base.normal_enabled:
			burning.set_shader_parameter("normal_tex", base.normal_texture)
			burning.set_shader_parameter("normal_scale", base.normal_scale)
		burning.set_shader_parameter("roughness", base.roughness)
		# the import gives both the same packed map (or neither)
		if base.roughness_texture != null:
			burning.set_shader_parameter("orm_tex", base.roughness_texture)
			burning.set_shader_parameter("roughness_channel", _channel(base.roughness_texture_channel))
		burning.set_shader_parameter("metallic", base.metallic)
		if base.metallic_texture != null:
			burning.set_shader_parameter("metallic_channel", _channel(base.metallic_texture_channel))
		else:
			burning.set_shader_parameter("metallic_channel", Vector4(1, 0, 0, 0))
		burning.set_shader_parameter("specular", base.metallic_specular)
		if base.emission_enabled:
			burning.set_shader_parameter("emission", base.emission)
			burning.set_shader_parameter("emission_energy", base.emission_energy_multiplier)
			if base.emission_texture != null:
				burning.set_shader_parameter("emission_tex", base.emission_texture)
		burning.set_shader_parameter("uv1_scale", base.uv1_scale)
		burning.set_shader_parameter("uv1_offset", base.uv1_offset)
	source.set_meta(&"dissolve", burning)
	return burning

static func _channel(channel: int) -> Vector4:
	match channel:
		BaseMaterial3D.TEXTURE_CHANNEL_GREEN:
			return Vector4(0, 1, 0, 0)
		BaseMaterial3D.TEXTURE_CHANNEL_BLUE:
			return Vector4(0, 0, 1, 0)
		BaseMaterial3D.TEXTURE_CHANNEL_ALPHA:
			return Vector4(0, 0, 0, 1)
		BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE:
			return Vector4(0.333, 0.333, 0.333, 0)
	return Vector4(1, 0, 0, 0)

## ShaderWarmup: the burning look drawn once (part burnt) on this body, so its
## pipeline compiles behind the loading screen.
func warm_burn() -> void:
	if model == null:
		return
	_start_burn()
	for entry: Array in _burnt:
		(entry[0] as GeometryInstance3D).set_instance_shader_parameter("dissolve", 0.45)
