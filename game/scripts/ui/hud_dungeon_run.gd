extends Control
class_name HudDungeonRun

## The player's dungeon run on screen inside its copy, driven by the run's
## "state" views (the old game's approved tracker):
##   - while the party gathers, a line saying so; then the start countdown in
##     the middle of the screen (10 ... 1, "Go!") as the start gate opens;
##   - the tracker on the right rail, on a glass wash that darkens toward the
##     screen's edge under a hairline in the difficulty's colour (no box): the
##     dungeon and its difficulty (name, diamonds), the run's curses, the
##     clock (light, large) with the medal it is still good for, the time
##     line with the medal marks (warm in the last two minutes before one is
##     lost), the clear (share, count, bar, creatures still standing), the
##     bosses (a gold diamond each, green once fallen), the deaths with their
##     penalty and the party's lives as hearts (at completion the clock stops
##     in gold; MapDungeon says the result).

## The tracker's inks (its glass is darker than a window's).
const TRACK_INK := Color(0.925, 0.902, 0.855)
const TRACK_DIM := Color(0.651, 0.624, 0.576)
const TRACK_FAINT := Color(0.435, 0.416, 0.384)
## How far the wash reaches left of the rail to fade in.
const WASH_LEAD := 30.0
## The clock warms this long before the next medal is lost.
const WARN_S := 120.0
const MEDAL_TINTS := {"gold": Color(0.92, 0.74, 0.30), "silver": Color(0.76, 0.80, 0.86), "bronze": Color(0.82, 0.54, 0.32)}
## RunView.phase.
const GATHERING := 0
const COUNTDOWN := 1
const RUNNING := 2
const OVER := 3

var session: Node

## The newest run view ({} before the first) and every phase seen (the check
## reads them), the countdown numbers popped and the "Go!".
var state: Dictionary = {}
var phases_seen := {}
var counts_shown: Array = []
var go_shown := false

var _count: Label
var wait_label: Label
var _last_count := 0
var _phase := -1
var _pop_tween: Tween
var _frozen := 0.0

