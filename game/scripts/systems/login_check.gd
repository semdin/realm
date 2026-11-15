extends Node

## `--check-login`: the front door as a player goes through it, against the
## login service (build/logs/aup_login.sh starts the coordinator, the grounds
## server and realm_login). It drives the real screens' code paths (their
## buttons' `pressed`, the fields' text, the look editor's steppers, swatches
## and slider):
##
##   first account   the login card (capture), New Account, a fresh account
##                   that logs straight in; the empty roster (capture); the
##                   empty slot's card opens the create card, a house and a
##                   few look values (capture), Create; the character on the
##                   dais (capture); Enter World
##   world           the scene rebuilt for the ticket's map: the session's
##                   sheet carries the chosen name, house and look; the
##                   character in the world (capture)
##   change          the Esc menu's Change character: its countdown, then the
##                   character screen again without the card (the token is
##                   still held) and the same roster (capture); Edit
##                   Appearance: the next hairstyle, Save (capture), the dais
##                   wears it; Enter World joins again (the server released
##                   the character when the connection closed) and the sheet
##                   carries the edited hair; the end screen (as for a lost
##                   connection) and its Return to Login
##   second account  the card says the connection was lost; another fresh
##                   account tries the same name in another
##                   case; the create card shows the service's refusal,
##                   translated (capture)
##
## The state lives on the Engine (STATE_KEY) across the scene reloads. The
## verdict line says what was seen and quits 0 only when each was.

const STATE_KEY := &"login_check_state"
const TOTAL_TIMEOUT := 240.0
const STEP_TIMEOUT := 40.0
const TAKEN := "Character name already taken."
const WANTED := ["login_card", "registered", "empty_roster", "create_card", "look_edited", "created", "podium",
	"world_joined", "world_name", "world_house", "world_look", "world_drawn", "back_at_select", "rejoined",
	"look_edit_saved", "world_look_edited", "end_screen", "back_at_card",
	"second_registered", "name_taken"]
const CAPTURES := 7

var game: Node
var _s: Dictionary = {}
var _done := false

func _ready() -> void:
	var carried: Variant = Engine.get_meta(STATE_KEY) if Engine.has_meta(STATE_KEY) else null
	if carried is Dictionary:
		_s = carried
	else:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var letters := ""
		for i in 5:
			letters += String.chr(97 + rng.randi_range(0, 25))
		_s = {"step": "first", "started": _now(), "seen": {}, "captures": [], "scenes": 0,
			"user": "chk_%06d" % rng.randi_range(0, 999999), "user2": "chk_%06d" % rng.randi_range(0, 999999),
			"password": "Check%06d" % rng.randi_range(0, 999999), "name": "Lysa" + letters, "house": "nisera",
			"look": {}}
	_s["scenes"] = int(_s["scenes"]) + 1
	Engine.set_meta(STATE_KEY, _s)
	print("realm check login: scene %d, step %s" % [int(_s["scenes"]), _s["step"]])
	_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(_delta: float) -> void:
	if not _done and _now() - float(_s["started"]) > TOTAL_TIMEOUT:
		_fail("ran out of time at step %s" % _s["step"])

func _seen(what: String, detail: Variant = true) -> void:
	if not (_s["seen"] as Dictionary).has(what):
		print("realm check login: seen %s: %s" % [what, detail])
	(_s["seen"] as Dictionary)[what] = detail

## Waits until `test` holds (true) or `seconds` pass (false).
func _until(test: Callable, seconds := STEP_TIMEOUT) -> bool:
	var end := _now() + seconds
	while _now() < end:
		if not is_inside_tree():
			return false
		if test.call():
			return true
		await get_tree().process_frame
	return bool(test.call())

func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/login")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		print("realm check login: captured %s" % path)

func _go(step: String) -> void:
	print("realm check login: step %s" % step)
	_s["step"] = step
	Engine.set_meta(STATE_KEY, _s)

