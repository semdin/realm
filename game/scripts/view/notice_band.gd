extends Control

## The notice band: one short line near the top of the screen for answers
## the windows give ("Not enough Oril.", "Sold for 20 Oril."). Windows find it
## as the sibling named "HUD" and call `show_notice`. A new line replaces the
## old one; each fades after a few seconds.

const SHOW_SECONDS := 3.0
const FADE_SECONDS := 0.6
const COLOURS := {"good": "gold_hi", "warn": "blood_lt", "info": "parchment"}

var _label: Label
var _left := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
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
	_label.text = text
	_label.add_theme_color_override("font_color", UITheme.c(String(COLOURS.get(kind, "parchment"))))
	_label.reset_size()
	_label.position.x = (size.x - _label.size.x) * 0.5
	_label.modulate.a = 1.0
	_left = SHOW_SECONDS

func _process(delta: float) -> void:
	if _left <= 0.0:
		return
	_left -= delta
	_label.modulate.a = clampf(_left / FADE_SECONDS, 0.0, 1.0)
