extends Node

## AudioManager (autoload): the sound library, the buses and the effect voices
## the client plays today - spell casts, bolts in flight, impacts, hit
## reactions and the interface sounds.
##
## Every sound is described by `assets/audio/sound_library.json` (bus, base
## gain, pitch variation, loop mode, positional or flat, alternate takes).
## Music / SFX / UI / Ambience buses (and Master over them) carry independent,
## persisted volumes;
## positional cues play on a pooled AudioStreamPlayer3D with a voice limit
## (combat warnings keep their voices), flat cues on a pooled AudioStreamPlayer.

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
	"spell_flame_wave_impact", "spell_shockwave_impact", "spell_ultimate_impact",
	"ui_hit", "spell_ward_shield_impact",
]

const MAX_SPATIAL_VOICES := 24
const MAX_FLAT_VOICES := 22
## Two listeners of one event must not stack the same flat cue on itself.
const FLAT_REPEAT_MSEC := 80

var library: Dictionary = {}
## "Master" is the Master bus (the settings' overall volume).
var volumes := {"Master": 1.0, "Music": 0.7, "SFX": 1.0, "UI": 0.9, "Ambience": 0.8}

var _spatial_pool: Array[AudioStreamPlayer3D] = []
var _flat_pool: Array[AudioStreamPlayer] = []
var _loops: Dictionary = {}          # key::owner_id -> player
var _last_played: Dictionary = {}    # key -> msec, for the flat repeat guard
var _streams: Dictionary = {}        # path -> AudioStream
var _last_variant: Dictionary = {}   # key -> the variant key it played last

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	_load_library()
	_load_settings()
	_apply_volumes()
	# A burst of spells must not clip over a combat warning.
	var limiter := AudioEffectLimiter.new()
	limiter.ceiling_db = -1.0
	limiter.threshold_db = -6.0
	limiter.soft_clip_db = -2.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("SFX"), limiter)

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
		var stream: AudioStream = load(path)
		# MP3/OGG carry their loop flag at runtime (the library decides).
		if stream is AudioStreamMP3:
			(stream as AudioStreamMP3).loop = bool(entry.get("loop", false))
		elif stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = bool(entry.get("loop", false))
		_streams[path] = stream
	return _streams[path]

## The key whose file plays for `key`: the entry itself or one of its library
## `variants` (a cast sound's other takes), never the same one twice in a
## row. A variant plays with its base entry's mix.
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

# ------------------------------------------------------------------ playing

func _spatial_player() -> AudioStreamPlayer3D:
	for player in _spatial_pool:
		if not player.playing:
			return player
	if _spatial_pool.size() < MAX_SPATIAL_VOICES:
		var created := AudioStreamPlayer3D.new()
		created.name = "Spatial%d" % _spatial_pool.size()
		created.max_distance = 45.0
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
		if not player.playing:
			return player
	if _flat_pool.size() < MAX_FLAT_VOICES:
		var created := AudioStreamPlayer.new()
		created.name = "Flat%d" % _flat_pool.size()
		created.finished.connect(_on_voice_finished.bind(created))
		add_child(created)
		_flat_pool.append(created)
		return created
	return _flat_pool[0]

## A voice that finished releases its stream (an idle player holding a stream
## keeps its playback alive).
func _on_voice_finished(player: Node) -> void:
	if is_instance_valid(player) and player.get("playing") == false:
		player.set("stream", null)

## Play one sound: positional at `position` unless the library marks it flat
## or `force_flat` asks. `owner_node` only keys loops. Returns the voice.
func play_sound_at(key: String, position: Vector3, owner_node: Node = null, force_flat: bool = false) -> Node:
	var entry: Dictionary = library.get(key, {})
	if entry.is_empty():
		return null
	var stream := _stream(_variant(key))
	if stream == null:
		return null
	var looping := bool(entry.get("loop", false))
	var spatial := bool(entry.get("spatial", true)) and not force_flat
	if not looping and not spatial:
		var now := Time.get_ticks_msec()
		if now - int(_last_played.get(key, -100000)) < FLAT_REPEAT_MSEC:
			return null
		_last_played[key] = now
	var variation := float(entry.get("pitch_variation", 0.0))
	var pitch := 1.0 if variation <= 0.0 else clampf(1.0 + randf_range(-variation, variation), 0.5, 2.0)
	var player: Node = _spatial_player() if spatial else _flat_player()
	player.set("stream", stream)
	player.set("bus", String(BUS_NAMES.get(String(entry.get("bus", "sfx")), "SFX")))
	player.set("pitch_scale", pitch)
	player.set("volume_db", float(entry.get("gain_db", 0.0)))
	player.set_meta("started", float(Time.get_ticks_msec()) / 1000.0)
	player.set_meta("priority", key in WARNING_PRIORITY)
	if spatial:
		var voice := player as AudioStreamPlayer3D
		voice.max_distance = 60.0 if looping else 45.0
		voice.global_position = position
	if audio_available():
		player.call("play")
	return player

## Start (or reuse) a looping sound for one owner, at the owner. Returns the voice.
func loop_sound(key: String, owner_node: Node) -> Node:
	var loop_key := _loop_key(key, owner_node)
	if _loops.has(loop_key) and is_instance_valid(_loops[loop_key]):
		return _loops[loop_key]
	var at := (owner_node as Node3D).global_position if owner_node is Node3D else Vector3.ZERO
	var player := play_sound_at(key, at, owner_node)
	if player != null:
		_loops[loop_key] = player
	return player

## Keep a loop on its moving owner (a bolt in flight).
func move_loop(key: String, owner_node: Node, position: Vector3) -> void:
	var player: Variant = _loops.get(_loop_key(key, owner_node))
	if is_instance_valid(player) and player is AudioStreamPlayer3D:
		(player as AudioStreamPlayer3D).global_position = position

func stop_sound(key: String, owner_node: Node) -> void:
	var loop_key := _loop_key(key, owner_node)
	var player: Variant = _loops.get(loop_key)
	_loops.erase(loop_key)
	if is_instance_valid(player):
		(player as Node).call("stop")

func _loop_key(key: String, owner_node: Node) -> String:
	return "%s::%d" % [key, owner_node.get_instance_id() if is_instance_valid(owner_node) else 0]

## Every voice stops and lets go of its stream (shutdown).
func stop_everything() -> void:
	for pool: Array in [_spatial_pool, _flat_pool]:
		for player in pool:
			if is_instance_valid(player):
				player.call("stop")
				player.set("stream", null)
	_loops.clear()

## True when there is an audio device that can actually play.
func audio_available() -> bool:
	var driver := AudioServer.get_driver_name().to_lower()
	return driver != "" and driver != "dummy"

# ------------------------------------------------------------------ interface

func play_hit() -> void:
	play_sound_at("ui_hit", Vector3.ZERO, null, true)

func play_levelup() -> void:
	play_sound_at("ui_levelup", Vector3.ZERO, null, true)

func play_deny() -> void:
	play_sound_at("ui_deny", Vector3.ZERO, null, true)

func play_equip() -> void:
	play_sound_at("ui_equip", Vector3.ZERO, null, true)

func play_unequip() -> void:
	play_sound_at("ui_unequip", Vector3.ZERO, null, true)

func play_potion() -> void:
	play_sound_at("ui_potion", Vector3.ZERO, null, true)

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
