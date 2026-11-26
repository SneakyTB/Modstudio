

local MS = MS
local UI = MS.UI
local floor = math.floor

UI.tourState = nil

local function rectOf(el)
	if (el and not el.destroyed and el.pos and el.size and el.size.w > 0) then
		return { el.pos.x, el.pos.y, el.size.w, el.size.h }
	end
	return nil
end

local function sideOf(id)
	for _, d in ipairs(UI.DOCKS or {}) do
		for _, t in ipairs(d.tabs) do
			if (t[1] == id) then return d.side end
		end
	end
	return nil
end

local function panel(id)
	return function()
		if (not (UI.isTabOpen and UI.isTabOpen(id))) then UI.selectTab(id) end
		local side = sideOf(id)
		return rectOf(side and UI.dockEls and UI.dockEls[side])
	end
end

local function toolbar(key)
	return function() return rectOf(UI.toolbarBtns and UI.toolbarBtns[key]) end
end

local function viewport()
	local x0, x1, y0, y1 = 0, WIN_W, 0, WIN_H
	local tb = UI.toolbar
	if (tb and not tb.destroyed and tb.pos.y < WIN_H / 2) then y0 = tb.pos.y + tb.size.h end
	local d = UI.dockEls or {}
	if (d.left and not d.left.destroyed and d.left.pos.x < WIN_W / 2) then x0 = d.left.pos.x + d.left.size.w end
	if (d.right and not d.right.destroyed and d.right.pos.x > WIN_W / 2) then x1 = d.right.pos.x end
	if (d.bottom and not d.bottom.destroyed and d.bottom.pos.y > WIN_H / 2) then y1 = d.bottom.pos.y end
	if (x1 - x0 < 100 or y1 - y0 < 100) then return nil end
	return { x0 + 8, y0 + 8, x1 - x0 - 16, y1 - y0 - 16 }
end

UI.TOUR = {
	{ title = "Welcome to Mod Studio!",
		text = "A quick look at the main parts, one at a time. Use Next and Back, or Skip whenever you like." },
	{ title = "Scene", target = panel("scene"),
		text = "Every object in your mod. Click one to select it, Shift+click to add more, double-click to rename it." },
	{ title = "Create", target = panel("create"),
		text = "Add shapes, floors, walls, ramps and triangles. New pieces appear where the camera is looking." },
	{ title = "Library", target = panel("library"),
		text = "Ready-made pieces. Save a selection as your own prefab and place it again any time." },
	{ title = "Tools", target = toolbar("Move"),
		text = "Select, Move, Rotate and Scale (F1 to F4), and Measure (F9). Select something, then drag the gizmo's arrows." },
	{ title = "3D view", target = viewport,
		text = "Click an object, body part or joint to select it. Right-drag turns the camera, the . key points it at the selection." },
	{ title = "Properties", target = panel("properties"),
		text = "Exact values for what you selected: position, size, rotation, colour and physics. Drag a label left or right to change it." },
	{ title = "Bodies", target = panel("players"),
		text = "Pick Tori or Uke and a body part to change its shape and physics. Add / remove limbs gives them extra parts." },
	{ title = "Joints", target = panel("joints"),
		text = "Strength, speed, angle limits and 360 spin for every joint. Add / connect joints makes new ones." },
	{ title = "Rules", target = panel("rules"),
		text = "Match length, gravity, dismemberment, game flags and the rest of the match rules." },
	{ title = "File", target = panel("file"),
		text = "Export a playable .tbm (Ctrl+E), save projects (Ctrl+S), start from a template, or reset." },
	{ title = "Undo and redo", target = toolbar("Undo"),
		text = "Everything can be undone (Ctrl+Z / Ctrl+Y). The History tab jumps back several steps at once." },
	{ title = "Test", target = toolbar("Test"),
		text = "Play your mod straight away, then come back to keep editing." },
	{ title = "Autosave", target = toolbar("Auto"),
		text = "Backs your work up to the _autosave project every few minutes. Click to turn it on or off." },
	{ title = "Help", target = toolbar("Help"),
		text = "Press H any time for every shortcut. You can replay this tour from Settings." },
}

local function killEls()
	for _, k in ipairs({ "tour", "tourFrame" }) do
		if (UI[k] and not UI[k].destroyed) then UI[k]:kill() end
		UI[k] = nil
	end
end

function UI.tourStop(silent)
	local st = UI.tourState
	killEls()
	if (not st) then return end
	UI.tourState = nil
	UI.modalOpen = false
	if (silent) then return end
	if (MS.settings.firstRun) then
		MS.settings.firstRun = false
		MS.saveSettings()
	end

	if (st.docks and UI.dockState) then
		for side, d in pairs(st.docks) do UI.dockState[side] = d end
		if (UI.saveDockState) then UI.saveDockState() end
		if (UI.buildDocks) then UI.buildDocks() end
	end
end

local function place(r, W, H)
	local margin, gap = 8, 16
	local function clampX(x) return math.max(margin, math.min(WIN_W - W - margin, x)) end
	local function clampY(y) return math.max(margin, math.min(WIN_H - H - margin, y)) end
	if (not r) then return floor((WIN_W - W) / 2), floor((WIN_H - H) / 2) end
	local cx = r[1] + r[3] / 2

	if (r[2] + r[4] + gap + H <= WIN_H - margin) then return clampX(cx - W / 2), r[2] + r[4] + gap end
	if (r[2] - gap - H >= margin) then return clampX(cx - W / 2), r[2] - gap - H end
	local cy = r[2] + r[4] / 2
	if (r[1] + r[3] + gap + W <= WIN_W - margin) then return r[1] + r[3] + gap, clampY(cy - H / 2) end
	if (r[1] - gap - W >= margin) then return r[1] - gap - W, clampY(cy - H / 2) end
	return clampX(cx - W / 2), clampY(cy - H / 2)
