extends Node3D
class_name ChestView

## A loot chest on the ground: every kill that dropped items leaves ONE chest
## holding them (oril goes straight to the purse). Right-clicking it opens the
## chest window (LootWindow); Z takes everything that fits. A plain chest glows
## warm gold, a chest that holds an enchanted piece (KIND_CHEST_RARE) sparkles
## violet. The glow is layered: a real (shadowless) light, a soft pool on the
## ground, a faint rising shaft, drifting motes and a fresnel rim on the model.
##
## It only draws: the chest is a snapshot entity (main.gd hands its position
## over), what it holds comes from the server when it is opened, and it goes
## when the snapshot no longer carries it.
##
## Opened (main.gd: the chest window, or Z), its lid (the model's own "Lid",
## split off by tools/art/split_chest.py, hinged on the back edge) jolts, then
## swings up and settles past upright; a breath of dust and a burst of motes in
## the chest's colour leave the opening, the light flares, and the inside
## (chest_inside.gdshader) glows up from the floor. It stays open while the
## window is on it, and shuts when the window closes on a chest still holding
## something. The server does not replicate who opened a chest, so only the
## opener sees it open.

## Snapshot kinds of a chest (realm_proto KIND_CHEST / KIND_CHEST_RARE).
const KIND_CHEST := 0x1000
const KIND_CHEST_RARE := 0x1001
const CHEST_MODEL := "res://assets/models/environment/loot_chest.glb"
const WorldSign := preload("res://scripts/world/world_sign.gd")
const RIM_SHADER := "res://assets/shaders/loot/chest_rim.gdshader"
const POOL_SHADER := "res://assets/shaders/loot/chest_pool.gdshader"
const BEAM_SHADER := "res://assets/shaders/loot/chest_beam.gdshader"
const INSIDE_SHADER := "res://assets/shaders/loot/chest_inside.gdshader"
const NOISE_TEX := "res://assets/vfx/tex/noise_erosion_512.png"
## The lid fully open (degrees back from shut: a little past upright, resting
## on its hinge), how long the swing takes, and how long Z's take keeps it up.
const LID_OPEN_DEGREES := 108.0
const LID_SWING := 0.42
const LID_HOLD := 1.2
## The light's height over the feet, shut and open.
const LIGHT_SHUT_Y := 0.22
const LIGHT_OPEN_Y := 0.5
const GLOW := {"chest": Color(1.0, 0.78, 0.36), "chest_rare": Color(0.66, 0.42, 1.0)}
## Per kind: light energy, pool, beam and rim strength, motes, pulse speed.
const LOOK := {
	"chest": {"light": 1.4, "pool": 1.1, "beam": 0.9, "rim": 0.25, "motes": 10, "speed": 1.6},
	"chest_rare": {"light": 1.8, "pool": 1.2, "beam": 1.2, "rim": 0.35, "motes": 18, "speed": 2.6},
}
## The chest opens from this close (the server's CHEST_REACH).
const PICK_RANGE := 7.0

static func is_chest(kind: int) -> bool:
	return kind == KIND_CHEST or kind == KIND_CHEST_RARE

## "chest" or "chest_rare".
var chest_kind := "chest"
var model_root: Node3D
var label: Label3D
var particles: CPUParticles3D
var pool: MeshInstance3D
var beam: MeshInstance3D
var light: OmniLight3D
var is_collected := false
var _phase := 0.0
var _rim_meshes: Array = []
## The lid (null: a model without one) and how open it is (0 shut, 1 open:
## the setter turns it), the inside's meshes [mesh, glow scale].
var lid: Node3D = null
var lid_open := 0.0:
	set(value):
		lid_open = value
		if lid != null:
			lid.rotation.x = -deg_to_rad(LID_OPEN_DEGREES) * value
var is_open := false
var _insides: Array = []
## Held open while this says so (main.gd: the window is on this chest), and
## at least until _open_until (seconds).
var _still_open: Callable = Callable()
var _open_until := 0.0
var _lid_tween: Tween = null
## The light's flare as it opens (decays to 0).
var _flare := 0.0
static var _inside_material: ShaderMaterial = null

