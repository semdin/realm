extends Node3D
class_name StairView

## The castle's moving staircases, drawn with the old game's flight art. The
## flights are simulated by the server and by the client core for prediction
## (realm_sim staircase.rs: a pure function of the tick); RealmSession.
## stair_parts gives every solid box of them as the player's own body sees it
## this frame - the deck, its two railings and the gates that are shut - and
## this poses the art on exactly those boxes every frame (no second clock: the
## stone moves where the body is carried). Nothing here collides: the core
## already does.
##
## A flight (built once per flight size, one mesh of three surfaces):
##   the deck slab and its 0.2 m stone steps (stone ashlar, sampled in the
##   flight's own space so it stays on the stone as it swings), an oak runner
##   on every step and the two railings in the castle's oak; no glowing edge
##   lines (a flight's state is shown by its wards and the warning line
##   below). Each step's top straddles the walked slope (the deck collider)
##   by half a step, so feet on the slope neither float nor sink more than
##   0.1 m.
## The gates are drawn as wards (stair_ward.gdshader): a shimmering veil of
## noise with embers along its edges, standing in the plane of the gate box
## the core collides with and as tall as it (its ragged crest licks a little
## higher and fades), so a body stops at the veil, never inside it; on the
## deck's two ends and across every landing a flight docks at, with a narrow
## glowing seam on the floor under a landing's veil (stair_threshold.gdshader),
## no wider than the gate. A veil stands while its gate is shut (violet:
## sealed), rises slowly in amber over the boarding warning, and sinks in gold
## when its gate opens.
##
## Near a flight that is swinging, or whose gates are shut for its warning
## before it swings, a line over the prompt says so (the old game's
## staircase warning): "Magical staircase: moving" / "...: gates closed".

const Kit = preload("res://maps/castle_interior/castle_kit.gd")
const WARD_SHADER := preload("res://assets/shaders/stair_ward.gdshader")
const THRESHOLD_SHADER := preload("res://assets/shaders/stair_threshold.gdshader")
const NOISE_TEX := "res://assets/vfx/tex/noise_erosion_512.png"
## Ward colours: open (board now), warning (leaving - stay off), sealed.
const WARD_OPEN := Color(1.0, 0.78, 0.36)
const WARD_WARN := Color(1.0, 0.42, 0.12)
const WARD_SEALED := Color(0.55, 0.32, 1.0)
## The deck's end gates are this tall (the landing gates 1.2 m).
const END_GATE_HEIGHT := 1.6
## How far a veil's ragged crest may lick over its gate's top (m, fading).
const VEIL_RISE := 0.7
## The floor seam under a landing's veil: this deep across the gate's line
## (the gate box is 0.3 m; a body stops ~0.5 m from the line).
const SEAM_DEPTH := 0.9
## Step height when the content does not say (maps.json staircases flight).
const STEP_HEIGHT := 0.2
## Seconds of the boarding warning when the content does not say.
const WARNING_SECONDS := 2.0
## How near a flight's deck (metres, across and up or down) the line shows.
const WARN_REACH := 7.0
const WARN_RISE := 5.0
const WARN_COLOUR := Color(1.0, 0.72, 0.36)

var session: Node
## What was drawn last frame (the check reads them): parts by kind, steps,
## and the decks' centres by flight.
var counts: Dictionary = {}
var treads := 0
var decks: Dictionary = {}
## Each flight's deck slab as posed: [Transform3D, size].
var deck_boxes: Dictionary = {}
## Each flight's phase by flight ("docked", "warning", "moving", "docking").
var phases: Dictionary = {}
## The warning line shown now ("" none; the check reads it).
var line_text := ""
var _line: Label

## flight -> {node: MeshInstance3D, steps: int, rise, run, width,
## deck_wards: [ward], landing: {key: ward}}; ward = {node, sill, closed, warn}
var _flights: Dictionary = {}
var _meshes: Dictionary = {}
var _noise: Texture2D
var _specs: Array = []

## A flight's walked surface ends as posed now: [low, high] (the slab's top
## at each end), [] when it is not in view.
func deck_ends(flight: int) -> Array:
	if not deck_boxes.has(flight):
		return []
	var t: Transform3D = deck_boxes[flight][0]
	var size: Vector3 = deck_boxes[flight][1]
	var top := t.origin + t.basis.y.normalized() * size.y * 0.5
	var a := top - t.basis.z.normalized() * size.z * 0.5
	var b := top + t.basis.z.normalized() * size.z * 0.5
	return [a, b] if a.y <= b.y else [b, a]

