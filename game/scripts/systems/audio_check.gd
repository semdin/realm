extends Node

## `--check-audio`: the sound layers on the grounds, read from AudioManager's
## and WorldAudio's state (what they started, at what level), not by ear.
## build/logs/aup_audio.sh starts the coordinator and the grounds server;
## character 901001 (make_prepared_character.py --travel-kit --level 12)
## stands in the castle courtyard.
##
##   land     the courtyard's zone, its music started and its ambience bed
##   stand    standing still: no footstep
##   walk     walks to the drowned ones' pack south of the courtyard: its
##            steps (and the robe now and then) while walking, the zone
##            changes as it leaves the courtyard
##   fight    fights every creature that comes at it: their alerts, grunts
##            when hit and death cries, the tension rising
##   calm     the fight over: the tension falls back
##   hearth   walks to the Hearth Pavilion, travels to Orvell Square: the
##            hearth's sound; in Orvell the village's music cross-fades in
##            over the track that was playing and its bed comes up
##   broom    mounts, rises and flies: the broom's wind follows the speed
##            (level and pitch hovering against flying); lands and dismounts
##
## `--audio-quick` leaves out the fight and the calm (their layers are then not
## wanted): about a minute, for the zone, the hearth trip and the broom. The
## hearth trip must sound once (its departure; the same-map arrival is
## silent), and the zone must change only where the walk really crosses it.
##
## The verdict line says what was seen, the audio layer's frame cost (the
## microseconds of AudioManager's and WorldAudio's work per frame), and
## quits 0 only when every layer was seen.

const TIMEOUT := 300.0
const PACK_AT := Vector2(33.1, 134.2)
const HOME_HEARTH := "hearth_pavilion"
const ORVELL_HEARTH := "hearth_orvell_square"
const FIGHT_REACH := 26.0
const FIGHT_SECONDS := 100.0
const WANTED := ["music_start", "bed", "steps_stop", "steps_walk", "zone_change", "creature_alert", "creature_hurt",
	"creature_death", "tension_rose", "tension_fell", "hearth_sound", "zone_crossfade", "village_bed",
	"broom_follows_speed"]

var game: Node
var _seen: Dictionary = {}
var _started := 0.0
var _done := false
var _walk := 0.0
var _jump := false
var _descend := false
var _steer := false
var _tension_max := 0.0
var _quick := OS.get_cmdline_user_args().has("--audio-quick")
## The layers the fight and the calm show (not wanted with --audio-quick).
const FIGHT_LAYERS := ["creature_alert", "creature_hurt", "creature_death", "tension_rose", "tension_fell"]

func _ready() -> void:
	_started = _now()
	_run.call_deferred()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func walk_intent() -> float:
	return _walk

func jump_intent() -> bool:
	return _jump

func descend_intent() -> bool:
	return _descend

func on_combat(_event: Dictionary) -> void:
	pass

func _process(_delta: float) -> void:
	if not _done and _now() - _started > TIMEOUT:
		_verdict("timed out")
		return
	_tension_max = maxf(_tension_max, AudioManager.tension)
	if _steer:
		_walk = 0.0
		if WayFinder.has_target() and game.way.finder.path.size() >= 2:
			_follow_route()

func _see(what: String, detail: Variant = true) -> void:
	if not _seen.has(what):
		print("realm check audio: seen %s: %s" % [what, detail])
	_seen[what] = detail

func _until(test: Callable, seconds: float) -> bool:
	var end := _now() + seconds
	while _now() < end:
		if not is_inside_tree() or _done:
			return false
		if test.call():
			return true
		await get_tree().process_frame
	return false

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout

func _me() -> Vector3:
	return game.session.own_position()

func _ready_to_play() -> bool:
	return game.built and game.session.status() == "joined" and not game.session.sheet().is_empty() \
		and not MapLoadingScreen.shared(get_tree()).is_open()

## Steer along the waypoint's route a few metres ahead (as MapCheck does).
func _follow_route() -> void:
	var finder: WayFinder = game.way.finder
	var me := _me()
	var s := finder._project(me).x
	var ahead: Vector3 = finder._at(s + 3.0)[0]
	var flat := Vector2(ahead.x - me.x, ahead.z - me.z)
	if flat.length() > 0.2:
		game.cam_yaw = atan2(-flat.x, -flat.y)
	_walk = 1.0

func _face(x: float, z: float) -> float:
	var me := _me()
	var flat := Vector2(x - me.x, z - me.z)
	if flat.length() > 0.3:
		game.cam_yaw = atan2(-flat.x, -flat.y)
	return flat.length()

## Walk to (x, z) along the way-finder's route, then the last metres straight.
func _walk_to(x: float, z: float, reach: float, seconds: float) -> bool:
	game.way.set_waypoint(String(game.map_name), Vector3(x, _me().y, z), "")
	_steer = true
	var ok: bool = await _until(func(): return Vector2(_me().x - x, _me().z - z).length() < maxf(reach, 6.0) \
		or not WayFinder.has_target(), seconds)
	_steer = false
	game.way.finder.clear()
	if not ok:
		return false
	ok = await _until(func():
		var left := _face(x, z)
		_walk = 1.0 if left > reach else 0.0
		return left <= reach, 12.0)
	_walk = 0.0
	return ok

