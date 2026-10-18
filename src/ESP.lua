-- ModuleScript: ESP
-- Highlight + billboard name tags, and 3D boxes.
--   ESP.marker(adornee, color, text, fill)  highlight + name tag for any part/model -> handle
--   ESP.box(adornee, color, text)           box that scales with distance + name under it -> handle
--       handle.update(color, text, fill) / handle.isAlive() / handle.destroy()
--       handle.setHighlight(bool) (marker only)
--   ESP.new({ resolve = fn, make = ESP.marker | ESP.box, maxDistance = n, fill = n })  player ESP
--       resolve(plr, char, dist) -> Color3 | nil (nil = hide), text
--       esp:setEnabled(bool), esp:setDistance(n), esp:step(dt) (call every frame)
--
-- Built to survive: one bad player never stops the others, markers are rebuilt whenever anything about
-- them died (respawn, camera swap, character replaced), and Highlights are budgeted because Roblox only
-- renders ~31 at once, past that they silently vanish. Players over the budget keep their name tag.

local import = ...
local Util = import("Util")

local Players = game:GetService("Players")

local ESP = {}
ESP.__index = ESP

ESP.HIGHLIGHT_CAP = 28 -- shared by every ESP instance

-- Look of every ESP (universal + game ones). Functionality's "Style" rows write into this table and the
-- markers re-read it on every update, so changes show up within a tick.
ESP.style = {
	highlight = true, -- chams fill / outline on or off
	fill = 0.8, -- highlight fill transparency
	outline = 0, -- highlight outline transparency (1 = no outline)
	showName = true,
	showDist = true,
	showHealth = true,
	showTool = false,
	textSize = 13,
	healthBar = true, -- boxes only
	boxFill = 0, -- 0 = hollow box, up to 1 = solid
	boxThick = 1.5,
	hpColor = false, -- colour by health
	rainbow = false,
	rainbowSpeed = 0.2,
	custom = false, -- fixed colour from `hue`
	hue = 0, -- 0..1
	wallCheck = false, -- green when you can see them, red behind walls
	tracerFrom = "bottom", -- bottom | center | top (read by tracers)
	rate = 10, -- updates per second
}

