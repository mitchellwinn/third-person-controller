@tool
extends Node
class_name BoneHitboxSystem

## Creates collision shapes for each bone on a skeleton.
## Provides per-bone damage multipliers and hit effects.
##
## USAGE:
## 1. Add this as a child of your character
## 2. Click "Create Hitboxes" in inspector
## 3. Adjust damage multipliers and effects per bone region

signal bone_hit(bone_name: String, damage: float, hit_info: Dictionary)
signal critical_hit(bone_name: String, damage: float)
signal limb_disabled(bone_name: String)
signal weapon_dropped(weapon: Node3D)

#region Configuration
@export_group("Skeleton")
@export var skeleton_path: NodePath

@export_group("Bone Regions")
## Bones that count as head (high damage)
@export var head_bones: Array[String] = ["head.x", "neck.x"]
## Bones that count as torso (normal damage)
@export var torso_bones: Array[String] = ["spine_01.x", "spine_02.x", "spine_03.x", "chest.x"]
## Arm bones (can cause weapon drop)
@export var arm_bones: Array[String] = ["arm_stretch.r", "arm_stretch.l", "forearm_stretch.r", "forearm_stretch.l", "hand.r", "hand.l"]
## Leg bones (can slow movement)
@export var leg_bones: Array[String] = ["thigh_stretch.r", "thigh_stretch.l", "calf_stretch.r", "calf_stretch.l", "foot.r", "foot.l"]

@export_group("Damage Multipliers")
@export var head_damage_mult: float = 3.0
@export var torso_damage_mult: float = 1.0
@export var arm_damage_mult: float = 0.7
@export var leg_damage_mult: float = 0.8
@export var hand_damage_mult: float = 0.5  # But can cause weapon drop!

@export_group("Hit Effects")
## Chance to drop weapon when hand/arm is hit (0-1)
@export var weapon_drop_chance: float = 0.3
## Damage threshold for guaranteed weapon drop
@export var weapon_drop_damage_threshold: float = 30.0
## Slow multiplier when leg is hit
@export var leg_hit_slow_mult: float = 0.6
## Duration of leg slow effect
@export var leg_slow_duration: float = 2.0

@export_group("Hitbox Sizes")
@export var head_radius: float = 0.12
@export var torso_radius: float = 0.15
@export var limb_radius: float = 0.06
@export var hand_radius: float = 0.04

@export_group("Actions")
@export var create_hitboxes: bool = false:
	set(v):
		if v and Engine.is_editor_hint():
			_create_all_hitboxes()

@export var show_debug_shapes: bool = false:
	set(v):
		show_debug_shapes = v
		_update_debug_visibility()
#endregion

#region Runtime State
var _skeleton: Skeleton3D
var _hitboxes: Dictionary = {}  # bone_name -> Area3D
var _bone_attachments: Dictionary = {}  # bone_name -> BoneAttachment3D
var _owner_entity: Node3D
var _equipment_manager: Node  # For weapon drop
var _is_blocking: bool = false  # True when entity is blocking
var _melee_weapon = null  # Current melee weapon for block stats
#endregion

#region Blocking
## Bones below knees - cannot be blocked (feet and lower calves)
const UNBLOCKABLE_BONES: Array[String] = ["foot.r", "foot.l", "calf_stretch.r", "calf_stretch.l"]

var _block_state = null  # Reference to StateMeleeBlock for parry checks

func set_blocking(blocking: bool, melee_weapon = null, block_state = null):
	## Called by blocking state to enable/disable block
	_is_blocking = blocking
	_melee_weapon = melee_weapon
	_block_state = block_state

func is_bone_blockable(bone_name: String) -> bool:
	## Returns true if this bone hit can be blocked (not below knees)
	return not bone_name in UNBLOCKABLE_BONES

func is_attack_from_front(attack_origin: Vector3) -> bool:
	## Check if attack is coming from in front of the character (can be blocked)
	## Returns false if attack is from behind (can't block what you can't see)
	if not _owner_entity:
		return true
	
	var to_attacker = (attack_origin - _owner_entity.global_position).normalized()
	var forward = -_owner_entity.global_transform.basis.z
	
	# Dot product: positive = in front, negative = behind
	# Allow blocking from front and sides (> -0.3 gives ~110 degree coverage)
	return to_attacker.dot(forward) > -0.3

