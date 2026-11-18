extends Control
class_name FirstSteps

## The controls introduction: one small card at the top of the screen that
## asks for one thing at a time and moves on when the player has done it, in
## the world, with nothing paused or blocked. Walk, look around, talk to the
## first quest's teacher, claim the reward, find the quest log, wear the cloak
## (the second quest), target, attack, cast, open the map, and take the first
## chest when one drops. Doing something early counts; the first three quests
## finish their steps by themselves.
##
## Keys come from GameSettings as they are bound now and redraw on a rebind, so
## no sentence names a key. "Next" passes a step, "Skip introduction" ends it
## for good. A returning character (past level 2 or a few quests in) never sees
## it, and Settings > Controls brings it back (`GameSettings.intro_done`).

const WIDTH := 560.0
## Under the target card and the notice band.
const TOP := 128.0
const POLL_SECONDS := 0.2
const OUTRO_SECONDS := 7.0
const MOVE_METRES := 3.0
const TURN_RADIANS := 0.5
## Who has played before: this far along, the introduction is not offered.
const RETURNING_LEVEL := 2
const RETURNING_QUESTS := 3
const ORDER := ["move", "camera", "talk", "claim", "quests", "bag", "target", "attack", "spells", "map", "loot"]
const FIRST_QUEST := "q001"
const CLOAK_QUEST := "q002"
const DRILL_QUEST := "q003"

## Done steps and the replay flag outlive a trip's scene reload.
static var _done: Dictionary = {}
static var _replaying := false
static var _running := false

var game: Node
var current := ""
var _decided := false
var _card: PanelContainer
var _count: Label
var _title: Label
var _body: Label
var _chips: HBoxContainer
var _next: Button
var _ring: Ring
var _poll := 0.0
var _from := Vector3.INF
var _yaw := 0.0
var _pitch := 0.0
var _cast := false
var _chest_seen := false
var _outro_left := 0.0

func _init() -> void:
	name = "FirstSteps"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	theme = UITheme.get_theme()
	_build()
	GameSettings.instance().changed.connect(_on_settings)
	game.hud.action_bar.spell_requested.connect(func(_id: String): _cast = true)

func is_running() -> bool:
	return _running and _card != null and _card.visible

## ----------------------------------------------------------------- the card

func _build() -> void:
	_ring = Ring.new()
	add_child(_ring)
	_card = PanelContainer.new()
	_card.name = "Card"
	var box := ArcaneSkin.surface()
	box.content_margin_left = 22
	box.content_margin_right = 20
	box.content_margin_top = 14
	box.content_margin_bottom = 18
	_card.add_theme_stylebox_override("panel", box)
	_card.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_card.offset_left = -WIDTH * 0.5
	_card.offset_right = WIDTH * 0.5
	_card.offset_top = TOP
	_card.grow_vertical = Control.GROW_DIRECTION_END
	_card.visible = false
	add_child(_card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_card.add_child(column)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	column.add_child(head)
	var caption := HudKit.label(I18n.upper(tr("First steps")), 12, HudKit.GOLD, HudKit.title(), 0)
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(caption)
	_count = HudKit.label("", 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_count)
	_next = HudKit.button(tr("Next"), 12)
	_next.name = "NextStep"
	_next.custom_minimum_size = Vector2(64, 24)
	_next.pressed.connect(skip_step)
	head.add_child(_next)
	var skip := HudKit.button(tr("Skip introduction"), 12)
	skip.name = "SkipIntro"
	skip.custom_minimum_size = Vector2(0, 24)
	skip.tooltip_text = tr("You can replay it from Settings > Controls")
	skip.pressed.connect(skip_all)
	head.add_child(skip)
	_title = HudKit.label("", 19, HudKit.GOLD_HI, HudKit.title(), 0)
	column.add_child(_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	column.add_child(row)
	_chips = HBoxContainer.new()
	_chips.add_theme_constant_override("separation", 4)
	_chips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_chips)
	_body = HudKit.label("", 15, HudKit.PARCHMENT, HudKit.body(), 0)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.custom_minimum_size.x = 200
	_body.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_body)

## A key cap (`bound`: the key's own name) or a mouse label.
func _chip(text: String) -> PanelContainer:
	var cap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.16)
	sb.border_color = HudKit.GOLD
	sb.set_border_width_all(1)
	sb.border_width_bottom = 2
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 2
	sb.content_margin_bottom = 3
	cap.add_theme_stylebox_override("panel", sb)
	var label := HudKit.label(text, 13, HudKit.GOLD_HI, HudKit.bold(), 0)
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size.x = 14
	cap.add_child(label)
	return cap

