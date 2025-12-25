extends Node

## PioneerMusicManager - Simple music playback for zone-based music triggers
## Plays AudioStreams directly from MusicZone nodes, no JSON/stem complexity

#region Signals
signal music_changed(zone_name: String)
signal zone_entered(zone_name: String)
signal zone_exited(zone_name: String)
#endregion

#region Configuration
## Audio bus name for music
var music_bus_name: String = "Music"

## Default fade duration
var default_fade_duration: float = 2.0
#endregion

#region Internal State
# Audio players
var _intro_player: AudioStreamPlayer = null
var _loop_player: AudioStreamPlayer = null
var _fade_tween: Tween = null

# Zone tracking
var active_zones: Array = []  # Array of MusicZone nodes
var current_zone = null

# Music override stack (for dialogue/cutscenes)
var music_override_stack: Array[Dictionary] = []

# Audio bus index
var music_bus_idx: int = -1
#endregion

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_configure_audio_buses()
	_setup_players()
	print("[PioneerMusicManager] Initialized")

func _configure_audio_buses():
	music_bus_idx = AudioServer.get_bus_index(music_bus_name)

	if music_bus_idx == -1:
		# Create music bus if it doesn't exist
		var bus_count = AudioServer.bus_count
		AudioServer.add_bus(bus_count)
		music_bus_idx = bus_count
		AudioServer.set_bus_name(music_bus_idx, music_bus_name)
		AudioServer.set_bus_volume_db(music_bus_idx, 0.0)
		AudioServer.set_bus_send(music_bus_idx, "Master")
		print("[PioneerMusicManager] Created audio bus: %s" % music_bus_name)

func _setup_players():
	_intro_player = AudioStreamPlayer.new()
	_intro_player.name = "IntroPlayer"
	_intro_player.bus = music_bus_name
	_intro_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_intro_player)
	_intro_player.finished.connect(_on_intro_finished)

	_loop_player = AudioStreamPlayer.new()
	_loop_player.name = "LoopPlayer"
	_loop_player.bus = music_bus_name
	_loop_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_loop_player)
	_loop_player.finished.connect(_on_loop_finished)

#region Zone Management
func register_zone(zone) -> void:
	## Called when player enters a MusicZone
	print("[PioneerMusicManager] register_zone: %s" % [zone.name if zone else "null"])

	if zone in active_zones:
		return

	active_zones.append(zone)
	zone_entered.emit(zone.name if zone else "unknown")
	_evaluate_zone_music()

func unregister_zone(zone) -> void:
	## Called when player exits a MusicZone
	print("[PioneerMusicManager] unregister_zone: %s" % [zone.name if zone else "null"])

	if zone not in active_zones:
		return

	active_zones.erase(zone)
	zone_exited.emit(zone.name if zone else "unknown")
	_evaluate_zone_music()

func _get_highest_priority_zone():
	if active_zones.is_empty():
		return null

	var highest = active_zones[0]
	for zone in active_zones:
		var zone_prio = zone.music_priority if "music_priority" in zone else 0
		var highest_prio = highest.music_priority if "music_priority" in highest else 0
		if zone_prio > highest_prio:
			highest = zone
	return highest

func _evaluate_zone_music():
	print("[PioneerMusicManager] _evaluate_zone_music: %d active zones" % active_zones.size())

	# If there's a music override, don't change zone music
	if not music_override_stack.is_empty():
		print("[PioneerMusicManager] Override active, skipping zone music")
		return

	if active_zones.is_empty():
		# No zones, fade out music
		print("[PioneerMusicManager] No zones, fading out")
		_fade_out_music()
		current_zone = null
		return

	var highest_zone = _get_highest_priority_zone()

	# If same zone, don't restart
	if highest_zone == current_zone:
		return

	current_zone = highest_zone
	print("[PioneerMusicManager] Playing music for zone: %s" % highest_zone.name)

	# Get music from zone
	var music_file = highest_zone.music_file if "music_file" in highest_zone else null
	var intro_file = highest_zone.intro_file if "intro_file" in highest_zone else null
	var volume_db = highest_zone.volume_db if "volume_db" in highest_zone else 0.0
	var fade_duration = highest_zone.fade_duration if "fade_duration" in highest_zone else default_fade_duration

	if not music_file and not intro_file:
		print("[PioneerMusicManager] Zone has no music files!")
		return

	_play_zone_music(intro_file, music_file, volume_db, fade_duration)
	music_changed.emit(highest_zone.name)
#endregion

