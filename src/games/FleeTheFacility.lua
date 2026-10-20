-- ModuleScript: games/FleeTheFacility
-- Flee the Facility (place 893973440) and 10 Player Flee (place 17600423422).
--   Role ESP        beast in red, survivors in green (option), chams + labels from the usual ESP options
--   Beast alert     toast when the beast comes within the slider distance
--   Computer icons  a small monitor icon above every computer, screen goes solid green once it is hacked
--   Pod icons       a capsule icon above every freeze pod
--   Exit icons      a door icon above every exit
-- The map icons are drawn from plain frames inside a BillboardGui (no highlights, no text boxes), so they stay
-- the same pixel size at any distance and show through walls. Only the optional distance line is text.
--
-- Names below are from memory of the live game, adjust the FILL spots if something does not show:
--   beast flag      Player.TempPlayerStatsModule.IsBeast (BoolValue), fallback: character holds "Hammer"
--   computers       Models named "ComputerTable", state read from the color of their "Screen" part
--   pods            "FreezePod"       exits  "ExitDoor"
-- Dump what the map really uses with:
--   for _,d in ipairs(workspace:GetDescendants()) do if d:IsA("Model") then print(d.Name) end end

local import = ...
local Util = import("Util")
local ESP = import("ESP")

local Players = game:GetService("Players")

local lp = Players.LocalPlayer
local lerp, range = Util.lerp, Util.range

local RED = Color3.fromRGB(255, 84, 96)
local GREEN = Color3.fromRGB(90, 220, 130)
local YELLOW = Color3.fromRGB(255, 214, 64)
local CYAN = Color3.fromRGB(80, 200, 255)
local DARK = Color3.fromRGB(26, 28, 36)

local Flee = { name = "FleeTheFacility", features = {} }
local features = Flee.features

-- options shared by every icon row
local function iconOpts(extra)
	local list = {
		{ type = "slider", key = "iconSize", label = "Icon size", min = 16, max = 48, step = 2, unit = "px", default = 28 },
		{ type = "toggle", key = "showDist", label = "Distance", default = true },
		{ type = "slider", key = "rate", label = "Update rate", min = 2, max = 30, step = 1, unit = "/s", default = 10 },
	}
	for _, o in ipairs(extra or {}) do
		table.insert(list, 1, o)
	end
	return list
end

Flee.tab = { name = "Flee", rows = {
	{ header = "Players" },
	{ id = "fleeRole", label = "Role ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 2000, " st"),
		opts = (function()
			local o = ESP.options("role")
			table.insert(o, 1, { type = "toggle", key = "survivors", label = "Show survivors", default = true })
			return o
		end)() },
	{ id = "fleeAlert", label = "Beast alert", slider = "Warn distance", value = 40, on = false, fmt = range(20, 150, " st"), opts = {
		{ type = "slider", key = "cooldown", label = "Alert cooldown", min = 2, max = 30, step = 1, unit = "s", default = 8 },
	} },
	{ header = "Map icons" },
	{ id = "fleeComp", label = "Computer icons", slider = "Max distance", value = 100, on = false, fmt = range(100, 3000, " st"),
		opts = iconOpts({ { type = "toggle", key = "hideDone", label = "Hide hacked computers", default = true } }) },
	{ id = "fleePod", label = "Pod icons", slider = "Max distance", value = 100, on = false, fmt = range(100, 3000, " st"), opts = iconOpts() },
	{ id = "fleeExit", label = "Exit icons", slider = "Max distance", value = 100, on = false, fmt = range(100, 3000, " st"), opts = iconOpts() },
} }

---------------------------------------------------------------------
-- beast detection
---------------------------------------------------------------------
local function isBeast(plr)
	local stats = plr:FindFirstChild("TempPlayerStatsModule")
	local flag = stats and stats:FindFirstChild("IsBeast")
	if flag and flag:IsA("BoolValue") then
		return flag.Value
	end
	local char = plr.Character
	return char ~= nil and (char:FindFirstChild("Hammer") ~= nil or char:FindFirstChild("BeastPowers") ~= nil) -- FILL: tool name if the fallback misses
end

local function currentBeast()
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp and Util.isAlive(plr.Character) and isBeast(plr) then
			return plr
		end
	end
	return nil
end

