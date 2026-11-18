extends "res://scripts/systems/dungeon_check.gd"

## `--check-lair`: the Silk Queen's Lair the way a player fights it, against
## the coordinator and two linked map servers (spider_caverns and
## dng_spider_lair, the dungeon server started with `--dev-dungeon-start
## <step> --dev-dungeon-scale 0.05 --dev-cocoon-solo`; build/logs/
## aup_lair.sh). The character comes from `tools/fixtures/
## make_prepared_character.py --dungeon-kit --spider-lair` (level 30, in the
## Blackweb Caverns by the camp's web gate). `--check-lair-step` names the
## part of the lair: eggs (the default) or queen.
##
##   land .. start  as DungeonCheck: the gate lair_entry_camp, its window,
##                  Normal, the launch, the copy, the countdown
##   to_room        down the tunnel (local x 0) to the egg cavern or the nest,
##                  the basic cast at anything in the way
##   eggs           (eggs) the sacs' guards fall to the basic cast, the sacs
##                  are spared; the sacs captured standing, then the check
##                  stands off one sac and watches it split open: the capture
##                  once the sac is gone and its hatchlings stand round it
##   clear          (eggs) everything is cleared until the gate message
##                  ("The last sac withers...")
##   queen          (queen) the Silk Queen and her brood; the cocoon she spins
##                  round the player captured (the player held inside it) and
##                  again as it splits open (a lone player cannot break it:
##                  it holds out its 12 s), the venom pools captured, the
##                  Queen captured down
##
## Looks at a thing turn the camera LOOK_ASIDE off the line through the
## player, so the player's own body does not hide it.
##
## The verdict prints what it saw and quits 0 only when each of those was seen.

const LAIR_TIMEOUT := 420.0
const GATE_ID := "lair_entry_camp"
## maps.json lair_entry_camp's trigger (spider_caverns).
const GATE_POINT := Vector2(-174.0, -159.0)
## realm_netcheck lair.rs: the tunnel (local x, z), then the room's tour.
const ROUTES := {
	"eggs": [Vector2(0, -20), Vector2(0, -45), Vector2(0, -60)],
	"queen": [Vector2(0, -20), Vector2(0, -60), Vector2(0, -100), Vector2(0, -140), Vector2(0, -162)],
}
const ROOMS := {
	"eggs": [Vector2(0, -62), Vector2(-6, -72), Vector2(6, -84), Vector2(0, -92), Vector2(-6, -84), Vector2(6, -70)],
	"queen": [Vector2(0, -166), Vector2(-8, -176), Vector2(8, -190), Vector2(0, -184), Vector2(-8, -190), Vector2(8, -176)],
}
## On the way down the tunnel only what comes this near is fought.
const ROUTE_SIGHT := 12.0
## dungeons.json eggs: a sac hatches this long after it was laid (the check
## gives up on a watched sac this long and 30 s more after it first saw one).
const HATCH_AFTER := 45.0
## A sac is picked to watch once nothing has been in sight this long, or
## this long after the sacs appeared at the latest.
const QUIET_BEFORE_WATCH := 1.5
const PICK_SAC_BY := 20.0
## While watching, only what comes this near is fought.
const CLOSE_FOE := 4.0
## Where the check watches the sac from (metres off it, toward the room).
const SAC_WATCH_OFF := 5.0
## Hatchlings within this of the sac count as its own.
const HATCH_NEAR := 2.2
## The hatch capture this long after the sac went (the burst still up).
const HATCH_CAPTURE_AFTER := 0.35
## A cocoon this near the player is round it.
const COCOON_NEAR := 1.5
const COCOON_CAPTURE_AFTER := 1.0
## The cocoon's split captured this long after it died (the burst up).
const COCOON_SPLIT_CAPTURE_AFTER := 0.3
const POOL_CAPTURE_AFTER := 1.0
const DOWN_HOLD := 1.2
## How far (radians) a look turns off the line through the player.
const LOOK_ASIDE := 0.5

