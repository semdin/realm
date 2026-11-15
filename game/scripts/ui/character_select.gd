extends Node3D
class_name CharacterSelect

## The character screen (the old client's character select): the key art
## behind a dark stone dais lit in the house colour, the character standing
## on it in the real hero body (HeroAppearance, the same body, look and
## house tint the world draws), the roster of the account's two slots on
## the left, the chosen character's card on the right, one big Enter World
## button. Left / Right (or A / D, or the arrows beside the dais) turn the
## dais to the other slot, Enter enters; right-drag on the stage turns the
## character and swings the camera, the wheel moves in to the face.
##
## The empty slot's card opens the create card: a name, the four houses
## (content/data/houses.json, crest, name, motto and trait) and the look
## editor (LookEditor) on the left, every change drawn live on the dais.
## Create sends name, house and look to the login service, which cleans the
## look; Enter World asks it for the ticket (FrontDoor joins with it).
##
## Edit Appearance (over Enter World) opens the same look editor for the
## chosen character with Save and Cancel; the dais shows the new look at
## once. The login service only creates, so the edit is kept here and sent
## as the character enters the world (main.gd: RealmSession.set_look, which
## the server cleans and saves); until then the roster shows it too.
##
## Everything comes from the login service (LoginApi): the roster is
## fetched when the screen opens; nothing is cached on disk.

signal logged_out
signal play_granted(map: String, address: String, ticket: String)

const MAX_CHARACTERS := 2
const DEFAULT_CLOAK := "cloak_wool"
const DEFAULT_WAND := "wand_ashwood"
## The camera's swing over (+) or under (-) the character, radians.
const PITCH_MIN := -0.25
const PITCH_MAX := 0.7
const COLOR_ERROR := Color(0.96, 0.47, 0.42)
const COLOR_WARN := Color(1.0, 0.74, 0.36)

var api: LoginApi
## The roster as the service sent it: {id, name, house, level, map, look}.
var characters: Array = []
## The roster has arrived (the checks wait for it).
var roster_loaded := false
var current_slot := 0
var selected_house := "velkar"
var is_switching := false
var creating := false
## The look editor is open on an existing character (Edit Appearance).
var editing := false

## Looks edited here and not yet in the world: character id -> look. Kept
## across the scene's reloads (Change character comes back here).
static var pending_looks: Dictionary = {}
## The edited look of the character entering the world now: main.gd sends it
## once the session has a sheet, then clears it.
static var look_on_entry: Dictionary = {}

var camera: Camera3D
var podium: Node3D
var podium_light: OmniLight3D
var rune_ring: MeshInstance3D
var model_anchor: Node3D
var embers: CPUParticles3D
var rim_light: DirectionalLight3D
## The character on the dais (HeroAppearance.spawn), null on an empty slot.
var current_body: Node3D

var canvas: CanvasLayer
var slot_label: Label
var logout_btn: Button
var roster_panel: PanelContainer
var roster: VBoxContainer
var roster_title: Label
## One card per slot (the roster's buttons, in slot order).
var roster_cards: Array = []
var info_card: PanelContainer
var crest: TextureRect
var name_label: Label
var house_label: Label
var level_label: Label
var place_label: Label
var motto_label: Label
var nav: HBoxContainer
var prev_btn: Button
var next_btn: Button
var bottom: VBoxContainer
var enter_btn: Button
var edit_btn: Button
var status_label: Label

var create_modal: PanelContainer
var name_input: LineEdit
## house key -> Button
var house_buttons := {}
var house_desc: Label
var modal_status: Label
var confirm_btn: Button
var cancel_btn: Button
var look_editor: LookEditor

var _drag_turn := false
var _zoom := 0.0
var _zoom_target := 0.0
var _camera_far := Transform3D()
var _pitch := 0.0
var _pitch_target := 0.0

func setup(p_api: LoginApi) -> void:
	api = p_api

func _ready() -> void:
	name = "CharacterSelect"
	_build_stage()
	_build_ui()
	_build_create_modal()
	_build_look_editor()
	_select_house("velkar")
	get_viewport().size_changed.connect(_layout)
	_layout()
	_update_slot_display()
	_load_characters()

## ================================================================ the stage

