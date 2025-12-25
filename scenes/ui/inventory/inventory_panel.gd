extends Control
class_name InventoryPanel

## Main inventory UI panel
## Layout is defined in inventory_panel.tscn for editor customization
## Shows equipment slots and inventory grid
## Handles equip/unequip via drag-drop or double-click

signal closed()
signal item_equipped(slot_name: String, item_data: Dictionary)
signal item_unequipped(slot_name: String)
signal item_dropped(item_data: Dictionary, world_position: Vector3)

## Scene node references
@onready var close_button: Button = $MainContainer/MainPanel/PanelMargin/VerticalLayout/HeaderBar/HeaderMargin/HeaderContent/CloseButton
@onready var inventory_grid: GridContainer = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/InventorySection/InventoryMargin/InventoryLayout/InventoryScroll/InventoryGrid
@onready var capacity_label: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/InventorySection/InventoryMargin/InventoryLayout/InventoryHeader/CapacityLabel

## Equipment slot references
@onready var weapon_1_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/WeaponSlotsSection/WeaponSlotsGrid/Weapon1Slot
@onready var weapon_2_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/WeaponSlotsSection/WeaponSlotsGrid/Weapon2Slot
@onready var weapon_3_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/WeaponSlotsSection/WeaponSlotsGrid/Weapon3Slot
@onready var head_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/CharacterArea/LeftSlots/HeadSlot
@onready var armor_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/CharacterArea/LeftSlots/ArmorSlot
@onready var gadget_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/CharacterArea/RightSlots/GadgetSlot
@onready var consumable_slot: InventorySlot = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection/EquipmentMargin/EquipmentLayout/CharacterArea/RightSlots/ConsumableSlot

## Info panel references
@onready var info_panel: PanelContainer = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel
@onready var info_icon_label: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemIcon/ItemIconLabel
@onready var info_name: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemDetails/ItemName
@onready var info_type: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemDetails/ItemType
@onready var info_description: RichTextLabel = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemDetails/ItemDescription
@onready var stat1_value: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemStats/Stat1/Value
@onready var stat2_value: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemStats/Stat2/Value
@onready var stat3_value: Label = $MainContainer/MainPanel/PanelMargin/VerticalLayout/InfoPanel/InfoMargin/InfoContent/ItemStats/Stat3/Value

## Slot collections (built on ready)
var equipment_slots: Dictionary = {} # slot_name -> InventorySlot
var inventory_slots: Array[InventorySlot] = []

## Local storage for unequipped items (survives refresh when DB is empty)
var _local_inventory_items: Array[Dictionary] = []

## Player reference
var _player: Node = null
var _equipment_manager: Node = null
var _character_id: int = 0

## Drag tracking for drop-to-world
var _drag_source_slot: InventorySlot = null
var _drag_item_data: Dictionary = {}

## Context menu
var _context_menu: PopupMenu = null
var _context_menu_slot: InventorySlot = null

func _ready():
	_setup_styles()
	_collect_slots()
	_connect_signals()
	_setup_context_menu()
	
	# Close on escape
	set_process_unhandled_input(true)
	
	# Add to group so state_talking knows we need mouse visible
	add_to_group("ui_needs_mouse")
	
	# Start hidden
	visible = false

func _unhandled_input(event: InputEvent):
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func _notification(what: int):
	# Detect when drag ends without being dropped on a valid target
	if what == NOTIFICATION_DRAG_END:
		if _drag_source_slot and not _drag_item_data.is_empty():
			# Small delay to let normal drop handlers fire first
			call_deferred("_check_drop_outside_panel")

func _check_drop_outside_panel():
	## Called after drag ends - check if item should be dropped in world
	if _drag_source_slot == null or _drag_item_data.is_empty():
		return
	
	# Check if the source slot still has the item (wasn't dropped on valid target)
	if _drag_source_slot.has_item():
		var source_item_id = _drag_source_slot.item_data.get("item_id", "")
		var drag_item_id = _drag_item_data.get("item_id", "")
		
		# If source still has same item, drag was cancelled or dropped outside
		if source_item_id == drag_item_id:
			# Check if mouse is outside the panel
			var mouse_pos = get_global_mouse_position()
			var panel_rect = get_global_rect()
			
			if not panel_rect.has_point(mouse_pos):
				# Dropped outside panel - drop item in world
				_drop_item_in_world(_drag_source_slot, _drag_item_data)
	
	# Clear drag state
	_drag_source_slot = null
	_drag_item_data = {}

