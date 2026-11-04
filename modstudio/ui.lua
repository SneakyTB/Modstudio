-- Mod Studio: interface
-- Main panel (tabs), top toolbar, status bar with hints, help overlay and dialogs.
-- Built on the game's own toriui so it looks and behaves like the stock menus.

local MS = MS
local V, M = MS.V, MS.M
local floor = math.floor

MS.UI = MS.UI or {}
local UI = MS.UI

UI.sub = UI.sub or { objects = "transform", players = "transform", joints = "main" }
UI.pages = UI.pages or {}
UI.fileMode = "main"
UI.filter = UI.filter or ""
UI.collapsed = UI.collapsed or {}   -- uid -> true for folded branches in the Scene list

-- Sizes are set by UI.applyTheme() from the "UI size" setting
local ROW, GAP, PAD = 20, 2, 4
UI.k, UI.textK, UI.HEADER_H = 1, 0.94, 26

-- Colors: Toribash's own menu reds, a shade darker for a dense editor look.
-- Filled in place by UI.applyTheme() so every widget picks up changes.
local C = { clear = { 0, 0, 0, 0 }, shade = { 0, 0, 0, 0.18 },
	axis = { { 0.85, 0.25, 0.25, 1 }, { 0.3, 0.65, 0.25, 1 }, { 0.25, 0.45, 0.9, 1 } } }
UI.C = C

UI.ACCENTS = {
	{ "pink", "Toribash", { 0.9, 0.62, 0.62, 1 } },
	{ "red", "Red", { 0.96, 0.38, 0.33, 1 } },
	{ "gold", "Gold", { 0.98, 0.78, 0.36, 1 } },
	{ "blue", "Blue", { 0.5, 0.66, 0.98, 1 } },
	{ "green", "Green", { 0.55, 0.85, 0.45, 1 } },
	{ "white", "White", { 0.93, 0.93, 0.93, 1 } }
}

local function shadeOf(c, f, a)
	return { math.min(1, c[1] * f), math.min(1, c[2] * f), math.min(1, c[3] * f), a or c[4] or 1 }
end

function UI.sizes() return ROW, GAP, PAD end

function UI.applyTheme()
	local st = MS.settings or {}
	local k = MS.clamp(tonumber(st.uiScale) or 1, 0.8, 1.5)
	UI.k = k
	ROW = floor(20 * k + 0.5)
	GAP = math.max(1, floor(2 * k + 0.5))
	PAD = math.max(2, floor(4 * k + 0.5))
	UI.HEADER_H = ROW + 6
	UI.textK = 0.94 * k
	local bg = TB_MENU_DEFAULT_BG_COLOR or { 0.67, 0.11, 0.11, 1 }
	local darker = TB_MENU_DEFAULT_DARKER_COLOR or { 0.607, 0.109, 0.109, 1 }
	local darkest = TB_MENU_DEFAULT_DARKEST_COLOR or { 0.55, 0.05, 0.05, 1 }
	local lighter = TB_MENU_DEFAULT_LIGHTER_COLOR or { 0.8, 0.25, 0.25, 1 }
	local accent = UI.ACCENTS[1][3]
	for _, a in ipairs(UI.ACCENTS) do
		if (a[1] == st.accent) then accent = a[3] end
	end
	C.bg = shadeOf(darker, 0.8)        -- panel body
	C.dark = shadeOf(bg, 0.92)         -- buttons
	C.darkest = shadeOf(darkest, 0.62) -- fields, section bars, panel edges, top bar
	C.light = shadeOf(lighter, 1)      -- hover
	C.lightest = { accent[1], accent[2], accent[3], 1 } -- active / selected
	C.edge = shadeOf(darkest, 0.4)
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

function UI.requestRefresh()
	UI.needRefresh = true
end

function UI.setTip(text, el)
	UI.tipText = text
	UI.tipElem = el
end

local function inside(el, x, y)
	return el and not el.destroyed and el.displayed ~= false and el.pos and
		x >= el.pos.x and x <= el.pos.x + el.size.w and y >= el.pos.y and y <= el.pos.y + el.size.h
end

---Every top-level piece of UI (docks, toolbar, status, overlays)
function UI.roots()
	local list = { UI.dialog, UI.help, UI.toolbar, UI.status, UI.testBar }
	for _, el in pairs(UI.dockEls or {}) do table.insert(list, el) end
	return list
end

function UI.isOverUI(x, y)
	for _, el in ipairs(UI.roots()) do
		if (inside(el, x, y)) then return true end
	end
	return false
end

function UI.fieldFocused()
	for _, v in ipairs(UIKeyboardHandler or {}) do
		if (v.textfield and v.keyboard) then return true end
	end
	return false
end

function UI.blurFields()
	for _, v in ipairs(UIKeyboardHandler or {}) do
		if (v.textfield) then
			if (v.menuKeyboardId) then pcall(v.disableMenuKeyboard, v) end
			v.keyboard = false
		end
	end
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

-- BadaBoom, the game's own heading font
UI.TITLE_FONT = (FONTS and FONTS.BIG) or 0

local function label(parent, x, y, w, h, str, align, scale, font)
	local l = parent:addChild({ pos = { x, y }, size = { w, h } })
	l:addAdaptedText(false, str, nil, nil, font or 4, align or LEFTMID, (scale or 0.5) * UI.textK)
	return l
end
UI.label = label

local function hint(parent, x, y, w, h, str, scale)
	local l = parent:addChild({ pos = { x, y }, size = { w, h } })
	l:addAdaptedText(true, str, nil, nil, 4, CENTERMID, (scale or 0.5) * UI.textK)
	return l
end
UI.hint = hint

---Button. o: active, disabled, tip, color, scale, align
local function button(parent, x, y, w, h, text, onClick, o)
	o = o or {}
	local b = parent:addChild({
		pos = { x, y }, size = { w, h },
		shapeType = ROUNDED, rounded = 2,
		interactive = not o.disabled,
		bgColor = o.active and C.lightest or (o.color or C.dark),
		hoverColor = C.light, pressedColor = C.darkest,
		inactiveColor = C.darkest
	})
	b:addAdaptedText(false, text, o.align == LEFTMID and 6 or nil, nil, 4, o.align or CENTERMID, (o.scale or 0.5) * UI.textK)
	if (onClick and not o.disabled) then
		b:addMouseHandlers(nil, function() onClick() end)
	end
	if (o.tip) then
		b:addMouseHandlers(nil, nil, function() UI.setTip(o.tip, b) end)
	end
	return b
end
UI.button = button

---Row of evenly sized buttons. items = { { text, fn, active = , tip = , disabled = } }
local function buttonRow(parent, x, y, w, h, items)
	local n = #items
	local bw = (w - GAP * (n - 1)) / n
	for i, it in ipairs(items) do
		button(parent, x + (i - 1) * (bw + GAP), y, bw, h, it[1], it[2], { active = it.active, tip = it.tip, disabled = it.disabled })
	end
end

---Text input. o: numeric, live (getter for auto refresh), placeholder, align
local function field(parent, x, y, w, h, value, o, onChange)
	o = o or {}
	local f = TBMenu:spawnTextField2(parent, { x = x, y = y, w = w, h = h }, value or "", o.placeholder, {
		isNumeric = o.numeric or false,
		allowDecimal = true,
		allowNegative = true,
		fontId = 4,
		textScale = 0.5 * UI.textK,
		textAlign = o.align or CENTERMID,
		darkerMode = true,
		inputType = o.numeric and KEYBOARD_INPUT.NUMBERPAD or KEYBOARD_INPUT.ASCII,
		returnKeyType = KEYBOARD_RETURN.DONE
	})
	if (onChange) then
		f:addInputCallback(function() onChange(f.textfieldstr[1]) end)
	end
	if (o.enter) then
		f:addEnterAction(function() o.enter(f.textfieldstr[1]) end)
	end
	if (o.live) then
		f:addCustomDisplay(false, function()
			if (not f.keyboard) then
				local ok, v = pcall(o.live)
				local s = ok and MS.fmt(v) or ""
				if (f.textfieldstr[1] ~= s) then
					f.textfieldstr[1] = s
					f.textfieldindex = string.len(s)
				end
			end
		end, true)
	end
	return f
end
UI.field = field

---Lets the user drag left/right on an element to change a number
local function scrub(el, get, set, step, o)
	o = o or {}
	el:addMouseHandlers(function(_, x)
			el.scrubX = x
			el.scrubV = get() or 0
			pcall(disable_mouse_camera_movement)
		end, function()
			el.scrubX = nil
			pcall(enable_mouse_camera_movement)
		end, function(x)
			if (el.hoverState == BTN_DN and el.scrubX) then
				local mult = MS.shiftDown() and 0.2 or 1
				local v = el.scrubV + (x - el.scrubX) * step * 0.2 * mult
				if (o.int) then v = floor(v + 0.5) end
				if (o.min) then v = math.max(o.min, v) end
				if (o.max) then v = math.min(o.max, v) end
				if (v ~= el.lastScrub) then
					el.lastScrub = v
					set(v)
				end
			else
				UI.setTip(o.tip or "Drag left/right to change (hold Shift for fine control), or type a value", el)
			end
		end, nil, function()
			el.scrubX = nil
			pcall(enable_mouse_camera_movement)
		end)
end

local function clampEntry(e, v)
	if (e.int) then v = floor(v + 0.5) end
	if (e.min) then v = math.max(e.min, v) end
	if (e.max) then v = math.min(e.max, v) end
	return v
end

---label | [-] [ value ] [+]
local function numRow(holder, y, w, e)
	local lw = floor(w * 0.44)
	local lab = holder:addChild({ pos = { 0, y }, size = { lw - 2, ROW }, interactive = true,
		bgColor = C.clear, hoverColor = C.shade, pressedColor = C.shade, shapeType = ROUNDED, rounded = 3 })
	lab:addAdaptedText(false, e.label, 4, nil, 4, LEFTMID, 0.5)
	scrub(lab, e.get, function(v) e.set(clampEntry(e, v)) end, e.step or 0.1, { int = e.int, min = e.min, max = e.max, tip = e.tip })
	local function nudge(d)
		if (MS.shiftDown()) then d = d * 10 end
		local v = clampEntry(e, (e.get() or 0) + d * (e.step or 0.1))
		e.set(v)
	end
	button(holder, lw, y, ROW, ROW, "-", function() nudge(-1) end, { tip = "Decrease (Shift: x10)" })
	field(holder, lw + ROW + GAP, y, w - lw - ROW * 2 - GAP * 2, ROW, MS.fmt(e.get()), { numeric = true, live = e.get }, function(s)
		local v = tonumber(s)
		if (v) then e.set(clampEntry(e, v)) end
	end)
	button(holder, w - ROW, y, ROW, ROW, "+", function() nudge(1) end, { tip = "Increase (Shift: x10)" })
end

---label | X [  ] Y [  ] Z [  ]   (drag the letters to scrub)
local function vec3Row(holder, y, w, e)
	local lw = floor(w * 0.26)
	label(holder, 4, y, lw - 4, ROW, e.label, LEFTMID, 0.5)
	local cw = (w - lw) / 3
	local letters = e.letters or { "X", "Y", "Z" }
	for k = 1, 3 do
		local x = lw + (k - 1) * cw
		local let = holder:addChild({ pos = { x, y }, size = { 16, ROW }, interactive = true,
			bgColor = C.axis[k], hoverColor = C.light, pressedColor = C.darkest, shapeType = ROUNDED, rounded = 3 })
		let:addAdaptedText(false, letters[k], nil, nil, 4, CENTERMID, 0.45)
		scrub(let, function() return e.get(k) end, function(v) e.set(k, v) end, e.step or 0.1, { tip = e.tip })
		field(holder, x + 17, y, cw - 19, ROW, MS.fmt(e.get(k)), { numeric = true, live = function() return e.get(k) end }, function(s)
			local v = tonumber(s)
			if (v) then e.set(k, v) end
		end)
	end
end

local function sliderRow(holder, y, w, e)
	local lw = floor(w * 0.36)
	label(holder, 4, y, lw - 4, ROW, e.label, LEFTMID, 0.5)
	local sh = holder:addChild({ pos = { lw, y }, size = { w - lw, ROW } })
	local s = TBMenu:spawnSlider2(sh, nil, e.get() or 0, {
		minValue = e.min or 0, maxValue = e.max or 255, decimal = e.decimal or 0, darkerMode = true,
		minValueDisp = e.minDisp, maxValueDisp = e.maxDisp
	}, function(val) e.set(val) end, nil, nil, e.labelFn)
	if (e.tip) then
		sh:addMouseHandlers(nil, nil, function() UI.setTip(e.tip, sh) end)
	end
	return s
end

local function toggleRow(holder, y, w, e)
	local view = holder:addChild({ pos = { 0, y }, size = { ROW, ROW } })
	TBMenu:spawnToggle(view, 0, 0, ROW, ROW, e.get() and true or false, function(val)
		e.set(val == true or val == 1)
	end)
	local lab = holder:addChild({ pos = { ROW + 6, y }, size = { w - ROW - 6, ROW }, interactive = e.tip ~= nil, bgColor = C.clear, hoverColor = C.clear, pressedColor = C.clear })
	lab:addAdaptedText(false, e.label, nil, nil, 4, LEFTMID, 0.5)
	if (e.tip) then
		lab:addMouseHandlers(nil, nil, function() UI.setTip(e.tip, lab) end)
	end
end

local function textRow(holder, y, w, e)
	local lw = floor(w * 0.36)
	label(holder, 4, y, lw - 4, ROW, e.label, LEFTMID, 0.5)
	field(holder, lw, y, w - lw, ROW, e.get() or "", { align = LEFTMID, placeholder = e.placeholder, enter = e.enter }, function(s) e.set(s) end)
end

local function choiceRow(holder, y, w, e)
	local lw = e.label and floor(w * 0.36) or 0
	if (e.label) then label(holder, 4, y, lw - 4, ROW, e.label, LEFTMID, 0.5) end
	local cur = e.get()
	local items = {}
	for _, opt in ipairs(e.options) do
		table.insert(items, { opt[2], function()
			e.set(opt[1])
			UI.requestRefresh()
		end, active = tostring(cur) == tostring(opt[1]), tip = e.tip })
	end
	buttonRow(holder, lw, y, w - lw, ROW, items)
end

local function swatchesRow(holder, y, w, e)
	local perRow = 8
	local sw = (w - GAP * (perRow - 1)) / perRow
	for i, c in ipairs(MS.PALETTE) do
		local r = floor((i - 1) / perRow)
		local col = (i - 1) % perRow
		local s = holder:addChild({
			pos = { col * (sw + GAP), y + r * (ROW + GAP) }, size = { sw, ROW },
			interactive = true, shapeType = ROUNDED, rounded = 3,
			bgColor = { c[1], c[2], c[3], 1 }, hoverColor = { math.min(1, c[1] + 0.15), math.min(1, c[2] + 0.15), math.min(1, c[3] + 0.15), 1 },
			pressedColor = { c[1] * 0.7, c[2] * 0.7, c[3] * 0.7, 1 }
		})
		s:addMouseHandlers(nil, function() e.set(c) end, function() UI.setTip("Click to paint the selection with this color", s) end)
	end
end

---Renders one row entry. Kinds: header hint num vec3 slider toggle text choice buttons swatches custom
---Folded sections are remembered in settings
function UI.isFolded(id)
	local f = MS.settings.folded
	return f and f[id] == true
end

function UI.setFolded(id, folded)
	MS.settings.folded = MS.settings.folded or {}
	MS.settings.folded[id] = folded or false
	MS.saveSettings()
	UI.requestRefresh()
end

---Builds one long entry list out of foldable sections: { { id, title, fn -> entries }, ... }
function UI.sections(list)
	local out = {}
	for _, sec in ipairs(list) do
		table.insert(out, { kind = "fold", id = sec[1], label = sec[2] })
		if (not UI.isFolded(sec[1])) then
			for _, e in ipairs(sec[3]() or {}) do table.insert(out, e) end
		end
	end
	return out
end

function UI.renderEntry(holder, y, e, w)
	local k = e.kind
	if (k == "fold") then
		local folded = UI.isFolded(e.id)
		button(holder, 0, y + 1, w, ROW - 1, (folded and "+   " or "-   ") .. e.label, function()
			UI.setFolded(e.id, not folded)
		end, { align = LEFTMID, color = C.darkest, scale = 0.5, tip = folded and "Click to open this section" or "Click to fold this section away" })
	elseif (k == "header") then
		local bar = holder:addChild({ pos = { 0, y + 3 }, size = { w, ROW - 4 }, bgColor = C.darkest, shapeType = ROUNDED, rounded = 3 })
		bar:addAdaptedText(false, e.label, 6, nil, UI.TITLE_FONT, LEFTMID, 0.5)
	elseif (k == "hint") then
		hint(holder, 0, y, w, (e.rows or 1) * (ROW + GAP) - GAP, e.label, e.scale or 0.45)
	elseif (k == "num") then
		numRow(holder, y, w, e)
	elseif (k == "vec3") then
		vec3Row(holder, y, w, e)
	elseif (k == "slider") then
		sliderRow(holder, y, w, e)
	elseif (k == "toggle") then
		toggleRow(holder, y, w, e)
	elseif (k == "text") then
		textRow(holder, y, w, e)
	elseif (k == "choice") then
		choiceRow(holder, y, w, e)
	elseif (k == "buttons") then
		buttonRow(holder, 0, y, w, ROW, e.items)
	elseif (k == "swatches") then
		swatchesRow(holder, y, w, e)
	elseif (k == "custom") then
		e.render(holder, y, w)
	end
end

