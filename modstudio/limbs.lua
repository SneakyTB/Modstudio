-- Mod Studio: adding, connecting, renaming and removing extra limbs (Toribash 5.78+)
--
-- The game has no Lua call that creates a body part or joint on a fighter. Its own
-- Mod Maker (Alt + M) does it in C++, and its .tbm export / import already round-trip
-- extra limbs ("env_obj 0", then "body name" / "joint name" with "connect parent child").
-- So every limb change here is: export what's in the mod maker to a scratch file, edit the
-- limb lines of each fighter, import the file back. Names, groups, triangles and models of
-- objects are kept (they're stored by object index, which the round trip doesn't change).
--
-- The text editing part (MS.Limbs.*) is pure Lua so tests/test_limbs.py can run it offline.

local MS = MS
local L = {}
MS.Limbs = L

L.TEMP = "modstudio_limbs_temp"

-- Names the .tbm format uses for the classic parts, by index
L.CLASSIC_BODIES = {
	[0] = "head", "breast", "chest", "stomach", "groin",
	"r_pecs", "r_biceps", "r_triceps", "l_pecs", "l_biceps", "l_triceps",
	"r_hand", "l_hand", "r_butt", "l_butt",
	"r_thigh", "l_thigh", "l_leg", "r_leg", "r_foot", "l_foot"
}
L.CLASSIC_JOINTS = {
	[0] = "neck", "chest", "lumbar", "abs",
	"r_pecs", "r_shoulder", "r_elbow", "l_pecs", "l_shoulder", "l_elbow",
	"r_wrist", "l_wrist", "r_glute", "l_glute",
	"r_hip", "l_hip", "r_knee", "l_knee", "r_ankle", "l_ankle"
}
-- The two bodies each classic joint holds when it isn't re-wired (from the engine's classic table)
L.CLASSIC_PAIRS = {
	[0] = { 1, 0 }, { 1, 2 }, { 2, 3 }, { 4, 3 },
	{ 5, 1 }, { 6, 5 }, { 7, 6 }, { 1, 8 }, { 8, 9 }, { 9, 10 },
	{ 11, 7 }, { 10, 12 }, { 13, 4 }, { 4, 14 },
	{ 15, 13 }, { 16, 14 }, { 18, 15 }, { 17, 16 }, { 19, 18 }, { 17, 20 }
}
L.ROOT_BODY = 4 -- groin: every body must stay joined to it

local function indexOf(list, name)
	for i = 0, #list do
		if (list[i] == name) then return i end
	end
	return nil
end
function L.classicBody(name) return indexOf(L.CLASSIC_BODIES, name) end
function L.classicJoint(name) return indexOf(L.CLASSIC_JOINTS, name) end

