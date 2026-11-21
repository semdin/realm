extends HudWindow
class_name HudDungeonGuide

## The dungeon guide (K, anywhere), the old game's approved window: every
## dungeon on the left (and the player's titles under them); for the chosen
## dungeon and difficulty what the character has done there (clear and medal,
## best time, final chests left today), whether the difficulty is open to them
## (a dimmed tab when not, worded on the first fact), the gold medal time,
## this week's curses, and the week's fastest full clears.
##
## Everything comes from one server answer (RealmSession.dungeon_guide -> a
## "dungeon" event `guide`: week, affixes, records [[dungeon, difficulty,
## rank, best_ms, rights]], boards [{dungeon, difficulty, week, runs}],
## titles); the window asks on opening and on every choice. Locked is worked
## out from the records as the server does (DungeonData.unlocked). "Show the
## way to the gate" lays the waypoint to the chosen dungeon's gate (MapWay:
## from another map the footprints lead to the door toward it) and closes
## the window.
##
## In a finished copy (MapDungeon.finished_run) the guide opens on that
## dungeon and difficulty and carries "Run it again" (the end of a run has no
## window of its own): the party leader's alone (disabled for everyone
## else), it asks the server for another run of the same dungeon and
## difficulty from inside the finished copy (RealmSession.dungeon_start with
## a gate of this dungeon); the party's ready check follows as at the gate
## (HudInvites) and "launch" takes everyone into a fresh copy. A refusal says
## why on the notice band (the gate window's words) and lets the leader ask
## again.

const MEDAL_NAMES := {3: "Gold", 2: "Silver", 1: "Bronze", 0: "Cleared"}  # i18n
const CURSE := Color(0.86, 0.62, 1.0)

var session: Node
## Set by MapWay: the waypoint to dungeon `id`'s gate (true when it was laid).
var show_way: Callable
var dungeon_id := ""
var difficulty := "normal"
## The server's last answer ({} before the first) and how many came (the
## check reads them).
var guide: Dictionary = {}
var answers := 0
## What the board shows now (rows, the check reads it).
var board_rows: Array = []
## The finished run of this copy ({} none): its dungeon and difficulty
## (protocol index) for "Run it again", and the replays asked for (the check
## reads them).
var finished: Dictionary = {}
var again_button: Button
var replays_sent := 0
## A replay asked for and not yet answered (launch, refusal, cancel).
var _asking := false

var _list: VBoxContainer
var _titles: VBoxContainer
var _heading: Label
var _band: Label
var tabs: Dictionary = {}   # difficulty -> Button
var _facts: GridContainer
var _board: VBoxContainer

func _init() -> void:
	super._init("Dungeon Guide", Vector2(820, 620))
	name = "DungeonGuide"

