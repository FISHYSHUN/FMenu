-- ModuleScript: QuickMenu
-- Hold a key (default Tab) and a small panel with the current game's cheats pops up. Release the key and it goes away.
--   click a row            toggle it
--   drag the thin bar      change the row's main slider (same value the big menu uses)
--   right-click a row      open that row's full settings popover (the one from the main menu)
--   hold + settings open   the panel stays up until the popover is closed
--
-- Which rows: the game's own tab when the place is recognised (e.g. Flee), then Speed / Fly / Noclip underneath.
-- In unrecognised games it shows a small universal set. Both lists are editable below.
-- It reads and writes the same row objects as the main menu, so the two always agree and saving still works.
-- Needs a keyboard (hold-key). While the panel is open the mouse is freed and Roblox's player list is hidden,
-- so Tab does not open both. A tap shorter than HOLD_DELAY is left alone, the player list still works.
--
--   QuickMenu.new({ ui = ui, animations = Animations, profile = profile }) -> object with :destroy()

local import = ...
local Util = import("Util")
local UI = import("UI")

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local C = UI.THEME
local make = Util.make

local QuickMenu = {}
QuickMenu.__index = QuickMenu

QuickMenu.KEY = Enum.KeyCode.Tab
QuickMenu.HOLD_DELAY = 0.15 -- seconds the key must be held before the panel opens
QuickMenu.FALLBACK = { "speed", "jump", "fly", "noclip", "infjump", "esp", "fullbright" } -- unrecognised games
QuickMenu.EXTRA = { "speed", "fly", "noclip" } -- universal rows shown under a game's own rows

local PANEL_W, HEAD_H = 270, 46
local ROW_H, ROW_SLIDER_H, GAP = 32, 48, 6
local STEP = "FMenuQuickMenu"

local function corner(obj, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r) }, obj)
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- ordered list of { id } and { header } entries
local function collect(profile)
	local list, seen = {}, {}
	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			list[#list + 1] = { id = id }
		end
	end
	local gameTab = profile and profile.name ~= "Universal" and profile.tabs and profile.tabs[#profile.tabs - 1] or nil
	if gameTab then
		for _, data in ipairs(gameTab.rows) do
			add(data.id)
		end
		local before = #list
		for _, id in ipairs(QuickMenu.EXTRA) do
			add(id)
		end
		if #list > before then
			table.insert(list, before + 1, { header = "Universal" })
		end
	else
		for _, id in ipairs(QuickMenu.FALLBACK) do
			add(id)
		end
	end
	return list
end

function QuickMenu.new(deps)
	local self = setmetatable({}, QuickMenu)
	self.ui = deps.ui
	self.A = deps.animations
	self.profile = deps.profile
	self.key = deps.key or QuickMenu.KEY
	self.visible = false
	self.held, self.heldAt = false, 0
	self.drag = nil
	self.entries = {}
	self.content = 0
	self._conns = {}
	self:_build()
	self:_bind()
	return self
end

---------------------------------------------------------------------
-- gui
---------------------------------------------------------------------
function QuickMenu:_build()
	local gui = make("ScreenGui", {
		Name = "MenuWidgetQuick",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1200, -- above the menu (1100) so the panel is never covered
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	Util.mount(gui)
	self.gui = gui

	-- a Modal button frees the mouse in first person / shift lock while the panel is open
	self.modal = make("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Modal = true,
		Visible = false,
		ZIndex = 1,
	}, gui)

	local panel = make("CanvasGroup", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PANEL_W, 200),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = 2,
	}, gui)
	corner(panel, 14)
	make("UIStroke", { Color = C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, panel)
	self.panel = panel

	local profileName = self.profile and self.profile.name or ""
	make("TextLabel", {
		Position = UDim2.fromOffset(14, 7),
		Size = UDim2.new(1, -28, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = profileName ~= "" and (profileName .. "  |  quick menu") or "quick menu",
	}, panel)
	make("TextLabel", {
		Position = UDim2.fromOffset(14, 25),
		Size = UDim2.new(1, -28, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = C.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "click = toggle  |  drag bar = value  |  right-click = settings",
	}, panel)

	self.scroll = make("ScrollingFrame", {
		Position = UDim2.fromOffset(0, HEAD_H),
		Size = UDim2.new(1, 0, 1, -HEAD_H),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		ScrollBarImageColor3 = C.line,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, GAP), SortOrder = Enum.SortOrder.LayoutOrder }, self.scroll)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 10),
	}, self.scroll)

	local order, total, count = 0, 12, 0
	for _, item in ipairs(collect(self.profile)) do
		if item.header then
			order += 1
			count += 1
			total += 14 + (count > 1 and GAP or 0)
			make("TextLabel", {
				LayoutOrder = order,
				Size = UDim2.new(1, 0, 0, 14),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 10,
				TextColor3 = C.muted,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = item.header:upper(),
			}, self.scroll)
		else
			local row = self.ui.rowsById[item.id]
			if row then
				order += 1
				count += 1
				local h = self:_addRow(row, order)
				total += h + (count > 1 and GAP or 0)
			end
		end
	end
	self.content = total
