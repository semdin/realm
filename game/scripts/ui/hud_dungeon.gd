extends HudWindow
class_name HudDungeon

## The dungeon gate window (F at a dungeon's door), the old game's approved
## Dungeon tab: a banner with the dungeon's boss, its level band and the medal
## times; five difficulty cards (1-5 diamonds, each in its colour, locked per
## the player's own unlocks); for the chosen one the run for this party as
## chips (creature levels, power, what it needs, the gold medal, the final
## chest, the key or the best time) and this week's curses on it (red tags,
## each curse's description on hover); the party at the gate with a status tag
## each (empty places up to the party cap); then the verdict and the button:
## "Ready check" for a party, "Enter" alone. A run of the player's that is
## still open offers its way back in ("Return to the dungeon (m:ss)", through
## the same door: the server lets a roster member back in).
##
## The server decides everything (RealmSession.dungeon_info / dungeon_start);
## the checks here only explain early what it would refuse. While open the
## window asks again every REFRESH_S. This week's curses come with the gate's
## answer (`affixes`, in order); a difficulty takes the first N of them
## (dungeons.json difficulty.<id>.affixes).
##
## Its second tab is the Seal Shop (the old window's): the Dungeon Seals in
## the bag, then dungeons.json rewards.shop as a two-column card grid, each
## with its Buy button (RealmSession.seal_buy; the server sells only within
## reach of a dungeon gate and answers through the item results, as the
## Hearth window's purchases do).

const REFRESH_S := 1.5
const WELL := Color("070b12")
const GOOD := Color(0.498, 0.839, 0.478)
const BAD := Color(0.937, 0.416, 0.373)
const FAINT := Color(0.435, 0.424, 0.400)
const SEAL := "dungeon_seal"
const Workshop := preload("res://scripts/ui/workshop_window.gd")

var session: Node
var hud: Node
## The player's sheet (main.gd's PlayerSheet): the item answers, the bag.
var sheet: PlayerSheet

var portal_id := ""
var difficulty := "normal"
## The gate's last answer ("info" event; {} before the first).
var info: Dictionary = {}
## Answers heard and starts sent (the check reads them).
var answers := 0
var starts_sent := 0
var _refresh_t := 0.0
var _active_at_ms := 0

var _banner: DungeonBanner
var cards: Dictionary = {}   # difficulty -> DifficultyCard
var _detail: PanelContainer
var _chips: GridContainer
var _facts_key := ""
## The chosen difficulty's curses as their tags (ids, in order).
var curses_shown: Array = []
var _curses: HFlowContainer
var _members: VBoxContainer
var _members_key := ""
var verdict: Label
var start_button: Button
var rejoin_button: Button

## "run" or "shop".
var page := "run"
var page_tabs: Dictionary = {}   # page id -> Workshop.TabChip
var _run_view: VBoxContainer
var _shop_view: VBoxContainer
var _tab_seals: Label
var _seals: Label
var _shop_grid: GridContainer
## Buy buttons by shop row (the check presses one).
var buy_buttons: Array = []
## The purchase waiting for its answer (op id, -1 none) and the last answer
## ({row, item, ok, reason}; the check reads it).
var _buy_id := -1
var _buy_row := -1
var last_buy: Dictionary = {}

func _init() -> void:
	super._init("Dungeon Gate", Vector2(680, 640))
	name = "DungeonGate"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 10)
	_banner = DungeonBanner.new()
	body.add_child(_banner)
	_build_tabs()
	var view := VBoxContainer.new()
	view.add_theme_constant_override("separation", 8)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(view)
	_run_view = view
	_shop_view = _build_shop()
	body.add_child(_shop_view)

	var row_cards := HBoxContainer.new()
	row_cards.add_theme_constant_override("separation", 6)
	view.add_child(row_cards)
	var diamonds := 1
	for id: String in DungeonData.DIFFICULTIES:
		var card := DifficultyCard.new(DungeonData.difficulty_name(id), DungeonData.colour(id), diamonds)
		card.name = "Tab_" + id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.chosen.connect(pick.bind(id))
		row_cards.add_child(card)
		cards[id] = card
		diamonds += 1

	_detail = PanelContainer.new()
	view.add_child(_detail)
	var detail_col := VBoxContainer.new()
	detail_col.add_theme_constant_override("separation", 8)
	_detail.add_child(detail_col)
	_chips = GridContainer.new()
	_chips.columns = 3
	_chips.add_theme_constant_override("h_separation", 6)
	_chips.add_theme_constant_override("v_separation", 6)
	detail_col.add_child(_chips)
	_curses = HFlowContainer.new()
	_curses.name = "Curses"
	_curses.add_theme_constant_override("h_separation", 6)
	_curses.add_theme_constant_override("v_separation", 4)
	detail_col.add_child(_curses)

	view.add_child(section(tr("Party at the gate")))
	_members = VBoxContainer.new()
	_members.add_theme_constant_override("separation", 3)
	_members.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.add_child(_members)
	verdict = HudKit.label("", 14, HudKit.TEXT, HudKit.bold(), 3)
	verdict.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	verdict.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	view.add_child(verdict)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	view.add_child(row)
	start_button = HudKit.gold_button(tr("Ready check"))
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.pressed.connect(_on_start)
	row.add_child(start_button)
	rejoin_button = HudKit.button(tr("Return to the dungeon"), 15)
	rejoin_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rejoin_button.custom_minimum_size = Vector2(0, 44)
	rejoin_button.pressed.connect(_on_rejoin)
	row.add_child(rejoin_button)
	if sheet != null:
		sheet.equipment_answer.connect(_bought)
		sheet.inventory_changed.connect(_refresh_shop)
	show_page(page)

