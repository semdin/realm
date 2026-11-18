extends CanvasLayer
class_name FloatingText

## The floating combat text: what a hit did, what healed, a word over a body.
##
## Drawn by the 2D canvas at each anchor's projected point, like the nameplates
## and under the HUD: no 3D frame in between, so the figures stay crisp at any
## render scale and no fog, tonemap or glow reaches them. One canvas item draws
## them all from a fixed pool (MAX_POPS): no node, material or shader per
## number; each is shaped once (a TextLine kept with its pool slot) and then
## only moved. The face is the distance-field Literata with tabular lining
## figures, so a figure scales and slides smoothly and a total that grows does
## not jitter.
##
## The look, loudest first: a critical hit is warm gold, larger, with a short
## scale pop; a normal hit of the player's is a calm warm white; a blow taken
## is a muted red beside the hero, healing a soft green on its other side; what
## other people do, damage over time and misses are small and quiet. The edge
## is a thin dark line in a soft shade, no plate behind the figures.
##
## A figure stands beside the body it belongs to (past the body's width on
## screen, alternating sides) and rises from there, so it does not cover what
## is being fought; one whose rise would run into the body's nameplate starts
## lower and ends under the plate; a figure that would land on another starts
## under it (the older one is ahead on the same curve, so they never meet), and
## quick repeats on one body add up into one figure (`merge`).
##
## One size on screen at any distance (a little smaller far away), following
## the window's height and the interface scale.

enum Style { HIT, FINISHER, CRIT, TAKEN, TAKEN_CRIT, HEAL, ALLY, ALLY_CRIT, ALLY_TAKEN, TICK, QUIET, WORD }

## A plain hit's letters at a 900 px window and interface scale 1 (canvas
## pixels); the window's height scales them within UNIT_MIN..UNIT_MAX.
const BASE_PX := 27.5
const REF_HEIGHT := 900.0
const UNIT_MIN := 0.85
const UNIT_MAX := 2.4
## The size every line is shaped at (the canvas transform scales it: distance
## field glyphs stay sharp).
const SHAPE_PX := 32
## The pool; past SOFT_CAP the quiet kinds are not shown at all.
const MAX_POPS := 64
const SOFT_CAP := 36
## Seconds the rise takes (it eases out), and the slow drift that goes on after
## it, per second in px at unit 1.
const RISE_TIME := 0.55
const DRIFT := 9.0
const FADE_IN := 0.05
## The last share of a life is the fade.
const FADE_SHARE := 0.34
## Figures start this share of the way to their side and spread to it.
const SPREAD_FROM := 0.74
## Clear space between a body's edge and the figure beside it (px at unit 1),
## how far a body's half width counts on screen, the step down between rows of
## figures on one side, and how many steps a figure takes to get clear.
const BODY_GAP := 12.0
const HALF_MIN := 6.0
const HALF_MAX := 60.0
const ROW_STEP := 20.0
const CLEAR_STEPS := 3
## Half the height a nameplate takes on the canvas, and the air over it.
const PLATE_HALF := 22.0
const PLATE_GAP := 3.0
## How far past the window's sides an anchor still shows.
const SIDE_MARGIN := 80.0
## A fan starts over when its body was quiet this long.
const FAN_REST := 0.7
## From this far away figures shrink, to FAR_SCALE at FAR_DISTANCE.
const NEAR_DISTANCE := 14.0
const FAR_DISTANCE := 50.0
const FAR_SCALE := 0.8
## Past this nobody needs the figure: the player's own, anyone else's.
const OWN_REACH := 90.0
const OTHER_REACH := 46.0
## Bands of the canvas the HUD holds: figures are gone before they reach them.
const HUD_TOP := 118.0
const HUD_FADE := 44.0
## A merged figure's little bump.
const BUMP_TIME := 0.12
const BUMP_SIZE := 0.1
## The edge: the widths are outline sizes at SHAPE_PX.
const EDGE_WIDTH := 4
const SHADE_NEAR := 8
const SHADE_FAR := 14
const SHADE_DROP := 1.2

