extends Terrain3D

## The grounds' terrain (Terrain3D, 2 x 2 km, 1 m cells, lake surface y = 0):
## the old world's heightfield and painted control map, the same data the
## server's map pack was compiled from, so the drawn ground is the ground the
## bodies stand on.
##
## View only: no Terrain3D collision (the server and the prediction collide
## with the pack; clicks pick through RealmSession.pick). Trees, bushes and
## rocks are drawn by the Terrain3D instancer from the baked instance files,
## one mesh slot per variant (the slot's name is the variant), and past their
## LOD1 by GroundsImpostors' 256 m tiles (the exact handover: the band starts
## where Terrain3D's LOD1 ends, on every preset).

const Scatter := preload("res://maps/grounds/grounds_scatter.gd")
const Impostors := preload("res://maps/grounds/grounds_impostors.gd")

## The render layer (1-based) of the ground and its vegetation: the pitch's
## chalk decal paints this layer only.
const RENDER_LAYER := 18
const RENDER_BIT := 1 << (RENDER_LAYER - 1)
const ASSETS := "res://assets/terrain/grounds_assets.tres"
const MATERIAL := "res://assets/terrain/grounds_material.tres"

## Foliage density the instances were added with (-1: none added yet).
var _vegetation_density := -1.0
## The trees' far band (null until the vegetation is planted).
var _impostors: Node3D


func _init() -> void:
	# Both resources must be saved files: Terrain3D reloads its resources by
	# path, and an in-memory one makes it load an empty path (an error).
	material = load(MATERIAL)
	assets = load(ASSETS)
	# The ground draws on its own layer; the vegetation joins it.
	render_layers = (render_layers & ~1) | RENDER_BIT


func _ready() -> void:
	collision.mode = Terrain3DCollision.DISABLED


## Quality preset (GroundsQuality): terrain clipmap size, how far every
## vegetation LOD reaches, which LODs cast shadows, and how much of the small
## stuff is drawn; then the vegetation is planted. The catalogue's LOD
## distances are kept in metadata, so presets never compound.
func plant(preset: Dictionary) -> void:
	var size := int(preset.get("terrain_mesh_size", mesh_size))
	if size != mesh_size:
		mesh_size = size
	# The mesh assets are set up before any instance is added: the instancer
	# must not see a mesh asset change under live instances.
	_set_assets(assets, _asset_plan(assets, preset))
	_add_vegetation(float(preset.get("foliage_density", 1.0)))
	if _impostors == null:
		_impostors = Impostors.build(RENDER_BIT)
		if _impostors != null:
			add_child(_impostors)
	if _impostors != null:
		_impostors.set_ranges(assets, preset)


## Every variant's baked instances, thinned by `density` for the small stuff.
func _add_vegetation(density: float) -> void:
	for i in assets.get_mesh_count():
		var asset := assets.get_mesh_asset(i)
		if asset == null or asset.name == "":
			continue
		var data := Scatter.instances(asset.name)
		var thin := density < 1.0 and _is_thinned(asset.name)
		var xforms: Array[Transform3D] = []
		for k in data.size() / 5:
			if thin and float(k % 100) / 100.0 >= density:
				continue
			xforms.append(Scatter.transform_of(data, k))
		if not xforms.is_empty():
			instancer.add_transforms(i, xforms, PackedColorArray(), true)
	_vegetation_density = density


## What every mesh asset of `list` should be under `preset`: one entry per
## asset ({} for an empty slot).
static func _asset_plan(list: Terrain3DAssets, preset: Dictionary) -> Array:
	var lod_scale := float(preset.get("vegetation_lod_scale", 1.0))
	var far_scale := float(preset.get("vegetation_far_scale", lod_scale))
	var shadow_lod := int(preset.get("vegetation_shadow_lod", 1))
	var small_shadows := bool(preset.get("small_plant_shadows", true))
	var wanted: Array = []
	for i in list.get_mesh_count():
		var asset := list.get_mesh_asset(i)
		if asset == null:
			wanted.append({})
			continue
		if not asset.has_meta("base_ranges"):
			var base: Array = []
			for l in asset.get_lod_count():
				base.append(asset.get_lod_range(l))
			asset.set_meta("base_ranges", base)
		var base_ranges: Array = asset.get_meta("base_ranges")
		# A tree's far band is the impostors' (they scale their own far range):
		# its Terrain3D LOD1 is the last LOD but keeps the near-LOD scale.
		var banded: bool = Impostors.has_variant(asset.name)
		var ranges: Array = []
		for l in base_ranges.size():
			ranges.append(float(base_ranges[l]) * (far_scale if l == asset.last_lod and not banded else lod_scale))
		# One shadow mesh at every distance: LOD0 cast its own detailed shadow
		# and LOD1 a different one, so a tree's shadow changed shape as the
		# camera came near. The shadow impostor draws the shadow LOD's mesh
		# under the nearer LODs too.
		var shadow_mesh := mini(shadow_lod, asset.last_lod)
		var entry := {"ranges": ranges, "shadow_lod": shadow_mesh, "impostor": shadow_mesh, "cast": -1}
		if _is_small_plant(asset.name):
			entry["cast"] = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if small_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wanted.append(entry)
	return wanted


## Applies an _asset_plan. Each asset's signals are blocked while it changes:
## Terrain3D answers every LOD / shadow setter by rendering a 512 px thumbnail
## of the mesh and updating its multimeshes (~1.4 s for one preset's worth of
## setters on the old client's world entry).
static func _set_assets(list: Terrain3DAssets, wanted: Array) -> void:
	for i in wanted.size():
		var entry: Dictionary = wanted[i]
		if entry.is_empty():
			continue
		var asset := list.get_mesh_asset(i)
		asset.set_block_signals(true)
		asset.visibility_layers = RENDER_BIT
		var ranges: Array = entry["ranges"]
		for l in ranges.size():
			asset.set_lod_range(l, float(ranges[l]))
		asset.last_shadow_lod = int(entry["shadow_lod"])
		asset.shadow_impostor = int(entry["impostor"])
		if int(entry["cast"]) >= 0:
			asset.cast_shadows = int(entry["cast"])
		asset.set_block_signals(false)


static func _is_small_plant(variant: String) -> bool:
	return variant.begins_with("fern") or variant == "shrub"


## The small stuff the preset's foliage density thins out.
static func _is_thinned(variant: String) -> bool:
	return _is_small_plant(variant) or variant.begins_with("rock_moss")
