extends RefCounted
class_name UIKit

## The interface's control kit: every button, gauge, slider, stepper, swatch,
## tab and checkbox wears these pieces (assets/ui/kit/, drawn by
## tools/art/ui_kit.py). `install` puts them in the shared theme, so a plain
## Button, ProgressBar or HSlider anywhere already has them; HudKit's button
## and gauge helpers hand them out too.
##
## The look (2026-11-21, after AION 2 / Lost Ark / FFXIV): chamfered plates of
## dark blued steel in a thin antique-gold bevel lit from above, with a faint
## inner double rule; the main action in gilt bronze with a warm inner glow and
## gold studs on its ends; the one big action of a screen (Enter World) with
## flourishes beyond its ends; inset grooves for gauges, the fill glossy with
## a hot leading edge; diamond slider grips and gem swatches.
##
## A piece is drawn at 4 px per interface unit and loaded as a texture that
## reports its interface size (ImageTexture size_override): nine-slice margins
## below are interface units, and a large screen still samples real detail.

const DIR := "res://assets/ui/kit/"
const STATES := ["normal", "hover", "pressed", "disabled"]

## id -> [interface size, nine-slice margins (left, top, right, bottom), how
## far the art reaches past the control (halo and shadow room)]. Printed by
## `python tools/art/ui_kit.py --spec`; a plate's states share its row.
const SPEC := {
	"bar_cap_l": [Vector2(18, 24), [], 0],
	"bar_cap_r": [Vector2(18, 24), [], 0],
	"bar_fill": [Vector2(32, 16), [3, 0, 3, 0], 0],
	"bar_gloss": [Vector2(32, 16), [3, 0, 3, 0], 0],
	"bar_spark": [Vector2(12, 24), [], 0],
	"bar_track": [Vector2(64, 16), [5, 4, 5, 4], 0],
	"bar_track_thin": [Vector2(48, 8), [3.5, 2, 3.5, 2], 0],
	"btn": [Vector2(76, 42), [16.5, 12.5, 16.5, 12.5], 6],
	"btn_accent": [Vector2(76, 42), [16.5, 12.5, 16.5, 12.5], 6],
	"btn_blood": [Vector2(76, 42), [16.5, 12.5, 16.5, 12.5], 6],
	"btn_gold": [Vector2(76, 42), [16.5, 12.5, 16.5, 12.5], 6],
	"btn_icon": [Vector2(38, 38), [15, 11, 15, 11], 5],
	"check_off": [Vector2(22, 22), [], 0],
	"check_off_disabled": [Vector2(22, 22), [], 0],
	"check_on": [Vector2(22, 22), [], 0],
	"check_on_disabled": [Vector2(22, 22), [], 0],
	"field_disabled": [Vector2(96, 34), [8, 8, 8, 8], 0],
	"field_focus": [Vector2(96, 34), [8, 8, 8, 8], 0],
	"field_normal": [Vector2(96, 34), [8, 8, 8, 8], 0],
	"gem_next": [Vector2(16, 16), [], 0],
	"gem_off": [Vector2(16, 16), [], 0],
	"gem_on": [Vector2(16, 16), [], 0],
	"ico_chevron_down": [Vector2(20, 20), [], 0],
	"ico_chevron_left": [Vector2(20, 20), [], 0],
	"ico_chevron_right": [Vector2(20, 20), [], 0],
	"ico_chevron_up": [Vector2(20, 20), [], 0],
	"ico_close": [Vector2(16, 16), [], 0],
	"pip_next": [Vector2(14, 9), [], 0],
	"pip_off": [Vector2(14, 9), [], 0],
	"pip_on": [Vector2(14, 9), [], 0],
	"plaque": [Vector2(96, 30), [24, 7, 24, 7], 0],
	"rail_row": [Vector2(120, 40), [10, 4, 70, 4], 0],
	"rail_row_hover": [Vector2(120, 40), [10, 4, 70, 4], 0],
	"slider_fill": [Vector2(40, 10), [5, 4, 5, 4], 0],
	"slider_grip_disabled": [Vector2(26, 26), [], 0],
	"slider_grip_hover": [Vector2(26, 26), [], 0],
	"slider_grip_normal": [Vector2(26, 26), [], 0],
	"slider_track": [Vector2(40, 10), [5, 4, 5, 4], 0],
	"stud": [Vector2(11, 11), [], 0],
	"stud_lit": [Vector2(11, 11), [], 0],
	"swatch_disc": [Vector2(30, 30), [], 0],
	"swatch_glass": [Vector2(30, 30), [], 0],
	"swatch_ring_hover": [Vector2(30, 30), [], 0],
	"swatch_ring_normal": [Vector2(30, 30), [], 0],
	"swatch_ring_selected": [Vector2(30, 30), [], 0],
	"tab_hover": [Vector2(64, 34), [20, 4, 20, 4], 0],
	"tab_mark": [Vector2(10, 10), [], 0],
	"tab_selected": [Vector2(64, 34), [20, 4, 20, 4], 0],
	"toggle_off": [Vector2(40, 22), [], 0],
	"toggle_off_disabled": [Vector2(40, 22), [], 0],
	"toggle_on": [Vector2(40, 22), [], 0],
	"toggle_on_disabled": [Vector2(40, 22), [], 0],
	"wing_l": [Vector2(40, 18), [], 0],
	"wing_l_lit": [Vector2(40, 18), [], 0],
	"wing_r": [Vector2(40, 18), [], 0],
	"wing_r_lit": [Vector2(40, 18), [], 0],
}

