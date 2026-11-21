extends RefCounted
class_name AccountDialogs

## The windows of the account screens, shared by the login card, the character
## screen and the settings: the Terms and Privacy reader, the consent card,
## the one-time recovery code, the forgotten-password form and the typed
## confirmation before a deletion. They are the game's standard window
## (HudWindow, ArcaneSkin) over a dimmed screen, and everything they say comes
## from the catalogue; the legal text itself comes from the login service, in
## the language the game is showing.

const COLOR_ERROR := Color(0.96, 0.47, 0.42)
const COLOR_WARN := Color(1.0, 0.74, 0.36)
const COLOR_OK := Color(0.55, 0.85, 0.55)
const COLOR_DANGER := Color(0.62, 0.16, 0.14)

## ------------------------------------------------------------------ parts

static func caption(text: String) -> Label:
	return HudKit.label(I18n.upper(text), 13, HudKit.GOLD_LT, HudKit.title(), 0)

## Wrapped body text; `width` is what it may use before the first layout.
static func note(text: String, width: float, size := 14, colour := HudKit.TEXT) -> Label:
	var l := HudKit.label(text, size, colour, HudKit.body(), 0)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = width
	return l

static func field(placeholder: String, secret := false, max_length := 128) -> LineEdit:
	var edit := FrontDoor.line_edit(placeholder)
	edit.secret = secret
	edit.max_length = max_length
	edit.custom_minimum_size.y = 38
	edit.add_theme_font_size_override("font_size", 15)
	return edit

static func check(text: String) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.focus_mode = Control.FOCUS_NONE
	box.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_font_size_override("font_size", 14)
	for colour_name in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		box.add_theme_color_override(colour_name, HudKit.TEXT)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		box.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	# The theme's empty box all but vanishes on the dark card, and these are
	# boxes a player has to find.
	box.add_theme_icon_override("unchecked", _box_icon(false))
	box.add_theme_icon_override("checked", _box_icon(true))
	box.add_theme_constant_override("h_separation", 8)
	return box

static var _box_icons: Dictionary = {}

## A gold-edged square, with a tick when `ticked`.
static func _box_icon(ticked: bool) -> Texture2D:
	if _box_icons.has(ticked):
		return _box_icons[ticked]
	const SIZE := 18
	var image := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.02, 0.027, 0.043, 0.9))
	for i in SIZE:
		for edge: Vector2i in [Vector2i(i, 0), Vector2i(i, SIZE - 1), Vector2i(0, i), Vector2i(SIZE - 1, i)]:
			image.set_pixelv(edge, HudKit.GOLD_LT)
	if ticked:
		for i in 11:
			# down the short stroke, then up the long one
			var at := Vector2i(4 + i, 9 + i if i < 3 else 14 - i)
			for thick in 2:
				image.set_pixelv(at + Vector2i(0, thick - 1), HudKit.GOLD_HI)
	_box_icons[ticked] = ImageTexture.create_from_image(image)
	return _box_icons[ticked]

## A quiet text button: a link in the card.
static func link(text: String, size := 14) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", HudKit.GOLD_LT)
	b.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	b.add_theme_color_override("font_pressed_color", HudKit.GOLD)
	return b

## The button of an action that cannot be undone: the kit's blood plate.
static func danger_button(text: String, size := 15) -> Button:
	return UIKit.button(text, "blood", size)

static func set_message(label: Label, text: String, colour := COLOR_ERROR) -> void:
	label.text = text
	label.add_theme_color_override("font_color", colour)

## Opens a page in the player's browser (only https, or the local dev service).
static func open_url(url: String) -> void:
	if url.begins_with("https://") or url.begins_with("http://127.0.0.1"):
		OS.shell_open(url)

static func open_support() -> void:
	open_url(LoginApi.SUPPORT_URL)

## The legal documents' plain format as RichTextLabel markup.
static func markup(source: String) -> String:
	var out := PackedStringArray()
	for raw: String in source.split("\n"):
		var line := raw.strip_edges(false, true).replace("[", "[lb]")
		if line.begins_with("# "):
			continue
		if line.begins_with("## "):
			out.append("\n[font_size=18][color=#e8c87a][b]%s[/b][/color][/font_size]" % line.substr(3))
		elif line.begins_with("- "):
			out.append("  •  " + _inline(line.substr(2)))
		else:
			out.append(_inline(line))
	return "\n".join(out).strip_edges()

