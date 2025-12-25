extends Node

## ServerRoot - Persistent server scene that manages zone instances
## Zones are loaded as child nodes, not scene changes
## Each player is assigned to a zone and only receives RPCs from that zone

signal zone_loaded(zone_id: String, zone_node: Node)
signal zone_unloaded(zone_id: String)
signal player_zone_changed(peer_id: int, old_zone: String, new_zone: String)

@onready var zones_container: Node = $Zones

## Loaded zone scenes: zone_id -> Node
var loaded_zones: Dictionary = {}

## Player spawn queue: peer_id -> zone_id (players waiting to spawn after zone loads)
var spawn_queue: Dictionary = {}

func _ready():
	print("[ServerRoot] Server root initialized")

	# Connect to NetworkManager signals
	var network = get_node_or_null("/root/NetworkManager")
	if network:
		if network.has_signal("peer_connected"):
			network.peer_connected.connect(_on_peer_connected)
		if network.has_signal("peer_disconnected"):
			network.peer_disconnected.connect(_on_peer_disconnected)

	# Connect to ZoneManager signals
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if zone_manager:
		zone_manager.zone_created.connect(_on_zone_created)
		zone_manager.zone_destroyed.connect(_on_zone_destroyed)
		zone_manager.player_joined_zone.connect(_on_player_joined_zone)
		zone_manager.player_left_zone.connect(_on_player_left_zone)

	# Load initial hub zone
	call_deferred("_load_initial_zones")

func _load_initial_zones():
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		push_error("[ServerRoot] ZoneManager not found!")
		return

	# ZoneManager creates hub zones in _ready, we just need to load their scenes
	await get_tree().process_frame  # Wait for ZoneManager to initialize

	for zone_id in zone_manager.zones:
		_load_zone_scene(zone_id)

func _on_zone_created(zone_id: String, zone_type: String):
	print("[ServerRoot] Zone created: %s (%s)" % [zone_id, zone_type])
	_load_zone_scene(zone_id)

func _on_zone_destroyed(zone_id: String):
	print("[ServerRoot] Zone destroyed: %s" % zone_id)
	_unload_zone_scene(zone_id)

func _load_zone_scene(zone_id: String) -> Node:
	if loaded_zones.has(zone_id):
		return loaded_zones[zone_id]

	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager or not zone_manager.zones.has(zone_id):
		push_error("[ServerRoot] Zone not found in ZoneManager: %s" % zone_id)
		return null

	var zone_data = zone_manager.zones[zone_id]
	var scene_path = zone_data.scene_path

	var scene = load(scene_path)
	if not scene:
		push_error("[ServerRoot] Failed to load zone scene: %s" % scene_path)
		return null

	var zone_node = scene.instantiate()
	zone_node.name = zone_id

	# Tag the zone node with its ID for entity lookups
	zone_node.set_meta("zone_id", zone_id)

	zones_container.add_child(zone_node)
	loaded_zones[zone_id] = zone_node

	# Store reference in ZoneManager
	zone_data.scene_instance = zone_node

	print("[ServerRoot] Loaded zone scene: %s -> %s" % [zone_id, scene_path])
	zone_loaded.emit(zone_id, zone_node)

	# Process any queued spawns for this zone
	_process_spawn_queue(zone_id)

	return zone_node

func _unload_zone_scene(zone_id: String):
	if not loaded_zones.has(zone_id):
		return

	var zone_node = loaded_zones[zone_id]
	loaded_zones.erase(zone_id)

	if is_instance_valid(zone_node):
		zone_node.queue_free()

	print("[ServerRoot] Unloaded zone scene: %s" % zone_id)
	zone_unloaded.emit(zone_id)

func _on_peer_connected(peer_id: int, player_data: Dictionary):
	# peer_connected is emitted twice:
	# 1. On initial connection (steam_id=0, no zone request yet)
	# 2. After registration (steam_id set, zone request available)
	# Only assign zone after registration
	var steam_id = player_data.get("steam_id", 0)
	if steam_id == 0:
		print("[ServerRoot] Peer %d connected, waiting for registration..." % peer_id)
		return

	print("[ServerRoot] Peer %d registered, assigning to zone" % peer_id)

	# Get requested zone type from NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		return

	var requested_zone = "hub"
	if network and network.has_method("get_pending_zone_request"):
		requested_zone = network.get_pending_zone_request(peer_id)
		network.clear_pending_zone_request(peer_id)

	print("[ServerRoot] Player %d requested zone type: %s" % [peer_id, requested_zone])

	# Use ZoneManager's generic get_or_create_zone for any zone type
	var zone_id = zone_manager.get_or_create_zone(requested_zone)

	if not zone_id.is_empty():
		_assign_player_to_zone(peer_id, zone_id)

