extends HudWindow
class_name SettingsWindow

## Settings, opened from the Esc menu (GameSettings keeps and applies them):
## four tabs in one window - General (language, fullscreen, interface scale,
## mouse sensitivity, screen shake and flash), Audio (master and the four
## buses), Controls (key rebinding) and Credits (GameCredits). The key list
## and the credits scroll inside their tabs. Every change applies at once and
## is saved.
##
## Key capture is explicit: a row listens only after its button is pressed,
## and the very next key (Escape cancels) is consumed and never reaches the
## game.

## The player picked another language and wants the HUD rebuilt in it now
## (the menu's change-character countdown).
signal language_apply_requested

const WINDOW_SIZE := Vector2(660, 640)
const TABS := ["general", "audio", "controls", "credits"]

## Player-facing names of the bindable actions.
const ACTION_NAMES := {
	"move_forward": "Move forward", "move_backward": "Move backward",
	"move_left": "Move left", "move_right": "Move right",
	"jump": "Jump / rise", "descend": "Descend (broom)", "ride": "Mount / dismount broom",
	"target_cycle": "Next target", "pickup_loot": "Pick up loot", "interact": "Talk / interact",
	"chat": "Chat", "inventory": "Bag", "character": "Character", "quest_log": "Quests",
	"workshop": "Kestrin's forge", "dungeon_guide": "Dungeon Guide", "skills": "Skills",
	"spell_1": "Spell slot 1", "spell_2": "Spell slot 2", "spell_3": "Spell slot 3",
	"spell_4": "Spell slot 4", "spell_5": "Spell slot 5", "spell_6": "Spell slot 6",
	"spell_7": "Spell slot 7", "spell_8": "Spell slot 8",
	"quick_1": "Quick slot 1", "quick_2": "Quick slot 2", "quick_3": "Quick slot 3", "quick_4": "Quick slot 4",
}
const BUS_NAMES := {"Master": "Master volume", "Music": "Music", "SFX": "Effects", "UI": "Interface",
	"Ambience": "Ambience"}

var pages: Dictionary = {}
var tab_buttons: Dictionary = {}
var sliders: Dictionary = {}
var bind_buttons: Dictionary = {}
var fullscreen_button: Button
var language_picker: OptionButton
var status: Label
var credits: RichTextLabel
var listening := ""
## Evidence for the menu check.
var rebinds := 0
var _values: Dictionary = {}
var _scale_dragging := false

func _init() -> void:
	super._init("Settings", WINDOW_SIZE)
	name = "SettingsWindow"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 10)
	closed.connect(func(): listening = "")
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	body.add_child(tabs)
	var holder := MarginContainer.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(holder)
	var titles := {"general": tr("General"), "audio": tr("Audio"), "controls": tr("Controls"), "credits": tr("Credits")}
	for key: String in TABS:
		var b := HudKit.button(String(titles[key]), 15)
		b.name = key.capitalize() + "Tab"
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(120, 34)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(show_page.bind(key))
		tabs.add_child(b)
		tab_buttons[key] = b
		var page := VBoxContainer.new()
		page.name = key.capitalize() + "Page"
		page.add_theme_constant_override("separation", 12)
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		holder.add_child(page)
		pages[key] = page
	_build_general(pages["general"])
	_build_audio(pages["audio"])
	_build_controls(pages["controls"])
	credits = GameCredits.build()
	(pages["credits"] as VBoxContainer).add_child(credits)
	var footer := HBoxContainer.new()
	body.add_child(footer)
	status = HudKit.label("", 14, HudKit.GOLD_LT, HudKit.body(), 0)
	status.name = "Status"
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(status)
	var close_button := HudKit.button(tr("Close"), 15)
	close_button.custom_minimum_size = Vector2(120, 34)
	close_button.tooltip_text = tr("Close the settings (Esc)")
	close_button.pressed.connect(close)
	footer.add_child(close_button)
	show_page("general")

func open() -> void:
	super.open()
	refresh()

func show_page(key: String) -> void:
	for k: String in pages:
		(pages[k] as Control).visible = k == key
		(tab_buttons[k] as Button).set_pressed_no_signal(k == key)
	if key != "controls":
		listening = ""

func page_shown() -> String:
	for k: String in pages:
		if (pages[k] as Control).visible:
			return k
	return ""

## ------------------------------------------------------------------ pages