end

function UI.tourShow(i)
	local st = UI.tourState
	if (not st) then return end
	st.i = math.max(1, math.min(#UI.TOUR, i))
	killEls()
	local step = UI.TOUR[st.i]
	local ok, r = true, nil
	if (step.target) then ok, r = pcall(step.target) end
	if (not ok) then r = nil end

	local ROW, GAP = UI.sizes()
	local W = math.min(330, WIN_W - 40)
	local sc = UI.textSize("body") * UI.textK
	local msgH = 40
	local probe = UIElement:new({ globalid = TB_MENU_HUB_GLOBALID, pos = { 0, 0 }, size = { W - 28, msgH } })
	while (msgH < 220) do
		local okf, fits = pcall(probe.uiText, probe, step.text, nil, nil, 4, nil, sc, nil, nil, nil, nil, nil, true)
		if (not okf or fits) then break end
		msgH = msgH + 8
		probe.size.h = msgH
	end
	probe:kill()

	local okw, tw = pcall(get_string_length, step.text, 4)
	if (okw and type(tw) == "number") then
		local lines = math.ceil(tw * sc * 1.12 / (W - 28))
		msgH = math.max(msgH, lines * floor(34 * sc + 2) + 6)
	end
	local H = 34 + msgH + 8 + ROW + 14

	local bx, by
	if (r and r[3] * r[4] > WIN_W * WIN_H * 0.12) then
		bx = floor(math.max(8, math.min(WIN_W - W - 8, r[1] + (r[3] - W) / 2)))
		by = floor(math.max(8, math.min(WIN_H - H - 8, r[2] + math.min(r[4] * 0.35, r[4] - H - 12))))
	else
		bx, by = place(r, W, H)
	end

	if (r) then
		local fx, fy, fw, fh = r[1] - 3, r[2] - 3, r[3] + 6, r[4] + 6
		local frame = UIElement:new({ globalid = TB_MENU_HUB_GLOBALID, pos = { 0, 0 }, size = { WIN_W, WIN_H } })
		frame:addCustomDisplay(true, function()
			local c = UI.C.lightest
			set_color(c[1], c[2], c[3], 0.95)
			local t = 3
			draw_quad(fx, fy, fw, t)
			draw_quad(fx, fy + fh - t, fw, t)
			draw_quad(fx, fy, t, fh)
			draw_quad(fx + fw - t, fy, t, fh)

			local tx = math.max(fx, math.min(fx + fw, bx + W / 2))
			local ty = math.max(fy, math.min(fy + fh, by + H / 2))
			if (by >= fy + fh) then
				draw_quad(math.max(bx + 12, math.min(bx + W - 14, tx)) - 1, fy + fh, 3, by - (fy + fh))
			elseif (by + H <= fy) then
				draw_quad(math.max(bx + 12, math.min(bx + W - 14, tx)) - 1, by + H, 3, fy - (by + H))
			elseif (bx >= fx + fw) then
				draw_quad(fx + fw, math.max(by + 12, math.min(by + H - 14, ty)) - 1, bx - (fx + fw), 3)
			elseif (bx + W <= fx) then
				draw_quad(bx + W, math.max(by + 12, math.min(by + H - 14, ty)) - 1, fx - (bx + W), 3)
			end
		end)
		UI.tourFrame = frame
	end

	local box = UIElement:new({ globalid = TB_MENU_HUB_GLOBALID, pos = { bx, by }, size = { W, H },
		bgColor = UI.C.lightest, shapeType = ROUNDED, rounded = UI.r(6), interactive = true })
	UI.tour = box
	local inner = box:addChild({ shift = { 2, 2 }, bgColor = UI.C.darkest }, true)
	UI.label(inner, 12, 6, W - 80, 26, step.title, LEFTMID, "heading", UI.TITLE_FONT)
	UI.label(inner, W - 72, 6, 56, 26, st.i .. " / " .. #UI.TOUR, RIGHTMID or LEFTMID, "small")
	UI.hint(inner, 12, 34, W - 28, msgH, step.text, "body")
	local bw = (W - 28 - GAP * 2) / 3
	local yb = H - ROW - 12
	local last = st.i == #UI.TOUR
	UI.button(inner, 12, yb, bw, ROW, "Skip tour", function() UI.tourStop() end,
		{ tip = "End the tour (replay it from Settings or the help screen)" })
	UI.button(inner, 12 + bw + GAP, yb, bw, ROW, "Back", function() UI.tourShow(st.i - 1) end, { disabled = st.i == 1 })
	UI.button(inner, 12 + (bw + GAP) * 2, yb, bw, ROW, last and "Finish" or "Next", function()
		if (last) then UI.tourStop() else UI.tourShow(st.i + 1) end
	end, { active = true })
	UI.modalOpen = true
	UI.raiseOverlays()
end

function UI.tourStart()
	if (UI.help and UI.toggleHelp) then
		UI.help:kill()
		UI.help = nil
	end
	local docks = {}
	for side, d in pairs(UI.dockState or {}) do docks[side] = { active = d.active, open = d.open } end
	UI.tourState = { i = 1, docks = docks }
	UI.tourShow(1)
end