var _lair_step := "eggs"
var _route_at := 0
var _room_at := 0
## The raw (English) step messages, in order.
var _said: Array = []
var _sacs_first_seen := 0.0
## When a foe was last in sight (the sac watch waits for quiet).
var _quiet_since := 0.0
var _watch_sac := 0
var _watch_at := Vector3.ZERO
## Where the watched sac stood when last seen.
var _sac_at_last := Vector3.ZERO
## The weavers drawn the frame before the sac went, and those new since (id -> metres
## from the sac where first drawn).
var _weavers_before: Dictionary = {}
var _hatchlings: Dictionary = {}
var _sac_gone_at := 0.0
var _cocoon_id := 0
var _cocoon_since := 0.0
var _cocoon_gone_at := 0.0
var _pool_since := 0.0
var _queen_id := 0

func _ready() -> void:
	super()
	_lair_step = String(game._arg("--check-lair-step", "eggs"))
	if not ROUTES.has(_lair_step):
		_lair_step = "eggs"

func _go(step: String) -> void:
	print("realm check lair: frame %d step %s at %s on %s" % [Engine.get_frames_drawn(), step,
		_me().snapped(Vector3(0.1, 0.1, 0.1)), game.map_name])
	_s["step"] = step
	_since = _now()
	_held = 0.0
	_sent = false

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/lair")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check lair: captured %s" % path)

func _local(at: Vector3) -> Vector3:
	return (at - _offset()).snapped(Vector3(0.1, 0.1, 0.1))

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null:
		return
	var step := String(_s["step"])
	_note_messages()
	if step in ["to_room", "eggs", "clear", "queen"]:
		_lair_steps(step, delta)
		return
	if _now() - float(_s["started"]) > TOTAL_TIMEOUT + LAIR_TIMEOUT and not step.ends_with("_wait"):
		_verdict("timed out in step " + step)
		return
	if not _ready_to_play() and not step.ends_with("_wait"):
		return
	match step:
		"land":
			_held += delta
			if game.map_name != "spider_caverns":
				_verdict("did not land in the Blackweb Caverns (%s)" % game.map_name)
				return
			if _held > HOLD:
				_seen("land", str(_me().snapped(Vector3(0.1, 0.1, 0.1))))
				_go("to_gate")
		"to_gate":
			if String(game.travel.active_portal.get("id", "")) == GATE_ID:
				_go("gate")
			elif _walk_to(GATE_POINT.x, GATE_POINT.y) > 0.4:
				_walk = 1.0
			elif _now() - _since > STEP_TIMEOUT:
				_verdict("no gate prompt at %s" % GATE_ID)
		"copy":
			_held += delta
			if game.map_name != "dng_spider_lair" or int(game.session.copy()) == 0:
				_verdict("the launch did not lead into a lair copy (%s, copy %d)" % [game.map_name, int(game.session.copy())])
				return
			if _held > HOLD:
				_seen("copy", "copy %d at %s" % [int(game.session.copy()), str(_offset())])
				_go("start")
		"start":
			var run: HudDungeonRun = game.dungeon.run_view
			if run.phase() == HudDungeonRun.RUNNING:
				_seen("running", "step %s" % run.state.get("step", ""))
				game.cam_distance = 9.0
				game.cam_pitch = -0.45
				_route_at = 0
				_go("to_room")
			elif _now() - _since > STEP_TIMEOUT:
				_verdict("the run never started")
		_:
			# the gate, its window and the launch are DungeonCheck's own
			super(delta)

## The run's step messages as the server words them (the shown ones are
## translated).
func _note_messages() -> void:
	if game.dungeon == null:
		return
	var raw := String(game.dungeon._message)
	if raw != "" and (_said.is_empty() or _said.back() != raw):
		_said.append(raw)
		print("realm check lair: message \"%s\"" % raw)

func _heard(what: String) -> bool:
	for line: String in _said:
		if line.contains(what):
			return true
	return false

## The lair steps (in the copy): their own clock, no scene reloads.
func _lair_steps(step: String, delta: float) -> void:
	if _now() - _since > LAIR_TIMEOUT:
		_verdict("step %s timed out" % step)
		return
	_held += delta
	if game.feedback.is_dead():
		if not _has("died"):
			_seen("died", true)
		if game.feedback.can_rise():
			_s["deaths"] = int(_s["deaths"]) + 1
			game.feedback.press_rise(true)
		return
	match step:
		"to_room":
			var route: Array = ROUTES[_lair_step]
			if _route_at >= route.size():
				_room_at = 0
				_go(_lair_step)
				return
			if _fight_near(delta, "", ROUTE_SIGHT):
				return
			var goal: Vector2 = route[_route_at]
			var at := _offset() + Vector3(goal.x, 0, goal.y)
			if _walk_to(at.x, at.z) < STOP_REACH * 1.2:
				_route_at += 1
			else:
				_walk = 1.0
		"eggs":
			_eggs(delta)
		"clear":
			if _heard("last sac withers"):
				if not _has("gate_open"):
					_seen("gate_open", "\"%s\", %d left" % [_said.back(), int(game.dungeon.run_view.state.get("left", 0))])
					_held = 0.0
				if _held > HOLD:
					_capture("egg_gate")
					_verdict("")
				return
			if not _fight_near(delta, "", SIGHT):
				_tour(delta)
		"queen":
			_queen(delta)

