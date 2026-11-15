extends Control
class_name HudActionBar

## The action bar: eight spell slots (1-4, Q, E, 5, 6) and, after a gap, four
## quick slots on F1-F4 that hold consumables - the health and mana potions by
## default, any potion dragged onto them from the bag. A filled quick slot can be
## dragged onto another (move or swap) or out onto the world to empty it;
## right-click clears it too. Spell slots swap the same way, and the keys follow
## the slots (`spell_at`). Both layouts are remembered per install
## (`user://quickslots.cfg`).
##
## A spell slot asks for its spell through `spell_requested` (the world aims
## it). Clicking a spell slot that is not learned yet while a skill point is
## free learns that spell: the bar is where the player meets a new spell, so it
## is where the point is spent. A quick slot uses the potion exactly like the
## bag does (PlayerSheet "consume" on the bag cell holding it); the server
## decides whether it is allowed and what it restores.

## A spell slot was pressed (key or click) and its spell is learned.
signal spell_requested(spell_id: String)
## The server answered a skill point (RealmSession.take_skill_results: spell,
## ok, reason); the skill window and the checks hear it here.
signal skill_answered(answer: Dictionary)

const SLOT := 50.0
const GAP := 4.0
const GROUP_GAP := 18.0
## The deck plate reaches this far past the slots (left/right, and up/down).
const PLATE_PAD := 12.0
const PLATE_TOP := 8.0
const SPELLS := [
	["stun_bolt", "1"], ["flame_wave", "2"], ["shockwave", "3"],
	["disarm", "4"], ["ward_shield", "Q"], ["ultimate", "E"], ["light_of_ithrel", "5"],
	["frost_grip", "6"],
]
## The slots' keys are GameSettings' spell_1..spell_8 and quick_1..quick_4
## (rebindable; SPELLS' letters are the defaults).
const QUICK_DEFAULTS := ["potion_health", "potion_mana", "", ""]
const QUICK_COOLDOWN := 1.0
const SAVE_PATH := "user://quickslots.cfg"

var hud: Control = null
var session: Node = null
var sheet: PlayerSheet = null
var spell_slots: Array[HudSlot] = []
var quick_slots: Array[HudSlot] = []
var quick_items: Array = ["", "", "", ""]
var _quick_cd: Array = [0.0, 0.0, 0.0, 0.0]
var _pending_request := 0
## Width the plate runs on past the quick slots (the HUD's bag button sits
## there, on the same taskbar), and the x of each extra divider.
var tray_extra := 0.0
var tray_dividers: Array = []
## Which spell each slot holds (the keys read it through spell_at).
var spell_order: Array = []
## Each spell's level as last read (a rise says so on the notice band).
var _known_levels: Dictionary = {}
static var _spells: Dictionary = {}

static func spells() -> Dictionary:
	if _spells.is_empty():
		var loaded: Variant = RealmContent.table("spells")
		if loaded is Dictionary:
			_spells = loaded
	return _spells

## The spell on bar slot `index`.
func spell_at(index: int) -> String:
	return String(spell_order[index]) if index >= 0 and index < spell_order.size() else ""

func _init() -> void:
	name = "ActionBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_load()
	for i in SPELLS.size():
		var s := HudSlot.new(SLOT)
		s.name = "SpellSlot%d" % (i + 1)
		s.key_text = GameSettings.key_name("spell_%d" % (i + 1))
		s.accept_drop = _accept_spell_drop
		s.drag_slot_index = i
		s.drag_key = "spell_slot"
		s.keep_on_release = true
		s.item_dropped.connect(_on_spell_drop.bind(i))
		var index := i
		s.pressed.connect(func(): _press_spell(index, true))
		add_child(s)
		spell_slots.append(s)
	_show_spells()
	for i in range(4):
		var q := HudSlot.new(SLOT)
		q.name = "Quick%d" % (i + 1)
		q.key_text = GameSettings.key_name("quick_%d" % (i + 1))
		q.empty_hint = tr("drop")
		q.accept_drop = _accept_quick_drop
		q.item_dropped.connect(_on_quick_drop.bind(i))
		q.cleared.connect(func(_s): _assign(i, ""))
		q.drag_slot_index = i
		q.drag_released.connect(func(_s): _assign(i, ""))
		var index := i
		q.pressed.connect(func(): use_quick(index))
		add_child(q)
		quick_slots.append(q)
	_layout()
	GameSettings.instance().changed.connect(_on_settings_changed)

