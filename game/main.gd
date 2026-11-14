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
##   [--check-target stone_dark]                      the check fights the nearest of this
##                                                    species (a Dark Shard, a dummy) first
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
## casts hit or when its Shockwave landed on a creature that can be thrown and
## none it hit was ever seen thrown (STATUS_KNOCKED; a boss, a Dark Shard or a
## dummy never is);
## the final line prints the status bits seen on its target, then what it saw
## of the world: creature answers (bosses with the body and scale they wear),
## the map's notices, and the Dark Shards, dummies and bosses in view.
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
## + 1 in the low bits, CreatureView ELITE_BIT / ENRAGED_BIT / BOSS_BIT above).
const KIND_PLAYER := 0
## An elite's name on the target card (the old game's elite label colour).
const ELITE_NAME_COLOR := Color(1.0, 0.9, 0.35)
## The target card per kind of target (the old game's colours and icons):
## [tint, bar, icon].
const CARD_BOSS := [Color(1.0, 0.84, 0.36), Color(0.86, 0.10, 0.06), "ui_boss"]
const CARD_ENRAGED := [Color(1.0, 0.52, 0.26), Color(0.92, 0.32, 0.06), "status_enraged"]
const CARD_STONE := [Color(0.62, 1.0, 0.68), Color(0.20, 0.74, 0.36), "minimap_monolith"]
const CARD_DUMMY := [Color(0.78, 0.95, 0.78), Color(0.30, 0.66, 0.24), "ui_target"]
## A camera shake's swing (old SkillFX.shake_camera) and how fast it settles.
const SHAKE_SWING := 0.4
const SHAKE_SETTLE := 0.3
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
## Species kinds (marks masked) with no model in this client yet.
var no_model := {}
const CreatureViewScript := "res://scripts/view/creature_view.gd"
## Objects draw through their own views (creature_views.json "object").
const OBJECT_VIEWS := {"stone": "res://scripts/view/stone_view.gd", "dummy": "res://scripts/view/dummy_view.gd"}
## What the server said each creature is (RealmSession.take_creature_info),
## by entity id: boss_key, name, level, elite, boss.
var infos := {}
## World bosses by their name: {region, level} from the content (the notices
## name only the boss).
var _boss_sites := {}
var _shaking: Tween
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
## The creatures the check's Shockwave (its throw) landed on, with their kind.
var check_thrown_at := {}
var check_target_statuses := 0
## The union of status bits the creatures put on the player.
var check_own_statuses := 0
## `--check-spells`: the rotation the check casts instead of the basic cast.
var check_spells: PackedStringArray = []
var check_spell_next := 0
## `--check-target stone_dark`: the species the check fights first (a Dark
## Shard's waves, a dummy), when one is in view.
var check_target_species := ""
## What the check saw of the world: creature answers, bosses with the body
## they wear (entity id -> "key model xscale"), notices by kind, and the
## objects in view (entity ids).
var check_infos := 0
var check_bosses := {}
var check_notices := {}
var check_stones := {}
var check_dummies := {}
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
	check_target_species = _arg("--check-target", "")
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

## Show creature `id` on the target card (0 clears the target) and ask the
## server what it is (its own name and its level come back as creature info).
func select_target(id: int) -> void:
	var i := _creature_index(id)
	target = id if i >= 0 else 0
	if target == 0:
		hud.set_target(0)
		return
	session.inspect(target)
	_show_target_card(i)

