extends Node

## `--check-social`: chat and the party the way a player uses them, against a
## running map server, the coordinator and a scripted partner
## (`realm_netcheck --social-partner`, "Wanderer 103"), one step at a time:
##
##   land     waits for the joined body and its sheet
##   say      Enter opens the chat, a local line is typed and sent; waits for
##            the line in the log under the player's own name and its bubble
##            over the player's head
##   invite   "/invite Wanderer 103" through the chat; waits for a party of two
##            in RealmSession.party() and the partner's row in the party frames
##   hear     waits for the partner's party line and its shout in the log
##   log      Enter again: the full scroll-back, every channel in its colour
##   leave    "/leave"; waits for the party to dissolve and the row to go
##
## With `--check-invite-from NAME` (a second client run with `--social-guest`)
## it goes on: waits for NAME's invitation card, opens the player menu on NAME
## (named by its local line), accepts on the card, opens the menu again
## (Invite dimmed: already in the party) and leaves again.
##
## Every step holds HOLD seconds of frame time on screen (captures). The
## verdict prints what it saw and quits 0 when every step was seen, with no
## correction.
##
## `--social-guest NAME` makes this client the second one: it says a local
## line, then invites NAME, again every GUEST_RETRY seconds until the
## coordinator answers that the invitation was sent (and again when it says
## that one expired), and quits after `--guest-seconds` (default 90).

const PARTNER := "Wanderer 103"
const SAY_LINE := "Well met, wanderers of the realm!"
const GUEST_LINE := "Over here - I will send you an invitation."
const HOLD := 1.6
## A step may wait this long (an invitation that expired comes again).
const STEP_TIMEOUT := 45.0
const TOTAL_TIMEOUT := 200.0
const GUEST_RETRY := 4.0

var game: Node
var guest_of := ""
var invite_from := ""
var _step := "land"
var _since := 0.0
var _held := 0.0
var _started := 0.0
var _sent := false
var _failure := ""
## What it saw.
var _own_line := false
var _bubble := ""
var _party_seen := ""
var _rows_seen := 0
var _partner_party_line := false
var _partner_shout := false
var _left := false
var _card_from := ""
var _menu_entries := ""
var _accepted := ""
var _menu_dimmed := ""
var _left_again := false
## The guest: invitations asked for and whether one went out.
var _guest_asks := 0
var _guest_next := 0.0
var _guest_said := false
var _guest_sent := false

func _ready() -> void:
	_started = _now()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go(step: String) -> void:
	print("realm check social: frame %d step %s" % [Engine.get_frames_drawn(), step])
	_step = step
	_since = _now()
	_held = 0.0
	_sent = false

