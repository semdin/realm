extends Control

## The in-game HUD: the unit frame with the health and mana gauges (top-left),
## the target card (top centre), the action bar with the bag on one taskbar
## plate and the experience band along the bottom edge, and the notice band;
## the unit frame also carries the house standing, and a rank-up is a notice.
## The social pieces live here too: the chat log bottom-left (HudChat), the
## party frames under the unit frame (HudParty), the local player's duel
## (HudDuel: countdown, plaque, arena, result), and over every window the
## invitation cards and duel challenges (HudInvites) and the right-click
## player menu (HudPlayerMenu).
## Windows find this node as their sibling "HUD" and call `show_notice`.
##
## It only draws: health and mana come from the newest snapshot
## (RealmSession.vitals), name, level, experience and purse from the character
## sheet (PlayerSheet; the experience a level takes is the sheet's
## `exp_next`), the target's health from the snapshot hp byte or, when
## a hit lands, from the hit itself. Another player on the target card (one
## whose name the client knows) offers "Invite to Party", which sends the same
## `/invite Name` the chat takes; the server's own reply says it was sent.

const NoticeScript := "res://scripts/view/notice_band.gd"

## The taskbar (the old game's): after the spells and the quick slots, the bag
## as a full action-bar cell, then the window buttons as a block of small
## cells (MICRO_COLUMNS x 2, as tall together as one slot), each set off by a
## divider. A button that wants attention pulses gold: Character with status
## points to spend, Skills with skill points (and their count), Quests with
## a quest ready to hand in.
const TRAY_DIVIDER := 14.0
const MICRO_CELL := 24.0
const MICRO_GAP := 2.0
const MICRO_COLUMNS := 4
## The window buttons in order: [id, icon, the GameSettings action whose key
## it names (Escape for the menu), tooltip].
# i18n-begin
const MENU_BUTTONS := [
	["workshop", "menu_kestrin", "workshop", "Kestrin - forge the wand higher"],
	["quests", "menu_quests", "quest_log", "Quests - every open quest and reward"],
	["character", "menu_character", "character", "Character - stats and status points"],
	["skills", "menu_skills", "skills", "Skills - spend skill points on your spells"],
	["map", "menu_map", "world_map", "World map"],
	["bestiary", "menu_bestiary", "bestiary", "Bestiary - where every creature lives"],
	["dungeons", "dungeon_seal", "dungeon_guide", "Dungeons - difficulties, records and the way to each gate"],
	["menu", "menu_settings", "", "Menu - settings, change character, quit"],
]
# i18n-end
const TARGET_CARD_H := 74.0
## The target card's name colour for an ordinary creature, and its health
## gauge's.
const TARGET_TINT := Color(1.0, 0.86, 0.80)
const TARGET_BAR := Color(0.80, 0.09, 0.08)
## A hit's hp byte stands this long before the (older) interpolated snapshot
## may raise the target card's bar again.
const HIT_HOLD_SECONDS := 0.5
const ChatScript := "res://scripts/ui/hud_chat.gd"
const PartyScript := "res://scripts/ui/hud_party.gd"
const InvitesScript := "res://scripts/ui/hud_invites.gd"
const PlayerMenuScript := "res://scripts/ui/hud_player_menu.gd"
const DuelScript := "res://scripts/ui/hud_duel.gd"

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
## The window buttons on the taskbar by id (MENU_BUTTONS); main.gd connects
## them. `skills_button` is the skill window's (V).
var menu_buttons: Dictionary = {}
var skills_button: Button
var _skill_badge: PointsBadge
var _menu_grid: GridContainer
## The timed effects under the unit frame (HudBuffBar).
var buff_bar: HudBuffBar
## Whether a quest is ready to hand in (main.gd sets it: QuestManager).
var quests_ready: Callable
var target_panel: Panel
var target_name: Label
var target_rank: Label
var target_level: Label
var target_hp_bar: ProgressBar
var target_hp_text: Label
var target_portrait: TargetPortrait
## A game admin on the target card: the GA emblem after the name.
var target_ga: TextureRect
var chat: HudChat
var party_frames: HudParty
var invites: HudInvites
var player_menu: HudPlayerMenu
var duel_view: HudDuel
## The travel windows (MapTravel builds them beside the HUD): the Hearth
## window, and the Waylink picker the bag opens on an Old Boot.
var hearthway: Control
var waylink: Control
## The target card's "Invite to Party" (another player not in the party), and
## the name it invites.
var invite_button: Button
var _invite_name := ""
## The entity the target card shows (0 = none).
var target_id := 0
var _status: VBoxContainer
var _hp_stat: StatBar
var _mana_stat: StatBar
var _exp_stat: StatBar
var _target_stat: StatBar
var _target_flow: GaugeFlow
var _hit_hold_until := 0.0
## The house rank last shown; 0 until the first sheet, so a load is not a
## rank-up.
var _house_rank := 0

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
	buff_bar = HudBuffBar.new()
	buff_bar.session = session
	buff_bar.sheet = sheet
	add_child(buff_bar)
	_build_tray(open_bag)
	_build_target_card()
	_build_social()
	# The notice band draws above every window (the bag, the workshop, the
	# log): a window left open must not hide what just happened.
	var notice_layer := CanvasLayer.new()
	notice_layer.name = "NoticeLayer"
	notice_layer.layer = 6
	add_child(notice_layer)
	notices = load(NoticeScript).new()
	notices.name = "Notices"
	notice_layer.add_child(notices)
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
	bag_button.pressed.connect(open_bag)
	_style_menu_cell(bag_button, "menu_inventory", HudActionBar.SLOT)
	add_child(bag_button)
	_menu_grid = GridContainer.new()
	_menu_grid.name = "MenuButtons"
	_menu_grid.columns = MICRO_COLUMNS
	_menu_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_grid.add_theme_constant_override("h_separation", int(MICRO_GAP))
	_menu_grid.add_theme_constant_override("v_separation", int(MICRO_GAP))
	add_child(_menu_grid)
	for entry: Array in MENU_BUTTONS:
		var button := Button.new()
		button.name = String(entry[0]).capitalize().replace(" ", "") + "Button"
		button.focus_mode = Control.FOCUS_NONE
		_style_menu_cell(button, String(entry[1]), MICRO_CELL)
		_menu_grid.add_child(button)
		menu_buttons[String(entry[0])] = button
	skills_button = menu_buttons["skills"]
	_skill_badge = PointsBadge.new()
	_skill_badge.name = "PointsBadge"
	skills_button.add_child(_skill_badge)
	_skill_badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	refresh_menu_tips()
	GameSettings.instance().changed.connect(_on_settings_changed)

