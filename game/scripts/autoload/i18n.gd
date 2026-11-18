extends Node

## I18n autoload - the game's language.
##
## Source text is English everywhere (scripts, scenes, the data JSON): every
## English string is its own message id. A language is one gettext catalogue
## in `res://locale/<code>.po` listed under `internationalization/locale/
## translations` in project.godot; English needs no catalogue. Until the player
## picks one the game follows the system: Turkish on a Turkish system, English
## everywhere else.
##
## Translating: nodes use `tr("English text")` (and `tr("Level %d") % level`
## for formatted text - translate the pattern, then format); static functions
## and data use `I18n.t()`. Content from the data JSON (item, mob, quest, map
## names) is translated where it is shown: `I18n.t(String(item.name))`; a
## `{key:action}` in such text comes out as the key bound to it now.
## `tools/i18n/i18n.py` collects every message into locale/messages.pot and
## merges it into each catalogue; see docs/localization.md.
##
## The choice is per machine, not per account (the login screen needs it before
## anyone signs in): `<data root>/language.cfg`, beside the shared settings.
## The dedicated server always runs in English, so anything it composes reaches
## clients as message ids they translate themselves.

signal language_changed(code: String)

## Listed first in the pickers; the language of a Turkish system.
const DEFAULT_LANGUAGE := "tr"
const SOURCE_LANGUAGE := "en"
const CONFIG_FILE := "language.cfg"
## Each language's own name for itself (the picker shows these). A language
## missing here falls back to the engine's English name for the locale.
const NATIVE_NAMES := {
	"tr": "Türkçe",
	"en": "English",
	"de": "Deutsch",
	"fr": "Français",
	"es": "Español",
	"ru": "Русский",
	"pt": "Português",
}

var current := SOURCE_LANGUAGE

func _enter_tree() -> void:
	# Before any other autoload or the first scene builds a single label.
	# `--lang=<code>` wins everywhere (capture tools, headless checks).
	var forced := _cmdline_language()
	if forced != "":
		apply(forced, false)
	else:
		apply(_load_choice(), false)

## ------------------------------------------------------------------ query

## Every language the build can show: English plus each loaded catalogue,
## the default first. [{code, name}]
func languages() -> Array:
	var codes: Array = [SOURCE_LANGUAGE]
	for code in TranslationServer.get_loaded_locales():
		var short := String(code).get_slice("_", 0)
		if not codes.has(short):
			codes.append(short)
	codes.sort_custom(func(a, b):
		if a == DEFAULT_LANGUAGE or b == DEFAULT_LANGUAGE:
			return a == DEFAULT_LANGUAGE
		return a < b)
	return codes.map(func(code): return {"code": code, "name": native_name(code)})

func native_name(code: String) -> String:
	return String(NATIVE_NAMES.get(code, TranslationServer.get_locale_name(code)))

func is_turkish() -> bool:
	return current == "tr"

## ------------------------------------------------------------------ change

## Switch the language, remember it, and tell the screens that rebuild
## themselves (`language_changed`). Labels showing plain message ids follow on
## their own; text composed earlier keeps its language until it is rebuilt.
func set_language(code: String) -> void:
	apply(code, true)

func apply(code: String, persist: bool) -> void:
	var known: Array = languages().map(func(l): return String(l.code))
	if not known.has(code):
		code = SOURCE_LANGUAGE
	var changed := code != current
	current = code
	TranslationServer.set_locale(code)
	if persist:
		_save_choice(code)
	if changed and is_inside_tree():
		language_changed.emit(code)

## ---------------------------------------------------------------- helpers

## Translate outside a node (static functions, data). `context` separates two
## meanings of the same English text (msgctxt in the catalogue).
static func t(message: String, context: String = "") -> String:
	if message.is_empty():
		return message
	var text := String(TranslationServer.translate(message, context))
	return GameSettings.fill_keys(text) if text.contains("{key:") else text

## Numbers as the shown language writes them, one rule for every window:
## Turkish (and the other languages listed) write 1,8 and 10.000, English 1.8
## and 10,000. Patterns take the number as `%s` from these, never `%.1f`
## (which always writes a point).
const DECIMAL_COMMA := ["tr", "de", "es", "pt", "fr", "ru"]

