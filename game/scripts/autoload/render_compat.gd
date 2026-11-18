extends Node

## RenderCompat autoload - what one graphics driver cannot compile.
##
## Mesa's NVK (the open Vulkan driver for NVIDIA cards) has a shader compiler,
## NAK, that panics on a derivative of a 16-bit float (from_nir.rs asserts
## `bit_size == 32` on ddx/ddy, Mesa 26 and its main branch alike), and the
## pipeline is then lost: the leaves, flowers and far trees using it stutter
## and fill the log (issue semdin/realm#1: 29 panics on a GTX 1660 Ti).
##
## Godot's Mobile renderer shades in 16 bits wherever the device offers them;
## no project setting changes that (SceneShaderForwardMobile::use_fp16 follows
## the device's features alone, and NVK offers shaderFloat16 from shader model
## 7 up). Of its derivatives (Godot 4.8 beta 3) exactly one takes a 16-bit
## value: the fwidth() in compute_alpha_antialiasing_edge
## (scene_forward_aa_inc.glsl). A shader gets that code when it writes
## ALPHA_ANTIALIASING_EDGE or ALPHA_TEXTURE_COORDINATE; a BaseMaterial3D writes
## both when its alpha antialiasing is on.
##
## So on NVK, and only there, nothing reaches the renderer with them: the
## materials fall back to their plain alpha scissor (the game runs without
## MSAA, so the edge they lose is slight). Every other driver never enters
## this code. What is cleaned is the shared resource itself, before its first
## draw: the materials of whatever enters the scene tree, and Terrain3D's mesh
## assets, which it draws without nodes (GroundsTerrain hands them over).
##
## `-- --assume-nvk` takes this path on any machine (checks).

const ASSUME_ARG := "--assume-nvk"

## The adapter is NVK (or the run assumes it).
var nvk := false

var _done: Dictionary[int, bool] = {}
var _late: Array = []
var _materials := 0
var _shaders := 0
var _reported := 0
var _shader_writes: RegEx
var _shader_modes: Array[RegEx] = []


func _enter_tree() -> void:
	var adapter := RenderingServer.get_video_adapter_name()
	nvk = adapter.contains("NVK") or OS.get_cmdline_user_args().has(ASSUME_ARG)
	if not nvk:
		return
	print("realm: NVK path on '%s': no alpha edge antialiasing" % adapter)
	_shader_writes = RegEx.create_from_string("\\bALPHA_(?:ANTIALIASING_EDGE|TEXTURE_COORDINATE)\\s*=[^;]*;")
	for pattern in [
		",\\s*alpha_to_coverage(?:_and_one)?\\b",
		"\\balpha_to_coverage(?:_and_one)?\\s*,\\s*",
		"\\brender_mode\\s+alpha_to_coverage(?:_and_one)?\\s*;",
	]:
		_shader_modes.append(RegEx.create_from_string(pattern))
	get_tree().node_added.connect(_on_node_added)


## Terrain3D's mesh assets: their meshes are drawn without nodes.
func clean_terrain_assets(assets: Terrain3DAssets) -> void:
	if not nvk or assets == null:
		return
	for i in assets.get_mesh_count():
		var asset := assets.get_mesh_asset(i)
		if asset == null:
			continue
		_clean_material(asset.material_override)
		_clean_material(asset.material_overlay)
		for lod in asset.get_lod_count():
			_clean_mesh(asset.get_mesh(lod))
	_report()


func _on_node_added(node: Node) -> void:
	if not node is GeometryInstance3D:
		return
	_clean_node(node)
	# Its mesh or material may be set right after add_child: look again before
	# the frame is drawn.
	if _late.is_empty():
		_clean_late.call_deferred()
	_late.append(node)


func _clean_late() -> void:
	for node in _late:
		if is_instance_valid(node):
			_clean_node(node)
	_late.clear()
	_report()


func _clean_node(node: GeometryInstance3D) -> void:
	_clean_material(node.material_override)
	_clean_material(node.material_overlay)
	if node is MeshInstance3D:
		_clean_mesh(node.mesh)
		for i in node.get_surface_override_material_count():
			_clean_material(node.get_surface_override_material(i))
	elif node is MultiMeshInstance3D:
		if node.multimesh != null:
			_clean_mesh(node.multimesh.mesh)
	elif node is GPUParticles3D:
		for i in node.draw_passes:
			_clean_mesh(node.get_draw_pass_mesh(i))
	elif node is CPUParticles3D:
		_clean_mesh(node.mesh)
	elif node is SpriteBase3D or node is Label3D:
		if node.alpha_antialiasing_mode != BaseMaterial3D.ALPHA_ANTIALIASING_OFF:
			node.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_OFF


func _clean_mesh(mesh: Mesh) -> void:
	if mesh == null or _done.has(mesh.get_instance_id()):
		return
	_done[mesh.get_instance_id()] = true
	for i in mesh.get_surface_count():
		_clean_material(mesh.surface_get_material(i))


func _clean_material(material: Material) -> void:
	while material != null and not _done.has(material.get_instance_id()):
		_done[material.get_instance_id()] = true
		if material is BaseMaterial3D:
			if material.alpha_antialiasing_mode != BaseMaterial3D.ALPHA_ANTIALIASING_OFF:
				material.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_OFF
				_materials += 1
		elif material is ShaderMaterial and material.shader != null:
			_clean_shader(material.shader)
		material = material.next_pass


## The shader without the edge: its two writes go, and alpha to coverage with
## them (it would move the surface to the transparent pass), as a BaseMaterial3D
## with the antialiasing off has neither.
func _clean_shader(shader: Shader) -> void:
	if _done.has(shader.get_instance_id()):
		return
	_done[shader.get_instance_id()] = true
	var code := _shader_writes.sub(shader.code, "", true)
	if code == shader.code:
		return
	for mode in _shader_modes:
		code = mode.sub(code, "", true)
	shader.code = code
	_shaders += 1


func _report() -> void:
	if _materials + _shaders != _reported:
		_reported = _materials + _shaders
		print("realm: NVK path: alpha edge off on %d materials, %d shaders" % [_materials, _shaders])