func _on_peer_disconnected(peer_id: int):
	print("[ServerRoot] Peer disconnected: %d" % peer_id)

	# ZoneManager handles removal
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if zone_manager:
		zone_manager.remove_player_from_zone(peer_id)

	# Remove from spawn queue
	spawn_queue.erase(peer_id)

func _on_player_joined_zone(peer_id: int, zone_id: String):
	print("[ServerRoot] === _on_player_joined_zone: peer=%d, zone=%s ===" % [peer_id, zone_id])

	# Tell client to load this zone
	_notify_client_zone_change(peer_id, zone_id)

	# Spawn player in zone
	print("[ServerRoot] About to call _spawn_player_in_zone")
	_spawn_player_in_zone(peer_id, zone_id)

func _on_player_left_zone(peer_id: int, zone_id: String):
	print("[ServerRoot] Player %d left zone %s" % [peer_id, zone_id])

	# Despawn player from zone
	_despawn_player_from_zone(peer_id, zone_id)

func _assign_player_to_zone(peer_id: int, zone_id: String):
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		return

	# Get current zone
	var old_zone = zone_manager.get_player_zone(peer_id)

	if old_zone == zone_id:
		return  # Already in this zone

	# ZoneManager handles the zone assignment
	zone_manager.add_player_to_zone(peer_id, zone_id)

	player_zone_changed.emit(peer_id, old_zone, zone_id)

func _notify_client_zone_change(peer_id: int, zone_id: String):
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager or not zone_manager.zones.has(zone_id):
		return

	var zone_data = zone_manager.zones[zone_id]
	var scene_path = zone_data.scene_path

	# Use NetworkManager to notify client (RPC is defined there, available on both server and client)
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("notify_client_zone_change"):
		network.notify_client_zone_change(peer_id, zone_id, scene_path)

func _spawn_player_in_zone(peer_id: int, zone_id: String):
	print("[ServerRoot] _spawn_player_in_zone called: peer=%d, zone=%s" % [peer_id, zone_id])
	print("[ServerRoot] loaded_zones keys: %s" % [loaded_zones.keys()])

	if not loaded_zones.has(zone_id):
		spawn_queue[peer_id] = zone_id
		print("[ServerRoot] Zone %s NOT in loaded_zones, queuing spawn" % zone_id)
		return

	var zone_node = loaded_zones[zone_id]
	print("[ServerRoot] zone_node: %s" % zone_node)

	var mp_scene = _find_multiplayer_scene(zone_node)
	print("[ServerRoot] mp_scene found: %s" % mp_scene)

	if mp_scene:
		print("[ServerRoot] Calling mp_scene.spawn_player(%d)" % peer_id)
		mp_scene.spawn_player(peer_id)
		print("[ServerRoot] spawn_player returned")
	else:
		push_error("[ServerRoot] NO MultiplayerScene in zone %s!" % zone_id)

func _find_multiplayer_scene(zone_node: Node) -> Node:
	## Find the MultiplayerScene in a zone (could be the zone itself or a child)
	if zone_node.is_in_group("multiplayer_scene"):
		return zone_node
	for child in zone_node.get_children():
		if child.is_in_group("multiplayer_scene"):
			return child
	return null

func _despawn_player_from_zone(peer_id: int, zone_id: String):
	# Find MultiplayerScene and despawn via it
	if loaded_zones.has(zone_id):
		var zone_node = loaded_zones[zone_id]
		var mp_scene = _find_multiplayer_scene(zone_node)
		if mp_scene and mp_scene.has_method("despawn_player"):
			mp_scene.despawn_player(peer_id)

func _process_spawn_queue(zone_id: String):
	var to_spawn = []
	for peer_id in spawn_queue:
		if spawn_queue[peer_id] == zone_id:
			to_spawn.append(peer_id)

	for peer_id in to_spawn:
		spawn_queue.erase(peer_id)
		_spawn_player_in_zone(peer_id, zone_id)

## Public API

func get_zone_node(zone_id: String) -> Node:
	return loaded_zones.get(zone_id, null)

func get_player_zone_node(peer_id: int) -> Node:
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		return null

	var zone_id = zone_manager.get_player_zone(peer_id)
	return loaded_zones.get(zone_id, null)

func get_entity_zone_id(entity: Node) -> String:
	## Get the zone ID for an entity by walking up the tree
	var node = entity
	while node:
		if node.has_meta("zone_id"):
			return node.get_meta("zone_id")
		node = node.get_parent()
	return ""

func get_peers_in_zone(zone_id: String) -> Array[int]:
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if zone_manager:
		return zone_manager.get_zone_players(zone_id)
	return []

func transition_player_to_zone(peer_id: int, target_zone_id: String) -> bool:
	## Transition a player to a different zone
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		return false

	# Ensure zone is loaded
	if not loaded_zones.has(target_zone_id):
		_load_zone_scene(target_zone_id)

	_assign_player_to_zone(peer_id, target_zone_id)
	return true