const WARM_WHITE := Color(0.965, 0.935, 0.865)
const GOLD := Color(1.0, 0.79, 0.38)
const GOLD_FLASH := Color(1.0, 0.95, 0.8)
const MUTED_RED := Color(0.93, 0.43, 0.37)
const SOFT_GREEN := Color(0.62, 0.89, 0.64)
const STONE_WHITE := Color(0.82, 0.8, 0.75)
const PALE_GOLD := Color(0.9, 0.78, 0.55)
const DUSK_ROSE := Color(0.78, 0.56, 0.52)
const EMBER := Color(0.88, 0.68, 0.5)
const MIST := Color(0.76, 0.8, 0.84)
const INK := Color(0.075, 0.05, 0.04)
const INK_GOLD := Color(0.17, 0.085, 0.02)
const INK_RED := Color(0.16, 0.035, 0.03)
const INK_GREEN := Color(0.03, 0.09, 0.05)

## size: of BASE_PX; rise: px at unit 1; life: seconds; merge: seconds within
## which another of its kind on one body adds in (0: never); rank: drawn in
## this order, 0 also the first to go in a crowd; open: the scale it opens at
## (0: the critical hit's pop); shade: how much of the soft dark round the
## glyphs.
const STYLES := {
	Style.HIT: {"size": 1.0, "rise": 40.0, "life": 0.85, "merge": 0.13, "rank": 1, "open": 0.88,
		"fill": WARM_WHITE, "ink": INK, "shade": 1.0},
	Style.FINISHER: {"size": 1.08, "rise": 44.0, "life": 0.92, "merge": 0.0, "rank": 1, "open": 0.84,
		"fill": WARM_WHITE, "ink": INK, "shade": 1.0},
	Style.CRIT: {"size": 1.24, "rise": 50.0, "life": 1.15, "merge": 0.0, "rank": 2, "open": 0.0,
		"fill": GOLD, "ink": INK_GOLD, "shade": 1.0},
	Style.TAKEN: {"size": 0.92, "rise": 30.0, "life": 0.95, "merge": 0.13, "rank": 2, "open": 0.88,
		"fill": MUTED_RED, "ink": INK_RED, "shade": 1.0},
	Style.TAKEN_CRIT: {"size": 1.12, "rise": 36.0, "life": 1.1, "merge": 0.0, "rank": 2, "open": 0.0,
		"fill": MUTED_RED, "ink": INK_RED, "shade": 1.0},
	Style.HEAL: {"size": 0.92, "rise": 34.0, "life": 1.05, "merge": 0.4, "rank": 1, "open": 0.88,
		"fill": SOFT_GREEN, "ink": INK_GREEN, "shade": 1.0},
	Style.ALLY: {"size": 0.72, "rise": 26.0, "life": 0.7, "merge": 0.32, "rank": 0, "open": 0.92,
		"fill": STONE_WHITE, "ink": INK, "shade": 0.55},
	Style.ALLY_CRIT: {"size": 0.84, "rise": 30.0, "life": 0.8, "merge": 0.0, "rank": 0, "open": 0.86,
		"fill": PALE_GOLD, "ink": INK_GOLD, "shade": 0.55},
	Style.ALLY_TAKEN: {"size": 0.68, "rise": 24.0, "life": 0.65, "merge": 0.32, "rank": 0, "open": 0.92,
		"fill": DUSK_ROSE, "ink": INK_RED, "shade": 0.55},
	Style.TICK: {"size": 0.68, "rise": 18.0, "life": 0.62, "merge": 0.75, "rank": 0, "open": 0.94,
		"fill": EMBER, "ink": INK, "shade": 0.5},
	Style.QUIET: {"size": 0.7, "rise": 22.0, "life": 0.8, "merge": 0.0, "rank": 0, "open": 0.94,
		"fill": MIST, "ink": INK, "shade": 0.55},
	Style.WORD: {"size": 0.72, "rise": 28.0, "life": 1.3, "merge": 0.0, "rank": 1, "open": 0.92,
		"fill": WARM_WHITE, "ink": INK, "shade": 0.8},
}