---Scrolling list of entries filling `height`. Only rows in view are created;
---the mouse wheel, the scroll bar (drag the thumb or click the track) move it.
---UI.pages[pageKey] holds the first visible entry.
local SCROLL_W = 10
UI.scrollAreas = UI.scrollAreas or {}
function UI.paged(parent, topY, height, entries, pageKey, render)
	render = render or UI.renderEntry
	local fullW = parent.size.w - PAD * 2
	local holder = parent:addChild({ pos = { PAD, topY }, size = { fullW, math.max(ROW, height) } })
	local unit = ROW + GAP
	local heights, total = {}, 0
	for i, e in ipairs(entries) do
		heights[i] = (e.rows or 1) * unit
		total = total + heights[i]
	end
	local avail = holder.size.h + GAP
	local scrolling = total > avail
	local w = scrolling and (fullW - SCROLL_W - GAP * 2) or fullW
	-- Highest first entry that still fills the view to the bottom
	local maxFirst, acc = #entries, 0
	for i = #entries, 1, -1 do
		acc = acc + heights[i]
		if (acc > avail) then break end
		maxFirst = i
	end
	maxFirst = math.max(1, maxFirst)
	local first = MS.clamp(UI.pages[pageKey] or 1, 1, maxFirst)
	UI.pages[pageKey] = first

	local y, shown = 0, 0
	for i = first, #entries do
		if (y + heights[i] > avail and i > first) then break end
		render(holder, y, entries[i], w)
		y = y + heights[i]
		shown = shown + 1
	end

	if (scrolling) then
		table.insert(UI.scrollAreas, { el = holder, key = pageKey, max = maxFirst, page = math.max(1, shown - 1) })
		local th = holder.size.h
		local track = holder:addChild({
			pos = { fullW - SCROLL_W, 0 }, size = { SCROLL_W, th },
			bgColor = C.darkest, shapeType = ROUNDED, rounded = 4, interactive = true
		})
		local before = 0
		for i = 1, first - 1 do before = before + heights[i] end
		local thumbH = math.max(24, floor(th * avail / total))
		local travel = th - thumbH
		local thumbY = maxFirst > 1 and floor(travel * (first - 1) / (maxFirst - 1)) or 0
		track:addMouseHandlers(nil, function(_, _, my)
			-- Click above / below the thumb: one screen up / down
			local dir = (my or 0) < track.pos.y + thumbY and -1 or 1
			UI.pages[pageKey] = MS.clamp(first + dir * math.max(1, shown - 1), 1, maxFirst)
			UI.requestRefresh()
		end)
		local thumb = track:addChild({
			pos = { 1, thumbY }, size = { SCROLL_W - 2, thumbH },
			bgColor = C.lightest, hoverColor = { 1, 1, 1, 1 }, pressedColor = C.light,
			shapeType = ROUNDED, rounded = 3, interactive = true
		})
		thumb:addMouseHandlers(function(_, _, my)
			UI.startPointerDrag({ kind = "scroll", key = pageKey, max = maxFirst, y0 = my or MS.G.mouseY or 0, first0 = first, travel = math.max(1, travel) })
		end, nil, function() UI.setTip("Drag to scroll (or use the mouse wheel)", thumb) end)
	end
	return holder
end

---Mouse wheel over a panel. Returns true when the panel used it.
function UI.handleWheel(x, y, btn)
	for i = #UI.scrollAreas, 1, -1 do
		local a = UI.scrollAreas[i]
		if (not a.el or a.el.destroyed) then
			table.remove(UI.scrollAreas, i)
		elseif (inside(a.el, x, y)) then
			local cur = UI.pages[a.key] or 1
			local nv = MS.clamp(cur + (btn == 4 and -3 or 3), 1, a.max)
			if (nv ~= cur) then
				UI.pages[a.key] = nv
				UI.requestRefresh()
			end
			return true
		end
	end
	-- Over a panel but not over a list: still don't zoom the camera
	return true
end

---------------------------------------------------------------------------
-- Pointer drags that outlive the element they started on (scroll thumbs,
-- moving / resizing panels). Followed every frame from UI.tick.
---------------------------------------------------------------------------

function UI.startPointerDrag(d)
	d.mx0, d.my0 = MS.G.mouseX or MOUSE_X or 0, MS.G.mouseY or MOUSE_Y or 0
	if (d.y0 == nil) then d.y0 = d.my0 end
	UI.pointerDrag = d
	pcall(disable_mouse_camera_movement)
end

function UI.endPointerDrag()
	local d = UI.pointerDrag
	if (not d) then return false end
	UI.pointerDrag = nil
	pcall(enable_mouse_camera_movement)
	if (d.kind == "layout" and d.rect) then
		MS.settings.layout = MS.settings.layout or {}
		MS.settings.layout[d.target] = { x = floor(d.rect[1]), y = floor(d.rect[2]), w = floor(d.rect[3]), h = floor(d.rect[4]) }
		MS.saveSettings()
		if (d.target == "toolbar") then UI.buildToolbar()
		elseif (d.target == "status") then UI.buildStatus()
		else UI.buildDock(d.target) end
	end
	return true
end

local function followPointerDrag()
	local d = UI.pointerDrag
	if (not d) then return end
	local mx, my = MS.G.mouseX or MOUSE_X or d.mx0, MS.G.mouseY or MOUSE_Y or d.my0
	if (d.kind == "scroll") then
		local nv = MS.clamp(d.first0 + floor((my - d.y0) / d.travel * (d.max - 1) + 0.5), 1, d.max)
		if (nv ~= UI.pages[d.key]) then
			UI.pages[d.key] = nv
			UI.needRefresh = true
		end
		return
	end
	-- layout: move or resize, drawn as an outline until you let go
	local r0 = d.rect0
	local dx, dy = mx - d.mx0, my - d.my0
	local r
	if (d.mode == "move") then
		r = { MS.clamp(r0[1] + dx, 0, WIN_W - math.min(r0[3], 80)), MS.clamp(r0[2] + dy, 0, WIN_H - 24), r0[3], r0[4] }
	else
		r = { r0[1], r0[2], MS.clamp(r0[3] + dx, 200, WIN_W - r0[1]), MS.clamp(r0[4] + dy, 120, WIN_H - r0[2]) }
	end
	d.rect = r
	set_color(1, 0.85, 0.3, 0.14)
	pcall(draw_quad, r[1], r[2], r[3], r[4])
	set_color(1, 0.85, 0.3, 0.95)
	pcall(draw_quad, r[1], r[2], r[3], 2)
	pcall(draw_quad, r[1], r[2] + r[4] - 2, r[3], 2)
	pcall(draw_quad, r[1], r[2], 2, r[4])
	pcall(draw_quad, r[1] + r[3] - 2, r[2], 2, r[4])
end
UI.followPointerDrag = followPointerDrag

---A small handle that starts moving / resizing a piece of UI
local function layoutGrip(parent, x, y, w, h, text, target, mode, rectFn, tip)
	local g = parent:addChild({
		pos = { x, y }, size = { w, h }, interactive = true,
		bgColor = C.darkest, hoverColor = C.light, pressedColor = C.lightest,
		shapeType = ROUNDED, rounded = 3
	})
	g:addAdaptedText(false, text, nil, nil, 4, CENTERMID, 0.45)
	g:addMouseHandlers(function()
		UI.startPointerDrag({ kind = "layout", target = target, mode = mode, rect0 = rectFn() })
	end, nil, function() UI.setTip(tip, g) end)
	return g
end
UI.layoutGrip = layoutGrip

function UI.resetLayout()
	MS.settings.layout = {}
	MS.saveSettings()
	UI.close()
	UI.open()
	MS.toast("Panels are back in their default places")
end

---Sub tab strip; returns the next free y
local function subTabs(parent, y, key, items)
	local w = parent.size.w - PAD * 2
	local list = {}
	for _, it in ipairs(items) do
		table.insert(list, { it[2], function()
			UI.sub[key] = it[1]
			UI.pages[key .. ":" .. it[1]] = 1
			UI.requestRefresh()
		end, active = UI.sub[key] == it[1], tip = it[3] })
	end
	buttonRow(parent, PAD, y, w, ROW, list)
	return y + ROW + GAP * 3
end

---------------------------------------------------------------------------
-- Entry builders for objects
---------------------------------------------------------------------------

local POSF = { "pos_x", "pos_y", "pos_z" }
local ROTF = { "rot_x", "rot_y", "rot_z" }
local DIMF = { "dims_x", "dims_y", "dims_z" }

local function prim()
	return MS.primary and MS.objs[MS.primary]
end

local function envTargets(f)
	local list = {}
	for _, idx in ipairs(MS.selList()) do
		local m = MS.meta[idx]
		if (not (m and m.tri and MS.tris[m.tri]) or MS.TRI_PROPS[f]) then
			table.insert(list, idx)
		end
	end
	return list
end

local function envGet(f)
	return function()
		local o = prim()
		return o and o[f]
	end
end

local function envSet(f, title)
	return function(v)
		MS.pushUndo(title or "Edit", "env:" .. f)
		for _, idx in ipairs(envTargets(f)) do
			MS.objSet(idx, f, v)
		end
	end
end

local function envNum(lbl, f, step, o)
	o = o or {}
	return { kind = "num", label = lbl, get = envGet(f), set = envSet(f, lbl), step = step, min = o.min, max = o.max, int = o.int, tip = o.tip }
end

local function envVec(lbl, fields, step, tip)
	return {
		kind = "vec3", label = lbl, step = step, tip = tip,
		get = function(k) local o = prim(); return o and o[fields[k]] end,
		set = function(k, v)
			MS.pushUndo(lbl, "env:" .. fields[k])
			for _, idx in ipairs(envTargets(fields[k])) do MS.objSet(idx, fields[k], v) end
		end
	}
end

local function envToggle(lbl, f, tip)
	return { kind = "toggle", label = lbl, tip = tip, get = envGet(f), set = function(v)
		MS.pushUndo(lbl)
		for _, idx in ipairs(envTargets(f)) do MS.objSet(idx, f, v) end
	end }
end

local function colorSlider(lbl, f)
	return { kind = "slider", label = lbl, min = 0, max = 255,
		get = function() local o = prim(); return o and (o[f] or 0) * 255 or 0 end,
		set = function(v)
			MS.pushUndo("Color", "env:" .. f)
			for _, idx in ipairs(envTargets(f)) do MS.objSet(idx, f, v / 255) end
		end }
end

local function trigEntries(get, set)
	local function n(lbl, f, tip, step)
		return { kind = "num", label = lbl, step = step or 1, int = true, tip = tip, get = function() return get(f) end, set = function(v) set(f, v) end }
	end
	local function s(lbl, f)
		return { kind = "slider", label = lbl, min = 0, max = 255,
			get = function() return (get(f) or 0) * 255 end, set = function(v) set(f, v / 255) end }
	end
	return {
		{ kind = "hint", label = "Triggers fire when something touches this. Use the ID + mask to choose what reacts.", rows = 2 },
		n("Trigger ID", "trig_id", "Bit that identifies this as a trigger source"),
		n("Trigger mask", "trig_mask", "Which trigger IDs this reacts to (bitmask)"),
		n("Action", "trig_action", "What happens on touch (engine action number)"),
		n("Sound", "trig_sound", "Sound effect number to play on touch"),
		s("Color R", "trig_color_r"), s("Color G", "trig_color_g"), s("Color B", "trig_color_b"), s("Color A", "trig_color_a"),
		n("Score", "trig_score", "Points given (can be negative)", 10),
		{ kind = "toggle", label = "Score only once", get = function() return get("trig_scoreonce") end, set = function(v) set("trig_scoreonce", v) end }
	}
end

---Every plain field the engine knows, as a fallback page for anything not covered elsewhere
local function shapeChoice(get, set)
	return { kind = "choice", label = "Shape", get = get, set = set,
		options = { { 1, "Box" }, { 0, "Sphere" }, { 2, "Cylinder" } }, tip = "Change the collision shape" }
end

local function objTransformEntries()
	local o = prim()
	local entries = {
		{ kind = "vec3", label = "Position", step = 0.1, tip = "Drag the letters to slide, or type exact values",
			get = function(k) local p = prim(); return p and p[POSF[k]] end,
			set = function(k, v)
				local p = prim()
				if (not p) then return end
				local d = { 0, 0, 0 }
				d[k] = v - (p[POSF[k]] or 0)
				MS.pushUndo("Move", "env:pos" .. k)
				MS.translateSelection(d)
			end },
		(function()
			-- Turning a parent swings its children around with it
			local e = envVec("Rotation", ROTF, 5, "Degrees. Drag the letters or type a value")
			local set = e.set
			e.set = function(k, v) MS.withChildrenFollowing(set, k, v) end
			return e
		end)(),
	}
	if (o.type == 0) then
		table.insert(entries, envNum("Radius", "dims_x", 0.05, { min = 0.01 }))
	elseif (o.type == 2) then
		table.insert(entries, envNum("Radius", "dims_x", 0.05, { min = 0.01 }))
		table.insert(entries, envNum("Length", "dims_y", 0.1, { min = 0.01 }))
	else
		table.insert(entries, envVec("Size", DIMF, 0.1, "Full width / depth / height"))
	end
	table.insert(entries, shapeChoice(envGet("type"), function(v)
		MS.pushUndo("Change shape")
		for _, idx in ipairs(envTargets("type")) do
			local ob = MS.objs[idx]
			local old = ob.type
			MS.objSet(idx, "type", v)
			-- Keep the object roughly the same size when switching shapes
			if (old == 1 and v ~= 1) then
				MS.objSet(idx, "dims_x", math.max(ob.dims_x or 1, ob.dims_y or 1) / 2)
				if (v == 2) then MS.objSet(idx, "dims_y", ob.dims_z or 1) end
			elseif (old ~= 1 and v == 1) then
				local r = ob.dims_x or 0.5
				MS.objSet(idx, "dims_x", r * 2)
				MS.objSet(idx, "dims_y", r * 2)
				MS.objSet(idx, "dims_z", old == 2 and (ob.dims_y or 1) + r * 2 or r * 2)
			end
		end
	end))
	table.insert(entries, { kind = "buttons", items = {
		{ "Drop to floor", MS.dropToFloor, tip = "Rest the selection on the ground" },
		{ "Snap to grid", MS.snapSelectionToGrid, tip = "Round positions to the grid step" },
		{ "Reset rotation", MS.resetRotation }
	} })
	table.insert(entries, { kind = "buttons", items = {
		{ "Duplicate", MS.duplicateSelected, tip = "Ctrl+D" },
		{ "Focus camera", MS.focusSelection, tip = "F" },
		{ "Delete", MS.deleteSelected, tip = "Delete key" }
	} })
	return entries
end