## A canvas-background environment is drawn by every viewport of its world
## that draws 2D, not only the screen's: each tooltip and popup menu (a
## Window) ran it as an empty 3D scene at its own pixel size, through ACES
## and glow. Under 64 px (a swatch's "#ffffff" tooltip is 60 x 27) the
## Mobile renderer's glow walks past the end of its mip chain ("Index
## p_mipmap = 4 is out of bounds", "framebuffer is null", "uniform_set is
## null", every frame it shows; Godot 4.7.2). The UI windows never need the
## stage's environment, so theirs is off: they draw plain 2D, as the world's
## do.
func _windows_without_environment() -> void:
	var tree := get_tree()
	var pending: Array[Node] = [tree.root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node != tree.root:
			_environment_off(node)
		pending.append_array(node.get_children(true))
	if not tree.node_added.is_connected(_environment_off):
		tree.node_added.connect(_environment_off)

func _environment_off(node: Node) -> void:
	if node is Window:
		RenderingServer.viewport_set_environment_mode((node as Window).get_viewport_rid(), RenderingServer.VIEWPORT_ENVIRONMENT_DISABLED)

func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_environment_off):
		tree.node_added.disconnect(_environment_off)

func _build_stage() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	# the key art (a canvas layer behind) shows where nothing is drawn
	env.background_mode = Environment.BG_CANVAS
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.2, 0.22, 0.3)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.6
	# the world's low bloom: more washed the skin in an orange haze
	env.glow_bloom = 0.04
	env_node.environment = env
	add_child(env_node)
	_windows_without_environment()
	var back := CanvasLayer.new()
	back.layer = -1
	add_child(back)
	back.add_child(FrontDoor.backdrop(0.42))
	var vignette := ColorRect.new()
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.color = Color(0.0, 0.0, 0.02, 0.35)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.add_child(vignette)

	camera = Camera3D.new()
	camera.transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0.985, -0.174), Vector3(0, 0.174, 0.985)), Vector3(0, 1.45, 3.6))
	camera.fov = 62.0
	add_child(camera)
	camera.make_current()

	podium = Node3D.new()
	podium.name = "Podium"
	add_child(podium)
	# the dais: dark dressed stone, a slim glowing rune ring
	var dais := MeshInstance3D.new()
	dais.name = "PodiumMesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.35
	cyl.bottom_radius = 1.48
	cyl.height = 0.5
	cyl.radial_segments = 64
	dais.mesh = cyl
	var stone := StandardMaterial3D.new()
	var noise := FastNoiseLite.new()
	noise.frequency = 0.035
	noise.fractal_octaves = 5
	var grain := NoiseTexture2D.new()
	grain.width = 512
	grain.height = 512
	grain.seamless = true
	grain.noise = noise
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.55, 0.53, 0.58))
	ramp.set_color(1, Color(1.0, 0.98, 1.0))
	grain.color_ramp = ramp
	stone.albedo_texture = grain
	stone.uv1_triplanar = true
	stone.uv1_scale = Vector3(0.6, 0.6, 0.6)
	# darker: the key light that models the face also falls on the dais
	stone.albedo_color = Color(0.11, 0.105, 0.125)
	stone.roughness = 0.9
	dais.material_override = stone
	podium.add_child(dais)
	rune_ring = MeshInstance3D.new()
	rune_ring.name = "RuneRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 1.22
	torus.outer_radius = 1.27
	torus.rings = 96
	rune_ring.mesh = torus
	rune_ring.position.y = 0.26
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.emission_enabled = true
	glow.emission_energy_multiplier = 1.4
	rune_ring.material_override = glow
	podium.add_child(rune_ring)
	podium_light = OmniLight3D.new()
	podium_light.name = "PodiumLight"
	podium_light.position.y = 0.4
	# on the dais and the boots: reaching up from below it painted the
	# eyelids, nostrils and jaw
	podium_light.omni_range = 0.9
	podium_light.light_energy = 1.8
	podium.add_child(podium_light)
	embers = CPUParticles3D.new()
	embers.name = "EmbersParticles"
	embers.position.y = 0.3
	embers.amount = 25
	embers.lifetime = 2.0
	var spark := SphereMesh.new()
	spark.radius = 0.025
	spark.height = 0.05
	# amber sparks whatever the house (the key art's own embers)
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.albedo_color = Color(1.0, 0.75, 0.3, 0.8)
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark.material = spark_mat
	embers.mesh = spark
	embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	embers.emission_sphere_radius = 1.2
	embers.gravity = Vector3(0, 0.8, 0)
	embers.scale_amount_min = 0.5
	embers.scale_amount_max = 1.3
	podium.add_child(embers)
	model_anchor = Node3D.new()
	model_anchor.name = "ModelAnchor"
	model_anchor.position.y = 0.25
	podium.add_child(model_anchor)
	_stage_lights()

