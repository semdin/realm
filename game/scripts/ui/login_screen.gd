extends Control
class_name LoginScreen

## The login card, the game's front door (the old client's main menu): the
## key art behind a left-hand column with the crest and the card (Log In /
## New Account tabs, username, password with Show, the password again for a
## new account, Remember my username, the maintenance notice, the big button
## and a status line), the server pill and the language picker top right,
## the version and Quit Game along the bottom. Built in code from UITheme
## and HudKit, so the first screen and the world read as one client.
##
## It talks to the login service through FrontDoor's LoginApi; a good login
## emits `signed_in` (FrontDoor shows the character screen). A new account
## needs the two consent boxes, is shown its one-time recovery code and logs
## straight in; an older account that has not accepted the current terms is
## asked first. "Forgot your password?" takes a recovery code. The service's
## status decides the notice on the card (maintenance, the realm unreachable,
## this game too old). Only the username is remembered (PREFS_PATH), never the
## password; the token stays in memory (LoginApi).

signal signed_in
signal settings_requested

const PREFS_PATH := "user://login_prefs.json"
const CARD_WIDTH := 430.0
const STATUS_POLL_SECONDS := 15.0
const LOGO_HEIGHT := 180.0
const LOGO_MIN_HEIGHT := 72.0
## Kept free above and below the column (the footer's line).
const COLUMN_MARGIN := 40.0
const COLOR_ERROR := Color(0.96, 0.47, 0.42)
const COLOR_WARN := Color(1.0, 0.74, 0.36)
## The service takes ASCII account names only; said so here, since to a
## Turkish player "letters" reads as if Ş or ı were allowed.
const USERNAME_RULE_TEXT := "Usernames cannot contain Turkish letters (ç, ğ, ı, İ, ö, ş, ü) or spaces: only English letters, digits, '_' and '-'."  # i18n

var api: LoginApi
## False keeps the remembered username as it was (the login check's
## throwaway accounts).
var keep_prefs := true
var register_mode := false
var busy := false
## ONLINE | MAINTENANCE | REALM_DOWN | OFFLINE | OUTDATED | UNKNOWN
var server_state := "UNKNOWN"

var username_input: LineEdit
var password_input: LineEdit
var confirm_input: LineEdit
var confirm_block: Control
var reveal_btn: Button
var remember_check: CheckBox
var consent: AccountDialogs.ConsentBoxes
var forgot_btn: Button
var reader: AccountDialogs.Reader
var consent_dialog: AccountDialogs.Consent
var code_dialog: AccountDialogs.RecoveryCode
var recover_dialog: AccountDialogs.Recover
var submit_btn: Button
var login_tab: Button
var register_tab: Button
var status_label: Label
var notice_panel: PanelContainer
var notice_title: Label
var notice_body: Label
var server_pill: PanelContainer
var server_dot: Panel
var server_label: Label
var language_picker: OptionButton
var login_column: VBoxContainer
var crest_box: Control
var crest_logo: TextureRect

var _status_timer: Timer
var _status_in_flight := false
var _username_re := RegEx.create_from_string("^[A-Za-z0-9_-]+$")

func setup(p_api: LoginApi) -> void:
	api = p_api

func _ready() -> void:
	name = "LoginScreen"
	theme = UITheme.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_window().title = UITheme.GAME_TITLE
	_build()
	_load_prefs()
	_set_mode(false)
	_start_status_poll()
	if username_input.text.is_empty():
		username_input.call_deferred("grab_focus")
	else:
		password_input.call_deferred("grab_focus")

## ================================================================ layout

