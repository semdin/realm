extends Node

## `--check-play USER PASSWORD`: the release smoke check, the shortest way a
## player goes into the realm, driven through the real screens' code paths
## (the card's fields and buttons, the roster's cards, Enter World). It runs
## in an exported game too (it is exported; the other checks are not):
##
##   card     logs USER in; an unknown account is registered (it then logs
##            straight in)
##   roster   the first character, or, on an empty roster, a new one created
##            in the create card (a random name, the first house)
##   world    Enter World: the scene is rebuilt for the ticket's map; the
##            session joins, the sheet arrives, the map is drawn
##
## Each step waits at most STEP_TIMEOUT, all of it TOTAL_TIMEOUT; any refusal
## the card or the roster shows fails at once. The verdict line quits 0 when
## the world was joined and drawn. The state lives on the Engine across the
## scene reload. `--check-play-limit SECONDS` gives the world and the whole run
## that long instead (a first start on a slow GPU compiles for minutes).

const STATE_KEY := &"play_smoke_state"
const TOTAL_TIMEOUT := 80.0
const STEP_TIMEOUT := 25.0
## The map's drawing, warm-up included.
const WORLD_TIMEOUT := 40.0
## The join itself: longer than main.gd's JOIN_TIMEOUT, so a join the
## server holds (a claim the coordinator does not answer: 20 s) is refused and
## tried again before this gives up.
const JOIN_STEP_TIMEOUT := 45.0

var game: Node
var _s: Dictionary = {}
var _done := false
var _total_limit := TOTAL_TIMEOUT
var _world_limit := WORLD_TIMEOUT
## The character screen while Enter World waits for its ticket.
var _entering: CharacterSelect = null

func _ready() -> void:
	var limit_at := OS.get_cmdline_user_args().find("--check-play-limit")
	if limit_at >= 0 and limit_at + 1 < OS.get_cmdline_user_args().size():
		_total_limit = maxf(TOTAL_TIMEOUT, float(OS.get_cmdline_user_args()[limit_at + 1]))
		_world_limit = maxf(WORLD_TIMEOUT, _total_limit)
	var carried: Variant = Engine.get_meta(STATE_KEY) if Engine.has_meta(STATE_KEY) else null
	if carried is Dictionary:
		_s = carried
	else:
		var args := OS.get_cmdline_user_args()
		var i := args.find("--check-play")
		if i < 0 or i + 2 >= args.size() or String(args[i + 1]).begins_with("--") or String(args[i + 2]).begins_with("--"):
			_fail("usage: --check-play USER PASSWORD")
			return
		_s = {"step": "card", "started": _now(), "user": String(args[i + 1]), "password": String(args[i + 2])}
	Engine.set_meta(STATE_KEY, _s)
	print("realm check play: step %s (%s build)" % [_s["step"], "release" if RealmPaths.is_release() else "dev"])
	_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(_delta: float) -> void:
	if _done or _s.is_empty():
		return
	if _now() - float(_s["started"]) > _total_limit:
		_fail("ran out of time at step %s" % _s["step"])
	elif is_instance_valid(_entering) and not _entering.enter_btn.disabled and _entering.status_label.text != "":
		_fail("Enter World was refused: %s" % _entering.status_label.text)

## Waits until `test` holds (true), or `fails` holds or `seconds` pass (false).
func _until(test: Callable, seconds := STEP_TIMEOUT, fails := Callable()) -> bool:
	var end := _now() + seconds
	while _now() < end and not _done:
		if not is_inside_tree():
			return false
		if test.call():
			return true
		if fails.is_valid() and fails.call():
			return false
		await get_tree().process_frame
	return bool(test.call())

func _run() -> void:
	if _done:
		return
	if game.front_door != null and String(_s["step"]) == "card":
		await _card()
	elif game.front_door == null and String(_s["step"]) == "world":
		await _world()
	else:
		_fail("%s came up at step %s" % ["the front door" if game.front_door != null else "the world", _s["step"]])

## The card shows a refusal (in its error or warning colour) and waits.
func _card_refused(card: LoginScreen) -> bool:
	var colour := card.status_label.get_theme_color("font_color")
	return not card.busy and card.status_label.text != "" \
		and (colour == LoginScreen.COLOR_ERROR or colour == LoginScreen.COLOR_WARN)

