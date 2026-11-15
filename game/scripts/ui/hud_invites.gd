extends Control
class_name HudInvites

## Invitation cards, top centre (the old game's approved card): a party
## invitation, a duel challenge, a group duel challenge or a dungeon ready
## check names who asked, runs a timer bar down over the server's answer
## window (TTL_S; a ready check's own end) and answers with the same chat
## commands the player can type (`/accept` and `/decline` for a party,
## `/daccept` and `/ddecline` for a duel), so a card is a thin shortcut over
## the server's own flow; a ready check answers with
## RealmSession.dungeon_ready. Cards are wide, framed in the invitation's
## colour, slide in with a chime and pulse until answered; a new invitation of
## the same kind replaces the old one.

const CARD_W := 404.0
## The coordinator's INVITE_TTL and the map server's duel REQUEST_TICKS.
const TTL_S := 30.0
const MAX_CARDS := 3
const ACCENTS := {
	"party": Color(0.46, 0.74, 1.0),
	"duel": Color(1.0, 0.40, 0.32),
	"group_duel": Color(1.0, 0.58, 0.24),
	"dungeon": Color(0.77, 0.61, 1.0),
}
## What each answer sends: [accept, decline].
const ANSWERS := {
	"party": ["/accept", "/decline"],
	"duel": ["/daccept", "/ddecline"],
	"group_duel": ["/daccept", "/ddecline"],
}

var session: Node
var _stack: VBoxContainer
## The ready check the dungeon card answers (0 = none).
var _dungeon_check := 0

func _init() -> void:
	name = "Invites"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stack = VBoxContainer.new()
	_stack.name = "Stack"
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_theme_constant_override("separation", 10)
	add_child(_stack)

func _process(_delta: float) -> void:
	# Top centre, a fifth of the way down: under the target card, above the
	# character.
	var area := get_viewport_rect().size
	_stack.position = Vector2(roundf((area.x - CARD_W) * 0.5), roundf(maxf(150.0, area.y * 0.2)))
	_stack.size = Vector2(CARD_W, 0.0)

## Show the card for `kind` from `from_name` (replacing one of the same kind);
## `party_size` is a group duel's head count.
func push(kind: String, from_name: String, party_size := 1) -> InviteCard:
	# Cards leave the stack at once: a freed card stayed a child until the
	# frame's end, so the count below never fell and the loop never ended
	# (four invite kinds, three cards: the game hung).
	for card in _stack.get_children():
		if card is InviteCard and (card as InviteCard).kind == kind:
			_stack.remove_child(card)
			card.queue_free()
	var card := InviteCard.new()
	card.setup(kind, from_name, party_size, ACCENTS.get(kind, HudKit.GOLD))
	card.answered.connect(_on_answered)
	_stack.add_child(card)
	_stack.move_child(card, 0)
	while _stack.get_child_count() > MAX_CARDS:
		var oldest := _stack.get_child(_stack.get_child_count() - 1)
		_stack.remove_child(oldest)
		oldest.queue_free()
	AudioManager.play_sound_at("ui_quest", Vector3.ZERO, null, true)
	return card

## A dungeon ready check asks the player once (the leader is ready already);
## its end (cancelled, launch) takes the card away. `view` is the check
## (ReadyView: id, dungeon, difficulty, leader, members [[name, level,
## ready]], ends_tick).
func on_dungeon_ready(view: Dictionary) -> void:
	var id := int(view.get("id", 0))
	if id == 0 or id == _dungeon_check or session == null:
		return
	var own := String((session.sheet() as Dictionary).get("name", ""))
	for m: Array in view.get("members", []):
		if String(m[0]) == own and bool(m[2]):
			return
	_dungeon_check = id
	var card := push("dungeon", String(view.get("leader", "")), (view.get("members", []) as Array).size())
	card.detail = "%s - %s" % [DungeonData.display_name(String(view.get("dungeon", ""))),
		DungeonData.difficulty_name(DungeonData.difficulty_id(int(view.get("difficulty", 1))))]
	var now := float(session.server_tick())
	if now >= 0.0:
		card.ttl_s = maxf(1.0, (float(view.get("ends_tick", 0)) - now) / float(RealmInfo.sim_hz()))

