extends Node

## `--check-duel`: a duel the way a player fights one, against a running map
## server and a second client run with `--duel-guest NAME` (NAME is this
## client's character), one step at a time:
##
##   land       waits for the joined body and its sheet
##   card       waits for the challenger's duel card (HudInvites)
##   menu       opens the player menu on the challenger: Invite to Party,
##              Challenge to Duel, Group Duel (dimmed: no party)
##   accept     Accept on the card (`/daccept`); waits for the duel to open
##   countdown  sees the pops (3, 2, 1, Fight!), the arena wall and the plaque
##              with its timer; waits for the fight
##   target     Tab until the foe hero is the target (its card says "Duel
##              opponent")
##   fight      the basic cast at the foe every CAST_SECONDS until the server
##              puts it out; counts the hits and their damage numbers on it,
##              the red mark over it, then the grey one
##   banner     waits for the Victory banner
##
## Every step holds HOLD seconds of frame time on screen (captures). The
## verdict prints what it saw and quits 0 when every step was seen, with no
## correction.
##
## `--duel-guest NAME` makes this client the second one: it walks a few steps
## south off the spawn point both share, then challenges NAME
## (`/duel NAME`) every GUEST_RETRY seconds until the server answers
## "Challenge sent.", stands while NAME fights it, and quits 0 once it heard
## that it lost (or 1 after `--guest-seconds`, default 150).

const HOLD := 1.6
const STEP_TIMEOUT := 40.0
const TOTAL_TIMEOUT := 220.0
const CAST_SECONDS := 0.6
const TAB_SECONDS := 0.3
const GUEST_RETRY := 4.0
## How long the guest walks off the spawn point before it challenges.
const GUEST_WALK_SECONDS := 0.8
## A challenge the server holds this long (REQUEST_TICKS) is asked again.
const CHALLENGE_TTL := 30.0

var game: Node
var guest_of := ""
var _step := "land"
var _since := 0.0
var _held := 0.0
var _started := 0.0
var _sent := false
var _next_action := 0.0
var _failure := ""
## What it saw.
var _card := ""
var _card_kind := ""
var _menu := ""
var _menu_dimmed := false
var _accepted := false
var _arena := ""
var _plaque := ""
var _plaque_time := ""
var _foe := 0
var _foe_name := ""
var _tabs := 0
var _target_rank := ""
var _casts := 0
var _hits := 0
var _damage := 0
var _numbers := 0
var _foe_lowest_hp := 255
var _foe_statuses := 0
var _mark_red := false
var _mark_grey := false
var _out_seen := false
var _banner := ""
var _result: Dictionary = {}
## The guest: challenges asked and whether one went out.
var _guest_asks := 0
var _guest_next := 0.0
var _guest_sent_at := 0.0
var _guest_sent_seen := 0
var _guest_joined_at := 0.0
var _guest_ended_at := 0.0

func _ready() -> void:
	_started = _now()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go(step: String) -> void:
	print("realm check duel: frame %d step %s" % [Engine.get_frames_drawn(), step])
	_step = step
	_since = _now()
	_held = 0.0
	_sent = false

## Every combat event main.gd shows: the player's own hits on the foe.
func on_combat(event: Dictionary) -> void:
	if guest_of != "" or _foe == 0 or String(event.get("kind", "")) != "hit":
		return
	if int(event["attacker"]) != int(game.session.own_entity()) or int(event["target"]) != _foe:
		return
	_hits += 1
	_damage += int(event.get("amount", 0))
	_foe_lowest_hp = mini(_foe_lowest_hp, int(event.get("hp", 255)))
	# CombatView floats the number over a body it draws.
	if game.drawn.has(_foe):
		_numbers += 1