func _run() -> void:
	if not await _until(_ready_to_play, 60.0):
		_verdict("never joined")
		return
	AudioManager.reset_cost()
	var world: WorldAudio = game.world_audio
	# ---- land: the courtyard's music and bed
	await _until(func(): return AudioManager.zone != "" and AudioManager.current_music_key() != "" \
		and not AudioManager.describe()["beds"].is_empty(), 10.0)
	var mix: Dictionary = AudioManager.describe()
	if AudioManager.current_music_key() != "":
		_see("music_start", "%s in %s" % [AudioManager.current_music_key(), AudioManager.zone])
	if not (mix["beds"] as Dictionary).is_empty():
		_see("bed", "%s in %s" % [mix["beds"], AudioManager.zone])
	# ---- stand: no steps
	await _wait(1.0)
	var steps_before := world.own_steps
	await _wait(3.0)
	if world.own_steps == steps_before:
		_see("steps_stop", "0 steps in 3 s standing")
	else:
		print("realm check audio: %d steps while standing" % (world.own_steps - steps_before))
	# ---- walk to the pack: steps, the zone leaving the courtyard
	var zone_from := AudioManager.zone
	steps_before = world.own_steps
	var played_before := AudioManager.played_count("step_")
	var walked_from := _me()
	await _walk_to(PACK_AT.x, PACK_AT.y, 18.0, 45.0)
	var walked := walked_from.distance_to(_me())
	var steps := world.own_steps - steps_before
	if steps >= 4:
		_see("steps_walk", "%d steps (%d voices, %d robe swishes) over %.0f m, surface %s" % [steps,
			AudioManager.played_count("step_") - played_before, world.robes,
			walked, WorldAudio.ZONE_SURFACES.get(AudioManager.zone, "stone")])
	if AudioManager.zone != zone_from:
		_see("zone_change", "%s -> %s" % [zone_from, AudioManager.zone])
	# ---- fight whatever comes
	if not _quick:
		await _fight_and_calm()
	await _hearth_and_broom()

func _fight_and_calm() -> void:
	var world: WorldAudio = game.world_audio
	await _fight()
	if world.voices["alert"] > 0:
		_see("creature_alert", "%d (%s)" % [world.voices["alert"], _keys_like("_alert")])
	if world.voices["hurt"] > 0:
		_see("creature_hurt", "%d" % world.voices["hurt"])
	if world.voices["death"] > 0:
		_see("creature_death", "%d (%s)" % [world.voices["death"], _keys_like("_death")])
	if _tension_max > 0.8:
		_see("tension_rose", "max %.2f" % _tension_max)
	# ---- calm: the tension falls
	if await _until(func(): return AudioManager.tension < 0.05 and not AudioManager.combat_music_active(), 40.0):
		_see("tension_fell", "%.2f, music %s" % [AudioManager.tension, AudioManager.get_music_state()])

func _hearth_and_broom() -> void:
	# ---- the hearth: its sound, then Orvell's music and bed
	var travel: MapTravel = game.travel
	var mouth := travel.nodes.mouth(HOME_HEARTH) + TravelData.facing(TravelData.node(HOME_HEARTH)) * 1.2
	await _walk_to(mouth.x, mouth.z, 1.2, 60.0)
	await _until(func(): return travel.active_node == HOME_HEARTH, 5.0)
	# a track sounding, so the trip's zone change has one to cross-fade from
	await _until(func(): return AudioManager.current_music_key() != "", 25.0)
	var track_before := AudioManager.current_music_key()
	var fades_before := AudioManager.crossfades.size()
	var whoosh_before := AudioManager.played_count("hearth_whoosh")
	travel.interact()
	if await _until(func(): return travel.hearthway.visible, 5.0):
		await _wait(0.5)
		var go: Button = travel.hearthway.travel_buttons.get(ORVELL_HEARTH)
		if go != null and not go.disabled:
			go.pressed.emit()
	var square: Array = TravelData.node(ORVELL_HEARTH).get("pos", [0, 0, 0])
	await _until(func(): return Vector2(_me().x - float(square[0]), _me().z - float(square[2])).length() < 14.0, 15.0)
	await _wait(1.5)   # the arrival's flames are up by now
	var whooshes := AudioManager.played_count("hearth_whoosh") - whoosh_before
	if whooshes == 1:
		_see("hearth_sound", "hearth_whoosh x1")
	else:
		print("realm check audio: the hearth trip sounded %d times (wanted once)" % whooshes)
	await _until(func(): return AudioManager.zone == "village", 6.0)
	await _wait(1.0)
	for fade: Dictionary in AudioManager.crossfades.slice(fades_before):
		if String(fade["reason"]) == "zone":
			_see("zone_crossfade", "%s -> %s (%s -> village), %d music voices" % [fade["from"], fade["to"],
				track_before, AudioManager.music_voices()])
	if (AudioManager.describe()["beds"] as Dictionary).has("amb_village"):
		_see("village_bed", AudioManager.describe()["beds"])
	# ---- the broom: its wind follows speed
	await _broom()
	_verdict("")

