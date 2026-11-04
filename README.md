# Mod Studio for Toribash

A friendlier, more powerful mod maker for Toribash: a 3D move/rotate/scale gizmo,
triangles, parent/child hierarchy, undo/redo with a history list, multi-select,
generators, a built-in .tbm text editor and project files.

## Install

Copy `modstudio.lua` and the `modstudio/` folder into your Toribash `data/script/` folder,
then run it in game:

```
/ls modstudio.lua
```

Press **H** in Mod Studio for every shortcut.

## Files

| File | What it does |
| --- | --- |
| `modstudio.lua` | Entry point: starts Mod Studio and hooks it into the game |
| `modstudio/core.lua` | Object cache, selection, undo, triangles, tools, rules, files |
| `modstudio/hierarchy.lua` | Parent / child hierarchy |
| `modstudio/tools.lua` | Stick (surface snapping), measure, prefabs, curves, moving obstacles, templates, presets, player placement + dojo |
| `modstudio/viewport.lua` | 3D gizmo, picking, dragging, camera, shortcuts |
| `modstudio/ui.lua` | Panels, toolbar, status line, help, theme |
| `modstudio/extras.lua` | TBM editor, undo history, hide/isolate, copy/paste properties |

Projects are saved to `data/script/modstudio/projects/` and settings to
`data/script/modstudio/settings.cfg` (both created as you use it).
