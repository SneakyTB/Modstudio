-- Mod Studio: per-object 3D models and asset tools
--
-- How Toribash does it (verified in data/mod/*.tbm + the game exe strings):
--   * An env_obj block can carry "use_model 1" and "model_name <path>".
--   * The model file is data/mod_assets/<modname>/<model_name>.obj, where <modname> is the mod's path
--     under data/mod without ".tbm" (the exe has the format "data/mod_assets/%s/%s.obj").
--     So a mod at data/mod/bowling_noki.tbm writes "../Noki/bowling" for data/mod_assets/Noki/bowling.obj,
--     and data/mod/system/events/holeinthewall6.tbm writes "../../../events/sakura".
--     Mod Studio exports to data/mod/modmaker/<name>.tbm, so its paths start with "../../".
--   * The mod maker API has no per-object model field, so Mod Studio keeps the model in the object's
--     metadata (meta.useModel / meta.modelName = path under data/mod_assets, no extension), previews it
--     with load_obj + draw_obj_m, and adds the two lines to the exported .tbm after export_mod_maker.
--   * The engine draws the model with its origin at the object's position, rotated by the object's
--     rotation and scaled per axis by the object's "sides" (bowling_noki: pin sides 0.2 0.2 0.75 sit exactly
--     on the lane because 0.75 * model z-min -0.491 + pos z 0.72 = 0.352 = lane top).

local MSV2 = MSV2
local V, M = MSV2.V, MSV2.M
local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local clock = MSV2.clock

MSV2.ASSET_ROOT = "data/mod_assets"
local ROOT = MSV2.ASSET_ROOT

---------------------------------------------------------------------------
-- File helpers (io.open with root = true starts at the Toribash folder)
---------------------------------------------------------------------------

local function openRoot(path, mode)
	local ok, f = pcall(io.open, path, mode, true)
	if (ok and type(f) == "userdata") then return f end
	return nil
end

function MSV2.fileExists(path)
	local f = openRoot(path, "rb")
	if (f) then f:close() return true end
	return false
end

---Whole file as a string (binary safe), or nil
function MSV2.readBytes(path)
	local f = openRoot(path, "rb")
	if (not f) then return nil end
	local ok, data = pcall(f.read, f, "*a")
	f:close()
	if (ok and type(data) == "string") then return data end
	return nil
end

---Writes a whole file (binary). Returns true on success. Callers must check the file doesn't exist
---first when they must not overwrite: "wb" truncates.
function MSV2.writeBytes(path, data)
	local f = openRoot(path, "wb")
	if (not f) then return false end
	local ok = pcall(f.write, f, data)
	f:close()
	return ok == true
end

local function splitPath(s)
	local out = {}
	for part in tostring(s or ""):gsub("\\", "/"):gmatch("[^/]+") do table.insert(out, part) end
	return out
end

local function baseName(path) return (tostring(path):gsub("\\", "/"):match("([^/]*)$")) end
local function dirName(path) return (tostring(path):gsub("\\", "/"):match("^(.*)/[^/]*$")) or "" end

---------------------------------------------------------------------------
-- Model names: canonical = path under data/mod_assets without ".obj" ("Noki/bowling").
-- model_name in the .tbm is that path relative to data/mod_assets/<modname>/.
---------------------------------------------------------------------------

---Tidies what a user typed or the picker gave: slashes, no .obj, no "data/mod_assets/" prefix
function MSV2.cleanModelName(s)
	s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
	s = s:gsub("^[Dd]ata/[Mm]od_assets/", ""):gsub("^[Mm]od_assets/", ""):gsub("^/+", "")
	s = s:gsub("%.[Oo][Bb][Jj]$", ""):gsub("//+", "/")
	return s
end

---Folders between data/mod_assets and the mod. For a file name like "modmaker/Foo.tbm" it's { "modmaker", "Foo" }.
---With no name (not exported yet) Mod Studio's own export location is assumed.
function MSV2.modBaseSegs(fullName)
	local depth = tonumber(MSV2.settings.modelDepth) or 2
	if (fullName and fullName ~= "") then
		local segs = splitPath((tostring(fullName):gsub("%.[Tt][Bb][Mm]$", "")))
		if (#segs > 0) then return segs end
	end
	local name = MSV2.safeName(MSV2.saveName or "Untitled")
	if (depth >= 2) then return { "modmaker", name } end
	return { name }
end

---"../Noki/bowling" (as written in a .tbm) -> "Noki/bowling". Returns nil, reason when it climbs out of mod_assets.
function MSV2.resolveModelName(rel, baseSegs)
	local stack = {}
	for _, s in ipairs(baseSegs or {}) do table.insert(stack, s) end
	for _, part in ipairs(splitPath(rel)) do
		if (part == "..") then
			if (#stack == 0) then return nil, "goes above data/mod_assets" end
			table.remove(stack)
		elseif (part ~= ".") then
			table.insert(stack, part)
		end
	end
	if (#stack == 0) then return nil, "empty" end
	return table.concat(stack, "/")
end

---"Noki/bowling" -> "../../Noki/bowling" for a mod whose assets folder is baseSegs
function MSV2.relativeModelName(canon, baseSegs)
	if (not canon or canon == "") then return "" end
	local segs = splitPath(canon)
	for _, s in ipairs(segs) do
		-- Already relative / unresolved (imported with a path we couldn't place): keep exactly as written
		if (s == ".." or s == ".") then return canon end
	end
	local c = 0
	baseSegs = baseSegs or {}
	while (c < #baseSegs and c < #segs - 1 and segs[c + 1] == baseSegs[c + 1]) do c = c + 1 end
	local out = {}
	for _ = 1, #baseSegs - c do table.insert(out, "..") end
	for i = c + 1, #segs do table.insert(out, segs[i]) end
	return table.concat(out, "/")
end

---Reasons a stored model name won't load (nil = fine)
function MSV2.modelNameProblem(name)
	if (not name or name == "") then return "no model chosen" end
	if (name:find("\\", 1, true)) then return "uses backslashes (use /)" end
	if (name:find("^%a:") or name:find("^/")) then return "is an absolute path (must be inside data/mod_assets)" end
	if (name:find("%.%.")) then return "climbs out of data/mod_assets (..)" end
	if (name:lower():find("%.obj$")) then return "ends in .obj (the game adds it)" end
	if (name:find("^%s") or name:find("%s$")) then return "has spaces at the start or end" end
	if (name:find("[<>:\"|?*]")) then return "has characters Windows file names can't use" end
	return nil
end

---------------------------------------------------------------------------
-- Finding .obj files under data/mod_assets
---------------------------------------------------------------------------

MSV2.modelList = MSV2.modelList or nil
MSV2.modelListTime = MSV2.modelListTime or 0

local function isFolder(path)
	if (is_folder) then
		local ok, r = pcall(is_folder, path)
		if (ok) then return r == true end
	end
	return false
end

function MSV2.scanModels(force)
	if (MSV2.modelList and not force and clock() - MSV2.modelListTime < 60) then return MSV2.modelList end
	local out = {}
	local seen = 0
	local function walk(dir, rel, depth)
		if (depth > 6 or seen > 3000) then return end
		local ok, files = pcall(get_files, dir, "")
		if (not ok or type(files) ~= "table") then return end
		for _, v in pairs(files) do
			if (type(v) == "string" and v ~= "." and v ~= "..") then
				seen = seen + 1
				if (v:lower():match("%.obj$")) then
					table.insert(out, rel .. v:sub(1, -5))
				elseif (not v:match("%.%w+$") or isFolder(dir .. "/" .. v)) then
					walk(dir .. "/" .. v, rel .. v .. "/", depth + 1)
				end
			end
		end
	end
	walk(ROOT, "", 0)
	table.sort(out, function(a, b) return a:lower() < b:lower() end)
	MSV2.modelList, MSV2.modelListTime = out, clock()
	return out
end

---------------------------------------------------------------------------
-- Reading an .obj: bounds, UVs, material file and textures
---------------------------------------------------------------------------

MSV2.objCache = MSV2.objCache or {}

local function texturesFromMtl(mtlText)
	local list = {}
	if (not mtlText) then return list end
	for line in mtlText:gmatch("[^\r\n]+") do
		local key, rest = line:match("^%s*(%S+)%s+(.-)%s*$")
		if (key and rest and (key:lower():find("^map_") or key == "bump" or key == "decal" or key == "disp")) then
			-- Options (-s 1 1 1) come first; the file is the last token
			local file = rest:match("(%S+)$")
			if (file) then table.insert(list, (file:gsub("\\", "/"))) end
		end
	end
	return list
end

---Info about data/mod_assets/<name>.obj, cached for a few seconds:
---{ missing, min, max, center, ext, verts, hasUV, files = { existing paths }, absent = { missing paths }, textures, mtl }
function MSV2.objInfo(name, force)
	local c = MSV2.objCache[name]
	if (c and not force and clock() - c.t < 15) then return c end
	local info = { name = name, path = ROOT .. "/" .. name .. ".obj", t = clock(), files = {}, absent = {}, textures = {} }
	MSV2.objCache[name] = info
	local data = MSV2.readBytes(info.path)
	if (not data) then
		info.missing = true
		table.insert(info.absent, info.path)
		return info
	end
	info.size = #data
	local lo, hi, n, uv = { 1e30, 1e30, 1e30 }, { -1e30, -1e30, -1e30 }, 0, 0
	for line in data:gmatch("[^\r\n]+") do
		local c1 = line:sub(1, 1)
		if (c1 == "v") then
			local tag, a, b, cc = line:match("^(v)%s+(%S+)%s+(%S+)%s+(%S+)")
			if (tag) then
				a, b, cc = tonumber(a), tonumber(b), tonumber(cc)
				if (a and b and cc) then
					n = n + 1
					if (a < lo[1]) then lo[1] = a end
					if (a > hi[1]) then hi[1] = a end
					if (b < lo[2]) then lo[2] = b end
					if (b > hi[2]) then hi[2] = b end
					if (cc < lo[3]) then lo[3] = cc end
					if (cc > hi[3]) then hi[3] = cc end
				end
			elseif (line:sub(1, 3) == "vt ") then
				uv = uv + 1
			end
		elseif (not info.mtl and line:sub(1, 7) == "mtllib ") then
			info.mtl = (line:sub(8):gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/"):gsub("^%./", ""))
		end
	end
	info.verts, info.hasUV = n, uv > 0
	if (n > 0) then
		info.min, info.max = lo, hi
		info.center = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
		info.ext = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] }
	end

	local dir = dirName(name)
	local prefix = ROOT .. "/" .. (dir ~= "" and (dir .. "/") or "")
	table.insert(info.files, info.path)

	-- Textures named by the .mtl (when that file exists); the game also looks for <name>.tga next to the model
	local refs = {}
	if (info.mtl) then
		local mtlPath = prefix .. info.mtl
		local mtlText = MSV2.readBytes(mtlPath)
		if (mtlText) then
			table.insert(info.files, mtlPath)
			info.mtlFound = true
			for _, t in ipairs(texturesFromMtl(mtlText)) do table.insert(refs, t) end
		else
			info.mtlMissing = true
		end
	end
	local seenTex = {}
	for _, t in ipairs(refs) do
		local p = prefix .. t:gsub("^%./", "")
		if (not seenTex[p]) then
			seenTex[p] = true
			if (MSV2.fileExists(p)) then
				table.insert(info.files, p)
				table.insert(info.textures, p)
			else
				table.insert(info.absent, p)
				info.textureMissing = true
			end
		end
	end
	local stem = baseName(name)
	for _, ext in ipairs({ ".tga", ".png" }) do
		local p = prefix .. stem .. ext
		if (not seenTex[p] and MSV2.fileExists(p)) then
			seenTex[p] = true
			table.insert(info.files, p)
			table.insert(info.textures, p)
		end
	end
	info.hasTexture = #info.textures > 0
	return info
end

---------------------------------------------------------------------------
-- Per-object model state (stored in MSV2.meta so undo, copy/paste, prefabs and projects carry it)
---------------------------------------------------------------------------

function MSV2.objModel(idx)
	local m = MSV2.meta[idx]
	if (not m) then return false, "" end
	return m.useModel == true, m.modelName or ""
end

local function touch()
	MSV2.changed = true
	MSV2.changedSinceAutosave = true
	-- Only metadata changed: the game's world doesn't need a rebuild
end

---Sets the model for a list of object indices. `use` / `name` may be nil to leave that part alone.
function MSV2.setObjModels(list, use, name)
	for _, idx in ipairs(list) do
		if (MSV2.objs[idx]) then
			MSV2.meta[idx] = MSV2.meta[idx] or {}
			local m = MSV2.meta[idx]
			if (use ~= nil) then m.useModel = use and true or nil end
			if (name ~= nil) then
				name = MSV2.cleanModelName(name)
				m.modelName = name ~= "" and name or nil
			end
			if (m.useModel == nil and m.modelName == nil) then m.useModel, m.modelName = nil, nil end
		end
	end
	touch()
end

function MSV2.modelUsers()
	local users, order = {}, {}
	for _, idx in ipairs(MSV2.sortedKeys(MSV2.meta)) do
		local m = MSV2.meta[idx]
		if (m and m.useModel and MSV2.objs[idx]) then
			local name = m.modelName or ""
			if (not users[name]) then users[name] = {}; table.insert(order, name) end
			table.insert(users[name], idx)
		end
	end
	table.sort(order, function(a, b) return a:lower() < b:lower() end)
	return users, order
end

---------------------------------------------------------------------------
-- Editor preview: load_obj once per path, draw_obj_m at the object's pose.
-- Slots (0..127) are shared with the game's own UI model cache, so we register in it.
---------------------------------------------------------------------------

MSV2.modelSlots = MSV2.modelSlots or {}   -- canonical name -> { slot, file } | { failed = time }
local MAX_PREVIEW_MODELS = 16

local function uiCache()
	_G.UIElement3DModelCache = _G.UIElement3DModelCache or {}
	_G.UIElement3DModelIndex = _G.UIElement3DModelIndex or 0
	return _G.UIElement3DModelCache
end

function MSV2.modelSlot(name)
	local rec = MSV2.modelSlots[name]
	if (rec) then
		if (rec.slot) then return rec.slot end
		if (clock() - rec.failed < 4) then return nil end
	end
	if (not load_obj or MSV2.modelProblem) then return nil end
	local loaded = 0
	for _, r in pairs(MSV2.modelSlots) do if (r.slot) then loaded = loaded + 1 end end
	if (loaded >= MAX_PREVIEW_MODELS) then
		if (not MSV2.modelCapWarned) then
			MSV2.modelCapWarned = true
			MSV2.toast("Preview shows up to " .. MAX_PREVIEW_MODELS .. " different models at once")
		end
		return nil
	end
	local file = ROOT .. "/" .. name
	if (MSV2.modelNameProblem(name) or not MSV2.fileExists(file .. ".obj")) then
		MSV2.modelSlots[name] = { failed = clock() }
		return nil
	end
	local cache = uiCache()
	local slot
	for i = 0, 127 do
		local e = cache[i]
		if (e and e.name == file) then
			e.count = (e.count or 0) + 1
			MSV2.modelSlots[name] = { slot = i, file = file }
			return i
		elseif (not e and not slot) then
			slot = i
		end
	end
	if (not slot) then
		MSV2.modelSlots[name] = { failed = clock() }
		return nil
	end
	local ok, res = pcall(load_obj, slot, file, 1)
	if (not ok or not res) then
		MSV2.modelSlots[name] = { failed = clock() }
		return nil
	end
	cache[slot] = { name = file, count = 1 }
	_G.UIElement3DModelIndex = max(_G.UIElement3DModelIndex or 0, slot)
	MSV2.modelSlots[name] = { slot = slot, file = file }
	return slot
end

---Releases one preview model (or all of them). Called on close and when the file changes.
function MSV2.unloadModels(name)
	local cache = uiCache()
	for n, rec in pairs(MSV2.modelSlots) do
		if (not name or n == name) then
			if (rec.slot) then
				local e = cache[rec.slot]
				if (e) then
					e.count = (e.count or 1) - 1
					if (e.count <= 0) then
						pcall(unload_obj, rec.slot)
						cache[rec.slot] = nil
					end
				else
					pcall(unload_obj, rec.slot)
				end
			end
			MSV2.modelSlots[n] = nil
		end
	end
	MSV2.objCache = {}
end

local function rotTB(R)
	local t = { r0 = R[1][1], r1 = R[1][2], r2 = R[1][3], r3 = 0, r4 = R[2][1], r5 = R[2][2], r6 = R[2][3], r7 = 0,
		r8 = R[3][1], r9 = R[3][2], r10 = R[3][3], r11 = 0, r12 = 0, r13 = 0, r14 = 0, r15 = 1 }
	for n = 0, 15 do t[n + 1] = t["r" .. n] end
	return t
end

---Scale the game applies to a model: the object's sides per axis (box: full size; ball: radius)
function MSV2.modelScale(idx)
	local o = MSV2.objs[idx]
	local x, y, z = o.dims_x, o.dims_y, o.dims_z
	if (o.type == 0) then y, z = x, x
	elseif (o.type == 2) then z = z or y end
	local k = MSV2.sizeK()
	return { (x or 1) * k, (y or x or 1) * k, (z or x or 1) * k }
end

---Called from the draw3d hook every frame
function MSV2.drawModels()
	if (not MSV2.settings.modelPreview or not draw_obj_m) then return end
	for idx, m in pairs(MSV2.meta) do
		if (m.useModel and m.modelName and m.modelName ~= "") then
			local o = MSV2.objs[idx]
			if (o and o.visible ~= false) then
				local slot = MSV2.modelSlot(m.modelName)
				if (slot) then
					local s = MSV2.modelScale(idx)
					local R = MSV2.objRot(idx)
					set_color(o.color_r or 1, o.color_g or 1, o.color_b or 1, o.color_a or 1)
					local ok = pcall(draw_obj_m, slot, o.pos_x or 0, o.pos_y or 0, o.pos_z or 0, s[1], s[2], s[3], rotTB(R))
					if (not ok) then
						MSV2.modelProblem = true
						MSV2.toast("Model preview isn't supported by this game version")
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Sizing: model <-> hitbox
---------------------------------------------------------------------------

---Scale + centre the game will draw for the model on this object: world centre and full world extents of its bounding box
function MSV2.modelWorldBox(idx)
	local m = MSV2.meta[idx]
	if (not m or not m.modelName) then return nil, "Pick a model first" end
	local info = MSV2.objInfo(m.modelName)
	if (info.missing) then return nil, "The model file isn't there: " .. info.path end
	if (not info.ext) then return nil, "No vertices found in the model" end
	local s = MSV2.modelScale(idx)
	local R = MSV2.objRot(idx)
	local local_c = { info.center[1] * s[1], info.center[2] * s[2], info.center[3] * s[3] }
	local c = V.add(MSV2.objPos(idx), M.apply(R, local_c))
	return { center = c, ext = { info.ext[1] * s[1], info.ext[2] * s[2], info.ext[3] * s[3] }, R = R, info = info, scale = s }
end

---Sets the model scale (the object's size) and moves the object so the model's centre stays where it is
function MSV2.setModelScale(list, k)
	MSV2.pushUndo("Model scale", "model:scale")
	local n = 0
	for _, idx in ipairs(list) do
		local m = MSV2.meta[idx]
		local o = MSV2.objs[idx]
		if (m and m.useModel and m.modelName and o and o.type == 1) then
			local info = MSV2.objInfo(m.modelName)
			local before = info.center and MSV2.modelWorldBox(idx)
			MSV2.objSet(idx, "dims_x", k)
			MSV2.objSet(idx, "dims_y", k)
			MSV2.objSet(idx, "dims_z", k)
			if (before) then
				local after = MSV2.modelWorldBox(idx)
				if (after) then MSV2.setObjPos(idx, V.add(MSV2.objPos(idx), V.sub(before.center, after.center))) end
			end
			n = n + 1
		end
	end
	return n
end

---Adds an invisible static box exactly around the drawn model (parented to the object) - one undo step.
---The model is scaled by the object's own size, so the object's own box can't also be the model's hitbox
---unless the model is about 1 unit big (then nothing needs adding).
function MSV2.modelAddHitbox(idx)
	local box, why = MSV2.modelWorldBox(idx)
	if (not box) then MSV2.toast(why) return nil end
	local e, o = box.ext, MSV2.objs[idx]
	local info = box.info
	local unit = abs(info.ext[1] - 1) < 0.15 and abs(info.ext[2] - 1) < 0.15 and abs(info.ext[3] - 1) < 0.15
	if (unit) then
		MSV2.toast("This model is about 1 unit big, so the object's own box already fits it - just set the object's size")
		return nil
	end
	local newIdx
	MSV2.withUndo("Fit hitbox to model", function()
		local rx, ry, rz = M.toEuler(box.R)
		local f = {
			type = 1, pos_x = box.center[1], pos_y = box.center[2], pos_z = box.center[3],
			rot_x = rx, rot_y = ry, rot_z = rz,
			dims_x = max(0.01, e[1]), dims_y = max(0.01, e[2]), dims_z = max(0.01, e[3]),
			static = o.static, visible = false, color_r = 0.2, color_g = 0.8, color_b = 1, color_a = 0.3,
			friction = o.friction, bounce = o.bounce, hardness = o.hardness, mass = o.mass or 1
		}
		newIdx = MSV2.createObj(f, { name = MSV2.objName(idx) .. " hitbox" })
		if (newIdx) then
			local pk, ck = MSV2.nodeKey(idx), MSV2.nodeKey(newIdx)
			if (pk and ck and MSV2.setParent) then MSV2.setParent({ ck }, pk) end
		end
	end)
	if (newIdx) then
		MSV2.selSet(newIdx)
		MSV2.toast("Added an invisible hitbox " .. MSV2.fmt(e[1]) .. " x " .. MSV2.fmt(e[2]) .. " x " .. MSV2.fmt(e[3]) .. " around the model (child of the object)")
	end
	return newIdx
end

---------------------------------------------------------------------------
-- Export: write use_model / model_name into the .tbm, import: read them back
---------------------------------------------------------------------------

local function splitLines(text)
	local lines, pos = {}, 1
	local n = #text
	while (pos <= n) do
		local e = text:find("\n", pos, true)
		if (not e) then
			table.insert(lines, text:sub(pos))
			break
		end
		table.insert(lines, text:sub(pos, e - 1))
		pos = e + 1
	end
	return lines, text:sub(-1) == "\n"
end

local function tbmPath(written)
	written = tostring(written or ""):gsub("\\", "/")
	if (not written:lower():find("%.tbm$")) then written = written .. ".tbm" end
	return "data/mod/" .. written
end
MSV2.tbmPath = tbmPath

---The mod's path under data/mod without .tbm, as the game knows it ("modmaker/Name"). export_mod_maker's
---return value may or may not include the modmaker/ folder, so look for the file.
function MSV2.normExport(written)
	local w = tostring(written or ""):gsub("\\", "/"):gsub("%.[Tt][Bb][Mm]$", "")
	if (not MSV2.fileExists("data/mod/" .. w .. ".tbm") and MSV2.fileExists("data/mod/modmaker/" .. w .. ".tbm")) then
		w = "modmaker/" .. w
	end
	return w
end

---Adds use_model 1 / model_name to the env_obj blocks of an exported mod. Returns patched count, error text.
function MSV2.writeModelLines(written)
	local want = {}
	local total = 0
	for idx, m in pairs(MSV2.meta) do
		if (m.useModel and m.modelName and m.modelName ~= "" and MSV2.objs[idx]) then
			want[idx] = m
			total = total + 1
		end
	end
	if (total == 0) then return 0 end
	written = MSV2.normExport(written)
	local path = tbmPath(written)
	local text = MSV2.readBytes(path)
	if (not text) then return 0, "couldn't read " .. path end
	local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
	local lines, endsNl = splitLines(text)
	local base = MSV2.modBaseSegs(written)
	local out, cur, patched = {}, nil, 0
	local function closeBlock()
		if (cur) then
			table.insert(out, "   use_model 1")
			table.insert(out, "   model_name " .. MSV2.relativeModelName(cur.modelName, base))
			patched = patched + 1
			cur = nil
		end
	end
	for _, raw in ipairs(lines) do
		local line = raw:gsub("\r$", "")
		local n = line:match("^env_obj%s+(%d+)%s*$")
		if (n or line:match("^%S")) then
			closeBlock()
			if (n) then cur = want[tonumber(n)] end
			table.insert(out, line)
		elseif (cur and (line:match("^%s+use_model%s") or line:match("^%s+model_name%s"))) then
			-- replaced by the lines added at the end of the block
		else
			table.insert(out, line)
		end
	end
	closeBlock()
	local joined = table.concat(out, eol) .. (endsNl and eol or "")
	if (not MSV2.writeBytes(path, joined)) then return 0, "couldn't write " .. path end
	if (patched < total) then
		return patched, (total - patched) .. " model object(s) weren't found in the exported file"
	end
	return patched
end

---Reads use_model / model_name for every env_obj of a .tbm and stores them on the objects that were just imported
function MSV2.readModelLines(name)
	local text = MSV2.readBytes(tbmPath(name))
	if (not text) then return 0 end
	local base = MSV2.modBaseSegs(name)
	local blocks, cur = {}, nil
	for raw in text:gmatch("[^\n]+") do
		local line = raw:gsub("\r$", "")
		local n = line:match("^env_obj%s+(%d+)%s*$")
		if (n) then
			cur = { num = tonumber(n) }
			table.insert(blocks, cur)
		elseif (line:match("^%S")) then
			cur = nil
		elseif (cur) then
			local u = line:match("^%s+use_model%s+(%-?%d+)")
			if (u) then cur.use = tonumber(u) == 1 end
			local mn = line:match("^%s+model_name%s+(.-)%s*$")
			if (mn) then cur.name = mn end
		end
	end
	local indices = MSV2.sortedKeys(MSV2.objs)
	local byOrder = #indices == #blocks
	local found = 0
	for i, b in ipairs(blocks) do
		local idx = byOrder and indices[i] or (MSV2.objs[b.num] and b.num or nil)
		if (idx and b.use and b.name and not b.name:match("^env_obj%d*$")) then
			local canon = MSV2.resolveModelName(b.name, base) or b.name
			MSV2.meta[idx] = MSV2.meta[idx] or {}
			MSV2.meta[idx].useModel = true
			MSV2.meta[idx].modelName = canon
			found = found + 1
		end
	end
	return found
end

---------------------------------------------------------------------------
-- Asset report: everything the mod needs, problems, cached for a few seconds
---------------------------------------------------------------------------

MSV2.assetCache = MSV2.assetCache or nil

---{ order = { names }, users, infos, issues = { {severity,text,objs} }, files = { paths }, missing = { paths } }
function MSV2.assetReport(force)
	local users, order = MSV2.modelUsers()
	local key = {}
	for _, n in ipairs(order) do table.insert(key, n .. "#" .. #users[n]) end
	key = table.concat(key, "|") .. "|" .. (MSV2.settings.modelDepth or 2)
	local c = MSV2.assetCache
	if (c and not force and c.key == key and clock() - c.t < 6) then return c end
	local rep = { key = key, t = clock(), order = order, users = users, infos = {}, issues = {}, files = {}, missing = {} }
	local seenFile = {}
	local function add(sev, text, objs) table.insert(rep.issues, { severity = sev, text = text, objs = objs or {} }) end
	for _, name in ipairs(order) do
		local objs = users[name]
		local n = #objs
		if (name == "") then
			add("warn", "with \"Use a 3D model\" on but no model chosen (the game would look for a file called env_obj)", objs)
		else
			local bad = MSV2.modelNameProblem(name)
			if (bad) then
				add("warn", "with a model path that " .. bad .. ": \"" .. name .. "\"", objs)
			else
				local info = MSV2.objInfo(name, force)
				rep.infos[name] = info
				if (info.missing) then
					add("warn", "with a 3D model that isn't in data/mod_assets: " .. name .. ".obj. Players need that file too", objs)
					table.insert(rep.missing, info.path)
				else
					for _, f in ipairs(info.files) do
						if (not seenFile[f]) then seenFile[f] = true; table.insert(rep.files, f) end
					end
					if (info.textureMissing) then
						add("warn", "with model \"" .. name .. "\" whose .mtl names a texture that's missing: " .. (info.absent[1] or "?"), objs)
						for _, p in ipairs(info.absent) do table.insert(rep.missing, p) end
					elseif (info.hasUV and not info.hasTexture) then
						add("warn", "with model \"" .. name .. "\" which has no texture next to it (expected " .. name .. ".tga) - it will look plain", objs)
						table.insert(rep.missing, ROOT .. "/" .. name .. ".tga")
					end
					if (not info.ext) then
						add("warn", "with model \"" .. name .. "\" which has no vertices - nothing will be drawn", objs)
					end
				end
			end
		end
	end
	if (#order > 0) then
		local names = {}
		for _, n in ipairs(order) do if (n ~= "") then table.insert(names, n) end end
		if (#names > 0) then
			add("info", #names .. " 3D model" .. (#names == 1 and "" or "s") .. " used (" .. #rep.files .. " asset file" .. (#rep.files == 1 and "" or "s") .. "): " .. table.concat(names, ", ") ..
				". Players must have them in data/mod_assets/ - see the Assets section", {})
		end
	end
	MSV2.assetCache = rep
	return rep
end

---Issues for MSV2.checkMod
function MSV2.assetIssues(force)
	local ok, rep = pcall(MSV2.assetReport, force)
	if (ok and rep) then return rep.issues end
	return {}
end

---------------------------------------------------------------------------
-- Mod message note, manifest, asset pack
---------------------------------------------------------------------------

local NOTE_A = "This mod needs these assets: "
local NOTE_B = "Download the mod's 3D assets"

local function stripNote(msg)
	local a = msg:find(NOTE_A, 1, true)
	local b = msg:find(NOTE_B, 1, true)
	local cut = a and b and min(a, b) or a or b
	if (cut) then msg = msg:sub(1, cut - 1):gsub("%s+$", "") end
	return msg
end

---Adds (or replaces) an asset note at the end of the welcome message. kind: "list" or "download"
function MSV2.appendAssetNote(kind)
	local rep = MSV2.assetReport(true)
	if (#rep.order == 0) then MSV2.toast("No 3D models in use - nothing to mention") return false end
	local okm, msg = pcall(get_mod_message)
	msg = stripNote(okm and msg or "")
	local names = {}
	for _, n in ipairs(rep.order) do if (n ~= "") then table.insert(names, n) end end
	local note
	if (kind == "download") then
		note = NOTE_B .. " and put them in Toribash/data/mod_assets"
	else
		local shown = {}
		for i = 1, min(#names, 4) do table.insert(shown, names[i]) end
		note = NOTE_A .. table.concat(shown, ", ") .. (#names > 4 and (" +" .. (#names - 4) .. " more") or "") .. " (in data/mod_assets)"
	end
	pcall(set_mod_message, (msg ~= "" and (msg .. " ") or "") .. note)
	MSV2.changed = true
	MSV2.toast("Added an asset note to the welcome message")
	return true
end

function MSV2.removeAssetNote()
	local okm, msg = pcall(get_mod_message)
	if (not okm or not msg) then return end
	pcall(set_mod_message, stripNote(msg))
	MSV2.markDirty()
	MSV2.toast("Removed the asset note from the welcome message")
end

---Writes data/mod/<folder>/<Name>_assets.txt next to the exported mod. Returns path or nil, error.
function MSV2.writeManifest(written)
	local rep = MSV2.assetReport(true)
	if (#rep.order == 0) then return nil, "no models" end
	local w = MSV2.normExport(written)
	local base = MSV2.modBaseSegs(w)
	local path = "data/mod/" .. w .. "_assets.txt"
	local out = {
		"Mod Studio asset list for " .. w .. ".tbm",
		"",
		"Put these files in Toribash/data/mod_assets/ (keep the folders). Paths below are relative to that folder.",
		""
	}
	for _, f in ipairs(rep.files) do table.insert(out, (f:gsub("^" .. ROOT:gsub("%p", "%%%0") .. "/", ""))) end
	if (#rep.missing > 0) then
		table.insert(out, "")
		table.insert(out, "NOT FOUND on the machine that exported this mod (add them before sharing):")
		for _, f in ipairs(rep.missing) do table.insert(out, (f:gsub("^" .. ROOT:gsub("%p", "%%%0") .. "/", ""))) end
	end
	table.insert(out, "")
	table.insert(out, "Model paths as written in the .tbm (relative to data/mod_assets/" .. table.concat(base, "/") .. "/):")
	for _, name in ipairs(rep.order) do
		table.insert(out, "  " .. MSV2.relativeModelName(name, base) .. "   (" .. #rep.users[name] .. " object" .. (#rep.users[name] == 1 and "" or "s") .. ")")
	end
	table.insert(out, "")
	if (not MSV2.writeBytes(path, table.concat(out, "\r\n"))) then return nil, "couldn't write " .. path end
	return path
end

---Everything that happens after export_mod_maker succeeded. Returns a short text for the toast.
function MSV2.afterExport(written)
	local parts = {}
	local ok, patched, err = pcall(MSV2.writeModelLines, written)
	if (not ok) then
		err, patched = patched, 0
	end
	if (patched and patched > 0) then
		table.insert(parts, patched .. " model" .. (patched == 1 and "" or "s") .. " written")
	end
	if (err) then
		table.insert(parts, "model lines: " .. tostring(err))
		echo("Mod Studio: " .. tostring(err))
	end
	local okm, mp = pcall(MSV2.writeManifest, written)
	if (okm and mp) then
		table.insert(parts, "asset list saved")
	end
	return table.concat(parts, ", ")
end

---Copies the files of every used model into data/mod_assets/<folder>/ (never overwriting), then points the
---objects at the copies. Returns a list of report lines. The folder must already exist: Lua can't create folders.
function MSV2.makeAssetPack(folder)
	local rep = MSV2.assetReport(true)
	local log = {}
	local function say(s) table.insert(log, s) end
	if (#rep.order == 0) then say("No 3D models in use.") return log end
	folder = MSV2.safeName(folder or MSV2.saveName or "Untitled")
	local destDir = ROOT .. "/" .. folder
	local copied, skipped, failed = 0, 0, 0
	local moved = {}
	local abort = false
	for _, name in ipairs(rep.order) do
		local info = rep.infos[name]
		if (info and not info.missing and name ~= "" and not abort) then
			local ok = true
			local newName = folder .. "/" .. baseName(name)
			if (dirName(name) == folder) then
				say(name .. ": already in " .. folder .. "/")
				ok = false
			end
			if (ok) then
				local convert = true
				for _, src in ipairs(info.files) do
					local dst = destDir .. "/" .. baseName(src)
					local data = MSV2.readBytes(src)
					if (not data) then
						failed = failed + 1
						convert = false
						say("Couldn't read " .. src)
					else
						local existing = MSV2.readBytes(dst)
						if (existing) then
							skipped = skipped + 1
							if (existing ~= data) then
								convert = false
								say("Skipped " .. baseName(src) .. ": a different file with that name is already in " .. folder .. "/ (not overwritten)")
							else
								say("Skipped " .. baseName(src) .. ": already there")
							end
						elseif (MSV2.writeBytes(dst, data)) then
							copied = copied + 1
						else
							failed = failed + 1
							convert = false
							say("Couldn't write " .. dst .. " - create the folder data/mod_assets/" .. folder .. " first (Lua can't make folders), then try again")
							abort = true
							break
						end
					end
				end
				if (convert) then moved[name] = newName end
			end
		end
	end
	if (next(moved)) then
		MSV2.withUndo("Make asset pack", function()
			for old, new in pairs(moved) do
				MSV2.setObjModels(rep.users[old], nil, new)
			end
		end)
		for old, new in pairs(moved) do say("Now using " .. new .. " (was " .. old .. ")") end
	end
	MSV2.unloadModels()
	MSV2.assetCache = nil
	MSV2.lastPackMoved = MSV2.count(moved)
	table.insert(log, 1, copied .. " file" .. (copied == 1 and "" or "s") .. " copied, " .. skipped .. " skipped (already exist), " .. failed .. " failed")
	return log
end

---True when the game's Lua can read and write binary files (desktop io.open); mobile builds only get the list
function MSV2.canBinaryCopy()
	if (is_mobile) then
		local ok, m = pcall(is_mobile)
		if (ok and m) then return false end
	end
	return io ~= nil and io.open ~= nil
end

function MSV2.openAssetsFolder()
	if (open_file_location) then
		if (pcall(open_file_location, ROOT)) then return true end
	end
	MSV2.toast("Open the folder Toribash/data/mod_assets yourself")
	return false
end
