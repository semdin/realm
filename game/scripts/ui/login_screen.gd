extends Control
class_name LoginScreen

## The login card, the game's front door (the old client's main menu): the
## key art (the castle under the aurora, a mage's wand alight; one shader
## pass with its slow push-in, parallax and shades) behind a left-hand
## column with the crest (a sheen and a bloom) and the frosted card (Log In /
## New Account tabs, username, password with Show, the password again for a
## new account, Remember my username / password, the maintenance notice, the
## gold Enter Game button and a status line), the server pill, Settings and
## the language top right, the version, Help and Quit along the bottom.
## Built in code from UITheme (prototype: build/ui_proto/login).
##
## It talks to the login service through FrontDoor's LoginApi; a good login
## emits `signed_in` (FrontDoor shows the character screen). A new account
## needs the two consent boxes, is shown its one-time recovery code and logs
## straight in; an older account that has not accepted the current terms is
## asked first. "Forgot your password?" takes a recovery code. The service's
## status decides the notice on the card (maintenance, the realm unreachable,
## this game too old). The username is remembered (PREFS_PATH) and, with
## "Remember my password", the service's signed saved login (LoginApi
## saved_login, never the password itself); the session token stays in
## memory (LoginApi).

signal signed_in
signal settings_requested

const PREFS_PATH := "user://login_prefs.json"
const CARD_WIDTH := 430.0
const STATUS_POLL_SECONDS := 15.0
const LOGO_HEIGHT := 170.0
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
var remember_pass_check: CheckBox
## The password field stands for a saved login (SAVED_FILL in it): Enter
## logs in with it; typing replaces it with a real password.
var _using_saved := false
var _saved_user := ""
var _saved_token := ""
const SAVED_FILL := "••••••••••"
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

## The key art (front_door_key.jpg, 2560x1440): the castle under the aurora
## and the mage on the right, the left third kept dark for the column.
const KEY_ART := "res://assets/branding/front_door_key.jpg"
const ART := "res://assets/ui/login/"
const BACKDROP_SHADER := preload("res://assets/shaders/login_backdrop.gdshader")
const CARD_SHADER := preload("res://assets/shaders/login_card.gdshader")
const BUTTON_SHADER := preload("res://assets/shaders/login_button.gdshader")
const LOGO_SHADER := preload("res://assets/shaders/login_logo.gdshader")
## Room around the card and the big button for their shadow and glow.
const CARD_PAD := 40.0
const BUTTON_PAD := 24.0
const INK := Color(0.114, 0.078, 0.02)
const FIELD_PLACEHOLDER := Color(0.416, 0.412, 0.384)

var _backdrop: ColorRect
var _backdrop_mat: ShaderMaterial
var _parallax := Vector2.ZERO
var _tabs_box: Control
var _tab_bar: TextureRect
var _opts_row: Control
var _saved_chip: Control
var _enter_mat: ShaderMaterial
var _top_right: Control

func _build() -> void:
	# the world: one pass draws the art, its light and the shades
	_backdrop = ColorRect.new()
	_backdrop.name = "Background"
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop_mat = ShaderMaterial.new()
	_backdrop_mat.shader = BACKDROP_SHADER
	_backdrop_mat.set_shader_parameter("art", load(KEY_ART))
	_backdrop_mat.set_shader_parameter("intro", 0.0)
	_backdrop.material = _backdrop_mat
	add_child(_backdrop)
	add_child(FrontDoor.embers(self))
	var column := VBoxContainer.new()
	login_column = column
	column.name = "LoginColumn"
	column.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	column.offset_left = 100.0
	column.offset_right = 100.0 + CARD_WIDTH
	column.offset_top = COLUMN_MARGIN
	column.offset_bottom = -COLUMN_MARGIN
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 20)
	add_child(column)
	crest_box = _build_crest()
	column.add_child(crest_box)
	var card := _build_card()
	column.add_child(card)
	column.minimum_size_changed.connect(_fit_column.call_deferred)
	resized.connect(_fit_column)
	_build_server_pill()
	_build_language_picker()
	_build_footer()
	_build_dialogs()
	_intro([crest_box, card, _top_right])

