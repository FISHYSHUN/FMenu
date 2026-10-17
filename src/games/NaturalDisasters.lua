-- Natural Disaster Survival
-- Disaster HUD (reads on-screen text, heuristic), sky platform to sit out most disasters, and a
-- fall speed limit. The disaster word list and the "no fall damage" assumption (damage scales with
-- landing speed) are from memory, not checked against the live game.

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

local NDS = {
	name = "Natural Disaster Survival",
	tab = { name = "NDS", rows = {
		{ id = "ndStatus", label = "Disaster HUD", slider = "Scan speed", value = 40, on = false, fmt = range(0.5, 4, "/s") },
		{ id = "ndSky", label = "Sky platform", slider = "Height", value = 40, on = false, fmt = range(150, 1000, " st") },
		{ id = "ndNoFall", label = "No fall damage", slider = "Max fall speed", value = 30, on = false, fmt = range(30, 120) },
	} },
	features = {},
}
local features = NDS.features

-- disaster HUD: finds visible on-screen text that names a disaster and shows it top left
do
	local label, enabled, interval, acc = nil, false, 0.5, 0
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
	features.ndStatus = {
		init = function(_ctx, hud)
			label = Util.make("TextLabel", {
				Name = "DisasterStatus",
				Position = UDim2.fromOffset(12, 30),
				Size = UDim2.fromOffset(320, 18),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = Color3.fromRGB(255, 214, 64),
				TextStrokeTransparency = 0.5,
				TextXAlignment = Enum.TextXAlignment.Left,
				Visible = false,
				Text = "",
			}, hud)
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
