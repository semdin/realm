extends Node3D
class_name StatusFX

## What crowd control and damage over time look like on a body: the status
## byte the server replicates per entity (RealmSession.remote `statuses`),
## drawn the same way for creatures and heroes alike.
##
##   stun     dizziness over the head: three small comets of pale gold light
##            chasing round a thin wobbling ring, with a dust of motes that
##            twinkle in and out (dizzy_orbit.gdshader, on the GPU), and red
##            sparks dripping off the body
##   freeze   a clear ice shell over the body, ice shards at its feet, cold mist
##            rolling off it, the pose held; the ice bursts when it thaws
##   slow     rime creeping up from the feet, frost motes and a cold mist, the
##            animation at the slowed pace
##   bleed    wet stains on the body, drops, a spurt now and then, and a
##            trail of blood on the ground behind it
##   burn     the body is on fire: a few big tongues of flame off its back and
##            shoulders, sparks, smoke over its head, a little soot and the
##            fire's glow on it, a flickering firelight (the spell, an ignite proc)
##   poison   a faint green sheen, green vapour rising, bubbles
##   knocked  dust where the throw starts and where it lands
##   weak     (disarmed) only its name
##   rooted   bound where it stands: strands of silk wound round its legs
##            and waist over a torn milky film (web_bind.gdshader), pale
##            flecks drifting off it; the silk tears away when the hold ends
##
## No words over the body: the look says it, and the player's own effects
## and the target's stand as icons in the HUD (HudBuffBar). Bodies call
## `StatusFX.update(body, bits)` when their status changes; nothing is built on
## a headless process. What the look needs from a body:
##   visuals          the Node3D holding its drawn meshes (else the body itself)
##   head_height      metres from the feet to the top of the head (optional;
##                    else the meshes' top)
##   is_dead          true once it died (no thaw burst or smoke puff on a corpse)
##   set_cc_anim_scale(pace)  optional: 0 holds the pose (frozen), 0.55 is
##                    the slowed pace, 1 the normal one
## Presentation only: the server decides who carries which status and for how
## long.

## The server's status bits (realm_proto STATUS_*).
const STATUS_STUN := 1
const STATUS_FREEZE := 2
const STATUS_SLOW := 4
const STATUS_BLEED := 8
const STATUS_BURN := 16
const STATUS_POISON := 32
const STATUS_KNOCKED := 64
const STATUS_WEAK := 128
const STATUS_ROOTED := 256
## The silk a rooted body is bound in, how see-through it is, and how much of
## the body's height it covers.
const WEB_SHADER := preload("res://assets/shaders/web_bind.gdshader")
const WEB_COVER := 0.55
const WEB_WIND := 0.18

const GLOW_TEX := "res://assets/vfx/tex/soft_glow_512.png"
const FLAME_ATLAS := "res://assets/vfx/atlases/flame_loop_8x8_1k.png"
const SMOKE_ATLAS := "res://assets/vfx/atlases/smoke_puff_8x8_1k.png"
const NOISE_TEX := "res://assets/vfx/tex/noise_erosion_512.png"
const SKIN_SHADER := preload("res://assets/shaders/status_skin.gdshader")
const DIZZY_SHADER := preload("res://assets/shaders/dizzy_orbit.gdshader")
const ICE_SHADER := preload("res://assets/shaders/ice_crystal.gdshader")
const BLOOD_SHADER := preload("res://assets/shaders/blood_splat.gdshader")
const SPARK_SHADER := preload("res://assets/shaders/ember_spark.gdshader")
## The stun's dizziness: comets round the ring, motes per comet, loose dust.
const DIZZY_COMETS := 3
const DIZZY_TAIL := 10
const DIZZY_DUST := 12
## Its ring is this wide for a man-sized head (0.45 m girth), within limits.
const DIZZY_RADIUS := 0.26
const FLAME_SHADER := preload("res://assets/shaders/body_flame.gdshader")
## The fire's crackle on a burning body (the flame wave's loop).
const BURN_SOUND := "spell_flame_wave_sustain"
## The spell stage whose sparks drip off a stunned body.
const STUN_SPELL := "stun_bolt"
## A stun outlasting this is renewed by the server; the sparks are freed with
## the status anyway.
const STUN_SPARKS_SECONDS := 30.0
## The pace of a slowed body's clips.
const SLOW_PACE := 0.55
## Blood left on the ground at a time, per bleeding body.
const MAX_SPLATS := 5

