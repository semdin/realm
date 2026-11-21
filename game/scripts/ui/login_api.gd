extends Node
class_name LoginApi

## The login service (crates/realm_login) as the front door talks to it:
## JSON over HTTP, `base_url` from `--login-url` (default default_url():
## the realm's own service in an exported game, a local one in a dev run).
##
##   register(user, pass)        POST /api/register (consent given) -> the recovery code
##   login(user, pass)           POST /api/login -> the session token
##   logout()                    POST /api/logout (Bearer)
##   characters()                POST /api/characters/list (Bearer)
##   create(name, house, look)   POST /api/characters/create (Bearer)
##   delete_character(id, name)  POST /api/characters/delete (Bearer)
##   play(character_id)          POST /api/play (Bearer) -> map, address, ticket
##   status()                    GET  /api/status
##   legal_document(kind)        GET  /api/legal/<kind>/<language>.json
##   account_info(), accept_terms(), change_password(..), new_recovery_code(..),
##   recover(..), delete_account(..)   POST /api/account/...
##
## Every call is awaitable and answers {ok, code, body, error, reason}: `error`
## is the player's sentence, already translated (the service's English sentence
## through I18n, "maintenance" and an unreachable service in our own words);
## `reason` is the service's refusal code; `maintenance` is true when the realm
## takes no logins, `update_required` when this game is too old for it.
##
## The session token lives in memory only (`token`, static: it outlives the
## scene reload into the world and back), never on disk.

## A dev run's service (realm_login on loopback) and an exported game's.
const DEV_URL := "http://127.0.0.1:7950"
const RELEASE_URL := "https://api.agsilvery.com"
const TIMEOUT := 12.0
## Where players get help: the public issue tracker.
const SUPPORT_URL := "https://github.com/semdin/realm/issues"

# i18n-begin
## What the login service says, in its words (crates/realm_login, the name
## rule of realm_rules::names); listed so the catalogue carries them.
const SERVICE_LINES := [
	"Account names are 3-24 letters, digits, _ or -.",
	"Passwords need 8 or more characters with letters and digits.",
	"That account name is taken.",
	"That account name is not available.",
	"That name is not available.",
	"Service unavailable.",
	"Too many failed logins. Try again in a few minutes.",
	"Invalid username or password.",
	"Not logged in.",
	"Unknown house.",
	"Maximum 2 characters per account.",
	"Character name already taken.",
	"No such character.",
	"The realm is not reachable right now.",
	"Name must be 2-20 characters.",
	"Spaces, hyphens and apostrophes may only stand between letters.",
	"Names may only use letters, digits, spaces, hyphens and apostrophes.",
	"Names need at least one letter.",
	"Too many attempts. Try again in a few minutes.",
	"Too many new accounts from your network. Try again later.",
	"New accounts are paused for now. Try again later.",
	"The login service is busy. Try again in a moment.",
	"Invalid username or recovery code.",
	"Your current password is not correct.",
	"The name you typed does not match.",
	"The account name you typed does not match.",
	"That character could not leave the world yet. Try again in a moment.",
	"Accept the Terms of Service and Privacy Policy to continue.",
	"You must confirm that you are 16 or older.",
	"The Terms have changed. Please review them again.",
	"Your game is out of date. Close it and open the launcher to update.",
]
# i18n-end

static var token := ""
static var username := ""
## The last login's word: the account must accept the current terms first,
## which version they are, and whether it has a recovery code yet.
static var terms_required := false
static var terms_version := ""
static var has_recovery_code := true

var base_url := DEV_URL

static func default_url() -> String:
	return RELEASE_URL if RealmPaths.is_release() else DEV_URL

func _init(url: String = "") -> void:
	name = "LoginApi"
	base_url = (url if url != "" else default_url()).strip_edges().rstrip("/")

func signed_in() -> bool:
	return token != ""

## This build's protocol, sent so the service can say "update" before anything
## else happens (0: the native library is not loaded).
static func protocol_version() -> int:
	if not ClassDB.class_exists("RealmInfo"):
		return 0
	return int(ClassDB.class_call_static("RealmInfo", "protocol_version"))

func _with_protocol(body: Dictionary) -> Dictionary:
	var version := protocol_version()
	if version > 0:
		body["protocol_version"] = version
	return body

## The player has ticked both consent boxes; the service wants the version of
## the terms they were shown.
func register(user: String, password: String) -> Dictionary:
	var version: String = await current_terms_version()
	return await _call("/api/register", _with_protocol({"username": user, "password": password,
		"terms_version": version, "terms_accepted": true, "age_confirmed": true}), false)

