extends Node3D
class_name DungeonHazards

## The weekly curses' marks on the floor of the player's dungeon copy (the old
## game's dungeon_hazards), drawn from what the server says: each `hazard`
## dungeon event, and the run view's `hazards` (a player arriving late sees
## the marks already there). Each is a GroundWarning in its curse's tint:
##   * burst (Bursting Dead, at a corpse) and storm (Storm Rain, under a
##     player) are rings whose fire crawls out from `start_tick` and bursts on
##     `release_tick`;
##   * sticky (Sticky Ground) and pool (the Queen's venom, or a web when it
##     takes no health) are held patches that burn steady until `until_tick`,
##     then cool away;
##   * breath (Threehead's sleeping breath down the Sealed Wing's stair) is a
##     band (`half`: half extents x, z round `center`) that fills like a ring
##     from `start_tick` and goes off (the push) on `release_tick`;
##   * rockfall (a boss's arena coming down) is a ring as burst is, with a
##     stone dropping onto it over the last ROCK_DROP seconds.
## Any mark with a non-zero `half` is a band of that size, not a disc.
## Positions are world space (the copy's offset included). Presentation only:
## the server resolves every hazard on its own clock; this follows that clock
## (RealmSession.server_tick).

const TINTS := {
	"burst": Color(1.0, 0.45, 0.12),
	"storm": Color(0.55, 0.75, 1.0),
	"sticky": Color(0.85, 0.85, 0.78),
	"pool": Color(0.55, 0.95, 0.2),
	"breath": Color(0.74, 0.76, 1.0),
	"rockfall": Color(0.95, 0.66, 0.36),
}
## A rockfall's stone: the grounds' boulder, this big across, falling from
## this high over the last ROCK_DROP seconds; the area spell's burst where it
## lands.
const ROCK_MODEL := "res://assets/models/vegetation/rock_boulder.glb"
const ROCK_SIZE := 1.3
const ROCK_DROP := 0.5
const ROCK_HEIGHT := 12.0
const ROCK_IMPACT := "shockwave"
## A web (a pool that takes no health) is pale, as sticky ground is.
const WEB_TINT := Color(0.85, 0.85, 0.78)
const FALLBACK_TINT := Color(1.0, 0.3, 0.1)

var session: Node

## Marks drawn now: id -> {data, warning, ring}.
var live: Dictionary = {}
## Every id drawn or let go (a later view still listing one adds nothing).
var _known: Dictionary = {}
## What was seen (the check reads them): marks drawn per kind, rings burst,
## patches run out.
var drawn_kinds: Dictionary = {}
var bursts := 0
var expired := 0
var _rock_scene: PackedScene

func _init() -> void:
	name = "DungeonHazards"

func _now() -> float:
	return float(session.server_tick()) if session != null else 0.0

## A `hazard` dungeon event (its HazardView's fields).
func on_hazard(data: Dictionary) -> void:
	_add(data)

## A run view's `hazards`: the marks on the floor now.
func sync(hazards: Array) -> void:
	for h: Variant in hazards:
		if h is Dictionary:
			_add(h)

static func is_ring(kind: String) -> bool:
	return kind == "burst" or kind == "storm" or kind == "breath" or kind == "rockfall"

## A band's half extents (x, z), zero for a disc.
static func half_of(data: Dictionary) -> Vector2:
	var h: Variant = data.get("half", null)
	if h is Vector2:
		return h
	if h is Array and (h as Array).size() >= 2:
		return Vector2(float(h[0]), float(h[1]))
	return Vector2.ZERO

static func tint_for(data: Dictionary) -> Color:
	var kind := String(data.get("kind", ""))
	if kind == "pool" and float(data.get("hp_share", 0.0)) <= 0.0:
		return WEB_TINT
	return TINTS.get(kind, FALLBACK_TINT)

static func _center(data: Dictionary) -> Vector3:
	var c: Variant = data.get("center", Vector3.ZERO)
	if c is Vector3:
		return c
	if c is Array and (c as Array).size() >= 3:
		return Vector3(float(c[0]), float(c[1]), float(c[2]))
	return Vector3.ZERO

