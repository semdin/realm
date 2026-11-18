extends Node
class_name QuestManager

## The client's view of the quest log. The quests are content
## (content/data/quests.json `chain`) and every bit of progress is the
## server's: the sheet carries the open log (`quests`: ready first, each
## {id, state, progress, count}) and the claimed ids (`quests_done`). This
## node mirrors them for the tracker, the log, the scroll, the dialogue card
## and the NPCs' arrows, turns changes into signals and sounds, and asks the
## server to pay a finished quest (RealmSession.claim_quest).
##
## "New" is a view-only flag: an open quest the player has not read yet. It is
## kept per character in user://quest_seen.json so the blink survives a relog.

signal quest_updated
## A quest was claimed (the reward is paid).
signal quest_completed(quest_id: String)
## A quest reached its count and waits to be claimed.
signal quest_ready(quest_id: String)
## A quest opened (level reached, prerequisite claimed).
signal quest_new(quest_id: String)

const SEEN_PATH := "user://quest_seen.json"

var session: Node
var sheet: PlayerSheet
## The house of the character (the reputation reward's crest and name).
var house := ""
## Claims asked for (the check reads it).
var claims_sent := 0

var _chain: Array = []
var _by_id: Dictionary = {}
var _talk_radius := 6.0
## The log as last read: open and ready ids in log order, progress by id,
## claimed ids.
var _open_ids: Array = []
var _ready_ids: Array = []
var _done_ids: Array = []
var _progress: Dictionary = {}
var _synced := false
var _seen: Array = []
var _seen_key := ""

func setup(realm_session: Node, player_sheet: PlayerSheet) -> void:
	session = realm_session
	sheet = player_sheet
	var table: Variant = RealmContent.table("quests")
	if table is Dictionary:
		_chain = (table as Dictionary).get("chain", [])
		_talk_radius = float((table as Dictionary).get("talk_radius", 6.0))
	for q: Dictionary in _chain:
		_by_id[String(q.get("id", ""))] = q
	sheet.inventory_changed.connect(_sync)

# ------------------------------------------------------------------ queries

## One quest's content (quests.json), {} when there is none.
func quest(id: String) -> Dictionary:
	return _by_id.get(id, {})

## How near an NPC the server counts a talk.
func talk_radius() -> float:
	return _talk_radius

## Open quests (not finished yet), in chain order.
func open_quests() -> Array:
	return _open_ids.map(func(id): return quest(String(id)))

## The log as the interface shows it: finished quests waiting for their
## reward first, then new (unread) ones, then the rest, each in chain order.
func log_entries() -> Array:
	var ready: Array = []
	var fresh: Array = []
	var rest: Array = []
	for id in _ready_ids:
		ready.append(quest(String(id)))
	for id in _open_ids:
		(fresh if is_new(String(id)) else rest).append(quest(String(id)))
	return ready + fresh + rest

func progress_of(id: String) -> int:
	if is_ready(id):
		return int(quest(id).get("count", 1))
	return int(_progress.get(id, 0))

func is_ready(id: String) -> bool:
	return _ready_ids.has(id)

func is_done(id: String) -> bool:
	return _done_ids.has(id)

## In the log and not finished yet.
func is_open(id: String) -> bool:
	return _open_ids.has(id)

func is_new(id: String) -> bool:
	return _open_ids.has(id) and not _seen.has(id)

func done_count() -> int:
	return _done_ids.size()

## True while anything in the log wants attention (a reward or an unread quest).
func needs_attention() -> bool:
	return not _ready_ids.is_empty() or _open_ids.any(func(id): return is_new(String(id)))

## True while an open talk quest asks the player to speak with `npc_name`
## (the bobbing arrow over its head).
func npc_wants_talk(npc_name: String) -> bool:
	for id in _open_ids:
		var q := quest(String(id))
		if String(q.get("type", "")) == "talk" and String(q.get("target", "")) == npc_name \
				and progress_of(String(id)) < int(q.get("count", 1)):
			return true
	return false

## The top of the log (the scroll opens it when no quest is named).
func current_quest() -> Dictionary:
	var entries := log_entries()
	return entries[0] if not entries.is_empty() else {}

