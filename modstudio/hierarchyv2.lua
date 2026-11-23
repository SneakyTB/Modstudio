-- Mod Studio: parent / child hierarchy
--
-- Any object or triangle can be the parent of any number of children. Moving,
-- rotating or scaling a parent carries its whole branch along (the "Children
-- follow parent" setting turns that off). Positions stay in world space, so
-- un-parenting never moves anything and exported .tbm files are unchanged:
-- the hierarchy is an editing aid, saved in Mod Studio project files.
--
-- A "node" is a plain object ("o<index>") or a whole triangle ("t<id>").
-- Each node can carry a stable `uid` (kept in MSV2.meta for objects, in the
-- triangle table for triangles) and a `parent` uid. Engine indices change
-- on undo / project load, uids don't, so nothing needs remapping.

local MSV2 = MSV2
local V, M = MSV2.V, MSV2.M
local abs = math.abs

MSV2.nextUid = MSV2.nextUid or 1

---------------------------------------------------------------------------
-- Nodes
---------------------------------------------------------------------------

---Node key of the object at engine index `idx` (triangle slices map to their triangle)
function MSV2.nodeKey(idx)
	if (idx == nil) then return nil end
	local m = MSV2.meta[idx]
	if (m and m.tri and MSV2.tris[m.tri]) then return "t" .. m.tri end
	if (MSV2.objs[idx]) then return "o" .. idx end
	return nil
end

local function parseKey(key)
	return key:sub(1, 1), tonumber(key:sub(2))
end
MSV2.parseNodeKey = parseKey

---The table holding a node's uid / parent (meta for objects, the triangle itself)
function MSV2.nodeData(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MSV2.tris[n] end
	if (MSV2.objs[n]) then
		MSV2.meta[n] = MSV2.meta[n] or {}
		return MSV2.meta[n]
	end
	return nil
end

function MSV2.nodeExists(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MSV2.tris[n] ~= nil and #MSV2.tris[n].objs > 0 end
	return MSV2.objs[n] ~= nil
end

---Engine indices that make up a node
function MSV2.nodeObjs(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MSV2.tris[n] and MSV2.tris[n].objs or {} end
	return MSV2.objs[n] and { n } or {}
end

---One engine index that stands for the node (for selecting / sorting)
function MSV2.nodeRep(key)
	return MSV2.nodeObjs(key)[1]
end

function MSV2.nodeName(key)
	local kind, n = parseKey(key)
	if (kind == "t") then
		local t = MSV2.tris[n]
		return (t and t.name) or ("Triangle " .. n)
	end
	return MSV2.objName(n)
end

---Names objects / triangles. Several at once get "Name 1", "Name 2"...
---in scene order. An empty name puts the default name back.
function MSV2.renameNodes(keys, name)
	if (#keys == 0) then return end
	name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	MSV2.pushUndo("Rename")
	for i, key in ipairs(keys) do
		local d = MSV2.nodeData(key)
		if (d) then
			if (name == "") then d.name = nil
			elseif (#keys == 1) then d.name = name
			else d.name = name .. " " .. i end
		end
	end
	MSV2.changed = true
	if (name == "") then
		MSV2.toast("Name cleared")
	else
		MSV2.toast(#keys == 1 and ("Renamed to \"" .. name .. "\"") or ("Renamed " .. #keys .. " items " .. name .. " 1 - " .. #keys))
	end
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end

function MSV2.nodePos(key)
	local kind, n = parseKey(key)
	if (kind == "t") then return MSV2.triCentroid(n) end
	return MSV2.objPos(n)
end

---Position + orientation of a node. Triangles use a frame built from their corners
---so it stays stable under any rigid move.
function MSV2.nodeFrame(key)
	local kind, n = parseKey(key)
	if (kind == "t") then
		local t = MSV2.tris[n]
		local e1 = V.sub(t.b, t.a)
		local nrm = V.cross(e1, V.sub(t.c, t.a))
		local R = M.identity()
		if (V.len(e1) > 1e-6 and V.len(nrm) > 1e-9) then
			local u = V.norm(e1)
			local w = V.norm(nrm)
			R = M.fromCols(u, V.cross(w, u), w)
		end
		return { pos = MSV2.triCentroid(n), R = R }
	end
	return { pos = MSV2.objPos(n), R = MSV2.objRot(n) }
end

---Gives the node a uid if it has none yet and returns it
function MSV2.ensureUid(key)
	local d = MSV2.nodeData(key)
	if (not d) then return nil end
	if (not d.uid) then
		d.uid = MSV2.nextUid
		MSV2.nextUid = MSV2.nextUid + 1
	end
	return d.uid
end

function MSV2.newUid()
	local u = MSV2.nextUid
	MSV2.nextUid = MSV2.nextUid + 1
	return u
end

---------------------------------------------------------------------------
-- Hierarchy index (rebuilt on demand - it's cheap)
---------------------------------------------------------------------------

local function orderOf(key)
	return MSV2.nodeRep(key) or math.huge
end

local function sortKeys(list)
	table.sort(list, function(a, b) return orderOf(a) < orderOf(b) end)
	return list
end
MSV2.sortNodeKeys = sortKeys

---Builds { keys, byUid, parent = {child -> parent key}, children = {key -> list}, roots }
function MSV2.hier()
	local H = { keys = {}, byUid = {}, parent = {}, children = {}, roots = {} }
	for idx in pairs(MSV2.objs) do
		local m = MSV2.meta[idx]
		if (not (m and m.tri and MSV2.tris[m.tri])) then table.insert(H.keys, "o" .. idx) end
	end
	for id, t in pairs(MSV2.tris) do
		if (#t.objs > 0) then table.insert(H.keys, "t" .. id) end
	end
	sortKeys(H.keys)
	local data = {}
	for _, key in ipairs(H.keys) do
		local d = MSV2.nodeData(key)
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
function MSV2.descendants(key, H, out)
	out = out or {}
	for _, c in ipairs(H.children[key] or {}) do
		table.insert(out, c)
		MSV2.descendants(c, H, out)
	end
	return out
end

function MSV2.depthOf(key, H)
	local d, p = 0, H.parent[key]
	while (p) do
		d = d + 1
		p = H.parent[p]
	end
	return d
end

---True if `a` sits somewhere below `b`
function MSV2.isBelow(a, b, H)
	local p = H.parent[a]
	while (p) do
		if (p == b) then return true end
		p = H.parent[p]
	end
	return false
end

---Removes references to parents that no longer exist, drops duplicate uids
---and moves the uid counter past everything in use. Call after bulk changes.
function MSV2.hierFix()
	local seen, maxUid = {}, 0
	local datas = {}
	for idx, m in pairs(MSV2.meta) do
		if (MSV2.objs[idx] and not (m.tri and MSV2.tris[m.tri])) then
			table.insert(datas, m)
		elseif (m.tri) then
			-- Slices belong to their triangle; they never carry their own links
			m.uid, m.parent = nil, nil
		end
	end
	for _, t in pairs(MSV2.tris) do table.insert(datas, t) end
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
	MSV2.nextUid = math.max(MSV2.nextUid or 1, maxUid + 1)
end

---------------------------------------------------------------------------
-- Selection helpers
---------------------------------------------------------------------------

---Set of selected node keys + the list in scene order
function MSV2.selKeys()
	local set, list = {}, {}
	for _, idx in ipairs(MSV2.selList()) do
		local key = MSV2.nodeKey(idx)
		if (key and not set[key]) then
			set[key] = true
			table.insert(list, key)
		end
	end
	return set, sortKeys(list)
end

---The set plus every descendant of anything in it
function MSV2.withDescendants(set, H)
	local out = {}
	for key in pairs(set) do
		out[key] = true
		for _, d in ipairs(MSV2.descendants(key, H)) do out[d] = true end
	end
	return out
end

---Same shape as MSV2.selSplit(): set of triangle ids, sorted list of plain indices
function MSV2.splitKeys(set)
	local tris, plain = {}, {}
	for key in pairs(set) do
		local kind, n = parseKey(key)
		if (kind == "t") then
			if (MSV2.tris[n]) then tris[n] = true end
		elseif (MSV2.objs[n]) then
			table.insert(plain, n)
		end
	end
	table.sort(plain)
	return tris, plain
end

function MSV2.childrenFollow()
	return MSV2.settings == nil or MSV2.settings.moveChildren ~= false
end

---Like MSV2.selSplit() but also includes the children of everything selected
---(when "Children follow parent" is on). Used by every move / rotate / scale.
function MSV2.selSplitFamily()
	if (not MSV2.childrenFollow()) then return MSV2.selSplit() end
	local set = MSV2.selKeys()
	if (next(set) == nil) then return {}, {} end
	return MSV2.splitKeys(MSV2.withDescendants(set, MSV2.hier()))
end

---Engine indices of everything selected + descendants (for highlighting)
function MSV2.followerObjs()
	if (not MSV2.childrenFollow()) then return {} end
	local set = MSV2.selKeys()
	if (next(set) == nil) then return {} end
	local H = MSV2.hier()
	local out = {}
	for key in pairs(MSV2.withDescendants(set, H)) do
		if (not set[key]) then table.insert(out, key) end
	end
	return sortKeys(out)
end

local function selectKeys(keys, primaryKey)
	MSV2.sel = {}
	MSV2.vertexSel = nil
	local first
	for _, key in ipairs(keys) do
		for _, idx in ipairs(MSV2.nodeObjs(key)) do
			MSV2.sel[idx] = true
			first = first or idx
		end
	end
	MSV2.primary = primaryKey and MSV2.nodeRep(primaryKey) or first
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end
MSV2.selectNodeKeys = selectKeys

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
function MSV2.transformNode(key, pivot, Q, d)
	local rot = not isIdentity(Q)
	local function tp(p)
		if (rot) then return V.add(V.add(pivot, M.apply(Q, V.sub(p, pivot))), d) end
		return V.add(p, d)
	end
	local kind, n = parseKey(key)
	if (kind == "t") then
		local t = MSV2.tris[n]
		if (not t) then return end
		t.a, t.b, t.c = tp(t.a), tp(t.b), tp(t.c)
		MSV2.triBuild(n)
	elseif (MSV2.objs[n]) then
		MSV2.setObjPos(n, tp(MSV2.objPos(n)))
		if (rot) then MSV2.setObjRot(n, M.mul(Q, MSV2.objRot(n))) end
	end
end

---Makes every descendant that isn't in `xf` follow the change of its closest
---ancestor that is. xf: key -> { pivot, Q, d }
function MSV2.followTransforms(xf, H)
	if (not MSV2.childrenFollow() or next(xf) == nil) then return end
	H = H or MSV2.hier()
	for _, key in ipairs(H.keys) do
		if (not xf[key]) then
			local p = H.parent[key]
			while (p) do
				local x = xf[p]
				if (x) then
					MSV2.transformNode(key, x.pivot, x.Q, x.d)
					break
				end
				p = H.parent[p]
			end
		end
	end
end

---Runs `fn` (an operation that only touches the selection itself) and then
---carries the children of every node it moved or turned along with it.
function MSV2.withChildrenFollowing(fn, ...)
	if (not MSV2.childrenFollow()) then return fn(...) end
	local H = MSV2.hier()
	local set = MSV2.selKeys()
	local before = {}
	for key in pairs(set) do
		if (H.children[key]) then before[key] = MSV2.nodeFrame(key) end
	end
	local results = { fn(...) }
	if (next(before) ~= nil) then
		-- Every selected node is an entry so its children follow it (or stay put
		-- with it) instead of following an ancestor further up
		local xf, any = {}, false
		for key in pairs(set) do
			local x = { pivot = { 0, 0, 0 }, Q = M.identity(), d = { 0, 0, 0 } }
			local b = before[key]
			if (b and MSV2.nodeExists(key)) then
				local a = MSV2.nodeFrame(key)
				local Q = M.mul(a.R, M.transpose(b.R))
				local d = V.sub(a.pos, b.pos)
				if (not isIdentity(Q) or V.len(d) > 1e-9) then
					x = { pivot = b.pos, Q = Q, d = d }
					any = true
				end
			end
			xf[key] = x
		end
		if (any) then MSV2.followTransforms(xf, H) end
	end
	return (table.unpack or unpack)(results)
end

---------------------------------------------------------------------------
-- Parenting
---------------------------------------------------------------------------

---Makes `parentKey` the parent of every key in `childKeys`. Returns how many changed.
function MSV2.setParent(childKeys, parentKey)
	local H = MSV2.hier()
	local puid = parentKey and MSV2.ensureUid(parentKey) or nil
	local n, refused = 0, 0
	for _, key in ipairs(childKeys) do
		if (key ~= parentKey and MSV2.nodeExists(key)) then
			if (parentKey and MSV2.isBelow(parentKey, key, H)) then
				refused = refused + 1
			else
				local d = MSV2.nodeData(key)
				if (d and d.parent ~= puid) then
					d.parent = puid
					n = n + 1
				end
			end
		end
	end
	if (n > 0) then
		MSV2.changed = true
		MSV2.changedSinceAutosave = true
	end
	return n, refused
end

---Parents everything selected to the primary (last clicked) object. Ctrl+P style.
function MSV2.parentSelection(parentKey)
	parentKey = parentKey or MSV2.nodeKey(MSV2.primary)
	if (not parentKey) then
		MSV2.toast("Select the children, then Shift+click the parent last")
		return
	end
	local _, list = MSV2.selKeys()
	local kids = {}
	for _, key in ipairs(list) do
		if (key ~= parentKey) then table.insert(kids, key) end
	end
	if (#kids == 0) then
		MSV2.toast("Select the children first, then Shift+click the parent last (or use Pick parent)")
		return
	end
	MSV2.pushUndo("Set parent")
	local n, refused = MSV2.setParent(kids, parentKey)
	if (n == 0) then
		table.remove(MSV2.undoStack)
	end
	local msg
	if (n > 0) then
		msg = "Parented " .. n .. " item" .. (n == 1 and "" or "s") .. " to " .. MSV2.nodeName(parentKey)
	elseif (refused > 0) then
		MSV2.toast("Can't do that: " .. MSV2.nodeName(parentKey) .. " is already a child of the selection")
		return
	else
		msg = "Already parented to " .. MSV2.nodeName(parentKey)
	end
	if (refused > 0) then
		msg = msg .. " (skipped " .. refused .. ": a parent can't become a child of its own child)"
	end
	MSV2.toast(msg)
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end

---Clears the parent of every selected node (they keep their place in the world)
function MSV2.unparentSelection()
	local H = MSV2.hier()
	local _, list = MSV2.selKeys()
	local kids = {}
	for _, key in ipairs(list) do
		if (H.parent[key]) then table.insert(kids, key) end
	end
	if (#kids == 0) then
		MSV2.toast(#list == 0 and "Select something to unparent" or "The selection has no parent")
		return
	end
	MSV2.pushUndo("Clear parent")
	MSV2.setParent(kids, nil)
	MSV2.toast("Unparented " .. #kids .. " item" .. (#kids == 1 and "" or "s"))
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end

---Unlinks the direct children of the selection (they become top level / move up a level)
function MSV2.releaseChildren()
	local H = MSV2.hier()
	local set, list = MSV2.selKeys()
	local moved = 0
	local any = false
	for _, key in ipairs(list) do
		if (H.children[key]) then any = true end
	end
	if (not any) then
		MSV2.toast("The selection has no children")
		return
	end
	MSV2.pushUndo("Release children")
	for _, key in ipairs(list) do
		local gp = H.parent[key]
		while (gp and set[gp]) do gp = H.parent[gp] end
		for _, c in ipairs(H.children[key] or {}) do
			if (not set[c]) then
				local d = MSV2.nodeData(c)
				d.parent = gp and MSV2.ensureUid(gp) or nil
				moved = moved + 1
			end
		end
	end
	MSV2.changed = true
	MSV2.changedSinceAutosave = true
	MSV2.toast("Released " .. moved .. " child" .. (moved == 1 and "" or "ren"))
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end

function MSV2.selectParent()
	local H = MSV2.hier()
	local _, list = MSV2.selKeys()
	local out, seen = {}, {}
	for _, key in ipairs(list) do
		local p = H.parent[key]
		if (p and not seen[p]) then
			seen[p] = true
			table.insert(out, p)
		end
	end
	if (#out == 0) then
		MSV2.toast(#list == 0 and "Nothing selected" or "No parent - this is already at the top")
		return
	end
	selectKeys(out)
	MSV2.toast("Selected parent: " .. MSV2.nodeName(out[1]) .. (#out > 1 and (" (+" .. (#out - 1) .. ")") or ""))
end

---Selects the children of the selection. `all`: every descendant, keeping the selection.
function MSV2.selectChildren(all)
	local H = MSV2.hier()
	local set, list = MSV2.selKeys()
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
		local kids = all and MSV2.descendants(key, H) or (H.children[key] or {})
		for _, c in ipairs(kids) do
			if (not set[c]) then found = found + 1 end
			add(c)
		end
	end
	if (found == 0) then
		MSV2.toast(#list == 0 and "Nothing selected" or "No children")
		return
	end
	selectKeys(sortKeys(out), all and MSV2.nodeKey(MSV2.primary) or nil)
	MSV2.toast(all and ("Selected the whole branch (" .. #out .. " items)") or ("Selected " .. found .. " child" .. (found == 1 and "" or "ren")))
end

---Before deleting `set`: children that survive move up to the closest surviving ancestor
function MSV2.hierBeforeDelete(set)
	local H = MSV2.hier()
	for _, key in ipairs(H.keys) do
		local p = H.parent[key]
		if (not set[key] and p and set[p]) then
			while (p and set[p]) do p = H.parent[p] end
			local d = MSV2.nodeData(key)
			if (d) then d.parent = p and MSV2.ensureUid(p) or nil end
		end
	end
end

---Deletes the selection together with all of its children
function MSV2.deleteBranch()
	local set = MSV2.selKeys()
	if (next(set) == nil) then
		MSV2.toast("Nothing selected")
		return
	end
	local list = {}
	for k in pairs(MSV2.withDescendants(set, MSV2.hier())) do table.insert(list, k) end
	selectKeys(list)
	MSV2.deleteSelected()
end

---Turns a group name into a hierarchy: everything in the group becomes a child of the primary
function MSV2.groupToParent()
	local m = MSV2.meta[MSV2.primary]
	local g = m and m.group
	if (not g) then
		MSV2.toast("Give the selection a group name first")
		return
	end
	local pk = MSV2.nodeKey(MSV2.primary)
	local kids, seen = {}, {}
	for idx, mm in pairs(MSV2.meta) do
		if (mm.group == g and MSV2.objs[idx]) then
			local k = MSV2.nodeKey(idx)
			if (k and k ~= pk and not seen[k]) then
				seen[k] = true
				table.insert(kids, k)
			end
		end
	end
	if (#kids == 0) then
		MSV2.toast("Nothing else is in group \"" .. g .. "\"")
		return
	end
	MSV2.pushUndo("Group to parent")
	local n = MSV2.setParent(kids, pk)
	MSV2.toast("Parented " .. n .. " item" .. (n == 1 and "" or "s") .. " of \"" .. g .. "\" to " .. MSV2.nodeName(pk))
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end

---Short description of the primary's place in the hierarchy (for the Info tab)
function MSV2.hierSummary()
	local key = MSV2.nodeKey(MSV2.primary)
	if (not key) then return "Nothing selected" end
	local H = MSV2.hier()
	local p = H.parent[key]
	local kids = H.children[key] and #H.children[key] or 0
	local all = #MSV2.descendants(key, H)
	local s = "Parent: " .. (p and MSV2.nodeName(p) or "none (top level)")
	s = s .. "\nChildren: " .. kids
	if (all > kids) then s = s .. " (" .. all .. " in the whole branch)" end
	return s
end

---------------------------------------------------------------------------
-- Children follow the selection-only tools too
---------------------------------------------------------------------------

for _, name in ipairs({ "dropToFloor", "snapSelectionToGrid", "resetRotation", "alignSelection", "distributeSelection" }) do
	local original = MSV2[name]
	if (original) then
		MSV2[name] = function(...) return MSV2.withChildrenFollowing(original, ...) end
	end
end
