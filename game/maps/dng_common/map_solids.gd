extends SceneTree

## Builds the drawn caverns and dungeon maps headless and prints what each
## built; with `--write <patches dir>` it writes every map's drawn solids
## that the old game gave no collider (the views' `solids`) as
## <dir>/<map>.json, the collider patch format of realm_worldc
## (crates/realm_worldc/src/patch.rs), then `realm_worldc patch` adds them to
## the packs:
##
##   godot --headless --path game -s res://maps/dng_common/map_solids.gd -- --write ../world/patches
##   ./build/lead_target/release/realm_worldc patch world/maps content/data
##
## The caverns' big stalagmite spires (the view's `spires`) are boxed here
## from the stalag mesh, as `obstacle` boxes stacked inside the drawn rock;
## a dungeon's stalagmites (the view's `stalagmites`, the Web Mother's lair)
## the same way, as ordinary colliders.
##
## The grounds are not built: their solids are the Terrain3D instancer's
## trees and big rocks, read from the baked instances the view plants
## (assets/terrain/grounds/scatter, GroundsScatter; the far-tree impostors
## are the same instances) and sized from each model's own mesh. They are
## `obstacle` boxes: solid to bodies and cut out of the navmesh, but not
## ground for what the server places from the sky.
##
## A trunk gets a box around its lowest TRUNK_TOP metres, inside the drawn
## trunk at every height of that band (the trunk mesh's cross-sections; the
## box's corners touch the bark at the narrowest one); a trunk leaning out of
## one box gets two or three stacked. A rock gets one box inside its drawn shape (its
## top surface rasterized: the largest rectangle that stays under the surface
## at the box's top), when the rock is at least ROCK_MIN metres across and the
## box rises higher than a body steps (ROCK_MIN_TOP). Bushes, ferns, stumps,
## logs and grass stay walk-through.

const MAPS := ["spider_caverns", "dng_trial", "dng_sealed_wing", "dng_spider_lair"]

const Scatter = preload("res://maps/grounds/grounds_scatter.gd")
const DungeonView = preload("res://maps/dng_common/dungeon_view.gd")
const STALAG := "res://assets/models/caverns/cavern_stalag.glb"
## The spires' bands (fractions of the stalag mesh's height): the broad foot,
## the flank, the spire's body, its upper body; the thin tip stays open.
const SPIRE_BANDS := [[0.0, 0.12], [0.12, 0.3], [0.3, 0.5], [0.5, 0.7]]
const SPIRE_CELLS := 72
const VEG := "res://assets/terrain/vegetation/%s_%s.res"
const TREES := ["fir_a", "fir_b", "fir_c", "pine_a", "pine_b", "pine_c", "broadleaf_a", "broadleaf_b"]
const ROCKS := ["rock_boulder", "rock_slab", "rock_moss_a0", "rock_moss_a1", "rock_moss_a2",
	"rock_moss_b0", "rock_moss_b1", "rock_moss_b2"]
## World metres: the trunk band boxed (from under the ground to this high).
const TRUNK_TOP := 3.0
const TRUNK_SINK := 0.4
## Cross-sections every this many mesh metres; the band boxed starts here.
const SLICE := 0.15
## A trunk leaning so far that one box keeps less than this share of the
## narrowest section's inscribed radius is boxed in more parts.
const LEAN_SPLIT := 0.7
## The trunk's inside distance grid: this many points a side, reaching this
## far (mesh metres) from the trunk's axis at its foot.
const TRUNK_GRID := 41
const TRUNK_REACH := 0.4
## Rocks: smallest drawn size boxed, lowest box top over the rock's foot,
## how far the box reaches under the foot, the raster's cells per side.
const ROCK_MIN := 1.0
const ROCK_MIN_TOP := 0.5
const ROCK_SINK := 0.3
const ROCK_CELLS := 40
const ROCK_TOPS := [0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85]

var _done := false
var _raster: Dictionary = {}