## "Defeat 6 Black Weavers  3/6" - the objective with its live count.
func objective_text(q: Dictionary) -> String:
	var id := String(q.get("id", ""))
	if is_ready(id):
		return tr("Complete! Click to claim your reward")
	var count := int(q.get("count", 1))
	if count <= 1:
		return I18n.t(String(q.get("name", "")))
	return "%s  %d/%d" % [I18n.t(String(q.get("name", ""))), mini(progress_of(id), count), count]

## "Woolen Traveller's Cloak, Health Potion x5" for a quest's item rewards.
static func reward_items_text(q: Dictionary) -> String:
	var parts: Array = []
	for reward: Dictionary in q.get("reward_items", []):
		var item_name := I18n.t(String(Items.item(String(reward.get("id", ""))).get("name", reward.get("id", ""))))
		var amount := int(reward.get("amount", 1))
		parts.append(item_name if amount <= 1 else "%s x%d" % [item_name, amount])
	return ", ".join(parts)

# ------------------------------------------------------------------ actions

## Ask the server for a finished quest's reward; the answer is a
## "quest_result" game event and, when it pays, a "reward".
func claim(id: String) -> void:
	if is_ready(id):
		claims_sent += 1
		session.claim_quest(id)

## The player opened (read) a quest: it stops blinking.
func mark_seen(id: String) -> void:
	if id == "" or _seen.has(id):
		return
	_seen.append(id)
	_save_seen()
	quest_updated.emit()

# ------------------------------------------------------------------ mirroring

## Mirror the sheet's log. The first read is a load, not news; afterwards a
## quest that appears is new, one that moves to ready finished, one that
## moves to done was claimed.
func _sync() -> void:
	var data := sheet.data
	if data.is_empty() or not data.has("quests"):
		return
	var key := "%s" % data.get("id", "")
	if key != _seen_key:
		_seen_key = key
		_seen = _load_seen()
		_synced = false
	house = String(data.get("house", ""))
	var open_ids: Array = []
	var ready_ids: Array = []
	var progress := {}
	for entry: Dictionary in data["quests"]:
		var id := String(entry.get("id", ""))
		if not _by_id.has(id):
			continue
		if String(entry.get("state", "")) == "ready":
			ready_ids.append(id)
		else:
			open_ids.append(id)
			progress[id] = int(entry.get("progress", 0))
	var done_ids: Array = (data.get("quests_done", []) as Array).map(func(id): return String(id))
	if _synced and open_ids == _open_ids and ready_ids == _ready_ids and done_ids == _done_ids \
			and progress == _progress:
		return
	var announce := _synced
	var fresh := open_ids.filter(func(id): return not _open_ids.has(id))
	var finished := ready_ids.filter(func(id): return not _ready_ids.has(id))
	var claimed := done_ids.filter(func(id): return not _done_ids.has(id))
	_open_ids = open_ids
	_ready_ids = ready_ids
	_done_ids = done_ids
	_progress = progress
	_synced = true
	if announce:
		for id in claimed:
			quest_completed.emit(String(id))
		for id in finished:
			quest_ready.emit(String(id))
		for id in fresh:
			quest_new.emit(String(id))
		if not finished.is_empty():
			AudioManager.play_sound_at("ui_quest_complete", Vector3.ZERO, null, true)
		elif not fresh.is_empty():
			AudioManager.play_sound_at("ui_quest", Vector3.ZERO, null, true)
	quest_updated.emit()

# ------------------------------------------------------------------ "new" flags

func _load_seen() -> Array:
	if _seen_key == "" or not FileAccess.file_exists(SEEN_PATH):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SEEN_PATH))
	if parsed is Dictionary and (parsed as Dictionary).get(_seen_key) is Array:
		return ((parsed as Dictionary)[_seen_key] as Array).map(func(id): return String(id))
	return []

func _save_seen() -> void:
	if _seen_key == "":
		return
	var all: Dictionary = {}
	if FileAccess.file_exists(SEEN_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SEEN_PATH))
		if parsed is Dictionary:
			all = parsed
	all[_seen_key] = _seen
	var file := FileAccess.open(SEEN_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(all))
