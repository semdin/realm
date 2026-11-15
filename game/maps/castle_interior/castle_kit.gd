extends RefCounted

## The castle interior's surfaces, room lights and occluders (the old game's
## castle_blockout.gd, the Gothic build only).
##
## res://assets/castle/castle_interior.glb is art/castle/layout.json built by
## Blender: visual meshes merged per room and material, `kit_<slot>`
## materials (resolved here to world-space triplanar PBR surfaces - the
## dressing has no UVs) and one convex collider per piece. The map server's
## pack was compiled from the very same colliders, so the glb placed with its
## layout L0 at y = 200 stands where the server's walls and floors do. The
## client simulates nothing with Godot physics: the colliders only give the
## occluders their boxes, then they are dropped.
##
## Every surface takes the low-preset path the old game measured on Intel
## iGPUs: the PBR shader's `lite` mode (no roughness / AO reads), so those
## maps are never loaded either.

const SHADER := preload("res://assets/shaders/triplanar_pbr.gdshader")
const WINDOW_SHADER := preload("res://assets/shaders/castle/window_view.gdshader")
const LAKE_SHADER := preload("res://assets/shaders/castle/lake_window.gdshader")
const SKY_SHADER := preload("res://assets/shaders/castle/enchanted_sky.gdshader")

const GOTHIC := "res://assets/castle/castle_interior.glb"
const LAYOUT := "res://assets/castle/castle_layout.json"
const TEXTURES := "res://assets/castle/textures/%s"
const PBR_DIR := "res://assets/textures/pbr/%s/%s_%s_2k.%s"

## Texture sets: [albedo name, normal name, extension, metres per tile].
const PBR_SETS := {
	"large_sandstone_blocks_01": ["diff", "nor_gl", "jpg", 3.5],
	"sandstone_blocks_08": ["diff", "nor_gl", "jpg", 2.5],
	"plaster_grey_04": ["diff", "nor_gl", "jpg", 3.0],
	"large_floor_tiles_02": ["diff", "nor_gl", "jpg", 4.0],
	"medieval_blocks_03": ["diff", "nor_gl", "jpg", 3.0],
	"medieval_wood": ["diff", "nor_gl", "jpg", 2.5],
	"stone_ashlar_01": ["albedo", "normal", "png", 8.0],
}

## Slots whose surfaces must not cast shadows: glazing, cloth, paintings and
## the enchanted ceiling would block the moonlight.
const NO_SHADOW := ["glass", "sky_vault", "glass_clear", "stained_side", "stained_west", "compass",
	"tapestry", "lake_window", "leaf"]

static var _surfaces: Dictionary = {}

static func load_layout() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	return parsed if parsed is Dictionary else {}

## The imported castle, or null when this build does not carry it.
static func instantiate() -> Node3D:
	if not ResourceLoader.exists(GOTHIC):
		return null
	var packed := load(GOTHIC) as PackedScene
	return packed.instantiate() as Node3D if packed != null else null

## A world-space triplanar PBR surface on the lite path. `object_space`
## samples in the mesh's own space instead (a moving staircase flight: the
## stone stays on the stone as it swings).
static func surface(set_id: String, tint: Color = Color.WHITE, metres: float = 0.0,
		object_space := false) -> ShaderMaterial:
	var key := "%s|%s|%.2f|%s" % [set_id, tint.to_html(), metres, object_space]
	if _surfaces.has(key):
		return _surfaces[key]
	var spec: Array = PBR_SETS[set_id]
	var m := ShaderMaterial.new()
	m.shader = SHADER if not object_space else load("res://maps/castle_interior/flight_pbr.gdshader")
	m.set_shader_parameter("albedo_tex", load(PBR_DIR % [set_id, set_id, spec[0], spec[2]]))
	m.set_shader_parameter("normal_tex", load(PBR_DIR % [set_id, set_id, spec[1], spec[2]]))
	m.set_shader_parameter("lite", true)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("world_scale", 1.0 / maxf(0.05, metres if metres > 0.0 else float(spec[3])))
	_surfaces[key] = m
	return m