func _build() -> void:
	add_child(FrontDoor.backdrop(1.0))
	# Left-to-right shade: deep behind the form, clear over the hero.
	add_child(FrontDoor.gradient_rect("ShadeLeft", [
		[0.0, Color(0.02, 0.025, 0.04, 0.94)],
		[0.34, Color(0.02, 0.025, 0.04, 0.80)],
		[0.62, Color(0.02, 0.025, 0.04, 0.0)],
	], false))
	# Bottom fade, so the footer always has contrast.
	add_child(FrontDoor.gradient_rect("ShadeBottom", [
		[0.0, Color(0, 0, 0, 0)],
		[0.78, Color(0, 0, 0, 0)],
		[1.0, Color(0, 0, 0, 0.75)],
	], true))
	add_child(FrontDoor.embers(self))
	# The login column sits over the darkened left of the key art; the
	# wizard and the castle stay visible on the right.
	var column := VBoxContainer.new()
	login_column = column
	column.name = "LoginColumn"
	column.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	column.offset_left = 72.0
	column.offset_right = 72.0 + CARD_WIDTH
	column.offset_top = COLUMN_MARGIN
	column.offset_bottom = -COLUMN_MARGIN
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 18)
	add_child(column)
	crest_box = _build_crest()
	column.add_child(crest_box)
	column.add_child(_build_card())
	column.minimum_size_changed.connect(_fit_column.call_deferred)
	resized.connect(_fit_column)
	_build_server_pill()
	_build_language_picker()
	_build_footer()
	_build_dialogs()

func _build_dialogs() -> void:
	reader = AccountDialogs.Reader.new(api)
	consent_dialog = AccountDialogs.Consent.new(api, reader)
	code_dialog = AccountDialogs.RecoveryCode.new()
	recover_dialog = AccountDialogs.Recover.new(api)
	# the consent card comes first: the reader opens over it
	add_child(consent_dialog)
	add_child(recover_dialog)
	add_child(code_dialog)
	add_child(reader)
	consent_dialog.accepted.connect(_finish_login)
	consent_dialog.declined.connect(func():
		await api.logout()
		set_status(tr("You have logged out."), "info"))
	recover_dialog.recovered.connect(_on_recovered)

func _build_crest() -> Control:
	var box := VBoxContainer.new()
	box.name = "Crest"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# no wider than the login card below it
	crest_logo = UITheme.logo(LOGO_HEIGHT)
	box.add_child(crest_logo)
	var subtitle := Label.new()
	subtitle.name = "SubtitleLabel"
	subtitle.text = tr("REALM OF KAF")
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_override("font", UITheme.font_title())
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	subtitle.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	subtitle.add_theme_constant_override("outline_size", UITheme.outline_for(15, 4))
	box.add_child(subtitle)
	box.add_child(FrontDoor.ornament())
	return box

## The card always fits: on a short window the logo gives way first (smaller,
## then gone), so no field or button falls off the screen.
func _fit_column() -> void:
	if crest_logo == null or size.y <= 0.0:
		return
	var room := size.y - COLUMN_MARGIN * 2.0
	# The same answer with the crest shown or hidden: hiding it also removes
	# the column's gap, and an answer that changed with it flipped the crest
	# without end (a three-line message on the card crashed the game).
	var gap := float(login_column.get_theme_constant("separation"))
	var rest := login_column.get_combined_minimum_size().y
	if crest_box.visible:
		rest -= crest_box.get_combined_minimum_size().y + gap
	var crest_extra := crest_box.get_combined_minimum_size().y - crest_logo.custom_minimum_size.y
	var logo_room := room - rest - crest_extra - gap
	crest_box.visible = logo_room >= LOGO_MIN_HEIGHT
	var height := clampf(logo_room, LOGO_MIN_HEIGHT, LOGO_HEIGHT)
	if not is_equal_approx(crest_logo.custom_minimum_size.y, height):
		var aspect := crest_logo.custom_minimum_size.x / crest_logo.custom_minimum_size.y
		crest_logo.custom_minimum_size = Vector2(height * aspect, height)

