extends Node3D
class_name CombatView

## Combat as the session reports it, drawn: when a cast starts the caster's
## hero plays the spell's clip and a bolt spell's charge gathers at its wand;
## on the release a bolt leaves the wand (homing on the creature the cast
## named), a cone sweeps out of it or a ward rises round the caster; where a
## bolt lands its impact plays on the body or, for an area spell, a burst on
## the spot; a damage number rises over whoever is hit. The looks are
## SpellEffect stages (VFXLibrary) and WardShield, their sounds AudioManager's.
## A creature's telegraphed ability burns on the ground where it will land
## (GroundWarning), its fire reaching the boundary on the server's release
## tick, while the creature plays the ability's clip; on the release the
## warning flashes out and the ability's impact plays (a thrown boulder lands
## there first). A creature's bolt flies straight from where the server
## launched it.
## It decides nothing; every event comes from the server through
## RealmSession.take_combat_events, which main.gd drains once per frame and
## hands here (`show_event`).

## Where a cast aims on a creature, above its feet (the server's chest height).
const CHEST := 1.15
## A body's nameplate stands this much over its head_height (where the view
## has one); damage numbers on any body but the player's stand over the plate.
const PLATE_OVER_HEAD := 0.45
## The local player's numbers stand at the chest (the nameplate holds the space
## over the head): blows on the camera's right, healing on its left.
const OWN_NUMBER_HEIGHT := 1.3
const HERO_GIRTH := 0.4
## Health coming back by this much at once is shown (the share of the maximum,
## at least HEAL_SHOWN): a potion or life steal, not the steady regeneration.
const HEAL_SHARE := 0.02
const HEAL_SHOWN := 8
## Where a hero without a wand prop casts from (the server's wand height).
const WAND_HEIGHT := 1.2
## A body's girth where a spell meets it.
const BODY_RADIUS := 0.45
## Hit flags (realm_proto CombatEvent::Hit).
const FLAG_CRIT := 1
const FLAG_FINISHER := 2
## A creature walking home shrugged the blow off (amount 0).
const FLAG_EVADE := 64
## What an area ability's release plays when its data names no impact (the
## old game's default), and what a cone's plays from the creature's chest.
const AREA_IMPACT := "shockwave"
const CONE_CAST := "disarm"
## The thrown boulder: the grounds' rock, this big across; the last stretch
## of the windup at most is its flight, on an arc this high.
const BOULDER_MODEL := "res://assets/models/vegetation/rock_boulder.glb"
const BOULDER_SIZE := 1.5
const BOULDER_FLIGHT := 0.55
const BOULDER_ARC := 5.0
## Longest a landing bolt takes to reach where it struck.
const LAND_SECONDS := 0.25

## The local player's entity id and hero, the other players' heroes and the
## modelled creatures by entity id (main.gd's tables).
var own_id := 0
var player: HeroView
var heroes: Dictionary = {}
var beasts: Dictionary = {}
## Every body's drawn position this frame by entity id, own included (main.gd
## fills it before the events are shown).
var drawn: Dictionary = {}
## The RealmSession: the ground under a burst, the player's house and skills.
var session: Node
## The player's health as last seen (note_health).
var _seen_hp := 0
var _seen_max := 0
## Bolts in flight: {node, effect, caster, spell, target, velocity, left, path,
## travelled, length, amp, side}.
var _bolts: Array = []
## Per caster: what its last cast named (spell, target, aim), and its basic
## chain step.
var _cast_targets := {}
var _chain := {}
## Raised wards by caster entity id.
var _wards := {}
## Telegraphs by caster entity id: {warning, start, release, recovery, data,
## rock, from}.
var _telegraphs := {}
## A creature's hit this many ticks before its telegraph's release tick is
## the telegraph landing.
const RELEASE_SLACK := 4.0
## What the check reads: telegraphs shown, released and cancelled, boulders
## thrown, creature bolts launched, evades shown.
var telegraphs_seen := 0
var telegraphs_released := 0
var telegraphs_cancelled := 0
var boulders_thrown := 0
var creature_bolts := 0
var evades_shown := 0
static var _boulder_scene: PackedScene = null

static func spell(id: String) -> Dictionary:
	return HudActionBar.spells().get(id, {})

