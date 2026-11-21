extends RefCounted
class_name HeroAppearance

## The hero body, and the one house-tint rule that dresses it.
##
## The in-game player and the character-select preview both spawn `MODEL` and
## tint it through here, so the wizard a player picks on the podium is the wizard
## they then play. Before this helper existed the preview loaded a different
## KayKit model (`wizard.glb`) and tinted a `Mage_Cape` node that only that model
## has, so the podium showed a character nobody could ever play.
##
## The hero (art/characters/hero_q: the free Quaternius kit - Modular
## Character Outfits, the Universal Base Characters head and hairstyles, all on
## the Universal rig with GameRig bone names) is several skinned meshes on one
## skeleton: `Hero_Head`, `Hero_Eyes`, `Hero_Brows`, `Hero_Hair_<style>` and the
## outfit parts `Hero_<Outfit>_<part>`; the look picks which are shown. There is
## no trim/robe material to recolour yet; the tint stays keyed on material name,
## so a body that ships `Hero_Trim` / `Hero_Robe` slots (or a house-mask
## material) is tinted and the current one is left as authored.

const MODEL := preload("res://assets/models/characters/hero_wizard.glb")
const WAND := preload("res://assets/models/props/wand.gltf")
const WandGripModifierScript = preload("res://scripts/entities/wand_grip_modifier.gd")
## Refinement aura colour by wand upgrade tier (presentation only).
const WAND_AURAS := [Color(0.7,0.7,0.7,0),Color(0.7,0.7,0.7,0),Color(0.7,0.7,0.7,0),Color(0.3,0.7,1,0.4),Color(0.2,0.8,1,0.6),Color(0.1,0.9,1,0.8),Color(1,0.85,0.2,0.9),Color(1,0.6,0.1,1),Color(0.9,0.2,1,1),Color(1,0.9,0.4,1)]

## The prop's own units: `assets/models/props/wand.gltf` is a cylinder whose
## POSITION accessor spans y -0.2656934 .. +0.7004468 (0.9661 m long, 0.0803 m
## radius). The pivot is therefore 0.1063 m above the butt and 0.2802 m below the
## tip once WAND_SCALE is applied - the grip sits at the pivot, the butt clears
## the bottom of the fist and the tip leads it, which is how a wand is held.
const WAND_SCALE := 0.4
const WAND_TIP_LOCAL := Vector3(0.0, 0.7004468, 0.0)
## The wand leaves the fist between thumb and index and leans out along the
## hand: a pointer, not a hammer. Straight across the palm (pinky -> index) the
## aim had to bend the wrist ~70 degrees sideways to point it at a target.
const WAND_LEAN_DEG := 18.0
## The handle sits in the index end of the fist's tunnel: this far from the
## knuckles' centre toward the index (across the palm) and out of the palm,
## so the tip leaves between the thumb and the index knuckle, not through
## the curled fingers.
const WAND_SEAT := Vector2(0.018, 0.006)

static func wand_axis_in_wrist(skeleton: Skeleton3D) -> Vector3:
	var grip := RigIK.grip_frame(skeleton, "R")
	var lean := deg_to_rad(WAND_LEAN_DEG)
	return (grip.basis.x * cos(lean) + grip.basis.y * sin(lean)).normalized()

static func wand_grip_transform(skeleton: Skeleton3D) -> Transform3D:
	var grip := RigIK.grip_frame(skeleton, "R")
	var seat := grip.origin + grip.basis.x * WAND_SEAT.x + grip.basis.z * WAND_SEAT.y
	return Transform3D(Basis(Quaternion(Vector3.UP, wand_axis_in_wrist(skeleton))), seat)


static func _bone_index(skeleton: Skeleton3D, bone: String) -> int:
	return RigIK.bone_index(skeleton, bone)


## The tip of the equipped wand, as a live node that rides the animation, or null
## when no wand is equipped. Every emitter (spell flash, projectile, trail) reads
## this one definition, so "out of the wand's head" means the same thing
## everywhere.
static func wand_tip(root: Node) -> Node3D:
	if root == null:
		return null
	var attachment := root.find_child("EquippedWand", true, false)
	if attachment == null:
		return null
	return attachment.find_child("WandTip", true, false) as Node3D


## The existing prop follows the same wrist on both the live model and preview.
## This is presentation only: the server owns what is equipped.
static func show_equipped_wand(root: Node, entry: Dictionary) -> void:
	var previous := root.find_child("EquippedWand",true,false)
	if previous:
		# Stop the follower holding a reference to a node about to be freed.
		var follower := previous.get_parent().get_node_or_null("RigFollower")
		if follower is RigFollower:
			(follower as RigFollower).detach(previous)
		previous.get_parent().remove_child(previous)
		previous.queue_free()
	var wand_grip = root.find_child("WandGripModifier", true, false)
	if entry.is_empty():
		if wand_grip:
			wand_grip.target_weight = 0.0
			wand_grip.weight = 0.0
		return
	var skeleton: Skeleton3D = _skeleton(root)
	if skeleton == null: return
	var bone := HeroBones.hand("R")
	if RigIK.bone_index(skeleton, bone) < 0: return

	# Curl fingers of right hand to firmly grasp the wand
	if wand_grip == null:
		wand_grip = WandGripModifierScript.new()
		wand_grip.name = "WandGripModifier"
		skeleton.add_child(wand_grip)
	wand_grip.target_weight = 1.0
	wand_grip.weight = 1.0

	# A plain holder glued to the FINAL bone pose by the rig's follower, not a
	# BoneAttachment3D: an attachment follows the skeleton's own update, which runs
	# before the cast layer poses the arm, so the wand used to sit at the clip-only
	# pose while a cast aimed the hand elsewhere. See rig_follower.gd.
	var attachment := Node3D.new()
	attachment.name = "EquippedWand"
	skeleton.add_child(attachment)
	var grip := wand_grip_transform(skeleton)
	RigFollower.of(skeleton).attach(attachment, bone, grip)
	# A tiered wand names its own model (items.json `model`, authored in this
	# prop's frame by art/wands/scripts/build_wands.py); others keep the default.
	var model_path := String(Items.item(String(entry.get("id", ""))).get("model", ""))
	var scene: PackedScene = load(model_path) as PackedScene if model_path != "" and ResourceLoader.exists(model_path) else WAND
	var wand := scene.instantiate() as Node3D
	wand.transform = Transform3D(Basis().scaled(Vector3.ONE * WAND_SCALE), Vector3.ZERO)
	attachment.add_child(wand)
	# One definition of "the wand's tip", authored in the prop's own space so it
	# follows every pose and is inherited by the mesh's own scaling.
	var tip := Marker3D.new()
	tip.name = "WandTip"
	tip.position = WAND_TIP_LOCAL
	wand.add_child(tip)
	var tier := int(entry.get("tier", 0))
	if tier >= 4:
		var aura := CPUParticles3D.new()
		# The refinement aura belongs to the wand, so it is built here, at the tip,
		# and scales with the tier - a second, statically-placed aura in the player
		# scene used to sit wherever the scene put it, off the wand entirely.
		aura.amount = 20 if tier < 7 else (40 if tier < 9 else 70)
		aura.lifetime = 0.6
		aura.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		aura.emission_sphere_radius = 0.035
		aura.gravity = Vector3(0,0.12,0)
		aura.initial_velocity_min = 0.03
		aura.initial_velocity_max = 0.08
		aura.scale_amount_min = 0.012
		aura.scale_amount_max = 0.025
		aura.color = WAND_AURAS[clampi(tier, 0, WAND_AURAS.size() - 1)]
		# Anchored to the tip in the wand's space (the wand carries the 0.4 scale,
		# so WAND_TIP_LOCAL needs no separate scaling) rather than a guessed 0.28 m
		# up the bone, which pointed the aura away from the wand.
		aura.position = wand.transform * WAND_TIP_LOCAL
		attachment.add_child(aura)

