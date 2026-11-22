extends Node3D
class_name LevelUpFX

## The level-up moment, about three seconds, seen from the play camera:
##   0.00  the ground under the hero flares (a warm pool), a shockwave of light
##         and dust races out over the ground with light skidding out in it;
##         a column of gold light shoots up round the hero into the sky,
##         sparks are thrown up out of it and fall back as glitter, a flash
##         and a band of light sweep up the body from the feet to the crown;
##   0.08  three comets of light leave the ground and wind up round the body,
##         shedding glitter, and meet over the head;
##   0.7   where they meet the crown bursts: a flash and a spray of gold
##         sparkle over the head;
##   1.5+  the column draws in and lifts off into the sky, its foot burning
##         away first; the pool, the glitter and the body's light fade;
##   3.3   all freed.
## Plus the big "LEVEL N" banner on screen.
##
## Built from the game's rendered VFX material only (the erosion cloud, the
## burst_gold clip, the soft glow, GPU embers), never drawn shapes: the
## column, the comets and the ground light are shaders on one cylinder, one
## strip mesh and one projected box; the motes and sparks run on the GPU.
## One `age` drives the shaders, so _process only sets a few values. No
## shadow casters; one shadowless warm light. Bloom is off on the low preset,
## so every glow is painted in its shader.
##
## Presentation only - the server already applied the level. One call from
## the feedback layer (`LevelUpFX.play(player, level, overlay)`) does all of
## it; the chime is the feedback layer's (AudioManager.play_levelup).

const COLUMN_SHADER := "res://assets/shaders/level_up_column.gdshader"
const GROUND_SHADER := "res://assets/shaders/level_up_ground.gdshader"
const HELIX_SHADER := "res://assets/shaders/level_up_helix.gdshader"
const BODY_SHADER := "res://assets/shaders/level_up_body.gdshader"
const MOTES_SHADER := "res://assets/shaders/level_up_motes.gdshader"
const EMBER_PROCESS := "res://assets/shaders/ember_particles.gdshader"
const SPARK_DRAW := "res://assets/shaders/ember_spark.gdshader"
const LAYER_ADD := "res://assets/shaders/spell_layer_add.gdshader"
const NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const CROWN := "res://assets/vfx/atlases/burst_gold_8x8_1k.png"
const GLOW := "res://assets/vfx/tex/soft_glow_512.png"
const FLARE := "res://assets/vfx/tex/star_flare_256.png"
const GOLD := Color(1.0, 0.74, 0.32)
const HOT := Color(1.0, 0.95, 0.8)
const LENGTH := 3.3
const COLUMN_HEIGHT := 9.0
const SHOCK_REACH := 4.6
const GROUND_HALF_HEIGHT := 0.8
## The comets' helix, shared by their strip (level_up_helix.gdshader) and the
## glitter they shed (level_up_motes.gdshader mode 0).
const HELIX := {"launch": 0.08, "stagger": 0.06, "climb": 1.25, "tail": 0.5, "turns": 1.6,
	"top": 2.35, "foot_radius": 0.78, "crown_radius": 0.22}
const HELIX_SEGMENTS := 64
## The crown bursts as the comets reach it (a head reaches the top a little
## under half way through its climb; the tail then follows it out).
const CROWN_AT := 0.08 + 0.06 + 1.25 * 0.47
const CROWN_FPS := 30.0
const CROWN_FIRST_FRAME := 16.0
const CROWN_HEIGHT := 2.4
const BODY_LIT := 1.6

var target: Node3D
var quality := "high"
var _age := 0.0
## Warm-up copy (ShaderWarmup): held mid-moment, never freed by itself.
var _hold := false
var _column: ShaderMaterial
var _ground: ShaderMaterial
var _helix: ShaderMaterial
var _shed: GPUParticles3D
var _shed_process: ShaderMaterial
var _body: ShaderMaterial
var _crown: MeshInstance3D
var _crown_material: ShaderMaterial
var _crown_sparks: GPUParticles3D
var _flash_node: MeshInstance3D
var _flash: ShaderMaterial
var _light: OmniLight3D
## The body pieces wearing the light (their overlay was empty and is ours).
var _lit: Array[GeometryInstance3D] = []

