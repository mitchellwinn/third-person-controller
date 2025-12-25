extends Node

## SquadManager - Handles squad formation, ready checks, and mission launching

signal squad_formed(leader_id: int, members: Array)
signal squad_disbanded()
signal member_joined(steam_id: int)
signal member_left(steam_id: int)
signal member_ready_changed(steam_id: int, is_ready: bool)
signal all_ready()
signal mission_launch_requested(mission_id: String)

#region Configuration
@export var max_squad_size: int = 4
@export var ready_check_timeout: float = 30.0
#endregion

#region State
var is_in_squad: bool = false
var is_squad_leader: bool = false
var squad_members: Array[int] = []  # Steam IDs
var member_ready_states: Dictionary = {}  # steam_id -> bool
var selected_mission: String = ""
var ready_check_active: bool = false
var ready_check_timer: float = 0.0
#endregion

func _ready():
	# Connect to Steam lobby signals
	if has_node("/root/SteamManager"):
		SteamManager.lobby_created.connect(_on_lobby_created)
		SteamManager.lobby_joined.connect(_on_lobby_joined)
		SteamManager.lobby_left.connect(_on_lobby_left)
		SteamManager.lobby_member_joined.connect(_on_lobby_member_joined)
		SteamManager.lobby_member_left.connect(_on_lobby_member_left)
		SteamManager.lobby_data_changed.connect(_on_lobby_data_changed)

func _process(delta: float):
	if ready_check_active:
		ready_check_timer -= delta
		if ready_check_timer <= 0:
			_cancel_ready_check()

#region Squad Creation
func create_squad() -> void:
	if is_in_squad:
		return
	
	SteamManager.create_lobby(SteamManager.LobbyType.FRIENDS_ONLY, max_squad_size)

func leave_squad() -> void:
	if not is_in_squad:
		return
	
	# Notify mission manager before leaving
	var was_leader = is_squad_leader
	var mission_manager = get_node_or_null("/root/MissionManager")
	if mission_manager and mission_manager.has_method("on_leave_squad"):
		mission_manager.on_leave_squad()
	
	SteamManager.leave_lobby()
	_reset_squad_state()
	squad_disbanded.emit()

func invite_player(steam_id: int) -> bool:
	if not is_in_squad or not is_squad_leader:
		return false
	
	return SteamManager.invite_to_lobby(steam_id)

func kick_member(steam_id: int) -> bool:
	if not is_squad_leader:
		return false
	
	if steam_id == SteamManager.get_steam_id():
		return false  # Can't kick yourself
	
	# Set lobby data to indicate kick
	SteamManager.set_lobby_data("kicked_" + str(steam_id), "1")
	return true

func _on_lobby_created(lobby_id: int, result: int):
	if result == Steam.RESULT_OK:
		is_in_squad = true
		is_squad_leader = true
		squad_members = [SteamManager.get_steam_id()]
		member_ready_states[SteamManager.get_steam_id()] = false
		
		# Set initial lobby data
		SteamManager.set_lobby_data("status", "forming")
		
		squad_formed.emit(SteamManager.get_steam_id(), squad_members)

func _on_lobby_joined(lobby_id: int, response: int):
	if response == Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		is_in_squad = true
		is_squad_leader = SteamManager.is_lobby_host()
		squad_members = SteamManager.get_lobby_members_list()
		
		for member_id in squad_members:
			member_ready_states[member_id] = false
		
		# Check if we were kicked
		var kicked = SteamManager.get_lobby_data("kicked_" + str(SteamManager.get_steam_id()))
		if kicked == "1":
			leave_squad()
			return
		
		# Get leader's deployment if joining an existing squad
		if not is_squad_leader:
			var leader_mission = SteamManager.get_lobby_data("current_mission")
			var leader_step = SteamManager.get_lobby_data("current_step")
			if not leader_mission.is_empty():
				var mission_manager = get_node_or_null("/root/MissionManager")
				if mission_manager and mission_manager.has_method("on_join_squad"):
					mission_manager.on_join_squad({
						"mission_id": leader_mission,
						"step_index": int(leader_step) if not leader_step.is_empty() else 0
					})
		
		squad_formed.emit(Steam.getLobbyOwner(lobby_id), squad_members)

func _on_lobby_left():
	_reset_squad_state()

func _on_lobby_member_joined(steam_id: int):
	if steam_id not in squad_members:
		squad_members.append(steam_id)
		member_ready_states[steam_id] = false
		member_joined.emit(steam_id)
		
		# Cancel ready check if active
		if ready_check_active:
			_cancel_ready_check()

