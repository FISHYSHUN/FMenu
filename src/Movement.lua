-- ModuleScript: Movement
-- Parkour for your own character: sprint, wall run, wall jump, wall hop, ledge hang and mantle, each with a
-- body animation. Everything is client side: it moves YOUR character, other players see it because the
-- server replicates your position.
--
--   Movement.tab       the "Parkour" tab (rows + right-click options), picked up by Games.lua
--   Movement.features  { id = { set, step, ... } }, merged into Functionality's registry
--
-- How it works
--   One controller (pkCore) runs every frame and owns a tiny state machine: none / run / hang / mantle / launch.
--   The six rows only switch capabilities on and off and carry their settings, they hold no logic of their own.
--   Inputs: UserInputService.JumpRequest (keyboard, gamepad and the mobile jump button) plus the humanoid's
--   MoveDirection, so there are no fixed keys except the sprint key and Left Control (let go of a ledge).
--
--   sprint     WalkSpeed while the sprint key is held and you are moving. Raises speed, never lowers it. If the
--              Speed row is also on, the two fight over WalkSpeed.
--   wall run   airborne + moving along a wall on your left or right: gravity is cancelled and you run along it
--              for the max time. Jump while running = wall jump.
--   wall jump  jump while airborne next to a wall: kicks you away from it. Limited per air time.
--   wall hop   jump while airborne and FACING a wall: a small upward hop that keeps you on the wall. Limited per
--              air time. Wins over the wall jump when you face the wall.
--   hang       falling at a ledge: grabs it and holds you there. Jump (or hold forward, option) = mantle up,
--              hold back or Left Control = drop.
--   mantle     pulls you up to chest height on the ledge, then pops you into the air with an upward velocity
--              (sized from workspace.Gravity) and pushes you forward once your feet clear the ledge, so you
--              hop onto the surface instead of sliding onto it. State "launch" covers that last bit.
--
-- Animations: the character's Motor6D C0 values are offset by smoothed angles, which the Animator never
-- overwrites. Sprint is added on top of the game's run animation; wall run, hang, mantle and the kick / hop
-- poses stop the game's animation tracks and pose the body themselves. R15 only (R6 characters still get the
-- movement, just no pose).
-- The pose angles are written from the R15 rig's joint axes (arms forward = +X, torso forward lean = -X,
-- knees bend = -X) and were NOT tested on a live character: if a limb swings the wrong way, flip the sign in
-- the pose function (sprintPose / runPose / hangPose / mantlePose / kickPose / hopPose).
--
-- Extra poses (Parkour animations row): "leap" while sprinting through the air and a "landing" crouch after a
-- hard fall (scaled by impact speed). Both are layered on top of the game's own animation instead of replacing
-- it, so walking / running keeps animating. Each has its own toggle in the row's right-click menu.
--
-- Hand + foot IK (Parkour animations > "Hands reach ledge / wall"): while hanging both hands are placed on the
-- ledge top, while mantling they stay planted until the body is up, a wall hop slaps both hands on the wall.
-- While wall running the wall-side hand presses on the wall and slides with the stride, and BOTH feet step on
-- the wall: the planted foot sits on the wall surface, the swinging foot lifts off and moves forward. Legs use
-- the same solver as the arms (thigh / shin lengths measured from the rig, knee points forward and away from
-- the wall). The hang height comes from the rig's own arm length.
-- Ledge shimmy: while hanging, A / D (the sideways part of the move input) moves you along the ledge with the
-- hands going over each other. It stops at the end of the ledge (no corner wrapping). Hand spread is a slider.
-- R6 characters: the hands reach ledges and walls too (shoulders only), the body poses and leg IK stay R15 only.
-- Run styles (Sprint row): Pump, Sprinter (90 degree elbows, high knees) and Ninja (arms swept back), with stride,
-- torso twist, lean, pump and cadence sliders. Wall run also tilts the BODY away from the wall (Body tilt slider),
-- separate from the camera tilt.
-- Custom animation ID: the "Custom wall run animation ID" row takes one id (numbers only) for the wall run. A
-- loaded track replaces the procedural wall run pose. Roblox only lets a game play animations that its owner
-- owns (or Roblox itself published), so most marketplace ids from other creators will not load; the menu then
-- falls back to the procedural pose and says so after 2 s.
--
-- Anchoring: while hanging and mantling the root part is Anchored (released when you drop, the mantle pops you
-- up, the row is turned off or the menu is destroyed). Games with movement anti-cheat may rubber-band any of this.

local import = ...
local Util = import("Util")

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
local lerp = Util.lerp

local Movement = { features = {} }
local features = Movement.features

local UP = Vector3.new(0, 1, 0)
local V3 = Vector3.new
local REACH = 3.2 -- studs from the root part to a wall that still counts as touching it
local GRAB_REACH = 3.4 -- how far ahead a ledge is looked for
local RUN_MIN_SPEED = 8 -- horizontal speed needed to start a wall run
local HANG_OFF = 0.8 -- studs between the wall and the root part while hanging
local COOLDOWN = 0.35 -- seconds before a wall can be used again after a wall run / jump
local CAM_BIND = "FMenuParkourCam"
local MANTLE_PULL = 0.35 -- seconds of the scripted pull up before the mantle pops you into the air
local MANTLE_FWD = 12 -- studs/s pushed toward the ledge once the feet have cleared it
-- true  = the root part is Anchored while hanging / mantling (stable, but a client can't replicate an anchored part,
--         so other players may see you frozen until you let go).
-- false = nothing is anchored: velocity is zeroed and the CFrame re-set every frame instead (replicates normally,
--         may jitter slightly). Flip this if people report you "freezing" on ledges.
local ANCHOR_HOLD = true
-- true = a small blue notification the first time a pose kind kicks in (kind, joints found, pose strength, anim row on/off).
-- If you configure a style and see no such notice, the pose is not being selected; if you see it with joints < 10,
-- the rig is incomplete; if strength is 0.00, the Pose strength slider is at 0 or the anim row is off.
local DEBUG = true

local KEYS = {
	["Left Shift"] = Enum.KeyCode.LeftShift,
	["Left Control"] = Enum.KeyCode.LeftControl,
	Q = Enum.KeyCode.Q,
}