static func _inline(line: String) -> String:
	var parts := line.split("**")
	var text := ""
	for i in parts.size():
		text += ("[b]%s[/b]" % parts[i]) if i % 2 == 1 else parts[i]
	var at := text.find("https://")
	if at < 0:
		return text
	var end := at
	while end < text.length() and not " \t[".contains(text[end]):
		end += 1
	var url := text.substr(at, end - at).rstrip(".,;)")
	return text.substr(0, at) + "[url=%s][color=#7fceeb]%s[/color][/url]" % [url, url] + text.substr(at + url.length())

## ----------------------------------------------------------------- windows

## The game's window over a dimmed screen. Esc closes it unless it must be
## answered.
class Dialog extends HudWindow:
	var can_cancel := true
	var content_width := 460.0

	func _init(p_title: String, wanted: Vector2) -> void:
		super._init(p_title, wanted)
		content_width = wanted.x - 44.0
		add_to_group("account_dialog")

	func _ready() -> void:
		var dim := ColorRect.new()
		dim.name = "Dim"
		dim.color = Color(0, 0, 0, 0.6)
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(dim)
		super._ready()
		card.set_close_visible.call_deferred(can_cancel)

	func _unhandled_key_input(event: InputEvent) -> void:
		if visible and can_cancel and event.is_pressed() and (event as InputEventKey).keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			close()

## Terms of Service or Privacy Policy, read in the game; the same page opens
## in the browser.
class Reader extends Dialog:
	var api: LoginApi
	var text_view: RichTextLabel
	var status: Label
	var browser: Button
	var _kind := ""

	func _init(p_api: LoginApi) -> void:
		super._init("Terms of Service", Vector2(720, 640))
		name = "LegalReader"
		api = p_api

	func _ready() -> void:
		super._ready()
		text_view = RichTextLabel.new()
		text_view.name = "LegalText"
		text_view.bbcode_enabled = true
		text_view.selection_enabled = true
		text_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
		text_view.add_theme_font_override("normal_font", HudKit.body())
		text_view.add_theme_font_override("bold_font", HudKit.bold())
		text_view.add_theme_font_size_override("normal_font_size", 15)
		text_view.add_theme_font_size_override("bold_font_size", 15)
		text_view.add_theme_color_override("default_color", HudKit.TEXT)
		text_view.add_theme_constant_override("line_separation", 3)
		text_view.meta_clicked.connect(func(meta: Variant): AccountDialogs.open_url(String(meta)))
		body.add_child(text_view)
		status = AccountDialogs.note("", content_width, 14, AccountDialogs.COLOR_ERROR)
		body.add_child(status)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 10)
		browser = HudKit.button(tr("Open in browser"), 14)
		browser.custom_minimum_size = Vector2(170, 34)
		browser.pressed.connect(func(): AccountDialogs.open_url(api.legal_url(_kind)))
		row.add_child(browser)
		var done := HudKit.button(tr("Close"), 14)
		done.custom_minimum_size = Vector2(110, 34)
		done.pressed.connect(close)
		row.add_child(done)
		body.add_child(row)

	## `kind`: "terms" or "privacy".
	func show_document(kind: String) -> void:
		_kind = kind
		set_title("Terms of Service" if kind == "terms" else "Privacy Policy")
		open()
		text_view.text = tr("Loading…")
		status.text = ""
		var res: Dictionary = await api.legal_document(kind)
		if not is_inside_tree() or _kind != kind:
			return
		if res.ok:
			text_view.text = AccountDialogs.markup(String(res.body.get("text", "")))
			text_view.scroll_to_line(0)
		else:
			text_view.text = ""
			status.text = tr("The text could not be loaded. You can open it in your browser.")

## Two boxes and two links: the consent the registration form and the terms
## card share.
class ConsentBoxes extends VBoxContainer:
	signal changed
	signal read_requested(kind: String)
	var age: CheckBox
	var terms: CheckBox

	func _ready() -> void:
		add_theme_constant_override("separation", 2)
		age = AccountDialogs.check(tr("I am 16 years old or older."))
		age.name = "AgeCheck"
		age.toggled.connect(func(_on: bool): changed.emit())
		add_child(age)
		terms = AccountDialogs.check(tr("I accept the Terms of Service and the Privacy Policy."))
		terms.name = "TermsCheck"
		terms.toggled.connect(func(_on: bool): changed.emit())
		add_child(terms)
		var links := HBoxContainer.new()
		links.add_theme_constant_override("separation", 14)
		for spec: Array in [["terms", tr("Read the Terms")], ["privacy", tr("Read the Privacy Policy")]]:
			var kind := String(spec[0])
			var b := AccountDialogs.link(String(spec[1]), 13)
			b.name = "Read_" + kind
			b.pressed.connect(func(): read_requested.emit(kind))
			links.add_child(b)
		add_child(links)

	func accepted() -> bool:
		return age.button_pressed and terms.button_pressed

	func clear() -> void:
		age.button_pressed = false
		terms.button_pressed = false