func is_blocking() -> bool:
	return _is_blocking

func get_block_state():
	## Get the current block state for parry checks
	return _block_state
#endregion

func _ready():
	_owner_entity = get_parent()
	_find_skeleton()
	_find_equipment_manager()

	if not Engine.is_editor_hint():
		_find_existing_hitboxes()
		# Auto-create hitboxes at runtime if none exist
		if _hitboxes.is_empty() and _skeleton:
			print("[BoneHitboxSystem] No hitboxes found, creating at runtime...")
			_create_all_hitboxes()
			print("[BoneHitboxSystem] Created %d hitboxes" % _hitboxes.size())
		# Ensure debug visibility matches setting (hide by default)
		_update_debug_visibility()

func _find_skeleton() -> Skeleton3D:
	if skeleton_path:
		_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if not _skeleton:
		_skeleton = _search_for_skeleton(get_parent())
	return _skeleton

func _search_for_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _search_for_skeleton(child)
		if found:
			return found
	return null

func _find_equipment_manager():
	if _owner_entity:
		_equipment_manager = _owner_entity.get_node_or_null("EquipmentManager")

func _find_existing_hitboxes():
	if not _skeleton:
		return
	for child in _skeleton.get_children():
		if child is BoneAttachment3D and child.name.begins_with("Hitbox_"):
			var bone_name = child.bone_name
			_bone_attachments[bone_name] = child
			for area in child.get_children():
				if area is Area3D:
					_hitboxes[bone_name] = area
					# Connect signal if not already
					if not area.area_entered.is_connected(_on_hitbox_entered):
						area.area_entered.connect(_on_hitbox_entered.bind(bone_name))

#region Hitbox Creation (Editor)
func _create_all_hitboxes():
	_find_skeleton()
	if not _skeleton:
		push_error("[BoneHitboxSystem] No skeleton found!")
		return
	
	print("[BoneHitboxSystem] Creating hitboxes on: ", _skeleton.name)
	
	# Create hitboxes for each bone region
	for bone in head_bones:
		_create_hitbox_for_bone(bone, head_radius, "head")
	
	for bone in torso_bones:
		_create_hitbox_for_bone(bone, torso_radius, "torso")
	
	for bone in arm_bones:
		var radius = hand_radius if "hand" in bone else limb_radius
		_create_hitbox_for_bone(bone, radius, "arm")
	
	for bone in leg_bones:
		_create_hitbox_for_bone(bone, limb_radius, "leg")
	
	print("[BoneHitboxSystem] Created hitboxes for all bones!")

func _create_hitbox_for_bone(bone_name: String, radius: float, region: String):
	var bone_idx = _skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return  # Bone doesn't exist, skip silently
	
	# Check if already exists
	var attach_name = "Hitbox_" + bone_name.replace(".", "_")
	var existing = _skeleton.get_node_or_null(attach_name)
	if existing:
		return  # Already exists
	
	# Create bone attachment
	var attach = BoneAttachment3D.new()
	attach.name = attach_name
	attach.bone_name = bone_name
	_skeleton.add_child(attach)
	if Engine.is_editor_hint():
		attach.owner = get_tree().edited_scene_root
	
	# Create Area3D for hit detection
	var area = Area3D.new()
	area.name = "HitArea"
	area.collision_layer = 0  # Doesn't collide with anything
	area.collision_mask = 4  # Layer 3 = projectiles (adjust as needed)
	area.monitoring = true
	area.monitorable = true
	area.set_meta("bone_name", bone_name)
	area.set_meta("region", region)
	attach.add_child(area)
	if Engine.is_editor_hint():
		area.owner = get_tree().edited_scene_root
	
	# Create collision shape
	var shape = CollisionShape3D.new()
	shape.name = "Shape"
	var capsule = CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = radius * 3  # Elongated for bones
	shape.shape = capsule
	area.add_child(shape)
	if Engine.is_editor_hint():
		shape.owner = get_tree().edited_scene_root
	
	# Debug mesh (visible in editor)
	if show_debug_shapes:
		var debug_mesh = _create_debug_mesh(radius, region)
		area.add_child(debug_mesh)
		if Engine.is_editor_hint():
			debug_mesh.owner = get_tree().edited_scene_root
	
	_bone_attachments[bone_name] = attach
	_hitboxes[bone_name] = area
	
	# Connect area_entered signal for hit detection (CRITICAL for runtime-created hitboxes!)
	if not Engine.is_editor_hint():
		area.area_entered.connect(_on_hitbox_entered.bind(bone_name))

