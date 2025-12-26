extends Node
class_name EquipmentManager

## EquipmentManager - Manages equipped weapons, cycling, and holstering
## Attach as child of player entity

#region Signals
signal weapon_changed(slot: String, weapon: Node3D)
signal weapon_drawn(weapon: Node3D)
signal weapon_holstered()
signal all_weapons_holstered()
signal reload_requested()
#endregion

#region Configuration
@export_group("Equipment Slots")
## 3 generic weapon slots - any weapon can go in any slot
@export var weapon_slot_1: String = "weapon_1"
@export var weapon_slot_2: String = "weapon_2"
@export var weapon_slot_3: String = "weapon_3"

@export_group("Input Actions")
@export var action_next_weapon: String = "weapon_next"
@export var action_prev_weapon: String = "weapon_prev"
@export var action_holster: String = "holster"
@export var action_reload: String = "reload"
@export var action_fire: String = "fire"
@export var action_aim: String = "aim"

@export_group("Timing")
@export var weapon_switch_time: float = 0.0  # Instant switch
@export var holster_time: float = 0.0
@export var draw_time: float = 0.0
#endregion

#region Runtime State
var equipped_weapons: Dictionary = {}  # slot_name -> WeaponComponent
var weapon_instances: Dictionary = {}  # slot_name -> Node3D (the actual scene instance)
var weapon_inventory_ids: Dictionary = {}  # slot_name -> inventory_id (for saving state)
var weapon_prefab_paths: Dictionary = {}  # slot_name -> prefab_path (for re-equipping from inventory)
var current_slot: String = ""
var current_weapon: Node3D = null  # Currently active weapon instance

var is_switching: bool = false
var is_holstered: bool = true
var is_aiming: bool = false

var _switch_timer: float = 0.0
var _pending_slot: String = ""
var _slot_cycle: Array[String] = []

var _owner_entity: Node3D = null
var _holster_system: Node = null
var _weapon_ik: Node = null
var _attachment_setup: Node = null  # WeaponAttachmentSetup
var _player_camera: Node = null
#endregion

## Auto-save interval in seconds (saves ammo state periodically)
@export var auto_save_interval: float = 30.0
var _auto_save_timer: float = 0.0

func _ready():
	_owner_entity = get_parent()

	# Setup slot cycle order - 3 generic weapon slots
	_slot_cycle = [weapon_slot_1, weapon_slot_2, weapon_slot_3]
	
	# Find attachment systems (prefer new WeaponAttachmentSetup)
	_attachment_setup = _owner_entity.get_node_or_null("WeaponAttachmentSetup")
	_holster_system = _owner_entity.get_node_or_null("HolsterSystem")
	_weapon_ik = _owner_entity.get_node_or_null("WeaponIKController")
	_player_camera = _owner_entity.get_node_or_null("PlayerCamera")
	
	# Register input actions if they don't exist
	_ensure_input_actions()
	_ensure_drop_action()
	
	# Connect to tree exiting for save on scene change
	tree_exiting.connect(_on_tree_exiting)

func _ensure_input_actions():
	if not InputMap.has_action(action_next_weapon):
		InputMap.add_action(action_next_weapon)
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_WHEEL_UP
		InputMap.action_add_event(action_next_weapon, event)
	
	if not InputMap.has_action(action_prev_weapon):
		InputMap.add_action(action_prev_weapon)
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_WHEEL_DOWN
		InputMap.action_add_event(action_prev_weapon, event)
	
	if not InputMap.has_action(action_holster):
		InputMap.add_action(action_holster)
		var event = InputEventKey.new()
		event.keycode = KEY_H
		InputMap.action_add_event(action_holster, event)
	
	if not InputMap.has_action(action_reload):
		InputMap.add_action(action_reload)
		var event = InputEventKey.new()
		event.keycode = KEY_R
		InputMap.action_add_event(action_reload, event)

