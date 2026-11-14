extends PanelContainer
class_name HudChat

## The chat log, bottom-left (the old game's approved chat): one log, no tabs.
##
## Idle, the box is see-through: only the last IDLE_LINES lines float over the
## world, outlined so they read on grass or sky, and each fades out after
## IDLE_FADE_AFTER seconds over IDLE_FADE_TIME. Enter focuses the input; the
## box gains a glass panel, shows the full scroll-back (HISTORY lines) and the
## input line. Enter again sends and lets go; Esc lets go.
##
## What the server says (RealmSession.take_chat) comes in through `add_line`:
## a plain line is heard within 40 m (the speaker's name in its house colour),
## a line starting with "!" is a shout to the realm, "/p" speaks to the party,
## and system lines are the server's English, translated (I18n.from_server).
## What the player types goes to `session.send_chat` as typed.

## The box opened (Enter) or let go: the HUD lays it out again.
signal focus_changed(open: bool)

const IDLE_LINES := 7
const IDLE_FADE_AFTER := 14.0
const IDLE_FADE_TIME := 2.0
const HISTORY := 150
const FONT_SIZE := 15
const MAX_LENGTH := 200
## RealmSession.take_chat channels.
const LOCAL := 0
const SHOUT := 1
const PARTY := 2
const SYSTEM := 3
const PARTY_COLOUR := Color(0.55, 0.8, 1.0)
const SYSTEM_COLOUR := Color(0.96, 0.82, 0.45)

var session: Node
var history: RichTextLabel
var input: LineEdit
## Every stored line: {t (seconds), bb (BBCode, "{a}" where its alpha goes),
## channel, from, text (as shown, without markup)}.
var _lines: Array = []
var _dirty := true
var _tick := 0.0
var _focused := false

func _init() -> void:
	name = "Chat"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)
	history = RichTextLabel.new()
	history.name = "ChatHistory"
	history.custom_minimum_size = Vector2(0, 40)
	history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history.bbcode_enabled = true
	history.scroll_following = true
	history.fit_content = false
	# the newest line sits on the box's foot, open or idle
	history.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	history.selection_enabled = false
	history.mouse_filter = Control.MOUSE_FILTER_IGNORE
	history.add_theme_font_override("normal_font", HudKit.body())
	history.add_theme_font_override("bold_font", HudKit.bold())
	history.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	history.add_theme_font_size_override("bold_font_size", FONT_SIZE)
	history.add_theme_color_override("default_color", HudKit.TEXT)
	history.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	history.add_theme_constant_override("outline_size", UITheme.outline_for(UITheme.FS_BODY, 4))
	history.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	history.add_theme_constant_override("shadow_offset_y", 1)
	history.add_theme_constant_override("line_separation", 2)
	history.add_theme_stylebox_override("normal", HudKit.empty())
	column.add_child(history)
	input = LineEdit.new()
	input.name = "ChatInput"
	input.custom_minimum_size = Vector2(0, 30)
	input.placeholder_text = tr("Say something…   (start with ! to shout to everyone)")
	input.max_length = MAX_LENGTH
	input.add_theme_font_override("font", HudKit.body())
	input.add_theme_font_size_override("font_size", FONT_SIZE)
	input.add_theme_color_override("font_color", HudKit.PARCHMENT)
	input.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	input.add_theme_color_override("caret_color", HudKit.GOLD_HI)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0.02, 0.027, 0.043, 0.85)
	field.border_color = HudKit.GOLD.darkened(0.2)
	field.set_border_width_all(1)
	field.set_corner_radius_all(4)
	field.content_margin_left = 8
	field.content_margin_right = 8
	field.content_margin_top = 4
	field.content_margin_bottom = 4
	for state in ["normal", "focus", "read_only"]:
		input.add_theme_stylebox_override(state, field)
	input.focus_entered.connect(_on_focus.bind(true))
	input.focus_exited.connect(_on_focus.bind(false))
	input.gui_input.connect(_on_input_gui)
	input.text_submitted.connect(submit)
	column.add_child(input)
	_on_focus(false)

func is_open() -> bool:
	return _focused

## Enter: the input takes the keys and the box shows its scroll-back.
func open() -> void:
	input.show()
	input.grab_focus()

func close() -> void:
	input.release_focus()