func _ready() -> void:
	super._ready()
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 14)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(split)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(210, 0)
	left.add_theme_constant_override("separation", 10)
	split.add_child(left)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	left.add_child(_list)
	var all := DungeonData.all()
	for id: String in all:
		var d: Dictionary = all[id]
		var b := HudKit.button("%s\n%s" % [I18n.t(String(d.get("display", id))),
			tr("Levels %d-%d") % [int(d.get("level_min", 1)), int(d.get("level_max", 1))]], 14)
		b.name = "Dungeon_" + id
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 54)
		b.pressed.connect(pick_dungeon.bind(id))
		_list.add_child(b)
	left.add_child(HudDungeon.section(tr("Your titles")))
	_titles = VBoxContainer.new()
	_titles.add_theme_constant_override("separation", 3)
	left.add_child(_titles)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	split.add_child(right)
	_heading = HudKit.label("", 22, HudKit.GOLD_HI, HudKit.title(), 4)
	right.add_child(_heading)
	_band = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	right.add_child(_band)
	var way := HudKit.button(tr("Show the way to the gate"), 13)
	way.name = "ShowWay"
	way.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	way.pressed.connect(show_way_to_gate)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	actions.add_child(way)
	again_button = HudKit.button(tr("Run it again"), 13)
	again_button.name = "RunAgain"
	again_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	again_button.visible = false
	again_button.pressed.connect(replay)
	actions.add_child(again_button)
	right.add_child(actions)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	right.add_child(tab_row)
	for id: String in DungeonData.DIFFICULTIES:
		var tab := HudKit.button(DungeonData.difficulty_name(id), 13)
		tab.name = "Tab_" + id
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var colour := DungeonData.colour(id)
		tab.add_theme_color_override("font_color", colour)
		tab.add_theme_color_override("font_pressed_color", Color.WHITE)
		# the chosen difficulty: its plate lit in the difficulty's colour
		var chosen := UIKit.plate("steel", "hover", Color(colour, 0.8))
		tab.add_theme_stylebox_override("pressed", chosen)
		tab.add_theme_stylebox_override("hover_pressed", chosen)
		tab.pressed.connect(pick_difficulty.bind(id))
		tab_row.add_child(tab)
		tabs[id] = tab
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", HudHearthway._card_box(HudKit.NAVY_LT, HudKit.GOLD_DK, 0.9))
	right.add_child(card)
	_facts = GridContainer.new()
	_facts.columns = 2
	_facts.add_theme_constant_override("h_separation", 14)
	_facts.add_theme_constant_override("v_separation", 4)
	card.add_child(_facts)
	right.add_child(HudDungeon.section(tr("This week's fastest")))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 160)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_board = VBoxContainer.new()
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.add_theme_constant_override("separation", 3)
	scroll.add_child(_board)
	right.add_child(HudKit.label(tr("Curses and boards turn every Monday at 06:00."), 12, HudKit.TEXT_DIM, HudKit.body(), 2))

func open() -> void:
	if not finished.is_empty():
		# the run just finished here: its dungeon and difficulty, the replay
		dungeon_id = String(finished.get("dungeon", dungeon_id))
		difficulty = DungeonData.difficulty_id(int(finished.get("difficulty", 1)))
	if dungeon_id == "" and not DungeonData.all().is_empty():
		dungeon_id = String(DungeonData.all().keys()[0])
	super.open()
	_ask()
	refresh()

## The waypoint to the chosen dungeon's gate; the window closes when it is laid.
func show_way_to_gate() -> void:
	if show_way.is_valid() and bool(show_way.call(dungeon_id)):
		close()

func pick_dungeon(id: String) -> void:
	dungeon_id = id
	_ask()
	refresh()

func pick_difficulty(id: String) -> void:
	difficulty = id
	_ask()
	refresh()

func _ask() -> void:
	if session != null:
		session.dungeon_guide()

## The "dungeon" events MapDungeon hands over: the `guide` answer, and for
## "Run it again" a refusal, a cancelled ready check (the leader may ask
## again; the notice band says why) or the launch (the copy is left).
func on_event(event: Dictionary) -> void:
	match String(event.get("event", "guide")):
		"guide":
			guide = event
			answers += 1
			if visible:
				refresh()
		"refused", "cancelled":
			_asking = false
			_judge_again()
		"launch":
			_asking = false
			finished = {}
			_judge_again()

## ------------------------------------------------------------ run it again

## The run of this copy is over (MapDungeon): "Run it again" is offered.
func finished_run(view: Dictionary) -> void:
	finished = view
	_judge_again()
	if visible:
		open()

## The party leader, or a player alone.
func leads() -> bool:
	if session == null:
		return false
	var party: Dictionary = session.party()
	return int(party.get("party", 0)) == 0 or int(party.get("leader", 0)) == int(party.get("me", -1))

## A gate of the finished run's dungeon (a door on an open map into its
## map), the one the server starts the replay from; "" when there is none.
func replay_portal() -> String:
	var map := String(DungeonData.dungeon(String(finished.get("dungeon", ""))).get("map", ""))
	var all: Variant = RealmContent.table("maps")
	for p: Dictionary in ((all as Dictionary).get("portals", []) if all is Dictionary else []):
		if map != "" and String(p.get("to_map", "")) == map and not TravelData.instanced(String(p.get("map_id", ""))):
			return String(p.get("id", ""))
	return ""