---Part names may use letters, digits, _ and -, up to 31 characters (the game's own rule)
function L.validName(name)
	return type(name) == "string" and #name >= 1 and #name <= 31 and not name:find("[^%w_%-]")
end

---------------------------------------------------------------------------
-- Parsing a .tbm into fighters and blocks
---------------------------------------------------------------------------

---Splits text into lines (drops \r) and remembers the line ending
local function splitLines(text)
	local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	if (#lines > 0 and lines[#lines] == "") then table.remove(lines) end
	return lines, eol
end

---Parses a .tbm: { head = {lines before the first fighter...}, items = { {player=n, blocks}, {raw lines}... } }
---Each fighter is a list of blocks: { kind = "body"|"joint"|"env0"|"raw", name, lines = { ... } }
function L.parse(text)
	local lines, eol = splitLines(text or "")
	local doc = { eol = eol, items = {} }
	local cur, block = nil, nil
	local function rawItem(line)
		local last = doc.items[#doc.items]
		if (not last or last.player) then
			last = { raw = {} }
			table.insert(doc.items, last)
		end
		table.insert(last.raw, line)
	end
	for _, line in ipairs(lines) do
		local pn = line:match("^player%s+(%d+)%s*$")
		if (pn) then
			cur = { player = tonumber(pn), header = line, blocks = {} }
			table.insert(doc.items, cur)
			block = nil
		elseif (cur and line:match("^%S") and not line:match("^#")) then
			-- Unindented line: the fighter's section is over
			cur, block = nil, nil
			rawItem(line)
		elseif (cur) then
			local kind, name = line:match("^%s+([%a_]+)%s+(%S+)%s*$")
			if (kind == "body" or kind == "joint") then
				block = { kind = kind, name = name, lines = { line } }
				table.insert(cur.blocks, block)
			elseif (kind == "env_obj") then
				block = { kind = "env0", lines = { line } }
				table.insert(cur.blocks, block)
			elseif (line:match("^%s*#") or line:match("^%s*$")) then
				-- Comments / blank lines stand on their own so they never move with a part
				block = nil
				table.insert(cur.blocks, { kind = "raw", lines = { line } })
			elseif (block) then
				table.insert(block.lines, line)
			else
				table.insert(cur.blocks, { kind = "raw", lines = { line } })
			end
		else
			rawItem(line)
		end
	end
	return doc
end

function L.build(doc)
	local out = {}
	for _, it in ipairs(doc.items) do
		if (it.player) then
			table.insert(out, it.header)
			for _, b in ipairs(it.blocks) do
				for _, line in ipairs(b.lines) do table.insert(out, line) end
			end
		else
			for _, line in ipairs(it.raw) do table.insert(out, line) end
		end
	end
	return table.concat(out, doc.eol) .. doc.eol
end

function L.fighters(doc)
	local t = {}
	for _, it in ipairs(doc.items) do
		if (it.player) then t[it.player] = it end
	end
	return t
end

---Fighter q's section, made (empty, after the other fighters) when the file has none.
---The game's export leaves out a fighter that is still classic, so a fresh mod has no "player" lines at all.
function L.fighter(doc, q)
	local f = L.fighters(doc)[q]
	if (f) then return f end
	f = { player = q, header = "player " .. q, blocks = {} }
	local at = #doc.items + 1
	for i, it in ipairs(doc.items) do
		if (it.player and it.player > q) then at = i; break end
	end
	table.insert(doc.items, at, f)
	return f
end

---The `connect` line of a block, if any: parent, child, line index
local function connectOf(b)
	for i = 2, #b.lines do
		local a, c = b.lines[i]:match("^%s+connect%s+(%S+)%s+(%S+)")
		if (a) then return a, c, i end
	end
	return nil
end
L.connectOf = connectOf

local function isExtra(kind, name)
	if (kind == "body") then return L.classicBody(name) == nil end
	return L.classicJoint(name) == nil
end

---Extra part names of a fighter in file order: bodies, joints
function L.extraNames(f)
	local bodies, joints, seen = {}, {}, {}
	for _, b in ipairs(f.blocks) do
		if ((b.kind == "body" or b.kind == "joint") and isExtra(b.kind, b.name) and not seen[b.kind .. ":" .. b.name]) then
			seen[b.kind .. ":" .. b.name] = true
			table.insert(b.kind == "body" and bodies or joints, b.name)
		end
	end
	return bodies, joints
end

---Every joint of a fighter with the bodies it joins, by name: { name = {parent, child} }
function L.connections(f)
	local t = {}
	for j = 0, #L.CLASSIC_JOINTS do
		local pr = L.CLASSIC_PAIRS[j]
		t[L.CLASSIC_JOINTS[j]] = { L.CLASSIC_BODIES[pr[1]], L.CLASSIC_BODIES[pr[2]] }
	end
	for _, b in ipairs(f.blocks) do
		if (b.kind == "joint") then
			local a, c = connectOf(b)
			if (a) then t[b.name] = { a, c } end
		end
	end
	return t
end

---Names of every body of a fighter (classic + extra)
function L.bodySet(f)
	local s = {}
	for i = 0, #L.CLASSIC_BODIES do s[L.CLASSIC_BODIES[i]] = true end
	local extra = L.extraNames(f)
	for _, n in ipairs(extra) do s[n] = true end
	return s
end

---Bodies that can't reach the groin through `conns` (ignoring `skipBodies`)
function L.cutOff(f, conns, skipBodies)
	skipBodies = skipBodies or {}
	local bodies = L.bodySet(f)
	local adj = {}
	for _, pair in pairs(conns) do
		local a, c = pair[1], pair[2]
		if (not skipBodies[a] and not skipBodies[c]) then
			adj[a] = adj[a] or {}; adj[c] = adj[c] or {}
			table.insert(adj[a], c); table.insert(adj[c], a)
		end
	end
	local root = L.CLASSIC_BODIES[L.ROOT_BODY]
	local seen, queue = { [root] = true }, { root }
	while (#queue > 0) do
		local n = table.remove(queue)
		for _, m in ipairs(adj[n] or {}) do
			if (not seen[m]) then seen[m] = true; table.insert(queue, m) end
		end
	end
	local lost = {}
	for n in pairs(bodies) do
		if (not seen[n] and not skipBodies[n]) then table.insert(lost, n) end
	end
	table.sort(lost)
	return lost
end

---------------------------------------------------------------------------
-- Editing one fighter
---------------------------------------------------------------------------

local IND1, IND2 = "   ", "      "

local function num(v)
	local s = string.format("%.4f", v or 0):gsub("0+$", ""):gsub("%.$", "")
	if (s == "-0") then s = "0" end
	return s
end
local function vec(v) return num(v[1]) .. " " .. num(v[2]) .. " " .. num(v[3]) end
L.num = num

---Where the extra limbs start (the first "env_obj 0" of the fighter), adding it if missing
local function extrasStart(f)
	for i, b in ipairs(f.blocks) do
		if (b.kind == "env0") then return i end
	end
	-- Drop trailing blank lines so the new section sits right under the classic parts
	while (#f.blocks > 0 and f.blocks[#f.blocks].kind == "raw" and f.blocks[#f.blocks].lines[1]:match("^%s*$")) do
		table.remove(f.blocks)
	end
	table.insert(f.blocks, { kind = "raw", lines = { IND1 .. "# extra limbs (Toribash 5.78+); env_obj 0 makes older versions skip them" } })
	table.insert(f.blocks, { kind = "env0", lines = { IND1 .. "env_obj 0" } })
	return #f.blocks
end

---Index after the last extra block of `kind` (or after `fallback`)
local function afterLast(f, kind, fallback)
	local at = fallback
	for i = fallback + 1, #f.blocks do
		local b = f.blocks[i]
		if (b.kind == kind and isExtra(kind, b.name)) then at = i end
	end
	return at + 1
end

function L.hasPart(f, kind, name)
	for _, b in ipairs(f.blocks) do
		if (b.kind == kind and b.name == name) then return true end
	end
	if (kind == "body") then return L.classicBody(name) ~= nil end
	return L.classicJoint(name) ~= nil
end

---Adds a body. spec = { name, pos = {x,y,z}, sides = {x,y,z}, density, shape }
function L.addBody(f, spec)
	local start = extrasStart(f)
	local b = { kind = "body", name = spec.name, lines = { IND1 .. "body " .. spec.name } }
	if (spec.shape and spec.shape ~= "box") then table.insert(b.lines, IND2 .. "shape " .. spec.shape) end
	table.insert(b.lines, IND2 .. "sides " .. vec(spec.sides or { 0.15, 0.15, 0.15 }))
	table.insert(b.lines, IND2 .. "pos " .. vec(spec.pos or { 0, 0, 0 }))
	table.insert(b.lines, IND2 .. "density " .. num(spec.density or 0.1))
	table.insert(f.blocks, afterLast(f, "body", start), b)
end

---Adds a joint. spec = { name, parent, child, pos, axis, radius, range = {hi, lo}, strength, velocity }
function L.addJoint(f, spec)
	local start = extrasStart(f)
	local at = afterLast(f, "body", start)
	at = math.max(at, afterLast(f, "joint", start))
	local r = spec.range or { 1, -1 }
	local b = { kind = "joint", name = spec.name, lines = {
		IND1 .. "joint " .. spec.name,
		IND2 .. "connect " .. spec.parent .. " " .. spec.child,
		IND2 .. "radius " .. num(spec.radius or 0.08),
		IND2 .. "pos " .. vec(spec.pos or { 0, 0, 0 }),
		IND2 .. "axis " .. vec(spec.axis or { 1, 0, 0 }),
		IND2 .. "range " .. num(r[1]) .. " " .. num(r[2]),
		IND2 .. "strength " .. num(spec.strength or 1),
		IND2 .. "velocity " .. num(spec.velocity or 10)
	} }
	table.insert(f.blocks, at, b)
end

---Re-wires a joint. parent = nil puts a classic joint back on its classic bodies.
function L.connect(f, jointName, parent, child)
	local done = false
	for i = #f.blocks, 1, -1 do
		local b = f.blocks[i]
		if (b.kind == "joint" and b.name == jointName) then
			local _, _, li = connectOf(b)
			if (li) then
				if (parent and not done) then
					b.lines[li] = IND2 .. "connect " .. parent .. " " .. child
					done = true
				else
					table.remove(b.lines, li)
					if (#b.lines == 1) then table.remove(f.blocks, i) end
				end
			end
		end
	end
	if (parent and not done) then
		-- A classic joint that wasn't re-wired yet: put the block just before the extra limbs
		local at = #f.blocks + 1
		for i, b in ipairs(f.blocks) do
			if (b.kind == "env0") then
				at = i
				local prev = f.blocks[i - 1]
				if (prev and prev.kind == "raw" and prev.lines[1]:match("^%s*#")) then at = i - 1 end
				break
			end
		end
		table.insert(f.blocks, at, { kind = "joint", name = jointName, lines = {
			IND1 .. "joint " .. jointName, IND2 .. "connect " .. parent .. " " .. child } })
	end
end

---Renames an extra part and every connect line that names it
function L.rename(f, kind, old, new)
	for _, b in ipairs(f.blocks) do
		if (b.kind == kind and b.name == old) then
			b.name = new
			b.lines[1] = b.lines[1]:gsub("^(%s+" .. kind .. "%s+)%S+", "%1" .. new:gsub("%%", "%%%%"))
		end
		if (kind == "body" and b.kind == "joint") then
			local a, c, li = connectOf(b)
			if (li and (a == old or c == old)) then
				b.lines[li] = IND2 .. "connect " .. (a == old and new or a) .. " " .. (c == old and new or c)
			end
		end
	end
end

---Removes an extra joint, or an extra body with the extra joints that hold it
---(classic joints re-wired to it get their classic bodies back). Returns the joints removed.
function L.remove(f, kind, name)
	local gone = {}
	for i = #f.blocks, 1, -1 do
		local b = f.blocks[i]
		if (b.kind == kind and b.name == name) then
			table.remove(f.blocks, i)
		elseif (kind == "body" and b.kind == "joint") then
			local a, c = connectOf(b)
			if (a == name or c == name) then
				if (isExtra("joint", b.name)) then
					table.remove(f.blocks, i)
					table.insert(gone, b.name)
				end
			end
		end
	end
	if (kind == "body") then
		-- Classic joints that held it go back to their classic bodies
		local conns = L.connections(f)
		for j = 0, #L.CLASSIC_JOINTS do
			local jn = L.CLASSIC_JOINTS[j]
			local pr = conns[jn]
			if (pr[1] == name or pr[2] == name) then L.connect(f, jn, nil) end
		end
	end
	return gone
end

---------------------------------------------------------------------------
-- Engine side: export -> edit -> import, with undo
---------------------------------------------------------------------------

---The game's export never overwrites: it adds (0), (1)... to the name. Removes our scratch files.
local function cleanTemp(also)
	if (type(delete_mod) ~= "function") then return end
	local names = { "modmaker/" .. L.TEMP .. ".tbm" }
	for i = 0, 9 do table.insert(names, "modmaker/" .. L.TEMP .. "(" .. i .. ").tbm") end
	if (also) then table.insert(names, also) end
	-- Only files that are there: the game logs an error for every missing one
	for _, n in ipairs(names) do
		if (not MS.fileExists or MS.fileExists("data/mod/" .. n)) then pcall(delete_mod, n) end
	end
end
L.cleanTemp = cleanTemp

local function exportText()
	if (type(export_mod_maker) ~= "function") then return nil, "this game version can't export the mod maker" end
	cleanTemp()
	MS.flush(true)
	local run = function() return export_mod_maker(L.TEMP) end
	local ok, written = pcall(MS.withHiddenRevealed or function(fn) return fn() end, run)
	if (not ok or not written) then return nil, "export failed" end
	local path = "data/mod/" .. tostring(written):gsub("\\", "/")
	local text = MS.readBytes(path)
	cleanTemp(tostring(written))
	if (not text) then return nil, "couldn't read " .. path end
	return text
end

---Loads .tbm text into the mod maker, keeping object names, groups, triangles and models
local function importText(text)
	local written = "modmaker/" .. L.TEMP .. ".tbm"
	if (not MS.writeBytes("data/mod/" .. written, text)) then return false, "couldn't write the scratch file" end
	local meta, tris, nextTri = MS.meta, MS.tris, MS.nextTri
	local ok, res = pcall(import_mod_into_maker, written)
	cleanTemp()
	if (not ok or not res) then return false, "the game couldn't load the edited mod" end
	L.loadedText = text
	MS.meta, MS.tris, MS.nextTri = meta, tris, nextTri
	MS.reloadAll()
	MS.markDirty()
	return true
end
L.importText = importText

function L.supported()
	return type(get_num_bodies) == "function" and type(get_joint_bodies) == "function"
		and type(export_mod_maker) == "function" and type(import_mod_into_maker) == "function"
end

---Which fighters a limb change goes to
function L.targets(p)
	if (MS.settings.limbsOnePlayer) then return { p } end
	local t = {}
	for q = 0, math.max(1, MS.numPlayers) - 1 do table.insert(t, q) end
	return t
end

---Runs edit(fighter, p) on the chosen fighters of an exported copy of the mod, then loads it.
---edit returns nil to skip that fighter, or an error message to stop. check(p) says if it worked.
function L.apply(label, p, edit, check)
	if (not L.supported()) then
		MS.toast("Adding limbs needs Toribash 5.78 or newer")
		return false
	end
	if (next(L.pending or {})) then L.commit() end
	local before, why = exportText()
	if (not before) then
		MS.toast("Couldn't change limbs: " .. tostring(why))
		return false
	end
	local doc = L.parse(before)
	local changed, skipped = 0, 0
	for _, q in ipairs(L.targets(p)) do
		local f = L.fighter(doc, q)
		if (f) then
			local res = edit(f, q)
			if (type(res) == "string") then
				MS.toast(res)
				return false
			elseif (res == false) then
				skipped = skipped + 1
			else
				changed = changed + 1
			end
		end
	end
	if (changed == 0) then
		MS.toast("Nothing to change" .. (skipped > 0 and " on any fighter" or ""))
		return false
	end
	local after = L.build(doc)
	local snap = MS.snapshot()
	local ok, err = importText(after)
	if (ok and check and not check()) then
		ok, err = false, "the game didn't accept it (see the debug console)"
	end
	if (not ok) then
		importText(before)
		MS.toast("Couldn't change limbs: " .. tostring(err))
		return false
	end
	if (#MS.undoStack < (MS.cleanDepth or 0)) then MS.cleanValid = false end
	table.insert(MS.undoStack, { label = label, snap = snap, limbBefore = before, limbAfter = after })
	if (#MS.undoStack > MS.MAX_UNDO) then
		table.remove(MS.undoStack, 1)
		MS.cleanDepth = (MS.cleanDepth or 0) - 1
	end
	MS.redoStack = {}
	MS.lastUndoKey = nil
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
	return true, changed, skipped
end

-- Resetting drops extra limbs, which a snapshot can't bring back: remember the file text too
local origReset = MS.resetTo
if (origReset) then
	function MS.resetTo(what, onDone)
		if (not L.supported()) then return origReset(what, onDone) end
		if (next(L.pending or {})) then L.commit() end
		local hadExtras = false
		for p = 0, (MS.numPlayers or 2) - 1 do
			if (MS.numBodies(p) > MS.NUM_BODIES or MS.numJoints(p) > MS.NUM_JOINTS) then hadExtras = true end
		end
		local before = hadExtras and exportText() or nil
		local n = #MS.undoStack
		return origReset(what, function(ok)
			local e = MS.undoStack[n + 1]
			if (ok and before and e and #MS.undoStack == n + 1) then
				e.limbBefore, e.limbAfter, e.fresh, e.resetWhat = before, exportText(), true, what
			end
			if (onDone) then onDone(ok) end
		end)
	end
end

-- Undo / redo of a limb change loads the file text from before / after it
local origUndo, origRedo = MS.undo, MS.redo
function MS.undo()
	local e = MS.undoStack[#MS.undoStack]
	if (not (e and e.limbBefore)) then return origUndo() end
	table.remove(MS.undoStack)
	importText(e.limbBefore)
	if (e.fresh and e.snap) then
		-- Object names, groups and triangles from before the reset
		MS.meta, MS.tris, MS.nextTri = MS.deepcopy(e.snap.meta or {}), MS.deepcopy(e.snap.tris or {}), e.snap.nextTri or MS.nextTri
		for idx in pairs(MS.meta) do if (not MS.objs[idx]) then MS.meta[idx] = nil end end
	end
	table.insert(MS.redoStack, e)
	MS.lastUndoKey = nil
	MS.syncDirty()
	MS.toast("Undo: " .. e.label)
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end
function MS.redo()
	local e = MS.redoStack[#MS.redoStack]
	if (not (e and e.limbAfter)) then return origRedo() end
	table.remove(MS.redoStack)
	if (e.fresh) then
		-- Redoing a reset: run it again (loading text on top can't take extra limbs away)
		local redo = MS.redoStack
		MS.resetTo(e.resetWhat or "all")
		MS.redoStack = redo
		return
	end
	importText(e.limbAfter)
	table.insert(MS.undoStack, e)
	MS.lastUndoKey = nil
	MS.syncDirty()
	MS.toast("Redo: " .. e.label)
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

-- Jumping through history over a limb change goes one step at a time
local origUndoTo, origRedoTo = MS.undoTo, MS.redoTo
if (origUndoTo) then
	function MS.undoTo(k)
		for i = k, #MS.undoStack do
			if (MS.undoStack[i].limbBefore) then
				for _ = #MS.undoStack, k, -1 do MS.undo() end
				return
			end
		end
		return origUndoTo(k)
	end
end
if (origRedoTo) then
	function MS.redoTo(m)
		for i = m, #MS.redoStack do
			if (MS.redoStack[i].limbAfter) then
				for _ = #MS.redoStack, m, -1 do MS.redo() end
				return
			end
		end
		return origRedoTo(m)
	end
end

-- Keep the scratch file out of the mod lists
local origListMods = MS.listMods
if (origListMods) then
	function MS.listMods()
		local out = {}
		for _, v in ipairs(origListMods()) do
			if (not v:find(L.TEMP, 1, true)) then table.insert(out, v) end
		end
		return out
	end
end

---------------------------------------------------------------------------
-- Names <-> indices for the current fighters
---------------------------------------------------------------------------

---The .tbm name of body / joint index i of fighter p
function L.fileName(kind, p, i)
	local classic = kind == "body" and L.CLASSIC_BODIES or L.CLASSIC_JOINTS
	if (classic[i]) then return classic[i] end
	local infoFn = kind == "body" and get_body_info or get_joint_info
	if (type(infoFn) == "function") then
		local ok, info = pcall(infoFn, p, i)
		if (ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "") then return info.name end
	end
	return nil
end

local function fv(o, prefix)
	return { o and o[prefix .. "_x"] or 0, o and o[prefix .. "_y"] or 0, o and o[prefix .. "_z"] or 0 }
end

---Free name like base1, base2... over every fighter of the file
local function freeName(doc, kind, base)
	local used = {}
	for _, f in pairs(L.fighters(doc)) do
		for _, b in ipairs(f.blocks) do
			if (b.kind == kind) then used[b.name] = true end
		end
	end
	local i = 1
	while (used[base .. i] or (kind == "body" and L.classicBody(base .. i)) or (kind == "joint" and L.classicJoint(base .. i))) do i = i + 1 end
	return base .. i
end
L.freeName = freeName

---Suggested names for a new body / joint
function L.suggestNames()
	local text = exportText()
	local doc = text and L.parse(text) or { items = {} }
	return freeName(doc, "body", "extra_body"), freeName(doc, "joint", "extra_joint")
end

local function countsOk(p, db, dj, before)
	return function()
		return MS.numBodies(p) == before.b + db and MS.numJoints(p) == before.j + dj
	end
end

---Adds a new body on body b of fighter p, held by a new joint
function L.addBodyOn(p, b, bodyName, jointName)
	local parent = L.fileName("body", p, b)
	if (not parent) then MS.toast("Couldn't find that body's name in the mod"); return false end
	if (not L.validName(bodyName) or not L.validName(jointName)) then
		MS.toast("Names use letters, digits, _ and -, up to 31 characters.")
		return false
	end
	-- Place it just outside the parent, away from the middle of the fighter
	local po = MS.bodies[p] and MS.bodies[p][b]
	local ppos, psides = fv(po, "pos"), fv(po, "sides")
	local c, n = { 0, 0, 0 }, 0
	for _, o in pairs(MS.bodies[p] or {}) do
		c[1], c[2], c[3] = c[1] + (o.pos_x or 0), c[2] + (o.pos_y or 0), c[3] + (o.pos_z or 0)
		n = n + 1
	end
	if (n > 0) then c = { c[1] / n, c[2] / n, c[3] / n } end
	local d = { ppos[1] - c[1], ppos[2] - c[2], ppos[3] - c[3] }
	local len = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
	if (len < 0.05) then d, len = { 0, 0, 1 }, 1 end
	d = { d[1] / len, d[2] / len, d[3] / len }
	local reach = math.max(psides[1], psides[2], psides[3], 0.1) / 2
	local size = 0.15
	local jpos = { ppos[1] + d[1] * reach, ppos[2] + d[2] * reach, ppos[3] + d[3] * reach }
	local bpos = { jpos[1] + d[1] * size / 2, jpos[2] + d[2] * size / 2, jpos[3] + d[3] * size / 2 }
	-- Hinge across the direction it sticks out
	local axis = math.abs(d[3]) > 0.7 and { 1, 0, 0 } or { 0, 0, 1 }
	local before = { b = MS.numBodies(p), j = MS.numJoints(p) }
	local ok, changed, skipped = L.apply("Add body " .. bodyName, p, function(f, q)
		if (not L.hasPart(f, "body", parent)) then return false end
		if (L.hasPart(f, "body", bodyName)) then return (q == p) and (bodyName .. " already exists") or false end
		if (L.hasPart(f, "joint", jointName)) then return (q == p) and (jointName .. " already exists") or false end
		-- Other fighters get the part at the same spot relative to their own copy of the parent
		local off = { 0, 0, 0 }
		local qo = MS.bodies[q] and MS.bodies[q][b]
		if (q ~= p and qo and po) then off = { (qo.pos_x or 0) - ppos[1], (qo.pos_y or 0) - ppos[2], (qo.pos_z or 0) - ppos[3] } end
		local function at(v) return { v[1] + off[1], v[2] + off[2], v[3] + off[3] } end
		L.addBody(f, { name = bodyName, pos = at(bpos), sides = { size, size, size }, density = 0.1 })
		L.addJoint(f, { name = jointName, parent = parent, child = bodyName, pos = at(jpos), axis = axis })
	end, countsOk(p, 1, 1, before))
	if (ok) then
		MS.toast("Added body " .. bodyName .. " on " .. MS.bodyName(p, b) .. ", held by joint " .. jointName
			.. ((skipped or 0) > 0 and (" (" .. changed .. " of " .. (changed + skipped) .. " fighters)") or ""))
		if (MS.UI and MS.UI.selectBody) then MS.UI.selectBody(p, MS.numBodies(p) - 1) end
	end
	return ok
end

---Adds a joint between two existing bodies (parent moves child)
function L.addJointBetween(p, b1, b2, jointName)
	if (b1 == b2) then MS.toast("A joint connects two different bodies: choose the parent and the child."); return false end
	local parent, child = L.fileName("body", p, b1), L.fileName("body", p, b2)
	if (not parent or not child) then MS.toast("Couldn't find those bodies' names in the mod"); return false end
	if (not L.validName(jointName)) then MS.toast("Names use letters, digits, _ and -, up to 31 characters."); return false end
	local o1, o2 = MS.bodies[p] and MS.bodies[p][b1], MS.bodies[p] and MS.bodies[p][b2]
	local a, c = fv(o1, "pos"), fv(o2, "pos")
	local mid = { (a[1] + c[1]) / 2, (a[2] + c[2]) / 2, (a[3] + c[3]) / 2 }
	local before = { b = MS.numBodies(p), j = MS.numJoints(p) }
	local ok, changed, skipped = L.apply("Add joint " .. jointName, p, function(f, q)
		if (not L.hasPart(f, "body", parent) or not L.hasPart(f, "body", child)) then return false end
		if (L.hasPart(f, "joint", jointName)) then return (q == p) and (jointName .. " already exists") or false end
		for jn, pr in pairs(L.connections(f)) do
			if ((pr[1] == parent and pr[2] == child) or (pr[1] == child and pr[2] == parent)) then
				return (q == p) and (jn .. " already connects " .. parent .. " and " .. child .. ".") or false
			end
		end
		local off = { 0, 0, 0 }
		local qo = MS.bodies[q] and MS.bodies[q][b1]
		if (q ~= p and qo and o1) then off = { (qo.pos_x or 0) - a[1], (qo.pos_y or 0) - a[2], (qo.pos_z or 0) - a[3] } end
		L.addJoint(f, { name = jointName, parent = parent, child = child,
			pos = { mid[1] + off[1], mid[2] + off[2], mid[3] + off[3] } })
	end, countsOk(p, 0, 1, before))
	if (ok) then
		MS.toast("Added joint " .. jointName .. ": " .. MS.bodyName(p, b1) .. " moves " .. MS.bodyName(p, b2)
			.. ((skipped or 0) > 0 and (" (" .. changed .. " of " .. (changed + skipped) .. " fighters)") or ""))
		if (MS.UI and MS.UI.selectJoint) then MS.UI.selectJoint(p, MS.numJoints(p) - 1) end
	end
	return ok
end

---Re-wires joint j so it connects b1 (parent) and b2 (child). b1 = nil: classic bodies again.
function L.reconnect(p, j, b1, b2)
	local jn = L.fileName("joint", p, j)
	if (not jn) then MS.toast("Couldn't find that joint's name in the mod"); return false end
	local parent = b1 and L.fileName("body", p, b1)
	local child = b2 and L.fileName("body", p, b2)
	if (b1 and (b1 == b2)) then MS.toast("A joint connects two different bodies."); return false end
	if (b1 and (not parent or not child)) then MS.toast("Couldn't find those bodies' names in the mod"); return false end
	if (not b1 and not L.classicJoint(jn)) then MS.toast("Only classic joints have classic bodies to go back to"); return false end
	local ok = L.apply(b1 and ("Connect " .. jn) or ("Reset " .. jn), p, function(f, q)
		if (not L.hasPart(f, "joint", jn)) then return false end
		if (parent and (not L.hasPart(f, "body", parent) or not L.hasPart(f, "body", child))) then return false end
		local conns = L.connections(f)
		if (parent) then
			for other, pr in pairs(conns) do
				if (other ~= jn and ((pr[1] == parent and pr[2] == child) or (pr[1] == child and pr[2] == parent))) then
					return (q == p) and (other .. " already connects " .. parent .. " and " .. child .. ".") or false
				end
			end
			conns[jn] = { parent, child }
		else
			local pr = L.CLASSIC_PAIRS[L.classicJoint(jn)]
			conns[jn] = { L.CLASSIC_BODIES[pr[1]], L.CLASSIC_BODIES[pr[2]] }
		end
		local lost = L.cutOff(f, conns)
		if (#lost > 0) then
			return (q == p) and ("That would cut " .. table.concat(lost, ", ") .. " off the fighter. Connect another joint to it first.") or false
		end
		L.connect(f, jn, parent, child)
	end)
	if (ok) then
		if (b1) then
			MS.toast(MS.jointName(p, j) .. " now connects " .. MS.bodyName(p, b1) .. " (parent) and " .. MS.bodyName(p, b2) .. " (child). Move the joint on the Joint section if needed.")
		else
			MS.toast(MS.jointName(p, j) .. " connects its classic bodies again.")
		end
	end
	return ok
end

---Renames extra body / joint i of fighter p on every chosen fighter
function L.renamePart(kind, p, i, new)
	local old = L.fileName(kind, p, i)
	if (not old) then MS.toast("Couldn't find that part's name in the mod"); return false end
	if (not isExtra(kind, old)) then MS.toast("Classic parts keep their names."); return false end
	if (not L.validName(new)) then MS.toast("Names use letters, digits, _ and -, up to 31 characters."); return false end
	if (new == old) then return false end
	if (not isExtra("body", new) or not isExtra("joint", new)) then MS.toast(new .. " is the name of a classic part."); return false end
	local ok = L.apply("Rename " .. old, p, function(f, q)
		if (not L.hasPart(f, kind, old)) then return false end
		if (L.hasPart(f, kind, new)) then return (q == p) and ("This fighter already has a part called " .. new .. ".") or false end
		L.rename(f, kind, old, new)
	end)
	if (ok) then MS.toast("Renamed " .. old .. " to " .. new) end
	return ok
end

---Removes extra body / joint i of fighter p (a body takes the joints that hold it along)
function L.removePart(kind, p, i)
	local name = L.fileName(kind, p, i)
	if (not name) then MS.toast("Couldn't find that part's name in the mod"); return false end
	if (not isExtra(kind, name)) then MS.toast("Classic parts can't be removed."); return false end
	local removedJoints = {}
	local ok = L.apply("Remove " .. name, p, function(f, q)
		if (not L.hasPart(f, kind, name)) then return false end
		-- Check nothing else would come loose
		local conns = L.connections(f)
		local skip = {}
		if (kind == "joint") then
			conns[name] = nil
		else
			skip[name] = true
			for jn, pr in pairs(conns) do
				if (pr[1] == name or pr[2] == name) then
					local cj = L.classicJoint(jn)
					if (cj) then
						local cp = L.CLASSIC_PAIRS[cj]
						conns[jn] = { L.CLASSIC_BODIES[cp[1]], L.CLASSIC_BODIES[cp[2]] }
					else
						conns[jn] = nil
					end
				end
			end
		end
		local lost = L.cutOff(f, conns, skip)
		if (#lost > 0) then
			return (q == p) and ("Removing " .. name .. " would cut " .. table.concat(lost, ", ") .. " off the fighter: no other joint holds it. Connect another joint to it first.") or false
		end
		local gone = L.remove(f, kind, name)
		if (q == p) then removedJoints = gone end
	end)
	if (ok) then
		MS.toast("Removed " .. kind .. " " .. name .. (#removedJoints > 0 and (", and with it " .. table.concat(removedJoints, ", ")) or ""))
		if (kind == "body") then MS.bodySel = { p = p, b = 0 } else MS.jointSel = { p = p, j = 0 } end
	end
	return ok
end

---------------------------------------------------------------------------
-- Editing extra parts. The game's get_mod_body / set_mod_body (and _joint) answer
-- "index out of range" for extra limbs, so their values come from the .tbm and edits
-- go back through it: queued while you work, written when you let go / stop typing.
---------------------------------------------------------------------------

-- .tbm line -> Mod Studio fields (in order), and defaults for a missing line
L.BODY_LINES = {
	{ "pos", { "pos_x", "pos_y", "pos_z" }, { 0, 0, 0 } },
	{ "rot", { "rot_x", "rot_y", "rot_z" }, { 0, 0, 0 } },
	{ "sides", { "sides_x", "sides_y", "sides_z" }, { 0.15, 0.15, 0.15 } },
	{ "density", { "density" }, { 0.1 } },
	{ "friction", { "friction" }, nil },
	{ "bounce", { "bounce" }, nil },
}
L.JOINT_LINES = {
	{ "pos", { "pos_x", "pos_y", "pos_z" }, { 0, 0, 0 } },
	{ "axis", { "axis_x", "axis_y", "axis_z" }, { 1, 0, 0 } },
	{ "radius", { "radius" }, { 0.08 } },
	{ "range", { "histop", "lostop" }, { 1, -1 } },
	{ "strength", { "maxforce" }, { 1 } },
	{ "velocity", { "maxvelocity" }, { 10 } },
}
local LINE_OF = { body = {}, joint = {} }
for _, d in ipairs(L.BODY_LINES) do for _, f in ipairs(d[2]) do LINE_OF.body[f] = d end end
for _, d in ipairs(L.JOINT_LINES) do for _, f in ipairs(d[2]) do LINE_OF.joint[f] = d end end
L.LINE_OF = LINE_OF

---Field table for a part's block: { pos_x = , ... } (defaults for lines it doesn't have)
function L.readFields(block, kind)
	local o = {}
	for _, d in ipairs(kind == "body" and L.BODY_LINES or L.JOINT_LINES) do
		local vals
		for i = 2, #block.lines do
			local key, rest = block.lines[i]:match("^%s+(%S+)%s+(.-)%s*$")
			if (key == d[1]) then
				vals = {}
				for n in rest:gmatch("[^%s,]+") do table.insert(vals, tonumber(n)) end
			end
		end
		vals = vals or d[3]
		if (vals) then
			for k, f in ipairs(d[2]) do o[f] = vals[k] end
		end
	end
	return o
end

---Writes the lines named in `keys` ({ pos = true, ... }) from field table `o` into the block
function L.writeFields(block, kind, o, keys)
	for _, d in ipairs(kind == "body" and L.BODY_LINES or L.JOINT_LINES) do
		local key = d[1]
		if (keys[key]) then
			local parts = {}
			for _, f in ipairs(d[2]) do table.insert(parts, num(o[f] or 0)) end
			local line = IND2 .. key .. " " .. table.concat(parts, " ")
			local done = false
			for i = 2, #block.lines do
				if (block.lines[i]:match("^%s+(%S+)") == key) then block.lines[i] = line; done = true end
			end
			if (not done) then table.insert(block.lines, line) end
		end
	end
end

---The last block of a part in a fighter (later lines win in the game too)
local function blockOf(f, kind, name)
	local found
	for _, b in ipairs(f.blocks) do
		if (b.kind == kind and b.name == name) then found = b end
	end
	return found
end
L.blockOf = blockOf

L.parts = L.parts or {}     -- ["p:kind:i"] = name, for extra parts filled from the file
L.pending = L.pending or {} -- ["p:kind:i"] = { p, kind, i, keys = { line keys } }

local function isFilePart(kind, p, i)
	return L.parts[p .. ":" .. kind .. ":" .. i] ~= nil
end
L.isFilePart = isFilePart

---Fills MS.bodies / MS.joints for the extra parts from the .tbm text
function L.syncFromText(text)
	L.parts = {}
	if (not text) then return end
	local fighters = L.fighters(L.parse(text))
	for p = 0, (MS.numPlayers or 2) - 1 do
		local f = fighters[p]
		for _, kind in ipairs({ "body", "joint" }) do
			local first = kind == "body" and MS.NUM_BODIES or MS.NUM_JOINTS
			local count = kind == "body" and MS.numBodies(p) or MS.numJoints(p)
			for i = first, count - 1 do
				local name = L.fileName(kind, p, i)
				local block = f and name and blockOf(f, kind, name)
				if (block) then
					local store = kind == "body" and MS.bodies or MS.joints
					store[p] = store[p] or {}
					store[p][i] = L.readFields(block, kind)
					L.parts[p .. ":" .. kind .. ":" .. i] = name
				end
			end
		end
	end
end

local function anyExtras()
	for p = 0, (MS.numPlayers or 2) - 1 do
		if (MS.numBodies(p) > MS.NUM_BODIES or MS.numJoints(p) > MS.NUM_JOINTS) then return true end
	end
	return false
end

-- After every re-read, fill in the extra parts (from the text just loaded, or a fresh export)
local origReload = MS.reloadAll
function MS.reloadAll(...)
	origReload(...)
	local text = L.loadedText
	L.loadedText = nil
	if (not L.supported() or not anyExtras()) then L.parts = {}; return end
	if (not text) then text = exportText() end
	L.syncFromText(text)
end

local function queue(kind, p, i, f)
	local d = LINE_OF[kind][f]
	if (not d) then return end
	local key = p .. ":" .. kind .. ":" .. i
	local q = L.pending[key] or { p = p, kind = kind, i = i, keys = {} }
	q.keys[d[1]] = true
	L.pending[key] = q
	L.lastQueue = MS.clock()
end

local origBodySet, origJointSet = MS.bodySet, MS.jointSet
function MS.bodySet(p, b, f, v)
	if (not isFilePart("body", p, b)) then return origBodySet(p, b, f, v) end
	local o = MS.bodies[p] and MS.bodies[p][b]
	if (not o) then return end
	o[f] = v
	queue("body", p, b, f)
	MS.changed, MS.changedSinceAutosave, MS.lastEditClock = true, true, MS.clock()
end
function MS.jointSet(p, j, f, v)
	if (not isFilePart("joint", p, j)) then return origJointSet(p, j, f, v) end
	local o = MS.joints[p] and MS.joints[p][j]
	if (not o) then return end
	o[f] = v
	queue("joint", p, j, f)
	MS.changed, MS.changedSinceAutosave, MS.lastEditClock = true, true, MS.clock()
end

---Writes every queued extra-part edit to the mod in one go
function L.commit()
	if (not next(L.pending)) then return end
	local pending = L.pending
	L.pending = {}
	local before = exportText()
	if (not before) then MS.toast("Couldn't save the extra part edits"); return end
	local doc = L.parse(before)
	local fighters = L.fighters(doc)
	local n = 0
	for _, q in pairs(pending) do
		local name = L.parts[q.p .. ":" .. q.kind .. ":" .. q.i]
		local store = q.kind == "body" and MS.bodies or MS.joints
		local o = store[q.p] and store[q.p][q.i]
		local f = fighters[q.p]
		local block = f and name and blockOf(f, q.kind, name)
		if (block and o) then
			L.writeFields(block, q.kind, o, q.keys)
			n = n + 1
		end
	end
	if (n == 0) then return end
	local sel, jsel = MS.bodySel, MS.jointSel
	local ok = importText(L.build(doc))
	if (not ok) then
		importText(before)
		MS.toast("The game didn't accept that change to the extra part")
	end
	MS.bodySel, MS.jointSel = sel, jsel
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

---Writes queued edits once you let go of the gizmo and stop typing for a moment
function L.tick()
	if (not next(L.pending)) then return end
	if (MS.G and MS.G.drag) then return end
	if (MS.clock() - (L.lastQueue or 0) < 0.6) then return end
	L.commit()
end

if (MS.UI and MS.UI.tick) then
	local origTick = MS.UI.tick
	MS.UI.tick = function(...)
		origTick(...)
		local ok, err = pcall(L.tick)
		if (not ok) then echo("Mod Studio limbs: " .. tostring(err)) end
	end
end

-- Saving and exporting write queued edits first
for _, fnName in ipairs({ "exportMod", "saveProject" }) do
	local orig = MS[fnName]
	if (orig) then
		MS[fnName] = function(...)
			if (next(L.pending)) then L.commit() end
			return orig(...)
		end
	end
end

---------------------------------------------------------------------------
-- UI: body picker dialog + entries for the Bodies and Joints tabs
---------------------------------------------------------------------------

local UI = MS.UI

---Shows every body of fighter p as buttons; onPick(b) runs on a click
function L.pickBody(title, p, onPick, disabled)
	if (not UI) then return end
	if (UI.dialog) then UI.dialog:kill() end
	UI.modalOpen = true
	local ROW, GAP = UI.sizes()
	local names, count = MS.bodyNameList(p), MS.numBodies(p)
	local cols = 3
	local rows = math.ceil(count / cols)
	local W = math.min(480, WIN_W - 40)
	local rowH = math.max(18, math.min(ROW - 2, math.floor((WIN_H - 140) / rows) - GAP))
	local H = 44 + rows * (rowH + GAP) + 44
	local shade = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { 0, 0 }, size = { WIN_W, WIN_H },
		bgColor = { 0, 0, 0, 0.45 }, interactive = true
	})
	UI.dialog = shade
	local box = shade:addChild({ pos = { math.floor((WIN_W - W) / 2), math.floor((WIN_H - H) / 2) }, size = { W, H },
		bgColor = UI.C.darkest, shapeType = ROUNDED, rounded = UI.r(8) })
	local inner = box:addChild({ shift = { 2, 2 }, bgColor = UI.C.bg }, true)
	UI.label(inner, 14, 8, W - 28, 28, title, LEFTMID, "title", UI.TITLE_FONT)
	local cw = (W - 28 - GAP * (cols - 1)) / cols
	for i = 0, count - 1 do
		local r, c = math.floor(i / cols), i % cols
		UI.button(inner, 14 + c * (cw + GAP), 40 + r * (rowH + GAP), cw, rowH, names[i], function()
			UI.closeDialog()
			onPick(i)
		end, { scale = "body", disabled = disabled and disabled[i] })
	end
	UI.button(inner, 14, H - 40, W - 28, 28, "Cancel", function() UI.closeDialog() end)
end

local function fighterNote()
	return MS.settings.limbsOnePlayer and "this fighter only" or "every fighter"
end

local function toggleEntry()
	return { kind = "toggle", label = "Change every fighter", tip = "On: new, re-wired, renamed and removed limbs go to every fighter. Off: only the one picked above",
		get = function() return not MS.settings.limbsOnePlayer end,
		set = function(v) MS.settings.limbsOnePlayer = not v; MS.saveSettings() end }
end

local function countHint(p)
	return { kind = "hint", label = "Extra bodies: " .. (MS.numBodies(p) - MS.NUM_BODIES) .. "   Extra joints: " .. (MS.numJoints(p) - MS.NUM_JOINTS)
		.. "   (changes go to " .. fighterNote() .. ")" }
end

local function unsupportedHint()
	return { kind = "hint", rows = 2, label = "Adding body parts and joints needs Toribash 5.78 or newer." }
end

---Flow: name the new body and joint, then add them on body b
function L.uiAddBodyOn(p, b)
	local bn, jn = L.suggestNames()
	UI.prompt("Name the new body (on " .. MS.bodyName(p, b) .. ")", bn, function(bodyName)
		UI.prompt("Name the joint that holds " .. bodyName, jn, function(jointName)
			L.addBodyOn(p, b, bodyName, jointName)
			UI.requestRefresh()
		end, "Add")
	end, "Next")
end

---Flow: pick parent, pick child, name the joint
function L.uiAddJoint(p, parentB)
	local function withParent(b1)
		L.pickBody("Child body (the one " .. MS.bodyName(p, b1) .. " moves)", p, function(b2)
			local _, jn = L.suggestNames()
			UI.prompt("Name the new joint", jn, function(name)
				L.addJointBetween(p, b1, b2, name)
				UI.requestRefresh()
			end, "Add")
		end, { [b1] = true })
	end
	if (parentB) then withParent(parentB) else L.pickBody("Parent body of the new joint", p, withParent) end
end

function L.uiReconnect(p, j)
	L.pickBody("New parent body of " .. MS.jointName(p, j), p, function(b1)
		L.pickBody("New child body of " .. MS.jointName(p, j), p, function(b2)
			L.reconnect(p, j, b1, b2)
			UI.requestRefresh()
		end, { [b1] = true })
	end)
end

local function confirmRemove(kind, p, i)
	local nm = kind == "body" and MS.bodyName(p, i) or MS.jointName(p, i)
	UI.confirm("Remove " .. nm .. "?", kind == "body"
		and "Removes this body and the extra joints that hold it from " .. fighterNote() .. ". Ctrl+Z brings it back."
		or "Removes this joint from " .. fighterNote() .. ". Ctrl+Z brings it back.", {
		{ "Remove", function() L.removePart(kind, p, i); UI.requestRefresh() end },
		{ "Cancel" }
	})
end

---Entries for the "Limbs" section of the Bodies tab
function L.bodyEntries(p, b)
	if (not L.supported()) then return { unsupportedHint() } end
	local extra = b >= MS.NUM_BODIES
	return {
		countHint(p),
		toggleEntry(),
		{ kind = "buttons", items = {
			{ "Add body on " .. MS.bodyName(p, b), function() L.uiAddBodyOn(p, b) end, tip = "Adds a small box next to this part, held to it by a new joint" },
			{ "Add joint from here", function() L.uiAddJoint(p, b) end, tip = "Adds a joint between this part (parent) and another body" }
		} },
		{ kind = "buttons", items = {
			{ "Rename", function()
				UI.prompt("Rename " .. MS.bodyName(p, b), L.fileName("body", p, b) or "", function(s) L.renamePart("body", p, b, s); UI.requestRefresh() end, "Rename")
			end, disabled = not extra, tip = extra and "Renames this body (and fixes the joints that name it)" or "Classic parts keep their names" },
			{ "Remove", function() confirmRemove("body", p, b) end, disabled = not extra, tip = extra and "Removes this body and the extra joints holding it" or "Classic parts can't be removed" }
		} }
	}
end

---Entries for the "Limbs" section of the Joints tab
function L.jointEntries(p, j)
	if (not L.supported()) then return { unsupportedHint() } end
	local extra = j >= MS.NUM_JOINTS
	local rewired = false
	if (not extra) then
		local a, c = MS.jointBodies(p, j)
		local pr = L.CLASSIC_PAIRS[j]
		rewired = a ~= nil and not ((a == pr[1] and c == pr[2]) or (a == pr[2] and c == pr[1]))
	end
	return {
		countHint(p),
		toggleEntry(),
		{ kind = "buttons", items = {
			{ "Add joint", function() L.uiAddJoint(p) end, tip = "Pick a parent and a child body, then a name" },
			{ "Add body + joint", function()
				L.pickBody("Add the new body on...", p, function(b) L.uiAddBodyOn(p, b) end)
			end, tip = "Adds a new body part and the joint that holds it" }
		} },
		{ kind = "buttons", items = {
			{ "Connect to...", function() L.uiReconnect(p, j) end, tip = "Change which two bodies this joint holds (parent, then child)" },
			{ "Classic bodies", function() L.reconnect(p, j, nil); UI.requestRefresh() end, disabled = not rewired,
				tip = extra and "Only classic joints have classic bodies" or "Put this joint back on its classic bodies" }
		} },
		{ kind = "buttons", items = {
			{ "Rename", function()
				UI.prompt("Rename " .. MS.jointName(p, j), L.fileName("joint", p, j) or "", function(s) L.renamePart("joint", p, j, s); UI.requestRefresh() end, "Rename")
			end, disabled = not extra, tip = extra and "Renames this joint" or "Classic parts keep their names" },
			{ "Remove", function() confirmRemove("joint", p, j) end, disabled = not extra, tip = extra and "Removes this joint" or "Classic parts can't be removed" }
		} }
	}
end
