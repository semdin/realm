extends Control
class_name HudDungeonRun

## The player's dungeon run on screen inside its copy, driven by the run's
## "state" views (the old game's approved tracker):
##   - while the party gathers, a line saying so; then the start countdown in
##     the middle of the screen (10 ... 1, "Go!") as the start gate opens;
##   - the tracker on the right rail: the dungeon and difficulty in the
##     difficulty's colour, the clock against the medal times (it ticks here
##     from the run's start tick and its death penalty), the clear, the
##     creatures still standing, the bosses, the deaths and the party's lives;
##   - at completion with a result, the result window (HudDungeonResult).

const MEDAL_TINTS := {"gold": Color(0.92, 0.74, 0.30), "silver": Color(0.76, 0.80, 0.86), "bronze": Color(0.82, 0.54, 0.32)}
## RunView.phase.
const GATHERING := 0
const COUNTDOWN := 1
const RUNNING := 2
const OVER := 3

var session: Node
var result_window: HudDungeonResult = null

## The newest run view ({} before the first) and every phase seen (the check
## reads them), the countdown numbers popped and the "Go!".
var state: Dictionary = {}
var phases_seen := {}
var counts_shown: Array = []
var go_shown := false
var result_shown := false

var _count: Label
var wait_label: Label
var _last_count := 0
var _phase := -1
var _pop_tween: Tween
var _frozen := 0.0

var panel: PanelContainer
var _title: Label
var clock_label: Label
var _target: Label
var _medal_bar: MedalBar
var clear_label: Label
var _clear_bar: MedalBar
var _bosses: VBoxContainer
var _bosses_key := ""
var _deaths: Label

func _init() -> void:
	name = "DungeonRun"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	wait_label = HudKit.label(tr("Waiting for the party to arrive..."), 20, HudKit.GOLD_LT, HudKit.bold(), 5)
	wait_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wait_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	wait_label.custom_minimum_size = Vector2(700, 40)
	wait_label.offset_left = -350
	wait_label.offset_right = 350
	wait_label.offset_top = 210
	wait_label.visible = false
	add_child(wait_label)
	_build_tracker()

func _build_tracker() -> void:
	panel = PanelContainer.new()
	panel.name = "DungeonTracker"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.040, 0.067, 0.88)
	box.border_color = HudKit.GOLD_DK.lerp(HudKit.GOLD, 0.4)
	box.set_border_width_all(1)
	box.border_width_bottom = 2
	box.set_corner_radius_all(8)
	box.shadow_color = Color(0, 0, 0, 0.5)
	box.shadow_size = 8
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 8
	box.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", box)
	# The right rail (where a duel's plaque also sits).
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_right = -UITheme.EDGE
	panel.offset_left = -UITheme.EDGE - UITheme.RIGHT_COL_W
	panel.offset_top = 272
	panel.visible = false
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)
	_title = HudKit.label("", 14, HudKit.GOLD_LT, HudKit.title(), 4)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_title)
	var clock_row := HBoxContainer.new()
	clock_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(clock_row)
	clock_label = HudKit.label("0:00", 30, HudKit.PARCHMENT, HudKit.deco(), 5)
	clock_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clock_row.add_child(clock_label)
	_target = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	_target.size_flags_vertical = Control.SIZE_SHRINK_END
	clock_row.add_child(_target)
	_medal_bar = MedalBar.new()
	column.add_child(_medal_bar)
	clear_label = HudKit.label("", 13, HudKit.TEXT, HudKit.body(), 3)
	column.add_child(clear_label)
	_clear_bar = MedalBar.new()
	_clear_bar.plain = Color(0.45, 0.82, 0.52)
	column.add_child(_clear_bar)
	_bosses = VBoxContainer.new()
	_bosses.add_theme_constant_override("separation", 0)
	_bosses.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_bosses)
	_deaths = HudKit.label("", 13, HudKit.TEXT, HudKit.body(), 3)
	_deaths.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_deaths)

## A run view (the "state" event's `view`).
func on_state(view: Dictionary) -> void:
	var phase := int(view.get("phase", RUNNING))
	if phase == OVER and _phase != OVER:
		_frozen = seconds()   # the clock stops where it stood
	state = view
	phases_seen[phase] = true
	if phase == COUNTDOWN and _phase != COUNTDOWN:
		_last_count = 0
	if phase == RUNNING and _phase == COUNTDOWN:
		go_shown = true
		_pop(I18n.upper(tr("Go!")), Color(0.55, 0.95, 0.6), 1.1)
		AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)
	_phase = phase
	_refresh_tracker()
	var result: Variant = view.get("result")
	if bool(view.get("complete", false)) and result is Dictionary and not result_shown and result_window != null:
		result_shown = true
		result_window.show_result(view)

func phase() -> int:
	return _phase

func _ticks_per_second() -> float:
	return float(RealmInfo.sim_hz())

func _server_tick() -> float:
	return float(session.server_tick()) if session != null else -1.0

func _process(_delta: float) -> void:
	var here := not state.is_empty()
	panel.visible = here
	wait_label.visible = here and _phase == GATHERING
	if not here:
		_count.visible = false
		return
	_tick_clock()
	if _phase != COUNTDOWN:
		return
	var now := _server_tick()
	if now < 0.0:
		return
	var left := int(ceil((float(state.get("countdown_end", 0)) - now) / _ticks_per_second()))
	if left > 0 and left != _last_count:
		_last_count = left
		counts_shown.append(left)
		_pop(str(left), HudKit.GOLD_HI if left > 3 else Color(1.0, 0.62, 0.35))
		AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)

