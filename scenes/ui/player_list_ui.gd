extends Control
class_name PlayerListUI

## PlayerListUI - Shows all players in the server, their ping, and squad controls
## Opens with ESC key, similar rules to inventory for mouse capture

signal closed()
signal player_invited(peer_id: int)
signal player_kicked(peer_id: int)
signal invite_accepted(from_peer_id: int)
signal squad_left()

#region Node References
@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/VBox/TitleBar/TitleLabel
@onready var close_button: Button = $Panel/VBox/TitleBar/CloseButton
@onready var player_container: VBoxContainer = $Panel/VBox/ScrollContainer/PlayerContainer
@onready var squad_info_label: Label = $Panel/VBox/SquadInfo
@onready var leave_squad_button: Button = $Panel/VBox/LeaveSquadButton
#endregion

#region Configuration
@export var row_scene: PackedScene
#endregion

#region State
var _player_rows: Dictionary = {}  # peer_id -> row node
var _network_manager: Node = null
#endregion

func _ready():
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Add to group so state_talking knows we need mouse visible
	add_to_group("ui_needs_mouse")
	
	# Connect close button
	if close_button:
		close_button.pressed.connect(close)
	
	# Connect leave squad button
	if leave_squad_button:
		leave_squad_button.pressed.connect(_on_leave_squad_pressed)
	
	# Find NetworkManager
	_network_manager = get_node_or_null("/root/NetworkManager")
	if _network_manager:
		if _network_manager.has_signal("player_list_updated"):
			_network_manager.player_list_updated.connect(_refresh_player_list)
		if _network_manager.has_signal("squad_invite_received"):
			_network_manager.squad_invite_received.connect(_on_invite_received)

func _input(event: InputEvent):
	if not visible:
		return
	
	# Close on ESC
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func _gui_input(event: InputEvent):
	# Consume all mouse clicks on the panel
	if event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()

#region Public API
func open():
	## Open the player list
	visible = true
	_ensure_talking_state()
	_refresh_player_list()

func close():
	## Close the player list
	visible = false
	closed.emit()
	_exit_talking_state()

func is_open() -> bool:
	return visible

func toggle():
	if visible:
		close()
	else:
		open()

func _ensure_talking_state():
	## Enter talking state to show mouse cursor
	var player = _get_local_player()
	if not player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	
	var state_manager = player.get_node_or_null("StateManager")
	if not state_manager:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	
	if state_manager.has_method("get_current_state_name"):
		if state_manager.get_current_state_name() == "talking":
			return
	
	if state_manager.has_method("change_state") and state_manager.has_method("has_state"):
		if state_manager.has_state("talking"):
			state_manager.change_state("talking", true)
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _exit_talking_state():
	## Exit talking state - it will check if other UIs still need mouse
	var player = _get_local_player()
	if not player:
		return
	
	var state_manager = player.get_node_or_null("StateManager")
	if not state_manager:
		return
	
	if state_manager.has_method("get_current_state_name"):
		if state_manager.get_current_state_name() != "talking":
			return
	
	if state_manager.has_method("change_state") and state_manager.has_method("has_state"):
		if state_manager.has_state("idle"):
			state_manager.change_state("idle", true)

func _get_local_player() -> Node:
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if "can_receive_input" in player and player.can_receive_input:
			return player
	return null
#endregion

#region Display
func _refresh_player_list():
	if not _network_manager:
		return
	
	# Get player info
	var players: Array
	if _network_manager.has_method("get_cached_players_info"):
		players = _network_manager.get_cached_players_info()
	elif _network_manager.has_method("get_all_players_info"):
		players = _network_manager.get_all_players_info()
	else:
		return
	
	# Get my info
	var my_peer_id = _network_manager.get_local_peer_id()
	var my_squad_id = -1
	var am_leader = false
	
	if _network_manager.has_method("am_i_squad_leader"):
		am_leader = _network_manager.am_i_squad_leader()
	
	# Get pending invites
	var pending_invites = []
	if _network_manager.has_method("get_pending_invites"):
		pending_invites = _network_manager.get_pending_invites()
	
	# Find my squad
	for p in players:
		if p.peer_id == my_peer_id:
			my_squad_id = p.squad_id
			break
	
	# Update squad info label
	if squad_info_label:
		var squad_members = []
		for p in players:
			if p.squad_id == my_squad_id:
				var pname = p.display_name if p.display_name else "Player_%d" % p.peer_id
				squad_members.append(pname)
		
		if squad_members.size() <= 1:
			squad_info_label.text = "Squad: Solo"
		else:
			squad_info_label.text = "Squad: %s (%d members)" % [
				"You are leader" if am_leader else "Member",
				squad_members.size()
			]
	
	# Update leave squad button
	if leave_squad_button:
		var my_squad_members = []
		if _network_manager.has_method("get_my_squad_members"):
			my_squad_members = _network_manager.get_my_squad_members()
		leave_squad_button.visible = my_squad_members.size() > 1
		leave_squad_button.text = "Leave Squad" if not am_leader else "Disband Squad"
	
	# Clear old rows
	for row in _player_rows.values():
		row.queue_free()
	_player_rows.clear()
	
	# Sort players: my squad first, then others
	players.sort_custom(func(a, b):
		var a_in_squad = a.squad_id == my_squad_id
		var b_in_squad = b.squad_id == my_squad_id
		if a_in_squad and not b_in_squad:
			return true
		if b_in_squad and not a_in_squad:
			return false
		var a_name = a.display_name if a.display_name else "Player_%d" % a.peer_id
		var b_name = b.display_name if b.display_name else "Player_%d" % b.peer_id
		return a_name < b_name
	)
	
	# Create rows
	for player in players:
		var row = _create_player_row(player, my_peer_id, my_squad_id, am_leader, pending_invites)
		player_container.add_child(row)
		_player_rows[player.peer_id] = row

