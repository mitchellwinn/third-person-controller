extends MultiplayerScene

## Mirth - First planet zone
## A hostile extraction zone where players can beam down from the hub
## Combat enabled, enemies spawn, extraction mechanic

func _ready():
	# Mirth is a hostile zone - full combat enabled
	allow_combat = true
	allow_pvp = false  # PvP off for now, can enable later
	allow_jumping = true
	allow_dodging = true
	allow_sprinting = true

	super._ready()
	print("[Mirth] Planet zone initialized with ", spawn_points.size(), " spawn points")

	# TODO: Setup enemy spawners
	# TODO: Setup extraction points
	# TODO: Setup objective markers