func _ready() -> void:
	name = "Staircases"
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_line = HudKit.label("", 16, WARN_COLOUR, HudKit.bold(), 4)
	_line.name = "StaircaseLine"
	_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line.anchor_left = 0.0
	_line.anchor_right = 1.0
	_line.anchor_top = 1.0
	_line.anchor_bottom = 1.0
	_line.offset_top = -204.0
	_line.offset_bottom = -178.0
	_line.hide()
	layer.add_child(_line)

func _process(delta: float) -> void:
	if session == null or String(session.status()) != "joined":
		return
	var parts: Array = session.stair_parts()
	if parts.is_empty():
		return
	var offset: Vector3 = session.copy_offset()
	counts = {}
	treads = 0
	decks = {}
	deck_boxes = {}
	phases = {}
	var end_shut := {}
	var landing_shut := {}
	for part: Dictionary in parts:
		var kind := String(part["kind"])
		counts[kind] = int(counts.get(kind, 0)) + 1
		var flight := int(part["flight"])
		var t: Transform3D = part["transform"]
		t.origin += offset
		var size: Vector3 = part["size"]
		match kind:
			"deck":
				decks[flight] = t.origin
				deck_boxes[flight] = [t, size]
				phases[flight] = String(part.get("phase", "docked"))
			"gate":
				if absf(size.y - END_GATE_HEIGHT) < 0.05:
					end_shut[flight] = true
				else:
					if not landing_shut.has(flight):
						landing_shut[flight] = []
					landing_shut[flight].append([t, size])
	for flight: int in deck_boxes:
		var f := _flight(flight, deck_boxes[flight][0], deck_boxes[flight][1])
		f["node"].transform = _flight_frame(f, deck_boxes[flight][0])
		treads += int(f["steps"])
		_pose_wards(f, String(phases[flight]), bool(end_shut.get(flight, false)),
			landing_shut.get(flight, []), delta)
	_warn(session.own_position())

# ------------------------------------------------------------------ flights

## The flight's frame (origin at its foot, z up the run, yaw only) from the
## deck slab's pose: the slab is the frame's (0, 0, 0)-(0, rise, run) slope,
## 0.3 m thick under it, tilted about x.
static func _deck_local(rise: float, run: float) -> Transform3D:
	var angle := atan2(rise, run)
	var mid := Vector3(0.0, rise * 0.5, run * 0.5)
	var up := Vector3(0.0, cos(angle), -sin(angle))
	return Transform3D(Basis(Vector3.RIGHT, -angle), mid - up * 0.15)

func _flight_frame(f: Dictionary, deck: Transform3D) -> Transform3D:
	return deck * (f["deck_local"] as Transform3D).affine_inverse()

func _flight(flight: int, deck: Transform3D, size: Vector3) -> Dictionary:
	if _flights.has(flight):
		return _flights[flight]
	var spec := _spec(flight)
	var ramp := size.z
	var angle := asin(clampf(deck.basis.z.normalized().y, -1.0, 1.0))
	var rise := ramp * sin(angle)
	var run := ramp * cos(angle)
	var width := size.x
	var step_h := float((spec.get("flight", {}) as Dictionary).get("step_height", STEP_HEIGHT))
	var steps := maxi(1, int(round(rise / maxf(step_h, 0.05))))
	var node := MeshInstance3D.new()
	node.name = "Flight%d" % flight
	node.mesh = _flight_mesh(rise, run, width, steps)
	add_child(node)
	var f := {"node": node, "steps": steps, "rise": rise, "run": run, "width": width,
		"deck_local": _deck_local(rise, run), "deck_wards": [], "landing": {},
		"warn_s": maxf(0.4, float((spec.get("timing", {}) as Dictionary).get("warning_ms", WARNING_SECONDS * 1000.0)) / 1000.0)}
	# the deck's end gates: across its foot and its head
	for end in [0, 1]:
		var at := Vector3(0.0, 0.0, -0.15) if end == 0 else Vector3(0.0, rise, run + 0.15)
		f["deck_wards"].append(_ward(node, Transform3D(Basis(), at), width, END_GATE_HEIGHT, 0.0))
	_flights[flight] = f
	return f

## This flight's maps.json staircase entry (castle_interior's, in order), {}
## when the content has none.
func _spec(flight: int) -> Dictionary:
	if _specs.is_empty():
		var maps: Variant = RealmContent.table("maps")
		if maps is Dictionary:
			for entry: Dictionary in (maps as Dictionary).get("staircases", []):
				if String(entry.get("map_id", "")) == "castle_interior":
					_specs.append(entry)
	return _specs[flight] if flight < _specs.size() else {}

