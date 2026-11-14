extends HudWindow
class_name HudWaylink

## Where should the Waylink go? Opened by right-clicking an Old Boot in the
## bag (inventory_arcane.gd asks the HUD's `waylink`); the server sets it down
## at the owner's feet (RealmSession.waylink_place). The destinations are
## travel.json `waylink.destinations`; one above the character's level is
## locked and says the level it needs.

var session: Node
var player: Node = null
var _list: VBoxContainer
## Destination node id -> its button (the travel check reads them).
var buttons := {}

func _init() -> void:
	super._init("Waylink", Vector2(380, 360))
	name = "WaylinkWindow"

func _ready() -> void:
	super._ready()
	var hint := HudKit.label(tr("Set the boot down and choose where it goes. For ten seconds your party may grab hold; then everyone holding on is carried there together."), 13, HudKit.PARCHMENT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	body.add_child(_list)

## Open for `who` (the PlayerSheet: its level locks rows).
func open_for(who: Node) -> void:
	player = who
	for child in _list.get_children():
		child.queue_free()
	buttons.clear()
	var level := int(player.get("level")) if is_instance_valid(player) else 1
	for id in TravelData.rules("waylink").get("destinations", []):
		var dest := TravelData.node(String(id))
		if dest.is_empty():
			continue
		var row := HBoxContainer.new()
		_list.add_child(row)
		var name_label := HudKit.label(I18n.t(String(dest.get("label", id))), 16, HudKit.GOLD_HI)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var go := HudKit.button("", 14)
		go.focus_mode = Control.FOCUS_NONE
		go.custom_minimum_size = Vector2(110, 0)
		var need := int(dest.get("level_min", 1))
		if level < need:
			go.text = tr("Level %d") % need
			go.disabled = true
		else:
			go.text = tr("Set down")
			go.pressed.connect(_place.bind(String(id)))
		row.add_child(go)
		buttons[String(id)] = go
	open()

func _place(dest_id: String) -> void:
	close()
	if session != null:
		session.waylink_place(dest_id)
