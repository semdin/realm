extends Node

## `--check-travel`: travel the way a player does it, against the coordinator
## and two linked map servers (grounds and castle_interior), one step at a
## time:
##
##   land          lands on the grounds (the castle approach)
##   to_door       walks north to the castle door until its prompt shows
##   door          holds the prompt, presses F (RealmSession.door)
##   door_wait     the loading screen comes up; the ticket rebuilds the scene
##   castle        (after the reload) the castle is joined and drawn
##   to_exit       walks to the vestibule's way out until its prompt shows
##   exit          holds the prompt, presses F
##   exit_wait     the loading screen again; the scene is rebuilt
##   grounds       (after the reload) back on the grounds
##   to_hearth     walks to the Hearth Pavilion until its prompt shows
##   hearth        F opens the Hearth window
##   window        holds the window, presses Orvell Square's Travel
##   hearth_trip   the flames, the fade, the arrival at Orvell Square
##   mount         Shift: waits for the body to mount (is_mounted)
##   rise          Space for a moment, then holds the mounted pose
##   descend       Ctrl until the body is near the ground
##   dismount      Shift: waits for the body to stand (a "no landing" refusal
##                 sends it back to descend)
##   waylink_pick  the Waylink picker (what a right-click on the Old Boot in the
##                 bag opens): Set down for the Hearth Pavilion
##   waylink_placed  the boot, its aura and countdown
##   waylink_hold  F grabs hold (the body kneels); the Waylink fires
##   waylink_arrived  set down near the Hearth Pavilion
##
## Every step holds HOLD seconds on screen and saves a PNG of the key moments
## into `--capture-dir` (default build/captures/travel). A map change rebuilds
## the scene, so the check's state lives on the Engine (STATE_KEY) and the new
## scene's check carries on from its step. The verdict prints what it saw and
## quits 0 when every step was seen.

const HOLD := 1.5
const STEP_TIMEOUT := 60.0
const TOTAL_TIMEOUT := 400.0
const STATE_KEY := &"travel_check_state"
const REACH := 1.2
## Castle door trigger (maps.json castle_door), the vestibule's way out, Orvell
## Square's hearth (travel.json): where the walks aim.
const DOOR_AT := Vector2(0.0, 6.5)
const EXIT_AT := Vector2(0.0, 62.8)
const ORVELL_HEARTH := "hearth_orvell_square"
const HOME_HEARTH := "hearth_pavilion"
const RISE_SECONDS := 1.0
const DESCEND_MAX := 8.0

var game: Node
var _s: Dictionary = {}
var _since := 0.0
var _held := 0.0
var _sent := false
var _walk := 0.0
var _jump := false
var _descend := false
var _next_ride := 0.0

func _ready() -> void:
	var carried: Variant = Engine.get_meta(STATE_KEY) if Engine.has_meta(STATE_KEY) else null
	if carried is Dictionary:
		_s = carried
	else:
		_s = {"step": "land", "started": _now(), "seen": {}, "captures": [], "refusals": {}, "results": [],
			"corrections": 0, "reloads": 0, "maps": []}
	Engine.set_meta(STATE_KEY, _s)
	(_s["maps"] as Array).append(String(game.map_name))
	_since = _now()
	print("realm check travel: scene for %s, step %s" % [game.map_name, _s["step"]])

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go(step: String) -> void:
	print("realm check travel: frame %d step %s at %s on %s" % [Engine.get_frames_drawn(), step,
		_me().snapped(Vector3(0.1, 0.1, 0.1)), game.map_name])
	_s["step"] = step
	_since = _now()
	_held = 0.0
	_sent = false

func _seen(what: String, detail: Variant = true) -> void:
	(_s["seen"] as Dictionary)[what] = detail

func _me() -> Vector3:
	return game.session.own_position() if game.session != null else Vector3.ZERO

func walk_intent() -> float:
	return _walk

func jump_intent() -> bool:
	return _jump

func descend_intent() -> bool:
	return _descend

