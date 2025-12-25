extends PanelContainer
class_name InventorySlot

## A single inventory slot that can hold an item
## Supports drag & drop and double-click to equip
## Layout is defined in inventory_slot.tscn for editor customization

signal item_clicked(slot: InventorySlot)
signal item_double_clicked(slot: InventorySlot)
signal item_right_clicked(slot: InventorySlot, mouse_pos: Vector2)
signal drag_started(slot: InventorySlot)
signal drag_ended(slot: InventorySlot, target: InventorySlot)
signal items_stacked(source_slot: InventorySlot, target_slot: InventorySlot)

## Slot type for filtering what items can go where
enum SlotType {
	INVENTORY,
	EQUIPMENT_WEAPON_1,
	EQUIPMENT_WEAPON_2,
	EQUIPMENT_WEAPON_3,
	EQUIPMENT_HEAD,
	EQUIPMENT_ARMOR,
	EQUIPMENT_GADGET,
	EQUIPMENT_CONSUMABLE
}

@export var slot_type: SlotType = SlotType.INVENTORY
@export var slot_index: int = 0
@export var slot_label: String = ""  ## Label shown when slot is empty

## Item data (from ItemDatabase)
var item_data: Dictionary = {}
var inventory_id: int = -1  # SQLite inventory_id

## UI node references (found from scene tree)
@onready var icon_rect: TextureRect = $MarginContainer/VBox/IconRect
@onready var icon_label: Label = $MarginContainer/VBox/IconLabel
@onready var name_label: Label = $MarginContainer/VBox/NameLabel
@onready var highlight: ColorRect = $Highlight
@onready var quantity_label: Label = $QuantityLabel
@onready var rarity_strip: ColorRect = $RarityStrip
@onready var slot_type_label: Label = $SlotTypeLabel

## Icons for item types (fallback when no texture)
const TYPE_ICONS = {
	"rifle": "🔫",
	"pistol": "🔫",
	"smg": "🔫",
	"shotgun": "🔫",
	"melee": "⚔️",
	"armor": "🛡️",
	"helmet": "⛑️",
	"gadget": "⚙️",
	"consumable": "💊",
	"ammo": "📦",
	"misc": "📦"
}

## Rarity colors - used for rarity strip and name coloring
const RARITY_COLORS = {
	"common": Color(0.55, 0.55, 0.6),
	"uncommon": Color(0.3, 0.75, 0.35),
	"rare": Color(0.3, 0.55, 1.0),
	"epic": Color(0.7, 0.35, 0.9),
	"legendary": Color(1.0, 0.65, 0.15)
}

## Style colors
const EMPTY_SLOT_COLOR = Color(0.25, 0.25, 0.28)
const HOVER_COLOR = Color(1, 1, 1, 0.08)

## Double-click tracking
var _last_click_time: float = 0.0
const DOUBLE_CLICK_TIME: float = 0.3  # seconds

func _ready():
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	
	# Ensure drag and drop is enabled
	mouse_filter = MOUSE_FILTER_STOP
	
	# Show slot type label for equipment slots
	if slot_type != SlotType.INVENTORY and slot_type_label:
		slot_type_label.visible = true
		slot_type_label.text = slot_label if slot_label else _get_slot_label()
	
	# Show name label for equipment slots (wider slots)
	if slot_type != SlotType.INVENTORY and name_label:
		name_label.visible = true
	
	_update_display()

func set_item(data: Dictionary, inv_id: int = -1):
	item_data = data
	inventory_id = inv_id
	_update_display()

func clear_item():
	item_data = {}
	inventory_id = -1
	_update_display()

func has_item() -> bool:
	return not item_data.is_empty()

