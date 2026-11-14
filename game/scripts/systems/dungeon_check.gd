extends Node

## `--check-dungeon`: a solo Trial Hall run the way a player does it, against
## the coordinator and two linked map servers (grounds and dng_trial, the
## dungeon server started with `--dev-dungeon-scale 0.05` so one bolt kills).
## The character comes from `tools/fixtures/make_prepared_character.py
## --dungeon-kit` (level 12, on the grounds by the Trial Hall gate). One step
## at a time:
##
##   land        lands on the grounds by the gate
##   to_gate     walks onto the gate (portal trial_entry) until its prompt shows
##   gate        F opens the gate window; waits for the gate's answer
##   window      holds the window: Normal open, Hard locked; picks Normal and
##               presses Enter
##   launch_wait the launch closes the window; the loading screen comes up and
##               the ticket rebuilds the scene
##   copy        (after the reload) in a copy: the map drawn at copy_offset(),
##               the gates standing; looks at the nearest closed gate
##   start       the tracker: gathering, the countdown (10..1), Go
##   fight       the tour of the hall (realm_netcheck dungeon.rs `tour`, local
##               coordinates + copy_offset()), a basic cast at the nearest
##               creature in sight; until the run is complete
##   result      the result window with a medal and the rewards
##   to_exit     the rest of the tour, then the reward exit (trial_reward_exit)
##   exit        F at the reward exit; the loading screen; the scene is rebuilt
##   grounds     (after the reload) back on the grounds
##
## Key moments are held HOLD seconds on screen and saved as PNGs into
## `--capture-dir` (default build/captures/dungeon). A map change rebuilds the
## scene, so the check's state lives on the Engine (STATE_KEY). The verdict
## prints what it saw and quits 0 when every step was seen.

const HOLD := 1.5
const STEP_TIMEOUT := 90.0
const FIGHT_TIMEOUT := 480.0
const TOTAL_TIMEOUT := 720.0
const STATE_KEY := &"dungeon_check_state"
const GATE := "trial_entry"
const REWARD_EXIT := "trial_reward_exit"
## Where the gate's trigger stands (maps.json trial_entry).
const GATE_AT := Vector2(70.0, 69.0)
## realm_netcheck dungeon.rs `tour`: the corridor, both side rooms through
## their doors, the hall and both ossuaries, the arena (local x, z).
const TOUR := [Vector2(0, -8), Vector2(0, -24), Vector2(-9, -24), Vector2(-15, -24), Vector2(-9, -24),
	Vector2(9, -24), Vector2(15, -24), Vector2(9, -24), Vector2(0, -30), Vector2(0, -42), Vector2(0, -58),
	Vector2(-16, -58), Vector2(-25, -58), Vector2(-16, -58), Vector2(16, -58), Vector2(25, -58),
	Vector2(16, -58), Vector2(0, -72), Vector2(0, -88), Vector2(0, -104), Vector2(0, -118), Vector2(0, -132)]
const STOP_REACH := 1.0
## The netcheck's sight: creatures this near with nothing of the map between.
const SIGHT := 24.0
const CAST_EVERY := 0.6
## How long after the first own hit the fight capture is taken (the bolt's
## impact on screen).
const FIGHT_CAPTURE_AFTER := 0.25
## How long after a countdown number pops the capture is taken (settled, not
## yet fading).
const COUNT_CAPTURE_AFTER := 0.3

var game: Node
var _s: Dictionary = {}
var _since := 0.0
var _held := 0.0
var _sent := false
var _walk := 0.0
var _cast_wait := 0.0
var _hits_at_start := -1
var _first_hit_at := 0.0
var _counts_seen := 0
var _count_at := 0.0

