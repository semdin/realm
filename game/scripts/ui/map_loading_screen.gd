extends CanvasLayer
class_name MapLoadingScreen

## The loading screen of a map transfer (the castle door, a hearth to another
## map, a Waylink): the dark frame, the realm's emblem, the gold bar, a tip and
## the turning rune, so stepping through a door looks like part of the game
## rather than a black flash, and the bar says what is happening: leaving the
## old map, joining the new one, building it.
##
## A trip to another map rebuilds the whole scene (main.gd reloads it for the
## new map's session), so the one screen lives on the scene tree's root, not
## in the scene: `shared()` finds it (or makes it) and it stays up across the
## reload until the new scene has joined and drawn its map.
##
##   await MapLoadingScreen.shared(tree).open("KAF CASTLE", "Entering Kaf Castle...")
##   MapLoadingScreen.shared(tree).set_progress(40.0, "Waiting for the server…")
##   await MapLoadingScreen.shared(tree).close()

const ART := "res://assets/branding/thousand_realms_logo.png"
const FADE := 0.25
## Never flash: once shown, the screen stays at least this long.
const MIN_SHOW := 0.8
# i18n-begin
const TIPS := [
	"Start a chat line with ! to shout to everyone in the realm.",
	"Drag a potion from your bag onto a quick slot to drink it with one key.",
	"Shardglass Ward reflects projectiles back at their caster.",
	"Saltwights are dry as tinder: Flame Wave burns them for double damage.",
	"Hold the right mouse button to turn the camera; the wheel zooms.",
	"Land on level ground before you dismount your broom.",
	"Dark Shards summon waves of creatures - bring friends.",
	"Kestrin can refine your wand. Higher tiers glow brighter.",
]
# i18n-end

## No word from the loading for this long: the way back appears.
const STUCK_SECONDS := 45.0

var _root: Control
var _stuck_row: Control
var _progress_at := 0
var _title: Label
var _bar: ProgressBar
var _status: Label
var _tip: Label
var _target := 0.0
var _shown_at := 0
var _fading := 0.0     # +1 fading in, -1 fading out, 0 still
## How many times it was opened and closed, and the texts it showed (checks).
var opened := 0
var closed_count := 0
var last_title := ""
var last_status := ""
var last_notice := ""

## The one loading screen, on the root of `tree` (it outlives a scene reload).
static func shared(tree: SceneTree) -> MapLoadingScreen:
	var found := tree.root.get_node_or_null("MapLoadingScreen") as MapLoadingScreen
	if found == null:
		found = MapLoadingScreen.new()
		found.name = "MapLoadingScreen"
		tree.root.add_child(found)
	return found

func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.modulate.a = 0.0
	_root.visible = false
	add_child(_root)
	var black := ColorRect.new()
	black.color = Color(0.01, 0.012, 0.02)
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(black)
	if ResourceLoader.exists(ART):
		var art := TextureRect.new()
		art.texture = load(ART)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		art.offset_left = -260
		art.offset_right = 260
		art.offset_top = -300
		art.offset_bottom = 60
		art.modulate = Color(0.82, 0.8, 0.86)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(art)
	var shade := ShadeRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_title = HudKit.label("", 52, HudKit.GOLD_HI, HudKit.deco(), 10)
	_title.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_title.offset_left = -560
	_title.offset_right = 560
	_title.offset_top = -220
	_title.offset_bottom = -150
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_outline_color", Color(0.1, 0.06, 0.02, 0.95))
	_root.add_child(_title)
	_bar = ProgressBar.new()
	_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.offset_left = -360
	_bar.offset_right = 360
	_bar.offset_top = -132
	_bar.offset_bottom = -118
	_bar.min_value = 0
	_bar.max_value = 100
	_bar.show_percentage = false
	HudKit.style_gauge(_bar, Color(0.9, 0.68, 0.2))
	_root.add_child(_bar)
	_status = HudKit.label("", 16, HudKit.PARCHMENT, HudKit.title(), 4)
	_status.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_status.offset_left = -360
	_status.offset_right = 360
	_status.offset_top = -112
	_status.offset_bottom = -90
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_status)
	_tip = HudKit.label("", 16, HudKit.TEXT, HudKit.body(), 4)
	_tip.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_tip.offset_left = -520
	_tip.offset_right = 520
	_tip.offset_top = -70
	_tip.offset_bottom = -40
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_tip)
	_build_stuck_row()
	var rune := Spinner.new()
	rune.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	rune.offset_left = -92
	rune.offset_top = -92
	rune.offset_right = -36
	rune.offset_bottom = -36
	_root.add_child(rune)