static func _delivery(id: String) -> String:
	return String(spell(id).get("delivery", ""))

func _init() -> void:
	name = "CombatView"

func _ready() -> void:
	# Every spell's sheets and sounds, before the first cast needs them.
	for id: String in VFXLibrary.SPELLS:
		SkillFX.warm_spell(id)

func show_event(event: Dictionary) -> void:
	match String(event.get("kind", "")):
		"cast_started":
			_cast_started(event)
		"cast_released":
			_released(event)
		"burst":
			var caster := int(event["caster"])
			var spell_id := String(event["spell"])
			var at: Vector3 = event["at"]
			if not _land(caster, spell_id, at, 0, func(dir: Vector3): _burst(caster, spell_id, at, dir)):
				_burst(caster, spell_id, at, at - (drawn.get(caster, at) as Vector3))
		"telegraph":
			_telegraph(event)
		"telegraph_cancelled":
			_end_telegraph(int(event["caster"]), false)
		"hit":
			_strike_lands(int(event["attacker"]))
			event = _named_blow(event)
			if not _land(int(event["attacker"]), String(event["spell"]), Vector3.ZERO, int(event["target"]),
					func(dir: Vector3): _hit(event, dir)):
				_hit(event, _incoming(event))

## A creature's blow names no spell (the server's hit carries none for a
## creature): when the creature has a bolt in the air the blow is that bolt,
## so the bolt finishes its flight onto the body and its impact plays there.
func _named_blow(event: Dictionary) -> Dictionary:
	var attacker := int(event["attacker"])
	if String(event["spell"]) != "" or _hero(attacker) != null:
		return event
	for bolt: Dictionary in _bolts:
		if int(bolt["caster"]) == attacker and not bolt.has("then"):
			var named := event.duplicate()
			named["spell"] = bolt["spell"]
			return named
	return event

## The caster's hero plays the spell's clip, its release on the server's
## windup (half the spell's cast lock, in whole ticks); a bolt spell's charge
## gathers at the wand meanwhile (the basic flick's sparks wait for the
## release).
func _cast_started(event: Dictionary) -> void:
	var caster := int(event["caster"])
	var spell_id := String(event["spell"])
	var aim: Vector3 = event.get("aim", Vector3.ZERO)
	_cast_targets[caster] = {"spell": spell_id, "target": int(event.get("target", 0)), "aim": aim}
	var data := spell(spell_id)
	var now := Time.get_ticks_msec() / 1000.0
	var step := 0
	if spell_id == "basic_cast":
		var chain: Dictionary = _chain.get(caster, {"next": 0, "until": 0.0})
		step = int(chain["next"]) if now <= float(chain["until"]) else 0
		var steps := maxi(1, (data.get("combo_multipliers", [1]) as Array).size())
		_chain[caster] = {"next": (step + 1) % steps, "until": now + float(data.get("combo_window", 1.2))}
	else:
		_chain.erase(caster)
	var hero := _hero(caster)
	if hero == null:
		return
	var hz := float(RealmInfo.sim_hz())
	var windup := maxf(1.0, round(float(data.get("cast_lock", 0.28)) * 0.5 * hz)) / hz
	hero.play_cast(spell_id, aim, windup, step)
	if spell_id != "basic_cast" and _delivery(spell_id).begins_with("projectile"):
		var wand := hero.position + Vector3.UP * WAND_HEIGHT
		SkillFX.play_cast(self, hero, spell_id, wand, aim - wand, _house(caster))

## The release: a cone sweeps out of the wand, a ward rises round the caster,
## anything else flies as a bolt.
func _released(event: Dictionary) -> void:
	var caster := int(event["caster"])
	var spell_id := String(event["spell"])
	var from: Vector3 = event["from"]
	var dir: Vector3 = event["dir"]
	var hero := _hero(caster)
	match _delivery(spell_id):
		"cone":
			SkillFX.play_cast(self, hero, spell_id, from, dir, _house(caster))
		"self":
			SkillFX.play_cast(self, hero, spell_id, from, dir, _house(caster))
			_raise_ward(caster, hero, spell_id)
		_:
			if hero == null:
				# A creature's bolt: the flash where it leaves the body.
				creature_bolts += 1
				SkillFX.play_cast(self, null, spell_id, from, dir)
			elif spell_id == "basic_cast":
				SkillFX.play_cast(self, hero, spell_id, from, dir, _house(caster))
			_launch(caster, spell_id, SkillFX.emission_origin(hero, from), dir)