## Button text: parchment at rest, gold-white under the cursor.
const TEXT := Color(0.949, 0.910, 0.812)
const TEXT_HOVER := Color(1.0, 0.945, 0.78)
const TEXT_PRESSED := Color(0.91, 0.784, 0.478)
const TEXT_DISABLED := Color(0.52, 0.50, 0.46)
const GOLD_TEXT := Color(1.0, 0.925, 0.72)
## Room a plate's ornaments need beside it (CTA flourishes).
const WING_ROOM := 34.0

static var _tex: Dictionary = {}
static var _boxes: Dictionary = {}
static var _fonts: Dictionary = {}


# ------------------------------------------------------------------ pieces

## Piece `id` as a texture of its interface size, mipmapped (it is drawn at
## 1x-2x of that size from 4x art); null when the art is not in this build.
static func tex(id: String) -> Texture2D:
	if _tex.has(id):
		return _tex[id]
	var out: Texture2D = null
	var path := DIR + id + ".png"
	var row: Array = SPEC.get(_spec_id(id), [])
	if ResourceLoader.exists(path) and not row.is_empty():
		var source := load(path) as Texture2D
		var img := source.get_image() if source != null else null
		if img != null:
			img = img.duplicate() as Image
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			img.generate_mipmaps()
			var t := ImageTexture.create_from_image(img)
			var logical: Vector2 = row[0]
			t.set_size_override(Vector2i(roundi(logical.x), roundi(logical.y)))
			out = t
	_tex[id] = out
	return out

## The SPEC row a file belongs to: a plate's state files share their plate's.
static func _spec_id(id: String) -> String:
	if SPEC.has(id):
		return id
	for state in STATES:
		if id.ends_with("_" + state) and SPEC.has(id.trim_suffix("_" + state)):
			return id.trim_suffix("_" + state)
	return id

## A nine-slice of piece `id` (its SPEC margins and reach).
static func nine(id: String, modulate := Color.WHITE) -> StyleBoxTexture:
	var row: Array = SPEC.get(_spec_id(id), [Vector2.ONE, [], 0])
	var box := StyleBoxTexture.new()
	box.texture = tex(id)
	var m: Array = row[1]
	if m.size() == 4:
		box.texture_margin_left = m[0]
		box.texture_margin_top = m[1]
		box.texture_margin_right = m[2]
		box.texture_margin_bottom = m[3]
	box.set_expand_margin_all(float(row[2]))
	box.modulate_color = modulate
	return box

