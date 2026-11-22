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
##
## Only the cells near the camera are planted. Terrain3D gives every 32 m cell
## one RenderingServer instance + multimesh per mesh and LOD (and one for the
## shadow impostor): ~31k of them for the whole 2 km, ~340 MB of process
## memory on the Intel iGPU (2026-11-15), while only the few hundred within
## their last LOD's visibility range can ever draw. The baked instances stay
## in `_cells`; `_stream` writes the cells within a mesh's reach (its last
## LOD range + fade margin + STREAM_SLACK) into the regions' instance
## dictionaries and empties those past reach + STREAM_KEEP, so the drawn
## vegetation is what planting every cell drew.

const Scatter := preload("res://maps/grounds/grounds_scatter.gd")
const Impostors := preload("res://maps/grounds/grounds_impostors.gd")
const Mats := preload("res://maps/grounds/grounds_mats.gd")

## The render layer (1-based) of the ground and its vegetation: the pitch's
## chalk decal paints this layer only.
const RENDER_LAYER := 18
const RENDER_BIT := 1 << (RENDER_LAYER - 1)
const ASSETS := "res://assets/terrain/grounds_assets.tres"
const MATERIAL := "res://assets/terrain/grounds_material.tres"

## Terrain3DInstancer::CELL_SIZE (pixels; the grounds' vertex spacing is 1 m).
const CELL := 32
## A cell is planted this far past its mesh's reach (the drawn distance is
## measured to the cell's AABB centre, which can overhang the cell a little).
const STREAM_SLACK := 24.0
## ... and emptied only this much farther still (no plant/empty flicker).
const STREAM_KEEP := 32.0
## The planted sets are recomputed when the camera has moved this far.
const STREAM_STEP := 8.0

## Foliage density the instances were added with (-1: none added yet).
var _vegetation_density := -1.0
## mesh id -> {global cell Vector2i: [region location, local cell,
## Array[Transform3D] (region space), PackedColorArray]}
var _cells := {}
## global cell -> the mesh ids with instances in it
var _cell_meshes := {}
## mesh id -> {global cell: true} planted now
var _planted := {}
## mesh id -> metres from the camera within which a cell is planted
var _reach := {}
## where the planted sets were last computed (INF: never)
var _focus := Vector3.INF
## cells emptied in the regions, erased once Terrain3D has freed their
## multimeshes: [frame, region location, mesh id, local cell]
var _emptied: Array = []
## The trees' far band (null until the vegetation is planted).
var _impostors: Node3D


func _init() -> void:
	# Both resources must be saved files: Terrain3D reloads its resources by
	# path, and an in-memory one makes it load an empty path (an error).
	material = load(MATERIAL)
	assets = load(ASSETS)
	RenderCompat.clean_terrain_assets(assets)
	# The ground draws on its own layer; the vegetation joins it.
	render_layers = (render_layers & ~1) | RENDER_BIT


func _ready() -> void:
	collision.mode = Terrain3DCollision.DISABLED
	# _stream follows the camera where it is drawn from: after every script
	# that places it this frame (the player's rig, a check's survey camera).
	process_priority = 1000


## Quality preset (QualityPreset, through GroundsMap.apply_quality): terrain
## clipmap size, how far every vegetation LOD reaches, which LODs cast shadows,
## and how much of the small stuff is drawn; the first call plants the
## vegetation. The catalogue's LOD distances are kept in metadata, so presets
## never compound.
func plant(preset: Dictionary) -> void:
	var size := int(preset.get("terrain_mesh_size", mesh_size))
	if size != mesh_size:
		mesh_size = size
	var density := float(preset.get("foliage_density", 1.0))
	var plan := _asset_plan(assets, preset)
	if _vegetation_density < 0.0:
		# The mesh assets are set up before any instance is added: the
		# instancer must not see a mesh asset change under live instances.
		_set_assets(assets, plan)
		_plain_leaves(assets)
		_add_vegetation(density)
	else:
		# A preset switch. Only the thinned small stuff is cleared and added
		# back (its instance count follows the density); every other mesh
		# keeps its multimeshes and the instancer just restyles them (LOD
		# ranges, shadows). Clearing and re-adding all ~100k instances was a
		# ~200 ms call and a ~650 ms frame on every switch (the old client,
		# Intel iGPU).
		var thinned: Array = []
		if not is_equal_approx(density, _vegetation_density):
			for i in assets.get_mesh_count():
				var asset := assets.get_mesh_asset(i)
				if asset != null and _is_thinned(asset.name):
					thinned.append(i)
					instancer.clear_by_mesh(i)
					_planted.erase(i)
		for i: int in _set_assets(assets, plan):
			if not thinned.has(i):
				instancer.update_mmis(i)
		if not thinned.is_empty():
			_add_vegetation(density, thinned)
	_set_reach()
	_focus = Vector3.INF
	_stream()
	if _impostors == null:
		_impostors = Impostors.build(RENDER_BIT)
		if _impostors != null:
			add_child(_impostors)
	if _impostors != null:
		_impostors.set_ranges(assets, preset)