var panel: PanelContainer
var _title: Label
var _difficulty: Label
var _top_line: GradLine
var _pips: Pips
## The run's curses, one line ("" and hidden when none).
var curses_label: Label
var clock_label: Label
var _target: Label
var _medal: Medal
var _timeline: TimeLine
## The clear's share ("%40"), then its count and the creatures left.
var clear_label: Label
var _clear_count: Label
var _clear_bar: ForceBar
var _left: Label
var _bosses: VBoxContainer
var _bosses_key := ""
var _deaths: Label
var _penalty: Label
var _hearts: Hearts

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
	# No box: a glass wash that darkens toward the screen's edge, a hairline
	# in the difficulty's colour over it and a faint one under it.
	panel.add_theme_stylebox_override("panel", _wash())
	# The right rail (where a duel's plaque also sits), reaching a little
	# further left for the wash to fade in.
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_right = -UITheme.EDGE
	panel.offset_left = -UITheme.EDGE - UITheme.RIGHT_COL_W - WASH_LEAD
	panel.offset_top = 272
	panel.visible = false
	add_child(panel)
	# The hairline over the glass: beside the panel, not in it (a container
	# would stretch it over the whole panel); _process lays it on the top edge.
	_top_line = GradLine.new()
	_top_line.visible = false
	add_child(_top_line)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_END
	head.add_theme_constant_override("separation", 9)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(head)
	_title = HudKit.label("", 15, TRACK_INK, _spaced(UITheme.W_BOLD, 2), 2)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_title)
	_difficulty = HudKit.label("", 12, Color.WHITE, _spaced(600, 1), 2)
	_difficulty.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_difficulty)
	_pips = Pips.new()
	_pips.size_flags_horizontal = Control.SIZE_SHRINK_END
	column.add_child(_pips)

	curses_label = HudKit.label("", 11, Color(1.0, 0.70, 0.66), HudKit.bold(), 2)
	curses_label.name = "Curses"
	curses_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	curses_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	curses_label.add_theme_stylebox_override("normal", _curse_box())
	curses_label.size_flags_horizontal = Control.SIZE_FILL
	curses_label.visible = false
	column.add_child(_gap(8))
	column.add_child(curses_label)

	column.add_child(_gap(8))
	var clock_row := HBoxContainer.new()
	clock_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(clock_row)
	var target_row := HBoxContainer.new()
	target_row.add_theme_constant_override("separation", 7)
	target_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_row.size_flags_vertical = Control.SIZE_SHRINK_END
	target_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock_row.add_child(target_row)
	_medal = Medal.new()
	_medal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	target_row.add_child(_medal)
	_target = HudKit.label("", 13, TRACK_DIM, HudKit.body(), 2)
	target_row.add_child(_target)
	clock_label = HudKit.label("0:00", 38, Color.WHITE, UITheme.font(300), 2)
	clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	clock_row.add_child(clock_label)
	_timeline = TimeLine.new()
	column.add_child(_timeline)

	column.add_child(_gap(12))
	var clear_row := HBoxContainer.new()
	clear_row.add_theme_constant_override("separation", 6)
	clear_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(clear_row)
	var clear_name := HudKit.label(tr("Clear"), 13, TRACK_DIM, HudKit.body(), 2)
	clear_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_row.add_child(clear_name)
	clear_label = HudKit.label("", 13, TRACK_INK, HudKit.bold(), 2)
	clear_row.add_child(clear_label)
	_clear_count = HudKit.label("", 12, TRACK_FAINT, HudKit.body(), 2)
	_clear_count.size_flags_vertical = Control.SIZE_SHRINK_END
	clear_row.add_child(_clear_count)
	column.add_child(_gap(6))
	_clear_bar = ForceBar.new()
	column.add_child(_clear_bar)
	_left = HudKit.label("", 12, TRACK_FAINT, HudKit.body(), 2)
	_left.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	column.add_child(_gap(4))
	column.add_child(_left)

	column.add_child(_gap(8))
	_bosses = VBoxContainer.new()
	_bosses.add_theme_constant_override("separation", 6)
	_bosses.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_bosses)

	column.add_child(_gap(10))
	var rule := GradLine.new()
	rule.colours = [Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.10)]
	rule.custom_minimum_size = Vector2(0, 1)
	column.add_child(rule)
	column.add_child(_gap(8))
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(foot)
	var skull := UITheme.icon_rect("status_dead", 16.0)
	skull.modulate = Color(1, 1, 1, 0.8)
	skull.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(skull)
	_deaths = HudKit.label("", 13, TRACK_DIM, HudKit.body(), 2)
	foot.add_child(_deaths)
	_penalty = HudKit.label("", 13, Color(1.0, 0.61, 0.56), HudKit.body(), 2)
	_penalty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_penalty)
	_hearts = Hearts.new()
	_hearts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(_hearts)

static func _gap(px: float) -> Control:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, px)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return gap

## The face at `weight` with `spacing` px between letters (a FontVariation of
## its own: one over another loses the weight).
static func _spaced(weight: int, spacing: int) -> Font:
	var face := UITheme.font(weight)
	if not (face is FontVariation):
		return face
	var spaced := (face as FontVariation).duplicate() as FontVariation
	spaced.spacing_glyph = spacing
	return spaced

