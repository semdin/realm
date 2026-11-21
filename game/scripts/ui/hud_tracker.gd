extends VBoxContainer
class_name HudTracker

## The objective tracker on the left edge of the screen: a header ("Quests",
## the count, an arrow) that folds the tracker away and back (remembered in
## GameSettings.tracker_collapsed), and under it one card per quest at the
## top of the log (QuestManager.log_entries - finished first, then new, then
## the rest), at most MAX_ROWS, each with its title and live count ("Defeat 6
## Black Weavers 3/6"). A new (unread) quest pulses gold, a finished one
## pulses green until it is claimed (the folded header pulses for them too):
## clicking a finished card claims the reward, clicking any other opens it on
## its parchment scroll. "More quests" opens the quest log (J) when the log
## holds more than shows here.
##
## It shares the left rail with the party frames above it and the chat below
## (HUD.left_rail_band): it stands under the party's last row and shows only
## the cards that fit above the chat; when a big party leaves no room for a
## card there, it stands beside the party frames instead. A party of any size
## and an open chat never run into it (until 2026-11-21 a party of two or more
## pushed it down over the chat).

signal quest_opened(quest_id: String)
signal log_opened

const WIDTH := 210.0
const ICON := 28.0
const MAX_ROWS := 3
const NEW_GLOW := Color(1.0, 0.82, 0.35)
const READY_GLOW := Color(0.45, 1.0, 0.55)
const ACCENT := Color(0.85, 0.68, 0.32)
## Where it sits with nothing above it: this far in from the left edge, this
## far above the middle.
const AT := Vector2(16, -110)
## Room kept to the party's last row above and to the chat below.
const GAP := 10.0
## What the empty log's card needs ("No open quests").
const MIN_CARD := 46.0

var quests: QuestManager
var collapsed := false
var _rows: Array = []
var _row_ids: Array = []
var _row_boxes: Array = []
var _header: Button
var _caption: Label
var _arrow: TextureRect
var _more: Button
var _hud: Control
var _t := 0.0

func _init() -> void:
	name = "Tracker"
	add_theme_constant_override("separation", 5)
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	theme = UITheme.get_theme()
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = AT.x
	offset_right = AT.x + WIDTH
	collapsed = GameSettings.instance().tracker_collapsed
	_header = _make_header()
	add_child(_header)
	for i in MAX_ROWS:
		var row := _make_row()
		row.pressed.connect(_on_row_pressed.bind(i))
		add_child(row)
		_rows.append(row)
		_row_ids.append("")
	_more = Button.new()
	_more.flat = true
	_more.focus_mode = Control.FOCUS_NONE
	_more.add_theme_font_override("font", HudKit.bold())
	_more.add_theme_font_size_override("font_size", 13)
	_more.add_theme_color_override("font_color", HudKit.GOLD_LT)
	_more.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	_more.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_more.add_theme_constant_override("outline_size", 3)
	_more.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# a line of text, not a plate: no button margins round it
	var bare := StyleBoxEmpty.new()
	bare.content_margin_left = 9
	bare.content_margin_top = 1
	bare.content_margin_bottom = 1
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		_more.add_theme_stylebox_override(state, bare)
	_more.pressed.connect(func(): log_opened.emit())
	add_child(_more)
	quests.quest_updated.connect(refresh)
	get_viewport().size_changed.connect(refresh)
	refresh()

## Stand in `hud`'s left rail (HUD.left_rail_band) and move with it.
func follow(hud: Control) -> void:
	_hud = hud
	if hud.has_signal("left_rail_changed") and not hud.left_rail_changed.is_connected(refresh):
		hud.left_rail_changed.connect(refresh)
	refresh()

## Fold the cards away (or back); remembered for the next session.
func set_collapsed(on: bool) -> void:
	collapsed = on
	GameSettings.instance().set_tracker_collapsed(on)
	refresh()

## The header: "QUESTS · 3" and the arrow, over a fading gold rule.
func _make_header() -> Button:
	var b := Button.new()
	b.name = "Header"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 26)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", UIKit.tab("hover", Vector2(6, 3)))
	b.add_theme_stylebox_override("hover", UIKit.tab("selected", Vector2(6, 3)))
	b.add_theme_stylebox_override("pressed", UIKit.tab("selected", Vector2(6, 3)))
	b.add_theme_stylebox_override("hover_pressed", UIKit.tab("selected", Vector2(6, 3)))
	b.add_theme_stylebox_override("focus", HudKit.empty())
	b.pressed.connect(func(): set_collapsed(not collapsed))
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 6
	line.offset_right = -4
	line.offset_bottom = -3
	line.add_theme_constant_override("separation", 6)
	b.add_child(line)
	_caption = HudKit.label("", 13, HudKit.GOLD_LT, UIKit.spaced_font(UITheme.W_BOLD, 1), 3)
	_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(_caption)
	_arrow = TextureRect.new()
	_arrow.custom_minimum_size = Vector2(16, 16)
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(_arrow)
	return b

