extends Node

## `--check-stairs`: the castle's moving staircases as a player meets them,
## on castle_interior (build/logs/aup_stairs.sh; --map castle_interior
## --character 901201). Each step is captured into `--capture-dir` (default
## build/captures/stairs):
##
##   land     joins; the flights are drawn (StairView): seven decks, their
##            railings, treads, the shut gates
##   to_foot  a flight docked at the player's storey: the walk to its foot,
##            and the flight seen from there (capture)
##   climb    up the treads to its head while it stays docked; the body
##            rises with the drawn deck (capture on the way)
##   top      at the head: the body stands a storey higher than it began
##            (capture)
##   moving   from the landing, a flight swings to its next landing: its
##            deck seen moving between two frames (capture mid-swing)
##   warning_line  at any step, the staircase warning line over the prompt
##            near a flight that swings or has shut its gates (capture)
##
## The verdict line says what was seen; it quits 0 only when every step was.

const STEP_TIMEOUT := 60.0
const TOTAL_TIMEOUT := 200.0
## Ends of a deck the walk aims for, metres inside the slab's end.
const INSET := 1.6
const REACH := 1.0

var game: Node
var _step := "land"
var _since := 0.0
var _started := 0.0
var _walk := 0.0
var _seen := {}
var _captures: Array = []
var _last_decks := {}
var _flight := -1
var _climb_from := 0.0
var _climb_top := 0.0
var _held := 0.0
var _dock_at := Vector3.INF
var _dock_since := 0.0
## The flight seen swinging (-1 none) and when.
var _mover := -1
var _mover_at := 0.0
## When the warning line was first seen (its capture comes a moment later).
var _line_at := 0.0

func _ready() -> void:
	_started = _now()
	_since = _now()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func walk_intent() -> float:
	return _walk

func _go(step: String) -> void:
	print("realm check stairs: frame %d step %s at %s" % [Engine.get_frames_drawn(), step,
		(game.session.own_position() as Vector3).snapped(Vector3(0.1, 0.1, 0.1))])
	_step = step
	_since = _now()
	_held = 0.0

func _see(what: String, detail: Variant) -> void:
	if not _seen.has(what):
		print("realm check stairs: seen %s: %s" % [what, detail])
	_seen[what] = detail

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/stairs")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check stairs: captured %s" % path)

func _face(at: Vector3) -> void:
	var me: Vector3 = game.session.own_position()
	game.cam_yaw = atan2(-(at.x - me.x), -(at.z - me.z))

func _walk_to(at: Vector3) -> float:
	var me: Vector3 = game.session.own_position()
	var flat := Vector2(at.x - me.x, at.z - me.z)
	if flat.length() > 0.3:
		game.cam_yaw = atan2(-flat.x, -flat.y)
	return flat.length()

