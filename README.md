# Mod Studio for Toribash

A friendlier, more powerful mod maker for Toribash: a docked panel layout with icons,
a 3D move/rotate/scale gizmo, triangles, parent/child hierarchy, undo/redo with a history
list, multi-select, generators, 3D model assets, a built-in .tbm text editor and project files.

**Version 1.1.3**

1.1.3: add your own joints and body parts, and a round of fixes found in game. Joints tab > Add / connect joints and Bodies tab > Add / remove limbs add a body part with the joint that holds it, add a joint between two bodies, re-wire a joint to other bodies (or back to its classic ones), and rename or remove extra parts, on every fighter or just one; Mod Studio checks nothing would be left hanging and Ctrl+Z undoes it. Extra parts can be moved and edited like classic ones (the game's Lua calls refuse them, so their values go through the mod file). Reset everything now really gives you classic: the game's default rules and a stored copy of the classic fighter, even after edits have changed the game's own built-in fighter. Clicking selects only and the right panel follows it (an object opens Properties, a body part Bodies, a joint Joints); things move with the gizmo or typed values, and the gizmo is arrows only by default (the centre dot and plane squares are options under Settings > Gizmo). Moving a body part or joint no longer drags the rest of the fighter about, and moving Uke's head (the game turns Uke around his head) no longer swings his body. Button rows use icons on every button or on none, square corners work, dark text on a light accent, autosave defaults to every 5 minutes with an on/off button in the top bar, open panels are remembered between sessions, Gold is gone from the 3D view colours (same as Yellow), and the defaults are now Large size, Charcoal, White accent and 50% panels.

1.1.2: bug fixes and quality of life, tested in game. The Models tab no longer crashes the game when data/mod_assets has non-model files in it (textures, Steam cloud files). Switching a cylinder to a box keeps the right height. Number boxes too small for a value show it shortened (10.228 shows as 10) instead of only the last digits (.228), and show the exact value while you edit. Saved panel layouts can no longer end up under the toolbar. Rebuilding objects the game dropped no longer marks the mod as changed. Undo, redo and History jumps keep your selection. Duplicated and pasted objects get their own names (Ramp, Ramp 2, Ramp 3). "Show me" on the export warning selects what the warning is about.

1.1.1: code tidy-up. Removes the old surface-snapping code (object drags have held the object at a fixed camera distance for a while), a few functions nothing called and unused variables. No change to how Mod Studio works.

1.1.0: extra joints. For Toribash alpha 2 mods that add extra body parts and joints, the Bodies and Joints tabs list every part (extra ones use the mod's own names), you can pick them in 3D, and the Joints tab shows which two body parts a joint connects. Adding and re-wiring joints isn't in yet. Works as before on older game versions.

1.0.1: closing no longer warns after a test round-trip with no edits; the test bar sits lower so it no longer covers the Uke label.

## What's in 1.0

- Models tab with a live 3D model preview and asset tools
- Gizmo-only moving: clicking selects, the gizmo (or typed values) moves, turns and sizes
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
- **Gizmo moving**: clicking only selects. Move, turn and size things with the gizmo or by typing values; scroll while dragging the gizmo to push the selection nearer or further.
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
| `modstudio/limbs.lua` | Adding, connecting, renaming, removing and editing extra joints and body parts |
| `modstudio/classic_fighter.lua` | The classic fighter, used by the resets |

Projects (`.msp`) are saved to `data/script/modstudio/projects/`, prefabs (`.msf`) to
`data/script/modstudio/prefabs/` and settings to `data/script/modstudio/settings.cfg`.
Projects made with the older version open as-is (same file format).