func _on_settings_changed(_what: String) -> void:
	refresh_menu_tips()

## Each window button's tooltip names its key as it is bound now.
func refresh_menu_tips() -> void:
	for entry: Array in MENU_BUTTONS:
		var key := "Esc" if String(entry[2]) == "" else GameSettings.key_name(String(entry[2]))
		(menu_buttons[String(entry[0])] as Button).tooltip_text = "[%s] %s" % [key, tr(String(entry[3]))]
	bag_button.tooltip_text = tr("[%s] Bag - the potions you carry") % GameSettings.key_name("inventory")

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

## ------------------------------------------------------------------ social

## The chat log and the party frames on the HUD; the invitation cards and the
## player menu on their own layer above every window (an open bag must not
## hide an invitation).
func _build_social() -> void:
	chat = load(ChatScript).new()
	chat.session = session
	add_child(chat)
	chat.focus_changed.connect(func(_open: bool): _layout())
	chat.add_system_line(tr("Party: /invite Name, /leave, /p text for party chat."))
	chat.add_system_line(tr("Duel: right-click a player, or /duel Name (/gduel Name for parties, /yield to give up)."))
	party_frames = load(PartyScript).new()
	add_child(party_frames)
	duel_view = load(DuelScript).new()
	duel_view.session = session
	duel_view.chat_sink = chat.add_system_line
	add_child(duel_view)
	var popups := CanvasLayer.new()
	popups.name = "PopupLayer"
	popups.layer = 6
	add_child(popups)
	invites = load(InvitesScript).new()
	invites.session = session
	popups.add_child(invites)
	player_menu = load(PlayerMenuScript).new()
	player_menu.session = session
	player_menu.party_frames = party_frames
	player_menu.duel_view = duel_view
	popups.add_child(player_menu)

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
	target_name = HudKit.label("", 17, TARGET_TINT, HudKit.title(), 4)
	target_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	target_name.set_anchors_preset(Control.PRESET_TOP_WIDE)
	target_name.offset_left = left
	target_name.offset_right = -70
	target_name.offset_top = 6
	target_name.offset_bottom = 28
	target_name.clip_text = true
	target_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	target_panel.add_child(target_name)
	target_ga = TextureRect.new()
	target_ga.name = "TargetGA"
	target_ga.texture = HudUnitFrame.ga_icon(24)
	target_ga.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_ga.visible = false
	target_panel.add_child(target_ga)
	target_level =HudKit.label("", 13, HudKit.PARCHMENT, HudKit.bold(), 3)
	target_level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	target_level.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	target_level.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	target_level.offset_left = -68
	target_level.offset_right = -12
	target_level.offset_top = 6
	target_level.offset_bottom = 28
	target_panel.add_child(target_level)
	target_rank = HudKit.label(I18n.upper(tr("Creature")), 11, Color(1.0, 0.86, 0.80).darkened(0.12), HudKit.bold(), 2)
	target_rank.set_anchors_preset(Control.PRESET_TOP_WIDE)
	target_rank.offset_left = left + 1
	target_rank.offset_right = -40
	target_rank.offset_top = 27
	target_rank.offset_bottom = 41
	target_panel.add_child(target_rank)
	target_hp_bar = _gauge(Color(0.86, 0.13, 0.11), TARGET_BAR, 1.0)
	target_hp_bar.max_value = 255
	_target_flow = GaugeFlow.attach(target_hp_bar, TARGET_BAR)
	target_hp_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	target_hp_bar.offset_left = left
	target_hp_bar.offset_right = -12
	target_hp_bar.offset_top = -27
	target_hp_bar.offset_bottom = -9
	target_panel.add_child(target_hp_bar)
	_target_stat = StatBar.new().attach(self, target_hp_bar)
	target_hp_text = _gauge_label(target_hp_bar, 12, Color(1, 1, 1))
	invite_button = HudKit.button(tr("Invite to Party"), 13)
	invite_button.name = "InviteToParty"
	invite_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	invite_button.offset_left = -150
	invite_button.offset_right = -8
	invite_button.offset_top = 6
	invite_button.offset_bottom = 34
	invite_button.visible = false
	invite_button.pressed.connect(_on_invite_pressed)
	target_panel.add_child(invite_button)