func _add(data: Dictionary) -> void:
	var id := int(data.get("id", 0))
	if _known.has(id):
		return
	var kind := String(data.get("kind", ""))
	var ring := is_ring(kind)
	var now := _now()
	# Already over on the server's clock: nothing to draw.
	if (ring and now >= float(data.get("release_tick", 0))) or (not ring and now >= float(data.get("until_tick", 0))):
		_known[id] = true
		return
	_known[id] = true
	drawn_kinds[kind] = int(drawn_kinds.get(kind, 0)) + 1
	var entry := {"data": data, "ring": ring, "warning": null}
	if DisplayServer.get_name() != "headless":
		var warning := GroundWarning.spawn(self, _center(data), float(data.get("radius", 3.0)), 0.0, 0.0,
			tint_for(data), not ring, half_of(data))
		entry["warning"] = warning
	live[id] = entry
	_drive(entry, now)

## One frame of a mark: a ring's fire follows the server tick from its start
## to its release; a patch holds steady.
func _drive(entry: Dictionary, now: float) -> void:
	var warning: Variant = entry["warning"]
	if not is_instance_valid(warning) or not bool(entry["ring"]):
		return
	var data: Dictionary = entry["data"]
	var release := float(data.get("release_tick", 0))
	var start := minf(float(data.get("start_tick", release - 1.0)), release - 1.0)
	(warning as GroundWarning).set_progress((now - start) / maxf(1.0, release - start))
	if String(data.get("kind", "")) != "rockfall":
		return
	var left := (release - now) / float(RealmInfo.sim_hz())
	if left > ROCK_DROP:
		return
	if not is_instance_valid(entry.get("rock")):
		entry["rock"] = _rock()
	# falling: slow at the top, fastest as it lands
	var t := clampf(left / ROCK_DROP, 0.0, 1.0)
	var rock := entry["rock"] as Node3D
	rock.global_position = _center(data) + Vector3.UP * (ROCK_HEIGHT * t * t + ROCK_SIZE * 0.4)
	rock.rotation = Vector3((1.0 - t) * 2.5, 0.7, (1.0 - t) * 1.3)

## The falling stone: the boulder model sized to ROCK_SIZE across, its centre
## on the node.
func _rock() -> Node3D:
	if _rock_scene == null:
		_rock_scene = load(ROCK_MODEL) as PackedScene
	var holder := Node3D.new()
	holder.name = "FallingRock"
	add_child(holder)
	if _rock_scene == null:
		return holder
	var model := _rock_scene.instantiate() as Node3D
	holder.add_child(model)
	var box := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var node: Node = mesh
		while node != null and node != model:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var local: AABB = xf * mesh.get_aabb()
		box = local if first else box.merge(local)
		first = false
	var extent := maxf(0.01, maxf(box.size.x, maxf(box.size.y, box.size.z)))
	model.scale = Vector3.ONE * (ROCK_SIZE / extent)
	model.position = -box.get_center() * model.scale
	return holder

func _process(_delta: float) -> void:
	if live.is_empty():
		return
	var now := _now()
	for id: int in live.keys():
		var entry: Dictionary = live[id]
		var data: Dictionary = entry["data"]
		var warning: Variant = entry["warning"]
		if bool(entry["ring"]):
			if now >= float(data.get("release_tick", 0)):
				live.erase(id)
				bursts += 1
				if is_instance_valid(warning):
					(warning as GroundWarning).release()
				if is_instance_valid(entry.get("rock")):
					(entry["rock"] as Node).queue_free()
				if String(data.get("kind", "")) == "rockfall" and DisplayServer.get_name() != "headless":
					var at := _center(data)
					SkillFX.play_impact(self, at, ROCK_IMPACT, Vector3.DOWN, at.y, Vector3.UP)
				continue
		elif now >= float(data.get("until_tick", 0)):
			live.erase(id)
			expired += 1
			if is_instance_valid(warning):
				(warning as GroundWarning).expire()
			continue
		_drive(entry, now)

## Every mark goes (the run is left behind).
func clear() -> void:
	for id: int in live.keys():
		var entry: Dictionary = live[id]
		for key: String in ["warning", "rock"]:
			var node: Variant = entry.get(key)
			if is_instance_valid(node):
				(node as Node).queue_free()
	live.clear()