func _create_debug_mesh(radius: float, region: String) -> MeshInstance3D:
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.name = "DebugMesh"
	
	var capsule = CapsuleMesh.new()
	capsule.radius = radius
	capsule.height = radius * 3
	mesh_inst.mesh = capsule
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	match region:
		"head":
			mat.albedo_color = Color(1, 0, 0, 0.3)  # Red
		"torso":
			mat.albedo_color = Color(0, 0, 1, 0.3)  # Blue
		"arm":
			mat.albedo_color = Color(0, 1, 0, 0.3)  # Green
		"leg":
			mat.albedo_color = Color(1, 1, 0, 0.3)  # Yellow
	
	mesh_inst.material_override = mat
	return mesh_inst

func _update_debug_visibility():
	for bone in _hitboxes:
		var area = _hitboxes[bone]
		var debug = area.get_node_or_null("DebugMesh")
		if debug:
			debug.visible = show_debug_shapes
#endregion

#region Damage Processing
func process_hit(bone_name: String, base_damage: float, hit_info: Dictionary = {}) -> float:
	## Process a hit on a specific bone. Returns actual damage dealt.
	## Handles blocking - upper body hits are blocked, leg hits go through
	var region = _get_bone_region(bone_name)
	var damage_mult = _get_damage_multiplier(region, bone_name)
	var final_damage = base_damage * damage_mult
	
	# Check if blocked
	var was_blocked = false
	var block_reduction = 0.0
	
	# Get attack origin for direction check
	var attack_origin = hit_info.get("hit_position", Vector3.ZERO)
	if hit_info.has("attacker") and hit_info.attacker is Node3D:
		attack_origin = hit_info.attacker.global_position
	
	if _is_blocking and is_bone_blockable(bone_name) and is_attack_from_front(attack_origin):
		# This hit is blocked!
		was_blocked = true
		
		# Get block reduction from melee weapon
		if _melee_weapon and "block_damage_reduction" in _melee_weapon:
			block_reduction = _melee_weapon.block_damage_reduction
		else:
			block_reduction = 0.7  # Default 70% reduction
		
		# Reduce damage
		final_damage = final_damage * (1.0 - block_reduction)
		
		# Play block effect
		if _owner_entity and _owner_entity.has_method("on_block_hit"):
			_owner_entity.on_block_hit(base_damage, bone_name, hit_info)
		
		print("[BoneHitboxSystem] BLOCKED hit on %s! Reduced %.1f -> %.1f damage" % [
			bone_name, base_damage * damage_mult, final_damage
		])
	
	# Populate hit info
	hit_info["bone_name"] = bone_name
	hit_info["region"] = region
	hit_info["damage_mult"] = damage_mult
	hit_info["final_damage"] = final_damage
	hit_info["was_blocked"] = was_blocked
	hit_info["block_reduction"] = block_reduction
	
	# Emit signals
	bone_hit.emit(bone_name, final_damage, hit_info)
	
	if not was_blocked and region == "head" and damage_mult >= 2.0:
		critical_hit.emit(bone_name, final_damage)
	
	# Handle special effects (reduced if blocked)
	if not was_blocked or final_damage > 0:
		_handle_hit_effects(bone_name, region, final_damage, hit_info)
	
	return final_damage

func _get_bone_region(bone_name: String) -> String:
	if bone_name in head_bones:
		return "head"
	elif bone_name in torso_bones:
		return "torso"
	elif bone_name in arm_bones:
		return "arm"
	elif bone_name in leg_bones:
		return "leg"
	return "torso"  # Default