## The target card's invitation: the chat command, nothing more (the server
## answers with "Party invitation sent to ..." or why not).
func _on_invite_pressed() -> void:
	if _invite_name == "":
		return
	session.send_chat("/invite %s" % _invite_name)
	invite_button.visible = false

## Show `id` (a creature named `title`, at hp byte `hp`) on the card, or hide
## it (id 0). `look` says what kind of target it is (main.gd target_look):
## `rank` (the line under the name), `level` (0: none), `tint` (the name and
## rank), `bar` (the gauge) and `icon` (the portrait: a crown for a world boss,
## the enraged eye, the shard for a Dark Shard); `invite`, another player's
## name, shows "Invite to Party".
func set_target(id: int, title := "", hp := 255, look := {}) -> void:
	var changed := id != target_id
	target_id = id
	target_panel.visible = id != 0
	_invite_name = String(look.get("invite", "")) if id != 0 else ""
	invite_button.visible = _invite_name != ""
	if id == 0:
		return
	var tint: Color = look.get("tint", TARGET_TINT)
	var bar: Color = look.get("bar", TARGET_BAR)
	target_name.text = title
	target_name.add_theme_color_override("font_color", tint)
	target_ga.visible = bool(look.get("ga", false)) and target_ga.texture != null
	target_name.offset_right = -70.0
	if target_ga.visible:
		var mark := target_ga.texture.get_size()
		var room := target_panel.size.x - target_name.offset_left - 70.0 - mark.x - 6.0
		var name_w := minf(room, HudKit.title().get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x)
		target_name.offset_right = -70.0 - mark.x - 6.0
		target_ga.position = Vector2(target_name.offset_left + name_w + 6.0, 5.0)
		target_ga.size = mark
	target_rank.text = I18n.upper(String(look.get("rank", tr("Creature"))))
	target_rank.add_theme_color_override("font_color", tint.darkened(0.12))
	var level := int(look.get("level", 0))
	target_level.text = (tr("Lv. %d") % level) if level > 0 else ""
	_target_flow.set_colour(bar)
	target_portrait.set_look(UITheme.chrome(String(look.get("icon", "ui_target"))), bar.lerp(tint, 0.35))
	if changed:
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
	target_hp_text.text = tr("%s%%") % (I18n.num(pct) if pct < 10.0 and pct > 0.0 else str(roundi(pct)))