## The target card for snapshot index `i`: its name (a boss's, a Dark
## Shard's or a dummy's own, else the species'), what kind of target it is and
## its level, as far as the server has said.
func _show_target_card(i: int) -> void:
	var kind := (others["kinds"] as PackedInt32Array)[i]
	var info: Dictionary = infos.get(target, {})
	var species := CreatureView.species_for_kind(kind)
	var object := String(CreatureView.view_of(species).get("object", ""))
	var own_name := String(info.get("name", ""))
	var title := ""
	var look := {"level": int(info.get("level", 0))}
	var card: Array = []
	match object:
		"stone":
			var beast: Node = beasts.get(target)
			title = I18n.t(own_name if own_name != "" else (String(beast.stone_name) if beast != null else "Dark Shard"))
			look["rank"] = tr("Fallen Star Shard")
			card = CARD_STONE
		"dummy":
			title = I18n.t(own_name if own_name != "" else "Training Dummy")
			look["rank"] = tr("Practice target")
			look["level"] = 0
			card = CARD_DUMMY
		_:
			if own_name != "":
				title = I18n.mob_name(own_name)
			else:
				var mobs: Variant = RealmContent.table("mobs")
				var entry: Dictionary = (mobs as Dictionary).get("mobs", {}).get(species, {}) if mobs is Dictionary else {}
				title = I18n.mob_name(String(entry.get("display", species.capitalize())))
			var enraged := kind & CreatureView.ENRAGED_BIT != 0
			if kind & CreatureView.BOSS_BIT != 0:
				look["rank"] = tr("World Boss")
				card = CARD_BOSS
			elif enraged:
				look["rank"] = tr("Enraged")
				card = CARD_ENRAGED
			else:
				look["rank"] = tr("Creature")
			if CreatureView.is_elite(kind) and own_name == "":
				title = tr("Elite %s") % title
				look["tint"] = ELITE_NAME_COLOR
			if enraged:
				title += tr(" • ENRAGED")
	if not card.is_empty():
		look["tint"] = card[0]
		look["bar"] = card[1]
		look["icon"] = card[2]
	_target_kind = kind
	hud.set_target(target, title, (others["hp"] as PackedInt32Array)[i], look)

## The kind the target card was drawn for (an enrage redraws it).
var _target_kind := -1

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
		return
	if (others["kinds"] as PackedInt32Array)[i] != _target_kind:
		_show_target_card(i)
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
				var body: Node = beasts.get(int(event["target"]))
				if body != null and body.has_method("on_hit"):
					body.on_hit(event, int(event["attacker"]) == own)
				if int(event["attacker"]) == own:
					check_hits += 1
					check_hp = int(event["hp"])
					check_hit_ids[int(event["target"])] = true
					var hit_index := _creature_index(int(event["target"]))
					if hit_index >= 0 and String(event["spell"]) == "shockwave":
						check_thrown_at[int(event["target"])] = (others["kinds"] as PackedInt32Array)[hit_index]
			"cast_started":
				if int(event["caster"]) == own:
					check_casts += 1
			"burst":
				if int(event["caster"]) == own:
					check_bursts += 1
			"cast_refused":
				_say_refusal(String(event["spell"]), String(event["reason"]))

## ------------------------------------------------------ creatures and the map

## The body for a creature of snapshot `kind`: its model (CreatureView), a Dark
## Shard (StoneView) or a dummy (DummyView); null when this client has no model
## for it yet. A boss or an object is asked what it is (its boss body's size,
## its own name) as it first appears.
func _new_beast(id: int, kind: int) -> Node3D:
	var view := CreatureView.view_for_kind(kind)
	var object := String(view.get("object", ""))
	var beast: Node3D = load(String(OBJECT_VIEWS.get(object, CreatureViewScript))).new()
	add_child(beast)
	if not beast.setup(kind):
		beast.queue_free()
		return null
	if object == "stone":
		beast.observer = player
		beast.shake = shake_camera
	if infos.has(id):
		beast.apply_info(infos[id])
	if object != "" or kind & CreatureView.BOSS_BIT != 0:
		session.inspect(id)
	return beast

## Answers to inspect: kept, handed to the body, and the target card redrawn
## when it is the target's.
func _take_creature_info() -> void:
	for info: Dictionary in session.take_creature_info():
		var id := int(info["entity"])
		infos[id] = info
		check_infos += 1
		var beast: Node = beasts.get(id)
		if beast != null:
			beast.apply_info(info)
			if bool(info.get("boss", false)) and beast is CreatureView:
				var body := beast as CreatureView
				check_bosses[id] = "%s %s x%.2f" % [info.get("boss_key", ""), body.model.scene_file_path.get_file(),
					body.model.scale.x]
		if id == target:
			var i := _creature_index(id)
			if i >= 0:
				_show_target_card(i)

