-- Mod Studio: extras
--   * TBM tab: a line-by-line text editor for the .tbm file you're making
--   * History tab: every undo step, click one to jump straight to it
--   * Hide / isolate objects in the editor (they still export and play normally)
--   * Copy / paste properties (look, physics, thrust, trigger) between objects

local MSV2 = MSV2
local UI = MSV2.UI
local floor = math.floor

local ROW, GAP, PAD = 22, 2, 4

---------------------------------------------------------------------------
-- Hide / isolate. Hidden objects are made invisible in the editor only: the
-- cached values (what gets saved, exported and tested) are never changed.
---------------------------------------------------------------------------

function MSV2.isHidden(idx)
	local m = MSV2.meta[idx]
	if (not m) then return false end
	if (m.tri and MSV2.tris[m.tri]) then return MSV2.tris[m.tri].hidden == true end
	return m.hidden == true
end

---Pushes the right visibility for one object to the engine
function MSV2.syncHidden(idx)
	local o = MSV2.objs[idx]
	if (not o) then return end
	if (MSV2.isHidden(idx) and not MSV2.revealing) then
		pcall(set_mod_envobj, idx, "visible", MSV2.toEngine("visible", false))
		pcall(set_mod_envobj, idx, "color_a", 0)
	else
		pcall(set_mod_envobj, idx, "visible", MSV2.toEngine("visible", o.visible ~= false))
		pcall(set_mod_envobj, idx, "color_a", o.color_a or 1)
	end
end

function MSV2.syncAllHidden()
	for idx in pairs(MSV2.objs) do MSV2.syncHidden(idx) end
	MSV2.needRefresh = true
end

function MSV2.anyHidden()
	for idx in pairs(MSV2.objs) do
		if (MSV2.isHidden(idx)) then return true end
	end
	return false
end

---Shows everything for real (export, test, close), then `fn`, then hides again
function MSV2.withHiddenRevealed(fn, ...)
	if (not MSV2.anyHidden()) then return fn(...) end
	MSV2.revealing = true
	MSV2.syncAllHidden()
	MSV2.flush()
	local results = { pcall(fn, ...) }
	MSV2.revealing = false
	MSV2.syncAllHidden()
	if (not results[1]) then error(results[2], 0) end
	return unpack(results, 2)
end

function MSV2.setNodesHidden(keys, hide, announce)
	local n = 0
	for _, key in ipairs(keys) do
		local d = MSV2.nodeData(key)
		if (d and (d.hidden == true) ~= (hide == true)) then
			d.hidden = hide or nil
			n = n + 1
			for _, idx in ipairs(MSV2.nodeObjs(key)) do
				MSV2.syncHidden(idx)
				if (hide) then MSV2.sel[idx] = nil end
			end
		end
	end
	if (hide and MSV2.primary and not MSV2.sel[MSV2.primary]) then MSV2.primary = MSV2.selList()[1] end
	MSV2.needRefresh = true
	MSV2.changedSinceAutosave = true
	if (announce and n > 0) then
		MSV2.toast((hide and "Hid " or "Showing ") .. n .. " item" .. (n == 1 and "" or "s") .. (hide and " in the editor - Ctrl+Shift+H shows everything" or ""))
	end
	UI.requestRefresh()
	return n
end

function MSV2.hideSelected()
	local set = MSV2.selKeys()
	if (next(set) == nil) then
		MSV2.toast("Select something to hide")
		return
	end
	local keys = {}
	for k in pairs(MSV2.withDescendants(set, MSV2.hier())) do table.insert(keys, k) end
	MSV2.setNodesHidden(keys, true, true)
end

function MSV2.showAll()
	local keys = {}
	for _, k in ipairs(MSV2.hier().keys) do table.insert(keys, k) end
	MSV2.isolated = false
	local n = MSV2.setNodesHidden(keys, false)
	MSV2.toast(n > 0 and ("Showing all " .. n .. " hidden item" .. (n == 1 and "" or "s")) or "Nothing is hidden")
end

---Hides everything except the selection (and its children). Run again to show all.
function MSV2.isolateSelected()
	if (MSV2.isolated) then
		MSV2.showAll()
		return
	end
	local set = MSV2.selKeys()
	if (next(set) == nil) then
		MSV2.toast("Select what you want to work on, then isolate it")
		return
	end
	local H = MSV2.hier()
	local keep = MSV2.withDescendants(set, H)
	local keys = {}
	for _, k in ipairs(H.keys) do
		if (not keep[k]) then table.insert(keys, k) end
	end
	MSV2.setNodesHidden(keys, true)
	MSV2.isolated = true
	MSV2.toast("Isolated the selection - Ctrl+I again (or Ctrl+Shift+H) shows everything")
