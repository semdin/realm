extends HudWindow
class_name HudBestiary

## The bestiary (B by default; GameSettings "bestiary"), the old game's: every
## creature of the realm with a portrait, a line of lore and a few short facts
## - where it is found, its boss, what it is weak to and what it shrugs off.
## "Show on map" sets the waypoint on the nearest of its packs on this map
## (or, for a dungeon's creature, on the way to that dungeon's gate) and
## opens the world map. Everything is read from the data the server spawns
## from (spawn_tables.json, mobs.json, dungeons.json), so it never lies about
## where a creature lives. Like the old one it keeps no kill counts: the
## character sheet has none.

const PORTRAITS := "res://assets/ui/bestiary/%s.png"
# i18n-begin
const LORE := {
	"drowned_one": "Drowned corpses bewitched to serve the Ash Priest. Slow, relentless and terrified of fire.",
	"drowned_warden": "Drowned Ones raised from a cursed lake to guard what lies beneath. Their cold grip drags you down; fire still breaks them.",
	"goblin_teller": "Goblin moneylenders from Orvell's vaults, out collecting debts. They count every coin and carry a heavy purse.",
	"goblin_guard": "Vault guards in goblin-wrought silver. Shoving, stubborn and well paid; what they carry is rarely ordinary.",
	"goblin_hexer": "Goblin magic needs no wand. Hexers walk with the tellers and the guards and blast debtors off their feet with bare hands.",
	"black_weaver": "Giant spiders of the Raven Woods, bred from an ancient brood-mother. They hunt in packs.",
	"dark_bandit": "Wizards turned bounty hunters, roaming the roads in gangs. Some cast from range.",
	"troll_forest": "Hulking forest trolls with crude clubs. Slow to anger, slower to fall.",
	"troll_mountain": "The largest trolls, grey-skinned and thick-hided, guarding the high moors.",
	"pallid": "Soul-sucking wardens of Morhal. Their cold drains your will; only the Light of Ithrel truly drives them off.",
	"fidgetling": "Electric-blue pests that lift wizards off their feet and hurl them about.",
	"armour_guard": "Suits of armour enchanted to defend the castle's sealed wing.",
	"armour_commander": "A cursed suit that commands the others. Its shield turns aside blows from the front.",
	"strangling_vine": "A creeping plant that strangles whatever struggles. Burn its vines to reach the heart.",
	"threehead": "A three-headed hound bound to guard the sealed wing's stone hatch. The sleep chime lulls it.",
	"venomfang_weaver": "Lean, long-legged hunters of the Blackweb Caverns. Their emerald venom burns for seconds after the bite.",
	"broodguard": "Bone-plated giants that guard the egg caverns. Their armour turns blows from the front; their webs pin you down.",
}
const RESIST_NAMES := {"fire": "Fire (Flame Wave)", "stun": "Stuns", "force": "Force (Shockwave)",
	"ithrel_light": "Light of Ithrel", "arcane": "Arcane"}
const FAMILY_NAMES := {"troll": "Troll", "undead": "Undead", "ashbound": "Ashbound", "pallid": "Pallid",
	"beast": "Beast", "pixie": "Fidgetling", "snare": "Plant", "armour": "Enchanted armour", "hound": "Hound",
	"spider": "Spider", "goblin": "Goblin"}
# i18n-end
## Roles that are not creatures of their own (a boss's head or vine, an egg
## sac, a cocoon).
const NOT_LISTED := ["part", "object"]
## A list row's height, and the room kept round its text when a name wraps.
const ROW_HEIGHT := 54.0
const ROW_PAD := 12.0

## main.gd: the way-finding (MapWay) and the map the player is on.
var way: Node = null
var map_name := ""
var _entries: Array = []
var _list: VBoxContainer
var _detail: VBoxContainer
## The creature shown (the check reads it).
var selected := ""

func _init() -> void:
	super._init("Bestiary", Vector2(760, 520))
	name = "Bestiary"