func _setup_styles():
	## Apply styling to panels - can be customized here or via theme
	var main_panel = $MainContainer/MainPanel
	var main_style = StyleBoxFlat.new()
	main_style.bg_color = Color(0.08, 0.08, 0.1, 0.98)
	main_style.border_color = Color(0.2, 0.2, 0.25)
	main_style.set_border_width_all(1)
	main_style.set_corner_radius_all(4)
	main_panel.add_theme_stylebox_override("panel", main_style)
	
	# Header bar
	var header = $MainContainer/MainPanel/PanelMargin/VerticalLayout/HeaderBar
	var header_style = StyleBoxFlat.new()
	header_style.bg_color = Color(0.12, 0.12, 0.14)
	header.add_theme_stylebox_override("panel", header_style)
	
	# Equipment section
	var equip_section = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/EquipmentSection
	var equip_style = StyleBoxFlat.new()
	equip_style.bg_color = Color(0.1, 0.1, 0.12)
	equip_section.add_theme_stylebox_override("panel", equip_style)
	
	# Inventory section
	var inv_section = $MainContainer/MainPanel/PanelMargin/VerticalLayout/ContentArea/InventorySection
	var inv_style = StyleBoxFlat.new()
	inv_style.bg_color = Color(0.09, 0.09, 0.11)
	inv_section.add_theme_stylebox_override("panel", inv_style)
	
	# Info panel
	var info_style = StyleBoxFlat.new()
	info_style.bg_color = Color(0.11, 0.11, 0.13)
	info_style.border_color = Color(0.18, 0.18, 0.22)
	info_style.border_width_top = 1
	info_panel.add_theme_stylebox_override("panel", info_style)
	
	# Style all slots
	_apply_slot_styles()

func _apply_slot_styles():
	## Style is applied after slots are collected
	await get_tree().process_frame
	
	var slot_style = StyleBoxFlat.new()
	slot_style.bg_color = Color(0.14, 0.14, 0.16)
	slot_style.border_color = Color(0.22, 0.22, 0.26)
	slot_style.set_border_width_all(1)
	slot_style.set_corner_radius_all(3)
	
	var equip_slot_style = StyleBoxFlat.new()
	equip_slot_style.bg_color = Color(0.12, 0.12, 0.15)
	equip_slot_style.border_color = Color(0.25, 0.25, 0.3)
	equip_slot_style.set_border_width_all(1)
	equip_slot_style.set_corner_radius_all(4)
	
	for slot in inventory_slots:
		slot.add_theme_stylebox_override("panel", slot_style)
	
	for slot_name in equipment_slots:
		equipment_slots[slot_name].add_theme_stylebox_override("panel", equip_slot_style)

func _collect_slots():
	## Gather all slot references from scene
	# Equipment slots - 3 generic weapon slots (any weapon can go in any slot)
	equipment_slots = {
		"weapon_1": weapon_1_slot,
		"weapon_2": weapon_2_slot,
		"weapon_3": weapon_3_slot,
		"head": head_slot,
		"armor": armor_slot,
		"gadget": gadget_slot,
		"consumable": consumable_slot
	}
	
	# Inventory grid slots
	inventory_slots.clear()
	for child in inventory_grid.get_children():
		if child is InventorySlot:
			inventory_slots.append(child)

func _connect_signals():
	## Connect all slot signals
	close_button.pressed.connect(close)
	
	# Equipment slots
	for slot_name in equipment_slots:
		var slot = equipment_slots[slot_name]
		if slot:
			slot.item_clicked.connect(_on_slot_clicked)
			slot.item_double_clicked.connect(_on_slot_double_clicked)
			slot.item_right_clicked.connect(_on_slot_right_clicked)
			slot.drag_started.connect(_on_drag_started)
			slot.drag_ended.connect(_on_drag_ended)
			slot.items_stacked.connect(_on_items_stacked)
			slot.mouse_entered.connect(_on_slot_hovered.bind(slot))
			slot.mouse_exited.connect(_on_slot_unhovered)
	
	# Inventory slots
	for slot in inventory_slots:
		slot.item_clicked.connect(_on_slot_clicked)
		slot.item_double_clicked.connect(_on_slot_double_clicked)
		slot.item_right_clicked.connect(_on_slot_right_clicked)
		slot.drag_started.connect(_on_drag_started)
		slot.drag_ended.connect(_on_drag_ended)
		slot.items_stacked.connect(_on_items_stacked)
		slot.mouse_entered.connect(_on_slot_hovered.bind(slot))
		slot.mouse_exited.connect(_on_slot_unhovered)

