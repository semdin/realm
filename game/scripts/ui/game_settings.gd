extends RefCounted
class_name GameSettings

## The player's settings (the Esc menu's Settings window), per machine in
## `user://settings.cfg`, applied live:
##
##   * the interface scale - the Window's content scale factor, so every
##     Control (HUD, windows, prompts) scales together and stays anchored.
##     Automatic until the player moves the slider: auto_ui_scale() reads the
##     window size and the screen's DPI, so a 4K or Retina screen starts
##     readable and a small one still fits the layout;
##   * the mouse-look sensitivity main.gd multiplies its camera turn by;
##   * screen shake and screen flash, 0 (off) to 1.5 (1 = as authored):
##     main.gd's shake_camera and LevelUpFX's flash read them;
##   * the window: windowed, fullscreen or exclusive fullscreen (also F11, on a
##     Mac Control+Command+F), the windowed size, VSync and the frame cap;
##     the first window is fitted to the screen (fit_first_window);
##   * the key bindings of the gameplay keys: main.gd, the action bar and the
##     movement read `key(action)` instead of fixed keys;
##   * the graphics quality ("auto" or a QualityPreset name; main.gd applies a
##     change to the live world), the 3D render scale ("auto" follows the
##     preset) and the time of day on the grounds (DayNight: the server clock
##     in GMT+3, or held at one of the day's five faces);
##   * whether the controls introduction (FirstSteps) still has to be shown.
##
## A Mac gets its own default keys (MAC_KEYS): Control-click is a right click
## there, the function keys are media keys, Control+arrows is Mission Control
## and F11 is Show Desktop. Key names follow the platform (key_name).
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
## 2: a Mac has its own default keys (MAC_KEYS).
const KEYS_VERSION := 2

const UI_SCALE_DEFAULT := 1.0
const UI_SCALE_BASE := 1.0
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 3.0
## The canvas the interface was laid out for, and the smallest one it still
## fits: the automatic scale never leaves less room than this.
const UI_DESIGN_CANVAS := Vector2(1600.0, 900.0)
const UI_MIN_CANVAS := Vector2(1280.0, 720.0)
## How much of "the layout grown to fill the window" a large screen gets: full
## proportion would make a 27-inch 1440p interface look oversized.
const UI_FILL_SHARE := 0.85
## The smallest window, and the windowed size until the player sizes one.
const WINDOW_MIN := Vector2i(1024, 576)
const WINDOW_DEFAULT := Vector2i(1600, 900)
## What a title bar and the frame take from the usable screen.
const WINDOW_CHROME := Vector2i(16, 40)
const WINDOW_MODES := ["windowed", "fullscreen", "exclusive"]
const FPS_CHOICES := [0, 30, 60, 90, 120, 144, 165, 240]
## "auto" (the quality preset's) or a percentage of the window's pixels.
const RENDER_SCALE_CHOICES := ["auto", "100", "85", "75", "67", "50"]
const SENSITIVITY_DEFAULT := 1.0
const SENSITIVITY_MIN := 0.25
const SENSITIVITY_MAX := 3.0
const INTENSITY_DEFAULT := 1.0
const INTENSITY_MIN := 0.0
const INTENSITY_MAX := 1.5
const GRAPHICS_CHOICES := ["auto", "low", "medium", "high"]
const GRAPHICS_DEFAULT := "auto"
## Time of day on the grounds (DayNight): the server clock in GMT+3, or held at
## dawn, noon, afternoon, sunset or night.
const TIME_OF_DAY_CHOICES := ["system", "dawn", "noon", "afternoon", "sunset", "night"]
const TIME_OF_DAY_DEFAULT := "system"
## Master first, then AudioManager's buses.
const VOLUMES := ["Master", "Music", "SFX", "UI", "Ambience"]

