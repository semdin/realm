extends Control
class_name CombatFeedback

## The kill loop on screen: the loot / experience / level / reputation toasts, the level-up
## moment, and a clear death / rise state with the death choice.
##
## Everything here is driven by the server's game events (main.gd hands them
## over) and the sheet: nothing decides anything. The death panel counts out
## the server's ticks (`ready_tick`, `auto_tick` against
## RealmSession.server_tick); the buttons only ask (RealmSession.respawn) and
## the body rises when the server says so (the snapshot's health comes back).

const TOASTS_MAX := 6
## A body that just rose is untouchable and casts nothing this long (the
## server's RISE_PROTECT_MS); the hero fades in over it (HeroView.fade_in).
const RISE_PROTECT := 3.0
## Height of the notification card, in canvas pixels, pinned above the
## control deck rather than to a fixed y.
const TOAST_H := 120.0
const TOAST_SECONDS := 4.0
## House reputation's colour (the toast and the words over the hero).
const REP_COLOUR := Color(1.0, 0.78, 0.35)

var session: Node
var hud: Control
## The player's hero (HeroView): the death pose, the rise and the level-up
## pillar.
var player: Node3D

var _toast_box: VBoxContainer
var _toast_panel: Panel
var _toasts: Array = []
var _death_panel: ColorRect
var _death_label: Label
var _death_icon: TextureRect
var _revive_here: Button
var _revive_town: Button
var _respawn_sent := false
## The death as the server scheduled it: server ticks the choice opens and the
## body goes to town by itself (-1: alive).
var _ready_tick := -1.0
## The map this layer is on (main.gd sets it before setup): in a dungeon the
## second death choice wakes at its entrance, not in town.
var map_name := ""
## Until when (seconds, Time.get_ticks_msec) the risen body is protected.
var _protect_until := 0.0
var _auto_tick := -1.0
## The snapshot showed the body at no health since the death (it rises when
## the health comes back).
var _seen_down := false
## The level last shown; a rise is the level-up moment.
var _shown_level := 0

## What the check reads.
var toasts_shown := 0
var deaths_shown := 0
var rises_shown := 0
var level_ups_shown := 0
var last_toast := ""

func setup(realm_session: Node, p_hud: Control, p_player: Node3D) -> void:
	session = realm_session
	hud = p_hud
	player = p_player
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UITheme.get_theme()
	_build()

func is_dead() -> bool:
	return _ready_tick >= 0.0

## Server ticks per second.
static func _hz() -> float:
	return float(RealmInfo.sim_hz())

## A control `extent` large, its centre `offset` from the parent's centre.
static func _place_centred(control: Control, extent: Vector2, offset := Vector2.ZERO) -> void:
	control.set_anchors_preset(Control.PRESET_CENTER)
	control.offset_left = offset.x - extent.x * 0.5
	control.offset_top = offset.y - extent.y * 0.5
	control.offset_right = offset.x + extent.x * 0.5
	control.offset_bottom = offset.y + extent.y * 0.5

