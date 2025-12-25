extends Node3D
class_name ExtractionBeacon

## Extraction Beacon - Allows players to signal the station and beam back up
## Server-authoritative state machine with synced state to clients

enum BeaconState {
	IDLE,       ## Ready to initiate signal
	SIGNALING,  ## Contacting station (not interactable)
	READY       ## Extraction window open
}

signal state_changed(new_state: BeaconState)
signal player_extracted(player: Node)

#region Exports
@export_group("Timing")
@export var signal_duration: float = 10.0  ## How long to establish connection
@export var ready_window: float = 30.0     ## How long extraction stays available

@export_group("Interaction")
@export var interaction_radius: float = 3.0
@export var interaction_prompt_idle: String = "Press E to signal station"
@export var interaction_prompt_ready: String = "Press E to extract"

@export_group("Dialogue")
@export var dialogue_tree_idle: String = "extraction_beacon_idle"
@export var dialogue_tree_ready: String = "extraction_beacon_ready"
#endregion

#region State
var current_state: BeaconState = BeaconState.IDLE
var _signal_timer: float = 0.0
var _ready_timer: float = 0.0
var _signaling_player_peer_id: int = 0  ## Who initiated the signal

## Nearby players for interaction
var nearby_players: Array[Node] = []
#endregion

#region Node References
@onready var interaction_area: Area3D = $InteractionArea
@onready var mesh_root: Node3D = $MeshRoot if has_node("MeshRoot") else null
#endregion

func _ready():
	# Setup interaction area
	if interaction_area:
		interaction_area.body_entered.connect(_on_body_entered)
		interaction_area.body_exited.connect(_on_body_exited)

	add_to_group("extraction_beacons")
	add_to_group("interactable")

func _physics_process(delta: float):
	# Update interaction prompts for nearby players (runs on all clients)
	_update_nearby_player_prompts()

	# State machine only runs on server
	if not _is_server():
		return

	match current_state:
		BeaconState.SIGNALING:
			_signal_timer += delta
			if _signal_timer >= signal_duration:
				_enter_ready_state()

		BeaconState.READY:
			_ready_timer += delta
			if _ready_timer >= ready_window:
				_enter_idle_state()

func _update_nearby_player_prompts():
	## Show/hide interaction prompt for nearby players (same pattern as ActionNPC)
	for player in nearby_players:
		if not is_instance_valid(player):
			continue

		var dist = global_position.distance_to(player.global_position)
		var should_show = dist <= interaction_radius and can_interact()

		if should_show:
			if player.has_method("show_interaction_prompt"):
				# Only show if this is the nearest interactable
				var nearest = _get_player_nearest_interactable(player)
				if nearest == self:
					player.show_interaction_prompt(get_interaction_prompt(), self)
		else:
			if player.has_method("hide_interaction_prompt"):
				if player.has_method("get_prompt_target") and player.get_prompt_target() == self:
					player.hide_interaction_prompt()

func _get_player_nearest_interactable(player: Node) -> Node:
	## Find nearest interactable to player (same pattern as ActionNPC)
	var nearest: Node = null
	var nearest_dist: float = INF

	for interactable in player.get_tree().get_nodes_in_group("interactable"):
		if not is_instance_valid(interactable):
			continue
		if interactable.has_method("can_interact") and not interactable.can_interact():
			continue

		var idist = player.global_position.distance_to(interactable.global_position)
		if idist < nearest_dist:
			nearest_dist = idist
			nearest = interactable

	return nearest

#region State Machine
func _enter_idle_state():
	current_state = BeaconState.IDLE
	_signal_timer = 0.0
	_ready_timer = 0.0
	_signaling_player_peer_id = 0
	state_changed.emit(BeaconState.IDLE)
	_sync_state_to_clients()
	print("[ExtractionBeacon] Entered IDLE state")

func _enter_signaling_state(initiator_peer_id: int):
	current_state = BeaconState.SIGNALING
	_signal_timer = 0.0
	_signaling_player_peer_id = initiator_peer_id
	state_changed.emit(BeaconState.SIGNALING)
	_sync_state_to_clients()
	print("[ExtractionBeacon] Entered SIGNALING state (initiated by peer %d)" % initiator_peer_id)

func _enter_ready_state():
	current_state = BeaconState.READY
	_ready_timer = 0.0
	state_changed.emit(BeaconState.READY)
	_sync_state_to_clients()
	print("[ExtractionBeacon] Entered READY state - extraction window open for %.1fs" % ready_window)
#endregion