local function triEntries(id)
	local t = MS.tris[id]
	local function vtx(key, lbl)
		return { kind = "vec3", label = lbl, step = 0.1,
			tip = "Corner position. You can also drag the white corner dots in the 3D view",
			get = function(k) return MS.tris[id] and MS.tris[id][key][k] end,
			set = function(k, v)
				local tt = MS.tris[id]
				if (not tt) then return end
				MS.pushUndo("Move corner", "tri:" .. id .. key .. k)
				tt[key][k] = v
				MS.triBuild(id)
			end }
	end
	return {
		{ kind = "hint", label = "Triangle made from " .. #t.objs .. " box slices. It plays like a real triangle in-game, no script needed.", rows = 2 },
		{ kind = "vec3", label = "Center", step = 0.1,
			get = function(k) return MS.tris[id] and MS.triCentroid(id)[k] end,
			set = function(k, v)
				if (not MS.tris[id]) then return end
				local d = { 0, 0, 0 }
				d[k] = v - MS.triCentroid(id)[k]
				MS.pushUndo("Move triangle", "tri:c" .. id .. k)
				MS.translateSelection(d)
			end },
		vtx("a", "Corner A"), vtx("b", "Corner B"), vtx("c", "Corner C"),
		{ kind = "num", label = "Thickness", step = 0.05, min = 0.01,
			get = function() return MS.tris[id] and MS.tris[id].thick end,
			set = function(v)
				MS.pushUndo("Thickness", "tri:t" .. id)
				MS.tris[id].thick = v
				MS.triBuild(id)
			end },
		{ kind = "num", label = "Smoothness", step = 1, int = true, min = 1, max = 64,
			tip = "Number of slices. More = smoother edges but uses more objects",
			get = function() return MS.tris[id] and MS.tris[id].slices end,
			set = function(v)
				MS.pushUndo("Smoothness", "tri:s" .. id)
				MS.tris[id].slices = v
				MS.triBuild(id)
			end },
		{ kind = "choice", label = "Flat edge", tip = "Which edge is perfectly smooth (the others are slightly stepped)",
			get = function() return MS.tris[id] and MS.tris[id].smooth or "longest" end,
			set = function(v)
				MS.pushUndo("Flat edge")
				MS.tris[id].smooth = v
				MS.triBuild(id)
			end,
			options = { { "longest", "Longest" }, { "ab", "A-B" }, { "bc", "B-C" }, { "ca", "C-A" } } },
		{ kind = "buttons", items = {
			{ "Drop to floor", MS.dropToFloor },
			{ "Snap corners", MS.snapSelectionToGrid, tip = "Round corner positions to the grid" },
			{ "To plain boxes", function() MS.triDetach(id) end, tip = "Stop treating the slices as one triangle" }
		} },
		{ kind = "buttons", items = {
			{ "Duplicate", MS.duplicateSelected },
			{ "Focus camera", MS.focusSelection },
			{ "Delete", MS.deleteSelected }
		} }
	}
end

local function objLookEntries()
	local entries = {
		{ kind = "swatches", rows = 2, set = function(c)
			MS.pushUndo("Paint")
			for _, idx in ipairs(envTargets("color_r")) do
				MS.objSet(idx, "color_r", c[1])
				MS.objSet(idx, "color_g", c[2])
				MS.objSet(idx, "color_b", c[3])
			end
		end },
		colorSlider("Red", "color_r"), colorSlider("Green", "color_g"), colorSlider("Blue", "color_b"),
		colorSlider("Opacity", "color_a"),
		envToggle("Visible in game", "visible", "Invisible objects still collide - good for hidden walls"),
		{ kind = "buttons", items = {
			{ "Random color", function()
				MS.pushUndo("Random color")
				for _, idx in ipairs(envTargets("color_r")) do
					MS.objSet(idx, "color_r", math.random())
					MS.objSet(idx, "color_g", math.random())
					MS.objSet(idx, "color_b", math.random())
				end
			end },
			{ "Copy color", function()
				local o = prim()
				if (o) then
					UI.colorClip = { o.color_r, o.color_g, o.color_b, o.color_a }
					MS.toast("Color copied")
				end
			end },
			{ "Paste color", function()
				local c = UI.colorClip
				if (not c) then MS.toast("Copy a color first") return end
				MS.pushUndo("Paste color")
				for _, idx in ipairs(envTargets("color_r")) do
					MS.objSet(idx, "color_r", c[1])
					MS.objSet(idx, "color_g", c[2])
					MS.objSet(idx, "color_b", c[3])
					MS.objSet(idx, "color_a", c[4])
				end
			end }
		} }
	}
	return entries
end

local function materialButtons(from, to)
	local items = {}
	for i = from, to do
		local mat = MS.MATERIALS[i]
		if (mat) then
			table.insert(items, { mat.name, function()
				MS.pushUndo("Material " .. mat.name)
				for _, idx in ipairs(envTargets("hardness")) do
					MS.objSet(idx, "hardness", mat.hardness)
					MS.objSet(idx, "friction", mat.friction)
					MS.objSet(idx, "bounce", mat.bounce)
				end
				MS.toast("Applied " .. mat.name)
			end, tip = "Hardness " .. mat.hardness .. ", friction " .. mat.friction .. ", bounce " .. mat.bounce })
		end
	end
	return items
end

local function objPhysicsEntries()
	local isTri = MS.selSingleTri() ~= nil
	return {
		envToggle("Static (fixed in place)", "static", "Static objects never move. Turn off for things that fall and can be pushed"),
		{ kind = "header", label = "Material presets" },
		{ kind = "buttons", items = materialButtons(1, 4) },
		{ kind = "buttons", items = materialButtons(5, 7) },
		envNum(isTri and "Mass (per slice)" or "Mass", "mass", 0.1, { min = 0, tip = "Only matters for non-static objects" }),
		envNum("Hardness", "hardness", 0.05, { min = 0 }),
		envNum("Friction", "friction", 0.05, { min = 0, tip = "0 = ice, higher = grippy" }),
		envNum("Bounce", "bounce", 0.05, { min = 0, tip = "0 = dead, 1 = very bouncy" }),
		envVec("Start force", { "force_x", "force_y", "force_z" }, 1, "Push applied at the start of the match")
	}
end

local function objThrustEntries()
	return {
		{ kind = "hint", label = "Thrust keeps pushing the object for a number of frames - make rockets, moving platforms and launchers.", rows = 2 },
		envNum("Thrust frames", "thrust_frames", 10, { int = true, min = 0 }),
		envVec("Thrust", { "thrust_x", "thrust_y", "thrust_z" }, 1, "Force per frame"),
		envToggle("Relative to object", "thrust_relative", "On: direction turns with the object. Off: world direction")
	}
end

local function objTriggerEntries()
	return trigEntries(function(f) local o = prim(); return o and o[f] end, function(f, v)
		MS.pushUndo("Trigger", "env:" .. f)
		for _, idx in ipairs(envTargets(f)) do MS.objSet(idx, f, v) end
	end)
end

local function objInfoEntries()
	local id = MS.selSingleTri()
	local n = MS.selCount()
	local entries = {
		{ kind = "text", label = "Name", placeholder = "Give it a name",
			get = function()
				if (id) then return MS.tris[id].name or "" end
				local m = MS.meta[MS.primary]
				return m and m.name or ""
			end,
			set = function(s)
				if (id) then MS.tris[id].name = s ~= "" and s or nil
				elseif (MS.meta[MS.primary]) then MS.meta[MS.primary].name = s ~= "" and s or nil end
				MS.changed = true
			end },
		{ kind = "text", label = "Group", placeholder = "e.g. Walls",
			get = function() local m = MS.meta[MS.primary]; return m and m.group or "" end,
			set = function(s)
				for _, idx in ipairs(MS.selList()) do
					MS.meta[idx] = MS.meta[idx] or {}
					MS.meta[idx].group = s ~= "" and s or nil
				end
				MS.changed = true
			end },
		{ kind = "buttons", items = {
			{ "Select group", function()
				local m = MS.meta[MS.primary]
				local g = m and m.group
				if (not g) then MS.toast("Give the selection a group name first") return end
				MS.sel = {}
				for idx, mm in pairs(MS.meta) do
					if (mm.group == g and MS.objs[idx]) then MS.sel[idx] = true end
				end
				UI.requestRefresh()
				MS.toast("Selected group \"" .. g .. "\"")
			end, tip = "Select every object in the same group" },
			{ "Lock", function()
				for _, idx in ipairs(MS.selList()) do
					MS.meta[idx] = MS.meta[idx] or {}
					MS.meta[idx].locked = true
				end
				MS.selClear()
				MS.toast("Locked - it can't be clicked in 3D now. Unlock it from the list")
			end, tip = "Locked objects ignore clicks in the 3D view so you can't move them by accident" }
		} },
		{ kind = "header", label = "Parent & children" },
		{ kind = "hint", rows = 2, label = MS.hierSummary() },
		{ kind = "buttons", items = {
			{ "Pick parent...", UI.startParentPick, tip = "Then click the object (in 3D or the Scene list) that the selection should hang from" },
			{ "Parent to last", function() MS.parentSelection() end, tip = "P: everything selected becomes a child of the object you clicked last (yellow outline)" },
			{ "Unparent", MS.unparentSelection, tip = "Shift+P: detach from the parent. Nothing moves" }
		} },
		{ kind = "buttons", items = {
			{ "Select parent", MS.selectParent, tip = "[" },
			{ "Select children", function() MS.selectChildren(false) end, tip = "]" },
			{ "Select branch", function() MS.selectChildren(true) end, tip = "Shift+]: this plus every child, grandchild..." }
		} },
		{ kind = "buttons", items = {
			{ "Release children", MS.releaseChildren, tip = "The direct children move up one level. Nothing moves in the world" },
			{ "Delete branch", MS.deleteBranch, tip = "Delete the selection AND all of its children" },
			{ "Group to parent", MS.groupToParent, tip = "Make everything in this object's group a child of it" }
		} },
		{ kind = "hint", rows = 2, label = n .. " selected" .. (MS.primary and (" | engine index " .. MS.primary) or "") }
	}
	return entries
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

---Scene list rows as a tree: { idx, key, tri, name, tag, depth, kids, uid }.
---While searching it's a flat list of matches instead.
local function outlinerItems()
	local items = {}
	local filter = (UI.filter or ""):lower()
	local H = MS.hier()
	local function item(key, depth)
		local kind, n = MS.parseNodeKey(key)
		local d = MS.nodeData(key)
		return {
			idx = MS.nodeRep(key), key = key, tri = kind == "t" and n or nil, name = MS.nodeName(key),
			tag = kind == "t" and "Tri" or (MS.SHAPES[MS.objs[n].type] or "?"):sub(1, 3),
			depth = depth, kids = H.children[key] and #H.children[key] or 0, uid = d and d.uid,
			parentName = H.parent[key] and MS.nodeName(H.parent[key]) or nil
		}
	end
	if (filter ~= "") then
		for _, key in ipairs(H.keys) do
			local it = item(key, 0)
			if (it.name:lower():find(filter, 1, true)) then table.insert(items, it) end
		end
		return items, H
	end
	local function walk(key, depth)
		local it = item(key, depth)
		table.insert(items, it)
		if (it.kids > 0 and not (it.uid and UI.collapsed[it.uid])) then
			for _, c in ipairs(H.children[key]) do walk(c, depth + 1) end
		end
	end
	for _, key in ipairs(H.roots) do walk(key, 0) end
	return items, H
end

function UI.startParentPick()
	if (MS.selCount() == 0) then
		MS.toast("Select the object(s) that should become children first")
		return
	end
	UI.parentPick = true
	MS.toast("Now click the new PARENT - in the 3D view or the Scene list (Esc cancels)")
	UI.requestRefresh()
end

function UI.finishParentPick(idx)
	UI.parentPick = nil
	local key = MS.nodeKey(idx)
	if (key) then MS.parentSelection(key) end
	UI.requestRefresh()
end

---Folds or unfolds every branch in the Scene list
function UI.toggleAllBranches()
	local H = MS.hier()
	local anyOpen = false
	for key in pairs(H.children) do
		local d = MS.nodeData(key)
		if (d and d.uid and not UI.collapsed[d.uid]) then anyOpen = true end
	end
	UI.collapsed = {}
	if (anyOpen) then
		for key in pairs(H.children) do
			local uid = MS.ensureUid(key)
			if (uid) then UI.collapsed[uid] = true end
		end
	end
	UI.requestRefresh()
end

---Left dock: add buttons + the list of everything in the mod
function UI.tabScene(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	buttonRow(pane, PAD, y, w, ROW, {
		{ "Box", function() MS.addPrimitive("box") end, tip = "Add a box where the camera is looking" },
		{ "Sphere", function() MS.addPrimitive("sphere") end },
		{ "Cylinder", function() MS.addPrimitive("cylinder") end }
	})
	y = y + ROW + GAP
	buttonRow(pane, PAD, y, w, ROW, {
		{ "Triangle", function() MS.addTriangle("fin") end, tip = "Add a triangle - drag its corner dots to reshape it" },
		{ "Ramp", function() MS.addTriangle("ramp") end, tip = "Add a wedge-shaped ramp" },
		{ "Duplicate", MS.duplicateSelected, tip = "Ctrl+D", disabled = MS.selCount() == 0 },
		{ "Delete", MS.deleteSelected, tip = "Delete key", disabled = MS.selCount() == 0 }
	})
	y = y + ROW + GAP
	local none = MS.selCount() == 0
	buttonRow(pane, PAD, y, w, ROW, {
		{ "Parent", function() MS.parentSelection() end, tip = "P: select the children, Shift+click the parent last, then press this", disabled = none },
		{ UI.parentPick and "Click parent" or "Pick parent", function()
			if (UI.parentPick) then
				UI.parentPick = nil
				UI.requestRefresh()
			else
				UI.startParentPick()
			end
		end, tip = "Click this, then click the object the selection should hang from", disabled = none and not UI.parentPick, active = UI.parentPick },
		{ "Unparent", MS.unparentSelection, tip = "Shift+P: detach the selection from its parent. Nothing moves", disabled = none },
		{ "Fold all", UI.toggleAllBranches, tip = "Collapse / expand every branch in the list below" }
	})
	y = y + ROW + GAP * 3

	-- Outliner
	local items = outlinerItems()
	local filtering = (UI.filter or "") ~= ""
	label(pane, PAD, y, w * 0.42, ROW, "Scene (" .. MS.count(MS.objs) .. " objects)", LEFTMID, 0.48)
	field(pane, PAD + w * 0.42, y, w * 0.58, ROW, UI.filter, { align = LEFTMID, placeholder = "Search, then Enter", enter = function() UI.blurFields() end }, function(s)
		UI.filter = s
		UI.pages.outliner = 1
		UI.filterDirty = true
	end)
	y = y + ROW + GAP
	local listH = pane.size.h - y - PAD
	if (#items == 0) then
		hint(pane, PAD, y, w, 80, MS.count(MS.objs) == 0 and "Your mod is empty.\nAdd something with the buttons above or the Create tab." or "No objects match your search.", 0.5)
	else
		local entries = {}
		for _, it in ipairs(items) do
			table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
				local selected = MS.sel[it.idx]
				local m = MS.meta[it.idx] or {}
				local indent = math.min(it.depth, 8) * 10
				local x = indent
				if (it.kids > 0) then
					local folded = it.uid and UI.collapsed[it.uid]
					button(holder, x, ry, 18, ROW, folded and "+" or "-", function()
						local uid = MS.ensureUid(it.key)
						UI.collapsed[uid] = not UI.collapsed[uid] or nil
						UI.requestRefresh()
					end, { tip = (folded and "Show " or "Hide ") .. "the " .. it.kids .. " child" .. (it.kids == 1 and "" or "ren"), scale = 0.5 })
				end
				x = x + 18 + GAP
				local nameText = "[" .. it.tag .. "] " .. it.name
				if (it.kids > 0) then nameText = nameText .. "  (" .. it.kids .. ")" end
				if (filtering and it.parentName) then nameText = nameText .. "  < " .. it.parentName end
				local hidden = MS.isHidden and MS.isHidden(it.idx)
				if (hidden) then nameText = nameText .. "  (hidden)" end
				button(holder, rw - 56 - 44 - GAP, ry, 44, ROW, hidden and "Show" or "Hide", function()
					MS.setNodesHidden({ it.key }, not hidden, true)
				end, { active = hidden, tip = "Hide in the editor only (Ctrl+H). Hidden objects still export and play normally", scale = 0.42 })
				button(holder, x, ry, rw - 56 - 44 - GAP * 2 - x, ROW, nameText, function()
					if (UI.parentPick) then
						UI.finishParentPick(it.idx)
					elseif (MS.shiftDown()) then
						MS.selToggle(it.idx)
					else
						MS.selSet(it.idx)
					end
				end, { active = selected, align = LEFTMID, scale = 0.45,
					tip = UI.parentPick and "Click to make this the parent of the selection" or
						"Click to select, Shift+click to add to the selection. Indented rows are children of the row above" })
				button(holder, rw - 56, ry, 56, ROW, m.locked and "Locked" or "Lock", function()
					local targets = it.tri and MS.tris[it.tri].objs or { it.idx }
					for _, i in ipairs(targets) do
						MS.meta[i] = MS.meta[i] or {}
						MS.meta[i].locked = not m.locked or nil
					end
					UI.requestRefresh()
				end, { active = m.locked, tip = "Locked objects can't be clicked in the 3D view", scale = 0.42 })
			end })
		end
		UI.paged(pane, y, listH, entries, "outliner")
	end
end

---Right dock: everything about the current selection
function UI.tabProperties(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	local triId = MS.selSingleTri()
	if (not prim()) then
		hint(pane, PAD, y, w, 110, "Nothing selected.\n\nClick an object in the world (or in the Scene list) to edit it here.\nShift+click to select several, Shift+drag to box-select.\nPress H for all shortcuts.", 0.5)
		return
	end
	local n = MS.selCount()
	local title = triId and (MS.tris[triId].name or ("Triangle " .. triId)) or (n > 1 and (n .. " objects") or MS.objName(MS.primary))
	label(pane, PAD, y, w, ROW, title, LEFTMID, 0.55, UI.TITLE_FONT)
	y = y + ROW + GAP
	local dist = MS.selectionDistance()
	if (dist) then
		label(pane, PAD, y, w, ROW, "Distance between their centers: " .. MS.fmt(dist), LEFTMID, 0.45)
		y = y + ROW + GAP
	end
	local function withProps(group, entries)
		if (MS.copyProps) then
			local name = group == "all" and "all properties" or group
			table.insert(entries, { kind = "buttons", items = {
				{ "Copy " .. name, function() MS.copyProps(group) end, tip = "Remember these settings from the object you clicked last" .. (group == "all" and " (Ctrl+Shift+C)" or "") },
				{ "Paste" .. (MS.propClip and (" " .. MS.propClip.label) or ""), function() MS.pasteProps() end,
					disabled = not MS.propClip, tip = "Apply the copied settings to everything selected (Ctrl+Shift+V)" }
			} })
		end
		return entries
	end
	local entries = UI.sections({
		{ "obj:transform", triId and "Triangle" or "Transform", function() return triId and triEntries(triId) or objTransformEntries() end },
		{ "obj:look", "Look", function() return withProps("look", objLookEntries()) end },
		{ "obj:physics", "Physics", function() return withProps("physics", objPhysicsEntries()) end },
		{ "obj:thrust", "Thrust", function() return withProps("thrust", objThrustEntries()) end },
		{ "obj:trigger", "Trigger", function() return withProps("trigger", objTriggerEntries()) end },
		{ "obj:info", "Info & parent", function() return withProps("all", objInfoEntries()) end }
	})
	if (n > 1 and not triId) then
		table.insert(entries, 1, { kind = "hint", label = "Editing " .. n .. " objects at once" })
	end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "objects")
end

function UI.tabCreate(pane)
	local g = MS.gen
	local function gnum(lbl, key, step, o)
		o = o or {}
		return { kind = "num", label = lbl, step = step, int = o.int, min = o.min, max = o.max,
			get = function() return g[key] end, set = function(v) g[key] = v end }
	end
	local entries = {
		{ kind = "header", label = "Shapes (appear where the camera looks)" },
		{ kind = "buttons", items = {
			{ "Box", function() MS.addPrimitive("box") end }, { "Sphere", function() MS.addPrimitive("sphere") end },
			{ "Cylinder", function() MS.addPrimitive("cylinder") end }, { "Ball", function() MS.addPrimitive("ball") end, tip = "A bouncy physics ball" }
		} },
		{ kind = "buttons", items = {
			{ "Floor", function() MS.addPrimitive("floor") end }, { "Wall", function() MS.addPrimitive("wall") end },
			{ "Pillar", function() MS.addPrimitive("pillar") end }, { "Platform", function() MS.addPrimitive("platform") end }
		} },
		{ kind = "buttons", items = {
			{ "Triangle", function() MS.addTriangle("fin") end, tip = "Upright triangle" },
			{ "Ramp", function() MS.addTriangle("ramp") end, tip = "Wedge ramp with a smooth slope" },
			{ "Flat triangle", function() MS.addTriangle("flat") end, tip = "Triangle lying on the floor" }
		} },
		{ kind = "toggle", label = "New objects are static", tip = "Static = fixed in place. Turn off to make physics props",
			get = function() return MS.settings.newStatic end, set = function(v) MS.settings.newStatic = v end },
		{ kind = "header", label = "Stairs" },
		gnum("Steps", "stairsSteps", 1, { int = true, min = 1, max = 60 }),
		gnum("Step height", "stairsRise", 0.05, { min = 0.02 }),
		gnum("Step depth", "stairsRun", 0.05, { min = 0.05 }),
		gnum("Width", "stairsWidth", 0.25, { min = 0.1 }),
		{ kind = "buttons", items = { { "Build stairs", MS.genStairs } } },
		{ kind = "header", label = "Arena (walls around the players)" },
		gnum("Size", "arenaSize", 1, { min = 2 }),
		gnum("Wall height", "arenaWall", 0.25, { min = 0.1 }),
		gnum("Wall thickness", "arenaThick", 0.1, { min = 0.05 }),
		{ kind = "buttons", items = { { "Build arena", MS.genArena } } },
		{ kind = "header", label = "Checkerboard floor" },
		gnum("Tiles across", "tilesX", 1, { int = true, min = 1, max = 30 }),
		gnum("Tiles deep", "tilesY", 1, { int = true, min = 1, max = 30 }),
		gnum("Tile size", "tileSize", 0.25, { min = 0.1 }),
		{ kind = "buttons", items = { { "Build checkerboard", MS.genTiles } } },
		{ kind = "header", label = "Block pyramid (physics)" },
		gnum("Levels", "pyramidLevels", 1, { int = true, min = 1, max = 8 }),
		gnum("Block size", "pyramidSize", 0.1, { min = 0.1 }),
		{ kind = "buttons", items = { { "Build pyramid", MS.genPyramid } } },
		{ kind = "header", label = "Curves (arches, curved ramps, tunnels)" },
		{ kind = "num", label = "Radius", step = 0.25, min = 0.2, get = function() return MS.arcGen.radius end, set = function(v) MS.arcGen.radius = v end,
			tip = "Inside radius of the curve" },
		{ kind = "num", label = "Thickness", step = 0.05, min = 0.02, get = function() return MS.arcGen.thick end, set = function(v) MS.arcGen.thick = v end },
		{ kind = "num", label = "Width / height", step = 0.25, min = 0.1, get = function() return MS.arcGen.width end, set = function(v) MS.arcGen.width = v end,
			tip = "How wide the walkway is (or how tall a curved wall is)" },
		{ kind = "num", label = "Pieces", step = 1, int = true, min = 2, max = 72, get = function() return MS.arcGen.segments end, set = function(v) MS.arcGen.segments = v end,
			tip = "More pieces = smoother curve, but more objects" },
		{ kind = "num", label = "Span (degrees)", step = 15, min = 15, max = 360, get = function() return MS.arcGen.span end, set = function(v) MS.arcGen.span = v end,
			tip = "How far round the arch / curved wall goes" },
		{ kind = "buttons", items = {
			{ "Arch", function() MS.genArc("arch") end, tip = "Half-circle over a walkway" },
			{ "Quarter pipe", function() MS.genArc("quarterpipe") end, tip = "Floor that curves up into a wall" },
			{ "Tunnel", function() MS.genArc("tunnel") end, tip = "Full ring to walk through" }
		} },
		{ kind = "buttons", items = {
			{ "Curved wall", function() MS.genArc("curvedwall") end, tip = "Wall bending around - good for round arenas" },
			{ "Spiral stairs", function() MS.genArc("spiral") end, tip = "Steps winding round a pole" }
		} },
		{ kind = "num", label = "Spiral steps", step = 1, int = true, min = 2, max = 80, get = function() return MS.arcGen.spiralSteps end, set = function(v) MS.arcGen.spiralSteps = v end },
		{ kind = "num", label = "Spiral turns", step = 0.25, min = 0.1, max = 6, get = function() return MS.arcGen.spiralTurns end, set = function(v) MS.arcGen.spiralTurns = v end },
		{ kind = "num", label = "Step rise", step = 0.05, min = 0.05, get = function() return MS.arcGen.spiralRise end, set = function(v) MS.arcGen.spiralRise = v end },
		{ kind = "header", label = "Moving obstacles (experimental)" },
		{ kind = "num", label = "Size", step = 0.25, min = 0.2, max = 5, get = function() return MS.moverGen.size end, set = function(v) MS.moverGen.size = v end },
		{ kind = "num", label = "Motor speed", step = 1, min = 0, max = 60, get = function() return MS.moverGen.speed end, set = function(v) MS.moverGen.speed = v end,
			tip = "How fast spinners and turntables turn" },
		{ kind = "num", label = "Motor strength", step = 100, min = 0, get = function() return MS.moverGen.strength end, set = function(v) MS.moverGen.strength = v end,
			tip = "How hard they push - low strength gets stopped by players" },
		{ kind = "buttons", items = (function()
			local items = {}
			for i = 1, 3 do
				local m = MS.MOVERS[i]
				table.insert(items, { m.name, function() MS.genMover(m.id) end, tip = m.tip })
			end
			return items
		end)() },
		{ kind = "buttons", items = (function()
			local items = {}
			for i = 4, #MS.MOVERS do
				local m = MS.MOVERS[i]
				table.insert(items, { m.name, function() MS.genMover(m.id) end, tip = m.tip })
			end
			return items
		end)() },
		{ kind = "hint", rows = 2, scale = 0.42, label = "Built from physics objects joined by links - press Test to watch them move. Fine-tune speed and limits on the Links tab." },
		{ kind = "header", label = "Surface presets (for the selection)" },
		{ kind = "buttons", items = (function()
			local items = {}
			for i, pr in ipairs(MS.SURFACE_PRESETS) do
				table.insert(items, { pr.name, function() MS.applySurfacePreset(i) end, tip = pr.tip })
			end
			return items
		end)() },
		{ kind = "header", label = "Touch triggers (experimental)" },
		{ kind = "buttons", items = (function()
			local items = {}
			for i, pr in ipairs(MS.TRIGGER_PRESETS) do
				table.insert(items, { pr.name, function() MS.applyTriggerPreset(i) end, tip = pr.tip })
			end
			return items
		end)() },
		{ kind = "hint", rows = 2, scale = 0.42, label = "Triggers fire when a player touches the object. Players get put in trigger groups automatically. Check them with Test." },
		{ kind = "header", label = "Selection tools" },
		{ kind = "buttons", items = {
			{ "Align X", function() MS.alignSelection(1) end, tip = "Line up the selection with the last-clicked object" },
			{ "Align Y", function() MS.alignSelection(2) end },
			{ "Align Z", function() MS.alignSelection(3) end }
		} },
		{ kind = "buttons", items = {
			{ "Spread X", function() MS.distributeSelection(1) end, tip = "Space 3+ objects evenly" },
			{ "Spread Y", function() MS.distributeSelection(2) end },
			{ "Spread Z", function() MS.distributeSelection(3) end }
		} },
		{ kind = "buttons", items = {
			{ "Mirror copy X", function() MS.mirrorSelection(1, true) end, tip = "Copy to the other side of the map (flips X)" },
			{ "Mirror copy Y", function() MS.mirrorSelection(2, true) end, tip = "Copy to the other side of the map (flips Y)" },
			{ "Flip in place", function() MS.mirrorSelection(1, false, true) end, tip = "Mirror the selection around its own center" }
		} },
		{ kind = "vec3", label = "Array step", step = 0.25,
			get = function(k) return ({ g.arrayX, g.arrayY, g.arrayZ })[k] end,
			set = function(k, v) if (k == 1) then g.arrayX = v elseif (k == 2) then g.arrayY = v else g.arrayZ = v end end },
		gnum("Array copies", "arrayCount", 1, { int = true, min = 1, max = 100 }),
		{ kind = "buttons", items = { { "Make array", function() MS.arraySelection(g.arrayCount, { g.arrayX, g.arrayY, g.arrayZ }) end, tip = "Repeat the selection in a line" } } },
		gnum("Ring count", "radialCount", 1, { int = true, min = 2, max = 72 }),
		gnum("Ring radius", "radialRadius", 0.25, { min = 0.1 }),
		{ kind = "buttons", items = { { "Make ring", function() MS.radialArraySelection(g.radialCount, g.radialRadius) end, tip = "Repeat the selection around a circle" } } },
		{ kind = "buttons", items = {
			{ "Drop to floor", MS.dropToFloor }, { "Snap to grid", MS.snapSelectionToGrid }, { "Reset rotation", MS.resetRotation }
		} }
	}
	UI.paged(pane, PAD, pane.size.h - PAD * 2, entries, "create")
end

function UI.startLinkPick()
	UI.linkPick = { stage = 1 }
	MS.toast("Click the FIRST object in the 3D view")
end

function UI.finishLinkPick(idx)
	local lp = UI.linkPick
	if (not lp) then return end
	if (lp.stage == 1) then
		lp.first = idx
		lp.stage = 2
		MS.toast("Now click the SECOND object")
		return
	end
	if (idx == lp.first) then
		MS.toast("Pick a different object for the second end")
		return
	end
	UI.linkPick = nil
	UI.createLink(lp.first, idx)
end

function UI.createLink(a, b)
	MS.pushUndo("Link objects")
	local ok, n = pcall(create_mod_envjoint, a, b)
	if (not ok or n == nil) then
		MS.toast("Couldn't link those objects")
		return
	end
	MS.readEJ(n)
	local mid = V.lerp(MS.objPos(a), MS.objPos(b), 0.5)
	MS.ejSet(n, "pos_x", mid[1])
	MS.ejSet(n, "pos_y", mid[2])
	MS.ejSet(n, "pos_z", mid[3])
	MS.ejSel = n
	MS.toast("Linked " .. MS.objName(a) .. " and " .. MS.objName(b))
	UI.requestRefresh()
end

function UI.tabLinks(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	local sel = MS.selList()
	buttonRow(pane, PAD, y, w, ROW, {
		{ "+ Link 2 selected", function()
			local s = MS.selList()
			local _, plain = MS.selSplit()
			if (#plain == 2) then UI.createLink(plain[1], plain[2])
			elseif (#s == 2) then UI.createLink(s[1], s[2])
			else MS.toast("Select exactly 2 objects first (Shift+click)") end
		end, tip = "Join the 2 selected objects with a hinge", disabled = #sel < 2 },
		{ "Pick in 3D...", UI.startLinkPick, tip = "Click two objects in the world to join them" },
		{ "Delete link", function()
			if (MS.ejSel and MS.ejs[MS.ejSel]) then
				MS.pushUndo("Delete link")
				pcall(delete_mod_envjoint, MS.ejSel)
				MS.ejs[MS.ejSel] = nil
				MS.ejSel = nil
				MS.markDirty()
				UI.requestRefresh()
			end
		end, disabled = not (MS.ejSel and MS.ejs[MS.ejSel]) }
	})
	y = y + ROW + GAP * 3

	local keys = MS.sortedKeys(MS.ejs)
	if (#keys == 0) then
		hint(pane, PAD, y, w, 80, MS.count(MS.objs) < 2 and "Links join two objects with a joint (doors, swings, flails).\nAdd at least 2 objects first." or "Links join two objects with a joint (doors, swings, flails).\nSelect 2 objects and press \"Link 2 selected\".", 0.5)
		return
	end
	if (not (MS.ejSel and MS.ejs[MS.ejSel])) then MS.ejSel = keys[1] end
	local listEntries = {}
	for _, j in ipairs(keys) do
		local ej = MS.ejs[j]
		table.insert(listEntries, { kind = "custom", render = function(holder, ry, rw)
			button(holder, 0, ry, rw, ROW, "Link " .. j .. ":  " .. MS.objName(ej.obj1 or -1) .. "  <->  " .. MS.objName(ej.obj2 or -1), function()
				MS.ejSel = j
				UI.requestRefresh()
			end, { active = MS.ejSel == j, align = LEFTMID, scale = 0.45 })
		end })
	end
	local listH = 3 * (ROW + GAP) + ROW
	UI.paged(pane, y, listH, listEntries, "links")
	y = y + listH + GAP * 3

	local j = MS.ejSel
	local function g(f) return function() return MS.ejs[j] and MS.ejs[j][f] end end
	local function s(f, lbl) return function(v) MS.pushUndo(lbl, "ej:" .. f); MS.ejSet(j, f, v) end end
	local function num(lbl, f, step, o)
		o = o or {}
		return { kind = "num", label = lbl, get = g(f), set = s(f, lbl), step = step, min = o.min, int = o.int, tip = o.tip }
	end
	local function vec(lbl, fields, step, tip)
		return { kind = "vec3", label = lbl, step = step, tip = tip,
			get = function(k) return MS.ejs[j] and MS.ejs[j][fields[k]] end,
			set = function(k, v) MS.pushUndo(lbl, "ej:" .. fields[k]); MS.ejSet(j, fields[k], v) end }
	end
	local entries = {
		num("Object 1", "obj1", 1, { int = true, min = 0, tip = "Engine index of the first object" }),
		num("Object 2", "obj2", 1, { int = true, min = 0 }),
		vec("Hinge position", { "pos_x", "pos_y", "pos_z" }, 0.1, "Where the two objects pivot"),
		{ kind = "buttons", items = {
			{ "Put at midpoint", function()
				local ej = MS.ejs[j]
				if (ej and MS.objs[ej.obj1] and MS.objs[ej.obj2]) then
					MS.pushUndo("Link midpoint")
					local mid = V.lerp(MS.objPos(ej.obj1), MS.objPos(ej.obj2), 0.5)
					MS.ejSet(j, "pos_x", mid[1]); MS.ejSet(j, "pos_y", mid[2]); MS.ejSet(j, "pos_z", mid[3])
				end
			end },
			{ "Select both objects", function()
				local ej = MS.ejs[j]
				if (ej) then
					MS.sel = {}
					if (MS.objs[ej.obj1]) then MS.sel[ej.obj1] = true end
					if (MS.objs[ej.obj2]) then MS.sel[ej.obj2] = true end
					MS.primary = ej.obj1
					UI.requestRefresh()
				end
			end }
		} },
		vec("Axis", { "axis_x", "axis_y", "axis_z" }, 0.1, "Direction the hinge turns around"),
		num("Max angle", "histop", 0.1, { tip = "Upper rotation limit" }),
		num("Min angle", "lostop", 0.1, { tip = "Lower rotation limit" }),
		num("Strength", "maxforce", 10, { min = 0 }),
		num("Max speed", "maxvelocity", 1, { min = 0 }),
		num("Hardness", "hardness", 0.05, { min = 0 }),
		num("Bounce", "bounce", 0.05, { min = 0 }),
		num("Joint type", "type", 1, { int = true, min = 0, tip = "Engine joint type number (0 = hinge)" }),
		{ kind = "toggle", label = "Visible", get = g("visible"), set = s("visible", "Link visible") }
	}
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "links:fields")
end

---------------------------------------------------------------------------
-- Players (bodies + joints)
---------------------------------------------------------------------------

local PLAYER_NAMES = { [0] = "Tori", "Uke", "Player 3", "Player 4" }

local function playerRow(pane, y, w, current, onPick)
	local items = {}
	for p = 0, math.max(1, MS.numPlayers) - 1 do
		table.insert(items, { PLAYER_NAMES[p] or ("Player " .. (p + 1)), function() onPick(p) end, active = current == p })
	end
	buttonRow(pane, PAD, y, w, ROW, items)
	return y + ROW + GAP * 2
end

local function partGrid(pane, y, w, names, count, current, onPick, mirrorMap)
	local cols = 3
	local cw = (w - GAP * (cols - 1)) / cols
	for i = 0, count - 1 do
		local r, c = floor(i / cols), i % cols
		button(pane, PAD + c * (cw + GAP), y + r * (ROW - 2 + GAP), cw, ROW - 2, names[i], function() onPick(i) end,
			{ active = current == i, scale = 0.42 })
	end
	return y + math.ceil(count / cols) * (ROW - 2 + GAP) + GAP * 2
end

function UI.selectBody(p, b)
	MS.bodySel = { p = p, b = b }
	UI.pages.players = 1
	UI.requestRefresh()
	MS.toast("Selected " .. (PLAYER_NAMES[p] or "") .. " " .. MS.BODY_NAMES[b])
end

function UI.selectJoint(p, j)
	MS.jointSel = { p = p, j = j }
	UI.pages.joints = 1
	UI.requestRefresh()
	MS.toast("Selected " .. (PLAYER_NAMES[p] or "") .. " " .. MS.JOINT_NAMES[j])
end

function UI.tabPlayers(pane)
	local w = pane.size.w - PAD * 2
	MS.bodySel = MS.bodySel or { p = 0, b = 0 }
	if (not MS.bodies[MS.bodySel.p]) then MS.bodySel = { p = 0, b = 0 } end
	local p, b = MS.bodySel.p, MS.bodySel.b
	if (not MS.bodies[p] or not MS.bodies[p][b]) then
		hint(pane, PAD, PAD, w, 60, "Body parts can't be edited right now.", 0.5)
		return
	end
	local y = playerRow(pane, PAD, w, p, function(np) UI.selectBody(np, b) end)
	y = partGrid(pane, y, w, MS.BODY_NAMES, MS.NUM_BODIES, b, function(nb) UI.selectBody(p, nb) end)
	local function g(f) return function() return MS.bodies[p][b][f] end end
	local function s(f, lbl)
		return function(v)
			MS.pushUndo(lbl, "body:" .. p .. ":" .. b .. ":" .. f)
			MS.bodySet(p, b, f, v)
			if (MS.settings.symmetry) then MS.mirrorBody(p, b, true) end
		end
	end
	local function num(lbl, f, step, o)
		o = o or {}
		return { kind = "num", label = lbl, get = g(f), set = s(f, lbl), step = step, min = o.min, int = o.int, tip = o.tip }
	end
	local function vec(lbl, prefix, step, tip)
		local fields = { prefix .. "_x", prefix .. "_y", prefix .. "_z" }
		return { kind = "vec3", label = lbl, step = step, tip = tip,
			get = function(k) return MS.bodies[p][b][fields[k]] end,
			set = function(k, v) s(fields[k], lbl)(v) end }
	end
	local function entriesFor(sub)
	local entries
	if (sub == "place") then
		local function rule(lbl, name, step, tip)
			return { kind = "num", label = lbl, step = step, int = true, tip = tip,
				get = function() return tonumber(MS.getRule(name)) or 0 end,
				set = function(v) MS.pushUndo(lbl, "rule:" .. name); MS.setRule(name, floor(v)) end }
		end
		entries = {
			{ kind = "toggle", label = "Gizmo moves the whole player", tip = "Turn on to move / turn the whole player and show the dojo resize dot",
				get = function() return UI.sub.players == "place" end,
				set = function(v) UI.sub.players = v and "place" or "transform"; UI.requestRefresh() end },
			{ kind = "hint", rows = 2, scale = 0.44, label = "With that on, the gizmo moves/turns the whole " .. (PLAYER_NAMES[p] or "player") ..
				". Pick the other player at the top. Drag the yellow dot to resize the dojo." },
			{ kind = "buttons", items = {
				{ "Face the other way", function()
					MS.pushUndo("Turn player")
					local Q = M.axisAngle({ 0, 0, 1 }, 180)
					local c = MS.playerModCenter(p)
					for b = 0, MS.NUM_BODIES - 1 do
						local o = MS.bodies[p][b]
						local np = V.add(c, M.apply(Q, V.sub({ o.pos_x, o.pos_y, o.pos_z }, c)))
						MS.bodySet(p, b, "pos_x", np[1]); MS.bodySet(p, b, "pos_y", np[2]); MS.bodySet(p, b, "pos_z", np[3])
						local x, yy, z = M.toEuler(M.mul(Q, M.fromEuler(o.rot_x, o.rot_y, o.rot_z)))
						MS.bodySet(p, b, "rot_x", x); MS.bodySet(p, b, "rot_y", yy); MS.bodySet(p, b, "rot_z", z)
					end
					for j = 0, MS.NUM_JOINTS - 1 do
						local o = MS.joints[p] and MS.joints[p][j]
						if (o) then
							local np = V.add(c, M.apply(Q, V.sub({ o.pos_x, o.pos_y, o.pos_z }, c)))
							MS.jointSet(p, j, "pos_x", np[1]); MS.jointSet(p, j, "pos_y", np[2]); MS.jointSet(p, j, "pos_z", np[3])
							local ax = M.apply(Q, { o.axis_x or 0, o.axis_y or 0, o.axis_z or 0 })
							MS.jointSet(p, j, "axis_x", ax[1]); MS.jointSet(p, j, "axis_y", ax[2]); MS.jointSet(p, j, "axis_z", ax[3])
						end
					end
					MS.toast("Turned " .. (PLAYER_NAMES[p] or "player") .. " around")
				end },
				{ "Reset this player", function() MS.resetTo(p); UI.requestRefresh() end }
			} },
			{ kind = "header", label = "Start spacing (applied when a match starts)" },
			rule("Engage distance", "engagedistance", 5, "How far apart the players start"),
			rule("Engage height", "engageheight", 5, "How high above the floor they start"),
			rule("Engage rotation", "engagerotation", 15, "Degrees the players are turned at the start"),
			{ kind = "buttons", items = { { "Restart match to see it", MS.restartMatch } } },
			{ kind = "header", label = "Dojo" },
			{ kind = "choice", label = "Shape", options = { { 0, "Square" }, { 1, "Round" } },
				get = function() return tonumber(MS.getRule("dojotype")) or 0 end,
				set = function(v)
					MS.pushUndo("Dojo shape")
					-- Keep the same footprint when switching shape
					local r = MS.dojoShape()
					MS.setRule("dojotype", v)
					if (r) then MS.setDojoFromRadius(r) end
				end },
			rule("Dojo size", "dojosize", 25, "0 = no dojo. Square: full width. Round: radius (hundredths of a unit)"),
			{ kind = "toggle", label = "Always show the dojo outline", get = function() return MS.settings.showDojo end,
				set = function(v) MS.settings.showDojo = v; MS.saveSettings() end }
		}
	elseif (sub == "physics") then
		entries = {
			num("Density", "density", 0.05, { min = 0, tip = "Heavier parts hit harder but move slower" }),
			num("Hardness", "hardness", 0.05, { min = 0 }),
			num("Friction", "friction", 0.05, { min = 0 }),
			num("Bounce", "bounce", 0.05, { min = 0 }),
			vec("Start force", "force", 1, "Push applied at the start")
		}
	elseif (sub == "thrust") then
		entries = {
			num("Thrust frames", "thrust_frames", 10, { int = true, min = 0 }),
			vec("Thrust", "thrust", 1),
			{ kind = "toggle", label = "Relative to part", get = g("thrust_relative"), set = s("thrust_relative", "Thrust relative") }
		}
	elseif (sub == "trigger") then
		entries = trigEntries(function(f) return MS.bodies[p][b][f] end, function(f, v) s(f, "Trigger")(v) end)
	elseif (sub == "tools") then
		entries = {
			{ kind = "hint", label = "Tip: click body parts in the 3D view to select them.", rows = 1 },
			{ kind = "toggle", label = "Show gizmo on body parts", get = function() return MS.settings.bodyGizmo end,
				set = function(v) MS.settings.bodyGizmo = v end, tip = "Move, rotate and resize parts with the 3D handles" },
			{ kind = "toggle", label = "Live symmetry (left <-> right)", get = function() return MS.settings.symmetry end,
				set = function(v) MS.settings.symmetry = v end, tip = "Edits to a left part are copied to the right one (and back)" },
			{ kind = "buttons", items = {
				{ "Mirror to other side", function() MS.pushUndo("Mirror part"); MS.mirrorBody(p, b) end, disabled = not MS.BODY_MIRROR[b] },
				{ "Copy to other player", function()
					MS.pushUndo("Copy part")
					MS.copyBodyToOtherPlayers(p, b)
					MS.toast("Copied shape + physics to the other player(s)")
				end, tip = "Copies size, shape and physics (not position)" }
			} },
			{ kind = "buttons", items = {
				{ "Physics to all parts", function()
					MS.pushUndo("Physics to all parts")
					local src = MS.bodies[p][b]
					for nb = 0, MS.NUM_BODIES - 1 do
						for _, f in ipairs({ "density", "hardness", "friction", "bounce" }) do
							if (src[f] ~= nil) then MS.bodySet(p, nb, f, src[f]) end
						end
					end
					MS.toast("Copied density/hardness/friction/bounce to every part")
				end }
			} },
			{ kind = "num", label = "Player scale", step = 0.05, min = 0.1, max = 10,
				get = function() return UI.playerScale or 1.5 end, set = function(v) UI.playerScale = v end,
				tip = "Size multiplier for the whole player (1.5 = 50% bigger)" },
			{ kind = "buttons", items = {
				{ "Scale whole player", function()
					local k = UI.playerScale or 1.5
					MS.pushUndo("Scale player")
					MS.scalePlayer(p, k)
					MS.toast("Scaled " .. (PLAYER_NAMES[p] or "player") .. " by x" .. MS.fmt(k))
				end, tip = "Resizes every part and joint around the feet" }
			} },
			{ kind = "buttons", items = {
				{ "Reset this player", function()
					MS.resetTo(p)
					UI.requestRefresh()
				end, tip = "Every body part and joint of this player back to default (Ctrl+Z undoes)" }
			} }
		}
	else
		entries = {}
		if (b ~= 0) then
			table.insert(entries, shapeChoice(g("type"), function(v)
				MS.pushUndo("Body shape")
				MS.bodySet(p, b, "type", v)
				if (MS.settings.symmetry) then MS.mirrorBody(p, b, true) end
			end))
		end
		table.insert(entries, vec("Position", "pos", 0.05))
		table.insert(entries, vec("Rotation", "rot", 5, "Degrees"))
		table.insert(entries, vec("Size", "sides", 0.05, "Sphere: X is the radius. Cylinder: X radius, Y length"))
		if (not MS.unsupported.body.altsides_x) then
			table.insert(entries, vec("Alt size", "altsides", 0.05, "Alternate size used by some game modes"))
		end
		table.insert(entries, { kind = "buttons", items = {
			{ "Focus camera", MS.focusSelection },
			{ "Mirror to other side", function() MS.pushUndo("Mirror part"); MS.mirrorBody(p, b) end, disabled = not MS.BODY_MIRROR[b] }
		} })
	end
	return entries
	end
	local entries = UI.sections({
		{ "players:shape", "Shape", function() return entriesFor("transform") end },
		{ "players:physics", "Physics", function() return entriesFor("physics") end },
		{ "players:thrust", "Thrust", function() return entriesFor("thrust") end },
		{ "players:trigger", "Trigger", function() return entriesFor("trigger") end },
		{ "players:tools", "Tools", function() return entriesFor("tools") end },
		{ "players:place", "Place players + dojo", function() return entriesFor("place") end }
	})
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "players")
end

function UI.tabJoints(pane)
	local w = pane.size.w - PAD * 2
	MS.jointSel = MS.jointSel or { p = 0, j = 0 }
	if (not MS.joints[MS.jointSel.p]) then MS.jointSel = { p = 0, j = 0 } end
	local p, j = MS.jointSel.p, MS.jointSel.j
	if (not MS.joints[p] or not MS.joints[p][j]) then
		hint(pane, PAD, PAD, w, 60, "Joints can't be edited right now.", 0.5)
		return
	end
	local y = playerRow(pane, PAD, w, p, function(np) UI.selectJoint(np, j) end)
	y = partGrid(pane, y, w, MS.JOINT_NAMES, MS.NUM_JOINTS, j, function(nj) UI.selectJoint(p, nj) end)
	local function g(f) return function() return MS.joints[p][j][f] end end
	local function s(f, lbl)
		return function(v)
			MS.pushUndo(lbl, "joint:" .. p .. ":" .. j .. ":" .. f)
			MS.jointSet(p, j, f, v)
			if (MS.settings.symmetry) then MS.mirrorJoint(p, j, true) end
		end
	end
	local function num(lbl, f, step, o)
		o = o or {}
		return { kind = "num", label = lbl, get = g(f), set = s(f, lbl), step = step, min = o.min, int = o.int, tip = o.tip }
	end
	local function vec(lbl, prefix, step, tip)
		local fields = { prefix .. "_x", prefix .. "_y", prefix .. "_z" }
		return { kind = "vec3", label = lbl, step = step, tip = tip,
			get = function(k) return MS.joints[p][j][fields[k]] end,
			set = function(k, v) s(fields[k], lbl)(v) end }
	end
	local function entriesFor(sub)
	local entries
	if (sub == "physics") then
		entries = {
			num("Radius", "radius", 0.01, { min = 0.01 }),
			num("Density", "density", 0.05, { min = 0 }),
			num("Hardness", "hardness", 0.05, { min = 0 }),
			num("Friction", "friction", 0.05, { min = 0 }),
			num("Bounce", "bounce", 0.05, { min = 0 })
		}
	elseif (sub == "trigger") then
		entries = trigEntries(function(f) return MS.joints[p][j][f] end, function(f, v) s(f, "Trigger")(v) end)
	elseif (sub == "tools") then
		entries = {
			{ kind = "toggle", label = "Show gizmo on joints", get = function() return MS.settings.bodyGizmo end,
				set = function(v) MS.settings.bodyGizmo = v end },
			{ kind = "toggle", label = "Live symmetry (left <-> right)", get = function() return MS.settings.symmetry end,
				set = function(v) MS.settings.symmetry = v end },
			{ kind = "buttons", items = {
				{ "Mirror to other side", function() MS.pushUndo("Mirror joint"); MS.mirrorJoint(p, j) end, disabled = not MS.JOINT_MIRROR[j] },
				{ "Copy to other player", function()
					MS.pushUndo("Copy joint")
					MS.copyJointToOtherPlayers(p, j)
					MS.toast("Copied limits, strength and physics to the other player(s)")
				end }
			} },
			{ kind = "header", label = "360 presets (both players)" },
			{ kind = "buttons", items = {
				{ "360 chest", function()
					MS.pushUndo("360 chest")
					MS.spinJoints({ MS.CHEST_JOINT }, true)
					MS.toast("Chest spins 360 for every player - turn it either way when playing")
					UI.requestRefresh()
				end, tip = "Like the classic 360 chest mods" },
				{ "360 chest + lumbar", function()
					MS.pushUndo("360 chest + lumbar")
					MS.spinJoints({ MS.CHEST_JOINT, MS.LUMBAR_JOINT }, true)
					MS.toast("Chest and lumbar spin 360 for every player")
					UI.requestRefresh()
				end, tip = "Blender style: the whole upper body can spin" }
			} },
			{ kind = "buttons", items = {
				{ "Remove all 360 joints", function()
					MS.pushUndo("Remove 360 joints")
					local all = {}
					for jj = 0, MS.NUM_JOINTS - 1 do table.insert(all, jj) end
					local n = MS.spinJoints(all, false)
					MS.toast(n > 0 and ("Put limits back on " .. n .. " joints") or "No joints were set to spin")
					UI.requestRefresh()
				end }
			} },
			{ kind = "header", label = "Change every joint at once" },
			{ kind = "num", label = "Strength", step = 10, min = 0, get = function() return UI.allForce or MS.joints[p][j].maxforce end, set = function(v) UI.allForce = v end },
			{ kind = "num", label = "Max speed", step = 1, min = 0, get = function() return UI.allVel or MS.joints[p][j].maxvelocity end, set = function(v) UI.allVel = v end },
			{ kind = "buttons", items = {
				{ "Apply to all joints", function()
					MS.pushUndo("All joints")
					for q = 0, MS.numPlayers - 1 do
						for jj = 0, MS.NUM_JOINTS - 1 do
							if (UI.allForce) then MS.jointSet(q, jj, "maxforce", UI.allForce) end
							if (UI.allVel) then MS.jointSet(q, jj, "maxvelocity", UI.allVel) end
						end
					end
					MS.toast("Updated every joint on every player")
				end, tip = "Sets strength + speed on all joints of all players" }
			} }
		}
	else
		entries = {
			vec("Position", "pos", 0.05),
			vec("Axis", "axis", 0.1, "Direction the joint bends around"),
			{ kind = "toggle", label = "Spins 360 (no limits)", tip = "Keeps turning in either direction, like the 360 chest mods",
				get = function() return MS.jointSpins(p, j) end,
				set = function(v)
					MS.pushUndo(v and "360 joint" or "Limit joint")
					MS.setJointSpin(p, j, v)
					if (MS.settings.symmetry and MS.JOINT_MIRROR[j]) then MS.mirrorJoint(p, j, true) end
					MS.toast(MS.JOINT_NAMES[j] .. (v and " now spins all the way round" or " has its limits back"))
					UI.requestRefresh()
				end },
			MS.jointSpins(p, j) and { kind = "hint", label = "Limits are off (10 / -10 means no limit)." } or
				num("Max angle", "histop", 0.05, { tip = "How far it bends one way (radians)" }),
			MS.jointSpins(p, j) and { kind = "hint", label = "Turn the toggle off to set angle limits again." } or
				num("Min angle", "lostop", 0.05, { tip = "How far it bends the other way (radians)" }),
			num("Strength", "maxforce", 10, { min = 0, tip = "Higher = stronger joint" }),
			num("Max speed", "maxvelocity", 1, { min = 0, tip = "How fast it can move" }),
			{ kind = "buttons", items = {
				{ "Focus camera", MS.focusSelection },
				{ "Mirror to other side", function() MS.pushUndo("Mirror joint"); MS.mirrorJoint(p, j) end, disabled = not MS.JOINT_MIRROR[j] }
			} }
		}
	end
	return entries
	end
	local entries = UI.sections({
		{ "joints:main", "Joint", function() return entriesFor("main") end },
		{ "joints:physics", "Physics", function() return entriesFor("physics") end },
		{ "joints:trigger", "Trigger", function() return entriesFor("trigger") end },
		{ "joints:tools", "Tools", function() return entriesFor("tools") end }
	})
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "joints")
end

---------------------------------------------------------------------------
-- Rules / World / File / Console / Settings
---------------------------------------------------------------------------

function UI.tabRules(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	local modName = MS.getRule("mod") or ""
	buttonRow(pane, PAD, y, w, ROW, {
		{ "Restart match to try", MS.restartMatch, tip = "Rules apply right away - this starts a new match so you can see them" },
		{ "Reset rules", function()
			UI.confirm("Reset all rules?", "Puts every rule back to the classic defaults. Objects and players are kept. Ctrl+Z undoes it.", {
				{ "Reset rules", function() MS.resetTo("rules"); UI.requestRefresh() end }, { "Cancel" }
			})
		end, tip = "Back to the classic default rules" }
	})
	y = y + ROW + GAP * 3

	-- Game flags: one bit each, with what they do written out
	local flags = MS.getFlags()
	local entries = {
		{ kind = "header", label = "Game flags   (flags = " .. flags .. ": " .. MS.flagsSummary(flags) .. ")" }
	}
	for _, f in ipairs(MS.FLAGS) do
		local fl = f
		table.insert(entries, { kind = "toggle", label = fl.title .. "   [adds " .. fl.bit .. "]", tip = fl.desc,
			get = function() return MS.hasBit(MS.getFlags(), fl.bit) end,
			set = function(v)
				MS.pushUndo("Flag " .. fl.title)
				MS.setFlag(fl.bit, v)
				UI.requestRefresh()
			end })
		table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
			label(holder, ROW + 6, ry, rw - ROW - 6, ROW, fl.desc, LEFTMID, 0.4)
		end })
	end
	table.insert(entries, { kind = "num", label = "Flags value", step = 1, int = true, min = 0, max = 15,
		tip = "The flags above added together (0-15). Typing a number here sets the toggles",
		get = function() return MS.getFlags() end,
		set = function(v)
			MS.pushUndo("Flags", "rule:flags")
			MS.setFlags(v)
		end })

	table.insert(entries, { kind = "header", label = "Rules" })
	for _, r in ipairs(MS.RULES) do
		local cur = MS.getRule(r.name)
		if (cur ~= nil and cur ~= "none") then
			local rule = r
			if (rule.kind == "bool") then
				table.insert(entries, { kind = "toggle", label = rule.title, tip = rule.tip,
					get = function() return MS.getRule(rule.name) == "1" end,
					set = function(v) MS.setRule(rule.name, v and 1 or 0); UI.requestRefresh() end })
			elseif (rule.kind == "enum") then
				table.insert(entries, { kind = "choice", label = rule.title, tip = rule.tip, options = rule.options,
					get = function() return tonumber(MS.getRule(rule.name)) or 0 end,
					set = function(v) MS.setRule(rule.name, v) end })
			elseif (rule.kind == "string") then
				table.insert(entries, { kind = "text", label = rule.title, tip = rule.tip,
					get = function() return MS.getRule(rule.name) or "" end,
					set = function(v) MS.setRule(rule.name, v) end })
			elseif (rule.kind == "percent") then
				local function pct() return MS.clamp(tonumber(MS.getRule(rule.name)) or rule.default or 100, rule.min, rule.max) end
				table.insert(entries, { kind = "slider", label = rule.title .. "  (" .. (pct() == 0 and "Off" or (floor(pct() + 0.5) .. "%")) .. ")",
					tip = rule.tip, min = rule.min, max = rule.max, minDisp = rule.minDisp, maxDisp = rule.maxDisp,
					labelFn = function(v) v = floor(v + 0.5); return v == 0 and "Off" or (v .. "%") end,
					get = pct,
					set = function(v)
						MS.pushUndo(rule.title, "rule:" .. rule.name)
						MS.setRule(rule.name, floor(v + 0.5))
					end })
				table.insert(entries, { kind = "buttons", items = {
					{ "100% (default)", function() MS.pushUndo(rule.title); MS.setRule(rule.name, 100); UI.requestRefresh() end },
					{ "Off", function() MS.pushUndo(rule.title); MS.setRule(rule.name, 0); UI.requestRefresh() end }
				} })
			elseif (rule.kind == "vec3") then
				local function parts()
					local s = MS.getRule(rule.name) or "0 0 0"
					local t = {}
					for n in s:gmatch("[^%s,]+") do table.insert(t, tonumber(n) or 0) end
					return { t[1] or 0, t[2] or 0, t[3] or 0 }
				end
				table.insert(entries, { kind = "vec3", label = rule.title, step = 0.5, tip = rule.tip,
					get = function(k) return parts()[k] end,
					set = function(k, v)
						local t = parts()
						t[k] = v
						MS.setRule(rule.name, MS.fmt(t[1]) .. " " .. MS.fmt(t[2]) .. " " .. MS.fmt(t[3]))
					end })
			else
				local step = (rule.name == "matchframes") and 50 or ((rule.name:find("threshold") or rule.name == "maxcontacts") and 10 or 1)
				table.insert(entries, { kind = "num", label = rule.title, step = step, int = true, tip = rule.tip,
					get = function() return tonumber(MS.getRule(rule.name)) or 0 end,
					set = function(v) MS.setRule(rule.name, floor(v)) end })
			end
		end
	end
	table.insert(entries, { kind = "hint", label = "Mod file: " .. tostring(modName) })
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "rules")
end

function UI.tabWorld(pane)
	local entries = {
		{ kind = "header", label = "Mod info" },
		{ kind = "text", label = "Welcome message", placeholder = "Shown when the mod loads",
			get = function() local ok, v = pcall(get_mod_message); return ok and v or "" end,
			set = function(v) pcall(set_mod_message, v); MS.markDirty() end },
		{ kind = "toggle", label = "Use a custom world model",
			get = function() local ok, v = pcall(get_mod_use_model); return ok and v end,
			set = function(v) pcall(set_mod_use_model, v); MS.markDirty() end },
		{ kind = "text", label = "World model name", placeholder = "model file name",
			get = function() local ok, v = pcall(get_mod_model_name); return ok and v or "" end,
			set = function(v) pcall(set_mod_model_name, v); MS.markDirty() end },
		{ kind = "header", label = "Camera" },
		{ kind = "buttons", items = {
			{ "Top", function() MS.viewFrom("top") end }, { "Front", function() MS.viewFrom("front") end },
			{ "Side", function() MS.viewFrom("side") end }, { "3/4", function() MS.viewFrom("iso") end }
		} },
		{ kind = "buttons", items = {
			{ "Focus selection (F)", MS.focusSelection },
			{ "Look at players", function() MS.cameraTo({ 0, 0, 1 }, nil, 6, nil, true) end }
		} },
		{ kind = "header", label = "Overview" },
		{ kind = "hint", rows = 2, label = MS.count(MS.objs) .. " objects | " .. MS.count(MS.tris) .. " triangles | " .. MS.count(MS.ejs) .. " links | " .. MS.numPlayers .. " players" }
	}
	UI.paged(pane, PAD, pane.size.h - PAD * 2, entries, "world")
end

function UI.tabFile(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	if (UI.fileMode == "import" or UI.fileMode == "projects") then
		local isImport = UI.fileMode == "import"
		label(pane, PAD, y, w - 80, ROW, isImport and "Pick a mod to import" or "Pick a project to open", LEFTMID, 0.5)
		button(pane, PAD + w - 76, y, 76, ROW, "Back", function() UI.fileMode = "main"; UI.requestRefresh() end)
		y = y + ROW + GAP * 3
		local list = isImport and MS.listMods() or MS.listProjects()
		if (#list == 0) then
			hint(pane, PAD, y, w, 60, isImport and "No mods found in data/mod." or "No saved projects yet. Use \"Save project\" first.", 0.5)
			return
		end
		local entries = {}
		for _, name in ipairs(list) do
			table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
				button(holder, 0, ry, rw, ROW, (name:gsub("%.tbm$", "")), function()
					local function go()
						UI.fileMode = "main"
						if (isImport) then MS.importMod(name) else MS.loadProject(name) end
						UI.requestRefresh()
					end
					if (MS.changed) then
						UI.confirm("Replace current mod?", "You have unsaved changes. They can still be undone with Ctrl+Z.", {
							{ "Open anyway", go }, { "Cancel" }
						})
					else
						go()
					end
				end, { align = LEFTMID, scale = 0.45 })
			end })
		end
		UI.paged(pane, y, pane.size.h - y - PAD, entries, UI.fileMode)
		return
	end

	MS.saveName = MS.saveName or "Untitled"
	local entries = {
		{ kind = "text", label = "Mod name", get = function() return MS.saveName end, set = function(v) MS.saveName = v end },
		{ kind = "buttons", items = {
			{ "Export .tbm", function() MS.exportMod(MS.saveName) end, tip = "Ctrl+E. Saves a playable mod to data/mod/modmaker/" },
			{ "Save project", function() MS.saveProject(MS.saveName) end, tip = "Ctrl+S. Also keeps names, groups and triangles" }
		} },
		{ kind = "buttons", items = {
			{ "Import a mod...", function() UI.fileMode = "import"; UI.requestRefresh() end, tip = "Load any .tbm to edit it" },
			{ "Open project...", function() UI.fileMode = "projects"; UI.requestRefresh() end }
		} },
		{ kind = "buttons", items = {
			{ "Recover autosave", function()
				UI.confirm("Recover autosave?", "Loads the last automatic backup. Your current work can be brought back with Ctrl+Z.", {
					{ "Recover", function() MS.loadProject("_autosave"); UI.requestRefresh() end }, { "Cancel" }
				})
			end, tip = "Loads the last automatic backup" },
			{ "Test mod", UI.enterTest, tip = "Play your mod, then come back to keep editing" }
		} },
		{ kind = "header", label = "Autosave" },
		{ kind = "toggle", label = "Autosave while I work", tip = "Backs up to the \"_autosave\" project, which \"Recover autosave\" loads",
			get = function() return MS.settings.autosave end,
			set = function(v)
				MS.settings.autosave = v
				MS.saveSettings()
				MS.toast(v and ("Autosave on - every " .. MS.settings.autosaveMinutes .. " min") or "Autosave off - remember to Save project / Export")
				UI.requestRefresh()
			end },
		{ kind = "choice", label = "Every", tip = "How often to back up (only when something changed)",
			options = { { 1, "1 min" }, { 2, "2 min" }, { 5, "5 min" }, { 10, "10 min" } },
			get = function() return MS.settings.autosaveMinutes end,
			set = function(v) MS.settings.autosaveMinutes = v; MS.saveSettings() end },
		{ kind = "header", label = "Start from a template (objects + rules)" }
	}
	for _, t in ipairs(MS.TEMPLATES) do
		local tt = t
		table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
			button(holder, 0, ry, floor(rw * 0.34), ROW, tt.name, function()
				UI.confirm("Start a " .. tt.name .. " mod?", tt.desc .. "\nThis replaces the current mod. Ctrl+Z brings it back.", {
					{ "Start it", function() MS.applyTemplate(tt.id); UI.requestRefresh() end }, { "Cancel" }
				})
			end, { tip = tt.desc, scale = 0.45 })
			label(holder, floor(rw * 0.34) + 6, ry, rw - floor(rw * 0.34) - 6, ROW, tt.desc, LEFTMID, 0.38)
		end })
	end
	local rest = {
		{ kind = "header", label = "Reset (everything can be undone with Ctrl+Z)" },
		{ kind = "buttons", items = {
			{ "Reset everything", function()
				UI.confirm("Reset everything?", "Starts over from the classic default mod: no objects, default players and rules.", {
					{ "Reset everything", function() MS.resetTo("all"); UI.requestRefresh() end }, { "Cancel" }
				})
			end, tip = "Back to a blank classic mod" },
			{ "Remove all objects", function()
				UI.confirm("Remove every object?", "Clears the map but keeps players and rules.", {
					{ "Remove all", MS.clearAll }, { "Cancel" }
				})
			end }
		} },
		{ kind = "buttons", items = {
			{ "Reset both players", function()
				UI.confirm("Reset both players?", "Every body part and joint goes back to default. Objects and rules are kept.", {
					{ "Reset players", function() MS.resetTo("players"); UI.requestRefresh() end }, { "Cancel" }
				})
			end },
			{ "Reset Tori", function() MS.resetTo(0); UI.requestRefresh() end, tip = "Only Tori's body + joints" },
			{ "Reset Uke", function() MS.resetTo(1); UI.requestRefresh() end, tip = "Only Uke's body + joints" }
		} },
		{ kind = "buttons", items = {
			{ "Reset rules", function()
				UI.confirm("Reset all rules?", "Rules and flags go back to the classic defaults.", {
					{ "Reset rules", function() MS.resetTo("rules"); UI.requestRefresh() end }, { "Cancel" }
				})
			end }
		} },
		{ kind = "hint", rows = 3, label = "Exported mods appear in your Mods list under \"modmaker\".\nProjects are saved in data/script/modstudio/projects/." }
	}
	for _, e in ipairs(rest) do table.insert(entries, e) end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "file")
