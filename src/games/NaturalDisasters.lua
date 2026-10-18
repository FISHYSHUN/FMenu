-- Natural Disaster Survival
-- Disaster HUD (reads on-screen text, heuristic), disaster alerts, sky platform to sit out most disasters,
-- an air floor that follows you, and a fall speed limit. The disaster word list and the "no fall damage"
-- assumption (damage scales with landing speed) are from memory, not checked against the live game.

local import = ...
local Util = import("Util")

local Players = game:GetService("Players")

local lp = Players.LocalPlayer
local range = Util.range

local DISASTERS = {
	"tornado", "tsunami", "flood", "earthquake", "meteor", "volcan", "blizzard", "sandstorm",
	"acid rain", "wildfire", "thunder", "lightning", "virus", "hail", "sinkhole", "fire",
}
local OWN_GUIS = { MenuWidget = true, MenuWidgetHUD = true }
local YELLOW = Color3.fromRGB(255, 214, 64)

local NDS = {
	name = "Natural Disaster Survival",
	tab = { name = "NDS", rows = {
		{ id = "ndStatus", label = "Disaster HUD", slider = "Scan speed", value = 40, on = false, fmt = range(0.5, 4, "/s") },
		{ id = "ndAlert", label = "Disaster alert", slider = "Unused", value = 0, on = false },
		{ id = "ndSky", label = "Sky platform", slider = "Height", value = 40, on = false, fmt = range(150, 1000, " st") },
		{ id = "ndAir", label = "Air floor", slider = "Lift above you", value = 20, on = false, fmt = range(5, 100, " st") },
		{ id = "ndNoFall", label = "No fall damage", slider = "Max fall speed", value = 30, on = false, fmt = range(30, 120) },
	} },
	features = {},
}
local features = NDS.features

-- finds visible on-screen text that names a disaster (nil when there is none)
local function scan()
	local pg = lp:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	for _, d in ipairs(pg:GetDescendants()) do
		if d:IsA("TextLabel") and d.Visible and d.Text ~= "" then
			local gui = d:FindFirstAncestorOfClass("ScreenGui")
			if gui and not OWN_GUIS[gui.Name] and gui.Enabled then
				local text = d.Text:lower()
				for _, word in ipairs(DISASTERS) do
					if text:find(word, 1, true) then
						return d.Text
					end
				end
			end
		end
	end
	return nil
end

-- disaster HUD: shows what scan() found, top left (drag it to move it)
do
	local label, enabled, interval, acc = nil, false, 0.5, 0
	features.ndStatus = {
		init = function(ctx)
			label = ctx.hudLabel("DisasterStatus", YELLOW, Enum.Font.GothamBold)
			ctx.draggable(label, "DisasterStatus", "left", 1)
		end,
		set = function(on, v)
			enabled = on
			label.Visible = on
			interval = 1 / Util.lerp(0.5, 4, v)
			acc = interval
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			if acc >= interval then
				acc = 0
				local text = scan()
				label.Text = text and ("disaster: " .. text:sub(1, 40)) or "disaster: --"
			end
		end,
	}
end

-- disaster alert: one toast whenever a new disaster text shows up (re-arms when it disappears)
do
	local enabled, acc, last = false, 0, nil
	features.ndAlert = {
		set = function(on)
			enabled = on
			last = nil
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
			local text = scan()
			if text and text ~= last then
				ctx.notify("disaster: " .. text:sub(1, 40), YELLOW)
			end
			last = text
		end,
	}
end

-- sky platform: parks you on a platform high above the map, toggling off sends you back
do
	local platform, origin = nil, nil
	features.ndSky = {
		set = function(on, v)
			local root = Util.root()
			if on then
				if not root then
					return
				end
				origin = origin or root.CFrame
				if not platform or not platform.Parent then
					platform = Util.make("Part", {
						Name = "FMenuPlatform",
						Anchored = true,
						Size = Vector3.new(80, 2, 80),
						Material = Enum.Material.ForceField,
						Color = Color3.fromRGB(139, 125, 255),
						Transparency = 0.5,
						CastShadow = false,
					}, workspace)
				end
				platform.Position = origin.Position + Vector3.new(0, Util.lerp(150, 1000, v), 0)
				root.CFrame = platform.CFrame + Vector3.new(0, 4, 0)
			else
				if platform then
					platform:Destroy()
					platform = nil
				end
				if origin and root then
					root.CFrame = origin
				end
				origin = nil
			end
		end,
		destroy = function()
			if platform then
				platform:Destroy()
				platform = nil
			end
		end,
	}
end

-- air floor: invisible floor `lift` studs above where you turned it on that follows you around, so you
-- can walk over water / lava / the ground. Turning it off drops you back down.
do
	local floorPart, enabled, y = nil, false, 0
	local function clear()
		if floorPart then
			floorPart:Destroy()
			floorPart = nil
		end
	end
	features.ndAir = {
		set = function(on, v)
			local root = Util.root()
			if on and root then
				if not enabled then
					y = root.Position.Y - 3.6 -- just under your feet
				end
				enabled = true
				local lift = Util.lerp(5, 100, v)
				local prev = floorPart and floorPart:GetAttribute("lift") or 0
				local delta = lift - prev -- slider moved: only the difference is applied
				if not floorPart or not floorPart.Parent then
					floorPart = Util.make("Part", {
						Name = "FMenuFloor",
						Anchored = true,
						Size = Vector3.new(24, 1, 24),
						Transparency = 1,
						CastShadow = false,
					}, workspace)
				end
				y = y + delta
				floorPart:SetAttribute("lift", lift)
				floorPart.Position = Vector3.new(root.Position.X, y, root.Position.Z)
				root.CFrame = root.CFrame + Vector3.new(0, delta, 0)
			else
				enabled = false
				clear()
			end
		end,
		step = function()
			if not enabled or not floorPart then
				return
			end
			local root = Util.root()
			if root then
				floorPart.Position = Vector3.new(root.Position.X, y, root.Position.Z)
			end
		end,
		destroy = function()
			enabled = false
			clear()
		end,
	}
end

-- no fall damage: caps downward speed so you land softly
do
	local enabled, maxFall = false, 50
	features.ndNoFall = {
		set = function(on, v)
			enabled = on
			maxFall = Util.lerp(30, 120, v)
		end,
		step = function()
			if not enabled then
				return
			end
			local root = Util.root()
			if not root then
				return
			end
			local vel = root.AssemblyLinearVelocity
			if vel.Y < -maxFall then
				root.AssemblyLinearVelocity = Vector3.new(vel.X, -maxFall, vel.Z)
			end
		end,
	}
end

return NDS
