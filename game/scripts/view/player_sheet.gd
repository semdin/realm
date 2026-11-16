extends Node
class_name PlayerSheet

## The player's character sheet for the interface, in the shape the windows
## read: `inventory` (bag entries, each with its `cell`), `equipment` (slot ->
## entry), `oril` (oril), `level`, `is_dead`. It mirrors what the
## RealmSession last received from the server and turns window requests into
## item operations; nothing here decides anything.

## The sheet changed (any field).
signal inventory_changed
## The answer to a request: {request_id, ok, reason, amount}.
signal equipment_answer(answer: Dictionary)

## Equipment cells are 100 + the slot's index (RealmSession.slot_names).
const WORN_BASE := 100

var session: Node
var is_local_player := true
var player_name := ""
var level := 1
var oril := 0
var hp := 0
var max_hp := 1
var mana := 0
var max_mana := 1
var is_dead := false
var inventory: Array = []
var equipment: Dictionary = {}
## Bag cell -> entry (empty cells absent).
var cells: Dictionary = {}
## The whole sheet as the session last reported it (RealmSession.sheet: the
## quest log, house standing and the rest), for readers that want more than
## the windows' shape.
var data: Dictionary = {}
var _slot_names: PackedStringArray
var _revision := -1
## RealmSession.sheet_revision is there (an extension built before it lacks
## it: then the whole sheet is read each frame, as it used to be).
var _cheap_revision := false

func _init(realm_session: Node) -> void:
	session = realm_session
	_cheap_revision = session.has_method("sheet_revision")
	_slot_names = session.slot_names()
	add_to_group("players")

func _process(_delta: float) -> void:
	# the revision alone each frame; the whole sheet only when it changed
	if not _cheap_revision or int(session.sheet_revision()) != _revision:
		var sheet: Dictionary = session.sheet()
		if not sheet.is_empty() and int(sheet.get("revision", 0)) != _revision:
			_read(sheet)
	for answer: Dictionary in session.take_item_results():
		equipment_answer.emit({"request_id": int(answer.op_id), "ok": bool(answer.ok),
			"reason": String(answer.reason), "amount": int(answer.amount)})

func _read(sheet: Dictionary) -> void:
	_revision = int(sheet.get("revision", 0))
	data = sheet
	player_name = String(sheet.get("name", ""))
	level = int(sheet.get("level", 1))
	oril = int(sheet.get("oril", 0))
	hp = int(sheet.get("hp", 0))
	max_hp = int(sheet.get("max_hp", 1))
	mana = int(sheet.get("mana", 0))
	max_mana = int(sheet.get("max_mana", 1))
	inventory.clear()
	cells.clear()
	var bag: Array = sheet.get("bag", [])
	for i in bag.size():
		if bag[i] == null:
			continue
		var entry := _entry(bag[i])
		entry["cell"] = i
		inventory.append(entry)
		cells[i] = entry
	equipment.clear()
	var worn: Dictionary = sheet.get("equipment", {})
	for slot: String in worn:
		equipment[slot] = _entry(worn[slot])
	inventory_changed.emit()

## The windows' entry shape: bonuses as a list of {stat, value}.
static func _entry(item: Dictionary) -> Dictionary:
	var bonuses: Array = []
	var raw: Dictionary = item.get("bonuses", {})
	for stat: String in raw:
		bonuses.append({"stat": stat, "value": raw[stat]})
	return {"id": String(item.get("id", "")), "amount": int(item.get("amount", 1)),
		"tier": int(item.get("tier", 0)), "uid": int(item.get("uid", 0)), "bonuses": bonuses}

func worn_cell(slot: String) -> int:
	var index := _slot_names.find(slot)
	return WORN_BASE + index if index >= 0 else -1

## The first empty bag cell at or after `from` (-1 when the bag is full).
func free_cell(from := 0) -> int:
	for i in range(from, ItemRules.BAG_SLOTS):
		if not cells.has(i):
			return i
	return -1

## A window request: `operation` as the old interface named it, `slot` the
## equipment slot it concerns, `entry` the bag entry (with its `cell`),
## `cell` a destination bag cell where it matters. Returns the request id the
## answer will carry (0 when nothing was sent).
func submit(operation: String, slot: String, entry: Dictionary = {}, cell := -1) -> int:
	var from := int(entry.get("cell", -1))
	match operation:
		"equip":
			return session.move_item(from, worn_cell(slot)) if from >= 0 else 0
		"unequip":
			var to := cell if cell >= 0 and not cells.has(cell) else free_cell()
			return session.move_item(worn_cell(slot), to) if to >= 0 else 0
		"move":
			return session.move_item(from, cell) if from >= 0 and cell >= 0 else 0
		"consume":
			return session.use_item(from) if from >= 0 else 0
		"sell":
			return session.sell_item(from) if from >= 0 else 0
		"destroy":
			return session.destroy_item(from) if from >= 0 else 0
	return 0

## The workshop: refine the bag entry `entry` one step (+N). Returns the
## request id (0 when nothing was sent).
func refine(entry: Dictionary) -> int:
	var at := int(entry.get("cell", -1))
	return session.refine_item(at) if at >= 0 else 0

## The workshop: use the first bag stack of the scroll `scroll_id` (imbue or
## reweave) on the bag entry `entry`. Returns the request id (0 when nothing
## was sent: no such scroll, or no target cell).
func enchant(scroll_id: String, entry: Dictionary) -> int:
	var at := int(entry.get("cell", -1))
	for held: Dictionary in inventory:
		if String(held.id) == scroll_id and at >= 0:
			return session.enchant_item(int(held.cell), at)
	return 0

## The sheet's revision (bumped by every change the server makes).
func revision() -> int:
	return _revision

## Derived stats now and after moving `from` to `to` (see
## RealmSession.preview_move).
func derived() -> Dictionary:
	return session.derived_stats()

func preview(from: int, to: int) -> Dictionary:
	return session.preview_move(from, to)