---------------------------------------------------------------------
-- tab
---------------------------------------------------------------------
Movement.tab = { name = "Parkour", rows = {
	{ header = "Sprint" },
	{ id = "pkSprint", label = "Sprint", slider = "Sprint speed", value = 40, on = false, fmt = Util.range(16, 60, " sp"), opts = {
		{ type = "choice", key = "key", label = "Sprint key", choices = { "Left Shift", "Left Control", "Q", "Always" }, default = "Left Shift" },
		{ type = "slider", key = "lean", label = "Forward lean", min = 0, max = 1.5, step = 0.05, pct = true, default = 1 },
		{ type = "slider", key = "pump", label = "Arm / leg pump", min = 0, max = 1.5, step = 0.05, pct = true, default = 1 },
		{ type = "choice", key = "style", label = "Run style", choices = { "Pump", "Sprinter", "Ninja" }, default = "Pump" },
		{ type = "slider", key = "stride", label = "Stride length", min = 0, max = 1.5, step = 0.05, pct = true, default = 1 },
		{ type = "slider", key = "twist", label = "Torso twist", min = 0, max = 1.5, step = 0.05, pct = true, default = 0.5 },
		{ type = "slider", key = "cadence", label = "Cadence", min = 0.5, max = 2, step = 0.05, unit = "x", default = 1 },
		{ type = "slider", key = "fovKick", label = "FOV kick", min = 0, max = 25, step = 1, unit = " deg", default = 8 },
		{ type = "toggle", key = "always", label = "Run style also when walking / running (no key)", default = true },
		{ type = "toggle", key = "replace", label = "Replace the game's run animation", default = true },
	} },
	{ header = "Walls" },
	{ id = "pkWallRun", label = "Wall run", slider = "Max run time", value = 45, on = false, fmt = function(v) return ("%.1fs"):format(lerp(0.5, 4, v)) end, opts = {
		{ type = "slider", key = "speed", label = "Run speed", min = 14, max = 60, step = 1, unit = " sp", default = 30 },
		{ type = "slider", key = "tilt", label = "Camera tilt", min = 0, max = 20, step = 1, unit = " deg", default = 8 },
		{ type = "slider", key = "stride", label = "Leg stride", min = 0, max = 1.5, step = 0.05, pct = true, default = 1 },
		{ type = "slider", key = "cadence", label = "Leg cadence", min = 0.5, max = 2, step = 0.05, unit = "x", default = 1 },
		{ type = "slider", key = "bodyTilt", label = "Body tilt (away from wall)", min = 0, max = 45, step = 1, unit = " deg", default = 15 },
		{ type = "toggle", key = "needKey", label = "Needs move key held", default = true },
	} },
	{ id = "pkWallJump", label = "Wall jump", slider = "Push power", value = 40, on = false, fmt = Util.range(20, 80, " sp"), opts = {
		{ type = "slider", key = "up", label = "Up power", min = 20, max = 70, step = 1, unit = " sp", default = 45 },
		{ type = "slider", key = "jumps", label = "Jumps per air time", min = 1, max = 5, step = 1, default = 2 },
	} },
	{ id = "pkWallHop", label = "Wall hop", slider = "Hop height", value = 50, on = false, fmt = Util.range(20, 60, " sp"), opts = {
		{ type = "slider", key = "hops", label = "Hops per air time", min = 1, max = 8, step = 1, default = 3 },
	} },
	{ header = "Ledges" },
	{ id = "pkMantle", label = "Hang & mantle", slider = "Reach", value = 40, on = false, fmt = function(v) return ("%.1f st"):format(lerp(3, 8, v)) end, opts = {
		{ type = "toggle", key = "autoGrab", label = "Auto grab (off = hold jump)", default = true },
		{ type = "toggle", key = "autoMantle", label = "Mantle without hanging", default = false },
		{ type = "toggle", key = "wToClimb", label = "Hold forward to climb", default = false },
		{ type = "slider", key = "hangTime", label = "Max hang time", min = 2, max = 30, step = 1, unit = "s", default = 12 },
		{ type = "slider", key = "speed", label = "Mantle speed", min = 0.5, max = 2, step = 0.1, unit = "x", default = 1 },
		{ type = "toggle", key = "shimmy", label = "Move along ledge (A / D)", default = true },
		{ type = "slider", key = "shimmySpeed", label = "Ledge move speed", min = 2, max = 16, step = 1, unit = " st/s", default = 6 },
		{ type = "slider", key = "spread", label = "Hand spread", min = 0.3, max = 1.3, step = 0.05, unit = " st", default = 0.7 },
	} },
	{ header = "Visuals" },
	{ id = "pkAnim", label = "Parkour animations", slider = "Pose strength", value = 67, on = true, fmt = Util.range(0, 150, "%"), opts = {
		{ type = "slider", key = "smooth", label = "Smoothing", min = 4, max = 20, step = 1, default = 10 },
		{ type = "toggle", key = "landing", label = "Landing crouch", default = true },
		{ type = "toggle", key = "leap", label = "Sprint leap pose", default = true },
		{ type = "toggle", key = "ik", label = "Hands + feet reach ledge / wall (IK)", default = true },
	} },
	{ id = "pkCustom", label = "Custom wall run animation ID", slider = "Unused", value = 0, on = false, opts = {
		{ type = "text", key = "idRun", label = "Wall run", placeholder = "animation id (numbers)", default = "" },
	} },
} }