## What step `id` says: {title, body, keys (actions), mouse (labels)}.
func _spec(id: String) -> Dictionary:
	match id:
		"move":
			return {"title": tr("Walk"), "body": tr("Use these keys to walk around the courtyard."),
				"keys": ["move_forward", "move_left", "move_backward", "move_right"]}
		"camera":
			var how := tr("Hold the right mouse button and drag to look around. The wheel zooms.")
			if GameSettings.is_mac():
				how += " " + tr("On a trackpad, hold Control and drag.")
			return {"title": tr("Look around"), "body": how, "mouse": [tr("Right mouse"), tr("Wheel")]}
		"talk":
			var teacher := I18n.t(String(game.quests.quest(FIRST_QUEST).get("target", "")))
			return {"title": tr("Your first quest"),
				"body": tr("Follow the gold arrow to %s, then click them or press the key to talk.") % teacher,
				"keys": ["interact"], "mouse": [tr("Left click")]}
		"claim":
			return {"title": tr("Collect the reward"), "body": tr("Quest done! Click its glowing card on the left."),
				"mouse": [tr("Left click")]}
		"quests":
			return {"title": tr("Your quests"),
				"body": tr("The cards on the left show what to do next. Open the quest log to see them all."),
				"keys": ["quest_log"]}
		"bag":
			return {"title": tr("Wear your reward"), "body": tr("Open your bag and right-click the cloak to put it on."),
				"keys": ["inventory"], "mouse": [tr("Right click")]}
		"target":
			return {"title": tr("Choose a target"),
				"body": tr("Click a training dummy or a creature, or cycle through what is near."),
				"keys": ["target_cycle"], "mouse": [tr("Left click")]}
		"attack":
			return {"title": tr("Attack"), "body": tr("Click your target to cast at it. Hold the button or the key to keep casting."),
				"keys": ["basic_attack"], "mouse": [tr("Left click")]}
		"spells":
			return {"title": tr("Spells"),
				"body": tr("Click a spell on the bar to learn it with a skill point, then press its key to cast. The Skills window holds the rest."),
				"keys": ["spell_1", "spell_2", "skills"]}
		"map":
			return {"title": tr("Find your way"), "body": tr("Open the world map. Click it to set a waypoint."),
				"keys": ["world_map"]}
		"loot":
			return {"title": tr("Loot"), "body": tr("A chest dropped! Walk up to it and take what is inside."),
				"keys": ["pickup_loot"], "mouse": [tr("Left click")]}
	return {}

## The window or bar a step points at (null: none).
func _focus(id: String) -> Control:
	match id:
		"claim":
			return game.tracker
		"quests":
			return game.hud.menu_buttons["quests"]
		"bag":
			return game.hud.bag_button
		"spells":
			return game.hud.action_bar
		"map":
			return game.hud.menu_buttons["map"]
	return null

func _show_step() -> void:
	var spec := _spec(current)
	_title.text = String(spec.get("title", ""))
	_body.text = String(spec.get("body", ""))
	for old: Node in _chips.get_children():
		old.queue_free()
	for action: String in spec.get("keys", []):
		_chips.add_child(_chip(GameSettings.key_name(action) if GameSettings.key(action) > 0 else "—"))
	for text: String in spec.get("mouse", []):
		_chips.add_child(_chip(text))
	var left := ORDER.filter(func(id): return _done.has(id)).size()
	_count.text = "%d / %d" % [mini(left + 1, ORDER.size()), ORDER.size()]
	_next.visible = true
	_card.reset_size()
	_card.offset_left = -WIDTH * 0.5
	_card.offset_right = WIDTH * 0.5
	_card.visible = true
	_ring.follow(_focus(current))

## ------------------------------------------------------------------ the flow

## Begin (or, `replay`, begin again with every step open).
func start(replay := false) -> void:
	if replay or not _running:
		_done.clear()
	_replaying = replay or _replaying
	_running = true
	_cast = false
	_chest_seen = false
	_from = game.session.own_position()
	_yaw = game.cam_yaw
	_pitch = game.cam_pitch
	_advance()

func skip_step() -> void:
	if current == "":
		return
	_done[current] = true
	# no talk, so nothing to collect either
	if current == "talk":
		_done["claim"] = true
	_advance()

func skip_all() -> void:
	_stop()
	GameSettings.instance().set_intro_done(true)

func _stop() -> void:
	_running = false
	_replaying = false
	current = ""
	_outro_left = 0.0
	_card.visible = false
	_ring.follow(null)

func _advance() -> void:
	var next := _pick()
	if next == current and next != "":
		return
	current = next
	if current != "":
		_show_step()
	elif _done.has("loot"):
		_finish()
	else:
		# only the first chest is left: the card waits for one
		_card.visible = false
		_ring.follow(null)

