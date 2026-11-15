extends Node

## AudioManager (autoload): the sound library, the buses, the effect voices and
## the dynamic mix the old game had - zone ambience, the music director, the
## combat tension mix, stingers and the flight layers.
##
## Every sound is described by `assets/audio/sound_library.json` (bus, base
## gain, pitch variation, loop mode, positional or flat, alternate takes).
## Master / Music / SFX / UI / Ambience carry independent, persisted volumes
## (the settings window).
##
##   * Voices: positional cues play on a pooled AudioStreamPlayer3D with a
##     voice limit (combat warnings keep their voices), flat cues on a pooled
##     AudioStreamPlayer. A kind of sound (`category`: a crowd's footsteps, the
##     creatures' voices, the ambient scatter) holds at most CATEGORY_CAPS of
##     them, and a positional cue beyond its hearing distance from the camera
##     is never started.
##   * Zones (ZONES): each place has its ambient beds, a scatter of one-shots
##     round the listener, its reverb and its music pool. WorldAudio (the
##     world scene's ear) says which zone the listener is in; beds cross-fade.
##   * The music director: an exploration track plays once and gives way to a
##     breath of silence before the next (the soundtrack breathes); a new zone
##     whose pool does not hold the track cross-fades to one of its own;
##     flight gets its soaring theme; combat and bosses take over with looping
##     battle music and, after a fight, the world is quiet for a moment before
##     exploration music returns. The front door pins the menu theme.
##   * Tension: `tension` rises toward 1 while a fight is on and falls after
##     it; it ducks the ambience under the fight. Low health brings a heartbeat
##     and muffles music and ambience, death muffles them further; a pallid
##     close by adds its icy bed.
##   * Stingers (boss, victory, death) and the level-up cue duck the music
##     while they sound; dialogue and the game menu dim it.
##   * Flight: the broom's wind bed follows speed (level and pitch); the high
##     wind rises with altitude and takes over from the ground beds.
##
## The state (zone, beds, music, tension, layers, what played) is kept the same
## with or without an audio device; only starting a stream needs one.

const LIBRARY_PATH := "res://assets/audio/sound_library.json"
const SETTINGS_PATH := "user://audio_settings.json"
const BUSES := ["Music", "SFX", "UI", "Ambience"]
const BUS_NAMES := {"sfx": "SFX", "ui": "UI", "ambience": "Ambience", "music": "Music"}
## Bumped when the sound set is replaced: volumes saved against an older set
## go back to the defaults once.
const SETTINGS_VERSION := 2

## Keys that must stay audible under heavy spell combinations: a full voice
## pool never steals them.
const WARNING_PRIORITY := [
	"boss_slam_cast", "boss_slam_release", "boss_death",
	"spell_flame_wave_impact", "spell_shockwave_impact", "spell_ultimate_impact",
	"ui_hit", "spell_ward_shield_impact",
]

const MAX_SPATIAL_VOICES := 24
const MAX_FLAT_VOICES := 22
## Two listeners of one event must not stack the same flat cue on itself.
const FLAT_REPEAT_MSEC := 80
## Voices one kind of sound may hold at once: a crowd's footsteps, the
## creatures' voices, the ambient scatter.
const CATEGORY_CAPS := {"step": 6, "voice": 8, "scatter": 3}
## A positional one-shot farther than this from the listener is not started.
const HEARING := 45.0

## One-shot scatter sets, shared between zones: keys, the gap between plays
## (seconds), and where it sounds (a ring round the listener, or flat).
## `ground`: silent high above the ground; `dry`: silent in the rain.
const SCATTER := {
	"birds": {"keys": ["amb_bird_1", "amb_bird_2", "amb_bird_3", "amb_bird_4"], "gap": [7.0, 18.0], "spatial": true, "dist": [14.0, 32.0], "height": 6.0, "ground": true, "dry": true},
	"gusts": {"keys": ["amb_wind_gust_1", "amb_wind_gust_2"], "gap": [16.0, 34.0], "spatial": false},
	"leaves": {"keys": ["amb_leaf_rustle_1", "amb_leaf_rustle_2"], "gap": [10.0, 22.0], "spatial": true, "dist": [6.0, 16.0], "height": 2.5, "ground": true},
	"trees": {"keys": ["amb_tree_creak_1", "amb_tree_creak_2"], "gap": [12.0, 26.0], "spatial": true, "dist": [8.0, 22.0], "height": 5.0, "ground": true},
	"snap": {"keys": ["amb_branch_snap"], "gap": [28.0, 60.0], "spatial": true, "dist": [8.0, 16.0], "height": 0.5, "ground": true},
	"owls": {"keys": ["amb_owl_1", "amb_owl_2"], "gap": [18.0, 40.0], "spatial": true, "dist": [18.0, 34.0], "height": 7.0, "ground": true},
	"howl": {"keys": ["amb_wolf_howl"], "gap": [45.0, 90.0], "spatial": false},
	"crows": {"keys": ["amb_crow_1", "amb_crow_2"], "gap": [14.0, 32.0], "spatial": true, "dist": [16.0, 36.0], "height": 8.0, "ground": true, "dry": true},
	"frogs": {"keys": ["amb_frog_1", "amb_frog_2", "amb_bubble"], "gap": [6.0, 15.0], "spatial": true, "dist": [5.0, 15.0], "height": 0.3, "ground": true},
	"waves": {"keys": ["amb_wave"], "gap": [7.0, 14.0], "spatial": true, "dist": [8.0, 18.0], "height": 0.2, "ground": true},
	"castle": {"keys": ["amb_castle_door_far", "amb_castle_steps_far", "amb_portrait_whisper"], "gap": [14.0, 30.0], "spatial": true, "dist": [8.0, 22.0], "height": 2.0},
	"magic": {"keys": ["amb_magic_chime", "amb_ghost_laugh", "amb_owl_flutter"], "gap": [24.0, 50.0], "spatial": true, "dist": [6.0, 18.0], "height": 4.0},
	"hall": {"keys": ["amb_hall_laughter", "amb_owl_flutter", "amb_magic_chime"], "gap": [18.0, 38.0], "spatial": true, "dist": [8.0, 24.0], "height": 4.0},
	"library": {"keys": ["amb_library_page_1", "amb_library_page_2", "amb_quill"], "gap": [9.0, 20.0], "spatial": true, "dist": [3.0, 9.0], "height": 1.2},
	"drips": {"keys": ["amb_dungeon_drip_1", "amb_dungeon_drip_2", "amb_dungeon_drip_3"], "gap": [5.0, 12.0], "spatial": true, "dist": [4.0, 14.0], "height": 2.5},
	"deep": {"keys": ["amb_dungeon_rumble", "amb_dungeon_chains", "amb_dungeon_growl", "amb_dungeon_whisper_1", "amb_dungeon_whisper_2"], "gap": [16.0, 34.0], "spatial": true, "dist": [6.0, 18.0], "height": 2.0},
}