## The screen comes up out of the dark: the world, then the crest, the card
## and the corner, one after another.
func _intro(parts: Array) -> void:
	var tween := create_tween().set_parallel(true)
	tween.tween_method(func(v: float): _backdrop_mat.set_shader_parameter("intro", v), 0.0, 1.0, 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for i in parts.size():
		var part: CanvasItem = parts[i]
		part.modulate.a = 0.0
		tween.tween_property(part, "modulate:a", 1.0, 0.9).set_delay(0.15 + 0.14 * i) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

## The pointer moves the world a little (eased, so it drifts).
func _process(delta: float) -> void:
	if _backdrop_mat == null or size.x <= 0.0:
		return
	var aim := get_local_mouse_position() / size - Vector2(0.5, 0.5)
	aim = aim.clamp(Vector2(-0.5, -0.5), Vector2(0.5, 0.5))
	var next := _parallax.lerp(aim, 1.0 - exp(-delta * 3.0))
	if next.distance_squared_to(_parallax) > 1e-7:
		_parallax = next
		_backdrop_mat.set_shader_parameter("parallax", _parallax)

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

static func _icon(file: String) -> Texture2D:
	return load(ART + file) as Texture2D

static func _icon_rect(file: String, px: float, tint: Color) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = _icon(file)
	rect.custom_minimum_size = Vector2(px, px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rect.modulate = tint
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

## A gold hairline fading in from `toward` (-1: from the right).
static func _hairline(width: float, toward: int) -> TextureRect:
	var gradient := Gradient.new()
	gradient.set_color(0, UITheme.alpha("gold_lt", 0.0))
	gradient.set_color(1, UITheme.c("gold_lt"))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 64
	tex.height = 1
	var rect := TextureRect.new()
	rect.texture = tex
	rect.custom_minimum_size = Vector2(width, 1)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.flip_h = toward < 0
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

func _build_crest() -> Control:
	var box := VBoxContainer.new()
	box.name = "Crest"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# no wider than the login card below it; a sheen crosses its metal and a
	# soft bloom breathes behind it
	crest_logo = UITheme.logo(LOGO_HEIGHT)
	var sheen := ShaderMaterial.new()
	sheen.shader = LOGO_SHADER
	crest_logo.material = sheen
	var bloom := TextureRect.new()
	bloom.name = "Bloom"
	bloom.texture = _icon("logo_bloom.png")
	bloom.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bloom.stretch_mode = TextureRect.STRETCH_SCALE
	bloom.show_behind_parent = true
	bloom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bloom.modulate.a = 0.38
	crest_logo.add_child(bloom)
	# the bloom picture has 96 px of room around a 1024x438 emblem
	crest_logo.resized.connect(func():
		var drawn := crest_logo.size.y * 1024.0 / 438.0
		var inset := Vector2((crest_logo.size.x - drawn) * 0.5, 0.0)
		var room := Vector2(drawn * 96.0 / 1024.0, crest_logo.size.y * 96.0 / 438.0)
		bloom.position = inset - room
		bloom.size = Vector2(drawn, crest_logo.size.y) + room * 2.0)
	var breathe := bloom.create_tween().set_loops()
	breathe.tween_property(bloom, "modulate:a", 0.7, 2.5).set_trans(Tween.TRANS_SINE)
	breathe.tween_property(bloom, "modulate:a", 0.38, 2.5).set_trans(Tween.TRANS_SINE)
	box.add_child(crest_logo)
	var realm := HBoxContainer.new()
	realm.alignment = BoxContainer.ALIGNMENT_CENTER
	realm.add_theme_constant_override("separation", 14)
	realm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	realm.add_child(_hairline(64.0, 1))
	var subtitle := Label.new()
	subtitle.name = "SubtitleLabel"
	subtitle.text = tr("REALM OF KAF")
	var spaced := UITheme.font(UITheme.W_BOLD).duplicate() as FontVariation
	if spaced != null:
		spaced.spacing_glyph = 6
		subtitle.add_theme_font_override("font", spaced)
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	subtitle.add_theme_color_override("font_shadow_color", UITheme.alpha("gold_lt", 0.45))
	subtitle.add_theme_constant_override("shadow_outline_size", 8)
	subtitle.add_theme_constant_override("shadow_offset_x", 0)
	subtitle.add_theme_constant_override("shadow_offset_y", 0)
	realm.add_child(subtitle)
	realm.add_child(_hairline(64.0, -1))
	box.add_child(realm)
	return box

## The card always fits: on a short window the logo gives way first (smaller,
## then gone), so no field or button falls off the screen.
func _fit_column() -> void:
	if crest_logo == null or size.y <= 0.0:
		return
	# the column stands in from the left edge as the window allows
	var left := clampf(size.x * 0.052, 28.0, 100.0)
	login_column.offset_left = left
	login_column.offset_right = left + CARD_WIDTH
	_backdrop_mat.set_shader_parameter("view_size", size)
	_backdrop_mat.set_shader_parameter("column_px", left + CARD_WIDTH + 20.0)
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

static func _white() -> Texture2D:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)

func _build_card() -> Control:
	var card := PanelContainer.new()
	card.name = "LoginCard"
	# dark frosted glass in a fine gold frame (login_card.gdshader), drawn
	# CARD_PAD beyond the card for its shadow
	var face := StyleBoxTexture.new()
	face.texture = _white()
	face.expand_margin_left = CARD_PAD
	face.expand_margin_right = CARD_PAD
	face.expand_margin_top = CARD_PAD
	face.expand_margin_bottom = CARD_PAD
	face.content_margin_left = 32
	face.content_margin_right = 32
	face.content_margin_top = 18
	face.content_margin_bottom = 24
	card.add_theme_stylebox_override("panel", face)
	var glass := ShaderMaterial.new()
	glass.shader = CARD_SHADER
	glass.set_shader_parameter("pad", CARD_PAD)
	glass.set_shader_parameter("gold_hi", UITheme.c("gold_hi"))
	glass.set_shader_parameter("gold", UITheme.c("gold"))
	glass.set_shader_parameter("gold_lt", UITheme.c("gold_lt"))
	card.material = glass
	card.resized.connect(func(): glass.set_shader_parameter("size", card.size + Vector2.ONE * CARD_PAD * 2.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	card.add_child(v)

	v.add_child(_build_tabs())

	notice_panel = _build_notice()
	v.add_child(notice_panel)

	username_input = _edit(tr("Your username"))
	username_input.name = "UsernameInput"
	username_input.max_length = 24
	v.add_child(_field(tr("USERNAME"), _input_box("user.svg", username_input, [])))

	password_input = _edit(tr("Your password"))
	password_input.name = "PasswordInput"
	password_input.secret = true
	password_input.max_length = 128
	reveal_btn = Button.new()
	reveal_btn.name = "RevealButton"
	reveal_btn.flat = true
	reveal_btn.focus_mode = Control.FOCUS_NONE
	reveal_btn.icon = _icon("eye.svg")
	reveal_btn.tooltip_text = tr("Show")
	reveal_btn.custom_minimum_size = Vector2(40, 0)
	reveal_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reveal_btn.expand_icon = true
	reveal_btn.add_theme_constant_override("icon_max_width", 18)
	reveal_btn.add_theme_color_override("icon_normal_color", UITheme.c("text_dim"))
	reveal_btn.add_theme_color_override("icon_hover_color", UITheme.c("gold_hi"))
	reveal_btn.add_theme_color_override("icon_pressed_color", UITheme.c("gold_hi"))
	reveal_btn.add_theme_color_override("icon_focus_color", UITheme.c("text_dim"))
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		reveal_btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	reveal_btn.pressed.connect(_toggle_reveal)
	_saved_chip = _build_saved_chip()
	v.add_child(_field(tr("PASSWORD"), _input_box("lock.svg", password_input, [_saved_chip, reveal_btn])))

	confirm_input = _edit(tr("Type your password again"))
	confirm_input.name = "ConfirmInput"
	confirm_input.secret = true
	confirm_input.max_length = 128
	confirm_block = _field(tr("PASSWORD (AGAIN)"), _input_box("lock.svg", confirm_input, []))
	v.add_child(confirm_block)

	# the two remember boxes, "Forgot your password?" beside them
	var opts := HBoxContainer.new()
	_opts_row = opts
	opts.name = "Options"
	var checks := VBoxContainer.new()
	checks.add_theme_constant_override("separation", 9)
	opts.add_child(checks)
	remember_check = _check(tr("Remember my username"))
	remember_check.name = "RememberCheck"
	remember_check.button_pressed = true
	checks.add_child(remember_check)
	remember_pass_check = _check(tr("Remember my password"))
	remember_pass_check.name = "RememberPassCheck"
	remember_pass_check.tooltip_text = tr("Not your password: a secure login key that works only on this computer for 30 days. Changing your password ends it.")
	checks.add_child(remember_pass_check)
	# the password is remembered with its username; no username, no password
	remember_pass_check.toggled.connect(func(on: bool):
		if on:
			remember_check.button_pressed = true
		elif _using_saved:
			_forget_saved())
	remember_check.toggled.connect(func(on: bool):
		if not on:
			remember_pass_check.button_pressed = false)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(spacer)
	forgot_btn = AccountDialogs.link(tr("Forgot your password?"), 13)
	forgot_btn.name = "ForgotPassword"
	forgot_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	forgot_btn.add_theme_color_override("font_color", UITheme.c("text_dim"))
	forgot_btn.add_theme_font_override("font", UITheme.font(UITheme.W_BODY))
	forgot_btn.pressed.connect(func(): recover_dialog.start(username_input.text.strip_edges()))
	opts.add_child(forgot_btn)
	v.add_child(opts)

	consent = AccountDialogs.ConsentBoxes.new()
	consent.name = "Consent"
	consent.read_requested.connect(func(kind: String): reader.show_document(kind))
	v.add_child(consent)
	for box: CheckBox in consent.find_children("*", "CheckBox", true, false):
		_dress_check(box)

	submit_btn = _build_enter()
	v.add_child(submit_btn)

	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(0, 22)
	status_label.add_theme_font_size_override("font_size", 14)
	v.add_child(status_label)

	password_input.text_changed.connect(_on_password_typed)
	username_input.text_changed.connect(func(_t: String):
		# another account: the saved login is not its
		if _using_saved and username_input.text.strip_edges() != _saved_user:
			_leave_saved(""))
	username_input.text_submitted.connect(func(_t: String): password_input.grab_focus())
	password_input.text_submitted.connect(func(_t: String):
		if register_mode:
			confirm_input.grab_focus()
		else:
			_on_submit())
	confirm_input.text_submitted.connect(func(_t: String): _on_submit())
	return card

## Log In / New Account, the chosen one underlined in lit gold that slides
## across when the other is picked.
func _build_tabs() -> Control:
	_tabs_box = Control.new()
	_tabs_box.name = "Tabs"
	_tabs_box.custom_minimum_size = Vector2(0, 44)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 0)
	_tabs_box.add_child(row)
	login_tab = _tab_button(tr("LOG IN"))
	login_tab.name = "LoginTab"
	register_tab = _tab_button(tr("NEW ACCOUNT"))
	register_tab.name = "RegisterTab"
	login_tab.pressed.connect(func(): _set_mode(false))
	register_tab.pressed.connect(func(): _set_mode(true))
	row.add_child(login_tab)
	row.add_child(register_tab)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.07)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	rule.offset_top = -1.0
	_tabs_box.add_child(rule)
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.3, 0.7, 1.0])
	gradient.colors = PackedColorArray([UITheme.alpha("gold_hi", 0.0), UITheme.c("gold_hi"),
		UITheme.c("gold_hi"), UITheme.alpha("gold_hi", 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 128
	tex.height = 1
	_tab_bar = TextureRect.new()
	_tab_bar.name = "TabBar"
	_tab_bar.texture = tex
	_tab_bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tab_bar.stretch_mode = TextureRect.STRETCH_SCALE
	_tab_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tabs_box.add_child(_tab_bar)
	_tabs_box.resized.connect(func():
		_tab_bar.size = Vector2(_tabs_box.size.x * 0.5, 2.0)
		_tab_bar.position = Vector2(_tabs_box.size.x * 0.5 if register_mode else 0.0, _tabs_box.size.y - 2.0))
	return _tabs_box

func _tab_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spaced := UITheme.font(UITheme.W_BOLD).duplicate() as FontVariation
	if spaced != null:
		spaced.spacing_glyph = 2
		b.add_theme_font_override("font", spaced)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UITheme.c("text_dim"))
	b.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	b.add_theme_color_override("font_pressed_color", UITheme.c("gold_hi"))
	b.add_theme_color_override("font_hover_pressed_color", UITheme.c("gold_hi"))
	b.add_theme_color_override("font_disabled_color", UITheme.alpha("text_dim", 0.6))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	return b

func _edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_size_override("font_size", 16)
	edit.add_theme_color_override("font_color", UITheme.c("parchment"))
	edit.add_theme_color_override("font_uneditable_color", UITheme.c("text_dim"))
	edit.add_theme_color_override("font_placeholder_color", FIELD_PLACEHOLDER)
	edit.add_theme_color_override("caret_color", UITheme.c("gold_hi"))
	edit.add_theme_color_override("selection_color", UITheme.alpha("gold", 0.45))
	for state in ["normal", "focus", "read_only"]:
		var empty := StyleBoxEmpty.new()
		empty.content_margin_left = 0
		empty.content_margin_right = 4
		edit.add_theme_stylebox_override(state, empty)
	return edit

## A field's well: dark, its icon on the left, lit gold while it has focus.
func _input_box(icon: String, edit: LineEdit, extras: Array) -> Control:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(0, 46)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0, 0, 0, 0.36)
	normal.border_color = Color(1, 1, 1, 0.08)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(6)
	normal.content_margin_left = 14
	normal.content_margin_right = 4
	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = UITheme.alpha("gold_lt", 0.7)
	focus.shadow_color = UITheme.alpha("gold_lt", 0.18)
	focus.shadow_size = 9
	box.add_theme_stylebox_override("panel", normal)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var glyph := _icon_rect(icon, 18.0, UITheme.c("text_dim"))
	row.add_child(glyph)
	row.add_child(edit)
	for extra: Control in extras:
		extra.size_flags_vertical = Control.SIZE_SHRINK_CENTER if extra is PanelContainer else Control.SIZE_FILL
		row.add_child(extra)
	edit.focus_entered.connect(func():
		box.add_theme_stylebox_override("panel", focus)
		glyph.modulate = UITheme.c("gold_lt"))
	edit.focus_exited.connect(func():
		box.add_theme_stylebox_override("panel", normal)
		glyph.modulate = UITheme.c("text_dim"))
	return box

## "Saved": the password field holds a saved login, not a typed password.
func _build_saved_chip() -> Control:
	var chip := PanelContainer.new()
	chip.name = "SavedChip"
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.alpha("gold_lt", 0.12)
	sb.border_color = UITheme.alpha("gold_lt", 0.35)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(11)
	sb.content_margin_left = 9
	sb.content_margin_right = 10
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	chip.add_theme_stylebox_override("panel", sb)
	chip.tooltip_text = tr("Not your password: a secure login key that works only on this computer for 30 days. Changing your password ends it.")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(row)
	row.add_child(_icon_rect("key.svg", 12.0, UITheme.c("gold_hi")))
	var label := Label.new()
	label.text = tr("Saved")
	label.add_theme_font_override("font", UITheme.font(UITheme.W_BOLD))
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", UITheme.c("gold_hi"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	chip.hide()
	return chip

func _check(text: String) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.focus_mode = Control.FOCUS_NONE
	_dress_check(check)
	return check

## The gold check boxes (check_on / check_off).
func _dress_check(check: CheckBox) -> void:
	check.add_theme_icon_override("checked", _icon("check_on.svg"))
	check.add_theme_icon_override("unchecked", _icon("check_off.svg"))
	check.add_theme_icon_override("checked_disabled", _icon("check_on.svg"))
	check.add_theme_icon_override("unchecked_disabled", _icon("check_off.svg"))
	check.add_theme_constant_override("h_separation", 10)
	check.add_theme_font_size_override("font_size", 14)
	check.add_theme_color_override("font_color", UITheme.c("text"))
	check.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	check.add_theme_color_override("font_pressed_color", UITheme.c("text"))
	check.add_theme_color_override("font_hover_pressed_color", UITheme.c("parchment"))
	# The theme gives every Button-derived control a plate; a checkbox wants none.
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		check.add_theme_stylebox_override(state, StyleBoxEmpty.new())

## Enter Game: lit gold with a glow and a passing sheen (login_button.gdshader
## on a face BUTTON_PAD wider than the button), brighter under the pointer.
func _build_enter() -> Button:
	var b := Button.new()
	b.name = "SubmitButton"
	b.text = tr("ENTER GAME")
	b.custom_minimum_size = Vector2(0, 56)
	b.focus_mode = Control.FOCUS_NONE
	var spaced := UITheme.font(UITheme.W_DECO).duplicate() as FontVariation
	if spaced != null:
		spaced.spacing_glyph = 4
		b.add_theme_font_override("font", spaced)
	b.add_theme_font_size_override("font_size", 17)
	for colour in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(colour, INK)
	b.add_theme_color_override("font_disabled_color", Color(0.23, 0.2, 0.15))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var face := ColorRect.new()
	face.name = "Face"
	face.show_behind_parent = true
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	face.offset_left = -BUTTON_PAD
	face.offset_top = -BUTTON_PAD
	face.offset_right = BUTTON_PAD
	face.offset_bottom = BUTTON_PAD
	_enter_mat = ShaderMaterial.new()
	_enter_mat.shader = BUTTON_SHADER
	_enter_mat.set_shader_parameter("pad", BUTTON_PAD)
	face.material = _enter_mat
	b.add_child(face)
	b.resized.connect(func(): _enter_mat.set_shader_parameter("size", b.size + Vector2.ONE * BUTTON_PAD * 2.0))
	var ease_to := func(param: String, value: float, seconds: float):
		var from := float(_enter_mat.get_shader_parameter(param))
		b.create_tween().tween_method(func(x: float): _enter_mat.set_shader_parameter(param, x), from, value, seconds)
	b.mouse_entered.connect(func(): ease_to.call("hover", 1.0, 0.18))
	b.mouse_exited.connect(func(): ease_to.call("hover", 0.0, 0.25))
	b.button_down.connect(func(): _enter_mat.set_shader_parameter("press", 1.0))
	b.button_up.connect(func(): _enter_mat.set_shader_parameter("press", 0.0))
	# greyed with the button (busy, or a game too old for the realm)
	b.draw.connect(func(): _enter_mat.set_shader_parameter("disabled", 1.0 if b.disabled else 0.0))
	return b

func _field(caption: String, input: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	var label := Label.new()
	label.text = caption
	var spaced := UITheme.font(UITheme.W_BOLD).duplicate() as FontVariation
	if spaced != null:
		spaced.spacing_glyph = 2
		label.add_theme_font_override("font", spaced)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	box.add_child(input)
	return box

func _build_notice() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "MaintenanceNotice"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.3, 0.15, 0.02, 0.55)
	sb.border_color = Color(1.0, 0.67, 0.31, 0.45)
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 14
	sb.content_margin_right = 12
	sb.content_margin_top = 11
	sb.content_margin_bottom = 11
	panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	var lock := _icon_rect("lock.svg", 24.0, Color(1.0, 0.74, 0.36))
	lock.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(lock)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 3)
	row.add_child(texts)
	notice_title = Label.new()
	notice_title.add_theme_font_override("font", UITheme.font(UITheme.W_BOLD))
	notice_title.add_theme_font_size_override("font_size", 14)
	notice_title.add_theme_color_override("font_color", Color(1.0, 0.83, 0.57))
	texts.add_child(notice_title)
	notice_body = Label.new()
	notice_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice_body.add_theme_font_size_override("font_size", 13)
	notice_body.add_theme_color_override("font_color", Color(0.96, 0.9, 0.82))
	texts.add_child(notice_body)
	panel.hide()
	return panel

