-- ModuleScript: Movement
-- Parkour for your own character: sprint, wall run, wall jump, wall hop, ledge hang and mantle, each with a
-- body animation. Everything is client side: it moves YOUR character, other players see it because the
-- server replicates your position.
--
--   Movement.tab       the "Parkour" tab (rows + right-click options), picked up by Games.lua
--   Movement.features  { id = { set, step, ... } }, merged into Functionality's registry
--
-- How it works
--   One controller (pkCore) runs every frame and owns a tiny state machine: none / run / hang / mantle.
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
--
-- Animations: no asset ids are used. The character's Motor6D C0 values are offset by smoothed angles, which
-- the Animator never overwrites. Sprint is added on top of the game's run animation; wall run, hang, mantle
-- and the kick / hop poses stop the game's animation tracks and pose the body themselves. R15 only (R6
-- characters still get the movement, just no pose).
-- The pose angles are written from the R15 rig's joint axes (arms forward = +X, torso forward lean = -X,
-- knees bend = -X) and were NOT tested on a live character: if a limb swings the wrong way, flip the sign in
-- the pose function (sprintPose / runPose / hangPose / mantlePose / kickPose / hopPose).
--
-- Extra poses (Parkour animations row): "leap" while sprinting through the air and a "landing" crouch after a
-- hard fall (scaled by impact speed). Both are layered on top of the game's own animation instead of replacing
-- it, so walking / running keeps animating. Each has its own toggle in the row's right-click menu.
--
-- Hand IK (Parkour animations > "Hands reach ledge / wall"): while hanging both hands are placed on the ledge
-- top, while mantling they stay planted until the body is up, while wall running the wall-side hand presses on
-- the wall and a wall hop slaps both hands on it. The hang height comes from the rig's own arm length.
-- Custom animation IDs: the "Custom animation IDs" row takes one id per move (numbers only). A loaded track
-- replaces that move's procedural pose. Roblox only lets a game play animations that its owner owns (or Roblox
-- itself published), so most marketplace ids from other creators will not load; the menu then falls back to
-- the procedural pose and says so after 2 s. One-shot moves (wall jump, hop, mantle, landing) are stretched
-- to the move's length.
--
-- Anchoring: while hanging and mantling the root part is Anchored (released when you drop, mantle ends, the
-- row is turned off or the menu is destroyed). Games with movement anti-cheat may rubber-band any of this.

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
local COOLDOWN = 0.35 -- seconds before a wall can be used again after a wall run / jump
local CAM_BIND = "FMenuParkourCam"
-- true  = the root part is Anchored while hanging / mantling (stable, but a client can't replicate an anchored part,
--         so other players may see you frozen until you let go).
-- false = nothing is anchored: velocity is zeroed and the CFrame re-set every frame instead (replicates normally,
--         may jitter slightly). Flip this if people report you "freezing" on ledges.
local ANCHOR_HOLD = true

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
		{ type = "slider", key = "fovKick", label = "FOV kick", min = 0, max = 25, step = 1, unit = " deg", default = 8 },
	} },
	{ header = "Walls" },
	{ id = "pkWallRun", label = "Wall run", slider = "Max run time", value = 45, on = false, fmt = function(v) return ("%.1fs"):format(lerp(0.5, 4, v)) end, opts = {
		{ type = "slider", key = "speed", label = "Run speed", min = 14, max = 60, step = 1, unit = " sp", default = 30 },
		{ type = "slider", key = "tilt", label = "Camera tilt", min = 0, max = 20, step = 1, unit = " deg", default = 8 },
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
	} },
	{ header = "Visuals" },
	{ id = "pkAnim", label = "Parkour animations", slider = "Pose strength", value = 67, on = true, fmt = Util.range(0, 150, "%"), opts = {
		{ type = "slider", key = "smooth", label = "Smoothing", min = 4, max = 20, step = 1, default = 10 },
		{ type = "toggle", key = "landing", label = "Landing crouch", default = true },
		{ type = "toggle", key = "leap", label = "Sprint leap pose", default = true },
		{ type = "toggle", key = "ik", label = "Hands reach ledge / wall (IK)", default = true },
	} },
	{ id = "pkCustom", label = "Custom animation IDs", slider = "Unused", value = 0, on = false, opts = {
		{ type = "text", key = "idSprint", label = "Sprint", placeholder = "animation id (numbers)", default = "" },
		{ type = "text", key = "idLeap", label = "Sprint leap", placeholder = "animation id", default = "" },
		{ type = "text", key = "idRun", label = "Wall run", placeholder = "animation id", default = "" },
		{ type = "text", key = "idKick", label = "Wall jump", placeholder = "animation id", default = "" },
		{ type = "text", key = "idHop", label = "Wall hop", placeholder = "animation id", default = "" },
		{ type = "text", key = "idHang", label = "Ledge hang", placeholder = "animation id", default = "" },
		{ type = "text", key = "idMantle", label = "Mantle", placeholder = "animation id", default = "" },
		{ type = "text", key = "idLand", label = "Landing", placeholder = "animation id", default = "" },
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
	char = nil, rig = nil, rigRetry = 0, warnedRig = false,
	state = "none", -- none / run / hang / mantle
	run = nil, hang = nil, mantle = nil, flash = nil,
	noWallUntil = 0, noGrabUntil = 0, lastRunPart = nil,
	airJumps = 0, hops = 0,
	wasAir = false, fallV = 0, -- landing detection: was airborne last frame, fastest fall speed of this air time
	sprintOn = false, sprintSet = nil, origWS = 16, phase = 0,
	autoRotate = nil, anchored = false,
	roll = 0, fov = 0, fovBase = nil, fovLast = nil,
	conns = {}, ctx = nil, camBound = false,
}

local function resetState()
	S.state, S.run, S.hang, S.mantle, S.flash = "none", nil, nil, nil, nil
	S.anchored, S.sprintOn, S.sprintSet, S.autoRotate = false, false, nil, nil
	S.airJumps, S.hops, S.lastRunPart = 0, 0, nil
	S.wasAir, S.fallV = false, 0
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
	-- geometry for the hand IK, measured from this character's own (possibly scaled) rig
	local root, torso, rs = char:FindFirstChild("HumanoidRootPart"), char:FindFirstChild("UpperTorso"), rig.joints.RightShoulder
	if root and torso and rs and rig.joints.LeftShoulder then
		local ua, la, hd = char:FindFirstChild("RightUpperArm"), char:FindFirstChild("RightLowerArm"), char:FindFirstChild("RightHand")
		rig.torsoRel = root.CFrame:ToObjectSpace(torso.CFrame)
		rig.armLen = (ua and ua.Size.Y or 1.2) + (la and la.Size.Y or 1.1) + (hd and hd.Size.Y * 0.5 or 0.2)
		rig.hangDrop = math.clamp((rig.torsoRel * rs.c0).Position.Y + rig.armLen * 0.93, 2.5, 4.5) -- root height below the ledge
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
				j.m.C0 = j.c0 * j.curR * CFrame.Angles(j.cur.X, j.cur.Y, j.cur.Z)
				j.dirty = true
			elseif t or j.dirty then -- settled joints with no target cost nothing
				j.cur = j.cur:Lerp((t or Vector3.zero) * strength, k)
				j.curR = j.curR:Lerp(ident, k)
				local _, ang = j.curR:ToAxisAngle()
				if ang < 1e-3 then
					j.curR = ident
				end
				if j.cur.Magnitude > 1e-3 or ang >= 1e-3 then
					j.m.C0 = j.c0 * j.curR * CFrame.Angles(j.cur.X, j.cur.Y, j.cur.Z)
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
local function sprintPose(phase, lean, pump)
	local t = {}
	local s = math.sin(phase)
	add(t, "Waist", -0.3 * lean)
	add(t, "Neck", 0.2 * lean)
	add(t, "RightElbow", 1.2 * pump)
	add(t, "LeftElbow", 1.2 * pump)
	add(t, "RightShoulder", s * 0.7 * pump)
	add(t, "LeftShoulder", -s * 0.7 * pump)
	add(t, "RightHip", -s * 0.5 * pump)
	add(t, "LeftHip", s * 0.5 * pump)
	add(t, "RightKnee", -0.9 * math.max(0, s) * pump)
	add(t, "LeftKnee", -0.9 * math.max(0, -s) * pump)
	return t
end

-- side = +1 wall on the right, -1 wall on the left
local function runPose(phase, side)
	local t = {}
	local s = math.sin(phase * 1.4)
	add(t, "Waist", -0.15, 0, 0.35 * side) -- top leans away from the wall
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
	add(t, "RightHip", -s * 1.0)
	add(t, "LeftHip", s * 1.0)
	add(t, "RightKnee", -1.0 * math.max(0, s))
	add(t, "LeftKnee", -1.0 * math.max(0, -s))
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
-- hand IK: the shoulder is rotated to point the arm at a world position, the elbow bends by how much slack the
-- arm has. Joint-frame based (no assumed axes) except the elbow, which bends around +X like the other poses.
---------------------------------------------------------------------
local function armIK(t, rig, root, side, target)
	local j = rig.joints[side .. "Shoulder"]
	if not (j and rig.torsoRel and target) then
		return false
	end
	local frame = root.CFrame * rig.torsoRel * j.c0
	local to = target - frame.Position
	local d = to.Magnitude
	if d < 0.05 then
		return false
	end
	local dir = frame:VectorToObjectSpace(to / d)
	local down = V3(0, -1, 0)
	local dot = math.clamp(down:Dot(dir), -1, 1)
	local axis = down:Cross(dir)
	t[side .. "Shoulder"] = axis.Magnitude < 1e-4 and (dot > 0 and CFrame.new() or CFrame.Angles(math.pi, 0, 0))
		or CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
	t[side .. "Elbow"] = V3(math.min(math.acos(math.clamp(d / rig.armLen, 0, 1)) * 2, 0.8), 0, 0)
	return true
end

local function ikReady()
	local rig = S.rig
	return rig and rig.torsoRel and cfg.anim.o.ik ~= false and rig or nil
end

-- both hands on a point, spread sideways along `right`
local function reachBoth(t, rig, root, point, right, spread)
	return armIK(t, rig, root, "Right", point + right * spread) and armIK(t, rig, root, "Left", point - right * spread)
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
	return reachBoth(t, rig, root, h.grip, right.Unit, 0.65) and t or nil
end

-- hands stay planted on the ledge while the body is pulled up, then the euler pose pushes off it
local function ikMantlePose(p, root, m)
	local rig = ikReady()
	if not (rig and m.grip) or p >= 0.6 then
		return nil
	end
	local t = mantlePose(p)
	local right = (-m.n):Cross(UP)
	if right.Magnitude < 0.01 then
		return nil
	end
	return reachBoth(t, rig, root, m.grip, right.Unit, 0.65) and t or nil
end

-- the hand on the wall side is pressed against the wall
local function ikRunPose(phase, side, root, r)
	local rig = ikReady()
	if not rig then
		return nil
	end
	local t = runPose(phase, side)
	local point = root.Position - r.normal * (r.dist or REACH) + r.tangent * 0.35 + UP * 0.4
	return armIK(t, rig, root, side > 0 and "Right" or "Left", point) and t or nil
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
-- custom animation ids (Custom animation IDs row): a loaded track replaces the procedural pose of that move
---------------------------------------------------------------------
local KEYMAP = { run = "idRun", hang = "idHang", mantle = "idMantle", kick = "idKick", hop = "idHop", land = "idLand", sprint = "idSprint", leap = "idLeap" }
local LOOPED = { run = true, hang = true, sprint = true, leap = true }
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
		S.char, S.rig, S.rigRetry = char, nil, 0
	end
	local root = Util.rootOf(char)
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if char and hum and (not S.rig or (S.rig.n == 0 and os.clock() >= S.rigRetry and hum.RigType == Enum.HumanoidRigType.R15)) then
		S.rig = buildRig(char, hum)
		S.rigRetry = os.clock() + 0.5
		if hum.RigType ~= Enum.HumanoidRigType.R15 and not S.warnedRig and S.ctx then
			S.warnedRig = true
			S.ctx.notify("parkour: R6 character, movement works but there are no body poses", Color3.fromRGB(255, 214, 64))
		end
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
	S.state, S.run, S.hang, S.mantle, S.flash = "none", nil, nil, nil, nil
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

local function startMantle(root, hum)
	local h = S.hang
	if not h then
		return
	end
	local standH = hum.HipHeight + root.Size.Y / 2
	local b = V3(h.cf.Position.X, h.ledgeY + standH + 0.35, h.cf.Position.Z)
	S.state = "mantle"
	-- step forward onto the ledge, but only as far as there is floor to stand on (thin ledges / railings)
	local c = b - h.n * 1.8
	if not workspace:Raycast(c + UP * 2, V3(0, -(standH + 4), 0), Util.rayParams()) then
		c = b - h.n * 0.9
	end
	S.mantle = { t = 0, dur = 0.6 / (cfg.mantle.o.speed or 1), a = root.Position, b = b, c = c, n = h.n, grip = h.grip }
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
	local target = V3(hit.Position.X, ledgeY - drop, hit.Position.Z) + n * 1.0
	local grip = V3(hit.Position.X, ledgeY + 0.05, hit.Position.Z) - n * 0.25 -- where the hands go
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
	}
	S.airJumps, S.hops = 0, 0
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
			elseif S.sprintSet and hum.WalkSpeed ~= S.sprintSet then
				S.origWS = hum.WalkSpeed -- the game (or the Speed row) changed it: that is the new normal speed
			end
			local target = math.max(S.origWS, lerp(16, 60, cfg.sprint.v))
			if hum.WalkSpeed ~= target then
				hum.WalkSpeed = target
			end
			S.sprintSet = target
		elseif S.sprintOn then
			S.sprintOn = false
			if S.sprintSet and hum.WalkSpeed == S.sprintSet then
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
				local face = CFrame.lookAt(root.Position, root.Position + tg)
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
			local m = S.mantle
			m.t += dt
			local p = m.t / m.dur
			local pos
			if p < 0.6 then
				pos = m.a:Lerp(m.b, smooth(p / 0.6))
			else
				pos = m.b:Lerp(m.c, smooth((p - 0.6) / 0.4))
			end
			if not ANCHOR_HOLD then
				root.AssemblyLinearVelocity = Vector3.zero
			end
			root.CFrame = CFrame.lookAt(pos, pos - m.n)
			if p >= 1 then
				releaseHold(root)
				root.AssemblyLinearVelocity = -m.n * 10
				S.state, S.mantle, S.hang = "none", nil, nil
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
		elseif S.sprintOn and hv > RUN_MIN_SPEED then
			kind = (air and cfg.anim.o.leap ~= false) and "leap" or "sprint"
		end

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
				pose, override = ikRunPose(S.phase, S.run.side, root, S.run) or runPose(S.phase, S.run.side), true
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
				S.phase += dt * hv * 0.55
				pose = sprintPose(S.phase, cfg.sprint.o.lean or 1, cfg.sprint.o.pump or 1)
			end
			if override then
				stopTracks(hum) -- the game's animation would fight the pose
			end
			applyPose(dt, pose, strength, speed)
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
		if S.sprintOn and hum and S.sprintSet and hum.WalkSpeed == S.sprintSet then
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