## A card: the scroll icon on the left, the title and the objective beside it.
func _make_row() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 0)
	var box := RowBox.new()
	box.base = UIKit.nine("rail_row")
	var hover := RowBox.new()
	hover.base = UIKit.nine("rail_row_hover")
	_row_boxes.append([box, hover])
	b.add_theme_stylebox_override("normal", box)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("hover_pressed", hover)
	b.add_theme_stylebox_override("focus", HudKit.empty())
	var line := HBoxContainer.new()
	line.name = "Line"
	line.add_theme_constant_override("separation", 6)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_top = 6
	line.offset_bottom = -6
	line.offset_left = 9
	line.offset_right = -6
	b.add_child(line)
	var icon := UITheme.icon_rect("ui_quest", ICON)
	icon.name = "Icon"
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(icon)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 1)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(column)
	var title := HudKit.label("", 13, HudKit.PARCHMENT, HudKit.bold(), 3)
	title.name = "Title"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(WIDTH - ICON - 21, 0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(title)
	var objective := HudKit.label("", 12, HudKit.GOLD_LT, HudKit.body(), 3)
	objective.name = "Objective"
	objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective.custom_minimum_size = Vector2(WIDTH - ICON - 21, 0)
	objective.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(objective)
	return b

func _set_row(row: Button, title_text: String, objective_text: String) -> void:
	var title := row.get_node("Line/Column/Title") as Label
	var objective := row.get_node("Line/Column/Objective") as Label
	if title.text != title_text:
		title.text = title_text
	if objective.text != objective_text:
		objective.text = objective_text
	# measured from the font: before its first layout a wrapping label does
	# not know its height yet
	row.custom_minimum_size.y = maxf(ICON, _text_height(title) + 1.0 + _text_height(objective)) + 12.0
	(row.get_node("Line") as Control).queue_sort()

## The height quest `q`'s card takes (the first row's labels measure it).
func _card_height(q: Dictionary) -> float:
	var row: Button = _rows[0]
	var title := row.get_node("Line/Column/Title") as Label
	var objective := row.get_node("Line/Column/Objective") as Label
	var keep := [title.text, objective.text]
	title.text = I18n.t(String(q.get("title", "")))
	objective.text = quests.objective_text(q)
	var h := maxf(ICON, _text_height(title) + 1.0 + _text_height(objective)) + 12.0
	title.text = keep[0]
	objective.text = keep[1]
	return h

## The height `label` takes wrapped at its minimum width.
static func _text_height(label: Label) -> float:
	var font := label.get_theme_font("font")
	var size := label.get_theme_font_size("font_size")
	if font == null or label.text == "":
		return 0.0
	var text_size := font.get_multiline_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, label.custom_minimum_size.x, size)
	var lines := maxf(1.0, roundf(text_size.y / font.get_height(size)))
	return text_size.y + (lines - 1.0) * float(label.get_theme_constant("line_spacing"))

func _on_row_pressed(index: int) -> void:
	var id := String(_row_ids[index])
	if id == "":
		return
	if quests.is_ready(id):
		quests.claim(id)
	else:
		quest_opened.emit(id)

## The id on tracker row `index` ("" when the row is empty), for the check.
func row_id(index: int) -> String:
	return String(_row_ids[index]) if index < _row_ids.size() else ""

## How many quest cards show now (the checks).
func shown_rows() -> int:
	var n := 0
	for row: Button in _rows:
		if row.visible and String(_row_ids[_rows.find(row)]) != "":
			n += 1
	return n

func _process(delta: float) -> void:
	_t += delta
	# New and finished quests pulse until they are read / claimed; folded,
	# the header pulses for them.
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	for i in _rows.size():
		var row: Button = _rows[i]
		var id := String(_row_ids[i])
		var glow := _glow_of(id)
		var glowing := glow != Color.WHITE and row.visible
		if not glowing and row.get_meta("glowing", true) == false:
			continue
		row.set_meta("glowing", glowing)
		row.self_modulate = Color.WHITE.lerp(glow, pulse * 0.35) if glowing else Color.WHITE
		for box: RowBox in _row_boxes[i]:
			box.set_accent(Color(glow, 0.45 + 0.55 * pulse) if glowing else ACCENT)
	if _header != null:
		var call := Color.WHITE
		if collapsed:
			for entry: Dictionary in quests.log_entries():
				var g := _glow_of(String(entry.get("id", "")))
				if g == READY_GLOW:
					call = g
					break
				if g == NEW_GLOW:
					call = g
		var want := Color.WHITE.lerp(call, pulse) if call != Color.WHITE else Color.WHITE
		if _caption.modulate != want:
			_caption.modulate = want