## The glass wash: clear at the left, deepening toward the screen's edge.
static func _wash() -> StyleBoxTexture:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.22, 1.0])
	gradient.colors = PackedColorArray([Color(0.031, 0.043, 0.067, 0.0), Color(0.031, 0.043, 0.067, 0.62),
		Color(0.031, 0.043, 0.067, 0.80)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 128
	texture.height = 4
	var box := StyleBoxTexture.new()
	box.texture = texture
	box.content_margin_left = WASH_LEAD + 8
	box.content_margin_right = 18
	box.content_margin_top = 14
	box.content_margin_bottom = 14
	return box

## A curse's tag: a red wash ending in a bright edge on the right.
static func _curse_box() -> StyleBoxTexture:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([Color(0.47, 0.08, 0.06, 0.0), Color(0.47, 0.08, 0.06, 0.6)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 64
	texture.height = 4
	var box := StyleBoxTexture.new()
	box.texture = texture
	box.content_margin_left = 10
	box.content_margin_right = 8
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	return box

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

func phase() -> int:
	return _phase

func _ticks_per_second() -> float:
	return float(RealmInfo.sim_hz())

func _server_tick() -> float:
	return float(session.server_tick()) if session != null else -1.0

func _process(_delta: float) -> void:
	var here := not state.is_empty()
	panel.visible = here
	_top_line.visible = here
	if here:
		_top_line.position = panel.position + Vector2(WASH_LEAD, 0.0)
		_top_line.size = Vector2(maxf(0.0, panel.size.x - WASH_LEAD), 1.0)
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

## The clock, the medal it is still good for, and the time line: its fill,
## the medal marks along it (a passed one dims) and the warm warning in the
## last WARN_S before the next medal is lost.
func _tick_clock() -> void:
	var secs := seconds()
	clock_label.text = DungeonData.clock(secs)
	var par := float(state.get("par_s", 0.0))
	var medals := DungeonData.medals()
	var ids := ["gold", "silver", "bronze"]
	var bronze := par * float(medals.get("bronze", 1.6))
	var span := maxf(float(state.get("limit_s", 0.0)), bronze * 1.15)
	var marks: Array = []
	for id: String in ids:
		var at := par * float(medals.get(id, 0.0))
		marks.append([at / maxf(1.0, span), MEDAL_TINTS[id], secs > at])
	_timeline.marks = marks
	_timeline.fraction = clampf(secs / maxf(1.0, span), 0.0, 1.0)
	var over := _phase == OVER or state.get("result") is Dictionary
	var target := ""
	var tint := Color(0.42, 0.42, 0.45)
	var warn := false
	if not bool(state.get("broken", false)):
		for id: String in ids:
			var limit := par * float(medals.get(id, 0.0))
			if secs <= limit:
				target = "%s  %s" % [{"gold": tr("Gold"), "silver": tr("Silver"), "bronze": tr("Bronze")}[id],
					DungeonData.clock(limit)]
				tint = MEDAL_TINTS[id]
				warn = not over and limit - secs < WARN_S
				break
	if target == "":
		target = tr("no medal")
	_target.text = target
	_medal.tint = tint
	_timeline.warn = warn
	var clock_tint := Color.WHITE
	if over:
		clock_tint = Color(1.0, 0.94, 0.76)
	elif warn:
		clock_tint = Color(1.0, 0.82, 0.65)
	clock_label.add_theme_color_override("font_color", clock_tint)

func _refresh_tracker() -> void:
	var dungeon_id := String(state.get("dungeon", ""))
	var difficulty := DungeonData.difficulty_id(int(state.get("difficulty", 1)))
	var tint := DungeonData.colour(difficulty)
	_title.text = I18n.upper(DungeonData.display_name(dungeon_id))
	_difficulty.text = I18n.upper(DungeonData.difficulty_name(difficulty))
	_difficulty.add_theme_color_override("font_color", tint)
	_top_line.colours = [Color(tint, 0.0), tint, tint.lerp(Color.WHITE, 0.35)]
	_top_line.queue_redraw()
	_pips.tint = tint
	_pips.lit = int(state.get("difficulty", 1)) + 1
	var names := PackedStringArray()
	for id: Variant in state.get("affixes", []):
		names.append(DungeonData.affix_name(String(id)))
	curses_label.text = "  ·  ".join(names)
	curses_label.visible = not names.is_empty()
	var forces := int(state.get("forces", 0))
	var total := int(state.get("forces_total", 0))
	var share := 1.0 if total <= 0 else minf(1.0, float(forces) / float(total))
	clear_label.text = tr("%d%%") % int(floor(share * 100.0))
	_clear_count.text = "%d / %d" % [forces, total]
	_clear_bar.fraction = share
	# The creatures of the run still standing (the server counts them while
	# the run is under way; at the end they are all that holds the finish).
	var left := int(state.get("left", 0))
	_left.text = tr("%d creature(s) left") % left if left > 0 and not bool(state.get("complete", false)) else ""
	_left.visible = _left.text != ""
	var bosses: Array = state.get("bosses", [])
	if str(bosses) != _bosses_key:
		_bosses_key = str(bosses)
		for child in _bosses.get_children():
			_bosses.remove_child(child)   # out of the layout this frame
			child.queue_free()
		for boss: Array in bosses:
			_bosses.add_child(_boss_row(I18n.mob_name(String(boss[0])), bool(boss[1])))
	var rules := DungeonData.difficulty(difficulty)
	var deaths := int(state.get("deaths", 0))
	var penalty := float(rules.get("death_penalty_s", 0))
	_deaths.text = tr("Deaths %d") % deaths
	_deaths.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4) if bool(state.get("broken", false)) else TRACK_DIM)
	_penalty.text = tr("(+%d s)") % int(penalty * deaths) if penalty > 0.0 and deaths > 0 else ""
	var lives := int(state.get("lives_left", -1))
	_hearts.visible = lives >= 0
	_hearts.total = int(rules.get("lives", 0))
	_hearts.left = maxi(0, lives)
	_tick_clock()

## A boss of the run: its name and a diamond, gold while it stands, green
## and dimmed once it fell.
func _boss_row(boss_name: String, down: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 9)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := HudKit.label(boss_name, 14, TRACK_FAINT if down else TRACK_INK, HudKit.body(), 2)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(name_label)
	var mark := Diamond.new()
	mark.down = down
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(mark)
	return row

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

## A hairline whose colour runs left to right through `colours`.
class GradLine extends Control:
	var colours: Array = [Color(1, 1, 1, 0), Color(1, 1, 1, 0.8)]

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var n := colours.size()
		if n < 2 or size.x <= 0.0:
			return
		for i in n - 1:
			var x0 := size.x * float(i) / float(n - 1)
			var x1 := size.x * float(i + 1) / float(n - 1)
			draw_polygon(PackedVector2Array([Vector2(x0, 0), Vector2(x1, 0), Vector2(x1, size.y), Vector2(x0, size.y)]),
				PackedColorArray([colours[i], colours[i + 1], colours[i + 1], colours[i]]))

## The difficulty's five diamonds, `lit` of them filled.
class Pips extends Control:
	var tint := Color.WHITE:
		set(v):
			tint = v
			queue_redraw()
	var lit := 1:
		set(v):
			lit = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(5 * 10.0, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		for i in 5:
			var c := Vector2(size.x - 5.0 - float(4 - i) * 10.0, size.y * 0.5 + 1.0)
			var d := PackedVector2Array([c + Vector2(0, -4), c + Vector2(4, 0), c + Vector2(0, 4), c + Vector2(-4, 0)])
			if i < lit:
				draw_circle(c, 6.0, Color(tint, 0.18))
				draw_colored_polygon(d, tint)
			else:
				d.append(d[0])
				draw_polyline(d, Color(tint, 0.55), 1.0, true)

## A small lit medal (the medal the clock is still good for).
class Medal extends Control:
	var tint := Color(0.92, 0.74, 0.30):
		set(v):
			tint = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(14, 14)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, 7.5, Color(tint, 0.25))
		draw_circle(c, 6.0, tint.darkened(0.45))
		draw_circle(c, 5.0, tint)
		draw_circle(c + Vector2(-1.6, -1.6), 2.2, tint.lerp(Color(1, 0.98, 0.88), 0.7))

## The run's time line: a slim track filling with the clock, its medal
## marks above it (each a lit dot on a fading stem, dimmed once passed); warm
## when the next medal is about to be lost.
class TimeLine extends Control:
	var marks: Array = []
	var warn := false:
		set(v):
			if v != warn:
				warn = v
				queue_redraw()
	var fraction := 0.0:
		set(v):
			if absf(v - fraction) > 0.0005:
				fraction = v
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 18)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := 11.0
		draw_rect(Rect2(0, y, size.x, 3), Color(1, 1, 1, 0.10))
		var w := size.x * fraction
		if w > 0.5:
			var head := Color(1.0, 0.70, 0.42) if warn else Color.WHITE
			draw_polygon(PackedVector2Array([Vector2(0, y), Vector2(w, y), Vector2(w, y + 3), Vector2(0, y + 3)]),
				PackedColorArray([Color(head, 0.35), head, head, Color(head, 0.35)]))
			draw_circle(Vector2(w, y + 1.5), 4.0, Color(head, 0.25))
		for m: Array in marks:
			var x := size.x * float(m[0])
			var tint: Color = m[1]
			var passed := bool(m[2])
			var col := Color(0.35, 0.35, 0.38) if passed else tint
			draw_polygon(PackedVector2Array([Vector2(x - 0.5, 3), Vector2(x + 0.5, 3), Vector2(x + 0.5, 16), Vector2(x - 0.5, 16)]),
				PackedColorArray([Color(col, 0.0), Color(col, 0.0), col, col]))
			if not passed:
				draw_circle(Vector2(x, 3), 5.5, Color(tint, 0.22))
			draw_circle(Vector2(x, 3), 3.6, col.darkened(0.4))
			draw_circle(Vector2(x, 3), 2.8, col)
			draw_circle(Vector2(x - 0.9, 2.1), 1.1, col.lerp(Color(1, 0.98, 0.9), 0.75))

## The clear: a slim bar, its fill a green ramp with a lit top line and a
## soft glow at its head.
class ForceBar extends Control:
	var fraction := 0.0:
		set(v):
			if absf(v - fraction) > 0.0005:
				fraction = v
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 5)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.08))
		var w := size.x * fraction
		if w <= 0.5:
			return
		var low := Color(0.18, 0.56, 0.40)
		var high := Color(0.44, 0.89, 0.65)
		draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, size.y), Vector2(0, size.y)]),
			PackedColorArray([low, high, high, low]))
		draw_rect(Rect2(0, 0, w, 1), Color(1, 1, 1, 0.5))
		draw_circle(Vector2(w, size.y * 0.5), 5.0, Color(0.67, 1.0, 0.82, 0.35))

