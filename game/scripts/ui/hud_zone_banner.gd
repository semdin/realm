extends Control
class_name HudZoneBanner

## The zone announcement (the old game's): a large engraved title that fades
## in when the player crosses into another named place and fades away again,
## with the hunting grounds' level band under it, tinted against the
## player's level. The place the player logged in or arrived at is not
## announced (the loading screen named the map); the minimap keeps the name
## on screen.

const SHOW := 3.2
const FADE_IN := 0.35
const FADE_OUT := 1.0

var title_label: Label
var sub_label: Label
## What the check reads: the places announced, in order.
var announced: Array = []
var _key := ""
var _timer := 0.0

func _init() -> void:
	name = "ZoneBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _ready() -> void:
	title_label = HudKit.label("", 40, HudKit.GOLD_HI, HudKit.deco(), 8)
	title_label.name = "Title"
	title_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title_label.offset_left = -420.0
	title_label.offset_top = 96.0
	title_label.offset_right = 420.0
	title_label.offset_bottom = 150.0
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.02, 0.9))
	title_label.modulate.a = 0.0
	add_child(title_label)
	sub_label = HudKit.label("", 15, HudKit.PARCHMENT, HudKit.title(), 4)
	sub_label.name = "Band"
	sub_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub_label.offset_left = -300.0
	sub_label.offset_top = 148.0
	sub_label.offset_right = 300.0
	sub_label.offset_bottom = 172.0
	sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_label.modulate.a = 0.0
	add_child(sub_label)

## The place the player stands in now (`title` translated, `hunt` the
## hunting region or {}); a change is announced unless it is the first.
func show_place(title: String, hunt: Dictionary, player_level: int) -> void:
	var key := title + "|" + String(hunt.get("id", ""))
	if key == _key:
		return
	var first := _key == ""
	_key = key
	title_label.text = title
	sub_label.text = ""
	sub_label.add_theme_color_override("font_color", HudKit.PARCHMENT)
	if not hunt.is_empty():
		var lo := int(hunt.get("level_min", 1))
		var hi := int(hunt.get("level_max", lo))
		sub_label.text = tr("Hunting grounds  ·  Lv %d-%d") % [lo, hi]
		sub_label.add_theme_color_override("font_color", MapPlaces.band_color(player_level, lo, hi))
	if not first:
		_timer = SHOW
		announced.append(title)

func is_showing() -> bool:
	return _timer > 0.0

func _process(delta: float) -> void:
	if _timer <= 0.0:
		if title_label.modulate.a != 0.0:
			title_label.modulate.a = 0.0
			sub_label.modulate.a = 0.0
		return
	_timer -= delta
	# fade in quickly, hold, fade out over the last second
	var a := clampf((SHOW - _timer) / FADE_IN, 0.0, 1.0) * clampf(_timer / FADE_OUT, 0.0, 1.0)
	title_label.modulate.a = a
	sub_label.modulate.a = a * 0.9
