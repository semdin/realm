extends Node3D
class_name DummyView

## A training dummy in the yard, as the server reports it: a duelling-practice
## figure built here from primitives and lathed profiles with the CC0 hessian
## and medieval wood textures (Poly Haven) - crossed oak planks for a foot, a
## weathered post, a stuffed hessian sack cinched with rope, a crossbar in
## burlap sleeves with straw bursting from the cuffs, a tied sack head with
## stitched eyes and a painted target on the chest and back - turned to face
## the yard (creature_views.json `training_dummy.faces`). "Training Dummy" and
## its health stand over it. It sways a little, rocks on a hit, shows what a
## skill does to it (StatusFX) and never strikes back; at 0 it stands up whole
## and says so. Presentation only.

const HESSIAN := "res://assets/textures/pbr/hessian_230/hessian_230_%s_1k.jpg"
const WOOD := "res://assets/textures/pbr/medieval_wood/medieval_wood_%s_2k.jpg"
const HEAD_TOP := 2.34
const RESET_COLOUR := Color(0.5, 1.0, 0.5)
const HIT_HOLD_SECONDS := 0.5
## The label's size on screen (fixed_size): about 15 px a line.
const LABEL_PIXEL := 0.0008

var species := ""
var view := {}
var max_hp := 800
var hp := 800
## Read by StatusFX, CombatView and main.gd.
var visuals: Node3D
var head_height := HEAD_TOP
var is_dead := false
var body_radius := 0.6
var elite := false
var is_boss := false
var enraged := false

## The whole figure but its foot: it sways and rocks.
var _pole: Node3D
var _label: Label3D
var _t := 0.0
var _faced := false
var _hit_hold_until := 0.0
static var _mats: Dictionary = {}

func setup(kind: int) -> bool:
	species = CreatureView.species_for_kind(kind)
	view = CreatureView.view_of(species)
	body_radius = float(view.get("body_radius", 0.6))
	var tables: Variant = RealmContent.table("spawn_tables")
	var config: Dictionary = (tables as Dictionary).get("dummy_config", {}) if tables is Dictionary else {}
	max_hp = maxi(1, int(config.get("max_hp", 800)))
	hp = max_hp
	_t = randf() * TAU
	_pole = Node3D.new()
	_pole.name = "Body"
	add_child(_pole)
	visuals = _pole
	if DisplayServer.get_name() != "headless":
		_build_body()
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.double_sided = false
	_label.font_size = 32
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0)
	_label.modulate = Color(0.6, 1.0, 0.6)
	_label.fixed_size = true
	_label.pixel_size = LABEL_PIXEL
	_label.visibility_range_end = 40.0
	_label.position.y = float(view.get("label_height", 2.75))
	add_child(_label)
	_update_label()
	return true

func apply_info(_info: Dictionary) -> void:
	pass

func set_kind(_kind: int) -> void:
	pass

func set_status(bits: int) -> void:
	StatusFX.update(self, bits)

func drive(drawn: Vector3, _yaw: float, _state: int, _delta: float) -> void:
	position = drawn
	if not _faced:
		_faced = true
		var yard: Array = view.get("faces", [])
		if yard.size() == 2:
			var to := Vector2(float(yard[0]) - drawn.x, float(yard[1]) - drawn.z)
			if to.length() > 1.0:
				_pole.rotation.y = atan2(to.x, to.y)

## A blow: the count goes down and the figure rocks; one that empties it
## stands it up whole (the server's reset) with a word over it.
func on_hit(event: Dictionary, _own: bool) -> void:
	var byte := int(event.get("hp", 255))
	_hit_hold_until = Time.get_ticks_msec() / 1000.0 + HIT_HOLD_SECONDS
	if byte <= 0:
		hp = max_hp
		FloatingText.spawn(get_parent(), global_position + Vector3(0, 2.4, 0), I18n.upper(tr("Dummy reset!")), RESET_COLOUR, 1.3)
	else:
		hp = _within_byte(hp - int(event.get("amount", 0)), byte)
	_update_label()
	var tween := create_tween()
	tween.tween_property(_pole, "rotation:z", 0.12, 0.06)
	tween.tween_property(_pole, "rotation:z", 0.0, 0.18)

## The snapshot's hp byte, every frame.
func set_health(byte: int) -> void:
	if Time.get_ticks_msec() / 1000.0 < _hit_hold_until:
		return
	var kept := _within_byte(hp, byte)
	if kept != hp:
		hp = kept
		_update_label()

