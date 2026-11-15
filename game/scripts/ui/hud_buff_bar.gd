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

const ICON := 34.0
## kind -> [icon, title, description, debuff]; the ward's words are the
## spell's own (spells.json).
# i18n-begin
const KINDS := {
	"ward": ["ward_shield", "Ward Shield", "Reflects projectiles; other damage reduced by 60%.", false],
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
var _icons: Dictionary = {}   # kind -> BuffIcon
var _poll := 0.0
## Kinds ever shown (the check reads it).
var shown: Dictionary = {}

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

## Show `effects` ([{kind, seconds}]): new icons come, ended ones go.
func refresh(effects: Array) -> void:
	var now := {}
	for e: Dictionary in effects:
		var kind := String(e.get("kind", ""))
		if KINDS.has(kind):
			now[kind] = maxf(float(now.get(kind, 0.0)), float(e.get("seconds", 0.0)))
	for kind: String in _icons.keys():
		if not now.has(kind):
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

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _get_tooltip(_at: Vector2) -> String:
		var t := title
		if remaining > 0.0:
			t += "  (%ds)" % int(ceil(remaining))
		if desc != "":
			t += "\n" + desc
		return t

	func _make_custom_tooltip(for_text: String) -> Object:
		return HudKit.tooltip(for_text, HudKit.RED.lightened(0.3) if debuff else HudKit.GOLD_LT)

	func _draw() -> void:
		var s := minf(size.x, size.y - 14)
		var r := Rect2(Vector2((size.x - s) * 0.5, 0), Vector2(s, s))
		draw_rect(r, Color(0, 0, 0, 0.7))
		if texture != null:
			draw_texture_rect(texture, r.grow(-2), false)
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
		# The seconds left under the icon.
		if remaining > 0.0:
			var txt := ("%.1f" % remaining) if remaining < 3.0 else "%ds" % int(ceil(remaining))
			var f := HudKit.bold()
			var fs := 12
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var p := Vector2((size.x - w) * 0.5, s + 12)
			draw_string_outline(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.95))
			draw_string(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudKit.PARCHMENT if remaining > 3.0 else HudKit.GOLD_HI)