func _run() -> void:
	if game.front_door != null:
		match String(_s["step"]):
			"first":
				await _first_account()
			"second":
				await _second_account()
			"change":
				await _back_at_select()
			_:
				_fail("the login card came back at step %s" % _s["step"])
	elif String(_s["step"]) == "world":
		await _in_world()
	elif String(_s["step"]) == "world2":
		await _in_world_again()
	else:
		_fail("the world came up at step %s" % _s["step"])

## Register `user` on the card (it logs straight in) and wait for the
## character screen's roster.
func _register(user: String, capture_card: bool) -> CharacterSelect:
	var door: FrontDoor = game.front_door
	var card: LoginScreen = door.login
	if not await _until(func(): return card.is_inside_tree() and card.submit_btn != null, 10.0):
		_fail("the login card never came up")
		return null
	card.keep_prefs = false
	if String(_s["step"]) == "second":
		await _frames(2)
		if card.status_label.text == tr("The connection to the server was lost. Please log in again."):
			_seen("back_at_card", card.status_label.text)
	if capture_card:
		card.login_tab.pressed.emit()
		card.username_input.text = user
		card.password_input.text = String(_s["password"])
		await _frames(30)
		_seen("login_card", card.submit_btn.text)
		await _capture("login_card")
	card.register_tab.pressed.emit()
	card.username_input.text = user
	card.password_input.text = String(_s["password"])
	card.confirm_input.text = String(_s["password"])
	card.submit_btn.pressed.emit()
	if not await _until(func(): return door.select != null and door.select.roster_loaded):
		_fail("no roster after registering %s (card says: %s)" % [user, card.status_label.text])
		return null
	return door.select

func _first_account() -> void:
	var select := await _register(String(_s["user"]), true)
	if select == null:
		return
	_seen("registered", _s["user"])
	if not select.characters.is_empty():
		_fail("a fresh account has characters: %s" % [select.characters])
		return
	_seen("empty_roster", select.roster_title.text)
	await _frames(30)
	await _capture("empty_select")
	(select.roster_cards[0] as Button).pressed.emit()
	if not await _until(func(): return select.create_modal.visible and select.look_editor.visible, 5.0):
		_fail("the empty slot did not open the create card")
		return
	_seen("create_card")
	var house := String(_s["house"])
	(select.house_buttons[house] as Button).pressed.emit()
	var editor := select.look_editor
	var before: Dictionary = editor.look.duplicate()
	(editor.steppers["hair"][1] as Button).pressed.emit()
	(editor.steppers["hair"][1] as Button).pressed.emit()
	(editor.steppers["outfit"][1] as Button).pressed.emit()
	(editor.steppers["beard"][1] as Button).pressed.emit()
	(editor.swatches["hair_color"][4] as Button).pressed.emit()
	(editor.swatches["eyes"][2] as Button).pressed.emit()
	(editor.swatches["skin"][2] as Button).pressed.emit()
	(editor.sliders["height"] as HSlider).value = 0.4
	var changed: Array = []
	for key: String in editor.look:
		if not is_equal_approx(float(editor.look[key]), float(before[key])):
			changed.append(key)
	if changed.size() < 6:
		_fail("the look editor changed only %s" % [changed])
		return
	_s["look"] = editor.look.duplicate()
	_seen("look_edited", changed)
	select.name_input.text = String(_s["name"])
	await _frames(40)
	await _capture("create_modal")
	select.confirm_btn.pressed.emit()
	if not await _until(func(): return select.characters.size() == 1 and not select.creating):
		_fail("the character was not created (card says: %s)" % select.modal_status.text)
		return
	var made: Dictionary = select.characters[0]
	_seen("created", "%s %s" % [made.get("name", ""), made.get("house", "")])
	if String(made.get("name", "")) != String(_s["name"]) or String(made.get("house", "")) != house \
			or not is_instance_valid(select.current_body) or select.name_label.text != String(_s["name"]):
		_fail("the dais shows %s / %s" % [select.name_label.text, made])
		return
	_seen("podium", select.name_label.text)
	await _frames(40)
	await _capture("select_podium")
	_go("world")
	select.enter_btn.pressed.emit()
	# the scene is rebuilt for the world (this node goes with it, and the
	# timer's connection too); still here after this long, it did not go
	get_tree().create_timer(20.0).timeout.connect(_enter_timeout.bind(select))

