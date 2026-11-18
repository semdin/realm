extends Node3D
class_name WayFinder

## The waypoint (the old game's WaypointGuide): a mark set on the world map
## or from a quest or the dungeon guide, the walkable route to it
## (RealmSession.path_to over the map's navigation mesh) and the way the
## route is shown in the world:
##
##   * On foot: inked footprints - a steady trail of
##     left/right prints from the player's feet along the route for the next
##     stretch, pinned to the route (they do not swim as you walk) with a glow
##     rippling forward; new prints ink in ahead as you go.
##   * On the broom: embers drifting ahead toward the goal at riding height.
##   * Always: a smouldering column of gold light over the goal, embers
##     rising through it, seen from far away.
##
## A mark on another map leads to the door that goes there first (the fewest
## doors; the castle's front door for a room inside from the grounds). It
## clears itself on arrival (within ARRIVE_RADIUS) with a notice. The mark
## outlives the scene: a trip rebuilds the scene and the new one picks it up.
## Client only: the server never hears of it.

signal changed
signal arrived

const FOOTPRINT_SHADER := preload("res://assets/shaders/footprint.gdshader")
const BEACON_SHADER := preload("res://assets/shaders/waypoint_beacon.gdshader")
const NOISE := preload("res://assets/vfx/tex/noise_erosion_512.png")
const STRIDE := 0.8
const TRAIL := 4.0                # prints the forward ripple lights at once
const AHEAD := 10.0               # metres of route shown ahead of the player
const RIPPLE_SPEED := 6.0         # prints per second the glow runs forward
const MAX_PRINTS := 14
const EMBERS := 22
const EMBER_SPACING := 8.0
const ARRIVE_RADIUS := 5.0
## Over open ground a broom overhead counts as arrived: the height check only
## matters where floors stack (castle storeys, caverns).
const ARRIVE_RADIUS_AIR := 12.0
const ARRIVE_AIR_HEIGHT := 120.0
## Off the route by this much (cut a corner, flew, got knocked) and the route
## is planned again from where the player stands.
const OFF_ROUTE := 6.0
const GOLD := Color(1.0, 0.78, 0.38)

## The mark: its map, its point in that map's own coordinates (a dungeon
## copy's offset taken off) and what it is ("" for a plain mark).
static var target_map := ""
static var target_local := Vector3.INF
static var target_label := ""

## main.gd (session, map_name).
var game: Node
var map_name := ""
## The route on this map (world coordinates), its arc length per point, and
## the point it leads to (the mark, or the door toward it).
var path := PackedVector3Array()
var goal := Vector3.INF
## The door the route leads to when the mark is on another map ({} when the
## mark is here).
var via_door: Dictionary = {}
## What the checks read: routes planned, arrivals.
var routes := 0
var arrivals := 0

var _arc := PackedFloat32Array()
var _ripple := 0.0
var _flow := 0.0
var _reroute_wait := 0.0
var _seg := 0
var _print_y: Dictionary = {}
var _prints: MultiMeshInstance3D
var _embers: MultiMeshInstance3D
var _beacon: MeshInstance3D
var _motes: GPUParticles3D

func setup(main: Node, map_id: String) -> void:
	game = main
	map_name = map_id
	name = "WayFinder"
	top_level = true
	_prints = _multimesh("Footprints", Vector2(0.25, 0.45), MAX_PRINTS, false)
	_embers = _multimesh("FlightEmbers", Vector2(0.55, 0.55), EMBERS, true)
	_beacon = MeshInstance3D.new()
	_beacon.name = "Beacon"
	var column := CylinderMesh.new()
	column.top_radius = 1.0
	column.bottom_radius = 1.4
	column.height = 140.0
	column.cap_top = false
	column.cap_bottom = false
	var mat := ShaderMaterial.new()
	mat.shader = BEACON_SHADER
	mat.set_shader_parameter("noise", NOISE)
	column.material = mat
	_beacon.mesh = column
	_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beacon)
	_motes = RisingMotes.make(1.1, 4.0, GOLD, 40, 2.8, Vector2(2.0, 5.5), Vector2(0.03, 0.07))
	_motes.name = "BeaconMotes"
	add_child(_motes)
	_hide_all()

func _multimesh(node_name: String, quad_size: Vector2, count: int, ember: bool) -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = quad_size
	var mat := ShaderMaterial.new()
	mat.shader = BEACON_SHADER if ember else FOOTPRINT_SHADER
	mat.set_shader_parameter("noise", NOISE)
	if ember:
		mat.set_shader_parameter("ember", true)
		quad.orientation = PlaneMesh.FACE_Z
	else:
		mat.set_shader_parameter("trail", TRAIL)
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = count
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi

## ------------------------------------------------------------------- API

static func has_target() -> bool:
	return target_local != Vector3.INF

## Mark `point` (world coordinates on `map_id`; on this map a copy's offset
## is taken off) and plan the route to it. `label` names what it is.
func set_target(map_id: String, point: Vector3, label := "") -> void:
	if map_id == map_name:
		point -= game.session.copy_offset() as Vector3
	target_map = map_id
	target_local = point
	target_label = label
	_reroute()
	changed.emit()

