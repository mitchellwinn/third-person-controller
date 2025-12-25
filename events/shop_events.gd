extends Node

## Shop Events - Custom dialogue events for the shop system
## This file is auto-loaded by EventManager

func register_events(event_manager: Node):
	## Called by EventManager to register our events
	event_manager.register_event("open_shop", _on_open_shop)
	event_manager.register_event("give_credits", _on_give_credits)
	event_manager.register_event("has_credits", _on_has_credits)
	print("[ShopEvents] Registered shop dialogue events")

func _on_open_shop(args: Array) -> String:
	## Opens a shop UI
	## Usage in dialogue: `open_shop|shop_id`
	## Example: `open_shop|supply_officer`
	
	var shop_id = args[1] if args.size() > 1 else "supply_officer"
	
	# Find the local player
	var player = _get_local_player()
	if not player:
		push_warning("[ShopEvents] Cannot open shop - no local player found")
		return ""
	
	# Get player info
	var character_id = -1
	var steam_id = 0
	var network = get_node_or_null("/root/NetworkManager")
	if network:
		character_id = network.get_character_id_for_peer(player.get_multiplayer_authority())
		steam_id = network.get_steam_id_for_peer(player.get_multiplayer_authority())
	
	# Find or create shop panel
	var shop_panel = _get_or_create_shop_panel(player)
	if shop_panel:
		# Open shop FIRST (this ensures talking state stays active)
		# Then close dialogue UI (but don't exit talking state since shop is open)
		shop_panel.open(shop_id, character_id, steam_id)
		
		# Close dialogue UI only (the shop has already entered talking state)
		var dialogue_manager = get_node_or_null("/root/DialogueManager")
		if dialogue_manager:
			dialogue_manager.end_dialogue()
		
		# Mouse visibility is handled by the talking state - don't set it directly!
	
	return ""

func _on_give_credits(args: Array) -> String:
	## Give credits to the player
	## Usage: `give_credits|amount`
	## Example: `give_credits|500`
	
	var amount = int(args[1]) if args.size() > 1 else 0
	if amount <= 0:
		return ""
	
	var player = _get_local_player()
	if not player:
		return ""
	
	var network = get_node_or_null("/root/NetworkManager")
	var item_db = get_node_or_null("/root/ItemDatabase")
	if network and item_db:
		var character_id = network.get_character_id_for_peer(player.get_multiplayer_authority())
		if character_id > 0:
			var new_total = item_db.add_credits(character_id, amount)
			print("[ShopEvents] Gave %d credits to player (new total: %d)" % [amount, new_total])
	
	return ""

func _on_has_credits(args: Array) -> String:
	## Check if player has enough credits
	## Usage: `has_credits|amount`
	## Returns "true" or "false"
	
	var required = int(args[1]) if args.size() > 1 else 0
	
	var player = _get_local_player()
	if not player:
		return "false"
	
	var network = get_node_or_null("/root/NetworkManager")
	var item_db = get_node_or_null("/root/ItemDatabase")
	if network and item_db:
		var character_id = network.get_character_id_for_peer(player.get_multiplayer_authority())
		if character_id > 0:
			var current = item_db.get_player_credits(character_id)
			return "true" if current >= required else "false"
	
	return "false"

func _get_local_player() -> Node:
	## Find the local player entity
	for player in get_tree().get_nodes_in_group("players"):
		if player.has_method("can_receive_input") and player.can_receive_input:
			return player
	return null

func _get_or_create_shop_panel(player: Node) -> Control:
	## Get or create the shop panel for a player
	var existing = player.get_node_or_null("ShopUILayer/ShopPanel")
	if existing:
		return existing
	
	var shop_scene = load("res://scenes/ui/shop/shop_panel.tscn")
	if not shop_scene:
		push_error("[ShopEvents] Could not load shop_panel.tscn")
		return null
	
	var shop_panel = shop_scene.instantiate()
	
	var canvas = CanvasLayer.new()
	canvas.name = "ShopUILayer"
	canvas.layer = 100
	player.add_child(canvas)
	canvas.add_child(shop_panel)
	
	return shop_panel


