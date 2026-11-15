extends Node3D

## The broom's wake: smoke shed at the bristle tip into world space, so it
## streams out along the flight path, lags behind a turn and hangs where it
## was left, drifting and fading (GPU particles, broom_wake.gdshader; drawn by
## broom_wake_puff.gdshader with the broom mist flipbook). Every hero on a
## broom wears one (BroomRig): the own player and the replicated ones alike,
## since everything here is read from where the tip actually went:
##   * at speed: more puffs, each a thin wisp drawn out along the flight, so
##     the wake is long and narrow; hovering: a few slow round puffs sinking
##     from the bristles;
##   * a turn: the shed air keeps a little of the old heading and its drift
##     turns with the bank, so the wake hooks round outside the turn;
##   * a hard push off (a take-off, or speeding up from a hover): a ring of
##     puffs flung out round the tail and a flurry of glints;
##   * glints (the wake's embers): a faint trickle at speed, more on a turn.
## Getting off stops the shedding; what is in the air fades on its own.
## The CPU side is a handful of uniforms a frame (a rider beyond FAR none);
## the particles live on the GPU.

const PROCESS := preload("res://assets/shaders/broom_wake.gdshader")
const PUFF := preload("res://assets/shaders/broom_wake_puff.gdshader")
const SPARK := preload("res://assets/shaders/ember_spark.gdshader")
const MIST_ATLAS := "res://assets/vfx/atlases/broom_mist_8x8_1k.png"
const EROSION := "res://assets/vfx/tex/noise_erosion_512.png"

## Mist puffs alive at most (high preset; the preset's particle_scale thins
## them) and how long the longest of them lives.
const MIST_AMOUNT := 44
const MIST_LIFE := 1.7
const GLINT_AMOUNT := 14
const GLINT_LIFE := 1.1
const BURST_AMOUNT := 12
## Speeds (m/s) between which the wake turns from a hover's breath into a
## full streaming wake (the broom's top speed is 12-18.5).
const HOVER_SPEED := 1.2
const CRUISE_SPEED := 11.0
## A push off: the tip speeding up at least this hard (m/s per s) from below
## SLOW_SPEED (the broom's acceleration is 25 m/s per s).
const PUSH_ACCEL := 14.0
const SLOW_SPEED := 8.0
const PUSH_COOLDOWN := 1.4
## A tip that jumps further than this in one frame was moved (a trip, a snap
## back): no wake is drawn across the gap.
const TELEPORT := 6.0
## Beyond this far from the camera a rider sheds nothing.
const FAR := 90.0
## The tip's speed and turn are read over this long.
const WINDOW := 0.15

static var _mist_pass: QuadMesh
static var _glint_pass: QuadMesh
static var _glint_ramp: GradientTexture1D

## The bristle tip (BroomRig's TailSocket).
var tail: Node3D
var flying := false
var _mist: GPUParticles3D
var _glints: GPUParticles3D
var _burst: GPUParticles3D
var _mist_process: ShaderMaterial
var _glint_process: ShaderMaterial
var _burst_process: ShaderMaterial
var _last := Vector3.ZERO
var _has_last := false
var _velocity := Vector3.ZERO
var _speed := 0.0
var _accel := 0.0
var _turn := 0.0
var _heading := NAN
var _push_cooldown := 0.0
var _burst_in := -1.0
var _flurry := 0.0
var _far := false
var _pushes := 0
## The (moving, banking, turn) the slow uniforms were last written for.
var _look := Vector3(-1.0, -1.0, 0.0)
var _clock := 0.0
var _times := PackedFloat64Array()
var _spots := PackedVector3Array()
var _since_sample := 0.0
var _speed_then := 0.0

func _init() -> void:
	name = "BroomWake"
	# world placed: the hero's scale and turn never reach the particles
	top_level = true

func _ready() -> void:
	var share := float(QualityPreset.value("particle_scale", 1.0))
	_shared_passes()
	_mist_process = _process_material(false)
	_mist = _particles("Mist", maxi(16, int(round(MIST_AMOUNT * share))), MIST_LIFE, _mist_process, _mist_pass)
	_glint_process = _process_material(true)
	_glint_process.set_shader_parameter(&"width_min", 0.006)
	_glint_process.set_shader_parameter(&"width_max", 0.016)
	_glint_process.set_shader_parameter(&"drag", 2.4)
	_glint_process.set_shader_parameter(&"swirl", 2.2)
	_glint_process.set_shader_parameter(&"jitter", 1.1)
	_glint_process.set_shader_parameter(&"lift", -0.2)
	_glints = _particles("Glints", maxi(6, int(round(GLINT_AMOUNT * share))), GLINT_LIFE, _glint_process, _glint_pass)
	_burst_process = _process_material(false)
	_burst = _particles("Burst", BURST_AMOUNT, 1.2, _burst_process, _mist_pass)
	_burst.one_shot = true
	_burst.explosiveness = 0.9

