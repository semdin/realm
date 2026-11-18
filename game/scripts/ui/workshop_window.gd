extends Control

## Kestrin's workshop (O, anywhere) - the blacksmith. It works on ONE
## item put on its anvil: drag a wand, cloak, broom or accessory from the bag
## onto the slot, or right-click it in the bag while the workshop is open. The
## anvil header shows the item; below it two tabs:
##   Upgrade  - +N -> +N+1 with the stat lines now and after (gains in green),
##              the materials (one cell each, have/need) and the oril cost,
##              the success chance and the downgrade risk, then UPGRADE
##              (combat.json `wand_tiers`, `upgrade_curves`);
##   Enchant  - the item's enchantment slots (filled with grade, or empty) and
##              the two scrolls: imbue (chance by the current count) and
##              reweave.
## With the anvil empty the page explains both instead of standing empty. The
## server rolls every outcome; a request names the item by its bag cell and
## the answer comes back through PlayerSheet.equipment_answer (shared with the
## bag and the action bar, each keeping only its own request id). The new
## sheet follows the answer, so the window stays busy until it arrives.
##
## The workshop docks left of the inventory, which opens with it.

const WIDTH := 430.0
const HEIGHT := 600.0
const PAGE_H := 376.0
const MAT_CELL := 50.0
## How long the last outcome stays in the footer, and the anvil's flash.
const RESULT_SECONDS := 4.0
const FLASH_SECONDS := 0.9

const WELL := Color("070b12")
const WELL_EDGE := Color("3a3122")
const FAINT := Color(0.435, 0.424, 0.400)
const GOOD := Color(0.498, 0.839, 0.478)
const BAD := Color(0.937, 0.416, 0.373)

const Inventory := preload("res://scripts/ui/inventory_arcane.gd")

var player: PlayerSheet = null
## The instance on the anvil (its uid), 0 = empty.
var target_uid := 0
## The request on its way (0 = none), what it was, and the sheet revision it
## was sent against: after an accepted answer the window waits for a newer
## sheet before it takes the next request.
var _pending_id := 0
var _last_op := ""
var _sent_revision := -1
var _settle_revision := -1
## The last answer, for the footer and the check: {op, ok, reason, amount,
## good, text}, and how many answers came.
var last_result: Dictionary = {}
var results_seen := 0
var _result_until := 0.0
## What the pages were last built from (see _refresh).
var _shown_key := ""
var _layer: CanvasLayer
var _window: UIWindow
var _tooltip: ItemTooltip
var _anvil_card: PanelContainer
var _slot: UISlot
var _slot_hint: AnvilHint
var _flash: AnvilFlash
var _item_name: Label
var _item_plus: Label
var _item_meta: Label
var _empty_hint: Label
var _take: Button
var _tab_row: Control
var _tabs: Dictionary = {}    # page id -> TabChip
var _pages: Dictionary = {}   # page id -> VBoxContainer
var _page := "refine"
var _enchant_count: Label
var _refine: VBoxContainer
var _enchant: VBoxContainer
var _upgrade_button: Button
var _imbue_button: Button
var _reweave_button: Button
var _foot: Label

func _ready() -> void:
	name = "WorkshopUI"
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer = CanvasLayer.new()
	_layer.layer = 10
	add_child(_layer)
	_window = ArcaneSkin.window(I18n.upper(tr("Kestrin")), Vector2(WIDTH, HEIGHT), "ui_kestrin")
	_window.name = "Window"
	_window.closed.connect(hide)
	_layer.add_child(_window)
	_build()
	_tooltip = ItemTooltip.new()
	_layer.add_child(_tooltip)
	visibility_changed.connect(func():
		_layer.visible = visible
		_refresh_bag()   # the anvil's lock on a bag slot follows the window
		if not visible and _tooltip != null: _tooltip.hide_item())
	hide()

# -------------------------------------------------------------------- build

func _build() -> void:
	var body := _window.body
	body.add_theme_constant_override("separation", 10)
	_build_anvil(body)
	# Tabs, the character window's strip.
	var strip := VBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	body.add_child(strip)
	_tab_row = strip
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	strip.add_child(row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(2, 0)
	row.add_child(pad)
	for page in [["refine", tr("Upgrade")], ["enchant", tr("Enchant")]]:
		var tab := TabChip.new(String(page[1]))
		tab.name = "Tab_" + String(page[0])
		tab.chosen.connect(_show_page.bind(String(page[0])))
		row.add_child(tab)
		_tabs[String(page[0])] = tab
	_enchant_count = HudKit.label("", 12, ItemTooltip.ENCHANT_COLOUR, HudKit.body(), 0)
	(_tabs["enchant"] as TabChip).row.add_child(_enchant_count)
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	strip.add_child(rule)

	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, PAGE_H)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(holder)
	for id in ["intro", "refine", "enchant"]:
		var page := VBoxContainer.new()
		page.name = "Page_" + id
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(page)
		_pages[id] = page
	_build_intro(_pages["intro"])
	_refine = _pages["refine"]
	_enchant = _pages["enchant"]

	_foot = HudKit.label(tr("Right-click an item in your bag or drag it here"), 12, FAINT, HudKit.body(), 0)
	_foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_foot)