## ---------------------------------------------------------------- cloak

const CLOAK_MODEL := "res://assets/models/cloaks/cloak_base.glb"
static var _cloak_materials: Dictionary = {}

## Draw the worn chest item's cloak, or none. Every cloak item shares one
## skinned mesh (art/cloaks/scripts/build_cloak_sim.py, bound to the same GameRig as
## the body) and names its own fabric (items.json `cloak_texture`). The mesh is
## moved under the body's Skeleton3D, where its skin binds by bone name, so it
## rides every clip, the cast layer and the broom grip like the body does.
static func show_cloak(root: Node, entry: Dictionary) -> void:
	var skeleton: Skeleton3D = _skeleton(root)
	if skeleton == null:
		return
	var texture_path := String(Items.item(String(entry.get("id", ""))).get("cloak_texture", ""))
	var current := skeleton.get_node_or_null("EquippedCloak") as MeshInstance3D
	if current != null and current.get_meta("cloak_texture", "") == texture_path:
		return
	if current != null:
		skeleton.remove_child(current)
		current.queue_free()
	if texture_path == "" or not ResourceLoader.exists(texture_path):
		return
	var scene := load(CLOAK_MODEL) as PackedScene
	if scene == null:
		return
	var source := scene.instantiate()
	var mesh := source.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	# the panel's chain bones come from the cloak model's own skeleton
	var chains := CloakDeformerScript.ensure_bones(skeleton, mesh.get_parent() as Skeleton3D)
	mesh.get_parent().remove_child(mesh)
	source.free()
	if not chains:
		mesh.free()
		return
	mesh.name = "EquippedCloak"
	mesh.set_meta("cloak_texture", texture_path)
	mesh.layers |= CHARACTER_LAYER
	skeleton.add_child(mesh)
	mesh.skeleton = NodePath("..")
	mesh.transform = Transform3D.IDENTITY
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mesh.material_override = _cloak_material(texture_path)
	# The deformer swings the panel's chain bones (spring bones, with the
	# legs, arms and back as colliders).
	var deformer := CloakDeformerScript.new()
	deformer.name = "CloakDeformer"
	mesh.add_child(deformer)

const CloakDeformerScript = preload("res://scripts/entities/cloak_deformer.gd")
const CLOAK_SHADER := preload("res://assets/shaders/cloak.gdshader")

static func _cloak_material(texture_path: String) -> ShaderMaterial:
	if _cloak_materials.has(texture_path):
		return _cloak_materials[texture_path]
	var mat := ShaderMaterial.new()   # cull_disabled: one sheet of cloth, both faces show
	mat.shader = CLOAK_SHADER
	mat.set_shader_parameter("albedo_tex", load(texture_path))
	mat.set_shader_parameter("roughness", 0.85)
	mat.set_shader_parameter("rim", CLOTH_RIM)
	mat.set_shader_parameter("rim_tint", CLOTH_RIM_TINT)
	_cloak_materials[texture_path] = mat
	return mat

static func _skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D: return root
	for child in root.get_children():
		var found := _skeleton(child)
		if found: return found
	return null

## A stationary hero's breathing clip, in preference order. The body carries
## `Idle`; the others are seat/loop fallbacks if the animation set changes.
const IDLE_CLIPS := ["Idle", "Cast_Idle_Loop", "Broom_Seated_Idle"]

## The clip an idle body should play, or "" when it carries none of them.
static func idle_clip(player: AnimationPlayer) -> String:
	if player == null:
		return ""
	for clip in IDLE_CLIPS:
		if player.has_animation(clip):
			return clip
	return ""


## Spawn the hero body under `anchor` and return it, already tinted with `primary`
## and (when the body carries one) playing its idle clip.
##
## `anchor` is any Node3D: the player's `Visuals`, or the podium's `ModelAnchor`.
## The caller resolves `primary` from the house, so this helper stays free of
## game data and is just as usable from a test.
static func spawn(anchor: Node3D, primary: Color) -> Node3D:
	var body := MODEL.instantiate() as Node3D
	if body == null:
		return null
	install_head(body)
	# On the character layer before it enters the world (see set_character_layer).
	set_character_layer(body)
	anchor.add_child(body)
	body.position = Vector3.ZERO
	body.rotation = Vector3.ZERO
	apply_house_tint(body, primary)
	# every hairstyle ships in the model: show the default look until the
	# owner's look arrives
	apply_look(body, Looks.default_look())
	var player := find_anim_player(body)
	var clip := idle_clip(player)
	if clip != "":
		player.play(clip)
	return body


