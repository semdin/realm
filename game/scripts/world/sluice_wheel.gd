extends Node3D
class_name SluiceWheel

## The sluice wheel by the Wheelwarden (the run view's `chime`: {at, radius, ringer,
## start_tick, end_tick, ready_tick}, server ticks). Drawn from what the server
## says, on its clock (RealmSession.server_tick):
##
##   the prop     an iron hand-wheel on the stone post at `at`, in a cold light,
##                a few motes drifting up off the ground it is worked from
##                (`radius`, where standing turns it) while it is ready; dim
##                and still while it cools down (before `ready_tick`)
##   turning      from `start_tick` to `end_tick` a `ringer` stands there: the
##                wheel spins, the light swells, motes stream up round it, the
##                sluice grinds now and then, and a channel bar over the
##                worker's head fills to `end_tick` (pinned on screen like a
##                speech bubble, on its own layer so nothing in the world tints it)
##
## The server runs it and breaks it off (a hit or a blow given); this only shows
## it. The Wheelwarden seized by the flood is the boss's own look (CreatureView).

const GLOW := Color(0.62, 0.92, 0.86)
const MOTE := Color(0.66, 0.9, 0.86)
const BAR := Color(0.45, 0.8, 0.76)
const RING_SOUND := "passage_stone"
const RING_EVERY := 1.3
## Over the ringer's feet.
const BAR_HEIGHT := 2.55
const BAR_RANGE := 60.0
const BAR_WIDTH := 170.0

## main.gd (session, drawn, camera, _ground).
var game: Node
## The run view's chime (empty: none in this run).
var data: Dictionary = {}
## What was seen (the check reads them): the ringer and the share of its
## channel now, and every ringing seen (ringer, start_tick).
var ringing := false
var progress := 0.0
var rings_seen: Dictionary = {}
var _prop: Node3D = null
var _wheel: Node3D = null
var _light: OmniLight3D = null
var _motes: GPUParticles3D = null
var _layer: CanvasLayer = null
var _card: PanelContainer = null
var _bar: ProgressBar = null
var _bell_wait := 0.0

func _init() -> void:
	name = "SluiceWheel"

func _now() -> float:
	return float(game.session.server_tick()) if game != null and game.session != null else 0.0

## The run view's `chime` (null: the run has none).
func sync(chime: Variant) -> void:
	if not (chime is Dictionary):
		data = {}
		_hide()
		return
	var first := data.is_empty()
	data = chime
	if first:
		_build()

static func _vec(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO

func _build() -> void:
	var at := _vec(data.get("at"))
	if game != null and game.has_method("_ground"):
		at = game._ground(at)
	_prop = Node3D.new()
	_prop.name = "Chime"
	add_child(_prop)
	_prop.global_position = at
	if DisplayServer.get_name() == "headless":
		return
	_build_wheel()
	_light = OmniLight3D.new()
	_light.light_color = GLOW
	_light.light_energy = 1.0
	_light.omni_range = 6.0
	_light.shadow_enabled = false
	_light.position = Vector3(0, 1.5, 0)
	_prop.add_child(_light)
	_motes = RisingMotes.make(maxf(0.8, float(data.get("radius", 2.6))), 4.0, MOTE, 40, 2.2,
		Vector2(0.25, 0.9), Vector2(0.012, 0.03))
	_motes.position.y = 0.05
	_prop.add_child(_motes)
	_motes.emitting = true
	_build_bar()

## The iron hand-wheel, its axle level, turned while someone works it.
func _build_wheel() -> void:
	_wheel = Node3D.new()
	_wheel.name = "Wheel"
	_wheel.position = Vector3(0, 1.55, 0)
	_prop.add_child(_wheel)
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.17, 0.16, 0.15)
	iron.metallic = 0.75
	iron.roughness = 0.5
	var rim := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.52
	torus.outer_radius = 0.62
	rim.mesh = torus
	rim.material_override = iron
	rim.rotation.z = PI * 0.5
	_wheel.add_child(rim)
	var hub := MeshInstance3D.new()
	var drum := CylinderMesh.new()
	drum.top_radius = 0.1
	drum.bottom_radius = 0.1
	drum.height = 0.2
	hub.mesh = drum
	hub.material_override = iron
	hub.rotation.z = PI * 0.5
	_wheel.add_child(hub)
	for k in 4:
		var spoke := MeshInstance3D.new()
		var bar := BoxMesh.new()
		bar.size = Vector3(0.05, 1.08, 0.06)
		spoke.mesh = bar
		spoke.material_override = iron
		spoke.rotation.x = PI * 0.25 * k
		_wheel.add_child(spoke)