## The portrait lighting: a warm key from the camera's left, high and in
## front (the one shadow), a cool fill from the right and a rim from behind
## in a pale wash of the house colour that draws the outline off the dark
## backdrop.
func _stage_lights() -> void:
	var target := Vector3(0, 1.4, 0)
	var key := DirectionalLight3D.new()
	key.name = "KeyLight"
	add_child(key)
	key.look_at_from_position(Vector3(-2.0, 3.0, 2.8), target)
	key.light_color = Color(1.0, 0.94, 0.86)
	key.light_energy = 1.5
	key.shadow_enabled = true
	key.shadow_blur = 1.5
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key.directional_shadow_max_distance = 8.0
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	add_child(fill)
	fill.look_at_from_position(Vector3(2.8, 1.5, 2.2), target)
	fill.light_color = Color(0.72, 0.8, 1.0)
	fill.light_energy = 0.35
	rim_light = DirectionalLight3D.new()
	rim_light.name = "RimLight"
	add_child(rim_light)
	rim_light.look_at_from_position(Vector3(-0.3, 3.0, -3.0), target)
	rim_light.light_color = Color(0.78, 0.84, 1.0)
	rim_light.light_energy = 1.2
	# grazing from behind, its highlight burnt white patches on the hair
	rim_light.light_specular = 0.15

func _apply_rune_color(col: Color) -> void:
	podium_light.light_color = col
	rim_light.light_color = Color(0.78, 0.84, 1.0).lerp(col.lightened(0.45), 0.35)
	var mat := rune_ring.material_override as StandardMaterial3D
	mat.albedo_color = col
	mat.emission = col

## ================================================================ the interface

func _build_ui() -> void:
	canvas = CanvasLayer.new()
	canvas.name = "SelectUI"
	canvas.layer = 10
	add_child(canvas)
	var root := Control.new()
	root.name = "Root"
	root.theme = UITheme.get_theme()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root)

	# --- top: the logo, the slot and Log Out
	var logo := UITheme.logo(84.0)
	logo.position = Vector2(30, 10)
	root.add_child(logo)
	var top := HBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	top.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	top.offset_top = 26
	top.offset_right = -30
	top.add_theme_constant_override("separation", 20)
	root.add_child(top)
	slot_label = HudKit.label("", 16, HudKit.PARCHMENT, HudKit.title(), 4)
	slot_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(slot_label)
	logout_btn = HudKit.button(tr("Log Out"), 15)
	logout_btn.name = "LogoutButton"
	logout_btn.custom_minimum_size = Vector2(130, 40)
	logout_btn.pressed.connect(_on_logout_pressed)
	top.add_child(logout_btn)

	# --- the roster on the left
	roster_panel = PanelContainer.new()
	roster_panel.name = "Roster"
	var roster_box := HudKit.panel(0.82, 8).duplicate() as StyleBoxFlat
	roster_box.set_content_margin_all(14)
	roster_panel.add_theme_stylebox_override("panel", roster_box)
	root.add_child(roster_panel)
	roster = VBoxContainer.new()
	roster.add_theme_constant_override("separation", 10)
	roster_panel.add_child(roster)
	roster_title = HudKit.label("", 15, HudKit.GOLD, HudKit.title(), 3)
	roster.add_child(roster_title)

	# --- the chosen character's card on the right
	info_card = PanelContainer.new()
	info_card.name = "InfoCard"
	var info_box := HudKit.panel(0.82, 8).duplicate() as StyleBoxFlat
	info_box.set_content_margin_all(18)
	info_card.add_theme_stylebox_override("panel", info_box)
	root.add_child(info_card)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	info_card.add_child(vbox)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vbox.add_child(head)
	crest = TextureRect.new()
	crest.custom_minimum_size = Vector2(56, 56)
	crest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	crest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(crest)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	name_label = HudKit.label("", 30, HudKit.GOLD_HI, HudKit.deco(), 6)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	names.add_child(name_label)
	house_label = HudKit.label("", 16, HudKit.PARCHMENT, HudKit.title(), 3)
	names.add_child(house_label)
	var rule := ColorRect.new()
	rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.45)
	rule.custom_minimum_size = Vector2(0, 1)
	vbox.add_child(rule)
	level_label = HudKit.label("", 16, HudKit.TEXT, HudKit.body(), 2)
	vbox.add_child(level_label)
	place_label = HudKit.label("", 16, HudKit.TEXT, HudKit.body(), 2)
	vbox.add_child(place_label)
	motto_label = HudKit.label("", 14, HudKit.TEXT_DIM, HudKit.body(), 2)
	motto_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(motto_label)

	# --- the slot arrows beside the dais
	nav = HBoxContainer.new()
	nav.set_anchors_preset(Control.PRESET_CENTER)
	nav.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(nav)
	prev_btn = HudKit.button("◄", 20)
	prev_btn.custom_minimum_size = Vector2(52, 52)
	prev_btn.pressed.connect(func(): _switch_slot((current_slot - 1 + MAX_CHARACTERS) % MAX_CHARACTERS))
	nav.add_child(prev_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav.add_child(spacer)
	next_btn = HudKit.button("►", 20)
	next_btn.custom_minimum_size = Vector2(52, 52)
	next_btn.pressed.connect(func(): _switch_slot((current_slot + 1) % MAX_CHARACTERS))
	nav.add_child(next_btn)

	# --- Enter World: one big gold button, bottom centre, a status line under it
	bottom = VBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.offset_left = -260
	bottom.offset_right = 260
	bottom.offset_bottom = -26
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 8)
	root.add_child(bottom)
	edit_btn = HudKit.button(tr("Edit Appearance"), 15)
	edit_btn.name = "EditLookButton"
	edit_btn.custom_minimum_size = Vector2(220, 38)
	edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	edit_btn.pressed.connect(open_edit)
	bottom.add_child(edit_btn)
	enter_btn = HudKit.button(tr("ENTER WORLD"), 22)
	enter_btn.name = "EnterWorldButton"
	for state in ["normal", "hover", "pressed"]:
		var sb := HudKit.button_box(state).duplicate() as StyleBoxFlat
		sb.bg_color = Color(0.36, 0.25, 0.08) if state == "normal" else (Color(0.48, 0.34, 0.1) if state == "hover" else Color(0.26, 0.18, 0.06))
		sb.border_color = HudKit.GOLD_HI if state == "hover" else HudKit.GOLD_LT
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.shadow_color = Color(0, 0, 0, 0.5)
		sb.shadow_size = 8
		enter_btn.add_theme_stylebox_override(state, sb)
	enter_btn.add_theme_font_override("font", HudKit.title())
	enter_btn.add_theme_color_override("font_color", HudKit.GOLD_HI)
	enter_btn.custom_minimum_size = Vector2(380, 60)
	enter_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	enter_btn.pressed.connect(_on_enter_world_pressed)
	bottom.add_child(enter_btn)
	status_label = HudKit.label("", 15, HudKit.TEXT, HudKit.body(), 3)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(520, 0)
	bottom.add_child(status_label)

