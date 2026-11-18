extends Control
class_name HudPlayerMenu

## The menu a right click on another player opens at the cursor (the old
## game's approved menu): a header with the player's name and, when the
## client knows them, `Lv. N · House`, then the entries: invite to the party,
## challenge to a duel, call a group duel. Each entry sends the chat command
## the player could type (`/invite Name`, `/duel Name`, `/gduel Name`); the
## server checks everything again and answers in the chat. An entry that cannot
## apply stays listed but dimmed, with the reason under it, so the options are
## always discoverable. Below them, Block (or Unblock) and Report.
##
## It opens on a player within RANGE of the player's own body and closes beyond
## the same RANGE, so the reach that opens it and the reach that keeps it agree;
## it also closes on a click anywhere else and on Esc.

## Who it opens on and how far it stays open, from the player's own body.
const RANGE := 40.0
const MENU_W := 238.0
const PARTY_ACCENT := Color(0.46, 0.74, 1.0)
const DUEL_ACCENT := Color(1.0, 0.40, 0.32)
const GROUP_ACCENT := Color(1.0, 0.58, 0.24)
const BLOCK_ACCENT := Color(0.72, 0.72, 0.78)
const REPORT_ACCENT := Color(0.95, 0.74, 0.30)
const ReportWindowScript := "res://scripts/ui/hud_report_window.gd"

var session: Node
## The player's own body (the range), the party frames (who is in the party,
## who leads it) and the duel view (whether the player is in a duel).
var player: Node3D
var party_frames: HudParty
var duel_view: HudDuel
## The player the menu is open on: its body and its name.
var target: Node3D
var target_name := ""
## Names this account has blocked, as the server last said.
var blocked_names: Array = []
var _report_window: HudWindow
var _panel: PanelContainer
var _column: VBoxContainer
## Where its top-left corner wants to be (beside the cursor that opened it).
var _corner := Vector2.ZERO

func _init() -> void:
	name = "PlayerMenu"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.040, 0.067, 0.97)
	box.border_color = HudKit.GOLD
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.shadow_color = Color(0, 0, 0, 0.6)
	box.shadow_size = 12
	box.shadow_offset = Vector2(0, 4)
	box.set_content_margin_all(6)
	box.anti_aliasing = true
	_panel.add_theme_stylebox_override("panel", box)
	add_child(_panel)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 2)
	_column.custom_minimum_size = Vector2(MENU_W, 0)
	_panel.add_child(_column)

## Whether a body at `at` is near enough to open the menu on.
func in_reach(at: Vector3) -> bool:
	return player != null and player.global_position.distance_to(at) <= RANGE

## Open on `body` (another player) at screen point `at`. `who` is what the
## client knows of it: `name`, and `level` and `house` when it is in the
## party (0 / empty when not known).
func open(body: Node3D, who: Dictionary, at: Vector2) -> void:
	if body == null or body == player or String(who.get("name", "")) == "" or not in_reach(body.global_position):
		return
	target = body
	target_name = String(who["name"])
	for child in _column.get_children():
		_column.remove_child(child)
		child.queue_free()
	_column.add_child(_header(target_name, int(who.get("level", 0)), String(who.get("house", ""))))
	var in_mine := party_frames != null and party_frames.shown_members().any(func(m): return String(m["name"]) == target_name)
	_column.add_child(_entry(tr("Invite to Party"), PARTY_ACCENT, "/invite %s" % target_name,
		tr("Already in your party.") if in_mine else ""))
	var in_duel := duel_view != null and duel_view.active()
	var duel_hint := tr("You are already in a duel.") if in_duel else ""
	_column.add_child(_entry(tr("Challenge to Duel"), DUEL_ACCENT, "/duel %s" % target_name, duel_hint))
	var group_hint := duel_hint
	if group_hint == "":
		if party_frames == null or not party_frames.in_party():
			group_hint = tr("You need a party.")
		elif not party_frames.is_leader():
			group_hint = tr("Only the party leader can call it.")
		elif in_mine:
			group_hint = tr("They are in your party.")
	_column.add_child(_entry(tr("Group Duel"), GROUP_ACCENT, "/gduel %s" % target_name, group_hint))
	var is_blocked := target_name in blocked_names
	_column.add_child(_entry(tr("Unblock Player") if is_blocked else tr("Block Player"), BLOCK_ACCENT,
		("/unblock \"%s\"" if is_blocked else "/block \"%s\"") % target_name, ""))
	_column.add_child(_entry(tr("Report Player"), REPORT_ACCENT, _open_report.bind(target_name, int(who.get("character", 0))), ""))
	visible = true
	_panel.reset_size()
	_corner = at + Vector2(10, 6)
	_place()
	AudioManager.play_sound_at("ui_open", Vector3.ZERO, null, true)

## The report window, made the first time it is needed; it lives beside the
## menu, which hides itself.
func _open_report(who: String, character: int) -> void:
	if _report_window == null:
		_report_window = load(ReportWindowScript).new()
		_report_window.session = session
		get_parent().add_child(_report_window)
	_report_window.open_on(who, character)

