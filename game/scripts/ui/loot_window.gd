extends Control
class_name LootWindow

## The small chest window (Knight Online style): right-clicking a chest on the
## ground opens its slots here. Click a slot to take that item, or "Take all".
##
## The window only ever shows what the server says the chest holds: the
## "chest" game event (sent on open and again after every take). A take is a
## request; the slot empties when the server answers with the updated chest,
## and the window closes with the chest (main.gd closes it when the snapshot
## drops it) or when the player walks away.

const COLUMNS := 5
const SLOT_PX := 48.0
## Walk further than this from the chest and the window closes.
const CLOSE_RANGE := 9.0

var session: Node
## The chest's place and the player's, for the range (main.gd's drawn table).
var where: Callable
var _window: UIWindow
var _grid: GridContainer
var _take_all: Button
var _status: Label
var _tooltip: ItemTooltip
var _layer: CanvasLayer
## The open chest's entity id (0 = none) and whether it is an enchanted one.
var chest_id := 0
var _rare := false
var _items: Array = []
var _slots: Array[UISlot] = []
## Takes asked for (the check reads it).
var takes_sent := 0

func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer = CanvasLayer.new()
	_layer.layer = 11
	add_child(_layer)
	_window = ArcaneSkin.window(I18n.upper(tr("Chest")), Vector2(COLUMNS * (SLOT_PX + 5) + 44, 214), "ui_inventory")
	_window.closed.connect(close)
	_layer.add_child(_window)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 5)
	_grid.add_theme_constant_override("v_separation", 5)
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_window.body.add_child(_grid)
	_status = UITheme.body("", 12, UITheme.c("text_dim"))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_window.body.add_child(_status)
	_take_all = Button.new()
	_take_all.text = tr("Take all")
	_take_all.focus_mode = Control.FOCUS_NONE
	_take_all.pressed.connect(func(): take(-1))
	_window.body.add_child(_take_all)
	_tooltip = ItemTooltip.new()
	_layer.add_child(_tooltip)
	visibility_changed.connect(func(): _layer.visible = visible)
	hide()

## Open (or re-target) the window on chest `id`; its cells come with the
## server's "chest" answer.
func open_chest(id: int, rare: bool) -> void:
	if id != chest_id:
		_items = []
	chest_id = id
	_rare = rare
	_status.text = ""
	session.open_chest(id)
	refresh()
	if not visible:
		var view := get_viewport().get_visible_rect().size
		var at := Vector2(view.x * 0.5 + 140.0, view.y * 0.32).floor()
		_window.offset_left = minf(at.x, view.x - _window.custom_minimum_size.x - 12.0)
		_window.offset_top = at.y
		_window.offset_right = _window.offset_left + _window.custom_minimum_size.x
		_window.offset_bottom = _window.offset_top + _window.custom_minimum_size.y
	show()
	_window.open()
	_play("ui_open")

func close() -> void:
	chest_id = 0
	_items = []
	if _tooltip != null:
		_tooltip.hide_item()
	hide()

func is_open() -> bool:
	return visible

## The server's word on what chest `id` holds (item dictionaries, null for an
## emptied cell).
func on_chest(id: int, slots: Array) -> void:
	if id != chest_id or not visible:
		return
	_items = slots
	refresh()

## The answer to a take or an open: why nothing came, in the window.
func on_result(id: int, ok: bool, reason: String) -> void:
	if id != chest_id or not visible:
		return
	match reason:
		"out_of_range":
			_status.text = tr("Too far away.")
		"bag_full":
			_status.text = tr("Your bag is full.")
		"gone":
			if not ok:
				close()
		_:
			_status.text = ""

func refresh() -> void:
	_window.title = I18n.upper(tr("Enchanted Chest") if _rare else tr("Chest"))
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_slots.clear()
	var held := 0
	var cells := maxi(COLUMNS * 2, int(ceil(float(_items.size()) / COLUMNS)) * COLUMNS)
	for index in cells:
		var slot := UISlot.new(Vector2(SLOT_PX, SLOT_PX))
		slot.equipment_interaction = true
		slot.ready.connect(func(): slot.theme_type_variation = &"ArcaneSlot")
		slot.set_meta("chest_slot", index)
		if index < _items.size() and _items[index] is Dictionary and int(_items[index].get("amount", 0)) > 0:
			var entry := PlayerSheet._entry(_items[index])
			held += 1
			slot.set_item(String(entry.id), entry)
			slot.tooltip_text = ""
			slot.pressed.connect(func(): take(index))
			slot.activated.connect(func(_s): take(index))
			slot.slot_entered.connect(_on_slot_entered)
			slot.slot_exited.connect(func(_s): _tooltip.hide_item())
		_grid.add_child(slot)
		_slots.append(slot)
	_take_all.disabled = held == 0

## Ask for one cell, or (-1) everything that fits.
func take(slot: int) -> void:
	if chest_id == 0:
		close()
		return
	session.take_loot(chest_id, slot)
	takes_sent += 1
	_play("ui_loot")

func _on_slot_entered(slot: UISlot) -> void:
	if slot.item_id == "":
		return
	_tooltip.show_item(slot.item_id, slot.entry)
	_tooltip.follow_cursor()

func _process(_delta: float) -> void:
	if not visible:
		return
	if _tooltip.visible:
		_tooltip.follow_cursor()
	var span: float = where.call(chest_id) if where.is_valid() else INF
	if span > CLOSE_RANGE:
		close()

func _play(sound: String) -> void:
	AudioManager.play_sound_at(sound, Vector3.ZERO, null, true)
