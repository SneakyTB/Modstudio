-- Mod Studio: core data layer
-- Wraps the native mod maker API (get_mod_envobj/set_mod_envobj/...) with a
-- Lua-side cache, selection, undo/redo, triangles, generators and project files.

MSV2 = MSV2 or {}
local MSV2 = MSV2

MSV2.VERSION = "1.0"
MSV2.HOOK = "modstudiov2"

local clock = os.clock_real or os.clock
MSV2.clock = clock

local sin, cos, atan2, asin, sqrt, abs, floor = math.sin, math.cos, math.atan2, math.asin, math.sqrt, math.abs, math.floor
local rad, deg = math.rad, math.deg

---------------------------------------------------------------------------
-- Generic helpers
---------------------------------------------------------------------------

function MSV2.deepcopy(v)
	if (type(v) ~= "table") then
		return v
	end
	local t = {}
	for k, val in pairs(v) do
		t[k] = MSV2.deepcopy(val)
	end
	return t
end

function MSV2.clamp(v, lo, hi)
	if (v < lo) then return lo end
	if (v > hi) then return hi end
	return v
end

function MSV2.round(v, step)
	step = step or 1
	if (step <= 0) then return v end
	return floor(v / step + 0.5) * step
end

function MSV2.fmt(v)
	if (type(v) ~= "number") then
		return tostring(v or "")
	end
	local s = string.format("%.3f", v)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	if (s == "-0") then s = "0" end
	return s
end

function MSV2.count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function MSV2.sortedKeys(t)
	local keys = {}
	for k in pairs(t or {}) do table.insert(keys, k) end
	table.sort(keys)
	return keys
end

---Serializes plain Lua data (numbers, strings, booleans, tables)
function MSV2.serialize(v)
	local t = type(v)
	if (t == "number") then
		if (v ~= v or v == math.huge or v == -math.huge) then return "0" end
		return string.format("%.7g", v)
	elseif (t == "boolean") then
		return tostring(v)
	elseif (t == "string") then
		return string.format("%q", v)
	elseif (t == "table") then
		local parts = {}
		for k, val in pairs(v) do
			local key
			if (type(k) == "number") then
				key = "[" .. MSV2.serialize(k) .. "]"
			else
				key = "[" .. string.format("%q", tostring(k)) .. "]"
			end
			table.insert(parts, key .. "=" .. MSV2.serialize(val))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

function MSV2.writeFile(path, content)
	local f = io.open(path, "w")
	if (not f) then
		return false
	end
	f:write(content)
	f:close()
	return true
end

function MSV2.readData(path)
	local f = io.open(path, "r")
	if (not f) then
		return nil
	end
	local s = f:read("*a")
	f:close()
	local fn = loadstring(s)
	if (not fn) then
		return nil
	end
	setfenv(fn, {})
	local ok, data = pcall(fn)
	if (ok and type(data) == "table") then
		return data
	end
	return nil
end

---------------------------------------------------------------------------
-- Settings (persisted to data/script/modstudiov2/settingsv2.cfg)
---------------------------------------------------------------------------

MSV2.SETTINGS_FILE = "modstudiov2/settingsv2.cfg"
MSV2.PROJECT_DIR = "modstudiov2/projectsv2/"

MSV2.DEFAULT_SETTINGS = {
	tool = "move",          -- select / move / rotate / scale
	space = "world",        -- world / local
	snap = true,
	gridStep = 0.25,
	rotStep = 15,
	scaleStep = 0.05,
	showGrid = true,
	gridExtent = 50,
	gridFix = 0,            -- settings migrations done for the grid
	showLabels = false,
	showLinks = true,
	gizmoSize = 95,
	newStatic = true,
	autosave = true,
	autosaveMinutes = 1,    -- how often autosave runs (when something changed)
	rotConvention = 1,      -- 1: Rz*Ry*Rx (Toribash default), 2: transposed
	rotUnit = "deg",        -- units of rot_* in the engine API ("deg" / "rad"), measured by MSV2.calibrate
	sizeScale = 1,          -- engine dims per unit of full size, measured by MSV2.calibrate
	camMethod = "hook",     -- how to move the camera from a script: hook / native / hold
	camMethodOk = true,     -- true once camMethod is known to move the camera (hook confirmed in game)
	camFix = 0,             -- settings migration marker for the camera method
	objLimit = 0,           -- max env objects the game allows (0 = not measured yet)
	surfaceSnap = true,     -- unused: object drags now hold the object at a fixed camera distance
	showDojo = true,        -- draw the dojo outline on the floor
	modelPreview = true,    -- draw each object's 3D model (use_model) in the editor
	modelDepth = 2,         -- folders between data/mod_assets and the exported mod: 2 = modmaker/<name>, 1 = data/mod/<name>
	assetNote = false,      -- add "This mod needs these assets" to the welcome message on export
	symmetry = false,       -- mirror body/joint edits to the other side
	bodyGizmo = true,
	moveChildren = true,    -- moving a parent moves its children
	showHierarchy = true,   -- parent lines for the selection
	showAllHierarchy = false,
	scrollPush = true,      -- wheel pushes a click-dragged object along the view line (off: wheel zooms)
	altDuplicate = true,    -- Alt + gizmo drag drags out a copy
	layout = {},            -- moved / resized panels: side -> { x, y, w, h }
	dockSizes = {},         -- v2: dragged panel sizes: left / right width, bottom height
	dockState = nil,        -- v2: which tabs are open: side -> { active, open }
	uiScale = 1,            -- 0.85 / 1 / 1.15 / 1.3
	accent = "pink",        -- highlight color (see UI.ACCENTS)
	accentCustom = { 0.9, 0.62, 0.62 },
	theme = "toribash",     -- main panel colour (see UI.THEMES)
	themeCustom = { 0.4, 0.4, 0.45 },
	squareCorners = false,
	panelOpacity = 1,       -- 0.3 .. 1, panel bodies only
	selColor = "cyan",      -- 3D view highlight colours (see MSV2.VIEW_COLORS)
	primaryColor = "gold",
	hoverColor = "yellow",
	hoverOutline = "white",
	outlineWidth = 1.5,
	gizmoWidth = 1,
	folded = { ["obj:thrust"] = true, ["obj:trigger"] = true, ["players:thrust"] = true, ["players:trigger"] = true,
		["players:tools"] = true, ["joints:trigger"] = true, ["joints:tools"] = true },
	firstRun = true,
	panelX = nil,
	panelY = nil
}

function MSV2.loadSettings()
	local s = MSV2.DEFAULT_SETTINGS
	MSV2.settings = MSV2.deepcopy(s)
	local saved = MSV2.readData(MSV2.SETTINGS_FILE)
	if (saved) then
		for k, v in pairs(saved) do
			if (MSV2.settings[k] ~= nil or k == "panelX" or k == "panelY") then
				MSV2.settings[k] = v
			end
		end
	end
	-- Earlier builds could wrongly switch away from the camera hook at the zoom limit
	if ((tonumber(MSV2.settings.camFix) or 0) < 2) then
		MSV2.settings.camMethod = "hook"
		MSV2.settings.camMethodOk = true
	end
	-- A test build briefly turned scroll push off: put it back on
	if ((tonumber(MSV2.settings.camFix) or 0) < 4) then
		MSV2.settings.scrollPush = true
		MSV2.settings.camFix = 4
	end
	-- The grid used to default to 16: move anyone still on the old default to the bigger grid
	if ((tonumber(MSV2.settings.gridFix) or 0) < 1) then
		if ((tonumber(MSV2.settings.gridExtent) or 16) == 16) then MSV2.settings.gridExtent = 50 end
		MSV2.settings.gridFix = 1
	end
end

function MSV2.saveSettings()
	MSV2.writeFile(MSV2.SETTINGS_FILE, "return " .. MSV2.serialize(MSV2.settings))
end

---------------------------------------------------------------------------
-- Vector / matrix math (vectors are {x, y, z}, matrices are 3x3 m[row][col])
---------------------------------------------------------------------------

local V = {}
MSV2.V = V