func _enter_timeout(select: CharacterSelect) -> void:
	_fail("Enter World did not leave the character screen (says: %s)" % select.status_label.text)

func _in_world() -> void:
	var session: Node = game.session
	if not await _until(func(): return session.status() == "joined" and not (session.sheet() as Dictionary).is_empty()):
		_fail("the world did not take the ticket: %s" % session.status())
		return
	_seen("world_joined", game.map_name)
	var sheet: Dictionary = session.sheet()
	if String(sheet["name"]) == String(_s["name"]):
		_seen("world_name", sheet["name"])
	if String(sheet["house"]) == String(_s["house"]):
		_seen("world_house", sheet["house"])
	var look: Dictionary = sheet["look"]
	var wrong: Array = []
	for key: String in _s["look"]:
		if absf(float(look.get(key, -99.0)) - float(_s["look"][key])) > 0.011:
			wrong.append("%s %s != %s" % [key, look.get(key, "missing"), _s["look"][key]])
	if wrong.is_empty():
		_seen("world_look", look.size())
	else:
		print("realm check login: the sheet's look differs: %s" % [wrong])
	if not await _until(func(): return game.built and not MapLoadingScreen.shared(get_tree()).is_open(), 60.0):
		_fail("the map was never drawn")
		return
	# the character from the front (a new character faces the camera), close
	game.cam_distance = 4.0
	game.cam_side = 0.0
	await _frames(90)
	_seen("world_drawn")
	await _capture("world")
	# the Esc menu's Change character: the scene is rebuilt to the
	# character screen when its countdown runs out
	_go("change")
	var menu: HudGameMenu = game.game_menu
	menu.open()
	(menu.buttons["character"] as Button).pressed.emit()
	get_tree().create_timer(20.0).timeout.connect(_change_timeout.bind(menu))

func _change_timeout(menu: HudGameMenu) -> void:
	_fail("Change character did not leave the world (%s)" % menu.note.text)

## Back from the world by Change character: the character screen with the
## same roster, no card; then into the world again.
func _back_at_select() -> void:
	var door: FrontDoor = game.front_door
	if not await _until(func(): return door.select != null and door.select.roster_loaded, 15.0):
		_fail("Change character did not open the character screen (card shown: %s)" % door.login_visible())
		return
	var select := door.select
	if door.login_visible() or select.characters.size() != 1 			or String(select.characters[0].get("name", "")) != String(_s["name"]):
		_fail("the character screen after Change character shows %s" % [select.characters])
		return
	_seen("back_at_select", select.name_label.text)
	await _frames(40)
	await _capture("select_again")
	# Edit Appearance: the next hairstyle, Save; the dais wears it at once
	select.edit_btn.pressed.emit()
	if not await _until(func(): return select.editing and select.look_editor.visible, 5.0):
		_fail("Edit Appearance did not open the look editor")
		return
	var editor := select.look_editor
	var hair_before := int(editor.look["hair"])
	(editor.steppers["hair"][1] as Button).pressed.emit()
	var edited: Dictionary = editor.look.duplicate()
	await _frames(30)
	await _capture("edit_look")
	(editor._buttons.get_child(0) as Button).pressed.emit()
	var id := int(select.characters[0].get("id", 0))
	var kept: Dictionary = CharacterSelect.pending_looks.get(id, {})
	if select.editing or int(kept.get("hair", -1)) != int(edited["hair"]) or int(edited["hair"]) == hair_before 			or not is_instance_valid(select.current_body) or int(CharacterSelect.look_for(select.characters[0])["hair"]) != int(edited["hair"]):
		_fail("the edited look was not kept: hair %d -> %s, kept %s" % [hair_before, edited.get("hair"), kept])
		return
	_s["hair"] = int(edited["hair"])
	_seen("look_edit_saved", "hair %d -> %d" % [hair_before, int(edited["hair"])])
	_go("world2")
	select.enter_btn.pressed.emit()
	get_tree().create_timer(20.0).timeout.connect(_enter_timeout.bind(select))