## The nearest living creature within `reach` in sight, not of species
## `spare` (entity id, 0 when none).
func _foe(spare: String, reach: float) -> int:
	var others: Dictionary = game.others
	var ids: PackedInt32Array = others.get("ids", PackedInt32Array())
	var kinds: PackedInt32Array = others.get("kinds", PackedInt32Array())
	var positions: PackedVector3Array = others.get("positions", PackedVector3Array())
	var me := _me()
	var eye := me + Vector3(0, 1.5, 0)
	var best := 0
	var best_d := reach
	for i in ids.size():
		if game._creature_index(ids[i]) < 0:
			continue
		if spare != "" and CreatureView.species_for_kind(kinds[i]) == spare:
			continue
		var d := me.distance_to(positions[i])
		if d >= best_d:
			continue
		var aim := positions[i] + Vector3(0, 1.0, 0)
		var hit: Dictionary = game.session.pick(eye, (aim - eye).normalized(), eye.distance_to(aim))
		if not hit.is_empty() and int(hit["entity"]) == 0 and eye.distance_to(hit["point"]) < eye.distance_to(aim) - 0.3:
			continue
		best = ids[i]
		best_d = d
	return best

## The basic cast at the nearest foe in sight; true while there is one.
func _fight_near(delta: float, spare: String, reach: float) -> bool:
	var foe := _foe(spare, reach)
	if foe == 0 or not game.drawn.has(foe):
		return false
	_face(game.drawn[foe])
	_cast_wait -= delta
	if _cast_wait <= 0.0:
		_cast_wait = CAST_EVERY
		if game.target != foe:
			game.select_target(foe)
		_s["casts"] = int(_s["casts"]) + 1
		game.cast_spell("basic_cast")
	return true

## The room's tour (no stop inside a live pool).
func _tour(_delta: float) -> void:
	var room: Array = ROOMS[_lair_step]
	for _i in room.size():
		var stop: Vector2 = room[_room_at % room.size()]
		if not _in_pool(_offset() + Vector3(stop.x, 0, stop.y), 1.0):
			break
		_room_at += 1
	var goal: Vector2 = room[_room_at % room.size()]
	var at := _offset() + Vector3(goal.x, 0, goal.y)
	if _walk_to(at.x, at.z) < STOP_REACH:
		_room_at += 1
	else:
		_walk = 1.0

## Whether (x, z) lies in a live venom pool (with `margin`).
func _in_pool(at: Vector3, margin: float) -> bool:
	var hazards: DungeonHazards = game.dungeon.hazards
	for id: int in hazards.live:
		var data: Dictionary = (hazards.live[id] as Dictionary)["data"]
		if String(data.get("kind", "")) != "pool" or float(data.get("hp_share", 0.0)) <= 0.0:
			continue
		var c := DungeonHazards._center(data)
		if Vector2(at.x - c.x, at.z - c.z).length() < float(data.get("radius", 0.0)) + margin:
			return true
	return false

## The bodies of a species in view: id -> CreatureView (living only unless
## `dead_too`).
func _bodies(species: String, dead_too := false) -> Dictionary:
	var out := {}
	for id: int in game.beasts.keys():
		var body: Variant = game.beasts[id]
		if body is CreatureView and (body as CreatureView).species == species and (dead_too or not (body as CreatureView).is_dead):
			out[id] = body
	return out

