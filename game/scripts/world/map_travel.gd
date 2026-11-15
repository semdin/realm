extends Node
class_name MapTravel

## Travel on the client: everything a player does to leave a place, drawn from
## what the server says. The server decides every trip; this asks and shows.
##
##   * Doors (maps.json `portals` of this map): the body is tested against each
##     trigger every frame; standing in one shows "Press F - Enter <map>", F
##     asks RealmSession.door. Mounted, the door is refused here (the server
##     refuses it too). A door into an instanced map is a dungeon's gate: F
##     opens its gate window (MapDungeon). Inside a dungeon copy the doors'
##     triggers stand at the copy's offset (RealmSession.copy_offset).
##   * Hearths, Twinned Cabinets and passages (travel.json `nodes` of this
##     map, drawn by TravelNodes): within a node's radius its prompt shows. F
##     at a hearth opens the Hearth window (HudHearthway), whose Travel plays
##     the green flames and asks RealmSession.travel(here, there); F at a
##     cabinet or passage plays its smoke and asks travel(node, "").
##   * Waylinks (WaylinkViews): F within a boot's radius grabs hold or lets go.
##   * The broom: Shift asks RealmSession.ride(!mounted); the body mounts when
##     the server's ride window reaches it.
##   * A trip: `departing` (same map: a short fade, the teleport follows;
##     another map: the loading screen), `travel` (the new map's ticket: the
##     scene is rebuilt for it and the new scene joins with start_travel),
##     `arrived` (the arrival flames where the body was set down).
##   * Refusals (`travel_result` with ok false) on the notice band.

const PROMPT_KEY := "F"
## Same-map trips: fade to black, hold while the teleport lands, fade back.
const FADE_OUT := 0.2
const FADE_HOLD := 0.45
const FADE_IN := 0.5
## The hearth's flames burn this long before the trip is asked for (the old
## game's departure), a cabinet's or passage's smoke this long.
const HEARTH_DELAY := 0.7
const PASSAGE_DELAY := 0.8
## The new map is drawn this many frames behind the loading screen before it
## lifts (its first draws compile pipelines).
const SETTLE_FRAMES := 8

## main.gd (session, player, hud, map_name, heroes, ground lookup).
var game: Node
var map_name := ""
var nodes: TravelNodes
var waylinks: WaylinkViews
var hearthway: HudHearthway
var waylink_window: HudWaylink

## What the body stands in this frame: a door (its maps.json entry), a travel
## node id, a Waylink ({id, holding, label}).
var active_portal: Dictionary = {}
var active_node := ""
var active_waylink: Dictionary = {}
## The prompt text this frame ("" when none).
var prompt := ""
## A trip to another map is under way: the old session may close any moment
## and main.gd must not take that for a failure.
var leaving := false
## The scene is being rebuilt for this trip (the loading screen is up).
var reloading := false
## This scene was built for a trip (start_travel): the loading screen stays up
## until the map is drawn.
var arrived_by_trip := false
## What the checks read: trips by kind, fades, arrivals by kind, refusals.
var departures: Array = []
var arrivals: Array = []
var fades := 0
var results: Array = []
var last_refusal := ""
var doors_asked := 0
var rides_asked := 0

var _prompt_label: Label
var _fade_rect: ColorRect
var _fade_tween: Tween
var _pending_arrival := ""
var _loading_done := false
var _settle_frames := 0

func setup(main: Node, map_id: String, ui_root: Control) -> void:
	game = main
	map_name = map_id
	name = "MapTravel"
	_build_ui()
	hearthway = HudHearthway.new()
	hearthway.session = game.session
	hearthway.sheet = game.sheet_view
	hearthway.on_travel = _hearth_depart
	ui_root.add_child(hearthway)
	waylink_window = HudWaylink.new()
	waylink_window.session = game.session
	ui_root.add_child(waylink_window)
	game.hud.hearthway = hearthway
	game.hud.waylink = waylink_window
	waylinks = WaylinkViews.new()
	waylinks.name = "WaylinkViews"
	waylinks.game = game
	game.add_child(waylinks)

## The scene was rebuilt for a trip: the loading screen (still up from the
## old scene) says the new map is being joined.
func begin_arrival() -> void:
	arrived_by_trip = true
	var screen := MapLoadingScreen.shared(get_tree())
	if not screen.is_open():
		screen.open(_loading_title(map_name), _loading_text(map_name))
	screen.set_progress(35.0, tr("Waiting for the server…"))