func _build_card() -> Control:
	var card := PanelContainer.new()
	card.name = "LoginCard"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.043, 0.06, 0.094, 0.9)
	sb.border_color = UITheme.alpha("gold", 0.75)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 22
	sb.shadow_offset = Vector2(0, 8)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 22
	sb.content_margin_bottom = 26
	card.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	card.add_child(v)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	login_tab = _tab_button(tr("LOG IN"))
	login_tab.name = "LoginTab"
	register_tab = _tab_button(tr("NEW ACCOUNT"))
	register_tab.name = "RegisterTab"
	login_tab.pressed.connect(func(): _set_mode(false))
	register_tab.pressed.connect(func(): _set_mode(true))
	tabs.add_child(login_tab)
	tabs.add_child(register_tab)
	v.add_child(tabs)

	username_input = FrontDoor.line_edit(tr("Your username"))
	username_input.name = "UsernameInput"
	username_input.max_length = 24
	v.add_child(_field(tr("USERNAME"), username_input))

	password_input = FrontDoor.line_edit(tr("Your password"))
	password_input.name = "PasswordInput"
	password_input.secret = true
	password_input.max_length = 128
	reveal_btn = Button.new()
	reveal_btn.name = "RevealButton"
	reveal_btn.text = tr("Show")
	reveal_btn.flat = true
	reveal_btn.focus_mode = Control.FOCUS_NONE
	reveal_btn.add_theme_font_size_override("font_size", 13)
	reveal_btn.add_theme_color_override("font_color", UITheme.c("text_dim"))
	reveal_btn.add_theme_color_override("font_hover_color", UITheme.c("gold_hi"))
	reveal_btn.pressed.connect(_toggle_reveal)
	var pass_row := HBoxContainer.new()
	pass_row.add_theme_constant_override("separation", 6)
	password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pass_row.add_child(password_input)
	pass_row.add_child(reveal_btn)
	v.add_child(_field(tr("PASSWORD"), pass_row))

	confirm_input = FrontDoor.line_edit(tr("Type your password again"))
	confirm_input.name = "ConfirmInput"
	confirm_input.secret = true
	confirm_input.max_length = 128
	confirm_block = _field(tr("PASSWORD (AGAIN)"), confirm_input)
	v.add_child(confirm_block)

	remember_check = CheckBox.new()
	remember_check.name = "RememberCheck"
	remember_check.text = tr("Remember my username")
	remember_check.button_pressed = true
	remember_check.focus_mode = Control.FOCUS_NONE
	remember_check.add_theme_font_size_override("font_size", 14)
	remember_check.add_theme_color_override("font_color", UITheme.c("text_dim"))
	remember_check.add_theme_color_override("font_hover_color", UITheme.c("text"))
	remember_check.add_theme_color_override("font_pressed_color", UITheme.c("text"))
	remember_check.add_theme_color_override("font_hover_pressed_color", UITheme.c("text"))
	# The theme gives every Button-derived control a plate; a checkbox wants none.
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		remember_check.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	v.add_child(remember_check)

	consent = AccountDialogs.ConsentBoxes.new()
	consent.name = "Consent"
	consent.read_requested.connect(func(kind: String): reader.show_document(kind))
	v.add_child(consent)

	notice_panel = _build_notice()
	v.add_child(notice_panel)

	submit_btn = FrontDoor.primary_button(tr("ENTER GAME"))
	submit_btn.name = "SubmitButton"
	submit_btn.pressed.connect(_on_submit)
	v.add_child(submit_btn)

	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(0, 40)
	status_label.add_theme_font_size_override("font_size", 14)
	v.add_child(status_label)

	forgot_btn = AccountDialogs.link(tr("Forgot your password?"), 13)
	forgot_btn.name = "ForgotPassword"
	forgot_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	forgot_btn.pressed.connect(func(): recover_dialog.start(username_input.text.strip_edges()))
	v.add_child(forgot_btn)

	username_input.text_submitted.connect(func(_t: String): password_input.grab_focus())
	password_input.text_submitted.connect(func(_t: String):
		if register_mode:
			confirm_input.grab_focus()
		else:
			_on_submit())
	confirm_input.text_submitted.connect(func(_t: String): _on_submit())
	return card

