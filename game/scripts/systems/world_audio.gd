extends Node
class_name WorldAudio

## The world scene's ear: it watches what main.gd draws and tells AudioManager
## what the listener hears - the zone it stands in, its height over the
## ground, its broom, its health, the fights on it - and voices the bodies
## round it. It decides nothing about the game.
##
##   * Zone: the map first (the castle by its rooms and the dungeons below,
##     the caverns and the dungeons as their own), on the grounds the
##     courtyard, the lake, the hunting region's kind of land (village, wood,
##     dark wood, moor, marsh, shore) or the open valley. A new zone must hold
##     for two scans (a second) so a region edge does not flip the soundtrack;
##     high above the grounds the zone holds (the high wind owns the sky).
##   * Footsteps: every hero's rig reports its foot contacts (HeroAnimation
##     `footstep:`); each plays a soft step on the zone's ground, now and then
##     with the robe's swish. Another player's steps are quieter and only
##     within STEP_REACH; a crowd holds at most AudioManager's step voices.
##   * Creatures (CreatureView): an alert as one turns on the player, its
##     attack as it strikes, a grunt when it is hit, its death cry, a breath
##     now and then while it chases or idles nearby - by species family, only
##     within VOICE_REACH, the voices capped.
##   * Fights: a blow on or by the player, the player's cast at a creature, a
##     creature striking close by raise the combat mix (a boss's, the boss
##     music and its stinger; its fall, the victory stinger); a boss's
##     telegraphed slam charges and lands with its own cues.
##   * The broom's wind follows the rider's speed; mounting and dismounting
##     (the player's or another's nearby) have their cues.
##   * The music steps back under a dialogue and the game menu.

## How often the zone, the height, health and the heroes' hooks are read.
const SCAN := 0.5
## How often the creatures are looked at (their state changes, their voices).
const VOICE_SCAN := 0.1
const STEP_REACH := 28.0
const VOICE_REACH := 40.0
const IDLE_VOICE_REACH := 22.0
## A moving creature this close and closing has turned on the player.
const AGGRO_REACH := 18.0
## A creature striking this close is on the player (the fight is on).
const ON_PLAYER := 8.0
## A pallid this close chills the mix.
const DESPAIR_REACH := 14.0
const MOUNT_REACH := 30.0
## Own and other players' step loudness (of the library's already quiet gain).
const OWN_STEP := 0.85
const OTHER_STEP := 0.6
## Every this many steps (a random pick) the robe swishes.
const ROBE_EVERY := [3, 5]
## Above this height over the ground the grounds' zone holds.
const SKY_HOLD := 25.0
## A zone's edge is this wide (metres): the zone the listener is in holds
## while it lies within this of the listener, so walking along a boundary (the
## courtyard's rim, a region's edge) does not flap the music and the banner.
const ZONE_EDGE := 4.0

## Hunting region (spawn_tables.json) -> grounds zone. Unlisted: open valley.
const REGION_ZONES := {
	"village": "village", "orvell_road": "village",
	"forest_sw": "forest", "forest_w": "forest", "forest_e": "forest", "pitch_woods": "forest", "lakeside_glade": "forest",
	"greenhouse_meadow": "grounds", "pitch_outskirts": "grounds", "eastern_road": "grounds",
	"forest_deep": "forest_dark", "dark_thicket": "forest_dark", "spider_woods": "forest_dark", "crypt_gate": "forest_dark",
	"boss_w": "forest_dark", "boss_e": "forest_dark", "troll_hollow": "forest_dark",
	"highland_moor": "moor", "western_moor": "moor", "eastern_moor": "moor", "ridge_path": "moor", "stone_summit": "moor",
	"orvell_heights": "moor", "southern_barrows": "moor", "fog_barrens": "moor",
	"grey_marsh": "marsh", "warden_barrow": "marsh",
	"misty_shore": "shore", "station_mist": "shore",
}
## Grounds place names (MapPlaces) that set the zone where no region does.
const PLACE_ZONES := {
	"Castle Courtyard": "courtyard", "Lake Lunra": "lake", "Boathouse": "lake", "Orvell": "village",
	"Orvell Landing": "shore", "Raven Woods": "forest", "Northern Moors": "moor",
}
## The ground a step lands on, by zone.
const ZONE_SURFACES := {
	"grounds": "grass", "courtyard": "stone", "village": "stone", "forest": "dirt", "forest_dark": "dirt",
	"moor": "grass", "marsh": "dirt", "shore": "dirt", "lake": "dirt", "feast_hall": "stone", "library": "wood",
	"interior": "stone", "dungeon": "stone", "corridor": "stone",
}
## Creature species -> its voice family (assets/audio/monsters).
const VOICES := {
	"black_weaver": "spider", "broodguard": "spider", "venomfang_weaver": "spider",
	"armour_commander": "armour", "armour_guard": "armour", "fidgetling": "pixie", "dark_bandit": "bandit",
	"pallid": "armour", "strangling_vine": "snare", "wheelwarden": "armour",
	"goblin_guard": "goblin", "goblin_hexer": "goblin", "goblin_teller": "goblin",
	"drowned_one": "drowned_one", "drowned_warden": "drowned_one", "troll_forest": "troll", "troll_mountain": "troll",
}
## A family's own key for a cue where it differs from `<family>_<cue>`.
const VOICE_KEYS := {"spider": {"attack": "spider_bite"}}