## The button: shown in a finished copy whose dungeon has a gate, on that
## run's page, pressable by the leader alone (asked again at every refresh:
## the party may change).
func _judge_again() -> void:
	if again_button == null:
		return
	# on the finished run's own page (another tab is another run)
	var own_page := dungeon_id == String(finished.get("dungeon", "")) \
		and difficulty == DungeonData.difficulty_id(int(finished.get("difficulty", 1)))
	again_button.visible = not finished.is_empty() and own_page and replay_portal() != ""
	again_button.disabled = not leads() or _asking
	again_button.tooltip_text = "" if leads() else tr("Only the party leader can start the dungeon.")

## "Run it again": the finished run's dungeon and difficulty once more.
func replay() -> void:
	var gate := replay_portal()
	if session == null or gate == "" or not leads():
		return
	replays_sent += 1
	_asking = true
	again_button.disabled = true
	session.dungeon_start(gate, int(finished.get("difficulty", 1)))
	AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

## The player's record on `dungeon` at difficulty index `index`: [rank,
## best_ms, rights] ([-1, 0, daily_rewards] when the answer has none).
func record(dungeon: String, index: int) -> Array:
	for r: Variant in guide.get("records", []):
		if r is Array and (r as Array).size() >= 5 and String(r[0]) == dungeon and int(r[1]) == index:
			return [int(r[2]), int(r[3]), int(r[4])]
	return [-1, 0, int(DungeonData.difficulty(DungeonData.difficulty_id(index)).get("daily_rewards", -1))]

## Best ranks on `dungeon` by difficulty index (-1 never cleared).
func ranks(dungeon: String) -> Array:
	var out: Array = []
	for i in DungeonData.DIFFICULTIES.size():
		out.append(int(record(dungeon, i)[0]))
	return out

## Whether `id` is open to the player on the chosen dungeon (everything looks
## open before the first answer).
func is_unlocked(id: String) -> bool:
	return guide.is_empty() or DungeonData.unlocked(ranks(dungeon_id), id)

## The week's board for the chosen dungeon and difficulty (runs, fastest
## first; [] when none).
func board_runs() -> Array:
	var index := DungeonData.difficulty_index(difficulty)
	for b: Variant in guide.get("boards", []):
		if b is Dictionary and String(b.get("dungeon", "")) == dungeon_id and int(b.get("difficulty", -1)) == index:
			return b.get("runs", [])
	return []

func refresh() -> void:
	if _facts == null:
		return
	var dungeon := DungeonData.dungeon(dungeon_id)
	_heading.text = I18n.t(String(dungeon.get("display", dungeon_id)))
	_band.text = tr("Levels %d-%d · 1-%d players") % [int(dungeon.get("level_min", 1)),
		int(dungeon.get("level_max", 1)), int(DungeonData.group().get("max_party", 5))]
	for b in _list.get_children():
		(b as Button).set_pressed_no_signal(String(b.name) == "Dungeon_" + dungeon_id)
	for id: String in tabs:
		var tab := tabs[id] as Button
		tab.set_pressed_no_signal(id == difficulty)
		tab.modulate.a = 1.0 if is_unlocked(id) else 0.45
	for child in _facts.get_children():
		_facts.remove_child(child)
		child.queue_free()
	var rules := DungeonData.difficulty(difficulty)
	if not is_unlocked(difficulty):
		var after := String(rules.get("unlock_after", ""))
		var need := DungeonData.difficulty_name(after)
		var medal := String(rules.get("unlock_medal", ""))
		_fact(tr("Locked"), (tr("clear %s with a %s medal first") % [need, tr(medal.capitalize())]) if medal != "" \
			else (tr("clear %s first") % need), HudKit.RED)
	var mine := record(dungeon_id, DungeonData.difficulty_index(difficulty))
	var rank := int(mine[0])
	if guide.is_empty():
		_fact(tr("Your clear"), "…")
	else:
		_fact(tr("Your clear"), tr(String(MEDAL_NAMES[rank])) if MEDAL_NAMES.has(rank) else tr("Not yet"), _medal_tint(rank, HudKit.PARCHMENT))
	var best_ms := int(mine[1])
	_fact(tr("Your best"), DungeonData.clock(best_ms / 1000.0) if best_ms > 0 else "—")
	var left := int(mine[2])
	_fact(tr("Final chest"), tr("unlimited") if left < 0 else (tr("%d left today") % left if left > 0 else tr("none left - helper")),
		HudKit.RED if left == 0 else HudKit.PARCHMENT)
	var par := DungeonData.par(dungeon, difficulty) * float(DungeonData.medals().get("gold", 1.0))
	_fact(tr("Gold medal"), tr("full clear within %s") % DungeonData.clock(par))
	var week: Array = guide.get("affixes", [])
	var n := mini(int(rules.get("affixes", 0)), week.size())
	if n == 0 and not guide.is_empty():
		_fact(tr("Curse"), tr("No curses on this difficulty."), HudKit.TEXT_DIM)
	for id: Variant in week.slice(0, n):
		var curse := DungeonData.affix(String(id))
		_fact(tr("Curse"), "%s - %s" % [I18n.t(String(curse.get("display", id))), I18n.t(String(curse.get("desc", "")))], CURSE)
	_fill_board(board_runs())
	_fill_titles()
	_judge_again()

