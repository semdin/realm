extends RefCounted

## The purpose-built places of the valley (world overhaul step 2,
## plans/layout-plan.html): the Trial Hall on the castle's east terrace, the
## Hearth Pavilion beside the castle approach, the fenced training yard by the
## broom landing pad, Kestrin's forge's glow and sign (his smithy is a VillageKit
## building on the west side of Orvell square) and the
## cave mouth down to the Blackweb Caverns in Spider Hollow's west slope.
##
## Every place reads its spot from the content (RealmContent), so the building
## and the trigger cannot drift apart: the Trial Hall and the cave mouth are
## grounds portals (maps.json `dressing` "trial_hall" / "cave_mouth", `facing`
## = the compass direction the doorway faces in degrees, 0 = +z south, 90 = +x
## east), the pavilion stands round the hearth hearth_pavilion (travel.json),
## and the training yard round the dummies (the layout's "training"). Drawn
## only: the colliders are the server's map pack.

const PBR := preload("res://maps/grounds/grounds_pbr.gd")
const Layout := preload("res://maps/grounds/grounds_layout.gd")
const ArchKit := preload("res://maps/grounds/arch_kit.gd")
const Mats := preload("res://maps/grounds/grounds_mats.gd")
const Sites := preload("res://maps/grounds/grounds_sites.gd")
const MAP := "grounds"

## The training yard's fence (x, z extents round its centre) and its gate on
## the west side, facing the landing pad.
const YARD_HALF := Vector2(11.0, 7.0)
const YARD_GATE := 4.0


static func build(world: Node3D) -> Node3D:
	var root := Node3D.new()
	root.name = "Precinct"
	world.add_child(root)
	var mats: Dictionary = Mats.materials().duplicate()
	mats["yard"] = PBR.surface("dirt_ground_01", Color(0.78, 0.68, 0.55), {"metres": 2.0})
	mats["path"] = PBR.surface("floor_flagstone_01", Color(0.68, 0.66, 0.62), {"metres": 3.0})
	mats["ember"] = _glow(Color(1.0, 0.45, 0.12), 3.0)
	_trial_hall(root, mats)
	_hearth_pavilion(root, mats)
	_training_yard(root, mats)
	_kestrin_forge(root)
	_cave_mouth(root, mats)
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		node.add_to_group("grounds_site_geometry")
	return root


# ------------------------------------------------------------------ data

## The grounds portal dressed as `dressing`: [trigger centre on the ground,
## yaw (radians) its doorway faces, the portal entry], or [] when none is.
static func portal_spot(dressing: String) -> Array:
	var maps: Variant = RealmContent.table("maps")
	var portals: Array = (maps as Dictionary).get("portals", []) if maps is Dictionary else []
	for entry: Dictionary in portals:
		if String(entry.get("map_id", "")) != MAP or String(entry.get("dressing", "")) != dressing:
			continue
		var raw: Array = (entry as Dictionary).get("trigger", {}).get("center", [0, 0, 0])
		return [Layout.ground(float(raw[0]), float(raw[2])), deg_to_rad(float(entry.get("facing", 0.0))), entry]
	return []


## The training yard's centre: the middle of the dummies' row, a few metres
## in front of them (they line the yard's east fence).
static func yard_centre() -> Vector3:
	var lm := Layout.landmark("training")
	return lm if lm != Vector3.INF else Layout.ground(78, 27)


static func _glow(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


## A strip of paving draped on the terrain along `pts` (x, z) (the server's
## pack has it as a collider: bodies stand on the cover, as in the courtyard).
static func _drape(root: Node3D, pts: Array, width: float, lift: float, mat: Material, node_name: String) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in pts.size() - 1:
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[k + 1]
		var length := a.distance_to(b)
		var dir := (b - a) / length
		var n := Vector2(-dir.y, dir.x) * width * 0.5
		var steps := maxi(1, int(ceil(length / 1.5)))
		for s in steps:
			var p0 := a.lerp(b, float(s) / steps)
			var p1 := a.lerp(b, float(s + 1) / steps)
			var q := [p0 - n, p0 + n, p1 + n, p1 - n]
			var v := []
			for p in q:
				v.append(Layout.ground(p.x, p.y) + Vector3.UP * lift)
			for i in [0, 2, 1, 0, 3, 2]:
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(v[i].x, v[i].z) * 0.33)
				st.add_vertex(v[i])
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


# ------------------------------------------------------------- Trial Hall

const HALL_W := 13.0
const HALL_D := 18.0
const HALL_H := 8.0
const DOOR := Vector2(3.2, 5.0)