func _process(delta: float) -> void:
	if game == null or not game.built or game.session.status() != "joined" or game.session.sheet().is_empty():
		if _now() - _started > TOTAL_TIMEOUT:
			_fail("never joined")
		return
	if guest_of != "":
		_guest()
		return
	_held += delta
	if _now() - _started > TOTAL_TIMEOUT:
		_fail("timed out in step " + _step)
		return
	if _step != "land" and _now() - _since > STEP_TIMEOUT:
		_fail("step %s timed out" % _step)
		return
	var duel: HudDuel = game.hud.duel_view
	_face(_foe if _foe != 0 else _challenger())
	match _step:
		"land":
			if _held > HOLD:
				_go("card")
		"card":
			var card: HudInvites.InviteCard = game.hud.invites.card_of("duel")
			if card != null:
				_card = card.from_name
				_card_kind = card.kind
				if _held > HOLD:
					_go("menu")
		"menu":
			if _open_menu() and _held > HOLD:
				var menu: HudPlayerMenu = game.hud.player_menu
				var shown := PackedStringArray()
				for entry: Dictionary in menu.entries():
					shown.append(String(entry["text"]) + (" (dimmed)" if entry["blocked"] else ""))
					if String(entry["text"]) == tr("Group Duel") and entry["blocked"]:
						_menu_dimmed = true
				_menu = "%s: %s" % [menu.target_name, ", ".join(shown)]
				menu.close()
				_go("accept")
		"accept":
			if not _sent:
				var card: HudInvites.InviteCard = game.hud.invites.card_of("duel")
				if card != null:
					_sent = true
					card.answer(true)
			if duel.active():
				_accepted = true
				var foes: Array = duel.state().get("foes", [])
				if not foes.is_empty():
					_foe = int(foes[0]["entity"])
					_foe_name = String(foes[0]["name"])
				_go("countdown")
		"countdown":
			var arena: MeshInstance3D = duel.arena()
			if arena != null and arena.is_inside_tree():
				var mesh := arena.mesh as CylinderMesh
				_arena = "%s r %.0f m h %.0f m at %s" % [arena.name, mesh.top_radius, mesh.height,
					str(arena.global_position.snapped(Vector3(0.1, 0.1, 0.1)))]
			if duel.plaque_visible():
				_plaque = duel.plaque_sides()
				_plaque_time = duel.plaque_time()
			if duel.fighting() and duel.pops_shown.size() >= 2 and _held > 0.5:
				_go("target")
		"target":
			if game.target != _foe and _now() >= _next_action:
				_next_action = _now() + TAB_SECONDS
				_tabs += 1
				game.cycle_target()   # Tab
			_note_foe()
			if game.target == _foe and _held > HOLD * 0.5:
				_target_rank = String(game.hud.target_rank.text)
				_go("fight")
		"fight":
			if game.target != _foe and duel.is_foe(_foe):
				game.cycle_target()
				_tabs += 1
			if duel.is_foe(_foe) and _now() >= _next_action:
				_next_action = _now() + CAST_SECONDS
				_casts += 1
				game.cast_spell("basic_cast")
			_note_foe()
			if (duel.state().get("out", PackedInt32Array()) as PackedInt32Array).has(_foe):
				_out_seen = true
			if not duel.last_result.is_empty():
				_go("banner")
		"banner":
			if duel.banner_visible() and not duel.last_result.is_empty():
				_result = duel.last_result
				_banner = "%s / %s" % [_result["title"], _result["sub"]]
				if _held > HOLD:
					_go("done")
		"done":
			if _held > HOLD:
				_verdict()

## The foe hero's mark and status as drawn.
func _note_foe() -> void:
	var hero: Node = game.heroes.get(_foe)
	if hero == null:
		return
	_mark_red = _mark_red or int(hero.duel_mark) == HeroView.DUEL_FOE
	_mark_grey = _mark_grey or int(hero.duel_mark) == HeroView.DUEL_OUT
	_foe_statuses |= int(hero.status)

## The challenger's entity (the client knows its name from the server's
## answer when it came into view).
func _challenger() -> int:
	for id: int in game.player_names:
		if String(game.player_names[id]) == _card and game.heroes.has(id):
			return id
	return 0

## The camera turns toward the foe (or the challenger), so captures show it.
func _face(id: int) -> void:
	var hero: Node3D = game.heroes.get(id)
	if hero == null:
		return
	var me: Vector3 = game.session.own_position()
	var flat := Vector2(hero.global_position.x - me.x, hero.global_position.z - me.z)
	if flat.length() > 0.3:
		game.cam_yaw = atan2(-flat.x, -flat.y)

## The player menu on the challenger's body; true once it is open.
func _open_menu() -> bool:
	var menu: HudPlayerMenu = game.hud.player_menu
	if menu.is_open():
		return true
	var id := _challenger()
	if id == 0:
		return false
	var body: Node3D = game.heroes[id]
	var at: Vector2 = game.camera.unproject_position(body.global_position + Vector3(0, 1.2, 0))
	game.open_player_menu(id, at)
	return menu.is_open()