## Fight every creature that comes: the nearest live one in reach, basic casts.
func _fight() -> void:
	var end := _now() + FIGHT_SECONDS
	var calm_since := _now()
	while _now() < end and not _done:
		await get_tree().create_timer(0.3).timeout
		if game.feedback.is_dead():
			print("realm check audio: fell in the fight")
			return
		var near: Array = game._creatures_near(FIGHT_REACH)
		near = near.filter(func(id): return game.beasts.get(id) is CreatureView)
		if near.is_empty():
			if game.world_audio.voices["death"] > 0 and _now() - calm_since > 3.0:
				_walk = 0.0
				return
			# none in reach yet: step toward the pack
			_walk = 1.0 if _face(PACK_AT.x, PACK_AT.y) > 4.0 else 0.0
			continue
		_walk = 0.0
		calm_since = _now()
		if game.target == 0 or not near.has(game.target):
			game.select_target(near[0])
		var at: Vector3 = (game.beasts[game.target] as Node3D).position
		_face(at.x, at.z)
		game.cast_spell("basic_cast")

func _broom() -> void:
	var travel: MapTravel = game.travel
	if not await _until(func():
		if not game.player.is_mounted and Engine.get_process_frames() % 60 == 0:
			travel.toggle_ride()
		return game.player.is_mounted, 12.0):
		print("realm check audio: never mounted")
		return
	# hover up: barely any ground speed
	_jump = true
	await _wait(1.6)
	_jump = false
	await _wait(0.6)
	var slow := AudioManager.layer_state("broom_wind")
	var slow_ratio: float = game.world_audio.broom_ratio
	# fly west over the fields
	game.cam_yaw = atan2(1.0, 0.0)
	_walk = 1.0
	await _wait(3.5)
	var fast := AudioManager.layer_state("broom_wind")
	var fast_ratio: float = game.world_audio.broom_ratio
	_walk = 0.0
	if not slow.is_empty() and not fast.is_empty() and float(fast["target_pitch"]) > float(slow["target_pitch"]) + 0.1 \
			and float(fast["target_db"]) > float(slow["target_db"]) + 1.0:
		_see("broom_follows_speed", "speed %.2f -> %.2f: %.1f -> %.1f dB, pitch %.2f -> %.2f" % [slow_ratio, fast_ratio,
			float(slow["target_db"]), float(fast["target_db"]), float(slow["target_pitch"]), float(fast["target_pitch"])])
	else:
		print("realm check audio: broom wind slow %s fast %s" % [slow, fast])
	# down and off
	var tries := 0
	while game.player.is_mounted and tries < 4 and not _done:
		tries += 1
		_descend = true
		await _until(func(): return bool(game.session.own_body().get("on_floor", false)), 8.0)
		_descend = false
		travel.toggle_ride()
		await _until(func(): return not game.player.is_mounted, 3.0)

func _keys_like(suffix: String) -> String:
	var keys: Array = []
	for key: String in AudioManager.played_counts:
		if key.ends_with(suffix) and not keys.has(key):
			keys.append(key)
	return ", ".join(keys)

func _verdict(failure: String) -> void:
	if _done:
		return
	_done = true
	_walk = 0.0
	_jump = false
	_descend = false
	var missing := WANTED.filter(func(k): return not _seen.has(k) and not (_quick and FIGHT_LAYERS.has(k)))
	var cost := AudioManager.cost_summary()
	var world: WorldAudio = game.world_audio
	print("realm check audio: %s | seen {%s} | missing [%s]" % [
			"ok" if failure == "" and missing.is_empty() else (failure if failure != "" else "missing layers"),
			", ".join(_seen.keys().map(func(k): return "%s: %s" % [k, _seen[k]])), ", ".join(missing)],
		" | voices %s, steps own %d other %d, zones [%s], crossfades [%s], stingers [%s]" % [world.voices,
			world.own_steps, world.other_steps,
			", ".join(world.zone_changes.map(func(z): return "%s->%s at (%d, %d) %.1f s" % [z["from"], z["to"],
				roundi((z["pos"] as Vector3).x), roundi((z["pos"] as Vector3).z), float(z["at"])])),
			", ".join(AudioManager.crossfades.map(func(f): return "%s->%s (%s)" % [f["from"], f["to"], f["reason"]])),
			", ".join(AudioManager.stingers_played)],
		" | audio layer %d frames: mean %.1f us, p99 %d us, max %d us; %d frames read a file (longest %d us) | %d fps | mix %s" % [
			int(cost["frames"]), float(cost["mean_us"]), int(cost["p99_us"]), int(cost["max_us"]),
			int(cost["load_frames"]), int(cost["load_max_us"]), Engine.get_frames_per_second(), AudioManager.describe()])
	get_tree().quit(0 if failure == "" and missing.is_empty() else 1)
