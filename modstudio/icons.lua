-- Mod Studio: icons
-- Small vector icons drawn with the game's 2D draw calls, so there are no image
-- files to ship and they scale with the "UI size" setting and follow the theme.
-- Every icon is drawn into a square of side s centred on (cx, cy).

local MS = MS
MS.UI = MS.UI or {}
local UI = MS.UI

local sin, cos, rad, floor = math.sin, math.cos, math.rad, math.floor

local Icons = {}
UI.Icons = Icons

-- Primitives -------------------------------------------------------------

local function quad(x, y, w, h) pcall(draw_quad, floor(x + 0.5), floor(y + 0.5), w, h) end
local function dot(x, y, r) pcall(draw_disk, x, y, 0, r, 16, 1, 0, 360, 0) end
local function ring(x, y, r, w) pcall(draw_disk, x, y, math.max(0, r - w / 2), r + w / 2, 28, 1, 0, 360, 0) end

---Line with round ends so joined segments don't leave gaps
local function line(x1, y1, x2, y2, w)
	pcall(draw_line, x1, y1, x2, y2, w)
	if (w > 1.5) then
		dot(x1, y1, w / 2)
		dot(x2, y2, w / 2)
	end
end

local function poly(pts, w, closed)
	for i = 1, #pts - 1 do line(pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2], w) end
	if (closed and #pts > 2) then line(pts[#pts][1], pts[#pts][2], pts[1][1], pts[1][2], w) end
end

---Ellipse arc. Angles in degrees, 0 = right, 90 = down (screen space)
local function arcPts(cx, cy, rx, ry, a0, a1, seg)
	seg = seg or 14
	local pts = {}
	for i = 0, seg do
		local a = rad(a0 + (a1 - a0) * i / seg)
		pts[#pts + 1] = { cx + cos(a) * rx, cy + sin(a) * ry }
	end
	return pts
end
local function arc(cx, cy, rx, ry, a0, a1, w, seg) poly(arcPts(cx, cy, rx, ry, a0, a1, seg), w) end

---Filled triangle, drawn as 1px horizontal strips
local function tri(ax, ay, bx, by, cx, cy)
	local p = { { ax, ay }, { bx, by }, { cx, cy } }
	table.sort(p, function(a, b) return a[2] < b[2] end)
	local function xAt(a, b, y)
		if (b[2] == a[2]) then return a[1] end
		return a[1] + (b[1] - a[1]) * (y - a[2]) / (b[2] - a[2])
	end
	for y = floor(p[1][2]), floor(p[3][2]) do
		local yy = y + 0.5
		if (yy >= p[1][2] and yy <= p[3][2]) then
			local x1 = xAt(p[1], p[3], yy)
			local x2 = yy < p[2][2] and xAt(p[1], p[2], yy) or xAt(p[2], p[3], yy)
			if (x1 > x2) then x1, x2 = x2, x1 end
			if (x2 - x1 >= 0.5) then pcall(draw_quad, floor(x1 + 0.5), y, math.max(1, floor(x2 - x1 + 0.5)), 1) end
		end
	end
end

---Arrow head at (x, y) pointing along angle a (degrees)
local function head(x, y, a, len, w)
	local l, r = rad(a + 150), rad(a - 150)
	line(x, y, x + cos(l) * len, y + sin(l) * len, w)
	line(x, y, x + cos(r) * len, y + sin(r) * len, w)
end

-- Icons ------------------------------------------------------------------
-- Each: function(cx, cy, s, w) where w is the stroke width

local function eye(cx, cy, s, w)
	local a, b = s * 0.46, s * 0.27
	local R = (a * a + b * b) / (2 * b)
	local phi = math.deg(math.asin(a / R))
	arc(cx, cy - b + R, R, R, -90 - phi, -90 + phi, w)  -- upper lid
	arc(cx, cy + b - R, R, R, 90 - phi, 90 + phi, w)    -- lower lid
	dot(cx, cy, s * 0.14)
end

Icons.eye = eye
Icons.eyeoff = function(cx, cy, s, w)
	eye(cx, cy, s, w)
	line(cx - s * 0.4, cy - s * 0.36, cx + s * 0.4, cy + s * 0.36, w)
end

local function padlock(cx, cy, s, w, open)
	local bw, bh = s * 0.62, s * 0.44
	local top = cy - s * 0.02
	quad(cx - bw / 2, top, bw, bh)
	local r = s * 0.19
	local sy = open and top - s * 0.14 or top
	-- Shackle: arc over the top, legs down into the body (open: right leg lifted out)
	arc(cx, sy - s * 0.12, r, r, 180, 360, w)
	line(cx - r, sy - s * 0.12, cx - r, top + 1, w)
	if (open) then
		line(cx + r, sy - s * 0.12, cx + r, sy - s * 0.02, w)
	else
		line(cx + r, sy - s * 0.12, cx + r, top + 1, w)
	end
end
Icons.lock = function(cx, cy, s, w) padlock(cx, cy, s, w, false) end
Icons.unlock = function(cx, cy, s, w) padlock(cx, cy, s, w, true) end

Icons.chevright = function(cx, cy, s, w) poly({ { cx - s * 0.12, cy - s * 0.25 }, { cx + s * 0.13, cy }, { cx - s * 0.12, cy + s * 0.25 } }, w) end
Icons.chevdown = function(cx, cy, s, w) poly({ { cx - s * 0.25, cy - s * 0.12 }, { cx, cy + s * 0.13 }, { cx + s * 0.25, cy - s * 0.12 } }, w) end
Icons.chevup = function(cx, cy, s, w) poly({ { cx - s * 0.25, cy + s * 0.12 }, { cx, cy - s * 0.13 }, { cx + s * 0.25, cy + s * 0.12 } }, w) end

Icons.plus = function(cx, cy, s, w)
	line(cx - s * 0.3, cy, cx + s * 0.3, cy, w)
	line(cx, cy - s * 0.3, cx, cy + s * 0.3, w)
end
Icons.minus = function(cx, cy, s, w) line(cx - s * 0.3, cy, cx + s * 0.3, cy, w) end
Icons.close = function(cx, cy, s, w)
	local d = s * 0.27
	line(cx - d, cy - d, cx + d, cy + d, w)
	line(cx - d, cy + d, cx + d, cy - d, w)
end

Icons.trash = function(cx, cy, s, w)
	line(cx - s * 0.36, cy - s * 0.26, cx + s * 0.36, cy - s * 0.26, w)              -- lid
	poly({ { cx - s * 0.1, cy - s * 0.26 }, { cx - s * 0.1, cy - s * 0.38 }, { cx + s * 0.1, cy - s * 0.38 }, { cx + s * 0.1, cy - s * 0.26 } }, w)
	poly({ { cx - s * 0.27, cy - s * 0.16 }, { cx - s * 0.22, cy + s * 0.4 }, { cx + s * 0.22, cy + s * 0.4 }, { cx + s * 0.27, cy - s * 0.16 } }, w)
	line(cx, cy - s * 0.06, cx, cy + s * 0.28, math.max(1, w * 0.8))
end

Icons.grip = function(cx, cy, s)
	local r = math.max(1, s * 0.07)
	for i = -1, 1 do
		dot(cx - s * 0.12, cy + i * s * 0.24, r)
		dot(cx + s * 0.12, cy + i * s * 0.24, r)
	end
end

Icons.resize = function(cx, cy, s, w)
	local x2, y2 = cx + s * 0.38, cy + s * 0.38
	for i = 1, 3 do
		local d = s * 0.25 * i
		line(x2 - d, y2, x2, y2 - d, math.max(1, w * 0.8))
	end
end

-- Toolbar

Icons.select = function(cx, cy, s, w)
	-- Mouse pointer: arrow head plus a short tail
	local x, y = cx - s * 0.18, cy - s * 0.4
	tri(x, y, x, y + s * 0.6, x + s * 0.43, y + s * 0.45)
	line(x + s * 0.17, y + s * 0.45, x + s * 0.3, y + s * 0.76, w * 1.3)
end

Icons.move = function(cx, cy, s, w)
	local d = s * 0.42
	line(cx - d, cy, cx + d, cy, w)
	line(cx, cy - d, cx, cy + d, w)
	local hl = s * 0.16
	head(cx + d, cy, 0, hl, w); head(cx - d, cy, 180, hl, w)
	head(cx, cy + d, 90, hl, w); head(cx, cy - d, 270, hl, w)
end

Icons.rotate = function(cx, cy, s, w)
	local r = s * 0.32
	arc(cx, cy, r, r, -60, 220, w, 18)
	local a = rad(220)
	head(cx + cos(a) * r, cy + sin(a) * r, 220 + 90, s * 0.2, w)
end

Icons.scale = function(cx, cy, s, w)
	-- Small box growing into a big dashed corner
	local x0, y0 = cx - s * 0.38, cy + s * 0.38
	quad(x0, y0 - s * 0.34, s * 0.34, s * 0.34)
	poly({ { x0, y0 - s * 0.76 }, { x0 + s * 0.76, y0 - s * 0.76 }, { x0 + s * 0.76, y0 } }, math.max(1, w * 0.8))
	line(x0 + s * 0.42, y0 - s * 0.42, x0 + s * 0.68, y0 - s * 0.68, w)
	head(x0 + s * 0.68, y0 - s * 0.68, -45, s * 0.16, w)
end

Icons.measure = function(cx, cy, s, w)
	-- Ruler
	local x0, x1, y = cx - s * 0.42, cx + s * 0.42, cy + s * 0.12
	line(x0, y, x1, y, w)
	for i = 0, 6 do
		local x = x0 + (x1 - x0) * i / 6
		local h = (i % 3 == 0) and s * 0.34 or s * 0.18
		line(x, y, x, y - h, math.max(1, w * 0.75))
	end
end

Icons.world = function(cx, cy, s, w)
	local r = s * 0.38
	ring(cx, cy, r, w)
	arc(cx, cy, r * 0.42, r, 0, 360, math.max(1, w * 0.8), 20)
	line(cx - r, cy, cx + r, cy, math.max(1, w * 0.8))
end

Icons["local"] = function(cx, cy, s, w)
	-- Cube in perspective
	local f, o = s * 0.5, s * 0.2
	local x0, y0 = cx - s * 0.36, cy - s * 0.18
	poly({ { x0, y0 }, { x0 + f, y0 }, { x0 + f, y0 + f }, { x0, y0 + f } }, w, true)
	poly({ { x0, y0 }, { x0 + o, y0 - o }, { x0 + f + o, y0 - o }, { x0 + f, y0 } }, w)
	poly({ { x0 + f + o, y0 - o }, { x0 + f + o, y0 + f - o }, { x0 + f, y0 + f } }, w)
end

Icons.snap = function(cx, cy, s, w)
	local d = s * 0.38
	local t = math.max(1, w * 0.75)
	for i = -1, 1, 2 do
		line(cx - d, cy + i * d / 3, cx + d, cy + i * d / 3, t)
		line(cx + i * d / 3, cy - d, cx + i * d / 3, cy + d, t)
	end
	dot(cx + d / 3, cy - d / 3, w * 1.4)
end

Icons.stick = function(cx, cy, s, w)
	-- Horseshoe magnet, poles down, with gaps marking the pole tips
	local r = s * 0.24
	local y = cy - s * 0.04
	local t = w * 1.3
	arc(cx, y, r, r, 180, 360, t, 14)
	line(cx - r, y, cx - r, y + s * 0.2, t)
	line(cx + r, y, cx + r, y + s * 0.2, t)
	quad(cx - r - t / 2, y + s * 0.28, t, s * 0.12)
	quad(cx + r - t / 2, y + s * 0.28, t, s * 0.12)
end

Icons.undo = function(cx, cy, s, w)
	local r = s * 0.28
	local y = cy + s * 0.08
	arc(cx, y, r, r, -90, 90, w, 12)                         -- right half circle
	line(cx - s * 0.26, y - r, cx, y - r, w)                 -- top, back to the arrow head
	line(cx, y + r, cx - s * 0.1, y + r, w)
	head(cx - s * 0.26, y - r, 180, s * 0.18, w)
end
Icons.redo = function(cx, cy, s, w)
	local r = s * 0.28
	local y = cy + s * 0.08
	arc(cx, y, r, r, 90, 270, w, 12)
	line(cx + s * 0.26, y - r, cx, y - r, w)
	line(cx, y + r, cx + s * 0.1, y + r, w)
	head(cx + s * 0.26, y - r, 0, s * 0.18, w)
end

Icons.focus = function(cx, cy, s, w)
	local r = s * 0.26
	ring(cx, cy, r, w)
	dot(cx, cy, w)
	local a, b = s * 0.16, s * 0.42
	line(cx - b, cy, cx - a, cy, w); line(cx + a, cy, cx + b, cy, w)
	line(cx, cy - b, cx, cy - a, w); line(cx, cy + a, cx, cy + b, w)
end

Icons.play = function(cx, cy, s)
	tri(cx - s * 0.24, cy - s * 0.34, cx - s * 0.24, cy + s * 0.34, cx + s * 0.34, cy)
end

Icons.help = function(cx, cy, s, w)
	local r = s * 0.17
	arc(cx, cy - s * 0.16, r, r, 180, 400, w, 12)
	local a = rad(400)
	local ex, ey = cx + cos(a) * r, cy - s * 0.16 + sin(a) * r
	line(ex, ey, cx, cy + s * 0.08, w)
	line(cx, cy + s * 0.08, cx, cy + s * 0.14, w)
	dot(cx, cy + s * 0.33, w * 0.9)
end

Icons.pencil = function(cx, cy, s, w)
	local d = s * 0.3
	line(cx - d + s * 0.06, cy + d - s * 0.06, cx + d, cy - d, w * 2)
	tri(cx - d - s * 0.06, cy + d + s * 0.06, cx - d + s * 0.13, cy + d + s * 0.01, cx - d - s * 0.01, cy + d - s * 0.13)
end

-- Objects / actions

Icons.copy = function(cx, cy, s, w)
	local d = s * 0.44
	poly({ { cx - s * 0.36 + d * 0.35, cy - s * 0.36 }, { cx - s * 0.36, cy - s * 0.36 }, { cx - s * 0.36, cy - s * 0.36 + d } , { cx - s * 0.36 + d * 0.35, cy - s * 0.36 + d } }, w)
	poly({ { cx - s * 0.12, cy - s * 0.12 }, { cx - s * 0.12 + d, cy - s * 0.12 }, { cx - s * 0.12 + d, cy - s * 0.12 + d }, { cx - s * 0.12, cy - s * 0.12 + d } }, w, true)
end

Icons.box = function(cx, cy, s, w) Icons["local"](cx, cy, s * 0.9, w) end
Icons.sphere = function(cx, cy, s, w)
	local r = s * 0.36
	ring(cx, cy, r, w)
	arc(cx, cy, r, r * 0.35, 0, 180, math.max(1, w * 0.75), 12)
end
Icons.cylinder = function(cx, cy, s, w)
	local rx, ry, h = s * 0.3, s * 0.11, s * 0.5
	arc(cx, cy - h / 2, rx, ry, 0, 360, w, 18)
	arc(cx, cy + h / 2, rx, ry, 0, 180, w, 10)
	line(cx - rx, cy - h / 2, cx - rx, cy + h / 2, w)
	line(cx + rx, cy - h / 2, cx + rx, cy + h / 2, w)
end

-- Drawing ----------------------------------------------------------------

---Icon colour for a button: dark on a bright (active) background, light otherwise
function UI.iconColor(bg, disabled)
	local lum = bg and (bg[1] * 0.3 + bg[2] * 0.59 + bg[3] * 0.11) or 0
	local c = lum > 0.72 and { 0.12, 0.08, 0.08 } or { 1, 1, 1 }
	return c[1], c[2], c[3], disabled and 0.35 or 0.95
end

---Draws the named icon into a w x h box at (x, y). Unknown names draw nothing.
function UI.drawIcon(name, x, y, w, h, r, g, b, a)
	local fn = Icons[name]
	if (not fn) then return end
	local s = math.min(w, h) * 0.78
	set_color(r or 1, g or 1, b or 1, a or 1)
	fn(x + w / 2, y + h / 2, s, math.max(1.2, s / 9))
end

---Adds an icon on top of an element.
---o: bg (background colour, picks a dark icon on bright buttons), disabled, dim (fainter, for "off" states),
---   box = { x, y, w, h } inside the element (default: the whole element)
function UI.addIcon(el, name, o)
	o = o or {}
	-- On its own (non-interactive) child: an element has one custom display slot and
	-- addAdaptedText uses it for the label
	local bx = o.box or { 0, 0, el.size.w, el.size.h }
	local holder = el:addChild({ pos = { bx[1], bx[2] }, size = { bx[3], bx[4] } })
	local r, g, b, a = UI.iconColor(o.bg, o.disabled)
	if (o.dim and not o.disabled) then a = 0.5 end
	holder:addCustomDisplay(true, function(init)
		if (init) then return end
		UI.drawIcon(name, holder.pos.x, holder.pos.y, holder.size.w, holder.size.h, r, g, b, a)
	end)
	return holder
end
