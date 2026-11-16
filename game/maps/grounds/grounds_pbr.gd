extends RefCounted

## The grounds' world-space triplanar PBR materials (the old game's PBRKit,
## the sets the grounds use): which texture set backs each surface, at what
## physical scale, and the shader material built from it, so no surface
## stretches whatever the size of the box it is painted on.

const SHADER := preload("res://assets/shaders/triplanar_pbr.gdshader")

## set id -> [file pattern (set, map, res, ext), maps, metres per tile].
## `maps` names each channel's file suffix.
const POLY := {"albedo": "diff", "normal": "nor_gl", "rough": "rough", "ao": "ao"}
const AUTHORED := {"albedo": "albedo", "normal": "normal", "rough": "rough", "ao": "ao"}
const SETS := {
	"castle_wall_varriation": ["2k", "jpg", POLY, 4.0],
	"roof_slates_02": ["2k", "jpg", POLY, 3.0],
	"medieval_wood": ["2k", "jpg", POLY, 2.5],
	"white_rough_plaster": ["2k", "jpg", POLY, 3.0],
	"wooden_planks": ["2k", "jpg", POLY, 2.5],
	"mossy_stone_wall": ["2k", "jpg", POLY, 3.0],
	"cobblestone_floor_04": ["2k", "jpg", POLY, 4.0],
	"stone_floor": ["2k", "jpg", POLY, 3.0],
	"cobblestone_large_01": ["2k", "jpg", POLY, 3.0],
	"leafy_grass": ["2k", "jpg", POLY, 2.5],
	"sandstone_blocks_08": ["2k", "jpg", POLY, 2.5],
	"stone_wall": ["2k", "jpg", POLY, 4.0],
	"grey_roof_tiles": ["2k", "jpg", POLY, 3.0],
	"stone_tiles_02": ["2k", "jpg", POLY, 8.0],
	"floor_flagstone_01": ["2k", "png", AUTHORED, 8.0],
	"dirt_ground_01": ["1k", "png", {"albedo": "albedo", "normal": "normal", "rough": "rough"}, 4.0],
	# worn castle flags (the great doors' porch and apron) and big weathered
	# ashlar (the lake stair's flanks): albedo and normal only
	"medieval_blocks_03": ["2k", "jpg", POLY, 3.0],
	"large_sandstone_blocks_01": ["2k", "jpg", POLY, 3.0],
}

## The low preset's lighter path (QualityPreset lite_surfaces, the old client's low path
## for these surfaces): the roughness and AO maps are neither sampled (two of
## the four texture reads per pixel) nor loaded.
static var lite := false

static var _maps_cache: Dictionary = {}
static var _material_cache: Dictionary = {}


static func set_maps(set_id: String) -> Dictionary:
	if _maps_cache.has(set_id):
		return _maps_cache[set_id]
	var out := {}
	var spec: Array = SETS.get(set_id, [])
	if not spec.is_empty():
		var maps: Dictionary = spec[2]
		for channel: String in maps:
			if lite and (channel == "rough" or channel == "ao"):
				# the lite path never samples them: never loaded either
				out[channel] = null
				continue
			var path := "res://assets/textures/pbr/%s/%s_%s_%s.%s" % [set_id, set_id, maps[channel], spec[0], spec[1]]
			out[channel] = load(path) if ResourceLoader.exists(path) else null
		out["metres"] = float(spec[3])
	_maps_cache[set_id] = out
	return out


## A world-space triplanar PBR material. `tint` multiplies albedo (sRGB).
static func surface(set_id: String, tint: Color = Color.WHITE, opts: Dictionary = {}) -> ShaderMaterial:
	var key := "%s|%s|%s" % [set_id, tint.to_html(), str(opts)]
	if _material_cache.has(key):
		return _material_cache[key]
	var maps := set_maps(set_id)
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("albedo_tex", maps.get("albedo"))
	m.set_shader_parameter("normal_tex", maps.get("normal"))
	m.set_shader_parameter("rough_tex", maps.get("rough"))
	m.set_shader_parameter("ao_tex", maps.get("ao"))
	m.set_shader_parameter("tint", tint)
	var metres: float = float(opts.get("metres", maps.get("metres", 4.0)))
	m.set_shader_parameter("world_scale", 1.0 / maxf(0.05, metres))
	m.set_shader_parameter("normal_strength", float(opts.get("normal_strength", 1.0)))
	m.set_shader_parameter("rough_min", float(opts.get("rough_min", 0.03)))
	m.set_shader_parameter("rough_max", float(opts.get("rough_max", 1.0)))
	m.set_shader_parameter("ao_strength", float(opts.get("ao_strength", 1.0)))
	m.set_shader_parameter("metallic_amount", float(opts.get("metallic", 0.0)))
	m.set_shader_parameter("emission_color", opts.get("emission", Color(0, 0, 0)))
	m.set_shader_parameter("emission_energy", float(opts.get("emission_energy", 0.0)))
	m.set_shader_parameter("lite", lite)
	m.set_meta("set_id", set_id)
	_material_cache[key] = m
	return m


## Every material made so far (the quality switch restyles them).
static func all_materials() -> Array:
	return _material_cache.values()


## A preset switch: every material made so far takes the lighter path or
## leaves it; leaving it loads the roughness and AO maps the lite path never
## read.
static func set_lite(on: bool) -> void:
	if on == lite:
		return
	lite = on
	_maps_cache.clear()
	for m: ShaderMaterial in _material_cache.values():
		var maps := set_maps(String(m.get_meta("set_id", "")))
		m.set_shader_parameter("rough_tex", maps.get("rough"))
		m.set_shader_parameter("ao_tex", maps.get("ao"))
		m.set_shader_parameter("lite", lite)


static func clear_cache() -> void:
	_maps_cache.clear()
	_material_cache.clear()
