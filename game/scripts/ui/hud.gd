extends Control

## The in-game HUD: the unit frame with the health and mana gauges (top-left),
## the target card (top centre), the action bar with the bag on one taskbar
## plate and the experience band along the bottom edge, and the notice band.
## Windows find this node as their sibling "HUD" and call `show_notice`.
##
## It only draws: health and mana come from the newest snapshot
## (RealmSession.vitals), name, level, experience and purse from the character
## sheet (PlayerSheet), the target's health from the snapshot hp byte or, when
## a hit lands, from the hit itself.

const NoticeScript := "res://scripts/view/notice_band.gd"

## The taskbar: the bag as a full action-bar cell after the quick slots, set off
## by a divider.
const TRAY_DIVIDER := 14.0
const TARGET_CARD_H := 74.0
## A hit's hp byte stands this long before the (older) interpolated snapshot
## may raise the target card's bar again.
const HIT_HOLD_SECONDS := 0.5

var session: Node
var sheet: PlayerSheet
var unit_frame: HudUnitFrame
var action_bar: HudActionBar
var notices: Control
var hp_bar: ProgressBar
var hp_label: Label
var mana_bar: ProgressBar
var mana_label: Label
var exp_bar: ProgressBar
var exp_label: Label
var bag_button: Button
var target_panel: Panel
var target_name: Label
var target_rank: Label
var target_hp_bar: ProgressBar
var target_hp_text: Label
var target_portrait: TargetPortrait
## The entity the target card shows (0 = none).
var target_id := 0
var _status: VBoxContainer
var _hp_stat: StatBar
var _mana_stat: StatBar
var _exp_stat: StatBar
var _target_stat: StatBar
var _hit_hold_until := 0.0
## The level last shown; a rise plays the level-up sound.
var _shown_level := 0

func _init() -> void:
	name = "HUD"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## `open_bag` toggles the inventory (the bag button).
func setup(realm_session: Node, player_sheet: PlayerSheet, open_bag: Callable) -> void:
	session = realm_session
	sheet = player_sheet
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	unit_frame = HudUnitFrame.new()
	add_child(unit_frame)
	_build_gauges()
	_build_tray(open_bag)
	_build_target_card()
	notices = load(NoticeScript).new()
	notices.name = "Notices"
	add_child(notices)
	get_viewport().size_changed.connect(_layout)
	_layout()

func show_notice(text: String, kind := "info") -> void:
	notices.show_notice(text, kind)

## ------------------------------------------------------------------ gauges

func _gauge(colour: Color, flow_colour: Color, flow_speed: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 18)
	HudKit.style_gauge(bar, colour)
	GaugeFlow.attach(bar, flow_colour, flow_speed)
	return bar

## The bar's numbers, centred and above the lag band StatBar adds.
func _gauge_label(bar: ProgressBar, font_size: int, colour: Color) -> Label:
	var label := HudKit.label("", font_size, colour, HudKit.bold(), 3)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(label)
	return label

func _build_gauges() -> void:
	_status = VBoxContainer.new()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.add_theme_constant_override("separation", 4)
	add_child(_status)
	hp_bar = _gauge(Color(0.86, 0.13, 0.11), Color(0.80, 0.09, 0.08), 1.0)
	mana_bar = _gauge(Color(0.18, 0.42, 0.92), Color(0.12, 0.36, 0.92), 0.9)
	_status.add_child(hp_bar)
	_status.add_child(mana_bar)
	_hp_stat = StatBar.new().attach(self, hp_bar)
	_mana_stat = StatBar.new().attach(self, mana_bar)
	hp_label = _gauge_label(hp_bar, 13, Color(1, 1, 1))
	mana_label = _gauge_label(mana_bar, 13, Color(1, 1, 1))
	# EXP across the bottom edge, with ten segment ticks.
	exp_bar = _gauge(Color(0.90, 0.66, 0.16), Color(0.86, 0.60, 0.12), 0.45)
	add_child(exp_bar)
	_exp_stat = StatBar.new().attach(self, exp_bar)
	var ticks := ExpTicks.new()
	ticks.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	exp_bar.add_child(ticks)
	exp_bar.move_child(ticks, 0)
	exp_label = _gauge_label(exp_bar, 11, HudKit.PARCHMENT)

## ----------------------------------------------------------------- taskbar

func _build_tray(open_bag: Callable) -> void:
	action_bar = HudActionBar.new()
	add_child(action_bar)
	action_bar.bind(self, session, sheet)
	bag_button = Button.new()
	bag_button.name = "BagButton"
	bag_button.focus_mode = Control.FOCUS_NONE
	bag_button.tooltip_text = tr("[I] Bag - the potions you carry")
	bag_button.pressed.connect(open_bag)
	_style_menu_cell(bag_button, "menu_inventory", HudActionBar.SLOT)
	add_child(bag_button)

