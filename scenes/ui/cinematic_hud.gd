extends Control
class_name CinematicHUD

## CinematicHUD - Modern HUD with cinematic black bars
## Top bar: Player name, HP, Shield, Squad status
## Bottom bar: Weapon name, Stamina, Ammo
## Center: Crosshair with hit markers

signal hit_marker_shown()

#region Configuration
@export_group("Bars")
@export var bar_opacity: float = 0.7
@export var bar_color: Color = Color(0.02, 0.02, 0.04, 1.0)

@export_group("Crosshair")
@export var crosshair_color: Color = Color(1, 1, 1, 0.8)
@export var crosshair_size: float = 20.0
@export var line_thickness: float = 2.0
@export var center_gap: float = 6.0
@export var hit_marker_duration: float = 0.15
@export var hit_marker_color: Color = Color(1, 0.3, 0.3, 1)

@export_group("Colors")
@export var health_color: Color = Color(0.85, 0.25, 0.2, 1.0)
@export var health_bg_color: Color = Color(0.3, 0.1, 0.1, 0.6)
@export var shield_color: Color = Color(0.2, 0.6, 1.0, 1.0)
@export var shield_bg_color: Color = Color(0.1, 0.2, 0.3, 0.6)
@export var stamina_color: Color = Color(0.2, 0.8, 0.4, 0.9)
@export var stamina_low_color: Color = Color(0.9, 0.3, 0.2, 0.9)
@export var stamina_bg_color: Color = Color(0.1, 0.1, 0.1, 0.6)
#endregion

#region UI References
@onready var top_bar: Panel = $TopBar
@onready var bottom_bar: Panel = $BottomBar
@onready var crosshair: Control = $Crosshair

# Top bar elements
@onready var player_name_label: Label = %PlayerName
@onready var health_progress: ProgressBar = %HealthProgress
@onready var health_text: Label = %HealthText
@onready var shield_progress: ProgressBar = %ShieldProgress
@onready var shield_text: Label = %ShieldText
@onready var squad_section: HBoxContainer = %SquadSection

# Bottom bar elements
@onready var weapon_name_label: Label = %WeaponName
@onready var weapon_type_label: Label = %WeaponType
@onready var stamina_bar: ProgressBar = %StaminaBar
@onready var current_ammo_label: Label = %CurrentAmmo
@onready var reserve_ammo_label: Label = %ReserveAmmo
@onready var ammo_type_label: Label = %AmmoType
@onready var reload_bar: ProgressBar = %ReloadBar
#endregion

#region State
var _player_entity: Node = null
var _combat_component: Node = null
var _equipment_manager: Node = null
var _current_weapon: Node = null

var _hit_marker_timer: float = 0.0
var _spread_current: float = 0.0
var _spread_target: float = 0.0

# Smoothed display values
var _health_display: float = 100.0
var _shield_display: float = 100.0
var _stamina_display: float = 100.0

# Reload tracking
var _is_reloading: bool = false
var _reload_duration: float = 0.0
var _reload_elapsed: float = 0.0

var _squad_member_displays: Array[Control] = []
#endregion

func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Style the bars with semi-transparent black
	_style_bar(top_bar)
	_style_bar(bottom_bar)
	
	# Style progress bars
	_style_progress_bar(health_progress, health_color, health_bg_color)
	_style_progress_bar(shield_progress, shield_color, shield_bg_color)
	_style_progress_bar(stamina_bar, stamina_color, stamina_bg_color)
	
	# Style reload bar with a distinct color
	if reload_bar:
		var reload_color = Color(1.0, 0.8, 0.2, 1.0)  # Yellow/gold
		var reload_bg = Color(0.2, 0.15, 0.05, 0.6)
		_style_progress_bar(reload_bar, reload_color, reload_bg)
		reload_bar.visible = false
	
	# Connect to crosshair drawing
	crosshair.draw.connect(_draw_crosshair)
	
	# Find player after scene setup
	await get_tree().create_timer(0.5).timeout
	_find_local_player()

func _style_bar(bar: Panel):
	## Apply the semi-transparent dark style to a bar
	var style = StyleBoxFlat.new()
	style.bg_color = Color(bar_color.r, bar_color.g, bar_color.b, bar_opacity)
	# Subtle gradient effect
	style.border_width_top = 1
	style.border_color = Color(1, 1, 1, 0.05)
	bar.add_theme_stylebox_override("panel", style)

