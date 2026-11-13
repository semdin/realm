extends RefCounted
class_name Levels

## Character and skill levels for the interface: the experience a level takes
## and how a skill level is written. The numbers come from the content tables
## (combat.json, spawn_tables.json) with the formulas the old world rules used,
## so the EXP bar fills the way the server counts.

static var _spawns: Dictionary = {}

static func spawn_tables() -> Dictionary:
	if _spawns.is_empty():
		var loaded: Variant = RealmContent.table("spawn_tables")
		if loaded is Dictionary:
			_spawns = loaded
	return _spawns

static func max_exp() -> int:
	return int((ItemRules.combat().get("limits", {}) as Dictionary).get("max_exp", 2000000000))

## The experience one ordinary creature of `level` gives (pack_tuning).
static func pack_exp_reward(level: int) -> int:
	var tuning: Dictionary = spawn_tables().get("pack_tuning", {})
	return int(round(float(tuning.get("exp_base", 25)) + float(level) * float(tuning.get("exp_per_level", 6))
		+ float(level * level) * float(tuning.get("exp_per_level_sq", 0.0))))

## Experience needed to leave `level`: one ordinary creature's experience at
## that level x the kills a level should take (base_stats.exp_curve), rounded
## to 10, capped at limits.max_exp.
static func exp_threshold(level: int) -> int:
	var curve: Dictionary = (ItemRules.combat().get("base_stats", {}) as Dictionary).get("exp_curve", {})
	var lv := maxi(1, level)
	var kills := float(curve.get("kills_base", 10)) + float(curve.get("kills_per_level", 10)) * float(lv - 1)
	return mini(max_exp(), int(round(float(pack_exp_reward(lv)) * kills / 10.0)) * 10)

static func skill_rules() -> Dictionary:
	return ItemRules.combat().get("skills", {})

## Spells that take skill points; the rest (the basic attack, Light of Ithrel)
## are always level 1.
static func skill_upgradeable(spell_id: String) -> bool:
	return spell_id in (skill_rules().get("upgradeable", []) as Array)

static func skill_is_master(level: int) -> bool:
	return level >= int(skill_rules().get("master_level", 10))

## What a hotbar badge prints: "1".."9", then "M".
static func skill_level_label(level: int) -> String:
	return "M" if skill_is_master(level) else str(maxi(1, level))
