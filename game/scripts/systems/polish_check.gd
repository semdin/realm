extends Node

## `--check-polish`: the small HUD pieces, on the grounds (build/logs/
## aup_polish.sh; --character 902101, the travel kit's broom, at the castle
## approach). No walk: everything happens where the character stands, each
## step fails at once when it is stuck (STEP_TIMEOUT), the whole run in
## under TOTAL_TIMEOUT. Captures go to `--capture-dir` (default
## build/captures/polish).
##
##   readout    the debug readout hidden; its key (GameSettings.DEBUG_KEY)
##              shows it (capture), again hides it
##   ping       the minimap's "N ms"
##   arrow      the Up arrow held a moment walks the body
##   alt_enter  Alt+Enter toggles fullscreen, again toggles it back
##   broom      Shift mounts: the take-off swoosh, the broom icon leads the
##              effects row with its green landing mark; the pointer over it
##              opens its tooltip (controls, height and speed; capture); up
##              (jump) past the landing height the mark turns red and the
##              open tooltip says "Cannot land here" (capture); Shift in the
##              air is refused with the broom's refusal sound and the reason
##              on the notice band (capture); down to the ground, Shift
##              dismounts, the icon goes and the landing sounds
##
## The verdict line says what was seen; it quits 0 only when every step was.

const STEP_TIMEOUT := 12.0
const TOTAL_TIMEOUT := 80.0
const WANTED := ["readout_hidden", "readout_shown", "ping", "arrow_walk", "alt_enter", "mounted", "swoosh",
	"broom_icon", "broom_tip", "cannot_land", "landing_refused", "dismounted", "icon_gone", "landing_sound"]

var game: Node
var _step := "wait"
var _since := 0.0
var _started := 0.0
var _seen := {}
var _captures: Array = []
var _forward := 0.0
var _jump := false
var _descend := false
var _drive := false
var _from := Vector3.ZERO
var _count := 0
var _asks := 0
var _done := false

func _ready() -> void:
	_started = _now()
	_since = _now()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

## main.gd: the check steers only while it flies the broom.
func drives() -> bool:
	return _drive

func walk_intent() -> float:
	return _forward

func jump_intent() -> bool:
	return _jump

func descend_intent() -> bool:
	return _descend

func _go(step: String) -> void:
	print("realm check polish: %.1f s step %s" % [_now() - _started, step])
	_step = step
	_since = _now()

func _see(what: String, detail: Variant = "") -> void:
	if not _seen.has(what):
		print("realm check polish: seen %s: %s" % [what, detail])
	_seen[what] = detail

func _key(code: Key, pressed: bool, alt := false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	event.alt_pressed = alt
	Input.parse_input_event(event)

## The pointer comes to rest over `control` (its tooltip opens after the
## hover delay).
func _hover(control: Control) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = control.get_global_rect().get_center()
	motion.global_position = motion.position
	Input.warp_mouse(motion.position)
	Input.parse_input_event(motion)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/polish")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check polish: captured %s" % path)

func _mounted() -> bool:
	return bool(game.session.own_body().get("mounted", false))

