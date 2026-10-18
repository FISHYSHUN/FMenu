-- ModuleScript: ESP
-- Highlight + billboard name tags, and 3D boxes.
--   ESP.marker(adornee, color, text, fill, style)  highlight + name tag for any part/model -> handle
--   ESP.box(adornee, color, text, fill, style)     box that scales with distance + name under it -> handle
--       handle.update(color, text, fill) / handle.isAlive() / handle.destroy()
--       handle.setHighlight(bool) (marker only)
--   ESP.new({ resolve = fn, make = ESP.marker | ESP.box, maxDistance = n, fill = n, style = {..} })  player ESP
--       resolve(plr, char, dist, style) -> Color3 | nil (nil = hide), text
--       esp:setEnabled(bool), esp:setDistance(n), esp:configure(opts), esp:step(dt) (call every frame)
--
-- STYLE IS PER ESP NOW. Every ESP instance owns its own style table, filled from the feature's right-click
-- menu (esp:configure(opts)). ESP.options(kind) returns the option list a row hands to the menu, and the option
-- keys are exactly the style keys below, so a row's `opts` table can be passed straight to configure.
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

local DEFAULT_STYLE = {
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
	colorMode = "Default", -- Default | Custom | Rainbow | Health | Wall check
	hue = 0, -- 0..1, used by Custom
	rainbowSpeed = 0.2,
	hideTeam = false,
	tracerFrom = "Bottom", -- Bottom | Center | Top (tracers)
	alpha = 1, -- tracer opacity
	rate = 10, -- updates per second
}

-- read-only defaults, used by markers made without a style (e.g. the MM2 gun drop marker)
ESP.style = DEFAULT_STYLE

function ESP.newStyle(overrides)
	local s = table.clone(DEFAULT_STYLE)
	if overrides then
		for k, v in pairs(overrides) do
			s[k] = v
		end
	end
	return s
end

function ESP.applyStyle(style, opts)
	for k, v in pairs(opts) do
		style[k] = v
	end
end

---------------------------------------------------------------------
-- option lists for the right-click menu
---------------------------------------------------------------------
local function chamsOpts()
	return {
		{ type = "toggle", key = "highlight", label = "Chams", default = true },
		{ type = "slider", key = "fill", label = "Fill transparency", min = 0, max = 1, step = 0.05, pct = true, default = 0.8 },
		{ type = "slider", key = "outline", label = "Outline transparency", min = 0, max = 1, step = 0.05, pct = true, default = 0 },
	}
end

local function labelOpts()
	return {
		{ type = "toggle", key = "showName", label = "Name", default = true },
		{ type = "toggle", key = "showDist", label = "Distance", default = true },
		{ type = "toggle", key = "showHealth", label = "Health text", default = true },
		{ type = "toggle", key = "showTool", label = "Held tool", default = false },
		{ type = "slider", key = "textSize", label = "Text size", min = 10, max = 20, step = 1, unit = "px", default = 13 },
	}
end

local function colorOpts()
	return {
		{ type = "choice", key = "colorMode", label = "Color", choices = { "Default", "Custom", "Rainbow", "Health", "Wall check" }, default = "Default" },
		{ type = "hue", key = "hue", label = "Custom hue", default = 0 },
		{ type = "slider", key = "rainbowSpeed", label = "Rainbow speed", min = 0.05, max = 1, step = 0.05, default = 0.2 },
	}
end

local function rateOpt()
	return { type = "slider", key = "rate", label = "Update rate", min = 4, max = 30, step = 1, unit = "/s", default = 10 }
end

