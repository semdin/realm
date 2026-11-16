extends Node

## `--check-controls`: the controls and HUD answers to the 11-17 player
## requests, on the grounds (build/logs/w22_stack.sh; --character 922101,
## the travel kit's broom, at the castle approach inside its protected
## ground). Each step fails at once when it is stuck (STEP_TIMEOUT), the whole
## run in under TOTAL_TIMEOUT. Captures go to `--capture-dir` (default
## build/captures/controls).
##
##   safe_out   walks east out of the castle approach's protected ground
##   safe_in    walks back in: the cue's "Safe area" line shows and no sound
##              plays (leaving keeps its soft one) (capture)
##   to_yard    walks to the training yard; the nearest dummy is the target
##   zoom       the wheel out stops at CAM_FAR (capture), in at CAM_NEAR
##              (capture); at the near limit the lens stays clear of the
##              hero's body at the lowest, level and highest pitch
##   key_hold   the basic attack's key (Ctrl) held: casts at the cooldown's
##              cadence, none after it is let go
##   mouse_hold the left button held on the dummy: the same (capture of the
##              damage numbers, a made-up crit and a hit taken beside them)
##   numbers    the same numbers from CAM_FAR (capture): one size on screen
##   mounted    on the broom Ctrl casts nothing (it is descend there)
##   loot_keys  Z and the key under Escape (physical QuoteLeft; the Mac's §)
##              both reach the loot take
##   signs      the camera at 50-300 m from Kestrin's Forge's sign: it is
##              drawn inside its reach and faded out past it (captures)
##
## The verdict line says what was seen; it quits 0 only when every step was.

const STEP_TIMEOUT := 25.0
const TOTAL_TIMEOUT := 85.0
const WANTED := ["safe_out", "safe_in", "dummy", "zoom_far", "zoom_near", "key_hold", "key_release", "mouse_hold",
	"mouse_release", "numbers_far", "mounted_ctrl", "loot_keys", "signs"]
## In the training yard, a few metres west of its posts (spawn_tables.json
## dummies at x 86, z 22.5-31.5), world x, z, through the gate in the middle
## of its west fence (GroundsPrecinct: x 67, z 27).
const YARD_GATE := Vector2(62.0, 27.0)
const YARD := Vector2(80.0, 27.0)
const HOLD_S := 2.6
## The sign's distances the camera is put at (metres from its place).
const SIGN_DISTANCES := [50.0, 75.0, 95.0, 110.0, 160.0, 300.0]

var game: Node
var _step := "wait"
var _since := 0.0
var _started := 0.0
var _seen := {}
var _captures: Array = []
var _forward := 0.0
var _drive := false
var _done := false
var _count := 0
var _sounds := {}
var _dummy := 0
var _sign: Label3D = null
var _sign_at := 0
var _cam_override := false
var _cam_from := Vector3.ZERO
var _cam_to := Vector3.ZERO
var _sign_rows: Array = []

func _init() -> void:
	# after main.gd placed this frame's camera, before the signs size to it
	process_priority = 500

func _ready() -> void:
	_started = _now()
	_since = _now()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func drives() -> bool:
	return _drive

func walk_intent() -> float:
	return _forward

func _go(step: String) -> void:
	print("realm check controls: %.1f s step %s" % [_now() - _started, step])
	_step = step
	_since = _now()

func _see(what: String, detail: Variant = "") -> void:
	if not _seen.has(what):
		print("realm check controls: seen %s: %s" % [what, detail])
	_seen[what] = detail

