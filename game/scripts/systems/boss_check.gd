extends "res://scripts/systems/dungeon_check.gd"

## `--check-boss`: a Sealed Wing boss the way a player fights it, against the
## coordinator and two linked map servers (castle_interior and
## dng_sealed_wing, the dungeon server started with `--dev-dungeon-start
## <step>` so the run begins at that boss with every gate before it open, and
## `--dev-dungeon-scale 0.05`; build/logs/dup_boss.sh). The character comes
## from `tools/fixtures/make_prepared_character.py --dungeon-kit --sealed-wing
## --level 34` (in the castle on the Sealed Wing gate). `--check-boss-step`
## names the boss: threehead (the default) or snare (the Strangling Vine).
##
##   land .. start  as DungeonCheck: the gate fc_entry, its window, Normal, the
##                  launch, the copy, the countdown
##   to_boss        down the corridor along its middle line (local x 0); the
##                  Sealed Wing's breath (a band down the stair) is looked at
##                  and captured once on the way
##   chime          (threehead) stands in the sleep chime's reach without a
##                  cast until it rings (the channel bar over the player) and
##                  Threehead sleeps (its stun); captures both
##   parts          the boss's parts one by one: Tab-style targeting of the
##                  nearest standing head or vine, the basic cast at it; the
##                  first part down is captured slumped (or withered) on the
##                  model; back to the chime when Threehead wakes and the chime
##                  is ready again
##   body           (snare) the heart once its vines are gone
##   down           the boss dies (with its last head, or its heart)
##
## The verdict prints what it saw and quits 0 when the boss died, a part was
## seen down on the model and (threehead) the chime rang and the boss slept.

const BOSS_HOLD := 1.2
const BOSS_TIMEOUT := 600.0
const GATE_ID := "fc_entry"
## maps.json fc_entry's trigger (castle_interior).
const GATE_POINT := Vector2(65.1, -10.4)
## The corridor's middle line, then the boss's room (local x, z).
const ROUTES := {
	"threehead": [Vector2(0, -20), Vector2(0, -56), Vector2(0, -100), Vector2(0, -140), Vector2(0, -150), Vector2(0, -158), Vector2(8, -164)],
	"snare": [Vector2(0, -20), Vector2(0, -56), Vector2(0, -100), Vector2(0, -112)],
}
## Where the vine fight is watched from (local), out of its lash.
const SNARE_STAND := Vector2(0, -114)
## The stair stop (local) where the check waits for a breath (it blows
## every 7 s or so while someone stands in the band), at most BREATH_WAIT s.
const BREATH_STOP := Vector2(0, -150)
const BREATH_WAIT := 20.0
## The chime appears with Threehead, who wakes once the hall is entered
## (local z below -168): walk this way until the run view carries it.
const CHIME_FALLBACK := Vector2(15, -171)
## A breath band is captured with its fire this far filled.
const BREATH_CAPTURE_AT := 0.55
## Stand this far inside the chime's reach.
const CHIME_INSIDE := 1.0
const PART_CAPTURE_SAG := 0.9
## How near the check goes to the boss to look at it (its captures).
const APPROACH := 11.0
const APPROACH_STALL := 1.5

var _boss_step := "threehead"
var _boss_id := 0
var _route_at := 0
var _part_capture_id := 0
var _breath_wait_since := 0.0
var _approach_from := Vector3.INF
var _approach_at := 0.0

func _ready() -> void:
	super()
	_boss_step = String(game._arg("--check-boss-step", "threehead"))
	if not ROUTES.has(_boss_step):
		_boss_step = "threehead"