---------------------------------------------------------------------
-- settings (filled by the rows' set functions)
---------------------------------------------------------------------
local cfg = {
	sprint = { on = false, v = 40, o = {} },
	run = { on = false, v = 45, o = {} },
	jump = { on = false, v = 40, o = {} },
	hop = { on = false, v = 50, o = {} },
	mantle = { on = false, v = 40, o = {} },
	anim = { on = false, v = 67, o = {} },
	custom = { on = false, v = 0, o = {} },
}

local function bind(id, key)
	features[id] = {
		set = function(on, v, _c, o)
			local c = cfg[key]
			c.on, c.v, c.o = on, v, o
		end,
	}
end
bind("pkSprint", "sprint")
bind("pkWallRun", "run")
bind("pkWallJump", "jump")
bind("pkWallHop", "hop")
bind("pkMantle", "mantle")
bind("pkAnim", "anim")
bind("pkCustom", "custom")

---------------------------------------------------------------------
-- state
---------------------------------------------------------------------
local S = {
	char = nil, rig = nil, rigRetry = 0, rigTries = 0, warnedRig = false,
	state = "none", -- none / run / hang / mantle / launch
	run = nil, hang = nil, mantle = nil, launch = nil, flash = nil,
	noWallUntil = 0, noGrabUntil = 0, lastRunPart = nil,
	airJumps = 0, hops = 0,
	cyc = 0, -- 0..1 fade-in of the running cycle (the cycle itself must not be low-pass filtered)
	upright = 0, -- seconds left of easing the body back upright after a tilted wall run
	wasAir = false, fallV = 0, -- landing detection: was airborne last frame, fastest fall speed of this air time
	sprintOn = false, sprintSet = nil, origWS = 16, phase = 0,
	autoRotate = nil, anchored = false,
	roll = 0, fov = 0, fovBase = nil, fovLast = nil,
	conns = {}, ctx = nil, camBound = false,
}

local function resetState()
	S.state, S.run, S.hang, S.mantle, S.launch, S.flash = "none", nil, nil, nil, nil, nil
	S.anchored, S.sprintOn, S.sprintSet, S.autoRotate = false, false, nil, nil
	S.airJumps, S.hops, S.lastRunPart = 0, 0, nil
	S.wasAir, S.fallV, S.upright = false, 0, 0
end

---------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------
local function flat(v)
	return V3(v.X, 0, v.Z)
end

-- a solid, near vertical surface that is not another player
local function cast(origin, dir, dist)
	local hit = workspace:Raycast(origin, dir * dist, Util.rayParams())
	if hit and hit.Instance.CanCollide and math.abs(hit.Normal.Y) < 0.3 and not Util.playerFromPart(hit.Instance) then
		return hit
	end
	return nil
end

local function flatNormal(hit)
	return V3(hit.Normal.X, 0, hit.Normal.Z).Unit
end

local function airborne(hum)
	if hum.FloorMaterial ~= Enum.Material.Air or hum.SeatPart ~= nil then
		return false
	end
	local st = hum:GetState()
	return st ~= Enum.HumanoidStateType.Climbing and st ~= Enum.HumanoidStateType.Swimming
end

-- WalkSpeed is stored as a 32 bit float, so what you read back is not exactly what you wrote (33.6 -> 33.59999)
local function near(a, b)
	return math.abs(a - b) < 0.01
end

local function smooth(x)
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

---------------------------------------------------------------------
-- rig + pose engine
---------------------------------------------------------------------
local R15 = { "Waist", "Neck", "RightShoulder", "LeftShoulder", "RightElbow", "LeftElbow", "RightHip", "LeftHip", "RightKnee", "LeftKnee" }

local function buildRig(char, hum)
	local rig = { joints = {}, n = 0 }
	if hum.RigType == Enum.HumanoidRigType.R6 then
		-- R6: only the two shoulders are driven (by the hand IK). Its joint axes differ from R15, so the euler
		-- poses are not used on it and there is no elbow.
		local root, torso, ra = char:FindFirstChild("HumanoidRootPart"), char:FindFirstChild("Torso"), char:FindFirstChild("Right Arm")
		if root and torso then
			-- R6 has no waist / elbows / knees: arms, legs and the neck swing, the rest of a pose is skipped
			local R6MAP = { ["Right Shoulder"] = "RightShoulder", ["Left Shoulder"] = "LeftShoulder", ["Right Hip"] = "RightHip", ["Left Hip"] = "LeftHip", Neck = "Neck" }
			for _, d in ipairs(torso:GetChildren()) do
				local name = d:IsA("Motor6D") and R6MAP[d.Name]
				if name and not rig.joints[name] then
					rig.joints[name] = { m = d, c0 = d.C0, c0rot = d.C0 - d.C0.Position, cur = Vector3.zero, curR = CFrame.new(), dirty = false }
					rig.n += 1
				end
			end
			if rig.joints.RightShoulder and rig.joints.LeftShoulder then
				rig.r6, rig.noElbow = true, true
				rig.torsoRel = root.CFrame:ToObjectSpace(torso.CFrame)
				rig.upperLen = (ra and ra.Size.Y or 2) * 0.8
				rig.lowerLen = 0.05
				rig.armLen = rig.upperLen
				rig.hangDrop = math.clamp((rig.torsoRel * rig.joints.RightShoulder.c0).Position.Y + rig.armLen * 0.85, 1.8, 4.5)
			end
		end
		return rig
	end
	if hum.RigType ~= Enum.HumanoidRigType.R15 then
		return rig
	end
	local want = {}
	for _, name in ipairs(R15) do
		want[name] = true
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("Motor6D") and want[d.Name] and not rig.joints[d.Name] then
			rig.joints[d.Name] = { m = d, c0 = d.C0, cur = Vector3.zero, curR = CFrame.new(), dirty = false }
			rig.n += 1
		end
	end
	-- geometry for the hand / foot IK, measured from this character's own (possibly scaled) rig
	local root, torso, rs = char:FindFirstChild("HumanoidRootPart"), char:FindFirstChild("UpperTorso"), rig.joints.RightShoulder
	if root and torso and rs and rig.joints.LeftShoulder then
		local ua, la, hd = char:FindFirstChild("RightUpperArm"), char:FindFirstChild("RightLowerArm"), char:FindFirstChild("RightHand")
		rig.torsoRel = root.CFrame:ToObjectSpace(torso.CFrame)
		rig.upperLen = ua and ua.Size.Y or 1.2
		rig.lowerLen = (la and la.Size.Y or 1.1) + (hd and hd.Size.Y * 0.5 or 0.2)
		rig.armLen = rig.upperLen + rig.lowerLen
		rig.hangDrop = math.clamp((rig.torsoRel * rs.c0).Position.Y + rig.armLen * 0.85, 1.8, 4.5) -- root height below the ledge
	end
	local lt = char:FindFirstChild("LowerTorso")
	local ul, ll, ft = char:FindFirstChild("RightUpperLeg"), char:FindFirstChild("RightLowerLeg"), char:FindFirstChild("RightFoot")
	if root and lt and rig.joints.RightHip and rig.joints.LeftHip then
		rig.lowerRel = root.CFrame:ToObjectSpace(lt.CFrame)
		rig.thighLen = ul and ul.Size.Y or 1.2
		rig.shinLen = (ll and ll.Size.Y or 1.2) + (ft and ft.Size.Y * 0.5 or 0.1)
	end
	return rig
end

local function restoreRig(rig)
	for _, j in pairs(rig.joints) do
		if j.m.Parent then
			j.m.C0 = j.c0
		end
		j.cur, j.curR, j.dirty = Vector3.zero, CFrame.new(), false
	end
end

-- eases every joint toward its target angles (radians, x / y / z) and writes C0 = original * rotation
-- a target is a Vector3 (euler angles) or a CFrame (a rotation, used by the IK); both ease in and out
-- euler offset of a joint. The poses are written in the torso's frame (R15 joints have no baked rotation); R6 joints
-- DO have one in their C0, so the rotation is carried into the joint's own frame: C0rot^-1 * Q * C0rot
local function eul(rig, j)
	local q = CFrame.Angles(j.cur.X, j.cur.Y, j.cur.Z)
	if rig.r6 and j.c0rot then
		return j.c0rot:Inverse() * q * j.c0rot
	end
	return q
end

local function applyPose(dt, targets, strength, speed)
	local rig = S.rig
	if not rig then
		return
	end
	local k = 1 - math.exp(-dt * speed)
	local ident = CFrame.new()
	for name, j in pairs(rig.joints) do
		if j.m.Parent then
			local t = targets and targets[name]
			if typeof(t) == "CFrame" then
				j.curR = j.curR:Lerp(ident:Lerp(t, math.min(strength, 1)), k)
				j.cur = j.cur:Lerp(Vector3.zero, k)
				j.m.C0 = j.c0 * j.curR * eul(rig, j)
				j.dirty = true
			elseif t or j.dirty then -- settled joints with no target cost nothing
				j.cur = j.cur:Lerp((t or Vector3.zero) * strength, k)
				j.curR = j.curR:Lerp(ident, k)
				local _, ang = j.curR:ToAxisAngle()
				if ang < 1e-3 then
					j.curR = ident
				end
				if j.cur.Magnitude > 1e-3 or ang >= 1e-3 then
					j.m.C0 = j.c0 * j.curR * eul(rig, j)
					j.dirty = true
				elseif j.dirty then
					j.m.C0 = j.c0
					j.cur, j.dirty = Vector3.zero, false
				end
			end
		end
	end
end

local function stopTracks(hum)
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0.1)
	end
end

local function add(t, name, x, y, z)
	t[name] = (t[name] or Vector3.zero) + V3(x or 0, y or 0, z or 0)
end

-- R15 joint axes assumed: arm / leg forward = +X, outward arm = +Z (right) / -Z (left),
-- torso forward lean = -X, knee / elbow bend = -X / +X.
-- o = the Sprint row's options: style, lean, pump, stride, twist (cadence is applied to the phase by the caller)
local function sprintPose(phase, o)
	local lean, pump = o.lean or 1, o.pump or 1
	local stride, twist = o.stride or 1, o.twist or 0.5
	local style = o.style or "Pump"
	local t = {}
	local s, c = math.sin(phase), math.cos(phase)
	-- torso rotates against the hips, the head stays roughly facing forward
	add(t, "Waist", 0, c * 0.25 * twist, 0)
	add(t, "Neck", 0, -c * 0.15 * twist, 0)
	if style == "Ninja" then
		-- arms swept straight back behind the body
		add(t, "Waist", -0.55 * lean)
		add(t, "Neck", 0.4 * lean)
		add(t, "RightShoulder", -1.9 - s * 0.12 * pump, 0, 0.12)
		add(t, "LeftShoulder", -1.9 + s * 0.12 * pump, 0, -0.12)
		add(t, "RightElbow", 0.15)
		add(t, "LeftElbow", 0.15)
		add(t, "RightHip", -s * 0.55 * stride)
		add(t, "LeftHip", s * 0.55 * stride)
		add(t, "RightKnee", -1.0 * math.max(0, s) * stride)
		add(t, "LeftKnee", -1.0 * math.max(0, -s) * stride)
	elseif style == "Sprinter" then
		-- tight 90 degree elbows, big arm drive, high knees
		add(t, "Waist", -0.4 * lean)
		add(t, "Neck", 0.25 * lean)
		add(t, "RightElbow", 1.55)
		add(t, "LeftElbow", 1.55)
		add(t, "RightShoulder", s * 1.0 * pump)
		add(t, "LeftShoulder", -s * 1.0 * pump)
		add(t, "RightHip", -s * 0.75 * stride)
		add(t, "LeftHip", s * 0.75 * stride)
		add(t, "RightKnee", -1.2 * math.max(0, s) * stride)
		add(t, "LeftKnee", -1.2 * math.max(0, -s) * stride)
	else
		add(t, "Waist", -0.3 * lean)
		add(t, "Neck", 0.2 * lean)
		add(t, "RightElbow", 1.2 * pump)
		add(t, "LeftElbow", 1.2 * pump)
		add(t, "RightShoulder", s * 0.7 * pump)
		add(t, "LeftShoulder", -s * 0.7 * pump)
		add(t, "RightHip", -s * 0.5 * stride)
		add(t, "LeftHip", s * 0.5 * stride)
		add(t, "RightKnee", -0.9 * math.max(0, s) * stride)
		add(t, "LeftKnee", -0.9 * math.max(0, -s) * stride)
	end
	return t
end

