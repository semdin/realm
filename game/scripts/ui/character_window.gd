extends Control
class_name CharacterWindow

## The character sheet (C): the header (crest, name, house, the level
## medallion and the experience bar) and the Attributes page of the old game's
## character window: the four status-point attributes, what a point gives,
## the total so far, and the "+" that spends one (Metin2: two per level, up to
## the cap in one attribute). The Status and Properties pages come with the
## slice that ports them.
##
## Everything is read off the sheet the server sent (PlayerSheet /
## RealmSession.sheet: `attributes`, `attribute_points`, `exp_next`); "+"
## only asks (RealmSession.spend_attribute) and the new sheet is the answer.

const ATTRIBUTES := [["vit", "Vitality"], ["int", "Intellect"], ["str", "Strength"], ["dex", "Agility"]]  # i18n
const PAGE_H := 300.0
const WANTED := Vector2(470, 470)

const WELL := Color("070b12")
const WELL_EDGE := Color("3a3122")
const FAINT := Color(0.435, 0.424, 0.400)

var session: Node
var card: UIWindow
var body: VBoxContainer
var _crest: TextureRect
var _name: Label
var _house: Label
var _medal: LevelMedal
var _exp_text: Label
var _exp_bar: FillBar
var _points: Label
var _points_box: PanelContainer
var _coin_box: StyleBoxFlat
var _attr_cards: Dictionary = {}   # attribute id -> {card, value, total, bar, plus, hover}
var _shown := ""
var _pulse := 0.0
var _placed := false
## Points asked to be spent (the check reads it).
var spends_sent := 0

func setup(realm_session: Node) -> void:
	session = realm_session

func _ready() -> void:
	name = "CharacterWindow"
	theme = UITheme.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	card = ArcaneSkin.window(I18n.upper(tr("Character")), WANTED)
	card.name = "Card"
	add_child(card)
	card.closed.connect(hide)
	body = card.body
	body.add_theme_constant_override("separation", 10)
	_build_head()
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(rule)
	var page := VBoxContainer.new()
	page.name = "Page_attrs"
	page.custom_minimum_size = Vector2(0, PAGE_H)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(page)
	_build_attributes(page)
	hide()

