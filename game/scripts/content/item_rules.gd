extends RefCounted
class_name ItemRules

## Item facts for the interface (tooltips, the bag, the merchant). The numbers
## come from the Rust rules (RealmContent.item_stats), the same code the server
## decides with; this class only words them. Item definitions are the content
## table (Items).

## Bag cells (realm_rules BAG_SLOTS).
const BAG_SLOTS := 40
## Fixed stats that are percentages or per-second rates (never grow with +N).
const FIXED_PERCENT := ["attack_speed", "move_speed", "spell_power", "hp_regen", "mana_regen"]

static var _combat: Dictionary = {}
static var _travel: Dictionary = {}

static func item(id: String) -> Dictionary:
	return Items.item(id)

static func fits(id: String, slot: String) -> bool:
	return slot in item(id).get("slots", [])

static func equippable(id: String) -> bool:
	return not (item(id).get("slots", []) as Array).is_empty()

static func stackable(id: String) -> bool:
	var data := item(id)
	if data.is_empty():
		return true
	if data.has("stackable"):
		return bool(data.stackable)
	return String(data.get("type", "")) in ["consumable", "material"]

static func required_level(id: String) -> int:
	return maxi(1, int(item(id).get("required_level", 1)))

## One item's numbers at refine level `tier` (see RealmContent.item_stats).
static func stats(id: String, tier: int) -> Dictionary:
	return RealmContent.item_stats(id, tier)

static func refinable(id: String) -> bool:
	return bool(stats(id, 0).get("refinable", false))

static func enchantable(id: String) -> bool:
	return bool(stats(id, 0).get("enchantable", false))

static func sell_price(id: String, tier: int = 0) -> int:
	return int(stats(id, tier).get("sell_price", 0))

static func combat() -> Dictionary:
	if _combat.is_empty():
		var loaded: Variant = RealmContent.table("combat")
		if loaded is Dictionary:
			_combat = loaded
	return _combat

## The +N damage multiplier of a wand at `tier`.
static func wand_multiplier(tier: int) -> float:
	var tiers: Array = combat().get("wand_tiers", [])
	if tiers.is_empty():
		return 1.0
	return float((tiers[clampi(tier, 0, tiers.size() - 1)] as Dictionary).get("multiplier", 1.0))

## The item a Waylink is (travel.json waylink.item).
static func waylink_item() -> String:
	if _travel.is_empty():
		var loaded: Variant = RealmContent.table("travel")
		if loaded is Dictionary:
			_travel = loaded
	return String((_travel.get("waylink", {}) as Dictionary).get("item", ""))

## Tooltip / workshop lines for an item's fixed stats at refine level `tier`:
## [{text, negative}], in display order. One wording for every window.
static func fixed_lines(id: String, tier: int) -> Array:
	var n := stats(id, tier)
	var lines: Array = []
	if n.has("attack_value"):
		var span: PackedFloat32Array = n.attack_value
		lines.append({"text": I18n.t("Attack Value %d - %d") % [int(span[0]), int(span[1])], "negative": false})
	if n.has("magic_attack"):
		var span: PackedFloat32Array = n.magic_attack
		lines.append({"text": I18n.t("Magic Attack Value %d - %d") % [int(span[0]), int(span[1])], "negative": false})
	if int(n.get("armor", 0)) > 0:
		lines.append({"text": I18n.t("Armour %d") % int(n.armor), "negative": false})
	if int(n.get("bonus_hp", 0)) > 0:
		lines.append({"text": I18n.t("Max Health +%d") % int(n.bonus_hp), "negative": false})
	if int(n.get("bonus_mana", 0)) > 0:
		lines.append({"text": I18n.t("Max Mana +%d") % int(n.bonus_mana), "negative": false})
	# i18n-begin
	var labels := {"attack_speed": "Attack Speed %+d%%", "move_speed": "Movement Speed %+d%%", "spell_power": "Spell Power %+d%%",
		"hp_regen": "Health Regeneration %+d/s", "mana_regen": "Mana Regeneration %+d/s"}
	# i18n-end
	for key in FIXED_PERCENT:
		if n.has(key) and not is_zero_approx(float(n[key])):
			lines.append({"text": I18n.t(labels[key]) % int(n[key]), "negative": float(n[key]) < 0.0})
	if n.has("mount_speed"):
		lines.append({"text": I18n.t("Mount Speed %.1f") % float(n.mount_speed), "negative": false})
	return lines

## "Spell Power +6%" - the one wording for an enchantment line.
static func bonus_text(bonus: Dictionary) -> String:
	var specs: Dictionary = (combat().get("enchant", {}) as Dictionary).get("stats", {})
	var spec: Dictionary = specs.get(String(bonus.get("stat", "")), {})
	if bool(spec.get("flag", false)):
		return I18n.t(String(spec.get("label", bonus.get("stat", "?"))))
	return "%s +%d%s" % [I18n.t(String(spec.get("label", bonus.get("stat", "?")))), int(bonus.get("value", 0)), String(spec.get("unit", ""))]