func _ready() -> void:
	var carried: Variant = Engine.get_meta(STATE_KEY) if Engine.has_meta(STATE_KEY) else null
	if carried is Dictionary:
		_s = carried
	else:
		_s = {"step": "land", "started": _now(), "seen": {}, "captures": [], "refusals": {}, "events": [],
			"corrections": 0, "reloads": 0, "maps": [], "stop": 0, "casts": 0, "hits": 0, "deaths": 0}
	Engine.set_meta(STATE_KEY, _s)
	(_s["maps"] as Array).append(String(game.map_name))
	_since = _now()
	print("realm check dungeon: scene for %s, step %s" % [game.map_name, _s["step"]])

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go(step: String) -> void:
	print("realm check dungeon: frame %d step %s at %s on %s" % [Engine.get_frames_drawn(), step,
		_me().snapped(Vector3(0.1, 0.1, 0.1)), game.map_name])
	_s["step"] = step
	_since = _now()
	_held = 0.0
	_sent = false

func _seen(what: String, detail: Variant = true) -> void:
	(_s["seen"] as Dictionary)[what] = detail

func _has(what: String) -> bool:
	return (_s["seen"] as Dictionary).has(what)

func _me() -> Vector3:
	return game.session.own_position() if game.session != null else Vector3.ZERO

func _offset() -> Vector3:
	return game.session.copy_offset() if game.session != null else Vector3.ZERO

func walk_intent() -> float:
	return _walk

## Every travel and dungeon game event main.gd shows.
func on_event(event: Dictionary) -> void:
	var kind := String(event["kind"])
	var line := kind
	match kind:
		"travel_result":
			line = "%s %s %s" % [event["what"], "ok" if bool(event["ok"]) else "refused", event["reason"]]
		"departing":
			line = "departing %s to %s" % [event["trip"], event["map"]]
		"travel":
			line = "travel ticket for %s" % event["map"]
		"arrived":
			line = "arrived by %s" % event["trip"]
		"dungeon":
			var what := String(event.get("event", ""))
			var view: Dictionary = event.get("view", event)
			line = "dungeon " + what
			match what:
				"refused", "cancelled":
					line += " %s %s" % [event.get("reason", ""), event.get("who", "")]
					var r: Dictionary = _s["refusals"]
					r[String(event.get("reason", ""))] = int(r.get(String(event.get("reason", "")), 0)) + 1
				"launch":
					line += " " + String(event.get("map", ""))
				"state":
					line += " phase %d step %s forces %d/%d%s" % [int(view.get("phase", -1)), view.get("step", ""),
						int(view.get("forces", 0)), int(view.get("forces_total", 0)), " complete" if bool(view.get("complete", false)) else ""]
					if view.get("result") is Dictionary:
						_seen("result_view", str(view["result"]))
				"rewards":
					line += " exp %d oril %d items %s unlocked %s" % [int(event.get("exp", 0)), int(event.get("oril", 0)),
						str(event.get("items", [])), str(event.get("unlocked", []))]
					_seen("rewards", "exp %d, oril %d, %d items" % [int(event.get("exp", 0)), int(event.get("oril", 0)),
						(event.get("items", []) as Array).size()])
	(_s["events"] as Array).append(line)
	print("realm check dungeon: frame %d event %s" % [Engine.get_frames_drawn(), line])

## The scene is about to be rebuilt for a trip: the loading screen is up (a
## capture of it), the session's numbers are kept, the next step is set.
func before_reload() -> void:
	_s["reloads"] = int(_s["reloads"]) + 1
	_s["corrections"] = int(_s["corrections"]) + int(game.session.stats().get("corrections", 0))
	_s["hits"] = int(_s["hits"]) + int(game.check_hits)
	var screen := MapLoadingScreen.shared(get_tree())
	_seen("loading_%d" % int(_s["reloads"]), "%s / %s" % [screen.last_title, screen.last_status])
	_capture("loading_%d" % int(_s["reloads"]))
	match String(_s["step"]):
		"launch_wait":
			_go("copy")
		"exit_wait":
			_go("grounds")
	Engine.set_meta(STATE_KEY, _s)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/dungeon")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check dungeon: captured %s" % path)

## Walk toward world (x, z): the camera turns there. Returns the distance.
func _walk_to(x: float, z: float) -> float:
	var me := _me()
	var flat := Vector2(x - me.x, z - me.z)
	if flat.length() > 0.3:
		game.cam_yaw = atan2(-flat.x, -flat.y)
	return flat.length()