static func _uses_comma() -> bool:
	return DECIMAL_COMMA.has(TranslationServer.get_locale().get_slice("_", 0))

## `value` with `decimals` places: 1,8 / 1.8.
static func num(value: float, decimals := 1) -> String:
	var text := ("%." + str(maxi(decimals, 0)) + "f") % value
	return text.replace(".", ",") if _uses_comma() else text

## A whole number in groups of three: 10.000 / 10,000.
static func whole(value: int) -> String:
	var digits := str(absi(value))
	var sep := "." if _uses_comma() else ","
	var out := ""
	while digits.length() > 3:
		out = sep + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out

## Text the world server composed in English (chat replies, boss and monolith
## lines, dungeon messages, creature names): a fixed line is its own message
## id; a line with a name or a number in it is matched against COMPOSED and
## rebuilt from the translated pattern, its pieces translated in turn.
func from_server(text: String) -> String:
	var exact := t(text)
	if exact != text or current == SOURCE_LANGUAGE or text.is_empty():
		return exact
	for pattern in COMPOSED:
		var found := _pattern_regex(pattern).search(text)
		if found == null:
			continue
		var kinds := _placeholders(pattern)
		var args: Array = []
		for i in range(1, found.get_group_count() + 1):
			var piece := found.get_string(i)
			# A title, a place or a creature; a player's name stays as it is.
			args.append(int(piece) if kinds[i - 1] == "d" else from_server(piece))
		return t(pattern) % args
	return text

## A creature's name as the server sends it (species, "Elite " + species, a
## boss part).
func mob_name(text: String) -> String:
	return from_server(text)

# i18n-begin
const COMPOSED := [
	# a dungeon's weekly record (the map server, to the whole realm)
	"%s set this week's record in %s (%s): %s!",
	# the realm coordinator (parties)
	"%s declined your party invitation.",
	"%s is not online.",
	"%s is not accepting invitations.",
	"You are muted for %d more min.",
	"You can shout from level %d.",
	"You can shout again in %d s.",
	"%s is already in a party.",
	"Party invitation sent to %s.",
	"%s joined the party.",
	"%s is not in your party.",
	"Your party invitation to %s expired.",
	"GAs: %s",
	"No player called '%s' is online.",
	"You invited %s to your party.",
	"%s was removed from the party.",
	"%s now leads the party.",
	"%s is already in a duel.",
	"%s is not in a party.",
	"%s is too far away to duel.",
	"You challenged %s's party to a group duel.",
	"You challenged %s to a duel.",
	"New title earned: %s!",
	"Elite %s",
	"Threehead's %s Head",
	"Snare %s Vine",
	"Threehead's %s head slumps!",
	"Threehead's %s head slumps! Threehead howls in fury!",
	"%s begins to ring the sleep chime...",
	"A vine shrivels in the flames! %d left.",
	"%s: a wave of creatures answers its call! (Wave %d/3)",
	"The %s has been shattered by %s! Riches shower the realm!",
	"A new %s has manifested in the realm!",
]
## Fixed server lines, listed so the catalogue carries them.
const SERVER_LINES := [
	# the realm map server and coordinator (chat, parties)
	"You declined the party invitation.",
	"You have no party invitation.",
	"Only the party leader can invite.",
	"Your party is full.",
	"The invitation is no longer valid.",
	"You are already in a party.",
	"That party is full.",
	"You were removed from the party.",
	"Shouting reaches no one right now.",
	"Unknown command. Try: /p, /invite <name>, /accept, /decline, /leave, /kick <name>, /promote <name>, !shout",
	"Parties are not available right now.",
	"Rain started.",
	"Rain stopped.",
	"Only a GA can use /ga.",
	"GA rights are set in the server configuration.",
	"GA: /ga rain on|off, /ga list",
	"There is no party invitation to accept.",
	"You joined the party.",
	"Invitation declined.",
	"You left the party.",
	"You are not in a party.",
	"You cannot invite yourself.",
	"That player is already in a party.",
	"Only the party leader can do that.",
	"The party is full (5).",
	"That player is not in your party.",
	"That did not work.",
	"Unknown command. Party: /invite Name, /accept, /decline, /leave, /kick Name, /promote Name, /p text. Duel: /duel Name, /gduel Name, /daccept, /ddecline, /yield",
	"Usage: /duel Name",
	"Usage: /gduel Name",
	"You cannot duel yourself.",
	"You are already in a duel.",
	"Both duelists must be alive.",
	"You need a party for a group duel.",
	"Only the party leader can call a group duel.",
	"You cannot duel your own party.",
	"There is no duel challenge to accept.",
	"The challenger is no longer here.",
	"One of you is already in a duel.",
	"You are too far apart to duel.",
	"The parties changed - challenge again.",
	"Duel declined.",
	"You are not in a duel.",
	# a refused join (the map server, the coordinator, a ticket's check)
	"ticket expired",
	"ticket already used",
	"ticket signature does not verify",
	"malformed ticket",
	"the realm is not ready; try again",
	"the realm is restarting; try again",
	"client version does not match the server",
	"character unavailable",
	"character not found",
]
# i18n-end