func _build_create_modal() -> void:
	create_modal = PanelContainer.new()
	create_modal.name = "CreateModal"
	var box := HudKit.window().duplicate() as StyleBoxFlat
	box.set_content_margin_all(24)
	create_modal.add_theme_stylebox_override("panel", box)
	(canvas.get_child(0) as Control).add_child(create_modal)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	create_modal.add_child(v)
	var title := HudKit.label(tr("New Wizard"), 26, HudKit.GOLD_HI, HudKit.deco(), 5)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	v.add_child(name_row)
	var name_caption := HudKit.label(tr("Name:"), 16, HudKit.PARCHMENT, HudKit.body(), 2)
	name_caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(name_caption)
	name_input = FrontDoor.line_edit(tr("Your character's name"))
	name_input.name = "NameInput"
	name_input.max_length = 20
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_input.text_submitted.connect(func(_t: String): _on_confirm_create_pressed())
	name_row.add_child(name_input)
	var house_row := HBoxContainer.new()
	house_row.alignment = BoxContainer.ALIGNMENT_CENTER
	house_row.add_theme_constant_override("separation", 10)
	v.add_child(house_row)
	for entry: Array in FrontDoor.houses():
		var key: String = entry[0]
		var b := HudKit.button(FrontDoor.house_name(key), 14)
		b.name = "House_" + key
		b.custom_minimum_size = Vector2(110, 84)
		b.icon = UITheme.chrome_at("house_" + key, 44.0)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.expand_icon = false
		b.pressed.connect(func(): _select_house(key))
		house_row.add_child(b)
		house_buttons[key] = b
	house_desc = HudKit.label("", 15, HudKit.TEXT, HudKit.body(), 2)
	house_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	house_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# an autowrapped label needs a width before its first layout, or it is
	# one character wide and thousands of pixels tall
	house_desc.custom_minimum_size = Vector2(460, 66)
	v.add_child(house_desc)
	modal_status = HudKit.label("", 15, COLOR_ERROR, HudKit.body(), 2)
	modal_status.name = "ModalStatus"
	modal_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	modal_status.custom_minimum_size = Vector2(460, 0)
	v.add_child(modal_status)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	v.add_child(buttons)
	confirm_btn = HudKit.gold_button(tr("Create"), 44.0, 17)
	confirm_btn.name = "ConfirmCreate"
	confirm_btn.custom_minimum_size.x = 180
	confirm_btn.pressed.connect(_on_confirm_create_pressed)
	buttons.add_child(confirm_btn)
	cancel_btn = HudKit.button(tr("Cancel"), 16)
	cancel_btn.custom_minimum_size = Vector2(150, 44)
	cancel_btn.pressed.connect(_close_create)
	buttons.add_child(cancel_btn)
	create_modal.hide()