## The shaders, meshes, ramps and textures, kept for the session: a level-up
## every few minutes would otherwise read them again and, freed with their
## last user, compile their pipelines again in the middle of play.
static var _kept: Dictionary = {}

## Spawn the whole moment. `overlay` is a full-rect Control for the banner;
## either half is skipped when its anchor is missing.
static func play(player: Node3D, level: int, overlay: Control = null) -> Node3D:
	if overlay != null and is_instance_valid(overlay):
		_banner(overlay, level)
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return null
	# several levels from one reward arrive in one frame: one moment is enough
	for child in player.get_parent().get_children():
		if child is LevelUpFX and (child as LevelUpFX).target == player and (child as LevelUpFX)._age < 0.5:
			return child
	var fx := LevelUpFX.new()
	fx.name = "LevelUpFX"
	fx.target = player
	fx.quality = SkillFX.quality
	player.get_parent().add_child(fx)
	fx.global_position = player.global_position
	fx._build()
	return fx

## The moment held mid-way, every layer showing, on `body` under `parent`
## (ShaderWarmup: its pipelines compile behind the loading screen). Freed
## with its parent.
static func warm(parent: Node3D, body: Node3D) -> Node3D:
	if parent == null or not is_instance_valid(parent) or body == null or not is_instance_valid(body):
		return null
	var fx := LevelUpFX.new()
	fx.name = "LevelUpFXWarm"
	fx.target = body
	fx._hold = true
	fx._age = 0.4
	parent.add_child(fx)
	fx.global_position = body.global_position
	fx._build()
	fx._tick()
	return fx

static func _res(path: String) -> Resource:
	var res: Resource = _kept.get(path)
	if res == null:
		res = load(path)
		_kept[path] = res
	return res

func _build() -> void:
	var more := 1.0 if quality == "low" else (1.25 if quality == "medium" else 1.5)
	_add_ground()
	_add_column()
	_add_helix()
	_add_shed(int(96 * more))
	_add_skid(int(30 * more))
	_add_sparks(int(34 * more))
	_add_crown_sparks(int(40 * more))
	_add_crown()
	_add_flash()
	_light_body()
	if not _hold:
		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.8, 0.5)
		_light.omni_range = 5.5
		_light.omni_attenuation = 1.4
		_light.light_energy = 0.0
		_light.light_specular = 0.3
		_light.shadow_enabled = false
		_light.position = Vector3(0, 1.1, 0)
		add_child(_light)

# ------------------------------------------------------------------- layers

func _add_column() -> void:
	var mesh: CylinderMesh = _kept.get("column_mesh")
	if mesh == null:
		mesh = CylinderMesh.new()
		mesh.top_radius = 1.0
		mesh.bottom_radius = 1.0
		mesh.height = 1.0
		mesh.radial_segments = 28
		mesh.rings = 12
		mesh.cap_top = false
		mesh.cap_bottom = false
		_kept["column_mesh"] = mesh
	_column = ShaderMaterial.new()
	_column.shader = _res(COLUMN_SHADER)
	_column.set_shader_parameter("noise", _res(NOISE))
	_column.set_shader_parameter("tint", GOLD)
	_column.set_shader_parameter("hot", HOT)
	_column.set_shader_parameter("height", COLUMN_HEIGHT)
	var node := MeshInstance3D.new()
	node.name = "Column"
	node.mesh = mesh
	node.material_override = _column
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the shader shapes the unit cylinder: cull by what it can become
	node.custom_aabb = AABB(Vector3(-3.0, -0.5, -3.0), Vector3(6.0, COLUMN_HEIGHT + 1.0, 6.0))
	add_child(node)

