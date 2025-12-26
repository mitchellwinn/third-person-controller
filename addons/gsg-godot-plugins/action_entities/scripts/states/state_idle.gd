extends EntityState
class_name StateIdle

## Idle state - entity is standing still, ready for input

@export var debug_idle: bool = false

func _ready():
	can_be_interrupted = true
	priority = 0
	allows_movement = true
	allows_rotation = true
	state_animation = "idle"  # Will auto-play on enter

func on_enter(previous_state = null):
	super.on_enter(previous_state)  # Plays state_animation

	# Reset speed multiplier to normal
	if entity.has_method("set_speed_multiplier"):
		entity.set_speed_multiplier(1.0)

func on_physics_process(delta: float):
	# Check if this is a remote player (not local)
	# Remote players should NOT process input locally - their state comes from network sync
	var is_remote = "_is_remote_player" in entity and entity._is_remote_player
	if is_remote:
		return  # Remote players just wait for state sync, no local input processing

	# Check if fell off edge - transition to airborne state
	# Skip for remote players - their state is synced from network
	var is_local = not "can_receive_input" in entity or entity.can_receive_input
	if is_local and entity is CharacterBody3D:
		if not entity.is_on_floor():
			if debug_idle:
				print("[StateIdle] Left ground -> transitioning to airborne")
			transition_to("airborne")
			return

	# Check for movement input to transition
	if entity.has_method("get_movement_input"):
		var input_dir = entity.get_movement_input()
		if input_dir.length() > 0.1:
			if debug_idle:
				print("[StateIdle] Movement detected (%.2f, %.2f) -> moving" % [input_dir.x, input_dir.z])
			transition_to("moving")
			return

	# Check for blocking (right-click/aim with melee weapon)
	if _check_block_input():
		if _can_block() and state_manager.has_state("melee_block"):
			transition_to("melee_block")
			return

	# Check for attack input - BOTH direct input AND buffered (for maximum responsiveness)
	var has_attack_input = false
	var input_source = ""
	if _is_player_controlled():
		# Local player: check direct input first for lowest latency
		if Input.is_action_just_pressed("attack_primary") or Input.is_action_just_pressed("fire"):
			has_attack_input = true
			input_source = "direct"
	# Also check buffered inputs (for both local player's buffered inputs and server entities)
	if not has_attack_input:
		if state_manager.consume_buffered_input("attack_primary"):
			has_attack_input = true
			input_source = "buffered"

	if has_attack_input:
		# Check if we have a ranged weapon - let EquipmentManager handle firing
		var equip_manager = entity.get_node_or_null("EquipmentManager")
		if equip_manager and equip_manager.has_method("is_current_weapon_melee"):
			if not equip_manager.is_current_weapon_melee():
				# Ranged weapon equipped - EquipmentManager handles firing, don't trigger melee
				return

		# Use combo controller for melee attacks (handles combo state properly)
		var combo_ctrl = entity.get_node_or_null("MeleeComboController")
		if combo_ctrl and combo_ctrl.has_method("try_attack"):
			if combo_ctrl.try_attack():
				return

		# Fallback to other melee attack states (only if melee weapon equipped)
		var attack_state = _get_attack_state()
		if not attack_state.is_empty():
			transition_to(attack_state)
			return
	
	var dodge_result = state_manager.consume_buffered_input_with_data("dodge")
	if dodge_result.found:
		if _can_dodge():
			# Pass buffered direction to dash via entity metadata
			var buffered_dir = dodge_result.data.get("direction", Vector2(0, -1))
			entity.set_meta("_buffered_dash_direction", buffered_dir)
			# Check if dash state exists, otherwise use dodging
			if state_manager.has_state("dash"):
				transition_to("dash")
			else:
				transition_to("dodging")
		return
	
	# Check for double-tap dash (local player)
	if entity.has_method("try_dash") and entity.try_dash():
		if _can_dodge() and state_manager.has_state("dash"):
			transition_to("dash")
			return
	
	if state_manager.consume_buffered_input("jump"):
		if _can_jump():
			if debug_idle:
				print("[StateIdle] Jump input consumed -> jumping")
			transition_to("jumping")
		return

func _can_jump() -> bool:
	if entity.has_method("can_jump"):
		return entity.can_jump()
	return true

func _can_dodge() -> bool:
	# Check stamina for dash
	if entity.has_method("has_stamina"):
		var dash_cost = entity.dash_stamina_cost if "dash_stamina_cost" in entity else 20.0
		if not entity.has_stamina(dash_cost):
			return false
	
	if entity.has_method("can_dodge"):
		return entity.can_dodge()
	return true

func _can_attack() -> bool:
	if entity.has_method("can_attack"):
		return entity.can_attack()
	return true

func _check_block_input() -> bool:
	## Check if block input is held (right-click/aim) while having melee weapon
	if not _is_player_controlled():
		return state_manager.consume_buffered_input("attack_secondary") or state_manager.consume_buffered_input("aim")
	return Input.is_action_pressed("aim") or Input.is_action_pressed("attack_secondary")

func _can_block() -> bool:
	## Can only block with melee weapon equipped
	var equip_manager = entity.get_node_or_null("EquipmentManager")
	if equip_manager and equip_manager.has_method("is_current_weapon_melee"):
		if equip_manager.is_current_weapon_melee():
			# Check if melee weapon can block
			var melee = equip_manager.get_current_melee_component()
			if melee and "can_block" in melee:
				return melee.can_block
			return true
	return false

func _get_attack_state() -> String:
	## Determine which attack state to use based on current weapon
	## Returns empty string if no valid attack state exists
	var equip_manager = entity.get_node_or_null("EquipmentManager")
	if equip_manager and equip_manager.has_method("is_current_weapon_melee"):
		if equip_manager.is_current_weapon_melee():
			# Use combo controller's state names
			if state_manager.has_state("saber_light_slash_0"):
				return "saber_light_slash_0"
	
	# Fallback: check if a ranged attack state exists
	if state_manager.has_state("attack_light"):
		return "attack_light"
	if state_manager.has_state("shooting"):
		return "shooting"
	
	# No valid attack state - return empty to prevent transition
	return ""

func _is_player_controlled() -> bool:
	if "can_receive_input" in entity:
		return entity.can_receive_input
	return false