## eggs: the guards fall, the sacs stand; one sac watched until it splits.
func _eggs(delta: float) -> void:
	var sacs := _bodies("egg_sac")
	if not sacs.is_empty() and _sacs_first_seen == 0.0:
		_sacs_first_seen = _now()
		print("realm check lair: %d egg sacs in view" % sacs.size())
	if _has("egg_sacs"):
		_watch_hatch(delta)
		return
	if _heard("egg sac splits"):
		# hatched before the check stood off one: the brood is cleared
		_go("clear")
		return
	if _watch_sac == 0:
		# the guards first (the sacs spared), then a sac to watch
		if _fight_near(delta, "egg_sac", SIGHT):
			_quiet_since = _now()
			return
		if _sacs_first_seen > 0.0 and not sacs.is_empty() and (_now() - _quiet_since > QUIET_BEFORE_WATCH \
				or _now() - _sacs_first_seen > PICK_SAC_BY):
			_pick_sac(sacs)
		else:
			_tour(delta)
		return
	var sac: CreatureView = game.beasts.get(_watch_sac)
	if sac == null or sac.is_dead:
		# gone before the watch began (a stray bolt): another one
		_watch_sac = 0
		return
	_sac_at_last = sac.global_position
	# to the watch point, then the sacs captured standing
	if _walk_to(_watch_at.x, _watch_at.z) > STOP_REACH:
		_walk = 1.0
		return
	_look_past(sac.global_position)
	if not _sent:
		_sent = true
		_held = 0.0
	if _held > HOLD:
		_seen("egg_sacs", "%d standing, watching %d at %s from %s, %.1f s after they appeared" % [sacs.size(), _watch_sac,
			str(_local(sac.global_position)), str(_local(_me())), _now() - _sacs_first_seen])
		_capture("egg_sacs")

## The camera on `at` from where the player stands, turned LOOK_ASIDE off
## the line through the player so its body does not hide the thing.
func _look_past(at: Vector3) -> void:
	_face(at)
	game.cam_yaw += LOOK_ASIDE
	game.cam_distance = 8.0
	game.cam_pitch = -0.42

## The sac nearest the room's middle line, and where it is watched from.
func _pick_sac(sacs: Dictionary) -> void:
	var me := _me()
	var best := 0
	for id: int in sacs.keys():
		if best == 0 or me.distance_to((sacs[id] as Node3D).global_position) < me.distance_to((sacs[best] as Node3D).global_position):
			best = id
	_watch_sac = best
	var at: Vector3 = (sacs[best] as Node3D).global_position
	var mid := Vector3(_offset().x, at.y, at.z)
	var off := (mid - at)
	off.y = 0.0
	off = off.normalized() if off.length() > 0.1 else Vector3(0, 0, 1)
	_watch_at = at + off * SAC_WATCH_OFF
	print("realm check lair: watching sac %d at %s from %s" % [best, str(_local(at)), str(_local(_watch_at))])

## Stands at the watch point with the camera on the sac until it is gone and
## its hatchlings stand round where it was: the hatch capture.
func _watch_hatch(delta: float) -> void:
	var sac: CreatureView = game.beasts.get(_watch_sac)
	var gone := sac == null or sac.is_dead
	if not gone:
		_sac_at_last = sac.global_position
		# (the weavers drawn this frame: a corpse's id comes back on a new
		# creature once it is gone)
		_weavers_before = _bodies("black_weaver", true)
		# what comes at the player is fought; the sac is left be
		if _fight_near(delta, "egg_sac", CLOSE_FOE):
			return
		if _walk_to(_watch_at.x, _watch_at.z) > STOP_REACH:
			_walk = 1.0
		else:
			_look_past(sac.global_position)
		if _now() - _sacs_first_seen > HATCH_AFTER + 30.0:
			_verdict("the sac never hatched (%.0f s after the sacs appeared)" % (_now() - _sacs_first_seen))
		return
	if _sac_gone_at == 0.0:
		_sac_gone_at = _now()
		print("realm check lair: sac %d gone at %.1f s after the sacs appeared" % [_watch_sac, _now() - _sacs_first_seen])
	_look_past(_sac_at_last)
	# the weavers new since the sac went, where each was first drawn
	for id: int in _bodies("black_weaver").keys():
		if not _weavers_before.has(id) and not _hatchlings.has(id):
			var at: Vector3 = (game.beasts[id] as Node3D).global_position
			_hatchlings[id] = Vector2(at.x - _sac_at_last.x, at.z - _sac_at_last.z).length()
			print("realm check lair: weaver %d drawn %.1f m from the sac %.2f s after it went" % [id, _hatchlings[id],
				_now() - _sac_gone_at])
	var brood := 0
	for id: int in _hatchlings.keys():
		if float(_hatchlings[id]) < HATCH_NEAR:
			brood += 1
	if not _has("hatch") and brood > 0 and _now() - _sac_gone_at >= HATCH_CAPTURE_AFTER:
		var split := sac != null and sac.split_open
		_seen("hatch", "sac %d %s%s at %s, %d hatchlings born round it (first drawn %s m off), captured %.2f s on, message %s" % [
			_watch_sac, "dead" if sac != null else "removed", ", split open" if split else "", str(_local(_sac_at_last)), brood,
			", ".join(_hatchlings.values().map(func(d): return "%.1f" % d)), _now() - _sac_gone_at,
			"heard" if _heard("egg sac splits") else "not yet"])
		_capture("hatch")
	var others := _bodies("egg_sac")
	if not _has("hatch") and brood == 0 and not _heard("egg sac splits") and _now() - _sac_gone_at > 1.5 \
			and not others.is_empty():
		# a stray bolt burnt it before its time: another one is watched
		print("realm check lair: sac %d burnt before it hatched, watching another" % _watch_sac)
		_sac_gone_at = 0.0
		_hatchlings.clear()
		_pick_sac(others)
		return
	if _has("hatch") or _now() - _sac_gone_at > 4.0:
		if not _has("hatch"):
			_verdict("the sac went but no hatchling stood round it")
			return
		_go("clear")

