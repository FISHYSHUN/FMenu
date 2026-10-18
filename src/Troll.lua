-- ModuleScript: Troll
-- Silly stuff for messing around. Everything is client side: it moves YOUR character (which other players
-- can see because the server replicates your position) or changes your own camera. Nothing here touches
-- other players' characters or the game's own state, and nothing chats or spams.
--
--   Troll.tab       the tab definition (rows + right-click options), picked up by Games.lua
--   Troll.features  { id = { set, step } }, merged into Functionality's registry
--
-- Player pranks (orbit, head sit, shadow, spectate) pick a target with the "Target" option:
--   Nearest = the closest player when you turn it on, Random = a random one. The target is kept until
--   they die or leave, then a new one is picked. Changing the option re-picks.
-- Feature set() functions get (enabled, value, ctx, opts); `opts` is the live table of the right-click menu,
-- so features keep it and read it every frame.

local import = ...
local Util = import("Util")

local Players = game:GetService("Players")

local lp = Players.LocalPlayer
local lerp, range = Util.lerp, Util.range

local Troll = { features = {} }
local features = Troll.features

local TARGET = { type = "choice", key = "target", label = "Target", choices = { "Nearest", "Random" }, default = "Nearest" }

Troll.tab = { name = "Troll", rows = {
	{ header = "Movement" },
	{ id = "trSpin", label = "Spin", slider = "Spin speed", value = 40, on = false, fmt = range(90, 2160, " deg/s") },
	{ id = "trMoon", label = "Moonwalk", slider = "Unused", value = 0, on = false },
	{ id = "trVibe", label = "Vibrate", slider = "Intensity", value = 30, on = false, fmt = function(v) return ("%.1f st"):format(lerp(0.1, 1.5, v)) end },
	{ id = "trDead", label = "Play dead", slider = "Unused", value = 0, on = false, opts = {
		{ type = "choice", key = "pose", label = "Pose", choices = { "On back", "On face" }, default = "On back" },
	} },
	{ id = "trDance", label = "Emote spam", slider = "Repeat every", value = 30, on = false, fmt = range(2, 15, "s"), opts = {
		{ type = "choice", key = "emote", label = "Emote", choices = { "dance", "dance2", "dance3", "cheer", "laugh", "point", "wave" }, default = "dance" },
	} },
	{ header = "Players" },
	{ id = "trOrbit", label = "Orbit player", slider = "Radius", value = 20, on = false, fmt = range(3, 40, " st"), opts = {
		TARGET,
		{ type = "slider", key = "speed", label = "Orbit speed", min = 30, max = 720, step = 10, unit = " deg/s", default = 120 },
		{ type = "slider", key = "height", label = "Height", min = -3, max = 15, step = 1, unit = " st", default = 2 },
	} },
	{ id = "trHead", label = "Head sit", slider = "Height offset", value = 0, on = false, fmt = range(0, 6, " st"), opts = { TARGET } },
	{ id = "trFollow", label = "Shadow", slider = "Keep distance", value = 10, on = false, fmt = range(3, 25, " st"), opts = { TARGET } },
	{ id = "trSpec", label = "Spectate", slider = "Unused", value = 0, on = false, opts = { TARGET } },
} }

---------------------------------------------------------------------
-- targets
---------------------------------------------------------------------
local function usable(plr)
	return plr ~= nil and plr.Parent ~= nil and Util.isAlive(plr.Character) and Util.rootOf(plr.Character) ~= nil
end

