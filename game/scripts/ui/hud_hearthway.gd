extends HudWindow
class_name HudHearthway

## The Hearth window (F at a hearth, travel.json `nodes` of kind hearthway).
## Lists every other hearth of the network grouped by map: each can be
## travelled to for one pinch of Waycoal; a hearth above the character's
## level carries a lock and says the level it needs. Waycoal and the
## keeper's Waystake boots are sold right here. The server decides everything
## (RealmSession.travel, buy_item); this window only asks and shows.

const DUST := "hearth_dust"
const BOOT := "waylink_boot"
const EMERALD := Color(0.36, 0.86, 0.5)
const EMERALD_DK := Color(0.07, 0.2, 0.13)

var session: Node
## The player's sheet (PlayerSheet): level, bag, oril and item answers.
var sheet: PlayerSheet
var node_id := ""
## Set by MapTravel: plays the departure flames, then asks for the trip
## (from, to).
var on_travel: Callable
## The destinations listed last (node ids, in order) and their buttons, for
## the travel check.
var listed: Array = []
var travel_buttons := {}

var _bought := DUST
var _dust_label: Label
var _price_label: Label
var _here_label: Label
var _list: VBoxContainer
var _buy_id := -1

func _init() -> void:
	super._init("Emberway", Vector2(520, 620))
	name = "HearthwayWindow"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 8)
	_here_label = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	_here_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_here_label)
	body.add_child(_dust_card())
	body.add_child(_section(tr("Destinations")))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	body.add_child(_boot_row())

## The pouch: what you carry, the price, and the two buy buttons, on an
## emerald-rimmed card (the colour of the flames it makes).
func _dust_card() -> PanelContainer:
	var card_box := PanelContainer.new()
	card_box.add_theme_stylebox_override("panel", _card_box(EMERALD_DK, EMERALD, 0.95))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card_box.add_child(row)
	row.add_child(UITheme.icon_rect(DUST, 52))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	_dust_label = HudKit.label("", 17, HudKit.GOLD_HI, HudKit.bold())
	text.add_child(_dust_label)
	_price_label = HudKit.label("", 13, HudKit.PARCHMENT.darkened(0.15), HudKit.body(), 3)
	_price_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(_price_label)
	for amount in [1, 5]:
		var buy := HudKit.button(tr("Buy %d") % amount, 14)
		buy.custom_minimum_size = Vector2(64, 34)
		buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		buy.pressed.connect(_buy_item.bind(DUST, amount))
		row.add_child(buy)
	return card_box

## A small heading with gold rules either side.
func _section(text: String) -> HBoxContainer:
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

## The keeper's other ware, quiet at the foot of the window.
func _boot_row() -> PanelContainer:
	var card_box := PanelContainer.new()
	card_box.add_theme_stylebox_override("panel", _card_box(HudKit.NAVY, HudKit.GOLD_DK, 0.7))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card_box.add_child(row)
	row.add_child(UITheme.icon_rect(BOOT, 34))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	text.add_child(HudKit.label(tr("Waystake"), 14, HudKit.PARCHMENT, HudKit.bold(), 3))
	var boot_note := HudKit.label(tr("%s Oril - carries your party anywhere") % _oril(int(ItemRules.item(BOOT).get("buy_price", 0))),
		12, HudKit.TEXT_DIM, HudKit.body(), 2)
	boot_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(boot_note)
	var buy := HudKit.button(tr("Buy"), 14)
	buy.custom_minimum_size = Vector2(70, 30)
	buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	buy.pressed.connect(_buy_item.bind(BOOT, 1))
	row.add_child(buy)
	return card_box