func _setup_context_menu():
	## Create the right-click context menu
	_context_menu = PopupMenu.new()
	_context_menu.name = "ItemContextMenu"
	add_child(_context_menu)
	
	# Connect menu selection
	_context_menu.id_pressed.connect(_on_context_menu_selected)

#region Data Loading
func set_player(player: Node):
	_player = player
	_equipment_manager = player.get_node_or_null("EquipmentManager")
	
	# Get character_id - MUST match what ItemDatabase used when giving starting weapons
	# Priority: NetworkManager's authenticated character > player properties > fallback
	
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("get_local_character_id"):
		_character_id = network.get_local_character_id()
		print("[Inventory] Got character_id from NetworkManager: ", _character_id)
	
	# Fallback to player properties
	if _character_id == 0:
		if "character_id" in player and player.character_id > 0:
			_character_id = player.character_id
		elif "steam_id" in player and player.steam_id > 0:
			_character_id = player.steam_id
		elif player.has_node("NetworkIdentity"):
			var net_id = player.get_node("NetworkIdentity")
			if "owner_peer_id" in net_id:
				_character_id = net_id.owner_peer_id
	
	# Last fallback: SteamManager
	if _character_id == 0:
		var steam = get_node_or_null("/root/SteamManager")
		if steam and steam.has_method("get_steam_id"):
			_character_id = steam.get_steam_id()
	
	print("[Inventory] Player set, character_id: ", _character_id)
	refresh()

func refresh():
	## Reload all data - ALWAYS use EquipmentManager for equipment slots (source of truth)
	## and database/local items for inventory slots
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		print("[Inventory] ItemDatabase not found!")
		return
	
	if not item_db.is_ready:
		print("[Inventory] ItemDatabase not ready yet")
		return
	
	print("[Inventory] Refreshing for character_id: ", _character_id)
	
	# Clear all slots first
	for slot in inventory_slots:
		slot.clear_item()
	for slot_name in equipment_slots:
		if equipment_slots[slot_name]:
			equipment_slots[slot_name].clear_item()
	
	# ALWAYS populate equipment slots from EquipmentManager (it's what's actually equipped!)
	# Database may not have items that were picked up this session (client can't write to server DB)
	var equipped_from_manager: Dictionary = {}
	if _equipment_manager and _equipment_manager.has_method("get_all_weapon_data"):
		equipped_from_manager = _equipment_manager.get_all_weapon_data()
		print("[Inventory] Equipped from EquipmentManager: ", equipped_from_manager.keys())
		
		for slot_name in equipped_from_manager:
			if equipment_slots.has(slot_name) and equipment_slots[slot_name]:
				var data = equipped_from_manager[slot_name]
				equipment_slots[slot_name].set_item(data, data.get("inventory_id", -1))
	
	# For inventory slots, try database first, then local items
	var inv_index = 0
	var item_count = 0
	
	if _character_id > 0:
		# Load inventory (non-equipped items) from database
		var inventory = item_db.get_inventory(_character_id)
		print("[Inventory] Total inventory items from DB: ", inventory.size())
		
		# Get equipped inventory IDs to skip
		var equipped_item_ids: Array[String] = []
		for slot_name in equipped_from_manager:
			var item_id = equipped_from_manager[slot_name].get("item_id", "")
			if not item_id.is_empty():
				equipped_item_ids.append(item_id)
		
		for item in inventory:
			# Skip items that are currently equipped
			var item_id = item.get("item_id", "")
			if item_id in equipped_item_ids:
				print("[Inventory] Skipping equipped item: ", item.get("name", "unknown"))
				continue
			
			if inv_index < inventory_slots.size():
				inventory_slots[inv_index].set_item(item, item.get("inventory_id", -1))
				inv_index += 1
				item_count += 1
	
	# ALSO restore local inventory items (items unequipped/picked up this session but not in DB)
	print("[Inventory] Local inventory items: ", _local_inventory_items.size())
	for local_item in _local_inventory_items:
		var local_item_id = local_item.get("item_id", "")
		var already_shown = false
		
		# Check if already in equipment slots
		for slot_name in equipped_from_manager:
			if equipped_from_manager[slot_name].get("item_id", "") == local_item_id:
				already_shown = true
				break
		
		# Check if already in inventory slots
		if not already_shown:
			for i in range(inv_index):
				var slot_item = inventory_slots[i].item_data
				if slot_item and slot_item.get("item_id", "") == local_item_id:
					already_shown = true
					break
		
		if not already_shown and inv_index < inventory_slots.size():
			inventory_slots[inv_index].set_item(local_item, -1)
			print("[Inventory] Restored local item: ", local_item.get("name", "unknown"))
			inv_index += 1
			item_count += 1
	
	# Update capacity display
	var total_items = equipped_from_manager.size() + item_count
	if capacity_label:
		capacity_label.text = "%d / %d" % [total_items, inventory_slots.size() + equipment_slots.size()]

