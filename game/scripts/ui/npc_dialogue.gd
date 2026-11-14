extends PanelContainer
class_name NpcDialogue

## The NPC dialogue card, bottom centre: a medallion in the NPC's robe colour
## with the initial of its last name (and a "?" / "!" mark when the NPC has a
## quest to hand in or a new one), the name and role, and the NPC's lines one
## page at a time, typed out. F or a click finishes the page, then turns it.
## Under the text, the NPC's own quests (quests.json `giver`: ready to hand
## in, new, in progress), a service when the NPC offers one, and Goodbye. It
## stays until Esc, Goodbye, or the player walks away.
##
## The card only asks: a quest row emits `quest_chosen` (the quest scroll
## opens, which claims), a service row emits `service_chosen`.

signal quest_chosen(quest_id: String)
signal service_chosen(service: String)

const WIDTH := 660.0
## Characters typed per second.
const TYPE_RATE := 110.0
## Farther than this from the NPC and the card closes.
const WALK_AWAY := 8.0
## At most this many quest rows; the rest are in the log (J).
const MAX_QUESTS := 4
## A service's icon by its id (npcs.json `services`).
const SERVICE_ICONS := {"workshop": "ui_kestrin"}

var quests: QuestManager
var npc: NpcView = null
var player: Node3D = null
## Whether a service can be offered here (service id -> bool); a service whose
## window this client does not have yet gets no row.
var can_serve: Callable
var _pages: Array = []
var _page := 0
var _typed := 0.0
var _medal: Medal
var _mark: HBoxContainer
var _mark_icon: QuestMark
var _mark_text: Label
var _name: Label
var _role: Label
var _dots: PageDots
var _text: Label
var _next: HBoxContainer
var _next_label: Label
var _options: VBoxContainer
## The quest rows on the card now, in order (the check reads them).
var quest_rows: Array = []
## Placing resizes the card, which asks to place it again.
var _placing := false

func _init() -> void:
	name = "Dialogue"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.086, 0.141, 0.97)
	sb.border_color = HudKit.GOLD
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_size = 14
	sb.shadow_offset = Vector2(0, 6)
	sb.content_margin_left = 18
	sb.content_margin_right = 22
	sb.content_margin_top = 18
	sb.content_margin_bottom = 16
	add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	var portrait := VBoxContainer.new()
	portrait.custom_minimum_size.x = 96
	portrait.add_theme_constant_override("separation", 8)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(portrait)
	_medal = Medal.new()
	_medal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	portrait.add_child(_medal)
	_mark = HBoxContainer.new()
	_mark.alignment = BoxContainer.ALIGNMENT_CENTER
	_mark.add_theme_constant_override("separation", 5)
	_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.add_child(_mark)
	_mark_icon = QuestMark.new("ready", 18.0)
	_mark.add_child(_mark_icon)
	_mark_text = _label("", 12, HudKit.GOLD_LT)
	_mark.add_child(_mark_text)

	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 0)
	main.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(main)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.add_child(head)
	_name = HudKit.label("", 20, HudKit.GOLD_HI, HudKit.title(), 3)
	head.add_child(_name)
	_role = _label("", 14, HudKit.TEXT_DIM)
	_role.size_flags_vertical = Control.SIZE_SHRINK_END
	_role.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_role)
	_dots = PageDots.new()
	_dots.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_dots)
	var rule := RuleFade.new()
	rule.custom_minimum_size = Vector2(0, 21)
	main.add_child(rule)
	_text = _label("", 17, HudKit.PARCHMENT)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(WIDTH - 180.0, 76)
	_text.add_theme_constant_override("line_spacing", 4)
	main.add_child(_text)
	_next = HBoxContainer.new()
	_next.alignment = BoxContainer.ALIGNMENT_END
	_next.add_theme_constant_override("separation", 8)
	_next.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.add_child(_next)
	_next_label = _label("", 14, HudKit.GOLD_LT)
	_next.add_child(_next_label)
	_next.add_child(_keycap("F"))
	_options = VBoxContainer.new()
	_options.add_theme_constant_override("separation", 4)
	_options.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.add_child(_options)

func _ready() -> void:
	theme = UITheme.get_theme()
	get_viewport().size_changed.connect(_place)
	resized.connect(_place)
	quests.quest_updated.connect(func():
		if visible:
			_build_options())

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		advance()
		accept_event()

## Open the card for `p_npc` (its name, role and lines are English message
## ids, shown translated).
func open(p_npc: NpcView, p_player: Node3D) -> void:
	npc = p_npc
	player = p_player
	_pages = npc.dialogue.map(func(line): return I18n.t(String(line)))
	if _pages.is_empty():
		_pages = [""]
	_page = 0
	var shown := I18n.t(npc.npc_name)
	_name.text = shown
	_role.text = I18n.t(npc.role)
	var words := shown.split(" ", false)
	_medal.initial = words[-1].left(1) if not words.is_empty() else "?"
	_medal.robe = npc.robe_color
	_build_options()
	_show_page()
	show()
	_place()