## A bolt leaves the wand: the spell's travel stage riding a point that flies
## at the spell's speed for its range, bending toward the cast's creature. A
## spell with a `curve` bows off the straight line, sideways by a fraction of
## its flight at a new angle every cast (rarely below it, so it does not dive
## into the floor).
func _launch(caster: int, spell_id: String, from: Vector3, dir: Vector3) -> void:
	var data := spell(spell_id)
	var speed := float(data.get("projectile_speed", 0.0))
	if speed <= 0.0:
		return
	# Only a hero's cast names a creature to home on; a creature's bolt flies
	# straight along the server's line.
	var hero_cast := _hero(caster) != null
	var named: Dictionary = _cast_targets.get(caster, {}) if hero_cast else {}
	var mine := String(named.get("spell", "")) == spell_id
	var target := int(named.get("target", 0)) if mine else 0
	var aim := SkillFX.safe_direction(dir)
	var node := Node3D.new()
	node.name = "Bolt"
	add_child(node)
	node.global_position = from
	var bolt := {"node": node, "caster": caster, "spell": spell_id, "target": target,
		"velocity": aim * speed, "left": float(data.get("range", 30.0)) / speed,
		"path": from, "travelled": 0.0, "length": 1.0, "amp": 0.0, "side": Vector3.ZERO,
		"effect": SkillFX.spawn_stage(self, spell_id, "travel", from, aim, _hero(caster),
			{"follow_target": node, "house": _house(caster)})}
	var bend := float((VFXLibrary.SPELLS.get(spell_id, {}) as Dictionary).get("curve", 0.0)) if hero_cast else 0.0
	if bend > 0.0:
		var end: Vector3 = from + aim * 15.0
		if drawn.has(target):
			end = (drawn[target] as Vector3) + Vector3.UP * CHEST
		elif mine:
			end = named.get("aim", end)
		bolt["length"] = maxf(1.0, from.distance_to(end))
		bolt["amp"] = clampf(bend * float(bolt["length"]), 0.25, 1.5)
		var right := aim.cross(Vector3.UP)
		right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
		var up := right.cross(aim).normalized()
		var angle := randf_range(-0.15 * PI, 1.15 * PI)
		bolt["side"] = (right * cos(angle) + up * sin(angle)).normalized()
	_bolts.append(bolt)

## The server says the caster's oldest bolt of that spell landed (on `target`,
## else at `at`). The server resolves a hit within a tick or two of the
## release, before the drawn bolt has crossed the gap, so the bolt finishes
## its flight there and `then` (the impact, the number) plays when it arrives,
## given the bolt's last direction. False when no such bolt is in the air (a
## cone, or one already gone).
func _land(caster: int, spell_id: String, at: Vector3, target: int, then: Callable) -> bool:
	for bolt: Dictionary in _bolts:
		if int(bolt["caster"]) == caster and String(bolt["spell"]) == spell_id and not bolt.has("then"):
			bolt["then"] = then
			bolt["end_at"] = at
			bolt["end_target"] = target
			# However far it still has to go, it gets there within LAND_SECONDS.
			bolt["left"] = maxf(float(bolt["left"]), LAND_SECONDS)
			return true
	return false

## The bolt at `index` ends: its wake fades where it is, and what was waiting
## on its arrival plays.
func _end_bolt(index: int) -> void:
	var bolt: Dictionary = _bolts[index]
	_bolts.remove_at(index)
	var effect: Variant = bolt["effect"]
	if is_instance_valid(effect):
		(effect as SpellEffect).retire_travel()
	if bolt.has("then"):
		(bolt["then"] as Callable).call((bolt["velocity"] as Vector3).normalized())
	(bolt["node"] as Node).queue_free()

