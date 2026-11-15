extends Control
class_name HudDuel

## The local player's duel (the old game's approved duel view), drawn from the
## server's "duel" game events (RealmSession.take_game_events):
##   - the countdown (3, 2, 1, Fight!) in the middle of the screen;
##   - a plaque on the right rail: the two sides (beaten duelists struck
##     through) and the time left;
##   - the arena: a glowing wall round the circle the server judges, amber
##     during the countdown and red in the fight, with a warning when the
##     player nears its edge (leaving it loses the duel);
##   - red names over the standing foes, grey over the beaten;
##   - the result banner (Victory / Defeat / Draw) and a chat line.
## Everything here is presentation: who may hit whom, the 1 health rule and
## the arena check are the server's (realm_server sim/duel.rs). Times are
## server ticks (`fight_tick`, `end_tick`) read against
## RealmSession.server_tick() when the event lands.

const ARENA_HEIGHT := 7.0
const WARN_MARGIN := 7.0
## The marks HeroView.set_duel_mark draws.
const MARK_NONE := 0
const MARK_FOE := 1
const MARK_OUT := 2
const AMBER := Color(1.0, 0.78, 0.36)
const EMBER := Color(1.0, 0.36, 0.26)

var session: Node
## The player's own hero (the edge warning, where the arena goes) and the
## other players' heroes by entity (main.gd's `heroes`, for the marks).
var player: Node3D = null
var heroes: Dictionary = {}
## The HUD's chat sink: add_system_line(text).
var chat_sink: Callable

var _state: Dictionary = {}
var _duel_id := 0
var _fight_at_ms := 0
var _ends_at_ms := 0
var _fight_shown := false
var _last_count := -1
var _marked: Dictionary = {}   # entity -> the hero it was set on
var _mark_check_ms := 0
var _arena: MeshInstance3D = null
var _arena_mat: ShaderMaterial = null

var _count: Label
var _plaque: PanelContainer
var _plaque_title: Label
var _plaque_time: Label
var _plaque_sides: RichTextLabel
var _warn: Label
var _banner: Control
var _banner_title: Label
var _banner_sub: Label
var _banner_tween: Tween

## What it showed, for the checks: every countdown pop in order, the last
## result ({result, reason, title, sub}) and how many duels it drew.
var pops_shown: PackedStringArray = []
var last_result: Dictionary = {}
var duels_shown := 0

## The wall: its soft glow fades upward from a bright band near the ground,
## breathing in broad bands round the circle; a slow noise drifting through
## it keeps the bands from reading as ruled stripes.
const ARENA_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add, shadows_disabled, fog_disabled;
uniform vec4 tint : source_color = vec4(1.0, 0.36, 0.26, 1.0);
uniform float strength = 0.36;
uniform float height = 7.0;
uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
varying float h01;
void vertex() {
	h01 = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}