func _get_damage_multiplier(region: String, bone_name: String) -> float:
	match region:
		"head":
			return head_damage_mult
		"torso":
			return torso_damage_mult
		"arm":
			if "hand" in bone_name:
				return hand_damage_mult
			return arm_damage_mult
		"leg":
			return leg_damage_mult
	return 1.0

func _handle_hit_effects(bone_name: String, region: String, damage: float, hit_info: Dictionary):
	# Apply procedural ragdoll hit reaction
	_apply_ragdoll_hit_reaction(bone_name, damage, hit_info)
	
	# Weapon drop on hand/arm hit
	if region == "arm" and _equipment_manager:
		var drop_chance = weapon_drop_chance
		if damage >= weapon_drop_damage_threshold:
			drop_chance = 1.0  # Guaranteed drop on high damage
		
		if randf() < drop_chance:
			if _equipment_manager.has_method("force_drop_weapon"):
				# Calculate force based on damage - high damage = flying weapon
				var drop_force = 8.0 + (damage * 0.3)  # Base + damage scaling
				drop_force = clampf(drop_force, 8.0, 20.0)
				
				# Direction from hit (weapon flies away from shooter)
				var hit_dir = hit_info.get("hit_direction", Vector3.ZERO)
				if hit_dir == Vector3.ZERO:
					hit_dir = hit_info.get("knockback_direction", Vector3(randf() - 0.5, 0.5, randf() - 0.5))
				
				_equipment_manager.force_drop_weapon(drop_force, hit_dir)
				weapon_dropped.emit(null)
	
	# Leg hit slow effect
	if region == "leg" and _owner_entity:
		if _owner_entity.has_method("apply_slow"):
			_owner_entity.apply_slow(leg_hit_slow_mult, leg_slow_duration)
	
	# Apply knockback if specified
	var knockback = hit_info.get("knockback_force", 0.0)
	var knockback_dir = hit_info.get("knockback_direction", Vector3.ZERO)
	if knockback > 0 and knockback_dir != Vector3.ZERO and _owner_entity:
		if _owner_entity.has_method("apply_knockback"):
			_owner_entity.apply_knockback(knockback_dir * knockback)
	
	# Apply hitstun if specified
	var hitstun = hit_info.get("hitstun_duration", 0.0)
	if hitstun > 0 and _owner_entity:
		if _owner_entity.has_method("apply_hitstun"):
			_owner_entity.apply_hitstun(hitstun)

func _on_hitbox_entered(area: Area3D, bone_name: String):
	## Called when something enters a bone's hitbox
	# Check if it's a projectile
	if area.has_meta("projectile_data"):
		var proj_data = area.get_meta("projectile_data")
		var base_damage = proj_data.get("damage", 10.0)
		var hit_info = proj_data.duplicate()
		hit_info["hit_position"] = area.global_position
		
		# Check for projectile parry/block first
		# Must be: blocking, bone is blockable, and attack is from front
		var attack_origin = area.global_position - proj_data.get("velocity", Vector3.FORWARD).normalized() * 2.0
		if _is_blocking and is_bone_blockable(bone_name) and is_attack_from_front(attack_origin):
			if _block_state and _block_state.has_method("is_in_parry_window") and _block_state.is_in_parry_window():
				# PARRY! Reflect the projectile
				_reflect_projectile(area, proj_data)
				return
		
		# Process hit (handles blocking, damage multipliers, etc.)
		var final_damage = process_hit(bone_name, base_damage, hit_info)
		
		# Apply actual damage to owner entity
		if final_damage > 0 and _owner_entity:
			var attacker = proj_data.get("owner", null)
			var damage_type = proj_data.get("damage_type", "energy")
			if _owner_entity.has_method("take_damage"):
				_owner_entity.take_damage(final_damage, attacker, damage_type)
			
			print("[BoneHitboxSystem] Applied %.1f damage to %s (bone: %s)" % [
				final_damage, _owner_entity.name, bone_name
			])

