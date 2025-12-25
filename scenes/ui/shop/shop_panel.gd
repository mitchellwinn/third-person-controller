extends Control
class_name ShopPanel

## Shop UI for buying weapons and supplies from NPCs
## Loads inventory from JSON files in data/shops/

signal item_purchased(item_id: String, quantity: int)
signal shop_closed()

@export var player_credits: int = 5000

# Shop data loaded from JSON
var _shop_data: Dictionary = {}
var _shop_inventory: Array[Dictionary] = []  # Merged with item definitions
var _selected_item: Dictionary = {}
var _selected_quantity: int = 1
var _current_category: String = "weapon"
var _price_multiplier: float = 1.0

# Character info for purchases
var _character_id: int = -1
var _steam_id: int = 0

# UI References
@onready var credits_label: Label = %CreditsLabel
@onready var items_list: VBoxContainer = %ItemsList
@onready var preview_icon: Label = %PreviewIcon
@onready var item_name_label: Label = %ItemNameLabel
@onready var item_type_label: Label = %ItemTypeLabel
@onready var item_description: RichTextLabel = %ItemDescription
@onready var stats_container: HBoxContainer = %StatsContainer
@onready var price_value: Label = %PriceValue
@onready var quantity_row: HBoxContainer = %QuantityRow
@onready var quantity_value: Label = %QuantityValue
@onready var buy_button: Button = %BuyButton
@onready var vendor_label: Label = %VendorLabel
@onready var weapons_tab: Button = %WeaponsTab
@onready var ammo_tab: Button = %AmmoTab
@onready var gear_tab: Button = %GearTab

# Item type icons
const ITEM_ICONS = {
	"rifle": "⌘",
	"smg": "⌖",
	"pistol": "⚡",
	"launcher": "◉",
	"melee": "⚔",
	"ammo": "▣",
	"gear": "◈"
}

# Rarity colors
const RARITY_COLORS = {
	"common": Color(0.7, 0.7, 0.72),
	"uncommon": Color(0.3, 0.85, 0.4),
	"rare": Color(0.3, 0.6, 0.95),
	"epic": Color(0.7, 0.3, 0.9),
	"legendary": Color(1.0, 0.75, 0.2)
}

const SHOPS_PATH = "res://data/shops/"

func _ready():
	# Connect buttons
	$MainContainer/MainPanel/PanelMargin/VerticalLayout/HeaderBar/HeaderMargin/HeaderContent/CloseButton.pressed.connect(_on_close_pressed)
	buy_button.pressed.connect(_on_buy_pressed)
	
	# Category tabs
	weapons_tab.pressed.connect(_on_weapons_tab)
	ammo_tab.pressed.connect(_on_ammo_tab)
	gear_tab.pressed.connect(_on_gear_tab)
	
	# Quantity buttons
	var minus_btn = quantity_row.get_node("MinusBtn")
	var plus_btn = quantity_row.get_node("PlusBtn")
	minus_btn.pressed.connect(_on_quantity_decrease)
	plus_btn.pressed.connect(_on_quantity_increase)
	
	# Block input from passing through to the game
	mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Add to group so state_talking knows we need mouse visible
	add_to_group("ui_needs_mouse")
	
	# Hide by default
	visible = false

func _unhandled_input(event: InputEvent):
	if not visible:
		return

	# ESC to close
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open(shop_id: String = "supply_officer", character_id: int = -1, steam_id: int = 0):
	## Open the shop with a specific shop ID (loads from JSON)
	_character_id = character_id
	_steam_id = steam_id
	
	# Load shop data from JSON
	_load_shop_data(shop_id)
	
	# Update vendor label
	vendor_label.text = "Vendor: " + _shop_data.get("name", "Unknown Vendor")
	
	# Get player credits from database
	_load_player_credits()
	
	visible = true
	_refresh_items_list()
	_clear_selection()
	grab_focus()

func open_with_name(vendor_name: String, character_id: int = -1, steam_id: int = 0):
	## Legacy open function - opens default shop with custom name
	open("supply_officer", character_id, steam_id)
	vendor_label.text = "Vendor: " + vendor_name

func close():
	visible = false
	shop_closed.emit()

func _get_local_player() -> Node:
	## Get the local player node
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if "can_receive_input" in player and player.can_receive_input:
			return player
	return null

