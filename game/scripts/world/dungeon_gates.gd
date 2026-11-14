extends Node3D
class_name DungeonGates

## The gates of the dungeon copy the player is in (RealmSession.gates: id,
## world centre, box size, open at the predicted tick), each drawn as the old
## greybox's portcullis: iron bars across the opening and three cross straps.
## An opening gate lifts smoothly into the arch and is hidden once up; a
## closing one drops back quickly. The collision is the server's (and the
## prediction's); this only shows it.

const BAR_SPACING := 0.45
const BAR_RADIUS := 0.06
## Seconds a gate takes to rise, and to fall.
const RISE_S := 1.2
const FALL_S := 0.35

var _iron: StandardMaterial3D
## id -> {node, size, lift (0 down .. 1 up), open}
var _gates: Dictionary = {}

func _init() -> void:
	name = "DungeonGates"
	_iron = StandardMaterial3D.new()
	_iron.albedo_color = Color(0.16, 0.15, 0.15)
	_iron.roughness = 0.5
	_iron.metallic = 0.6

## How many gates are drawn, and how many of them stand closed (down).
func count() -> int:
	return _gates.size()

func closed_count() -> int:
	return _gates.values().filter(func(g): return not bool(g["open"])).size()

## The ids of the gates down now.
func closed_ids() -> Array:
	return _gates.keys().filter(func(id): return not bool(_gates[id]["open"]))

## This frame's gates from the session; lifts move toward open or shut.
func sync(gates: Array, delta: float) -> void:
	for gate: Dictionary in gates:
		var id := String(gate.get("id", ""))
		if not _gates.has(id):
			var open := bool(gate.get("open", false))
			_gates[id] = {"node": _build(id, gate.get("size", Vector3(4, 4, 0.4))), "size": gate.get("size", Vector3(4, 4, 0.4)),
				"lift": 1.0 if open else 0.0, "open": open}
		var g: Dictionary = _gates[id]
		g["open"] = bool(gate.get("open", false))
		var step := delta / (RISE_S if g["open"] else -FALL_S)
		g["lift"] = clampf(float(g["lift"]) + step, 0.0, 1.0)
		var node: Node3D = g["node"]
		var size: Vector3 = g["size"]
		var eased := smoothstep(0.0, 1.0, float(g["lift"]))
		node.position = (gate.get("center", Vector3.ZERO) as Vector3) + Vector3(0, size.y * 0.95 * eased, 0)
		node.visible = float(g["lift"]) < 1.0

## A portcullis for a gate of box `size` (centred on its node): bars across
## the wider horizontal side, straps at three heights.
func _build(id: String, size: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Gate_" + id
	add_child(root)
	var across_z := size.z > size.x
	var width := size.z if across_z else size.x
	if across_z:
		root.rotation.y = PI * 0.5
	var bars := maxi(1, int(width / BAR_SPACING))
	for i in range(bars + 1):
		var bar := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = BAR_RADIUS
		cyl.bottom_radius = BAR_RADIUS
		cyl.height = size.y
		cyl.radial_segments = 8
		bar.mesh = cyl
		bar.material_override = _iron
		bar.position = Vector3(-width * 0.5 + i * width / bars, 0, 0)
		root.add_child(bar)
	for y in [-size.y * 0.3, 0.0, size.y * 0.3]:
		var strap := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(width + 0.1, 0.16, 0.12)
		strap.mesh = bm
		strap.material_override = _iron
		strap.position = Vector3(0, y, 0)
		root.add_child(strap)
	return root