func _on_lobby_member_left(steam_id: int):
	squad_members.erase(steam_id)
	member_ready_states.erase(steam_id)
	member_left.emit(steam_id)
	
	# Cancel ready check if active
	if ready_check_active:
		_cancel_ready_check()

func _on_lobby_data_changed(_lobby_id: int):
	# Check for mission selection
	var mission = SteamManager.get_lobby_data("selected_mission")
	if mission != selected_mission:
		selected_mission = mission
	
	# Check for ready check
	var ready_check = SteamManager.get_lobby_data("ready_check")
	if ready_check == "active" and not ready_check_active:
		_start_ready_check()
	elif ready_check != "active" and ready_check_active:
		ready_check_active = false

func _reset_squad_state():
	is_in_squad = false
	is_squad_leader = false
	squad_members.clear()
	member_ready_states.clear()
	selected_mission = ""
	ready_check_active = false
#endregion

#region Ready Check
func start_ready_check() -> bool:
	if not is_squad_leader or squad_members.size() < 2:
		return false
	
	SteamManager.set_lobby_data("ready_check", "active")
	_start_ready_check()
	return true

func _start_ready_check():
	ready_check_active = true
	ready_check_timer = ready_check_timeout
	
	# Reset all ready states
	for member_id in member_ready_states:
		member_ready_states[member_id] = false
	
	# Leader is auto-ready
	set_ready(true)

func _cancel_ready_check():
	ready_check_active = false
	SteamManager.set_lobby_data("ready_check", "")
	
	for member_id in member_ready_states:
		member_ready_states[member_id] = false

func set_ready(is_ready: bool):
	var my_id = SteamManager.get_steam_id()
	member_ready_states[my_id] = is_ready
	
	# Broadcast to lobby
	SteamManager.set_lobby_member_data("ready", "1" if is_ready else "0")
	
	member_ready_changed.emit(my_id, is_ready)
	
	_check_all_ready()

func _check_all_ready():
	if not ready_check_active:
		return
	
	for member_id in squad_members:
		if not member_ready_states.get(member_id, false):
			return
	
	# Everyone is ready!
	ready_check_active = false
	all_ready.emit()
	
	# Leader launches mission
	if is_squad_leader:
		_launch_mission()

func is_member_ready(steam_id: int) -> bool:
	return member_ready_states.get(steam_id, false)
#endregion

#region Mission Selection
func select_mission(mission_id: String) -> bool:
	if not is_squad_leader:
		return false
	
	selected_mission = mission_id
	SteamManager.set_lobby_data("selected_mission", mission_id)
	
	# Also update current deployment for HUD sync
	SteamManager.set_lobby_data("current_mission", mission_id)
	SteamManager.set_lobby_data("current_step", "0")
	
	return true

func sync_deployment(mission_id: String, step_index: int) -> bool:
	## Sync deployment state to squad (leader only)
	if not is_squad_leader:
		return false
	
	SteamManager.set_lobby_data("current_mission", mission_id)
	SteamManager.set_lobby_data("current_step", str(step_index))
	return true

func clear_deployment() -> bool:
	## Clear deployment (leader only, or when leaving squad)
	if is_squad_leader:
		SteamManager.set_lobby_data("current_mission", "")
		SteamManager.set_lobby_data("current_step", "")
	return true

func get_selected_mission() -> String:
	return selected_mission

func launch_mission() -> bool:
	if not is_squad_leader:
		return false
	
	if selected_mission.is_empty():
		return false
	
	# Start ready check
	return start_ready_check()

func _launch_mission():
	if selected_mission.is_empty():
		return
	
	mission_launch_requested.emit(selected_mission)
	
	# Update lobby status
	SteamManager.set_lobby_data("status", "in_mission")
	SteamManager.set_lobby_joinable(false)
	
	# Rich presence
	SteamManager.set_in_mission(selected_mission)
#endregion

#region Utility
func get_squad_size() -> int:
	return squad_members.size()

func is_squad_full() -> bool:
	return squad_members.size() >= max_squad_size

func get_member_name(steam_id: int) -> String:
	return SteamManager.get_player_name(steam_id)

func get_squad_info() -> Dictionary:
	return {
		"is_in_squad": is_in_squad,
		"is_leader": is_squad_leader,
		"members": squad_members,
		"size": squad_members.size(),
		"max_size": max_squad_size,
		"selected_mission": selected_mission,
		"ready_states": member_ready_states.duplicate()
	}
#endregion