static func available() -> bool:
	return tex("btn_normal") != null


# ------------------------------------------------------------------ plates

## A button plate: "steel" (every button), "gold" (a window's main action),
## "blood" (an action that cannot be undone), "icon" (square picture
## buttons); `state` one of STATES. `accent` tints a light inside the plate
## (a house or a difficulty colour); `pad` is the content margin.
static func plate(kind: String, state: String, accent := Color(0, 0, 0, 0), pad := Vector2(18, 6)) -> StyleBox:
	var key := "%s/%s/%s/%s" % [kind, state, accent.to_html(), pad]
	if _boxes.has(key):
		return _boxes[key]
	var file: String = {"steel": "btn", "gold": "btn_gold", "blood": "btn_blood", "icon": "btn_icon"}.get(kind, "btn")
	var out: StyleBox
	if tex(file + "_" + state) == null:
		out = _flat_plate(kind, state)
	else:
		var p := Plate.new()
		p.base = nine(file + "_" + state)
		if accent.a > 0.0:
			var a := accent
			if state == "hover":
				a = accent.lightened(0.15)
			elif state == "disabled":
				a = Color(accent, accent.a * 0.35)
			p.accent = nine("btn_accent", a)
		if kind in ["gold", "blood"] and state != "pressed" and state != "disabled":
			p.studs = tex("stud_lit" if state == "hover" else "stud")
		out = p
	out.content_margin_left = pad.x
	out.content_margin_right = pad.x
	out.content_margin_top = pad.y
	out.content_margin_bottom = pad.y + 1.0
	_boxes[key] = out
	return out

## The one big action of a screen (Enter World, Create): a gold plate with a
## flourish beyond each end (keep WING_ROOM free beside it).
static func cta_plate(state: String) -> StyleBox:
	var key := "cta/" + state
	if _boxes.has(key):
		return _boxes[key]
	var p := plate("gold", state, Color(0, 0, 0, 0), Vector2(28, 8))
	if p is Plate:
		var c := Plate.new()
		c.base = (p as Plate).base
		c.studs = null
		var lit := state == "hover"
		if state != "disabled":
			c.wings = [tex("wing_l_lit" if lit else "wing_l"), tex("wing_r_lit" if lit else "wing_r")]
		c.content_margin_left = 28
		c.content_margin_right = 28
		c.content_margin_top = 8
		c.content_margin_bottom = 9
		p = c
	_boxes[key] = p
	return p

## Without the kit's art (a build without it): the old flat plates.
static func _flat_plate(kind: String, state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(4)
	sb.set_border_width_all(1)
	sb.bg_color = {"gold": Color("4a3110"), "blood": Color("4a121a")}.get(kind, Color(0.09, 0.114, 0.165))
	sb.border_color = Color(0.749, 0.604, 0.298) if state != "disabled" else Color(0.3, 0.28, 0.24)
	if state == "hover":
		sb.bg_color = sb.bg_color.lightened(0.12)
	elif state == "pressed":
		sb.bg_color = sb.bg_color.darkened(0.3)
	return sb

## Give `b` the plates of `kind` (and the text colours that go with them).
static func style_button(b: Button, kind := "steel", font_size := 15, accent := Color(0, 0, 0, 0)) -> void:
	for state in STATES:
		b.add_theme_stylebox_override(state, plate(kind, state, accent))
	b.add_theme_stylebox_override("hover_pressed", plate(kind, "pressed", accent))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_font_override("font", UITheme.font_body_bold())
	b.add_theme_font_size_override("font_size", font_size)
	var gilt := kind == "gold"
	b.add_theme_color_override("font_color", GOLD_TEXT if gilt else TEXT)
	b.add_theme_color_override("font_hover_color", Color(1, 0.97, 0.88) if gilt else TEXT_HOVER)
	b.add_theme_color_override("font_pressed_color", TEXT_PRESSED)
	b.add_theme_color_override("font_hover_pressed_color", TEXT_PRESSED)
	b.add_theme_color_override("font_focus_color", GOLD_TEXT if gilt else TEXT)
	b.add_theme_color_override("font_disabled_color", TEXT_DISABLED)
	b.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.03, 0.85))
	b.add_theme_constant_override("outline_size", 3)