func _ready() -> void:
	super._ready()
	_entries = build_entries()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(row)
	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(260, 0)
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(list_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_list)
	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(detail_scroll)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 8)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(_detail)
	for entry: Dictionary in _entries:
		_list.add_child(_list_row(entry))
	if not _entries.is_empty():
		show_species(String(_entries[0]["species"]))

## The creatures listed (species ids, in the list's order).
func species() -> Array:
	return _entries.map(func(e): return String(e["species"]))

static func _table(name: String) -> Dictionary:
	var t: Variant = RealmContent.table(name)
	return t if t is Dictionary else {}

## A pack's boss name: its override's (boss_key, else the encounter id's last
## word), else the species'.
static func _boss_name(pack: Dictionary, overrides: Dictionary, mobs: Dictionary) -> String:
	var key := String(pack.get("boss_key", ""))
	if key == "" or not overrides.has(key):
		key = String(pack.get("encounter_id", "")).get_slice("_", String(pack.get("encounter_id", "")).get_slice_count("_") - 1)
	var name := String((overrides.get(key, {}) as Dictionary).get("name", ""))
	if name == "":
		name = String((mobs.get(String(pack.get("mob", "")), {}) as Dictionary).get("display", ""))
	return name

## One entry per creature: its catalogue identity plus every place it lives.
static func build_entries() -> Array:
	var tables := _table("spawn_tables")
	var mobs: Dictionary = _table("mobs").get("mobs", {})
	var overrides: Dictionary = tables.get("boss_overrides", {})
	var regions := {}
	for region: Dictionary in tables.get("regions", []):
		regions[String(region.get("id", ""))] = String(region.get("display", region.get("id", "")))
	var by_species := {}
	var blank := func(s: String) -> Dictionary:
		return {"species": s, "regions": {}, "bosses": [], "dungeons": [], "level_min": 999, "level_max": 0,
			"aggressive_from": 0, "packs": []}
	for pack: Dictionary in tables.get("packs", []):
		# A mixed pack (the goblins) lists every species it fields.
		var roster: Array = pack.get("roster", [pack.get("mob", "")])
		var seen := {}
		for species_id: Variant in roster:
			var sp := String(species_id)
			if sp == "" or seen.has(sp):
				continue
			seen[sp] = true
			var e: Dictionary = by_species.get(sp, blank.call(sp))
			var level := int(pack.get("level", 1))
			var area: Array = pack.get("area", [0, 0, 0, 0])
			var centre := Vector2(float(area[0]) + float(area[2]) * 0.5, float(area[1]) + float(area[3]) * 0.5)
			(e["packs"] as Array).append({"map": String(pack.get("map", "")), "at": centre})
			var zone := String(pack.get("zone", ""))
			if bool(pack.get("boss", false)) or bool(pack.get("world_boss", false)):
				(e["bosses"] as Array).append({"name": I18n.t(_boss_name(pack, overrides, mobs)), "level": level,
					"world": bool(pack.get("world_boss", false)), "region": I18n.t(String(regions.get(zone, zone)))})
			else:
				var r: Dictionary = (e["regions"] as Dictionary).get(zone, {"zone": zone, "packs": 0, "lo": 999, "hi": 0})
				r["packs"] = int(r["packs"]) + 1
				r["lo"] = mini(int(r["lo"]), level)
				r["hi"] = maxi(int(r["hi"]), level)
				e["regions"][zone] = r
				e["level_min"] = mini(int(e["level_min"]), level)
				e["level_max"] = maxi(int(e["level_max"]), level)
				if String(pack.get("aggro_mode", "")) == "aggressive":
					var from := int(e["aggressive_from"])
					e["aggressive_from"] = level if from == 0 else mini(from, level)
			by_species[sp] = e
	var dungeons := DungeonData.all()
	for id: String in dungeons:
		var dungeon: Dictionary = dungeons[id]
		for step: Dictionary in dungeon.get("steps", []):
			for spawn: Dictionary in step.get("spawn", []):
				var sp := String(spawn.get("mob", ""))
				var e: Dictionary = by_species.get(sp, blank.call(sp))
				if not (e["dungeons"] as Array).has(id):
					(e["dungeons"] as Array).append(id)
				# A dungeon's creatures follow the run's level: the dungeon's band.
				if (e["regions"] as Dictionary).is_empty():
					e["level_min"] = mini(int(e["level_min"]), int(dungeon.get("level_min", 1)))
					e["level_max"] = maxi(int(e["level_max"]), int(dungeon.get("level_max", dungeon.get("level_min", 1))))
				by_species[sp] = e
	var out: Array = []
	for sp: String in by_species:
		var def: Dictionary = mobs.get(sp, {})
		if def.is_empty() or NOT_LISTED.has(String(def.get("role", ""))):
			continue
		var e: Dictionary = by_species[sp]
		e["display"] = I18n.t(String(def.get("display", sp)))
		e["family"] = String(def.get("family", ""))
		e["resist"] = def.get("resist", {})
		e["region_names"] = regions
		out.append(e)
	out.sort_custom(func(a, b): return int(a["level_min"]) < int(b["level_min"]) \
		or (int(a["level_min"]) == int(b["level_min"]) and String(a["species"]) < String(b["species"])))
	return out