## The anvil: the slot, the item's name and kind, and the button that takes
## it off again.
func _build_anvil(body: VBoxContainer) -> void:
	_anvil_card = PanelContainer.new()
	_anvil_card.name = "Anvil"
	_anvil_card.add_theme_stylebox_override("panel", _box(WELL, WELL_EDGE, 5, 12))
	_anvil_card.custom_minimum_size = Vector2(0, 92)
	body.add_child(_anvil_card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_anvil_card.add_child(row)
	_slot = UISlot.new(Vector2(66, 66))
	_slot.name = "AnvilSlot"
	_slot.equipment_interaction = true
	_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slot.drop_check = func(_s, payload): return _accepts(payload)
	_slot.dropped.connect(func(_s, payload): set_target(int(payload.get("uid", 0))))
	_slot.activated.connect(func(_s): clear_target())
	_slot.slot_entered.connect(func(s):
		if s.item_id != "":
			_tooltip.show_item(s.item_id, s.entry)
			_tooltip.follow_cursor())
	_slot.slot_exited.connect(func(_s): _tooltip.hide_item())
	_slot.ready.connect(func(): _slot.theme_type_variation = &"ArcaneSlot")
	row.add_child(_slot)
	_slot_hint = AnvilHint.new()
	_slot_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_slot.add_child(_slot_hint)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	info.add_child(name_row)
	_item_plus = HudKit.label("", 17, HudKit.GOLD_HI, HudKit.title(), 2)
	name_row.add_child(_item_plus)
	_item_name = HudKit.label("", 17, Color.WHITE, HudKit.body(), 2)
	_item_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_item_name.custom_minimum_size.x = 60
	name_row.add_child(_item_name)
	_item_meta = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	info.add_child(_item_meta)
	_empty_hint = HudKit.label(tr("Drag the item you want to upgrade or enchant here, or right-click it in your bag."), 14, HudKit.TEXT_DIM, HudKit.body(), 0)
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_hint.custom_minimum_size.x = 200
	info.add_child(_empty_hint)

	_take = Button.new()
	_take.name = "Take"
	_take.text = "×"
	_take.tooltip_text = tr("Take it off the anvil")
	_take.focus_mode = Control.FOCUS_NONE
	_take.custom_minimum_size = Vector2(26, 26)
	_take.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_take.add_theme_font_override("font", HudKit.body())
	_take.add_theme_font_size_override("font_size", 16)
	_take.add_theme_color_override("font_color", HudKit.TEXT_DIM)
	_take.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	for state in ["normal", "hover", "pressed"]:
		_take.add_theme_stylebox_override(state, _box(Color("0d1320"), HudKit.GOLD if state != "normal" else Color("3a4560"), 4, 0))
	_take.pressed.connect(clear_target)
	row.add_child(_take)

	# The outcome's flash over the whole anvil (drawn above its children).
	_flash = AnvilFlash.new()
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_anvil_card.add_child(_flash)

## What the workshop does, in place of empty pages while the anvil is empty.
func _build_intro(page: VBoxContainer) -> void:
	page.add_theme_constant_override("separation", 8)
	var top := Control.new()
	top.custom_minimum_size = Vector2(0, 4)
	page.add_child(top)
	page.add_child(_howto("mat_phoenix_ash", tr("Upgrade"),
			tr("Takes rods, cloaks, skiffs and accessories from +0 to +9. Every step needs materials and Oril; the chance falls with each level, and from +%d a failure drops the item one level.")
			% _downgrade_from()))
	page.add_child(_howto(String(_enchant_rules().get("imbue_scroll", "scroll_imbue")), tr("Enchant"),
			tr("An item holds up to %d enchantments. An Imbue rune adds a new one (the more it has, the lower the chance); a Reweave rune rerolls them all.")
			% _max_bonuses()))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	var note := HudKit.label(tr("Worn items must be taken off first  ·  the item stays locked in the bag while on the anvil"), 12, FAINT, HudKit.body(), 0)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(note)

func _howto(icon_id: String, title: String, text: String) -> PanelContainer:
	var card := PanelContainer.new()
	var sb := _box(Color(0.086, 0.141, 0.227, 0.45), Color("23324c"), 5, 11)
	sb.content_margin_left = 12
	card.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	var icon := TextureRect.new()
	icon.texture = UITheme.icon_for(icon_id)
	icon.custom_minimum_size = Vector2(40, 40)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(icon)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 3)
	row.add_child(col)
	col.add_child(HudKit.label(I18n.upper(title), 13, HudKit.GOLD_LT, HudKit.title(), 2))
	var body := HudKit.label(text, 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size.x = 260
	col.add_child(body)
	return card

static func _box(bg: Color, border: Color, radius: int, margin: float) -> StyleBoxFlat:
	return CharacterWindow._box(bg, border, radius, margin)

func _show_page(page: String) -> void:
	_page = page
	var has := not _find(target_uid).is_empty()
	_tab_row.visible = has
	for id in _pages:
		(_pages[id] as Control).visible = (id == page) if has else id == "intro"
	for id in _tabs:
		(_tabs[id] as TabChip).selected = id == page

## The page the check (and a capture) wants in front.
func show_page(page: String) -> void:
	_show_page(page)

func _clear(box: Container) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

func _gap(box: Container, px: float) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(c)

# ------------------------------------------------------------------- rules

static func _enchant_rules() -> Dictionary:
	return ItemRules.combat().get("enchant", {})

static func _max_bonuses() -> int:
	return int(_enchant_rules().get("max_bonuses", 5))

static func _downgrade_from() -> int:
	return int((ItemRules.combat().get("upgrade_curves", {}) as Dictionary).get("fail_downgrade_from", 4))

## The highest +N (the last `wand_tiers` step).
static func _top_tier() -> int:
	return maxi(0, (ItemRules.combat().get("wand_tiers", []) as Array).size() - 1)

## An enchantment's grade 1-5: where its value sits in its stat's `values`.
static func grade_of(bonus: Dictionary) -> int:
	var spec: Dictionary = (_enchant_rules().get("stats", {}) as Dictionary).get(String(bonus.get("stat", "")), {})
	var values: Array = spec.get("values", [])
	var value := float(bonus.get("value", 0.0))
	for i in values.size():
		if is_equal_approx(float(values[i]), value):
			return i + 1
	return 1

# --------------------------------------------------------------- the anvil

## The item's base lines at refine level `tier` (what the card shows).
static func stat_lines(id: String, tier: int) -> Array:
	return ItemRules.fixed_lines(id, tier).map(func(line): return String(line.text))

func open_for_player(p_player: PlayerSheet) -> void:
	if is_instance_valid(player) and player != p_player:
		if player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.disconnect(_equipment_answer)
		if player.inventory_changed.is_connected(_refresh): player.inventory_changed.disconnect(_refresh)
	player = p_player
	if not player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.connect(_equipment_answer)
	if not player.inventory_changed.is_connected(_refresh): player.inventory_changed.connect(_refresh)
	# The anvil opens empty: the player drags or right-clicks the item to work.
	target_uid = 0
	show()
	_window.open()
	# The bag opens alongside: it is where items are dragged from.
	var inventory := _inventory()
	if inventory != null:
		if not inventory.visible: inventory.open_for_player(player)
		inventory._set_merchant_open(false)
	_place(inventory)
	_refresh()

func toggle(p_player: PlayerSheet) -> void:
	if visible:
		hide()
	else:
		open_for_player(p_player)

func _inventory() -> Control:
	return get_parent().get_node_or_null("Inventory") as Control if get_parent() != null else null

## Dock left of the inventory window, top-aligned with it.
func _place(inventory: Control) -> void:
	var canvas := get_viewport().get_visible_rect().size
	var at := ((canvas - Vector2(WIDTH, HEIGHT)) * 0.5).floor()
	if inventory != null and inventory.get("_window") != null:
		var inv: UIWindow = inventory._window
		at = Vector2(maxf(8.0, inv.offset_left - WIDTH - 12.0), inv.offset_top + 40.0)
	at.y = clampf(at.y, 24.0, maxf(24.0, canvas.y - HEIGHT - 12.0))
	ArcaneSkin.place(_window, at, Vector2(WIDTH, minf(HEIGHT, canvas.y - at.y - 12.0)))

## Workable items: refinable or enchantable instances in the bag. Worn pieces
## must be taken off first.
func _accepts(payload: Dictionary) -> bool:
	var id := String(payload.get("id", ""))
	var uid := int(payload.get("uid", 0))
	if uid <= 0 or String(payload.get("source_slot", "")) != "" or (is_instance_valid(player) and _worn_slot(uid) != ""):
		return false
	return ItemRules.refinable(id) or ItemRules.enchantable(id)

## True while the instance `uid` sits on the anvil: the bag keeps it in place
## (no moving, equipping or selling) until it is taken off or the window closes.
func holds(uid: int) -> bool:
	return visible and uid > 0 and target_uid == uid

func set_target(uid: int) -> void:
	target_uid = uid
	var id := String(_find(uid).get("id", ""))
	# Open on the page the item can use: enchant-only pieces skip Upgrade.
	_page = "enchant" if id != "" and not ItemRules.refinable(id) else "refine"
	_refresh()
	_refresh_bag()

func clear_target() -> void:
	target_uid = 0
	_refresh()
	_refresh_bag()

func _refresh_bag() -> void:
	var inventory := _inventory()
	if inventory != null and inventory.visible:
		inventory.refresh()

## The instance `uid` in the bag or worn ({} when gone).
func _find(uid: int) -> Dictionary:
	if uid <= 0 or not is_instance_valid(player): return {}
	for entry: Dictionary in player.inventory:
		if int(entry.get("uid", 0)) == uid: return entry
	for slot in player.equipment:
		if int(player.equipment[slot].get("uid", 0)) == uid: return player.equipment[slot]
	return {}

func _worn_slot(uid: int) -> String:
	for slot in player.equipment:
		if int(player.equipment[slot].get("uid", 0)) == uid: return String(slot)
	return ""

## The item on the anvil ({} when it is empty).
func target_entry() -> Dictionary:
	return _find(target_uid)

func _count(id: String) -> int:
	var have := 0
	for entry: Dictionary in player.inventory:
		if entry.id == id and int(entry.get("tier", 0)) == 0: have += int(entry.amount)
	return have

## The materials one upgrade step asks for, as [[id, amount], ...]: a step may
## list several under `materials`, or name one with material_id/_amount.
static func _step_materials(step: Dictionary) -> Array:
	if step.has("materials"):
		return (step.materials as Array).map(func(m): return [String(m.get("id", "")), int(m.get("amount", 0))])
	if String(step.get("material_id", "")) == "":
		return []
	return [[String(step.material_id), int(step.material_amount)]]

## A request is on its way, or its answer came and the sheet it changed has
## not yet.
func busy() -> bool:
	if _pending_id != 0:
		return true
	return _settle_revision >= 0 and is_instance_valid(player) and player.revision() == _settle_revision

func _refresh() -> void:
	if not is_instance_valid(player) or _slot == null: return
	if _settle_revision >= 0 and player.revision() != _settle_revision:
		_settle_revision = -1
	if target_uid > 0 and _worn_slot(target_uid) != "":
		target_uid = 0   # the anvil only works bag items
	var item := _find(target_uid)
	if item.is_empty():
		target_uid = 0
	# Rebuild the pages only when something they show changed: the sheet also
	# changes with every potion and every coin, and a rebuild under the
	# pointer drops a hover or a press.
	# What the pages read of the purse and the stacks: whether the next step
	# is affordable and the counts of its materials and the two scrolls (the
	# whole purse and every stack rebuilt both pages on each kill's oril).
	var step_tier := int(item.get("tier", 0))
	var tiers: Array = ItemRules.combat().get("wand_tiers", [])
	var affordable := true
	var wanted := [String(_enchant_rules().get("imbue_scroll", "")), String(_enchant_rules().get("reweave_scroll", ""))]
	if not item.is_empty() and ItemRules.refinable(String(item.id)) and step_tier < tiers.size():
		affordable = int(player.oril) >= int((tiers[step_tier] as Dictionary).get("cost", 0))
		for need in _step_materials(tiers[step_tier]):
			wanted.append(String(need[0]))
	var stacks := wanted.map(func(id): return _count(String(id)))
	var shown := var_to_str([target_uid, item, affordable, busy(), stacks])
	if shown == _shown_key or not visible:
		_shown_key = shown if visible else ""
		_show_foot()
		return
	_shown_key = shown
	var id := String(item.get("id", ""))
	_slot.set_item(id, item)
	_slot_hint.visible = item.is_empty()
	_take.visible = not item.is_empty()
	_empty_hint.visible = item.is_empty()
	_item_plus.visible = not item.is_empty()
	_item_name.visible = not item.is_empty()
	_item_meta.visible = not item.is_empty()
	_clear(_refine)
	_clear(_enchant)
	_upgrade_button = null
	_imbue_button = null
	_reweave_button = null
	if not item.is_empty():
		var tier := int(item.get("tier", 0))
		var data := ItemRules.item(id)
		_item_plus.text = "+%d" % tier
		_item_plus.visible = ItemRules.refinable(id)
		_item_name.text = I18n.t(String(data.get("name", id)))
		_item_name.add_theme_color_override("font_color", ItemTooltip.RARITY_COLOUR.get(ItemTooltip.rarity_of(id), Color.WHITE))
		_item_meta.text = "%s  ·  %s  ·  %s" % [_kind_text(data), ItemTooltip.rarity_label(id), tr("Level %d") % ItemRules.required_level(id)]
		_build_refine(id, tier)
		_build_enchant(id, item)
		_enchant_count.text = "%d/%d" % [(item.get("bonuses", []) as Array).size(), _max_bonuses()] \
				if ItemRules.enchantable(id) else ""
	_show_foot()
	_show_page(_page)

## The item's kind as the bag names it: a wand or a broom by its type, a worn
## piece by the slot it goes in (Robes, Head, Ring I, ...).
func _kind_text(data: Dictionary) -> String:
	var kind := String(data.get("type", ""))
	if kind in ["weapon", "mount"]:
		return tr(String(ItemTooltip.KIND_LABEL[kind]))
	var slots: Array = data.get("slots", [])
	if not slots.is_empty() and Inventory.SLOT_LABELS.has(String(slots[0])):
		return tr(String(Inventory.SLOT_LABELS[String(slots[0])]))
	return tr(String(ItemTooltip.KIND_LABEL.get(kind, kind.capitalize())))

## The footer: the last outcome for a while, else the hint (only while an
## item is on the anvil - the empty anvil already says it).
func _show_foot() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not last_result.is_empty() and now < _result_until:
		_foot.visible = true
		_foot.text = String(last_result.get("text", ""))
		_foot.add_theme_color_override("font_color", GOOD if bool(last_result.get("good", false)) else BAD)
		return
	_foot.visible = target_uid != 0
	_foot.text = tr("Right-click an item in your bag or drag it here")
	_foot.add_theme_color_override("font_color", FAINT)

# ------------------------------------------------------------------ upgrade

func _build_refine(id: String, tier: int) -> void:
	var page := _refine
	page.add_theme_constant_override("separation", 0)
	_gap(page, 14)
	if not ItemRules.refinable(id):
		var label := HudKit.label(tr("Cannot be refined"), 15, HudKit.TEXT_DIM, HudKit.body(), 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(label)
		return
	var top_tier := _top_tier()
	var steps := HBoxContainer.new()
	steps.alignment = BoxContainer.ALIGNMENT_CENTER
	steps.add_theme_constant_override("separation", 14)
	page.add_child(steps)
	if tier >= top_tier:
		steps.add_child(StepBadge.new("+%d" % tier, true))
		_gap(page, 12)
		var done := HudKit.label(tr("Fully refined"), 16, HudKit.GOLD_HI, HudKit.body(), 2)
		done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(done)
		var sub := HudKit.label(tr("This item is at its highest level."), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(sub)
		_gap(page, 12)
		_compare(page, id, tier, tier)
		return
	steps.add_child(StepBadge.new("+%d" % tier, false))
	steps.add_child(ArrowMark.new())
	steps.add_child(StepBadge.new("+%d" % (tier + 1), true))
	_gap(page, 12)
	_compare(page, id, tier, tier + 1)

	var step: Dictionary = ItemRules.combat().wand_tiers[tier]
	var cost := int(step.cost)
	var cost_ok := int(player.oril) >= cost
	var head := HBoxContainer.new()
	page.add_child(head)
	_gap(page, 6)
	head.add_child(HudKit.label(I18n.upper(tr("Requirements")), 12, HudKit.GOLD_LT, HudKit.title(), 2))
	var head_gap := Control.new()
	head_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_gap)
	head.add_child(_cost_pill(cost, cost_ok))
	var mats := HBoxContainer.new()
	mats.add_theme_constant_override("separation", 6)
	page.add_child(mats)
	var mats_ok := true
	for need in _step_materials(step):
		var have := _count(String(need[0]))
		mats_ok = mats_ok and have >= int(need[1])
		mats.add_child(_material_cell(String(need[0]), int(need[1]), have))

	_gap(page, 12)
	var chance := int(step.chance)
	var row := HBoxContainer.new()
	page.add_child(row)
	var caption := HudKit.label(tr("Success chance"), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	row.add_child(HudKit.label(tr("%d%%") % chance, 14, HudKit.PARCHMENT, HudKit.body(), 0))
	_gap(page, 4)
	var colour := GOOD if chance >= 75 else (HudKit.GOLD_LT if chance >= 40 else BAD)
	var bar := CharacterWindow.FillBar.new(colour.lightened(0.15), colour.darkened(0.25), 10.0)
	bar.fraction = chance / 100.0
	page.add_child(bar)
	_gap(page, 5)
	var risky := tier >= _downgrade_from()
	page.add_child(HudKit.label(tr("If it fails, the item drops to +%d") % (tier - 1) if risky else tr("A failure does not lower the level"),
			13, BAD if risky else FAINT, HudKit.body(), 0))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	_upgrade_button = HudKit.gold_button(I18n.upper(tr("Upgrade now")), 40.0, 16)
	_upgrade_button.name = "Upgrade"
	_upgrade_button.disabled = busy() or not cost_ok or not mats_ok
	_upgrade_button.pressed.connect(refine)
	page.add_child(_upgrade_button)

## The item's stat lines now and after the step, side by side; a line that
## grows shows its new value in green.
func _compare(page: VBoxContainer, id: String, from: int, to: int) -> void:
	var now := stat_lines(id, from)
	var later := stat_lines(id, to)
	page.add_child(_hair(0.25))
	var split := RegEx.create_from_string("^(.*?)\\s*([+\\-]?\\d.*)$")
	for i in now.size():
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, 28)
		row.add_theme_constant_override("separation", 8)
		page.add_child(row)
		var m := split.search(String(now[i]))
		var key := m.get_string(1) if m != null else String(now[i])
		var value := m.get_string(2) if m != null else ""
		var next_text := String(later[i]) if i < later.size() else String(now[i])
		var m2 := split.search(next_text)
		var next_value := m2.get_string(2) if m2 != null else next_text
		var k := HudKit.label(key, 14, HudKit.TEXT_DIM, HudKit.body(), 0)
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(k)
		var v := HudKit.label(value, 14, HudKit.PARCHMENT, HudKit.body(), 0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(v)
		if from != to:
			var arrow := HudKit.label("›", 14, FAINT, HudKit.body(), 0)
			arrow.custom_minimum_size.x = 12
			arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			row.add_child(arrow)
			var n := HudKit.label(next_value, 14, FAINT if next_value == value else GOOD, HudKit.body(), 0)
			n.custom_minimum_size.x = 92
			n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(n)
		page.add_child(_hair(0.12))

func _hair(alpha: float) -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(HudKit.GOLD, alpha)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line

func _cost_pill(cost: int, ok: bool) -> PanelContainer:
	var pill := PanelContainer.new()
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := _box(WELL, Color("2f5a2c") if ok else Color("6a2622"), 12, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	pill.add_child(row)
	row.add_child(HudKit.label(tr("Cost"), 12, HudKit.TEXT_DIM, HudKit.body(), 0))
	row.add_child(HudKit.label(Inventory.oril_text(cost), 14, HudKit.GOLD_HI if ok else BAD, HudKit.body(), 0))
	var coin := PanelContainer.new()
	coin.custom_minimum_size = Vector2(15, 15)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin.add_theme_stylebox_override("panel", _box(Color(0.85, 0.62, 0.22), HudKit.GOLD_HI, 8, 0))
	row.add_child(coin)
	return pill

## One material: its icon in a slot, "have/need" under it (green when there
## is enough), and its name on hover.
func _material_cell(id: String, need: int, have: int) -> Control:
	var cell := UISlot.new(Vector2(MAT_CELL, MAT_CELL))
	cell.set_item(id, {"amount": 1})
	cell.ready.connect(func(): cell.theme_type_variation = &"ArcaneSlot")
	cell.tooltip_text = tr("%s  ·  you have %d, need %d") % [I18n.t(String(ItemRules.item(id).get("name", id))), have, need]
	var ok := have >= need
	if not ok:
		cell.self_modulate = Color(0.75, 0.7, 0.7)
	var count := HudKit.label("%d/%d" % [have, need], 12, GOOD if ok else BAD, HudKit.bold(), 4)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	count.offset_top = -17
	count.offset_bottom = 1
	cell.add_child(count)
	cell.ready.connect(func(): cell.move_child(count, -1))   # over the icon UISlot adds in _ready
	return cell

# ------------------------------------------------------------------ enchant

func _build_enchant(id: String, item: Dictionary) -> void:
	var page := _enchant
	page.add_theme_constant_override("separation", 5)
	_gap(page, 9)
	if not ItemRules.enchantable(id):
		var label := HudKit.label(tr("Cannot be enchanted"), 15, HudKit.TEXT_DIM, HudKit.body(), 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(label)
		return
	var rules := _enchant_rules()
	var held: Array = item.get("bonuses", [])
	var cap := _max_bonuses()
	for i in cap:
		page.add_child(_bonus_row(i, held[i] if i < held.size() else {}))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	var is_busy := busy()
	var imbue_id := String(rules.get("imbue_scroll", ""))
	var reweave_id := String(rules.get("reweave_scroll", ""))
	var chances: Array = rules.get("imbue_chance", [100])
	var imbue_chance := int(chances[clampi(held.size(), 0, chances.size() - 1)])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	page.add_child(row)
	var full := held.size() >= cap
	_imbue_button = _scroll_card(imbue_id, tr("Imbue"),
			(tr("Slots full  ·  you have %d") % _count(imbue_id)) if full else (tr("Chance %d%%  ·  you have %d") % [imbue_chance, _count(imbue_id)]))
	_imbue_button.name = "Imbue"
	_imbue_button.disabled = is_busy or full or _count(imbue_id) == 0
	_imbue_button.modulate.a = 0.45 if _imbue_button.disabled else 1.0
	_imbue_button.pressed.connect(imbue)
	row.add_child(_imbue_button)
	_reweave_button = _scroll_card(reweave_id, tr("Reweave"),
			(tr("No enchantments  ·  you have %d") % _count(reweave_id)) if held.is_empty() else (tr("Rerolls %d  ·  you have %d") % [held.size(), _count(reweave_id)]))
	_reweave_button.name = "Reweave"
	_reweave_button.disabled = is_busy or held.is_empty() or _count(reweave_id) == 0
	_reweave_button.modulate.a = 0.45 if _reweave_button.disabled else 1.0
	_reweave_button.pressed.connect(reweave)
	row.add_child(_reweave_button)

## One enchantment slot: its number, the bonus in violet and its grade (1-5),
## or a dim empty slot.
func _bonus_row(index: int, bonus: Dictionary) -> PanelContainer:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 34)
	var empty := bonus.is_empty()
	var sb := _box(Color(0, 0, 0, 0) if empty else WELL, Color("2a3346") if empty else Color("2c2a3c"), 4, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	row.add_theme_stylebox_override("panel", sb)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	var number := HudKit.label(str(index + 1), 12, FAINT, HudKit.body(), 0)
	number.custom_minimum_size.x = 14
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_child(number)
	var text := HudKit.label(tr("Empty enchantment slot") if empty else ItemRules.bonus_text(bonus),
			13 if empty else 15, FAINT if empty else ItemTooltip.ENCHANT_COLOUR, HudKit.body(), 0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(text)
	if not empty:
		var grade := GradePips.new(clampi(grade_of(bonus), 1, 5))
		grade.tooltip_text = tr("Grade %d/5") % grade.grade
		line.add_child(grade)
	return row

## A scroll as a button card: its icon, the action, and chance / count.
func _scroll_card(scroll_id: String, title: String, detail: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	# Room for the title and a detail that wraps to two lines ("1 efsunu
	# yeniden atar  ·  elinde 2").
	button.custom_minimum_size = Vector2(0, 68)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = I18n.t(String(ItemRules.item(scroll_id).get("desc", "")))
	var looks := {"normal": [Color(0.17, 0.13, 0.28, 0.75), Color("5a4a8a")], "hover": [Color(0.23, 0.18, 0.38, 0.85), ItemTooltip.ENCHANT_COLOUR],
			"pressed": [Color(0.13, 0.1, 0.22, 0.9), ItemTooltip.ENCHANT_COLOUR], "disabled": [Color(0.08, 0.07, 0.12, 0.6), Color("3a3550")]}
	for state in looks:
		button.add_theme_stylebox_override(state, _box(looks[state][0], looks[state][1], 5, 0))
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -8
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	var icon := TextureRect.new()
	icon.texture = UITheme.icon_for(scroll_id)
	icon.custom_minimum_size = Vector2(38, 38)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	col.add_child(HudKit.label(title, 15, HudKit.GOLD_HI, HudKit.body(), 2))
	var small := HudKit.label(detail, 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	small.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	small.custom_minimum_size.x = 100
	col.add_child(small)
	return button

# ---------------------------------------------------------------- requests

## Refine the item on the anvil one step. True when the request went out.
func refine() -> bool:
	return _send("refine", "")

## Use an imbue / a reweave scroll on the item on the anvil.
func imbue() -> bool:
	return _send("imbue", String(_enchant_rules().get("imbue_scroll", "")))

func reweave() -> bool:
	return _send("reweave", String(_enchant_rules().get("reweave_scroll", "")))

func _send(op: String, scroll_id: String) -> bool:
	var item := _find(target_uid)
	if not is_instance_valid(player) or item.is_empty() or busy(): return false
	_last_op = op
	_sent_revision = player.revision()
	_pending_id = player.refine(item) if op == "refine" else player.enchant(scroll_id, item)
	_refresh()
	return _pending_id != 0

func _equipment_answer(result: Dictionary) -> void:
	if _pending_id == 0 or int(result.get("request_id", -1)) != _pending_id: return
	_pending_id = 0
	var ok := bool(result.get("ok", false))
	var reason := String(result.get("reason", ""))
	# The new sheet follows an accepted answer: hold the next request until it
	# is in (unless it already came).
	_settle_revision = _sent_revision if ok and player.revision() == _sent_revision else -1
	var good := reason in ["refined", "enchanted"]
	var text := I18n.t(String(Inventory.REASONS.get(reason, "Equipment updated.")))
	if text == "":
		text = I18n.t("Equipment updated.")
	# The server answers a reweave as "enchanted" too; it rerolled them all.
	if _last_op == "reweave" and reason == "enchanted":
		text = tr("The enchantments were rewoven.")
	# A refine answers with the level the item is at now.
	if reason in ["refined", "refinement_failed"]:
		text = "%s  ·  +%d" % [text, int(result.get("amount", 0))]
	last_result = {"op": _last_op, "ok": ok, "reason": reason, "amount": int(result.get("amount", 0)),
		"good": good, "text": text}
	results_seen += 1
	_result_until = Time.get_ticks_msec() / 1000.0 + RESULT_SECONDS
	var hud := get_parent().get_node_or_null("HUD") if get_parent() != null else null
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, "good" if good else "warn")
	if reason in ["refined", "refinement_failed", "enchanted", "enchant_failed"]:
		AudioManager.play_sound_at("ui_upgrade_success" if good else "ui_upgrade_fail", Vector3.ZERO, null, true)
		_flash.play(_flash_colour(reason))
	elif not ok:
		AudioManager.play_deny()
	_refresh()

## The anvil's flash: gold for a refine, violet for an enchantment, red for a
## failure.
func _flash_colour(reason: String) -> Color:
	match reason:
		"refined":
			return HudKit.GOLD_HI
		"enchanted":
			return ItemTooltip.ENCHANT_COLOUR
	return BAD

func _process(_delta: float) -> void:
	if not visible:
		return
	if _tooltip != null and _tooltip.visible:
		_tooltip.follow_cursor()
	if not last_result.is_empty() and _result_until > 0.0 and Time.get_ticks_msec() / 1000.0 >= _result_until:
		_result_until = 0.0
		_show_foot()


## The empty anvil slot: the workshop's mark, dim, inside a dashed outline
## that breathes, inviting a drop.
class AnvilHint extends Control:
	var _t := 0.0
	var _mark: Texture2D

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mark = UITheme.icon_for("ui_kestrin")

	func _process(delta: float) -> void:
		if is_visible_in_tree():
			_t += delta
			queue_redraw()

	func _draw() -> void:
		var pulse := 0.5 + 0.5 * sin(_t * TAU / 2.2)
		if _mark != null:
			var s := size.x * 0.46
			draw_texture_rect(_mark, Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s)), false, Color(1, 1, 1, 0.45))
		var r := Rect2(Vector2(8, 8), size - Vector2(16, 16))
		var colour := Color(HudKit.GOLD_LT, 0.35 + 0.45 * pulse)
		var dash := 4.0
		for edge in [[r.position, Vector2(r.end.x, r.position.y)], [Vector2(r.end.x, r.position.y), r.end],
				[r.end, Vector2(r.position.x, r.end.y)], [Vector2(r.position.x, r.end.y), r.position]]:
			var a: Vector2 = edge[0]
			var b: Vector2 = edge[1]
			var length := a.distance_to(b)
			var dir := (b - a) / length
			var d := 0.0
			while d < length:
				draw_line(a + dir * d, a + dir * minf(d + dash, length), colour, 1.0)
				d += dash * 2.0


## The outcome over the anvil: a soft glow that blooms from the item's slot
## and fades, in the outcome's colour.
class AnvilFlash extends Control:
	var _t := -1.0
	var _colour := Color.WHITE

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func play(colour: Color) -> void:
		_colour = colour
		_t = 0.0
		queue_redraw()

	func _process(delta: float) -> void:
		if _t < 0.0:
			return
		_t += delta
		if _t > FLASH_SECONDS:
			_t = -1.0
		queue_redraw()

	func _draw() -> void:
		if _t < 0.0:
			return
		var k := _t / FLASH_SECONDS
		var fade := (1.0 - k) * (1.0 - k)
		# The slot's centre: the card's left padding plus half the 66 px slot.
		var c := Vector2(12.0 + 33.0, size.y * 0.5)
		var reach := lerpf(30.0, size.x * 0.55, sqrt(k))
		for i in 6:
			var f := 1.0 - float(i) / 6.0
			draw_circle(c, reach * f, Color(_colour, 0.07 * fade))
		draw_rect(Rect2(Vector2.ZERO, size), Color(_colour, 0.55 * fade), false, 2.0)


## A round "+N" badge; the step the upgrade reaches is lit.
class StepBadge extends Control:
	var text := ""
	var lit := false

	func _init(p_text: String, p_lit: bool) -> void:
		text = p_text
		lit = p_lit
		custom_minimum_size = Vector2(46, 46)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.0
		if lit:
			draw_circle(c, r + 2.0, Color(0.91, 0.78, 0.48, 0.18))
		draw_circle(c, r, HudKit.GOLD if lit else Color("4a5570"))
		draw_circle(c, r - 2.0, Color("141d30"))
		var font := HudKit.title()
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		draw_string(font, Vector2(c.x - w * 0.5, c.y + 6.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, HudKit.GOLD_HI if lit else HudKit.PARCHMENT)


## The arrow between the two step badges.
class ArrowMark extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(22, 46)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := size.y * 0.5
		draw_line(Vector2(2, y), Vector2(size.x - 4, y), HudKit.GOLD, 2.0, true)
		draw_colored_polygon(PackedVector2Array([Vector2(size.x - 1, y), Vector2(size.x - 8, y - 5), Vector2(size.x - 8, y + 5)]), HudKit.GOLD)


## An enchantment's grade as five small bars, the first `grade` lit.
class GradePips extends Control:
	var grade := 1

	func _init(p_grade: int) -> void:
		grade = p_grade
		custom_minimum_size = Vector2(5 * 8 - 2, 12)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _draw() -> void:
		for i in 5:
			var r := Rect2(Vector2(i * 8, 1), Vector2(6, 10))
			var on := i < grade
			draw_rect(r, ItemTooltip.ENCHANT_COLOUR if on else Color("1c1a2a"))
			draw_rect(r, Color("d6c6ff") if on else Color("3a3550"), false, 1.0)


## A page tab (the character window's strip): dim, lit when chosen.
class TabChip extends PanelContainer:
	signal chosen
	var row: HBoxContainer
	var _label: Label
	var _hover := false
	var selected := false:
		set(value):
			selected = value
			_restyle()

	func _init(caption: String) -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 7)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		_label = HudKit.label(caption, 15, HudKit.TEXT_DIM, HudKit.body(), 0)
		row.add_child(_label)
		mouse_entered.connect(func(): _hover = true; _restyle())
		mouse_exited.connect(func(): _hover = false; _restyle())
		_restyle()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit()
			accept_event()

	func _restyle() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("1d2f4a") if selected else Color(0, 0, 0, 0)
		sb.border_color = HudKit.GOLD_DK if selected else Color(0, 0, 0, 0)
		sb.set_border_width_all(1)
		sb.border_width_bottom = 0
		sb.corner_radius_top_left = 5
		sb.corner_radius_top_right = 5
		sb.content_margin_left = 16
		sb.content_margin_right = 16
		sb.content_margin_top = 6
		sb.content_margin_bottom = 7
		add_theme_stylebox_override("panel", sb)
		if _label != null:
			_label.add_theme_color_override("font_color", HudKit.GOLD_HI if selected else (HudKit.PARCHMENT if _hover else HudKit.TEXT_DIM))
