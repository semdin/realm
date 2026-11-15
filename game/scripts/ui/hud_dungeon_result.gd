extends HudWindow
class_name HudDungeonResult

## The end of a dungeon run (the old game's approved result window): the
## medal (or none), the clock against the run's par, the clear and the
## deaths. Opened by HudDungeonRun from the run's `result`; what this player
## earned arrives as the server's "rewards" event.
##
## "Run it again" belongs to the party leader alone (disabled for everyone
## else; the old game wrongly offered it to all): it asks the server for
## another run of the same dungeon and difficulty from inside the finished
## copy (RealmSession.dungeon_start with a gate of this dungeon), and the
## party's ready check follows as at the gate (HudInvites); "launch" takes
## everyone into a fresh copy. A refusal says why on the notice band (the
## gate window's words) and lets the leader ask again.

const MEDALS := {
	"gold": Color(0.92, 0.74, 0.30),
	"silver": Color(0.76, 0.80, 0.86),
	"bronze": Color(0.82, 0.54, 0.32),
	"": Color(0.45, 0.45, 0.50),
}

var session: Node
## The medal shown ("" none) and the rewards heard (the check reads them).
var medal := ""
var rewards: Dictionary = {}
var _medal: MedalDisc
var _medal_name: Label
var _subtitle: Label
var _facts: GridContainer
var _earned: VBoxContainer
var again_button: Button
## The run shown: its dungeon and difficulty (protocol index), and the
## replays asked for (the check reads them).
var dungeon_id := ""
var difficulty := 1
var replays_sent := 0

## The notice band's text sits around y 96-130.
const NOTICE_CLEARANCE := 150.0

func _init() -> void:
	super._init("Dungeon Complete", Vector2(460, 480))
	name = "DungeonResult"

func _ready() -> void:
	super._ready()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	body.add_child(head)
	_medal = MedalDisc.new()
	head.add_child(_medal)
	var words := VBoxContainer.new()
	words.alignment = BoxContainer.ALIGNMENT_CENTER
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(words)
	_medal_name = HudKit.label("", 30, HudKit.GOLD_HI, HudKit.title(), 4)
	words.add_child(_medal_name)
	_subtitle = HudKit.label("", 14, HudKit.TEXT_DIM, HudKit.body(), 3)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	words.add_child(_subtitle)
	_facts = GridContainer.new()
	_facts.columns = 2
	_facts.add_theme_constant_override("h_separation", 16)
	_facts.add_theme_constant_override("v_separation", 4)
	body.add_child(_facts)
	_earned = VBoxContainer.new()
	_earned.add_theme_constant_override("separation", 3)
	_earned.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_earned)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	body.add_child(row)
	again_button = HudKit.button(tr("Run it again"), 15)
	again_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again_button.custom_minimum_size = Vector2(0, 38)
	again_button.visible = false
	again_button.pressed.connect(replay)
	row.add_child(again_button)
	var done := HudKit.button(tr("Close"), 15)
	done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	done.custom_minimum_size = Vector2(0, 38)
	done.pressed.connect(close)
	row.add_child(done)

## The "dungeon" game events of this window: the rewards, a new launch.
func on_event(event: Dictionary) -> void:
	match String(event.get("event", "")):
		"launch":
			close()
			rewards = {}
		"refused", "cancelled":
			# the leader may ask again (the notice band says why)
			_judge_again()
		"rewards":
			rewards = event
			_show_rewards()

## Stands below the notice band's line: the run's last step message (shown
## on the band as the result arrives) stays readable above the title. Every
## layout (the content fills in after the window opens) keeps it there.
func _layout() -> void:
	super._layout()
	if card == null:
		return
	var canvas := get_viewport().get_visible_rect().size
	var height := card.offset_bottom - card.offset_top
	var top := minf(maxf(card.offset_top, NOTICE_CLEARANCE), maxf(24.0, canvas.y - 100.0 - height))
	if top != card.offset_top:
		card.offset_top = top
		card.offset_bottom = top + height

## The party leader, or a player alone.
func _leads() -> bool:
	if session == null:
		return false
	var party: Dictionary = session.party()
	return int(party.get("party", 0)) == 0 or int(party.get("leader", 0)) == int(party.get("me", -1))