## Deck, steps, runners and railings in the flight's frame: one mesh, a
## surface per material, shared by every flight of the same size.
func _flight_mesh(rise: float, run: float, width: float, steps: int) -> ArrayMesh:
	var key := "%.2f/%.2f/%.2f/%d" % [rise, run, width, steps]
	if _meshes.has(key):
		return _meshes[key]
	var angle := atan2(rise, run)
	var ramp := sqrt(rise * rise + run * run)
	var mid := Vector3(0.0, rise * 0.5, run * 0.5)
	var up := Vector3(0.0, cos(angle), -sin(angle))
	var tilt := Basis(Vector3.RIGHT, -angle)
	var stone := SurfaceTool.new()
	var rail := SurfaceTool.new()
	var runner := SurfaceTool.new()
	_box(stone, Vector3(width, 0.3, ramp), Transform3D(tilt, mid - up * 0.15))
	var step_h := rise / float(steps)
	var step_run := run / float(steps)
	const RUNNER := 0.05
	for i in steps:
		# the step's top at (i + 0.5) step heights: the slope crosses it at
		# its middle, half a step under its back edge and over its front
		var top := (float(i) + 0.5) * step_h
		var z := (float(i) + 0.5) * step_run
		# one step tall: down to the slope at its front edge, and not below
		# the deck slab's underside at its back (the underside stays smooth)
		var body := step_h
		_box(stone, Vector3(width - 0.1, body - RUNNER, step_run),
			Transform3D(Basis(), Vector3(0.0, top - RUNNER - (body - RUNNER) * 0.5, z)))
		_box(runner, Vector3(width - 0.9, RUNNER * 2.0, step_run * 0.94),
			Transform3D(Basis(), Vector3(0.0, top - RUNNER, z)))
	for side in [-1.0, 1.0]:
		_box(rail, Vector3(0.16, 1.1, ramp),
			Transform3D(tilt, mid + up * 0.55 + Vector3(side * (width * 0.5 + 0.12), 0.0, 0.0)))
	var mesh := ArrayMesh.new()
	var materials := [
		Kit.surface("stone_ashlar_01", Color(0.88, 0.86, 0.82), 3.0, true),
		Kit.surface("medieval_wood", Color(0.9, 0.82, 0.74), 0.0, true),
		Kit.surface("medieval_wood", Color(1.0, 0.86, 0.66), 0.0, true),
	]
	var tools := [stone, rail, runner]
	for k in tools.size():
		(tools[k] as SurfaceTool).commit(mesh)
		mesh.surface_set_material(k, materials[k])
	_meshes[key] = mesh
	return mesh

static func _box(st: SurfaceTool, size: Vector3, xform: Transform3D) -> void:
	var box := BoxMesh.new()
	box.size = size
	st.append_from(box, 0, xform)

# ------------------------------------------------------------------ wards

## A ward across a gate whose foot is at `at` (in `parent`'s space): a veil
## in the gate's plane, `width` wide and the gate's `height` tall (plus
## VEIL_RISE for its fading crest), and when `landing_dir` is not 0 the floor
## seam on the gate's line (the landing lies +z / -z of the gate, the flight
## the other way).
func _ward(parent: Node3D, at: Transform3D, width: float, height: float, landing_dir: float) -> Dictionary:
	if _noise == null:
		_noise = load(NOISE_TEX)
	var quad_h := height + VEIL_RISE
	var mat := ShaderMaterial.new()
	mat.shader = WARD_SHADER
	mat.set_shader_parameter("noise", _noise)
	mat.set_shader_parameter("width_m", width)
	mat.set_shader_parameter("height_m", quad_h)
	mat.set_shader_parameter("gate_m", height)
	var quad := QuadMesh.new()
	quad.size = Vector2(width, quad_h)
	quad.material = mat
	var curtain := MeshInstance3D.new()
	curtain.name = "Ward"
	curtain.mesh = quad
	curtain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	curtain.transform = at * Transform3D(Basis(), Vector3(0.0, quad_h * 0.5, 0.0))
	parent.add_child(curtain)
	var sill: ShaderMaterial = null
	if landing_dir != 0.0:
		sill = ShaderMaterial.new()
		sill.shader = THRESHOLD_SHADER
		sill.set_shader_parameter("noise", _noise)
		sill.set_shader_parameter("width_m", width)
		sill.set_shader_parameter("depth_m", SEAM_DEPTH)
		var plane := PlaneMesh.new()
		plane.size = Vector2(width, SEAM_DEPTH)
		plane.material = sill
		var strip := MeshInstance3D.new()
		strip.name = "WardThreshold"
		strip.mesh = plane
		strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# centred on the gate's line; PlaneMesh v runs toward +z, and the
		# flight lies away from the landing
		sill.set_shader_parameter("toward", -signf(landing_dir))
		strip.transform = at * Transform3D(Basis(), Vector3(0.0, 0.03, 0.0))
		parent.add_child(strip)
	return {"node": curtain, "sill": sill, "closed": 1.0, "warn": false, "shut": true}

