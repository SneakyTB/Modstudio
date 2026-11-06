-- Mod Studio: 3D viewport
-- Move / rotate / scale gizmo, click + box selection, triangle corner handles,
-- overlays (grid, outlines, links, labels) and keyboard shortcuts.

local MSV2 = MSV2
local V, M = MSV2.V, MSV2.M
local clock = MSV2.clock
local abs, sqrt, floor, atan2 = math.abs, math.sqrt, math.floor, math.atan2

MSV2.G = MSV2.G or {}
local G = MSV2.G

local AXIS_COLORS = {
	{ 0.95, 0.27, 0.27 },
	{ 0.40, 0.85, 0.30 },
	{ 0.30, 0.55, 1.00 }
}
local HOVER_COLOR = { 1, 0.85, 0.2 }
local SELECT_COLOR = { 0.35, 0.9, 1 }
local PRIMARY_COLOR = { 1, 0.85, 0.3 }
local HOVER_OUTLINE = { 1, 1, 1 }

-- Colours you can pick for the selection / hover highlights (Settings > 3D view)
MSV2.VIEW_COLORS = {
	{ "cyan", "Cyan", { 0.35, 0.9, 1 } },
	{ "gold", "Gold", { 1, 0.85, 0.3 } },
	{ "yellow", "Yellow", { 1, 0.85, 0.2 } },
	{ "white", "White", { 1, 1, 1 } },
	{ "pink", "Pink", { 1, 0.5, 0.8 } },
	{ "green", "Green", { 0.45, 1, 0.45 } },
	{ "orange", "Orange", { 1, 0.55, 0.15 } },
	{ "purple", "Purple", { 0.75, 0.55, 1 } }
}

local function viewColor(name, fallback)
	for _, c in ipairs(MSV2.VIEW_COLORS) do
		if (c[1] == name) then return c[3] end
	end
	return fallback
end

---Copies the chosen highlight colours into the tables the drawing code uses
function MSV2.applyViewColors()
	local st = MSV2.settings or {}
	for _, pair in ipairs({
		{ SELECT_COLOR, viewColor(st.selColor, { 0.35, 0.9, 1 }) },
		{ PRIMARY_COLOR, viewColor(st.primaryColor, { 1, 0.85, 0.3 }) },
		{ HOVER_COLOR, viewColor(st.hoverColor, { 1, 0.85, 0.2 }) },
		{ HOVER_OUTLINE, viewColor(st.hoverOutline, { 1, 1, 1 }) }
	}) do
		pair[1][1], pair[1][2], pair[1][3] = pair[2][1], pair[2][2], pair[2][3]
	end
end

local function outlineW() return MSV2.clamp(tonumber(MSV2.settings.outlineWidth) or 1.5, 0.5, 5) end
local function gizmoW() return MSV2.clamp(tonumber(MSV2.settings.gizmoWidth) or 1, 0.5, 3) end
local HIER_COLOR = { 0.80, 0.55, 1 }
local AXIS_NAMES = { "X", "Y", "Z" }

local function ctrlDown() local ok, v = pcall(get_keyboard_ctrl); return ok and (v == 1 or v == true) end
local function shiftDown() local ok, v = pcall(get_keyboard_shift); return ok and (v == 1 or v == true) end
local function altDown() local ok, v = pcall(get_keyboard_alt); return ok and (v == 1 or v == true) end
MSV2.ctrlDown, MSV2.shiftDown, MSV2.altDown = ctrlDown, shiftDown, altDown

---Snapping is on when the setting is on, Ctrl held flips it for the current drag
function MSV2.snapActive()
	local s = MSV2.settings.snap
	if (ctrlDown()) then s = not s end
	return s
end

---------------------------------------------------------------------------
-- Ray helpers (ray_world_point works from mouse callbacks)
---------------------------------------------------------------------------

function MSV2.mouseRay(x, y)
	local ok1, ax, ay, az = pcall(ray_world_point, x, y, 1)
	local ok2, bx, by, bz = pcall(ray_world_point, x, y, 6)
	if (not ok1 or not ok2 or ax == nil or bx == nil) then
		return nil
	end
	local a, b = { ax, ay, az }, { bx, by, bz }
	local d = V.norm(V.sub(b, a))
	if (V.len(d) < 0.5) then return nil end
	return V.sub(a, d), d
end

local function rayPlane(ro, rd, p, n)
	local denom = V.dot(n, rd)
	if (abs(denom) < 1e-5) then return nil end
	local t = V.dot(n, V.sub(p, ro)) / denom
	if (t < 0) then return nil end
	return V.add(ro, V.mul(rd, t))
end

---Parameter t of the point on line (p0 + t*u) closest to the ray
local function lineRayParam(p0, u, ro, rd)
	local w0 = V.sub(p0, ro)
	local b = V.dot(u, rd)
	local d = V.dot(u, w0)
	local e = V.dot(rd, w0)
	local denom = 1 - b * b
	if (denom < 1e-4) then return nil end
	return (b * e - d) / denom
end

local function camVectors()
	local ok, cam = pcall(get_camera_info)
	if (not ok or not cam or not cam.pos) then
		return { 0, -5, 2 }, { 0, 0, 1 }, { 0, 1, 0 }, { 1, 0, 0 }, { 0, 0, 1 }
	end
	local pos = { cam.pos.x, cam.pos.y, cam.pos.z }
	local look = { cam.lookat.x, cam.lookat.y, cam.lookat.z }
	local fwd = V.norm(V.sub(look, pos))
	local right = V.cross(fwd, { 0, 0, 1 })
	if (V.len(right) < 1e-3) then right = { 1, 0, 0 } end
	right = V.norm(right)
	local up = V.norm(V.cross(right, fwd))
	return pos, look, fwd, right, up
end
MSV2.camVectors = camVectors

---------------------------------------------------------------------------
-- What the gizmo operates on
---------------------------------------------------------------------------

local function shapeMatrix(o)
	return M.fromEuler(o.rot_x, o.rot_y, o.rot_z)
end

---------------------------------------------------------------------------
-- Players as the game actually shows them. Mod coordinates (get_mod_body) can
-- differ from where the body is drawn (engage distance / height / rotation),
-- so picking, outlines and the gizmo use the live world data instead.
---------------------------------------------------------------------------

local function tabOpen(id)
	return MSV2.UI and MSV2.UI.isTabOpen and MSV2.UI.isTabOpen(id)
end
MSV2.tabOpen = tabOpen

---Bodies tab is open on its Place sub-tab (whole-player gizmo + dojo handle)
local function placingPlayers()
	return tabOpen("players") and MSV2.UI.sub ~= nil and MSV2.UI.sub.players == "place"
end

local function rotFromTB(r)
	if (type(r) ~= "table") then return nil end
	local function g(n) return r["r" .. n] or r[n + 1] end
	if (type(g(0)) ~= "number") then return nil end
	return { { g(0), g(1), g(2) }, { g(4), g(5), g(6) }, { g(8), g(9), g(10) } }
end

---World pos / rotation / sides / shape of a body part, or nil
function MSV2.bodyWorld(p, b)
	local ok, info = pcall(get_body_info, p, b)
	if (not ok or type(info) ~= "table" or not info.pos or not info.sides) then return nil end
	return {
		pos = { info.pos.x, info.pos.y, info.pos.z },
		R = rotFromTB(info.rot) or M.identity(),
		sides = { info.sides.x or 0, info.sides.y or 0, info.sides.z or 0 },
		shape = info.shape or 1
	}
end

---World pos + radius of a joint, or nil
function MSV2.jointWorld(p, j)
	local pos
	local ok, v = pcall(get_joint_pos2, p, j)
	if (ok and type(v) == "table" and v.x) then
		pos = { v.x, v.y, v.z }
	else
		local ok2, x, y, z = pcall(get_joint_pos, p, j)
		if (ok2 and type(x) == "number") then pos = { x, y, z } end
	end
	if (not pos) then return nil end
	local okr, r = pcall(get_joint_radius, p, j)
	local cached = MSV2.joints[p] and MSV2.joints[p][j]
	return { pos = pos, radius = (okr and type(r) == "number") and r or (cached and cached.radius) or 0.1 }
end

---Rotation that turns a player's mod coordinates into world coordinates
---(players can be turned around by engage rotation). Measured from the pecs.
function MSV2.playerFrame(p)
	local bm = MSV2.bodies[p]
	local wr, wl = MSV2.bodyWorld(p, 5), MSV2.bodyWorld(p, 8)
	if (not bm or not bm[5] or not bm[8] or not wr or not wl) then return M.identity() end
	local vm = { bm[8].pos_x - bm[5].pos_x, bm[8].pos_y - bm[5].pos_y }
	local vw = { wl.pos[1] - wr.pos[1], wl.pos[2] - wr.pos[2] }
	if (vm[1] * vm[1] + vm[2] * vm[2] < 1e-6 or vw[1] * vw[1] + vw[2] * vw[2] < 1e-6) then return M.identity() end
	local yaw = math.deg(atan2(vw[2], vw[1]) - atan2(vm[2], vm[1]))
	yaw = MSV2.round(yaw, 0.01)
	if (abs(yaw) < 0.05) then return M.identity() end
	return M.axisAngle({ 0, 0, 1 }, yaw)
end

-- Ray intersections. Return the distance along the ray or nil.

local function rayOBB(ro, rd, pos, R, half)
	local Rt = M.transpose(R)
	local o = M.apply(Rt, V.sub(ro, pos))
	local d = M.apply(Rt, rd)
	local tmin, tmax = -math.huge, math.huge
	for k = 1, 3 do
		if (abs(d[k]) < 1e-9) then
			if (abs(o[k]) > half[k]) then return nil end
		else
			local t1, t2 = (-half[k] - o[k]) / d[k], (half[k] - o[k]) / d[k]
			if (t1 > t2) then t1, t2 = t2, t1 end
			if (t1 > tmin) then tmin = t1 end
			if (t2 < tmax) then tmax = t2 end
			if (tmin > tmax) then return nil end
		end
	end
	if (tmax < 0) then return nil end
	return tmin >= 0 and tmin or 0
end

local function raySphere(ro, rd, c, r)
	local oc = V.sub(ro, c)
	local b = V.dot(oc, rd)
	local cc = V.dot(oc, oc) - r * r
	local disc = b * b - cc
	if (disc < 0) then return nil end
	local s = math.sqrt(disc)
	local t = -b - s
	if (t < 0) then t = -b + s end
	if (t < 0) then return nil end
	return t
end

---Capsule along local Z: `len` between the end-cap centers
local function rayCapsule(ro, rd, pos, R, r, len)
	local a = M.col(R, 3)
	local p0 = V.sub(pos, V.mul(a, len / 2))
	-- Closest approach between the ray and the capsule's core segment
	local w0 = V.sub(ro, p0)
	local b = V.dot(rd, a)
	local d, e = V.dot(rd, w0), V.dot(a, w0)
	local denom = 1 - b * b
	local s, t
	if (denom < 1e-6) then
		s, t = 0, e
	else
		s = (b * e - d) / denom
		t = (e - b * d) / denom
	end
	t = MSV2.clamp(t, 0, len)
	s = math.max(0, V.dot(rd, V.sub(V.add(p0, V.mul(a, t)), ro)))
	local q = V.add(p0, V.mul(a, t))
	local hit = raySphere(ro, rd, q, r)
	if (hit) then return hit end
	local dist = V.dist(V.add(ro, V.mul(rd, s)), q)
	if (dist <= r) then return s end
	return nil
end

---Distance along the ray to a body part, or nil
local function rayBody(ro, rd, w)
	local s = w.sides
	if (w.shape == 0) then
		return raySphere(ro, rd, w.pos, math.max(0.01, s[1]))
	elseif (w.shape == 2) then
		return rayCapsule(ro, rd, w.pos, w.R, math.max(0.01, s[1]), math.max(0, s[2]))
	end
	return rayOBB(ro, rd, w.pos, w.R, { s[1] / 2, s[2] / 2, s[3] / 2 })