static func button(text: String, kind := "steel", font_size := 15) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	style_button(b, kind, font_size)
	return b

## The screen's big action: the heaviest weight, letter-spaced, on the
## flourished gold plate (`text` comes in capitals: I18n.upper, or a
## translated capital line).
static func cta_button(text: String, size := Vector2(360, 58), font_size := 22) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = size
	for state in STATES:
		b.add_theme_stylebox_override(state, cta_plate(state))
	b.add_theme_stylebox_override("hover_pressed", cta_plate("pressed"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_font_override("font", spaced_font(UITheme.W_DECO, 2))
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", GOLD_TEXT)
	b.add_theme_color_override("font_hover_color", Color(1, 0.98, 0.9))
	b.add_theme_color_override("font_pressed_color", TEXT_PRESSED)
	b.add_theme_color_override("font_hover_pressed_color", TEXT_PRESSED)
	b.add_theme_color_override("font_disabled_color", TEXT_DISABLED)
	b.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.0, 0.9))
	b.add_theme_constant_override("outline_size", 4)
	return b

## The game face at `weight` with `spacing` px between letters (capitals).
static func spaced_font(weight: int, spacing: int) -> Font:
	var key := "%d/%d" % [weight, spacing]
	if _fonts.has(key):
		return _fonts[key]
	var base := UITheme.font(weight)
	var out: Font = base
	if base is FontVariation:
		var v := (base as FontVariation).duplicate() as FontVariation
		v.spacing_glyph = spacing
		out = v
	_fonts[key] = out
	return out

