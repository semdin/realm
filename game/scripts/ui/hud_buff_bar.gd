extends HBoxContainer
class_name HudBuffBar

## The row of timed effects on the player, under the unit frame (the old
## game's HudBuffBar). Each effect is its own icon; the time gone darkens it
## clockwise from twelve with a bright hairline where the shade ends, the
## seconds left stand beneath it and a tooltip names it; when it ends the icon
## goes. A buff (the ward) has a gold edge, a debuff a red one.
##
## An effect that comes says so here instead of a word over the body: its icon
## comes in large with a white flash and a ring that opens round it; a renewed
## one bumps and flashes again; in its last three seconds it blinks and counts
## tenths.
##
## The effects come from the server's list of what lasts on the player and
## the tick each ends (RealmSession.effects: kind, seconds left), so a stun,
## a web or a ward shows exactly as long as the server holds it; between two
## reads (POLL) the time runs down here.
##
## Cheap by design: the sweep and the flash are one small canvas shader per
## icon fed two numbers a frame (no polygon work), the come-in is the icon's
## scale, the blink its modulate; the icon redraws only while its ring opens
## or when the line under it changes.
##
## While the body rides the broom, the ridden broom's own icon leads the row
## (no timer: the height over the ground under it). Its corner mark says
## whether Shift would land here, live by the server's own rule
## (RealmSession.landing: level ground within 3.1 m under the feet): green
## with a tick, or red with a cross. Its tooltip keeps the controls, the
## height and speed and the landing line up to date while it is open.

const ICON := 34.0
## The line of seconds under a timed icon.
const UNDER := 14.0
## kind -> [icon, title, description, debuff]; the ward's words are the
## spell's own (spells.json).
# i18n-begin
const KINDS := {
	"ward": ["ward_shield", "Ward Shield", "Reflects projectiles; other damage reduced by 60%.", false],
	"stun": ["status_stun", "Stunned", "You cannot cast or move.", true],
	"knock": ["shockwave", "Knocked back", "Thrown off your feet: no casting until you land.", true],
	"freeze": ["frost_grip", "Frozen", "Encased in ice: you cannot cast or move.", true],
	"web": ["status_slow", "Webbed", "Sticky silk: you move at half speed.", true],
	"root": ["status_slow", "Bound", "Held where you stand: you cannot move or jump, but you can still cast.", true],
	"despair": ["status_despair", "Despair", "A Pallid's cold: no natural health recovery.", true],
	"venom": ["mat_weaver_venom", "Poisoned", "Spider venom: damage over time.", true],
	"burn": ["status_burn", "Burning", "Taking fire damage over time.", true],
	"bleed": ["status_bleed", "Bleeding", "Losing health over time.", true],
	"weak": ["status_weakened", "Weakened", "Your spells deal less damage.", true],
}
# i18n-end
## The list is read this often.
const POLL := 0.1

var session: Node
## The sheet (PlayerSheet): which broom is worn.
var sheet: PlayerSheet
var _icons: Dictionary = {}   # kind -> BuffIcon
var _poll := 0.0
## Kinds ever shown (the check reads it).
var shown: Dictionary = {}
## The broom while mounted (null on foot), and how many times its mark
## turned to "cannot land here" (the check reads both).
var broom_icon: BuffIcon
var broom_blocked_shown := 0

func _init() -> void:
	name = "BuffBar"
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	for icon: BuffIcon in _icons.values():
		icon.advance(delta)
	if broom_icon != null:
		broom_icon.advance(delta)
	if session == null:
		return
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL
	refresh(session.effects())
	refresh_broom()

## Show `effects` ([{kind, seconds}]): new icons come, ended ones go.
func refresh(effects: Array) -> void:
	var now := {}
	for e: Dictionary in effects:
		var kind := String(e.get("kind", ""))
		if KINDS.has(kind):
			now[kind] = maxf(float(now.get(kind, 0.0)), float(e.get("seconds", 0.0)))
	_drop_except(now)
	for kind: String in now:
		var icon: BuffIcon = _icons.get(kind)
		var left := float(now[kind])
		if icon == null:
			var look: Array = KINDS[kind]
			icon = _add_icon(kind, String(look[0]), I18n.t(String(look[1])), I18n.t(String(look[2])), bool(look[3]), ICON, UNDER)
			icon.duration = left
		elif left > icon.remaining + 0.25:
			# renewed: the whole length is what it has now
			icon.duration = left
			icon.renew()
		# the largest seen keeps the sweep from jumping back
		icon.duration = maxf(icon.duration, left)
		icon.remaining = left