## Every ward of a flight toward its gate's state this frame.
func _pose_wards(f: Dictionary, phase: String, ends_shut: bool, landing: Array, delta: float) -> void:
	var warn_s: float = f["warn_s"]
	for ward: Dictionary in f["deck_wards"]:
		_ease(ward, ends_shut, phase, phase == "warning", warn_s, delta)
	# landing gates stand still at their docks: known by where they stand
	# (an open one is not in the parts; it keeps its last place)
	var seen := {}
	for gate: Array in landing:
		var t: Transform3D = gate[0]
		var key := str(t.origin.snapped(Vector3(0.5, 0.5, 0.5)))
		seen[key] = true
		if not f["landing"].has(key):
			f["landing"][key] = _landing_ward(f, t, gate[1])
	for key: String in f["landing"]:
		var ward: Dictionary = f["landing"][key]
		var shut := seen.has(key)
		# the gate of the dock the flight leaves shuts as its warning begins
		if shut and not bool(ward["shut"]) and phase == "warning":
			ward["warn"] = true
		elif phase != "warning":
			ward["warn"] = false
		ward["shut"] = shut
		_ease(ward, shut, phase, bool(ward["warn"]), warn_s, delta)

## A landing gate's ward (its box `t`, `size`): the veil from the gate's
## foot as tall as the gate, the seam under it.
func _landing_ward(f: Dictionary, t: Transform3D, size: Vector3) -> Dictionary:
	var foot := Transform3D(t.basis.orthonormalized(), t.origin - t.basis.y.normalized() * size.y * 0.5)
	# the flight runs +z from a foot gate and ends -z of a head gate; the
	# landing lies the other way
	var frame: Transform3D = (f["node"] as Node3D).transform
	var head := absf(foot.origin.y - (frame.origin.y + float(f["rise"]))) < absf(foot.origin.y - frame.origin.y)
	return _ward(self, foot, size.x, size.y, 1.0 if head else -1.0)

func _ease(ward: Dictionary, shut: bool, phase: String, warning: bool, warn_s: float, delta: float) -> void:
	var closed: float = ward["closed"]
	var tint := WARD_OPEN
	var pulse := 0.0
	if not shut:
		closed = move_toward(closed, 0.0, delta / 0.7)
	elif warning and phase == "warning":
		# rises over the whole warning: the height is the countdown
		closed = move_toward(closed, 1.0, delta / warn_s)
		tint = WARD_WARN
		pulse = 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * 9.0)
	else:
		closed = move_toward(closed, 1.0, delta / 0.5)
		tint = WARD_SEALED
	ward["closed"] = closed
	var node: MeshInstance3D = ward["node"]
	node.visible = closed > 0.001
	var mat := (node.mesh as QuadMesh).material as ShaderMaterial
	mat.set_shader_parameter("closed", closed)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("pulse", pulse)
	var sill: ShaderMaterial = ward["sill"]
	if sill != null:
		sill.set_shader_parameter("open", 1.0 - closed)
		sill.set_shader_parameter("tint", tint if tint != WARD_SEALED else WARD_SEALED * 0.6)

# ------------------------------------------------------------------ line

## The line for the nearest flight that is not docked within reach of `me`.
func _warn(me: Vector3) -> void:
	var text := ""
	var best := INF
	for flight: int in phases:
		var phase := String(phases[flight])
		if phase == "docked":
			continue
		var ends := deck_ends(flight)
		var low: Vector3 = ends[0]
		var high: Vector3 = ends[1]
		if me.y < low.y - WARN_RISE or me.y > high.y + WARN_RISE:
			continue
		var a := Vector2(low.x, low.z)
		var ab := Vector2(high.x, high.z) - a
		var p := Vector2(me.x, me.z)
		var f := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var d := p.distance_to(a + ab * f)
		if d < WARN_REACH and d < best:
			best = d
			text = tr("Magical staircase: gates closed") if phase == "warning" else tr("Magical staircase: moving")
	line_text = text
	if _line.text != text:
		_line.text = text
	_line.visible = text != ""