## A taskbar button as an action-bar cell `px` wide: dark recess, a thin gold
## bevel that lights on hover, and the full-bleed icon inside it.
func _style_menu_cell(button: Button, icon_id: String, px: float) -> void:
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.custom_minimum_size = Vector2(px, px)
	button.icon = UITheme.chrome_at(icon_id, 128.0)
	var inset := 2 if px < 30.0 else 3
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.031, 0.039, 0.058, 0.95)
		sb.set_border_width_all(1)
		sb.border_color = HudKit.GOLD.darkened(0.15)
		sb.set_corner_radius_all(3)
		sb.set_content_margin_all(inset)
		sb.shadow_color = Color(0, 0, 0, 0.55)
		sb.shadow_size = 3
		match state:
			"hover":
				sb.border_color = HudKit.GOLD_HI
				sb.set_border_width_all(2)
			"pressed":
				sb.border_color = HudKit.GOLD_LT
				sb.set_content_margin_all(inset + 1)
			"focus":
				sb.draw_center = false
				sb.border_color = Color(0, 0, 0, 0)
		button.add_theme_stylebox_override(state, sb)
	button.add_theme_color_override("icon_hover_color", Color(1.12, 1.08, 0.98))
	button.add_theme_color_override("icon_pressed_color", Color(0.85, 0.85, 0.85))

## ------------------------------------------------------------- target card

## The target card: a round portrait on the left; the name and the rank line;
## and a wide health gauge with the percentage in it.
func _build_target_card() -> void:
	target_panel = Panel.new()
	target_panel.name = "TargetPanel"
	target_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := HudKit.panel(0.9, 8).duplicate() as StyleBoxFlat
	sb.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.9)
	sb.border_width_bottom = 2
	target_panel.add_theme_stylebox_override("panel", sb)
	target_panel.hide()
	add_child(target_panel)
	target_portrait = TargetPortrait.new()
	target_portrait.position = Vector2(-12, (TARGET_CARD_H - 66.0) * 0.5)
	target_portrait.size = Vector2(66, 66)
	target_portrait.set_look(UITheme.chrome("ui_target"), Color(0.80, 0.09, 0.08).lerp(Color(1.0, 0.86, 0.80), 0.35))
	target_panel.add_child(target_portrait)
	var left := 64.0
	target_name = HudKit.label("", 17, Color(1.0, 0.86, 0.80), HudKit.title(), 4)
	target_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	target_name.set_anchors_preset(Control.PRESET_TOP_WIDE)
	target_name.offset_left = left
	target_name.offset_right = -70
	target_name.offset_top = 6
	target_name.offset_bottom = 28
	target_name.clip_text = true
	target_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	target_panel.add_child(target_name)
	target_rank = HudKit.label(I18n.upper(tr("Creature")), 11, Color(1.0, 0.86, 0.80).darkened(0.12), HudKit.bold(), 2)
	target_rank.set_anchors_preset(Control.PRESET_TOP_WIDE)
	target_rank.offset_left = left + 1
	target_rank.offset_right = -40
	target_rank.offset_top = 27
	target_rank.offset_bottom = 41
	target_panel.add_child(target_rank)
	target_hp_bar = _gauge(Color(0.86, 0.13, 0.11), Color(0.80, 0.09, 0.08), 1.0)
	target_hp_bar.max_value = 255
	target_hp_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	target_hp_bar.offset_left = left
	target_hp_bar.offset_right = -12
	target_hp_bar.offset_top = -27
	target_hp_bar.offset_bottom = -9
	target_panel.add_child(target_hp_bar)
	_target_stat = StatBar.new().attach(self, target_hp_bar)
	target_hp_text = _gauge_label(target_hp_bar, 12, Color(1, 1, 1))

## Show `id` (a creature named `title`, at hp byte `hp`) on the card, or hide
## it (id 0).
func set_target(id: int, title := "", hp := 255) -> void:
	target_id = id
	target_panel.visible = id != 0
	if id == 0:
		return
	target_name.text = title
	_hit_hold_until = 0.0
	_show_target_health(hp)
	_target_stat.snap()

## The snapshot's hp byte (0..255) for the target, every frame.
func set_target_health(hp: int) -> void:
	if Time.get_ticks_msec() / 1000.0 < _hit_hold_until and hp > int(target_hp_bar.value):
		return
	_show_target_health(hp)

## A hit carries the target's hp byte after it: shown at once.
func on_hit(event: Dictionary) -> void:
	if target_id != 0 and int(event.get("target", 0)) == target_id:
		_hit_hold_until = Time.get_ticks_msec() / 1000.0 + HIT_HOLD_SECONDS
		_show_target_health(int(event.get("hp", 0)))

func _show_target_health(hp: int) -> void:
	_target_stat.set_value(hp, 255)
	var pct := 100.0 * float(hp) / 255.0
	target_hp_text.text = ("%.1f%%" % pct) if pct < 10.0 and pct > 0.0 else "%d%%" % int(round(pct))

## ------------------------------------------------------------------ update

