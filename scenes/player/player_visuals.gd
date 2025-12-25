extends Node3D
class_name PlayerVisuals

## Handles visual customization for the player model
## Attach to MeshRoot to affect all child meshes

@export var unlit: bool = true
@export var custom_color: Color = Color.WHITE # Set to change tint (WHITE = no tint)
@export var use_custom_color: bool = false

func _ready():
	if unlit:
		set_all_unlit()
	if use_custom_color:
		set_all_color(custom_color)

func set_all_unlit():
	## Make all materials on child meshes unlit (no shading)
	_apply_to_all_materials(func(mat: BaseMaterial3D):
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	)
	print("[PlayerVisuals] Set all materials to unlit")

func set_all_lit():
	## Restore normal shading
	_apply_to_all_materials(func(mat: BaseMaterial3D):
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	)

func set_all_color(color: Color):
	## Tint all materials with a color
	_apply_to_all_materials(func(mat: BaseMaterial3D):
		mat.albedo_color = color
	)

func set_all_transparency(alpha: float):
	## Set transparency on all materials
	_apply_to_all_materials(func(mat: BaseMaterial3D):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var col = mat.albedo_color
		col.a = alpha
		mat.albedo_color = col
	)

func _apply_to_all_materials(modifier: Callable):
	## Iterate all MeshInstance3D children and apply modifier to their materials
	_process_node(self, modifier)

func _process_node(node: Node, modifier: Callable):
	if node is MeshInstance3D:
		var mesh_instance = node as MeshInstance3D
		
		# Process surface materials
		for i in range(mesh_instance.get_surface_override_material_count()):
			var mat = mesh_instance.get_surface_override_material(i)
			if mat == null and mesh_instance.mesh:
				# Get material from mesh and make a unique copy
				mat = mesh_instance.mesh.surface_get_material(i)
				if mat:
					mat = mat.duplicate()
					mesh_instance.set_surface_override_material(i, mat)
			
			if mat is BaseMaterial3D:
				modifier.call(mat)
		
		# Also check material_override
		if mesh_instance.material_override:
			if mesh_instance.material_override is BaseMaterial3D:
				var mat = mesh_instance.material_override.duplicate()
				modifier.call(mat)
				mesh_instance.material_override = mat
	
	# Recurse into children
	for child in node.get_children():
		_process_node(child, modifier)