## queen: the Silk Queen and her brood; the cocoon, the pools, her fall.
func _queen(delta: float) -> void:
	_find_queen()
	var queen: CreatureView = game.beasts.get(_queen_id)
	if _queen_id != 0 and (queen == null or queen.is_dead) and _has("queen_seen"):
		if not _has("queen_down"):
			_seen("queen_down", "%d, heard \"curls up\" %s" % [_queen_id, _heard("curls up")])
			_held = 0.0
		if queen != null:
			_look_past(queen.global_position)
		if _held > DOWN_HOLD and not _has("queen_down_capture"):
			_seen("queen_down_capture", true)
			_capture("queen_down")
		if _has("queen_down_capture") and (_has("cocoon_split") and _has("venom_pools") or _held > 20.0):
			_verdict("")
		return
	if _look_at_cocoon():
		return
	if _look_at_pools():
		return
	if _in_pool(_me(), 0.6):
		# out of the venom first
		var out := _offset() + Vector3(0, 0, -184)
		_walk_to(out.x, out.z)
		_walk = 1.0
		return
	if not _fight_near(delta, "web_cocoon", SIGHT):
		_tour(delta)

func _find_queen() -> void:
	if _queen_id != 0:
		return
	for id: int in game.beasts.keys():
		var body: Variant = game.beasts[id]
		if body is CreatureView and (body as CreatureView).species == "black_weaver" and (body as CreatureView).is_boss \
				and not (body as CreatureView).is_dead:
			_queen_id = id
			_seen("queen_seen", "%d at %s, %s x%.2f" % [id, str(_local((body as CreatureView).global_position)),
				(body as CreatureView).model.scene_file_path.get_file(), (body as CreatureView).model.scale.x])
			return