## A square picture button (close, arrows, +): the small plate with `icon_id`
## (a kit icon: ico_chevron_left, ico_close, ...) at its centre.
static func icon_button(icon_id: String, px := 30.0, tip := "") -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(px, px)
	b.tooltip_text = tip
	b.icon = tex(icon_id)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.expand_icon = false
	for state in STATES:
		b.add_theme_stylebox_override(state, plate("icon", state, Color(0, 0, 0, 0), Vector2(3, 3)))
	b.add_theme_stylebox_override("hover_pressed", plate("icon", "pressed", Color(0, 0, 0, 0), Vector2(3, 3)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("icon_normal_color", Color(0.92, 0.88, 0.8))
	b.add_theme_color_override("icon_hover_color", Color(1.15, 1.1, 1.0))
	b.add_theme_color_override("icon_pressed_color", Color(0.8, 0.75, 0.65))
	b.add_theme_color_override("icon_disabled_color", Color(0.5, 0.5, 0.5, 0.6))
	return b


# ------------------------------------------------------------------ swatches, tabs, plaques

## A colour choice drawn as a gem: the colour under glass in a metal ring
## (`ring`: "normal", "hover", or "selected" - gold and lit).
static func swatch(colour: Color, ring: String) -> StyleBox:
	var key := "swatch/%s/%s" % [colour.to_html(), ring]
	if _boxes.has(key):
		return _boxes[key]
	var out: StyleBox
	if tex("swatch_disc") == null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = colour
		sb.set_corner_radius_all(15)
		sb.border_color = Color(1, 0.93, 0.73) if ring == "selected" else Color(0, 0, 0, 0.6)
		sb.set_border_width_all(3 if ring == "selected" else 1)
		out = sb
	else:
		var s := Swatch.new()
		s.colour = colour
		s.disc = tex("swatch_disc")
		s.glass = tex("swatch_glass")
		s.ring = tex("swatch_ring_" + ring)
		out = s
	out.set_content_margin_all(0)
	_boxes[key] = out
	return out

## Give swatch button `b` (30 x 30) the gem of `colour`, `selected` or not.
static func style_swatch(b: Button, colour: Color, selected: bool) -> void:
	b.add_theme_stylebox_override("normal", swatch(colour, "selected" if selected else "normal"))
	b.add_theme_stylebox_override("hover", swatch(colour, "selected" if selected else "hover"))
	b.add_theme_stylebox_override("pressed", swatch(colour, "selected"))
	b.add_theme_stylebox_override("hover_pressed", swatch(colour, "selected"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

## A tab's look: "selected" underlined in lit gold with its mark under the
## middle, "hover" a faint line, "normal" nothing.
static func tab(state: String, pad := Vector2(14, 7)) -> StyleBox:
	var key := "tab/%s/%s" % [state, pad]
	if _boxes.has(key):
		return _boxes[key]
	var out: StyleBox
	if state == "normal" or tex("tab_selected") == null:
		out = StyleBoxEmpty.new()
	elif state == "selected":
		var p := Plate.new()
		p.base = nine("tab_selected")
		p.mark = tex("tab_mark")
		out = p
	else:
		out = nine("tab_hover")
	out.content_margin_left = pad.x
	out.content_margin_right = pad.x
	out.content_margin_top = pad.y
	out.content_margin_bottom = pad.y + 2.0
	_boxes[key] = out
	return out

## A toggle Button as a tab (pressed = the shown tab).
static func style_tab(b: Button, font_size := 15, pad := Vector2(14, 7)) -> void:
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", tab("normal", pad))
	b.add_theme_stylebox_override("hover", tab("hover", pad))
	b.add_theme_stylebox_override("pressed", tab("selected", pad))
	b.add_theme_stylebox_override("hover_pressed", tab("selected", pad))
	b.add_theme_stylebox_override("disabled", tab("normal", pad))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_font_override("font", UITheme.font_body_bold())
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", Color(0.62, 0.61, 0.58))
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", Color(1, 0.93, 0.73))
	b.add_theme_color_override("font_hover_pressed_color", Color(1, 0.95, 0.8))
	b.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.03, 0.8))
	b.add_theme_constant_override("outline_size", 2)

## The recessed plate a stepper's value sits on (and any read-only value).
static func plaque(pad := Vector2(12, 4)) -> StyleBox:
	var key := "plaque/%s" % pad
	if _boxes.has(key):
		return _boxes[key]
	var out: StyleBox
	if tex("plaque") == null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.02, 0.03, 0.05, 0.9)
		out = sb
	else:
		out = nine("plaque")
	out.content_margin_left = pad.x
	out.content_margin_right = pad.x
	out.content_margin_top = pad.y
	out.content_margin_bottom = pad.y
	_boxes[key] = out
	return out


# ------------------------------------------------------------------ gauges

## A gauge's groove (thin for bars under 10 units tall; `ornate`: a gold
## blade and diamond beyond each end - the loading bar).
static func track(thin := false, ornate := false) -> StyleBox:
	var key := "track/%s/%s" % [thin, ornate]
	if _boxes.has(key):
		return _boxes[key]
	var out: StyleBox
	if tex("bar_track") == null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.02, 0.024, 0.035, 0.92)
		sb.border_color = Color(0.373, 0.286, 0.137, 0.95)
		sb.set_border_width_all(1)
		out = sb
	elif ornate:
		var p := Plate.new()
		p.base = nine("bar_track")
		p.caps = [tex("bar_cap_l"), tex("bar_cap_r")]
		out = p
	else:
		out = nine("bar_track_thin" if thin else "bar_track")
	out.set_content_margin_all(0)
	_boxes[key] = out
	return out

