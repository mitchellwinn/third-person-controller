extends Node3D
class_name MultiplayerScene

## MultiplayerScene - Base class for all multiplayer scenes (hub, test maps, missions)
## Handles common functionality like player spawning and network management

signal player_spawned(player: Node)
signal player_despawned(peer_id: int)

@export var player_scene: PackedScene
@export var spawn_points_path: NodePath = "SpawnPoints"

## Zone action permissions - what players can do in this scene
@export_group("Zone Permissions")
@export var allow_combat: bool = true
@export var allow_jumping: bool = true
@export var allow_dodging: bool = true
@export var allow_sprinting: bool = true
@export var allow_pvp: bool = false  # Player vs player damage

var spawn_points: Array[Node3D] = []
var players: Dictionary = {}  # peer_id -> player node
var spawn_index: int = 0

func _ready():
	# Add to group for network manager lookup
	add_to_group("multiplayer_scene")
	
	# Clear any stale player data from previous sessions
	players.clear()
	spawn_index = 0
	
	# Collect spawn points
	var spawn_container = get_node_or_null(spawn_points_path)
	if spawn_container:
		for child in spawn_container.get_children():
			if child is Marker3D or child is Node3D:
				spawn_points.append(child)

	# Connect to network manager for player spawning
	if has_node("/root/NetworkManager"):
		var network = get_node("/root/NetworkManager")
		if not network.peer_connected.is_connected(_on_peer_connected):
			network.peer_connected.connect(_on_peer_connected)
		if not network.peer_disconnected.is_connected(_on_peer_disconnected):
			network.peer_disconnected.connect(_on_peer_disconnected)

		# Spawn existing players - deferred to avoid "busy adding children" error
		call_deferred("_spawn_existing_players")

	print("[MultiplayerScene] Initialized with ", spawn_points.size(), " spawn points")

func _spawn_existing_players():
	var network = get_node_or_null("/root/NetworkManager")

	if not network:
		# No network manager - spawn local player with ID 1
		print("[MultiplayerScene] No NetworkManager - spawning local player")
		_spawn_player_for_peer(1)
		return

	# Check if this is a dedicated (headless) server
	var is_dedicated_server = network.is_server and DisplayServer.get_name() == "headless"

	# Spawn players for all connected peers IN THIS ZONE
	for peer_id in network.connected_peers:
		# Don't spawn for peer 1 (server) - dedicated servers don't have players
		if peer_id == 1 and is_dedicated_server:
			continue
		# Don't spawn for peer 1 on clients (that's the dedicated server, not a player)
		if peer_id == 1 and not network.is_server:
			continue
		# Only spawn if player is in this zone
		if _is_player_in_my_zone(peer_id):
			_spawn_player_for_peer(peer_id)

	# If hosting as listen server (not dedicated) and no peers yet, spawn the host player
	if network.is_server and not is_dedicated_server and network.connected_peers.is_empty():
		_spawn_player_for_peer(1)
		print("[MultiplayerScene] Spawned host player (listen server mode)")

func _get_my_zone_id() -> String:
	## Walk up tree to find zone_id meta (set by ServerRoot when loading zones)
	var node = self
	while node:
		if node.has_meta("zone_id"):
			return node.get_meta("zone_id")
		node = node.get_parent()
	return ""

func _is_player_in_my_zone(peer_id: int) -> bool:
	## Check if a player is assigned to this zone (server only check)
	var network = get_node_or_null("/root/NetworkManager")

	# Clients don't have zone assignment data - allow all spawns
	# The server controls which zone scene the client loads
	if network and not network.is_server:
		return true

	var my_zone = _get_my_zone_id()
	if my_zone.is_empty():
		# No zone system - allow all spawns (backward compatibility)
		return true

	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		return true

	var player_zone = zone_manager.get_player_zone(peer_id)
	return player_zone == my_zone