func _process(_delta: float) -> void:
	if session == null:
		return
	var vitals: PackedInt32Array = session.vitals()
	if vitals[1] > 0:
		_hp_stat.set_value(vitals[0], vitals[1])
		hp_label.text = "%d / %d" % [vitals[0], vitals[1]]
		_mana_stat.set_value(vitals[2], vitals[3])
		mana_label.text = "%d / %d" % [vitals[2], vitals[3]]
	var data: Dictionary = session.sheet()
	if data.is_empty():
		return
	var level := int(data["level"])
	if _shown_level > 0 and level > _shown_level:
		AudioManager.play_levelup()
	_shown_level = level
	var earned := int(data["exp"])
	var needed := Levels.exp_threshold(level)
	_exp_stat.set_value(earned, needed)
	# Rounded down: 7347 / 7350 is 99.9 %, never a full bar that has not levelled.
	var pct := floorf(float(earned) / maxf(1.0, float(needed)) * 1000.0) / 10.0
	exp_label.text = tr("Level %d   ·   %d / %d EXP   ·   %.1f%%") % [level, earned, needed, pct]
	unit_frame.set_identity(String(data["name"]), String(data["house"]), level)
	unit_frame.set_oril(int(data["oril"]))

## ------------------------------------------------------------------ layout

## Everything placed for the current canvas: unit frame and gauges top-left,
## the target card top centre, the taskbar centred on the spells above the
## experience band (sliding left near the right edge).
func _layout() -> void:
	var canvas := get_viewport().get_visible_rect().size
	var compact := canvas.x < 1000 or canvas.y < 560
	unit_frame.position = Vector2(12, 8)
	var gauges := unit_frame.gauge_rect()
	_place(_status, Vector2(0, 0), unit_frame.position + gauges.position, Vector2(gauges.size.x, 40))
	exp_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	exp_bar.offset_left = 0
	exp_bar.offset_right = 0
	exp_bar.offset_top = -14
	exp_bar.offset_bottom = 0
	exp_bar.custom_minimum_size = Vector2(0, 14)
	var slot := HudActionBar.SLOT
	var bw := action_bar.bar_width()
	var extra := TRAY_DIVIDER + slot
	var bar_y := -14.0 - 12.0 - slot
	var left := minf(-bw * 0.5, canvas.x * 0.5 - 14.0 - HudActionBar.PLATE_PAD - bw - extra)
	_place(action_bar, Vector2(0.5, 1.0), Vector2(left, bar_y), Vector2(bw, slot))
	action_bar.tray_extra = extra
	action_bar.tray_dividers = [bw + TRAY_DIVIDER * 0.5]
	action_bar.queue_redraw()
	_place(bag_button, Vector2(0.5, 1.0), Vector2(left + bw + TRAY_DIVIDER, bar_y), Vector2(slot, slot))
	var card_w := 300.0 if compact else 360.0
	_place(target_panel, Vector2(0.5, 0.0), Vector2(-card_w * 0.5, 10), Vector2(card_w, TARGET_CARD_H))

## Pin `control` to the anchor point `anchor` (0..1 of the canvas) at `offset`
## with `extent`.
static func _place(control: Control, anchor: Vector2, offset: Vector2, extent: Vector2) -> void:
	control.anchor_left = anchor.x
	control.anchor_right = anchor.x
	control.anchor_top = anchor.y
	control.anchor_bottom = anchor.y
	control.offset_left = offset.x
	control.offset_top = offset.y
	control.offset_right = offset.x + extent.x
	control.offset_bottom = offset.y + extent.y


## The target card's portrait: a dark disc, the target's icon and a ring in the
## target's colour, hanging over the card's left edge like the unit frame's.
class TargetPortrait extends Control:
	var icon: Texture2D = null
	var ring := HudKit.GOLD
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func set_look(p_icon: Texture2D, p_ring: Color) -> void:
		if p_icon != icon or p_ring != ring:
			icon = p_icon
			ring = p_ring
			queue_redraw()
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c + Vector2(0, 2), r, Color(0, 0, 0, 0.45))
		draw_circle(c, r - 1, Color(0.024, 0.031, 0.051, 1.0))
		draw_circle(c, r - 5, Color(0.07, 0.085, 0.13, 1.0))
		if icon != null:
			var s := (r - 7) * 2.0 * 0.86
			draw_texture_rect(icon, Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false)
		draw_arc(c, r - 2.5, 0, TAU, 64, HudKit.GOLD_DK, 4.0, true)
		draw_arc(c, r - 2.5, 0, TAU, 64, Color(ring.r, ring.g, ring.b, 0.95), 2.0, true)
		draw_arc(c, r - 5.5, PI * 1.1, PI * 1.9, 24, Color(1, 1, 1, 0.18), 1.5, true)


## Ten segment ticks over the experience bar, the MMO way of reading progress.
class ExpTicks extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		for i in range(1, 10):
			var x := floorf(size.x * float(i) / 10.0)
			draw_line(Vector2(x, 2), Vector2(x, size.y - 1), Color(0, 0, 0, 0.55), 2.0)
			draw_line(Vector2(x + 1, 2), Vector2(x + 1, size.y - 1), Color(1, 0.9, 0.6, 0.18), 1.0)
		draw_line(Vector2(0, 0.5), Vector2(size.x, 0.5), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.8), 1.0)
