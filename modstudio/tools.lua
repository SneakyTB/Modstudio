

local MS = MS
local V, M = MS.V, MS.M
local abs, sqrt, floor = math.abs, math.sqrt, math.floor
local rad, deg, sin, cos = math.rad, math.deg, math.sin, math.cos

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

local function rayCapsuleN(ro, rd, pos, R, r, len)

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

		local hit = V.add(ro, V.mul(rd, best[1]))
		local s = MS.clamp(V.dot(V.sub(hit, p0), a), 0, len)
		return best[1], V.norm(V.sub(hit, V.add(p0, V.mul(a, s))))
	end
	return nil
end

function MS.raycastScene(ro, rd, exclude)
	exclude = exclude or {}
	local best
	for idx, o in pairs(MS.objs) do
		if (not exclude[idx] and o.visible ~= false) then
			local pos, R = MS.objPos(idx), MS.objRot(idx)
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

MS.measure = MS.measure or {}

function MS.surfacePoint(x, y)
	local ro, rd = MS.mouseRay(x, y)
	if (not ro) then return nil end
	local hit = MS.raycastScene(ro, rd, {})
	return hit and hit.pos, hit
end

function MS.measureClick(x, y)
	local p = MS.surfacePoint(x, y)
	if (not p) then
		MS.toast("Click on an object or the floor to measure")
		return
	end
	local step = MS.settings.gridStep
	if (MS.snapActive() and step > 0) then
		p = { MS.round(p[1], step), MS.round(p[2], step), MS.round(p[3], step) }
	end
	local m = MS.measure
	if (not m.a or m.b) then
		MS.measure = { a = p }
		MS.toast("Point A set - click a second point")
	else
		m.b = p
		local d = V.sub(m.b, m.a)
		MS.toast("Distance " .. MS.fmt(V.len(d)) .. "  (X " .. MS.fmt(d[1]) .. ", Y " .. MS.fmt(d[2]) .. ", Z " .. MS.fmt(d[3]) .. ")")
	end
end