func _process(delta: float) -> void:
	if game == null or not game.built or game.session.status() != "joined" or game.session.sheet().is_empty():
		if _now() - _started > TOTAL_TIMEOUT:
			_fail("never joined")
		return
	if guest_of != "":
		_guest()
		return
	_held += delta
	_face_nearest()
	if _now() - _started > TOTAL_TIMEOUT:
		_fail("timed out in step " + _step)
		return
	if _step != "land" and _now() - _since > STEP_TIMEOUT:
		_fail("step %s timed out" % _step)
		return
	var chat: HudChat = game.hud.chat
	var party: Dictionary = game.session.party()
	var frames: HudParty = game.hud.party_frames
	match _step:
		"land":
			if _held > HOLD:
				_go("say")
		"say":
			if not _sent:
				_sent = true
				chat.open()
				chat.input.text = SAY_LINE
			elif chat.input.text != "" and _held > HOLD:
				chat.submit(chat.input.text)
			if not _own_line:
				_own_line = _heard(HudChat.LOCAL, _own_name(), SAY_LINE)
			var bubble: Node = game.player.get_node_or_null("SpeechBubble")
			if bubble != null:
				_bubble = String(bubble.text)
			if _own_line and _bubble == SAY_LINE and _held > HOLD * 2.0:
				_go("invite")
		"invite":
			_type_and_send("/invite " + PARTNER)
			var members: Array = party.get("members", [])
			if int(party.get("party", 0)) != 0 and members.size() == 2:
				_party_seen = ", ".join(members.map(func(m): return "%s Lv %d %s %d/%d" % [m["name"], m["level"], m["house"],
					m["hp"], m["max_hp"]]))
				_rows_seen = frames.row_count()
				if _rows_seen == 1 and _held > HOLD:
					_go("hear")
		"hear":
			_partner_party_line = _partner_party_line or _heard(HudChat.PARTY, PARTNER, "")
			_partner_shout = _partner_shout or _heard(HudChat.SHOUT, PARTNER, "")
			if _partner_party_line and _partner_shout and _held > HOLD:
				_go("log")
		"log":
			if not _sent:
				_sent = true
				chat.open()
			elif _held > HOLD * 1.5:
				chat.close()
				_go("leave")
		"leave":
			_type_and_send("/leave")
			if _sent and int(party.get("party", 0)) == 0 and frames.row_count() == 0 and _held > HOLD:
				_left = true
				_go("card" if invite_from != "" else "done")
		"card":
			var card: HudInvites.InviteCard = game.hud.invites.card_of("party")
			if card != null and card.from_name == invite_from:
				_card_from = card.from_name
				if _held > HOLD:
					_go("menu")
		"menu":
			if _open_menu() and _held > HOLD:
				_menu_entries = _entries_text()
				game.hud.player_menu.close()
				_go("accept")
		"accept":
			if not _sent:
				var card: HudInvites.InviteCard = game.hud.invites.card_of("party")
				if card != null:
					_sent = true
					card.answer(true)
			var members: Array = party.get("members", [])
			if members.any(func(m): return String(m["name"]) == invite_from) and frames.row_count() == 1 and _held > HOLD:
				_accepted = ", ".join(members.map(func(m): return "%s Lv %d %s" % [m["name"], m["level"], m["house"]]))
				_go("menu2")
		"menu2":
			if _open_menu() and _held > HOLD:
				_menu_dimmed = _entries_text()
				game.hud.player_menu.close()
				_go("leave2")
		"leave2":
			_type_and_send("/leave")
			if _sent and int(party.get("party", 0)) == 0 and frames.row_count() == 0 and _held > HOLD:
				_left_again = true
				_go("done")
		"done":
			if _held > HOLD:
				_verdict()

## Type `line` into the chat and send it (once per step).
func _type_and_send(line: String) -> void:
	var chat: HudChat = game.hud.chat
	if not _sent:
		_sent = true
		chat.open()
		chat.input.text = line
	elif chat.input.text != "" and _held > 0.6:
		chat.submit(chat.input.text)

func _own_name() -> String:
	return String(game.session.sheet().get("name", ""))

## A line on `channel` from `from` in the log (`text` empty: any text).
func _heard(channel: int, from: String, text: String) -> bool:
	for line: Dictionary in game.hud.chat.lines():
		if int(line["channel"]) == channel and String(line["from"]) == from \
				and (text == "" or String(line["text"]).ends_with(text)):
			return true
	return false

## How many system lines in the log say exactly `text`.
func _system_said(text: String) -> int:
	var count := 0
	for line: Dictionary in game.hud.chat.lines():
		if int(line["channel"]) == HudChat.SYSTEM and String(line["text"]) == text:
			count += 1
	return count

## The camera turns toward the nearest other player, so captures show it.
func _face_nearest() -> void:
	var me: Vector3 = game.session.own_position()
	var best := INF
	for hero: Node3D in game.heroes.values():
		var flat := Vector2(hero.global_position.x - me.x, hero.global_position.z - me.z)
		if flat.length() < best and flat.length() > 0.5:
			best = flat.length()
			game.cam_yaw = atan2(-flat.x, -flat.y)

## The player menu on invite_from's body (the client knows its name from its
## local line); true once it is open.
func _open_menu() -> bool:
	var menu: HudPlayerMenu = game.hud.player_menu
	if menu.is_open():
		return true
	for id: int in game.player_names:
		if String(game.player_names[id]) == invite_from and game.heroes.has(id):
			var body: Node3D = game.heroes[id]
			var at: Vector2 = game.camera.unproject_position(body.global_position + Vector3(0, 1.2, 0))
			game.open_player_menu(id, at)
			return menu.is_open()
	return false