## Zone identities: ambient beds, scatter sets, reverb, and the music pool with
## the silence between its tracks. `indoor`: under a roof (no high wind, no
## flight theme).
const ZONES := {
	"grounds": {"beds": ["amb_grounds"], "scatter": ["birds", "gusts", "leaves"], "room_size": 0.2, "damping": 0.8, "wet": 0.05, "dry": 1.0,
		"music": ["music_grounds_a", "music_grounds_b"], "gap": [35.0, 80.0]},
	"courtyard": {"beds": ["amb_courtyard"], "scatter": ["birds", "gusts"], "room_size": 0.45, "damping": 0.6, "wet": 0.12, "dry": 1.0,
		"music": ["music_grounds_b", "music_grounds_a"], "gap": [30.0, 70.0]},
	"village": {"beds": ["amb_village"], "scatter": ["birds", "gusts"], "room_size": 0.3, "damping": 0.7, "wet": 0.08, "dry": 1.0,
		"music": ["music_village"], "gap": [25.0, 60.0]},
	"forest": {"beds": ["amb_forest"], "scatter": ["birds", "trees", "leaves", "snap"], "room_size": 0.35, "damping": 0.7, "wet": 0.1, "dry": 1.0,
		"music": ["music_forest", "music_grounds_a"], "gap": [30.0, 70.0]},
	"forest_dark": {"beds": ["amb_forest_dark"], "scatter": ["owls", "trees", "snap", "howl"], "room_size": 0.4, "damping": 0.6, "wet": 0.12, "dry": 1.0,
		"music": ["music_wilds", "music_forest"], "gap": [20.0, 50.0]},
	"moor": {"beds": ["amb_moor"], "scatter": ["crows", "gusts", "howl"], "room_size": 0.25, "damping": 0.8, "wet": 0.06, "dry": 1.0,
		"music": ["music_wilds"], "gap": [25.0, 60.0]},
	"marsh": {"beds": ["amb_marsh"], "scatter": ["frogs", "crows"], "room_size": 0.3, "damping": 0.7, "wet": 0.08, "dry": 1.0,
		"music": ["music_wilds"], "gap": [25.0, 60.0]},
	"shore": {"beds": ["amb_shore"], "scatter": ["waves", "gusts", "crows"], "room_size": 0.3, "damping": 0.7, "wet": 0.08, "dry": 1.0,
		"music": ["music_wilds", "music_grounds_b"], "gap": [30.0, 70.0]},
	"lake": {"beds": ["amb_shore"], "scatter": ["waves", "birds", "gusts"], "room_size": 0.25, "damping": 0.75, "wet": 0.06, "dry": 1.0,
		"music": ["music_grounds_a", "music_grounds_b"], "gap": [35.0, 80.0]},
	"feast_hall": {"beds": ["amb_feast_hall", "amb_fire"], "scatter": ["hall"], "room_size": 0.92, "damping": 0.35, "wet": 0.4, "dry": 0.88,
		"music": ["music_castle_a", "music_castle_b"], "gap": [30.0, 70.0], "indoor": true},
	"library": {"beds": ["amb_library"], "scatter": ["library", "magic"], "room_size": 0.35, "damping": 0.62, "wet": 0.18, "dry": 0.95,
		"music": ["music_castle_b"], "gap": [40.0, 90.0], "indoor": true},
	"interior": {"beds": ["amb_castle"], "scatter": ["castle", "magic"], "room_size": 0.7, "damping": 0.4, "wet": 0.3, "dry": 0.9,
		"music": ["music_castle_a", "music_castle_b"], "gap": [30.0, 70.0], "indoor": true},
	"dungeon": {"beds": ["amb_dungeon"], "scatter": ["drips", "deep"], "room_size": 0.75, "damping": 0.25, "wet": 0.38, "dry": 0.88,
		"music": ["music_dungeon"], "gap": [15.0, 35.0], "indoor": true},
	"corridor": {"beds": ["amb_corridor"], "scatter": ["drips", "deep"], "room_size": 0.8, "damping": 0.3, "wet": 0.4, "dry": 0.86,
		"music": ["music_corridor", "music_dungeon"], "gap": [12.0, 30.0], "indoor": true},
}

## Music states -> the representative track (the checks read this).
const MUSIC_STATES := {
	"menu": "music_menu",
	"map": "music_grounds_a",
	"castle": "music_castle_a",
	"dungeon": "music_dungeon",
	"flight": "music_flight",
	"combat": "music_combat",
	"boss": "music_boss",
}

const MUSIC_FADE_IN := 3.0
const MUSIC_FADE_COMBAT := 0.8
const MUSIC_FADE_OUT := 3.5
## A zone change cross-fades over this long.
const MUSIC_CROSSFADE := 3.0
## After a fight the world is quiet for a moment before exploration music returns.
const AFTER_COMBAT_GAP := [6.0, 14.0]
## Combat music lingers this long after the last blow / cast / creature on the player.
const COMBAT_LINGER := 9.0
const BOSS_LINGER := 14.0
## Tension per second up (into a fight) and down (after it).
const TENSION_RISE := 1.2
const TENSION_FALL := 0.3
## Ambience under a fight at full tension, in dB.
const TENSION_DUCK_DB := -6.0
## Music under a stinger, and under dialogue or the game menu, in dB.
const STINGER_DUCK_DB := -9.0
const DIM_DB := -7.0
## The same stinger at most this often (seconds).
const STINGER_SPACING := 30.0
## Flight: the rider is "flying" for the soundtrack once this high above the
## ground for this long; the high wind layer fades in between these heights.
const FLIGHT_MUSIC_HEIGHT := 10.0
const FLIGHT_MUSIC_DELAY := 4.0
const HIGH_WIND_FROM := 8.0
const HIGH_WIND_FULL := 60.0
## Health fraction where the heartbeat starts / is at full strength.
const LOW_HP_START := 0.3
const LOW_HP_FULL := 0.1
## Frame-cost samples kept (microseconds per frame of the audio layer).
const COST_SAMPLES := 4096
## Streams load on the main thread (no threaded loads in the client): the
## world's sounds are read ahead from a queue, one every WARM_EVERY seconds,
## or up to WARM_BUDGET_US a frame while the loading screen covers the world.
const WARM_EVERY := 0.2
const WARM_BUDGET_US := 8000
## A track whose file still has to be read waits a frame when this much was
## already read on this one (a zone change reads its bed first).
const LOAD_SPREAD_US := 1500

var library: Dictionary = {}
## "Master" is the Master bus (the settings' overall volume).
var volumes := {"Master": 1.0, "Music": 0.7, "SFX": 1.0, "UI": 0.9, "Ambience": 0.8}

## --- what WorldAudio reports about the listener (its world, not ours)
var zone := ""
var listener := Vector3.INF
var altitude := 0.0
var mounted := false
var flight_time := 0.0
var hp_fraction := 1.0
var dead := false
var raining := false
var despair := false
## Dims on the music by reason ("dialogue", "menu").
var dims: Dictionary = {}

## --- state the checks read
## Every key played (a small ring) and how often each key played.
var played_log: Array[String] = []
var played_counts: Dictionary = {}
## Cross-fades between tracks: {from, to, reason, at}.
var crossfades: Array = []
## 0..1: how much of a fight the mix is in.
var tension := 0.0
var music_state := ""
var stingers_played: Array[String] = []

var _spatial_pool: Array[AudioStreamPlayer3D] = []
var _flat_pool: Array[AudioStreamPlayer] = []
var _loops: Dictionary = {}          # key::owner_id -> player
var _last_played: Dictionary = {}    # key -> msec, for the flat repeat guard
var _streams: Dictionary = {}        # path -> AudioStream
var _last_variant: Dictionary = {}   # key -> the variant key it played last
var _last_take: Dictionary = {}      # family -> the take it played last (steps, robe)

