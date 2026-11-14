extends Node3D
class_name NpcView

## A quest NPC (content/data/npcs.json), drawn here: NPCs are not server
## entities, they stand on the ground under their `pos`. A robed wizard tinted
## by the robe colour, or the body of its own (`body.model`, Borin's on the
## hero rig); the nameplate "<name> / < click to talk >"; a little idle bob;
## a gold arrow bobbing and turning over the head while an open talk quest
## names this NPC; the Talk clip while the player talks to it.
##
## Presentation only: talking is `RealmSession.talk` (main.gd), which the
## server range-checks against the same npcs.json position.

const WIZARD := "res://assets/models/characters/wizard.glb"
## The wizard's props an NPC does not carry.
const PROPS := ["Rig/Skeleton3D/handslot_r/2H_Staff", "Rig/Skeleton3D/handslot_l/Spellbook",
	"Rig/Skeleton3D/handslot_l/Spellbook_open"]
const CAPE := "Rig/Skeleton3D/chest/Mage_Cape"
const LOOPING_CLIPS := ["Idle", "Talk", "Walk_A"]
## How long the NPC keeps gesturing after the player talks to it.
const TALK_SECONDS := 4.0
## The wizard's height and girth (metres) when the content gives no body.
const WIZARD_HEIGHT := 2.25
const WIZARD_RADIUS := 0.45
## The nameplate's size on screen (fixed_size, about 15 px a line) and how far
## it reads.
const LABEL_PIXEL := 0.0008
const LABEL_RANGE := 30.0
const NAME_TINT := Color(1.0, 0.9, 0.5)
## How far over the crown the nameplate and the gold arrow float: the arrow
## clears the two-line plate at the usual camera distances.
const LABEL_RISE := 0.45
const MARKER_RISE := 1.35

## The content id ("teral_venn") and what npcs.json says about it.
var npc_id := ""
var npc_name := ""
var role := ""
var dialogue: Array = []
var services: Array = []
## The robe colour, also the dialogue medallion's.
var robe_color := Color(0.2, 0.25, 0.5)
## The body's height and radius at its scale (the click capsule, the label).
var height := WIZARD_HEIGHT
var radius := WIZARD_RADIUS
## Whether the gold arrow shows (an open talk quest names this NPC).
var wanted := false

var _rig: Node3D
var _marker: Node3D
var _label: Label3D
var _anim: AnimationPlayer
var _bob := 0.03
var _marker_height := 3.1
var _talk_left := 0.0
var _t := 0.0
static var _robe_textures: Dictionary = {}
static var _gold: StandardMaterial3D

func setup(id: String, data: Dictionary) -> void:
	npc_id = id
	name = "Npc_" + id
	npc_name = String(data.get("name", id))
	role = String(data.get("role", ""))
	dialogue = data.get("dialogue", [])
	services = data.get("services", [])
	var rgb: Array = data.get("robe", [])
	if rgb.size() == 3:
		robe_color = Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))
	var body: Dictionary = data.get("body", {})
	var size := float(body.get("scale", 1.0))
	height = float(body.get("height", WIZARD_HEIGHT)) * size
	radius = float(body.get("radius", WIZARD_RADIUS)) * size
	_t = randf() * TAU
	_rig = Node3D.new()
	_rig.name = "Rig"
	add_child(_rig)
	if DisplayServer.get_name() != "headless":
		_build_body(body, size)
	_label = Label3D.new()
	_label.name = "NpcLabel"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.double_sided = false
	_label.font_size = 32
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0)
	_label.modulate = NAME_TINT
	_label.fixed_size = true
	_label.pixel_size = LABEL_PIXEL
	_label.visibility_range_end = LABEL_RANGE
	# Over the NPC's own hat, the way the old game's screen-space plates read.
	_label.no_depth_test = true
	_label.render_priority = 1
	_label.position.y = height + LABEL_RISE
	add_child(_label)
	_label.text = tr("%s\n< click to talk >") % I18n.t(npc_name)
	_build_marker()
	var yaw: Variant = data.get("yaw")
	if yaw != null:
		rotation.y = float(yaw)