func _entries_text() -> String:
	var menu: HudPlayerMenu = game.hud.player_menu
	var shown := PackedStringArray()
	for entry: Dictionary in menu.entries():
		shown.append(String(entry["text"]) + (" (dimmed)" if entry["blocked"] else ""))
	return "%s: %s" % [menu.target_name, ", ".join(shown)]

## The second client: a local line (so the first client knows its name), then
## the invitation, until the coordinator says it went out.
func _guest() -> void:
	var now := _now()
	var sent := _system_said(I18n.from_server("Party invitation sent to %s." % guest_of))
	var expired := _system_said(I18n.from_server("Your party invitation to %s expired." % guest_of))
	if _guest_sent != (sent > expired):
		_guest_sent = sent > expired
		print("realm guest: invitation to %s %s after %d asks" % [guest_of, "sent" if _guest_sent else "expired", _guest_asks])
	if not _guest_sent and now >= _guest_next:
		if not _guest_said:
			game.session.send_chat(GUEST_LINE)
			_guest_said = true
			_guest_next = now + 1.0
		else:
			game.session.send_chat("/invite " + guest_of)
			_guest_asks += 1
			_guest_said = false
			_guest_next = now + GUEST_RETRY
	if now - _started > float(game._arg("--guest-seconds", "90")):
		var lines: Array = game.hud.chat.lines().map(func(l): return "[%d] %s" % [l["channel"], l["text"]])
		print("realm guest: invited %s: %s (%d asks) | log: %s" % [guest_of, _guest_sent, _guest_asks, " / ".join(lines)])
		get_tree().quit(0 if _guest_sent else 1)

func _fail(why: String) -> void:
	_failure = why
	_verdict()

func _verdict() -> void:
	set_process(false)
	var stats: Dictionary = game.session.stats()
	var counts := {}
	for line: Dictionary in game.hud.chat.lines():
		counts[int(line["channel"])] = int(counts.get(int(line["channel"]), 0)) + 1
	var system_lines: Array = game.hud.chat.lines().filter(func(l): return int(l["channel"]) == HudChat.SYSTEM) \
		.map(func(l): return String(l["text"]))
	var extras_ok := invite_from == "" or (_card_from == invite_from and _menu_entries != "" and _accepted != ""
		and _menu_dimmed.contains("(dimmed)") and _left_again)
	var corrections := int(stats.get("corrections", 0))
	# Who the other players in view are, as the server answered (they need
	# not have said a word).
	var known: Array = []
	for id in game.heroes:
		var who: Dictionary = game.player_identity(id)
		if not who.is_empty():
			known.append("%s Lv %d %s" % [who["name"], int(who["level"]), who["house"]])
	print("realm check social: %s | own line %s, own bubble \"%s\" | party [%s], frame rows %d | partner party line %s, shout %s | left %s" % [
			"ok" if _failure == "" else _failure, _own_line, _bubble, _party_seen, _rows_seen, _partner_party_line,
			_partner_shout, _left],
		" | invite card from \"%s\", menu [%s], accepted [%s], menu after [%s], left again %s" % [_card_from, _menu_entries,
			_accepted, _menu_dimmed, _left_again],
		" | log lines: local %d, shout %d, party %d, system %d; system [%s]" % [int(counts.get(0, 0)), int(counts.get(1, 0)),
			int(counts.get(2, 0)), int(counts.get(3, 0)), " / ".join(system_lines)],
		" | players in view known [%s]" % ", ".join(known),
		" | corrections %d (max %.3f m), snapshots %d" % [corrections, float(stats.get("max_correction", 0.0)),
			int(stats.get("snapshots", 0))])
	var passed := _failure == "" and _own_line and _bubble == SAY_LINE and _party_seen != "" and _rows_seen == 1 \
		and _partner_party_line and _partner_shout and _left and extras_ok and corrections == 0 and not known.is_empty() \
		and int(stats.get("snapshots", 0)) > 0
	get_tree().quit(0 if passed else 1)
