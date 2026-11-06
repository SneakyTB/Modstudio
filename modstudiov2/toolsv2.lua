-- Mod Studio: extra tools
-- Surface snapping, measuring, whole-player placement, dojo, arc/curve
-- generators, prefab library and trigger/physics presets.

local MSV2 = MSV2
local V, M = MSV2.V, MSV2.M
local abs, sqrt, floor = math.abs, math.sqrt, math.floor
local rad, deg, sin, cos = math.rad, math.deg, math.sin, math.cos

---------------------------------------------------------------------------
-- Scene raycasting with surface normals (uses the cached objects)
---------------------------------------------------------------------------

---Ray vs oriented box. Returns t, world normal
local function rayOBBn(ro, rd, pos, R, half)
	local Rt = M.transpose(R)
	local o = M.apply(Rt, V.sub(ro, pos))
	local d = M.apply(Rt, rd)
	local tmin, tmax = -math.huge, math.huge
	local nAxis, nSign = 1, 1
	for k = 1, 3 do
		if (abs(d[k]) < 1e-9) then
			if (abs(o[k]) > half[k]) then return nil end
		else
			local t1, t2 = (-half[k] - o[k]) / d[k], (half[k] - o[k]) / d[k]
			local s1 = -1
			if (t1 > t2) then t1, t2 = t2, t1; s1 = 1 end
			if (t1 > tmin) then tmin, nAxis, nSign = t1, k, s1 end
			if (t2 < tmax) then tmax = t2 end
			if (tmin > tmax) then return nil end
		end
	end
	if (tmax < 0 or tmin < 0) then return nil end
	return tmin, V.mul(M.col(R, nAxis), nSign), nAxis
end

local function raySphereN(ro, rd, c, r)
	local oc = V.sub(ro, c)
	local b = V.dot(oc, rd)
	local disc = b * b - (V.dot(oc, oc) - r * r)
	if (disc < 0) then return nil end
	local t = -b - sqrt(disc)
	if (t < 0) then return nil end
	return t, V.norm(V.sub(V.add(ro, V.mul(rd, t)), c))
end

---Ray vs capsule along local Z
local function rayCapsuleN(ro, rd, pos, R, r, len)
	-- Test the bounding box first, then treat the surface as the capsule
	local t = rayOBBn(ro, rd, pos, R, { r, r, len / 2 + r })
	if (not t) then return nil end
	local a = M.col(R, 3)
	local p0 = V.sub(pos, V.mul(a, len / 2))
	local best
	for i = 0, 24 do
		local q = V.add(p0, V.mul(a, len * i / 24))
		local ts, n = raySphereN(ro, rd, q, r)
		if (ts and (not best or ts < best[1])) then best = { ts, n } end
	end
	if (best) then
		-- Normal points away from the core line
		local hit = V.add(ro, V.mul(rd, best[1]))
		local s = MSV2.clamp(V.dot(V.sub(hit, p0), a), 0, len)
		return best[1], V.norm(V.sub(hit, V.add(p0, V.mul(a, s))))
	end
	return nil
end

---Nearest surface along the ray among objects (not in `exclude`) and the ground.
---Returns { t, pos, normal, idx (nil = ground) } or nil
function MSV2.raycastScene(ro, rd, exclude)
	exclude = exclude or {}
	local best
	for idx, o in pairs(MSV2.objs) do
		if (not exclude[idx] and o.visible ~= false) then
			local pos, R = MSV2.objPos(idx), MSV2.objRot(idx)
			local t, n
			if (o.type == 0) then
				t, n = raySphereN(ro, rd, pos, math.max(0.01, o.dims_x or 0.5))
			elseif (o.type == 2) then
				t, n = rayCapsuleN(ro, rd, pos, R, math.max(0.01, o.dims_x or 0.3), math.max(0, o.dims_y or 1))
			else
				t, n = rayOBBn(ro, rd, pos, R, { (o.dims_x or 1) / 2, (o.dims_y or 1) / 2, (o.dims_z or 1) / 2 })
			end
			if (t and (not best or t < best.t)) then
				best = { t = t, normal = n, idx = idx }
			end
		end
	end
	-- The floor
	if (rd[3] < -1e-4) then
		local t = -ro[3] / rd[3]
		if (t > 0 and (not best or t < best.t)) then
			best = { t = t, normal = { 0, 0, 1 }, idx = nil }
		end
	end
	if (best) then
		best.pos = V.add(ro, V.mul(rd, best.t))
	end
	return best
end

---------------------------------------------------------------------------
-- Surface snapping: the dragged selection rests on whatever is under the
-- cursor and lines its edges up with that object's edges.
---------------------------------------------------------------------------

---Surface snapping applies when dragging an object directly (not the gizmo handles).
---The setting turns it on, holding Shift while dragging flips it.
function MSV2.surfaceSnapActive()
	return (MSV2.settings.surfaceSnap and true or false) ~= MSV2.shiftDown()
end

---Lowest point of a shape along direction n, relative to `origin`
local function minAlong(pos, R, shape, dims, n, origin)
	local c = V.dot(V.sub(pos, origin), n)
	if (shape == 0) then return c - dims[1] end
	local e = MSV2.shapeExtents(shape, dims[1], dims[2], dims[3])
	local s = abs(V.dot(n, M.col(R, 1))) * e[1] / 2 + abs(V.dot(n, M.col(R, 2))) * e[2] / 2 + abs(V.dot(n, M.col(R, 3))) * e[3] / 2
	return c - s
end

local function extentAlong(pos, R, shape, dims, u)
	local c = V.dot(pos, u)
	local s
	if (shape == 0) then
		s = dims[1]
	else
		local e = MSV2.shapeExtents(shape, dims[1], dims[2], dims[3])
		s = abs(V.dot(u, M.col(R, 1))) * e[1] / 2 + abs(V.dot(u, M.col(R, 2))) * e[2] / 2 + abs(V.dot(u, M.col(R, 3))) * e[3] / 2
	end
	return c - s, c + s
end

---Works out where the selection (drag.items, at drag start) should go so it sits
---on the surface under the ray. Returns move delta + readout, or nil.
function MSV2.surfaceSnapDelta(drag, ro, rd)
	local items = drag.items
	if (not items or not items.objs) then return nil end
	local exclude = {}
	for _, it in ipairs(items.objs) do exclude[it.idx] = true end
	for _, it in ipairs(items.tris or {}) do
		for _, idx in ipairs(MSV2.tris[it.id] and MSV2.tris[it.id].objs or {}) do exclude[idx] = true end
	end
	local hit = MSV2.raycastScene(ro, rd, exclude)
	if (not hit or hit.t > 250) then return nil end
	local n = hit.normal
	local pivot0 = drag.pivot0

	-- How far the selection reaches "below" its pivot along the surface normal
	local lowest = math.huge
	for _, it in ipairs(items.objs) do
		lowest = math.min(lowest, minAlong(it.pos, it.R, it.type, it.dims, n, pivot0))
	end
	for _, it in ipairs(items.tris or {}) do
		for _, key in ipairs({ "a", "b", "c" }) do
			lowest = math.min(lowest, V.dot(V.sub(it[key], pivot0), n) - (it.thick or 0.2) / 2)
		end
	end
	if (lowest == math.huge) then return nil end
	-- Pivot goes under the cursor on the surface, lifted so the lowest point touches it
	local newPivot = V.sub(hit.pos, V.mul(n, lowest))
	local d = V.sub(newPivot, pivot0)

	-- Edge alignment against the object we landed on
	local aligned = false
	local target = hit.idx and MSV2.objs[hit.idx]
	if (target) then
		local tR = MSV2.objRot(hit.idx)
		local tPos = MSV2.objPos(hit.idx)
		local tDims = { target.dims_x or 1, target.dims_y or 1, target.dims_z or 1 }
		local thr = math.max(0.08, (MSV2.settings.gridStep or 0.25) * 0.6)
		for k = 1, 3 do
			local u = M.col(tR, k)
			if (abs(V.dot(u, n)) < 0.3) then
				local tmin, tmax = extentAlong(tPos, tR, target.type, tDims, u)
				local smin, smax = math.huge, -math.huge
				for _, it in ipairs(items.objs) do
					local a, b = extentAlong(V.add(it.pos, d), it.R, it.type, it.dims, u)
					smin, smax = math.min(smin, a), math.max(smax, b)
				end
				if (smin < math.huge) then
					local cands = {
						tmin - smin, tmax - smax, (tmin + tmax) / 2 - (smin + smax) / 2,
						tmax - smin, tmin - smax
					}
					local bestShift
					for _, sh in ipairs(cands) do
						if (abs(sh) < thr and (not bestShift or abs(sh) < abs(bestShift))) then bestShift = sh end
					end
					if (bestShift) then
						d = V.add(d, V.mul(u, bestShift))
						aligned = true
					end
				end
			end
		end
	end
	-- On flat ground (or a flat top) grid snapping still applies sideways
	if (not aligned and drag.snap and MSV2.settings.gridStep > 0 and abs(n[3]) > 0.999) then
		local step = MSV2.settings.gridStep
		local target2 = V.add(pivot0, d)
		target2[1] = MSV2.round(target2[1], step)
		target2[2] = MSV2.round(target2[2], step)
		d = V.sub(target2, pivot0)
	end
	local where = hit.idx and MSV2.objName(hit.idx) or "the floor"
	return d, "On " .. where .. (aligned and "  [edges lined up]" or "")