const BITS := [STATUS_STUN, STATUS_FREEZE, STATUS_SLOW, STATUS_BLEED, STATUS_BURN,
	STATUS_POISON, STATUS_KNOCKED, STATUS_WEAK, STATUS_ROOTED]


static var _materials: Dictionary = {}
## The sparks' draw mesh (ember_spark.gdshader on a quad), one per process.
static var _spark_quad: QuadMesh = null

var body: Node3D = null
var bits := 0
var _head := 1.9
var _radius := 0.5
## The drawn body's bounds in the body's own space (the meshes at rest), so the
## flames cover a wide low spider as well as a tall troll.
var _bounds := AABB()
var _parts: Dictionary = {}       # status bit -> Node (its look while it runs)
var _overlay: Material = null
var _overlaid: Array = []         # meshes carrying _overlay
var _stars: GPUParticles3D = null
## Spell-stage effects that live in the world, following the body (the stun
## sparks): freed with the status, or with the body.
var _world_parts: Dictionary = {}  # status bit -> Node3D
var _t := 0.0
var _firelight: OmniLight3D = null
var _burn_audio := false
var _spurt_wait := 0.0
var _splats: Array = []
var _cold: ShaderMaterial = null

## Load the status looks' own pictures ahead of them: the first stun, freeze or
## burn on a body read them from disk on that frame.
static func warm_assets() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for path in [GLOW_TEX, FLAME_ATLAS, SMOKE_ATLAS, NOISE_TEX]:
		SpellEffect.asset(path)

## Draw `status` on `target` (creating its StatusFX child the first time).
static func update(target: Node3D, status: int) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	if DisplayServer.get_name() == "headless":
		return
	var fx := target.get_node_or_null("StatusFX") as StatusFX
	if fx == null:
		if status == 0:
			return
		fx = StatusFX.new()
		fx.name = "StatusFX"
		fx.body = target
		target.add_child(fx)
	fx._apply(status)

func _ready() -> void:
	_measure()
	set_process(false)

## Head height and girth from the drawn meshes (at rest), the head from the
## body when it knows it.
func _measure() -> void:
	var told: Variant = body.get("head_height")
	var known_head := told != null and float(told) > 0.0
	if known_head:
		_head = clampf(float(told), 0.6, 9.0)
	var root: Variant = body.get("visuals")
	var meshes: Array = []
	_collect(root if root is Node3D else body, meshes)
	var found := false
	var to_body := body.global_transform.affine_inverse()
	var merged := AABB()
	for mesh in meshes:
		var box := (to_body * _drawn_transform(mesh as MeshInstance3D)) * (mesh as VisualInstance3D).get_aabb()
		merged = box if not found else merged.merge(box)
		found = true
	# Trust the meshes only when they look like a body (a stray 100x rig scale
	# or an empty mesh would put the fire metres away).
	if found and merged.size.y > 0.3 and merged.size.y < (_head * 2.5 + 1.0 if known_head else 12.0) \
			and maxf(merged.size.x, merged.size.z) < merged.size.y * 6.0 + 2.0:
		_bounds = merged
		_radius = clampf(minf(merged.size.x, merged.size.z) * 0.5, 0.3, 2.5)
		if not known_head:
			_head = clampf(merged.end.y, 1.0, 9.0)
	else:
		_bounds = AABB(Vector3(-_radius, 0.0, -_radius), Vector3(_radius * 2.0, _head, _radius * 2.0))

## Where a mesh's rest-pose vertices are drawn. A skinned mesh is drawn by its
## skeleton, not by its own node: its rest vertices go through the bind pose and
## the bone rest into skeleton space (a rig imported at 100x with a 0.01
## armature has a node transform that would shrink the body to centimetres).
static func _drawn_transform(mesh: MeshInstance3D) -> Transform3D:
	var skeleton := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
	if mesh.skin == null or skeleton == null or mesh.skin.get_bind_count() == 0:
		return mesh.global_transform
	var bone := mesh.skin.get_bind_bone(0)
	if bone < 0:
		bone = skeleton.find_bone(mesh.skin.get_bind_name(0))
	if bone < 0:
		return mesh.global_transform
	return skeleton.global_transform * skeleton.get_bone_global_rest(bone) * mesh.skin.get_bind_pose(0)

func _apply(status: int) -> void:
	if status == bits:
		return
	var began := status & ~bits
	var ended := bits & ~status
	bits = status
	for bit in BITS:
		if ended & int(bit):
			_end(int(bit))
	for bit in BITS:
		if began & int(bit):
			_begin(int(bit))
	_refresh_overlay()
	_refresh_pace()
	set_process(bits & (STATUS_BURN | STATUS_BLEED) != 0)