local function healthRatio(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	return math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
end

-- label text built from the Style toggles. `extra` is a game specific bit (e.g. "[SHERIFF]")
function ESP.text(plr, char, dist, extra)
	local s = ESP.style
	local parts = {}
	if s.showName then
		parts[#parts + 1] = plr.DisplayName
	end
	if extra and extra ~= "" then
		parts[#parts + 1] = extra
	end
	if s.showDist then
		parts[#parts + 1] = ("%dm"):format(math.floor(dist))
	end
	if s.showHealth then
		local r = healthRatio(char)
		local hum = char:FindFirstChildOfClass("Humanoid")
		if r and hum then
			parts[#parts + 1] = ("%dhp"):format(math.floor(hum.Health))
		end
	end
	if s.showTool then
		local tool = char:FindFirstChildOfClass("Tool")
		if tool then
			parts[#parts + 1] = tool.Name
		end
	end
	return table.concat(parts, "  ")
end

-- colour from the Style toggles. Priority: wall check > custom > rainbow > health > team > fallback
function ESP.color(plr, char, fallback)
	local s = ESP.style
	if s.wallCheck then
		local cam = workspace.CurrentCamera
		local part = char:FindFirstChild("Head") or Util.rootOf(char)
		if cam and part then
			return Util.visible(cam.CFrame.Position, part) and Color3.fromRGB(90, 220, 130) or Color3.fromRGB(255, 90, 90)
		end
	end
	if s.custom then
		return Color3.fromHSV(s.hue, 0.85, 1)
	end
	if s.rainbow then
		return Color3.fromHSV((os.clock() * s.rainbowSpeed) % 1, 0.85, 1)
	end
	if s.hpColor then
		local r = healthRatio(char)
		if r then
			return Color3.fromHSV(r * 0.33, 0.9, 1)
		end
	end
	return (plr.Team and plr.TeamColor.Color) or fallback
end
local highlightsUsed = 0

local holder
local function getHolder()
	if holder and holder.Parent and holder:IsDescendantOf(workspace) then
		return holder
	end
	if holder then
		pcall(holder.Destroy, holder)
	end
	holder = Instance.new("Folder")
	holder.Name = "FMenuESP"
	holder.Parent = workspace.CurrentCamera or workspace
	return holder
end

local function tagPartOf(adornee)
	if adornee:IsA("Model") then
		return adornee:FindFirstChild("Head") or adornee.PrimaryPart or adornee:FindFirstChildWhichIsA("BasePart")
	end
	return adornee
end

function ESP.marker(adornee, color, text, fill)
	local parent = getHolder()
	local curColor, curFill = color, fill or ESP.style.fill
	local hl

	local bb = Util.make("BillboardGui", {
		Adornee = tagPartOf(adornee),
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
	local dead = false

	function handle.setHighlight(on)
		if dead then
			return
		end
		if on and not hl and highlightsUsed < ESP.HIGHLIGHT_CAP then
			highlightsUsed += 1
			hl = Util.make("Highlight", {
				Adornee = adornee,
				FillColor = curColor,
				OutlineColor = curColor,
				FillTransparency = curFill,
				OutlineTransparency = ESP.style.outline,
				DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			}, parent)
		elseif not on and hl then
			hl:Destroy()
			hl = nil
			highlightsUsed -= 1
		end
	end

	function handle.update(c, t, f)
		curColor = c
		curFill = f or ESP.style.fill
		if hl then
			hl.FillColor = c
			hl.OutlineColor = c
			hl.FillTransparency = curFill
			hl.OutlineTransparency = ESP.style.outline
		end
		label.TextColor3 = c
		label.TextSize = ESP.style.textSize
		label.Text = t or ""
	end

	function handle.isAlive()
		return not dead
			and bb.Parent ~= nil
			and adornee.Parent ~= nil
			and adornee:IsDescendantOf(workspace)
			and (hl == nil or hl.Parent ~= nil)
	end

	function handle.destroy()
		if dead then
			return
		end
		handle.setHighlight(false)
		dead = true
		bb:Destroy()
	end

	handle.setHighlight(true)
	return handle
end

-- box that grows / shrinks with distance (BillboardGui scale is in studs) with the text under it
function ESP.box(adornee, color, text)
	local parent = getHolder()
	local root = adornee
	if adornee:IsA("Model") then
		root = adornee:FindFirstChild("HumanoidRootPart") or adornee.PrimaryPart or adornee:FindFirstChildWhichIsA("BasePart")
	end
	local bb = Util.make("BillboardGui", {
		Adornee = root,
		Size = UDim2.fromScale(4.2, 6.2),
		AlwaysOnTop = true,
		LightInfluence = 0,
	}, parent)
	local frame = Util.make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, BackgroundTransparency = 1, BorderSizePixel = 0 }, bb)
	local stroke = Util.make("UIStroke", { Color = color, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
	-- health bar on the left edge of the box (pixel sized, so it stays readable at any distance)
	local barBack = Util.make("Frame", {
		Position = UDim2.new(0, -6, 0, 0),
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = Color3.fromRGB(20, 20, 24),
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Visible = false,
	}, frame)
	local barFill = Util.make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
	}, barBack)
	local label = Util.make("TextLabel", {
		Position = UDim2.new(0, 0, 1, 2),
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = color,
		TextStrokeTransparency = 0.4,
		Text = text or "",
	}, frame)

	local handle = {}
	local dead = false
	function handle.update(c, t)
		local s = ESP.style
		stroke.Color = c
		stroke.Thickness = s.boxThick
		frame.BackgroundColor3 = c
		frame.BackgroundTransparency = s.boxFill > 0 and (1 - s.boxFill * 0.6) or 1
		label.TextColor3 = c
		label.TextSize = s.textSize - 1
		label.Text = t or ""
		local ratio = s.healthBar and healthRatio(adornee)
		barBack.Visible = ratio ~= nil and ratio ~= false
		if ratio then
			barFill.Size = UDim2.fromScale(1, ratio)
			barFill.BackgroundColor3 = Color3.fromHSV(ratio * 0.33, 0.9, 1)
		end
	end
	function handle.isAlive()
		return not dead and bb.Parent ~= nil and adornee.Parent ~= nil and adornee:IsDescendantOf(workspace)
	end
	function handle.destroy()
		if not dead then
			dead = true
			bb:Destroy()
		end
	end
	return handle
end

function ESP.new(opts)
	local self = setmetatable({}, ESP)
	self.resolve = opts.resolve
	self.make = opts.make or ESP.marker
	self.maxDistance = opts.maxDistance or 1000
	self.fill = opts.fill -- optional per-instance override of ESP.style.fill
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
		self.entries[plr] = nil
		pcall(e.marker.destroy)
	end
end

function ESP:step(dt)
	if not self.enabled then
		return
	end
	self._acc += dt
	if self._acc < 1 / math.max(ESP.style.rate, 1) then
		return
	end
	self._acc = 0
	local ok, err = pcall(self._update, self)
	if not ok then
		warn("[FMenu] ESP update failed, retrying: " .. tostring(err))
	end
end

function ESP:_update()
	local lp = Players.LocalPlayer
	local myRoot = Util.root()

	for plr in pairs(self.entries) do
		if plr.Parent == nil then
			self:_drop(plr)
		end
	end

	-- who should be marked this tick, nearest first (nearest get the Highlights)
	local cands = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			local char = plr.Character
			local color, text, dist
			if char and char.Parent and Util.isAlive(char) then
				local root = Util.rootOf(char)
				if root then
					dist = myRoot and (root.Position - myRoot.Position).Magnitude or 0
					if dist <= self.maxDistance then
						local ok, c, t = pcall(self.resolve, plr, char, dist)
						if ok then
							color, text = c, t
						end
					end
				end
			end
			if color then
				cands[#cands + 1] = { plr = plr, char = char, color = color, text = text, dist = dist }
			else
				self:_drop(plr)
			end
		end
	end
	table.sort(cands, function(a, b)
		return a.dist < b.dist
	end)

	for i, c in ipairs(cands) do
		local ok = pcall(function()
			local e = self.entries[c.plr]
			if e and (e.char ~= c.char or not e.marker.isAlive()) then
				self:_drop(c.plr)
				e = nil
			end
			if not e then
				e = { char = c.char, marker = self.make(c.char, c.color, c.text, self.fill) }
				self.entries[c.plr] = e
			end
			e.marker.update(c.color, c.text, self.fill)
			if e.marker.setHighlight then
				e.marker.setHighlight(ESP.style.highlight and i <= ESP.HIGHLIGHT_CAP)
			end
		end)
		if not ok then
			self:_drop(c.plr) -- rebuilt from scratch next tick
		end
	end
end

return ESP