func _in_world_again() -> void:
	var session: Node = game.session
	if not await _until(func(): return session.status() == "joined" and not (session.sheet() as Dictionary).is_empty()):
		_fail("the world did not take the second ticket: %s" % session.status())
		return
	_seen("rejoined", (session.sheet() as Dictionary).get("name", ""))
	# the look edited on the character screen, sent as the world was entered
	if not await _until(func(): return int(((session.sheet() as Dictionary)["look"] as Dictionary).get("hair", -1)) == int(_s["hair"]), 10.0):
		_fail("the edited hair never reached the sheet: %s" % [(session.sheet() as Dictionary)["look"]])
		return
	_seen("world_look_edited", "hair %d" % int(_s["hair"]))
	if not await _until(func(): return game.built and not MapLoadingScreen.shared(get_tree()).is_open(), 60.0):
		_fail("the map was never drawn the second time")
		return
	await _frames(30)
	_go("second")
	# the end screen a closed connection shows, and its button: through the
	# front door it says Return to Login and goes back to the card
	var ui: MaintenanceUI = game.maintenance
	ui.show_closed("closed: connection lost", true)
	if ui.reconnect_button.text != tr("Return to Login"):
		_fail("the end screen offers %s" % ui.reconnect_button.text)
		return
	_seen("end_screen", ui.reconnect_button.text)
	ui.reconnect_button.pressed.emit()

func _second_account() -> void:
	var select := await _register(String(_s["user2"]), false)
	if select == null:
		return
	_seen("second_registered", _s["user2"])
	(select.roster_cards[0] as Button).pressed.emit()
	if not await _until(func(): return select.create_modal.visible, 5.0):
		_fail("the second account's create card did not open")
		return
	(select.house_buttons["torvan"] as Button).pressed.emit()
	var other_case := String(_s["name"]).to_upper()
	select.name_input.text = other_case
	select.confirm_btn.pressed.emit()
	var want := I18n.from_server(TAKEN)
	if not await _until(func(): return not select.confirm_btn.disabled and select.modal_status.text == want, 15.0):
		_fail("%s was not refused as taken (card says: %s)" % [other_case, select.modal_status.text])
		return
	if I18n.current != I18n.SOURCE_LANGUAGE and want == TAKEN:
		_fail("the refusal is not translated: %s" % want)
		return
	_seen("name_taken", "%s: %s" % [other_case, want])
	await _frames(30)
	await _capture("name_taken")
	_verdict()

func _verdict() -> void:
	_done = true
	var seen: Dictionary = _s["seen"]
	var missing: Array = WANTED.filter(func(w): return not seen.has(w))
	var captures: int = (_s["captures"] as Array).size()
	var need := 0 if DisplayServer.get_name() == "headless" else CAPTURES
	var ok := missing.is_empty() and captures >= need
	print("realm check login: %s - seen %d/%d%s, %d captures, %.0f s, language %s" % [
		"PASS" if ok else "FAIL", WANTED.size() - missing.size(), WANTED.size(),
		"" if missing.is_empty() else " (missing %s)" % ", ".join(missing), captures,
		_now() - float(_s["started"]), I18n.current])
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if ok else 1)

func _fail(why: String) -> void:
	if _done:
		return
	print("realm check login: FAIL - %s" % why)
	_done = true
	var seen: Dictionary = _s["seen"]
	print("realm check login: seen %s" % ", ".join(seen.keys()))
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(1)