end

---Nearest body part under the cursor: player, body, distance
function MSV2.pickBody(x, y)
	local ro, rd = MSV2.mouseRay(x, y)
	if (not ro) then return nil end
	local best, bp, bb = math.huge, nil, nil
	for p = 0, math.max(1, MSV2.numPlayers) - 1 do
		for b = 0, MSV2.NUM_BODIES - 1 do
			local w = MSV2.bodyWorld(p, b)
			local t = w and rayBody(ro, rd, w)
			if (t and t < best) then best, bp, bb = t, p, b end
		end
	end
	if (bp == nil) then return nil end
	return bp, bb, best
end

---Nearest joint under the cursor (slightly generous radius): player, joint, distance
function MSV2.pickJoint(x, y)
	local ro, rd = MSV2.mouseRay(x, y)
	if (not ro) then return nil end
	local best, bp, bj = math.huge, nil, nil
	for p = 0, math.max(1, MSV2.numPlayers) - 1 do
		for j = 0, MSV2.NUM_JOINTS - 1 do
			local w = MSV2.jointWorld(p, j)
			local t = w and raySphere(ro, rd, w.pos, math.max(0.08, w.radius * 1.4))
			if (t and t < best) then best, bp, bj = t, p, j end
		end
	end
	if (bp == nil) then return nil end
	return bp, bj, best
end

---Returns the current gizmo context or nil
function MSV2.gizmoContext()
	local localSpace = MSV2.settings.space == "local"
	if (placingPlayers() and MSV2.bodySel and MSV2.bodies[MSV2.bodySel.p]) then
		-- Whole player: move / turn where they stand
		local p = MSV2.bodySel.p
		local c = MSV2.playerWorldCenter(p)
		if (c) then
			return { kind = "player", p = p, pivot = c, A = M.identity(), W = MSV2.playerFrame(p), rot = true, scale = false }
		end
	end
	if (tabOpen("players") and MSV2.settings.bodyGizmo and MSV2.bodySel) then
		local o = MSV2.bodies[MSV2.bodySel.p] and MSV2.bodies[MSV2.bodySel.p][MSV2.bodySel.b]
		if (o) then
			local w = MSV2.bodyWorld(MSV2.bodySel.p, MSV2.bodySel.b)
			local W = MSV2.playerFrame(MSV2.bodySel.p)
			return { kind = "body", p = MSV2.bodySel.p, b = MSV2.bodySel.b,
				pivot = w and w.pos or { o.pos_x, o.pos_y, o.pos_z },
				A = localSpace and (w and w.R or shapeMatrix(o)) or M.identity(), W = W, rot = true, scale = true }
		end
	elseif (tabOpen("joints") and MSV2.settings.bodyGizmo and MSV2.jointSel) then
		local o = MSV2.joints[MSV2.jointSel.p] and MSV2.joints[MSV2.jointSel.p][MSV2.jointSel.j]
		if (o) then
			local w = MSV2.jointWorld(MSV2.jointSel.p, MSV2.jointSel.j)
			return { kind = "joint", p = MSV2.jointSel.p, j = MSV2.jointSel.j,
				pivot = w and w.pos or { o.pos_x, o.pos_y, o.pos_z },
				A = M.identity(), W = MSV2.playerFrame(MSV2.jointSel.p), rot = false, scale = false }
		end
	end
	if (MSV2.vertexSel and MSV2.tris[MSV2.vertexSel.tri]) then
		local t = MSV2.tris[MSV2.vertexSel.tri]
		return { kind = "vertex", tri = MSV2.vertexSel.tri, key = MSV2.vertexSel.key, pivot = V.copy(t[MSV2.vertexSel.key]),
			A = M.identity(), rot = false, scale = false }
	end
	local center = MSV2.selCenter()
	if (not center) then return nil end
	local A = M.identity()
	if (localSpace) then
		local triId = MSV2.selSingleTri()
		if (triId) then
			local s = MSV2.triSlices(MSV2.tris[triId])[1]
			if (s) then A = s.R end
		elseif (MSV2.primary and MSV2.objs[MSV2.primary]) then
			A = MSV2.objRot(MSV2.primary)
		end
	end
	return { kind = "env", pivot = center, A = A, rot = true, scale = true }
end

---Snapshot of the things a drag will change
local function captureItems(ctx)
	local items = {}
	if (ctx.kind == "player") then
		local p = ctx.p
		local it = { p = p, bodies = {}, joints = {}, center = MSV2.playerModCenter(p) or { 0, 0, 0 } }
		for b = 0, MSV2.NUM_BODIES - 1 do
			local o = MSV2.bodies[p][b]
			if (o) then it.bodies[b] = { pos = { o.pos_x, o.pos_y, o.pos_z }, R = shapeMatrix(o) } end
		end
		for j = 0, MSV2.NUM_JOINTS - 1 do
			local o = MSV2.joints[p] and MSV2.joints[p][j]
			if (o) then it.joints[j] = { pos = { o.pos_x, o.pos_y, o.pos_z }, axis = { o.axis_x or 0, o.axis_y or 0, o.axis_z or 0 } } end
		end
		items.player = it
	elseif (ctx.kind == "body") then
		local o = MSV2.bodies[ctx.p][ctx.b]
		items.body = { p = ctx.p, b = ctx.b, pos = { o.pos_x, o.pos_y, o.pos_z }, R = shapeMatrix(o),
			type = o.type, dims = { o.sides_x or 0, o.sides_y or 0, o.sides_z or 0 } }
	elseif (ctx.kind == "joint") then
		local o = MSV2.joints[ctx.p][ctx.j]
		items.joint = { p = ctx.p, j = ctx.j, pos = { o.pos_x, o.pos_y, o.pos_z } }
	elseif (ctx.kind == "vertex") then
		items.vertex = { tri = ctx.tri, key = ctx.key, pos = V.copy(MSV2.tris[ctx.tri][ctx.key]) }
	else
		-- Children ride along with their parents
		local tris, plain = MSV2.selSplitFamily()
		items.objs = {}
		for _, idx in ipairs(plain) do
			local o = MSV2.objs[idx]
			table.insert(items.objs, { idx = idx, pos = MSV2.objPos(idx), R = MSV2.objRot(idx), type = o.type,
				dims = { o.dims_x or 0, o.dims_y or 0, o.dims_z or 0 } })
		end
		items.tris = {}
		for id in pairs(tris) do
			local t = MSV2.tris[id]
			table.insert(items.tris, { id = id, a = V.copy(t.a), b = V.copy(t.b), c = V.copy(t.c), thick = t.thick })
		end
	end
	return items
end

---Scales full box dims by local factors. Spheres keep one radius, cylinders radius+length.
local function scaleDims(shape, dims, fl, snap)
	local d
	if (shape == 0) then
		local f = math.max(fl[1], fl[2], fl[3])
		if (f == 1) then f = math.min(fl[1], fl[2], fl[3]) end
		d = { dims[1] * f, dims[2] * f, dims[3] * f }
	elseif (shape == 2) then
		local fr = fl[1] ~= 1 and fl[1] or fl[2]
		d = { dims[1] * fr, dims[2] * fl[3], dims[3] * fr }
	else
		d = { dims[1] * fl[1], dims[2] * fl[2], dims[3] * fl[3] }
	end
	for k = 1, 3 do
		if (snap and MSV2.settings.scaleStep > 0) then
			d[k] = math.max(MSV2.settings.scaleStep, MSV2.round(d[k], MSV2.settings.scaleStep))
		end
		d[k] = math.max(0.01, d[k])
	end
	return d
end

---Maps a world-space axis scale to the object's local axes
local function localFactors(R, axisWorld, f)
	if (not axisWorld) then return { f, f, f } end
	local best, bestDot = 1, -1
	for j = 1, 3 do
		local dd = abs(V.dot(M.col(R, j), axisWorld))
		if (dd > bestDot) then best, bestDot = j, dd end
	end
	local fl = { 1, 1, 1 }
	fl[best] = f
	return fl
end

---Applies a transform relative to the drag start state.
---op = { move = vec } | { rot = matrix } | { scaleAxis = vec|nil, scale = f }
local function applyOp(drag, op)
	local items, pivot = drag.items, drag.pivot0
	local snap = drag.snap
	local function tpos(p)
		if (op.move) then return V.add(p, op.move) end
		if (op.rot) then return V.add(pivot, M.apply(op.rot, V.sub(p, pivot))) end
		local d = V.sub(p, pivot)
		if (op.scaleAxis) then
			d = V.add(d, V.mul(op.scaleAxis, V.dot(d, op.scaleAxis) * (op.scale - 1)))
		else
			d = V.mul(d, op.scale)
		end
		return V.add(pivot, d)
	end

	-- Body/joint gizmos work in world space; convert into the player's mod coordinates
	local W = drag.ctx and drag.ctx.W
	if ((items.body or items.joint or items.player) and W) then
		local Wt = M.transpose(W)
		local o2 = {}
		for k, v in pairs(op) do o2[k] = v end
		if (op.move) then o2.move = M.apply(Wt, op.move) end
		if (op.rot) then o2.rot = M.mul(M.mul(Wt, op.rot), W) end
		if (op.scaleAxis) then o2.scaleAxis = M.apply(Wt, op.scaleAxis) end
		op = o2
	end

	if (items.player) then
		-- Every part and joint moves / turns together around the player's center
		local it = items.player
		local p = it.p
		local Q = op.rot or M.identity()
		local mv = op.move or { 0, 0, 0 }
		local function tp(pos) return V.add(V.add(it.center, M.apply(Q, V.sub(pos, it.center))), mv) end
		for b, s in pairs(it.bodies) do
			local np = tp(s.pos)
			MSV2.bodySet(p, b, "pos_x", np[1])
			MSV2.bodySet(p, b, "pos_y", np[2])
			MSV2.bodySet(p, b, "pos_z", np[3])
			local x, y, z = M.toEuler(M.mul(Q, s.R))
			MSV2.bodySet(p, b, "rot_x", x)
			MSV2.bodySet(p, b, "rot_y", y)
			MSV2.bodySet(p, b, "rot_z", z)
		end
		for j, s in pairs(it.joints) do
			local np = tp(s.pos)
			MSV2.jointSet(p, j, "pos_x", np[1])
			MSV2.jointSet(p, j, "pos_y", np[2])
			MSV2.jointSet(p, j, "pos_z", np[3])
			local ax = M.apply(Q, s.axis)
			MSV2.jointSet(p, j, "axis_x", ax[1])
			MSV2.jointSet(p, j, "axis_y", ax[2])
			MSV2.jointSet(p, j, "axis_z", ax[3])
		end
		return
	end
	if (items.body) then
		local it = items.body
		local p, b = it.p, it.b
		local np = op.move and V.add(it.pos, op.move) or it.pos
		MSV2.bodySet(p, b, "pos_x", np[1])
		MSV2.bodySet(p, b, "pos_y", np[2])
		MSV2.bodySet(p, b, "pos_z", np[3])
		local R = it.R
		if (op.rot) then R = M.mul(op.rot, it.R) end
		local x, y, z = M.toEuler(R)
		MSV2.bodySet(p, b, "rot_x", x)
		MSV2.bodySet(p, b, "rot_y", y)
		MSV2.bodySet(p, b, "rot_z", z)
		local d = it.dims
		if (op.scale) then d = scaleDims(it.type, it.dims, localFactors(it.R, op.scaleAxis, op.scale), snap) end
		MSV2.bodySet(p, b, "sides_x", d[1])
		MSV2.bodySet(p, b, "sides_y", d[2])
		MSV2.bodySet(p, b, "sides_z", d[3])
		if (MSV2.settings.symmetry) then MSV2.mirrorBody(p, b, true) end
		return
	end
	if (items.joint) then
		local it = items.joint
		local np = op.move and V.add(it.pos, op.move) or it.pos
		MSV2.jointSet(it.p, it.j, "pos_x", np[1])
		MSV2.jointSet(it.p, it.j, "pos_y", np[2])
		MSV2.jointSet(it.p, it.j, "pos_z", np[3])
		if (MSV2.settings.symmetry) then MSV2.mirrorJoint(it.p, it.j, true) end
		return
	end
	if (items.vertex) then
		local it = items.vertex
		local t = MSV2.tris[it.tri]
		if (t) then
			t[it.key] = op.move and V.add(it.pos, op.move) or V.copy(it.pos)
			MSV2.triBuild(it.tri)
		end
		return
	end
	for _, it in ipairs(items.objs or {}) do
		if (MSV2.objs[it.idx]) then
			MSV2.setObjPos(it.idx, tpos(it.pos))
			if (op.rot) then
				MSV2.setObjRot(it.idx, M.mul(op.rot, it.R))
			elseif (op.move) then
				-- nothing else changes
			else
				MSV2.setObjRot(it.idx, it.R)
				local d = it.dims
				if (op.scale) then d = scaleDims(it.type, it.dims, localFactors(it.R, op.scaleAxis, op.scale), snap) end
				MSV2.objSet(it.idx, "dims_x", d[1])
				MSV2.objSet(it.idx, "dims_y", d[2])
				MSV2.objSet(it.idx, "dims_z", d[3])
			end
		end
	end
	for _, it in ipairs(items.tris or {}) do
		local t = MSV2.tris[it.id]
		if (t) then
			t.a, t.b, t.c = tpos(it.a), tpos(it.b), tpos(it.c)
			if (op.scale and not op.scaleAxis) then
				t.thick = math.max(0.01, it.thick * op.scale)
			end
			MSV2.triBuild(it.id)
		end
	end