## Show the run's `view` (its `result` filled in).
func show_result(view: Dictionary) -> void:
	var result: Dictionary = view.get("result", {})
	dungeon_id = String(view.get("dungeon", ""))
	difficulty = int(view.get("difficulty", 1))
	var difficulty_key := DungeonData.difficulty_id(difficulty)
	medal = String(DungeonData.RANK_MEDALS.get(int(result.get("rank", -1)), ""))
	var timeout := bool(result.get("timeout", false))
	set_title("Time Is Up" if timeout else "Dungeon Complete")
	var names := {"gold": tr("Gold"), "silver": tr("Silver"), "bronze": tr("Bronze"), "": tr("No medal")}
	_medal.tint = MEDALS.get(medal, MEDALS[""])
	_medal.queue_redraw()
	_medal_name.text = String(names.get(medal, names[""]))
	_medal_name.add_theme_color_override("font_color", (MEDALS.get(medal, MEDALS[""]) as Color).lightened(0.2))
	_subtitle.text = "%s - %s" % [DungeonData.display_name(dungeon_id), DungeonData.difficulty_name(difficulty_key)]
	for child in _facts.get_children():
		_facts.remove_child(child)   # out of the layout this frame
		child.queue_free()
	var medals := DungeonData.medals()
	var par := float(view.get("par_s", 0.0))
	var clear := float(result.get("clear", 0)) / 1000.0
	_fact(tr("Time"), tr("%s (gold %s, silver %s, bronze %s)") % [DungeonData.clock(float(result.get("time_ms", 0)) / 1000.0),
		DungeonData.clock(par * float(medals.get("gold", 1.0))), DungeonData.clock(par * float(medals.get("silver", 1.3))),
		DungeonData.clock(par * float(medals.get("bronze", 1.6)))])
	_fact(tr("Clear"), tr("%d%%") % int(floor(clear * 100.0)))
	_fact(tr("Deaths"), str(int(result.get("deaths", 0))))
	if medal == "":
		var why := tr("The run was too slow for a medal.")
		if timeout:
			why = tr("Time ran out (%s) - the run ended where it stood.") % DungeonData.clock(par * float(medals.get("limit", 2.0)))
		elif clear < 1.0:
			why = tr("A medal needs every creature cleared, side rooms included.")
		elif bool(view.get("broken", false)):
			why = tr("The party's lives ran out.")
		_fact("", why)
	again_button.visible = portal() != ""
	_judge_again()
	_show_rewards()
	open()
	AudioManager.play_sound_at("ui_confirm" if medal != "" else "ui_open", Vector3.ZERO, null, true)

## "Run it again" is the leader's.
func _judge_again() -> void:
	if again_button == null:
		return
	again_button.disabled = not _leads()
	again_button.tooltip_text = "" if _leads() else tr("Only the party leader can start the dungeon.")

## A gate of the shown dungeon (a door on an open map into its map), the one
## the server starts the replay from; "" when there is none.
func portal() -> String:
	var map := String(DungeonData.dungeon(dungeon_id).get("map", ""))
	var all: Variant = RealmContent.table("maps")
	for p: Dictionary in ((all as Dictionary).get("portals", []) if all is Dictionary else []):
		if map != "" and String(p.get("to_map", "")) == map and not TravelData.instanced(String(p.get("map_id", ""))):
			return String(p.get("id", ""))
	return ""

## "Run it again": the same dungeon and difficulty once more.
func replay() -> void:
	var gate := portal()
	if session == null or gate == "" or not _leads():
		return
	replays_sent += 1
	again_button.disabled = true
	session.dungeon_start(gate, difficulty)
	AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

## What this player earned: experience, oril, the final chest's contents (it
## waits at the end of the dungeon), a difficulty newly opened, a title.
func _show_rewards() -> void:
	if _earned == null:
		return
	for child in _earned.get_children():
		_earned.remove_child(child)   # out of the layout this frame
		child.queue_free()
	if rewards.is_empty():
		return
	_line(I18n.upper(tr("Your rewards")), HudKit.GOLD_LT)
	if bool(rewards.get("helper", false)):
		_line(tr("You came as a helper: no final chest today."), HudKit.GOLD_LT)
	else:
		_line(tr("+%d EXP") % int(rewards.get("exp", 0)), Color(0.5, 1.0, 0.6))
		_line(tr("+%d Oril") % int(rewards.get("oril", 0)), Color(1.0, 0.85, 0.35))
		var parts: Array[String] = []
		for item: Array in rewards.get("items", []):
			var id := String(item[0])
			var amount := int(item[1])
			var item_name := I18n.t(String(ItemRules.item(id).get("name", id)))
			if int(item[2]) > 0:
				item_name += " " + tr("(%d enchantments)") % int(item[2])
			parts.append(item_name if amount == 1 else "%s x%d" % [item_name, amount])
		if not parts.is_empty():
			_line(tr("In your chest: %s") % ", ".join(PackedStringArray(parts)), HudKit.PARCHMENT)
	for index in rewards.get("unlocked", []):
		var id := DungeonData.difficulty_id(int(index))
		_line(tr("Unlocked: %s") % DungeonData.difficulty_name(id), DungeonData.colour(id))
	var title := String(rewards.get("title", ""))
	if title != "":
		_line(tr("New title earned: %s!") % I18n.t(title), HudKit.GOLD_HI)

func _line(text: String, colour: Color) -> void:
	var label := HudKit.label(text, 14, colour, HudKit.bold(), 2)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_earned.add_child(label)

func _fact(key: String, value: String) -> void:
	_facts.add_child(HudKit.label(key, 14, HudKit.TEXT_DIM, HudKit.body(), 2))
	var v := HudKit.label(value, 15, HudKit.PARCHMENT, HudKit.bold(), 2)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_facts.add_child(v)


## The medal: a struck disc in its metal with a ring and a star.
class MedalDisc extends Control:
	var tint := Color(0.92, 0.74, 0.30)

	func _init() -> void:
		custom_minimum_size = Vector2(84, 84)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 4.0
		draw_circle(c, r + 4.0, Color(tint.r, tint.g, tint.b, 0.25))
		draw_circle(c, r, tint.darkened(0.35))
		draw_circle(c + Vector2(-r * 0.15, -r * 0.18), r * 0.8, tint)
		draw_arc(c, r - 5.0, 0.0, TAU, 48, tint.lightened(0.45), 2.0, true)
		var points := PackedVector2Array()
		for i in 10:
			var a := -PI * 0.5 + TAU * float(i) / 10.0
			points.append(c + Vector2(cos(a), sin(a)) * (r * (0.5 if i % 2 == 0 else 0.22)))
		draw_colored_polygon(points, tint.lightened(0.55))