func _load_shop_data(shop_id: String):
	## Load shop inventory from JSON file
	var file_path = SHOPS_PATH + shop_id + ".json"
	
	if not FileAccess.file_exists(file_path):
		push_warning("[ShopPanel] Shop file not found: " + file_path + ", using default")
		file_path = SHOPS_PATH + "supply_officer.json"
	
	if not FileAccess.file_exists(file_path):
		push_error("[ShopPanel] Default shop file not found!")
		_shop_data = {"name": "Shop", "inventory": []}
		_shop_inventory.clear()
		return
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("[ShopPanel] Failed to parse shop JSON: " + json.get_error_message())
		_shop_data = {"name": "Shop", "inventory": []}
		_shop_inventory.clear()
		return
	
	_shop_data = json.data
	_price_multiplier = _shop_data.get("price_multiplier", 1.0)
	
	# Build inventory by merging shop entries with item definitions
	_build_shop_inventory()
	
	print("[ShopPanel] Loaded shop: %s with %d items" % [_shop_data.get("name", shop_id), _shop_inventory.size()])

func _build_shop_inventory():
	## Merge shop inventory entries with full item definitions
	_shop_inventory.clear()
	
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		push_warning("[ShopPanel] ItemDatabase not found")
		return
	
	var all_items = item_db.get_all_items()
	var shop_entries = _shop_data.get("inventory", [])
	
	for entry in shop_entries:
		var item_id = entry.get("item_id", "")
		if item_id.is_empty():
			continue
		
		if not all_items.has(item_id):
			push_warning("[ShopPanel] Unknown item in shop: " + item_id)
			continue
		
		# Clone the item definition
		var item = all_items[item_id].duplicate(true)
		
		# Apply shop-specific overrides
		item["_shop_stock"] = entry.get("stock", -1)  # -1 = unlimited
		
		# Apply price override or multiplier
		var price_override = entry.get("price_override")
		if price_override != null and price_override > 0:
			item["shop_price"] = int(price_override)
		else:
			item["shop_price"] = int(item.get("base_value", 0) * _price_multiplier)
		
		_shop_inventory.append(item)

func _load_player_credits():
	## Load player credits from database
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db and _character_id > 0:
		player_credits = item_db.get_player_credits(_character_id)
	_update_credits_display()

func _update_credits_display():
	credits_label.text = _format_number(player_credits)

func _format_number(n: int) -> String:
	## Format number with commas
	var s = str(n)
	var result = ""
	var count = 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = "," + result
		result = s[i] + result
		count += 1
	return result

func _refresh_items_list():
	## Refresh the displayed items based on current category
	# Clear existing items
	for child in items_list.get_children():
		child.queue_free()
	
	# Filter by category
	var filtered_items = _shop_inventory.filter(func(item):
		# Skip out of stock items (stock = 0)
		var stock = item.get("_shop_stock", -1)
		if stock == 0:
			return false
		
		if _current_category == "weapon":
			return item.get("type") == "weapon"
		elif _current_category == "ammo":
			return item.get("type") == "ammo"
		elif _current_category == "gear":
			return item.get("type") == "gear" or item.get("type") == "consumable"
		return false
	)
	
	# Sort by rarity then name
	filtered_items.sort_custom(func(a, b):
		var rarity_order = ["common", "uncommon", "rare", "epic", "legendary"]
		var ra = rarity_order.find(a.get("rarity", "common"))
		var rb = rarity_order.find(b.get("rarity", "common"))
		if ra != rb:
			return ra < rb
		return a.get("name", "") < b.get("name", "")
	)
	
	# Create item entries
	for item in filtered_items:
		var entry = _create_item_entry(item)
		items_list.add_child(entry)