func _update_display():
	if not is_inside_tree():
		return
	
	if item_data.is_empty():
		# Empty slot appearance
		if icon_label:
			icon_label.text = ""
		if icon_rect:
			icon_rect.texture = null
		if name_label:
			name_label.text = slot_label if slot_label else _get_slot_label()
			name_label.modulate = Color(0.45, 0.45, 0.5)
		if quantity_label:
			quantity_label.text = ""
		if rarity_strip:
			rarity_strip.color = EMPTY_SLOT_COLOR
		if slot_type_label:
			slot_type_label.visible = slot_type != SlotType.INVENTORY
		
		modulate = Color(0.6, 0.6, 0.6, 0.7)
	else:
		# Filled slot appearance
		var subtype = item_data.get("subtype", "misc")
		var rarity = item_data.get("rarity", "common")
		var rarity_color = RARITY_COLORS.get(rarity, RARITY_COLORS["common"])
		
		# Icon - prefer texture, fallback to generated colored placeholder
		if icon_rect:
			var icon_path = item_data.get("icon", "")
			if icon_path and icon_path != "" and ResourceLoader.exists(icon_path):
				var loaded_texture = load(icon_path)
				if loaded_texture:
					icon_rect.texture = loaded_texture
					if icon_label:
						icon_label.text = ""
				else:
					# Failed to load, use placeholder
					icon_rect.texture = _generate_item_placeholder(subtype, rarity_color)
					if icon_label:
						icon_label.text = TYPE_ICONS.get(subtype, "📦")
			else:
				# No icon path or doesn't exist, generate colored placeholder texture
				icon_rect.texture = _generate_item_placeholder(subtype, rarity_color)
				if icon_label:
					icon_label.text = TYPE_ICONS.get(subtype, "📦")
		
		# Name
		if name_label:
			name_label.text = item_data.get("name", "Unknown")
			name_label.modulate = rarity_color
		
		# Quantity - show for all stackable items
		if quantity_label:
			var qty = item_data.get("quantity", 1)
			var is_stackable = item_data.get("stackable", false) or item_data.get("type", "") == "ammo"
			if is_stackable or qty > 1:
				quantity_label.text = "x%d" % qty
			else:
				quantity_label.text = ""
		
		# Rarity strip color
		if rarity_strip:
			rarity_strip.color = rarity_color
		
		# Hide slot type label when filled
		if slot_type_label:
			slot_type_label.visible = false
		
		modulate = Color.WHITE

## Cache for generated placeholder textures
static var _placeholder_cache: Dictionary = {}

func _generate_item_placeholder(subtype: String, rarity_color: Color) -> ImageTexture:
	## Generate a colored placeholder icon based on item type
	var cache_key = "%s_%s" % [subtype, rarity_color.to_html()]
	if _placeholder_cache.has(cache_key):
		return _placeholder_cache[cache_key]
	
	var img_size = 48
	var img = Image.create(img_size, img_size, false, Image.FORMAT_RGBA8)
	
	# Background color (darker version of rarity)
	var bg_color = rarity_color.darkened(0.6)
	bg_color.a = 0.9
	
	# Fill background
	img.fill(bg_color)
	
	# Draw border
	var border_color = rarity_color
	for x in range(img_size):
		img.set_pixel(x, 0, border_color)
		img.set_pixel(x, 1, border_color)
		img.set_pixel(x, img_size - 1, border_color)
		img.set_pixel(x, img_size - 2, border_color)
	for y in range(img_size):
		img.set_pixel(0, y, border_color)
		img.set_pixel(1, y, border_color)
		img.set_pixel(img_size - 1, y, border_color)
		img.set_pixel(img_size - 2, y, border_color)
	
	# Draw simple shape based on type
	var center = img_size / 2.0
	var shape_color = rarity_color.lightened(0.2)
	
	match subtype:
		"rifle", "smg":
			# Long rectangle for rifle
			for x in range(8, img_size - 8):
				for y in range(center - 4, center + 4):
					img.set_pixel(x, y, shape_color)
			# Stock
			for x in range(8, 16):
				for y in range(center - 8, center + 8):
					img.set_pixel(x, y, shape_color)
		"pistol":
			# Small rectangle for pistol
			for x in range(12, img_size - 12):
				for y in range(center - 6, center + 2):
					img.set_pixel(x, y, shape_color)
			# Grip
			for x in range(16, 24):
				for y in range(center + 2, center + 12):
					img.set_pixel(x, y, shape_color)
		"shotgun":
			# Wide rectangle
			for x in range(6, img_size - 6):
				for y in range(center - 5, center + 5):
					img.set_pixel(x, y, shape_color)
		"melee":
			# Diagonal line for blade
			for i in range(img_size - 16):
				var x = 8 + i
				var y = 8 + i
				for dx in range(-2, 3):
					for dy in range(-2, 3):
						if x + dx >= 0 and x + dx < img_size and y + dy >= 0 and y + dy < img_size:
							img.set_pixel(x + dx, y + dy, shape_color)
		"armor":
			# Vest shape
			for x in range(12, img_size - 12):
				for y in range(8, img_size - 8):
					img.set_pixel(x, y, shape_color)
		"helmet":
			# Dome shape
			for x in range(10, img_size - 10):
				for y in range(8, img_size - 14):
					img.set_pixel(x, y, shape_color)
		"gadget":
			# Circle-ish
			for x in range(12, img_size - 12):
				for y in range(12, img_size - 12):
					img.set_pixel(x, y, shape_color)
		_:
			# Default box
			for x in range(12, img_size - 12):
				for y in range(12, img_size - 12):
					img.set_pixel(x, y, shape_color)
	
	var texture = ImageTexture.create_from_image(img)
	_placeholder_cache[cache_key] = texture
	return texture

