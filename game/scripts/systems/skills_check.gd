extends Node

## `--check-skills`: the skill window (V) and the skill points as a player
## uses them, on a dev join (build/logs/aup_skills.sh: the coordinator and the
## grounds server; character 900801 from make_prepared_character.py --level 12
## --skills stun_bolt:9, so three points are free). Keys go in as real key
## events, the window's "+" and the bar's slot through their `pressed`:
##
##   land      the sheet is in: three free points, and the taskbar's skill
##             book carries the badge with 3 (capture)
##   open      V opens the skill window: Stun Bolt at level 9, the points
##             capsule says 3 (capture); the pointer rests on Stun Bolt's card
##             and its tooltip shows the numbers now and at Master (capture)
##   master    Stun Bolt's "+": the server's answer, then the sheet: level 10
##             (the card's plate and the bar's badge say "M"), 2 points left
##             (capture)
##   learn     Shockwave's "+" learns it: level 1, 1 point left (capture)
##   bar       a click on the bar's Disarm slot learns it the old way: level
##             1, no points left, the badge gone; the "+" buttons are dimmed
##             and the window refuses another point itself (capture)
##   close     V closes the window
##
## The verdict line says what was seen and quits 0 only when each was.

const TIMEOUT := 120.0
const STEP_TIMEOUT := 20.0
const HOLD := 1.0
const WANTED := ["land", "badge", "open", "points_shown", "tooltip", "master", "master_badge", "learn",
	"bar_learn", "badge_gone", "refused", "close"]

var game: Node
var _seen: Dictionary = {}
var _captures: Array = []
var _answers: Array = []
var _started := 0.0
var _done := false

func _ready() -> void:
	_started = _now()
	_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(_delta: float) -> void:
	if not _done and _now() - _started > TIMEOUT:
		_verdict("timed out")

func _see(what: String, detail: Variant = true) -> void:
	if not _seen.has(what):
		print("realm check skills: seen %s: %s" % [what, detail])
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
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/skills")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check skills: captured %s" % path)

func _key(keycode: int) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = down
		Input.parse_input_event(event)
		await _frames(2)

func _points() -> int:
	return int(game.session.skill_points())

func _level(spell: String) -> int:
	return int(game.session.skill_level(spell))

func _bar_slot(spell: String) -> HudSlot:
	var bar: HudActionBar = game.hud.action_bar
	return bar.spell_slots[bar.spell_order.find(spell)]

## "+" on `spell`'s card, then the server's answer and the sheet's new level.
func _train(spell: String, level: int, points: int) -> bool:
	var card: Variant = game.skill_window._cards.get(spell)
	if card == null or card.train_button.disabled:
		return false
	_answers.clear()
	card.train_button.pressed.emit()
	return await _until(func(): return _answered(spell) and _level(spell) == level and _points() == points)

func _answered(spell: String) -> bool:
	return _answers.any(func(a): return String(a["spell"]) == spell and bool(a["ok"]))

