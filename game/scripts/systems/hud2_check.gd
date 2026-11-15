extends "res://scripts/systems/dungeon_check.gd"

## `--check-hud2`: the HUD parity pieces as a player meets them, on the
## dungeon check's road (build/logs/aup_hud2.sh; --character 901101, the
## Trial Hall kit, hurt to a fifth of its health). Captures go to
## `--capture-dir` (build/captures/hud2). Before the gate:
##
##   hud_land   lands hurt: the low-health edge (LowHpVignette) is drawn,
##              the custom pointers are in (capture)
##   taskbar    each window button on the taskbar opens its window and
##              closes it again; the character window's Status and
##              Properties pages (captures); B opens the bestiary on a
##              creature (capture)
##   effects    learns Ward Shield if it must and casts it: the server's
##              effect list carries the ward and the bar under the unit
##              frame shows it counting down (capture)
##   ring       a training dummy taken as the target from a few metres: the
##              ring of light under it (capture); dropped, the ring goes
##   world      the grounds' world bosses stir (the server raises them
##              soon): the realm-wide notice and its "[World]" chat line
##              (capture); the words for a boss slain by a named player and
##              for a Legendary gold are checked on made-up notices (no
##              level-12 character can make them happen)
##   safe_in    walks into the castle courtyard: the protected-ground cue
##              over the taskbar (capture)
##   safe_out   walks back out: the cue's leaving line (capture), then it goes
##
## then the dungeon check's own steps (the gate, the copy, the fight), and
## at the result window:
##
##   result     the medal and "Run it again" shown and enabled for the
##              player alone (its own leader); the week's record title
##              earned on this first clear shows its "New title" toast
##              (capture); "Run it again"
##   replay     the server starts another run from the finished copy: the
##              launch, the loading screen, and a new copy of the Trial
##              Hall with its run gathering (capture)
##
## The verdict line says what was seen and quits 0 only when all was.

const HUD_STEPS := ["hud_land", "taskbar", "effects", "ring", "world", "safe_in", "safe_out", "replay_copy", "replay_wait"]
## Where the castle courtyard's protected ground is walked into (inside its
## edge) from the Trial Hall gate.
const SAFE_INSIDE := Vector2(28.0, 66.0)
const WORLD_WAIT := 120.0
const TITLE_WAIT := 20.0
const MY_TIMEOUT := 900.0

var _sub := 0
var _sub_at := 0.0

func _ready() -> void:
	super._ready()
	if String(_s["step"]) == "land" and not _s.has("hud2"):
		_s["hud2"] = true
		_s["step"] = "hud_land"

func _say(text: String) -> void:
	print("realm check hud2: frame %d %s" % [Engine.get_frames_drawn(), text])

func _seen2(what: String, detail: Variant = true) -> void:
	if not _has(what):
		_say("seen %s: %s" % [what, detail])
	_seen(what, detail)