end

---------------------------------------------------------------------------
-- Dragging
---------------------------------------------------------------------------

local function snapMoveDelta(drag, d, axes)
	if (not drag.snap or MSV2.settings.gridStep <= 0) then return d end
	local step = MSV2.settings.gridStep
	local worldFrame = drag.worldFrame
	if (worldFrame) then
		-- Absolute snapping: the pivot lands on grid lines
		local target = V.add(drag.pivot0, d)
		for k = 1, 3 do
			if (axes[k]) then target[k] = MSV2.round(target[k], step) end
		end
		return V.sub(target, drag.pivot0)
	end
	local A = drag.A
	local comps = M.apply(M.transpose(A), d)
	for k = 1, 3 do
		if (axes[k]) then comps[k] = MSV2.round(comps[k], step) end
	end
	return M.apply(A, comps)
end

local function isIdentity(A)
	return abs(A[1][1] - 1) < 1e-6 and abs(A[2][2] - 1) < 1e-6 and abs(A[3][3] - 1) < 1e-6
end

---Starts a drag. handle = { type = axis|plane|free|ring|saxis|suni|direct, k = axis }
function MSV2.beginDrag(handle, x, y, ctx)
	ctx = ctx or MSV2.gizmoContext()
	if (not ctx) then return false end
	-- Alt + gizmo handle: drag out a copy and leave the original where it was
	local dup = false
	if (ctx.kind == "env" and handle.type ~= "direct" and altDown() and MSV2.settings.altDuplicate ~= false) then
		local clip = MSV2.copySelection()
		if (clip) then
			MSV2.pushUndo("Duplicate drag")
			local list = MSV2.pasteClip(clip, { 0, 0, 0 })
			if (#list > 0) then
				dup = true
				ctx = MSV2.gizmoContext() or ctx
				MSV2.toast("Dragging a copy of " .. #list .. " object" .. (#list == 1 and "" or "s") .. " (Esc / right-click cancels)")
			else
				table.remove(MSV2.undoStack)
			end
		end
	end
	local ro, rd = MSV2.mouseRay(x, y)
	local drag = {
		handle = handle, ctx = ctx, x0 = x, y0 = y,
		pivot0 = V.copy(ctx.pivot), A = ctx.A, worldFrame = isIdentity(ctx.A),
		items = captureItems(ctx), started = handle.type ~= "direct", angle = 0
	}
	-- Kept for cancelling: rebaseDrag() replaces items/pivot0 when the camera moves
	drag.origItems, drag.origPivot = drag.items, drag.pivot0
	local A = ctx.A
	local _, _, fwd = camVectors()
	if (handle.type == "axis" or handle.type == "saxis") then
		drag.axis = M.col(A, handle.k)
		drag.t0 = ro and lineRayParam(drag.pivot0, drag.axis, ro, rd)
	elseif (handle.type == "plane") then
		drag.normal = M.col(A, handle.k)
	elseif (handle.type == "free") then
		drag.normal = V.mul(fwd, -1)
	elseif (handle.type == "direct") then
		if (handle.vertical) then
			local h = { fwd[1], fwd[2], 0 }
			drag.normal = V.len(h) > 1e-3 and V.norm(h) or { 0, 1, 0 }
		elseif (handle.cameraPlane) then
			drag.normal = V.mul(fwd, -1)
		else
			drag.normal = { 0, 0, 1 }
		end
	elseif (handle.type == "ring") then
		drag.normal = M.col(A, handle.k)
	end
	if (drag.normal and ro) then
		drag.hit0 = rayPlane(ro, rd, drag.pivot0, drag.normal)
		if (drag.hit0) then drag.lastVec = V.sub(drag.hit0, drag.pivot0) end
	end
	if (handle.type == "suni") then
		local c = MSV2.frame and MSV2.frame.giz and MSV2.frame.giz.center
		drag.screenPivot = c
	end
	G.drag = drag
	G.mouseX, G.mouseY = x, y
	local camPos, look = camVectors()
	G.dragCam = { V.copy(camPos), V.copy(look) }
	pcall(disable_mouse_camera_movement)
	drag.dup = dup
	if (drag.started and not dup) then
		MSV2.pushUndo(({ axis = "Move", plane = "Move", free = "Move", ring = "Rotate", saxis = "Scale", suni = "Scale" })[handle.type] or "Edit")
	end
	return true
end

function MSV2.updateDrag(x, y)
	local drag = G.drag
	if (not drag) then return end
	if (not drag.started) then
		if (abs(x - drag.x0) + abs(y - drag.y0) < 5) then return end
		drag.started = true
		MSV2.pushUndo("Move")
	end
	if (drag.needRebase) then
		-- Camera moved since the last mouse update: anchor at the previous cursor
		-- position with today's camera, then apply only the real mouse movement
		MSV2.rebaseAt(drag, G.prevMouseX or x, G.prevMouseY or y)
	end
	drag.snap = MSV2.snapActive()
	local ro, rd = MSV2.mouseRay(x, y)
	if (not ro) then return end
	local h = drag.handle
	local op, readout
	local snapD, snapInfo
	if (h.type == "direct" and not h.vertical and not h.cameraPlane and not drag.pushed and drag.ctx and drag.ctx.kind == "env" and MSV2.surfaceSnapActive()) then
		snapD, snapInfo = MSV2.surfaceSnapDelta(drag, ro, rd)
	end


	if (h.type == "axis") then
		local t = lineRayParam(drag.pivot0, drag.axis, ro, rd)
		if (t and drag.t0) then
			local axes = { false, false, false }
			axes[h.k] = true
			local d = snapMoveDelta(drag, V.mul(drag.axis, t - drag.t0), axes)
			op = { move = d }
			readout = AXIS_NAMES[h.k] .. " " .. (V.dot(d, drag.axis) >= 0 and "+" or "") .. MSV2.fmt(V.dot(d, drag.axis))
		end
	elseif (snapD) then
		-- Rest the selection on whatever surface is under the cursor
		op = { move = snapD }
		readout = snapInfo
	elseif (h.type == "plane" or h.type == "free" or h.type == "direct") then
		-- Rays that only skim the plane hit it miles away - ignore them instead of flinging the object
		local grazing = abs(V.dot(rd, drag.normal)) < 0.06
		local hit = (not grazing) and drag.hit0 and rayPlane(ro, rd, drag.pivot0, drag.normal)
		if (hit and V.dist(hit, ro) > 250) then hit = nil end
		if (hit) then
			local d = V.sub(hit, drag.hit0)
			local axes = { true, true, true }
			if (h.type == "plane") then
				axes[h.k] = false
				d = V.sub(d, V.mul(drag.normal, V.dot(d, drag.normal)))
			elseif (h.type == "direct" and not h.vertical and not h.cameraPlane and not drag.pushed) then
				axes[3] = false
				d[3] = 0
			end
			d = snapMoveDelta(drag, d, axes)
			op = { move = d }
			readout = "Move " .. MSV2.fmt(d[1]) .. ", " .. MSV2.fmt(d[2]) .. ", " .. MSV2.fmt(d[3])
		end
	elseif (h.type == "ring") then
		local hit = rayPlane(ro, rd, drag.pivot0, drag.normal)
		local useScreen = abs(V.dot(rd, drag.normal)) < 0.12 or not hit or not drag.lastVec
		if (useScreen) then
			drag.angle = ((x - drag.x0) - (y - drag.y0)) * 0.6
		else
			local v1 = V.sub(hit, drag.pivot0)
			local a = drag.lastVec
			local s = V.dot(V.cross(a, v1), drag.normal)
			local c = V.dot(a, v1)
			drag.angle = drag.angle + math.deg(atan2(s, c))
			drag.lastVec = v1
		end
		local ang = drag.angle
		if (drag.snap and MSV2.settings.rotStep > 0) then
			ang = MSV2.round(ang, MSV2.settings.rotStep)
		end
		op = { rot = M.axisAngle(drag.normal, ang) }
		readout = AXIS_NAMES[h.k] .. " " .. MSV2.fmt(ang) .. " deg"
	elseif (h.type == "saxis") then
		local t = lineRayParam(drag.pivot0, drag.axis, ro, rd)
		if (t and drag.t0 and abs(drag.t0) > 1e-3) then
			local f = math.max(0.02, t / drag.t0)
			op = { scaleAxis = drag.axis, scale = f }
			readout = AXIS_NAMES[h.k] .. " x" .. string.format("%.2f", f)
		end
	elseif (h.type == "suni") then
		local f
		local sp = drag.screenPivot
		local d0 = sp and sqrt((drag.x0 - sp[1]) ^ 2 + (drag.y0 - sp[2]) ^ 2) or 0
		if (sp and d0 > 25) then
			f = sqrt((x - sp[1]) ^ 2 + (y - sp[2]) ^ 2) / d0
		else
			f = math.exp(((x - drag.x0) - (y - drag.y0)) / 140)
		end
		f = math.max(0.02, f)
		op = { scale = f }
		readout = "Scale x" .. string.format("%.2f", f)
	end

	if (op) then
		applyOp(drag, op)
		drag.readout = readout
		drag.mx, drag.my = x, y
	end
end

function MSV2.endDrag()
	local drag = G.drag
	if (not drag) then return end
	G.drag = nil
	pcall(enable_mouse_camera_movement)
	if (drag.started) then
		MSV2.UI.requestRefresh()
	end
end

---Ends a drag without touching anything (used by undo/restore)
function MSV2.endDragSilently()
	if (G.drag) then
		G.drag = nil
		pcall(enable_mouse_camera_movement)
	end
	G.marquee = nil
end

function MSV2.cancelDrag()
	local drag = G.drag
	if (not drag) then return end
	if (drag.dup) then
		-- Throw the copies away again
		MSV2.endDragSilently()
		local e = table.remove(MSV2.undoStack)
		if (e) then MSV2.restore(e.snap) end
		MSV2.toast("Cancelled - copy removed")
		MSV2.UI.requestRefresh()
		return
	end
	if (drag.started) then
		drag.items, drag.pivot0 = drag.origItems, drag.origPivot
		applyOp(drag, { move = { 0, 0, 0 } })
		if (drag.handle.type ~= "axis" and drag.handle.type ~= "plane" and drag.handle.type ~= "free" and drag.handle.type ~= "direct") then
			applyOp(drag, { scale = 1 })
		end
		-- The undo entry pushed at drag start is now a no-op; drop it
		table.remove(MSV2.undoStack)
	end
	MSV2.endDragSilently()
	MSV2.toast("Cancelled")
	MSV2.UI.requestRefresh()
end

---------------------------------------------------------------------------
-- Per-frame projection cache (get_screen_pos only works in draw3d)
---------------------------------------------------------------------------

local function P(v)
	local x, y, z = get_screen_pos(v[1], v[2], v[3])
	return { x, y, ok = (z == 0) }
end

local function boxCorners(pos, R, e)
	local out = {}
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				table.insert(out, V.add(pos, M.apply(R, { sx * e[1] / 2, sy * e[2] / 2, sz * e[3] / 2 })))
			end
		end
	end
	return out
end
local BOX_EDGES = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 }, { 1, 3 }, { 2, 4 }, { 5, 7 }, { 6, 8 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }

---Builds a 2D outline (list of segments, or a circle) for a shape
local function outline(shape, pos, R, dims, right)
	if (shape == 0) then
		local c = P(pos)
		local e = P(V.add(pos, V.mul(right, dims[1])))
		if (c.ok and e.ok) then
			return { circle = { c[1], c[2], sqrt((e[1] - c[1]) ^ 2 + (e[2] - c[2]) ^ 2) } }
		end
		return nil
	end
	local ext = MSV2.shapeExtents(shape, dims[1], dims[2], dims[3])
	local corners = boxCorners(pos, R, ext)
	local pc = {}
	for i, c in ipairs(corners) do pc[i] = P(c) end
	local segs = {}
	for _, e in ipairs(BOX_EDGES) do
		local a, b = pc[e[1]], pc[e[2]]
		if (a.ok and b.ok) then table.insert(segs, { a[1], a[2], b[1], b[2] }) end
	end
	return { segs = segs }
end

local function objOutline(idx, right)
	local o = MSV2.objs[idx]
	return outline(o.type, MSV2.objPos(idx), MSV2.objRot(idx), { o.dims_x or 0, o.dims_y or 0, o.dims_z or 0 }, right)
end

function MSV2.buildFrame()
	local F = { centers = {}, outlines = {}, labels = {}, links = {}, verts = {}, triEdges = {}, hier = {} }
	local camPos, _, fwd, right, up = camVectors()
	F.right, F.fwd = right, fwd

	-- Object centers (box select + labels)
	for idx in pairs(MSV2.objs) do
		local c = P(MSV2.objPos(idx))
		if (c.ok) then F.centers[idx] = c end
	end

	-- Outlines for the selection (triangles get their real edges instead of slices)
	local tris, plain = MSV2.selSplit()
	local count = 0
	for _, idx in ipairs(plain) do
		count = count + 1
		if (count > 300) then break end
		local ol = objOutline(idx, right)
		if (ol) then
			ol.color = idx == MSV2.primary and PRIMARY_COLOR or SELECT_COLOR
			table.insert(F.outlines, ol)
		end
	end
	for id in pairs(tris) do
		local t = MSV2.tris[id]
		local pa, pb, pc = P(t.a), P(t.b), P(t.c)
		F.triEdges[id] = { pa, pb, pc }
		F.verts[id] = { a = pa, b = pb, c = pc }
	end
	if (G.hoverObj and MSV2.objs[G.hoverObj] and not MSV2.sel[G.hoverObj]) then
		local m = MSV2.meta[G.hoverObj]
		if (m and m.tri and MSV2.tris[m.tri]) then
			local t = MSV2.tris[m.tri]
			F.hoverTri = { P(t.a), P(t.b), P(t.c) }
		else
			local ol = objOutline(G.hoverObj, right)
			if (ol) then
				ol.color = HOVER_OUTLINE
				ol.alpha = 0.45
				table.insert(F.outlines, ol)
			end
		end
	end

	-- Body / joint selection on the player tabs
	-- Uses where the game actually draws the player, not the raw mod values
	local function bodyOutline(p, b, color, alpha)
		local w = MSV2.bodyWorld(p, b)
		if (not w) then return end
		local ol = outline(w.shape, w.pos, w.R, w.sides, right)
		if (ol) then
			ol.color, ol.alpha = color, alpha
			table.insert(F.outlines, ol)
		end
	end
	if (tabOpen("players")) then
		if (MSV2.bodySel) then bodyOutline(MSV2.bodySel.p, MSV2.bodySel.b, PRIMARY_COLOR) end
		if (G.hoverBody and not (MSV2.bodySel and MSV2.bodySel.p == G.hoverBody.p and MSV2.bodySel.b == G.hoverBody.b)) then
			bodyOutline(G.hoverBody.p, G.hoverBody.b, HOVER_OUTLINE, 0.5)
		end
	end
	if (tabOpen("joints") and MSV2.jointSel) then
		local o = MSV2.joints[MSV2.jointSel.p] and MSV2.joints[MSV2.jointSel.p][MSV2.jointSel.j]
		local w = MSV2.jointWorld(MSV2.jointSel.p, MSV2.jointSel.j)
		if (o and w) then
			local W = MSV2.playerFrame(MSV2.jointSel.p)
			local pos = w.pos
			local axis = V.norm(M.apply(W, { o.axis_x or 0, o.axis_y or 0, o.axis_z or 0 }))
			local c = P(pos)
			local e = P(V.add(pos, V.mul(right, math.max(0.05, w.radius))))
			local a1 = P(V.add(pos, V.mul(axis, 0.4)))
			local a2 = P(V.sub(pos, V.mul(axis, 0.4)))
			if (c.ok and e.ok) then
				local ol = { circle = { c[1], c[2], sqrt((e[1] - c[1]) ^ 2 + (e[2] - c[2]) ^ 2) }, color = PRIMARY_COLOR, segs = {} }
				if (a1.ok and a2.ok) then table.insert(ol.segs, { a1[1], a1[2], a2[1], a2[2] }) end
				table.insert(F.outlines, ol)
			end
		end
	end

	-- Links between objects
	if (MSV2.settings.showLinks or tabOpen("links")) then
		for j, ej in pairs(MSV2.ejs) do
			local o1, o2 = MSV2.objs[ej.obj1], MSV2.objs[ej.obj2]
			if (o1 and o2) then
				local a, b = P(MSV2.objPos(ej.obj1)), P(MSV2.objPos(ej.obj2))
				local jp = P({ ej.pos_x or 0, ej.pos_y or 0, ej.pos_z or 0 })
				table.insert(F.links, { a = a, b = b, j = jp, selected = MSV2.ejSel == j })
			end
		end
	end

	-- Hierarchy: lines from the selection to its parent and down through its
	-- children, plus a faint outline on children that will move along with it
	if (MSV2.settings.showHierarchy ~= false or (MSV2.UI and MSV2.UI.parentPick)) then
		local set = MSV2.selKeys()
		local H = (next(set) ~= nil or MSV2.settings.showAllHierarchy) and MSV2.hier() or nil
		if (H) then
			local done, n = {}, 0
			local function addLine(child, parent, strong)
				local id = child .. ">" .. parent
				if (done[id] or n > 400) then return end
				done[id] = true
				n = n + 1
				table.insert(F.hier, { a = P(MSV2.nodePos(child)), b = P(MSV2.nodePos(parent)), strong = strong })
			end
			for key in pairs(set) do
				if (H.parent[key]) then addLine(key, H.parent[key], true) end
				for _, d in ipairs(MSV2.descendants(key, H)) do addLine(d, H.parent[d], true) end
			end
			if (MSV2.settings.showAllHierarchy) then
				for child, parent in pairs(H.parent) do addLine(child, parent, false) end
			end
			if (MSV2.childrenFollow() and next(set) ~= nil) then
				local m = 0
				for key in pairs(MSV2.withDescendants(set, H)) do
					if (not set[key]) then
						m = m + 1
						if (m > 150) then break end
						local kind, id = MSV2.parseNodeKey(key)
						local ol
						if (kind == "t") then
							local t = MSV2.tris[id]
							local pa, pb, pc = P(t.a), P(t.b), P(t.c)
							ol = { segs = {} }
							for _, e in ipairs({ { pa, pb }, { pb, pc }, { pc, pa } }) do
								if (e[1].ok and e[2].ok) then table.insert(ol.segs, { e[1][1], e[1][2], e[2][1], e[2][2] }) end
							end
						else
							ol = objOutline(id, right)
						end
						if (ol) then
							ol.color, ol.alpha = HIER_COLOR, 0.55
							table.insert(F.outlines, ol)
						end
					end
				end
			end
		end
	end

	-- Measuring
	local m = MSV2.measure
	if (m and m.a) then
		F.measure = { a = P(m.a), b = m.b and P(m.b) or nil, pa = m.a, pb = m.b }
	end

	-- Dojo resize handle while placing players
	if (placingPlayers()) then
		local r = MSV2.dojoShape()
		if (r) then
			local c = MSV2.dojoCenter()
			F.dojoHandle = P({ c[1] + r, c[2], 0.02 })
		end
	end

	-- Labels
	if (MSV2.settings.showLabels) then
		local n = 0
		for idx, c in pairs(F.centers) do
			local m = MSV2.meta[idx]
			if ((not (m and m.tri) or MSV2.tris[m.tri].objs[1] == idx) and not (MSV2.isHidden and MSV2.isHidden(idx))) then
				n = n + 1
				if (n > 200) then break end
				table.insert(F.labels, { c[1], c[2], MSV2.objName(idx) })
			end
		end
	end

	-- Gizmo
	local ctx = (MSV2.settings.tool ~= "select") and MSV2.gizmoContext() or nil
	if (G.drag and G.drag.started) then ctx = MSV2.gizmoContext() end
	if (ctx and (MSV2.settings.tool == "move" or (MSV2.settings.tool == "rotate" and ctx.rot) or (MSV2.settings.tool == "scale" and ctx.scale) or ctx.kind == "vertex" or ctx.kind == "joint")) then
		local tool = MSV2.settings.tool
		if (ctx.kind == "vertex" or ctx.kind == "joint") then tool = "move" end
		local pivot = ctx.pivot
		local c = P(pivot)
		local r = P(V.add(pivot, right))
		if (c.ok and r.ok) then
			local ppu = sqrt((r[1] - c[1]) ^ 2 + (r[2] - c[2]) ^ 2)
			if (ppu > 0.01) then
				local L = MSV2.settings.gizmoSize / ppu
				local g = { tool = tool, center = c, L = L, axes = {}, planes = {}, rings = {} }
				for k = 1, 3 do
					local dir = M.col(ctx.A, k)
					local tip = P(V.add(pivot, V.mul(dir, L)))
					local base = P(V.add(pivot, V.mul(dir, L * 0.18)))
					g.axes[k] = { tip = tip, base = base, ok = tip.ok and base.ok and ((tip[1] - c[1]) ^ 2 + (tip[2] - c[2]) ^ 2) > 196 }
				end
				if (tool == "move") then
					for k = 1, 3 do
						local i, j = k % 3 + 1, (k + 1) % 3 + 1
						local di, dj = M.col(ctx.A, i), M.col(ctx.A, j)
						local q = {}
						for n, uv in ipairs({ { 0.22, 0.22 }, { 0.42, 0.22 }, { 0.42, 0.42 }, { 0.22, 0.42 } }) do
							q[n] = P(V.add(pivot, V.add(V.mul(di, uv[1] * L), V.mul(dj, uv[2] * L))))
						end
						g.planes[k] = { q = q, ok = q[1].ok and q[2].ok and q[3].ok and q[4].ok }
					end
				elseif (tool == "rotate") then
					for k = 1, 3 do
						local a1, a2 = M.col(ctx.A, k % 3 + 1), M.col(ctx.A, (k + 1) % 3 + 1)
						local pts, ok = {}, true
						for n = 0, 48 do
							local t = n / 48 * math.pi * 2
							local p = P(V.add(pivot, V.add(V.mul(a1, math.cos(t) * L * 0.85), V.mul(a2, math.sin(t) * L * 0.85))))
							if (not p.ok) then ok = false end
							pts[n + 1] = p
						end
						g.rings[k] = { pts = pts, ok = ok }
					end
				end
				F.giz = g
			end
		end
	end
	MSV2.frame = F
end

---------------------------------------------------------------------------
-- Hit testing (screen space, uses the last frame's projections)
---------------------------------------------------------------------------

local function distSeg(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local l2 = dx * dx + dy * dy
	local t = 0
	if (l2 > 0) then t = MSV2.clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1) end
	local cx, cy = ax + t * dx, ay + t * dy
	return sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

local function inQuad(px, py, q)
	local sign = 0
	for i = 1, 4 do
		local a, b = q[i], q[i % 4 + 1]
		local cr = (b[1] - a[1]) * (py - a[2]) - (b[2] - a[2]) * (px - a[1])
		if (cr ~= 0) then
			local s = cr > 0 and 1 or -1
			if (sign == 0) then sign = s elseif (s ~= sign) then return false end
		end
	end
	return true
end

function MSV2.gizmoHit(x, y)
	local g = MSV2.frame and MSV2.frame.giz
	if (not g) then return nil end
	local c = g.center
	local dc = sqrt((x - c[1]) ^ 2 + (y - c[2]) ^ 2)
	if (g.tool == "move") then
		if (dc < 11) then return { type = "free" } end
		for k = 1, 3 do
			local pl = g.planes[k]
			if (pl and pl.ok and inQuad(x, y, pl.q)) then return { type = "plane", k = k } end
		end
	elseif (g.tool == "scale") then
		if (dc < 12) then return { type = "suni" } end
	end
	local best, bestD = nil, 9
	if (g.tool == "move" or g.tool == "scale") then
		for k = 1, 3 do
			local a = g.axes[k]
			if (a.ok) then
				local d = distSeg(x, y, a.base[1], a.base[2], a.tip[1], a.tip[2])
				local dt = sqrt((x - a.tip[1]) ^ 2 + (y - a.tip[2]) ^ 2) - 4
				d = math.min(d, dt)
				if (d < bestD) then best, bestD = { type = g.tool == "move" and "axis" or "saxis", k = k }, d end
			end
		end
	elseif (g.tool == "rotate") then
		for k = 1, 3 do
			local ring = g.rings[k]
			if (ring) then
				for n = 1, #ring.pts - 1 do
					local a, b = ring.pts[n], ring.pts[n + 1]
					if (a.ok and b.ok) then
						local d = distSeg(x, y, a[1], a[2], b[1], b[2])
						if (d < bestD) then best, bestD = { type = "ring", k = k }, d end
					end
				end
			end
		end
	end
	return best
end

---Triangle corner handle under the cursor
local function vertexHit(x, y)
	local F = MSV2.frame
	if (not F) then return nil end
	for id, vs in pairs(F.verts) do
		for _, key in ipairs({ "a", "b", "c" }) do
			local p = vs[key]
			if (p and p.ok and (x - p[1]) ^ 2 + (y - p[2]) ^ 2 < 110) then
				return id, key
			end
		end
	end
	return nil
end

local function pickObj(x, y)
	MSV2.flush()
	local ok, idx, dist = pcall(pick_mod_envobj, x, y)
	if (ok and idx ~= nil and MSV2.objs[idx]) then
		local m = MSV2.meta[idx]
		if (m and m.locked) then return nil end
		if (MSV2.isHidden and MSV2.isHidden(idx)) then return nil end
		return idx, dist
	end
	return nil
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function MSV2.draw3d()
	-- Ground grid
	if (MSV2.settings.showGrid) then
		local step = MSV2.settings.gridStep
		if (step <= 0) then step = 1 end
		local ext = MSV2.settings.gridExtent or 16
		while (ext / step > 48) do step = step * 2 end
		local n = floor(ext / step)
		for i = -n, n do
			local v = i * step
			local major = abs(v - MSV2.round(v, 1)) < 1e-6
			if (i == 0) then
				set_color(0.95, 0.3, 0.3, 0.7)
				pcall(draw_line, -ext, 0, 0.006, ext, 0, 0.006, 2)
				set_color(0.4, 0.85, 0.3, 0.7)
				pcall(draw_line, 0, -ext, 0.006, 0, ext, 0.006, 2)
			else
				set_color(1, 1, 1, major and 0.16 or 0.07)
				pcall(draw_line, v, -ext, 0.005, v, ext, 0.005, 1)
				pcall(draw_line, -ext, v, 0.005, ext, v, 0.005, 1)
			end
		end
	end
	-- Dojo outline on the floor
	local placing = placingPlayers()
	if (MSV2.settings.showDojo or placing) then
		local r, kind = MSV2.dojoShape()
		if (r) then
			local c = MSV2.dojoCenter()
			local z = 0.012
			set_color(1, 0.85, 0.3, placing and 0.9 or 0.45)
			if (kind == 0) then
				local x1, x2, y1, y2 = c[1] - r, c[1] + r, c[2] - r, c[2] + r
				pcall(draw_line, x1, y1, z, x2, y1, z, 2)
				pcall(draw_line, x2, y1, z, x2, y2, z, 2)
				pcall(draw_line, x2, y2, z, x1, y2, z, 2)
				pcall(draw_line, x1, y2, z, x1, y1, z, 2)
			else
				local seg = 64
				for i = 0, seg - 1 do
					local a1, a2 = i / seg * math.pi * 2, (i + 1) / seg * math.pi * 2
					pcall(draw_line, c[1] + math.cos(a1) * r, c[2] + math.sin(a1) * r, z, c[1] + math.cos(a2) * r, c[2] + math.sin(a2) * r, z, 2)
				end
			end
		end
	end
	-- Measuring line (depth tested so it sits in the world)
	local m = MSV2.measure
	if (m and m.a and m.b) then
		set_color(0.35, 0.9, 1, 0.9)
		pcall(draw_line, m.a[1], m.a[2], m.a[3] + 0.01, m.b[1], m.b[2], m.b[3] + 0.01, 3)
	end

	-- Translucent fill for selected / hovered triangles, both windings
	local tris = MSV2.selSplit()
	local function fill(t, a)
		set_color(SELECT_COLOR[1], SELECT_COLOR[2], SELECT_COLOR[3], a)
		pcall(draw_triangle, t.a[1], t.a[2], t.a[3], t.b[1], t.b[2], t.b[3], t.c[1], t.c[2], t.c[3])
		pcall(draw_triangle, t.a[1], t.a[2], t.a[3], t.c[1], t.c[2], t.c[3], t.b[1], t.b[2], t.b[3])
	end
	for id in pairs(tris) do fill(MSV2.tris[id], 0.22) end
end

local function line2d(a, b, w)
	pcall(draw_line, a[1], a[2], b[1], b[2], w)
end

local function disk(x, y, r)
	pcall(draw_disk, x, y, 0, r, 20, 1, 0, 360, 0)
end

local function ring2d(x, y, r, w)
	pcall(draw_disk, x, y, math.max(0, r - w / 2), r + w / 2, 40, 1, 0, 360, 0)
end

local function text(str, x, y, r, g, b, a)
	set_color(0, 0, 0, 0.6 * (a or 1))
	pcall(draw_text, str, x + 1, y + 1, 1)
	set_color(r or 1, g or 1, b or 1, a or 1)
	pcall(draw_text, str, x, y, 1)
end
MSV2.text2d = text

local function axisColor(k, hovered)
	if (hovered) then return HOVER_COLOR end
	return AXIS_COLORS[k]
end

local function sameHandle(h, t, k)
	return h and h.type == t and (k == nil or h.k == k)
end

function MSV2.draw2d()
	local F = MSV2.frame
	if (not F) then return end
	MSV2.applyViewColors()
	local ow, gw = outlineW(), gizmoW()

	-- Outlines
	for _, ol in ipairs(F.outlines) do
		local c = ol.color
		set_color(c[1], c[2], c[3], ol.alpha or 0.95)
		for _, s in ipairs(ol.segs or {}) do pcall(draw_line, s[1], s[2], s[3], s[4], ow) end
		if (ol.circle) then ring2d(ol.circle[1], ol.circle[2], ol.circle[3], ow) end
	end
	if (F.hoverTri) then
		set_color(HOVER_OUTLINE[1], HOVER_OUTLINE[2], HOVER_OUTLINE[3], 0.5)
		local e = F.hoverTri
		for i = 1, 3 do
			local a, b = e[i], e[i % 3 + 1]
			if (a.ok and b.ok) then line2d(a, b, ow) end
		end
	end
	for _, e in pairs(F.triEdges) do
		set_color(SELECT_COLOR[1], SELECT_COLOR[2], SELECT_COLOR[3], 1)
		for i = 1, 3 do
			local a, b = e[i], e[i % 3 + 1]
			if (a.ok and b.ok) then line2d(a, b, ow + 0.5) end
		end
	end
	-- Triangle corner handles
	for id, vs in pairs(F.verts) do
		for _, key in ipairs({ "a", "b", "c" }) do
			local p = vs[key]
			if (p and p.ok) then
				local active = MSV2.vertexSel and MSV2.vertexSel.tri == id and MSV2.vertexSel.key == key
				local hov = G.hoverVertex and G.hoverVertex.tri == id and G.hoverVertex.key == key
				set_color(0, 0, 0, 0.7)
				disk(p[1], p[2], 8)
				if (active) then set_color(PRIMARY_COLOR[1], PRIMARY_COLOR[2], PRIMARY_COLOR[3], 1)
				elseif (hov) then set_color(HOVER_COLOR[1], HOVER_COLOR[2], HOVER_COLOR[3], 1)
				else set_color(1, 1, 1, 1) end
				disk(p[1], p[2], 6)
				text(string.upper(key), p[1] + 9, p[2] - 18)
			end
		end
	end

	-- Parent lines (child end small dot, parent end big dot)
	for _, l in ipairs(F.hier or {}) do
		if (l.a.ok and l.b.ok) then
			set_color(HIER_COLOR[1], HIER_COLOR[2], HIER_COLOR[3], l.strong and 0.9 or 0.4)
			line2d(l.a, l.b, l.strong and 1.5 or 1)
			set_color(0, 0, 0, 0.6)
			disk(l.b[1], l.b[2], 5)
			set_color(HIER_COLOR[1], HIER_COLOR[2], HIER_COLOR[3], 1)
			disk(l.b[1], l.b[2], 3.5)
			disk(l.a[1], l.a[2], 2)
		end
	end

	-- Links
	for _, l in ipairs(F.links) do
		if (l.a.ok and l.b.ok) then
			if (l.selected) then set_color(1, 0.85, 0.2, 0.95) else set_color(1, 0.6, 0.2, 0.6) end
			line2d(l.a, l.b, l.selected and 2.5 or 1.5)
		end
		if (l.j.ok) then
			set_color(0, 0, 0, 0.7)
			disk(l.j[1], l.j[2], 6)
			if (l.selected) then set_color(1, 0.85, 0.2, 1) else set_color(1, 0.6, 0.2, 1) end
			disk(l.j[1], l.j[2], 4)
		end
	end

	-- Labels
	for _, lb in ipairs(F.labels) do
		local ok, w = pcall(get_string_length, lb[3], 1)
		w = ok and w or 40
		text(lb[3], lb[1] - w / 2, lb[2] - 20, 1, 1, 1, 0.85)
	end

	-- Gizmo
	local g = F.giz
	if (g) then
		local hov = G.drag and G.drag.handle or G.hover
		local c = g.center
		if (g.tool == "move" or g.tool == "scale") then
			for k = 1, 3 do
				local a = g.axes[k]
				if (a.ok) then
					local hovered = sameHandle(hov, g.tool == "move" and "axis" or "saxis", k)
					local col = axisColor(k, hovered)
					set_color(0, 0, 0, 0.45)
					pcall(draw_line, c[1], c[2], a.tip[1], a.tip[2], (hovered and 6 or 5) * gw)
					set_color(col[1], col[2], col[3], 1)
					pcall(draw_line, c[1], c[2], a.tip[1], a.tip[2], (hovered and 4 or 3) * gw)
					if (g.tool == "move") then
						set_color(0, 0, 0, 0.5)
						disk(a.tip[1], a.tip[2], 8)
						set_color(col[1], col[2], col[3], 1)
						disk(a.tip[1], a.tip[2], 6.5)
					else
						set_color(0, 0, 0, 0.5)
						pcall(draw_quad, a.tip[1] - 7, a.tip[2] - 7, 14, 14)
						set_color(col[1], col[2], col[3], 1)
						pcall(draw_quad, a.tip[1] - 5.5, a.tip[2] - 5.5, 11, 11)
					end
					text(AXIS_NAMES[k], a.tip[1] + 9, a.tip[2] - 9, col[1], col[2], col[3], 1)
				end
			end
			if (g.tool == "move") then
				for k = 1, 3 do
					local pl = g.planes[k]
					if (pl and pl.ok) then
						local hovered = sameHandle(hov, "plane", k)
						local col = axisColor(k, hovered)
						set_color(col[1], col[2], col[3], hovered and 1 or 0.75)
						for n = 1, 4 do line2d(pl.q[n], pl.q[n % 4 + 1], (hovered and 3 or 2) * gw) end
						local cx = (pl.q[1][1] + pl.q[3][1]) / 2
						local cy = (pl.q[1][2] + pl.q[3][2]) / 2
						set_color(col[1], col[2], col[3], hovered and 0.7 or 0.35)
						disk(cx, cy, 4)
					end
				end
			end
			local centerHover = sameHandle(hov, g.tool == "move" and "free" or "suni")
			set_color(0, 0, 0, 0.55)
			disk(c[1], c[2], 9)
			if (centerHover) then set_color(HOVER_COLOR[1], HOVER_COLOR[2], HOVER_COLOR[3], 1) else set_color(1, 1, 1, 1) end
			disk(c[1], c[2], 7)
		elseif (g.tool == "rotate") then
			for k = 1, 3 do
				local ring = g.rings[k]
				if (ring) then
					local hovered = sameHandle(hov, "ring", k)
					local col = axisColor(k, hovered)
					set_color(col[1], col[2], col[3], hovered and 1 or 0.85)
					for n = 1, #ring.pts - 1 do
						local a, b = ring.pts[n], ring.pts[n + 1]
						if (a.ok and b.ok) then line2d(a, b, (hovered and 4 or 2.5) * gw) end
					end
				end
			end
			set_color(1, 1, 1, 0.9)
			disk(c[1], c[2], 4)
		end
	end

	-- Measuring points + distance label
	local ms = F.measure
	if (ms) then
		for _, p in ipairs({ ms.a, ms.b }) do
			if (p and p.ok) then
				set_color(0, 0, 0, 0.7)
				disk(p[1], p[2], 7)
				set_color(0.35, 0.9, 1, 1)
				disk(p[1], p[2], 5)
			end
		end
		if (ms.b and ms.a.ok and ms.b.ok and ms.pb) then
			local d = V.sub(ms.pb, ms.pa)
			local s = MSV2.fmt(V.len(d)) .. "   (" .. MSV2.fmt(d[1]) .. ", " .. MSV2.fmt(d[2]) .. ", " .. MSV2.fmt(d[3]) .. ")"
			local mx, my = (ms.a[1] + ms.b[1]) / 2, (ms.a[2] + ms.b[2]) / 2
			local ok, w = pcall(get_string_length, s, 1)
			w = ok and w or 120
			set_color(0, 0, 0, 0.7)
			pcall(draw_quad, mx - w / 2 - 6, my - 26, w + 12, 22)
			text(s, mx - w / 2, my - 24, 0.6, 0.95, 1)
		end
	end

	-- Dojo resize handle
	local dh = F.dojoHandle
	if (dh and dh.ok) then
		set_color(0, 0, 0, 0.7)
		disk(dh[1], dh[2], 9)
		set_color(1, 0.85, 0.3, 1)
		disk(dh[1], dh[2], 7)
		text(G.dojoReadout or "Drag to resize the dojo", dh[1] + 12, dh[2] - 9, 1, 0.9, 0.5)
	end

	-- Box selection rectangle
	local mq = G.marquee
	if (mq and mq.active) then
		local x1, y1 = math.min(mq.x0, mq.x1), math.min(mq.y0, mq.y1)
		local w, h = abs(mq.x1 - mq.x0), abs(mq.y1 - mq.y0)
		set_color(0.35, 0.9, 1, 0.12)
		pcall(draw_quad, x1, y1, w, h)
		set_color(0.35, 0.9, 1, 0.9)
		pcall(draw_line, x1, y1, x1 + w, y1, 1)
		pcall(draw_line, x1, y1 + h, x1 + w, y1 + h, 1)
		pcall(draw_line, x1, y1, x1, y1 + h, 1)
		pcall(draw_line, x1 + w, y1, x1 + w, y1 + h, 1)
	end

	-- Drag readout next to the cursor
	local drag = G.drag
	if (drag and drag.started and drag.readout and drag.mx) then
		local s = drag.readout .. (drag.snap and "  [snap]" or "")
		local ok, w = pcall(get_string_length, s, 1)
		w = ok and w or 100
		set_color(0, 0, 0, 0.65)
		pcall(draw_quad, drag.mx + 16, drag.my + 14, w + 12, 22)
		text(s, drag.mx + 22, drag.my + 16)
	end
end

---------------------------------------------------------------------------
-- Camera helpers
---------------------------------------------------------------------------

---Smoothly moves the camera to look at `target` from `dir` (unit vector) at `dist`.
---`stay` (focus / view buttons) leaves the camera in free mode afterwards so the
---game's normal camera doesn't pull it straight back.
function MSV2.cameraTo(target, dir, dist, dur, stay)
	local camPos, look = camVectors()
	if (not dir) then
		dir = V.norm(V.sub(camPos, look))
		if (V.len(dir) < 0.5) then dir = V.norm({ 0.6, -1, 0.6 }) end
	end
	MSV2.camAnim = {
		fromPos = camPos, fromLook = look,
		toPos = V.add(target, V.mul(dir, dist)), toLook = V.copy(target),
		t0 = clock(), dur = dur or 0.35, stay = stay
	}
	if (stay and not G.drag) then
		-- The mouse camera overwrites script moves every frame while it's on
		pcall(disable_mouse_camera_movement)
		MSV2.camAnim.reenable = true
	end
end

---Zooms toward the look-at point. Several quick notches add up instead of restarting.
function MSV2.zoomCamera(factor)
	local camPos, look = camVectors()
	local a = MSV2.camAnim
	local fromPos, target = camPos, look
	if (a) then
		-- Continue from where the running zoom/focus is heading
		fromPos, target = a.toPos, a.toLook
	end
	local off = V.sub(fromPos, target)
	local d = MSV2.clamp(V.len(off) * factor, 0.6, 80)
	MSV2.cameraTo(target, V.norm(off), d, 0.15)
end

---The game resets the camera every frame unless it's moved from inside the
---"camera" hook in FREE mode (same trick the game's own tutorial uses).
---Movement is queued here and applied by MSV2.onCamera().
function MSV2.tickCamera()
	local a = MSV2.camAnim
	if (not a) then return end
	local t = MSV2.clamp((clock() - a.t0) / a.dur, 0, 1)
	local e = t * t * (3 - 2 * t)
	MSV2.camRequest = { pos = V.lerp(a.fromPos, a.toPos, e), look = V.lerp(a.fromLook, a.toLook, e), stay = a.stay }
	if (t >= 1) then
		MSV2.camAnim = nil
		if (a.reenable) then
			-- Turn the mouse camera back on once the last frame has been placed
			MSV2.camReenableAfter = 2
		end
	end
end

MSV2.camStats = MSV2.camStats or { hookCalls = 0 }

local function placeCamera(pos, look, stay)
	local okm, mode = pcall(get_camera_mode)
	mode = (okm and type(mode) == "number") and mode or 0
	if (stay and mode ~= 3 and MSV2.prevCamMode == nil) then
		-- Remember the player's camera mode so closing Mod Studio can put it back
		MSV2.prevCamMode = mode
	end
	pcall(set_camera_mode, 3)
	pcall(set_camera_lookat, look[1], look[2], look[3])
	pcall(set_camera_pos, pos[1], pos[2], pos[3])
	if (not stay) then
		pcall(set_camera_mode, mode)
	end
end

---"camera" hook. Returning 1 tells the game the script placed the camera this frame.
function MSV2.onCamera()
	MSV2.camStats.hookCalls = MSV2.camStats.hookCalls + 1
	if (MSV2.camReenableAfter) then
		MSV2.camReenableAfter = MSV2.camReenableAfter - 1
		if (MSV2.camReenableAfter <= 0) then
			MSV2.camReenableAfter = nil
			if (not G.drag) then pcall(enable_mouse_camera_movement) end
		end
	end
	local r = MSV2.camRequest
	if (not r) then return end
	MSV2.camRequest = nil
	placeCamera(r.pos, r.look, r.stay)
	return 1
end

---Puts the camera mode back to what it was before Mod Studio's first focus
function MSV2.restoreCameraMode()
	if (MSV2.prevCamMode ~= nil) then
		pcall(set_camera_mode, MSV2.prevCamMode)
		MSV2.prevCamMode = nil
	end
end

---------------------------------------------------------------------------
-- Zooming while dragging. The game blocks its own zoom while the mouse camera
-- is off, and there's more than one way to move the camera from a script, so
-- Mod Studio tries each method, checks the camera really moved, and keeps the
-- one that works (saved in settings.camMethod).
---------------------------------------------------------------------------

MSV2.CAM_METHODS = { "hook", "native", "hold" }
local METHOD_NAMES = { hook = "camera hook", native = "game's own zoom", hold = "held distance" }

local function camDist()
	local camPos, look = camVectors()
	return V.dist(camPos, look), camPos, look
end

---Wheel while click-dragging an object: push it away from / pull it toward the
---camera along the line of sight, so it stays under the cursor
function MSV2.dragPush(btn)
	local drag = G.drag
	local ctx = MSV2.gizmoContext()
	if (not drag or not ctx or ctx.kind ~= "env") then return 1 end
	if (not drag.started) then
		drag.started = true
		MSV2.pushUndo("Move")
	end
	local camPos = camVectors()
	local dir = V.sub(ctx.pivot, camPos)
	local dist = V.len(dir)
	if (dist < 1e-3) then return 1 end
	dir = V.mul(dir, 1 / dist)
	local step = math.max(0.1, dist * 0.1)
	if (MSV2.snapActive() and MSV2.settings.gridStep > 0) then
		step = math.max(MSV2.settings.gridStep, MSV2.round(step, MSV2.settings.gridStep))
	end
	local sign = (btn == 4) and 1 or -1
	if (sign < 0) then step = math.min(step, math.max(0, dist - 0.6)) end
	if (step <= 0) then
		MSV2.toast("Can't pull it any closer")
		return 1
	end
	MSV2.translateSelection(V.mul(dir, sign * step))
	-- From here on the object slides at its new distance from the camera: Stick
	-- or the floor-level slide would put it straight back where it was
	drag.pushed = true
	if (drag.handle.type == "direct" or drag.handle.type == "free") then
		local _, look = camVectors()
		drag.normal = V.norm(V.sub(camPos, look))
	end
	MSV2.rebaseAt(drag, G.mouseX or drag.x0, G.mouseY or drag.y0)
	drag.readout = (sign > 0 and "Pushed away: " or "Pulled closer: ") .. MSV2.fmt(dist + sign * step) .. " from camera"
	drag.mx, drag.my = G.mouseX or drag.mx, G.mouseY or drag.my
	if (not MSV2.pushHintShown) then
		MSV2.pushHintShown = true
		MSV2.toast("Scroll pushes the object away / pulls it closer. Shift+scroll zooms the camera instead")
	end
	return 1
end

---Called for wheel events while dragging. Returns 1 to swallow the event.
function MSV2.dragZoom(btn)
	local f = btn == 4 and 0.82 or (1 / 0.82)
	local method = MSV2.settings.camMethod or "hook"
	local d, camPos, look = camDist()
	if (not G.zoomProbe) then
		G.zoomProbe = { method = method, dist0 = d, t0 = clock(), zoomIn = btn == 4 }
	end
	if (method == "native") then
		-- Let this one wheel event through to the game with the mouse camera on
		pcall(enable_mouse_camera_movement)
		G.reDisableCam = true
		return nil
	elseif (method == "hold") then
		local base = G.camHold and G.camHold.dist or d
		G.camHold = { dist = MSV2.clamp(base * f, 0.6, 80), dir = V.norm(V.sub(camPos, look)) }
		return 1
	end
	MSV2.zoomCamera(f)
	return 1
end

local function nextMethod(cur, tried)
	for _, m in ipairs(MSV2.CAM_METHODS) do
		if (not tried[m] and m ~= cur) then return m end
	end
	return nil
end

local function judgeZoomProbe()
	local p = G.zoomProbe
	if (not p or clock() - p.t0 < 0.4) then return end
	G.zoomProbe = nil
	if (not G.drag) then return end -- let go too early to tell
	local d = camDist()
	G.zoomTried = G.zoomTried or {}
	if (MSV2.settings.camMethodOk and MSV2.settings.camMethod == p.method) then
		-- A method that has worked before only stops when the game won't zoom any further
		if (math.abs(d - p.dist0) <= 0.01) then
			MSV2.toast(p.zoomIn and "Can't zoom in any closer" or "Can't zoom out any further")
		end
		return
	end
	if (math.abs(d - p.dist0) > 0.01) then
		if (MSV2.settings.camMethod ~= p.method or not MSV2.settings.camMethodOk) then
			MSV2.settings.camMethod = p.method
			MSV2.settings.camMethodOk = true
			MSV2.saveSettings()
			echo("Mod Studio: zoom while dragging works (using " .. METHOD_NAMES[p.method] .. ")")
		end
		return
	end
	G.zoomTried[p.method] = true
	local nm = nextMethod(p.method, G.zoomTried)
	local info = "camera hook ran " .. MSV2.camStats.hookCalls .. " times, camera mode " .. tostring(select(2, pcall(get_camera_mode)))
	if (nm) then
		MSV2.settings.camMethod = nm
		MSV2.settings.camMethodOk = false
		MSV2.saveSettings()
		echo("Mod Studio: zoom via " .. METHOD_NAMES[p.method] .. " did nothing (" .. info .. "). Trying " .. METHOD_NAMES[nm] .. " - scroll again")
		G.camHold = nil
	else
		echo("Mod Studio: couldn't zoom while dragging with any method (" .. info .. "). Please send this line to the developer.")
	end
end

---Per frame: zoom bookkeeping, and keeps the dragged thing under the cursor
---whenever the camera moves (scroll zoom, smooth camera, keyboard camera).
function MSV2.tickZoom()
	if (G.reDisableCam) then
		G.reDisableCam = nil
		if (G.drag) then pcall(disable_mouse_camera_movement) end
	end
	if (G.camHold) then
		if (G.drag) then
			local _, _, look = camDist()
			local pos = V.add(look, V.mul(G.camHold.dir, G.camHold.dist))
			MSV2.camRequest = { pos = pos, look = look }
			pcall(set_camera_pos, pos[1], pos[2], pos[3])
		else
			G.camHold = nil
		end
	end
	judgeZoomProbe()
	local drag = G.drag
	if (drag and G.dragCam and G.mouseX) then
		local camPos, look = camVectors()
		if (V.dist(camPos, G.dragCam[1]) > 1e-4 or V.dist(look, G.dragCam[2]) > 1e-4) then
			MSV2.carryWithCamera(drag, G.dragCam, { camPos, look })
			G.dragCam = { V.copy(camPos), V.copy(look) }
			MSV2.rebaseDrag()
		end
	end
end

local function camFrame(pos, look)
	local fwd = V.norm(V.sub(look, pos))
	local right = V.cross(fwd, { 0, 0, 1 })
	right = V.len(right) < 1e-3 and { 1, 0, 0 } or V.norm(right)
	return fwd, right, V.norm(V.cross(right, fwd))
end

---The game camera moved (WASD slides or swings it around): bring the held
---object along so it keeps its place in view (kept to the handle's axis /
---plane). Mod Studio's own zoom leaves it where it is.
function MSV2.carryWithCamera(drag, old, new)
	if (MSV2.camAnim or MSV2.camRequest or G.camHold or G.zoomProbe) then return end
	local ctx = MSV2.gizmoContext()
	if (not ctx or ctx.kind ~= "env") then return end
	local f0, r0, u0 = camFrame(old[1], old[2])
	local f1, r1, u1 = camFrame(new[1], new[2])
	local rel = V.sub(ctx.pivot, old[1])
	local lx, ly, lz = V.dot(rel, r0), V.dot(rel, u0), V.dot(rel, f0)
	local p1 = V.add(new[1], V.add(V.mul(r1, lx), V.add(V.mul(u1, ly), V.mul(f1, lz))))
	local h = drag.handle
	local d = V.sub(p1, ctx.pivot)
	if (h.type == "axis" and drag.axis) then
		d = V.mul(drag.axis, V.dot(d, drag.axis))
	elseif (h.type == "plane" or (h.type == "direct" and h.vertical)) then
		d = V.sub(d, V.mul(drag.normal, V.dot(d, drag.normal)))
	elseif (h.type == "direct" and not h.cameraPlane and not drag.pushed) then
		d[3] = 0
	elseif (h.type ~= "direct" and h.type ~= "free") then
		return -- rotating / scaling
	end
	if (V.len(d) < 1e-6) then return end
	if (not drag.started) then
		drag.started = true
		MSV2.pushUndo("Move")
	end
	MSV2.translateSelection(d)
end

---The camera moved mid-drag (zoom, WASD, smooth camera). Don't touch the object:
---just mark the drag so the next mouse update re-anchors it with the camera as
---the game currently sees it (mouse rays can lag a frame behind the camera).
function MSV2.rebaseDrag()
	if (G.drag) then G.drag.needRebase = true end
end

---Re-anchors the drag at screen point (x, y) using the current camera
local function rebaseAt(drag, x, y)
	drag.needRebase = nil
	local ctx = MSV2.gizmoContext()
	if (not ctx) then return end
	drag.items = captureItems(ctx)
	drag.pivot0 = V.copy(ctx.pivot)
	drag.x0, drag.y0 = x, y
	drag.angle = 0
	drag.screenPivot = MSV2.frame and MSV2.frame.giz and MSV2.frame.giz.center or drag.screenPivot
	local ro, rd = MSV2.mouseRay(x, y)
	if (not ro) then return end
	if (drag.axis) then
		drag.t0 = lineRayParam(drag.pivot0, drag.axis, ro, rd)
	end
	if (drag.normal) then
		drag.hit0 = rayPlane(ro, rd, drag.pivot0, drag.normal)
		drag.lastVec = drag.hit0 and V.sub(drag.hit0, drag.pivot0) or nil
	end
end
MSV2.rebaseAt = rebaseAt

---Size of what's currently selected/targeted (for camera framing)
local function targetSize()
	local list = MSV2.selList()
	local size = 1
	for _, idx in ipairs(list) do
		local e = MSV2.objExtents(idx)
		size = math.max(size, e[1], e[2], e[3])
	end
	if (#list > 1) then
		local c = MSV2.selCenter()
		for _, idx in ipairs(list) do
			size = math.max(size, V.dist(c, MSV2.objPos(idx)) * 2)
		end
	end
	return size
end

function MSV2.focusSelection()
	local ctx = MSV2.gizmoContext()
	if (not ctx) then
		MSV2.cameraTo({ 0, 0, 1 }, nil, 6, nil, true)
		MSV2.toast("Nothing selected - centered on the players")
		return
	end
	local size = (ctx.kind == "env") and targetSize() or 1
	MSV2.cameraTo(ctx.pivot, nil, math.max(3, size * 1.8 + 1.5), nil, true)
end

---Tori's facing as the game draws him: forward and right along the floor.
---Falls back to world axes if the body can't be read.
function MSV2.toriAxes()
	local r, l = MSV2.bodyWorld(0, 5), MSV2.bodyWorld(0, 8)
	if (r and l) then
		local right = { r.pos[1] - l.pos[1], r.pos[2] - l.pos[2], 0 }
		if (V.len(right) > 1e-3) then
			right = V.norm(right)
			-- Facing +Y with the right side at +X gives forward = up x right
			local fwd = V.norm(V.cross({ 0, 0, 1 }, right))
			return fwd, right
		end
	end
	return { 0, 1, 0 }, { 1, 0, 0 }
end

---Camera views relative to Tori: front = looking at his face, side = from his right
function MSV2.viewFrom(which)
	local ctx = MSV2.gizmoContext()
	local target = ctx and ctx.pivot
	if (not target) then
		local c = MSV2.playerWorldCenter and MSV2.playerWorldCenter(0)
		target = c or { 0, 0, 1 }
	end
	local fwd, right = MSV2.toriAxes()
	local up = { 0, 0, 1 }
	local dirs = {
		-- Straight down, nudged back so Tori faces the top of the screen
		top = V.norm(V.add(up, V.mul(fwd, -0.02))),
		front = V.norm(V.add(fwd, V.mul(up, 0.15))),
		side = V.norm(V.add(right, V.mul(up, 0.15))),
		iso = V.norm(V.add(V.add(fwd, right), V.mul(up, 0.8)))
	}
	MSV2.cameraTo(target, dirs[which] or dirs.iso, math.max(6, ((ctx and ctx.kind == "env") and targetSize() or 1) * 2 + 3), nil, true)
end

---------------------------------------------------------------------------
-- Input hooks
---------------------------------------------------------------------------

local function interactive()
	return MSV2.active and not MSV2.testMode and not (MSV2.UI and MSV2.UI.modalOpen) and TB_MENU_MAIN_ISOPEN ~= 1
end

function MSV2.onMouseDown(btn, x, y)
	if (not interactive()) then return end
	local wheel = btn == 4 or btn == 5
	if (wheel) then
		-- A wheel event's x / y is the scroll amount, not the cursor position
		x, y = MOUSE_X or G.mouseX or x, MOUSE_Y or G.mouseY or y
	end
	-- Mid-drag the wheel always belongs to the drag, even over a panel
	if (not (wheel and G.drag) and MSV2.UI.isOverUI(x, y)) then
		-- Wheel over a panel scrolls it instead of zooming the camera
		if ((btn == 4 or btn == 5) and MSV2.UI.handleWheel and MSV2.UI.handleWheel(x, y, btn)) then return 1 end
		return
	end
	-- Clicking the world takes focus away from any text box so shortcuts work again
	MSV2.UI.blurFields()
	if (btn == 3) then
		if (G.drag) then
			MSV2.cancelDrag()
			return 1
		end
		return
	end
	if (btn == 4 or btn == 5) then
		if (G.drag) then
			local moving = ({ direct = true, free = true, plane = true, axis = true })[G.drag.handle.type]
			if (moving and not shiftDown() and MSV2.settings.scrollPush ~= false) then
				return MSV2.dragPush(btn)
			end
			return MSV2.dragZoom(btn)
		end
		return
	end
	if (btn ~= 1) then return end

	-- 0) Measure tool: click two points
	if (MSV2.settings.tool == "measure") then
		MSV2.measureClick(x, y)
		return 1
	end

	-- 0b) Dojo resize handle (Bodies > Place)
	local dh = MSV2.frame and MSV2.frame.dojoHandle
	if (dh and dh.ok and (x - dh[1]) ^ 2 + (y - dh[2]) ^ 2 < 140) then
		MSV2.pushUndo("Dojo size")
		G.dojoDrag = true
		pcall(disable_mouse_camera_movement)
		return 1
	end

	-- 1) Gizmo handles
	local h = MSV2.gizmoHit(x, y)
	if (h) then
		MSV2.beginDrag(h, x, y)
		return 1
	end

	-- 2) Triangle corner dots
	local tri, key = vertexHit(x, y)
	if (tri) then
		MSV2.vertexSel = { tri = tri, key = key }
		MSV2.UI.requestRefresh()
		local ctx = MSV2.gizmoContext()
		MSV2.beginDrag({ type = "direct", cameraPlane = true }, x, y, ctx)
		return 1
	end

	-- 3) Body parts / joints (own ray picking against the drawn bodies),
	--    unless an object is closer to the camera
	local idx, objDist = pickObj(x, y)
	objDist = objDist or math.huge
	if (tabOpen("players")) then
		local p, b, t = MSV2.pickBody(x, y)
		if (p ~= nil and t < objDist) then
			MSV2.UI.selectBody(p, b)
			return 1
		end
	end
	if (tabOpen("joints")) then
		local p, j, t = MSV2.pickJoint(x, y)
		if (p ~= nil and t < objDist) then
			MSV2.UI.selectJoint(p, j)
			return 1
		end
	end

	-- 4) Objects
	if (MSV2.UI.parentPick) then
		if (idx) then
			MSV2.UI.finishParentPick(idx)
		else
			MSV2.UI.parentPick = nil
			MSV2.toast("Parent pick cancelled")
		end
		return 1
	end
	if (tabOpen("links") and MSV2.UI.linkPick and idx) then
		MSV2.UI.finishLinkPick(idx)
		return 1
	end
	if (idx) then
		MSV2.vertexSel = nil
		if (shiftDown()) then
			MSV2.selToggle(idx)
			return 1
		end
		if (not MSV2.sel[idx]) then
			MSV2.selSet(idx)
		else
			MSV2.primary = idx
			MSV2.UI.requestRefresh()
		end
		if (MSV2.settings.tool ~= "rotate" and MSV2.settings.tool ~= "scale") then
			-- Click and drag an object to slide it along the ground (Alt: up/down)
			local ctx = MSV2.gizmoContext()
			if (ctx and ctx.kind == "env") then
				MSV2.beginDrag({ type = "direct", vertical = altDown() }, x, y, ctx)
			end
		end
		return 1
	end

	-- 5) Empty space: Shift+drag box-selects, plain click deselects
	if (shiftDown()) then
		G.marquee = { x0 = x, y0 = y, x1 = x, y1 = y, active = false }
		pcall(disable_mouse_camera_movement)
		return 1
	end
	if (MSV2.selCount() > 0 or MSV2.vertexSel) then
		MSV2.selClear()
	end