end

function UI.tabConsole(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	UI.consoleHistory = UI.consoleHistory or {}
	UI.consoleCmd = UI.consoleCmd or ""
	local function run()
		local cmd = UI.consoleCmd
		if (not cmd or cmd == "") then return end
		if (runCmd) then
			pcall(runCmd, cmd, false, CMD_ECHO_ENABLED)
		end
		table.insert(UI.consoleHistory, 1, cmd)
		if (#UI.consoleHistory > 30) then table.remove(UI.consoleHistory) end
		UI.consoleCmd = ""
		UI.requestRefresh()
	end
	field(pane, PAD, y, w - 60, ROW, UI.consoleCmd, { align = LEFTMID, placeholder = "Type a game command (without /)", enter = function() run() end },
		function(s) UI.consoleCmd = s end)
	button(pane, PAD + w - 56, y, 56, ROW, "Run", run)
	y = y + ROW + GAP * 3
	if (#UI.consoleHistory == 0) then
		hint(pane, PAD, y, w, 60, "Commands you run show up here. Click one to put it back in the box.", 0.5)
		return
	end
	local entries = {}
	for _, cmd in ipairs(UI.consoleHistory) do
		table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
			button(holder, 0, ry, rw, ROW, cmd, function() UI.consoleCmd = cmd; UI.requestRefresh() end, { align = LEFTMID, scale = 0.45 })
		end })
	end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "console")
