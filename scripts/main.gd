extends Node

## Main entry point - handles server/client mode based on command line args
##
## Usage:
##   --server              Start as dedicated server
##   --client              Start as client
##   --port 7777           Port to use
##   --ip 127.0.0.1        Server IP (client only)
##   --max-players 32      Max players (server only)
##
## Zone Architecture:
##   Server loads server_root.tscn which manages zones as child nodes
##   Clients wait for zone assignment from server before loading scene

@export var default_scene: PackedScene
@export var hub_scene_path: String = "res://scenes/hub/hub.tscn"
@export var server_root_path: String = "res://scenes/server_root.tscn"

var is_server: bool = false
var is_client: bool = false
var server_ip: String = "127.0.0.1"
var server_port: int = 7777
var max_players: int = 32

func _ready():
	_parse_command_line()
	_setup_mode()

func _parse_command_line():
	var args = OS.get_cmdline_args()  # Gets all command line args

	var i = 0
	while i < args.size():
		var arg = args[i]

		match arg:
			"--server":
				is_server = true
			"--client":
				is_client = true
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

	# Auto-detect headless as server
	if DisplayServer.get_name() == "headless":
		is_server = true

	print("[Main] Mode: ", "SERVER" if is_server else ("CLIENT" if is_client else "STANDALONE"))
	print("[Main] Port: ", server_port)
	if is_client:
		print("[Main] Server IP: ", server_ip)
	if is_server:
		print("[Main] Max Players: ", max_players)

func _setup_mode():
	if is_server:
		_start_server()
	elif is_client:
		_start_client()
	else:
		# Standalone mode - just load the scene normally (for editor testing)
		_load_hub_scene()

func _start_server():
	print("[Main] Starting dedicated server on port ", server_port)

	# Initialize networking
	if has_node("/root/NetworkManager"):
		var network = get_node("/root/NetworkManager")
		if network.has_method("start_server"):
			network.start_server(server_port, max_players)

	# Load the server root scene (manages zones as children)
	_load_server_root()

	print("[Main] Server ready!")

func _start_client():
	print("[Main] Starting client, connecting to ", server_ip, ":", server_port)

	# Initialize networking
	if has_node("/root/NetworkManager"):
		var network = get_node("/root/NetworkManager")
		if network.has_method("connect_to_server"):
			network.connect_to_server(server_ip, server_port)

	# Client starts with hub scene - server will assign zone via RPC
	# The server_root's _rpc_client_load_zone will change scene when zone is assigned
	_load_hub_scene()

func _load_server_root():
	## Server loads the server_root scene which manages all zones
	if server_root_path:
		get_tree().change_scene_to_file(server_root_path)
	else:
		push_error("[Main] No server_root_path configured!")

func _load_hub_scene():
	if default_scene:
		get_tree().change_scene_to_packed(default_scene)
	elif hub_scene_path:
		get_tree().change_scene_to_file(hub_scene_path)