## Ambient beds: key -> {"player", "target_db", "base_db"}; dynamic layers
## (high wind, heartbeat, despair, broom wind): key -> {"player", "target_db",
## "pitch", "level"}. Volumes glide toward their targets every frame.
var _beds: Dictionary = {}
var _layers: Dictionary = {}
var _scatter_next: Dictionary = {}
var _scatter_last: Dictionary = {}
var _reverb_sfx: AudioEffectReverb
var _reverb_amb: AudioEffectReverb
var _lowpass_music: AudioEffectLowPassFilter
var _lowpass_amb: AudioEffectLowPassFilter
var _duck_music: AudioEffectAmplify
var _duck_amb: AudioEffectAmplify

## The music director.
var _world: Node = null
var _music_pinned := false
var _music_active: AudioStreamPlayer = null
var _music_active_key := ""
var _music_players: Array[AudioStreamPlayer] = []
var _music_tweens: Array[Tween] = []
var _music_pool_id := ""
var _music_next_at := 0.0
var _music_last_key := ""
var _music_combat_until := 0.0
var _music_boss_until := 0.0
var _stinger_player: AudioStreamPlayer = null
var _last_stinger: Dictionary = {}
var _stinger_duck_until := 0.0
var _was_dead := false
var _music_pending: Dictionary = {}
## Microseconds spent reading streams this frame; the read-ahead queue.
var _load_usec := 0
var _warm_queue: Array[String] = []
var _warm_at := 0.0

## The audio layer's own cost: microseconds this frame, and past frames'
## (without reading files); the frames that read a file and their longest.
var _cost_frame := 0
var _frame_load := 0
var cost_samples: PackedInt32Array = PackedInt32Array()
var _cost_at := 0
var load_frames := 0
var load_max_us := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	_load_library()
	_load_settings()
	_apply_volumes()
	_setup_bus_effects()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE \
			or what == NOTIFICATION_EXIT_TREE:
		# Shutdown releases every stream: a stopped player that still holds one
		# keeps its playback alive past exit.
		stop_everything()
		_streams.clear()

# ------------------------------------------------------------------ buses

func _ensure_buses() -> void:
	for bus_name: String in BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus_name), "Master")

## The SFX limiter, the zone reverb on effects and ambience, and the tension
## mix: a low-pass that muffles music and ambience when hurt or fallen, and an
## amplify stage that ducks the ambience under a fight and the music under a
## stinger or a dialogue.
func _setup_bus_effects() -> void:
	var sfx := AudioServer.get_bus_index("SFX")
	# A burst of spells must not clip over a combat warning.
	var limiter := AudioEffectLimiter.new()
	limiter.ceiling_db = -1.0
	limiter.threshold_db = -6.0
	limiter.soft_clip_db = -2.0
	AudioServer.add_bus_effect(sfx, limiter)
	_reverb_sfx = AudioEffectReverb.new()
	AudioServer.add_bus_effect(sfx, _reverb_sfx)
	var amb := AudioServer.get_bus_index("Ambience")
	_reverb_amb = AudioEffectReverb.new()
	AudioServer.add_bus_effect(amb, _reverb_amb)
	_lowpass_amb = AudioEffectLowPassFilter.new()
	_lowpass_amb.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(amb, _lowpass_amb)
	_duck_amb = AudioEffectAmplify.new()
	AudioServer.add_bus_effect(amb, _duck_amb)
	var music := AudioServer.get_bus_index("Music")
	_lowpass_music = AudioEffectLowPassFilter.new()
	_lowpass_music.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(music, _lowpass_music)
	_duck_music = AudioEffectAmplify.new()
	AudioServer.add_bus_effect(music, _duck_music)
	_apply_reverb(ZONES["grounds"])

func _set_bus_volume_linear(bus_name: String, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index != -1:
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(0.0001, clampf(linear, 0.0, 1.5))))

func _apply_volumes() -> void:
	for bus_name: String in volumes:
		_set_bus_volume_linear(bus_name, float(volumes[bus_name]))

## Independent master / music / SFX / UI / ambience volume, 0..1, saved.
func set_volume(bus_name: String, linear: float) -> void:
	if not volumes.has(bus_name):
		return
	volumes[bus_name] = clampf(linear, 0.0, 1.0)
	_apply_volumes()
	_save_settings()

func get_volume(bus_name: String) -> float:
	return float(volumes.get(bus_name, 1.0))

# ------------------------------------------------------------------ library

func _load_library() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIBRARY_PATH))
	if not parsed is Dictionary:
		printerr("AudioManager: ", LIBRARY_PATH, " could not be read")
		return
	library = (parsed as Dictionary).get("sounds", {})

func has_sound(key: String) -> bool:
	return library.has(key)

## Load `key`'s stream and every take it may be played as now (they stay
## cached), so its first play does not read a file on that frame.
func warm_sound(key: String) -> void:
	_stream(key)
	for other: String in library.get(key, {}).get("variants", []):
		_stream(other)

func _is_cached(key: String) -> bool:
	var path := String(library.get(key, {}).get("path", ""))
	if path != "" and not path.begins_with("res://"):
		path = "res://" + path
	return path == "" or _streams.has(path)

## Read `keys` (and their takes) ahead, in order, from the queue.
func queue_warm(keys: Array) -> void:
	for key: String in keys:
		if not has_sound(key):
			continue
		for take: String in [key] + Array(library[key].get("variants", [])):
			if not _is_cached(take) and not _warm_queue.has(take):
				_warm_queue.append(take)

## The world's sounds, read ahead as a world is joined: every short one-shot
## first (steps, voices, the scatter, travel, the interface), then the layers,
## then the zone's beds and music and the fight's and flight's tracks.
func warm_world() -> void:
	var short: Array = []
	var later: Array = []
	for key: String in library:
		var entry: Dictionary = library[key]
		var path := String(entry.get("path", ""))
		if path.contains("/music/") or path.contains("/spells/"):
			continue
		if bool(entry.get("loop", false)):
			later.append(key)
		else:
			short.append(key)
	queue_warm(short)
	queue_warm(later)
	queue_warm_zone(zone)
	queue_warm(["music_combat", "music_flight", "music_boss", "stinger_boss", "stinger_victory", "stinger_death"])

## A zone's beds and music, read ahead.
func queue_warm_zone(name: String) -> void:
	var config: Dictionary = ZONES.get(name, {})
	if not config.is_empty():
		queue_warm(config["beds"])
		queue_warm(config["music"])

func _process_warm() -> void:
	if _warm_queue.is_empty():
		return
	var screen := get_tree().root.get_node_or_null("MapLoadingScreen") as MapLoadingScreen
	if screen != null and screen.is_open():
		while not _warm_queue.is_empty() and _load_usec < WARM_BUDGET_US:
			_stream(_warm_queue.pop_front())
		return
	if _now() < _warm_at:
		return
	_warm_at = _now() + WARM_EVERY
	_stream(_warm_queue.pop_front())