## The map is drawn (main.gd built its geometry): this map's travel objects
## stand on it.
func on_map_built() -> void:
	nodes = TravelNodes.new()
	game.add_child(nodes)
	nodes.build(map_name, _floor_under)
	if arrived_by_trip:
		MapLoadingScreen.shared(get_tree()).set_progress(85.0, tr("Almost there…"))
		_settle_frames = SETTLE_FRAMES
	else:
		_loading_done = true

## The lowest surface under (x, z): the terrain, not a roof over it (a
## hearth stands under the Hearth Pavilion's roof). A ray from the sky steps
## down past every surface it meets.
func _floor_under(x: float, z: float) -> Vector3:
	var from := Vector3(x, 1500.0, z)
	var lowest := Vector3(x, 0.0, z)
	for attempt in 8:
		var hit: Dictionary = game.session.pick(from, Vector3.DOWN, from.y + 200.0)
		if hit.is_empty():
			break
		var point: Vector3 = hit["point"]
		if int(hit["entity"]) == 0:
			lowest = point
		from = point - Vector3(0, 0.3, 0)
	return lowest

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "MapStatusUI"
	layer.layer = 20
	add_child(layer)
	_fade_rect = ColorRect.new()
	_fade_rect.name = "Fade"
	_fade_rect.color = Color(0.02, 0.02, 0.04, 0.0)
	_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade_rect)
	_prompt_label = Label.new()
	_prompt_label.name = "Prompt"
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_label.add_theme_font_size_override("font_size", 20)
	_prompt_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_prompt_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_prompt_label.add_theme_constant_override("outline_size", 6)
	_prompt_label.anchor_top = 1.0
	_prompt_label.anchor_right = 1.0
	_prompt_label.anchor_bottom = 1.0
	_prompt_label.offset_top = -168.0
	_prompt_label.offset_bottom = -136.0
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_prompt_label)

func mounted() -> bool:
	return bool(game.session.own_body().get("mounted", false))

## Every frame once the map is drawn: what the body stands in, the prompt,
## and the loading screen's last steps after a trip.
func tick(_delta: float) -> void:
	if _settle_frames > 0:
		_settle_frames -= 1
		if _settle_frames == 0:
			_finish_loading()
	if nodes == null or leaving:
		_set_prompt("")
		return
	var me: Vector3 = game.session.own_position()
	# a dungeon copy's doors stand at its offset (content is at the map's own
	# coordinates)
	var local: Vector3 = me - (game.session.copy_offset() as Vector3)
	active_portal = {}
	for portal: Dictionary in TravelData.portals(map_name):
		if _portal_contains(portal, local):
			active_portal = portal
			break
	active_node = ""
	active_waylink = {}
	if active_portal.is_empty():
		active_waylink = waylinks.grab_candidate(me)
	if active_portal.is_empty() and active_waylink.is_empty():
		active_node = nodes.node_at(me)
	var text := ""
	if not active_portal.is_empty():
		if _is_gate(active_portal):
			text = tr("Press %s - %s") % [PROMPT_KEY, tr("Way to %s") % TravelData.display_name(String(active_portal.get("to_map", "")))]
		elif mounted():
			text = tr("Mounted - the castle door is closed to broom flight. Dismount to enter.")
		else:
			text = tr("Press %s - %s") % [PROMPT_KEY, tr("Way to %s") % TravelData.display_name(String(active_portal.get("to_map", "")))]
	elif not active_waylink.is_empty():
		text = (tr("Press %s - Let go of the Waylink (to %s)") if bool(active_waylink.get("holding", false)) \
			else tr("Press %s - Grab hold of the Waylink (to %s)")) % [PROMPT_KEY, I18n.t(String(active_waylink.get("label", "")))]
	elif active_node != "":
		text = tr("Press %s - %s") % [PROMPT_KEY, _node_prompt(active_node)]
	# The Hearth window stands where the prompt is drawn: the prompt waits.
	if hearthway.visible:
		if active_node != hearthway.node_id:
			hearthway.close()
		else:
			text = ""
	# So does a dungeon's gate window; it closes when the body leaves the gate.
	var gate: HudDungeon = game.dungeon.gate_window
	if gate.visible:
		if String(active_portal.get("id", "")) != gate.portal_id:
			gate.close()
		else:
			text = ""
	_set_prompt(text)

## A door into an instanced map from outside one: a dungeon's gate.
func _is_gate(portal: Dictionary) -> bool:
	return TravelData.instanced(String(portal.get("to_map", ""))) and not TravelData.instanced(map_name)

func _set_prompt(text: String) -> void:
	prompt = text
	if _prompt_label != null and _prompt_label.text != text:
		_prompt_label.text = text