## The guest's walk off the shared spawn point: forward (1) while it walks,
## else 0. main.gd reads it as the movement intent.
func walk_intent() -> float:
	if guest_of == "" or _guest_joined_at == 0.0:
		return 0.0
	return 1.0 if _now() - _guest_joined_at < GUEST_WALK_SECONDS else 0.0

## The second client: first a few steps south off the spawn point both
## clients share (so the foe stands apart, against the open field), then the
## challenge until the server says it went out (again when it would have
## expired unanswered), then it stands until the duel ends.
func _guest() -> void:
	var now := _now()
	if _guest_joined_at == 0.0:
		_guest_joined_at = now
		game.cam_yaw = PI
	if now - _guest_joined_at < GUEST_WALK_SECONDS + 0.5:
		return
	var duel: HudDuel = game.hud.duel_view
	var sent := _system_said(I18n.from_server("Challenge sent."))
	if sent > _guest_sent_seen:
		_guest_sent_seen = sent
		_guest_sent_at = now
		print("realm guest: challenge to %s sent after %d asks" % [guest_of, _guest_asks])
	if not duel.active() and duel.last_result.is_empty() and now >= _guest_next \
			and (_guest_sent_at == 0.0 or now - _guest_sent_at > CHALLENGE_TTL):
		game.session.send_chat("/duel " + guest_of)
		_guest_asks += 1
		_guest_next = now + GUEST_RETRY
	if not duel.last_result.is_empty() and _guest_ended_at == 0.0:
		_guest_ended_at = now
	var timed_out := now - _started > float(game._arg("--guest-seconds", "150"))
	if (_guest_ended_at > 0.0 and now - _guest_ended_at > 3.0) or timed_out:
		var lines: Array = game.hud.chat.lines().filter(func(l): return int(l["channel"]) == HudChat.SYSTEM) \
			.map(func(l): return String(l["text"]))
		print("realm guest: challenged %s (%d asks), duels %d, result %s | system: %s" % [guest_of, _guest_asks,
			duel.duels_shown, duel.last_result, " / ".join(lines)])
		get_tree().quit(0 if String(duel.last_result.get("result", "")) == "lost" else 1)

## How many system lines in the log say exactly `text`.
func _system_said(text: String) -> int:
	var count := 0
	for line: Dictionary in game.hud.chat.lines():
		if int(line["channel"]) == HudChat.SYSTEM and String(line["text"]) == text:
			count += 1
	return count

func _fail(why: String) -> void:
	_failure = why
	_verdict()

func _verdict() -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var duel: HudDuel = game.hud.duel_view
	var corrections := int(stats.get("corrections", 0))
	var system_lines: Array = game.hud.chat.lines().filter(func(l): return int(l["channel"]) == HudChat.SYSTEM) \
		.map(func(l): return String(l["text"]))
	var pops := ", ".join(duel.pops_shown)
	print("realm check duel: %s | card %s from \"%s\" | menu [%s] | accepted %s | pops [%s] | arena %s | plaque \"%s\" %s" % [
			"ok" if _failure == "" else _failure, _card_kind, _card, _menu, _accepted, pops, _arena if _arena != "" else "-",
			_plaque, _plaque_time],
		" | foe %s (%d), %d tabs, target card \"%s\" | %d casts, %d hits for %d damage, %d numbers, foe lowest hp byte %d, statuses %d | mark red %s, grey %s, out %s" % [
			_foe_name, _foe, _tabs, _target_rank, _casts, _hits, _damage, _numbers, _foe_lowest_hp, _foe_statuses,
			_mark_red, _mark_grey, _out_seen],
		" | banner \"%s\", result %s | system [%s]" % [_banner, _result, " / ".join(system_lines)],
		" | corrections %d (max %.3f m), snapshots %d" % [corrections, float(stats.get("max_correction", 0.0)),
			int(stats.get("snapshots", 0))])
	var counted := duel.pops_shown.size() >= 4 and duel.pops_shown[duel.pops_shown.size() - 1] == I18n.upper(tr("Fight!"))
	var passed := _failure == "" and _card_kind == "duel" and _card != "" and _menu.contains(tr("Challenge to Duel")) \
		and _menu_dimmed and _accepted and counted and _arena != "" and _plaque != "" and _plaque_time != "" \
		and _foe != 0 and _target_rank != "" and _hits > 0 and _numbers > 0 and _mark_red and _out_seen \
		and String(_result.get("result", "")) == "won" and _banner != "" and corrections == 0 \
		and int(stats.get("snapshots", 0)) > 0
	get_tree().quit(0 if passed else 1)