func _stream(key: String) -> AudioStream:
	var entry: Dictionary = library.get(key, {})
	var path := String(entry.get("path", ""))
	if path == "":
		return null
	if not path.begins_with("res://"):
		path = "res://" + path
	if not _streams.has(path):
		if not ResourceLoader.exists(path):
			return null
		var loading := Time.get_ticks_usec()
		var stream: AudioStream = load(path)
		_load_usec += Time.get_ticks_usec() - loading
		_frame_load += Time.get_ticks_usec() - loading
		# MP3/OGG carry their loop flag at runtime (the library decides).
		if stream is AudioStreamMP3:
			(stream as AudioStreamMP3).loop = bool(entry.get("loop", false))
		elif stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = bool(entry.get("loop", false))
		_streams[path] = stream
	return _streams[path]

## The key whose file plays for `key`: the entry itself or one of its library
## `variants` (a track's alternate take, a cast sound's other takes), never
## the same one twice in a row. A variant plays with its base entry's mix.
func _variant(key: String) -> String:
	var options: Array = [key]
	for other: String in library.get(key, {}).get("variants", []):
		if has_sound(other):
			options.append(other)
	if options.size() > 1:
		options.erase(_last_variant.get(key, ""))
	var chosen := String(options[randi() % options.size()])
	_last_variant[key] = chosen
	return chosen

func _note_played(key: String) -> void:
	played_log.append(key)
	if played_log.size() > 96:
		played_log.remove_at(0)
	played_counts[key] = int(played_counts.get(key, 0)) + 1

## How often keys starting with `prefix` played since the start.
func played_count(prefix: String) -> int:
	var total := 0
	for key: String in played_counts:
		if key.begins_with(prefix):
			total += int(played_counts[key])
	return total

# ------------------------------------------------------------------ playing

func _spatial_player() -> AudioStreamPlayer3D:
	for player in _spatial_pool:
		if not player.playing:
			return player
	if _spatial_pool.size() < MAX_SPATIAL_VOICES:
		var created := AudioStreamPlayer3D.new()
		created.name = "Spatial%d" % _spatial_pool.size()
		created.max_distance = HEARING
		created.unit_size = 6.0
		created.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		created.finished.connect(_on_voice_finished.bind(created))
		add_child(created)
		_spatial_pool.append(created)
		return created
	# voice limit reached: steal the oldest non-priority voice
	var oldest: AudioStreamPlayer3D = null
	var oldest_time := INF
	for player in _spatial_pool:
		if bool(player.get_meta("priority", false)):
			continue
		var started := float(player.get_meta("started", 0.0))
		if started < oldest_time:
			oldest_time = started
			oldest = player
	return oldest if oldest != null else _spatial_pool[0]

func _flat_player() -> AudioStreamPlayer:
	for player in _flat_pool:
		if not player.playing and not bool(player.get_meta("bed", false)):
			return player
	if _flat_pool.size() < MAX_FLAT_VOICES:
		var created := AudioStreamPlayer.new()
		created.name = "Flat%d" % _flat_pool.size()
		created.finished.connect(_on_voice_finished.bind(created))
		add_child(created)
		_flat_pool.append(created)
		return created
	# never a bed: the oldest one-shot gives way
	var oldest: AudioStreamPlayer = null
	var oldest_time := INF
	for player in _flat_pool:
		if bool(player.get_meta("bed", false)):
			continue
		var started := float(player.get_meta("started", 0.0))
		if started < oldest_time:
			oldest_time = started
			oldest = player
	return oldest

## A voice that finished releases its stream (an idle player holding a stream
## keeps its playback alive).
func _on_voice_finished(player: Node) -> void:
	if is_instance_valid(player) and player.get("playing") == false and not bool(player.get_meta("bed", false)):
		player.set("stream", null)

## Voices of `category` sounding now.
func _category_voices(category: String) -> int:
	var count := 0
	for player in _spatial_pool:
		if player.playing and String(player.get_meta("category", "")) == category:
			count += 1
	return count

## Where the ear is: the camera of the world being drawn.
func _ear() -> Vector3:
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	return camera.global_position if camera != null else listener

## Play one sound: positional at `position` unless the library marks it flat
## or `force_flat` asks. `owner_node` only keys loops; `category` caps how
## many voices of its kind sound at once (CATEGORY_CAPS). Returns the voice,
## or null when nothing was started (unknown, out of earshot, capped).
func play_sound_at(key: String, position: Vector3, owner_node: Node = null, force_flat: bool = false,
		category := "") -> Node:
	var entry: Dictionary = library.get(key, {})
	if entry.is_empty():
		return null
	var looping := bool(entry.get("loop", false))
	var spatial := bool(entry.get("spatial", true)) and not force_flat
	if spatial and not looping and category != "":
		# a crowd's sound out of earshot: no voice spent on it
		var ear := _ear()
		if ear != Vector3.INF and ear.distance_to(position) > HEARING:
			return null
	if category != "" and _category_voices(category) >= int(CATEGORY_CAPS.get(category, MAX_SPATIAL_VOICES)):
		return null
	var stream := _stream(_variant(key))
	if stream == null:
		return null
	if not looping and not spatial:
		var now := Time.get_ticks_msec()
		if now - int(_last_played.get(key, -100000)) < FLAT_REPEAT_MSEC:
			return null
		_last_played[key] = now
	var variation := float(entry.get("pitch_variation", 0.0))
	var pitch := 1.0 if variation <= 0.0 else clampf(1.0 + randf_range(-variation, variation), 0.5, 2.0)
	var player: Node = _spatial_player() if spatial else _flat_player()
	if player == null:
		return null
	player.call("stop")
	player.set("stream", stream)
	player.set("bus", String(BUS_NAMES.get(String(entry.get("bus", "sfx")), "SFX")))
	player.set("pitch_scale", pitch)
	player.set("volume_db", float(entry.get("gain_db", 0.0)))
	player.set_meta("key", key)
	player.set_meta("loop_key", "")
	player.set_meta("category", category)
	player.set_meta("started", float(Time.get_ticks_msec()) / 1000.0)
	player.set_meta("priority", key in WARNING_PRIORITY)
	if spatial:
		var voice := player as AudioStreamPlayer3D
		voice.max_distance = 60.0 if looping else HEARING
		voice.global_position = position
	_note_played(key)
	if audio_available():
		player.call("play")
	return player

## Start (or reuse) a looping sound for one owner, at the owner. Returns the voice.
func loop_sound(key: String, owner_node: Node) -> Node:
	var loop_key := _loop_key(key, owner_node)
	var held := _loop_voice(loop_key)
	if held != null:
		return held
	var at := (owner_node as Node3D).global_position if owner_node is Node3D else Vector3.ZERO
	var player := play_sound_at(key, at, owner_node)
	if player != null:
		player.set_meta("loop_key", loop_key)
		_loops[loop_key] = player
	return player

## The voice still holding loop `loop_key`: a pooled voice can be stolen by
## another sound and must not be moved or stopped for its old owner.
func _loop_voice(loop_key: String) -> Node:
	var player: Variant = _loops.get(loop_key)
	if is_instance_valid(player) and String((player as Node).get_meta("loop_key", "")) == loop_key:
		return player
	_loops.erase(loop_key)
	return null

## Keep a loop on its moving owner (a bolt in flight).
func move_loop(key: String, owner_node: Node, position: Vector3) -> void:
	var player := _loop_voice(_loop_key(key, owner_node))
	if player is AudioStreamPlayer3D:
		(player as AudioStreamPlayer3D).global_position = position