func _drop_except(keep: Dictionary) -> void:
	for kind: String in _icons.keys():
		if not keep.has(kind):
			remove_child(_icons[kind])   # the others close up this frame, not the next
			(_icons[kind] as Node).queue_free()
			_icons.erase(kind)

func _add_icon(kind: String, picture: String, title: String, desc: String, debuff: bool, side: float, under: float) -> BuffIcon:
	var icon := BuffIcon.new()
	icon.name = "Buff_" + kind
	icon.under = under
	icon.custom_minimum_size = Vector2(side, side + under)
	icon.texture = UITheme.icon_for(picture)
	icon.title = title
	icon.desc = desc
	icon.debuff = debuff
	add_child(icon)
	_icons[kind] = icon
	shown[kind] = true
	return icon

## The broom icon: there while the body rides, first in the row; its picture
## is the worn broom's, its mark and numbers the body's and
## RealmSession.landing's.
func refresh_broom() -> void:
	var body: Dictionary = session.own_body()
	if not bool(body.get("mounted", false)):
		if broom_icon != null:
			remove_child(broom_icon)
			broom_icon.queue_free()
			broom_icon = null
		return
	if broom_icon == null:
		broom_icon = BuffIcon.new()
		broom_icon.name = "Buff_broom"
		broom_icon.mount = true
		broom_icon.custom_minimum_size = Vector2(ICON, ICON + UNDER)
		broom_icon.title = tr("Broom Flight")
		add_child(broom_icon)
		move_child(broom_icon, 0)
		shown["broom"] = true
	var worn := ""
	if sheet != null:
		worn = String((sheet.equipment.get("broom", {}) as Dictionary).get("id", ""))
	if worn != broom_icon.item or broom_icon.texture == null:
		broom_icon.item = worn
		var picture: Texture2D = UITheme.item_icon(worn) if worn != "" else null
		broom_icon.texture = picture if picture != null else UITheme.chrome("status_mounted")
	var land: Dictionary = session.landing()
	var velocity: Vector3 = body.get("velocity", Vector3.ZERO)
	var ok := bool(land.get("ok", false))
	if not ok and broom_icon.landing_ok:
		broom_blocked_shown += 1
	broom_icon.landing_ok = ok
	broom_icon.height = float(land.get("height", -1.0))
	broom_icon.speed = Vector2(velocity.x, velocity.z).length()
	broom_icon.queue_redraw()

## The icons shown now by kind.
func kinds() -> Array:
	return _icons.keys()


