-- ModuleScript: UI
-- Builds the gui, owns input (clicks, right-click / long-press slider popover) and the
-- minimize/expand + countdown state. All motion is delegated to Animations.
-- It knows nothing about what the toggles actually do: it just calls ui.onChanged(id, enabled, value, opts).
--
-- Slider popover notes (why it no longer closes by itself):
--   * a full-screen "scrim" button sits under the popover while it is open. Pressing it closes the
--     popover. The popover sits above the scrim, so presses on the slider can never reach it.
--     No hit-testing math, so mouse / touch / inset differences cannot close it by accident.
--   * dragging reads the real pointer X every move event and keeps going even if the pointer
--     leaves the popover.
--   * mouse wheel over a slider nudges it for fine control.
--
-- The popover is the feature's settings menu: the row's main slider (when it has one) followed by the row's
-- `opts` controls (slider / hue / toggle / choice). Values live in row.optv and are handed to onChanged.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local import = ...
local Util = import("Util")

local UI = {}
UI.__index = UI

UI.CONFIG = {
	HideSeconds = 4,
	ToggleKey = Enum.KeyCode.Insert,
	TopOffset = 12,
	Width = 600, -- the height is not fixed, it follows the active tab (see UI:_layoutFor)
	Pill = Vector2.new(176, 38),
	LongPressSeconds = 0.5,
	SlideDistance = 180, -- how far panels travel when switching tabs
	ScreenMargin = 24, -- free space kept under the menu before a tab starts scrolling
	RepeatDelay = 0.35,
	RepeatRate = 0.04,
}

UI.THEME = {
	panel = Color3.fromRGB(22, 24, 31),
	panel2 = Color3.fromRGB(31, 34, 43),
	line = Color3.fromRGB(42, 46, 58),
	text = Color3.fromRGB(236, 238, 244),
	muted = Color3.fromRGB(138, 144, 160),
	accent = Color3.fromRGB(139, 125, 255),
	white = Color3.fromRGB(255, 255, 255),
	good = Color3.fromRGB(72, 214, 134), -- menu open / feature on
	bad = Color3.fromRGB(255, 84, 96), -- menu closed / countdown about to expire
}

local CFG, C = UI.CONFIG, UI.THEME
local LEAD_W = 70
local LEAD_EXP = UDim2.new(0, 14, 0, 0)
local LEAD_MIN = UDim2.new(0.5, -LEAD_W / 2, 0, 0)
-- vertical layout of the expanded menu: header + tab bar + PANEL_Y.. rows ..GAP, hint line, PAD
local PANEL_X, PANEL_Y, PANEL_W = 14, 86, 572
local CELL_H, GAP = 38, 8 -- one row, space between rows
local HEAD_H, SEC_GAP = 20, 10 -- section title line, space between sections
local HINT_H, PAD = 14, 8
local CHROME = PANEL_Y + GAP + HINT_H + PAD -- everything that is not the row panel
local PANEL_POS = UDim2.fromOffset(PANEL_X, PANEL_Y)
local POP_W = 290
local POP_HEAD = 34
local HUE_STOPS = {}
for i = 0, 6 do
	HUE_STOPS[#HUE_STOPS + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 0.85, 1))
end
local HUE_SEQ = ColorSequence.new(HUE_STOPS)

---------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------
local function make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function corner(obj, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r) }, obj)
end

local function isOver(obj, p)
	local pos, size = obj.AbsolutePosition, obj.AbsoluteSize
	return p.X >= pos.X and p.X <= pos.X + size.X and p.Y >= pos.Y and p.Y <= pos.Y + size.Y
end