## A key was rebound: the slots show their new keys (and their tooltips are
## built again with them).
func _on_settings_changed(what: String) -> void:
	if what != "bindings" and what != "all":
		return
	for i in spell_slots.size():
		spell_slots[i].key_text = GameSettings.key_name("spell_%d" % (i + 1))
		spell_slots[i].tooltip_text = ""
	for i in quick_slots.size():
		quick_slots[i].key_text = GameSettings.key_name("quick_%d" % (i + 1))
		quick_slots[i].held_id = "-"

func bind(p_hud: Control, p_session: Node, p_sheet: PlayerSheet) -> void:
	hud = p_hud
	session = p_session
	sheet = p_sheet
	sheet.equipment_answer.connect(_on_answer)

func bar_width() -> float:
	return SLOT * float(SPELLS.size() + 4) + GAP * float(SPELLS.size() + 2) + GROUP_GAP

func _layout() -> void:
	custom_minimum_size = Vector2(bar_width(), SLOT)
	size = custom_minimum_size
	var x := 0.0
	for s in spell_slots:
		s.position = Vector2(x, 0)
		s.size = Vector2(SLOT, SLOT)
		x += SLOT + GAP
	x += GROUP_GAP - GAP
	for q in quick_slots:
		q.position = Vector2(x, 0)
		q.size = Vector2(SLOT, SLOT)
		x += SLOT + GAP

func _draw() -> void:
	# The deck plate: a dark bar with a lit gold top edge behind both groups.
	var plate := Rect2(Vector2(-PLATE_PAD, -PLATE_TOP), Vector2(size.x + tray_extra + PLATE_PAD * 2.0, size.y + PLATE_TOP * 2.0))
	draw_rect(plate, Color(0.02, 0.027, 0.043, 0.78))
	draw_rect(Rect2(plate.position, Vector2(plate.size.x, 1.5)), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.85))
	draw_rect(Rect2(Vector2(plate.position.x, plate.end.y - 1), Vector2(plate.size.x, 1)), Color(0, 0, 0, 0.8))
	# Divider between spells and quick slots.
	var dx := SLOT * SPELLS.size() + GAP * (SPELLS.size() - 1) + GROUP_GAP * 0.5
	draw_line(Vector2(dx, 2), Vector2(dx, size.y - 2), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.5), 1.0)
	for x in tray_dividers:
		draw_line(Vector2(x, 2), Vector2(x, size.y - 2), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.5), 1.0)
	# Corner studs.
	for p in [plate.position, Vector2(plate.end.x, plate.position.y)]:
		draw_circle(p + Vector2(0, 0.75), 3.0, HudKit.GOLD_LT)

## The cooldown sweep moves every frame; the tooltip, the skill badge and the
## bag counts change rarely and refresh four times a second.
const SLOW_REFRESH := 0.25
var _slow_wait := 0.0