func _build() -> void:
	# Loot / XP / level toasts: the lowest card in the right rail, pinned above
	# the control deck so it clears it at every canvas height.
	_toast_panel = Panel.new()
	_toast_panel.name = "ToastPanel"
	_toast_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	var at := Vector2(-(UITheme.RIGHT_COL_W + UITheme.EDGE), -(UITheme.DECK_BOTTOM + UITheme.DECK_H + 8 + TOAST_H))
	_toast_panel.offset_left = at.x
	_toast_panel.offset_top = at.y
	_toast_panel.offset_right = at.x + UITheme.RIGHT_COL_W
	_toast_panel.offset_bottom = at.y + TOAST_H
	_toast_panel.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W, TOAST_H)
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.theme_type_variation = UITheme.V_CARD
	_toast_box = VBoxContainer.new()
	_toast_box.name = "Toasts"
	_toast_box.position = Vector2(9, 6)
	_toast_box.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W - 18, TOAST_H - 12)
	_toast_box.add_theme_constant_override("separation", 2)
	_toast_panel.add_child(_toast_box)
	_toast_panel.hide()
	add_child(_toast_panel)

	# Death / rise state.
	_death_panel = ColorRect.new()
	_death_panel.name = "DeathPanel"
	_death_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_panel.color = Color(0.12, 0.0, 0.0, 0.55)
	_death_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_panel.hide()
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.03, 0.01, 0.01, 0.72)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place_centred(backdrop, Vector2(620, 290), Vector2(0, 8))
	_death_panel.add_child(backdrop)
	_death_label = _make_label("", UITheme.FS_BANNER, UITheme.c("blood_lt"))
	_place_centred(_death_label, Vector2(640, 120))
	_death_label.custom_minimum_size = Vector2(640, 120)
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_panel.add_child(_death_label)
	_death_icon = UITheme.icon_rect("status_dead", 72.0)
	_death_icon.name = "DeathIcon"
	_place_centred(_death_icon, Vector2(72, 72), Vector2(0, -104))
	_death_panel.add_child(_death_icon)
	# The death choice: get up where you fell, or go back to town. The panel
	# itself ignores the mouse; only the buttons take clicks.
	var choices := HBoxContainer.new()
	choices.name = "DeathChoices"
	choices.alignment = BoxContainer.ALIGNMENT_CENTER
	choices.add_theme_constant_override("separation", 18)
	_place_centred(choices, Vector2(460, 44), Vector2(0, 96))
	_death_panel.add_child(choices)
	_revive_here = HudKit.button(tr("Revive Here"), 16)
	_revive_here.name = "ReviveHere"
	_revive_here.custom_minimum_size = Vector2(200, UIKit.H_MAIN)
	_revive_here.tooltip_text = tr("Get up where you fell with half health")
	_revive_here.pressed.connect(request_respawn.bind(true))
	choices.add_child(_revive_here)
	_revive_town = HudKit.button(tr("Return to the Entrance") if in_dungeon() else tr("Return to Town"), 16)
	_revive_town.name = "ReviveTown"
	_revive_town.custom_minimum_size = Vector2(200, UIKit.H_MAIN)
	_revive_town.tooltip_text = tr("Wake at the dungeon's entrance with full health") if in_dungeon() \
		else tr("Wake at this map's respawn point with full health")
	_revive_town.pressed.connect(request_respawn.bind(false))
	choices.add_child(_revive_town)
	# Its own layer, above every window (a window left open must not hide the
	# choice).
	var death_layer := CanvasLayer.new()
	death_layer.name = "DeathLayer"
	death_layer.layer = 80
	add_child(death_layer)
	death_layer.add_child(_death_panel)

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# These labels float over the world rather than sitting on a panel: an
	# edge, and the bold cut for the weight.
	label.add_theme_font_override("font", UITheme.font_body_bold())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	label.add_theme_constant_override("outline_size", 3)
	return label

## ----------------------------------------------------------- death / rise

## The server's "death": the body fell; the choice opens at `ready_tick`, the
## body goes to town by itself at `auto_tick`.
func on_death(event: Dictionary) -> void:
	var first := not is_dead()
	_ready_tick = float(event.get("ready_tick", 0))
	_auto_tick = float(event.get("auto_tick", 0))
	_respawn_sent = false
	_seen_down = false
	_death_panel.show()
	_update_death_panel()
	if not first:
		return
	deaths_shown += 1
	hud.show_notice(tr("You were defeated."), "warn")
	AudioManager.play_stinger("stinger_death")
	if is_instance_valid(player):
		player.set_dead(true)
		FloatingText.word(player.global_position + Vector3(0, 2.4, 0), I18n.upper(tr("Defeated!")),
			FloatingText.MUTED_RED, 1.25, 2.0, Nameplates.HERO_HEIGHT - 2.4)

