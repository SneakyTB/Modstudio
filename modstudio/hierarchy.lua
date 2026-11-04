-- Mod Studio: parent / child hierarchy
--
-- Any object or triangle can be the parent of any number of children. Moving,
-- rotating or scaling a parent carries its whole branch along (the "Children
-- follow parent" setting turns that off). Positions stay in world space, so
-- un-parenting never moves anything and exported .tbm files are unchanged:
-- the hierarchy is an editing aid, saved in Mod Studio project files.
--
-- A "node" is a plain object ("o<index>") or a whole triangle ("t<id>").
-- Each node can carry a stable `uid` (kept in MS.meta for objects, in the
-- triangle table for triangles) and a `parent` uid. Engine indices change
-- on undo / project load, uids don't, so nothing needs remapping.

local MS = MS
local V, M = MS.V, MS.M
local abs = math.abs

MS.nextUid = MS.nextUid or 1

---------------------------------------------------------------------------
-- Nodes
---------------------------------------------------------------------------

---Node key of the object at engine index `idx` (triangle slices map to their triangle)
function MS.nodeKey(idx)
	if (idx == nil) then return nil end
	local m = MS.meta[idx]
	if (m and m.tri and MS.tris[m.tri]) then return "t" .. m.tri end
	if (MS.objs[idx]) then return "o" .. idx end
	return nil
end

local function parseKey(key)
	return key:sub(1, 1), tonumber(key:sub(2))
end
MS.parseNodeKey = parseKey

---The table holding a node's uid / parent (meta for objects, the triangle itself)
function MS.nodeData(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MS.tris[n] end
	if (MS.objs[n]) then
		MS.meta[n] = MS.meta[n] or {}
		return MS.meta[n]
	end
	return nil
end

function MS.nodeExists(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MS.tris[n] ~= nil and #MS.tris[n].objs > 0 end
	return MS.objs[n] ~= nil
end

---Engine indices that make up a node
function MS.nodeObjs(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MS.tris[n] and MS.tris[n].objs or {} end
	return MS.objs[n] and { n } or {}
end

---One engine index that stands for the node (for selecting / sorting)
function MS.nodeRep(key)
	return MS.nodeObjs(key)[1]
end

function MS.nodeName(key)
	local kind, n = parseKey(key)
	if (kind == "t") then
		local t = MS.tris[n]
		return (t and t.name) or ("Triangle " .. n)
	end
	return MS.objName(n)
end

function MS.nodePos(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MS.triCentroid(n) end
	return MS.objPos(n)
end

---Position + orientation of a node. Triangles use a frame built from their corners
---so it stays stable under any rigid move.
function MS.nodeFrame(key)
	local kind, n = parseKey(key)
	if (kind == "t") then
		local t = MS.tris[n]
		local e1 = V.sub(t.b, t.a)
		local nrm = V.cross(e1, V.sub(t.c, t.a))
		local R = M.identity()
		if (V.len(e1) > 1e-6 and V.len(nrm) > 1e-9) then
			local u = V.norm(e1)
			local w = V.norm(nrm)
			R = M.fromCols(u, V.cross(w, u), w)
		end
		return { pos = MS.triCentroid(n), R = R }
	end
	return { pos = MS.objPos(n), R = MS.objRot(n) }
end

---Gives the node a uid if it has none yet and returns it
function MS.ensureUid(key)
	local d = MS.nodeData(key)
	if (not d) then return nil end
	if (not d.uid) then
		d.uid = MS.nextUid
		MS.nextUid = MS.nextUid + 1
	end
	return d.uid
end

function MS.newUid()
	local u = MS.nextUid
	MS.nextUid = MS.nextUid + 1
	return u
end

---------------------------------------------------------------------------
-- Hierarchy index (rebuilt on demand - it's cheap)
---------------------------------------------------------------------------

local function orderOf(key)
	return MS.nodeRep(key) or math.huge
end

local function sortKeys(list)
	table.sort(list, function(a, b) return orderOf(a) < orderOf(b) end)
	return list
end
MS.sortNodeKeys = sortKeys

---Builds { keys, byUid, parent = {child -> parent key}, children = {key -> list}, roots }
function MS.hier()
	local H = { keys = {}, byUid = {}, parent = {}, children = {}, roots = {} }
	for idx in pairs(MS.objs) do
		local m = MS.meta[idx]
		if (not (m and m.tri and MS.tris[m.tri])) then table.insert(H.keys, "o" .. idx) end
	end
	for id, t in pairs(MS.tris) do
		if (#t.objs > 0) then table.insert(H.keys, "t" .. id) end
	end
	sortKeys(H.keys)
	local data = {}
	for _, key in ipairs(H.keys) do
		local d = MS.nodeData(key)
		data[key] = d
		if (d and d.uid and not H.byUid[d.uid]) then H.byUid[d.uid] = key end
	end
	for _, key in ipairs(H.keys) do
		local d = data[key]
		local pk = d and d.parent and H.byUid[d.parent]
		if (pk and pk ~= key) then H.parent[key] = pk end
	end
	-- Never let a loop survive (only possible with a hand-edited project)
	for _, key in ipairs(H.keys) do
		local seen, p = { [key] = true }, H.parent[key]
		while (p) do
			if (seen[p]) then
				H.parent[key] = nil
				if (data[key]) then data[key].parent = nil end
				break
			end
			seen[p] = true
			p = H.parent[p]
		end
	end
	for _, key in ipairs(H.keys) do
		local pk = H.parent[key]
		if (pk) then
			H.children[pk] = H.children[pk] or {}
			table.insert(H.children[pk], key)
		else
			table.insert(H.roots, key)
		end
	end
	return H
end

---All descendants of `key` (depth first), appended to `out`
function MS.descendants(key, H, out)
	out = out or {}
	for _, c in ipairs(H.children[key] or {}) do
		table.insert(out, c)
		MS.descendants(c, H, out)
	end
	return out
end

function MS.depthOf(key, H)
	local d, p = 0, H.parent[key]
	while (p) do
		d = d + 1
		p = H.parent[p]
	end
	return d
end

---True if `a` sits somewhere below `b`
function MS.isBelow(a, b, H)
	local p = H.parent[a]
	while (p) do
		if (p == b) then return true end
		p = H.parent[p]
	end
	return false
end

---Removes references to parents that no longer exist, drops duplicate uids
---and moves the uid counter past everything in use. Call after bulk changes.
function MS.hierFix()
	local seen, maxUid = {}, 0
	local datas = {}
	for idx, m in pairs(MS.meta) do
		if (MS.objs[idx] and not (m.tri and MS.tris[m.tri])) then
			table.insert(datas, m)
		elseif (m.tri) then
			-- Slices belong to their triangle; they never carry their own links
			m.uid, m.parent = nil, nil
		end
	end
	for _, t in pairs(MS.tris) do table.insert(datas, t) end
	for _, d in ipairs(datas) do
		if (d.uid) then
			if (seen[d.uid]) then
				d.uid = nil
			else
				seen[d.uid] = true
				maxUid = math.max(maxUid, d.uid)
			end
		end
	end
	for _, d in ipairs(datas) do
		if (d.parent and (not seen[d.parent] or d.parent == d.uid)) then d.parent = nil end
	end
	MS.nextUid = math.max(MS.nextUid or 1, maxUid + 1)
end

---------------------------------------------------------------------------
-- Selection helpers
---------------------------------------------------------------------------

---Set of selected node keys + the list in scene order
function MS.selKeys()
	local set, list = {}, {}
	for _, idx in ipairs(MS.selList()) do
		local key = MS.nodeKey(idx)
		if (key and not set[key]) then
			set[key] = true
			table.insert(list, key)
		end
	end
	return set, sortKeys(list)
end

---The set plus every descendant of anything in it
function MS.withDescendants(set, H)
	local out = {}
	for key in pairs(set) do
		out[key] = true
		for _, d in ipairs(MS.descendants(key, H)) do out[d] = true end
	end
	return out
end

---Same shape as MS.selSplit(): set of triangle ids, sorted list of plain indices
function MS.splitKeys(set)
	local tris, plain = {}, {}
	for key in pairs(set) do
		local kind, n = parseKey(key)
		if (kind == "t") then
			if (MS.tris[n]) then tris[n] = true end
		elseif (MS.objs[n]) then
			table.insert(plain, n)
		end
	end
	table.sort(plain)
	return tris, plain
end

function MS.childrenFollow()
	return MS.settings == nil or MS.settings.moveChildren ~= false
end

---Like MS.selSplit() but also includes the children of everything selected
---(when "Children follow parent" is on). Used by every move / rotate / scale.
function MS.selSplitFamily()
	if (not MS.childrenFollow()) then return MS.selSplit() end
	local set = MS.selKeys()
	if (next(set) == nil) then return {}, {} end
	return MS.splitKeys(MS.withDescendants(set, MS.hier()))
end

---Engine indices of everything selected + descendants (for highlighting)
function MS.followerObjs()
	if (not MS.childrenFollow()) then return {} end
	local set = MS.selKeys()
	if (next(set) == nil) then return {} end
	local H = MS.hier()
	local out = {}
	for key in pairs(MS.withDescendants(set, H)) do
		if (not set[key]) then table.insert(out, key) end
	end
	return sortKeys(out)
end

local function selectKeys(keys, primaryKey)
	MS.sel = {}
	MS.vertexSel = nil
	local first
	for _, key in ipairs(keys) do
		for _, idx in ipairs(MS.nodeObjs(key)) do
			MS.sel[idx] = true
			first = first or idx
		end
	end
	MS.primary = primaryKey and MS.nodeRep(primaryKey) or first
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end
MS.selectNodeKeys = selectKeys

---------------------------------------------------------------------------
-- Moving nodes
---------------------------------------------------------------------------

local function isIdentity(Q)
	if (not Q) then return true end
	for i = 1, 3 do
		for j = 1, 3 do
			if (abs(Q[i][j] - (i == j and 1 or 0)) > 1e-6) then return false end
		end
	end
	return true
end

---Rigid transform of one node: p -> pivot + Q (p - pivot) + d
function MS.transformNode(key, pivot, Q, d)
	local rot = not isIdentity(Q)
	local function tp(p)
		if (rot) then return V.add(V.add(pivot, M.apply(Q, V.sub(p, pivot))), d) end
		return V.add(p, d)
	end
	local kind, n = parseKey(key)
	if (kind == "t") then
		local t = MS.tris[n]
		if (not t) then return end
		t.a, t.b, t.c = tp(t.a), tp(t.b), tp(t.c)
		MS.triBuild(n)
	elseif (MS.objs[n]) then
		MS.setObjPos(n, tp(MS.objPos(n)))
		if (rot) then MS.setObjRot(n, M.mul(Q, MS.objRot(n))) end
	end
end

---Makes every descendant that isn't in `xf` follow the change of its closest
---ancestor that is. xf: key -> { pivot, Q, d }
function MS.followTransforms(xf, H)
	if (not MS.childrenFollow() or next(xf) == nil) then return end
	H = H or MS.hier()
	for _, key in ipairs(H.keys) do
		if (not xf[key]) then
			local p = H.parent[key]
			while (p) do
				local x = xf[p]
				if (x) then
					MS.transformNode(key, x.pivot, x.Q, x.d)
					break
				end
				p = H.parent[p]
			end
		end
	end
end

---Runs `fn` (an operation that only touches the selection itself) and then
---carries the children of every node it moved or turned along with it.
function MS.withChildrenFollowing(fn, ...)
	if (not MS.childrenFollow()) then return fn(...) end
	local H = MS.hier()
	local set = MS.selKeys()
	local before = {}
	for key in pairs(set) do
		if (H.children[key]) then before[key] = MS.nodeFrame(key) end
	end
	local results = { fn(...) }
	if (next(before) ~= nil) then
		-- Every selected node is an entry so its children follow it (or stay put
		-- with it) instead of following an ancestor further up
		local xf, any = {}, false
		for key in pairs(set) do
			local x = { pivot = { 0, 0, 0 }, Q = M.identity(), d = { 0, 0, 0 } }
			local b = before[key]
			if (b and MS.nodeExists(key)) then
				local a = MS.nodeFrame(key)
				local Q = M.mul(a.R, M.transpose(b.R))
				local d = V.sub(a.pos, b.pos)
				if (not isIdentity(Q) or V.len(d) > 1e-9) then
					x = { pivot = b.pos, Q = Q, d = d }
					any = true
				end
			end
			xf[key] = x
		end
		if (any) then MS.followTransforms(xf, H) end
	end
	return (table.unpack or unpack)(results)
end

---------------------------------------------------------------------------
-- Parenting
---------------------------------------------------------------------------

---Makes `parentKey` the parent of every key in `childKeys`. Returns how many changed.
function MS.setParent(childKeys, parentKey)
	local H = MS.hier()
	local puid = parentKey and MS.ensureUid(parentKey) or nil
	local n, refused = 0, 0
	for _, key in ipairs(childKeys) do
		if (key ~= parentKey and MS.nodeExists(key)) then
			if (parentKey and MS.isBelow(parentKey, key, H)) then
				refused = refused + 1
			else
				local d = MS.nodeData(key)
				if (d and d.parent ~= puid) then
					d.parent = puid
					n = n + 1
				end
			end
		end
	end
	if (n > 0) then
		MS.changed = true
		MS.changedSinceAutosave = true
	end
	return n, refused
end

---Parents everything selected to the primary (last clicked) object. Ctrl+P style.
function MS.parentSelection(parentKey)
	parentKey = parentKey or MS.nodeKey(MS.primary)
	if (not parentKey) then
		MS.toast("Select the children, then Shift+click the parent last")
		return
	end
	local _, list = MS.selKeys()
	local kids = {}
	for _, key in ipairs(list) do
		if (key ~= parentKey) then table.insert(kids, key) end
	end
	if (#kids == 0) then
		MS.toast("Select the children first, then Shift+click the parent last (or use Pick parent)")
		return
	end
	MS.pushUndo("Set parent")
	local n, refused = MS.setParent(kids, parentKey)
	if (n == 0) then
		table.remove(MS.undoStack)
	end
	local msg
	if (n > 0) then
		msg = "Parented " .. n .. " item" .. (n == 1 and "" or "s") .. " to " .. MS.nodeName(parentKey)
	elseif (refused > 0) then
		MS.toast("Can't do that: " .. MS.nodeName(parentKey) .. " is already a child of the selection")
		return
	else
		msg = "Already parented to " .. MS.nodeName(parentKey)
	end
	if (refused > 0) then
		msg = msg .. " (skipped " .. refused .. ": a parent can't become a child of its own child)"
	end
	MS.toast(msg)
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

---Clears the parent of every selected node (they keep their place in the world)
function MS.unparentSelection()
	local H = MS.hier()
	local _, list = MS.selKeys()
	local kids = {}
	for _, key in ipairs(list) do
		if (H.parent[key]) then table.insert(kids, key) end
	end
	if (#kids == 0) then
		MS.toast(#list == 0 and "Select something to unparent" or "The selection has no parent")
		return
	end
	MS.pushUndo("Clear parent")
	MS.setParent(kids, nil)
	MS.toast("Unparented " .. #kids .. " item" .. (#kids == 1 and "" or "s"))
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

---Unlinks the direct children of the selection (they become top level / move up a level)
function MS.releaseChildren()
	local H = MS.hier()
	local set, list = MS.selKeys()
	local moved = 0
	local any = false
	for _, key in ipairs(list) do
		if (H.children[key]) then any = true end
	end
	if (not any) then
		MS.toast("The selection has no children")
		return
	end
	MS.pushUndo("Release children")
	for _, key in ipairs(list) do
		local gp = H.parent[key]
		while (gp and set[gp]) do gp = H.parent[gp] end
		for _, c in ipairs(H.children[key] or {}) do
			if (not set[c]) then
				local d = MS.nodeData(c)
				d.parent = gp and MS.ensureUid(gp) or nil
				moved = moved + 1
			end
		end
	end
	MS.changed = true
	MS.changedSinceAutosave = true
	MS.toast("Released " .. moved .. " child" .. (moved == 1 and "" or "ren"))
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

function MS.selectParent()
	local H = MS.hier()
	local _, list = MS.selKeys()
	local out, seen = {}, {}
	for _, key in ipairs(list) do
		local p = H.parent[key]
		if (p and not seen[p]) then
			seen[p] = true
			table.insert(out, p)
		end
	end
	if (#out == 0) then
		MS.toast(#list == 0 and "Nothing selected" or "No parent - this is already at the top")
		return
	end
	selectKeys(out)
	MS.toast("Selected parent: " .. MS.nodeName(out[1]) .. (#out > 1 and (" (+" .. (#out - 1) .. ")") or ""))
end

---Selects the children of the selection. `all`: every descendant, keeping the selection.
function MS.selectChildren(all)
	local H = MS.hier()
	local set, list = MS.selKeys()
	local out, seen = {}, {}
	local function add(k)
		if (not seen[k]) then
			seen[k] = true
			table.insert(out, k)
		end
	end
	if (all) then
		for _, key in ipairs(list) do add(key) end
	end
	local found = 0
	for _, key in ipairs(list) do
		local kids = all and MS.descendants(key, H) or (H.children[key] or {})
		for _, c in ipairs(kids) do
			if (not set[c]) then found = found + 1 end
			add(c)
		end
	end
	if (found == 0) then
		MS.toast(#list == 0 and "Nothing selected" or "No children")
		return
	end
	selectKeys(sortKeys(out), all and MS.nodeKey(MS.primary) or nil)
	MS.toast(all and ("Selected the whole branch (" .. #out .. " items)") or ("Selected " .. found .. " child" .. (found == 1 and "" or "ren")))
end

---Before deleting `set`: children that survive move up to the closest surviving ancestor
function MS.hierBeforeDelete(set)
	local H = MS.hier()
	for _, key in ipairs(H.keys) do
		local p = H.parent[key]
		if (not set[key] and p and set[p]) then
			while (p and set[p]) do p = H.parent[p] end
			local d = MS.nodeData(key)
			if (d) then d.parent = p and MS.ensureUid(p) or nil end
		end
	end
end

---Deletes the selection together with all of its children
function MS.deleteBranch()
	local set = MS.selKeys()
	if (next(set) == nil) then
		MS.toast("Nothing selected")
		return
	end
	local list = {}
	for k in pairs(MS.withDescendants(set, MS.hier())) do table.insert(list, k) end
	selectKeys(list)
	MS.deleteSelected()
end

---Turns a group name into a hierarchy: everything in the group becomes a child of the primary
function MS.groupToParent()
	local m = MS.meta[MS.primary]
	local g = m and m.group
	if (not g) then
		MS.toast("Give the selection a group name first")
		return
	end
	local pk = MS.nodeKey(MS.primary)
	local kids, seen = {}, {}
	for idx, mm in pairs(MS.meta) do
		if (mm.group == g and MS.objs[idx]) then
			local k = MS.nodeKey(idx)
			if (k and k ~= pk and not seen[k]) then
				seen[k] = true
				table.insert(kids, k)
			end
		end
	end
	if (#kids == 0) then
		MS.toast("Nothing else is in group \"" .. g .. "\"")
		return
	end
	MS.pushUndo("Group to parent")
	local n = MS.setParent(kids, pk)
	MS.toast("Parented " .. n .. " item" .. (n == 1 and "" or "s") .. " of \"" .. g .. "\" to " .. MS.nodeName(pk))
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

---Short description of the primary's place in the hierarchy (for the Info tab)
function MS.hierSummary()
	local key = MS.nodeKey(MS.primary)
	if (not key) then return "Nothing selected" end
	local H = MS.hier()
	local p = H.parent[key]
	local kids = H.children[key] and #H.children[key] or 0
	local all = #MS.descendants(key, H)
	local s = "Parent: " .. (p and MS.nodeName(p) or "none (top level)")
	s = s .. "\nChildren: " .. kids
	if (all > kids) then s = s .. " (" .. all .. " in the whole branch)" end
	return s
end

---------------------------------------------------------------------------
-- Children follow the selection-only tools too
---------------------------------------------------------------------------

for _, name in ipairs({ "dropToFloor", "snapSelectionToGrid", "resetRotation", "alignSelection", "distributeSelection" }) do
	local original = MS[name]
	if (original) then
		MS[name] = function(...) return MS.withChildrenFollowing(original, ...) end
	end
end
