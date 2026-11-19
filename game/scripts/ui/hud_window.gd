extends Control
class_name HudWindow

## The one window standard the travel windows share (the Hearth window, the
## Waylink picker): the same card as the inventory and Kestrin's workshop, an
## opaque midnight panel in the arcane frame, the gold title ribbon with ONE
## close button, draggable by the ribbon, sized to the screen.
##
## Windows are non-modal: no dimming, clicks around the card reach the world
## and the character keeps moving.
##
## Content goes into `body`; `card` is the framed window itself. The title is
## given in English and translated here (the node keeps the English name).

signal closed

var title_text := ""
var body: VBoxContainer
var card: UIWindow
var _title: Label
var _wanted := Vector2(560, 480)
var _placed := false

func _init(p_title: String = "", wanted: Vector2 = Vector2(560, 480)) -> void:
	title_text = p_title
	_wanted = wanted
	name = p_title.replace(" ", "") + "Window" if p_title != "" else "HudWindow"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _ready() -> void:
	card = ArcaneSkin.window(I18n.upper(tr(title_text)), _wanted)
	card.name = "Card"
	add_child(card)
	card.closed.connect(close)
	_title = card._title_label
	body = card.body
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	get_viewport().size_changed.connect(_layout)
	card._content_margin.minimum_size_changed.connect(_content_changed)
	_layout()

func set_title(text: String) -> void:
	title_text = text
	if _title != null:
		_title.text = I18n.upper(tr(text))

## The content came to need more (or less) room: one layout for however many
## changes a frame makes.
var _layout_queued := false

func _content_changed() -> void:
	if _layout_queued or not visible:
		return   # a hidden window is laid out when it opens
	_layout_queued = true
	_layout.call_deferred()

## Size the card and clamp it to the screen; centre it the first time
## (afterwards it stays where the player dragged it). The card is the size its
## window asked for, or what its content needs when that is more.
func _layout() -> void:
	_layout_queued = false
	if card == null:
		return
	var canvas := get_viewport().get_visible_rect().size
	var need := card._content_margin.get_combined_minimum_size()
	# Keep clear of the action bar at the bottom (about 100 px).
	var s := Vector2(minf(maxf(_wanted.x, need.x), canvas.x - 32.0), minf(maxf(_wanted.y, need.y), canvas.y - 140.0))
	var at := Vector2(card.offset_left, card.offset_top)
	if not _placed:
		at = ((canvas - s) * 0.5).floor() - Vector2(0, 30)
	at.x = clampf(at.x, 0.0, maxf(0.0, canvas.x - s.x))
	at.y = clampf(at.y, 24.0, maxf(24.0, canvas.y - 100.0 - s.y))
	ArcaneSkin.place(card, at, s)

func open() -> void:
	move_to_front()   # the window just opened is the one on top
	show()
	_layout()
	_placed = true
	card.open()

func close() -> void:
	if not visible:
		return
	hide()
	closed.emit()

func is_open() -> bool:
	return visible

func toggle() -> void:
	if visible:
		close()
	else:
		open()
