extends Control

## Title Menu - Main menu with Steam status and navigation options
## Also handles command line args for server/client mode

signal go_to_hub_pressed()
signal go_to_test_pressed()

@onready var steam_status_label: Label = $VBoxContainer/SteamStatus
@onready var steam_name_label: Label = $VBoxContainer/SteamName
@onready var connection_status_label: Label = $VBoxContainer/ConnectionStatus
@onready var hub_button: Button = $VBoxContainer/ButtonContainer/HubButton
@onready var test_button: Button = $VBoxContainer/ButtonContainer/TestButton
@onready var reset_data_button: Button = $VBoxContainer/ButtonContainer/ResetDataButton
@onready var quit_button: Button = $VBoxContainer/ButtonContainer/QuitButton

# Command line state
var is_server: bool = false
var is_dedicated: bool = false
var server_port: int = 7777
var server_ip: String = "127.0.0.1"
var max_players: int = 32

# Connection state
var is_connecting: bool = false
var current_server_index: int = 0
var connection_timer: Timer
var pending_scene: String = ""

# Server list - try localhost first, then public IP
const SERVER_LIST: Array = [
	"127.0.0.1",
	"47.152.116.196"  # Your public IP - update when it changes
]
const CONNECTION_TIMEOUT: float = 3.0