func _add_ground() -> void:
	var box := BoxMesh.new()
	var span := (SHOCK_REACH + 0.8) * 2.0
	box.size = Vector3(span, GROUND_HALF_HEIGHT * 2.0, span)
	_ground = ShaderMaterial.new()
	_ground.shader = _res(GROUND_SHADER)
	_ground.set_shader_parameter("noise", _res(NOISE))
	_ground.set_shader_parameter("tint", GOLD)
	_ground.set_shader_parameter("hot", HOT)
	_ground.set_shader_parameter("reach", SHOCK_REACH)
	_ground.set_shader_parameter("half_height", GROUND_HALF_HEIGHT)
	var node := MeshInstance3D.new()
	node.name = "Ground"
	node.mesh = box
	node.material_override = _ground
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)

## The three comets winding up round the body: one strip mesh; the helix and
## the turn toward the camera are the shader's.
func _add_helix() -> void:
	_helix = ShaderMaterial.new()
	_helix.shader = _res(HELIX_SHADER)
	_helix.set_shader_parameter("noise", _res(NOISE))
	_helix.set_shader_parameter("tint", GOLD)
	_helix.set_shader_parameter("hot", HOT)
	for key: String in HELIX:
		_helix.set_shader_parameter(key, HELIX[key])
	var node := MeshInstance3D.new()
	node.name = "Comets"
	node.mesh = _helix_mesh()
	node.material_override = _helix
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-1.5, -0.2, -1.5), Vector3(3.0, 3.2, 3.0))
	add_child(node)

## Three strips of HELIX_SEGMENTS quads: UV.x along (0..1), UV.y across,
## UV2.x the strand. The positions are placeholders; the shader places them.
static func _helix_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = _kept.get("helix_mesh")
	if mesh != null:
		return mesh
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var index := PackedInt32Array()
	for strand in 3:
		var base := verts.size()
		for i in HELIX_SEGMENTS + 1:
			var u := float(i) / HELIX_SEGMENTS
			for side in 2:
				verts.append(Vector3(0.0, u * 2.0, 0.0))
				uvs.append(Vector2(u, float(side)))
				uv2s.append(Vector2(float(strand), 0.0))
		for i in HELIX_SEGMENTS:
			var a := base + i * 2
			index.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = index
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_kept["helix_mesh"] = mesh
	return mesh

## Glitter shed by the comets (level_up_motes.gdshader mode 0, the same
## helix); it starts with them.
func _add_shed(amount: int) -> void:
	_shed = _particles("Glitter", amount, 0.95, true)
	_shed.explosiveness = 0.0
	_shed_process = ShaderMaterial.new()
	_shed_process.shader = _res(MOTES_SHADER)
	_shed_process.set_shader_parameter("mode", 0)
	for key: String in HELIX:
		_shed_process.set_shader_parameter(key, HELIX[key])
	_shed_process.set_shader_parameter("size_min", 0.009)
	_shed_process.set_shader_parameter("size_max", 0.024)
	_shed_process.set_shader_parameter("stretch", 0.03)
	_shed_process.set_shader_parameter("energy", 0.9)
	_shed_process.set_shader_parameter("ramp", _ramp())
	_shed.process_material = _shed_process
	_shed.emitting = false

## Light skidding out over the ground with the shockwave (mode 1).
func _add_skid(amount: int) -> void:
	var particles := _particles("Skid", amount, 1.1, false)
	particles.explosiveness = 1.0
	var process := ShaderMaterial.new()
	process.shader = _res(MOTES_SHADER)
	process.set_shader_parameter("mode", 1)
	process.set_shader_parameter("radius", 0.5)
	process.set_shader_parameter("speed_min", 3.5)
	process.set_shader_parameter("speed_max", 8.0)
	process.set_shader_parameter("size_min", 0.01)
	process.set_shader_parameter("size_max", 0.022)
	process.set_shader_parameter("stretch", 0.02)
	process.set_shader_parameter("energy", 0.8)
	process.set_shader_parameter("ramp", _ramp())
	particles.process_material = process
	particles.emitting = true