## Every travel game event main.gd shows.
func on_event(event: Dictionary) -> void:
	var kind := String(event["kind"])
	var line := kind
	match kind:
		"travel_result":
			line = "%s %s %s" % [event["what"], "ok" if bool(event["ok"]) else "refused", event["reason"]]
			if not bool(event["ok"]):
				var r: Dictionary = _s["refusals"]
				r[String(event["reason"])] = int(r.get(String(event["reason"]), 0)) + 1
		"departing":
			line = "departing %s (%s) to %s" % [event["trip"], event["label"], event["map"]]
		"travel":
			line = "travel ticket for %s" % event["map"]
		"arrived":
			line = "arrived by %s" % event["trip"]
	(_s["results"] as Array).append(line)
	print("realm check travel: frame %d event %s" % [Engine.get_frames_drawn(), line])

## The scene is about to be rebuilt for a trip: the loading screen is up (a
## capture of it), the session's numbers are kept, the next step is set.
func before_reload() -> void:
	_s["reloads"] = int(_s["reloads"]) + 1
	_s["corrections"] = int(_s["corrections"]) + int(game.session.stats().get("corrections", 0))
	var screen := MapLoadingScreen.shared(get_tree())
	_seen("loading_%d" % int(_s["reloads"]), "%s / %s" % [screen.last_title, screen.last_status])
	_capture("loading_%d" % int(_s["reloads"]))
	match String(_s["step"]):
		"door_wait":
			_go("castle")
		"exit_wait":
			_go("grounds")
	Engine.set_meta(STATE_KEY, _s)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/travel")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check travel: captured %s" % path)

## Walk toward (x, z) on the ground: the camera turns there, forward 1.
func _walk_to(x: float, z: float) -> float:
	var me := _me()
	var flat := Vector2(x - me.x, z - me.z)
	if flat.length() > 0.3:
		game.cam_yaw = atan2(-flat.x, -flat.y)
	return flat.length()

func _ready_to_play() -> bool:
	return game.built and game.session.status() == "joined" and not game.session.sheet().is_empty() \
		and not MapLoadingScreen.shared(get_tree()).is_open()