end

-- one row: toggle, optional value slider. Returns the row height.
function QuickMenu:_addRow(row, order)
	local hasSlider = row.slider ~= "Unused" and not row.button
	local h = hasSlider and ROW_SLIDER_H or ROW_H
	local btn = make("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, h),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
	}, self.scroll)
	corner(btn, 8)

	local e = { row = row, hasSlider = hasSlider }
	e.bar = make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0, ROW_H / 2),
		Size = UDim2.fromOffset(3, 16),
		BackgroundColor3 = C.accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, btn)
	corner(e.bar, 2)
	e.name = make("TextLabel", {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -110, 0, ROW_H),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = row.label,
	}, btn)

	if row.button then
		make("TextLabel", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0, ROW_H / 2),
			Size = UDim2.fromOffset(60, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextColor3 = C.muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "click to run",
		}, btn)
	else
		e.track = make("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0, ROW_H / 2),
			Size = UDim2.fromOffset(32, 18),
			BackgroundColor3 = C.line,
			BorderSizePixel = 0,
		}, btn)
		corner(e.track, 9)
		e.knob = make("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 3, 0.5, 0),
			Size = UDim2.fromOffset(12, 12),
			BackgroundColor3 = C.white,
			BorderSizePixel = 0,
		}, e.track)
		corner(e.knob, 6)
	end

	if hasSlider then
		e.badge = make("TextLabel", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -50, 0, ROW_H / 2),
			Size = UDim2.fromOffset(0, 14),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = C.muted,
			Text = "",
		}, btn)
		-- the hit area is taller than the thin bar so it is easy to grab
		local hit = make("TextButton", {
			Position = UDim2.fromOffset(10, ROW_H - 4),
			Size = UDim2.new(1, -20, 0, 16),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
		}, btn)
		local line = make("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(1, 0, 0, 4),
			BackgroundColor3 = C.line,
			BorderSizePixel = 0,
		}, hit)
		corner(line, 2)
		e.fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.accent, BorderSizePixel = 0 }, line)
		corner(e.fill, 2)
		e.sknob = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(10, 10),
			BackgroundColor3 = C.white,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, line)
		corner(e.sknob, 5)
		e.hit = hit
		table.insert(self._conns, hit.InputBegan:Connect(function(input)
			if isPress(input) then
				self.drag = { entry = e, input = input }
				self:_dragTo(self.drag)
			end
		end))
	end

	table.insert(self._conns, btn.MouseButton1Click:Connect(function()
		self.ui:_activate(row, true)
	end))
	table.insert(self._conns, btn.MouseButton2Click:Connect(function()
		local mouse = UserInputService:GetMouseLocation()
		local panel = self.panel
		local right = panel.AbsolutePosition.X + panel.AbsoluteSize.X
		-- opens beside the panel so the popover never sits underneath it
		self.ui:_openPop(row, Vector2.new(right + 150, mouse.Y))
	end))

	self.entries[#self.entries + 1] = e
	return h
end

-- moves the dragged slider to the pointer
function QuickMenu:_dragTo(drag)
	local e = drag.entry
	local row = e.row
	local w = math.max(1, e.hit.AbsoluteSize.X)
	local x = Util.pointer(drag.input).X
	local v = math.clamp(math.floor((x - e.hit.AbsolutePosition.X) / w * 100 + 0.5), 0, 100)
	if v ~= row.value then
		row.value = v
		if row.badge then
			row.badge.Text = row.fmt and row.fmt(v) or tostring(v) -- keeps the big menu's badge in step
		end
		self.ui.onChanged(row.id, row.on, v, row.optv)
	end
end

-- copies the rows' real state onto the panel (the big menu or a keybind may have changed it)
function QuickMenu:_sync()
	for _, e in ipairs(self.entries) do
		local row = e.row
		e.bar.BackgroundTransparency = (not row.button and row.on) and 0 or 1
		e.name.TextColor3 = (row.on or row.button) and C.text or C.muted
		if e.track then
			e.track.BackgroundColor3 = row.on and C.accent or C.line
			e.knob.Position = UDim2.new(0, row.on and 17 or 3, 0.5, 0)
		end
		if e.hasSlider then
			local f = math.clamp(row.value / 100, 0, 1)
			e.fill.Size = UDim2.fromScale(f, 1)
			e.sknob.Position = UDim2.fromScale(f, 0.5)
			e.badge.Text = row.fmt and row.fmt(row.value) or tostring(row.value)
		end
	end
end

---------------------------------------------------------------------
-- show / hide
---------------------------------------------------------------------
function QuickMenu:show()
	if self.visible then
		return
	end
	self.visible = true
	self:_sync()

	local vpY = self.gui.AbsoluteSize.Y
	if vpY <= 0 then
		vpY = 720
	end
	local maxH = vpY - 80
	local h = math.min(HEAD_H + self.content, maxH)
	self.panel.Size = UDim2.fromOffset(PANEL_W, h)
	self.scroll.ScrollBarThickness = (HEAD_H + self.content > maxH) and 3 or 0
	self.scroll.CanvasPosition = Vector2.zero

	self.modal.Visible = true
	self.panel.Position = UDim2.new(0.5, 0, 0.5, 8)
	self.panel.GroupTransparency = 1
	self.panel.Visible = true
	self.A.tween(self.panel, "fast", { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) })

	-- Roblox's player list also opens on Tab: hide it while the panel is up
	local ok, was = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList)
	self._listWas = ok and was or false
	if self._listWas then
		pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false)
	end
	self._icon = UserInputService.MouseIconEnabled
	pcall(function()
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Last.Value + 1, function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default -- the camera script re-locks it every frame
			UserInputService.MouseIconEnabled = true
		end)
	end)