func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func _mouse(button: MouseButton, pressed: bool, at: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = at
	event.global_position = at
	if pressed and button == MOUSE_BUTTON_LEFT:
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(event)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var dir := String(game._arg("--capture-dir", RealmPaths.root().path_join("build/captures/controls")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check controls: captured %s" % path)

func _me() -> Vector3:
	return game.session.own_position()

## Walk toward world (x, z); the distance left.
func _walk_to(x: float, z: float) -> float:
	var me := _me()
	var to := Vector2(x - me.x, z - me.z)
	game.cam_yaw = atan2(-to.x, -to.y)
	_forward = 1.0
	_drive = true
	return to.length()

func _stop() -> void:
	_forward = 0.0
	_drive = false

func _zone() -> String:
	return String((game.safe_cue as SafeZoneCue).zone)

func _nearest_dummy() -> int:
	var best := 0
	var best_d := 30.0
	for id: int in game.beasts:
		if game.beasts[id] is DummyView and game.drawn.has(id):
			var d: float = (game.drawn[id] as Vector3).distance_to(_me())
			if d < best_d:
				best_d = d
				best = id
	return best

## The shortest gap between the camera and the hero's body (a capsule from
## its feet to the top of its hair, 0.42 m round), metres.
func _lens_gap() -> float:
	var cam: Vector3 = game.camera.global_position
	var feet := _me()
	var y := clampf(cam.y, feet.y + 0.1, feet.y + 1.85)
	return Vector2(cam.x - feet.x, cam.z - feet.z).length() - 0.42 if absf(cam.y - y) < 0.001 \
		else Vector3(cam.x - feet.x, cam.y - y, cam.z - feet.z).length() - 0.42

func _find_sign(node: Node, text: String) -> Label3D:
	if node is Label3D and (node as Label3D).text == text and (node as Label3D).get_script() != null:
		return node
	for child in node.get_children():
		var found := _find_sign(child, text)
		if found != null:
			return found
	return null

func _process(_delta: float) -> void:
	if _cam_override:
		game.camera.global_position = _cam_from
		game.camera.look_at(_cam_to)
	if _done or game == null or game.session == null:
		return
	var now := _now()
	if now - _started > TOTAL_TIMEOUT:
		_verdict("timed out in step " + _step)
		return
	if _step != "wait" and now - _since > STEP_TIMEOUT:
		_verdict("step %s stuck at %s" % [_step, str(_me().snapped(Vector3.ONE * 0.1))])
		return
	var held := now - _since
	match _step:
		"wait":
			if game.built and String(game.session.status()) == "joined" and not MapLoadingScreen.shared(get_tree()).is_open():
				_go("settle")
		"settle":
			if held > 1.0:
				if _zone() == "":
					_verdict("the character does not start on protected ground (%s)" % str(_me()))
					return
				_sounds = {"in": AudioManager.played_count("ui_confirm"), "out": AudioManager.played_count("ui_close")}
				_go("safe_out")
		"safe_out":
			if _zone() == "":
				_stop()
				_see("safe_out", "at %s, leaving line \"%s\", ui_close %d -> %d" % [str(_me().snapped(Vector3.ONE * 0.1)),
					(game.safe_cue as SafeZoneCue)._label.text, int(_sounds["out"]), AudioManager.played_count("ui_close")])
				_go("safe_back")
			else:
				_walk_to(_me().x + 10.0, _me().z)
		"safe_back":
			if held < 0.6:
				return
			if _zone() != "":
				_stop()
				if held > 1.6:
					var cue: SafeZoneCue = game.safe_cue
					var chimes := AudioManager.played_count("ui_confirm") - int(_sounds["in"])
					if not cue.visible:
						_verdict("the protected-ground line does not show inside")
						return
					if chimes != 0:
						_verdict("entering protected ground played ui_confirm %d time(s)" % chimes)
						return
					_see("safe_in", "\"%s\" shown, entry sounds 0, crossings %s" % [cue._label.text, str(cue.crossings)])
					_go("safe_capture")
					await _capture("safe_in_silent")
					_go("to_yard")
			else:
				_walk_to(_me().x - 10.0, _me().z)
		"to_yard":
			if not _seen.has("yard_gate"):
				if _walk_to(YARD_GATE.x, YARD_GATE.y) < 1.5:
					_seen["yard_gate"] = true
				return
			var left := _walk_to(YARD.x, YARD.y)
			var dummy := _nearest_dummy()
			if dummy != 0 and (game.drawn[dummy] as Vector3).distance_to(_me()) < 9.0 or left < 2.0:
				_stop()
				if dummy == 0:
					_verdict("no training dummy near the yard")
					return
				_dummy = dummy
				game.select_target(dummy)
				var at: Vector3 = game.drawn[dummy]
				game.cam_yaw = atan2(-(at.x - _me().x), -(at.z - _me().z))
				game.cam_pitch = -0.3
				_see("dummy", "%d at %.1f m" % [dummy, at.distance_to(_me())])
				_go("zoom_out")
		"zoom_out":
			if held < 0.3:
				return
			for i in 30:
				_mouse(MOUSE_BUTTON_WHEEL_DOWN, true, get_viewport().get_visible_rect().size * 0.5)
			_go("zoom_far")
		"zoom_far":
			if held > 0.6:
				if not is_equal_approx(game.cam_distance, game.CAM_FAR):
					_verdict("the wheel out stopped at %.2f m, not %.1f" % [game.cam_distance, game.CAM_FAR])
					return
				_see("zoom_far", "%.1f m" % game.cam_distance)
				_go("zoom_far_capture")
				await _capture("zoom_far")
				for i in 50:
					_mouse(MOUSE_BUTTON_WHEEL_UP, true, get_viewport().get_visible_rect().size * 0.5)
				_go("zoom_near")
		"zoom_near":
			if held > 0.6:
				if not is_equal_approx(game.cam_distance, game.CAM_NEAR):
					_verdict("the wheel in stopped at %.2f m, not %.1f" % [game.cam_distance, game.CAM_NEAR])
					return
				_count = 0
				_sign_rows = []
				_go("zoom_pitch")
		"zoom_pitch":
			# the near limit at the lowest, level and highest pitch: the gap
			# between the lens and the body, a frame after each is set
			var pitches := [-1.3, -0.35, 0.4]
			if _count > 0:
				_sign_rows.append("pitch %.2f gap %.2f m" % [game.cam_pitch, _lens_gap()])
				if _lens_gap() < 0.3:
					_verdict("at the near limit the lens is %.2f m from the hero (pitch %.2f)" % [_lens_gap(), game.cam_pitch])
					return
			if _count < pitches.size():
				game.cam_pitch = pitches[_count]
				_count += 1
				return
			game.cam_pitch = -0.35
			_see("zoom_near", "%.1f m; %s" % [game.cam_distance, ", ".join(PackedStringArray(_sign_rows))])
			_go("zoom_near_capture")
			await _capture("zoom_near")
			game.cam_distance = 9.0
			game.cam_pitch = -0.3
			_count = int(game.check_casts)
			_key(KEY_CTRL, true)
			_go("key_hold")
		"key_hold":
			_face_dummy()
			if held > HOLD_S:
				_key(KEY_CTRL, false)
				var casts := int(game.check_casts) - _count
				if casts < 4:
					_verdict("Ctrl held %.1f s cast %d basic attacks (refusals %s)" % [HOLD_S, casts, str(game.check_refusals)])
					return
				_see("key_hold", "%d casts in %.1f s (cadence %.2f s), %d hits so far" % [casts, HOLD_S,
					game._basic_interval(), int(game.check_hits)])
				_count = int(game.check_casts)
				_go("key_release")
		"key_release":
			if held > 1.2:
				var after := int(game.check_casts) - _count
				if after > 1:
					_verdict("%d casts after Ctrl was let go" % after)
					return
				_see("key_release", "%d after release" % after)
				_count = int(game.check_casts)
				_mouse(MOUSE_BUTTON_LEFT, true, _dummy_on_screen())
				_go("mouse_hold")
		"mouse_hold":
			if int(game.check_casts) != int(_sounds.get("casts_seen", -1)):
				_sounds["casts_seen"] = int(game.check_casts)
				print("realm check controls: %.2f s cast %d (repeats %d, hold %s, left %s)" % [held, int(game.check_casts) - _count,
					int(game.basic_repeats), game.basic_hold, Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)])
			if held > HOLD_S:
				_mouse(MOUSE_BUTTON_LEFT, false, _dummy_on_screen())
				var casts := int(game.check_casts) - _count
				if casts < 4:
					_verdict("the left button held %.1f s cast %d basic attacks (hold %s, refusals %s)" % [HOLD_S, casts,
						game.basic_hold, str(game.check_refusals)])
					return
				_see("mouse_hold", "%d casts in %.1f s" % [casts, HOLD_S])
				# the last hits' numbers still rising, a made-up crit and a hit
				# taken beside them (after the count: a capture stalls a frame)
				_fake_numbers()
				_go("numbers_near_capture")
				await _capture("numbers_near")
				_count = int(game.check_casts)
				_go("mouse_release")
		"mouse_release":
			if held > 1.2:
				var after := int(game.check_casts) - _count
				if after > 1:
					_verdict("%d casts after the left button was let go" % after)
					return
				_see("mouse_release", "%d after release" % after)
				game.cam_distance = game.CAM_FAR
				_key(KEY_CTRL, true)
				_go("numbers_far")
		"numbers_far":
			_face_dummy()
			if held > 1.6:
				_fake_numbers()
				_see("numbers_far", "camera %.0f m" % game.cam_distance)
				_go("numbers_far_capture")
				await _capture("numbers_far")
				_key(KEY_CTRL, false)
				game.cam_distance = 9.0
				game.travel.toggle_ride()
				_count = 0
				_go("mount")
		"mount":
			if not bool(game.session.own_body().get("mounted", false)) and held > 2.0 * float(_count + 1):
				# refused while the fight still holds (the notice says why)
				_count += 1
				game.travel.toggle_ride()
			if bool(game.session.own_body().get("mounted", false)) and held > 0.8:
				_count = int(game.check_casts)
				_sounds["refusals"] = int(game.check_refusals.get("mounted", 0))
				_key(KEY_CTRL, true)
				_go("mounted_ctrl")
		"mounted_ctrl":
			if held > 1.5:
				_key(KEY_CTRL, false)
				var casts := int(game.check_casts) - _count
				var refused := int(game.check_refusals.get("mounted", 0)) - int(_sounds["refusals"])
				if casts != 0 or refused != 0:
					_verdict("Ctrl on the broom cast %d and was refused %d times" % [casts, refused])
					return
				_see("mounted_ctrl", "no cast, no refusal while mounted (hold state \"%s\")" % game.basic_hold)
				game.travel.toggle_ride()
				_count = 0
				_go("dismount")
		"dismount":
			if bool(game.session.own_body().get("mounted", false)) and held > 1.5 * float(_count + 1):
				_count += 1
				game.travel.toggle_ride()
			if not bool(game.session.own_body().get("mounted", false)) and held > 0.5:
				_count = int(game.check_loot_presses)
				_key(KEY_QUOTELEFT, true)
				_key(KEY_QUOTELEFT, false)
				_key(GameSettings.key("pickup_loot") as Key, true)
				_key(GameSettings.key("pickup_loot") as Key, false)
				_go("loot_keys")
		"loot_keys":
			if held > 0.3:
				var presses := int(game.check_loot_presses) - _count
				var mac := GameSettings.action_for(KEY_SECTION)
				if presses != 2 or mac != "pickup_loot":
					_verdict("the loot keys reached the take %d time(s) of 2 (section key: \"%s\")" % [presses, mac])
					return
				_see("loot_keys", "Z (%s) and the key under Escape (%s) both took; the section key too" % [
					GameSettings.key_name("pickup_loot"), GameSettings.second_key_name("pickup_loot")])
				_sign = _find_sign(game, I18n.upper(I18n.t("Kestrin's Forge")))
				if _sign == null:
					_verdict("Kestrin's Forge's sign is not in the scene")
					return
				_sign_at = 0
				_sign_rows = []
				_go("signs")
		"signs":
			_signs(held)

## The camera at each of SIGN_DISTANCES from the sign's place, raised and
## looking at it; a capture at each with what the sign did.
func _signs(held: float) -> void:
	var home: Vector3 = _sign.get_parent().global_transform * (_sign.get("_home") as Vector3)
	if _sign_at >= SIGN_DISTANCES.size():
		_cam_override = false
		_see("signs", "; ".join(PackedStringArray(_sign_rows)))
		_verdict("")
		return
	var d: float = SIGN_DISTANCES[_sign_at]
	if not _cam_override or held < 0.05:
		var away := Vector3(-home.x, 0.0, -home.z).normalized()   # toward the castle
		_cam_from = home + away * d * 0.94 + Vector3.UP * d * 0.34
		_cam_to = home
		_cam_override = true
		return
	if held < 0.9:
		return
	var reach := float(_sign.get("reach"))
	var away := _cam_from.distance_to(home)
	var amount := float(_sign.get("shown"))
	var want := clampf((reach + 14.0 - away) / 14.0, 0.0, 1.0)
	_sign_rows.append("%.0f m: shown %.2f, layers %d, scale %.1f, stood %.1f m nearer" % [away, amount, _sign.layers,
		_sign.scale.x, _sign.global_position.distance_to(home)])
	if absf(amount - want) > 0.05 or (amount <= 0.0) != (_sign.layers == 0):
		_verdict("the sign %.0f m from its place shows %.2f (want %.2f, reach %.0f, layers %d)" % [away, amount, want,
			reach, _sign.layers])
		return
	_go("sign_capture")
	await _capture("sign_%03dm" % int(d))
	_sign_at += 1
	_go("signs")

func _face_dummy() -> void:
	if _dummy != 0 and game.drawn.has(_dummy):
		var at: Vector3 = game.drawn[_dummy]
		game.cam_yaw = atan2(-(at.x - _me().x), -(at.z - _me().z))

func _dummy_on_screen() -> Vector2:
	if _dummy == 0 or not game.drawn.has(_dummy):
		return get_viewport().get_visible_rect().size * 0.5
	var at: Vector3 = (game.drawn[_dummy] as Vector3) + Vector3(0, 1.1, 0)
	var pos: Vector2 = game.camera.unproject_position(at)
	Input.warp_mouse(pos)
	return pos

## A critical hit on the dummy and a hit on the player beside the real ones
## (the capture shows all three kinds).
func _fake_numbers() -> void:
	var combat: CombatView = game.combat
	if _dummy != 0:
		combat._number({"target": _dummy, "amount": 1234, "flags": CombatView.FLAG_CRIT})
	combat._number({"target": combat.own_id, "amount": 87, "flags": 0})

func _verdict(failure: String) -> void:
	if _done:
		return
	_done = true
	_stop()
	_cam_override = false
	_key(KEY_CTRL, false)
	var missing := WANTED.filter(func(k): return not _seen.has(k))
	var need := 0 if DisplayServer.get_name() == "headless" else 8
	var ok := failure == "" and missing.is_empty() and _captures.size() >= need
	print("realm check controls: %s - seen %d/%d%s, %d captures, %.0f s%s" % [
		"PASS" if ok else "FAIL", WANTED.size() - missing.size(), WANTED.size(),
		"" if missing.is_empty() else " (missing %s)" % ", ".join(missing), _captures.size(), _now() - _started,
		"" if failure == "" else " | " + failure])
	get_tree().quit(0 if ok else 1)