func clear() -> void:
	target_local = Vector3.INF
	target_map = ""
	target_label = ""
	path = PackedVector3Array()
	_arc = PackedFloat32Array()
	goal = Vector3.INF
	via_door = {}
	_hide_all()
	changed.emit()

## The mark in world coordinates when it is on this map (else INF).
func target_here() -> Vector3:
	if not has_target() or target_map != map_name:
		return Vector3.INF
	return target_local + (game.session.copy_offset() as Vector3)

## ---------------------------------------------------------------- routing

## The next map on the way from `from_map` to `to_map` through the doors
## (maps.json portals; the fewest doors, never through a dungeon), "" when no
## door leads there.
static func next_hop(from_map: String, to_map: String) -> String:
	if from_map == to_map:
		return to_map
	var first: Dictionary = {}
	var queue: Array = [from_map]
	var seen := {from_map: true}
	while not queue.is_empty():
		var at := String(queue.pop_front())
		for portal: Dictionary in TravelData.portals(at):
			var next := String(portal.get("to_map", ""))
			if next == "" or seen.has(next) or (TravelData.instanced(next) and next != to_map):
				continue
			seen[next] = true
			first[next] = next if at == from_map else first[at]
			if next == to_map:
				return String(first[next])
			queue.append(next)
	return ""

## Doors from one map to another (-1: no way).
static func hops(from_map: String, to_map: String) -> int:
	var at := from_map
	for n in 8:
		if at == to_map:
			return n
		at = next_hop(at, to_map)
		if at == "":
			return -1
	return -1

## The door of `from_map` into `to_map` ({} when none).
static func door_to(from_map: String, to_map: String) -> Dictionary:
	for portal: Dictionary in TravelData.portals(from_map):
		if String(portal.get("to_map", "")) == to_map:
			return portal
	return {}

static func door_point(portal: Dictionary) -> Vector3:
	var c: Array = (portal.get("trigger", {}) as Dictionary).get("center", [0.0, 0.0, 0.0])
	return Vector3(float(c[0]), float(c[1]), float(c[2]))

func _reroute() -> void:
	_print_y.clear()
	_seg = 0
	if not has_target() or game == null or String(game.session.status()) != "joined":
		return
	var offset: Vector3 = game.session.copy_offset()
	via_door = {}
	goal = Vector3.INF
	if target_map == map_name:
		goal = target_local + offset
	else:
		var hop := next_hop(map_name, target_map)
		via_door = door_to(map_name, hop) if hop != "" else {}
		if not via_door.is_empty():
			goal = door_point(via_door) + offset
	if goal == Vector3.INF:
		path = PackedVector3Array()
		_arc = PackedFloat32Array()
		_hide_all()
		return
	path = game.session.path_to(goal)
	if path.size() < 2:
		# no walkable way (a ledge, a pit): straight there
		path = PackedVector3Array([game.session.own_position(), goal])
	else:
		goal = path[path.size() - 1]
	_arc.resize(path.size())
	var total := 0.0
	for i in path.size():
		if i > 0:
			total += path[i - 1].distance_to(path[i])
		_arc[i] = total
	routes += 1
	changed.emit()

## The route's remaining length from where the player stands (metres).
func remaining() -> float:
	if path.size() < 2 or _arc.is_empty():
		return 0.0
	var proj := _project(game.session.own_position())
	return maxf(0.0, _arc[_arc.size() - 1] - proj.x)