func _exit_tree() -> void:
	_stop_burn_audio()
	_clear_overlay()
	for part in _world_parts.values():
		if part is Node and is_instance_valid(part):
			(part as Node).queue_free()
	_world_parts.clear()

func _process(delta: float) -> void:
	_t += delta
	if _firelight != null and is_instance_valid(_firelight):
		# firelight never holds still
		_firelight.light_energy = 1.5 + sin(_t * 23.0) * 0.25 + sin(_t * 9.7) * 0.3 + randf() * 0.25
	if _burn_audio:
		var audio := _audio()
		if audio != null:
			audio.call("move_loop", BURN_SOUND, self, global_position)
	if bits & STATUS_BLEED:
		_spurt_wait -= delta
		if _spurt_wait <= 0.0:
			_spurt_wait = randf_range(0.8, 1.4)
			_spurt()

func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")

# ------------------------------------------------------------------ begin/end

func _begin(bit: int) -> void:
	match bit:
		STATUS_STUN:
			_stars = _make_dizzy()
			_parts[bit] = _stars
			_world_parts[bit] = SkillFX.spawn_stage(body.get_parent(), STUN_SPELL, "sustain",
				body.global_position + Vector3.UP * (_head + 0.1), Vector3.UP, null,
				{"follow_target": body, "duration": STUN_SPARKS_SECONDS, "floor_y": body.global_position.y})
		STATUS_FREEZE:
			_parts[bit] = _holder("Freeze", [_make_crystals(), _make_mist(Color(0.82, 0.93, 1.0, 0.32), -0.25, 5)])
		STATUS_SLOW:
			_parts[bit] = _holder("Slow", [_make_motes(Color(0.7, 0.9, 1.0, 0.9), -1.2, 10, 1.1, 0.09),
				_make_mist(Color(0.78, 0.9, 1.0, 0.22), -0.12, 4)])
		STATUS_BLEED:
			_parts[bit] = _make_drops()
			_spurt_wait = 0.25
		STATUS_BURN:
			_parts[bit] = _make_fire()
		STATUS_POISON:
			_parts[bit] = _holder("Poison", [_make_motes(Color(0.45, 1.0, 0.3, 0.8), 1.4, 8, 1.0, 0.11),
				_make_mist(Color(0.45, 0.75, 0.3, 0.12), 0.3, 3, 0.55)])
		STATUS_KNOCKED:
			_dust(1.0)
		STATUS_ROOTED:
			_parts[bit] = _make_web()

func _end(bit: int) -> void:
	for parts in [_parts, _world_parts]:
		var part = parts.get(bit)
		parts.erase(bit)
		if part is GPUParticles3D and bit == STATUS_STUN and is_inside_tree():
			# the dizziness clears rather than blinking out
			_fade_dizzy(part as GPUParticles3D, 0.0, 0.22).tween_callback((part as Node).queue_free)
		elif part is Node and is_instance_valid(part):
			(part as Node).queue_free()
	match bit:
		STATUS_STUN:
			_stars = null
		STATUS_BURN:
			_firelight = null
			_stop_burn_audio()
			if is_inside_tree() and not _is_dead():
				_smoke_out()
		STATUS_FREEZE:
			if is_inside_tree() and not _is_dead():
				_shatter()
		STATUS_KNOCKED:
			if is_inside_tree() and not _is_dead():
				_dust(1.35)
		STATUS_ROOTED:
			if is_inside_tree() and not _is_dead():
				var size := Vector2(minf(_radius * 1.4, 1.2), minf(_bounds.size.y * WEB_COVER, 1.1) * 0.6)
				SilkBurst.play(body.get_parent(), body.global_position + Vector3.UP * 0.05, size, Color(0, 0, 0, 0))

func _is_dead() -> bool:
	return body.get("is_dead") == true

# ------------------------------------------------------------------ the body