end

function UI.tabSettings(pane)
	local st = MS.settings
	local function tog(lbl, key, tip)
		return { kind = "toggle", label = lbl, tip = tip, get = function() return st[key] end, set = function(v) st[key] = v; MS.saveSettings() end }
	end
	local function num(lbl, key, step, o)
		o = o or {}
		return { kind = "num", label = lbl, step = step, min = o.min, max = o.max, int = o.int, tip = o.tip,
			get = function() return st[key] end, set = function(v) st[key] = v end }
	end
	local entries = {
		{ kind = "header", label = "Snapping" },
		tog("Snap while dragging (G)", "snap", "Hold Ctrl while dragging to temporarily flip this"),
		num("Grid step", "gridStep", 0.05, { min = 0.01, tip = "Move snapping + arrow key nudge distance" }),
		num("Rotation step", "rotStep", 5, { min = 1, max = 90 }),
		num("Size step", "scaleStep", 0.01, { min = 0.01 }),
		{ kind = "header", label = "View" },
		tog("Show ground grid", "showGrid"),
		num("Grid size", "gridExtent", 2, { min = 2, max = 100 }),
		tog("Show object names", "showLabels"),
		tog("Show links between objects", "showLinks"),
		{ kind = "header", label = "Parent & children" },
		tog("Children follow parent", "moveChildren", "Moving, turning, resizing, copying or mirroring a parent also does it to its children"),
		tog("Show parent lines", "showHierarchy", "Purple lines from the selection to its parent and children"),
		tog("Parent lines for everything", "showAllHierarchy", "Draw every parent line, not just the selection's"),
		{ kind = "header", label = "Dragging" },
		tog("Scroll pushes a dragged object", "scrollPush", "While you click-drag an object, the wheel moves it away from / toward the camera. Shift+scroll zooms instead"),
		tog("Alt + gizmo drag makes a copy", "altDuplicate", "Hold Alt when you grab an arrow, ring or handle to drag out a duplicate"),
		{ kind = "header", label = "Look" },
		{ kind = "choice", label = "UI size", tip = "Makes every panel, button and text bigger or smaller",
			get = function() return st.uiScale or 1 end,
			set = function(v) st.uiScale = v; MS.saveSettings(); UI.close(); UI.open() end,
			options = { { 0.85, "Small" }, { 1, "Normal" }, { 1.15, "Large" }, { 1.3, "Huge" } } },
		{ kind = "choice", label = "Accent", tip = "Color of selected tabs, buttons and switches",
			get = function() return st.accent or "pink" end,
			set = function(v) st.accent = v; MS.saveSettings(); UI.close(); UI.open() end,
			options = (function() local o = {} for _, a in ipairs(UI.ACCENTS) do table.insert(o, { a[1], a[2] }) end return o end)() },
		{ kind = "buttons", items = { { "Unfold all sections", function() MS.settings.folded = {}; MS.saveSettings(); UI.requestRefresh() end } } },
		{ kind = "header", label = "Panels" },
		{ kind = "hint", rows = 2, label = "Drag the :: handle on a panel, the toolbar or the status bar to move it. Drag the / corner to resize a panel." },
		{ kind = "buttons", items = { { "Reset panel layout", function() UI.resetLayout() end, tip = "Put every panel back where it started" } } },
		{ kind = "slider", label = "Gizmo size", min = 50, max = 200, get = function() return st.gizmoSize end, set = function(v) st.gizmoSize = v end },
		{ kind = "header", label = "Saving" },
		tog("Autosave while I work", "autosave", "Backup goes to the \"_autosave\" project. Recover it from the File tab"),
		{ kind = "choice", label = "Autosave every", options = { { 1, "1 min" }, { 2, "2 min" }, { 5, "5 min" }, { 10, "10 min" } },
			get = function() return st.autosaveMinutes end, set = function(v) st.autosaveMinutes = v; MS.saveSettings() end },
		{ kind = "header", label = "Engine units (measured automatically at start)" },
		{ kind = "hint", rows = 2, scale = 0.42, label = (function()
			local c = MS.calib
			local how = (c and c.done) and (c.result and "Measured this session" or "Couldn't measure - using saved values") or "Measuring..."
			return how .. ": rotation in " .. (st.rotUnit == "rad" and "radians" or "degrees") .. ", order " .. st.rotConvention .. ", size scale " .. MS.fmt(st.sizeScale)
		end)() },
		{ kind = "buttons", items = {
			{ "Measure again", function()
				MS.startCalibration()
				MS.toast("Measuring the engine's units...")
				UI.requestRefresh()
			end, tip = "Re-checks how the game stores rotations and sizes" }
		} },
		{ kind = "choice", label = "Rotation units", tip = "Only change this by hand if rotated objects or triangles look wrong",
			get = function() return st.rotUnit end,
			set = function(v)
				st.rotUnit = v
				MS.saveSettings()
				MS.reloadAll()
				for id in pairs(MS.tris) do MS.triBuild(id) end
			end,
			options = { { "deg", "Degrees" }, { "rad", "Radians" } } },
		{ kind = "choice", label = "Rotation order", tip = "Only change this by hand if rotated objects or triangles look wrong",
			get = function() return st.rotConvention end,
			set = function(v)
				st.rotConvention = v
				MS.saveSettings()
				for id in pairs(MS.tris) do MS.triBuild(id) end
			end,
			options = { { 1, "Default" }, { 2, "Alternative" } } },
		{ kind = "buttons", items = {
			{ "Show help", function() UI.toggleHelp(true) end },
			{ "Reset settings", function()
				MS.settings = MS.deepcopy(MS.DEFAULT_SETTINGS)
				MS.settings.firstRun = false
				MS.saveSettings()
				UI.buildToolbar()
				UI.requestRefresh()
				MS.toast("Settings reset")
			end }
		} },
		{ kind = "hint", label = "Mod Studio " .. MS.VERSION }
	}
	UI.paged(pane, PAD, pane.size.h - PAD * 2, entries, "settings")