## An area spell bursts on the spot, its ground ring on the floor under it,
## laid along the slope measured near its rim (where the ring is brightest).
func _burst(caster: int, spell_id: String, at: Vector3, dir: Vector3) -> void:
	var ground := _floor_under(at)
	var normal := Vector3.UP
	var reach := maxf(1.0, float(spell(spell_id).get("radius", 2.0)) * 0.8)
	var east := _floor_under(at + Vector3(reach, 0, 0), reach) - _floor_under(at - Vector3(reach, 0, 0), reach)
	var south := _floor_under(at + Vector3(0, 0, reach), reach) - _floor_under(at - Vector3(0, 0, reach), reach)
	if ground > SpellEffect.NO_FLOOR and absf(east) < reach * 2.0 and absf(south) < reach * 2.0:
		normal = Vector3(-east / (2.0 * reach), 1.0, -south / (2.0 * reach)).normalized()
	SkillFX.play_impact(self, at, spell_id, dir, ground, normal, _house(caster))

## A hit: the damage number, the blow's sound for the player's own hurt and
## own critical hits, a ripple on a raised ward, and the spell's impact on the
## side of the body it came from (an area spell's burst already covers its
## victims).
func _hit(event: Dictionary, dir: Vector3) -> void:
	var target := int(event["target"])
	var attacker := int(event["attacker"])
	var spell_id := String(event["spell"])
	_number(event)
	if target == own_id or (attacker == own_id and (int(event.get("flags", 0)) & FLAG_CRIT) != 0):
		AudioManager.play_hit()
	if not drawn.has(target):
		return
	var feet: Vector3 = drawn[target]
	# a Dark Shard is far wider than a creature: the impact lands on its face
	var body := _body(target)
	var radius: Variant = body.get("body_radius") if body != null else null
	var contact := SkillFX.body_contact(feet, CHEST, float(radius) if radius != null else BODY_RADIUS, dir)
	if is_instance_valid(_wards.get(target)):
		(_wards[target] as WardShield).on_hit(contact)
	if VFXLibrary.has_spell(spell_id) and _delivery(spell_id) != "projectile_aoe":
		SkillFX.play_hit_on(self, _body(target), contact, feet.y, spell_id, dir, _house(attacker))

## Which way a blow without a bolt came: from the attacker to the target.
func _incoming(event: Dictionary) -> Vector3:
	var at: Vector3 = drawn.get(int(event["target"]), Vector3.ZERO)
	return at - (drawn.get(int(event["attacker"]), at - Vector3.FORWARD) as Vector3)

## What a hit did, beside the body it landed on (FloatingText): the player's
## own blows in full, blows on the player in red at its side, everyone else's
## small; a tick of a burn or a bleed (a hero's hit naming no spell) stays low.
func _number(event: Dictionary) -> void:
	var target := int(event["target"])
	if not drawn.has(target):
		return
	var flags := int(event.get("flags", 0))
	var amount := int(event.get("amount", 0))
	var attacker := int(event.get("attacker", own_id))
	var crit := (flags & FLAG_CRIT) != 0
	var feet: Vector3 = drawn[target]
	var body := _body(target)
	var own := target == own_id
	# the player's own wounds beside it; every other body's over its nameplate
	# (a number set beside a far body, under its plate, landed by the player)
	var height := OWN_NUMBER_HEIGHT if own else _plate_of(body)
	var at := feet + Vector3.UP * height
	var girth := HERO_GIRTH if own else _girth_of(body)
	var plate := _plate_of(body) - height if own else -FloatingText.PLATE_AT
	var side := 1 if own else FloatingText.OVER
	if (flags & FLAG_EVADE) != 0:
		evades_shown += 1
		FloatingText.note(tr("Evaded"), target, at, body, girth, plate, side)
		return
	if amount <= 0:
		FloatingText.note(tr("Blocked"), target, at, body, girth, plate, side)
		return
	var style: int
	if own:
		style = FloatingText.Style.TAKEN_CRIT if crit else FloatingText.Style.TAKEN
	elif attacker != own_id:
		if _hero(target) != null:
			style = FloatingText.Style.ALLY_TAKEN
		else:
			style = FloatingText.Style.ALLY_CRIT if crit else FloatingText.Style.ALLY
	elif String(event.get("spell", "basic_cast")) == "":
		style = FloatingText.Style.TICK
	elif crit:
		style = FloatingText.Style.CRIT
	elif (flags & FLAG_FINISHER) != 0:
		style = FloatingText.Style.FINISHER
	else:
		style = FloatingText.Style.HIT
	FloatingText.figure(style, amount, target, at, body, girth, side, plate)