## What the map announced, on the notice band in the old game's words:
## a world boss stirring, rising and falling (with its horn), a Dark Shard's
## wave and its shatter. The server sends the numbers (seconds, level, wave)
## and who felled it; where a world boss rises comes from the content.
func _show_notices() -> void:
	for notice: Dictionary in session.take_notices():
		var kind := String(notice["kind"])
		var subject := String(notice["subject"])
		check_notices[kind] = int(check_notices.get(kind, 0)) + 1
		var name := I18n.t(subject)
		var text := ""
		var band := "boss"
		match kind:
			"boss_soon":
				text = tr("%s stirs at %s - %d seconds!") % [name, I18n.t(_boss_site(subject)["region"]), int(notice["value"])]
			"boss_spawned":
				var site := _boss_site(subject)
				text = tr("%s has appeared at %s (Lv %d)!") % [name, I18n.t(site["region"]), int(notice["value"])]
				AudioManager.play_sound_at("stinger_boss", Vector3.ZERO, null, true)
			"boss_slain":
				text = tr("%s has fallen!") % name
				AudioManager.play_sound_at("stinger_victory", Vector3.ZERO, null, true)
			"stone_wave":
				var stone: StoneView = _stone_named(subject)
				if stone != null:
					stone.on_wave()
				text = tr("%s: a wave of creatures answers its call! (Wave %d/%d)") % [name, int(notice["value"]), int(notice["of"])]
				band = "stone"
			"stone_shattered":
				var actor := String(notice.get("actor", ""))
				var by := actor if actor != "" else tr("A brave Wizard")
				text = tr("The %s has been shattered by %s! Riches shower the realm!") % [name, by]
				band = "stone"
		if text != "":
			hud.show_notice(text, band)

## Where world boss `boss_name` rises: {region, level} from its pack
## (spawn_tables.json packs with world_boss, boss_overrides for the name,
## regions for the place's name).
func _boss_site(boss_name: String) -> Dictionary:
	if _boss_sites.is_empty():
		var tables: Variant = RealmContent.table("spawn_tables")
		if tables is Dictionary:
			var regions := {}
			for region: Dictionary in (tables as Dictionary).get("regions", []):
				regions[String(region.get("id", ""))] = String(region.get("display", region.get("id", "")))
			var bosses: Dictionary = (tables as Dictionary).get("boss_overrides", {})
			for pack: Dictionary in (tables as Dictionary).get("packs", []):
				if not bool(pack.get("world_boss", false)):
					continue
				var boss: Dictionary = bosses.get(String(pack.get("boss_key", "")), {})
				var zone := String(pack.get("zone", ""))
				_boss_sites[String(boss.get("name", ""))] = {"region": String(regions.get(zone, zone)),
					"level": int(pack.get("level", 1))}
	return _boss_sites.get(boss_name, {"region": "the wilds", "level": 1})

## The Dark Shard called `stone_name` nearest the player (the notice comes
## from one in view).
func _stone_named(stone_name: String) -> StoneView:
	var me: Vector3 = drawn.get(session.own_entity(), Vector3.ZERO)
	var best: StoneView = null
	var best_distance := INF
	for beast: Node3D in beasts.values():
		if beast is StoneView and (beast as StoneView).stone_name == stone_name:
			var distance := me.distance_to(beast.global_position)
			if distance < best_distance:
				best_distance = distance
				best = beast as StoneView
	return best