#region Player Management
func spawn_player(peer_id: int, player_node: Node = null) -> Node:
	# Get spawn position
	var spawn_pos = _get_next_spawn_position()
	print("[MultiplayerScene] Spawn point node: %s, global_position: %s" % [spawn_pos.name if spawn_pos else "NULL", spawn_pos.global_position if spawn_pos else "N/A"])

	# Create player if not provided
	if not player_node:
		if player_scene:
			player_node = player_scene.instantiate()
		else:
			push_error("[MultiplayerScene] No player scene configured")
			return null

	# CRITICAL: Set consistent name BEFORE adding to scene for RPC path matching
	player_node.name = "Player_%d" % peer_id

	# Set up network identity BEFORE adding to scene (so _ready() sees correct values)
	if player_node.has_node("NetworkIdentity"):
		var network_id = player_node.get_node("NetworkIdentity")
		network_id.network_id = peer_id
		network_id.owner_peer_id = peer_id
	
	# Set character/steam ID from NetworkManager player data (for inventory queries)
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.connected_peers.has(peer_id):
		var player_data = network.connected_peers[peer_id]
		if "steam_id" in player_node:
			player_node.steam_id = player_data.steam_id if "steam_id" in player_data else 0
		if "character_id" in player_node:
			player_node.character_id = player_data.character_id if "character_id" in player_data else 0
		print("[MultiplayerScene] Set player %d identity: steam=%d, char=%d" % [
			peer_id, 
			player_node.steam_id if "steam_id" in player_node else 0, 
			player_node.character_id if "character_id" in player_node else 0
		])

	# Add to scene FIRST (this triggers _ready())
	add_child(player_node)
	players[peer_id] = player_node

	# Position player AFTER adding to tree (global_position only works when in tree)
	player_node.global_position = spawn_pos.global_position
	if spawn_pos.has_method("get_spawn_rotation"):
		player_node.rotation = spawn_pos.get_spawn_rotation()

	print("[MultiplayerScene] Player %d spawned at: %s (spawn point: %s)" % [peer_id, player_node.global_position, spawn_pos.global_position])
	
	# Add to players group for network lookup
	player_node.add_to_group("players")

	# Notify network manager (reuse network variable from earlier)
	if network:
		network.set_player_entity(peer_id, player_node)

	player_spawned.emit(player_node)
	return player_node

func despawn_player(peer_id: int):
	if players.has(peer_id):
		var player = players[peer_id]
		players.erase(peer_id)
		if is_instance_valid(player):
			# Save equipment state before destroying player
			_save_player_equipment_state(player)
			player.queue_free()
		player_despawned.emit(peer_id)

func _save_player_equipment_state(player: Node):
	## Save weapon ammo/state to database before player despawns
	var equipment_manager = player.get_node_or_null("EquipmentManager")
	if equipment_manager and equipment_manager.has_method("save_all_weapon_states"):
		equipment_manager.save_all_weapon_states()
		print("[MultiplayerScene] Saved equipment state for player")

func _on_peer_disconnected(peer_id: int):
	# Defer to avoid removing while scene is busy
	call_deferred("despawn_player", peer_id)

func get_player(peer_id: int) -> Node:
	return players.get(peer_id, null)

func get_all_players() -> Array:
	var player_list = []
	for player in players.values():
		if is_instance_valid(player):
			player_list.append(player)
	return player_list

func _get_next_spawn_position() -> Node3D:
	if spawn_points.size() == 0:
		# Fallback to scene origin
		var marker = Marker3D.new()
		marker.global_position = Vector3.ZERO
		return marker

	var spawn = spawn_points[spawn_index % spawn_points.size()]
	spawn_index += 1
	return spawn

func _on_peer_connected(peer_id: int, _player_data: Dictionary):
	var network = get_node_or_null("/root/NetworkManager")

	# Don't spawn for peer 1 on clients (that's the dedicated server, not a player)
	if peer_id == 1 and network and not network.is_server:
		print("[MultiplayerScene] Skipping spawn for server peer (client side)")
		return

	# Don't spawn for peer 1 on dedicated server (server doesn't need a player)
	var is_dedicated_server = network and network.is_server and DisplayServer.get_name() == "headless"
	if peer_id == 1 and is_dedicated_server:
		print("[MultiplayerScene] Skipping spawn for server peer (dedicated server)")
		return

	# Zone filtering: only spawn if player is in this zone
	if not _is_player_in_my_zone(peer_id):
		return

	# Defer spawning to avoid "busy adding children" error
	call_deferred("_spawn_player_for_peer", peer_id)

func _spawn_player_for_peer(peer_id: int):
	if players.has(peer_id):
		return  # Already spawned

	var player = spawn_player(peer_id)
	if player:
		# Set display name from NetworkManager
		_set_player_display_name(player, peer_id)
		
		# Allow subclasses to configure the player (e.g., disable combat in hub)
		_on_player_spawned_in_zone(player)
	print("[MultiplayerScene] Spawned player for peer: ", peer_id)

func _set_player_display_name(player: Node, peer_id: int):
	## Set the player's display name from NetworkManager or Steam
	var network = get_node_or_null("/root/NetworkManager")
	var display_name = ""
	
	if network and network.connected_peers.has(peer_id):
		var player_data = network.connected_peers[peer_id]
		display_name = player_data.display_name
	
	# Fallback to SteamManager for local player
	if display_name.is_empty() and _is_local_player(player):
		var steam_manager = get_node_or_null("/root/SteamManager")
		if steam_manager and steam_manager.has_method("get_persona_name"):
			display_name = steam_manager.get_persona_name()
	
	# Last fallback
	if display_name.is_empty():
		display_name = "Player_%d" % peer_id
	
	# Set on entity
	if "display_name" in player:
		player.display_name = display_name
	
	# Update nametag
	var nametag = player.get_node_or_null("Nametag")
	if nametag and nametag.has_method("set_nametag_text"):
		nametag.set_nametag_text(display_name)