func _go(step: String) -> void:
	print("realm check boss: frame %d step %s at %s on %s" % [Engine.get_frames_drawn(), step,
		_me().snapped(Vector3(0.1, 0.1, 0.1)), game.map_name])
	_s["step"] = step
	_since = _now()
	_held = 0.0
	_sent = false

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/boss")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check boss: captured %s" % path)

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null:
		return
	var step := String(_s["step"])
	if step in ["to_boss", "chime", "parts", "body"]:
		_boss_steps(step, delta)
		return
	if _now() - float(_s["started"]) > TOTAL_TIMEOUT + BOSS_TIMEOUT and not step.ends_with("_wait"):
		_verdict("timed out in step " + step)
		return
	if not _ready_to_play() and not step.ends_with("_wait"):
		return
	match step:
		"land":
			_held += delta
			if game.map_name != "castle_interior":
				_verdict("did not land in the castle (%s)" % game.map_name)
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
			if game.map_name != "dng_sealed_wing" or int(game.session.copy()) == 0:
				_verdict("the launch did not lead into a Sealed Wing copy (%s, copy %d)" % [game.map_name, int(game.session.copy())])
				return
			if _held > HOLD:
				_seen("copy", "copy %d at %s" % [int(game.session.copy()), str(_offset())])
				_go("start")
		"start":
			var run: HudDungeonRun = game.dungeon.run_view
			if run.phase() == HudDungeonRun.RUNNING:
				_seen("running", "step %s" % run.state.get("step", ""))
				game.cam_distance = 10.0
				game.cam_pitch = -0.45
				_route_at = 0
				_go("to_boss")
			elif _now() - _since > STEP_TIMEOUT:
				_verdict("the run never started")
		_:
			# the gate, its window and the launch are DungeonCheck's own
			super(delta)

## The boss steps (in the copy): their own clock, no scene reloads.
func _boss_steps(step: String, delta: float) -> void:
	if _now() - _since > BOSS_TIMEOUT:
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
	_find_boss()
	if _boss_id != 0 and not _boss_alive() and _has("boss_seen"):
		_seen("boss_down", "%s %d, parts down [%s]" % [_boss_step, _boss_id, ", ".join(_boss_view().parts_down) if _boss_view() != null else ""])
		_watch_boss()
		if _held > BOSS_HOLD:
			_capture("boss_down")
			_verdict("")
		return
	match step:
		"to_boss":
			if _look_at_breath():
				return
			var route: Array = ROUTES[_boss_step]
			if _route_at >= route.size():
				_go("chime" if _boss_step == "threehead" else "parts")
				return
			var goal: Vector2 = route[_route_at]
			var at := _offset() + Vector3(goal.x, 0, goal.y)
			if _walk_to(at.x, at.z) < STOP_REACH:
				if goal == BREATH_STOP and not _has("breath"):
					# stand in the band until it blows (or give up)
					if _breath_wait_since == 0.0:
						_breath_wait_since = _now()
					if _now() - _breath_wait_since < BREATH_WAIT:
						return
				_route_at += 1
			else:
				_walk = 1.0
		"chime":
			_at_chime()
		"parts":
			_fight_parts(delta)
		"body":
			_fight_body(delta)

## The boss body in view (the step's species), 0 when none yet.
func _find_boss() -> void:
	if _boss_id != 0 and game.beasts.has(_boss_id):
		return
	var species := "threehead" if _boss_step == "threehead" else "strangling_vine"
	for id: int in game.beasts.keys():
		var body: Variant = game.beasts[id]
		if body is CreatureView and (body as CreatureView).species == species and not (body as CreatureView).is_dead:
			_boss_id = id
			_seen("boss_seen", "%s %d at %s" % [species, id, str(((body as CreatureView).global_position - _offset()).snapped(Vector3(0.1, 0.1, 0.1)))])
			return

func _boss_view() -> CreatureView:
	return game.beasts.get(_boss_id) as CreatureView

func _boss_alive() -> bool:
	var body := _boss_view()
	return body != null and not body.is_dead

## The camera on the boss (from where the player stands).
func _watch_boss() -> void:
	var body := _boss_view()
	if body != null:
		_face(body.global_position)
		game.cam_distance = 7.5
		game.cam_pitch = -0.22

## Walks toward the boss until within APPROACH; true once there, or once
## the walk has made no headway for APPROACH_STALL seconds (the hall's
## dressing or the boss's own bulk in the way).
func _near_boss() -> bool:
	var body := _boss_view()
	if body == null:
		return false
	var at := body.global_position
	if _walk_to(at.x, at.z) <= APPROACH:
		return true
	var me := _me()
	if _approach_from == Vector3.INF or me.distance_to(_approach_from) > 0.5:
		_approach_from = me
		_approach_at = _now()
	elif _now() - _approach_at > APPROACH_STALL:
		return true
	_walk = 1.0
	return false

