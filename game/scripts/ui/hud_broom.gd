extends PanelContainer
class_name HudBroom

## The broom flight panel (the old HUD's mounted panel), bottom right over
## the taskbar while the player rides: the controls (their bound keys), the
## height over the ground and the speed, and whether a dismount here would
## land - live, by the server's own rule (RealmSession.landing: level ground
## within 3.1 m under the feet), "Cannot land here" in red when Shift would
## be refused.

const OK_COLOUR := Color(0.55, 0.9, 0.5)
const BLOCKED := Color(1.0, 0.42, 0.36)

## RealmSession.
var session: Node
## What the check reads: the landing line shown last, and how many times it
## turned to "Cannot land here".
var landing_text := ""
var blocked_shown := 0

var _controls: Label
var _flight: Label
var _landing: Label
var _was_blocked := false

func _init() -> void:
	name = "BroomPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _ready() -> void:
	add_theme_stylebox_override("panel", HudKit.panel(0.8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	var title := HudKit.label(tr("Broom Flight"), 15, HudKit.GOLD_HI, HudKit.title(), 3)
	v.add_child(title)
	_controls = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 2)
	v.add_child(_controls)
	_flight = HudKit.label("", 13, HudKit.PARCHMENT, HudKit.body(), 2)
	v.add_child(_flight)
	_landing = HudKit.label("", 13, OK_COLOUR, HudKit.bold(), 2)
	v.add_child(_landing)
	# a point at the bottom right the panel grows up and left from
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = -16.0
	offset_right = -16.0
	offset_top = -(14.0 + 12.0 + HudActionBar.SLOT + 40.0)
	offset_bottom = offset_top

## Every frame (MapTravel.tick).
func tick() -> void:
	var body: Dictionary = session.own_body()
	if not bool(body.get("mounted", false)):
		if visible:
			hide()
		_was_blocked = false
		landing_text = ""
		return
	var land: Dictionary = session.landing()
	var velocity: Vector3 = body.get("velocity", Vector3.ZERO)
	var height := float(land.get("height", -1.0))
	_controls.text = tr("%s rise · %s descend · %s dismount") % [
		GameSettings.key_name("jump"), GameSettings.key_name("descend"), GameSettings.key_name("ride")]
	_flight.text = tr("Height %s · speed %s m/s") % [
		(tr("%s m") % I18n.num(height)) if height >= 0.0 else "—", I18n.num(Vector2(velocity.x, velocity.z).length())]
	var blocked := not bool(land.get("ok", false))
	if blocked:
		landing_text = tr("Cannot land here: descend near level ground (%s)") % GameSettings.key_name("descend")
		if not _was_blocked:
			blocked_shown += 1
	else:
		landing_text = tr("Landing here: OK (%s to dismount)") % GameSettings.key_name("ride")
	_was_blocked = blocked
	_landing.text = landing_text
	_landing.add_theme_color_override("font_color", BLOCKED if blocked else OK_COLOUR)
	if not visible:
		show()