-- side = +1 wall on the right, -1 wall on the left
local function runPose(phase, side, o)
	o = o or {}
	local stride = o.stride or 1
	local t = {}
	local s = math.sin(phase * 1.4 * (o.cadence or 1))
	add(t, "Waist", -0.15, 0, 0.2 * side) -- top leans away from the wall (the body tilt does the rest)
	add(t, "Neck", 0.15)
	if side > 0 then
		add(t, "RightShoulder", 0.3, 0, 1.3) -- wall side hand out against the wall
		add(t, "LeftShoulder", -0.7)
	else
		add(t, "LeftShoulder", 0.3, 0, -1.3)
		add(t, "RightShoulder", -0.7)
	end
	add(t, "RightElbow", 0.6)
	add(t, "LeftElbow", 0.6)
	add(t, "RightHip", -s * 1.0 * stride)
	add(t, "LeftHip", s * 1.0 * stride)
	add(t, "RightKnee", -1.4 * math.max(0, s) * stride)
	add(t, "LeftKnee", -1.4 * math.max(0, -s) * stride)
	return t
end

local function hangPose(clock)
	local t = {}
	local sway = math.sin(clock * 1.5) * 0.08
	add(t, "RightShoulder", 2.9, 0, 0.15)
	add(t, "LeftShoulder", 2.9, 0, -0.15)
	add(t, "RightElbow", 0.15)
	add(t, "LeftElbow", 0.15)
	add(t, "Neck", 0.35)
	add(t, "RightHip", 0.15 + sway)
	add(t, "LeftHip", 0.05 - sway)
	add(t, "RightKnee", -0.3)
	add(t, "LeftKnee", -0.3)
	return t
end

local function mantlePose(p)
	local t = {}
	local q = smooth(p / 0.6)
	local arc = math.sin(math.pi * math.clamp(p, 0, 1))
	local arm = 2.9 * (1 - q) + 0.2 * q
	add(t, "RightShoulder", arm)
	add(t, "LeftShoulder", arm)
	add(t, "Waist", -0.6 * arc)
	add(t, "RightHip", 1.2 * arc)
	add(t, "LeftHip", 1.0 * arc)
	add(t, "RightKnee", -1.4 * arc)
	add(t, "LeftKnee", -1.2 * arc)
	return t
end

local function kickPose()
	local t = {}
	add(t, "Waist", -0.15)
	add(t, "RightShoulder", 0.4, 0, 1.2)
	add(t, "LeftShoulder", 0.4, 0, -1.2)
	add(t, "RightHip", 0.9)
	add(t, "LeftHip", -0.3)
	add(t, "RightKnee", -1.3)
	add(t, "LeftKnee", -0.6)
	return t
end

local function hopPose()
	local t = {}
	add(t, "Waist", -0.1)
	add(t, "RightShoulder", 2.5)
	add(t, "LeftShoulder", 2.5)
	add(t, "RightHip", 0.6)
	add(t, "LeftHip", 0.6)
	add(t, "RightKnee", -1.0)
	add(t, "LeftKnee", -1.0)
	return t
end

-- sprinting through the air: lead arm and knee reach forward, the trailing leg folds behind
local function leapPose(lean, pump)
	local t = {}
	add(t, "Waist", -0.35 * lean)
	add(t, "Neck", 0.25 * lean)
	add(t, "RightShoulder", 2.3 * pump, 0, 0.2)
	add(t, "LeftShoulder", -0.9 * pump, 0, -0.3)
	add(t, "RightElbow", 0.4 * pump)
	add(t, "LeftElbow", 0.9 * pump)
	add(t, "RightHip", 1.0 * pump)
	add(t, "LeftHip", -0.7 * pump)
	add(t, "RightKnee", -0.8 * pump)
	add(t, "LeftKnee", -1.3 * pump)
	return t
end

-- landing absorb: k = 0..1 crouch depth (the caller fades it out over the flash)
local function landPose(k)
	local t = {}
	add(t, "Waist", -0.5 * k)
	add(t, "Neck", 0.3 * k)
	add(t, "RightShoulder", 0.9 * k, 0, 0.5 * k)
	add(t, "LeftShoulder", 0.9 * k, 0, -0.5 * k)
	add(t, "RightHip", 1.0 * k)
	add(t, "LeftHip", 1.0 * k)
	add(t, "RightKnee", -1.5 * k)
	add(t, "LeftKnee", -1.5 * k)
	return t
end

---------------------------------------------------------------------
-- limb IK (arms and legs), solved from the DISTANCE between the joint and what is being reached:
--   too far  -> the limb straightens and points at it
--   closer   -> law of cosines gives the middle joint's bend and how far the upper part leans off the line
-- `pole` is the direction the elbow / knee should point. The top joint is twisted along the limb so the middle
-- joint's bend axis (X) lies in that bend plane. Everything is worked out in the top joint's own frame, so no
-- rig axis has to be guessed except the bend axis: elbow flexes +X (forearm swings forward), knee flexes -X
-- (shin swings back), which is what `sign` carries.
---------------------------------------------------------------------
local function limbIK(t, frame, jointName, lowerName, Lu, Ll, target, pole, sign, noLower)
	if not target then
		return false
	end
	local to = target - frame.Position
	local d = to.Magnitude
	if d < 0.05 then
		return false
	end
	local dir = to / d

	local u, flex = dir, 0 -- upper limb direction (world), middle joint flexion
	if not noLower and d < Lu + Ll - 1e-3 then
		local dd = math.max(d, math.abs(Lu - Ll) + 1e-3)
		local alpha = math.acos(math.clamp((Lu * Lu + dd * dd - Ll * Ll) / (2 * Lu * dd), -1, 1))
		flex = math.pi - math.acos(math.clamp((Lu * Lu + Ll * Ll - dd * dd) / (2 * Lu * Ll), -1, 1))
		local p = pole - dir * pole:Dot(dir)
		if p.Magnitude < 1e-3 then
			p = frame.UpVector - dir * frame.UpVector:Dot(dir)
		end
		p = p.Unit
		u = dir * math.cos(alpha) + p * math.sin(alpha)
	end

	-- top joint: minimal rotation taking the resting limb direction (down) to u, in the joint frame
	local down = V3(0, -1, 0)
	local ul = frame:VectorToObjectSpace(u)
	local dot = math.clamp(down:Dot(ul), -1, 1)
	local axis = down:Cross(ul)
	local r0 = axis.Magnitude < 1e-4 and (dot > 0 and CFrame.new() or CFrame.Angles(math.pi, 0, 0))
		or CFrame.fromAxisAngle(axis.Unit, math.acos(dot))

	-- twist about the limb so the middle joint bends toward the target
	local rot = r0
	if flex > 0.02 then
		local midPos = frame.Position + u * Lu
		local a = u:Cross(target - midPos)
		if a.Magnitude > 1e-4 then
			a = a.Unit * sign -- the knee bends -X, so its bend axis is the flipped one
			local x0 = (frame * r0):VectorToWorldSpace(V3(1, 0, 0))
			local armAxis = -u -- local +Y after r0 points back up the limb
			local phi = math.atan2(armAxis:Dot(x0:Cross(a)), x0:Dot(a))
			rot = r0 * CFrame.Angles(0, phi, 0)
		end
	end
	t[jointName] = rot
	if not noLower then
		t[lowerName] = V3(flex * sign, 0, 0)
	end
	return true
end

local function armIK(t, rig, root, side, target, pole)
	local j = rig.joints[side .. "Shoulder"]
	if not (j and rig.torsoRel and rig.upperLen and target) then
		return false
	end
	return limbIK(t, root.CFrame * rig.torsoRel * j.c0, side .. "Shoulder", side .. "Elbow", rig.upperLen, rig.lowerLen, target, pole, 1, rig.noElbow == true)
end

local function legIK(t, rig, root, side, target, pole)
	local j = rig.joints[side .. "Hip"]
	if not (j and rig.lowerRel and rig.thighLen and target) then
		return false
	end
	return limbIK(t, root.CFrame * rig.lowerRel * j.c0, side .. "Hip", side .. "Knee", rig.thighLen, rig.shinLen, target, pole, -1, false)
end

local function ikReady()
	local rig = S.rig
	return rig and rig.torsoRel and cfg.anim.o.ik ~= false and rig or nil