func _ready():
	_parse_command_line()
	
	# If headless/dedicated server, skip menu and go directly to test map
	if is_dedicated:
		_start_dedicated_server()
		return
	
	_update_steam_status()
	_setup_connection_timer()
	
	hub_button.pressed.connect(_on_hub_pressed)
	test_button.pressed.connect(_on_test_pressed)
	reset_data_button.pressed.connect(_on_reset_data_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	
	# Connect to Steam signals if available
	if SteamManager:
		if not SteamManager.steam_initialized.is_connected(_on_steam_initialized):
			SteamManager.steam_initialized.connect(_on_steam_initialized)
	
	# Connect to network signals
	if NetworkManager:
		if not NetworkManager.connected_to_server.is_connected(_on_connected_to_server):
			NetworkManager.connected_to_server.connect(_on_connected_to_server)
		if not NetworkManager.connection_failed.is_connected(_on_connection_failed):
			NetworkManager.connection_failed.connect(_on_connection_failed)
	
	_update_connection_status("Not connected")

func _setup_connection_timer():
	connection_timer = Timer.new()
	connection_timer.one_shot = true
	connection_timer.timeout.connect(_on_connection_timeout)
	add_child(connection_timer)

func _parse_command_line():
	var args = OS.get_cmdline_args()
	
	var i = 0
	while i < args.size():
		var arg = args[i]
		
		match arg:
			"--server":
				is_server = true
			"--port":
				if i + 1 < args.size():
					server_port = int(args[i + 1])
					i += 1
			"--ip":
				if i + 1 < args.size():
					server_ip = args[i + 1]
					i += 1
			"--max-players":
				if i + 1 < args.size():
					max_players = int(args[i + 1])
					i += 1
		
		i += 1
	
	# Auto-detect headless as dedicated server
	if DisplayServer.get_name() == "headless":
		is_dedicated = true
		is_server = true

func _start_dedicated_server():
	print("[Server] Starting dedicated server on port ", server_port)
	print("[Server] Max players: ", max_players)
	print("[Server] Public IP: ", SERVER_LIST[1] if SERVER_LIST.size() > 1 else "N/A")

	# Start network server
	if NetworkManager:
		NetworkManager.start_server(server_port)

	# Load server root which manages zones as children
	get_tree().change_scene_to_file("res://scenes/server_root.tscn")

func _update_steam_status():
	if not SteamManager:
		steam_status_label.text = "Steam: Not Available"
		steam_name_label.text = ""
		return
	
	if SteamManager.is_steam_running():
		if SteamManager.is_using_steam():
			steam_status_label.text = "Steam: Connected"
			steam_status_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			steam_status_label.text = "Steam: Mock Mode (Offline)"
			steam_status_label.add_theme_color_override("font_color", Color.YELLOW)
		steam_name_label.text = SteamManager.get_persona_name()
	else:
		steam_status_label.text = "Steam: Initializing..."
		steam_name_label.text = ""

func _update_connection_status(status: String, color: Color = Color(0.5, 0.5, 0.5)):
	if connection_status_label:
		connection_status_label.text = status
		connection_status_label.add_theme_color_override("font_color", color)

func _on_steam_initialized(_success: bool):
	_update_steam_status()

func _on_hub_pressed():
	go_to_hub_pressed.emit()
	_connect_and_load("res://scenes/hub/hub.tscn")

func _on_test_pressed():
	go_to_test_pressed.emit()
	_connect_and_load("res://scenes/test.tscn")

func _on_reset_data_pressed():
	## Delete all character data for this Steam user (for testing)
	## Also recreates inventory tables to fix any schema issues
	if not SteamManager:
		_update_connection_status("Cannot reset - no Steam", Color.RED)
		return
	
	var steam_id = SteamManager.get_steam_id()
	if steam_id <= 0:
		_update_connection_status("Cannot reset - no Steam ID", Color.RED)
		return
	
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db:
		# First recreate tables to fix any foreign key constraint issues
		if item_db.has_method("recreate_inventory_tables"):
			item_db.recreate_inventory_tables()
		
		# Then delete character data
		if item_db.has_method("delete_character_data"):
			item_db.delete_character_data(steam_id)
		
		_update_connection_status("Character data reset!", Color.GREEN)
		print("[TitleMenu] Reset character data for Steam ID: ", steam_id)
	else:
		# Fallback: delete via DatabaseManager directly
		var db = get_node_or_null("/root/DatabaseManager")
		if db:
			# Delete equipment, inventory, and character data
			db.execute_query("DELETE FROM player_equipment WHERE steam_id = ?;", [steam_id])
			db.execute_query("DELETE FROM player_inventory WHERE steam_id = ?;", [steam_id])
			db.execute_query("DELETE FROM characters WHERE steam_id = ?;", [steam_id])
			_update_connection_status("Character data reset!", Color.GREEN)
			print("[TitleMenu] Reset character data for Steam ID: ", steam_id)
		else:
			_update_connection_status("Cannot reset - no database", Color.RED)

func _on_quit_pressed():
	get_tree().quit()

func _connect_and_load(scene_path: String):
	# If running as server (listen server mode), start server and load server_root
	if is_server and not is_dedicated:
		if NetworkManager:
			NetworkManager.start_server(server_port)
			# Register server player with Steam info
			if SteamManager:
				var steam_id = SteamManager.get_steam_id()
				var steam_name = SteamManager.get_persona_name()
				print("[Server] Registering host as: ", steam_name, " (Steam ID: ", steam_id, ")")
				NetworkManager.register_player(steam_id, steam_name, 0)
		# Server loads server_root which manages zones as children
		get_tree().change_scene_to_file("res://scenes/server_root.tscn")
		return
	
	# Client mode - try to connect to servers
	pending_scene = scene_path
	current_server_index = 0
	_try_connect_to_server()

func _try_connect_to_server():
	if current_server_index >= SERVER_LIST.size():
		# All servers failed - show error, stay on menu
		_update_connection_status("Connection Failed - Servers Unavailable", Color.RED)
		print("[Client] All servers unreachable - cannot play")
		is_connecting = false
		_set_buttons_enabled(true)
		return
	
	var server = SERVER_LIST[current_server_index]
	is_connecting = true
	
	_update_connection_status("Connecting to " + server + "...", Color.YELLOW)
	print("[Client] Trying to connect to: ", server, ":", server_port)
	
	# Disable buttons while connecting
	_set_buttons_enabled(false)
	
	# Try to connect
	if NetworkManager:
		NetworkManager.connect_to_server(server, server_port)
	
	# Start timeout timer
	connection_timer.start(CONNECTION_TIMEOUT)

func _on_connected_to_server():
	is_connecting = false
	connection_timer.stop()
	
	var server = SERVER_LIST[current_server_index]
	_update_connection_status("Connected! Joining zone...", Color.GREEN)
	print("[Client] Connected to: ", server)

	# Determine zone type from pending_scene
	var zone_type = "hub"
	if pending_scene.contains("test"):
		zone_type = "test"

	# Register player with Steam info and requested zone
	if NetworkManager and SteamManager:
		var steam_id = SteamManager.get_steam_id()
		var steam_name = SteamManager.get_persona_name()
		print("[Client] Registering as: %s (Steam ID: %d), requesting zone: %s" % [steam_name, steam_id, zone_type])
		NetworkManager.register_player(steam_id, steam_name, 0, zone_type)

	# Server will assign us to the requested zone and send _rpc_client_load_zone
	print("[Client] Waiting for server to assign zone...")

func _on_connection_failed():
	_try_next_server()

func _on_connection_timeout():
	if is_connecting:
		print("[Client] Connection timeout for: ", SERVER_LIST[current_server_index])
		_try_next_server()

func _try_next_server():
	is_connecting = false
	connection_timer.stop()
	
	if NetworkManager:
		NetworkManager.disconnect_from_server()
	
	current_server_index += 1
	_try_connect_to_server()

func _set_buttons_enabled(enabled: bool):
	hub_button.disabled = not enabled
	test_button.disabled = not enabled
	reset_data_button.disabled = not enabled
	quit_button.disabled = not enabled
