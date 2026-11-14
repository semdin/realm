extends Node

## `--check-workshop`: Kestrin's workshop the way a player uses it, one step
## at a time, against a running server (the prepared character carries Velkar
## Ash, imbue and reweave scrolls and wears the starter wand):
##
##   land     waits for the joined body to come to rest
##   talk     (only while q012 "speak with Kestrin" is in the log) talks to
##            the nearest NPC, shows the dialogue with its "Open the workshop"
##            row, waits for q012 to be ready and opens the workshop from that
##            row; otherwise the O key opens it
##   claim12  claims q012 and waits for q013 (refine) to open
##   unequip  takes the worn wand off into the bag (the bag's own request)
##   anvil    right-clicks the wand in the bag onto the anvil
##   refine   UPGRADE NOW; waits for the answer and the sheet's new +N
##   claim13  (quest run) waits for q013 ready, claims it, waits for q015
##   imbue    the Enchant page's imbue card; waits for the answer and the
##            sheet's new enchantment
##   reweave  the reweave card; waits for the answer and the new sheet
##   q015     (quest run) waits for q015 ready
##
## Every step holds HOLD seconds of frame time on screen (captures). The
## verdict prints each answer and the sheet it left, then quits 0 when the
## refine and the imbue were answered and the sheet shows the new +N and
## enchantment, the reweave was answered, there were no corrections, and on a
## quest run the dialogue row was shown, q013 was ready and q015 is ready.

const Workshop := preload("res://scripts/ui/workshop_window.gd")
const HOLD := 1.6
const STEP_TIMEOUT := 25.0
const TOTAL_TIMEOUT := 180.0
const REST_SECONDS := 0.6

var game: Node
var _step := "land"
var _since := 0.0          # real seconds the step began
var _held := 0.0           # frame seconds the step has been on screen
var _started := 0.0
var _rest_from := Vector3.INF
var _rest_at := 0.0
var _quest_run := false
var _wand_uid := 0
var _answers_before := 0
var _tier_before := -1
var _bonuses_before := -1
var _sent := false
var _results := {}         # op -> {ok, reason, amount, sheet}
var _dialogue_row := false
var _opened_by := ""
var _q013_ready := false
var _q015_ready := false
var _claimed: Array = []
var _notes: Array = []

func _ready() -> void:
	_started = _now()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _go(step: String) -> void:
	print("realm check workshop: frame %d step %s" % [Engine.get_frames_drawn(), step])
	_step = step
	_since = _now()
	_held = 0.0
	_sent = false

func _process(delta: float) -> void:
	if game == null or not game.built or game.session.status() != "joined":
		if _now() - _started > TOTAL_TIMEOUT:
			_verdict("never joined")
		return
	_held += delta
	if _now() - _started > TOTAL_TIMEOUT:
		_verdict("timed out in step " + _step)
		return
	if _step != "land" and _now() - _since > STEP_TIMEOUT:
		_verdict("step %s timed out" % _step)
		return
	var sheet: PlayerSheet = game.sheet_view
	var workshop: Control = game.workshop
	match _step:
		"land":
			if sheet.revision() < 0 or sheet.inventory.is_empty():
				return
			var me: Vector3 = game.session.own_position()
			if _rest_from == Vector3.INF or me.distance_to(_rest_from) > 0.02:
				_rest_from = me
				_rest_at = _now()
				return
			if _now() - _rest_at < REST_SECONDS:
				return
			_quest_run = _in_log("q012")
			_go("talk" if _quest_run else "open")
		"talk":
			if not _sent:
				var npc: NpcView = game._npc_near(game.TALK_KEY_REACH)
				if npc == null or npc.npc_name != "Kestrin":
					_verdict("Kestrin is not within %.1f m of %s" % [game.TALK_KEY_REACH, game.session.own_position().snapped(Vector3(0.1, 0.1, 0.1))])
					return
				game.talk_to(npc)
				_sent = true
				return
			var row := game.dialogue.find_child("Service_workshop", true, false) as Button
			if row != null and row.is_visible_in_tree():
				_dialogue_row = true
			if _held < HOLD * 1.5 or not game.quests.is_ready("q012"):
				return
			if row == null:
				_verdict("the dialogue has no workshop row")
				return
			row.pressed.emit()
			_opened_by = "dialogue"
			_go("claim12")
		"open":
			if not _sent:
				var key := InputEventKey.new()
				key.physical_keycode = KEY_O
				key.keycode = KEY_O
				key.pressed = true
				Input.parse_input_event(key)
				var up := key.duplicate() as InputEventKey
				up.pressed = false
				Input.parse_input_event(up)
				_sent = true
				return
			if workshop.visible:
				_opened_by = "O key"
				_go("unequip")
		"claim12":
			if not _sent:
				if not workshop.visible:
					_verdict("the dialogue row did not open the workshop")
					return
				game.quests.claim("q012")
				_sent = true
				return
			if game.quests.is_done("q012") and _in_log("q013"):
				_claimed.append("q012")
				_go("unequip")
		"unequip":
			var worn: Dictionary = sheet.equipment.get("main_hand", {})
			if not _sent:
				if worn.is_empty():
					_wand_uid = _bag_wand_uid(sheet)
					_go("anvil")
					return
				_wand_uid = int(worn.get("uid", 0))
				game.inventory._request("unequip", "main_hand")
				_sent = true
				return
			# (the empty anvil's intro page stays up a moment for captures)
			if worn.is_empty() and _bag_entry(sheet, _wand_uid).size() > 0 and _held >= HOLD:
				_go("anvil")
		"anvil":
			if not _sent:
				var slot := _bag_slot(_wand_uid)
				if slot != null:
					game.inventory._activate(slot)   # right-click in the bag
				else:
					workshop.set_target(_wand_uid)
				_sent = true
				return
			if workshop.target_uid != _wand_uid:
				_verdict("the wand did not land on the anvil")
				return
			if _held >= HOLD:
				_go("refine")
		"refine", "imbue", "reweave":
			_operate(_step, sheet, workshop)
		"claim13":
			if not _sent:
				if not game.quests.is_ready("q013"):
					return
				_q013_ready = true
				game.quests.claim("q013")
				_sent = true
				return
			if game.quests.is_done("q013") and _in_log("q015"):
				_claimed.append("q013")
				_go("imbue")
		"q015":
			if game.quests.is_ready("q015"):
				_q015_ready = true
			if _q015_ready or _held > HOLD * 2.0:
				_verdict("")

