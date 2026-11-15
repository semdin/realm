extends Node

## `--check-guide`: the seal shop and the dungeon guide the way a player uses
## them, against the coordinator and the grounds server (build/logs/dup.sh).
## The character comes from `tools/fixtures/make_prepared_character.py
## --dungeon-kit --dungeon-cleared normal --seals 20` (level 12 by the Trial
## Hall gate, gold on Easy and Normal, 20 Dungeon Seals). One step at a time:
##
##   land      lands on the grounds by the gate
##   to_gate   walks onto the gate (portal trial_entry) until its prompt shows
##   gate      F opens the gate window; waits for the gate's answer
##   shop      the Seal Shop tab; the purse shows the bag's seals; presses Buy
##             on the Trial Hall Key
##   bought    the answer "bought"; the seals drop by the price and the key is
##             in the bag (purse and Buy buttons refreshed); closes the window
##   guide     K opens the guide; its answer: Trial Hall Normal gold, Hard
##             open, Very Hard locked; the week's board for Trial Normal (may
##             be empty) and the titles
##
## The Seal Shop and the guide are held HOLD seconds and saved as PNGs into
## `--capture-dir` (default build/captures/guide). The verdict prints what it
## saw and quits 0 when every step passed.

const HOLD := 1.5
const STEP_TIMEOUT := 60.0
const GATE := "trial_entry"
const GATE_AT := Vector2(70.0, 69.0)
const KEY := "key_trial"

var game: Node
var _step := "land"
var _since := 0.0
var _held := 0.0
var _sent := false
var _walk := 0.0
var _seen: Dictionary = {}
var _captures: Array = []
var _events: Array = []
var _seals_before := -1
var _keys_before := -1
var _price := 0
var _row := -1

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _ready() -> void:
	_since = _now()
	print("realm check guide: scene for %s" % game.map_name)

func walk_intent() -> float:
	return _walk

## main.gd forwards every travel and dungeon event; a map change is no part
## of this check.
func on_event(event: Dictionary) -> void:
	var line := String(event.get("kind", ""))
	if line == "dungeon":
		line += " " + String(event.get("event", ""))
		if String(event.get("event", "")) == "guide":
			line += " week %s affixes %s records %s boards %d titles %s" % [str(event.get("week", "")),
				str(event.get("affixes", [])), str(event.get("records", [])), (event.get("boards", []) as Array).size(),
				str(event.get("titles", []))]
	if not line.begins_with("dungeon info"):
		_events.append(line)
		print("realm check guide: event %s" % line)

func before_reload() -> void:
	_verdict("the scene was rebuilt for a trip (%s)" % _step)

func _go(step: String) -> void:
	print("realm check guide: step %s" % step)
	_step = step
	_since = _now()
	_held = 0.0
	_sent = false

func _me() -> Vector3:
	return game.session.own_position()

func _count(item_id: String) -> int:
	var n := 0
	for cell: Variant in (game.session.sheet() as Dictionary).get("bag", []):
		if cell is Dictionary and String(cell.get("id", "")) == item_id:
			n += int(cell.get("amount", 1))
	return n