func _input(event: InputEvent):
	# Only process input for local player (includes window focus check)
	if not _is_local_player():
		return
	
	# Weapon cycling
	if event.is_action_pressed(action_next_weapon):
		cycle_weapon(1)
	elif event.is_action_pressed(action_prev_weapon):
		cycle_weapon(-1)
	
	# Holster toggle
	if event.is_action_pressed(action_holster):
		toggle_holster()
	
	# Drop weapon (Q key)
	if event.is_action_pressed(action_drop_weapon):
		drop_current_weapon()
	
	# Reload
	if event.is_action_pressed(action_reload):
		try_reload()
	
	# Aiming
	if event.is_action_pressed(action_aim):
		set_aiming(true)
	elif event.is_action_released(action_aim):
		set_aiming(false)

func _process(delta: float):
	# Handle weapon switch timing
	if is_switching:
		_switch_timer -= delta
		if _switch_timer <= 0:
			_complete_switch()
	
	# Handle firing (held input) - block when UI is open or in dialogue
	if _is_local_player() and not is_holstered and current_weapon:
		if not _is_input_blocked() and Input.is_action_pressed(action_fire):
			try_fire()
	
	# Auto-save timer (only on server or for local player)
	if auto_save_interval > 0 and equipped_weapons.size() > 0:
		_auto_save_timer += delta
		if _auto_save_timer >= auto_save_interval:
			_auto_save_timer = 0.0
			save_all_weapon_states()

func _on_tree_exiting():
	## Called when scene is changing or player being removed
	save_all_weapon_states()

func _is_local_player() -> bool:
	if _owner_entity and "can_receive_input" in _owner_entity:
		return _owner_entity.can_receive_input
	return false

func _is_input_blocked() -> bool:
	## Check if input should be blocked (dialogue, UI open, etc.)
	# Use player's built-in dialogue check if available
	if _owner_entity and _owner_entity.has_method("_is_in_dialogue"):
		if _owner_entity._is_in_dialogue():
			return true

	# Check for UI that needs mouse (shop, dialogue, inventory, etc.)
	var ui_nodes = get_tree().get_nodes_in_group("ui_needs_mouse")
	for ui in ui_nodes:
		if is_instance_valid(ui) and ui is Control and ui.visible:
			return true

	return false

func _hide_preview_weapon(_slot: String):
	## Hide preview weapons when any weapon is equipped
	## With 3 generic slots, just hide all preview weapons
	if not _owner_entity:
		return

	for preview_name in ["PreviewRifle", "PreviewPistol", "PreviewSaber"]:
		var preview = _owner_entity.find_child(preview_name, true, false)
		if preview and preview is Node3D:
			preview.visible = false

func _show_preview_weapon(_slot: String):
	## Show preview weapons when slot is empty
	## Only show if no weapons are equipped in any slot
	if not _owner_entity:
		return

	# Only show previews if ALL weapon slots are empty
	if weapon_instances.size() > 0:
		return

	for preview_name in ["PreviewRifle", "PreviewPistol", "PreviewSaber"]:
		var preview = _owner_entity.find_child(preview_name, true, false)
		if preview and preview is Node3D:
			preview.visible = true

