extends RefCounted

## The house cloth on banners, hangings and the pitch stands, in the four
## houses' own colours (content/data/houses.json `primary_color`). The cloth
## slots keep the names the models give them (cloth_red, cloth_blue, ...):
## each stands for one house here, so changing a house's colour changes its
## cloth everywhere.

const SLOT_HOUSE := {
	"cloth_red": "velkar",
	"cloth_blue": "ilvane",
	"cloth_green": "nisera",
	"cloth_yellow": "torvan",
}
## Woven cloth reads darker than the flat UI colour.
const CLOTH_SHADE := 0.72

## The cloth colour for `slot` (with or without a `_dark` suffix).
static func cloth(slot: String) -> Color:
	var house: String = SLOT_HOUSE.get(slot.trim_suffix("_dark"), "")
	var table: Variant = RealmContent.table("houses")
	var colour := Color(0.45, 0.42, 0.38)
	if table is Dictionary and (table as Dictionary).has(house):
		colour = Color.html(String((table as Dictionary)[house].get("primary_color", "#73695f")))
	return colour * CLOTH_SHADE