var game: Node

## What the check reads.
var own_steps := 0
var other_steps := 0
var robes := 0
var voices := {"alert": 0, "attack": 0, "hurt": 0, "death": 0, "move": 0, "idle": 0}
var voice_log: Array[String] = []
var zone_changes: Array = []
var mounts := 0
## Seconds from the dismount to the landing's footfall.
const LANDING_DELAY := 0.3
var broom_ratio := 0.0

var _scan_left := 0.0
var _voice_left := 0.0
var _zone_candidate := ""
var _zone_count := 0
var _map := ""
var _was_mounted := false
var _flight_time := 0.0
var _on_floor := true
var _creatures := {}       # entity -> {state, attacks, dead, dist, engaged_until, next_move, next_idle, hurt_at, alerted_at}
var _boss_id := 0
var _slams := {}           # caster -> {at (seconds), where}
var _hooked := {}          # hero instance id -> true

func _init() -> void:
	name = "WorldAudio"

func _ready() -> void:
	AudioManager.attach_world(self)

func _exit_tree() -> void:
	AudioManager.detach_world(self)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_tick(delta)
	AudioManager.add_cost(Time.get_ticks_usec() - started)

func _tick(delta: float) -> void:
	if game == null or game.session == null or not game.built or not is_instance_valid(game.player):
		return
	var hero: HeroView = game.player
	var me: Vector3 = hero.position
	AudioManager.listener = me
	if hero.is_mounted != _was_mounted:
		_was_mounted = hero.is_mounted
		mounts += 1
		AudioManager.play_mount(hero.is_mounted, me)
		# the rider's own broom: a rush of air as it lifts off, the feet
		# touching down a moment after the dismount
		if hero.is_mounted:
			AudioManager.play_sound_at("broom_swoosh_%d" % (randi() % 2 + 1), me)
		else:
			get_tree().create_timer(LANDING_DELAY).timeout.connect(func():
				if is_instance_valid(hero):
					AudioManager.play_sound_at("landing", hero.position))
	AudioManager.mounted = hero.is_mounted
	if hero.is_mounted:
		# the broom's wind: louder, higher and with more bite the faster it goes
		var speed := Vector2(hero.velocity.x, hero.velocity.z).length()
		broom_ratio = clampf(speed / maxf(1.0, hero.mounted_speed), 0.0, 1.0)
		AudioManager.set_layer("broom_wind", lerpf(0.35, 1.0, broom_ratio), lerpf(0.85, 1.2, broom_ratio), 4.0)
		var high := AudioManager.altitude > AudioManager.FLIGHT_MUSIC_HEIGHT
		_flight_time = _flight_time + delta if high else maxf(0.0, _flight_time - delta * 2.0)
	else:
		broom_ratio = 0.0
		_flight_time = 0.0
		AudioManager.set_layer("broom_wind", 0.0)
	AudioManager.flight_time = _flight_time
	_play_slams()
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = SCAN
		_scan(me)
	_voice_left -= delta
	if _voice_left <= 0.0:
		_voice_left = VOICE_SCAN
		_scan_creatures(me)

# ------------------------------------------------------------------ the scan

