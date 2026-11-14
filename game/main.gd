extends Node3D

## The realm client's first view. Everything that happens comes from the
## RealmSession extension node (Rust): this script reads the controls, hands
## them over, and draws what the session reports. Players are the real hero
## (HeroView); the map is still grey collision geometry and creatures are
## capsules until their scenes move over.
##
##   godot --path game -- [--server 127.0.0.1:7777] [--map grounds]
##   godot --headless --path game -- --check 20     joins, walks, prints, quits
##   [--cam-distance 4] [--cam-side 90]              camera framing (captures)
##   [--open-bag 1]                                   start with the inventory open
##   [--character 7]                                  play this dev character (saved when the
##                                                    server runs with --characters)
##
## Controls: WASD move, Space jump, Ctrl descend, right-drag turns the camera,
## wheel zooms. Left-click picks under the cursor: a creature becomes the target
## and takes a basic cast, anything else takes the basic cast at that point.
## Tab cycles the nearest living creatures, Esc closes the bag or drops the
## target, I opens the bag; the action bar reads 1-4, Q, E, 5, 6 and F1-F4.
## The check mode also fights: it targets the nearest creature, learns and casts
## Shockwave once, then the basic cast every CHECK_CAST_SECONDS (or, with
## `--check-spells stun_bolt,flame_wave,...`, those spells in turn: a capture of
## the status looks on a character that knows them). It fails when none of its
## casts hit or when no creature it hit was ever seen thrown (STATUS_KNOCKED);
## the final line prints the status bits seen on its target.
##
## Paths to keys/, content/data and world/maps default to the realm checkout
## the project sits in.

const KIND_COLORS := [Color(0.35, 0.65, 1.0), Color(0.85, 0.3, 0.25), Color(0.9, 0.6, 0.2),
	Color(0.55, 0.8, 0.3), Color(0.7, 0.4, 0.85), Color(0.9, 0.85, 0.3)]

const HeroViewScript := "res://scripts/view/hero_view.gd"
const PlayerSheetScript := "res://scripts/view/player_sheet.gd"
const HudScript := "res://scripts/ui/hud.gd"
const InventoryScript := "res://scripts/ui/inventory_arcane.gd"
## Entity kind of a player in snapshots (creatures carry their species index
## + 1, with CreatureView.ELITE_BIT set for an elite).
const KIND_PLAYER := 0
## An elite's name on the target card (the old game's elite label colour).
const ELITE_NAME_COLOR := Color(1.0, 0.9, 0.35)
## Where a cast aims on a creature, above its feet (the server's chest height).
const CHEST := 1.15
## How far the cursor's pick ray reaches, and how near Tab looks for creatures.
const PICK_REACH := 200.0
const TAB_RANGE := 30.0
const CHECK_CAST_SECONDS := 0.6
const HELD_NOTICE_SECONDS := 0.8

var session: Node
var player: Node3D
## Other players' heroes by entity id.
var heroes := {}
## The player's sheet for the windows, the HUD and the windows.
var sheet_view: PlayerSheet
var hud: Control
var inventory: Control
## Casts, bolts, impacts, bursts, wards and damage numbers.
var combat: CombatView
## The selected creature (entity id, 0 = none).
var target := 0
## This frame's snapshot of everyone else (RealmSession.remote) and every
## body's drawn position by entity id, own included.
var others: Dictionary = {}
var drawn: Dictionary = {}
## Creatures with a model by entity id (CreatureView); species without one yet
## are drawn as capsules.
var beasts := {}
## Species kinds (elite bit masked) with no model in this client yet.
var no_model := {}
const CreatureViewScript := "res://scripts/view/creature_view.gd"
var house_color := Color(0.85, 0.4, 0.11)
var crowd: MultiMeshInstance3D
var camera: Camera3D
## The connection readout, top-right.
var readout: Label
var cam_yaw := 0.0
var cam_pitch := -0.35
var cam_distance := 9.0
## Extra camera turn around the player that does not steer (screenshots).
var cam_side := 0.0
var check_seconds := 0.0
var check_started := 0.0
var check_cast_wait := 0.0
## What the check saw of its own fight: casts begun, hits landed and the hp
## byte (0..255) its last hit left the creature at.
var check_casts := 0
var check_hits := 0
var check_hp := -1
## The check also learns Shockwave with its free skill point and casts it once
## (the skill request, an area burst).
var check_learn_sent := false
var check_shockwave_cast := false
var check_bursts := 0
## Status bits seen on each creature (entity id -> union), the creatures the
## check's own hits landed on, and the union seen on its target.
var check_statuses := {}
var check_hit_ids := {}
var check_target_statuses := 0
## The union of status bits the creatures put on the player.
var check_own_statuses := 0
## `--check-spells`: the rotation the check casts instead of the basic cast.
var check_spells: PackedStringArray = []
var check_spell_next := 0
var built := false
## When the next "you are stunned" notice may show.
var _held_notice_at := 0.0