func _field(caption: String, input: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = caption
	label.add_theme_font_override("font", UITheme.font_title())
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	box.add_child(input)
	return box

func _tab_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 40)
	b.add_theme_font_override("font", UITheme.font_title())
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UITheme.c("text_dim"))
	b.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	b.add_theme_color_override("font_pressed_color", UITheme.c("gold_hi"))
	b.add_theme_color_override("font_hover_pressed_color", UITheme.c("gold_hi"))
	# the control kit's tab: the chosen one underlined in lit gold
	b.add_theme_stylebox_override("normal", UIKit.tab("hover", Vector2(10, 6)))
	b.add_theme_stylebox_override("hover", UIKit.tab("hover", Vector2(10, 6)))
	b.add_theme_stylebox_override("pressed", UIKit.tab("selected", Vector2(10, 6)))
	b.add_theme_stylebox_override("hover_pressed", UIKit.tab("selected", Vector2(10, 6)))
	b.add_theme_stylebox_override("disabled", UIKit.tab("normal", Vector2(10, 6)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b

func _build_notice() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "MaintenanceNotice"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.2, 0.09, 0.02, 0.92)
	sb.border_color = Color(1.0, 0.62, 0.22, 0.95)
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	var lock := UITheme.icon_rect("ui_lock", 30.0)
	lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lock)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 2)
	row.add_child(texts)
	notice_title = Label.new()
	notice_title.add_theme_font_override("font", UITheme.font_title())
	notice_title.add_theme_font_size_override("font_size", 15)
	notice_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5))
	texts.add_child(notice_title)
	notice_body = Label.new()
	notice_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice_body.add_theme_font_size_override("font_size", 13)
	notice_body.add_theme_color_override("font_color", Color(1.0, 0.93, 0.84))
	texts.add_child(notice_body)
	panel.hide()
	return panel

func _build_server_pill() -> void:
	server_pill = PanelContainer.new()
	server_pill.name = "ServerPill"
	server_pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	server_pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	server_pill.offset_left = -260.0
	server_pill.offset_right = -28.0
	server_pill.offset_top = 24.0
	server_pill.add_theme_stylebox_override("panel", FrontDoor.pill_box())
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 9)
	server_pill.add_child(row)
	server_dot = Panel.new()
	server_dot.custom_minimum_size = Vector2(10, 10)
	server_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(server_dot)
	server_label = Label.new()
	server_label.add_theme_font_size_override("font_size", 14)
	server_label.add_theme_color_override("font_color", UITheme.c("text"))
	row.add_child(server_label)
	add_child(server_pill)
	_render_server_state()

## The language, under the server pill. A change rebuilds the screen in the
## new language (nothing typed here is worth more than a remembered username).
func _build_language_picker() -> void:
	var picker := OptionButton.new()
	language_picker = picker
	picker.name = "LanguagePicker"
	picker.focus_mode = Control.FOCUS_NONE
	# Each language is listed under its own name, never translated.
	picker.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	picker.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	picker.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	picker.offset_left = -180.0
	picker.offset_right = -28.0
	picker.offset_top = 70.0
	picker.offset_bottom = 102.0
	picker.tooltip_text = tr("Language")
	picker.add_theme_font_size_override("font_size", 14)
	picker.add_theme_color_override("font_color", UITheme.c("text"))
	picker.add_theme_color_override("font_hover_color", UITheme.c("gold_hi"))
	# the control kit's plates (the theme's OptionButton), tighter
	for state in UIKit.STATES:
		picker.add_theme_stylebox_override(state, UIKit.plate("steel", state, Color(0, 0, 0, 0), Vector2(14, 2)))
	var languages: Array = I18n.languages()
	for i in languages.size():
		picker.add_item(String(languages[i].name), i)
		picker.set_item_metadata(i, String(languages[i].code))
		if String(languages[i].code) == I18n.current:
			picker.select(i)
	picker.item_selected.connect(func(index: int):
		var code := String(picker.get_item_metadata(index))
		if code == I18n.current or busy:
			return
		I18n.set_language(code)
		# the front door is built again in the new language (the scene reload
		# comes back here: nobody is signed in)
		get_tree().reload_current_scene.call_deferred())
	add_child(picker)
	# Settings beside it: the interface scale, window, keys and credits are
	# needed before the first login too
	var settings := Button.new()
	settings.name = "SettingsButton"
	settings.text = tr("Settings")
	settings.focus_mode = Control.FOCUS_NONE
	settings.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	settings.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	settings.offset_left = -310.0
	settings.offset_right = -192.0
	settings.offset_top = 70.0
	settings.offset_bottom = 102.0
	UIKit.style_button(settings, "steel", 14)
	for state in UIKit.STATES:
		settings.add_theme_stylebox_override(state, UIKit.plate("steel", state, Color(0, 0, 0, 0), Vector2(14, 2)))
	settings.pressed.connect(func(): settings_requested.emit())
	add_child(settings)