## Styled box: `bg` filled, `border` edged, `radius` rounded, `margin` inside.
static func _box(bg: Color, border: Color, radius: int, margin: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	sb.anti_aliasing = true
	return sb

static func _attribute_rules() -> Dictionary:
	return ItemRules.combat().get("attributes", {})

# ------------------------------------------------------------------- header

func _build_head() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	body.add_child(head)
	_crest = TextureRect.new()
	_crest.custom_minimum_size = Vector2(58, 58)
	_crest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_crest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_crest)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 2)
	head.add_child(names)
	_name = HudKit.label("", 21, HudKit.GOLD_HI, HudKit.title(), 0)
	names.add_child(_name)
	_house = HudKit.label("", 15, HudKit.PARCHMENT, HudKit.body(), 0)
	names.add_child(_house)
	_medal = LevelMedal.new()
	_medal.caption = I18n.upper(tr("Level"))
	_medal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_medal)

	var exp_box := VBoxContainer.new()
	exp_box.add_theme_constant_override("separation", 3)
	body.add_child(exp_box)
	var row := HBoxContainer.new()
	exp_box.add_child(row)
	var caption := HudKit.label(tr("Experience"), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	_exp_text = HudKit.label("", 13, HudKit.PARCHMENT, HudKit.body(), 0)
	row.add_child(_exp_text)
	_exp_bar = FillBar.new(Color(0.949, 0.765, 0.353), Color(0.604, 0.416, 0.071), 12.0)
	exp_box.add_child(_exp_bar)

# --------------------------------------------------------------- attributes

func _build_attributes(page: VBoxContainer) -> void:
	page.add_theme_constant_override("separation", 5)
	var head := HBoxContainer.new()
	page.add_child(head)
	_points_box = PanelContainer.new()
	_points_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_points_box.add_child(row)
	var coin := PanelContainer.new()
	coin.custom_minimum_size = Vector2(24, 24)
	_coin_box = _box(Color(0.12, 0.12, 0.12), Color(0.2, 0.2, 0.2), 12, 0)
	_coin_box.content_margin_left = 6
	_coin_box.content_margin_right = 6
	coin.add_theme_stylebox_override("panel", _coin_box)
	row.add_child(coin)
	_points = HudKit.label("0", 13, FAINT, HudKit.bold(), 0)
	_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	coin.add_child(_points)
	row.add_child(HudKit.label(tr("Status Points"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))
	head.add_child(_points_box)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	var rules := _attribute_rules()
	head.add_child(HudKit.label(tr("%d per level  ·  up to %d each") % [int(rules.get("points_per_level", 2)), int(rules.get("max", 90))], 12, FAINT, HudKit.body(), 0))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 3)
	page.add_child(spacer)
	for pair in ATTRIBUTES:
		_attribute(page, String(pair[0]), tr(String(pair[1])))

func _attribute(page: VBoxContainer, key: String, caption: String) -> void:
	var box := PanelContainer.new()
	box.name = "Attr_" + key
	box.custom_minimum_size = Vector2(0, 60)
	page.add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var value := HudKit.label("0", 24, HudKit.GOLD_HI, HudKit.title(), 0)
	value.custom_minimum_size.x = 44
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(value)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.add_theme_constant_override("separation", 1)
	row.add_child(mid)
	var top := HBoxContainer.new()
	mid.add_child(top)
	var name_label := HudKit.label(caption, 16, HudKit.GOLD_LT, HudKit.bold(), 0)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_label)
	var total := HudKit.label("", 12, HudKit.GREEN, HudKit.body(), 0)
	top.add_child(total)
	var desc_text := I18n.t(String((_attribute_rules().get("stats", {}) as Dictionary).get(key, {}).get("desc", "")))
	var desc := HudKit.label(desc_text, 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	desc.custom_minimum_size.x = 60
	mid.add_child(desc)
	var bar := FillBar.new(Color(1.0, 0.906, 0.639), Color(0.753, 0.561, 0.216), 5.0)
	mid.add_child(bar)
	var plus := Button.new()
	plus.name = "Plus"
	plus.text = "+"
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(30, 30)
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plus.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	plus.tooltip_text = desc_text
	plus.add_theme_font_override("font", HudKit.body())
	plus.add_theme_font_size_override("font_size", 20)
	for colour_name in ["font_color", "font_hover_color", "font_pressed_color"]:
		plus.add_theme_color_override(colour_name, HudKit.GOLD_HI)
	plus.add_theme_color_override("font_disabled_color", Color("3b465c"))
	var looks := {"normal": Color("5a3e0e"), "hover": Color("8a611a"), "pressed": Color("44300a"), "disabled": Color("0d1320")}
	for state in looks:
		var sb := _box(looks[state], Color("283247") if state == "disabled" else HudKit.GOLD_LT, 4, 0)
		if state != "disabled":
			sb.shadow_color = Color(0.91, 0.78, 0.48, 0.25)
			sb.shadow_size = 4
		plus.add_theme_stylebox_override(state, sb)
	plus.pressed.connect(spend.bind(key))
	row.add_child(plus)
	_attr_cards[key] = {"card": box, "value": value, "total": total, "bar": bar, "plus": plus, "hover": false}
	_style_attr(key, false)

## Ask the server to spend one status point on `key`.
func spend(key: String) -> void:
	if session != null:
		session.spend_attribute(key)
		spends_sent += 1

func _style_attr(key: String, hover: bool) -> void:
	var sb := _box(Color(0.149, 0.212, 0.314, 0.65) if hover else Color(0.09, 0.149, 0.231, 0.55),
			HudKit.GOLD if hover else Color("23324c"), 4, 0)
	sb.content_margin_left = 12
	sb.content_margin_right = 10
	(_attr_cards[key].card as PanelContainer).add_theme_stylebox_override("panel", sb)

## What `points` in attribute `key` add up to: "+24 Health", "+8 Attack  ·  +24 Health".
func _attribute_total(key: String, points: int) -> String:
	if points <= 0:
		return tr("No points yet")
	var gives: Dictionary = (_attribute_rules().get("stats", {}) as Dictionary).get(key, {})
	var words := {
		"max_hp": tr("+%s Health"), "max_mana": tr("+%s Mana"), "attack_value": tr("+%s Attack"),
		"magic_attack": tr("+%s Magic attack"), "attack_speed": tr("+%s%% speed"), "crit_chance": tr("+%s%% critical"),
	}
	var out: Array = []
	for stat in gives:
		if not words.has(stat):
			continue
		var amount := float(gives[stat]) * points
		var shown := str(roundi(amount)) if is_equal_approx(amount, roundf(amount)) else "%.1f" % amount
		out.append(String(words[stat]) % shown)
	return "  ·  ".join(out)

# ------------------------------------------------------------------- window

func toggle() -> void:
	if visible:
		card.close()
	else:
		open()

func open() -> void:
	show()
	card.open()
	_shown = ""
	_refresh()
	_layout()

## Size the card to what it holds (never smaller than it asked for) and centre
## it the first time; afterwards it stays where the player dragged it.
func _layout() -> void:
	var view := get_viewport().get_visible_rect().size
	var need := card._content_margin.get_combined_minimum_size()
	var extent := Vector2(maxf(WANTED.x, need.x), maxf(WANTED.y, need.y))
	var at := Vector2(card.offset_left, card.offset_top)
	if not _placed:
		_placed = true
		at = ((view - extent) * 0.5).floor()
	ArcaneSkin.place(card, at, extent)

## The sheet formats a dozen numbers and compares their text: at most this
## often while the window is open.
const REFRESH_EVERY := 0.1
var _refresh_wait := 0.0

func _process(delta: float) -> void:
	if not visible:
		_refresh_wait = 0.0   # opens current
		return
	_refresh_wait -= delta
	if _refresh_wait <= 0.0:
		_refresh_wait = REFRESH_EVERY
		_refresh()
	_hover_cards()
	if _free_points() > 0:
		_pulse += delta
		_coin_box.shadow_size = int(round(2.0 + 4.0 * (0.5 + 0.5 * sin(_pulse * TAU / 1.8))))

func _free_points() -> int:
	var sheet: Dictionary = session.sheet() if session != null else {}
	return int(sheet.get("attribute_points", 0))

## The attribute card under the pointer lights its border.
func _hover_cards() -> void:
	var over := get_viewport().gui_get_hovered_control()
	var hovered := ""
	while over != null and over != self:
		if over.name.begins_with("Attr_"):
			hovered = over.name.substr(5)
			break
		over = over.get_parent_control()
	for key in _attr_cards:
		var on: bool = key == hovered
		if on != bool(_attr_cards[key].hover):
			_attr_cards[key].hover = on
			_style_attr(key, on)

func _refresh() -> void:
	if session == null or _name == null:
		return
	var sheet: Dictionary = session.sheet()
	if sheet.is_empty():
		return
	var oril_text: Callable = preload("res://scripts/ui/inventory_arcane.gd").oril_text
	var exp_now := int(sheet["exp"])
	var exp_max := maxi(1, int(sheet.get("exp_next", 1)))
	var exp_line := "%s / %s  ·  %.1f%%" % [oril_text.call(exp_now), oril_text.call(exp_max), floorf(1000.0 * exp_now / exp_max) / 10.0]
	var free := int(sheet.get("attribute_points", 0))
	var attributes: Dictionary = sheet.get("attributes", {})
	var key := "%s|%d|%s|%d|%s" % [exp_line, free, str(attributes), int(sheet["level"]), String(sheet["name"])]
	if key == _shown:
		return
	_shown = key
	_exp_text.text = exp_line
	_exp_bar.fraction = float(exp_now) / float(exp_max)
	_medal.level = int(sheet["level"])

	var cap := int(_attribute_rules().get("max", 90))
	_points.text = str(free)
	_points.add_theme_color_override("font_color", Color(0.165, 0.102, 0.016) if free > 0 else FAINT)
	_coin_box.bg_color = Color(0.85, 0.62, 0.22) if free > 0 else Color(0.12, 0.12, 0.12)
	_coin_box.border_color = HudKit.GOLD_HI if free > 0 else Color(0.2, 0.2, 0.2)
	_coin_box.shadow_color = Color(1.0, 0.82, 0.47, 0.55) if free > 0 else Color(0, 0, 0, 0)
	_coin_box.shadow_size = 0
	var capsule := _box(Color(0.035, 0.051, 0.09), HudKit.GOLD_DK if free > 0 else Color("2b3a55"), 13, 0)
	capsule.content_margin_left = 4
	capsule.content_margin_right = 12
	capsule.content_margin_top = 3
	capsule.content_margin_bottom = 3
	_points_box.add_theme_stylebox_override("panel", capsule)
	for id in _attr_cards:
		var entry: Dictionary = _attr_cards[id]
		var points := int(attributes.get(id, 0))
		(entry.value as Label).text = str(points)
		(entry.value as Label).add_theme_color_override("font_color", HudKit.GOLD_HI if points > 0 else HudKit.TEXT_DIM)
		(entry.total as Label).text = _attribute_total(id, points)
		(entry.total as Label).add_theme_color_override("font_color", HudKit.GREEN if points > 0 else FAINT)
		(entry.bar as FillBar).fraction = float(points) / float(maxi(1, cap))
		(entry.plus as Button).disabled = free <= 0 or points >= cap

	_name.text = String(sheet["name"])
	var house := String(sheet["house"])
	var houses: Variant = RealmContent.table("houses")
	var data: Dictionary = (houses as Dictionary).get(house, {}) if houses is Dictionary else {}
	_house.text = I18n.t(String(data.get("name", house.capitalize())))
	_crest.texture = UITheme.icon_for("house_" + house.to_lower())

## The answer to a spend: why nothing changed, on the notice band.
func on_result(event: Dictionary) -> void:
	if bool(event.get("ok", false)):
		AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)
		return
	AudioManager.play_deny()