func _populate_from_equipment_manager():
	## Fallback: populate equipment slots directly from EquipmentManager
	## Also restores locally stored inventory items
	print("[Inventory] === POPULATING FROM EQUIPMENT MANAGER ===")
	print("[Inventory] _equipment_manager: ", _equipment_manager)
	print("[Inventory] equipment_slots: ", equipment_slots.keys())
	print("[Inventory] Local inventory items: ", _local_inventory_items.size())
	
	# Check each slot node exists
	for slot_name in equipment_slots:
		var slot_node = equipment_slots[slot_name]
		print("[Inventory] Slot '%s' node: %s" % [slot_name, slot_node])
	
	if not _equipment_manager:
		print("[Inventory] ERROR: No EquipmentManager!")
		# Try to find it again
		if _player:
			_equipment_manager = _player.get_node_or_null("EquipmentManager")
			print("[Inventory] Re-searched, found: ", _equipment_manager)
	
	if not _equipment_manager:
		print("[Inventory] STILL no EquipmentManager!")
		# Try to find it again
		if _player:
			_equipment_manager = _player.get_node_or_null("EquipmentManager")
		if not _equipment_manager:
			print("[Inventory] Cannot find EquipmentManager - showing empty inventory")
			return
	
	# Clear all slots first
	for slot in inventory_slots:
		slot.clear_item()
	for slot_name in equipment_slots:
		if equipment_slots[slot_name]:
			equipment_slots[slot_name].clear_item()
	
	# Get weapon data
	var weapons = {}
	if _equipment_manager.has_method("get_all_weapon_data"):
		weapons = _equipment_manager.get_all_weapon_data()
	print("[Inventory] Got %d weapons from EquipmentManager" % weapons.size())
	
	# Populate equipment slots
	for slot_name in weapons:
		print("[Inventory] Setting slot '%s' with: %s" % [slot_name, weapons[slot_name]])
		if equipment_slots.has(slot_name) and equipment_slots[slot_name]:
			equipment_slots[slot_name].set_item(weapons[slot_name], -1)
			print("[Inventory] SUCCESS: Set %s" % slot_name)
		else:
			print("[Inventory] FAILED: Slot '%s' not found or null" % slot_name)
	
	# Restore local inventory items (items that were unequipped but not saved to DB)
	var inv_index = 0
	for item_data in _local_inventory_items:
		if inv_index < inventory_slots.size():
			inventory_slots[inv_index].set_item(item_data, -1)
			print("[Inventory] Restored local item: %s" % item_data.get("name", "unknown"))
			inv_index += 1
	
	# Update capacity
	var count = weapons.size() + _local_inventory_items.size()
	if capacity_label:
		capacity_label.text = "%d / %d" % [count, inventory_slots.size() + equipment_slots.size()]

#endregion

#region Slot Interactions
func _on_slot_clicked(slot: InventorySlot):
	_update_info_panel(slot)

func _on_slot_double_clicked(slot: InventorySlot):
	if not slot.has_item():
		return
	
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		return
	
	if slot.slot_type == InventorySlot.SlotType.INVENTORY:
		_try_equip_item(slot)
	else:
		_try_unequip_item(slot)

func _on_drag_started(slot: InventorySlot):
	## Track drag source for drop-outside-panel detection
	_drag_source_slot = slot
	_drag_item_data = slot.item_data.duplicate(true)

func _on_drag_ended(source: InventorySlot, target: InventorySlot):
	# Clear drag tracking since it ended on a valid slot
	_drag_source_slot = null
	_drag_item_data = {}
	
	if source == target:
		return
	
	if source.slot_type == InventorySlot.SlotType.INVENTORY:
		if target.slot_type == InventorySlot.SlotType.INVENTORY:
			_swap_items(source, target)
		else:
			_try_equip_to_slot(source, target)
	else:
		if target.slot_type == InventorySlot.SlotType.INVENTORY:
			_try_unequip_item(source)
		else:
			_swap_items(source, target)

func _on_slot_hovered(slot: InventorySlot):
	_update_info_panel(slot)