func _create_player_row(player: Dictionary, my_peer_id: int, my_squad_id: int, am_leader: bool, pending_invites: Array) -> Control:
	var row = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var is_me = player.peer_id == my_peer_id
	var is_in_my_squad = player.squad_id == my_squad_id
	var has_invite_from_them = player.peer_id in pending_invites
	
	# Name label
	var name_label = Label.new()
	var display_text = player.display_name if player.display_name else "Player_%d" % player.peer_id
	name_label.text = display_text
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Color based on squad membership
	if is_me:
		name_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))  # Cyan for self
	elif is_in_my_squad:
		name_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))  # Green for squad
	else:
		name_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))  # White for others
	
	row.add_child(name_label)
	
	# Leader indicator
	if player.is_squad_leader and is_in_my_squad and not is_me:
		var leader_icon = Label.new()
		leader_icon.text = "★"
		leader_icon.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		row.add_child(leader_icon)
	
	# Ping label
	var ping_label = Label.new()
	ping_label.text = "%dms" % player.latency_ms
	ping_label.custom_minimum_size.x = 60
	ping_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	
	# Color ping based on value
	if player.latency_ms < 50:
		ping_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	elif player.latency_ms < 100:
		ping_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
	elif player.latency_ms < 200:
		ping_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
	else:
		ping_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	
	row.add_child(ping_label)
	
	# Action button (Invite / Accept / Kick)
	if not is_me:
		var action_btn = Button.new()
		action_btn.custom_minimum_size.x = 80
		
		if has_invite_from_them:
			# They invited us - show Accept button
			action_btn.text = "Accept"
			action_btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
			action_btn.pressed.connect(_on_accept_pressed.bind(player.peer_id))
		elif is_in_my_squad and am_leader:
			# We're leader and they're in our squad - show Kick button
			action_btn.text = "Kick"
			action_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			action_btn.pressed.connect(_on_kick_pressed.bind(player.peer_id))
		elif not is_in_my_squad:
			# Not in our squad - show Invite button
			action_btn.text = "Invite"
			action_btn.pressed.connect(_on_invite_pressed.bind(player.peer_id))
		else:
			# In our squad but we're not leader - no action
			action_btn.text = "—"
			action_btn.disabled = true
		
		row.add_child(action_btn)
	else:
		# Spacer for self row
		var spacer = Control.new()
		spacer.custom_minimum_size.x = 80
		row.add_child(spacer)
	
	return row
#endregion

#region Button Handlers
func _on_invite_pressed(peer_id: int):
	if _network_manager:
		# Try Steam invite first (sends both Steam and squad invite)
		if _network_manager.has_method("invite_player_via_steam"):
			var steam_id = _get_steam_id_for_peer(peer_id)
			if steam_id > 0:
				_network_manager.invite_player_via_steam(steam_id)
				player_invited.emit(peer_id)
				return
		# Fall back to regular squad invite
		if _network_manager.has_method("invite_to_squad"):
			_network_manager.invite_to_squad(peer_id)
			player_invited.emit(peer_id)

func _get_steam_id_for_peer(peer_id: int) -> int:
	if _network_manager and _network_manager.has_method("_get_steam_id_for_peer_id"):
		return _network_manager._get_steam_id_for_peer_id(peer_id)
	# Try to find it in cached player info
	for p in _network_manager.get_cached_players_info() if _network_manager else []:
		if p.peer_id == peer_id:
			return p.get("steam_id", 0)
	return 0

func _on_kick_pressed(peer_id: int):
	if _network_manager and _network_manager.has_method("kick_from_squad"):
		_network_manager.kick_from_squad(peer_id)
		player_kicked.emit(peer_id)

func _on_accept_pressed(from_peer_id: int):
	if _network_manager and _network_manager.has_method("accept_squad_invite"):
		_network_manager.accept_squad_invite(from_peer_id)
		invite_accepted.emit(from_peer_id)

func _on_leave_squad_pressed():
	if _network_manager and _network_manager.has_method("leave_squad"):
		_network_manager.leave_squad()
		squad_left.emit()

func _on_invite_received(from_peer_id: int, from_name: String):
	# Refresh to show the Accept button
	_refresh_player_list()
	print("[PlayerList] Received invite from: ", from_name)
#endregion