func _build_footer() -> void:
	var version := Label.new()
	version.name = "VersionLabel"
	version.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	version.offset_left = 24.0
	version.offset_top = -34.0
	version.offset_bottom = -12.0
	version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version.text = "%s  %s" % [UITheme.GAME_TITLE, _client_version()]
	version.add_theme_font_size_override("font_size", 12)
	version.add_theme_color_override("font_color", UITheme.alpha("text_dim", 0.8))
	add_child(version)
	var quit := Button.new()
	quit.name = "QuitButton"
	quit.text = tr("Quit Game")
	quit.flat = true
	quit.focus_mode = Control.FOCUS_NONE
	quit.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	quit.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	quit.grow_vertical = Control.GROW_DIRECTION_BEGIN
	quit.offset_left = -160.0
	quit.offset_right = -24.0
	quit.offset_top = -48.0
	quit.offset_bottom = -14.0
	quit.add_theme_font_size_override("font_size", 14)
	quit.add_theme_color_override("font_color", UITheme.c("text_dim"))
	quit.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	UITheme.set_button_icon(quit, "ui_close", 14.0)
	quit.pressed.connect(func(): get_tree().quit())
	add_child(quit)
	var help := AccountDialogs.link(tr("Help & Support"))
	help.name = "HelpButton"
	help.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	help.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	help.grow_vertical = Control.GROW_DIRECTION_BEGIN
	help.offset_left = -340.0
	help.offset_right = -170.0
	help.offset_top = -48.0
	help.offset_bottom = -14.0
	help.pressed.connect(AccountDialogs.open_support)
	add_child(help)

func _client_version() -> String:
	var v := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
	return ("v" + v) if not v.is_empty() else tr("development build")

## ================================================================ state

func _set_mode(p_register: bool) -> void:
	register_mode = p_register
	login_tab.set_pressed_no_signal(not register_mode)
	register_tab.set_pressed_no_signal(register_mode)
	confirm_block.visible = register_mode
	consent.visible = register_mode
	remember_check.visible = not register_mode
	forgot_btn.visible = not register_mode
	submit_btn.text = tr("CREATE ACCOUNT") if register_mode else tr("ENTER GAME")
	password_input.placeholder_text = tr("8+ characters, letters and digits") if register_mode else tr("Your password")
	confirm_input.text = ""
	set_status("")

func _toggle_reveal() -> void:
	password_input.secret = not password_input.secret
	confirm_input.secret = password_input.secret
	reveal_btn.text = tr("Hide") if not password_input.secret else tr("Show")

func _set_busy(value: bool, message: String = "") -> void:
	busy = value
	submit_btn.disabled = value or server_state == "OUTDATED"
	login_tab.disabled = value
	register_tab.disabled = value
	username_input.editable = not value
	password_input.editable = not value
	confirm_input.editable = not value
	if not message.is_empty():
		set_status(message, "progress")

## kind: info | progress | error | warn | ok
func set_status(message: String, kind: String = "info") -> void:
	if status_label == null:
		return
	status_label.text = message
	var colour: Color = UITheme.c("text_dim")
	match kind:
		"progress": colour = UITheme.c("gold_lt")
		"error": colour = COLOR_ERROR
		"warn": colour = COLOR_WARN
		"ok": colour = UITheme.c("good")
	status_label.add_theme_color_override("font_color", colour)