func _get_slot_label() -> String:
	match slot_type:
		SlotType.EQUIPMENT_WEAPON_1: return "WEAPON 1"
		SlotType.EQUIPMENT_WEAPON_2: return "WEAPON 2"
		SlotType.EQUIPMENT_WEAPON_3: return "WEAPON 3"
		SlotType.EQUIPMENT_HEAD: return "HEAD"
		SlotType.EQUIPMENT_ARMOR: return "ARMOR"
		SlotType.EQUIPMENT_GADGET: return "GADGET"
		SlotType.EQUIPMENT_CONSUMABLE: return "ITEM"
		_: return ""

func _on_mouse_entered():
	if highlight:
		highlight.color = HOVER_COLOR

func _on_mouse_exited():
	if highlight:
		highlight.color = Color(1, 1, 1, 0)

func _notification(what):
	# Reset highlight when drag ends without dropping
	if what == NOTIFICATION_DRAG_END:
		if highlight:
			highlight.color = Color(1, 1, 1, 0)

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var current_time = Time.get_ticks_msec() / 1000.0
			var time_since_last_click = current_time - _last_click_time
			
			if time_since_last_click < DOUBLE_CLICK_TIME and _last_click_time > 0:
				# Double click detected
				item_double_clicked.emit(self)
				_last_click_time = 0.0  # Reset to prevent triple-click
			else:
				# Single click
				item_clicked.emit(self)
				_last_click_time = current_time
		
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Right click - show context menu
			if has_item():
				item_right_clicked.emit(self, get_global_mouse_position())
				get_viewport().set_input_as_handled()

#region Drag and Drop
func _get_drag_data(_pos: Vector2):
	if item_data.is_empty():
		return null
	
	drag_started.emit(self)
	
	# Create drag preview with actual item texture/placeholder
	var preview = Control.new()
	preview.custom_minimum_size = Vector2(64, 64)
	
	var preview_rect = TextureRect.new()
	preview_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	preview_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.add_child(preview_rect)
	
	# Use the same logic as _update_display to get the texture
	var subtype = item_data.get("subtype", "misc")
	var rarity = item_data.get("rarity", "common")
	var rarity_color = RARITY_COLORS.get(rarity, RARITY_COLORS["common"])
	
	var icon_path = item_data.get("icon", "")
	if icon_path and icon_path != "" and ResourceLoader.exists(icon_path):
		var loaded_texture = load(icon_path)
		if loaded_texture:
			preview_rect.texture = loaded_texture
		else:
			preview_rect.texture = _generate_item_placeholder(subtype, rarity_color)
	else:
		preview_rect.texture = _generate_item_placeholder(subtype, rarity_color)
	
	# Add quantity label for stackable items
	var qty = item_data.get("quantity", 1)
	var is_stackable = item_data.get("stackable", false) or item_data.get("type", "") == "ammo"
	if is_stackable or qty > 1:
		var qty_label = Label.new()
		qty_label.text = "x%d" % qty
		qty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		qty_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		qty_label.offset_left = -30
		qty_label.offset_top = -20
		qty_label.add_theme_font_size_override("font_size", 12)
		qty_label.add_theme_color_override("font_color", Color.WHITE)
		qty_label.add_theme_color_override("font_outline_color", Color.BLACK)
		qty_label.add_theme_constant_override("outline_size", 3)
		preview.add_child(qty_label)
	
	preview.modulate = Color.WHITE
	
	set_drag_preview(preview)
	
	return {
		"source_slot": self,
		"item_data": item_data.duplicate(true),
		"inventory_id": inventory_id
	}

