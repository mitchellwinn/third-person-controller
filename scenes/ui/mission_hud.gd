extends Control
class_name MissionHUD

## MissionHUD - Displays current deployment info in top-right corner
## Shows mission name, current objective, and hint text
## Syncs with squad - all members see the same deployment info

signal deployment_changed(mission_id: String)

#region Configuration
@export var fade_in_duration: float = 0.3
@export var update_animation_duration: float = 0.2
@export var pulse_urgent_objectives: bool = true
#endregion

#region Node References
@onready var panel: PanelContainer = $Panel
@onready var mission_label: Label = $Panel/VBox/MissionLabel
@onready var objective_label: Label = $Panel/VBox/ObjectiveLabel
@onready var hint_label: Label = $Panel/VBox/HintLabel
@onready var progress_bar: ProgressBar = $Panel/VBox/ProgressBar
@onready var timer_label: Label = $Panel/VBox/TimerLabel
#endregion

#region State
var current_mission_id: String = ""
var current_step_index: int = 0
var mission_data: Dictionary = {}
var is_squad_leader: bool = false
var _urgent_pulse_time: float = 0.0
var _original_objective_color: Color = Color.WHITE
#endregion

func _ready():
	# Start hidden
	visible = false
	modulate.a = 0.0
	
	# Store original colors for pulsing
	if objective_label:
		_original_objective_color = objective_label.get_theme_color("font_color", "Label")
	
	# Connect to mission manager if available
	_connect_to_mission_manager()
	
	# Connect to squad manager if available
	_connect_to_squad_manager()

func _process(delta: float):
	# Pulse urgent objectives
	if pulse_urgent_objectives and _is_current_step_urgent():
		_urgent_pulse_time += delta * 3.0
		var pulse = (sin(_urgent_pulse_time) + 1.0) * 0.5
		var urgent_color = _original_objective_color.lerp(Color(1.0, 0.3, 0.3), pulse * 0.6)
		if objective_label:
			objective_label.add_theme_color_override("font_color", urgent_color)
	else:
		if objective_label:
			objective_label.remove_theme_color_override("font_color")

func _connect_to_mission_manager():
	var mission_manager = get_node_or_null("/root/MissionManager")
	if mission_manager:
		if mission_manager.has_signal("mission_started"):
			mission_manager.mission_started.connect(_on_mission_started)
		if mission_manager.has_signal("mission_completed"):
			mission_manager.mission_completed.connect(_on_mission_completed)
		if mission_manager.has_signal("mission_failed"):
			mission_manager.mission_failed.connect(_on_mission_failed)
		if mission_manager.has_signal("mission_abandoned"):
			mission_manager.mission_abandoned.connect(_on_mission_abandoned)
		if mission_manager.has_signal("objective_updated"):
			mission_manager.objective_updated.connect(_on_objective_updated)
		if mission_manager.has_signal("step_changed"):
			mission_manager.step_changed.connect(_on_step_changed)

func _connect_to_squad_manager():
	var squad_manager = get_node_or_null("/root/SquadManager")
	if not squad_manager:
		squad_manager = get_node_or_null("../SquadManager")
	
	if squad_manager:
		if squad_manager.has_signal("squad_disbanded"):
			squad_manager.squad_disbanded.connect(_on_squad_disbanded)
		if squad_manager.has_signal("member_left"):
			squad_manager.member_left.connect(_on_member_left)

#region Public API
func set_deployment(mission_id: String, mission_info: Dictionary, step_index: int = 0):
	## Set the current deployment to display
	current_mission_id = mission_id
	mission_data = mission_info
	current_step_index = step_index
	
	_update_display()
	_show_with_animation()
	
	deployment_changed.emit(mission_id)

func clear_deployment():
	## Clear the deployment display
	current_mission_id = ""
	mission_data = {}
	current_step_index = 0
	
	_hide_with_animation()

func advance_step():
	## Move to the next step in the mission
	var steps = mission_data.get("steps", [])
	if current_step_index < steps.size() - 1:
		current_step_index += 1
		_update_display_animated()

func set_step(step_index: int):
	## Set a specific step
	var steps = mission_data.get("steps", [])
	if step_index >= 0 and step_index < steps.size():
		current_step_index = step_index
		_update_display_animated()

func set_step_by_id(step_id: String):
	## Set step by ID
	var steps = mission_data.get("steps", [])
	for i in range(steps.size()):
		if steps[i].get("id", "") == step_id:
			set_step(i)
			return