static func _plain(colour: Color, roughness: float, metallic := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = roughness
	m.metallic = metallic
	return m

static func _glowing(colour: Color, energy: float, roughness: float) -> StandardMaterial3D:
	var m := _plain(colour, roughness)
	m.emission_enabled = true
	m.emission = colour
	m.emission_energy_multiplier = energy
	return m

## Gothic kit slot -> material (the old castle's look, slot for slot).
static func kit_material(slot: String) -> Material:
	if slot.begins_with("portrait_"):
		var canvas := StandardMaterial3D.new()
		canvas.albedo_texture = load(TEXTURES % (slot + ".jpg"))
		canvas.roughness = 0.8
		return canvas
	match slot:
		# grey-gold sandstone ashlar walls, dressed stone mouldings,
		# limewashed vault webs, worn flagstones; the dungeons cold grey
		"stone":
			return surface("large_sandstone_blocks_01", Color(0.96, 0.92, 0.85))
		"stone_cold":
			return surface("medieval_blocks_03", Color(0.82, 0.86, 0.9))
		"stone_dark":
			return surface("medieval_blocks_03", Color(0.5, 0.5, 0.52))
		"stone_vault":
			return surface("plaster_grey_04", Color(1.0, 0.95, 0.86))
		"stone_vault_cold":
			return surface("plaster_grey_04", Color(0.72, 0.76, 0.8))
		"trim":
			return surface("sandstone_blocks_08", Color(1.0, 0.95, 0.88))
		"trim_cold":
			return surface("medieval_blocks_03", Color(0.95, 0.97, 1.0), 2.0)
		"stone_floor":
			return surface("large_floor_tiles_02", Color(0.95, 0.92, 0.88))
		"wood":
			return surface("medieval_wood", Color(0.9, 0.82, 0.74))
		"wood_dark":
			return surface("medieval_wood", Color(0.55, 0.45, 0.4))
		"glass":
			# the moonlit highland vista beyond, behind diamond leaded quarries
			var view := ShaderMaterial.new()
			view.shader = WINDOW_SHADER
			view.set_shader_parameter("vista", load(TEXTURES % "window_vista_night.jpg"))
			view.set_shader_parameter("energy", 1.25)
			view.set_shader_parameter("lite", 1.0)
			return view
		"banner_red", "banner_green", "banner_blue", "banner_yellow":
			var cloth := StandardMaterial3D.new()
			cloth.albedo_texture = load(TEXTURES % (slot + ".png"))
			cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
			cloth.roughness = 0.92
			return cloth
		"stained_side", "stained_west":
			# leaded light glowing with the dusk behind it
			var pane := StandardMaterial3D.new()
			var tex: Texture2D = load(TEXTURES % (slot + ".png"))
			pane.albedo_texture = tex
			pane.albedo_color = Color(0.35, 0.35, 0.35)
			pane.emission_enabled = true
			pane.emission_texture = tex
			pane.emission_energy_multiplier = 1.4
			pane.roughness = 0.2
			return pane
		"glass_clear":
			var clear := StandardMaterial3D.new()
			clear.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			clear.albedo_color = Color(0.85, 0.92, 1.0, 0.18)
			clear.roughness = 0.05
			clear.metallic_specular = 0.9
			clear.cull_mode = BaseMaterial3D.CULL_DISABLED
			return clear
		"brass":
			return _plain(Color(0.78, 0.6, 0.3), 0.32, 1.0)
		"gilt":
			return _plain(Color(0.83, 0.64, 0.3), 0.38, 1.0)
		"iron":
			return _plain(Color(0.12, 0.11, 0.11), 0.5, 0.85)
		"gem_red":
			return _glowing(Color(1.0, 0.12, 0.1), 2.2, 0.15)
		"gem_green":
			return _glowing(Color(0.1, 0.9, 0.35), 2.2, 0.15)
		"gem_blue":
			return _glowing(Color(0.15, 0.4, 1.0), 2.2, 0.15)
		"gem_yellow":
			return _glowing(Color(1.0, 0.8, 0.15), 2.2, 0.15)
		"compass":
			# a round inlay: the texture's corners are cut away by its alpha
			var painted := StandardMaterial3D.new()
			painted.albedo_texture = load(TEXTURES % "compass.png")
			painted.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			painted.alpha_scissor_threshold = 0.5
			painted.roughness = 0.55
			painted.metallic = 0.25
			return painted
		"slate":
			return _plain(Color(0.07, 0.085, 0.075), 0.95)
		"soot":
			return _plain(Color(0.04, 0.035, 0.03), 1.0)
		"potion":
			var brew := _glowing(Color(0.2, 0.9, 0.35), 1.6, 0.1)
			brew.emission = Color(0.25, 1.0, 0.4)
			return brew
		"jar_green", "jar_amber", "jar_purple", "jar_blue":
			# murky old glass: dark bodies with a faint inner glow
			var tint: Color = {"jar_green": Color(0.36, 0.52, 0.22), "jar_amber": Color(0.62, 0.38, 0.12),
				"jar_purple": Color(0.36, 0.2, 0.42), "jar_blue": Color(0.18, 0.3, 0.45)}[slot]
			var jar := _glowing(tint, 0.12, 0.08)
			jar.metallic_specular = 0.9
			return jar
		"books":
			var books := StandardMaterial3D.new()
			books.albedo_texture = load(TEXTURES % "books.jpg")
			books.cull_mode = BaseMaterial3D.CULL_DISABLED
			books.roughness = 0.85
			return books
		"cloth_red", "cloth_blue", "cloth_green", "cloth_yellow", \
				"cloth_red_dark", "cloth_blue_dark", "cloth_green_dark", "cloth_yellow_dark":
			var base: Color = {"cloth_red": Color(0.55, 0.08, 0.07), "cloth_blue": Color(0.1, 0.18, 0.5),
				"cloth_green": Color(0.06, 0.3, 0.16), "cloth_yellow": Color(0.78, 0.58, 0.12)}[slot.trim_suffix("_dark")]
			return _plain(base * (0.55 if slot.ends_with("_dark") else 1.0), 0.95)
		"straw":
			return _plain(Color(0.72, 0.6, 0.32), 1.0)
		"terracotta":
			return _plain(Color(0.62, 0.32, 0.18), 0.9)
		"leaf":
			var leaf := _plain(Color(0.16, 0.38, 0.12), 0.8)
			leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
			return leaf
		"tapestry":
			var weave := StandardMaterial3D.new()
			weave.albedo_texture = load(TEXTURES % "tapestry.jpg")
			weave.roughness = 0.95
			return weave
		"lake_window":
			var lake := ShaderMaterial.new()
			lake.shader = LAKE_SHADER
			return lake
		"sky_vault":
			var sky := ShaderMaterial.new()
			sky.shader = SKY_SHADER
			return sky
		"seal":
			return _glowing(Color(0.55, 0.2, 0.95), 1.5, 0.9)
	push_warning("castle: no material for kit slot %s" % slot)
	return _plain(Color(1, 0, 1), 0.9)   # magenta: an unassigned slot is never silent

## Every `kit_<slot>` surface of the build gets its material (one per slot,
## shared); glazing and cloth cast no shadow.
static func restyle(root: Node) -> void:
	var cache := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s)
			var src_name := src.resource_name if src != null else ""
			if not src_name.begins_with("kit_"):
				continue
			var slot := src_name.trim_prefix("kit_")
			if slot in NO_SHADOW or slot.begins_with("banner_") or slot.begins_with("portrait_"):
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if not cache.has(slot):
				cache[slot] = kit_material(slot)
			mi.set_surface_override_material(s, cache[slot])