## Every digit and sign a figure uses, and the letters words use: shaped ahead
## of the first fight (a glyph's distance field is made when first met).
const FIGURES := "0123456789.,+"
const LETTERS := "ABCÇDEFGĞHIİJKLMNOÖPQRSŞTUÜVWXYZabcçdefgğhıijklmnoöpqrsştuüvwxyz!:()-'"

class Pop:
	var line := TextLine.new()
	var width := 0.0
	var height := 0.0
	var style := 0
	var key := 0
	var value := 0
	var anchor := Vector3.ZERO
	## The body the anchor rides on, and the anchor's offset from it.
	var body: Node3D = null
	var offset := Vector3.ZERO
	var lane := Vector2.ZERO
	var px := 0.0
	var rise := 0.0
	var life := 1.0
	var rank := 0
	var opening := 1.0
	var fill := Color.WHITE
	var ink := Color.BLACK
	var shade := 1.0
	var age := 0.0
	## Since the last amount was added.
	var touched := 0.0
	## This frame, for the draw.
	var at := Vector2.ZERO
	var scale := 1.0
	var alpha := 0.0
	var tint := Color.WHITE

static var _active: FloatingText = null

var _canvas: Control
var _font: Font
var _word_font: Font
var _live: Array[Pop] = []
var _free: Array[Pop] = []
## Per body (`key`): [figures so far, seconds since the last].
var _fans: Dictionary = {}
var _unit := 1.0

static func enabled() -> bool:
	return DisplayServer.get_name() != "headless"

## A figure for `amount` on the body `key`, anchored at `at` (world space).
## `body` (may be null) carries the anchor along; `girth` is its half width in
## metres; `side` puts the figure right (1) or left (-1) of it, 0 alternates;
## `plate` is how far over `at` its nameplate stands (0: none; below `at`,
## negative: a word over a plate stays clear above it).
static func figure(style: int, amount: int, key: int, at: Vector3, body: Node3D = null, girth := 0.45, side := 0, plate := 0.0) -> void:
	if _active != null:
		_active._add(style, amount, _figure_text(style, amount), key, at, body, girth, side, plate)

## A short word in place of a figure ("Evaded"), placed like one.
static func note(text: String, key: int, at: Vector3, body: Node3D = null, girth := 0.45, plate := 0.0) -> void:
	if _active != null:
		_active._add(Style.QUIET, 0, text, key, at, body, girth, 0, plate)

## A word over `at` (world space): a status, a level, a title. `scale_mult`
## sizes it, `seconds` > 0 is how long it stays, `plate` as for a figure; its
## colour is calmed to sit with the rest.
static func word(at: Vector3, text: String, colour := WARM_WHITE, scale_mult := 1.0, seconds := 0.0, plate := 0.0) -> void:
	if _active == null:
		return
	var pop := _active._add(Style.WORD, 0, text, 0, at, null, 0.0, 2, plate, scale_mult)
	if pop != null:
		pop.fill = _calm(colour)
		if seconds > 0.0:
			pop.life = seconds

## Every style drawn once and every glyph made (ShaderWarmup, behind the
## loading screen).
static func warm() -> void:
	if _active != null:
		_active._warm()

static func _figure_text(style: int, amount: int) -> String:
	return ("+" if style == Style.HEAL else "") + I18n.whole(amount)

## At most this saturated and never dark: a pure red or yellow from a caller
## reads as neon over the world.
static func _calm(colour: Color) -> Color:
	return Color.from_hsv(colour.h, minf(colour.s, 0.58), clampf(colour.v, 0.8, 0.98))