func _process(delta: float) -> void:
	for i in range(4):
		_quick_cd[i] = maxf(0.0, float(_quick_cd[i]) - delta)
	if session == null or sheet == null:
		return
	var vitals: PackedInt32Array = session.vitals()
	var dead := vitals[0] <= 0
	var mana := vitals[2]
	_slow_wait -= delta
	var slow := _slow_wait <= 0.0
	if slow:
		_slow_wait = SLOW_REFRESH
	var points: int = session.skill_points() if slow else 0
	for s in spell_slots:
		var spell_id := s.held_id
		var spell: Dictionary = spells().get(spell_id, {})
		if slow or not s.has_meta("trained"):
			s.set_meta("trained", int(session.skill_level(spell_id)))
			s.set_meta("total", maxf(0.01, float(session.cooldown_total(spell_id))))
			_note_level(spell_id, int(s.get_meta("trained")))
		var trained: int = int(s.get_meta("trained"))
		var cd: float = session.cooldown_remaining(spell_id)
		s.set_cooldown(cd, cd / float(s.get_meta("total")))
		s.unusable = dead or trained <= 0 or mana < int(spell.get("mana_cost", 0)) \
			or sheet.level < int(spell.get("requires_level", 1))
		if slow:
			s.badge_text = Levels.skill_level_label(trained) if trained > 0 and Levels.skill_upgradeable(spell_id) else ""
			var tip := _spell_tooltip(s.key_text, spell, trained, float(s.get_meta("total")), points)
			if s.tooltip_text != tip:
				s.tooltip_text = tip
	for i in range(4):
		var q := quick_slots[i]
		var id := String(quick_items[i])
		if q.held_id != id:
			q.held_id = id
			q.icon_texture = UITheme.icon_for(id) if id != "" else null
			q.tooltip_text = _item_tooltip(q.key_text, id)
			q.count = -2   # a new item is counted now, not at the next refresh
		if slow or q.count == -2:
			q.count = _count_of(id) if id != "" else -1
		q.unusable = dead or (id != "" and q.count <= 0)
		q.set_cooldown(float(_quick_cd[i]), float(_quick_cd[i]) / QUICK_COOLDOWN)
	for answer: Dictionary in session.take_skill_results():
		_on_skill_answer(answer)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var key: int = (event as InputEventKey).physical_keycode
	var action := GameSettings.action_for(key)
	if action.begins_with("spell_"):
		_press_spell(int(action.trim_prefix("spell_")) - 1, false)
		get_viewport().set_input_as_handled()
	elif action.begins_with("quick_"):
		use_quick(int(action.trim_prefix("quick_")) - 1)
		get_viewport().set_input_as_handled()

## ------------------------------------------------------------- spell slots

## A key or a click on spell slot `index`. A click on a spell that is not
## learned spends a free skill point on it; otherwise a learned spell is asked
## for and an unlearned one says how to get it.
func _press_spell(index: int, clicked: bool) -> void:
	var spell_id := spell_at(index)
	var spell: Dictionary = spells().get(spell_id, {})
	if spell.is_empty() or session == null:
		return
	var shown := I18n.t(String(spell.get("name", spell_id)))
	if int(session.skill_level(spell_id)) > 0:
		spell_requested.emit(spell_id)
	elif sheet.level < int(spell.get("requires_level", 1)):
		_notice(tr("Requires level %d") % int(spell.get("requires_level", 1)), "warn")
	elif int(session.skill_points()) <= 0:
		_notice(tr("Learn %s first - gain a level to earn a skill point") % shown, "warn")
	elif clicked:
		session.learn_skill(spell_id)
	else:
		_notice(tr("Learn %s first - click its slot to spend a skill point") % shown, "info")

## A skill level read off the session: a rise over the last one read (the
## bar's click, the skill window's "+") is said on the notice band, as the old
## game's floating "Stun Bolt Lv.3" / "mastered!" said it.
func _note_level(spell_id: String, level: int) -> void:
	var was := int(_known_levels.get(spell_id, -1))
	_known_levels[spell_id] = level
	if was < 0 or level <= was or not Levels.skill_upgradeable(spell_id):
		return
	var shown := I18n.t(String(spells().get(spell_id, {}).get("name", spell_id)))
	if was == 0:
		_notice(tr("You learned %s!") % shown, "good")
	elif Levels.skill_is_master(level):
		_notice(tr("%s mastered!") % shown, "good")
	else:
		_notice(tr("%s Lv.%d") % [shown, level], "good")