## A good answer keeps the token (and the name the service spells).
## `remember` asks for a saved login ("Remember my password"); `saved` logs
## in with one instead of the password. A saved login the service refuses
## (run out, or the password changed since) answers reason
## "remember_refused".
func login(user: String, password: String, remember := false, saved := "") -> Dictionary:
	var body := {"username": user, "password": password, "remember": remember}
	if saved != "":
		body = {"username": user, "remember_token": saved}
	var res: Dictionary = await _call("/api/login", _with_protocol(body), false)
	if res.ok:
		token = String(res.body.get("token", ""))
		username = String(res.body.get("username", user))
		var renewed := String(res.body.get("remember_token", ""))
		if renewed != "" and (remember or saved != ""):
			keep_saved_login(username, renewed)
	elif saved != "" and String(res.reason) == "remember_refused":
		forget_saved_login()
		terms_required = bool(res.body.get("terms_required", false))
		terms_version = String(res.body.get("terms_version", ""))
		has_recovery_code = bool(res.body.get("has_recovery_code", true))
	return res

## The version of the terms the service asks for now.
func current_terms_version() -> String:
	var res: Dictionary = await _call("/api/legal", {}, false, HTTPClient.METHOD_GET)
	if res.ok:
		terms_version = String(res.body.get("version", terms_version))
	return terms_version

func accept_terms() -> Dictionary:
	var version: String = await current_terms_version()
	var res: Dictionary = await _call("/api/account/accept-terms",
		{"terms_version": version, "terms_accepted": true, "age_confirmed": true}, true)
	if res.ok:
		terms_required = false
	return res

func account_info() -> Dictionary:
	var res: Dictionary = await _call("/api/account/info", {}, true)
	if res.ok:
		has_recovery_code = bool(res.body.get("has_recovery_code", true))
	return res

## Every session ends; this client continues on the new token it gets back.
func change_password(current: String, new_password: String, playing_character := 0) -> Dictionary:
	var res: Dictionary = await _call("/api/account/password", {"current_password": current,
		"new_password": new_password, "keep_character": playing_character}, true)
	if res.ok:
		token = String(res.body.get("token", token))
		# a new password ends every saved login on the service
		forget_saved_login()
	return res

func new_recovery_code(password: String) -> Dictionary:
	var res: Dictionary = await _call("/api/account/recovery-code", {"password": password}, true)
	if res.ok:
		has_recovery_code = true
	return res

func recover(user: String, code: String, new_password: String) -> Dictionary:
	var res: Dictionary = await _call("/api/account/recover", {"username": user, "recovery_code": code,
		"new_password": new_password}, false)
	if res.ok:
		forget_saved_login()
	return res

func delete_character(character_id: int, typed_name: String) -> Dictionary:
	return await _call("/api/characters/delete", {"character_id": character_id, "confirm_name": typed_name}, true)

## Gone for good: the session goes with it.
func delete_account(password: String, typed_username: String) -> Dictionary:
	var res: Dictionary = await _call("/api/account/delete", {"password": password,
		"confirm_username": typed_username}, true)
	if res.ok:
		token = ""
		username = ""
		forget_saved_login()
	return res

## ================================================================ saved login

## "Remember my password" keeps the service's signed saved login (never the
## password) for this computer only: encrypted with a key from this
## machine's id, so the file is no use copied elsewhere. It runs out after
## the service's REMEMBER_DAYS, renewed by each use; a new password ends it.
const SAVED_LOGIN_PATH := "user://saved_login.bin"

static func _saved_key() -> String:
	return ("realm-saved-login:" + OS.get_unique_id()).sha256_text()

## {username, token}, or {} when there is none (or it cannot be read).
static func saved_login() -> Dictionary:
	if not FileAccess.file_exists(SAVED_LOGIN_PATH):
		return {}
	var file := FileAccess.open_encrypted_with_pass(SAVED_LOGIN_PATH, FileAccess.READ, _saved_key())
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or String(parsed.get("token", "")) == "" or String(parsed.get("username", "")) == "":
		return {}
	return {"username": String(parsed["username"]), "token": String(parsed["token"])}

static func keep_saved_login(user: String, saved: String) -> void:
	var file := FileAccess.open_encrypted_with_pass(SAVED_LOGIN_PATH, FileAccess.WRITE, _saved_key())
	if file != null:
		file.store_string(JSON.stringify({"username": user, "token": saved}))

static func forget_saved_login() -> void:
	if FileAccess.file_exists(SAVED_LOGIN_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVED_LOGIN_PATH))

## The language the legal documents are shown in.
static func legal_language() -> String:
	return "tr" if I18n.is_turkish() else "en"

func legal_url(kind: String) -> String:
	return "%s/api/legal/%s/%s" % [base_url, kind, legal_language()]

