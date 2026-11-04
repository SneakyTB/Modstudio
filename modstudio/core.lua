-- Mod Studio: core data layer
-- Wraps the native mod maker API (get_mod_envobj/set_mod_envobj/...) with a
-- Lua-side cache, selection, undo/redo, triangles, generators and project files.

MS = MS or {}
local MS = MS

MS.VERSION = "1.0"
MS.HOOK = "modstudio"

local clock = os.clock_real or os.clock
MS.clock = clock

local sin, cos, atan2, asin, sqrt, abs, floor = math.sin, math.cos, math.atan2, math.asin, math.sqrt, math.abs, math.floor
local rad, deg = math.rad, math.deg

---------------------------------------------------------------------------
-- Generic helpers
---------------------------------------------------------------------------

function MS.deepcopy(v)
	if (type(v) ~= "table") then
		return v
	end
	local t = {}
	for k, val in pairs(v) do
		t[k] = MS.deepcopy(val)
	end
	return t
end

function MS.clamp(v, lo, hi)
	if (v < lo) then return lo end
	if (v > hi) then return hi end
	return v
end

function MS.round(v, step)
	step = step or 1
	if (step <= 0) then return v end
	return floor(v / step + 0.5) * step
end

function MS.fmt(v)
	if (type(v) ~= "number") then
		return tostring(v or "")
	end
	local s = string.format("%.3f", v)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	if (s == "-0") then s = "0" end
	return s
end

function MS.count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function MS.sortedKeys(t)
	local keys = {}
	for k in pairs(t or {}) do table.insert(keys, k) end
	table.sort(keys)
	return keys
end

---Serializes plain Lua data (numbers, strings, booleans, tables)
function MS.serialize(v)
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
				key = "[" .. MS.serialize(k) .. "]"
			else
				key = "[" .. string.format("%q", tostring(k)) .. "]"
			end
			table.insert(parts, key .. "=" .. MS.serialize(val))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

function MS.writeFile(path, content)
	local f = io.open(path, "w")
	if (not f) then
		return false
	end
	f:write(content)
	f:close()
	return true
end

function MS.readData(path)
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
-- Settings (persisted to data/script/modstudio/settings.cfg)
---------------------------------------------------------------------------

MS.SETTINGS_FILE = "modstudio/settings.cfg"
MS.PROJECT_DIR = "modstudio/projects/"

MS.DEFAULT_SETTINGS = {
	tool = "move",          -- select / move / rotate / scale
	space = "world",        -- world / local
	snap = true,
	gridStep = 0.25,
	rotStep = 15,
	scaleStep = 0.05,
	showGrid = true,
	gridExtent = 16,
	showLabels = false,
	showLinks = true,
	gizmoSize = 95,
	newStatic = true,
	autosave = true,
	autosaveMinutes = 1,    -- how often autosave runs (when something changed)
	rotConvention = 1,      -- 1: Rz*Ry*Rx (Toribash default), 2: transposed
	rotUnit = "deg",        -- units of rot_* in the engine API ("deg" / "rad"), measured by MS.calibrate
	sizeScale = 1,          -- engine dims per unit of full size, measured by MS.calibrate
	camMethod = "hook",     -- how to move the camera from a script: hook / native / hold
	camMethodOk = true,     -- true once camMethod is known to move the camera (hook confirmed in game)
	camFix = 0,             -- settings migration marker for the camera method
	objLimit = 0,           -- max env objects the game allows (0 = not measured yet)
	surfaceSnap = true,     -- dragged objects rest on the surface under the cursor
	showDojo = true,        -- draw the dojo outline on the floor
	symmetry = false,       -- mirror body/joint edits to the other side
	bodyGizmo = true,
	moveChildren = true,    -- moving a parent moves its children
	showHierarchy = true,   -- parent lines for the selection
	showAllHierarchy = false,
	scrollPush = true,      -- wheel pushes a click-dragged object along the view line
	altDuplicate = true,    -- Alt + gizmo drag drags out a copy
	layout = {},            -- moved / resized panels: side -> { x, y, w, h }
	uiScale = 1,            -- 0.85 / 1 / 1.15 / 1.3
	accent = "pink",        -- highlight color (see UI.ACCENTS)
	folded = { ["obj:thrust"] = true, ["obj:trigger"] = true, ["players:thrust"] = true, ["players:trigger"] = true,
		["players:tools"] = true, ["joints:trigger"] = true, ["joints:tools"] = true },
	firstRun = true,
	panelX = nil,
	panelY = nil
}

function MS.loadSettings()
	local s = MS.DEFAULT_SETTINGS
	MS.settings = MS.deepcopy(s)
	local saved = MS.readData(MS.SETTINGS_FILE)
	if (saved) then
		for k, v in pairs(saved) do
			if (MS.settings[k] ~= nil or k == "panelX" or k == "panelY") then
				MS.settings[k] = v
			end
		end
	end
	-- Earlier builds could wrongly switch away from the camera hook at the zoom limit
	if (MS.settings.camFix ~= 2) then
		MS.settings.camMethod = "hook"
		MS.settings.camMethodOk = true
		MS.settings.camFix = 2
	end
end

function MS.saveSettings()
	MS.writeFile(MS.SETTINGS_FILE, "return " .. MS.serialize(MS.settings))
end

---------------------------------------------------------------------------
-- Vector / matrix math (vectors are {x, y, z}, matrices are 3x3 m[row][col])
---------------------------------------------------------------------------

local V = {}
MS.V = V

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
MS.M = M

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
	local r31 = MS.clamp(R[3][1], -1, 1)
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
	if (MS.settings and MS.settings.rotConvention == 2) then
		return M.transpose(R)
	end
	return R
end

---Rotation matrix to euler (degrees), inverse of M.fromEuler
function M.toEuler(R)
	if (MS.settings and MS.settings.rotConvention == 2) then
		R = M.transpose(R)
	end
	local x, y, z = matToZYX(R)
	local function clean(a)
		a = MS.round(a, 0.001)
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

MS.SHAPES = { [0] = "Sphere", [1] = "Box", [2] = "Cylinder" }

MS.TRIG_FIELDS = { "trig_id", "trig_mask", "trig_action", "trig_sound", "trig_color_r", "trig_color_g", "trig_color_b", "trig_color_a", "trig_score", "trig_scoreonce" }

MS.ENV_FIELDS = {
	"type", "pos_x", "pos_y", "pos_z", "rot_x", "rot_y", "rot_z", "dims_x", "dims_y", "dims_z", "mass",
	"color_r", "color_g", "color_b", "color_a", "visible", "static", "force_x", "force_y", "force_z",
	"hardness", "friction", "bounce", "thrust_frames", "thrust_x", "thrust_y", "thrust_z", "thrust_relative"
}
for _, f in ipairs(MS.TRIG_FIELDS) do table.insert(MS.ENV_FIELDS, f) end

MS.BODY_FIELDS = {
	"type", "pos_x", "pos_y", "pos_z", "rot_x", "rot_y", "rot_z", "sides_x", "sides_y", "sides_z",
	"altsides_x", "altsides_y", "altsides_z", "force_x", "force_y", "force_z",
	"density", "hardness", "friction", "bounce", "thrust_frames", "thrust_x", "thrust_y", "thrust_z", "thrust_relative"
}
for _, f in ipairs(MS.TRIG_FIELDS) do table.insert(MS.BODY_FIELDS, f) end

MS.JOINT_FIELDS = {
	"pos_x", "pos_y", "pos_z", "axis_x", "axis_y", "axis_z", "histop", "lostop", "maxforce", "maxvelocity",
	"radius", "density", "hardness", "friction", "bounce"
}
for _, f in ipairs(MS.TRIG_FIELDS) do table.insert(MS.JOINT_FIELDS, f) end

MS.EJ_FIELDS = {
	"obj1", "obj2", "type", "pos_x", "pos_y", "pos_z", "axis_x", "axis_y", "axis_z",
	"histop", "lostop", "maxforce", "maxvelocity", "hardness", "bounce", "visible"
}

MS.BOOL_FIELDS = { visible = true, static = true, thrust_relative = true, trig_scoreonce = true }

MS.BODY_NAMES = {
	[0] = "Head", "Breast", "Chest", "Stomach", "Thorax",
	"R Pecs", "R Biceps", "R Triceps", "L Pecs", "L Biceps", "L Triceps",
	"R Hand", "L Hand", "R Butt", "L Butt",
	"R Thigh", "L Thigh", "L Leg", "R Leg", "R Foot", "L Foot"
}
MS.NUM_BODIES = 21

MS.JOINT_NAMES = {
	[0] = "Neck", "Chest", "Lumbar", "Abs",
	"R Pecs", "R Shoulder", "R Elbow",
	"L Pecs", "L Shoulder", "L Elbow",
	"R Wrist", "L Wrist",
	"R Glute", "L Glute",
	"R Hip", "L Hip",
	"R Knee", "L Knee", "R Ankle", "L Ankle"
}
MS.NUM_JOINTS = 20

MS.BODY_MIRROR = { [5] = 8, [8] = 5, [6] = 9, [9] = 6, [7] = 10, [10] = 7, [11] = 12, [12] = 11,
	[13] = 14, [14] = 13, [15] = 16, [16] = 15, [17] = 18, [18] = 17, [19] = 20, [20] = 19 }
MS.JOINT_MIRROR = { [4] = 7, [7] = 4, [5] = 8, [8] = 5, [6] = 9, [9] = 6, [10] = 11, [11] = 10,
	[12] = 13, [13] = 12, [14] = 15, [15] = 14, [16] = 17, [17] = 16, [18] = 19, [19] = 18 }

-- Fields that failed to read in this client version; the UI hides them
MS.unsupported = MS.unsupported or { env = {}, body = {}, joint = {}, ej = {} }