## The ready check ended (cancelled, or the party is on its way in).
func clear_dungeon() -> void:
	_dungeon_check = 0
	for card in _stack.get_children():
		if card is InviteCard and (card as InviteCard).kind == "dungeon":
			_stack.remove_child(card)
			card.queue_free()

func _on_answered(kind: String, accept: bool) -> void:
	if kind == "dungeon":
		if session != null and _dungeon_check != 0:
			session.dungeon_ready(_dungeon_check, accept)
		AudioManager.play_sound_at("ui_confirm" if accept else "ui_cancel", Vector3.ZERO, null, true)
		return
	var pair: Array = ANSWERS.get(kind, ["", ""])
	var command := String(pair[0] if accept else pair[1])
	if command != "" and session != null:
		session.send_chat(command)
	AudioManager.play_sound_at("ui_confirm" if accept else "ui_cancel", Vector3.ZERO, null, true)

## The card of `kind` still waiting for an answer, or null.
func card_of(kind: String) -> InviteCard:
	for card in _stack.get_children():
		if card is InviteCard and (card as InviteCard).kind == kind and not card.is_queued_for_deletion() \
				and not (card as InviteCard).closing:
			return card
	return null


## One invitation: emblem, title, who asked, the timer bar and the two answers.
class InviteCard extends PanelContainer:
	signal answered(kind: String, accept: bool)

	var kind := "party"
	var from_name := ""
	var closing := false
	## A line under the sentence (the dungeon and its difficulty).
	var detail := "":
		set(v):
			detail = v
			if _detail != null:
				_detail.text = v
				_detail.visible = v != ""
	## Seconds the answer window lasts (a ready check sends its own end).
	var ttl_s := HudInvites.TTL_S
	var _detail: Label
	var _accent := HudKit.GOLD
	var _box: StyleBoxFlat
	var _bar: TimerBar
	var _born_ms := 0

	func setup(p_kind: String, p_from: String, party_size: int, accent: Color) -> void:
		kind = p_kind
		from_name = p_from
		_accent = accent
		name = "Invite_%s" % kind
		custom_minimum_size = Vector2(HudInvites.CARD_W, 0.0)
		mouse_filter = Control.MOUSE_FILTER_STOP
		_box = StyleBoxFlat.new()
		_box.bg_color = Color(0.031, 0.040, 0.067, 0.97)
		_box.border_color = accent.lerp(HudKit.GOLD, 0.45)
		_box.set_border_width_all(2)
		_box.set_corner_radius_all(10)
		_box.shadow_color = Color(accent.r, accent.g, accent.b, 0.32)
		_box.shadow_size = 16
		_box.content_margin_left = 14
		_box.content_margin_right = 14
		_box.content_margin_top = 12
		_box.content_margin_bottom = 12
		_box.anti_aliasing = true
		add_theme_stylebox_override("panel", _box)

		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 10)
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(column)

		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 14)
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(head)
		var emblem := InviteEmblem.new()
		emblem.kind = kind
		emblem.accent = accent
		head.add_child(emblem)
		var words := VBoxContainer.new()
		words.add_theme_constant_override("separation", 3)
		words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		words.alignment = BoxContainer.ALIGNMENT_CENTER
		words.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_child(words)
		words.add_child(HudKit.label(I18n.upper(_title()), 15, accent.lerp(HudKit.GOLD_HI, 0.35), HudKit.title(), 4))
		var body := RichTextLabel.new()
		body.bbcode_enabled = true
		body.fit_content = true
		body.scroll_active = false
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		body.add_theme_font_override("normal_font", HudKit.body())
		body.add_theme_font_override("bold_font", HudKit.bold())
		body.add_theme_font_size_override("normal_font_size", 16)
		body.add_theme_font_size_override("bold_font_size", 16)
		body.add_theme_color_override("default_color", HudKit.PARCHMENT)
		body.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		body.add_theme_constant_override("outline_size", UITheme.outline_for(16, 3))
		body.text = _sentence(p_from, party_size)
		words.add_child(body)
		_detail = HudKit.label("", 14, accent.lerp(HudKit.GOLD_HI, 0.5), HudKit.bold(), 3)
		_detail.visible = false
		words.add_child(_detail)

		_bar = TimerBar.new()
		_bar.accent = accent
		column.add_child(_bar)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(row)
		var yes := _answer_button(tr("Accept"), Color(0.30, 0.78, 0.38))
		yes.pressed.connect(func(): answer(true))
		row.add_child(yes)
		var no := _answer_button(tr("Decline"), Color(0.86, 0.30, 0.26))
		no.pressed.connect(func(): answer(false))
		row.add_child(no)

	func _title() -> String:
		match kind:
			"duel":
				return tr("Duel Challenge")
			"group_duel":
				return tr("Group Duel Challenge")
			"dungeon":
				return tr("Ready Check")
		return tr("Party Invitation")

	func _sentence(who_name: String, party_size: int) -> String:
		var who := "[b][color=#%s]%s[/color][/b]" % [HudKit.GOLD_HI.to_html(false), who_name.replace("[", "[lb]")]
		match kind:
			"duel":
				return tr("%s challenges you to a duel.") % who
			"group_duel":
				return tr("%s challenges your party to a group duel (%d players).") % [who, party_size]
			"dungeon":
				return tr("%s wants to enter the dungeon with the party (%d players). Ready?") % [who, party_size]
		return tr("%s invites you to join their party.") % who

	func _answer_button(text: String, tint: Color) -> Button:
		var b := Button.new()
		b.text = text
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 36)
		for state in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.set_corner_radius_all(6)
			sb.set_border_width_all(1)
			sb.content_margin_top = 6
			sb.content_margin_bottom = 6
			sb.anti_aliasing = true
			match state:
				"hover":
					sb.bg_color = tint.darkened(0.45)
					sb.border_color = tint.lightened(0.35)
					sb.shadow_color = Color(tint.r, tint.g, tint.b, 0.35)
					sb.shadow_size = 6
				"pressed":
					sb.bg_color = tint.darkened(0.7)
					sb.border_color = tint
				"focus":
					sb.draw_center = false
					sb.border_color = tint.lightened(0.35)
				_:
					sb.bg_color = tint.darkened(0.62)
					sb.border_color = tint.darkened(0.1)
			b.add_theme_stylebox_override(state, sb)
		b.add_theme_font_override("font", HudKit.bold())
		b.add_theme_font_size_override("font_size", 15)
		b.add_theme_color_override("font_color", HudKit.PARCHMENT)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_color_override("font_pressed_color", HudKit.GOLD_LT)
		b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		b.add_theme_constant_override("outline_size", UITheme.outline_for(15, 3))
		return b

	func _ready() -> void:
		_born_ms = Time.get_ticks_msec()
		modulate.a = 0.0
		create_tween().tween_property(self, "modulate:a", 1.0, 0.18)

	func _process(_delta: float) -> void:
		var age := float(Time.get_ticks_msec() - _born_ms) / 1000.0
		var left := clampf(1.0 - age / maxf(1.0, ttl_s), 0.0, 1.0)
		_bar.fraction = left
		# A pulse on the frame for the first seconds, then a slow breath.
		var speed := 7.0 if age < 4.0 else 2.4
		var glow := 0.5 + 0.5 * sin(age * speed)
		_box.shadow_size = int(lerpf(12.0, 22.0, glow) if age < 4.0 else lerpf(12.0, 16.0, glow))
		_box.border_color = _accent.lerp(HudKit.GOLD, 0.45).lerp(_accent.lightened(0.3), glow * (0.8 if age < 4.0 else 0.3))
		if left <= 0.0 and not closing:
			_close()

	## Accept or Decline (the buttons; the check presses them the same way).
	func answer(accept: bool) -> void:
		if closing:
			return
		answered.emit(kind, accept)
		_close()

	func _close() -> void:
		closing = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tween := create_tween()
		tween.tween_property(self, "modulate:a", 0.0, 0.16)
		tween.tween_callback(queue_free)