func _build_general(g: VBoxContainer) -> void:
	g.add_child(_section(tr("Language")))
	g.add_child(_language_row())
	g.add_child(_section(tr("Display")))
	var row := _row(tr("Fullscreen  (F11)"))
	fullscreen_button = HudKit.button("", 14)
	fullscreen_button.name = "Fullscreen"
	fullscreen_button.toggle_mode = true
	fullscreen_button.custom_minimum_size = Vector2(120, 32)
	fullscreen_button.toggled.connect(func(on: bool):
		GameSettings.instance().set_fullscreen(on)
		refresh())
	row.add_child(fullscreen_button)
	g.add_child(row)
	g.add_child(_slider_row("ui_scale", tr("Interface scale"), GameSettings.UI_SCALE_MIN, GameSettings.UI_SCALE_MAX, 0.05))
	g.add_child(_section(tr("Camera & effects")))
	g.add_child(_slider_row("mouse_sensitivity", tr("Mouse sensitivity"), GameSettings.SENSITIVITY_MIN,
		GameSettings.SENSITIVITY_MAX, 0.05))
	g.add_child(_slider_row("shake", tr("Screen shake"), GameSettings.INTENSITY_MIN, GameSettings.INTENSITY_MAX, 0.05))
	g.add_child(_slider_row("flash", tr("Screen flash"), GameSettings.INTENSITY_MIN, GameSettings.INTENSITY_MAX, 0.05))

func _build_audio(a: VBoxContainer) -> void:
	a.add_child(_section(tr("Volume")))
	for bus: String in GameSettings.VOLUMES:
		a.add_child(_slider_row("vol_" + bus, tr(String(BUS_NAMES[bus])), 0.0, 1.0, 0.05))

func _build_controls(c: VBoxContainer) -> void:
	var head := HBoxContainer.new()
	var caption := _section(tr("Key bindings"))
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	var reset := HudKit.button(tr("Reset keys"), 14)
	reset.name = "ResetKeys"
	reset.custom_minimum_size = Vector2(130, 30)
	reset.pressed.connect(func():
		GameSettings.instance().reset_bindings()
		listening = ""
		status.text = tr("Key bindings reset to defaults.")
		refresh())
	head.add_child(reset)
	c.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.name = "Keys"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	c.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	scroll.add_child(rows)
	var index := 0
	for action: String in GameSettings.BINDABLE:
		var stripe := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.035 if index % 2 == 0 else 0.0)
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 10
		sb.content_margin_right = 6
		stripe.add_theme_stylebox_override("panel", sb)
		stripe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var r := HBoxContainer.new()
		r.custom_minimum_size.y = 34
		stripe.add_child(r)
		var name_label := HudKit.label(action_name(action), 15, HudKit.TEXT, HudKit.body(), 0)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		r.add_child(name_label)
		var button := HudKit.button("", 14)
		button.name = "Bind_" + action
		# a key's own name, never a catalogue word ("Enter" is not "Gir")
		button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		button.custom_minimum_size = Vector2(150, 30)
		button.pressed.connect(begin_rebind.bind(action))
		r.add_child(button)
		rows.add_child(stripe)
		bind_buttons[action] = button
		index += 1

## The language picker. Labels built from now on use the new language at once;
## what is already on screen switches when the HUD is built again, so the row
## offers the character screen (through the menu's countdown).
func _language_row() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var row := _row(tr("Game language"))
	language_picker = OptionButton.new()
	language_picker.name = "LanguagePicker"
	language_picker.focus_mode = Control.FOCUS_NONE
	# each language is listed under its own name, never translated
	language_picker.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	language_picker.custom_minimum_size = Vector2(280, 32)
	language_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HudKit.style_button(language_picker, 14)
	var languages: Array = I18n.languages()
	for i in languages.size():
		language_picker.add_item(String(languages[i].name), i)
		language_picker.set_item_metadata(i, String(languages[i].code))
		if String(languages[i].code) == I18n.current:
			language_picker.select(i)
	row.add_child(language_picker)
	box.add_child(row)
	var apply_row := HBoxContainer.new()
	apply_row.add_theme_constant_override("separation", 10)
	apply_row.visible = false
	var note := HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_row.add_child(note)
	var apply := HudKit.button("", 13)
	apply.custom_minimum_size = Vector2(200, 30)
	apply.pressed.connect(func():
		close()
		language_apply_requested.emit())
	apply_row.add_child(apply)
	box.add_child(apply_row)
	language_picker.item_selected.connect(func(index: int):
		var code := String(language_picker.get_item_metadata(index))
		if code == I18n.current:
			return
		I18n.set_language(code)
		apply_row.visible = true
		note.text = tr("Open windows switch language when the interface is rebuilt.")
		apply.text = tr("Change character now")
		status.text = tr("Language: %s") % I18n.native_name(code))
	return box