func stop_sound(key: String, owner_node: Node) -> void:
	var loop_key := _loop_key(key, owner_node)
	var player := _loop_voice(loop_key)
	_loops.erase(loop_key)
	if player != null:
		player.set_meta("loop_key", "")
		player.call("stop")
		player.set("stream", null)

func _loop_key(key: String, owner_node: Node) -> String:
	return "%s::%d" % [key, owner_node.get_instance_id() if is_instance_valid(owner_node) else 0]

## Every voice stops and lets go of its stream (shutdown).
func stop_everything() -> void:
	for pool: Array in [_spatial_pool, _flat_pool]:
		for player in pool:
			if is_instance_valid(player):
				player.call("stop")
				player.set("stream", null)
				player.set_meta("bed", false)
	_kill_music_tweens()
	for player in _music_players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	if _stinger_player != null and is_instance_valid(_stinger_player):
		_stinger_player.stop()
		_stinger_player.stream = null
	_music_active = null
	_music_active_key = ""
	_music_pool_id = ""
	_loops.clear()
	_beds.clear()
	_layers.clear()
	_scatter_next.clear()

## True when there is an audio device that can actually play.
func audio_available() -> bool:
	var driver := AudioServer.get_driver_name().to_lower()
	return driver != "" and driver != "dummy"

# ------------------------------------------------------------------ steps

## One footstep on `surface` (stone, grass, dirt, wood, water): one of its
## four takes, never the same twice in a row, quiet and a little varied
## (footsteps are background sounds). `gain_scale` lowers it further
## (another player's step).
func play_step(surface: String, at: Vector3, gain_scale := 1.0) -> Node:
	if not has_sound("step_%s_1" % surface):
		surface = "stone"
	return _play_take("step_" + surface, "step_%s_%d", surface, 4, at, gain_scale, "step")

## The robe's swish under a stride (a soft cloth cue now and then).
func play_robe(at: Vector3, gain_scale := 1.0) -> Node:
	return _play_take("robe", "robe_%d", "", 3, at, gain_scale, "step")

func _play_take(family: String, pattern: String, surface: String, takes: int, at: Vector3,
		gain_scale: float, category: String) -> Node:
	var last := String(_last_take.get(family, ""))
	var key := last
	for _i in 4:
		key = (pattern % [surface, randi() % takes + 1]) if surface != "" else (pattern % (randi() % takes + 1))
		if key != last and has_sound(key):
			break
	_last_take[family] = key
	var player := play_sound_at(key, at, null, false, category)
	if player != null:
		player.set("volume_db", float(player.get("volume_db")) + linear_to_db(maxf(0.05, gain_scale)) + randf_range(-1.5, 1.5))
	return player

# ------------------------------------------------------------------ world

## The world scene's ear (WorldAudio) arrived: it owns the soundtrack from here.
func attach_world(world: Node) -> void:
	_world = world
	warm_world()
	if _music_pinned:
		_music_pinned = false
		music_state = ""
	_music_pool_id = ""

## Its scene is going (a map trip rebuilds it, or the game leaves the world):
## the beds and the track play on until the next scene's ear says where it is.
func detach_world(world: Node) -> void:
	if _world == world:
		_world = null

## The world was left for the login card or the character screen: the world's
## sound fades away (the front door pins its own theme).
func world_ended() -> void:
	_world = null
	zone = ""
	listener = Vector3.INF
	mounted = false
	dead = false
	despair = false
	dims.clear()
	_music_combat_until = 0.0
	_music_boss_until = 0.0
	_set_zone_beds([], false)
	_scatter_next.clear()
	for key: String in _layers.keys():
		(_layers[key] as Dictionary)["target_db"] = -60.0
	_apply_music_state(false)

## Switch the ambient beds, scatter and reverb to zone `name` (ZONES), and
## the music with them. `immediate`: the beds start at their level (the
## first zone of a session).
func set_zone(name: String, immediate := false) -> void:
	if not ZONES.has(name) or name == zone:
		return
	zone = name
	var config: Dictionary = ZONES[name]
	_apply_reverb(config)
	_set_zone_beds(config["beds"], immediate)
	queue_warm_zone(name)
	_reset_scatter(config["scatter"])
	# the music always fades: in from silence, or across from the menu theme
	_apply_music_state(false, "zone")

func is_indoors() -> bool:
	return bool((ZONES.get(zone, {}) as Dictionary).get("indoor", false))

func _apply_reverb(config: Dictionary) -> void:
	for effect: AudioEffectReverb in [_reverb_sfx, _reverb_amb]:
		if effect == null:
			continue
		effect.room_size = float(config["room_size"])
		effect.damping = float(config["damping"])
		effect.wet = float(config["wet"])
		effect.dry = float(config["dry"])
		effect.spread = 0.6

## Beds cross-fade: beds the new zone keeps stay, the others fade to silence
## and stop, new ones fade in. The per-frame mixer does the fading.
func _set_zone_beds(keys: Array, immediate: bool) -> void:
	for key: String in _beds.keys():
		if not keys.has(key):
			(_beds[key] as Dictionary)["target_db"] = -60.0
	for key: String in keys:
		if _beds.has(key):
			var bed: Dictionary = _beds[key]
			bed["target_db"] = float(bed["base_db"])
			continue
		var player := _start_bed(key, immediate)
		if player != null:
			var base := float(library[key].get("gain_db", -18.0))
			_beds[key] = {"player": player, "target_db": base, "base_db": base}

## A bed player reserved from the flat pool until it stops.
func _start_bed(key: String, immediate: bool) -> Node:
	var entry: Dictionary = library.get(key, {})
	var stream := _stream(key)
	if entry.is_empty() or stream == null:
		return null
	var player: AudioStreamPlayer = _flat_player()
	if player == null:
		return null
	player.stop()
	player.stream = stream
	player.bus = String(BUS_NAMES.get(String(entry.get("bus", "ambience")), "Ambience"))
	player.pitch_scale = 1.0
	player.volume_db = float(entry.get("gain_db", -18.0)) if immediate else -60.0
	player.set_meta("key", key)
	player.set_meta("bed", true)
	player.set_meta("started", float(Time.get_ticks_msec()) / 1000.0)
	_note_played(key)
	if audio_available():
		player.play()
		# Start somewhere inside the loop so two visits never open on the same bar.
		if stream.get_length() > 4.0:
			player.seek(randf_range(0.0, stream.get_length() * 0.8))
	return player

func _stop_bed_player(player: Node) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.call("stop")
	player.set("stream", null)
	player.set_meta("bed", false)

## Beds and layers glide toward their target volume each frame.
func _mix_beds(delta: float) -> void:
	# The ground beds give way to the high wind as the rider climbs.
	var ground_atten := 0.0 if is_indoors() \
		else -clampf((altitude - HIGH_WIND_FROM) / (HIGH_WIND_FULL - HIGH_WIND_FROM), 0.0, 1.0) * 18.0
	for key: String in _beds.keys():
		var bed: Dictionary = _beds[key]
		var player: Node = bed["player"]
		if not is_instance_valid(player):
			_beds.erase(key)
			continue
		var target := float(bed["target_db"])
		if target > -59.0:
			target += ground_atten
		var current := float(player.get("volume_db"))
		if current != target:
			player.set("volume_db", move_toward(current, target, delta * 30.0))
		if float(bed["target_db"]) <= -59.0 and current <= -58.0:
			_stop_bed_player(player)
			_beds.erase(key)
	for key: String in _layers.keys():
		var layer: Dictionary = _layers[key]
		var lp: Node = layer["player"]
		if not is_instance_valid(lp):
			_layers.erase(key)
			continue
		var cur := float(lp.get("volume_db"))
		if cur != float(layer["target_db"]):
			lp.set("volume_db", move_toward(cur, float(layer["target_db"]), delta * 30.0))
		var pitch := float(lp.get("pitch_scale"))
		var goal := float(layer.get("pitch", 1.0))
		if absf(pitch - goal) > 0.001:
			lp.set("pitch_scale", lerpf(pitch, goal, minf(1.0, delta * 3.0)))
		if float(layer["target_db"]) <= -59.0 and cur <= -58.0:
			_stop_bed_player(lp)
			_layers.erase(key)

