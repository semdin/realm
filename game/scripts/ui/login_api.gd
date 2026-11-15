extends Node
class_name LoginApi

## The login service (crates/realm_login) as the front door talks to it:
## JSON over HTTP, `base_url` from `--login-url` (default DEFAULT_URL).
##
##   register(user, pass)        POST /api/register
##   login(user, pass)           POST /api/login -> the session token
##   logout()                    POST /api/logout (Bearer)
##   characters()                POST /api/characters/list (Bearer)
##   create(name, house, look)   POST /api/characters/create (Bearer)
##   play(character_id)          POST /api/play (Bearer) -> map, address, ticket
##   health()                    GET  /api/health
##
## Every call is awaitable and answers {ok, code, body, error}: `error` is
## the player's sentence, already translated (the service's English sentence
## through I18n, "maintenance" and an unreachable service in our own words);
## `maintenance` is true when the realm takes no logins.
##
## The session token lives in memory only (`token`, static: it outlives the
## scene reload into the world and back), never on disk.

const DEFAULT_URL := "http://127.0.0.1:7950"
const TIMEOUT := 12.0

# i18n-begin
## What the login service says, in its words (crates/realm_login, the name
## rule of realm_rules::names); listed so the catalogue carries them.
const SERVICE_LINES := [
	"Account names are 3-24 letters, digits, _ or -.",
	"Passwords need 8 or more characters with letters and digits.",
	"That account name is taken.",
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
]
# i18n-end

static var token := ""
static var username := ""

var base_url := DEFAULT_URL

func _init(url: String = DEFAULT_URL) -> void:
	name = "LoginApi"
	base_url = url.strip_edges().rstrip("/")

func signed_in() -> bool:
	return token != ""

func register(user: String, password: String) -> Dictionary:
	return await _call("/api/register", {"username": user, "password": password}, false)

## A good answer keeps the token (and the name the service spells).
func login(user: String, password: String) -> Dictionary:
	var res: Dictionary = await _call("/api/login", {"username": user, "password": password}, false)
	if res.ok:
		token = String(res.body.get("token", ""))
		username = String(res.body.get("username", user))
	return res

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
	return await _call("/api/play", {"character_id": character_id}, true)

func health() -> Dictionary:
	return await _call("/api/health", {}, false, HTTPClient.METHOD_GET)

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
	if code == 200 and bool(data.get("success", path == "/api/health")):
		return _answer(true, code, data, "")
	var english := String(data.get("error", ""))
	print("realm login: %s -> %d %s" % [path, code, english])
	if english == "maintenance":
		var res := _answer(false, code, data, tr("The server is under maintenance. Please try again a little later."))
		res["maintenance"] = true
		return res
	if code == 401 and bearer and with_token == "":
		# the session ran out (24 h) or a newer login pushed it out
		token = ""
	var text := I18n.from_server(english)
	if english == "" or (text == english and I18n.current != I18n.SOURCE_LANGUAGE):
		text = tr("Something went wrong (%d). Please try again.") % code
	return _answer(false, code, data, text)

static func _answer(ok: bool, code: int, body: Dictionary, error: String) -> Dictionary:
	return {"ok": ok, "code": code, "body": body, "error": error, "maintenance": false}
