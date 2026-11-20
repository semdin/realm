extends Node3D
class_name ChestView

## A loot chest on the ground: every kill that dropped items leaves ONE chest
## holding them (oril goes straight to the purse). Right-clicking it opens the
## chest window (LootWindow); Z takes everything that fits. A plain chest glows
## warm gold, a chest that holds an enchanted piece (KIND_CHEST_RARE) violet.
## The glow is layered, all of it from the game's own VFX maps:
##   ground   the light it spills (chest_pool): a hot contact glow at its foot,
##            caustic filaments crawling through flow-warped erosion noise,
##            faint rays over the ground, an edge the noise tears
##   seam     what lies inside leaking through the crack under the lid, a thin
##            flickering line of light (chest_rim, the model's overlay); an
##            enchanted chest also has arcane veins crawling over its boards
##   shaft    a soft volume of light over it (chest_beam on an open cylinder):
##            short on a plain chest, a tall pillar seen from afar on an
##            enchanted one
##   glints   star flares winking on its corners, lock and lid (chest_glints)
##   motes    sparks drifting up off it (RisingMotes, on the GPU)
##   light    a real shadowless light, faded out with distance
## Every layer breathes on its own on the GPU (TIME and a per-chest phase): an
## idle chest runs no script at all; materials, meshes and textures are shared
## by every chest of a kind.
##
## It only draws: the chest is a snapshot entity (main.gd hands its position
## over), what it holds comes from the server when it is opened, and it goes
## when the snapshot no longer carries it.
##
## Opened (main.gd: the chest window, or Z), its lid (the model's own "Lid",
## split off by tools/art/split_chest.py, hinged on the back edge) jolts, then
## swings up and settles past upright; a breath of dust and a burst of motes in
## the chest's colour leave the opening, the light flares, and the inside
## (chest_inside.gdshader) glows up from the floor, a ring of light runs out
## over the ground, a bloom swells over it and every glint winks at once; the
## seam's light goes out as the lid lifts. It stays open while the
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
const GLINT_SHADER := "res://assets/shaders/loot/chest_glints.gdshader"
const NOISE_TEX := "res://assets/vfx/tex/noise_erosion_512.png"
const FLOW_TEX := "res://assets/vfx/tex/noise_flow_512.png"
const STAR_TEX := "res://assets/vfx/tex/star_flare_256.png"
const GLOW_TEX := "res://assets/vfx/tex/soft_glow_512.png"
## The ground plane under a chest (metres across; chest_pool's `size`).
const POOL_SIZE := 3.4
## The seam under the lid in the model's own space (the split script's rim).
const SEAM_Y := 0.238
## Where the shaft starts over the feet: just over the lid's top (0.47 m), so
## none of it stands in the wood.
const BEAM_FOOT := 0.5
## The lid fully open (degrees back from shut: a little past upright, resting
## on its hinge), how long the swing takes, and how long Z's take keeps it up.
const LID_OPEN_DEGREES := 108.0
const LID_SWING := 0.42
const LID_HOLD := 1.2
## The light's height over the feet, shut and open.
const LIGHT_SHUT_Y := 0.22
const LIGHT_OPEN_Y := 0.5
const GLOW := {"chest": Color(1.0, 0.78, 0.36), "chest_rare": Color(0.66, 0.42, 1.0)}
## Per kind: light energy, pool, shaft (strength, height, radius), rim, seam
## leak and veins, glints, motes and the breathing's speed.
const LOOK := {
	"chest": {"light": 1.25, "pool": 1.0, "beam": 0.6, "beam_h": 1.7, "beam_r": 0.16, "rim": 0.12,
		"leak": 1.0, "veins": 0.0, "glints": 6, "motes": 10, "speed": 1.6},
	"chest_rare": {"light": 1.6, "pool": 1.15, "beam": 0.85, "beam_h": 4.6, "beam_r": 0.16, "rim": 0.22,
		"leak": 1.15, "veins": 1.0, "glints": 10, "motes": 18, "speed": 2.4},
}
## Where the glints sit, in the chest's own metres (0.9 m across, the lid's
## top near 0.46 m): its top corners and edges, the lock, the bands.
const GLINT_SPOTS := [
	Vector3(-0.4, 0.44, 0.17), Vector3(0.4, 0.44, 0.17), Vector3(0.0, 0.29, 0.22), Vector3(-0.21, 0.5, 0.05),
	Vector3(0.24, 0.49, -0.06), Vector3(0.43, 0.3, -0.18), Vector3(-0.43, 0.3, -0.17), Vector3(0.1, 0.52, 0.12),
	Vector3(-0.28, 0.2, 0.22), Vector3(0.3, 0.18, 0.22),
]
## The light fades out from this far (metres) over FADE_LENGTH: a far chest's
## light costs nothing; its glow layers carry it.
const LIGHT_FADE_FROM := 22.0
const LIGHT_FADE_LENGTH := 8.0
## The opening: the flare's length (seconds) and the ground ring's run.
const FLARE_SECONDS := 0.7
const RING_SECONDS := 0.9
## The chest opens from this close (the server's CHEST_REACH).
const PICK_RANGE := 7.0