local function pointerOf(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
	end
	return UserInputService:GetMouseLocation()
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function shown(row, v)
	if row.fmt then
		return row.fmt(v)
	end
	return tostring(v)
end

-- text for an option control's value
local function fmtOpt(d, v)
	if d.fmt then
		return d.fmt(v)
	end
	if d.type == "hue" then
		return ("%d deg"):format(math.floor(v * 360 + 0.5))
	end
	if d.pct then
		return ("%d%%"):format(math.floor(v * 100 + 0.5))
	end
	local step = d.step or 1
	local dec = step >= 1 and 0 or (step >= 0.1 and 1 or 2)
	local text = dec == 0 and ("%d"):format(math.floor(v + 0.5)) or ("%." .. dec .. "f"):format(v)
	return text .. (d.unit or "")
end

-- a saved / default option value, checked against its definition (nil = not usable)
local function sane(d, v)
	local t = d.type
	if t == "toggle" then
		if type(v) == "boolean" then
			return v
		end
	elseif t == "choice" then
		for _, c in ipairs(d.choices) do
			if c == v then
				return v
			end
		end
	elseif type(v) == "number" then
		return math.clamp(v, d.min or 0, d.max or (t == "hue" and 1 or 100))
	end
	return nil
end

---------------------------------------------------------------------
-- construction
---------------------------------------------------------------------
function UI.new(deps)
	local self = setmetatable({}, UI)
	self.A = deps.Animations
	self.title = deps.title or "FMenu"
	self.profileName = deps.profileName or ""
	self.onChanged = function(_id, _enabled, _value) end

	self.state = {
		minimized = false,
		mode = "run", -- run | hold | idle
		deadline = 0,
		shown = 1,
		tab = 1,
		activeRow = nil,
		popOpen = false,
		drag = nil, -- { ctl, input } while a popover slider is being dragged
		hover = nil, -- slider under the pointer (mouse wheel target)
		token = 0,
		autoHide = true,
		hideSeconds = CFG.HideSeconds,
	}
	self.rowList, self.rowsById = {}, {}
	self.tabButtons, self.panels, self.scrolls, self.tabRows, self.tabBadges = {}, {}, {}, {}, {}
	self.expanded = Vector2.new(CFG.Width, 246) -- real height is set per tab once the rows exist
	self.tabNatural = {} -- tab index -> height its sections need
	self.surfaceT = 0 -- background transparency of the menu surfaces (see UI:setOpacity)
	self._conns = {}

	self:_buildShell()
	self:_bindInput()
	return self
end

function UI:_buildShell()
	local gui = make("ScreenGui", {
		Name = "MenuWidget",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1100, -- above the HUD gui and above Roblox's own core gui
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	Util.mount(gui)
	self.gui = gui

	-- CanvasGroup so the rounded corners actually clip the contents
	local root = make("CanvasGroup", {
		Name = "Root",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, CFG.TopOffset),
		Size = UDim2.fromOffset(self.expanded.X, self.expanded.Y),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
	}, gui)
	corner(root, 19)
	make("UIStroke", { Color = C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, root)
	self.scale = make("UIScale", { Scale = 1 }, root)
	self.root = root

	-- fixed-width body, centered, so the pill shrink clips evenly from both sides (no reflow)
	self.body = make("CanvasGroup", {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(self.expanded.X, self.expanded.Y),
		BackgroundTransparency = 1,
		ZIndex = 1,
	}, root)

	-- countdown bar
	self.barGroup = make("CanvasGroup", {
		Name = "Bar",
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, root)
	self.barFill = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
	}, self.barGroup)

	-- header
	self.header = make("TextButton", {
		Name = "Header",
		Position = UDim2.fromOffset(0, 3),
		Size = UDim2.new(1, 0, 0, 35),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 2,
	}, root)
	self.lead = make("Frame", {
		Size = UDim2.new(0, LEAD_W, 1, 0),
		Position = LEAD_EXP,
		BackgroundTransparency = 1,
	}, self.header)

	-- status dot: red = closed, green = open (+ pulsing ring while open)
	self.ring = make("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 5, 0.5, 0),
		Size = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1,
	}, self.lead)
	corner(self.ring, 20)
	self.ringStroke = make("UIStroke", {
		Color = C.good, Thickness = 2, Transparency = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, self.ring)
	self.dot = make("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 5, 0.5, 0),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = C.bad,
		BorderSizePixel = 0,
	}, self.lead)
	corner(self.dot, 5)

	make("TextLabel", {
		Text = self.title,
		Position = UDim2.fromOffset(19, 0),
		Size = UDim2.new(0, 48, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, self.lead)
	self.sub = make("TextLabel", {
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(260, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = C.muted,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, self.header)

	-- tab bar (buttons are added in build)
	self.tabBar = make("Frame", {
		Name = "Tabs",
		Position = UDim2.fromOffset(14, 44),
		Size = UDim2.fromOffset(PANEL_W, 32),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
	}, self.body)
	corner(self.tabBar, 10)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
	}, self.tabBar)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, self.tabBar)

	-- pinned to the bottom of the body, so it always sits right under the last row
	self.hint = make("TextLabel", {
		Text = "click = toggle  |  right-click or long-press = settings  |  drag HUD text to move  |  Insert = hide",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -PAD),
		Size = UDim2.fromOffset(CFG.Width, HINT_H),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = C.muted,
	}, self.body)

	-- scrim: sits under the popover, any press on it closes the popover
	self.scrim = make("TextButton", {
		Name = "Scrim",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 9,
	}, gui)

	-- settings popover lives on the ScreenGui so nothing clips it. Its controls are rebuilt every time it opens.
	local pop = make("CanvasGroup", {
		Name = "SliderPopover",
		Size = UDim2.fromOffset(POP_W, 100),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 10,
	}, gui)
	corner(pop, 12)
	make("UIStroke", { Color = C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, pop)
	self.pop = pop
	self.popName = make("TextLabel", {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.fromOffset(POP_W - 90, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, pop)
	self.popReset = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(56, 22),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
		TextColor3 = C.muted,
		Text = "reset",
	}, pop)
	corner(self.popReset, 7)
	self.popScroll = make("ScrollingFrame", {
		Position = UDim2.fromOffset(0, POP_HEAD),
		Size = UDim2.new(1, 0, 1, -POP_HEAD),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		ScrollBarImageColor3 = C.line,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, pop)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, self.popScroll)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 10),
	}, self.popScroll)

	-- handed to Animations for minimize/expand
	self.refs = {
		root = self.root,
		body = self.body,
		barGroup = self.barGroup,
		sub = self.sub,
		lead = self.lead,
	}
