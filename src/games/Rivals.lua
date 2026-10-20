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
--   Target priority (option on both): Crosshair / Lowest HP / Nearest decides who gets picked inside the ring.
--
--   Extras      Nearest enemy HUD (world distance), Session K/D HUD (leaderstats, falls back to own deaths),
--               Viewmodel chams (recolors the gun / arms models parented to the camera).
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

-- "hold to aim" key, an option on both Aim assist and Aim lock
local function holdOption()
	return { type = "choice", key = "hold", label = "Aim key", choices = { "Right mouse", "Left mouse", "Shift", "Always" }, default = "Right mouse" }
end

-- who gets picked when several enemies are inside the ring, an option on both Aim assist and Aim lock
local function priorityOption()
	return { type = "choice", key = "priority", label = "Target priority", choices = { "Crosshair", "Lowest HP", "Nearest" }, default = "Crosshair" }
end
local CHEST = { "UpperTorso", "Torso", "HumanoidRootPart" }

local shared = { fov = 150, team = true, visible = true, part = "head", lead = 0, priority = "Crosshair" }
local aim = { assist = false, lock = false, strength = 0.4, smooth = 0, bound = false, target = nil, dead = 0.4, falloff = 0.6 }

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

-- lower score wins: pixels from the crosshair, health, or world distance depending on the priority option
local function score(plr, d)
	if shared.priority == "Lowest HP" then
		local hum = Util.humanoid(plr.Character)
		return hum and hum.Health or math.huge
	elseif shared.priority == "Nearest" then
		local r, me = Util.rootOf(plr.Character), Util.root()
		return (r and me) and (r.Position - me.Position).Magnitude or math.huge
	end
	return d
end

-- best enemy inside `radius` pixels by priority -> part, player, distance (pixels from the centre)
local function acquire(cam, center, radius)
	local bestPart, bestPlr, bestD, bestS
	for _, plr in ipairs(Players:GetPlayers()) do
		if valid(plr) then
			local part, d = pick(plr.Character, center, cam, radius)
			if part then
				local s = score(plr, d)
				if not bestS or s < bestS then
					bestPart, bestPlr, bestD, bestS = part, plr, d, s
				end
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
		{ id = "rvAim", label = "Aim assist", slider = "Pull strength", value = 40, on = false, fmt = range(0, 100, "%"), opts = {
			Util.modeOption(),
			holdOption(),
			priorityOption(),
			{ type = "slider", key = "dead", label = "Dead zone", min = 0.1, max = 3, step = 0.1, unit = " deg", default = 0.4 },
			{ type = "slider", key = "falloff", label = "Edge falloff", min = 0, max = 1, step = 0.05, pct = true, default = 0.6 },
		} },
		{ id = "rvLock", label = "Aim lock", slider = "Smoothing (0 = snap)", value = 0, on = false, fmt = function(v) return v == 0 and "snap" or ("%d%%"):format(v) end, opts = { Util.modeOption(), holdOption(), priorityOption() } },
		{ id = "rvFov", label = "FOV ring", slider = "Radius", value = 40, on = false, fmt = range(40, 400, "px"), opts = {
			Util.modeOption(),
			{ type = "slider", key = "thickness", label = "Thickness", min = 1, max = 5, step = 0.5, unit = "px", default = 1.5 },
			{ type = "slider", key = "alpha", label = "Opacity", min = 0.1, max = 1, step = 0.05, pct = true, default = 0.65 },
			{ type = "toggle", key = "tint", label = "Custom color", default = false },
			{ type = "hue", key = "hue", label = "Hue", default = 0.55 },
		} },
		{ id = "rvPart", label = "Aim part", slider = "Head / Chest / Closest", value = 0, on = true, fmt = function(v) return v < 34 and "Head" or (v < 67 and "Chest" or "Closest") end },
		{ id = "rvPred", label = "Prediction", slider = "Lead amount", value = 30, on = false, fmt = range(0, 100, "%") },
		{ header = "Shooting & ESP" },
		{ id = "rvTrigger", label = "Triggerbot", slider = "Reaction delay", value = 15, on = false, fmt = range(0, 300, "ms"), opts = {
			Util.modeOption(),
			{ type = "slider", key = "interval", label = "Time between clicks", min = 0.05, max = 0.5, step = 0.01, unit = "s", default = 0.12 },
		} },
		{ id = "rvEsp", label = "Enemy ESP", slider = "Max distance", value = 100, on = false, fmt = range(100, 2000, " st"), opts = ESP.options("player") },
		{ id = "rvInfo", label = "Target info", slider = "Unused", value = 0, on = false },
		{ header = "Filters" },
		{ id = "rvVis", label = "Visible only", slider = "Unused", value = 0, on = true },
		{ id = "rvTeam", label = "Team check", slider = "Unused", value = 0, on = true },
		{ header = "Extras" },
		{ id = "rvNear", label = "Nearest enemy", slider = "Unused", value = 0, on = false },
		{ id = "rvKd", label = "Session K/D", slider = "Unused", value = 0, on = false },
		{ id = "rvViewmodel", label = "Viewmodel chams", slider = "Unused", value = 0, on = false, opts = {
			{ type = "choice", key = "material", label = "Material", choices = { "Neon", "ForceField", "Glass" }, default = "Neon" },
			{ type = "slider", key = "alpha", label = "Opacity", min = 0.1, max = 1, step = 0.05, pct = true, default = 0.6 },
			{ type = "hue", key = "hue", label = "Hue", default = 0.55 },
		} },
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

