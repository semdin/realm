extends Node3D
class_name WaylinkViews

## Waylinks on the client, from the `waylink` game events the server sends to
## the owner and the owner's party (RealmSession.take_game_events):
##   * the owner reaches down and sets the boot on the ground (its
##     Waylink_Place clip; the boot appears as the hand comes down);
##   * a soft blue aura (flipbook) and blue motes lifting off its reach mark it, with
##     a countdown over it;
##   * everyone holding on kneels with a hand on the boot (the Place clip held)
##     on every viewer's screen; moving away lets go;
##   * when it fires a blue-white whirlwind snaps the holders away; a Waylink
##     nobody holds just fades.
## MapTravel asks `grab_candidate` which boot the local body could hold.

const BOOT := "res://assets/models/travel/waylink_boot.glb"
const WorldSign := preload("res://scripts/world/world_sign.gd")
const BLUE := Color(0.5, 0.75, 1.0)
## The owner's hand reaches the ground this long into the Place clip.
const DROP_DELAY := 0.9
## A boot whose end the server's word never reached goes this long after its
## countdown (seconds).
const STALE_AFTER := 3.0

## main.gd: the session, the local hero and the other heroes by entity id.
var game: Node
## id -> {root, label, state, holders}
var views: Dictionary = {}
## How many boots were drawn, fired and fizzled (checks).
var placed_seen := 0
var fired_seen := 0
var _letting_go := false

func _session() -> Node:
	return game.session if game != null else null

func _me() -> int:
	var s := _session()
	return int(s.own_entity()) if s != null else 0

## The hero drawn for entity `id` (the local one included), or null.
func _body(id: int) -> Node3D:
	if id == _me():
		return game.player
	var hero: Node3D = game.heroes.get(id)
	return hero if hero != null and is_instance_valid(hero) else null

## One `waylink` game event.
func on_event(event: Dictionary) -> void:
	var id := int(event.get("id", 0))
	var phase := int(event.get("phase", 0))
	var at: Vector3 = event.get("pos", Vector3.ZERO)
	var holders: Array = Array(event.get("holders", PackedInt32Array()))
	match phase:
		0:
			if not views.has(id):
				views[id] = _build(event)
				placed_seen += 1
				var owner := int(event.get("owner", 0))
				var owner_body := _body(owner)
				if owner_body != null and owner_body.has_method("waylink_place"):
					owner_body.waylink_place(at)
				if owner != _me():
					var who := String(event.get("owner_name", ""))
					_notice(tr("%s set down a Waylink to %s - hold on to it! (%s)") % [who if who != "" else tr("A party member"),
						I18n.t(String(event.get("label", ""))), GameSettings.key_name("interact")])
			var view: Dictionary = views[id]
			view["state"] = event
			_sync_holders(view, holders, at)
		1:
			fired_seen += 1
			var view: Dictionary = views.get(id, {})
			for holder in holders:
				var body := _body(int(holder))
				if body != null:
					TravelNodes.burst(get_parent(), body.global_position, "waylink")
			if holders.is_empty():
				AudioManager.play_sound_at("waylink_whoosh", at, null, false)
			if not view.is_empty():
				_sync_holders(view, [], at)
			_drop(id)
		_:
			if int(event.get("owner", 0)) == _me():
				_notice(tr("The Waylink fizzled - nobody was holding on. The boot is back in your bag."))
			var view: Dictionary = views.get(id, {})
			if not view.is_empty():
				_sync_holders(view, [], at)
			_drop(id)

## Kneel the bodies that hold on, stand up those that let go.
func _sync_holders(view: Dictionary, holders: Array, at: Vector3) -> void:
	var before: Array = view.get("holders", [])
	for id in holders:
		if not before.has(id):
			var body := _body(int(id))
			if body != null and body.has_method("waylink_kneel"):
				body.waylink_kneel(at)
	for id in before:
		if not holders.has(id):
			var body := _body(int(id))
			if body != null and body.has_method("waylink_release"):
				body.waylink_release()
	view["holders"] = holders.duplicate()
	if holders.has(_me()):
		_letting_go = false

func _drop(id: int) -> void:
	var view: Dictionary = views.get(id, {})
	if view.has("root") and is_instance_valid(view["root"]):
		var root: Node3D = view["root"]
		var tw := root.create_tween()
		tw.tween_property(root, "scale", Vector3(0.01, 0.01, 0.01), 0.35)
		tw.tween_callback(root.queue_free)
	views.erase(id)

func _notice(text: String) -> void:
	if game != null and game.hud != null:
		game.hud.show_notice(text, "info")

