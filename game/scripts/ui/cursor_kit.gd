extends RefCounted
class_name CursorKit

## The game's mouse pointers (the old game's CursorKit), all one size (36 px):
## the arrow, a pointing hand over buttons, a text bar over text fields, and a
## gold "rotate" glyph while the right mouse button turns the camera, so it is
## plain the mouse is steering the view and not pointing at something.
## main.gd installs them as the scene starts (`apply`), hands the shapes back
## as it leaves (`release`), turns the glyph on and off with the right button
## (`set_rotating`) and gives every button the hand (`point_at_buttons`).

const ARROW := "res://assets/ui/cursor.png"
const HAND := "res://assets/ui/cursor_hand.png"
const IBEAM := "res://assets/ui/cursor_ibeam.png"
const ROTATE := "res://assets/ui/cursor_rotate.png"
## Where each pointer points: the arrow's tip, the index fingertip, centres.
const HOTSPOTS := {
	ARROW: Vector2(0, 0),
	HAND: Vector2(12, 1),
	IBEAM: Vector2(18, 18),
	ROTATE: Vector2(18, 18),
}
## The shapes the game draws itself, and the pointer each one normally shows:
## every shape a control or a drag can ask for, so the system's pointer never
## shows (a dragged item asks for can-drop / forbidden / drag, a window's
## title bar for move, a splitter for a resize arrow).
const SHAPES := {
	Input.CURSOR_ARROW: ARROW,
	Input.CURSOR_POINTING_HAND: HAND,
	Input.CURSOR_IBEAM: IBEAM,
	Input.CURSOR_DRAG: HAND,
	Input.CURSOR_CAN_DROP: HAND,
	Input.CURSOR_FORBIDDEN: ARROW,
	Input.CURSOR_MOVE: HAND,
	Input.CURSOR_CROSS: ARROW,
	Input.CURSOR_WAIT: ARROW,
	Input.CURSOR_BUSY: ARROW,
	Input.CURSOR_HELP: ARROW,
	Input.CURSOR_VSIZE: ARROW,
	Input.CURSOR_HSIZE: ARROW,
	Input.CURSOR_BDIAGSIZE: ARROW,
	Input.CURSOR_FDIAGSIZE: ARROW,
	Input.CURSOR_VSPLIT: ARROW,
	Input.CURSOR_HSPLIT: ARROW,
}

static var _rotating := false
## Pointers installed (the check reads it).
static var installed := 0

static func apply() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_rotating = false
	for shape: int in SHAPES:
		_install(SHAPES[shape], shape)

## Every shape back to the system's while the RenderingServer still exists
## (the pointer textures would leak at exit).
static func release() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for shape: int in SHAPES:
		Input.set_custom_mouse_cursor(null, shape)
	installed = 0

## While turning the camera every shape shows the rotate glyph (the pointer
## may cross a button or a text field on the way).
static func set_rotating(on: bool) -> void:
	if on == _rotating or DisplayServer.get_name() == "headless":
		return
	_rotating = on
	for shape: int in SHAPES:
		_install(ROTATE if on else SHAPES[shape], shape)

static func is_rotating() -> bool:
	return _rotating

## Buttons show the hand (SceneTree.node_added). Text fields already ask for
## the I-beam; a control that chose another shape keeps it.
static func point_at_buttons(node: Node) -> void:
	if node is BaseButton and (node as Control).mouse_default_cursor_shape == Control.CURSOR_ARROW:
		(node as Control).mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func _install(path: String, shape: Input.CursorShape) -> void:
	var tex := load(path) as Texture2D if ResourceLoader.exists(path) else null
	if tex != null:
		Input.set_custom_mouse_cursor(tex, shape, HOTSPOTS[path])
		installed += 1
