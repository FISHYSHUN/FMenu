-- ModuleScript: Vehicle
-- Controller for whatever you are driving. Detection is automatic: when your humanoid sits in an unanchored
-- seat (VehicleSeat or a plain Seat of a custom car) that seat's assembly is "the vehicle". Stand up and
-- everything idles; sit in another car and it follows you there.
--
--   Vehicle.tab       the tab definition, picked up by Games.lua
--   Vehicle.features  merged into Functionality's registry
--
-- How it works: while you sit, you own the car's physics, so the controller writes the assembly's velocity /
-- angular velocity once per physics step (RunService.Stepped, before physics runs). It reads your input from
-- the seat (ThrottleFloat / SteerFloat) or from W A S D / arrows when the game uses a custom chassis.
-- Games with their own anti-cheat or server-driven cars can still override or rubber-band this, and "forward"
-- is taken from the seat's LookVector, so cars whose seat is rotated oddly will handle oddly.
--
--   Top speed   raises the speed ceiling (VehicleSeat.MaxSpeed + extra push along the car's heading)
--   Nitro       hold a key for extra forward acceleration
--   Drift       velocity direction lags behind the car's heading, so it slides; slider = how long it slides
--   Steering    sets the yaw rate directly (turn rate, less at speed)
--   Brake       hold a key to shed speed fast
--   Stability   downforce + anti-roll
--   Auto-flip   rights the car when it is upside down (plus an optional instant flip key)
--   Car jump    hop key
--   Stay seated stops Space from throwing you out of the seat
-- Rows with a Mode option scale their power by the cheat level (Blatant / Semi / Legit, see Config).

local import = ...
local Util = import("Util")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local lerp, range = Util.lerp, Util.range

local Vehicle = { features = {} }
local features = Vehicle.features

local MODE = Util.modeOption()
local function keyChoice(label, choices, default)
	return { type = "choice", key = "key", label = label, choices = choices, default = default }
end

Vehicle.tab = { name = "Vehicle", rows = {
	{ header = "Info" },
	{ id = "vhInfo", label = "Vehicle info", slider = "Unused", value = 0, on = false, opts = {
		{ type = "choice", key = "unit", label = "Speed unit", choices = { "st/s", "km/h", "mph" }, default = "st/s" },
	} },
	{ header = "Power" },
	{ id = "vhSpeed", label = "Top speed", slider = "Top speed", value = 40, on = false, fmt = range(60, 600, " st/s"), opts = {
		MODE,
		{ type = "slider", key = "accel", label = "Acceleration", min = 20, max = 400, step = 10, unit = " st/s2", default = 120 },
	} },
	{ id = "vhBoost", label = "Nitro", slider = "Boost power", value = 40, on = false, fmt = range(30, 400, " st/s2"), opts = {
		MODE,
		keyChoice("Hold key", { "E", "Q", "Shift", "Ctrl", "Alt" }, "E"),
		{ type = "slider", key = "cap", label = "Max boost speed", min = 100, max = 800, step = 10, unit = " st/s", default = 450 },
	} },
	{ header = "Handling" },
	{ id = "vhDrift", label = "Drift", slider = "Drift amount", value = 60, on = false, fmt = range(0, 100, "%"), opts = {
		{ type = "choice", key = "trigger", label = "Drift while holding", choices = { "Always", "Shift", "Ctrl", "Alt", "E", "Q" }, default = "Shift" },
		{ type = "toggle", key = "keep", label = "Hold speed while sliding", default = true },
	} },
	{ id = "vhSteer", label = "Steering", slider = "Turn rate", value = 50, on = false, fmt = range(30, 240, " deg/s"), opts = {
		{ type = "slider", key = "reduce", label = "Less turning at speed", min = 0, max = 1, step = 0.05, pct = true, default = 0.4 },
	} },
	{ id = "vhBrake", label = "Brake", slider = "Brake strength", value = 50, on = false, fmt = range(2, 12, "x"), opts = {
		keyChoice("Hold key", { "Ctrl", "Shift", "Alt", "E", "Q" }, "Ctrl"),
	} },
	{ header = "Stability & tricks" },
	{ id = "vhStable", label = "Stability", slider = "Downforce", value = 40, on = false, fmt = range(0, 150, " st/s2"), opts = {
		{ type = "slider", key = "roll", label = "Anti-roll", min = 0, max = 1, step = 0.05, pct = true, default = 0.5 },
	} },
	{ id = "vhFlip", label = "Auto-flip", slider = "Flip after", value = 20, on = false, fmt = function(v) return ("%.1fs"):format(lerp(0.2, 3, v)) end, opts = {
		keyChoice("Instant flip key", { "Off", "R", "T", "Y" }, "R"),
	} },
	{ id = "vhJump", label = "Car jump", slider = "Jump power", value = 40, on = false, fmt = range(20, 120, " st/s"), opts = {
		MODE,
		keyChoice("Jump key", { "F", "G", "X", "Z", "Q" }, "F"),
	} },
	{ id = "vhLock", label = "Stay seated", slider = "Unused", value = 0, on = false },
} }

---------------------------------------------------------------------
-- detection + input
---------------------------------------------------------------------
local function typing()
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function keyDown(name)
	if typing() then
		return false
	end
	local k = UserInputService
	if name == "Shift" then
		return k:IsKeyDown(Enum.KeyCode.LeftShift) or k:IsKeyDown(Enum.KeyCode.RightShift)
	elseif name == "Ctrl" then
		return k:IsKeyDown(Enum.KeyCode.LeftControl) or k:IsKeyDown(Enum.KeyCode.RightControl)
	elseif name == "Alt" then
		return k:IsKeyDown(Enum.KeyCode.LeftAlt) or k:IsKeyDown(Enum.KeyCode.RightAlt)
	end
	local code = Enum.KeyCode[name]
	return code ~= nil and k:IsKeyDown(code)
end

-- the car you are sitting in, or nil
local function current()
	local hum = Util.humanoid()
	local seat = hum and hum.SeatPart
	if not seat then
		return nil
	end
	local part = seat.AssemblyRootPart or seat
	if part.Anchored then
		return nil -- a bench or a chair bolted to the map
	end
	return { seat = seat, part = part, hum = hum, model = seat:FindFirstAncestorOfClass("Model") }
end

local function flatten(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- forward as a flat unit vector (nil if the seat looks straight up / down)
local function forwardOf(car)
	local f = flatten(car.seat.CFrame.LookVector)
	if f.Magnitude < 0.05 then
		return nil
	end
	return f.Unit
end

local function throttleOf(seat)
	if seat:IsA("VehicleSeat") and seat.ThrottleFloat ~= 0 then
		return seat.ThrottleFloat
	end
	local t = 0
	if keyDown("W") or keyDown("Up") then
		t += 1
	end
	if keyDown("S") or keyDown("Down") then
		t -= 1
	end
	return t
end

local function steerOf(seat)
	if seat:IsA("VehicleSeat") and seat.SteerFloat ~= 0 then
		return seat.SteerFloat
	end
	local s = 0
	if keyDown("D") or keyDown("Right") then
		s += 1
	end
	if keyDown("A") or keyDown("Left") then
		s -= 1
	end
	return s
end

-- VehicleSeat properties we change are put back when the feature goes off
local savedProps = setmetatable({}, { __mode = "k" })
local function setProp(seat, prop, value)
	local saved = savedProps[seat]
	if not saved then
		saved = {}
		savedProps[seat] = saved
	end
	if saved[prop] == nil then
		saved[prop] = seat[prop]
	end
	if seat[prop] ~= value then
		seat[prop] = value
	end
end

local function restoreProps()
	for seat, saved in pairs(savedProps) do
		if seat.Parent then
			for prop, value in pairs(saved) do
				seat[prop] = value
			end
		end
		savedProps[seat] = nil
	end
end

---------------------------------------------------------------------
-- state + one physics loop for everything
---------------------------------------------------------------------
-- every controller: on, v (0..1 slider), cfg (live option table) and its own scratch values
local S = {
	speed = { on = false, v = 0, cfg = {} },
	boost = { on = false, v = 0, cfg = {} },
	drift = { on = false, v = 0, cfg = {}, dir = nil, lastSpeed = 0 },
	steer = { on = false, v = 0, cfg = {} },
	brake = { on = false, v = 0, cfg = {} },
	stable = { on = false, v = 0, cfg = {} },
	flip = { on = false, v = 0, cfg = {}, since = nil, cooldown = 0 },
	jump = { on = false, v = 0, cfg = {}, held = false },
	lock = { on = false, hum = nil },
}

local conn = nil

local function doLock(car)
	local s = S.lock
	s.hum = car.hum
	car.hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	if car.hum.Jump then
		car.hum.Jump = false
	end
end

local function unlock()
	local s = S.lock
	if s.hum then
		pcall(function()
			s.hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end)
		s.hum = nil
	end
end

local function doSpeed(car, dt)
	local s = S.speed
	local L = Util.level(s.cfg.mode)
	local top = lerp(60, 600, s.v * 100)
	local limit = 60 + (top - 60) * L.power
	if car.seat:IsA("VehicleSeat") then
		setProp(car.seat, "MaxSpeed", limit)
	end
	local throttle = throttleOf(car.seat)
	local fwd = forwardOf(car)
	if throttle == 0 or not fwd then
		return
	end
	local dir = fwd * (throttle > 0 and 1 or -1)
	local vel = car.part.AssemblyLinearVelocity
	local along = vel:Dot(dir)
	if along < limit then
		local add = math.min((s.cfg.accel or 120) * L.power * dt, limit - along)
		car.part.AssemblyLinearVelocity = vel + dir * add
	end
end

local function doBoost(car, dt)
	local s = S.boost
	if not keyDown(s.cfg.key or "E") then
		return
	end
	local fwd = forwardOf(car)
	if not fwd then
		return
	end
	local L = Util.level(s.cfg.mode)
	local power = lerp(30, 400, s.v * 100) * L.power
	local vel = car.part.AssemblyLinearVelocity
	if vel:Dot(fwd) < (s.cfg.cap or 450) then
		car.part.AssemblyLinearVelocity = vel + fwd * power * dt
	end
end

-- Drift: the car's own physics keeps pulling its velocity toward its heading (grip). Here the direction we
-- last set is remembered and only slowly rotated toward the heading, so the car keeps sliding the way it was going.
local function doDrift(car, dt)
	local s = S.drift
	local trigger = s.cfg.trigger or "Shift"
	local vel = car.part.AssemblyLinearVelocity
	local horiz = flatten(vel)
	local speed = horiz.Magnitude
	local fwd = forwardOf(car)
	if (trigger ~= "Always" and not keyDown(trigger)) or speed < 8 or not fwd then
		s.dir, s.lastSpeed = nil, speed
		return
	end
	local heading = fwd * (horiz:Dot(fwd) >= 0 and 1 or -1)
	local base = s.dir or horiz.Unit
	local rate = lerp(24, 0.8, s.v * 100) -- 0 = tight grip, 100 = long slides
	local dir = base:Lerp(heading, 1 - math.exp(-dt * rate))
	if dir.Magnitude < 0.01 then
		return
	end
	dir = dir.Unit
	local sp = speed
	if s.cfg.keep ~= false and throttleOf(car.seat) >= 0 then
		sp = math.max(speed, s.lastSpeed - 12 * dt) -- sideways scrub does not eat all your speed
	end
	s.dir, s.lastSpeed = dir, sp
	car.part.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0) + dir * sp
end

local function doSteer(car, dt)
	local s = S.steer
	local input = steerOf(car.seat)
	if math.abs(input) < 0.1 then
		return
	end
	local vel = car.part.AssemblyLinearVelocity
	local fwd = forwardOf(car)
	local speed = flatten(vel).Magnitude
	if speed < 3 or not fwd then
		return
	end
	local reverse = flatten(vel):Dot(fwd) < 0 and -1 or 1
	local factor = 1 - (s.cfg.reduce or 0.4) * math.min(1, speed / 200)
	local rate = math.rad(lerp(30, 240, s.v * 100)) * factor
	local ang = car.part.AssemblyAngularVelocity
	-- positive Y spins counter-clockwise (a left turn), so steering right is negative
	car.part.AssemblyAngularVelocity = Vector3.new(ang.X, -input * rate * reverse, ang.Z)
end

local function doBrake(car, dt)
	local s = S.brake
	if not keyDown(s.cfg.key or "Ctrl") then
		return
	end
	local vel = car.part.AssemblyLinearVelocity
	local k = lerp(2, 12, s.v * 100)
	car.part.AssemblyLinearVelocity = vel:Lerp(Vector3.new(0, vel.Y, 0), 1 - math.exp(-dt * k))
end

local function doStable(car, dt)
	local s = S.stable
	local vel = car.part.AssemblyLinearVelocity
	local speed = flatten(vel).Magnitude
	local down = lerp(0, 150, s.v * 100) * math.min(1, speed / 100)
	if down > 0 then
		car.part.AssemblyLinearVelocity = vel - Vector3.new(0, down * dt, 0)
	end
	local roll = s.cfg.roll or 0.5
	if roll > 0 then
		local cf = car.seat.CFrame
		local a = cf:VectorToObjectSpace(car.part.AssemblyAngularVelocity)
		-- local X = pitch, Z = roll, Y = yaw (the turn). Only pitch and roll are damped.
		local damp = 1 - math.clamp(roll * dt * 8, 0, 1)
		car.part.AssemblyAngularVelocity = cf:VectorToWorldSpace(Vector3.new(a.X * damp, a.Y, a.Z * damp))
	end
end

local function flipUp(car)
	local cf = car.seat.CFrame
	local look = forwardOf(car) or Vector3.new(0, 0, -1)
	local pos = cf.Position + Vector3.new(0, 4, 0)
	local target = CFrame.lookAt(pos, pos + look)
	car.part.CFrame = target * cf:ToObjectSpace(car.part.CFrame)
	car.part.AssemblyLinearVelocity = Vector3.zero
	car.part.AssemblyAngularVelocity = Vector3.zero
end

local function doFlip(car, dt)
	local s = S.flip
	local now = os.clock()
	local key = s.cfg.key or "R"
	if key ~= "Off" and keyDown(key) and now > s.cooldown then
		s.cooldown = now + 0.6
		flipUp(car)
		return
	end
	if car.seat.CFrame.UpVector.Y < 0.3 then
		s.since = s.since or now
		if now - s.since >= lerp(0.2, 3, s.v * 100) and now > s.cooldown then
			s.cooldown = now + 0.6
			s.since = nil
			flipUp(car)
		end
	else
		s.since = nil
	end
end

local function doJump(car)
	local s = S.jump
	local down = keyDown(s.cfg.key or "F")
	if down and not s.held then
		local L = Util.level(s.cfg.mode)
		local vel = car.part.AssemblyLinearVelocity
		car.part.AssemblyLinearVelocity = Vector3.new(vel.X, vel.Y + lerp(20, 120, s.v * 100) * L.power, vel.Z)
	end
	s.held = down
end

local function resetScratch()
	S.drift.dir, S.drift.lastSpeed = nil, 0
	S.flip.since = nil
end

local function onStepped(_, dt)
	local car = current()
	if not car then
		resetScratch()
		unlock()
		return
	end
	if S.lock.on then
		doLock(car)
	end
	if S.steer.on then
		doSteer(car, dt)
	end
	if S.drift.on then
		doDrift(car, dt)
	end
	if S.speed.on then
		doSpeed(car, dt)
	end
	if S.boost.on then
		doBoost(car, dt)
	end
	if S.brake.on then
		doBrake(car, dt)
	end
	if S.stable.on then
		doStable(car, dt)
	end
	if S.flip.on then
		doFlip(car, dt)
	end
	if S.jump.on then
		doJump(car)
	end
end

local function refresh()
	local need = false
	for _, s in pairs(S) do
		if s.on then
			need = true
		end
	end
	if need and not conn then
		conn = RunService.Stepped:Connect(onStepped)
	elseif not need and conn then
		conn:Disconnect()
		conn = nil
	end
	if not S.speed.on then
		restoreProps()
	end
	if not S.lock.on then
		unlock()
	end
	if not S.drift.on then
		resetScratch()
	end
end

local function shutdown()
	for _, s in pairs(S) do
		s.on = false
	end
	refresh()
end

local function controller(id, key)
	features[id] = {
		set = function(on, v, _c, o)
			local s = S[key]
			s.on, s.v, s.cfg = on, v / 100, o
			refresh()
		end,
		destroy = shutdown,
	}
end

controller("vhSpeed", "speed")
controller("vhBoost", "boost")
controller("vhDrift", "drift")
controller("vhSteer", "steer")
controller("vhBrake", "brake")
controller("vhStable", "stable")
controller("vhFlip", "flip")
controller("vhJump", "jump")
controller("vhLock", "lock")

---------------------------------------------------------------------
-- info readout (draggable)
---------------------------------------------------------------------
do
	local label, enabled, acc, cfg = nil, false, 0, {}
	local WHITE = Color3.fromRGB(236, 238, 244)
	local FACTOR = { ["st/s"] = 1, ["km/h"] = 1.008, mph = 0.626 } -- 1 stud is about 0.28 m
	features.vhInfo = {
		init = function(ctx)
			label = ctx.hudLabel("VehicleInfo", WHITE, Enum.Font.GothamBold)
			ctx.draggable(label, "VehicleInfo", "left", 1)
		end,
		set = function(on, _v, _c, o)
			enabled, cfg = on, o
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
			local car = current()
			if not car then
				label.Text = "vehicle: --"
				return
			end
			local unit = cfg.unit or "st/s"
			local speed = car.part.AssemblyLinearVelocity.Magnitude * (FACTOR[unit] or 1)
			local name = car.model and car.model.Name or car.seat.Name
			label.Text = ("%s  %d %s"):format(name:sub(1, 24), math.floor(speed + 0.5), unit)
		end,
	}
end

return Vehicle