func _create_item_entry(item: Dictionary) -> Control:
	## Create a clickable item entry for the shop list
	var entry = PanelContainer.new()
	entry.custom_minimum_size = Vector2(0, 56)
	
	# Background
	var bg = ColorRect.new()
	bg.color = Color(0.1, 0.105, 0.115, 1)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.add_child(bg)
	
	# Margin
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	entry.add_child(margin)
	
	# Content HBox
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	margin.add_child(hbox)
	
	# Icon
	var icon = Label.new()
	icon.custom_minimum_size = Vector2(32, 32)
	var subtype = item.get("subtype", item.get("type", ""))
	icon.text = ITEM_ICONS.get(subtype, "◇")
	icon.add_theme_font_size_override("font_size", 24)
	var rarity = item.get("rarity", "common")
	icon.add_theme_color_override("font_color", RARITY_COLORS.get(rarity, Color.WHITE))
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(icon)
	
	# Name/Type VBox
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)
	
	var name_label = Label.new()
	name_label.text = item.get("name", "Unknown")
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", RARITY_COLORS.get(rarity, Color.WHITE))
	vbox.add_child(name_label)
	
	# Type + stock info
	var type_text = subtype.to_upper() if not subtype.is_empty() else item.get("type", "").to_upper()
	var stock = item.get("_shop_stock", -1)
	if stock > 0:
		type_text += " • %d in stock" % stock
	
	var type_label = Label.new()
	type_label.text = type_text
	type_label.add_theme_font_size_override("font_size", 10)
	type_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	vbox.add_child(type_label)
	
	# Price (use shop_price)
	var price_hbox = HBoxContainer.new()
	price_hbox.add_theme_constant_override("separation", 4)
	hbox.add_child(price_hbox)
	
	var price_icon = Label.new()
	price_icon.text = "◈"
	price_icon.add_theme_font_size_override("font_size", 14)
	price_icon.add_theme_color_override("font_color", Color(0.4, 0.85, 0.55))
	price_hbox.add_child(price_icon)
	
	var price_label = Label.new()
	price_label.text = _format_number(item.get("shop_price", item.get("base_value", 0)))
	price_label.add_theme_font_size_override("font_size", 14)
	price_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.55))
	price_hbox.add_child(price_label)
	
	# Click handler
	entry.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_select_item(item)
			# Update visual selection
			for child in items_list.get_children():
				var child_bg = child.get_child(0) as ColorRect
				if child_bg:
					child_bg.color = Color(0.1, 0.105, 0.115, 1)
			bg.color = Color(0.18, 0.2, 0.22, 1)
	)
	
	# Hover effect
	entry.mouse_entered.connect(func():
		if bg.color != Color(0.18, 0.2, 0.22, 1):
			bg.color = Color(0.13, 0.14, 0.15, 1)
	)
	entry.mouse_exited.connect(func():
		if bg.color != Color(0.18, 0.2, 0.22, 1):
			bg.color = Color(0.1, 0.105, 0.115, 1)
	)
	
	return entry

func _select_item(item: Dictionary):
	## Select an item to view details
	_selected_item = item
	_selected_quantity = 1
	
	# Update preview
	var subtype = item.get("subtype", item.get("type", ""))
	preview_icon.text = ITEM_ICONS.get(subtype, "◇")
	var rarity = item.get("rarity", "common")
	preview_icon.add_theme_color_override("font_color", RARITY_COLORS.get(rarity, Color.WHITE))
	
	# Update name and type
	item_name_label.text = item.get("name", "Unknown")
	item_name_label.add_theme_color_override("font_color", RARITY_COLORS.get(rarity, Color.WHITE))
	item_type_label.text = (subtype.to_upper() if not subtype.is_empty() else item.get("type", "").to_upper()) + " • " + rarity.to_upper()
	
	# Update description
	item_description.text = item.get("description", "No description available.")
	
	# Update stats based on item type
	_update_stats_display(item)
	
	# Update price (use shop_price)
	var unit_price = item.get("shop_price", item.get("base_value", 0))
	price_value.text = _format_number(unit_price)
	
	# Show quantity selector for ammo
	var is_ammo = item.get("type") == "ammo"
	quantity_row.visible = is_ammo
	if is_ammo:
		_selected_quantity = 10  # Default to buying 10 ammo
		quantity_value.text = str(_selected_quantity)
		_update_total_price()
	
	# Enable buy button if can afford
	var total_cost = unit_price * _selected_quantity
	buy_button.disabled = player_credits < total_cost
	buy_button.text = "PURCHASE" if player_credits >= total_cost else "INSUFFICIENT CREDITS"

func _update_stats_display(item: Dictionary):
	## Update stats display based on item type
	var stat1 = stats_container.get_node("Stat1")
	var stat2 = stats_container.get_node("Stat2")
	var stat3 = stats_container.get_node("Stat3")
	
	if item.get("type") == "weapon":
		var weapon_data = item.get("weapon_data", {})
		
		# Stat 1: Damage
		stat1.get_node("Label").text = "DAMAGE"
		stat1.get_node("Value").text = str(weapon_data.get("damage", "--"))
		
		# Stat 2: Fire Rate or Attack Speed
		if weapon_data.has("fire_rate"):
			stat2.get_node("Label").text = "FIRE RATE"
			stat2.get_node("Value").text = str(weapon_data.fire_rate) + "/s"
		elif weapon_data.has("attack_speed"):
			stat2.get_node("Label").text = "ATTACK SPEED"
			stat2.get_node("Value").text = str(weapon_data.attack_speed)
		else:
			stat2.get_node("Label").text = "FIRE RATE"
			stat2.get_node("Value").text = "--"
		
		# Stat 3: Range or Clip Size
		if weapon_data.has("range"):
			stat3.get_node("Label").text = "RANGE"
			stat3.get_node("Value").text = str(weapon_data.range) + "m"
		elif weapon_data.has("attack_range"):
			stat3.get_node("Label").text = "RANGE"
			stat3.get_node("Value").text = str(weapon_data.attack_range) + "m"
		else:
			stat3.get_node("Label").text = "RANGE"
			stat3.get_node("Value").text = "--"
		
		stats_container.visible = true
		
	elif item.get("type") == "ammo":
		stat1.get_node("Label").text = "STACK SIZE"
		stat1.get_node("Value").text = str(item.get("stack_size", 999))
		
		stat2.get_node("Label").text = "AMMO TYPE"
		stat2.get_node("Value").text = item.get("ammo_type", "--").replace("_", " ").to_upper()
		
		stat3.get_node("Label").text = ""
		stat3.get_node("Value").text = ""
		
		stats_container.visible = true
	else:
		stats_container.visible = false

