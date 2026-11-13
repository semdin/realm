extends Node3D
class_name CreatureView

## One creature drawn from interpolated snapshots: its model and clips come from
## content/data/creature_views.json, the clip it plays from the replicated state
## (idle, moving, attacking, dead) and the speed it is seen to cover. It decides
## nothing.

## Snapshot states (realm_server sim.rs).
const STATE_IDLE := 0
const STATE_MOVING := 1
const STATE_ATTACKING := 2
const STATE_DEAD := 3

## Which clip plays for each slot, per animation set; a clip the body lacks
## falls back to Idle.
const ANIM_SETS := {
	"spider": {"idle": "Idle", "walk": "Walk", "run": "Walk",
		"anticipation": "Bite_Anticipation", "attack": "Bite_Attack", "hit": "Hit", "death": "Death"},
	"troll": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "death": "Death"},
	"caster": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Charge2_Anticipation", "attack": "Charge2_Attack", "hit": "Hit", "death": "Death"},
	"undead": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "death": "Death"},
	"goblin": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "death": "Death"},
	"goblin_caster": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Cast_Anticipation", "attack": "Cast_Attack", "hit": "Hit", "death": "Death"},
	"wraith": {"idle": "Idle", "walk": "Float", "run": "Float",
		"anticipation": "Reach_Anticipation", "attack": "Reach_Attack", "hit": "Hit", "death": "Death"},
	"hound": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Bite_Anticipation", "attack": "Bite_Attack", "hit": "Hit", "death": "Death"},
	"snare": {"idle": "Idle", "walk": "Idle", "run": "Idle",
		"anticipation": "Lash_Anticipation", "attack": "Lash_Attack", "hit": "Hit", "death": "Death"},
	"knight": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "death": "Death"},
	"pixie": {"idle": "Idle", "walk": "Idle", "run": "Idle",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit", "death": "Death"},
	"generic": {"idle": "Idle", "walk": "Walk", "run": "Run",
		"anticipation": "Idle", "attack": "Idle", "hit": "Hit", "death": "Death"},
}

## Seen ground speed (m/s) above which the body counts as moving, with
## hysteresis so a body on the threshold does not flicker.
const MOVING_ON := 0.35
const MOVING_OFF := 0.15
const TURN_RATE := 10.0

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
var _dead := false
var _attack_phase := ""

## Species ids in the server's order: a snapshot's creature kind is its index
## here plus one (realm_server game.rs sorts species by id).
static func species_for_kind(kind: int) -> String:
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
	var found := model.find_child("AnimationPlayer", true, false)
	anim_player = found as AnimationPlayer
	if anim_player != null:
		for clip in ["Idle", "Walk", "Run", "Float"]:
			if anim_player.has_animation(clip):
				anim_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_play("idle")
	return true

func drive(drawn: Vector3, yaw: float, state: int, delta: float) -> void:
	if _has_last and delta > 0.0:
		var seen := Vector2(drawn.x - _last.x, drawn.z - _last.z).length() / delta
		_speed = lerpf(_speed, seen, minf(1.0, delta * 8.0))
	_last = drawn
	_has_last = true
	_moving = _speed > (MOVING_OFF if _moving else MOVING_ON)
	position = drawn
	# Snapshot yaw 0 looks along -Z; the models look along +Z.
	facing = rotate_toward(facing, yaw + PI, TURN_RATE * delta)
	rotation.y = facing
	if state == STATE_DEAD:
		if not _dead:
			_dead = true
			_play("death", 0.1)
		return
	_dead = false
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
	if anim_player.current_animation == clip and anim_player.is_playing():
		anim_player.speed_scale = speed
		return
	anim_player.play(clip, blend)
	anim_player.speed_scale = speed
