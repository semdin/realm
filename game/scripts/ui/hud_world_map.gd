extends HudWindow
class_name HudWorldMap

## The map window (M by default; GameSettings "world_map"), the old game's:
## the map the player is on as a painted sheet (MapSheets) - the grounds as
## the old atlas (hill shading, water, contours, the buildings from above)
## with its place names, the castle as a floor plan in ink on parchment one
## storey at a time (opening on the player's, with the rooms' names), the
## caverns by depth, a dungeon copy's plan - and on it:
##
##   * the player (the gold arrow and the camera's light cone) and the party;
##   * the people to talk to, a gold mark over the ones a quest sends you to;
##   * the doors (a dungeon's gate as the violet diamond with its name), the
##     hearths and the twinned cabinets and passages;
##   * the open quests' targets: the NPC to speak with, the place to visit,
##     the dungeon's gate - each ringed in gold with the quest's title;
##   * the waypoint's route as footprints and its pin with its coordinates.
##
## A click sets the waypoint: on a marker (a quest's target, a door, a
## hearth, an NPC) it marks that, anywhere else the walkable point nearest
## the click. Right-click sets it too, or clears it on the pin (the old
## map's way). Wheel zooms around the cursor, drag pans; it opens centred on
## the player. Under the map: the player's, the cursor's and the waypoint's
## coordinates.

const GATE := Color(0.72, 0.45, 1.0)
const QUEST := Color(1.0, 0.82, 0.32)
const PARTY_COLOUR := Color(0.45, 0.78, 1.0)
const INK := Color(0.29, 0.18, 0.09)
## A click that moved less than this is a click, not a drag (pixels).
const CLICK_SLOP := 5.0

## MapWay (game, finder, map_name, sheets).
var way: Node
var view: MapView
## "grounds", "castle", "caverns" or "dungeon".
var mode := "grounds"
var castle_level := 0
## The shown sheet ({texture, rect, style}).
var sheet: Dictionary = {}
## The markers a click may land on this frame: [{at (world), label, kind,
## y}], and what the check reads.
var markers: Array = []
var waypoints_set := 0
## Script time a frame (markers, coordinates; drawing in MapView.cost_ms),
## averaged (ms; the check reports it).
var cost_ms := 0.0
var _floors: HBoxContainer
var _floor_buttons := {}
var _coords: Label
var _hint: Label

func _init() -> void:
	super._init("World Map", Vector2(660, 600))
	name = "WorldMap"

func _ready() -> void:
	super._ready()
	_floors = HBoxContainer.new()
	_floors.name = "Floors"
	_floors.alignment = BoxContainer.ALIGNMENT_CENTER
	_floors.add_theme_constant_override("separation", 4)
	for lv in range(MapPlaces.LEVEL_MIN, MapPlaces.LEVEL_MAX + 1):
		var b := HudKit.button(I18n.t(String(MapPlaces.FLOOR_NAMES[lv])), 13)
		b.name = "Floor%d" % lv
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(54, 26)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(show_level.bind(lv))
		_floors.add_child(b)
		_floor_buttons[lv] = b
	body.add_child(_floors)
	view = MapView.new()
	view.name = "MapView"
	view.host = self
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(view)
	_coords = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 2)
	_coords.name = "Coords"
	_coords.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_coords)
	_hint = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = 1.0
	body.add_child(_hint)

func _map_mode() -> String:
	match String(way.map_name):
		"grounds":
			return "grounds"
		"castle_interior":
			return "castle"
		"spider_caverns":
			return "caverns"
	return "dungeon"

func open() -> void:
	mode = _map_mode()
	set_title({"castle": "Kaf Castle", "caverns": "Blackweb Caverns", "dungeon": TravelData.display_name(way.map_name)}.get(mode, "World Map"))  # i18n
	_floors.visible = mode == "castle"
	_hint.text = tr("Click: set waypoint  ·  Right-click the pin: clear  ·  Wheel: zoom  ·  Drag: move  ·  %s / Esc: close") \
		% GameSettings.key_name("world_map")
	super.open()
	var me: Vector3 = way.game.session.own_position()
	if mode == "castle":
		show_level(MapPlaces.castle_level(me.y - (way.game.session.copy_offset() as Vector3).y))
	else:
		_load_sheet(0)
	await get_tree().process_frame
	view.centre_on_player()

