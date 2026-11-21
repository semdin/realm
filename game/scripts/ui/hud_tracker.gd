extends VBoxContainer
class_name HudTracker

## The objective tracker on the left edge of the screen, drawn the way the
## Korean MMOs the owner pointed at draw theirs (AION 2, Lost Ark): no cards
## or boxes, type over a soft dark wash. A header ("QUESTS · 6" and an arrow)
## folds it to that line and back (remembered in
## GameSettings.tracker_collapsed). Under it, one entry per quest at the top
## of the log (QuestManager.log_entries - finished first, then new, then the
## rest), at most MAX_ROWS: a small cut-diamond mark (a dot in progress, "!"
## new, a tick finished), the title in warm gold, and indented under it the
## objective with its count on the right and a slim progress line. A new
## (unread) quest pulses gold, a finished one green until it is claimed (the
## folded header pulses for them too): clicking a finished entry claims the
## reward, clicking any other opens it on its parchment scroll. "More quests"
## opens the quest log (J) when the log holds more than shows here.
##
## It shares the left rail with the party frames above it and the chat below
## (HUD.left_rail_band): it stands under the party's last row and shows only
## the entries that fit above the chat; when a big party leaves no room for
## one there, it stands beside the party frames instead. A party of any size
## and an open chat never run into it (until 2026-11-21 a party of two or
## more pushed it down over the chat).

signal quest_opened(quest_id: String)
signal log_opened

const WIDTH := 228.0
const MARK := 16.0
## The objective's indent under the title (past the mark).
const INDENT := 21.0
## Room for the count on the objective's right ("12/20").
const COUNT_W := 38.0
const MAX_ROWS := 3
const NEW_GLOW := Color(1.0, 0.82, 0.35)
const READY_GLOW := Color(0.45, 1.0, 0.55)
const ACCENT := Color(0.85, 0.68, 0.32)
const TITLE := Color(0.96, 0.82, 0.55)
const TITLE_READY := Color(0.80, 0.95, 0.60)
const OBJECTIVE := Color(0.87, 0.85, 0.80)
const COUNT := Color(1.0, 0.86, 0.55)
## Where it sits with nothing above it: this far in from the left edge, this
## far above the middle.
const AT := Vector2(14, -110)
## Room kept to the party's last row above and to the chat below.
const GAP := 10.0
## What the empty log's entry needs ("No open quests").
const MIN_CARD := 40.0

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
var _back: StyleBox
var _t := 0.0

func _init() -> void:
	name = "Tracker"
	add_theme_constant_override("separation", 2)
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	theme = UITheme.get_theme()
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = AT.x
	offset_right = AT.x + WIDTH
	collapsed = GameSettings.instance().tracker_collapsed
	_back = UIKit.nine("rail_back") if UIKit.tex("rail_back") != null else null
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
	_more.add_theme_font_size_override("font_size", 12)
	_more.add_theme_color_override("font_color", Color(0.80, 0.72, 0.56))
	_more.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	_more.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_more.add_theme_constant_override("outline_size", 3)
	_more.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# a line of text, not a plate: no button margins round it
	var bare := StyleBoxEmpty.new()
	bare.content_margin_left = INDENT
	bare.content_margin_top = 2
	bare.content_margin_bottom = 2
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

## Fold the entries away (or back); remembered for the next session.
func set_collapsed(on: bool) -> void:
	collapsed = on
	GameSettings.instance().set_tracker_collapsed(on)
	refresh()

## The soft dark wash behind the entries (not behind the header).
func _draw() -> void:
	if _back == null or collapsed or _header == null:
		return
	var top := _header.size.y
	if size.y - top > 8.0:
		_back.draw(get_canvas_item(), Rect2(Vector2(-AT.x, top - 6.0), Vector2(size.x + AT.x + 40.0, size.y - top + 14.0)))

## The header: "QUESTS · 3" and the arrow, over a fading gold rule.
func _make_header() -> Button:
	var b := Button.new()
	b.name = "Header"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 24)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", UIKit.tab("hover", Vector2(4, 3)))
	b.add_theme_stylebox_override("hover", UIKit.tab("selected", Vector2(4, 3)))
	b.add_theme_stylebox_override("pressed", UIKit.tab("selected", Vector2(4, 3)))
	b.add_theme_stylebox_override("hover_pressed", UIKit.tab("selected", Vector2(4, 3)))
	b.add_theme_stylebox_override("focus", HudKit.empty())
	b.pressed.connect(func(): set_collapsed(not collapsed))
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 2
	line.offset_right = -2
	line.offset_bottom = -3
	line.add_theme_constant_override("separation", 6)
	b.add_child(line)
	_caption = HudKit.label("", 12, Color(0.92, 0.80, 0.55), UIKit.spaced_font(UITheme.W_BOLD, 2), 3)
	_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(_caption)
	_arrow = TextureRect.new()
	_arrow.custom_minimum_size = Vector2(14, 14)
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(_arrow)
	return b