func _style_progress_bar(progress: ProgressBar, fill_color: Color, bg_color: Color):
	## Create custom styles for progress bars
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = bg_color
	bg_style.corner_radius_top_left = 2
	bg_style.corner_radius_top_right = 2
	bg_style.corner_radius_bottom_left = 2
	bg_style.corner_radius_bottom_right = 2
	
	var fill_style = StyleBoxFlat.new()
	fill_style.bg_color = fill_color
	fill_style.corner_radius_top_left = 2
	fill_style.corner_radius_top_right = 2
	fill_style.corner_radius_bottom_left = 2
	fill_style.corner_radius_bottom_right = 2
	
	progress.add_theme_stylebox_override("background", bg_style)
	progress.add_theme_stylebox_override("fill", fill_style)

func _find_local_player():
	## Find and connect to the local player entity
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if "can_receive_input" in player and player.can_receive_input:
			_connect_to_player(player)
			break

func _connect_to_player(player: Node):
	_player_entity = player
	
	# Get components
	_combat_component = player.get_node_or_null("CombatComponent")
	_equipment_manager = player.get_node_or_null("EquipmentManager")
	
	# Connect signals
	if player.has_signal("stamina_changed"):
		player.stamina_changed.connect(_on_stamina_changed)
	
	if _combat_component:
		if _combat_component.has_signal("health_changed"):
			_combat_component.health_changed.connect(_on_health_changed)
		if _combat_component.has_signal("shield_changed"):
			_combat_component.shield_changed.connect(_on_shield_changed)
		# Initialize values
		_health_display = _combat_component.current_health
		_shield_display = _combat_component.current_shields
		health_progress.max_value = _combat_component.max_health
		shield_progress.max_value = _combat_component.max_shields
	
	# Set player name from entity, NetworkManager, or Steam
	var name_to_show = _get_player_display_name(player)
	player_name_label.text = name_to_show
	
	# Initialize stamina
	if "current_stamina" in player and "max_stamina" in player:
		_stamina_display = player.current_stamina
		stamina_bar.max_value = player.max_stamina
	
	print("[CinematicHUD] Connected to local player")

func _get_player_display_name(player: Node) -> String:
	## Get display name from various sources with fallbacks
	
	# First try: entity's display_name property (set by MultiplayerScene)
	if "display_name" in player and not player.display_name.is_empty():
		return player.display_name
	
	# Second try: NetworkManager's player data
	var network = get_node_or_null("/root/NetworkManager")
	if network:
		var peer_id = 1
		if multiplayer and multiplayer.has_multiplayer_peer():
			peer_id = multiplayer.get_unique_id()
		
		if network.connected_peers.has(peer_id):
			var pd = network.connected_peers[peer_id]
			if not pd.display_name.is_empty():
				return pd.display_name
	
	# Third try: SteamManager directly
	var steam_manager = get_node_or_null("/root/SteamManager")
	if steam_manager and steam_manager.has_method("get_persona_name"):
		var steam_name = steam_manager.get_persona_name()
		if not steam_name.is_empty():
			return steam_name
	
	# Fallback
	if "entity_id" in player and not player.entity_id.is_empty():
		return player.entity_id
	
	return "PLAYER"

func _on_health_changed(current: float, maximum: float):
	health_progress.max_value = maximum
	_health_display = current

func _on_shield_changed(current: float, maximum: float):
	shield_progress.max_value = maximum
	_shield_display = current

func _on_stamina_changed(current: float, maximum: float):
	stamina_bar.max_value = maximum
	_stamina_display = current

func _process(delta: float):
	# Update hit marker timer
	if _hit_marker_timer > 0:
		_hit_marker_timer -= delta
	
	# Smooth spread changes
	_spread_current = lerp(_spread_current, _spread_target, 15.0 * delta)
	
	# Smooth bar animations
	if health_progress:
		health_progress.value = lerp(health_progress.value, _health_display, 10.0 * delta)
	if shield_progress:
		shield_progress.value = lerp(shield_progress.value, _shield_display, 10.0 * delta)
	if stamina_bar:
		stamina_bar.value = lerp(stamina_bar.value, _stamina_display, 10.0 * delta)
		_update_stamina_color()
	
	# Update text displays
	_update_health_display()
	_update_shield_display()
	_update_weapon_display()
	_update_reload_bar(delta)
	
	# Try to reconnect to player if lost
	if not is_instance_valid(_player_entity):
		_player_entity = null
		_combat_component = null
		_equipment_manager = null
		_disconnect_weapon_signals()
		_current_weapon = null
		_find_local_player()
	
	# Update crosshair
	if crosshair:
		crosshair.queue_redraw()

func _update_health_display():
	if not _combat_component:
		return
	
	var current = int(health_progress.value)
	var maximum = int(_combat_component.max_health)
	health_text.text = "%d/%d" % [current, maximum]

