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
## A stun played on the hit clip (no stun clip of its own) holds the recoil
## this far into it, the body reeling, for as long as the stun lasts.
const STUN_HOLD := 0.4
## A snapshot creature kind is its species index + 1, with this bit set for an
## elite (a stronger copy of the same species).
const ELITE_BIT := 0x8000
const SPECIES_MASK := 0x7FFF

static var _views := {}
static var _species := []

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
## The snapshot kind rolled elite.
var elite := false
## The telegraphed ability playing: {clip, release_at, recovery_at, phase} in
## seconds of Time.get_ticks_msec (empty: none).
var _ability := {}

## Species ids in the server's order: a snapshot's creature kind is its index
## here plus one (realm_server game.rs sorts species by id).
static func species_for_kind(kind: int) -> String:
	kind &= SPECIES_MASK
	if _species.is_empty():
		var mobs: Variant = RealmContent.table("mobs")
		if mobs is Dictionary:
			for id: String in (mobs as Dictionary).get("mobs", {}):
				if not id.begins_with("_"):
					_species.append(id)
			_species.sort()
	return String(_species[kind - 1]) if kind >= 1 and kind <= _species.size() else ""

static func view_of(id: String) -> Dictionary:
	if _views.is_empty():
		var loaded: Variant = RealmContent.table("creature_views")
		if loaded is Dictionary:
			_views = loaded
	return _views.get(id, {})

## False when the species has no model in this client yet.
func setup(kind: int) -> bool:
	species = species_for_kind(kind)
	elite = is_elite(kind)
	view = view_of(species)
	var path := String(view.get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		return false
	var scene := load(path) as PackedScene
	if scene == null:
		return false
	model = scene.instantiate() as Node3D
	model.scale = Vector3.ONE * float(view.get("scale", 1.0))
	model.position.y = float(view.get("offset_y", 0.0)) + float(view.get("hover_height", 0.0))
	add_child(model)
	visuals = model
	# the name label's height (creature_views.json) sits just over the head
	head_height = maxf(0.0, float(view.get("label_height", 0.0)) - 0.45)
	var found := model.find_child("AnimationPlayer", true, false)
	anim_player = found as AnimationPlayer
	if anim_player != null:
		for clip in ["Idle", "Walk", "Run", "Float", "Stun", "Sleep"]:
			if anim_player.has_animation(clip):
				anim_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_play("idle")
	return true

static func is_elite(kind: int) -> bool:
	return kind & ELITE_BIT != 0

## The replicated status (main.gd hands it over when it changes): the look on
## the body, and through set_cc_anim_scale the pace of its clips.
func set_status(bits: int) -> void:
	if bits == status:
		return
	status = bits
	StatusFX.update(self, bits)

## StatusFX: hold the pose (0, frozen) or play at the slowed pace.
func set_cc_anim_scale(pace: float) -> void:
	_cc_pace = pace
	_apply_speed()

func drive(drawn: Vector3, yaw: float, state: int, delta: float) -> void:
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
		return
	is_dead = false
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
	var clip := "%s_%s" % [_ability["clip"], "Anticipation" if phase == "anticipation" else "Attack"]
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
		# the corpse falls at the normal pace, frozen or not
		anim_player.speed_scale = _anim_speed * (1.0 if is_dead else _cc_pace)