func _portrait(sp: String, px: int) -> TextureRect:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(px, px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var path := PORTRAITS % sp
	if ResourceLoader.exists(path):
		rect.texture = load(path)
	return rect

func _list_row(entry: Dictionary) -> Button:
	var b := Button.new()
	b.name = "Row_" + String(entry["species"])
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(state, HudKit.button_box("hover" if state != "normal" else "normal"))
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 8)
	b.add_child(row)
	var pic := _portrait(String(entry["species"]), 48)
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(pic)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.clip_contents = true
	row.add_child(col)
	# a long name ("Drowned Warden of Lunra") wraps to a second line and the
	# row grows to hold it, never cut short
	var title := HudKit.label(String(entry["display"]), 15, HudKit.GOLD_LT, HudKit.bold(), 3)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(title)
	var dungeon_only := (entry["regions"] as Dictionary).is_empty() and (entry["bosses"] as Array).is_empty()
	var sub := HudKit.label(_level_text(entry) + (tr("  ·  dungeon") if dungeon_only else ""), 12, HudKit.TEXT_DIM, HudKit.body(), 2)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(sub)
	col.minimum_size_changed.connect(func(): b.custom_minimum_size.y = maxf(ROW_HEIGHT, col.get_combined_minimum_size().y + ROW_PAD))
	b.pressed.connect(func(): show_species(String(entry["species"])))
	return b

func _level_text(entry: Dictionary) -> String:
	var lo := int(entry["level_min"])
	var hi := int(entry["level_max"])
	if lo > hi:
		return ""
	return tr("Lv %d") % lo if lo == hi else tr("Lv %d–%d") % [lo, hi]

func _entry(sp: String) -> Dictionary:
	for e: Dictionary in _entries:
		if String(e["species"]) == sp:
			return e
	return {}