## One overlay at a time, the strongest look first: ice, then fire, rime,
## poison, blood.
func _refresh_overlay() -> void:
	var wanted: Material = null
	if bits & STATUS_FREEZE:
		wanted = _material("ice")
	elif bits & STATUS_BURN:
		wanted = _material("burn")
	elif bits & STATUS_SLOW:
		# rime climbs a third of this body's height (a spider is not a troll)
		if _cold == null:
			_cold = _material("cold").duplicate() as ShaderMaterial
			_cold.set_shader_parameter("reach", clampf(_bounds.size.y * 0.35, 0.2, 1.2))
		wanted = _cold
	elif bits & STATUS_POISON:
		wanted = _material("poison")
	elif bits & STATUS_BLEED:
		wanted = _material("blood")
	if wanted == _overlay:
		return
	_clear_overlay()
	_overlay = wanted
	if wanted == null:
		return
	var root: Variant = body.get("visuals")
	_collect(root if root is Node3D else body, _overlaid)
	for mesh in _overlaid:
		(mesh as GeometryInstance3D).material_overlay = wanted

func _clear_overlay() -> void:
	for mesh in _overlaid:
		if is_instance_valid(mesh) and (mesh as GeometryInstance3D).material_overlay == _overlay:
			(mesh as GeometryInstance3D).material_overlay = null
	_overlaid.clear()
	_overlay = null

func _collect(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child == self or child.name == "StatusFX":
			continue
		if child is MeshInstance3D and (child as MeshInstance3D).visible:
			out.append(child)
		if out.size() < 32:
			_collect(child, out)

## Frozen: the pose is held. Slowed: the clips play at the slowed pace.
func _refresh_pace() -> void:
	if not body.has_method("set_cc_anim_scale"):
		return
	var pace := 1.0
	if bits & STATUS_FREEZE:
		pace = 0.0
	elif bits & STATUS_SLOW:
		pace = SLOW_PACE
	body.call("set_cc_anim_scale", pace)

# ------------------------------------------------------------------ the looks

## Several looks under one node, freed together with their status.
## Bound where it stands: silk wound round the lower body (web_bind.gdshader
## on an open tube, wider at the feet), winding on over WEB_WIND seconds,
## and a few flecks of silk drifting off it.
func _make_web() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Web"
	add_child(holder)
	var height := clampf(_bounds.size.y * WEB_COVER, 0.45, 2.4)
	var wide := _bounds.size.y < _radius * 1.6
	var tube := CylinderMesh.new()
	tube.top_radius = _radius * (1.15 if wide else 0.78)
	tube.bottom_radius = _radius * (1.35 if wide else 1.05)
	tube.height = height
	tube.cap_top = false
	tube.cap_bottom = false
	tube.radial_segments = 20
	tube.rings = 3
	var mesh := MeshInstance3D.new()
	mesh.name = "Silk"
	mesh.mesh = tube
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.material_override = _material("web")
	mesh.position = Vector3(0.0, height * 0.5 - 0.03, 0.0)
	mesh.set_instance_shader_parameter("wound", 0.0)
	holder.add_child(mesh)
	var wind := holder.create_tween()
	wind.tween_method(func(v: float) -> void: mesh.set_instance_shader_parameter("wound", v), 0.0, 1.0, WEB_WIND)
	var flecks := RisingMotes.make(_radius * 0.9, 1.6, Color(0.92, 0.9, 0.96, 0.8), 8, 1.4,
		Vector2(0.15, 0.5), Vector2(0.01, 0.025), false)
	flecks.position = Vector3(0, height * 0.6, 0)
	holder.add_child(flecks)
	flecks.emitting = true
	return holder

func _holder(holder_name: String, parts: Array) -> Node3D:
	var holder := Node3D.new()
	holder.name = holder_name
	add_child(holder)
	for part in parts:
		(part as Node).reparent(holder, false)
	return holder

## The body on fire: flames licking up off its whole height (they trail behind
## a body that runs, local_coords off), embers flying up, smoke rolling off the
## top, a flickering firelight on everything round it, and its crackle.
func _make_fire() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Burning"
	add_child(holder)
	var low := SkillFX.quality == "low"
	var middle := _bounds.get_center()
	var half := _bounds.size * 0.5
	# A few big tongues sized to the body (a scatter of small ones read as
	# speckles), rising off its upper half; a wide body gets a couple more.
	var tongue := clampf(minf(maxf(half.x, half.z) * 2.0, _bounds.size.y) * 0.8, 0.55, 1.9)
	var spread_area := clampf((half.x * half.z) / 0.25, 1.0, 1.8)
	var flames := _particles(_material("flame"), int((6 if low else 8) * spread_area), 0.85, tongue)
	flames.reparent(holder, false)
	flames.position = Vector3(middle.x, middle.y + half.y * 0.3, middle.z)
	flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	flames.emission_box_extents = Vector3(half.x * 0.45, half.y * 0.3, half.z * 0.45)
	flames.direction = Vector3.UP
	flames.spread = 12.0
	flames.initial_velocity_min = 0.35
	flames.initial_velocity_max = 0.9
	flames.gravity = Vector3(0, 1.4, 0)
	flames.angle_min = -14.0
	flames.angle_max = 14.0
	flames.anim_speed_min = 0.22
	flames.anim_speed_max = 0.32
	flames.anim_offset_max = 1.0
	flames.scale_amount_min = 0.7
	flames.scale_amount_max = 1.25
	flames.scale_amount_curve = _curve([Vector2(0.0, 0.35), Vector2(0.25, 1.0), Vector2(1.0, 0.25)])
	flames.color = Color(1.0, 0.9, 0.8, 1.0)
	flames.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1.0, 0.7, 0.5, 0.0)], [0.0, 0.15, 1.0])
	var embers := _particles(_material("mote"), 4 if low else 6, 1.1, 0.045 * clampf(tongue / 0.5, 0.8, 2.0))
	embers.reparent(holder, false)
	embers.position = Vector3(middle.x, middle.y + half.y * 0.3, middle.z)
	embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	embers.emission_box_extents = Vector3(half.x * 0.7, half.y * 0.4, half.z * 0.7)
	embers.direction = Vector3.UP
	embers.spread = 30.0
	embers.initial_velocity_min = 1.2
	embers.initial_velocity_max = 2.6
	embers.gravity = Vector3(0, 0.6, 0)
	embers.damping_min = 0.6
	embers.damping_max = 1.4
	embers.color = Color(1.0, 0.55, 0.15, 1.0)
	var smoke := _particles(_material("smoke"), 4 if low else 7, 1.8, tongue * 1.4)
	smoke.reparent(holder, false)
	smoke.position = Vector3(middle.x, _bounds.end.y, middle.z)
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	smoke.emission_box_extents = Vector3(half.x * 0.5, 0.1, half.z * 0.5)
	smoke.direction = Vector3.UP
	smoke.spread = 15.0
	smoke.initial_velocity_min = 0.5
	smoke.initial_velocity_max = 0.9
	smoke.gravity = Vector3(0, 0.3, 0)
	smoke.angle_min = -180.0
	smoke.angle_max = 180.0
	smoke.anim_speed_min = 0.8
	smoke.anim_speed_max = 1.0
	smoke.scale_amount_curve = _curve([Vector2(0.0, 0.5), Vector2(1.0, 1.7)])
	smoke.color = Color(0.13, 0.11, 0.1, 1.0)
	smoke.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0.0)], [0.0, 0.2, 1.0])
	if not low:
		_firelight = OmniLight3D.new()
		_firelight.light_color = Color(1.0, 0.5, 0.18)
		_firelight.omni_range = 3.0 + maxf(half.x, half.z) * 3.0
		_firelight.shadow_enabled = false
		holder.add_child(_firelight)
		_firelight.position = Vector3(middle.x, _bounds.end.y, middle.z)
	var audio := _audio()
	if audio != null and audio.has_method("loop_sound"):
		audio.call("loop_sound", BURN_SOUND, self)
		_burn_audio = true
	return holder