end

function MSV2.onMouseMove(x, y)
	G.prevMouseX, G.prevMouseY = G.mouseX or x, G.mouseY or y
	G.mouseX, G.mouseY = x, y
	if (not interactive()) then return end
	if (G.dojoDrag) then
		local ro, rd = MSV2.mouseRay(x, y)
		local hit = ro and rayPlane(ro, rd, { 0, 0, 0 }, { 0, 0, 1 })
		if (hit) then
			local c = MSV2.dojoCenter()
			local _, kind = MSV2.dojoShape()
			local r
			if (kind == 0) then
				-- Square: half-width is the bigger of the X/Y distances
				r = math.max(abs(hit[1] - c[1]), abs(hit[2] - c[2]))
			else
				r = V.dist({ hit[1], hit[2], 0 }, c)
			end
			MSV2.setDojoFromRadius(math.max(0.25, r))
			local _, _, size = MSV2.dojoShape()
			G.dojoReadout = "Dojo size " .. tostring(size or 0)
		end
		return
	end
	if (G.drag) then
		MSV2.updateDrag(x, y)
		return
	end
	local mq = G.marquee
	if (mq) then
		mq.x1, mq.y1 = x, y
		if (abs(x - mq.x0) + abs(y - mq.y0) > 6) then mq.active = true end
		return
	end
	if (MSV2.UI.isOverUI(x, y)) then
		G.hover, G.hoverObj, G.hoverVertex, G.hoverBody = nil, nil, nil, nil
		return
	end
	G.hover = MSV2.gizmoHit(x, y)
	local tri, key = vertexHit(x, y)
	G.hoverVertex = tri and { tri = tri, key = key } or nil
	local now = clock()
	if (not G.hover and not tri and now - (G.lastPick or 0) > 0.04) then
		G.lastPick = now
		local idx, dist = pickObj(x, y)
		G.hoverObj = idx
		G.hoverBody = nil
		if (tabOpen("players")) then
			local p, b, t = MSV2.pickBody(x, y)
			if (p ~= nil and t < (dist or math.huge)) then
				G.hoverBody = { p = p, b = b }
				G.hoverObj = nil
			end
		end
	elseif (G.hover or tri) then
		G.hoverObj, G.hoverBody = nil, nil
	end
