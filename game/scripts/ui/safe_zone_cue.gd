extends HBoxContainer
class_name SafeZoneCue

## Protected ground on screen (the old game's safe-area row): while the
## player stands in a safe zone (SafeZones, the rule the server enforces:
## nobody takes or deals damage there) a shield and "Safe area · Combat
## disabled" sit over the taskbar ("Duel in progress" while a duel goes on
## there: the foes agreed to it). Stepping in lights the row, silently (a
## chime at every gate and square was noise); stepping out leaves it a moment
## in amber, "Leaving protected ground", with a soft sound: combat is possible
## again. (Not on the notice band: entering a safe zone is mostly entering a
## named place, whose banner stands there at the same moment.)

## The zone is looked up this often (seconds), and how long the leaving
## line stays.
const POLL := 0.25
const LEAVING_SECONDS := 2.5
const SAFE := Color(0.6, 0.95, 0.6)
const LEAVING := Color(1.0, 0.72, 0.36)

## main.gd (session, map_name, hud).
var game: Node
## The zone the player is in ("" none), and the crossings seen (the check
## reads them: "in:courtyard", "out:courtyard").
var zone := ""
var crossings: Array = []
var _label: Label
var _icon: TextureRect
var _wait := 0.0
var _known := false
var _leaving_until := 0.0

func _init() -> void:
	name = "SafeZoneCue"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 5)
	visible = false

func _ready() -> void:
	_icon = TextureRect.new()
	_icon.texture = UITheme.chrome_at("ui_safe_zone", 18.0)
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon)
	_label = HudKit.label("", 14, SAFE, HudKit.bold(), 4)
	add_child(_label)
	# centred over the taskbar, under the notices
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	var y := -14.0 - 12.0 - HudActionBar.SLOT - 52.0
	offset_left = -160.0
	offset_right = 160.0
	offset_top = y
	offset_bottom = y + 22.0

func _process(delta: float) -> void:
	if game == null or game.session == null or not game.built:
		return
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = POLL
	var now := Time.get_ticks_msec() / 1000.0
	var here := SafeZones.zone_at(String(game.map_name), game.session.own_position())
	if here != zone:
		if _known:
			if here != "":
				crossings.append("in:" + here)
				_leaving_until = 0.0
			else:
				crossings.append("out:" + zone)
				_leaving_until = now + LEAVING_SECONDS
				AudioManager.play_sound_at("ui_close", Vector3.ZERO, null, true)
		zone = here
	_known = true
	visible = zone != "" or now < _leaving_until
	if zone != "":
		var duel: bool = game.hud.duel_view.active()
		_label.text = tr("Safe area · Duel in progress") if duel else tr("Safe area · Combat disabled")
		_label.add_theme_color_override("font_color", SAFE)
		_icon.modulate = Color.WHITE
	elif visible:
		_label.text = tr("Leaving protected ground - combat is possible")
		_label.add_theme_color_override("font_color", LEAVING)
		_icon.modulate = Color(1.0, 0.7, 0.4, 0.8)