#region Weapon Management
func equip_weapon(slot: String, weapon_data: Dictionary) -> bool:
	## Equip a weapon to a slot from database data
	print("[EquipmentManager] equip_weapon called - slot: ", slot, " data keys: ", weapon_data.keys())
	
	var prefab_path = weapon_data.get("prefab_path", "")
	print("[EquipmentManager] prefab_path: ", prefab_path)
	
	if prefab_path.is_empty():
		push_error("[EquipmentManager] No prefab_path in weapon data for slot %s: %s" % [slot, weapon_data])
		return false
	
	if not ResourceLoader.exists(prefab_path):
		push_error("[EquipmentManager] Weapon prefab not found for slot %s: %s" % [slot, prefab_path])
		return false
	
	# Remove existing weapon in slot
	if weapon_instances.has(slot):
		var old_weapon = weapon_instances[slot]
		if is_instance_valid(old_weapon):
			# Remove from holster system first
			if _holster_system and _holster_system.has_method("remove_weapon"):
				_holster_system.remove_weapon(old_weapon)
			elif _attachment_setup and _attachment_setup.has_method("remove_weapon"):
				_attachment_setup.remove_weapon(old_weapon)
			# Remove from parent before freeing
			if old_weapon.get_parent():
				old_weapon.get_parent().remove_child(old_weapon)
			old_weapon.queue_free()
		weapon_instances.erase(slot)
		equipped_weapons.erase(slot)
	
	# Load and instantiate weapon
	var prefab = load(prefab_path)
	if not prefab:
		push_error("[EquipmentManager] Failed to load prefab for slot %s: %s" % [slot, prefab_path])
		return false
	
	var weapon_instance = prefab.instantiate()
	print("[EquipmentManager] Instantiated weapon '%s' for slot %s" % [weapon_instance.name, slot])
	
	# Check if it's a melee weapon (duck typing to avoid load order issues)
	var melee_component = _get_melee_component_from(weapon_instance)
	
	if melee_component:
		# It's a melee weapon
		melee_component.load_from_database(weapon_data)
		melee_component.set_weapon_owner(_owner_entity)
		equipped_weapons[slot] = melee_component
	else:
		# It's a ranged weapon - WeaponComponent
		var weapon_component = weapon_instance.get_node_or_null("WeaponComponent")
		if not weapon_component and weapon_instance.get_script():
			var script_name = weapon_instance.get_script().get_global_name()
			if script_name == "WeaponComponent":
				weapon_component = weapon_instance
		
		if weapon_component:
			weapon_component.load_from_database(weapon_data)
			weapon_component.set_weapon_owner(_owner_entity)
			
			# Load saved instance state (ammo, heat, etc.) if available
			if weapon_data.has("instance_state"):
				weapon_component.load_instance_state(weapon_data.instance_state)
				print("[EquipmentManager] Loaded saved weapon state: ", weapon_data.instance_state)
			
			equipped_weapons[slot] = weapon_component
	
	weapon_instances[slot] = weapon_instance
	
	# Store inventory_id for saving state later
	if weapon_data.has("inventory_id"):
		weapon_inventory_ids[slot] = weapon_data.inventory_id
	
	# Store prefab path for re-equipping from inventory
	weapon_prefab_paths[slot] = prefab_path
	
	# Initially holster the weapon
	var holster_slot_name = weapon_data.get("holster_slot", "back_primary")
	if _attachment_setup and _attachment_setup.has_method("holster_weapon"):
		_attachment_setup.holster_weapon(weapon_instance, holster_slot_name)
	elif _holster_system:
		_holster_system.holster_weapon(weapon_instance, holster_slot_name)
	else:
		# No holster system - just hide it
		weapon_instance.visible = false
		_owner_entity.add_child(weapon_instance)
	
	weapon_changed.emit(slot, weapon_instance)

	# Hide preview weapons for this slot (both local and remote players)
	_hide_preview_weapon(slot)

	# Broadcast to other clients (only if local player)
	if _is_local_player():
		var network = get_node_or_null("/root/NetworkManager")
		if network and network.has_method("broadcast_weapon_equip"):
			network.broadcast_weapon_equip(slot, weapon_data)
	
	# If no current weapon, this becomes current and auto-draw
	if current_slot.is_empty():
		current_slot = slot
		# Auto-draw first weapon
		call_deferred("draw_current")
	
	return true

func unequip_weapon(slot: String):
	if not weapon_instances.has(slot):
		return
	
	# Save weapon state before unequipping (ammo, heat, etc.)
	var inv_id = weapon_inventory_ids.get(slot, -1)
	if inv_id > 0:
		var weapon_comp = equipped_weapons.get(slot)
		if weapon_comp and weapon_comp.has_method("get_instance_state"):
			var state = weapon_comp.get_instance_state()
			var item_db = get_node_or_null("/root/ItemDatabase")
			if item_db and item_db.has_method("save_weapon_state"):
				item_db.save_weapon_state(inv_id, state)
				print("[EquipmentManager] Saved weapon state before unequipping: ", slot, " inv_id=", inv_id)
	
	# If this is current weapon, holster first
	if slot == current_slot and not is_holstered:
		holster_current()
	
	var weapon = weapon_instances[slot]
	if is_instance_valid(weapon):
		# Remove from holster system first
		if _holster_system and _holster_system.has_method("remove_weapon"):
			_holster_system.remove_weapon(weapon)
		elif _attachment_setup and _attachment_setup.has_method("remove_weapon"):
			_attachment_setup.remove_weapon(weapon)
		# Remove from parent before freeing
		if weapon.get_parent():
			weapon.get_parent().remove_child(weapon)
		weapon.queue_free()
	
	weapon_instances.erase(slot)
	equipped_weapons.erase(slot)
	weapon_prefab_paths.erase(slot)
	weapon_inventory_ids.erase(slot)
	
	# Select next available weapon
	if slot == current_slot:
		current_slot = ""
		current_weapon = null
		for s in _slot_cycle:
			if weapon_instances.has(s):
				current_slot = s
				break
	
	weapon_changed.emit(slot, null)

	# Show preview weapon for this slot again (both local and remote players)
	_show_preview_weapon(slot)
	
	# Broadcast unequip to network
	_broadcast_weapon_unequip(slot)