## The views are built on the first frame, inside the tree (a skinned
## model's bounds follow its skeleton only there).
func _process(_delta: float) -> bool:
	if _done:
		return false
	_done = true
	_run()
	return false

func _run() -> void:
	# the content tables the views read (portals): the realm checkout's
	var content := ProjectSettings.globalize_path("res://").path_join("../content/data").simplify_path()
	if not ClassDB.class_call_static("RealmContent", "load", content):
		push_error("content/data could not be read")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var i := args.find("--write")
	var out_dir := args[i + 1] if i >= 0 and i + 1 < args.size() else ""
	if out_dir != "" and out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir).simplify_path()
	var failed := false
	for map in MAPS:
		var path := "res://maps/%s/%s.tscn" % [map, map]
		var view: Node3D = (load(path) as PackedScene).instantiate()
		root.add_child(view)
		view.call("build")
		var solids: Array = view.get("solids")
		var spires: Variant = view.get("spires")
		if spires is Array and not spires.is_empty():
			solids = solids + _spire_solids(spires)
		var stalagmites: Variant = view.get("stalagmites")
		if stalagmites is Array and not stalagmites.is_empty():
			solids = solids + _stalagmite_solids(stalagmites)
		print("map %s: %s" % [map, view.get("built_stats")])
		var obstacles := 0
		for s: Dictionary in solids:
			obstacles += 1 if s.get("obstacle", false) else 0
			print("  solid %s centre %s half %s yaw %s%s" % [s["note"], s["center"], s["half"], s["yaw_deg"],
				" (obstacle)" if s.get("obstacle", false) else ""])
		print("  %d boxes, %d of them obstacles" % [solids.size(), obstacles])
		if out_dir != "":
			var doc := {
				"_comment": ("Colliders for drawn solids the old %s gave no collider, recorded by the map's own view " +
					"(game/maps/%s; written by game/maps/dng_common/map_solids.gd --write). Pack coordinates " +
					"(a dungeon's copy-local ones). Applied by realm_worldc patch.") % [map, map],
				"boxes": solids,
			}
			failed = not _write(out_dir.path_join(map + ".json"), JSON.stringify(doc, "  ") + "\n", solids.size()) or failed
		view.queue_free()
	var grounds := _grounds_solids()
	if out_dir != "":
		# One box a line: some twenty thousand of them.
		var lines := PackedStringArray()
		for b: Dictionary in grounds:
			lines.append("    " + JSON.stringify(b))
		var text := "{\n  \"_comment\": %s,\n  \"boxes\": [\n%s\n  ]\n}\n" % [JSON.stringify(
			"Obstacles for the grounds' trees and big rocks (the Terrain3D instancer's baked instances, " +
			"assets/terrain/grounds/scatter), sized from each model's mesh by game/maps/dng_common/map_solids.gd " +
			"--write. Trunks boxed over their lowest 3 m inside the drawn bark, rocks inside their drawn shape. " +
			"Solid to bodies, cut out of the navmesh, not ground for placing from the sky. Applied by realm_worldc patch."),
			",\n".join(lines)]
		failed = not _write(out_dir.path_join("grounds.json"), text, grounds.size()) or failed
	quit(1 if failed else 0)

func _write(path: String, text: String, count: int) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write %s" % path)
		return false
	file.store_string(text)
	file.close()
	print("  wrote %d boxes to %s" % [count, path])
	return true

# ------------------------------------------------------------ cavern spires

## The caverns' big stalagmite spires (the view's `spires`: the baked stalag
## mesh placed) as obstacle boxes stacked by height band, each inside the
## drawn rock (DungeonView.raster_solids on the mesh's top surface).
func _spire_solids(spires: Array) -> Array:
	var raster := _stalag_raster()
	var out: Array = []
	for spire: Transform3D in spires:
		for b: Dictionary in DungeonView.raster_solids(raster, spire, SPIRE_BANDS,
				"stalagmite spire at %.0f, %.0f: drawn rock, no collider" % [spire.origin.x, spire.origin.z]):
			b["obstacle"] = true
			out.append(b)
	print("  %d spires -> %d obstacle boxes" % [spires.size(), out.size()])
	return out

