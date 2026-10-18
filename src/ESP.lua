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
	local curColor, curFill = color, fill or 0.75
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
				OutlineTransparency = 0,
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
		if f then
			curFill = f
		end
		if hl then
			hl.FillColor = c
			hl.OutlineColor = c
			hl.FillTransparency = curFill
		end
		label.TextColor3 = c
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
	local frame = Util.make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, bb)
	local stroke = Util.make("UIStroke", { Color = color, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
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
		stroke.Color = c
		label.TextColor3 = c
		label.Text = t or ""
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
		self.entries[plr] = nil
		pcall(e.marker.destroy)
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
				e.marker.setHighlight(i <= ESP.HIGHLIGHT_CAP)
			end
		end)
		if not ok then
			self:_drop(c.plr) -- rebuilt from scratch next tick
		end
	end
end

return ESP
