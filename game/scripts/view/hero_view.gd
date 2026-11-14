extends Node3D
class_name HeroView

## One hero drawn from what the session reports: the model and its look
## (HeroAppearance), the animation graph (HeroAnimation) and the pose state
## picked from the body's motion. It decides nothing; the body's position,
## velocity and contacts come from the Rust rules (own player) or from
## interpolated snapshots (everyone else). Its replicated status draws on it
## (StatusFX): stunned or frozen it plays the stun loop, thrown the fall loop,
## frozen its pose is held and slowed its clips play at the slowed pace.
## Fallen it lies in the death pose until it rises with the Revive clip.

## A short hop or a step down keeps the light airborne pose; past this long
## in the air, or falling faster than HARD_FALL_SPEED, the body flails.
const LONG_FALL_AIR := 0.8
const HARD_FALL_SPEED := 9.6
## Air time before a lifted foot counts as airborne (terrain creases, slope
## changes and stair edges lift the feet for a tick or two).
const AIR_GRACE := 0.12
## Facing turn rate toward the direction of travel, radians per second.
const TURN_RATE := 14.0
## Below this ground speed the body keeps its facing.
const FACE_MIN_SPEED := 0.6
const DEFAULT_CLOAK := "cloak_wool"
## The upper-body clip each spell casts with (assets/animations/hero, merged by
## HeroAnimation.merge_extra_clips). `release` is the clip fraction where the
## wand hand is furthest forward, `hold` how long the cast layer owns the arm,
## `aim` false for a swing that keeps its own arc. The basic chain is keyed per
## step ("basic_cast:<step>"); Light of Ithrel leaves the wand with Flame
## Wave's thrust and Frost Grip with Shockwave's overhead throw.
const SPELL_CLIPS := {
	"stun_bolt": {"clip": "Cast_Stun_Bolt", "release": 0.226, "hold": 0.72},
	"flame_wave": {"clip": "Cast_Flame_Wave", "release": 0.25, "hold": 0.66, "aim": false},
	"light_of_ithrel": {"clip": "Cast_Flame_Wave", "release": 0.25, "hold": 0.7, "aim": false},
	"shockwave": {"clip": "Cast_Shockwave", "release": 0.182, "hold": 0.7},
	"frost_grip": {"clip": "Cast_Shockwave", "release": 0.182, "hold": 0.7},
	"disarm": {"clip": "Cast_Disarm", "release": 0.128, "hold": 0.6},
	"ward_shield": {"clip": "Cast_Ward_Shield", "release": 0.128, "hold": 0.9, "aim": false},
	"ultimate": {"clip": "Cast_Ultimate", "release": 0.158, "hold": 0.85},
	"basic_cast:0": {"clip": "Cast_Basic1", "release": 0.222, "hold": 0.36},
	"basic_cast:1": {"clip": "Cast_Basic2", "release": 0.231, "hold": 0.4, "aim": false},
	"basic_cast:2": {"clip": "Cast_Basic3", "release": 0.222, "hold": 0.55},
}

var body: Node3D
var anim: HeroAnimation
## Read by the pose layers (CloakDeformer finds its rider by `is_mounted`).
var velocity := Vector3.ZERO
var is_mounted := false
var mounted_speed := 14.0
var is_local_player := false
var facing := 0.0
var _airborne := false
var _peak_fall := 0.0
var _air_time := 0.0
## Remote heroes: motion estimated from successive drawn positions.
var _last_position := Vector3.ZERO
var _has_last := false
var _estimated_velocity := Vector3.ZERO
## A standing caster turns to face what it casts at (radians; NAN = keep).
var _turn_to := NAN
## The replicated status bits (StatusFX.STATUS_*) and the clip pace StatusFX
## sets for them (0 frozen, the slowed pace, 1). Below 1 the animation tree is
## advanced by hand at that pace.
var status := 0
## Fallen (set_dead): the death pose holds until the body rises.
var dead := false
var _cc_pace := 1.0
var _tree_mode := AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE

## The drawn meshes (StatusFX lays its skin looks over them).
var visuals: Node3D:
	get:
		return body

const DEFAULT_WAND := "wand_ashwood"
var _wand_key := ""

## Puts `entry` (an item: id, tier, uid) in the hero's hand; an empty entry
## leaves the hand empty. A no-op when it already holds that piece.
func show_wand(entry: Dictionary) -> void:
	var key := "%s:%d:%d" % [entry.get("id", ""), int(entry.get("tier", 0)), int(entry.get("uid", 0))]
	if body == null or key == _wand_key:
		return
	_wand_key = key
	HeroAppearance.show_equipped_wand(body, entry)