end

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------

---Usage bar: label | [#####-----] text
local function usageBar(holder, y, w, labelText, used, limit, note)
	local lw = floor(w * 0.36)
	label(holder, 4, y, lw - 4, ROW, labelText, LEFTMID, 0.5)
	local bw = w - lw
	local bg = holder:addChild({ pos = { lw, y + 3 }, size = { bw, ROW - 6 }, bgColor = C.darkest, shapeType = ROUNDED, rounded = 3 })
	local text
	if (limit and limit > 0) then
		local f = MS.clamp(used / limit, 0, 1)
		local col = f < 0.7 and { 0.3, 0.75, 0.35, 1 } or (f < 0.9 and { 0.95, 0.65, 0.2, 1 } or { 0.9, 0.2, 0.2, 1 })
		if (f > 0) then
			bg:addChild({ pos = { 0, 0 }, size = { math.max(4, bw * f), ROW - 6 }, bgColor = col, shapeType = ROUNDED, rounded = 3 })
		end
		text = used .. " / " .. limit .. "  (" .. floor(f * 100 + 0.5) .. "%)"
	else
		text = used .. (note or "")
	end
	local t = holder:addChild({ pos = { lw, y }, size = { bw, ROW } })
	t:addAdaptedText(false, text, nil, nil, 4, CENTERMID, 0.45)
end

function UI.tabStats(pane)
	local total = MS.count(MS.objs)
	local limit = (MS.settings.objLimit or 0) > 0 and MS.settings.objLimit or nil
	local static, dynamic, hidden, locked, thrusters, triggers = 0, 0, 0, 0, 0, 0
	local groups = {}
	local Hs = MS.hier()
	local parented, parents = MS.count(Hs.parent), MS.count(Hs.children)
	for idx, o in pairs(MS.objs) do
		if (o.static) then static = static + 1 else dynamic = dynamic + 1 end
		if (o.visible == false) then hidden = hidden + 1 end
		if ((o.thrust_frames or 0) > 0) then thrusters = thrusters + 1 end
		if ((o.trig_id or 0) ~= 0 or (o.trig_mask or 0) ~= 0) then triggers = triggers + 1 end
		local m = MS.meta[idx]
		if (m and m.locked) then locked = locked + 1 end
		if (m and m.group) then groups[m.group] = true end
	end
	local triSlices, triCount, biggestTri, biggestN = 0, 0, nil, 0
	for id, t in pairs(MS.tris) do
		triCount = triCount + 1
		triSlices = triSlices + #t.objs
		if (#t.objs > biggestN) then biggestTri, biggestN = id, #t.objs end
	end
	local entries = {
		{ kind = "header", label = "Objects" },
		{ kind = "custom", render = function(h, y, w)
			usageBar(h, y, w, "Objects used", total, limit, limit and "" or "  (limit not measured yet)")
		end },
		{ kind = "custom", render = function(h, y, w)
			usageBar(h, y, w, "Links used", MS.count(MS.ejs), nil, "")
		end },
		{ kind = "hint", rows = 1, label = limit and ("Room for " .. math.max(0, limit - total) .. " more objects")
			or "Press \"Measure limit\" to find out how many objects the game allows." },
		{ kind = "buttons", items = {
			{ limit and "Measure limit again" or "Measure limit", function()
				local n = MS.measureObjectLimit()
				MS.toast(n and ("The game allows " .. n .. " objects") or "Couldn't measure the limit")
				UI.requestRefresh()
			end, tip = "Briefly creates placeholder objects until the game says no, then removes them. Your mod isn't changed" }
		} },
		{ kind = "header", label = "Breakdown" },
		{ kind = "hint", rows = 1, label = static .. " static  |  " .. dynamic .. " physics (moving)  |  " .. hidden .. " invisible" },
		{ kind = "hint", rows = 1, label = triCount .. " triangles using " .. triSlices .. " objects  |  " .. MS.count(groups) .. " groups  |  " .. locked .. " locked" },
		{ kind = "hint", rows = 1, label = thrusters .. " with thrust  |  " .. triggers .. " with triggers  |  " .. MS.numPlayers .. " players" },
		{ kind = "hint", rows = 1, label = parented .. " items have a parent  |  " .. parents .. " parents" }
	}
	if (dynamic > 40) then
		table.insert(entries, { kind = "hint", rows = 2, label = "Lots of physics objects can make the game slow. Mark the ones that never move as Static." })
	end
	if (biggestTri and limit and triSlices > limit * 0.25) then
		table.insert(entries, { kind = "hint", rows = 2, label = "Triangles use a big share of your objects. Lower their Smoothness to free some up (biggest: " .. (MS.tris[biggestTri].name or ("Triangle " .. biggestTri)) .. ", " .. biggestN .. " slices)." })
	end
	table.insert(entries, { kind = "header", label = "Performance" })
	local costMs = floor((MS.refreshCost or 0) * 1000 + 0.5)
	local gapMs = floor(MS.refreshInterval() * 1000 + 0.5)
	table.insert(entries, { kind = "hint", rows = 2, label = "The game takes about " .. costMs .. " ms to rebuild the world after a change. " ..
		(gapMs > 0 and ("While you're editing, Mod Studio updates the objects every " .. gapMs .. " ms so the panels stay smooth.") or "That's fast, so every change shows right away.") })
	table.insert(entries, { kind = "header", label = "Session" })
	local ago = MS.lastAutosave and floor(MS.clock() - MS.lastAutosave) or nil
	table.insert(entries, { kind = "hint", rows = 1, label = (MS.changed and "Unsaved changes" or "All changes exported/saved") .. "  |  " .. #MS.undoStack .. " undo steps" })
	table.insert(entries, { kind = "hint", rows = 1, label = MS.settings.autosave and ("Last autosave check " .. (ago and (ago .. "s ago") or "-")) or "Autosave is off" })
	table.insert(entries, { kind = "buttons", items = { { "Refresh", function() UI.requestRefresh() end } } })
	UI.paged(pane, PAD, pane.size.h - PAD * 2, entries, "stats")
end

---------------------------------------------------------------------------
-- Library (prefabs)
---------------------------------------------------------------------------

UI.prefabName = UI.prefabName or ""

function UI.tabLibrary(pane)
	local w = pane.size.w - PAD * 2
	local y = PAD
	local n = MS.selCount()
	label(pane, PAD, y, w, ROW, "Save the selection as a reusable prefab:", LEFTMID, 0.45)
	y = y + ROW + GAP
	field(pane, PAD, y, w - 90, ROW, UI.prefabName, { align = LEFTMID, placeholder = "Prefab name" }, function(s) UI.prefabName = s end)
	button(pane, PAD + w - 86, y, 86, ROW, "Save", function()
		local name = UI.prefabName ~= "" and UI.prefabName or ("Prefab " .. (#MS.listPrefabs() + 1))
		if (MS.savePrefab(name)) then
			UI.prefabName = ""
			UI.requestRefresh()
		end
	end, { disabled = n == 0, tip = n == 0 and "Select some objects first" or ("Saves the " .. n .. " selected objects") })
	y = y + ROW + GAP * 3

	local entries = { { kind = "header", label = "Built-in" } }
	local function row(name, builtin)
		table.insert(entries, { kind = "custom", render = function(holder, ry, rw)
			local delW = builtin and 0 or 56
			button(holder, 0, ry, rw - delW - (builtin and 0 or GAP), ROW, "Place  " .. name, function()
				MS.placePrefab(name)
			end, { align = LEFTMID, scale = 0.45, tip = "Adds it where the camera is looking" })
			if (not builtin) then
				button(holder, rw - delW, ry, delW, ROW, "Delete", function()
					UI.confirm("Delete prefab?", "Removes \"" .. name .. "\" from your library. Objects already placed stay.", {
						{ "Delete", function() MS.deletePrefabFile(name); UI.requestRefresh() end }, { "Cancel" }
					})
				end, { scale = 0.42 })
			end
		end })
	end
	for _, b in ipairs(MS.BUILTIN_PREFABS) do row(b.name, true) end
	local mine = MS.listPrefabs()
	table.insert(entries, { kind = "header", label = "Your prefabs (" .. #mine .. ")" })
	if (#mine == 0) then
		table.insert(entries, { kind = "hint", rows = 2, label = "Build something, select it, give it a name above and press Save. It'll be here for every mod you make." })
	end
	for _, name in ipairs(mine) do row(name, false) end
	UI.paged(pane, y, pane.size.h - y - PAD, entries, "library")
end

---------------------------------------------------------------------------
-- Docks: three panels around the screen edges, each with its own tabs.
-- Click a panel's active tab to tuck it away, click any tab to open it.
---------------------------------------------------------------------------

UI.TAB_BUILD = {
	scene = function(p) UI.tabScene(p) end,
	create = function(p) UI.tabCreate(p) end,
	library = function(p) UI.tabLibrary(p) end,
	links = function(p) UI.tabLinks(p) end,
	properties = function(p) UI.tabProperties(p) end,
	players = function(p) UI.tabPlayers(p) end,
	joints = function(p) UI.tabJoints(p) end,
	file = function(p) UI.tabFile(p) end,
	rules = function(p) UI.tabRules(p) end,
	world = function(p) UI.tabWorld(p) end,
	stats = function(p) UI.tabStats(p) end,
	console = function(p) UI.tabConsole(p) end,
	settings = function(p) UI.tabSettings(p) end,
	tbm = function(p) UI.tabTBM(p) end,
	history = function(p) UI.tabHistory(p) end
}

UI.DOCKS = {
	{ side = "left", tabs = { { "scene", "Scene" }, { "create", "Create" }, { "library", "Library" }, { "links", "Links" }, { "history", "History" } } },
	{ side = "right", tabs = { { "properties", "Properties" }, { "players", "Bodies" }, { "joints", "Joints" } } },
	{ side = "bottom", tabs = { { "file", "File" }, { "rules", "Rules" }, { "world", "World" }, { "stats", "Stats" }, { "console", "Console" }, { "tbm", "TBM" }, { "settings", "Settings" } } }
}

UI.dockState = UI.dockState or {
	left = { active = "scene", open = true },
	right = { active = "properties", open = true },
	bottom = { active = "file", open = false }
}
UI.dockEls = UI.dockEls or {}
UI.dockContent = UI.dockContent or {}


function UI.isTabOpen(id)
	for _, st in pairs(UI.dockState) do
		if (st.open and st.active == id) then return true end
	end
	return false
end

local function dockOf(id)
	for _, d in ipairs(UI.DOCKS) do
		for _, t in ipairs(d.tabs) do
			if (t[1] == id) then return d.side end
		end
	end
end

---Opens the panel that holds tab `id` and shows that tab
function UI.selectTab(id)
	local side = dockOf(id)
	if (not side) then return end
	UI.dockState[side].active = id
	UI.dockState[side].open = true
	UI.linkPick = nil
	UI.buildDock(side)
end

local function dockRect(side)
	local sideW = MS.clamp(floor(WIN_W * 0.2), floor(250 * UI.k), floor(360 * UI.k))
	local top = UI.topBarH()
	local bottom = WIN_H - UI.statusH()
	local open = UI.dockState[side].open
	-- Moved / resized by the user (kept on screen if the window got smaller)
	local L = MS.settings.layout and MS.settings.layout[side]
	if (L and L.w) then
		local w = MS.clamp(L.w, 200, WIN_W - 4)
		local x = MS.clamp(L.x, 0, WIN_W - w)
		local y = MS.clamp(L.y, 0, bottom - UI.HEADER_H)
		if (not open) then
			if (side == "bottom") then
				-- Tucked away: sit on the bottom edge of where the panel opens
				y = MS.clamp(L.y + (L.h or UI.HEADER_H) - UI.HEADER_H, 0, bottom - UI.HEADER_H)
			end
			return x, y, w, UI.HEADER_H
		end
		-- Would run off the bottom of the screen: pop up instead
		local h = MS.clamp(L.h or 120, 120, bottom)
		y = math.max(0, math.min(L.y, bottom - h))
		return x, y, w, h
	end
	-- Default: Scene and Properties stacked down the left edge, File / Rules /
	-- Stats... in the bottom-right corner, the 3D view free in the middle
	sideW = MS.clamp(floor(WIN_W * 0.1875), floor(250 * UI.k), floor(400 * UI.k))
	local avail = bottom - top
	local leftH = floor(avail * 0.55)
	if (side == "left") then
		return 0, top, sideW, open and leftH or UI.HEADER_H
	elseif (side == "right") then
		-- Sits under the Scene panel and moves up when that one is tucked away
		local y = top + (UI.dockState.left.open and leftH or UI.HEADER_H)
		return 0, y, sideW, open and (bottom - y) or UI.HEADER_H
	end
	local bw = MS.clamp(floor(WIN_W * 0.31), floor(380 * UI.k), WIN_W - sideW - 20)
	local bh = open and floor(avail * 0.54) or UI.HEADER_H
	return WIN_W - bw, bottom - bh, bw, bh
end

---Rebuilds a panel after it was opened / tucked away. The default Properties
---panel sits under the Scene panel, so it follows when Scene changes size.
function UI.rebuildAfterToggle(side)
	UI.buildDock(side)
	local placed = MS.settings.layout and MS.settings.layout.right and MS.settings.layout.right.w
	if (side == "left" and not placed and UI.dockEls.right) then
		UI.buildDock("right")
	end
end

function UI.buildDock(side)
	if (UI.dockEls[side]) then UI.dockEls[side]:kill() end
	UI.dockEls[side], UI.dockContent[side] = nil, nil
	local def
	for _, d in ipairs(UI.DOCKS) do if (d.side == side) then def = d end end
	local st = UI.dockState[side]
	local x, y, w, h = dockRect(side)
	local floating = MS.settings.layout and MS.settings.layout[side] and MS.settings.layout[side].w
	local root = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { x, y }, size = { w, h },
		bgColor = C.edge, shapeType = ROUNDED, rounded = floating and 5 or 0, interactive = true
	})
	UI.dockEls[side] = root
	local inner = root:addChild({ shift = { 1, 1 }, bgColor = C.bg, shapeType = ROUNDED, rounded = floating and 4 or 0 }, true)

	-- Tab row (always visible, even when the panel is tucked away)
	local n = #def.tabs
	local tw = (inner.size.w - 4 - (ROW + GAP) * 2 - GAP * (n - 1)) / n
	local function fullRect()
		-- Always the opened rect, so a tucked panel saves where it opens
		local wasOpen = st.open
		st.open = true
		local fx, fy, fw, fh = dockRect(side)
		st.open = wasOpen
		return { fx, fy, fw, fh }
	end
	layoutGrip(inner, inner.size.w - (ROW + GAP) * 2 - 2 + GAP, 2, ROW, ROW, "::", side, "move", fullRect,
		"Drag to move this panel (Settings > Reset panel layout puts it back)")
	for i, t in ipairs(def.tabs) do
		local id = t[1]
		button(inner, 2 + (i - 1) * (tw + GAP), 2, tw, ROW, t[2], function()
			if (st.open and st.active == id) then
				st.open = false
			else
				st.active, st.open = id, true
			end
			UI.linkPick = nil
			UI.rebuildAfterToggle(side)
		end, { active = st.open and st.active == id, scale = 0.46,
			tip = (st.open and st.active == id) and "Click again to tuck this panel away" or nil })
	end
	button(inner, inner.size.w - ROW - 2, 2, ROW, ROW, st.open and "-" or "+", function()
		st.open = not st.open
		UI.rebuildAfterToggle(side)
	end, { tip = st.open and "Tuck this panel away" or "Open this panel" })

	if (not st.open) then return end
	local content = inner:addChild({ pos = { 0, UI.HEADER_H }, size = { inner.size.w, inner.size.h - UI.HEADER_H }, bgColor = C.bg })
	UI.dockContent[side] = content
	UI.refreshDock(side)
	-- Resize handle in the bottom-right corner, on top of the content
	UI.dockGrips = UI.dockGrips or {}
	UI.dockGrips[side] = layoutGrip(inner, inner.size.w - 16, inner.size.h - 16, 16, 16, "/", side, "resize", fullRect,
		"Drag to resize this panel")
end

function UI.refreshDock(side)
	local content = UI.dockContent[side]
	if (not content or content.destroyed) then return end
	content:kill(true)
	local id = UI.dockState[side].active
	local build = UI.TAB_BUILD[id]
	if (build) then
		local ok, err = pcall(build, content)
		if (not ok) then
			hint(content, PAD, PAD, content.size.w - PAD * 2, 80, "Something went wrong drawing this tab:\n" .. tostring(err), 0.45)
			echo("Mod Studio error: " .. tostring(err))
		end
	end
end

function UI.refresh()
	UI.needRefresh = false
	for _, d in ipairs(UI.DOCKS) do
		UI.refreshDock(d.side)
	end
end

function UI.buildDocks()
	for _, d in ipairs(UI.DOCKS) do
		UI.buildDock(d.side)
	end
end

---------------------------------------------------------------------------
-- Toolbar
---------------------------------------------------------------------------

function UI.setTool(tool)
	MS.settings.tool = tool
	UI.buildToolbar()
	if (tool ~= "measure") then MS.measure = {} end
	MS.toast(({ select = "Select tool", move = "Move tool - drag an arrow", rotate = "Rotate tool - drag a ring", scale = "Scale tool - drag a handle",
		measure = "Measure - click two points on objects or the floor" })[tool])
end

function UI.toggleSpace()
	MS.settings.space = MS.settings.space == "world" and "local" or "world"
	UI.buildToolbar()
	MS.toast(MS.settings.space == "world" and "Gizmo follows the world axes" or "Gizmo follows the object's own rotation")
end

function UI.toggleSnap()
	MS.settings.snap = not MS.settings.snap
	UI.buildToolbar()
	MS.toast("Snapping " .. (MS.settings.snap and "on" or "off") .. " (hold Ctrl to flip it while dragging)")
end

function UI.topBarH() return ROW + 10 end
function UI.statusH() return ROW + 4 end

function UI.buildToolbar()
	if (UI.toolbar) then UI.toolbar:kill() end
	if (not MS.active) then return end
	local st = MS.settings
	local items = {
		{ "Select", function() UI.setTool("select") end, st.tool == "select", "1 - Click objects. Shift+click adds, Shift+drag box-selects" },
		{ "Move", function() UI.setTool("move") end, st.tool == "move", "2 - Arrows: one axis. Squares: a plane. Center dot: free" },
		{ "Rotate", function() UI.setTool("rotate") end, st.tool == "rotate", "3 - Drag a colored ring" },
		{ "Scale", function() UI.setTool("scale") end, st.tool == "scale", "4 - Drag a handle to stretch, center to resize evenly" },
		{ "Measure", function() UI.setTool("measure") end, st.tool == "measure", "5 - Click two points to see the distance between them" },
		false,
		{ st.space == "world" and "World" or "Local", UI.toggleSpace, false, "L - Gizmo aligned to the world or to the object" },
		{ st.snap and "Snap on" or "Snap off", UI.toggleSnap, st.snap, "G - Snap to the grid (Ctrl flips it while dragging)" },
		{ st.surfaceSnap and "Stick on" or "Stick off", function()
			st.surfaceSnap = not st.surfaceSnap
			MS.saveSettings()
			UI.buildToolbar()
			MS.toast(st.surfaceSnap and "Dragged objects rest on other objects and line up with their edges (Shift flips it)" or "Dragged objects slide at their own height (Shift flips it)")
		end, st.surfaceSnap, "Dragged objects sit on whatever is under the cursor and line up edges. Hold Shift while dragging to flip" },
		false,
		{ "Undo", MS.undo, false, "Ctrl+Z" },
		{ "Redo", MS.redo, false, "Ctrl+Y" },
		{ "Focus", MS.focusSelection, false, "F - Point the camera at the selection" },
		{ "Test", function() UI.enterTest() end, false, "Play the mod, then come back to editing" },
		{ "Help", function() UI.toggleHelp() end, false, "H - Shortcuts and tips" },
		false,
		{ "Close", function() MS.close() end, false, "Close Mod Studio" }
	}
	local n, seps = 0, 0
	for _, it in ipairs(items) do if (it) then n = n + 1 else seps = seps + 1 end end
	local h = ROW + 4
	local L = MS.settings.layout and MS.settings.layout.toolbar
	local titleW = L and 0 or floor(96 * UI.k)
	local bw = math.min(floor(62 * UI.k), floor((WIN_W - 60 - titleW - seps * 10) / n))
	local contentW = n * (bw + GAP) + seps * 10 + 6 + 16 + GAP
	-- Docked: a full-width top bar. Moved by the user: a compact floating bar.
	local W = L and contentW or WIN_W
	local tx = L and MS.clamp(L.x, 0, WIN_W - W) or 0
	local ty = L and MS.clamp(L.y, 0, WIN_H - h - 6) or 0
	local bar = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { tx, ty }, size = { W, h + 6 },
		bgColor = C.darkest, shapeType = ROUNDED, rounded = L and 5 or 0, interactive = true
	})
	UI.toolbar = bar
	layoutGrip(bar, 3, 3, 16, h, "::", "toolbar", "move", function() return { bar.pos.x, bar.pos.y, contentW, bar.size.h } end,
		"Drag to move the toolbar (Settings > Reset panel layout docks it again)")
	if (not L) then label(bar, 3 + 16 + GAP * 2, 3, titleW, h, "MOD STUDIO", LEFTMID, 0.55, UI.TITLE_FONT) end
	local x = 3 + 16 + GAP + titleW
	for _, it in ipairs(items) do
		if (it) then
			button(bar, x, 3, bw, h, it[1], it[2], { active = it[3], tip = it[4], scale = 0.46 })
			x = x + bw + GAP
		else
			x = x + 10
		end
	end
	-- Docked bar: show tips / messages in the empty space after the buttons,
	-- clear of the game's own icons in the bottom-left corner
	UI.tipsInToolbar = false
	local tipW = W - x - 16
	if (not L and tipW > 160) then
		UI.tipsInToolbar = true
		local tipEl = bar:addChild({ pos = { x + 12, 3 }, size = { tipW, h } })
		tipEl:addCustomDisplay(true, function(init)
			if (init) then return end
			local s, isToast = UI.statusText()
			tipEl:uiText(s or "", nil, nil, 4, LEFTMID, 0.47 * UI.textK, nil, nil, isToast and { 1, 0.9, 0.45, 1 } or nil)
		end)
	end
end

---------------------------------------------------------------------------
-- Status bar
---------------------------------------------------------------------------

local function contextHint()
	local G = MS.G
	if (G.drag and G.drag.started) then
		return "Release to finish. Scroll to zoom. Right-click or Esc cancels. Hold Ctrl to flip snapping."
	end
	if (UI.parentPick) then
		return "Click the object that should become the parent (3D view or Scene list). Esc cancels."
	end
	if (UI.linkPick) then
		return UI.linkPick.stage == 1 and "Click the first object to link" or "Click the second object to link"
	end
	if (G.hover) then
		local t = G.hover.type
		if (t == "axis") then return "Drag to move along " .. ({ "X (red)", "Y (green)", "Z (blue, up/down)" })[G.hover.k] end
		if (t == "plane") then return "Drag to move across a flat plane" end
		if (t == "free") then return "Drag to move freely, facing the camera" end
		if (t == "ring") then return "Drag to rotate around " .. ({ "X", "Y", "Z" })[G.hover.k] end
		if (t == "saxis") then return "Drag to stretch along " .. ({ "X", "Y", "Z" })[G.hover.k] end
		if (t == "suni") then return "Drag to resize evenly" end
	end
	if (G.hoverVertex) then return "Drag this corner to reshape the triangle" end
	if (G.hoverObj) then return "Click to select " .. MS.objName(G.hoverObj) .. ". Drag to slide it (Alt: up/down)" end
	if (MS.settings.tool == "measure") then
		return (MS.measure and MS.measure.a and not MS.measure.b) and "Click the second point" or "Click a point on an object or the floor to start measuring (Snap rounds to the grid)"
	end
	if (G.hoverBody) then return "Click to select " .. (MS.BODY_NAMES[G.hoverBody.b] or "this body part") end
	if (UI.isTabOpen("players")) then return "Click a body part in the world or the grid. Use the gizmo to move/resize it." end
	if (UI.isTabOpen("joints")) then return "Click a joint in the world or the grid to edit it." end
	if (MS.selCount() == 0) then return "Click an object to select it - or add one from the Objects / Create tab. H = help" end
	return "Arrows: nudge | Ctrl+D: duplicate | Del: delete | F: focus | Ctrl+Z: undo | 1-4: tools"
end

function UI.statusText()
	local now = MS.clock()
	if (MS.toastMsg and now - (MS.toastClock or 0) < 3.5) then
		return MS.toastMsg, true
	end
	local te = UI.tipElem
	if (UI.tipText and te and not te.destroyed and te.displayed ~= false and te.hoverState and te.hoverState ~= BTN_NONE) then
		return UI.tipText
	end
	return contextHint()
end

function UI.buildStatus()
	if (UI.status) then UI.status:kill() end
	local L = MS.settings.layout and MS.settings.layout.status
	local SH = UI.statusH()
	local W = L and math.min(WIN_W - 40, floor(820 * UI.k)) or WIN_W
	local bar = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { L and MS.clamp(L.x, 0, WIN_W - W) or 0, L and MS.clamp(L.y, 0, WIN_H - SH) or WIN_H - SH }, size = { W, SH },
		bgColor = L and { 0, 0, 0, 0.6 } or C.darkest, shapeType = ROUNDED, rounded = L and 5 or 0, interactive = true
	})
	UI.status = bar
	bar:addMouseHandlers(function()
		UI.startPointerDrag({ kind = "layout", target = "status", mode = "move", rect0 = { bar.pos.x, bar.pos.y, bar.size.w, bar.size.h } })
	end)
	local textEl = bar:addChild({ pos = { 10, 0 }, size = { W - 190, SH } })
	textEl:addCustomDisplay(true, function(init)
		-- Tips live in the top bar when it's docked
		if (init or UI.tipsInToolbar) then return end
		local s, isToast = UI.statusText()
		textEl:uiText(s or "", nil, nil, 4, LEFTMID, 0.47 * UI.textK, nil, nil, isToast and { 1, 0.9, 0.45, 1 } or nil)
	end)
	local countEl = bar:addChild({ pos = { W - 180, 0 }, size = { 170, SH } })
	countEl:addCustomDisplay(true, function(init)
		if (init) then return end
		local n = MS.selCount()
		local limit = MS.settings.objLimit or 0
		local s = (n > 0 and (n .. " selected | ") or "") .. MS.count(MS.objs) .. (limit > 0 and (" / " .. limit) or "") .. " objects"
		countEl:uiText(s, nil, nil, 4, RIGHTMID, 0.43 * UI.textK)
	end)
end

---------------------------------------------------------------------------
-- Help overlay
---------------------------------------------------------------------------

UI.HELP = {
	{ "Getting around", true },
	{ "Panels", "Left: Scene. Right: Properties. Bottom: File/Rules/Stats. Click an open tab to tuck it away" },
	{ "Right-drag", "Turn the camera (same as normal Toribash)" },
	{ "F", "Point the camera at what's selected" },
	{ "Selecting", true },
	{ "Click", "Select an object (or body part on the Bodies tab)" },
	{ "Shift+click", "Add / remove from the selection" },
	{ "Shift+drag", "Box-select on empty space" },
	{ "Ctrl+A / Esc", "Select everything / deselect" },
	{ "Editing", true },
	{ "1 2 3 4 5", "Select, Move, Rotate, Scale, Measure tools" },
	{ "Drag object", "It rests on what's under the cursor and lines up edges (Shift: off, Alt: up/down)" },
	{ "Scroll (gizmo drag)", "Zoom in/out without letting go - the object stays put, keep dragging after" },
	{ "Arrow keys", "Nudge by one grid step (PgUp/PgDn: up/down, Shift: finer)" },
	{ "L / G", "World or local gizmo / snapping on or off" },
	{ "Ctrl (dragging)", "Temporarily flip snapping" },
	{ "Ctrl+D / Del", "Duplicate / delete" },
	{ "Ctrl+C / Ctrl+V", "Copy / paste" },
	{ "Ctrl+Z / Ctrl+Y", "Undo / redo (everything is undoable)" },
	{ "Parenting", true },
	{ "P", "Make the selection children of the object clicked last" },
	{ "Shift+P", "Unparent the selection (nothing moves)" },
	{ "[  /  ]", "Select parent / select children (Shift+]: whole branch)" },
	{ "Children", "Follow their parent when it's moved, turned, resized, copied or mirrored" },
	{ "More", true },
	{ "Scroll (dragging)", "While click-dragging an object: push it away / pull it closer. Shift+scroll zooms" },
	{ "Alt + gizmo drag", "Drag out a copy instead of moving the original" },
	{ "Ctrl+H / Ctrl+Shift+H", "Hide the selection in the editor / show everything" },
	{ "Ctrl+I", "Isolate: hide everything except the selection (again to show all)" },
	{ "Ctrl+Shift+C / V", "Copy / paste all properties (color, physics, thrust, trigger)" },
	{ "Panels", "Drag :: to move a panel, the / corner to resize it. Scroll lists with the wheel" },
	{ "Files", true },
	{ "Ctrl+S", "Save project (keeps names, groups, parents, triangles)" },
	{ "Ctrl+E", "Export a playable .tbm mod" },
	{ "Tip", "Drag any field's label left/right to change it" }
}

function UI.toggleHelp(force)
	if (UI.help and not force) then
		UI.help:kill()
		UI.help = nil
		if (MS.settings.firstRun) then
			MS.settings.firstRun = false
			MS.saveSettings()
		end
		return
	end
	if (UI.help) then UI.help:kill() end
	local rowH = 20
	local W = math.min(560, WIN_W - 40)
	local H = 70 + #UI.HELP * rowH + 40
	local box = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { floor((WIN_W - W) / 2), floor((WIN_H - H) / 2) }, size = { W, H },
		bgColor = C.darkest, shapeType = ROUNDED, rounded = 8, interactive = true
	})
	UI.help = box
	local inner = box:addChild({ shift = { 2, 2 }, bgColor = C.bg }, true)
	label(inner, 14, 8, W - 30, 30, MS.settings.firstRun and "Welcome to Mod Studio!" or "Mod Studio - shortcuts", LEFTMID, 0.75, UI.TITLE_FONT)
	local y = 44
	for _, row in ipairs(UI.HELP) do
		if (row[2] == true) then
			local bar = inner:addChild({ pos = { 10, y + 2 }, size = { W - 24, rowH - 2 }, bgColor = C.darkest, shapeType = ROUNDED, rounded = 3 })
			bar:addAdaptedText(false, row[1], 6, nil, 4, LEFTMID, 0.48)
		else
			label(inner, 18, y, 150, rowH, row[1], LEFTMID, 0.47)
			label(inner, 170, y, W - 190, rowH, row[2], LEFTMID, 0.47)
		end
		y = y + rowH
	end
	button(inner, W / 2 - 80, H - 36, 160, 28, MS.settings.firstRun and "Let's go!" or "Close (H)", function() UI.toggleHelp() end)
end

---------------------------------------------------------------------------
-- Confirm dialog
---------------------------------------------------------------------------

---buttons = { { text, fn }, ... } - a button without fn just closes
function UI.confirm(title, message, buttons)
	if (UI.dialog) then UI.dialog:kill() end
	UI.modalOpen = true
	local shade = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { 0, 0 }, size = { WIN_W, WIN_H },
		bgColor = { 0, 0, 0, 0.45 }, interactive = true
	})
	UI.dialog = shade
	local W, H = math.min(420, WIN_W - 40), 150
	local box = shade:addChild({ pos = { floor((WIN_W - W) / 2), floor((WIN_H - H) / 2) }, size = { W, H }, bgColor = C.darkest, shapeType = ROUNDED, rounded = 8 })
	local inner = box:addChild({ shift = { 2, 2 }, bgColor = C.bg }, true)
	label(inner, 14, 8, W - 28, 28, title, LEFTMID, 0.65, UI.TITLE_FONT)
	hint(inner, 14, 38, W - 28, 50, message, 0.5)
	local n = #buttons
	local bw = (W - 28 - GAP * (n - 1)) / n
	for i, b in ipairs(buttons) do
		button(inner, 14 + (i - 1) * (bw + GAP), H - 40, bw, 28, b[1], function()
			UI.closeDialog()
			if (b[2]) then b[2]() end
		end, { active = i == 1 })
	end