func _init() -> void:
	name = "FloatingText"
	# over the nameplates (0), under the low-health edge (4) and the HUD (5)
	layer = 1

func _enter_tree() -> void:
	_active = self

func _exit_tree() -> void:
	if _active == self:
		_active = null

func _ready() -> void:
	_font = UITheme.world_font(UITheme.W_BOLD, true)
	_word_font = UITheme.world_font(UITheme.W_BOLD)
	_canvas = Control.new()
	_canvas.name = "TextCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_all)
	add_child(_canvas)
	for i in MAX_POPS:
		_free.append(Pop.new())
	if enabled():
		_shape_glyphs(_font, FIGURES)
	set_process(false)

func _shape_glyphs(font: Font, glyphs: String) -> void:
	var line := TextLine.new()
	line.add_string(glyphs, font, SHAPE_PX)
	line.get_size()

func _warm() -> void:
	if not enabled():
		return
	_shape_glyphs(_word_font, LETTERS + FIGURES)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position - cam.global_basis.z * 7.0
	for style: int in STYLES:
		_add(style, 1234, _figure_text(style, 1234), -1 - style, at, null, 0.4, 0)

## How large things are this frame: a share of the window's height, in canvas
## pixels (so the interface scale multiplies it).
func _measure() -> void:
	var view := get_viewport().get_visible_rect().size.y * get_tree().root.content_scale_factor
	_unit = clampf(view / REF_HEIGHT, UNIT_MIN, UNIT_MAX)

func _add(style: int, value: int, text: String, key: int, at: Vector3, body: Node3D, girth: float, side: int, plate := 0.0, scale_mult := 1.0) -> Pop:
	if not enabled():
		return null
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(at):
		return null
	var data: Dictionary = STYLES[style]
	var rank := int(data["rank"])
	var distance := cam.global_position.distance_to(at)
	if distance > (OTHER_REACH if rank == 0 else OWN_REACH):
		return null
	if value > 0 and _merged(style, key, value, float(data["merge"])):
		return null
	if rank == 0 and _live.size() >= SOFT_CAP:
		return null
	var pop := _take(rank)
	if pop == null:
		return null
	_measure()
	pop.style = style
	pop.key = key
	pop.value = value
	pop.age = 0.0
	pop.touched = 0.0
	pop.anchor = at
	pop.body = body
	pop.offset = at - body.global_position if body != null else Vector3.ZERO
	pop.rise = float(data["rise"])
	pop.life = float(data["life"])
	pop.rank = rank
	pop.opening = float(data["open"])
	pop.fill = data["fill"]
	pop.ink = data["ink"]
	pop.shade = float(data["shade"])
	var far := remap(clampf(distance, NEAR_DISTANCE, FAR_DISTANCE), NEAR_DISTANCE, FAR_DISTANCE, 1.0, FAR_SCALE)
	pop.px = BASE_PX * float(data["size"]) * far * scale_mult
	_shape(pop, text)
	pop.lane = _lane(cam, pop, at, girth, side, plate)
	pop.at = cam.unproject_position(at) + pop.lane
	pop.alpha = 0.0
	_live.append(pop)
	set_process(true)
	return pop

## A quick repeat on one body joins the figure already rising there.
func _merged(style: int, key: int, value: int, window: float) -> bool:
	if window <= 0.0:
		return false
	for pop: Pop in _live:
		if pop.key == key and pop.style == style and pop.touched <= window:
			pop.value += value
			pop.touched = 0.0
			pop.life = maxf(pop.life, pop.age + float(STYLES[style]["life"]) * 0.8)
			_shape(pop, _figure_text(style, pop.value))
			return true
	return false

## A free slot, or the oldest figure of the lowest rank at or under `rank`.
func _take(rank: int) -> Pop:
	if not _free.is_empty():
		return _free.pop_back()
	for wanted in rank + 1:
		for i in _live.size():
			if _live[i].rank == wanted:
				var pop: Pop = _live[i]
				_live.remove_at(i)
				pop.body = null
				return pop
	return null

