-- ModuleScript: games/FleeTheFacility
-- Flee the Facility (place 893973440) and 10 Player Flee (place 17600423422).
--   Role ESP        beast in red, survivors in green (option), chams + labels from the usual ESP options
--   Computer ESP    every computer, colored by whether it is already hacked
--   Pod ESP         freeze pods
--   Exit ESP        exit doors
--   Beast alert     toast when the beast comes within the slider distance
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

local Flee = { name = "FleeTheFacility", features = {} }
local features = Flee.features

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
	{ header = "Map" },
	{ id = "fleeComp", label = "Computer ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 3000, " st"), opts = ESP.options("chams") },
	{ id = "fleePod", label = "Pod ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 3000, " st"), opts = ESP.options("chams") },
	{ id = "fleeExit", label = "Exit ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 3000, " st"), opts = ESP.options("chams") },
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
-- map object ESP (computers, pods, exits)
---------------------------------------------------------------------
-- names = set of instance names, describe(inst) -> color, label
local function objectEsp(names, describe)
	local on, maxDist = false, 1000
	local style = ESP.newStyle()
	local found, handles = {}, {}
	local scanAcc, acc = 99, 0

	local function drop(inst)
		local h = handles[inst]
		if h then
			handles[inst] = nil
			pcall(h.destroy)
		end
	end

	local function rescan()
		table.clear(found)
		for _, d in ipairs(workspace:GetDescendants()) do
			if names[d.Name] and (d:IsA("Model") or d:IsA("BasePart")) then
				local p = d.Parent
				if not (p and names[p.Name]) then -- one marker per object, not one per child part
					found[#found + 1] = d
				end
			end
		end
	end

	local function clearAll()
		for inst in pairs(handles) do
			drop(inst)
		end
	end

	local def = {}
	function def.set(enabled, v, _c, o, span)
		ESP.applyStyle(style, o)
		on = enabled
		if not enabled then
			clearAll()
		end
	end
	function def.step(dt)
		if not on then
			return
		end
		scanAcc += dt
		acc += dt
		if acc < 1 / math.max(style.rate, 1) then
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
					local pos = inst:GetPivot().Position
					local dist = root and (pos - root.Position).Magnitude or 0
					if dist > maxDist then
						drop(inst)
						return
					end
					local color, text = describe(inst, dist)
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
						h = ESP.marker(inst, color, text, nil, style)
						handles[inst] = h
					end
					h.update(color, text)
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
	end
	def.destroy = clearAll
	function def.setDistance(d)
		maxDist = d
	end
	return def
end

-- wraps an objectEsp so the row slider drives its max distance
local function register(id, hi, names, describe)
	local def = objectEsp(names, describe)
	local rawSet = def.set
	def.set = function(on, v, c, o)
		def.setDistance(lerp(100, hi, v))
		rawSet(on, v, c, o)
	end
	features[id] = def
end

local function hackedScreen(inst)
	local screen = inst:FindFirstChild("Screen", true) -- FILL: part that changes color when a computer is done
	if screen and screen:IsA("BasePart") then
		local c = screen.Color
		return c.G > 0.6 and c.R < 0.5 and c.B < 0.6
	end
	return false
end

register("fleeComp", 3000, { ComputerTable = true }, function(inst, dist)
	local done = hackedScreen(inst)
	return done and GREEN or CYAN, (done and "computer (done)  %dm" or "computer  %dm"):format(math.floor(dist))
end)

register("fleePod", 3000, { FreezePod = true }, function(_inst, dist)
	return YELLOW, ("pod  %dm"):format(math.floor(dist))
end)

register("fleeExit", 3000, { ExitDoor = true }, function(_inst, dist)
	return GREEN, ("exit  %dm"):format(math.floor(dist))
end)

return Flee
