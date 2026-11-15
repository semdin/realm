extends RefCounted
class_name GameCredits

## The Credits page of the Settings window: whose work this client is built
## from, listing only what it ships. CC BY 4.0 (Human Shaders' skin and iris
## textures), MIT (Godot, the Human Shaders skin model, most Rust libraries),
## OFL (Literata) and the other licences ask for their notice where players
## can read it; the CC0 sources and the tools are thanked too. The Rust
## libraries compiled into the client extension come from
## res://assets/credits/rust_crates.json (from `cargo metadata` over
## `cargo tree -p realm_client -e normal`: rewrite it when the dependencies
## change). The page ends with the Literata licence and Godot's own licence,
## its third-party notices and the licence texts
## (Engine.get_license_text / get_copyright_info / get_license_info).

const CRATES_PATH := "res://assets/credits/rust_crates.json"
const OFL_PATH := "res://assets/fonts/OFL-Literata.txt"

## Entries: name, by, licence, url, what (the only translated field).
const SECTIONS := [
	{
		"title": "Licensed assets",
		"entries": [
			{
				"name": "Godot Engine", "by": "© 2014-present Godot Engine contributors, © 2007-2014 Juan Linietsky, Ariel Manzur",
				"licence": "MIT", "url": "https://godotengine.org",
				"what": "Game engine. Its licence and third-party notices are at the end of this page.",
			},
			{
				"name": "Human Shaders", "by": "© 2025 MatMADNESS",
				"licence": "CC BY 4.0 · MIT", "url": "https://github.com/matmadness/HumanShaders",
				"licence_url": "https://creativecommons.org/licenses/by/4.0/",
				"what": "Skin pore and iris textures (CC BY 4.0, unchanged); the skin lighting follows its skin shader (MIT).",
			},
			{
				"name": "NVIDIA SimReady Assets", "by": "© NVIDIA Corporation", "licence": "CC BY 4.0",
				"url": "https://huggingface.co/datasets/nvidia/simready-assets",
				"licence_url": "https://creativecommons.org/licenses/by/4.0/",
				"what": "The food, plates and kitchenware on the castle's feast and kitchen tables (decimated, re-baked onto one texture atlas and arranged into table settings).",
			},
			{
				"name": "godot-rust", "by": "godot-rust developers", "licence": "MPL 2.0",
				"url": "https://github.com/godot-rust/gdext", "licence_url": "https://mozilla.org/MPL/2.0/",
				"what": "The bridge between the game's Rust code and the engine. The other Rust libraries are listed below.",
			},
		],
	},
	{
		"title": "Fonts",
		"entries": [
			{
				"name": "Literata", "by": "© 2017 The Literata Project Authors (TypeTogether)",
				"licence": "SIL OFL 1.1", "url": "https://github.com/googlefonts/literata",
				"what": "Interface lettering. Its licence is at the end of this page.",
			},
		],
	},
	{
		"title": "Free assets (CC0)",
		"entries": [
			{
				"name": "Quaternius", "by": "", "licence": "CC0 1.0", "url": "https://quaternius.com",
				"what": "Modular Character Outfits, Universal Base Characters and the Universal Animation Library: the hero's body, clothes, hair and animations",
			},
			{
				"name": "KayKit Adventurers", "by": "Kay Lousberg", "licence": "CC0 1.0", "url": "https://kaylousberg.com",
				"what": "The robed wizard and the wand",
			},
			{
				"name": "Poly Haven", "by": "", "licence": "CC0 1.0", "url": "https://polyhaven.com",
				"what": "Boulder, hessian and wood textures",
			},
			{
				"name": "Particle Pack", "by": "Kenney", "licence": "CC0 1.0", "url": "https://kenney.nl",
				"what": "Flame and spark sprites",
			},
		],
	},
	{
		"title": "Sound",
		"entries": [
			{
				"name": "Sonniss GDC Game Audio Bundle", "by": "Sonniss", "licence": "", "url": "https://sonniss.com/gameaudiogdc",
				"what": "Recorded sound effects",
			},
			{
				"name": "Stable Audio", "by": "Powered by Stability AI", "licence": "Stability AI Community License",
				"url": "https://stability.ai/community-license-agreement",
				"what": "Generated sound effects and music",
			},
			{
				"name": "ElevenLabs", "by": "", "licence": "", "url": "https://elevenlabs.io",
				"what": "Generated sound effects and music",
			},
		],
	},
	{
		"title": "Made with",
		"entries": [
			{
				"name": "Blender", "by": "Blender Foundation", "licence": "", "url": "https://www.blender.org",
				"what": "Modelling, rigging and baking",
			},
			{
				"name": "Mixamo", "by": "Adobe", "licence": "", "url": "https://www.mixamo.com",
				"what": "Walking, running and jumping animations",
			},
			{
				"name": "Tencent Hunyuan3D, Meshy", "by": "", "licence": "", "url": "",
				"what": "Generated 3D models of characters, creatures and items",
			},
			{
				"name": "OpenAI, Google, Alibaba Wan (fal.ai)", "by": "", "licence": "", "url": "",
				"what": "Generated icons, textures and spell effects",
			},
			{
				"name": "Hunyuan Motion (fal.ai)", "by": "", "licence": "", "url": "",
				"what": "Generated spell-casting motion",
			},
		],
	},
]