## The keys the settings may rebind and the key each has by default - the
## keys this client has always used. A rebind replaces the action's key, and a
## key already driving another action is refused, so no key ever does two
## things (but for SHARED pairs, which never apply at once). Escape (menu /
## close), Enter on the keypad and the mouse stay fixed.
##
## The basic attack (the left mouse button's cast, repeating while held) has
## its key too: Ctrl, either side (Control on a Mac), the broom's descend key,
## since the attack is never cast mounted and descend does nothing on foot.
const BINDABLE := {
	"move_forward": KEY_W,
	"move_backward": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"jump": KEY_SPACE,
	"descend": KEY_CTRL,
	"basic_attack": KEY_CTRL,
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
	"world_map": KEY_M,
	"skills": KEY_V,
	"bestiary": KEY_B,
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
## What a Mac binds differently. Control is taken by the system (Control-click
## is a right click, Control+arrows moves Spaces) and F1-F4 are media keys until
## Fn is held, so the attack and the broom's descend sit on Option and the quick
## slots on the free number keys.
const MAC_KEYS := {
	"descend": KEY_ALT,
	"basic_attack": KEY_ALT,
	"quick_1": KEY_7,
	"quick_2": KEY_8,
	"quick_3": KEY_9,
	"quick_4": KEY_0,
}
## What a Mac keyboard prints on the keys that differ.
const MAC_KEY_NAMES := {
	KEY_META: "Command", KEY_ALT: "Option", KEY_CTRL: "Control",
	KEY_ENTER: "Return", KEY_BACKSPACE: "Delete", KEY_DELETE: "Forward Delete",
}
## The debug readout's fixed key in a dev run (main.gd): F3 is quick slot 3 here.
const DEBUG_KEY := KEY_F10
## Keys no action may take: they have their own fixed use.
const RESERVED := [KEY_ESCAPE, KEY_F11, KEY_KP_ENTER, DEBUG_KEY, KEY_META]
## Second keys that are not rebound: the arrow keys walk too (the old
## client's second keys), and loot is also taken with the key under Escape,
## left of 1, by its place on the keyboard (physical keycodes), so it is the
## same key on every layout: ` on a US board, " on a Turkish-Q one. A Mac's
## ISO board reports that key as the section key (§), so it counts too. A
## second key holds while its action is rebound and steps aside for any
## action bound to it.
const SECONDARY := {"move_forward": [KEY_UP], "move_backward": [KEY_DOWN], "move_left": [KEY_LEFT],
	"move_right": [KEY_RIGHT], "pickup_loot": [KEY_QUOTELEFT, KEY_SECTION]}
## Actions that may share one key because they never apply at once: the
## broom's descend (read held, only mounted) and the basic attack (on foot).
## The key's presses go to the second of the pair.
const SHARED := [["descend", "basic_attack"]]

static var _instance: GameSettings = null

## The manual interface scale; used once `ui_scale_auto` is off.
var ui_scale := UI_SCALE_DEFAULT
var ui_scale_auto := true
var mouse_sensitivity := SENSITIVITY_DEFAULT
var invert_mouse_y := false
var shake := INTENSITY_DEFAULT
var flash := INTENSITY_DEFAULT
## "windowed" | "fullscreen" (borderless) | "exclusive"
var window_mode := "windowed"
## True in either fullscreen mode.
var fullscreen := false
## The windowed size the player left (ZERO: none yet, fit the screen).
var window_size := Vector2i.ZERO
var window_maximized := false
var vsync := true
## Frames per second at most (0: no cap).
var fps_cap := 0
var render_scale := "auto"
var show_fps := false
var graphics_quality := GRAPHICS_DEFAULT
var time_of_day := TIME_OF_DAY_DEFAULT
## The controls introduction was finished or skipped on this machine.
var intro_done := false
## The quest tracker is folded to its header (HudTracker).
var tracker_collapsed := false
## action -> physical keycode
var bindings: Dictionary = {}
var _by_key: Dictionary = {}
var load_error := ""
var _window_fitted := false
var _resize_serial := 0

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

## A Mac (`--assume-macos` takes the path on any machine: checks).
static func is_mac() -> bool:
	return OS.get_name() == "macOS" or OS.get_cmdline_user_args().has("--assume-macos")

## The key `action` has until the player rebinds it, on this platform.
static func default_key(action: String) -> int:
	if is_mac() and MAC_KEYS.has(action):
		return int(MAC_KEYS[action])
	return int(BINDABLE.get(action, 0))

## The physical key bound to `action`.
static func key(action: String) -> int:
	return int(instance().bindings.get(action, default_key(action)))

## The action a press of `keycode` drives ("" when none): its bound action,
## else the action whose fixed second key it is.
static func action_for(keycode: int) -> String:
	var bound := String(instance()._by_key.get(keycode, ""))
	if bound != "":
		return bound
	for action: String in SECONDARY:
		if (SECONDARY[action] as Array).has(keycode):
			return action
	return ""

static func pressed(action: String) -> bool:
	if Input.is_physical_key_pressed(key(action)):
		return true
	for second: int in SECONDARY.get(action, []):
		if not instance()._by_key.has(second) and Input.is_physical_key_pressed(second):
			return true
	return false

## Whether `a` and `b` may hold one key (SHARED).
static func shares(a: String, b: String) -> bool:
	for pair: Array in SHARED:
		if pair.has(a) and pair.has(b) and a != b:
			return true
	return false

## The fixed second key's name for `action` as this keyboard prints it ("" when
## it has none or something else is bound to it).
static func second_key_name(action: String) -> String:
	for second: int in SECONDARY.get(action, []):
		if instance()._by_key.has(second):
			continue
		# the character the layout prints on it (", `, §), else its name
		var label := int(DisplayServer.keyboard_get_label_from_physical(second as Key))
		if label > 32 and label < int(KEY_SPECIAL):
			return String.chr(label)
		if label != 0:
			return OS.get_keycode_string(label as Key)
	return ""

## The key's name as a slot or a row shows it ("Q", "F1", "Space"; "Option" on
## a Mac).
static func key_name(action: String) -> String:
	return keycode_name(key(action))

static func keycode_name(keycode: int) -> String:
	if is_mac() and MAC_KEY_NAMES.has(keycode):
		return String(MAC_KEY_NAMES[keycode])
	return OS.get_keycode_string(keycode as Key)

## The fullscreen shortcut as this platform writes it.
static func fullscreen_shortcut() -> String:
	return "Control+Command+F" if is_mac() else "F11"

## Whether `event` is the fullscreen shortcut: F11 or Alt+Enter, on a Mac the
## system's Control+Command+F (F11 is Show Desktop, and Option is the attack).
static func is_fullscreen_chord(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if is_mac():
		return event.physical_keycode == KEY_F and event.ctrl_pressed and event.meta_pressed
	if event.physical_keycode == KEY_F11:
		return true
	return event.alt_pressed and (event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_KP_ENTER)

## A key pressed with Command on a Mac is the system's or the menu's (Command+Q,
## Command+M, Command+H), never a game key.
static func is_system_chord(event: InputEventKey) -> bool:
	return event.meta_pressed and is_mac()

## `{key:action}` in a sentence becomes that action's key as bound now: quest
## text, NPC lines and tips stay true after a rebind.
static func fill_keys(text: String) -> String:
	if not text.contains("{key:"):
		return text
	var out := text
	var at := out.find("{key:")
	while at >= 0:
		var end := out.find("}", at)
		if end < 0:
			break
		var action := out.substr(at + 5, end - at - 5)
		var shown := key_name(action) if BINDABLE.has(action) else action
		out = out.substr(0, at) + shown + out.substr(end + 1)
		at = out.find("{key:", at + shown.length())
	return out

static func sensitivity() -> float:
	return instance().mouse_sensitivity

## What a mouse movement up does to the camera's pitch: 1, or -1 inverted.
static func pitch_sign() -> float:
	return -1.0 if instance().invert_mouse_y else 1.0

static func shake_value() -> float:
	return instance().shake

static func flash_value() -> float:
	return instance().flash

static func global_path() -> String:
	return ProjectSettings.globalize_path(SETTINGS_PATH)

## ------------------------------------------------------------------- disk

func load_from_disk() -> void:
	ui_scale = UI_SCALE_DEFAULT
	ui_scale_auto = true
	mouse_sensitivity = SENSITIVITY_DEFAULT
	invert_mouse_y = false
	shake = INTENSITY_DEFAULT
	flash = INTENSITY_DEFAULT
	window_mode = "fullscreen" if fullscreen_default() else "windowed"
	window_size = Vector2i.ZERO
	window_maximized = false
	vsync = true
	fps_cap = 0
	render_scale = "auto"
	show_fps = false
	graphics_quality = GRAPHICS_DEFAULT
	time_of_day = TIME_OF_DAY_DEFAULT
	intro_done = false
	tracker_collapsed = false
	bindings.clear()
	for action: String in BINDABLE:
		bindings[action] = default_key(action)
	load_error = ""
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error == OK:
		ui_scale = clampf(float(config.get_value(GENERAL, "ui_scale", UI_SCALE_DEFAULT)), UI_SCALE_MIN, UI_SCALE_MAX)
		# a file from before the automatic scale: a scale the player moved
		# stays theirs, the old untouched default becomes automatic
		ui_scale_auto = bool(config.get_value(GENERAL, "ui_scale_auto", is_equal_approx(ui_scale, UI_SCALE_DEFAULT)))
		mouse_sensitivity = clampf(float(config.get_value(GENERAL, "mouse_sensitivity", SENSITIVITY_DEFAULT)),
			SENSITIVITY_MIN, SENSITIVITY_MAX)
		invert_mouse_y = bool(config.get_value(GENERAL, "invert_mouse_y", false))
		shake = clampf(float(config.get_value(GENERAL, "shake", INTENSITY_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
		flash = clampf(float(config.get_value(GENERAL, "flash", INTENSITY_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
		var old_fullscreen := bool(config.get_value(GENERAL, "fullscreen", fullscreen_default()))
		var mode := String(config.get_value(GENERAL, "window_mode", "fullscreen" if old_fullscreen else "windowed"))
		window_mode = mode if WINDOW_MODES.has(mode) else "windowed"
		var stored_size: Variant = config.get_value(GENERAL, "window_size", Vector2i.ZERO)
		window_size = stored_size if stored_size is Vector2i else Vector2i.ZERO
		window_maximized = bool(config.get_value(GENERAL, "window_maximized", false))
		vsync = bool(config.get_value(GENERAL, "vsync", true))
		var cap := int(config.get_value(GENERAL, "fps_cap", 0))
		fps_cap = cap if FPS_CHOICES.has(cap) else 0
		var pixels := String(config.get_value(GENERAL, "render_scale", "auto"))
		render_scale = pixels if RENDER_SCALE_CHOICES.has(pixels) else "auto"
		show_fps = bool(config.get_value(GENERAL, "show_fps", false))
		intro_done = bool(config.get_value(GENERAL, "intro_done", false))
		tracker_collapsed = bool(config.get_value(GENERAL, "tracker_collapsed", false))
		var quality := String(config.get_value(GENERAL, "graphics_quality", GRAPHICS_DEFAULT))
		graphics_quality = quality if GRAPHICS_CHOICES.has(quality) else GRAPHICS_DEFAULT
		var hour := String(config.get_value(GENERAL, "time_of_day", TIME_OF_DAY_DEFAULT))
		time_of_day = hour if TIME_OF_DAY_CHOICES.has(hour) else TIME_OF_DAY_DEFAULT
		var taken := {}
		# a Mac's file from before its own default keys still holds the old
		# ones: they move to the Mac's, a key the player chose stays
		var old_mac_keys := is_mac() and int(config.get_value(GENERAL, "keys_version", 1)) < KEYS_VERSION
		for action: String in BINDABLE:
			var stored := int(config.get_value(BINDINGS, action, default_key(action)))
			if old_mac_keys and stored == int(BINDABLE[action]):
				stored = default_key(action)
			# a hand-edited file must not bind one key twice or take a fixed
			# key; an action new since the file was written whose default is
			# already another's stays unbound until the player picks a key
			if stored <= 0 or _clashes(taken, stored, action) or RESERVED.has(stored):
				stored = default_key(action)
				if _clashes(taken, stored, action):
					stored = 0
			if stored > 0:
				taken[stored] = String(taken.get(stored, "")) + action + " "
			bindings[action] = stored
	elif error != ERR_FILE_NOT_FOUND:
		load_error = "could not read %s (error %d)" % [SETTINGS_PATH, error]
		push_warning("[GameSettings] " + load_error)
	fullscreen = window_mode != "windowed"
	_index_keys()

func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value(GENERAL, "ui_scale", ui_scale)
	config.set_value(GENERAL, "ui_scale_auto", ui_scale_auto)
	config.set_value(GENERAL, "mouse_sensitivity", mouse_sensitivity)
	config.set_value(GENERAL, "invert_mouse_y", invert_mouse_y)
	config.set_value(GENERAL, "shake", shake)
	config.set_value(GENERAL, "flash", flash)
	config.set_value(GENERAL, "fullscreen", fullscreen)
	config.set_value(GENERAL, "window_mode", window_mode)
	config.set_value(GENERAL, "window_size", window_size)
	config.set_value(GENERAL, "window_maximized", window_maximized)
	config.set_value(GENERAL, "vsync", vsync)
	config.set_value(GENERAL, "fps_cap", fps_cap)
	config.set_value(GENERAL, "render_scale", render_scale)
	config.set_value(GENERAL, "show_fps", show_fps)
	config.set_value(GENERAL, "intro_done", intro_done)
	config.set_value(GENERAL, "tracker_collapsed", tracker_collapsed)
	config.set_value(GENERAL, "keys_version", KEYS_VERSION)
	config.set_value(GENERAL, "graphics_quality", graphics_quality)
	config.set_value(GENERAL, "time_of_day", time_of_day)
	for action: String in bindings:
		config.set_value(BINDINGS, action, int(bindings[action]))
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		load_error = "could not write %s (error %d)" % [SETTINGS_PATH, error]
		push_warning("[GameSettings] " + load_error)

## Whether `keycode` is held by an action `action` may not share it with.
static func _clashes(taken: Dictionary, keycode: int, action: String) -> bool:
	for other: String in String(taken.get(keycode, "")).split(" ", false):
		if not shares(action, other):
			return true
	return false

func _index_keys() -> void:
	_by_key.clear()
	for action: String in bindings:
		var keycode := int(bindings[action])
		if keycode <= 0:
			continue
		# a shared key's presses go to the pair's second action
		var held := String(_by_key.get(keycode, ""))
		if held == "" or _second_of_pair(action, held):
			_by_key[keycode] = action

static func _second_of_pair(action: String, other: String) -> bool:
	for pair: Array in SHARED:
		if pair.size() == 2 and pair[1] == action and pair[0] == other:
			return true
	return false

## ------------------------------------------------------------------ apply

func apply_all() -> void:
	_watch_window()
	apply_window_mode()
	apply_frame_pacing()
	apply_ui_scale()
	changed.emit("all")

## The scale in use: the player's, or what this window and screen call for.
func effective_ui_scale() -> float:
	if not ui_scale_auto:
		return ui_scale
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null or DisplayServer.get_name() == "headless":
		return UI_SCALE_DEFAULT
	return auto_ui_scale(tree.root.size, screen_scale())

## The automatic interface scale for a window of `window` pixels on a screen
## the system scales by `system` (1 = 100 %, 2 = Retina): the system's own
## scale, more when the window is much larger than the layout's canvas, and
## never so much that the canvas gets smaller than the layout needs.
static func auto_ui_scale(window: Vector2i, system: float) -> float:
	var fill := minf(window.x / UI_DESIGN_CANVAS.x, window.y / UI_DESIGN_CANVAS.y)
	var wanted := maxf(maxf(system, 1.0), fill * UI_FILL_SHARE)
	var most := minf(window.x / UI_MIN_CANVAS.x, window.y / UI_MIN_CANVAS.y)
	return clampf(floorf(minf(wanted, most) * 20.0 + 0.001) / 20.0, UI_SCALE_MIN, UI_SCALE_MAX)

## What the system scales the window's screen by. macOS, Windows and Wayland
## report it; elsewhere the DPI says, when it is clearly a high-density screen.
static func screen_scale() -> float:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--assume-screen-scale="):   # checks
			return float(arg.get_slice("=", 1))
	var screen := DisplayServer.window_get_current_screen()
	var reported := DisplayServer.screen_get_scale(screen)
	if reported > 1.0:
		return reported
	var dpi := DisplayServer.screen_get_dpi(screen)
	return snappedf(dpi / 96.0, 0.25) if dpi >= 144 and OS.get_name() != "macOS" else 1.0

func apply_ui_scale() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var wanted := effective_ui_scale() * UI_SCALE_BASE
		if not is_equal_approx(tree.root.content_scale_factor, wanted):
			tree.root.content_scale_factor = wanted

## Until the player chooses, a Mac starts fullscreen (its windowed mode opens
## a small window off to one side, where Mac players expect the whole
## screen); elsewhere the game starts in a window.
static func fullscreen_default() -> bool:
	return OS.get_name() == "macOS"

## A dev run that fixes its own window (`--keep-window`, a check): nothing here
## moves it, and its size is not remembered.
static func _window_is_given() -> bool:
	return Array(OS.get_cmdline_user_args()).any(func(a):
		return String(a) == "--keep-window" or String(a).begins_with("--check"))

## Once per run, before the first frame that matters: the smallest window, the
## size kept from last time or one fitted to this screen.
func fit_first_window() -> void:
	if _window_fitted or DisplayServer.get_name() == "headless":
		return
	_window_fitted = true
	DisplayServer.window_set_min_size(WINDOW_MIN)
	if window_mode != "windowed" or _window_is_given():
		return
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var plan := first_window_plan(usable.size, window_size, window_maximized)
	if bool(plan["maximized"]):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		return
	var size_now: Vector2i = plan["size"]
	DisplayServer.window_set_size(size_now)
	DisplayServer.window_set_position(usable.position + (usable.size - size_now) / 2)

## The first window on a screen with `usable` free pixels: {size, maximized}.
## A screen the default window does not comfortably fit gets a maximized
## window; a very large one a window in proportion to it (1600x900 is a stamp
## on 4K); a size the player left is kept when it still fits.
static func first_window_plan(usable: Vector2i, kept: Vector2i, was_maximized: bool) -> Dictionary:
	var room := usable - WINDOW_CHROME
	if was_maximized or room.x < WINDOW_DEFAULT.x or room.y < WINDOW_DEFAULT.y:
		return {"size": WINDOW_DEFAULT, "maximized": true}
	if kept.x >= WINDOW_MIN.x and kept.y >= WINDOW_MIN.y and kept.x <= room.x and kept.y <= room.y:
		return {"size": kept, "maximized": false}
	if usable.y < 1300:
		return {"size": WINDOW_DEFAULT, "maximized": false}
	var height := int(usable.y * 0.8)
	return {"size": Vector2i(height * WINDOW_DEFAULT.x / WINDOW_DEFAULT.y, height), "maximized": false}

func apply_window_mode() -> void:
	fit_first_window()
	if DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_WINDOWED
	match window_mode:
		"fullscreen":
			want = DisplayServer.WINDOW_MODE_FULLSCREEN
		"exclusive":
			want = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	var now := DisplayServer.window_get_mode()
	# a maximized window is a window: leaving it alone keeps it maximized
	if now == want or (want == DisplayServer.WINDOW_MODE_WINDOWED and now == DisplayServer.WINDOW_MODE_MAXIMIZED):
		return
	DisplayServer.window_set_mode(want)
	if want == DisplayServer.WINDOW_MODE_WINDOWED and window_maximized:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)

## VSync and the frame cap.
func apply_frame_pacing() -> void:
	Engine.max_fps = fps_cap
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

## The render scale the player chose (0: the preset decides).
func chosen_render_scale() -> float:
	return 0.0 if render_scale == "auto" else float(render_scale) / 100.0

## The window changed size: the automatic scale follows, and the windowed size
## is remembered once the resizing has settled.
func _watch_window() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null or tree.root.size_changed.is_connected(_on_window_resized):
		return
	tree.root.size_changed.connect(_on_window_resized)

func _on_window_resized() -> void:
	apply_ui_scale()
	if _window_is_given() or DisplayServer.get_name() == "headless" or window_mode != "windowed":
		return
	var tree := Engine.get_main_loop() as SceneTree
	_resize_serial += 1
	var serial := _resize_serial
	await tree.create_timer(1.0).timeout
	if serial != _resize_serial:
		return
	var mode := DisplayServer.window_get_mode()
	var maximized := mode == DisplayServer.WINDOW_MODE_MAXIMIZED
	if mode != DisplayServer.WINDOW_MODE_WINDOWED and not maximized:
		return
	var size_now := DisplayServer.window_get_size()
	if maximized == window_maximized and (maximized or size_now == window_size):
		return
	window_maximized = maximized
	if not maximized:
		window_size = size_now
	save_to_disk()

## ---------------------------------------------------------------- setters

## A scale the player picked: automatic ends here.
func set_ui_scale(value: float) -> void:
	ui_scale = clampf(snappedf(value, 0.05), UI_SCALE_MIN, UI_SCALE_MAX)
	ui_scale_auto = false
	apply_ui_scale()
	save_to_disk()
	changed.emit("ui_scale")

func set_ui_scale_auto(on: bool) -> void:
	# the slider starts from what the player is looking at
	if not on and ui_scale_auto:
		ui_scale = clampf(effective_ui_scale(), UI_SCALE_MIN, UI_SCALE_MAX)
	ui_scale_auto = on
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

func set_invert_mouse_y(on: bool) -> void:
	invert_mouse_y = on
	save_to_disk()
	changed.emit("invert_mouse_y")

func set_fullscreen(on: bool) -> void:
	set_window_mode("fullscreen" if on else "windowed")

func set_window_mode(mode: String) -> void:
	window_mode = mode if WINDOW_MODES.has(mode) else "windowed"
	fullscreen = window_mode != "windowed"
	apply_window_mode()
	apply_ui_scale()
	save_to_disk()
	changed.emit("fullscreen")

func set_vsync(on: bool) -> void:
	vsync = on
	apply_frame_pacing()
	save_to_disk()
	changed.emit("vsync")

func set_fps_cap(cap: int) -> void:
	fps_cap = cap if FPS_CHOICES.has(cap) else 0
	apply_frame_pacing()
	save_to_disk()
	changed.emit("fps_cap")

## "auto" or a percentage; applies to the live view at once.
func set_render_scale(choice: String) -> void:
	render_scale = choice if RENDER_SCALE_CHOICES.has(choice) else "auto"
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		QualityPreset.apply_render_scale(tree.root)
	save_to_disk()
	changed.emit("render_scale")

func set_show_fps(on: bool) -> void:
	show_fps = on
	save_to_disk()
	changed.emit("show_fps")

## The controls introduction is over (or, false, wanted again).
func set_intro_done(done: bool) -> void:
	intro_done = done
	save_to_disk()
	changed.emit("intro")

func set_tracker_collapsed(on: bool) -> void:
	if tracker_collapsed == on:
		return
	tracker_collapsed = on
	save_to_disk()
	changed.emit("tracker")

## "auto" or a preset name; main.gd applies the result to the live world.
func set_graphics_quality(choice: String) -> void:
	graphics_quality = choice if GRAPHICS_CHOICES.has(choice) else GRAPHICS_DEFAULT
	QualityPreset.choice_changed()
	save_to_disk()
	changed.emit("graphics_quality")

## "system" (the server clock, GMT+3) or a held time; DayNight eases to it.
func set_time_of_day(choice: String) -> void:
	time_of_day = choice if TIME_OF_DAY_CHOICES.has(choice) else TIME_OF_DAY_DEFAULT
	save_to_disk()
	changed.emit("time_of_day")

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
	for other: String in bindings:
		if other != action and int(bindings[other]) == keycode and not shares(action, other):
			return "taken:" + other
	bindings[action] = keycode
	_index_keys()
	save_to_disk()
	changed.emit("bindings")
	return ""

func reset_bindings() -> void:
	for action: String in BINDABLE:
		bindings[action] = default_key(action)
	_index_keys()
	save_to_disk()
	changed.emit("bindings")