## An account that has not accepted the current terms is asked at login.
class Consent extends Dialog:
	signal accepted
	signal declined
	var api: LoginApi
	var reader: Reader
	var boxes: ConsentBoxes
	var accept_btn: Button
	var status: Label

	func _init(p_api: LoginApi, p_reader: Reader) -> void:
		super._init("Terms of Service", Vector2(540, 340))
		name = "ConsentDialog"
		api = p_api
		reader = p_reader
		can_cancel = false

	func _ready() -> void:
		super._ready()
		body.add_child(AccountDialogs.note(tr("Please read and accept our Terms of Service and Privacy Policy to keep playing."), content_width))
		boxes = ConsentBoxes.new()
		body.add_child(boxes)
		boxes.changed.connect(func(): accept_btn.disabled = not boxes.accepted())
		boxes.read_requested.connect(reader.show_document)
		status = AccountDialogs.note("", content_width, 14, AccountDialogs.COLOR_ERROR)
		body.add_child(status)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 12)
		accept_btn = HudKit.gold_button(tr("Accept and continue"), 40.0, 15)
		accept_btn.name = "AcceptTerms"
		accept_btn.custom_minimum_size.x = 220
		accept_btn.disabled = true
		accept_btn.pressed.connect(_accept)
		row.add_child(accept_btn)
		var out := HudKit.button(tr("Log Out"), 14)
		out.custom_minimum_size = Vector2(120, UIKit.H_BUTTON)
		out.pressed.connect(func():
			close()
			declined.emit())
		row.add_child(out)
		body.add_child(row)

	func _accept() -> void:
		accept_btn.disabled = true
		var res: Dictionary = await api.accept_terms()
		if not is_inside_tree():
			return
		if res.ok:
			close()
			accepted.emit()
		else:
			accept_btn.disabled = false
			status.text = res.error

## The recovery code, shown this once.
class RecoveryCode extends Dialog:
	signal finished
	var code_box: LineEdit
	var saved: CheckBox
	var done_btn: Button

	func _init() -> void:
		super._init("Your recovery code", Vector2(560, 340))
		name = "RecoveryCodeDialog"
		can_cancel = false

	func _ready() -> void:
		super._ready()
		body.add_child(AccountDialogs.note(tr("If you forget your password, this code is the only way back into your account. It is shown only now. Keep it somewhere safe and never share it."), content_width))
		code_box = FrontDoor.line_edit("")
		code_box.name = "RecoveryCode"
		code_box.editable = false
		code_box.alignment = HORIZONTAL_ALIGNMENT_CENTER
		code_box.add_theme_font_size_override("font_size", 17)
		code_box.add_theme_color_override("font_uneditable_color", HudKit.GOLD_HI)
		body.add_child(code_box)
		var copy := HudKit.button(tr("Copy"), 14)
		copy.name = "CopyCode"
		copy.custom_minimum_size = Vector2(120, 32)
		copy.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		copy.pressed.connect(func():
			DisplayServer.clipboard_set(code_box.text)
			copy.text = tr("Copied"))
		body.add_child(copy)
		saved = AccountDialogs.check(tr("I have stored this code in a safe place."))
		saved.name = "CodeSaved"
		saved.toggled.connect(func(on: bool): done_btn.disabled = not on)
		body.add_child(saved)
		done_btn = HudKit.gold_button(tr("Continue"), 40.0, 15)
		done_btn.name = "CodeDone"
		done_btn.custom_minimum_size.x = 200
		done_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		done_btn.disabled = true
		done_btn.pressed.connect(func():
			code_box.text = ""
			close()
			finished.emit())
		body.add_child(done_btn)

	func present(code: String) -> void:
		code_box.text = code
		saved.button_pressed = false
		done_btn.disabled = true
		open()

