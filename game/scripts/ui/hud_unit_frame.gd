extends Control
class_name HudUnitFrame

## The player's unit frame, top-left: a round portrait medallion (house crest in
## a gold ring) with the level badge under it, the name and house beside it, the
## purse under the gauges with the house standing (rank, title and a thin
## reputation bar) beside it, on a plate that fades out to the right; a game
## admin's gilded GA emblem stands after the name. The HP and
## mana gauges are the HUD's own bars; this control draws the frame around them
## and says where they go (`gauge_rect`).

const MEDALLION := 92.0

var player_name := ""
var house := ""
var level := 1
var crest: Texture2D = null
var oril := -1
## House standing from the sheet: rank (0 = not known yet), its title, the
## reputation and the rank's span (`rank_to` -1 at the top rank).
var house_rank := 0
var house_title := ""
var house_rep := 0
var rank_from := 0
var rank_to := -1
var _house_name := ""
var _house_colour := HudKit.TEXT
var _coin: Texture2D = null
var _ring: Texture2D = null
## A game admin (the player info's `ga`): the emblem after the name.
var is_ga := false
var _ga_emblem: Texture2D = null

func _init() -> void:
	name = "UnitFrame"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(350, 110)
	size = custom_minimum_size

func _ready() -> void:
	if ResourceLoader.exists("res://assets/ui/arcane/minimap.png"):
		_ring = ArcaneSkin.texture("minimap")
	_coin = UITheme.chrome_at("oril", 16.0)

func set_oril(amount: int) -> void:
	if amount != oril:
		oril = amount
		queue_redraw()

func set_identity(p_name: String, p_house: String, p_level: int) -> void:
	if p_name == player_name and p_house == house and p_level == level:
		return
	player_name = p_name
	if p_house != house:
		house = p_house
		crest = UITheme.chrome("house_" + house) if house != "" else null
		var houses: Variant = RealmContent.table("houses")
		var data: Dictionary = (houses as Dictionary).get(house, {}) if houses is Dictionary else {}
		_house_name = I18n.t(String(data.get("name", house.capitalize())))
		_house_colour = Color.html(String(data["primary_color"])).lightened(0.35) if data.has("primary_color") else HudKit.TEXT
	level = p_level
	queue_redraw()

func set_ga(on: bool) -> void:
	if on == is_ga:
		return
	is_ga = on
	if on and _ga_emblem == null:
		_ga_emblem = ga_icon(28)
	queue_redraw()

static var _ga_icons := {}

## The GA emblem resampled once to `height` px (the 512 px art drawn small on
## a canvas would shimmer without it); the unit frame and the target card.
static func ga_icon(height: int) -> Texture2D:
	if _ga_icons.has(height):
		return _ga_icons[height]
	var out: Texture2D = null
	if ResourceLoader.exists(HeroView.GA_EMBLEM):
		var source := load(HeroView.GA_EMBLEM) as Texture2D
		var img := source.get_image() if source != null else null
		if img != null:
			if img.is_compressed():
				img.decompress()
			img.resize(maxi(1, roundi(height * float(img.get_width()) / img.get_height())), height, Image.INTERPOLATE_LANCZOS)
			out = ImageTexture.create_from_image(img)
	_ga_icons[height] = out
	return out

func set_house_standing(rank: int, title: String, rep: int, from: int, to: int) -> void:
	if rank == house_rank and title == house_title and rep == house_rep and from == rank_from and to == rank_to:
		return
	house_rank = rank
	house_title = title
	house_rep = rep
	rank_from = from
	rank_to = to
	queue_redraw()

## Where the gauges go, in this control's coordinates.
func gauge_rect() -> Rect2:
	return Rect2(Vector2(MEDALLION + 14, 40), Vector2(size.x - MEDALLION - 26, 42))