end

---------------------------------------------------------------------------
-- Measuring
---------------------------------------------------------------------------

MSV2.measure = MSV2.measure or {}

---Point on whatever surface is under the cursor (objects or floor)
function MSV2.surfacePoint(x, y)
	local ro, rd = MSV2.mouseRay(x, y)
	if (not ro) then return nil end
	local hit = MSV2.raycastScene(ro, rd, {})
	return hit and hit.pos, hit
end

function MSV2.measureClick(x, y)
	local p, hit = MSV2.surfacePoint(x, y)
	if (not p) then
		MSV2.toast("Click on an object or the floor to measure")
		return
	end
	local step = MSV2.settings.gridStep
	if (MSV2.snapActive() and step > 0) then
		p = { MSV2.round(p[1], step), MSV2.round(p[2], step), MSV2.round(p[3], step) }
	end
	local m = MSV2.measure
	if (not m.a or m.b) then
		MSV2.measure = { a = p }
		MSV2.toast("Point A set - click a second point")
	else
		m.b = p
		local d = V.sub(m.b, m.a)
		MSV2.toast("Distance " .. MSV2.fmt(V.len(d)) .. "  (X " .. MSV2.fmt(d[1]) .. ", Y " .. MSV2.fmt(d[2]) .. ", Z " .. MSV2.fmt(d[3]) .. ")")
	end
end