end

-- both hands on a point, spread sideways along `right`
local function reachBoth(t, rig, root, point, right, spread)
	-- elbows point down and outward
	return armIK(t, rig, root, "Right", point + right * spread, V3(0, -1, 0) + right * 0.8)
		and armIK(t, rig, root, "Left", point - right * spread, V3(0, -1, 0) - right * 0.8)
end

local function ikHangPose(clock, root, h)
	local rig = ikReady()
	if not (rig and h.grip) then
		return nil
	end
	local t = hangPose(clock)
	local right = (-h.n):Cross(UP)
	if right.Magnitude < 0.01 then
		return nil
	end
	right = right.Unit
	-- while moving along the ledge the hands go over each other: each one reaches further out in turn
	local spread = cfg.mantle.o.spread or 0.7
	local sw = 0.3 * (h.mv or 0)
	local ph = h.ph or 0
	local rr = spread + sw * math.sin(ph)
	local rl = spread + sw * math.sin(ph + math.pi)
	local ok = armIK(t, rig, root, "Right", h.grip + right * rr, V3(0, -1, 0) + right * 0.8)
		and armIK(t, rig, root, "Left", h.grip - right * rl, V3(0, -1, 0) - right * 0.8)
	return ok and t or nil
end

-- hands stay planted on the ledge while the body is pulled up
local function ikMantlePose(p, root, m)
	local rig = ikReady()
	if not (rig and m.grip) or p >= 0.9 then
		return nil
	end
	local t = mantlePose(p)
	local right = (-m.n):Cross(UP)
	if right.Magnitude < 0.01 then
		return nil
	end
	return reachBoth(t, rig, root, m.grip, right.Unit, cfg.mantle.o.spread or 0.7) and t or nil
end

-- wall run: the wall-side hand presses on the wall and slides with the stride, both feet step on the wall.
-- A foot is planted on the wall surface while it moves back relative to the body, then lifts off the wall and
-- swings forward (lift = the swing half of the cycle).
local function ikRunPose(phase, side, root, r, o)
	local rig = ikReady()
	if not rig then
		return nil
	end
	local t = runPose(phase, side, o)
	t.Waist = nil -- the IK frames assume an unbent torso
	local n, tg = r.normal, r.tangent
	local surf = root.Position - n * (r.dist or REACH) -- wall point at root height
	local ph = phase * 1.4 * (o.cadence or 1)

	-- elbow points back and down, away from the wall
	local hand = surf + n * 0.1 + tg * (0.35 + 0.3 * math.cos(ph)) + UP * 0.4
	armIK(t, rig, root, side > 0 and "Right" or "Left", hand, -tg * 0.6 + V3(0, -0.6, 0) + n * 0.3)

	if rig.lowerRel and rig.thighLen then
		local reach = rig.thighLen + rig.shinLen
		local stride = (o.stride or 1) * 0.9
		for _, leg in ipairs({ "Right", "Left" }) do
			local j = rig.joints[leg .. "Hip"]
			if j then
				local pp = ph + (leg == "Right" and 0 or math.pi)
				local lift = math.max(0, -math.sin(pp))
				local hip = (root.CFrame * rig.lowerRel * j.c0).Position
				local foot = V3(surf.X, hip.Y - reach * 0.82 + lift * 0.5, surf.Z)
					+ n * (0.15 + lift * 0.8) + tg * (stride * math.cos(pp))
				-- knee points forward and away from the wall
				legIK(t, rig, root, leg, foot, tg * 0.8 + n * 0.4)
			end
		end
	end
	return t
end

-- both hands slap the wall in front and slide up it
local function ikHopPose(root, f)
	local rig = ikReady()
	if not (rig and f.point) then
		return nil
	end
	local t = hopPose()
	local right = flat(root.CFrame.RightVector)
	if right.Magnitude < 0.01 then
		return nil
	end
	local point = V3(f.point.X, root.Position.Y + 0.9, f.point.Z)
	return reachBoth(t, rig, root, point, right.Unit, 0.7) and t or nil
end

---------------------------------------------------------------------
-- custom animation id (Custom wall run animation ID row): a loaded track replaces the procedural wall run pose
---------------------------------------------------------------------
local KEYMAP = { run = "idRun" }
local LOOPED = { run = true }
local custom = { tracks = {}, active = nil }

local function stopCustom(fade)
	local rec = custom.active and custom.tracks[custom.active]
	if rec and rec.track then
		pcall(rec.track.Stop, rec.track, fade or 0.15)
	end
	custom.active = nil
end

-- plays the track for `kind` (nil = none). Returns true while a custom track really is animating the body.
local function setCustom(hum, kind, dur)
	local optKey = kind and KEYMAP[kind]
	local id = optKey and tostring(cfg.custom.o[optKey] or ""):match("%d+")
	local animator = id and hum:FindFirstChildOfClass("Animator")
	if not animator then
		stopCustom()
		return false
	end
	local rec = custom.tracks[kind]
	if not rec or rec.id ~= id or rec.animator ~= animator then
		if rec and rec.track then
			pcall(rec.track.Stop, rec.track, 0)
		end
		rec = { id = id, animator = animator, born = os.clock(), track = false }
		custom.tracks[kind] = rec
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. id
		local ok, track = pcall(animator.LoadAnimation, animator, anim)
		if ok and track then
			pcall(function()
				track.Priority = Enum.AnimationPriority.Action4
				track.Looped = LOOPED[kind] == true
			end)
			rec.track = track
		end
	end
	local track = rec.track
	if not track then
		stopCustom()
		return false
	end
	if custom.active ~= kind then
		stopCustom()
		custom.active = kind
		rec.speedSet = false
		track:Play(0.15)
	end
	if track.Length <= 0 then
		-- not loaded (yet): the procedural pose keeps running; after 2 s it is treated as refused by the game
		if os.clock() - rec.born > 2 and not rec.warned then
			rec.warned = true
			rec.track = false
			pcall(track.Stop, track, 0)
			if S.ctx then
				S.ctx.notify(("parkour: animation %s did not load (the game may not allow it)"):format(id), Color3.fromRGB(255, 214, 64))
			end
		end
		return false
	end
	if dur and not rec.speedSet then
		rec.speedSet = true
		pcall(track.AdjustSpeed, track, track.Length / dur) -- one-shot moves are stretched to the move's length
	end
	return true
end

---------------------------------------------------------------------
-- character tracking
---------------------------------------------------------------------
local function refreshChar()
	local char = lp.Character
	if char ~= S.char then
		if S.rig then
			restoreRig(S.rig)
		end
		stopCustom(0)
		table.clear(custom.tracks)
		resetState()
		S.char, S.rig, S.rigRetry, S.rigTries = char, nil, 0, 0
	end
	local root = Util.rootOf(char)
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	-- a rig built while the character was still loading can miss joints: rebuild it (from clean C0s) until complete
	local want = hum and (hum.RigType == Enum.HumanoidRigType.R6 and 5 or hum.RigType == Enum.HumanoidRigType.R15 and 10) or 0
	local incomplete = S.rig and (S.rig.n < want or (want == 10 and not S.rig.lowerRel))
	if char and hum and (not S.rig or (incomplete and os.clock() >= S.rigRetry and S.rigTries < 20)) then
		if S.rig then
			restoreRig(S.rig)
		end
		S.rig = buildRig(char, hum)
		S.rigTries += 1
		S.rigRetry = os.clock() + 0.5
	end
	return char, root, hum
end

local function releaseHold(root)
	if S.anchored and root then
		root.Anchored = false
	end
	S.anchored = false
end

local function endRun(hum)
	S.state, S.run = "none", nil
	S.noWallUntil = os.clock() + COOLDOWN
	S.upright = 0.4 -- ease the tilted body back upright
	if S.autoRotate ~= nil and hum then
		hum.AutoRotate = S.autoRotate
	end
	S.autoRotate = nil
end

local function abortAll(root, hum)
	releaseHold(root)
	if S.state == "run" then
		endRun(hum)
	end
	S.state, S.run, S.hang, S.mantle, S.launch, S.flash = "none", nil, nil, nil, nil, nil