## ------------------------------------------------------------------ update

## Free skill points: the skill book's cell pulses and shows the count.
var _points_wait := 0.0
var _pulse := 0.0

## What wants attention by button id, asked four times a second.
var _wants: Dictionary = {}

func _show_skill_points(delta: float) -> void:
	_points_wait -= delta
	if _points_wait <= 0.0:
		_points_wait = 0.25
		_skill_badge.points = int(session.skill_points())
		var data := _sheet_data()
		_wants = {
			"skills": _skill_badge.points > 0,
			"character": int(data.get("attribute_points", 0)) > 0,
			"quests": quests_ready.is_valid() and bool(quests_ready.call()),
		}
	_pulse += delta
	var glow := 0.5 + 0.5 * sin(_pulse * 5.0)
	for id: String in _wants:
		var button: Button = menu_buttons[id]
		var on: bool = _wants[id]
		if not on and not bool(button.get_meta("pulsing", true)):
			continue
		button.set_meta("pulsing", on)
		button.self_modulate = Color.WHITE.lerp(Color(1.6, 1.3, 0.55), glow * 0.6) if on else Color.WHITE
		var sb := button.get_theme_stylebox("normal") as StyleBoxFlat
		if sb != null:
			sb.border_color = Color(HudKit.GOLD_HI, 0.4 + 0.6 * glow) if on else HudKit.GOLD.darkened(0.15)
			sb.set_border_width_all(2 if on else 1)

## The sheet as the PlayerSheet last read it: session.sheet() builds the whole
## sheet (bag, quest log) anew on every call, 40-150 us, and this ran it each
## frame although it only changes with a new revision.
func _sheet_data() -> Dictionary:
	return sheet.data if sheet != null else session.sheet()

func _process(delta: float) -> void:
	if session == null:
		return
	_show_skill_points(delta)
	var vitals: PackedInt32Array = session.vitals()
	if vitals[1] > 0:
		_hp_stat.set_value(vitals[0], vitals[1])
		hp_label.text = "%d / %d" % [vitals[0], vitals[1]]
		_mana_stat.set_value(vitals[2], vitals[3])
		mana_label.text = "%d / %d" % [vitals[2], vitals[3]]
	var data := _sheet_data()
	if data.is_empty():
		return
	var level := int(data["level"])
	var earned := int(data["exp"])
	var needed := maxi(1, int(data.get("exp_next", 1)))
	_exp_stat.set_value(earned, needed)
	# Rounded down: 7347 / 7350 is 99.9 %, never a full bar that has not levelled.
	var pct := floorf(float(earned) / maxf(1.0, float(needed)) * 1000.0) / 10.0
	exp_label.text = tr("Level %d   ·   %s / %s EXP   ·   %s%%") % [level, I18n.whole(earned), I18n.whole(needed), I18n.num(pct)]
	unit_frame.set_identity(String(data["name"]), String(data["house"]), level)
	unit_frame.set_oril(int(data["oril"]))
	_apply_house_standing(data)

## House standing (quest reputation): the unit frame shows rank and progress, a
## rise past a threshold gets a notice and the level-up chime.
func _apply_house_standing(data: Dictionary) -> void:
	if not data.has("house_rank"):
		return
	var rank := int(data["house_rank"])
	var title := String(data.get("house_title", ""))
	unit_frame.set_house_standing(rank, title, int(data.get("house_rep", 0)), int(data.get("rank_from", 0)),
		int(data.get("rank_to", -1)))
	if _house_rank > 0 and rank > _house_rank:
		show_notice(tr("%s Rank %d · %s") % [HudQuestScroll.house_name(String(data["house"])), rank, I18n.t(title)], "good")
		AudioManager.play_levelup()
	_house_rank = rank