func _build_look_editor() -> void:
	look_editor = LookEditor.new()
	look_editor.name = "LookEditor"
	look_editor.set_edit_buttons(false)
	look_editor.hide()
	(canvas.get_child(0) as Control).add_child(look_editor)
	look_editor.look_changed.connect(_preview_look)
	look_editor.confirmed.connect(save_edit)
	look_editor.cancelled.connect(_close_edit)
	# the face tab frames the face (the wheel zoom's close end); the look tab
	# steps back to the whole character
	look_editor.tab_changed.connect(func(tab_name: String):
		_zoom_target = 1.0 if tab_name == "face" else 0.0)

## Side columns shrink with the canvas; while creating, the look editor
## takes the left and the create card the right, the dais between them.
func _layout() -> void:
	if roster_panel == null:
		return
	var view := get_viewport().get_visible_rect().size
	var side := clampf(view.x * 0.22, 260.0, 340.0)
	var edge := 24.0 if view.x < 1200 else 36.0
	var top := view.y * 0.5 - minf(190.0, view.y * 0.5 - 100.0)
	_place(roster_panel, Vector2(edge, top), Vector2(side, 0))
	# the wrapped motto needs its width before the card measures itself, or
	# it counts one word a line and the card runs down the screen
	motto_label.custom_minimum_size.x = side - 36.0
	_place(info_card, Vector2(view.x - side - edge, top), Vector2(side, 0))
	for card: Button in roster_cards:
		card.custom_minimum_size.x = side - 28.0
	var half := clampf(view.x * 0.5 - side - 70.0, 170.0, 340.0)
	nav.offset_left = -half
	nav.offset_right = half
	nav.offset_top = -26
	nav.offset_bottom = 26
	nav.visible = not creating and not editing
	roster_panel.visible = not creating and not editing
	info_card.visible = not creating
	bottom.visible = not creating and not editing
	edit_btn.visible = not creating and not editing and current_slot < characters.size()
	look_editor.visible = creating or editing
	create_modal.visible = creating
	if creating or editing:
		var ew := clampf(view.x * 0.24, 300.0, 360.0)
		_place(look_editor, Vector2(edge, maxf(16.0, view.y * 0.5 - 340.0)), Vector2(ew, 0))
	if creating:
		var w := minf(560.0, view.x * 0.5 - 90.0)
		var house_w := clampf((w - 88.0) / 4.0, 84.0, 110.0)
		for b: Button in house_buttons.values():
			b.custom_minimum_size = Vector2(house_w, 84)
		house_desc.custom_minimum_size.x = w - 48.0
		modal_status.custom_minimum_size.x = w - 48.0
		_place(create_modal, Vector2(view.x - w - edge, 0), Vector2(w, 0))
		create_modal.reset_size()
		create_modal.position.y = floorf((view.y - create_modal.size.y) * 0.5)

static func _place(c: Control, at: Vector2, size: Vector2) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = at
	c.custom_minimum_size.x = size.x
	c.size = Vector2(size.x, maxf(size.y, c.get_combined_minimum_size().y))

## ================================================================ the roster

func _load_characters() -> void:
	set_status(tr("Loading your characters…"), "progress")
	var res: Dictionary = await api.characters()
	if not is_inside_tree():
		return
	if not res.ok:
		set_status(res.error, "error")
		if not api.signed_in():
			# the session ran out: back to the card
			logged_out.emit()
		return
	characters = res.body.get("characters", [])
	roster_loaded = true
	set_status("")
	current_slot = 0
	_update_slot_display()

## kind: info | progress | error | warn
func set_status(message: String, kind: String = "info") -> void:
	status_label.text = message
	var colour := HudKit.TEXT
	match kind:
		"progress": colour = HudKit.GOLD_LT
		"error": colour = COLOR_ERROR
		"warn": colour = COLOR_WARN
	status_label.add_theme_color_override("font_color", colour)