## A dungeon copy's map (its "town" is its entrance).
func in_dungeon() -> bool:
	return map_name.begins_with("dng_")

## Whether the body that just rose is still protected (no casts yet).
func is_rising() -> bool:
	return Time.get_ticks_msec() / 1000.0 < _protect_until

## The body is up again (the snapshot's health came back): RISE_PROTECT
## seconds untouchable, fading in.
func _on_risen() -> void:
	_ready_tick = -1.0
	_auto_tick = -1.0
	_protect_until = Time.get_ticks_msec() / 1000.0 + RISE_PROTECT
	_death_panel.hide()
	rises_shown += 1
	hud.show_notice(tr("Back on your feet."), "good")
	toast(tr("Respawned"), Color(0.5, 1.0, 0.6), "stat_health")
	AudioManager.play_sound_at("ui_respawn", Vector3.ZERO, null, true)
	if is_instance_valid(player):
		player.set_dead(false)

## Seconds until the server tick `tick`.
func _seconds_until(tick: float) -> float:
	var now: float = session.server_tick()
	if now < 0.0:
		return 0.0
	return maxf(0.0, (tick - now) / _hz())

func _update_death_panel() -> void:
	var wait := _seconds_until(_ready_tick)
	var ready := wait <= 0.0 and not _respawn_sent
	_revive_here.disabled = not ready
	_revive_town.disabled = not ready
	if wait > 0.0:
		_death_label.text = tr("DEFEATED\nYou can rise in %ds") % int(ceil(wait))
	else:
		var left := int(ceil(_seconds_until(_auto_tick)))
		var back := tr("DEFEATED\nReturning to the entrance in %d:%02d") if in_dungeon() \
			else tr("DEFEATED\nReturning to town in %d:%02d")
		_death_label.text = back % [left / 60, left % 60]

## Whether the choice is open (the buttons take clicks).
func can_rise() -> bool:
	return is_dead() and not _revive_here.disabled

## A death-panel button: rise here (half health, a short ward) or in town.
func request_respawn(here: bool) -> void:
	if _respawn_sent or not is_dead():
		return
	_respawn_sent = true
	session.respawn(here)
	_update_death_panel()
	# A refused or lost request must not lock the buttons for good.
	get_tree().create_timer(2.0).timeout.connect(func():
		_respawn_sent = false)

## The buttons, for the check (it presses them the way a click does).
func press_rise(here: bool) -> void:
	(_revive_here if here else _revive_town).pressed.emit()

## ------------------------------------------------------------ loot and xp

## The server's "reward": a kill's experience, the killer's oril, items taken
## from a chest, a claimed quest's pay (house reputation with it: a toast with
## the crest and the words over the hero).
##
## Sounds: a kill's oril comes with nearly every kill, so it only toasts (the
## coin on each one was noise); a quest's pay (every quest gives house
## reputation, a kill never does) rings the coin. Items from a chest sounded
## when the take was asked for (the chest window, Z), so their reward is
## quiet; items in a quest's pay add nothing over its coin.
func on_reward(event: Dictionary) -> void:
	var exp := int(event.get("exp", 0))
	var oril := int(event.get("oril", 0))
	var rep := int(event.get("rep", 0))
	var quest_pay := rep > 0
	if rep > 0:
		var house := String(session.sheet().get("house", ""))
		var text := tr("+%d %s Reputation") % [rep, HudQuestScroll.house_name(house)]
		toast(text, REP_COLOUR, "house_" + house)
		if is_instance_valid(player):
			FloatingText.word(player.global_position + Vector3(0, 2.6, 0), text, REP_COLOUR, 1.05, 1.8,
				Nameplates.HERO_HEIGHT - 2.6)
	if exp > 0:
		toast(tr("+%d EXP") % exp, Color(0.5, 1.0, 0.6), "stat_exp")
	if oril > 0:
		toast(tr("+%d Oril") % oril, Color(1.0, 0.85, 0.35), "oril")
	if quest_pay:
		AudioManager.play_sound_at("ui_coin", Vector3.ZERO, null, true)
	var items: Array = event.get("items", [])
	for entry in items:
		if entry is Dictionary:
			var item_id := String(entry.get("id", "item"))
			var item_name := I18n.t(String(Items.item(item_id).get("name", item_id)))
			toast("+%s x%d" % [item_name, int(entry.get("amount", 1))], Color(0.75, 0.95, 0.75),
				item_id if UITheme.icon_for(item_id) != null else "ui_pickup")