## Healing the player received, on the side away from the blows.
func show_heal(amount: int) -> void:
	if not drawn.has(own_id):
		return
	var at := (drawn[own_id] as Vector3) + Vector3.UP * OWN_NUMBER_HEIGHT
	FloatingText.figure(FloatingText.Style.HEAL, amount, own_id, at, player, HERO_GIRTH, -1,
		Nameplates.HERO_HEIGHT - OWN_NUMBER_HEIGHT)

## The server sends no heal event: a jump in the player's health is one (the
## same maximum and alive on both sides, so no level-up or rising).
func note_health(vitals: PackedInt32Array) -> void:
	if vitals.size() < 2:
		return
	var gained := vitals[0] - _seen_hp
	var steady := _seen_hp > 0 and vitals[0] > 0 and vitals[1] == _seen_max
	_seen_hp = vitals[0]
	_seen_max = vitals[1]
	if steady and gained >= maxi(HEAL_SHOWN, ceili(vitals[1] * HEAL_SHARE)):
		show_heal(gained)

## Where a body's nameplate stands over its feet (main.gd's and Nameplates').
static func _plate_of(body: Node3D) -> float:
	var top: Variant = body.get("head_height") if body != null else null
	return float(top) + PLATE_OVER_HEAD if top != null and float(top) > 0.5 else Nameplates.HERO_HEIGHT

static func _girth_of(body: Node3D) -> float:
	var radius: Variant = body.get("body_radius") if body != null else null
	return float(radius) if radius != null else BODY_RADIUS

## A ward round `hero` for as long as the server holds it: the spell's
## duration, scaled by the caster's skill level when it is the player's own.
## A new ward replaces the one held (Ward Shield or Shardglass Ward).
func _raise_ward(caster: int, hero: HeroView, spell_id := "ward_shield") -> void:
	if hero == null:
		return
	if is_instance_valid(_wards.get(caster)):
		(_wards[caster] as Node).queue_free()
	var seconds := float(spell(spell_id).get("duration_ms", 3500)) / 1000.0
	var combat: Variant = RealmContent.table("combat")
	if caster == own_id and session != null and combat is Dictionary:
		var skills: Dictionary = (combat as Dictionary).get("skills", {})
		var level := clampi(int(session.skill_level(spell_id)), 1, int(skills.get("max_level", 10)))
		seconds *= 1.0 + float(skills.get("effect_per_level", 0.0)) * (level - 1)
	_wards[caster] = WardShield.raise(self, hero, seconds, spell_id)

func _hero(id: int) -> HeroView:
	return player if id == own_id else heroes.get(id)

## The drawn body of an entity (a hero or a modelled creature), or null.
func _body(id: int) -> Node3D:
	var hero := _hero(id)
	return hero if hero != null else beasts.get(id)

## The caster's house, for a spell drawn in house colours (only the player's
## own is known).
func _house(caster: int) -> String:
	if caster != own_id or session == null:
		return ""
	return String((session.sheet() as Dictionary).get("house", ""))

## The ground under `at`, looking from `above` metres over it (a body
## standing there counts with its feet), or SpellEffect.NO_FLOOR.
func _floor_under(at: Vector3, above := 0.5) -> float:
	if session == null:
		return SpellEffect.NO_FLOOR
	var hit: Dictionary = session.pick(at + Vector3.UP * above, Vector3.DOWN, 30.0 + above)
	if hit.is_empty():
		return SpellEffect.NO_FLOOR
	var entity := int(hit["entity"])
	if entity != 0 and drawn.has(entity):
		return (drawn[entity] as Vector3).y
	var point: Vector3 = hit["point"]
	return point.y if point.y > at.y - 29.9 else SpellEffect.NO_FLOOR

## ---------------------------------------------------------------- telegraphs

## The server tick now, between whole ticks (the session's estimate).
func server_tick() -> float:
	return float(session.server_tick()) if session != null else 0.0