end

function QuickMenu:hide()
	if not self.visible then
		return
	end
	self.visible = false
	self.drag = nil
	self.modal.Visible = false
	pcall(RunService.UnbindFromRenderStep, RunService, STEP)
	if self._icon ~= nil then
		UserInputService.MouseIconEnabled = self._icon
	end
	if self._listWas then
		self._listWas = false
		pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, true)
	end
	local t = self.A.tween(self.panel, "fast", { GroupTransparency = 1 })
	t.Completed:Once(function()
		if not self.visible then
			self.panel.Visible = false
		end
	end)
end

---------------------------------------------------------------------
-- input + state loop
---------------------------------------------------------------------
function QuickMenu:_bind()
	local conns = self._conns

	table.insert(conns, UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode ~= self.key or self.held then
			return
		end
		if UserInputService:GetFocusedTextBox() or self.ui.state.binding then
			return
		end
		self.held, self.heldAt = true, os.clock()
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == self.key then
			self.held = false
		end
		if self.drag and isPress(input) then
			self.drag = nil
		end
	end))

	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		local d = self.drag
		if d and (input.UserInputType == Enum.UserInputType.MouseMovement or input == d.input) then
			self:_dragTo(d)
		end
	end))

	table.insert(conns, RunService.Heartbeat:Connect(function()
		local popOpen = self.ui.state.popOpen
		if not self.visible then
			if self.held and os.clock() - self.heldAt >= QuickMenu.HOLD_DELAY then
				self:show()
			end
			return
		end
		-- the settings popover needs the mouse, so the modal button steps aside while it is open
		self.modal.Visible = not popOpen
		self:_sync()
		if not self.held and not popOpen and not self.drag then
			self:hide()
		end
	end))
end

function QuickMenu:destroy()
	self:hide()
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.gui:Destroy()
end

return QuickMenu