## One workshop request: show its page, press its button, wait for the answer
## and the sheet it changed, hold the result on screen.
func _operate(op: String, sheet: PlayerSheet, workshop: Control) -> void:
	var item: Dictionary = _bag_entry(sheet, _wand_uid)
	if not _sent:
		workshop.show_page("refine" if op == "refine" else "enchant")
		if _held < HOLD * 0.5:
			return
		_answers_before = workshop.results_seen
		_tier_before = int(item.get("tier", 0))
		_bonuses_before = (item.get("bonuses", []) as Array).size()
		var sent: bool = workshop.call(op)
		if not sent:
			_verdict("%s was not sent (busy or nothing to send)" % op)
			return
		_sent = true
		_held = 0.0
		return
	if workshop.results_seen == _answers_before or workshop.busy():
		_held = 0.0
		return
	if not _results.has(op):
		var answer: Dictionary = workshop.last_result
		_results[op] = {"ok": answer.get("ok", false), "reason": answer.get("reason", ""), "amount": answer.get("amount", 0),
			"tier_before": _tier_before, "tier": int(item.get("tier", 0)),
			"bonuses_before": _bonuses_before, "bonuses": (item.get("bonuses", []) as Array).duplicate(true)}
		print("realm check workshop: %s answered ok=%s reason=%s amount=%d | sheet +%d -> +%d, enchantments %d -> %d [%s]" % [
			op, answer.get("ok", false), answer.get("reason", ""), int(answer.get("amount", 0)), _tier_before,
			int(item.get("tier", 0)), _bonuses_before, (item.get("bonuses", []) as Array).size(), _bonus_list(item)])
	if _held < HOLD:
		return
	match op:
		"refine":
			_go("claim13" if _quest_run else "imbue")
		"imbue":
			_go("reweave")
		"reweave":
			if _quest_run:
				_go("q015")
			else:
				_verdict("")

func _in_log(id: String) -> bool:
	for q: Dictionary in game.quests.log_entries():
		if String(q.get("id", "")) == id:
			return true
	return false

func _bag_entry(sheet: PlayerSheet, uid: int) -> Dictionary:
	for entry: Dictionary in sheet.inventory:
		if int(entry.get("uid", 0)) == uid:
			return entry
	return {}

func _bag_wand_uid(sheet: PlayerSheet) -> int:
	for entry: Dictionary in sheet.inventory:
		if int(entry.get("uid", 0)) > 0 and ItemRules.refinable(String(entry.id)) and ItemRules.enchantable(String(entry.id)):
			return int(entry.uid)
	return 0

func _bag_slot(uid: int) -> UISlot:
	for slot: UISlot in game.inventory._bag_slots:
		if int(slot.entry.get("uid", 0)) == uid:
			return slot
	return null

func _bonus_list(item: Dictionary) -> String:
	var parts: Array = []
	for bonus: Dictionary in item.get("bonuses", []):
		parts.append("%s grade %d" % [ItemRules.bonus_text(bonus), Workshop.grade_of(bonus)])
	return ", ".join(parts)

func _verdict(failure: String) -> void:
	if _step == "done":
		return
	_step = "done"
	var stats: Dictionary = game.session.stats()
	var refine: Dictionary = _results.get("refine", {})
	var imbue: Dictionary = _results.get("imbue", {})
	var reweave: Dictionary = _results.get("reweave", {})
	var refined := bool(refine.get("ok", false)) and String(refine.get("reason", "")) == "refined" \
		and int(refine.get("tier", -1)) == int(refine.get("tier_before", -2)) + 1
	var imbued := bool(imbue.get("ok", false)) and String(imbue.get("reason", "")) == "enchanted" \
		and (imbue.get("bonuses", []) as Array).size() == int(imbue.get("bonuses_before", -2)) + 1
	var rewoven := bool(reweave.get("ok", false)) and (reweave.get("bonuses", []) as Array).size() == int(reweave.get("bonuses_before", -2))
	var quests_ok := not _quest_run or (_dialogue_row and _q013_ready and _q015_ready)
	var corrections := int(stats.get("corrections", 0))
	print("realm check workshop: opened by %s | refine %s, imbue %s, reweave %s | quest run %s: dialogue row %s, claimed [%s], q013 ready %s, q015 ready %s | corrections %d (max %.3f m), snapshots %d%s" % [
		_opened_by if _opened_by != "" else "-", refined, imbued, rewoven, _quest_run, _dialogue_row, ", ".join(_claimed),
		_q013_ready, _q015_ready, corrections, float(stats.get("max_correction", 0.0)), int(stats.get("snapshots", 0)),
		(" | FAILED: " + failure) if failure != "" else ""])
	var passed := failure == "" and refined and imbued and rewoven and quests_ok and corrections == 0 and int(stats.get("snapshots", 0)) > 0
	get_tree().quit(0 if passed else 1)
