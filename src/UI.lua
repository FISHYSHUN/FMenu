-- ModuleScript: UI
-- Builds the gui, owns input (clicks, right-click / long-press slider popover) and the
-- minimize/expand + countdown state. All motion is delegated to Animations.
-- It knows nothing about what the toggles actually do: it just calls ui.onChanged(id, enabled, value).
--
-- Slider popover notes (why it no longer closes by itself):
--   * a full-screen "scrim" button sits under the popover while it is open. Pressing it closes the
--     popover. The popover sits above the scrim, so presses on the slider can never reach it.
--     No hit-testing math, so mouse / touch / inset differences cannot close it by accident.
--   * dragging reads the real pointer X every move event and keeps going even if the pointer
--     leaves the popover.
--   * -/+ buttons (hold to repeat) for fine control.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local UI = {}
UI.__index = UI

UI.CONFIG = {
	HideSeconds = 4,
	ToggleKey = Enum.KeyCode.Insert,
	TopOffset = 12,
	Expanded = Vector2.new(560, 246),
	Pill = Vector2.new(176, 38),
	LongPressSeconds = 0.5,
	MaxRowsPerTab = 6,
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
local LEAD_W = 112
local LEAD_EXP = UDim2.new(0, 14, 0, 0)
local LEAD_MIN = UDim2.new(0.5, -LEAD_W / 2, 0, 0)
local PANEL_POS = UDim2.fromOffset(14, 86)
local PANEL_SIZE = UDim2.fromOffset(532, 130)
local POP_W, POP_H = 260, 76

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
		dragging = false,
		dragInput = nil,
		stepToken = 0,
		token = 0,
		autoHide = true,
		hideSeconds = CFG.HideSeconds,
	}
	self.rowList, self.rowsById = {}, {}
	self.tabButtons, self.panels, self.tabRows, self.tabDots = {}, {}, {}, {}
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
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))
	self.gui = gui

	-- CanvasGroup so the rounded corners actually clip the contents
	local root = make("CanvasGroup", {
		Name = "Root",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, CFG.TopOffset),
		Size = UDim2.fromOffset(CFG.Expanded.X, CFG.Expanded.Y),
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
		Size = UDim2.fromOffset(CFG.Expanded.X, CFG.Expanded.Y),
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
	-- how many features are on, visible even when minimized
	self.count = make("TextLabel", {
		Text = "0 on",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 68, 0.5, 0),
		Size = UDim2.fromOffset(42, 16),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = C.muted,
	}, self.lead)
	corner(self.count, 8)

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
		Size = UDim2.fromOffset(532, 32),
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

	make("TextLabel", {
		Text = "click = toggle  |  right-click (or long-press) = slider  |  Insert = hide",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 224),
		Size = UDim2.fromOffset(CFG.Expanded.X, 14),
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

	-- slider popover lives on the ScreenGui so nothing clips it
	local pop = make("CanvasGroup", {
		Name = "SliderPopover",
		Size = UDim2.fromOffset(POP_W, POP_H),
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
		Size = UDim2.fromOffset(150, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, pop)
	self.popVal = make("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(80, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = C.accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "0",
	}, pop)

	self.popMinus = make("TextButton", {
		Text = "-",
		Position = UDim2.fromOffset(10, 38),
		Size = UDim2.fromOffset(24, 26),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = C.text,
	}, pop)
	corner(self.popMinus, 7)
	self.popPlus = make("TextButton", {
		Text = "+",
		Position = UDim2.fromOffset(POP_W - 34, 38),
		Size = UDim2.fromOffset(24, 26),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = C.text,
	}, pop)
	corner(self.popPlus, 7)

	self.popHit = make("TextButton", {
		Position = UDim2.fromOffset(46, 36),
		Size = UDim2.fromOffset(POP_W - 92, 30),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, pop)
	self.popTrack = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, 6),
		BackgroundColor3 = C.line,
		BorderSizePixel = 0,
	}, self.popHit)
	corner(self.popTrack, 3)
	self.popFill = make("Frame", {
		Size = UDim2.fromScale(0.5, 1),
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
	}, self.popTrack)
	corner(self.popFill, 3)
	self.popKnob = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = C.white,
		BorderSizePixel = 0,
	}, self.popTrack)
	corner(self.popKnob, 10)

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
			BackgroundTransparency = i == 1 and 0 or 1,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = i == 1 and C.text or C.muted,
		}, self.tabBar)
		corner(tbtn, 7)
		self.tabButtons[i] = tbtn
		-- small green dot on a tab when something inside it is on
		local dot = make("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -5, 0, 5),
			Size = UDim2.fromOffset(5, 5),
			BackgroundColor3 = C.good,
			BorderSizePixel = 0,
			Visible = false,
		}, tbtn)
		corner(dot, 3)
		self.tabDots[i] = dot
		self.tabRows[i] = {}
		table.insert(self._conns, tbtn.MouseButton1Click:Connect(function()
			self:_selectTab(i)
		end))

		local panel = make("CanvasGroup", {
			Name = "Panel_" .. tab.name,
			Position = PANEL_POS,
			Size = PANEL_SIZE,
			BackgroundTransparency = 1,
			Visible = i == 1,
		}, self.body)
		make("UIGridLayout", {
			CellSize = UDim2.new(0.5, -4, 0, 38),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, panel)
		self.panels[i] = panel

		if #tab.rows > CFG.MaxRowsPerTab then
			warn(("[FMenu] tab '%s' has %d rows, only %d fit"):format(tab.name, #tab.rows, CFG.MaxRowsPerTab))
		end
		for r, data in ipairs(tab.rows) do
			if r <= CFG.MaxRowsPerTab then
				self:_buildRow(data, r, panel, i)
			end
		end
	end
	self:refreshStatus()
end

function UI:rows()
	return self.rowList
end

function UI:_buildRow(data, order, parent, tabIndex)
	local row = {
		id = data.id,
		slider = data.slider or data.label,
		value = data.value,
		on = data.on,
		fmt = data.fmt,
	}

	local btn = make("TextButton", {
		LayoutOrder = order,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
	}, parent)
	corner(btn, 10)
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

	-- left click / tap = toggle
	local held, longFired = false, false
	table.insert(self._conns, btn.MouseButton1Click:Connect(function()
		if longFired then
			longFired = false
			return
		end
		row.on = not row.on
		self.A.setSwitch(row, true, C)
		self.onChanged(row.id, row.on, row.value)
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
-- live status (dot, counts, tab dots)
---------------------------------------------------------------------
function UI:refreshStatus()
	local total = 0
	for i, rows in ipairs(self.tabRows) do
		local n = 0
		for _, row in ipairs(rows) do
			if row.on then
				n += 1
			end
		end
		total += n
		self.tabDots[i].Visible = n > 0
	end
	self.count.Text = ("%d on"):format(total)
	self.count.TextColor3 = total > 0 and C.good or C.muted
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
-- slider popover
---------------------------------------------------------------------
function UI:_setSliderVisual(row, v)
	self.popFill.Size = UDim2.fromScale(v / 100, 1)
	self.popKnob.Position = UDim2.fromScale(v / 100, 0.5)
	self.popVal.Text = shown(row, v)
end

function UI:_openPop(row, pos)
	local s = self.state
	if s.activeRow and s.activeRow ~= row then
		self.A.highlightRow(s.activeRow, false)
	end
	s.activeRow = row
	self.A.highlightRow(row, true)
	self.popName.Text = row.slider
	self:_setSliderVisual(row, row.value)

	local vp = self.gui.AbsoluteSize
	local x = math.clamp(pos.X - POP_W / 2, 8, math.max(8, vp.X - POP_W - 8))
	local y = math.clamp(pos.Y + 10, 8, math.max(8, vp.Y - POP_H - 8))
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
	s.dragging = false
	s.dragInput = nil
	s.stepToken += 1
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

function UI:_setValue(v)
	local row = self.state.activeRow
	if not row then
		return
	end
	v = math.clamp(math.floor(v + 0.5), 0, 100)
	if v == row.value then
		return
	end
	row.value = v
	row.badge.Text = shown(row, v)
	self:_setSliderVisual(row, v)
	self.onChanged(row.id, row.on, v)
end

function UI:_sliderFromInput(input)
	local x
	if input.UserInputType == Enum.UserInputType.Touch then
		x = input.Position.X
	else
		x = UserInputService:GetMouseLocation().X
	end
	local track = self.popTrack
	local w = math.max(1, track.AbsoluteSize.X)
	self:_setValue((x - track.AbsolutePosition.X) / w * 100)
end

function UI:_nudge(delta)
	local row = self.state.activeRow
	if row then
		self:_setValue(row.value + delta)
	end
end

---------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------
function UI:_selectTab(i)
	local s = self.state
	if i == s.tab then
		return
	end
	self:_closePop(true)
	s.tab = i
	for idx, btn in ipairs(self.tabButtons) do
		self.A.styleTab(btn, idx == i, C)
		if idx ~= i then
			self.panels[idx].Visible = false
		end
	end
	self.A.showPanel(self.panels[i], PANEL_POS)
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
	self.A.expand(self.refs, CFG.Expanded, LEAD_EXP)
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
function UI:setScale(scale)
	self.scale.Scale = scale
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

	-- any press on the scrim (everything outside the popover) closes it
	table.insert(conns, self.scrim.InputBegan:Connect(function(input)
		if isPress(input) or input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_closePop(false)
		end
	end))

	-- slider track: press jumps to the pointer, then drag follows it anywhere on screen
	table.insert(conns, self.popHit.InputBegan:Connect(function(input)
		if isPress(input) then
			s.dragging = true
			s.dragInput = input
			self.A.knobGrow(self.popKnob, true)
			self:_sliderFromInput(input)
		end
	end))

	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not s.dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input == s.dragInput then
			self:_sliderFromInput(s.dragInput or input)
		end
	end))

	-- -/+ buttons, hold to repeat
	local function bindStep(btn, delta)
		table.insert(conns, btn.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			s.stepToken += 1
			local token = s.stepToken
			self:_nudge(delta)
			task.spawn(function()
				task.wait(CFG.RepeatDelay)
				while s.stepToken == token and s.popOpen do
					self:_nudge(delta)
					task.wait(CFG.RepeatRate)
				end
			end)
		end))
	end
	bindStep(self.popMinus, -1)
	bindStep(self.popPlus, 1)

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			if s.dragging then
				s.dragging = false
				s.dragInput = nil
				self.A.knobGrow(self.popKnob, false)
			end
			s.stepToken += 1
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