## Show creature `sp` on the right.
func show_species(sp: String) -> void:
	selected = sp
	for row in _list.get_children():
		(row as Button).button_pressed = row.name == "Row_" + sp
	for child in _detail.get_children():
		_detail.remove_child(child)   # out of the layout this frame
		child.queue_free()
	var e := _entry(sp)
	if e.is_empty():
		return
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	_detail.add_child(head)
	head.add_child(_portrait(sp, 140))
	var id_col := VBoxContainer.new()
	id_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_col.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(id_col)
	id_col.add_child(HudKit.label(String(e["display"]), 24, HudKit.GOLD_HI, HudKit.title(), 4))
	var family := String(e["family"])
	id_col.add_child(HudKit.label("%s  ·  %s" % [_level_text(e), I18n.t(String(FAMILY_NAMES.get(family, family.capitalize())))],
		14, HudKit.TEXT_DIM, HudKit.body(), 2))
	var lore := HudKit.label(I18n.t(String(LORE.get(sp, ""))), 14, HudKit.TEXT, HudKit.body(), 2)
	lore.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lore.custom_minimum_size = Vector2(300, 0)
	id_col.add_child(lore)
	if _can_show_way(e):
		var show := HudKit.button(tr("Show on map"), 14)
		show.name = "ShowOnMap"
		show.focus_mode = Control.FOCUS_NONE
		show.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		show.pressed.connect(show_on_map)
		id_col.add_child(show)
	# Short and scannable: where (region names only), the boss, weak / strong.
	var regions: Array = (e["regions"] as Dictionary).values()
	regions.sort_custom(func(a, b): return int(a["lo"]) < int(b["lo"]))
	var region_names: Dictionary = e["region_names"]
	var names: Array = regions.map(func(r): return I18n.t(String(region_names.get(String(r["zone"]), r["zone"]))))
	if names.size() > 3:
		names = names.slice(0, 3) + [tr("+%d more") % (names.size() - 3)]
	for d: String in e["dungeons"]:
		names.append(tr("%s (dungeon)") % DungeonData.display_name(d))
	if not names.is_empty():
		_fact(tr("Found"), ", ".join(names))
	for boss: Dictionary in e["bosses"]:
		var where := String(boss["region"])
		_fact(tr("World boss") if bool(boss["world"]) else tr("Boss"),
			tr("%s  ·  Lv %d  ·  %s") % [String(boss["name"]), int(boss["level"]), where], HudKit.GOLD_LT)
	var weak: Array = []
	var strong: Array = []
	var resist: Dictionary = e["resist"]
	for k: String in resist:
		var v := float(resist[k])
		var label := I18n.t(String(RESIST_NAMES.get(k, k.capitalize())))
		if v < 0.0:
			weak.append(label)
		elif v >= 0.3:
			strong.append(label)
	if not weak.is_empty():
		_fact(tr("Weak"), ", ".join(weak), Color(0.6, 1.0, 0.6))
	if not strong.is_empty():
		_fact(tr("Resists"), ", ".join(strong), Color(1.0, 0.75, 0.55))
	if int(e["aggressive_from"]) > 0:
		_fact(tr("Aggressive"), tr("from Lv %d") % int(e["aggressive_from"]), Color(1.0, 0.6, 0.5))

## One short labelled line: "Found   Village Outskirts, Pitch Woods".
func _fact(caption: String, text: String, colour: Color = HudKit.TEXT) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var c := HudKit.label(I18n.upper(caption), 12, HudKit.GOLD, HudKit.bold(), 2)
	c.custom_minimum_size = Vector2(86, 0)
	row.add_child(c)
	var l := HudKit.label(text, 14, colour, HudKit.body(), 2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	_detail.add_child(row)

func _can_show_way(e: Dictionary) -> bool:
	if way == null:
		return false
	return (e["packs"] as Array).any(func(p): return String(p["map"]) == map_name) or not (e["dungeons"] as Array).is_empty()

## "Show on map": the waypoint on the nearest of the shown creature's packs
## on this map (or the way to its dungeon's gate), and the world map.
func show_on_map() -> void:
	var e := _entry(selected)
	if e.is_empty() or way == null:
		return
	var me: Vector3 = way.game.session.own_position()
	var best := Vector2.INF
	for p: Dictionary in e["packs"]:
		if String(p["map"]) != map_name:
			continue
		var at: Vector2 = p["at"]
		if best == Vector2.INF or at.distance_to(Vector2(me.x, me.z)) < best.distance_to(Vector2(me.x, me.z)):
			best = at
	if best != Vector2.INF:
		var point: Vector3 = way.game.session.nav_point(Vector3(best.x, me.y, best.y))
		way.set_waypoint(map_name, point, String(e["display"]))
	elif not (e["dungeons"] as Array).is_empty():
		if not way.show_way_to_dungeon(String(e["dungeons"][0])):
			return
	else:
		return
	close()
	way.world_map.open()
