-- Mod Studio: extras
--   * TBM tab: a line-by-line text editor for the .tbm file you're making
--   * History tab: every undo step, click one to jump straight to it
--   * Hide / isolate objects in the editor (they still export and play normally)
--   * Copy / paste properties (look, physics, thrust, trigger) between objects

local MS = MS
local UI = MS.UI
local floor = math.floor

local ROW, GAP, PAD = 22, 2, 4

---------------------------------------------------------------------------
-- Hide / isolate. Hidden objects are made invisible in the editor only: the
-- cached values (what gets saved, exported and tested) are never changed.
---------------------------------------------------------------------------

function MS.isHidden(idx)
	local m = MS.meta[idx]
	if (not m) then return false end
	if (m.tri and MS.tris[m.tri]) then return MS.tris[m.tri].hidden == true end
	return m.hidden == true
end

---Pushes the right visibility for one object to the engine
function MS.syncHidden(idx)
	local o = MS.objs[idx]
	if (not o) then return end
	if (MS.isHidden(idx) and not MS.revealing) then
		pcall(set_mod_envobj, idx, "visible", MS.toEngine("visible", false))
		pcall(set_mod_envobj, idx, "color_a", 0)
	elseif (MS.modelBoxHidden and MS.modelBoxHidden[idx] and not MS.revealing) then
		-- Object carries a previewed 3D model: only its plain box is hidden (editor only)
		pcall(set_mod_envobj, idx, "visible", MS.toEngine("visible", o.visible ~= false))
		pcall(set_mod_envobj, idx, "color_a", 0)
	else
		pcall(set_mod_envobj, idx, "visible", MS.toEngine("visible", o.visible ~= false))
		pcall(set_mod_envobj, idx, "color_a", o.color_a or 1)
	end
end

function MS.syncAllHidden()
	for idx in pairs(MS.objs) do MS.syncHidden(idx) end
	MS.needRefresh = true
end

function MS.anyHidden()
	for idx in pairs(MS.objs) do
		if (MS.isHidden(idx) or (MS.modelBoxHidden and MS.modelBoxHidden[idx])) then return true end
	end
	return false
end

---Shows everything for real (export, test, close), then `fn`, then hides again
function MS.withHiddenRevealed(fn, ...)
	if (not MS.anyHidden()) then return fn(...) end
	MS.revealing = true
	MS.syncAllHidden()
	MS.flush()
	local results = { pcall(fn, ...) }
	MS.revealing = false
	MS.syncAllHidden()
	if (not results[1]) then error(results[2], 0) end
	return unpack(results, 2)
end

function MS.setNodesHidden(keys, hide, announce)
	local n = 0
	for _, key in ipairs(keys) do
		local d = MS.nodeData(key)
		if (d and (d.hidden == true) ~= (hide == true)) then
			d.hidden = hide or nil
			n = n + 1
			for _, idx in ipairs(MS.nodeObjs(key)) do
				MS.syncHidden(idx)
				if (hide) then MS.sel[idx] = nil end
			end
		end
	end
	if (hide and MS.primary and not MS.sel[MS.primary]) then MS.primary = MS.selList()[1] end
	MS.needRefresh = true
	MS.changedSinceAutosave = true
	if (announce and n > 0) then
		MS.toast((hide and "Hid " or "Showing ") .. n .. " item" .. (n == 1 and "" or "s") .. (hide and " in the editor - Ctrl+Shift+H shows everything" or ""))
	end
	UI.requestRefresh()
	return n
end

function MS.hideSelected()
	local set = MS.selKeys()
	if (next(set) == nil) then
		MS.toast("Select something to hide")
		return
	end
	local keys = {}
	for k in pairs(MS.withDescendants(set, MS.hier())) do table.insert(keys, k) end
	MS.setNodesHidden(keys, true, true)
end

function MS.showAll()
	local keys = {}
	for _, k in ipairs(MS.hier().keys) do table.insert(keys, k) end
	MS.isolated = false
	local n = MS.setNodesHidden(keys, false)
	MS.toast(n > 0 and ("Showing all " .. n .. " hidden item" .. (n == 1 and "" or "s")) or "Nothing is hidden")
end

---Hides everything except the selection (and its children). Run again to show all.
function MS.isolateSelected()
	if (MS.isolated) then
		MS.showAll()
		return
	end
	local set = MS.selKeys()
	if (next(set) == nil) then
		MS.toast("Select what you want to work on, then isolate it")
		return
	end
	local H = MS.hier()
	local keep = MS.withDescendants(set, H)
	local keys = {}
	for _, k in ipairs(H.keys) do
		if (not keep[k]) then table.insert(keys, k) end
	end
	MS.setNodesHidden(keys, true)
	MS.isolated = true
	MS.toast("Isolated the selection - Ctrl+I again (or Ctrl+Shift+H) shows everything")