static func is_chest(kind: int) -> bool:
	return kind == KIND_CHEST or kind == KIND_CHEST_RARE

## "chest" or "chest_rare".
var chest_kind := "chest"
var model_root: Node3D
var label: Label3D
var particles: GPUParticles3D
var pool: MeshInstance3D
var beam: MeshInstance3D
var glints: MeshInstance3D
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
		_show_open()
var is_open := false
var _insides: Array = []
## Held open while this says so (main.gd: the window is on this chest), and
## at least until _open_until (seconds).
var _still_open: Callable = Callable()
var _open_until := 0.0
var _lid_tween: Tween = null
## The light's flare as it opens (1 -> 0 over FLARE_SECONDS) and the ground
## ring's run (0 -> 1, then off).
var _flare := 0.0
var _ring := 1.0
static var _inside_material: ShaderMaterial = null
## One material per layer for every chest (instance uniforms tell them
## apart), and one glint mesh per kind.
static var _materials: Dictionary = {}
static var _glint_meshes: Dictionary = {}

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
		var rim := _material("rim")
		lid = model.find_child("Lid", true, false) as Node3D
		for mesh in model.find_children("*", "MeshInstance3D", true, false):
			(mesh as MeshInstance3D).material_overlay = rim
			_rim_meshes.append(mesh)
			_dress_inside(mesh as MeshInstance3D)
	model_root.rotation.y = randf() * TAU
	_build_glow()
	_update_display()
	# nothing to run until it opens: every layer breathes on its own
	set_process(false)

## The shared material of a layer ("pool", "beam", "rim", "glints").
static func _material(layer: String) -> ShaderMaterial:
	if _materials.has(layer):
		return _materials[layer]
	var material := ShaderMaterial.new()
	match layer:
		"pool":
			material.shader = load(POOL_SHADER)
			material.render_priority = -1
			material.set_shader_parameter("noise", load(NOISE_TEX))
			material.set_shader_parameter("flow", load(FLOW_TEX))
			material.set_shader_parameter("size", POOL_SIZE)
		"beam":
			material.shader = load(BEAM_SHADER)
			material.set_shader_parameter("noise", load(NOISE_TEX))
		"rim":
			material.shader = load(RIM_SHADER)
			material.set_shader_parameter("noise", load(NOISE_TEX))
		"glints":
			material.shader = load(GLINT_SHADER)
			material.render_priority = 1
			material.set_shader_parameter("star", load(STAR_TEX))
			material.set_shader_parameter("glow", load(GLOW_TEX))
	_materials[layer] = material
	return material