func _on_slot_unhovered():
	_update_info_panel(null)

func _on_slot_right_clicked(slot: InventorySlot, mouse_pos: Vector2):
	## Show context menu for the slot
	if not slot.has_item():
		return
	
	_context_menu_slot = slot
	_context_menu.clear()
	
	var data = slot.item_data
	var item_type = data.get("type", "")
	var is_equipment_slot = slot.slot_type != InventorySlot.SlotType.INVENTORY
	
	# Menu item IDs
	const ID_EQUIP = 0
	const ID_UNEQUIP = 1
	const ID_DROP = 2
	const ID_INSPECT = 3
	
	# Add menu items based on context
	if is_equipment_slot:
		_context_menu.add_item("Unequip", ID_UNEQUIP)
	else:
		if item_type == "weapon" or item_type == "armor" or item_type == "helmet" or item_type == "gadget" or item_type == "consumable":
			_context_menu.add_item("Equip", ID_EQUIP)
	
	_context_menu.add_separator()
	_context_menu.add_item("Drop", ID_DROP)
	
	# Position and show menu
	_context_menu.position = Vector2i(mouse_pos)
	_context_menu.popup()

func _on_context_menu_selected(id: int):
	## Handle context menu selection
	if not _context_menu_slot or not _context_menu_slot.has_item():
		return
	
	const ID_EQUIP = 0
	const ID_UNEQUIP = 1
	const ID_DROP = 2
	const ID_INSPECT = 3
	
	match id:
		ID_EQUIP:
			_try_equip_item(_context_menu_slot)
		ID_UNEQUIP:
			_try_unequip_item(_context_menu_slot)
		ID_DROP:
			_drop_item_in_world(_context_menu_slot, _context_menu_slot.item_data.duplicate(true))
	
	_context_menu_slot = null
#endregion

#region Item Operations
func _try_equip_item(slot: InventorySlot):
	## Try to equip item to appropriate slot
	var data = slot.item_data
	var item_type = data.get("type", "")

	if item_type == "weapon":
		# Find best weapon slot: prefer empty slot matching holster preference, then any empty, then first slot
		var weapon_slot_names = ["weapon_1", "weapon_2", "weapon_3"]
		var holster_slot = data.get("holster_slot", "")

		# Determine preferred slot based on holster type
		var preferred_slot_index = 0
		if holster_slot in ["back_primary", "back_secondary"]:
			preferred_slot_index = 0  # Large weapons prefer slot 1
		elif holster_slot in ["hip_right", "hip_left", "thigh_right", "thigh_left"]:
			preferred_slot_index = 2  # Small weapons prefer slot 3
		else:
			preferred_slot_index = 1  # Medium weapons prefer slot 2

		# Try preferred slot first if empty
		var preferred_name = weapon_slot_names[preferred_slot_index]
		if equipment_slots.has(preferred_name) and not equipment_slots[preferred_name].has_item():
			_try_equip_to_slot(slot, equipment_slots[preferred_name])
			return

		# Try to find any empty weapon slot
		for slot_name in weapon_slot_names:
			if equipment_slots.has(slot_name) and not equipment_slots[slot_name].has_item():
				_try_equip_to_slot(slot, equipment_slots[slot_name])
				return

		# All slots full - swap with preferred slot
		if equipment_slots.has(preferred_name):
			_try_equip_to_slot(slot, equipment_slots[preferred_name])
	elif item_type == "armor":
		if equipment_slots.has("armor"):
			_try_equip_to_slot(slot, equipment_slots["armor"])
	elif item_type == "helmet":
		if equipment_slots.has("head"):
			_try_equip_to_slot(slot, equipment_slots["head"])
	elif item_type == "gadget":
		if equipment_slots.has("gadget"):
			_try_equip_to_slot(slot, equipment_slots["gadget"])
	elif item_type == "consumable":
		if equipment_slots.has("consumable"):
			_try_equip_to_slot(slot, equipment_slots["consumable"])