## The time left to answer: a thin bar in the invitation's colour.
class TimerBar extends Control:
	var accent := HudKit.GOLD
	var fraction := 1.0:
		set(v):
			if absf(v - fraction) > 0.001:
				fraction = v
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 5)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
		var fill := Rect2(Vector2.ZERO, Vector2(size.x * fraction, size.y))
		var tint := accent if fraction > 0.25 else accent.lerp(Color(1.0, 0.3, 0.25), 0.6)
		draw_rect(fill, tint.darkened(0.15))
		draw_rect(Rect2(Vector2.ZERO, Vector2(fill.size.x, 1.0)), tint.lightened(0.35))


## The card's medallion: a dark disc in a coloured ring with the invitation's
## glyph - three figures for a party, crossed wands for a duel (with figures
## behind them for a group duel). Drawn in code like the rest of the HUD kit.
class InviteEmblem extends Control:
	var kind := "party"
	var accent := HudKit.GOLD

	func _init() -> void:
		custom_minimum_size = Vector2(56, 56)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 2.0
		draw_circle(c, r + 2.0, Color(accent.r, accent.g, accent.b, 0.18))
		draw_circle(c, r, Color(0.020, 0.027, 0.047))
		draw_arc(c, r, 0.0, TAU, 48, accent.lerp(HudKit.GOLD, 0.35), 2.0, true)
		draw_arc(c, r - 4.0, 0.0, TAU, 48, Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35), 1.0, true)
		var ink := accent.lerp(HudKit.GOLD_HI, 0.45)
		if kind == "party":
			_figure(c + Vector2(-10, 3), 0.8, ink.darkened(0.25))
			_figure(c + Vector2(10, 3), 0.8, ink.darkened(0.25))
			_figure(c + Vector2(0, 0), 1.0, ink)
			return
		if kind == "dungeon":
			# A portcullis: the gate the party is about to go through.
			draw_rect(Rect2(c + Vector2(-13, -14), Vector2(26, 28)), Color(0, 0, 0, 0.4))
			for i in 5:
				var x := -12.0 + 6.0 * float(i)
				draw_line(c + Vector2(x, -14), c + Vector2(x, 15), ink, 2.4, true)
			for y in [-7.0, 4.0]:
				draw_line(c + Vector2(-14, y), c + Vector2(14, y), ink.darkened(0.2), 2.4, true)
			draw_arc(c + Vector2(0, -14), 14.0, PI, TAU, 18, ink, 2.4, true)
			return
		if kind == "group_duel":
			_figure(c + Vector2(-12, 6), 0.65, ink.darkened(0.45))
			_figure(c + Vector2(12, 6), 0.65, ink.darkened(0.45))
		_wand(c + Vector2(-12, 12), c + Vector2(11, -11), ink)
		_wand(c + Vector2(12, 12), c + Vector2(-11, -11), ink)
		draw_circle(c + Vector2(0, -15), 2.2, Color(1.0, 0.95, 0.8))

	func _figure(at: Vector2, s: float, col: Color) -> void:
		draw_circle(at + Vector2(0, -7) * s, 4.6 * s, col)
		draw_arc(at + Vector2(0, 9) * s, 9.0 * s, PI, TAU, 18, col, 4.0 * s, true)

	func _wand(from: Vector2, to: Vector2, col: Color) -> void:
		draw_line(from, to, Color(0, 0, 0, 0.6), 5.0, true)
		draw_line(from, to, col, 3.0, true)
		draw_line(from, from.lerp(to, 0.28), col.darkened(0.35), 4.2, true)   # the grip
		draw_circle(to, 2.4, col.lightened(0.4))