## A gauge's fill in `colour`: lit top, glossy band, dark foot; `edge` adds
## the hot leading edge (loading, experience).
static func fill(colour: Color, edge := false, inset := 1.5) -> StyleBox:
	var key := "fill/%s/%s/%s" % [colour.to_html(), edge, inset]
	if _boxes.has(key):
		return _boxes[key]
	var out: StyleBox
	if tex("bar_fill") == null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = colour
		out = sb
	else:
		var f := Fill.new()
		f.shade = nine("bar_fill", colour.lightened(0.10))
		f.gloss = nine("bar_gloss")
		f.spark = tex("bar_spark") if edge else null
		f.inset = inset
		out = f
	out.set_content_margin_all(0)
	_boxes[key] = out
	return out

## Style a ProgressBar as a kit gauge in `colour`.
static func style_gauge(bar: ProgressBar, colour: Color, edge := false, ornate := false) -> void:
	var thin := bar.custom_minimum_size.y > 0.0 and bar.custom_minimum_size.y < 10.0
	bar.add_theme_stylebox_override("background", track(thin, ornate))
	bar.add_theme_stylebox_override("fill", fill(colour, edge, 1.0 if thin else 1.5))
	bar.show_percentage = false

## Draw a gauge by hand (a custom Control's _draw): the groove over `rect`,
## the fill over `fraction` of it.
static func draw_gauge(item: CanvasItem, rect: Rect2, fraction: float, colour: Color, edge := false) -> void:
	var thin := rect.size.y < 10.0
	track(thin).draw(item.get_canvas_item(), rect)
	if fraction > 0.0:
		var f := rect
		f.size.x = rect.size.x * clampf(fraction, 0.0, 1.0)
		fill(colour, edge, 1.0 if thin else 1.5).draw(item.get_canvas_item(), f)


# ------------------------------------------------------------------ theme

