extends Node3D
class_name HeroView

## One hero drawn from what the session reports: the model and its look
## (HeroAppearance), the animation graph (HeroAnimation) and the pose state
## picked from the body's motion. It decides nothing; the body's position,
## velocity and contacts come from the Rust rules (own player) or from
## interpolated snapshots (everyone else).

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

func setup(house_color: Color, look: Dictionary = {}) -> void:
	body = HeroAppearance.spawn(self, house_color)
	if body == null:
		return
	if not look.is_empty():
		HeroAppearance.apply_look(body, look)
	HeroAppearance.show_cloak(body, {"id": DEFAULT_CLOAK})
	HeroAppearance.show_equipped_wand(body, {})
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
	anim.tick(delta)
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