func _stop_burn_audio() -> void:
	if not _burn_audio:
		return
	_burn_audio = false
	var audio := _audio()
	if audio != null:
		audio.call("stop_sound", BURN_SOUND, self)

## The fire goes out in a puff of smoke.
func _smoke_out() -> void:
	var size := clampf(_radius * 2.2, 1.2, 3.6)
	FlipbookFX.play(body.get_parent(), body.global_position + Vector3.UP * (_head * 0.55), [
		{"atlas": "smoke_puff_8x8_1k", "size": size, "height": 0.0, "fps": 26.0, "tint": Color(0.2, 0.18, 0.17), "opacity": 0.5},
	], {"life": 1.3, "name": "BurnOut"})

## Slow-rolling vapour round the body: cold mist sinking off ice and rime
## (`rise` < 0), green fumes rising off poison.
func _make_mist(colour: Color, rise: float, amount: int, size: float = 0.9) -> CPUParticles3D:
	var girth := clampf(_radius / 0.45, 0.8, 2.6)
	var mist := _particles(_material("smoke"), amount, 1.9, size * girth)
	mist.position.y = _head * (0.25 if rise < 0.0 else 0.55)
	mist.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	mist.emission_sphere_radius = _radius * 0.8
	mist.direction = Vector3.UP if rise > 0.0 else Vector3.DOWN
	mist.spread = 60.0
	mist.initial_velocity_min = absf(rise) * 0.4
	mist.initial_velocity_max = absf(rise)
	mist.gravity = Vector3.ZERO
	mist.angle_min = -180.0
	mist.angle_max = 180.0
	mist.anim_speed_min = 0.7
	mist.anim_speed_max = 0.9
	mist.scale_amount_curve = _curve([Vector2(0.0, 0.6), Vector2(1.0, 1.5)])
	mist.color = Color(colour.r, colour.g, colour.b, 1.0)
	mist.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, colour.a), Color(1, 1, 1, 0.0)], [0.0, 0.3, 1.0])
	return mist

