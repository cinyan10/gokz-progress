
# gokz-progress

A SourceMod plugin for GOKZ that shows real-time map progress and ranking for each player using replay tick data.

### 🚀 Features

* Real-time progress tracking based on `.replay` file positions
* Displays progress and rank as a percentage
* In-game panel or menu with live updates (`!progressmenu`)
* Supports bots if enabled via cvar
* Player preferences for toggling rank and progress display (`!rank`, `!progress`)

### 🔧 Cvars

```ini
gokz_progress_include_bots "0"   // Include bots in progress ranking (0 = no, 1 = yes)
```

### 💬 Commands

| Command         | Description                         |
| --------------- | ----------------------------------- |
| `!progressmenu` | Opens/closes the live progress menu |
| `!rank`         | Toggles rank display in HUD/TP menu |
| `!progress`     | Toggles progress display            |

### 📘 Requirements

* GOKz
* `.replay` file must be available for the current map (in `replays/` folder)

### 📌 Notes

* Progress is only shown if a valid `.replay` file is found. Plugin will not working for replay more than 30 min by default
* Rank and progress percentages are displayed using gokz-hud, so you need to install the modified gokz-hud.smx aswell