## The chest comes first while it lies there; else the next step in order.
func _pick() -> String:
	if not _done.has("loot") and not game.chests.is_empty():
		return "loot"
	for id: String in ORDER:
		if id != "loot" and not _done.has(id):
			return id
	return ""

func _finish() -> void:
	_title.text = tr("You are ready")
	_body.text = tr("Every key can be changed in Settings > Controls. Good luck out there.")
	for old: Node in _chips.get_children():
		old.queue_free()
	_count.text = ""
	_next.visible = false
	_card.visible = true
	_ring.follow(null)
	_outro_left = OUTRO_SECONDS
	_running = false
	_replaying = false
	GameSettings.instance().set_intro_done(true)

## Whether the player has done step `id` (a quest finished counts, except on a
## replay, when those quests were finished long ago).
func _did(id: String) -> bool:
	var q: QuestManager = game.quests
	var by_quest := not _replaying
	match id:
		"move":
			var here: Vector3 = game.session.own_position()
			return _from != Vector3.INF and Vector2(here.x - _from.x, here.z - _from.z).length() >= MOVE_METRES
		"camera":
			return absf(wrapf(game.cam_yaw - _yaw, -PI, PI)) + absf(game.cam_pitch - _pitch) >= TURN_RADIANS
		"talk":
			return game.dialogue.visible or (by_quest and (q.is_ready(FIRST_QUEST) or q.is_done(FIRST_QUEST)))
		"claim":
			return not by_quest or (not q.is_ready(FIRST_QUEST) and not q.is_open(FIRST_QUEST))
		"quests":
			return game.quest_log.visible or game.quest_scroll.is_open()
		"bag":
			if by_quest and q.is_open(CLOAK_QUEST):
				return false
			return game.inventory.visible or (by_quest and (q.is_ready(CLOAK_QUEST) or q.is_done(CLOAK_QUEST)))
		"target":
			return game.target != 0
		"attack":
			return game.basic_hold != "" or (by_quest and (q.is_done(DRILL_QUEST) or q.is_ready(DRILL_QUEST) or q.progress_of(DRILL_QUEST) > 0))
		"spells":
			return _cast or game.skill_window.visible
		"map":
			return game.way.world_map.visible
		"loot":
			return game.loot_window.visible or (_chest_seen and game.chests.is_empty())
	return false

func _process(delta: float) -> void:
	if _outro_left > 0.0:
		_outro_left -= delta
		if _outro_left <= 0.0:
			_card.visible = false
		return
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_SECONDS
	if not _decided:
		_decide()
		return
	if not _running or not game.built:
		return
	if not game.chests.is_empty():
		_chest_seen = true
	var changed := false
	for id: String in ORDER:
		if not _done.has(id) and _did(id):
			_done[id] = true
			changed = true
	if changed or current == "" or (current != "loot" and _pick() == "loot"):
		_advance()

## Once the world and the sheet are here: offer it, or not.
func _decide() -> void:
	if not game.built or game.sheet_view.data.is_empty():
		return
	_decided = true
	if _running:
		start()   # a trip in the middle of it: on with the rest
		return
	var settings := GameSettings.instance()
	if settings.intro_done or Array(OS.get_cmdline_user_args()).any(func(a): return String(a).begins_with("--check")):
		return
	if game.sheet_view.level > RETURNING_LEVEL or game.quests.done_count() > RETURNING_QUESTS:
		settings.set_intro_done(true)
		return
	start()

func _on_settings(what: String) -> void:
	match what:
		"bindings":
			if current != "":
				_show_step()
		"intro":
			# Settings > Controls asked for it again
			if not GameSettings.instance().intro_done and _decided and not _running:
				_outro_left = 0.0
				start(true)

## The gold outline that pulses round what a step talks about.
class Ring extends Control:
	var _target: Control
	var _t := 0.0
	var _box := StyleBoxFlat.new()

	func _init() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_box.draw_center = false
		_box.set_border_width_all(2)
		_box.set_corner_radius_all(5)
		set_process(false)

	func follow(target: Control) -> void:
		_target = target
		set_process(target != null)
		queue_redraw()

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		if _target == null or not is_instance_valid(_target) or not _target.is_visible_in_tree():
			return
		var pulse := 0.5 + 0.5 * sin(_t * 4.0)
		_box.border_color = Color(HudKit.GOLD_HI.r, HudKit.GOLD_HI.g, HudKit.GOLD_HI.b, 0.45 + 0.55 * pulse)
		var area := _target.get_global_rect().grow(3.0 + 2.0 * pulse)
		area.position -= get_global_rect().position
		draw_style_box(_box, area)