func setup(kind: int) -> void:
	chest_kind = "chest_rare" if kind == KIND_CHEST_RARE else "chest"
	_phase = randf() * TAU
	model_root = Node3D.new()
	model_root.name = "Model"
	add_child(model_root)
	var scene := load(CHEST_MODEL) as PackedScene
	if scene != null:
		var model := scene.instantiate() as Node3D
		model_root.add_child(model)
		_fit_model(model, 0.9)
		var rim := ShaderMaterial.new()
		rim.shader = load(RIM_SHADER)
		for mesh in model.find_children("*", "MeshInstance3D", true, false):
			(mesh as MeshInstance3D).material_overlay = rim
			_rim_meshes.append(mesh)
			_dress_inside(mesh as MeshInstance3D)
		lid = model.find_child("Lid", true, false) as Node3D
	model_root.rotation.y = randf() * TAU
	_build_glow()
	_update_display()

## The pool, shaft, light, name and motes of the old LootDrop scene.
func _build_glow() -> void:
	var pool_material := ShaderMaterial.new()
	pool_material.render_priority = -1
	pool_material.shader = load(POOL_SHADER)
	var plane := PlaneMesh.new()
	plane.material = pool_material
	plane.size = Vector2(2.1, 2.1)
	pool = MeshInstance3D.new()
	pool.name = "GlowPool"
	pool.position = Vector3(0, 0.03, 0)
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pool.mesh = plane
	add_child(pool)
	var beam_material := ShaderMaterial.new()
	beam_material.shader = load(BEAM_SHADER)
	var quad := QuadMesh.new()
	quad.material = beam_material
	quad.size = Vector2(0.95, 2.6)
	beam = MeshInstance3D.new()
	beam.name = "Beam"
	beam.position = Vector3(0, 1.2, 0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.mesh = quad
	add_child(beam)
	light = OmniLight3D.new()
	light.name = "Light"
	light.position = Vector3(0, LIGHT_SHUT_Y, 0)
	light.light_color = Color(1, 0.8, 0.35)
	light.light_energy = 0.9
	light.light_specular = 0.25
	light.omni_range = 2.3
	light.omni_attenuation = 1.2
	add_child(light)
	label = WorldSign.new()   # readable from afar, faded past 45 m
	label.call("setup", 45.0, 15.0)
	label.name = "Label3D"
	label.position = Vector3(0, 1.2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.double_sided = false
	label.font_size = 28
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0, 1)
	add_child(label)
	particles = CPUParticles3D.new()
	particles.name = "Motes"
	particles.position = Vector3(0, 0.3, 0)
	particles.mesh = _mote_mesh()
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 0.4
	particles.direction = Vector3(0, 1, 0)
	particles.spread = 20.0
	particles.initial_velocity_min = 0.1
	particles.initial_velocity_max = 0.25
	particles.gravity = Vector3(0, 0.25, 0)
	particles.damping_min = 0.1
	particles.damping_max = 0.2
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.1
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.2), 0.0, 3.0)
	curve.add_point(Vector2(0.25, 1), 0.0, 0.0)
	curve.add_point(Vector2(1, 0), -1.4, 0.0)
	particles.scale_amount_curve = curve
	add_child(particles)

## A soft round mote that faces the camera.
static func _mote_mesh() -> QuadMesh:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 32
	texture.height = 32
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1, 0.5)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = texture
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	var quad := QuadMesh.new()
	quad.material = material
	quad.size = Vector2(0.09, 0.09)
	return quad

## Scale an imported model to `width` metres across and stand it on the ground.
func _fit_model(model: Node3D, width: float) -> void:
	var box := AABB()
	var first := true
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		var local: AABB = (mesh as MeshInstance3D).get_aabb()
		var xf: Transform3D = _relative_transform(model, mesh as Node3D)
		var b := xf * local
		box = b if first else box.merge(b)
		first = false
	if first or box.size.x <= 0.0:
		return
	var s := width / maxf(box.size.x, box.size.z)
	model.scale = Vector3.ONE * s
	model.position = -Vector3(box.get_center().x, box.position.y, box.get_center().z) * s

