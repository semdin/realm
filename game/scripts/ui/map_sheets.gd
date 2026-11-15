extends RefCounted
class_name MapSheets

## The painted map sheets the minimap and the world map draw: painted once
## per map (per storey in the castle) by RealmSession.map_image_start on a
## worker thread from the map pack the session already holds - the terrain,
## the water, the colliders and the walkable mesh - mipmaps included, and
## kept for as long as the player stays on that map. The frame only pays
## for the texture's upload when it is handed over.
##
## A sheet is a picture, not a camera: the old minimap rendered the world
## again through an orthographic camera (a second pass over the whole scene,
## ~2 ms a frame on the Intel iGPU even at 10 Hz). Here the disc and the
## window only draw a texture, so an open map costs next to nothing.
##
##   grounds          "terrain", 1 px per metre (the old world map's 2048 px)
##   spider_caverns   "cave", 2 px per metre, every floor
##   castle_interior  "plan", one sheet per storey, 4 px per metre
##   a dungeon copy   "plan", its walkable floor, 4 px per metre

const CASTLE_RECT := Rect2(-118.0, -98.0, 222.0, 222.0)
## Pixels per metre by style, and the most pixels a side may have.
const DENSITY := {"terrain": 1.0, "cave": 2.0, "plan": 4.0}
const MAX_PX := 2048

## key -> {texture, rect, style, ms (painting, on its thread), wait_ms (asked
## to handed over), upload_ms (the frame's share)}
static var _kept: Dictionary = {}
## key -> {job, started}
static var _jobs: Dictionary = {}
static var _kept_map := ""
static var _session_id := 0
## The newest sheet handed over (the check reports it).
static var last: Dictionary = {}

## The sheet of the map the session plays (`level`: the castle storey), or
## {} while it is still being painted (ask again next frame).
static func sheet(session: Node, map_id: String, level: int = 0) -> Dictionary:
	if session == null:
		return {}
	if _session_id != session.get_instance_id():
		# another session (a trip rebuilt the scene): its jobs are not ours
		_session_id = session.get_instance_id()
		_jobs.clear()
	if _kept_map != map_id:
		# a sheet of another map is no use any more: its memory goes
		_kept.clear()
		_jobs.clear()
		_kept_map = map_id
	var offset: Vector3 = session.copy_offset()
	var plan := map_id == "castle_interior"
	var key := "%s|%d|%s" % [map_id, level if plan else 0, str(offset)]
	if _kept.has(key):
		return _kept[key]
	if _jobs.has(key):
		return _collect(session, key)
	var style := style_of(map_id)
	var rect: Rect2
	var lo := -100000.0
	var hi := 100000.0
	if plan:
		rect = Rect2(CASTLE_RECT.position + Vector2(offset.x, offset.z), CASTLE_RECT.size)
		lo = MapPlaces.storey_y(level) + offset.y
		hi = lo + MapPlaces.STOREY
	else:
		rect = session.map_bounds()
		if rect.size.x <= 0.0:
			return {}
		# square, a little margin round a small map
		var side := maxf(rect.size.x, rect.size.y)
		if style == "plan":
			side += 24.0
		rect = Rect2(rect.get_center() - Vector2(side, side) * 0.5, Vector2(side, side))
	var px := clampi(roundi(rect.size.x * float(DENSITY[style])), 256, MAX_PX)
	var job: int = session.map_image_start(rect, px, lo, hi, style)
	if job > 0:
		_jobs[key] = {"job": job, "started": Time.get_ticks_usec(), "rect": rect, "style": style}
	return {}

static func _collect(session: Node, key: String) -> Dictionary:
	var pending: Dictionary = _jobs[key]
	var started := Time.get_ticks_usec()
	var image: Image = session.map_image_take(int(pending["job"]))
	if image == null:
		if not session.map_image_pending(int(pending["job"])):
			_jobs.erase(key)   # it failed: the next ask paints it again
		return {}
	var entry := {"texture": ImageTexture.create_from_image(image), "rect": pending["rect"], "style": pending["style"],
		"ms": float(session.map_image_ms()), "wait_ms": (started - int(pending["started"])) / 1000.0,
		"upload_ms": (Time.get_ticks_usec() - started) / 1000.0}
	_jobs.erase(key)
	_kept[key] = entry
	last = entry
	return entry

static func style_of(map_id: String) -> String:
	match map_id:
		"grounds":
			return "terrain"
		"spider_caverns":
			return "cave"
	return "plan"

## World (x, z) -> the sheet's UV.
static func to_uv(entry: Dictionary, at: Vector2) -> Vector2:
	var rect: Rect2 = entry["rect"]
	return (at - rect.position) / rect.size