## The level the sheet carries; a rise is the level-up moment: the toast, the
## chime, the words over the hero and the pillar and banner.
func _follow_level(level: int) -> void:
	if _shown_level > 0 and level > _shown_level:
		level_ups_shown += 1
		toast(tr("LEVEL %d!") % level, Color(1.0, 0.9, 0.3), "stat_level")
		AudioManager.play_levelup()
		if is_instance_valid(player):
			FloatingText.word(player.global_position + Vector3(0, 2.4, 0), tr("LEVEL UP! (Lv.%d)") % level,
				FloatingText.GOLD, 1.4, 1.8, Nameplates.HERO_HEIGHT - 2.4)
		LevelUpFX.play(player, level, self)
	_shown_level = level

## A notification line. The icon is the loot itself when there is one (an item
## id resolves through the same namespace a bag cell uses).
func toast(text: String, color: Color, icon_id: String = "ui_pickup") -> void:
	toasts_shown += 1
	last_toast = text
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := UITheme.icon_rect(icon_id, 16.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var label := _make_label(text, UITheme.FS_SMALL, color)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	_toast_box.add_child(row)
	_toast_panel.show()
	_toasts.append({"label": label, "row": row, "until": _now() + TOAST_SECONDS})
	var canvas := get_viewport().get_visible_rect().size
	var capacity := 2 if canvas.x < 1000 or canvas.y < 560 else TOASTS_MAX
	# As many as the card holds: the newest at the bottom must not hang out
	# of it (six rows of this font are taller than the card).
	while _toasts.size() > capacity or (_toasts.size() > 1 and _rows_height() > TOAST_H - 12.0):
		var oldest: Dictionary = _toasts.pop_front()
		if is_instance_valid(oldest["row"]):
			_toast_box.remove_child(oldest["row"])
			(oldest["row"] as Node).queue_free()

## The toast rows' height together, as the box lays them out.
func _rows_height() -> float:
	var total := 0.0
	var rows := 0
	for entry: Dictionary in _toasts:
		if is_instance_valid(entry["row"]):
			total += (entry["row"] as Control).get_combined_minimum_size().y
			rows += 1
	return total + 2.0 * maxf(0.0, float(rows - 1))

## ------------------------------------------------------------------ process

func _process(_delta: float) -> void:
	if session == null:
		return
	var now := _now()
	for entry in _toasts.duplicate():
		if not is_instance_valid(entry["label"]):
			_toasts.erase(entry)
		elif now > float(entry["until"]):
			# out of the box now: freed at the frame's end, the rows under it
			# moved up a frame late (the toasts jumped)
			_toast_box.remove_child(entry["row"])
			(entry["row"] as Node).queue_free()
			_toasts.erase(entry)
	if _toasts.is_empty() and _toast_panel.visible:
		_toast_panel.hide()
	if is_dead():
		var hp: int = (session.vitals() as PackedInt32Array)[0]
		if hp <= 0:
			_seen_down = true
		elif _seen_down:
			_on_risen()
	if _death_panel.visible:
		_update_death_panel()
	# the PlayerSheet's copy: session.sheet() rebuilds the whole sheet per call
	var sheet: PlayerSheet = hud.get("sheet") if hud != null else null
	if sheet != null:
		if sheet.revision() >= 0:
			_follow_level(sheet.level)
	else:
		var data: Dictionary = session.sheet()
		if not data.is_empty():
			_follow_level(int(data["level"]))

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