## Arc length of the closest point of the route to `p`, and its distance.
func _project(p: Vector3) -> Vector2:
	var best := INF
	var best_s := 0.0
	var lo := maxi(0, _seg - 40)
	var hi := mini(path.size() - 1, _seg + 80)
	for i in range(lo, hi):
		var a := path[i]
		var b := path[i + 1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var d := p.distance_to(a + ab * t)
		if d < best:
			best = d
			best_s = _arc[i] + ab.length() * t
			_seg = i
	return Vector2(best_s, best)

## Position and heading on the route at arc length s.
func _at(s: float) -> Array:
	s = clampf(s, 0.0, _arc[_arc.size() - 1])
	var i := clampi(_seg, 0, path.size() - 2)
	while i > 0 and _arc[i] > s:
		i -= 1
	while i < path.size() - 2 and _arc[i + 1] < s:
		i += 1
	var a := path[i]
	var b := path[i + 1]
	var seg_len := maxf(0.0001, _arc[i + 1] - _arc[i])
	var p := a.lerp(b, clampf((s - _arc[i]) / seg_len, 0.0, 1.0))
	var dir := Vector3(b.x - a.x, 0.0, b.z - a.z)
	return [p, dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD]

## ------------------------------------------------------------------ frame

func _hide_all() -> void:
	if _prints != null:
		_prints.multimesh.visible_instance_count = 0
		_embers.multimesh.visible_instance_count = 0
		_beacon.visible = false
		_motes.emitting = false

## Every frame once the map is drawn (MapWay.tick).
func tick(delta: float) -> void:
	if not has_target() or String(game.session.status()) != "joined":
		return
	var p: Vector3 = game.session.own_position()
	var mounted := bool(game.session.own_body().get("mounted", false))
	if target_map == map_name and _arrived(p, mounted):
		clear()
		arrivals += 1
		arrived.emit()
		return
	_reroute_wait = maxf(0.0, _reroute_wait - delta)
	if path.size() < 2 and _reroute_wait <= 0.0:
		_reroute_wait = 1.0
		_reroute()
	if path.size() < 2:
		_hide_all()
		return
	var proj := _project(p)
	if proj.y > OFF_ROUTE and _reroute_wait <= 0.0:
		_reroute_wait = 0.6
		_reroute()
		if path.size() < 2:
			return
		proj = _project(p)
	_beacon.visible = true
	_beacon.global_position = goal + Vector3(0, 70.0, 0)
	_motes.global_position = goal
	_motes.emitting = true
	if mounted:
		_prints.multimesh.visible_instance_count = 0
		_draw_air(delta, p)
	else:
		_embers.multimesh.visible_instance_count = 0
		_draw_prints(delta, proj.x)

func _arrived(p: Vector3, mounted: bool) -> bool:
	var t := target_here()
	var flat := Vector2(p.x - t.x, p.z - t.z).length()
	if flat < ARRIVE_RADIUS and absf(p.y - t.y) < 6.0:
		return true
	return mounted and TravelData.flight_allowed(map_name) and flat < ARRIVE_RADIUS_AIR \
			and p.y > t.y - 2.0 and p.y - t.y < ARRIVE_AIR_HEIGHT

## The ground under a print: the first surface (not a creature) a short ray
## down from just over the route meets; the route's own height if none.
func _ground_y(at: Vector3) -> float:
	var from := at + Vector3(0, 2.5, 0)
	for attempt in 3:
		var hit: Dictionary = game.session.pick(from, Vector3.DOWN, 6.0)
		if hit.is_empty():
			break
		var point: Vector3 = hit["point"]
		if int(hit["entity"]) == 0:
			return point.y
		from = point - Vector3(0, 0.3, 0)
	return at.y

func _draw_prints(delta: float, s_player: float) -> void:
	var total := _arc[_arc.size() - 1]
	var k_player := s_player / STRIDE
	var first := int(floor(k_player)) + 1
	var last := mini(int(floor(minf(total, s_player + AHEAD) / STRIDE)), first + MAX_PRINTS - 1)
	var count := maxi(1, last - first + 1)
	# the glow runs from the feet to the far end and starts over
	_ripple = fmod(_ripple + delta * RIPPLE_SPEED, float(count) + TRAIL)
	var mm := _prints.multimesh
	var n := 0
	for k in range(first, last + 1):
		var at: Array = _at(float(k) * STRIDE)
		var pos: Vector3 = at[0]
		var fwd: Vector3 = at[1]
		var right := fwd.cross(Vector3.UP).normalized()
		pos += right * (0.15 if k % 2 == 0 else -0.15)
		# each print finds its ground once (a ray), and keeps it
		if not _print_y.has(k):
			_print_y[k] = _ground_y(pos)
			if _print_y.size() > 256:
				_print_y.erase(_print_y.keys()[0])
		pos.y = float(_print_y[k]) + 0.06
		mm.set_instance_transform(n, Transform3D(Basis(right, fwd, Vector3.UP), pos))
		# x: steps since the ripple passed this print; y: how far along the
		# shown stretch it is (the far end fades out, the feet fade in)
		var i := float(k - first)
		mm.set_instance_custom_data(n, Color(_ripple - i, i / float(count), k - k_player, 0))
		n += 1
	mm.visible_instance_count = n

## On the broom: embers drifting from the rider toward the goal, holding the
## rider's height and settling onto the goal over the last 60 m.
func _draw_air(delta: float, p: Vector3) -> void:
	var to := goal + Vector3(0, 3.0, 0)
	var flat := Vector3(to.x - p.x, 0.0, to.z - p.z)
	var dist := flat.length()
	var mm := _embers.multimesh
	if dist < 2.0:
		mm.visible_instance_count = 0
		return
	var fwd := flat / dist
	_flow = fmod(_flow + delta * 9.0, EMBER_SPACING)
	var n := 0
	for k in EMBERS:
		var s := 6.0 + float(k) * EMBER_SPACING + _flow
		if s > dist:
			break
		var y := lerpf(p.y - 1.0, to.y, smoothstep(dist - 60.0, dist, s))
		var pos := p + fwd * s
		pos.y = y + sin(s * 0.7 + _flow) * 0.25
		mm.set_instance_transform(n, Transform3D(Basis(), pos))
		mm.set_instance_custom_data(n, Color(0, 0, 0, 0))
		n += 1
	mm.visible_instance_count = n