func _glow_of(id: String) -> Color:
	if id == "":
		return Color.WHITE
	if quests.is_ready(id):
		return READY_GLOW
	if quests.is_new(id):
		return NEW_GLOW
	return Color.WHITE

## Lay the tracker out: its place on the rail, the header, then as many
## cards as fit between it and the chat.
func refresh() -> void:
	if _rows.is_empty():
		return
	var entries: Array = quests.log_entries()
	var canvas := get_viewport_rect().size
	var band := Vector2(0.0, canvas.y)
	var party := Rect2()
	if _hud != null and _hud.has_method("left_rail_band"):
		band = _hud.left_rail_band()
		party = _hud.left_rail_party()
	var sep := float(get_theme_constant("separation"))
	# its own place, or higher (never above the rail) when the cards need it
	var want := _header.get_combined_minimum_size().y
	for i in mini(MAX_ROWS, entries.size()) if not collapsed else 0:
		want += sep + _card_height(entries[i])
	if entries.size() > MAX_ROWS:
		want += sep + _more.get_combined_minimum_size().y
	var top := maxf(minf(canvas.y * 0.5 + AT.y, band.y - GAP - want), band.x + GAP)
	var room := band.y - GAP - top
	var x := AT.x
	# what the first card needs (and the "more" line after it)
	var first := _header.get_combined_minimum_size().y + sep + (_card_height(entries[0]) if not entries.is_empty() else MIN_CARD)
	if entries.size() > 1:
		first += sep + _more.get_combined_minimum_size().y
	if not collapsed and room < first and party.size.y > 0.0:
		# no room for a card under a big party: beside it
		x = party.end.x + GAP
		top = party.position.y
		room = band.y - GAP - top
	offset_left = x
	offset_right = x + WIDTH
	offset_top = top
	offset_bottom = top + 10.0
	_caption.text = "%s  ·  %d" % [I18n.upper(tr("Quests")), entries.size()]
	_arrow.texture = UIKit.tex("ico_chevron_right" if collapsed else "ico_chevron_down")
	_header.tooltip_text = tr("Show the quests") if collapsed else tr("Hide the quests")
	var used := _header.get_combined_minimum_size().y
	var more_h := _more.get_combined_minimum_size().y + sep
	var shown := 0
	for i in _rows.size():
		var row: Button = _rows[i]
		_row_ids[i] = ""
		if collapsed or (i >= entries.size() and i > 0):
			row.visible = false
			continue
		if entries.is_empty():
			_set_row(row, tr("No open quests"), tr("Level up to unlock more"))
			row.tooltip_text = ""
		else:
			var q: Dictionary = entries[i]
			var id := String(q.get("id", ""))
			_set_row(row, I18n.t(String(q.get("title", ""))), quests.objective_text(q))
			row.tooltip_text = tr("Click to claim the reward") if quests.is_ready(id) else tr("Click to read the quest scroll")
		var need := sep + row.custom_minimum_size.y
		var later := entries.size() > i + 1
		if used + need + (more_h if later else 0.0) > room:
			row.visible = false
			continue
		row.visible = true
		if not entries.is_empty():
			_row_ids[i] = String(entries[i].get("id", ""))
			shown += 1
		used += need
	var hidden := entries.size() - shown
	_more.visible = not collapsed and hidden > 0 and used + more_h <= room
	_more.text = tr("More quests (%d)  ·  %s") % [hidden, GameSettings.key_name("quest_log")]


## A card's look: the kit's fading glass, and a slim accent on its left edge
## (gold, or pulsing gold / green for a new / finished quest).
class RowBox extends StyleBox:
	@export var base: StyleBox
	@export var accent := HudTracker.ACCENT

	func set_accent(c: Color) -> void:
		if c != accent:
			accent = c
			emit_changed()

	func _draw(item: RID, rect: Rect2) -> void:
		base.draw(item, rect)
		RenderingServer.canvas_item_add_rect(item, Rect2(rect.position + Vector2(0, 3), Vector2(2, rect.size.y - 6)), accent)
		var soft := Color(accent, accent.a * 0.25)
		RenderingServer.canvas_item_add_rect(item, Rect2(rect.position + Vector2(2, 3), Vector2(3, rect.size.y - 6)), soft)
