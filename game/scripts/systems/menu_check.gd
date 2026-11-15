extends Node

## `--check-menu`: the Esc menu, its Settings and Credits and the way out of
## the world, as a player uses them, on a dev join (build/logs/aup_menu.sh
## starts the coordinator - admin surface 127.0.0.1:8094, token check-token -
## and the grounds server). Keys go in as real key events
## (Input.parse_input_event), buttons through their `pressed`, sliders
## through their value:
##
##   land        joins the grounds; the coordinator counts the player
##               (GET /admin/status); the settings files in user:// are kept
##               aside, to be put back at the end
##   escape      the bag open: Escape closes it and no menu opens; a target
##               held: Escape drops it and no menu opens; then Escape opens
##               the menu (capture)
##   settings    Settings: master volume 45 % (the Master bus follows),
##               interface scale 115 % (the window's content scale follows),
##               the bag key rebound to G (the next key press, consumed);
##               a capture of each tab
##   reopen      Escape closes the settings, G opens the bag (and I does
##               not), Escape closes it; Escape, Settings again: the sliders
##               and the key row still say so, user://settings.cfg and
##               user://audio_settings.json hold them, and a fresh read of the
##               file gives them back
##   credits     the Credits tab: the notices are there (capture)
##   leave       Change character: the countdown (capture); walking cancels
##               it; Change character again, standing still: the scene is
##               rebuilt to the login card (capture) and the coordinator no
##               longer counts the player (the connection closed, the server
##               saved and released it)
##
## The settings the check changed are put back (the files restored) before
## the verdict. The state lives on the Engine (STATE_KEY) across the scene
## reload. The verdict line says what was seen and quits 0 only when each was.

const STATE_KEY := &"menu_check_state"
const TOTAL_TIMEOUT := 180.0
const STEP_TIMEOUT := 30.0
const MASTER := 0.45
const SCALE := 1.15
const ACTION := "inventory"
const NEW_KEY := KEY_G
const FILES := ["user://settings.cfg", "user://audio_settings.json"]
const WANTED := ["land", "server_had_player", "esc_closes_window", "esc_drops_target", "menu", "settings",
	"master_volume", "ui_scale", "rebind", "tabs", "new_key_opens_bag", "kept_after_reopen", "file_saved",
	"fresh_read", "credits", "countdown", "cancelled_by_moving", "landed_login", "server_left", "restored"]

var game: Node
var _s: Dictionary = {}
var _walk := 0.0
## The last leave: presses made, and when _process may press again.
var _leave_presses := 0
var _leave_next := 0.0
var _admin := ""
var _token := ""

func _ready() -> void:
	_admin = String(game._arg("--check-admin", "127.0.0.1:8094"))
	_token = String(game._arg("--check-token", "check-token"))
	var carried: Variant = Engine.get_meta(STATE_KEY) if Engine.has_meta(STATE_KEY) else null
	if carried is Dictionary:
		_s = carried
	else:
		_s = {"step": "land", "started": _now(), "seen": {}, "captures": [], "scenes": 0, "kept": {}}
	_s["scenes"] = int(_s["scenes"]) + 1
	Engine.set_meta(STATE_KEY, _s)
	print("realm check menu: scene %d, step %s" % [int(_s["scenes"]), _s["step"]])
	_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(_delta: float) -> void:
	if _now() - float(_s["started"]) > TOTAL_TIMEOUT:
		_fail("timed out in step " + String(_s["step"]))
		return
	if _leave_next > 0.0 and _now() >= _leave_next and game.session != null and game.game_menu.leaving == "":
		if _leave_presses == 3:
			_fail("the countdown never ran out (cancels %s)" % game.game_menu.cancels)
			return
		_leave_presses += 1
		_s["left_at"] = _now()
		(game.game_menu.buttons["character"] as Button).pressed.emit()
		_leave_next = _now() + 1.0

## The walk the leave step asks main.gd for (forward, 0..1).
func walk_intent() -> float:
	return _walk

