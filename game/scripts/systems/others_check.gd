extends Node

## `--check-others`: another player drawn as it is, on a dev join
## (build/logs/aup_others.sh: the coordinator and the grounds server; the
## check character 900811 and the partner 900812 - level 23, house Nisera,
## the Sealed Wing Explorer title, the Runed Mantle - four metres apart). The
## check starts the partner itself: a second, headless client of this game
## (`--others-guest NAME --character 900812`, its log in
## build/logs/others_guest.log), stopped by its PID at the end if it has not
## quit by then.
##
##   land      both are in; the partner's body is in view and the server
##             answered who it is (inspect)
##   plate     its nameplate says its name, "Lv. 23 · Nisera" and « Sealed
##             Wing Explorer », and is drawn this frame; its body holds the
##             wand, wears the mantle and the look of its info (capture)
##   ready     a local line ("Ready when you are.") tells the partner to change
##   changed   pushed unasked: the partner's new look (another hair, hair
##             colour and outfit) and gear without the wand; its body
##             wears the new look and its hand is empty (capture)
##
## `--others-guest NAME` makes this client the partner: once NAME's local line
## is over NAME's head it asks for its new look (RealmSession.set_look) and
## takes its wand off (PlayerSheet "unequip" main_hand), then quits once both
## are on its own sheet and NAME is gone (or after `--guest-seconds`, 120).
##
## The verdict line says what was seen and quits 0 only when each was.

const PARTNER := 900812
const READY_LINE := "Ready when you are."
## The partner's new look (looks.json picks: indexes into each list).
const NEW_LOOK := {"hair": 4.0, "hair_color": 6.0, "outfit": 2.0}
const TIMEOUT := 150.0
const STEP_TIMEOUT := 40.0
const HOLD := 1.2
const WANTED := ["land", "info", "plate", "plate_drawn", "wand", "cloak", "look", "ready", "pushed", "new_look",
	"no_wand", "plate_after"]

var game: Node
var guest_of := ""
var _seen: Dictionary = {}
var _captures: Array = []
var _started := 0.0
var _done := false
var _guest_pid := 0
## Player infos as they came (the pushed one after the ready line).
var _infos: Array = []

func _ready() -> void:
	_started = _now()
	if guest_of != "":
		_guest.call_deferred()
	else:
		_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(_delta: float) -> void:
	if not _done and _now() - _started > (float(game._arg("--guest-seconds", "120")) if guest_of != "" else TIMEOUT):
		if guest_of != "":
			_guest_done("timed out")
		else:
			_verdict("timed out")

## main.gd hands every player info over as it comes.
func on_player_info(info: Dictionary) -> void:
	if int(info.get("character", 0)) == PARTNER:
		_infos.append(info)

func _see(what: String, detail: Variant = true) -> void:
	if not _seen.has(what):
		print("realm check others: seen %s: %s" % [what, detail])
	_seen[what] = detail

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
	var root := RealmPaths.root()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/others")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check others: captured %s" % path)

## The partner's entity (0 while it is not in view with its info).
func _partner() -> int:
	for id: int in game.player_infos:
		if int(game.player_infos[id].get("character", 0)) == PARTNER and game.heroes.has(id):
			return id
	return 0

## The camera beside the player, looking past it at the partner (the two
## plates side by side, not one over the other).
func _face(id: int) -> void:
	var me: Vector3 = game.player.global_position
	var to: Vector3 = (game.heroes[id] as Node3D).global_position - me
	game.cam_yaw = atan2(-to.x, -to.z) + 0.75
	game.cam_distance = 4.0
	game.cam_pitch = -0.18

## The partner's body: its wand node (null without one), its cloak and the
## look it wears.
func _wand(hero: HeroView) -> Node:
	return hero.body.find_child("EquippedWand", true, false)

func _run() -> void:
	if not await _until(func(): return game.built and String(game.session.status()) == "joined" \
			and not (game.session.sheet() as Dictionary).is_empty()):
		_verdict("never joined (status %s)" % game.session.status())
		return
	var own_name := String(game.session.sheet()["name"])
	_start_guest(own_name)
	if not await _until(func(): return _partner() != 0, 60.0):
		_verdict("the partner never came into view (guest pid %d)" % _guest_pid)
		return
	var id := _partner()
	var hero: HeroView = game.heroes[id]
	_see("land", "partner entity %d" % id)
	var info: Dictionary = game.player_infos[id]
	var who := String(info["name"])
	_see("info", "%s level %d %s titles %s gear %d look %d" % [who, int(info["level"]), info["house"], info["titles"],
		(info["gear"] as Array).size(), (info["look"] as Array).size()])
	_face(id)
	await _wait(HOLD)
	# --- the plate and the body as they are
	var plate: String = game.plates.text_of(id)
	var title := I18n.t(DungeonData.title_name("fc_explorer"))
	var sub := tr("Lv. %d  ·  %s") % [23, HudQuestScroll.house_name("nisera")]
	if plate.contains(who) and plate.contains(sub) and plate.contains(title):
		_see("plate", plate)
	if await _until(func(): return game.plates.is_drawn(id), 3.0):
		_see("plate_drawn")
	if _wand(hero) != null:
		_see("wand", str(info["gear"]))
	if hero.body.find_child("EquippedCloak", true, false) != null:
		_see("cloak", hero._worn_cloak)
	var worn: Dictionary = hero._worn_look
	if worn == HeroView.look_of_pairs(info["look"]):
		_see("look", "hair %s outfit %s" % [worn.get("hair", "-"), worn.get("outfit", "-")])
	await _capture("before")
	# --- the partner changes
	_infos.clear()
	game.session.send_chat(READY_LINE)
	_see("ready")
	var changed := func() -> bool:
		if _infos.is_empty():
			return false
		var last: Dictionary = _infos[-1]
		var look := HeroView.look_of_pairs(last["look"])
		var wand: bool = (last["gear"] as Array).any(func(g): return int(g["slot"]) == 4)
		return not wand and NEW_LOOK.keys().all(func(k): return is_equal_approx(float(look.get(k, -1.0)), float(NEW_LOOK[k])))
	if not await _until(changed):
		_verdict("the partner's new look and gear never came (%d infos, last %s)" % [_infos.size(),
			_infos[-1] if not _infos.is_empty() else {}])
		return
	_see("pushed", "%d infos" % _infos.size())
	await _frames(2)
	worn = hero._worn_look
	if NEW_LOOK.keys().all(func(k): return is_equal_approx(float(worn.get(k, -1.0)), float(NEW_LOOK[k]))):
		_see("new_look", "hair %s colour %s outfit %s" % [worn["hair"], worn["hair_color"], worn["outfit"]])
	if _wand(hero) == null:
		_see("no_wand")
	if game.plates.text_of(id).contains(who):
		_see("plate_after", game.plates.text_of(id))
	_face(id)
	await _wait(HOLD)
	await _capture("after")
	_verdict("")