## Dress the hero under `visuals` in its house: the main cloth of every outfit
## takes `primary` (hero_cloth.gdshader `house_color`). The single definition of
## what a house looks like on the body; `visuals` may be the model root or any
## ancestor of it.
static func apply_house_tint(visuals: Node, primary: Color) -> void:
	if visuals == null:
		return
	dress_parts(visuals)
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var part := String(node.name)
		for prefix: String in OUTFIT_PARTS.values():
			if part.begins_with(prefix):
				(node as MeshInstance3D).set_instance_shader_parameter("house_color", primary)


## ---------------------------------------------------------------- head

## The hero's head (tools/art/hero/build_head.py): a MakeHuman head and neck
## (CC0) on the same GameRig, with its eyes, corneas, lashes and every brow,
## and the face sliders as shape keys of MakeHuman's own targets. It replaces
## the kit head's parts of MODEL (removed from each instance).
const HEAD_MODEL := preload("res://assets/models/characters/face/hero_head.glb")
const FACE_DIR := "res://assets/models/characters/face/"
const OLD_HEAD_PARTS := ["Hero_Head", "Hero_Eyes", "Hero_Brows", "Hero_Brows_Regular", "Hero_BrowPaint",
	"Hero_Beard_Full"]
const FACE_SKIN_SHADER := preload("res://assets/shaders/hero_face_skin.gdshader")
const FACE_EYE_SHADER := preload("res://assets/shaders/hero_face_eye.gdshader")
const FACE_CORNEA_SHADER := preload("res://assets/shaders/hero_face_cornea.gdshader")
const HAIR_CARD_SHADER := preload("res://assets/shaders/hero_hair_card.gdshader")
const HAIR_FRINGE_SHADER := preload("res://assets/shaders/hero_hair_fringe.gdshader")
## A face slider at +-1 sets its keys to this: build_head.py bakes each key at
## the strength its slider sheet was tuned to.
const FACE_KEY_GAIN := 1.0
static var _face_materials := {}
## How far (m) the small head parts are drawn (by the name after "Face_").
const FACE_PART_REACH := {"Lashes": 9.0, "Cornea": 12.0, "Brow": 30.0, "Eyeball": 40.0}


