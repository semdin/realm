extends RefCounted
class_name GameSettings

## The player's settings (the Esc menu's Settings window), per machine in
## `user://settings.cfg`, applied live:
##
##   * the interface scale - the Window's content scale factor, so every
##     Control (HUD, windows, prompts) scales together and stays anchored;
##   * the mouse-look sensitivity main.gd multiplies its camera turn by;
##   * screen shake and screen flash, 0 (off) to 1.5 (1 = as authored):
##     main.gd's shake_camera and LevelUpFX's flash read them;
##   * fullscreen (also F11);
##   * the key bindings of the gameplay keys: main.gd, the action bar and the
##     movement read `key(action)` instead of fixed keys.
##
## The four sound volumes and the master volume belong to AudioManager (its
## buses, saved in user://audio_settings.json); the window drives that one API.
## The language belongs to I18n (user://language.cfg).
##
## The old client's 1.0 meant a content scale of 0.85 on a 1280x720 canvas
## stretched to the window (about 1.06 at 1600x900); this client lays its
## interface out at the window's own 1600x900 pixels, so the same size is a
## content scale of 1.0 here: UI_SCALE_BASE.
##
## A lazily made static singleton: any script asks `GameSettings.instance()`
## (main.gd makes it first, before the front door builds a label).

signal changed(what: String)

const SETTINGS_PATH := "user://settings.cfg"
const GENERAL := "general"
const BINDINGS := "bindings"

const UI_SCALE_DEFAULT := 1.0
const UI_SCALE_BASE := 1.0
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 1.75
const SENSITIVITY_DEFAULT := 1.0
const SENSITIVITY_MIN := 0.25
const SENSITIVITY_MAX := 3.0
const INTENSITY_DEFAULT := 1.0
const INTENSITY_MIN := 0.0
const INTENSITY_MAX := 1.5
## Master first, then AudioManager's buses.
const VOLUMES := ["Master", "Music", "SFX", "UI", "Ambience"]

## The keys the settings may rebind and the key each has by default - the
## keys this client has always used. A rebind replaces the action's key, and a
## key already driving another action is refused, so no key ever does two
## things. Escape (menu / close), Enter on the keypad and the mouse stay fixed.
const BINDABLE := {
	"move_forward": KEY_W,
	"move_backward": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"jump": KEY_SPACE,
	"descend": KEY_CTRL,
	"ride": KEY_SHIFT,
	"target_cycle": KEY_TAB,
	"pickup_loot": KEY_Z,
	"interact": KEY_F,
	"chat": KEY_ENTER,
	"inventory": KEY_I,
	"character": KEY_C,
	"quest_log": KEY_J,
	"workshop": KEY_O,
	"dungeon_guide": KEY_K,
	"spell_1": KEY_1,
	"spell_2": KEY_2,
	"spell_3": KEY_3,
	"spell_4": KEY_4,
	"spell_5": KEY_Q,
	"spell_6": KEY_E,
	"spell_7": KEY_5,
	"spell_8": KEY_6,
	"quick_1": KEY_F1,
	"quick_2": KEY_F2,
	"quick_3": KEY_F3,
	"quick_4": KEY_F4,
}
## Keys no action may take: they have their own fixed use.
const RESERVED := [KEY_ESCAPE, KEY_F11, KEY_KP_ENTER]

static var _instance: GameSettings = null

var ui_scale := UI_SCALE_DEFAULT
var mouse_sensitivity := SENSITIVITY_DEFAULT
var shake := INTENSITY_DEFAULT
var flash := INTENSITY_DEFAULT
var fullscreen := false
## action -> physical keycode
var bindings: Dictionary = {}
var _by_key: Dictionary = {}
var load_error := ""

static func instance() -> GameSettings:
	if _instance == null:
		_instance = GameSettings.new()
		_instance.load_from_disk()
	return _instance

## Read the file again and apply it (the menu check: what a new start sees).
static func reload_from_disk() -> GameSettings:
	instance().load_from_disk()
	instance().apply_all()
	return _instance

## The physical key bound to `action`.
static func key(action: String) -> int:
	return int(instance().bindings.get(action, BINDABLE.get(action, 0)))

## The action `keycode` drives ("" when none).
static func action_for(keycode: int) -> String:
	return String(instance()._by_key.get(keycode, ""))

static func pressed(action: String) -> bool:
	return Input.is_physical_key_pressed(key(action))

## The key's name as a slot or a row shows it ("Q", "F1", "Space").
static func key_name(action: String) -> String:
	return OS.get_keycode_string(key(action))

static func sensitivity() -> float:
	return instance().mouse_sensitivity

static func shake_value() -> float:
	return instance().shake

static func flash_value() -> float:
	return instance().flash

static func global_path() -> String:
	return ProjectSettings.globalize_path(SETTINGS_PATH)

## ------------------------------------------------------------------- disk

