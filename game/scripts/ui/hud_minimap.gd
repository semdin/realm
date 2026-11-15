extends Control
class_name HudMinimap

## The minimap (top right), the old game's: the map round the player in the
## brass ring, north up, the gold arrow turning with the character over the
## light cone of the camera; the hunting grounds as rings tinted by their
## level band; the creatures (the red shard, the boss's crown, a stone's green
## spike), the NPCs (a gold mark over one a quest sends you to), the party,
## and the waypoint's route and pin (held at the rim when it is farther than
## the disc shows). Under the disc the place's name and the coordinates;
## under the ring zoom out, recentre, zoom in.
##
## Cheap on the Intel iGPU: the ground is the map's painted sheet
## (MapSheets) seen through a shader on one quad - no second camera - and
## the markers are one canvas item's few textured quads.

## Radius of the disc in pixels, and the world metres across it (the +/-
## buttons change it).
const MAP_PX := 178.0
const ZOOM_DEFAULT := 150.0
const ZOOM_MIN := 60.0
const ZOOM_MAX := 420.0
const AT := Vector2(-(MAP_PX + 16.0), 14.0)
const DISC_SHADER := preload("res://assets/shaders/map_disc.gdshader")
const PARTY_COLOUR := Color(0.45, 0.78, 1.0)

## MapWay (game, finder, map_name).
var way: Node
var zoom := ZOOM_DEFAULT
## What the check reads: markers drawn last frame by kind.
var drawn: Dictionary = {}
## Drawing time a frame of the markers, averaged (ms; the check reports it).
var cost_ms := 0.0
var place_label: Label
var coords_label: Label

var _disc: ColorRect
var _overlay: Control
var _marker: MapMarker
var _sheet: Dictionary = {}
var _centre := Vector3.ZERO
var _icons: Dictionary = {}

func _init() -> void:
	name = "Minimap"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = AT.x
	offset_top = AT.y
	offset_right = AT.x + MAP_PX
	offset_bottom = AT.y + MAP_PX
	custom_minimum_size = Vector2(MAP_PX, MAP_PX)

func _ready() -> void:
	_disc = ColorRect.new()
	_disc.name = "Disc"
	_disc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = DISC_SHADER
	_disc.material = mat
	add_child(_disc)
	_overlay = Control.new()
	_overlay.name = "Markers"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_markers)
	add_child(_overlay)
	_marker = MapMarker.new()
	_marker.name = "PlayerMarker"
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.cone_length = MAP_PX * 0.36
	add_child(_marker)
	var ring := TextureRect.new()
	ring.name = "Ring"
	ring.texture = ArcaneSkin.texture("minimap")
	ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ring)
	# where you are, under the disc: the place in the map's own lettering
	place_label = HudKit.label("", 15, HudKit.GOLD_HI, HudKit.deco(), 5)
	place_label.name = "PlaceName"
	place_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	place_label.offset_left = -130.0
	place_label.offset_right = 130.0
	place_label.offset_top = 30.0
	place_label.offset_bottom = 52.0
	place_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place_label.clip_text = true
	add_child(place_label)
	# where exactly: the map's own coordinates in whole metres
	coords_label = HudKit.label("", 13, HudKit.PARCHMENT, HudKit.body(), 4)
	coords_label.name = "Coords"
	coords_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	coords_label.offset_left = -130.0
	coords_label.offset_right = 130.0
	coords_label.offset_top = 52.0
	coords_label.offset_bottom = 70.0
	coords_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coords_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(coords_label)
	_build_buttons()