func _section(text: String) -> Label:
	return HudKit.label(I18n.upper(text), 14, HudKit.GOLD, HudKit.title(), 0)

func _row(title: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	r.custom_minimum_size.y = 32
	var l := HudKit.label(title, 15, HudKit.TEXT, HudKit.body(), 0)
	l.custom_minimum_size.x = 190
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(l)
	return r

func _slider_row(key: String, title: String, minimum: float, maximum: float, step: float) -> HBoxContainer:
	var r := _row(title)
	var slider := HSlider.new()
	slider.name = "Slider_" + key
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.02, 0.025, 0.04)
	track.border_color = Color(0, 0, 0)
	track.set_border_width_all(1)
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := StyleBoxFlat.new()
	fill.bg_color = HudKit.GOLD
	fill.set_corner_radius_all(3)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	if key == "ui_scale":
		# rescaling the interface while the knob is held moves the slider
		# under the cursor and the drag fights itself: while dragging only the
		# number updates, the scale applies on release
		slider.drag_started.connect(func(): _scale_dragging = true)
		slider.drag_ended.connect(func(_changed: bool):
			_scale_dragging = false
			set_value(key, slider.value))
	slider.value_changed.connect(func(value: float): set_value(key, value))
	r.add_child(slider)
	var value_label := HudKit.label("", 14, HudKit.GOLD_HI, HudKit.bold(), 0)
	value_label.custom_minimum_size.x = 58
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(value_label)
	sliders[key] = slider
	_values[key] = value_label
	return r

## ---------------------------------------------------------------- changes

## A slider moved (or the check set it): apply and save.
func set_value(key: String, value: float) -> void:
	var settings := GameSettings.instance()
	if key == "ui_scale" and _scale_dragging:
		(_values[key] as Label).text = _format(key, value)
		return
	match key:
		"ui_scale":
			settings.set_ui_scale(value)
		"mouse_sensitivity":
			settings.set_mouse_sensitivity(value)
		"shake":
			settings.set_shake(value)
		"flash":
			settings.set_flash(value)
		_:
			if key.begins_with("vol_"):
				settings.set_volume(key.trim_prefix("vol_"), value)
	refresh()

func value_of(key: String) -> float:
	var settings := GameSettings.instance()
	match key:
		"ui_scale":
			return settings.ui_scale
		"mouse_sensitivity":
			return settings.mouse_sensitivity
		"shake":
			return settings.shake
		"flash":
			return settings.flash
	return settings.volume(key.trim_prefix("vol_")) if key.begins_with("vol_") else 0.0

func _format(key: String, value: float) -> String:
	if key.begins_with("vol_") or key == "shake" or key == "flash":
		return "%d%%" % roundi(value * 100.0)
	if key == "mouse_sensitivity":
		return "%.2fx" % value
	return "%d%%" % roundi(value * 100.0)

func refresh() -> void:
	if fullscreen_button == null:
		return
	var settings := GameSettings.instance()
	fullscreen_button.set_pressed_no_signal(settings.fullscreen)
	fullscreen_button.text = tr("On") if settings.fullscreen else tr("Off")
	for key: String in sliders:
		var v := value_of(key)
		(sliders[key] as HSlider).set_value_no_signal(v)
		(_values[key] as Label).text = _format(key, v)
	for action: String in bind_buttons:
		var b: Button = bind_buttons[action]
		b.text = tr("press a key…") if action == listening else GameSettings.key_name(action)

func action_name(action: String) -> String:
	return tr(String(ACTION_NAMES.get(action, action.capitalize())))

func begin_rebind(action: String) -> void:
	listening = action
	status.text = tr("Press a key for '%s' (Esc cancels)") % action_name(action)
	refresh()

## The next key while a row listens: consumed, never reaching the game.
func _input(event: InputEvent) -> void:
	if listening == "" or not visible:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()
	take_key((event as InputEventKey).physical_keycode)

## Bind the listening row to `keycode` (Escape cancels).
func take_key(keycode: int) -> void:
	var action := listening
	listening = ""
	if keycode == KEY_ESCAPE:
		status.text = tr("Rebinding cancelled.")
		refresh()
		return
	var error := GameSettings.instance().set_binding(action, keycode)
	if error == "":
		rebinds += 1
		status.text = tr("'%s' is now %s.") % [action_name(action), OS.get_keycode_string(keycode)]
	elif error.begins_with("taken:"):
		status.text = tr("Refused: that key already drives '%s'.") % action_name(error.trim_prefix("taken:"))
	else:
		status.text = tr("Refused: that key is kept for the menu and fullscreen.")
	refresh()
