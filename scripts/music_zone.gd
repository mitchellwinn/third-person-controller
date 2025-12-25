@tool
extends Area3D
class_name MusicZone

## MusicZone - Area3D that triggers music changes when player enters/exits
## Assign music_file (and optionally intro_file) in the inspector

@export var music_file: AudioStream  ## Main looping music track
@export var intro_file: AudioStream  ## Optional intro that plays once before loop
@export_range(-40.0, 6.0) var volume_db: float = 0.0
@export var fade_duration: float = 2.0
@export var music_priority: int = 0  ## Higher priority zones override lower ones
@export var trigger_groups: Array[String] = ["players"]
@export var trigger_any: bool = false  ## If true, any body triggers the zone

var _is_active: bool = false
var _music_manager = null

func _ready():
	print("[MusicZone] _ready called! Editor hint: %s" % Engine.is_editor_hint())
	if Engine.is_editor_hint():
		return

	print("[MusicZone] ========================================")
	print("[MusicZone] Initializing zone: %s" % name)
	print("[MusicZone] Music: %s" % [music_file])
	print("[MusicZone] Intro: %s" % [intro_file])
	print("[MusicZone] Volume: %s dB, Fade: %s sec" % [volume_db, fade_duration])

	# Ensure collision is set up to detect players
	collision_layer = 0  # Don't need to be detected
	collision_mask = 2   # Detect players (layer 2)
	monitoring = true
	monitorable = false
	print("[MusicZone] Collision mask set to %d, monitoring: %s" % [collision_mask, monitoring])

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	# Look for the music manager autoload
	_music_manager = get_node_or_null("/root/PioneerMusicManager")
	if not _music_manager:
		_music_manager = get_node_or_null("/root/MusicManager")

	if not _music_manager:
		push_error("[MusicZone] No music manager found! Check autoloads.")
		return

	print("[MusicZone] Ready with manager: %s" % _music_manager.name)
	print("[MusicZone] ========================================")

	# Check for bodies already inside the zone (player spawned inside)
	# Need to wait for physics to process first
	_start_initial_body_check()

func _start_initial_body_check():
	# Wait a couple physics frames for collision detection to initialize
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check_initial_bodies()

func _check_initial_bodies():
	print("[MusicZone] Zone position: %s, collision_mask: %d" % [global_position, collision_mask])

	# Print collision shape info
	for child in get_children():
		if child is CollisionShape3D:
			var shape = child.shape
			print("[MusicZone] CollisionShape at: %s, shape: %s" % [child.global_position, shape])
			if shape is BoxShape3D:
				print("[MusicZone]   BoxShape size: %s" % shape.size)

	var bodies = get_overlapping_bodies()
	print("[MusicZone] Checking for bodies already inside: %d found" % bodies.size())

	# If no bodies, let's see what players exist and where they are
	if bodies.size() == 0:
		var players = get_tree().get_nodes_in_group("players")
		print("[MusicZone] Players in scene: %d" % players.size())
		for player in players:
			print("[MusicZone]   Player '%s' at %s, layer: %d" % [player.name, player.global_position, player.collision_layer if "collision_layer" in player else -1])

	for body in bodies:
		print("[MusicZone] Found body inside: %s (groups: %s)" % [body.name, body.get_groups()])
		_on_body_entered(body)

	# If still no bodies found, the player might have spawned after us
	# Keep checking for a short time
	if bodies.size() == 0:
		print("[MusicZone] No bodies found yet, will keep checking...")
		_delayed_body_check()

func _delayed_body_check():
	# Check a few more times over the next second in case player spawns late
	for i in range(5):
		await get_tree().create_timer(0.2).timeout
		if _is_active:
			return  # Already triggered, stop checking
		var bodies = get_overlapping_bodies()
		print("[MusicZone] Delayed check %d: %d bodies" % [i + 1, bodies.size()])
		if bodies.size() > 0:
			for body in bodies:
				print("[MusicZone] Found body (delayed): %s" % body.name)
				_on_body_entered(body)
			return

func _on_body_entered(body: Node3D):
	if not _should_trigger(body):
		return

	if _is_active:
		return

	_is_active = true

	if _music_manager:
		print("[MusicZone] Player entered: %s" % name)
		_music_manager.register_zone(self)

func _on_body_exited(body: Node3D):
	if not _should_trigger(body):
		return

	# Check if any valid bodies are still inside
	var still_has_valid_body = false
	for overlapping in get_overlapping_bodies():
		if overlapping != body and _should_trigger(overlapping):
			still_has_valid_body = true
			break

	if still_has_valid_body:
		return

	_is_active = false

	if _music_manager:
		print("[MusicZone] Player exited: %s" % name)
		_music_manager.unregister_zone(self)

func _should_trigger(body: Node3D) -> bool:
	if trigger_any:
		return true

	for group in trigger_groups:
		if body.is_in_group(group):
			return true

	# Also trigger for local player (has can_receive_input)
	if "can_receive_input" in body and body.can_receive_input:
		return true

	return false