local function append(dst, src)
	for _, o in ipairs(src) do
		dst[#dst + 1] = o
	end
	return dst
end

-- kind: "player" (chams + labels + colors), "box", "tracer", "role" (chams + labels, colour fixed by the game), "chams"
function ESP.options(kind)
	local list = {}
	if kind == "player" then
		append(list, chamsOpts())
		append(list, labelOpts())
		append(list, colorOpts())
		list[#list + 1] = { type = "toggle", key = "hideTeam", label = "Hide teammates", default = false }
		list[#list + 1] = rateOpt()
	elseif kind == "box" then
		list[#list + 1] = { type = "slider", key = "boxFill", label = "Box fill", min = 0, max = 1, step = 0.05, pct = true, default = 0 }
		list[#list + 1] = { type = "slider", key = "boxThick", label = "Box thickness", min = 1, max = 4, step = 0.5, unit = "px", default = 1.5 }
		list[#list + 1] = { type = "toggle", key = "healthBar", label = "Health bar", default = true }
		append(list, labelOpts())
		append(list, colorOpts())
		list[#list + 1] = { type = "toggle", key = "hideTeam", label = "Hide teammates", default = false }
		list[#list + 1] = rateOpt()
	elseif kind == "tracer" then
		list[#list + 1] = { type = "choice", key = "tracerFrom", label = "Origin", choices = { "Bottom", "Center", "Top" }, default = "Bottom" }
		list[#list + 1] = { type = "slider", key = "alpha", label = "Opacity", min = 0.1, max = 1, step = 0.05, pct = true, default = 1 }
		append(list, colorOpts())
		list[#list + 1] = { type = "toggle", key = "hideTeam", label = "Hide teammates", default = false }
	elseif kind == "role" then
		append(list, chamsOpts())
		append(list, labelOpts())
		list[#list + 1] = rateOpt()
	elseif kind == "chams" then
		append(list, chamsOpts())
		list[#list + 1] = rateOpt()
	end
	return list
end

---------------------------------------------------------------------
-- text + colour
---------------------------------------------------------------------
local function healthRatio(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	return math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
end

-- label text built from the style toggles. `extra` is a game specific bit (e.g. "[SHERIFF]")
function ESP.text(plr, char, dist, extra, style)
	local s = style or DEFAULT_STYLE
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
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
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

-- colour from the style's colour mode. Default = team colour (unless ignoreTeam) else `fallback`
function ESP.color(plr, char, fallback, style, ignoreTeam)
	local s = style or DEFAULT_STYLE
	local mode = s.colorMode
	if mode == "Wall check" then
		local cam = workspace.CurrentCamera
		local part = char:FindFirstChild("Head") or Util.rootOf(char)
		if cam and part then
			return Util.visible(cam.CFrame.Position, part) and Color3.fromRGB(90, 220, 130) or Color3.fromRGB(255, 90, 90)
		end
	elseif mode == "Custom" then
		return Color3.fromHSV(s.hue, 0.85, 1)
	elseif mode == "Rainbow" then
		return Color3.fromHSV((os.clock() * s.rainbowSpeed) % 1, 0.85, 1)
	elseif mode == "Health" then
		local r = healthRatio(char)
		if r then
			return Color3.fromHSV(r * 0.33, 0.9, 1)
		end
	end
	if not ignoreTeam and plr.Team then
		return plr.TeamColor.Color
	end
	return fallback
end

---------------------------------------------------------------------
-- markers + boxes
---------------------------------------------------------------------
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

function ESP.marker(adornee, color, text, fill, style)
	style = style or DEFAULT_STYLE
	local parent = getHolder()
	local curColor, curFill = color, fill or style.fill
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
		TextSize = style.textSize,
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
				OutlineTransparency = style.outline,
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
		curFill = f or style.fill
		if hl then
			hl.FillColor = c
			hl.OutlineColor = c
			hl.FillTransparency = curFill
			hl.OutlineTransparency = style.outline
		end
		label.TextColor3 = c
		label.TextSize = style.textSize
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

	handle.setHighlight(style.highlight)
	return handle
end

-- box that grows / shrinks with distance (BillboardGui scale is in studs) with the text under it
function ESP.box(adornee, color, text, _fill, style)
	style = style or DEFAULT_STYLE
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
		stroke.Color = c
		stroke.Thickness = style.boxThick
		frame.BackgroundColor3 = c
		frame.BackgroundTransparency = style.boxFill > 0 and (1 - style.boxFill * 0.6) or 1
		label.TextColor3 = c
		label.TextSize = style.textSize - 1
		label.Text = t or ""
		local ratio = style.healthBar and healthRatio(adornee)
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

---------------------------------------------------------------------
-- player ESP
---------------------------------------------------------------------
function ESP.new(opts)
	local self = setmetatable({}, ESP)
	self.resolve = opts.resolve
	self.make = opts.make or ESP.marker
	self.maxDistance = opts.maxDistance or 1000
	self.fill = opts.fill -- optional per-instance override of style.fill
	self.style = ESP.newStyle(opts.style)
	self.entries = {}
	self.enabled = false
	self._acc = 0
	return self
end

-- takes the option table of a row (keys = style keys) and applies it
function ESP:configure(opts)
	ESP.applyStyle(self.style, opts)
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
	if self._acc < 1 / math.max(self.style.rate, 1) then
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
	local style = self.style

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
						local ok, c, t = pcall(self.resolve, plr, char, dist, style)
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
				e = { char = c.char, marker = self.make(c.char, c.color, c.text, self.fill, style) }
				self.entries[c.plr] = e
			end
			e.marker.update(c.color, c.text, self.fill)
			if e.marker.setHighlight then
				e.marker.setHighlight(style.highlight and i <= ESP.HIGHLIGHT_CAP)
			end
		end)
		if not ok then
			self:_drop(c.plr) -- rebuilt from scratch next tick
		end
	end
end

return ESP