const NAME_SIZE := 16
const TEXT_SIZE := 14
const NOTICE_SIZE := 12

## A scrolling page; it fills the first time it is shown (Godot's notices are
## long: building them is cheap, laying them out is not).
static func build() -> RichTextLabel:
	var page := RichTextLabel.new()
	page.name = "Credits"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.scroll_active = true
	page.selection_enabled = true
	page.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.focus_mode = Control.FOCUS_NONE
	page.add_theme_font_override("normal_font", HudKit.body())
	page.add_theme_font_override("bold_font", HudKit.bold())
	page.add_theme_font_size_override("normal_font_size", TEXT_SIZE)
	page.add_theme_font_size_override("bold_font_size", NAME_SIZE)
	page.add_theme_color_override("default_color", HudKit.TEXT)
	page.meta_clicked.connect(func(meta: Variant): OS.shell_open(String(meta)))
	page.visibility_changed.connect(func():
		if page.is_visible_in_tree() and page.get_total_character_count() == 0:
			fill(page))
	return page

static func fill(page: RichTextLabel) -> void:
	page.clear()
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(I18n.t("%s is built on the work of the people and tools below. Thank you.") % UITheme.GAME_TITLE)
	page.pop()
	page.newline()
	for section: Dictionary in SECTIONS:
		_heading(page, I18n.t(String(section["title"])))
		for entry: Dictionary in section["entries"]:
			_entry(page, entry)
	_crates(page)
	_heading(page, I18n.t("Literata licence"))
	_notice(page, FileAccess.get_file_as_string(OFL_PATH))
	_heading(page, I18n.t("Godot Engine licence"))
	_notice(page, Engine.get_license_text())
	_heading(page, I18n.t("Third-party components of Godot Engine"))
	for component: Dictionary in Engine.get_copyright_info():
		page.push_bold()
		page.add_text(String(component["name"]))
		page.pop()
		page.newline()
		for part: Dictionary in component["parts"]:
			var lines: PackedStringArray = []
			for line: String in part["copyright"]:
				lines.append("© " + line)
			lines.append(String(part["license"]))
			_notice(page, "\n".join(lines))
	_heading(page, I18n.t("Licence texts"))
	var licences: Dictionary = Engine.get_license_info()
	for key: String in licences:
		page.push_bold()
		page.add_text(key)
		page.pop()
		page.newline()
		_notice(page, String(licences[key]))

## The Rust libraries in the client extension: name, version, licence and
## authors, one line each.
static func _crates(page: RichTextLabel) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CRATES_PATH))
	if not parsed is Array:
		return
	_heading(page, I18n.t("Rust libraries"))
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(I18n.t("Compiled into the game's extension; their licence texts are at the end of this page."))
	page.pop()
	page.newline()
	page.newline()
	page.push_font_size(NOTICE_SIZE + 1)
	for crate: Dictionary in parsed:
		page.push_color(HudKit.GOLD_HI)
		page.add_text("%s %s" % [crate["name"], crate["version"]])
		page.pop()
		page.push_color(HudKit.GOLD_LT)
		page.add_text("  " + String(crate["licence"]))
		page.pop()
		var authors: Array = crate.get("authors", [])
		if not authors.is_empty():
			page.push_color(HudKit.TEXT_DIM)
			page.add_text("  © " + ", ".join(PackedStringArray(authors)))
			page.pop()
		page.newline()
	page.pop()
	page.newline()

static func _heading(page: RichTextLabel, text: String) -> void:
	page.newline()
	page.push_font(HudKit.title(), 15)
	page.push_color(HudKit.GOLD)
	page.add_text(I18n.upper(text))
	page.pop()
	page.pop()
	page.newline()

static func _entry(page: RichTextLabel, entry: Dictionary) -> void:
	page.push_bold()
	page.push_color(HudKit.GOLD_HI)
	page.add_text(String(entry["name"]))
	page.pop()
	page.pop()
	var licence := String(entry.get("licence", ""))
	if licence != "":
		page.add_text("  ")
		page.push_color(HudKit.GOLD_LT)
		var licence_url := String(entry.get("licence_url", ""))
		if licence_url != "":
			page.push_meta(licence_url)
		page.add_text(licence)
		if licence_url != "":
			page.pop()
		page.pop()
	page.newline()
	if String(entry.get("by", "")) != "":
		page.push_color(HudKit.TEXT_DIM)
		page.add_text(String(entry["by"]))
		page.pop()
		page.newline()
	page.add_text(I18n.t(String(entry["what"])))
	page.newline()
	var url := String(entry.get("url", ""))
	if url != "":
		page.push_color(HudKit.GOLD_LT)
		page.push_meta(url)
		page.add_text(url)
		page.pop()
		page.pop()
		page.newline()
	page.newline()

static func _notice(page: RichTextLabel, text: String) -> void:
	page.push_font_size(NOTICE_SIZE)
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(text.strip_edges())
	page.pop()
	page.pop()
	page.newline()
	page.newline()