#region Interaction
func can_interact() -> bool:
	return current_state != BeaconState.SIGNALING

func get_interaction_prompt() -> String:
	match current_state:
		BeaconState.IDLE:
			return interaction_prompt_idle
		BeaconState.READY:
			return interaction_prompt_ready
		_:
			return ""

func get_dialogue_tree_id() -> String:
	match current_state:
		BeaconState.IDLE:
			return dialogue_tree_idle
		BeaconState.READY:
			return dialogue_tree_ready
		_:
			return ""

func start_interaction(player: Node):
	## Called when player interacts - routes to appropriate action
	if not can_interact():
		return

	# Start dialogue via NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("request_dialogue"):
		network.request_dialogue(get_dialogue_tree_id())
#endregion

#region Dialogue Event Handlers
func handle_dialogue_event(event: Dictionary, player: Node) -> bool:
	## Handle events from dialogue choices
	var event_type = event.get("type", "")

	match event_type:
		"start_signal":
			_handle_start_signal(player)
			return true
		"confirm_extraction":
			_handle_extraction(player)
			return true
		_:
			return false

func _handle_start_signal(player: Node):
	## Player initiated signal to station
	if current_state != BeaconState.IDLE:
		return

	var peer_id = _get_player_peer_id(player)
	if peer_id <= 0:
		return

	_enter_signaling_state(peer_id)

func _handle_extraction(player: Node):
	## Player confirmed extraction
	if current_state != BeaconState.READY:
		return

	var peer_id = _get_player_peer_id(player)
	if peer_id <= 0:
		return

	print("[ExtractionBeacon] Extracting player peer %d" % peer_id)
	player_extracted.emit(player)

	# Trigger zone transfer back to hub
	var pioneer = get_node_or_null("/root/PioneerEventManager")
	if pioneer and pioneer.has_method("ascend_to_station"):
		pioneer.ascend_to_station(player)
	else:
		# Fallback: direct zone manager call
		_transfer_to_hub(peer_id)

func _transfer_to_hub(peer_id: int):
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		return

	# Find or create hub zone
	var hub_zone_id = ""
	if zone_manager.has_method("get_or_create_zone"):
		hub_zone_id = zone_manager.get_or_create_zone("hub", "res://scenes/hub/hub.tscn")

	if hub_zone_id.is_empty():
		push_warning("[ExtractionBeacon] Could not get hub zone")
		return

	# Transfer player
	if zone_manager.has_method("request_transfer"):
		zone_manager.request_transfer(peer_id, hub_zone_id)
		if zone_manager.has_method("complete_transfer"):
			zone_manager.complete_transfer(peer_id)
#endregion

#region Interaction Detection
func _on_body_entered(body: Node):
	if body.is_in_group("players"):
		if body not in nearby_players:
			nearby_players.append(body)

func _on_body_exited(body: Node):
	if body in nearby_players:
		nearby_players.erase(body)
		# Hide prompt when player leaves
		if body.has_method("hide_interaction_prompt"):
			if body.has_method("get_prompt_target") and body.get_prompt_target() == self:
				body.hide_interaction_prompt()
#endregion

#region Networking
func _is_server() -> bool:
	var network = get_node_or_null("/root/NetworkManager")
	if network and "is_server" in network:
		return network.is_server
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()

func _sync_state_to_clients():
	## Sync beacon state to all clients
	if not _is_server():
		return

	# Use RPC to sync state
	_rpc_sync_state.rpc(current_state, _ready_timer, ready_window - _ready_timer)

@rpc("authority", "call_remote", "reliable")
func _rpc_sync_state(state: int, timer: float, time_remaining: float):
	if _is_server():
		return

	current_state = state as BeaconState
	_ready_timer = timer
	state_changed.emit(current_state)

func _get_player_peer_id(player: Node) -> int:
	if "peer_id" in player:
		return player.peer_id

	var net_id = player.get_node_or_null("NetworkIdentity")
	if net_id and "peer_id" in net_id:
		return net_id.peer_id

	# Ask NetworkManager to look up entity
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("get_peer_for_entity"):
		return network.get_peer_for_entity(player)

	return 0
#endregion

#region Query
func get_state() -> BeaconState:
	return current_state

func get_time_remaining() -> float:
	if current_state == BeaconState.READY:
		return ready_window - _ready_timer
	elif current_state == BeaconState.SIGNALING:
		return signal_duration - _signal_timer
	return 0.0

func is_extraction_available() -> bool:
	return current_state == BeaconState.READY
#endregion