end

-- Keep the editor-only hiding in place whenever the engine copy is rewritten
local origObjSet = MS.objSet
function MS.objSet(idx, f, v)
	origObjSet(idx, f, v)
	if ((f == "visible" or f == "color_a") and (MS.isHidden(idx) or (MS.modelBoxHidden and MS.modelBoxHidden[idx])) and not MS.revealing) then
		MS.syncHidden(idx)
	end
end

local origTriBuild = MS.triBuild
function MS.triBuild(id)
	origTriBuild(id)
	local t = MS.tris[id]
	if (t and t.hidden) then
		for _, idx in ipairs(t.objs) do MS.syncHidden(idx) end
	end
end

local origRestore = MS.restore
function MS.restore(s)
	origRestore(s)
	MS.syncAllHidden()
end

local origReloadAll = MS.reloadAll
function MS.reloadAll()
	-- Read the real values back, not the "hidden" ones
	if (MS.objs and next(MS.objs) and MS.anyHidden()) then
		MS.revealing = true
		MS.syncAllHidden()
		MS.revealing = false
	end
	origReloadAll()
	MS.syncAllHidden()
end

local origExport = MS.exportMod
function MS.exportMod(name)
	return MS.withHiddenRevealed(origExport, name)
end

local origSelAll = MS.selAll
function MS.selAll()
	origSelAll()
	for idx in pairs(MS.sel) do
		if (MS.isHidden(idx)) then MS.sel[idx] = nil end
	end
	if (MS.primary and not MS.sel[MS.primary]) then MS.primary = MS.selList()[1] end
end

local origEnterTest = UI.enterTest
function UI.enterTest()
	if (MS.anyHidden()) then
		MS.revealing = true
		MS.syncAllHidden()
		MS.flush()
	end
	origEnterTest()
	if (not MS.testMode) then
		MS.revealing = false
		MS.syncAllHidden()
	end
end

local origExitTest = UI.exitTest
function UI.exitTest()
	origExitTest()
	if (MS.revealing) then
		MS.revealing = false
		MS.syncAllHidden()
	end
end

---Called by MS.shutdown so the mod maker never keeps editor-only hiding
function MS.revealAllHidden()
	MS.revealing = true
	MS.syncAllHidden()
	MS.flush()
	MS.revealing = false
end

---------------------------------------------------------------------------
-- Copy / paste properties
---------------------------------------------------------------------------

MS.PROP_GROUPS = {
	look = { "color_r", "color_g", "color_b", "color_a", "visible" },
	physics = { "static", "mass", "hardness", "friction", "bounce", "force_x", "force_y", "force_z" },
	thrust = { "thrust_frames", "thrust_x", "thrust_y", "thrust_z", "thrust_relative" },
	trigger = MS.TRIG_FIELDS
}

function MS.copyProps(group)
	local o = MS.primary and MS.objs[MS.primary]
	if (not o) then
		MS.toast("Click the object to copy from first")
		return
	end
	local groups = group == "all" and { "look", "physics", "thrust", "trigger" } or { group }
	local vals = {}
	local m = MS.meta[MS.primary]
	local tri = m and m.tri and MS.tris[m.tri]
	for _, g in ipairs(groups) do
		for _, f in ipairs(MS.PROP_GROUPS[g] or {}) do
			if (o[f] ~= nil) then vals[f] = o[f] end
		end
	end
	-- A triangle's slices each carry a share of its mass: copy the whole triangle's
	if (tri and vals.mass and tri.props and tri.props.mass) then vals.mass = tri.props.mass end
	local label = group == "all" and "all" or group
	MS.propClip = { label = label, vals = vals, from = MS.objName(MS.primary) }
	MS.toast("Copied " .. (label == "all" and "all properties" or label) .. " from " .. MS.propClip.from .. " - select objects and Paste")
	UI.requestRefresh()
end