end

function MSV2.onMouseUp(btn, x, y)
	if (not MSV2.active) then return end
	if (btn == 1 and MSV2.UI.endPointerDrag and MSV2.UI.endPointerDrag()) then return end
	if (btn ~= 1) then return end
	if (G.dojoDrag) then
		G.dojoDrag, G.dojoReadout = nil, nil
		pcall(enable_mouse_camera_movement)
		MSV2.toast("Dojo resized - press Restart match on the Rules tab to see the game's own dojo update")
		MSV2.UI.requestRefresh()
		return
	end
	if (G.drag) then
		MSV2.endDrag()
		return
	end
	local mq = G.marquee
	if (mq) then
		G.marquee = nil
		pcall(enable_mouse_camera_movement)
		if (mq.active and MSV2.frame) then
			local x1, x2 = math.min(mq.x0, mq.x1), math.max(mq.x0, mq.x1)
			local y1, y2 = math.min(mq.y0, mq.y1), math.max(mq.y0, mq.y1)
			local n = 0
			for idx, c in pairs(MSV2.frame.centers) do
				local m = MSV2.meta[idx]
				if (c[1] >= x1 and c[1] <= x2 and c[2] >= y1 and c[2] <= y2 and not (m and m.locked) and not (MSV2.isHidden and MSV2.isHidden(idx))) then
					MSV2.selAdd(idx)
					n = n + 1
				end
			end
			MSV2.toast(n > 0 and ("Box-selected " .. n .. " object" .. (n == 1 and "" or "s")) or "Nothing inside the box")
		end
	end
