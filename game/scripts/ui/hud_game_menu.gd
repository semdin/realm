extends HudWindow
class_name HudGameMenu

## The Esc menu: what a player reaches when nothing else is open. Resume,
## Settings, Help & Support (the issue tracker, in the browser), Change
## character (back to the character screen) and Quit.
##
## Leaving an online world is not instant, as in the old game: a short
## countdown (3 s, 5 s after combat in the last 10 s) that damage taken,
## defeat, moving and closing the menu cancel - "log out to escape a fight"
## must not work. It cannot start while defeated. The save does not depend on
## it: the server saves and releases the character when the connection closes,
## which main.gd's leave_world does cleanly before the scene changes.

signal settings_requested

const LEAVE_SECONDS := 3
const LEAVE_SECONDS_COMBAT := 5
## Damage dealt or taken this recently counts as "in combat".
const COMBAT_WINDOW_MS := 10000
## Moving farther than this (on the ground plane) since the countdown began
## cancels it.
const MOVE_CANCEL_METRES := 0.4

var game: Node
var buttons: Dictionary = {}
var note: Label
## Countdown state: "" when idle, else "character" or "quit".
var leaving := ""
## Evidence for the menu check: countdowns begun, cancelled (by reason), and
## the countdown texts shown.
var countdowns := 0
var cancels: Dictionary = {}
var shown_seconds: Array = []
var _leave_at_ms := 0
var _last_combat_ms := -COMBAT_WINDOW_MS
var _from := Vector3.INF

func _init() -> void:
	super._init("Menu", Vector2(340, 340))
	name = "GameMenu"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 8)
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	for spec: Array in [["resume", tr("Resume")], ["settings", tr("Settings")], ["help", tr("Help & Support")],
			["character", tr("Change Character")], ["quit", tr("Quit Game")]]:
		var b := HudKit.button(String(spec[1]), 15)
		b.name = String(spec[0]).capitalize().replace(" ", "")
		b.custom_minimum_size = Vector2(0, 36)
		b.pressed.connect(_on_pressed.bind(String(spec[0])))
		body.add_child(b)
		buttons[String(spec[0])] = b
	note = HudKit.label(tr("Progress is saved when you leave."), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	note.name = "Note"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# the countdown line is wider than the card: unwrapped it pushed the
	# buttons out of the frame
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(1.0, 40.0)
	body.add_child(note)
	closed.connect(func(): cancel_leave(""))

func _on_pressed(id: String) -> void:
	match id:
		"resume":
			cancel_leave("")
			close()
		"settings":
			close()
			settings_requested.emit()
		"help":
			AccountDialogs.open_support()
		"character", "quit":
			begin_leave(id)

## Back to the character screen through the same countdown (the settings'
## language switch).
func leave_to_characters() -> void:
	open()
	begin_leave("character")

func begin_leave(kind: String) -> void:
	if leaving != "":
		return
	if game.feedback.is_dead():
		note.text = tr("You cannot leave while defeated.")
		return
	var in_combat := Time.get_ticks_msec() - _last_combat_ms < COMBAT_WINDOW_MS
	var seconds := LEAVE_SECONDS_COMBAT if in_combat else LEAVE_SECONDS
	leaving = kind
	countdowns += 1
	_leave_at_ms = Time.get_ticks_msec() + seconds * 1000
	_from = game.session.own_position()
	for id: String in buttons:
		(buttons[id] as Button).disabled = id != "resume"
	(buttons["resume"] as Button).text = tr("Cancel")
	_refresh_countdown()

func cancel_leave(reason: String, why := "") -> void:
	if leaving == "":
		return
	leaving = ""
	if why != "":
		cancels[why] = int(cancels.get(why, 0)) + 1
	for b: Button in buttons.values():
		b.disabled = false
	(buttons["resume"] as Button).text = tr("Resume")
	note.text = reason if reason != "" else tr("Progress is saved when you leave.")

func _refresh_countdown() -> void:
	var left := maxi(0, ceili(float(_leave_at_ms - Time.get_ticks_msec()) / 1000.0))
	if not shown_seconds.has(left):
		shown_seconds.append(left)
	var line := tr("Quitting in %d…") if leaving == "quit" else tr("Changing character in %d…")
	note.text = (line % left) + "\n" + tr("(moving or taking damage cancels)")

func _process(_delta: float) -> void:
	if leaving == "":
		return
	if game.feedback.is_dead():
		cancel_leave(tr("Interrupted: you were defeated."), "defeated")
		return
	var here: Vector3 = game.session.own_position()
	if _from != Vector3.INF and Vector2(here.x - _from.x, here.z - _from.z).length() > MOVE_CANCEL_METRES:
		cancel_leave(tr("Interrupted: you moved."), "moved")
		return
	if Time.get_ticks_msec() >= _leave_at_ms:
		var kind := leaving
		leaving = ""
		for b: Button in buttons.values():
			b.disabled = true
		note.text = tr("Saving…")
		game.leave_world(kind == "quit")
		return
	_refresh_countdown()

## Every combat event main.gd sees: a hit on the player cancels the
## countdown; a hit taken or dealt counts as combat.
func on_combat(event: Dictionary) -> void:
	if String(event["kind"]) != "hit" or int(event.get("amount", 0)) <= 0:
		return
	var me := int(game.session.own_entity())
	if int(event["target"]) == me:
		_last_combat_ms = Time.get_ticks_msec()
		cancel_leave(tr("Interrupted: you took damage."), "damage")
	elif int(event["attacker"]) == me:
		_last_combat_ms = Time.get_ticks_msec()