## A jolt of the camera that settles back (a Dark Shard landing close by).
func shake_camera(strength: float) -> void:
	if _shaking != null and _shaking.is_running():
		return
	camera.h_offset = randf_range(-strength, strength) * SHAKE_SWING
	camera.v_offset = randf_range(-strength, strength) * SHAKE_SWING
	_shaking = create_tween()
	_shaking.tween_property(camera, "h_offset", 0.0, SHAKE_SETTLE)
	_shaking.parallel().tween_property(camera, "v_offset", 0.0, SHAKE_SETTLE)

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
		if check_target_species != "":
			# `--check-target`: the nearest of that species when one is in view
			var kinds: PackedInt32Array = others.get("kinds", PackedInt32Array())
			var ids: PackedInt32Array = others.get("ids", PackedInt32Array())
			var wanted := near.filter(func(id): return CreatureView.species_for_kind(kinds[ids.find(id)]) == check_target_species)
			if not wanted.is_empty():
				near = wanted
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

## Whether the check's Shockwave landed on a creature that can be thrown: the
## server never throws a boss, a Dark Shard, a dummy or a species with full
## displace_resist (mobs.json), so a blast on Grak or a stone alone shows none.
func _check_hit_throwable() -> bool:
	var mobs: Variant = RealmContent.table("mobs")
	for id in check_thrown_at:
		var kind := int(check_thrown_at[id])
		var species := CreatureView.species_for_kind(kind)
		if kind & CreatureView.BOSS_BIT != 0 or CreatureView.view_of(species).has("object"):
			continue
		var entry: Dictionary = (mobs as Dictionary).get("mobs", {}).get(species, {}) if mobs is Dictionary else {}
		if float(entry.get("displace_resist", 0.0)) < 1.0:
			return true
	return false

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
	var hps: PackedInt32Array = others["hp"]
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
			# a body that turned boss (or stopped being one) changes body
			if beasts.has(ids[i]) and bool(beasts[ids[i]].is_boss) != (kinds[i] & CreatureView.BOSS_BIT != 0):
				beasts[ids[i]].queue_free()
				beasts.erase(ids[i])
			if not beasts.has(ids[i]):
				var beast := _new_beast(ids[i], kinds[i])
				if beast != null:
					beasts[ids[i]] = beast
				else:
					no_model[species_kind] = true
			if beasts.has(ids[i]):
				var beast: Node3D = beasts[ids[i]]
				beast.set_kind(kinds[i])
				beast.set_status(statuses[i])
				beast.drive(positions[i], yaws[i], states[i], delta)
				if beast is StoneView:
					(beast as StoneView).set_health(hps[i])
					check_stones[ids[i]] = true
				elif beast is DummyView:
					(beast as DummyView).set_health(hps[i])
					check_dummies[ids[i]] = true
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
	_take_creature_info()
	_follow_target()
	if check_seconds > 0.0:
		_check_fight(delta)
		_check_statuses(ids, kinds, statuses)
	_show_combat()
	_show_notices()

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
			" | statuses: target %s (%d), hit creatures %s (%d), shockwave on a throwable %s" % [_status_names(check_target_statuses),
				check_target_statuses, _status_names(_check_hit_statuses()), _check_hit_statuses(), _check_hit_throwable()],
			" | creatures: %d telegraphs (%d released, %d called off), %d boulders, %d bolts, %d evades, own statuses %s" % [
				combat.telegraphs_seen, combat.telegraphs_released, combat.telegraphs_cancelled, combat.boulders_thrown,
				combat.creature_bolts, combat.evades_shown, _status_names(check_own_statuses)],
			" | world: target %s, %d creature infos, bosses [%s], notices [%s], %d stones, %d dummies in view, last notice \"%s\"" % [
				hud.target_name.text if target != 0 else "-", check_infos, ", ".join(check_bosses.values()),
				", ".join(check_notices.keys().map(func(k): return "%s x%d" % [k, check_notices[k]])),
				check_stones.size(), check_dummies.size(), hud.notices.last_text])
		var passed := int(stats.get("corrections", 0)) == 0 and int(stats.get("snapshots", 0)) > 0 and check_hits > 0 \
			and check_bursts > 0 and (_check_hit_statuses() & StatusFX.STATUS_KNOCKED != 0 or not _check_hit_throwable())
		get_tree().quit(0 if passed else 1)