local function pick(mode)
	local myRoot = Util.root()
	local list, best, bestD = {}, nil, nil
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp and usable(plr) then
			list[#list + 1] = plr
			local d = myRoot and (Util.rootOf(plr.Character).Position - myRoot.Position).Magnitude or 0
			if not bestD or d < bestD then
				best, bestD = plr, d
			end
		end
	end
	if mode == "Random" and #list > 0 then
		return list[math.random(#list)]
	end
	return best
end

-- returns get(mode) -> player or nil, reset()
local function targeter()
	local current, lastMode = nil, nil
	local function get(mode)
		if mode ~= lastMode then
			current, lastMode = nil, mode
		end
		if not usable(current) then
			current = pick(mode)
		end
		return current
	end
	local function reset()
		current = nil
	end
	return get, reset
end

---------------------------------------------------------------------
-- movement pranks
---------------------------------------------------------------------

-- spin: your character rotates on the spot, everyone sees it
do
	local on, speed, autoRotate = false, 360, nil
	features.trSpin = {
		set = function(enabled, v)
			local hum = Util.humanoid()
			if enabled and not on and hum then
				autoRotate = hum.AutoRotate
			end
			on = enabled
			speed = lerp(90, 2160, v)
			if not enabled and hum and autoRotate ~= nil then
				hum.AutoRotate = autoRotate
				autoRotate = nil
			end
		end,
		step = function(dt)
			if not on then
				return
			end
			local root, hum = Util.root(), Util.humanoid()
			if root and hum then
				hum.AutoRotate = false
				root.CFrame = root.CFrame * CFrame.Angles(0, math.rad(speed) * dt, 0)
			end
		end,
	}
end

-- moonwalk: you face away from where you are walking
do
	local on, autoRotate = false, nil
	features.trMoon = {
		set = function(enabled)
			local hum = Util.humanoid()
			if enabled and not on and hum then
				autoRotate = hum.AutoRotate
			end
			on = enabled
			if not enabled and hum and autoRotate ~= nil then
				hum.AutoRotate = autoRotate
				autoRotate = nil
			end
		end,
		step = function()
			if not on then
				return
			end
			local root, hum = Util.root(), Util.humanoid()
			if not (root and hum) then
				return
			end
			hum.AutoRotate = false
			local m = hum.MoveDirection
			local flat = Vector3.new(m.X, 0, m.Z)
			if flat.Magnitude > 0.1 then
				root.CFrame = CFrame.lookAt(root.Position, root.Position - flat)
			end
		end,
	}
end

-- vibrate: small random shake, looks like lag from the outside
do
	local on, intensity, last = false, 0.5, Vector3.zero
	features.trVibe = {
		set = function(enabled, v)
			on = enabled
			intensity = lerp(0.1, 1.5, v)
			if not enabled then
				last = Vector3.zero
			end
		end,
		step = function()
			if not on then
				return
			end
			local root = Util.root()
			if not root then
				return
			end
			local nextOffset = Vector3.new((math.random() - 0.5) * intensity, 0, (math.random() - 0.5) * intensity)
			root.CFrame = root.CFrame - last + nextOffset -- undo the last shake first so you do not drift away
			last = nextOffset
		end,
	}
end

-- play dead: you fall over and stay down
do
	local on, cfg = false, {}
	local function standUp()
		local hum, root = Util.humanoid(), Util.root()
		if hum then
			hum.PlatformStand = false
		end
		if root then
			local _, yaw = root.CFrame:ToOrientation()
			root.CFrame = CFrame.new(root.Position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, yaw, 0)
		end
	end
	features.trDead = {
		set = function(enabled, _v, _c, o)
			local was = on
			on, cfg = enabled, o
			if was and not enabled then
				standUp()
			end
		end,
		step = function()
			if not on then
				return
			end
			local root, hum = Util.root(), Util.humanoid()
			if not (root and hum) then
				return
			end
			hum.PlatformStand = true
			local _, yaw = root.CFrame:ToOrientation()
			local tilt = math.rad(cfg.pose == "On face" and 90 or -90)
			root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(tilt, 0, 0)
		end,
	}
end

-- emote spam: plays an emote again every few seconds (needs the game to allow the default emotes)
do
	local on, cfg, acc, interval = false, {}, 0, 5
	features.trDance = {
		set = function(enabled, v, _c, o)
			on, cfg = enabled, o
			interval = lerp(2, 15, v)
			acc = interval -- plays right away
		end,
		step = function(dt)
			if not on then
				return
			end
			acc += dt
			if acc < interval then
				return
			end
			acc = 0
			local hum = Util.humanoid()
			if hum then
				pcall(function()
					hum:PlayEmote(cfg.emote or "dance")
				end)
			end
		end,
	}
end

---------------------------------------------------------------------
-- player pranks
---------------------------------------------------------------------

-- orbit: circle around the target
do
	local on, cfg, radius, angle = false, {}, 12, 0
	local get, reset = targeter()
	features.trOrbit = {
		set = function(enabled, v, _c, o)
			on, cfg, radius = enabled, o, lerp(3, 40, v)
			reset()
		end,
		step = function(dt)
			if not on then
				return
			end
			local root, plr = Util.root(), get(cfg.target)
			if not (root and plr) then
				return
			end
			local troot = Util.rootOf(plr.Character)
			angle += math.rad(cfg.speed or 120) * dt
			local pos = troot.Position + Vector3.new(math.cos(angle) * radius, cfg.height or 2, math.sin(angle) * radius)
			root.CFrame = CFrame.lookAt(pos, Vector3.new(troot.Position.X, pos.Y, troot.Position.Z))
			root.AssemblyLinearVelocity = Vector3.zero
		end,
	}
end

-- head sit: park yourself on the target's head
do
	local on, cfg, lift = false, {}, 0
	local get, reset = targeter()
	features.trHead = {
		set = function(enabled, v, _c, o)
			on, cfg, lift = enabled, o, lerp(0, 6, v)
			reset()
		end,
		step = function()
			if not on then
				return
			end
			local root, plr = Util.root(), get(cfg.target)
			if not (root and plr) then
				return
			end
			local char = plr.Character
			local head = char:FindFirstChild("Head") or Util.rootOf(char)
			local rot = head.CFrame - head.CFrame.Position
			root.CFrame = CFrame.new(head.Position + Vector3.new(0, head.Size.Y / 2 + 2.5 + lift, 0)) * rot
			root.AssemblyLinearVelocity = Vector3.zero
		end,
	}
end

-- shadow: walks after the target and stops at the keep-distance
do
	local on, cfg, gap = false, {}, 10
	local get, reset = targeter()
	features.trFollow = {
		set = function(enabled, v, _c, o)
			on, cfg, gap = enabled, o, lerp(3, 25, v)
			reset()
		end,
		step = function()
			if not on then
				return
			end
			local root, hum, plr = Util.root(), Util.humanoid(), get(cfg.target)
			if not (root and hum and plr) then
				return
			end
			local troot = Util.rootOf(plr.Character)
			local d = troot.Position - root.Position
			local flat = Vector3.new(d.X, 0, d.Z).Magnitude
			hum:MoveTo(flat > gap and troot.Position or root.Position)
		end,
	}
end

-- spectate: your camera watches the target, goes back to you when turned off
do
	local on, cfg = false, {}
	local get, reset = targeter()
	local function restore()
		local cam, hum = workspace.CurrentCamera, Util.humanoid()
		if cam and hum then
			cam.CameraSubject = hum
		end
	end
	features.trSpec = {
		set = function(enabled, _v, _c, o)
			on, cfg = enabled, o
			reset()
			if not enabled then
				restore()
			end
		end,
		step = function()
			if not on then
				return
			end
			local cam, plr = workspace.CurrentCamera, get(cfg.target)
			local hum = plr and Util.humanoid(plr.Character)
			if cam and hum then
				if cam.CameraSubject ~= hum then
					cam.CameraSubject = hum
				end
			else
				restore()
			end
		end,
		destroy = restore,
	}
end

return Troll