func _process(_delta: float) -> void:
	if _done or game == null or game.session == null:
		return
	var now := _now()
	if now - _started > TOTAL_TIMEOUT:
		_verdict("timed out in step " + _step)
		return
	if _step != "wait" and now - _since > STEP_TIMEOUT:
		_verdict("step %s stuck" % _step)
		return
	var held := now - _since
	var bar: HudBuffBar = game.hud.buff_bar if game.built else null
	var broom: HudBuffBar.BuffIcon = bar.broom_icon if bar != null else null
	match _step:
		"wait":
			if game.built and String(game.session.status()) == "joined" and not MapLoadingScreen.shared(get_tree()).is_open():
				_go("settle")
		"settle":
			if held > 1.5:
				if game.readout.visible:
					_verdict("the readout shows without its key")
					return
				_see("readout_hidden")
				_key(GameSettings.DEBUG_KEY, true)
				_key(GameSettings.DEBUG_KEY, false)
				_go("readout")
		"readout":
			if game.readout.visible and String(game.readout.text).begins_with("realm"):
				_see("readout_shown", String(game.readout.text).get_slice("\n", 0))
				_go("readout_capture")
				await _capture("readout")
				_key(GameSettings.DEBUG_KEY, true)
				_key(GameSettings.DEBUG_KEY, false)
				_go("ping")
		"ping":
			var ping: Label = game.way.minimap.ping_label
			if ping.visible and ping.text.ends_with("ms") and not game.readout.visible:
				_see("ping", ping.text)
				_from = game.session.own_position()
				_key(KEY_UP, true)
				_go("arrow")
		"arrow":
			var moved := Vector2(game.session.own_position().x - _from.x, game.session.own_position().z - _from.z).length()
			if held > 0.7:
				_key(KEY_UP, false)
				if moved < 0.3:
					_verdict("the Up arrow moved the body %.2f m" % moved)
					return
				_see("arrow_walk", "%.2f m" % moved)
				_count = int(GameSettings.instance().fullscreen)
				_key(KEY_ENTER, true, true)
				_key(KEY_ENTER, false, true)
				_go("alt_enter")
		"alt_enter":
			if int(GameSettings.instance().fullscreen) != _count and held > 0.5:
				_key(KEY_ENTER, true, true)
				_key(KEY_ENTER, false, true)
				_go("alt_enter_back")
		"alt_enter_back":
			if int(GameSettings.instance().fullscreen) == _count and held > 0.5:
				_see("alt_enter", "fullscreen on and off")
				_count = AudioManager.played_count("broom_swoosh")
				game.travel.toggle_ride()
				_go("mount")
		"mount":
			if _mounted():
				_see("mounted")
				if broom != null and broom.is_visible_in_tree() and broom.landing_ok and bar.get_child(0) == broom:
					_see("broom_icon", "%s, %s" % [broom.item, broom.landing_text()])
				if AudioManager.played_count("broom_swoosh") > _count:
					_see("swoosh")
				if _seen.has("broom_icon") and _seen.has("swoosh") and held > 0.5:
					_hover(broom)
					_go("tip")
		"tip":
			# the tooltip opens after the viewport's hover delay
			if broom != null and broom.tips > 0 and held > 0.9:
				_see("broom_tip", broom.broom_lines()[1])
				_go("tip_capture")
				await _capture("broom_ok")
				_drive = true
				_jump = true
				_go("rise")
		"rise":
			var land: Dictionary = game.session.landing()
			if float(land.get("height", 0.0)) > 6.0 and not bool(land.get("ok", true)) and broom != null \
					and not broom.landing_ok and bar.broom_blocked_shown > 0:
				_jump = false
				_see("cannot_land", "%s at %.1f m" % [broom.landing_text(), float(land["height"])])
				_go("rise_capture")
				await _capture("broom_blocked")
				_count = AudioManager.played_count("broom_land_blocked")
				game.travel.toggle_ride()
				_go("refuse")
		"refuse":
			if game.travel.last_refusal == game.travel.refusal_text("ride", "no_landing") \
					and game.hud.notices.last_text == game.travel.last_refusal \
					and AudioManager.played_count("broom_land_blocked") > _count and _mounted():
				_see("landing_refused", game.travel.last_refusal)
				_go("refuse_capture")
				await _capture("landing_refused")
				_descend = true
				_go("descend")
		"descend":
			# well inside the landing height (the panel said OK from 3.1 m)
			var land: Dictionary = game.session.landing()
			if bool(land.get("ok", false)) and float(land.get("height", 9.0)) < 1.0:
				_descend = false
				_count = AudioManager.played_count("landing")
				game.travel.toggle_ride()
				_go("dismount")
		"dismount":
			if _mounted() and held > 1.5 * float(_asks + 1):
				_asks += 1
				print("realm check polish: still mounted, last refusal \"%s\"; asking again" % game.travel.last_refusal)
				game.travel.toggle_ride()
			if not _mounted():
				_see("dismounted")
				_drive = false
				if broom == null and held > 0.3:
					_see("icon_gone")
				if _seen.has("icon_gone") and AudioManager.played_count("landing") > _count:
					_see("landing_sound")
					_verdict("")

func _verdict(failure: String) -> void:
	if _done:
		return
	_done = true
	_drive = false
	_key(KEY_UP, false)
	var missing := WANTED.filter(func(k): return not _seen.has(k))
	var need := 0 if DisplayServer.get_name() == "headless" else 3
	var ok := failure == "" and missing.is_empty() and _captures.size() >= need
	print("realm check polish: %s - seen %d/%d%s, %d captures, %.0f s%s" % [
		"PASS" if ok else "FAIL", WANTED.size() - missing.size(), WANTED.size(),
		"" if missing.is_empty() else " (missing %s)" % ", ".join(missing), _captures.size(), _now() - _started,
		"" if failure == "" else " | " + failure])
	get_tree().quit(0 if ok else 1)