func _shape(pop: Pop, text: String) -> void:
	pop.line.clear()
	pop.line.add_string(text, _font if pop.style != Style.WORD and pop.value > 0 else _word_font, SHAPE_PX)
	var size := pop.line.get_size()
	pop.width = size.x
	pop.height = size.y

## Where a new figure stands from its anchor, in canvas pixels: beside the body
## (`side` 1 right, -1 left, 0 alternating, 2 straight over the anchor), a row
## lower each round of the fan, low enough that its rise ends under the
## nameplate (a word placed over a plate: above it), and clear of any figure
## already there.
func _lane(cam: Camera3D, pop: Pop, at: Vector3, girth: float, side: int, plate: float) -> Vector2:
	var p := cam.unproject_position(at)
	var k := _size_of(pop) / float(SHAPE_PX)
	var box := Vector2(pop.width, pop.height * 0.74) * k
	var lane := Vector2.ZERO
	if side != 2:
		var fan: Array = _fans.get(pop.key, [0, 0.0])
		if float(fan[1]) > FAN_REST:
			fan[0] = 0
		var count := int(fan[0])
		fan[0] = count + 1
		fan[1] = 0.0
		_fans[pop.key] = fan
		var along := side if side != 0 else (1 if count % 2 == 0 else -1)
		var row := (count / 2) % 3 if side == 0 else count % 3
		var half := absf(cam.unproject_position(at + cam.global_basis.x * girth).x - p.x)
		half = clampf(half, HALF_MIN * _unit, HALF_MAX * _unit)
		lane = Vector2(along * (half + BODY_GAP * _unit + box.x * 0.5), row * ROW_STEP * _unit)
	var step := box.y
	if plate != 0.0:
		var plate_y := cam.unproject_position(at + Vector3.UP * plate).y
		var bottom := p.y + lane.y + box.y * 0.5
		if plate > 0.0:
			var climb := (pop.rise + DRIFT * pop.life) * _unit
			if bottom - box.y - climb < plate_y + PLATE_HALF and bottom > plate_y - PLATE_HALF:
				lane.y = plate_y + PLATE_HALF + PLATE_GAP + box.y * 0.5 + climb - p.y
		elif bottom > plate_y - PLATE_HALF:
			lane.y = plate_y - PLATE_HALF - PLATE_GAP - box.y * 0.5 - p.y
			step = -box.y
	for attempt in CLEAR_STEPS:
		var mine := Rect2(p + lane - box * 0.5, box)
		var clear := true
		for other: Pop in _live:
			if (other.alpha > 0.15 or other.age < 0.1) and mine.intersects(_rect_of(other)):
				clear = false
				break
		if clear:
			break
		lane.y += step
	return lane

func _size_of(pop: Pop) -> float:
	return pop.px * _unit

func _rect_of(pop: Pop) -> Rect2:
	var k := _size_of(pop) / float(SHAPE_PX)
	var box := Vector2(pop.width, pop.height * 0.74) * k
	return Rect2(pop.at - box * 0.5, box)

func _process(delta: float) -> void:
	_measure()
	var cam := get_viewport().get_camera_3d()
	var canvas := get_viewport().get_visible_rect().size
	var kept := 0
	for i in _live.size():
		var pop: Pop = _live[i]
		pop.age += delta
		pop.touched += delta
		if pop.age >= pop.life:
			pop.body = null
			_free.append(pop)
			continue
		_live[kept] = pop
		kept += 1
		if cam != null:
			_step(pop, cam, canvas)
	_live.resize(kept)
	for key: int in _fans.keys():
		var fan: Array = _fans[key]
		fan[1] = float(fan[1]) + delta
		if float(fan[1]) > FAN_REST:
			_fans.erase(key)
	_canvas.queue_redraw()
	if _live.is_empty():
		_fans.clear()
		set_process(false)

