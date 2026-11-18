extends VBoxContainer
class_name AccountPanel

## The account page: the signed-in name, a new password, a new recovery code,
## the Terms, the Privacy Policy and Help, and deleting the account. It is the
## Settings window's Account tab in the world and the Account window on the
## character screen. Everything goes through the login service with the
## session the login card opened; a game that came in without one (a dev
## join) only shows the documents and Help.

## The account is gone: the screen around this page goes back to the card.
signal account_deleted

const WIDTH := 560.0

var api: LoginApi
## The character this client is playing (its session survives a new password).
var playing_character := 0
var who: Label
var current_input: LineEdit
var new_input: LineEdit
var again_input: LineEdit
var password_btn: Button
var password_status: Label
var code_state: Label
var code_password: LineEdit
var code_btn: Button
var code_status: Label
var delete_password: LineEdit
var delete_name: LineEdit
var delete_btn: Button
var delete_status: Label
var _signed_blocks: Array[Control] = []
var _reader: AccountDialogs.Reader
var _code_dialog: AccountDialogs.RecoveryCode

func setup(p_api: LoginApi, dialogs_parent: Control) -> void:
	api = p_api
	_reader = AccountDialogs.Reader.new(api)
	dialogs_parent.add_child(_reader)
	_code_dialog = AccountDialogs.RecoveryCode.new()
	dialogs_parent.add_child(_code_dialog)

func _ready() -> void:
	name = "AccountPanel"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.name = "AccountScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 9)
	scroll.add_child(rows)
	who = HudKit.label("", 15, HudKit.PARCHMENT, HudKit.bold(), 0)
	who.name = "SignedInAs"
	rows.add_child(who)
	_build_password(rows)
	_build_recovery(rows)
	_build_help(rows)
	_build_delete(rows)
	refresh()

func _section(rows: VBoxContainer, title: String, signed_only: bool) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var head := HudKit.label(I18n.upper(title), 14, HudKit.GOLD, HudKit.title(), 0)
	box.add_child(head)
	rows.add_child(box)
	if signed_only:
		_signed_blocks.append(box)
	return box

func _message(box: VBoxContainer) -> Label:
	var l := AccountDialogs.note("", WIDTH, 13)
	box.add_child(l)
	return l

func _build_password(rows: VBoxContainer) -> void:
	var box := _section(rows, tr("Change password"), true)
	current_input = AccountDialogs.field(tr("Current password"), true)
	current_input.name = "CurrentPassword"
	box.add_child(current_input)
	new_input = AccountDialogs.field(tr("New password (8+ characters, letters and digits)"), true)
	new_input.name = "NewPassword"
	box.add_child(new_input)
	again_input = AccountDialogs.field(tr("New password (again)"), true)
	again_input.name = "NewPasswordAgain"
	box.add_child(again_input)
	box.add_child(AccountDialogs.note(tr("Changing it logs your account out everywhere else."), WIDTH, 13, HudKit.TEXT_DIM))
	password_btn = HudKit.button(tr("Change password"), 14)
	password_btn.name = "ChangePassword"
	password_btn.custom_minimum_size = Vector2(190, 32)
	password_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	password_btn.pressed.connect(change_password)
	box.add_child(password_btn)
	password_status = _message(box)

func _build_recovery(rows: VBoxContainer) -> void:
	var box := _section(rows, tr("Recovery code"), true)
	code_state = AccountDialogs.note("", WIDTH, 14)
	code_state.name = "RecoveryState"
	box.add_child(code_state)
	code_password = AccountDialogs.field(tr("Current password"), true)
	code_password.name = "RecoveryPassword"
	box.add_child(code_password)
	code_btn = HudKit.button(tr("Make a new recovery code"), 14)
	code_btn.name = "NewRecoveryCode"
	code_btn.custom_minimum_size = Vector2(240, 32)
	code_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	code_btn.pressed.connect(make_code)
	box.add_child(code_btn)
	code_status = _message(box)