func _switch_slot(new_slot: int) -> void:
	if is_switching or creating or new_slot == current_slot:
		return
	is_switching = true
	current_slot = new_slot
	# the dais turns half round to the other slot
	var tween := create_tween().set_parallel(true)
	tween.tween_property(podium, "rotation:y", podium.rotation.y + PI, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(camera, "fov", 58.0, 0.22).set_trans(Tween.TRANS_SINE)
	tween.chain().tween_property(camera, "fov", 62.0, 0.23).set_trans(Tween.TRANS_SINE)
	await tween.finished
	# the dais is round: back to its rest turn, so the next character faces
	# the camera as it stands up on it
	podium.rotation.y = 0.0
	is_switching = false
	_update_slot_display()

func _update_slot_display() -> void:
	slot_label.text = tr("SLOT %d / 2") % [current_slot + 1]
	_refresh_roster()
	if current_slot < characters.size():
		var c: Dictionary = characters[current_slot]
		var house := String(c.get("house", ""))
		var colour := FrontDoor.house_color(house)
		name_label.text = String(c.get("name", ""))
		house_label.text = FrontDoor.house_name(house)
		house_label.add_theme_color_override("font_color", colour.lightened(0.3))
		crest.texture = UITheme.chrome("house_" + house)
		crest.visible = true
		level_label.text = tr("Level %d") % int(c.get("level", 1))
		place_label.text = TravelData.display_name(String(c.get("map", "grounds")))
		motto_label.text = "\"%s\"" % tr(String(FrontDoor.house_entry(house).get("motto", "")))
		_apply_rune_color(colour)
		enter_btn.visible = true
		enter_btn.disabled = false
		enter_btn.text = tr("ENTER WORLD")
		_spawn_podium_character(house, look_for(c))
	else:
		name_label.text = tr("Empty Slot")
		house_label.text = tr("Create a new wizard")
		house_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		crest.visible = false
		level_label.text = "—"
		place_label.text = ""
		motto_label.text = ""
		enter_btn.visible = false
		_clear_podium_character()
		_apply_rune_color(Color(0.4, 0.5, 0.7, 0.6))
	# an empty line still takes its height in the card
	place_label.visible = place_label.text != ""
	motto_label.visible = motto_label.text != ""
	_layout()

## One card per slot: crest, name, level and house; the empty slot creates.
func _refresh_roster() -> void:
	for card: Button in roster_cards:
		# out of the column now: a card waiting to be freed still counts in
		# the panel's height
		roster.remove_child(card)
		card.queue_free()
	roster_cards.clear()
	roster_title.text = tr("YOUR WIZARDS  (%d / 2)") % characters.size()
	for i in range(MAX_CHARACTERS):
		var card := Button.new()
		card.name = "Slot%d" % (i + 1)
		card.focus_mode = Control.FOCUS_NONE
		card.custom_minimum_size = Vector2(260, 70)
		card.alignment = HORIZONTAL_ALIGNMENT_LEFT
		card.add_theme_constant_override("h_separation", 12)
		var selected := i == current_slot
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.09, 0.11, 0.17, 0.9) if selected else Color(0.05, 0.06, 0.09, 0.7)
		normal.border_color = HudKit.GOLD_LT if selected else Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)
		normal.set_border_width_all(2 if selected else 1)
		normal.set_corner_radius_all(6)
		normal.content_margin_left = 12
		normal.content_margin_right = 10
		var hover := normal.duplicate() as StyleBoxFlat
		hover.border_color = HudKit.GOLD_HI
		card.add_theme_stylebox_override("normal", normal)
		card.add_theme_stylebox_override("hover", hover)
		card.add_theme_stylebox_override("pressed", hover)
		card.add_theme_stylebox_override("focus", HudKit.empty())
		card.add_theme_font_override("font", HudKit.bold())
		card.add_theme_font_size_override("font_size", 16)
		card.add_theme_color_override("font_color", HudKit.PARCHMENT)
		card.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
		var index := i
		if i < characters.size():
			var c: Dictionary = characters[i]
			var house := String(c.get("house", ""))
			card.icon = UITheme.chrome_at("house_" + house, 46.0)
			card.text = tr("%s\nLevel %d  ·  %s") % [String(c.get("name", "")), int(c.get("level", 1)), FrontDoor.house_name(house)]
			card.pressed.connect(func(): _switch_slot(index))
		else:
			card.icon = UITheme.chrome_at("minimap_zoom_in", 30.0)
			card.text = tr("Create New Wizard")
			card.add_theme_color_override("font_color", HudKit.GOLD_LT)
			card.disabled = not roster_loaded
			card.pressed.connect(func():
				if current_slot != index:
					current_slot = index
					_update_slot_display()
				open_create())
		roster.add_child(card)
		roster_cards.append(card)

