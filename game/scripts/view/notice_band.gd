extends Control

## The notice band: one short line near the top of the screen for answers
## the windows and the action bar give ("Not enough Oril.", "Sold for 20
## Oril."); the HUD hands its `show_notice` calls here. A new line replaces the
## old one; each fades after a few seconds. What the map announces (a world
## boss stirring, appearing or falling; a Dark Shard's waves and its shatter)
## shows in the boss colour or the stone's emerald and stands a little longer.

const SHOW_SECONDS := 3.0
const ANNOUNCE_SECONDS := 5.0
const FADE_SECONDS := 0.6
const COLOURS := {"good": "gold_hi", "warn": "blood_lt", "info": "parchment"}
const ANNOUNCE_COLOURS := {"boss": Color(1.0, 0.62, 0.95), "stone": Color(0.62, 1.0, 0.68)}

## The line shown last (the check reads it).
var last_text := ""

var _label: Label
var _left := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = UITheme.body("", UITheme.FS_BODY, UITheme.c("parchment"))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_label.position.y = 96.0
	_label.add_theme_constant_override("outline_size", 6)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_label)
	_label.modulate.a = 0.0

func show_notice(text: String, kind := "info") -> void:
	last_text = text
	_label.text = text
	var colour: Color = ANNOUNCE_COLOURS[kind] if ANNOUNCE_COLOURS.has(kind) else UITheme.c(String(COLOURS.get(kind, "parchment")))
	_label.add_theme_color_override("font_color", colour)
	_label.reset_size()
	_label.position.x = (size.x - _label.size.x) * 0.5
	_label.modulate.a = 1.0
	_left = ANNOUNCE_SECONDS if ANNOUNCE_COLOURS.has(kind) else SHOW_SECONDS

func _process(delta: float) -> void:
	if _left <= 0.0:
		return
	_left -= delta
	_label.modulate.a = clampf(_left / FADE_SECONDS, 0.0, 1.0)