#region Music Playback
func _play_zone_music(intro: AudioStream, loop: AudioStream, volume_db: float, fade_duration: float):
	print("[PioneerMusicManager] _play_zone_music - intro: %s, loop: %s, vol: %s dB" % [intro, loop, volume_db])

	# Cancel any existing fade
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()

	# Stop current music with fade
	if _intro_player.playing or _loop_player.playing:
		_fade_tween = create_tween()
		_fade_tween.set_parallel(true)
		_fade_tween.tween_property(_intro_player, "volume_db", -80.0, fade_duration * 0.5)
		_fade_tween.tween_property(_loop_player, "volume_db", -80.0, fade_duration * 0.5)
		await _fade_tween.finished

	_intro_player.stop()
	_loop_player.stop()

	# Start new music
	if intro:
		print("[PioneerMusicManager] Playing intro: %s" % intro.resource_path if intro.resource_path else intro)
		_intro_player.stream = intro
		_intro_player.volume_db = -80.0
		_intro_player.play()

		# Queue up the loop
		_loop_player.stream = loop
		_loop_player.volume_db = volume_db

		# Fade in intro
		_fade_tween = create_tween()
		_fade_tween.tween_property(_intro_player, "volume_db", volume_db, fade_duration)
	elif loop:
		print("[PioneerMusicManager] Playing loop directly: %s" % loop.resource_path if loop.resource_path else loop)
		_loop_player.stream = loop
		_loop_player.volume_db = -80.0
		_loop_player.play()

		# Fade in loop
		_fade_tween = create_tween()
		_fade_tween.tween_property(_loop_player, "volume_db", volume_db, fade_duration)

	print("[PioneerMusicManager] Music started!")

func _on_intro_finished():
	## When intro finishes, start the loop
	print("[PioneerMusicManager] Intro finished, starting loop")
	if _loop_player.stream:
		_loop_player.play()

func _on_loop_finished():
	## When loop finishes, restart it (manual looping)
	if _loop_player.stream and current_zone:
		_loop_player.play()

func _fade_out_music(duration: float = -1.0):
	if duration < 0:
		duration = default_fade_duration

	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()

	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)
	_fade_tween.tween_property(_intro_player, "volume_db", -80.0, duration)
	_fade_tween.tween_property(_loop_player, "volume_db", -80.0, duration)

	await _fade_tween.finished
	_intro_player.stop()
	_loop_player.stop()

func stop_all():
	## Stop all music immediately
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_intro_player.stop()
	_loop_player.stop()
	print("[PioneerMusicManager] Stopped all music")
#endregion

#region Override System (for dialogue/cutscenes)
func play_music_override(music: AudioStream, source: String = "unknown", fade_duration: float = 2.0, volume_db: float = 0.0):
	## Temporarily override zone music
	music_override_stack.append({"music": music, "source": source, "volume_db": volume_db})
	_play_zone_music(null, music, volume_db, fade_duration)
	print("[PioneerMusicManager] Music override from %s" % source)

func stop_music_override(source: String = "", fade_duration: float = 2.0):
	## Stop the current override and return to zone music
	if music_override_stack.is_empty():
		return

	var current = music_override_stack.back()
	if not source.is_empty() and current.source != source:
		return

	music_override_stack.pop_back()

	if not music_override_stack.is_empty():
		# Play previous override
		var prev = music_override_stack.back()
		_play_zone_music(null, prev.music, prev.volume_db, fade_duration)
	else:
		# Return to zone music
		_evaluate_zone_music()

	print("[PioneerMusicManager] Stopped override, returning to zone music")

func clear_all_overrides(fade_duration: float = 2.0):
	music_override_stack.clear()
	_evaluate_zone_music()
#endregion

#region Dialogue Event Integration
func handle_dialogue_event(event: Dictionary):
	## Handle music-related dialogue events
	var event_type = event.get("type", "")

	match event_type:
		"music_play":
			var track_path = event.get("track", "")
			var fade = event.get("fade", default_fade_duration)
			var volume = event.get("volume", 0.0)
			if not track_path.is_empty():
				var stream = load(track_path)
				if stream:
					play_music_override(stream, "dialogue", fade, volume)

		"music_stop":
			var fade = event.get("fade", default_fade_duration)
			stop_music_override("dialogue", fade)
#endregion

# Legacy compatibility - these are no-ops for the simplified system
func _register_zone_music(_track_id: String, _data: Dictionary):
	## No-op - zones now provide music files directly
	pass

func get_current_song() -> String:
	return current_zone.name if current_zone else ""

func is_song_playing(_song_key: String = "") -> bool:
	return _intro_player.playing or _loop_player.playing