func _broadcast_weapon_unequip(slot: String):
	## Broadcast weapon unequip to other clients (local player only)
	if not _is_local_player():
		return  # Only local player broadcasts their own state
	
	var network = get_node_or_null("/root/NetworkManager")
	if not network:
		return
	
	# Send empty weapon data to indicate slot is now empty
	if network.has_method("broadcast_weapon_equip"):
		network.broadcast_weapon_equip(slot, {})

func _broadcast_weapon_state(slot: String, holstered: bool):
	## Broadcast weapon draw/holster state to other clients (local player only)
	if not _is_local_player():
		return  # Only local player broadcasts their own state
	
	var network = get_node_or_null("/root/NetworkManager")
	if not network:
		return
	
	if network.has_method("broadcast_weapon_state"):
		network.broadcast_weapon_state(slot, holstered)
#endregion

#region Weapon Cycling
func cycle_weapon(direction: int):
	if is_switching:
		return
	
	if weapon_instances.size() <= 1:
		return
	
	# Find current index in cycle
	var current_idx = _slot_cycle.find(current_slot)
	if current_idx < 0:
		current_idx = 0
	
	# Find next valid slot
	var attempts = _slot_cycle.size()
	while attempts > 0:
		current_idx = (current_idx + direction) % _slot_cycle.size()
		if current_idx < 0:
			current_idx = _slot_cycle.size() - 1
		
		var slot = _slot_cycle[current_idx]
		if weapon_instances.has(slot) and slot != current_slot:
			switch_to_slot(slot)
			return
		
		attempts -= 1

func switch_to_slot(slot: String):
	if not weapon_instances.has(slot):
		return
	
	if slot == current_slot and not is_holstered:
		return
	
	is_switching = true
	_pending_slot = slot
	
	if is_holstered:
		# Just draw the new weapon
		_switch_timer = draw_time
	else:
		# Holster current, then draw new
		_switch_timer = weapon_switch_time
		_holster_current_weapon()
	
	current_slot = slot

func _complete_switch():
	is_switching = false
	
	if _pending_slot.is_empty():
		return
	
	# Draw the new weapon
	_draw_weapon(_pending_slot)
	_pending_slot = ""

func _holster_current_weapon():
	if not current_weapon:
		return
	
	var weapon_comp = equipped_weapons.get(current_slot)  # WeaponComponent
	var holster_slot = "back_primary"
	if weapon_comp and weapon_comp.holster_slot:
		holster_slot = weapon_comp.holster_slot
	
	# Use new attachment setup if available
	if _attachment_setup and _attachment_setup.has_method("holster_weapon"):
		if _attachment_setup.has_method("detach_weapon"):
			_attachment_setup.detach_weapon()
		_attachment_setup.holster_weapon(current_weapon, holster_slot)
	elif _holster_system:
		_holster_system.holster_weapon(current_weapon, holster_slot)
	else:
		current_weapon.visible = false

