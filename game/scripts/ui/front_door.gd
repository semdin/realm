extends Node
class_name FrontDoor

## The game's front door: the login card (LoginScreen), then the character
## screen (CharacterSelect), then the world. main.gd shows it when the game
## starts without `--character` (and without a check that needs the dev
## join); `--login-url` names the login service (LoginApi.DEFAULT_URL).
##
## Entering the world asks the service for a ticket (/api/play) and hands
## it to RealmSession.join_ticket: the loading screen comes up and the scene
## is rebuilt, and main.gd joins the character's map with start_travel as it
## does after a trip. A refused play (the realm in maintenance) stays here
## with the reason. The world's end screen comes back here through
## main.gd's return_to_login (`return_kind` says why, shown on the card).

signal entering_world(map: String)

## Why the world sent the player back (MaintenanceUI's screen kind and its
## text), read once by the next front door.
static var return_kind := ""
static var return_detail := ""

var api: LoginApi
var login: LoginScreen
var select: CharacterSelect
var _login_layer: CanvasLayer

func setup(login_url: String) -> void:
	name = "FrontDoor"
	api = LoginApi.new(login_url)
	add_child(api)
	# a session from before (the world sent the player back) ends here: the
	# card asks for the password again
	if api.signed_in():
		api.logout()
	_login_layer = CanvasLayer.new()
	_login_layer.name = "LoginLayer"
	_login_layer.layer = 10
	add_child(_login_layer)
	login = LoginScreen.new()
	login.setup(api)
	_login_layer.add_child(login)
	login.signed_in.connect(_show_select)
	if return_kind != "":
		login.show_return_notice.call_deferred(return_kind, return_detail)
		return_kind = ""
		return_detail = ""

func login_visible() -> bool:
	return login != null and _login_layer.visible

func _show_select() -> void:
	_login_layer.visible = false
	select = CharacterSelect.new()
	select.setup(api)
	add_child(select)
	select.logged_out.connect(_back_to_login)
	select.play_granted.connect(_enter_world)

func _back_to_login() -> void:
	if select != null:
		select.queue_free()
		select = null
	_login_layer.visible = true
	login.set_status(tr("You have logged out."), "info")

## The ticket came: the loading screen covers the change, and the scene is
## rebuilt to join `map` (main.gd sees the pending join).
func _enter_world(map: String, address: String, ticket: String) -> void:
	if not ClassDB.class_call_static("RealmSession", "join_ticket", map, address, ticket):
		select.play_failed(tr("The login server sent a ticket this client cannot read."))
		return
	entering_world.emit(map)
	var screen := MapLoadingScreen.shared(get_tree())
	await screen.open(I18n.upper(TravelData.display_name(map)), tr("Entering the realm…"))
	screen.set_progress(20.0, tr("Entering the realm…"))
	get_tree().reload_current_scene()

## ================================================================ shared look

## The night behind the front door, darkened by `light` (1 = full): a deep
## indigo sky with a warm glow low in the middle, where the embers rise.
## (The old client's banner showed a castle and riders too close to another
## world's; new key art comes with the Phase 6 art pass.)
static func backdrop(light: float) -> TextureRect:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	gradient.colors = PackedColorArray([
		Color(0.20, 0.11, 0.17) * light,
		Color(0.07, 0.06, 0.13) * light,
		Color(0.015, 0.02, 0.04),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 512
	tex.height = 512
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.78)
	tex.fill_to = Vector2(1.15, 0.0)
	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = tex
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bg

static func gradient_rect(node_name: String, stops: Array, vertical: bool) -> TextureRect:
	var offsets := PackedFloat32Array()
	var colours := PackedColorArray()
	for stop in stops:
		offsets.append(float(stop[0]))
		colours.append(stop[1])
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colours
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 8 if vertical else 512
	tex.height = 512 if vertical else 8
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = tex
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

## Slow embers drifting up from the bottom edge of `host` - the key art's
## own sparks.
static func embers(host: Control) -> Node:
	var e := CPUParticles2D.new()
	e.name = "Embers"
	if DisplayServer.get_name() == "headless":
		e.emitting = false
		return e
	e.amount = 46
	e.lifetime = 9.0
	e.preprocess = 9.0
	e.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	e.emission_rect_extents = Vector2(900, 10)
	e.position = Vector2(800, 940)
	e.direction = Vector2(0, -1)
	e.spread = 18.0
	e.gravity = Vector2(0, -6)
	e.initial_velocity_min = 18.0
	e.initial_velocity_max = 46.0
	e.scale_amount_min = 1.2
	e.scale_amount_max = 3.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.62, 0.25, 0.0))
	ramp.set_color(1, Color(1.0, 0.45, 0.15, 0.0))
	ramp.add_point(0.15, Color(1.0, 0.7, 0.3, 0.85))
	ramp.add_point(0.7, Color(1.0, 0.5, 0.2, 0.5))
	e.color_ramp = ramp
	host.resized.connect(func(): e.position = Vector2(host.size.x * 0.5, host.size.y + 40.0))
	return e

