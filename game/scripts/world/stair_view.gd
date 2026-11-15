extends MultiMeshInstance3D
class_name StairView

## The castle's moving staircases, drawn (placeholder stone like the walls
## until the castle scene comes in Phase 6). The flights are simulated by
## the server and by the client core for prediction (realm_sim staircase.rs:
## a pure function of the tick); RealmSession.stair_parts gives every solid
## box of them as the player's own body sees it this frame - the deck, its
## two railings and the gates that are shut - and this draws each as a block,
## with treads on the deck so it reads as a stair, every frame. Nothing here
## collides: the core already does.

## Height of one drawn tread (metres); the walked surface is the deck's slope,
## the treads sit on it centred, half a tread above and below.
const TREAD := 0.2
const STONE := Color(0.62, 0.6, 0.56)
const TREAD_STONE := Color(0.68, 0.66, 0.61)
const RAIL := Color(0.5, 0.47, 0.43)
const GATE := Color(0.24, 0.23, 0.25)

var session: Node
## What was drawn last frame (the check reads them): boxes by kind, treads,
## and the decks' centres by flight.
var counts: Dictionary = {}
var treads := 0
var decks: Dictionary = {}
## Each flight's deck slab as drawn: [Transform3D, size].
var deck_boxes: Dictionary = {}

## A flight's walked surface ends as drawn now: [low, high] (the slab's top
## at each end), [] when it is not in view.
func deck_ends(flight: int) -> Array:
	if not deck_boxes.has(flight):
		return []
	var t: Transform3D = deck_boxes[flight][0]
	var size: Vector3 = deck_boxes[flight][1]
	var top := t.origin + t.basis.y.normalized() * size.y * 0.5
	var a := top - t.basis.z.normalized() * size.z * 0.5
	var b := top + t.basis.z.normalized() * size.z * 0.5
	return [a, b] if a.y <= b.y else [b, a]

func _ready() -> void:
	name = "Staircases"
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color.WHITE
	material.roughness = 0.9
	box.material = material
	multimesh.mesh = box

func _process(_delta: float) -> void:
	if session == null or String(session.status()) != "joined":
		return
	var parts: Array = session.stair_parts()
	var offset: Vector3 = session.copy_offset()
	var boxes: Array = []   # [Transform3D, Color]
	counts = {}
	treads = 0
	decks = {}
	deck_boxes = {}
	for part: Dictionary in parts:
		var kind := String(part["kind"])
		counts[kind] = int(counts.get(kind, 0)) + 1
		var t: Transform3D = part["transform"]
		t.origin += offset
		var size: Vector3 = part["size"]
		var colour := STONE
		match kind:
			"rail":
				colour = RAIL
			"gate":
				colour = GATE
			"deck":
				decks[int(part["flight"])] = t.origin
				deck_boxes[int(part["flight"])] = [t, size]
				_treads(t, size, boxes)
		boxes.append([Transform3D(_sized(t.basis, size), t.origin), colour])
	if multimesh.instance_count < boxes.size():
		multimesh.instance_count = boxes.size() + 32
	for i in boxes.size():
		multimesh.set_instance_transform(i, boxes[i][0])
		multimesh.set_instance_color(i, boxes[i][1])
	multimesh.visible_instance_count = boxes.size()

## Treads on a deck slab (`t` its centre and tilt, `size` its extents): level
## blocks from the low end to the high end, each top a quarter tread over
## the slope at its middle (the feet on the slope neither float nor sink far).
func _treads(t: Transform3D, size: Vector3, boxes: Array) -> void:
	var along := t.basis.z.normalized()
	var up := t.basis.y.normalized()
	var top := t.origin + up * size.y * 0.5
	var a := top - along * size.z * 0.5
	var b := top + along * size.z * 0.5
	var low := a if a.y <= b.y else b
	var high := b if a.y <= b.y else a
	var rise := high.y - low.y
	var flat := Vector3(high.x - low.x, 0.0, high.z - low.z)
	if rise < 0.3 or flat.length() < 0.3:
		return
	var n := maxi(2, int(round(rise / TREAD)))
	var forward := flat.normalized()
	var basis := Basis(Vector3.UP.cross(forward).normalized(), Vector3.UP, forward)
	var step_h := rise / float(n)
	var depth := flat.length() / float(n)
	var width := size.x
	for i in n:
		var f := (float(i) + 0.5) / float(n)
		var tread_top := low.y + rise * f + step_h * 0.25
		var height := step_h + 0.35
		var centre := low + flat * f
		centre.y = tread_top - height * 0.5
		boxes.append([Transform3D(_sized(basis, Vector3(width, height, depth)), centre),
			TREAD_STONE if i % 2 == 0 else STONE])
		treads += 1

## A rotation with its axes stretched to the box's size (a unit box to it).
static func _sized(b: Basis, size: Vector3) -> Basis:
	return Basis(b.x.normalized() * size.x, b.y.normalized() * size.y, b.z.normalized() * size.z)