func _draw_weapon(slot: String):
	print("[EquipmentManager] _draw_weapon called for slot: ", slot)
	if not weapon_instances.has(slot):
		print("[EquipmentManager] No weapon in slot: ", slot)
		return

	current_weapon = weapon_instances[slot]
	current_slot = slot
	is_holstered = false

	# Use new attachment setup if available
	if _attachment_setup and _attachment_setup.has_method("attach_weapon"):
		print("[EquipmentManager] Using WeaponAttachmentSetup to attach: ", current_weapon.name)
		_attachment_setup.attach_weapon(current_weapon)
	elif _holster_system:
		print("[EquipmentManager] Using legacy HolsterSystem")
		_holster_system.draw_weapon(current_weapon)
		# Notify legacy weapon IK
		if _weapon_ik and _weapon_ik.has_method("set_weapon"):
			_weapon_ik.set_weapon(current_weapon)
	else:
		print("[EquipmentManager] No attachment system, just showing weapon")
		current_weapon.visible = true
	
	# Broadcast weapon draw to network
	_broadcast_weapon_state(slot, false)  # false = drawn (not holstered)
	
	weapon_drawn.emit(current_weapon)
#endregion

#region Holster
func toggle_holster():
	if is_switching:
		return
	
	if is_holstered:
		draw_current()
	else:
		holster_current()

func holster_current():
	if is_holstered or not current_weapon:
		return
	
	# Save weapon state before holstering
	if current_slot != "":
		var inv_id = weapon_inventory_ids.get(current_slot, -1)
		if inv_id > 0:
			var weapon_comp = equipped_weapons.get(current_slot)
			if weapon_comp and weapon_comp.has_method("get_instance_state"):
				var state = weapon_comp.get_instance_state()
				var item_db = get_node_or_null("/root/ItemDatabase")
				if item_db and item_db.has_method("save_weapon_state"):
					item_db.save_weapon_state(inv_id, state)
	
	is_holstered = true
	is_aiming = false
	
	_holster_current_weapon()
	
	# Notify legacy weapon IK (new setup handles this in detach_weapon)
	if not _attachment_setup and _weapon_ik and _weapon_ik.has_method("set_weapon"):
		_weapon_ik.set_weapon(null)
	
	weapon_holstered.emit()
	
	# Broadcast holster to network
	_broadcast_weapon_state(current_slot, true)  # true = holstered

func draw_current():
	if not is_holstered:
		return
	
	if current_slot.is_empty():
		# Find first available weapon
		for slot in _slot_cycle:
			if weapon_instances.has(slot):
				current_slot = slot
				break
	
	if current_slot.is_empty():
		return  # No weapons equipped
	
	is_switching = true
	_switch_timer = draw_time
	_pending_slot = current_slot

func holster_all():
	holster_current()
	all_weapons_holstered.emit()

func apply_remote_state(target_slot: String, target_holstered: bool):
	## For remote players: directly apply equipment state without timers
	## This bypasses the timer-based switching which can cause sync issues

	# Cancel any in-progress switch
	is_switching = false
	_pending_slot = ""

	# Step 1: If we need to switch slots, holster old weapon first
	var slot_changed = false
	if not target_slot.is_empty() and weapon_instances.has(target_slot):
		if current_slot != target_slot:
			slot_changed = true
			# Holster current weapon directly (no timer)
			if current_weapon and not is_holstered:
				_holster_current_weapon()
				is_holstered = true  # Mark as holstered after holstering old weapon
			# Update to new slot
			current_slot = target_slot
			current_weapon = weapon_instances[target_slot]

	# Step 2: Apply holster state
	if target_holstered:
		# Should be holstered
		if not is_holstered and current_weapon:
			_holster_current_weapon()
			is_holstered = true
			# Don't broadcast - this is a remote player receiving state
	else:
		# Should be drawn - either because we need to draw, or we just switched slots
		if (is_holstered or slot_changed) and not current_slot.is_empty() and weapon_instances.has(current_slot):
			# Draw weapon directly (no timer)
			current_weapon = weapon_instances[current_slot]
			is_holstered = false
			if _attachment_setup and _attachment_setup.has_method("attach_weapon"):
				_attachment_setup.attach_weapon(current_weapon)
			elif _holster_system and _holster_system.has_method("draw_weapon"):
				_holster_system.draw_weapon(current_weapon)
			else:
				current_weapon.visible = true
			# Don't broadcast - this is a remote player receiving state
#endregion