local function normalize(field, v)
	if (MS.BOOL_FIELDS[field]) then
		return v == true or v == 1
	end
	return v
end

---------------------------------------------------------------------------
-- Engine units. Mod Studio always works in degrees and full box sizes; the
-- engine API may use radians / half sizes. MS.calibrate() measures which.
---------------------------------------------------------------------------

MS.ROT_FIELDS = { rot_x = true, rot_y = true, rot_z = true }
MS.SIZE_FIELDS = { dims_x = true, dims_y = true, dims_z = true, sides_x = true, sides_y = true, sides_z = true,
	altsides_x = true, altsides_y = true, altsides_z = true }

---Engine units per degree / per unit of full size
function MS.rotK() return (MS.settings and MS.settings.rotUnit == "rad") and (math.pi / 180) or 1 end
function MS.sizeK() return (MS.settings and MS.settings.sizeScale) or 1 end

local function fromEngine(f, v)
	if (type(v) ~= "number") then return v end
	if (MS.ROT_FIELDS[f]) then return v / MS.rotK() end
	if (MS.SIZE_FIELDS[f]) then return v / MS.sizeK() end
	return v
end

local function toEngine(f, v)
	if (type(v) ~= "number") then return v end
	if (MS.ROT_FIELDS[f]) then return v * MS.rotK() end
	if (MS.SIZE_FIELDS[f]) then return v * MS.sizeK() end
	return v
end
MS.toEngine, MS.fromEngine = toEngine, fromEngine

---------------------------------------------------------------------------
-- Cache + engine writes
---------------------------------------------------------------------------

MS.objs = MS.objs or {}      -- env object index -> field table
MS.ejs = MS.ejs or {}        -- env joint index -> field table
MS.bodies = MS.bodies or {}  -- [player][body] -> field table
MS.joints = MS.joints or {}  -- [player][joint] -> field table
MS.meta = MS.meta or {}      -- env object index -> { name, group, locked, tri, uid, parent }
MS.tris = MS.tris or {}      -- triangle id -> triangle definition
MS.nextTri = MS.nextTri or 1
MS.numPlayers = MS.numPlayers or 2

function MS.markDirty()
	MS.needRefresh = true
	MS.changed = true
	MS.changedSinceAutosave = true
	MS.lastEditClock = clock()
end

---How long a world rebuild takes (smoothed, seconds) - see MS.flush
MS.refreshCost = MS.refreshCost or 0
MS.lastRefresh = MS.lastRefresh or 0

---Gap to leave between world rebuilds while editing. Cheap rebuilds aren't
---held back at all; slow ones (big mods) run at most ~every 3x their cost.
function MS.refreshInterval()
	local cost = MS.refreshCost or 0
	if (cost < 0.004) then return 0 end
	return MS.clamp(cost * 3, 0.016, 0.25)
end

---Rebuilds the mod maker world if anything changed. The game rebuilds every
---object and player each time, which is what made editing laggy, so repeated
---changes (scrubbing, typing, dragging) are batched unless `force` is set.
function MS.flush(force)
	if (not MS.needRefresh) then return end
	local now = clock()
	if (not force and now - (MS.lastRefresh or 0) < MS.refreshInterval()) then
		return
	end
	MS.needRefresh = false
	pcall(refresh_mod_maker_world)
	local after = clock()
	local took = math.max(0, after - now)
	-- Smooth so one slow frame doesn't throttle everything
	MS.refreshCost = (MS.refreshCost or 0) * 0.7 + took * 0.3
	MS.lastRefresh = after
end

function MS.readObj(idx)
	local o = {}
	for _, f in ipairs(MS.ENV_FIELDS) do
		if (not MS.unsupported.env[f]) then
			local ok, v = pcall(get_mod_envobj, idx, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, fromEngine(f, v))
			elseif (not ok) then
				MS.unsupported.env[f] = true
			end
		end
	end
	o.type = o.type or 1
	MS.objs[idx] = o
	return o
end

function MS.readEJ(idx)
	local o = {}
	for _, f in ipairs(MS.EJ_FIELDS) do
		if (not MS.unsupported.ej[f]) then
			local ok, v = pcall(get_mod_envjoint, idx, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, v)
			elseif (not ok) then
				MS.unsupported.ej[f] = true
			end
		end
	end
	MS.ejs[idx] = o
	return o
end

function MS.readBody(p, b)
	local o = {}
	for _, f in ipairs(MS.BODY_FIELDS) do
		if (not MS.unsupported.body[f]) then
			local ok, v = pcall(get_mod_body, p, b, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, fromEngine(f, v))
			elseif (not ok) then
				if (tostring(v):find("player index")) then
					return nil
				end
				MS.unsupported.body[f] = true
			end
		end
	end
	MS.bodies[p] = MS.bodies[p] or {}
	MS.bodies[p][b] = o
	return o
end

function MS.readJoint(p, j)
	local o = {}
	for _, f in ipairs(MS.JOINT_FIELDS) do
		if (not MS.unsupported.joint[f]) then
			local ok, v = pcall(get_mod_joint, p, j, f)
			if (ok and v ~= nil) then
				o[f] = normalize(f, v)
			elseif (not ok) then
				if (tostring(v):find("player index")) then
					return nil
				end
				MS.unsupported.joint[f] = true
			end
		end
	end
	MS.joints[p] = MS.joints[p] or {}
	MS.joints[p][j] = o
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

function MS.activeObjIndices() return activeList(get_active_mod_envobjs) end
function MS.activeEJIndices() return activeList(get_active_mod_envjoints) end