## A dynamic layer (high wind, heartbeat, despair, broom wind): `level` 0..1
## maps silence..the library gain (+ `boost_db` at full).
func set_layer(key: String, level: float, pitch := 1.0, boost_db := 0.0) -> void:
	if not has_sound(key):
		return
	var base := float(library[key].get("gain_db", -18.0))
	var target := -60.0 if level <= 0.01 else base + boost_db * level + linear_to_db(clampf(level, 0.02, 1.0))
	if _layers.has(key):
		var layer: Dictionary = _layers[key]
		layer["target_db"] = target
		layer["pitch"] = pitch
		layer["level"] = level
		return
	if target <= -59.0:
		return
	var player := _start_bed(key, false)
	if player != null:
		_layers[key] = {"player": player, "target_db": target, "pitch": pitch, "level": level}

## A layer's state now: {level, target_db, volume_db, pitch} ({} when silent).
func layer_state(key: String) -> Dictionary:
	var layer: Dictionary = _layers.get(key, {})
	if layer.is_empty() or not is_instance_valid(layer["player"]):
		return {}
	var player: Node = layer["player"]
	return {"level": float(layer.get("level", 0.0)), "target_db": float(layer["target_db"]),
		"volume_db": float(player.get("volume_db")), "pitch": float(player.get("pitch_scale")),
		"target_pitch": float(layer.get("pitch", 1.0))}

func _reset_scatter(sets: Array) -> void:
	_scatter_next.clear()
	for set_name: String in sets:
		var cfg: Dictionary = SCATTER.get(set_name, {})
		if cfg.is_empty():
			continue
		var gap: Array = cfg["gap"]
		_scatter_next[set_name] = randf_range(float(gap[0]) * 0.3, float(gap[1]) * 0.6)

func _process_scatter(delta: float) -> void:
	if _scatter_next.is_empty() or _world == null or dead or listener == Vector3.INF:
		return
	for set_name: String in _scatter_next.keys():
		_scatter_next[set_name] = float(_scatter_next[set_name]) - delta
		if float(_scatter_next[set_name]) > 0.0:
			continue
		var cfg: Dictionary = SCATTER[set_name]
		var gap: Array = cfg["gap"]
		# Fights thin the scatter out: the world is busy elsewhere.
		_scatter_next[set_name] = randf_range(float(gap[0]), float(gap[1])) * (1.6 if combat_music_active() else 1.0)
		if bool(cfg.get("ground", false)) and altitude > 25.0:
			continue
		if bool(cfg.get("dry", false)) and raining:
			continue
		var choices: Array = []
		for key: String in cfg["keys"]:
			if has_sound(key) and key != String(_scatter_last.get(set_name, "")):
				choices.append(key)
		if choices.is_empty():
			continue
		var key: String = choices[randi() % choices.size()]
		_scatter_last[set_name] = key
		var node: Node = null
		if bool(cfg.get("spatial", false)):
			var dist_range: Array = cfg.get("dist", [10.0, 25.0])
			var angle := randf_range(0.0, TAU)
			var dist := randf_range(float(dist_range[0]), float(dist_range[1]))
			var h := randf_range(0.3, float(cfg.get("height", 3.0)))
			node = play_sound_at(key, listener + Vector3(cos(angle) * dist, h, sin(angle) * dist), null, false, "scatter")
		else:
			node = play_sound_at(key, Vector3.ZERO, null, true)
			if node != null:
				node.set("bus", "Ambience")
		if node != null:
			node.set("volume_db", float(node.get("volume_db")) + randf_range(-2.5, 1.0))

# ------------------------------------------------------------------ the mix

func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_flush_cost()
	_load_usec = 0
	_process_warm()
	_process_scatter(delta)
	_process_flight()
	_process_tension(delta)
	_mix_beds(delta)
	if not _music_pending.is_empty() and _load_usec < LOAD_SPREAD_US:
		var pending := _music_pending
		_music_pending = {}
		_start_music(String(pending["key"]), float(pending["fade"]), String(pending["reason"]))
	_refresh_music()
	add_cost(Time.get_ticks_usec() - started)

## The audio layer's time this frame (WorldAudio adds its own).
func add_cost(usec: int) -> void:
	_cost_frame += usec

func _flush_cost() -> void:
	var work := maxi(0, _cost_frame - _frame_load)
	var read := _frame_load
	_cost_frame = 0
	_frame_load = 0
	if _world == null:
		return
	if read > 0:
		load_frames += 1
		load_max_us = maxi(load_max_us, read)
	if cost_samples.size() < COST_SAMPLES:
		cost_samples.append(work)
	else:
		cost_samples[_cost_at] = work
		_cost_at = (_cost_at + 1) % COST_SAMPLES

## {frames, mean_us, p99_us, max_us} over the kept frames (file reads apart:
## load_frames of them read a file, the longest read load_max_us).
func cost_summary() -> Dictionary:
	if cost_samples.is_empty():
		return {"frames": 0, "mean_us": 0.0, "p99_us": 0, "max_us": 0, "load_frames": 0, "load_max_us": 0}
	var sorted := cost_samples.duplicate()
	sorted.sort()
	var total := 0
	for v in sorted:
		total += v
	return {"frames": sorted.size(), "mean_us": float(total) / sorted.size(),
		"p99_us": sorted[mini(sorted.size() - 1, int(sorted.size() * 0.99))], "max_us": sorted[sorted.size() - 1],
		"load_frames": load_frames, "load_max_us": load_max_us}

func reset_cost() -> void:
	cost_samples = PackedInt32Array()
	_cost_at = 0
	load_frames = 0
	load_max_us = 0

## Flight: the high wind rises with altitude whether mounted or not (the
## broom's own wind is WorldAudio's: it follows the rider's speed).
func _process_flight() -> void:
	var high := 0.0
	if _world != null and not is_indoors():
		high = clampf((altitude - HIGH_WIND_FROM) / (HIGH_WIND_FULL - HIGH_WIND_FROM), 0.0, 1.0)
	set_layer("amb_high_wind", high)

