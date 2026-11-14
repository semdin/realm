extends RefCounted
class_name DungeonData

## The dungeon tables as the interface reads them (dungeons.json through
## RealmContent): the five difficulties in their order (the protocol sends
## their index), each dungeon's map, level band, par and key, the medal
## multiples and the party rules. The server decides every run; this only
## says what the gate and the tracker show.

## The difficulties in protocol order (index 0..4).
const DIFFICULTIES := ["easy", "normal", "hard", "very_hard", "legendary"]
## Each difficulty's colour (the old gate's cards and the tracker's title).
const COLOURS := {
	"easy": Color(0.44, 0.81, 0.55),
	"normal": Color(0.50, 0.70, 0.94),
	"hard": Color(0.94, 0.65, 0.34),
	"very_hard": Color(0.94, 0.48, 0.45),
	"legendary": Color(0.77, 0.61, 1.0),
}
const MEDAL_COLOURS := {"gold": Color("e8c34a"), "silver": Color("c8ccd6"), "bronze": Color("c98a4a")}
## realm_rules::dungeons RANK_*: 3 gold, 2 silver, 1 bronze, 0 cleared
## without a medal, -1 not cleared.
const RANK_MEDALS := {3: "gold", 2: "silver", 1: "bronze"}

static var _table: Dictionary = {}

static func _load() -> Dictionary:
	if _table.is_empty():
		var t: Variant = RealmContent.table("dungeons")
		if t is Dictionary:
			_table = t
	return _table

## The difficulty id at protocol index `index` ("normal" for 1).
static func difficulty_id(index: int) -> String:
	return String(DIFFICULTIES[clampi(index, 0, DIFFICULTIES.size() - 1)])

static func difficulty_index(id: String) -> int:
	return maxi(0, DIFFICULTIES.find(id))

## One difficulty's rules (display, min_party, min_level_add, keys,
## par_mult, death_penalty_s, lives, hp, damage, level_offset, ...).
static func difficulty(id: String) -> Dictionary:
	return (_load().get("difficulty", {}) as Dictionary).get(id, {})

static func difficulty_name(id: String) -> String:
	return I18n.t(String(difficulty(id).get("display", id)))

static func colour(id: String) -> Color:
	return COLOURS.get(id, HudKit.GOLD_LT)

## One dungeon by id (map, display, level_min, level_max, par_s, key, steps).
static func dungeon(id: String) -> Dictionary:
	return (_load().get("dungeons", {}) as Dictionary).get(id, {})

static func display_name(id: String) -> String:
	return I18n.t(String(dungeon(id).get("display", id)))

## The dungeon whose copies `map_id` holds, as [id, data] ([] when none).
static func for_map(map_id: String) -> Array:
	var all: Dictionary = _load().get("dungeons", {})
	for id: String in all:
		if String((all[id] as Dictionary).get("map", "")) == map_id:
			return [id, all[id]]
	return []

## The medal multiples of par (gold, silver, bronze, limit).
static func medals() -> Dictionary:
	return _load().get("medals", {})

## The party rules (max_party, max_level_spread, ref_max_weight, gather_radius,
## countdown_s, party_hp_trash, party_hp_boss).
static func group() -> Dictionary:
	return _load().get("group", {})

static func roles() -> Dictionary:
	return _load().get("roles", {})

## The run's reference level for a party of `levels` (realm_rules
## Dungeons::ref_level).
static func ref_level(data: Dictionary, levels: Array) -> int:
	var lo := int(data.get("level_min", 1))
	var hi := int(data.get("level_max", lo))
	if levels.is_empty():
		return lo
	var top := 0
	var sum := 0.0
	for l in levels:
		top = maxi(top, int(l))
		sum += float(l)
	var w := float(group().get("ref_max_weight", 0.6))
	return clampi(roundi(w * float(top) + (1.0 - w) * sum / float(levels.size())), lo, hi)

## A creature's level in a run (realm_rules Dungeons::mob_level).
static func mob_level(ref: int, difficulty_id_: String, role: String, extra: int) -> int:
	var offset := int(difficulty(difficulty_id_).get("level_offset", 0))
	var r := int((roles().get(role, {}) as Dictionary).get("lvl", 0))
	return maxi(1, ref + offset + r + extra)

## Creature health multiplier of a role (realm_rules Dungeons::hp_scale).
static func hp_scale(difficulty_id_: String, role: String, party: int) -> float:
	var boss := String((roles().get(role, {}) as Dictionary).get("party_hp", "trash")) == "boss"
	var per := float(group().get("party_hp_boss" if boss else "party_hp_trash", 0.0))
	return float(difficulty(difficulty_id_).get("hp", 1.0)) * (1.0 + per * float(maxi(1, party) - 1))

## The gold-medal time of a full clear on `difficulty_id_`, seconds.
static func par(data: Dictionary, difficulty_id_: String) -> float:
	return float(data.get("par_s", 1200)) * float(difficulty(difficulty_id_).get("par_mult", 1.0))

## "m:ss".
static func clock(seconds: float) -> String:
	var s := maxi(0, int(round(seconds)))
	return "%d:%02d" % [s / 60, s % 60]