func _update_shield_display():
	if not _combat_component:
		return
	
	var current = int(shield_progress.value)
	var maximum = int(_combat_component.max_shields)
	shield_text.text = "%d/%d" % [current, maximum]
	
	# Update shield display from combat component
	_shield_display = _combat_component.current_shields

func _update_stamina_color():
	## Change stamina bar color when low
	var percent = stamina_bar.value / stamina_bar.max_value if stamina_bar.max_value > 0 else 1.0
	
	var fill_style = stamina_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill_style:
		if percent < 0.25:
			fill_style.bg_color = stamina_low_color
		elif percent < 0.4:
			var blend = (percent - 0.25) / 0.15
			fill_style.bg_color = stamina_low_color.lerp(stamina_color, blend)
		else:
			fill_style.bg_color = stamina_color

func _update_reload_bar(delta: float):
	## Update reload progress bar
	if not reload_bar:
		return
	
	if _is_reloading:
		_reload_elapsed += delta
		var progress = clampf(_reload_elapsed / _reload_duration, 0.0, 1.0) if _reload_duration > 0 else 1.0
		reload_bar.value = progress
		reload_bar.visible = true
	else:
		reload_bar.visible = false

func _update_weapon_display():
	if not is_instance_valid(_player_entity):
		return

	# Get current weapon from equipment manager
	if _equipment_manager and _equipment_manager.has_method("get_current_weapon"):
		var weapon = _equipment_manager.get_current_weapon()

		# Validate weapon reference - it may have been freed
		if not is_instance_valid(weapon):
			weapon = null

		# Connect to new weapon signals if weapon changed
		if weapon != _current_weapon:
			_disconnect_weapon_signals()
			_current_weapon = weapon
			_connect_weapon_signals()

		if weapon:
			# Update weapon name
			if "weapon_name" in weapon:
				weapon_name_label.text = weapon.weapon_name.to_upper()
			elif "name" in weapon:
				weapon_name_label.text = weapon.name.to_upper()

			# Update weapon type - show slot number
			var slot = _equipment_manager.current_slot if "current_slot" in _equipment_manager else "weapon_1"
			match slot:
				"weapon_1":
					weapon_type_label.text = "Weapon 1"
				"weapon_2":
					weapon_type_label.text = "Weapon 2"
				"weapon_3":
					weapon_type_label.text = "Weapon 3"
				_:
					weapon_type_label.text = "Weapon"

			# Update ammo display
			if weapon.has_method("get_ammo_display"):
				var ammo_data = weapon.get_ammo_display()
				current_ammo_label.text = str(ammo_data.get("current", 0))
				reserve_ammo_label.text = str(ammo_data.get("reserve", 0))
				ammo_type_label.text = ammo_data.get("type", "").to_upper()
			elif "current_ammo" in weapon:
				current_ammo_label.text = str(weapon.current_ammo)
				# Get reserve directly from weapon component (not database - clients can't access it)
				if "reserve_ammo" in weapon:
					reserve_ammo_label.text = str(weapon.reserve_ammo)
				else:
					reserve_ammo_label.text = "0"

				# Get ammo type name
				if "ammo_type" in weapon and not weapon.ammo_type.is_empty():
					ammo_type_label.text = _get_ammo_type_name(weapon.ammo_type)
				else:
					ammo_type_label.text = ""
			else:
				# Melee or infinite ammo
				current_ammo_label.text = "∞"
				reserve_ammo_label.text = ""
				ammo_type_label.text = ""
		else:
			# No weapon equipped - clear weapon display
			weapon_name_label.text = "UNARMED"
			weapon_type_label.text = ""
			current_ammo_label.text = "-"
			reserve_ammo_label.text = ""
			ammo_type_label.text = ""

func _get_ammo_type_name(ammo_type: String) -> String:
	match ammo_type:
		"energy_light":
			return "LIGHT CELLS"
		"energy_medium":
			return "MEDIUM CELLS"
		"energy_heavy":
			return "HEAVY CELLS"
		"grenades":
			return "GRENADES"
		_:
			return ammo_type.to_upper().replace("_", " ")

#region Weapon Signal Connections
func _connect_weapon_signals():
	if not is_instance_valid(_current_weapon):
		return
	
	if _current_weapon.has_signal("reload_started"):
		if not _current_weapon.reload_started.is_connected(_on_reload_started):
			_current_weapon.reload_started.connect(_on_reload_started)
	
	if _current_weapon.has_signal("reload_finished"):
		if not _current_weapon.reload_finished.is_connected(_on_reload_finished):
			_current_weapon.reload_finished.connect(_on_reload_finished)

