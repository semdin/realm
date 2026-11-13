extends Node3D
class_name CombatView

## Combat as the session reports it, drawn: the caster's cast clip when a cast
## starts, a glowing bolt from the wand when a projectile is released (homing
## on the creature the cast named), a short expanding sphere where a spell
## bursts, and a damage number over whoever is hit. It decides nothing; every
## event comes from the server through RealmSession.take_combat_events, which
## main.gd drains once per frame and hands here (`show_event`).

## Where a cast aims on a creature, above its feet (the server's chest height).
const CHEST := 1.15
## Damage numbers start this far above the body's feet.
const NUMBER_HEIGHT := 2.0
const BOLT_RADIUS := 0.12
## The soft glow around a bolt, edge to edge (m).
const GLOW_SIZE := 0.9
const BURST_SECONDS := 0.35
## A burst grows to this radius when the spell names none.
const BURST_RADIUS := 1.5
## Hit flags (realm_proto CombatEvent::Hit).
const FLAG_CRIT := 1

## The local player's entity id and hero, and the other players' heroes by
## entity id (main.gd's table).
var own_id := 0
var player: HeroView
var heroes: Dictionary = {}
## Every body's drawn position this frame by entity id, own included (main.gd
## fills it before the events are shown).
var drawn: Dictionary = {}
## Bolts in flight: {node, caster, spell, target, velocity, left}.
var _bolts: Array = []
## Longest a landing bolt takes to reach where it struck.
const LAND_SECONDS := 0.25
## Bursts growing: {node, material, radius, age}.
var _bursts: Array = []
## Per caster: the target its last cast named, and its basic chain step.
var _cast_targets := {}
var _chain := {}
var _looks := {}
var _sphere: SphereMesh
var _glow: QuadMesh
## A radial falloff, white at the centre to clear at the rim: the glow's
## shape, tinted per spell.
var _falloff: GradientTexture2D

static func spell(id: String) -> Dictionary:
	return HudActionBar.spells().get(id, {})

func _init() -> void:
	name = "CombatView"
	_sphere = SphereMesh.new()
	_sphere.radius = 1.0
	_sphere.height = 2.0
	_sphere.radial_segments = 16
	_sphere.rings = 8
	_glow = QuadMesh.new()
	_glow.size = Vector2.ONE * GLOW_SIZE
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	ramp.add_point(0.35, Color(1, 1, 1, 0.45))
	_falloff = GradientTexture2D.new()
	_falloff.gradient = ramp
	_falloff.fill = GradientTexture2D.FILL_RADIAL
	_falloff.fill_from = Vector2(0.5, 0.5)
	_falloff.fill_to = Vector2(1.0, 0.5)
	_falloff.width = 64
	_falloff.height = 64

func show_event(event: Dictionary) -> void:
	match String(event.get("kind", "")):
		"cast_started":
			_cast_started(event)
		"cast_released":
			_launch(event)
		"burst":
			var spell_id := String(event["spell"])
			var at: Vector3 = event["at"]
			if not _land(int(event["caster"]), spell_id, at, 0, func(): _burst(spell_id, at)):
				_burst(spell_id, at)
		"hit":
			if not _land(int(event["attacker"]), String(event["spell"]), Vector3.ZERO, int(event["target"]), func(): _number(event)):
				_number(event)

## The caster's hero plays the spell's clip, its release on the server's
## windup (half the spell's cast lock, in whole ticks).
func _cast_started(event: Dictionary) -> void:
	var caster := int(event["caster"])
	var spell_id := String(event["spell"])
	var target := int(event.get("target", 0))
	_cast_targets[caster] = {"spell": spell_id, "target": target}
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
	var hero: HeroView = player if caster == own_id else heroes.get(caster)
	if hero == null:
		return
	var hz := float(RealmInfo.sim_hz())
	var windup := maxf(1.0, round(float(data.get("cast_lock", 0.28)) * 0.5 * hz)) / hz
	hero.play_cast(spell_id, event.get("aim", hero.position), windup, step)

## A projectile leaves the wand: a small bright sphere in a soft glow of the
## spell's colour that flies at the spell's speed for its range, bending toward
## the cast's creature.
func _launch(event: Dictionary) -> void:
	var spell_id := String(event["spell"])
	var data := spell(spell_id)
	var speed := float(data.get("projectile_speed", 0.0))
	if speed <= 0.0:
		return
	var caster := int(event["caster"])
	var named: Dictionary = _cast_targets.get(caster, {})
	var bolt := Node3D.new()
	var core := MeshInstance3D.new()
	core.mesh = _sphere
	core.scale = Vector3.ONE * BOLT_RADIUS
	core.material_override = _look(spell_id, "core")
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bolt.add_child(core)
	var glow := MeshInstance3D.new()
	glow.mesh = _glow
	glow.material_override = _look(spell_id, "glow")
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bolt.add_child(glow)
	add_child(bolt)
	bolt.global_position = event["from"]
	_bolts.append({"node": bolt, "caster": caster, "spell": spell_id,
		"target": int(named.get("target", 0)) if String(named.get("spell", "")) == spell_id else 0,
		"velocity": (event["dir"] as Vector3).normalized() * speed,
		"left": float(data.get("range", 30.0)) / speed})