---Re-reads everything from the engine. Keeps metadata for indices that still exist.
function MS.reloadAll()
	local oldMeta = MS.meta or {}
	MS.objs, MS.ejs, MS.meta = {}, {}, {}
	for _, idx in ipairs(MS.activeObjIndices()) do
		MS.readObj(idx)
		MS.meta[idx] = oldMeta[idx] or {}
	end
	for _, idx in ipairs(MS.activeEJIndices()) do
		MS.readEJ(idx)
	end
	-- Drop triangles whose slices no longer exist
	for id, t in pairs(MS.tris) do
		local alive = {}
		for _, idx in ipairs(t.objs) do
			if (MS.objs[idx]) then
				table.insert(alive, idx)
				MS.meta[idx].tri = id
			end
		end
		t.objs = alive
		if (#alive == 0) then
			MS.tris[id] = nil
		end
	end
	MS.bodies, MS.joints = {}, {}
	MS.numPlayers = 0
	local okr, rule = pcall(get_gamerule, "numplayers")
	local maxPlayers = MS.clamp(okr and tonumber(rule) or 2, 2, 4)
	for p = 0, maxPlayers - 1 do
		if (MS.readBody(p, 0) == nil) then
			break
		end
		for b = 1, MS.NUM_BODIES - 1 do MS.readBody(p, b) end
		for j = 0, MS.NUM_JOINTS - 1 do MS.readJoint(p, j) end
		MS.numPlayers = p + 1
	end
	if (MS.hierFix) then MS.hierFix() end
	MS.selClear()
end

function MS.objSet(idx, f, v)
	local o = MS.objs[idx]
	if (not o or MS.unsupported.env[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_envobj, idx, f, toEngine(f, v))
	-- Keep triangle-wide properties in sync so rebuilds keep them
	local m = MS.meta[idx]
	if (m and m.tri and MS.tris[m.tri] and MS.TRI_PROPS[f]) then
		local t = MS.tris[m.tri]
		if (f == "mass") then
			t.props.mass = v * math.max(1, #t.objs)
		else
			t.props[f] = v
		end
	end
	MS.markDirty()
end

function MS.ejSet(idx, f, v)
	local o = MS.ejs[idx]
	if (not o or MS.unsupported.ej[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_envjoint, idx, f, v)
	MS.markDirty()
end

function MS.bodySet(p, b, f, v)
	local o = MS.bodies[p] and MS.bodies[p][b]
	if (not o or MS.unsupported.body[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_body, p, b, f, toEngine(f, v))
	MS.markDirty()
end

function MS.jointSet(p, j, f, v)
	local o = MS.joints[p] and MS.joints[p][j]
	if (not o or MS.unsupported.joint[f]) then
		return
	end
	v = normalize(f, v)
	o[f] = v
	pcall(set_mod_joint, p, j, f, v)
	MS.markDirty()
end

function MS.objPos(idx)
	local o = MS.objs[idx]
	return { o.pos_x or 0, o.pos_y or 0, o.pos_z or 0 }
end

function MS.objRot(idx)
	local o = MS.objs[idx]
	return M.fromEuler(o.rot_x, o.rot_y, o.rot_z)
end

function MS.setObjPos(idx, p)
	MS.objSet(idx, "pos_x", p[1])
	MS.objSet(idx, "pos_y", p[2])
	MS.objSet(idx, "pos_z", p[3])
end

function MS.setObjRot(idx, R)
	local x, y, z = M.toEuler(R)
	MS.objSet(idx, "rot_x", x)
	MS.objSet(idx, "rot_y", y)
	MS.objSet(idx, "rot_z", z)
end

---Full box extents of a shape in its local frame (used for outlines / floor drop)
function MS.shapeExtents(shape, dx, dy, dz)
	dx, dy, dz = dx or 0, dy or 0, dz or 0
	if (shape == 0) then
		return { dx * 2, dx * 2, dx * 2 }
	elseif (shape == 2) then
		return { dx * 2, dx * 2, dy + dx * 2 }
	end
	return { dx, dy, dz }
end

function MS.objExtents(idx)
	local o = MS.objs[idx]
	return MS.shapeExtents(o.type, o.dims_x, o.dims_y, o.dims_z)
end

---Lowest world Z of an object's oriented bounding box
function MS.objBottom(idx)
	local p = MS.objPos(idx)
	local R = MS.objRot(idx)
	local e = MS.objExtents(idx)
	if (MS.objs[idx].type == 0) then
		return p[3] - e[3] / 2
	end
	local h = abs(R[3][1]) * e[1] / 2 + abs(R[3][2]) * e[2] / 2 + abs(R[3][3]) * e[3] / 2
	return p[3] - h
end

function MS.objName(idx)
	local m = MS.meta[idx]
	if (m and m.name and m.name ~= "") then
		return m.name
	end
	local o = MS.objs[idx]
	if (m and m.tri) then
		return "Triangle " .. m.tri
	end
	return (MS.SHAPES[o and o.type or 1] or "Object") .. " " .. idx
end

---------------------------------------------------------------------------
-- Toasts / status
---------------------------------------------------------------------------

function MS.toast(msg)
	MS.toastMsg = msg
	MS.toastClock = clock()
end

---------------------------------------------------------------------------
-- Selection (env objects). Selecting a triangle slice selects the whole triangle.
---------------------------------------------------------------------------

MS.sel = MS.sel or {}
MS.primary = MS.primary or nil

local function selChanged()
	if (MS.UI and MS.UI.requestRefresh) then
		MS.UI.requestRefresh()
	end
end

function MS.selClear()
	MS.sel = {}
	MS.primary = nil
	MS.vertexSel = nil
	selChanged()
end

local function addWithTri(idx)
	local m = MS.meta[idx]
	if (m and m.tri and MS.tris[m.tri]) then
		for _, i in ipairs(MS.tris[m.tri].objs) do
			MS.sel[i] = true
		end
	else
		MS.sel[idx] = true
	end
end

function MS.selSet(idx)
	MS.sel = {}
	MS.vertexSel = nil
	if (idx and MS.objs[idx]) then
		addWithTri(idx)
		MS.primary = idx
	else
		MS.primary = nil
	end
	selChanged()
end

function MS.selAdd(idx)
	if (idx and MS.objs[idx]) then
		addWithTri(idx)
		MS.primary = idx
		selChanged()
	end
end

function MS.selToggle(idx)
	if (not idx or not MS.objs[idx]) then return end
	if (MS.sel[idx]) then
		local m = MS.meta[idx]
		if (m and m.tri and MS.tris[m.tri]) then
			for _, i in ipairs(MS.tris[m.tri].objs) do MS.sel[i] = nil end
		else
			MS.sel[idx] = nil
		end
		if (MS.primary == idx or not MS.sel[MS.primary or -1]) then
			MS.primary = MS.selList()[1]
		end
		selChanged()
	else
		MS.selAdd(idx)
	end
end

function MS.selAll()
	MS.sel = {}
	for idx in pairs(MS.objs) do
		if (not (MS.meta[idx] and MS.meta[idx].locked)) then
			MS.sel[idx] = true
			MS.primary = MS.primary or idx
		end
	end
	if (MS.primary and not MS.sel[MS.primary]) then
		MS.primary = MS.selList()[1]
	end
	selChanged()
end

function MS.selList()
	local list = {}
	for idx in pairs(MS.sel) do
		if (MS.objs[idx]) then
			table.insert(list, idx)
		else
			MS.sel[idx] = nil
		end
	end
	table.sort(list)
	return list
end

function MS.selCount()
	return #MS.selList()
end

---Selected triangles (set of ids) and plain (non-triangle) objects
function MS.selSplit()
	local tris, plain = {}, {}
	for _, idx in ipairs(MS.selList()) do
		local m = MS.meta[idx]
		if (m and m.tri and MS.tris[m.tri]) then
			tris[m.tri] = true
		else
			table.insert(plain, idx)
		end
	end
	return tris, plain
end

---The single selected triangle, if the selection is exactly one triangle
function MS.selSingleTri()
	local tris, plain = MS.selSplit()
	if (#plain > 0) then return nil end
	local id, n = nil, 0
	for t in pairs(tris) do id = t; n = n + 1 end
	if (n == 1) then return id end
	return nil
end

function MS.selCenter()
	local list = MS.selList()
	if (#list == 0) then return nil end
	local tris, plain = MS.selSplit()
	local sum, n = { 0, 0, 0 }, 0
	for _, idx in ipairs(plain) do
		sum = V.add(sum, MS.objPos(idx)); n = n + 1
	end
	for id in pairs(tris) do
		sum = V.add(sum, MS.triCentroid(id)); n = n + 1
	end
	return V.mul(sum, 1 / n)
end

---------------------------------------------------------------------------
-- Undo / redo (whole-scene snapshots, coalesced for typing)
---------------------------------------------------------------------------

MS.undoStack = MS.undoStack or {}
MS.redoStack = MS.redoStack or {}
MS.MAX_UNDO = 80

function MS.snapshot()
	return {
		objs = MS.deepcopy(MS.objs),
		ejs = MS.deepcopy(MS.ejs),
		meta = MS.deepcopy(MS.meta),
		tris = MS.deepcopy(MS.tris),
		bodies = MS.deepcopy(MS.bodies),
		joints = MS.deepcopy(MS.joints),
		rules = MS.readRules and MS.readRules() or nil,
		nextTri = MS.nextTri
	}
end

---Records the current state before a change. Calls with the same `key`
---within a short time are merged so typing a number is one undo step.
---Runs `fn` as a single undo step: everything it changes undoes in one Ctrl+Z
function MS.withUndo(label, fn)
	MS.pushUndo(label)
	local was = MS.undoSuppress
	MS.undoSuppress = true
	local ok, err = pcall(fn)
	MS.undoSuppress = was
	if (not ok) then
		echo("Mod Studio error: " .. tostring(err))
	end
	return ok
end

function MS.pushUndo(label, key)
	if (MS.undoSuppress) then return end
	local now = clock()
	if (key and MS.lastUndoKey == key and now - (MS.lastUndoTime or 0) < 1.5) then
		MS.lastUndoTime = now
		return
	end
	MS.lastUndoKey = key
	MS.lastUndoTime = now
	table.insert(MS.undoStack, { label = label or "Edit", snap = MS.snapshot() })
	if (#MS.undoStack > MS.MAX_UNDO) then
		table.remove(MS.undoStack, 1)
	end
	MS.redoStack = {}
end

local function sameKeys(a, b)
	for k in pairs(a) do if (b[k] == nil) then return false end end
	for k in pairs(b) do if (a[k] == nil) then return false end end
	return true
end

local function writeObjFields(idx, fields, skipSame)
	local cur = MS.objs[idx]
	if (fields.type ~= nil and (not skipSame or cur.type ~= fields.type)) then
		MS.objSet(idx, "type", fields.type)
	end
	for _, f in ipairs(MS.ENV_FIELDS) do
		local v = fields[f]
		if (f ~= "type" and v ~= nil and (not skipSame or cur[f] ~= v)) then
			MS.objSet(idx, f, v)
		end
	end
end
MS.writeObjFields = writeObjFields

local function writeEJFields(idx, fields, skipSame)
	local cur = MS.ejs[idx]
	for _, f in ipairs(MS.EJ_FIELDS) do
		local v = fields[f]
		if (v ~= nil and f ~= "obj1" and f ~= "obj2" and (not skipSame or cur[f] ~= v)) then
			MS.ejSet(idx, f, v)
		end
	end
end

---True if the game still has every object in the cache
local function engineHasAll()
	local active = {}
	for _, idx in ipairs(MS.activeObjIndices()) do active[idx] = true end
	for idx in pairs(MS.objs) do
		if (not active[idx]) then return false end
	end
	return true
end

---Restores a snapshot. With `forceRecreate` (or when the game has lost objects)
---every object is rebuilt instead of only writing changed fields.
function MS.restore(s, forceRecreate)
	MS.endDragSilently()
	local map = {}
	local sameObjs = not forceRecreate and sameKeys(MS.objs, s.objs) and engineHasAll()
	if (sameObjs) then
		for idx, fields in pairs(s.objs) do
			writeObjFields(idx, fields, true)
			map[idx] = idx
		end
	else
		for idx in pairs(MS.ejs) do pcall(delete_mod_envjoint, idx) end
		MS.ejs = {}
		for idx in pairs(MS.objs) do pcall(delete_mod_envobj, idx) end
		MS.objs = {}
		for _, old in ipairs(MS.sortedKeys(s.objs)) do
			local ok, n = pcall(create_mod_envobj)
			if (ok and n ~= nil) then
				MS.readObj(n)
				writeObjFields(n, s.objs[old], false)
				map[old] = n
			end
		end
	end

	-- Env joints
	if (sameObjs and sameKeys(MS.ejs, s.ejs)) then
		for idx, fields in pairs(s.ejs) do
			local cur = MS.ejs[idx]
			if (cur.obj1 == fields.obj1 and cur.obj2 == fields.obj2) then
				writeEJFields(idx, fields, true)
			end
		end
	else
		for idx in pairs(MS.ejs) do pcall(delete_mod_envjoint, idx) end
		MS.ejs = {}
		for _, old in ipairs(MS.sortedKeys(s.ejs)) do
			local f = s.ejs[old]
			local o1, o2 = map[f.obj1], map[f.obj2]
			if (o1 and o2) then
				local ok, n = pcall(create_mod_envjoint, o1, o2)
				if (ok and n ~= nil) then
					MS.readEJ(n)
					writeEJFields(n, f, false)
				end
			end
		end
	end

	-- Metadata + triangles, remapped to new indices
	MS.meta = {}
	for old, m in pairs(s.meta) do
		if (map[old]) then MS.meta[map[old]] = MS.deepcopy(m) end
	end
	for idx in pairs(MS.objs) do MS.meta[idx] = MS.meta[idx] or {} end
	MS.tris = {}
	for id, t in pairs(s.tris) do
		local nt = MS.deepcopy(t)
		nt.objs = {}
		for _, old in ipairs(t.objs) do
			if (map[old]) then table.insert(nt.objs, map[old]) end
		end
		MS.tris[id] = nt
	end
	MS.nextTri = s.nextTri or MS.nextTri

	-- Players
	for p, parts in pairs(s.bodies or {}) do
		for b, fields in pairs(parts) do
			local cur = MS.bodies[p] and MS.bodies[p][b]
			if (cur) then
				for f, v in pairs(fields) do
					if (cur[f] ~= v) then MS.bodySet(p, b, f, v) end
				end
			end
		end
	end
	for p, parts in pairs(s.joints or {}) do
		for j, fields in pairs(parts) do
			local cur = MS.joints[p] and MS.joints[p][j]
			if (cur) then
				for f, v in pairs(fields) do
					if (cur[f] ~= v) then MS.jointSet(p, j, f, v) end
				end
			end
		end
	end

	MS.applyRules(s.rules)
	if (MS.hierFix) then MS.hierFix() end

	MS.markDirty()
	MS.selClear()
end

---The game's mod maker can drop its objects on its own (seen when moving Tori's
---head). If objects Mod Studio knows about are gone from the game, rebuild them
---from the cache. Returns how many were missing.
function MS.repairEngine()
	local active = {}
	for _, idx in ipairs(MS.activeObjIndices()) do active[idx] = true end
	local missing = 0
	for idx in pairs(MS.objs) do
		if (not active[idx]) then missing = missing + 1 end
	end
	local ejMissing = 0
	local activeEJ = {}
	for _, idx in ipairs(MS.activeEJIndices()) do activeEJ[idx] = true end
	for idx in pairs(MS.ejs) do
		if (not activeEJ[idx]) then ejMissing = ejMissing + 1 end
	end
	if (missing == 0 and ejMissing == 0) then return 0 end
	MS.restore(MS.snapshot(), true)
	-- Whatever dropped the objects may have reloaded the players too: push ours back
	MS.pushPlayersToEngine()
	MS.flush(true)
	echo("Mod Studio: the game dropped " .. missing .. " object" .. (missing == 1 and "" or "s") ..
		(ejMissing > 0 and (" and " .. ejMissing .. " link" .. (ejMissing == 1 and "" or "s")) or "") ..
		" from the mod maker - rebuilt them from Mod Studio's copy.")
	MS.toast("Restored " .. missing .. " objects the game dropped")
	return missing
end

---Writes every cached body part / joint field to the game
function MS.pushPlayersToEngine()
	for p, parts in pairs(MS.bodies) do
		for b, fields in pairs(parts) do
			for f, v in pairs(fields) do
				if (not MS.unsupported.body[f]) then pcall(set_mod_body, p, b, f, toEngine(f, v)) end
			end
		end
	end
	for p, parts in pairs(MS.joints) do
		for j, fields in pairs(parts) do
			for f, v in pairs(fields) do
				if (not MS.unsupported.joint[f]) then pcall(set_mod_joint, p, j, f, toEngine(f, v)) end
			end
		end
	end
	MS.needRefresh = true
end

---Called every frame; checks the game still has everything about once a second
function MS.tickRepair()
	local now = clock()
	if (MS.G and MS.G.drag) then return end
	if (MS.lastRepairCheck and now - MS.lastRepairCheck < 1) then return end
	MS.lastRepairCheck = now
	pcall(MS.repairEngine)
end

function MS.undo()
	local e = table.remove(MS.undoStack)
	if (not e) then
		MS.toast("Nothing to undo")
		return
	end
	table.insert(MS.redoStack, { label = e.label, snap = MS.snapshot() })
	MS.restore(e.snap)
	MS.lastUndoKey = nil
	MS.toast("Undo: " .. e.label)
end

function MS.redo()
	local e = table.remove(MS.redoStack)
	if (not e) then
		MS.toast("Nothing to redo")
		return
	end
	table.insert(MS.undoStack, { label = e.label, snap = MS.snapshot() })
	MS.restore(e.snap)
	MS.lastUndoKey = nil
	MS.toast("Redo: " .. e.label)
end

---------------------------------------------------------------------------
-- Creating / deleting objects
---------------------------------------------------------------------------

MS.PALETTE = {
	{ 0.90, 0.30, 0.25 }, { 0.95, 0.60, 0.20 }, { 0.98, 0.85, 0.25 }, { 0.45, 0.80, 0.30 },
	{ 0.25, 0.70, 0.65 }, { 0.30, 0.55, 0.95 }, { 0.55, 0.40, 0.90 }, { 0.90, 0.45, 0.75 },
	{ 0.95, 0.95, 0.95 }, { 0.65, 0.65, 0.68 }, { 0.35, 0.35, 0.38 }, { 0.10, 0.10, 0.12 },
	{ 0.55, 0.35, 0.20 }, { 0.80, 0.70, 0.50 }, { 0.20, 0.35, 0.20 }, { 0.15, 0.20, 0.40 }
}
MS.paletteCursor = MS.paletteCursor or 0

function MS.nextColor()
	MS.paletteCursor = MS.paletteCursor % 8 + 1
	return MS.PALETTE[MS.paletteCursor]
end

---Ground point the camera is looking at, snapped to the grid
function MS.spawnPoint()
	if (MS.spawnOverride) then return V.copy(MS.spawnOverride) end
	local p = { 0, 0, 0 }
	local ok, cam = pcall(get_camera_info)
	if (ok and cam and cam.lookat) then
		p = { cam.lookat.x, cam.lookat.y, 0 }
	end
	local step = MS.settings.gridStep > 0 and MS.settings.gridStep or 0.25
	p[1] = MS.round(p[1], step)
	p[2] = MS.round(p[2], step)
	-- Nudge away from existing objects so new ones don't stack inside each other
	for _ = 1, 12 do
		local clash = false
		for idx in pairs(MS.objs) do
			local q = MS.objPos(idx)
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
function MS.noteObjectLimit()
	local n = #MS.activeObjIndices()
	if (n > 0 and MS.settings.objLimit ~= n) then
		MS.settings.objLimit = n
		MS.saveSettings()
	end
	return n
end

---Finds the env object limit by creating placeholders until the game says no,
---then removes them. Returns the limit or nil.
function MS.measureObjectLimit()
	local made = {}
	local cap = 10000
	for _ = 1, cap do
		local ok, idx = pcall(create_mod_envobj)
		if (not ok or idx == nil) then break end
		table.insert(made, idx)
	end
	local limit = #MS.activeObjIndices()
	for _, idx in ipairs(made) do pcall(delete_mod_envobj, idx) end
	pcall(refresh_mod_maker_world)
	if (#made >= cap or limit == 0) then return nil end
	MS.settings.objLimit = limit
	MS.saveSettings()
	return limit
end

---Creates an env object. `fields` overrides defaults. Returns the index or nil.
function MS.createObj(fields, meta)
	local ok, idx = pcall(create_mod_envobj)
	if (not ok or idx == nil) then
		local n = MS.noteObjectLimit()
		MS.toast("The game won't allow more objects (limit " .. n .. "). Delete some or lower triangle Smoothness")
		return nil
	end
	MS.readObj(idx)
	MS.meta[idx] = meta or {}
	local defaults = {
		rot_x = 0, rot_y = 0, rot_z = 0,
		static = MS.settings.newStatic, visible = true, color_a = 1
	}
	for k, v in pairs(defaults) do
		if (fields[k] == nil) then fields[k] = v end
	end
	writeObjFields(idx, fields, false)
	MS.markDirty()
	local limit = MS.settings.objLimit or 0
	local n = MS.count(MS.objs)
	if (limit > 0 and n >= limit * 0.9 and (MS.lastLimitWarn or 0) < clock() - 20) then
		MS.lastLimitWarn = clock()
		MS.toast("Heads up: " .. n .. " of " .. limit .. " objects used (see the Stats tab)")
	end
	return idx
end

---Creates a primitive at the spawn point. kind: box/sphere/cylinder/floor/wall/pillar/platform/ball
function MS.addPrimitive(kind)
	MS.pushUndo("Add " .. kind)
	local p = MS.spawnPoint()
	local c = MS.nextColor()
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
	local idx = MS.createObj(f, { name = name })
	if (idx) then
		MS.selSet(idx)
		MS.toast("Added " .. MS.objName(idx) .. " - drag the arrows to move it")
	end
	return idx
end

function MS.deleteObjRaw(idx)
	-- Remove links that reference this object first
	for j, ej in pairs(MS.ejs) do
		if (ej.obj1 == idx or ej.obj2 == idx) then
			pcall(delete_mod_envjoint, j)
			MS.ejs[j] = nil
		end
	end
	pcall(delete_mod_envobj, idx)
	MS.objs[idx] = nil
	local m = MS.meta[idx]
	MS.meta[idx] = nil
	if (m and m.tri and MS.tris[m.tri]) then
		local t = MS.tris[m.tri]
		for i = #t.objs, 1, -1 do
			if (t.objs[i] == idx) then table.remove(t.objs, i) end
		end
		if (#t.objs == 0) then MS.tris[m.tri] = nil end
	end
	MS.sel[idx] = nil
	MS.markDirty()
end

function MS.deleteSelected()
	local list = MS.selList()
	if (#list == 0) then
		MS.toast("Nothing selected")
		return
	end
	MS.pushUndo("Delete")
	-- Children of deleted objects stay, moving up to the nearest surviving parent
	local orphans = 0
	if (MS.hierBeforeDelete) then
		local set = MS.selKeys()
		local H = MS.hier()
		for k in pairs(set) do
			for _, c in ipairs(H.children[k] or {}) do
				if (not set[c]) then orphans = orphans + 1 end
			end
		end
		MS.hierBeforeDelete(set)
	end
	local tris = MS.selSplit()
	for id in pairs(tris) do MS.tris[id] = nil end
	for _, idx in ipairs(list) do
		if (MS.meta[idx]) then MS.meta[idx].tri = nil end
		MS.deleteObjRaw(idx)
	end
	if (MS.hierFix) then MS.hierFix() end
	MS.selClear()
	MS.toast("Deleted " .. #list .. " object" .. (#list == 1 and "" or "s") ..
		(orphans > 0 and (" - kept " .. orphans .. " child" .. (orphans == 1 and "" or "ren") .. " (use Delete branch to remove them too)") or ""))
end

---Copies selection into a clipboard table (objects + triangles)
function MS.copySelection()
	-- Copying a parent copies its children too
	local tris, plain = (MS.selSplitFamily or MS.selSplit)()
	if (#plain == 0 and next(tris) == nil) then
		MS.toast("Nothing selected to copy")
		return nil
	end
	local clip = { objs = {}, tris = {} }
	for _, idx in ipairs(plain) do
		table.insert(clip.objs, { fields = MS.deepcopy(MS.objs[idx]), meta = MS.deepcopy(MS.meta[idx]) })
	end
	for id in pairs(tris) do
		local t = MS.deepcopy(MS.tris[id])
		t.objs = {}
		table.insert(clip.tris, t)
	end
	return clip
end

---Pastes a clipboard with an offset. Returns the new selection list.
---Parent links inside the clip are kept between the copies; copies of top
---level items keep the original's parent. `keepUids` reuses the clip's ids
---(only when the originals were deleted first, e.g. mirror in place).
function MS.pasteClip(clip, offset, keepUids)
	if (not clip) then return {} end
	offset = offset or { 0, 0, 0 }
	local newSel = {}
	local remap = {}
	local function fresh(uid)
		if (uid == nil or keepUids) then return uid end
		remap[uid] = remap[uid] or MS.newUid()
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
		local f = MS.deepcopy(item.fields)
		f.pos_x = (f.pos_x or 0) + offset[1]
		f.pos_y = (f.pos_y or 0) + offset[2]
		f.pos_z = (f.pos_z or 0) + offset[3]
		local m = MS.deepcopy(item.meta) or {}
		m.tri = nil
		relink(m)
		local idx = MS.createObj(f, m)
		if (idx) then table.insert(newSel, idx) end
	end
	for _, t in ipairs(clip.tris) do
		local id = MS.triCreate(V.add(t.a, offset), V.add(t.b, offset), V.add(t.c, offset), {
			thick = t.thick, slices = t.slices, smooth = t.smooth, props = MS.deepcopy(t.props), name = t.name
		})
		if (id) then
			local link = { uid = t.uid, parent = t.parent }
			relink(link)
			MS.tris[id].uid, MS.tris[id].parent = link.uid, link.parent
			for _, idx in ipairs(MS.tris[id].objs) do table.insert(newSel, idx) end
		end
	end
	if (MS.hierFix) then MS.hierFix() end
	MS.sel = {}
	for _, idx in ipairs(newSel) do MS.sel[idx] = true end
	MS.primary = newSel[1]
	selChanged()
	return newSel
end

function MS.selWidthX()
	local lo, hi = math.huge, -math.huge
	for _, idx in ipairs(MS.selList()) do
		local p = MS.objPos(idx)
		local e = MS.objExtents(idx)
		lo = math.min(lo, p[1] - e[1] / 2)
		hi = math.max(hi, p[1] + e[1] / 2)
	end
	if (lo > hi) then return 1 end
	return hi - lo
end

function MS.duplicateSelected()
	local clip = MS.copySelection()
	if (not clip) then return end
	MS.pushUndo("Duplicate")
	local step = MS.settings.gridStep > 0 and MS.settings.gridStep or 0.25
	local dx = MS.round(MS.selWidthX() + step, step)
	local list = MS.pasteClip(clip, { dx, 0, 0 })
	MS.toast("Duplicated " .. #list .. " object" .. (#list == 1 and "" or "s"))
end

---------------------------------------------------------------------------
-- Triangles: a triangle prism built from box slices so it exports as a
-- normal .tbm and collides correctly in-game (no script needed to play).
---------------------------------------------------------------------------

MS.TRI_PROPS = { color_r = true, color_g = true, color_b = true, color_a = true, mass = true, static = true,
	hardness = true, friction = true, bounce = true, visible = true }

function MS.triCentroid(id)
	local t = MS.tris[id]
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
function MS.triSlices(t)
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
function MS.triBuild(id)
	local t = MS.tris[id]
	if (not t) then return end
	local slices = MS.triSlices(t)
	local want = #slices
	-- Create / delete slices to match the wanted count
	while (#t.objs > want and #t.objs > 0) do
		local idx = table.remove(t.objs)
		if (MS.meta[idx]) then MS.meta[idx].tri = nil end
		MS.deleteObjRaw(idx)
	end
	local wasSelected = false
	for _, idx in ipairs(t.objs) do
		if (MS.sel[idx]) then wasSelected = true end
	end
	while (#t.objs < want) do
		local ok, idx = pcall(create_mod_envobj)
		if (not ok or idx == nil) then
			MS.noteObjectLimit()
			MS.toast("Object limit reached - lower the triangle's Smoothness")
			break
		end
		MS.readObj(idx)
		MS.meta[idx] = { tri = id }
		table.insert(t.objs, idx)
	end
	local props = t.props
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
			local o = MS.objs[idx]
			for _, fname in ipairs(MS.ENV_FIELDS) do
				local v = f[fname]
				if (v ~= nil and o[fname] ~= v and not MS.unsupported.env[fname]) then
					o[fname] = normalize(fname, v)
					pcall(set_mod_envobj, idx, fname, toEngine(fname, o[fname]))
				end
			end
			MS.meta[idx] = MS.meta[idx] or {}
			MS.meta[idx].tri = id
			if (wasSelected) then MS.sel[idx] = true end
		end
	end
	MS.markDirty()
end

---Creates a triangle from three world points. opts: thick, slices, smooth, props, name
function MS.triCreate(a, b, c, opts)
	opts = opts or {}
	local id = MS.nextTri
	MS.nextTri = MS.nextTri + 1
	local col = MS.nextColor()
	local props = opts.props or {
		color_r = col[1], color_g = col[2], color_b = col[3], color_a = 1,
		mass = 1, static = MS.settings.newStatic, visible = true
	}
	MS.tris[id] = {
		a = V.copy(a), b = V.copy(b), c = V.copy(c),
		thick = opts.thick or 0.2,
		slices = opts.slices or 16,
		smooth = opts.smooth or "longest",
		props = props,
		name = opts.name,
		objs = {}
	}
	MS.triBuild(id)
	if (#MS.tris[id].objs == 0) then
		MS.tris[id] = nil
		return nil
	end
	return id
end

function MS.addTriangle(kind)
	MS.pushUndo("Add " .. (kind or "triangle"))
	local p = MS.spawnPoint()
	local id
	if (kind == "ramp") then
		-- Right-angle wedge: smooth sloped top, 2 wide
		id = MS.triCreate({ p[1] - 1.5, p[2], 0 }, { p[1] + 1.5, p[2], 0 }, { p[1] + 1.5, p[2], 1.2 },
			{ thick = 2, slices = 20, smooth = "ca", name = "Ramp" })
	elseif (kind == "flat") then
		-- Lying flat on the ground (a triangular floor tile)
		id = MS.triCreate({ p[1] - 1, p[2] - 0.8, 0.05 }, { p[1] + 1, p[2] - 0.8, 0.05 }, { p[1], p[2] + 1, 0.05 },
			{ thick = 0.1, slices = 16, name = "Floor Triangle" })
	else
		-- Upright triangle ("fin")
		id = MS.triCreate({ p[1] - 1, p[2], 0 }, { p[1] + 1, p[2], 0 }, { p[1], p[2], 1.6 },
			{ thick = 0.2, slices = 16 })
	end
	if (id) then
		MS.selSet(MS.tris[id].objs[1])
		MS.toast("Added triangle - edit its corners in the Triangle tab or drag the corner dots")
	end
	return id
end

---Turns a triangle into ordinary objects (keeps the slices, drops the link)
function MS.triDetach(id)
	local t = MS.tris[id]
	if (not t) then return end
	MS.pushUndo("Detach triangle")
	for i, idx in ipairs(t.objs) do
		MS.meta[idx] = MS.meta[idx] or {}
		MS.meta[idx].tri = nil
		-- The first slice takes over the triangle's place in the hierarchy
		MS.meta[idx].parent = t.parent
		MS.meta[idx].uid = (i == 1) and t.uid or nil
	end
	MS.tris[id] = nil
	MS.toast("Triangle converted to " .. #t.objs .. " plain boxes")
	selChanged()
end

---------------------------------------------------------------------------
-- Tools: align / distribute / mirror / drop / snap / arrays / generators
---------------------------------------------------------------------------

---Applies a rigid transform (pivot, rotation Q, translation d) to the selection
function MS.transformSelection(pivot, Q, d)
	local tris, plain = (MS.selSplitFamily or MS.selSplit)()
	for _, idx in ipairs(plain) do
		local p = MS.objPos(idx)
		local np = V.add(V.add(pivot, M.apply(Q, V.sub(p, pivot))), d)
		MS.setObjPos(idx, np)
		MS.setObjRot(idx, M.mul(Q, MS.objRot(idx)))
	end
	for id in pairs(tris) do
		local t = MS.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do
			t[key] = V.add(V.add(pivot, M.apply(Q, V.sub(t[key], pivot))), d)
		end
		MS.triBuild(id)
	end
end

---Moves the selection without touching rotations
function MS.translateSelection(d)
	local tris, plain = (MS.selSplitFamily or MS.selSplit)()
	for _, idx in ipairs(plain) do
		MS.setObjPos(idx, V.add(MS.objPos(idx), d))
	end
	for id in pairs(tris) do
		local t = MS.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do
			t[key] = V.add(t[key], d)
		end
		MS.triBuild(id)
	end
end

function MS.dropToFloor()
	local tris, plain = MS.selSplit()
	if (#plain == 0 and next(tris) == nil) then
		MS.toast("Select something to drop")
		return
	end
	MS.pushUndo("Drop to floor")
	for _, idx in ipairs(plain) do
		local dz = -MS.objBottom(idx)
		MS.objSet(idx, "pos_z", MS.objs[idx].pos_z + dz)
	end
	for id in pairs(tris) do
		local t = MS.tris[id]
		local lo = math.min(t.a[3], t.b[3], t.c[3])
		local half = 0
		local slices = MS.triSlices(t)
		if (slices[1]) then
			half = abs(slices[1].R[3][3]) * (t.thick or 0.2) / 2
		end
		local dz = -(lo - half)
		for _, key in ipairs({ "a", "b", "c" }) do t[key][3] = t[key][3] + dz end
		MS.triBuild(id)
	end
	MS.toast("Dropped to the floor")
end

function MS.snapSelectionToGrid()
	local step = MS.settings.gridStep
	if (step <= 0) then return end
	local tris, plain = MS.selSplit()
	MS.pushUndo("Snap to grid")
	for _, idx in ipairs(plain) do
		local p = MS.objPos(idx)
		MS.setObjPos(idx, { MS.round(p[1], step), MS.round(p[2], step), MS.round(p[3], step) })
	end
	for id in pairs(tris) do
		local t = MS.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do
			t[key] = { MS.round(t[key][1], step), MS.round(t[key][2], step), MS.round(t[key][3], step) }
		end
		MS.triBuild(id)
	end
	MS.toast("Snapped to grid (" .. MS.fmt(step) .. ")")
end

function MS.resetRotation()
	local _, plain = MS.selSplit()
	if (#plain == 0) then return end
	MS.pushUndo("Reset rotation")
	for _, idx in ipairs(plain) do
		MS.objSet(idx, "rot_x", 0)
		MS.objSet(idx, "rot_y", 0)
		MS.objSet(idx, "rot_z", 0)
	end
end

---Align all selected objects' centers to the primary object on axis k (1..3)
function MS.alignSelection(k, mode)
	local tris, plain = MS.selSplit()
	if (#plain + MS.count(tris) < 2) then
		MS.toast("Select 2 or more objects to align (Shift+click)")
		return
	end
	MS.pushUndo("Align")
	local target
	if (mode == "floor") then
		target = 0
	elseif (MS.primary and MS.objs[MS.primary]) then
		target = MS.objPos(MS.primary)[k]
	else
		target = MS.selCenter()[k]
	end
	for _, idx in ipairs(plain) do
		local p = MS.objPos(idx)
		p[k] = target
		MS.setObjPos(idx, p)
	end
	for id in pairs(tris) do
		local c = MS.triCentroid(id)
		local d = { 0, 0, 0 }
		d[k] = target - c[k]
		local t = MS.tris[id]
		for _, key in ipairs({ "a", "b", "c" }) do t[key] = V.add(t[key], d) end
		MS.triBuild(id)
	end
	MS.toast("Aligned on " .. ({ "X", "Y", "Z" })[k])
end

---Evenly spaces plain selected objects between the outermost two along axis k
function MS.distributeSelection(k)
	local _, plain = MS.selSplit()
	if (#plain < 3) then
		MS.toast("Select 3 or more objects to distribute")
		return
	end
	MS.pushUndo("Distribute")
	table.sort(plain, function(a, b) return MS.objPos(a)[k] < MS.objPos(b)[k] end)
	local lo = MS.objPos(plain[1])[k]
	local hi = MS.objPos(plain[#plain])[k]
	for i, idx in ipairs(plain) do
		local p = MS.objPos(idx)
		p[k] = lo + (hi - lo) * (i - 1) / (#plain - 1)
		MS.setObjPos(idx, p)
	end
	MS.toast("Distributed evenly on " .. ({ "X", "Y", "Z" })[k])
end

---Mirrors the selection across the world plane through 0 (or the selection center)
---on axis k. With `copy` the mirrored version is added as new objects.
function MS.mirrorSelection(k, copy, aroundCenter)
	local clip = MS.copySelection()
	if (not clip) then return end
	MS.pushUndo(copy and "Mirror copy" or "Mirror")
	local c = aroundCenter and MS.selCenter()[k] or 0
	local function mp(p)
		local q = V.copy(p)
		q[k] = 2 * c - q[k]
		return q
	end
	if (not copy) then
		-- The clip holds the selection and its children: replace all of them
		local tris, plain = (MS.selSplitFamily or MS.selSplit)()
		local doomed = {}
		for _, idx in ipairs(plain) do table.insert(doomed, idx) end
		for id in pairs(tris) do
			for _, idx in ipairs(MS.tris[id].objs) do table.insert(doomed, idx) end
			MS.tris[id] = nil
		end
		for _, idx in ipairs(doomed) do
			if (MS.meta[idx]) then MS.meta[idx].tri = nil end
			MS.deleteObjRaw(idx)
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
	MS.pasteClip(clip, { 0, 0, 0 }, not copy)
	MS.toast((copy and "Mirrored copy" or "Mirrored") .. " across " .. ({ "X", "Y", "Z" })[k])
end

---Linear array: `count` extra copies, each offset by `offset`
function MS.arraySelection(count, offset)
	local clip = MS.copySelection()
	if (not clip) then return end
	count = floor(count or 0)
	if (count < 1) then return end
	MS.pushUndo("Array")
	local all = MS.selList()
	for i = 1, count do
		for _, idx in ipairs(MS.pasteClip(clip, V.mul(offset, i))) do
			table.insert(all, idx)
		end
	end
	MS.sel = {}
	for _, idx in ipairs(all) do MS.sel[idx] = true end
	selChanged()
	MS.toast("Made " .. count .. " copies")
end

---Radial array around the selection center (or world origin) on the Z axis
function MS.radialArraySelection(count, radius)
	local clip = MS.copySelection()
	if (not clip) then return end
	count = floor(count or 0)
	if (count < 2) then return end
	MS.pushUndo("Radial array")
	local center = MS.selCenter()
	local pivot = { center[1] - radius, center[2], center[3] }
	local all = MS.selList()
	for i = 1, count - 1 do
		local ang = 360 * i / count
		local Q = M.axisAngle({ 0, 0, 1 }, ang)
		local c2 = MS.deepcopy(clip)
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
		for _, idx in ipairs(MS.pasteClip(c2, { 0, 0, 0 })) do table.insert(all, idx) end
	end
	MS.sel = {}
	for _, idx in ipairs(all) do MS.sel[idx] = true end
	selChanged()
	MS.toast("Placed " .. count .. " copies in a circle")
end

MS.gen = MS.gen or {
	stairsSteps = 6, stairsWidth = 2, stairsRise = 0.25, stairsRun = 0.4,
	arenaSize = 12, arenaWall = 2, arenaThick = 0.4,
	tilesX = 6, tilesY = 6, tileSize = 1,
	arrayCount = 3, arrayX = 1.5, arrayY = 0, arrayZ = 0,
	radialCount = 8, radialRadius = 4,
	pyramidLevels = 4, pyramidSize = 0.8
}

function MS.genStairs()
	local g = MS.gen
	MS.pushUndo("Stairs")
	local p = MS.spawnPoint()
	local c = MS.nextColor()
	local list = {}
	for i = 1, floor(g.stairsSteps) do
		local h = g.stairsRise * i
		local idx = MS.createObj({
			type = 1, dims_x = g.stairsRun, dims_y = g.stairsWidth, dims_z = h,
			pos_x = p[1] + g.stairsRun * (i - 1), pos_y = p[2], pos_z = h / 2,
			color_r = c[1], color_g = c[2], color_b = c[3], static = true, mass = 1
		}, { name = "Step " .. i, group = "Stairs" })
		if (idx) then table.insert(list, idx) end
	end
	MS.sel = {}
	for _, idx in ipairs(list) do MS.sel[idx] = true end
	MS.primary = list[1]
	selChanged()
	MS.toast("Built " .. #list .. " stairs")
end

function MS.genArena()
	local g = MS.gen
	MS.pushUndo("Arena")
	local s, h, t = g.arenaSize, g.arenaWall, g.arenaThick
	local list = {}
	local function add(f, name)
		f.type = 1
		f.static = true
		f.mass = 1
		local idx = MS.createObj(f, { name = name, group = "Arena" })
		if (idx) then table.insert(list, idx) end
	end
	add({ dims_x = s, dims_y = s, dims_z = 0.2, pos_x = 0, pos_y = 0, pos_z = 0.1, color_r = 0.62, color_g = 0.62, color_b = 0.66 }, "Arena Floor")
	local wc = { 0.35, 0.38, 0.45 }
	add({ dims_x = s + t * 2, dims_y = t, dims_z = h, pos_x = 0, pos_y = s / 2 + t / 2, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall North")
	add({ dims_x = s + t * 2, dims_y = t, dims_z = h, pos_x = 0, pos_y = -s / 2 - t / 2, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall South")
	add({ dims_x = t, dims_y = s, dims_z = h, pos_x = s / 2 + t / 2, pos_y = 0, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall East")
	add({ dims_x = t, dims_y = s, dims_z = h, pos_x = -s / 2 - t / 2, pos_y = 0, pos_z = h / 2, color_r = wc[1], color_g = wc[2], color_b = wc[3] }, "Wall West")
	MS.sel = {}
	for _, idx in ipairs(list) do MS.sel[idx] = true end
	MS.primary = list[1]
	selChanged()
	MS.toast("Built an arena around the players")
end

function MS.genTiles()
	local g = MS.gen
	MS.pushUndo("Tiles")
	local p = MS.spawnPoint()
	local nx, ny, sz = floor(g.tilesX), floor(g.tilesY), g.tileSize
	local list = {}
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			local dark = (i + j) % 2 == 0
			local v = dark and 0.2 or 0.85
			local idx = MS.createObj({
				type = 1, dims_x = sz, dims_y = sz, dims_z = 0.1,
				pos_x = p[1] + (i - (nx - 1) / 2) * sz, pos_y = p[2] + (j - (ny - 1) / 2) * sz, pos_z = 0.05,
				color_r = v, color_g = v, color_b = v, static = true, mass = 1
			}, { group = "Tiles" })
			if (idx) then table.insert(list, idx) else break end
		end
	end
	MS.sel = {}
	for _, idx in ipairs(list) do MS.sel[idx] = true end
	MS.primary = list[1]
	selChanged()
	MS.toast("Built a " .. nx .. "x" .. ny .. " checkerboard")
end

function MS.genPyramid()
	local g = MS.gen
	MS.pushUndo("Pyramid")
	local p = MS.spawnPoint()
	local n, sz = floor(g.pyramidLevels), g.pyramidSize
	local list = {}
	for level = 0, n - 1 do
		local w = n - level
		for i = 0, w - 1 do
			for j = 0, w - 1 do
				local c = MS.PALETTE[(level % 8) + 1]
				local idx = MS.createObj({
					type = 1, dims_x = sz, dims_y = sz, dims_z = sz,
					pos_x = p[1] + (i - (w - 1) / 2) * sz, pos_y = p[2] + (j - (w - 1) / 2) * sz, pos_z = sz / 2 + level * sz,
					color_r = c[1], color_g = c[2], color_b = c[3], static = false, mass = 0.5
				}, { group = "Pyramid" })
				if (idx) then table.insert(list, idx) end
			end
		end
	end
	MS.sel = {}
	for _, idx in ipairs(list) do MS.sel[idx] = true end
	MS.primary = list[1]
	selChanged()
	MS.toast("Stacked " .. #list .. " blocks - they're physical, so they'll tumble!")
end

---------------------------------------------------------------------------
-- Materials
---------------------------------------------------------------------------

MS.MATERIALS = {
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
function MS.playerMirrorAxis(p)
	local r, l = MS.bodies[p] and MS.bodies[p][5], MS.bodies[p] and MS.bodies[p][8]
	if (not r or not l) then return 1, 0 end
	local d = { abs(r.pos_x - l.pos_x), abs(r.pos_y - l.pos_y), abs(r.pos_z - l.pos_z) }
	local k = 1
	if (d[2] > d[k]) then k = 2 end
	if (d[3] > d[k]) then k = 3 end
	local keys = { "pos_x", "pos_y", "pos_z" }
	return k, (r[keys[k]] + l[keys[k]]) / 2
end

local AXK = { "x", "y", "z" }

function MS.mirrorBody(p, b, silent)
	local other = MS.BODY_MIRROR[b]
	local src = MS.bodies[p] and MS.bodies[p][b]
	if (not other or not src) then
		if (not silent) then MS.toast("This body part has no left/right partner") end
		return
	end
	local k, c = MS.playerMirrorAxis(p)
	for f, v in pairs(src) do
		MS.bodySet(p, other, f, v)
	end
	MS.bodySet(p, other, "pos_" .. AXK[k], 2 * c - src["pos_" .. AXK[k]])
	local R = M.mirror(M.fromEuler(src.rot_x, src.rot_y, src.rot_z), k)
	local x, y, z = M.toEuler(R)
	MS.bodySet(p, other, "rot_x", x)
	MS.bodySet(p, other, "rot_y", y)
	MS.bodySet(p, other, "rot_z", z)
	if (src.force_x) then
		MS.bodySet(p, other, "force_" .. AXK[k], -src["force_" .. AXK[k]])
	end
	if (not silent) then MS.toast("Copied " .. MS.BODY_NAMES[b] .. " to " .. MS.BODY_NAMES[other]) end
end

function MS.mirrorJoint(p, j, silent)
	local other = MS.JOINT_MIRROR[j]
	local src = MS.joints[p] and MS.joints[p][j]
	if (not other or not src) then
		if (not silent) then MS.toast("This joint has no left/right partner") end
		return
	end
	local k, c = MS.playerMirrorAxis(p)
	for f, v in pairs(src) do
		MS.jointSet(p, other, f, v)
	end
	MS.jointSet(p, other, "pos_" .. AXK[k], 2 * c - src["pos_" .. AXK[k]])
	-- Rotation axes are pseudo-vectors: reflect, then flip
	local ax = { src.axis_x or 0, src.axis_y or 0, src.axis_z or 0 }
	ax[k] = -ax[k]
	ax = V.mul(ax, -1)
	MS.jointSet(p, other, "axis_x", ax[1])
	MS.jointSet(p, other, "axis_y", ax[2])
	MS.jointSet(p, other, "axis_z", ax[3])
	if (not silent) then MS.toast("Copied " .. MS.JOINT_NAMES[j] .. " to " .. MS.JOINT_NAMES[other]) end
end

MS.PHYS_BODY_FIELDS = { "type", "sides_x", "sides_y", "sides_z", "density", "hardness", "friction", "bounce" }
MS.PHYS_JOINT_FIELDS = { "histop", "lostop", "maxforce", "maxvelocity", "radius", "density", "hardness", "friction", "bounce" }

function MS.copyBodyToOtherPlayers(p, b)
	local src = MS.bodies[p][b]
	for q = 0, MS.numPlayers - 1 do
		if (q ~= p) then
			for _, f in ipairs(MS.PHYS_BODY_FIELDS) do
				if (src[f] ~= nil and (f ~= "type" or b ~= 0)) then MS.bodySet(q, b, f, src[f]) end
			end
		end
	end
end

function MS.copyJointToOtherPlayers(p, j)
	local src = MS.joints[p][j]
	for q = 0, MS.numPlayers - 1 do
		if (q ~= p) then
			for _, f in ipairs(MS.PHYS_JOINT_FIELDS) do
				if (src[f] ~= nil) then MS.jointSet(q, j, f, src[f]) end
			end
		end
	end
end

---------------------------------------------------------------------------
-- 360 joints: limits past +-pi are ignored by the physics engine, so a joint
-- with range 10 / -10 keeps turning either way (how the "360 chest" mods work)
---------------------------------------------------------------------------

MS.SPIN_LIMIT = 10
MS.spinPrev = MS.spinPrev or {}

function MS.jointSpins(p, j)
	local o = MS.joints[p] and MS.joints[p][j]
	if (not o) then return false end
	return math.abs(o.histop or 0) > math.pi and math.abs(o.lostop or 0) > math.pi
end

---Turns 360 spinning on/off for one joint, remembering its old limits
function MS.setJointSpin(p, j, on)
	local o = MS.joints[p] and MS.joints[p][j]
	if (not o) then return end
	local key = p .. ":" .. j
	if (on) then
		if (not MS.jointSpins(p, j)) then
			MS.spinPrev[key] = { o.histop, o.lostop }
		end
		MS.jointSet(p, j, "histop", MS.SPIN_LIMIT)
		MS.jointSet(p, j, "lostop", -MS.SPIN_LIMIT)
	else
		local prev = MS.spinPrev[key]
		MS.jointSet(p, j, "histop", prev and prev[1] or 1)
		MS.jointSet(p, j, "lostop", prev and prev[2] or -1)
		MS.spinPrev[key] = nil
	end
end

---Spin preset for a list of joints on every player. Returns how many joints changed
function MS.spinJoints(list, on)
	local n = 0
	for p = 0, math.max(1, MS.numPlayers) - 1 do
		for _, j in ipairs(list) do
			if (MS.joints[p] and MS.joints[p][j] and MS.jointSpins(p, j) ~= on) then
				MS.setJointSpin(p, j, on)
				n = n + 1
			end
		end
	end
	return n
end

MS.CHEST_JOINT, MS.LUMBAR_JOINT = 1, 2

---Scales a whole player around the point between its feet (sizes, positions, joint radii)
function MS.scalePlayer(p, k)
	if (not MS.bodies[p] or k <= 0) then return end
	local minZ = math.huge
	for b = 0, MS.NUM_BODIES - 1 do
		local o = MS.bodies[p][b]
		if (o) then minZ = math.min(minZ, o.pos_z - (o.sides_z or 0) / 2) end
	end
	local head = MS.bodies[p][0]
	local pivot = { head.pos_x, head.pos_y, math.max(0, minZ) }
	local function sp(o, set, id)
		local q = V.add(pivot, V.mul(V.sub({ o.pos_x, o.pos_y, o.pos_z }, pivot), k))
		set(p, id, "pos_x", q[1])
		set(p, id, "pos_y", q[2])
		set(p, id, "pos_z", q[3])
	end
	for b = 0, MS.NUM_BODIES - 1 do
		local o = MS.bodies[p][b]
		if (o) then
			sp(o, MS.bodySet, b)
			for _, f in ipairs({ "sides_x", "sides_y", "sides_z" }) do
				if (o[f]) then MS.bodySet(p, b, f, o[f] * k) end
			end
		end
	end
	for j = 0, MS.NUM_JOINTS - 1 do
		local o = MS.joints[p] and MS.joints[p][j]
		if (o) then
			sp(o, MS.jointSet, j)
			if (o.radius) then MS.jointSet(p, j, "radius", o.radius * k) end
		end
	end
end

---------------------------------------------------------------------------
-- Gamerules
---------------------------------------------------------------------------

MS.RULES = {
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
MS.FLAGS = {
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
MS.hasBit = hasBit

---Current flags value, rebuilt from the individual rules if `flags` is missing
function MS.getFlags()
	local n = tonumber(MS.getRule("flags") or "")
	if (n) then return n end
	n = 0
	for _, f in ipairs(MS.FLAGS) do
		local v = MS.getRule(f.rule) == "1"
		if (f.invert) then v = not v end
		if (v) then n = n + f.bit end
	end
	return n
end

function MS.setFlags(n)
	n = MS.clamp(floor(n or 0), 0, 15)
	MS.setRule("flags", n)
	for _, f in ipairs(MS.FLAGS) do
		local on = hasBit(n, f.bit)
		if (f.invert) then on = not on end
		MS.setRule(f.rule, on and 1 or 0)
	end
end

function MS.setFlag(bit, on)
	local n = MS.getFlags()
	if (hasBit(n, bit) and not on) then
		n = n - bit
	elseif (not hasBit(n, bit) and on) then
		n = n + bit
	end
	MS.setFlags(n)
end

---Human readable summary like "DQ + Dismemberment"
function MS.flagsSummary(n)
	local parts = {}
	for _, f in ipairs(MS.FLAGS) do
		if (hasBit(n, f.bit)) then table.insert(parts, (f.title:gsub(" %(DQ%)", ""))) end
	end
	return #parts > 0 and table.concat(parts, " + ") or "None"
end

---Every rule name a snapshot / project keeps
function MS.allRuleNames()
	local names = { "flags" }
	for _, f in ipairs(MS.FLAGS) do table.insert(names, f.rule) end
	for _, r in ipairs(MS.RULES) do table.insert(names, r.name) end
	return names
end

function MS.readRules()
	local t = {}
	for _, name in ipairs(MS.allRuleNames()) do
		local v = MS.getRule(name)
		if (v ~= nil) then t[name] = v end
	end
	return t
end

function MS.applyRules(rules)
	if (not rules) then return end
	for name, v in pairs(rules) do
		if (name ~= "mod" and v ~= MS.getRule(name)) then
			pcall(set_gamerule, name, tostring(v))
		end
	end
end

function MS.getRule(name)
	local ok, v = pcall(get_gamerule, name)
	if (ok) then return v end
	return nil
end

function MS.setRule(name, value)
	pcall(set_gamerule, name, tostring(value))
	MS.changed = true
	MS.changedSinceAutosave = true
end

function MS.restartMatch()
	MS.flush(true)
	local ok, ws = pcall(get_world_state)
	if (ok and ws and ws.game_type == 1 and runCmd) then
		runCmd("reset")
	else
		pcall(start_new_game)
	end
	MS.toast("Match restarted with the new rules")
end

---------------------------------------------------------------------------
-- Project files (keeps names, groups, locks, parents and triangles - .tbm can't)
---------------------------------------------------------------------------

function MS.safeName(name)
	name = tostring(name or ""):gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if (name == "") then name = "Untitled" end
	return name
end

function MS.saveProject(name, silent)
	name = MS.safeName(name)
	local s = MS.snapshot()
	s.version = MS.VERSION
	local okm, msg = pcall(get_mod_message)
	local oku, um = pcall(get_mod_use_model)
	local okn, mn = pcall(get_mod_model_name)
	s.world = { message = okm and msg or nil, useModel = oku and um or nil, modelName = okn and mn or nil }
	local path = MS.PROJECT_DIR .. name .. ".msp"
	if (MS.writeFile(path, "return " .. MS.serialize(s))) then
		MS.changedSinceAutosave = false
		if (not silent) then
			MS.changed = false
			MS.toast("Saved project \"" .. name .. "\"")
		end
		return true
	end
	if (not silent) then
		MS.toast("Couldn't save - is data/script/modstudio/projects/ missing?")
	end
	return false
end

function MS.loadProject(name)
	local data = MS.readData(MS.PROJECT_DIR .. name .. ".msp")
	if (not data or not data.objs) then
		MS.toast("Couldn't read project " .. tostring(name))
		return false
	end
	MS.pushUndo("Load project")
	MS.restore(data)
	if (data.world) then
		if (data.world.message) then pcall(set_mod_message, data.world.message) end
		if (data.world.useModel ~= nil) then pcall(set_mod_use_model, data.world.useModel) end
		if (data.world.modelName) then pcall(set_mod_model_name, data.world.modelName) end
	end
	MS.saveName = name ~= "_autosave" and name or MS.saveName
	MS.markDirty()
	MS.changed = false
	MS.toast("Loaded project \"" .. name .. "\"")
	return true
end

function MS.listProjects()
	local list = {}
	local ok, files = pcall(get_files, "data/script/modstudio/projects", "")
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

function MS.listMods()
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

function MS.exportMod(name)
	name = MS.safeName(name)
	MS.flush(true)
	local ok, written = pcall(export_mod_maker, name)
	if (ok and written) then
		MS.saveName = (tostring(written):gsub("^modmaker/", ""):gsub("%.tbm$", ""))
		MS.changed = false
		-- Keep a project file next to the export so names/triangles survive
		MS.saveProject(MS.saveName, true)
		MS.toast("Exported data/mod/" .. tostring(written) .. " - load it from the Mods menu")
		echo("Mod Studio: exported " .. tostring(written))
		return written
	end
	MS.toast("Export failed - see the debug console for details")
	return nil
end

function MS.importMod(name)
	MS.pushUndo("Import " .. name)
	local ok, res = pcall(import_mod_into_maker, name)
	if (ok and res) then
		MS.meta, MS.tris = {}, {}
		MS.reloadAll()
		MS.saveName = (name:gsub("^modmaker/", ""):gsub("%.tbm$", ""))
		MS.markDirty()
		MS.changed = false
		MS.toast("Imported " .. name)
		return true
	end
	MS.toast("Couldn't import " .. name)
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
	local c = MS.calib
	c.done = true
	c.result = result
	if (c.probe) then
		pcall(delete_mod_envobj, c.probe)
		pcall(refresh_mod_maker_world)
	end
	if (not result) then
		echo("Mod Studio: couldn't measure the engine's rotation units, using saved settings (" .. MS.settings.rotUnit .. ")")
		return
	end
	local changed = result.rotUnit ~= MS.settings.rotUnit or result.conv ~= MS.settings.rotConvention or
		abs((result.sizeScale or 1) - MS.settings.sizeScale) > 1e-6
	MS.settings.rotUnit = result.rotUnit
	MS.settings.rotConvention = result.conv
	MS.settings.sizeScale = result.sizeScale or MS.settings.sizeScale
	MS.saveSettings()
	if (changed) then
		-- Re-read everything in the right units and rebuild triangles with them
		MS.reloadAll()
		for id in pairs(MS.tris) do MS.triBuild(id) end
		MS.flush(true)
		echo("Mod Studio: matched the engine (rotation in " .. (result.rotUnit == "rad" and "radians" or "degrees") ..
			", size scale " .. MS.fmt(MS.settings.sizeScale) .. ") - rotations and triangles now line up")
	end
end

function MS.startCalibration()
	MS.calib = { frames = 0 }
end

---Advances calibration by one frame. Call from draw3d until MS.calib.done.
function MS.calibrateStep()
	local c = MS.calib
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
	local n = MS.count(MS.objs) + 6
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

MS.DEFAULT_MOD = "classic.tbm"

local RESET_LABELS = {
	all = "Reset everything", players = "Reset both players", rules = "Reset rules", [0] = "Reset Tori", [1] = "Reset Uke"
}

---what: "all" | "players" | "rules" | player index
function MS.resetTo(what)
	local label = RESET_LABELS[what] or "Reset"
	local keep = MS.snapshot()
	local okm, msg = pcall(get_mod_message)
	local oku, um = pcall(get_mod_use_model)
	local okn, mn = pcall(get_mod_model_name)
	-- Inside MS.withUndo the caller already recorded the undo step
	local pushed = not MS.undoSuppress
	MS.pushUndo(label)
	MS.endDragSilently()
	local ok, res = pcall(import_mod_into_maker, MS.DEFAULT_MOD)
	if (not ok or not res) then
		-- The import may have half-run: re-read the engine, then put everything back
		if (pushed) then table.remove(MS.undoStack) end
		MS.reloadAll()
		MS.restore(keep)
		MS.toast("Couldn't load the default mod (" .. MS.DEFAULT_MOD .. ") - nothing was changed")
		return false
	end
	MS.meta, MS.tris = {}, {}
	MS.reloadAll()
	if (what ~= "all") then
		-- Put back everything that isn't being reset
		local s = MS.deepcopy(keep)
		if (what == "players") then
			s.bodies, s.joints = nil, nil
		elseif (type(what) == "number") then
			if (s.bodies) then s.bodies[what] = nil end
			if (s.joints) then s.joints[what] = nil end
		elseif (what == "rules") then
			s.rules = nil
		end
		MS.restore(s)
		if (okm and msg) then pcall(set_mod_message, msg) end
		if (oku and um ~= nil) then pcall(set_mod_use_model, um) end
		if (okn and mn) then pcall(set_mod_model_name, mn) end
	end
	MS.markDirty()
	MS.selClear()
	MS.toast(label .. " done - Ctrl+Z undoes it")
	return true
end

function MS.clearAll()
	MS.pushUndo("Clear all objects")
	for idx in pairs(MS.ejs) do pcall(delete_mod_envjoint, idx) end
	for idx in pairs(MS.objs) do pcall(delete_mod_envobj, idx) end
	MS.objs, MS.ejs, MS.meta, MS.tris = {}, {}, {}, {}
	MS.markDirty()
	MS.selClear()
	MS.toast("Removed all objects (Ctrl+Z brings them back)")
end
