-- ModuleScript: ESP
-- Highlight + billboard name tags.
--   ESP.marker(adornee, color, text, fill)  one marker for any part/model -> handle
--       handle.update(color, text, fill) / handle.isAlive() / handle.destroy()
--   ESP.new({ resolve = fn, maxDistance = n, fill = n })  player ESP
--       resolve(plr, char, dist) -> Color3 | nil (nil = hide), text
--       esp:setEnabled(bool), esp:setDistance(n), esp:step(dt) (call every frame)

local import = ...
local Util = import("Util")

local Players = game:GetService("Players")

local ESP = {}
ESP.__index = ESP

local holder
local function getHolder()
	if not holder or not holder:IsDescendantOf(workspace) then
		holder = Util.make("Folder", { Name = "FMenuESP" }, workspace.CurrentCamera)
	end
	return holder
end

function ESP.marker(adornee, color, text, fill)
	local parent = getHolder()
	local tagPart = adornee
	if adornee:IsA("Model") then
		tagPart = adornee:FindFirstChild("Head") or adornee.PrimaryPart or adornee:FindFirstChildWhichIsA("BasePart")
	end

	local hl = Util.make("Highlight", {
		Adornee = adornee,
		FillColor = color,
		OutlineColor = color,
		FillTransparency = fill or 0.75,
		OutlineTransparency = 0,
		DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
	}, parent)
	local bb = Util.make("BillboardGui", {
		Adornee = tagPart,
		Size = UDim2.fromOffset(220, 30),
		StudsOffset = Vector3.new(0, 2.6, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
	}, parent)
	local label = Util.make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = color,
		TextStrokeTransparency = 0.4,
		Text = text or "",
	}, bb)

	local handle = {}
	function handle.update(c, t, f)
		hl.FillColor = c
		hl.OutlineColor = c
		if f then
			hl.FillTransparency = f
		end
		label.TextColor3 = c
		label.Text = t or ""
	end
	function handle.isAlive()
		return hl.Parent ~= nil and hl.Adornee ~= nil
	end
	function handle.destroy()
		hl:Destroy()
		bb:Destroy()
	end
	return handle
end

function ESP.new(opts)
	local self = setmetatable({}, ESP)
	self.resolve = opts.resolve
	self.maxDistance = opts.maxDistance or 1000
	self.fill = opts.fill or 0.8
	self.entries = {}
	self.enabled = false
	self._acc = 0
	return self
end

function ESP:setEnabled(on)
	self.enabled = on
	if not on then
		for plr in pairs(self.entries) do
			self:_drop(plr)
		end
	end
end

function ESP:setDistance(d)
	self.maxDistance = d
end

function ESP:_drop(plr)
	local e = self.entries[plr]
	if e then
		e.marker.destroy()
		self.entries[plr] = nil
	end
end

function ESP:step(dt)
	if not self.enabled then
		return
	end
	self._acc += dt
	if self._acc < 0.1 then
		return
	end
	self._acc = 0
	self:_update()
end

function ESP:_update()
	local lp = Players.LocalPlayer
	local myRoot = Util.root()

	for plr in pairs(self.entries) do
		if plr.Parent == nil then
			self:_drop(plr)
		end
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			local char = plr.Character
			local root = Util.root(char)
			local color, text
			if root and Util.alive(char) then
				local dist = myRoot and (root.Position - myRoot.Position).Magnitude or 0
				if dist <= self.maxDistance then
					color, text = self.resolve(plr, char, dist)
				end
			end

			local e = self.entries[plr]
			if color then
				if e and (e.char ~= char or not e.marker.isAlive()) then
					self:_drop(plr)
					e = nil
				end
				if not e then
					e = { char = char, marker = ESP.marker(char, color, text, self.fill) }
					self.entries[plr] = e
				end
				e.marker.update(color, text, self.fill)
			elseif e then
				self:_drop(plr)
			end
		end
	end
end

return ESP