func _scan(me: Vector3) -> void:
	var own: Dictionary = game.session.own_body()
	_on_floor = bool(own.get("on_floor", true))
	_measure_altitude(me)
	_detect_zone(me)
	# the live health (the snapshot's) over the sheet's maximum
	var hp := int(game.session.stats().get("hp", 0))
	if game.sheet_view != null and game.sheet_view.max_hp > 1 and hp > 0:
		AudioManager.hp_fraction = clampf(float(hp) / float(game.sheet_view.max_hp), 0.0, 1.0)
	AudioManager.dead = game.feedback != null and game.feedback.is_dead()
	AudioManager.raining = game.weather != null and game.weather.outdoors and game.weather.rain_amount > 0.5
	AudioManager.set_dim("dialogue", game.dialogue != null and game.dialogue.visible)
	AudioManager.set_dim("menu", game.game_menu != null and game.game_menu.visible)
	var chilled := false
	for id: int in game.beasts:
		var body: Node = game.beasts[id]
		if body is CreatureView and (body as CreatureView).species == "pallid" and not (body as CreatureView).is_dead \
				and (body as Node3D).position.distance_to(me) < DESPAIR_REACH:
			chilled = true
			break
	AudioManager.despair = chilled
	_hook(game.player)
	for id: int in game.heroes:
		var other: HeroView = game.heroes[id]
		_hook(other)
		if other.has_meta("audio_mounted") and bool(other.get_meta("audio_mounted")) != other.is_mounted 				and other.position.distance_to(me) < MOUNT_REACH:
			AudioManager.play_mount(other.is_mounted, other.position)
		other.set_meta("audio_mounted", other.is_mounted)

## Height over the ground under the listener (0 indoors, standing or unknown).
func _measure_altitude(me: Vector3) -> void:
	if AudioManager.is_indoors() or (_on_floor and not game.player.is_mounted):
		AudioManager.altitude = 0.0
		return
	var hit: Dictionary = game.session.pick(me + Vector3.UP * 0.5, Vector3.DOWN, 150.0)
	var point: Variant = hit.get("point")
	AudioManager.altitude = maxf(0.0, me.y - (point as Vector3).y) if point is Vector3 else 150.0

## The zone the listener is in (see the class notes).
func zone_at(map_id: String, pos: Vector3) -> String:
	if map_id == "castle_interior":
		if MapPlaces.castle_level(pos.y) < 0:
			return "dungeon"
		match MapPlaces.place_at(map_id, pos):
			"Long Table":
				return "feast_hall"
			"Hall of Rolls":
				return "library"
		return "interior"
	if map_id == "dng_sealed_wing":
		return "corridor"
	if map_id.begins_with("dng_") or map_id == "spider_caverns":
		return "dungeon"
	var place := MapPlaces.place_at(map_id, pos)
	if place == "Castle Courtyard" or place == "Lake Lunra" or place == "Boathouse":
		return String(PLACE_ZONES[place])
	var region := MapPlaces.hunting_region(map_id, pos)
	var by_region := String(REGION_ZONES.get(String(region.get("id", "")), ""))
	if by_region != "":
		return by_region
	return String(PLACE_ZONES.get(place, "grounds"))

func _detect_zone(me: Vector3) -> void:
	var map_id := String(game.map_name)
	var offset: Vector3 = game.session.copy_offset()
	var wanted := zone_at(map_id, me - offset)
	var first := AudioManager.zone == ""
	var map_changed := map_id != _map
	_map = map_id
	if not map_changed and not AudioManager.is_indoors() and AudioManager.altitude > SKY_HOLD:
		wanted = AudioManager.zone
	if not first and not map_changed and wanted != AudioManager.zone and _zone_within_edge(map_id, me - offset):
		wanted = AudioManager.zone
	if wanted == AudioManager.zone:
		_zone_candidate = ""
		return
	if wanted != _zone_candidate:
		_zone_candidate = wanted
		_zone_count = 0
	_zone_count += 1
	# A new map (a door, a trip) switches at once; region edges wait a scan.
	if first or map_changed or _zone_count >= 2:
		_zone_candidate = ""
		zone_changes.append({"from": AudioManager.zone, "to": wanted, "at": _now(), "pos": me - offset})
		AudioManager.set_zone(wanted, first)