func _portal_contains(portal: Dictionary, point: Vector3) -> bool:
	var trigger: Dictionary = portal.get("trigger", {})
	if point.y < float(trigger.get("y_min", -1000.0)) or point.y > float(trigger.get("y_max", 1000.0)):
		return false
	var centre: Array = trigger.get("center", [0.0, 0.0, 0.0])
	var dx := point.x - float(centre[0])
	var dz := point.z - float(centre[2])
	var radius := float(trigger.get("radius", 0.0))
	return dx * dx + dz * dz <= radius * radius

## The prompt over a travel object: the Hearthway, or a twin link's own words
## and where it leads.
func _node_prompt(node_id: String) -> String:
	var node := TravelData.node(node_id)
	if String(node.get("kind", "")) == "hearthway":
		return tr("Hearthway (%s)") % I18n.t(String(node.get("label", "")))
	var pair := TravelData.node(String(node.get("pair", "")))
	return tr("%s (to %s)") % [I18n.t(String(node.get("prompt", "Use"))), I18n.t(String(pair.get("label", "")))]

## F: a door, a Waylink, a travel object. True when F was this one's.
func interact() -> bool:
	if leaving or nodes == null:
		return false
	if not active_portal.is_empty():
		if _is_gate(active_portal):
			game.dungeon.open_gate(String(active_portal.get("id", "")))
			return true
		if mounted():
			_refuse(tr("Dismount before entering - the broom cannot fly inside the castle."))
			return true
		doors_asked += 1
		game.session.door(String(active_portal.get("id", "")))
		return true
	if not active_waylink.is_empty():
		game.session.waylink_hold(int(active_waylink["id"]), not bool(active_waylink.get("holding", false)))
		return true
	if active_node == "":
		return false
	if String(TravelData.node(active_node).get("kind", "")) == "hearthway":
		hearthway.open_at(active_node)
	else:
		_passage_depart(active_node)
	return true

## Shift: on or off the broom (the server's answer mounts the body).
func toggle_ride() -> void:
	if leaving:
		return
	rides_asked += 1
	game.session.ride(not mounted())

## The Hearth window's Travel: the powder catches and the green flames roar
## up in the hearth; the trip is asked for as they peak.
func _hearth_depart(from_node: String, dest_node: String) -> void:
	TravelNodes.burst(game, nodes.mouth(from_node), "hearthway")
	await get_tree().create_timer(HEARTH_DELAY).timeout
	if is_instance_valid(game) and game.session != null:
		game.session.travel(from_node, dest_node)

## A Twinned Cabinet or the Stone Raven's passage: no window, the link has
## one end.
func _passage_depart(node_id: String) -> void:
	TravelNodes.burst(game, nodes.mouth(node_id), String(TravelData.node(node_id).get("kind", "")))
	await get_tree().create_timer(PASSAGE_DELAY).timeout
	if is_instance_valid(game) and game.session != null:
		game.session.travel(node_id, "")

## The travel game events (main.gd hands each over).
func on_event(event: Dictionary) -> void:
	match String(event["kind"]):
		"travel_result":
			results.append(event)
			if not bool(event["ok"]):
				var text := refusal_text(String(event["what"]), String(event["reason"]))
				last_refusal = text
				if text != "":
					_refuse(text)
		"departing":
			departures.append(event)
			var to := String(event["map"])
			if to == map_name:
				_fade()
			else:
				_leave(to)
		"travel":
			_travel(String(event["map"]))
		"arrived":
			arrivals.append(String(event["trip"]))
			_pending_arrival = String(event["trip"])
			if _loading_done:
				_play_arrival()
		"waylink":
			waylinks.on_event(event)

func _refuse(text: String) -> void:
	game.hud.show_notice(text, "warn")
	AudioManager.play_deny()

## A same-map trip: down to black, the teleport lands, back up.
func _fade() -> void:
	fades += 1
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_fade_rect, "color:a", 1.0, FADE_OUT)
	_fade_tween.tween_interval(FADE_HOLD)
	_fade_tween.tween_property(_fade_rect, "color:a", 0.0, FADE_IN)

## The fade's darkness now (0 clear .. 1 black), for the checks.
func fade_alpha() -> float:
	return _fade_rect.color.a if _fade_rect != null else 0.0