static func _card_box(bg: Color, rim: Color, alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg.r, bg.g, bg.b, alpha)
	sb.border_color = Color(rim.r, rim.g, rim.b, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	sb.anti_aliasing = true
	return sb

## Open at the hearth `at_node`.
func open_at(at_node: String) -> void:
	node_id = at_node
	set_title("Emberway")  # i18n
	if _here_label != null:
		_here_label.text = tr("You stand at the hearth of %s") % I18n.t(String(TravelData.node(at_node).get("label", "")))
	if sheet != null and not sheet.equipment_answer.is_connected(_answer):
		sheet.equipment_answer.connect(_answer)
	refresh()
	open()

func _process(_delta: float) -> void:
	if visible:
		_refresh_dust()

func dust_count() -> int:
	var n := 0
	if sheet != null:
		for entry: Dictionary in sheet.inventory:
			if String(entry.get("id", "")) == DUST:
				n += int(entry.get("amount", 1))
	return n

func _refresh_dust() -> void:
	if _dust_label == null:
		return
	var price := int(ItemRules.item(DUST).get("buy_price", 0))
	var count := dust_count()
	_dust_label.text = (tr("Waycoal: %d lump") if count == 1 else tr("Waycoal: %d lumps")) % count
	_price_label.text = tr("%s Oril a lump, one per journey") % _oril(price)
	var cost := int(TravelData.hearth_price()[1])
	for id: String in travel_buttons:
		var button: Button = travel_buttons[id]
		if is_instance_valid(button):
			button.disabled = count < cost

## 12500 -> "12,500".
static func _oril(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out

func refresh() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		_list.remove_child(child)   # out of the layout now, not at the frame's end
		child.queue_free()
	travel_buttons.clear()
	listed.clear()
	var level := sheet.level if sheet != null else 1
	# Group the hearths by map, in the order travel.json lists them.
	var groups: Dictionary = {}
	var all := TravelData.nodes()
	for id: String in all:
		var dest: Dictionary = all[id]
		if id == node_id or String(dest.get("kind", "")) != "hearthway":
			continue
		var map_id := String(dest.get("map", ""))
		if not groups.has(map_id):
			groups[map_id] = []
		(groups[map_id] as Array).append(id)
	for map_id: String in groups:
		var heading := HudKit.label(TravelData.display_name(map_id), 12, HudKit.GOLD, HudKit.bold(), 3)
		_list.add_child(heading)
		for id: String in groups[map_id]:
			_list.add_child(_destination(id, level))
			listed.append(id)
	_refresh_dust()

## One hearth: a card with its name, a line saying what it takes, and the
## Travel button (or the level it waits for).
func _destination(id: String, level: int) -> PanelContainer:
	var dest := TravelData.node(id)
	var need := int(dest.get("level_min", 1))
	var open_to_travel := level >= need
	var card_box := PanelContainer.new()
	card_box.add_theme_stylebox_override("panel", _card_box(HudKit.NAVY_LT if open_to_travel else HudKit.INK,
		EMERALD if open_to_travel else HudKit.GOLD_DK, 0.92 if open_to_travel else 0.75))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card_box.add_child(row)
	var glyph := UITheme.icon_rect("ui_portal" if open_to_travel else "ui_lock", 30)
	if not open_to_travel:
		glyph.modulate = Color(1, 1, 1, 0.55)
	row.add_child(glyph)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var name_label := HudKit.label(I18n.t(String(dest.get("label", id))), 16,
		HudKit.GOLD_HI if open_to_travel else HudKit.TEXT_DIM, HudKit.bold(), 3)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	text.add_child(name_label)
	var note := tr("1 lump of Waycoal")
	if level < need:
		note = tr("Requires level %d (you are %d)") % [need, level]
	var note_label := HudKit.label(note, 12, EMERALD.darkened(0.1) if open_to_travel else HudKit.TEXT_DIM.darkened(0.15), HudKit.body(), 2)
	note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(note_label)
	if not open_to_travel:
		var badge := HudKit.label(tr("Lv %d") % need, 14, Color(0.9, 0.45, 0.35), HudKit.bold(), 3)
		badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(badge)
	else:
		var go := HudKit.button(tr("Travel"), 14)
		go.custom_minimum_size = Vector2(92, 34)
		go.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		go.pressed.connect(_travel.bind(id))
		row.add_child(go)
		travel_buttons[id] = go
	return card_box

func _travel(dest_id: String) -> void:
	close()
	if on_travel.is_valid():
		on_travel.call(node_id, dest_id)
	elif session != null:
		session.travel(node_id, dest_id)

func _buy_item(item_id: String, amount: int) -> void:
	if session == null:
		return
	_bought = item_id
	_buy_id = int(session.buy_item(item_id, amount))

func _answer(answer: Dictionary) -> void:
	if int(answer.get("request_id", -2)) != _buy_id:
		return
	_buy_id = -1
	var hud: Node = get_parent().get_node_or_null("HUD") if get_parent() != null else null
	var reason := String(answer.get("reason", ""))
	var fails := {"no_gold": tr("Not enough Oril."), "bag_full": tr("Your bag is full."),
		"not_at_shop": tr("Stand at the hearth to buy.")}
	var ok := bool(answer.get("ok", false))
	var text := tr("%s bought.") % I18n.t(String(ItemRules.item(_bought).get("name", _bought)))
	if not ok:
		text = String(fails.get(reason, tr("The hearth keeper shakes his head.")))
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, "good" if ok else "warn")
	if ok:
		AudioManager.play_sound_at("ui_coin", Vector3.ZERO, null, true)
	else:
		AudioManager.play_deny()
	# only the dust count and the Travel buttons follow a purchase (a rebuilt
	# list dropped the hover under the pointer)
	if visible:
		_refresh_dust()