func _disconnect_weapon_signals():
	if not is_instance_valid(_current_weapon):
		return
	
	if _current_weapon.has_signal("reload_started"):
		if _current_weapon.reload_started.is_connected(_on_reload_started):
			_current_weapon.reload_started.disconnect(_on_reload_started)
	
	if _current_weapon.has_signal("reload_finished"):
		if _current_weapon.reload_finished.is_connected(_on_reload_finished):
			_current_weapon.reload_finished.disconnect(_on_reload_finished)

func _on_reload_started():
	_is_reloading = true
	_reload_elapsed = 0.0
	# Get reload duration from weapon
	if is_instance_valid(_current_weapon) and "reload_time" in _current_weapon:
		_reload_duration = _current_weapon.reload_time
	else:
		_reload_duration = 1.0  # Default fallback

func _on_reload_finished():
	_is_reloading = false
	_reload_elapsed = 0.0
	if reload_bar:
		reload_bar.visible = false
#endregion

#region Crosshair Drawing
func _draw_crosshair():
	var center = crosshair.size / 2.0
	var color = hit_marker_color if _hit_marker_timer > 0 else crosshair_color
	
	var half_size = crosshair_size / 2.0 + _spread_current
	var gap = center_gap + _spread_current * 0.5
	
	# Draw four lines (cross pattern with gap in middle)
	crosshair.draw_line(center + Vector2(0, -gap), center + Vector2(0, -half_size), color, line_thickness)
	crosshair.draw_line(center + Vector2(0, gap), center + Vector2(0, half_size), color, line_thickness)
	crosshair.draw_line(center + Vector2(-gap, 0), center + Vector2(-half_size, 0), color, line_thickness)
	crosshair.draw_line(center + Vector2(gap, 0), center + Vector2(half_size, 0), color, line_thickness)
#endregion

#region Public API
func show_hit_marker():
	## Flash the crosshair to indicate a hit
	_hit_marker_timer = hit_marker_duration
	hit_marker_shown.emit()

func set_spread(spread_degrees: float):
	## Set crosshair spread based on weapon accuracy
	_spread_target = spread_degrees * 3.0

func set_aiming(is_aiming: bool):
	## Tighten crosshair when aiming
	if is_aiming:
		crosshair_size = 14.0
		center_gap = 4.0
	else:
		crosshair_size = 20.0
		center_gap = 6.0

func set_player(player: Node):
	## Manually set the player to track
	print("[CinematicHUD] set_player called with: ", player.name if player else "null")
	_connect_to_player(player)

func add_squad_member(member_name: String, health_percent: float, shield_percent: float):
	## Add a squad member display to the top bar
	var member_display = _create_squad_member_display(member_name, health_percent, shield_percent)
	squad_section.add_child(member_display)
	_squad_member_displays.append(member_display)

func update_squad_member(index: int, health_percent: float, shield_percent: float):
	## Update a squad member's health and shield display
	if index < 0 or index >= _squad_member_displays.size():
		return
	
	var display = _squad_member_displays[index]
	var hp_bar = display.get_node_or_null("HealthBar")
	var shield_bar = display.get_node_or_null("ShieldBar")
	
	if hp_bar:
		hp_bar.value = health_percent * 100
	if shield_bar:
		shield_bar.value = shield_percent * 100

func remove_squad_member(index: int):
	## Remove a squad member display
	if index < 0 or index >= _squad_member_displays.size():
		return
	
	var display = _squad_member_displays[index]
	_squad_member_displays.remove_at(index)
	display.queue_free()

func clear_squad():
	## Remove all squad member displays
	for display in _squad_member_displays:
		display.queue_free()
	_squad_member_displays.clear()

func _create_squad_member_display(member_name: String, health_percent: float, shield_percent: float) -> Control:
	## Create a compact squad member health/shield display
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)
	
	# Name label
	var name_label = Label.new()
	name_label.text = member_name
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9, 1))
	container.add_child(name_label)
	
	# Health bar (smaller)
	var hp_bar = ProgressBar.new()
	hp_bar.name = "HealthBar"
	hp_bar.custom_minimum_size = Vector2(100, 8)
	hp_bar.max_value = 100
	hp_bar.value = health_percent * 100
	hp_bar.show_percentage = false
	_style_progress_bar(hp_bar, health_color, health_bg_color)
	container.add_child(hp_bar)
	
	# Shield bar (even smaller)
	var shield_bar = ProgressBar.new()
	shield_bar.name = "ShieldBar"
	shield_bar.custom_minimum_size = Vector2(100, 5)
	shield_bar.max_value = 100
	shield_bar.value = shield_percent * 100
	shield_bar.show_percentage = false
	_style_progress_bar(shield_bar, shield_color, shield_bg_color)
	container.add_child(shield_bar)
	
	return container
#endregion