## A small dark glass plate (the corner's chips and pill).
static func _glass_box(radius: int, h_margin: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.024, 0.035, 0.06, 0.66)
	sb.border_color = Color(1, 1, 1, 0.09)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = h_margin
	sb.content_margin_right = h_margin
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb

func _build_server_pill() -> void:
	_top_right = VBoxContainer.new()
	_top_right.name = "Corner"
	_top_right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_top_right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_top_right.offset_left = -420.0
	_top_right.offset_right = -28.0
	_top_right.offset_top = 24.0
	_top_right.add_theme_constant_override("separation", 10)
	add_child(_top_right)
	server_pill = PanelContainer.new()
	server_pill.name = "ServerPill"
	server_pill.size_flags_horizontal = Control.SIZE_SHRINK_END
	var pill := _glass_box(18, 15.0)
	pill.content_margin_left = 13
	server_pill.add_theme_stylebox_override("panel", pill)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 13)
	server_pill.add_child(row)
	server_dot = Panel.new()
	server_dot.custom_minimum_size = Vector2(9, 9)
	server_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(server_dot)
	# a ring goes out from the dot now and then: the realm is alive
	var ring := Panel.new()
	ring.name = "Ping"
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.size = Vector2(19, 19)
	ring.position = Vector2(-5, -5)
	ring.pivot_offset = Vector2(9.5, 9.5)
	server_dot.add_child(ring)
	var ping := ring.create_tween().set_loops()
	ping.tween_property(ring, "scale", Vector2.ONE * 1.35, 2.2).from(Vector2.ONE * 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	ping.parallel().tween_property(ring, "modulate:a", 0.0, 2.2).from(0.7) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	server_label = Label.new()
	server_label.add_theme_font_size_override("font_size", 14)
	server_label.add_theme_color_override("font_color", UITheme.c("text"))
	row.add_child(server_label)
	_top_right.add_child(server_pill)
	_render_server_state()

## The corner's glass chip (Settings, the language).
func _chip_style(button: Button, icon: String) -> void:
	button.focus_mode = Control.FOCUS_NONE
	button.icon = _icon(icon)
	# the icon's own size capped (it keeps its shape); expand_icon would
	# squeeze it out beside the text
	button.add_theme_constant_override("icon_max_width", 15)
	button.add_theme_constant_override("h_separation", 8)
	button.add_theme_font_override("font", UITheme.font(UITheme.W_BODY))
	button.custom_minimum_size = Vector2(0, 34)
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_color_override("font_color", UITheme.c("text"))
	button.add_theme_color_override("font_hover_color", UITheme.c("gold_hi"))
	button.add_theme_color_override("font_pressed_color", UITheme.c("gold_hi"))
	button.add_theme_color_override("font_focus_color", UITheme.c("text"))
	button.add_theme_color_override("icon_normal_color", UITheme.c("text"))
	button.add_theme_color_override("icon_hover_color", UITheme.c("gold_hi"))
	button.add_theme_color_override("icon_pressed_color", UITheme.c("gold_hi"))
	var normal := _glass_box(6, 14.0)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.border_color = UITheme.alpha("gold_lt", 0.5)
	for state in ["normal", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, hover)

## The language, beside Settings under the server pill. A change rebuilds the
## screen in the new language (nothing typed here is worth more than a
## remembered username).
func _build_language_picker() -> void:
	var tools := HBoxContainer.new()
	tools.name = "Tools"
	tools.size_flags_horizontal = Control.SIZE_SHRINK_END
	tools.add_theme_constant_override("separation", 8)
	_top_right.add_child(tools)
	# Settings: the interface scale, window, keys and credits are needed
	# before the first login too
	var settings := Button.new()
	settings.name = "SettingsButton"
	settings.text = tr("Settings")
	_chip_style(settings, "gear.svg")
	settings.pressed.connect(func(): settings_requested.emit())
	tools.add_child(settings)
	var picker := OptionButton.new()
	language_picker = picker
	picker.name = "LanguagePicker"
	_chip_style(picker, "globe.svg")
	# the language's own name with the globe, no arrow: the globe says what it is
	picker.add_theme_icon_override("arrow", ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8)))
	picker.add_theme_constant_override("arrow_margin", 0)
	# Each language is listed under its own name, never translated.
	picker.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	picker.tooltip_text = tr("Language")
	var languages: Array = I18n.languages()
	for i in languages.size():
		picker.add_icon_item(_icon("globe.svg"), String(languages[i].name), i)
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
	tools.add_child(picker)

