extends Node

## PioneerEventManager - Handles all dialogue events from NPCs
## Centralizes shop, bank, teleporter, and other NPC functionality

signal shop_opened(player: Node, shop_id: String)
signal shop_closed(player: Node)
signal bank_opened(player: Node)
signal bank_closed(player: Node)
signal descend_requested(player: Node, destination: String, use_rental: bool)
signal ascend_requested(player: Node)
signal extraction_started(player: Node, beacon: Node)

#region Dialogue Event Routing
func handle_dialogue_event(event: Dictionary, player: Node, npc: Node) -> bool:
	## Routes dialogue events to appropriate handlers
	## Returns true if event was handled
	var event_type = event.get("type", "")
	var params = event.get("params", {})

	match event_type:
		"open_shop":
			var shop_id = params.get("shop_id", npc.shop_id if "shop_id" in npc else "")
			open_shop(player, shop_id)
			return true
		"open_bank":
			var bank_name = npc.bank_name if "bank_name" in npc else "Storage"
			open_bank(player, bank_name)
			return true
		"descend_planet":
			_descend_to_planet(player, npc, false)
			return true
		"descend_rental":
			_descend_to_planet(player, npc, true)
			return true
		"start_signal":
			# Extraction beacon: start signaling station
			if npc.has_method("handle_dialogue_event"):
				return npc.handle_dialogue_event(event, player)
			return false
		"confirm_extraction":
			# Extraction beacon: player confirmed extraction
			if npc.has_method("handle_dialogue_event"):
				return npc.handle_dialogue_event(event, player)
			return false
		_:
			return false
#endregion

#region Shop System
func open_shop(player: Node, shop_id: String):
	print("[PioneerEventManager] Opening shop: %s" % shop_id)

	var shop_panel = _get_or_create_shop_panel(player)
	if not shop_panel:
		push_warning("[PioneerEventManager] Could not create shop panel")
		return

	var character_id = -1
	var steam_id = 0

	var network = get_node_or_null("/root/NetworkManager")
	if network:
		character_id = network.get_character_id_for_peer(player.get_multiplayer_authority())
		steam_id = network.get_steam_id_for_peer(player.get_multiplayer_authority())

	if not shop_panel.shop_closed.is_connected(_on_shop_closed):
		shop_panel.shop_closed.connect(_on_shop_closed.bind(player))

	shop_panel.open(shop_id, character_id, steam_id)
	shop_opened.emit(player, shop_id)

func _get_or_create_shop_panel(player: Node) -> Control:
	var existing = player.get_node_or_null("ShopUILayer/ShopPanel")
	if existing:
		return existing

	var shop_scene = load("res://scenes/ui/shop/shop_panel.tscn")
	if not shop_scene:
		push_error("[PioneerEventManager] Could not load shop_panel.tscn")
		return null

	var shop_panel = shop_scene.instantiate()

	var canvas = CanvasLayer.new()
	canvas.name = "ShopUILayer"
	canvas.layer = 100
	player.add_child(canvas)
	canvas.add_child(shop_panel)

	return shop_panel

func _on_shop_closed(player: Node):
	shop_closed.emit(player)
#endregion

#region Bank System
func open_bank(player: Node, bank_name: String):
	print("[PioneerEventManager] Opening bank: %s" % bank_name)
	bank_opened.emit(player)

	var character_id = 0
	if "character_id" in player:
		character_id = player.character_id

	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("open_bank_panel"):
		network.open_bank_panel(character_id, bank_name)
	else:
		_open_bank_panel_local(player, bank_name)

func _open_bank_panel_local(player: Node, bank_name: String):
	var bank_panel_scene = load("res://scenes/ui/bank_panel.tscn")
	if not bank_panel_scene:
		push_warning("[PioneerEventManager] Bank panel scene not found")
		return

	var bank_panel = bank_panel_scene.instantiate()

	var ui_layer = player.get_node_or_null("UILayer")
	if not ui_layer:
		ui_layer = CanvasLayer.new()
		ui_layer.name = "UILayer"
		ui_layer.layer = 100
		player.add_child(ui_layer)

	ui_layer.add_child(bank_panel)

	var character_id = 0
	if "character_id" in player:
		character_id = player.character_id

	if bank_panel.has_method("open_bank"):
		bank_panel.open_bank(character_id, bank_name)

	if bank_panel.has_signal("closed"):
		bank_panel.closed.connect(_on_bank_closed.bind(player))

func _on_bank_closed(player: Node):
	bank_closed.emit(player)
#endregion

#region Teleporter/Descent System
func _descend_to_planet(player: Node, npc: Node, use_rental: bool):
	var destination_scene = npc.destination_zone if "destination_zone" in npc else ""
	var planet_name = npc.planet_name if "planet_name" in npc else "Unknown"

	if destination_scene.is_empty():
		push_warning("[PioneerEventManager] No destination_zone set on NPC")
		return

	print("[PioneerEventManager] Descending to %s (rental: %s)" % [planet_name, use_rental])

	if use_rental:
		_setup_rental_loadout(player, npc)

	descend_requested.emit(player, destination_scene, use_rental)

	# Get player's peer_id for zone transfer
	var peer_id = _get_player_peer_id(player)
	if peer_id <= 0:
		push_warning("[PioneerEventManager] Could not get peer_id for player")
		return

	# Use ZoneManager to create/get zone and transfer player
	var zone_manager = get_node_or_null("/root/ZoneManager")
	if zone_manager:
		# Create or get a zone for this planet (zone_type is the planet name)
		var zone_id = ""
		if zone_manager.has_method("get_or_create_zone"):
			zone_id = zone_manager.get_or_create_zone(planet_name.to_lower(), destination_scene)

		if zone_id.is_empty():
			push_warning("[PioneerEventManager] Failed to create zone for %s" % planet_name)
			return

		print("[PioneerEventManager] Zone ready: %s, transferring player %d" % [zone_id, peer_id])

		# Transfer player to the zone
		if zone_manager.has_method("request_transfer"):
			if zone_manager.request_transfer(peer_id, zone_id):
				# Complete the transfer immediately for teleporter
				if zone_manager.has_method("complete_transfer"):
					zone_manager.complete_transfer(peer_id)
				print("[PioneerEventManager] Player %d transferred to zone %s" % [peer_id, zone_id])
			else:
				push_warning("[PioneerEventManager] Transfer request failed")
	else:
		push_warning("[PioneerEventManager] No ZoneManager found")