func load_from_disk() -> void:
	ui_scale = UI_SCALE_DEFAULT
	mouse_sensitivity = SENSITIVITY_DEFAULT
	shake = INTENSITY_DEFAULT
	flash = INTENSITY_DEFAULT
	fullscreen = false
	bindings.clear()
	for action: String in BINDABLE:
		bindings[action] = int(BINDABLE[action])
	load_error = ""
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error == OK:
		ui_scale = clampf(float(config.get_value(GENERAL, "ui_scale", UI_SCALE_DEFAULT)), UI_SCALE_MIN, UI_SCALE_MAX)
		mouse_sensitivity = clampf(float(config.get_value(GENERAL, "mouse_sensitivity", SENSITIVITY_DEFAULT)),
			SENSITIVITY_MIN, SENSITIVITY_MAX)
		shake = clampf(float(config.get_value(GENERAL, "shake", INTENSITY_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
		flash = clampf(float(config.get_value(GENERAL, "flash", INTENSITY_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
		fullscreen = bool(config.get_value(GENERAL, "fullscreen", false))
		var taken := {}
		for action: String in BINDABLE:
			var stored := int(config.get_value(BINDINGS, action, int(BINDABLE[action])))
			# a hand-edited file must not bind one key twice or take a fixed key
			if stored <= 0 or taken.has(stored) or RESERVED.has(stored):
				stored = int(BINDABLE[action])
			taken[stored] = true
			bindings[action] = stored
	elif error != ERR_FILE_NOT_FOUND:
		load_error = "could not read %s (error %d)" % [SETTINGS_PATH, error]
		push_warning("[GameSettings] " + load_error)
	_index_keys()

func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value(GENERAL, "ui_scale", ui_scale)
	config.set_value(GENERAL, "mouse_sensitivity", mouse_sensitivity)
	config.set_value(GENERAL, "shake", shake)
	config.set_value(GENERAL, "flash", flash)
	config.set_value(GENERAL, "fullscreen", fullscreen)
	for action: String in bindings:
		config.set_value(BINDINGS, action, int(bindings[action]))
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		load_error = "could not write %s (error %d)" % [SETTINGS_PATH, error]
		push_warning("[GameSettings] " + load_error)

func _index_keys() -> void:
	_by_key.clear()
	for action: String in bindings:
		_by_key[int(bindings[action])] = action

## ------------------------------------------------------------------ apply

func apply_all() -> void:
	apply_ui_scale()
	apply_window_mode()
	changed.emit("all")

func apply_ui_scale() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		tree.root.content_scale_factor = ui_scale * UI_SCALE_BASE

func apply_window_mode() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)

## ---------------------------------------------------------------- setters

func set_ui_scale(value: float) -> void:
	ui_scale = clampf(snappedf(value, 0.05), UI_SCALE_MIN, UI_SCALE_MAX)
	apply_ui_scale()
	save_to_disk()
	changed.emit("ui_scale")

func set_mouse_sensitivity(value: float) -> void:
	mouse_sensitivity = clampf(value, SENSITIVITY_MIN, SENSITIVITY_MAX)
	save_to_disk()
	changed.emit("mouse_sensitivity")

func set_shake(value: float) -> void:
	shake = clampf(value, INTENSITY_MIN, INTENSITY_MAX)
	save_to_disk()
	changed.emit("shake")

func set_flash(value: float) -> void:
	flash = clampf(value, INTENSITY_MIN, INTENSITY_MAX)
	save_to_disk()
	changed.emit("flash")

func set_fullscreen(on: bool) -> void:
	fullscreen = on
	apply_window_mode()
	save_to_disk()
	changed.emit("fullscreen")

func toggle_fullscreen() -> void:
	set_fullscreen(not fullscreen)

## Volume 0..1 of "Master" or one of AudioManager's buses (saved by it).
func set_volume(bus: String, linear: float) -> void:
	var audio := _audio()
	if audio != null and VOLUMES.has(bus):
		audio.call("set_volume", bus, linear)
		changed.emit("volume")

func volume(bus: String) -> float:
	var audio := _audio()
	return float(audio.call("get_volume", bus)) if audio != null else 1.0

func _audio() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("AudioManager") if tree != null and tree.root != null else null

## Bind `action` to `keycode`: "" when done, else why not ("reserved", or
## "taken:<action>" for the action that key already drives).
func set_binding(action: String, keycode: int) -> String:
	if not BINDABLE.has(action) or keycode <= 0:
		return "invalid"
	if RESERVED.has(keycode):
		return "reserved"
	var other := String(_by_key.get(keycode, ""))
	if other != "" and other != action:
		return "taken:" + other
	bindings[action] = keycode
	_index_keys()
	save_to_disk()
	changed.emit("bindings")
	return ""

func reset_bindings() -> void:
	for action: String in BINDABLE:
		bindings[action] = int(BINDABLE[action])
	_index_keys()
	save_to_disk()
	changed.emit("bindings")