# Override in subclasses to configure spawned players
func _on_player_spawned_in_zone(player: Node):
	# Apply zone permissions to the spawned player
	_apply_zone_permissions(player)
	
	# Equip weapons (server-authoritative)
	_equip_starting_weapons(player)

func _equip_starting_weapons(player: Node):
	## Load player's equipment - SERVER ONLY
	## Clients receive equipment via RPC from NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	
	# Check if this is the local player on a client
	var is_client = network and not network.is_server
	var is_local_player = _is_local_player(player)
	
	if is_client:
		if is_local_player:
			# Client's local player - equipment comes from server via RPC
			print("[MultiplayerScene] Client: waiting for equipment from server for local player")
			# Check if there's pending equipment from server
			if network.has_method("check_pending_equipment"):
				network.check_pending_equipment(player)
		else:
			# Remote player on client - check if we have pending equipment for them
			print("[MultiplayerScene] Client: checking pending equipment for remote player ", player.name)
			var peer_id = _get_peer_id_for_player(player)
			if network.has_method("check_pending_remote_equipment") and peer_id > 0:
				network.check_pending_remote_equipment(peer_id, player)
		return
	
	# SERVER PATH: Equipment is handled by NetworkManager after player registration
	# Don't equip here - wait for character_id to be available
	var character_id = _get_character_id_for_player(player)
	if character_id <= 0:
		# Character not registered yet - NetworkManager will handle equipment after registration
		print("[MultiplayerScene] Server: Waiting for character registration before equipping weapons")
		return
	
	# If character IS registered, load from database
	var equipment_manager = player.get_node_or_null("EquipmentManager")
	if not equipment_manager:
		print("[MultiplayerScene] ERROR: No EquipmentManager on player!")
		return
	
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db or not item_db.is_server_instance:
		print("[MultiplayerScene] ERROR: ItemDatabase not available on server!")
		return
	
	# Load equipped items from database
	var equipped = item_db.get_equipped_items(character_id)
	
	if equipped.is_empty():
		print("[MultiplayerScene] No equipment in DB for character %d - NetworkManager will handle" % character_id)
		return
	
	# Equip each item from database
	for slot_name in equipped:
		var slot_data = equipped[slot_name]
		var item_id = slot_data.get("item_id", "")
		
		if item_id.is_empty():
			continue
		
		# Get full weapon data
		var weapon_data = item_db.get_full_weapon_data(item_id)
		if not weapon_data.is_empty():
			equipment_manager.equip_weapon(slot_name, weapon_data)
	
	print("[MultiplayerScene] Loaded equipment from database for character ", character_id)

func _is_local_player(player: Node) -> bool:
	## Check if this player is the local player
	var network = get_node_or_null("/root/NetworkManager")
	if not network:
		return true  # No network = single player = always local
	
	# Find peer ID for this player
	for pid in players:
		if players[pid] == player:
			return pid == network.local_peer_id or (network.is_server and pid == 1)
	
	return false

func _get_peer_id_for_player(player: Node) -> int:
	## Get the peer ID for this player
	for pid in players:
		if players[pid] == player:
			return pid
	return 0

func _get_character_id_for_player(player: Node) -> int:
	## Get the character ID for this player from NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	if not network:
		return 0
	
	# Find peer ID for this player
	var peer_id = 0
	for pid in players:
		if players[pid] == player:
			peer_id = pid
			break
	
	if peer_id <= 0:
		return 0
	
	# Get player data from network manager
	if network.connected_peers.has(peer_id):
		var player_data = network.connected_peers[peer_id]
		# PlayerData is a class, access character_id property directly
		if "character_id" in player_data:
			return player_data.character_id
	
	return 0

func _apply_zone_permissions(player: Node):
	## Apply this zone's permissions to a player entity
	if player.has_method("set_zone_permissions"):
		player.set_zone_permissions({
			"combat": allow_combat,
			"jumping": allow_jumping,
			"dodging": allow_dodging,
			"sprinting": allow_sprinting,
			"pvp": allow_pvp
		})
	
	# Legacy support for set_combat_enabled
	if player.has_method("set_combat_enabled"):
		player.set_combat_enabled(allow_combat)

func get_zone_permissions() -> Dictionary:
	## Returns the current zone's permission settings
	return {
		"combat": allow_combat,
		"jumping": allow_jumping,
		"dodging": allow_dodging,
		"sprinting": allow_sprinting,
		"pvp": allow_pvp
	}
#endregion
