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
##     floor (DungeonHazards, from the "hazard" events and the run views).
##     A run with a sleep chime (the Sealed Wing's, by Threehead) shows it
##     from the run view's `chime` (SleepChime).
##   * The end of a run takes no window: one line on the notice band (the
##     medal and the time, once the run's last step message has had its
##     moment) and the facts and the "rewards" that follow as chat lines
##     (the clock, clear and deaths; why there is no medal; the experience,
##     oril, the final chest's contents, a difficulty opened, a title).
##   * The guide (K, anywhere: HudDungeonGuide): the player's records and
##     this week's boards, the server's "guide" answer. In a finished copy
##     it also carries "Run it again" (the leader's: another run from the
##     finished copy, the ready check and the launch as at the gate); at the
##     gate outside, the gate window's difficulty cards start the next run.

## main.gd (session, hud).
var game: Node
var map_name := ""
var gate_window: HudDungeon
var guide_window: HudDungeonGuide
var run_view: HudDungeonRun
var gates: DungeonGates
var hazards: DungeonHazards
var chime: SleepChime
## Step messages shown (the check reads them).
var messages: Array = []
## Every dungeon event by its `event` (the check reads them).
var events: Dictionary = {}
## The finished run's view ({} until the run completes), the notice band's
## line about it and the chat lines said about its end (the check reads
## them).
var outcome: Dictionary = {}
var outcome_notice := ""
var outcome_notice_shown := false
var outcome_lines: Array = []
var _message := ""
## When the result's notice line shows (seconds on the ticks clock; 0 none).
var _notice_due := 0.0
## Rewards heard before the run's result (the server may send them first):
## said after it, or on their own if no result follows within a moment.
var _early_rewards: Dictionary = {}
var _early_at := 0.0

## The result's line waits this long after the run's last step message.
const RESULT_NOTICE_DELAY := 3.2

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
	run_view = HudDungeonRun.new()
	run_view.session = game.session
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
	if _notice_due > 0.0 and Time.get_ticks_msec() / 1000.0 >= _notice_due:
		_notice_due = 0.0
		outcome_notice_shown = true
		var medal := _medal() != ""
		game.hud.show_notice(outcome_notice, "good" if medal else "info")
		AudioManager.play_sound_at("ui_confirm" if medal else "ui_open", Vector3.ZERO, null, true)
	if not _early_rewards.is_empty() and Time.get_ticks_msec() / 1000.0 - _early_at > 2.0:
		var rewards := _early_rewards
		_early_rewards = {}
		_say_rewards(rewards, true)

## F at a dungeon door: its gate window.
func open_gate(portal_id: String) -> void:
	gate_window.open_at(portal_id)

## A "dungeon" game event (main.gd hands each over).
func on_event(event: Dictionary) -> void:
	var what := String(event.get("event", ""))
	events[what] = int(events.get(what, 0)) + 1
	var view: Dictionary = event.get("view", event)
	match what:
		"info":
			gate_window.on_event(event)
		"refused":
			gate_window.on_event(event)
			guide_window.on_event(event)
		"ready":
			gate_window.on_event(event)
			game.hud.invites.on_dungeon_ready(view)
		"cancelled":
			gate_window.on_event(event)
			guide_window.on_event(event)
			game.hud.invites.clear_dungeon()
		"launch":
			gate_window.on_event(event)
			guide_window.on_event(event)
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
			if bool(view.get("complete", false)) and view.get("result") is Dictionary and outcome.is_empty():
				_say_result(view, message != "")
		"rewards":
			_say_rewards(event)
		"hazard":
			hazards.on_hazard(view)
		"guide":
			guide_window.on_event(event)

## ------------------------------------------------------------- the run's end

## The finished run's medal ("" none).
func _medal() -> String:
	var result: Dictionary = outcome.get("result", {})
	return String(DungeonData.RANK_MEDALS.get(int(result.get("rank", -1)), ""))

