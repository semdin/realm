extends RefCounted
class_name Looks

## A character's appearance, from content/data/looks.json (read through the
## Rust content loader, RealmContent): palette entries are picked by index,
## sliders are floats in their range. HeroAppearance draws a look on the hero.

static var _table: Dictionary = {}

static func table() -> Dictionary:
	if _table.is_empty():
		var loaded: Variant = RealmContent.table("looks")
		if loaded is Dictionary:
			_table = loaded
	return _table

## One palette or list (`hair_styles`, `outfits`, `beards`, `brows`,
## `hair_colors`, `eye_colors`, `skin_tones`, `faces`).
static func list(name: String) -> Array:
	return table().get(name, [])

## slider -> [min, max]
static func sliders() -> Dictionary:
	return table().get("sliders", {})

## The palette keys of a look and the list each one indexes.
static func picks() -> Dictionary:
	return table().get("picks", {})

static func default_look() -> Dictionary:
	var look := {}
	for key: String in picks():
		look[key] = 0
	for key: String in sliders():
		look[key] = 0.0
	return look

## A saved or received look reduced to known keys with valid values; anything
## missing or out of range falls back to the default, so a look can never name
## a mesh or colour that does not exist.
static func clean_look(raw: Variant) -> Dictionary:
	var out := default_look()
	if not (raw is Dictionary):
		return out
	var src := raw as Dictionary
	var palette := picks()
	for key: String in palette:
		var size := list(String(palette[key])).size()
		if size > 0 and src.has(key) and (src[key] is int or src[key] is float):
			out[key] = clampi(int(src[key]), 0, size - 1)
	var spans := sliders()
	for key: String in spans:
		if src.has(key) and (src[key] is int or src[key] is float) and not is_nan(float(src[key])):
			var span: Array = spans[key]
			out[key] = snappedf(clampf(float(src[key]), float(span[0]), float(span[1])), 0.01)
	return out
