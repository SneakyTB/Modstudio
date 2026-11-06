# Mod Studio for Toribash

A friendlier, more powerful mod maker for Toribash: a docked panel layout with icons,
a 3D move/rotate/scale gizmo, triangles, parent/child hierarchy, undo/redo with a history
list, multi-select, generators, 3D model assets, a built-in .tbm text editor and project files.

**Version 1.0**

## What's in 1.0

- Models tab with a live 3D model preview and asset tools
- Held-object dragging (pick up an object with the mouse, scroll to push it nearer or further)
- Floor grid
- Player placement, with "Face the other way"
- F1-F4 tools (Select, Move, Rotate, Scale) and F9 Measure
- In-game help window (H)
- Built-in TBM text editor
- Library prefabs
- Undo/redo with history; the unsaved-changes warning clears when you undo back to the last export or load

## Install

Copy `modstudio.lua` and the `modstudio/` folder into your Toribash `data/script/` folder,
then run it in game:

```
/ls modstudio.lua
```

## Using it

- **F1 / F2 / F3 / F4**: Select, Move, Rotate, Scale tools. **F9**: Measure.
- **H**: help overlay with every shortcut.
- **Held dragging**: pick up an object with the mouse and scroll to push it nearer or further.
- **Floor grid**: toggle it from the View options.
- **Players**: place each player's start position, with "Face the other way" to turn them, and reset them again.
- **3D model assets**: the Models tab lists every .obj in data/mod_assets (rescanned live) and adds one with a click; models follow the live objects in Test mode; asset pack support in `models.lua`.
- Exported mods appear in your Mods list under "modmaker".

## Files

| File | What it does |
| --- | --- |
| `modstudio.lua` | Entry point: starts Mod Studio and hooks it into the game |
| `modstudio/core.lua` | Object cache, selection, undo, triangles, tools, rules, files |
| `modstudio/hierarchy.lua` | Parent / child hierarchy |
| `modstudio/tools.lua` | Stick, measure, prefabs, curves, moving obstacles, templates, presets, player placement |
| `modstudio/viewport.lua` | 3D gizmo, picking, dragging, camera, shortcuts |
| `modstudio/layout.lua` | Dock layout maths |
| `modstudio/ui.lua` | Panels, toolbar, status line, help, theme |
| `modstudio/icons.lua` | Icon set used throughout the UI |
| `modstudio/extras.lua` | TBM editor, undo history, hide/isolate, copy/paste properties |
| `modstudio/models.lua` | 3D model files and textures |

Projects (`.msp`) are saved to `data/script/modstudio/projects/`, prefabs (`.msf`) to
`data/script/modstudio/prefabs/` and settings to `data/script/modstudio/settings.cfg`.
Projects made with the older version open as-is (same file format).