---Distance between the two selected objects' centers, or nil
function MSV2.selectionDistance()
	local list = MSV2.selList()
	local tris, plain = MSV2.selSplit()
	if (#plain == 2 and next(tris) == nil) then
		return V.dist(MSV2.objPos(plain[1]), MSV2.objPos(plain[2]))
	end
	return nil
end

---------------------------------------------------------------------------
-- Whole-player placement + dojo
---------------------------------------------------------------------------

---Average drawn position of a player's body parts
function MSV2.playerWorldCenter(p)
	local sum, n = { 0, 0, 0 }, 0
	for b = 0, MSV2.NUM_BODIES - 1 do
		local w = MSV2.bodyWorld(p, b)
		if (w) then sum = V.add(sum, w.pos); n = n + 1 end
	end
	if (n == 0) then return nil end
	return V.mul(sum, 1 / n)
end

function MSV2.playerModCenter(p)
	local sum, n = { 0, 0, 0 }, 0
	for b = 0, MSV2.NUM_BODIES - 1 do
		local o = MSV2.bodies[p] and MSV2.bodies[p][b]
		if (o) then sum = V.add(sum, { o.pos_x, o.pos_y, o.pos_z }); n = n + 1 end
	end
	if (n == 0) then return nil end
	return V.mul(sum, 1 / n)
end

---Dojo center on the floor: halfway between the players as the game draws them
function MSV2.dojoCenter()
	local a, b = MSV2.playerWorldCenter(0), MSV2.playerWorldCenter(1)
	if (a and b) then return { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, 0 } end
	if (a) then return { a[1], a[2], 0 } end
	return { 1, -0.1, 0 }
end

---Dojo half-width (square) or radius (round) in world units, type, raw size
function MSV2.dojoShape()
	local size = tonumber(MSV2.getRule("dojosize") or "") or 0
	local kind = tonumber(MSV2.getRule("dojotype") or "") or 0
	if (size <= 0) then return nil end
	-- Square: size is the full width. Round: size is the radius. Both in 1/100 units.
	local r = kind == 1 and size / 100 or size / 200
	return r, kind, size
end

function MSV2.setDojoFromRadius(r)
	local _, kind = MSV2.dojoShape()
	kind = kind or (tonumber(MSV2.getRule("dojotype") or "") or 0)
	local size = kind == 1 and r * 100 or r * 200
	MSV2.setRule("dojosize", math.max(0, floor(size + 0.5)))
end

---------------------------------------------------------------------------
-- Arc / curve generators
---------------------------------------------------------------------------

MSV2.arcGen = MSV2.arcGen or {
	kind = "arch", radius = 2, thick = 0.25, width = 2, segments = 12, span = 180,
	spiralSteps = 12, spiralRise = 0.25, spiralTurns = 1
}

---Builds boxes along an arc. Frames: r (radial), t (tangent), a = r x t.
---`pointAt(theta)` returns center, radial, tangent (all unit except center).
local function buildArc(name, segs, span, radius, thick, width, startAngle, frame, color, group)
	local list = {}
	local dTheta = span / segs
	local segLen = 2 * (radius + thick) * math.tan(rad(dTheta) / 2) * 1.02
	for i = 0, segs - 1 do
		local th = startAngle + dTheta * (i + 0.5)
		local center, r, t = frame(th)
		local a = V.cross(r, t)
		local R = M.fromCols(r, t, a)
		local pos = V.add(center, V.mul(r, radius + thick / 2))
		local ex, ey, ez = M.toEuler(R)
		local idx = MSV2.createObj({
			type = 1, dims_x = thick, dims_y = segLen, dims_z = width,
			pos_x = pos[1], pos_y = pos[2], pos_z = pos[3],
			rot_x = ex, rot_y = ey, rot_z = ez,
			color_r = color[1], color_g = color[2], color_b = color[3], static = true, mass = 1
		}, { name = name .. " " .. (i + 1), group = group })
		if (not idx) then break end
		table.insert(list, idx)
	end
	return list
end

local function selectList(list)
	MSV2.sel = {}
	for _, idx in ipairs(list) do MSV2.sel[idx] = true end
	MSV2.primary = list[1]
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
end

function MSV2.genArc(kind)
	local g = MSV2.arcGen
	kind = kind or g.kind
	local p = MSV2.spawnPoint()
	local c = MSV2.nextColor()
	local segs = math.max(2, floor(g.segments))
	local R, T, W = g.radius, g.thick, g.width
	MSV2.pushUndo("Build " .. kind)
	local list
	if (kind == "arch") then
		-- Vertical half circle over the spawn point, walkway along Y
		local base = { p[1], p[2], 0 }
		list = buildArc("Arch", segs, g.span, R, T, W, 0, function(th)
			local r = { cos(rad(th)), 0, sin(rad(th)) }
			local t = { -sin(rad(th)), 0, cos(rad(th)) }
			return base, r, t
		end, c, "Arch")
	elseif (kind == "quarterpipe") then
		-- Curved ramp: floor curving up into a wall (inside surface)
		local center = { p[1], p[2], R + T }
		list = buildArc("Quarter pipe", segs, 90, R, T, W, -90, function(th)
			local r = { cos(rad(th)), 0, sin(rad(th)) }
			local t = { -sin(rad(th)), 0, cos(rad(th)) }
			return center, r, t
		end, c, "Quarter pipe")
	elseif (kind == "tunnel") then
		local center = { p[1], p[2], R + T }
		list = buildArc("Tunnel", segs, 360, R, T, W, -90, function(th)
			local r = { cos(rad(th)), 0, sin(rad(th)) }
			local t = { -sin(rad(th)), 0, cos(rad(th)) }
			return center, r, t
		end, c, "Tunnel")
	elseif (kind == "curvedwall") then
		-- Wall bending around the vertical axis (good for round arenas)
		local center = { p[1], p[2], W / 2 }
		list = buildArc("Curved wall", segs, g.span, R, T, W, 0, function(th)
			local r = { cos(rad(th)), sin(rad(th)), 0 }
			local t = { -sin(rad(th)), cos(rad(th)), 0 }
			return center, r, t
		end, c, "Curved wall")
	elseif (kind == "spiral") then
		list = {}
		local steps = math.max(2, floor(g.spiralSteps))
		local turns = math.max(0.1, g.spiralTurns)
		local dTheta = 360 * turns / steps
		local stepW = 2 * R * math.tan(rad(dTheta) / 2) * 1.05
		for i = 0, steps - 1 do
			local th = rad(dTheta * i)
			local r = { cos(th), sin(th), 0 }
			local t = { -sin(th), cos(th), 0 }
			local Rm = M.fromCols(r, t, { 0, 0, 1 })
			local ex, ey, ez = M.toEuler(Rm)
			local h = g.spiralRise * (i + 1)
			local pos = V.add({ p[1], p[2], h - 0.05 }, V.mul(r, R / 2 + 0.15))
			local idx = MSV2.createObj({
				type = 1, dims_x = R, dims_y = stepW, dims_z = 0.1,
				pos_x = pos[1], pos_y = pos[2], pos_z = pos[3], rot_x = ex, rot_y = ey, rot_z = ez,
				color_r = c[1], color_g = c[2], color_b = c[3], static = true, mass = 1
			}, { name = "Spiral step " .. (i + 1), group = "Spiral stairs" })
			if (not idx) then break end
			table.insert(list, idx)
		end
		local pole = MSV2.createObj({
			type = 1, dims_x = 0.3, dims_y = 0.3, dims_z = g.spiralRise * steps,
			pos_x = p[1], pos_y = p[2], pos_z = g.spiralRise * steps / 2,
			color_r = 0.6, color_g = 0.6, color_b = 0.62, static = true, mass = 1
		}, { name = "Spiral pole", group = "Spiral stairs" })
		if (pole) then table.insert(list, pole) end
	end
	list = list or {}
	selectList(list)
	MSV2.toast("Built " .. #list .. " pieces")
	return list
end

---------------------------------------------------------------------------
-- Prefab library (saved in data/script/modstudiov2/prefabsv2/*.msf)
---------------------------------------------------------------------------

MSV2.PREFAB_DIR = "modstudiov2/prefabsv2/"

---Copies the selection with positions relative to its bottom-center
function MSV2.selectionAsPrefab()
	local clip = MSV2.copySelection()
	if (not clip) then return nil end
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	local function grow(p, e)
		for k = 1, 3 do
			lo[k] = math.min(lo[k], p[k] - e[k] / 2)
			hi[k] = math.max(hi[k], p[k] + e[k] / 2)
		end
	end
	for _, item in ipairs(clip.objs) do
		local f = item.fields
		grow({ f.pos_x, f.pos_y, f.pos_z }, MSV2.shapeExtents(f.type, f.dims_x, f.dims_y, f.dims_z))
	end
	for _, t in ipairs(clip.tris) do
		for _, key in ipairs({ "a", "b", "c" }) do grow(t[key], { t.thick, t.thick, t.thick }) end
	end
	local origin = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, lo[3] }
	for _, item in ipairs(clip.objs) do
		local f = item.fields
		f.pos_x, f.pos_y, f.pos_z = f.pos_x - origin[1], f.pos_y - origin[2], f.pos_z - origin[3]
	end
	for _, t in ipairs(clip.tris) do
		for _, key in ipairs({ "a", "b", "c" }) do t[key] = V.sub(t[key], origin) end
	end
	return clip
end

function MSV2.savePrefab(name)
	name = MSV2.safeName(name)
	local clip = MSV2.selectionAsPrefab()
	if (not clip) then
		MSV2.toast("Select what you want to save as a prefab first")
		return false
	end
	clip.name = name
	if (MSV2.writeFile(MSV2.PREFAB_DIR .. name .. ".msf", "return " .. MSV2.serialize(clip))) then
		MSV2.toast("Saved prefab \"" .. name .. "\" - find it in the Library tab")
		return true
	end
	MSV2.toast("Couldn't save - is data/script/modstudiov2/prefabsv2/ missing?")
	return false
end

function MSV2.listPrefabs()
	local list = {}
	local ok, files = pcall(get_files, "data/script/modstudiov2/prefabsv2", "")
	if (ok and type(files) == "table") then
		for _, v in pairs(files) do
			if (type(v) == "string" and v:match("%.msf$")) then
				local name = v:gsub("%.msf$", "")
				-- Deleted prefabs are emptied files (scripts can't delete files)
				if (MSV2.readData(MSV2.PREFAB_DIR .. name .. ".msf")) then table.insert(list, name) end
			end
		end
	end
	table.sort(list)
	return list
end

function MSV2.deletePrefabFile(name)
	MSV2.writeFile(MSV2.PREFAB_DIR .. name .. ".msf", "return nil")
	MSV2.toast("Deleted prefab \"" .. name .. "\"")
end

---Built-in starter prefabs (positions relative to bottom-center)
local function box(x, y, z, sx, sy, sz, col, extra)
	local f = { type = 1, pos_x = x, pos_y = y, pos_z = z, dims_x = sx, dims_y = sy, dims_z = sz, rot_x = 0, rot_y = 0, rot_z = 0,
		color_r = col[1], color_g = col[2], color_b = col[3], color_a = 1, static = true, visible = true, mass = 1 }
	for k, v in pairs(extra or {}) do f[k] = v end
	return { fields = f, meta = {} }
end

MSV2.BUILTIN_PREFABS = {
	{ name = "Doorway", clip = { objs = {
		box(-0.9, 0, 1.1, 0.3, 0.3, 2.2, { 0.55, 0.4, 0.3 }), box(0.9, 0, 1.1, 0.3, 0.3, 2.2, { 0.55, 0.4, 0.3 }),
		box(0, 0, 2.35, 2.1, 0.35, 0.3, { 0.45, 0.32, 0.25 }) }, tris = {} } },
	{ name = "Pillar with cap", clip = { objs = {
		box(0, 0, 0.1, 0.9, 0.9, 0.2, { 0.7, 0.7, 0.72 }), box(0, 0, 1.4, 0.5, 0.5, 2.4, { 0.85, 0.85, 0.87 }),
		box(0, 0, 2.7, 0.9, 0.9, 0.2, { 0.7, 0.7, 0.72 }) }, tris = {} } },
	{ name = "Table", clip = { objs = {
		box(0, 0, 0.85, 1.6, 1, 0.1, { 0.6, 0.42, 0.25 }),
		box(-0.7, -0.4, 0.4, 0.1, 0.1, 0.8, { 0.5, 0.35, 0.2 }), box(0.7, -0.4, 0.4, 0.1, 0.1, 0.8, { 0.5, 0.35, 0.2 }),
		box(-0.7, 0.4, 0.4, 0.1, 0.1, 0.8, { 0.5, 0.35, 0.2 }), box(0.7, 0.4, 0.4, 0.1, 0.1, 0.8, { 0.5, 0.35, 0.2 }) }, tris = {} } },
	{ name = "Bounce pad", clip = { objs = {
		box(0, 0, 0.05, 1.5, 1.5, 0.1, { 0.2, 0.85, 0.4 }, { bounce = 1, hardness = 0.2, friction = 0.6 }) }, tris = {} } },
	{ name = "Bridge", clip = { objs = {
		box(0, 0, 1.5, 6, 1.6, 0.15, { 0.55, 0.4, 0.28 }),
		box(0, -0.75, 1.9, 6, 0.08, 0.08, { 0.45, 0.32, 0.22 }), box(0, 0.75, 1.9, 6, 0.08, 0.08, { 0.45, 0.32, 0.22 }),
		box(-2.9, 0, 0.75, 0.3, 1.6, 1.5, { 0.6, 0.6, 0.62 }), box(2.9, 0, 0.75, 0.3, 1.6, 1.5, { 0.6, 0.6, 0.62 }) }, tris = {} } }
}

function MSV2.loadPrefab(name)
	for _, b in ipairs(MSV2.BUILTIN_PREFABS) do
		if (b.name == name) then return MSV2.deepcopy(b.clip) end
	end
	local data = MSV2.readData(MSV2.PREFAB_DIR .. name .. ".msf")
	if (data and data.objs) then return data end
	return nil
end

---Places a prefab where the camera is looking (or at `at`)
function MSV2.placePrefab(name, at)
	local clip = MSV2.loadPrefab(name)
	if (not clip) then
		MSV2.toast("Couldn't read prefab " .. tostring(name))
		return {}
	end
	MSV2.pushUndo("Place " .. name)
	local p = at or MSV2.spawnPoint()
	local list = MSV2.pasteClip(clip, { p[1], p[2], 0 })
	MSV2.toast("Placed " .. name .. " (" .. #list .. " objects)")
	return list
end

---------------------------------------------------------------------------
-- Presets: physics surfaces (reliable) and touch triggers (experimental)
---------------------------------------------------------------------------

MSV2.SURFACE_PRESETS = {
	{ name = "Bounce pad", tip = "Launches whatever lands on it", fields = { bounce = 1, hardness = 0.2, friction = 0.6, static = true }, color = { 0.2, 0.85, 0.4 } },
	{ name = "Ice", tip = "Almost no grip", fields = { friction = 0.01, hardness = 0.5, bounce = 0, static = true }, color = { 0.75, 0.9, 1 } },
	{ name = "Sticky", tip = "Very grippy", fields = { friction = 3, hardness = 0.2, bounce = 0, static = true }, color = { 0.85, 0.6, 0.2 } },
	{ name = "Pushable", tip = "A loose physics block", fields = { static = false, mass = 0.6, friction = 0.5 }, color = { 0.6, 0.45, 0.3 } },
	{ name = "Ghost wall", tip = "Invisible but solid", fields = { visible = false, static = true, color_a = 0.3 }, color = nil }
}

-- Touch triggers fire when something whose Group (trig_id) bits overlap this
-- object's Collide-with (trig_mask) bits touches it. Players need a group too.
MSV2.TRIGGER_PRESETS = {
	{ name = "Score pad +100", tip = "Gives points when a player touches it (once)", score = 100, once = true, color = { 0.2, 0.9, 0.3, 1 } },
	{ name = "Penalty zone -100", tip = "Takes points when a player touches it", score = -100, once = false, color = { 0.95, 0.2, 0.2, 1 } },
	{ name = "Color flash", tip = "Changes color when a player touches it", score = 0, once = false, color = { 1, 0.9, 0.2, 1 } }
}

function MSV2.applySurfacePreset(i)
	local pr = MSV2.SURFACE_PRESETS[i]
	local list = MSV2.selList()
	if (#list == 0) then
		MSV2.toast("Select the objects to turn into a " .. pr.name)
		return
	end
	MSV2.pushUndo(pr.name)
	for _, idx in ipairs(list) do
		for f, v in pairs(pr.fields) do MSV2.objSet(idx, f, v) end
		if (pr.color) then
			MSV2.objSet(idx, "color_r", pr.color[1])
			MSV2.objSet(idx, "color_g", pr.color[2])
			MSV2.objSet(idx, "color_b", pr.color[3])
		end
	end
	MSV2.toast(pr.name .. " applied to " .. #list .. " object" .. (#list == 1 and "" or "s"))
end

---Puts every body part of each player into its own trigger group (Tori 1, Uke 2)
---if they don't have one yet. Returns how many parts changed.
function MSV2.ensurePlayerTriggerGroups()
	local changed = 0
	for p = 0, math.max(1, MSV2.numPlayers) - 1 do
		local bit = p == 0 and 1 or (p == 1 and 2 or 0)
		if (bit > 0) then
			for b = 0, MSV2.NUM_BODIES - 1 do
				local o = MSV2.bodies[p] and MSV2.bodies[p][b]
				if (o and (o.trig_id or 0) == 0) then
					MSV2.bodySet(p, b, "trig_id", bit)
					changed = changed + 1
				end
			end
		end
	end
	return changed
end

function MSV2.applyTriggerPreset(i)
	local pr = MSV2.TRIGGER_PRESETS[i]
	local list = MSV2.selList()
	if (#list == 0) then
		MSV2.toast("Select the objects to turn into a " .. pr.name)
		return
	end
	MSV2.pushUndo(pr.name)
	local groups = MSV2.ensurePlayerTriggerGroups()
	for _, idx in ipairs(list) do
		MSV2.objSet(idx, "trig_mask", 3)
		MSV2.objSet(idx, "trig_score", pr.score)
		MSV2.objSet(idx, "trig_scoreonce", pr.once)
		MSV2.objSet(idx, "trig_color_r", pr.color[1])
		MSV2.objSet(idx, "trig_color_g", pr.color[2])
		MSV2.objSet(idx, "trig_color_b", pr.color[3])
		MSV2.objSet(idx, "trig_color_a", pr.color[4])
	end
	MSV2.toast(pr.name .. " set up" .. (groups > 0 and " (players were given trigger groups)" or "") .. " - try it with Test")
end

---------------------------------------------------------------------------
-- Moving obstacles: physics objects hinged to a fixed anchor with links.
-- Hinge limits beyond +-pi are ignored by the physics engine, so +-10 means
-- "spins forever". maxvelocity is the motor speed, maxforce its strength.
---------------------------------------------------------------------------

MSV2.moverGen = MSV2.moverGen or { size = 1, speed = 4, strength = 800 }

local FREE = 10 -- hinge limit that means "no limit"

---Hinges b to a at `pos` around `axis`. o: lo, hi, force, speed
local function hinge(a, b, pos, axis, o)
	if (not a or not b) then return nil end
	o = o or {}
	local ok, n = pcall(create_mod_envjoint, a, b)
	if (not ok or n == nil) then return nil end
	MSV2.readEJ(n)
	MSV2.ejSet(n, "pos_x", pos[1]); MSV2.ejSet(n, "pos_y", pos[2]); MSV2.ejSet(n, "pos_z", pos[3])
	MSV2.ejSet(n, "axis_x", axis[1]); MSV2.ejSet(n, "axis_y", axis[2]); MSV2.ejSet(n, "axis_z", axis[3])
	MSV2.ejSet(n, "histop", o.hi or FREE)
	MSV2.ejSet(n, "lostop", o.lo or -FREE)
	MSV2.ejSet(n, "maxforce", o.force or 0)
	MSV2.ejSet(n, "maxvelocity", o.speed or 0)
	MSV2.ejSet(n, "visible", o.visible == true)
	return n
end

local function piece(f, name, group)
	f.type = f.type or 1
	f.rot_x, f.rot_y, f.rot_z = f.rot_x or 0, f.rot_y or 0, f.rot_z or 0
	if (f.static == nil) then f.static = false end
	f.mass = f.mass or 1
	return MSV2.createObj(f, { name = name, group = group })
end

local function col(c, f) f.color_r, f.color_g, f.color_b = c[1], c[2], c[3]; return f end

local METAL, DARK, WOOD, RED = { 0.7, 0.72, 0.75 }, { 0.3, 0.3, 0.33 }, { 0.6, 0.42, 0.25 }, { 0.85, 0.2, 0.2 }

MSV2.MOVERS = {
	{ id = "spinner", name = "Spinning blade", tip = "A bar that spins round on a post - jump it or get swept",
		build = function(p, s, g)
			local post = piece(col(DARK, { pos_x = p[1], pos_y = p[2], pos_z = 0.5 * s, dims_x = 0.35 * s, dims_y = 0.35 * s, dims_z = s, static = true }), "Spinner post", "Spinner")
			local blade = piece(col(RED, { pos_x = p[1], pos_y = p[2], pos_z = s + 0.1 * s, dims_x = 3.2 * s, dims_y = 0.3 * s, dims_z = 0.15 * s, mass = 2 * s }), "Spinner blade", "Spinner")
			hinge(post, blade, { p[1], p[2], s + 0.05 * s }, { 0, 0, 1 }, { force = g.strength, speed = g.speed })
			return { post, blade }
		end },
	{ id = "turntable", name = "Turntable", tip = "A platform that slowly turns",
		build = function(p, s, g)
			local base = piece(col(DARK, { pos_x = p[1], pos_y = p[2], pos_z = 0.1 * s, dims_x = 0.6 * s, dims_y = 0.6 * s, dims_z = 0.2 * s, static = true }), "Turntable base", "Turntable")
			local top = piece(col(METAL, { pos_x = p[1], pos_y = p[2], pos_z = 0.28 * s, dims_x = 3 * s, dims_y = 3 * s, dims_z = 0.15 * s, mass = 5 * s, friction = 0.8 }), "Turntable", "Turntable")
			hinge(base, top, { p[1], p[2], 0.2 * s }, { 0, 0, 1 }, { force = g.strength * 2, speed = g.speed * 0.25 })
			return { base, top }
		end },
	{ id = "hammer", name = "Swinging hammer", tip = "A heavy hammer swinging back and forth from a frame",
		build = function(p, s, g)
			local H = 3.4 * s
			local beam = piece(col(DARK, { pos_x = p[1], pos_y = p[2], pos_z = H, dims_x = 0.3 * s, dims_y = 2 * s, dims_z = 0.3 * s, static = true }), "Hammer beam", "Hammer")
			local l = piece(col(DARK, { pos_x = p[1], pos_y = p[2] - s, pos_z = H / 2, dims_x = 0.3 * s, dims_y = 0.3 * s, dims_z = H, static = true }), "Hammer post", "Hammer")
			local r = piece(col(DARK, { pos_x = p[1], pos_y = p[2] + s, pos_z = H / 2, dims_x = 0.3 * s, dims_y = 0.3 * s, dims_z = H, static = true }), "Hammer post", "Hammer")
			local arm = piece(col(METAL, { pos_x = p[1], pos_y = p[2], pos_z = H - 1.1 * s, dims_x = 0.15 * s, dims_y = 0.15 * s, dims_z = 2.2 * s, mass = s }), "Hammer arm", "Hammer")
			local head = piece(col(RED, { pos_x = p[1], pos_y = p[2], pos_z = H - 2.4 * s, dims_x = 1.2 * s, dims_y = 0.6 * s, dims_z = 0.6 * s, mass = 6 * s,
				force_x = 40 * s }), "Hammer head", "Hammer")
			-- Free swing on the beam, head locked to the arm
			hinge(beam, arm, { p[1], p[2], H }, { 0, 1, 0 }, { force = 0 })
			hinge(arm, head, { p[1], p[2], H - 2.2 * s }, { 0, 1, 0 }, { lo = 0, hi = 0, force = 100000 })
			return { beam, l, r, arm, head }
		end },
	{ id = "wreckingball", name = "Wrecking ball", tip = "A heavy ball on a rod, already swinging",
		build = function(p, s, g)
			local H = 4.5 * s
			local anchor = piece(col(DARK, { pos_x = p[1], pos_y = p[2], pos_z = H, dims_x = 0.4 * s, dims_y = 0.4 * s, dims_z = 0.4 * s, static = true }), "Wrecking ball anchor", "Wrecking ball")
			local rod = piece(col(METAL, { pos_x = p[1], pos_y = p[2], pos_z = H - 1.4 * s, dims_x = 0.08 * s, dims_y = 0.08 * s, dims_z = 2.8 * s, mass = 0.3 * s }), "Wrecking ball rod", "Wrecking ball")
			local ball = piece(col(DARK, { type = 0, pos_x = p[1], pos_y = p[2], pos_z = H - 3.2 * s, dims_x = 0.6 * s, dims_y = 0.6 * s, dims_z = 0.6 * s, mass = 10 * s,
				force_y = 80 * s }), "Wrecking ball", "Wrecking ball")
			hinge(anchor, rod, { p[1], p[2], H }, { 1, 0, 0 }, { force = 0 })
			hinge(rod, ball, { p[1], p[2], H - 2.8 * s }, { 1, 0, 0 }, { lo = 0, hi = 0, force = 100000 })
			return { anchor, rod, ball }
		end },
	{ id = "seesaw", name = "See-saw", tip = "A plank that tips when someone stands on one end",
		build = function(p, s, g)
			local base = piece(col(DARK, { pos_x = p[1], pos_y = p[2], pos_z = 0.25 * s, dims_x = 0.4 * s, dims_y = 1.2 * s, dims_z = 0.5 * s, static = true }), "See-saw base", "See-saw")
			local plank = piece(col(WOOD, { pos_x = p[1], pos_y = p[2], pos_z = 0.56 * s, dims_x = 4.5 * s, dims_y = 1.2 * s, dims_z = 0.12 * s, mass = 2 * s, friction = 0.8 }), "See-saw plank", "See-saw")
			hinge(base, plank, { p[1], p[2], 0.5 * s }, { 0, 1, 0 }, { lo = -0.35, hi = 0.35, force = 0 })
			return { base, plank }
		end },
	{ id = "door", name = "Swinging door", tip = "A door on a hinge that swings when pushed",
		build = function(p, s, g)
			local post = piece(col(DARK, { pos_x = p[1], pos_y = p[2], pos_z = 1.1 * s, dims_x = 0.2 * s, dims_y = 0.2 * s, dims_z = 2.2 * s, static = true }), "Door post", "Door")
			local door = piece(col(WOOD, { pos_x = p[1] + 0.72 * s, pos_y = p[2], pos_z = 1.05 * s, dims_x = 1.2 * s, dims_y = 0.12 * s, dims_z = 2 * s, mass = 1.5 * s }), "Door", "Door")
			hinge(post, door, { p[1] + 0.1 * s, p[2], 1.05 * s }, { 0, 0, 1 }, { lo = -1.6, hi = 1.6, force = 0 })
			return { post, door }
		end }
}

function MSV2.genMover(id)
	local def
	for _, m in ipairs(MSV2.MOVERS) do if (m.id == id) then def = m end end
	if (not def) then return {} end
	local g = MSV2.moverGen
	local list = {}
	MSV2.withUndo("Build " .. def.name, function()
		local p = MSV2.spawnPoint()
		for _, idx in ipairs(def.build(p, math.max(0.2, g.size), g)) do
			if (idx) then table.insert(list, idx) end
		end
	end)
	MSV2.sel = {}
	for _, idx in ipairs(list) do MSV2.sel[idx] = true end
	MSV2.primary = list[1]
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
	MSV2.toast("Built a " .. def.name .. " - press Test to watch it move")
	return list
end

---------------------------------------------------------------------------
-- Mod templates: start a new mod with objects AND rules set up
---------------------------------------------------------------------------

local function at(c, dx, dy) return { c[1] + dx, c[2] + dy, 0 } end

local function floorTile(c, sx, sy, color, name, z)
	return MSV2.createObj({ type = 1, pos_x = c[1], pos_y = c[2], pos_z = (z or 0) + 0.05, dims_x = sx, dims_y = sy, dims_z = 0.1,
		color_r = color[1], color_g = color[2], color_b = color[3], static = true, mass = 1, friction = 0.6 }, { name = name, group = "Floor" })
end

MSV2.TEMPLATES = {
	{ id = "sumo", name = "Sumo ring", desc = "Round ring - push your opponent out. Leaving the ring loses instantly.",
		rules = { matchframes = 500, turnframes = "30", dojotype = 1, dojosize = 300, dqflag = 1, dqtimeout = 0, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 1,
		build = function(c)
			floorTile(c, 7, 7, { 0.82, 0.72, 0.52 }, "Ring floor")
			MSV2.spawnOverride = { c[1], c[2], 0 }
			local g = MSV2.arcGen
			local old = { g.radius, g.thick, g.width, g.segments, g.span }
			g.radius, g.thick, g.width, g.segments, g.span = 3, 0.2, 0.15, 32, 360
			MSV2.genArc("curvedwall")
			g.radius, g.thick, g.width, g.segments, g.span = old[1], old[2], old[3], old[4], old[5]
		end },
	{ id = "aikido", name = "Aikido mat", desc = "The classic aikido rules: heavy gravity, square dojo, DQ + dismemberment + fracture.",
		rules = { gravity = "0 0 -30", engagedistance = 90, dismemberthreshold = 325, fracturethreshold = 200, matchframes = 350,
			turnframes = "10,20,20,30,30,35,35,40,40,40,50", dojosize = 450, dojotype = 0, sumo = 1 },
		flags = 11,
		build = function(c)
			floorTile(c, 4.5, 4.5, { 0.85, 0.82, 0.62 }, "Tatami")
			floorTile(c, 6, 6, { 0.35, 0.25, 0.2 }, "Mat border", -0.02)
		end },
	{ id = "brawl", name = "Arena brawl", desc = "Walled arena, limbs come off easily. No dojo, no DQ.",
		rules = { matchframes = 800, turnframes = "30", dojosize = 0, dismemberthreshold = 100, fracturethreshold = 100, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 10,
		build = function(c)
			local g = MSV2.gen
			local old = g.arenaSize
			g.arenaSize = 10
			MSV2.genArena()
			g.arenaSize = old
		end },
	{ id = "parkour", name = "Parkour course", desc = "A line of platforms with gaps, a ramp and a goal. Long match, no DQ.",
		rules = { matchframes = 2000, turnframes = "20", dojosize = 0, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 0,
		build = function(c)
			local fwd = MSV2.toriAxes and MSV2.toriAxes() or { 0, 1, 0 }
			local function along(d, h, sx, sy, color, name)
				local p = { c[1] + fwd[1] * d, c[2] + fwd[2] * d }
				return MSV2.createObj({ type = 1, pos_x = p[1], pos_y = p[2], pos_z = h - 0.1, dims_x = sx, dims_y = sy, dims_z = 0.2,
					rot_z = math.deg(math.atan2(fwd[2], fwd[1])) - 90,
					color_r = color[1], color_g = color[2], color_b = color[3], static = true, mass = 1, friction = 0.7 }, { name = name, group = "Course" })
			end
			floorTile(c, 4, 4, { 0.6, 0.6, 0.64 }, "Start")
			local col = { 0.3, 0.55, 0.95 }
			along(4, 0.4, 1.6, 1.6, col, "Platform 1")
			along(6.5, 0.8, 1.4, 1.4, col, "Platform 2")
			along(9, 1.2, 1.2, 1.2, col, "Platform 3")
			along(11.5, 1.4, 1, 1, col, "Platform 4")
			along(14.5, 1.4, 2.5, 2.5, { 0.2, 0.85, 0.35 }, "Goal")
		end },
	{ id = "moon", name = "Moon fight", desc = "Very low gravity and floating platforms to jump between.",
		rules = { matchframes = 800, turnframes = "40", dojosize = 0, engagedistance = 80, gravity = "0 0 -3" },
		flags = 0,
		build = function(c)
			floorTile(c, 6, 6, { 0.55, 0.55, 0.6 }, "Moon floor")
			local plat = { 0.75, 0.75, 0.82 }
			for i, o in ipairs({ { 3.5, 0, 1.5 }, { -3.5, 0, 1.5 }, { 0, 3.5, 2.5 }, { 0, -3.5, 2.5 }, { 2.5, 2.5, 3.5 } }) do
				MSV2.createObj({ type = 1, pos_x = c[1] + o[1], pos_y = c[2] + o[2], pos_z = o[3], dims_x = 1.6, dims_y = 1.6, dims_z = 0.2,
					color_r = plat[1], color_g = plat[2], color_b = plat[3], static = true, mass = 1 }, { name = "Floating platform " .. i, group = "Platforms" })
			end
		end },
	{ id = "obstacles", name = "Obstacle course", desc = "Spinning blades, a swinging hammer and a see-saw between you and the goal.",
		rules = { matchframes = 1500, turnframes = "20", dojosize = 0, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 0,
		build = function(c)
			local fwd = MSV2.toriAxes and MSV2.toriAxes() or { 0, 1, 0 }
			local function p(d) return { c[1] + fwd[1] * d, c[2] + fwd[2] * d, 0 } end
			MSV2.createObj({ type = 1, pos_x = p(9)[1], pos_y = p(9)[2], pos_z = -0.05, dims_x = 6, dims_y = 6, dims_z = 0.1,
				rot_z = math.deg(math.atan2(fwd[2], fwd[1])) - 90, color_r = 0.55, color_g = 0.55, color_b = 0.6, static = true, mass = 1 }, { name = "Course floor", group = "Course" })
			local g = MSV2.moverGen
			local oldSize = g.size
			g.size = 1
			for _, item in ipairs({ { "spinner", 4 }, { "hammer", 8 }, { "seesaw", 12 }, { "spinner", 16 } }) do
				local def
				for _, m in ipairs(MSV2.MOVERS) do if (m.id == item[1]) then def = m end end
				def.build(p(item[2]), 1, g)
			end
			g.size = oldSize
			floorTile(p(19), 2.5, 2.5, { 0.2, 0.85, 0.35 }, "Goal")
		end }
}

---Feature showcase: one of everything, laid out around the players.
---  ahead: arch over a walkway, score pad, stairs + bridge
---  right: ramp + upright triangle, ice patch, pyramid of physics blocks
---  left:  spinner, see-saw, swinging door, wrecking ball, bounce pad
---  behind: spiral stairs, doorway prefab
local function buildShowcase(c)
	local fwd, right = { 0, 1, 0 }, { 1, 0, 0 }
	if (MSV2.toriAxes) then fwd, right = MSV2.toriAxes() end
	local function P(df, dr, z)
		return { c[1] + fwd[1] * df + right[1] * dr, c[2] + fwd[2] * df + right[2] * dr, z or 0 }
	end
	local function spawnAt(df, dr) MSV2.spawnOverride = P(df, dr) end
	local function name(list, group)
		for _, idx in ipairs(list or {}) do
			MSV2.meta[idx] = MSV2.meta[idx] or {}
			MSV2.meta[idx].group = group
		end
	end

	-- Ahead: arch over a walkway, with a score pad past it
	local g = MSV2.arcGen
	local saved = MSV2.deepcopy(g)
	g.radius, g.thick, g.width, g.segments, g.span = 1.6, 0.2, 1.6, 10, 180
	spawnAt(7, 0)
	name(MSV2.genArc("arch"), "Showcase: curves")
	local scorePad = MSV2.createObj({ type = 1, pos_x = P(10, 0)[1], pos_y = P(10, 0)[2], pos_z = 0.05, dims_x = 1.5, dims_y = 1.5, dims_z = 0.1,
		color_r = 0.2, color_g = 0.9, color_b = 0.3, static = true, mass = 1 }, { name = "Score pad (+100)", group = "Showcase: triggers" })
	if (scorePad) then
		MSV2.sel = { [scorePad] = true }
		MSV2.applyTriggerPreset(1)
	end
	-- Stairs up to a bridge
	local gen = MSV2.gen
	local oldSteps, oldRise, oldRun, oldW = gen.stairsSteps, gen.stairsRise, gen.stairsRun, gen.stairsWidth
	gen.stairsSteps, gen.stairsRise, gen.stairsRun, gen.stairsWidth = 5, 0.3, 0.4, 1.6
	spawnAt(7, 6)
	name(MSV2.genStairs and (function() MSV2.genStairs(); return MSV2.selList() end)(), "Showcase: generators")
	gen.stairsSteps, gen.stairsRise, gen.stairsRun, gen.stairsWidth = oldSteps, oldRise, oldRun, oldW
	name(MSV2.placePrefab("Bridge", P(11, 6)), "Showcase: prefabs")

	-- Right: triangles, ice, physics pyramid
	local rp = P(0, 7)
	MSV2.triCreate({ rp[1] - 1.5, rp[2], 0 }, { rp[1] + 1.5, rp[2], 0 }, { rp[1] + 1.5, rp[2], 1.2 },
		{ thick = 2, slices = 10, smooth = "ca", name = "Ramp (triangle)" })
	local fp = P(-3.5, 7)
	MSV2.triCreate({ fp[1] - 0.9, fp[2], 0 }, { fp[1] + 0.9, fp[2], 0 }, { fp[1], fp[2], 1.5 },
		{ thick = 0.2, slices = 8, name = "Upright triangle" })
	local ice = MSV2.createObj({ type = 1, pos_x = P(3.5, 7)[1], pos_y = P(3.5, 7)[2], pos_z = 0.05, dims_x = 2.5, dims_y = 2.5, dims_z = 0.1,
		color_r = 0.75, color_g = 0.9, color_b = 1, static = true, mass = 1 }, { name = "Ice patch", group = "Showcase: surfaces" })
	if (ice) then MSV2.sel = { [ice] = true }; MSV2.applySurfacePreset(2) end
	local oldLevels = gen.pyramidLevels
	gen.pyramidLevels = 3
	spawnAt(-7, 6)
	MSV2.genPyramid()
	name(MSV2.selList(), "Showcase: physics")
	gen.pyramidLevels = oldLevels

	-- Left: moving obstacles
	local mg = MSV2.moverGen
	local oldSize = mg.size
	mg.size = 1
	for _, item in ipairs({ { "spinner", 3, -7 }, { "seesaw", -1, -7 }, { "door", -4.5, -7 }, { "wreckingball", 7, -6 } }) do
		for _, m in ipairs(MSV2.MOVERS) do
			if (m.id == item[1]) then
				local list = m.build(P(item[2], item[3]), 1, mg)
				name(list, "Showcase: moving")
			end
		end
	end
	mg.size = oldSize
	name(MSV2.placePrefab("Bounce pad", P(4, -3.5)), "Showcase: surfaces")

	-- Behind: spiral stairs and a doorway
	g.spiralSteps, g.spiralTurns, g.spiralRise, g.radius = 10, 1, 0.25, 1.4
	spawnAt(-8, 0)
	name(MSV2.genArc("spiral"), "Showcase: curves")
	name(MSV2.placePrefab("Doorway", P(-4, -2.5)), "Showcase: prefabs")

	for k, v in pairs(saved) do g[k] = v end
	MSV2.spawnOverride = nil
	pcall(set_mod_message, "Mod Studio showcase - curves, triangles, moving obstacles, prefabs and presets")
end

table.insert(MSV2.TEMPLATES, 1, {
	id = "showcase", name = "Feature showcase",
	desc = "One of everything: curves, triangles, moving obstacles, prefabs, presets and triggers.",
	rules = { matchframes = 1500, turnframes = "20", dojosize = 0, engagedistance = 80, gravity = "0 0 -9.82",
		dismemberthreshold = 150, fracturethreshold = 150 },
	flags = 10,
	build = buildShowcase
})

---Replaces the whole mod with a template. One Ctrl+Z puts the old mod back.
function MSV2.applyTemplate(id)
	local t
	for _, tt in ipairs(MSV2.TEMPLATES) do if (tt.id == id) then t = tt end end
	if (not t) then return false end
	local ok = MSV2.withUndo("Template: " .. t.name, function()
		if (not MSV2.resetTo("all")) then error("couldn't reset the mod first") end
		for k, v in pairs(t.rules) do MSV2.setRule(k, v) end
		if (t.flags) then MSV2.setFlags(t.flags) end
		local c = MSV2.dojoCenter()
		MSV2.spawnOverride = { c[1], c[2], 0 }
		t.build(c)
	end)
	MSV2.spawnOverride = nil
	MSV2.selClear()
	MSV2.markDirty()
	MSV2.saveName = t.name
	if (ok) then
		MSV2.toast("Started a new \"" .. t.name .. "\" mod - Restart match (Rules tab) to see the new rules, Ctrl+Z to undo")
	end
	return ok
end

---------------------------------------------------------------------------
-- Object saver: merge boxes that line up into one, and thin out triangles
---------------------------------------------------------------------------

local MERGE_EPS = 0.002
-- Geometry is merged; everything else must match exactly
local MERGE_SKIP = { pos_x = true, pos_y = true, pos_z = true, dims_x = true, dims_y = true, dims_z = true, mass = true }

---Why a box can't take part in merging (nil = it can)
local function mergeBlocker(idx, H, linked)
	local o, m = MSV2.objs[idx], MSV2.meta[idx]
	if (o.type ~= 1) then return "shape" end
	if (m and m.tri) then return "triangle" end
	if (not o.static) then return "physics" end
	if (linked[idx]) then return "link" end
	if (MSV2.isHidden and MSV2.isHidden(idx)) then return "hidden" end
	if ((o.trig_mask or 0) ~= 0 or (o.trig_action or 0) ~= 0 or (o.trig_id or 0) ~= 0) then return "trigger" end
	local key = "o" .. idx
	if (H.parent[key] or H.children[key]) then return "parent" end
	return nil
end

local function mergeSignature(o)
	local parts = {}
	for _, f in ipairs(MSV2.ENV_FIELDS) do
		if (not MERGE_SKIP[f]) then
			local v = o[f]
			if (type(v) == "number") then v = string.format("%.3f", v) end
			table.insert(parts, f .. "=" .. tostring(v))
		end
	end
	return table.concat(parts, ";")
end

---Can boxes a and b (same rotation R) become one box? Returns the merged
---{ pos, dims } or nil.
local function mergePair(R, a, b)
	local d = V.sub(b.pos, a.pos)
	local along
	for k = 1, 3 do
		local c = V.dot(d, M.col(R, k))
		if (abs(c) > MERGE_EPS or abs(a.dims[k] - b.dims[k]) > MERGE_EPS) then
			if (along) then return nil end
			along = k
		end
	end
	if (not along) then along = 1 end -- exact twins: keep one
	local u = M.col(R, along)
	local c = V.dot(d, u)
	-- Must touch or overlap so the union is still a solid box
	if (abs(c) > (a.dims[along] + b.dims[along]) / 2 + MERGE_EPS) then return nil end
	for k = 1, 3 do
		if (k ~= along and (abs(V.dot(d, M.col(R, k))) > MERGE_EPS or abs(a.dims[k] - b.dims[k]) > MERGE_EPS)) then return nil end
	end
	local lo = math.min(-a.dims[along] / 2, c - b.dims[along] / 2)
	local hi = math.max(a.dims[along] / 2, c + b.dims[along] / 2)
	local dims = { a.dims[1], a.dims[2], a.dims[3] }
	dims[along] = hi - lo
	return { pos = V.add(a.pos, V.mul(u, (lo + hi) / 2)), dims = dims }
end

---Works out what the object saver would do, without changing anything.
---triTarget: lower every triangle with more slices than this (nil = leave them)
function MSV2.planObjectSaver(triTarget)
	local H = MSV2.hier()
	local linked = {}
	for _, ej in pairs(MSV2.ejs) do
		if (ej.obj1) then linked[ej.obj1] = true end
		if (ej.obj2) then linked[ej.obj2] = true end
	end
	local buckets, skipped = {}, {}
	for _, idx in ipairs(MSV2.sortedKeys(MSV2.objs)) do
		local why = mergeBlocker(idx, H, linked)
		if (why) then
			skipped[why] = (skipped[why] or 0) + 1
		else
			local o = MSV2.objs[idx]
			local sig = mergeSignature(o)
			buckets[sig] = buckets[sig] or {}
			table.insert(buckets[sig], { idx = idx, pos = MSV2.objPos(idx), dims = { o.dims_x or 0, o.dims_y or 0, o.dims_z or 0 }, absorbed = {} })
		end
	end
	local merges = {}
	local removed = 0
	for _, list in pairs(buckets) do
		if (#list > 1) then
			local R = MSV2.objRot(list[1].idx)
			-- Keep joining pairs until nothing in this bucket lines up any more
			local changed = true
			while (changed) do
				changed = false
				for i = 1, #list do
					local a = list[i]
					if (not a.gone) then
						for j = i + 1, #list do
							local b = list[j]
							if (not b.gone) then
								local m = mergePair(R, a, b)
								if (m) then
									a.pos, a.dims = m.pos, m.dims
									table.insert(a.absorbed, b.idx)
									for _, x in ipairs(b.absorbed) do table.insert(a.absorbed, x) end
									b.gone = true
									changed = true
								end
							end
						end
					end
				end
			end
			for _, a in ipairs(list) do
				if (not a.gone and #a.absorbed > 0) then
					table.insert(merges, { keep = a.idx, pos = a.pos, dims = a.dims, remove = a.absorbed })
					removed = removed + #a.absorbed
				end
			end
		end
	end
	local tris, triSaved = {}, 0
	if (triTarget) then
		for id, t in pairs(MSV2.tris) do
			local n = #t.objs
			if (n > triTarget) then
				table.insert(tris, id)
				triSaved = triSaved + (n - triTarget)
			end
		end
	end
	return { merges = merges, mergeSaved = removed, tris = tris, triTarget = triTarget, triSaved = triSaved,
		total = removed + triSaved, skipped = skipped }
end

---Does what planObjectSaver(triTarget) describes, as one undo step
function MSV2.applyObjectSaver(plan)
	if (not plan or plan.total == 0) then
		MSV2.toast("Nothing to save - every box is already as big as it can be")
		return 0
	end
	local before = MSV2.count(MSV2.objs)
	MSV2.withUndo("Object saver", function()
		for _, m in ipairs(plan.merges) do
			if (MSV2.objs[m.keep]) then
				MSV2.objSet(m.keep, "pos_x", m.pos[1])
				MSV2.objSet(m.keep, "pos_y", m.pos[2])
				MSV2.objSet(m.keep, "pos_z", m.pos[3])
				MSV2.objSet(m.keep, "dims_x", m.dims[1])
				MSV2.objSet(m.keep, "dims_y", m.dims[2])
				MSV2.objSet(m.keep, "dims_z", m.dims[3])
				for _, idx in ipairs(m.remove) do
					if (MSV2.objs[idx]) then MSV2.deleteObjRaw(idx) end
				end
			end
		end
		for _, id in ipairs(plan.tris) do
			local t = MSV2.tris[id]
			if (t and plan.triTarget and (t.slices or 0) > plan.triTarget) then
				t.slices = plan.triTarget
				MSV2.triBuild(id)
			end
		end
		if (MSV2.hierFix) then MSV2.hierFix() end
	end)
	MSV2.selClear()
	local saved = before - MSV2.count(MSV2.objs)
	MSV2.toast("Object saver freed " .. saved .. " object" .. (saved == 1 and "" or "s") .. " (Ctrl+Z undoes)")
	if (MSV2.UI and MSV2.UI.requestRefresh) then MSV2.UI.requestRefresh() end
	return saved
end

---------------------------------------------------------------------------
-- Check before export: things that are probably mistakes
---------------------------------------------------------------------------

local FAR = 60

---Is world point p inside object idx's box (grown by `pad`)?
local function insideObj(idx, p, pad)
	local o = MSV2.objs[idx]
	local rel = V.sub(p, MSV2.objPos(idx))
	local e = MSV2.objExtents(idx)
	if (o.type == 0) then return V.len(rel) <= e[1] / 2 + pad end
	local R = MSV2.objRot(idx)
	for k = 1, 3 do
		if (abs(V.dot(rel, M.col(R, k))) > e[k] / 2 + pad) then return false end
	end
	return true
end

---List of { severity = "warn" | "info", text, objs = { idx... } }, worst first
function MSV2.checkMod()
	local issues = {}
	local function add(sev, text, objs)
		if (#objs > 0) then table.insert(issues, { severity = sev, text = text, objs = objs }) end
	end
	local all = MSV2.sortedKeys(MSV2.objs)

	-- Inside a player at the start
	local bodies = {}
	if (MSV2.bodyWorld) then
		for p = 0, math.max(1, MSV2.numPlayers or 2) - 1 do
			for b = 0, MSV2.NUM_BODIES - 1 do
				local ok, w = pcall(MSV2.bodyWorld, p, b)
				if (ok and w and w.pos) then table.insert(bodies, w.pos) end
			end
		end
	end
	local inPlayer = {}
	for _, idx in ipairs(all) do
		local o = MSV2.objs[idx]
		if (o.visible ~= false or o.static) then
			for _, bp in ipairs(bodies) do
				if (insideObj(idx, bp, 0)) then
					table.insert(inPlayer, idx)
					break
				end
			end
		end
	end
	add("warn", "inside a player at the start - they'll be stuck or thrown around", inPlayer)

	-- Under the floor / far away
	local under, far = {}, {}
	for _, idx in ipairs(all) do
		local p = MSV2.objPos(idx)
		local top = 2 * p[3] - MSV2.objBottom(idx)
		if (top < -0.01) then table.insert(under, idx) end
		if (math.sqrt(p[1] * p[1] + p[2] * p[2]) > FAR or abs(p[3]) > FAR) then table.insert(far, idx) end
	end
	add("warn", "completely under the floor - nobody will ever see or touch them", under)
	add("warn", "more than " .. FAR .. " away from the middle of the arena", far)

	-- Stacked twins
	local seen, twins = {}, {}
	for _, idx in ipairs(all) do
		local o = MSV2.objs[idx]
		local key = string.format("%d|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f", o.type or 1, o.pos_x or 0, o.pos_y or 0, o.pos_z or 0,
			o.rot_x or 0, o.rot_y or 0, o.rot_z or 0, o.dims_x or 0, o.dims_y or 0, o.dims_z or 0)
		if (seen[key]) then table.insert(twins, idx) else seen[key] = idx end
	end
	add("warn", "exact copies sitting on top of another object (the extra copies are selected)", twins)

	-- Tiny and see-through
	local tiny, clear, invisible = {}, {}, {}
	for _, idx in ipairs(all) do
		local o, e = MSV2.objs[idx], MSV2.objExtents(idx)
		if (math.max(e[1], e[2], e[3]) < 0.02) then table.insert(tiny, idx) end
		if (o.visible ~= false and (o.color_a or 1) < 0.02) then table.insert(clear, idx) end
		if (o.visible == false) then table.insert(invisible, idx) end
	end
	add("warn", "so small you can hardly see them", tiny)
	add("info", "fully see-through (colour alpha 0) but still solid", clear)
	add("info", "invisible (still solid - fine for invisible walls)", invisible)

	-- 3D model files and textures (modelsv2.lua)
	if (MSV2.assetIssues) then
		for _, it in ipairs(MSV2.assetIssues(false)) do table.insert(issues, it) end
	end

	-- Object budget
	local limit = MSV2.settings.objLimit or 0
	local n = #all
	if (limit > 0 and n > limit) then
		table.insert(issues, 1, { severity = "warn", text = n .. " objects - over the game's limit of " .. limit .. ". The Object saver can help", objs = {} })
	elseif (limit > 0 and n >= limit * 0.9) then
		table.insert(issues, { severity = "info", text = n .. " of " .. limit .. " objects used - nearly full", objs = {} })
	end
	table.sort(issues, function(a, b)
		if (a.severity ~= b.severity) then return a.severity == "warn" end
		return #a.objs > #b.objs
	end)
	return issues
end

---Selects the objects of one check result and points the camera at them
function MSV2.selectIssue(issue)
	if (not issue or #issue.objs == 0) then return end
	MSV2.selClear()
	for _, idx in ipairs(issue.objs) do
		if (MSV2.objs[idx]) then MSV2.selAdd(idx) end
	end
	if (MSV2.focusSelection) then MSV2.focusSelection() end
	MSV2.toast("Selected " .. #issue.objs .. " object" .. (#issue.objs == 1 and "" or "s"))
end

---Export, but first show any warnings from the check
function MSV2.exportChecked(name)
	if (MSV2.assetReport) then pcall(MSV2.assetReport, true) end
	local warns = 0
	for _, it in ipairs(MSV2.checkMod()) do
		if (it.severity == "warn") then warns = warns + 1 end
	end
	if (warns == 0 or not (MSV2.UI and MSV2.UI.confirm)) then
		return MSV2.exportMod(name)
	end
	MSV2.UI.confirm("Export with " .. warns .. " warning" .. (warns == 1 and "" or "s") .. "?",
		"The mod check found things that are probably mistakes. Have a look, or export anyway.", {
			{ "Show me", function() MSV2.UI.selectTab("stats") end },
			{ "Export anyway", function() MSV2.exportMod(name) end },
			{ "Cancel" }
		})
end