## Low health, a pallid's chill, a fight and death shape the mix.
func _process_tension(delta: float) -> void:
	var in_world := _world != null
	if dead and not _was_dead and in_world:
		_on_death()
	_was_dead = dead
	var goal := 1.0 if combat_music_active() and not dead else 0.0
	tension = move_toward(tension, goal, delta * (TENSION_RISE if goal > tension else TENSION_FALL))
	# Heartbeat: from LOW_HP_START down to LOW_HP_FULL, faster as it gets worse.
	var danger := 0.0 if dead or not in_world \
		else clampf((LOW_HP_START - hp_fraction) / (LOW_HP_START - LOW_HP_FULL), 0.0, 1.0)
	set_layer("tension_heartbeat", danger, lerpf(0.95, 1.3, danger))
	set_layer("amb_despair", 0.85 if despair and not dead and in_world else 0.0)
	# Muffle: hurt -> 1.8 kHz, fallen -> 700 Hz; a pallid takes the top off too.
	var cutoff := 20000.0
	if dead and in_world:
		cutoff = 700.0
	elif danger > 0.0:
		cutoff = lerpf(9000.0, 1800.0, danger)
	if despair and not dead and in_world:
		cutoff = minf(cutoff, 4500.0)
	for filter: AudioEffectLowPassFilter in [_lowpass_music, _lowpass_amb]:
		if filter != null:
			# glide in log space so the sweep sounds even
			if absf(filter.cutoff_hz - cutoff) > 1.0:
				filter.cutoff_hz = exp(lerpf(log(filter.cutoff_hz), log(cutoff), minf(1.0, delta * 2.5)))
	if _duck_amb != null and _duck_amb.volume_db != TENSION_DUCK_DB * tension:
		_duck_amb.volume_db = move_toward(_duck_amb.volume_db, TENSION_DUCK_DB * tension, delta * 6.0)
	if _duck_music != null:
		var music_target := 0.0
		if not dims.is_empty():
			music_target = DIM_DB
		if _now() < _stinger_duck_until:
			music_target = minf(music_target, STINGER_DUCK_DB)
		if _duck_music.volume_db != music_target:
			_duck_music.volume_db = move_toward(_duck_music.volume_db, music_target, delta * 18.0)

func _on_death() -> void:
	_music_combat_until = 0.0
	_music_boss_until = 0.0
	_stop_music(1.2)

## Dialogue or a menu over the world: the music steps back while it is up.
func set_dim(reason: String, on: bool) -> void:
	if on:
		dims[reason] = true
	else:
		dims.erase(reason)

func music_dim_db() -> float:
	return _duck_music.volume_db if _duck_music != null else 0.0

# ------------------------------------------------------------------ music

## A pinned state (the front door's menu theme) owns the soundtrack until a
## world's ear arrives.
func set_music_state(state: String) -> void:
	if not MUSIC_STATES.has(state):
		return
	music_state = state
	_music_pinned = true
	_apply_music_state(false)

func get_music_state() -> String:
	return _music_pool_id.get_slice(":", 0)

## The zone that owns a place -> the state its track represents.
func music_state_for_zone(zone_name: String) -> String:
	if zone_name in ["feast_hall", "library", "interior"]:
		return "castle"
	if zone_name in ["dungeon", "corridor"]:
		return "dungeon"
	return "map"

## A fight near the listener: raise or extend the combat override.
func notify_combat(seconds := COMBAT_LINGER) -> void:
	_music_combat_until = maxf(_music_combat_until, _now() + maxf(0.0, seconds))
	_apply_music_state(false)

## A boss is on the listener: its stinger once, then boss music.
func notify_boss(seconds := BOSS_LINGER) -> void:
	if _music_boss_until < _now():
		play_stinger("stinger_boss")
	_music_boss_until = maxf(_music_boss_until, _now() + seconds)
	notify_combat(seconds)

## The boss fell: victory, and the fight winds down at once.
func boss_fell() -> void:
	_music_boss_until = 0.0
	_music_combat_until = minf(_music_combat_until, _now() + 1.0)
	play_stinger("stinger_victory")

func combat_music_active() -> bool:
	return _music_combat_until > _now()

## A short musical cue over the soundtrack; the music ducks under it. The same
## stinger never twice within STINGER_SPACING, and never over another.
func play_stinger(key: String) -> void:
	if not has_sound(key):
		return
	if _now() - float(_last_stinger.get(key, -1000.0)) < STINGER_SPACING or _now() < _stinger_duck_until:
		return
	_last_stinger[key] = _now()
	var stream := _stream(_variant(key))
	if stream == null:
		return
	if _stinger_player == null or not is_instance_valid(_stinger_player):
		_stinger_player = AudioStreamPlayer.new()
		_stinger_player.name = "Stinger"
		add_child(_stinger_player)
	_stinger_player.stream = stream
	# on the UI bus: the music's duck must not take the stinger down with it
	_stinger_player.bus = "UI"
	_stinger_player.volume_db = float(library[key].get("gain_db", -9.0))
	_stinger_duck_until = _now() + stream.get_length()
	stingers_played.append(key)
	_note_played(key)
	if audio_available():
		_stinger_player.play()

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

## What should be sounding: a state and its pool.
func _music_target() -> Dictionary:
	if _music_pinned:
		return {"state": music_state, "pool": [String(MUSIC_STATES.get(music_state, ""))], "loop": true}
	if zone == "":
		return {"state": "", "pool": []}
	if dead:
		return {"state": "dead", "pool": []}
	if _music_boss_until > _now():
		return {"state": "boss", "pool": ["music_boss"], "loop": true}
	if combat_music_active():
		return {"state": "combat", "pool": ["music_combat"], "loop": true}
	if mounted and flight_time > FLIGHT_MUSIC_DELAY and not is_indoors():
		return {"state": "flight", "pool": ["music_flight"], "gap": [20.0, 45.0]}
	var config: Dictionary = ZONES.get(zone, ZONES["grounds"])
	return {"state": music_state_for_zone(zone), "pool": config["music"], "gap": config["gap"]}

func _refresh_music() -> void:
	_apply_music_state(false)

func _apply_music_state(immediate: bool, reason := "") -> void:
	var want := _music_target()
	var pool: Array = want.get("pool", [])
	var state := String(want.get("state", ""))
	var pool_id := "%s:%s" % [state, ",".join(pool)]
	var playing := _music_sounding()
	if pool_id != _music_pool_id:
		var previous_state := _music_pool_id.get_slice(":", 0)
		_music_pool_id = pool_id
		if pool.is_empty():
			_stop_music(0.0 if immediate else (1.2 if state == "dead" else MUSIC_FADE_OUT))
			return
		# The track already sounding belongs to the new pool: let it play on.
		if playing and pool.has(_music_active_key):
			return
		# Landing mid flight-theme: let the theme play out, then the place's
		# own music returns after the usual gap (no cut on every touch-down).
		if playing and previous_state == "flight" and not (state in ["combat", "boss", "dead", "menu"]):
			return
		var into_fight := state == "combat" or state == "boss"
		var after_fight := previous_state == "combat" or previous_state == "boss"
		if into_fight or state == "menu" or state == "flight" or (not playing and previous_state in ["", "menu", "dead"]):
			_start_music(_pick_track(pool), 0.0 if immediate else (MUSIC_FADE_COMBAT if into_fight else MUSIC_FADE_IN),
				reason if reason != "" else state)
		elif playing and not after_fight:
			# into a new place: its own track cross-fades in over the old one
			_start_music(_pick_track(pool), 0.0 if immediate else MUSIC_CROSSFADE, reason if reason != "" else "zone")
		elif after_fight:
			# Out of a fight: the battle music fades, then a breath of silence
			# before the place's music returns.
			_stop_music(0.0 if immediate else MUSIC_FADE_OUT)
			_music_next_at = _now() + (0.0 if immediate else randf_range(AFTER_COMBAT_GAP[0], AFTER_COMBAT_GAP[1]))
		else:
			# Into a new place between tracks: its music comes after a short breath.
			_music_next_at = minf(_music_next_at, _now() + (0.0 if immediate else randf_range(2.0, 5.0)))
		return
	if playing or pool.is_empty():
		return
	if _now() >= _music_next_at:
		_start_music(_pick_track(pool), 0.0 if immediate else MUSIC_FADE_IN, "next")