func _can_drop_data(_pos: Vector2, data) -> bool:
	if data == null or not data is Dictionary:
		return false
	if not data.has("source_slot"):
		return false
	
	var source_item = data.get("item_data", {})
	var can_accept = _can_accept_item(source_item)
	var can_stack = _can_stack_with(source_item)
	
	# Visual feedback - highlight if can accept or stack
	if highlight:
		if can_stack:
			highlight.color = Color(0.3, 0.5, 0.9, 0.4)  # Blue tint for stacking
		elif can_accept:
			highlight.color = Color(0.3, 0.7, 0.3, 0.3)  # Green tint for valid drop
		else:
			highlight.color = Color(0.7, 0.3, 0.3, 0.3)  # Red tint for invalid drop
	
	return can_accept or can_stack

func _can_stack_with(source_data: Dictionary) -> bool:
	## Check if source item can be stacked onto this slot's item
	if item_data.is_empty() or source_data.is_empty():
		return false
	
	# Must be same item type
	var my_item_id = item_data.get("item_id", item_data.get("id", ""))
	var source_item_id = source_data.get("item_id", source_data.get("id", ""))
	if my_item_id.is_empty() or my_item_id != source_item_id:
		return false
	
	# Must be stackable
	var is_stackable = item_data.get("stackable", false) or item_data.get("type", "") == "ammo"
	if not is_stackable:
		return false
	
	# Check max stack size
	var max_stack = item_data.get("max_stack", 999)
	var current_qty = item_data.get("quantity", 1)
	if current_qty >= max_stack:
		return false
	
	return true

func _can_accept_item(data: Dictionary) -> bool:
	if data.is_empty():
		return true  # Empty items can go anywhere

	var item_type = data.get("type", "")
	var item_subtype = data.get("subtype", "")

	match slot_type:
		SlotType.INVENTORY:
			return true
		SlotType.EQUIPMENT_WEAPON_1, SlotType.EQUIPMENT_WEAPON_2, SlotType.EQUIPMENT_WEAPON_3:
			# Any weapon can go in any weapon slot (no size restrictions)
			return item_type == "weapon"
		SlotType.EQUIPMENT_HEAD:
			return item_subtype == "helmet" or item_type == "helmet"
		SlotType.EQUIPMENT_ARMOR:
			return item_subtype == "armor" or item_type == "armor"
		SlotType.EQUIPMENT_GADGET:
			return item_subtype == "gadget" or item_type == "gadget"
		SlotType.EQUIPMENT_CONSUMABLE:
			return item_type == "consumable"

	return false

func _drop_data(_pos: Vector2, data):
	var source_slot = data.get("source_slot") as InventorySlot
	if source_slot:
		# Reset highlight after drop
		if highlight:
			highlight.color = Color(1, 1, 1, 0)
		
		# Check if we should stack instead of swap
		var source_data = data.get("item_data", {})
		if _can_stack_with(source_data):
			items_stacked.emit(source_slot, self)
		else:
			drag_ended.emit(source_slot, self)
#endregion