## Captures go to `--capture-dir` (a relative path from the realm checkout),
## by default build/captures/hud2.
func _capture(tag: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var dir := String(game._arg("--capture-dir", "build/captures/hud2"))
	if dir.is_relative_path():
		dir = root.path_join(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var image := get_viewport().get_texture().get_image()
	var path := dir.path_join("%02d_%s.png" % [(_s["captures"] as Array).size() + 1, tag])
	if image != null and image.save_png(path) == OK:
		(_s["captures"] as Array).append(path)
		_say("captured %s" % path)

## A real key press and release, as the keyboard sends them.
func _key(keycode: int) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = down
		Input.parse_input_event(event)

func before_reload() -> void:
	var step := String(_s["step"])
	super.before_reload()
	if step == "replay_wait":
		_go("replay_copy")
		Engine.set_meta(STATE_KEY, _s)

func _process(delta: float) -> void:
	var step := String(_s["step"])
	if step == "result":
		_walk = 0.0
		if game != null and game.session != null and _ready_to_play():
			_held += delta
			_result()
		return
	if not HUD_STEPS.has(step):
		super._process(delta)
		return
	_walk = 0.0
	if game == null or game.session == null:
		return
	var now := _now()
	if now - float(_s["started"]) > MY_TIMEOUT and step != "replay_wait":
		_verdict("timed out in step " + step)
		return
	if now - _since > (WORLD_WAIT if step == "world" else STEP_TIMEOUT) and step != "replay_wait":
		_verdict("step %s timed out" % step)
		return
	if not _ready_to_play() and step != "replay_wait":
		return
	_held += delta
	match step:
		"hud_land":
			var vignette: LowHpVignette = game.vignette
			if _held > HOLD and vignette.visible and vignette.strength > 0.25:
				var vitals: PackedInt32Array = game.session.vitals()
				_seen2("low_hp", "health %d / %d, edge %.2f" % [vitals[0], vitals[1], vignette.strength])
				_seen2("cursors", "%d pointers installed" % CursorKit.installed)
				_capture("low_hp_vignette")
				_sub = 0
				_go("taskbar")
		"taskbar":
			_taskbar()
		"effects":
			_effects()
		"ring":
			_ring()
		"world":
			_world()
		"safe_in":
			var cue: SafeZoneCue = game.safe_cue
			if cue.zone != "":
				if not _has("safe_in"):
					_seen2("safe_in", "zone %s, \"%s\"" % [cue.zone, cue._label.text])
					_held = 0.0
				elif _held > 0.6:
					_capture("safe_in")
					_go("safe_out")
			else:
				if _walk_to(SAFE_INSIDE.x, SAFE_INSIDE.y) > 0.8:
					_walk = 1.0
		"safe_out":
			var cue: SafeZoneCue = game.safe_cue
			if cue.zone == "":
				if not _has("safe_out"):
					if not cue.visible:
						_verdict("leaving protected ground showed nothing")
						return
					_seen2("safe_out", "crossings %s, \"%s\"" % [str(cue.crossings), cue._label.text])
					_held = 0.0
				elif _held > 0.4:
					_capture("safe_out")
					# the dungeon check's clock starts at its own first step
					_s["started"] = _now()
					_go("to_gate")
			else:
				_walk_to(GATE_AT.x, GATE_AT.y)
				_walk = 1.0
		"replay_wait":
			# Refused (the last kill still holds the party "in combat", as at
			# the gate): the leader asks again once the button is back, as a
			# player would, a few times at most.
			var result: HudDungeonResult = game.dungeon.result_window
			var refusals: Dictionary = _s["refusals"]
			var refused := 0
			for why: String in refusals:
				refused += int(refusals[why])
			if refused > int(_s.get("replay_refusals", 0)) and result.visible and not result.again_button.disabled:
				if _held > 2.0:
					if result.replays_sent >= 8:
						_verdict("Run it again was refused %d times (%s)" % [refused, str(refusals)])
						return
					_s["replay_refusals"] = refused
					_say("asking again after a refusal (%s)" % str(refusals))
					result.again_button.pressed.emit()
					_held = 0.0
			elif _held > 45.0 and not MapLoadingScreen.shared(get_tree()).is_open():
				_verdict("Run it again led nowhere (%d sent, refusals %s)" % [result.replays_sent, str(refusals)])
		"replay_copy":
			var run: HudDungeonRun = game.dungeon.run_view
			var copy := int(game.session.copy())
			if game.map_name == "dng_trial" and copy != 0 and copy != int(_s.get("first_copy", 0)) \
					and run.phase() >= HudDungeonRun.GATHERING and not run.state.is_empty():
				# the new copy's gate in view, as the dungeon check's copy step
				_look_at_gate()
				game.cam_distance = 7.0
				game.cam_pitch = -0.35
				if _held > HOLD:
					_seen2("replay_copy", "copy %d after %d, run phase %d, tracker \"%s\"" % [copy, int(_s.get("first_copy", 0)),
						run.phase(), run.clock_label.text])
					_capture("replay_copy")
					_verdict("")
			elif _held > 30.0:
				_verdict("the replay did not lead into a new copy (%s, copy %d after %d)" % [game.map_name, copy,
					int(_s.get("first_copy", 0))])

## Each window button opens its window and closes it again; the character
## window's pages and the bestiary are captured on the way.
func _taskbar() -> void:
	var hud: Control = game.hud
	var ids: Array = HudKit_ids()
	if _sub < ids.size():
		var id := String(ids[_sub])
		var window := _window_of(id)
		var button: Button = hud.menu_buttons[id]
		if _sub_at == 0.0:
			if window.visible:
				_close(id)
			button.pressed.emit()
			_sub_at = _now()
			return
		if not window.visible:
			if _now() - _sub_at > 2.0:
				_verdict("the %s button did not open its window" % id)
			return
		var held := _now() - _sub_at
		if id == "character":
			var cw: CharacterWindow = game.character_window
			# the page set, a moment, then its capture (the frame shows it)
			if held > 0.6 and not _has("char_status"):
				cw.show_page("status")
				_seen2("char_status", "attack %s, magic %s, armour %s, crit %s, spell power %s, skill %s, oril %s, hp %s" % [
					cw.value_text("attack"), cw.value_text("magic"), cw.value_text("armour"), cw.value_text("crit"),
					cw.value_text("spell_power"), cw.value_text("skill"), cw.value_text("oril"), cw.value_text("hp")])
				return
			if held > 1.0 and not _has("char_status_capture"):
				_seen("char_status_capture", true)
				_capture("character_status")
				return
			if held > 1.4 and not _has("char_props"):
				(cw._tabs["props"] as CharacterWindow.TabChip).chosen.emit()
				_seen2("char_props", "page %s, attack speed %s, move speed %s, pierce %s, block %s, oril found %s" % [cw.page,
					cw.value_text("attack_speed"), cw.value_text("move_speed"), cw.value_text("pierce"), cw.value_text("block"),
					cw.value_text("gold_bonus")])
				return
			if held > 1.8 and not _has("char_props_capture"):
				_seen("char_props_capture", true)
				_capture("character_properties")
				return
			if held < 2.2:
				return
			cw.show_page("status")
		elif held < 0.4:
			return
		_seen2("button_" + id, true)
		_close(id)
		_sub += 1
		_sub_at = 0.0
		return
	# the bestiary through its key (rebindable), on a creature with a portrait
	var bestiary: HudBestiary = game.bestiary
	if _sub == ids.size():
		if bestiary.visible:
			bestiary.close()
		_key(GameSettings.key("bestiary"))
		_sub += 1
		_sub_at = _now()
		return
	if _sub == ids.size() + 1:
		if not bestiary.visible:
			if _now() - _sub_at > 2.0:
				_verdict("B did not open the bestiary")
			return
		bestiary.show_species("troll_forest")
		_seen2("bestiary", "%d creatures listed, showing %s, show-on-map %s" % [bestiary.species().size(), bestiary.selected,
			bestiary.find_child("ShowOnMap", true, false) != null])
		_sub += 1
		_sub_at = _now()
		return
	if _now() - _sub_at > 0.8 and not _has("bestiary_capture"):
		_seen("bestiary_capture", true)
		_capture("bestiary")
		_sub_at = _now()
		return
	if _now() - _sub_at > 0.4 and _has("bestiary_capture") and not _has("taskbar"):
		bestiary.close()
		_seen2("taskbar", "%d window buttons opened and closed" % ids.size())
		_sub_at = _now()
		return
	if _has("taskbar") and _now() - _sub_at > 0.5:
		# every window shut again: the taskbar as it stands
		_capture("taskbar")
		_sub = 0
		_go("effects")

static func HudKit_ids() -> Array:
	var ids: Array = []
	for entry: Array in preload("res://scripts/ui/hud.gd").MENU_BUTTONS:
		ids.append(String(entry[0]))
	return ids

func _window_of(id: String) -> Control:
	match id:
		"workshop":
			return game.workshop
		"quests":
			return game.quest_log
		"character":
			return game.character_window
		"skills":
			return game.skill_window
		"map":
			return game.way.world_map
		"bestiary":
			return game.bestiary
		"dungeons":
			return game.dungeon.guide_window
		"menu":
			return game.game_menu
	return null

func _close(id: String) -> void:
	match id:
		"workshop":
			# the workshop docks beside the bag it opened
			game.workshop.hide()
			game.inventory.hide()
		"character":
			game.character_window.card.close()
		_:
			_window_of(id).call("close")

## Ward Shield: learnt if it must be, cast; the bar shows it.
func _effects() -> void:
	var bar: HudBuffBar = game.hud.buff_bar
	if bar.kinds().has("ward"):
		if not _has("effect_ward"):
			var effects: Array = game.session.effects()
			_seen2("effect_ward", "server list %s, bar %s" % [str(effects), str(bar.kinds())])
			_held = 0.0
		elif _held > 0.5:
			_capture("effects_bar")
			_sub_at = 0.0
			_go("ring")
		return
	if _sub == 0 and int(game.session.skill_level("ward_shield")) == 0:
		game.session.learn_skill("ward_shield")
		_sub = 1
		_sub_at = _now()
		return
	if int(game.session.skill_level("ward_shield")) > 0 and _now() - _sub_at > 1.5:
		_sub_at = _now()
		_s["casts"] = int(_s["casts"]) + 1
		game.session.cast("ward_shield", 0, _me() + Vector3(0, 1.0, 0))

## The realm's news: a "[World]" line from the world bosses stirring.
func _world() -> void:
	if not _has("notice_words"):
		var slain := String(game.notice_text({"kind": "boss_slain", "subject": "Grak", "actor": "Vela"})[0])
		var legend := String(game.notice_text({"kind": "dungeon_legend", "subject": "Trial Hall", "actor": "Vela, Oren"})[0])
		if slain.find("Vela") < 0 or legend.find("Vela, Oren") < 0:
			_verdict("the notice words lose the names: \"%s\" / \"%s\"" % [slain, legend])
			return
		_seen2("notice_words", "\"%s\" / \"%s\"" % [slain, legend])
	if game.world_lines.is_empty():
		return
	if not _has("world_line"):
		_seen2("world_line", "\"%s\"" % game.world_lines[0])
		_held = 0.0
	elif _held > 0.5:
		_capture("world_line")
		_go("safe_in")

## The ring under the target: the training yard's nearest dummy (it stands
## still and never falls) taken as the target from a few metres, the camera
## looking down at it; captured a moment after the ring closed in, then the
## target is dropped and the ring goes.
func _ring() -> void:
	var ring: TargetRing = game.target_ring
	var dummy := 0
	var best := INF
	for id: int in game.beasts:
		if game.beasts[id] is DummyView and game.drawn.has(id) and _me().distance_to(game.drawn[id]) < best:
			best = _me().distance_to(game.drawn[id])
			dummy = id
	if dummy == 0:
		_walk_to(78.0, 30.0)
		_walk = 1.0
		return
	var at: Vector3 = game.drawn[dummy]
	if best > 9.0 and _sub_at == 0.0:
		_walk_to(at.x, at.z)
		_walk = 1.0
		return
	if _sub_at == 0.0:
		game.select_target(dummy)
		_sub_at = _now()
		game.cam_distance = 6.0
		game.cam_pitch = -0.75
	_face(at)
	if _has("target_ring"):
		if not ring.visible and game.target == 0:
			_seen2("ring_gone", true)
			game.cam_pitch = -0.35
			game.cam_distance = 9.0
			_sub_at = 0.0
			_go("world")
		return
	if ring.visible and ring.target == dummy and _now() - _sub_at > 0.9:
		_seen2("target_ring", "dummy %d %.1f m away, radius %.1f, colour %s" % [dummy, best, ring.radius, ring.tint])
		_capture("target_ring")
		game.select_target(0)

## The result window: "Run it again" for the leader, the record title's
## toast, then the replay.
func _result() -> void:
	var result: HudDungeonResult = game.dungeon.result_window
	if not result.visible or result.rewards.is_empty():
		return
	if not _sent:
		_sent = true
		_held = 0.0
		_s["first_copy"] = int(game.session.copy())
		_seen2("result_window", "medal %s, again %s %s" % [result.medal if result.medal != "" else "none",
			"shown" if result.again_button.visible else "hidden", "enabled" if not result.again_button.disabled else "disabled"])
		_seen("complete", true)
		if not result.again_button.visible or result.again_button.disabled:
			_verdict("Run it again is not offered to the leader")
			return
	var titled: bool = (game.titles_toasted as Array).has("dungeon_record")
	if titled and not _has("title_toast"):
		_seen2("title_toast", "toasts %s, last \"%s\"" % [str(game.titles_toasted), game.feedback.last_toast])
		_sub_at = _now()
		return
	if titled and not _has("title_capture"):
		# the gold line over the player and the toast, settled
		if _now() - _sub_at > 0.5:
			_seen("title_capture", true)
			_capture("title_toast")
		return
	if _held < HOLD or (not titled and _held < TITLE_WAIT):
		return
	_capture("result")
	_seen2("replay_pressed", "portal %s, difficulty %d" % [result.portal(), result.difficulty])
	result.again_button.pressed.emit()
	_go("replay_wait")

func _verdict(failure: String) -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var corrections := int(_s["corrections"]) + int(stats.get("corrections", 0))
	var seen: Dictionary = _s["seen"]
	var wanted := ["low_hp", "cursors", "char_status", "char_props", "bestiary", "taskbar", "effect_ward", "notice_words",
		"world_line", "safe_in", "safe_out", "gate_window", "copy", "running", "target_ring", "ring_gone", "result_window", "title_toast",
		"replay_pressed", "replay_copy"]
	for entry: Array in preload("res://scripts/ui/hud.gd").MENU_BUTTONS:
		wanted.append("button_" + String(entry[0]))
	var missing := wanted.filter(func(k): return not seen.has(k))
	var ok := failure == "" and missing.is_empty() and corrections == 0
	print("realm check hud2: %s | maps [%s], %d reloads | seen {%s} | missing [%s]" % [
			"ok" if ok else (failure if failure != "" else "incomplete"), ", ".join(_s["maps"]), int(_s["reloads"]),
			" ; ".join(seen.keys().map(func(k): return "%s: %s" % [k, seen[k]])), ", ".join(missing)],
		" | %d casts, %d own hits, %d rises | refusals {%s} | effects shown %s" % [int(_s["casts"]),
			int(_s["hits"]) + int(game.check_hits), int(_s["deaths"]),
			", ".join((_s["refusals"] as Dictionary).keys().map(func(k): return "%s x%d" % [k, _s["refusals"][k]])),
			str(game.hud.buff_bar.shown.keys())],
		" | captures %d | corrections %d (this map max %.3f m), snapshots %d" % [(_s["captures"] as Array).size(),
			corrections, float(stats.get("max_correction", 0.0)), int(stats.get("snapshots", 0))])
	for path in _s["captures"]:
		print("realm check hud2: capture ", path)
	Engine.remove_meta(STATE_KEY)
	get_tree().quit(0 if ok else 1)
