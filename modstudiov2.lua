-- Mod Studio for Toribash
-- A friendlier, more powerful mod maker with a 3D move/rotate/scale gizmo,
-- triangles, parent/child hierarchy, undo/redo, multi-select, generators and project files.
--
-- Run it in game with:  /ls modstudiov2.lua    (close it with the X on the panel)
-- Files: data/script/modstudiov2.lua + data/script/modstudiov2/*v2.lua

require("toriui.uielement")
require("toriui.uielement3d")
require("system.iofiles")
require("system.menu_manager")

-- Already open: re-attach hooks (another script may have cleared them) and bring the UI back
if (MSV2 and MSV2.active and MSV2.addHooks) then
	MSV2.addHooks()
	if (not MSV2.testMode) then MSV2.hideGameHud() end
	MSV2.UI.close()
	MSV2.UI.open()
	MSV2.toast("Mod Studio is already open")
	return
end

dofile("modstudiov2/corev2.lua")
dofile("modstudiov2/hierarchyv2.lua")
dofile("modstudiov2/toolsv2.lua")
dofile("modstudiov2/viewportv2.lua")
dofile("modstudiov2/layoutv2.lua")
dofile("modstudiov2/uiv2.lua")
dofile("modstudiov2/iconsv2.lua")
dofile("modstudiov2/extrasv2.lua")
dofile("modstudiov2/modelsv2.lua")

local MSV2 = MSV2

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

---Hides the game's HUD while editing; remembers the player's setting so it can be put back
function MSV2.hideGameHud()
	if (MSV2.savedHud == nil) then
		local ok, v = pcall(get_option, "hud")
		MSV2.savedHud = (ok and tonumber(v)) or 1
	end
	pcall(set_option, "hud", 0)
end

---Shows the game's HUD (used for test mode)
function MSV2.showGameHud()
	pcall(set_option, "hud", 1)
end

---Puts the HUD back to whatever the player had before Mod Studio opened
function MSV2.restoreGameHud()
	if (MSV2.savedHud == nil) then return end
	pcall(set_option, "hud", MSV2.savedHud)
	MSV2.savedHud = nil
end

function MSV2.tick()
	MSV2.tickCamera()
	MSV2.tickZoom()
	if (not MSV2.testMode and not (MSV2.calib and not MSV2.calib.done)) then
		MSV2.tickRepair()
		if (MSV2.tickFace) then pcall(MSV2.tickFace) end
		MSV2.tickWorldMap()
	end
	MSV2.UI.tick()
	local now = MSV2.clock()
	MSV2.lastAutosave = MSV2.lastAutosave or now
	-- Wait for a pause in editing so the save never lands mid-scrub
	local idle = now - (MSV2.lastEditClock or 0) > 2
	local every = 60 * math.max(1, tonumber(MSV2.settings.autosaveMinutes) or 1)
	if (MSV2.settings.autosave and MSV2.changedSinceAutosave and now - MSV2.lastAutosave > every and idle and not MSV2.G.drag) then
		MSV2.lastAutosave = now
		MSV2.saveProject("_autosave", true)
	end
end

function MSV2.addHooks()
	local H = MSV2.HOOK
	add_hook("draw3d", H, function()
		if (not MSV2.active or MSV2.testMode) then return end
		MSV2.calibrateStep()
		MSV2.flush()
		local ok, err = pcall(MSV2.draw3d)
		if (not ok) then MSV2.reportError(err) end
		ok, err = pcall(MSV2.buildFrame)
		if (not ok) then MSV2.reportError(err) end
	end)
	-- Floor lines are drawn here: draw_line_3d isn't batched and needs to run after everything else
	add_hook("post_draw3d", H, function()
		if (not MSV2.active or MSV2.testMode) then return end
		local ok, err = pcall(MSV2.drawFloor3d)
		if (not ok) then MSV2.reportError(err) end
	end)
	add_hook("draw2d", H, function()
		if (not MSV2.active) then return end
		if (not MSV2.testMode) then
			local ok, err = pcall(MSV2.draw2d)
			if (not ok) then MSV2.reportError(err) end
		end
		MSV2.tick()
	end)
	add_hook("camera", H, function()
		if (MSV2.active) then return MSV2.onCamera() end
	end)
	add_hook("mouse_button_down", H, function(btn, x, y) return MSV2.onMouseDown(btn, x, y) end)
	add_hook("mouse_button_up", H, function(btn, x, y) return MSV2.onMouseUp(btn, x, y) end)
	add_hook("mouse_move", H, function(x, y) return MSV2.onMouseMove(x, y) end)
	add_hook("key_down", H, function(key) return MSV2.onKeyDown(key) end)
	add_hook("key_up", H, function(key) return MSV2.onKeyUp(key) end)
	add_hook("resolution_changed", H, function()
		if (MSV2.active) then
			MSV2.UI.close()
			MSV2.UI.open()
		end
	end)
	-- The game fires "unload" for internal world reloads too, so never close here - just back up the work
	add_hook("unload", H, function()
		if (MSV2.active and MSV2.changedSinceAutosave and MSV2.settings.autosave) then
			pcall(MSV2.saveProject, "_autosave", true)
		end
	end)
end

---Prints an error once per message so a bug never spams chat every frame
function MSV2.reportError(err)
	MSV2.reported = MSV2.reported or {}
	local s = tostring(err)
	if (not MSV2.reported[s]) then
		MSV2.reported[s] = true
		echo("Mod Studio error: " .. s)
	end
end

function MSV2.start()
	MSV2.loadSettings()
	closeBuiltinModMaker()
	if (not modMakerActive()) then
		pcall(enter_mod_maker_mode)
	end
	if (not modMakerActive()) then
		echo("Mod Studio: the mod maker isn't available right now (leave multiplayer / stop the replay and try again).")
		return
	end
	MSV2.active = true
	MSV2.testMode = false
	MSV2.undoStack, MSV2.redoStack = {}, {}
	MSV2.tris, MSV2.meta, MSV2.sel = {}, {}, {}
	MSV2.nextTri = 1
	MSV2.changed = false
	MSV2.changedSinceAutosave = false
	MSV2.lastAutosave = MSV2.clock()
	MSV2.reloadAll()
	MSV2.startCalibration()
	MSV2.saveName = MSV2.saveName or "Untitled"
	MSV2.addHooks()
	MSV2.hideGameHud()
	MSV2.UI.open()
	if (MSV2.settings.firstRun) then
		MSV2.UI.toggleHelp(true)
	end
	MSV2.toast("Mod Studio ready - press H any time for help")
end

---Asks before closing if there's unsaved work
function MSV2.close(force)
	if (not force and MSV2.changed) then
		MSV2.UI.confirm("Close Mod Studio?", "You have changes that aren't exported yet. Leaving the mod maker discards them (an autosave is kept).", {
			{ "Export & close", function()
				if (MSV2.exportMod(MSV2.saveName or "Untitled")) then MSV2.shutdown() end
			end },
			{ "Close anyway", function() MSV2.shutdown() end },
			{ "Cancel" }
		})
		return
	end
	MSV2.shutdown()
end

function MSV2.shutdown()
	-- Release the 3D models loaded for the preview
	if (MSV2.unloadModels) then pcall(MSV2.unloadModels) end
	-- Editor-only hiding must not stay behind in the mod maker
	if (MSV2.revealAllHidden) then pcall(MSV2.revealAllHidden) end
	if (MSV2.changedSinceAutosave and MSV2.settings.autosave) then
		pcall(MSV2.saveProject, "_autosave", true)
	end
	pcall(MSV2.saveSettings)
	MSV2.endDragSilently()
	MSV2.camAnim, MSV2.camRequest = nil, nil
	MSV2.restoreCameraMode()
	if (MSV2.testMode) then pcall(exit_mod_maker_test_mode) end
	MSV2.testMode = false
	MSV2.UI.close()
	remove_hooks(MSV2.HOOK)
	MSV2.restoreGameHud()
	MSV2.active = false
	pcall(enable_mouse_camera_movement)
	if (modMakerActive()) then
		pcall(exit_mod_maker_mode)
	end
	echo("Mod Studio closed.")
end

MSV2.start()
