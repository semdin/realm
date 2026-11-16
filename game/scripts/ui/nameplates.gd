extends CanvasLayer
class_name Nameplates

## The overhead nameplates (the old game's WorldLabels): other players' and
## the player's own name, level, house and newest title, the GA emblem, and the
## creatures' "[Lv.N] Name" in their elite / boss / enraged colours.
##
## Drawn by the 2D canvas at each body's projected anchor, not as Label3D: a
## 3D label goes through everything the 3D frame does (tonemapping, fog, glow
## from a sunlit rock behind it, mip blur once small), so names washed into
## whatever stood behind them at range. Here they are the HUD's own crisp
## glyphs and outlines at every distance and over every background, a little
## smaller with distance (REF_DISTANCE, MIN_SCALE .. MAX_SCALE), hidden past
## their range or behind the camera, far ones under near ones.
##
## A crowd does not pile its names into one smear: nearer plates claim their
## screen space first and a creature's plate that would overlap one already
## placed is left out that frame (players' plates and the target's always
## show).
##
## One canvas item draws every plate in one pass. Each line is shaped once
## into a TextLine and kept until its text or its on-screen size changes; a
## frame only projects anchors and sorts the plates in view (no allocation per
## plate per frame). A hero's duel mark tints its name and its GA emblem
## floats over the plate (HeroView keeps both as its source of truth with
## `screen_plate`). On a headless run nothing is drawn, but the plates are
## still kept (the checks read `text_of`).
##
## Objects and people that carry their own label (an NPC's name, a training
## dummy's or a Dark Shard's health) put it up here too (`put`), held at one
## size on screen like the Label3D overlays they replace: those were drawn
## into the 3D frame, so on the low preset (77 % render scale, bilinear
## upscale, FXAA) their letters came out soft and grainy.

const REF_DISTANCE := 7.0
const MIN_SCALE := 0.62
const MAX_SCALE := 1.08
const PLAYER_RANGE := 55.0
const CREATURE_RANGE := 40.0
## Over a hero's feet: the name line's centre (the old NAMEPLATE_HEIGHT plus
## the name's lift), and how much higher it rides on a broom.
const HERO_HEIGHT := 2.22
const MOUNT_LIFT := 0.38
const OUTLINE := Color(0.02, 0.015, 0.01, 0.92)
const SHADOW := Color(0, 0, 0, 0.45)
const GA_EMBLEM := "res://assets/ui/ga_emblem.png"
## The emblem's height on screen at the reference distance, and its float.
const GA_PX := 30.0
const GA_FLOAT_PX := 3.0
const CREST_GAP := 4.0

## Line looks the plates use.
const NAME_PX := 20.0
const SUB_PX := 14.0
const TITLE_PX := 14.0
const OWN_NAME := Color(1.0, 0.88, 0.58)
const OTHER_NAME := Color(0.96, 0.96, 0.94)
const TITLE_TINT := Color(1.0, 0.8, 0.42)
const DUEL_FOE := Color(1.0, 0.36, 0.30)
const DUEL_OUT := Color(0.62, 0.58, 0.56)
const CREATURE_TINT := Color(1.0, 0.6, 0.5)
const ELITE_TINT := Color(1.0, 0.9, 0.35)
const BOSS_TINT := Color(1.0, 0.72, 0.25)
const CREATURE_PX := 14.0
const BOSS_PX := 17.0

## One plate: what it is anchored to and its lines, top to bottom. `name_line`
## is the line centred on the anchor (the others stack above and below it in
## screen pixels, so they never collide at any distance).
class Plate:
	var node: Node3D
	var hero: HeroView
	var height := 0.0
	var reach := PLAYER_RANGE
	## [text, px, colour, bold]
	var lines: Array = []
	var name_line := 0
	var crest: Texture2D
	var crest_line := -1
	var hidden := false
	## one size on screen at every distance (an object's own plate)
	var fixed := false
	## this frame: screen point (x, y) and camera distance (z)
	var at := Vector3.ZERO
	var id := 0
	var shaped: Array = []
	## each line's height on screen at the shaped size
	var heights := PackedFloat32Array()
	var shaped_px := -1

static var _ga_texture: Texture2D
## The objects' own plates (`put`), by their node's instance id. Static, so a
## view built before this layer (or across a map's reload) still shows.
static var _own: Dictionary = {}

var _plates: Dictionary = {}
var _drawn: Array = []
var _placed: Array[Rect2] = []
## The target's entity (main.gd): its plate is never left out.
var focus_id := 0
var _canvas: Control
var _t := 0.0

static func enabled() -> bool:
	return DisplayServer.get_name() != "headless"

func _init() -> void:
	name = "Nameplates"
	# under the HUD (5) and its windows: a window opened over the world covers
	# the names behind it
	layer = 0

func _ready() -> void:
	_canvas = Control.new()
	_canvas.name = "PlateCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_plates)
	add_child(_canvas)
	set_process(enabled())