func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback

func _ready() -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	check_seconds = float(_arg("--check", "0"))
	cam_distance = float(_arg("--cam-distance", str(cam_distance)))
	cam_side = deg_to_rad(float(_arg("--cam-side", "0")))
	var rotation_arg := _arg("--check-spells", "")
	if rotation_arg != "":
		check_spells = rotation_arg.split(",", false)
	if not ClassDB.class_exists("RealmSession"):
		printerr("realm: the realm_client extension did not load (cargo build --release -p realm_client)")
		get_tree().quit(2)
		return
	if not ClassDB.class_call_static("RealmContent", "load", _arg("--content", root.path_join("content/data"))):
		printerr("realm: content/data could not be read")
		get_tree().quit(1)
		return
	var houses: Variant = ClassDB.class_call_static("RealmContent", "table", "houses")
	if houses is Dictionary and (houses as Dictionary).has("velkar"):
		house_color = Color.html(String(houses["velkar"].get("primary_color", "#d9661c")))
	session = ClassDB.instantiate("RealmSession")
	add_child(session)
	var ok: bool = session.start_dev(_arg("--server", "127.0.0.1:7777"), _arg("--keys", root.path_join("keys")),
		_arg("--content", root.path_join("content/data")), _arg("--maps", root.path_join("world/maps")),
		_arg("--map", "grounds"), int(_arg("--character", "0")))
	if not ok:
		printerr("realm: ", session.status())
		get_tree().quit(1)
		return
	_build_view()

func _build_view() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(35), 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.68, 0.82)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.52, 0.55)
	add_child(env)
	player = _new_hero()
	player.is_local_player = true
	crowd = MultiMeshInstance3D.new()
	crowd.multimesh = MultiMesh.new()
	crowd.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	crowd.multimesh.use_colors = true
	crowd.multimesh.mesh = _capsule(Color.WHITE)
	add_child(crowd)
	camera = Camera3D.new()
	camera.far = 3000.0
	add_child(camera)
	combat = CombatView.new()
	combat.player = player
	combat.heroes = heroes
	combat.beasts = beasts
	combat.session = session
	add_child(combat)
	StatusFX.warm_assets()
	readout = Label.new()
	readout.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	readout.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	readout.offset_right = -12
	readout.offset_top = 10
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.add_theme_font_size_override("font_size", 12)
	var layer := CanvasLayer.new()
	layer.add_child(readout)
	add_child(layer)
	_build_ui()

## The interface: a full-screen root holding the HUD ("HUD", which the windows
## look for) and the inventory (I).
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	var root := Control.new()
	root.name = "UI"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	sheet_view = load(PlayerSheetScript).new(session)
	add_child(sheet_view)
	hud = load(HudScript).new()
	root.add_child(hud)
	hud.setup(session, sheet_view, toggle_inventory)
	hud.action_bar.spell_requested.connect(cast_spell)
	inventory = load(InventoryScript).new()
	inventory.name = "Inventory"
	root.add_child(inventory)
	inventory.prepare(sheet_view)
	if _arg("--open-bag", "") != "":
		inventory.open_for_player(sheet_view)

func toggle_inventory() -> void:
	if inventory.visible:
		inventory.hide()
	else:
		inventory.open_for_player(sheet_view)