## The Dungeon / Seal Shop tabs (the workshop's strip); the shop tab carries
## the seal count.
func _build_tabs() -> void:
	var strip := VBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	body.add_child(strip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	strip.add_child(row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(2, 0)
	row.add_child(pad)
	for p: Array in [["run", tr("Dungeon")], ["shop", tr("Seal Shop")]]:
		var tab := Workshop.TabChip.new(String(p[1]))
		tab.name = "Page_" + String(p[0])
		tab.chosen.connect(show_page.bind(String(p[0])))
		row.add_child(tab)
		page_tabs[String(p[0])] = tab
	var shop_tab: Workshop.TabChip = page_tabs["shop"]
	shop_tab.row.add_child(UITheme.icon_rect(SEAL, 16))
	_tab_seals = HudKit.label("", 12, HudKit.GOLD_LT, HudKit.body(), 0)
	shop_tab.row.add_child(_tab_seals)
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	strip.add_child(rule)

## The seal shop page: the purse, then the wares as a two-column card grid.
func _build_shop() -> VBoxContainer:
	var view := VBoxContainer.new()
	view.name = "SealShop"
	view.add_theme_constant_override("separation", 10)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var purse := PanelContainer.new()
	purse.add_theme_stylebox_override("panel", _box(WELL, Color("3a3122"), 5, 10))
	view.add_child(purse)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	purse.add_child(line)
	line.add_child(UITheme.icon_rect(SEAL, 40))
	var words := VBoxContainer.new()
	words.add_theme_constant_override("separation", 0)
	words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(words)
	_seals = HudKit.label("", 22, HudKit.GOLD_HI, HudKit.title(), 3)
	words.add_child(_seals)
	# Wrapped: on one line it set the whole window's width (678 of 600 in Turkish).
	var hint := HudKit.label(tr("Dungeon Seals  ·  Normal and harder clears pay seals; a gold medal adds one"), 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 200
	words.add_child(hint)
	_shop_grid = GridContainer.new()
	_shop_grid.columns = 2
	_shop_grid.add_theme_constant_override("h_separation", 6)
	_shop_grid.add_theme_constant_override("v_separation", 6)
	view.add_child(_shop_grid)
	var wares := DungeonData.shop()
	for i in wares.size():
		var entry: Dictionary = wares[i]
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", _box(Color(0.086, 0.141, 0.227, 0.45), Color("23324c"), 5, 8))
		_shop_grid.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card.add_child(row)
		var item_id := String(entry.get("item", ""))
		row.add_child(UITheme.icon_rect(item_id, 38))
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		col.add_theme_constant_override("separation", 2)
		row.add_child(col)
		var amount := int(entry.get("amount", 1))
		var name_text := I18n.t(String(ItemRules.item(item_id).get("name", item_id)))
		var label := HudKit.label(name_text if amount == 1 else "%s ×%d" % [name_text, amount], 14, HudKit.PARCHMENT, HudKit.body(), 0)
		# A longer name takes a second line before it is cut.
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.max_lines_visible = 2
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.custom_minimum_size.x = 60
		col.add_child(label)
		var price := HBoxContainer.new()
		price.add_theme_constant_override("separation", 4)
		col.add_child(price)
		price.add_child(UITheme.icon_rect(SEAL, 15))
		price.add_child(HudKit.label(tr("%d seals") % int(entry.get("seals", 1)), 13, HudKit.GOLD_LT, HudKit.body(), 0))
		var buy := HudKit.gold_button_small(tr("Buy"))
		buy.name = "Buy_%d" % i
		buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		buy.set_meta("seals", int(entry.get("seals", 1)))
		buy.pressed.connect(buy_row.bind(i))
		row.add_child(buy)
		buy_buttons.append(buy)
	return view

## Show the Dungeon ("run") or the Seal Shop ("shop") page.
func show_page(id: String) -> void:
	page = id
	if _run_view == null:
		return
	_run_view.visible = id == "run"
	_shop_view.visible = id == "shop"
	for p: String in page_tabs:
		(page_tabs[p] as Workshop.TabChip).selected = p == id
	_refresh_shop()

## Dungeon Seals in the bag.
func seal_count() -> int:
	return _key_count(SEAL)

## The purse, the tab's count and the Buy buttons (off when the seals do not
## reach the price, or while a purchase waits for its answer).
func _refresh_shop() -> void:
	if _seals == null:
		return
	var seals := seal_count()
	_seals.text = str(seals)
	_tab_seals.text = str(seals)
	for buy: Button in buy_buttons:
		buy.disabled = _buy_id >= 0 or seals < int(buy.get_meta("seals", 1))

## Buy shop row `index` (the server checks the seals, the bag and the gate).
func buy_row(index: int) -> void:
	if session == null or _buy_id >= 0 or index < 0 or index >= DungeonData.shop().size():
		return
	_buy_row = index
	_buy_id = int(session.seal_buy(index))
	if _buy_id <= 0:
		_buy_id = -1
	_refresh_shop()

## An item answer: ours when it carries the purchase's op id.
func _bought(answer: Dictionary) -> void:
	if _buy_id < 0 or int(answer.get("request_id", -2)) != _buy_id:
		return
	_buy_id = -1
	var wares := DungeonData.shop()
	var item_id := String((wares[_buy_row] as Dictionary).get("item", "")) if _buy_row < wares.size() else ""
	var ok := bool(answer.get("ok", false))
	var reason := String(answer.get("reason", ""))
	last_buy = {"row": _buy_row, "item": item_id, "ok": ok, "reason": reason}
	var fails := {"no_seals": tr("Not enough Dungeon Seals."), "bag_full": tr("Your bag is full."),
		"not_at_shop": tr("The seal shop is at the dungeon gates.")}
	var text := String(fails.get(reason, tr("The gate keeper shakes his head.")))
	if ok:
		text = tr("%s bought.") % I18n.t(String(ItemRules.item(item_id).get("name", item_id)))
	_notice(text, "good" if ok else "warn")
	if ok:
		AudioManager.play_sound_at("ui_coin", Vector3.ZERO, null, true)
	else:
		AudioManager.play_deny()
	_refresh_shop()

static func _box(bg: Color, border: Color, radius: int, margin: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	sb.anti_aliasing = true
	return sb

## A small heading with gold rules either side (the Hearth window's).
static func section(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in 2:
		var rule := ColorRect.new()
		rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.45)
		rule.custom_minimum_size = Vector2(0, 1)
		rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(rule)
		if i == 0:
			row.add_child(HudKit.label(I18n.upper(text), 13, HudKit.GOLD_LT, HudKit.title(), 3))
	return row

## Open at the gate `at_portal` (a maps.json portal into an instanced map).
func open_at(at_portal: String) -> void:
	portal_id = at_portal
	info = {}
	_facts_key = ""
	_members_key = ""
	var dungeon := _dungeon()
	set_title("Dungeon Gate")
	_banner.setup(I18n.t(String(dungeon.get("display", "Dungeon"))), _boss_art(dungeon))
	_ask()
	refresh()
	open()

## The dungeon behind this gate ({} when the portal leads nowhere known).
func _dungeon() -> Dictionary:
	var found := DungeonData.for_map(String(_portal().get("to_map", "")))
	return found[1] if not found.is_empty() else {}

func _portal() -> Dictionary:
	for portal: Dictionary in (RealmContent.table("maps") as Dictionary).get("portals", []):
		if String(portal.get("id", "")) == portal_id:
			return portal
	return {}

## The picture of the dungeon's boss (the first boss its steps spawn).
static func _boss_art(dungeon: Dictionary) -> Texture2D:
	for step: Dictionary in dungeon.get("steps", []):
		for spawn: Dictionary in step.get("spawn", []):
			if String(spawn.get("role", "")) == "boss":
				var path := "res://assets/ui/bestiary/%s.png" % String(spawn.get("mob", ""))
				if ResourceLoader.exists(path):
					return load(path)
	return null

func _ask() -> void:
	_refresh_t = REFRESH_S
	if session != null and portal_id != "":
		session.dungeon_info(portal_id)

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_t -= delta
	if rejoin_button.visible:
		var left := active_left_s()
		rejoin_button.text = tr("Return to the dungeon") + (" (%s)" % DungeonData.clock(left) if left > 0.0 else "")
	if _refresh_t <= 0.0:
		_ask()

## Choose a difficulty card.
func pick(id: String) -> void:
	difficulty = id
	refresh()

## The "dungeon" game events (MapDungeon hands each over).
func on_event(event: Dictionary) -> void:
	match String(event.get("event", "")):
		"info":
			if String(event.get("portal", "")) == portal_id:
				info = event
				answers += 1
				_active_at_ms = Time.get_ticks_msec()
				if visible:
					refresh()
		"ready":
			if visible:
				info["check"] = event.get("view", event)
				refresh()
		"cancelled":
			_notice(tr("Ready check cancelled: %s") % reason_text(String(event.get("reason", "")),
				String(event.get("who", "")), 0), "warn")
			if visible:
				info.erase("check")
				_ask()
		"refused":
			_notice(reason_text(String(event.get("reason", "")), String(event.get("who", "")),
				int(event.get("value", 0))), "warn")
			AudioManager.play_deny()
		"launch":
			close()

func _notice(text: String, kind: String) -> void:
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, kind)

## Words for a refusal or a cancelled ready check; `who` names the member it
## is about, `value` a number (a level, a party size, keys).
static func reason_text(reason: String, who: String, value: int) -> String:
	var whom := who if who != "" else I18n.t("A party member")
	match reason:
		"not_leader":
			return I18n.t("Only the party leader can start the dungeon.")
		"party_size":
			return I18n.t("This difficulty needs a party of at least %d.") % value
		"level_spread":
			return I18n.t("Party levels may differ by at most %d (now %d).") % [
				int(DungeonData.group().get("max_level_spread", 15)), value]
		"level_too_low":
			return I18n.t("%s needs level %d for this difficulty.") % [whom, value]
		"not_gathered":
			return I18n.t("%s is not at the gate.") % whom
		"dead":
			return I18n.t("%s is dead.") % whom
		"mounted":
			return I18n.t("%s is on a broom.") % whom
		"in_duel":
			return I18n.t("%s is in a duel.") % whom
		"in_combat":
			return I18n.t("%s is fighting.") % whom
		"transfer_pending":
			return I18n.t("%s is travelling.") % whom
		"in_run":
			return I18n.t("%s is still inside another dungeon.") % whom
		"difficulty_locked":
			return I18n.t("%s has not unlocked this difficulty yet.") % whom
		"no_key":
			return I18n.t("%s needs %d key(s) to open this difficulty.") % [whom, value]
		"ready_pending":
			return I18n.t("A ready check is already under way.")
		"declined":
			return I18n.t("%s is not ready.") % whom
		"ready_timeout":
			return I18n.t("No answer from %s.") % whom
		"party_changed":
			return I18n.t("The party changed.")
		"map_full":
			return I18n.t("Every copy of this dungeon is taken - try again shortly.")
		"range":
			return I18n.t("Stand at the gate.")
		"no_portal":
			return I18n.t("Start the dungeon at its gate.")
		"not_finished":
			return I18n.t("Finish this run before starting another.")
		"map_unavailable":
			return I18n.t("The dungeon could not be prepared - try again in a moment.")
	return I18n.t("The gate stays shut.")

## The player's own run still open behind this gate ({} when none).
func active() -> Dictionary:
	var run: Variant = info.get("active")
	return run if run is Dictionary else {}

## Seconds the open run stays open, ticking down from the gate's answer (-1:
## no limit now).
func active_left_s() -> float:
	var left := float(active().get("left_s", -1))
	if left < 0.0:
		return -1.0
	return maxf(0.0, left - float(Time.get_ticks_msec() - _active_at_ms) / 1000.0)

## The ready check under way ({} when none).
func _check() -> Dictionary:
	var check: Variant = info.get("check")
	return check if check is Dictionary else {}

## The local player's row in the gate's answer ({} before the first).
func me(members: Array) -> Dictionary:
	var own: Dictionary = session.party() if session != null else {}
	var sheet: Dictionary = session.sheet() if session != null else {}
	for m: Dictionary in members:
		if int(m.get("character", 0)) == int(own.get("me", -1)) or String(m.get("name", "")) == String(sheet.get("name", "?")):
			return m
	return {}

func _own_name() -> String:
	return String((session.sheet() as Dictionary).get("name", "")) if session != null else ""

func _key_count(item_id: String) -> int:
	var n := 0
	if session == null or item_id == "":
		return 0
	var sheet: Dictionary = session.sheet()
	for cell: Variant in sheet.get("bag", []):
		if cell is Dictionary and String(cell.get("id", "")) == item_id:
			n += int(cell.get("amount", 1))
	return n

## Rebuild the view for the chosen difficulty from the dungeon data and the
## server's last word on the party.
func refresh() -> void:
	if _chips == null:
		return
	var dungeon := _dungeon()
	var d_index := DungeonData.difficulty_index(difficulty)
	var rules := DungeonData.difficulty(difficulty)
	var group := DungeonData.group()
	var accent := DungeonData.colour(difficulty)
	var members: Array = info.get("members", [])
	var levels: Array = members.map(func(m): return int(m.get("level", 1)))
	if levels.is_empty() and session != null:
		levels.append(int((session.sheet() as Dictionary).get("level", 1)))
	var ref := DungeonData.ref_level(dungeon, levels)
	var low := DungeonData.mob_level(ref, difficulty, "trash", 0)
	var high := DungeonData.mob_level(ref, difficulty, "boss", 1)
	var trash := DungeonData.hp_scale(difficulty, "trash", maxi(1, members.size()))
	var need := int(dungeon.get("level_min", 1)) + int(rules.get("min_level_add", 0))
	var par := DungeonData.par(dungeon, difficulty)
	var medals := DungeonData.medals()
	_banner.band = tr("Levels %d-%d · 1-%d players") % [int(dungeon.get("level_min", 1)),
		int(dungeon.get("level_max", 1)), int(group.get("max_party", 5))]
	_banner.medals = [[DungeonData.MEDAL_COLOURS.gold, DungeonData.clock(par * float(medals.get("gold", 1.0)))],
		[DungeonData.MEDAL_COLOURS.silver, DungeonData.clock(par * float(medals.get("silver", 1.3)))],
		[DungeonData.MEDAL_COLOURS.bronze, DungeonData.clock(par * float(medals.get("bronze", 1.6)))]]
	_banner.queue_redraw()
	var mine := me(members)
	for id: String in cards:
		var card := cards[id] as DifficultyCard
		card.selected = id == difficulty
		card.locked = not mine.is_empty() and not bool((mine.get("unlocked", []) as Array)[DungeonData.difficulty_index(id)])

	var facts: Array = []
	facts.append([tr("Creatures"), tr("Lv %d–%d") % [low, high], HudKit.PARCHMENT])
	facts.append([tr("Health · damage"), "×%.2f · ×%.2f" % [trash, float(rules.get("damage", 1.0))], HudKit.PARCHMENT])
	facts.append([tr("Needs"), tr("%d+ players · Lv %d+") % [int(rules.get("min_party", 1)), need],
		BAD if members.size() > 0 and members.size() < int(rules.get("min_party", 1)) else HudKit.PARCHMENT])
	facts.append([tr("Gold medal"), tr("full clear within %s") % DungeonData.clock(par * float(medals.get("gold", 1.0))), HudKit.PARCHMENT])
	var rights: Array = mine.get("rights", [])
	var left := int(rights[d_index]) if d_index < rights.size() else -1
	facts.append([tr("Final chest"), tr("unlimited") if left < 0 else (tr("%d left today") % left if left > 0 else tr("none left - helper")),
		BAD if left == 0 else HudKit.PARCHMENT])
	var keys := int(rules.get("keys", 0))
	if keys > 0:
		var have := _key_count(String(dungeon.get("key", "")))
		facts.append([tr("Key"), tr("%d needed · you have %d") % [keys, have], GOOD if have >= keys else BAD])
	else:
		var best: Array = mine.get("best_ms", [])
		var best_ms := int(best[d_index]) if d_index < best.size() else 0
		facts.append([tr("Your best"), DungeonData.clock(best_ms / 1000.0) if best_ms > 0 else "—", HudKit.PARCHMENT])
	# This week's curses on the chosen difficulty (the run keeps the ones it
	# starts with).
	var curses := week_curses(difficulty)
	# Rebuilt only when a fact changed: the gate asks again every REFRESH_S,
	# and new chips lay their wrapped values out afresh (the rows below them
	# twitched with every answer).
	var facts_key := str(facts) + str(curses) + str(info.is_empty())
	if facts_key != _facts_key:
		_facts_key = facts_key
		for child in _chips.get_children():
			_chips.remove_child(child)
			child.queue_free()
		for fact: Array in facts:
			_chip(String(fact[0]), String(fact[1]), fact[2])
		for child in _curses.get_children():
			_curses.remove_child(child)
			child.queue_free()
		curses_shown = curses
		# (nothing before the gate's first answer: the week comes with it)
		if curses.is_empty() and not info.is_empty():
			_curses.add_child(HudKit.label(tr("No curses on this difficulty."), 12, FAINT, HudKit.body(), 0))
		elif not curses.is_empty():
			_curses.add_child(HudKit.label(tr("This week's curses:"), 12, HudKit.TEXT_DIM, HudKit.body(), 0))
			for id: String in curses:
				var curse := DungeonData.affix(id)
				_curses.add_child(_curse(I18n.t(String(curse.get("display", id))), I18n.t(String(curse.get("desc", "")))))
	_set_accent(accent)
	_fill_members(members, need, int(group.get("max_party", 5)))
	_judge(members, levels, rules, need)

## The detail panel's left edge in the chosen difficulty's colour.
func _set_accent(accent: Color) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = WELL
	box.border_color = accent
	box.border_width_left = 3
	box.set_corner_radius_all(5)
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	_detail.add_theme_stylebox_override("panel", box)

## The curses a run on `difficulty_id` takes this week: the first N of the
## gate's `affixes` (N: dungeons.json difficulty.<id>.affixes).
func week_curses(difficulty_id: String) -> Array:
	var week: Array = info.get("affixes", [])
	var n := mini(int(DungeonData.difficulty(difficulty_id).get("affixes", 0)), week.size())
	return week.slice(0, n).map(func(id): return String(id))

## A curse as a red tag; its description on hover.
func _curse(title: String, desc: String) -> PanelContainer:
	var tag := PanelContainer.new()
	tag.mouse_filter = Control.MOUSE_FILTER_STOP
	tag.tooltip_text = desc
	var sb := _box(Color(0.43, 0.1, 0.055, 0.25), Color("5a2a2a"), 11, 0)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	tag.add_theme_stylebox_override("panel", sb)
	tag.add_child(HudKit.label("☠ " + title, 12, Color("ffb4a8"), HudKit.body(), 0))
	return tag

## One fact as a small card: caption over value.
func _chip(caption: String, value: String, colour: Color = HudKit.PARCHMENT) -> void:
	var chip := PanelContainer.new()
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip.add_theme_stylebox_override("panel", _box(Color(0.114, 0.184, 0.29, 0.35), Color("1f2b40"), 4, 6))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	chip.add_child(col)
	col.add_child(HudKit.label(caption, 11, HudKit.TEXT_DIM, HudKit.body(), 0))
	var v := HudKit.label(value, 14, colour, HudKit.body(), 0)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.custom_minimum_size.x = 140
	col.add_child(v)
	_chips.add_child(chip)

## One row per member (crown for the leader, level, a status tag), then
## dashed empty places up to the party cap.
func _fill_members(members: Array, need: int, cap: int) -> void:
	var leader := String(info.get("leader", ""))
	var check := _check()
	var ready := {}
	for m: Array in check.get("members", []):
		if bool(m[2]):
			ready[String(m[0])] = true
	var d_index := DungeonData.difficulty_index(difficulty)
	var rows: Array = []
	for m: Dictionary in members:
		var who := String(m.get("name", "?"))
		var level := int(m.get("level", 1))
		var status := String(m.get("status", ""))
		var text := tr("at the gate")
		var colour := GOOD
		var unlocked: Array = m.get("unlocked", [])
		var rights: Array = m.get("rights", [])
		if not check.is_empty():
			text = tr("ready") if ready.has(who) else tr("answering...")
			colour = GOOD if ready.has(who) else HudKit.GOLD_LT
		elif status != "":
			text = _status_word(status)
			colour = BAD
		elif level < need:
			text = tr("level too low")
			colour = BAD
		elif d_index < unlocked.size() and not bool(unlocked[d_index]):
			text = tr("locked")
			colour = BAD
		elif d_index < rights.size() and int(rights[d_index]) == 0:
			text = tr("helper (no chest)")
			colour = HudKit.GOLD_LT
		rows.append([("♛ " if who == leader else "") + who, level, text, colour])
	# Rebuilt only when a row changed (the answer comes every REFRESH_S).
	var key := str(rows) + str(cap)
	if key == _members_key:
		return
	_members_key = key
	for child in _members.get_children():
		_members.remove_child(child)
		child.queue_free()
	for r: Array in rows:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(0, 34)
		card.add_theme_stylebox_override("panel", _box(Color(0.086, 0.141, 0.227, 0.45), Color("23324c"), 4, 0))
		_members.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 12)
		margin.add_theme_constant_override("margin_right", 10)
		card.add_child(margin)
		margin.add_child(row)
		var name_label := HudKit.label(String(r[0]), 15, HudKit.GOLD_HI, HudKit.body(), 2)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_label)
		var lv := HudKit.label(tr("Lv %d") % int(r[1]), 14, HudKit.TEXT if int(r[1]) >= need else BAD, HudKit.body(), 0)
		lv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lv)
		row.add_child(_pill(String(r[2]), r[3]))
	for i in range(rows.size(), cap):
		var empty := PanelContainer.new()
		empty.custom_minimum_size = Vector2(0, 30)
		empty.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0), Color("1c2638"), 4, 0))
		var label := HudKit.label(tr("empty place"), 12, FAINT, HudKit.body(), 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.add_child(label)
		_members.add_child(empty)

## A status tag: its colour on a faint fill of the same.
func _pill(text: String, colour: Color) -> PanelContainer:
	var pill := PanelContainer.new()
	pill.custom_minimum_size = Vector2(110, 0)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := _box(Color(colour, 0.14), Color(colour, 0.45), 11, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 1
	sb.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", sb)
	var label := HudKit.label(text, 12, colour, HudKit.body(), 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pill.add_child(label)
	return pill

func _status_word(status: String) -> String:
	match status:
		"not_gathered":
			return tr("away")
		"dead":
			return tr("dead")
		"mounted":
			return tr("on a broom")
		"in_duel":
			return tr("duelling")
		"in_combat":
			return tr("fighting")
		"transfer_pending":
			return tr("travelling")
		"in_run":
			return tr("in another run")
		"difficulty_locked":
			return tr("locked")
	return tr("busy")

## The first thing the server would refuse, worded; the buttons follow it.
func _judge(members: Array, levels: Array, rules: Dictionary, need: int) -> void:
	var problem := ""
	var leader := String(info.get("leader", ""))
	var i_lead := leader == "" or leader == _own_name()
	var check := _check()
	var d_index := DungeonData.difficulty_index(difficulty)
	if info.is_empty():
		problem = tr("Asking the gate...")
	elif not check.is_empty():
		var all: Array = check.get("members", [])
		problem = tr("Ready check under way: %d / %d ready") % [all.filter(func(m): return bool(m[2])).size(), all.size()]
	elif not i_lead:
		problem = tr("The party leader starts the dungeon.")
	elif members.size() < int(rules.get("min_party", 1)):
		problem = reason_text("party_size", "", int(rules.get("min_party", 1)))
	elif _spread(levels) > int(DungeonData.group().get("max_level_spread", 15)):
		problem = reason_text("level_spread", "", _spread(levels))
	else:
		for m: Dictionary in members:
			var unlocked: Array = m.get("unlocked", [])
			if String(m.get("status", "")) != "":
				problem = reason_text(String(m["status"]), String(m.get("name", "")), 0)
				break
			if int(m.get("level", 1)) < need:
				problem = reason_text("level_too_low", String(m.get("name", "")), need)
				break
			if d_index < unlocked.size() and not bool(unlocked[d_index]):
				problem = reason_text("difficulty_locked", String(m.get("name", "")), 0)
				break
		var keys := int(rules.get("keys", 0))
		if problem == "" and keys > 0 and _key_count(String(_dungeon().get("key", ""))) < keys:
			problem = reason_text("no_key", tr("You"), keys)
	var blocked := problem != ""
	verdict.text = problem if blocked else (tr("Everyone is ready at the gate.") if members.size() > 1 else tr("The gate is open to you."))
	verdict.add_theme_color_override("font_color", HudKit.GOLD_LT if not check.is_empty() else (BAD if blocked else GOOD))
	start_button.text = I18n.upper(tr("Ready check") if members.size() > 1 else tr("Enter"))
	start_button.disabled = blocked
	rejoin_button.visible = not active().is_empty() and active_left_s() != 0.0

static func _spread(levels: Array) -> int:
	if levels.is_empty():
		return 0
	return int(levels.max()) - int(levels.min())

func _on_start() -> void:
	if session == null or start_button.disabled:
		return
	starts_sent += 1
	session.dungeon_start(portal_id, DungeonData.difficulty_index(difficulty))
	AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

## Back into the player's open run: through the same door (the server lets a
## roster member in).
func _on_rejoin() -> void:
	close()
	if session != null:
		session.door(portal_id)


## The dungeon's banner: a dark red glow behind its boss on the right, the
## name, the level band and the three medal times on the left.
class DungeonBanner extends Control:
	var title := ""
	var band := ""
	var medals: Array = []   # [[colour, "15:00"], ...] gold, silver, bronze
	var art: Texture2D

	func _init() -> void:
		custom_minimum_size = Vector2(0, 100)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func setup(p_title: String, p_art: Texture2D) -> void:
		title = p_title
		art = p_art
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color("0a0f1a"))
		# The glow: rings of warm red, fading out from behind the boss.
		var glow_c := Vector2(size.x * 0.8, size.y * 0.5)
		for i in 12:
			var t := 1.0 - float(i) / 12.0
			draw_circle(glow_c, size.y * (0.4 + 1.6 * t), Color(0.55, 0.16, 0.12, 0.035))
		if art != null:
			var h := size.y * 1.45
			var w := h * art.get_width() / art.get_height()
			draw_texture_rect(art, Rect2(size.x - w + 10.0, size.y - h + 20.0, w, h), false, Color(1, 1, 1, 0.9))
		# Fade the art into the dark on its left.
		var fade := 180.0
		for i in 18:
			var t := float(i) / 18.0
			draw_rect(Rect2(size.x * 0.52 + fade * t, 0, fade / 18.0 + 1.0, size.y), Color(0.04, 0.06, 0.1, 0.9 * (1.0 - t)))
		draw_rect(Rect2(0, 0, size.x * 0.52, size.y), Color(0.04, 0.06, 0.1, 0.9))
		var deco := HudKit.deco()
		draw_string_outline(deco, Vector2(18, 38), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 4, Color(0, 0, 0, 0.8))
		draw_string(deco, Vector2(18, 38), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, HudKit.GOLD_HI)
		draw_string(HudKit.body(), Vector2(18, 60), band, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HudKit.PARCHMENT)
		var x := 18.0
		for medal: Array in medals:
			draw_circle(Vector2(x + 6.0, 80.0), 6.0, medal[0])
			draw_arc(Vector2(x + 6.0, 80.0), 6.0, 0.0, TAU, 16, Color(0, 0, 0, 0.6), 1.0, true)
			draw_string(HudKit.body(), Vector2(x + 16.0, 85.0), String(medal[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.TEXT_DIM)
			x += 74.0
		draw_rect(r, Color("3a3122"), false, 1.0)


## A difficulty to pick: 1-5 diamonds and the name in its colour; the chosen
## one fills with a dark shade of it and glows; a locked one dims with a lock.
class DifficultyCard extends Control:
	signal chosen
	var caption := ""
	var colour := Color.WHITE
	var diamonds := 1
	var selected := false:
		set(value):
			selected = value
			queue_redraw()
	var locked := false:
		set(value):
			locked = value
			modulate.a = 0.45 if value else 1.0
			queue_redraw()
	var _hover := false

	func _init(p_caption: String, p_colour: Color, p_diamonds: int) -> void:
		caption = p_caption
		colour = p_colour
		diamonds = p_diamonds
		custom_minimum_size = Vector2(0, 58)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; queue_redraw())

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit()
			accept_event()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var box := StyleBoxFlat.new()
		box.set_corner_radius_all(5)
		box.set_border_width_all(1)
		if selected:
			box.bg_color = colour.darkened(0.72)
			box.border_color = colour
			box.shadow_color = Color(colour, 0.3)
			box.shadow_size = 8
		else:
			box.bg_color = Color(0.067, 0.11, 0.18, 0.8)
			box.border_color = colour if _hover else Color("23324c")
		draw_style_box(box, r)
		var y := size.y * 0.36
		var step := 12.0
		var x0 := size.x * 0.5 - step * 2.0
		for i in 5:
			var c := Vector2(x0 + step * i, y)
			var pts := PackedVector2Array([c + Vector2(0, -4.5), c + Vector2(4.5, 0), c + Vector2(0, 4.5), c + Vector2(-4.5, 0)])
			if i < diamonds:
				draw_colored_polygon(pts, colour)
			else:
				pts.append(pts[0])
				draw_polyline(pts, Color(colour, 0.35), 1.0, true)
		var font := HudKit.body()
		var w := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y * 0.78), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE if selected else colour)
		if locked:
			var lock := UITheme.icon_for("ui_lock")
			if lock != null:
				draw_texture_rect(lock, Rect2(size.x - 17.0, 5.0, 12.0, 12.0), false)
