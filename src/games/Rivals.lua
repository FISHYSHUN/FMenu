-- Rivals
-- Two kinds of aiming, triggerbot, enemy ESP and a target readout. All client side: it moves your camera
-- and clicks, it never touches the game's own state. Assumes standard Player characters with a Head part
-- and a first person camera with the crosshair at screen centre; if Rivals changes that, targets will be off.
--
--   Aim assist  hold right mouse. A gentle pull: it eases your aim toward the target inside the FOV ring,
--               limited in speed, weaker near the edge of the ring, and stops when you are already on it.
--               You still do most of the aiming.
--   Aim lock    hold right mouse. Picks a target inside the ring, then stays on it (even if it leaves the
--               ring) until you let go, it dies, or it goes out of sight. Smoothing 0 = hard snap.
--   With both on, lock wins.
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
local CHEST = { "UpperTorso", "Torso", "HumanoidRootPart" }

local shared = { fov = 150, team = true, visible = true, part = "head", lead = 0 }
local aim = { assist = false, lock = false, strength = 0.4, smooth = 0, bound = false, target = nil }

local function isEnemy(plr)
	if plr == lp then
		return false
	end
	if shared.team and Util.isTeammate(plr) then
		return false
	end
	return true
end

local function valid(plr)
	return plr ~= nil and plr.Parent ~= nil and isEnemy(plr) and Util.isAlive(plr.Character)
end

local function chestOf(char)
	for _, name in ipairs(CHEST) do
		local p = char:FindFirstChild(name)
		if p then
			return p
		end
	end
	return nil
end

