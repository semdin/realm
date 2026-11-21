extends RefCounted
class_name HudKit

## The in-game HUD's visual kit: one place for the MMO frame language so the
## unit frame, the action bar, the buff row, the chat, the trackers, the notices,
## the menus and the maps are drawn from the same handful of materials.
##
## The language is the project's "arcane" palette pushed toward a classic MMO
## frame: deep midnight glass, a thin aged-gold bevel, glossy gauges with a lit
## top edge, and text with a soft dark outline so it reads over any terrain.
## Everything is generated in code (no new chrome art), and every font is
## loaded through `ResourceLoader.exists` so the dedicated server - which ships
## no fonts or UI art - never fails to parse a script that uses the kit.

# ------------------------------------------------------------------ colours
const INK := Color(0.035, 0.043, 0.063)
const NAVY := Color(0.055, 0.075, 0.118)
const NAVY_LT := Color(0.098, 0.129, 0.192)
const GOLD_DK := Color(0.373, 0.286, 0.137)
const GOLD := Color(0.749, 0.604, 0.298)
const GOLD_LT := Color(0.910, 0.784, 0.478)
const GOLD_HI := Color(1.0, 0.929, 0.729)
const PARCHMENT := Color(0.949, 0.910, 0.812)
const TEXT := Color(0.886, 0.867, 0.820)
const TEXT_DIM := Color(0.647, 0.635, 0.604)
const SHADOW := Color(0, 0, 0, 0.85)
const RED := Color(0.886, 0.200, 0.176)
const BLUE := Color(0.243, 0.502, 0.949)
const GREEN := Color(0.392, 0.820, 0.341)
const SHOUT := Color(1.0, 0.647, 0.278)
const WHISPER := Color(0.851, 0.569, 1.0)

static var _boxes: Dictionary = {}

# -------------------------------------------------------------------- fonts

## Body copy: chat, tooltips, numbers.
static func body() -> Font:
	return UITheme.font_body()

static func bold() -> Font:
	return UITheme.font_body_bold()

## Captions and window titles: the game face, heavy.
static func title() -> Font:
	return UITheme.font_title()

## Place names and the big zone announcement: the game face, heaviest.
static func deco() -> Font:
	return UITheme.font_deco()

# ------------------------------------------------------------------- labels

## A label that reads over the world: dark outline plus a soft drop shadow.
static func label(text: String, size: int, colour: Color = TEXT, font: Font = null, outline: int = 4) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", font if font != null else body())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", UITheme.outline_for(size, outline))
	# a drop shadow only under text that sits over the world; on a panel it
	# doubled every stroke a pixel or two down and right (the ghosted digits)
	if outline > 0:
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.45))
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", 1)
	return l

static func style_label(l: Control, size: int, colour: Color, font: Font = null, outline: int = 4) -> void:
	l.add_theme_font_override("font", font if font != null else body())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", UITheme.outline_for(size, outline))

# --------------------------------------------------------------- styleboxes

## Midnight glass with a thin gold bevel - the base of every HUD card.
static func panel(alpha: float = 0.88, radius: int = 6, border_alpha: float = 0.85) -> StyleBoxFlat:
	var key := "panel%.2f/%d/%.2f" % [alpha, radius, border_alpha]
	if _boxes.has(key):
		return _boxes[key]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(NAVY.r, NAVY.g, NAVY.b, alpha)
	sb.border_color = Color(GOLD.r, GOLD.g, GOLD.b, border_alpha)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.shadow_color = Color(0, 0, 0, 0.45 * alpha)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0, 2)
	sb.set_content_margin_all(10)
	sb.anti_aliasing = true
	_boxes[key] = sb
	return sb

## A window: same glass, heavier frame, title band drawn by the window itself.
static func window() -> StyleBoxFlat:
	if _boxes.has("window"):
		return _boxes["window"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.039, 0.051, 0.082, 0.96)
	sb.border_color = GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0, 6)
	sb.set_content_margin_all(0)
	_boxes["window"] = sb
	return sb

## Parchment card (quest dialog).
static func parchment() -> StyleBoxFlat:
	if _boxes.has("parchment"):
		return _boxes["parchment"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.886, 0.812, 0.639)
	sb.border_color = Color(0.384, 0.259, 0.114)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(4)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 16
	sb.shadow_offset = Vector2(0, 6)
	sb.set_content_margin_all(0)
	_boxes["parchment"] = sb
	return sb

static func empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()

## Buttons wear the control kit's plates (UIKit): dark blued steel in a thin
## antique-gold bevel, lit on hover.
static func button_box(state: String) -> StyleBox:
	return UIKit.plate("steel", state)

static func style_button(b: Button, size: int = UIKit.FS_BUTTON) -> void:
	UIKit.style_button(b, "steel", mini(size, UIKit.FS_MAIN))

## The window's main action (Upgrade, Enter, Sell): the kit's gilt plate with
## its gold studs; greyed out while disabled.
static func gold_button(text: String, height: float = UIKit.H_MAIN, font_size: int = UIKit.FS_MAIN) -> Button:
	# compact like the Korean MMOs' main buttons: never taller than H_MAIN
	var b := UIKit.button(text, "gold", mini(font_size, 16))
	b.custom_minimum_size = Vector2(0, minf(height, UIKit.H_MAIN))
	b.add_theme_font_override("font", title())
	return b

## A small gold button for a row (Buy): the body face, tight padding.
static func gold_button_small(text: String) -> Button:
	var b := UIKit.button(text, "gold", 13)
	b.add_theme_font_override("font", body())
	b.custom_minimum_size = Vector2(48, 28)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for state in UIKit.STATES:
		b.add_theme_stylebox_override(state, UIKit.plate("gold", state, Color(0, 0, 0, 0), Vector2(11, 3)))
	return b

static func button(text: String, size: int = UIKit.FS_BUTTON) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	style_button(b, size)
	return b

# ------------------------------------------------------------------- gauges

## Gauges are the control kit's (UIKit): an inset groove in a thin gold
## frame, the fill lit on top with a glossy band and a dark foot.
static func gauge_fill(base: Color) -> StyleBox:
	return UIKit.fill(base)

static func gauge_track() -> StyleBox:
	return UIKit.track()

## `edge`: the fill's hot leading edge (a bar that fills up: loading, sleep).
static func style_gauge(bar: ProgressBar, base: Color, edge := false) -> void:
	UIKit.style_gauge(bar, base, edge)

# --------------------------------------------------------------- tooltip

## The HUD tooltip: first line as a gold heading, the rest as body copy, on the
## midnight card. Controls return this from `_make_custom_tooltip`.
static func tooltip(for_text: String, accent: Color = GOLD_LT) -> Control:
	var card := PanelContainer.new()
	var sb := panel(0.96, 5).duplicate() as StyleBoxFlat
	sb.set_content_margin_all(9)
	card.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	card.add_child(box)
	var lines := for_text.split("\n")
	for i in range(lines.size()):
		var line := String(lines[i])
		if i == 0:
			box.add_child(label(line, 15, accent, bold(), 2))
		else:
			var l := label(line, 13, TEXT if i > 1 else Color(0.62, 0.78, 1.0), body(), 0)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 240
			box.add_child(l)
	return card
