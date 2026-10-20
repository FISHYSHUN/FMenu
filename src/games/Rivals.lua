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
--   Wireframe viewmodel  hides your gun / arms and draws the edges of every part instead (blender style).
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

local CHEST = { "UpperTorso", "Torso", "HumanoidRootPart" }

local shared = { fov = 150, team = true, visible = true, part = "head", lead = 0 }
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
		{ id = "rvAim", label = "Aim assist", slider = "Pull strength", value = 40, on = false, fmt = range(0, 100, "%"), opts = {
			Util.modeOption(),
			holdOption(),
			{ type = "slider", key = "dead", label = "Dead zone", min = 0.1, max = 3, step = 0.1, unit = " deg", default = 0.4 },
			{ type = "slider", key = "falloff", label = "Edge falloff", min = 0, max = 1, step = 0.05, pct = true, default = 0.6 },
		} },
		{ id = "rvLock", label = "Aim lock", slider = "Smoothing (0 = snap)", value = 0, on = false, fmt = function(v) return v == 0 and "snap" or ("%d%%"):format(v) end, opts = { Util.modeOption(), holdOption() } },
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
		{ header = "Visuals" },
		{ id = "rvWire", label = "Wireframe viewmodel", slider = "Unused", value = 0, on = false, opts = {
			{ type = "choice", key = "parts", label = "Draw", choices = { "All", "Weapon only", "Hands only" }, default = "All" },
			{ type = "slider", key = "thickness", label = "Line thickness", min = 1, max = 4, step = 1, unit = "x", default = 1 },
			{ type = "slider", key = "alpha", label = "Opacity", min = 0.1, max = 1, step = 0.05, pct = true, default = 1 },
			{ type = "hue", key = "hue", label = "Hue", default = 0.55 },
			{ type = "slider", key = "sat", label = "Saturation", min = 0, max = 1, step = 0.05, pct = true, default = 0.85 },
			{ type = "toggle", key = "rainbow", label = "Rainbow", default = false },
			{ type = "slider", key = "rainbowSpeed", label = "Rainbow speed", min = 0.1, max = 2, step = 0.1, unit = "x", default = 0.4 },
			{ type = "toggle", key = "mesh", label = "Real mesh edges", default = true },
			{ type = "toggle", key = "onTop", label = "Show through walls", default = false },
			{ type = "toggle", key = "hide", label = "Hide real model", default = true },
		} },
		{ id = "rvHighlight", label = "Highlight viewmodel", slider = "Unused", value = 0, on = false, opts = {
			{ type = "slider", key = "fill", label = "Fill opacity", min = 0, max = 1, step = 0.05, pct = true, default = 0 },
			{ type = "slider", key = "outline", label = "Outline opacity", min = 0.1, max = 1, step = 0.05, pct = true, default = 1 },
			{ type = "hue", key = "hue", label = "Hue", default = 0.55 },
			{ type = "slider", key = "sat", label = "Saturation", min = 0, max = 1, step = 0.05, pct = true, default = 0.85 },
			{ type = "toggle", key = "rainbow", label = "Rainbow", default = false },
			{ type = "slider", key = "rainbowSpeed", label = "Rainbow speed", min = 0.1, max = 2, step = 0.1, unit = "x", default = 0.4 },
			{ type = "toggle", key = "onTop", label = "Show through walls", default = true },
			{ type = "toggle", key = "hide", label = "Hide real model", default = true },
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
	local function aimHeld()
		local o = (aim.lock and aim.lockCfg) or aim.assistCfg or {}
		local hold = o.hold or "Right mouse"
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

-- viewmodel helpers shared by Wireframe viewmodel and Highlight viewmodel.
--   Where the viewmodel lives is a guess: any model without a Humanoid under the camera, plus workspace
--   models whose name contains one of VM_NAMES. Hands are told apart from the weapon by part / parent names
--   containing one of HAND_WORDS. Both lists are FILL spots: dump the real names once and hardcode them.
local VM = { refs = setmetatable({}, { __mode = "k" }), orig = setmetatable({}, { __mode = "k" }) }
local VM_NAMES = { "viewmodel", "view_model", "arms" } -- FILL
local HAND_WORDS = { "arm", "hand", "glove", "sleeve", "finger", "wrist" } -- FILL

function VM.models()
	local list = {}
	local function consider(m)
		if m:IsA("Model") and not m:FindFirstChildOfClass("Humanoid") and not Players:GetPlayerFromCharacter(m) then
			list[#list + 1] = m
		end
	end
	local cam = workspace.CurrentCamera
	if cam then
		for _, c in ipairs(cam:GetChildren()) do
			consider(c)
		end
	end
	for _, c in ipairs(workspace:GetChildren()) do
		local n = c.Name:lower()
		for _, key in ipairs(VM_NAMES) do
			if n:find(key, 1, true) then
				consider(c)
				break
			end
		end
	end
	return list
end

-- a part we may draw: visible, or hidden by us (so the other row still sees it)
function VM.candidate(part)
	return VM.orig[part] ~= nil or part.Transparency < 0.99
end

function VM.isHand(part, model)
	local p = part
	while p and p ~= model.Parent do
		local n = p.Name:lower()
		for _, w in ipairs(HAND_WORDS) do
			if n:find(w, 1, true) then
				return true
			end
		end
		p = p.Parent
	end
	return false
end

-- hide / show are reference counted so both rows can hide the same part without fighting
function VM.hide(part)
	local r = VM.refs[part]
	if not r then
		VM.orig[part] = part.Transparency
		r = 0
	end
	VM.refs[part] = r + 1
	part.Transparency = 1
end

function VM.show(part)
	local r = VM.refs[part]
	if not r then
		return
	end
	if r <= 1 then
		VM.refs[part] = nil
		if part.Parent then
			part.Transparency = VM.orig[part] or 0
		end
		VM.orig[part] = nil
	else
		VM.refs[part] = r - 1
	end
end

-- the game may reset transparency: keep everything we hid hidden
function VM.keep()
	for part in pairs(VM.refs) do
		if part.Transparency ~= 1 then
			part.Transparency = 1
		end
	end
end

local function vmColor(c)
	local sat = c.sat or 0.85
	if c.rainbow then
		return Color3.fromHSV((os.clock() * (c.rainbowSpeed or 0.4)) % 1, sat, 1)
	end
	return Color3.fromHSV(c.hue or 0.55, sat, 1)
end

-- wireframe viewmodel: parts are drawn as lines (WireframeHandleAdornment).
--   Real mesh edges: tries AssetService:CreateEditableMeshAsync on every MeshPart and draws its triangle
--   edges. Executors that block that (or meshes it cannot read) fall back to the 12 edges of the part's box.
--   Thickness draws 1-4 copies nudged a hair apart, there is no real line width on this adornment.
do
	local AssetService = game:GetService("AssetService")
	local MAX_TRIS = 800 -- per mesh, triangles are skipped evenly past this
	local OFFS = { Vector3.new(0, 0, 0), Vector3.new(1, 1, 1), Vector3.new(-1, -1, -1), Vector3.new(1, -1, 1) }
	local STEP = 0.006 -- studs between copies

	local enabled, cfg, acc, busy, reported = false, {}, 0, false, false
	local wires = {} -- part -> { adorns, sig, hidden }
	local meshData = {} -- MeshId -> list of { v1, v2, v3 } or false
	local folder

	local function getFolder()
		local cam = workspace.CurrentCamera
		if folder and folder.Parent == cam then
			return folder
		end
		if folder then
			pcall(folder.Destroy, folder)
		end
		folder = Instance.new("Folder")
		folder.Name = "FMenuWire"
		folder.Parent = cam
		return folder
	end

	local function drop(part)
		local rec = wires[part]
		if not rec then
			return
		end
		wires[part] = nil
		for _, w in ipairs(rec.adorns) do
			w:Destroy()
		end
		if rec.hidden then
			VM.show(part)
		end
	end

	local function dropAll()
		for part in pairs(wires) do
			drop(part)
		end
	end

	local function meshTris(part)
		local id = part.MeshId
		if meshData[id] ~= nil then
			return meshData[id] or nil
		end
		local ok, em = pcall(function()
			return AssetService:CreateEditableMeshAsync(Content.fromUri(id))
		end)
		if not ok or not em then
			meshData[id] = false
			return nil
		end
		local tris = {}
		local ok2 = pcall(function()
			local all = em:GetTriangles()
			local stride = math.max(1, math.ceil(#all / MAX_TRIS))
			for i = 1, #all, stride do
				local a, b, c = em:GetTriangleVertices(all[i])
				tris[#tris + 1] = { em:GetPosition(a), em:GetPosition(b), em:GetPosition(c) }
			end
		end)
		pcall(em.Destroy, em)
		meshData[id] = (ok2 and #tris > 0) and tris or false
		return meshData[id] or nil
	end

	local function drawBox(w, size)
		local h = size / 2
		local function c(x, y, z)
			return Vector3.new(x * h.X, y * h.Y, z * h.Z)
		end
		w:AddPath({ c(-1, -1, -1), c(1, -1, -1), c(1, -1, 1), c(-1, -1, 1) }, true)
		w:AddPath({ c(-1, 1, -1), c(1, 1, -1), c(1, 1, 1), c(-1, 1, 1) }, true)
		w:AddLine(c(-1, -1, -1), c(-1, 1, -1))
		w:AddLine(c(1, -1, -1), c(1, 1, -1))
		w:AddLine(c(1, -1, 1), c(1, 1, 1))
		w:AddLine(c(-1, -1, 1), c(-1, 1, 1))
	end

	local function build(part)
		local tris, k
		if cfg.mesh ~= false and part:IsA("MeshPart") and part.MeshId ~= "" then
			tris = meshTris(part)
			local ms = part.MeshSize
			if tris and ms.X > 0 and ms.Y > 0 and ms.Z > 0 then
				k = part.Size / ms
			else
				tris = nil
			end
		end
		local adorns = {}
		for i = 1, math.clamp(math.floor(cfg.thickness or 1), 1, #OFFS) do
			local w = Instance.new("WireframeHandleAdornment")
			w.Adornee = part
			w.CFrame = CFrame.new(OFFS[i] * STEP)
			w.Parent = getFolder()
			if tris then
				for _, t in ipairs(tris) do
					w:AddPath({ t[1] * k, t[2] * k, t[3] * k }, true)
				end
			else
				drawBox(w, part.Size)
			end
			adorns[#adorns + 1] = w
		end
		return adorns
	end

	local function scan(ctx)
		local sig = tostring(math.floor(cfg.thickness or 1)) .. "|" .. tostring(cfg.mesh ~= false)
		local filter = cfg.parts or "All"
		local seen = {}
		for _, model in ipairs(VM.models()) do
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and VM.candidate(d) then
					local hand = VM.isHand(d, model)
					if filter == "All" or (filter == "Hands only" and hand) or (filter == "Weapon only" and not hand) then
						seen[d] = true
						local rec = wires[d]
						if rec and rec.sig ~= sig then
							drop(d)
							rec = nil
						end
						if not rec then
							wires[d] = { adorns = build(d), sig = sig, hidden = false }
						end
					end
				end
			end
		end
		for part in pairs(wires) do
			if not seen[part] or not part:IsDescendantOf(workspace) then
				drop(part)
			end
		end
		local wantHide = cfg.hide ~= false
		local n = 0
		for part, rec in pairs(wires) do
			n += 1
			if wantHide and not rec.hidden then
				VM.hide(part)
				rec.hidden = true
			elseif not wantHide and rec.hidden then
				VM.show(part)
				rec.hidden = false
			end
		end
		if not enabled or reported then
			return
		end
		if n > 0 then
			reported = true
			ctx.notify(("wireframe: %d parts"):format(n), Color3.fromRGB(72, 214, 134))
		else
			local names = {}
			local cam = workspace.CurrentCamera
			for _, c in ipairs(cam and cam:GetChildren() or {}) do
				names[#names + 1] = c.Name .. "(" .. c.ClassName .. ")"
			end
			print("[FMenu] wireframe: no viewmodel found. camera children: " .. table.concat(names, ", "))
		end
	end

	features.rvWire = {
		set = function(on, _v, ctx, o)
			enabled, cfg = on, o
			acc = 1
			reported = false
			if not on then
				dropAll()
			end
		end,
		step = function(dt, ctx)
			if not enabled then
				return
			end
			VM.keep()
			local color, alpha, top = vmColor(cfg), 1 - (cfg.alpha or 1), cfg.onTop == true
			for _, rec in pairs(wires) do
				for _, w in ipairs(rec.adorns) do
					w.Color3 = color
					w.Transparency = alpha
					w.AlwaysOnTop = top
				end
			end
			acc += dt
			if acc >= 0.5 and not busy then -- picks up weapon swaps (CreateEditableMeshAsync can yield, hence the thread)
				acc = 0
				busy = true
				task.spawn(function()
					pcall(scan, ctx)
					busy = false
				end)
			end
		end,
		destroy = function()
			enabled = false
			dropAll()
			if folder then
				pcall(folder.Destroy, folder)
				folder = nil
			end
		end,
	}
end

-- highlight viewmodel: one Highlight per viewmodel model. Fill 0 = outline only. With "Hide real model" the
-- parts go fully transparent so only the outline is left (a Highlight still draws on transparent parts, didn't
-- check it in Rivals: if the outline vanishes when hidden, turn "Hide real model" off).
do
	local enabled, cfg, acc = false, {}, 0
	local hl = {} -- model -> { h, parts = { [part] = true } }
	local folder

	local function getFolder()
		local cam = workspace.CurrentCamera
		if folder and folder.Parent == cam then
			return folder
		end
		if folder then
			pcall(folder.Destroy, folder)
		end
		folder = Instance.new("Folder")
		folder.Name = "FMenuHighlight"
		folder.Parent = cam
		return folder
	end

	local function unhide(rec)
		for part in pairs(rec.parts) do
			VM.show(part)
		end
		table.clear(rec.parts)
	end

	local function drop(model)
		local rec = hl[model]
		if not rec then
			return
		end
		hl[model] = nil
		rec.h:Destroy()
		unhide(rec)
	end

	local function dropAll()
		for model in pairs(hl) do
			drop(model)
		end
	end

	local function scan()
		local seen = {}
		local wantHide = cfg.hide ~= false
		for _, model in ipairs(VM.models()) do
			seen[model] = true
			local rec = hl[model]
			if not rec then
				local h = Instance.new("Highlight")
				h.Adornee = model
				h.Parent = getFolder()
				rec = { h = h, parts = {} }
				hl[model] = rec
			end
			if wantHide then
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") and not rec.parts[d] and VM.candidate(d) then
						VM.hide(d)
						rec.parts[d] = true
					end
				end
			else
				unhide(rec)
			end
		end
		for model, rec in pairs(hl) do
			if not seen[model] or not model:IsDescendantOf(workspace) then
				drop(model)
			end
		end
	end

	features.rvHighlight = {
		set = function(on, _v, _c, o)
			enabled, cfg = on, o
			acc = 1
			if not on then
				dropAll()
			end
		end,
		step = function(dt)
			if not enabled then
				return
			end
			VM.keep()
			local color = vmColor(cfg)
			local mode = cfg.onTop ~= false and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
			for _, rec in pairs(hl) do
				local h = rec.h
				h.FillColor, h.OutlineColor = color, color
				h.FillTransparency = 1 - (cfg.fill or 0)
				h.OutlineTransparency = 1 - (cfg.outline or 1)
				h.DepthMode = mode
			end
			acc += dt
			if acc >= 0.5 then -- picks up weapon swaps
				acc = 0
				pcall(scan)
			end
		end,
		destroy = function()
			enabled = false
			dropAll()
			if folder then
				pcall(folder.Destroy, folder)
				folder = nil
			end
		end,
	}
end

return Rivals