func _within_byte(value: int, byte: int) -> int:
	if byte <= 0:
		return 0
	var high := int(floor(float(byte) / 255.0 * max_hp))
	var low := int(floor(float(byte - 1) / 255.0 * max_hp)) + 1
	return clampi(value, low, maxi(low, high))

func _update_label() -> void:
	_label.text = tr("Training Dummy\n%d / %d") % [hp, max_hp]

func _process(delta: float) -> void:
	_t += delta
	_pole.rotation.x = sin(_t * 1.2) * 0.02

# ------------------------------------------------------------------ the figure

func _build_body() -> void:
	var sack := _pbr(HESSIAN, Color(0.86, 0.76, 0.6), Vector3(2.0, 2.0, 1.0))
	var sack_dark := _pbr(HESSIAN, Color(0.62, 0.52, 0.38), Vector3(2.0, 2.0, 1.0))
	var wood := _pbr(WOOD, Color(0.72, 0.6, 0.48), Vector3(0.6, 1.5, 1.0))
	var rope := StandardMaterial3D.new()
	rope.albedo_color = Color(0.55, 0.45, 0.3)
	rope.roughness = 1.0
	var straw := StandardMaterial3D.new()
	straw.albedo_color = Color(0.86, 0.72, 0.38)
	straw.roughness = 0.9
	straw.cull_mode = BaseMaterial3D.CULL_DISABLED
	var paint_red := StandardMaterial3D.new()
	paint_red.albedo_color = Color(0.58, 0.1, 0.08)
	paint_red.roughness = 0.85
	var paint_cream := StandardMaterial3D.new()
	paint_cream.albedo_color = Color(0.9, 0.84, 0.68)
	paint_cream.roughness = 0.85
	var thread := StandardMaterial3D.new()
	thread.albedo_color = Color(0.12, 0.08, 0.06)

	# foot: two crossed planks and the post
	for yaw in [0.0, PI * 0.5]:
		var plank := _box(Vector3(1.3, 0.12, 0.2), wood)
		plank.position = Vector3(0, 0.06, 0)
		plank.rotation.y = yaw + 0.3
		add_child(plank)
	var post := _lathe([Vector2(0.095, 0.0), Vector2(0.085, 1.0), Vector2(0.08, 2.1), Vector2(0.06, 2.16)], wood, 10, Vector2(1.0, 2.0))
	_pole.add_child(post)
	# body: a stuffed sack, fullest at the chest
	var torso := _lathe([Vector2(0.0, 0.88), Vector2(0.2, 0.9), Vector2(0.3, 1.02), Vector2(0.34, 1.25),
		Vector2(0.36, 1.48), Vector2(0.33, 1.66), Vector2(0.22, 1.76), Vector2(0.11, 1.8)], sack, 18, Vector2(2.0, 1.0))
	_pole.add_child(torso)
	for band in [[1.08, 0.31], [1.6, 0.345]]:
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = float(band[1]) - 0.015
		tm.outer_radius = float(band[1]) + 0.025
		tm.rings = 24
		tm.ring_segments = 6
		tm.material = rope
		ring.mesh = tm
		ring.position.y = float(band[0])
		_pole.add_child(ring)
	# shoulders: the crossbar and its burlap sleeves, straw at the cuffs
	var bar := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.045
	bm.bottom_radius = 0.045
	bm.height = 1.5
	bm.radial_segments = 8
	bm.material = wood
	bar.mesh = bm
	bar.rotation.z = PI * 0.5
	bar.position.y = 1.62
	_pole.add_child(bar)
	for side in [-1.0, 1.0]:
		var sleeve := _lathe([Vector2(0.09, 0.0), Vector2(0.11, 0.12), Vector2(0.1, 0.38), Vector2(0.085, 0.46)], sack_dark, 10, Vector2(1.0, 1.0))
		sleeve.rotation.z = -side * PI * 0.5
		sleeve.position = Vector3(side * 0.24, 1.62, 0)
		_pole.add_child(sleeve)
		_tuft(straw, Vector3(side * 0.71, 1.62, 0), Vector3(side, 0, 0), 9, 0.2)
	_tuft(straw, Vector3(0, 0.9, 0), Vector3.DOWN, 12, 0.22)
	# head: a tied sack on the post
	var head := _lathe([Vector2(0.0, 1.84), Vector2(0.09, 1.85), Vector2(0.2, 1.94), Vector2(0.24, 2.08),
		Vector2(0.22, 2.22), Vector2(0.14, 2.31), Vector2(0.0, HEAD_TOP)], sack, 16, Vector2(1.5, 1.0))
	_pole.add_child(head)
	var tie := MeshInstance3D.new()
	var tt := TorusMesh.new()
	tt.inner_radius = 0.09
	tt.outer_radius = 0.13
	tt.ring_segments = 6
	tt.material = rope
	tie.mesh = tt
	tie.position.y = 1.86
	_pole.add_child(tie)
	_tuft(straw, Vector3(0, 1.82, 0), Vector3.UP, 8, 0.12)
	# stitched X eyes and a stitched mouth, on the side facing the yard
	for ex in [-0.085, 0.085]:
		for tilt in [0.75, -0.75]:
			var stitch := _box(Vector3(0.075, 0.012, 0.01), thread)
			stitch.position = Vector3(ex, 2.12, 0.225)
			stitch.rotation.z = tilt
			_pole.add_child(stitch)
	var mouth := _box(Vector3(0.12, 0.012, 0.01), thread)
	mouth.position = Vector3(0, 2.0, 0.232)
	_pole.add_child(mouth)
	# painted target, chest and back
	for z in [1.0, -1.0]:
		for ring in [[0.17, paint_red], [0.11, paint_cream], [0.05, paint_red]]:
			var disc := MeshInstance3D.new()
			var dm := CylinderMesh.new()
			dm.top_radius = float(ring[0])
			dm.bottom_radius = float(ring[0])
			dm.height = 0.01
			dm.radial_segments = 20
			dm.material = ring[1]
			disc.mesh = dm
			disc.rotation.x = PI * 0.5
			disc.position = Vector3(0, 1.36, z * (0.355 + (0.17 - float(ring[0])) * 0.03))
			_pole.add_child(disc)