class BuffIcon extends Control:
	## The come-in: this long, from this much larger; a renewal's bump.
	const COME_TIME := 0.34
	const COME_SCALE := 0.42
	const RENEW_TIME := 0.22
	const RENEW_SCALE := 0.14
	## The last seconds blink (this many times a second) and count tenths.
	const BLINK_FROM := 3.0
	const BLINK_RATE := 2.6
	## How far the come-in's ring opens past the icon (px).
	const RING_REACH := 11.0
	const SHADER := """shader_type canvas_item;
// The time gone shaded clockwise from twelve over the picture (box: its rect
// in the icon's own space), a bright hairline where the shade ends, and a
// white flash over everything in the box as the icon comes.
uniform vec4 box = vec4(0.0, 0.0, 1.0, 1.0);
uniform float gone = 0.0;
uniform float flash = 0.0;
varying vec2 local;
void vertex() {
	local = VERTEX;
}
void fragment() {
	vec2 rel = (local - box.xy) / box.zw;
	if (rel.x >= 0.0 && rel.y >= 0.0 && rel.x <= 1.0 && rel.y <= 1.0) {
		if (gone > 0.0 && gone < 1.0) {
			vec2 d = rel - 0.5;
			float turn = fract(atan(d.x, -d.y) / 6.2831853 + 1.0);
			float edge = 1.0 - smoothstep(0.0, 0.014, abs(turn - gone));
			COLOR.rgb *= turn < gone ? 0.34 : 1.0;
			COLOR.rgb += vec3(1.0, 0.9, 0.66) * edge * 0.4 * COLOR.a;
		}
		COLOR.rgb = mix(COLOR.rgb, vec3(1.0), flash * COLOR.a);
	}
}
"""
	static var _shader: Shader = null
	static var _plates: Dictionary = {}   # "back" / edge colour -> StyleBoxFlat

	var texture: Texture2D
	var title := ""
	var desc := ""
	var remaining := -1.0
	var duration := 0.0
	var debuff := false
	## The line under the picture (0: none).
	var under := UNDER
	## The broom while mounted: the worn broom's item id, whether Shift would
	## land here, the height over the ground (-1: none under it) and the speed.
	var mount := false
	var item := ""
	var landing_ok := true
	var height := -1.0
	var speed := 0.0
	## Tooltips opened on it (the check reads it).
	var tips := 0
	## Seconds since it came and since it was last renewed.
	var age := 0.0
	var renewed := 99.0
	var _line := ""
	var _shows := -2
	var _gone := -1.0
	var _flash := -1.0
	var _box := Rect2()
	var _material := ShaderMaterial.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		if _shader == null:
			_shader = Shader.new()
			_shader.code = SHADER
		_material.shader = _shader
		material = _material

	func renew() -> void:
		renewed = 0.0

	## One frame: the time runs down, the sweep, the flash, the come-in and
	## the blink follow; a redraw only while the ring opens or the line under
	## it changes.
	func advance(delta: float) -> void:
		age += delta
		renewed += delta
		if remaining > 0.0:
			remaining = maxf(0.0, remaining - delta)
		var gone := clampf(1.0 - remaining / duration, 0.0, 1.0) if duration > 0.0 and remaining >= 0.0 else 0.0
		if absf(gone - _gone) > 0.0015:
			_gone = gone
			_material.set_shader_parameter("gone", gone)
		var come := clampf(age / COME_TIME, 0.0, 1.0)
		var bump := clampf(renewed / RENEW_TIME, 0.0, 1.0)
		if come < 1.0 or bump < 1.0 or _flash != 0.0:
			var flash := maxf(pow(1.0 - come, 2.0) * 0.9, pow(1.0 - bump, 2.0) * 0.5)
			if absf(flash - _flash) > 0.004 or flash == 0.0:
				_flash = flash
				_material.set_shader_parameter("flash", flash)
			scale = Vector2.ONE * (1.0 + COME_SCALE * pow(1.0 - come, 3.0) + RENEW_SCALE * pow(1.0 - bump, 2.0))
		var blink := remaining > 0.0 and remaining < BLINK_FROM
		self_modulate.a = 0.62 + 0.38 * (0.5 + 0.5 * cos(remaining * TAU * BLINK_RATE)) if blink else 1.0
		# the line under it is made again only when what it shows changes
		var shows := -1
		if under > 0.0 and not mount and remaining > 0.0:
			shows = int(remaining * 10.0) if blink else 1000 + int(ceil(remaining))
		if shows != _shows:
			_shows = shows
			_line = _under_text()
			queue_redraw()
		elif come < 1.0:
			queue_redraw()

	func _under_text() -> String:
		if under <= 0.0 or mount or remaining <= 0.0:
			return ""
		return I18n.num(remaining) if remaining < BLINK_FROM else "%ds" % int(ceil(remaining))

	## The broom's tooltip lines: title, flight, controls, landing.
	func broom_lines() -> PackedStringArray:
		var flight := tr("Height %s · speed %s m/s") % [
			(tr("%s m") % I18n.num(height)) if height >= 0.0 else "—", I18n.num(speed)]
		var controls := tr("%s rise · %s descend · %s dismount") % [
			GameSettings.key_name("jump"), GameSettings.key_name("descend"), GameSettings.key_name("ride")]
		return PackedStringArray([title, flight, controls, landing_text()])

	## The landing line as the tooltip says it.
	func landing_text() -> String:
		if landing_ok:
			return tr("Landing here: OK (%s to dismount)") % GameSettings.key_name("ride")
		return tr("Cannot land here: descend near level ground (%s)") % GameSettings.key_name("descend")

	func _get_tooltip(_at: Vector2) -> String:
		if mount:
			return "\n".join(broom_lines())
		var t := title
		if remaining > 0.0:
			t += "  (%ds)" % int(ceil(remaining))
		if desc != "":
			t += "\n" + desc
		return t

	func _make_custom_tooltip(for_text: String) -> Object:
		if mount:
			tips += 1
			return BroomTip.new(self)
		return HudKit.tooltip(for_text, HudKit.RED.lightened(0.3) if debuff else HudKit.GOLD_LT)

	## A rounded plate: the dark back, or an edge in `colour`.
	static func _plate(colour: Color, back: bool) -> StyleBoxFlat:
		var key := "back" if back else colour.to_html()
		if not _plates.has(key):
			var box := StyleBoxFlat.new()
			box.set_corner_radius_all(4)
			box.anti_aliasing = true
			if back:
				box.bg_color = Color(0.035, 0.028, 0.03, 0.82)
			else:
				box.draw_center = false
				box.border_color = colour
				box.set_border_width_all(2)
			_plates[key] = box
		return _plates[key]

	func _draw() -> void:
		var s := minf(size.x, size.y - under)
		var r := Rect2(Vector2((size.x - s) * 0.5, 0), Vector2(s, s))
		var inner := r.grow(-2)
		if inner != _box:
			_box = inner
			_material.set_shader_parameter("box", Vector4(inner.position.x, inner.position.y, inner.size.x, inner.size.y))
			pivot_offset = r.get_center()
		draw_style_box(_plate(Color.BLACK, true), r)
		if texture != null:
			draw_texture_rect(UITheme.drawn_pixels(texture, s - 4.0, self), inner, false)
		var edge := HudKit.RED if debuff else HudKit.GOLD
		draw_style_box(_plate(edge, false), r)
		# the come-in's ring, opening out and fading
		var come := clampf(age / COME_TIME, 0.0, 1.0)
		if come < 1.0:
			var ring := edge.lightened(0.35)
			ring.a = 0.85 * (1.0 - come)
			draw_rect(r.grow(1.0 + RING_REACH * (1.0 - pow(1.0 - come, 2.0))), ring, false, 2.0)
		if mount:
			_draw_landing_mark(r)
			# the height over the ground under it, where the others count down
			if height >= 0.0:
				_draw_under(tr("%s m") % I18n.num(height, 0), s, HudKit.PARCHMENT)
			return
		if _line != "":
			_draw_under(_line, s, HudKit.PARCHMENT if remaining > BLINK_FROM else HudKit.GOLD_HI)

	## A short line centred under the icon.
	func _draw_under(txt: String, s: float, colour: Color) -> void:
		var f := HudKit.bold()
		var fs := 12
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var p := Vector2((size.x - w) * 0.5, s + 12)
		draw_string_outline(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.95))
		draw_string(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)

	## The broom's corner mark: a green disc with a tick where Shift would
	## land, a red one with a cross where it would be refused. Top right: the
	## brooms' pictures run from the top left down to their bristles at the
	## bottom right, so that corner stays clear.
	func _draw_landing_mark(r: Rect2) -> void:
		var radius := 6.5
		var c := Vector2(r.end.x - radius + 1.5, r.position.y + radius - 1.5)
		draw_circle(c, radius + 1.5, Color(0, 0, 0, 0.9))
		draw_circle(c, radius, HudKit.GREEN if landing_ok else HudKit.RED)
		draw_circle(c + Vector2(-1.5, -2.0), radius * 0.45, Color(1, 1, 1, 0.18))
		var ink := Color(1, 1, 1, 0.95)
		if landing_ok:
			draw_polyline(PackedVector2Array([c + Vector2(-3.2, 0.2), c + Vector2(-0.9, 2.6), c + Vector2(3.3, -2.4)]),
				ink, 1.8, true)
		else:
			draw_line(c + Vector2(-2.6, -2.6), c + Vector2(2.6, 2.6), ink, 1.8, true)
			draw_line(c + Vector2(-2.6, 2.6), c + Vector2(2.6, -2.6), ink, 1.8, true)


