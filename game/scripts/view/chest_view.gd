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

## Snapshot kinds of a chest (realm_proto KIND_CHEST / KIND_CHEST_RARE).
const KIND_CHEST := 0x1000
const KIND_CHEST_RARE := 0x1001
const CHEST_MODEL := "res://assets/models/environment/loot_chest.glb"
const WorldSign := preload("res://scripts/world/world_sign.gd")
const RIM_SHADER := "res://assets/shaders/loot/chest_rim.gdshader"
const POOL_SHADER := "res://assets/shaders/loot/chest_pool.gdshader"
const BEAM_SHADER := "res://assets/shaders/loot/chest_beam.gdshader"
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
	light.position = Vector3(0, 0.22, 0)
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
	light.light_energy = look["light"] * (0.8 + 0.35 * t)
	pool.set_instance_shader_parameter("strength", look["pool"] * (0.75 + 0.35 * t))
	beam.set_instance_shader_parameter("strength", look["beam"] * (0.7 + 0.4 * t))
	for mesh in _rim_meshes:
		(mesh as GeometryInstance3D).set_instance_shader_parameter("strength", look["rim"] * (0.6 + 0.6 * t))

func _process(_delta: float) -> void:
	if is_collected or light == null:
		return
	# A slow breathing glow; the enchanted one pulses faster.
	_pulse(0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * float(LOOK[chest_kind]["speed"]) + _phase))

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