-- the body parts that count as targets for the current "aim part" setting
local function candidates(char)
	local list = {}
	local head, chest = char:FindFirstChild("Head"), chestOf(char)
	if shared.part == "head" then
		list[1] = head or chest
	elseif shared.part == "chest" then
		list[1] = chest or head
	else
		list[#list + 1] = head
		list[#list + 1] = chest
	end
	return list
end

-- where to aim at: the part, led by the target's velocity when prediction is on
local function aimPos(part)
	local pos = part.Position
	if shared.lead > 0 then
		local root = part.Parent and part.Parent:FindFirstChild("HumanoidRootPart")
		local cam = workspace.CurrentCamera
		if root and cam then
			local travel = (pos - cam.CFrame.Position).Magnitude / 300 -- rough bullet travel time
			pos = pos + root.AssemblyLinearVelocity * travel * shared.lead
		end
	end
	return pos
end

-- best part of one character: nearest to the screen centre within maxDist pixels (and visible if asked)
local function pick(char, center, cam, maxDist)
	local best, bestD
	for _, part in ipairs(candidates(char)) do
		local p, onScreen = cam:WorldToViewportPoint(part.Position)
		if onScreen and p.Z > 0 then
			local d = (Vector2.new(p.X, p.Y) - center).Magnitude
			if d <= maxDist and (not shared.visible or Util.visible(cam.CFrame.Position, part)) and (not bestD or d < bestD) then
				best, bestD = part, d
			end
		end
	end
	return best, bestD
end

-- closest enemy to the screen centre inside `radius` pixels -> part, player, distance
local function acquire(cam, center, radius)
	local bestPart, bestPlr, bestD
	for _, plr in ipairs(Players:GetPlayers()) do
		if valid(plr) then
			local part, d = pick(plr.Character, center, cam, radius)
			if part and (not bestD or d < bestD) then
				bestPart, bestPlr, bestD = part, plr, d
			end
		end
	end
	return bestPart, bestPlr, bestD
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
		{ header = "Aiming" },
		{ id = "rvAim", label = "Aim assist", slider = "Pull strength", value = 40, on = false, fmt = range(0, 100, "%") },
		{ id = "rvLock", label = "Aim lock", slider = "Smoothing (0 = snap)", value = 0, on = false, fmt = function(v) return v == 0 and "snap" or ("%d%%"):format(v) end },
		{ id = "rvFov", label = "FOV ring", slider = "Radius", value = 40, on = false, fmt = range(40, 400, "px") },
		{ id = "rvPart", label = "Aim part", slider = "Head / Chest / Closest", value = 0, on = true, fmt = function(v) return v < 34 and "Head" or (v < 67 and "Chest" or "Closest") end },
		{ id = "rvPred", label = "Prediction", slider = "Lead amount", value = 30, on = false, fmt = range(0, 100, "%") },
		{ header = "Shooting & ESP" },
		{ id = "rvTrigger", label = "Triggerbot", slider = "Reaction delay", value = 15, on = false, fmt = range(0, 300, "ms") },
		{ id = "rvEsp", label = "Enemy ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 2000, " st") },
		{ id = "rvInfo", label = "Target info", slider = "Unused", value = 0, on = false },
		{ header = "Filters" },
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

features.rvPart = {
	set = function(on, v)
		shared.part = (not on or v < 34) and "head" or (v < 67 and "chest" or "closest")
	end,
}

features.rvPred = {
	set = function(on, v)
		shared.lead = on and v / 100 or 0
	end,
}

-- aim assist + aim lock share one render step (right mouse held)
do
	local function aimStep(dt)
		if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) or UserInputService:GetFocusedTextBox() then
			aim.target = nil
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		local center = Vector2.new(vp.X / 2, vp.Y / 2)

		-- keep the current target while it stays valid (lock: anywhere on screen, assist: a bit past the ring)
		local part, d
		if aim.target and valid(aim.target) then
			part, d = pick(aim.target.Character, center, cam, aim.lock and math.huge or shared.fov * 1.3)
		end
		if not part then
			local plr
			part, plr, d = acquire(cam, center, shared.fov)
			aim.target = plr
		end
		if not part then
			return
		end

		local origin = cam.CFrame.Position
		local pos = aimPos(part)
		local dir = pos - origin
		if dir.Magnitude < 0.01 then
			return
		end
		local desired = CFrame.lookAt(origin, pos)

		if aim.lock then
			local alpha = aim.smooth <= 0 and 1 or (1 - math.exp(-dt * Util.lerp(40, 5, aim.smooth)))
			cam.CFrame = cam.CFrame:Lerp(desired, alpha)
		else
			local angle = math.acos(math.clamp(cam.CFrame.LookVector:Dot(dir.Unit), -1, 1))
			if angle < math.rad(0.4) then
				return -- already on it, leave your aim alone
			end
			local falloff = 1 - 0.6 * math.min(1, d / shared.fov) -- weaker toward the edge of the ring
			local rate = Util.lerp(1.5, 12, aim.strength * 100) * falloff
			local step = math.min(angle * (1 - math.exp(-dt * rate)), math.rad(Util.lerp(60, 300, aim.strength * 100)) * dt)
			cam.CFrame = cam.CFrame:Lerp(desired, step / angle)
		end
	end

	local function refresh()
		local need = aim.assist or aim.lock
		if need and not aim.bound then
			aim.bound = true
			RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 1, aimStep)
		elseif not need and aim.bound then
			aim.bound = false
			RunService:UnbindFromRenderStep(AIM_BIND)
		end
		if not need then
			aim.target = nil
		end
	end

	features.rvAim = {
		set = function(on, v)
			aim.assist = on
			aim.strength = v / 100
			refresh()
		end,
		destroy = function()
			aim.assist, aim.lock = false, false
			refresh()
		end,
	}
	features.rvLock = {
		set = function(on, v)
			aim.lock = on
			aim.smooth = v
			refresh()
		end,
		destroy = function()
			aim.assist, aim.lock = false, false
			refresh()
		end,
	}
end

-- FOV ring: also sets the radius the aiming uses (even while the ring is hidden)
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

-- target info: draggable readout of who the aiming is on right now
do
	local label, enabled, acc = nil, false, 0
	features.rvInfo = {
		init = function(ctx)
			label = ctx.hudLabel("AimTarget", Color3.fromRGB(255, 214, 64), Enum.Font.GothamBold)
			ctx.draggable(label, "AimTarget", "left", 1)
		end,
		set = function(on)
			enabled = on
			label.Visible = on
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			if acc < 0.1 then
				return
			end
			acc = 0
			local plr = aim.target
			if plr and valid(plr) then
				local hum = Util.humanoid(plr.Character)
				local root, myRoot = Util.rootOf(plr.Character), Util.root()
				local dist = (root and myRoot) and (root.Position - myRoot.Position).Magnitude or 0
				label.Text = ("%s  %dhp  %dm"):format(plr.DisplayName, math.floor(hum and hum.Health or 0), math.floor(dist))
			else
				label.Text = "no target"
			end
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
			if plr and isEnemy(plr) and Util.isAlive(plr.Character) then
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
					return Color3.fromRGB(255, 70, 70), ESP.text(plr, char, dist)
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