var _pattern_cache: Dictionary = {}

func _pattern_regex(pattern: String) -> RegEx:
	if not _pattern_cache.has(pattern):
		var source := "^"
		var i := 0
		while i < pattern.length():
			var two := pattern.substr(i, 2)
			if two == "%s" or two == "%d":
				source += "(.+?)" if two == "%s" else "(-?\\d+)"
				i += 2
				continue
			var ch := pattern[i]
			source += ("\\" + ch) if ".^$*+?()[]{}|\\/".contains(ch) else ch
			i += 1
		_pattern_cache[pattern] = RegEx.create_from_string(source + "$")
	return _pattern_cache[pattern]

## "s" / "d" for each placeholder of `pattern`, in order.
static func _placeholders(pattern: String) -> Array:
	var kinds: Array = []
	var at := pattern.find("%")
	while at >= 0 and at + 1 < pattern.length():
		var kind := pattern[at + 1]
		if kind == "s" or kind == "d":
			kinds.append(kind)
		at = pattern.find("%", at + 2)
	return kinds

## Upper case that knows the Turkish dotted/dotless i (i -> İ, ı -> I); the
## engine's to_upper() would print "BILGI" for "Bilgi".
static func upper(text: String) -> String:
	if TranslationServer.get_locale().begins_with("tr"):
		text = text.replace("i", "İ").replace("ı", "I")
	return text.to_upper()

## Lower case counterpart of upper() (I -> ı, İ -> i in Turkish).
static func lower(text: String) -> String:
	if TranslationServer.get_locale().begins_with("tr"):
		text = text.replace("I", "ı").replace("İ", "i")
	return text.to_lower()

## ---------------------------------------------------------------- storage

func _config_path() -> String:
	return "user://" + CONFIG_FILE

func _cmdline_language() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if String(arg).begins_with("--lang="):
			return String(arg).substr(7)
	return ""

## What the player picked, else the system's language.
func _load_choice() -> String:
	var config := ConfigFile.new()
	if config.load(_config_path()) != OK:
		return system_language()
	return String(config.get_value("general", "language", system_language()))

## The language for this system: `THOUSANDREALMS_LANG` when set (as the launcher
## reads it), else the system's own; Turkish for Turkish, otherwise English.
static func system_language() -> String:
	var tag := OS.get_environment("THOUSANDREALMS_LANG").strip_edges()
	if tag == "":
		tag = OS.get_locale_language()
	return "tr" if tag.to_lower().begins_with("tr") else SOURCE_LANGUAGE

func _save_choice(code: String) -> void:
	var config := ConfigFile.new()
	config.set_value("general", "language", code)
	DirAccess.make_dir_recursive_absolute(_config_path().get_base_dir())
	var error := config.save(_config_path())
	if error != OK:
		push_warning("[I18n] could not save the language (error %d)" % error)