## Starts the partner: this game again, headless, as `--others-guest`.
func _start_guest(own_name: String) -> void:
	var root := RealmPaths.root()
	var log_path := root.path_join("build/logs/others_guest.log")
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--log-file", log_path, "--",
		"--others-guest", own_name, "--character", str(PARTNER), "--server", game._arg("--server", "127.0.0.1:7777")]
	_guest_pid = OS.create_process(OS.get_executable_path(), args)
	print("realm check others: partner started (pid %d, log %s)" % [_guest_pid, log_path])

func _verdict(failure: String) -> void:
	if _done:
		return
	_done = true
	var missing := WANTED.filter(func(k): return not _seen.has(k))
	print("realm check others: %s | seen {%s} | missing [%s] | captures %d" % ["ok" if failure == "" else failure,
		" ; ".join(_seen.keys().map(func(k): return "%s: %s" % [k, _seen[k]])), ", ".join(missing), _captures.size()])
	var code := 0 if failure == "" and missing.is_empty() else 1
	# this player leaves first (the connection closes): the partner sees it go
	# and quits by itself; past a few seconds it is stopped by its own PID
	game.before_reload()
	game.process_mode = Node.PROCESS_MODE_DISABLED
	if game.session != null:
		game.session.free()
		game.session = null
	if _guest_pid > 0:
		var end := _now() + 8.0
		while OS.is_process_running(_guest_pid) and _now() < end:
			await _wait(0.25)
		if OS.is_process_running(_guest_pid):
			OS.kill(_guest_pid)
			print("realm check others: partner stopped (pid %d)" % _guest_pid)
	get_tree().quit(code)

## ================================================================== guest

var _guest_asked := false
var _guest_unequip := 0

func _guest() -> void:
	if not await _until(func(): return game.built and String(game.session.status()) == "joined" \
			and not (game.session.sheet() as Dictionary).is_empty(), 60.0):
		_guest_done("never joined (status %s)" % game.session.status())
		return
	print("realm guest others: joined as %s, waiting for %s" % [game.session.sheet()["name"], guest_of])
	var host := func() -> int:
		for id: int in game.player_names:
			if String(game.player_names[id]) == guest_of and game.heroes.has(id):
				return id
		return 0
	if not await _until(func(): return host.call() != 0, 60.0):
		_guest_done("%s never came into view" % guest_of)
		return
	var said := func() -> bool:
		var hero: Node = game.heroes.get(host.call())
		var bubble: Node = hero.get_node_or_null("SpeechBubble") if hero != null else null
		return bubble != null and String(bubble.text) == READY_LINE
	if not await _until(said, 90.0):
		_guest_done("%s never said it was ready" % guest_of)
		return
	print("realm guest others: %s is ready: new look %s, wand off" % [guest_of, NEW_LOOK])
	# The wand first: an item request names the sheet revision it was made
	# on, and the new look makes a new revision, so the look waits for it.
	var answers: Array = []
	game.sheet_view.equipment_answer.connect(func(a: Dictionary): answers.append(a))
	_guest_unequip = game.sheet_view.submit("unequip", "main_hand")
	_guest_asked = true
	if not await _until(func(): return not (game.session.sheet()["equipment"] as Dictionary).has("main_hand")):
		_guest_done("the wand never came off (request %d, answers %s)" % [_guest_unequip, answers])
		return
	var look: Dictionary = (game.session.sheet()["look"] as Dictionary).duplicate()
	for key: String in NEW_LOOK:
		look[key] = float(NEW_LOOK[key])
	game.session.set_look(look)
	var dressed := func() -> bool:
		var sheet: Dictionary = game.session.sheet()
		var now: Dictionary = sheet["look"]
		return not (sheet["equipment"] as Dictionary).has("main_hand") \
			and NEW_LOOK.keys().all(func(k): return is_equal_approx(float(now.get(k, -1.0)), float(NEW_LOOK[k])))
	if not await _until(dressed):
		_guest_done("the sheet never showed the new look without the wand (unequip request %d)" % _guest_unequip)
		return
	print("realm guest others: dressed; waiting for %s to go" % guest_of)
	await _until(func(): return host.call() == 0, 60.0)
	_guest_done("")

func _guest_done(failure: String) -> void:
	if _done:
		return
	_done = true
	print("realm guest others: %s | asked %s, unequip request %d" % ["ok" if failure == "" else failure, _guest_asked,
		_guest_unequip])
	get_tree().quit(0 if failure == "" else 1)