func setup(house_color: Color, look: Dictionary = {}) -> void:
	body = HeroAppearance.spawn(self, house_color)
	if body == null:
		return
	if not look.is_empty():
		HeroAppearance.apply_look(body, look)
	HeroAppearance.show_cloak(body, {"id": DEFAULT_CLOAK})
	# Every hero holds the starter wand until its own gear says otherwise
	# (other players' gear is not replicated yet).
	show_wand({"id": DEFAULT_WAND})
	var player := HeroAppearance.find_anim_player(body)
	var skeleton := HeroAppearance._skeleton(body)
	if player != null and skeleton != null:
		# spawn() starts the idle clip on the player for posed displays; a
		# playing AnimationPlayer would overwrite the graph's pose every frame.
		player.stop()
		anim = HeroAnimation.new()
		anim.name = "HeroAnimation"
		add_child(anim)
		anim.setup(player, skeleton, self)

## The replicated status (main.gd hands it over when it changes).
func set_status(bits: int) -> void:
	if bits == status:
		return
	var held := StatusFX.STATUS_STUN | StatusFX.STATUS_FREEZE | StatusFX.STATUS_KNOCKED
	if bits & held and not status & held and anim != null:
		# a stun or a throw breaks the cast: the arm drops into the stun clip
		anim.end_cast()
	status = bits
	StatusFX.update(self, bits)

## Duel marks (HudDuel sets them on the local player's foes): the foe's name
## over its head, red while it stands, grey once it is beaten; none clears it.
const DUEL_NONE := 0
const DUEL_FOE := 1
const DUEL_OUT := 2
const DUEL_FOE_TINT := Color(1.0, 0.36, 0.30)
const DUEL_OUT_TINT := Color(0.62, 0.58, 0.56)
## Over the crown, fixed size on screen like the NPC plates (a foe across the
## arena still reads).
const DUEL_MARK_HEIGHT := 2.3
const DUEL_MARK_PIXEL := 0.0009
var duel_mark := DUEL_NONE
var _duel_label: Label3D

func set_duel_mark(mark: int, who := "") -> void:
	if who != "" and _duel_label == null:
		_duel_label = Label3D.new()
		_duel_label.name = "DuelMark"
		_duel_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_duel_label.double_sided = false
		_duel_label.fixed_size = true
		_duel_label.pixel_size = DUEL_MARK_PIXEL
		_duel_label.font = HudKit.bold()
		_duel_label.font_size = 34
		_duel_label.outline_size = 10
		_duel_label.outline_modulate = Color(0.04, 0.03, 0.02, 0.88)
		# Over the body, under the damage numbers (FloatingText, priority 0)
		# that rise through it.
		_duel_label.no_depth_test = true
		_duel_label.render_priority = -1
		_duel_label.outline_render_priority = -2
		_duel_label.position.y = DUEL_MARK_HEIGHT
		add_child(_duel_label)
	if _duel_label != null and who != "":
		_duel_label.text = who
	duel_mark = mark
	if _duel_label != null:
		_duel_label.visible = mark != DUEL_NONE
		_duel_label.modulate = DUEL_OUT_TINT if mark == DUEL_OUT else DUEL_FOE_TINT

## Fallen or risen. A fall drops the cast and lies down in Death_A; a rise
## plays Revive over the standing pose.
func set_dead(on: bool) -> void:
	if on == dead:
		return
	dead = on
	if anim == null:
		return
	if on:
		anim.end_cast()
		anim.cancel_oneshot()
		anim.set_locomotion("dead", "Death_A", true)
	else:
		anim.play_oneshot("Revive")
		anim.set_locomotion("idle", "Idle", true)

## StatusFX: hold the pose (0, frozen) or play at the slowed pace.
func set_cc_anim_scale(pace: float) -> void:
	if anim == null or anim.tree == null:
		return
	if _cc_pace >= 1.0 and pace < 1.0:
		_tree_mode = anim.tree.callback_mode_process
		anim.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	elif _cc_pace < 1.0 and pace >= 1.0:
		anim.tree.callback_mode_process = _tree_mode
	_cc_pace = pace

