extends Control
class_name HudQuestLog

## The quest log (J): every open quest and every finished one waiting for its
## reward, as small parchment cards three to a row (QuestManager.log_entries
## order - finished first, then new, then the rest), under a summary line. A
## card shows the title, the objective with its live count and the reward; a
## finished card carries a Claim button, any card opens the full scroll. It
## only asks: claiming is QuestManager.claim.

const COLUMNS := 3
const CARD_W := 196.0
const WANTED := Vector2(COLUMNS * (CARD_W + 10) + 48, 560)

var quests: QuestManager
## Opens one quest on the parchment scroll (set by main.gd).
var open_scroll: Callable
var card: UIWindow
var body: VBoxContainer
var _grid: GridContainer
var _summary: Label
var _empty: Label
var _shown := ""
var _cards: Array = []   # [{panel, id, objective}]
## The cards' make-up last built (ids, ready, new) and the counts shown; a
## kill that only moves a count rewrites that card's objective line.
var _shown_cards := ""
var _dirty := true
var _t := 0.0
var _placed := false

func _ready() -> void:
	name = "QuestLog"
	theme = UITheme.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	card = ArcaneSkin.window(I18n.upper(tr("Quests")), WANTED)
	card.name = "Card"
	add_child(card)
	card.closed.connect(hide)
	body = card.body
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_summary = HudKit.label("", 14, HudKit.TEXT_DIM, HudKit.body(), 0)
	body.add_child(_summary)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)
	_empty = HudKit.label(tr("No open quests. Level up to unlock more."), 15, HudKit.TEXT_DIM, HudKit.body(), 0)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_empty)
	var hint := HudKit.label(tr("Click a card to read it  ·  finished quests pay when you claim them  ·  %s / Esc: close") % GameSettings.key_name("quest_log"), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	quests.quest_updated.connect(func(): _dirty = true)
	hide()

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func open() -> void:
	show()
	card.open()
	_shown = ""
	_shown_cards = ""
	_refresh()
	_layout()

func close() -> void:
	card.close()

## Centred the first time; afterwards it stays where the player dragged it.
func _layout() -> void:
	var view := get_viewport().get_visible_rect().size
	var extent := Vector2(WANTED.x, minf(WANTED.y, view.y - 40.0))
	var at := Vector2(card.offset_left, card.offset_top)
	if not _placed:
		_placed = true
		at = ((view - extent) * 0.5).floor()
	ArcaneSkin.place(card, at, extent)

func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	if _dirty:
		_refresh()
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	for entry: Dictionary in _cards:
		var id := String(entry.id)
		var box := (entry.panel as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		if box == null:
			continue
		if quests.is_ready(id):
			box.border_color = Color(HudTracker.READY_GLOW, 0.4 + 0.6 * pulse)
		elif quests.is_new(id):
			box.border_color = Color(HudTracker.NEW_GLOW, 0.4 + 0.6 * pulse)
		else:
			box.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)

## Only what changed: the cards are rebuilt when quests come, finish or are
## read; a count that moves (every kill on a hunting quest) rewrites its line.
## The rebuild used to run on every quest update, and its old cards stayed in
## the grid until the frame's end, so the new ones were laid out after them
## for a frame (the log jumped).
func _refresh() -> void:
	_dirty = false
	var entries: Array = quests.log_entries()
	var cards := str(entries.map(func(q): return [q.id, quests.is_ready(String(q.id)), quests.is_new(String(q.id))]))
	var key := cards + str(entries.map(func(q): return quests.progress_of(String(q.id)))) + str(quests.done_count())
	if key == _shown:
		return
	_shown = key
	var ready := 0
	for q: Dictionary in entries:
		if quests.is_ready(String(q.id)):
			ready += 1
	_summary.text = tr("%d open  ·  %d ready to claim  ·  %d completed") % [entries.size() - ready, ready, quests.done_count()]
	_empty.visible = entries.is_empty()
	if cards == _shown_cards:
		for i in _cards.size():
			var line := quests.objective_text(entries[i])
			var label := _cards[i].objective as Label
			if label.text != line:
				label.text = line
		return
	_shown_cards = cards
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()
	for q: Dictionary in entries:
		_grid.add_child(_card(q))

func _card(q: Dictionary) -> Control:
	var id := String(q.get("id", ""))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CARD_W, 0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.86, 0.78, 0.6)   # parchment
	box.set_border_width_all(2)
	box.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)
	box.set_corner_radius_all(4)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", box)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and open_scroll.is_valid():
			open_scroll.call(id))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)
	var ink := Color(0.22, 0.13, 0.05)
	var tag := I18n.upper(tr("Ready")) if quests.is_ready(id) else (I18n.upper(tr("New")) if quests.is_new(id) else tr("Lv. %d") % int(q.get("level", 1)))
	col.add_child(_ink(tag + "  ·  " + I18n.t(String(q.get("chapter", ""))), 11, Color(0.42, 0.25, 0.08), HudKit.title()))
	col.add_child(_ink(I18n.t(String(q.get("title", ""))), 16, Color(0.36, 0.12, 0.05), HudKit.bold()))
	var objective := _ink(quests.objective_text(q), 13, ink, HudKit.body())
	col.add_child(objective)
	var reward := tr("%d EXP  ·  %d Oril") % [int(q.get("reward_exp", 0)), int(q.get("reward_gold", 0))]
	var items := QuestManager.reward_items_text(q)
	if items != "":
		reward += "\n" + items
	col.add_child(_ink(reward, 12, Color(0.4, 0.28, 0.1), HudKit.body()))
	if quests.is_ready(id):
		var claim := HudKit.button(tr("Claim reward"), 14)
		claim.focus_mode = Control.FOCUS_NONE
		claim.pressed.connect(func(): quests.claim(id))
		col.add_child(claim)
	_cards.append({"panel": panel, "id": id, "objective": objective})
	return panel

func _ink(text: String, size: int, colour: Color, font: Font) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(CARD_W - 20, 0)
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