## `node`'s transform in `root`'s space (works before either is in the tree).
static func _relative_transform(root: Node3D, node: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var at: Node = node
	while at != null and at != root:
		if at is Node3D:
			xf = (at as Node3D).transform * xf
		at = at.get_parent()
	return xf

## The chest's place this frame (the snapshot's).
func drive(at: Vector3) -> void:
	position = at

func display_name() -> String:
	return tr("Enchanted Chest") if chest_kind == "chest_rare" else tr("Chest")

func _update_display() -> void:
	var glow: Color = GLOW[chest_kind]
	label.text = display_name()
	label.modulate = glow.lightened(0.35)
	var look: Dictionary = LOOK[chest_kind]
	light.light_color = glow
	for mesh in _rim_meshes:
		(mesh as GeometryInstance3D).set_instance_shader_parameter("tint", glow)
	pool.set_instance_shader_parameter("tint", glow)
	beam.set_instance_shader_parameter("tint", glow)
	for entry: Array in _insides:
		(entry[0] as GeometryInstance3D).set_instance_shader_parameter("inside_tint", glow)
	_pulse(0.5)
	var rare := chest_kind == "chest_rare"
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.7, 1.0])
	var hot := glow.lightened(0.3)
	ramp.colors = PackedColorArray([Color(hot, 0.0), Color(hot, 1.0), Color(glow, 0.7), Color(glow, 0.0)])
	particles.color_ramp = ramp
	particles.amount = look["motes"]
	particles.lifetime = 1.8 if rare else 2.2
	particles.emission_sphere_radius = 0.5 if rare else 0.38
	particles.initial_velocity_max = 0.45 if rare else 0.25
	particles.scale_amount_max = 1.5 if rare else 1.0

## Breathing glow, 0..1: the light, pool, shaft and rim swell together.
func _pulse(t: float) -> void:
	var look: Dictionary = LOOK[chest_kind]
	# open, the light rises out of the chest (a hand's breadth over the rim:
	# inside, its walls a few centimetres off it burnt white) and the shaft
	# with it
	light.position.y = lerpf(LIGHT_SHUT_Y, LIGHT_OPEN_Y, lid_open)
	light.light_energy = look["light"] * (0.8 + 0.35 * t) * (1.0 + _flare)
	pool.set_instance_shader_parameter("strength", look["pool"] * (0.75 + 0.35 * t) * (1.0 + 0.25 * lid_open))
	beam.set_instance_shader_parameter("strength", look["beam"] * (0.7 + 0.4 * t) * (1.0 + 0.5 * lid_open + _flare * 0.5))
	for mesh in _rim_meshes:
		(mesh as GeometryInstance3D).set_instance_shader_parameter("strength", look["rim"] * (0.6 + 0.6 * t))
	for entry: Array in _insides:
		(entry[0] as GeometryInstance3D).set_instance_shader_parameter("inside_glow",
			float(entry[1]) * lid_open * (0.85 + 0.25 * t + _flare * 0.6))

func _process(delta: float) -> void:
	if is_collected or light == null:
		return
	if is_open and Time.get_ticks_msec() / 1000.0 >= _open_until \
			and not (_still_open.is_valid() and bool(_still_open.call())):
		_shut()
	_flare = maxf(0.0, _flare - delta * 1.6)
	# A slow breathing glow; the enchanted one pulses faster.
	_pulse(0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * float(LOOK[chest_kind]["speed"]) + _phase))