## A boss's mark: a gold diamond outline while it stands, filled green once
## it fell.
class Diamond extends Control:
	var down := false

	func _init() -> void:
		custom_minimum_size = Vector2(12, 12)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var d := PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)])
		if down:
			draw_circle(c, 6.5, Color(0.49, 0.89, 0.64, 0.25))
			draw_colored_polygon(d, Color(0.49, 0.89, 0.64))
		else:
			d.append(d[0])
			draw_polyline(d, Color(0.92, 0.77, 0.42), 1.5, true)

## The party's lives: a heart each, spent ones grey.
class Hearts extends Control:
	var total := 0:
		set(v):
			if v != total:
				total = v
				custom_minimum_size = Vector2(maxi(0, v) * 13.0, 11)
				queue_redraw()
	var left := 0:
		set(v):
			if v != left:
				left = v
				queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		for i in total:
			var o := Vector2(i * 13.0 + 1.0, 1.0)
			var lit := i < left
			var col := Color(1.0, 0.42, 0.42) if lit else Color(1, 1, 1, 0.16)
			if lit:
				draw_circle(o + Vector2(5, 5), 6.0, Color(1.0, 0.35, 0.35, 0.18))
			draw_circle(o + Vector2(2.6, 3.0), 2.6, col)
			draw_circle(o + Vector2(7.4, 3.0), 2.6, col)
			draw_colored_polygon(PackedVector2Array([o + Vector2(0.2, 3.8), o + Vector2(9.8, 3.8), o + Vector2(5, 9.4)]), col)