## A bleeding wound pumps: a few drops thrown out and a fresh spot of blood
## on the ground under the body (the old ones fade as it walks on).
func _spurt() -> void:
	if not is_inside_tree() or _is_dead():
		return
	var spray := _particles(_material("drop"), 6, 0.6, 0.06)
	spray.reparent(body.get_parent(), true)
	spray.global_position = body.global_position + Vector3.UP * (_head * 0.6)
	spray.one_shot = true
	spray.explosiveness = 0.9
	spray.direction = Vector3(randf_range(-1.0, 1.0), 0.6, randf_range(-1.0, 1.0)).normalized()
	spray.spread = 25.0
	spray.initial_velocity_min = 1.2
	spray.initial_velocity_max = 2.4
	spray.gravity = Vector3(0, -9.0, 0)
	spray.color = Color(0.45, 0.0, 0.01, 1.0)
	spray.emitting = true
	spray.finished.connect(spray.queue_free)
	_splat()

## A spot of blood on the ground under the body. The body's drawn position is
## its feet on the ground (the server's); a body thrown through the air leaves
## none.
func _splat() -> void:
	if bits & STATUS_KNOCKED:
		return
	var spot := MeshInstance3D.new()
	var quad := QuadMesh.new()
	var size := randf_range(0.25, 0.45) * clampf(_radius / 0.45, 0.8, 1.8)
	quad.size = Vector2(size, size * randf_range(0.7, 1.0))
	quad.orientation = PlaneMesh.FACE_Y
	quad.material = _material("splat")
	spot.mesh = quad
	spot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.get_parent().add_child(spot)
	spot.global_position = body.global_position + Vector3.UP * 0.03 \
		+ Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)) * _radius
	spot.rotation.y = randf() * TAU
	spot.transparency = 0.15
	var tw := spot.create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(spot, "transparency", 1.0, 2.5)
	tw.tween_callback(spot.queue_free)
	_splats = _splats.filter(func(s): return is_instance_valid(s))
	_splats.append(spot)
	while _splats.size() > MAX_SPLATS:
		var old = _splats.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()

static func _curve(points: Array) -> Curve:
	var curve := Curve.new()
	curve.max_value = 2.0
	for point in points:
		curve.add_point(point)
	return curve

static func _ramp(colours: Array, offsets: Array) -> Gradient:
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array(offsets)
	ramp.colors = PackedColorArray(colours)
	return ramp

## The stun's dizziness over the head (dizzy_orbit.gdshader): small comets of
## light chasing round a thin wobbling ring a little wider than the head, and
## motes twinkling round with them. Its own copy of the process material: it
## fades in and out on its own.
func _make_dizzy() -> GPUParticles3D:
	var ring := GPUParticles3D.new()
	ring.name = "Dizzy"
	var r := clampf(DIZZY_RADIUS * _radius / 0.45, 0.2, 0.75)
	var grow := clampf(r / DIZZY_RADIUS, 0.85, 2.0)
	ring.amount = DIZZY_COMETS * DIZZY_TAIL + DIZZY_DUST
	# every particle's place is a function of the time: they never die
	ring.lifetime = 600.0
	ring.explosiveness = 1.0
	ring.local_coords = true
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var span := r * 1.4 + 0.2
	ring.visibility_aabb = AABB(Vector3(-span, -0.5, -span), Vector3(span * 2.0, 1.0, span * 2.0))
	if _spark_quad == null:
		_spark_quad = QuadMesh.new()
		var draw := ShaderMaterial.new()
		draw.shader = SPARK_SHADER
		_spark_quad.material = draw
	ring.draw_pass_1 = _spark_quad
	var process := (_material("dizzy") as ShaderMaterial).duplicate() as ShaderMaterial
	process.set_shader_parameter("radius", r)
	process.set_shader_parameter("size_head", 0.019 * grow)
	process.set_shader_parameter("size_dust", 0.008 * grow)
	process.set_shader_parameter("strength", 0.0)
	ring.process_material = process
	add_child(ring)
	# round the crown, where a dazed head's eyes would roll
	ring.position.y = _head - 0.08 * grow
	ring.emitting = true
	_fade_dizzy(ring, 1.0, 0.18)
	return ring