## The active track is sounding (or, with no device, would be).
func _music_sounding() -> bool:
	if _music_active == null or not is_instance_valid(_music_active):
		return false
	return _music_active.playing or (not audio_available() and _music_active_key != "")

func _pick_track(pool: Array) -> String:
	var options: Array = []
	for key: String in pool:
		if has_sound(key) and key != _music_last_key:
			options.append(key)
	if options.is_empty():
		for key: String in pool:
			if has_sound(key):
				options.append(key)
	return "" if options.is_empty() else String(options[randi() % options.size()])

func _start_music(key: String, fade: float, reason := "") -> void:
	if key == "":
		return
	# Each track alternates with its variants (the original, then its alt take).
	var take := _variant(key)
	if not _is_cached(take) and _load_usec >= LOAD_SPREAD_US:
		# this frame already read a file (the zone's bed): the track's waits a frame
		_music_pending = {"key": key, "fade": fade, "reason": reason}
		return
	var stream := _stream(take)
	if stream == null:
		return
	_ensure_music_players()
	var outgoing := _music_active
	var outgoing_key := _music_active_key
	var incoming: AudioStreamPlayer = _music_players[1] if outgoing == _music_players[0] else _music_players[0]
	_kill_music_tweens()
	for player in _music_players:
		if player == incoming or not (player.playing or player.stream != null):
			continue
		if fade > 0.0 and player == outgoing:
			var fade_tween := create_tween()
			fade_tween.tween_property(player, "volume_db", -60.0, minf(fade * 1.5, MUSIC_FADE_OUT))
			fade_tween.tween_callback(_release_music_player.bind(player))
			_music_tweens.append(fade_tween)
		else:
			_release_music_player(player)
	if outgoing_key != "" and fade > 0.0:
		crossfades.append({"from": outgoing_key, "to": key, "reason": reason, "at": _now()})
	_music_active_key = key
	_music_last_key = key
	incoming.stop()
	incoming.stream = stream
	incoming.bus = "Music"
	incoming.pitch_scale = 1.0
	var target_db := float(library.get(key, {}).get("gain_db", -12.0))
	incoming.volume_db = target_db if fade <= 0.0 else -50.0
	incoming.set_meta("key", key)
	_note_played(key)
	if audio_available():
		incoming.play()
	if fade > 0.0:
		var in_tween := create_tween()
		in_tween.tween_property(incoming, "volume_db", target_db, fade)
		_music_tweens.append(in_tween)
	_music_active = incoming

func _release_music_player(player: AudioStreamPlayer) -> void:
	if not is_instance_valid(player) or player == _music_active:
		return
	player.stop()
	player.stream = null

func _stop_music(fade: float) -> void:
	_kill_music_tweens()
	for player in _music_players:
		if not is_instance_valid(player) or not (player.playing or player.stream != null):
			continue
		if fade > 0.0 and player.playing:
			var tween := create_tween()
			tween.tween_property(player, "volume_db", -60.0, fade)
			tween.tween_callback(_release_music_player.bind(player))
			_music_tweens.append(tween)
		else:
			player.stop()
			player.stream = null
	_music_active = null
	_music_active_key = ""

## A track that played out leaves silence; the next one comes after the pool's gap.
func _on_music_finished(player: AudioStreamPlayer) -> void:
	if player != _music_active:
		return
	_music_active = null
	_music_active_key = ""
	player.stream = null
	var gap: Array = _music_target().get("gap", [20.0, 50.0])
	_music_next_at = _now() + randf_range(float(gap[0]), float(gap[1]))

func _ensure_music_players() -> void:
	while _music_players.size() < 2:
		var player := AudioStreamPlayer.new()
		player.name = "Music%d" % _music_players.size()
		player.bus = "Music"
		player.finished.connect(_on_music_finished.bind(player))
		add_child(player)
		_music_players.append(player)

func _kill_music_tweens() -> void:
	for tween in _music_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_music_tweens.clear()

## The track sounding right now ("" between tracks).
func current_music_key() -> String:
	return _music_active_key

## Music players sounding now (two while a cross-fade runs).
func music_voices() -> int:
	var count := 0
	for player in _music_players:
		if is_instance_valid(player) and player.stream != null and (player.playing or not audio_available()):
			count += 1
	return count

# ------------------------------------------------------------------ interface

func play_hit() -> void:
	play_sound_at("ui_hit", Vector3.ZERO, null, true)

## The level-up cue is a small piece of music: the soundtrack ducks under it.
func play_levelup() -> void:
	if play_sound_at("ui_levelup", Vector3.ZERO, null, true) != null:
		var stream := _stream("ui_levelup")
		_stinger_duck_until = maxf(_stinger_duck_until, _now() + (stream.get_length() if stream != null else 2.0))
		stingers_played.append("ui_levelup")

func play_deny() -> void:
	play_sound_at("ui_deny", Vector3.ZERO, null, true)

func play_equip() -> void:
	play_sound_at("ui_equip", Vector3.ZERO, null, true)

func play_unequip() -> void:
	play_sound_at("ui_unequip", Vector3.ZERO, null, true)

func play_potion() -> void:
	play_sound_at("ui_potion", Vector3.ZERO, null, true)

## Mount / dismount at `at`: the take-off or landing cue.
func play_mount(on: bool, at: Vector3) -> void:
	play_sound_at("mount" if on else "dismount", at)

# ------------------------------------------------------------------ settings

func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if not parsed is Dictionary:
		return
	if int((parsed as Dictionary).get("version", 1)) < SETTINGS_VERSION:
		_save_settings()
		return
	for key: String in (parsed as Dictionary):
		if volumes.has(key):
			volumes[key] = clampf(float(parsed[key]), 0.0, 1.0)

func _save_settings() -> void:
	var handle := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if handle == null:
		return
	var data := volumes.duplicate()
	data["version"] = SETTINGS_VERSION
	handle.store_string(JSON.stringify(data))
	handle.close()

## The mix as it stands, for the checks.
func describe() -> Dictionary:
	var beds := {}
	for key: String in _beds:
		if float((_beds[key] as Dictionary)["target_db"]) > -59.0:
			beds[key] = snappedf(float((_beds[key] as Dictionary)["player"].get("volume_db")), 0.1)
	return {
		"driver": AudioServer.get_driver_name(),
		"zone": zone,
		"beds": beds,
		"layers": _layers.keys(),
		"music_state": get_music_state(),
		"music_key": _music_active_key,
		"music_voices": music_voices(),
		"crossfades": crossfades.size(),
		"tension": snappedf(tension, 0.01),
		"combat": combat_music_active(),
		"dim_db": snappedf(music_dim_db(), 0.1),
		"altitude": snappedf(altitude, 0.1),
		"spatial_voices": _spatial_pool.filter(func(p): return p.playing).size(),
	}