## Sparks thrown up out of the column that fall back as gold glitter
## (the spells' ember process).
func _add_sparks(amount: int) -> void:
	var particles := _particles("Sparks", amount, 2.2, false)
	particles.explosiveness = 0.9
	particles.position = Vector3(0, 0.3, 0)
	particles.process_material = _ember_process(24.0, Vector2(4.5, 10.0), 4.0, 1.6, 0.35)
	particles.emitting = true

## The crown's spray: sparks flung out all round where the comets meet,
## drifting down as glitter. Fired by _tick at CROWN_AT.
func _add_crown_sparks(amount: int) -> void:
	_crown_sparks = _particles("CrownSparks", amount, 1.6, false)
	_crown_sparks.explosiveness = 1.0
	_crown_sparks.position = Vector3(0, CROWN_HEIGHT, 0)
	_crown_sparks.process_material = _ember_process(110.0, Vector2(1.6, 4.6), 2.2, 2.4, 0.12)
	_crown_sparks.emitting = false

func _ember_process(spread: float, speed: Vector2, gravity: float, drag: float, radius: float) -> ShaderMaterial:
	var process := ShaderMaterial.new()
	process.shader = _res(EMBER_PROCESS)
	process.set_shader_parameter("dir", Vector3.UP)
	process.set_shader_parameter("spread_deg", spread)
	process.set_shader_parameter("speed_min", speed.x)
	process.set_shader_parameter("speed_max", speed.y)
	process.set_shader_parameter("gravity", gravity)
	process.set_shader_parameter("drag", drag)
	process.set_shader_parameter("turbulence", 2.0)
	process.set_shader_parameter("turb_freq", 4.0)
	process.set_shader_parameter("size_min", 0.01)
	process.set_shader_parameter("size_max", 0.026)
	process.set_shader_parameter("stretch", 0.03)
	process.set_shader_parameter("emit_radius", radius)
	process.set_shader_parameter("energy", 1.0)
	process.set_shader_parameter("floor_y", global_position.y if is_inside_tree() else -100000.0)
	process.set_shader_parameter("ramp", _ramp())
	return process

func _particles(node_name: String, amount: int, lifetime: float, local: bool) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = maxi(1, amount)
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.randomness = 0.0
	particles.fixed_fps = 0
	particles.local_coords = local
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-7, -2, -7), Vector3(14, 12, 14))
	var quad: QuadMesh = _kept.get("spark_quad")
	if quad == null:
		quad = QuadMesh.new()
		var draw := ShaderMaterial.new()
		draw.shader = _res(SPARK_DRAW)
		quad.material = draw
		_kept["spark_quad"] = quad
	particles.draw_pass_1 = quad
	add_child(particles)
	return particles

## White-hot -> pale gold -> gold -> a dim amber, fading out.
static func _ramp() -> GradientTexture1D:
	var ramp: GradientTexture1D = _kept.get("ramp")
	if ramp != null:
		return ramp
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.1, 0.4, 0.8, 1.0])
	gradient.colors = PackedColorArray([Color(1.0, 0.93, 0.74, 1.0), Color(1.0, 0.84, 0.5, 1.0),
		Color(1.0, 0.72, 0.3, 0.95), Color(0.85, 0.48, 0.16, 0.7), Color(0.55, 0.26, 0.08, 0.0)])
	ramp = GradientTexture1D.new()
	ramp.gradient = gradient
	ramp.width = 64
	_kept["ramp"] = ramp
	return ramp

