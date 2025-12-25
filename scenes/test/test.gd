extends MultiplayerScene

## Test - Testing zone with all actions enabled
## Use this for testing combat, abilities, and all game mechanics

func _ready():
	# Test zone allows everything
	allow_combat = true
	allow_pvp = true
	allow_jumping = true
	allow_dodging = true
	allow_sprinting = true
	
	super._ready()
	print("[Test] Initialized with ", spawn_points.size(), " spawn points - ALL ACTIONS ENABLED")


