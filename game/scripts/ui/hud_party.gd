extends Control
class_name HudParty

## Party frames under the player's own frame: one ROW_W x ROW_H row per
## member other than the player, the leader first, drawn the way AION 2 and
## Lost Ark draw theirs - no boxes, type and slim gauges over a soft dark
## wash: the name (gold, with a gold mark, for the leader), the level on the
## right, a health line and a thinner mana line under it. A fallen member, or
## one on another map, is drawn at AWAY_ALPHA.
##
## Everything shown is the server's party view (RealmSession.party), handed in
## by `show_party` whenever the session says the party changed; members'
## health and mana come with it about once a second.

## The rows' height changed: where they end now (the tracker below them moves
## out of the way).
signal rows_changed(bottom: float)

const ROW_W := 190.0
const ROW_H := 34.0
const ROW_GAP := 6.0
const AT := Vector2(14.0, 178.0)
const AWAY_ALPHA := 0.45

## The map this client stands on (a member elsewhere is drawn away).
var map_name := ""
var _rows: VBoxContainer
var _view: Dictionary = {"party": 0}
## The members other than the player, leader first.
var _shown: Array = []
## Rows are rebuilt only when what they say in text changes (members, leader,
## names, levels, away or fallen); health and mana move the bars in place.
var _rows_key := ""
var _row_bars: Dictionary = {}
var _back: StyleBox

func _init() -> void:
	name = "PartyFrames"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = AT
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", int(ROW_GAP))
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rows)
	_back = UIKit.nine("rail_back") if UIKit.tex("rail_back") != null else null

## The soft dark wash behind the rows (the quest tracker's).
func _draw() -> void:
	if _back == null or _rows.get_child_count() == 0:
		return
	var h := _rows.get_combined_minimum_size().y
	_back.draw(get_canvas_item(), Rect2(Vector2(-position.x, -8.0), Vector2(position.x + ROW_W + 50.0, h + 16.0)))

## The server's party view: {party, leader, me, members}.
func show_party(view: Dictionary) -> void:
	_view = view
	var me := int(view.get("me", 0))
	var leader := int(view.get("leader", 0))
	_shown = (view.get("members", []) as Array).filter(func(m): return int(m["character"]) != me)
	_shown.sort_custom(func(a, b): return int(a["character"]) == leader and int(b["character"]) != leader)
	_rebuild()

func in_party() -> bool:
	return int(_view.get("party", 0)) != 0

func is_leader() -> bool:
	return in_party() and int(_view.get("leader", 0)) == int(_view.get("me", 0))

## The members other than the player, leader first.
func shown_members() -> Array:
	return _shown

## The member called `who` (any member, the player included), or {}.
func member_named(who: String) -> Dictionary:
	for m: Dictionary in _view.get("members", []):
		if String(m["name"]) == who:
			return m
	return {}

func row_count() -> int:
	return _row_bars.size()

## Where the last row ends on the canvas (the frames' top with no rows).
func rows_bottom() -> float:
	return position.y + (_rows.get_combined_minimum_size().y if _rows.get_child_count() > 0 else 0.0)

func _rebuild() -> void:
	var key := ""
	if in_party():
		key = str(_view.get("leader", 0))
		for m: Dictionary in _shown:
			key += "|%d:%s:%d:%s:%s" % [int(m["character"]), String(m["name"]), int(m["level"]), str(bool(m["dead"])),
				str(String(m["map"]) != map_name)]
	if key == _rows_key and key != "":
		for m: Dictionary in _shown:
			var bars: Array = _row_bars.get(int(m["character"]), [])
			if bars.size() == 2:
				_fill(bars[0], int(m["hp"]), int(m["max_hp"]))
				_fill(bars[1], int(m["mana"]), int(m["max_mana"]))
		return
	_rows_key = key
	_row_bars.clear()
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if in_party():
		var leader := int(_view.get("leader", 0))
		for m: Dictionary in _shown:
			_rows.add_child(_member_row(m, int(m["character"]) == leader, String(m["map"]) != map_name))
	queue_redraw()
	_say_bottom.call_deferred()

## Where the rows end, once they are laid out.
func _say_bottom() -> void:
	rows_changed.emit(AT.y + (_rows.get_combined_minimum_size().y if _rows.get_child_count() > 0 else 0.0))

static func _fill(bar: ProgressBar, value: int, most: int) -> void:
	bar.max_value = maxf(1.0, float(most))
	bar.value = float(value)

func _member_row(m: Dictionary, leader: bool, away: bool) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(ROW_W, ROW_H)
	var bare := StyleBoxEmpty.new()
	bare.content_margin_left = 2
	bare.content_margin_right = 4
	panel.add_theme_stylebox_override("panel", bare)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(head)
	if leader and UIKit.tex("tab_mark") != null:
		var crown := TextureRect.new()
		crown.texture = UIKit.tex("tab_mark")
		crown.custom_minimum_size = Vector2(10, 10)
		crown.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		crown.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		crown.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		crown.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crown.tooltip_text = tr("Party leader")
		head.add_child(crown)
	var who := HudKit.label(String(m["name"]), 13, Color(1.0, 0.86, 0.56) if leader else Color(0.93, 0.91, 0.86), HudKit.bold(), 3)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(who)
	head.add_child(HudKit.label(tr("Lv %d") % int(m["level"]), 12, Color(0.78, 0.72, 0.60), HudKit.body(), 3))
	var health := _bar(6.0, Color(0.86, 0.16, 0.15))
	_fill(health, int(m["hp"]), int(m["max_hp"]))
	box.add_child(health)
	var mana := _bar(3.0, Color(0.22, 0.50, 0.98))
	_fill(mana, int(m["mana"]), int(m["max_mana"]))
	box.add_child(mana)
	_row_bars[int(m["character"])] = [health, mana]
	if bool(m["dead"]) or away:
		panel.modulate = Color(1, 1, 1, AWAY_ALPHA)
	return panel

static func _bar(height: float, colour: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.custom_minimum_size = Vector2(ROW_W - 8.0, height)
	HudKit.style_gauge(bar, colour)
	return bar