## A player's plate: its newest title over the name, the name, and under it
## the crest with "Lv. N · House" in the house colour. `own` gives the name the
## player's own gold.
func set_player(id: int, hero: HeroView, who_name: String, level: int, house: String, title: String, own: bool) -> void:
	var lines: Array = []
	var name_line := 0
	if title != "":
		lines.append(["« %s »" % title, TITLE_PX, TITLE_TINT, true])
		name_line = 1
	lines.append([who_name, NAME_PX, OWN_NAME if own else OTHER_NAME, true])
	var tint := FrontDoor.house_color(house).lightened(0.42) if house != "" else Color(0.85, 0.85, 0.85)
	var sub := tr("Lv. %d  ·  %s") % [level, HudQuestScroll.house_name(house)] if house != "" else tr("Lv. %d") % level
	lines.append([sub, SUB_PX, tint, true])
	var plate := _plate(id, hero, HERO_HEIGHT, PLAYER_RANGE, lines, name_line)
	plate.hero = hero
	plate.crest = UITheme.icon_for("house_" + house) if house != "" else null
	plate.crest_line = lines.size() - 1

## A creature's plate: "[Lv.N] Name" over its head (no level before the server
## said it), boss / elite / ordinary in the old game's colours and sizes.
func set_creature(id: int, body: Node3D, height: float, title: String, level: int, elite: bool, boss: bool) -> void:
	var text := tr("[Lv.%d] %s") % [level, title] if level > 0 else title
	var tint := BOSS_TINT if boss else (ELITE_TINT if elite else CREATURE_TINT)
	_plate(id, body, height, CREATURE_RANGE, [[text, BOSS_PX if boss else CREATURE_PX, tint, true]], 0)

## An object's own plate over `node` (`height` metres over its origin, shown
## within `reach` metres): its lines top to bottom, [text, px, colour, bold]
## each, the whole plate centred on the anchor (as the Label3D was), at one
## size on screen. Call again
## when the text changes; the plate goes with the node.
static func put(node: Node3D, height: float, reach: float, lines: Array) -> void:
	var id := node.get_instance_id()
	var plate: Plate = _own.get(id)
	if plate == null:
		plate = Plate.new()
		plate.id = id
		plate.fixed = true
		_own[id] = plate
	plate.node = node
	plate.height = height
	plate.reach = reach
	if lines != plate.lines:
		plate.lines = lines
		plate.shaped_px = -1

## Hide an object's own plate without forgetting it (a Dark Shard falling in).
static func hide_own(node: Node3D, on: bool) -> void:
	var plate: Plate = _own.get(node.get_instance_id())
	if plate != null:
		plate.hidden = on

## An object's own plate's lines joined by " / " ("" when it has none).
static func own_text(node: Node3D) -> String:
	var plate: Plate = _own.get(node.get_instance_id())
	if plate == null:
		return ""
	return " / ".join(plate.lines.map(func(line): return String(line[0])))

func _plate(id: int, node: Node3D, height: float, reach: float, lines: Array, name_line: int) -> Plate:
	var plate: Plate = _plates.get(id)
	if plate == null or plate.node != node:
		plate = Plate.new()
		plate.id = id
		_plates[id] = plate
	plate.node = node
	plate.height = height
	plate.reach = reach
	plate.name_line = name_line
	if lines != plate.lines:
		plate.lines = lines
		plate.shaped_px = -1
	return plate

func remove(id: int) -> void:
	_plates.erase(id)

## Hide a plate without forgetting it (a fallen creature).
func set_hidden(id: int, on: bool) -> void:
	var plate: Plate = _plates.get(id)
	if plate != null:
		plate.hidden = on

func has_plate(id: int) -> bool:
	return _plates.has(id)

## The plate's lines joined by " / " ("" when there is none): what the checks
## read.
func text_of(id: int) -> String:
	var plate: Plate = _plates.get(id)
	if plate == null:
		return ""
	return " / ".join(plate.lines.map(func(line): return String(line[0])))

## Whether plate `id` was drawn on the last frame (in range, in front).
func is_drawn(id: int) -> bool:
	var plate: Plate = _plates.get(id)
	return plate != null and _drawn.has(plate)

func _process(delta: float) -> void:
	_t += delta
	_drawn.clear()
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var from := cam.global_position
		var view := get_viewport().get_visible_rect().grow(120.0)
		for plates: Dictionary in [_plates, _own]:
			for id: int in plates.keys():
				var plate: Plate = plates[id]
				if not is_instance_valid(plate.node):
					plates.erase(id)
					continue
				if plate.hidden or not plate.node.is_visible_in_tree():
					continue
				var anchor := plate.node.global_position + Vector3(0, plate.height, 0)
				if plate.hero != null:
					anchor.y += plate.hero.mount_blend * MOUNT_LIFT
				if cam.is_position_behind(anchor):
					continue
				var distance := from.distance_to(anchor)
				if distance > plate.reach:
					continue
				var p := cam.unproject_position(anchor)
				if not view.has_point(p):
					continue
				plate.at = Vector3(p.x, p.y, distance)
				_drawn.append(plate)
		# far plates first, so nearer ones are drawn over them
		_drawn.sort_custom(func(a: Plate, b: Plate): return a.at.z > b.at.z)
		_declutter()
	_canvas.queue_redraw()