func _on_skill_answer(answer: Dictionary) -> void:
	skill_answered.emit(answer)
	if bool(answer.get("ok", false)):
		# the new level is read on the next refresh (the sheet that follows)
		for s in spell_slots:
			s.remove_meta("trained")
		_slow_wait = 0.0
		return
	# i18n-begin
	var words := {"no_points": "No skill points left - gain a level", "max_level": "Already mastered",
		"dead": "You are defeated", "not_a_skill": "Cannot train that now",
		"level": "Your level is too low for that spell"}
	# i18n-end
	_notice(I18n.t(String(words.get(String(answer.get("reason", "")), "Cannot train that now"))), "warn")

func _show_spells() -> void:
	for i in spell_slots.size():
		var s := spell_slots[i]
		var id := spell_at(i)
		if s.held_id != id:
			s.held_id = id
			s.icon_texture = UITheme.spell_icon(id)
			s.tooltip_text = ""
			s.remove_meta("trained")

## A spell from another slot (swap).
func _accept_spell_drop(_slot: HudSlot, payload: Dictionary) -> bool:
	return payload.has("spell_slot") and spells().has(String(payload.get("id", "")))

func _on_spell_drop(_slot: HudSlot, payload: Dictionary, index: int) -> void:
	place_spell(String(payload.get("id", "")), index)

## Put `spell_id` on slot `index`; the spell that was there moves to the slot
## the dropped one came from, so every spell stays on the bar exactly once.
func place_spell(spell_id: String, index: int) -> void:
	var from := spell_order.find(spell_id)
	if from == index or index < 0 or index >= spell_order.size():
		return
	if from >= 0:
		spell_order[from] = spell_order[index]
	spell_order[index] = spell_id
	_show_spells()
	_save()

## ------------------------------------------------------------- quick slots

func use_quick(index: int) -> void:
	if session == null or session.vitals()[0] <= 0:
		return
	var id := String(quick_items[index])
	if id == "":
		_notice(tr("Drag a potion from your bag onto %s") % quick_slots[index].key_text, "info")
		return
	if float(_quick_cd[index]) > 0.0:
		return
	var entry := _entry_of(id)
	if entry.is_empty():
		_notice(tr("No %s left") % _item_name(id), "warn")
		return
	var data := ItemRules.item(id)
	if String(data.get("type", "")) != "consumable":
		return
	var vitals: PackedInt32Array = session.vitals()
	if data.has("heal_hp") and vitals[0] >= vitals[1]:
		_notice(tr("Health is already full"), "info")
		return
	if data.has("heal_mana") and vitals[2] >= vitals[3]:
		_notice(tr("Mana is already full"), "info")
		return
	_quick_cd[index] = QUICK_COOLDOWN
	_pending_request = sheet.submit("consume", "", entry)

func _on_answer(answer: Dictionary) -> void:
	if _pending_request == 0 or int(answer.get("request_id", 0)) != _pending_request:
		return
	_pending_request = 0
	if bool(answer.get("ok", false)):
		AudioManager.play_potion()
		return
	# i18n-begin
	var words := {"resource_full": "Already full", "item_missing": "None left", "casting": "Finish casting first",
		"dead": "You are defeated", "stale_inventory": "", "stale_request": "", "transfer_pending": "Wait until the map loads"}
	# i18n-end
	var reason := String(answer.get("reason", ""))
	var text := I18n.t(String(words[reason])) if words.has(reason) else tr("Cannot use that now")
	if text != "":
		_notice(text, "warn")

func _accept_quick_drop(_slot: HudSlot, payload: Dictionary) -> bool:
	var id := String(payload.get("id", ""))
	return id != "" and String(ItemRules.item(id).get("type", "")) == "consumable"