func _fade_dizzy(ring: GPUParticles3D, to: float, seconds: float) -> Tween:
	var process := ring.process_material as ShaderMaterial
	var tween := ring.create_tween()
	tween.tween_method(func(v: float) -> void: process.set_shader_parameter("strength", v),
		float(process.get_shader_parameter("strength")), to, seconds)
	return tween

## Ice shards grown up round the feet (ice_crystal.gdshader: clear blue ice
## clouded by frost and cracks, a cold rim): a ring of slim ones leaning out
## and a few small ones between, each its own size and lean.
func _make_crystals() -> Node3D:
	var holder := Node3D.new()
	holder.name = "IceCrystals"
	add_child(holder)
	var grow := clampf(_head / 1.9, 0.8, 2.0)
	var count := 11
	for i in range(count):
		var small := i % 3 == 2
		var spike := MeshInstance3D.new()
		var prism := PrismMesh.new()
		var h := (randf_range(0.18, 0.32) if small else randf_range(0.38, 0.72)) * grow
		var w := (randf_range(0.07, 0.11) if small else randf_range(0.11, 0.17)) * grow
		prism.size = Vector3(w, h, w * randf_range(0.7, 0.95))
		prism.material = _material("ice_shard")
		spike.mesh = prism
		spike.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var a := TAU * float(i) / float(count) + randf_range(-0.2, 0.2)
		var r := _radius * (randf_range(0.95, 1.2) if small else randf_range(0.7, 0.95))
		spike.position = Vector3(cos(a) * r, h * 0.36, sin(a) * r)
		# Leaning out from the body, each its own way.
		var lean := randf_range(0.25, 0.55)
		spike.rotation = Vector3(sin(a) * lean, randf_range(0.0, TAU), -cos(a) * lean)
		holder.add_child(spike)
	return holder

func _make_drops() -> CPUParticles3D:
	var drops := _particles(_material("drop"), 14, 0.75, 0.07)
	drops.position.y = _head * 0.62
	drops.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	drops.emission_sphere_radius = _radius * 0.65
	drops.direction = Vector3.DOWN
	drops.spread = 25.0
	drops.initial_velocity_min = 0.3
	drops.initial_velocity_max = 1.0
	drops.gravity = Vector3(0, -9.0, 0)
	drops.color = Color(0.5, 0.0, 0.01, 1.0)
	return drops

## Frost motes falling (slow) or bubbles rising (poison) round the body.
func _make_motes(colour: Color, rise: float, amount: int, life: float, size: float) -> CPUParticles3D:
	var motes := _particles(_material("mote"), amount, life, size)
	motes.position.y = _head * (0.25 if rise > 0.0 else 0.9)
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	motes.emission_sphere_radius = _radius * 0.9
	motes.direction = Vector3.UP if rise > 0.0 else Vector3.DOWN
	motes.spread = 15.0
	motes.initial_velocity_min = absf(rise) * 0.5
	motes.initial_velocity_max = absf(rise)
	motes.gravity = Vector3.ZERO
	motes.color = colour
	return motes