-- aim assist + aim lock share one render step (aim key held, set in either row's options)
do
	local function activeCfg()
		return (aim.lock and aim.lockCfg) or aim.assistCfg or {}
	end

	local function aimHeld()
		local hold = activeCfg().hold or "Right mouse"
		if hold == "Always" then
			return true
		elseif hold == "Left mouse" then
			return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		elseif hold == "Shift" then
			return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		end
		return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	end

	local function aimStep(dt)
		if not aimHeld() or UserInputService:GetFocusedTextBox() then
			aim.target = nil
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		local center = Vector2.new(vp.X / 2, vp.Y / 2)

		-- priority comes from whichever row is driving (lock wins when both are on)
		shared.priority = activeCfg().priority or "Crosshair"

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
			if angle < math.rad(aim.dead) then
				return -- already on it, leave your aim alone
			end
			local falloff = 1 - aim.falloff * math.min(1, d / shared.fov) -- weaker toward the edge of the ring
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
		set = function(on, v, _c, o)
			aim.assist = on
			aim.assistCfg = o
			aim.strength = v / 100 * Util.level(o.mode).aim
			aim.dead = o.dead or 0.4
			aim.falloff = o.falloff or 0.6
			refresh()
		end,
		destroy = function()
			aim.assist, aim.lock = false, false
			refresh()
		end,
	}
	features.rvLock = {
		set = function(on, v, _c, o)
			aim.lock = on
			aim.lockCfg = o
			aim.smooth = math.max(v, Util.level(o.mode).smooth)
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
	local ring, stroke
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
			stroke = Util.make("UIStroke", {
				Color = Color3.fromRGB(255, 255, 255),
				Thickness = 1.5,
				Transparency = 0.35,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}, ring)
		end,
		set = function(on, v, _c, o)
			stroke.Thickness = o.thickness or 1.5
			stroke.Transparency = 1 - (o.alpha or 0.65)
			stroke.Color = o.tint and Color3.fromHSV(o.hue or 0, 0.85, 1) or Color3.fromRGB(255, 255, 255)
			shared.fov = Util.lerp(40, 400, v) * Util.level(o.mode).fov
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
	local enabled, delay, acquiredAt, lastClick, cfg, jitter, extra = false, 0.05, nil, 0, {}, 0, 0
	features.rvTrigger = {
		set = function(on, v, _c, o)
			enabled = on
			cfg = o
			local L = Util.level(o.mode)
			delay = math.max(Util.lerp(0, 300, v), L.delay) / 1000
			jitter = L.jitter / 1000
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
				if not acquiredAt then
					acquiredAt = now
					extra = math.random() * jitter -- humanised: a different reaction time every time
				end
				if now - acquiredAt >= delay + extra and now - lastClick > (cfg.interval or 0.12) then
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
				resolve = function(plr, char, dist, style)
					if not isEnemy(plr) then
						return nil
					end
					if style.hideTeam and Util.isTeammate(plr) then
						return nil
					end
					return ESP.color(plr, char, Color3.fromRGB(255, 70, 70), style, true), ESP.text(plr, char, dist, nil, style)
				end,
			})
		end,
		set = function(on, v, _c, o)
			esp:configure(o)
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