## Show storey `lv` of the castle.
func show_level(lv: int) -> void:
	castle_level = lv
	for k: int in _floor_buttons:
		(_floor_buttons[k] as Button).set_pressed_no_signal(k == lv)
	_load_sheet(lv)
	view.queue_redraw()

func _load_sheet(level: int) -> void:
	sheet = MapSheets.sheet(way.game.session, way.map_name, level)

func _process(_delta: float) -> void:
	if not visible or view == null or way.game.session == null:
		return
	var started := Time.get_ticks_usec()
	if sheet.is_empty():
		# still being painted on its thread
		_load_sheet(castle_level if mode == "castle" else 0)
		if not sheet.is_empty():
			view.centre_on_player()
	_collect_markers()
	view.queue_redraw()
	_update_coords()
	cost_ms = lerpf(cost_ms, (Time.get_ticks_usec() - started) / 1000.0, 0.05)

## The floor the shown storey stands on (world y; only the castle has more
## than one).
func shown_floor_y() -> float:
	var offset: Vector3 = way.game.session.copy_offset()
	if mode == "castle":
		return MapPlaces.storey_y(castle_level) + offset.y
	return way.game.session.own_position().y

## Whether a world point stands on the shown storey.
func on_shown_storey(y: float) -> bool:
	if mode != "castle":
		return true
	var floor_y := shown_floor_y()
	return y > floor_y - 2.0 and y < floor_y + MapPlaces.STOREY - 2.0

func coords_of(at: Vector2) -> String:
	return MapPlaces.coords_text(way.map_name, at, way.game.session.copy_offset())

## You, the cursor and the waypoint, in the map's coordinates.
func _update_coords() -> void:
	var parts: Array = []
	var me: Vector3 = way.game.session.own_position()
	parts.append(tr("You") + "  " + coords_of(Vector2(me.x, me.z)))
	if view.hovering:
		parts.append(tr("Cursor") + "  " + coords_of(view.hover))
	var finder: WayFinder = way.finder
	if WayFinder.has_target() and finder.goal != Vector3.INF:
		var mark := tr("Waypoint") + "  " + coords_of(Vector2(finder.goal.x, finder.goal.z))
		if WayFinder.target_label != "":
			mark = tr("Waypoint") + "  " + WayFinder.target_label + "  " + coords_of(Vector2(finder.goal.x, finder.goal.z))
		mark += "  (%d m)" % roundi(finder.remaining())
		parts.append(mark)
	var text := "   ·   ".join(parts)
	if _coords.text != text:
		_coords.text = text

## What a click may mark: the quest targets, the doors and gates, the travel
## objects, the NPCs (world positions, this map).
func _collect_markers() -> void:
	markers = []
	var game: Node = way.game
	var offset: Vector3 = game.session.copy_offset()
	for portal: Dictionary in TravelData.portals(way.map_name):
		var at := WayFinder.door_point(portal) + offset
		var to_map := String(portal.get("to_map", ""))
		var gate := TravelData.instanced(to_map) and not TravelData.instanced(way.map_name)
		markers.append({"at": at, "kind": "gate" if gate else "door",
			"label": TravelData.display_name(to_map) if gate else tr("Way to %s") % TravelData.display_name(to_map)})
	var nodes: Dictionary = TravelData.nodes()
	for id: String in nodes:
		var node: Dictionary = nodes[id]
		if String(node.get("map", "")) != way.map_name:
			continue
		var p: Array = node.get("pos", [0.0, 0.0, 0.0])
		var at := Vector3(float(p[0]), float(p[1]), float(p[2])) + offset
		if game.travel.nodes != null and game.travel.nodes.roots.has(id):
			at = (game.travel.nodes.roots[id] as Node3D).global_position
		markers.append({"at": at, "kind": "hearth" if String(node.get("kind", "")) == "hearthway" else "link",
			"label": I18n.t(String(node.get("label", "")))})
	for npc: NpcView in game.npcs:
		markers.append({"at": npc.position, "kind": "npc", "label": I18n.t(npc.npc_name),
			"wanted": game.quests.npc_wants_talk(npc.npc_name)})
	for target: Dictionary in way.quest_targets():
		markers.append(target)