func _build_help(rows: VBoxContainer) -> void:
	var box := _section(rows, tr("Help and legal"), false)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for spec: Array in [["help", tr("Help & Support")], ["terms", tr("Terms of Service")], ["privacy", tr("Privacy Policy")]]:
		var kind := String(spec[0])
		var b := HudKit.button(String(spec[1]), 13)
		b.name = "Open_" + kind
		b.custom_minimum_size = Vector2(150, 30)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if kind == "help":
			b.pressed.connect(AccountDialogs.open_support)
		else:
			b.pressed.connect(func(): _reader.show_document(kind))
		row.add_child(b)
	box.add_child(row)

func _build_delete(rows: VBoxContainer) -> void:
	var box := _section(rows, tr("Delete account"), true)
	box.add_child(AccountDialogs.note(tr("This cannot be undone. Your account and all of its characters are deleted, and you are disconnected. Only an anonymous record of the deletion is kept; logs and backups expire as the Privacy Policy explains."),
		WIDTH, 13, AccountDialogs.COLOR_WARN))
	delete_password = AccountDialogs.field(tr("Current password"), true)
	delete_password.name = "DeletePassword"
	box.add_child(delete_password)
	delete_name = AccountDialogs.field(tr("Type your username to confirm"), false, 24)
	delete_name.name = "DeleteUsername"
	delete_name.text_changed.connect(func(_t: String): _refresh_delete())
	box.add_child(delete_name)
	delete_btn = AccountDialogs.danger_button(tr("Delete my account"), 14)
	delete_btn.name = "DeleteAccount"
	delete_btn.custom_minimum_size = Vector2(200, 32)
	delete_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	delete_btn.pressed.connect(delete_account)
	box.add_child(delete_btn)
	delete_status = _message(box)

func _refresh_delete() -> void:
	delete_btn.disabled = delete_name.text.strip_edges().to_lower() != LoginApi.username.to_lower() or LoginApi.username == ""

## What the page shows now, and the service's word on the recovery code.
func refresh() -> void:
	var signed: bool = api != null and api.signed_in()
	for block in _signed_blocks:
		block.visible = signed
	who.text = tr("Logged in as %s") % LoginApi.username if signed else tr("Log in from the login screen to manage your account.")
	_refresh_delete()
	if not signed:
		return
	code_state.text = tr("Checking…")
	var res: Dictionary = await api.account_info()
	if not is_inside_tree():
		return
	if res.ok:
		_show_code_state(bool(res.body.get("has_recovery_code", false)))
	else:
		code_state.text = res.error

func _show_code_state(has_code: bool) -> void:
	code_state.text = tr("You have a recovery code. Making a new one cancels the old one.") if has_code \
		else tr("You have no recovery code yet. Make one now: without it a forgotten password cannot be recovered.")

func change_password() -> void:
	AccountDialogs.set_message(password_status, "")
	if new_input.text != again_input.text:
		AccountDialogs.set_message(password_status, tr("The passwords do not match."))
		return
	password_btn.disabled = true
	var res: Dictionary = await api.change_password(current_input.text, new_input.text, playing_character)
	if not is_inside_tree():
		return
	password_btn.disabled = false
	if not res.ok:
		AccountDialogs.set_message(password_status, res.error)
		return
	current_input.text = ""
	new_input.text = ""
	again_input.text = ""
	AccountDialogs.set_message(password_status, tr("Your password was changed."), AccountDialogs.COLOR_OK)

func make_code() -> void:
	AccountDialogs.set_message(code_status, "")
	code_btn.disabled = true
	var res: Dictionary = await api.new_recovery_code(code_password.text)
	if not is_inside_tree():
		return
	code_btn.disabled = false
	if not res.ok:
		AccountDialogs.set_message(code_status, res.error)
		return
	code_password.text = ""
	_show_code_state(true)
	_code_dialog.present(String(res.body.get("recovery_code", "")))

func delete_account() -> void:
	AccountDialogs.set_message(delete_status, tr("Deleting…"), HudKit.GOLD_LT)
	delete_btn.disabled = true
	var res: Dictionary = await api.delete_account(delete_password.text, delete_name.text.strip_edges())
	if not is_inside_tree():
		return
	if not res.ok:
		_refresh_delete()
		AccountDialogs.set_message(delete_status, res.error)
		return
	account_deleted.emit()