## Off to another map: the loading screen comes up over the old one.
func _leave(to_map: String) -> void:
	if leaving:
		return
	leaving = true
	hearthway.close()
	waylink_window.close()
	game.dungeon.gate_window.close()
	var screen := MapLoadingScreen.shared(get_tree())
	await screen.open(_loading_title(to_map), _loading_text(to_map))
	screen.set_progress(10.0, tr("Leaving %s…") % _place_name(map_name))

## The new map's ticket came: the scene is rebuilt for it (main.gd joins with
## start_travel), behind the loading screen.
func _travel(to_map: String) -> void:
	if reloading:
		return
	reloading = true
	if not leaving:
		await _leave(to_map)
	var screen := MapLoadingScreen.shared(get_tree())
	while not screen.is_covering():
		await get_tree().process_frame
	screen.set_progress(20.0, _loading_text(to_map))
	game.before_reload()
	get_tree().reload_current_scene()

## The new map is drawn and settled: the loading screen lifts, and the body
## steps out of the arrival flames.
func _finish_loading() -> void:
	await MapLoadingScreen.shared(get_tree()).close()
	_loading_done = true
	if _pending_arrival != "":
		_play_arrival()

func _play_arrival() -> void:
	var kind := _pending_arrival
	_pending_arrival = ""
	var at: Vector3 = game.session.own_position()
	match kind:
		"hearthway", "cabinet", "passage", "waylink":
			TravelNodes.burst(game, at, kind)
		_:
			# through a door: it opens onto a hall or a dungeon, and shuts
			# behind on the way back out (the old game's door pair)
			var out := map_name == "grounds" or map_name == "spider_caverns"
			AudioManager.play_sound_at("door_close" if out else "door_open", at, null, false)

func _loading_title(map_id: String) -> String:
	return I18n.upper(TravelData.display_name(map_id))

func _loading_text(map_id: String) -> String:
	match map_id:
		"castle_interior":
			return tr("Entering Kaf Castle...")
		"grounds":
			return tr("Returning to the Grounds...")
	return tr("Entering %s...") % TravelData.display_name(map_id)

func _place_name(map_id: String) -> String:
	match map_id:
		"castle_interior":
			return tr("the castle")
		"grounds":
			return tr("the grounds")
	return TravelData.display_name(map_id)

## A refused trip in the player's words, by what was asked and why.
func refusal_text(what: String, reason: String) -> String:
	if what == "ride":
		match reason:
			"not_grounded":
				return tr("Take off from the ground!")
			"casting":
				return tr("Finish casting first.")
			"no_landing":
				return tr("Descend near level ground first (Ctrl)")
			"transfer_pending":
				return tr("The map is still loading!")
			"no_flight":
				return tr("Flight is not allowed on this map!")
			"no_broom":
				return tr("You have no mount - equip a broom first.")
			"dead":
				return tr("You are defeated!")
			"stunned":
				return tr("You are stunned!")
			"in_combat":
				return tr("Wait five seconds after combat.")
		return tr("You cannot mount right now.")
	match reason:
		"mounted":
			if what == "door":
				return tr("Dismount before entering - the broom cannot fly inside the castle.")
			if what == "hearthway":
				return tr("Dismount before stepping into the fireplace.")
			return tr("Not while mounted!")
		"no_item":
			return tr("You have no Waylink boot.") if what == "waylink" else tr("You have no Hearth Dust - buy a pinch at the fireplace.")
		"in_combat":
			if what == "hearthway":
				return tr("The flames will not take you while you are fighting.")
			return tr("Wait five seconds after combat.")
		"level_too_low":
			if what == "door":
				return tr("You are not experienced enough to enter.")
			return tr("Your level is too low for that destination.")
		"out_of_range":
			return tr("Stand closer to the door.") if what == "door" else tr("Move closer and try again.")
		"no_portal":
			return tr("There is no doorway here.")
		"no_flight":
			return tr("The broom cannot fly inside the castle - dismount on the landing pad first.")
		"map_unavailable":
			return tr("The destination map is unavailable.")
		"map_full":
			return tr("The destination is full right now.")
		"transfer_pending":
			return tr("A transfer is already in progress.")
		"aborted":
			return tr("The transfer was cancelled.")
		"dead":
			return tr("You are defeated!")
		"stunned":
			return tr("You are stunned!")
		"casting":
			return tr("Finish casting first.")
		"in_dungeon":
			return tr("A Waylink will not work in here.")
		"waylink_active":
			return tr("Your Waylink is already waiting - grab hold of it.")
		"waylink_gone":
			return tr("That Waylink has already gone.")
		"not_in_party":
			return tr("That Waylink is not yours - only its owner's party may hold on.")
	return tr("Transfer refused (%s).") % reason if reason != "" else ""