func _fact(key: String, value: String, colour: Color = HudKit.PARCHMENT) -> void:
	_facts.add_child(HudKit.label(key, 13, HudKit.TEXT_DIM, HudKit.body(), 2))
	var v := HudKit.label(value, 14, colour, HudKit.bold(), 2)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_facts.add_child(v)

static func _medal_tint(rank: int, otherwise: Color) -> Color:
	return HudDungeonRun.MEDAL_TINTS.get(DungeonData.RANK_MEDALS.get(rank, ""), otherwise)

## The week's runs: place, time tinted by its medal, the party (name and
## level), deaths.
func _fill_board(runs: Array) -> void:
	for child in _board.get_children():
		_board.remove_child(child)
		child.queue_free()
	board_rows = []
	if runs.is_empty():
		var empty := HudKit.label(tr("No full clear this week yet - the first one sets the record.") if not guide.is_empty() else "…",
			13, HudKit.TEXT_DIM, HudKit.body(), 2)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_board.add_child(empty)
		return
	for i in runs.size():
		var run: Dictionary = runs[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_board.add_child(row)
		var time := DungeonData.clock(int(run.get("ms", 0)) / 1000.0)
		row.add_child(_cell("%d." % (i + 1), 34, HudKit.GOLD_HI if i == 0 else HudKit.TEXT))
		row.add_child(_cell(time, 60, _medal_tint(int(run.get("rank", -1)), HudKit.TEXT)))
		var names: Array[String] = []
		for p: Variant in run.get("party", []):
			if p is Array and (p as Array).size() >= 2:
				names.append("%s (%d)" % [String(p[0]), int(p[1])])
		var who := _cell(", ".join(PackedStringArray(names)), 0, HudKit.PARCHMENT)
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(who)
		var deaths := int(run.get("deaths", 0))
		row.add_child(_cell(tr("%d deaths") % deaths, 70, HudKit.TEXT_DIM))
		board_rows.append([i + 1, time, int(run.get("rank", -1)), ", ".join(PackedStringArray(names)), deaths])

func _cell(text: String, width: float, colour: Color) -> Label:
	var label := HudKit.label(text, 14, colour, HudKit.body(), 2)
	label.custom_minimum_size = Vector2(width, 0)
	return label

func _fill_titles() -> void:
	for child in _titles.get_children():
		_titles.remove_child(child)
		child.queue_free()
	var titles: Array = guide.get("titles", [])
	if titles.is_empty():
		_titles.add_child(HudKit.label(tr("None yet") if not guide.is_empty() else "…", 13, HudKit.TEXT_DIM, HudKit.body(), 2))
	for id: Variant in titles:
		var t := HudKit.label("✦ " + I18n.t(DungeonData.title_name(String(id))), 14, HudKit.GOLD_LT, HudKit.body(), 2)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_titles.add_child(t)