---------------------------------------------------------------------
-- role ESP
---------------------------------------------------------------------
do
	local esp
	features.fleeRole = {
		init = function()
			esp = ESP.new({
				maxDistance = 1000,
				resolve = function(plr, char, dist, style)
					if isBeast(plr) then
						return RED, ESP.text(plr, char, dist, "[BEAST]", style)
					end
					if style.survivors == false then
						return nil
					end
					return GREEN, ESP.text(plr, char, dist, nil, style)
				end,
			})
		end,
		set = function(on, v, _c, o)
			esp:configure(o)
			esp:setDistance(lerp(100, 2000, v))
			esp:setEnabled(on)
		end,
		step = function(dt)
			esp:step(dt)
		end,
		destroy = function()
			if esp then
				esp:setEnabled(false)
			end
		end,
	}
end

---------------------------------------------------------------------
-- beast alert
---------------------------------------------------------------------
do
	local on, thr, acc, last, cfg = false, 60, 0, 0, {}
	features.fleeAlert = {
		set = function(enabled, v, _c, o)
			on, thr, cfg = enabled, lerp(20, 150, v), o
		end,
		step = function(dt, ctx)
			if not on then
				return
			end
			acc += dt
			if acc < 0.25 then
				return
			end
			acc = 0
			local root = Util.root()
			local beast = currentBeast()
			local broot = beast and Util.rootOf(beast.Character)
			if not (root and broot) then
				return
			end
			local d = (broot.Position - root.Position).Magnitude
			local now = os.clock()
			if d <= thr and now - last >= (cfg.cooldown or 8) then
				last = now
				ctx.notify(("beast %dm away"):format(math.floor(d)), RED)
			end
		end,
	}
end

---------------------------------------------------------------------
-- drawn icons (24 x 24 design grid, scaled to the icon size option)
---------------------------------------------------------------------
local function rect(parent, x, y, w, h, color, radius, transparency)
	local f = Util.make("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = color,
		BackgroundTransparency = transparency or 0,
		BorderSizePixel = 0,
	}, parent)
	if radius then
		Util.make("UICorner", { CornerRadius = UDim.new(0, radius) }, f)
	end
	return f
end

local function outline(frame, color, thickness)
	return Util.make("UIStroke", { Color = color, Thickness = thickness, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
end

-- each builder draws into `parent` and returns update(color, state)
local ICONS = {}

function ICONS.computer(parent)
	local body = rect(parent, 1, 2, 22, 15, DARK, 3)
	local stroke = outline(body, CYAN, 2)
	local screen = rect(parent, 4, 5, 16, 9, CYAN, 1, 0.35)
	rect(parent, 10, 17, 4, 3, DARK)
	rect(parent, 6, 20, 12, 2, DARK, 1)
	return function(color, state)
		stroke.Color = color
		screen.BackgroundColor3 = color
		screen.BackgroundTransparency = state == "done" and 0 or 0.35
	end
end

function ICONS.pod(parent)
	local capsule = rect(parent, 6, 0, 12, 24, DARK, 6)
	local stroke = outline(capsule, YELLOW, 2)
	local glow = rect(parent, 9, 4, 6, 16, YELLOW, 3, 0.45)
	return function(color)
		stroke.Color = color
		glow.BackgroundColor3 = color
	end
end

function ICONS.exit(parent)
	local door = rect(parent, 4, 1, 16, 22, DARK, 2)
	local stroke = outline(door, GREEN, 2)
	local panel = rect(parent, 8, 5, 8, 14, GREEN, 1, 0.55)
	local knob = rect(parent, 14, 12, 3, 3, GREEN, 2)
	return function(color)
		stroke.Color = color
		panel.BackgroundColor3 = color
		knob.BackgroundColor3 = color
	end
end

---------------------------------------------------------------------
-- icon ESP for map objects
---------------------------------------------------------------------
local holder
local function getHolder()
	if holder and holder.Parent and holder:IsDescendantOf(workspace) then
		return holder
	end
	if holder then
		pcall(holder.Destroy, holder)
	end
	holder = Instance.new("Folder")
	holder.Name = "FMenuIcons"
	holder.Parent = workspace.CurrentCamera or workspace
	return holder
end

local function anchorPart(inst)
	if inst:IsA("BasePart") then
		return inst
	end
	return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
end

-- icon + distance line above one object
local function makeIcon(inst, builder)
	local part = anchorPart(inst)
	if not part then
		return nil
	end
	-- lift the icon just above the top of the object
	local top
	if inst:IsA("Model") then
		local cf, size = inst:GetBoundingBox()
		top = cf.Position.Y + size.Y / 2
	else
		top = inst.Position.Y + inst.Size.Y / 2
	end
	local lift = math.max(2, top - part.Position.Y + 1.5)

	local bb = Util.make("BillboardGui", {
		Adornee = part,
		Size = UDim2.fromOffset(80, 60),
		StudsOffsetWorldSpace = Vector3.new(0, lift, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = math.huge,
	}, getHolder())
	local iconFrame = Util.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(24, 24),
		BackgroundTransparency = 1,
	}, bb)
	local scale = Util.make("UIScale", { Scale = 1 }, iconFrame)
	local tint = builder(iconFrame)
	local label = Util.make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(80, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextStrokeTransparency = 0.4,
		TextColor3 = Color3.new(1, 1, 1),
		Text = "",
	}, bb)

	local handle, dead = {}, false
	function handle.update(color, state, text, size)
		tint(color, state)
		scale.Scale = size / 24
		bb.Size = UDim2.fromOffset(80, size + 18)
		label.Position = UDim2.new(0.5, 0, 0, size + 2)
		label.TextColor3 = color
		label.Visible = text ~= nil
		label.Text = text or ""
	end
	function handle.isAlive()
		return not dead and bb.Parent ~= nil and inst.Parent ~= nil and inst:IsDescendantOf(workspace)
	end
	function handle.destroy()
		if not dead then
			dead = true
			bb:Destroy()
		end
	end
	return handle