## A cast began: the spell's upper-body clip blends over locomotion, timed so
## the wand's forward snap lands `release_seconds` from now (the server's
## windup), with the casting arm aimed at `aim` (world space). `step` picks the
## basic chain's move (0..2).
func play_cast(spell: String, aim: Vector3, release_seconds: float, step := 0) -> void:
	if anim == null:
		return
	var own: Dictionary = SPELL_CLIPS.get("basic_cast:%d" % clampi(step, 0, 2) if spell == "basic_cast" else spell, {})
	var upper := String(own.get("clip", "Spellcast_Shoot")) + "_Upper"
	var hold := float(own.get("hold", 0.42))
	anim.start_cast(upper, hold)
	anim.align_cast(clampf(release_seconds, 0.01, hold - 0.02), float(own.get("release", 0.45)))
	if bool(own.get("aim", true)):
		anim.set_cast_aim(aim)
	else:
		anim.clear_cast_aim()
	var flat := Vector2(aim.x - position.x, aim.z - position.z)
	if flat.length() > 0.2:
		_turn_to = atan2(flat.x, flat.y)

## The player's own body: everything known exactly.
func drive_own(state: Dictionary, delta: float) -> void:
	var velocity: Vector3 = state.get("velocity", Vector3.ZERO)
	_pose(state.get("position", position), velocity, bool(state.get("on_floor", true)),
		bool(state.get("swimming", false)), float(state.get("air_seconds", 0.0)), delta)

## Another player: only the drawn position is known; motion is estimated.
func drive_remote(drawn: Vector3, delta: float) -> void:
	if _has_last and delta > 0.0:
		var raw := (drawn - _last_position) / delta
		_estimated_velocity = _estimated_velocity.lerp(raw, clampf(delta * 12.0, 0.0, 1.0))
	_last_position = drawn
	_has_last = true
	var v := _estimated_velocity
	var lifted := v.y > 1.0 or v.y < -4.0
	_air_time = _air_time + delta if lifted else 0.0
	_pose(drawn, v, not lifted, false, _air_time, delta)

func _pose(at: Vector3, velocity: Vector3, on_floor: bool, swimming: bool, air_seconds: float, delta: float) -> void:
	position = at
	self.velocity = velocity
	if _cc_pace <= 0.0:
		# frozen solid: the pose and the facing it was caught in are held
		return
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length() > FACE_MIN_SPEED:
		# The model looks along +Z; face the direction of travel.
		var target := atan2(velocity.x, velocity.z)
		facing = rotate_toward(facing, target, TURN_RATE * delta)
		_turn_to = NAN
	elif not is_nan(_turn_to):
		facing = rotate_toward(facing, _turn_to, TURN_RATE * delta)
	rotation.y = facing
	if anim == null:
		return
	anim.tick(delta * _cc_pace)
	if _cc_pace < 1.0 and anim.tree != null and anim.tree.active:
		anim.tree.advance(delta * _cc_pace)
	if dead:
		# lies where it fell (set_dead chose the clip)
		return
	if status & StatusFX.STATUS_KNOCKED:
		anim.set_locomotion("thrown", "Fall_Loop")
		return
	if status & (StatusFX.STATUS_STUN | StatusFX.STATUS_FREEZE):
		anim.set_locomotion("stun", "Stun_Loop")
		return
	if swimming:
		anim.set_locomotion("swim_idle" if flat.length() < 0.5 else "swim", "Idle" if flat.length() < 0.5 else "Running_A")
		return
	var airborne := not on_floor and (velocity.y > 1.0 or (air_seconds >= AIR_GRACE and velocity.y < -0.5))
	if airborne:
		_peak_fall = maxf(_peak_fall, -velocity.y)
		if velocity.y > 0.5:
			anim.set_locomotion("air_up", "Jump_Start")
		elif air_seconds < LONG_FALL_AIR and _peak_fall < HARD_FALL_SPEED:
			anim.set_locomotion("air_hold", "Jump_Air")
		else:
			anim.set_locomotion("air_down", "Fall")
		_airborne = true
		return
	if _airborne:
		_airborne = false
		anim.play_oneshot("Land" if _peak_fall >= HARD_FALL_SPEED else "Land_Soft")
		_peak_fall = 0.0
	# set_ground_motion also hands the locomotion layer back to the ground blend.
	var forward := Vector3(sin(facing), 0.0, cos(facing))
	var left := Vector3(cos(facing), 0.0, -sin(facing))
	var motion := Vector3(velocity.x, 0.0, velocity.z)
	anim.set_ground_motion(Vector2(motion.dot(left), motion.dot(forward)))