## The inside faces (material "ChestInside") take chest_inside.gdshader; the
## lid's hollow glows less than the floor.
func _dress_inside(mesh: MeshInstance3D) -> void:
	if mesh.mesh == null:
		return
	for i in mesh.mesh.get_surface_count():
		var source := mesh.mesh.surface_get_material(i)
		if source == null or source.resource_name != "ChestInside":
			continue
		if _inside_material == null:
			_inside_material = ShaderMaterial.new()
			_inside_material.shader = load(INSIDE_SHADER)
			_inside_material.set_shader_parameter("noise", load(NOISE_TEX))
		mesh.set_surface_override_material(i, _inside_material)
		_insides.append([mesh, 0.1 if mesh.name == "Lid" else 1.0])
		mesh.set_instance_shader_parameter("inside_glow", 0.0)

## The player opened it (the window, or Z's take): the lid jolts, swings up
## and settles, dust and motes leave the opening, the light flares. It stays
## up while `still_open` says so, and at least `hold` seconds.
func open_lid(still_open: Callable = Callable(), hold: float = LID_HOLD) -> void:
	if still_open.is_valid():
		_still_open = still_open
	_open_until = maxf(_open_until, Time.get_ticks_msec() / 1000.0 + hold)
	if is_open or is_collected or lid == null:
		return
	is_open = true
	if _lid_tween != null:
		_lid_tween.kill()
	_lid_tween = create_tween()
	# the lid lifts a crack and catches (the latch giving), then swings
	_lid_tween.tween_property(self, "lid_open", 0.06, 0.07).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_lid_tween.tween_property(self, "lid_open", 0.045, 0.05)
	_lid_tween.tween_callback(_burst)
	_lid_tween.tween_property(self, "lid_open", 1.0, LID_SWING).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## The window left a chest that still holds something: the lid drops shut.
func _shut() -> void:
	is_open = false
	_still_open = Callable()
	if _lid_tween != null:
		_lid_tween.kill()
	_lid_tween = create_tween()
	_lid_tween.tween_property(self, "lid_open", 0.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_lid_tween.tween_property(self, "lid_open", 0.03, 0.06).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_lid_tween.tween_property(self, "lid_open", 0.0, 0.07).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

## What leaves the opening as the lid gives: a burst of motes in the chest's
## colour rising out of it, a soft breath of dust, the light flaring.
func _burst() -> void:
	_flare = 0.8 if chest_kind == "chest_rare" else 0.6
	if DisplayServer.get_name() == "headless" or not is_inside_tree():
		return
	var glow: Color = GLOW[chest_kind]
	var top := _opening_height()
	var motes := RisingMotes.make(0.22, 4.0, glow, 24 if chest_kind == "chest_rare" else 18, 1.4,
		Vector2(0.5, 1.5), Vector2(0.006, 0.014), true)
	motes.name = "OpenMotes"
	RisingMotes.set_band(motes, Vector2(0.3, 0.12))
	# round sparks of light, not streaks: they drift up, they are not thrown
	(motes.process_material as ShaderMaterial).set_shader_parameter("stretch", 0.004)
	(motes.process_material as ShaderMaterial).set_shader_parameter("energy", 0.75)
	model_root.add_child(motes)
	motes.position = Vector3(0.0, top - 0.05, 0.0)
	motes.emitting = true
	var gone := motes.create_tween()
	gone.tween_interval(2.4)
	gone.tween_callback(motes.queue_free)
	var dust := Color(0.62, 0.55, 0.46).lerp(glow, 0.25)
	FlipbookFX.play(self, global_position + Vector3.UP * top, [
		{"atlas": "smoke_puff_8x8_1k", "size": 0.95, "height": 0.18, "fps": 30.0, "tint": dust, "opacity": 0.3},
	], {"life": 1.2, "name": "ChestDust"})

## Where the opening is over the chest's feet (the lid's hinge height).
func _opening_height() -> float:
	if lid == null:
		return 0.3
	return (global_transform.affine_inverse() * lid.global_position).y

## The snapshot no longer carries it (emptied or expired): it shrinks away.
func despawn() -> void:
	if is_collected:
		return
	is_collected = true
	label.visible = false
	particles.emitting = false
	light.visible = false
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ONE * 0.001, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y", position.y + 0.4, 0.25)
	tween.chain().tween_callback(queue_free)
