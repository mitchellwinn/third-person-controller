# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pioneer Online is a Godot 4.3 multiplayer extraction-style game with:
- Client-server architecture with Steam integration
- Squad-based missions (1-4 players)
- MMO-lite hub zones and instanced mission areas
- SQLite database persistence

## Running the Game

**Setup:** Create `godot.cfg` in project root with path to Godot 4.3 executable, or set `GODOT_PATH_ENV` environment variable.

**Launch scripts (Windows):**
- `run_local_test.bat` - Starts 1 server + 2 clients for local multiplayer testing (recommended for development)
- `run_server.bat` - Headless dedicated server on port 7777
- `run_client.bat` - Client connecting to localhost:7777

**Command-line arguments:**
```
--server              Start as dedicated server
--client              Start as client
--port 7777           Port to use
--ip 127.0.0.1        Server IP (client only)
--max-players 32      Max players (server only)
--headless            Auto-enables server mode
```

**Network config:** `config/network_config.gd` defines default port (7777) and server IPs.

## Architecture

### Plugin System

The game uses a modular plugin architecture via **gsg-godot-plugins** (git submodule in `addons/gsg-godot-plugins/`). Core systems are autoloaded singletons:

| Plugin | Purpose |
|--------|---------|
| NetworkManager | State sync, input buffering, client-side prediction |
| ZoneManager | Hub/instance zone management, squad transitions |
| DatabaseManager | SQLite persistence with Steam ID authentication |
| SteamManager | Lobbies, matchmaking, rich presence, avatars |
| ActionEntities | Server-authoritative 3D entity system with combat |
| ItemDatabase | Weapons, equipment, items |
| MusicManager | Multi-stem music with zone crossfading |
| SoundManager | 3D spatial audio |

### Key Directories

```
addons/
  gsg-godot-plugins/  # Core plugin framework (git submodule)
  godot-sqlite/       # SQLite driver
  godotsteam/         # Steam API integration
config/               # Network configuration
data/                 # JSON data files (missions, items, dialogue, shops)
prefabs/              # Reusable components (enemies, pickups, projectiles, weapons)
scenes/
  hub/                # Main social hub zone
  player/             # Player character
  ui/                 # UI systems (title menu, inventory, shop, HUD)
  test/               # Test scenes
scripts/
  main.gd             # Entry point - handles server/client/standalone modes
```

### Networking Flow

```
Client (ActionPlayer + UI)
    ↓ input
NetworkManager (state sync, prediction)
    ↓ RPC
Server (ZoneManager, ActionEntities)
    ↓ persistence
DatabaseManager (SQLite)
```

Mode detection: Headless runtime automatically becomes server. Title menu handles manual mode selection for standalone launches.

### Data Architecture

**Runtime state (in-memory):** Player stats like HP, shields, and stamina are simple variables in `CombatComponent` and `ActionEntity`. Updates happen every frame with no database overhead. Server broadcasts state to clients via RPC.

**Database persistence:** SQLite writes occur at boundaries, not per-frame:
- On mission end (`end_match()` saves match history and stats)
- On disconnect in safe zones (hub) - state preserved
- On disconnect in hostile zones - inventory drops/lost (extraction mechanic)
- Character data stored in `stats_json`, `equipment_json`, `inventory_json` columns

**Static game data (JSON):** Content definitions in `data/`:
- `missions/missions.json` - Mission objectives, conditions, rewards
- `items/items.json` - Weapon stats, equipment, consumables
- `dialogue/` - NPC dialogue trees
- `shops/` - Vendor inventories

## Code Conventions

- **GDScript** with `##` docstrings for documentation
- Autoloads accessed via `/root/PluginName` (e.g., `/root/NetworkManager`)
- Server authority for combat and state; clients predict then reconcile
- Use `is_multiplayer_authority()` to gate client-only code

## Input Actions

Key bindings defined in `project.godot`:
- E: Interact | R: Reload | Tab: Inventory
- 1-3: Weapon slots | H: Holster
- Shift: Sprint | Ctrl: Crouch | Space: Jump