func _run() -> void:
	var window: HudSkillWindow = game.skill_window
	game.hud.action_bar.skill_answered.connect(func(a: Dictionary): _answers.append(a))
	if not await _until(func(): return game.built and String(game.session.status()) == "joined" \
			and not (game.session.sheet() as Dictionary).is_empty()):
		_verdict("never joined (status %s)" % game.session.status())
		return
	await _wait(1.5)
	if _points() != 3 or _level("stun_bolt") != 9:
		_verdict("the fixture is not level 12 with Stun Bolt 9 (points %d, stun bolt %d)" % [_points(), _level("stun_bolt")])
		return
	_see("land", "level %d, %d points" % [int(game.session.sheet()["level"]), _points()])
	if await _until(func(): return game.hud._skill_badge.points == 3, 3.0):
		_see("badge", game.hud._skill_badge.points)
	await _capture("badge")

	# --- V opens the window
	await _key(GameSettings.key("skills"))
	if not await _until(func(): return window.visible, 3.0):
		_verdict("V did not open the skill window")
		return
	await _wait(HOLD)
	var stun: Variant = window._cards["stun_bolt"]
	if stun.slot.badge_text == "9":
		_see("open", "stun bolt plate %s" % stun.slot.badge_text)
	if window._points.text == "3":
		_see("points_shown", window._points.text)
	await _capture("window")
	# the pointer rests on Stun Bolt's card: the tooltip beside the window
	var motion := InputEventMouseMotion.new()
	motion.position = (stun as Control).get_global_rect().get_center()
	motion.global_position = motion.position
	get_viewport().warp_mouse(motion.position)
	Input.parse_input_event(motion)
	if await _until(func(): return window._tip.visible, 3.0):
		var lines: Array = window._tip_body.get_children().filter(func(c): return c is Label).map(func(c): return c.text)
		_see("tooltip", " | ".join(lines))
	await _wait(HOLD * 0.5)
	await _capture("tooltip")
	var away := InputEventMouseMotion.new()
	away.position = Vector2(8, 8)
	away.global_position = away.position
	get_viewport().warp_mouse(away.position)
	Input.parse_input_event(away)
	await _frames(4)

	# --- Stun Bolt to Master
	if not await _train("stun_bolt", 10, 2):
		_verdict("Stun Bolt did not reach Master (level %d, points %d, answers %s)" % [_level("stun_bolt"), _points(), _answers])
		return
	_see("master", "level %d, %d points" % [_level("stun_bolt"), _points()])
	if await _until(func(): return stun.slot.badge_text == "M" and _bar_slot("stun_bolt").badge_text == "M" \
			and window._points.text == "2" and game.hud._skill_badge.points == 2, 3.0):
		_see("master_badge", "card %s, bar %s" % [stun.slot.badge_text, _bar_slot("stun_bolt").badge_text])
	await _wait(HOLD)
	await _capture("master")

	# --- Shockwave learned with "+"
	if not await _train("shockwave", 1, 1):
		_verdict("Shockwave was not learned (level %d, points %d)" % [_level("shockwave"), _points()])
		return
	if await _until(func(): return window._cards["shockwave"].slot.badge_text == "1" and window._points.text == "1", 3.0):
		_see("learn", "shockwave %d, %d point" % [_level("shockwave"), _points()])
	await _wait(HOLD)
	await _capture("learned")

	# --- the bar's own path: a click on an unlearned slot spends the point
	_answers.clear()
	_bar_slot("disarm").pressed.emit()
	if await _until(func(): return _answered("disarm") and _level("disarm") == 1 and _points() == 0):
		_see("bar_learn", "disarm %d" % _level("disarm"))
	if await _until(func(): return game.hud._skill_badge.points == 0 and window._points.text == "0" \
			and window._cards["flame_wave"].train_button.disabled, 3.0):
		_see("badge_gone", "badge %d" % game.hud._skill_badge.points)
	var sent := window.trains_sent
	window.train("flame_wave")
	await _frames(2)
	if window.trains_sent == sent and String(game.hud.notices.last_text) != "":
		_see("refused", game.hud.notices.last_text)
	await _wait(HOLD)
	await _capture("spent")

	# --- V closes it
	await _key(GameSettings.key("skills"))
	if await _until(func(): return not window.visible, 3.0):
		_see("close")
	_verdict("")

func _verdict(failure: String) -> void:
	if _done:
		return
	_done = true
	var missing := WANTED.filter(func(k): return not _seen.has(k))
	print("realm check skills: %s | seen {%s} | missing [%s] | captures %d" % ["ok" if failure == "" else failure,
		" ; ".join(_seen.keys().map(func(k): return "%s: %s" % [k, _seen[k]])), ", ".join(missing), _captures.size()])
	get_tree().quit(0 if failure == "" and missing.is_empty() else 1)
