extends RefCounted
class_name GameCredits

## The Credits page of the Settings window, which the login screen opens too:
## how the game was made (much of it with AI tools, said first), whose work it
## is built from, and every licence notice. The list is
## res://assets/credits/credits.json, the Rust libraries in the client
## extension res://assets/credits/rust_crates.json, and the full texts
## res://assets/credits/THIRD_PARTY_NOTICES.txt, the same file every client
## package carries beside the game: tools/release/gen_notices.py writes the
## last two from credits.json, cargo and the engine, so run it when a dependency
## changes.

const CREDITS_PATH := "res://assets/credits/credits.json"
const CRATES_PATH := "res://assets/credits/rust_crates.json"
const NOTICES_PATH := "res://assets/credits/THIRD_PARTY_NOTICES.txt"
const FULL_TEXTS := "notices:full"

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
	page.threaded = true
	page.meta_clicked.connect(func(meta: Variant):
		if String(meta) == FULL_TEXTS:
			_full_texts(page)
		else:
			OS.shell_open(String(meta)))
	page.visibility_changed.connect(func():
		if page.is_visible_in_tree() and page.get_total_character_count() == 0:
			fill(page))
	return page

static func fill(page: RichTextLabel) -> void:
	page.clear()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CREDITS_PATH))
	var credits: Dictionary = parsed if parsed is Dictionary else {}
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(I18n.t("%s is built on the work of the people and tools below. Thank you.") % UITheme.GAME_TITLE)
	page.pop()
	page.newline()
	page.newline()
	page.push_color(HudKit.PARCHMENT)
	page.add_text(I18n.t(String(credits.get("ai_notice", ""))))
	page.pop()
	page.newline()
	for section: Dictionary in credits.get("sections", []):
		_heading(page, I18n.t(String(section["title"])))
		for entry: Dictionary in section["entries"]:
			_entry(page, entry)
	_crates(page)
	_heading(page, I18n.t("Licence texts"))
	page.push_color(HudKit.GOLD_LT)
	page.push_meta(FULL_TEXTS)
	page.add_text(I18n.t("Show every licence text"))
	page.pop()
	page.pop()
	page.newline()

## Every notice, once: long, so only when asked for.
static func _full_texts(page: RichTextLabel) -> void:
	if page.has_meta(&"full_texts"):
		return
	page.set_meta(&"full_texts", true)
	page.newline()
	_notice(page, FileAccess.get_file_as_string(NOTICES_PATH))

## The Rust libraries in the client extension: name, version, licence and
## authors, one line each.
static func _crates(page: RichTextLabel) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CRATES_PATH))
	if not parsed is Array:
		return
	_heading(page, I18n.t("Rust libraries"))
	page.push_color(HudKit.TEXT_DIM)
	page.add_text(I18n.t("Compiled into the game's extension; their licence texts are with the others below."))
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