## A gauge: dark well, two-tone fill with a lit top half.
class FillBar extends Control:
	var top := Color.WHITE
	var bottom := Color.WHITE
	var fraction := 0.0:
		set(value):
			value = clampf(value, 0.0, 1.0)
			if not is_equal_approx(value, fraction):
				fraction = value
				queue_redraw()

	func _init(p_top: Color, p_bottom: Color, height: float) -> void:
		top = p_top
		bottom = p_bottom
		custom_minimum_size = Vector2(0, height)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, CharacterWindow.WELL)
		if fraction > 0.0:
			var fill := Rect2(Vector2(1, 1), Vector2(maxf(2.0, (size.x - 2.0) * fraction), size.y - 2.0))
			draw_rect(fill, bottom)
			draw_rect(Rect2(fill.position, Vector2(fill.size.x, fill.size.y * 0.45)), top.lerp(bottom, 0.25))
		draw_rect(r, CharacterWindow.WELL_EDGE, false, 1.0)


## The round level medallion in the header.
class LevelMedal extends Control:
	var caption := ""
	var level := 0:
		set(value):
			if value != level:
				level = value
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(60, 60)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.0
		draw_circle(c, r + 1.0, Color(0.91, 0.78, 0.48, 0.15))
		draw_circle(c, r, HudKit.GOLD)
		draw_circle(c, r - 2.0, Color("0b1120"))
		draw_circle(c, r - 4.0, Color("1a2338"))
		var small := HudKit.body()
		var cw := small.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		draw_string(small, Vector2(c.x - cw * 0.5, c.y - 9.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, HudKit.TEXT_DIM)
		var big := HudKit.title()
		var txt := str(level)
		var tw := big.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_string(big, Vector2(c.x - tw * 0.5, c.y + 15.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, HudKit.GOLD_HI)