#region Combat Actions
func try_fire() -> bool:
	if is_holstered or is_switching:
		return false
	
	# Check if melee weapon - use attack instead
	if is_current_weapon_melee():
		return try_attack()
	
	var weapon_comp = get_current_weapon_component()
	if weapon_comp:
		return weapon_comp.try_fire()
	
	return false

func try_attack() -> bool:
	## Try to attack with melee weapon
	if is_holstered or is_switching:
		return false
	
	var melee_comp = get_current_melee_component()
	if melee_comp:
		return melee_comp.try_attack()
	
	return false

func try_block(blocking: bool):
	## Start or stop blocking with melee weapon
	var melee_comp = get_current_melee_component()
	if melee_comp:
		if blocking:
			melee_comp.start_block()
		else:
			melee_comp.stop_block()

func try_reload():
	if is_holstered or is_switching:
		return
	
	var weapon_comp = get_current_weapon_component()
	if weapon_comp and weapon_comp.can_reload():
		weapon_comp.try_reload()
		reload_requested.emit()

func set_aiming(aiming: bool):
	if is_holstered:
		is_aiming = false
		return
	
	is_aiming = aiming
	
	var weapon_comp = get_current_weapon_component()
	if weapon_comp:
		if weapon_comp.has_method("set_aiming"):
			weapon_comp.set_aiming(aiming)
		
		# Set camera zoom based on weapon (only for ranged weapons with aim_zoom)
		if _player_camera and _player_camera.has_method("set_aiming"):
			_player_camera.set_aiming(aiming)
			if aiming and "aim_zoom" in weapon_comp:
				_player_camera.set_aim_zoom(weapon_comp.aim_zoom)
	
	# Notify weapon IK for pose change
	if _weapon_ik and _weapon_ik.has_method("set_aiming"):
		_weapon_ik.set_aiming(aiming)
	
	# Notify weapon attachment setup for pose change
	if _attachment_setup and _attachment_setup.has_method("set_aiming"):
		_attachment_setup.set_aiming(aiming)
	
	# Update crosshair on HUD
	var weapon_hud = _owner_entity.get_node_or_null("WeaponHUD")
	if weapon_hud and weapon_hud.has_method("set_crosshair_aiming"):
		weapon_hud.set_crosshair_aiming(aiming)
#endregion

#region Getters
func get_current_weapon() -> Node3D:
	return current_weapon

func get_current_weapon_component():  # Returns WeaponComponent
	if equipped_weapons.has(current_slot):
		return equipped_weapons[current_slot]
	return null

func get_equipped_slots() -> Array[String]:
	var slots: Array[String] = []
	for slot in weapon_instances:
		slots.append(slot)
	return slots

func is_weapon_equipped(slot: String) -> bool:
	return weapon_instances.has(slot)

func get_all_weapon_data() -> Dictionary:
	## Get data for all equipped weapons (for inventory UI)
	var result = {}
	print("[EquipmentManager] get_all_weapon_data - equipped_weapons has %d items" % equipped_weapons.size())

	for slot in equipped_weapons:
		var weapon_comp = equipped_weapons[slot]
		if weapon_comp:
			# Determine weapon subtype based on holster slot
			var subtype = "melee"
			if "holster_slot" in weapon_comp:
				match weapon_comp.holster_slot:
					"back_primary", "back_secondary":
						subtype = "rifle"
					"hip_right", "hip_left", "thigh_right", "thigh_left":
						if weapon_comp.has_method("try_attack") and not weapon_comp.has_method("try_fire"):
							subtype = "melee"
						else:
							subtype = "pistol"

			# Get actual rarity from weapon component or look up from ItemDatabase
			var rarity = "common"
			if "rarity" in weapon_comp:
				rarity = weapon_comp.rarity
			else:
				# Look up from ItemDatabase by item_id
				var item_id = weapon_comp.item_id if "item_id" in weapon_comp else ""
				if not item_id.is_empty():
					var item_db = get_node_or_null("/root/ItemDatabase")
					if item_db:
						var item_def = item_db.get_item(item_id)
						rarity = item_def.get("rarity", "common")

			var data = {
				"name": weapon_comp.weapon_name if "weapon_name" in weapon_comp else "Weapon",
				"item_id": weapon_comp.item_id if "item_id" in weapon_comp else "",
				"type": "weapon",
				"subtype": subtype,
				"rarity": rarity,
				"icon": "",  # No icon path, will use placeholder
				"damage": weapon_comp.damage if "damage" in weapon_comp else 0,
				"prefab_path": weapon_prefab_paths.get(slot, ""),  # For re-equipping
				"holster_slot": weapon_comp.holster_slot if "holster_slot" in weapon_comp else "back_primary",
			}
			
			# Add ranged weapon stats if available
			if "fire_rate" in weapon_comp:
				data["fire_rate"] = weapon_comp.fire_rate
			if "effective_range" in weapon_comp:
				data["effective_range"] = weapon_comp.effective_range
			
			result[slot] = data
			print("[EquipmentManager] Weapon in slot %s: %s" % [slot, data.name])
	
	return result