## A dungeon's stalagmites (the view's `stalagmites`: the same stalag mesh
## placed) boxed the same way, as ordinary colliders: the dungeon director
## places its creatures at fixed spots, none on a stalagmite.
func _stalagmite_solids(stalagmites: Array) -> Array:
	var raster := _stalag_raster()
	var out: Array = []
	for s: Dictionary in stalagmites:
		out.append_array(DungeonView.raster_solids(raster, s["xform"], SPIRE_BANDS, String(s["note"])))
	print("  %d stalagmites -> %d boxes" % [stalagmites.size(), out.size()])
	return out

## The stalag mesh's top surface (DungeonView.top_raster), measured once.
func _stalag_raster() -> Dictionary:
	if _raster.is_empty():
		var scene: Node = (load(STALAG) as PackedScene).instantiate()
		var mesh: Mesh = (scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).mesh
		scene.free()
		_raster = DungeonView.top_raster(mesh, SPIRE_CELLS)
	return _raster

# ------------------------------------------------------------------ grounds

func _grounds_solids() -> Array:
	var out: Array = []
	var trees := 0
	for v: String in TREES:
		var profile := _trunk_profile(v)
		var data := Scatter.instances(v)
		var n := data.size() / 5
		var boxes := 0
		var narrowest := INF
		for k in n:
			var o := k * 5
			var made := _trunk_boxes(profile, Vector3(data[o], data[o + 1], data[o + 2]), data[o + 3], data[o + 4],
				"%s tree %d" % [v, k])
			for b: Dictionary in made:
				narrowest = minf(narrowest, float(b["half"][0]))
			boxes += made.size()
			out.append_array(made)
		trees += n
		var columns := PackedStringArray()
		for p: Array in _columns(profile, profile["ys"].size()):
			columns.append("%.2f-%.2f m r %.3f" % [float(profile["ys"][p[0]]), float(profile["ys"][p[1]]), float(p[3])])
		print("map grounds: %-12s %5d trees -> %5d trunk boxes (narrowest half %.2f m; mesh columns %s)" % [
			v, n, boxes, narrowest, ", ".join(columns)])
	var rocks := 0
	for v: String in ROCKS:
		var shape := _rock_shape(v)
		var data := Scatter.instances(v)
		var n := data.size() / 5
		var boxes := 0
		for k in n:
			var o := k * 5
			var b := _rock_box(shape, Vector3(data[o], data[o + 1], data[o + 2]), data[o + 3], data[o + 4],
				"%s rock %d" % [v, k])
			if not b.is_empty():
				out.append(b)
				boxes += 1
		rocks += boxes
		print("map grounds: %-12s %5d rocks -> %5d boxes (drawn %s)" % [v, n, boxes, shape["size"]])
	print("map grounds: %d trees, %d rocks boxed: %d obstacle boxes" % [trees, rocks, out.size()])
	return out

## A box dict in the patch format (yaw in radians, Godot's: Basis(UP, yaw)).
static func _box(note: String, center: Vector3, half: Vector3, yaw: float) -> Dictionary:
	return {"note": note,
		"center": [snappedf(center.x, 0.01), snappedf(center.y, 0.01), snappedf(center.z, 0.01)],
		"half": [snappedf(half.x, 0.01), snappedf(half.y, 0.01), snappedf(half.z, 0.01)],
		"yaw_deg": snappedf(rad_to_deg(yaw), 0.01), "obstacle": true}