## A roster entry's look: the one edited here when there is one.
static func look_for(c: Dictionary) -> Dictionary:
	var id := int(c.get("id", 0))
	if pending_looks.has(id):
		return pending_looks[id]
	return LoginApi.look_of(c.get("look", []))

func _spawn_podium_character(house: String, look: Dictionary) -> void:
	_clear_podium_character()
	# the same body and the same house tint the world draws, so the character
	# on the dais is the one the player is about to play
	current_body = HeroAppearance.spawn(model_anchor, FrontDoor.house_color(house))
	if current_body == null:
		return
	HeroAppearance.apply_look(current_body, look)
	HeroAppearance.show_cloak(current_body, {"id": DEFAULT_CLOAK})
	HeroAppearance.show_equipped_wand(current_body, {"id": DEFAULT_WAND})

func _clear_podium_character() -> void:
	if is_instance_valid(current_body):
		current_body.queue_free()
	current_body = null

## ================================================================ create

func open_create() -> void:
	if characters.size() >= MAX_CHARACTERS or not roster_loaded:
		return
	creating = true
	modal_status.text = ""
	name_input.text = ""
	confirm_btn.disabled = false
	look_editor.set_edit_buttons(false)
	look_editor.set_look(Looks.default_look())
	look_editor._show_tab("look")
	_select_house(selected_house)
	_spawn_podium_character(selected_house, look_editor.look)
	model_anchor.rotation.y = 0.0
	_layout()
	name_input.grab_focus.call_deferred()

func _close_create() -> void:
	creating = false
	_zoom_target = 0.0
	_layout()
	_update_slot_display()

## ================================================================ edit a look

## Edit Appearance: the look editor on the chosen character, Save / Cancel.
func open_edit() -> void:
	if creating or editing or is_switching or current_slot >= characters.size():
		return
	editing = true
	look_editor.set_edit_buttons(true)
	look_editor.set_look(look_for(characters[current_slot]))
	look_editor._show_tab("look")
	model_anchor.rotation.y = 0.0
	set_status("")
	_layout()

## Save: the dais and the roster keep the new look; it goes to the server
## as this character enters the world.
func save_edit(look: Dictionary) -> void:
	if not editing or current_slot >= characters.size():
		return
	var c: Dictionary = characters[current_slot]
	pending_looks[int(c.get("id", 0))] = Looks.clean_look(look)
	_close_edit()
	set_status(tr("New look saved - it is kept as you enter the world."), "info")

func _close_edit() -> void:
	editing = false
	_zoom_target = 0.0
	_update_slot_display()

func _select_house(key: String) -> void:
	selected_house = key
	var data := FrontDoor.house_entry(key)
	house_desc.text = "%s - \"%s\"\n%s" % [FrontDoor.house_name(key), tr(String(data.get("motto", ""))), tr(String(data.get("trait", "")))]
	var colour := FrontDoor.house_color(key)
	house_desc.add_theme_color_override("font_color", colour.lightened(0.45))
	for k: String in house_buttons:
		var b: Button = house_buttons[k]
		b.modulate = Color.WHITE if k == key else Color(1, 1, 1, 0.55)
		var sb := HudKit.button_box("normal").duplicate() as StyleBoxFlat
		if k == key:
			sb.border_color = colour.lightened(0.35)
			sb.set_border_width_all(2)
			sb.bg_color = colour.darkened(0.72)
		b.add_theme_stylebox_override("normal", sb)
	if creating:
		_apply_rune_color(colour)
		if is_instance_valid(current_body):
			# the outfit's main cloth wears the house colour
			HeroAppearance.apply_house_tint(current_body, colour)

func _preview_look(look: Dictionary) -> void:
	if is_instance_valid(current_body):
		HeroAppearance.apply_look(current_body, look)

func _on_confirm_create_pressed() -> void:
	if confirm_btn.disabled:
		return
	var character_name := name_input.text.strip_edges()
	if character_name.length() < 2:
		modal_status.add_theme_color_override("font_color", COLOR_ERROR)
		modal_status.text = tr("A character name needs at least 2 letters!")
		return
	confirm_btn.disabled = true
	modal_status.add_theme_color_override("font_color", HudKit.GOLD_LT)
	modal_status.text = tr("Creating wizard...")
	var res: Dictionary = await api.create(character_name, selected_house, look_editor.look)
	if not is_inside_tree():
		return
	confirm_btn.disabled = false
	if not res.ok:
		modal_status.add_theme_color_override("font_color", COLOR_ERROR)
		modal_status.text = res.error
		return
	var made: Dictionary = res.body.get("character", {})
	# the roster again: the new character as the service keeps it (its
	# cleaned look, level, map)
	var listed: Dictionary = await api.characters()
	if not is_inside_tree():
		return
	if listed.ok:
		characters = listed.body.get("characters", [])
	else:
		characters.append({"id": made.get("id", 0), "name": made.get("name", character_name),
			"house": made.get("house", selected_house), "level": 1, "map": "grounds",
			"look": look_editor.look.keys().map(func(k): return [k, look_editor.look[k]])})
	current_slot = maxi(0, characters.find_custom(func(c): return int(c.get("id", 0)) == int(made.get("id", -1))))
	creating = false
	_zoom_target = 0.0
	_update_slot_display()