func get_aim_blend() -> float:
	var weapon_comp = get_current_weapon_component()
	if weapon_comp:
		return weapon_comp.get_aim_blend()
	return 0.0

func is_current_weapon_melee() -> bool:
	## Check if current weapon is a melee weapon
	if not current_weapon:
		return false
	return _get_melee_component_from(current_weapon) != null

func get_current_melee_component():  # Returns MeleeWeaponComponent or null
	## Get the MeleeWeaponComponent of current weapon
	if not current_weapon or not is_instance_valid(current_weapon):
		return null
	return _get_melee_component_from(current_weapon)

func _get_melee_component_from(weapon_node: Node):  # Returns MeleeWeaponComponent or null
	## Duck-typed melee component lookup (avoids class load order issues)
	if not weapon_node:
		return null
	
	# Check if the node itself has melee methods
	if weapon_node.has_method("try_attack") and weapon_node.has_method("start_block"):
		return weapon_node
	
	# Check for child component
	var child = weapon_node.get_node_or_null("MeleeWeaponComponent")
	if child:
		return child
	
	# Check script class name
	var script = weapon_node.get_script()
	if script:
		var class_name_str = script.get_global_name()
		if class_name_str and "MeleeWeaponComponent" in class_name_str:
			return weapon_node
	
	return null
#endregion

#region Weapon Drop/Pickup
const DROP_FORCE_MANUAL: float = 3.0      # Gentle toss when pressing Q
const DROP_FORCE_DISARM: float = 8.0      # Moderate force when disarmed
const DROP_FORCE_SHOT: float = 15.0       # Flying when shot out of hands

## Input action for dropping weapon
var action_drop_weapon: String = "drop_weapon"

func _ensure_drop_action():
	if not InputMap.has_action(action_drop_weapon):
		InputMap.add_action(action_drop_weapon)
		var event = InputEventKey.new()
		event.keycode = KEY_Q
		InputMap.action_add_event(action_drop_weapon, event)

func drop_current_weapon():
	## Manually drop weapon (Q key) - gentle toss forward
	force_drop_weapon(DROP_FORCE_MANUAL, Vector3.ZERO)

func force_drop_weapon(force: float = DROP_FORCE_DISARM, hit_direction: Vector3 = Vector3.ZERO):
	## Force drop the current weapon
	## force: How hard to throw it
	## hit_direction: Direction the hit came from (weapon flies opposite)
	if not current_weapon or is_holstered:
		return
	
	var weapon_to_drop = current_weapon
	var weapon_comp = equipped_weapons.get(current_slot)
	var slot_to_clear = current_slot
	
	# Get weapon data for the dropped weapon
	var drop_data = {}
	if weapon_comp:
		drop_data = {
			"id": weapon_comp.item_id,
			"name": weapon_comp.weapon_name,
			"prefab_path": weapon_comp.get("prefab_path", ""),
			"holster_slot": weapon_comp.holster_slot,
			# Include current ammo state
			"current_ammo": weapon_comp.current_ammo,
			"reserve_ammo": weapon_comp.reserve_ammo
		}
	
	# Holster first to detach from IK
	holster_current()
	
	# Remove from equipment
	weapon_instances.erase(slot_to_clear)
	equipped_weapons.erase(slot_to_clear)
	
	# Calculate drop direction
	var drop_dir: Vector3
	if hit_direction != Vector3.ZERO:
		# Shot out - fly in hit direction (away from shooter)
		drop_dir = hit_direction.normalized()
		drop_dir.y = abs(drop_dir.y) + 0.3  # Always go up a bit
	else:
		# Manual drop - toss forward
		drop_dir = -_owner_entity.global_transform.basis.z
		drop_dir.y = 0.2
		drop_dir = drop_dir.normalized()
	
	# Spawn dropped weapon
	_spawn_dropped_weapon(weapon_to_drop, drop_data, drop_dir, force)
	
	# Select next weapon if available
	current_slot = ""
	current_weapon = null
	for s in _slot_cycle:
		if weapon_instances.has(s):
			current_slot = s
			break