## The pool, shaft, glints, light, name and motes.
func _build_glow() -> void:
	var look: Dictionary = LOOK[chest_kind]
	pool = MeshInstance3D.new()
	pool.name = "GlowPool"
	pool.position = Vector3(0, 0.03, 0)
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pool.mesh = _pool_mesh()
	pool.material_override = _material("pool")
	add_child(pool)
	var shaft := CylinderMesh.new()
	shaft.top_radius = float(look["beam_r"]) * 1.25
	shaft.bottom_radius = float(look["beam_r"])
	shaft.height = float(look["beam_h"])
	shaft.radial_segments = 20
	shaft.rings = 1
	shaft.cap_top = false
	shaft.cap_bottom = false
	beam = MeshInstance3D.new()
	beam.name = "Beam"
	# it rises out of the lid, narrower than the chest is deep: never in front of it
	beam.position = Vector3(0, BEAM_FOOT + float(look["beam_h"]) * 0.5, 0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.mesh = shaft
	beam.material_override = _material("beam")
	beam.set_instance_shader_parameter("height", float(look["beam_h"]))
	add_child(beam)
	glints = MeshInstance3D.new()
	glints.name = "Glints"
	glints.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glints.mesh = _glint_mesh(chest_kind, int(look["glints"]))
	glints.material_override = _material("glints")
	glints.custom_aabb = AABB(Vector3(-1.2, -0.5, -1.2), Vector3(2.4, 2.2, 2.4))
	model_root.add_child(glints)
	light = OmniLight3D.new()
	light.name = "Light"
	light.position = Vector3(0, LIGHT_SHUT_Y, 0)
	light.light_color = Color(1, 0.8, 0.35)
	light.light_energy = 0.9
	light.light_specular = 0.25
	light.omni_range = 2.3
	light.omni_attenuation = 1.2
	light.distance_fade_enabled = true
	light.distance_fade_begin = LIGHT_FADE_FROM
	light.distance_fade_length = LIGHT_FADE_LENGTH
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

## The pool's disc (shared): a fan over the circle the light can reach, a
## fifth fewer pixels than the square it is mapped on.
static func _pool_mesh() -> ArrayMesh:
	if _glint_meshes.has("pool"):
		return _glint_meshes["pool"]
	var points := PackedVector3Array([Vector3.ZERO])
	var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
	var index := PackedInt32Array()
	var radius := POOL_SIZE * 0.47
	var segments := 40
	for i in segments:
		var a := TAU * float(i) / float(segments)
		var at := Vector3(cos(a), 0.0, sin(a)) * radius
		points.append(at)
		uvs.append(Vector2(at.x, at.z) / POOL_SIZE + Vector2(0.5, 0.5))
		index.append_array(PackedInt32Array([0, 1 + (i + 1) % segments, 1 + i]))
	var normals := PackedVector3Array()
	normals.resize(points.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_glint_meshes["pool"] = mesh
	return mesh

## The glints of a kind: `count` quads, each with all four corners at its
## spot (chest_glints turns and sizes it), plus the opening's bloom (seed -1).
static func _glint_mesh(kind: String, count: int) -> ArrayMesh:
	if _glint_meshes.has(kind):
		return _glint_meshes[kind]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind)
	var points := PackedVector3Array()
	var uvs := PackedVector2Array()
	var seeds := PackedVector2Array()
	var index := PackedInt32Array()
	var spots: Array = GLINT_SPOTS.slice(0, mini(count, GLINT_SPOTS.size()))
	spots.append(Vector3(0.0, 0.42, 0.0))
	for i in spots.size():
		var bloom := i == spots.size() - 1
		var seed := -1.0 if bloom else rng.randf()
		var size := 0.55 if bloom else rng.randf_range(0.07, 0.12)
		var base := points.size()
		for corner: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			points.append(spots[i])
			uvs.append(corner)
			seeds.append(Vector2(seed, size))
		index.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = seeds
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_glint_meshes[kind] = mesh
	return mesh

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
	var look: Dictionary = LOOK[chest_kind]
	label.text = display_name()
	label.modulate = glow.lightened(0.35)
	light.light_color = glow
	var phase := _phase
	var speed := float(look["speed"])
	# Instance uniforms are written once every material is on the mesh (the
	# inside's override came after the overlay): a material added later
	# rebuilds the mesh's set and drops what was written before it.
	for mesh in _rim_meshes:
		var body := mesh as GeometryInstance3D
		# the seam: the body's top, the lid's own floor
		body.set_instance_shader_parameter("seam_y", 0.0 if mesh == lid else SEAM_Y)
		body.set_instance_shader_parameter("seam_dir", -1.0 if mesh == lid else 1.0)
		body.set_instance_shader_parameter("tint", glow)
		body.set_instance_shader_parameter("strength", float(look["rim"]))
		body.set_instance_shader_parameter("veins", float(look["veins"]))
		_layer(body, phase, speed)
	for layer: GeometryInstance3D in [pool, beam, glints]:
		layer.set_instance_shader_parameter("tint", glow)
		_layer(layer, phase, speed)
	pool.set_instance_shader_parameter("strength", float(look["pool"]))
	glints.set_instance_shader_parameter("strength", 1.0)
	for entry: Array in _insides:
		(entry[0] as GeometryInstance3D).set_instance_shader_parameter("inside_tint", glow)
	_show_open()
	if particles == null and DisplayServer.get_name() != "headless":
		var rare := chest_kind == "chest_rare"
		particles = RisingMotes.make(0.4 if rare else 0.32, 4.0, glow, int(look["motes"]), 2.0 if rare else 2.4,
			Vector2(0.2, 0.55 if rare else 0.4), Vector2(0.006, 0.013 if rare else 0.011))
		particles.name = "Motes"
		RisingMotes.set_inner(particles, 0.75)
		(particles.process_material as ShaderMaterial).set_shader_parameter("stretch", 0.004)
		add_child(particles)
		particles.position = Vector3(0, 0.18, 0)
		particles.emitting = true

static func _layer(layer: GeometryInstance3D, phase: float, speed: float) -> void:
	layer.set_instance_shader_parameter("phase", phase)
	layer.set_instance_shader_parameter("speed", speed)

## What the lid and the opening's flare do to the layers: the seam's light
## goes out as the lid lifts, the inside lights up, the shaft swells, the
## glints and the bloom flash, the light flares and rises out of it.
func _show_open() -> void:
	if light == null:
		return
	var look: Dictionary = LOOK[chest_kind]
	var flash := _flare * _flare
	light.position.y = lerpf(LIGHT_SHUT_Y, LIGHT_OPEN_Y, lid_open)
	light.light_energy = float(look["light"]) * (1.0 - 0.25 * lid_open + 0.7 * flash)
	beam.set_instance_shader_parameter("strength", float(look["beam"]) * (1.0 + 0.45 * lid_open + 1.6 * flash))
	glints.set_instance_shader_parameter("flash", flash)
	pool.set_instance_shader_parameter("burst", _ring if _ring < 1.0 else 0.0)
	for mesh in _rim_meshes:
		(mesh as GeometryInstance3D).set_instance_shader_parameter("leak", float(look["leak"]) * clampf(1.0 - lid_open * 3.0, 0.0, 1.0))
	for entry: Array in _insides:
		(entry[0] as GeometryInstance3D).set_instance_shader_parameter("inside_glow",
			float(entry[1]) * lid_open * (1.0 + _flare * 0.6))

func _process(delta: float) -> void:
	if is_collected or light == null:
		set_process(false)
		return
	if is_open and Time.get_ticks_msec() / 1000.0 >= _open_until \
			and not (_still_open.is_valid() and bool(_still_open.call())):
		_shut()
	_flare = maxf(0.0, _flare - delta / FLARE_SECONDS)
	if _ring < 1.0:
		_ring = minf(1.0, _ring + delta / RING_SECONDS)
	_show_open()
	# an idle chest, shut and settled, runs nothing
	if not is_open and _flare <= 0.0 and _ring >= 1.0 and (_lid_tween == null or not _lid_tween.is_running()):
		set_process(false)

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
	set_process(true)
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
	set_process(true)
	_lid_tween.tween_property(self, "lid_open", 0.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_lid_tween.tween_property(self, "lid_open", 0.03, 0.06).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_lid_tween.tween_property(self, "lid_open", 0.0, 0.07).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

## What leaves the opening as the lid gives: a burst of motes in the chest's
## colour rising out of it, a soft breath of dust, the light flaring, the
## bloom and the glints flashing, a ring of light running out over the ground.
func _burst() -> void:
	_flare = 1.0
	_ring = 0.0
	set_process(true)
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
	if particles != null:
		particles.emitting = false
	light.visible = false
	glints.visible = false
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ONE * 0.001, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y", position.y + 0.4, 0.25)
	tween.chain().tween_callback(queue_free)