func _draw() -> void:
	var m := MEDALLION
	var c := Vector2(m * 0.5 + 4, m * 0.5 + 4)
	# Plate behind name and gauges: navy glass fading to nothing on the right
	# (vertex colours, no banding).
	var plate := Rect2(Vector2(c.x, 16), Vector2(size.x - c.x, 92))
	var x0 := plate.position.x
	var x1 := plate.end.x
	var y0 := plate.position.y
	var y1 := plate.end.y
	var mid := x0 + plate.size.x * 0.62
	var body := Color(0.035, 0.047, 0.075, 0.82)
	var clear := Color(0.035, 0.047, 0.075, 0.0)
	draw_polygon(PackedVector2Array([Vector2(x0, y0), Vector2(mid, y0), Vector2(mid, y1), Vector2(x0, y1)]), PackedColorArray([body, body, body, body]))
	draw_polygon(PackedVector2Array([Vector2(mid, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(mid, y1)]), PackedColorArray([body, clear, clear, body]))
	var gold := Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.9)
	var gold_clear := Color(gold.r, gold.g, gold.b, 0.0)
	for yy in [y0, y1 - 1.5]:
		draw_polygon(PackedVector2Array([Vector2(x0, yy), Vector2(x1, yy), Vector2(x1, yy + 1.5), Vector2(x0, yy + 1.5)]), PackedColorArray([gold, gold_clear, gold_clear, gold]))
	# Medallion: dark disc, crest, ring.
	draw_circle(c, m * 0.5 - 2, Color(0.024, 0.031, 0.051, 0.96))
	draw_circle(c, m * 0.5 - 8, Color(0.075, 0.098, 0.153, 1.0))
	if crest != null:
		# whole pixels: the crest is resampled to exactly this size
		var cs := roundf(m * 0.62)
		draw_texture_rect(UITheme.drawn_pixels(crest, cs, self), Rect2((c - Vector2(cs, cs) * 0.5).round(), Vector2(cs, cs)), false)
	if _ring != null:
		draw_texture_rect(_ring, Rect2(c - Vector2(m, m) * 0.5, Vector2(m, m)), false)
	else:
		draw_arc(c, m * 0.5 - 3, 0, TAU, 64, HudKit.GOLD, 3.0, true)
	# Level badge.
	var bc := c + Vector2(0, m * 0.5 - 4)
	draw_circle(bc, 15, Color(0, 0, 0, 0.6))
	draw_circle(bc, 13.5, Color(0.10, 0.07, 0.04))
	draw_arc(bc, 13.5, 0, TAU, 40, HudKit.GOLD_LT, 2.0, true)
	var lv := str(level)
	var lf := HudKit.bold()
	var ls := 15 if lv.length() < 3 else 12
	var lw := lf.get_string_size(lv, HORIZONTAL_ALIGNMENT_LEFT, -1, ls).x
	var lp := bc + Vector2(-lw * 0.5, ls * 0.36)
	draw_string_outline(lf, lp, lv, HORIZONTAL_ALIGNMENT_LEFT, -1, ls, 3, Color(0, 0, 0))
	draw_string(lf, lp, lv, HORIZONTAL_ALIGNMENT_LEFT, -1, ls, HudKit.GOLD_HI)
	# Name and house.
	var nf := HudKit.title()
	var np := Vector2(MEDALLION + 14, 34)
	draw_string_outline(nf, np, player_name, HORIZONTAL_ALIGNMENT_LEFT, 170, 18, 4, Color(0, 0, 0, 0.9))
	draw_string(nf, np, player_name, HORIZONTAL_ALIGNMENT_LEFT, 170, 18, HudKit.GOLD_HI)
	if is_ga and _ga_emblem != null:
		var name_w := minf(170.0, nf.get_string_size(player_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x)
		var eh := 28.0
		var ew := eh * _ga_emblem.get_width() / maxf(1.0, _ga_emblem.get_height())
		draw_texture_rect(_ga_emblem, Rect2(Vector2(np.x + name_w + 6.0, np.y - eh * 0.78), Vector2(ew, eh)), false)
	if _house_name != "":
		var hf := HudKit.bold()
		var hw := hf.get_string_size(_house_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var hp := Vector2(size.x - hw - 14, 33)
		draw_string_outline(hf, hp, _house_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.9))
		draw_string(hf, hp, _house_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, _house_colour)
		if house_rank > 0:
			_draw_house_standing(_house_colour)
	# Purse, under the gauges.
	if oril >= 0:
		var text := thousands(oril)
		var gf := HudKit.bold()
		var gp := Vector2(MEDALLION + 34, 100)
		if _coin != null:
			draw_texture_rect(_coin, Rect2(Vector2(MEDALLION + 14, 87), Vector2(16, 16)), false)
		draw_string_outline(gf, gp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color(0, 0, 0, 0.9))
		draw_string(gf, gp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.GOLD_LT)

## Rank title and a thin reputation bar, right-aligned on the purse line.
func _draw_house_standing(colour: Color) -> void:
	var text := tr("Rank %d · %s") % [house_rank, I18n.t(house_title)]
	var f := HudKit.bold()
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var right := size.x - 14
	var p := Vector2(right - w, 98)
	draw_string_outline(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.9))
	draw_string(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, colour)
	var pct := 1.0 if rank_to < 0 else clampf(float(house_rep - rank_from) / maxf(1.0, float(rank_to - rank_from)), 0.0, 1.0)
	var bar := Rect2(Vector2(right - w, 102), Vector2(w, 3))
	draw_rect(bar, Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * pct, bar.size.y)), colour)

static func thousands(v: int) -> String:
	return I18n.whole(v)