func _build(state: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = "Waylink%d" % int(state.get("id", 0))
	add_child(root)
	root.global_position = state.get("pos", Vector3.ZERO)
	var boot_holder := Node3D.new()
	root.add_child(boot_holder)
	if ResourceLoader.exists(BOOT):
		var boot: Node3D = (load(BOOT) as PackedScene).instantiate()
		boot.scale = Vector3.ONE * 1.25
		boot.rotation = Vector3(0.0, randf() * TAU, deg_to_rad(-8.0))
		boot_holder.add_child(boot)
	# The boot appears as the owner's hand comes down, with a little settle.
	boot_holder.scale = Vector3(0.01, 0.01, 0.01)
	var tw := root.create_tween()
	tw.tween_interval(DROP_DELAY)
	tw.tween_property(boot_holder, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	FlipbookFX.play(root, root.global_position, [
		{"atlas": "waylink_aura_8x8_1k", "size": 2.0, "height": 0.85, "fps": 18.0, "loop": true, "delay": DROP_DELAY,
			"fade_in": 0.6},
	], {"life": 0.0, "light": BLUE, "light_energy": 1.6, "light_range": 4.5, "light_height": 0.6, "name": "Aura"})
	# The reach to hold on within: blue motes lifting off its edge (no drawn
	# ring or glyphs on the ground).
	var motes := RisingMotes.make(float(state.get("radius", 3.0)), 4.0, Color(0.45, 0.7, 1.0), 28, 1.8,
		Vector2(0.25, 0.9), Vector2(0.010, 0.022))
	RisingMotes.set_rate(motes, 0.6)
	root.add_child(motes)
	var label: Label3D = WorldSign.new()   # readable from afar, faded past 60 m
	label.call("setup", 60.0, 15.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font = UITheme.world_font(UITheme.W_DECO)
	label.font_size = 30
	label.outline_size = 10
	label.outline_modulate = Color(0.02, 0.04, 0.1, 0.9)
	label.modulate = Color(0.78, 0.9, 1.0)
	label.position = Vector3(0, 1.9, 0)
	label.no_depth_test = true
	root.add_child(label)
	return {"root": root, "label": label, "state": state, "holders": []}

## The server's ticks per second.
static func _hz() -> float:
	return float(ClassDB.class_call_static("RealmInfo", "sim_hz"))

## Seconds until Waylink `id` fires (0 when unknown or due).
func seconds_left(id: int) -> float:
	var view: Dictionary = views.get(id, {})
	var s := _session()
	if view.is_empty() or s == null:
		return 0.0
	var now: float = s.server_tick()
	if now < 0.0:
		return 0.0
	return maxf(0.0, (float(view["state"].get("fires_tick", 0)) - now) / _hz())

func _process(_delta: float) -> void:
	if game == null or game.session == null:
		return
	var me := _me()
	var stale: Array = []
	for id: int in views:
		var view: Dictionary = views[id]
		if not is_instance_valid(view["root"]):
			continue
		var state: Dictionary = view["state"]
		var left := seconds_left(id)
		var now: float = game.session.server_tick()
		if now >= 0.0 and now > float(state.get("fires_tick", 0)) + STALE_AFTER * _hz():
			stale.append(id)
			continue
		(view["label"] as Label3D).text = tr("Waylink to %s\n%d") % [I18n.t(String(state.get("label", ""))), ceili(left)]
		# Moving away from the boot lets go of it (one request per release).
		var holders: Array = view.get("holders", [])
		if holders.has(me) and not _letting_go:
			var v: Vector3 = game.session.own_body().get("velocity", Vector3.ZERO)
			if Vector2(v.x, v.z).length() > 1.2:
				_letting_go = true
				game.session.waylink_hold(id, false)
	for id in stale:
		var view: Dictionary = views[id]
		_sync_holders(view, [], view["state"].get("pos", Vector3.ZERO))
		_drop(id)

## The Waylink the local body at `pos` could hold (or is holding):
## {id, holding, label} or {}.
func grab_candidate(pos: Vector3) -> Dictionary:
	var me := _me()
	for id: int in views:
		var state: Dictionary = views[id]["state"]
		var d: Vector3 = pos - (state.get("pos", Vector3.ZERO) as Vector3)
		if Vector2(d.x, d.z).length() > float(state.get("radius", 3.0)) or absf(d.y) > 3.0:
			continue
		return {"id": id, "holding": (views[id].get("holders", []) as Array).has(me),
			"label": String(state.get("label", ""))}
	return {}
