-- Rivals
-- Aim assist, FOV ring, triggerbot and enemy ESP. All client side: it moves your camera and clicks,
-- it never touches the game's own state. Assumes standard Player characters with a Head part and a
-- first person camera with the crosshair at screen centre; if Rivals changes that, targets will be off.
--
-- Rivals teleports you from the lobby into a match (a different place of the same universe). This module
-- is picked by universe id in Games.index, and loader.lua re-runs itself after the teleport, so the tab
-- is there in the lobby and in every match.

local import = ...
local Util = import("Util")
local ESP = import("ESP")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local range = Util.range

local AIM_BIND = "FMenuAim"

local shared = { fov = 150, team = true, visible = true }

local function isEnemy(plr)
	if plr == lp then
		return false
	end
	if shared.team and Util.isTeammate(plr) then
		return false
	end
	return true
end

-- closest enemy head to the screen centre inside the FOV ring
local function bestTarget()
	local cam = workspace.CurrentCamera
	local vp = cam.ViewportSize
	local center = Vector2.new(vp.X / 2, vp.Y / 2)
	local best, bestDist = nil, shared.fov
	for _, plr in ipairs(Players:GetPlayers()) do
		if isEnemy(plr) and Util.alive(plr.Character) then
			local head = plr.Character:FindFirstChild("Head")
			if head then
				local p, onScreen = cam:WorldToViewportPoint(head.Position)
				if onScreen then
					local d = (Vector2.new(p.X, p.Y) - center).Magnitude
					if d < bestDist and (not shared.visible or Util.visible(cam.CFrame.Position, head)) then
						best, bestDist = head, d
					end
				end
			end
		end
	end
	return best
end

local function click()
	if mouse1click then -- executor global
		mouse1click()
		return
	end
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		local vp = workspace.CurrentCamera.ViewportSize
		vim:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, true, game, 0)
		vim:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, false, game, 0)
	end)
end

local Rivals = {
	name = "Rivals",
	tab = { name = "Rivals", rows = {
		{ id = "rvAim", label = "Aim assist", slider = "Strength", value = 40, on = false, fmt = range(5, 95, "%") },
		{ id = "rvFov", label = "FOV ring", slider = "Radius", value = 40, on = false, fmt = range(40, 400, "px") },
		{ id = "rvTrigger", label = "Triggerbot", slider = "Reaction delay", value = 15, on = false, fmt = range(0, 300, "ms") },
		{ id = "rvEsp", label = "Enemy ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 2000, " st") },
		{ id = "rvVis", label = "Visible only", slider = "Unused", value = 0, on = true },
		{ id = "rvTeam", label = "Team check", slider = "Unused", value = 0, on = true },
	} },
	features = {},
}
local features = Rivals.features

features.rvTeam = {
	set = function(on)
		shared.team = on
	end,
}

features.rvVis = {
	set = function(on)
		shared.visible = on
	end,
}

-- aim assist: hold right mouse, the camera eases toward the best head in the ring
do
	local bound, alpha = false, 0.4
	local function aimStep()
		if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
			return
		end
		local head = bestTarget()
		if not head then
			return
		end
		local cam = workspace.CurrentCamera
		cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, head.Position), alpha)
	end
	features.rvAim = {
		set = function(on, v)
			alpha = Util.lerp(0.05, 0.95, v)
			if on and not bound then
				bound = true
				RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 1, aimStep)
			elseif not on and bound then
				bound = false
				RunService:UnbindFromRenderStep(AIM_BIND)
			end
		end,
		destroy = function()
			if bound then
				bound = false
				RunService:UnbindFromRenderStep(AIM_BIND)
			end
		end,
	}
end

-- FOV ring: also sets the radius the aim assist uses (even while the ring is hidden)
do
	local ring
	features.rvFov = {
		init = function(_ctx, hud)
			ring = Util.make("Frame", {
				Name = "AimRing",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(300, 300),
				BackgroundTransparency = 1,
				Visible = false,
			}, hud)
			Util.make("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
			Util.make("UIStroke", {
				Color = Color3.fromRGB(255, 255, 255),
				Thickness = 1.5,
				Transparency = 0.35,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}, ring)
		end,
		set = function(on, v)
			shared.fov = Util.lerp(40, 400, v)
			ring.Size = UDim2.fromOffset(shared.fov * 2, shared.fov * 2)
			ring.Visible = on
		end,
	}
end

-- triggerbot: clicks while the crosshair is on an enemy. value = reaction delay 0 to 300 ms
do
	local enabled, delay, acquiredAt, lastClick = false, 0.05, nil, 0
	features.rvTrigger = {
		set = function(on, v)
			enabled = on
			delay = Util.lerp(0, 300, v) / 1000
			if not on then
				acquiredAt = nil
			end
		end,
		step = function()
			if not enabled then
				return
			end
			local cam = workspace.CurrentCamera
			local hit = workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 1500, Util.rayParams())
			local plr = hit and Util.playerFromPart(hit.Instance)
			if plr and isEnemy(plr) and Util.alive(plr.Character) then
				local now = os.clock()
				acquiredAt = acquiredAt or now
				if now - acquiredAt >= delay and now - lastClick > 0.12 then
					lastClick = now
					click()
				end
			else
				acquiredAt = nil
			end
		end,
	}
end

-- enemy ESP: honours the team check row
do
	local esp
	features.rvEsp = {
		init = function()
			esp = ESP.new({
				maxDistance = 1000,
				resolve = function(plr, char, dist)
					if not isEnemy(plr) then
						return nil
					end
					local hum = Util.humanoid(char)
					return Color3.fromRGB(255, 70, 70),
						("%s  %dm  %dhp"):format(plr.DisplayName, math.floor(dist), math.floor(hum and hum.Health or 0))
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

return Rivals