## A gold rule with a diamond at its centre.
static func ornament() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0, 18)
	for i in 3:
		if i == 1:
			var gem := Panel.new()
			var gs := StyleBoxFlat.new()
			gs.bg_color = UITheme.c("gold_lt")
			gs.set_corner_radius_all(1)
			gem.add_theme_stylebox_override("panel", gs)
			gem.custom_minimum_size = Vector2(8, 8)
			gem.rotation_degrees = 45.0
			gem.pivot_offset = Vector2(4, 4)
			gem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(gem)
		else:
			var line := Panel.new()
			var ls := StyleBoxFlat.new()
			ls.bg_color = UITheme.alpha("gold", 0.8)
			line.add_theme_stylebox_override("panel", ls)
			line.custom_minimum_size = Vector2(120, 1)
			line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(line)
	return row

static func line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 44)
	edit.add_theme_font_size_override("font_size", 17)
	edit.add_theme_color_override("font_color", UITheme.c("parchment"))
	edit.add_theme_color_override("font_placeholder_color", UITheme.alpha("text_dim", 0.6))
	edit.add_theme_color_override("caret_color", UITheme.c("gold_hi"))
	edit.add_theme_color_override("selection_color", UITheme.alpha("gold", 0.45))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.02, 0.027, 0.043, 0.92)
	normal.border_color = UITheme.c("steel_lt")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = UITheme.c("gold_lt")
	focus.shadow_color = UITheme.alpha("gold", 0.25)
	focus.shadow_size = 6
	var read_only := normal.duplicate() as StyleBoxFlat
	read_only.bg_color = Color(0.05, 0.055, 0.07, 0.8)
	edit.add_theme_stylebox_override("normal", normal)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_stylebox_override("read_only", read_only)
	return edit

## The big blood-red button with the gold rim (Enter Game, Create Account).
static func primary_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_override("font", UITheme.font_title())
	b.add_theme_font_size_override("font_size", 19)
	b.add_theme_color_override("font_color", UITheme.c("gold_hi"))
	b.add_theme_color_override("font_hover_color", Color(1, 0.97, 0.86))
	b.add_theme_color_override("font_pressed_color", UITheme.c("gold_lt"))
	b.add_theme_color_override("font_disabled_color", UITheme.alpha("text_dim", 0.7))
	b.add_theme_color_override("font_outline_color", Color(0.1, 0.02, 0.02))
	b.add_theme_constant_override("outline_size", UITheme.outline_for(19, 4))
	var normal := StyleBoxFlat.new()
	normal.bg_color = UITheme.c("blood")
	normal.border_color = UITheme.c("gold")
	normal.set_border_width_all(1)
	normal.border_width_top = 2
	normal.set_corner_radius_all(6)
	normal.shadow_color = Color(0, 0, 0, 0.45)
	normal.shadow_size = 6
	normal.shadow_offset = Vector2(0, 3)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = UITheme.c("blood_lt")
	hover.border_color = UITheme.c("gold_lt")
	hover.shadow_color = UITheme.alpha("gold", 0.3)
	hover.shadow_size = 10
	hover.shadow_offset = Vector2.ZERO
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = UITheme.c("blood_dk")
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.13, 0.12, 0.13)
	disabled.border_color = UITheme.c("steel_lt")
	disabled.shadow_size = 0
	var focus := normal.duplicate() as StyleBoxFlat
	focus.draw_center = false
	focus.border_color = UITheme.c("gold_hi")
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", focus)
	return b

## The rounded dark pill (server status, language).
static func pill_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.06, 0.78)
	sb.border_color = UITheme.alpha("gold_dk", 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 14
	sb.content_margin_right = 16
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb

## The houses (content/data/houses.json) in a fixed order: [key, entry].
static func houses() -> Array:
	var table: Variant = RealmContent.table("houses")
	var out: Array = []
	if table is Dictionary:
		var keys: Array = (table as Dictionary).keys()
		keys.sort()
		for key: String in ["velkar", "nisera", "ilvane", "torvan"]:
			if (table as Dictionary).has(key):
				out.append([key, table[key]])
				keys.erase(key)
		for key: String in keys:
			if not key.begins_with("_"):
				out.append([key, table[key]])
	return out

static func house_entry(key: String) -> Dictionary:
	var table: Variant = RealmContent.table("houses")
	if table is Dictionary and (table as Dictionary).has(key):
		return table[key]
	return {}

static func house_color(key: String) -> Color:
	return Color.html(String(house_entry(key).get("primary_color", "#8b8f96")))

static func house_name(key: String) -> String:
	return I18n.t(String(house_entry(key).get("name", key.capitalize())))