## A moderation notice as a line for the chat log ("" for none).
func social_notice(notice: Dictionary) -> String:
	match String(notice["kind"]):
		"blocks":
			blocked_names = Array(notice["names"])
		"sanction":
			if String(notice["state"]) == "unmute":
				return tr("You can speak again.")
			var until := int(notice["until"])
			var line := tr("You have been muted until %s.") % MaintenanceUI.local_time(until) if until > 0 else tr("You have been muted.")
			var reason := String(notice["reason"])
			return line if reason == "" else "%s %s" % [line, tr("Reason: %s") % reason]
		"social":
			return _social_line(String(notice["what"]), String(notice["reason"]), String(notice["name"]))
	return ""

func _social_line(what: String, reason: String, who: String) -> String:
	match reason:
		"sent":
			return tr("Your report was sent. Thank you.")
		"done":
			return tr("%s is blocked. You will not see their messages or invitations.") % who if what == "block" else tr("%s is no longer blocked.") % who
		"too_soon":
			return tr("Please wait a little before sending another report.")
		"daily_limit":
			return tr("You have sent too many reports today.")
		"duplicate":
			return tr("You already reported this player recently.")
		"self":
			return tr("You cannot do that to yourself.")
		"full":
			return tr("Your block list is full.")
		"not_found":
			return tr("No player with that name was found.")
	return tr("That is not available right now.")

func close() -> void:
	visible = false
	target = null
	target_name = ""

func is_open() -> bool:
	return visible

func _process(_delta: float) -> void:
	if not visible:
		return
	if target == null or not is_instance_valid(target) or not target.is_inside_tree() or not in_reach(target.global_position):
		close()
		return
	_place()

## Beside the cursor, kept on screen (its size is known once laid out).
func _place() -> void:
	var room := get_viewport_rect().size - _panel.get_combined_minimum_size() - Vector2(8, 8)
	_panel.position = Vector2(clampf(_corner.x, 8.0, maxf(8.0, room.x)), clampf(_corner.y, 8.0, maxf(8.0, room.y)))

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton and event.pressed and not _panel.get_global_rect().has_point(event.position):
		close()   # a click anywhere else closes it (and still does its own thing)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

## The entries as {text, blocked} (the checks read them).
func entries() -> Array:
	var out: Array = []
	for child in _column.get_children():
		if child is Button:
			out.append({"text": (child as Button).text, "blocked": (child as Button).disabled})
	return out

## Press the entry labelled `text` (the checks press it the way a click does).
func press(text: String) -> bool:
	for child in _column.get_children():
		if child is Button and (child as Button).text == text and not (child as Button).disabled:
			(child as Button).pressed.emit()
			return true
	return false

func _header(who: String, level: int, house: String) -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(box)
	box.add_child(HudKit.label(who, 17, HudKit.GOLD_HI, HudKit.title(), 4))
	if level > 0:
		var sub := tr("Lv. %d  ·  %s") % [level, HudQuestScroll.house_name(house)] if house != "" else tr("Lv. %d") % level
		box.add_child(HudKit.label(sub, 13, HudKit.TEXT_DIM, HudKit.body(), 3))
	var rule := ColorRect.new()
	rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.45)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(rule)
	return margin

## One entry: a coloured pip, the label, and (when it cannot apply) the reason.
func _entry(text: String, accent: Color, command: Variant, blocked: String) -> Control:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = text
	b.disabled = blocked != ""
	b.custom_minimum_size = Vector2(MENU_W, 50 if blocked != "" else 32)
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(5)
		sb.content_margin_left = 26
		sb.content_margin_right = 10
		sb.content_margin_top = 4
		sb.content_margin_bottom = 22 if blocked != "" else 4
		sb.anti_aliasing = true
		match state:
			"hover":
				sb.bg_color = Color(accent.r, accent.g, accent.b, 0.16)
				sb.border_color = Color(accent.r, accent.g, accent.b, 0.7)
				sb.border_width_left = 2
			"pressed":
				sb.bg_color = Color(accent.r, accent.g, accent.b, 0.26)
			"focus":
				sb.draw_center = false
			_:
				sb.bg_color = Color(0, 0, 0, 0)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_font_override("font", HudKit.bold())
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", HudKit.PARCHMENT)
	b.add_theme_color_override("font_hover_color", accent.lerp(Color.WHITE, 0.55))
	b.add_theme_color_override("font_pressed_color", accent)
	b.add_theme_color_override("font_disabled_color", Color(HudKit.TEXT_DIM.r, HudKit.TEXT_DIM.g, HudKit.TEXT_DIM.b, 0.7))
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	b.add_theme_constant_override("outline_size", UITheme.outline_for(15, 3))
	var pip := Pip.new()
	pip.colour = accent if blocked == "" else Color(0.4, 0.4, 0.42)
	pip.position = Vector2(9, 10 if blocked == "" else 9)
	b.add_child(pip)
	if blocked != "":
		var why := HudKit.label(blocked, 12, Color(0.80, 0.62, 0.50), HudKit.body(), 2)
		why.position = Vector2(26, 29)
		b.add_child(why)
	b.pressed.connect(func():
		if command is Callable:
			(command as Callable).call()
		elif session != null:
			session.send_chat(String(command))
		AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)
		close())
	return b


## The entry's colour mark: a small diamond.
class Pip extends Control:
	var colour := HudKit.GOLD

	func _init() -> void:
		size = Vector2(10, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)]), colour)
