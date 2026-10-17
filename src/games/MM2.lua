-- Murder Mystery 2
-- Roles are read from the tools a player holds: "Knife" = murderer, "Gun" = sheriff.
-- Tool / object names ("Knife", "Gun", "GunDrop", "Coin_Server") are from memory, not checked
-- against the live game. If a row does nothing, dump the names in a live round and edit the
-- constants below.

local import = ...
local Util = import("Util")
local ESP = import("ESP")

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local lp = Players.LocalPlayer
local range = Util.range
local fti = firetouchinterest -- executor global, nil if unsupported

local KNIFE, GUN, GUN_DROP, COIN = "Knife", "Gun", "GunDrop", "Coin_Server"

local COLORS = {
	murderer = Color3.fromRGB(255, 70, 70),
	sheriff = Color3.fromRGB(80, 150, 255),
	innocent = Color3.fromRGB(90, 220, 130),
	gun = Color3.fromRGB(255, 214, 64),
}
local LABELS = { murderer = "MURDERER", sheriff = "SHERIFF", innocent = "innocent" }

local function hasTool(plr, name)
	local char = plr.Character
	if char and char:FindFirstChild(name) then
		return true
	end
	local bp = plr:FindFirstChild("Backpack")
	return bp ~= nil and bp:FindFirstChild(name) ~= nil
end

local function roleOf(plr)
	if hasTool(plr, KNIFE) then
		return "murderer"
	end
	if hasTool(plr, GUN) then
		return "sheriff"
	end
	return "innocent"
end

local function findGunDrop()
	local g = Workspace:FindFirstChild(GUN_DROP, true)
	return g and g:IsA("BasePart") and g or nil
end

local MM2 = {
	name = "Murder Mystery 2",
	tab = { name = "MM2", rows = {
		{ id = "mm2Esp", label = "Role ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 2000, " st") },
		{ id = "mm2Alert", label = "Role alerts", slider = "Unused", value = 0, on = false },
		{ id = "mm2Gun", label = "Gun drop ESP", slider = "Unused", value = 0, on = false },
		{ id = "mm2Grab", label = "Auto grab gun", slider = "Unused", value = 0, on = false },
		{ id = "mm2Coins", label = "Coin collect", slider = "Range", value = 40, on = false, fmt = range(30, 500, " st") },
	} },
	features = {},
}
local features = MM2.features

-- role ESP: red murderer, blue sheriff, green innocents
do
	local esp
	features.mm2Esp = {
		init = function()
			esp = ESP.new({
				maxDistance = 1000,
				resolve = function(plr, _char, dist)
					local role = roleOf(plr)
					return COLORS[role], ("%s [%s] %dm"):format(plr.DisplayName, LABELS[role], math.floor(dist))
				end,
			})
		end,
		set = function(on, v)
			esp:setDistance(Util.lerp(100, 2000, v))
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

-- role alerts: toast when the murderer / sheriff show up each round
do
	local enabled, acc, lastM, lastS = false, 0, nil, nil
	features.mm2Alert = {
		set = function(on)
			enabled = on
			if not on then
				lastM, lastS = nil, nil
			end
		end,
		step = function(dt, ctx)
			if not enabled then
				return
			end
			acc += dt
			if acc < 1 then
				return
			end
			acc = 0
			local m, s
			for _, plr in ipairs(Players:GetPlayers()) do
				local role = roleOf(plr)
				if role == "murderer" then
					m = plr
				elseif role == "sheriff" then
					s = plr
				end
			end
			if m ~= lastM then
				lastM = m
				if m then
					ctx.notify("murderer: " .. m.DisplayName, COLORS.murderer)
				end
			end
			if s ~= lastS then
				lastS = s
				if s then
					ctx.notify("sheriff: " .. s.DisplayName, COLORS.sheriff)
				end
			end
		end,
	}
end

-- gun drop ESP: marks the dropped gun after the sheriff dies
do
	local on, acc, marker, target = false, 0, nil, nil
	local function clear()
		if marker then
			marker.destroy()
			marker = nil
		end
		target = nil
	end
	features.mm2Gun = {
		set = function(enabled)
			on = enabled
			if not enabled then
				clear()
			end
		end,
		step = function(dt)
			if not on then
				return
			end
			acc += dt
			if acc < 0.5 then
				return
			end
			acc = 0
			local g = findGunDrop()
			if g then
				if target ~= g or not marker or not marker.isAlive() then
					clear()
					target = g
					marker = ESP.marker(g, COLORS.gun, "GUN DROP", 0.3)
				end
			else
				clear()
			end
		end,
		destroy = clear,
	}
end

-- auto grab gun: touches the drop (or teleports there and straight back when the executor has no
-- firetouchinterest). Skipped while you hold the knife.
do
	local on, acc, cooldown = false, 0, 0
	features.mm2Grab = {
		set = function(enabled)
			on = enabled
		end,
		step = function(dt)
			if not on then
				return
			end
			acc += dt
			if acc < 0.3 or os.clock() < cooldown then
				return
			end
			acc = 0
			if hasTool(lp, KNIFE) then
				return
			end
			local g, root = findGunDrop(), Util.root()
			if not g or not root then
				return
			end
			cooldown = os.clock() + 1
			if fti then
				fti(root, g, 0)
				fti(root, g, 1)
			else
				task.spawn(function()
					local back = root.CFrame
					root.CFrame = g.CFrame
					task.wait(0.2)
					if root.Parent then
						root.CFrame = back
					end
				end)
			end
		end,
	}
end

-- coin collect: touches every coin inside the range slider. Needs firetouchinterest.
do
	local on, acc, radius, warned = false, 0, 100, false
	features.mm2Coins = {
		set = function(enabled, v, ctx)
			on = enabled
			radius = Util.lerp(30, 500, v)
			if enabled and not fti and not warned then
				warned = true
				ctx.notify("coin collect needs firetouchinterest (your executor has none)", COLORS.gun)
			end
		end,
		step = function(dt)
			if not on or not fti then
				return
			end
			acc += dt
			if acc < 1 then
				return
			end
			acc = 0
			local root = Util.root()
			if not root then
				return
			end
			for _, d in ipairs(Workspace:GetDescendants()) do
				if d.Name == COIN and d:IsA("BasePart") and (d.Position - root.Position).Magnitude <= radius then
					fti(root, d, 0)
					fti(root, d, 1)
				end
			end
		end,
	}
end

return MM2
