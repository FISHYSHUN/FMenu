-- ModuleScript: Defense
-- Protection from other players' cheats. Everything here is CLIENT SIDE: it changes what your own game
-- does about other players (collisions, your own velocity, warnings). It cannot kick or ban anyone, and
-- the detectors are heuristics: vehicles, game dashes, round teleports and fast flicks can look like cheating,
-- so treat a flag as "worth a look", not proof.
--
--   antifling / nocollide / stabilize   share one Stepped loop (runs before physics, every frame)
--   detMove / detSpin / detAim          detectors, all scanned from detMove's step
--   flagEsp                             orange markers on flagged players
--
-- features = { id = { init?, set, step?, destroy? } }, merged into Functionality's registry.

local import = ...
local Util = import("Util")
local ESP = import("ESP")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
local lerp = Util.lerp

local ORANGE = Color3.fromRGB(255, 160, 50)

local Defense = { features = {} }
local features = Defense.features

---------------------------------------------------------------------
-- flags: who looked like a cheater, and why (expire after FLAG_SECONDS without a new strike)
---------------------------------------------------------------------
local FLAG_SECONDS = 30
local flagged = {} -- plr -> { reasons = { [reason] = expiresAt } }
local lastAlert = {} -- plr -> { [reason] = time }

local function flag(plr, reason, ctx)
	local now = os.clock()
	local f = flagged[plr]
	if not f then
		f = { reasons = {} }
		flagged[plr] = f
	end
	f.reasons[reason] = now + FLAG_SECONDS
	local la = lastAlert[plr]
	if not la then
		la = {}
		lastAlert[plr] = la
	end
	if not la[reason] or now - la[reason] > 15 then
		la[reason] = now
		ctx.notify(("%s: %s"):format(plr.DisplayName, reason), ORANGE)
	end
end