func _step(pop: Pop, cam: Camera3D, canvas: Vector2) -> void:
	var t := pop.age
	pop.alpha = 0.0
	if is_instance_valid(pop.body):
		pop.anchor = pop.body.global_position + pop.offset
	if cam.is_position_behind(pop.anchor):
		return
	var base := cam.unproject_position(pop.anchor)
	if base.x < -SIDE_MARGIN or base.x > canvas.x + SIDE_MARGIN:
		return
	var eased := 1.0 - pow(1.0 - minf(t / RISE_TIME, 1.0), 3.0)
	var climb := (pop.rise * eased + DRIFT * t) * _unit
	# a tall body's head out of view, or under the bars: the figure stays on
	# the free part of the screen
	var floor_y := canvas.y - (UITheme.DECK_BOTTOM + UITheme.DECK_H + 12.0)
	base.y = clampf(base.y, HUD_TOP + HUD_FADE + pop.rise * _unit, maxf(floor_y - HUD_FADE, HUD_TOP + HUD_FADE + pop.rise * _unit))
	pop.at = base + Vector2(pop.lane.x * lerpf(SPREAD_FROM, 1.0, eased), pop.lane.y - climb)
	var bump := maxf(0.0, 1.0 - pop.touched / BUMP_TIME) * BUMP_SIZE if t > BUMP_TIME else 0.0
	pop.scale = _scale_at(pop, t) + bump
	var fade_from := pop.life * (1.0 - FADE_SHARE)
	pop.alpha = smoothstep(0.0, FADE_IN, t) * (1.0 - smoothstep(fade_from, pop.life, t)) \
		* smoothstep(HUD_TOP, HUD_TOP + HUD_FADE, pop.at.y)
	pop.tint = GOLD_FLASH.lerp(pop.fill, smoothstep(0.03, 0.2, t)) if pop.fill == GOLD else pop.fill

## The opening: a plain figure settles up from `opening`; a critical one
## (`opening` 0) starts small, passes its size and comes back.
static func _scale_at(pop: Pop, t: float) -> float:
	if pop.opening > 0.0:
		return lerpf(pop.opening, 1.0, 1.0 - pow(1.0 - minf(t / 0.09, 1.0), 2.0))
	if t < 0.075:
		return lerpf(0.72, 1.16, 1.0 - pow(1.0 - t / 0.075, 2.0))
	return lerpf(1.16, 1.0, smoothstep(0.075, 0.24, t))

func _draw_all() -> void:
	var rid := _canvas.get_canvas_item()
	for rank in 3:
		for pop: Pop in _live:
			if pop.rank == rank and pop.alpha > 0.004:
				_draw_pop(rid, pop)
	RenderingServer.canvas_item_add_set_transform(rid, Transform2D.IDENTITY)

func _draw_pop(rid: RID, pop: Pop) -> void:
	var k := _size_of(pop) * pop.scale / float(SHAPE_PX)
	RenderingServer.canvas_item_add_set_transform(rid, Transform2D(0.0, Vector2(k, k), 0.0, pop.at))
	var at := Vector2(-pop.width, -pop.height) * 0.5
	var ink := pop.ink
	ink.a = pop.alpha * pop.alpha * 0.17 * pop.shade
	pop.line.draw_outline(rid, at + Vector2(0.0, SHADE_DROP), SHADE_FAR, ink)
	ink.a = pop.alpha * pop.alpha * 0.34 * pop.shade
	pop.line.draw_outline(rid, at + Vector2(0.0, SHADE_DROP * 0.5), SHADE_NEAR, ink)
	ink.a = pop.alpha * 0.86
	pop.line.draw_outline(rid, at, EDGE_WIDTH, ink)
	var fill := pop.tint
	fill.a = pop.alpha
	pop.line.draw(rid, at, fill)