end

---------------------------------------------------------------------
-- actions
---------------------------------------------------------------------
local function startWallRun(root, hum, hit, side, tangent)
	S.state = "run"
	S.run = {
		normal = flatNormal(hit),
		tangent = tangent,
		side = side,
		dist = hit.Distance,
		t = 0,
		dur = lerp(0.5, 4, cfg.run.v),
	}
	S.lastRunPart = hit.Instance
	S.autoRotate = hum.AutoRotate
	hum.AutoRotate = false
end

-- normal = horizontal unit vector pointing away from the wall
local function wallJump(root, hum, normal, keep)
	local hv = flat(root.AssemblyLinearVelocity)
	local push = lerp(20, 80, cfg.jump.v)
	local up = cfg.jump.o.up or 45
	local along = keep and keep * math.max(0, hv:Dot(keep)) * 0.7 or Vector3.zero
	local v = normal * push + along + UP * up
	root.AssemblyLinearVelocity = v
	local dir = flat(v)
	if dir.Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + dir)
	end
	S.airJumps += 1
	S.noWallUntil = os.clock() + COOLDOWN
	S.flash = { kind = "kick", t = 0, dur = 0.4 }
end

local function wallHop(root, normal, point)
	local vel = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = V3(vel.X * 0.15, lerp(20, 60, cfg.hop.v), vel.Z * 0.15) - normal * 3
	root.CFrame = CFrame.lookAt(root.Position, root.Position - normal)
	S.hops += 1
	S.flash = { kind = "hop", t = 0, dur = 0.35, point = point }
end

-- pull up to chest height on the ledge (scripted), then step() pops you into the air and pushes you onto it
local function startMantle(root, hum)
	local h = S.hang
	if not h then
		return
	end
	local standH = hum.HipHeight + root.Size.Y / 2
	local b = V3(h.cf.Position.X, h.ledgeY + standH + 0.35, h.cf.Position.Z)
	-- land a bit past the lip, but only as far as there is floor to stand on (thin ledges / railings)
	local c = b - h.n * 1.8
	if not workspace:Raycast(c + UP * 2, V3(0, -(standH + 4), 0), Util.rayParams()) then
		c = b - h.n * 0.9
	end
	local a = root.Position
	S.state = "mantle"
	S.mantle = {
		t = 0, dur = MANTLE_PULL / (cfg.mantle.o.speed or 1), a = a, b = b, c = c, n = h.n, grip = h.grip,
		ledgeY = h.ledgeY, standH = standH, mid = V3(a.X, h.ledgeY - 0.4, a.Z),
	}
end

local function dropHang(root)
	releaseHold(root)
	if root then
		root.AssemblyLinearVelocity = S.hang and S.hang.n * 4 or Vector3.zero
	end
	S.state, S.hang = "none", nil
	S.noGrabUntil = os.clock() + 0.6
end

local function tryGrab(root, hum)
	local o = cfg.mantle.o
	local reachUp = lerp(3, 8, cfg.mantle.v)
	local md = flat(hum.MoveDirection)
	local dir = md.Magnitude > 0.1 and md or flat(root.CFrame.LookVector)
	if dir.Magnitude < 0.1 then
		return
	end
	dir = dir.Unit
	if o.autoGrab == false and not (UserInputService:IsKeyDown(Enum.KeyCode.Space) or hum.Jump) then
		return
	end
	local pos = root.Position
	local hit = cast(pos + UP * 0.5, dir, GRAB_REACH)
	if not hit then
		return
	end
	local n = flatNormal(hit)
	-- the top of that wall: a ray straight down from just inside it, above the reach
	local top = workspace:Raycast(hit.Position - n * 0.5 + UP * (reachUp + 2), V3(0, -(reachUp + 4.5), 0), Util.rayParams())
	-- the top may belong to a neighbouring part (stacked / tiled walls), it only has to be solid and not a player
	if not top or not top.Instance.CanCollide or top.Normal.Y < 0.8 or Util.playerFromPart(top.Instance) then
		return
	end
	local ledgeY = top.Position.Y
	if ledgeY < pos.Y + 0.6 or ledgeY > pos.Y + reachUp then
		return
	end
	if workspace:Raycast(top.Position + UP * 0.2, UP * 5.5, Util.rayParams()) then
		return -- no room to stand on it
	end
	local drop = S.rig and S.rig.hangDrop or 2.5 -- arms reach the ledge with the rig's own proportions
	local target = V3(hit.Position.X, ledgeY - drop, hit.Position.Z) + n * HANG_OFF
	local grip = V3(hit.Position.X, ledgeY + 0.05, hit.Position.Z) - n * 0.1 -- the lip of the ledge, where the hands go
	root.AssemblyLinearVelocity = Vector3.zero
	if ANCHOR_HOLD then
		root.Anchored = true
	end
	S.anchored = true
	local cf = CFrame.lookAt(target, target - n)
	S.state = "hang"
	S.hang = {
		cf = cf, n = n, ledgeY = ledgeY, part = hit.Instance, t = 0, from = root.CFrame, wHold = 0,
		rel = hit.Instance.CFrame:ToObjectSpace(cf), -- grab point in the wall's space, so moving platforms carry you
		grip = grip, gripRel = hit.Instance.CFrame:ToObjectSpace(CFrame.new(grip)),
		drop = drop, mv = 0, ph = 0, -- drop = root height under the ledge; mv / ph drive the hand-over-hand while moving
	}
	S.airJumps, S.hops = 0, 0
end

-- moves the hang point `dist` studs along the ledge (dirv = unit vector along it). The ledge top and the wall
-- are probed a little ahead of the hands, so it stops at the end of the ledge (corners are not wrapped) and
-- follows gentle bends and small steps. Returns false when there is nothing to hold ahead.
local function shimmy(h, dirv, dist)
	local ahead = 0.45
	local gp = h.grip + dirv * (dist + ahead)
	local top = workspace:Raycast(gp - h.n * 0.3 + UP * 1.5, V3(0, -3, 0), Util.rayParams())
	if not top or not top.Instance.CanCollide or top.Normal.Y < 0.8 or math.abs(top.Position.Y - h.ledgeY) > 0.7 or Util.playerFromPart(top.Instance) then
		return false
	end
	local wall = cast(V3(gp.X, top.Position.Y - 1.2, gp.Z) + h.n * 1.0, -h.n, 2.0)
	if not wall then
		return false
	end
	local n = flatNormal(wall)
	local ledgeY = top.Position.Y
	local back = dirv * ahead
	local pos = V3(wall.Position.X - back.X, ledgeY - h.drop, wall.Position.Z - back.Z) + n * HANG_OFF
	local grip = V3(wall.Position.X - back.X, ledgeY + 0.05, wall.Position.Z - back.Z) - n * 0.1
	local cf = CFrame.lookAt(pos, pos - n)
	h.n, h.ledgeY, h.cf, h.grip = n, ledgeY, cf, grip
	h.rel = h.part.CFrame:ToObjectSpace(cf)
	h.gripRel = h.part.CFrame:ToObjectSpace(CFrame.new(grip))
	return true
end

local function onJump()
	local _, root, hum = refreshChar()
	if not (root and hum) or hum.Health <= 0 then
		return
	end
	if S.state == "hang" then
		startMantle(root, hum)
		return
	end
	if S.state == "run" then
		local n, tg = S.run.normal, S.run.tangent
		endRun(hum)
		if cfg.jump.on then
			wallJump(root, hum, n, tg)
		else
			root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + UP * 35
		end
		return
	end
	if S.state ~= "none" or not airborne(hum) then
		return
	end
	local pos = root.Position
	local look = flat(root.CFrame.LookVector)
	if look.Magnitude < 0.01 then
		return
	end
	look = look.Unit
	if cfg.hop.on and S.hops < (cfg.hop.o.hops or 3) then
		local hit = cast(pos, look, REACH + 0.4)
		if hit then
			wallHop(root, flatNormal(hit), hit.Position)
			return
		end
	end
	if cfg.jump.on and S.airJumps < (cfg.jump.o.jumps or 2) then
		local right = flat(root.CFrame.RightVector).Unit
		local best
		for _, dir in ipairs({ look, right, -right, -look }) do
			local h = cast(pos, dir, REACH)
			if h and (not best or h.Distance < best.Distance) then
				best = h
			end
		end
		if best then
			wallJump(root, hum, flatNormal(best), nil)
		end
	end