## A loading that stopped moving must not be the end of the game: a line and a
## button back to the login card (hidden until it is needed).
func _build_stuck_row() -> void:
	var row := VBoxContainer.new()
	row.name = "StuckRow"
	row.add_theme_constant_override("separation", 8)
	row.set_anchors_preset(Control.PRESET_CENTER_TOP)
	row.offset_left = -300
	row.offset_right = 300
	row.offset_top = 24
	row.visible = false
	_stuck_row = row
	_root.add_child(row)
	var line := HudKit.label(tr("This is taking longer than it should."), 16, HudKit.GOLD_HI, HudKit.body(), 4)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(line)
	var back := HudKit.button(tr("Return to Login"), 15)
	back.name = "BackToLogin"
	back.custom_minimum_size = Vector2(190, 36)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(_give_up)
	row.add_child(back)

func _give_up() -> void:
	var game := get_tree().current_scene
	dismiss()
	if game != null and game.has_method("return_to_login"):
		game.call("return_to_login", "refused", tr("Loading took too long and was stopped. Please log in again."))

func is_open() -> bool:
	return _root != null and _root.visible

## Fully up (faded in, not fading out).
func is_covering() -> bool:
	return is_open() and _root.modulate.a >= 1.0 and _fading >= 0.0

## Show the screen (fades in; awaitable). The world behind keeps running.
func open(title: String, status: String) -> void:
	_title.text = title
	_status.text = status
	last_title = title
	last_status = status
	opened += 1
	_tip.text = tr("Tip: %s") % tr(String(TIPS[randi() % TIPS.size()]))
	_tip.add_theme_color_override("font_color", HudKit.TEXT)
	last_notice = ""
	_target = 5.0
	_bar.value = 0.0
	_root.visible = true
	_shown_at = Time.get_ticks_msec()
	_progress_at = _shown_at
	_stuck_row.visible = false
	_fading = 1.0
	while _root.modulate.a < 1.0 and is_inside_tree():
		await get_tree().process_frame

func set_progress(percent: float, status: String = "") -> void:
	if percent > _target or (status != "" and status != _status.text):
		_progress_at = Time.get_ticks_msec()
		_stuck_row.visible = false
	_target = maxf(_target, clampf(percent, 0.0, 100.0))
	if status != "":
		_status.text = status
		last_status = status

## Something the player should know about this wait: it takes the tip's place,
## in the bar's colour, until the screen is opened again.
func set_notice(text: String) -> void:
	last_notice = text
	_tip.text = text
	_tip.add_theme_color_override("font_color", HudKit.GOLD_HI)

## Fill the bar, respect the minimum show time, fade out (awaitable).
func close() -> void:
	set_progress(100.0)
	while Time.get_ticks_msec() - _shown_at < int(MIN_SHOW * 1000.0) and is_inside_tree():
		await get_tree().process_frame
	_fading = -1.0
	closed_count += 1
	while _root.visible and is_inside_tree():
		await get_tree().process_frame

## Gone at once, no fade (back to the login card: the card must not sit
## under a screen nothing will lift).
func dismiss() -> void:
	if _root == null or not _root.visible:
		return
	_fading = 0.0
	_root.modulate.a = 0.0
	_root.visible = false
	closed_count += 1

func _process(delta: float) -> void:
	if _root == null or not _root.visible:
		return
	_bar.value = lerpf(_bar.value, _target, minf(1.0, delta * 8.0))
	if not _stuck_row.visible and _fading >= 0.0 and Time.get_ticks_msec() - _progress_at > int(STUCK_SECONDS * 1000.0):
		_stuck_row.visible = true
	if _fading != 0.0:
		_root.modulate.a = clampf(_root.modulate.a + _fading * delta / FADE, 0.0, 1.0)
		if _fading > 0.0 and _root.modulate.a >= 1.0:
			_fading = 0.0
		elif _fading < 0.0 and _root.modulate.a <= 0.0:
			_fading = 0.0
			_root.visible = false

## The lower half darkens toward the bar and the tip.
class ShadeRect extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var top := Color(0, 0, 0, 0.0)
		var bottom := Color(0.0, 0.0, 0.02, 0.88)
		var y0 := size.y * 0.45
		draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(size.x, y0), Vector2(size.x, size.y), Vector2(0, size.y)]),
			PackedColorArray([top, top, bottom, bottom]))

## The turning rune in the corner.
class Spinner extends Control:
	var _a := 0.0
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _process(delta: float) -> void:
		_a += delta * 2.4
		queue_redraw()
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.42
		draw_arc(c, r, 0, TAU, 48, Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.25), 2.0, true)
		draw_arc(c, r, _a, _a + 1.6, 24, HudKit.GOLD_HI, 3.0, true)
		draw_arc(c, r * 0.6, -_a * 1.3, -_a * 1.3 + 1.1, 18, HudKit.GOLD, 2.0, true)