end

-- Keep the editor-only hiding in place whenever the engine copy is rewritten
local origObjSet = MSV2.objSet
function MSV2.objSet(idx, f, v)
	origObjSet(idx, f, v)
	if ((f == "visible" or f == "color_a") and MSV2.isHidden(idx) and not MSV2.revealing) then
		MSV2.syncHidden(idx)
	end
end

local origTriBuild = MSV2.triBuild
function MSV2.triBuild(id)
	origTriBuild(id)
	local t = MSV2.tris[id]
	if (t and t.hidden) then
		for _, idx in ipairs(t.objs) do MSV2.syncHidden(idx) end
	end
end

local origRestore = MSV2.restore
function MSV2.restore(s)
	origRestore(s)
	MSV2.syncAllHidden()
end

local origReloadAll = MSV2.reloadAll
function MSV2.reloadAll()
	-- Read the real values back, not the "hidden" ones
	if (MSV2.objs and next(MSV2.objs) and MSV2.anyHidden()) then
		MSV2.revealing = true
		MSV2.syncAllHidden()
		MSV2.revealing = false
	end
	origReloadAll()
	MSV2.syncAllHidden()
end

local origExport = MSV2.exportMod
function MSV2.exportMod(name)
	return MSV2.withHiddenRevealed(origExport, name)
end

local origSelAll = MSV2.selAll
function MSV2.selAll()
	origSelAll()
	for idx in pairs(MSV2.sel) do
		if (MSV2.isHidden(idx)) then MSV2.sel[idx] = nil end
	end
	if (MSV2.primary and not MSV2.sel[MSV2.primary]) then MSV2.primary = MSV2.selList()[1] end
end

local origEnterTest = UI.enterTest
function UI.enterTest()
	if (MSV2.anyHidden()) then
		MSV2.revealing = true
		MSV2.syncAllHidden()
		MSV2.flush()
	end
	origEnterTest()
	if (not MSV2.testMode) then
		MSV2.revealing = false
		MSV2.syncAllHidden()
	end
end

local origExitTest = UI.exitTest
function UI.exitTest()
	origExitTest()
	if (MSV2.revealing) then
		MSV2.revealing = false
		MSV2.syncAllHidden()
	end
end

---Called by MSV2.shutdown so the mod maker never keeps editor-only hiding
function MSV2.revealAllHidden()
	MSV2.revealing = true
	MSV2.syncAllHidden()
	MSV2.flush()
	MSV2.revealing = false
end

---------------------------------------------------------------------------
-- Copy / paste properties
---------------------------------------------------------------------------

MSV2.PROP_GROUPS = {
	look = { "color_r", "color_g", "color_b", "color_a", "visible" },
	physics = { "static", "mass", "hardness", "friction", "bounce", "force_x", "force_y", "force_z" },
	thrust = { "thrust_frames", "thrust_x", "thrust_y", "thrust_z", "thrust_relative" },
	trigger = MSV2.TRIG_FIELDS
}

function MSV2.copyProps(group)
	local o = MSV2.primary and MSV2.objs[MSV2.primary]
	if (not o) then
		MSV2.toast("Click the object to copy from first")
		return
	end
	local groups = group == "all" and { "look", "physics", "thrust", "trigger" } or { group }
	local vals = {}
	local m = MSV2.meta[MSV2.primary]
	local tri = m and m.tri and MSV2.tris[m.tri]
	for _, g in ipairs(groups) do
		for _, f in ipairs(MSV2.PROP_GROUPS[g] or {}) do
			if (o[f] ~= nil) then vals[f] = o[f] end
		end
	end
	-- A triangle's slices each carry a share of its mass: copy the whole triangle's
	if (tri and vals.mass and tri.props and tri.props.mass) then vals.mass = tri.props.mass end
	local label = group == "all" and "all" or group
	MSV2.propClip = { label = label, vals = vals, from = MSV2.objName(MSV2.primary) }
	MSV2.toast("Copied " .. (label == "all" and "all properties" or label) .. " from " .. MSV2.propClip.from .. " - select objects and Paste")
	UI.requestRefresh()
end

