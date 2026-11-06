-- Mod Studio: dock layout maths
-- Pure functions (numbers in, numbers out, no UI calls) so they can be tested
-- outside the game. The interface in ui.lua calls these to place the three
-- docks like an editor: Scene down the left, Properties down the right and the
-- bottom tabs in between. A tucked-away side dock shrinks to a thin rail and
-- the bottom dock grows into the freed space.

local MS = MS
MS.UI = MS.UI or {}
local UI = MS.UI

local floor = math.floor
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local Lc = {}
UI.layoutCalc = Lc

Lc.MIN_SIDE = 180      -- narrowest a side dock can be dragged
Lc.MIN_BOTTOM = 100    -- shortest the bottom dock can be dragged
Lc.DOUBLE_CLICK = 0.4  -- seconds between clicks on an edge that reset its size
Lc.EDGE = 5            -- thickness of the draggable edge strip

---Width of a tucked-away side dock
function Lc.railWidth(row)
	return row + 8
end

---m = { winW, winH, top, bottom, row, header, k }: window and bar metrics
local function maxSide(m) return floor(m.winW * 0.4) end
local function maxBottom(m) return floor((m.bottom - m.top) * 0.75) end

---Width of an open side dock: the user's size if they dragged one, else the default
function Lc.sideWidth(side, sizes, m)
	local v = sizes and sizes[side]
	if (type(v) == "number") then return clamp(floor(v), Lc.MIN_SIDE, math.max(Lc.MIN_SIDE, maxSide(m))) end
	return clamp(floor(m.winW * 0.1875), floor(250 * m.k), floor(400 * m.k))
end

---Height of the open bottom dock
function Lc.bottomHeight(sizes, m)
	local v = sizes and sizes.bottom
	if (type(v) == "number") then return clamp(floor(v), Lc.MIN_BOTTOM, math.max(Lc.MIN_BOTTOM, maxBottom(m))) end
	return clamp(floor((m.bottom - m.top) * 0.32), Lc.MIN_BOTTOM, math.max(Lc.MIN_BOTTOM, maxBottom(m)))
end

---Rectangle (x, y, w, h) of a docked panel. open = { left = bool, right = bool, bottom = bool }
function Lc.dockRect(side, open, sizes, m)
	local avail = m.bottom - m.top
	local rail = Lc.railWidth(m.row)
	local lw = open.left and Lc.sideWidth("left", sizes, m) or rail
	local rw = open.right and Lc.sideWidth("right", sizes, m) or rail
	if (side == "left") then return 0, m.top, lw, avail end
	if (side == "right") then return m.winW - rw, m.top, rw, avail end
	local h = open.bottom and Lc.bottomHeight(sizes, m) or m.header
	return lw, m.bottom - h, m.winW - lw - rw, h
end

---New size for a dock edge being dragged with the mouse at (mx, my)
function Lc.dragSize(side, mx, my, m)
	if (side == "left") then return clamp(floor(mx + 0.5), Lc.MIN_SIDE, math.max(Lc.MIN_SIDE, maxSide(m))) end
	if (side == "right") then return clamp(floor(m.winW - mx + 0.5), Lc.MIN_SIDE, math.max(Lc.MIN_SIDE, maxSide(m))) end
	return clamp(floor(m.bottom - my + 0.5), Lc.MIN_BOTTOM, math.max(Lc.MIN_BOTTOM, maxBottom(m)))
end

---Where to draw the preview line while an edge is dragged: x, y, w, h
function Lc.edgeLine(side, value, m)
	if (side == "left") then return value - 1, m.top, 2, m.bottom - m.top end
	if (side == "right") then return m.winW - value - 1, m.top, 2, m.bottom - m.top end
	return 0, m.bottom - value - 1, m.winW, 2
end

---Two clicks on the same edge close together reset its size
function Lc.isDoubleClick(last, now)
	return last ~= nil and now - last <= Lc.DOUBLE_CLICK
end

---Arrow on the collapse button: points the way the panel will go
function Lc.arrow(side, open)
	if (side == "left") then return open and "<" or ">" end
	if (side == "right") then return open and ">" or "<" end
	return open and "v" or "^"
end

---One letter shown on a rail button for a tab
function Lc.railLabel(name)
	return (tostring(name or "?"):sub(1, 1):upper())
end

---What gets saved: { side = { active, open } }
function Lc.serializeState(state)
	local out = {}
	for side, st in pairs(state) do out[side] = { active = st.active, open = st.open and true or false } end
	return out
end

---Applies saved dock state onto `state`, ignoring anything that no longer exists.
---tabs = { side = { tabId = true } }
function Lc.restoreState(state, saved, tabs)
	if (type(saved) ~= "table") then return state end
	for side, st in pairs(state) do
		local s = saved[side]
		if (type(s) == "table") then
			if (type(s.open) == "boolean") then st.open = s.open end
			if (type(s.active) == "string" and tabs[side] and tabs[side][s.active]) then st.active = s.active end
		end
	end
	return state
end