## The server says the caster's oldest bolt of that spell landed (on `target`,
## else at `at`). The server resolves a hit within a tick or two of the
## release, before the drawn bolt has crossed the gap, so the bolt finishes
## its flight there and `then` (the number, the burst) plays when it arrives.
## False when no such bolt is in the air (a cone, or one already gone).
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

## An area spell bursts: a soft flash of the spell's colour, fading from the
## centre outward as it grows to the spell's radius (no hard shell).
func _burst(spell_id: String, at: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.mesh = _glow
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Each burst fades on its own, so it gets its own copy of the look.
	var material := _look(spell_id, "burst").duplicate() as StandardMaterial3D
	node.material_override = material
	add_child(node)
	node.global_position = at
	node.scale = Vector3.ONE * 0.3
	_bursts.append({"node": node, "material": material,
		"radius": float(spell(spell_id).get("radius", BURST_RADIUS)), "age": 0.0})

## A damage number over the body that was hit: white, a bigger yellow-orange
## with "!" for a critical hit, red when the local player is the one hit.
func _number(event: Dictionary) -> void:
	var target := int(event["target"])
	if not drawn.has(target):
		return
	var amount := int(event.get("amount", 0))
	var crit := (int(event.get("flags", 0)) & FLAG_CRIT) != 0
	var text := ("%d!" % amount) if crit else str(amount)
	var colour := Color.WHITE
	var size := 1.0
	if target == own_id:
		colour = Color(1.0, 0.2, 0.2)
		size = 1.3
	elif crit:
		colour = Color(1.0, 0.7, 0.2)
		size = 1.5
	FloatingText.spawn(self, (drawn[target] as Vector3) + Vector3(0, NUMBER_HEIGHT, 0), text, colour, size)

## One unshaded material per spell and layer: the bright core, the soft
## additive glow facing the camera, the translucent burst shell.
func _look(spell_id: String, layer: String) -> StandardMaterial3D:
	var key := spell_id + ":" + layer
	if _looks.has(key):
		return _looks[key]
	var colour := Color.html(String(spell(spell_id).get("color", "#ffffff")))
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	match layer:
		"core":
			material.albedo_color = colour.lerp(Color.WHITE, 0.45)
		"glow":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			material.albedo_texture = _falloff
			material.albedo_color = Color(colour, 0.8)
		"burst":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			material.albedo_texture = _falloff
			material.albedo_color = Color(colour, 0.5)
	_looks[key] = material
	return material

func _process(delta: float) -> void:
	for i in range(_bolts.size() - 1, -1, -1):
		var bolt: Dictionary = _bolts[i]
		var node: Node3D = bolt["node"]
		bolt["left"] = float(bolt["left"]) - delta
		if float(bolt["left"]) <= 0.0:
			if bolt.has("then"):
				(bolt["then"] as Callable).call()
			node.queue_free()
			_bolts.remove_at(i)
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
				(bolt["then"] as Callable).call()
				node.queue_free()
				_bolts.remove_at(i)
				continue
			bolt["velocity"] = rest.normalized() * speed
			node.global_position += rest.normalized() * speed * delta
			continue
		var target := int(bolt["target"])
		if target != 0 and drawn.has(target):
			# Homing: it waits on the creature's chest for the hit to arrive.
			var to := (drawn[target] as Vector3) + Vector3(0, CHEST, 0) - node.global_position
			if to.length() <= velocity.length() * delta:
				node.global_position += to
				continue
			velocity = to.normalized() * velocity.length()
			bolt["velocity"] = velocity
		node.global_position += velocity * delta
	for i in range(_bursts.size() - 1, -1, -1):
		var burst: Dictionary = _bursts[i]
		burst["age"] = float(burst["age"]) + delta
		var t := float(burst["age"]) / BURST_SECONDS
		if t >= 1.0:
			(burst["node"] as Node).queue_free()
			_bursts.remove_at(i)
			continue
		# The flash quad is GLOW_SIZE wide; it grows to the spell's diameter.
		var full := float(burst["radius"]) * 2.0 / GLOW_SIZE
		(burst["node"] as Node3D).scale = Vector3.ONE * lerpf(0.3, full, 1.0 - (1.0 - t) * (1.0 - t))
		var material: StandardMaterial3D = burst["material"]
		material.albedo_color.a = 0.5 * (1.0 - t)