## A breath band filling on the stair: looked at, captured once. True while
## looking.
func _look_at_breath() -> bool:
	if _has("breath"):
		return false
	var hazards: DungeonHazards = game.dungeon.hazards
	for id: int in hazards.live.keys():
		var entry: Dictionary = hazards.live[id]
		var data: Dictionary = entry["data"]
		if String(data.get("kind", "")) != "breath":
			continue
		var warning: Variant = entry["warning"]
		var center := DungeonHazards._center(data)
		_face(center)
		game.cam_pitch = -0.6
		game.cam_distance = 12.0
		if is_instance_valid(warning) and (warning as GroundWarning).progress >= BREATH_CAPTURE_AT:
			_seen("breath", "id %d at %s half %s, ticks %d..%d, me %.1f m away" % [id,
				str((center - _offset()).snapped(Vector3(0.1, 0.1, 0.1))), str(DungeonHazards.half_of(data)),
				int(data.get("start_tick", 0)), int(data.get("release_tick", 0)), _me().distance_to(center)])
			_capture("breath_band")
			game.cam_pitch = -0.45
			game.cam_distance = 10.0
		return true
	return false

## Stand in the chime's reach, no casts, until it rings and Threehead sleeps.
func _at_chime() -> void:
	var chime: SleepChime = game.dungeon.chime
	if chime.data.is_empty():
		if _now() - _since > STEP_TIMEOUT:
			_verdict("the run view carries no chime")
			return
		var toward := _offset() + Vector3(CHIME_FALLBACK.x, 0, CHIME_FALLBACK.y)
		if _walk_to(toward.x, toward.z) > STOP_REACH:
			_walk = 1.0
		return
	var at := SleepChime._vec(chime.data.get("at"))
	var reach := float(chime.data.get("radius", 2.6))
	var me := _me()
	var off := Vector2(me.x - at.x, me.z - at.z)
	if off.length() > reach - CHIME_INSIDE:
		_walk_to(at.x, at.z)
		_walk = 1.0
		return
	if not _has("chime_seen"):
		_seen("chime_seen", "at %s r %.1f, the prop at %s" % [str((at - _offset()).snapped(Vector3(0.1, 0.1, 0.1))), reach,
			str((chime._prop.global_position - _offset()).snapped(Vector3(0.1, 0.1, 0.1))) if chime._prop != null else "-"])
	var body := _boss_view()
	if chime.ringing:
		if body != null:
			_face(body.global_position)
		else:
			_face(at)
		game.cam_distance = 9.0
		game.cam_pitch = -0.35
		if chime.progress >= 0.5 and not _has("chime_ringing"):
			_seen("chime_ringing", "ringer %d (me %d), %.0f %% at tick %d, rings %d" % [int(chime.data.get("ringer", 0)),
				int(game.session.own_entity()), chime.progress * 100.0, int(game.session.server_tick()), chime.rings_seen.size()])
			_capture("chime_ringing")
	if body != null and body.asleep:
		_watch_boss()
		if not _has("boss_asleep"):
			if not _near_boss():
				return
			_watch_boss()
			if not _sent:
				_sent = true
				_held = 0.0
			if _held > BOSS_HOLD:
				_seen("boss_asleep", "status %d, clip %s, haze %d" % [body.status,
					body.anim_player.current_animation if body.anim_player != null else "-", body._haze.size()])
				_capture("boss_asleep")
				_go("parts")
		else:
			_go("parts")

