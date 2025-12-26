extends MeshInstance3D
class_name EntityShadow

## Blob shadow that sits under entities, conforming to ground normal
## Grows larger and more transparent when entity is further from ground
## Uses MeshInstance3D for compatibility mode support (no Decals)

@export_group("Shadow Appearance")
@export var base_size: float = 1.0 ## Base shadow size when on ground
@export var max_size: float = 2.5 ## Maximum shadow size when far from ground
@export var base_opacity: float = 0.6 ## Opacity when on ground
@export var min_opacity: float = 0.1 ## Minimum opacity when far from ground

@export_group("Distance Settings")
@export var max_height: float = 10.0 ## Height at which shadow reaches max size/min opacity
@export var ground_offset: float = 0.02 ## Small offset above ground to prevent z-fighting
@export var raycast_distance: float = 20.0 ## How far down to check for ground

@export_group("Performance")
@export var update_interval: float = 0.0 ## Time between updates (0 = every frame)

var _update_timer: float = 0.0
var _entity: Node3D = null
var _is_on_ground: bool = true
var _shadow_material: ShaderMaterial = null

func _ready():
	# Find parent entity
	_entity = get_parent()
	while _entity and not _entity is CharacterBody3D:
		_entity = _entity.get_parent()

	if not _entity:
		_entity = get_parent() as Node3D

	# Setup mesh and material
	_setup_shadow()

func _setup_shadow():
	# Create a quad mesh facing up (lying flat on ground)
	var quad = QuadMesh.new()
	quad.size = Vector2(base_size, base_size)
	quad.orientation = PlaneMesh.FACE_Y # Face upward so it lies on ground
	mesh = quad

	# Create shader material for soft shadow circle
	_shadow_material = ShaderMaterial.new()
	_shadow_material.shader = _create_shadow_shader()
	_shadow_material.set_shader_parameter("shadow_color", Color(0, 0, 0, base_opacity))

	material_override = _shadow_material

	# Ensure shadow renders on top of ground
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _create_shadow_shader() -> Shader:
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.6);

void fragment() {
	// Create circular gradient from center
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(UV, center) * 2.0; // 0 at center, 1 at edge

	// Soft falloff using smoothstep
	float alpha = 1.0 - smoothstep(0.0, 1.0, dist);

	// Apply shadow color with calculated alpha
	ALBEDO = shadow_color.rgb;
	ALPHA = alpha * shadow_color.a;
}
"""
	return shader

func _process(delta: float):
	if not _entity:
		return

	# Throttle updates for performance
	if update_interval > 0:
		_update_timer += delta
		if _update_timer < update_interval:
			return
		_update_timer = 0.0

	_update_shadow()

func _update_shadow():
	## Raycast to find ground and update shadow position/size/opacity
	var space_state = get_world_3d().direct_space_state
	if not space_state:
		return

	# Cast ray from entity position downward
	var origin = _entity.global_position + Vector3(0, 0.5, 0) # Start slightly above feet
	var ray_end = origin + Vector3.DOWN * raycast_distance

	var query = PhysicsRayQueryParameters3D.create(origin, ray_end)
	query.exclude = [_entity]
	query.collision_mask = 1 # Ground layer (adjust if needed)

	var result = space_state.intersect_ray(query)

	if result:
		var ground_pos = result.position
		var ground_normal = result.normal
		var height = _entity.global_position.y - ground_pos.y

		# Position shadow just above ground
		global_position = ground_pos + ground_normal * ground_offset

		# Orient shadow to align with ground normal (quad faces +Y by default)
		# We want the quad's up (+Y) to align with ground normal
		if ground_normal != Vector3.UP and ground_normal != Vector3.DOWN:
			var up = ground_normal
			var forward = Vector3.FORWARD
			if abs(up.dot(Vector3.FORWARD)) > 0.99:
				forward = Vector3.RIGHT
			var right = up.cross(forward).normalized()
			forward = right.cross(up).normalized()
			global_basis = Basis(right, up, forward)
		else:
			global_basis = Basis.IDENTITY
			if ground_normal == Vector3.DOWN:
				# Flip for ceiling shadows (unlikely but handled)
				rotate_x(PI)

		# Calculate size/opacity based on height
		var height_ratio = clampf(height / max_height, 0.0, 1.0)

		# Size increases with height (shadow spreads)
		var current_size = lerp(base_size, max_size, height_ratio)
		if mesh is QuadMesh:
			(mesh as QuadMesh).size = Vector2(current_size, current_size)

		# Opacity decreases with height
		var current_opacity = lerp(base_opacity, min_opacity, height_ratio)
		if _shadow_material:
			var color = Color(0, 0, 0, current_opacity)
			_shadow_material.set_shader_parameter("shadow_color", color)

		_is_on_ground = true
		visible = true
	else:
		# No ground found - hide shadow
		_is_on_ground = false
		visible = false

func is_on_ground() -> bool:
	return _is_on_ground

func set_shadow_size(size: float):
	base_size = size
	if mesh is QuadMesh:
		(mesh as QuadMesh).size = Vector2(size, size)
