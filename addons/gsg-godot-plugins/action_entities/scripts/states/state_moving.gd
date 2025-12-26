extends EntityState
class_name StateMoving

## Moving state - entity is walking/running

@export var debug_moving: bool = false
var is_sprinting: bool = false
var _last_sprint_state: bool = false

func _ready():
	can_be_interrupted = true
	priority = 0
	allows_movement = true
	allows_rotation = true

func on_enter(previous_state = null):
	is_sprinting = false
	_last_sprint_state = false

	if debug_moving:
		var prev_name = previous_state.name if previous_state else "none"
		var input_dir = entity.get_movement_input() if entity.has_method("get_movement_input") else Vector3.ZERO
		print("[StateMoving] ENTER from %s - input=(%.2f, %.2f) sprint=%s" % [
			prev_name, input_dir.x, input_dir.z, str(is_sprinting)
		])

	_update_animation()

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
			if debug_moving:
				print("[StateMoving] Left ground -> transitioning to airborne")
			transition_to("airborne")
			return

	# Check for movement input
	var input_dir = Vector3.ZERO
	if entity.has_method("get_movement_input"):
		input_dir = entity.get_movement_input()

	# No input - return to idle
	if input_dir.length() < 0.1:
		if debug_moving:
			print("[StateMoving] No input (len=%.3f) -> transitioning to idle" % input_dir.length())
		transition_to("idle")
		return
	
	# Check sprint - handle both local input and network-applied speed multiplier
	if _is_player_controlled():
		# Local player: check actual input AND permission AND stamina
		var wants_sprint = Input.is_action_pressed("sprint") and _can_sprint()
		
		# Drain stamina while sprinting
		if is_sprinting:
			if entity.has_method("drain_stamina"):
				var drain_amount = entity.sprint_stamina_drain * delta if "sprint_stamina_drain" in entity else 10.0 * delta
				if not entity.drain_stamina(drain_amount):
					# Out of stamina - force stop sprinting
					wants_sprint = false
		
		if wants_sprint != is_sprinting:
			is_sprinting = wants_sprint
			if debug_moving:
				print("[StateMoving] Sprint changed (local input): %s -> %s" % [str(_last_sprint_state), str(is_sprinting)])
			_last_sprint_state = is_sprinting
			_update_animation()
		
		# Set sprint speed multiplier
		var speed_mult = 1.5 if is_sprinting else 1.0
		if entity.has_method("set_speed_multiplier"):
			entity.set_speed_multiplier(speed_mult)
	else:
		# Server-controlled entity: read sprint from current_speed_multiplier (set by apply_network_input)
		var server_sprint = false
		if "current_speed_multiplier" in entity:
			server_sprint = entity.current_speed_multiplier > 1.2 # Sprinting if multiplier > 1.2
		
		if server_sprint != is_sprinting:
			is_sprinting = server_sprint
			if debug_moving:
				print("[StateMoving] Sprint changed (server): %s -> %s (speed_mult=%.2f)" % [
					str(_last_sprint_state), str(is_sprinting),
					entity.current_speed_multiplier if "current_speed_multiplier" in entity else 0
				])
			_last_sprint_state = is_sprinting
			_update_animation()
	
	# Check for blocking (right-click/aim with melee weapon)
	if _check_block_input():
		if _can_block() and state_manager.has_state("melee_block"):
			transition_to("melee_block")
			return

	# Check for attack input - BOTH direct input AND buffered (for maximum responsiveness)
	var has_attack_input = false
	if _is_player_controlled():
		# Local player: check direct input first for lowest latency
		has_attack_input = Input.is_action_just_pressed("attack_primary") or Input.is_action_just_pressed("fire")
	# Also check buffered inputs (for both local player's buffered inputs and server entities)
	if not has_attack_input:
		has_attack_input = state_manager.consume_buffered_input("attack_primary")

	if has_attack_input:
		# Check if we have a ranged weapon - let EquipmentManager handle firing
		var equip_manager = entity.get_node_or_null("EquipmentManager")
		if equip_manager and equip_manager.has_method("is_current_weapon_melee"):
			if not equip_manager.is_current_weapon_melee():
				# Ranged weapon equipped - EquipmentManager handles firing, don't trigger melee
				return

		# Use combo controller for melee attacks (checks if melee weapon is equipped)
		var combo_ctrl = entity.get_node_or_null("MeleeComboController")
		if combo_ctrl and combo_ctrl.has_method("try_attack"):
			if combo_ctrl.try_attack():
				return  # Combo controller handled it

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
			if debug_moving:
				print("[StateMoving] Jump input consumed -> transitioning to jumping")
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

func _can_sprint() -> bool:
	# Check stamina first
	if entity.has_method("has_stamina"):
		if not entity.has_stamina(1.0):  # Need at least some stamina to start sprinting
			return false
	
	if entity.has_method("can_sprint"):
		return entity.can_sprint()
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

func _update_animation():
	if entity.has_method("play_animation"):
		if is_sprinting:
			entity.play_animation("sprint")
		else:
			entity.play_animation("run")

func get_exit_data() -> Dictionary:
	return {"was_sprinting": is_sprinting}