## The channel bar: a small midnight card with the gauge, over the ringer.
func _build_bar() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 0
	add_child(_layer)
	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := HudKit.panel(0.82, 5, 0.75).duplicate() as StyleBoxFlat
	box.set_content_margin_all(6)
	_card.add_theme_stylebox_override("panel", box)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 3)
	_card.add_child(column)
	var label := HudKit.label(tr("Turning the sluice wheel"), 13, HudKit.GOLD_LT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(label)
	_bar = ProgressBar.new()
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.custom_minimum_size = Vector2(BAR_WIDTH, 9)
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.0
	HudKit.style_gauge(_bar, BAR)
	column.add_child(_bar)
	_card.visible = false
	_layer.add_child(_card)

func _hide() -> void:
	ringing = false
	progress = 0.0
	if _card != null:
		_card.visible = false

func _process(delta: float) -> void:
	if data.is_empty():
		return
	var now := _now()
	var ringer := int(data.get("ringer", 0))
	var start := float(data.get("start_tick", 0))
	var end := float(data.get("end_tick", 0))
	ringing = ringer != 0 and now < end and end > start
	progress = clampf((now - start) / maxf(1.0, end - start), 0.0, 1.0) if ringing else 0.0
	if ringing:
		rings_seen["%d@%d" % [ringer, int(start)]] = true
	var can_ring := now >= float(data.get("ready_tick", 0))
	if _wheel != null and ringing:
		_wheel.rotate_x(delta * 2.4)
	var t := Time.get_ticks_msec() * 0.001
	if _light != null:
		var want := (1.6 + 1.6 * progress) * (0.85 + 0.15 * sin(t * 9.0)) if ringing else (1.0 if can_ring else 0.35)
		_light.light_energy = lerpf(_light.light_energy, want, minf(1.0, delta * 6.0))
	if _motes != null:
		_motes.emitting = ringing or can_ring
		RisingMotes.set_rate(_motes, 0.4 + 0.6 * progress if ringing else 0.22)
	if ringing:
		_bell_wait -= delta
		if _bell_wait <= 0.0:
			_bell_wait = RING_EVERY
			var audio := get_node_or_null("/root/AudioManager")
			if audio != null and _prop != null:
				audio.call("play_sound_at", RING_SOUND, _prop.global_position + Vector3.UP, self)
	else:
		_bell_wait = 0.0
	_pin_bar(ringer)

## The bar over the ringer's head, sized a little down with distance; hidden
## behind the camera, beyond BAR_RANGE or when nobody rings.
func _pin_bar(ringer: int) -> void:
	if _card == null:
		return
	var cam := get_viewport().get_camera_3d()
	var drawn: Dictionary = game.drawn if game != null else {}
	var shown := ringing and cam != null and drawn.has(ringer)
	var at := (drawn.get(ringer, Vector3.ZERO) as Vector3) + Vector3(0, BAR_HEIGHT, 0)
	shown = shown and not cam.is_position_behind(at) and cam.global_position.distance_to(at) <= BAR_RANGE
	_card.visible = shown
	if not shown:
		return
	_bar.value = progress
	var size := _card.get_combined_minimum_size()
	_card.size = size
	var s := clampf(9.0 / maxf(cam.global_position.distance_to(at), 0.01), 0.75, 1.0)
	_card.pivot_offset = Vector2(size.x * 0.5, size.y)
	_card.scale = Vector2(s, s)
	_card.position = cam.unproject_position(at) - Vector2(size.x * 0.5, size.y)
