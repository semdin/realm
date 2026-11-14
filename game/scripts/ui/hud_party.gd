extends Control
class_name HudParty

## Party frames under the player's own frame (the old game's approved rows):
## one ROW_W x ROW_H row per member other than the player, the leader first,
## each with "* Name  Lv N" (gold for the leader), a health bar and a mana bar.
## A fallen member, or one on another map, is drawn at AWAY_ALPHA.
##
## Everything shown is the server's party view (RealmSession.party), handed in
## by `show_party` whenever the session says the party changed; members'
## health and mana come with it about once a second.

## The rows' height changed: where they end now (the tracker below them moves
## out of the way).
signal rows_changed(bottom: float)

const ROW_W := 190.0
const ROW_H := 46.0
const ROW_GAP := 4.0
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
	panel.add_theme_stylebox_override("panel", HudKit.panel(0.78, 5, 0.6))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var name_text := tr("%s%s  Lv %d") % ["* " if leader else "", String(m["name"]), int(m["level"])]
	box.add_child(HudKit.label(name_text, 13, HudKit.GOLD_HI if leader else HudKit.PARCHMENT, HudKit.bold(), 3))
	var health := _bar(9.0, Color(0.75, 0.18, 0.16))
	_fill(health, int(m["hp"]), int(m["max_hp"]))
	box.add_child(health)
	var mana := _bar(6.0, Color(0.18, 0.42, 0.92))
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
	bar.custom_minimum_size = Vector2(ROW_W - 12.0, height)
	HudKit.style_gauge(bar, colour)
	return bar