## An entry: the mark and the title, the objective and its count under it,
## the progress line under that.
func _make_row() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 0)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var box := RowBox.new()
	var hover := RowBox.new()
	hover.wash = true
	_row_boxes.append([box, hover])
	b.add_theme_stylebox_override("normal", box)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("hover_pressed", hover)
	b.add_theme_stylebox_override("focus", HudKit.empty())
	var col := VBoxContainer.new()
	col.name = "Column"
	col.add_theme_constant_override("separation", 1)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_top = 5
	col.offset_bottom = -5
	col.offset_left = 2
	col.offset_right = -4
	b.add_child(col)
	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override("separation", 5)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)
	var mark := TextureRect.new()
	mark.name = "Mark"
	mark.custom_minimum_size = Vector2(MARK, MARK)
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(mark)
	var title := HudKit.label("", 14, TITLE, HudKit.bold(), 3)
	title.name = "Title"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(WIDTH - INDENT - 6, 0)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var task := HBoxContainer.new()
	task.name = "Task"
	task.add_theme_constant_override("separation", 4)
	task.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(task)
	var indent := Control.new()
	indent.custom_minimum_size = Vector2(INDENT - 4, 0)
	indent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	task.add_child(indent)
	var objective := HudKit.label("", 12, OBJECTIVE, HudKit.body(), 3)
	objective.name = "Objective"
	objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective.custom_minimum_size = Vector2(WIDTH - INDENT - COUNT_W - 8, 0)
	objective.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task.add_child(objective)
	var count := HudKit.label("", 12, COUNT, HudKit.bold(), 3)
	count.name = "Count"
	count.custom_minimum_size = Vector2(COUNT_W, 0)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	task.add_child(count)
	var bar_row := HBoxContainer.new()
	bar_row.name = "Progress"
	bar_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(bar_row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(INDENT - 4, 0)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_row.add_child(pad)
	var bar := ProgressBar.new()
	bar.name = "Bar"
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.custom_minimum_size = Vector2(0, 4)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UIKit.style_gauge(bar, Color(0.93, 0.70, 0.27))
	bar_row.add_child(bar)
	return b

## Fill entry `row` with quest `q` (or the empty log's line when `q` is {}).
func _set_row(row: Button, q: Dictionary) -> void:
	var title := row.get_node("Column/Head/Title") as Label
	var objective := row.get_node("Column/Task/Objective") as Label
	var count := row.get_node("Column/Task/Count") as Label
	var mark := row.get_node("Column/Head/Mark") as TextureRect
	var progress := row.get_node("Column/Progress") as Control
	var bar := row.get_node("Column/Progress/Bar") as ProgressBar
	var parts := _texts(q)
	if title.text != parts[0]:
		title.text = parts[0]
	if objective.text != parts[1]:
		objective.text = parts[1]
	count.text = parts[2]
	count.visible = parts[2] != ""
	objective.custom_minimum_size.x = _objective_width(parts[2] != "")
	var id := String(q.get("id", ""))
	var ready := id != "" and quests.is_ready(id)
	title.add_theme_color_override("font_color", TITLE_READY if ready else TITLE)
	objective.add_theme_color_override("font_color", Color(0.78, 0.93, 0.62) if ready else OBJECTIVE)
	mark.texture = UIKit.tex("quest_ready" if ready else ("quest_new" if id != "" and quests.is_new(id) else "quest_mark"))
	mark.visible = id != ""
	var total := int(q.get("count", 1))
	progress.visible = id != "" and not ready and total > 1
	if progress.visible:
		bar.max_value = float(total)
		bar.value = float(mini(quests.progress_of(id), total))
	row.custom_minimum_size.y = _entry_height(title, objective, progress.visible)

## [title, objective, count] for quest `q` ({}: the empty log's line).
func _texts(q: Dictionary) -> Array:
	if q.is_empty():
		return [tr("No open quests"), tr("Level up to unlock more"), ""]
	var id := String(q.get("id", ""))
	var title := I18n.t(String(q.get("title", "")))
	if quests.is_ready(id):
		return [title, tr("Complete! Click to claim your reward"), ""]
	var total := int(q.get("count", 1))
	var name_text := I18n.t(String(q.get("name", "")))
	if total <= 1:
		return [title, name_text, ""]
	return [title, name_text, "%d/%d" % [mini(quests.progress_of(id), total), total]]

func _entry_height(title: Label, objective: Label, with_bar: bool) -> float:
	var h := maxf(MARK, _text_height(title)) + 1.0 + _text_height(objective)
	if with_bar:
		h += 1.0 + 4.0
	return h + 10.0

## The height quest `q`'s entry takes (the first row's labels measure it).
func _card_height(q: Dictionary) -> float:
	var row: Button = _rows[0]
	var title := row.get_node("Column/Head/Title") as Label
	var objective := row.get_node("Column/Task/Objective") as Label
	var keep := [title.text, objective.text]
	var parts := _texts(q)
	title.text = parts[0]
	objective.text = parts[1]
	var keep_w := objective.custom_minimum_size.x
	objective.custom_minimum_size.x = _objective_width(parts[2] != "")
	var id := String(q.get("id", ""))
	var h := _entry_height(title, objective, id != "" and not quests.is_ready(id) and int(q.get("count", 1)) > 1)
	title.text = keep[0]
	objective.text = keep[1]
	objective.custom_minimum_size.x = keep_w
	return h

## The objective's width: all of the line, less the count's room when it has one.
static func _objective_width(with_count: bool) -> float:
	return WIDTH - INDENT - 8.0 - (COUNT_W if with_count else 0.0)

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

## How many quest entries show now (the checks).
func shown_rows() -> int:
	var n := 0
	for i in _rows.size():
		if (_rows[i] as Button).visible and String(_row_ids[i]) != "":
			n += 1
	return n

func _process(delta: float) -> void:
	_t += delta
	# New and finished quests pulse until they are read / claimed; folded,
	# the header pulses for them.
	var pulse := 0.5 + 0.5 * sin(_t * 4.0)
	for i in _rows.size():
		var row: Button = _rows[i]
		var id := String(_row_ids[i])
		var glow := _glow_of(id)
		var glowing := glow != Color.WHITE and row.visible
		if not glowing and row.get_meta("glowing", true) == false:
			continue
		row.set_meta("glowing", glowing)
		var mark := row.get_node("Column/Head/Mark") as TextureRect
		mark.self_modulate = Color.WHITE.lerp(Color(1.35, 1.3, 1.2), pulse) if glowing else Color.WHITE
		for box: RowBox in _row_boxes[i]:
			box.set_accent(Color(glow, 0.25 + 0.75 * pulse) if glowing else Color(0, 0, 0, 0))
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
## entries as fit between it and the chat.
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
	# its own place, or higher (never above the rail) when the entries need it
	var want := _header.get_combined_minimum_size().y
	for i in (mini(MAX_ROWS, entries.size()) if not collapsed else 0):
		want += sep + _card_height(entries[i])
	if entries.size() > MAX_ROWS and not collapsed:
		want += sep + _more.get_combined_minimum_size().y
	var top := maxf(minf(canvas.y * 0.5 + AT.y, band.y - GAP - want), band.x + GAP)
	var room := band.y - GAP - top
	var x := AT.x
	# what the first entry needs (and the "more" line after it)
	var first := _header.get_combined_minimum_size().y + sep + (_card_height(entries[0]) if not entries.is_empty() else MIN_CARD)
	if entries.size() > 1:
		first += sep + _more.get_combined_minimum_size().y
	if not collapsed and room < first and party.size.y > 0.0:
		# no room for an entry under a big party: beside it
		x = party.end.x + GAP + 4.0
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
		var q: Dictionary = entries[i] if not entries.is_empty() else {}
		_set_row(row, q)
		if q.is_empty():
			row.tooltip_text = ""
		else:
			row.tooltip_text = tr("Click to claim the reward") if quests.is_ready(String(q.get("id", ""))) else tr("Click to read the quest scroll")
		var need := sep + row.custom_minimum_size.y
		var later := entries.size() > i + 1
		if used + need + (more_h if later else 0.0) > room:
			row.visible = false
			continue
		row.visible = true
		if not q.is_empty():
			_row_ids[i] = String(q.get("id", ""))
			shown += 1
		used += need
	var hidden := entries.size() - shown
	_more.visible = not collapsed and hidden > 0 and used + more_h <= room
	_more.text = tr("More quests (%d)  ·  %s") % [hidden, GameSettings.key_name("quest_log")]
	queue_redraw()


## An entry's look: nothing at rest but a slim pulsing line on its left for a
## new or finished quest; under the cursor a gold wash fading to the right.
class RowBox extends StyleBox:
	@export var wash := false
	@export var accent := Color(0, 0, 0, 0)

	func set_accent(c: Color) -> void:
		if c != accent:
			accent = c
			emit_changed()

	func _draw(item: RID, rect: Rect2) -> void:
		if wash:
			var steps := 12
			for i in steps:
				var t := float(i) / steps
				var a := 0.14 * pow(1.0 - t, 1.6)
				RenderingServer.canvas_item_add_rect(item, Rect2(rect.position + Vector2(rect.size.x * t, 0), Vector2(rect.size.x / steps + 0.5, rect.size.y)), Color(0.91, 0.71, 0.32, a))
			RenderingServer.canvas_item_add_rect(item, Rect2(rect.position + Vector2(-4, 3), Vector2(2, rect.size.y - 6)), Color(0.95, 0.78, 0.42, 0.9))
		elif accent.a > 0.0:
			RenderingServer.canvas_item_add_rect(item, Rect2(rect.position + Vector2(-4, 3), Vector2(2, rect.size.y - 6)), accent)