## The robed wizard with its props put away and the cape in the robe colour,
## or the NPC's own body; Idle plays.
func _build_body(body: Dictionary, size: float) -> void:
	var model: Node3D
	var path := String(body.get("model", ""))
	if path != "" and ResourceLoader.exists(path):
		model = (load(path) as PackedScene).instantiate()
		model.scale = Vector3.ONE * size
		_bob = 0.0   # the rig's Idle already breathes; a bob lifts the boots
	else:
		model = (load(WIZARD) as PackedScene).instantiate()
		for prop in PROPS:
			var node := model.get_node_or_null(prop) as Node3D
			if node != null:
				node.hide()
		var cape := model.get_node_or_null(CAPE) as MeshInstance3D
		if cape != null:
			cape.material_override = robe_material(robe_color)
	_rig.add_child(model)
	_anim = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		for clip in LOOPING_CLIPS:
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		if _anim.has_animation("Idle"):
			_anim.play("Idle")
			_anim.seek(randf() * _anim.current_animation_length)

## A gold arrow pointing down at the NPC, with a warm glow, while a quest asks
## the player to talk to it.
func _build_marker() -> void:
	_marker = Node3D.new()
	_marker.name = "QuestArrow"
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.07
	shaft_mesh.bottom_radius = 0.07
	shaft_mesh.height = 0.34
	shaft_mesh.material = gold_material()
	shaft.mesh = shaft_mesh
	shaft.position.y = 0.37
	_marker.add_child(shaft)
	var head := MeshInstance3D.new()
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.22
	head_mesh.bottom_radius = 0.0
	head_mesh.height = 0.3
	head_mesh.material = gold_material()
	head.mesh = head_mesh
	head.position.y = 0.05
	_marker.add_child(head)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.3)
	glow.light_energy = 0.8
	glow.omni_range = 5.0
	glow.position.y = 0.25
	_marker.add_child(glow)
	_marker_height = height + MARKER_RISE
	_marker.position.y = _marker_height
	_marker.visible = false
	add_child(_marker)

func set_wanted(on: bool) -> void:
	wanted = on
	_marker.visible = on

## The player talks to it: it gestures for a while, then idles again.
func talk() -> void:
	if _anim != null and _anim.has_animation("Talk"):
		_anim.play("Talk", 0.3)
		_talk_left = TALK_SECONDS

## Where a ray from `origin` along `dir` (unit) first meets the NPC's body (a
## vertical cylinder `radius` wide, feet to crown), as a distance along the
## ray; INF when it misses.
func ray_distance(origin: Vector3, dir: Vector3) -> float:
	var o := Vector2(origin.x - global_position.x, origin.z - global_position.z)
	var d := Vector2(dir.x, dir.z)
	var a := d.length_squared()
	if a < 1e-8:
		return INF
	var b := o.dot(d)
	var c := o.length_squared() - radius * radius
	var disc := b * b - a * c
	if disc < 0.0:
		return INF
	var root := sqrt(disc)
	for t in [(-b - root) / a, (-b + root) / a]:
		if t < 0.0:
			continue
		var y: float = origin.y + dir.y * t - global_position.y
		if y >= 0.0 and y <= height:
			return t
	return INF

func _process(delta: float) -> void:
	_t += delta
	_rig.position.y = sin(_t * 2.0) * _bob
	if _talk_left > 0.0:
		_talk_left -= delta
		if _talk_left <= 0.0 and _anim != null and _anim.has_animation("Idle"):
			_anim.play("Idle", 0.4)
	if _marker.visible:
		_marker.position.y = _marker_height + sin(_t * 4.0) * 0.18
		_marker.rotation.y += delta * 1.5

## The robe: a soft noise in the robe colour, darker than the colour itself.
static func robe_material(colour: Color) -> StandardMaterial3D:
	var key := colour.to_html()
	if not _robe_textures.has(key):
		_robe_textures[key] = _noise_texture(colour.darkened(0.55), colour.darkened(0.25), 64, 71)
	var material := StandardMaterial3D.new()
	material.albedo_texture = _robe_textures[key]
	material.roughness = 0.85
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.uv1_scale = Vector3(6, 6, 6)
	return material

static func gold_material() -> StandardMaterial3D:
	if _gold == null:
		_gold = StandardMaterial3D.new()
		_gold.albedo_color = Color(0.95, 0.75, 0.25)
		_gold.metallic = 0.9
		_gold.roughness = 0.25
		_gold.emission_enabled = true
		_gold.emission = Color(0.8, 0.6, 0.15)
		_gold.emission_energy_multiplier = 0.6
	return _gold

static func _noise_texture(base: Color, variation: Color, px: int, seed_value: int) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.025
	noise.fractal_octaves = 4
	var image := Image.create(px, px, false, Image.FORMAT_RGBA8)
	for y in px:
		for x in px:
			var t := clampf(noise.get_noise_2d(x, y) * 0.8 + 0.5 + rng.randf_range(-0.035, 0.035), 0.0, 1.0)
			image.set_pixel(x, y, base.lerp(variation, t))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