func _pbr(pattern: String, tint: Color, uv: Vector3) -> StandardMaterial3D:
	var key := pattern + tint.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	var diff := pattern % "diff"
	if ResourceLoader.exists(diff):
		m.albedo_texture = load(diff)
	var nor := pattern % "nor_gl"
	if ResourceLoader.exists(nor):
		m.normal_enabled = true
		m.normal_texture = load(nor)
	var rough := pattern % "rough"
	if ResourceLoader.exists(rough):
		m.roughness_texture = load(rough)
	m.roughness = 1.0
	m.uv1_scale = uv
	_mats[key] = m
	return m

func _box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	b.material = mat
	mi.mesh = b
	return mi

## A surface of revolution about Y from (radius, height) points, bottom to
## top, with U around and V along the profile.
func _lathe(profile: Array, mat: Material, sides: int, uv_scale: Vector2) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length := 0.0
	var vs: Array[float] = [0.0]
	for i in range(1, profile.size()):
		length += (profile[i] as Vector2).distance_to(profile[i - 1])
		vs.append(length)
	for i in profile.size() - 1:
		var a: Vector2 = profile[i]
		var b: Vector2 = profile[i + 1]
		var slope := Vector2(b.y - a.y, -(b.x - a.x)).normalized()   # outward normal in (r, y)
		for k in sides:
			var t0 := TAU * float(k) / float(sides)
			var t1 := TAU * float(k + 1) / float(sides)
			var quad := [[a, t0, vs[i]], [b, t0, vs[i + 1]], [b, t1, vs[i + 1]], [a, t1, vs[i]]]
			for idx in [0, 2, 1, 0, 3, 2]:
				var q: Array = quad[idx]
				var pr: Vector2 = q[0]
				var th: float = q[1]
				st.set_normal(Vector3(cos(th) * slope.x, slope.y, sin(th) * slope.x).normalized())
				st.set_uv(Vector2(th / TAU * uv_scale.x, float(q[2]) / maxf(length, 0.001) * uv_scale.y))
				st.add_vertex(Vector3(cos(th) * pr.x, pr.y, sin(th) * pr.x))
	var mi := MeshInstance3D.new()
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	return mi

## A burst of straw: thin blades fanning out along `dir`.
func _tuft(mat: Material, at: Vector3, dir: Vector3, count: int, reach: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(at.x * 100.0) * 31 + int(at.y * 100.0) + count
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var basis := Basis.looking_at(-dir, Vector3.FORWARD if absf(dir.y) > 0.9 else Vector3.UP)
	for i in count:
		var spread := Vector3(rng.randf_range(-0.7, 0.7), rng.randf_range(-0.7, 0.7), -1.0).normalized()
		var tip := basis * spread * reach * rng.randf_range(0.6, 1.2)
		var side := tip.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized() * 0.022
		for v in [-side, side, tip]:
			st.set_normal(Vector3.UP)
			st.add_vertex(at + v)
	var mi := MeshInstance3D.new()
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pole.add_child(mi)