## A creature winds up a telegraphed ability: the warning on the ground, the
## creature's clip, and for a throw the rock in its hand.
func _telegraph(event: Dictionary) -> void:
	var caster := int(event["caster"])
	_end_telegraph(caster, false, true)
	telegraphs_seen += 1
	var release := int(event["release_tick"])
	var recovery := int(event["recovery_tick"])
	var now := server_tick()
	# The countdown runs from the server's start tick; one that arrived late
	# shows the fire already part way out.
	var start := minf(float(event.get("start_tick", release - 1)), float(release) - 1.0)
	var entry := {"start": start, "release": release, "recovery": recovery, "data": event}
	var cone := String(event.get("shape", "area")) == "cone"
	if DisplayServer.get_name() != "headless":
		var center: Vector3 = event["center"]
		# Snapshot yaw 0 looks along -Z; the warning's cone opens along +Z.
		var facing := float(event.get("yaw", 0.0)) + PI
		var reach := float(event.get("range", 8.0)) if cone else float(event.get("radius", 5.0))
		entry["warning"] = GroundWarning.spawn(self, center, reach,
			float(event.get("half_angle", 0.6)) if cone else 0.0, facing)
	if String(event.get("flight", "")) == "boulder":
		boulders_thrown += 1
		if DisplayServer.get_name() != "headless":
			entry["rock"] = _boulder()
	var hz := float(RealmInfo.sim_hz())
	var beast: Node = beasts.get(caster)
	if beast != null and is_instance_valid(beast):
		beast.begin_ability(String(event.get("clip", "")), (float(release) - now) / hz, (float(recovery) - now) / hz)
	_telegraphs[caster] = entry
	_drive_telegraph(caster, entry, now)

## The telegraph of `caster` ends: on its release tick (`landed`: the warning
## flashes out and the impact plays) or called off (it cools away, the clip
## and the rock with it). `quiet`: replaced by a new one, nothing counted.
func _end_telegraph(caster: int, landed: bool, quiet := false) -> void:
	var entry: Dictionary = _telegraphs.get(caster, {})
	if entry.is_empty():
		return
	_telegraphs.erase(caster)
	var warning: Variant = entry.get("warning")
	var rock: Variant = entry.get("rock")
	if is_instance_valid(rock):
		(rock as Node).queue_free()
	if landed:
		telegraphs_released += 1
		if is_instance_valid(warning):
			(warning as GroundWarning).release()
		_ability_impact(caster, entry["data"])
		return
	if not quiet:
		telegraphs_cancelled += 1
	if is_instance_valid(warning):
		(warning as GroundWarning).cancel()
	var beast: Node = beasts.get(caster)
	if beast != null and is_instance_valid(beast):
		beast.cancel_ability()

## A creature's blow arrived: a telegraph of its due within RELEASE_SLACK
## ticks is its release (the hit and the flash land together, whatever the
## clock's jitter).
func _strike_lands(attacker: int) -> void:
	var entry: Dictionary = _telegraphs.get(attacker, {})
	if not entry.is_empty() and server_tick() >= float(entry["release"]) - RELEASE_SLACK:
		_end_telegraph(attacker, true)