end

---------------------------------------------------------------------
-- build tabs + rows from a profile's tab list
---------------------------------------------------------------------
-- tabs = { { name = "Main", rows = { { id, label, slider, value, on, fmt? }, ... } }, ... }
function UI:build(tabs)
	local n = #tabs
	for i, tab in ipairs(tabs) do
		local tbtn = make("TextButton", {
			LayoutOrder = i,
			Text = tab.name,
			Size = UDim2.new(1 / n, -((n - 1) * 4) / n, 1, 0),
			AutoButtonColor = false,
			BackgroundColor3 = C.panel,
			BackgroundTransparency = i == 1 and self.surfaceT or 1,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = i == 1 and C.text or C.muted,
		}, self.tabBar)
		corner(tbtn, 7)
		self.tabButtons[i] = tbtn
		-- number of features that are on inside this tab (hidden at 0)
		local badge = make("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -3, 0, 2),
			Size = UDim2.fromOffset(0, 12),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = C.good,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 9,
			TextColor3 = C.panel,
			Text = "0",
			Visible = false,
		}, tbtn)
		corner(badge, 6)
		make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, badge)
		make("UISizeConstraint", { MinSize = Vector2.new(12, 12) }, badge)
		self.tabBadges[i] = badge
		self.tabRows[i] = {}
		table.insert(self._conns, tbtn.MouseButton1Click:Connect(function()
			self:_selectTab(i)
		end))

		-- panel = clipped, sized to the tab's rows (animated as a whole when switching tabs).
		-- scroll = only does anything when the rows are taller than the screen allows.
		local panel = make("CanvasGroup", {
			Name = "Panel_" .. tab.name,
			Position = PANEL_POS,
			Size = UDim2.fromOffset(PANEL_W, CELL_H),
			BackgroundTransparency = 1,
			Visible = i == 1,
		}, self.body)
		local scroll = make("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 0,
			ScrollBarImageColor3 = C.line,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ElasticBehavior = Enum.ElasticBehavior.Never,
		}, panel)
		make("UIListLayout", {
			Padding = UDim.new(0, SEC_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, scroll)
		self.panels[i] = panel
		self.scrolls[i] = scroll

		-- tab.rows may contain { header = "Title" } entries: they start a new titled section. Rows before the
		-- first header (or in a tab without any) form an untitled section. Each section is its own 2 column grid.
		local sections, cur = {}, nil
		for _, data in ipairs(tab.rows) do
			if data.header then
				cur = { title = data.header, rows = {} }
				sections[#sections + 1] = cur
			else
				if not cur then
					cur = { rows = {} }
					sections[#sections + 1] = cur
				end
				cur.rows[#cur.rows + 1] = data
			end
		end
		local natural, shownSections = 0, 0
		for _, sec in ipairs(sections) do
			if #sec.rows > 0 then
				shownSections += 1
				local lines = math.ceil(#sec.rows / 2)
				local gridH = lines * CELL_H + (lines - 1) * GAP
				local top = sec.title and HEAD_H or 0
				natural += top + gridH + (shownSections > 1 and SEC_GAP or 0)
				local frame = make("Frame", {
					Name = "Section",
					LayoutOrder = shownSections,
					Size = UDim2.new(1, 0, 0, top + gridH),
					BackgroundTransparency = 1,
				}, scroll)
				if sec.title then
					make("TextLabel", {
						Position = UDim2.fromOffset(3, 0),
						Size = UDim2.new(1, -3, 0, HEAD_H - 6),
						BackgroundTransparency = 1,
						Font = Enum.Font.GothamBold,
						TextSize = 10,
						TextColor3 = C.muted,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = sec.title:upper(),
					}, frame)
				end
				local grid = make("Frame", {
					Position = UDim2.fromOffset(0, top),
					Size = UDim2.new(1, 0, 0, gridH),
					BackgroundTransparency = 1,
				}, frame)
				make("UIGridLayout", {
					CellSize = UDim2.new(0.5, -4, 0, CELL_H),
					CellPadding = UDim2.fromOffset(GAP, GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}, grid)
				for r, data in ipairs(sec.rows) do
					self:_buildRow(data, r, grid, i)
				end
			end
		end
		self.tabNatural[i] = natural
	end
	self.built = true
	self:_applyHeight(false)
	self:refreshStatus()
end

function UI:rows()
	return self.rowList
end

function UI:_buildRow(data, order, parent, tabIndex)
	local row = {
		id = data.id,
		label = data.label,
		slider = data.slider or data.label,
		value = data.value,
		on = data.on == true and not data.button,
		fmt = data.fmt,
		button = data.button,
		optDefs = data.opts or {},
		optv = {},
		defOn = data.defOn,
		defValue = data.defValue or data.value,
	}
	if row.defOn == nil then
		row.defOn = data.on == true
	end
	-- right-click options: defaults, overridden by saved values that still fit their definition
	for _, d in ipairs(row.optDefs) do
		local v = data.optv and sane(d, data.optv[d.key])
		if v == nil then
			v = d.default
		end
		row.optv[d.key] = v
	end

	local btn = make("TextButton", {
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
	}, parent)
	corner(btn, 10)
	row.btn = btn
	row.stroke = make("UIStroke", {
		Color = C.accent, Thickness = 1, Transparency = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, btn)

	-- accent bar on the left edge while the row is on
	row.bar = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(3, 18),
		BackgroundColor3 = C.accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, btn)
	corner(row.bar, 2)

	make("TextLabel", {
		Text = data.label,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -140, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, btn)

	row.badge = make("TextLabel", {
		Text = shown(row, row.value),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -58, 0.5, 0),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = C.muted,
	}, btn)
	corner(row.badge, 6)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, row.badge)

	row.track = make("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(38, 22),
		BackgroundColor3 = C.line,
		BorderSizePixel = 0,
	}, btn)
	corner(row.track, 11)
	row.knob = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = C.white,
		BorderSizePixel = 0,
	}, row.track)
	corner(row.knob, 8)
	self.A.setSwitch(row, false, C)
	row.badge.Visible = row.slider ~= "Unused" and not row.button
	if row.button then
		row.track.Visible = false
		make("TextLabel", {
			Text = "click to run",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(80, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = C.muted,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, btn)
	end

	-- left click / tap = toggle
	local held, longFired = false, false
	table.insert(self._conns, btn.MouseButton1Click:Connect(function()
		if longFired then
			longFired = false
			return
		end
		if row.button then
			self.A.highlightRow(row, true)
			task.delay(0.25, function()
				self.A.highlightRow(row, false)
			end)
			self.onChanged(row.id, true, row.value, row.optv)
			self:_startCountdown()
			return
		end
		row.on = not row.on
		self.A.setSwitch(row, true, C)
		self.onChanged(row.id, row.on, row.value, row.optv)
		self:refreshStatus()
		self:_startCountdown()
	end))

	-- right click = slider popover
	table.insert(self._conns, btn.MouseButton2Click:Connect(function()
		self:_openPop(row, UserInputService:GetMouseLocation())
	end))

	-- touch long-press = slider popover
	table.insert(self._conns, btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			held, longFired = true, false
			task.delay(CFG.LongPressSeconds, function()
				if held then
					longFired = true
					self:_openPop(row, pointerOf(input))
				end
			end)
		end
	end))
	table.insert(self._conns, btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			held = false
		end
	end))

	table.insert(self.rowList, row)
	table.insert(self.tabRows[tabIndex], row)
	self.rowsById[row.id] = row
	return row
end

---------------------------------------------------------------------
-- live status (status dot, enabled count on each tab)
---------------------------------------------------------------------
function UI:refreshStatus()
	for i, rows in ipairs(self.tabRows) do
		local n = 0
		for _, row in ipairs(rows) do
			if row.on then
				n += 1
			end
		end
		local badge = self.tabBadges[i]
		badge.Text = tostring(n)
		badge.Visible = n > 0
	end
end

function UI:_applyStatus(open)
	self.A.setStatus(self.dot, open, C)
	if open then
		self.A.startPulse(self.ring, self.ringStroke, C.good)
	else
		self.A.stopPulse(self.ring, self.ringStroke)
	end
end

function UI:setProfileName(name)
	self.profileName = name or ""
end

---------------------------------------------------------------------
-- settings popover (right-click / long-press a row)
---------------------------------------------------------------------
local function label(parent, text, size, width)
	return make("TextLabel", {
		Size = UDim2.new(1, -(width or 0), 0, size or 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
	}, parent)
end

-- slider control. get() -> current value, set(v) is called when it changes, fmtf(v) -> text. hue = rainbow track.
function UI:_ctlSlider(order, text, lo, hi, step, get, set, fmtf, hue)
	local s = self.state
	local f = make("Frame", { LayoutOrder = order, Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1 }, self.popScroll)
	label(f, text, 16, 90)
	local val = make("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(86, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = C.accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
	}, f)
	local hit = make("TextButton", {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, f)
	local track = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, 6),
		BackgroundColor3 = hue and C.white or C.line,
		BorderSizePixel = 0,
	}, hit)
	corner(track, 3)
	local fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.accent, BorderSizePixel = 0 }, track)
	corner(fill, 3)
	if hue then
		fill.Visible = false
		make("UIGradient", { Color = HUE_SEQ }, track)
	end
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = C.white,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, track)
	corner(knob, 8)

	local ctl = { track = track, knob = knob, lo = lo, hi = hi, step = step }
	ctl.wheel = math.max(1, math.floor((hi - lo) / step / 25))
	local current = get()
	function ctl.show(v)
		local a = (v - lo) / (hi - lo)
		fill.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.fromScale(a, 0.5)
		val.Text = fmtf(v)
		if hue then
			knob.BackgroundColor3 = Color3.fromHSV(math.clamp(v, 0, 0.999), 0.85, 1)
		end
	end
	function ctl.apply(raw)
		local v = lo + math.floor((raw - lo) / step + 0.5) * step
		v = math.clamp(math.floor(v * 10000 + 0.5) / 10000, lo, hi)
		if v == current then
			return
		end
		current = v
		set(v)
		ctl.show(v)
	end
	function ctl.nudge(dir)
		ctl.apply(current + dir * step * ctl.wheel)
	end
	ctl.show(current)

	hit.InputBegan:Connect(function(input)
		if isPress(input) then
			s.drag = { ctl = ctl, input = input }
			self.A.knobGrow(knob, true)
			self:_dragTo(ctl, input)
		end
	end)
	hit.MouseEnter:Connect(function()
		s.hover = ctl
	end)
	hit.MouseLeave:Connect(function()
		if s.hover == ctl then
			s.hover = nil
		end
	end)
	return ctl