## Seconds on the run's clock now: from the run's start tick on the server's
## clock, plus the deaths' penalty; the result's own time once it is over.
func seconds() -> float:
	var result: Variant = state.get("result")
	if result is Dictionary:
		return float(result.get("time_ms", 0)) / 1000.0
	if _phase == OVER:
		return _frozen
	if _phase != RUNNING:
		return 0.0
	var now := _server_tick()
	if now < 0.0:
		return float(state.get("penalty_s", 0.0))
	return maxf(0.0, (now - float(state.get("start_tick", 0))) / _ticks_per_second()) + float(state.get("penalty_s", 0.0))

func _tick_clock() -> void:
	var secs := seconds()
	clock_label.text = DungeonData.clock(secs)
	var par := float(state.get("par_s", 0.0))
	var medals := DungeonData.medals()
	var bronze := par * float(medals.get("bronze", 1.6))
	_medal_bar.fraction = clampf(secs / maxf(1.0, bronze), 0.0, 1.0)
	_medal_bar.marks = [float(medals.get("gold", 1.0)) / float(medals.get("bronze", 1.6)),
		float(medals.get("silver", 1.3)) / float(medals.get("bronze", 1.6))]
	var target := ""
	var tint := HudKit.TEXT_DIM
	if bool(state.get("broken", false)):
		target = tr("no medal")
	else:
		for id: String in ["gold", "silver", "bronze"]:
			var limit := par * float(medals.get(id, 0.0))
			if secs <= limit:
				target = "%s %s" % [{"gold": tr("Gold"), "silver": tr("Silver"), "bronze": tr("Bronze")}[id], DungeonData.clock(limit)]
				tint = MEDAL_TINTS[id]
				_medal_bar.plain = MEDAL_TINTS[id]
				break
		if target == "":
			target = tr("no medal")
			_medal_bar.plain = Color(0.5, 0.5, 0.55)
	_target.text = target
	_target.add_theme_color_override("font_color", tint)

func _refresh_tracker() -> void:
	var dungeon_id := String(state.get("dungeon", ""))
	var difficulty := DungeonData.difficulty_id(int(state.get("difficulty", 1)))
	_title.text = "%s - %s" % [I18n.upper(DungeonData.display_name(dungeon_id)), DungeonData.difficulty_name(difficulty)]
	_title.add_theme_color_override("font_color", DungeonData.colour(difficulty))
	var forces := int(state.get("forces", 0))
	var total := int(state.get("forces_total", 0))
	var share := 1.0 if total <= 0 else minf(1.0, float(forces) / float(total))
	clear_label.text = tr("Clear %d%% (%d / %d)") % [int(floor(share * 100.0)), forces, total]
	# The creatures of the run still standing (the server counts them while
	# the run is under way; at the end they are all that holds the finish).
	var left := int(state.get("left", 0))
	if left > 0 and not bool(state.get("complete", false)):
		clear_label.text += "\n" + tr("%d creature(s) left") % left
	_clear_bar.fraction = share
	var bosses: Array = state.get("bosses", [])
	if str(bosses) != _bosses_key:
		_bosses_key = str(bosses)
		for child in _bosses.get_children():
			child.queue_free()
		for boss: Array in bosses:
			var done := bool(boss[1])
			_bosses.add_child(HudKit.label(("✔ " if done else "○ ") + I18n.mob_name(String(boss[0])), 13,
				HudKit.GREEN if done else HudKit.TEXT, HudKit.body(), 3))
	var rules := DungeonData.difficulty(difficulty)
	var deaths := int(state.get("deaths", 0))
	var penalty := float(rules.get("death_penalty_s", 0))
	var text := tr("Deaths %d") % deaths
	if penalty > 0.0 and deaths > 0:
		text += " " + tr("(+%d s)") % int(penalty * deaths)
	var lives := int(state.get("lives_left", -1))
	if lives >= 0:
		text += " · " + tr("Lives %d / %d") % [lives, int(rules.get("lives", 0))]
	_deaths.text = text
	_deaths.add_theme_color_override("font_color", HudKit.RED if bool(state.get("broken", false)) else HudKit.TEXT)
	_tick_clock()

func _pop(text: String, colour: Color, hold := 0.8) -> void:
	_count.text = text
	_count.add_theme_color_override("font_color", colour)
	_count.visible = true
	_count.scale = Vector2(1.6, 1.6)
	_count.modulate.a = 1.0
	# One number at a time: the last second's fade must not run on into this one's.
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = create_tween()
	_pop_tween.tween_property(_count, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop_tween.tween_interval(hold * 0.6)
	_pop_tween.tween_property(_count, "modulate:a", 0.0, hold * 0.4)

## The number (or "Go!") in the middle of the screen now ("" when none shows).
func count_text() -> String:
	return _count.text if _count.visible and _count.modulate.a > 0.05 else ""


## A thin progress bar; `marks` (fractions) draw the medal lines across it.
class MedalBar extends Control:
	var plain := Color(0.92, 0.74, 0.30)
	var marks: Array = []
	var fraction := 0.0:
		set(v):
			if absf(v - fraction) > 0.0005:
				fraction = v
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 7)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0, 0, 0, 0.55))
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * fraction, size.y)), plain.darkened(0.1))
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * fraction, 1.0)), plain.lightened(0.35))
		for i in marks.size():
			var x := size.x * float(marks[i])
			draw_line(Vector2(x, -2), Vector2(x, size.y + 2), HudDungeonRun.MEDAL_TINTS["gold" if i == 0 else "silver"], 2.0)
