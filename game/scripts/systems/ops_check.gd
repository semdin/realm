extends Node

## `--check-ops`: the realm's operations as a player sees them, driven
## through the coordinator's admin surface (`--check-admin 127.0.0.1:8094
## --check-token check-token`; build/logs/aup_ops.sh starts the servers):
##
##   land        joins the grounds
##   ga_on       POST /admin/ga {name: its own, on: true}; waits for its own
##               player info with `ga` (the emblem over its head and on its
##               unit frame)
##   rain_on     types "/ga rain on" into the chat (the Enter path); waits for
##               "Rain started.", RealmSession.raining() and the rain set in
##               (capture: rain on the grounds, the GA emblem)
##   rain_off    "/ga rain off"; waits for "Rain stopped." and the rain gone
##   update      POST /admin/announce update_soon 5 min; the notice band and
##               the chat say so (capture)
##   countdown   POST /admin/maintenance/begin (20 s); the banner counts down
##               locally between announcements (capture)
##   abort       POST /admin/maintenance/abort; the banner goes, the notice
##               band says it was called off (capture)
##   cycle       begin again (3 s): ANNOUNCING, SAVING (the frozen world's
##               notice, capture), DISCONNECTING, the connection closed and
##               the end screen "logged out for maintenance" (capture)
##   reconnect   presses the end screen's Reconnect: the scene joins again and
##               the realm, still in maintenance, refuses it; the end screen
##               says the server is under maintenance (capture)
##
## The state lives on the Engine (STATE_KEY) across the reconnect's scene
## reload. The verdict line says what was seen and quits 0 only when each was.

const HOLD := 1.5
const STEP_TIMEOUT := 45.0
const TOTAL_TIMEOUT := 300.0
const STATE_KEY := &"ops_check_state"
const WANTED := ["land", "ga", "ga_emblem", "rain_started", "rain", "rain_stopped", "rain_off", "update_soon",
	"countdown", "countdown_ticks", "aborted", "saving", "closed", "closed_screen", "refused_screen"]

var game: Node
var _s: Dictionary = {}
var _since := 0.0
var _held := 0.0
var _sent := false
var _mark := ""
var _admin := ""
var _token := ""

func _ready() -> void:
	_admin = String(game._arg("--check-admin", "127.0.0.1:8094"))
	_token = String(game._arg("--check-token", "check-token"))
	var carried: Variant = Engine.get_meta(STATE_KEY) if Engine.has_meta(STATE_KEY) else null
	if carried is Dictionary:
		_s = carried
	else:
		_s = {"step": "land", "started": _now(), "seen": {}, "captures": [], "http": [], "states": [], "scenes": 0,
			"name": ""}
	_s["scenes"] = int(_s["scenes"]) + 1
	Engine.set_meta(STATE_KEY, _s)
	_since = _now()
	print("realm check ops: scene %d, step %s" % [int(_s["scenes"]), _s["step"]])

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go(step: String) -> void:
	print("realm check ops: frame %d step %s (status %s)" % [Engine.get_frames_drawn(), step, game.session.status()])
	_s["step"] = step
	_since = _now()
	_held = 0.0
	_sent = false
	_mark = ""

func _seen(what: String, detail: Variant = true) -> void:
	if not (_s["seen"] as Dictionary).has(what):
		print("realm check ops: seen %s: %s" % [what, detail])
	(_s["seen"] as Dictionary)[what] = detail

func _has(what: String) -> bool:
	return (_s["seen"] as Dictionary).has(what)

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/ops")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check ops: captured %s" % path)