## A click at world `w` (on screen `screen`): a marker under the cursor is
## marked, else the walkable point nearest the click on the shown storey.
func click_at(w: Vector2, screen: Vector2) -> void:
	var hit := view.marker_at(screen)
	if not hit.is_empty():
		way.set_waypoint(way.map_name, hit["at"], String(hit.get("label", "")))
	else:
		var point: Vector3 = way.game.session.nav_point(Vector3(w.x, shown_floor_y() + 0.5, w.y))
		way.set_waypoint(way.map_name, point, "")
	waypoints_set += 1

func right_click_at(w: Vector2, screen: Vector2) -> void:
	var finder: WayFinder = way.finder
	if WayFinder.has_target() and finder.goal != Vector3.INF \
			and view.world_to_screen(Vector2(finder.goal.x, finder.goal.z)).distance_to(screen) < 14.0:
		finder.clear()
		return
	click_at(w, screen)


class MapView extends Control:
	var host: HudWorldMap
	## Pixels per world metre on screen, and the world point at the centre.
	var zoom := 0.45
	var centre := Vector2.ZERO
	var hover := Vector2.ZERO
	var hovering := false
	var _hover_px := Vector2.ZERO
	var _dragging := false
	var _pressed_at := Vector2.ZERO
	var _moved := 0.0
	var _icons := {}
	## Drawing time a frame, averaged (ms).
	var cost_ms := 0.0

	func _init() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(300, 300)

	func _rect() -> Rect2:
		return host.sheet.get("rect", Rect2(-100, -100, 200, 200))

	func centre_on_player() -> void:
		var me: Vector3 = host.way.game.session.own_position()
		centre = Vector2(me.x, me.z)
		zoom = maxf(_min_zoom(), {"castle": 3.2, "caverns": 1.6, "dungeon": 3.0}.get(host.mode, 0.45))
		_clamp()

	func _min_zoom() -> float:
		var r := _rect()
		return minf(size.x / maxf(r.size.x, 1.0), size.y / maxf(r.size.y, 1.0))

	func world_to_screen(w: Vector2) -> Vector2:
		return size * 0.5 + (w - centre) * zoom

	func screen_to_world(s: Vector2) -> Vector2:
		return centre + (s - size * 0.5) / zoom

	func _clamp() -> void:
		zoom = clampf(zoom, _min_zoom(), 3.0 if host.mode == "grounds" else 12.0)
		var r := _rect()
		var half := size * 0.5 / zoom
		var lo := r.position + half
		var hi := r.end - half
		var mid := r.get_center()
		centre.x = clampf(centre.x, minf(lo.x, mid.x), maxf(hi.x, mid.x))
		centre.y = clampf(centre.y, minf(lo.y, mid.y), maxf(hi.y, mid.y))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					var before := screen_to_world(mb.position)
					zoom *= 1.18 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.18
					_clamp()
					centre += before - screen_to_world(mb.position)
					_clamp()
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_dragging = true
					_pressed_at = mb.position
					_moved = 0.0
				else:
					_dragging = false
					if _moved < CLICK_SLOP:
						host.click_at(screen_to_world(mb.position), mb.position)
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				host.right_click_at(screen_to_world(mb.position), mb.position)
				accept_event()
		elif event is InputEventMouseMotion:
			var mm := event as InputEventMouseMotion
			if _dragging:
				_moved = maxf(_moved, mm.position.distance_to(_pressed_at))
				if _moved >= CLICK_SLOP:
					centre -= mm.relative / zoom
					_clamp()
				accept_event()
			_hover_px = mm.position
			hover = screen_to_world(mm.position)
			hovering = true

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT:
			hovering = false

	## The marker under screen point `at` ({} when none).
	func marker_at(at: Vector2) -> Dictionary:
		var best: Dictionary = {}
		var best_d := 11.0
		for m: Dictionary in host.markers:
			var p: Vector3 = m["at"]
			if not host.on_shown_storey(p.y):
				continue
			var radius := 11.0 + (float(m.get("radius", 0.0)) * zoom if String(m.get("kind", "")) == "place" else 0.0)
			var d := world_to_screen(Vector2(p.x, p.z)).distance_to(at)
			if d < maxf(best_d, radius) and (best.is_empty() or d < best_d):
				best_d = d
				best = m
		return best

	func _icon(id: String) -> Texture2D:
		if not _icons.has(id):
			_icons[id] = UITheme.chrome_at(id, 48.0)
		return _icons[id]

	## One of the painted markers, centred on `at`.
	func _draw_icon(id: String, at: Vector2, px: float) -> void:
		var tex := _icon(id)
		if tex == null:
			draw_circle(at, px * 0.3, HudKit.GOLD_LT)
			return
		draw_texture_rect(tex, Rect2(at - Vector2(px, px) * 0.5, Vector2(px, px)), false)

	func _text(txt: String, at: Vector2, fs: int, colour: Color, font: Font, outline: Color, outline_px := 5) -> void:
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var p := at - Vector2(w * 0.5, 0)
		draw_string_outline(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline_px, outline)
		draw_string(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)

	func _draw() -> void:
		if host.way.game.session == null:
			return   # leaving the world: the session is gone
		var started := Time.get_ticks_usec()
		var parchment := host.mode == "castle" or host.mode == "dungeon"
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.89, 0.81, 0.64) if parchment else Color(0.05, 0.05, 0.06))
		if host.sheet.has("texture"):
			var r := _rect()
			var tl := world_to_screen(r.position)
			draw_texture_rect(host.sheet["texture"], Rect2(tl, r.size * zoom), false)
		_draw_places()
		_draw_markers()
		_draw_party()
		_draw_route()
		_draw_player()
		_draw_cursor_coords()
		if host.mode == "castle":
			_draw_storey_title()
		draw_rect(Rect2(Vector2.ZERO, size), HudKit.GOLD.darkened(0.2), false, 2.0)
		cost_ms = lerpf(cost_ms, (Time.get_ticks_usec() - started) / 1000.0, 0.05)

	## The place names: the grounds' regions and landmarks, the castle's rooms
	## on this storey, the caverns' hunting floors.
	func _draw_places() -> void:
		var deco := HudKit.deco()
		match host.mode:
			"grounds":
				for spec: Array in MapPlaces.GROUNDS_LABELS:
					var fs := int(clampf(15.0 * float(spec[2]) * (0.75 + zoom * 0.6), 11.0, 30.0))
					_text(I18n.t(String(spec[0])), world_to_screen(spec[1]), fs, Color(0.22, 0.13, 0.06), deco,
						Color(0.98, 0.94, 0.84, 0.85))
			"castle":
				var offset: Vector3 = host.way.game.session.copy_offset()
				for room: Array in MapPlaces.CASTLE_ROOMS:
					if int(room[1]) != host.castle_level:
						continue
					var c := Vector2((float(room[2]) + float(room[3])) * 0.5, (float(room[4]) + float(room[5])) * 0.5)
					var fs := int(clampf(6.0 + zoom * 2.2, 10.0, 22.0))
					_text(I18n.t(String(room[0])), world_to_screen(c + Vector2(offset.x, offset.z)) + Vector2(0, fs * 0.35),
						fs, INK, deco, Color(0.95, 0.88, 0.72, 0.7), 3)
			"caverns":
				for region: Dictionary in MapPlaces.hunting_regions(host.way.map_name):
					var c: Array = region.get("center", [0.0, 0.0])
					var fs := int(clampf(10.0 + zoom * 3.0, 11.0, 20.0))
					_text(I18n.t(String(region.get("display", ""))), world_to_screen(Vector2(float(c[0]), float(c[1]))),
						fs, HudKit.GOLD_HI, HudKit.bold(), Color(0, 0, 0, 0.9))

	## Doors, gates, travel objects, NPCs, quest targets.
	func _draw_markers() -> void:
		var bold := HudKit.bold()
		var t := Time.get_ticks_msec() / 1000.0
		for m: Dictionary in host.markers:
			var p: Vector3 = m["at"]
			if not host.on_shown_storey(p.y):
				continue
			var at := world_to_screen(Vector2(p.x, p.z))
			if at.x < -40.0 or at.y < -40.0 or at.x > size.x + 40.0 or at.y > size.y + 40.0:
				continue
			var label := String(m.get("label", ""))
			match String(m.get("kind", "")):
				"gate":
					var r := 9.0
					draw_colored_polygon(PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0)]),
						Color(0.08, 0.03, 0.12, 0.95))
					r -= 3.0
					draw_colored_polygon(PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0)]), GATE)
					_text(label, at + Vector2(0, 24), 14, Color(0.86, 0.7, 1.0), bold, Color(0, 0, 0, 0.9))
				"door":
					_draw_icon("ui_portal", at, 20.0)
					if zoom > 0.9:
						_text(label, at + Vector2(0, 22), 12, HudKit.GOLD_HI, bold, Color(0, 0, 0, 0.85), 4)
				"hearth":
					_draw_icon("hearth_dust", at, 22.0)
					if zoom > 0.6:
						_text(label, at + Vector2(0, 24), 12, Color(0.7, 1.0, 0.72), bold, Color(0, 0, 0, 0.85), 4)
				"link":
					_draw_icon("ui_portal", at, 18.0)
					if zoom > 0.9:
						_text(label, at + Vector2(0, 22), 12, HudKit.GOLD_HI, bold, Color(0, 0, 0, 0.85), 4)
				"npc":
					_draw_icon("minimap_npc", at, 20.0)
					if bool(m.get("wanted", false)):
						_draw_icon("ui_quest", at + Vector2(0, -16), 16.0)
					if zoom > 0.7:
						draw_string_outline(bold, at + Vector2(10, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0, 0, 0, 0.85))
						draw_string(bold, at + Vector2(10, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.GOLD_HI)
				"place", "quest":
					# a quest's target: a gold ring breathing round it, the quest's
					# title over it
					var r := maxf(12.0, float(m.get("radius", 0.0)) * zoom)
					var pulse := 0.5 + 0.5 * sin(t * 3.0)
					if String(m["kind"]) == "place":
						draw_circle(at, r, Color(QUEST, 0.10 + 0.05 * pulse))
					draw_arc(at, r + 2.0 * pulse, 0.0, TAU, 48, Color(QUEST, 0.85), 2.0, true)
					_draw_icon("ui_quest", at - Vector2(0, minf(r, 40.0) + 12.0), 18.0)
					_text(label, at - Vector2(0, minf(r, 40.0) + 26.0), 13, QUEST, bold, Color(0, 0, 0, 0.9), 4)

	func _draw_party() -> void:
		var game: Node = host.way.game
		var party: Dictionary = host.way.party_ids()
		for id: int in party:
			var pos: Variant = game.drawn.get(id)
			if pos == null or not host.on_shown_storey((pos as Vector3).y):
				continue
			var at := world_to_screen(Vector2((pos as Vector3).x, (pos as Vector3).z))
			draw_circle(at, 6.0, Color(0.03, 0.05, 0.1, 0.9))
			draw_circle(at, 4.5, PARTY_COLOUR)
			if zoom > 0.6:
				var bold := HudKit.bold()
				draw_string_outline(bold, at + Vector2(9, 4), String(party[id]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.85))
				draw_string(bold, at + Vector2(9, 4), String(party[id]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, PARTY_COLOUR)

	## The waypoint's route as a dotted trail of footprints, and its pin.
	func _draw_route() -> void:
		var finder: WayFinder = host.way.finder
		if finder == null or not WayFinder.has_target() or finder.goal == Vector3.INF:
			return
		var plan := host.mode == "castle" or host.mode == "dungeon"
		var colour := Color(0.55, 0.12, 0.06) if plan else Color(1.0, 0.85, 0.35)
		var shadow := Color(0, 0, 0, 0.0 if plan else 0.6)
		var pts := finder.path
		var carry := 0.0
		var flip := false
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			if not host.on_shown_storey(a.y) and not host.on_shown_storey(b.y):
				continue
			var sa := world_to_screen(Vector2(a.x, a.z))
			var sb := world_to_screen(Vector2(b.x, b.z))
			var seg := sa.distance_to(sb)
			var dir := (sb - sa).normalized() if seg > 0.01 else Vector2.UP
			var n := Vector2(-dir.y, dir.x)
			var t := carry
			while t < seg:
				var p := sa + dir * t + n * (2.2 if flip else -2.2)
				draw_circle(p, 2.6, shadow)
				draw_circle(p, 1.9, colour)
				flip = not flip
				t += 9.0
			carry = t - seg
		var pin := world_to_screen(Vector2(finder.goal.x, finder.goal.z))
		if not host.on_shown_storey(finder.goal.y):
			colour = Color(colour, 0.45)
		draw_circle(pin + Vector2(0, -14), 7.5, Color(0, 0, 0, 0.55))
		draw_colored_polygon(PackedVector2Array([pin, pin + Vector2(-6, -12), pin + Vector2(6, -12)]), colour.darkened(0.2))
		draw_circle(pin + Vector2(0, -14), 6.5, colour)
		draw_circle(pin + Vector2(0, -14), 2.4, Color(1, 1, 1, 0.9))
		var f := HudKit.bold()
		var txt := host.coords_of(Vector2(finder.goal.x, finder.goal.z))
		_text(txt, pin + Vector2(0, -26), 12, Color(1.0, 0.92, 0.7), f, Color(0, 0, 0, 0.9), 4)

	func _draw_player() -> void:
		var game: Node = host.way.game
		var me: Vector3 = game.session.own_position()
		if not host.on_shown_storey(me.y):
			return
		var pp := world_to_screen(Vector2(me.x, me.z))
		MapMarker.draw_view_cone(self, pp, Vector2(-sin(game.cam_yaw), -cos(game.cam_yaw)), 90.0)
		MapMarker.draw_arrow(self, pp, Vector2(sin(game.player.facing), cos(game.player.facing)), 13.0)

	## A small dark tag beside the cursor with the map point under it.
	func _draw_cursor_coords() -> void:
		if not hovering or (_dragging and _moved >= CLICK_SLOP):
			return
		hover = screen_to_world(_hover_px)
		var f := HudKit.bold()
		var txt := host.coords_of(hover)
		var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var at := _hover_px + Vector2(14, 18)
		at.x = minf(at.x, size.x - tw - 12.0)
		at.y = minf(at.y, size.y - 8.0)
		draw_rect(Rect2(at - Vector2(5, 15), Vector2(tw + 10, 20)), Color(0.02, 0.03, 0.05, 0.82))
		draw_rect(Rect2(at - Vector2(5, 15), Vector2(tw + 10, 20)), Color(HudKit.GOLD, 0.6), false, 1.0)
		draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.GOLD_HI)

	func _draw_storey_title() -> void:
		var title := MapPlaces.floor_title(host.castle_level)
		var tf := HudKit.deco()
		var tw := tf.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		draw_rect(Rect2(Vector2(8, 8), Vector2(tw + 20, 28)), Color(0.89, 0.81, 0.64, 0.92))
		draw_rect(Rect2(Vector2(8, 8), Vector2(tw + 20, 28)), Color(INK, 0.6), false, 1.0)
		draw_string(tf, Vector2(18, 28), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(INK, 0.9))