function MS.pasteProps()
	local c = MS.propClip
	if (not c) then
		MS.toast("Copy properties first (Ctrl+Shift+C, or the Copy button on Look / Physics / Thrust / Trigger)")
		return
	end
	local list = MS.selList()
	if (#list == 0) then
		MS.toast("Select the objects to paste onto")
		return
	end
	MS.pushUndo("Paste " .. c.label)
	local done = {}
	for _, idx in ipairs(list) do
		local m = MS.meta[idx]
		local tri = m and m.tri and MS.tris[m.tri]
		for f, v in pairs(c.vals) do
			if (not tri or MS.TRI_PROPS[f]) then
				if (f == "mass" and tri) then
					MS.objSet(idx, f, v / math.max(1, #tri.objs))
				else
					MS.objSet(idx, f, v)
				end
			end
		end
		done[MS.nodeKey(idx) or idx] = true
	end
	local n = MS.count(done)
	MS.toast("Pasted " .. (c.label == "all" and "all properties" or c.label) .. " from " .. c.from .. " onto " .. n .. " item" .. (n == 1 and "" or "s"))
	UI.requestRefresh()
end

---------------------------------------------------------------------------
-- Undo history: jump to any step in one go
---------------------------------------------------------------------------

---Goes back to the state saved in undoStack[k] (before step k)
function MS.undoTo(k)
	local n = #MS.undoStack
	if (k < 1 or k > n) then return end
	local current = MS.snapshot()
	for j = n, k, -1 do
		local after = (j == n) and current or MS.undoStack[j + 1].snap
		table.insert(MS.redoStack, { label = MS.undoStack[j].label, snap = after })
	end
	local target = MS.undoStack[k].snap
	for _ = n, k, -1 do table.remove(MS.undoStack) end
	MS.restore(target)
	MS.lastUndoKey = nil
	MS.syncDirty()
	MS.toast("Went back " .. (n - k + 1) .. " step" .. (n - k == 0 and "" or "s"))
end

---Redoes up to and including redoStack[m] (the top of the stack is the next redo)
function MS.redoTo(m)
	local n = #MS.redoStack
	if (m < 1 or m > n) then return end
	local current = MS.snapshot()
	for j = n, m, -1 do
		local before = (j == n) and current or MS.redoStack[j + 1].snap
		table.insert(MS.undoStack, { label = MS.redoStack[j].label, snap = before })
	end
	local target = MS.redoStack[m].snap
	for _ = n, m, -1 do table.remove(MS.redoStack) end
	MS.restore(target)
	MS.lastUndoKey = nil
	MS.syncDirty()
	MS.toast("Redid " .. (n - m + 1) .. " step" .. (n - m == 0 and "" or "s"))
end

function UI.tabHistory(pane)
	ROW, GAP, PAD = UI.sizes()
	local w = pane.size.w - PAD * 2
	local y = PAD
	local nu, nr = #MS.undoStack, #MS.redoStack
	local buttonRow = function(items)
		local bw = (w - GAP * (#items - 1)) / #items
		local fit = UI.groupFrac(UI.rowFracs(bw, ROW, items))
		for i, it in ipairs(items) do
			UI.button(pane, PAD + (i - 1) * (bw + GAP), y, bw, ROW, it[1], it[2], { disabled = it.disabled, tip = it.tip, fit = fit })
		end
		y = y + ROW + GAP
	end
	buttonRow({
		{ "Undo", MS.undo, disabled = nu == 0, tip = "Ctrl+Z" },
		{ "Redo", MS.redo, disabled = nr == 0, tip = "Ctrl+Y" },
		{ "Clear history", function()
			UI.confirm("Clear the undo history?", "Your mod stays as it is, but you won't be able to undo past this point.", {
				{ "Clear", function() MS.undoStack, MS.redoStack = {}, {}; if (MS.changed) then MS.cleanValid = false else MS.markClean() end; UI.requestRefresh() end }, { "Cancel" }
			})
		end, disabled = nu + nr == 0 }
	})
	UI.hint(pane, PAD, y, w, ROW, "Click a step to jump straight to it. Greyed steps can be redone.", "small")
	y = y + ROW + GAP * 2
	if (nu + nr == 0) then
		UI.hint(pane, PAD, y, w, 60, "Nothing to undo yet.\nEvery change you make shows up here.", "body")
		return
	end
	local entries = {}
	local function row(text, fn, o)
		table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
			UI.button(holder, 0, ry, rw, ROW, text, fn, { align = LEFTMID, scale = "body", active = o.active, color = o.dim and UI.C.darkest or nil, tip = o.tip })
		end })
	end
	-- Oldest first: "Start", then each step; the current state is highlighted
	row("Start of history", function() MS.undoTo(1); UI.requestRefresh() end, { active = nu == 0, tip = "The state before the oldest step kept (" .. MS.MAX_UNDO .. " steps are kept)" })
	for i = 1, nu do
		local idx = i
		row(i .. ".  " .. MS.undoStack[i].label, function()
			if (idx < nu) then MS.undoTo(idx + 1) end
			UI.requestRefresh()
		end, { active = i == nu, tip = i == nu and "This is where you are now" or "Go back to right after this step" })
	end
	for j = nr, 1, -1 do
		local idx = j
		row((nu + nr - j + 1) .. ".  " .. MS.redoStack[j].label .. "   (undone)", function()
			MS.redoTo(idx)
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

function MS.tbmRead(name)
	local short, path = tbmPath(name)
	local f = openGameFile(path, "r")
	if (not f) then
		MS.toast("Couldn't open " .. path .. " - check the name (it's relative to data/mod)")
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
	MS.toast("Opened " .. path .. " (" .. #lines .. " lines)")
	return true
end

function MS.tbmWrite()
	if (not T.lines) then return false end
	local _, path = tbmPath(T.name)
	local f = openGameFile(path, "w")
	if (not f) then
		MS.toast("Couldn't write " .. path .. " - the game may not allow saving there")
		return false
	end
	f:write(table.concat(T.lines, "\n") .. "\n")
	f:close()
	T.dirty = false
	MS.toast("Saved " .. path)
	return true
end

---Exports what's in the mod maker right now and opens that file
function MS.tbmFromEditor()
	local written = MS.exportMod(MS.saveName or "Untitled")
	if (written) then MS.tbmRead(tostring(written)) end
end

---Saves the text and rebuilds the mod maker from it
function MS.tbmApply()
	if (not T.lines) then return end
	UI.confirm("Load this file into the mod maker?",
		"Saves the text, then rebuilds the mod from it. .tbm files don't store names, groups, parents or triangles, so those are dropped (Ctrl+Z brings them back).", {
		{ "Save & load", function()
			if (MS.tbmWrite()) then
				MS.importMod(T.name)
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
	T.name = T.name or ("modmaker/" .. (MS.saveName or "Untitled") .. ".tbm")

	UI.label(pane, PAD, y, 40, ROW, "File", LEFTMID, "body")
	UI.field(pane, PAD + 40, y, w - 40, ROW, T.name, { align = LEFTMID, placeholder = "modmaker/name.tbm (inside data/mod)" }, function(s)
		T.name = s
	end)
	y = y + ROW + GAP
	local items = {
		{ "From mod maker", MS.tbmFromEditor, tip = "Export what you've built and open that file here" },
		{ "Open file", function()
			local go = function() MS.tbmRead(T.name); UI.requestRefresh() end
			if (T.dirty) then
				UI.confirm("Discard your text changes?", "The file below has edits that aren't saved yet.", { { "Open anyway", go }, { "Cancel" } })
			else go() end
		end, tip = "Read the file named above" },
		{ "Save file", function() MS.tbmWrite(); UI.requestRefresh() end, disabled = not T.lines, tip = "Write the text back to the file" },
		{ "Save & load", MS.tbmApply, disabled = not T.lines, tip = "Save, then rebuild the mod maker from this file" }
	}
	local bw = (w - GAP * (#items - 1)) / #items
	local fit = UI.groupFrac(UI.rowFracs(bw, ROW, items))
	for i, it in ipairs(items) do
		UI.button(pane, PAD + (i - 1) * (bw + GAP), y, bw, ROW, it[1], it[2], { disabled = it.disabled, tip = it.tip, scale = "body", fit = fit })
	end
	y = y + ROW + GAP * 3

	if (not T.lines) then
		UI.hint(pane, PAD, y, w, 90, "Edit your mod's .tbm file as text, line by line.\n\nPress \"From mod maker\" to export what you've built and open it,\nor type a file name above and press \"Open file\".", "body")
		return
	end

	-- Section filter + search
	local sw = (w * 0.62 - GAP * (#SECTIONS - 1)) / #SECTIONS
	for i, sec in ipairs(SECTIONS) do
		UI.button(pane, PAD + (i - 1) * (sw + GAP), y, sw, ROW, sec[2], function()
			T.filter = sec[1]
			UI.pages.tbm = 1
			UI.requestRefresh()
		end, { active = T.filter == sec[1], scale = "small", tip = sec[1] ~= "" and ("Lines containing \"" .. sec[1] .. "\"") or "Every line" })
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
				UI.addText(numEl, false, tostring(li), nil, nil, 4, CENTERMID, "small")
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
	UI.hint(pane, PAD, y, w, ROW - 4, status, "small")
	y = y + ROW - 4 + GAP
	if (#entries == 0) then
		UI.hint(pane, PAD, y, w, 50, "No lines contain \"" .. T.filter .. "\".", "body")
		return
	end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "tbm")
end