end

-- names = set of instance names, describe(inst) -> color, state (nil color = hide), icon = ICONS key
local function iconEsp(id, icon, names, describe)
	local on, maxDist, cfg = false, 1000, {}
	local found, handles = {}, {}
	local scanAcc, acc = 99, 0

	local function drop(inst)
		local h = handles[inst]
		if h then
			handles[inst] = nil
			pcall(h.destroy)
		end
	end

	local function clearAll()
		for inst in pairs(handles) do
			drop(inst)
		end
	end

	local function rescan()
		table.clear(found)
		for _, d in ipairs(workspace:GetDescendants()) do
			if names[d.Name] and (d:IsA("Model") or d:IsA("BasePart")) then
				local p = d.Parent
				if not (p and names[p.Name]) then -- one icon per object, not one per child part
					found[#found + 1] = d
				end
			end
		end
	end

	features[id] = {
		set = function(enabled, v, _c, o)
			on, cfg = enabled, o
			maxDist = lerp(100, 3000, v)
			if not enabled then
				clearAll()
			end
		end,
		step = function(dt)
			if not on then
				return
			end
			scanAcc += dt
			acc += dt
			if acc < 1 / math.max(cfg.rate or 10, 1) then
				return
			end
			acc = 0
			if scanAcc >= 3 then
				scanAcc = 0
				rescan()
			end
			local root = Util.root()
			local live = {}
			for _, inst in ipairs(found) do
				if inst.Parent and inst:IsDescendantOf(workspace) then
					live[inst] = true
					local ok = pcall(function()
						local dist = root and (inst:GetPivot().Position - root.Position).Magnitude or 0
						local color, state
						if dist <= maxDist then
							color, state = describe(inst, cfg)
						end
						if not color then
							drop(inst)
							return
						end
						local h = handles[inst]
						if h and not h.isAlive() then
							drop(inst)
							h = nil
						end
						if not h then
							h = makeIcon(inst, ICONS[icon])
							if not h then
								return
							end
							handles[inst] = h
						end
						h.update(color, state, cfg.showDist ~= false and ("%dm"):format(math.floor(dist)) or nil, cfg.iconSize or 28)
					end)
					if not ok then
						drop(inst)
					end
				end
			end
			for inst in pairs(handles) do
				if not live[inst] then
					drop(inst)
				end
			end
		end,
		destroy = clearAll,
	}
end

local function hackedScreen(inst)
	local screen = inst:FindFirstChild("Screen", true) -- FILL: part that changes color when a computer is done
	if screen and screen:IsA("BasePart") then
		local c = screen.Color
		return c.G > 0.6 and c.R < 0.5 and c.B < 0.6
	end
	return false
end

iconEsp("fleeComp", "computer", { ComputerTable = true }, function(inst, cfg)
	if hackedScreen(inst) then
		if cfg.hideDone then
			return nil
		end
		return GREEN, "done"
	end
	return CYAN, "todo"
end)

iconEsp("fleePod", "pod", { FreezePod = true }, function()
	return YELLOW, "pod"
end)

iconEsp("fleeExit", "exit", { ExitDoor = true }, function()
	return GREEN, "exit"
end)

return Flee