## One box occluder per large wall, floor and ceiling piece (from the glb's
## W_*, F_*, C_* colliders), so a room hides what stands behind its walls and
## the storeys above and below. Window and door gaps stay open: the walls are
## already split around them.
static func add_occluders(structure: Node3D) -> int:
	var count := 0
	for node in structure.find_children("*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		var tag := String(body.name).left(2)
		if not (tag == "W_" or tag == "F_" or tag == "C_"):
			continue
		for child in body.get_children():
			var cs := child as CollisionShape3D
			if cs == null or not (cs.shape is ConvexPolygonShape3D):
				continue
			var pts: PackedVector3Array = (cs.shape as ConvexPolygonShape3D).points
			if pts.is_empty():
				continue
			var box := AABB(pts[0], Vector3.ZERO)
			for p in pts:
				box = box.expand(p)
			var dims := [box.size.x, box.size.y, box.size.z]
			dims.sort()
			if dims[0] < 0.35 or dims[1] < 3.0 or dims[2] < 3.0:
				continue
			var occ := OccluderInstance3D.new()
			var shape := BoxOccluder3D.new()
			shape.size = (box.size - Vector3(0.1, 0.1, 0.1)).max(Vector3(0.05, 0.05, 0.05))
			occ.occluder = shape
			structure.add_child(occ)
			occ.global_transform = cs.global_transform * Transform3D(Basis(), box.get_center())
			count += 1
	return count

## The colliders go once the occluders are made: nothing here collides (the
## client core does, against the map pack).
static func drop_bodies(structure: Node3D) -> int:
	var bodies := structure.find_children("*", "StaticBody3D", true, false)
	for body in bodies:
		body.get_parent().remove_child(body)
		body.free()
	return bodies.size()

## One warm light per 24 m bay of every room (at 70 % of the room height,
## never above 12 m), plus one per Grand Staircase gallery.
static func add_room_lights(parent: Node3D, layout: Dictionary, map_y: float, energy: float) -> void:
	for r in layout.get("rooms", []):
		var rect: Array = r["rect"]
		var y := float(r["y"])
		var h := float(r["h"])
		var w := float(rect[1]) - float(rect[0])
		var d := float(rect[3]) - float(rect[2])
		var nx := maxi(1, int(ceil(w / 24.0)))
		var nz := maxi(1, int(ceil(d / 24.0)))
		for i in nx:
			for j in nz:
				var light := OmniLight3D.new()
				light.light_color = Color(1.0, 0.86, 0.66)
				light.omni_range = maxf(w / nx, d / nz) * 0.95 + minf(h, 12.0) * 0.6
				light.light_energy = energy
				light.omni_attenuation = 0.6
				light.position = Vector3(float(rect[0]) + (i + 0.5) * w / nx, map_y + y + minf(h * 0.7, 12.0),
					float(rect[2]) + (j + 0.5) * d / nz)
				parent.add_child(light)
	var ms: Dictionary = layout.get("moving_stairs", {})
	var axis: Array = ms.get("axis", [0.0, 0.0])
	var levels: Dictionary = layout.get("levels", {})
	for k in levels:
		if float(levels[k]) > 0.0:
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.9, 0.75)
			light.omni_range = 30.0
			light.light_energy = 1.2
			light.position = Vector3(float(axis[0]), map_y + float(levels[k]) + 6.0, float(axis[1]))
			parent.add_child(light)
