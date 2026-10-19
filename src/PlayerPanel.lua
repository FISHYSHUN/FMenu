-- ModuleScript: PlayerPanel
-- Type /isee in chat and a panel with every player in the server opens (type it again to close it).
--   TP      teleport to that player
--   Watch   camera follows them (click again to go back to yourself)
--   Orbit   circle around them (one target at a time)
--   Mark    yellow chams + name tag + distance, any number of players
--
-- Everything is client side, same as the Troll tab: it moves your own character / camera and draws markers.
-- Nothing is sent to anyone.
--
-- How the command is caught:
--   * new chat (TextChatService): a TextChatCommand named "/isee" is created. Commands run locally and the text
--     is NOT sent to the server, nobody sees it.
--   * old chat: only Player.Chatted exists there, which fires after the message is sent, so the line "/isee"
--     is visible in chat. Use the new chat or the key below if that matters.
-- PlayerPanel.KEY = Enum.KeyCode.<something> also opens it with a key (nil = chat command only).
--
--   PlayerPanel.new({ animations = Animations, notify = Functionality.notify }) -> object with :toggle() :destroy()

local import = ...
local Util = import("Util")
local UI = import("UI")
local ESP = import("ESP")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")

local C = UI.THEME
local lp = Players.LocalPlayer
local make = Util.make

local PlayerPanel = {}
PlayerPanel.__index = PlayerPanel

PlayerPanel.COMMAND = "/isee"
PlayerPanel.KEY = nil -- e.g. Enum.KeyCode.RightBracket
PlayerPanel.ORBIT_RADIUS, PlayerPanel.ORBIT_SPEED, PlayerPanel.ORBIT_HEIGHT = 10, 2, 2

local PANEL_W, HEAD_H, ROW_H, GAP = 360, 78, 40, 6
local YELLOW = Color3.fromRGB(255, 214, 64)
local STEP = "FMenuPlayerPanel"

local function corner(obj, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r) }, obj)
end

local function usable(plr)
	return plr ~= nil and plr.Parent ~= nil and Util.isAlive(plr.Character) and Util.rootOf(plr.Character) ~= nil
end

function PlayerPanel.new(deps)
	local self = setmetatable({}, PlayerPanel)
	self.A = deps.animations
	self.notify = deps.notify or function() end
	self.visible = false
	self.rows = {} -- player -> { frame, tp, watch, orbit, mark }
	self.watch, self.orbit, self.angle = nil, nil, 0
	self.marked = {}
	self._conns = {}
	self._syncAcc = 0

	self.esp = ESP.new({
		maxDistance = 5000,
		resolve = function(plr, char, dist, style)
			if self.marked[plr] then
				return YELLOW, ESP.text(plr, char, dist, "[MARK]", style)
			end
			return nil
		end,
	})

	self:_build()
	self:_bind()
	self:_hookChat()
	return self
end