func show_maintenance_notice(show_it: bool, detail: String = "") -> void:
	notice_panel.visible = show_it
	if show_it:
		server_state = "MAINTENANCE"
		_render_server_state()
		notice_title.text = tr("Server under maintenance")
		notice_body.text = detail if not detail.is_empty() else \
			tr("The game is being updated right now. You can log in again in a few minutes.")

## This game cannot play on the realm as it is now: said once, plainly, and
## the button stays off until the launcher has updated it.
func show_update_notice() -> void:
	server_state = "OUTDATED"
	_render_server_state()
	notice_title.text = tr("Update required")
	notice_body.text = tr("Your game is out of date. Close it and open the launcher to update.")
	notice_panel.visible = true
	submit_btn.disabled = true

func _show_realm_down_notice() -> void:
	notice_title.text = tr("The realm is not reachable")
	notice_body.text = tr("The game servers are not answering right now. Please try again in a few minutes.")
	notice_panel.visible = true

func _show_service_down_notice() -> void:
	notice_title.text = tr("Server unreachable")
	notice_body.text = tr("The login server cannot be reached. It may be down, or your connection may have a problem.")
	notice_panel.visible = true

## Why the world sent the player back here (MaintenanceUI's end screen kind).
func show_return_notice(kind: String, detail: String) -> void:
	match kind:
		"maintenance", "refused_maintenance":
			show_maintenance_notice(true,
				tr("The server went into maintenance and you were logged out. Your progress is saved; you can log in again once maintenance is over."))
			set_status(tr("You can log in once maintenance is complete."), "warn")
		"lost":
			set_status(tr("The connection to the server was lost. Please log in again."), "warn")
		"account_deleted":
			set_status(tr("Your account was deleted."), "ok")
		"refused", "unanswered":
			set_status(detail, "warn")

## ================================================================ server status

func _start_status_poll() -> void:
	_status_timer = Timer.new()
	_status_timer.wait_time = STATUS_POLL_SECONDS
	_status_timer.timeout.connect(_poll_status)
	add_child(_status_timer)
	_status_timer.start()
	_poll_status()

func _poll_status() -> void:
	if _status_in_flight or not is_inside_tree() or api == null:
		return
	_status_in_flight = true
	var res: Dictionary = await api.status()
	_status_in_flight = false
	if not is_inside_tree():
		return
	apply_status(res)

## The service's answer on the card: the pill, and the notice that goes with
## anything but an open realm.
func apply_status(res: Dictionary) -> void:
	if server_state == "OUTDATED":
		return
	var realm := String(res.body.get("realm", "")) if res.ok else ""
	if not res.ok and int(res.code) == 404:
		# an older service: it has no /api/status for us; it answered, so it is up
		realm = "open"
	var theirs := int(String(res.body.get("protocol_version", "0"))) if res.ok else 0
	var ours := LoginApi.protocol_version()
	if theirs > 0 and ours > 0 and theirs != ours:
		show_update_notice()
		return
	var before := server_state
	match realm:
		"open":
			server_state = "ONLINE"
		"maintenance":
			server_state = "MAINTENANCE"
		"unreachable":
			server_state = "REALM_DOWN"
		"full":
			server_state = "FULL"
		"degraded":
			server_state = "DEGRADED"
		"":
			server_state = "OFFLINE"
		_:
			server_state = "ONLINE"
	_render_server_state()
	if server_state == before:
		return
	notice_panel.visible = false
	match server_state:
		"MAINTENANCE":
			show_maintenance_notice(true)
		"REALM_DOWN":
			_show_realm_down_notice()
		"OFFLINE":
			_show_service_down_notice()