end

---------------------------------------------------------------------
-- camera: FOV kick while sprinting, roll while wall running (applied after the camera script)
---------------------------------------------------------------------
local function camStep(dt)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local kick = (S.sprintOn and S.state == "none" and cfg.sprint.on) and (cfg.sprint.o.fovKick or 0) or 0
	S.fov += (kick - S.fov) * (1 - math.exp(-dt * 6))
	if S.fov > 0.01 or S.fovLast then
		-- if something else (the FOV row) changed the FOV since our last write, that value is the new base
		local base = (S.fovLast and math.abs(cam.FieldOfView - S.fovLast) < 1e-3) and S.fovBase or cam.FieldOfView
		S.fovBase = base
		if S.fov <= 0.01 and kick == 0 then
			cam.FieldOfView = base
			S.fov, S.fovLast = 0, nil
		else
			cam.FieldOfView = base + S.fov
			S.fovLast = cam.FieldOfView
		end
	end
	local rollT = 0
	if S.state == "run" and S.run then
		rollT = math.rad(cfg.run.o.tilt or 0) * S.run.side
	end
	S.roll += (rollT - S.roll) * (1 - math.exp(-dt * 8))
	if math.abs(S.roll) > 1e-3 then
		cam.CFrame = cam.CFrame * CFrame.Angles(0, 0, S.roll)
	end
end

---------------------------------------------------------------------
-- controller
---------------------------------------------------------------------
local function sprintKeyDown(o)
	local k = o.key or "Left Shift"
	if k == "Always" then
		return true
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	local code = KEYS[k]
	return code ~= nil and UserInputService:IsKeyDown(code)
end