## The gate's veil: two noise layers drifting against each other, the slow one
## warping the fine one, so the light moves like a disturbed surface rather
## than a drawn spiral; blue at the heart, gold toward the stone, soft at the
## edge.
const PORTAL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 rim : source_color = vec4(1.0, 0.76, 0.32, 1.0);
uniform vec4 core : source_color = vec4(0.32, 0.58, 1.0, 1.0);
uniform sampler2D noise : repeat_enable, filter_linear_mipmap;
void fragment() {
	vec2 p = (UV - vec2(0.5, 0.55)) * vec2(2.0, 2.2);
	float r = length(p);
	vec2 rise = vec2(0.0, TIME * 0.06);
	float warp = texture(noise, UV * vec2(0.7, 0.5) + vec2(TIME * 0.021, TIME * 0.013)).r - 0.5;
	float n = texture(noise, UV * vec2(1.4, 1.0) + rise + warp * 0.45).r;
	float m = texture(noise, UV * vec2(3.0, 2.2) - rise * 1.6 + warp * 0.25).r;
	float body = smoothstep(0.3, 0.8, n * 0.65 + m * 0.35);
	float edge = smoothstep(1.05, 0.62, r);
	vec3 colour = mix(core.rgb, rim.rgb, clamp(r * 0.85 + (m - 0.5) * 0.5, 0.0, 1.0));
	ALBEDO = colour * (0.55 + 0.9 * body);
	ALPHA = edge * (0.16 + 0.7 * body);
}
"""

## A stone hall with a porch; the glowing doorway is the dungeon gate (the
## trigger stands just in front of it, between the porch columns).
static func _trial_hall(root: Node3D, mats: Dictionary) -> void:
	var spot := portal_spot("trial_hall")
	if spot.is_empty():
		return
	var t: Vector3 = spot[0]
	var rot: float = spot[1]
	var basis := Basis(Vector3.UP, rot)
	var fwd := basis * Vector3.BACK   # local +z: out of the door
	var side := basis * Vector3.RIGHT
	var front := t - fwd * 1.5        # the front wall's outer face
	var c := front - fwd * HALL_D * 0.5
	var span := Layout.ground_span(Vector2(c.x, c.z), Vector2(HALL_W, HALL_D), rot)
	var fy := span.y + 0.05
	var kit := ArchKit.new()
	var base := span.x - 1.0
	kit.box(Vector3(c.x, (base + fy + HALL_H) * 0.5, c.z), Vector3(HALL_W, fy + HALL_H - base, HALL_D), rot, "stone")
	kit.box(Vector3(c.x, fy + 0.4, c.z), Vector3(HALL_W + 0.5, 0.8, HALL_D + 0.5), rot, "trim", false)
	kit.box(Vector3(c.x, fy + HALL_H - 0.2, c.z), Vector3(HALL_W + 0.4, 0.4, HALL_D + 0.4), rot, "trim", false)
	# buttresses down the long sides, lancets between them
	for s in [-1.0, 1.0]:
		for k in 4:
			var along := -HALL_D * 0.5 + 1.5 + k * (HALL_D - 3.0) / 3.0
			var p: Vector3 = c + side * s * (HALL_W * 0.5 + 0.45) + fwd * along
			kit.box(Vector3(p.x, (base + fy + HALL_H - 1.2) * 0.5, p.z), Vector3(0.9, fy + HALL_H - 1.2 - base, 1.1), rot, "trim")
			if k < 3:
				var w: Vector3 = c + side * s * (HALL_W * 0.5 + 0.01) + fwd * (along + (HALL_D - 3.0) / 6.0)
				kit.window(Vector3(w.x, fy + 4.4, w.z), side * s, 1.1, 2.6, "trim", "glass")
	# roof: the ridge runs front to back
	kit.gable(Vector3(c.x, fy + HALL_H, c.z), Vector2(HALL_D, HALL_W), 4.6, rot + PI * 0.5, "roof", "stone", 0.8)
	# the door: jambs and a lintel proud of the wall, the gate glows in it
	for s in [-1.0, 1.0]:
		var j: Vector3 = front + side * s * (DOOR.x * 0.5 + 0.35) + fwd * 0.2
		kit.box(Vector3(j.x, fy + DOOR.y * 0.5, j.z), Vector3(0.7, DOOR.y, 0.4), rot, "trim", false)
	var lintel := front + fwd * 0.2
	kit.box(Vector3(lintel.x, fy + DOOR.y + 0.35, lintel.z), Vector3(DOOR.x + 1.5, 0.7, 0.45), rot, "trim", false)
	# porch: two columns and a pediment roof over the gate
	for s in [-1.0, 1.0]:
		var col: Vector3 = front + side * s * 2.9 + fwd * 3.0
		var g := Layout.ground(col.x, col.z)
		kit.box(g + Vector3(0, 0.3, 0), Vector3(1.0, 0.8, 1.0), rot, "trim")
		kit.cylinder(g + Vector3(0, 0.6, 0), 0.38, fy + 6.0 - g.y - 0.6, "trim", 12)
	var porch := front + fwd * 1.7
	kit.box(Vector3(porch.x, fy + 6.25, porch.z), Vector3(7.2, 0.5, 3.8), rot, "trim")
	kit.gable(Vector3(porch.x, fy + 6.5, porch.z), Vector2(3.8, 7.2), 2.0, rot + PI * 0.5, "roof", "stone", 0.4)
	kit.box(Vector3(porch.x, t.y - 0.02, porch.z), Vector3(7.6, 0.2, 4.2), rot, "trim", false)
	var hall := kit.finish(root, mats, "TrialHall")
	# the walk from the castle road up to the porch
	var road := _nearest_road_point(Vector2(t.x, t.z), Vector2(fwd.x, fwd.z))
	var path_from := Vector2(t.x, t.z) + Vector2(fwd.x, fwd.z) * 2.2
	if road.distance_to(path_from) > 1.0:
		_drape(hall, [path_from, road], 3.0, 0.07, mats.get("path"), "TrialPath")
	var holder := Node3D.new()
	holder.name = "TrialGate"
	holder.position = Vector3(front.x, fy, front.z) + fwd * 0.05
	holder.rotation.y = rot
	hall.add_child(holder)
	var quad := QuadMesh.new()
	quad.size = DOOR - Vector2(0.1, 0.1)
	var shader := Shader.new()
	shader.code = PORTAL_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("noise", _veil_noise())
	quad.material = mat
	var veil := MeshInstance3D.new()
	veil.mesh = quad
	veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	veil.position = Vector3(0, DOOR.y * 0.5, 0)
	holder.add_child(veil)
	var dark := MeshInstance3D.new()
	var back := QuadMesh.new()
	back.size = DOOR
	dark.mesh = back
	dark.material_override = mats.get("dark")
	dark.position = Vector3(0, DOOR.y * 0.5, -0.04)
	holder.add_child(dark)
	var light := OmniLight3D.new()
	light.light_color = Color(0.55, 0.7, 1.0)
	light.light_energy = 1.6
	light.omni_range = 9.0
	light.position = Vector3(0, 2.4, 1.2)
	holder.add_child(light)
	# on the porch's pediment, over the gate (not up in the sky)
	# the first dungeon's door, a goal of the first chapter: read a little farther
	Mats.label(holder, I18n.t("Trial Hall"), I18n.t("Press {key:interact} at the door"), Vector3(0, 7.4, 4.4), 120.0)


## The veil's noise: soft, seamless, domain-warped value noise.
static func _veil_noise() -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = 6907
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.012
	n.fractal_octaves = 4
	n.domain_warp_enabled = true
	n.domain_warp_amplitude = 18.0
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.generate_mipmaps = true
	t.noise = n
	return t


## The point of the nearest road (layout.json) ahead of `from` along `dir`
## (within 40 m), or `from` itself when no road is near.
static func _nearest_road_point(from: Vector2, dir: Vector2) -> Vector2:
	var best := from
	var best_d := 40.0
	for r in Layout.roads():
		var pts: Array = r["points"]
		for k in pts.size() - 1:
			var a := Vector2(pts[k][0], pts[k][1])
			var b := Vector2(pts[k + 1][0], pts[k + 1][1])
			var q := Geometry2D.get_closest_point_to_segment(from, a, b)
			var d := q.distance_to(from)
			if d < best_d and (q - from).dot(dir) > 0.0:
				best_d = d
				# stop at the road's near verge
				best = q - (q - from).normalized() * float(r.get("width", 4.0)) * 0.5
	return best


# --------------------------------------------------------- Hearth Pavilion

## An open stone pavilion round the hearth by the castle approach: four
## columns, a pyramid roof and a back wall behind the hearth.
static func _hearth_pavilion(root: Node3D, mats: Dictionary) -> void:
	var travel: Variant = RealmContent.table("travel")
	var nodes: Dictionary = (travel as Dictionary).get("nodes", {}) if travel is Dictionary else {}
	var node: Dictionary = nodes.get("hearth_pavilion", {})
	if node.is_empty() or String(node.get("map", "")) != MAP:
		return
	var raw: Array = node.get("pos", [0.0, 0.0, 0.0])
	var h := Layout.ground(float(raw[0]), float(raw[2]))
	var rot := deg_to_rad(float(node.get("yaw", 0.0)))
	var basis := Basis(Vector3.UP, rot)
	var fwd := basis * Vector3.BACK
	var side := basis * Vector3.RIGHT
	var c := h + fwd * 2.0
	c.y = Layout.ground(c.x, c.z).y
	var kit := ArchKit.new()
	var half := 3.6
	kit.box(c + Vector3(0, 0.0, 0), Vector3(9.0, 0.16, 9.0), rot, "cobble")
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var p: Vector3 = c + side * sx * half + fwd * sz * half
			var g := Layout.ground(p.x, p.z)
			kit.box(g + Vector3(0, 0.25, 0), Vector3(0.9, 0.7, 0.9), rot, "trim")
			kit.cylinder(g + Vector3(0, 0.6, 0), 0.32, c.y + 5.0 - g.y - 0.6, "trim", 10)
	# beams on the columns, then the roof
	for k in 4:
		var a := rot + PI * 0.5 * k
		var b := Basis(Vector3.UP, a)
		kit.box(c + b * Vector3(0, 0, half) + Vector3(0, 5.25, 0), Vector3(half * 2.0 + 0.9, 0.5, 0.6), a, "trim", false)
	kit.pyramid(c + Vector3(0, 5.5, 0), Vector2(half * 2.0 + 0.6, half * 2.0 + 0.6), 3.0, rot, "roof", 0.5)
	# the back wall the hearth stands against
	var wall := c - fwd * (half + 0.1)
	var wg := Layout.ground_span(Vector2(wall.x, wall.z), Vector2(7.0, 0.6), rot)
	kit.box(Vector3(wall.x, (wg.x - 0.5 + c.y + 5.0) * 0.5, wall.z), Vector3(half * 2.0, c.y + 5.0 - wg.x + 0.5, 0.6), rot, "stone")
	var pav := kit.finish(root, mats, "HearthPavilion")
	Mats.label(pav, I18n.t("Hearth Pavilion"), "", c + Vector3(0, 9.6, 0))


# ------------------------------------------------------------ training yard

## A rail fence round the dummies with its gate towards the landing pad, and
## packed earth inside.
static func _training_yard(root: Node3D, mats: Dictionary) -> void:
	var y := yard_centre()
	var kit := ArchKit.new()
	var corners := [Vector2(-YARD_HALF.x, -YARD_HALF.y), Vector2(YARD_HALF.x, -YARD_HALF.y),
		Vector2(YARD_HALF.x, YARD_HALF.y), Vector2(-YARD_HALF.x, YARD_HALF.y)]
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var length := a.distance_to(b)
		var n := int(ceil(length / 2.4))
		for k in n:
			var p0 := a.lerp(b, float(k) / n)
			var p1 := a.lerp(b, float(k + 1) / n)
			var mid := (p0 + p1) * 0.5
			# the gate: the middle of the west side stays open
			if i == 3 and absf(mid.y) < YARD_GATE * 0.5:
				continue
			var g0 := Layout.ground(y.x + p0.x, y.z + p0.y)
			var g1 := Layout.ground(y.x + p1.x, y.z + p1.y)
			kit.box(g0 + Vector3(0, 0.6, 0), Vector3(0.22, 1.5, 0.22), 0.0, "timber")
			var m := (g0 + g1) * 0.5
			var rot := atan2(p1.x - p0.x, p1.y - p0.y)
			var seg := p0.distance_to(p1) + 0.05
			kit.box(m + Vector3(0, 1.1, 0), Vector3(0.1, 0.14, seg), rot, "timber")
			kit.box(m + Vector3(0, 0.6, 0), Vector3(0.1, 0.14, seg), rot, "timber")
	# gate posts
	for s in [-1.0, 1.0]:
		var g := Layout.ground(y.x - YARD_HALF.x, y.z + s * YARD_GATE * 0.5)
		kit.box(g + Vector3(0, 0.9, 0), Vector3(0.36, 2.2, 0.36), 0.0, "timber")
	kit.finish(root, mats, "TrainingYard")
	# packed earth: draped strips across the yard
	var strips := Node3D.new()
	strips.name = "TrainingYardFloor"
	root.add_child(strips)
	var z := -YARD_HALF.y + 0.3
	while z < YARD_HALF.y - 0.3:
		var z1 := minf(z + 2.0, YARD_HALF.y - 0.3)
		var zm := (z + z1) * 0.5
		_drape(strips, [Vector2(y.x - YARD_HALF.x + 0.3, y.z + zm), Vector2(y.x + YARD_HALF.x - 0.3, y.z + zm)],
			z1 - z + 0.02, 0.05, mats.get("yard"), "YardStrip")
		z = z1


# -------------------------------------------------------------- Kestrin's forge

## Kestrin's smithy is a kit building on the west side of Orvell square
## (Sites.smithy_site, VillageKit "smithy"); here its hearth's glow
## and its name over the door.
static func _kestrin_forge(root: Node3D) -> void:
	if Layout.landmark("orvell_square") == Vector3.INF:
		return
	var site := Sites.smithy_site()
	var c: Vector2 = site[0]
	var basis := Basis(Vector3.UP, float(site[1]))
	var g := Layout.ground(c.x, c.y)
	var hearth: Vector3 = g + basis * Vector3(1.8, 1.9, -1.6)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.55, 0.25)
	l.light_energy = 1.6
	l.omni_range = 7.0
	l.position = hearth
	l.add_to_group("grounds_torch_lights")
	root.add_child(l)
	# a smithy on the square: read in Orvell and on the way in, not from the castle
	Mats.label(root, I18n.t("Kestrin's Forge"), "", g + basis * Vector3(0, 6.8, 3.0), 85.0)


# ------------------------------------------------------------------ cave mouth

## The way down to the Blackweb Caverns: a dark mouth in the slope, framed by
## rock, webbed at the corners, a faint green glow inside.
static func _cave_mouth(root: Node3D, mats: Dictionary) -> void:
	var spot := portal_spot("cave_mouth")
	if spot.is_empty():
		return
	var t: Vector3 = spot[0]
	var rot: float = spot[1]
	var basis := Basis(Vector3.UP, rot)
	var fwd := basis * Vector3.BACK
	var side := basis * Vector3.RIGHT
	var kit := ArchKit.new()
	# the dark beyond the mouth, then the hillside mass it is cut into
	var void_at := t - fwd * 2.7
	kit.box(Vector3(void_at.x, t.y + 1.5, void_at.z), Vector3(5.2, 8.0, 1.0), rot, "dark")
	var mass := t - fwd * 6.0
	kit.box(Vector3(mass.x, t.y + 3.0, mass.z), Vector3(12.0, 10.0, 6.0), rot, "rubble")
	var rng := RandomNumberGenerator.new()
	rng.seed = 4108
	for s in [-1.0, 1.0]:
		var jamb: Vector3 = t + side * s * 3.6 - fwd * 1.2
		kit.box(Vector3(jamb.x, t.y + 2.4, jamb.z), Vector3(2.4, 8.0, 3.6), rot + s * 0.12, "rubble")
		var boulder: Vector3 = t + side * s * 4.3 + fwd * 1.0
		var g := Layout.ground(boulder.x, boulder.z)
		kit.box(g + Vector3(0, 0.9, 0), Vector3(2.0, 2.6, 2.2), rot + s * 0.5, "mossy")
	var lintel := t - fwd * 1.3
	kit.box(Vector3(lintel.x, t.y + 6.2, lintel.z), Vector3(9.4, 2.4, 3.8), rot + 0.04, "rubble")
	# scree in front, low enough to walk past
	for i in 7:
		var p: Vector3 = t + side * rng.randf_range(-5.5, 5.5) + fwd * rng.randf_range(1.5, 5.0)
		if absf((p - t).dot(side)) < 1.8:
			continue
		var g := Layout.ground(p.x, p.z)
		var sz := rng.randf_range(0.5, 1.1)
		kit.box(g + Vector3(0, sz * 0.3, 0), Vector3(sz, sz * 0.8, sz * 1.2), rng.randf() * TAU, "mossy", false)
	var mouth := kit.finish(root, mats, "CaveMouth")
	var l := OmniLight3D.new()
	l.light_color = Color(0.5, 0.8, 0.45)
	l.light_energy = 1.2
	l.omni_range = 7.0
	l.position = t + Vector3(0, 2.2, 0) - fwd * 1.2
	mouth.add_child(l)
	var web := ShaderMaterial.new()
	web.shader = load("res://assets/shaders/cobweb.gdshader")
	web.set_shader_parameter("web", load("res://assets/vfx/tex/cobweb_1024.png"))
	web.set_shader_parameter("tint", Color(0.6, 0.8, 0.55))
	web.set_shader_parameter("opacity", 0.7)
	for s in [-1.0, 1.0]:
		var q := QuadMesh.new()
		q.size = Vector2(2.6, 2.6)
		q.material = web
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = t - fwd * 0.6 + side * s * 1.9 + Vector3(0, 4.0, 0)
		mi.rotation.y = rot
		mi.rotation.z = s * 0.6
		mouth.add_child(mi)