func _render_server_state() -> void:
	if server_label == null:
		return
	var colour := UITheme.c("text_dim")
	var text := tr("Checking server status…")
	match server_state:
		"ONLINE":
			colour = UITheme.c("good")
			text = tr("Server online")
		"MAINTENANCE":
			colour = COLOR_WARN
			text = tr("Server under maintenance")
		"REALM_DOWN":
			colour = COLOR_WARN
			text = tr("The realm is not reachable")
		"FULL":
			colour = COLOR_WARN
			text = tr("Realm full: you may have to wait")
		"DEGRADED":
			colour = COLOR_WARN
			text = tr("The realm is having problems")
		"OUTDATED":
			colour = COLOR_ERROR
			text = tr("Update required")
		"OFFLINE":
			colour = COLOR_ERROR
			text = tr("Server unreachable")
	server_label.text = text
	var dot := StyleBoxFlat.new()
	dot.bg_color = colour
	dot.set_corner_radius_all(5)
	dot.shadow_color = Color(colour.r, colour.g, colour.b, 0.6)
	dot.shadow_size = 4
	server_dot.add_theme_stylebox_override("panel", dot)

## ================================================================ auth

func _on_submit() -> void:
	if busy:
		return
	var user := username_input.text.strip_edges()
	var pass_w := password_input.text
	if user.is_empty() or pass_w.is_empty():
		set_status(tr("Please enter your username and password."), "error")
		(username_input if user.is_empty() else password_input).grab_focus()
		return
	if register_mode:
		_do_register(user, pass_w)
	else:
		_do_login(user, pass_w)

func _do_register(user: String, pass_w: String) -> void:
	if user.length() < 3 or user.length() > 24:
		set_status(tr("Username must be 3-24 characters."), "error")
		return
	if not _username_re.search(user):
		set_status(tr(USERNAME_RULE_TEXT), "error")
		username_input.grab_focus()
		return
	if pass_w.length() < 8:
		set_status(tr("Password must be at least 8 characters."), "error")
		return
	if pass_w != confirm_input.text:
		set_status(tr("The passwords do not match."), "error")
		confirm_input.grab_focus()
		return
	if not consent.age.button_pressed:
		set_status(tr("You must confirm that you are 16 or older."), "error")
		return
	if not consent.terms.button_pressed:
		set_status(tr("Accept the Terms of Service and Privacy Policy to continue."), "error")
		return
	_set_busy(true, tr("Creating account…"))
	var res: Dictionary = await api.register(user, pass_w)
	if not is_inside_tree():
		return
	_set_busy(false)
	if not res.ok:
		if res.update_required:
			show_update_notice()
		set_status(res.error, "error")
		return
	_set_mode(false)
	consent.clear()
	set_status(tr("Your account was created! Logging in…"), "ok")
	# The code first, while nothing else is going on: it is never shown again.
	code_dialog.present(String(res.body.get("recovery_code", "")))
	await code_dialog.finished
	if not is_inside_tree():
		return
	# Straight in: nobody wants to type the password they just chose twice more.
	_do_login(user, pass_w)

func _do_login(user: String, pass_w: String) -> void:
	_set_busy(true, tr("Logging in…"))
	var res: Dictionary = await api.login(user, pass_w)
	if not is_inside_tree():
		return
	_set_busy(false)
	if not res.ok:
		if res.update_required:
			show_update_notice()
			set_status("")
		elif res.maintenance:
			show_maintenance_notice(true)
			set_status(res.error, "warn")
		else:
			set_status(res.error, "error")
			password_input.select_all()
			password_input.grab_focus()
		return
	_save_prefs(user)
	set_status("")
	password_input.text = ""
	if LoginApi.terms_required:
		consent_dialog.open()
		return
	_finish_login()

func _finish_login() -> void:
	signed_in.emit()

## A recovery went through: the replacement code is shown, then the card asks
## for the new password.
func _on_recovered(new_code: String, user: String) -> void:
	username_input.text = user
	password_input.text = ""
	_set_mode(false)
	set_status(tr("Your password was changed. Log in with the new one."), "ok")
	code_dialog.present(new_code)

## ================================================================ prefs

## Only the username is remembered - never the password.
func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var file := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return
	var remember := bool(parsed.get("remember", true))
	remember_check.button_pressed = remember
	if remember and str(parsed.get("username", "")) != "":
		username_input.text = str(parsed["username"])

func _save_prefs(user: String) -> void:
	if not keep_prefs:
		return
	var remember := remember_check.button_pressed
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"remember": remember, "username": user if remember else ""}))