func is_open_for(p_npc: NpcView) -> bool:
	return visible and p_npc != null and p_npc == npc

## Finish typing the page, else turn to the next one.
func advance() -> void:
	var full := String(_pages[_page]).length()
	if _typed < full:
		_typed = full
		_sync_text()
	elif _page < _pages.size() - 1:
		_page += 1
		_show_page()

func close() -> void:
	hide()

func _show_page() -> void:
	_typed = 0.0
	_text.text = String(_pages[_page])
	_dots.count = _pages.size()
	_dots.current = _page
	_sync_text()

func _sync_text() -> void:
	var full := String(_pages[_page]).length()
	_text.visible_characters = -1 if _typed >= full else int(_typed)
	var last := _page >= _pages.size() - 1
	_next.modulate.a = 0.0 if last and _typed >= full else 1.0
	_next_label.text = tr("Finish") if _typed < full else tr("Continue  ▸")

func _process(delta: float) -> void:
	if not visible:
		return
	var full := String(_pages[_page]).length()
	if _typed < full:
		_typed = minf(full, _typed + delta * TYPE_RATE)
		_sync_text()
	# Walking off ends the conversation.
	if npc != null and (not is_instance_valid(npc) or (is_instance_valid(player)
			and npc.global_position.distance_to(player.global_position) > WALK_AWAY)):
		close()

## Bottom centre above the taskbar, sized to its content.
func _place() -> void:
	if not visible or _placing:
		return
	_placing = true
	var canvas := get_viewport().get_visible_rect().size
	var w := minf(WIDTH, canvas.x - 32.0)
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	size = Vector2(w, 0)
	var h := get_combined_minimum_size().y
	position = Vector2(floorf((canvas.x - w) * 0.5), canvas.y - h - 112.0)
	size = Vector2(w, h)
	_placing = false

# ------------------------------------------------------------------ options

## The NPC's quests (ready to hand in first, then new, then in progress), its
## service, and Goodbye.
func _build_options() -> void:
	for child in _options.get_children():
		_options.remove_child(child)
		child.queue_free()
	quest_rows.clear()
	var ready: Array = []
	var fresh: Array = []
	var going: Array = []
	for q: Dictionary in quests.log_entries():
		if String(q.get("giver", "")) != npc.npc_name:
			continue
		var id := String(q.get("id", ""))
		if quests.is_ready(id):
			ready.append(q)
		elif quests.is_new(id):
			fresh.append(q)
		else:
			going.append(q)
	var listed := 0
	for group in [["ready", ready], ["new", fresh], ["going", going]]:
		for q: Dictionary in group[1]:
			if listed >= MAX_QUESTS:
				break
			listed += 1
			var id := String(q.get("id", ""))
			var meta := ""
			match String(group[0]):
				"ready":
					meta = tr("Hand in")
				"new":
					meta = tr("New")
				_:
					var count := int(q.get("count", 1))
					meta = "%d/%d" % [mini(quests.progress_of(id), count), count] if count > 1 else tr("In progress")
			var row := _option(QuestMark.new(String(group[0]), 22.0), I18n.t(String(q.get("title", id))), meta, String(group[0]))
			row.pressed.connect(func():
				close()
				quest_chosen.emit(id))
			_options.add_child(row)
			quest_rows.append({"id": id, "kind": String(group[0]), "button": row})
	for spec: Dictionary in npc.services:
		var service := String(spec.get("id", ""))
		if not can_serve.is_valid() or not bool(can_serve.call(service)):
			continue
		var icon := UITheme.icon_rect(String(SERVICE_ICONS.get(service, "ui_interact")), 22.0)
		var row := _option(icon, I18n.t(String(spec.get("label", service))), String(spec.get("key", "")), "")
		row.name = "Service_" + service
		row.pressed.connect(func():
			close()
			service_chosen.emit(service))
		_options.add_child(row)
	var bye := _option(Control.new(), tr("Goodbye"), "", "bye")
	bye.pressed.connect(close)
	_options.add_child(bye)
	var any_ready := not ready.is_empty()
	_mark.visible = any_ready or not fresh.is_empty()
	_mark_icon.kind = "ready" if any_ready else "new"
	_mark_text.text = tr("hand in") if any_ready else tr("new quest")

## One option row: an icon, the caption, a note on the right ("Hand in",
## "3/6", the key) and, for Goodbye, the Esc keycap.
func _option(icon: Control, caption: String, meta: String, kind: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 36)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var bye := kind == "bye"
	var looks := {
		"normal": [Color(0, 0, 0, 0) if bye else Color(0.086, 0.141, 0.227, 0.45), Color(0, 0, 0, 0) if bye else Color("23324c")],
		"hover": [Color(0.188, 0.259, 0.384, 0.6), HudKit.GOLD],
		"pressed": [Color(0.12, 0.17, 0.26, 0.7), HudKit.GOLD_LT],
	}
	for state in looks:
		var sb := StyleBoxFlat.new()
		sb.bg_color = looks[state][0]
		sb.border_color = looks[state][1]
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(4)
		button.add_theme_stylebox_override(state, sb)
	button.add_theme_stylebox_override("focus", HudKit.empty())
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 8
	row.offset_right = -10
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	icon.custom_minimum_size = Vector2(22, 22)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var text := _label(caption, 15, HudKit.TEXT_DIM if bye else HudKit.PARCHMENT)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.custom_minimum_size.x = 60
	row.add_child(text)
	if meta != "":
		var colour := HudKit.GOLD_HI if kind == "ready" else (HudKit.GOLD_LT if kind == "new" else HudKit.TEXT_DIM)
		var note := _label(meta, 13, colour)
		note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(note)
	if bye:
		var cap := _keycap("Esc")
		cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(cap)
	return button

