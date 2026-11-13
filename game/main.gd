extends Node3D

## The realm client's first view. Everything that happens comes from the
## RealmSession extension node (Rust): this script reads the controls, hands
## them over, and draws what the session reports. The look is programmer art
## (grey map geometry, capsules) until the real scenes stream in.
##
##   godot --path game -- [--server 127.0.0.1:7777] [--map grounds]
##   godot --headless --path game -- --check 20     joins, walks, prints, quits
##
## Paths to keys/, content/data and world/maps default to the realm checkout
## the project sits in.

const KIND_COLORS := [Color(0.35, 0.65, 1.0), Color(0.85, 0.3, 0.25), Color(0.9, 0.6, 0.2),
	Color(0.55, 0.8, 0.3), Color(0.7, 0.4, 0.85), Color(0.9, 0.85, 0.3)]

var session: Node
var player: MeshInstance3D
var crowd: MultiMeshInstance3D
var camera: Camera3D
var hud: Label
var cam_yaw := 0.0
var cam_pitch := -0.35
var cam_distance := 9.0
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
	if not ClassDB.class_exists("RealmSession"):
		printerr("realm: the realm_client extension did not load (cargo build --release -p realm_client)")
		get_tree().quit(2)
		return
	session = ClassDB.instantiate("RealmSession")
	add_child(session)
	var ok: bool = session.start_dev(_arg("--server", "127.0.0.1:7777"), _arg("--keys", root.path_join("keys")),
		_arg("--content", root.path_join("content/data")), _arg("--maps", root.path_join("world/maps")),
		_arg("--map", "grounds"))
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
	player = MeshInstance3D.new()
	player.mesh = _capsule(Color(0.95, 0.95, 0.95))
	add_child(player)
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
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clampf(cam_pitch - event.relative.y * 0.004, -1.3, 0.4)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = maxf(2.0, cam_distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = minf(60.0, cam_distance * 1.1)

func _process(_delta: float) -> void:
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
		jump = int(Time.get_ticks_msec() / 1500) % 4 == 0
	else:
		strafe = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		forward = float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		jump = Input.is_physical_key_pressed(KEY_SPACE)
	session.set_intent(strafe, forward, cam_yaw, jump, Input.is_physical_key_pressed(KEY_CTRL))

	var me: Vector3 = session.own_position()
	player.position = me + Vector3(0, 0.925, 0)
	var look_at_point := me + Vector3(0, 1.5, 0)
	var offset := Vector3(0, 0, cam_distance).rotated(Vector3.RIGHT, cam_pitch).rotated(Vector3.UP, cam_yaw)
	camera.position = look_at_point + offset
	camera.look_at(look_at_point)

	var others: Dictionary = session.remote()
	var positions: PackedVector3Array = others["positions"]
	var kinds: PackedInt32Array = others["kinds"]
	crowd.multimesh.instance_count = positions.size()
	for i in positions.size():
		crowd.multimesh.set_instance_transform(i, Transform3D(Basis(), positions[i] + Vector3(0, 0.925, 0)))
		crowd.multimesh.set_instance_color(i, KIND_COLORS[kinds[i] % KIND_COLORS.size()])

	var stats: Dictionary = session.stats()
	hud.text = "realm  %d fps  tick %d  hp %d  snapshots %d  corrections %d (max %.3f m)\n%s  %d others in view" % [
		Engine.get_frames_per_second(), stats.get("tick", 0), stats.get("hp", 0), stats.get("snapshots", 0),
		stats.get("corrections", 0), stats.get("max_correction", 0.0), str(me.snapped(Vector3(0.1, 0.1, 0.1))),
		positions.size()]

	if check_seconds > 0.0 and Time.get_ticks_msec() / 1000.0 - check_started > check_seconds:
		print("realm check: ", hud.text.replace("\n", " | "))
		get_tree().quit(0 if int(stats.get("corrections", 0)) == 0 and int(stats.get("snapshots", 0)) > 0 else 1)