## The nearest standing part of the boss, cast at until it is down; the
## first part down captured slumped on the model.
func _fight_parts(delta: float) -> void:
	var body := _boss_view()
	if body == null:
		if _boss_step == "snare":
			_hold_stand()
		return
	_capture_part_down(body)
	if _part_capture_id != 0:
		return
	var standing: Array = []
	for part: int in body.parts.keys():
		var entry: Variant = game.part_states.get(part)
		if entry is Array and int(entry[0]) != CreatureView.STATE_DEAD:
			standing.append(part)
	if standing.is_empty():
		if not body.parts.is_empty() and _boss_step == "snare":
			_go("body")
		return
	# Threehead awake again with the chime ready: back to it first.
	var chime: SleepChime = game.dungeon.chime
	if _boss_step == "threehead" and not body.asleep and not chime.data.is_empty() \
			and float(game.session.server_tick()) >= float(chime.data.get("ready_tick", 0)) and _has("boss_asleep"):
		_go("chime")
		return
	if _boss_step == "snare":
		_hold_stand()
	standing.sort_custom(func(a, b): return _me().distance_to(game.drawn[a]) < _me().distance_to(game.drawn[b]))
	var foe: int = standing[0]
	if _boss_step != "snare":
		_near_boss()
	_face(game.drawn[foe])
	game.cam_distance = 8.0
	game.cam_pitch = -0.22
	_cast_wait -= delta
	if _cast_wait <= 0.0:
		_cast_wait = CAST_EVERY
		if game.target != foe:
			game.select_target(foe)
			if not _has("part_card"):
				_seen("part_card", "\"%s\" (%s)" % [game.hud.target_name.text, game.hud.target_rank.text if "target_rank" in game.hud else ""])
		_s["casts"] = int(_s["casts"]) + 1
		game.cast_spell("basic_cast")

## The first part that goes down: the camera holds on the boss until it has
## slumped (or withered) on the model, then the capture.
func _capture_part_down(body: CreatureView) -> void:
	if _has("part_down"):
		return
	if _part_capture_id == 0:
		for part: int in body.parts.keys():
			if body.parts_down.has(String(body.parts[part])):
				_part_capture_id = part
				break
	if _part_capture_id == 0:
		return
	var key := String(body.parts[_part_capture_id])
	_watch_boss()
	if body.part_sag(key) >= PART_CAPTURE_SAG:
		_seen("part_down", "%s part %s (entity %d), sag %.2f, down [%s]" % [body.species, key, _part_capture_id,
			body.part_sag(key), ", ".join(body.parts_down)])
		_capture("head_slumped" if _boss_step == "threehead" else "vine_withered")
		_part_capture_id = 0

## The vine never moves: the check stands off its lash.
func _hold_stand() -> void:
	var at := _offset() + Vector3(SNARE_STAND.x, 0, SNARE_STAND.y)
	if _walk_to(at.x, at.z) > STOP_REACH:
		_walk = 1.0

## The Strangling Vine's heart once its vines are gone.
func _fight_body(delta: float) -> void:
	var body := _boss_view()
	if body == null:
		return
	_capture_part_down(body)
	_hold_stand()
	_face(body.global_position)
	_cast_wait -= delta
	if _cast_wait <= 0.0:
		_cast_wait = CAST_EVERY
		if game.target != _boss_id:
			game.select_target(_boss_id)
		_s["casts"] = int(_s["casts"]) + 1
		game.cast_spell("basic_cast")

func _verdict(failure: String) -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var corrections := int(_s["corrections"]) + int(stats.get("corrections", 0))
	var seen: Dictionary = _s["seen"]
	var wanted := ["land", "gate_prompt", "loading_1", "copy", "running", "boss_seen", "part_card", "part_down", "boss_down"]
	if _boss_step == "threehead":
		wanted.append_array(["chime_seen", "chime_ringing", "boss_asleep"])
	var missing := wanted.filter(func(k): return not seen.has(k))
	var ok := failure == "" and missing.is_empty()
	print("realm check boss: %s | %s | maps [%s] | seen {%s} | missing [%s]" % [
			"ok" if ok else (failure if failure != "" else "incomplete"), _boss_step, ", ".join(_s["maps"]),
			" ; ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing)],
		" | %d casts, %d own hits, %d rises | breath marks %d | corrections %d (max %.3f m)" % [int(_s["casts"]),
			int(_s["hits"]) + int(game.check_hits), int(_s["deaths"]), int(game.dungeon.hazards.drawn_kinds.get("breath", 0)),
			corrections, float(stats.get("max_correction", 0.0))])
	print("realm check boss: messages [%s]" % " | ".join(game.dungeon.messages))
	for path in _s["captures"]:
		print("realm check boss: capture ", path)
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if ok else 1)