## The player's hero wears the look the sheet carries (applied when it
## changes).
var _shown_look := {}

func _apply_sheet_look(sheet: Dictionary) -> void:
	# The hand shows the worn wand (none when the slot is empty).
	player.show_wand((sheet["equipment"] as Dictionary).get("main_hand", {}))
	var look: Dictionary = sheet["look"]
	if look == _shown_look or player.body == null:
		return
	_shown_look = look.duplicate()
	HeroAppearance.apply_look(player.body, Looks.clean_look(look))

func _new_hero() -> Node3D:
	var hero: Node3D = load(HeroViewScript).new()
	add_child(hero)
	hero.setup(house_color)
	return hero

func _capsule(color: Color) -> Mesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.85
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.vertex_color_use_as_albedo = true
	mesh.material = material
	return mesh

## Map geometry arrives once the session has joined (it needs the pack).
func _build_map() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.47, 0.38)
	var terrain: ArrayMesh = session.terrain_mesh(2)
	if terrain != null:
		var node := MeshInstance3D.new()
		node.mesh = terrain
		node.material_override = material
		add_child(node)
	var walls: ArrayMesh = session.collider_mesh()
	if walls != null:
		var node := MeshInstance3D.new()
		node.mesh = walls
		var stone := StandardMaterial3D.new()
		stone.albedo_color = Color(0.62, 0.6, 0.56)
		node.material_override = stone
		add_child(node)
	built = true

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_I:
				toggle_inventory()
			KEY_TAB:
				cycle_target()
			KEY_ESCAPE:
				if inventory.visible:
					inventory.hide()
				else:
					select_target(0)
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clampf(cam_pitch - event.relative.y * 0.004, -1.3, 0.4)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and built:
			click_world(event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = maxf(2.0, cam_distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = minf(60.0, cam_distance * 1.1)

## ----------------------------------------------------------------- targeting

## What lies under the screen point `at`: {entity, point} (RealmSession.pick).
func pick_at(at: Vector2) -> Dictionary:
	return session.pick(camera.project_ray_origin(at), camera.project_ray_normal(at), PICK_REACH)

## A left click on the world: a creature under the cursor becomes the target
## and takes the basic cast; otherwise the basic cast goes to the point there.
func click_world(at: Vector2) -> void:
	var hit := pick_at(at)
	if hit.is_empty():
		return
	var entity := int(hit["entity"])
	if _creature_index(entity) >= 0:
		select_target(entity)
		cast_spell("basic_cast")
	elif not _held_refusal():
		session.cast("basic_cast", 0, hit["point"])

## Casts `spell` at the target's chest, or with no target at the point under
## the cursor.
func cast_spell(spell: String) -> void:
	if _held_refusal():
		return
	if target != 0 and drawn.has(target):
		session.cast(spell, target, (drawn[target] as Vector3) + Vector3(0, CHEST, 0))
		return
	var hit := pick_at(get_viewport().get_mouse_position())
	if not hit.is_empty():
		session.cast(spell, 0, hit["point"])

## The index of living creature `id` in this frame's snapshot, -1 when it is
## not one (a player, a dead creature, gone).
func _creature_index(id: int) -> int:
	if id == 0 or others.is_empty():
		return -1
	var i := (others["ids"] as PackedInt32Array).find(id)
	if i < 0 or (others["kinds"] as PackedInt32Array)[i] == KIND_PLAYER 			or (others["states"] as PackedInt32Array)[i] == CreatureView.STATE_DEAD:
		return -1
	return i

## Show creature `id` on the target card (0 clears the target).
func select_target(id: int) -> void:
	var i := _creature_index(id)
	target = id if i >= 0 else 0
	if target == 0:
		hud.set_target(0)
		return
	var kind := (others["kinds"] as PackedInt32Array)[i]
	var species := CreatureView.species_for_kind(kind)
	var mobs: Variant = RealmContent.table("mobs")
	var entry: Dictionary = (mobs as Dictionary).get("mobs", {}).get(species, {}) if mobs is Dictionary else {}
	var title := I18n.mob_name(String(entry.get("display", species.capitalize())))
	if CreatureView.is_elite(kind):
		hud.set_target(target, tr("Elite %s") % title, (others["hp"] as PackedInt32Array)[i], ELITE_NAME_COLOR)
	else:
		hud.set_target(target, title, (others["hp"] as PackedInt32Array)[i])

## Living creatures within `reach` of the player, nearest first.
func _creatures_near(reach: float) -> Array:
	var me: Vector3 = drawn.get(session.own_entity(), Vector3.ZERO)
	var near: Array = []
	var ids: PackedInt32Array = others.get("ids", PackedInt32Array())
	for i in ids.size():
		if _creature_index(ids[i]) < 0:
			continue
		var distance := me.distance_to((others["positions"] as PackedVector3Array)[i])
		if distance <= reach:
			near.append([distance, ids[i]])
	near.sort_custom(func(a, b): return a[0] < b[0])
	return near.map(func(pair): return pair[1])

## Tab: the next of the nearest living creatures, from the current target.
func cycle_target() -> void:
	var near := _creatures_near(TAB_RANGE)
	if near.is_empty():
		select_target(0)
		return
	select_target(near[(near.find(target) + 1) % near.size()])

## The target card follows the snapshot; a dead or vanished target is dropped.
func _follow_target() -> void:
	if target == 0:
		return
	var i := _creature_index(target)
	if i < 0:
		select_target(0)
	else:
		hud.set_target_health((others["hp"] as PackedInt32Array)[i])

## The frame's combat events, taken once and handed to everything that shows
## them.
func _show_combat() -> void:
	var own := int(session.own_entity())
	combat.own_id = own
	combat.drawn = drawn
	for event: Dictionary in session.take_combat_events():
		combat.show_event(event)
		match String(event["kind"]):
			"hit":
				hud.on_hit(event)
				if int(event["attacker"]) == own:
					check_hits += 1
					check_hp = int(event["hp"])
					check_hit_ids[int(event["target"])] = true
			"cast_started":
				if int(event["caster"]) == own:
					check_casts += 1
			"burst":
				if int(event["caster"]) == own:
					check_bursts += 1
			"cast_refused":
				_say_refusal(String(event["spell"]), String(event["reason"]))

## Stunned or thrown (own_body `held`): the server refuses every cast, so none
## is sent and the notice band says why, at most every HELD_NOTICE_SECONDS.
func _held_refusal() -> bool:
	var own: Dictionary = session.own_body()
	if not bool(own.get("held", false)):
		return false
	var now := Time.get_ticks_msec() / 1000.0
	if now >= _held_notice_at:
		_held_notice_at = now + HELD_NOTICE_SECONDS
		var bits := int(own.get("status", 0))
		var text := tr("You are stunned!")
		if bits & StatusFX.STATUS_KNOCKED:
			text = tr("You were knocked off your feet!")
		elif bits & StatusFX.STATUS_FREEZE:
			text = tr("You are frozen!")
		hud.show_notice(text, "warn")
		AudioManager.play_deny()
	return true

## Why a cast of the player's was refused, on the notice band (a cooldown or an
## unknown spell needs no words).
func _say_refusal(spell: String, reason: String) -> void:
	var data: Dictionary = HudActionBar.spells().get(spell, {})
	var text := ""
	match reason:
		"no_mana":
			text = tr("Not enough Mana!")
		"mounted":
			text = tr("Not while mounted!")
		"no_wand":
			text = tr("Equip a wand first")
		"level":
			text = tr("Your level is too low for that spell")
		"skill_locked":
			text = tr("Learn %s first - click its slot to spend a skill point") % I18n.t(String(data.get("name", spell)))
	if text != "":
		hud.show_notice(text, "warn")
		AudioManager.play_deny()

## The check fights the nearest creature: a new target when it has none, a
## basic cast every CHECK_CAST_SECONDS.
func _check_fight(delta: float) -> void:
	check_cast_wait -= delta
	if check_cast_wait > 0.0:
		return
	check_cast_wait = CHECK_CAST_SECONDS
	if target == 0:
		var near := _creatures_near(INF)
		if not near.is_empty():
			select_target(near[0])
	if bool(session.own_body().get("held", false)):
		# stunned or thrown: nothing can be cast until the body is free
		return
	if not check_learn_sent:
		check_learn_sent = true
		session.learn_skill("shockwave")
	if target != 0:
		if not check_shockwave_cast and int(session.skill_level("shockwave")) > 0:
			check_shockwave_cast = true
			cast_spell("shockwave")
		elif not check_spells.is_empty():
			cast_spell(check_spells[check_spell_next % check_spells.size()])
			check_spell_next += 1
		else:
			cast_spell("basic_cast")

## The status bits every creature in view carries this frame, gathered for the
## check's verdict.
func _check_statuses(ids: PackedInt32Array, kinds: PackedInt32Array, statuses: PackedInt32Array) -> void:
	for i in ids.size():
		if kinds[i] == KIND_PLAYER or statuses[i] == 0:
			continue
		check_statuses[ids[i]] = int(check_statuses.get(ids[i], 0)) | statuses[i]
		if ids[i] == target:
			check_target_statuses |= statuses[i]

## The status bits seen on any creature the check's hits landed on.
func _check_hit_statuses() -> int:
	var seen := 0
	for id in check_hit_ids:
		seen |= int(check_statuses.get(id, 0))
	return seen

## Status bits as names: "stun+knocked".
static func _status_names(bits: int) -> String:
	var names := PackedStringArray()
	for pair in [[StatusFX.STATUS_STUN, "stun"], [StatusFX.STATUS_FREEZE, "freeze"], [StatusFX.STATUS_SLOW, "slow"],
			[StatusFX.STATUS_BLEED, "bleed"], [StatusFX.STATUS_BURN, "burn"], [StatusFX.STATUS_POISON, "poison"],
			[StatusFX.STATUS_KNOCKED, "knocked"], [StatusFX.STATUS_WEAK, "weak"]]:
		if bits & int(pair[0]):
			names.append(String(pair[1]))
	return "+".join(names) if not names.is_empty() else "none"

func _process(delta: float) -> void:
	if session == null:
		return
	var status: String = session.status()
	if status != "joined":
		if readout != null:
			readout.text = "realm: " + status
		if status.begins_with("refused") or status.begins_with("closed"):
			printerr("realm: ", status)
			get_tree().quit(1)
		return
	if not built:
		_build_map()
		check_started = Time.get_ticks_msec() / 1000.0
	var strafe := 0.0
	var forward := 0.0
	var jump := false
	if check_seconds > 0.0:
		# Walks (and hops) for the first third, then stands and fights.
		var walking := Time.get_ticks_msec() / 1000.0 - check_started < check_seconds / 3.0 or target == 0
		forward = 1.0 if walking else 0.0
		cam_yaw += 0.004
		jump = walking and int(Time.get_ticks_msec() / 1500) % 4 == 3
	else:
		strafe = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		forward = float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		jump = Input.is_physical_key_pressed(KEY_SPACE)
	session.set_intent(strafe, forward, cam_yaw, jump, Input.is_physical_key_pressed(KEY_CTRL))

	var own: Dictionary = session.own_body()
	var me: Vector3 = own.get("position", Vector3.ZERO)
	if not own.is_empty():
		player.drive_own(own, delta)
		player.set_status(int(own.get("status", 0)))
		check_own_statuses |= int(own.get("status", 0))
	var look_at_point := me + Vector3(0, 1.5, 0)
	var offset := Vector3(0, 0, cam_distance).rotated(Vector3.RIGHT, cam_pitch).rotated(Vector3.UP, cam_yaw + cam_side)
	camera.position = look_at_point + offset
	camera.look_at(look_at_point)

	others = session.remote()
	var ids: PackedInt32Array = others["ids"]
	var positions: PackedVector3Array = others["positions"]
	var kinds: PackedInt32Array = others["kinds"]
	var yaws: PackedFloat32Array = others["yaws"]
	var states: PackedInt32Array = others["states"]
	var statuses: PackedInt32Array = others["statuses"]
	var seen := {}
	var creatures := 0
	drawn = {session.own_entity(): me}
	crowd.multimesh.instance_count = positions.size()
	for i in positions.size():
		drawn[ids[i]] = positions[i]
		if kinds[i] == KIND_PLAYER:
			seen[ids[i]] = true
			if not heroes.has(ids[i]):
				heroes[ids[i]] = _new_hero()
			heroes[ids[i]].drive_remote(positions[i], delta)
			heroes[ids[i]].set_status(statuses[i])
			continue
		var species_kind := kinds[i] & CreatureView.SPECIES_MASK
		if not no_model.has(species_kind):
			seen[ids[i]] = true
			if not beasts.has(ids[i]):
				var beast: Node3D = load(CreatureViewScript).new()
				add_child(beast)
				if beast.setup(kinds[i]):
					beasts[ids[i]] = beast
				else:
					beast.queue_free()
					no_model[species_kind] = true
			if beasts.has(ids[i]):
				beasts[ids[i]].set_status(statuses[i])
				beasts[ids[i]].drive(positions[i], yaws[i], states[i], delta)
				continue
		crowd.multimesh.set_instance_transform(creatures, Transform3D(Basis(), positions[i] + Vector3(0, 0.925, 0)))
		crowd.multimesh.set_instance_color(creatures, KIND_COLORS[species_kind % KIND_COLORS.size()])
		creatures += 1
	crowd.multimesh.visible_instance_count = creatures
	for table: Dictionary in [heroes, beasts]:
		for id in table.keys():
			if not seen.has(id):
				table[id].queue_free()
				table.erase(id)
	_follow_target()
	if check_seconds > 0.0:
		_check_fight(delta)
		_check_statuses(ids, kinds, statuses)
	_show_combat()

	var stats: Dictionary = session.stats()
	readout.text = "realm  %d fps  tick %d  hp %d  snapshots %d  corrections %d (max %.3f m)  server moves %d
%s  %d others in view" % [
		Engine.get_frames_per_second(), stats.get("tick", 0), stats.get("hp", 0), stats.get("snapshots", 0),
		stats.get("corrections", 0), stats.get("max_correction", 0.0), stats.get("server_moves", 0),
		str(me.snapped(Vector3(0.1, 0.1, 0.1))),
		positions.size()]
	if player.anim != null:
		readout.text += "  pose %s" % player.anim.current_clip
	var sheet: Dictionary = session.sheet()
	if not sheet.is_empty():
		var bag: Array = sheet["bag"]
		var items := bag.filter(func(c): return c != null).map(
			func(c): return "%s x%d" % [c["id"], c["amount"]])
		readout.text += "
%s (%s)  level %d  hp %d/%d  mana %d/%d  %d oril  wields %s
bag: %s" % [
			sheet["name"], sheet["house"], sheet["level"], sheet["hp"], sheet["max_hp"], sheet["mana"],
			sheet["max_mana"], sheet["oril"], (sheet["equipment"] as Dictionary).get("main_hand", {}).get("id", "-"),
			", ".join(items)]
		_apply_sheet_look(sheet)

	if check_seconds > 0.0 and Time.get_ticks_msec() / 1000.0 - check_started > check_seconds:
		print("realm check: ", readout.text.replace("
", " | "),
			" | fight: %d own casts started, %d own hits, %d own bursts, target hp %d/255" % [check_casts, check_hits, check_bursts, check_hp],
			" | statuses: target %s (%d), hit creatures %s (%d)" % [_status_names(check_target_statuses),
				check_target_statuses, _status_names(_check_hit_statuses()), _check_hit_statuses()],
			" | creatures: %d telegraphs (%d released, %d called off), %d boulders, %d bolts, %d evades, own statuses %s" % [
				combat.telegraphs_seen, combat.telegraphs_released, combat.telegraphs_cancelled, combat.boulders_thrown,
				combat.creature_bolts, combat.evades_shown, _status_names(check_own_statuses)])
		var passed := int(stats.get("corrections", 0)) == 0 and int(stats.get("snapshots", 0)) > 0 and check_hits > 0 \
			and check_bursts > 0 and _check_hit_statuses() & StatusFX.STATUS_KNOCKED != 0
		get_tree().quit(0 if passed else 1)