## The run is over: its line on the notice band (after the run's last step
## message, which says where the reward waits, when one came with it) and
## its facts in the chat; the guide (K) offers the replay from here.
func _say_result(view: Dictionary, after_message: bool) -> void:
	outcome = view
	var result: Dictionary = view.get("result", {})
	var timeout := bool(result.get("timeout", false))
	var medal := _medal()
	var names := {"gold": tr("Gold"), "silver": tr("Silver"), "bronze": tr("Bronze"), "": tr("No medal")}
	var medal_name := String(names.get(medal, names[""]))
	var time := DungeonData.clock(float(result.get("time_ms", 0)) / 1000.0)
	var difficulty := DungeonData.difficulty_id(int(view.get("difficulty", 1)))
	outcome_notice = "%s · %s · %s" % [I18n.upper(tr("Time Is Up") if timeout else tr("Dungeon Complete")), medal_name, time]
	var clear := float(result.get("clear", 0)) / 1000.0
	_chat("%s - %s: %s · %s · %s · %s" % [DungeonData.display_name(String(view.get("dungeon", ""))),
		DungeonData.difficulty_name(difficulty), medal_name, time,
		tr("Clear %s%%") % I18n.whole(int(floor(clear * 100.0))), tr("Deaths %d") % int(result.get("deaths", 0))])
	if medal == "":
		var medals := DungeonData.medals()
		var why := tr("The run was too slow for a medal.")
		if timeout:
			why = tr("Time ran out (%s) - the run ended where it stood.") % DungeonData.clock(
				float(view.get("par_s", 0.0)) * float(medals.get("limit", 2.0)))
		elif clear < 1.0:
			why = tr("A medal needs every creature cleared, side rooms included.")
		elif bool(view.get("broken", false)):
			why = tr("The party's lives ran out.")
		_chat(why)
	guide_window.finished_run(view)
	if guide_window.replay_portal() != "" and guide_window.leads():
		_chat(tr("Run it again from the Dungeon Guide (%s).") % GameSettings.key_name("dungeon_guide"))
	# the step message keeps the band a moment; with none, the line shows now
	_notice_due = Time.get_ticks_msec() / 1000.0 + (RESULT_NOTICE_DELAY if after_message else 0.0) + 0.001
	if not _early_rewards.is_empty():
		_say_rewards(_early_rewards)
		_early_rewards = {}

## What this player earned (the server's "rewards"), as chat lines: the
## experience and oril, the final chest's contents (it waits at the end of
## the dungeon), a difficulty newly opened, a title.
func _say_rewards(rewards: Dictionary, alone := false) -> void:
	if outcome.is_empty() and not alone:
		_early_rewards = rewards
		_early_at = Time.get_ticks_msec() / 1000.0
		return
	if bool(rewards.get("helper", false)):
		_chat(tr("You came as a helper: no final chest today."))
	else:
		_chat("%s: %s · %s" % [tr("Your rewards"), tr("+%s EXP") % I18n.whole(int(rewards.get("exp", 0))),
			tr("+%s Oril") % I18n.whole(int(rewards.get("oril", 0)))])
		var parts: Array[String] = []
		for item: Array in rewards.get("items", []):
			var id := String(item[0])
			var amount := int(item[1])
			var item_name := I18n.t(String(ItemRules.item(id).get("name", id)))
			if int(item[2]) > 0:
				item_name += " " + tr("(%d enchantments)") % int(item[2])
			parts.append(item_name if amount == 1 else "%s x%s" % [item_name, I18n.whole(amount)])
		if not parts.is_empty():
			_chat(tr("In your chest: %s") % ", ".join(PackedStringArray(parts)))
	for index: Variant in rewards.get("unlocked", []):
		_chat(tr("Unlocked: %s") % DungeonData.difficulty_name(DungeonData.difficulty_id(int(index))))
	var title := String(rewards.get("title", ""))
	if title != "":
		_chat(tr("New title earned: %s!") % I18n.t(title))

func _chat(text: String) -> void:
	outcome_lines.append(text)
	game.hud.chat.add_system_line(text)