## Whether the current zone lies within ZONE_EDGE of `pos` (four points round
## it), so it holds.
func _zone_within_edge(map_id: String, pos: Vector3) -> bool:
	for d: Vector3 in [Vector3(ZONE_EDGE, 0, 0), Vector3(-ZONE_EDGE, 0, 0), Vector3(0, 0, ZONE_EDGE), Vector3(0, 0, -ZONE_EDGE)]:
		if zone_at(map_id, pos + d) == AudioManager.zone:
			return true
	return false

# ------------------------------------------------------------------ steps

## Listen to a hero's rig for its foot contacts (once per hero).
func _hook(hero: HeroView) -> void:
	if not is_instance_valid(hero) or hero.anim == null or _hooked.has(hero.get_instance_id()):
		return
	var key := hero.get_instance_id()
	_hooked[key] = true
	hero.anim.event_fired.connect(_on_rig_event.bind(hero))
	hero.tree_exiting.connect(func() -> void: _hooked.erase(key))

func _on_rig_event(event_name: String, hero: HeroView) -> void:
	if not event_name.begins_with("footstep:") or not is_instance_valid(hero):
		return
	var started := Time.get_ticks_usec()
	var own: bool = hero == game.player
	var at := hero.position
	if own or at.distance_to(AudioManager.listener) <= STEP_REACH:
		if own:
			own_steps += 1
		else:
			other_steps += 1
		var surface := String(ZONE_SURFACES.get(AudioManager.zone, "stone"))
		if own and bool(game.session.own_body().get("swimming", false)):
			surface = "water"
		var scale := OWN_STEP if own else OTHER_STEP
		AudioManager.play_step(surface, at, scale)
		var left := int(hero.get_meta("audio_robe", randi_range(ROBE_EVERY[0], ROBE_EVERY[1]))) - 1
		if left <= 0:
			left = randi_range(ROBE_EVERY[0], ROBE_EVERY[1])
			robes += 1
			AudioManager.play_robe(at + Vector3.UP * 0.9, scale)
		hero.set_meta("audio_robe", left)
	AudioManager.add_cost(Time.get_ticks_usec() - started)

# ------------------------------------------------------------------ creatures

func _voice_key(family: String, cue: String) -> String:
	var own: Dictionary = VOICE_KEYS.get(family, {})
	if own.has(cue):
		return String(own[cue])
	if cue == "move":
		return "%s_move_%d" % [family, randi() % 3 + 1]
	return "%s_%s" % [family, cue]

func _voice(body: CreatureView, cue: String, kind: String, gain_db := 0.0) -> void:
	var family := String(VOICES.get(body.species, ""))
	if family == "":
		return
	var key := _voice_key(family, cue)
	if body.is_boss and cue == "alert":
		key = "boss_alert"
	elif body.is_boss and cue == "death":
		key = "boss_death"
	# a death and a boss's cues are never dropped for the cap
	var capped := "" if cue == "death" or body.is_boss else "voice"
	var player := AudioManager.play_sound_at(key, body.position + Vector3.UP * 1.0, body, false, capped)
	if player == null:
		return
	if gain_db != 0.0:
		player.set("volume_db", float(player.get("volume_db")) + gain_db)
	voices[kind] = int(voices[kind]) + 1
	voice_log.append(key)
	if voice_log.size() > 64:
		voice_log.remove_at(0)