## POST `body` to the coordinator's admin surface; the answer goes into the
## state ("http") and to `done` (code, parsed body).
func _post(path: String, body: Dictionary, done := Callable()) -> void:
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray):
		var text := bytes.get_string_from_utf8()
		(_s["http"] as Array).append("%s %d %s" % [path, code if result == HTTPRequest.RESULT_SUCCESS else -result, text])
		print("realm check ops: %s -> %d %s" % [path, code, text])
		http.queue_free()
		if done.is_valid():
			var parsed: Variant = JSON.parse_string(text)
			done.call(code, parsed if parsed is Dictionary else {}))
	var error := http.request("http://%s%s" % [_admin, path],
		["x-service-token: %s" % _token, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		_fail("%s could not be sent (%d)" % [path, error])

## A line typed into the chat and sent with Enter.
func _type(text: String) -> void:
	var chat: HudChat = game.hud.chat
	chat.open()
	chat.input.text = text
	chat.input.text_submitted.emit(text)

func _chat_has(english: String) -> bool:
	var want := I18n.from_server(english)
	return (game.hud.chat.lines() as Array).any(func(l): return int(l["channel"]) == HudChat.SYSTEM and String(l["text"]) == want)

func _ready_to_play() -> bool:
	return game.built and game.session.status() == "joined" and not game.session.sheet().is_empty()

func _process(delta: float) -> void:
	if game == null or game.session == null:
		return
	var now := _now()
	if now - float(_s["started"]) > TOTAL_TIMEOUT:
		_fail("timed out in step " + String(_s["step"]))
		return
	if now - _since > STEP_TIMEOUT:
		_fail("step %s timed out" % _s["step"])
		return
	var ui: MaintenanceUI = game.maintenance
	if ui.state != "" and ((_s["states"] as Array).is_empty() or (_s["states"] as Array)[-1] != ui.state):
		(_s["states"] as Array).append(ui.state)
	var step := String(_s["step"])
	if not step in ["cycle", "reconnect", "refused"] and not _ready_to_play():
		return
	_held += delta
	match step:
		"land":
			if _held > HOLD:
				_s["name"] = String(game.session.sheet()["name"])
				_seen("land", "%s on %s" % [_s["name"], game.map_name])
				_go("ga_on")
		"ga_on":
			if not _sent:
				_sent = true
				_post("/admin/ga", {"name": _s["name"], "on": true})
			if game.own_ga:
				_seen("ga", "own player info ga")
				var emblem: Node = game.player.get_node_or_null("GAEmblem")
				if emblem != null and emblem.visible and game.hud.unit_frame.is_ga:
					_seen("ga_emblem", "over the head and on the unit frame")
					_go("rain_on")
		"rain_on":
			if not _sent:
				_sent = true
				# the camera lifts a little: rain reads best against the sky
				game.cam_pitch = -0.16
				_type("/ga rain on")
			if _chat_has("Rain started."):
				_seen("rain_started", I18n.from_server("Rain started."))
			var weather: RealmWeather = game.weather
			if _has("rain_started") and game.session.raining() and weather.rain_amount >= 0.999 \
					and weather.rain != null and weather.rain.emitting:
				if _mark == "":
					_mark = "wet"
					_held = 0.0
				elif _held > HOLD:
					_seen("rain", "raining, amount %.2f, %d drops, sound %s" % [weather.rain_amount, weather.rain.amount,
						weather.rain_sound != null and weather.rain_sound.playing])
					_capture("rain_ga")
					_go("rain_off")
		"rain_off":
			if not _sent:
				_sent = true
				_type("/ga rain off")
			if _chat_has("Rain stopped."):
				_seen("rain_stopped", I18n.from_server("Rain stopped."))
			var weather: RealmWeather = game.weather
			if _has("rain_stopped") and not game.session.raining() and weather.rain_amount <= 0.0 \
					and (weather.rain == null or not weather.rain.emitting):
				if _mark == "":
					_mark = "dry"
					_held = 0.0
				elif _held > HOLD:
					_seen("rain_off", "dry, sound %s" % (weather.rain_sound != null and weather.rain_sound.playing))
					_capture("rain_off")
					_go("update")
		"update":
			if not _sent:
				_sent = true
				game.cam_pitch = -0.35
				_post("/admin/announce", {"kind": "update_soon", "minutes": 5})
			var want := tr("An update is on its way: the realm restarts in about %d minutes.") % 5
			if game.hud.notices.last_text == want and _mark == "":
				_mark = "shown"
				_held = 0.0
			if _mark == "shown" and _held > 0.6:
				_seen("update_soon", want)
				_capture("update_soon")
				_go("countdown")
		"countdown":
			if not _sent:
				_sent = true
				_post("/admin/maintenance/begin", {"reason": "check", "countdown_seconds": 20})
			if ui.banner_visible() and ui.state == "ANNOUNCING":
				if _mark == "":
					_mark = ui.countdown_text()
					_held = 0.0
				elif _held > 2.5:
					var later := ui.countdown_text()
					if later != _mark:
						_seen("countdown_ticks", "%s -> %s" % [_mark, later])
					_seen("countdown", ui.title_label.text)
					_capture("countdown")
					_go("abort")
		"abort":
			if not _sent:
				_sent = true
				_post("/admin/maintenance/abort", {})
			if not ui.banner_visible() and ui.state == "ONLINE":
				if _mark == "":
					_mark = "gone"
					_held = 0.0
				elif _held > 0.8:
					_seen("aborted", "banner gone, notice \"%s\"" % game.hud.notices.last_text)
					_capture("aborted")
					_go("cycle")
		"cycle":
			if not _sent:
				_sent = true
				_post("/admin/maintenance/begin", {"reason": "check", "countdown_seconds": 3})
			if ui.state == "SAVING" and ui.banner_visible() and not _has("saving"):
				# two frames so the banner's new words are drawn
				if _mark != "saving":
					_mark = "saving"
					_held = 0.0
				elif _held > 0.05:
					_seen("saving", ui.title_label.text)
					_capture("saving")
			if ui.state == "DISCONNECTING" and ui.banner_visible() and not _has("disconnecting"):
				_seen("disconnecting", ui.title_label.text)
			var status: String = game.session.status()
			if status.begins_with("closed"):
				_seen("closed", status)
				if ui.screen_visible():
					if _mark != "screen":
						_mark = "screen"
						_held = 0.0
					elif _held > HOLD:
						_seen("closed_screen", "%s: %s" % [ui.screen_kind, ui.screen_title.text])
						if ui.screen_kind != "maintenance":
							_fail("the end screen after the cycle is %s, not maintenance" % ui.screen_kind)
							return
						_capture("logged_out")
						_go("reconnect")
		"reconnect":
			if not _sent:
				_sent = true
				_s["step"] = "refused"
				Engine.set_meta(STATE_KEY, _s)
				ui.reconnect_button.pressed.emit()
		"refused":
			var status: String = game.session.status()
			if status.begins_with("refused") and ui.screen_visible():
				if _mark != "screen":
					_mark = "screen"
					_held = 0.0
				elif _held > HOLD:
					_seen("refused_screen", "%s (%s): %s / %s" % [status, ui.screen_kind, ui.screen_title.text,
						ui.screen_detail.text])
					_capture("refused")
					if ui.screen_kind != "refused_maintenance":
						_fail("a join during maintenance showed %s" % ui.screen_kind)
						return
					_verdict("")

func _fail(why: String) -> void:
	_verdict(why)

func _verdict(failure: String) -> void:
	set_process(false)
	var seen: Dictionary = _s["seen"]
	var missing := WANTED.filter(func(k): return not seen.has(k))
	print("realm check ops: %s | seen {%s} | missing [%s]" % ["ok" if failure == "" else failure,
			" ; ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing)],
		" | maintenance states [%s] | admin [%s] | captures %d" % [" > ".join(_s["states"]),
			" / ".join(_s["http"]), (_s["captures"] as Array).size()])
	for path in _s["captures"]:
		print("realm check ops: capture ", path)
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if failure == "" and missing.is_empty() else 1)