## The three round buttons under the ring: zoom out, recentre, zoom in.
func _build_buttons() -> void:
	var row := HBoxContainer.new()
	row.name = "MapButtons"
	row.add_theme_constant_override("separation", 2)
	row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	row.offset_left = -72.0
	row.offset_right = 72.0
	row.offset_top = -18.0
	row.offset_bottom = 26.0
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	for spec: Array in [["minimap_zoom_out", -1, "Zoom out"], ["minimap_player", 0, "Recentre on me"], ["minimap_zoom_in", 1, "Zoom in"]]:  # i18n
		var b := Button.new()
		b.name = "Zoom%d" % int(spec[1])
		b.icon = UITheme.chrome_at(String(spec[0]), 26.0)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.tooltip_text = tr(String(spec[2]))
		b.custom_minimum_size = Vector2(30, 30)
		b.focus_mode = Control.FOCUS_NONE
		for state in ["normal", "hover", "pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		b.add_theme_color_override("icon_hover_color", Color(1.25, 1.18, 1.0))
		b.add_theme_color_override("icon_pressed_color", Color(0.8, 0.8, 0.8))
		var dir: int = spec[1]
		b.pressed.connect(zoom_step.bind(dir))
		row.add_child(b)

func zoom_step(direction: int) -> void:
	if direction == 0:
		zoom = ZOOM_DEFAULT
	else:
		zoom = clampf(zoom * (0.72 if direction > 0 else 1.39), ZOOM_MIN, ZOOM_MAX)

## Every frame (MapWay.tick): the disc follows the player, the arrow turns,
## the markers are drawn where they stand now.
func tick(me: Vector3, sheet: Dictionary, facing: float, cam_yaw: float) -> void:
	if sheet != _sheet:
		_sheet = sheet
		if not sheet.is_empty():
			(_disc.material as ShaderMaterial).set_shader_parameter("sheet", sheet["texture"])
	_centre = me
	_disc.visible = not sheet.is_empty()
	if not sheet.is_empty():
		var rect: Rect2 = sheet["rect"]
		var mat := _disc.material as ShaderMaterial
		mat.set_shader_parameter("centre_uv", MapSheets.to_uv(sheet, Vector2(me.x, me.z)))
		mat.set_shader_parameter("span_uv", Vector2(zoom, zoom) / rect.size)
	var f := Vector2(sin(facing), cos(facing))
	var c := Vector2(-sin(cam_yaw), -cos(cam_yaw))
	# the cone is tessellated on every redraw: only when it turned
	if f.dot(_marker.facing) < 0.99999 or c.dot(_marker.camera_dir) < 0.99999:
		_marker.facing = f
		_marker.camera_dir = c
		_marker.queue_redraw()
	_overlay.queue_redraw()

## World position -> pixel inside the disc (north up: +x right, +z down).
func to_disc(pos: Vector3) -> Vector2:
	var half := MAP_PX * 0.5
	return Vector2(half + (pos.x - _centre.x) / zoom * MAP_PX, half + (pos.z - _centre.z) / zoom * MAP_PX)

func _icon(id: String) -> Texture2D:
	if not _icons.has(id):
		_icons[id] = UITheme.chrome_at(id, 40.0)
	return _icons[id]

## One of the painted markers, centred on `at`, when it is inside the disc.
func _mark(id: String, at: Vector2, px: float, kind: String) -> bool:
	var half := MAP_PX * 0.5
	if (at - Vector2(half, half)).length() > half - px * 0.5 - 4.0:
		return false
	var tex := _icon(id)
	if tex != null:
		_overlay.draw_texture_rect(tex, Rect2(at - Vector2(px, px) * 0.5, Vector2(px, px)), false)
	drawn[kind] = int(drawn.get(kind, 0)) + 1
	return true

func _draw_markers() -> void:
	drawn = {}
	# leaving the world frees the session before this last redraw
	if way == null or _sheet.is_empty() or way.game.session == null:
		return
	var started := Time.get_ticks_usec()
	var game: Node = way.game
	var half := MAP_PX * 0.5
	var centre := Vector2(half, half)
	_draw_hunting_grounds(game)
	_draw_route(centre, half)
	# creatures: the crown for a boss, the green spike for a stone, the shard
	# for the rest; only what the disc shows gets any work
	var others: Dictionary = game.others
	if others.has("ids"):
		var ids: PackedInt32Array = others["ids"]
		var kinds: PackedInt32Array = others["kinds"]
		var positions: PackedVector3Array = others["positions"]
		var states: PackedInt32Array = others["states"]
		var reach := zoom * 0.75
		var party: Dictionary = way.party_ids()
		for i in ids.size():
			var pos := positions[i]
			if absf(pos.x - _centre.x) > reach or absf(pos.z - _centre.z) > reach:
				continue
			var kind := kinds[i]
			if kind == 0:
				if party.has(ids[i]):
					var at := to_disc(pos)
					if (at - centre).length() < half - 8.0:
						_overlay.draw_circle(at, 5.0, Color(0.03, 0.05, 0.1, 0.9))
						_overlay.draw_circle(at, 3.6, PARTY_COLOUR)
						drawn["party"] = int(drawn.get("party", 0)) + 1
				continue
			if ChestView.is_chest(kind) or states[i] & 15 == CreatureView.STATE_DEAD:
				continue
			var beast: Node = game.beasts.get(ids[i])
			if beast is DummyView:
				continue
			if beast is StoneView:
				_mark("minimap_monolith", to_disc(pos), 18.0, "stone")
			elif kind & CreatureView.BOSS_BIT != 0:
				_mark("minimap_boss", to_disc(pos), 18.0, "boss")
			else:
				_mark("minimap_mob", to_disc(pos), 12.0, "mob")
	# the people to talk to, a gold mark over the ones a quest wants
	for npc: NpcView in game.npcs:
		var at := to_disc(npc.position)
		if _mark("minimap_npc", at, 15.0, "npc") and game.quests.npc_wants_talk(npc.npc_name):
			_mark("ui_quest", at + Vector2(0, -11), 12.0, "quest")
	cost_ms = lerpf(cost_ms, (Time.get_ticks_usec() - started) / 1000.0, 0.05)

## Hunting grounds inside the disc: a filled tint and a ring coloured like
## the zone banner's level band (kept inside the disc).
func _draw_hunting_grounds(game: Node) -> void:
	var level := int(game.sheet_view.level)
	var half := MAP_PX * 0.5
	for region: Dictionary in MapPlaces.hunting_regions(way.map_name):
		var c: Array = region.get("center", [0.0, 0.0])
		var offset: Vector3 = game.session.copy_offset()
		var at := to_disc(Vector3(float(c[0]) + offset.x, 0.0, float(c[1]) + offset.z))
		var r := float(region.get("radius", 30.0)) / zoom * MAP_PX
		var room := half - 4.0 - (at - Vector2(half, half)).length()
		if room <= 2.0:
			continue
		r = minf(r, room)
		var tint := MapPlaces.band_color(level, int(region.get("level_min", 1)), int(region.get("level_max", 1)))
		_overlay.draw_circle(at, r, Color(tint, 0.14))
		_overlay.draw_arc(at, r, 0.0, TAU, 40, Color(tint, 0.7), 1.5, true)

## The waypoint's route as gold dots and its pin (at the rim when far).
func _draw_route(centre: Vector2, half: float) -> void:
	var finder: WayFinder = way.finder
	if finder == null or not WayFinder.has_target() or finder.goal == Vector3.INF:
		return
	var pts := finder.path
	var carry := 0.0
	for i in pts.size() - 1:
		if absf(pts[i].y - _centre.y) > 8.0 and way.map_name != "grounds":
			continue
		var a := to_disc(pts[i])
		var b := to_disc(pts[i + 1])
		var seg := a.distance_to(b)
		var t := carry
		while t < seg:
			var p := a.lerp(b, t / seg)
			if (p - centre).length() < half - 6.0:
				_overlay.draw_circle(p, 2.2, Color(0.15, 0.08, 0.02, 0.8))
				_overlay.draw_circle(p, 1.5, Color(1.0, 0.84, 0.36))
				drawn["route"] = int(drawn.get("route", 0)) + 1
			t += 7.0
		carry = t - seg
	var pin := to_disc(finder.goal)
	var off := pin - centre
	if off.length() > half - 10.0:
		pin = centre + off.normalized() * (half - 10.0)
	_overlay.draw_circle(pin, 6.0, Color(0.15, 0.08, 0.02, 0.85))
	_overlay.draw_circle(pin, 4.5, Color(1.0, 0.8, 0.3))
	_overlay.draw_circle(pin, 1.8, Color(1, 1, 1))
	drawn["pin"] = 1