end

function UI:_ctlToggle(order, text, get, set)
	local f = make("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, self.popScroll)
	label(f, text, 26, 44).Size = UDim2.new(1, -44, 1, 0)
	local track = make("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(34, 18),
		BackgroundColor3 = C.line,
		BorderSizePixel = 0,
	}, f)
	corner(track, 9)
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = C.white,
		BorderSizePixel = 0,
	}, track)
	corner(knob, 7)
	local function show(on, animate)
		local kind = animate and "fast" or "instant"
		self.A.tween(knob, kind, { Position = UDim2.new(0, on and 18 or 2, 0.5, 0) })
		self.A.tween(track, kind, { BackgroundColor3 = on and C.accent or C.line })
	end
	show(get(), false)
	f.MouseButton1Click:Connect(function()
		local v = not get()
		set(v)
		show(v, true)
	end)
end

function UI:_ctlChoice(order, text, choices, get, set)
	local f = make("Frame", { LayoutOrder = order, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, self.popScroll)
	label(f, text, 26, 112).Size = UDim2.new(1, -112, 1, 0)
	local btn = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(106, 22),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = C.accent,
		Text = tostring(get()),
	}, f)
	corner(btn, 7)
	btn.MouseButton1Click:Connect(function()
		local idx = 1
		for i, c in ipairs(choices) do
			if c == get() then
				idx = i
			end
		end
		local nextValue = choices[idx % #choices + 1]
		set(nextValue)
		btn.Text = tostring(nextValue)
	end)
end

-- (re)builds the controls for a row, returns the height they need
function UI:_fillPop(row)
	local s = self.state
	s.drag, s.hover = nil, nil
	for _, ch in ipairs(self.popScroll:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	local n, total = 0, 14 -- 14 = the scroll frame's top + bottom padding
	local function slot(height)
		n += 1
		total += height + (n > 1 and 6 or 0)
		return n
	end

	if row.slider ~= "Unused" then
		self:_ctlSlider(slot(38), row.slider, 0, 100, 1, function()
			return row.value
		end, function(v)
			row.value = v
			row.badge.Text = shown(row, v)
			self.onChanged(row.id, row.on, v, row.optv)
		end, function(v)
			return shown(row, v)
		end, false)
	end

	for _, d in ipairs(row.optDefs) do
		local key = d.key
		local function get()
			return row.optv[key]
		end
		local function set(v)
			row.optv[key] = v
			self.onChanged(row.id, row.on, row.value, row.optv)
		end
		if d.type == "slider" or d.type == "hue" then
			local hue = d.type == "hue"
			self:_ctlSlider(slot(38), d.label, d.min or 0, d.max or (hue and 1 or 100), d.step or (hue and 0.01 or 1), get, set, function(v)
				return fmtOpt(d, v)
			end, hue)
		elseif d.type == "toggle" then
			self:_ctlToggle(slot(26), d.label, get, set)
		elseif d.type == "choice" then
			self:_ctlChoice(slot(26), d.label, d.choices, get, set)
		end
	end
	return total
end

-- fills the popover and sizes it (capped to the screen, the controls scroll when they do not fit)
function UI:_sizePop(row)
	local content = self:_fillPop(row)
	local vpY = self.gui.AbsoluteSize.Y
	if vpY <= 0 then
		vpY = 720
	end
	local maxH = vpY - 16
	local h = math.min(POP_HEAD + content, maxH)
	self.pop.Size = UDim2.fromOffset(POP_W, h)
	self.popScroll.ScrollBarThickness = (POP_HEAD + content > maxH) and 3 or 0
	self.popScroll.CanvasPosition = Vector2.zero
end

function UI:_openPop(row, pos)
	local s = self.state
	if row.slider == "Unused" and #row.optDefs == 0 then
		return -- nothing to configure
	end
	if s.activeRow and s.activeRow ~= row then
		self.A.highlightRow(s.activeRow, false)
	end
	s.activeRow = row
	self.A.highlightRow(row, true)
	self.popName.Text = row.label
	self:_sizePop(row)

	local origin, vp = self.gui.AbsolutePosition, self.gui.AbsoluteSize
	local h = self.pop.Size.Y.Offset
	local x = math.clamp(pos.X - origin.X - POP_W / 2, 8, math.max(8, vp.X - POP_W - 8))
	local y = math.clamp(pos.Y - origin.Y + 10, 8, math.max(8, vp.Y - h - 8))
	s.popOpen = true
	self.scrim.Visible = true
	self.A.popOpen(self.pop, x, y)
end

function UI:_closePop(silent)
	local s = self.state
	if not s.popOpen then
		return
	end
	s.popOpen = false
	s.drag, s.hover = nil, nil
	self.scrim.Visible = false
	if s.activeRow then
		self.A.highlightRow(s.activeRow, false)
		s.activeRow = nil
	end
	self.A.popClose(self.pop).Completed:Once(function()
		if not s.popOpen then
			self.pop.Visible = false
		end
	end)
	if not silent and not s.minimized then
		self:_startCountdown()
	end
end

-- moves a slider to where the pointer is (works while the pointer is anywhere on screen)
function UI:_dragTo(ctl, input)
	local x
	if input.UserInputType == Enum.UserInputType.Touch then
		x = input.Position.X
	else
		x = UserInputService:GetMouseLocation().X
	end
	local w = math.max(1, ctl.track.AbsoluteSize.X)
	ctl.apply(ctl.lo + (x - ctl.track.AbsolutePosition.X) / w * (ctl.hi - ctl.lo))
end

-- puts a row back to its default (on / off, slider, every option) and tells the features
function UI:_resetRow(row, animate)
	row.on, row.value = row.defOn, row.defValue
	for _, d in ipairs(row.optDefs) do
		row.optv[d.key] = d.default -- in place: features keep a reference to this table
	end
	row.badge.Text = shown(row, row.value)
	self.A.setSwitch(row, animate, C)
	self.onChanged(row.id, row.on, row.value, row.optv)
end

function UI:resetAll()
	for _, row in ipairs(self.rowList) do
		if not row.button then
			self:_resetRow(row, true)
		end
	end
	self:refreshStatus()
end

---------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------
-- The menu is exactly as tall as the active tab needs: header, tab bar, its rows, hint line. Rows sit in
-- a two column grid per section, so 7 rows take 4 grid lines. When that would run off the screen the panel is capped
-- and its rows scroll instead.
-- returns panelHeight, totalMenuHeight, naturalPanelHeight
function UI:_layoutFor(i)
	local natural = self.tabNatural[i] or 0
	local vpY = self.gui.AbsoluteSize.Y
	if vpY <= 0 then
		local cam = workspace.CurrentCamera
		vpY = cam and cam.ViewportSize.Y or 720
	end
	local maxTotal = (vpY - CFG.TopOffset - CFG.ScreenMargin) / self.scale.Scale
	local panelH = natural
	if natural + CHROME > maxTotal then
		panelH = math.max(CELL_H, maxTotal - CHROME)
	end
	return panelH, panelH + CHROME, natural
end

-- sizes tab i's panel, returns the total menu height that goes with it
function UI:_sizePanel(i)
	local panelH, total, natural = self:_layoutFor(i)
	self.panels[i].Size = UDim2.fromOffset(PANEL_W, panelH)
	self.scrolls[i].ScrollBarThickness = natural > panelH and 3 or 0
	return total
end

-- re-fits the menu to the active tab (after build, scale change or a viewport resize)
function UI:_applyHeight(animate)
	local s = self.state
	local total = self:_sizePanel(s.tab)
	self.expanded = Vector2.new(CFG.Width, total)
	if s.minimized then
		self.body.Size = UDim2.fromOffset(CFG.Width, total) -- hidden, root keeps the pill size
		return
	end
	self.A.resize(self.refs, self.expanded, animate)
end

function UI:_selectTab(i)
	local s = self.state
	if i == s.tab or s.minimized then
		return
	end
	self:_closePop(true)
	local prev = s.tab
	local dir = i > prev and 1 or -1 -- moving right brings the new panel in from the right
	s.tab = i
	for idx, btn in ipairs(self.tabButtons) do
		self.A.styleTab(btn, idx == i, C, self.surfaceT)
		if idx ~= i and idx ~= prev then
			self.panels[idx].Visible = false -- leftover from a rapid double switch
		end
	end

	self.scrolls[i].CanvasPosition = Vector2.zero
	self.expanded = Vector2.new(CFG.Width, self:_sizePanel(i))

	local oldPanel = self.panels[prev]
	self.A.slideOut(oldPanel, PANEL_POS, -dir * CFG.SlideDistance).Completed:Once(function()
		if s.tab ~= prev then
			oldPanel.Visible = false
		end
	end)
	self.A.slideIn(self.panels[i], PANEL_POS, dir * CFG.SlideDistance)
	self.A.resize(self.refs, self.expanded, true)
	self:_startCountdown()
end

---------------------------------------------------------------------
-- minimize / expand / countdown
---------------------------------------------------------------------
function UI:_startCountdown()
	local s = self.state
	s.mode = "run"
	s.deadline = os.clock() + s.hideSeconds
end

function UI:minimize()
	local s = self.state
	if s.minimized then
		return
	end
	s.minimized = true
	s.mode = "idle"
	s.token += 1
	local token = s.token
	self:_closePop(true)
	s.shown = 1
	self.barFill.Size = UDim2.fromScale(1, 1)
	self:_applyStatus(false)

	local t = self.A.collapse(self.refs, CFG.Pill, LEAD_MIN)
	t.Completed:Once(function()
		if s.token == token and s.minimized then
			self.body.Visible = false
		end
	end)
end

function UI:expand()
	local s = self.state
	if not s.minimized then
		return
	end
	s.minimized = false
	s.token += 1
	self.body.Visible = true
	self:_applyStatus(true)
	self.A.expand(self.refs, self.expanded, LEAD_EXP)
	self:_startCountdown()
end

function UI:toggle()
	if self.state.minimized then
		self:expand()
	else
		self:minimize()
	end
end

-- called by Functionality (scale / auto-hide features)
-- alpha 1 = solid menu, lower = see-through (the menu surfaces only, text and switches stay solid)
function UI:setOpacity(alpha)
	local t = 1 - math.clamp(alpha, 0.2, 1)
	self.surfaceT = t
	self.root.BackgroundTransparency = t
	for _, row in ipairs(self.rowList) do
		row.btn.BackgroundTransparency = t
	end
	local active = self.tabButtons[self.state.tab]
	if active then
		active.BackgroundTransparency = t
	end
end

function UI:setScale(scale)
	self.scale.Scale = scale
	if self.built then
		self:_applyHeight(true) -- the screen cap depends on the scale
	end
end

function UI:setAutoHide(enabled, seconds)
	local s = self.state
	s.autoHide = enabled
	if seconds then
		s.hideSeconds = seconds
	end
	if not s.minimized then
		self:_startCountdown()
	end
end

---------------------------------------------------------------------
-- input + frame loop
---------------------------------------------------------------------
function UI:_bindInput()
	local s = self.state
	local conns = self._conns

	table.insert(conns, self.header.MouseButton1Click:Connect(function()
		self:toggle()
	end))

	-- screen resized / rotated: re-check whether the active tab still fits
	table.insert(conns, self.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if self.built then
			self:_applyHeight(true)
		end
	end))

	-- any press on the scrim (everything outside the popover) closes it
	table.insert(conns, self.scrim.InputBegan:Connect(function(input)
		if isPress(input) or input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_closePop(false)
		end
	end))

	-- dragging a slider keeps following the pointer even when it leaves the popover; the wheel over a slider nudges it
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if s.drag and (input.UserInputType == Enum.UserInputType.MouseMovement or input == s.drag.input) then
			self:_dragTo(s.drag.ctl, s.drag.input)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and s.hover then
			s.hover.nudge(input.Position.Z > 0 and 1 or -1)
		end
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if isPress(input) and s.drag then
			self.A.knobGrow(s.drag.ctl.knob, false)
			s.drag = nil
		end
	end))

	table.insert(conns, self.popReset.MouseButton1Click:Connect(function()
		local row = s.activeRow
		if row then
			self:_resetRow(row, true)
			self:refreshStatus()
			self:_sizePop(row)
		end
	end))

	table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == CFG.ToggleKey and not processed then
			self:toggle()
		end
	end))