func _particles(material: Material, amount: int, life: float, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material
	p.mesh = quad
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	add_child(p)
	return p

## Dust thrown up at the feet: the throw's take-off and its landing.
func _dust(scale: float) -> void:
	var feet := body.global_position + Vector3.UP * 0.05
	var size := clampf(_radius * 1.7, 1.1, 3.2) * scale
	FlipbookFX.play(body.get_parent(), feet, [
		{"atlas": "smoke_puff_8x8_1k", "size": size, "height": size * 0.3, "fps": 32.0, "tint": Color(0.55, 0.48, 0.38), "opacity": 0.45},
		{"atlas": "smoke_puff_8x8_1k", "size": size * 1.2, "flat": true, "height": 0.06, "fps": 28.0, "tint": Color(0.5, 0.44, 0.36), "opacity": 0.4},
	], {"life": 1.2, "name": "ThrowDust"})

## The ice bursts when the freeze ends.
func _shatter() -> void:
	var burst := _particles(_material("crystal"), 16, 0.6, 0.14)
	remove_child(burst)
	body.get_parent().add_child(burst)
	burst.global_position = body.global_position + Vector3.UP * (_head * 0.5)
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	burst.emission_sphere_radius = _radius * 0.7
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 2.5
	burst.initial_velocity_max = 5.0
	burst.gravity = Vector3(0, -14.0, 0)
	burst.color = Color(0.8, 0.95, 1.0, 1.0)
	burst.emitting = true
	burst.finished.connect(burst.queue_free)

# ------------------------------------------------------------------ materials

## The shared materials (one of each per process).
static func _material(kind: String) -> Material:
	if _materials.has(kind):
		return _materials[kind]
	if kind in ["burn", "ice", "cold", "poison", "blood"]:
		# The skin looks (status_skin.gdshader): one shader, a mode each.
		var skin := ShaderMaterial.new()
		skin.shader = SKIN_SHADER
		skin.set_shader_parameter("mode", {"burn": 0, "ice": 1, "cold": 2, "poison": 3, "blood": 4}[kind])
		skin.set_shader_parameter("noise", SpellEffect.asset(NOISE_TEX))
		# the ice shell sits a little proud of the skin; rime reaches the knees
		skin.set_shader_parameter("grow", 0.025 if kind == "ice" else 0.004)
		skin.set_shader_parameter("reach", 0.85)
		_materials[kind] = skin
		return skin
	if kind == "web":
		var web := ShaderMaterial.new()
		web.shader = WEB_SHADER
		web.set_shader_parameter("noise_tex", SpellEffect.asset(NOISE_TEX))
		_materials[kind] = web
		return web
	if kind == "dizzy":
		# the stun's comets: white-hot heads cooling to pale gold, then amber
		var dizzy := ShaderMaterial.new()
		dizzy.shader = DIZZY_SHADER
		dizzy.set_shader_parameter("comets", DIZZY_COMETS)
		dizzy.set_shader_parameter("tail", DIZZY_TAIL)
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.25, 0.7, 1.0])
		gradient.colors = PackedColorArray([Color(1.0, 0.97, 0.88, 1.0), Color(1.0, 0.86, 0.48, 1.0),
			Color(0.98, 0.62, 0.22, 0.8), Color(0.9, 0.42, 0.12, 0.0)])
		var ramp := GradientTexture1D.new()
		ramp.gradient = gradient
		ramp.width = 64
		dizzy.set_shader_parameter("ramp", ramp)
		_materials[kind] = dizzy
		return dizzy
	if kind == "splat":
		# a ragged spot of blood (blood_splat.gdshader), not a soft disc
		var splat := ShaderMaterial.new()
		splat.shader = BLOOD_SHADER
		splat.set_shader_parameter("noise", SpellEffect.asset(NOISE_TEX))
		_materials[kind] = splat
		return splat
	if kind == "ice_shard":
		var shard := ShaderMaterial.new()
		shard.shader = ICE_SHADER
		shard.set_shader_parameter("noise", SpellEffect.asset(NOISE_TEX))
		_materials[kind] = shard
		return shard
	if kind == "flame":
		var flame := ShaderMaterial.new()
		flame.shader = FLAME_SHADER
		flame.set_shader_parameter("atlas", SpellEffect.asset(FLAME_ATLAS))
		_materials[kind] = flame
		return flame
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	match kind:
		"smoke":
			# A rolling puff: the smoke flipbook played over each particle's life.
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			mat.billboard_keep_scale = true
			mat.particles_anim_h_frames = 8
			mat.particles_anim_v_frames = 8
			mat.particles_anim_loop = false
			mat.albedo_texture = SpellEffect.asset(SMOKE_ATLAS)
			mat.vertex_color_use_as_albedo = true
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		"crystal":
			mat.albedo_color = Color(0.7, 0.92, 1.0, 0.7)
			mat.emission_enabled = true
			mat.emission = Color(0.45, 0.75, 1.0)
			mat.emission_energy_multiplier = 1.1
			mat.roughness = 0.05
			mat.metallic_specular = 1.0
			mat.vertex_color_use_as_albedo = false
		"mote", "drop":
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if kind != "drop" else BaseMaterial3D.BLEND_MODE_MIX
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			mat.albedo_texture = SpellEffect.asset(GLOW_TEX)
			mat.vertex_color_use_as_albedo = true
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_materials[kind] = mat
	return mat
