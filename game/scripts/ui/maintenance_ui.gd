extends CanvasLayer
class_name MaintenanceUI

## The realm's maintenance as the player sees it (the old game's
## MaintenanceUI): a countdown banner under the notice band while the realm
## announces a maintenance, and the screen that says why the game stopped when
## the connection closes or a join is refused.
##
## The coordinator's cycle arrives as RealmSession.take_notices() dicts
## (`kind` "maintenance"; main.gd hands them to `on_notice`): `state`
## ANNOUNCING / DRAINING with `seconds` left (re-announced every 10 s, every
## 3 s in the last 15 s; the banner counts down locally between), SAVING (the
## world stands still while every character is saved), DISCONNECTING (the
## connection closes next), MAINTENANCE, FAILED (a held cycle: still
## connected, the world frozen) and ONLINE (called off: the banner goes, the
## notice band says so). The terminal states latch, so the reason stays on
## screen after the transport drops.
##
## `show_closed(status)` turns the session's "refused: ..." / "closed: ..."
## status into the end screen: the realm's emblem, a card in the arcane frame
## with what happened (a maintenance refusal, a logout for maintenance, a lost
## connection) and Reconnect (the scene joins again) / Quit Game.

const ACTIVE_STATES := ["ANNOUNCING", "DRAINING", "SAVING", "DISCONNECTING", "MAINTENANCE", "FAILED"]
const CLOSED_STATES := ["ONLINE", "ABORTED"]
const BANNER_SIZE := Vector2(660, 74)
## Under the target card (top 10 + 74) and the notice band's line (96).
const BANNER_TOP := 134.0
const CARD_SIZE := Vector2(640, 236)
const AMBER := Color(1.0, 0.74, 0.38)

var hud: Control
var state := ""
var reason := ""
var active := false
## What the end screen shows: "" (none), "refused_maintenance", "maintenance"
## (logged out by the cycle), "lost", "refused".
var screen_kind := ""

var banner: Panel
var title_label: Label
var detail_label: Label
var screen_layer: CanvasLayer
var screen_title: Label
var screen_detail: Label
var reconnect_button: Button
var quit_button: Button

var _deadline_ms := 0
var _warned := false
var _screen_root: Control

## Evidence for the checks: announcements seen, the states in order, the
## countdown texts shown.
var events_seen := 0
var states_seen: Array = []

func _init() -> void:
	name = "Maintenance"
	layer = 7

func setup(p_hud: Control) -> void:
	hud = p_hud
	_build_banner()

func _build_banner() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	banner = Panel.new()
	banner.name = "MaintenanceBanner"
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.offset_left = -BANNER_SIZE.x * 0.5
	banner.offset_right = BANNER_SIZE.x * 0.5
	banner.offset_top = BANNER_TOP
	banner.offset_bottom = BANNER_TOP + BANNER_SIZE.y
	var box := ArcaneSkin.surface()
	box.bg_color = Color(0.06, 0.05, 0.05, 0.93)
	box.border_color = Color(AMBER.r, AMBER.g, AMBER.b, 0.55)
	banner.add_theme_stylebox_override("panel", box)
	ArcaneSkin.decorate(banner)
	root.add_child(banner)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	_inset(banner, Vector4(18, 10, 18, 10)).add_child(row)
	var lock := UITheme.icon_rect("ui_lock", 40.0)
	lock.name = "LockIcon"
	lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lock)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)
	row.add_child(column)
	title_label = HudKit.label("", 19, AMBER, HudKit.title(), 4)
	column.add_child(title_label)
	detail_label = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 3)
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detail_label)
	banner.hide()

## ------------------------------------------------------------------ events

## One "maintenance" notice from the session.
func on_notice(notice: Dictionary) -> void:
	events_seen += 1
	var next := String(notice.get("state", ""))
	reason = String(notice.get("reason", ""))
	var seconds := maxi(0, int(notice.get("seconds", 0)))
	if states_seen.is_empty() or states_seen[-1] != next:
		states_seen.append(next)
	if CLOSED_STATES.has(next):
		var was_counting := active and (state == "ANNOUNCING" or state == "DRAINING" or state == "FAILED")
		state = next
		active = false
		_warned = false
		banner.hide()
		if was_counting and hud != null:
			hud.show_notice("%s - %s" % [tr("Maintenance cancelled"), tr("The server stays online.")], "good")
			hud.chat.add_system_line(tr("Maintenance cancelled") + ". " + tr("The server stays online."))
		return
	state = next
	active = true
	if state == "ANNOUNCING" or state == "DRAINING":
		_deadline_ms = Time.get_ticks_msec() + seconds * 1000
		if not _warned and hud != null:
			# the banner can be missed in a fight; the chat log keeps it
			_warned = true
			hud.chat.add_system_line(tr("The server is going into maintenance: everyone will be logged out in %d seconds. Stand somewhere safe; your progress will be saved.") % seconds)
	banner.show()
	_refresh()

## Seconds left of the announced countdown (0 once it has passed).
func countdown_seconds() -> int:
	return maxi(0, ceili(float(_deadline_ms - Time.get_ticks_msec()) / 1000.0))

func countdown_text() -> String:
	var seconds := countdown_seconds()
	return "%d:%02d" % [seconds / 60, seconds % 60]

func banner_visible() -> bool:
	return banner != null and banner.visible