## ------------------------------------------------------------------ layout

## Everything placed for the current canvas: unit frame and gauges top-left,
## the target card top centre, the taskbar centred on the spells above the
## experience band (sliding left near the right edge), the chat bottom-left
## (taller while it is open).
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
	# Buffs under the unit frame (the old game's place).
	buff_bar.position = unit_frame.position + Vector2(HudUnitFrame.MEDALLION + 14, 112)
	var slot := HudActionBar.SLOT
	var bw := action_bar.bar_width()
	var micro_w := MICRO_COLUMNS * MICRO_CELL + (MICRO_COLUMNS - 1) * MICRO_GAP
	var micro_h := 2.0 * MICRO_CELL + MICRO_GAP
	var extra := TRAY_DIVIDER + slot + TRAY_DIVIDER + micro_w
	var bar_y := -14.0 - 12.0 - slot
	var left := minf(-bw * 0.5, canvas.x * 0.5 - 14.0 - HudActionBar.PLATE_PAD - bw - extra)
	_place(action_bar, Vector2(0.5, 1.0), Vector2(left, bar_y), Vector2(bw, slot))
	action_bar.tray_extra = extra
	action_bar.tray_dividers = [bw + TRAY_DIVIDER * 0.5, bw + TRAY_DIVIDER * 1.5 + slot]
	action_bar.queue_redraw()
	_place(bag_button, Vector2(0.5, 1.0), Vector2(left + bw + TRAY_DIVIDER, bar_y), Vector2(slot, slot))
	_place(_menu_grid, Vector2(0.5, 1.0), Vector2(left + bw + TRAY_DIVIDER * 2.0 + slot, bar_y + (slot - micro_h) * 0.5),
		Vector2(micro_w, micro_h))
	# Chat, bottom-left; it stands on the taskbar when the two would meet.
	var tray_top := 14.0 + 12.0 + slot + HudActionBar.PLATE_TOP
	var tray_left := canvas.x * 0.5 + left - HudActionBar.PLATE_PAD
	var chat_w := 280.0 if compact else 360.0
	var chat_h := (170.0 if compact else 240.0) if chat.is_open() else (110.0 if compact else 170.0)
	var chat_bottom := 14.0 + 14.0
	if tray_left < 12.0 + chat_w + 8.0:
		chat_bottom = tray_top + 8.0
	_place(chat, Vector2(0.0, 1.0), Vector2(12, -chat_bottom - chat_h), Vector2(chat_w, chat_h))
	var card_w := 300.0 if compact else 360.0
	_place(target_panel, Vector2(0.5, 0.0), Vector2(-card_w * 0.5, 10), Vector2(card_w, TARGET_CARD_H))

## Where the taskbar stands on the canvas (a tall window beside it keeps clear).
func tray_rect() -> Rect2:
	var bar := action_bar.get_global_rect()
	var end := _menu_grid.get_global_rect().end
	var top := bar.position.y - HudActionBar.PLATE_TOP
	return Rect2(bar.position.x - HudActionBar.PLATE_PAD, top, end.x + HudActionBar.PLATE_PAD - bar.position.x, bar.end.y - top)

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


## The free skill points on the skill book's cell: a gold coin with the count
## in its top-right corner, none while there are none.
class PointsBadge extends Control:
	var points := 0:
		set(value):
			if value != points:
				points = value
				queue_redraw()
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		if points <= 0:
			return
		var text := str(points)
		var font := HudKit.bold()
		# smaller on a small cell (the taskbar's window buttons)
		var fs := 12 if size.x >= 40.0 else 10
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var r := 9.0 if size.x >= 40.0 else 7.0
		var box := Rect2(Vector2(size.x - maxf(r * 2.0, w + 6.0) + 4.0, -5.0), Vector2(maxf(r * 2.0, w + 6.0), r * 2.0))
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.85, 0.62, 0.22)
		sb.border_color = HudKit.GOLD_HI
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(int(r))
		sb.shadow_color = Color(0, 0, 0, 0.6)
		sb.shadow_size = 3
		draw_style_box(sb, box)
		draw_string(font, Vector2(box.position.x + (box.size.x - w) * 0.5, box.position.y + r + fs * 0.38), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.165, 0.102, 0.016))