## Every variant's baked instances, thinned by `density` for the small stuff,
## sorted into `_cells` the way Terrain3DInstancer.add_transforms places them
## (height offset applied, region space, 32 px cells); `only` limits it to
## those mesh ids (a preset switch). `_stream` plants them.
func _add_vegetation(density: float, only: Array = []) -> void:
	var span := float(region_size) * vertex_spacing
	var size := CELL * vertex_spacing
	for i in assets.get_mesh_count():
		var asset := assets.get_mesh_asset(i)
		if asset == null or asset.name == "":
			continue
		if not only.is_empty() and not only.has(i):
			continue
		var raw := Scatter.instances(asset.name)
		var thin := density < 1.0 and _is_thinned(asset.name)
		var lift := asset.height_offset
		var table := {}
		for k in raw.size() / 5:
			if thin and float(k % 100) / 100.0 >= density:
				continue
			var xform := Scatter.transform_of(raw, k)
			xform.origin += xform.basis.y * lift
			if not data.has_regionp(xform.origin):
				continue
			var global := Vector2i(floori(xform.origin.x / size), floori(xform.origin.z / size))
			if not table.has(global):
				var region := data.get_region_location(xform.origin)
				var offset := Vector3(region.x * span, 0.0, region.y * span)
				var none: Array[Transform3D] = []
				table[global] = [region, data.world_to_pixelv(xform.origin - offset) / CELL, none, PackedColorArray(), offset]
				var ids: PackedInt32Array = _cell_meshes.get(global, PackedInt32Array())
				if not ids.has(i):
					ids.append(i)
					_cell_meshes[global] = ids
			var cell: Array = table[global]
			xform.origin -= cell[4]
			var xforms: Array[Transform3D] = cell[2]
			xforms.append(xform)
			var colors: PackedColorArray = cell[3]
			colors.append(Color.WHITE)
			cell[3] = colors
		_cells[i] = table
	_vegetation_density = density


## How far from the camera each mesh's cells are planted: its last LOD's
## range plus the fade margin Terrain3D adds to it, plus STREAM_SLACK.
func _set_reach() -> void:
	_reach.clear()
	for i: int in _cells:
		var asset := assets.get_mesh_asset(i)
		if asset != null:
			_reach[i] = asset.get_lod_range(asset.last_lod) + asset.fade_margin + STREAM_SLACK


func _process(_delta: float) -> void:
	if not _emptied.is_empty():
		_erase_emptied()
	_stream()


## Plants the cells that came within reach of the camera and empties the
## ones that left it; Terrain3D builds and frees their multimeshes before the
## frame draws (update_mmis queues to RenderingServer.frame_pre_draw).
func _stream() -> void:
	if _cells.is_empty() or not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var at := camera.global_position
	if _focus.is_finite() and Vector2(at.x - _focus.x, at.z - _focus.z).length() < STREAM_STEP:
		return
	_focus = at
	var size := CELL * vertex_spacing
	var touched := {}
	for i: int in _planted:
		var keep: float = float(_reach.get(i, 0.0)) + STREAM_KEEP
		var planted: Dictionary = _planted[i]
		for global: Vector2i in planted.keys():
			if _cell_distance(global, at, size) > keep:
				planted.erase(global)
				touched[_write_cell(i, global, false)] = true
	var widest := 0.0
	for i: int in _reach:
		widest = maxf(widest, float(_reach[i]))
	var steps := ceili(widest / size) + 1
	var centre := Vector2i(floori(at.x / size), floori(at.z / size))
	for dz in range(-steps, steps + 1):
		for dx in range(-steps, steps + 1):
			var global := centre + Vector2i(dx, dz)
			if not _cell_meshes.has(global):
				continue
			var dist := _cell_distance(global, at, size)
			for i: int in _cell_meshes[global]:
				if dist > float(_reach.get(i, -1.0)) or not (_cells[i] as Dictionary).has(global):
					continue
				if not _planted.has(i):
					_planted[i] = {}
				var planted: Dictionary = _planted[i]
				if planted.has(global):
					continue
				planted[global] = true
				touched[_write_cell(i, global, true)] = true
	for key: Vector3i in touched:
		instancer.update_mmis(key.x, Vector2i(key.y, key.z), false)