function MS.selectionDistance()
	local tris, plain = MS.selSplit()
	if (#plain == 2 and next(tris) == nil) then
		return V.dist(MS.objPos(plain[1]), MS.objPos(plain[2]))
	end
	return nil
end

function MS.playerWorldCenter(p)
	local sum, n = { 0, 0, 0 }, 0
	for b = 0, MS.numBodies(p) - 1 do
		local w = MS.bodyWorld(p, b)
		if (w) then sum = V.add(sum, w.pos); n = n + 1 end
	end
	if (n == 0) then return nil end
	return V.mul(sum, 1 / n)
end

function MS.playerModCenter(p)
	local sum, n = { 0, 0, 0 }, 0
	for b = 0, MS.numBodies(p) - 1 do
		local o = MS.bodies[p] and MS.bodies[p][b]
		if (o) then sum = V.add(sum, { o.pos_x, o.pos_y, o.pos_z }); n = n + 1 end
	end
	if (n == 0) then return nil end
	return V.mul(sum, 1 / n)
end

function MS.dojoCenter()
	local a, b = MS.playerWorldCenter(0), MS.playerWorldCenter(1)
	if (a and b) then return { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, 0 } end
	if (a) then return { a[1], a[2], 0 } end
	return { 1, -0.1, 0 }
end

function MS.dojoShape()
	local size = tonumber(MS.getRule("dojosize") or "") or 0
	local kind = tonumber(MS.getRule("dojotype") or "") or 0
	if (size <= 0) then return nil end

	local r = kind == 1 and size / 100 or size / 200
	return r, kind, size
end

function MS.setDojoFromRadius(r)
	local _, kind = MS.dojoShape()
	kind = kind or (tonumber(MS.getRule("dojotype") or "") or 0)
	local size = kind == 1 and r * 100 or r * 200
	MS.setRule("dojosize", math.max(0, floor(size + 0.5)))
end

MS.arcGen = MS.arcGen or {
	kind = "arch", radius = 2, thick = 0.25, width = 2, segments = 12, span = 180,
	spiralSteps = 12, spiralRise = 0.25, spiralTurns = 1
}

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
		local idx = MS.createObj({
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
	MS.sel = {}
	for _, idx in ipairs(list) do MS.sel[idx] = true end
	MS.primary = list[1]
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

function MS.genArc(kind)
	local g = MS.arcGen
	kind = kind or g.kind
	local p = MS.spawnPoint()
	local c = MS.nextColor()
	local segs = math.max(2, floor(g.segments))
	local R, T, W = g.radius, g.thick, g.width
	MS.pushUndo("Build " .. kind)
	local list
	if (kind == "arch") then

		local base = { p[1], p[2], 0 }
		list = buildArc("Arch", segs, g.span, R, T, W, 0, function(th)
			local r = { cos(rad(th)), 0, sin(rad(th)) }
			local t = { -sin(rad(th)), 0, cos(rad(th)) }
			return base, r, t
		end, c, "Arch")
	elseif (kind == "quarterpipe") then

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
			local idx = MS.createObj({
				type = 1, dims_x = R, dims_y = stepW, dims_z = 0.1,
				pos_x = pos[1], pos_y = pos[2], pos_z = pos[3], rot_x = ex, rot_y = ey, rot_z = ez,
				color_r = c[1], color_g = c[2], color_b = c[3], static = true, mass = 1
			}, { name = "Spiral step " .. (i + 1), group = "Spiral stairs" })
			if (not idx) then break end
			table.insert(list, idx)
		end
		local pole = MS.createObj({
			type = 1, dims_x = 0.3, dims_y = 0.3, dims_z = g.spiralRise * steps,
			pos_x = p[1], pos_y = p[2], pos_z = g.spiralRise * steps / 2,
			color_r = 0.6, color_g = 0.6, color_b = 0.62, static = true, mass = 1
		}, { name = "Spiral pole", group = "Spiral stairs" })
		if (pole) then table.insert(list, pole) end
	end
	list = list or {}
	selectList(list)
	MS.toast("Built " .. #list .. " pieces")
	return list
end

MS.PREFAB_DIR = "modstudio/prefabs/"

function MS.selectionAsPrefab()
	local clip = MS.copySelection()
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
		grow({ f.pos_x, f.pos_y, f.pos_z }, MS.shapeExtents(f.type, f.dims_x, f.dims_y, f.dims_z))
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

function MS.savePrefab(name)
	name = MS.safeName(name)
	local clip = MS.selectionAsPrefab()
	if (not clip) then
		MS.toast("Select what you want to save as a prefab first")
		return false
	end
	clip.name = name
	if (MS.writeFile(MS.PREFAB_DIR .. name .. ".msf", "return " .. MS.serialize(clip))) then
		MS.toast("Saved prefab \"" .. name .. "\" - find it in the Library tab")
		return true
	end
	MS.toast("Couldn't save - is data/script/modstudio/prefabs/ missing?")
	return false
end

function MS.listPrefabs()
	local list = {}
	local ok, files = pcall(get_files, "data/script/modstudio/prefabs", "")
	if (ok and type(files) == "table") then
		for _, v in pairs(files) do
			if (type(v) == "string" and v:match("%.msf$")) then
				local name = v:gsub("%.msf$", "")

				if (MS.readData(MS.PREFAB_DIR .. name .. ".msf")) then table.insert(list, name) end
			end
		end
	end
	table.sort(list)
	return list
end

function MS.deletePrefabFile(name)
	MS.writeFile(MS.PREFAB_DIR .. name .. ".msf", "return nil")
	MS.toast("Deleted prefab \"" .. name .. "\"")
end

local function box(x, y, z, sx, sy, sz, col, extra)
	local f = { type = 1, pos_x = x, pos_y = y, pos_z = z, dims_x = sx, dims_y = sy, dims_z = sz, rot_x = 0, rot_y = 0, rot_z = 0,
		color_r = col[1], color_g = col[2], color_b = col[3], color_a = 1, static = true, visible = true, mass = 1 }
	for k, v in pairs(extra or {}) do f[k] = v end
	return { fields = f, meta = {} }
end

MS.BUILTIN_PREFABS = {
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

function MS.loadPrefab(name)
	for _, b in ipairs(MS.BUILTIN_PREFABS) do
		if (b.name == name) then return MS.deepcopy(b.clip) end
	end
	local data = MS.readData(MS.PREFAB_DIR .. name .. ".msf")
	if (data and data.objs) then return data end
	return nil
end

function MS.placePrefab(name, at)
	local clip = MS.loadPrefab(name)
	if (not clip) then
		MS.toast("Couldn't read prefab " .. tostring(name))
		return {}
	end
	MS.pushUndo("Place " .. name)
	local p = at or MS.spawnPoint()
	local list = MS.pasteClip(clip, { p[1], p[2], 0 })
	MS.toast("Placed " .. name .. " (" .. #list .. " objects)")
	return list
end

MS.SURFACE_PRESETS = {
	{ name = "Bounce pad", tip = "Launches whatever lands on it", fields = { bounce = 1, hardness = 0.2, friction = 0.6, static = true }, color = { 0.2, 0.85, 0.4 } },
	{ name = "Ice", tip = "Almost no grip", fields = { friction = 0.01, hardness = 0.5, bounce = 0, static = true }, color = { 0.75, 0.9, 1 } },
	{ name = "Sticky", tip = "Very grippy", fields = { friction = 3, hardness = 0.2, bounce = 0, static = true }, color = { 0.85, 0.6, 0.2 } },
	{ name = "Pushable", tip = "A loose physics block", fields = { static = false, mass = 0.6, friction = 0.5 }, color = { 0.6, 0.45, 0.3 } },
	{ name = "Ghost wall", tip = "Invisible but solid", fields = { visible = false, static = true, color_a = 0.3 }, color = nil }
}

MS.TRIGGER_PRESETS = {
	{ name = "Score pad +100", tip = "Gives points when a player touches it (once)", score = 100, once = true, color = { 0.2, 0.9, 0.3, 1 } },
	{ name = "Penalty zone -100", tip = "Takes points when a player touches it", score = -100, once = false, color = { 0.95, 0.2, 0.2, 1 } },
	{ name = "Color flash", tip = "Changes color when a player touches it", score = 0, once = false, color = { 1, 0.9, 0.2, 1 } }
}

function MS.applySurfacePreset(i)
	local pr = MS.SURFACE_PRESETS[i]
	local list = MS.selList()
	if (#list == 0) then
		MS.toast("Select the objects to turn into a " .. pr.name)
		return
	end
	MS.pushUndo(pr.name)
	for _, idx in ipairs(list) do
		for f, v in pairs(pr.fields) do MS.objSet(idx, f, v) end
		if (pr.color) then
			MS.objSet(idx, "color_r", pr.color[1])
			MS.objSet(idx, "color_g", pr.color[2])
			MS.objSet(idx, "color_b", pr.color[3])
		end
	end
	MS.toast(pr.name .. " applied to " .. #list .. " object" .. (#list == 1 and "" or "s"))
end

function MS.ensurePlayerTriggerGroups()
	local changed = 0
	for p = 0, math.max(1, MS.numPlayers) - 1 do
		local bit = p == 0 and 1 or (p == 1 and 2 or 0)
		if (bit > 0) then
			for b = 0, MS.numBodies(p) - 1 do
				local o = MS.bodies[p] and MS.bodies[p][b]
				if (o and (o.trig_id or 0) == 0) then
					MS.bodySet(p, b, "trig_id", bit)
					changed = changed + 1
				end
			end
		end
	end
	return changed
end

function MS.applyTriggerPreset(i)
	local pr = MS.TRIGGER_PRESETS[i]
	local list = MS.selList()
	if (#list == 0) then
		MS.toast("Select the objects to turn into a " .. pr.name)
		return
	end
	MS.pushUndo(pr.name)
	local groups = MS.ensurePlayerTriggerGroups()
	for _, idx in ipairs(list) do
		MS.objSet(idx, "trig_mask", 3)
		MS.objSet(idx, "trig_score", pr.score)
		MS.objSet(idx, "trig_scoreonce", pr.once)
		MS.objSet(idx, "trig_color_r", pr.color[1])
		MS.objSet(idx, "trig_color_g", pr.color[2])
		MS.objSet(idx, "trig_color_b", pr.color[3])
		MS.objSet(idx, "trig_color_a", pr.color[4])
	end
	MS.toast(pr.name .. " set up" .. (groups > 0 and " (players were given trigger groups)" or "") .. " - try it with Test")
end

MS.moverGen = MS.moverGen or { size = 1, speed = 4, strength = 800 }

local FREE = 10

local function hinge(a, b, pos, axis, o)
	if (not a or not b) then return nil end
	o = o or {}
	local ok, n = pcall(create_mod_envjoint, a, b)
	if (not ok or n == nil) then return nil end
	MS.readEJ(n)
	MS.ejSet(n, "pos_x", pos[1]); MS.ejSet(n, "pos_y", pos[2]); MS.ejSet(n, "pos_z", pos[3])
	MS.ejSet(n, "axis_x", axis[1]); MS.ejSet(n, "axis_y", axis[2]); MS.ejSet(n, "axis_z", axis[3])
	MS.ejSet(n, "histop", o.hi or FREE)
	MS.ejSet(n, "lostop", o.lo or -FREE)
	MS.ejSet(n, "maxforce", o.force or 0)
	MS.ejSet(n, "maxvelocity", o.speed or 0)
	MS.ejSet(n, "visible", o.visible == true)
	return n
end

local function piece(f, name, group)
	f.type = f.type or 1
	f.rot_x, f.rot_y, f.rot_z = f.rot_x or 0, f.rot_y or 0, f.rot_z or 0
	if (f.static == nil) then f.static = false end
	f.mass = f.mass or 1
	return MS.createObj(f, { name = name, group = group })
end

local function col(c, f) f.color_r, f.color_g, f.color_b = c[1], c[2], c[3]; return f end

local METAL, DARK, WOOD, RED = { 0.7, 0.72, 0.75 }, { 0.3, 0.3, 0.33 }, { 0.6, 0.42, 0.25 }, { 0.85, 0.2, 0.2 }

MS.MOVERS = {
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

function MS.genMover(id)
	local def
	for _, m in ipairs(MS.MOVERS) do if (m.id == id) then def = m end end
	if (not def) then return {} end
	local g = MS.moverGen
	local list = {}
	MS.withUndo("Build " .. def.name, function()
		local p = MS.spawnPoint()
		for _, idx in ipairs(def.build(p, math.max(0.2, g.size), g)) do
			if (idx) then table.insert(list, idx) end
		end
	end)
	MS.sel = {}
	for _, idx in ipairs(list) do MS.sel[idx] = true end
	MS.primary = list[1]
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
	MS.toast("Built a " .. def.name .. " - press Test to watch it move")
	return list
end

local function floorTile(c, sx, sy, color, name, z)
	return MS.createObj({ type = 1, pos_x = c[1], pos_y = c[2], pos_z = (z or 0) + 0.05, dims_x = sx, dims_y = sy, dims_z = 0.1,
		color_r = color[1], color_g = color[2], color_b = color[3], static = true, mass = 1, friction = 0.6 }, { name = name, group = "Floor" })
end

MS.TEMPLATES = {
	{ id = "sumo", name = "Sumo ring", desc = "Round ring - push your opponent out. Leaving the ring loses instantly.",
		rules = { matchframes = 500, turnframes = "30", dojotype = 1, dojosize = 300, dqflag = 1, dqtimeout = 0, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 1,
		build = function(c)
			floorTile(c, 7, 7, { 0.82, 0.72, 0.52 }, "Ring floor")
			MS.spawnOverride = { c[1], c[2], 0 }
			local g = MS.arcGen
			local old = { g.radius, g.thick, g.width, g.segments, g.span }
			g.radius, g.thick, g.width, g.segments, g.span = 3, 0.2, 0.15, 32, 360
			MS.genArc("curvedwall")
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
			local g = MS.gen
			local old = g.arenaSize
			g.arenaSize = 10
			MS.genArena()
			g.arenaSize = old
		end },
	{ id = "parkour", name = "Parkour course", desc = "A line of platforms with gaps, a ramp and a goal. Long match, no DQ.",
		rules = { matchframes = 2000, turnframes = "20", dojosize = 0, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 0,
		build = function(c)
			local fwd = MS.toriAxes and MS.toriAxes() or { 0, 1, 0 }
			local function along(d, h, sx, sy, color, name)
				local p = { c[1] + fwd[1] * d, c[2] + fwd[2] * d }
				return MS.createObj({ type = 1, pos_x = p[1], pos_y = p[2], pos_z = h - 0.1, dims_x = sx, dims_y = sy, dims_z = 0.2,
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
				MS.createObj({ type = 1, pos_x = c[1] + o[1], pos_y = c[2] + o[2], pos_z = o[3], dims_x = 1.6, dims_y = 1.6, dims_z = 0.2,
					color_r = plat[1], color_g = plat[2], color_b = plat[3], static = true, mass = 1 }, { name = "Floating platform " .. i, group = "Platforms" })
			end
		end },
	{ id = "obstacles", name = "Obstacle course", desc = "Spinning blades, a swinging hammer and a see-saw between you and the goal.",
		rules = { matchframes = 1500, turnframes = "20", dojosize = 0, engagedistance = 80, gravity = "0 0 -9.82" },
		flags = 0,
		build = function(c)
			local fwd = MS.toriAxes and MS.toriAxes() or { 0, 1, 0 }
			local function p(d) return { c[1] + fwd[1] * d, c[2] + fwd[2] * d, 0 } end
			MS.createObj({ type = 1, pos_x = p(9)[1], pos_y = p(9)[2], pos_z = -0.05, dims_x = 6, dims_y = 6, dims_z = 0.1,
				rot_z = math.deg(math.atan2(fwd[2], fwd[1])) - 90, color_r = 0.55, color_g = 0.55, color_b = 0.6, static = true, mass = 1 }, { name = "Course floor", group = "Course" })
			local g = MS.moverGen
			local oldSize = g.size
			g.size = 1
			for _, item in ipairs({ { "spinner", 4 }, { "hammer", 8 }, { "seesaw", 12 }, { "spinner", 16 } }) do
				local def
				for _, m in ipairs(MS.MOVERS) do if (m.id == item[1]) then def = m end end
				def.build(p(item[2]), 1, g)
			end
			g.size = oldSize
			floorTile(p(19), 2.5, 2.5, { 0.2, 0.85, 0.35 }, "Goal")
		end }
}

local function buildShowcase(c)
	local fwd, right = { 0, 1, 0 }, { 1, 0, 0 }
	if (MS.toriAxes) then fwd, right = MS.toriAxes() end
	local function P(df, dr, z)
		return { c[1] + fwd[1] * df + right[1] * dr, c[2] + fwd[2] * df + right[2] * dr, z or 0 }
	end
	local function spawnAt(df, dr) MS.spawnOverride = P(df, dr) end
	local function name(list, group)
		for _, idx in ipairs(list or {}) do
			MS.meta[idx] = MS.meta[idx] or {}
			MS.meta[idx].group = group
		end
	end

	local g = MS.arcGen
	local saved = MS.deepcopy(g)
	g.radius, g.thick, g.width, g.segments, g.span = 1.6, 0.2, 1.6, 10, 180
	spawnAt(7, 0)
	name(MS.genArc("arch"), "Showcase: curves")
	local scorePad = MS.createObj({ type = 1, pos_x = P(10, 0)[1], pos_y = P(10, 0)[2], pos_z = 0.05, dims_x = 1.5, dims_y = 1.5, dims_z = 0.1,
		color_r = 0.2, color_g = 0.9, color_b = 0.3, static = true, mass = 1 }, { name = "Score pad (+100)", group = "Showcase: triggers" })
	if (scorePad) then
		MS.sel = { [scorePad] = true }
		MS.applyTriggerPreset(1)
	end

	local gen = MS.gen
	local oldSteps, oldRise, oldRun, oldW = gen.stairsSteps, gen.stairsRise, gen.stairsRun, gen.stairsWidth
	gen.stairsSteps, gen.stairsRise, gen.stairsRun, gen.stairsWidth = 5, 0.3, 0.4, 1.6
	spawnAt(7, 6)
	name(MS.genStairs and (function() MS.genStairs(); return MS.selList() end)(), "Showcase: generators")
	gen.stairsSteps, gen.stairsRise, gen.stairsRun, gen.stairsWidth = oldSteps, oldRise, oldRun, oldW
	name(MS.placePrefab("Bridge", P(11, 6)), "Showcase: prefabs")

	local rp = P(0, 7)
	MS.triCreate({ rp[1] - 1.5, rp[2], 0 }, { rp[1] + 1.5, rp[2], 0 }, { rp[1] + 1.5, rp[2], 1.2 },
		{ thick = 2, slices = 10, smooth = "ca", name = "Ramp (triangle)" })
	local fp = P(-3.5, 7)
	MS.triCreate({ fp[1] - 0.9, fp[2], 0 }, { fp[1] + 0.9, fp[2], 0 }, { fp[1], fp[2], 1.5 },
		{ thick = 0.2, slices = 8, name = "Upright triangle" })
	local ice = MS.createObj({ type = 1, pos_x = P(3.5, 7)[1], pos_y = P(3.5, 7)[2], pos_z = 0.05, dims_x = 2.5, dims_y = 2.5, dims_z = 0.1,
		color_r = 0.75, color_g = 0.9, color_b = 1, static = true, mass = 1 }, { name = "Ice patch", group = "Showcase: surfaces" })
	if (ice) then MS.sel = { [ice] = true }; MS.applySurfacePreset(2) end
	local oldLevels = gen.pyramidLevels
	gen.pyramidLevels = 3
	spawnAt(-7, 6)
	MS.genPyramid()
	name(MS.selList(), "Showcase: physics")
	gen.pyramidLevels = oldLevels

	local mg = MS.moverGen
	local oldSize = mg.size
	mg.size = 1
	for _, item in ipairs({ { "spinner", 3, -7 }, { "seesaw", -1, -7 }, { "door", -4.5, -7 }, { "wreckingball", 7, -6 } }) do
		for _, m in ipairs(MS.MOVERS) do
			if (m.id == item[1]) then
				local list = m.build(P(item[2], item[3]), 1, mg)
				name(list, "Showcase: moving")
			end
		end
	end
	mg.size = oldSize
	name(MS.placePrefab("Bounce pad", P(4, -3.5)), "Showcase: surfaces")

	g.spiralSteps, g.spiralTurns, g.spiralRise, g.radius = 10, 1, 0.25, 1.4
	spawnAt(-8, 0)
	name(MS.genArc("spiral"), "Showcase: curves")
	name(MS.placePrefab("Doorway", P(-4, -2.5)), "Showcase: prefabs")

	for k, v in pairs(saved) do g[k] = v end
	MS.spawnOverride = nil
	pcall(set_mod_message, "Mod Studio showcase - curves, triangles, moving obstacles, prefabs and presets")
end

table.insert(MS.TEMPLATES, 1, {
	id = "showcase", name = "Feature showcase",
	desc = "One of everything: curves, triangles, moving obstacles, prefabs, presets and triggers.",
	rules = { matchframes = 1500, turnframes = "20", dojosize = 0, engagedistance = 80, gravity = "0 0 -9.82",
		dismemberthreshold = 150, fracturethreshold = 150 },
	flags = 10,
	build = buildShowcase
})

function MS.applyTemplate(id)
	local t
	for _, tt in ipairs(MS.TEMPLATES) do if (tt.id == id) then t = tt end end
	if (not t) then return false end

	MS.pushUndo("Template: " .. t.name)
	local was = MS.undoSuppress
	MS.undoSuppress = true
	local started = MS.resetTo("all", function(reset)
		local ok, err = reset, "couldn't reset the mod first"
		if (reset) then
			ok, err = pcall(function()
				for k, v in pairs(t.rules) do MS.setRule(k, v) end
				if (t.flags) then MS.setFlags(t.flags) end
				local c = MS.dojoCenter()
				MS.spawnOverride = { c[1], c[2], 0 }
				t.build(c)
			end)
		end
		MS.undoSuppress = was
		MS.spawnOverride = nil
		MS.selClear()
		MS.markDirty()
		if (ok) then
			MS.saveName = t.name
			MS.toast("Started a new \"" .. t.name .. "\" mod - Restart match (Rules tab) to see the new rules, Ctrl+Z to undo")
		else
			echo("Mod Studio error: " .. tostring(err))
		end
		if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
	end)
	if (not started) then MS.undoSuppress = was end
	return started
end

local MERGE_EPS = 0.002

local MERGE_SKIP = { pos_x = true, pos_y = true, pos_z = true, dims_x = true, dims_y = true, dims_z = true, mass = true }

local function mergeBlocker(idx, H, linked)
	local o, m = MS.objs[idx], MS.meta[idx]
	if (o.type ~= 1) then return "shape" end
	if (m and m.tri) then return "triangle" end
	if (not o.static) then return "physics" end
	if (linked[idx]) then return "link" end
	if (MS.isHidden and MS.isHidden(idx)) then return "hidden" end
	if ((o.trig_mask or 0) ~= 0 or (o.trig_action or 0) ~= 0 or (o.trig_id or 0) ~= 0) then return "trigger" end
	local key = "o" .. idx
	if (H.parent[key] or H.children[key]) then return "parent" end
	return nil
end

local function mergeSignature(o)
	local parts = {}
	for _, f in ipairs(MS.ENV_FIELDS) do
		if (not MERGE_SKIP[f]) then
			local v = o[f]
			if (type(v) == "number") then v = string.format("%.3f", v) end
			table.insert(parts, f .. "=" .. tostring(v))
		end
	end
	return table.concat(parts, ";")
end

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
	if (not along) then along = 1 end
	local u = M.col(R, along)
	local c = V.dot(d, u)

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

function MS.planObjectSaver(triTarget)
	local H = MS.hier()
	local linked = {}
	for _, ej in pairs(MS.ejs) do
		if (ej.obj1) then linked[ej.obj1] = true end
		if (ej.obj2) then linked[ej.obj2] = true end
	end
	local buckets, skipped = {}, {}
	for _, idx in ipairs(MS.sortedKeys(MS.objs)) do
		local why = mergeBlocker(idx, H, linked)
		if (why) then
			skipped[why] = (skipped[why] or 0) + 1
		else
			local o = MS.objs[idx]
			local sig = mergeSignature(o)
			buckets[sig] = buckets[sig] or {}
			table.insert(buckets[sig], { idx = idx, pos = MS.objPos(idx), dims = { o.dims_x or 0, o.dims_y or 0, o.dims_z or 0 }, absorbed = {} })
		end
	end
	local merges = {}
	local removed = 0
	for _, list in pairs(buckets) do
		if (#list > 1) then
			local R = MS.objRot(list[1].idx)

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
		for id, t in pairs(MS.tris) do
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

function MS.applyObjectSaver(plan)
	if (not plan or plan.total == 0) then
		MS.toast("Nothing to save - every box is already as big as it can be")
		return 0
	end
	local before = MS.count(MS.objs)
	MS.withUndo("Object saver", function()
		for _, m in ipairs(plan.merges) do
			if (MS.objs[m.keep]) then
				MS.objSet(m.keep, "pos_x", m.pos[1])
				MS.objSet(m.keep, "pos_y", m.pos[2])
				MS.objSet(m.keep, "pos_z", m.pos[3])
				MS.objSet(m.keep, "dims_x", m.dims[1])
				MS.objSet(m.keep, "dims_y", m.dims[2])
				MS.objSet(m.keep, "dims_z", m.dims[3])
				for _, idx in ipairs(m.remove) do
					if (MS.objs[idx]) then MS.deleteObjRaw(idx) end
				end
			end
		end
		for _, id in ipairs(plan.tris) do
			local t = MS.tris[id]
			if (t and plan.triTarget and (t.slices or 0) > plan.triTarget) then
				t.slices = plan.triTarget
				MS.triBuild(id)
			end
		end
		if (MS.hierFix) then MS.hierFix() end
	end)
	MS.selClear()
	local saved = before - MS.count(MS.objs)
	MS.toast("Object saver freed " .. saved .. " object" .. (saved == 1 and "" or "s") .. " (Ctrl+Z undoes)")
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
	return saved
end

local FAR = 60

local function insideObj(idx, p, pad)
	local o = MS.objs[idx]
	local rel = V.sub(p, MS.objPos(idx))
	local e = MS.objExtents(idx)
	if (o.type == 0) then return V.len(rel) <= e[1] / 2 + pad end
	local R = MS.objRot(idx)
	for k = 1, 3 do
		if (abs(V.dot(rel, M.col(R, k))) > e[k] / 2 + pad) then return false end
	end
	return true
end

function MS.checkMod()
	local issues = {}
	local function add(sev, text, objs)
		if (#objs > 0) then table.insert(issues, { severity = sev, text = text, objs = objs }) end
	end
	local all = MS.sortedKeys(MS.objs)

	local bodies = {}
	if (MS.bodyWorld) then
		for p = 0, math.max(1, MS.numPlayers or 2) - 1 do
			for b = 0, MS.numBodies(p) - 1 do
				local ok, w = pcall(MS.bodyWorld, p, b)
				if (ok and w and w.pos) then table.insert(bodies, w.pos) end
			end
		end
	end
	local inPlayer = {}
	for _, idx in ipairs(all) do
		local o = MS.objs[idx]
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

	local under, far = {}, {}
	for _, idx in ipairs(all) do
		local p = MS.objPos(idx)
		local top = 2 * p[3] - MS.objBottom(idx)
		if (top < -0.01) then table.insert(under, idx) end
		if (math.sqrt(p[1] * p[1] + p[2] * p[2]) > FAR or abs(p[3]) > FAR) then table.insert(far, idx) end
	end
	add("warn", "completely under the floor - nobody will ever see or touch them", under)
	add("warn", "more than " .. FAR .. " away from the middle of the arena", far)

	local seen, twins = {}, {}
	for _, idx in ipairs(all) do
		local o = MS.objs[idx]
		local key = string.format("%d|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f", o.type or 1, o.pos_x or 0, o.pos_y or 0, o.pos_z or 0,
			o.rot_x or 0, o.rot_y or 0, o.rot_z or 0, o.dims_x or 0, o.dims_y or 0, o.dims_z or 0)
		if (seen[key]) then table.insert(twins, idx) else seen[key] = idx end
	end
	add("warn", "exact copies sitting on top of another object (the extra copies are selected)", twins)

	local tiny, clear, invisible = {}, {}, {}
	for _, idx in ipairs(all) do
		local o, e = MS.objs[idx], MS.objExtents(idx)
		if (math.max(e[1], e[2], e[3]) < 0.02) then table.insert(tiny, idx) end
		if (o.visible ~= false and (o.color_a or 1) < 0.02) then table.insert(clear, idx) end
		if (o.visible == false) then table.insert(invisible, idx) end
	end
	add("warn", "so small you can hardly see them", tiny)
	add("info", "fully see-through (colour alpha 0) but still solid", clear)
	add("info", "invisible (still solid - fine for invisible walls)", invisible)

	if (MS.assetIssues) then
		for _, it in ipairs(MS.assetIssues(false)) do table.insert(issues, it) end
	end

	local limit = MS.settings.objLimit or 0
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

function MS.selectIssue(issue)
	if (not issue or #issue.objs == 0) then return end
	MS.selClear()
	for _, idx in ipairs(issue.objs) do
		if (MS.objs[idx]) then MS.selAdd(idx) end
	end
	if (MS.focusSelection) then MS.focusSelection() end
	MS.toast("Selected " .. #issue.objs .. " object" .. (#issue.objs == 1 and "" or "s"))
end

function MS.exportChecked(name)
	if (MS.assetReport) then pcall(MS.assetReport, true) end
	local warns, firstWarn = 0, nil
	for _, it in ipairs(MS.checkMod()) do
		if (it.severity == "warn") then
			warns = warns + 1
			firstWarn = firstWarn or it
		end
	end
	if (warns == 0 or not (MS.UI and MS.UI.confirm)) then
		return MS.exportMod(name)
	end
	MS.UI.confirm("Export with " .. warns .. " warning" .. (warns == 1 and "" or "s") .. "?",
		"The mod check found things that are probably mistakes. Have a look, or export anyway.", {
			{ "Show me", function()
				MS.UI.selectTab("stats")

				MS.selectIssue(firstWarn)
			end },
			{ "Export anyway", function() MS.exportMod(name) end },
			{ "Cancel" }
		})
end

MS.WELD_TOUCH = 0.03

local function weldBox(idx)
	local o = MS.objs[idx]
	local e = MS.objExtents(idx)
	return { c = MS.objPos(idx), R = MS.objRot(idx), h = { e[1] / 2, e[2] / 2, e[3] / 2 },
		vol = math.max(1e-6, e[1] * e[2] * e[3]), sphere = o.type == 0 }
end

local function boxAxes(b) return { M.col(b.R, 1), M.col(b.R, 2), M.col(b.R, 3) } end

local function projRadius(b, ax, L)
	return b.h[1] * abs(V.dot(ax[1], L)) + b.h[2] * abs(V.dot(ax[2], L)) + b.h[3] * abs(V.dot(ax[3], L))
end

local function boxOverlap(a, b)
	local A, B = boxAxes(a), boxAxes(b)
	local d = V.sub(b.c, a.c)
	local tests = { A[1], A[2], A[3], B[1], B[2], B[3] }
	for i = 1, 3 do
		for j = 1, 3 do
			local c = V.cross(A[i], B[j])
			if (V.len(c) > 1e-6) then tests[#tests + 1] = V.norm(c) end
		end
	end
	local best, bestAxis = math.huge, nil
	for _, L in ipairs(tests) do
		local dist = V.dot(d, L)
		local over = projRadius(a, A, L) + projRadius(b, B, L) - abs(dist)
		if (over < best) then
			best = over
			bestAxis = dist >= 0 and L or V.mul(L, -1)
		end
	end
	return best, bestAxis
end

local function closestOnBox(b, p)
	local ax = boxAxes(b)
	local d = V.sub(p, b.c)
	local q = V.copy(b.c)
	for k = 1, 3 do
		local t = MS.clamp(V.dot(d, ax[k]), -b.h[k], b.h[k])
		q = V.add(q, V.mul(ax[k], t))
	end
	return q
end

local function contactPoint(a, b)
	local pa = closestOnBox(a, b.c)
	local pb = closestOnBox(b, pa)
	pa = closestOnBox(a, pb)
	return V.lerp(pa, pb, 0.5)
end

-- "a:b" -> link index, both ways round.
local function linkedPairs()
	local set = {}
	for j, ej in pairs(MS.ejs) do
		if (ej.obj1 and ej.obj2) then
			set[ej.obj1 .. ":" .. ej.obj2] = j
			set[ej.obj2 .. ":" .. ej.obj1] = j
		end
	end
	return set
end

-- A weld is one hidden link with range 0..0 and no motor, the same as the
-- game's own rigid multi-part swords. Links in Toribash are soft, though: they
-- give way in proportion to the weight they hold. Tested in game with arms of
-- three blocks sticking out of a post: mass 1, 0.1 and 0.01 all sagged; 0.001
-- and 0.0001 stayed perfectly still. A second crossed hinge, a brake motor and
-- link hardness didn't help (the motor made it worse or exploded). So welding
-- also makes the welded pieces light, and unwelding gives them their weight back.
--
--
-- In-game test (three light blocks curling up from a post, 20 degrees per
-- joint): a 0..0 range with the axis along the bend kept the built curl.
-- Ranges pinned to the built angle, or narrow ranges around it, did worse. So a
-- weld is range 0..0 with its axis along the turn between the two pieces.
MS.WELD = { range = 0.001, mass = 0.001 }

-- The turn that takes piece a's orientation to piece b's, as a world axis (and
-- the range to use, always 0: the game holds the built angle at 0).
local function weldPose(a, b)
	local R1, R2 = MS.objRot(a), MS.objRot(b)
	local Rr = M.mul(M.transpose(R1), R2)
	local c = math.max(-1, math.min(1, (Rr[1][1] + Rr[2][2] + Rr[3][3] - 1) / 2))
	local ang = math.acos(c)
	if (ang < 1e-4) then return { 1, 0, 0 }, 0 end
	local u
	if (math.pi - ang < 1e-3) then
		-- Half turn: the axis is the column of (Rr + I) with the biggest size.
		local best = 0
		for k = 1, 3 do
			local col = { Rr[1][k], Rr[2][k], Rr[3][k] }
			col[k] = col[k] + 1
			if (V.len(col) > best) then best, u = V.len(col), col end
		end
	else
		u = { Rr[3][2] - Rr[2][3], Rr[1][3] - Rr[3][1], Rr[2][1] - Rr[1][2] }
	end
	u = V.norm(u)
	return V.norm(M.apply(R1, u)), 0
end

local function weldOpts(stop)
	return { hi = stop, lo = stop, force = 0, speed = 0, visible = false }
end

-- Pieces made light during the current weld action, for the message.
local lightened = 0

local function lighten(idx)
	local o = MS.objs[idx]
	if (not o) then return end
	local m = tonumber(o.mass) or 1
	if (m <= MS.WELD.mass * 1.01) then return end
	MS.meta[idx] = MS.meta[idx] or {}
	if (MS.meta[idx].preWeldMass == nil) then MS.meta[idx].preWeldMass = m end
	MS.objSet(idx, "mass", MS.WELD.mass)
	lightened = lightened + 1
end

local function lightMsg()
	if (lightened == 0) then return "" end
	return " Made " .. lightened .. " piece" .. (lightened == 1 and "" or "s") ..
		" light (mass " .. MS.WELD.mass .. ") so the welds hold - Unweld gives the weight back."
end

-- Creates a weld. Returns the link index, or nil.
local function weldLink(a, b, pos)
	local axis, stop = weldPose(a, b)
	local n = hinge(a, b, pos, axis, weldOpts(stop))
	if (n) then lighten(a); lighten(b) end
	return n
end

-- Is this hidden link part of one of Mod Studio's welds (any version)?
-- A weld is a hidden link whose range is pinned to one angle (older versions
-- used 0..0 or a tiny +-0.001 range).
local function isWeld(ej)
	if (not ej or ej.visible) then return false end
	return math.abs((ej.histop or 0) - (ej.lostop or 0)) <= MS.WELD.range * 2.5
end

-- After links are removed: pieces with no weld left get their weight back.
local function restoreWeights(objs)
	local welded = {}
	for _, ej in pairs(MS.ejs) do
		if (isWeld(ej)) then
			if (ej.obj1) then welded[ej.obj1] = true end
			if (ej.obj2) then welded[ej.obj2] = true end
		end
	end
	local n = 0
	for idx in pairs(objs) do
		local m = MS.meta[idx]
		if (MS.objs[idx] and m and m.preWeldMass ~= nil and not welded[idx]) then
			MS.objSet(idx, "mass", m.preWeldMass)
			m.preWeldMass = nil
			n = n + 1
		end
	end
	return n
end

local function weldLinksBetween(a, b)
	local out = {}
	for j, ej in pairs(MS.ejs) do
		if (((ej.obj1 == a and ej.obj2 == b) or (ej.obj1 == b and ej.obj2 == a)) and isWeld(ej)) then
			out[#out + 1] = j
		end
	end
	table.sort(out)
	return out
end

-- Brings an existing weld between a and b (made by any earlier version) up to
-- the current kind: one link held at the built angle, no motor, light pieces.
local function stiffenPair(a, b)
	local links = weldLinksBetween(a, b)
	if (#links == 0) then return false end
	local changed = false
	for i, j in ipairs(links) do
		local ej = MS.ejs[j]
		if (i > 1) then
			-- Earlier versions made two crossed hinges; one is enough.
			pcall(delete_mod_envjoint, j)
			MS.ejs[j] = nil
			if (MS.ejSel == j) then MS.ejSel = nil end
			changed = true
		else
			-- Point the axis along the pieces' built turn and pin the range there.
			local axis, stop = weldPose(ej.obj1, ej.obj2)
			local function off(x, y) return math.abs((x or 0) - y) > 1e-4 end
			if (off(ej.histop, stop) or off(ej.lostop, stop) or off(ej.axis_x, axis[1]) or off(ej.axis_y, axis[2])
				or off(ej.axis_z, axis[3]) or (ej.maxforce or 0) ~= 0 or (ej.maxvelocity or 0) ~= 0) then
				MS.ejSet(j, "axis_x", axis[1]); MS.ejSet(j, "axis_y", axis[2]); MS.ejSet(j, "axis_z", axis[3])
				MS.ejSet(j, "histop", stop)
				MS.ejSet(j, "lostop", stop)
				MS.ejSet(j, "maxforce", 0)
				MS.ejSet(j, "maxvelocity", 0)
				changed = true
			end
		end
	end
	local before = lightened
	lighten(a); lighten(b)
	return changed or lightened > before
end

local function isTriSlice(idx)
	local m = MS.meta[idx]
	return m and m.tri and MS.tris[m.tri] and true or false
end

-- ---------------------------------------------------------------------------
-- Trimming welded pieces so they don't overlap. Pieces that overlap push
-- against each other in game even when welded, so the build shakes and bends.
-- Before welding, one piece of each overlapping pair is made shorter from the
-- overlapping end only (its far end stays put), by the smallest cut that leaves
-- a hair-thin gap. Moving pieces instead broke curved builds like arches.
-- ---------------------------------------------------------------------------
MS.WELD_GAP = 0.001
MS.WELD_MIN_KEEP = 0.2 -- never cut a piece below 20% of its size

-- How far b sinks into a (> 0 = overlapping) and the direction from a to b.
local function penetration(a, b)
	if (a.sphere and b.sphere) then
		local d = V.sub(b.c, a.c)
		local len = V.len(d)
		local axis = len > 1e-9 and V.mul(d, 1 / len) or { 0, 0, 1 }
		return a.h[1] + b.h[1] - len, axis
	end
	if (a.sphere ~= b.sphere) then
		local box, ball, flip = a, b, 1
		if (a.sphere) then box, ball, flip = b, a, -1 end
		local q = closestOnBox(box, ball.c)
		local n = V.sub(ball.c, q)
		local len = V.len(n)
		if (len > 1e-6) then

			return ball.h[1] - len, V.mul(n, flip / len)
		end
	end
	return boxOverlap(a, b)
end

local function nodeVolume(key)
	local v = 0
	for _, idx in ipairs(MS.nodeObjs(key)) do v = v + weldBox(idx).vol end
	return v
end

-- The smallest trim of object idx that clears `other`. Returns the cut size and
-- a function that applies it, or nil when no trim within the limit works.
local DIM_FIELDS = { "dims_x", "dims_y", "dims_z" }
local function trimPlan(idx, other)
	local o = MS.objs[idx]
	if (not o) then return nil end
	local b = weldBox(idx)
	local need, keep = MS.WELD_GAP, MS.WELD_MIN_KEEP
	if (o.type == 0) then
		-- Sphere: only the radius can change.
		local r = o.dims_x or 0
		local s = penetration(b, other) + need
		if (s <= 0 or r - s < r * keep) then return nil end
		return s, function() MS.objSet(idx, "dims_x", r - s) end
	end
	local ax = boxAxes(b)
	-- Box: any of its three sides. Cylinder: only its length (local z).
	local sides = o.type == 2 and { 3 } or { 1, 2, 3 }
	local best
	for _, k in ipairs(sides) do
		local field = o.type == 2 and "dims_y" or DIM_FIELDS[k]
		local maxS = (o[field] or 0) * (1 - keep)
		for _, sign in ipairs({ 1, -1 }) do
			-- sign 1 cuts the +axis end, so the centre slides toward -axis.
			local function trial(s)
				local h = { b.h[1], b.h[2], b.h[3] }
				h[k] = h[k] - s / 2
				return (penetration({ c = V.sub(b.c, V.mul(ax[k], sign * s / 2)), R = b.R, h = h }, other))
			end
			if (maxS > 0 and trial(maxS) <= -need) then
				local lo, hi = 0, maxS
				for _ = 1, 30 do
					local mid = (lo + hi) / 2
					if (trial(mid) <= -need) then hi = mid else lo = mid end
				end
				if (not best or hi < best.s) then best = { s = hi, k = k, sign = sign, field = field } end
			end
		end
	end
	if (not best) then return nil end
	return best.s, function()
		MS.objSet(idx, best.field, (o[best.field] or 0) - best.s)
		MS.setObjPos(idx, V.sub(b.c, V.mul(ax[best.k], best.sign * best.s / 2)))
	end
end

-- keys: the nodes to fix. pickMover(ka, kb) returns the key that should be
-- trimmed first; the other one is tried if that can't be. Triangles are never
-- trimmed (their slices are rebuilt from the triangle's corners).
-- Returns how many trims were made, the biggest cut, and overlaps left unfixed.
local function trimNodes(keys, pickMover)
	local count, biggest, failed = 0, 0, 0
	for _ = 1, 6 do
		local any = false
		failed = 0
		for i = 1, #keys do
			for j = i + 1, #keys do
				local ka, kb = keys[i], keys[j]
				for _, a in ipairs(MS.nodeObjs(ka)) do
					for _, b in ipairs(MS.nodeObjs(kb)) do
						if (MS.objs[a] and MS.objs[b] and penetration(weldBox(a), weldBox(b)) > 0) then
							local order = { { a, b, ka }, { b, a, kb } }
							if (pickMover(ka, kb) == kb) then order = { order[2], order[1] } end
							local done = false
							for _, t in ipairs(order) do
								if (not done and t[3]:sub(1, 1) ~= "t") then
									local s, apply = trimPlan(t[1], weldBox(t[2]))
									if (s) then
										apply()
										count, biggest, done, any = count + 1, math.max(biggest, s), true, true
									end
								end
							end
							if (not done) then failed = failed + 1 end
						end
					end
				end
			end
		end
		if (not any) then break end
	end
	return count, biggest, failed
end

-- ---------------------------------------------------------------------------
-- Single-axis rotations. In-game test: a welded arch whose blocks were turned on
-- two axes (rot -90 0 -22.5 ...) pulled itself straight, while the same arch
-- with each block turned on one axis only (rot 0 -22.5 0, sides swapped to
-- match) kept its curve. The game works out a link's locked angle in a way that
-- only matches the pieces when they're turned around one axis. A box looks the
-- same whichever way its sides are labelled, so before welding each box is
-- relabelled (sides swapped) to the equivalent turn with the fewest axes.
-- ---------------------------------------------------------------------------
local BOX_TURNS

-- The 24 ways to relabel a box's axes: new axis k is old axis p[k] (times sign).
local function boxTurns()
	if (BOX_TURNS) then return BOX_TURNS end
	BOX_TURNS = {}
	local perms = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
	for _, p in ipairs(perms) do
		for _, sx in ipairs({ 1, -1 }) do
			for _, sy in ipairs({ 1, -1 }) do
				for _, sz in ipairs({ 1, -1 }) do
					local sg = { sx, sy, sz }
					local S = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
					for k = 1, 3 do S[p[k]][k] = sg[k] end
					local det = S[1][1] * (S[2][2] * S[3][3] - S[2][3] * S[3][2])
						- S[1][2] * (S[2][1] * S[3][3] - S[2][3] * S[3][1])
						+ S[1][3] * (S[2][1] * S[3][2] - S[2][2] * S[3][1])
					if (det > 0) then BOX_TURNS[#BOX_TURNS + 1] = { S = S, p = p } end
				end
			end
		end
	end
	return BOX_TURNS
end

local function axesUsed(x, y, z)
	local n = 0
	for _, a in ipairs({ x, y, z }) do
		if (math.abs(a) > 0.05) then n = n + 1 end
	end
	return n
end

-- Rewrites one object to an equivalent single-axis turn if it can.
-- Returns "changed", "ok" (already one axis or less) or "multi" (can't be).
local function makeSingleAxis(idx)
	local o = MS.objs[idx]
	if (not o) then return "ok" end
	local cur = axesUsed(o.rot_x or 0, o.rot_y or 0, o.rot_z or 0)
	if (cur <= 1) then return "ok" end
	if (o.type == 0) then
		-- A sphere looks the same however it's turned.
		MS.objSet(idx, "rot_x", 0); MS.objSet(idx, "rot_y", 0); MS.objSet(idx, "rot_z", 0)
		return "changed"
	end
	local m = MS.meta[idx]
	if (m and m.useModel) then return "multi" end -- relabelling would turn its 3D model
	local R = MS.objRot(idx)
	local best
	for _, t in ipairs(boxTurns()) do
		-- A cylinder's length runs along its own z, so z has to stay z.
		if (o.type ~= 2 or t.p[3] == 3) then
			local x, y, z = M.toEuler(M.mul(R, t.S))
			local n = axesUsed(x, y, z)
			if (not best or n < best.n) then best = { n = n, x = x, y = y, z = z, t = t } end
		end
	end
	if (not best or best.n > 1) then return "multi" end
	local function clean(a) return math.abs(a) > 0.05 and a or 0 end
	if (o.type ~= 2) then
		local dims = { o.dims_x or 0, o.dims_y or 0, o.dims_z or 0 }
		local p = best.t.p
		MS.objSet(idx, "dims_x", dims[p[1]]); MS.objSet(idx, "dims_y", dims[p[2]]); MS.objSet(idx, "dims_z", dims[p[3]])
	end
	MS.objSet(idx, "rot_x", clean(best.x)); MS.objSet(idx, "rot_y", clean(best.y)); MS.objSet(idx, "rot_z", clean(best.z))
	return "changed"
end

-- objs: object indices. Returns how many were rewritten and how many can't be.
local function makeAllSingleAxis(objs)
	local changed, multi = 0, 0
	for _, idx in ipairs(objs) do
		if (not isTriSlice(idx)) then
			local r = makeSingleAxis(idx)
			if (r == "changed") then changed = changed + 1 elseif (r == "multi") then multi = multi + 1 end
		end
	end
	return changed, multi
end

local function axisMsg(changed, multi)
	local msg = ""
	if (changed > 0) then
		msg = " Turned " .. changed .. " piece" .. (changed == 1 and "" or "s") .. " around one axis only (same look, sides relabelled) so the game keeps their angle."
	end
	if (multi > 0) then
		msg = msg .. " " .. multi .. " piece" .. (multi == 1 and " is" or "s are") .. " turned on more than one axis and can't be rewritten - their welds may pull straight in game."
	end
	return msg
end

local function trimmedMsg(count, biggest, failed)
	local msg = ""
	if (count > 0) then
		msg = string.format(" Trimmed overlapping pieces to fit (%d cut%s, biggest %.3f).", count, count == 1 and "" or "s", biggest)
	end
	if (failed > 0) then
		msg = msg .. " " .. failed .. " overlap" .. (failed == 1 and "" or "s") .. " couldn't be trimmed without cutting a piece below 20%."
	end
	return msg
end

function MS.weldPlan(list)
	local boxes = {}
	for _, idx in ipairs(list) do boxes[idx] = weldBox(idx) end
	local pairsList = {}
	for i = 1, #list do
		for j = i + 1, #list do
			local a, b = list[i], list[j]
			local over, axis = boxOverlap(boxes[a], boxes[b])
			if (over > -MS.WELD_TOUCH) then
				pairsList[#pairsList + 1] = { a = a, b = b, over = over, axis = axis,
					dist = V.dist(boxes[a].c, boxes[b].c) }
			end
		end
	end
	return boxes, pairsList
end

function MS.weldSelection()
	local list = MS.selList()
	if (#list < 2) then
		MS.toast("Select 2 or more touching objects to weld (Shift+click or Shift+drag)")
		return
	end
	if (#list > 300) then
		MS.toast("That's a lot of objects - weld at most 300 at a time")
		return
	end
	MS.pushUndo("Weld")
	lightened = 0
	local axisChanged, axisMulti = makeAllSingleAxis(list)
	-- Trim the smaller piece of each overlapping pair.
	local _, selNodes = MS.selKeys()
	local moves, biggest, failed = trimNodes(selNodes, function(ka, kb)
		return nodeVolume(ka) < nodeVolume(kb) and ka or kb
	end)
	local boxes, touching = MS.weldPlan(list)

	table.sort(touching, function(x, y) return x.dist < y.dist end)
	local parent = {}
	local function find(x)
		while (parent[x] and parent[x] ~= x) do x = parent[x] end
		return x
	end
	for _, idx in ipairs(list) do parent[idx] = idx end
	local existing = linkedPairs()
	local stiffened = 0
	for _, pr in ipairs(touching) do
		local j = existing[pr.a .. ":" .. pr.b]
		if (j) then
			if (stiffenPair(pr.a, pr.b)) then stiffened = stiffened + 1 end
			local ra, rb = find(pr.a), find(pr.b)
			if (ra ~= rb) then parent[ra] = rb end
		end
	end

	local made, overlapping = 0, 0
	for _, pr in ipairs(touching) do
		local ra, rb = find(pr.a), find(pr.b)
		local overlaps = pr.over > 0.001
		if (overlaps) then overlapping = overlapping + 1 end
		if ((ra ~= rb or overlaps) and not existing[pr.a .. ":" .. pr.b]) then
			local pos = contactPoint(boxes[pr.a], boxes[pr.b])
			if (weldLink(pr.a, pr.b, pos)) then
				parent[ra] = rb
				made = made + 1
			end
		end
	end

	local groups = {}
	for _, idx in ipairs(list) do groups[find(idx)] = true end
	local nGroups = MS.count(groups)
	MS.markDirty()
	if (made == 0 and stiffened == 0 and moves == 0 and axisChanged == 0) then
		table.remove(MS.undoStack)
		MS.toast(#touching == 0 and "None of the selected objects touch - move them together first"
			or "Already welded")
		return
	end
	local msg = made > 0 and ("Welded " .. made .. " joint" .. (made == 1 and "" or "s"))
		or "Already welded"
	if (stiffened > 0) then msg = msg .. ", upgraded " .. stiffened .. " existing weld" .. (stiffened == 1 and "" or "s") end
	if (nGroups > 1) then
		msg = msg .. " - " .. nGroups .. " separate groups (some pieces don't touch)"
	else
		msg = msg .. ". Untick Static to make it move as one piece"
	end
	MS.toast(msg .. "." .. trimmedMsg(moves, biggest, failed) .. lightMsg() .. axisMsg(axisChanged, axisMulti))
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

-- Every parent/child pair in the selected branches, as { parent = key, child = key }.
local function branchPairs()
	local H = MS.hier()
	local _, list = MS.selKeys()
	local out, seen = {}, {}
	for _, key in ipairs(list) do
		for _, c in ipairs(MS.descendants(key, H)) do
			if (not seen[c]) then
				seen[c] = true
				out[#out + 1] = { parent = H.parent[c], child = c }
			end
		end
	end
	return out, #list
end

-- The two closest objects between two nodes (a triangle node has several slices).
local function closestPair(pk, ck, boxes)
	local best, ba, bb = math.huge, nil, nil
	for _, a in ipairs(MS.nodeObjs(pk)) do
		boxes[a] = boxes[a] or weldBox(a)
		for _, b in ipairs(MS.nodeObjs(ck)) do
			boxes[b] = boxes[b] or weldBox(b)
			local d = V.dist(boxes[a].c, boxes[b].c)
			if (d < best) then best, ba, bb = d, a, b end
		end
	end
	return ba, bb
end

-- Every link index between two nodes.
local function nodeLinks(pk, ck, existing)
	local out = {}
	for _, a in ipairs(MS.nodeObjs(pk)) do
		for _, b in ipairs(MS.nodeObjs(ck)) do
			local j = existing[a .. ":" .. b]
			if (j) then out[#out + 1] = j end
		end
	end
	return out
end

function MS.weldToChildren()
	local pairsList, nSel = branchPairs()
	if (nSel == 0) then
		MS.toast("Select a parent first")
		return
	end
	if (#pairsList == 0) then
		MS.toast("The selection has no children to weld")
		return
	end
	if (#pairsList > 300) then
		MS.toast("That branch is very big - weld at most 300 children at a time")
		return
	end
	MS.pushUndo("Weld to children")
	lightened = 0
	-- Every node in the selected branches, parents included. Of an overlapping
	-- pair, the one lower in the hierarchy is trimmed (smaller one if level).
	local H = MS.hier()
	local branch, inBranch = {}, {}
	local function addKey(k)
		if (not inBranch[k]) then inBranch[k] = true; branch[#branch + 1] = k end
	end
	for _, pr in ipairs(pairsList) do addKey(pr.parent); addKey(pr.child) end
	local function depth(k)
		local n, p = 0, H.parent[k]
		while (p) do n = n + 1; p = H.parent[p] end
		return n
	end
	local branchObjs = {}
	for _, k in ipairs(branch) do
		for _, idx in ipairs(MS.nodeObjs(k)) do branchObjs[#branchObjs + 1] = idx end
	end
	local axisChanged, axisMulti = makeAllSingleAxis(branchObjs)
	local moves, biggest, failed = trimNodes(branch, function(ka, kb)
		local da, db = depth(ka), depth(kb)
		if (da > db or (da == db and nodeVolume(ka) < nodeVolume(kb))) then return ka end
		return kb
	end)
	local existing, boxes = linkedPairs(), {}
	local made, already, stiffened = 0, 0, 0
	for _, pr in ipairs(pairsList) do
		local links = nodeLinks(pr.parent, pr.child, existing)
		if (#links > 0) then
			already = already + 1
			for _, j in ipairs(links) do
				if (MS.ejs[j] and stiffenPair(MS.ejs[j].obj1, MS.ejs[j].obj2)) then stiffened = stiffened + 1 end
			end
		else
			local a, b = closestPair(pr.parent, pr.child, boxes)
			if (a and b) then
				local pos = contactPoint(boxes[a], boxes[b])
				local n = weldLink(a, b, pos)
				if (n) then
					existing[a .. ":" .. b], existing[b .. ":" .. a] = n, n
					made = made + 1
				end
			end
		end
	end
	MS.markDirty()
	if (made == 0 and (stiffened > 0 or moves > 0 or axisChanged > 0)) then
		local msg = stiffened > 0 and ("Upgraded " .. stiffened .. " existing weld" .. (stiffened == 1 and "" or "s") .. " to the new rigid kind.")
			or "Already welded to its children."
		MS.toast(msg .. trimmedMsg(moves, biggest, failed) .. lightMsg() .. axisMsg(axisChanged, axisMulti))
		if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
		return
	end
	if (made == 0) then
		table.remove(MS.undoStack)
		MS.toast(already > 0 and "Already welded to its children" or "Couldn't weld - the game refused the links")
		return
	end
	local msg = "Welded to " .. made .. " child" .. (made == 1 and "" or "ren") .. " (whole branch)"
	if (already > 0) then msg = msg .. ", " .. already .. " already welded" end
	MS.toast(msg .. ". Untick Static to make it move as one piece." .. trimmedMsg(moves, biggest, failed) .. lightMsg() .. axisMsg(axisChanged, axisMulti))
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

function MS.unweldChildren()
	local pairsList, nSel = branchPairs()
	if (nSel == 0 or #pairsList == 0) then
		MS.toast(nSel == 0 and "Select a parent first" or "The selection has no children")
		return
	end
	local want = {}
	for _, pr in ipairs(pairsList) do
		for _, a in ipairs(MS.nodeObjs(pr.parent)) do
			for _, b in ipairs(MS.nodeObjs(pr.child)) do
				want[a .. ":" .. b], want[b .. ":" .. a] = true, true
			end
		end
	end
	local doomed = {}
	for j, ej in pairs(MS.ejs) do
		if (ej.obj1 and ej.obj2 and want[ej.obj1 .. ":" .. ej.obj2]) then doomed[#doomed + 1] = j end
	end
	if (#doomed == 0) then
		MS.toast("No links between the selection and its children")
		return
	end
	MS.pushUndo("Unweld children")
	local touched = {}
	for _, j in ipairs(doomed) do
		local ej = MS.ejs[j]
		if (ej and ej.obj1) then touched[ej.obj1] = true end
		if (ej and ej.obj2) then touched[ej.obj2] = true end
		pcall(delete_mod_envjoint, j)
		MS.ejs[j] = nil
		if (MS.ejSel == j) then MS.ejSel = nil end
	end
	local restored = restoreWeights(touched)
	local weightMsg = restored > 0 and (". " .. restored .. " piece" .. (restored == 1 and "" or "s") .. " got their weight back") or ""
	MS.markDirty()
	MS.toast("Removed " .. #doomed .. " parent-child link" .. (#doomed == 1 and "" or "s") .. weightMsg)
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end

function MS.unweldSelection()
	local sel = {}
	for _, idx in ipairs(MS.selList()) do sel[idx] = true end
	local doomed = {}
	for j, ej in pairs(MS.ejs) do
		if (sel[ej.obj1] and sel[ej.obj2]) then doomed[#doomed + 1] = j end
	end
	if (#doomed == 0) then
		MS.toast("No links between the selected objects")
		return
	end
	MS.pushUndo("Unweld")
	local touched = {}
	for _, j in ipairs(doomed) do
		local ej = MS.ejs[j]
		if (ej and ej.obj1) then touched[ej.obj1] = true end
		if (ej and ej.obj2) then touched[ej.obj2] = true end
		pcall(delete_mod_envjoint, j)
		MS.ejs[j] = nil
		if (MS.ejSel == j) then MS.ejSel = nil end
	end
	local restored = restoreWeights(touched)
	local weightMsg = restored > 0 and (". " .. restored .. " piece" .. (restored == 1 and "" or "s") .. " got their weight back") or ""
	MS.markDirty()
	MS.toast("Removed " .. #doomed .. " link" .. (#doomed == 1 and "" or "s") .. " between the selected objects" .. weightMsg)
	if (MS.UI and MS.UI.requestRefresh) then MS.UI.requestRefresh() end
end