func _label(text: String, size: int, colour: Color) -> Label:
	return HudKit.label(text, size, colour, HudKit.body(), 0)

func _keycap(text: String) -> PanelContainer:
	var cap := PanelContainer.new()
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("1a1409")
	sb.border_color = HudKit.GOLD_DK
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	cap.add_theme_stylebox_override("panel", sb)
	cap.add_child(HudKit.label(text, 11, HudKit.GOLD_LT, HudKit.bold(), 0))
	return cap


## The portrait medallion: the NPC's robe colour behind its initial, in a gold
## ring with a faint outer halo.
class Medal extends Control:
	var robe := Color(0.2, 0.25, 0.5):
		set(value):
			robe = value
			queue_redraw()
	var initial := "":
		set(value):
			initial = value
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(92, 92)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 4.0
		draw_arc(c, r + 3.5, 0.0, TAU, 64, Color(HudKit.GOLD, 0.35), 1.0, true)
		draw_circle(c, r, HudKit.GOLD)
		draw_circle(c, r - 2.0, Color("0b1120"))
		# Robe colour, darker to the rim, lit towards the upper left.
		draw_circle(c, r - 4.0, robe.darkened(0.55))
		draw_circle(c + Vector2(-3, -4), r - 9.0, robe.darkened(0.2))
		draw_circle(c + Vector2(-6, -8), r - 22.0, robe.lightened(0.08))
		var font := HudKit.title()
		var w := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 32).x
		var at := Vector2(c.x - w * 0.5, c.y + 11.0)
		draw_string_outline(font, at, initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 32, 4, Color(0, 0, 0, 0.7))
		draw_string(font, at, initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 32, HudKit.GOLD_HI)


## A quest's state as a round mark: "?" glowing gold (ready to hand in), "!"
## (new), "…" (in progress). Kind "" or "bye" draws nothing.
class QuestMark extends Control:
	var kind := "":
		set(value):
			kind = value
			queue_redraw()

	func _init(p_kind: String, px: float) -> void:
		kind = p_kind
		custom_minimum_size = Vector2(px, px)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if kind not in ["ready", "new", "going"]:
			return
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.0
		var glyph := {"ready": "?", "new": "!", "going": "…"}[kind] as String
		var ink := HudKit.GOLD_HI
		if kind == "ready":
			draw_circle(c, r + 1.5, Color(1.0, 0.82, 0.47, 0.35))
			draw_circle(c, r, Color(0.85, 0.62, 0.22))
			draw_arc(c, r, 0.0, TAU, 32, HudKit.GOLD_HI, 1.0, true)
			ink = Color(0.165, 0.102, 0.016)
		elif kind == "new":
			draw_circle(c, r, Color("2a1d08"))
			draw_arc(c, r, 0.0, TAU, 32, HudKit.GOLD, 1.0, true)
		else:
			draw_circle(c, r, Color("141b29"))
			draw_arc(c, r, 0.0, TAU, 32, Color("3a4560"), 1.0, true)
			ink = HudKit.TEXT_DIM
		var font := HudKit.title()
		var fs := int(r * 1.25)
		var w := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(c.x - w * 0.5, c.y + fs * 0.36), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


## Which page of the NPC's lines is showing: read pages dim gold, the current
## one bright, the rest dark.
class PageDots extends Control:
	var count := 1:
		set(value):
			count = value
			custom_minimum_size = Vector2(maxf(0.0, count * 12.0 - 5.0), 8) if count > 1 else Vector2.ZERO
			queue_redraw()
	var current := 0:
		set(value):
			current = value
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if count <= 1:
			return
		for i in count:
			var c := Vector2(i * 12.0 + 3.5, size.y * 0.5)
			var fill := HudKit.GOLD_LT if i == current else (HudKit.GOLD_DK if i < current else Color("2a3550"))
			draw_circle(c, 3.5, fill)
			draw_arc(c, 3.5, 0.0, TAU, 16, HudKit.GOLD_HI if i == current else Color("3a4870"), 1.0, true)


## The rule under the name: gold fading out to the right.
class RuleFade extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := floorf(size.y * 0.5)
		var steps := 24
		for i in steps:
			var t := float(i) / steps
			draw_line(Vector2(size.x * t, y), Vector2(size.x * (t + 1.0 / steps), y), Color(HudKit.GOLD_DK, 1.0 - t * 0.85), 1.0)