## The tree's trunk as modelled: of its two near LODs the one whose trunk
## surfaces hold the most triangles (the cook once collapsed some LOD0
## trunks; they now carry LOD1's, so both measure the same), and those
## surfaces.
static func _trunk_mesh(variant: String) -> Array:
	var best: Array = []
	var most := 0
	for lod in ["lod0", "lod1"]:
		var mesh := load(VEG % [variant, lod]) as ArrayMesh
		var surfaces: Array = []
		var tris := 0
		for i in mesh.get_surface_count():
			var name := mesh.surface_get_name(i)
			if not (name.contains("leaves") or name.contains("branch") or name.contains("bark")
					or name.contains("impostor") or name.contains("dead")):
				surfaces.append(i)
				var arrays := mesh.surface_get_arrays(i)
				tris += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if arrays[Mesh.ARRAY_INDEX] != null 					else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		if tris > most:
			most = tris
			best = [mesh, surfaces, lod, tris]
	if not best.is_empty() and best[2] != "lod0":
		print("map grounds: %s: lod0's trunk is not whole, measured on %s's (%d triangles)" % [variant, best[2], best[3]])
	return best

## A tree's trunk measured (mesh space): its cross-sections every SLICE
## metres up to what the smallest instance's band needs, and each section's
## inside distance field (how far a point is from the section's edge, 0
## outside) on a grid around the trunk's axis at its foot:
## {ys, sections, points, fields, columns: {} (by section count, _columns)}.
static func _trunk_profile(variant: String) -> Dictionary:
	var found := _trunk_mesh(variant)
	var profile := {"ys": [], "sections": [], "points": PackedVector2Array(), "fields": [], "columns": {}}
	if found.is_empty():
		push_error("map_solids: %s has no trunk surface" % variant)
		return profile
	var mesh: ArrayMesh = found[0]
	var tris := PackedVector3Array()
	for i: int in found[1]:
		var arrays := mesh.surface_get_arrays(i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if index.is_empty():
			tris.append_array(verts)
		else:
			for j in index:
				tris.append(verts[j])
	var sections: Array = profile["sections"]
	var ys: Array = profile["ys"]
	var y := SLICE
	while y <= TRUNK_TOP / 0.6:
		var segs := PackedVector2Array()
		for k in range(0, tris.size() - 2, 3):
			var pts := PackedVector2Array()
			for e in 3:
				var a := tris[k + e]
				var b := tris[k + (e + 1) % 3]
				if (a.y - y) * (b.y - y) < 0.0:
					var f := (y - a.y) / (b.y - a.y)
					pts.append(Vector2(lerpf(a.x, b.x, f), lerpf(a.z, b.z, f)))
			if pts.size() == 2:
				segs.append(pts[0])
				segs.append(pts[1])
		if segs.size() >= 6:
			sections.append(segs)
			ys.append(y)
		y += SLICE
	if sections.is_empty():
		return profile
	# the grid: around the widest circle inside the section nearest 0.6 m up
	var foot: PackedVector2Array = sections[0]
	for k in sections.size():
		if absf(float(ys[k]) - 0.6) < absf(float(ys[sections.find(foot)]) - 0.6):
			foot = sections[k]
	var axis := _widest_inside(foot)
	var points: PackedVector2Array = profile["points"]
	var step := 2.0 * TRUNK_REACH / (TRUNK_GRID - 1)
	for i in TRUNK_GRID:
		for j in TRUNK_GRID:
			points.append(Vector2(axis.x - TRUNK_REACH + i * step, axis.y - TRUNK_REACH + j * step))
	profile["points"] = points
	# a section enclosing no point of the grid (an open skirt at the foot,
	# a fork) is left out: the column only has to fit the closed ones
	var kept: Array = []
	var kept_ys: Array = []
	for k in sections.size():
		var field := PackedFloat32Array()
		var most := 0.0
		for p in points:
			var d := _inside_distance(sections[k], p)
			field.append(d)
			most = maxf(most, d)
		if most > 0.0:
			profile["fields"].append(field)
			kept.append(sections[k])
			kept_ys.append(ys[k])
	profile["sections"] = kept
	profile["ys"] = kept_ys
	return profile

## The trunk's lowest `count` sections as up to three stacked upright
## columns, from the bottom up each as tall as one column keeps LEAN_SPLIT
## of each section's own radius around it (a straight trunk tapering is one
## column; a leaning one is cut): [[first, last, centre, radius]].
static func _columns(profile: Dictionary, count: int) -> Array:
	if profile["columns"].has(count):
		return profile["columns"][count]
	var fields: Array = profile["fields"]
	var points: PackedVector2Array = profile["points"]
	var sections: Array = profile["sections"]
	var parts: Array = []
	var first := 0
	while first < count and parts.size() < 3:
		var column: PackedFloat32Array = fields[first]
		var best := _peak(column)
		var last := first
		while last + 1 < count:
			var below: PackedFloat32Array = fields[last + 1]
			var next := column.duplicate()
			for k in next.size():
				next[k] = minf(next[k], below[k])
			# the next section's own radius near the column's axis
			var own := 0.0
			var near: float = column[best] + 0.05
			for k in below.size():
				if points[k].distance_to(points[best]) <= near:
					own = maxf(own, below[k])
			var peak := _peak(next)
			if next[peak] <= 0.0 or next[peak] < own * LEAN_SPLIT:
				break
			column = next
			best = peak
			last += 1
		# the grid's best point refined: a finer grid a cell around it
		var cell := 2.0 * TRUNK_REACH / (TRUNK_GRID - 1)
		var at := points[best]
		var radius: float = column[best]
		for i in 9:
			for j in 9:
				var p := points[best] + Vector2(i - 4, j - 4) * (cell / 4.0)
				var r := INF
				for k in range(first, last + 1):
					r = minf(r, _inside_distance(sections[k], p))
				if r > radius:
					radius = r
					at = p
		parts.append([first, last, at, radius])
		first = last + 1
	profile["columns"][count] = parts
	return parts

## Where a field is largest (its first such point).
static func _peak(field: PackedFloat32Array) -> int:
	var at := 0
	for k in field.size():
		if field[k] > field[at]:
			at = k
	return at

## The largest circle inside a cross-section (`segs`: its edges, two points
## each), as (x, z, radius): grid searches over the section's bounds for the
## inside point farthest from every edge, coarse then fine.
static func _widest_inside(segs: PackedVector2Array) -> Vector3:
	var lo := segs[0]
	var hi := segs[0]
	for p in segs:
		lo = lo.min(p)
		hi = hi.max(p)
	var best := Vector3(0, 0, 0)
	var span := hi - lo
	var origin := lo
	for pass_ in 2:
		var steps := 24
		for i in steps + 1:
			for j in steps + 1:
				var p := origin + Vector2(span.x * i / steps, span.y * j / steps)
				var r := _inside_distance(segs, p)
				if r > best.z:
					best = Vector3(p.x, p.y, r)
		# again around the best point, a cell either side
		span = span / steps * 2.0
		origin = Vector2(best.x, best.y) - span * 0.5
	return best

## How far `p` is from the nearest edge of the section, 0 when outside it:
## inside is enclosed, rays from `p` along both axes and both diagonals all
## meeting an edge (a scanned trunk's sections are not always closed loops,
## so no crossing parity).
static func _inside_distance(segs: PackedVector2Array, p: Vector2) -> float:
	var hits := 0
	var r := INF
	var q := Vector2(p.x + p.y, p.y - p.x)
	for k in range(0, segs.size(), 2):
		var a := segs[k]
		var b := segs[k + 1]
		r = minf(r, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
		if hits == 255:
			continue
		hits |= _ray_hits(a, b, p)
		hits |= _ray_hits(Vector2(a.x + a.y, a.y - a.x), Vector2(b.x + b.y, b.y - b.x), q) << 4
	return r if hits == 255 else 0.0

## Which of the four axis rays from `p` the segment a-b meets: bits +x, -x,
## +y, -y.
static func _ray_hits(a: Vector2, b: Vector2, p: Vector2) -> int:
	var out := 0
	if (a.y > p.y) != (b.y > p.y):
		var x := a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
		out |= 1 if x > p.x else 2
	if (a.x > p.x) != (b.x > p.x):
		var y := a.y + (p.x - a.x) / (b.x - a.x) * (b.y - a.y)
		out |= 4 if y > p.y else 8
	return out

## One tree's trunk boxes: the columns of the sections inside its band
## (world 0..TRUNK_TOP over its foot), the first reaching TRUNK_SINK under
## the foot, the last up to TRUNK_TOP. Each box is the square inside its
## column's circle (corners on the bark).
static func _trunk_boxes(profile: Dictionary, at: Vector3, yaw: float, s: float, note: String) -> Array:
	var ys: Array = profile["ys"]
	var count := 0
	while count < ys.size() and float(ys[count]) * s <= TRUNK_TOP:
		count += 1
	if count == 0:
		return []
	var parts := _columns(profile, count)
	var basis := Basis(Vector3.UP, yaw)
	var out: Array = []
	for k in parts.size():
		var p: Array = parts[k]
		var first: int = p[0]
		var last: int = p[1]
		var y0 := -TRUNK_SINK if k == 0 else (float(ys[first - 1]) + float(ys[first])) * 0.5 * s
		var y1 := TRUNK_TOP if last == count - 1 else (float(ys[last]) + float(ys[last + 1])) * 0.5 * s
		if last == count - 1 and first > 0 and y0 > TRUNK_TOP - 0.3:
			break
		var h := float(p[3]) * s / sqrt(2.0)
		if h < 0.03:
			continue
		var c: Vector2 = p[2]
		var centre := at + basis * Vector3(c.x * s, 0.0, c.y * s) + Vector3(0, (y0 + y1) * 0.5, 0)
		out.append(_box(note if parts.size() == 1 else "%s (part %d)" % [note, k + 1],
			centre, Vector3(h, (y1 - y0) * 0.5, h), yaw))
	return out

## A rock model's top surface rasterized over its footprint (mesh space,
## DungeonView.top_raster) and for each candidate top height the largest
## rectangle under it: {size, foot, tops: [[top, x0, x1, z0, z1]]}.
static func _rock_shape(variant: String) -> Dictionary:
	var mesh := load(VEG % [variant, "lod0"]) as ArrayMesh
	var raster := DungeonView.top_raster(mesh, ROCK_CELLS)
	var box: AABB = raster["box"]
	var tops: Array = []
	for f: float in ROCK_TOPS:
		var t := box.position.y + box.size.y * f
		var rect := DungeonView.raster_rect(raster, t)
		if not rect.is_empty():
			tops.append([t] + rect)
	return {"size": box.size, "foot": box.position.y, "tops": tops}

## One rock's box: of the shape's candidate tops the one boxing the most
## rock that still rises over a step; none for a small rock.
static func _rock_box(shape: Dictionary, at: Vector3, yaw: float, s: float, note: String) -> Dictionary:
	var size: Vector3 = shape["size"] * s
	if maxf(size.x, maxf(size.y, size.z)) < ROCK_MIN:
		return {}
	var foot: float = shape["foot"]
	var best: Array = []
	var volume := 0.0
	for c: Array in shape["tops"]:
		var rise := (float(c[0]) - foot) * s
		if rise < ROCK_MIN_TOP:
			continue
		var v := (float(c[2]) - float(c[1])) * (float(c[4]) - float(c[3])) * s * s * (rise + ROCK_SINK)
		if v > volume:
			volume = v
			best = c
	if best.is_empty():
		return {}
	var basis := Basis(Vector3.UP, yaw)
	var y0 := at.y + foot * s - ROCK_SINK
	var y1 := at.y + float(best[0]) * s
	var mid := Vector3((float(best[1]) + float(best[2])) * 0.5 * s, 0.0, (float(best[3]) + float(best[4])) * 0.5 * s)
	return _box(note, Vector3(at.x, (y0 + y1) * 0.5, at.z) + basis * mid,
		Vector3((float(best[2]) - float(best[1])) * 0.5 * s, (y1 - y0) * 0.5, (float(best[4]) - float(best[3])) * 0.5 * s), yaw)