## Enter in the input (or the check): a line goes to the server as typed, and
## the box lets go either way.
func submit(text: String) -> void:
	if not text.strip_edges().is_empty() and session != null:
		session.send_chat(text)
	input.clear()
	close()

func _on_focus(on: bool) -> void:
	_focused = on
	add_theme_stylebox_override("panel", HudKit.panel(0.74, 6, 0.6) if on else HudKit.empty())
	input.visible = on
	history.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	history.scroll_active = on
	_dirty = true
	_rebuild()
	focus_changed.emit(on)

func _on_input_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		input.clear()
		close()
		input.accept_event()

## ------------------------------------------------------------------- lines

## A line from the server. `house` colours a local speaker's name (empty: the
## gold of an unknown house).
func add_line(channel: int, from: String, text: String, house := "") -> void:
	var safe := _escape(text)
	var who := _escape(from)
	match channel:
		SYSTEM:
			add_system_line(I18n.from_server(text))
		SHOUT:
			_push("[color=#%s{a}]%s[/color]" % [HudKit.SHOUT.to_html(false), tr("%s shouts: %s") % ["[b]%s[/b]" % who, safe]],
				channel, from, tr("%s shouts: %s") % [from, text])
		PARTY:
			_push("[color=#%s{a}]%s [b]%s[/b]: %s[/color]" % [PARTY_COLOUR.to_html(false), tr("[Party]"), who, safe],
				channel, from, "%s %s: %s" % [tr("[Party]"), from, text])
		_:
			_push("[color=#%s{a}][b]%s[/b][/color][color=#%s{a}]: %s[/color]" % [house_colour(house).to_html(false), who,
				HudKit.TEXT.to_html(false), safe], channel, from, "%s: %s" % [from, text])

## A line the game itself says (already in the player's language).
func add_system_line(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	_push("[color=#%s{a}]%s[/color]" % [SYSTEM_COLOUR.to_html(false), _escape(text)], SYSTEM, "", text)

## A local speaker's name: its house colour lightened, gold when the house is
## not known.
static func house_colour(house: String) -> Color:
	var houses: Variant = RealmContent.table("houses")
	var data: Dictionary = (houses as Dictionary).get(house, {}) if houses is Dictionary else {}
	if data.has("primary_color"):
		return Color.html(String(data["primary_color"])).lightened(0.45)
	return HudKit.GOLD_LT

func _push(bb: String, channel: int, from: String, plain: String) -> void:
	_lines.append({"t": Time.get_ticks_msec() / 1000.0, "bb": bb, "channel": channel, "from": from, "text": plain})
	while _lines.size() > HISTORY:
		_lines.pop_front()
	_dirty = true
	_rebuild()

## Text from a player or the server never opens a tag of its own.
static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")

func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = 0.25
		if not _focused:
			_dirty = true
		_rebuild()

func _rebuild() -> void:
	if not _dirty or history == null:
		return
	_dirty = false
	var now := Time.get_ticks_msec() / 1000.0
	var out := PackedStringArray()
	if _focused:
		for line: Dictionary in _lines:
			out.append(String(line["bb"]).replace("{a}", "ff"))
	else:
		for i in range(maxi(0, _lines.size() - IDLE_LINES), _lines.size()):
			var age := now - float(_lines[i]["t"])
			var a := clampf(1.0 - (age - IDLE_FADE_AFTER) / IDLE_FADE_TIME, 0.0, 1.0)
			if a <= 0.0:
				continue
			var line_bb := String(_lines[i]["bb"]).replace("{a}", "%02x" % int(a * 255.0))
			if a < 1.0:
				line_bb = "[outline_color=#000000%02x]%s[/outline_color]" % [int(a * 235.0), line_bb]
			out.append(line_bb)
	_show("\n".join(out))
	# Idle, whole lines only: the oldest goes while the rest overflow the box
	# (a wrapped line would otherwise hang half cut off at the top).
	while not _focused and out.size() > 1 and history.size.y > 0.0 and history.get_content_height() > history.size.y:
		out.remove_at(0)
		_show("\n".join(out))

func _show(text: String) -> void:
	if history.text != text:
		history.text = text

## The stored lines (newest last) as {channel, from, text}: what the checks
## read.
func lines() -> Array:
	return _lines.map(func(line): return {"channel": line["channel"], "from": line["from"], "text": line["text"]})