func _card() -> void:
	var door: FrontDoor = game.front_door
	var card: LoginScreen = door.login
	if not await _until(func(): return card.is_inside_tree() and card.submit_btn != null, 10.0):
		_fail("the login card never came up")
		return
	card.keep_prefs = false
	var signed_in := func(): return door.select != null and door.select.roster_loaded
	var refused := func(): return door.select == null and _card_refused(card)
	# log in; an unknown account comes back refused, then it is registered
	card.login_tab.pressed.emit()
	card.username_input.text = String(_s["user"])
	card.password_input.text = String(_s["password"])
	card.submit_btn.pressed.emit()
	var asked := func(): return card.consent_dialog.visible
	if await _until(func(): return signed_in.call() or asked.call(), STEP_TIMEOUT, refused) and asked.call():
		# an account from before the current terms accepts them first
		card.consent_dialog.boxes.age.button_pressed = true
		card.consent_dialog.boxes.terms.button_pressed = true
		card.consent_dialog.accept_btn.pressed.emit()
	if not await _until(signed_in, STEP_TIMEOUT, refused):
		if not refused.call():
			_fail("the login card never answered (says: %s)" % card.status_label.text)
			return
		print("realm check play: login refused (%s), registering %s" % [card.status_label.text, _s["user"]])
		card.register_tab.pressed.emit()
		card.username_input.text = String(_s["user"])
		card.password_input.text = String(_s["password"])
		card.confirm_input.text = String(_s["password"])
		card.consent.age.button_pressed = true
		card.consent.terms.button_pressed = true
		card.submit_btn.pressed.emit()
		# the one-time recovery code comes up before the login goes on
		if await _until(func(): return card.code_dialog.visible, STEP_TIMEOUT, refused) and card.code_dialog.visible:
			card.code_dialog.saved.button_pressed = true
			card.code_dialog.done_btn.pressed.emit()
		# registering logs straight in, then the roster loads
		if not await _until(signed_in, STEP_TIMEOUT, refused):
			_fail("not signed in after registering %s (card says: %s)" % [_s["user"], card.status_label.text])
			return
	print("realm check play: signed in as %s" % _s["user"])
	var select: CharacterSelect = door.select
	if select.characters.is_empty():
		await _create(select)
		if _done:
			return
	var picked: Dictionary = select.characters[0]
	print("realm check play: character %s (%s, level %s)" % [picked.get("name", "?"), picked.get("house", "?"), picked.get("level", "?")])
	_s["name"] = String(picked.get("name", ""))
	_s["step"] = "world"
	Engine.set_meta(STATE_KEY, _s)
	select.enter_btn.pressed.emit()
	# the scene is rebuilt for the world (this node goes with it, and the
	# timer's connection too); a refusal shows on the screen (_process)
	_entering = select
	get_tree().create_timer(STEP_TIMEOUT).timeout.connect(_enter_timeout.bind(select))

func _enter_timeout(select: CharacterSelect) -> void:
	_fail("Enter World did not leave the character screen (says: %s)" % select.status_label.text)

func _create(select: CharacterSelect) -> void:
	(select.roster_cards[0] as Button).pressed.emit()
	if not await _until(func(): return select.create_modal.visible, 5.0):
		_fail("the empty slot did not open the create card")
		return
	var houses: Array = select.house_buttons.keys()
	if houses.is_empty():
		_fail("the create card offers no house")
		return
	houses.sort()
	(select.house_buttons[houses[0]] as Button).pressed.emit()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var name_text := "Smoke"
	for i in 6:
		name_text += String.chr(97 + rng.randi_range(0, 25))
	select.name_input.text = name_text
	select.confirm_btn.pressed.emit()
	var created := func(): return select.characters.size() == 1 and not select.creating
	var refused := func(): return not select.creating and select.characters.is_empty() and select.modal_status.text != ""
	if not await _until(created, STEP_TIMEOUT, refused):
		_fail("the character was not created (card says: %s)" % select.modal_status.text)
		return
	print("realm check play: created %s (%s)" % [name_text, houses[0]])

func _world() -> void:
	var session: Node = game.session
	if session == null:
		_fail("the world has no session")
		return
	# a join that fails is tried again with a fresh ticket (main.gd
	# retry_join, the scene rebuilt: this step runs again there); the end
	# screen is the failure
	var failed := func(): return game.maintenance != null and game.maintenance.screen_visible()
	var joined := func(): return is_instance_valid(session) and session.status() == "joined" \
		and not (session.sheet() as Dictionary).is_empty()
	if not await _until(joined, JOIN_STEP_TIMEOUT, failed):
		if not is_inside_tree():
			return   # the scene was rebuilt for another try; the new one checks
		_fail("the world did not take the ticket: %s" % (session.status() if is_instance_valid(session) else "-"))
		return
	var sheet: Dictionary = session.sheet()
	print("realm check play: joined %s as %s" % [game.map_name, sheet.get("name", "?")])
	if String(sheet.get("name", "")) != String(_s.get("name", "")):
		_fail("the sheet is %s, the roster picked %s" % [sheet.get("name", ""), _s.get("name", "")])
		return
	if not await _until(func(): return game.built and not MapLoadingScreen.shared(get_tree()).is_open(), _world_limit, failed):
		_fail("the map was never drawn (%s)" % session.status())
		return
	# the map's own scene from the pck, not the pack's grey stand-in
	var scene := "res://maps/%s/%s.tscn" % [game.map_name, game.map_name]
	if ResourceLoader.exists(scene) and not is_instance_valid(game.map_view):
		_fail("%s exists but the map was drawn as the grey stand-in" % scene)
		return
	_done = true
	print("realm check play: PASS - %s joined %s and drawn, %.1f s" % [sheet.get("name", ""), game.map_name, _now() - float(_s["started"])])
	Engine.remove_meta(STATE_KEY)
	RealmGuard.set_exit_code(0)
	get_tree().quit(0)

func _fail(why: String) -> void:
	if _done:
		return
	_done = true
	print("realm check play: FAIL - %s" % why)
	Engine.remove_meta(STATE_KEY)
	RealmGuard.set_exit_code(1)
	get_tree().quit(1)