void fragment() {
	float fade = pow(1.0 - h01, 1.8);
	float runes = 0.62 + 0.38 * sin(UV.x * 6.2831 * 64.0 + TIME * 1.6);
	float sweep = 0.75 + 0.25 * sin(UV.x * 6.2831 * 3.0 - TIME * 0.9);
	float rim = smoothstep(0.0, 0.05, h01) * (1.0 + 2.2 * smoothstep(0.10, 0.0, abs(h01 - 0.16)));
	vec2 drift = vec2(UV.x * 24.0 + TIME * 0.025, h01 * 0.9 - TIME * 0.06);
	float mist = texture(noise, drift).r * 0.6 + texture(noise, drift * 2.3 + vec2(0.37, TIME * 0.04)).r * 0.4;
	ALBEDO = tint.rgb;
	ALPHA = clamp(fade * runes * sweep * rim * strength * (0.55 + 0.75 * mist), 0.0, 1.0);
}
"""

func _init() -> void:
	name = "Duel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()

## A duel is on (countdown or fight) for the local player.
func active() -> bool:
	return _duel_id != 0

## The fight is on (the countdown is over).
func fighting() -> bool:
	return _duel_id != 0 and int(_state.get("phase", 0)) == 1

## Player `entity` is a standing foe in the local player's duel.
func is_foe(entity: int) -> bool:
	if _duel_id == 0 or entity == 0 or _out().has(entity):
		return false
	for foe: Dictionary in _state.get("foes", []):
		if int(foe.get("entity", 0)) == entity:
			return true
	return false

## The standing foes' entities.
func foes_standing() -> Array:
	var out: Array = []
	for foe: Dictionary in _state.get("foes", []):
		if is_foe(int(foe.get("entity", 0))):
			out.append(int(foe["entity"]))
	return out

## The duel as the server last said it ({} when none is on).
func state() -> Dictionary:
	return _state

## The arena wall while a duel is on (null otherwise).
func arena() -> MeshInstance3D:
	return _arena if _arena != null and is_instance_valid(_arena) else null

func plaque_visible() -> bool:
	return _plaque.visible

func plaque_time() -> String:
	return _plaque_time.text

func plaque_sides() -> String:
	return _plaque_sides.get_parsed_text().replace("\n", " ")

func banner_visible() -> bool:
	return _banner.visible

func edge_warning_visible() -> bool:
	return _warn.visible

func _own() -> int:
	return int(session.own_entity()) if session != null else 0

func _out() -> PackedInt32Array:
	var out: Variant = _state.get("out", PackedInt32Array())
	return out if out is PackedInt32Array else PackedInt32Array(out)

# ------------------------------------------------------------------ state

## A "duel" game event: the duel opened, moved on (the fight began, someone
## went out), ended, or a challenge was declined.
func on_event(event: Dictionary) -> void:
	var id := int(event.get("duel", 0))
	if id == 0:
		if String(event.get("declined_by", "")) != "":
			_chat(tr("%s declined your duel.") % String(event["declined_by"]))
		elif String(event.get("result", "")) != "":
			_finish(event)
		return
	var now := Time.get_ticks_msec()
	var server_now: float = session.server_tick() if session != null else -1.0
	var hz := float(RealmInfo.sim_hz())
	var fight_in := 0.0
	var ends_in := 0.0
	if server_now >= 0.0:
		fight_in = maxf(0.0, (float(event.get("fight_tick", 0)) - server_now) / hz)
		ends_in = maxf(0.0, (float(event.get("end_tick", 0)) - server_now) / hz)
	if id != _duel_id:
		_duel_id = id
		_fight_shown = false
		_last_count = -1
		duels_shown += 1
		_build_arena(event.get("center", Vector3.ZERO), float(event.get("radius", 40.0)))
		_chat(tr("Duel accepted - the fight begins in %d seconds. Leaving the circle loses the duel.") % int(ceil(fight_in)))
	var was_out := _out().has(_own())
	_state = event
	_fight_at_ms = now + int(fight_in * 1000.0)
	_ends_at_ms = now + int(ends_in * 1000.0)
	if int(event.get("phase", 0)) == 1 and not _fight_shown:
		_show_fight()
	if not was_out and _out().has(_own()) and _allies_standing() > 0:
		_chat(tr("You are out of the duel - your side fights on."))
	_apply_marks()
	_refresh_plaque()
	_plaque.visible = true
	if _arena_mat != null:
		_arena_mat.set_shader_parameter("tint", EMBER if int(event.get("phase", 0)) == 1 else AMBER)

## The player's allies (the player left out) still standing: a side that has
## none left loses as soon as the server checks.
func _allies_standing() -> int:
	var out := _out()
	var count := 0
	for ally: Dictionary in _state.get("allies", []):
		var id := int(ally.get("entity", 0))
		if id != _own() and not out.has(id):
			count += 1
	return count

func _finish(event: Dictionary) -> void:
	_duel_id = 0
	_state = {}
	_count.visible = false
	_plaque.visible = false
	_warn.visible = false
	_clear_marks()
	_free_arena()
	var result := String(event.get("result", "draw"))
	var sub := _result_line(event)
	var title := tr("Victory") if result == "won" else (tr("Defeat") if result == "lost" else tr("Draw"))
	var colour := HudKit.GOLD_HI if result == "won" else (Color(1.0, 0.40, 0.34) if result == "lost" else HudKit.PARCHMENT)
	_show_banner(I18n.upper(title), sub, colour)
	if result == "won":
		AudioManager.play_stinger("stinger_victory")
	else:
		AudioManager.play_sound_at("ui_upgrade_fail" if result == "lost" else "ui_confirm", Vector3.ZERO, null, true)
	var head := tr("Duel won") if result == "won" else (tr("Duel lost") if result == "lost" else tr("Duel drawn"))
	_chat("%s: %s" % [head, sub])
	last_result = {"result": result, "reason": String(event.get("reason", "")), "title": _banner_title.text, "sub": sub}

func _names(list: Array) -> String:
	var out: PackedStringArray = []
	for entry in list:
		out.append(String((entry as Dictionary).get("name", "?")))
	return ", ".join(out)

## How the duel ended, from the local player's side.
func _result_line(event: Dictionary) -> String:
	var me := String((session.sheet() as Dictionary).get("name", "")) if session != null else ""
	var last := String(event.get("last", ""))
	var by := String(event.get("by", ""))
	var group := bool(event.get("group", false))
	var result := String(event.get("result", "draw"))
	match String(event.get("reason", "")):
		"defeat":
			if group:
				return tr("Your party won the group duel.") if result == "won" else tr("Your party lost the group duel.")
			return tr("You defeated %s.") % last if result == "won" else tr("%s defeated you.") % (by if by != "" else _names(event.get("foes", [])))
		"fled":
			return tr("You left the duel circle.") if last == me else tr("%s left the duel circle.") % last
		"left":
			return tr("%s left the game.") % last
		"yield":
			return tr("You yielded.") if last == me else tr("%s yielded.") % last
		"died":
			return tr("You died.") if last == me else tr("%s died.") % last
		"timeout":
			return tr("Time ran out.")
	return tr("The duel is over.")

# ------------------------------------------------------------------ frame

func _process(_delta: float) -> void:
	if _duel_id == 0:
		return
	var now := Time.get_ticks_msec()
	# The countdown: whole seconds to the first blow, then "Fight!".
	if int(_state.get("phase", 0)) == 0:
		var left := int(ceil(float(_fight_at_ms - now) / 1000.0))
		if left > 0 and left != _last_count:
			_last_count = left
			_pop_count(str(left), HudKit.GOLD_HI)
			AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)
		elif left <= 0 and not _fight_shown:
			_show_fight()   # the server's fight phase follows within a few ticks
	var secs := maxi(0, int(ceil(float(_ends_at_ms - now) / 1000.0)))
	_plaque_time.text = "%d:%02d" % [secs / 60, secs % 60]
	# The edge of the arena.
	var near_edge := false
	if is_instance_valid(player) and _state.has("center"):
		var c: Vector3 = _state["center"]
		var p := player.global_position
		var d := Vector2(p.x - c.x, p.z - c.z).length()
		near_edge = d > float(_state.get("radius", 40.0)) - WARN_MARGIN and not _out().has(_own())
	_warn.visible = near_edge
	if near_edge:
		_warn.modulate.a = 0.6 + 0.4 * sin(now * 0.012)
	# Foe bodies that came into view after the last event get their marks.
	if now >= _mark_check_ms:
		_mark_check_ms = now + 500
		_apply_marks()

func _show_fight() -> void:
	_fight_shown = true
	_pop_count(I18n.upper(tr("Fight!")), Color(1.0, 0.44, 0.32), 1.1)
	AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

# ------------------------------------------------------------------ marks

func _apply_marks() -> void:
	var out := _out()
	for foe: Dictionary in _state.get("foes", []):
		var id := int(foe.get("entity", 0))
		var hero: Node = heroes.get(id)
		if hero == null or not is_instance_valid(hero):
			continue
		hero.set_duel_mark(MARK_OUT if out.has(id) else MARK_FOE, String(foe.get("name", "")))
		_marked[id] = hero

func _clear_marks() -> void:
	for id in _marked:
		var hero: Node = _marked[id]
		if hero != null and is_instance_valid(hero):
			hero.set_duel_mark(MARK_NONE)
	_marked.clear()

# ------------------------------------------------------------------ arena

func _build_arena(center: Vector3, radius: float) -> void:
	_free_arena()
	if not is_instance_valid(player) or player.get_parent() == null:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = ARENA_HEIGHT
	mesh.radial_segments = 96
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	var shader := Shader.new()
	shader.code = ARENA_SHADER
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.noise = noise
	_arena_mat = ShaderMaterial.new()
	_arena_mat.shader = shader
	_arena_mat.set_shader_parameter("height", ARENA_HEIGHT)
	_arena_mat.set_shader_parameter("tint", AMBER)
	_arena_mat.set_shader_parameter("noise", texture)
	_arena = MeshInstance3D.new()
	_arena.name = "DuelArena"
	_arena.mesh = mesh
	_arena.material_override = _arena_mat
	_arena.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	player.get_parent().add_child(_arena)
	# A metre and a half into the ground, so slopes inside the circle still meet it.
	_arena.global_position = center + Vector3(0, ARENA_HEIGHT * 0.5 - 1.5, 0)

func _free_arena() -> void:
	if _arena != null and is_instance_valid(_arena):
		_arena.queue_free()
	_arena = null
	_arena_mat = null

func _exit_tree() -> void:
	_free_arena()

# ------------------------------------------------------------------ widgets

func _build() -> void:
	_count = HudKit.label("", 96, HudKit.GOLD_HI, HudKit.deco(), 10)
	_count.name = "Countdown"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count.set_anchors_preset(Control.PRESET_CENTER)
	_count.custom_minimum_size = Vector2(700, 140)
	_count.offset_left = -350
	_count.offset_right = 350
	_count.offset_top = -190
	_count.offset_bottom = -50
	_count.pivot_offset = Vector2(350, 70)
	_count.visible = false
	add_child(_count)

	_plaque = PanelContainer.new()
	_plaque.name = "DuelPlaque"
	_plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.040, 0.067, 0.92)
	box.border_color = Color(1.0, 0.40, 0.32).lerp(HudKit.GOLD, 0.5)
	box.set_border_width_all(1)
	box.border_width_bottom = 2
	box.set_corner_radius_all(8)
	box.shadow_color = Color(0, 0, 0, 0.5)
	box.shadow_size = 8
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 6
	box.content_margin_bottom = 8
	_plaque.add_theme_stylebox_override("panel", box)
	# The right rail under the minimap: the top centre belongs to the target
	# card and the notice band, which a duel crosses often.
	_plaque.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_plaque.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_plaque.offset_right = -UITheme.EDGE
	_plaque.offset_left = -UITheme.EDGE - UITheme.RIGHT_COL_W
	_plaque.offset_top = 272
	_plaque.visible = false
	add_child(_plaque)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plaque.add_child(column)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(top)
	_plaque_title = HudKit.label("", 14, Color(1.0, 0.62, 0.50), HudKit.title(), 4)
	_plaque_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_plaque_title)
	_plaque_time = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.bold(), 3)
	top.add_child(_plaque_time)
	var rule := ColorRect.new()
	rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.4)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)
	_plaque_sides = RichTextLabel.new()
	_plaque_sides.bbcode_enabled = true
	_plaque_sides.fit_content = true
	_plaque_sides.scroll_active = false
	_plaque_sides.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plaque_sides.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plaque_sides.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W - 32, 0)
	_plaque_sides.add_theme_font_override("normal_font", HudKit.bold())
	_plaque_sides.add_theme_font_size_override("normal_font_size", 15)
	_plaque_sides.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_plaque_sides.add_theme_constant_override("outline_size", UITheme.outline_for(15, 3))
	column.add_child(_plaque_sides)

	_warn = HudKit.label(tr("Stay inside the duel circle - leaving it loses the duel!"), 18, Color(1.0, 0.42, 0.34), HudKit.bold(), 5)
	_warn.name = "DuelEdgeWarning"
	_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warn.set_anchors_preset(Control.PRESET_CENTER)
	_warn.offset_left = -360
	_warn.offset_right = 360
	_warn.offset_top = 40
	_warn.offset_bottom = 70
	_warn.visible = false
	add_child(_warn)

	_banner = VBoxContainer.new()
	_banner.name = "DuelResult"
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.offset_left = -400
	_banner.offset_right = 400
	_banner.offset_top = -220
	_banner.offset_bottom = -90
	_banner.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner.add_theme_constant_override("separation", 4)
	_banner.visible = false
	add_child(_banner)
	_banner_title = HudKit.label("", 72, HudKit.GOLD_HI, HudKit.deco(), 10)
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_title)
	var underline := ColorRect.new()
	underline.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.7)
	underline.custom_minimum_size = Vector2(360, 2)
	underline.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_banner.add_child(underline)
	_banner_sub = HudKit.label("", 20, HudKit.PARCHMENT, HudKit.bold(), 5)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_sub)

func _refresh_plaque() -> void:
	var group := bool(_state.get("group", false))
	_plaque_title.text = I18n.upper(tr("Group Duel") if group else tr("Duel"))
	var out := _out()
	var ally_col := Color(0.62, 0.84, 1.0).to_html(false)
	var foe_col := Color(1.0, 0.46, 0.38).to_html(false)
	var line := "[center]%s\n[color=#%s]%s[/color]\n%s[/center]" % [
		_side_text(_state.get("allies", []), out, ally_col), HudKit.GOLD.to_html(false),
		I18n.upper(tr("vs")), _side_text(_state.get("foes", []), out, foe_col)]
	_plaque_sides.text = line
	_plaque.reset_size()

func _side_text(list: Array, out: PackedInt32Array, colour: String) -> String:
	var parts: PackedStringArray = []
	for entry in list:
		var e := entry as Dictionary
		var who := String(e.get("name", "?")).replace("[", "[lb]")
		if out.has(int(e.get("entity", 0))):
			parts.append("[color=#7d7670][s]%s[/s][/color]" % who)
		else:
			parts.append("[color=#%s]%s[/color]" % [colour, who])
	return ", ".join(parts)

func _pop_count(text: String, colour: Color, hold := 0.8) -> void:
	pops_shown.append(text)
	_count.text = text
	_count.add_theme_color_override("font_color", colour)
	_count.visible = true
	_count.scale = Vector2(1.6, 1.6)
	_count.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(_count, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(hold * 0.6)
	tween.tween_property(_count, "modulate:a", 0.0, hold * 0.4)

func _show_banner(title: String, sub: String, colour: Color) -> void:
	_banner_title.text = title
	_banner_title.add_theme_color_override("font_color", colour)
	_banner_sub.text = sub
	_banner.visible = true
	_banner.modulate.a = 0.0
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.25)
	_banner_tween.tween_interval(3.2)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.6)
	_banner_tween.tween_callback(func(): _banner.visible = false)

func _chat(text: String) -> void:
	if chat_sink.is_valid():
		chat_sink.call(text)