func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", root.path_join("build/captures/guide")))
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [_captures.size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		_captures.append(path)
		print("realm check guide: captured %s" % path)

## K as the keyboard sends it (main.gd's _unhandled_input opens the guide).
func _press_k() -> void:
	for down: bool in [true, false]:
		var key := InputEventKey.new()
		key.keycode = KEY_K
		key.physical_keycode = KEY_K
		key.pressed = down
		Input.parse_input_event(key)

func _process(delta: float) -> void:
	_walk = 0.0
	if game == null or game.session == null:
		return
	if _now() - _since > STEP_TIMEOUT:
		_verdict("step %s timed out" % _step)
		return
	if not (game.built and game.session.status() == "joined" and not game.session.sheet().is_empty()
			and not MapLoadingScreen.shared(get_tree()).is_open()):
		return
	_held += delta
	var travel: MapTravel = game.travel
	var dungeon: MapDungeon = game.dungeon
	var gate: HudDungeon = dungeon.gate_window
	var guide: HudDungeonGuide = dungeon.guide_window
	match _step:
		"land":
			if game.map_name != "grounds":
				_verdict("did not land on the grounds (%s)" % game.map_name)
			elif _held > HOLD:
				_seen["land"] = str(_me().snapped(Vector3(0.1, 0.1, 0.1)))
				_go("to_gate")
		"to_gate":
			var flat := Vector2(GATE_AT.x - _me().x, GATE_AT.y - _me().z)
			if flat.length() > 0.3:
				game.cam_yaw = atan2(-flat.x, -flat.y)
			if String(travel.active_portal.get("id", "")) == GATE:
				_go("gate")
			else:
				_walk = 1.0
		"gate":
			if not _sent and _held > 0.5:
				_sent = true
				if not travel.interact() or not gate.visible:
					_verdict("F at the gate did not open the gate window")
					return
			if _sent and gate.answers > 0:
				_go("shop")
		"shop":
			if not _sent:
				_sent = true
				_held = 0.0
				(gate.page_tabs["shop"] as Control).emit_signal("chosen")
			elif _held > HOLD:
				var wares := DungeonData.shop()
				for i in wares.size():
					if String((wares[i] as Dictionary).get("item", "")) == KEY:
						_row = i
						_price = int((wares[i] as Dictionary).get("seals", 0))
				_seals_before = _count(HudDungeon.SEAL)
				_keys_before = _count(KEY)
				var shown := gate._seals.text
				_seen["seal_shop"] = "page %s, purse \"%s\" (bag %d seals, %d keys), %d wares, %s" % [gate.page, shown,
					_seals_before, _keys_before, wares.size(), ", ".join(gate.buy_buttons.map(func(b): return "%s%s" % [b.name, " off" if b.disabled else ""]))]
				_capture("seal_shop")
				if gate.page != "shop" or not gate._shop_view.visible:
					_verdict("the Seal Shop tab did not show")
					return
				if shown != str(_seals_before):
					_verdict("the purse shows %s, the bag holds %d seals" % [shown, _seals_before])
					return
				if _row < 0 or _seals_before < _price:
					_verdict("no %s on sale or too few seals (%d of %d): use --seals 20" % [KEY, _seals_before, _price])
					return
				var buy: Button = gate.buy_buttons[_row]
				if buy.disabled:
					_verdict("Buy on %s is disabled with %d seals" % [KEY, _seals_before])
					return
				buy.pressed.emit()
				_go("bought")
		"bought":
			if gate.last_buy.is_empty():
				return
			var answer := gate.last_buy
			if not bool(answer.get("ok", false)):
				_verdict("the purchase was refused: %s" % answer.get("reason", ""))
				return
			var seals := _count(HudDungeon.SEAL)
			var keys := _count(KEY)
			if seals != _seals_before - _price or keys != _keys_before + 1 or gate._seals.text != str(seals):
				return   # the sheet follows the answer
			if not _sent:
				_sent = true
				_held = 0.0
			elif _held > HOLD:
				_seen["bought"] = "%s: seals %d -> %d (price %d), %s %d -> %d, purse \"%s\", notice \"%s\"" % [answer.get("reason", ""),
					_seals_before, seals, _price, KEY, _keys_before, keys, gate._seals.text, _notice_text()]
				_capture("seal_shop_bought")
				gate.close()
				_go("guide")
		"guide":
			if not _sent and _held > 0.5:
				_sent = true
				_press_k()
			if not _sent or not guide.visible or guide.answers == 0:
				if _sent and _held > 5.0 and not guide.visible:
					_verdict("K did not open the dungeon guide")
				return
			if _held < HOLD + 0.5:
				return
			var rec := guide.record("trial", DungeonData.difficulty_index("normal"))
			var hard_open := guide.is_unlocked("hard")
			var very_hard_open := guide.is_unlocked("very_hard")
			var runs := guide.board_runs()
			_seen["guide"] = "dungeon %s %s, record rank %d best %d ms rights %d, hard %s, very_hard %s, week %s affixes %s, board %d run(s) %s, titles %s" % [
				guide.dungeon_id, guide.difficulty, int(rec[0]), int(rec[1]), int(rec[2]), "open" if hard_open else "locked",
				"open" if very_hard_open else "locked", str(guide.guide.get("week", "")), str(guide.guide.get("affixes", [])),
				runs.size(), str(guide.board_rows), str(guide.guide.get("titles", []))]
			_capture("guide")
			if guide.dungeon_id != "trial" or guide.difficulty != "normal":
				_verdict("the guide opened on %s %s" % [guide.dungeon_id, guide.difficulty])
			elif int(rec[0]) != 3:
				_verdict("the guide shows rank %d on Trial Hall Normal (gold 3 expected)" % int(rec[0]))
			elif not hard_open or very_hard_open:
				_verdict("the guide shows Hard %s and Very Hard %s" % ["open" if hard_open else "locked", "open" if very_hard_open else "locked"])
			elif (guide.tabs["very_hard"] as Button).modulate.a > 0.5:
				_verdict("the Very Hard tab is not dimmed")
			else:
				_verdict("")

func _notice_text() -> String:
	var notices: Node = game.hud.get("notices")
	if notices == null:
		return "?"
	for child in notices.find_children("*", "Label", true, false):
		if (child as Label).visible and (child as Label).text != "":
			return (child as Label).text
	return ""

func _verdict(failure: String) -> void:
	set_process(false)
	var wanted := ["land", "seal_shop", "bought", "guide"]
	var missing := wanted.filter(func(k): return not _seen.has(k))
	var ok := failure == "" and missing.is_empty()
	print("realm check guide: %s | seen {%s} | missing [%s]" % ["ok" if ok else (failure if failure != "" else "incomplete"),
		" ; ".join(_seen.keys().map(func(k): return "%s: %s" % [k, _seen[k]])), ", ".join(missing)])
	print("realm check guide: events [%s]" % " / ".join(_events))
	for path in _captures:
		print("realm check guide: capture ", path)
	get_tree().quit(0 if ok else 1)