---------------------------------------------------------------------
-- gui
---------------------------------------------------------------------
function PlayerPanel:_build()
	local gui = make("ScreenGui", {
		Name = "MenuWidgetPlayers",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1250, -- above the menu and the quick menu
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	Util.mount(gui)
	self.gui = gui

	-- a Modal button frees the mouse in first person while the panel is open
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
		Size = UDim2.fromOffset(PANEL_W, 380),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = 2,
	}, gui)
	corner(panel, 14)
	make("UIStroke", { Color = C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, panel)
	self.panel = panel

	make("TextLabel", {
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(160, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "players",
	}, panel)
	self.count = make("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -44, 0, 9),
		Size = UDim2.fromOffset(120, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = C.muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
	}, panel)
	local close = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(24, 22),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = C.muted,
		Text = "X",
	}, panel)
	corner(close, 7)
	table.insert(self._conns, close.MouseButton1Click:Connect(function()
		self:hide()
	end))

	self.search = make("TextBox", {
		Position = UDim2.fromOffset(12, 36),
		Size = UDim2.new(1, -24, 0, 26),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = C.text,
		PlaceholderText = "search name",
		PlaceholderColor3 = C.muted,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, panel)
	corner(self.search, 8)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, self.search)
	table.insert(self._conns, self.search:GetPropertyChangedSignal("Text"):Connect(function()
		self:_rebuild()
	end))

	self.scroll = make("ScrollingFrame", {
		Position = UDim2.fromOffset(0, HEAD_H),
		Size = UDim2.new(1, 0, 1, -HEAD_H),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
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
end

local function smallButton(parent, index, text)
	local b = make("TextButton", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(1, -182 + (index - 1) * 44, 0.5, 0),
		Size = UDim2.fromOffset(40, 24),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = C.muted,
		Text = text,
	}, parent)
	corner(b, 7)
	return b
end

function PlayerPanel:_addRow(plr, order)
	local frame = make("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, ROW_H),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
	}, self.scroll)
	corner(frame, 8)
	make("TextLabel", {
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -196, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = plr.DisplayName,
	}, frame)
	make("TextLabel", {
		Position = UDim2.fromOffset(10, 21),
		Size = UDim2.new(1, -196, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = C.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "@" .. plr.Name,
	}, frame)

	local e = { frame = frame }
	e.tp = smallButton(frame, 1, "TP")
	e.watch = smallButton(frame, 2, "Watch")
	e.orbit = smallButton(frame, 3, "Orbit")
	e.mark = smallButton(frame, 4, "Mark")
	table.insert(self._conns, e.tp.MouseButton1Click:Connect(function()
		self:_goto(plr)
	end))
	table.insert(self._conns, e.watch.MouseButton1Click:Connect(function()
		self:_toggleWatch(plr)
	end))
	table.insert(self._conns, e.orbit.MouseButton1Click:Connect(function()
		self:_toggleOrbit(plr)
	end))
	table.insert(self._conns, e.mark.MouseButton1Click:Connect(function()
		self:_toggleMark(plr)
	end))
	self.rows[plr] = e
end

-- (re)builds the list from the current players and the search text
function PlayerPanel:_rebuild()
	for _, e in pairs(self.rows) do
		e.frame:Destroy()
	end
	table.clear(self.rows)
	local query = self.search.Text:lower()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp and (query == "" or plr.Name:lower():find(query, 1, true) or plr.DisplayName:lower():find(query, 1, true)) then
			list[#list + 1] = plr
		end
	end
	table.sort(list, function(a, b)
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)
	for i, plr in ipairs(list) do
		self:_addRow(plr, i)
	end
	self.count.Text = ("%d players"):format(math.max(0, #Players:GetPlayers() - 1))
	self:_sync()
end

-- highlights the buttons that are active
function PlayerPanel:_sync()
	for plr, e in pairs(self.rows) do
		local function style(btn, on)
			btn.BackgroundColor3 = on and C.accent or C.panel
			btn.TextColor3 = on and C.white or C.muted
		end
		style(e.watch, self.watch == plr)
		style(e.orbit, self.orbit == plr)
		style(e.mark, self.marked[plr] == true)
	end
end

---------------------------------------------------------------------
-- actions
---------------------------------------------------------------------
function PlayerPanel:_goto(plr)
	local root, troot = Util.root(), usable(plr) and Util.rootOf(plr.Character)
	if not (root and troot) then
		self.notify(plr.DisplayName .. " is not available", Color3.fromRGB(255, 214, 64))
		return
	end
	root.CFrame = troot.CFrame * CFrame.new(0, 0, 4)
	root.AssemblyLinearVelocity = Vector3.zero
end

function PlayerPanel:_restoreCamera()
	local cam, hum = workspace.CurrentCamera, Util.humanoid()
	if cam and hum then
		cam.CameraSubject = hum
	end
end

function PlayerPanel:_toggleWatch(plr)
	if self.watch == plr then
		self.watch = nil
		self:_restoreCamera()
	else
		self.watch = plr
	end
	self:_sync()
end

function PlayerPanel:_toggleOrbit(plr)
	self.orbit = (self.orbit ~= plr) and plr or nil
	self:_sync()
end

function PlayerPanel:_toggleMark(plr)
	self.marked[plr] = (not self.marked[plr]) or nil
	self.esp:setEnabled(next(self.marked) ~= nil)
	self:_sync()
end

-- runs every frame: keeps watch / orbit / marks going, drops targets that left or died
function PlayerPanel:_step(dt)
	if self.watch then
		if usable(self.watch) then
			local cam, hum = workspace.CurrentCamera, Util.humanoid(self.watch.Character)
			if cam and hum and cam.CameraSubject ~= hum then
				cam.CameraSubject = hum
			end
		else
			self.watch = nil
			self:_restoreCamera()
			self:_sync()
		end
	end

	if self.orbit then
		if usable(self.orbit) then
			local root, troot = Util.root(), Util.rootOf(self.orbit.Character)
			if root and troot then
				self.angle += PlayerPanel.ORBIT_SPEED * dt
				local pos = troot.Position + Vector3.new(
					math.cos(self.angle) * PlayerPanel.ORBIT_RADIUS,
					PlayerPanel.ORBIT_HEIGHT,
					math.sin(self.angle) * PlayerPanel.ORBIT_RADIUS
				)
				root.CFrame = CFrame.lookAt(pos, Vector3.new(troot.Position.X, pos.Y, troot.Position.Z))
				root.AssemblyLinearVelocity = Vector3.zero
			end
		else
			self.orbit = nil
			self:_sync()
		end
	end

	for plr in pairs(self.marked) do
		if plr.Parent == nil then
			self.marked[plr] = nil
		end
	end
	self.esp:step(dt)
end

---------------------------------------------------------------------
-- show / hide / input
---------------------------------------------------------------------
function PlayerPanel:show()
	if self.visible then
		return
	end
	self.visible = true
	self:_rebuild()

	local vpY = self.gui.AbsoluteSize.Y
	if vpY <= 0 then
		vpY = 720
	end
	self.panel.Size = UDim2.fromOffset(PANEL_W, math.min(420, vpY - 80))

	self.modal.Visible = true
	self.panel.Position = UDim2.new(0.5, 0, 0.5, 8)
	self.panel.GroupTransparency = 1
	self.panel.Visible = true
	self.A.tween(self.panel, "fast", { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) })

	self._icon = UserInputService.MouseIconEnabled
	pcall(function()
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Last.Value + 1, function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default -- the camera script re-locks it every frame
			UserInputService.MouseIconEnabled = true
		end)
	end)
end

function PlayerPanel:hide()
	if not self.visible then
		return
	end
	self.visible = false
	self.modal.Visible = false
	pcall(RunService.UnbindFromRenderStep, RunService, STEP)
	if self._icon ~= nil then
		UserInputService.MouseIconEnabled = self._icon
	end
	self.search:ReleaseFocus()
	local t = self.A.tween(self.panel, "fast", { GroupTransparency = 1 })
	t.Completed:Once(function()
		if not self.visible then
			self.panel.Visible = false
		end
	end)
end

function PlayerPanel:toggle()
	if self.visible then
		self:hide()
	else
		self:show()
	end
end

function PlayerPanel:_hookChat()
	local hooked = false
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		local ok, cmd = pcall(function()
			local c = Instance.new("TextChatCommand")
			c.Name = "FMenuPlayers"
			c.PrimaryAlias = PlayerPanel.COMMAND
			c.Parent = TextChatService
			return c
		end)
		if ok and cmd then
			self.cmd = cmd
			table.insert(self._conns, cmd.Triggered:Connect(function()
				self:toggle()
			end))
			hooked = true
		end
	end
	if not hooked then
		-- old chat (or the command could not be created): Player.Chatted, the line stays visible in chat
		table.insert(self._conns, lp.Chatted:Connect(function(msg)
			if msg:lower():match("^%s*" .. PlayerPanel.COMMAND:gsub("%p", "%%%0") .. "%s*$") then
				self:toggle()
			end
		end))
	end
end

function PlayerPanel:_bind()
	table.insert(self._conns, Players.PlayerAdded:Connect(function()
		if self.visible then
			self:_rebuild()
		end
	end))
	table.insert(self._conns, Players.PlayerRemoving:Connect(function(plr)
		if self.watch == plr then
			self.watch = nil
			self:_restoreCamera()
		end
		if self.orbit == plr then
			self.orbit = nil
		end
		self.marked[plr] = nil
		if self.visible then
			task.defer(function()
				self:_rebuild()
			end)
		end
	end))
	table.insert(self._conns, RunService.Heartbeat:Connect(function(dt)
		self:_step(dt)
	end))
	if PlayerPanel.KEY then
		table.insert(self._conns, UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == PlayerPanel.KEY then
				self:toggle()
			end
		end))
	end
end

function PlayerPanel:destroy()
	self:hide()
	if self.watch then
		self:_restoreCamera()
	end
	self.watch, self.orbit = nil, nil
	table.clear(self.marked)
	self.esp:setEnabled(false)
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self.cmd then
		pcall(self.cmd.Destroy, self.cmd)
	end
	self.gui:Destroy()
end

return PlayerPanel