func _process(delta: float) -> void:
	_walk = 0.0
	_jump = false
	_descend = false
	if game == null or game.session == null:
		return
	var now := _now()
	if now - float(_s["started"]) > TOTAL_TIMEOUT and String(_s["step"]) != "door_wait" and String(_s["step"]) != "exit_wait":
		_fail("timed out in step " + String(_s["step"]))
		return
	if now - _since > STEP_TIMEOUT:
		_fail("step %s timed out" % _s["step"])
		return
	if not _ready_to_play() and not String(_s["step"]).ends_with("_wait"):
		return
	_held += delta
	var travel: MapTravel = game.travel
	var me := _me()
	match String(_s["step"]):
		"land":
			if game.map_name != "grounds":
				_fail("did not land on the grounds (%s)" % game.map_name)
				return
			if _held > HOLD:
				_seen("land", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
				_go("to_door")
		"to_door":
			_walk_to(DOOR_AT.x, DOOR_AT.y)
			if String(travel.active_portal.get("id", "")) == "castle_door":
				_go("door")
			else:
				_walk = 1.0
		"door":
			_walk_to(DOOR_AT.x, DOOR_AT.y - 3.0)   # look at the door
			if _held > HOLD and not _sent:
				_sent = true
				_seen("door_prompt", travel.prompt)
				_capture("door_prompt")
				if not travel.interact():
					_fail("F did nothing at the castle door")
					return
				_go("door_wait")
		"door_wait", "exit_wait":
			var screen := MapLoadingScreen.shared(get_tree())
			if screen.is_open():
				_seen("loading_up_" + String(_s["step"]), screen.last_title)
		"castle":
			if game.map_name != "castle_interior":
				_fail("the door did not lead into the castle (%s)" % game.map_name)
				return
			# inside the vestibule, looking back toward its way out (the
			# camera behind the body would stand outside the walls)
			game.cam_yaw = PI
			game.cam_distance = 5.0
			if _held > HOLD:
				_seen("castle", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
				_capture("castle_arrival")
				_go("to_exit")
		"to_exit":
			_walk_to(EXIT_AT.x, EXIT_AT.y)
			if String(travel.active_portal.get("id", "")) == "vestibule_exit":
				_go("exit")
			else:
				_walk = 1.0
		"exit":
			if _held > HOLD and not _sent:
				_sent = true
				_seen("exit_prompt", travel.prompt)
				_capture("exit_prompt")
				travel.interact()
				_go("exit_wait")
		"grounds":
			if game.map_name != "grounds":
				_fail("the way out did not lead to the grounds (%s)" % game.map_name)
				return
			if _held > HOLD:
				_capture("grounds_arrival")
				_seen("grounds", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
				_go("to_hearth")
		"to_hearth":
			var hearth: Node3D = travel.nodes.roots.get(HOME_HEARTH)
			if hearth == null:
				_fail("no Hearth Pavilion on the grounds")
				return
			var at := travel.nodes.mouth(HOME_HEARTH) + TravelData.facing(TravelData.node(HOME_HEARTH)) * 1.2
			var left := _walk_to(at.x, at.z)
			if travel.active_node == HOME_HEARTH and left < REACH:
				_go("hearth")
			else:
				_walk = 1.0
		"hearth":
			var hearth: Node3D = travel.nodes.roots[HOME_HEARTH]
			_walk_to(hearth.global_position.x, hearth.global_position.z)
			if _held > HOLD and not _sent:
				_sent = true
				_seen("hearth_prompt", travel.prompt)
				_capture("hearth_prompt")
				travel.interact()
			if _sent and travel.hearthway.visible:
				_go("window")
		"window":
			if _held > HOLD and not _sent:
				_sent = true
				var window: HudHearthway = travel.hearthway
				_seen("hearth_window", "%d destinations, dust %d" % [window.listed.size(), window.dust_count()])
				_capture("hearth_window")
				var go: Button = window.travel_buttons.get(ORVELL_HEARTH)
				if go == null or go.disabled:
					_fail("Orvell Square cannot be travelled to (%s)" % ("no button" if go == null else "disabled"))
					return
				go.pressed.emit()
				_go("hearth_trip")
		"hearth_trip":
			if travel.fade_alpha() > 0.9 and not (_s["seen"] as Dictionary).has("fade"):
				_seen("fade", travel.fades)
				_capture("fade")
			var square: Dictionary = TravelData.node(ORVELL_HEARTH)
			var pos: Array = square.get("pos", [0, 0, 0])
			var near := Vector2(me.x - float(pos[0]), me.z - float(pos[2])).length() < 12.0
			if near and travel.arrivals.has("hearthway") and travel.fade_alpha() < 0.05:
				if not _sent:
					_sent = true
					_held = 0.0
				if _held > HOLD:
					_seen("orvell", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
					_capture("orvell_arrival")
					_go("mount")
		"mount":
			if game.player.is_mounted:
				_seen("mounted", "mounted_speed %.1f" % float(game.player.mounted_speed))
				_go("rise")
			elif now >= _next_ride:
				_next_ride = now + 2.0
				travel.toggle_ride()
		"rise":
			_jump = _held < RISE_SECONDS
			# the rider from the side, so the capture shows the broom
			game.cam_side = deg_to_rad(80.0)
			if _held > RISE_SECONDS + HOLD:
				var broom: BroomRig = game.player.broom
				_seen("mounted_pose", "%s, broom %s, grip %.2f" % [game.player.anim.current_clip if game.player.anim != null else "-",
					broom.model_path.get_file() if broom != null else "-",
					game.player.broom_grip.weight if game.player.broom_grip != null else -1.0])
				_capture("mounted")
				_go("descend")
		"descend":
			game.cam_side = 0.0
			_descend = true
			var own: Dictionary = game.session.own_body()
			var low := bool(own.get("on_floor", false)) or (game.session.pick(me + Vector3(0, 0.2, 0), Vector3.DOWN, 1.2) as Dictionary).size() > 0
			if (low and _held > 0.5) or _held > DESCEND_MAX:
				_go("dismount")
		"dismount":
			if not game.player.is_mounted:
				if _held > HOLD:
					_seen("dismounted", str(me.snapped(Vector3(0.1, 0.1, 0.1))))
					_capture("dismounted")
					_go("waylink_pick")
			elif not _sent:
				_sent = true
				travel.toggle_ride()
			elif _held > 3.0:
				_go("descend")   # refused (no landing) or lost: lower, then again
		"waylink_pick":
			# what a right-click on the Old Boot in the bag does
			# (inventory_arcane.gd): the HUD's Waylink picker
			var picker: HudWaylink = game.hud.waylink
			if not _sent:
				_sent = true
				picker.open_for(game.sheet_view)
			if _held > HOLD and picker.visible:
				_seen("waylink_picker", ", ".join(picker.buttons.keys()))
				_capture("waylink_picker")
				var place: Button = picker.buttons.get(HOME_HEARTH)
				if place == null or place.disabled:
					_fail("the Waylink picker cannot set down for the Hearth Pavilion")
					return
				place.pressed.emit()
				_go("waylink_placed")
		"waylink_placed":
			if not travel.waylinks.views.is_empty():
				var id: int = travel.waylinks.views.keys()[0]
				game.cam_side = deg_to_rad(60.0)
				if _held > HOLD:
					_seen("waylink_placed", "fires in %.1f s" % travel.waylinks.seconds_left(id))
					_capture("waylink_boot")
					_go("waylink_hold")
		"waylink_hold":
			# the owner holds on from the moment it is set down (the server
			# counts it in); anyone else grabs hold with F
			if not travel.active_waylink.is_empty() and not (_s["seen"] as Dictionary).has("waylink_prompt"):
				_seen("waylink_prompt", travel.prompt)
			if not travel.active_waylink.is_empty() and not bool(travel.active_waylink.get("holding", false)) and not _sent:
				_sent = true
				travel.interact()
			if game.player.kneeling and not (_s["seen"] as Dictionary).has("waylink_kneel"):
				_held = 0.0
				_seen("waylink_kneel", true)
			if (_s["seen"] as Dictionary).has("waylink_kneel") and _held > HOLD and not (_s["seen"] as Dictionary).has("waylink_held"):
				_seen("waylink_held", true)
				_capture("waylink_kneel")
			if travel.arrivals.has("waylink"):
				game.cam_side = 0.0
				_go("waylink_arrived")
		"waylink_arrived":
			if travel.fade_alpha() < 0.05 and _held > HOLD:
				var home: Dictionary = TravelData.node(HOME_HEARTH)
				var pos: Array = home.get("pos", [0, 0, 0])
				_seen("waylink_arrived", "%s, %.0f m from the Hearth Pavilion" % [str(me.snapped(Vector3(0.1, 0.1, 0.1))),
					Vector2(me.x - float(pos[0]), me.z - float(pos[2])).length()])
				_capture("waylink_arrival")
				_go("done")
		"done":
			if _held > HOLD:
				_verdict("")

func _fail(why: String) -> void:
	_verdict(why)

func _verdict(failure: String) -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var corrections := int(_s["corrections"]) + int(stats.get("corrections", 0))
	var seen: Dictionary = _s["seen"]
	var wanted := ["land", "door_prompt", "loading_1", "castle", "exit_prompt", "loading_2", "grounds", "hearth_prompt",
		"hearth_window", "fade", "orvell", "mounted", "mounted_pose", "dismounted", "waylink_picker", "waylink_placed",
		"waylink_prompt", "waylink_kneel", "waylink_arrived"]
	var missing := wanted.filter(func(k): return not seen.has(k))
	print("realm check travel: %s | maps [%s], %d reloads | seen {%s} | missing [%s]" % [
			"ok" if failure == "" else failure, ", ".join(_s["maps"]), int(_s["reloads"]),
			", ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing)],
		" | events [%s] | refusals {%s}" % [" / ".join(_s["results"]),
			", ".join((_s["refusals"] as Dictionary).keys().map(func(k): return "%s x%d" % [k, _s["refusals"][k]]))],
		" | captures %d | corrections %d (this map max %.3f m), snapshots %d" % [(_s["captures"] as Array).size(),
			corrections, float(stats.get("max_correction", 0.0)), int(stats.get("snapshots", 0))])
	for path in _s["captures"]:
		print("realm check travel: capture ", path)
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if failure == "" and missing.is_empty() else 1)
