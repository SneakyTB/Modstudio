-- Mod Studio for Toribash
-- A friendlier, more powerful mod maker with a 3D move/rotate/scale gizmo,
-- triangles, parent/child hierarchy, undo/redo, multi-select, generators and project files.
--
-- Run it in game with:  /ls modstudio.lua      (close it with the X on the panel)
-- Files: data/script/modstudio.lua + data/script/modstudio/*.lua

require("toriui.uielement")
require("toriui.uielement3d")
require("system.iofiles")
require("system.menu_manager")

-- Already open: re-attach hooks (another script may have cleared them) and bring the UI back
if (MS and MS.active and MS.addHooks) then
	MS.addHooks()
	MS.UI.close()
	MS.UI.open()
	MS.toast("Mod Studio is already open")
	return
end

dofile("modstudio/core.lua")
dofile("modstudio/hierarchy.lua")
dofile("modstudio/tools.lua")
dofile("modstudio/viewport.lua")
dofile("modstudio/ui.lua")
dofile("modstudio/extras.lua")

local MS = MS

local function modMakerActive()
	local ok, active = pcall(is_mod_maker_mode_active)
	return ok and active
end

---Closes the stock Mod Maker window if it's open so the two don't fight over input
local function closeBuiltinModMaker()
	if (ModMaker == nil) then return end
	pcall(function()
		if (ModMaker.cancelDrag) then ModMaker.cancelDrag() end
		for _, key in ipairs({ "ViewportCapture", "EditButton", "MainElement" }) do
			if (ModMaker[key] ~= nil) then
				ModMaker[key]:kill()
				ModMaker[key] = nil
			end
		end
	end)
end

function MS.tick()
	MS.tickCamera()
	MS.tickZoom()
	if (not MS.testMode and not (MS.calib and not MS.calib.done)) then
		MS.tickRepair()
		MS.tickWorldMap()
	end
	MS.UI.tick()
	local now = MS.clock()
	MS.lastAutosave = MS.lastAutosave or now
	-- Wait for a pause in editing so the save never lands mid-scrub
	local idle = now - (MS.lastEditClock or 0) > 2
	local every = 60 * math.max(1, tonumber(MS.settings.autosaveMinutes) or 1)
	if (MS.settings.autosave and MS.changedSinceAutosave and now - MS.lastAutosave > every and idle and not MS.G.drag) then
		MS.lastAutosave = now
		MS.saveProject("_autosave", true)
	end
end

function MS.addHooks()
	local H = MS.HOOK
	add_hook("draw3d", H, function()
		if (not MS.active or MS.testMode) then return end
		MS.calibrateStep()
		MS.flush()
		local ok, err = pcall(MS.draw3d)
		if (not ok) then MS.reportError(err) end
		ok, err = pcall(MS.buildFrame)
		if (not ok) then MS.reportError(err) end
	end)
	add_hook("draw2d", H, function()
		if (not MS.active) then return end
		if (not MS.testMode) then
			local ok, err = pcall(MS.draw2d)
			if (not ok) then MS.reportError(err) end
		end
		MS.tick()
	end)
	add_hook("camera", H, function()
		if (MS.active) then return MS.onCamera() end
	end)
	add_hook("mouse_button_down", H, function(btn, x, y) return MS.onMouseDown(btn, x, y) end)
	add_hook("mouse_button_up", H, function(btn, x, y) return MS.onMouseUp(btn, x, y) end)
	add_hook("mouse_move", H, function(x, y) return MS.onMouseMove(x, y) end)
	add_hook("key_down", H, function(key) return MS.onKeyDown(key) end)
	add_hook("key_up", H, function(key) return MS.onKeyUp(key) end)
	add_hook("resolution_changed", H, function()
		if (MS.active) then
			MS.UI.close()
			MS.UI.open()
		end
	end)
	-- The game fires "unload" for internal world reloads too, so never close here - just back up the work
	add_hook("unload", H, function()
		if (MS.active and MS.changedSinceAutosave and MS.settings.autosave) then
			pcall(MS.saveProject, "_autosave", true)
		end
	end)
end

---Prints an error once per message so a bug never spams chat every frame
function MS.reportError(err)
	MS.reported = MS.reported or {}
	local s = tostring(err)
	if (not MS.reported[s]) then
		MS.reported[s] = true
		echo("Mod Studio error: " .. s)
	end
end

function MS.start()
	MS.loadSettings()
	closeBuiltinModMaker()
	if (not modMakerActive()) then
		pcall(enter_mod_maker_mode)
	end
	if (not modMakerActive()) then
		echo("Mod Studio: the mod maker isn't available right now (leave multiplayer / stop the replay and try again).")
		return
	end
	MS.active = true
	MS.testMode = false
	MS.undoStack, MS.redoStack = {}, {}
	MS.tris, MS.meta, MS.sel = {}, {}, {}
	MS.nextTri = 1
	MS.changed = false
	MS.changedSinceAutosave = false
	MS.lastAutosave = MS.clock()
	MS.reloadAll()
	MS.startCalibration()
	MS.saveName = MS.saveName or "Untitled"
	MS.addHooks()
	MS.UI.open()
	if (MS.settings.firstRun) then
		MS.UI.toggleHelp(true)
	end
	MS.toast("Mod Studio ready - press H any time for help")
end

---Asks before closing if there's unsaved work
function MS.close(force)
	if (not force and MS.changed) then
		MS.UI.confirm("Close Mod Studio?", "You have changes that aren't exported yet. Leaving the mod maker discards them (an autosave is kept).", {
			{ "Export & close", function()
				if (MS.exportMod(MS.saveName or "Untitled")) then MS.shutdown() end
			end },
			{ "Close anyway", function() MS.shutdown() end },
			{ "Cancel" }
		})
		return
	end
	MS.shutdown()
end

function MS.shutdown()
	-- Editor-only hiding must not stay behind in the mod maker
	if (MS.revealAllHidden) then pcall(MS.revealAllHidden) end
	if (MS.changedSinceAutosave and MS.settings.autosave) then
		pcall(MS.saveProject, "_autosave", true)
	end
	pcall(MS.saveSettings)
	MS.endDragSilently()
	MS.camAnim, MS.camRequest = nil, nil
	MS.restoreCameraMode()
	if (MS.testMode) then pcall(exit_mod_maker_test_mode) end
	MS.testMode = false
	MS.UI.close()
	remove_hooks(MS.HOOK)
	MS.active = false
	pcall(enable_mouse_camera_movement)
	if (modMakerActive()) then
		pcall(exit_mod_maker_mode)
	end
	echo("Mod Studio closed.")
end

MS.start()
