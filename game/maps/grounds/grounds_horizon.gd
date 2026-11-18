extends MeshInstance3D

## Distant mountains beyond the 2 km map, so a rider high on a broom sees ranges
## fading into haze instead of the edge of the world. Visual only.
##
## The mesh: a polar grid of rows from just inside the map edge (below the
## terrain's own mountain ring, ~120-150 m there) out to ~3.5 km, pushed out
## at the corners to follow the square map. Heights are ridged noise under a
## distance envelope (the ranges rise behind the terrain ring and fall away
## far out), with smooth normals and a per-vertex cavity term (gullies dark,
## crests light) so the light reads the relief.
##
## The material (assets/shaders/horizon_mountains.gdshader): grass, rock and
## snow split by slope and height and broken by noise, the terrain's own rock
## and meadow textures, lit by the sun / moon and the sky ambient like the
## rest of the world, then hazed into the sky's horizon colour by their true
## distance (aerial perspective). The camera's far plane is short on the low
## preset (1600 m), so the vertex stage pulls anything near or past it towards
## the camera along its own sight line (depth order kept): the full ranges
## show on every preset instead of being clipped into cut-outs.
##
## Each quarter second the node copies the hour's fog colour and density, the
## sky's horizon colour, the camera's far plane and the preset's light path
## into the material (DayNight and QualityPreset own those).

const SHADER := preload("res://assets/shaders/horizon_mountains.gdshader")
## The low preset's light path as its own shader: half the texture reads to
## compile (Metal's compile time grows with them), the same picture.
const SHADER_LITE := preload("res://assets/shaders/horizon_mountains_lite.gdshader")
const ROCK := preload("res://assets/terrain/textures/cliff_rock_alb_ht.png")
const MEADOW := preload("res://assets/terrain/textures/grass_meadow_alb_ht.png")
const NOISE := preload("res://assets/vfx/tex/noise_erosion_512.png")

## Row distances (m, along an axis; pushed out towards the corners) and the
## envelope height at each row: the first rows hide under the terrain's edge.
const ROWS := [990.0, 1030.0, 1075.0, 1125.0, 1180.0, 1240.0, 1305.0, 1375.0, 1450.0,
	1530.0, 1615.0, 1705.0, 1800.0, 1900.0, 2005.0, 2115.0, 2230.0, 2350.0, 2475.0,
	2605.0, 2740.0, 2880.0, 3025.0, 3175.0, 3330.0, 3490.0]
const ENVELOPE := [55.0, 90.0, 135.0, 185.0, 235.0, 285.0, 330.0, 370.0, 400.0,
	425.0, 445.0, 460.0, 475.0, 490.0, 500.0, 510.0, 520.0, 525.0, 525.0,
	515.0, 500.0, 480.0, 450.0, 410.0, 360.0, 300.0]
const SEGMENTS := 512
const UPDATE_PERIOD := 0.25

var _timer := 0.0
var _material: ShaderMaterial


## The mesh is the same every time (~15 ms to make): kept for the next build
## of the grounds (a trip away and back).
static var _cached: ArrayMesh = null


static func _preset_shader() -> Shader:
	return SHADER_LITE if bool(QualityPreset.value("lite_surfaces", false)) else SHADER


static func _bind_textures(m: ShaderMaterial) -> void:
	m.set_shader_parameter("rock_tex", ROCK)
	m.set_shader_parameter("meadow_tex", MEADOW)
	m.set_shader_parameter("noise_tex", NOISE)


static func build(parent: Node3D) -> MeshInstance3D:
	var mi: MeshInstance3D = load("res://maps/grounds/grounds_horizon.gd").new()
	mi.name = "Horizon"
	if _cached == null:
		_cached = _mesh()
	mi.mesh = _cached
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var m := ShaderMaterial.new()
	m.shader = _preset_shader()
	_bind_textures(m)
	mi.material_override = m
	mi._material = m
	parent.add_child(mi)
	mi._refresh()
	return mi