func _face(at: Vector3) -> void:
	var me := _me()
	game.cam_yaw = atan2(-(at.x - me.x), -(at.z - me.z))

func _ready_to_play() -> bool:
	return game.built and game.session.status() == "joined" and not game.session.sheet().is_empty() \
		and not MapLoadingScreen.shared(get_tree()).is_open()

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null:
		return
	var now := _now()
	var step := String(_s["step"])
	if now - float(_s["started"]) > TOTAL_TIMEOUT and not step.ends_with("_wait"):
		_verdict("timed out in step " + step)
		return
	if now - _since > (FIGHT_TIMEOUT if step == "fight" or step == "to_exit" else STEP_TIMEOUT):
		_verdict("step %s timed out" % step)
		return
	if not _ready_to_play() and not step.ends_with("_wait"):
		return
	_held += delta
	var travel: MapTravel = game.travel
	var dungeon: MapDungeon = game.dungeon
	var gate: HudDungeon = dungeon.gate_window
	var me := _me()
	match step:
		"land":
			if game.map_name != "grounds":
				_verdict("did not land on the grounds (%s)" % game.map_name)
				return
			if _held > HOLD:
				_seen("land", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
				_go("to_gate")
		"to_gate":
			_walk_to(GATE_AT.x, GATE_AT.y)
			if String(travel.active_portal.get("id", "")) == GATE:
				_go("gate")
			else:
				_walk = 1.0
		"gate":
			if not _sent and _held > 0.5:
				_sent = true
				_seen("gate_prompt", travel.prompt)
				if not travel.interact() or not gate.visible:
					_verdict("F at the gate did not open the gate window")
					return
			if _sent and gate.answers > 0:
				_go("window")
		"window":
			if _held > HOLD and not _sent:
				_sent = true
				var mine := gate.me(gate.info.get("members", []))
				var unlocked: Array = mine.get("unlocked", [])
				var normal_open := not (gate.cards["normal"] as HudDungeon.DifficultyCard).locked
				var hard_locked := (gate.cards["hard"] as HudDungeon.DifficultyCard).locked
				_seen("gate_window", "unlocked %s, Normal %s, Hard %s, verdict \"%s\", button \"%s\"" % [str(unlocked),
					"open" if normal_open else "locked", "locked" if hard_locked else "open", gate.verdict.text, gate.start_button.text])
				_capture("gate_window")
				if not normal_open or not hard_locked:
					_verdict("the gate window shows Normal %s and Hard %s" % ["open" if normal_open else "locked",
						"locked" if hard_locked else "open"])
					return
				(gate.cards["normal"] as HudDungeon.DifficultyCard).chosen.emit()
				if gate.start_button.disabled:
					_verdict("Enter is disabled: %s" % gate.verdict.text)
					return
				gate.start_button.pressed.emit()
				_go("launch_wait")
		"launch_wait", "exit_wait":
			var screen := MapLoadingScreen.shared(get_tree())
			if screen.is_open():
				_seen("loading_up_" + step, screen.last_title)
			if step == "launch_wait" and int(dungeon.events.get("launch", 0)) > 0 and not gate.visible:
				_seen("launch_closed_window", true)
		"copy":
			if game.map_name != "dng_trial" or int(game.session.copy()) == 0:
				_verdict("the launch did not lead into a Trial Hall copy (%s, copy %d)" % [game.map_name, int(game.session.copy())])
				return
			var walls: Node3D = game.get_node_or_null("Walls")
			if walls == null or not walls.position.is_equal_approx(_offset()) or _offset() == Vector3.ZERO:
				_verdict("the copy's map is not drawn at its offset (%s, offset %s)" % [str(walls.position) if walls else "none", str(_offset())])
				return
			if dungeon.gates == null or dungeon.gates.count() == 0:
				return
			_look_at_gate()
			game.cam_distance = 7.0
			if _held > HOLD:
				_seen("copy", "copy %d at %s, %d gates (%d closed: %s), me local %s" % [int(game.session.copy()), str(_offset()),
					dungeon.gates.count(), dungeon.gates.closed_count(), ", ".join(dungeon.gates.closed_ids()),
					str((me - _offset()).snapped(Vector3(0.1, 0.1, 0.1)))])
				_capture("copy_gates")
				_go("start")
		"start":
			var run: HudDungeonRun = dungeon.run_view
			if run.phase() == HudDungeonRun.GATHERING and run.wait_label.visible:
				_seen("gathering", run.wait_label.text)
			if run.counts_shown.size() != _counts_seen:
				_counts_seen = run.counts_shown.size()
				_count_at = _now()
			# a number in full, a moment after it popped (it fades before the next)
			if run.phase() == HudDungeonRun.COUNTDOWN and run.count_text() != "" and not _has("countdown"):
				if run.counts_shown.size() >= 3 and _now() - _count_at > COUNT_CAPTURE_AFTER:
					_seen("countdown", "%s (tracker \"%s\")" % [run.count_text(), run.clock_label.text])
					_capture("tracker_countdown")
			if run.phase() == HudDungeonRun.RUNNING:
				_seen("running", "counts %s, go %s" % [str(run.counts_shown), run.go_shown])
				_hits_at_start = int(game.check_hits)
				game.cam_distance = 8.0
				game.cam_pitch = -0.5
				_go("fight")
		"fight":
			_fight(delta)
		"result":
			var result: HudDungeonResult = dungeon.result_window
			if result.visible and not result.rewards.is_empty():
				if not _sent:
					_sent = true
					_held = 0.0
				if _held > HOLD:
					_seen("result_window", "medal %s, \"%s\", rewards exp %d oril %d, %d items, again button %s" % [
						result.medal if result.medal != "" else "none", result.card._title_label.text,
						int(result.rewards.get("exp", 0)), int(result.rewards.get("oril", 0)),
						(result.rewards.get("items", []) as Array).size(), "shown" if result.again_button.visible else "hidden"])
					_capture("result")
					if result.medal == "":
						_verdict("the run earned no medal")
						return
					result.close()
					_s["stop"] = _nearest_stop()
					_go("to_exit")
		"to_exit":
			var stop := int(_s["stop"])
			var goal: Vector2
			if stop < TOUR.size():
				goal = TOUR[stop]
			else:
				goal = Vector2(0, -161.0) if stop > TOUR.size() else Vector2(0, -148.0)
			var at := _offset() + Vector3(goal.x, 0, goal.y)
			if String(travel.active_portal.get("id", "")) == REWARD_EXIT:
				_go("exit")
			elif _walk_to(at.x, at.z) < STOP_REACH and stop <= TOUR.size():
				_s["stop"] = stop + 1
			else:
				_walk = 1.0
		"exit":
			if _held > HOLD * 0.5 and not _sent:
				_sent = true
				_seen("exit_prompt", travel.prompt)
				travel.interact()
				_go("exit_wait")
		"grounds":
			if game.map_name != "grounds":
				_verdict("the reward exit did not lead to the grounds (%s)" % game.map_name)
				return
			if _held > HOLD:
				_seen("grounds", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
				_capture("grounds_return")
				_verdict("")

## The tour stop nearest the body (the walk out goes on from there).
func _nearest_stop() -> int:
	var local := _me() - _offset()
	var best := 0
	for i in TOUR.size():
		if Vector2(local.x, local.z).distance_to(TOUR[i]) < Vector2(local.x, local.z).distance_to(TOUR[best]):
			best = i
	return best

## The camera looks at the nearest closed gate (the copy capture).
func _look_at_gate() -> void:
	var best := Vector3.INF
	var me := _me()
	for g: Dictionary in game.session.gates():
		if bool(g.get("open", false)):
			continue
		var c: Vector3 = g["center"]
		if best == Vector3.INF or me.distance_to(c) < me.distance_to(best):
			best = c
	if best != Vector3.INF:
		_face(best)

## The nearest living creature within SIGHT with nothing of the map between
## (entity id, 0 when none).
func _creature_in_sight() -> int:
	var others: Dictionary = game.others
	var ids: PackedInt32Array = others.get("ids", PackedInt32Array())
	var positions: PackedVector3Array = others.get("positions", PackedVector3Array())
	var me := _me()
	var eye := me + Vector3(0, 1.5, 0)
	var best := 0
	var best_d := SIGHT
	for i in ids.size():
		if game._creature_index(ids[i]) < 0:
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

## The fight: the nearest creature in sight takes the basic cast, otherwise
## the tour goes on; until the run is complete.
func _fight(delta: float) -> void:
	var dungeon: MapDungeon = game.dungeon
	var run: HudDungeonRun = dungeon.run_view
	if bool(run.state.get("complete", false)) and run.state.get("result") is Dictionary:
		_seen("complete", "%s, clock %s, %s" % [str(run.state["result"]), run.clock_label.text, run.clear_label.text.replace("\n", " / ")])
		_seen("messages", " | ".join(dungeon.messages))
		_go("result")
		return
	if game.feedback.is_dead():
		if not _has("died"):
			_seen("died", true)
		if game.feedback.can_rise():
			_s["deaths"] = int(_s["deaths"]) + 1
			game.feedback.press_rise(true)
		return
	var foe := _creature_in_sight()
	if foe != 0 and game.drawn.has(foe):
		_face(game.drawn[foe])
		_cast_wait -= delta
		if _cast_wait <= 0.0:
			_cast_wait = CAST_EVERY
			if game.target != foe:
				game.select_target(foe)
			_s["casts"] = int(_s["casts"]) + 1
			game.cast_spell("basic_cast")
	else:
		var stop := int(_s["stop"]) % TOUR.size()
		var at := _offset() + Vector3(TOUR[stop].x, 0, TOUR[stop].y)
		if _walk_to(at.x, at.z) < STOP_REACH:
			_s["stop"] = (stop + 1) % TOUR.size()
		else:
			_walk = 1.0
	# The fight capture: a moment after the first bolt of the run lands.
	if not _has("fight") and _hits_at_start >= 0 and int(game.check_hits) > _hits_at_start:
		if _first_hit_at == 0.0:
			_first_hit_at = _now()
		elif _now() - _first_hit_at > FIGHT_CAPTURE_AFTER:
			_seen("fight", "%s, %s" % [run.clock_label.text, run.clear_label.text.replace("\n", " / ")])
			_capture("fight")

func _verdict(failure: String) -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var corrections := int(_s["corrections"]) + int(stats.get("corrections", 0))
	var seen: Dictionary = _s["seen"]
	var wanted := ["land", "gate_prompt", "gate_window", "loading_1", "launch_closed_window", "copy", "countdown",
		"running", "fight", "complete", "rewards", "result_window", "exit_prompt", "loading_2", "grounds"]
	var missing := wanted.filter(func(k): return not seen.has(k))
	var ok := failure == "" and missing.is_empty() and corrections == 0
	print("realm check dungeon: %s | maps [%s], %d reloads | seen {%s} | missing [%s]" % [
			"ok" if ok else (failure if failure != "" else "incomplete"), ", ".join(_s["maps"]), int(_s["reloads"]),
			" ; ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing)],
		" | %d casts, %d own hits, %d rises | refusals {%s}" % [int(_s["casts"]), int(_s["hits"]) + int(game.check_hits),
			int(_s["deaths"]), ", ".join((_s["refusals"] as Dictionary).keys().map(func(k): return "%s x%d" % [k, _s["refusals"][k]]))],
		" | captures %d | corrections %d (this map max %.3f m), snapshots %d" % [(_s["captures"] as Array).size(),
			corrections, float(stats.get("max_correction", 0.0)), int(stats.get("snapshots", 0))])
	print("realm check dungeon: events [%s]" % " / ".join((_s["events"] as Array).filter(func(e): return not String(e).begins_with("dungeon info"))))
	for path in _s["captures"]:
		print("realm check dungeon: capture ", path)
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if ok else 1)
