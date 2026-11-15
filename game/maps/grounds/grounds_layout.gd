extends RefCounted

## The grounds design as the scenery reads it: assets/terrain/grounds/layout.json
## (landmarks, roads, regions, lake), the same file the old world's terrain and
## every building placement came from, and the ground height from the
## Terrain3D data. The server's map pack was compiled from the old world built
## out of these very files, so a building placed here stands on the pack's
## collider for it.

const PATH := "res://assets/terrain/grounds/layout.json"

static var _data: Dictionary = {}
## The grounds' Terrain3D (set by GroundsMap before anything is built).
static var terrain: Node = null


static func data() -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		_data = parsed if parsed is Dictionary else {}
	return _data


## Ground height at (x, z) from the terrain data (NAN outside it or with no
## terrain loaded): the surface the old world's collision was built from.
static func height_at(x: float, z: float) -> float:
	if terrain == null or not is_instance_valid(terrain):
		return NAN
	var d: Variant = terrain.get("data")
	if d == null:
		return NAN
	return float(d.call("get_surface_height", Vector3(x, 0.0, z)))


## Landmark position on the ground (x, ground y, z); Vector3.INF if unknown.
static func landmark(id: String) -> Vector3:
	for l: Dictionary in data().get("landmarks", []):
		if String(l.get("id", "")) == id:
			var p: Array = l["pos"]
			return ground(float(p[0]), float(p[1]))
	return Vector3.INF


## Point on the ground at (x, z); y = 0 if the terrain is not loaded.
static func ground(x: float, z: float) -> Vector3:
	var h := height_at(x, z)
	return Vector3(x, 0.0 if is_nan(h) else h, z)


static func road(id: String) -> Dictionary:
	for r: Dictionary in data().get("roads", []):
		if String(r.get("id", "")) == id:
			return r
	return {}


static func roads() -> Array:
	return data().get("roads", [])


## Distance on the XZ plane from p to the nearest road's verge.
static func road_distance(p: Vector2) -> float:
	var best := INF
	for r: Dictionary in roads():
		var pts: Array = r["points"]
		for i in pts.size() - 1:
			var a := Vector2(pts[i][0], pts[i][1])
			var b := Vector2(pts[i + 1][0], pts[i + 1][1])
			best = minf(best, Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) - float(r.get("width", 4.0)) * 0.5)
	return best


## Height range (min, max) of the ground over a rotated rectangle.
static func ground_span(center: Vector2, size: Vector2, rot_y: float = 0.0) -> Vector2:
	var lo := INF
	var hi := -INF
	var b := Basis(Vector3.UP, rot_y)
	for i in 4:
		for j in 4:
			var o := b * Vector3((i / 3.0 - 0.5) * size.x, 0, (j / 3.0 - 0.5) * size.y)
			var h := height_at(center.x + o.x, center.y + o.z)
			if is_nan(h):
				continue
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return Vector2(lo, hi) if lo != INF else Vector2.ZERO