func _try_equip_to_slot(source: InventorySlot, target: InventorySlot):
	var slot_name = _get_slot_name(target.slot_type)
	if slot_name.is_empty():
		return
	
	# Save source data BEFORE any modifications (deep copy to prevent reference issues)
	var source_data = source.item_data.duplicate(true)
	var source_inv_id = source.inventory_id
	
	# If target has item, swap (deep copy)
	var old_item = target.item_data.duplicate(true)
	var old_inv_id = target.inventory_id
	
	# Remove from local inventory if it was there
	var item_id = source_data.get("item_id", "")
	for i in range(_local_inventory_items.size() - 1, -1, -1):
		if _local_inventory_items[i].get("item_id", "") == item_id:
			_local_inventory_items.remove_at(i)
			print("[Inventory] Removed from local inventory: ", source_data.get("name", "unknown"))
			break
	
	# Try database first, but proceed even if it fails
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db and source_inv_id >= 0:
		item_db.equip_item(_character_id, slot_name, source_inv_id)
	
	# Update UI
	target.set_item(source_data, source_inv_id)
	
	if not old_item.is_empty():
		source.set_item(old_item, old_inv_id)
		# Add swapped item to local inventory
		_local_inventory_items.append(old_item)
		print("[Inventory] Added swapped item to local inventory: ", old_item.get("name", "unknown"))
	else:
		source.clear_item()
	
	# Notify equipment manager to actually equip the weapon (use saved data!)
	_notify_equipment_change(slot_name, source_data)
	item_equipped.emit(slot_name, source_data)
	_update_capacity()
	print("[Inventory] Equipped to ", slot_name, ": ", source_data.get("name", "unknown"))

func _try_unequip_item(slot: InventorySlot):
	var slot_name = _get_slot_name(slot.slot_type)
	if slot_name.is_empty():
		return
	
	# Check inventory capacity (local items + inventory slots in use)
	var used_slots = 0
	for inv_slot in inventory_slots:
		if inv_slot.has_item():
			used_slots += 1
	
	if used_slots >= inventory_slots.size():
		print("[Inventory] Inventory full - can't unequip!")
		return
	
	# Find empty inventory slot
	var empty_slot: InventorySlot = null
	for inv_slot in inventory_slots:
		if not inv_slot.has_item():
			empty_slot = inv_slot
			break
	
	if not empty_slot:
		print("[Inventory] No empty slot found - can't unequip!")
		return
	
	# Save item data BEFORE clearing (critical - deep copy!)
	var item_data_copy = slot.item_data.duplicate(true)
	var item_inv_id = slot.inventory_id
	
	# Request unequip from server (server handles database)
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db:
		# Save weapon state if EquipmentManager has it (server will persist)
		if _equipment_manager and _equipment_manager.has_method("get_all_weapon_states") and item_inv_id >= 0:
			var all_states = _equipment_manager.get_all_weapon_states()
			if all_states.has(slot_name) and all_states[slot_name].has("state"):
				# TODO: RPC to save weapon state on server
				print("[Inventory] Would save weapon state for: ", slot_name)
		
		# Request server to unequip (server updates database)
		if item_db.has_method("request_unequip"):
			item_db.request_unequip(slot_name)
		else:
			# Fallback for local/server
			item_db.unequip_slot(_character_id, slot_name)
	
	print("[Inventory] Requested unequip: ", slot_name)
	
	# Move item to inventory slot visually
	empty_slot.set_item(item_data_copy, item_inv_id)
	slot.clear_item()
	
	# Notify equipment manager to holster/remove the weapon
	_notify_equipment_unequip(slot_name)
	item_unequipped.emit(slot_name)
	_update_capacity()
	print("[Inventory] Unequipped: ", slot_name, " inv_id=", item_inv_id)

func _swap_items(slot_a: InventorySlot, slot_b: InventorySlot):
	var data_a = slot_a.item_data.duplicate(true)
	var inv_id_a = slot_a.inventory_id
	
	var data_b = slot_b.item_data.duplicate(true)
	var inv_id_b = slot_b.inventory_id
	
	if data_b.is_empty():
		slot_b.set_item(data_a, inv_id_a)
		slot_a.clear_item()
	else:
		slot_a.set_item(data_b, inv_id_b)
		slot_b.set_item(data_a, inv_id_a)