function MSV2.pasteProps()
	local c = MSV2.propClip
	if (not c) then
		MSV2.toast("Copy properties first (Ctrl+Shift+C, or the Copy button on Look / Physics / Thrust / Trigger)")
		return
	end
	local list = MSV2.selList()
	if (#list == 0) then
		MSV2.toast("Select the objects to paste onto")
		return
	end
	MSV2.pushUndo("Paste " .. c.label)
	local done = {}
	for _, idx in ipairs(list) do
		local m = MSV2.meta[idx]
		local tri = m and m.tri and MSV2.tris[m.tri]
		for f, v in pairs(c.vals) do
			if (not tri or MSV2.TRI_PROPS[f]) then
				if (f == "mass" and tri) then
					MSV2.objSet(idx, f, v / math.max(1, #tri.objs))
				else
					MSV2.objSet(idx, f, v)
				end
			end
		end
		done[MSV2.nodeKey(idx) or idx] = true
	end
	local n = MSV2.count(done)
	MSV2.toast("Pasted " .. (c.label == "all" and "all properties" or c.label) .. " from " .. c.from .. " onto " .. n .. " item" .. (n == 1 and "" or "s"))
	UI.requestRefresh()
end

---------------------------------------------------------------------------
-- Undo history: jump to any step in one go
---------------------------------------------------------------------------

---Goes back to the state saved in undoStack[k] (before step k)
function MSV2.undoTo(k)
	local n = #MSV2.undoStack
	if (k < 1 or k > n) then return end
	local current = MSV2.snapshot()
	for j = n, k, -1 do
		local after = (j == n) and current or MSV2.undoStack[j + 1].snap
		table.insert(MSV2.redoStack, { label = MSV2.undoStack[j].label, snap = after })
	end
	local target = MSV2.undoStack[k].snap
	for _ = n, k, -1 do table.remove(MSV2.undoStack) end
	MSV2.restore(target)
	MSV2.lastUndoKey = nil
	MSV2.toast("Went back " .. (n - k + 1) .. " step" .. (n - k == 0 and "" or "s"))
end

---Redoes up to and including redoStack[m] (the top of the stack is the next redo)
function MSV2.redoTo(m)
	local n = #MSV2.redoStack
	if (m < 1 or m > n) then return end
	local current = MSV2.snapshot()
	for j = n, m, -1 do
		local before = (j == n) and current or MSV2.redoStack[j + 1].snap
		table.insert(MSV2.undoStack, { label = MSV2.redoStack[j].label, snap = before })
	end
	local target = MSV2.redoStack[m].snap
	for _ = n, m, -1 do table.remove(MSV2.redoStack) end
	MSV2.restore(target)
	MSV2.lastUndoKey = nil
	MSV2.toast("Redid " .. (n - m + 1) .. " step" .. (n - m == 0 and "" or "s"))
end

function UI.tabHistory(pane)
	ROW, GAP, PAD = UI.sizes()
	local w = pane.size.w - PAD * 2
	local y = PAD
	local nu, nr = #MSV2.undoStack, #MSV2.redoStack
	local buttonRow = function(items)
		local bw = (w - GAP * (#items - 1)) / #items
		for i, it in ipairs(items) do
			UI.button(pane, PAD + (i - 1) * (bw + GAP), y, bw, ROW, it[1], it[2], { disabled = it.disabled, tip = it.tip })
		end
		y = y + ROW + GAP
	end
	buttonRow({
		{ "Undo", MSV2.undo, disabled = nu == 0, tip = "Ctrl+Z" },
		{ "Redo", MSV2.redo, disabled = nr == 0, tip = "Ctrl+Y" },
		{ "Clear history", function()
			UI.confirm("Clear the undo history?", "Your mod stays as it is, but you won't be able to undo past this point.", {
				{ "Clear", function() MSV2.undoStack, MSV2.redoStack = {}, {}; UI.requestRefresh() end }, { "Cancel" }
			})
		end, disabled = nu + nr == 0 }
	})
	UI.hint(pane, PAD, y, w, ROW, "Click a step to jump straight to it. Greyed steps can be redone.", 0.42)
	y = y + ROW + GAP * 2
	if (nu + nr == 0) then
		UI.hint(pane, PAD, y, w, 60, "Nothing to undo yet.\nEvery change you make shows up here.", 0.5)
		return
	end
	local entries = {}
	local function row(text, fn, o)
		table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
			UI.button(holder, 0, ry, rw, ROW, text, fn, { align = LEFTMID, scale = 0.45, active = o.active, color = o.dim and UI.C.darkest or nil, tip = o.tip })
		end })
	end
	-- Oldest first: "Start", then each step; the current state is highlighted
	row("Start of history", function() MSV2.undoTo(1); UI.requestRefresh() end, { active = nu == 0, tip = "The state before the oldest step kept (" .. MSV2.MAX_UNDO .. " steps are kept)" })
	for i = 1, nu do
		local idx = i
		row(i .. ".  " .. MSV2.undoStack[i].label, function()
			if (idx < nu) then MSV2.undoTo(idx + 1) end
			UI.requestRefresh()
		end, { active = i == nu, tip = i == nu and "This is where you are now" or "Go back to right after this step" })
	end
	for j = nr, 1, -1 do
		local idx = j
		row((nu + nr - j + 1) .. ".  " .. MSV2.redoStack[j].label .. "   (undone)", function()
			MSV2.redoTo(idx)
			UI.requestRefresh()
		end, { dim = true, tip = "Redo up to this step" })
	end
	-- Start the list scrolled so the current step is in view
	if (UI.historySeen ~= nu + nr) then
		UI.historySeen = nu + nr
		UI.pages.history = math.max(1, nu - 6)
	end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "history")
end

---------------------------------------------------------------------------
-- TBM editor: open the mod file as text, edit any line, save it and load it
-- back into the mod maker.
---------------------------------------------------------------------------

UI.tbm = UI.tbm or { name = nil, lines = nil, dirty = false, filter = "" }
local T = UI.tbm

---io.open for a path inside the Toribash folder (data/mod/...). Tries the
---game-root form first, then the path relative to data/script.
local function openGameFile(path, mode)
	local ok, f = pcall(io.open, path, mode, 1)
	if (ok and f) then return f end
	local rel = "../" .. (path:gsub("^data/", ""))
	ok, f = pcall(io.open, rel, mode)
	if (ok and f) then return f end
	return nil
end

local function tbmPath(name)
	name = tostring(name or ""):gsub("\\", "/"):gsub("^data/mod/", "")
	if (not name:match("%.tbm$")) then name = name .. ".tbm" end
	return name, "data/mod/" .. name
end

function MSV2.tbmRead(name)
	local short, path = tbmPath(name)
	local f = openGameFile(path, "r")
	if (not f) then
		MSV2.toast("Couldn't open " .. path .. " - check the name (it's relative to data/mod)")
		return false
	end
	local s = f:read("*a") or ""
	f:close()
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	if (#lines > 1 and lines[#lines] == "") then table.remove(lines) end
	T.name, T.lines, T.dirty = short, lines, false
	UI.pages.tbm = 1
	MSV2.toast("Opened " .. path .. " (" .. #lines .. " lines)")
	return true
end

function MSV2.tbmWrite()
	if (not T.lines) then return false end
	local _, path = tbmPath(T.name)
	local f = openGameFile(path, "w")
	if (not f) then
		MSV2.toast("Couldn't write " .. path .. " - the game may not allow saving there")
		return false
	end
	f:write(table.concat(T.lines, "\n") .. "\n")
	f:close()
	T.dirty = false
	MSV2.toast("Saved " .. path)
	return true
end

---Exports what's in the mod maker right now and opens that file
function MSV2.tbmFromEditor()
	local written = MSV2.exportMod(MSV2.saveName or "Untitled")
	if (written) then MSV2.tbmRead(tostring(written)) end
end

---Saves the text and rebuilds the mod maker from it
function MSV2.tbmApply()
	if (not T.lines) then return end
	UI.confirm("Load this file into the mod maker?",
		"Saves the text, then rebuilds the mod from it. .tbm files don't store names, groups, parents or triangles, so those are dropped (Ctrl+Z brings them back).", {
		{ "Save & load", function()
			if (MSV2.tbmWrite()) then
				MSV2.importMod(T.name)
				UI.requestRefresh()
			end
		end },
		{ "Cancel" }
	})
end

local SECTIONS = { { "", "All" }, { "gamerule", "Rules" }, { "env_obj", "Objects" }, { "env_obj_joint", "Links" }, { "body", "Bodies" }, { "joint", "Joints" } }

function UI.tabTBM(pane)
	ROW, GAP, PAD = UI.sizes()
	local w = pane.size.w - PAD * 2
	local y = PAD
	T.name = T.name or ("modmaker/" .. (MSV2.saveName or "Untitled") .. ".tbm")

	UI.label(pane, PAD, y, 40, ROW, "File", LEFTMID, 0.47)
	UI.field(pane, PAD + 40, y, w - 40, ROW, T.name, { align = LEFTMID, placeholder = "modmaker/name.tbm (inside data/mod)" }, function(s)
		T.name = s
	end)
	y = y + ROW + GAP
	local items = {
		{ "From mod maker", MSV2.tbmFromEditor, tip = "Export what you've built and open that file here" },
		{ "Open file", function()
			local go = function() MSV2.tbmRead(T.name); UI.requestRefresh() end
			if (T.dirty) then
				UI.confirm("Discard your text changes?", "The file below has edits that aren't saved yet.", { { "Open anyway", go }, { "Cancel" } })
			else go() end
		end, tip = "Read the file named above" },
		{ "Save file", function() MSV2.tbmWrite(); UI.requestRefresh() end, disabled = not T.lines, tip = "Write the text back to the file" },
		{ "Save & load", MSV2.tbmApply, disabled = not T.lines, tip = "Save, then rebuild the mod maker from this file" }
	}
	local bw = (w - GAP * (#items - 1)) / #items
	for i, it in ipairs(items) do
		UI.button(pane, PAD + (i - 1) * (bw + GAP), y, bw, ROW, it[1], it[2], { disabled = it.disabled, tip = it.tip, scale = 0.45 })
	end
	y = y + ROW + GAP * 3

	if (not T.lines) then
		UI.hint(pane, PAD, y, w, 90, "Edit your mod's .tbm file as text, line by line.\n\nPress \"From mod maker\" to export what you've built and open it,\nor type a file name above and press \"Open file\".", 0.48)
		return
	end

	-- Section filter + search
	local sw = (w * 0.62 - GAP * (#SECTIONS - 1)) / #SECTIONS
	for i, sec in ipairs(SECTIONS) do
		UI.button(pane, PAD + (i - 1) * (sw + GAP), y, sw, ROW, sec[2], function()
			T.filter = sec[1]
			UI.pages.tbm = 1
			UI.requestRefresh()
		end, { active = T.filter == sec[1], scale = 0.4, tip = sec[1] ~= "" and ("Lines containing \"" .. sec[1] .. "\"") or "Every line" })
	end
	local fx = PAD + w * 0.62 + GAP
	UI.field(pane, fx, y, PAD + w - fx, ROW, T.filter, { align = LEFTMID, placeholder = "Find text, then Enter", enter = function() UI.blurFields() end }, function(s)
		T.filter = s
		UI.pages.tbm = 1
		UI.filterDirty = true
	end)
	y = y + ROW + GAP

	local f = (T.filter or ""):lower()
	local entries, shown = {}, 0
	for i, line in ipairs(T.lines) do
		if (f == "" or line:lower():find(f, 1, true)) then
			shown = shown + 1
			local li = i
			table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
				local isHeader = line:match("^%s*[%a_]+%s+%d+") and not line:match("^%s*#")
				local numEl = holder:addChild({ pos = { 0, ry }, size = { 34, ROW }, bgColor = isHeader and UI.C.light or UI.C.darkest, shapeType = ROUNDED, rounded = UI.r(3) })
				numEl:addAdaptedText(false, tostring(li), nil, nil, 4, CENTERMID, 0.38)
				UI.field(holder, 36, ry, rw - 36 - (ROW + GAP) * 2, ROW, T.lines[li], { align = LEFTMID }, function(s)
					T.lines[li] = s
					T.dirty = true
				end)
				UI.button(holder, rw - ROW * 2 - GAP, ry, ROW, ROW, "+", function()
					table.insert(T.lines, li + 1, "")
					T.dirty = true
					UI.requestRefresh()
				end, { tip = "Add an empty line below this one" })
				UI.button(holder, rw - ROW, ry, ROW, ROW, "x", function()
					table.remove(T.lines, li)
					if (#T.lines == 0) then T.lines = { "" } end
					T.dirty = true
					UI.requestRefresh()
				end, { tip = "Delete this line" })
			end })
		end
	end
	local status = #T.lines .. " lines" .. (f ~= "" and (" | " .. shown .. " match") or "") .. (T.dirty and " | unsaved changes" or " | saved")
	UI.hint(pane, PAD, y, w, ROW - 4, status, 0.4)
	y = y + ROW - 4 + GAP
	if (#entries == 0) then
		UI.hint(pane, PAD, y, w, 50, "No lines contain \"" .. T.filter .. "\".", 0.5)
		return
	end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "tbm")
end
