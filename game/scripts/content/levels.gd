extends RefCounted
class_name Levels

## Skill levels for the interface: which spells take skill points and how a
## skill level is written (combat.json `skills`). The experience a character
## level takes comes with the sheet (`exp_next`).

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