end

function UI.closeDialog()
	if (UI.dialog) then UI.dialog:kill() end
	UI.dialog = nil
	UI.modalOpen = false
end

---------------------------------------------------------------------------
-- Test mode
---------------------------------------------------------------------------

function UI.enterTest()
	MS.flush(true)
	MS.endDragSilently()
	local ok, res = pcall(enter_mod_maker_test_mode)
	if (not ok or not res) then
		MS.toast("Couldn't start test mode right now")
		return
	end
	MS.testMode = true
	for _, el in ipairs(UI.roots()) do
		if (el and not el.destroyed) then el:hide() end
	end
	local bar = UIElement:new({
		globalid = TB_MENU_HUB_GLOBALID,
		pos = { floor(WIN_W / 2 - 150), 8 }, size = { 300, 34 },
		bgColor = C.darkest, shapeType = ROUNDED, rounded = 6, interactive = true
	})
	UI.testBar = bar
	label(bar, 10, 3, 140, 28, "Testing your mod", LEFTMID, 0.5)
	button(bar, 150, 3, 146, 28, "Back to editing", UI.exitTest, { active = true })
end

function UI.exitTest()
	pcall(exit_mod_maker_test_mode)
	MS.testMode = false
	if (UI.testBar) then UI.testBar:kill() end
	UI.testBar = nil
	for _, el in ipairs(UI.roots()) do
		if (el and not el.destroyed and el ~= UI.testBar) then el:show() end
	end
	MS.markDirty()
	UI.requestRefresh()
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

function UI.open()
	WIN_W, WIN_H = get_window_size()
	UI.applyTheme()
	UI.buildDocks()
	UI.buildToolbar()
	UI.buildStatus()
end

function UI.close()
	for _, key in ipairs({ "dialog", "help", "toolbar", "status", "testBar" }) do
		if (UI[key] and not UI[key].destroyed) then UI[key]:kill() end
		UI[key] = nil
	end
	for side, el in pairs(UI.dockEls) do
		if (el and not el.destroyed) then el:kill() end
		UI.dockEls[side], UI.dockContent[side] = nil, nil
	end
	UI.modalOpen = false
end

function UI.tick()
	if (UI.pointerDrag) then followPointerDrag() end
	if (UI.filterDirty) then
		-- Rebuilding while typing would steal focus from the search box, so wait until it loses focus
		if (not UI.fieldFocused()) then
			UI.filterDirty = false
			UI.needRefresh = true
		end
	end
	if (UI.needRefresh) then
		UI.scrollAreas = {}
		UI.refresh()
	end
end

UI.applyTheme()
