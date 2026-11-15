extends Node
class_name MapDungeon

## Dungeons on the client, drawn from what the server says:
##
##   * The gate (F at a door into an instanced map, MapTravel hands it over):
##     the gate window (HudDungeon) asks the server what the party may do and
##     starts the run; a ready check shows its card (HudInvites) and answers
##     with RealmSession.dungeon_ready; "launch" closes them, and the trip
##     (departing -> travel -> scene reload -> loading screen) is MapTravel's.
##   * Inside a copy (RealmSession.copy() != 0): main.gd draws the map at
##     copy_offset(); the copy's gates stand as portcullises (DungeonGates),
##     the run tracker (HudDungeonRun) follows the run's "state" views, a new
##     step message shows on the notice band, the curses' marks burn on the
##     floor (DungeonHazards, from the "hazard" events and the run views),
##     and the result window (HudDungeonResult) opens at the end with the
##     "rewards" that follow. A run with a sleep chime (the Sealed Wing's, by
##     Threehead) shows it from the run view's `chime` (SleepChime).
##   * The guide (K, anywhere: HudDungeonGuide): the player's records and
##     this week's boards, the server's "guide" answer.

## main.gd (session, hud).
var game: Node
var map_name := ""
var gate_window: HudDungeon
var guide_window: HudDungeonGuide
var run_view: HudDungeonRun
var result_window: HudDungeonResult
var gates: DungeonGates
var hazards: DungeonHazards
var chime: SleepChime
## Step messages shown (the check reads them).
var messages: Array = []
## Every dungeon event by its `event` (the check reads them).
var events: Dictionary = {}
var _message := ""

func setup(main: Node, map_id: String, ui_root: Control) -> void:
	game = main
	map_name = map_id
	name = "MapDungeon"
	gate_window = HudDungeon.new()
	gate_window.session = game.session
	gate_window.hud = game.hud
	gate_window.sheet = game.sheet_view
	ui_root.add_child(gate_window)
	guide_window = HudDungeonGuide.new()
	guide_window.session = game.session
	ui_root.add_child(guide_window)
	result_window = HudDungeonResult.new()
	result_window.session = game.session
	ui_root.add_child(result_window)
	run_view = HudDungeonRun.new()
	run_view.session = game.session
	run_view.result_window = result_window
	ui_root.add_child(run_view)
	ui_root.move_child(run_view, game.hud.get_index() + 1)
	hazards = DungeonHazards.new()
	hazards.session = game.session
	game.add_child(hazards)
	chime = SleepChime.new()
	chime.game = game
	game.add_child(chime)

## The player is in a dungeon copy.
func in_copy() -> bool:
	return game.session != null and int(game.session.copy()) != 0

## The map is drawn: a copy's gates stand on it.
func on_map_built() -> void:
	if in_copy():
		gates = DungeonGates.new()
		game.add_child(gates)

func tick(delta: float) -> void:
	if gates != null:
		gates.sync(game.session.gates(), delta)

## F at a dungeon door: its gate window.
func open_gate(portal_id: String) -> void:
	gate_window.open_at(portal_id)

## A "dungeon" game event (main.gd hands each over).
func on_event(event: Dictionary) -> void:
	var what := String(event.get("event", ""))
	events[what] = int(events.get(what, 0)) + 1
	var view: Dictionary = event.get("view", event)
	match what:
		"info", "refused":
			gate_window.on_event(event)
		"ready":
			gate_window.on_event(event)
			game.hud.invites.on_dungeon_ready(view)
		"cancelled":
			gate_window.on_event(event)
			game.hud.invites.clear_dungeon()
		"launch":
			gate_window.on_event(event)
			result_window.on_event(event)
			game.hud.invites.clear_dungeon()
		"state":
			run_view.on_state(view)
			hazards.sync(view.get("hazards", []))
			chime.sync(view.get("chime"))
			var message := String(view.get("message", ""))
			if message != "" and message != _message:
				# The server words its step messages in English (dungeons.json).
				var shown := I18n.from_server(message)
				messages.append(shown)
				game.hud.show_notice(shown, "info")
			_message = message
		"rewards":
			result_window.on_event(event)
		"hazard":
			hazards.on_hazard(view)
		"guide":
			guide_window.on_event(event)
