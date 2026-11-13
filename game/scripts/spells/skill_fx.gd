extends RefCounted
class_name SkillFX

## The spell effects facade over SpellEffect: where a stage is emitted from
## and what it follows. The rules it keeps for every effect:
##   * a cast leaves the hero's actual wand tip when it holds a wand
##     (HeroAppearance.wand_tip), else the server's launch point;
##   * zero-length aims fall back to a safe direction;
##   * effects are presentation: nothing here can produce a hit.

## Effect quality ("low", "medium", "high", VFXLibrary.QUALITY). Low is the
## default: the players' machines include integrated GPUs, and low keeps every
## layer that carries the gameplay information.
static var quality := "low"
## Spells whose stage textures were already loaded, and what was loaded (held
## for the session so a warmed sheet cannot drop out before its impact frame).
static var _warmed: Dictionary = {}
static var _warm_cache: Dictionary = {}

## An aim direction that is never zero-length.
static func safe_direction(raw: Vector3, fallback: Vector3 = Vector3.FORWARD) -> Vector3:
	if raw.length_squared() >= 0.0001:
		return raw.normalized()
	return fallback.normalized() if fallback.length_squared() >= 0.0001 else Vector3.FORWARD

static func spawn_stage(world: Node3D, spell_id: String, stage: String, origin: Vector3,
		dir: Vector3, caster: Node3D = null, opts: Dictionary = {}) -> SpellEffect:
	if not is_instance_valid(world) or not VFXLibrary.has_spell(spell_id) \
			or not VFXLibrary.stages_for(spell_id).has(stage):
		return null
	var effect := SpellEffect.new()
	world.add_child(effect)
	effect.setup(spell_id, stage, quality, origin, safe_direction(dir), caster, opts)
	return effect

## Load a spell's stage textures and sounds ahead of them: a 2048 impact sheet
## read from disk on the impact frame shows up late, after the damage number.
static func warm_spell(spell_id: String) -> void:
	if DisplayServer.get_name() == "headless" or _warmed.has(spell_id):
		return
	_warmed[spell_id] = true
	var tree := Engine.get_main_loop() as SceneTree
	var audio := tree.root.get_node_or_null("AudioManager") if tree != null else null
	var stages := VFXLibrary.stages_for(spell_id)
	for stage: String in stages:
		var key := String((stages[stage] as Dictionary).get("audio", ""))
		if key != "" and audio != null:
			audio.warm_sound(key)
		for raw: Variant in (stages[stage] as Dictionary).get("layers", []):
			if not raw is Dictionary:
				continue
			for field in ["atlas", "tex"]:
				var path := VFXLibrary.asset_path(String(raw.get(field, "")))
				if path != "" and not _warm_cache.has(path):
					_warm_cache[path] = SpellEffect.asset(path)

## The wand tip of a hero's equipped wand, or null.
static func wand_tip(hero: Node3D) -> Node3D:
	if hero == null or not is_instance_valid(hero) or not "body" in hero:
		return null
	var tip := HeroAppearance.wand_tip(hero.get("body"))
	return tip if tip != null and is_instance_valid(tip) else null

## Where a spell leaves `hero`: its wand tip, else `fallback`.
static func emission_origin(hero: Node3D, fallback: Vector3) -> Vector3:
	var tip := wand_tip(hero)
	return tip.global_position if tip != null else fallback

## The cast stage at the caster: a ward rises round the body, a bolt spell's
## charge rides the wand (or the body, without one), a cone starts at the wand
## and points down the aim.
static func play_cast(world: Node3D, hero: Node3D, spell_id: String, spawn_pos: Vector3,
		dir: Vector3, house: String = "") -> SpellEffect:
	warm_spell(spell_id)
	var aim := safe_direction(dir)
	var origin := emission_origin(hero, spawn_pos)
	var opts := {"house": house}
	var live := hero != null and is_instance_valid(hero)
	var delivery := String(HudActionBar.spells().get(spell_id, {}).get("delivery", ""))
	if delivery == "self" and live:
		origin = hero.global_position + Vector3.UP
		opts["follow_target"] = hero
	elif live and delivery != "cone":
		var tip := wand_tip(hero)
		opts["follow_target"] = tip if tip != null else hero
	if live:
		opts["floor_y"] = hero.global_position.y
	return spawn_stage(world, spell_id, "cast", origin, aim, hero if live else null, opts)

## An area spell's impact at `pos`, its ground ring on the floor under it
## (`floor_y`, sloping along `floor_normal`).
static func play_impact(world: Node3D, pos: Vector3, spell_id: String, incoming: Vector3,
		floor_y: float, floor_normal: Vector3, house: String = "") -> SpellEffect:
	return spawn_stage(world, spell_id, "impact", pos, safe_direction(incoming), null,
		{"target_position": pos, "floor_y": floor_y, "floor_normal": floor_normal, "house": house})

## A spell's impact ON a body: at the point of its surface the spell met
## (`contact`, see body_contact), riding along with the body when it has a
## node. Drawn there rather than at the body's centre, where the body's own
## mesh hid it.
static func play_hit_on(world: Node3D, victim: Node3D, contact: Vector3, feet_y: float,
		spell_id: String, incoming: Vector3, house: String = "") -> SpellEffect:
	var dir := safe_direction(incoming)
	var opts := {"target_position": contact, "floor_y": feet_y, "house": house}
	if victim != null and is_instance_valid(victim):
		opts["follow_target"] = victim
	return spawn_stage(world, spell_id, "impact", contact - dir * 0.12, dir, null, opts)

## Where a spell coming along `incoming` meets a body standing at `feet`: on
## its surface at chest height, on the side it came from.
static func body_contact(feet: Vector3, chest: float, radius: float, incoming: Vector3) -> Vector3:
	var at := feet + Vector3.UP * chest
	var flat := Vector3(incoming.x, 0.0, incoming.z)
	if flat.length_squared() < 0.0001:
		return at
	return at - flat.normalized() * radius * 0.8