-- nearest enemy: world-distance nearest, ignores the FOV ring and line of sight
do
	local label, enabled, acc = nil, false, 0
	features.rvNear = {
		init = function(ctx)
			label = ctx.hudLabel("NearestEnemy", Color3.fromRGB(255, 120, 120), Enum.Font.GothamBold)
			ctx.draggable(label, "NearestEnemy", "left", 1)
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
			local me = Util.root()
			local best, bestD
			for _, plr in ipairs(Players:GetPlayers()) do
				if valid(plr) then
					local r = Util.rootOf(plr.Character)
					if r and me then
						local d = (r.Position - me.Position).Magnitude
						if not bestD or d < bestD then
							best, bestD = plr, d
						end
					end
				end
			end
			if best then
				local hum = Util.humanoid(best.Character)
				label.Text = ("nearest  %s  %dhp  %dm"):format(best.DisplayName, math.floor(hum and hum.Health or 0), math.floor(bestD))
			else
				label.Text = "nearest  --"
			end
		end,
	}
end

-- session K/D: reads leaderstats, falls back to counting your own deaths
do
	local KILLS, DEATHS = "Kills", "Deaths" -- FILL: print(lp.leaderstats:GetChildren()) in a match for the real names
	local label, enabled, acc = nil, false, 0
	local base, deaths, diedConn = {}, 0, nil
	local function stat(name)
		local ls = lp:FindFirstChild("leaderstats")
		local v = ls and ls:FindFirstChild(name)
		return v and v:IsA("ValueBase") and tonumber(v.Value) or nil
	end
	local function hook(char)
		if diedConn then
			diedConn:Disconnect()
			diedConn = nil
		end
		local hum = char:WaitForChild("Humanoid", 5)
		if hum then
			diedConn = hum.Died:Connect(function()
				deaths += 1
			end)
		end
	end
	local charConn
	features.rvKd = {
		init = function(ctx)
			label = ctx.hudLabel("SessionKD", Color3.fromRGB(236, 238, 244), Enum.Font.GothamBold)
			ctx.draggable(label, "SessionKD", "left", 1)
		end,
		set = function(on)
			enabled = on
			label.Visible = on
			if on and not charConn then
				base = { k = stat(KILLS), d = stat(DEATHS) }
				deaths = 0
				charConn = lp.CharacterAdded:Connect(hook)
				if lp.Character then
					task.spawn(hook, lp.Character)
				end
			elseif not on and charConn then
				charConn:Disconnect()
				charConn = nil
				if diedConn then
					diedConn:Disconnect()
					diedConn = nil
				end
			end
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			if acc < 0.5 then
				return
			end
			acc = 0
			local k, d = stat(KILLS), stat(DEATHS)
			local kills = (k and base.k) and (k - base.k) or nil
			local dead = (d and base.d) and (d - base.d) or deaths
			label.Text = kills and ("session  %dK  %dD  %.2f"):format(kills, dead, kills / math.max(dead, 1)) or ("session  ?K  %dD"):format(dead)
		end,
		destroy = function()
			if charConn then
				charConn:Disconnect()
				charConn = nil
			end
			if diedConn then
				diedConn:Disconnect()
				diedConn = nil
			end
		end,
	}
end

-- viewmodel chams: recolors the gun / arms models parented to the camera (originals restored when off)
do
	local MATERIALS = { Neon = Enum.Material.Neon, ForceField = Enum.Material.ForceField, Glass = Enum.Material.Glass }
	local enabled, cfg, acc = false, {}, 0
	local orig = setmetatable({}, { __mode = "k" }) -- part -> { m, c, t }
	local function restore()
		for part, o in pairs(orig) do
			if part.Parent then
				part.Material, part.Color, part.Transparency = o.m, o.c, o.t
			end
		end
		table.clear(orig)
	end
	local function apply()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local color = Color3.fromHSV(cfg.hue or 0.55, 0.85, 1)
		for _, model in ipairs(cam:GetChildren()) do
			-- FILL: if it also hits stuff it should not, narrow this to the viewmodel's real name
			if model:IsA("Model") and not model:FindFirstChildOfClass("Humanoid") then
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") then
						if not orig[d] then
							orig[d] = { m = d.Material, c = d.Color, t = d.Transparency }
						end
						d.Material = MATERIALS[cfg.material] or Enum.Material.Neon
						d.Color = color
						d.Transparency = 1 - (cfg.alpha or 0.6)
					end
				end
			end
		end
	end
	features.rvViewmodel = {
		set = function(on, _v, _c, o)
			enabled, cfg = on, o
			acc = 1
			if not on then
				restore()
			end
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			if acc >= 0.25 then -- viewmodels get rebuilt on weapon swap, so re-apply
				acc = 0
				apply()
			end
		end,
		destroy = restore,
	}
end

return Rivals