func _spawn_dropped_weapon(weapon_instance: Node3D, item_data: Dictionary, direction: Vector3, force: float):
	## Create a DroppedWeapon in the world
	var DroppedWeaponScript = load("res://addons/gsg-godot-plugins/item_system/dropped_weapon.gd")
	if not DroppedWeaponScript:
		push_error("[EquipmentManager] Could not load DroppedWeapon script!")
		return
	
	var dropped = RigidBody3D.new()
	dropped.set_script(DroppedWeaponScript)
	dropped.name = "DroppedWeapon_" + str(randi())
	
	# Position at player's hand area
	var drop_pos = _owner_entity.global_position + Vector3(0, 1.2, 0)
	drop_pos += -_owner_entity.global_transform.basis.z * 0.3  # Slightly forward
	
	# Add to scene first (required for global_position)
	get_tree().current_scene.add_child(dropped)
	dropped.global_position = drop_pos
	
	# Setup the dropped weapon
	dropped.setup_from_weapon(weapon_instance, item_data)
	var peer_id = _owner_entity.get("peer_id") if "peer_id" in _owner_entity else -1
	dropped.original_owner_id = peer_id
	
	# Apply physics force
	dropped.drop_with_force(direction, force)

func pickup_weapon(item_data: Dictionary) -> bool:
	## Pick up a weapon from the ground
	var slot = _get_slot_for_size(item_data.get("size", "medium"))
	
	# Check if slot is available or can swap
	if weapon_instances.has(slot):
		# Drop current weapon in that slot first
		var old_slot = current_slot
		current_slot = slot
		is_holstered = false
		current_weapon = weapon_instances[slot]
		force_drop_weapon()
		current_slot = old_slot
	
	# Equip the new weapon
	return equip_weapon(slot, item_data)

func _get_slot_for_size(_size: String) -> String:
	## Find the first empty weapon slot, or return the first slot if all full
	for slot in _slot_cycle:
		if not weapon_instances.has(slot):
			return slot
	return weapon_slot_1  # Default to first slot if all full
#endregion

#region State Persistence
func get_all_weapon_states() -> Dictionary:
	## Get current state of all equipped weapons for saving to database
	## Returns: { slot_name: { inventory_id: int, state: Dictionary } }
	var states = {}
	
	for slot in equipped_weapons:
		var weapon_comp = equipped_weapons[slot]
		if weapon_comp and weapon_comp.has_method("get_instance_state"):
			var state = weapon_comp.get_instance_state()
			var inv_id = weapon_inventory_ids.get(slot, -1)
			if inv_id > 0:
				states[slot] = {
					"inventory_id": inv_id,
					"state": state
				}
	
	return states

func save_all_weapon_states():
	## Save all weapon states to database (call on disconnect)
	var states = get_all_weapon_states()
	if states.is_empty():
		return
	
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db and item_db.has_method("save_all_equipment_state"):
		# Get character_id from owner entity
		var character_id = 0
		if _owner_entity and "character_id" in _owner_entity:
			character_id = _owner_entity.character_id
		elif _owner_entity and "peer_id" in _owner_entity:
			character_id = _owner_entity.peer_id  # Use peer_id as fallback
		
		if character_id > 0:
			item_db.save_all_equipment_state(character_id, states)
			print("[EquipmentManager] Saved weapon states for character ", character_id)
#endregion

