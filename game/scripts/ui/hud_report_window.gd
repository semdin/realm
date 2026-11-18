extends HudWindow

## Reporting a player, from the player menu: what kind of problem it is and, if
## the player wants, a few words. The server keeps the report with the recent
## chat of the two players and answers in the chat log.

const MAX_TEXT := 300
## The server's words, and what the player reads.
const CATEGORIES := [
	["harassment", "Harassment"],
	["hate", "Hate speech"],
	["spam", "Spam"],
	["cheating", "Cheating"],
	["name", "Offensive name"],
	["other", "Something else"],
]

var session: Node
var target_name := ""
var target_character := 0
var _who: Label
var _category: OptionButton
var _text: LineEdit

func _init() -> void:
	super._init("Report Player", Vector2(460, 330))

func _ready() -> void:
	super._ready()
	_who = HudKit.label("", 17, HudKit.GOLD_HI, HudKit.bold(), 3)
	body.add_child(_who)
	_category = OptionButton.new()
	_category.name = "Category"
	_category.focus_mode = Control.FOCUS_NONE
	_category.custom_minimum_size = Vector2(0, 34)
	HudKit.style_button(_category)
	for i in CATEGORIES.size():
		_category.add_item(tr(String(CATEGORIES[i][1])), i)
	body.add_child(_category)
	_text = LineEdit.new()
	_text.name = "Details"
	_text.max_length = MAX_TEXT
	_text.placeholder_text = tr("What happened? (optional)")
	_text.custom_minimum_size = Vector2(0, 34)
	_text.add_theme_font_override("font", HudKit.body())
	_text.add_theme_font_size_override("font_size", 15)
	body.add_child(_text)
	var note := HudKit.label(tr("Recent chat from you and this player is sent with the report so staff can check it."), 13, HudKit.TEXT_DIM, HudKit.body(), 2)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	body.add_child(row)
	var cancel := HudKit.button(tr("Cancel"))
	cancel.pressed.connect(close)
	row.add_child(cancel)
	var send := HudKit.gold_button(tr("Send Report"), 34.0, 15)
	send.name = "Send"
	send.custom_minimum_size.x = 140
	send.pressed.connect(_send)
	row.add_child(send)

## Opens on the player called `who`.
func open_on(who: String, character: int) -> void:
	target_name = who
	target_character = character
	_who.text = tr("Report %s") % who
	_category.select(0)
	_text.clear()
	open()

func _send() -> void:
	if session != null:
		session.report_player(target_character, target_name, String(CATEGORIES[_category.selected][0]), _text.text.strip_edges())
	AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)
	close()