## Take the kit head off `body` (a MODEL instance) and put the head model's
## parts on its skeleton, bound by bone name (like the cloak). Idempotent.
static func install_head(body: Node) -> void:
	var skeleton := _skeleton(body)
	if skeleton == null or skeleton.has_node("Face_Head"):
		return
	for node in body.find_children("Hero_*", "MeshInstance3D", true, false):
		var part := String(node.name)
		if part in OLD_HEAD_PARTS or part.begins_with("Hero_Hair_"):
			node.get_parent().remove_child(node)
			node.free()
	var source := HEAD_MODEL.instantiate()
	for node in source.find_children("Face_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		mi.get_parent().remove_child(mi)
		mi.owner = null
		# on the character layer before it enters the world (set_character_layer)
		mi.layers |= CHARACTER_LAYER
		skeleton.add_child(mi)
		mi.skeleton = NodePath("..")
		mi.transform = Transform3D.IDENTITY
		var material := face_material(String(mi.name))
		for surface in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(surface, material)
		if mi.name == "Face_Cornea" or String(mi.name).begins_with("Face_Brow_") or mi.name == "Face_Lashes":
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# past these the part is under a pixel: not drawn (fewer draws per hero)
		var reach := float(FACE_PART_REACH.get(String(mi.name).get_slice("_", 1), 0.0))
		if reach > 0.0:
			mi.visibility_range_end = reach
			mi.visibility_range_end_margin = 1.0
	source.free()


## The shared material of a head part.
static func face_material(part: String) -> Material:
	if _face_materials.has(part):
		return _face_materials[part]
	var mat := ShaderMaterial.new()
	match part:
		"Face_Head":
			mat.shader = FACE_SKIN_SHADER
			mat.set_shader_parameter("albedo_tex", load(FACE_DIR + "head_albedo.png"))
			mat.set_shader_parameter("albedo_dark_tex", load(FACE_DIR + "head_albedo_dark.png"))
			mat.set_shader_parameter("normal_tex", load(FACE_DIR + "head_normal.png"))
			mat.set_shader_parameter("zones_tex", load(FACE_DIR + "head_zones.png"))
			mat.set_shader_parameter("grain_tex", load(SKIN_GRAIN))
			if ResourceLoader.exists(SKIN_MICRO):
				mat.set_shader_parameter("micro_tex", load(SKIN_MICRO))
				mat.set_shader_parameter("has_micro", true)
		"Face_Eyeball":
			mat.shader = FACE_EYE_SHADER
			mat.set_shader_parameter("eye_tex", load(FACE_DIR + "eye.png"))
		"Face_Cornea":
			mat.shader = FACE_CORNEA_SHADER
		"Face_Lashes":
			# procedural lash strips on the lid margins (build_head.py) on the
			# lash atlas (strand_atlas.py --lashes)
			mat = _card_material(load(FACE_DIR + "lash_atlas.png"), false, 0.3)
			_set_both(mat, {"spec_r": 0.05, "spec_trt": 0.04, "transmit": 0.0})
		_:
			# Face_Brow_<name>: fine hairs, a soft sheen
			mat = _card_material(load(FACE_DIR + "brow_%s.png" % part.trim_prefix("Face_Brow_")), false, 0.4)
			# brows barely shine: on a dark albedo even a faint broad lobe
			# turned the whole brow grey
			_set_both(mat, {"strand_along_u": true, "spec_r": 0.015, "spec_trt": 0.02, "gloss_r": 120.0,
				"transmit": 0.1, "darkness": 1.6})
			# a higher cut leaves the brow's thin hairs to the soft fringe pass:
			# at 0.4 the brow read as one painted black stroke
			_set_both(mat, {"alpha_cut": 0.62})
	_face_materials[part] = mat
	return mat


## ---------------------------------------------------------------- hair

## Hairstyles as hair cards (tools/art/hero/hair_cards.py): each built style
## is its own hair_<style>.glb (mesh skinned to the Head bone, with the head's
## scalp-moving shape keys) and cap_<style>.png (its short hairs on the scalp,
## in the head's UV). The look's style is loaded when first worn.
const HAIR_DIR := "res://assets/models/characters/hair/"
## The styles built so far (all of looks.json's): a style with cards has a
## hair_<style>.glb; Buzzed is drawn by its hair cap alone.
const CARD_STYLES := ["SimpleParted", "Buzzed", "Long", "Wavy", "Tousled", "Neat", "Ponytail", "Curly"]
## A look's style that has no cards yet shows the nearest built one (none
## today; a style added to looks.json before its cards are built).
const STAND_INS := {}
const HairSwayScript = preload("res://scripts/entities/hair_sway.gd")
static var _hair_scenes := {}
static var _hair_material: ShaderMaterial = null


## The style a look's `style` is drawn with ("none" stays bald).
static func drawn_style(style: String) -> String:
	if style == "none" or style in CARD_STYLES:
		return style
	return String(STAND_INS.get(style, CARD_STYLES[0]))


static func _hair_card_material() -> ShaderMaterial:
	if _hair_material == null:
		_hair_material = _card_material(load(HAIR_DIR + "hair_atlas.png"), true, 0.5)
	return _hair_material


## Past this distance the far LOD of the hair is drawn (the base and main
## layers, every other row, no fringe pass): about a fifth of the triangles.
const HAIR_NEAR := 7.0
static var _hair_far_material: ShaderMaterial = null


static func _hair_far_card_material() -> ShaderMaterial:
	if _hair_far_material == null:
		_hair_far_material = (_hair_card_material().duplicate() as ShaderMaterial)
		_hair_far_material.next_pass = null
	return _hair_far_material


## Put `style`'s cards on the skeleton (or none) as `node` (the near mesh)
## and `node`Far (the far LOD): the hair ("Hair") or the beard ("Beard").
## Returns the meshes worn.
static func _wear_cards(skeleton: Skeleton3D, style: String, node: String, sway: bool) -> Array[MeshInstance3D]:
	var worn: Array[MeshInstance3D] = []
	var current := skeleton.get_node_or_null(node) as MeshInstance3D
	if current == null:
		current = skeleton.get_node_or_null(node + "Shell") as MeshInstance3D
	if current != null and String(current.get_meta("style", "")) == style:
		worn.append(current)
		for extra in [node + "Far", node + "Shell"]:
			var other := skeleton.get_node_or_null(extra) as MeshInstance3D
			if other != null:
				worn.append(other)
		return worn
	for old_name in [node, node + "Far", node + "Shell"]:
		var old := skeleton.get_node_or_null(old_name)
		if old != null:
			skeleton.remove_child(old)
			old.queue_free()
	var path := HAIR_DIR + "hair_%s.glb" % style
	if style == "" or style == "none" or not ResourceLoader.exists(path):
		return worn
	if not _hair_scenes.has(style):
		_hair_scenes[style] = load(path)
	var source := (_hair_scenes[style] as PackedScene).instantiate()
	for found in source.find_children("*", "MeshInstance3D", true, false):
		var mi := found as MeshInstance3D
		var far := String(mi.name).ends_with("_far")
		var shell := String(mi.name).ends_with("_shell")
		mi.get_parent().remove_child(mi)
		mi.owner = null
		mi.name = node + "Far" if far else node
		mi.set_meta("style", style)
		mi.layers |= CHARACTER_LAYER
		skeleton.add_child(mi)
		mi.skeleton = NodePath("..")
		mi.transform = Transform3D.IDENTITY
		if shell:
			# short dense hair as shells (a beard): near the camera only, the
			# hair cap on the skin carries it further out
			mi.name = node + "Shell"
			mi.visibility_range_end = SHELL_NEAR
			mi.visibility_range_end_margin = 0.5
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_surface_override_material(0, _shell_material(style))
		elif far:
			mi.visibility_range_begin = HAIR_NEAR
			mi.visibility_range_begin_margin = 0.5
			mi.set_surface_override_material(0, _hair_far_card_material())
		else:
			mi.visibility_range_end = HAIR_NEAR
			mi.visibility_range_end_margin = 0.5
			mi.set_surface_override_material(0, _hair_card_material())
			if sway:
				var spring := HairSwayScript.new()
				spring.name = "HairSway"
				mi.add_child(spring)
		worn.append(mi)
	source.free()
	return worn


## The head's material under hair `style` and `beard` (Looks.list("beards")):
## the face material with the style's hair cap (cap_<style>.png) and the
## beard's (cap_Beard_<...>.png, hair_cards.py) - one per pair worn, shared.
static func _head_material(style: String, beard: String) -> Material:
	var base := face_material("Face_Head")
	var hair_path := HAIR_DIR + "cap_%s.png" % style
	var has_hair := style != "none" and ResourceLoader.exists(hair_path)
	var beard_style := String(BEARDS.get(beard, {}).get("cap", ""))
	var beard_path := HAIR_DIR + "cap_%s.png" % beard_style
	var has_beard := beard_style != "" and ResourceLoader.exists(beard_path)
	if not has_hair and not has_beard:
		return base
	var key := "Face_Head/%s/%s" % [style if has_hair else "", beard_style if has_beard else ""]
	if not _face_materials.has(key):
		var mat := (base as ShaderMaterial).duplicate() as ShaderMaterial
		if has_hair:
			mat.set_shader_parameter("cap_tex", load(hair_path))
			mat.set_shader_parameter("has_cap", true)
		if has_beard:
			mat.set_shader_parameter("beard_tex", load(beard_path))
			mat.set_shader_parameter("has_beard", true)
		_face_materials[key] = mat
	return _face_materials[key]


## Shells are drawn within this distance (m).
const SHELL_NEAR := 6.0
const HAIR_SHELL_SHADER := preload("res://assets/shaders/hero_hair_shell.gdshader")


## The shell material of `style` (its strand texture shell_<style>.png).
static func _shell_material(style: String) -> ShaderMaterial:
	var key := "shell/" + style
	if not _face_materials.has(key):
		var mat := ShaderMaterial.new()
		mat.shader = HAIR_SHELL_SHADER
		mat.set_shader_parameter("shell_tex", load(HAIR_DIR + "shell_%s.png" % style))
		mat.set_shader_parameter("use_card_data", false)
		_face_materials[key] = mat
	return _face_materials[key]


## Set shader parameters on a card material and its fringe pass.
static func _set_both(mat: ShaderMaterial, params: Dictionary) -> void:
	for key: String in params:
		mat.set_shader_parameter(key, params[key])
		(mat.next_pass as ShaderMaterial).set_shader_parameter(key, params[key])


## A hair-card material (hero_hair_card + its fringe pass) on `atlas`.
static func _card_material(atlas: Texture2D, card_data: bool, alpha_cut := 0.5) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = HAIR_CARD_SHADER
	var fringe := ShaderMaterial.new()
	fringe.shader = HAIR_FRINGE_SHADER
	for m: ShaderMaterial in [mat, fringe]:
		m.set_shader_parameter("atlas_tex", atlas)
		m.set_shader_parameter("use_card_data", card_data)
		m.set_shader_parameter("alpha_cut", alpha_cut)
	mat.next_pass = fringe
	return mat


## ---------------------------------------------------------------- lighting

## Render layer (1-based 20) that only characters sit on, so a character light
## can brighten them without touching the world.
const CHARACTER_LAYER := 1 << 19
## The world's sky ambient is tuned for bright stone; dark clothing facing away
## from the sun reads as a black silhouette under it. A soft, shadowless light
## from the camera lifts only characters (light_cull_mask), the usual
## third-person "character fill".
const FILL_ENERGY := 0.28
const FILL_COLOR := Color(0.92, 0.95, 1.0)
## Woven cloth scatters light at grazing angles; a little rim gives the
## silhouette an edge against the background. Only the outfit gets it: on the
## face a rim of 0.3 washed the cheeks and brow out to a grey sheen.
const CLOTH_RIM := 0.1
const CLOTH_RIM_TINT := 0.25
## Parts drawn by the look shaders (colours per hero as instance uniforms).
const SKIN_SHADER := preload("res://assets/shaders/hero_skin.gdshader")
const HAIR_SHADER := preload("res://assets/shaders/hero_hair.gdshader")
const EYE_SHADER := preload("res://assets/shaders/hero_eye.gdshader")
const BROW_SHADER := preload("res://assets/shaders/hero_brow.gdshader")
const BROW_PAINT_SHADER := preload("res://assets/shaders/hero_brow_paint.gdshader")
const CLOTH_SHADER := preload("res://assets/shaders/hero_cloth.gdshader")
## The kit arm texture brought to the MakeHuman face's mean colour.
const ARM_TONE_MATCH := Vector3(1.423, 1.606, 2.065)
## Materials that are skin: the head's and the bare arms every outfit carries.
const SKIN_MATERIALS := ["MI_Superhero_Male", "MI_Regular_Male"]
## Each hairstyle texture's mean luminance in linear colour (hero_hair.gdshader
## divides by it, so every style shows the picked colour at the same depth).
const HAIR_REF_LUMA := {"SimpleParted": 0.2807, "Buzzed": 0.2807, "Long": 0.2692,
	"Wavy": 0.0275, "Tousled": 0.0127, "Neat": 0.0123, "Ponytail": 0.013, "Curly": 0.008,
	"Beard_Full": 0.2807}
## The generated styles' temple shells (Hero_Hair_<style>_Temple, short
## strands): the strands' mean, so they shade like the locks.
const TEMPLE_REF_LUMA := 0.2218
## How far a face type (Looks.list("faces")) goes: MakeHuman's whole-face
## targets at full strength bloated the triangular and square faces.
const FACE_TYPE_WEIGHT := 0.7
## A face slider at +-1 sets its shape key to this: at 1.0 faces stayed too
## alike (20 random faces, 2026-11-02); 1.6 turned some into caricatures.
const FACE_SLIDER_GAIN := 1.3
## The head's scalp masks, one per hairstyle (build_rig.py), as one array.
const SCALP_DIR := "res://assets/models/characters/scalp/"
static var _scalp_masks: Texture2DArray = null
## The head's beard area (face_masks.png R; build_rig.py) and the fine grain
## that breaks the painted shade (art/characters/hero_q/skin_grain.py).
const FACE_MASKS := "res://assets/models/characters/face_masks.png"
const SKIN_GRAIN := "res://assets/models/characters/skin_grain.png"
## tiling pore normal (RG) + cavity (B), HumanShaders by MatMADNESS, CC BY 4.0
const SKIN_MICRO := "res://assets/models/characters/skin_micro.png"
## a 1024 px iris photo for the eye shader, HumanShaders by MatMADNESS, CC BY 4.0
const EYE_IRIS := "res://assets/models/characters/eye_iris.png"
## Looks.list("beards") -> the beard's short hairs on the face (its hair cap,
## cap_<cap>.png) and, for a full beard, its cards (hair_<mesh>.glb).
## "shade" is the kit head's painted beard (unused by the MakeHuman head).
const BEARDS := {
	"none": {"shade": 0.0, "mesh": "", "cap": ""},
	"stubble": {"shade": 0.5, "mesh": "", "cap": "Beard_Stubble"},
	"short": {"shade": 0.95, "mesh": "", "cap": "Beard_Short"},
	"full": {"shade": 1.0, "mesh": "Beard_Full", "cap": "Beard_Full"},
}
## Looks.list("brows") -> a painted brow (its tile on Hero_BrowPaint, 1-5) or
## a brow mesh of the kit.
const BROWS := {
	"natural": {"paint": 1, "mesh": ""},
	"bushy": {"paint": 2, "mesh": ""},
	"arched": {"paint": 3, "mesh": ""},
	"thin": {"paint": 4, "mesh": ""},
	"angular": {"paint": 5, "mesh": ""},
	"classic": {"paint": 0, "mesh": "Hero_Brows"},
	"classic_straight": {"paint": 0, "mesh": "Hero_Brows_Regular"},
}
## The iris of the Quaternius eye texture: one disc in the middle.
const IRIS_CENTRE := Vector2(0.5, 0.5)
const IRIS_RADIUS := 0.105
## Looks.list("outfits") -> the mesh-name prefix of its parts.
const OUTFIT_PARTS := {"peasant": "Hero_Peasant_", "peasant_2": "Hero_Peasant_",
	"ranger": "Hero_Ranger_", "ranger_3": "Hero_Ranger_"}
## Per outfit: its texture (empty: the one in the model), the main cloth's
## colour and the dye's brightness; the dyed texels are mask_<outfit>.png
## (art/characters/hero_q/house_masks.py).
const OUTFIT_DIR := "res://assets/models/characters/outfits/"
const OUTFIT_LOOKS := {
	"peasant": {"texture": "", "key": Color("928b70"), "gain": 0.55},
	"peasant_2": {"texture": "T_Peasant_2_BaseColor.png", "key": Color("2e2416"), "gain": 0.55},
	"ranger": {"texture": "", "key": Color("3f5a22"), "gain": 0.75},
	"ranger_3": {"texture": "T_Ranger_3_BaseColor.png", "key": Color("5c5545"), "gain": 0.6},
}
## Height slider: +-5 % of the whole body (the skeleton scales, so props and
## sockets follow).
const LOOK_HEIGHT_SPAN := 0.05

## One dressed material per part surface, shared by every hero.
static var _dressed_materials := {}


## Put every hero part on the character layer and give each surface its look:
## skin, hair, eye and brow surfaces get the look shaders, cloth a little rim.
## Idempotent.
static func dress_parts(visuals: Node) -> void:
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var part := String(mi.name)
		if mi.layers & CHARACTER_LAYER == 0:
			set_character_layer(mi)
		if mi.mesh == null:
			continue
		for surface in range(mi.mesh.get_surface_count()):
			var source := mi.mesh.surface_get_material(surface)
			if not (source is StandardMaterial3D) or mi.get_surface_override_material(surface) != null:
				continue
			var key := "%s/%d" % [part, surface]
			if not _dressed_materials.has(key):
				_dressed_materials[key] = _dressed(part, source as StandardMaterial3D)
			mi.set_surface_override_material(surface, _dressed_materials[key])


static func _dressed(part: String, base: StandardMaterial3D) -> Material:
	if _is_skin(base):
		var skin := _shader_material(SKIN_SHADER, base)
		if part != "Hero_Head":
			# the arms match the MakeHuman face (face/head_albedo.png's mean
			# skin over the kit's arm texture's, linear)
			skin.set_shader_parameter("face_tone", true)
			skin.set_shader_parameter("tone_match", ARM_TONE_MATCH)
		skin.set_shader_parameter("has_normal", base.normal_enabled and base.normal_texture != null)
		if base.roughness_texture != null:
			skin.set_shader_parameter("roughness_tex", base.roughness_texture)
			skin.set_shader_parameter("has_roughness", true)
		if ResourceLoader.exists(SKIN_MICRO):
			skin.set_shader_parameter("micro_tex", load(SKIN_MICRO))
			skin.set_shader_parameter("has_micro", true)
		# only the head carries the scalp masks and the beard areas
		skin.set_shader_parameter("has_scalp", part == "Hero_Head")
		if part == "Hero_Head":
			skin.set_shader_parameter("scalp_tex", _scalp_array())
		if part == "Hero_Head" and ResourceLoader.exists(FACE_MASKS):
			skin.set_shader_parameter("face_mask_tex", load(FACE_MASKS))
			skin.set_shader_parameter("grain_tex", load(SKIN_GRAIN))
			skin.set_shader_parameter("has_face", true)
		return skin
	if part.begins_with("Hero_Hair_") or part.begins_with("Hero_Beard_"):
		var hair := _shader_material(HAIR_SHADER, base)
		var luma := TEMPLE_REF_LUMA if part.ends_with("_Temple") else float(HAIR_REF_LUMA.get(part.trim_prefix("Hero_").trim_prefix("Hair_"), 0.28))
		hair.set_shader_parameter("ref_luma", luma)
		return hair
	if part == "Hero_Eyes":
		var eye := _shader_material(EYE_SHADER, base)
		eye.set_shader_parameter("iris_a", IRIS_CENTRE)
		eye.set_shader_parameter("iris_b", IRIS_CENTRE)
		eye.set_shader_parameter("iris_radius", IRIS_RADIUS)
		if ResourceLoader.exists(EYE_IRIS):
			eye.set_shader_parameter("iris_tex", load(EYE_IRIS))
			eye.set_shader_parameter("has_iris", true)
		return eye
	if part == "Hero_BrowPaint":
		return _shader_material(BROW_PAINT_SHADER, base)
	if part.begins_with("Hero_Brows"):
		return _shader_material(BROW_SHADER, base)
	for outfit: String in OUTFIT_PARTS:
		if part.begins_with(String(OUTFIT_PARTS[outfit])):
			return _cloth_material(base, outfit)
	var cloth := base.duplicate() as StandardMaterial3D
	cloth.rim_enabled = true
	cloth.rim = CLOTH_RIM
	cloth.rim_tint = CLOTH_RIM_TINT
	return cloth


## The scalp masks of Looks.list("hair_styles") as layers in style order (layer
## = style index); "none", or a style without a mask file, gets an empty layer.
static func _scalp_array() -> Texture2DArray:
	if _scalp_masks != null:
		return _scalp_masks
	var images: Array[Image] = []
	var size := 512
	for style: String in Looks.list("hair_styles"):
		var path := SCALP_DIR + "scalp_%s.png" % style
		var img: Image = null
		if style != "none" and ResourceLoader.exists(path):
			img = (load(path) as Texture2D).get_image()
			if img.is_compressed():
				img.decompress()
			size = img.get_width()
		else:
			img = Image.create(size, size, false, Image.FORMAT_L8)
		img.convert(Image.FORMAT_L8)
		if img.get_width() != size:
			img.resize(size, size)
		if not img.has_mipmaps():
			img.generate_mipmaps()
		images.append(img)
	_scalp_masks = Texture2DArray.new()
	_scalp_masks.create_from_images(images)
	return _scalp_masks


## The cloth material of `outfit`'s texture variant over the model's own one.
static func _cloth_material(base: StandardMaterial3D, outfit: String) -> ShaderMaterial:
	var look: Dictionary = OUTFIT_LOOKS[outfit]
	var mat := _shader_material(CLOTH_SHADER, base)
	if String(look["texture"]) != "":
		mat.set_shader_parameter("albedo_tex", load(OUTFIT_DIR + String(look["texture"])))
	mat.set_shader_parameter("mask_tex", load(OUTFIT_DIR + "mask_%s.png" % outfit))
	mat.set_shader_parameter("has_normal", base.normal_enabled and base.normal_texture != null)
	mat.set_shader_parameter("key_color", look["key"])
	mat.set_shader_parameter("house_gain", float(look["gain"]))
	mat.set_shader_parameter("rim_amount", CLOTH_RIM)
	return mat


## Put `outfit`'s cloth material on a visible outfit part (its skin surfaces
## keep the skin shader).
static func _wear_variant(mi: MeshInstance3D, part: String, outfit: String) -> void:
	for surface in range(mi.mesh.get_surface_count()):
		var source := mi.mesh.surface_get_material(surface)
		if not (source is StandardMaterial3D) or _is_skin(source):
			continue
		var key := "%s/%d/%s" % [part, surface, outfit]
		if not _dressed_materials.has(key):
			_dressed_materials[key] = _cloth_material(source as StandardMaterial3D, outfit)
		mi.set_surface_override_material(surface, _dressed_materials[key])


static func _is_skin(material: Material) -> bool:
	for name: String in SKIN_MATERIALS:
		if String(material.resource_name).begins_with(name):
			return true
	return false


static func _shader_material(shader: Shader, base: StandardMaterial3D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("albedo_tex", base.albedo_texture)
	if base.normal_enabled and base.normal_texture != null:
		mat.set_shader_parameter("normal_tex", base.normal_texture)
	return mat


## ---------------------------------------------------------------- look

## Draw `look` (Looks.clean_look) on the hero under `visuals`: the outfit and
## hairstyle (which meshes show), hair/skin/eye colours (instance uniforms of
## the look shaders) and the height. Cheap enough to call on every change; a
## remote body gets it with each player info.
static func apply_look(visuals: Node, raw_look: Dictionary) -> void:
	if visuals == null:
		return
	dress_parts(visuals)
	var look := Looks.clean_look(raw_look)
	var style := String(Looks.list("hair_styles")[int(look["hair"])])
	var outfit := String(Looks.list("outfits")[int(look["outfit"])])
	var hair := Color.html(Looks.list("hair_colors")[int(look["hair_color"])])
	var skin := Color.html(Looks.list("skin_tones")[int(look["skin"])])
	var iris := Color.html(Looks.list("eye_colors")[int(look["eyes"])])
	var beard: Dictionary = BEARDS[String(Looks.list("beards")[int(look["beard"])])]
	var brows: Dictionary = BROWS[String(Looks.list("brows")[int(look["brows"])])]
	var scalp_layer := -1.0 if style == "none" else float(Looks.list("hair_styles").find(style))
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var part := String(mi.name)
		if part.begins_with("Hero_Hair_"):
			mi.visible = part == "Hero_Hair_" + style or part == "Hero_Hair_" + style + "_Temple"
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part == "Hero_Eyes":
			mi.set_instance_shader_parameter("iris_color", iris)
		elif part.begins_with("Hero_Beard_"):
			mi.visible = part == String(beard["mesh"])
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part == "Hero_BrowPaint":
			mi.visible = int(brows["paint"]) > 0
			# blended, it still casts shadows as if opaque: the band over the
			# brows shadowed the upper eyelids dark
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_instance_shader_parameter("brow_paint", float(brows["paint"]))
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part.begins_with("Hero_Brows"):
			mi.visible = part == String(brows["mesh"])
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part == "Hero_Head":
			mi.set_instance_shader_parameter("hair_color", hair)
			mi.set_instance_shader_parameter("scalp_layer", scalp_layer)
			mi.set_instance_shader_parameter("beard_shade", float(beard["shade"]))
			# tuck_<style>: the ears drawn under a style's locks (build_rig.py)
			var head_mesh := mi.mesh as ArrayMesh
			for shape in range(mi.get_blend_shape_count() if head_mesh != null else 0):
				var shape_name := String(head_mesh.get_blend_shape_name(shape))
				if shape_name.begins_with("tuck_"):
					mi.set_blend_shape_value(shape, 1.0 if shape_name == "tuck_" + style else 0.0)
		var worn := String(OUTFIT_PARTS[outfit])
		for other: String in OUTFIT_PARTS.values():
			if part.begins_with(other):
				mi.visible = part.begins_with(worn)
				if mi.visible:
					_wear_variant(mi, part, outfit)
		if part == "Hero_Head" or part.ends_with("_Arms"):
			mi.set_instance_shader_parameter("skin_tint", skin)
	var brow_name := String(Looks.list("brows")[int(look["brows"])])
	var drawn := drawn_style(style)
	var face_skeleton := _skeleton(visuals)
	if face_skeleton != null and face_skeleton.has_node("Face_Head"):
		for hair_mesh in _wear_cards(face_skeleton, drawn, "Hair", true):
			hair_mesh.set_instance_shader_parameter("hair_color", hair)
		for beard_mesh in _wear_cards(face_skeleton, String(beard["mesh"]), "Beard", false):
			beard_mesh.set_instance_shader_parameter("hair_color", hair)
	for node in visuals.find_children("Face_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var part := String(mi.name)
		if part == "Face_Head":
			var head_mat := _head_material(drawn, String(Looks.list("beards")[int(look["beard"])]))
			for surface in range(mi.mesh.get_surface_count()):
				if mi.get_surface_override_material(surface) != head_mat:
					mi.set_surface_override_material(surface, head_mat)
			mi.set_instance_shader_parameter("skin_tint", skin)
			mi.set_instance_shader_parameter("hair_color", hair)
			mi.set_instance_shader_parameter("beard_shade", float(beard["shade"]))
		elif part == "Face_Eyeball":
			mi.set_instance_shader_parameter("iris_color", iris)
		elif part.begins_with("Face_Brow_"):
			mi.visible = part == "Face_Brow_" + brow_name
			# brows sit a shade darker than light hair (white brows glowed)
			mi.set_instance_shader_parameter("hair_color", hair.darkened(clampf(hair.get_luminance() * 0.6, 0.0, 0.5)))
		elif part == "Face_Lashes":
			# lashes are darker than the hair, the more so the lighter it is
			mi.set_instance_shader_parameter("hair_color", hair.darkened(minf(0.55 + 0.35 * hair.get_luminance(), 0.88)))
	var skeleton := _skeleton(visuals)
	if skeleton != null:
		skeleton.scale = Vector3.ONE * (1.0 + LOOK_HEIGHT_SPAN * float(look.get("height", 0.0)))
	# face sliders: face_<key>_neg / _pos shape keys on the head and the parts
	# on the face (art/characters/hero_q/face_morphs.py)
	for node in visuals.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.get_blend_shape_count() == 0:
			continue
		var new_head := String(mi.name).begins_with("Face_") or String(mi.name).begins_with("Hair") \
				or String(mi.name).begins_with("Beard")
		for key: String in Looks.sliders():
			if key == "height":
				continue
			var v := float(look.get(key, 0.0)) * (FACE_KEY_GAIN if new_head else FACE_SLIDER_GAIN)
			var neg := mi.find_blend_shape_by_name("face_%s_neg" % key)
			var pos := mi.find_blend_shape_by_name("face_%s_pos" % key)
			if neg >= 0:
				mi.set_blend_shape_value(neg, maxf(0.0, -v))
			if pos >= 0:
				mi.set_blend_shape_value(pos, maxf(0.0, v))
		var face_type := String(Looks.list("faces")[int(look["face"])])
		for type_name: String in Looks.list("faces"):
			var k := mi.find_blend_shape_by_name("face_type_" + type_name)
			if k >= 0:
				# the new head's keys are baked at the type's weight already
				var on := 1.0 if new_head else FACE_TYPE_WEIGHT
				mi.set_blend_shape_value(k, on if type_name == face_type else 0.0)


## The looks of this machine's own characters, by character id, so the
## character screen can draw each one (the account service's list carries no
## quests). Written whenever a look is known: the world join (the server's
## look) and the character screen (`pending`: picked here, not yet sent - the
## next world join sends it). Only a pending look is ever sent, so a stale
## entry on another machine can never overwrite the saved one.
const LOOK_CACHE := "user://character_looks.json"

static func remember_look(character_id: int, look: Dictionary, pending := false) -> void:
	if character_id <= 0:
		return
	var all := _read_look_cache()
	all[str(character_id)] = {"look": Looks.clean_look(look), "pending": pending}
	var file := FileAccess.open(LOOK_CACHE, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(all))

static func recall_look(character_id: int) -> Dictionary:
	var entry = _read_look_cache().get(str(character_id), {})
	return Looks.clean_look(entry.get("look", {}) if entry is Dictionary else {})

static func has_pending_look(character_id: int) -> bool:
	var entry = _read_look_cache().get(str(character_id), {})
	return entry is Dictionary and bool(entry.get("pending", false))

static func _read_look_cache() -> Dictionary:
	if not FileAccess.file_exists(LOOK_CACHE):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(LOOK_CACHE))
	return parsed if parsed is Dictionary else {}


## Put every mesh under `root` (itself included) on the character layer.
##
## A mesh must get its layers BEFORE it enters the world: the renderer pairs it
## with the lights whose cull mask it matches when it enters, and a later layer
## change never re-pairs it - freeing it then printed "BUG, indexing did not
## unpair geometries from light" (Godot 4.7; a Label3D swaps its base with every
## text change, so a creature's health label printed it on each hit). A mesh
## already in the world is taken out and put back so it pairs afresh. Bodies
## call this from their _enter_tree, when their children have not entered yet.
static func set_character_layer(root: Node) -> void:
	var meshes: Array = root.find_children("*", "GeometryInstance3D", true, false)
	if root is GeometryInstance3D:
		meshes.append(root)
	for node in meshes:
		var gi := node as GeometryInstance3D
		# Labels and sprites change their base as their text or frame changes;
		# they take no light anyway, so they stay off the layer.
		if gi is Label3D or gi is SpriteBase3D or gi.layers & CHARACTER_LAYER != 0:
			continue
		if gi.is_inside_tree():
			var parent := gi.get_parent()
			var index := gi.get_index()
			parent.remove_child(gi)
			gi.layers |= CHARACTER_LAYER
			parent.add_child(gi)
			parent.move_child(gi, index)
		else:
			gi.layers |= CHARACTER_LAYER

## Attach the character fill to `camera` (once) and return it.
static func add_character_fill(camera: Camera3D) -> DirectionalLight3D:
	var existing := camera.get_node_or_null("CharacterFill")
	if existing is DirectionalLight3D:
		return existing
	var fill := DirectionalLight3D.new()
	fill.name = "CharacterFill"
	fill.light_cull_mask = CHARACTER_LAYER
	fill.light_energy = FILL_ENERGY
	fill.light_color = FILL_COLOR
	fill.shadow_enabled = false
	# No specular from the fill: a highlight that follows the camera is what made
	# the face look wet and plastic. Lift it from above-left so the face keeps
	# its modelling instead of being flattened by a light on the view axis.
	fill.light_specular = 0.0
	# A light for the characters, not a second sun in the sky.
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	fill.rotation_degrees = Vector3(-32, 28, 0)
	camera.add_child(fill)
	_add_character_rim(camera)
	return fill


## A cool light from behind the characters toward the camera (above and a
## little to the side), on the character layer only: it draws a thin bright
## edge round the hair, the shoulders and the face, the separation light
## every character close-up in a modern MMO has. Shadowless; the world is not
## lit by it. Its energy follows the fill (DayNight sets the fill).
const RIM_SHARE := 0.75
const RIM_COLOR := Color(0.82, 0.88, 1.0)

static func _add_character_rim(camera: Camera3D) -> DirectionalLight3D:
	var existing := camera.get_node_or_null("CharacterRim")
	if existing is DirectionalLight3D:
		return existing
	var rim := DirectionalLight3D.new()
	rim.name = "CharacterRim"
	rim.light_cull_mask = CHARACTER_LAYER
	rim.light_energy = FILL_ENERGY * RIM_SHARE * 2.0
	rim.light_color = RIM_COLOR
	rim.light_specular = 0.5
	rim.shadow_enabled = false
	rim.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	# travelling toward the camera (+Z in its space), down and across
	rim.transform.basis = Basis.looking_at(Vector3(-0.35, -0.6, 1.0).normalized(), Vector3.UP)
	camera.add_child(rim)
	return rim


## The camera's rim light (made with the fill), or null.
static func character_rim(camera: Camera3D) -> DirectionalLight3D:
	return camera.get_node_or_null("CharacterRim") as DirectionalLight3D if camera != null else null


## The body's animation player, wherever the importer put it.
static func find_anim_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	var found := node.find_child("AnimationPlayer", true, false)
	if found is AnimationPlayer:
		return found as AnimationPlayer
	return null