## Put the kit in `theme`: buttons, option buttons, check boxes and switches,
## sliders, gauges, text fields and tabs.
static func install(theme: Theme) -> void:
	if not available():
		return
	theme.set_type_variation(&"DangerButton", &"Button")
	for entry in [[&"Button", "steel"], [&"MenuButton", "steel"], [&"OptionButton", "steel"],
			[&"PrimaryButton", "gold"], [&"DangerButton", "blood"]]:
		var type: StringName = entry[0]
		var kind: String = entry[1]
		for state in STATES:
			theme.set_stylebox(state, type, plate(kind, state))
		theme.set_stylebox("hover_pressed", type, plate(kind, "pressed"))
		theme.set_stylebox("focus", type, StyleBoxEmpty.new())
		var gilt := kind == "gold"
		theme.set_color("font_color", type, GOLD_TEXT if gilt else TEXT)
		theme.set_color("font_hover_color", type, TEXT_HOVER)
		theme.set_color("font_pressed_color", type, TEXT_PRESSED)
		theme.set_color("font_hover_pressed_color", type, TEXT_PRESSED)
		theme.set_color("font_focus_color", type, GOLD_TEXT if gilt else TEXT)
		theme.set_color("font_disabled_color", type, TEXT_DISABLED)
		theme.set_color("font_outline_color", type, Color(0.02, 0.02, 0.03, 0.85))
		theme.set_constant("outline_size", type, 3)
	theme.set_icon("arrow", &"OptionButton", tex("ico_chevron_down"))
	theme.set_constant("arrow_margin", &"OptionButton", 10)
	for state in STATES:
		theme.set_stylebox(state, &"IconButton", plate("icon", state, Color(0, 0, 0, 0), Vector2(3, 3)))
	theme.set_stylebox("hover_pressed", &"IconButton", plate("icon", "pressed", Color(0, 0, 0, 0), Vector2(3, 3)))
	# check boxes and switches: the picture is the control, no plate behind
	var bare := StyleBoxEmpty.new()
	bare.content_margin_left = 2
	bare.content_margin_right = 4
	bare.content_margin_top = 2
	bare.content_margin_bottom = 2
	for type in [&"CheckBox", &"CheckButton"]:
		for state in STATES + ["hover_pressed", "focus"]:
			theme.set_stylebox(state, type, bare)
		theme.set_color("font_color", type, Color(0.886, 0.867, 0.820))
		theme.set_color("font_hover_color", type, TEXT_HOVER)
		theme.set_color("font_pressed_color", type, TEXT)
		theme.set_color("font_hover_pressed_color", type, TEXT_HOVER)
		theme.set_color("font_disabled_color", type, TEXT_DISABLED)
		theme.set_constant("h_separation", type, 8)
	theme.set_icon("checked", &"CheckBox", tex("check_on"))
	theme.set_icon("unchecked", &"CheckBox", tex("check_off"))
	theme.set_icon("checked_disabled", &"CheckBox", tex("check_on_disabled"))
	theme.set_icon("unchecked_disabled", &"CheckBox", tex("check_off_disabled"))
	theme.set_icon("radio_checked", &"CheckBox", tex("check_on"))
	theme.set_icon("radio_unchecked", &"CheckBox", tex("check_off"))
	theme.set_icon("checked", &"CheckButton", tex("toggle_on"))
	theme.set_icon("unchecked", &"CheckButton", tex("toggle_off"))
	theme.set_icon("checked_disabled", &"CheckButton", tex("toggle_on_disabled"))
	theme.set_icon("unchecked_disabled", &"CheckButton", tex("toggle_off_disabled"))
	theme.set_icon("checked_mirrored", &"CheckButton", tex("toggle_on"))
	theme.set_icon("unchecked_mirrored", &"CheckButton", tex("toggle_off"))
	# sliders: a groove, the gold run up to a diamond grip
	for type in [&"HSlider"]:
		var groove := nine("slider_track")
		groove.content_margin_top = 5
		groove.content_margin_bottom = 5
		theme.set_stylebox("slider", type, groove)
		theme.set_stylebox("grabber_area", type, nine("slider_fill"))
		theme.set_stylebox("grabber_area_highlight", type, nine("slider_fill", Color(1.12, 1.08, 1.0)))
		theme.set_icon("grabber", type, tex("slider_grip_normal"))
		theme.set_icon("grabber_highlight", type, tex("slider_grip_hover"))
		theme.set_icon("grabber_disabled", type, tex("slider_grip_disabled"))
	# gauges
	for entry in [[&"ProgressBar", Color(0.90, 0.68, 0.20)], [&"HpBar", Color(0.86, 0.13, 0.11)],
			[&"ManaBar", Color(0.18, 0.42, 0.92)], [&"ExpBar", Color(0.90, 0.66, 0.16)], [&"BossBar", Color(0.70, 0.10, 0.10)]]:
		theme.set_stylebox("background", entry[0], track())
		theme.set_stylebox("fill", entry[0], fill(entry[1]))
	# text fields
	for type in [&"LineEdit"]:
		var normal := nine("field_normal")
		var focus := nine("field_focus")
		var off := nine("field_disabled")
		for sb in [normal, focus, off]:
			sb.content_margin_left = 10
			sb.content_margin_right = 10
			sb.content_margin_top = 6
			sb.content_margin_bottom = 6
		theme.set_stylebox("normal", type, normal)
		theme.set_stylebox("focus", type, focus)
		theme.set_stylebox("read_only", type, off)
	# tabs: the chosen one underlined in lit gold with its mark
	var chosen := Plate.new()
	chosen.base = nine("tab_selected")
	chosen.mark = tex("tab_mark")
	var hovered := nine("tab_hover")
	var plain := StyleBoxEmpty.new()
	for sb in [chosen, hovered, plain]:
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 7
		sb.content_margin_bottom = 9
	for type in [&"TabBar", &"TabContainer"]:
		theme.set_stylebox("tab_selected", type, chosen)
		theme.set_stylebox("tab_hovered", type, hovered)
		theme.set_stylebox("tab_unselected", type, plain)
		theme.set_stylebox("tab_focus", type, StyleBoxEmpty.new())
		theme.set_color("font_selected_color", type, Color(1, 0.93, 0.73))
		theme.set_color("font_hovered_color", type, TEXT)
		theme.set_color("font_unselected_color", type, Color(0.62, 0.61, 0.58))