func _footer_button(text: String, icon: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.icon = _icon(icon)
	b.add_theme_constant_override("icon_max_width", 14)
	b.add_theme_constant_override("h_separation", 7)
	b.add_theme_font_override("font", UITheme.font(UITheme.W_BODY))
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UITheme.c("text_dim"))
	b.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	b.add_theme_color_override("font_pressed_color", UITheme.c("parchment"))
	b.add_theme_color_override("icon_normal_color", UITheme.c("text_dim"))
	b.add_theme_color_override("icon_hover_color", UITheme.c("parchment"))
	b.add_theme_color_override("icon_pressed_color", UITheme.c("parchment"))
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	return b

func _build_footer() -> void:
	var version := Label.new()
	version.name = "VersionLabel"
	version.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	version.offset_left = 24.0
	version.offset_top = -36.0
	version.offset_bottom = -14.0
	version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version.text = "%s  %s" % [UITheme.GAME_TITLE, _client_version()]
	version.add_theme_font_size_override("font_size", 12)
	version.add_theme_color_override("font_color", UITheme.alpha("text_dim", 0.8))
	add_child(version)
	var row := HBoxContainer.new()
	row.name = "FooterLinks"
	row.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	row.offset_left = -400.0
	row.offset_right = -24.0
	row.offset_top = -46.0
	row.offset_bottom = -12.0
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 22)
	add_child(row)
	var help := _footer_button(tr("Help & Support"), "help.svg")
	help.name = "HelpButton"
	help.pressed.connect(AccountDialogs.open_support)
	row.add_child(help)
	var quit := _footer_button(tr("Quit Game"), "power.svg")
	quit.name = "QuitButton"
	quit.pressed.connect(func(): get_tree().quit())
	row.add_child(quit)

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
	_opts_row.visible = not register_mode
	if _tabs_box.size.x > 0.0:
		_tab_bar.create_tween().tween_property(_tab_bar, "position:x",
			_tabs_box.size.x * 0.5 if register_mode else 0.0, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	submit_btn.text = tr("CREATE ACCOUNT") if register_mode else tr("ENTER GAME")
	password_input.placeholder_text = tr("8+ characters, letters and digits") if register_mode else tr("Your password")
	confirm_input.text = ""
	set_status("")

## The saved login stands in the password field (dots, Enter logs in).
func _show_saved() -> void:
	_using_saved = true
	password_input.text = SAVED_FILL
	password_input.select_all_on_focus = true
	reveal_btn.visible = false
	_saved_chip.visible = true
	remember_pass_check.set_pressed_no_signal(true)

## The field becomes a real password field again; `typed` is what the
## player has typed into it so far.
func _leave_saved(typed: String) -> void:
	_using_saved = false
	password_input.select_all_on_focus = false
	password_input.text = typed
	password_input.caret_column = typed.length()
	reveal_btn.visible = true
	_saved_chip.visible = false

func _forget_saved() -> void:
	_leave_saved("")
	_saved_token = ""
	_saved_user = ""
	if keep_prefs:
		LoginApi.forget_saved_login()

func _on_password_typed(text: String) -> void:
	if _using_saved:
		# typing over the dots: only what was typed is kept
		_leave_saved(text.replace("•", ""))

func _toggle_reveal() -> void:
	password_input.secret = not password_input.secret
	confirm_input.secret = password_input.secret
	reveal_btn.icon = _icon("eye_off.svg" if not password_input.secret else "eye.svg")
	reveal_btn.tooltip_text = tr("Hide") if not password_input.secret else tr("Show")

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
	var ring := StyleBoxFlat.new()
	ring.draw_center = false
	ring.border_color = colour
	ring.set_border_width_all(1)
	ring.set_corner_radius_all(10)
	var ping := server_dot.get_node_or_null("Ping") as Panel
	if ping != null:
		ping.add_theme_stylebox_override("panel", ring)

## ================================================================ auth

func _on_submit() -> void:
	if busy:
		return
	var user := username_input.text.strip_edges()
	var pass_w := password_input.text
	if _using_saved and not register_mode and user == _saved_user:
		_do_login(user, "", _saved_token)
		return
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

func _do_login(user: String, pass_w: String, saved := "") -> void:
	_set_busy(true, tr("Logging in…"))
	var remember := remember_pass_check.button_pressed and keep_prefs
	var res: Dictionary = await api.login(user, pass_w, remember, saved)
	if not is_inside_tree():
		return
	_set_busy(false)
	if not res.ok:
		if String(res.reason) == "remember_refused":
			# run out, or the password was changed: the password is needed
			_forget_saved()
			remember_pass_check.button_pressed = true
			set_status(tr("Your saved login has run out. Please enter your password."), "warn")
			password_input.grab_focus()
		elif res.update_required:
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
	if saved == "" and not remember and keep_prefs:
		# logged in with the password and not asked to keep it
		LoginApi.forget_saved_login()
	_leave_saved("")
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

## The username, and with it a saved login (never the password).
func _load_prefs() -> void:
	_load_saved()
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
	if _using_saved:
		# the saved login names its own account
		username_input.text = _saved_user
		remember_check.set_pressed_no_signal(true)

func _load_saved() -> void:
	if not keep_prefs:
		return
	var saved := LoginApi.saved_login()
	if saved.is_empty():
		return
	_saved_user = String(saved["username"])
	_saved_token = String(saved["token"])
	username_input.text = _saved_user
	_show_saved()

func _save_prefs(user: String) -> void:
	if not keep_prefs:
		return
	var remember := remember_check.button_pressed
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"remember": remember, "username": user if remember else ""}))
