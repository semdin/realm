extends HBoxContainer
class_name HudBuffBar

## The row of timed effects under the unit frame (the old game's HudBuffBar):
## each effect is an icon whose shadow grows clockwise as its time runs out,
## with the seconds left beneath it and a tooltip that names it; when it ends
## the icon goes. A buff (the ward) has a gold edge, a debuff a red one.
##
## Everything comes from the server's list of what lasts on the player and
## the tick each ends (RealmSession.effects: kind, seconds left), so a stun,
## a web or a ward shows exactly as long as the server holds it.
##
## While the body rides the broom, the ridden broom's own icon leads the row
## (no timer: the height over the ground under it). Its corner mark says
## whether Shift would land here, live by the server's own rule
## (RealmSession.landing: level ground within 3.1 m under the feet): green
## with a tick, or red with a cross. Its tooltip keeps the controls, the
## height and speed and the landing line up to date while it is open.

const ICON := 34.0
## kind -> [icon, title, description, debuff]; the ward's words are the
## spell's own (spells.json).
# i18n-begin
const KINDS := {
	"ward": ["ward_shield", "Ward Shield", "Reflects projectiles; other damage reduced by 60%.", false],
	"shardglass_ward": ["shardglass_ward", "Shardglass Ward", "Reflects a duel foe's bolts; other damage reduced by 35%.", false],
	"stun": ["status_stun", "Stunned", "You cannot cast or move.", true],
	"knock": ["status_stun", "Knocked back", "Thrown off your feet: no casting until you land.", true],
	"freeze": ["status_stun", "Frozen", "Encased in ice: you cannot cast or move.", true],
	"web": ["status_stun", "Webbed", "Sticky silk: you move at half speed.", true],
	"despair": ["status_despair", "Despair", "A Pallid's cold: no natural health recovery.", true],
	"venom": ["status_burn", "Poisoned", "Spider venom: damage over time.", true],
	"burn": ["status_burn", "Burning", "Taking fire damage over time.", true],
	"bleed": ["status_burn", "Bleeding", "Losing health over time.", true],
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
	for kind: String in _icons.keys():
		if not now.has(kind):
			remove_child(_icons[kind])   # the others close up this frame, not the next
			(_icons[kind] as Node).queue_free()
			_icons.erase(kind)
	for kind: String in now:
		var look: Array = KINDS[kind]
		var icon: BuffIcon = _icons.get(kind)
		if icon == null:
			icon = BuffIcon.new()
			icon.name = "Buff_" + kind
			icon.custom_minimum_size = Vector2(ICON, ICON + 14)
			icon.texture = UITheme.icon_for(String(look[0]))
			icon.title = I18n.t(String(look[1]))
			icon.desc = I18n.t(String(look[2]))
			icon.debuff = bool(look[3])
			add_child(icon)
			_icons[kind] = icon
			shown[kind] = true
		# The whole length is what it had when it began; the largest seen
		# keeps the sweep from jumping back when a new one replaces it.
		var left := float(now[kind])
		if left > icon.remaining + 0.25:
			icon.duration = left
		icon.duration = maxf(icon.duration, left)
		icon.remaining = left
		icon.queue_redraw()

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
		broom_icon.custom_minimum_size = Vector2(ICON, ICON + 14)
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
	var texture: Texture2D
	var title := ""
	var desc := ""
	var remaining := -1.0
	var duration := 0.0
	var debuff := false
	## The broom while mounted: the worn broom's item id, whether Shift would
	## land here, the height over the ground (-1: none under it) and the speed.
	var mount := false
	var item := ""
	var landing_ok := true
	var height := -1.0
	var speed := 0.0
	## Tooltips opened on it (the check reads it).
	var tips := 0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

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

	func _draw() -> void:
		var s := minf(size.x, size.y - 14)
		var r := Rect2(Vector2((size.x - s) * 0.5, 0), Vector2(s, s))
		draw_rect(r, Color(0, 0, 0, 0.7))
		if texture != null:
			draw_texture_rect(UITheme.drawn_pixels(texture, s - 4.0, self), r.grow(-2), false)
		# The time gone shaded, growing clockwise from twelve.
		if duration > 0.0 and remaining >= 0.0:
			var elapsed := clampf(1.0 - remaining / duration, 0.0, 1.0)
			if elapsed > 0.0:
				var c := r.get_center()
				var pts := PackedVector2Array([c])
				var steps := maxi(3, int(40 * elapsed))
				for i in range(steps + 1):
					var a := -PI * 0.5 + TAU * elapsed * float(i) / float(steps)
					pts.append(c + Vector2(cos(a), sin(a)) * s)
				var inner := r.grow(-2)
				var sq := PackedVector2Array([inner.position, Vector2(inner.end.x, inner.position.y), inner.end,
					Vector2(inner.position.x, inner.end.y)])
				for poly in Geometry2D.intersect_polygons(pts, sq):
					draw_colored_polygon(poly, Color(0, 0, 0, 0.62))
		draw_rect(r, HudKit.RED if debuff else HudKit.GOLD, false, 1.5)
		if mount:
			_draw_landing_mark(r)
			# the height over the ground under it, where the others count down
			if height >= 0.0:
				_draw_under(tr("%s m") % I18n.num(height, 0), s, HudKit.PARCHMENT)
			return
		# The seconds left under the icon.
		if remaining > 0.0:
			var txt := I18n.num(remaining) if remaining < 3.0 else "%ds" % int(ceil(remaining))
			_draw_under(txt, s, HudKit.PARCHMENT if remaining > 3.0 else HudKit.GOLD_HI)

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