## The release: an area ability's impact bursts on its centre, a cone's blast
## leaves the creature's chest along its facing.
func _ability_impact(caster: int, data: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var impact := String(data.get("impact_fx", ""))
	var center: Vector3 = data["center"]
	if String(data.get("shape", "area")) == "cone":
		var yaw := float(data.get("yaw", 0.0))
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var from := (drawn.get(caster, center) as Vector3) + Vector3.UP * WAND_HEIGHT
		SkillFX.play_cast(self, null, impact if VFXLibrary.has_spell(impact) else CONE_CAST, from, dir)
		return
	_burst(0, impact if VFXLibrary.has_spell(impact) else AREA_IMPACT, center, Vector3.DOWN)

## The rock a creature throws: the grounds' boulder model sized to
## BOULDER_SIZE across, its centre on the node.
func _boulder() -> Node3D:
	if _boulder_scene == null:
		_boulder_scene = load(BOULDER_MODEL) as PackedScene
	var holder := Node3D.new()
	holder.name = "Boulder"
	add_child(holder)
	if _boulder_scene == null:
		return holder
	var model := _boulder_scene.instantiate() as Node3D
	holder.add_child(model)
	var box := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var node: Node = mesh
		while node != null and node != model:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var local: AABB = xf * mesh.get_aabb()
		box = local if first else box.merge(local)
		first = false
	var extent := maxf(0.01, maxf(box.size.x, maxf(box.size.y, box.size.z)))
	model.scale = Vector3.ONE * (BOULDER_SIZE / extent)
	model.position = -box.get_center() * model.scale
	return holder

## One frame of a telegraph: the fill follows the server tick from its start to
## its release; a held rock rides the thrower's hand, and over the last
## BOULDER_FLIGHT seconds flies on an arc to land on the centre at the release.
func _drive_telegraph(caster: int, entry: Dictionary, now: float) -> void:
	var release := float(entry["release"])
	var span := maxf(1.0, release - float(entry["start"]))
	var warning: Variant = entry.get("warning")
	if is_instance_valid(warning):
		(warning as GroundWarning).set_progress((now - float(entry["start"])) / span)
	var rock: Variant = entry.get("rock")
	if not is_instance_valid(rock):
		return
	var hz := float(RealmInfo.sim_hz())
	var left := (release - now) / hz
	var center: Vector3 = (entry["data"] as Dictionary)["center"]
	var node := rock as Node3D
	if left > BOULDER_FLIGHT:
		var beast: Node = beasts.get(caster)
		if beast != null and is_instance_valid(beast):
			node.global_position = beast.hand_position()
		elif drawn.has(caster):
			node.global_position = (drawn[caster] as Vector3) + Vector3.UP * 4.6
		entry["from"] = node.global_position
		return
	var from: Vector3 = entry.get("from", node.global_position)
	var t := clampf(1.0 - left / BOULDER_FLIGHT, 0.0, 1.0)
	node.global_position = from.lerp(center, t) + Vector3.UP * sin(t * PI) * BOULDER_ARC
	node.rotation = Vector3(t * 7.0, 0.0, t * 3.0)

func _process_telegraphs() -> void:
	if _telegraphs.is_empty():
		return
	var now := server_tick()
	for caster: int in _telegraphs.keys():
		var entry: Dictionary = _telegraphs[caster]
		if now >= float(entry["release"]):
			_end_telegraph(caster, true)
			continue
		# A caster gone from view or dead before its release takes its warning
		# with it (the server's own call-off follows).
		var beast: Node = beasts.get(caster)
		if not drawn.has(caster) or (beast != null and is_instance_valid(beast) and bool(beast.get("is_dead"))):
			_end_telegraph(caster, false)
			continue
		_drive_telegraph(caster, entry, now)

func _process(delta: float) -> void:
	_process_telegraphs()
	for i in range(_bolts.size() - 1, -1, -1):
		var bolt: Dictionary = _bolts[i]
		var node: Node3D = bolt["node"]
		bolt["left"] = float(bolt["left"]) - delta
		if float(bolt["left"]) <= 0.0:
			_end_bolt(i)
			continue
		var velocity: Vector3 = bolt["velocity"]
		if bolt.has("then"):
			# Landing: straight for where the server says it struck.
			var end: Vector3 = bolt["end_at"]
			var hit := int(bolt["end_target"])
			if hit != 0 and drawn.has(hit):
				end = (drawn[hit] as Vector3) + Vector3(0, CHEST, 0)
			var rest := end - node.global_position
			var speed := maxf(velocity.length(), rest.length() / LAND_SECONDS)
			if rest.length() <= speed * delta:
				node.global_position = end
				_end_bolt(i)
				continue
			velocity = rest.normalized() * speed
			bolt["velocity"] = velocity
			node.global_position += velocity * delta
		else:
			var path: Vector3 = bolt["path"]
			var target := int(bolt["target"])
			var step := velocity * delta
			if target != 0 and drawn.has(target):
				# Homing: it waits on the creature's chest for the hit to arrive.
				var to := (drawn[target] as Vector3) + Vector3(0, CHEST, 0) - path
				velocity = to.normalized() * velocity.length() if to.length_squared() > 0.0001 else velocity
				bolt["velocity"] = velocity
				step = to if to.length() <= velocity.length() * delta else velocity * delta
			bolt["path"] = path + step
			bolt["travelled"] = float(bolt["travelled"]) + step.length()
			var bow := sin(PI * clampf(float(bolt["travelled"]) / float(bolt["length"]), 0.0, 1.0))
			node.global_position = path + step + (bolt["side"] as Vector3) * float(bolt["amp"]) * bow
		var effect: Variant = bolt["effect"]
		if is_instance_valid(effect):
			(effect as SpellEffect).direction = velocity.normalized()