# ------------------------------------------------------------------ boxes

## A plate: the nine-sliced state art, and ornaments drawn at their own
## size so a tall or wide control does not stretch them - gold studs on the
## side edges, flourishes beyond the ends, a mark under the middle (a tab).
## Its parts are exported: a duplicate() (UIWindow's close button trims its
## margins on a copy) keeps only stored properties.
class Plate extends StyleBox:
	@export var base: StyleBox
	@export var accent: StyleBox = null
	@export var studs: Texture2D = null
	@export var wings: Array = []
	@export var caps: Array = []
	@export var mark: Texture2D = null

	func _draw(item: RID, rect: Rect2) -> void:
		if caps.size() == 2 and caps[0] != null:
			var cl: Texture2D = caps[0]
			var cr: Texture2D = caps[1]
			var cs := cl.get_size() * clampf(rect.size.y / 12.0, 0.8, 1.4)
			var cy := rect.position.y + (rect.size.y - cs.y) * 0.5
			cl.draw_rect(item, Rect2(Vector2(rect.position.x - cs.x + 2.0, cy), cs), false)
			cr.draw_rect(item, Rect2(Vector2(rect.end.x - 2.0, cy), cs), false)
		if wings.size() == 2 and wings[0] != null:
			var wl: Texture2D = wings[0]
			var wr: Texture2D = wings[1]
			var ws := wl.get_size()
			var wy := rect.position.y + (rect.size.y - ws.y) * 0.5
			wl.draw_rect(item, Rect2(Vector2(rect.position.x - ws.x + 3.0, wy), ws), false)
			wr.draw_rect(item, Rect2(Vector2(rect.end.x - 3.0, wy), ws), false)
		base.draw(item, rect)
		if accent != null:
			accent.draw(item, rect)
		if studs != null:
			var s := studs.get_size()
			var y := rect.position.y + (rect.size.y - s.y) * 0.5
			studs.draw_rect(item, Rect2(Vector2(rect.position.x - s.x * 0.5 + 0.5, y), s), false)
			studs.draw_rect(item, Rect2(Vector2(rect.end.x - s.x * 0.5 - 0.5, y), s), false)
		if mark != null:
			var m := mark.get_size()
			mark.draw_rect(item, Rect2(Vector2(rect.get_center().x - m.x * 0.5, rect.end.y - m.y * 0.5 - 1.6), m), false)

	func _get_draw_rect(rect: Rect2) -> Rect2:
		var r := rect.grow(6.0)
		if wings.size() == 2:
			r = r.grow_individual(WING_ROOM, 0, WING_ROOM, 0)
		return r


## A colour gem: the white disc tinted by the colour, the glass over it and
## the ring, each at its own size in the middle of the control.
class Swatch extends StyleBox:
	@export var colour := Color.WHITE
	@export var disc: Texture2D
	@export var glass: Texture2D
	@export var ring: Texture2D

	func _draw(item: RID, rect: Rect2) -> void:
		var s := disc.get_size()
		var at := Rect2(rect.get_center() - s * 0.5, s)
		disc.draw_rect(item, at, false, colour)
		glass.draw_rect(item, at, false)
		ring.draw_rect(item, at, false)


## A gauge's fill: the white light tinted by the gauge's colour, the gloss
## over it, both inset into the groove, and the hot leading edge.
class Fill extends StyleBox:
	@export var shade: StyleBox
	@export var gloss: StyleBox
	@export var spark: Texture2D = null
	@export var inset := 1.5

	func _draw(item: RID, rect: Rect2) -> void:
		var r := rect.grow(-inset)
		if r.size.x < 1.0 or r.size.y < 1.0:
			return
		shade.draw(item, r)
		gloss.draw(item, r)
		if spark != null and r.size.x > 4.0:
			var h := r.size.y * 1.9
			var w := h * 0.5
			spark.draw_rect(item, Rect2(Vector2(r.end.x - w * 0.5, r.get_center().y - h * 0.5), Vector2(w, h)), false)