static func _mesh() -> ArrayMesh:
	var ridge := FastNoiseLite.new()
	ridge.seed = 2026
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge.frequency = 1.0 / 1050.0
	ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = 4
	ridge.fractal_lacunarity = 2.0
	ridge.fractal_gain = 0.42
	ridge.domain_warp_enabled = false
	# the massifs and the saddles between them, so the ranges layer
	var macro := FastNoiseLite.new()
	macro.seed = 77
	macro.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	macro.frequency = 1.0 / 2400.0
	macro.fractal_octaves = 2
	var rows := ROWS.size()
	var cols := SEGMENTS + 1
	var pos := PackedVector3Array()
	pos.resize(rows * cols)
	for r in rows:
		var push := lerpf(0.9, 0.3, smoothstep(990.0, 2000.0, float(ROWS[r])))
		for i in cols:
			var a := TAU * i / SEGMENTS
			var c := cos(a)
			var s := sin(a)
			# square-ish: the map is a square, so the rows go out at the corners
			var sq: float = 1.0 / maxf(absf(c), absf(s))
			var radius: float = float(ROWS[r]) * lerpf(1.0, sq, push)
			var x := c * radius
			var z := s * radius
			var ridged := ridge.get_noise_2d(x, z) * 0.5 + 0.5
			var mass := clampf(0.62 + 0.7 * macro.get_noise_2d(x, z), 0.25, 1.15)
			var h: float = float(ENVELOPE[r]) * mass * (0.22 + 0.85 * pow(ridged, 1.4))
			pos[r * cols + i] = Vector3(x, h, z)
	# the seam: the last column is the first one
	for r in rows:
		pos[r * cols + SEGMENTS] = pos[r * cols]
	var normals := PackedVector3Array()
	normals.resize(pos.size())
	var colors := PackedColorArray()
	colors.resize(pos.size())
	for r in rows:
		for i in cols:
			var p := pos[r * cols + i]
			var il := (i - 1 + SEGMENTS) % SEGMENTS
			var ir := (i + 1) % SEGMENTS
			var left := pos[r * cols + il]
			var right := pos[r * cols + ir]
			var inner := pos[maxi(r - 1, 0) * cols + i]
			var outer := pos[mini(r + 1, rows - 1) * cols + i]
			var n := (right - left).cross(inner - outer).normalized()
			if n.y < 0.0:
				n = -n
			normals[r * cols + i] = n
			# cavity: above the neighbours' mean is a crest, below a gully
			var mean := (left.y + right.y + inner.y + outer.y) * 0.25
			var cavity := clampf(0.5 + (p.y - mean) / 70.0, 0.0, 1.0)
			colors[r * cols + i] = Color(cavity, float(r) / float(rows - 1), 0.0)
	var indices := PackedInt32Array()
	indices.resize((rows - 1) * SEGMENTS * 6)
	var k := 0
	for r in rows - 1:
		for i in SEGMENTS:
			var a := r * cols + i
			var b := a + 1
			var c := a + cols
			var d := c + 1
			indices[k] = a
			indices[k + 1] = d
			indices[k + 2] = b
			indices[k + 3] = a
			indices[k + 4] = c
			indices[k + 5] = d
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = UPDATE_PERIOD
	_refresh()


## The hour's haze, the camera's reach and the preset's light path.
func _refresh() -> void:
	if _material == null:
		return
	var map := get_parent()
	var main: Node = map.get("main") if map != null else null
	var env_node := main.get_node_or_null("WorldEnvironment") as WorldEnvironment if main != null else null
	var env := env_node.environment if env_node != null else null
	if env != null:
		var fog := env.fog_light_color
		var horizon := fog
		if env.sky != null and env.sky.sky_material is ShaderMaterial:
			var sky_horizon: Variant = (env.sky.sky_material as ShaderMaterial).get_shader_parameter("horizon_color")
			if sky_horizon is Color:
				horizon = sky_horizon
		_material.set_shader_parameter("haze_color", horizon.lerp(fog, 0.35))
		_material.set_shader_parameter("haze_density", env.fog_density if env.fog_enabled else 0.0004)
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		_material.set_shader_parameter("max_dist", camera.far)
	var shader := _preset_shader()
	if _material.shader != shader:
		_material.shader = shader
		_bind_textures(_material)