## Horizontal distance from `at` to the cell's square (0 inside it).
static func _cell_distance(global: Vector2i, at: Vector3, size: float) -> float:
	var x0 := global.x * size
	var z0 := global.y * size
	var dx := maxf(maxf(x0 - at.x, at.x - (x0 + size)), 0.0)
	var dz := maxf(maxf(z0 - at.z, at.z - (z0 + size)), 0.0)
	return Vector2(dx, dz).length()


## Puts one cell's instances into its region's instance dictionary (the
## [transforms, colours, modified] triple Terrain3D keeps), or empties it
## there; an emptied cell is erased once Terrain3D has freed its multimeshes.
## Returns (mesh, region x, region y) for the update.
func _write_cell(mesh: int, global: Vector2i, plant_it: bool) -> Vector3i:
	var cell: Array = _cells[mesh][global]
	var region_loc: Vector2i = cell[0]
	var region := data.get_region(region_loc)
	if region != null:
		var all: Dictionary = region.get_instances()
		var cells: Dictionary = all.get(mesh, {})
		if plant_it:
			cells[cell[1]] = [cell[2], cell[3], true]
		else:
			var none: Array[Transform3D] = []
			cells[cell[1]] = [none, PackedColorArray(), false]
			_emptied.append([Engine.get_process_frames() + 1, region_loc, mesh, cell[1]])
		all[mesh] = cells
	return Vector3i(mesh, region_loc.x, region_loc.y)


## Drops the emptied cells Terrain3D has seen (their multimeshes are freed),
## unless they were planted again meanwhile.
func _erase_emptied() -> void:
	var now := Engine.get_process_frames()
	var left: Array = []
	for entry: Array in _emptied:
		if int(entry[0]) >= now:
			left.append(entry)
			continue
		var region := data.get_region(entry[1])
		if region == null:
			continue
		var cells: Dictionary = region.get_instances().get(entry[2], {})
		var triple: Array = cells.get(entry[3], [])
		if triple.size() == 3 and (triple[0] as Array).is_empty():
			cells.erase(entry[3])
	_emptied = left


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


## Applies an _asset_plan and returns the ids of the meshes it changed. Each
## asset's signals are blocked while it changes: Terrain3D answers every LOD /
## shadow setter by rendering a 512 px thumbnail of the mesh and updating its
## multimeshes (~1.4 s for one preset's worth of setters on the old client's
## world entry). The caller updates the multimeshes once (a switch), or adds
## the instances afterwards.
static func _set_assets(list: Terrain3DAssets, wanted: Array) -> Array:
	var changed: Array = []
	for i in wanted.size():
		var entry: Dictionary = wanted[i]
		if entry.is_empty():
			continue
		var asset := list.get_mesh_asset(i)
		var before := _asset_state(asset)
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
		if _asset_state(asset) != before:
			changed.append(i)
	return changed


## Every vegetation mesh's leaves on a plain alpha scissor instead of
## alpha-to-coverage, before their first draw: the sun's shadow pass drew the
## coverage from an undefined alpha and the tree shadows flickered as the
## camera moved (GroundsMats.plain_alpha_scissor).
static func _plain_leaves(list: Terrain3DAssets) -> void:
	for i in list.get_mesh_count():
		var asset := list.get_mesh_asset(i)
		if asset == null:
			continue
		for lod in asset.get_lod_count():
			Mats.plain_alpha_scissor(asset.get_mesh(lod))


static func _asset_state(asset: Terrain3DMeshAsset) -> Array:
	var state: Array = [asset.visibility_layers, asset.last_shadow_lod, asset.shadow_impostor, asset.cast_shadows]
	for l in asset.get_lod_count():
		state.append(asset.get_lod_range(l))
	return state


static func _is_small_plant(variant: String) -> bool:
	return variant.begins_with("fern") or variant == "shrub"


## The small stuff the preset's foliage density thins out: ferns and shrubs
## only. Every mossy rock is an obstacle in the server's pack (map_solids.gd
## boxes each one, world/patches/grounds.json), so a thinned-out rock was a
## solid nobody could see (the low preset dropped half of them: 1206 bodies
## stood on air, 2026-11-16). placement_check.gd checks every obstacle's
## instance is planted on the preset.
static func _is_thinned(variant: String) -> bool:
	return _is_small_plant(variant)
