extends Control
class_name BankPanel

## Bank Panel UI - Shows inventory and bank side-by-side
## Allows moving items between inventory and bank via double-click or drag

signal closed()

@onready var close_button: Button = $MainPanel/PanelMargin/VBox/Header/CloseButton
@onready var title_label: Label = $MainPanel/PanelMargin/VBox/Header/TitleLabel
@onready var inventory_grid: GridContainer = $MainPanel/PanelMargin/VBox/Content/InventorySection/InventoryScroll/InventoryGrid
@onready var bank_grid: GridContainer = $MainPanel/PanelMargin/VBox/Content/BankSection/BankScroll/BankGrid
@onready var inventory_label: Label = $MainPanel/PanelMargin/VBox/Content/InventorySection/InventoryHeader/InventoryLabel
@onready var bank_label: Label = $MainPanel/PanelMargin/VBox/Content/BankSection/BankHeader/BankLabel

const SLOT_SCENE_PATH = "res://scenes/ui/inventory/inventory_slot.tscn"

var _character_id: int = 0
var _bank_name: String = "Bank"
var _inventory_slots: Array[InventorySlot] = []
var _bank_slots: Array[InventorySlot] = []

const INVENTORY_SLOT_COUNT = 20
const BANK_SLOT_COUNT = 40

func _ready():
	add_to_group("ui_needs_mouse")
	set_process_unhandled_input(true)

	if close_button:
		close_button.pressed.connect(_on_close_pressed)

	_create_slots()
	visible = false

func _unhandled_input(event: InputEvent):
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open_bank(character_id: int, bank_name: String = "Bank"):
	_character_id = character_id
	_bank_name = bank_name

	if title_label:
		title_label.text = bank_name

	_refresh_inventory()
	_refresh_bank()

	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func close():
	visible = false
	closed.emit()

func _on_close_pressed():
	close()

func _create_slots():
	var slot_scene = load(SLOT_SCENE_PATH)
	if not slot_scene:
		push_error("[BankPanel] Cannot load slot scene: ", SLOT_SCENE_PATH)
		return

	# Create inventory slots
	if inventory_grid:
		for i in range(INVENTORY_SLOT_COUNT):
			var slot = slot_scene.instantiate() as InventorySlot
			slot.slot_type = InventorySlot.SlotType.INVENTORY
			slot.slot_index = i
			slot.custom_minimum_size = Vector2(64, 64)
			inventory_grid.add_child(slot)
			_inventory_slots.append(slot)

			# Connect signals
			slot.slot_clicked.connect(_on_inventory_slot_clicked.bind(slot))
			slot.slot_double_clicked.connect(_on_inventory_slot_double_clicked.bind(slot))

	# Create bank slots
	if bank_grid:
		for i in range(BANK_SLOT_COUNT):
			var slot = slot_scene.instantiate() as InventorySlot
			slot.slot_type = InventorySlot.SlotType.INVENTORY  # Bank uses same slot type
			slot.slot_index = i
			slot.custom_minimum_size = Vector2(64, 64)
			bank_grid.add_child(slot)
			_bank_slots.append(slot)

			# Connect signals
			slot.slot_clicked.connect(_on_bank_slot_clicked.bind(slot))
			slot.slot_double_clicked.connect(_on_bank_slot_double_clicked.bind(slot))

func _refresh_inventory():
	# Clear all inventory slots first
	for slot in _inventory_slots:
		slot.clear_item()

	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		return

	var inventory = item_db.get_inventory(_character_id)

	# Fill slots with items
	var slot_index = 0
	for item in inventory:
		if slot_index >= _inventory_slots.size():
			break
		_inventory_slots[slot_index].set_item(item)
		slot_index += 1

	# Update label
	if inventory_label:
		inventory_label.text = "Inventory (%d/%d)" % [inventory.size(), INVENTORY_SLOT_COUNT]

func _refresh_bank():
	# Clear all bank slots first
	for slot in _bank_slots:
		slot.clear_item()

	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		return

	var bank_items = item_db.get_bank(_character_id)

	# Fill slots with items
	var slot_index = 0
	for item in bank_items:
		if slot_index >= _bank_slots.size():
			break
		_bank_slots[slot_index].set_item(item)
		slot_index += 1

	# Update label
	if bank_label:
		bank_label.text = "%s (%d/%d)" % [_bank_name, bank_items.size(), BANK_SLOT_COUNT]

func _on_inventory_slot_clicked(slot: InventorySlot):
	# Single click - could show item info
	pass

func _on_inventory_slot_double_clicked(slot: InventorySlot):
	# Double-click to deposit to bank
	if not slot.has_item():
		return

	var item_data = slot.item_data
	var inventory_id = item_data.get("inventory_id", 0)

	if inventory_id <= 0:
		return

	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		return

	# Move to bank
	var bank_id = item_db.bank_item(inventory_id)
	if bank_id > 0:
		print("[BankPanel] Deposited item to bank: ", item_data.get("name", "?"))
		_refresh_inventory()
		_refresh_bank()

func _on_bank_slot_clicked(slot: InventorySlot):
	# Single click - could show item info
	pass

func _on_bank_slot_double_clicked(slot: InventorySlot):
	# Double-click to withdraw from bank
	if not slot.has_item():
		return

	var item_data = slot.item_data
	var bank_id = item_data.get("bank_id", 0)

	if bank_id <= 0:
		return

	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		return

	# Move to inventory
	var inventory_id = item_db.unbank_item(bank_id)
	if inventory_id > 0:
		print("[BankPanel] Withdrew item from bank: ", item_data.get("name", "?"))
		_refresh_inventory()
		_refresh_bank()