features.pkCore = {
	init = function(ctx)
		S.ctx = ctx
		S.conns[#S.conns + 1] = UserInputService.JumpRequest:Connect(function()
			local ok, err = pcall(onJump)
			if not ok then
				warn("[FMenu] parkour jump failed: " .. tostring(err))
			end
		end)
		local okBind = pcall(function()
			RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Camera.Value + 2, camStep)
		end)
		S.camBound = okBind
	end,

	set = function() end,

	step = function(dt)
		dt = math.min(dt, 0.1) -- a lag spike must not skip a whole mantle / wall run
		local _, root, hum = refreshChar()
		if not (root and hum) then
			return
		end
		local now = os.clock()
		if hum.Health <= 0 then
			if S.state ~= "none" then
				abortAll(root, hum)
			end
			return
		end
		local air = airborne(hum)

		-- rows turned off in the middle of a move
		if S.state == "run" and not cfg.run.on then
			endRun(hum)
		elseif (S.state == "hang" or S.state == "mantle") and not cfg.mantle.on then
			releaseHold(root)
			S.state, S.hang, S.mantle = "none", nil, nil
		end

		-- after a tilted wall run: ease back to upright, keeping the facing direction
		if S.upright > 0 and S.state == "none" then
			S.upright -= dt
			local look = flat(root.CFrame.LookVector)
			if look.Magnitude > 0.01 then
				root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, root.Position + look), 1 - math.exp(-dt * 14))
			end
		end

		-- landing: remember the fastest fall of this air time, crouch when it ends hard
		if air then
			S.wasAir = true
			S.fallV = math.min(S.fallV, root.AssemblyLinearVelocity.Y)
		elseif S.wasAir then
			S.wasAir = false
			local impact = -S.fallV
			S.fallV = 0
			if impact > 30 and S.state == "none" and hum.FloorMaterial ~= Enum.Material.Air and cfg.anim.on and cfg.anim.o.landing ~= false then
				S.flash = { kind = "land", t = 0, dur = 0.35, power = math.clamp((impact - 30) / 60, 0.25, 1) }
			end
		end

		-- landing refills the air-time counters
		if hum.FloorMaterial ~= Enum.Material.Air and S.state == "none" then
			S.airJumps, S.hops, S.lastRunPart = 0, 0, nil
		end

		-- sprint
		if cfg.sprint.on and S.state == "none" and hum.MoveDirection.Magnitude > 0.1 and sprintKeyDown(cfg.sprint.o) and hum.SeatPart == nil then
			if not S.sprintOn then
				S.sprintOn = true
				S.origWS = hum.WalkSpeed
			elseif S.sprintSet and not near(hum.WalkSpeed, S.sprintSet) then
				S.origWS = hum.WalkSpeed -- the game (or the Speed row) changed it: that is the new normal speed
			end
			local target = math.max(S.origWS, lerp(16, 60, cfg.sprint.v))
			if not near(hum.WalkSpeed, target) then
				hum.WalkSpeed = target
			end
			S.sprintSet = target
		elseif S.sprintOn then
			S.sprintOn = false
			if S.sprintSet and near(hum.WalkSpeed, S.sprintSet) then
				hum.WalkSpeed = S.origWS
			end
			S.sprintSet = nil
		end

		-- wall run: start
		if cfg.run.on and S.state == "none" and air and now >= S.noWallUntil then
			local hv = flat(root.AssemblyLinearVelocity)
			local pressing = hum.MoveDirection.Magnitude > 0.1 or cfg.run.o.needKey == false
			if hv.Magnitude >= RUN_MIN_SPEED and pressing then
				local dirv = hv.Unit
				local right = flat(root.CFrame.RightVector)
				if right.Magnitude > 0.01 then
					right = right.Unit
					local best
					for _, sgn in ipairs({ 1, -1 }) do
						local h = cast(root.Position, right * sgn, REACH)
						if h and (not best or h.Distance < best.Distance) then
							best = h
						end
					end
					if best and best.Instance ~= S.lastRunPart then
						local n = flatNormal(best)
						local tg = n:Cross(UP)
						if tg:Dot(dirv) < 0 then
							tg = -tg
						end
						if tg:Dot(dirv) > 0.5 then
							local side = (-n):Dot(right) > 0 and 1 or -1
							startWallRun(root, hum, best, side, tg)
						end
					end
				end
			end
		end

		-- ledge grab
		if cfg.mantle.on and S.state == "none" and air and now >= S.noGrabUntil and root.AssemblyLinearVelocity.Y < 10 then
			tryGrab(root, hum)
		end

		-- state updates
		if S.state == "run" then
			local r = S.run
			r.t += dt
			local hit = cast(root.Position, -r.normal, REACH + 0.8)
			local keyOk = hum.MoveDirection.Magnitude > 0.1 or cfg.run.o.needKey == false
			if not hit or not air or r.t > r.dur or not keyOk then
				endRun(hum)
			else
				r.normal = flatNormal(hit)
				r.dist = hit.Distance
				local tg = r.normal:Cross(UP)
				if tg:Dot(r.tangent) < 0 then
					tg = -tg
				end
				r.tangent = tg
				local speed = cfg.run.o.speed or 30
				local p = r.t / r.dur
				root.AssemblyLinearVelocity = tg * speed + UP * (5 - 9 * p) - r.normal * 2
				-- the whole body leans away from the wall (positive roll = top to the left, so wall on the right = +)
				local roll = math.rad(cfg.run.o.bodyTilt or 0) * r.side
				local face = CFrame.lookAt(root.Position, root.Position + tg) * CFrame.Angles(0, 0, roll)
				root.CFrame = root.CFrame:Lerp(face, 1 - math.exp(-dt * 12))
				S.phase += dt * speed * 0.6
			end
		elseif S.state == "hang" then
			local h = S.hang
			h.t += dt
			if h.part.Parent then
				local cf = h.part.CFrame * h.rel
				h.ledgeY += cf.Position.Y - h.cf.Position.Y
				h.cf = cf
				h.grip = (h.part.CFrame * h.gripRel).Position
				local n = flat(-cf.LookVector)
				if n.Magnitude > 0.1 then
					h.n = n.Unit
				end
			end
			-- move along the ledge with the sideways part of the move input
			local o0 = cfg.mantle.o
			local want = 0
			if o0.shimmy ~= false and h.t >= 0.15 then
				local rightDir = (-h.n):Cross(UP)
				if rightDir.Magnitude > 0.01 then
					local side = hum.MoveDirection:Dot(rightDir.Unit)
					if math.abs(side) > 0.35 then
						want = side > 0 and 1 or -1
						local sp = o0.shimmySpeed or 6
						if shimmy(h, rightDir.Unit * want, sp * dt) then
							h.ph += dt * sp * 2.2
						else
							want = 0 -- end of the ledge
						end
					end
				end
			end
			h.mv += ((want ~= 0 and 1 or 0) - h.mv) * (1 - math.exp(-dt * 10))
			if not ANCHOR_HOLD then
				root.AssemblyLinearVelocity = Vector3.zero
			end
			root.CFrame = h.from:Lerp(h.cf, smooth(h.t / 0.12))
			local o = cfg.mantle.o
			local move = hum.MoveDirection
			if o.autoMantle and h.t >= 0.12 then
				startMantle(root, hum)
			else
				if o.wToClimb and h.t > 0.5 and move:Dot(-h.n) > 0.6 then
					h.wHold += dt
				else
					h.wHold = 0
				end
				if h.wHold > 0.25 then
					startMantle(root, hum)
				elseif move:Dot(h.n) > 0.6 or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or h.t > (o.hangTime or 12) or not h.part.Parent then
					dropHang(root)
				end
			end
		elseif S.state == "mantle" then
			-- scripted pull up to chest height on the ledge, then pop into the air
			local m = S.mantle
			m.t += dt
			local pos = m.a:Lerp(m.mid, smooth(m.t / m.dur))
			if not ANCHOR_HOLD then
				root.AssemblyLinearVelocity = Vector3.zero
			end
			root.CFrame = CFrame.lookAt(pos, pos - m.n)
			if m.t >= m.dur then
				releaseHold(root)
				-- vertical speed that carries the root to standing height plus a margin, from the real gravity
				local vy = math.clamp(math.sqrt(2 * workspace.Gravity * (m.b.Y - pos.Y + 0.7)), 20, 90)
				root.AssemblyLinearVelocity = V3(0, vy, 0)
				S.launch = { n = m.n, c = m.c, ledgeY = m.ledgeY, standH = m.standH, t = 0 }
				S.state, S.mantle, S.hang = "launch", nil, nil
				S.flash = { kind = "hop", t = 0, dur = 0.45 }
				S.noGrabUntil = now + 0.8
			end
		elseif S.state == "launch" then
			-- rising along the wall: no forward push until the feet are above the ledge (pushing into the wall
			-- would zero the velocity), then push over it until past the landing point
			local L = S.launch
			L.t += dt
			local v = root.AssemblyLinearVelocity
			local feetY = root.Position.Y - L.standH
			local pastC = (root.Position - L.c):Dot(-L.n) >= 0
			local fwd = (feetY > L.ledgeY - 0.3 and not pastC) and MANTLE_FWD or 0
			root.AssemblyLinearVelocity = V3(-L.n.X * fwd, v.Y, -L.n.Z * fwd)
			if (L.t > 0.12 and not air) or L.t > 1 then
				S.state, S.launch = "none", nil
				S.noGrabUntil = now + 0.5
			end
		end

		if S.flash then
			S.flash.t += dt
			if S.flash.t > S.flash.dur then
				S.flash = nil
			end
		end

		-- body animation: pick what the body is doing, then a custom track, the procedural pose, or nothing
		local hv = flat(root.AssemblyLinearVelocity).Magnitude
		local kind, kdur
		if S.state == "run" then
			kind = "run"
		elseif S.state == "hang" then
			kind = "hang"
		elseif S.state == "mantle" then
			kind, kdur = "mantle", S.mantle.dur
		elseif S.flash then
			kind, kdur = S.flash.kind, S.flash.dur
		elseif cfg.sprint.on and hv > 3 and (S.sprintOn or (not air and cfg.sprint.o.always ~= false and hum.MoveDirection.Magnitude > 0.1)) then
			kind = (air and cfg.anim.o.leap ~= false) and "leap" or "sprint"
		end

		if DEBUG and kind and kind ~= S.dbgKind and now - (S.dbgAt or 0) > 1 and S.ctx then
			S.dbgAt = now
			S.ctx.notify(("parkour dbg: %s | joints %d | strength %.2f | anim row %s"):format(
				kind, S.rig and S.rig.n or 0, lerp(0, 1.5, cfg.anim.v), tostring(cfg.anim.on)), Color3.fromRGB(120, 200, 255))
		end
		S.dbgKind = kind

		local usingCustom = false
		if cfg.custom.on then
			usingCustom = setCustom(hum, kind, kdur)
		elseif custom.active then
			stopCustom()
		end

		if usingCustom or not cfg.anim.on then
			applyPose(dt, nil, 1, 10)
		else
			local strength = lerp(0, 1.5, cfg.anim.v)
			local speed = cfg.anim.o.smooth or 10
			local pose, override
			if kind == "run" then
				pose, override = ikRunPose(S.phase, S.run.side, root, S.run, cfg.run.o) or runPose(S.phase, S.run.side, cfg.run.o), true
			elseif kind == "hang" then
				pose, override = ikHangPose(now, root, S.hang) or hangPose(now), true
			elseif kind == "mantle" then
				local p = S.mantle.t / S.mantle.dur
				pose, override = ikMantlePose(p, root, S.mantle) or mantlePose(p), true
			elseif kind == "land" then
				-- layered on the game's animation (no override), so its walk / run cycle keeps playing underneath
				local f = S.flash
				pose = landPose(f.power * (1 - f.t / f.dur) ^ 1.5)
			elseif kind == "hop" then
				pose, override = ikHopPose(root, S.flash) or hopPose(), true
			elseif kind == "kick" then
				pose, override = kickPose(), true
			elseif kind == "leap" then
				pose = leapPose(cfg.sprint.o.lean or 1, cfg.sprint.o.pump or 1)
			elseif kind == "sprint" then
				S.phase += dt * hv * 0.55 * (cfg.sprint.o.cadence or 1)
				pose = sprintPose(S.phase, cfg.sprint.o)
				-- layered on top of the game's run cycle the offsets drown in it, so by default it takes over
				override = cfg.sprint.o.replace ~= false
			end
			if override then
				stopTracks(hum) -- the game's animation would fight the pose
			end
			-- A running cycle swings several times a second. Smoothing it at the normal rate flattens it to a
			-- fraction of its size (legs looked still), so cycles are written almost directly and only their
			-- fade in / out is eased.
			local cyclic = kind == "run" or kind == "sprint"
			S.cyc += ((cyclic and 1 or 0) - S.cyc) * (1 - math.exp(-dt * 8))
			if cyclic then
				applyPose(dt, pose, strength * S.cyc, 80)
			else
				applyPose(dt, pose, strength, speed)
			end
		end
	end,

	destroy = function()
		local root = Util.rootOf(S.char)
		local hum = S.char and S.char:FindFirstChildOfClass("Humanoid")
		stopCustom(0)
		releaseHold(root)
		if S.autoRotate ~= nil and hum then
			hum.AutoRotate = S.autoRotate
		end
		if S.sprintOn and hum and S.sprintSet and near(hum.WalkSpeed, S.sprintSet) then
			hum.WalkSpeed = S.origWS
		end
		if S.rig then
			restoreRig(S.rig)
		end
		local cam = workspace.CurrentCamera
		if cam and S.fovLast and S.fovBase and math.abs(cam.FieldOfView - S.fovLast) < 1e-3 then
			cam.FieldOfView = S.fovBase
		end
		if S.camBound then
			pcall(RunService.UnbindFromRenderStep, RunService, CAM_BIND)
			S.camBound = false
		end
		for _, c in ipairs(S.conns) do
			c:Disconnect()
		end
		table.clear(S.conns)
		resetState()
	end,
}

return Movement