func _seen(what: String, detail: Variant = true) -> void:
	if not (_s["seen"] as Dictionary).has(what):
		print("realm check menu: seen %s: %s" % [what, detail])
	(_s["seen"] as Dictionary)[what] = detail

func _go(step: String) -> void:
	_s["step"] = step
	print("realm check menu: frame %d step %s" % [Engine.get_frames_drawn(), step])

func _until(test: Callable, seconds := STEP_TIMEOUT) -> bool:
	var end := _now() + seconds
	while _now() < end:
		if not is_inside_tree():
			return false
		if test.call():
			return true
		await get_tree().process_frame
	return false

func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

func _capture(tag: String) -> void:
	await _frames(3)
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/menu")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check menu: captured %s" % path)

## A real key press and release, as the keyboard sends them.
func _key(keycode: int) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = down
		Input.parse_input_event(event)
		await _frames(2)

## GET the coordinator's admin `path`: its parsed answer ({} when it failed).
func _admin_get(path: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var error := http.request("http://%s%s" % [_admin, path], ["x-service-token: %s" % _token])
	if error != OK:
		http.queue_free()
		return {}
	var answer: Array = await http.request_completed
	http.queue_free()
	if int(answer[0]) != HTTPRequest.RESULT_SUCCESS or int(answer[1]) != 200:
		return {}
	var parsed: Variant = JSON.parse_string((answer[3] as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}

## Players the coordinator counts online, and on the grounds.
func _players() -> Array:
	var status := await _admin_get("/admin/status")
	var maps := await _admin_get("/admin/maps")
	var grounds := -1
	for m: Dictionary in maps.get("maps", []):
		if String(m.get("map", "")) == "grounds":
			grounds = int(m.get("players", -1))
	return [int(status.get("players", -1)), grounds]

func _run() -> void:
	match String(_s["step"]):
		"land":
			await _world()
		"landed":
			await _landed()

## ================================================================== world

func _world() -> void:
	if not await _until(func(): return game.built and String(game.session.status()) == "joined"):
		_fail("never joined (status %s)" % game.session.status())
		return
	await _wait(1.5)
	_seen("land", game.session.own_position().snapped(Vector3(0.1, 0.1, 0.1)))
	_keep_files()
	var counted := await _players()
	if int(counted[0]) >= 1 and int(counted[1]) >= 1:
		_seen("server_had_player", "online %d, grounds %d" % counted)
	else:
		_fail("the coordinator does not count the player (online %d, grounds %d)" % counted)
		return
	var menu: HudGameMenu = game.game_menu
	var settings: SettingsWindow = game.settings_window

	# --- Escape: a window first, then the target, then the menu
	_go("escape")
	game.toggle_inventory()
	await _frames(2)
	if game.inventory.visible:
		await _key(KEY_ESCAPE)
		if not game.inventory.visible and not menu.visible:
			_seen("esc_closes_window")
	game.cycle_target()
	if not await _until(func(): return game.target != 0, 3.0):
		# nothing within Tab's reach: the check holds the nearest creature
		game.select_target(_nearest_creature())
	await _frames(2)
	if game.target == 0:
		print("realm check menu: no target to hold (%d entities in view, nearest creature %d)" % [
			(game.others.get("ids", PackedInt32Array()) as PackedInt32Array).size(), _nearest_creature()])
	if game.target != 0:
		var held: int = game.target
		await _key(KEY_ESCAPE)
		if game.target == 0 and not menu.visible:
			_seen("esc_drops_target", held)
	await _key(KEY_ESCAPE)
	if not await _until(func(): return menu.visible, 3.0):
		_fail("Escape did not open the menu")
		return
	_seen("menu")
	await _capture("menu")

	# --- Settings: volume, scale, a key
	_go("settings")
	(menu.buttons["settings"] as Button).pressed.emit()
	if not await _until(func(): return settings.visible and not menu.visible, 3.0):
		_fail("Settings did not open")
		return
	_seen("settings")
	await _capture("settings_general")
	(settings.sliders["ui_scale"] as HSlider).value = SCALE
	await _frames(3)
	if is_equal_approx(get_tree().root.content_scale_factor, SCALE * GameSettings.UI_SCALE_BASE):
		_seen("ui_scale", get_tree().root.content_scale_factor)
	await _capture("settings_general_scaled")
	(settings.tab_buttons["audio"] as Button).pressed.emit()
	await _frames(2)
	(settings.sliders["vol_Master"] as HSlider).value = MASTER
	await _frames(2)
	var master_db := AudioServer.get_bus_volume_db(0)
	if absf(master_db - linear_to_db(MASTER)) < 0.05:
		_seen("master_volume", "%.2f dB" % master_db)
	await _capture("settings_audio")
	(settings.tab_buttons["controls"] as Button).pressed.emit()
	await _frames(2)
	(settings.bind_buttons[ACTION] as Button).pressed.emit()
	await _frames(2)
	var listening := settings.listening == ACTION
	await _key(NEW_KEY)
	if listening and GameSettings.key(ACTION) == NEW_KEY and settings.rebinds == 1 and not game.inventory.visible:
		_seen("rebind", (settings.bind_buttons[ACTION] as Button).text)
	await _capture("settings_controls")
	var shown := []
	for page: String in SettingsWindow.TABS:
		(settings.tab_buttons[page] as Button).pressed.emit()
		await _frames(1)
		if settings.page_shown() == page:
			shown.append(page)
	if shown.size() == SettingsWindow.TABS.size():
		_seen("tabs", shown)

	# --- close, the new key, reopen: kept
	_go("reopen")
	await _key(KEY_ESCAPE)
	if not await _until(func(): return not settings.visible, 3.0):
		_fail("Escape did not close the settings")
		return
	await _key(KEY_I)
	var old_key_quiet: bool = not game.inventory.visible
	await _key(NEW_KEY)
	if old_key_quiet and await _until(func(): return game.inventory.visible, 2.0):
		_seen("new_key_opens_bag")
	await _key(KEY_ESCAPE)
	await _key(KEY_ESCAPE)
	if not await _until(func(): return menu.visible, 3.0):
		_fail("Escape did not open the menu again")
		return
	(menu.buttons["settings"] as Button).pressed.emit()
	await _until(func(): return settings.visible, 3.0)
	await _frames(2)
	var slider_scale: float = (settings.sliders["ui_scale"] as HSlider).value
	var slider_master: float = (settings.sliders["vol_Master"] as HSlider).value
	var key_text: String = (settings.bind_buttons[ACTION] as Button).text
	if is_equal_approx(slider_scale, SCALE) and is_equal_approx(slider_master, MASTER) \
			and key_text == OS.get_keycode_string(NEW_KEY):
		_seen("kept_after_reopen", "scale %.2f, master %.2f, %s" % [slider_scale, slider_master, key_text])
	var config := ConfigFile.new()
	var audio: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://audio_settings.json"))
	if config.load("user://settings.cfg") == OK and is_equal_approx(float(config.get_value("general", "ui_scale", 0.0)), SCALE) \
			and int(config.get_value("bindings", ACTION, 0)) == NEW_KEY and audio is Dictionary \
			and is_equal_approx(float(audio.get("Master", 0.0)), MASTER):
		_seen("file_saved", GameSettings.global_path())
	var fresh := GameSettings.reload_from_disk()
	if is_equal_approx(fresh.ui_scale, SCALE) and GameSettings.key(ACTION) == NEW_KEY:
		_seen("fresh_read")

	# --- Credits
	_go("credits")
	(settings.tab_buttons["credits"] as Button).pressed.emit()
	await _frames(4)
	var text: String = settings.credits.get_parsed_text()
	if text.contains("Human Shaders") and text.contains("CC BY 4.0") and text.contains("Literata") \
			and text.contains("Godot Engine") and text.contains("godot-rust"):
		_seen("credits", "%d characters" % text.length())
	await _capture("credits")
	settings.credits.scroll_to_line(settings.credits.get_line_count() / 3)
	await _capture("credits_scrolled")
	await _key(KEY_ESCAPE)

	# --- Change character: the countdown, cancelled by moving, then done
	_go("leave")
	await _key(KEY_ESCAPE)
	if not await _until(func(): return menu.visible, 3.0):
		_fail("Escape did not open the menu for the leave")
		return
	(menu.buttons["character"] as Button).pressed.emit()
	await _frames(2)
	if menu.leaving == "character":
		_seen("countdown", menu.note.text.replace("\n", " "))
	await _capture("countdown")
	_walk = 1.0
	var cancelled := await _until(func(): return menu.leaving == "", 4.0)
	_walk = 0.0
	if cancelled and int(menu.cancels.get("moved", 0)) == 1:
		_seen("cancelled_by_moving", menu.note.text)
	await _capture("cancelled")
	await _wait(1.5)
	_s["step"] = "landed"
	Engine.set_meta(STATE_KEY, _s)
	# from here _process presses Change character (again if a hit taken
	# cancels it) and nothing here awaits: the scene goes when the countdown
	# runs out
	_leave_presses = 0
	_leave_next = _now()

func _nearest_creature() -> int:
	var others: Dictionary = game.others
	if not others.has("ids"):
		return 0
	var me: Vector3 = game.session.own_position()
	var best := 0
	var best_d := INF
	var ids: PackedInt32Array = others["ids"]
	var kinds: PackedInt32Array = others["kinds"]
	var positions: PackedVector3Array = others["positions"]
	for i in ids.size():
		if kinds[i] == game.KIND_PLAYER:
			continue
		var d := positions[i].distance_to(me)
		if d < best_d:
			best_d = d
			best = ids[i]
	return best

## ================================================================ landed

func _landed() -> void:
	var door: FrontDoor = game.front_door
	if door == null or not await _until(func(): return door.login_visible() and door.select == null, 10.0):
		_fail("the change of character did not land on the login card")
		return
	_seen("landed_login", "after %.1f s" % (_now() - float(_s.get("left_at", _now()))))
	await _wait(1.0)
	await _capture("landed")
	var end := _now() + 20.0
	var counted := [-1, -1]
	while _now() < end:
		counted = await _players()
		if int(counted[0]) == 0 and int(counted[1]) == 0:
			break
		await _wait(0.5)
	if int(counted[0]) == 0 and int(counted[1]) == 0:
		_seen("server_left", "online 0, grounds 0 after %.1f s" % (_now() - float(_s.get("left_at", _now()))))
	_restore_files()
	_verdict("")

## ============================================================ the settings

## Keep the player's settings files aside: the check's changes must not stay.
func _keep_files() -> void:
	var kept := {}
	for path: String in FILES:
		kept[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	_s["kept"] = kept

func _restore_files() -> void:
	var kept: Dictionary = _s.get("kept", {})
	if kept.is_empty():
		return
	for path: String in kept:
		if kept[path] == null:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_buffer(kept[path])
			f.close()
	GameSettings.reload_from_disk()
	AudioManager.volumes["Master"] = 1.0
	AudioManager._load_settings()
	AudioManager._apply_volumes()
	if GameSettings.key(ACTION) == KEY_I and is_equal_approx(get_tree().root.content_scale_factor,
			GameSettings.instance().ui_scale * GameSettings.UI_SCALE_BASE):
		_seen("restored", "bag on %s, scale %.2f, master %.2f" % [GameSettings.key_name(ACTION),
			GameSettings.instance().ui_scale, AudioManager.get_volume("Master")])

## ================================================================ verdict

func _fail(why: String) -> void:
	_restore_files()
	_verdict(why)

func _verdict(failure: String) -> void:
	set_process(false)
	_walk = 0.0
	var seen: Dictionary = _s["seen"]
	var missing := WANTED.filter(func(k): return not seen.has(k))
	print("realm check menu: %s | seen {%s} | missing [%s] | captures %d" % ["ok" if failure == "" else failure,
		" ; ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing),
		(_s["captures"] as Array).size()])
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if failure == "" and missing.is_empty() else 1)