## Nearest first, each plate claims its box on screen; a creature's plate over
## a box already claimed is dropped (a player's, an object's own or the
## target's never is).
func _declutter() -> void:
	_placed.clear()
	for i in range(_drawn.size() - 1, -1, -1):
		var plate: Plate = _drawn[i]
		var box := _box(plate)
		if plate.hero == null and not plate.fixed and plate.id != focus_id and _overlaps(box):
			_drawn.remove_at(i)
			continue
		_placed.append(box)

func _overlaps(box: Rect2) -> bool:
	for placed: Rect2 in _placed:
		if placed.intersects(box):
			return true
	return false

## The plate's box on screen this frame (its lines shaped at its size).
func _box(plate: Plate) -> Rect2:
	var k := _plate_scale(plate)
	_shape(plate, k)
	var w := 0.0
	var h := 0.0
	for i in plate.shaped.size():
		w = maxf(w, (plate.shaped[i] as TextLine).get_size().x)
		h += plate.heights[i]
	return Rect2(plate.at.x - w * 0.5, _top(plate), w, h)

## The plate's top on screen: its name line centred on the anchor (the rest
## stacked around it), or an object's whole plate centred on it.
static func _top(plate: Plate) -> float:
	var top := plate.at.y - float(plate.heights[plate.name_line]) * 0.5
	for i in plate.name_line:
		top -= float(plate.heights[i])
	if plate.fixed:
		var h := 0.0
		for line_h in plate.heights:
			h += line_h
		top = plate.at.y - h * 0.5
	return top

static func _scale(distance: float) -> float:
	return clampf(REF_DISTANCE / maxf(distance, 0.01), MIN_SCALE, MAX_SCALE)

static func _plate_scale(plate: Plate) -> float:
	return 1.0 if plate.fixed else _scale(plate.at.z)

## The plate's lines shaped at `k` (kept until the size or the text changes).
func _shape(plate: Plate, k: float) -> void:
	var key := roundi(NAME_PX * k)
	if key == plate.shaped_px:
		return
	plate.shaped_px = key
	plate.shaped.clear()
	plate.heights.clear()
	for line: Array in plate.lines:
		var shaped := TextLine.new()
		var px := maxi(9, roundi(float(line[1]) * k))
		shaped.add_string(String(line[0]), HudKit.bold() if bool(line[3]) else HudKit.body(), px)
		plate.shaped.append(shaped)
		plate.heights.append(float(px) * 1.12)

func _draw_plates() -> void:
	var rid := _canvas.get_canvas_item()
	for plate: Plate in _drawn:
		var k := _plate_scale(plate)
		_shape(plate, k)
		var heights := plate.heights
		var top := _top(plate)
		var y := top
		for i in plate.lines.size():
			var line: Array = plate.lines[i]
			var shaped: TextLine = plate.shaped[i]
			var colour: Color = line[2]
			if i == plate.name_line and plate.hero != null:
				if plate.hero.duel_mark == HeroView.DUEL_FOE:
					colour = DUEL_FOE
				elif plate.hero.duel_mark == HeroView.DUEL_OUT:
					colour = DUEL_OUT
			var w := shaped.get_size().x
			var h := float(heights[i])
			var crest_w := 0.0
			if i == plate.crest_line and plate.crest != null:
				crest_w = h * 1.3 + CREST_GAP
			var x := roundf(plate.at.x - (w + crest_w) * 0.5)
			var at := Vector2(x + crest_w, roundf(y + (h - shaped.get_size().y) * 0.5))
			if crest_w > 0.0:
				# whole pixels: the crest is resampled to exactly this size
				var side := roundf(h * 1.3)
				RenderingServer.canvas_item_add_texture_rect(rid, Rect2(Vector2(x, roundf(y + (h - side) * 0.5)), Vector2(side, side)),
					UITheme.drawn_pixels(plate.crest, side, _canvas).get_rid())
			var outline := maxi(3, roundi(float(line[1]) * k * 0.26))
			shaped.draw(rid, at + Vector2(0, 2), SHADOW)
			shaped.draw_outline(rid, at, outline, OUTLINE)
			shaped.draw(rid, at, colour)
			y += h
		if plate.hero != null and plate.hero.is_ga:
			_draw_ga(rid, plate.at.x, top, k)

## The GA emblem over the plate, floating slowly like the old game's badge.
func _draw_ga(rid: RID, x: float, top: float, k: float) -> void:
	if _ga_texture == null:
		if not ResourceLoader.exists(GA_EMBLEM):
			return
		_ga_texture = load(GA_EMBLEM)
	var h := GA_PX * k
	var w := h * float(_ga_texture.get_width()) / maxf(1.0, float(_ga_texture.get_height()))
	var bob := sin(_t * TAU / 2.6) * GA_FLOAT_PX * k
	RenderingServer.canvas_item_add_texture_rect(rid, Rect2(Vector2(roundf(x - w * 0.5), roundf(top - h - 2.0 + bob)),
		Vector2(w, h)), _ga_texture.get_rid())