func _on_quick_drop(_slot: HudSlot, payload: Dictionary, index: int) -> void:
	var from := int(payload.get("quick_slot", -1))
	if from >= 0 and from < 4:
		move_quick(from, index)
		return
	_assign(index, String(payload.get("id", "")))

## Drag between quick slots: the item moves, and whatever the target held goes
## back to the source slot (a swap), so nothing is ever lost from the bar.
func move_quick(from: int, to: int) -> void:
	if from == to:
		return
	var moving := String(quick_items[from])
	quick_items[from] = quick_items[to]
	quick_items[to] = moving
	var cd = _quick_cd[from]
	_quick_cd[from] = _quick_cd[to]
	_quick_cd[to] = cd
	_save()

func _assign(index: int, id: String) -> void:
	# One item per bar: dropping it on a new slot moves it.
	if id != "":
		for i in range(4):
			if i != index and String(quick_items[i]) == id:
				quick_items[i] = ""
	quick_items[index] = id
	_save()

func _count_of(id: String) -> int:
	var total := 0
	for e: Dictionary in sheet.inventory:
		if String(e.get("id", "")) == id:
			total += int(e.get("amount", 1))
	return total

## The bag entry (with its `cell`) a quick slot uses.
func _entry_of(id: String) -> Dictionary:
	for e: Dictionary in sheet.inventory:
		if String(e.get("id", "")) == id and int(e.get("amount", 1)) > 0:
			return e
	return {}

func _item_name(id: String) -> String:
	return I18n.t(String(ItemRules.item(id).get("name", id)))

func _notice(text: String, kind: String) -> void:
	if hud != null:
		hud.show_notice(text, kind)

func _spell_tooltip(key: String, spell: Dictionary, trained: int, cooldown: float, points: int) -> String:
	if spell.is_empty():
		return ""
	var grade := tr("Not learned") if trained <= 0 else (tr("Master") if Levels.skill_is_master(trained) else tr("Level %d") % trained)
	var tip := tr("[%s] %s  ·  %s\n%d mana · %.1fs cooldown\n%s\nDrag onto another slot to swap") % [key,
		I18n.t(String(spell.get("name", ""))), grade, int(spell.get("mana_cost", 0)), cooldown, I18n.t(String(spell.get("desc", "")))]
	if trained <= 0 and points > 0:
		tip += "\n" + tr("Click to learn - spends a skill point (%d left)") % points
	return tip

func _item_tooltip(key: String, id: String) -> String:
	if id == "":
		return tr("[%s] Quick slot\nDrag a potion here from your bag (I).\nDrag a slot onto another to swap, or off the bar to clear it.") % key
	var data := ItemRules.item(id)
	return tr("[%s] %s\n%s\nDrag to move or swap; drag off the bar or right-click to clear.") % [key, I18n.t(String(data.get("name", id))), I18n.t(String(data.get("desc", "")))]

## The saved layouts: quick slot items, and the spell order when it is a
## permutation of today's spells (spells added since are appended in default
## order; a removed or unknown spell falls back to the default layout).
func _load() -> void:
	var defaults: Array = SPELLS.map(func(spec): return String(spec[0]))
	spell_order = defaults.duplicate()
	quick_items = QUICK_DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for i in range(4):
		quick_items[i] = String(cfg.get_value("quick", "slot%d" % (i + 1), QUICK_DEFAULTS[i]))
	var saved = cfg.get_value("spells", "order", [])
	if not saved is Array:
		return
	var order: Array = []
	for id in saved:
		if not defaults.has(id) or order.has(id):
			return
		order.append(id)
	for id in defaults:
		if not order.has(id):
			order.append(id)
	spell_order = order

func _save() -> void:
	var cfg := ConfigFile.new()
	for i in range(4):
		cfg.set_value("quick", "slot%d" % (i + 1), quick_items[i])
	cfg.set_value("spells", "order", spell_order)
	cfg.save(SAVE_PATH)