## "Forgot your password?": the username, the code and a new password.
class Recover extends Dialog:
	signal recovered(new_code: String, username: String)
	var api: LoginApi
	var user_input: LineEdit
	var code_input: LineEdit
	var new_input: LineEdit
	var again_input: LineEdit
	var status: Label
	var submit: Button

	func _init(p_api: LoginApi) -> void:
		super._init("Recover your account", Vector2(520, 440))
		name = "RecoverDialog"
		api = p_api

	func _ready() -> void:
		super._ready()
		body.add_child(AccountDialogs.note(tr("Enter the recovery code you saved when you made your account. Without it the password cannot be reset, because we keep no email address."), content_width))
		user_input = _add(tr("Username"), tr("Your username"), false, 24)
		code_input = _add(tr("Recovery code"), "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", false, 64)
		new_input = _add(tr("New password"), tr("8+ characters, letters and digits"), true, 128)
		again_input = _add(tr("New password (again)"), tr("Type your password again"), true, 128)
		status = AccountDialogs.note("", content_width, 14, AccountDialogs.COLOR_ERROR)
		body.add_child(status)
		submit = HudKit.gold_button(tr("Set new password"), 40.0, 15)
		submit.name = "RecoverSubmit"
		submit.custom_minimum_size.x = 220
		submit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		submit.pressed.connect(_submit)
		body.add_child(submit)

	func _add(title: String, placeholder: String, secret: bool, limit: int) -> LineEdit:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 3)
		box.add_child(AccountDialogs.caption(title))
		var edit := AccountDialogs.field(placeholder, secret, limit)
		box.add_child(edit)
		body.add_child(box)
		return edit

	func start(username: String) -> void:
		user_input.text = username
		code_input.text = ""
		new_input.text = ""
		again_input.text = ""
		status.text = ""
		open()

	func _submit() -> void:
		if new_input.text != again_input.text:
			status.text = tr("The passwords do not match.")
			return
		submit.disabled = true
		var user := user_input.text.strip_edges()
		var res: Dictionary = await api.recover(user, code_input.text, new_input.text)
		if not is_inside_tree():
			return
		submit.disabled = false
		if not res.ok:
			status.text = res.error
			return
		close()
		recovered.emit(String(res.body.get("recovery_code", "")), user)

## Deleting something: the warning, its name typed back, the red button
## (live only when the name matches).
class ConfirmDelete extends Dialog:
	signal confirmed
	var warning: Label
	var prompt: Label
	var input: LineEdit
	var status: Label
	var delete_btn: Button
	var _expect := ""

	func _init() -> void:
		super._init("Delete character", Vector2(500, 300))
		name = "ConfirmDelete"

	func _ready() -> void:
		super._ready()
		warning = AccountDialogs.note("", content_width, 14, AccountDialogs.COLOR_WARN)
		body.add_child(warning)
		prompt = AccountDialogs.note("", content_width)
		body.add_child(prompt)
		input = AccountDialogs.field("", false, 32)
		input.name = "ConfirmName"
		input.text_changed.connect(func(_t: String): _refresh())
		body.add_child(input)
		status = AccountDialogs.note("", content_width, 14, AccountDialogs.COLOR_ERROR)
		body.add_child(status)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 12)
		delete_btn = AccountDialogs.danger_button(tr("Delete forever"))
		delete_btn.name = "ConfirmDeleteButton"
		delete_btn.custom_minimum_size = Vector2(170, UIKit.H_MAIN)
		delete_btn.pressed.connect(func():
			delete_btn.disabled = true
			confirmed.emit())
		row.add_child(delete_btn)
		var cancel := HudKit.button(tr("Cancel"), 14)
		cancel.custom_minimum_size = Vector2(110, UIKit.H_MAIN)
		cancel.pressed.connect(close)
		row.add_child(cancel)
		body.add_child(row)

	func ask(character_name: String) -> void:
		_expect = character_name
		warning.text = tr("This cannot be undone. The character, its items and its progress are deleted, and its name becomes free for others.")
		prompt.text = tr("Type %s to confirm:") % character_name
		input.text = ""
		status.text = ""
		_refresh()
		open()
		input.grab_focus.call_deferred()

	func refused(message: String) -> void:
		status.text = message
		_refresh()

	func _refresh() -> void:
		delete_btn.disabled = input.text.strip_edges().to_lower() != _expect.to_lower()