func legal_document(kind: String) -> Dictionary:
	return await _call("/api/legal/%s/%s.json" % [kind, legal_language()], {}, false, HTTPClient.METHOD_GET)

## Ends the session on the service too; the token is forgotten either way.
func logout() -> void:
	if token == "":
		return
	var old := token
	token = ""
	var res: Dictionary = await _call("/api/logout", {}, true, HTTPClient.METHOD_POST, old)
	if not res.ok:
		print("realm login: logout: %s" % res.error)

func characters() -> Dictionary:
	return await _call("/api/characters/list", {}, true)

## `look`: looks.json keys -> value; the service takes [[key, value], ...]
## and cleans it.
func create(character_name: String, house: String, look: Dictionary) -> Dictionary:
	var pairs: Array = []
	for key: String in look:
		pairs.append([key, float(look[key])])
	return await _call("/api/characters/create", {"name": character_name, "house": house, "look": pairs}, true)

func play(character_id: int) -> Dictionary:
	return await _call("/api/play", _with_protocol({"character_id": character_id}), true)

func health() -> Dictionary:
	return await _call("/api/health", {}, false, HTTPClient.METHOD_GET)

## {state, realm: open|maintenance|unreachable, protocol_version, ...}
func status() -> Dictionary:
	return await _call("/api/status", {}, false, HTTPClient.METHOD_GET)

## A look as the roster sends it ([[key, value], ...]) as a dictionary.
static func look_of(pairs: Variant) -> Dictionary:
	var out := {}
	if pairs is Array:
		for pair: Variant in pairs:
			if pair is Array and (pair as Array).size() == 2:
				out[String(pair[0])] = pair[1]
	return Looks.clean_look(out)

func _call(path: String, body: Dictionary, bearer: bool, method := HTTPClient.METHOD_POST, with_token := "") -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	# Its own thread: polled from frames, a request barely moves while the
	# first frames compile shaders for seconds (a Mac's first start), and the
	# timeout ran out before it was even sent ("unreachable (result 13)").
	http.use_threads = true
	add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if bearer:
		headers.append("Authorization: Bearer %s" % (with_token if with_token != "" else token))
	var sent := http.request(base_url + path, headers, method, JSON.stringify(body) if method == HTTPClient.METHOD_POST else "")
	if sent != OK:
		http.queue_free()
		return _answer(false, 0, {}, tr("Could not reach the login server. Check your connection and try again."))
	var reply: Array = await http.request_completed
	http.queue_free()
	var result: int = reply[0]
	var code: int = reply[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		print("realm login: %s unreachable (result %d)" % [path, result])
		return _answer(false, 0, {}, tr("Could not reach the login server. Check your connection and try again."))
	var parsed: Variant = JSON.parse_string((reply[3] as PackedByteArray).get_string_from_utf8())
	var data: Dictionary = parsed if parsed is Dictionary else {}
	if code == 200 and bool(data.get("success", path == "/api/health" or path == "/api/status")):
		return _answer(true, code, data, "")
	var english := String(data.get("error", ""))
	print("realm login: %s -> %d %s" % [path, code, english])
	if english == "maintenance":
		var res := _answer(false, code, data, tr("The server is under maintenance. Please try again a little later."))
		res["maintenance"] = true
		return res
	if String(data.get("code", "")) == "realm_full":
		var position := int(data.get("position", 0))
		var line := tr("The realm is full. You are number %d in line.") % position if position > 0 \
			else tr("The realm is full. Please try again in a few minutes.")
		var res := _answer(false, code, data, line)
		res["queued"] = position > 0
		res["retry_s"] = maxf(2.0, float(data.get("retry_s", 5)))
		return res
	if String(data.get("code", "")) == "banned":
		var why := MaintenanceUI.sanction_text({"state": "ban", "reason": data.get("reason", ""), "until": data.get("until", 0)})
		return _answer(false, code, data, "%s\n%s" % [tr("This account is banned"), why])
	if code == 426 or String(data.get("code", "")) == "update_required":
		var res := _answer(false, code, data, tr("Your game is out of date. Close it and open the launcher to update."))
		res["update_required"] = true
		return res
	if code == 401 and bearer and with_token == "":
		# the session ran out (24 h) or a newer login pushed it out
		token = ""
	var text := I18n.from_server(english)
	if english == "" or (text == english and I18n.current != I18n.SOURCE_LANGUAGE):
		text = tr("Something went wrong (%d). Please try again.") % code
	return _answer(false, code, data, text)

static func _answer(ok: bool, code: int, body: Dictionary, error: String) -> Dictionary:
	return {"ok": ok, "code": code, "body": body, "error": error, "maintenance": false,
		"update_required": false, "reason": String(body.get("code", ""))}