## A camera-facing flipbook/glow card (spell_layer_add.gdshader).
func _card(node_name: String, texture_path: String, grid: Vector2, size: float, height: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var material := ShaderMaterial.new()
	material.shader = _res(LAYER_ADD)
	material.set_shader_parameter("atlas", _res(texture_path))
	material.set_shader_parameter("grid", grid)
	material.set_shader_parameter("frame", 0.0)
	material.set_shader_parameter("billboard", true)
	material.set_shader_parameter("tint", Color.WHITE)
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("soft_fade", 0.3)
	quad.material = material
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = Vector3(0, height, 0)
	node.scale = Vector3.ONE * size
	add_child(node)
	return node

## The spray of gold sparkle over the head where the comets meet.
func _add_crown() -> void:
	_crown = _card("Crown", CROWN, Vector2(8, 8), 2.0, CROWN_HEIGHT)
	_crown_material = (_crown.mesh as QuadMesh).material as ShaderMaterial
	_crown_material.set_shader_parameter("tint", Color(1.0, 0.88, 0.62))
	_crown.visible = false

## The flashes: round the body as it erupts, then over the head as the crown
## bursts (one card, moved).
func _add_flash() -> void:
	_flash_node = _card("Flash", GLOW, Vector2.ONE, 2.8, 1.0)
	_flash = (_flash_node.mesh as QuadMesh).material as ShaderMaterial
	_flash.set_shader_parameter("tint", Color(1.0, 0.7, 0.35))

## The light sweeping up the body: an overlay on the hero's own pieces whose
## overlay slot is free (a status look or a rising spirit keeps its own).
func _light_body() -> void:
	if target == null or not is_instance_valid(target):
		return
	_body = ShaderMaterial.new()
	_body.shader = _res(BODY_SHADER)
	_body.set_shader_parameter("noise", _res(NOISE))
	_body.set_shader_parameter("tint", GOLD)
	_body.set_shader_parameter("hot", HOT)
	_body.set_shader_parameter("gone_at", BODY_LIT)
	var root: Variant = target.get("visuals")
	var holder: Node = root if root is Node3D else target
	for node: Node in holder.find_children("*", "GeometryInstance3D", true, false):
		var piece := node as GeometryInstance3D
		var piece_name := String(piece.name)
		# the skin and clothes; not the hair cards, lashes and eyes (their
		# cards would light up as quads)
		if not (piece is MeshInstance3D) or not piece.is_visible_in_tree():
			continue
		if not (piece_name.begins_with("Hero_") or piece_name == "Face_Head"):
			continue
		if piece.material_overlay != null:
			continue
		piece.material_overlay = _body
		_lit.append(piece)
		if _lit.size() >= 16:
			break

func _unlight_body() -> void:
	for piece in _lit:
		if is_instance_valid(piece) and piece.material_overlay == _body:
			piece.material_overlay = null
	_lit.clear()

# ------------------------------------------------------------------- timing

func _process(delta: float) -> void:
	if not _hold:
		_age += delta
	if target != null and is_instance_valid(target) and target.is_inside_tree():
		global_position = target.global_position
	_tick()
	if _age >= BODY_LIT and not _lit.is_empty():
		_unlight_body()
	if not _hold and _age >= LENGTH:
		queue_free()

func _tick() -> void:
	_column.set_shader_parameter("age", _age)
	_ground.set_shader_parameter("age", _age)
	_helix.set_shader_parameter("age", _age)
	_shed_process.set_shader_parameter("age", _age)
	if not _shed.emitting and _age >= float(HELIX["launch"]) and _age < 0.5:
		_shed.emitting = true
	if _body != null:
		_body.set_shader_parameter("age", _age)
		_body.set_shader_parameter("feet", global_position)
	var t := _age - CROWN_AT
	_crown.visible = t >= 0.0
	if t >= 0.0 and not _crown_sparks.emitting and t < 0.2:
		_crown_sparks.emitting = true
	if t >= 0.0:
		var frame := minf(CROWN_FIRST_FRAME + t * CROWN_FPS, 63.0)
		_crown_material.set_shader_parameter("frame", frame)
		_crown_material.set_shader_parameter("opacity",
			clampf(t / 0.1, 0.0, 1.0) * clampf((60.0 - frame) / 20.0, 0.0, 1.0) * 0.7)
	# a flash round the body as it erupts, a smaller one at the crown
	var first := clampf(_age / 0.04, 0.0, 1.0) * clampf(1.0 - (_age - 0.04) / 0.3, 0.0, 1.0) * 0.45
	var second := clampf(t / 0.04, 0.0, 1.0) * clampf(1.0 - (t - 0.04) / 0.35, 0.0, 1.0) * 0.5
	if t >= 0.0:
		_flash_node.position.y = CROWN_HEIGHT
		_flash_node.scale = Vector3.ONE * 1.9
	_flash.set_shader_parameter("opacity", second if t >= 0.0 else first)
	if _light != null:
		var swell := clampf(_age / 0.08, 0.0, 1.0)
		var fall := clampf(1.0 - (_age - 0.15) / 1.9, 0.0, 1.0)
		_light.light_energy = 1.7 * swell * fall * fall

func _exit_tree() -> void:
	_unlight_body()

# ------------------------------------------------------------------- banner

## The on-screen moment: a gold flash and a big "LEVEL N" that punches in,
## holds and fades. A second level in the same frame updates the live banner.
static func _banner(overlay: Control, level: int) -> void:
	var live := overlay.get_node_or_null("LevelUpBanner")
	if live != null:
		var title := live.get_node_or_null("Box/Title") as Label
		if title != null:
			title.text = I18n.upper(I18n.t("Level %d") % level)
		return
	var root := Control.new()
	root.name = "LevelUpBanner"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(root)

	var flash := ColorRect.new()
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# the screen flash follows the player's Screen flash setting (0 = none)
	flash.color = Color(1.0, 0.8, 0.35, 0.16 * GameSettings.flash_value())
	var flash_material := CanvasItemMaterial.new()
	flash_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	flash.material = flash_material
	root.add_child(flash)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	box.anchor_left = 0.0
	box.anchor_right = 1.0
	box.anchor_top = 0.2
	box.anchor_bottom = 0.2
	box.offset_top = -10
	box.offset_bottom = 110
	root.add_child(box)

	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = load(FLARE)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.modulate = Color(1.0, 0.8, 0.4, 0.55)
	var glow_material := CanvasItemMaterial.new()
	glow_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = glow_material
	glow.anchor_left = 0.5
	glow.anchor_right = 0.5
	glow.anchor_top = 0.2
	glow.anchor_bottom = 0.2
	glow.offset_left = -260
	glow.offset_right = 260
	glow.offset_top = -110
	glow.offset_bottom = 160
	glow.pivot_offset = Vector2(260, 135)
	root.add_child(glow)
	root.move_child(glow, 1)

	var kicker := Label.new()
	kicker.text = I18n.upper(I18n.t("Level up"))
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kicker.add_theme_font_override("font", UITheme.font_title())
	kicker.add_theme_font_size_override("font_size", UITheme.FS_HEADER)
	kicker.add_theme_color_override("font_color", Color(1.0, 0.93, 0.75))
	kicker.add_theme_color_override("font_outline_color", Color(0.18, 0.1, 0.02, 0.9))
	kicker.add_theme_constant_override("outline_size", 6)
	box.add_child(kicker)

	var title := Label.new()
	title.name = "Title"
	title.text = I18n.upper(I18n.t("Level %d") % level)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", UITheme.font_title())
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.42))
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.12, 0.0, 0.95))
	title.add_theme_constant_override("outline_size", 12)
	title.add_theme_color_override("font_shadow_color", Color(1.0, 0.7, 0.2, 0.55))
	title.add_theme_constant_override("shadow_offset_x", 0)
	title.add_theme_constant_override("shadow_offset_y", 0)
	title.add_theme_constant_override("shadow_outline_size", 28)
	box.add_child(title)

	root.modulate.a = 0.0
	box.pivot_offset = Vector2(overlay.size.x * 0.5, 60)
	box.scale = Vector2(1.5, 1.5)
	var tween := root.create_tween()
	tween.set_parallel(true)
	tween.tween_property(root, "modulate:a", 1.0, 0.18)
	tween.tween_property(box, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(flash, "color:a", 0.0, 0.6).set_delay(0.08)
	tween.tween_property(glow, "rotation", 0.6, 2.6)
	tween.set_parallel(false)
	tween.tween_interval(1.9)
	tween.tween_property(root, "modulate:a", 0.0, 0.6)
	tween.tween_callback(root.queue_free)