## ================================================================ enter, log out

func _on_enter_world_pressed() -> void:
	if current_slot >= characters.size() or enter_btn.disabled:
		return
	var c: Dictionary = characters[current_slot]
	enter_btn.disabled = true
	enter_btn.text = tr("Loading World...")
	set_status("")
	var res: Dictionary = await api.play(int(c.get("id", 0)))
	if not is_inside_tree():
		return
	if not res.ok:
		play_failed(res.error, res.maintenance)
		return
	var id := int(c.get("id", 0))
	look_on_entry = pending_looks.get(id, {})
	pending_looks.erase(id)
	play_granted.emit(String(res.body.get("map", "")), String(res.body.get("address", "")), String(res.body.get("ticket", "")))

func play_failed(message: String, maintenance := false) -> void:
	enter_btn.disabled = false
	enter_btn.text = tr("ENTER WORLD")
	set_status(message, "warn" if maintenance else "error")

func _on_logout_pressed() -> void:
	logout_btn.disabled = true
	await api.logout()
	logged_out.emit()

## ================================================================ input, camera

func _unhandled_input(event: InputEvent) -> void:
	if creating or editing:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT, KEY_A:
				_switch_slot((current_slot - 1 + MAX_CHARACTERS) % MAX_CHARACTERS)
			KEY_RIGHT, KEY_D:
				_switch_slot((current_slot + 1) % MAX_CHARACTERS)
			KEY_ENTER, KEY_KP_ENTER:
				if enter_btn.visible and not enter_btn.disabled:
					_on_enter_world_pressed()

## Right-drag on the stage turns the character (sideways) and swings the
## camera over or under it (up / down); the wheel there moves in to the face.
func _input(event: InputEvent) -> void:
	var vp := get_viewport().get_visible_rect().size
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_drag_turn = event.pressed and _on_stage(event.position, vp)
	elif event is InputEventMouseButton and event.pressed and _on_stage(event.position, vp) \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var step := 0.12 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.12
		_zoom_target = clampf(_zoom_target + step, 0.0, 1.0)
	elif event is InputEventMouseMotion and _drag_turn:
		model_anchor.rotation.y += event.relative.x * 0.01
		_pitch_target = clampf(_pitch_target + event.relative.y * 0.006, PITCH_MIN, PITCH_MAX)

func _on_stage(at: Vector2, vp: Vector2) -> bool:
	return at.x > vp.x * 0.3 and at.x < vp.x * 0.7 and at.y < vp.y - 120

## 0 = the whole character on the dais, 1 = the face close up.
func _process(delta: float) -> void:
	if _camera_far == Transform3D():
		_camera_far = camera.transform
	_zoom = lerpf(_zoom, _zoom_target, 1.0 - exp(-10.0 * delta))
	_pitch = lerpf(_pitch, _pitch_target, 1.0 - exp(-10.0 * delta))
	# close up the embers drift past the lens as big blobs
	embers.visible = _zoom < 0.3
	if _zoom_target == 0.0 and _zoom < 0.001 and absf(_pitch) < 0.0005 and _pitch_target == 0.0:
		camera.transform = _camera_far
		return
	var face := model_anchor.global_position + Vector3(0, 1.6, 0)
	var far_look := _camera_far.origin - _camera_far.basis.z * 3.0
	var t := smoothstep(0.0, 1.0, _zoom)
	var look := far_look.lerp(face, t)
	var near_origin := face + (_camera_far.origin - face).normalized() * 0.85
	var origin := _camera_far.origin.lerp(near_origin, t)
	# swing over / under round the point looked at (the middle far out, the
	# face close up), about the camera's own side axis
	var pivot := look if t > 0.0 else model_anchor.global_position + Vector3(0, 1.0, 0)
	var side := (look - origin).cross(Vector3.UP).normalized()
	origin = pivot + (origin - pivot).rotated(side, -_pitch)
	if t <= 0.0:
		look = pivot + (look - pivot).rotated(side, -_pitch)
	camera.transform = Transform3D(Basis.looking_at(look - origin, Vector3.UP), origin)