end

-- SDL2 keycodes with SDL1 fallbacks
local KEYS = {
	up = { [1073741906] = true, [273] = true },
	down = { [1073741905] = true, [274] = true },
	right = { [1073741903] = true, [275] = true },
	left = { [1073741904] = true, [276] = true },
	pgup = { [1073741899] = true, [280] = true },
	pgdn = { [1073741902] = true, [281] = true },
	del = { [127] = true, [1073741900] = true },
	f1 = { [1073741882] = true, [282] = true },
	f2 = { [1073741883] = true, [283] = true }
}

local consumed = {}

local function nudge(d)
	local ctx = MSV2.gizmoContext()
	if (not ctx) then return false end
	local step = MSV2.settings.gridStep > 0 and MSV2.settings.gridStep or 0.1
	if (shiftDown()) then step = step / 5 end
	MSV2.pushUndo("Nudge", "nudge")
	local drag = { ctx = ctx, items = captureItems(ctx), pivot0 = V.copy(ctx.pivot), A = M.identity(), worldFrame = true }
	applyOp(drag, { move = V.mul(d, step) })
	return true
end

function MSV2.onKeyDown(key)
	if (not interactive()) then return end
	if (MSV2.UI.fieldFocused()) then return end
	local okc, chat = pcall(chat_input_is_active)
	if (okc and chat) then return end

	local ctrl, shift = ctrlDown(), shiftDown()
	local handled = true
	local ch = (key >= 32 and key < 127) and string.char(key):lower() or nil

	if (ctrl and ch == "z") then
		if (shift) then MSV2.redo() else MSV2.undo() end
	elseif (ctrl and ch == "y") then
		MSV2.redo()
	elseif (ctrl and ch == "d") then
		MSV2.duplicateSelected()
	elseif (ctrl and shift and ch == "c") then
		MSV2.copyProps("all")
	elseif (ctrl and shift and ch == "v") then
		MSV2.pasteProps()
	elseif (ctrl and shift and ch == "h") then
		MSV2.showAll()
	elseif (ctrl and ch == "h") then
		MSV2.hideSelected()
	elseif (ctrl and ch == "i") then
		MSV2.isolateSelected()
	elseif (ctrl and ch == "c") then
		local clip = MSV2.copySelection()
		if (clip) then
			MSV2.clipboard = clip
			MSV2.toast("Copied " .. (#clip.objs + #clip.tris) .. " item(s) - Ctrl+V to paste")
		end
	elseif (ctrl and ch == "v") then
		if (MSV2.clipboard) then
			MSV2.pushUndo("Paste")
			local step = MSV2.settings.gridStep > 0 and MSV2.settings.gridStep or 0.25
			MSV2.pasteClip(MSV2.clipboard, { step * 2, step * 2, 0 })
			MSV2.toast("Pasted")
		else
			MSV2.toast("Clipboard is empty - copy something with Ctrl+C first")
		end
	elseif (ctrl and ch == "a") then
		MSV2.selAll()
		MSV2.toast("Selected all " .. MSV2.selCount() .. " objects")
	elseif (ctrl and ch == "s") then
		MSV2.saveProject(MSV2.saveName or "Untitled")
	elseif (ctrl and ch == "e") then
		MSV2.exportChecked(MSV2.saveName or "Untitled")
	elseif (ctrl) then
		handled = false
	elseif (ch == "1") then
		MSV2.UI.setTool("select")
	elseif (ch == "2") then
		MSV2.UI.setTool("move")
	elseif (ch == "3") then
		MSV2.UI.setTool("rotate")
	elseif (ch == "4") then
		MSV2.UI.setTool("scale")
	elseif (ch == "5") then
		MSV2.UI.setTool("measure")
	elseif (ch == "l") then
		MSV2.UI.toggleSpace()
	elseif (ch == "g") then
		MSV2.UI.toggleSnap()
	elseif (ch == "f") then
		MSV2.focusSelection()
	elseif (ch == "h" or KEYS.f1[key]) then
		MSV2.UI.toggleHelp()
	elseif (KEYS.f2[key]) then
		MSV2.UI.renameNodes()
	elseif (KEYS.del[key] or key == 8) then
		MSV2.deleteSelected()
	elseif (ch == "p") then
		if (shift) then MSV2.unparentSelection() else MSV2.parentSelection() end
	elseif (ch == "[") then
		MSV2.selectParent()
	elseif (ch == "]") then
		MSV2.selectChildren(shift)
	elseif (key == 27) then
		if (MSV2.UI.parentPick) then
			MSV2.UI.parentPick = nil
			MSV2.toast("Parent pick cancelled")
		elseif (G.drag) then
			MSV2.cancelDrag()
		elseif (MSV2.vertexSel) then
			MSV2.vertexSel = nil
			MSV2.UI.requestRefresh()
		elseif (MSV2.selCount() > 0) then
			MSV2.selClear()
		else
			handled = false
		end
	elseif (KEYS.left[key]) then
		handled = nudge({ -1, 0, 0 })
	elseif (KEYS.right[key]) then
		handled = nudge({ 1, 0, 0 })
	elseif (KEYS.up[key]) then
		handled = nudge({ 0, 1, 0 })
	elseif (KEYS.down[key]) then
		handled = nudge({ 0, -1, 0 })
	elseif (KEYS.pgup[key]) then
		handled = nudge({ 0, 0, 1 })
	elseif (KEYS.pgdn[key]) then
		handled = nudge({ 0, 0, -1 })
	else
		handled = false
	end
	if (handled) then
		consumed[key] = true
		return 1
	end
end

function MSV2.onKeyUp(key)
	if (consumed[key]) then
		consumed[key] = nil
		return 1
	end
end