## A cocoon round the player: the camera on it, held, captured once.
func _look_at_cocoon() -> bool:
	if _has("cocoon_split"):
		return false
	var me := _me()
	if _cocoon_id == 0:
		for id: int in _bodies("web_cocoon").keys():
			var body: CreatureView = game.beasts[id]
			if Vector2(body.global_position.x - me.x, body.global_position.z - me.z).length() < COCOON_NEAR:
				_cocoon_id = id
				_cocoon_since = _now()
				_cocoon_gone_at = 0.0
				break
	if _cocoon_id == 0:
		return false
	var cocoon: CreatureView = game.beasts.get(_cocoon_id)
	var queen: CreatureView = game.beasts.get(_queen_id)
	# from the Queen's side, low, so the body in the silk shows
	if queen != null:
		_face(queen.global_position)
		game.cam_yaw += PI * 0.8
	game.cam_distance = 5.5
	game.cam_pitch = -0.2
	if cocoon == null or cocoon.is_dead:
		# held out (or broken): it splits open, the player is let go
		if not _has("cocoon") or cocoon == null:
			_cocoon_id = 0
			return false
		if _cocoon_gone_at == 0.0:
			_cocoon_gone_at = _now()
		if _now() - _cocoon_gone_at >= COCOON_SPLIT_CAPTURE_AFTER:
			var body: Dictionary = game.session.own_body()
			_seen("cocoon_split", "%d split open %s, held %.1f s, me held %s, hp %d" % [_cocoon_id,
				str(cocoon.split_open), _cocoon_gone_at - _cocoon_since, str(body.get("held", false)),
				int((game.session.vitals() as PackedInt32Array)[0]) if (game.session.vitals() as PackedInt32Array).size() > 0 else -1])
			_capture("cocoon_split")
			_cocoon_id = 0
		return true
	if not _has("cocoon") and _now() - _cocoon_since >= COCOON_CAPTURE_AFTER:
		var body: Dictionary = game.session.own_body()
		var box := _model_box(cocoon)
		_seen("cocoon", "%d at %s, me %s (held %s, status %d), drawn box y %.2f..%.2f, width %.2f, feet %.2f" % [_cocoon_id,
			str(_local(cocoon.global_position)), str(_local(me)), str(body.get("held", false)), int(body.get("status", 0)),
			box.position.y - me.y, box.end.y - me.y, maxf(box.size.x, box.size.z), cocoon.global_position.y - me.y])
		_capture("cocoon")
	return true

## The cocoon model's world box.
func _model_box(body: CreatureView) -> AABB:
	var box := AABB()
	var first := true
	for node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.visible:
			continue
		var b := mesh.global_transform * mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

## The venom pools: looked at from above once they have welled up, captured.
func _look_at_pools() -> bool:
	if _has("venom_pools"):
		return false
	var hazards: DungeonHazards = game.dungeon.hazards
	var pools: Array = []
	for id: int in hazards.live:
		var data: Dictionary = (hazards.live[id] as Dictionary)["data"]
		if String(data.get("kind", "")) == "pool":
			pools.append(data)
	if pools.is_empty():
		return false
	if _pool_since == 0.0:
		_pool_since = _now()
	# the pools' middle
	var mid := Vector3.ZERO
	for data: Dictionary in pools:
		mid += DungeonHazards._center(data)
	mid /= pools.size()
	_face(mid)
	game.cam_distance = 13.0
	game.cam_pitch = -0.75
	if _now() - _pool_since >= POOL_CAPTURE_AFTER:
		var data: Dictionary = pools[0]
		_seen("venom_pools", "%d pools, r %.1f, hp %.2f, ticks %d..%d, tint %s, me %s" % [pools.size(),
			float(data.get("radius", 0.0)), float(data.get("hp_share", 0.0)), int(data.get("start_tick", 0)),
			int(data.get("until_tick", 0)), str(DungeonHazards.tint_for(data)), str(_local(_me()))])
		_capture("venom_pools")
		game.cam_distance = 9.0
		game.cam_pitch = -0.45
	return true

func _verdict(failure: String) -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var corrections := int(_s["corrections"]) + int(stats.get("corrections", 0))
	var seen: Dictionary = _s["seen"]
	var wanted := ["land", "gate_prompt", "loading_1", "copy", "running"]
	if _lair_step == "eggs":
		wanted.append_array(["egg_sacs", "hatch", "gate_open"])
	else:
		wanted.append_array(["queen_seen", "cocoon", "cocoon_split", "venom_pools", "queen_down"])
	var missing := wanted.filter(func(k): return not seen.has(k))
	var ok := failure == "" and missing.is_empty()
	print("realm check lair: %s | %s | maps [%s] | seen {%s} | missing [%s]" % [
			"ok" if ok else (failure if failure != "" else "incomplete"), _lair_step, ", ".join(_s["maps"]),
			" ; ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing)],
		" | %d casts, %d own hits, %d rises | pool marks %d | corrections %d (max %.3f m)" % [int(_s["casts"]),
			int(_s["hits"]) + int(game.check_hits), int(_s["deaths"]), int(game.dungeon.hazards.drawn_kinds.get("pool", 0)),
			corrections, float(stats.get("max_correction", 0.0))])
	print("realm check lair: messages [%s]" % " | ".join(_said))
	for path in _s["captures"]:
		print("realm check lair: capture ", path)
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if ok else 1)