## The flight docked nearest the player's storey whose foot is in reach
## (-1 when none): a deck that has not moved for a moment, its low end
## within a storey of the feet.
func _docked_near(prev: Dictionary) -> int:
	var stairs: StairView = game.stairs
	var me: Vector3 = game.session.own_position()
	var best := -1
	var best_d := INF
	for flight: int in stairs.decks:
		var at: Vector3 = stairs.deck_ends(flight)[1]
		if not prev.has(flight) or (prev[flight] as Vector3).distance_to(at) > 0.001:
			continue
		var ends := stairs.deck_ends(flight)
		var low: Vector3 = ends[0]
		if absf(low.y - me.y) > 1.5:
			continue
		var d := Vector2(low.x - me.x, low.z - me.z).length()
		if d < best_d:
			best_d = d
			best = flight
	return best

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null or not game.built or String(game.session.status()) != "joined":
		return
	var now := _now()
	if now - _started > TOTAL_TIMEOUT:
		_verdict("timed out in step " + _step)
		return
	if now - _since > STEP_TIMEOUT:
		_verdict("step %s timed out" % _step)
		return
	_held += delta
	var stairs: StairView = game.stairs
	var me: Vector3 = game.session.own_position()
	# each deck's head (its high end): a swing turns the deck about a pivot
	# near its middle, so the head shows the motion best
	if stairs.line_text != "" and not _seen.has("warning_line") and _step != "land":
		_see("warning_line", stairs.line_text)
		_line_at = now
	if _line_at > 0.0 and now - _line_at > 0.3:
		# a few frames on: the capture reads the frame drawn before this one
		_line_at = 0.0
		_capture("warning_line")
	var prev := _last_decks
	_last_decks = {}
	for flight: int in stairs.decks:
		_last_decks[flight] = stairs.deck_ends(flight)[1]
	match _step:
		"land":
			if stairs.decks.size() > 0 and _held > 1.5:
				_see("drawn", "%s, %d treads, decks at %s, me %s" % [str(stairs.counts), stairs.treads,
					str(stairs.decks.values().map(func(v): return (v as Vector3).snapped(Vector3(0.1, 0.1, 0.1)))),
					me.snapped(Vector3(0.1, 0.1, 0.1))])
				game.cam_distance = 7.0
				game.cam_pitch = -0.35
				_go("to_foot")
		"moving":
			if _mover < 0:
				for flight: int in _last_decks:
					if prev.has(flight) and _held > 0.5:
						var step := (_last_decks[flight] as Vector3).distance_to(prev[flight])
						if step > 0.02 and step < 2.0:
							_mover = flight
							_mover_at = _now()
							_see("moving", "flight %d moved %.3f m in a frame at %s" % [flight, step,
								(stairs.decks[flight] as Vector3).snapped(Vector3(0.1, 0.1, 0.1))])
							break
			elif stairs.decks.has(_mover):
				# the camera turns to it, then the capture mid-swing
				_face(stairs.decks[_mover])
				if _now() - _mover_at > 0.6 and not _seen.has("moving_captured"):
					_capture("moving")
					_seen["moving_captured"] = true
				# the warning line comes with the swing; a moment for it
				if _seen.has("moving_captured") and (_seen.has("warning_line") or _now() - _mover_at > 4.0):
					_seen.erase("moving_captured")
					_verdict("")
		"to_foot":
			if _flight < 0:
				_flight = _docked_near(prev)
				if _flight < 0:
					return
				print("realm check stairs: flight %d docked by me" % _flight)
			var ends := stairs.deck_ends(_flight)
			if ends.is_empty():
				return
			var low: Vector3 = ends[0]
			var high: Vector3 = ends[1]
			var foot := low + (high - low).normalized() * INSET
			if _walk_to(foot) < REACH:
				_climb_from = me.y
				_climb_top = high.y
				_go("foot")
			else:
				_walk = 1.0
		"foot":
			# up the flight from its foot: the stairwell as a player meets it
			var ends := stairs.deck_ends(_flight)
			if not ends.is_empty():
				_face(ends[1])
			if _held > 0.6:
				_capture("stairwell")
				_go("climb")
		"climb":
			var ends := stairs.deck_ends(_flight)
			if ends.is_empty():
				_verdict("flight %d left view" % _flight)
				return
			var low: Vector3 = ends[0]
			var high: Vector3 = ends[1]
			var head := high - (high - low).normalized() * INSET
			if not _seen.has("climbing") and me.y - _climb_from > 3.0:
				game.cam_distance = 7.0
				game.cam_pitch = -0.35
				_see("climbing", "%.1f m up flight %d" % [me.y - _climb_from, _flight])
				_capture("climbing")
			if _walk_to(head) < REACH:
				_go("top")
			else:
				_walk = 1.0
		"top":
			if _held > 0.8:
				var gained := me.y - _climb_from
				_see("top", "rose %.1f m (deck head at %.1f, feet %.1f)" % [gained, _climb_top, me.y])
				_capture("top")
				if gained <= 6.0:
					_verdict("the climb rose only %.1f m" % gained)
					return
				# from the landing, the next flight's swing
				game.cam_distance = 8.0
				game.cam_pitch = -0.3
				_go("moving")

func _verdict(failure: String) -> void:
	set_process(false)
	var wanted := ["drawn", "moving", "climbing", "top", "warning_line"]
	var missing := wanted.filter(func(k): return not _seen.has(k))
	var stats: Dictionary = game.session.stats()
	var ok := failure == "" and missing.is_empty()
	print("realm check stairs: %s | seen {%s} | missing [%s] | captures %d | corrections %d (max %.3f m)" % [
		"ok" if ok else (failure if failure != "" else "incomplete"),
		" ; ".join(_seen.keys().map(func(k): return "%s: %s" % [k, _seen[k]])), ", ".join(missing), _captures.size(),
		int(stats.get("corrections", 0)), float(stats.get("max_correction", 0.0))])
	get_tree().quit(0 if ok else 1)