## The broom's tooltip card, kept up to date while it is open: the height and
## speed change in flight, the landing line turns green or red.
class BroomTip extends PanelContainer:
	var _icon: WeakRef
	var _lines: Array = []   # one Label per line
	var _shown := PackedStringArray()
	var _ok := true

	func _init(icon: BuffIcon) -> void:
		_icon = weakref(icon)
		var sb := HudKit.panel(0.96, 5).duplicate() as StyleBoxFlat
		sb.set_content_margin_all(9)
		add_theme_stylebox_override("panel", sb)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 3)
		add_child(box)
		_lines = [
			HudKit.label("", 15, HudKit.GOLD_LT, HudKit.bold(), 2),
			HudKit.label("", 13, Color(0.62, 0.78, 1.0), HudKit.body(), 0),
			HudKit.label("", 13, HudKit.TEXT, HudKit.body(), 0),
			HudKit.label("", 13, HudKit.GREEN, HudKit.bold(), 0),
		]
		for l: Label in _lines:
			box.add_child(l)
		_update()

	func _process(_delta: float) -> void:
		_update()

	func _update() -> void:
		var icon: BuffIcon = _icon.get_ref()
		if icon == null:
			return
		var lines := icon.broom_lines()
		if lines == _shown and icon.landing_ok == _ok:
			return
		_shown = lines
		_ok = icon.landing_ok
		for i in range(mini(lines.size(), _lines.size())):
			(_lines[i] as Label).text = lines[i]
		(_lines[3] as Label).add_theme_color_override("font_color", HudKit.GREEN if _ok else HudKit.RED.lightened(0.25))