func _on_items_stacked(source_slot: InventorySlot, target_slot: InventorySlot):
	## Combine stacks when same stackable items are dropped on each other
	# Clear drag tracking
	_drag_source_slot = null
	_drag_item_data = {}
	
	var source_data = source_slot.item_data.duplicate(true)
	var target_data = target_slot.item_data.duplicate(true)
	
	var source_qty = source_data.get("quantity", 1)
	var target_qty = target_data.get("quantity", 1)
	var max_stack = target_data.get("max_stack", 999)
	
	# Calculate how much can be added to target
	var space_available = max_stack - target_qty
	var amount_to_transfer = mini(source_qty, space_available)
	
	if amount_to_transfer <= 0:
		print("[Inventory] Stack full, cannot combine")
		return
	
	# Update target quantity
	target_data["quantity"] = target_qty + amount_to_transfer
	target_slot.set_item(target_data, target_slot.inventory_id)
	
	# Update or clear source
	var remaining = source_qty - amount_to_transfer
	if remaining > 0:
		source_data["quantity"] = remaining
		source_slot.set_item(source_data, source_slot.inventory_id)
	else:
		source_slot.clear_item()
	
	# TODO: Update database
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db and item_db.has_method("update_item_quantity"):
		if target_slot.inventory_id >= 0:
			item_db.update_item_quantity(target_slot.inventory_id, target_data["quantity"])
		if source_slot.inventory_id >= 0 and remaining > 0:
			item_db.update_item_quantity(source_slot.inventory_id, remaining)
		elif source_slot.inventory_id >= 0 and remaining == 0:
			item_db.remove_from_inventory(_character_id, source_slot.inventory_id)
	
	print("[Inventory] Stacked %d items (target now has %d)" % [amount_to_transfer, target_data["quantity"]])
	_update_capacity()

func _get_slot_name(slot_type: InventorySlot.SlotType) -> String:
	match slot_type:
		InventorySlot.SlotType.EQUIPMENT_WEAPON_1: return "weapon_1"
		InventorySlot.SlotType.EQUIPMENT_WEAPON_2: return "weapon_2"
		InventorySlot.SlotType.EQUIPMENT_WEAPON_3: return "weapon_3"
		InventorySlot.SlotType.EQUIPMENT_HEAD: return "head"
		InventorySlot.SlotType.EQUIPMENT_ARMOR: return "armor"
		InventorySlot.SlotType.EQUIPMENT_GADGET: return "gadget"
		InventorySlot.SlotType.EQUIPMENT_CONSUMABLE: return "consumable"
	return ""

func _notify_equipment_change(slot_name: String, item_data: Dictionary):
	if _equipment_manager and _equipment_manager.has_method("equip_weapon"):
		_equipment_manager.equip_weapon(slot_name, item_data)

func _notify_equipment_unequip(slot_name: String):
	if _equipment_manager and _equipment_manager.has_method("unequip_weapon"):
		_equipment_manager.unequip_weapon(slot_name)

func _update_capacity():
	if not capacity_label:
		return
	
	# Count items in inventory slots
	var inv_count = 0
	for slot in inventory_slots:
		if slot.has_item():
			inv_count += 1
	
	# Count equipped items
	var equip_count = 0
	for slot_name in equipment_slots:
		if equipment_slots[slot_name] and equipment_slots[slot_name].has_item():
			equip_count += 1
	
	var total = inv_count + equip_count
	var max_slots = inventory_slots.size() + 8 # 8 equipment slots
	capacity_label.text = "%d / %d" % [total, max_slots]
#endregion

#region Info Panel
func _update_info_panel(slot: InventorySlot):
	if slot == null or not slot.has_item():
		# Empty state
		if info_icon_label:
			info_icon_label.text = ""
		if info_name:
			info_name.text = "Hover over an item"
		if info_type:
			info_type.text = "to see details"
		if info_description:
			info_description.text = ""
		if stat1_value:
			stat1_value.text = "--"
		if stat2_value:
			stat2_value.text = "--"
		if stat3_value:
			stat3_value.text = "--"
		return
	
	var data = slot.item_data
	var rarity = data.get("rarity", "common")
	var rarity_color = InventorySlot.RARITY_COLORS.get(rarity, Color.WHITE)
	
	# Icon
	if info_icon_label:
		var subtype = data.get("subtype", "misc")
		info_icon_label.text = InventorySlot.TYPE_ICONS.get(subtype, "📦")
		info_icon_label.modulate = rarity_color
	
	# Name with rarity color
	if info_name:
		info_name.text = data.get("name", "Unknown")
		info_name.modulate = rarity_color
	
	# Type/subtype
	if info_type:
		var type_text = data.get("subtype", data.get("type", "item")).to_upper()
		var item_size = data.get("size", "")
		if item_size:
			type_text += " • " + item_size.to_upper()
		info_type.text = type_text
	
	# Description
	if info_description:
		info_description.text = "[i]%s[/i]" % data.get("description", "")
	
	# Stats (for weapons)
	if data.get("type") == "weapon":
		if stat1_value:
			stat1_value.text = str(int(data.get("damage", 0)))
		if stat2_value:
			stat2_value.text = "%.1f" % data.get("fire_rate", 0)
		if stat3_value:
			stat3_value.text = "%dm" % int(data.get("range", 0))
	else:
		if stat1_value:
			stat1_value.text = "--"
		if stat2_value:
			stat2_value.text = "--"
		if stat3_value:
			stat3_value.text = "--"