func _refresh() -> void:
	match state:
		"ANNOUNCING", "DRAINING":
			title_label.text = tr("Server maintenance: you will be logged out in %s") % countdown_text()
			detail_label.text = tr("Stand somewhere safe and finish what you are doing; your progress will be saved automatically.")
		"SAVING":
			title_label.text = tr("Maintenance - saving progress")
			detail_label.text = tr("The world stands still while every character is saved. Do not close the game.")
		"DISCONNECTING":
			title_label.text = tr("Maintenance - closing connections")
			detail_label.text = tr("Your progress is saved. You can log in again once maintenance is over.")
		"MAINTENANCE":
			title_label.text = tr("The server is closed for maintenance")
			detail_label.text = tr("You can log in again once maintenance is over.")
		"FAILED":
			title_label.text = tr("Maintenance is on hold")
			detail_label.text = tr("The world stands still while the server is checked. Stay connected; it moves again shortly.")
		_:
			title_label.text = tr("Maintenance")
			detail_label.text = ""

func _process(_delta: float) -> void:
	if banner != null and banner.visible and (state == "ANNOUNCING" or state == "DRAINING"):
		_refresh()

## ------------------------------------------------------------------ end screen

## The session ended or never began: `status` is RealmSession.status()
## ("refused: <reason>" or "closed: <reason>"). Shown once; the banner goes.
## `was_in`: the map had been joined and drawn (the world shows dimmed behind
## the card); a join that never got in has nothing to show behind it.
func show_closed(status: String, was_in := true) -> void:
	if screen_kind != "":
		return
	var refused := status.begins_with("refused")
	var why := status.get_slice(": ", 1) if status.contains(": ") else status
	var title := ""
	var detail := ""
	if refused and why == "maintenance":
		screen_kind = "refused_maintenance"
		title = tr("Server under maintenance")
		detail = tr("The server is under maintenance. Please try again a little later.")
	elif not refused and active and ACTIVE_STATES.has(state):
		screen_kind = "maintenance"
		title = tr("You were logged out for maintenance")
		detail = tr("Your progress is saved. You can log in again once maintenance is over.")
	elif refused:
		screen_kind = "refused"
		title = tr("Could not enter the realm")
		detail = I18n.from_server(why)
	else:
		screen_kind = "lost"
		title = tr("Connection to the server lost")
		detail = tr("The connection to the server was lost. Please log in again.")
	banner.hide()
	_build_screen(was_in)
	screen_title.text = title
	screen_detail.text = detail

func screen_visible() -> bool:
	return _screen_root != null and _screen_root.visible

func _build_screen(was_in: bool) -> void:
	screen_layer = CanvasLayer.new()
	screen_layer.name = "ClosedScreen"
	# over the HUD, every window and the loading screen (90)
	screen_layer.layer = 95
	add_child(screen_layer)
	_screen_root = Control.new()
	_screen_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_screen_root.mouse_filter = Control.MOUSE_FILTER_STOP
	screen_layer.add_child(_screen_root)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.014, 0.024, 0.86 if was_in else 1.0)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_root.add_child(shade)
	var logo := UITheme.logo(150.0)
	logo.set_anchors_preset(Control.PRESET_CENTER)
	logo.offset_left = -logo.custom_minimum_size.x * 0.5
	logo.offset_right = logo.custom_minimum_size.x * 0.5
	logo.offset_top = -CARD_SIZE.y * 0.5 - 172.0
	logo.offset_bottom = -CARD_SIZE.y * 0.5 - 22.0
	logo.modulate = Color(0.86, 0.84, 0.9)
	_screen_root.add_child(logo)
	var card := Panel.new()
	card.name = "ClosedCard"
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -CARD_SIZE.x * 0.5
	card.offset_right = CARD_SIZE.x * 0.5
	card.offset_top = -CARD_SIZE.y * 0.5
	card.offset_bottom = CARD_SIZE.y * 0.5
	card.add_theme_stylebox_override("panel", ArcaneSkin.card())
	ArcaneSkin.decorate(card)
	_screen_root.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	_inset(card, Vector4(34, 28, 34, 26)).add_child(column)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	column.add_child(head)
	var lock := UITheme.icon_rect("ui_lock", 44.0)
	lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(lock)
	screen_title = HudKit.label("", 24, HudKit.GOLD_HI, HudKit.title(), 5)
	screen_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	screen_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(screen_title)
	screen_detail = HudKit.label("", 16, HudKit.PARCHMENT, HudKit.body(), 3)
	screen_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	screen_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(screen_detail)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	column.add_child(buttons)
	reconnect_button = HudKit.gold_button(tr("Reconnect"), 42.0, 17)
	reconnect_button.name = "Reconnect"
	reconnect_button.custom_minimum_size.x = 200
	reconnect_button.pressed.connect(reconnect)
	buttons.add_child(reconnect_button)
	quit_button = HudKit.button(tr("Quit Game"), 16)
	quit_button.name = "QuitGame"
	quit_button.custom_minimum_size = Vector2(170, 42)
	quit_button.pressed.connect(func(): get_tree().quit(0))
	buttons.add_child(quit_button)

## A margin box filling `panel` inside its arcane frame (left, top, right,
## bottom), for the panel's content.
static func _inset(panel: Control, margins: Vector4) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", int(margins.x))
	margin.add_theme_constant_override("margin_top", int(margins.y))
	margin.add_theme_constant_override("margin_right", int(margins.z))
	margin.add_theme_constant_override("margin_bottom", int(margins.w))
	panel.add_child(margin)
	return margin

## Join again: the scene is rebuilt and its session joins afresh (a
## maintenance still running refuses it, and this screen says so again).
func reconnect() -> void:
	get_tree().reload_current_scene.call_deferred()