func _update_total_price():
	var unit_price = _selected_item.get("shop_price", _selected_item.get("base_value", 0))
	var total = unit_price * _selected_quantity
	price_value.text = _format_number(total)
	
	buy_button.disabled = player_credits < total
	buy_button.text = "PURCHASE" if player_credits >= total else "INSUFFICIENT CREDITS"

func _clear_selection():
	_selected_item = {}
	_selected_quantity = 1
	
	preview_icon.text = "⌘"
	preview_icon.add_theme_color_override("font_color", Color(0.3, 0.3, 0.35))
	item_name_label.text = "Select an item"
	item_name_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.92))
	item_type_label.text = "BROWSE THE SHOP"
	item_description.text = "Choose a weapon or supply from the inventory on the left to view its details."
	price_value.text = "---"
	quantity_row.visible = false
	stats_container.visible = false
	buy_button.disabled = true

#region Button Handlers
func _on_close_pressed():
	close()

func _on_buy_pressed():
	if _selected_item.is_empty():
		return
	
	var item_id = _selected_item.get("id", "")
	var unit_price = _selected_item.get("shop_price", _selected_item.get("base_value", 0))
	var total_cost = unit_price * _selected_quantity
	
	if player_credits < total_cost:
		push_warning("[ShopPanel] Cannot afford item")
		return
	
	# Check stock
	var stock = _selected_item.get("_shop_stock", -1)
	if stock >= 0 and stock < _selected_quantity:
		push_warning("[ShopPanel] Not enough stock")
		return
	
	# Deduct credits
	player_credits -= total_cost
	_update_credits_display()
	
	# Add item to inventory
	var item_db = get_node_or_null("/root/ItemDatabase")
	if item_db and _character_id > 0:
		# Save credits to database
		item_db.set_player_credits(_character_id, player_credits)
		
		# Add item to inventory
		var inv_id = item_db.add_to_inventory(_steam_id, _character_id, item_id, _selected_quantity)
		if inv_id > 0:
			print("[ShopPanel] Purchased %s x%d for %d credits" % [item_id, _selected_quantity, total_cost])
			item_purchased.emit(item_id, _selected_quantity)
			
			# Update stock in our local inventory
			if stock > 0:
				_selected_item["_shop_stock"] = stock - _selected_quantity
				# Update the master list too
				for item in _shop_inventory:
					if item.get("id") == item_id:
						item["_shop_stock"] = _selected_item["_shop_stock"]
						break
				
				# Refresh list to show updated stock
				_refresh_items_list()
	
	# Reset quantity for ammo
	if _selected_item.get("type") == "ammo":
		_selected_quantity = 10
		quantity_value.text = str(_selected_quantity)
		_update_total_price()

func _on_weapons_tab():
	_current_category = "weapon"
	weapons_tab.button_pressed = true
	ammo_tab.button_pressed = false
	gear_tab.button_pressed = false
	_refresh_items_list()
	_clear_selection()

func _on_ammo_tab():
	_current_category = "ammo"
	weapons_tab.button_pressed = false
	ammo_tab.button_pressed = true
	gear_tab.button_pressed = false
	_refresh_items_list()
	_clear_selection()

func _on_gear_tab():
	_current_category = "gear"
	weapons_tab.button_pressed = false
	ammo_tab.button_pressed = false
	gear_tab.button_pressed = true
	_refresh_items_list()
	_clear_selection()

func _on_quantity_decrease():
	if _selected_quantity > 1:
		_selected_quantity -= 10 if _selected_quantity > 10 else 1
		_selected_quantity = maxi(_selected_quantity, 1)
		quantity_value.text = str(_selected_quantity)
		_update_total_price()

func _on_quantity_increase():
	var stack_size = _selected_item.get("stack_size", 999)
	var stock = _selected_item.get("_shop_stock", -1)
	var max_qty = stack_size
	if stock > 0:
		max_qty = mini(stack_size, stock)
	
	if _selected_quantity < max_qty:
		_selected_quantity += 10
		_selected_quantity = mini(_selected_quantity, max_qty)
		quantity_value.text = str(_selected_quantity)
		_update_total_price()
#endregion