function V.new(x, y, z) return { x or 0, y or 0, z or 0 } end
function V.copy(a) return { a[1], a[2], a[3] } end
function V.add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
function V.sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
function V.mul(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
function V.dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
function V.cross(a, b)
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
function V.len(a) return sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end
function V.norm(a)
	local l = V.len(a)
	if (l < 1e-9) then return { 0, 0, 0 } end
	return { a[1] / l, a[2] / l, a[3] / l }
end
function V.dist(a, b) return V.len(V.sub(a, b)) end
function V.lerp(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end

local M = {}
MSV2.M = M

function M.identity() return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end

function M.mul(a, b)
	local r = { {}, {}, {} }
	for i = 1, 3 do
		for j = 1, 3 do
			r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		end
	end
	return r
end

function M.transpose(a)
	return {
		{ a[1][1], a[2][1], a[3][1] },
		{ a[1][2], a[2][2], a[3][2] },
		{ a[1][3], a[2][3], a[3][3] }
	}
end

function M.apply(m, v)
	return {
		m[1][1] * v[1] + m[1][2] * v[2] + m[1][3] * v[3],
		m[2][1] * v[1] + m[2][2] * v[2] + m[2][3] * v[3],
		m[3][1] * v[1] + m[3][2] * v[2] + m[3][3] * v[3]
	}
end

---Column j of the matrix = local axis j in world space
function M.col(m, j) return { m[1][j], m[2][j], m[3][j] } end

function M.fromCols(a, b, c)
	return {
		{ a[1], b[1], c[1] },
		{ a[2], b[2], c[2] },
		{ a[3], b[3], c[3] }
	}
end

---R = Rz * Ry * Rx (angles in degrees) - matches Utils3D.GetEulerFromMatrixTB
local function eulerZYX(x, y, z)
	x, y, z = rad(x), rad(y), rad(z)
	local cx, sx, cy, sy, cz, sz = cos(x), sin(x), cos(y), sin(y), cos(z), sin(z)
	return {
		{ cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
		{ sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
		{ -sy, cy * sx, cy * cx }
	}
end

local function matToZYX(R)
	local r31 = MSV2.clamp(R[3][1], -1, 1)
	local y = asin(-r31)
	local x, z
	if (abs(R[3][1]) < 0.99999) then
		x = atan2(R[3][2], R[3][3])
		z = atan2(R[2][1], R[1][1])
	else
		x = 0
		z = atan2(-R[1][2], R[2][2])
	end
	return deg(x), deg(y), deg(z)
end

---Euler (degrees, as stored in rot_x/y/z) to rotation matrix
function M.fromEuler(x, y, z)
	local R = eulerZYX(x or 0, y or 0, z or 0)
	if (MSV2.settings and MSV2.settings.rotConvention == 2) then
		return M.transpose(R)
	end
	return R
end

---Rotation matrix to euler (degrees), inverse of M.fromEuler
function M.toEuler(R)
	if (MSV2.settings and MSV2.settings.rotConvention == 2) then
		R = M.transpose(R)
	end
	local x, y, z = matToZYX(R)
	local function clean(a)
		a = MSV2.round(a, 0.001)
		if (a == -0) then a = 0 end
		return a
	end
	return clean(x), clean(y), clean(z)
end

---Rotation of `angle` degrees around a unit axis (Rodrigues)
function M.axisAngle(axis, angle)
	local a = V.norm(axis)
	local t = rad(angle)
	local c, s = cos(t), sin(t)
	local C = 1 - c
	local x, y, z = a[1], a[2], a[3]
	return {
		{ c + x * x * C, x * y * C - z * s, x * z * C + y * s },
		{ y * x * C + z * s, c + y * y * C, y * z * C - x * s },
		{ z * x * C - y * s, z * y * C + x * s, c + z * z * C }
	}
end

---Mirror a rotation across the plane perpendicular to world axis k
function M.mirror(R, k)
	local S = M.identity()
	S[k][k] = -1
	return M.mul(M.mul(S, R), S)
end

---------------------------------------------------------------------------
-- Native API field definitions
---------------------------------------------------------------------------

MSV2.SHAPES = { [0] = "Sphere", [1] = "Box", [2] = "Cylinder" }

MSV2.TRIG_FIELDS = { "trig_id", "trig_mask", "trig_action", "trig_sound", "trig_color_r", "trig_color_g", "trig_color_b", "trig_color_a", "trig_score", "trig_scoreonce" }

MSV2.ENV_FIELDS = {
	"type", "pos_x", "pos_y", "pos_z", "rot_x", "rot_y", "rot_z", "dims_x", "dims_y", "dims_z", "mass",
	"color_r", "color_g", "color_b", "color_a", "visible", "static", "force_x", "force_y", "force_z",
	"hardness", "friction", "bounce", "thrust_frames", "thrust_x", "thrust_y", "thrust_z", "thrust_relative"
}
for _, f in ipairs(MSV2.TRIG_FIELDS) do table.insert(MSV2.ENV_FIELDS, f) end

MSV2.BODY_FIELDS = {
	"type", "pos_x", "pos_y", "pos_z", "rot_x", "rot_y", "rot_z", "sides_x", "sides_y", "sides_z",
	"altsides_x", "altsides_y", "altsides_z", "force_x", "force_y", "force_z",
	"density", "hardness", "friction", "bounce", "thrust_frames", "thrust_x", "thrust_y", "thrust_z", "thrust_relative"
}
for _, f in ipairs(MSV2.TRIG_FIELDS) do table.insert(MSV2.BODY_FIELDS, f) end

MSV2.JOINT_FIELDS = {
	"pos_x", "pos_y", "pos_z", "axis_x", "axis_y", "axis_z", "histop", "lostop", "maxforce", "maxvelocity",
	"radius", "density", "hardness", "friction", "bounce"
}
for _, f in ipairs(MSV2.TRIG_FIELDS) do table.insert(MSV2.JOINT_FIELDS, f) end

MSV2.EJ_FIELDS = {
	"obj1", "obj2", "type", "pos_x", "pos_y", "pos_z", "axis_x", "axis_y", "axis_z",
	"histop", "lostop", "maxforce", "maxvelocity", "hardness", "bounce", "visible"
}

MSV2.BOOL_FIELDS = { visible = true, static = true, thrust_relative = true, trig_scoreonce = true }

MSV2.BODY_NAMES = {
	[0] = "Head", "Breast", "Chest", "Stomach", "Thorax",
	"R Pecs", "R Biceps", "R Triceps", "L Pecs", "L Biceps", "L Triceps",
	"R Hand", "L Hand", "R Butt", "L Butt",
	"R Thigh", "L Thigh", "L Leg", "R Leg", "R Foot", "L Foot"
}
MSV2.NUM_BODIES = 21

MSV2.JOINT_NAMES = {
	[0] = "Neck", "Chest", "Lumbar", "Abs",
	"R Pecs", "R Shoulder", "R Elbow",
	"L Pecs", "L Shoulder", "L Elbow",
	"R Wrist", "L Wrist",
	"R Glute", "L Glute",
	"R Hip", "L Hip",
	"R Knee", "L Knee", "R Ankle", "L Ankle"
}
MSV2.NUM_JOINTS = 20

MSV2.BODY_MIRROR = { [5] = 8, [8] = 5, [6] = 9, [9] = 6, [7] = 10, [10] = 7, [11] = 12, [12] = 11,
	[13] = 14, [14] = 13, [15] = 16, [16] = 15, [17] = 18, [18] = 17, [19] = 20, [20] = 19 }
MSV2.JOINT_MIRROR = { [4] = 7, [7] = 4, [5] = 8, [8] = 5, [6] = 9, [9] = 6, [10] = 11, [11] = 10,
	[12] = 13, [13] = 12, [14] = 15, [15] = 14, [16] = 17, [17] = 16, [18] = 19, [19] = 18 }

-- Fields that failed to read in this client version; the UI hides them
MSV2.unsupported = MSV2.unsupported or { env = {}, body = {}, joint = {}, ej = {} }

local function normalize(field, v)
	if (MSV2.BOOL_FIELDS[field]) then
		return v == true or v == 1
	end
	return v
end

---------------------------------------------------------------------------
-- Engine units. Mod Studio always works in degrees and full box sizes; the
-- engine API may use radians / half sizes. MSV2.calibrate() measures which.
---------------------------------------------------------------------------

MSV2.ROT_FIELDS = { rot_x = true, rot_y = true, rot_z = true }
MSV2.SIZE_FIELDS = { dims_x = true, dims_y = true, dims_z = true, sides_x = true, sides_y = true, sides_z = true,
	altsides_x = true, altsides_y = true, altsides_z = true }

---Engine units per degree / per unit of full size
function MSV2.rotK() return (MSV2.settings and MSV2.settings.rotUnit == "rad") and (math.pi / 180) or 1 end
function MSV2.sizeK() return (MSV2.settings and MSV2.settings.sizeScale) or 1 end

local function fromEngine(f, v)
	if (type(v) ~= "number") then return v end
	if (MSV2.ROT_FIELDS[f]) then return v / MSV2.rotK() end
	if (MSV2.SIZE_FIELDS[f]) then return v / MSV2.sizeK() end
	return v
end

local function toEngine(f, v)
	if (type(v) ~= "number") then return v end
	if (MSV2.ROT_FIELDS[f]) then return v * MSV2.rotK() end
	if (MSV2.SIZE_FIELDS[f]) then return v * MSV2.sizeK() end
	return v
end
MSV2.toEngine, MSV2.fromEngine = toEngine, fromEngine

---------------------------------------------------------------------------
-- Cache + engine writes
---------------------------------------------------------------------------

MSV2.objs = MSV2.objs or {}      -- env object index -> field table
MSV2.ejs = MSV2.ejs or {}        -- env joint index -> field table
MSV2.bodies = MSV2.bodies or {}  -- [player][body] -> field table
MSV2.joints = MSV2.joints or {}  -- [player][joint] -> field table
MSV2.meta = MSV2.meta or {}      -- env object index -> { name, group, locked, tri, uid, parent }
MSV2.tris = MSV2.tris or {}      -- triangle id -> triangle definition
MSV2.nextTri = MSV2.nextTri or 1
MSV2.numPlayers = MSV2.numPlayers or 2

---Fields the game can show instantly on its live object (no world rebuild needed)
MSV2.LIVE_FIELDS = { pos_x = true, pos_y = true, pos_z = true, rot_x = true, rot_y = true, rot_z = true,
	dims_x = true, dims_y = true, dims_z = true, color_r = true, color_g = true, color_b = true, color_a = true }
MSV2.livePending = MSV2.livePending or {}
-- True while every change since the last rebuild can be shown live
if (MSV2.onlyLive == nil) then MSV2.onlyLive = true end

---Marks the world as needing a rebuild. `liveIdx` = the change was only to a
---live field of that object, so it can be shown right away (see MSV2.flush).
function MSV2.markDirty(liveIdx)
	MSV2.needRefresh = true
	MSV2.changed = true
	MSV2.changedSinceAutosave = true
	MSV2.lastEditClock = clock()
	if (liveIdx) then
		MSV2.livePending[liveIdx] = true
	else
		MSV2.onlyLive = false
	end
end

---------------------------------------------------------------------------
-- Live object updates: the game keeps one live object per mod object. Moving
-- that directly (set_obj_pos etc.) is instant, unlike a full world rebuild,
-- so drags stay smooth; the proper rebuild runs once editing pauses.
---------------------------------------------------------------------------

MSV2.worldIdx = MSV2.worldIdx or {}
MSV2.worldMapDirty = true

local function worldPosMatches(i, o)
	local ok, x, y, z = pcall(get_obj_pos, i)
	return ok and type(x) == "number" and math.abs(x - (o.pos_x or 0)) < 1e-3
		and math.abs(y - (o.pos_y or 0)) < 1e-3 and math.abs(z - (o.pos_z or 0)) < 1e-3
end

---Works out which game object shows which mod object, by position
function MSV2.rebuildWorldMap()
	MSV2.worldMapDirty = false
	local list = MSV2.activeObjIndices()
	local map = {}
	-- Usually the n-th game object is the n-th mod object
	local inOrder = true
	for k, idx in ipairs(list) do
		local o = MSV2.objs[idx]
		if (o and worldPosMatches(k - 1, o)) then
			map[idx] = k - 1
		else
			inOrder = false
			break
		end
	end
	if (not inOrder) then
		-- Match by position + size. Objects that still look identical to another
		-- (e.g. pasted in place) are left unmapped and just use normal rebuilds,
		-- so a drag can never move the wrong object.
		map = {}
		local function sidesMatch(i, o)
			local ok, a, b, c = pcall(get_obj_sides, i)
			if (not ok or type(a) ~= "number") then return true end
			local e = { o.dims_x or 0, o.dims_y or 0, o.dims_z or 0 }
			if (o.type == 0) then return math.abs(a - e[1]) < 1e-3 end
			if (o.type == 2) then return math.abs(a - e[1]) < 1e-3 and math.abs((b or 0) - e[2]) < 1e-3 end
			return math.abs(a - e[1]) < 1e-3 and math.abs((b or 0) - e[2]) < 1e-3 and math.abs((c or 0) - e[3]) < 1e-3
		end
		local candidates, claimed = {}, {}
		for _, idx in ipairs(list) do
			local o = MSV2.objs[idx]
			candidates[idx] = {}
			if (o) then
				for i = 0, #list + 8 do
					if (worldPosMatches(i, o) and sidesMatch(i, o)) then
						table.insert(candidates[idx], i)
						claimed[i] = (claimed[i] or 0) + 1
					end
				end
			end
		end
		for idx, cands in pairs(candidates) do
			if (#cands == 1 and claimed[cands[1]] == 1) then map[idx] = cands[1] end
		end
	end
	MSV2.worldIdx = map
end

---Called every frame: maps objects once a rebuild has settled (cache == world)
function MSV2.tickWorldMap()
	if (MSV2.worldMapDirty and not MSV2.needRefresh) then
		pcall(MSV2.rebuildWorldMap)
	end
end

---Pushes an object's cached position / rotation / size / color to its live game object
local function liveObj(idx)
	local w, o = MSV2.worldIdx[idx], MSV2.objs[idx]
	if (not w or not o) then return false end
	if (not pcall(set_obj_pos, w, o.pos_x or 0, o.pos_y or 0, o.pos_z or 0)) then return false end
	local R = M.fromEuler(o.rot_x, o.rot_y, o.rot_z)
	local t = { r0 = R[1][1], r1 = R[1][2], r2 = R[1][3], r3 = 0, r4 = R[2][1], r5 = R[2][2], r6 = R[2][3], r7 = 0,
		r8 = R[3][1], r9 = R[3][2], r10 = R[3][3], r11 = 0, r12 = 0, r13 = 0, r14 = 0, r15 = 1 }
	for n = 0, 15 do t[n + 1] = t["r" .. n] end
	if (not pcall(set_obj_rot_m, w, t)) then
		if (not pcall(set_obj_rot, w, toEngine("rot_x", o.rot_x or 0), toEngine("rot_y", o.rot_y or 0), toEngine("rot_z", o.rot_z or 0))) then
			return false
		end
	end
	local ok
	if (o.type == 0) then
		ok = pcall(set_obj_sides, w, o.dims_x or 0.5)
	elseif (o.type == 2) then
		ok = pcall(set_obj_sides, w, o.dims_x or 0.3, o.dims_y or 1)
	else
		ok = pcall(set_obj_sides, w, o.dims_x or 1, o.dims_y or 1, o.dims_z or 1)
	end
	if (not ok) then return false end
	pcall(set_obj_color, w, o.color_r or 1, o.color_g or 1, o.color_b or 1, o.color_a or 1)
	return true
end
MSV2.liveObj = liveObj

---How long a world rebuild takes (smoothed, seconds) - see MSV2.flush
MSV2.refreshCost = MSV2.refreshCost or 0
MSV2.lastRefresh = MSV2.lastRefresh or 0

---Gap to leave between world rebuilds while editing. Cheap rebuilds aren't
---held back at all; slow ones (big mods) run at most ~every 3x their cost.
function MSV2.refreshInterval()
	local cost = MSV2.refreshCost or 0
	if (cost < 0.004) then return 0 end
	return MSV2.clamp(cost * 3, 0.016, 0.25)
end

---Rebuilds the mod maker world if anything changed. The game rebuilds every
---object and player each time, which is what made editing laggy, so repeated
---changes (scrubbing, typing, dragging) are batched unless `force` is set.
function MSV2.flush(force)
	if (not MSV2.needRefresh) then return end
	local now = clock()
	if (not force) then
		-- Only moves / resizes / recolors so far: show them on the live objects now
		-- and hold the full rebuild until editing pauses (keeps drags smooth)
		if (MSV2.onlyLive and not MSV2.worldMapDirty) then
			for idx in pairs(MSV2.livePending) do
				if (not liveObj(idx)) then MSV2.liveFailed = true end
			end
			MSV2.livePending = {}
			local busy = (MSV2.G and MSV2.G.drag) or now - (MSV2.lastEditClock or 0) < 0.4
			if (busy and not MSV2.liveFailed) then return end
		end
		if (now - (MSV2.lastRefresh or 0) < MSV2.refreshInterval()) then
			return
		end
	end
	MSV2.needRefresh = false
	pcall(refresh_mod_maker_world)
	local after = clock()
	local took = math.max(0, after - now)
	-- Smooth so one slow frame doesn't throttle everything
	MSV2.refreshCost = (MSV2.refreshCost or 0) * 0.7 + took * 0.3
	MSV2.lastRefresh = after
	-- The rebuild may renumber the game's objects: map them again next frame
	MSV2.livePending, MSV2.onlyLive, MSV2.liveFailed = {}, true, false
	MSV2.worldMapDirty = true
end

function MSV2.readObj(idx)
	local o = {}
	for _, f in ipairs(MSV2.ENV_FIELDS) do
		if (not MSV2.unsupported.env[f]) then
			local ok, v = pcall(get_mod_envobj, idx, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, fromEngine(f, v))
			elseif (not ok) then
				MSV2.unsupported.env[f] = true
			end
		end
	end
	o.type = o.type or 1
	MSV2.objs[idx] = o
	return o
end

function MSV2.readEJ(idx)
	local o = {}
	for _, f in ipairs(MSV2.EJ_FIELDS) do
		if (not MSV2.unsupported.ej[f]) then
			local ok, v = pcall(get_mod_envjoint, idx, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, v)
			elseif (not ok) then
				MSV2.unsupported.ej[f] = true
			end
		end
	end
	MSV2.ejs[idx] = o
	return o
end

function MSV2.readBody(p, b)
	local o = {}
	for _, f in ipairs(MSV2.BODY_FIELDS) do
		if (not MSV2.unsupported.body[f]) then
			local ok, v = pcall(get_mod_body, p, b, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, fromEngine(f, v))
			elseif (not ok) then
				if (tostring(v):find("player index")) then
					return nil
				end
				MSV2.unsupported.body[f] = true
			end
		end
	end
	MSV2.bodies[p] = MSV2.bodies[p] or {}
	MSV2.bodies[p][b] = o
	return o
end

function MSV2.readJoint(p, j)
	local o = {}
	for _, f in ipairs(MSV2.JOINT_FIELDS) do
		if (not MSV2.unsupported.joint[f]) then
			local ok, v = pcall(get_mod_joint, p, j, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, v)
			elseif (not ok) then
				if (tostring(v):find("player index")) then
					return nil
				end
				MSV2.unsupported.joint[f] = true
			end
		end
	end
	MSV2.joints[p] = MSV2.joints[p] or {}
	MSV2.joints[p][j] = o
	return o
end

local function activeList(fn)
	local list = {}
	local ok, t = pcall(fn)
	if (ok and type(t) == "table") then
		for _, idx in pairs(t) do
			table.insert(list, idx)
		end
	end
	table.sort(list)
	return list
end

function MSV2.activeObjIndices() return activeList(get_active_mod_envobjs) end
function MSV2.activeEJIndices() return activeList(get_active_mod_envjoints) end

---Re-reads everything from the engine. Keeps metadata for indices that still exist.
function MSV2.reloadAll()
	local oldMeta = MSV2.meta or {}
	MSV2.objs, MSV2.ejs, MSV2.meta = {}, {}, {}
	for _, idx in ipairs(MSV2.activeObjIndices()) do
		MSV2.readObj(idx)
		MSV2.meta[idx] = oldMeta[idx] or {}
	end
	for _, idx in ipairs(MSV2.activeEJIndices()) do
		MSV2.readEJ(idx)
	end
	-- Drop triangles whose slices no longer exist
	for id, t in pairs(MSV2.tris) do
		local alive = {}
		for _, idx in ipairs(t.objs) do
			if (MSV2.objs[idx]) then
				table.insert(alive, idx)
				MSV2.meta[idx].tri = id
			end
		end
		t.objs = alive
		if (#alive == 0) then
			MSV2.tris[id] = nil
		end
	end
	MSV2.bodies, MSV2.joints = {}, {}
	MSV2.numPlayers = 0
	local okr, rule = pcall(get_gamerule, "numplayers")
	local maxPlayers = MSV2.clamp(okr and tonumber(rule) or 2, 2, 4)
	for p = 0, maxPlayers - 1 do
		if (MSV2.readBody(p, 0) == nil) then
			break
		end
		for b = 1, MSV2.NUM_BODIES - 1 do MSV2.readBody(p, b) end
		for j = 0, MSV2.NUM_JOINTS - 1 do MSV2.readJoint(p, j) end
		MSV2.numPlayers = p + 1
	end
	if (MSV2.hierFix) then MSV2.hierFix() end
	MSV2.selClear()
end

function MSV2.objSet(idx, f, v)
	local o = MSV2.objs[idx]
	if (not o or MSV2.unsupported.env[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_envobj, idx, f, toEngine(f, v))
	-- Keep triangle-wide properties in sync so rebuilds keep them
	local m = MSV2.meta[idx]
	if (m and m.tri and MSV2.tris[m.tri] and MSV2.TRI_PROPS[f]) then
		local t = MSV2.tris[m.tri]
		if (f == "mass") then
			t.props.mass = v * math.max(1, #t.objs)
		else
			t.props[f] = v
		end
	end
	MSV2.markDirty(MSV2.LIVE_FIELDS[f] and idx or nil)
end

function MSV2.ejSet(idx, f, v)
	local o = MSV2.ejs[idx]
	if (not o or MSV2.unsupported.ej[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_envjoint, idx, f, v)
	MSV2.markDirty()
end

function MSV2.bodySet(p, b, f, v)
	local o = MSV2.bodies[p] and MSV2.bodies[p][b]
	if (not o or MSV2.unsupported.body[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_body, p, b, f, toEngine(f, v))
	MSV2.markDirty()
end

function MSV2.jointSet(p, j, f, v)
	local o = MSV2.joints[p] and MSV2.joints[p][j]
	if (not o or MSV2.unsupported.joint[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_joint, p, j, f, v)
	MSV2.markDirty()
end

function MSV2.objPos(idx)
	local o = MSV2.objs[idx]
	return { o.pos_x or 0, o.pos_y or 0, o.pos_z or 0 }
end

function MSV2.objRot(idx)
	local o = MSV2.objs[idx]
	return M.fromEuler(o.rot_x, o.rot_y, o.rot_z)
end

function MSV2.setObjPos(idx, p)
	MSV2.objSet(idx, "pos_x", p[1])
	MSV2.objSet(idx, "pos_y", p[2])
	MSV2.objSet(idx, "pos_z", p[3])
end

function MSV2.setObjRot(idx, R)
	local x, y, z = M.toEuler(R)
	MSV2.objSet(idx, "rot_x", x)
	MSV2.objSet(idx, "rot_y", y)
	MSV2.objSet(idx, "rot_z", z)
end

---Full box extents of a shape in its local frame (used for outlines / floor drop)
function MSV2.shapeExtents(shape, dx, dy, dz)
	dx, dy, dz = dx or 0, dy or 0, dz or 0
	if (shape == 0) then
		return { dx * 2, dx * 2, dx * 2 }
	elseif (shape == 2) then
		return { dx * 2, dx * 2, dy + dx * 2 }
	end
	return { dx, dy, dz }
end

function MSV2.objExtents(idx)
	local o = MSV2.objs[idx]
	return MSV2.shapeExtents(o.type, o.dims_x, o.dims_y, o.dims_z)
end

---Lowest world Z of an object's oriented bounding box
function MSV2.objBottom(idx)
	local p = MSV2.objPos(idx)
	local R = MSV2.objRot(idx)
	local e = MSV2.objExtents(idx)
	if (MSV2.objs[idx].type == 0) then
		return p[3] - e[3] / 2
	end
	local h = abs(R[3][1]) * e[1] / 2 + abs(R[3][2]) * e[2] / 2 + abs(R[3][3]) * e[3] / 2
	return p[3] - h
end

function MSV2.objName(idx)
	local m = MSV2.meta[idx]
	if (m and m.name and m.name ~= "") then
		return m.name
	end
	local o = MSV2.objs[idx]
	if (m and m.tri) then
		return "Triangle " .. m.tri
	end
	return (MSV2.SHAPES[o and o.type or 1] or "Object") .. " " .. idx
end

---------------------------------------------------------------------------
-- Toasts / status
---------------------------------------------------------------------------

function MSV2.toast(msg)
	MSV2.toastMsg = msg
	MSV2.toastClock = clock()
end

---------------------------------------------------------------------------
-- Selection (env objects). Selecting a triangle slice selects the whole triangle.
---------------------------------------------------------------------------

MSV2.sel = MSV2.sel or {}
MSV2.primary = MSV2.primary or nil

local function selChanged()
	if (MSV2.UI and MSV2.UI.requestRefresh) then
		MSV2.UI.requestRefresh()
	end
end

function MSV2.selClear()
	MSV2.sel = {}
	MSV2.primary = nil
	MSV2.vertexSel = nil
	selChanged()
end

local function addWithTri(idx)
	local m = MSV2.meta[idx]
	if (m and m.tri and MSV2.tris[m.tri]) then
		for _, i in ipairs(MSV2.tris[m.tri].objs) do
			MSV2.sel[i] = true
		end
	else
		MSV2.sel[idx] = true
	end
end

function MSV2.selSet(idx)
	MSV2.sel = {}
	MSV2.vertexSel = nil
	if (idx and MSV2.objs[idx]) then
		addWithTri(idx)
		MSV2.primary = idx
	else
		MSV2.primary = nil
	end
	selChanged()
end

function MSV2.selAdd(idx)
	if (idx and MSV2.objs[idx]) then
		addWithTri(idx)
		MSV2.primary = idx
		selChanged()
	end
end

function MSV2.selToggle(idx)
	if (not idx or not MSV2.objs[idx]) then return end
	if (MSV2.sel[idx]) then
		local m = MSV2.meta[idx]
		if (m and m.tri and MSV2.tris[m.tri]) then
			for _, i in ipairs(MSV2.tris[m.tri].objs) do MSV2.sel[i] = nil end
		else
			MSV2.sel[idx] = nil
		end
		if (MSV2.primary == idx or not MSV2.sel[MSV2.primary or -1]) then
			MSV2.primary = MSV2.selList()[1]
		end
		selChanged()
	else
		MSV2.selAdd(idx)
	end
end

function MSV2.selAll()
	MSV2.sel = {}
	for idx in pairs(MSV2.objs) do
		if (not (MSV2.meta[idx] and MSV2.meta[idx].locked)) then
			MSV2.sel[idx] = true
			MSV2.primary = MSV2.primary or idx
		end
	end
	if (MSV2.primary and not MSV2.sel[MSV2.primary]) then
		MSV2.primary = MSV2.selList()[1]
	end
	selChanged()
end

function MSV2.selList()
	local list = {}
	for idx in pairs(MSV2.sel) do
		if (MSV2.objs[idx]) then
			table.insert(list, idx)
		else
			MSV2.sel[idx] = nil
		end
	end
	table.sort(list)
	return list
end

function MSV2.selCount()
	return #MSV2.selList()
end

---Selected triangles (set of ids) and plain (non-triangle) objects
function MSV2.selSplit()
	local tris, plain = {}, {}
	for _, idx in ipairs(MSV2.selList()) do
		local m = MSV2.meta[idx]
		if (m and m.tri and MSV2.tris[m.tri]) then
			tris[m.tri] = true
		else
			table.insert(plain, idx)
		end
	end
	return tris, plain
end

---The single selected triangle, if the selection is exactly one triangle
function MSV2.selSingleTri()
	local tris, plain = MSV2.selSplit()
	if (#plain > 0) then return nil end
	local id, n = nil, 0
	for t in pairs(tris) do id = t; n = n + 1 end
	if (n == 1) then return id end
	return nil
end

function MSV2.selCenter()
	local list = MSV2.selList()
	if (#list == 0) then return nil end
	local tris, plain = MSV2.selSplit()
	local sum, n = { 0, 0, 0 }, 0
	for _, idx in ipairs(plain) do
		sum = V.add(sum, MSV2.objPos(idx)); n = n + 1
	end
	for id in pairs(tris) do
		sum = V.add(sum, MSV2.triCentroid(id)); n = n + 1
	end
	return V.mul(sum, 1 / n)
end

---------------------------------------------------------------------------
-- Undo / redo (whole-scene snapshots, coalesced for typing)
---------------------------------------------------------------------------

MSV2.undoStack = MSV2.undoStack or {}
MSV2.redoStack = MSV2.redoStack or {}
MSV2.MAX_UNDO = 80

function MSV2.snapshot()
	return {
		objs = MSV2.deepcopy(MSV2.objs),
		ejs = MSV2.deepcopy(MSV2.ejs),
		meta = MSV2.deepcopy(MSV2.meta),
		tris = MSV2.deepcopy(MSV2.tris),
		bodies = MSV2.deepcopy(MSV2.bodies),
		joints = MSV2.deepcopy(MSV2.joints),
		rules = MSV2.readRules and MSV2.readRules() or nil,
		nextTri = MSV2.nextTri
	}
end

---Records the current state before a change. Calls with the same `key`
---within a short time are merged so typing a number is one undo step.
---Runs `fn` as a single undo step: everything it changes undoes in one Ctrl+Z
function MSV2.withUndo(label, fn)
	MSV2.pushUndo(label)
	local was = MSV2.undoSuppress
	MSV2.undoSuppress = true
	local ok, err = pcall(fn)
	MSV2.undoSuppress = was
	if (not ok) then
		echo("Mod Studio error: " .. tostring(err))
	end
	return ok
end

function MSV2.pushUndo(label, key)
	if (MSV2.undoSuppress) then return end
	local now = clock()
	if (key and MSV2.lastUndoKey == key and now - (MSV2.lastUndoTime or 0) < 1.5) then
		MSV2.lastUndoTime = now
		return
	end
	MSV2.lastUndoKey = key
	MSV2.lastUndoTime = now
	table.insert(MSV2.undoStack, { label = label or "Edit", snap = MSV2.snapshot() })
	if (#MSV2.undoStack > MSV2.MAX_UNDO) then
		table.remove(MSV2.undoStack, 1)
	end
	MSV2.redoStack = {}
end

local function sameKeys(a, b)
	for k in pairs(a) do if (b[k] == nil) then return false end end
	for k in pairs(b) do if (a[k] == nil) then return false end end
	return true
end

local function writeObjFields(idx, fields, skipSame)
	local cur = MSV2.objs[idx]
	if (fields.type ~= nil and (not skipSame or cur.type ~= fields.type)) then
		MSV2.objSet(idx, "type", fields.type)
	end
	for _, f in ipairs(MSV2.ENV_FIELDS) do
		local v = fields[f]
		if (f ~= "type" and v ~= nil and (not skipSame or cur[f] ~= v)) then
			MSV2.objSet(idx, f, v)
		end
	end
end
MSV2.writeObjFields = writeObjFields

local function writeEJFields(idx, fields, skipSame)
	local cur = MSV2.ejs[idx]
	for _, f in ipairs(MSV2.EJ_FIELDS) do
		local v = fields[f]
		if (v ~= nil and f ~= "obj1" and f ~= "obj2" and (not skipSame or cur[f] ~= v)) then
			MSV2.ejSet(idx, f, v)
		end
	end
end

---True if the game still has every object in the cache
local function engineHasAll()
	local active = {}
	for _, idx in ipairs(MSV2.activeObjIndices()) do active[idx] = true end
	for idx in pairs(MSV2.objs) do
		if (not active[idx]) then return false end
	end
	return true
end

---Restores a snapshot. With `forceRecreate` (or when the game has lost objects)
---every object is rebuilt instead of only writing changed fields.
function MSV2.restore(s, forceRecreate)
	MSV2.endDragSilently()
	local map = {}
	local sameObjs = not forceRecreate and sameKeys(MSV2.objs, s.objs) and engineHasAll()
	if (sameObjs) then
		for idx, fields in pairs(s.objs) do
			writeObjFields(idx, fields, true)
			map[idx] = idx
		end
	else
		for idx in pairs(MSV2.ejs) do pcall(delete_mod_envjoint, idx) end
		MSV2.ejs = {}
		for idx in pairs(MSV2.objs) do pcall(delete_mod_envobj, idx) end
		MSV2.objs = {}
		for _, old in ipairs(MSV2.sortedKeys(s.objs)) do
			local ok, n = pcall(create_mod_envobj)
			if (ok and n ~= nil) then
				MSV2.readObj(n)
				writeObjFields(n, s.objs[old], false)
				map[old] = n
			end
		end
	end

	-- Env joints
	if (sameObjs and sameKeys(MSV2.ejs, s.ejs)) then
		for idx, fields in pairs(s.ejs) do
			local cur = MSV2.ejs[idx]
			if (cur.obj1 == fields.obj1 and cur.obj2 == fields.obj2) then
				writeEJFields(idx, fields, true)
			end
		end
	else
		for idx in pairs(MSV2.ejs) do pcall(delete_mod_envjoint, idx) end
		MSV2.ejs = {}
		for _, old in ipairs(MSV2.sortedKeys(s.ejs)) do
			local f = s.ejs[old]
			local o1, o2 = map[f.obj1], map[f.obj2]
			if (o1 and o2) then
				local ok, n = pcall(create_mod_envjoint, o1, o2)
				if (ok and n ~= nil) then
					MSV2.readEJ(n)
					writeEJFields(n, f, false)
				end
			end
		end
	end

	-- Metadata + triangles, remapped to new indices
	MSV2.meta = {}
	for old, m in pairs(s.meta) do
		if (map[old]) then MSV2.meta[map[old]] = MSV2.deepcopy(m) end
	end
	for idx in pairs(MSV2.objs) do MSV2.meta[idx] = MSV2.meta[idx] or {} end
	MSV2.tris = {}
	for id, t in pairs(s.tris) do
		local nt = MSV2.deepcopy(t)
		nt.objs = {}
		for _, old in ipairs(t.objs) do
			if (map[old]) then table.insert(nt.objs, map[old]) end
		end
		MSV2.tris[id] = nt
	end
	MSV2.nextTri = s.nextTri or MSV2.nextTri

	-- Players
	for p, parts in pairs(s.bodies or {}) do
		for b, fields in pairs(parts) do
			local cur = MSV2.bodies[p] and MSV2.bodies[p][b]
			if (cur) then
				for f, v in pairs(fields) do
					if (cur[f] ~= v) then MSV2.bodySet(p, b, f, v) end
				end
			end
		end
	end
	for p, parts in pairs(s.joints or {}) do
		for j, fields in pairs(parts) do
			local cur = MSV2.joints[p] and MSV2.joints[p][j]
			if (cur) then
				for f, v in pairs(fields) do
					if (cur[f] ~= v) then MSV2.jointSet(p, j, f, v) end
				end
			end
		end
	end

	local posBefore, rotBefore = MSV2.getRule("engageplayerpos"), MSV2.getRule("engageplayerrot")
	MSV2.applyRules(s.rules)
	for _, rn in ipairs({ "engageplayerpos", "engageplayerrot" }) do
		-- setRule also tracks values the engine doesn't echo back
		local want = s.rules and s.rules[rn]
		if (want ~= nil and tostring(want) ~= tostring(MSV2.getRule(rn))) then MSV2.setRule(rn, want) end
	end
	if (MSV2.hierFix) then MSV2.hierFix() end

	MSV2.markDirty()
	MSV2.selClear()
	-- Per-player start rules only take effect on a new match (undo / redo of a player move or turn)
	if (s.rules and (tostring(MSV2.getRule("engageplayerpos")) ~= tostring(posBefore)
		or tostring(MSV2.getRule("engageplayerrot")) ~= tostring(rotBefore))) then
		MSV2.faceFix = nil
		MSV2.restartMatch()
	end
end

---The game's mod maker can drop its objects on its own (seen when moving Tori's
---head). If objects Mod Studio knows about are gone from the game, rebuild them
---from the cache. Returns how many were missing.
function MSV2.repairEngine()
	local active = {}
	for _, idx in ipairs(MSV2.activeObjIndices()) do active[idx] = true end
	local missing = 0
	for idx in pairs(MSV2.objs) do
		if (not active[idx]) then missing = missing + 1 end
	end
	local ejMissing = 0
	local activeEJ = {}
	for _, idx in ipairs(MSV2.activeEJIndices()) do activeEJ[idx] = true end
	for idx in pairs(MSV2.ejs) do
		if (not activeEJ[idx]) then ejMissing = ejMissing + 1 end
	end
	if (missing == 0 and ejMissing == 0) then return 0 end
	MSV2.restore(MSV2.snapshot(), true)
	-- Whatever dropped the objects may have reloaded the players too: push ours back
	MSV2.pushPlayersToEngine()
	MSV2.flush(true)
	echo("Mod Studio: the game dropped " .. missing .. " object" .. (missing == 1 and "" or "s") ..
		(ejMissing > 0 and (" and " .. ejMissing .. " link" .. (ejMissing == 1 and "" or "s")) or "") ..
		" from the mod maker - rebuilt them from Mod Studio's copy.")
	MSV2.toast("Restored " .. missing .. " objects the game dropped")
	return missing
end

---Writes every cached body part / joint field to the game
function MSV2.pushPlayersToEngine()
	for p, parts in pairs(MSV2.bodies) do
		for b, fields in pairs(parts) do
			for f, v in pairs(fields) do
				if (not MSV2.unsupported.body[f]) then pcall(set_mod_body, p, b, f, toEngine(f, v)) end
			end
		end
	end
	for p, parts in pairs(MSV2.joints) do
		for j, fields in pairs(parts) do
			for f, v in pairs(fields) do
				if (not MSV2.unsupported.joint[f]) then pcall(set_mod_joint, p, j, f, toEngine(f, v)) end
			end
		end
	end
	MSV2.needRefresh = true
end

---Called every frame; checks the game still has everything about once a second
function MSV2.tickRepair()
	local now = clock()
	if (MSV2.G and MSV2.G.drag) then return end
	if (MSV2.lastRepairCheck and now - MSV2.lastRepairCheck < 1) then return end
	MSV2.lastRepairCheck = now
	pcall(MSV2.repairEngine)
end

function MSV2.undo()
	local e = table.remove(MSV2.undoStack)
	if (not e) then
		MSV2.toast("Nothing to undo")
		return
	end
	table.insert(MSV2.redoStack, { label = e.label, snap = MSV2.snapshot() })
	MSV2.restore(e.snap)
	MSV2.lastUndoKey = nil
	MSV2.toast("Undo: " .. e.label)
end

function MSV2.redo()
	local e = table.remove(MSV2.redoStack)
	if (not e) then
		MSV2.toast("Nothing to redo")
		return
	end
	table.insert(MSV2.undoStack, { label = e.label, snap = MSV2.snapshot() })
	MSV2.restore(e.snap)
	MSV2.lastUndoKey = nil
	MSV2.toast("Redo: " .. e.label)
end

---------------------------------------------------------------------------
-- Creating / deleting objects
---------------------------------------------------------------------------

MSV2.PALETTE = {
	{ 0.90, 0.30, 0.25 }, { 0.95, 0.60, 0.20 }, { 0.98, 0.85, 0.25 }, { 0.45, 0.80, 0.30 },
	{ 0.25, 0.70, 0.65 }, { 0.30, 0.55, 0.95 }, { 0.55, 0.40, 0.90 }, { 0.90, 0.45, 0.75 },
	{ 0.95, 0.95, 0.95 }, { 0.65, 0.65, 0.68 }, { 0.35, 0.35, 0.38 }, { 0.10, 0.10, 0.12 },
	{ 0.55, 0.35, 0.20 }, { 0.80, 0.70, 0.50 }, { 0.20, 0.35, 0.20 }, { 0.15, 0.20, 0.40 }
}
MSV2.paletteCursor = MSV2.paletteCursor or 0

function MSV2.nextColor()
	MSV2.paletteCursor = MSV2.paletteCursor % 8 + 1
	return MSV2.PALETTE[MSV2.paletteCursor]
end

---Ground point the camera is looking at, snapped to the grid
function MSV2.spawnPoint()
	if (MSV2.spawnOverride) then return V.copy(MSV2.spawnOverride) end
	local p = { 0, 0, 0 }
	local ok, cam = pcall(get_camera_info)
	if (ok and cam and cam.lookat) then
		p = { cam.lookat.x, cam.lookat.y, 0 }
	end
	local step = MSV2.settings.gridStep > 0 and MSV2.settings.gridStep or 0.25
	p[1] = MSV2.round(p[1], step)
	p[2] = MSV2.round(p[2], step)
	-- Nudge away from existing objects so new ones don't stack inside each other
	for _ = 1, 12 do
		local clash = false
		for idx in pairs(MSV2.objs) do
			local q = MSV2.objPos(idx)
			if (abs(q[1] - p[1]) < 0.3 and abs(q[2] - p[2]) < 0.3) then
				clash = true
				break
			end
		end
		if (not clash) then break end
		p[1] = p[1] + 1
	end
	return p
end

---The game refused a new object: whatever exists now is the limit
function MSV2.noteObjectLimit()
	local n = #MSV2.activeObjIndices()
	if (n > 0 and MSV2.settings.objLimit ~= n) then
		MSV2.settings.objLimit = n
		MSV2.saveSettings()
	end
	return n
end

---Finds the env object limit by creating placeholders until the game says no,
---then removes them. Returns the limit or nil.
function MSV2.measureObjectLimit()
	local made = {}
	local cap = 10000
	for _ = 1, cap do
		local ok, idx = pcall(create_mod_envobj)
		if (not ok or idx == nil) then break end
		table.insert(made, idx)
	end
	local limit = #MSV2.activeObjIndices()
	for _, idx in ipairs(made) do pcall(delete_mod_envobj, idx) end
	pcall(refresh_mod_maker_world)
	if (#made >= cap or limit == 0) then return nil end
	MSV2.settings.objLimit = limit
	MSV2.saveSettings()
	return limit
end

---Creates an env object. `fields` overrides defaults. Returns the index or nil.
function MSV2.createObj(fields, meta)
	local ok, idx = pcall(create_mod_envobj)
	if (not ok or idx == nil) then
		local n = MSV2.noteObjectLimit()
		MSV2.toast("The game won't allow more objects (limit " .. n .. "). Delete some or lower triangle Smoothness")
		return nil
	end
	MSV2.readObj(idx)
	MSV2.meta[idx] = meta or {}
	local defaults = {
		rot_x = 0, rot_y = 0, rot_z = 0,
		static = MSV2.settings.newStatic, visible = true, color_a = 1
	}
	for k, v in pairs(defaults) do
		if (fields[k] == nil) then fields[k] = v end
	end
	writeObjFields(idx, fields, false)
	MSV2.markDirty()
	local limit = MSV2.settings.objLimit or 0
	local n = MSV2.count(MSV2.objs)
	if (limit > 0 and n >= limit * 0.9 and (MSV2.lastLimitWarn or 0) < clock() - 20) then
		MSV2.lastLimitWarn = clock()
		MSV2.toast("Heads up: " .. n .. " of " .. limit .. " objects used (see the Stats tab)")
	end
	return idx
end

---Creates a primitive at the spawn point. kind: box/sphere/cylinder/floor/wall/pillar/platform/ball
function MSV2.addPrimitive(kind)
	MSV2.pushUndo("Add " .. kind)
	local p = MSV2.spawnPoint()
	local c = MSV2.nextColor()
	local f = { pos_x = p[1], pos_y = p[2], color_r = c[1], color_g = c[2], color_b = c[3], mass = 1 }
	local name
	if (kind == "sphere") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 0, 0.5, 0.5, 0.5, 0.5
	elseif (kind == "cylinder") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 2, 0.3, 1, 0.3, 0.8
	elseif (kind == "floor") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 1, 8, 8, 0.2, 0.1
		f.color_r, f.color_g, f.color_b = 0.65, 0.65, 0.68
		f.static = true
		name = "Floor"
	elseif (kind == "wall") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 1, 4, 0.3, 2, 1
		f.static = true
		name = "Wall"
	elseif (kind == "pillar") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 1, 0.5, 0.5, 3, 1.5
		f.static = true
		name = "Pillar"
	elseif (kind == "platform") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 1, 2, 2, 0.2, 1.5
		f.static = true
		name = "Platform"
	elseif (kind == "ball") then
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 0, 0.35, 0.35, 0.35, 2
		f.static = false
		f.mass = 0.5
		f.bounce = 0.6
		name = "Ball"
	else
		f.type, f.dims_x, f.dims_y, f.dims_z, f.pos_z = 1, 1, 1, 1, 0.5
	end
	local idx = MSV2.createObj(f, { name = name })
	if (idx) then
		MSV2.selSet(idx)
		MSV2.toast("Added " .. MSV2.objName(idx) .. " - drag the arrows to move it")
	end
	return idx
end

function MSV2.deleteObjRaw(idx)
	-- Remove links that reference this object first
	for j, ej in pairs(MSV2.ejs) do
		if (ej.obj1 == idx or ej.obj2 == idx) then
			pcall(delete_mod_envjoint, j)
			MSV2.ejs[j] = nil
		end
	end
	pcall(delete_mod_envobj, idx)
	MSV2.objs[idx] = nil
	local m = MSV2.meta[idx]
	MSV2.meta[idx] = nil
	if (m and m.tri and MSV2.tris[m.tri]) then
		local t = MSV2.tris[m.tri]
		for i = #t.objs, 1, -1 do
			if (t.objs[i] == idx) then table.remove(t.objs, i) end
		end
		if (#t.objs == 0) then MSV2.tris[m.tri] = nil end
	end
	MSV2.sel[idx] = nil
	MSV2.markDirty()
end

function MSV2.deleteSelected()
	local list = MSV2.selList()
	if (#list == 0) then
		MSV2.toast("Nothing selected")
		return
	end
	MSV2.pushUndo("Delete")
	-- Children of deleted objects stay, moving up to the nearest surviving parent
	local orphans = 0
	if (MSV2.hierBeforeDelete) then
		local set = MSV2.selKeys()
		local H = MSV2.hier()
		for k in pairs(set) do
			for _, c in ipairs(H.children[k] or {}) do
				if (not set[c]) then orphans = orphans + 1 end
			end
		end
		MSV2.hierBeforeDelete(set)
	end
	local tris = MSV2.selSplit()
	for id in pairs(tris) do MSV2.tris[id] = nil end
	for _, idx in ipairs(list) do
		if (MSV2.meta[idx]) then MSV2.meta[idx].tri = nil end
		MSV2.deleteObjRaw(idx)
	end
	if (MSV2.hierFix) then MSV2.hierFix() end
	MSV2.selClear()
	MSV2.toast("Deleted " .. #list .. " object" .. (#list == 1 and "" or "s") ..
		(orphans > 0 and (" - kept " .. orphans .. " child" .. (orphans == 1 and "" or "ren") .. " (use Delete branch to remove them too)") or ""))
end

---Copies selection into a clipboard table (objects + triangles)
function MSV2.copySelection()
	-- Copying a parent copies its children too
	local tris, plain = (MSV2.selSplitFamily or MSV2.selSplit)()
	if (#plain == 0 and next(tris) == nil) then
		MSV2.toast("Nothing selected to copy")
		return nil
	end
	local clip = { objs = {}, tris = {} }
	for _, idx in ipairs(plain) do
		table.insert(clip.objs, { fields = MSV2.deepcopy(MSV2.objs[idx]), meta = MSV2.deepcopy(MSV2.meta[idx]) })
	end
	for id in pairs(tris) do
		local t = MSV2.deepcopy(MSV2.tris[id])
		t.objs = {}
		table.insert(clip.tris, t)
	end
	return clip
end

---Pastes a clipboard with an offset. Returns the new selection list.
---Parent links inside the clip are kept between the copies; copies of top
---level items keep the original's parent. `keepUids` reuses the clip's ids
---(only when the originals were deleted first, e.g. mirror in place).
function MSV2.pasteClip(clip, offset, keepUids)
	if (not clip) then return {} end
	offset = offset or { 0, 0, 0 }
	local newSel = {}
	local remap = {}
	local function fresh(uid)
		if (uid == nil or keepUids) then return uid end
		remap[uid] = remap[uid] or MSV2.newUid()
		return remap[uid]
	end
	for _, item in ipairs(clip.objs) do
		if (item.meta and item.meta.uid) then fresh(item.meta.uid) end
	end
	for _, t in ipairs(clip.tris) do
		if (t.uid) then fresh(t.uid) end
	end
	local function relink(d)
		if (keepUids) then return end
		if (d.uid) then d.uid = remap[d.uid] end
		if (d.parent and remap[d.parent]) then d.parent = remap[d.parent] end
	end
	for _, item in ipairs(clip.objs) do
		local f = MSV2.deepcopy(item.fields)
		f.pos_x = (f.pos_x or 0) + offset[1]
		f.pos_y = (f.pos_y or 0) + offset[2]
		f.pos_z = (f.pos_z or 0) + offset[3]
		local m = MSV2.deepcopy(item.meta) or {}
		m.tri = nil
		relink(m)
		local idx = MSV2.createObj(f, m)
		if (idx) then table.insert(newSel, idx) end
	end
	for _, t in ipairs(clip.tris) do
		local id = MSV2.triCreate(V.add(t.a, offset), V.add(t.b, offset), V.add(t.c, offset), {
			thick = t.thick, slices = t.slices, smooth = t.smooth, props = MSV2.deepcopy(t.props), name = t.name
		})
		if (id) then
			local link = { uid = t.uid, parent = t.parent }
			relink(link)
			MSV2.tris[id].uid, MSV2.tris[id].parent = link.uid, link.parent
			for _, idx in ipairs(MSV2.tris[id].objs) do table.insert(newSel, idx) end
		end
	end
	if (MSV2.hierFix) then MSV2.hierFix() end
	MSV2.sel = {}
	for _, idx in ipairs(newSel) do MSV2.sel[idx] = true end
	MSV2.primary = newSel[1]
	selChanged()
	return newSel
end

function MSV2.selWidthX()
	local lo, hi = math.huge, -math.huge
	for _, idx in ipairs(MSV2.selList()) do
		local p = MSV2.objPos(idx)
		local e = MSV2.objExtents(idx)
		lo = math.min(lo, p[1] - e[1] / 2)
		hi = math.max(hi, p[1] + e[1] / 2)
	end
	if (lo > hi) then return 1 end
	return hi - lo
end

function MSV2.duplicateSelected()
	local clip = MSV2.copySelection()
	if (not clip) then return end
	MSV2.pushUndo("Duplicate")
	local step = MSV2.settings.gridStep > 0 and MSV2.settings.gridStep or 0.25
	local dx = MSV2.round(MSV2.selWidthX() + step, step)
	local list = MSV2.pasteClip(clip, { dx, 0, 0 })
	MSV2.toast("Duplicated " .. #list .. " object" .. (#list == 1 and "" or "s"))
end

---------------------------------------------------------------------------
-- Triangles: a triangle prism built from box slices so it exports as a
-- normal .tbm and collides correctly in-game (no script needed to play).
---------------------------------------------------------------------------

MSV2.TRI_PROPS = { color_r = true, color_g = true, color_b = true, color_a = true, mass = true, static = true,
	hardness = true, friction = true, bounce = true, visible = true }

function MSV2.triCentroid(id)
	local t = MSV2.tris[id]
	return V.mul(V.add(V.add(t.a, t.b), t.c), 1 / 3)
end

---Returns base start, base end, apex based on which edge should be perfectly flat
local function triBase(t)
	local a, b, c = t.a, t.b, t.c
	local edges = {
		ab = { a, b, c }, bc = { b, c, a }, ca = { c, a, b }
	}
	local mode = t.smooth or "longest"
	if (mode == "longest") then
		local best, bestLen = "ab", -1
		for k, e in pairs(edges) do
			local l = V.dist(e[1], e[2])
			if (l > bestLen) then best, bestLen = k, l end
		end
		mode = best
	end
	local e = edges[mode] or edges.ab
	return e[1], e[2], e[3]
end

---Computes slice transforms: list of { pos, R, dims }
function MSV2.triSlices(t)
	local p0, p1, q = triBase(t)
	local base = V.sub(p1, p0)
	local L = V.len(base)
	if (L < 1e-4) then return {} end
	local u = V.mul(base, 1 / L)
	local w = V.sub(q, p0)
	local tc = V.dot(w, u)
	local hvec = V.sub(w, V.mul(u, tc))
	local h = V.len(hvec)
	if (h < 1e-4) then return {} end
	local v = V.mul(hvec, 1 / h)
	local n = V.cross(u, v)
	local R = M.fromCols(u, v, n)
	local N = math.max(1, floor(t.slices or 10))
	local out = {}
	for k = 1, N do
		local sm = (k - 0.5) / N
		local cx = (L + sm * (2 * tc - L)) / 2
		local width = L * (1 - sm)
		local center = V.add(V.add(p0, V.mul(u, cx)), V.mul(v, sm * h))
		table.insert(out, { pos = center, R = R, dims = { math.max(0.01, width), math.max(0.01, h / N), math.max(0.01, t.thick or 0.2) } })
	end
	return out
end

---(Re)builds the env objects of a triangle to match its definition
function MSV2.triBuild(id)
	local t = MSV2.tris[id]
	if (not t) then return end
	local slices = MSV2.triSlices(t)
	local want = #slices
	-- Create / delete slices to match the wanted count
	while (#t.objs > want and #t.objs > 0) do
		local idx = table.remove(t.objs)
		if (MSV2.meta[idx]) then MSV2.meta[idx].tri = nil end
		MSV2.deleteObjRaw(idx)
	end
	local wasSelected = false
	for _, idx in ipairs(t.objs) do
		if (MSV2.sel[idx]) then wasSelected = true end
	end
	local created = false
	while (#t.objs < want) do
		local ok, idx = pcall(create_mod_envobj)
		if (not ok or idx == nil) then
			MSV2.noteObjectLimit()
			MSV2.toast("Object limit reached - lower the triangle's Smoothness")
			break
		end
		MSV2.readObj(idx)
		MSV2.meta[idx] = { tri = id }
		table.insert(t.objs, idx)
		created = true
	end
	local props = t.props
	-- Slices that only moved / resized can be shown live (see MSV2.flush)
	local nonLive, touched = false, {}
	for k, idx in ipairs(t.objs) do
		local s = slices[k]
		if (s) then
			local ex, ey, ez = M.toEuler(s.R)
			local f = {
				type = 1,
				pos_x = s.pos[1], pos_y = s.pos[2], pos_z = s.pos[3],
				rot_x = ex, rot_y = ey, rot_z = ez,
				dims_x = s.dims[1], dims_y = s.dims[2], dims_z = s.dims[3],
				color_r = props.color_r, color_g = props.color_g, color_b = props.color_b, color_a = props.color_a,
				static = props.static, visible = props.visible,
				hardness = props.hardness, friction = props.friction, bounce = props.bounce,
				mass = (props.mass or 1) / math.max(1, #t.objs)
			}
			-- Write without triggering the per-field triangle prop sync
			local o = MSV2.objs[idx]
			for _, fname in ipairs(MSV2.ENV_FIELDS) do
				local v = f[fname]
				if (v ~= nil and o[fname] ~= v and not MSV2.unsupported.env[fname]) then
					o[fname] = normalize(fname, v)
					pcall(set_mod_envobj, idx, fname, toEngine(fname, o[fname]))
					if (MSV2.LIVE_FIELDS[fname]) then touched[idx] = true else nonLive = true end
				end
			end
			MSV2.meta[idx] = MSV2.meta[idx] or {}
			MSV2.meta[idx].tri = id
			if (wasSelected) then MSV2.sel[idx] = true end
		end
	end
	if (nonLive or created) then
		MSV2.markDirty()
	else
		for idx in pairs(touched) do MSV2.markDirty(idx) end
	end
end

---Creates a triangle from three world points. opts: thick, slices, smooth, props, name
function MSV2.triCreate(a, b, c, opts)
	opts = opts or {}
	local id = MSV2.nextTri
	MSV2.nextTri = MSV2.nextTri + 1
	local col = MSV2.nextColor()
	local props = opts.props or {
		color_r = col[1], color_g = col[2], color_b = col[3], color_a = 1,
		mass = 1, static = MSV2.settings.newStatic, visible = true
	}
	MSV2.tris[id] = {
		a = V.copy(a), b = V.copy(b), c = V.copy(c),
		thick = opts.thick or 0.2,
		slices = opts.slices or 16,
		smooth = opts.smooth or "longest",
		props = props,
		name = opts.name,
		objs = {}
	}
	MSV2.triBuild(id)
	if (#MSV2.tris[id].objs == 0) then
		MSV2.tris[id] = nil
		return nil
	end
	return id
end

function MSV2.addTriangle(kind)
	MSV2.pushUndo("Add " .. (kind or "triangle"))
	local p = MSV2.spawnPoint()
	local id
	if (kind == "ramp") then
		-- Right-angle wedge: smooth sloped top, 2 wide
		id = MSV2.triCreate({ p[1] - 1.5, p[2], 0 }, { p[1] + 1.5, p[2], 0 }, { p[1] + 1.5, p[2], 1.2 },
			{ thick = 2, slices = 20, smooth = "ca", name = "Ramp" })
	elseif (kind == "flat") then
		-- Lying flat on the ground (a triangular floor tile)
		id = MSV2.triCreate({ p[1] - 1, p[2] - 0.8, 0.05 }, { p[1] + 1, p[2] - 0.8, 0.05 }, { p[1], p[2] + 1, 0.05 },
			{ thick = 0.1, slices = 16, name = "Floor Triangle" })
	else
		-- Upright triangle ("fin")
		id = MSV2.triCreate({ p[1] - 1, p[2], 0 }, { p[1] + 1, p[2], 0 }, { p[1], p[2], 1.6 },
			{ thick = 0.2, slices = 16 })
	end
	if (id) then
		MSV2.selSet(MSV2.tris[id].objs[1])
		MSV2.toast("Added triangle - edit its corners in the Triangle tab or drag the corner dots")
	end
	return id
end

---Turns a triangle into ordinary objects (keeps the slices, drops the link)
function MSV2.triDetach(id)
	local t = MSV2.tris[id]
	if (not t) then return end
	MSV2.pushUndo("Detach triangle")
	for i, idx in ipairs(t.objs) do
		MSV2.meta[idx] = MSV2.meta[idx] or {}
		MSV2.meta[idx].tri = nil
		-- The first slice takes over the triangle's place in the hierarchy
		MSV2.meta[idx].parent = t.parent
		MSV2.meta[idx].uid = (i == 1) and t.uid or nil
	end
	MSV2.tris[id] = nil
	MSV2.toast("Triangle converted to " .. #t.objs .. " plain boxes")
	selChanged()
end

---------------------------------------------------------------------------
-- Tools: align / distribute / mirror / drop / snap / arrays / generators
---------------------------------------------------------------------------

---Applies a rigid transform (pivot, rotation Q, translation d) to the selection
function MSV2.transformSelection(pivot, Q, d)
	local tris, plain = (MSV2.selSplitFamily or MSV2.selSplit)()
	for _, idx in ipairs(plain) do
		local p = MSV2.objPos(idx)
		local np = V.add(V.add(pivot, M.apply(Q, V.sub(p, pivot))), d)
		MSV2.setObjPos(idx, np)
		MSV2.setObjRot(idx, M.mul(Q, MSV2.objRot(idx)))
	end
	for id in pairs(tris) do
		local t = MSV2.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do
			t[key] = V.add(V.add(pivot, M.apply(Q, V.sub(t[key], pivot))), d)
		end
		MSV2.triBuild(id)
	end
end

---Moves the selection without touching rotations
function MSV2.translateSelection(d)
	local tris, plain = (MSV2.selSplitFamily or MSV2.selSplit)()
	for _, idx in ipairs(plain) do
		MSV2.setObjPos(idx, V.add(MSV2.objPos(idx), d))
	end
	for id in pairs(tris) do
		local t = MSV2.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do
			t[key] = V.add(t[key], d)
		end
		MSV2.triBuild(id)
	end
end

function MSV2.dropToFloor()
	local tris, plain = MSV2.selSplit()
	if (#plain == 0 and next(tris) == nil) then
		MSV2.toast("Select something to drop")
		return
	end
	MSV2.pushUndo("Drop to floor")
	for _, idx in ipairs(plain) do
		local dz = -MSV2.objBottom(idx)
		MSV2.objSet(idx, "pos_z", MSV2.objs[idx].pos_z + dz)
	end
	for id in pairs(tris) do
		local t = MSV2.tris[id]
		local lo = math.min(t.a[3], t.b[3], t.c[3])
		local half = 0
		local slices = MSV2.triSlices(t)
		if (slices[1]) then
			half = abs(slices[1].R[3][3]) * (t.thick or 0.2) / 2
		end
		local dz = -(lo - half)
		for _, key in ipairs({ "a", "b", "c" }) do t[key][3] = t[key][3] + dz end
		MSV2.triBuild(id)
	end
	MSV2.toast("Dropped to the floor")
end

function MSV2.snapSelectionToGrid()
	local step = MSV2.settings.gridStep
	if (step <= 0) then return end
	local tris, plain = MSV2.selSplit()
	MSV2.pushUndo("Snap to grid")
	for _, idx in ipairs(plain) do
		local p = MSV2.objPos(idx)
		MSV2.setObjPos(idx, { MSV2.round(p[1], step), MSV2.round(p[2], step), MSV2.round(p[3], step) })
	end
	for id in pairs(tris) do
		local t = MSV2.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do
			t[key] = { MSV2.round(t[key][1], step), MSV2.round(t[key][2], step), MSV2.round(t[key][3], step) }
		end
		MSV2.triBuild(id)
	end
	MSV2.toast("Snapped to grid (" .. MSV2.fmt(step) .. ")")
end

function MSV2.resetRotation()
	local _, plain = MSV2.selSplit()
	if (#plain == 0) then return end
	MSV2.pushUndo("Reset rotation")
	for _, idx in ipairs(plain) do
		MSV2.objSet(idx, "rot_x", 0)
		MSV2.objSet(idx, "rot_y", 0)
		MSV2.objSet(idx, "rot_z", 0)
	end
end

---Align all selected objects' centers to the primary object on axis k (1..3)
function MSV2.alignSelection(k, mode)
	local tris, plain = MSV2.selSplit()
	if (#plain + MSV2.count(tris) < 2) then
		MSV2.toast("Select 2 or more objects to align (Shift+click)")
		return
	end
	MSV2.pushUndo("Align")
	local target
	if (mode == "floor") then
		target = 0
	elseif (MSV2.primary and MSV2.objs[MSV2.primary]) then
		target = MSV2.objPos(MSV2.primary)[k]
	else
		target = MSV2.selCenter()[k]
	end
	for _, idx in ipairs(plain) do
		local p = MSV2.objPos(idx)
		p[k] = target
		MSV2.setObjPos(idx, p)
	end
	for id in pairs(tris) do
		local c = MSV2.triCentroid(id)
		local d = { 0, 0, 0 }
		d[k] = target - c[k]
		local t = MSV2.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do t[key] = V.add(t[key], d) end
		MSV2.triBuild(id)
	end
	MSV2.toast("Aligned on " .. ({ "X", "Y", "Z" })[k])
end

---Evenly spaces plain selected objects between the outermost two along axis k
function MSV2.distributeSelection(k)
	local _, plain = MSV2.selSplit()
	if (#plain < 3) then
		MSV2.toast("Select 3 or more objects to distribute")
		return
	end
	MSV2.pushUndo("Distribute")
	table.sort(plain, function(a, b) return MSV2.objPos(a)[k] < MSV2.objPos(b)[k] end)
	local lo = MSV2.objPos(plain[1])[k]
	local hi = MSV2.objPos(plain[#plain])[k]
	for i, idx in ipairs(plain) do
		local p = MSV2.objPos(idx)
		p[k] = lo + (hi - lo) * (i - 1) / (#plain - 1)
		MSV2.setObjPos(idx, p)
	end
	MSV2.toast("Distributed evenly on " .. ({ "X", "Y", "Z" })[k])
end

---Mirrors the selection across the world plane through 0 (or the selection center)
---on axis k. With `copy` the mirrored version is added as new objects.
function MSV2.mirrorSelection(k, copy, aroundCenter)
	local clip = MSV2.copySelection()
	if (not clip) then return end
	MSV2.pushUndo(copy and "Mirror copy" or "Mirror")
	local c = aroundCenter and MSV2.selCenter()[k] or 0
	local function mp(p)
		local q = V.copy(p)
		q[k] = 2 * c - q[k]
		return q
	end
	if (not copy) then
		-- The clip holds the selection and its children: replace all of them
		local tris, plain = (MSV2.selSplitFamily or MSV2.selSplit)()
		local doomed = {}
		for _, idx in ipairs(plain) do table.insert(doomed, idx) end
		for id in pairs(tris) do
			for _, idx in ipairs(MSV2.tris[id].objs) do table.insert(doomed, idx) end
			MSV2.tris[id] = nil
		end
		for _, idx in ipairs(doomed) do
			if (MSV2.meta[idx]) then MSV2.meta[idx].tri = nil end
			MSV2.deleteObjRaw(idx)
		end
	end
	for _, item in ipairs(clip.objs) do
		local f = item.fields
		local p = mp({ f.pos_x, f.pos_y, f.pos_z })
		f.pos_x, f.pos_y, f.pos_z = p[1], p[2], p[3]
		local R = M.mirror(M.fromEuler(f.rot_x, f.rot_y, f.rot_z), k)
		f.rot_x, f.rot_y, f.rot_z = M.toEuler(R)
		if (f.thrust_x) then
			local tv = { f.thrust_x, f.thrust_y, f.thrust_z }
			tv[k] = -tv[k]
			f.thrust_x, f.thrust_y, f.thrust_z = tv[1], tv[2], tv[3]
		end
	end
	for _, t in ipairs(clip.tris) do
		t.a, t.b, t.c = mp(t.a), mp(t.b), mp(t.c)
	end
	MSV2.pasteClip(clip, { 0, 0, 0 }, not copy)
	MSV2.toast((copy and "Mirrored copy" or "Mirrored") .. " across " .. ({ "X", "Y", "Z" })[k])
end

---Linear array: `count` extra copies, each offset by `offset`
function MSV2.arraySelection(count, offset)
	local clip = MSV2.copySelection()
	if (not clip) then return end
	count = floor(count or 0)
	if (count < 1) then return end
	MSV2.pushUndo("Array")
	local all = MSV2.selList()
	for i = 1, count do
		for _, idx in ipairs(MSV2.pasteClip(clip, V.mul(offset, i))) do
			table.insert(all, idx)
		end
	end
	MSV2.sel = {}
	for _, idx in ipairs(all) do MSV2.sel[idx] = true end
	selChanged()
	MSV2.toast("Made " .. count .. " copies")
end

---Radial array around the selection center (or world origin) on the Z axis
function MSV2.radialArraySelection(count, radius)
	local clip = MSV2.copySelection()
	if (not clip) then return end
	count = floor(count or 0)
	if (count < 2) then return end
	MSV2.pushUndo("Radial array")
	local center = MSV2.selCenter()
	local pivot = { center[1] - radius, center[2], center[3] }
	local all = MSV2.selList()
	for i = 1, count - 1 do
		local ang = 360 * i / count
		local Q = M.axisAngle({ 0, 0, 1 }, ang)
		local c2 = MSV2.deepcopy(clip)
		for _, item in ipairs(c2.objs) do
			local f = item.fields
			local p = V.add(pivot, M.apply(Q, V.sub({ f.pos_x, f.pos_y, f.pos_z }, pivot)))
			f.pos_x, f.pos_y, f.pos_z = p[1], p[2], p[3]
			f.rot_x, f.rot_y, f.rot_z = M.toEuler(M.mul(Q, M.fromEuler(f.rot_x, f.rot_y, f.rot_z)))
		end
		for _, t in ipairs(c2.tris) do
			for _, key in ipairs({ "a", "b", "c" }) do
				t[key] = V.add(pivot, M.apply(Q, V.sub(t[key], pivot)))
			end
		end
		for _, idx in ipairs(MSV2.pasteClip(c2, { 0, 0, 0 })) do table.insert(all, idx) end
	end
	MSV2.sel = {}
	for _, idx in ipairs(all) do MSV2.sel[idx] = true end
	selChanged()
	MSV2.toast("Placed " .. count .. " copies in a circle")
end

MSV2.gen = MSV2.gen or {
	stairsSteps = 6, stairsWidth = 2, stairsRise = 0.25, stairsRun = 0.4,
	arenaSize = 12, arenaWall = 2, arenaThick = 0.4,
	tilesX = 6, tilesY = 6, tileSize = 1,
	arrayCount = 3, arrayX = 1.5, arrayY = 0, arrayZ = 0,
	radialCount = 8, radialRadius = 4,
	pyramidLevels = 4, pyramidSize = 0.8
}

function MSV2.genStairs()
	local g = MSV2.gen
	MSV2.pushUndo("Stairs")
	local p = MSV2.spawnPoint()
	local c = MSV2.nextColor()
	local list = {}
	for i = 1, floor(g.stairsSteps) do
		local h = g.stairsRise * i
		local idx = MSV2.createObj({
			type = 1, dims_x = g.stairsRun, dims_y = g.stairsWidth, dims_z = h,
			pos_x = p[1] + g.stairsRun * (i - 1), pos_y = p[2], pos_z = h / 2,
			color_r = c[1], color_g = c[2], color_b = c[3], static = true, mass = 1
		}, { name = "Step " .. i, group = "Stairs" })
		if (idx) then table.insert(list, idx) end
	end
	MSV2.sel = {}
	for _, idx in ipairs(list) do MSV2.sel[idx] = true end
	MSV2.primary = list[1]
	selChanged()
	MSV2.toast("Built " .. #list .. " stairs")
end

function MSV2.genArena()
	local g = MSV2.gen
	MSV2.pushUndo("Arena")
	local s, h, t = g.arenaSize, g.arenaWall, g.arenaThick
	local list = {}
	local function add(f, name)
		f.type = 1
		f.static = true
		f.mass = 1
		local idx = MSV2.createObj(f, { name = name, group = "Arena" })
		if (idx) then table.insert(list, idx) end
	end
	add({ dims_x = s, dims_y = s, dims_z = 0.2, pos_x = 0, pos_y = 0, pos_z = 0.1, color_r = 0.62, color_g = 0.62, color_b = 0.66 }, "Arena Floor")
	local wc = { 0.35, 0.38, 0.45 }
	add({ dims_x = s + t * 2, dims_y = t, dims_z = h, pos_x = 0, pos_y = s / 2 + t / 2, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall North")
	add({ dims_x = s + t * 2, dims_y = t, dims_z = h, pos_x = 0, pos_y = -s / 2 - t / 2, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall South")
	add({ dims_x = t, dims_y = s, dims_z = h, pos_x = s / 2 + t / 2, pos_y = 0, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall East")
	add({ dims_x = t, dims_y = s, dims_z = h, pos_x = -s / 2 - t / 2, pos_y = 0, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall West")
	MSV2.sel = {}
	for _, idx in ipairs(list) do MSV2.sel[idx] = true end
	MSV2.primary = list[1]
	selChanged()
	MSV2.toast("Built an arena around the players")
end

function MSV2.genTiles()
	local g = MSV2.gen
	MSV2.pushUndo("Tiles")
	local p = MSV2.spawnPoint()
	local nx, ny, sz = floor(g.tilesX), floor(g.tilesY), g.tileSize
	local list = {}
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			local dark = (i + j) % 2 == 0
			local v = dark and 0.2 or 0.85
			local idx = MSV2.createObj({
				type = 1, dims_x = sz, dims_y = sz, dims_z = 0.1,
				pos_x = p[1] + (i - (nx - 1) / 2) * sz, pos_y = p[2] + (j - (ny - 1) / 2) * sz, pos_z = 0.05,
				color_r = v, color_g = v, color_b = v, static = true, mass = 1
			}, { group = "Tiles" })
			if (idx) then table.insert(list, idx) else break end
		end
	end
	MSV2.sel = {}
	for _, idx in ipairs(list) do MSV2.sel[idx] = true end
	MSV2.primary = list[1]
	selChanged()
	MSV2.toast("Built a " .. nx .. "x" .. ny .. " checkerboard")
end

function MSV2.genPyramid()
	local g = MSV2.gen
	MSV2.pushUndo("Pyramid")
	local p = MSV2.spawnPoint()
	local n, sz = floor(g.pyramidLevels), g.pyramidSize
	local list = {}
	for level = 0, n - 1 do
		local w = n - level
		for i = 0, w - 1 do
			for j = 0, w - 1 do
				local c = MSV2.PALETTE[(level % 8) + 1]
				local idx = MSV2.createObj({
					type = 1, dims_x = sz, dims_y = sz, dims_z = sz,
					pos_x = p[1] + (i - (w - 1) / 2) * sz, pos_y = p[2] + (j - (w - 1) / 2) * sz, pos_z = sz / 2 + level * sz,
					color_r = c[1], color_g = c[2], color_b = c[3], static = false, mass = 0.5
				}, { group = "Pyramid" })
				if (idx) then table.insert(list, idx) end
			end
		end
	end
	MSV2.sel = {}
	for _, idx in ipairs(list) do MSV2.sel[idx] = true end
	MSV2.primary = list[1]
	selChanged()
	MSV2.toast("Stacked " .. #list .. " blocks - they're physical, so they'll tumble!")
end

---------------------------------------------------------------------------
-- Materials
---------------------------------------------------------------------------

MSV2.MATERIALS = {
	{ name = "Default", hardness = 0, friction = 0, bounce = 0 },
	{ name = "Ice", hardness = 0.5, friction = 0.01, bounce = 0 },
	{ name = "Rubber", hardness = 0.1, friction = 1.2, bounce = 0.7 },
	{ name = "Metal", hardness = 1, friction = 0.4, bounce = 0.1 },
	{ name = "Wood", hardness = 0.6, friction = 0.7, bounce = 0.15 },
	{ name = "Trampoline", hardness = 0.2, friction = 0.6, bounce = 1 },
	{ name = "Sticky", hardness = 0.2, friction = 3, bounce = 0 }
}

---------------------------------------------------------------------------
-- Players: mirror, copy, scale
---------------------------------------------------------------------------

---Finds the left/right mirror axis + center for a player from the pecs positions
function MSV2.playerMirrorAxis(p)
	local r, l = MSV2.bodies[p] and MSV2.bodies[p][5], MSV2.bodies[p] and MSV2.bodies[p][8]
	if (not r or not l) then return 1, 0 end
	local d = { abs(r.pos_x - l.pos_x), abs(r.pos_y - l.pos_y), abs(r.pos_z - l.pos_z) }
	local k = 1
	if (d[2] > d[k]) then k = 2 end
	if (d[3] > d[k]) then k = 3 end
	local keys = { "pos_x", "pos_y", "pos_z" }
	return k, (r[keys[k]] + l[keys[k]]) / 2
end

local AXK = { "x", "y", "z" }

function MSV2.mirrorBody(p, b, silent)
	local other = MSV2.BODY_MIRROR[b]
	local src = MSV2.bodies[p] and MSV2.bodies[p][b]
	if (not other or not src) then
		if (not silent) then MSV2.toast("This body part has no left/right partner") end
		return
	end
	local k, c = MSV2.playerMirrorAxis(p)
	for f, v in pairs(src) do
		MSV2.bodySet(p, other, f, v)
	end
	MSV2.bodySet(p, other, "pos_" .. AXK[k], 2 * c - src["pos_" .. AXK[k]])
	local R = M.mirror(M.fromEuler(src.rot_x, src.rot_y, src.rot_z), k)
	local x, y, z = M.toEuler(R)
	MSV2.bodySet(p, other, "rot_x", x)
	MSV2.bodySet(p, other, "rot_y", y)
	MSV2.bodySet(p, other, "rot_z", z)
	if (src.force_x) then
		MSV2.bodySet(p, other, "force_" .. AXK[k], -src["force_" .. AXK[k]])
	end
	if (not silent) then MSV2.toast("Copied " .. MSV2.BODY_NAMES[b] .. " to " .. MSV2.BODY_NAMES[other]) end
end

function MSV2.mirrorJoint(p, j, silent)
	local other = MSV2.JOINT_MIRROR[j]
	local src = MSV2.joints[p] and MSV2.joints[p][j]
	if (not other or not src) then
		if (not silent) then MSV2.toast("This joint has no left/right partner") end
		return
	end
	local k, c = MSV2.playerMirrorAxis(p)
	for f, v in pairs(src) do
		MSV2.jointSet(p, other, f, v)
	end
	MSV2.jointSet(p, other, "pos_" .. AXK[k], 2 * c - src["pos_" .. AXK[k]])
	-- Rotation axes are pseudo-vectors: reflect, then flip
	local ax = { src.axis_x or 0, src.axis_y or 0, src.axis_z or 0 }
	ax[k] = -ax[k]
	ax = V.mul(ax, -1)
	MSV2.jointSet(p, other, "axis_x", ax[1])
	MSV2.jointSet(p, other, "axis_y", ax[2])
	MSV2.jointSet(p, other, "axis_z", ax[3])
	if (not silent) then MSV2.toast("Copied " .. MSV2.JOINT_NAMES[j] .. " to " .. MSV2.JOINT_NAMES[other]) end
end

MSV2.PHYS_BODY_FIELDS = { "type", "sides_x", "sides_y", "sides_z", "density", "hardness", "friction", "bounce" }
MSV2.PHYS_JOINT_FIELDS = { "histop", "lostop", "maxforce", "maxvelocity", "radius", "density", "hardness", "friction", "bounce" }

function MSV2.copyBodyToOtherPlayers(p, b)
	local src = MSV2.bodies[p][b]
	for q = 0, MSV2.numPlayers - 1 do
		if (q ~= p) then
			for _, f in ipairs(MSV2.PHYS_BODY_FIELDS) do
				if (src[f] ~= nil and (f ~= "type" or b ~= 0)) then MSV2.bodySet(q, b, f, src[f]) end
			end
		end
	end
end

function MSV2.copyJointToOtherPlayers(p, j)
	local src = MSV2.joints[p][j]
	for q = 0, MSV2.numPlayers - 1 do
		if (q ~= p) then
			for _, f in ipairs(MSV2.PHYS_JOINT_FIELDS) do
				if (src[f] ~= nil) then MSV2.jointSet(q, j, f, src[f]) end
			end
		end
	end
end

---------------------------------------------------------------------------
-- 360 joints: limits past +-pi are ignored by the physics engine, so a joint
-- with range 10 / -10 keeps turning either way (how the "360 chest" mods work)
---------------------------------------------------------------------------

MSV2.SPIN_LIMIT = 10
MSV2.spinPrev = MSV2.spinPrev or {}

function MSV2.jointSpins(p, j)
	local o = MSV2.joints[p] and MSV2.joints[p][j]
	if (not o) then return false end
	return math.abs(o.histop or 0) > math.pi and math.abs(o.lostop or 0) > math.pi
end

---Turns 360 spinning on/off for one joint, remembering its old limits
function MSV2.setJointSpin(p, j, on)
	local o = MSV2.joints[p] and MSV2.joints[p][j]
	if (not o) then return end
	local key = p .. ":" .. j
	if (on) then
		if (not MSV2.jointSpins(p, j)) then
			MSV2.spinPrev[key] = { o.histop, o.lostop }
		end
		MSV2.jointSet(p, j, "histop", MSV2.SPIN_LIMIT)
		MSV2.jointSet(p, j, "lostop", -MSV2.SPIN_LIMIT)
	else
		local prev = MSV2.spinPrev[key]
		MSV2.jointSet(p, j, "histop", prev and prev[1] or 1)
		MSV2.jointSet(p, j, "lostop", prev and prev[2] or -1)
		MSV2.spinPrev[key] = nil
	end
end

---Spin preset for a list of joints on every player. Returns how many joints changed
function MSV2.spinJoints(list, on)
	local n = 0
	for p = 0, math.max(1, MSV2.numPlayers) - 1 do
		for _, j in ipairs(list) do
			if (MSV2.joints[p] and MSV2.joints[p][j] and MSV2.jointSpins(p, j) ~= on) then
				MSV2.setJointSpin(p, j, on)
				n = n + 1
			end
		end
	end
	return n
end

MSV2.CHEST_JOINT, MSV2.LUMBAR_JOINT = 1, 2

---Scales a whole player around the point between its feet (sizes, positions, joint radii)
function MSV2.scalePlayer(p, k)
	if (not MSV2.bodies[p] or k <= 0) then return end
	local minZ = math.huge
	for b = 0, MSV2.NUM_BODIES - 1 do
		local o = MSV2.bodies[p][b]
		if (o) then minZ = math.min(minZ, o.pos_z - (o.sides_z or 0) / 2) end
	end
	local head = MSV2.bodies[p][0]
	local pivot = { head.pos_x, head.pos_y, math.max(0, minZ) }
	local function sp(o, set, id)
		local q = V.add(pivot, V.mul(V.sub({ o.pos_x, o.pos_y, o.pos_z }, pivot), k))
		set(p, id, "pos_x", q[1])
		set(p, id, "pos_y", q[2])
		set(p, id, "pos_z", q[3])
	end
	for b = 0, MSV2.NUM_BODIES - 1 do
		local o = MSV2.bodies[p][b]
		if (o) then
			sp(o, MSV2.bodySet, b)
			for _, f in ipairs({ "sides_x", "sides_y", "sides_z" }) do
				if (o[f]) then MSV2.bodySet(p, b, f, o[f] * k) end
			end
		end
	end
	for j = 0, MSV2.NUM_JOINTS - 1 do
		local o = MSV2.joints[p] and MSV2.joints[p][j]
		if (o) then
			sp(o, MSV2.jointSet, j)
			if (o.radius) then MSV2.jointSet(p, j, "radius", o.radius * k) end
		end
	end
end

---------------------------------------------------------------------------
-- Gamerules
---------------------------------------------------------------------------

MSV2.RULES = {
	{ name = "matchframes", title = "Match frames", kind = "int", tip = "How long the whole fight lasts" },
	{ name = "turnframes", title = "Turn frames", kind = "string", tip = "Frames per turn. Several values separated by commas set a pattern, e.g. 30,20,10" },
	{ name = "reactiontime", title = "Reaction time", kind = "int", tip = "Frames you get to react between turns (online)" },
	{ name = "numplayers", title = "Players", kind = "enum", options = { { 1, "1" }, { 2, "2" }, { 3, "3" }, { 4, "4" } } },
	{ name = "gravity", title = "Gravity", kind = "vec3", tip = "Default is 0 0 -9.82. Try 0 0 -3 for moon fights" },
	{ name = "grabmode", title = "Grab mode", kind = "enum", options = { { 0, "Fixed" }, { 1, "Rotatable" } }, tip = "Fixed: grabs lock solid. Rotatable: grabs act like a ball joint" },
	{ name = "tearthreshold", title = "Tear threshold", kind = "int", tip = "Force needed to break a rotatable grab" },
	{ name = "dismemberthreshold", title = "Dismember threshold", kind = "int", tip = "Force needed to rip a joint off. Lower = limbs come off easier" },
	{ name = "fracturethreshold", title = "Fracture threshold", kind = "int", tip = "Force needed to break a joint. Lower = breaks easier" },
	{ name = "dqtimeout", title = "DQ timeout", kind = "int", tip = "Frames a player may touch the ground before being disqualified" },
	{ name = "dqflag", title = "DQ mode", kind = "enum", options = { { 0, "Follow timeout" }, { 1, "Instant outside dojo" } } },
	{ name = "sumo", title = "Sumo mode", kind = "enum", options = { { 0, "Hands+Feet" }, { 1, "+Wrists/Ankles" } } },
	{ name = "dojosize", title = "Dojo size", kind = "int", tip = "0 = no dojo" },
	{ name = "dojotype", title = "Dojo type", kind = "enum", options = { { 0, "Square" }, { 1, "Round" } } },
	{ name = "engagedistance", title = "Engage distance", kind = "int", tip = "How far apart the players start" },
	{ name = "engageheight", title = "Engage height", kind = "int", tip = "Start height above the ground" },
	{ name = "engagerotation", title = "Engage rotation", kind = "int", tip = "Degrees the players are turned at the start" },
	{ name = "engageplayerpos", title = "Custom start pos", kind = "string", tip = "x,y,z for each player, comma separated (0 = off)" },
	{ name = "engageplayerrot", title = "Custom start rot", kind = "string", tip = "x,y,z rotation for each player, comma separated" },
	{ name = "damage", title = "Damage scoring", kind = "enum", options = { { 0, "Opponent" }, { 1, "Both" }, { 2, "Self" } } },
	{ name = "pointthreshold", title = "Point threshold", kind = "int" },
	{ name = "winpoint", title = "Win points", kind = "int", tip = "Score needed to win instantly (0 = off)" },
	{ name = "drawwinner", title = "Winner on draw", kind = "enum", options = { { 0, "Default" }, { 1, "Tori" }, { 2, "Uke" } } },
	{ name = "maxcontacts", title = "Max contacts", kind = "int" },
	{ name = "momentumdecay", title = "Momentum decay", kind = "percent", min = 0, max = 100, minDisp = "Off", maxDisp = "100%", default = 100,
		tip = "How much of the classic spin and flip slowdown is kept. 100% is normal Toribash, Off removes it (single player only)" },
	{ name = "ghostcustom", title = "Custom ghosts", kind = "bool" },
	{ name = "ghostlength", title = "Ghost length", kind = "int" },
	{ name = "ghostspeed", title = "Ghost speed", kind = "int" }
}

---Game flags: the `flags` gamerule is these bits added together. Each also has
---its own gamerule, which is kept in sync (grip is the inverse of No grip).
MSV2.FLAGS = {
	{ bit = 1, title = "Disqualification (DQ)", rule = "disqualification",
		desc = "Touching the ground with anything except hands and feet loses the match" },
	{ bit = 2, title = "Dismemberment", rule = "dismemberment",
		desc = "Joints can be ripped off when hit hard enough (see Dismember threshold)" },
	{ bit = 4, title = "No grip", rule = "grip", invert = true,
		desc = "Hands can't grab anything. Turn off to allow grabbing" },
	{ bit = 8, title = "Fracture", rule = "fracture",
		desc = "Joints can break and go limp but stay attached (see Fracture threshold)" }
}

local function hasBit(n, b)
	return floor(n / b) % 2 == 1
end
MSV2.hasBit = hasBit

---Current flags value, rebuilt from the individual rules if `flags` is missing
function MSV2.getFlags()
	local n = tonumber(MSV2.getRule("flags") or "")
	if (n) then return n end
	n = 0
	for _, f in ipairs(MSV2.FLAGS) do
		local v = MSV2.getRule(f.rule) == "1"
		if (f.invert) then v = not v end
		if (v) then n = n + f.bit end
	end
	return n
end

function MSV2.setFlags(n)
	n = MSV2.clamp(floor(n or 0), 0, 15)
	MSV2.setRule("flags", n)
	for _, f in ipairs(MSV2.FLAGS) do
		local on = hasBit(n, f.bit)
		if (f.invert) then on = not on end
		MSV2.setRule(f.rule, on and 1 or 0)
	end
end

function MSV2.setFlag(bit, on)
	local n = MSV2.getFlags()
	if (hasBit(n, bit) and not on) then
		n = n - bit
	elseif (not hasBit(n, bit) and on) then
		n = n + bit
	end
	MSV2.setFlags(n)
end

---Human readable summary like "DQ + Dismemberment"
function MSV2.flagsSummary(n)
	local parts = {}
	for _, f in ipairs(MSV2.FLAGS) do
		if (hasBit(n, f.bit)) then table.insert(parts, (f.title:gsub(" %(DQ%)", ""))) end
	end
	return #parts > 0 and table.concat(parts, " + ") or "None"
end

---Every rule name a snapshot / project keeps
function MSV2.allRuleNames()
	local names = { "flags" }
	for _, f in ipairs(MSV2.FLAGS) do table.insert(names, f.rule) end
	for _, r in ipairs(MSV2.RULES) do table.insert(names, r.name) end
	return names
end

function MSV2.readRules()
	local t = {}
	for _, name in ipairs(MSV2.allRuleNames()) do
		local v = MSV2.getRule(name)
		if (v ~= nil) then t[name] = v end
	end
	return t
end

function MSV2.applyRules(rules)
	if (not rules) then return end
	for name, v in pairs(rules) do
		if (name ~= "mod" and v ~= MSV2.getRule(name)) then
			pcall(set_gamerule, name, tostring(v))
		end
	end
end

---Rules we set that the engine doesn't report back yet (some only take effect on a
---new game): the value we set wins until the engine's own value changes
MSV2.ruleShadow = MSV2.ruleShadow or {}

function MSV2.getRule(name)
	local ok, v = pcall(get_gamerule, name)
	local sh = MSV2.ruleShadow[name]
	if (sh) then
		if (ok and tostring(v) == sh.eng) then return sh.v end
		MSV2.ruleShadow[name] = nil
	end
	if (ok) then return v end
	return nil
end

function MSV2.setRule(name, value)
	pcall(set_gamerule, name, tostring(value))
	local ok, back = pcall(get_gamerule, name)
	if (ok and tostring(back) ~= tostring(value)) then
		MSV2.ruleShadow[name] = { v = tostring(value), eng = tostring(back) }
	else
		MSV2.ruleShadow[name] = nil
	end
	MSV2.changed = true
	MSV2.changedSinceAutosave = true
end

function MSV2.restartMatch()
	MSV2.flush(true)
	local ok, ws = pcall(get_world_state)
	if (ok and ws and ws.game_type == 1 and runCmd) then
		runCmd("reset")
	else
		pcall(start_new_game)
	end
	MSV2.toast("Match restarted with the new rules")
end

---------------------------------------------------------------------------
-- Turning a whole player around with the game's per-player start rules
-- (engageplayerpos / engageplayerrot: "x,y,z" for each player, world units / degrees).
-- The engine rotates the player as one piece, so no body part or joint is rewritten.
-- Those rules replace engagedistance / height / rotation, and their exact origin and
-- rotation sign can't be read from the API, so the result is measured after the
-- restart and corrected (rotation first, then position) until the player is where
-- and how it should be.
---------------------------------------------------------------------------

MSV2.faceFlipped = MSV2.faceFlipped or {}

local function parseTriples(str, n)
	local out = {}
	for num in tostring(str or ""):gmatch("[%-%+]?[%d%.]+e?[%-%+]?%d*") do
		local v = tonumber(num)
		if (v) then out[#out + 1] = v end
	end
	if (#out < 3 * n) then return nil end
	local any = false
	for _, v in ipairs(out) do if (v ~= 0) then any = true end end
	if (not any) then return nil end
	local t = {}
	for i = 1, n do t[i] = { out[3 * i - 2], out[3 * i - 1], out[3 * i] } end
	return t
end

local function joinTriples(t)
	local parts = {}
	for _, v in ipairs(t) do parts[#parts + 1] = string.format("%.3f,%.3f,%.3f", v[1], v[2], v[3]) end
	return table.concat(parts, ",")
end

local function yawOf(p)
	local wr, wl = MSV2.bodyWorld(p, 5), MSV2.bodyWorld(p, 8)
	if (not wr or not wl) then return nil end
	return math.deg(math.atan2(wl.pos[2] - wr.pos[2], wl.pos[1] - wr.pos[1]))
end

local function angDiff(a, b)
	local d = (a - b) % 360
	if (d > 180) then d = d - 360 end
	return d
end

local function applyFace(f)
	MSV2.setRule("engageplayerpos", joinTriples(f.pos))
	MSV2.setRule("engageplayerrot", joinTriples(f.rot))
	MSV2.restartMatch()
	f.wait = 12
end

---The per-player start rules as lists of {x,y,z} (index 1 = Tori). When they aren't custom
---yet they are initialised from where each player is drawn now (c0 = world centres,
---yaw0 = facing), the same way for every player.
function MSV2.startRules(n, c0, yaw0)
	local V = MSV2.V
	local pos = parseTriples(MSV2.getRule("engageplayerpos"), n)
	local rot = pos and parseTriples(MSV2.getRule("engageplayerrot"), n) or nil
	if (not pos) then
		-- Not custom yet: start from where each player is drawn now
		pos, rot = {}, {}
		for i = 0, n - 1 do
			local W = MSV2.playerFrame(i)
			local mc = MSV2.playerModCenter(i) or { 0, 0, 0 }
			local o = V.sub(c0[i], MSV2.M.apply(W, mc))
			pos[i + 1] = o
			-- Yaw the mod coordinates are turned by (assumes the engine's +z turns the same way)
			local wr, wl = MSV2.bodies[i] and MSV2.bodies[i][5], MSV2.bodies[i] and MSV2.bodies[i][8]
			local ym = (wr and wl) and math.deg(math.atan2(wl.pos_y - wr.pos_y, wl.pos_x - wr.pos_x)) or 0
			rot[i + 1] = { 0, 0, angDiff(yaw0[i], ym) }
		end
	end
	rot = rot or {}
	for i = 1, n do rot[i] = rot[i] or { 0, 0, 0 } end
	return pos, rot
end

---Starts turning player p around (press again to turn back)
function MSV2.faceToggle(p)
	local n = math.max(2, MSV2.numPlayers or 2)
	local V = MSV2.V
	local f = { p = p, n = n, c0 = {}, yaw0 = {}, tries = 0 }
	for i = 0, n - 1 do
		f.c0[i] = MSV2.playerWorldCenter(i)
		f.yaw0[i] = yawOf(i)
		if (not f.c0[i] or not f.yaw0[i]) then
			MSV2.toast("Can't read where the players are right now")
			return false
		end
	end
	local pos, rot = MSV2.startRules(n, f.c0, f.yaw0)
	f.pos, f.rot = pos, rot
	f.rotBase = {}
	for i = 1, n do f.rotBase[i] = rot[i][3] end
	-- Expected result: everybody where and how they were, the chosen player turned 180
	f.want = {}
	for i = 0, n - 1 do f.want[i] = f.yaw0[i] + (i == p and 180 or 0) end
	rot[p + 1][3] = rot[p + 1][3] + 180
	f.rotBase[p + 1] = rot[p + 1][3]
	MSV2.pushUndo("Face the other way")
	MSV2.faceFlipped[p] = not MSV2.faceFlipped[p]
	MSV2.faceFix = f
	applyFace(f)
	return true
end

---Moves one whole player by world offset d by changing ONLY that player's entry in
---engageplayerpos (everybody else's values and engageplayerrot stay), then restarts the
---match and lets tickFace measure / correct the result. opts.previewed: the player is
---currently drawn already shifted by d (drag preview). opts.label: undo step name.
function MSV2.movePlayerBy(p, d, opts)
	opts = opts or {}
	local n = math.max(2, MSV2.numPlayers or 2)
	local V = MSV2.V
	local f = { p = p, n = n, c0 = {}, yaw0 = {}, tries = 0, want = {} }
	for i = 0, n - 1 do
		f.c0[i] = MSV2.playerWorldCenter(i)
		f.yaw0[i] = yawOf(i)
		if (not f.c0[i] or not f.yaw0[i]) then
			MSV2.toast("Can't read where the players are right now")
			return false
		end
		f.want[i] = f.yaw0[i]
	end
	-- Where p was before the move (the rules describe the match start, not the preview)
	if (opts.previewed) then f.c0[p] = V.sub(f.c0[p], d) end
	local pos, rot = MSV2.startRules(n, f.c0, f.yaw0)
	if (opts.label) then MSV2.pushUndo(opts.label) end
	pos[p + 1] = V.add(pos[p + 1], d)
	f.c0[p] = V.add(f.c0[p], d)
	f.pos, f.rot = pos, rot
	MSV2.faceFix = f
	applyFace(f)
	return true
end

---True when the per-player start rules hold custom positions
function MSV2.hasCustomPlacement()
	local n = math.max(2, MSV2.numPlayers or 2)
	return parseTriples(MSV2.getRule("engageplayerpos"), n) ~= nil
end

---Back to the game's own placement (engagedistance / engageheight / engagerotation, default
---facing): both per-player rules are unset ("0" = off, which is what the game's own rule editor
---writes), the turned-around flags are forgotten. restart: start a new match so it shows.
function MSV2.clearPlacement(restart)
	local n = math.max(2, MSV2.numPlayers or 2)
	local z = {}
	for i = 1, n do z[i] = "0,0,0" end
	MSV2.faceFix = nil
	MSV2.faceFlipped = {}
	MSV2.setRule("engageplayerpos", "0")
	MSV2.setRule("engageplayerrot", table.concat(z, ","))
	if (restart) then MSV2.restartMatch() end
end

---Where every player is drawn now: centres and yaws, or nil if they can't be read
function MSV2.measurePlayers()
	local n = math.max(2, MSV2.numPlayers or 2)
	local m = { c = {}, yaw = {} }
	for i = 0, n - 1 do
		m.c[i] = MSV2.playerWorldCenter(i)
		m.yaw[i] = yawOf(i)
		if (not m.c[i] or not m.yaw[i]) then return nil end
	end
	return m
end

---Puts only player p back at the game's default place / facing while the other players keep
---their custom start position and rotation. prior = MSV2.measurePlayers() from before the
---reset. Step A: remember the rules, clear them, restart. Step B (tickFace, phaseA): measure
---the defaults, rebuild the rules from them (p = default, the others = remembered), restart
---and let the normal measure-and-correct loop line everybody up.
function MSV2.resetPlayerPlacement(p, prior, doneMsg)
	local n = math.max(2, MSV2.numPlayers or 2)
	local savedPos = parseTriples(MSV2.getRule("engageplayerpos"), n)
	if (not savedPos or not prior) then
		MSV2.clearPlacement(true)
		return
	end
	local savedRot = parseTriples(MSV2.getRule("engageplayerrot"), n) or {}
	for i = 1, n do savedRot[i] = savedRot[i] or { 0, 0, 0 } end
	local f = {
		p = p, n = n, c0 = {}, yaw0 = {}, want = {}, tries = 0, phaseA = true,
		savedPos = savedPos, savedRot = savedRot, prior = prior,
		doneMsg = doneMsg, failMsg = "Reset, but couldn't line the players up exactly - check the start position"
	}
	local z = {}
	for i = 1, n do z[i] = "0,0,0" end
	MSV2.faceFlipped[p] = nil
	MSV2.setRule("engageplayerpos", "0")
	MSV2.setRule("engageplayerrot", table.concat(z, ","))
	MSV2.faceFix = f
	MSV2.restartMatch()
	f.wait = 12
end

---Per frame: once the restarted match has settled, check the result and correct it
function MSV2.tickFace()
	local f = MSV2.faceFix
	if (not f) then return end
	if (f.wait > 0) then f.wait = f.wait - 1; return end
	if (MSV2.needRefresh) then return end
	if (f.phaseA) then
		-- The match now starts with no custom rules: these are the default places
		local c, y = {}, {}
		for i = 0, f.n - 1 do
			c[i], y[i] = MSV2.playerWorldCenter(i), yawOf(i)
			if (not c[i] or not y[i]) then f.wait = 5; return end
		end
		local pos, rot = MSV2.startRules(f.n, c, y)
		for i = 0, f.n - 1 do
			if (i == f.p) then
				f.c0[i], f.want[i] = c[i], y[i]
			else
				pos[i + 1], rot[i + 1] = f.savedPos[i + 1], f.savedRot[i + 1]
				f.c0[i], f.want[i] = f.prior.c[i], f.prior.yaw[i]
			end
		end
		f.pos, f.rot = pos, rot
		f.phaseA = nil
		f.tries = 0
		applyFace(f)
		return
	end
	local worst, errs, perr = 0, {}, {}
	for i = 0, f.n - 1 do
		local c, y = MSV2.playerWorldCenter(i), yawOf(i)
		if (not c or not y) then f.wait = 5; return end
		errs[i] = angDiff(y, f.want[i])
		perr[i] = MSV2.V.sub(c, f.c0[i])
		worst = math.max(worst, math.abs(errs[i]))
	end
	local posBad = false
	for i = 0, f.n - 1 do
		if (MSV2.V.len({ perr[i][1], perr[i][2], perr[i][3] }) > 0.05) then posBad = true end
	end
	if (worst <= 3 and not posBad) then
		MSV2.faceFix = nil
		MSV2.toast(f.doneMsg or "Turned around")
		return
	end
	f.tries = f.tries + 1
	if (f.tries > 6) then
		MSV2.faceFix = nil
		MSV2.toast(f.failMsg or "Turned, but couldn't line the player up exactly - check the start position")
		return
	end
	if (worst > 3) then
		-- Rotation first. Try the error with the assumed sign, then the opposite sign.
		for i = 0, f.n - 1 do
			if (math.abs(errs[i]) > 3) then
				f.signTry = f.signTry or {}
				local last = f.signTry[i]
				if (last and math.abs(errs[i]) > math.abs(last.err) * 0.5) then
					-- That direction didn't help: go the other way from the original value
					f.rot[i + 1][3] = last.base + last.err * (last.dir == -1 and 1 or -1)
					f.signTry[i] = { base = last.base, err = last.err, dir = -last.dir }
				else
					f.signTry[i] = { base = f.rot[i + 1][3], err = errs[i], dir = -1 }
					f.rot[i + 1][3] = f.rot[i + 1][3] - errs[i]
				end
			end
		end
	else
		for i = 0, f.n - 1 do
			f.pos[i + 1] = MSV2.V.sub(f.pos[i + 1], perr[i])
		end
	end
	applyFace(f)
end

---------------------------------------------------------------------------
-- Project files (keeps names, groups, locks, parents and triangles - .tbm can't)
---------------------------------------------------------------------------

function MSV2.safeName(name)
	name = tostring(name or ""):gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if (name == "") then name = "Untitled" end
	return name
end

function MSV2.saveProject(name, silent)
	name = MSV2.safeName(name)
	local s = MSV2.snapshot()
	s.version = MSV2.VERSION
	local okm, msg = pcall(get_mod_message)
	local oku, um = pcall(get_mod_use_model)
	local okn, mn = pcall(get_mod_model_name)
	s.world = { message = okm and msg or nil, useModel = oku and um or nil, modelName = okn and mn or nil }
	local path = MSV2.PROJECT_DIR .. name .. ".msp"
	if (MSV2.writeFile(path, "return " .. MSV2.serialize(s))) then
		MSV2.changedSinceAutosave = false
		if (not silent) then
			MSV2.changed = false
			MSV2.toast("Saved project \"" .. name .. "\"")
		end
		return true
	end
	if (not silent) then
		MSV2.toast("Couldn't save - is data/script/modstudiov2/projectsv2/ missing?")
	end
	return false
end

function MSV2.loadProject(name)
	local data = MSV2.readData(MSV2.PROJECT_DIR .. name .. ".msp")
	if (not data or not data.objs) then
		MSV2.toast("Couldn't read project " .. tostring(name))
		return false
	end
	MSV2.pushUndo("Load project")
	MSV2.restore(data)
	if (data.world) then
		if (data.world.message) then pcall(set_mod_message, data.world.message) end
		if (data.world.useModel ~= nil) then pcall(set_mod_use_model, data.world.useModel) end
		if (data.world.modelName) then pcall(set_mod_model_name, data.world.modelName) end
	end
	MSV2.saveName = name ~= "_autosave" and name or MSV2.saveName
	MSV2.markDirty()
	MSV2.changed = false
	MSV2.toast("Loaded project \"" .. name .. "\"")
	return true
end

function MSV2.listProjects()
	local list = {}
	local ok, files = pcall(get_files, "data/script/modstudiov2/projectsv2", "")
	if (ok and type(files) == "table") then
		for _, v in pairs(files) do
			if (type(v) == "string" and v:match("%.msp$")) then
				table.insert(list, (v:gsub("%.msp$", "")))
			end
		end
	end
	table.sort(list)
	return list
end

function MSV2.listMods()
	local mods = {}
	local ok, files = pcall(get_files, "data/mod", "")
	if (ok and type(files) == "table") then
		for _, v in pairs(files) do
			if (type(v) == "string" and v:match("%.tbm$")) then table.insert(mods, v) end
		end
	end
	if (get_modmaker_files) then
		local ok2, files2 = pcall(get_modmaker_files, "data/mod/modmaker", "")
		if (ok2 and type(files2) == "table") then
			for _, v in pairs(files2) do
				if (type(v) == "string" and v:match("%.tbm$")) then table.insert(mods, "modmaker/" .. v) end
			end
		end
	end
	table.sort(mods)
	return mods
end

function MSV2.exportMod(name)
	name = MSV2.safeName(name)
	MSV2.flush(true)
	if (MSV2.settings.assetNote and MSV2.appendAssetNote and MSV2.assetReport) then
		local rep = MSV2.assetReport(true)
		if (#rep.order > 0) then pcall(MSV2.appendAssetNote, "list") end
	end
	local ok, written = pcall(export_mod_maker, name)
	if (ok and written) then
		MSV2.saveName = (tostring(written):gsub("^modmaker/", ""):gsub("%.tbm$", ""))
		MSV2.changed = false
		-- Keep a project file next to the export so names/triangles survive
		MSV2.saveProject(MSV2.saveName, true)
		MSV2.lastExport = tostring(written)
		local extra = MSV2.afterExport and MSV2.afterExport(written) or ""
		MSV2.toast("Exported data/mod/" .. tostring(written) .. " - load it from the Mods menu" .. (extra ~= "" and (" (" .. extra .. ")") or ""))
		echo("Mod Studio: exported " .. tostring(written))
		return written
	end
	MSV2.toast("Export failed - see the debug console for details")
	return nil
end

function MSV2.importMod(name)
	MSV2.pushUndo("Import " .. name)
	local ok, res = pcall(import_mod_into_maker, name)
	if (ok and res) then
		MSV2.meta, MSV2.tris = {}, {}
		MSV2.reloadAll()
		-- Per-object models live only in the file (the mod maker API can't see them)
		local nm = MSV2.readModelLines and MSV2.readModelLines(name) or 0
		if (nm > 0) then
			MSV2.toast("Imported " .. name .. " - " .. nm .. " object" .. (nm == 1 and "" or "s") .. " use 3D models")
		end
		MSV2.saveName = (name:gsub("^modmaker/", ""):gsub("%.tbm$", ""))
		MSV2.markDirty()
		MSV2.changed = false
		MSV2.toast("Imported " .. name)
		return true
	end
	MSV2.toast("Couldn't import " .. name)
	return false
end

---------------------------------------------------------------------------
-- Calibration: spawn a hidden probe box with a known raw rotation/size, read
-- back the orientation the engine actually built, and pick the matching units.
---------------------------------------------------------------------------

local PROBE_POS = { 321.5, -287.25, 55.5 }
local PROBE_ROT = { 40, 25, 10 }
local PROBE_DIMS = { 1, 2, 3 }

local function readRotTable(i)
	local res = { pcall(get_obj_rot, i) }
	if (not res[1]) then return nil end
	local r = {}
	if (type(res[2]) == "table") then
		local t = res[2]
		for n = 0, 11 do
			r[n] = t["r" .. n] or t[n + 1]
		end
	else
		for n = 0, 11 do r[n] = res[n + 2] end
	end
	for n = 0, 10 do
		if (type(r[n]) ~= "number" and n ~= 3 and n ~= 7) then return nil end
	end
	return {
		{ r[0], r[1], r[2] },
		{ r[4], r[5], r[6] },
		{ r[8], r[9], r[10] }
	}
end

local function matErr(a, b)
	local e = 0
	for i = 1, 3 do for j = 1, 3 do e = e + abs(a[i][j] - b[i][j]) end end
	return e
end

local function finishCalibration(result)
	local c = MSV2.calib
	c.done = true
	c.result = result
	if (c.probe) then
		pcall(delete_mod_envobj, c.probe)
		pcall(refresh_mod_maker_world)
	end
	if (not result) then
		echo("Mod Studio: couldn't measure the engine's rotation units, using saved settings (" .. MSV2.settings.rotUnit .. ")")
		return
	end
	local changed = result.rotUnit ~= MSV2.settings.rotUnit or result.conv ~= MSV2.settings.rotConvention or
		abs((result.sizeScale or 1) - MSV2.settings.sizeScale) > 1e-6
	MSV2.settings.rotUnit = result.rotUnit
	MSV2.settings.rotConvention = result.conv
	MSV2.settings.sizeScale = result.sizeScale or MSV2.settings.sizeScale
	MSV2.saveSettings()
	if (changed) then
		-- Re-read everything in the right units and rebuild triangles with them
		MSV2.reloadAll()
		for id in pairs(MSV2.tris) do MSV2.triBuild(id) end
		MSV2.flush(true)
		echo("Mod Studio: matched the engine (rotation in " .. (result.rotUnit == "rad" and "radians" or "degrees") ..
			", size scale " .. MSV2.fmt(MSV2.settings.sizeScale) .. ") - rotations and triangles now line up")
	end
end

function MSV2.startCalibration()
	MSV2.calib = { frames = 0 }
end

---Advances calibration by one frame. Call from draw3d until MSV2.calib.done.
function MSV2.calibrateStep()
	local c = MSV2.calib
	if (not c or c.done) then return end
	c.frames = c.frames + 1
	if (not c.probe) then
		local ok, idx = pcall(create_mod_envobj)
		if (not ok or idx == nil) then
			finishCalibration(nil)
			return
		end
		c.probe = idx
		local raw = {
			type = 1, static = true, color_a = 0,
			pos_x = PROBE_POS[1], pos_y = PROBE_POS[2], pos_z = PROBE_POS[3],
			rot_x = PROBE_ROT[1], rot_y = PROBE_ROT[2], rot_z = PROBE_ROT[3],
			dims_x = PROBE_DIMS[1], dims_y = PROBE_DIMS[2], dims_z = PROBE_DIMS[3]
		}
		for f, v in pairs(raw) do pcall(set_mod_envobj, idx, f, v) end
		pcall(refresh_mod_maker_world)
		return
	end

	-- Find the probe among the world's objects by its position
	local found
	local n = MSV2.count(MSV2.objs) + 6
	for i = 0, n do
		local ok, x, y, z = pcall(get_obj_pos, i)
		if (ok and type(x) == "number" and abs(x - PROBE_POS[1]) < 0.05 and abs(y - PROBE_POS[2]) < 0.05 and abs(z - PROBE_POS[3]) < 0.05) then
			found = i
			break
		end
	end
	if (not found) then
		if (c.frames > 45) then finishCalibration(nil) end
		return
	end
	local R = readRotTable(found)
	if (not R) then
		finishCalibration(nil)
		return
	end
	local best, bestErr = nil, math.huge
	for _, unit in ipairs({ "deg", "rad" }) do
		local f = unit == "rad" and (180 / math.pi) or 1
		local base = eulerZYX(PROBE_ROT[1] * f, PROBE_ROT[2] * f, PROBE_ROT[3] * f)
		for conv = 1, 2 do
			local cand = conv == 2 and M.transpose(base) or base
			local e = matErr(cand, R)
			if (e < bestErr) then best, bestErr = { rotUnit = unit, conv = conv }, e end
		end
	end
	if (bestErr > 0.15) then
		finishCalibration(nil)
		return
	end
	-- Size: world sides vs the raw dims we wrote
	local oks, sx, sy, sz = pcall(get_obj_sides, found)
	if (oks and type(sx) == "number" and sx > 0 and sy and sz) then
		local k = PROBE_DIMS[1] / sx
		if (abs(sy * k - PROBE_DIMS[2]) < 0.05 and abs(sz * k - PROBE_DIMS[3]) < 0.05) then
			for _, snap in ipairs({ 0.5, 1, 2 }) do
				if (abs(k - snap) < 0.02) then best.sizeScale = snap end
			end
		end
	end
	finishCalibration(best)
end

---------------------------------------------------------------------------
-- Reset to the default mod (what the classic editor's "Reset Everything" does)
---------------------------------------------------------------------------

MSV2.DEFAULT_MOD = "classic.tbm"

local RESET_LABELS = {
	all = "Reset everything", players = "Reset both players", rules = "Reset rules", [0] = "Reset Tori", [1] = "Reset Uke"
}

---what: "all" | "players" | "rules" | player index
function MSV2.resetTo(what)
	local label = RESET_LABELS[what] or "Reset"
	local keep = MSV2.snapshot()
	-- Whole-player placement lives in rules (engageplayerpos / engageplayerrot): note where
	-- everybody is drawn now, so a single-player reset can leave the others exactly there
	local hadPlacement = MSV2.hasCustomPlacement()
	local prior = (type(what) == "number" and hadPlacement) and MSV2.measurePlayers() or nil
	MSV2.faceFix = nil
	local okm, msg = pcall(get_mod_message)
	local oku, um = pcall(get_mod_use_model)
	local okn, mn = pcall(get_mod_model_name)
	-- Inside MSV2.withUndo the caller already recorded the undo step
	local pushed = not MSV2.undoSuppress
	MSV2.pushUndo(label)
	MSV2.endDragSilently()
	local ok, res = pcall(import_mod_into_maker, MSV2.DEFAULT_MOD)
	if (not ok or not res) then
		-- The import may have half-run: re-read the engine, then put everything back
		if (pushed) then table.remove(MSV2.undoStack) end
		MSV2.reloadAll()
		MSV2.restore(keep)
		MSV2.toast("Couldn't load the default mod (" .. MSV2.DEFAULT_MOD .. ") - nothing was changed")
		return false
	end
	MSV2.meta, MSV2.tris = {}, {}
	MSV2.reloadAll()
	if (what ~= "all") then
		-- Put back everything that isn't being reset
		local s = MSV2.deepcopy(keep)
		if (what == "players") then
			s.bodies, s.joints = nil, nil
		elseif (type(what) == "number") then
			if (s.bodies) then s.bodies[what] = nil end
			if (s.joints) then s.joints[what] = nil end
		elseif (what == "rules") then
			s.rules = nil
		end
		MSV2.restore(s)
		if (okm and msg) then pcall(set_mod_message, msg) end
		if (oku and um ~= nil) then pcall(set_mod_use_model, um) end
		if (okn and mn) then pcall(set_mod_model_name, mn) end
	end
	MSV2.markDirty()
	MSV2.selClear()
	-- Default position + facing (the game's own placement when the start rules are unset)
	local who = label:gsub("^Reset ", "")
	local toastMsg = label .. " done - Ctrl+Z undoes it"
	if (type(what) == "number") then
		toastMsg = who .. " reset to the default position - Ctrl+Z undoes it"
		if (hadPlacement) then
			-- The others keep their custom place: async measure-and-correct, toast when settled
			MSV2.resetPlayerPlacement(what, prior, who .. " reset to the default position")
			toastMsg = nil
		else
			MSV2.faceFlipped[what] = nil
		end
	elseif (hadPlacement or MSV2.hasCustomPlacement()) then
		MSV2.clearPlacement(true)
		toastMsg = label .. " done (players back at the default position) - Ctrl+Z undoes it"
	else
		MSV2.clearPlacement(false)
	end
	if (toastMsg) then MSV2.toast(toastMsg) end
	return true
end

function MSV2.clearAll()
	MSV2.pushUndo("Clear all objects")
	for idx in pairs(MSV2.ejs) do pcall(delete_mod_envjoint, idx) end
	for idx in pairs(MSV2.objs) do pcall(delete_mod_envobj, idx) end
	MSV2.objs, MSV2.ejs, MSV2.meta, MSV2.tris = {}, {}, {}, {}
	MSV2.markDirty()
	MSV2.selClear()
	MSV2.toast("Removed all objects (Ctrl+Z brings them back)")
end