## One draw pass of each kind for every wake in the game (the per-hero part is
## only the process material).
static func _shared_passes() -> void:
	if _mist_pass != null:
		return
	var puff := ShaderMaterial.new()
	puff.shader = PUFF
	puff.set_shader_parameter(&"atlas", SpellEffect.asset(MIST_ATLAS))
	puff.set_shader_parameter(&"erosion", SpellEffect.asset(EROSION))
	_mist_pass = QuadMesh.new()
	_mist_pass.material = puff
	var spark := ShaderMaterial.new()
	spark.shader = SPARK
	_glint_pass = QuadMesh.new()
	_glint_pass.material = spark
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.1, 0.6, 1.0])
	gradient.colors = PackedColorArray([Color(1.0, 0.97, 0.88, 0.9), Color(1.0, 0.86, 0.55, 0.75),
		Color(0.95, 0.72, 0.38, 0.45), Color(0.8, 0.55, 0.3, 0.0)])
	_glint_ramp = GradientTexture1D.new()
	_glint_ramp.gradient = gradient
	_glint_ramp.width = 32

func _process_material(spark: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PROCESS
	material.set_shader_parameter(&"spark", spark)
	material.set_shader_parameter(&"rate", 0.0)
	if spark:
		material.set_shader_parameter(&"ramp", _glint_ramp)
	return material

func _particles(node_name: String, amount: int, life: float, process: ShaderMaterial, draw: QuadMesh) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = amount
	particles.lifetime = life
	particles.local_coords = false
	# every frame, so `emit_motion` is exactly this frame's path
	particles.fixed_fps = 0
	particles.randomness = 0.0
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the wake trails up to ~30 m behind a fast broom
	particles.visibility_aabb = AABB(Vector3(-36, -14, -36), Vector3(72, 28, 72))
	particles.process_material = process
	particles.draw_pass_1 = draw
	particles.emitting = false
	add_child(particles)
	return particles

## Start or stop shedding (the rider got on or off). Getting on pushes off
## with a burst once the broom is under the rider.
func set_flying(on: bool) -> void:
	if on == flying:
		return
	flying = on
	_has_last = false
	_look = Vector3(-1.0, -1.0, 0.0)
	_heading = NAN
	_far = false
	if _mist != null:
		_mist.emitting = on
		_glints.emitting = on
	if on:
		_burst_in = 0.35

## What the wake is doing now (the dev checks print it).
func describe() -> Dictionary:
	return {"flying": flying, "speed": _speed, "turn": _turn, "accel": _accel, "pushes": _pushes,
		"rate": float(_mist_process.get_shader_parameter(&"rate")) if _mist_process != null else 0.0,
		"mist": _mist.amount if _mist != null else 0, "glints": _glints.amount if _glints != null else 0}

func _process(delta: float) -> void:
	if tail == null or not is_instance_valid(tail) or not tail.is_inside_tree() or delta <= 0.0:
		return
	var at := tail.global_position
	global_position = at
	if not flying:
		return
	# a rider far off sheds nothing (a wake there is a few pixels) and costs
	# nothing; the smoke it left fades on its own
	var camera := get_viewport().get_camera_3d()
	var far := camera != null and camera.global_position.distance_squared_to(at) > FAR * FAR
	if far != _far:
		_far = far
		_mist.emitting = not far
		_glints.emitting = not far
		_has_last = false
	if far:
		return
	if not _has_last:
		_last = at
		_has_last = true
		_velocity = Vector3.ZERO
		_speed = 0.0
		_speed_then = 0.0
		_accel = 0.0
		_turn = 0.0
		_times.clear()
		_spots.clear()
	var motion := at - _last
	_last = at
	if motion.length() > TELEPORT:
		motion = Vector3.ZERO
		_times.clear()
		_spots.clear()
	_measure(delta)
	_shed(motion, delta)

## The tip's motion over the last WINDOW seconds (the own body steps on the
## 30 Hz simulation ticks and a replicated one on its snapshots, so one
## frame's motion is not its speed): velocity over the window, the change of
## speed and of heading against the previous window.
func _measure(delta: float) -> void:
	_clock += delta
	_times.append(_clock)
	_spots.append(_last)
	var keep := 0
	while keep < _times.size() - 2 and _clock - _times[keep + 1] >= WINDOW:
		keep += 1
	if keep > 0:
		_times = _times.slice(keep)
		_spots = _spots.slice(keep)
	var span := _clock - _times[0]
	if span < 0.03:
		return
	_velocity = (_spots[_spots.size() - 1] - _spots[0]) / span
	var speed := _velocity.length()
	var flat := Vector2(_velocity.x, _velocity.z)
	var heading := atan2(flat.x, flat.y) if flat.length() > 2.0 else NAN
	_since_sample += delta
	if _since_sample >= WINDOW:
		_accel = lerpf(_accel, (speed - _speed_then) / _since_sample, 0.6)
		var turn := 0.0
		if not is_nan(heading) and not is_nan(_heading):
			turn = angle_difference(_heading, heading) / _since_sample
		_turn = lerpf(_turn, turn, 0.6)
		_speed_then = speed
		_heading = heading
		_since_sample = 0.0
	# the look follows a steadied speed (a replicated hero's estimate jumps
	# with its snapshots)
	_speed = lerpf(_speed, speed, clampf(delta * 6.0, 0.0, 1.0))

func _shed(motion: Vector3, delta: float) -> void:
	var moving := smoothstep(HOVER_SPEED, CRUISE_SPEED, _speed)
	var banking := clampf(absf(_turn) / 1.6, 0.0, 1.0)
	var travel := _velocity / _speed if _speed > 0.3 else Vector3.UP
	# a push off: a take-off, or speeding up hard from (nearly) standing
	_push_cooldown -= delta
	if _burst_in >= 0.0:
		_burst_in -= delta
		if _burst_in < 0.0:
			_push(travel, 0.5)
	elif _accel > PUSH_ACCEL and _speed < SLOW_SPEED and _push_cooldown <= 0.0:
		_push(travel, 1.0)
	_flurry = maxf(0.0, _flurry - delta)
	var m := _mist_process
	var g := _glint_process
	# where and how fast the tip goes: every frame
	m.set_shader_parameter(&"emit_motion", motion)
	m.set_shader_parameter(&"travel", travel)
	m.set_shader_parameter(&"carry", _velocity * lerpf(0.0, 0.22, moving))
	g.set_shader_parameter(&"emit_motion", motion)
	g.set_shader_parameter(&"travel", travel)
	g.set_shader_parameter(&"carry", _velocity * 0.15 + Vector3.UP * 0.2)
	g.set_shader_parameter(&"rate", (0.12 + banking * 0.5) * moving + (1.0 if _flurry > 0.0 else 0.0))
	# the wake's character: only when it changed enough to see
	var look := Vector3(moving, banking, -_turn)
	if look.distance_to(_look) < 0.03:
		return
	_look = look
	# hovering: a slow breath of round puffs sinking from the bristles;
	# cruising: a dense run of thin wisps drawn out along the flight
	m.set_shader_parameter(&"rate", lerpf(0.16, 1.0, moving) + banking * 0.25)
	m.set_shader_parameter(&"jitter", lerpf(0.25, 0.35, moving))
	m.set_shader_parameter(&"lift", lerpf(-0.35, 0.12, moving))
	m.set_shader_parameter(&"drag", lerpf(1.2, 2.6, moving))
	m.set_shader_parameter(&"swirl", lerpf(0.5, 0.8, moving) + banking * 1.6)
	m.set_shader_parameter(&"curl", -_turn * 1.6)
	m.set_shader_parameter(&"width_min", lerpf(0.3, 0.28, moving))
	m.set_shader_parameter(&"width_max", lerpf(0.48, 0.42, moving))
	m.set_shader_parameter(&"grow", lerpf(2.2, 1.9, moving))
	m.set_shader_parameter(&"stretch", lerpf(1.0, 3.4, moving))
	m.set_shader_parameter(&"opacity", lerpf(0.26, 0.42, moving) + banking * 0.1)
	m.set_shader_parameter(&"life_scale", lerpf(0.75, 1.0, moving))
	g.set_shader_parameter(&"curl", -_turn * 1.6)

func _push(travel: Vector3, strength: float) -> void:
	_pushes += 1
	_push_cooldown = PUSH_COOLDOWN
	_flurry = 0.35 * strength
	var b := _burst_process
	b.set_shader_parameter(&"rate", 1.0)
	b.set_shader_parameter(&"emit_motion", Vector3.ZERO)
	b.set_shader_parameter(&"travel", travel)
	b.set_shader_parameter(&"carry", -travel * 1.5 * strength)
	b.set_shader_parameter(&"burst", 2.2 * strength + 0.8)
	b.set_shader_parameter(&"jitter", 0.5)
	b.set_shader_parameter(&"lift", 0.05)
	b.set_shader_parameter(&"drag", 2.8)
	b.set_shader_parameter(&"swirl", 1.2)
	b.set_shader_parameter(&"width_min", 0.32)
	b.set_shader_parameter(&"width_max", 0.55)
	b.set_shader_parameter(&"grow", 2.6)
	b.set_shader_parameter(&"stretch", 1.0)
	b.set_shader_parameter(&"opacity", 0.32 * strength + 0.12)
	b.set_shader_parameter(&"life_scale", 1.0)
	b.set_shader_parameter(&"emit_radius", 0.2)
	_burst.restart()