func update_timer(seconds_remaining: float):
	## Update the mission timer display
	if timer_label:
		if seconds_remaining > 0:
			timer_label.visible = true
			var minutes = int(seconds_remaining) / 60
			var secs = int(seconds_remaining) % 60
			timer_label.text = "%d:%02d" % [minutes, secs]
			
			# Color based on urgency
			if seconds_remaining < 60:
				timer_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			elif seconds_remaining < 180:
				timer_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
			else:
				timer_label.remove_theme_color_override("font_color")
		else:
			timer_label.visible = false

func update_progress(current: int, total: int):
	## Update the progress bar (for multi-part objectives)
	if progress_bar:
		if total > 1:
			progress_bar.visible = true
			progress_bar.max_value = total
			progress_bar.value = current
		else:
			progress_bar.visible = false

func set_squad_leader(is_leader: bool):
	## Update squad leader status
	is_squad_leader = is_leader
#endregion

#region Display Updates
func _update_display():
	if mission_data.is_empty():
		return
	
	# Mission name
	if mission_label:
		var mission_name = mission_data.get("short_name", mission_data.get("name", "Unknown Mission"))
		mission_label.text = mission_name
	
	# Current step info
	var steps = mission_data.get("steps", [])
	if current_step_index < steps.size():
		var step = steps[current_step_index]
		
		if objective_label:
			objective_label.text = step.get("hud_text", step.get("name", ""))
		
		if hint_label:
			var hint = step.get("hud_hint", "")
			hint_label.text = hint
			hint_label.visible = not hint.is_empty()
	
	# Progress (step X of Y)
	if progress_bar and steps.size() > 1:
		progress_bar.visible = true
		progress_bar.max_value = steps.size()
		progress_bar.value = current_step_index + 1
	elif progress_bar:
		progress_bar.visible = false
	
	# Timer (hide by default)
	if timer_label:
		timer_label.visible = false

func _update_display_animated():
	if not panel:
		_update_display()
		return
	
	# Quick fade out, update, fade in
	var tween = create_tween()
	tween.tween_property(panel, "modulate:a", 0.5, update_animation_duration * 0.5)
	tween.tween_callback(_update_display)
	tween.tween_property(panel, "modulate:a", 1.0, update_animation_duration * 0.5)

func _show_with_animation():
	visible = true
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 1.0, fade_in_duration)

func _hide_with_animation():
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 0.0, fade_in_duration)
	tween.tween_callback(func(): visible = false)

func _is_current_step_urgent() -> bool:
	var steps = mission_data.get("steps", [])
	if current_step_index < steps.size():
		return steps[current_step_index].get("urgent", false)
	return false
#endregion

#region Signal Handlers
func _on_mission_started(mission_id: String, _squad: Array):
	# Load mission data
	var mission_manager = get_node_or_null("/root/MissionManager")
	if mission_manager:
		var info = mission_manager.get_mission_info(mission_id)
		if not info.is_empty():
			# Also load full mission data with steps
			var full_data = _load_mission_data(mission_id)
			if not full_data.is_empty():
				set_deployment(mission_id, full_data, 0)

func _on_mission_completed(_mission_id: String, _result: Dictionary):
	clear_deployment()

func _on_mission_failed(_mission_id: String, _reason: String):
	clear_deployment()

func _on_mission_abandoned(_mission_id: String):
	clear_deployment()

func _on_objective_updated(_objective_id: String, _completed: bool):
	# Could show completion animation here
	pass

func _on_step_changed(step_index: int):
	set_step(step_index)

func _on_squad_disbanded():
	# Non-leaders lose deployment when squad disbands
	if not is_squad_leader:
		clear_deployment()

func _on_member_left(steam_id: int):
	# Check if it was us who left
	var steam_manager = get_node_or_null("/root/SteamManager")
	if steam_manager and steam_manager.get_steam_id() == steam_id:
		if not is_squad_leader:
			clear_deployment()
#endregion

#region Data Loading
func _load_mission_data(mission_id: String) -> Dictionary:
	## Load full mission data including steps from JSON
	var path = "res://data/missions/missions.json"
	if not FileAccess.file_exists(path):
		return {}
	
	var file = FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text())
	
	if data is Dictionary and data.has(mission_id):
		return data[mission_id]
	
	return {}
#endregion

#region Network Sync (for squad members)
func receive_deployment_sync(mission_id: String, step_index: int):
	## Called via RPC to sync deployment state from squad leader
	if mission_id.is_empty():
		clear_deployment()
		return
	
	var full_data = _load_mission_data(mission_id)
	if not full_data.is_empty():
		current_mission_id = mission_id
		mission_data = full_data
		current_step_index = step_index
		_update_display()
		if not visible:
			_show_with_animation()

func get_sync_data() -> Dictionary:
	## Get data to sync to squad members
	return {
		"mission_id": current_mission_id,
		"step_index": current_step_index
	}
#endregion



