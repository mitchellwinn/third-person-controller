extends Node3D

## Generic Lifetime Effect
## Simple script to animate shader lifetime parameter and auto-free when done

@export var lifetime: float = 0.5  # Total duration in seconds
@export var auto_start: bool = true  # Start automatically on ready

var _current_time: float = 0.0
var _is_playing: bool = false
var _sprite: Sprite3D
var _material: ShaderMaterial

func _ready():
	_sprite = $Sprite3D
	_material = _sprite.material_override as ShaderMaterial

	if auto_start:
		play()

func _process(delta: float):
	if not _is_playing:
		return

	# Billboard mode on Sprite3D handles camera facing automatically
	# No need to look_at - it causes errors when aligned with UP vector

	_current_time += delta

	if _current_time >= lifetime:
		queue_free()  # Auto-free when done
		return

	_update_lifetime()

func play():
	_current_time = 0.0
	_is_playing = true
	_update_lifetime()

func stop():
	_is_playing = false
	_current_time = 0.0
	_update_lifetime()

func _update_lifetime():
	if _material:
		var progress = _current_time / lifetime
		_material.set_shader_parameter("lifetime", progress)
