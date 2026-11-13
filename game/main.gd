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
## Paths to keys/, content/data and world/maps default to the realm checkout
## the project sits in.

const KIND_COLORS := [Color(0.35, 0.65, 1.0), Color(0.85, 0.3, 0.25), Color(0.9, 0.6, 0.2),
	Color(0.55, 0.8, 0.3), Color(0.7, 0.4, 0.85), Color(0.9, 0.85, 0.3)]

const HeroViewScript := "res://scripts/view/hero_view.gd"
const PlayerSheetScript := "res://scripts/view/player_sheet.gd"
const NoticeScript := "res://scripts/view/notice_band.gd"
const InventoryScript := "res://scripts/ui/inventory_arcane.gd"
## Entity kind of a player in snapshots (creatures carry their kind id + 1).
const KIND_PLAYER := 0

var session: Node
var player: Node3D
## Other players' heroes by entity id.
var heroes := {}
## The player's sheet for the windows, and the windows.
var sheet_view: Node
var inventory: Control
## Creatures with a model by entity id (CreatureView); species without one yet
## are drawn as capsules.
var beasts := {}
## Kinds whose species has no model in this client yet.
var no_model := {}
const CreatureViewScript := "res://scripts/view/creature_view.gd"
var house_color := Color(0.85, 0.4, 0.11)
var crowd: MultiMeshInstance3D
var camera: Camera3D
var hud: Label
var cam_yaw := 0.0
var cam_pitch := -0.35
var cam_distance := 9.0
## Extra camera turn around the player that does not steer (screenshots).
var cam_side := 0.0
var check_seconds := 0.0
var check_started := 0.0
var built := false

func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback

func _ready() -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	check_seconds = float(_arg("--check", "0"))
	cam_distance = float(_arg("--cam-distance", str(cam_distance)))
	cam_side = deg_to_rad(float(_arg("--cam-side", "0")))
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
	hud = Label.new()
	hud.position = Vector2(12, 10)
	var layer := CanvasLayer.new()
	layer.add_child(hud)
	add_child(layer)
	_build_ui()

## The windows: a full-screen root holding the notice band ("HUD", which the
## windows look for) and the inventory (I).
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	var root := Control.new()
	root.name = "UI"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var band: Control = load(NoticeScript).new()
	band.name = "HUD"
	root.add_child(band)
	sheet_view = load(PlayerSheetScript).new(session)
	add_child(sheet_view)
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
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_I:
		toggle_inventory()
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clampf(cam_pitch - event.relative.y * 0.004, -1.3, 0.4)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = maxf(2.0, cam_distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = minf(60.0, cam_distance * 1.1)

func _process(delta: float) -> void:
	if session == null:
		return
	var status: String = session.status()
	if status != "joined":
		if hud != null:
			hud.text = "realm: " + status
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
		forward = 1.0
		cam_yaw += 0.004
		jump = int(Time.get_ticks_msec() / 1500) % 4 == 3
	else:
		strafe = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		forward = float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		jump = Input.is_physical_key_pressed(KEY_SPACE)
	session.set_intent(strafe, forward, cam_yaw, jump, Input.is_physical_key_pressed(KEY_CTRL))

	var own: Dictionary = session.own_body()
	var me: Vector3 = own.get("position", Vector3.ZERO)
	if not own.is_empty():
		player.drive_own(own, delta)
	var look_at_point := me + Vector3(0, 1.5, 0)
	var offset := Vector3(0, 0, cam_distance).rotated(Vector3.RIGHT, cam_pitch).rotated(Vector3.UP, cam_yaw + cam_side)
	camera.position = look_at_point + offset
	camera.look_at(look_at_point)

	var others: Dictionary = session.remote()
	var ids: PackedInt32Array = others["ids"]
	var positions: PackedVector3Array = others["positions"]
	var kinds: PackedInt32Array = others["kinds"]
	var yaws: PackedFloat32Array = others["yaws"]
	var states: PackedInt32Array = others["states"]
	var seen := {}
	var creatures := 0
	crowd.multimesh.instance_count = positions.size()
	for i in positions.size():
		if kinds[i] == KIND_PLAYER:
			seen[ids[i]] = true
			if not heroes.has(ids[i]):
				heroes[ids[i]] = _new_hero()
			heroes[ids[i]].drive_remote(positions[i], delta)
			continue
		if not no_model.has(kinds[i]):
			seen[ids[i]] = true
			if not beasts.has(ids[i]):
				var beast: Node3D = load(CreatureViewScript).new()
				add_child(beast)
				if beast.setup(kinds[i]):
					beasts[ids[i]] = beast
				else:
					beast.queue_free()
					no_model[kinds[i]] = true
			if beasts.has(ids[i]):
				beasts[ids[i]].drive(positions[i], yaws[i], states[i], delta)
				continue
		crowd.multimesh.set_instance_transform(creatures, Transform3D(Basis(), positions[i] + Vector3(0, 0.925, 0)))
		crowd.multimesh.set_instance_color(creatures, KIND_COLORS[kinds[i] % KIND_COLORS.size()])
		creatures += 1
	crowd.multimesh.visible_instance_count = creatures
	for table: Dictionary in [heroes, beasts]:
		for id in table.keys():
			if not seen.has(id):
				table[id].queue_free()
				table.erase(id)

	var stats: Dictionary = session.stats()
	hud.text = "realm  %d fps  tick %d  hp %d  snapshots %d  corrections %d (max %.3f m)  server moves %d\n%s  %d others in view" % [
		Engine.get_frames_per_second(), stats.get("tick", 0), stats.get("hp", 0), stats.get("snapshots", 0),
		stats.get("corrections", 0), stats.get("max_correction", 0.0), stats.get("server_moves", 0),
		str(me.snapped(Vector3(0.1, 0.1, 0.1))),
		positions.size()]
	if player.anim != null:
		hud.text += "  pose %s" % player.anim.current_clip
	var sheet: Dictionary = session.sheet()
	if not sheet.is_empty():
		var bag: Array = sheet["bag"]
		var items := bag.filter(func(c): return c != null).map(
			func(c): return "%s x%d" % [c["id"], c["amount"]])
		hud.text += "\n%s (%s)  level %d  hp %d/%d  mana %d/%d  %d oril  wields %s\nbag: %s" % [
			sheet["name"], sheet["house"], sheet["level"], sheet["hp"], sheet["max_hp"], sheet["mana"],
			sheet["max_mana"], sheet["oril"], (sheet["equipment"] as Dictionary).get("main_hand", {}).get("id", "-"),
			", ".join(items)]
		_apply_sheet_look(sheet)

	if check_seconds > 0.0 and Time.get_ticks_msec() / 1000.0 - check_started > check_seconds:
		print("realm check: ", hud.text.replace("\n", " | "))
		get_tree().quit(0 if int(stats.get("corrections", 0)) == 0 and int(stats.get("snapshots", 0)) > 0 else 1)