func _get_player_peer_id(player: Node) -> int:
	## Get the peer_id for a player entity
	# Check for peer_id property
	if "peer_id" in player:
		return player.peer_id

	# Check NetworkIdentity component
	var net_id = player.get_node_or_null("NetworkIdentity")
	if net_id and "peer_id" in net_id:
		return net_id.peer_id

	# Ask NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("get_peer_for_entity"):
		return network.get_peer_for_entity(player)

	return 0

func _setup_rental_loadout(player: Node, npc: Node):
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		push_warning("[PioneerEventManager] No ItemDatabase found")
		return

	var character_id = 0
	if "character_id" in player:
		character_id = player.character_id

	if character_id <= 0:
		push_warning("[PioneerEventManager] Invalid character ID")
		return

	# Bank all current inventory items
	if item_db.has_method("bank_all_inventory"):
		item_db.bank_all_inventory(character_id)
		print("[PioneerEventManager] Banked all inventory for character %d" % character_id)

	# Unequip all weapons
	var equipment = player.get_node_or_null("EquipmentManager")
	if equipment and equipment.has_method("unequip_all"):
		equipment.unequip_all()

	# Get steam_id for adding items
	var steam_id = 0
	if "steam_id" in player:
		steam_id = player.steam_id
	elif player.has_method("get_steam_id"):
		steam_id = player.get_steam_id()

	# Get rental weapons from NPC exports
	var rental_items: Array[String] = []
	if "rental_weapon_1" in npc and not npc.rental_weapon_1.is_empty():
		rental_items.append(npc.rental_weapon_1)
	if "rental_weapon_2" in npc and not npc.rental_weapon_2.is_empty():
		rental_items.append(npc.rental_weapon_2)
	if "rental_weapon_3" in npc and not npc.rental_weapon_3.is_empty():
		rental_items.append(npc.rental_weapon_3)

	for i in range(rental_items.size()):
		var item_id = rental_items[i]

		if item_db.has_method("add_to_inventory"):
			var inv_id = item_db.add_to_inventory(steam_id, character_id, item_id, 1)
			if inv_id > 0:
				print("[PioneerEventManager] Added rental item: %s" % item_id)

				var slot_name = "weapon_%d" % (i + 1)
				if item_db.has_method("equip_item"):
					item_db.equip_item(character_id, slot_name, inv_id)

	# Refresh equipment display
	if equipment and equipment.has_method("load_from_database"):
		equipment.load_from_database(character_id)
#endregion

#region Extraction/Ascend System
func ascend_to_station(player: Node):
	## Transfer player back to the station hub
	## Converts all credit chips in inventory to actual credits (successful extraction)
	print("[PioneerEventManager] Ascending player to station")

	ascend_requested.emit(player)

	var peer_id = _get_player_peer_id(player)
	if peer_id <= 0:
		push_warning("[PioneerEventManager] Could not get peer_id for ascending player")
		return

	# Convert credit chips to actual credits (extraction reward)
	_convert_credit_chips(player)

	var zone_manager = get_node_or_null("/root/ZoneManager")
	if not zone_manager:
		push_warning("[PioneerEventManager] No ZoneManager found")
		return

	# Get or create hub zone
	var hub_zone_id = ""
	if zone_manager.has_method("get_or_create_zone"):
		hub_zone_id = zone_manager.get_or_create_zone("hub", "res://scenes/hub/hub.tscn")

	if hub_zone_id.is_empty():
		push_warning("[PioneerEventManager] Could not get hub zone for ascent")
		return

	print("[PioneerEventManager] Hub zone ready: %s, transferring player %d" % [hub_zone_id, peer_id])

	# Transfer player to hub
	if zone_manager.has_method("request_transfer"):
		if zone_manager.request_transfer(peer_id, hub_zone_id):
			if zone_manager.has_method("complete_transfer"):
				zone_manager.complete_transfer(peer_id)
			print("[PioneerEventManager] Player %d ascended to station" % peer_id)
		else:
			push_warning("[PioneerEventManager] Ascent transfer request failed")

func _convert_credit_chips(player: Node):
	## Convert all credit_chip items in inventory to actual credits
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		return

	var character_id = 0
	if "character_id" in player:
		character_id = player.character_id

	if character_id <= 0:
		push_warning("[PioneerEventManager] No character_id for credit conversion")
		return

	# Get all credit chips from inventory
	var total_credits = 0
	if item_db.has_method("get_inventory_items"):
		var inventory = item_db.get_inventory_items(character_id)
		for item in inventory:
			if item.get("item_id") == "credit_chip":
				total_credits += item.get("quantity", 0)
				# Remove the credit chips from inventory
				if item_db.has_method("remove_from_inventory"):
					item_db.remove_from_inventory(item.get("inventory_id", 0))

	if total_credits > 0:
		# Add to actual credit balance
		if item_db.has_method("add_credits"):
			var new_total = item_db.add_credits(character_id, total_credits)
			print("[PioneerEventManager] Extraction success! Converted %d credit chips (total: %d)" % [total_credits, new_total])
#endregion