func _scan_creatures(me: Vector3) -> void:
	var now := _now()
	for id: int in _creatures.keys():
		if not game.beasts.has(id):
			_creatures.erase(id)
	for id: int in game.beasts:
		var body := game.beasts[id] as CreatureView
		if body == null or body.state < 0:
			continue
		var dist := body.position.distance_to(me)
		var e: Dictionary = _creatures.get(id, {})
		if e.is_empty():
			# first seen: no cue for what it was already doing
			_creatures[id] = {"attacks": body.attack_starts, "dead": body.is_dead, "dist": dist, "engaged_until": 0.0,
				"next_move": 0.0, "next_idle": now + randf_range(4.0, 16.0), "hurt_at": -10.0, "alerted_at": -100.0}
			continue
		var near := dist <= VOICE_REACH
		if body.is_dead:
			if not bool(e["dead"]):
				if near:
					_voice(body, "death", "death")
				if id == _boss_id:
					_boss_id = 0
					AudioManager.boss_fell()
			e["dead"] = true
			continue
		e["dead"] = false
		var attacked: bool = body.attack_starts != int(e["attacks"])
		e["attacks"] = body.attack_starts
		var closing: bool = body.state == CreatureView.STATE_MOVING and dist < AGGRO_REACH and dist < float(e["dist"]) - 0.2
		e["dist"] = dist
		if (attacked or body.state == CreatureView.STATE_ATTACKING) and dist < ON_PLAYER:
			_on_player(id, body)
		if not near:
			continue
		var engaged := now < float(e["engaged_until"])
		if (attacked or closing) and not engaged and now - float(e["alerted_at"]) > 10.0:
			e["alerted_at"] = now
			_voice(body, "alert", "alert")
		if attacked or closing:
			e["engaged_until"] = now + 6.0
			engaged = true
		if attacked:
			_voice(body, "attack", "attack")
		elif engaged and body.state == CreatureView.STATE_MOVING and now >= float(e["next_move"]):
			e["next_move"] = now + randf_range(0.9, 1.8)
			_voice(body, "move", "move", -2.0)
		elif not engaged and body.state == CreatureView.STATE_IDLE and dist < IDLE_VOICE_REACH and now >= float(e["next_idle"]):
			e["next_idle"] = now + randf_range(10.0, 24.0)
			_voice(body, "move", "idle", -6.0)

## A creature is on the player: the fight is on (a boss's music for a boss).
func _on_player(id: int, body: Node) -> void:
	if bool(body.get("is_boss")):
		_boss_id = id
		AudioManager.notify_boss()
	else:
		AudioManager.notify_combat()

## A creature that was hit: a grunt (at most every 0.8 s), and it is in the
## fight now (its alert if it was not yet).
func _creature_hurt(id: int) -> void:
	var body := game.beasts.get(id) as CreatureView
	var e: Dictionary = _creatures.get(id, {})
	if body == null or e.is_empty() or body.is_dead or body.position.distance_to(AudioManager.listener) > VOICE_REACH:
		return
	var now := _now()
	if now >= float(e["engaged_until"]) and now - float(e["alerted_at"]) > 10.0:
		e["alerted_at"] = now
		e["engaged_until"] = now + 6.0
		e["hurt_at"] = now
		_voice(body, "alert", "alert")
		return
	e["engaged_until"] = now + 6.0
	if now - float(e["hurt_at"]) < 0.8:
		return
	e["hurt_at"] = now
	_voice(body, "move", "hurt", 2.0)

# ------------------------------------------------------------------ events

## Every combat event main.gd shows.
func on_combat(event: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	var own := int(game.session.own_entity())
	match String(event.get("kind", "")):
		"hit":
			var attacker := int(event["attacker"])
			var target := int(event["target"])
			if game.beasts.has(target):
				_creature_hurt(target)
			if attacker == own or target == own:
				var other: int = target if attacker == own else attacker
				var body: Node = game.beasts.get(other)
				if body != null and bool(body.get("is_boss")):
					_boss_id = other
					AudioManager.notify_boss()
				else:
					AudioManager.notify_combat()
		"cast_started":
			if int(event["caster"]) == own and game.beasts.has(int(event.get("target", 0))):
				AudioManager.notify_combat()
		"telegraph":
			var caster := int(event["caster"])
			var body: Node = game.beasts.get(caster)
			if body != null and bool(body.get("is_boss")):
				var center: Vector3 = event["center"]
				AudioManager.play_sound_at("boss_slam_cast", center)
				var hz := float(RealmInfo.sim_hz())
				var lead := (float(event["release_tick"]) - float(game.session.server_tick())) / hz
				_slams[caster] = {"at": _now() + maxf(0.0, lead), "where": center}
		"telegraph_cancelled":
			_slams.erase(int(event["caster"]))
	AudioManager.add_cost(Time.get_ticks_usec() - started)

func _play_slams() -> void:
	if _slams.is_empty():
		return
	var now := _now()
	for caster: int in _slams.keys():
		var slam: Dictionary = _slams[caster]
		if now >= float(slam["at"]):
			_slams.erase(caster)
			AudioManager.play_sound_at("boss_slam_release", slam["where"])