end

function UI:_step(dt)
	local s = self.state
	if s.minimized then
		return
	end

	local hovered = false
	if UserInputService.MouseEnabled then
		local mp = UserInputService:GetMouseLocation()
		hovered = isOver(self.root, mp)
	end

	if not s.autoHide or s.popOpen or hovered then
		s.mode = "hold"
	elseif s.mode ~= "run" then
		self:_startCountdown()
	end

	local prefix = self.profileName ~= "" and (self.profileName .. "  |  ") or ""
	local target
	if s.mode == "run" then
		local remaining = math.max(0, s.deadline - os.clock())
		target = remaining / s.hideSeconds
		self.sub.Text = ("%shides in %ds"):format(prefix, math.ceil(remaining))
		if remaining <= 0 then
			self:minimize()
			return
		end
	else
		target = 1
		self.sub.Text = prefix .. (s.autoHide and "paused" or "pinned")
	end

	s.shown = self.A.stepBar(s.shown, target, dt)
	self.barFill.Size = UDim2.fromScale(s.shown, 1)
	-- bar drifts from accent to red as the menu is about to hide
	local warnAmount = math.clamp((0.35 - s.shown) / 0.35, 0, 1)
	self.barFill.BackgroundColor3 = C.accent:Lerp(C.bad, warnAmount)
end

function UI:start()
	self:refreshStatus()
	self:_applyStatus(true)
	self:_startCountdown()
	table.insert(self._conns, RunService.RenderStepped:Connect(function(dt)
		self:_step(dt)
	end))
end

function UI:destroy()
	self.A.stopPulse(self.ring, self.ringStroke)
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	self.gui:Destroy()
end

return UI
