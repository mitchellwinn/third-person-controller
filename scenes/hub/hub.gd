extends MultiplayerScene

## Hub - Social zone where players gather between missions
## Combat is disabled, nametags visible, NPCs handle themselves

func _ready():
	# Hub is a safe zone - configure permissions before spawning
	allow_combat = false
	allow_pvp = false
	# Allow movement abilities
	allow_jumping = true
	allow_dodging = true
	allow_sprinting = true
	
	super._ready()
	print("[Hub] Initialized with ", spawn_points.size(), " spawn points")