func _reflect_projectile(projectile: Area3D, proj_data: Dictionary):
	## Reflect a parried projectile back toward where the player is aiming
	print("[BoneHitboxSystem] PARRY! Reflecting projectile!")
	
	# Get aim direction from player camera
	var reflect_dir = Vector3.FORWARD
	if _owner_entity:
		# Try to get camera aim direction
		var camera = _owner_entity.get_node_or_null("PlayerCamera")
		if camera and camera.has_method("get_aim_direction"):
			reflect_dir = camera.get_aim_direction()
		elif camera:
			# Fallback: use camera forward
			reflect_dir = -camera.global_transform.basis.z
		else:
			# Fallback: use player forward
			reflect_dir = -_owner_entity.global_transform.basis.z
	
	# Get projectile scene to spawn a new one
	var proj_scene_path = ""
	if projectile.has_method("get_scene_path"):
		proj_scene_path = projectile.get_scene_path()
	elif projectile.scene_file_path:
		proj_scene_path = projectile.scene_file_path
	else:
		# Try to get from script
		var script = projectile.get_script()
		if script:
			proj_scene_path = script.resource_path.replace(".gd", ".tscn")
	
	# Spawn reflected projectile
	var spawn_pos = projectile.global_position
	var damage = proj_data.get("damage", 10.0) * 1.5  # Bonus damage on reflect
	var damage_type = proj_data.get("damage_type", "energy")
	var velocity = proj_data.get("velocity", Vector3.ZERO)
	var speed = velocity.length() if velocity.length() > 0 else 150.0
	
	# Load and spawn new projectile
	if proj_scene_path != "" and ResourceLoader.exists(proj_scene_path):
		var proj_prefab = load(proj_scene_path)
		if proj_prefab:
			var new_proj = proj_prefab.instantiate()
			projectile.get_tree().current_scene.add_child(new_proj)
			new_proj.global_position = spawn_pos + reflect_dir * 0.5  # Offset to avoid self-hit
			
			# Initialize with new direction, player as owner
			if new_proj.has_method("initialize"):
				new_proj.initialize(reflect_dir * speed, damage, damage_type, _owner_entity)
			
			print("[BoneHitboxSystem] Spawned reflected projectile toward ", reflect_dir)
	
	# Play parry effect
	if _block_state and _block_state.has_method("_on_parry_success"):
		# Pass null as attacker since it's a projectile
		_block_state._on_parry_success(null, {})
	
	# Restore stamina for successful parry
	if _owner_entity and _owner_entity.has_method("restore_stamina"):
		_owner_entity.restore_stamina(15.0)
	
	# The original projectile will destroy itself
#endregion

#region Ragdoll Integration
func _apply_ragdoll_hit_reaction(bone_name: String, damage: float, hit_info: Dictionary):
	## Apply procedural hit reaction to ragdoll controller if present
	if not _owner_entity:
		return
	
	# Get hit direction
	var hit_dir = hit_info.get("knockback_direction", Vector3.ZERO)
	if hit_dir == Vector3.ZERO:
		hit_dir = hit_info.get("hit_direction", Vector3.ZERO)
	if hit_dir == Vector3.ZERO and hit_info.has("hit_position") and _owner_entity:
		# Calculate from hit position to entity center
		hit_dir = (_owner_entity.global_position - hit_info.hit_position).normalized()
		hit_dir = -hit_dir  # Reverse so it pushes away from hit
	
	# Scale impact force with damage
	var impact_force = damage * 0.4
	
	# Try to apply hit reaction via entity method
	if _owner_entity.has_method("apply_hit_reaction"):
		_owner_entity.apply_hit_reaction(bone_name, hit_dir, impact_force)
#endregion

#region Utility
func get_hitbox_for_bone(bone_name: String) -> Area3D:
	return _hitboxes.get(bone_name, null)

func get_all_hitboxes() -> Dictionary:
	return _hitboxes.duplicate()

func set_hitboxes_enabled(enabled: bool):
	for bone in _hitboxes:
		_hitboxes[bone].monitoring = enabled
		_hitboxes[bone].monitorable = enabled
#endregion