-- "fly, speed" or nil when nothing (still) flagged
local function reasonsOf(plr)
	local f = flagged[plr]
	if not f then
		return nil
	end
	local now, list = os.clock(), {}
	for reason, expires in pairs(f.reasons) do
		if expires < now then
			f.reasons[reason] = nil
		else
			list[#list + 1] = reason
		end
	end
	if #list == 0 then
		flagged[plr] = nil
		return nil
	end
	table.sort(list)
	return table.concat(list, ", ")
end

---------------------------------------------------------------------
-- anti-fling, no collision, stabilizer
---------------------------------------------------------------------
-- A flinger spins / rockets their character into you. Collisions are decided by BOTH parts being
-- CanCollide, so turning their parts off locally means they pass through you on your screen and the
-- push never happens. Roblox re-enables character parts all the time, hence the per frame loop.
local col = { all = false, fling = false, thr = 176, stab = false, cap = 118 }
local stepConn = nil
local dangerUntil = {} -- plr -> time until which they count as dangerous
local records = setmetatable({}, { __mode = "k" }) -- char -> { orig = { part = CanCollide }, list = {}, t }

local function applyCollide(char, want, now)
	local rec = records[char]
	if want then
		if not rec then
			rec = { orig = {}, list = {}, t = -1 }
			records[char] = rec
		end
		if now - rec.t > 1 then -- re-scan now and then so tools / accessories are picked up
			rec.t = now
			table.clear(rec.list)
			for _, d in ipairs(char:GetDescendants()) do
				if d:IsA("BasePart") then
					rec.list[#rec.list + 1] = d
					if rec.orig[d] == nil then
						rec.orig[d] = d.CanCollide
					end
				end
			end
		end
		for _, p in ipairs(rec.list) do
			if p.CanCollide then
				p.CanCollide = false
			end
		end
	elseif rec then
		for part, orig in pairs(rec.orig) do
			if part.Parent then
				part.CanCollide = orig
			end
		end
		records[char] = nil
	end
end

local function restoreAll()
	for char in pairs(records) do
		applyCollide(char, false, 0)
	end
end

local function onStepped()
	local now = os.clock()
	local myRoot = Util.root()
	local dangerNear = false

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			local char = plr.Character
			local root = Util.rootOf(char)
			if root then
				if col.fling then
					local lin = root.AssemblyLinearVelocity.Magnitude
					local ang = root.AssemblyAngularVelocity.Magnitude
					if lin > col.thr or ang > 25 then
						dangerUntil[plr] = now + 3 -- stays "dangerous" a moment after they slow down
					end
				end
				local dangerous = (dangerUntil[plr] or 0) > now
				if dangerous and myRoot and (root.Position - myRoot.Position).Magnitude < 30 then
					dangerNear = true
				end
				applyCollide(char, col.all or dangerous, now)
			end
		end
	end

	-- stabilizer: your own spin is always cut, your speed only while a dangerous player is close
	if col.stab and myRoot then
		if myRoot.AssemblyAngularVelocity.Magnitude > 25 then
			myRoot.AssemblyAngularVelocity = Vector3.zero
		end
		if dangerNear then
			local v = myRoot.AssemblyLinearVelocity
			if v.Magnitude > col.cap then
				myRoot.AssemblyLinearVelocity = v.Unit * col.cap
			end
		end
	end
end

local function refresh()
	local need = col.all or col.fling or col.stab
	if need and not stepConn then
		stepConn = RunService.Stepped:Connect(onStepped)
	elseif not need and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	if not (col.all or col.fling) then
		restoreAll()
	end
end

local function shutdown()
	col.all, col.fling, col.stab = false, false, false
	refresh()
end

features.antifling = {
	set = function(on, v)
		col.fling = on
		col.thr = lerp(80, 400, v)
		refresh()
	end,
	destroy = shutdown,
}
features.nocollide = {
	set = function(on)
		col.all = on
		refresh()
	end,
	destroy = shutdown,
}
features.stabilize = {
	set = function(on, v)
		col.stab = on
		col.cap = lerp(40, 300, v)
		refresh()
	end,
	destroy = shutdown,
}

---------------------------------------------------------------------
-- detection
---------------------------------------------------------------------
local det = { move = false, spin = false, aim = false, moveSens = 50, spinSens = 50, aimSens = 50 }
local samples = {} -- plr -> per player running numbers
local acc = 0

local function sampleOf(plr)
	local s = samples[plr]
	if not s then
		s = {}
		samples[plr] = s
	end
	return s
end

-- speed / teleport / fly, and spin / fling, from position and velocity samples every 0.1 s
local function scanMotion(plr, s, now, ctx)
	local char = plr.Character
	local root, hum = Util.rootOf(char), char and char:FindFirstChildOfClass("Humanoid")
	if not (root and hum and hum.Health > 0) then
		s.pos, s.air, s.fast, s.spin = nil, 0, 0, 0
		return
	end

	if det.move then
		local sens = det.moveSens / 100
		if s.pos and s.char == char then
			local dt = now - s.t
			local delta = root.Position - s.pos
			if dt > 0 and dt < 0.5 then
				local horiz = Vector3.new(delta.X, 0, delta.Z).Magnitude / dt
				local limit = math.max(hum.WalkSpeed, 16) * lerp(2.4, 1.4, sens * 100) + 12
				if horiz > limit and hum.SeatPart == nil then
					s.fast = (s.fast or 0) + 1
				else
					s.fast = 0
				end
				if s.fast >= 3 then
					flag(plr, "speed", ctx)
				end

				-- teleport: a big jump in one tick; needs a second one within 20 s so round starts do not count
				if delta.Magnitude > lerp(150, 60, sens * 100) and dt < 0.3 then
					if s.lastTp and now - s.lastTp < 20 then
						flag(plr, "teleport", ctx)
					end
					s.lastTp = now
				end

				-- fly: in the air for seconds with almost no vertical speed, not seated / climbing / swimming
				local state = hum:GetState()
				local floating = hum.FloorMaterial == Enum.Material.Air
					and math.abs(root.AssemblyLinearVelocity.Y) < 4
					and hum.SeatPart == nil
					and state ~= Enum.HumanoidStateType.Climbing
					and state ~= Enum.HumanoidStateType.Swimming
				s.air = floating and ((s.air or 0) + dt) or 0
				if s.air > lerp(5, 2.5, sens * 100) then
					flag(plr, "fly", ctx)
				end
			end
		end
	end

	if det.spin then
		local sens = det.spinSens
		local ang = root.AssemblyAngularVelocity.Magnitude
		local lin = root.AssemblyLinearVelocity.Magnitude
		if ang > lerp(60, 20, sens) or (lin > lerp(300, 120, sens) and ang > 10) then
			s.spin = (s.spin or 0) + 1
		else
			s.spin = 0
		end
		if s.spin >= 3 then
			flag(plr, lin > lerp(300, 120, sens) and "fling" or "spin", ctx)
		end
	end

	s.pos, s.t, s.char = root.Position, now, char
end

-- aim snap: their body turns from clearly away to dead on YOU within one frame, again and again.
-- Needs several snaps inside 30 s before it flags, a single quick flick is normal.
local function scanAim(plr, s, now, myRoot, ctx)
	local root = Util.rootOf(plr.Character)
	if not root or not Util.isAlive(plr.Character) then
		s.prevAngle = nil
		return
	end
	local to = myRoot.Position - root.Position
	local flat = Vector3.new(to.X, 0, to.Z)
	local look = root.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 5 or flat.Magnitude > 250 or look.Magnitude < 0.01 then
		s.prevAngle = nil
		return
	end
	local angle = math.deg(math.acos(math.clamp(look.Unit:Dot(flat.Unit), -1, 1)))
	local sens = det.aimSens
	if s.prevAngle and s.prevT and now - s.prevT < 0.1 and s.prevAngle > lerp(40, 15, sens) and angle < 4 then
		s.snaps = s.snaps or {}
		s.snaps[#s.snaps + 1] = now
	end
	s.prevAngle, s.prevT = angle, now
	if s.snaps then
		for i = #s.snaps, 1, -1 do
			if now - s.snaps[i] > 30 then
				table.remove(s.snaps, i)
			end
		end
		if #s.snaps >= math.floor(lerp(5, 2, sens) + 0.5) then
			flag(plr, "aim snap", ctx)
			s.snaps = {}
		end
	end
end

features.detSpin = {
	set = function(on, v)
		det.spin = on
		det.spinSens = v
	end,
}
features.detAim = {
	set = function(on, v)
		det.aim = on
		det.aimSens = v
	end,
}
-- detMove owns the scan loop for all three (a feature's step runs every frame whether it is on or not)
features.detMove = {
	set = function(on, v)
		det.move = on
		det.moveSens = v
	end,
	step = function(dt, ctx)
		if not (det.move or det.spin or det.aim) then
			return
		end
		local now = os.clock()
		acc += dt
		local motionTick = acc >= 0.1
		if motionTick then
			acc = 0
		end
		local myRoot = det.aim and Util.root() or nil
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local s = sampleOf(plr)
				if motionTick then
					scanMotion(plr, s, now, ctx)
				end
				if myRoot and Util.isAlive(lp.Character) then
					scanAim(plr, s, now, myRoot, ctx)
				end
			end
		end
		for plr in pairs(samples) do
			if plr.Parent == nil then
				samples[plr], flagged[plr], lastAlert[plr], dangerUntil[plr] = nil, nil, nil, nil
			end
		end
	end,
	destroy = function()
		det.move, det.spin, det.aim = false, false, false
		table.clear(samples)
		table.clear(flagged)
	end,
}

-- flag markers: orange tag + highlight on everyone currently flagged
do
	local esp
	features.flagEsp = {
		init = function()
			esp = ESP.new({
				maxDistance = 5000,
				resolve = function(plr, _char, _dist)
					local reasons = reasonsOf(plr)
					if reasons then
						return ORANGE, ("! %s [%s]"):format(plr.DisplayName, reasons)
					end
					return nil
				end,
			})
		end,
		set = function(on)
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

return Defense