#endregion

#region World Drop
func _drop_item_in_world(slot: InventorySlot, data: Dictionary):
	## Drop an item from inventory into the 3D world
	if not _player:
		push_warning("[Inventory] Cannot drop item - no player reference")
		return
	
	var item_type = data.get("type", "")
	var item_name = data.get("name", "Item")
	
	# Calculate drop position in front of player
	var drop_position = _player.global_position + Vector3.UP * 1.0
	if _player.has_method("get_aim_direction"):
		drop_position += _player.get_aim_direction() * 1.5
	else:
		drop_position += -_player.global_basis.z * 1.5
	
	# Create the appropriate dropped item type
	var dropped_item: Node = null
	
	if item_type == "weapon":
		dropped_item = _create_dropped_weapon(data, drop_position)
	elif item_type == "ammo":
		dropped_item = _create_dropped_ammo(data, drop_position)
	else:
		dropped_item = _create_dropped_generic(data, drop_position)
	
	if dropped_item:
		# Add to scene
		get_tree().current_scene.add_child(dropped_item)
		
		# Apply drop force
		if dropped_item.has_method("drop_with_force"):
			var direction = (-_player.global_basis.z + Vector3.UP * 0.5).normalized()
			dropped_item.drop_with_force(direction, 3.0)
		
		# If this is an equipment slot, unequip from EquipmentManager first
		if slot.slot_type != InventorySlot.SlotType.INVENTORY:
			var slot_name = _get_slot_name(slot.slot_type)
			if not slot_name.is_empty():
				_notify_equipment_unequip(slot_name)
				print("[Inventory] Unequipped %s from EquipmentManager" % slot_name)
		
		# Remove from slot and inventory
		_remove_item_from_slot(slot)
		
		print("[Inventory] Dropped %s at %s" % [item_name, drop_position])
		item_dropped.emit(data, drop_position)

func _create_dropped_weapon(data: Dictionary, drop_pos: Vector3) -> Node:
	## Create a dropped weapon pickup
	var scene = load("res://addons/gsg-godot-plugins/item_system/dropped_weapon.tscn")
	if not scene:
		# Use generic if weapon scene doesn't exist
		return _create_dropped_generic(data, drop_pos)
	
	var dropped = scene.instantiate() as DroppedWeapon
	dropped.global_position = drop_pos
	dropped.setup_from_data(data)
	return dropped

func _create_dropped_ammo(data: Dictionary, drop_pos: Vector3) -> Node:
	## Create a dropped ammo pickup (uses generic for now)
	return _create_dropped_generic(data, drop_pos)

func _create_dropped_generic(data: Dictionary, drop_pos: Vector3) -> Node:
	## Create a generic dropped item pickup
	var scene = load("res://prefabs/pickups/dropped_item.tscn")
	if not scene:
		# Fallback - create inline
		var item = DroppedItem.new()
		item.global_position = drop_pos
		item.setup(data)
		return item
	
	var dropped = scene.instantiate()
	dropped.global_position = drop_pos
	if dropped.has_method("setup"):
		dropped.setup(data)
	return dropped

func _remove_item_from_slot(slot: InventorySlot):
	## Remove item from both UI and database
	var data = slot.item_data
	var inv_id = slot.inventory_id
	
	# Remove from local storage
	var _item_id = data.get("item_id", "")
	for i in range(_local_inventory_items.size() - 1, -1, -1):
		if _local_inventory_items[i].get("item_id", "") == _item_id:
			_local_inventory_items.remove_at(i)
			break
	
	# Remove from database
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db and inv_id >= 0 and _character_id > 0:
		if slot.slot_type == InventorySlot.SlotType.INVENTORY:
			# remove_from_inventory takes only inventory_id, not character_id
			item_db.remove_from_inventory(inv_id)
		else:
			var slot_name = _get_slot_name(slot.slot_type)
			if slot_name:
				item_db.unequip_slot(_character_id, slot_name)
	
	# Clear the slot UI
	slot.clear_item()
	
	# Refresh to update capacity
	_update_capacity()
#endregion

#region Open/Close
func open():
	visible = true
	refresh()
	# Enter talking state (single source of truth for mouse visibility)
	_ensure_talking_state()

func close():
	visible = false
	closed.emit()
	# Exit talking state - it will check if other UIs still need mouse
	_exit_talking_state()

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
