-- ModuleScript: Functionality
-- Feature registry. A feature is keyed by the same id a row uses in Games.lua:
--   { init = function(ctx, hudGui) end,   -- optional, runs once (build hud elements, snapshot originals)
--     set  = function(enabled, value, ctx, opts) end,  -- runs on toggle, slider or option change
--                                                      -- (value 0-100, opts = the right-click menu values by key, a live table)
--     step = function(dt, ctx) end,        -- optional, runs every RenderStepped
--     destroy = function() end }           -- optional, extra cleanup (set(false) is already called for you)
-- ctx = { ui, animations, profileName, notify(text, color?), hud }
-- Games register their own features through Functionality.register.
--
-- Everything in here is universal (works in any game). Game specific stuff lives in src/games/.

local import = ...
local Util = import("Util")
local ESP = import("ESP")
local Defense = import("Defense")
local Troll = import("Troll")
local Vehicle = import("Vehicle")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local lp = Players.LocalPlayer
local make, lerp = Util.make, Util.lerp

local Functionality = {}

local features = {}
local state = {} -- id -> { on, value } (last values applied, used to undo everything on destroy)
local ctx = nil
local hudGui = nil
local toasts = nil
local conn = nil
local hudConns = {}
local positions = {} -- hud key -> Vector2 (where the user dragged it), survives toggling
local dragging = nil -- { info, key, input, start, from }
local hudLocked, notifyOn = false, true
local huds = {} -- every draggable label, so they can be pulled back on screen after a resize

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function screenSize()
	local s = hudGui and hudGui.AbsoluteSize or Vector2.zero
	if s.X <= 0 or s.Y <= 0 then
		local cam = workspace.CurrentCamera
		s = cam and cam.ViewportSize or Vector2.new(1280, 720)
	end
	return s
end

local function clampPos(obj, p)
	local vp, sz = screenSize(), obj.AbsoluteSize
	return Vector2.new(
		math.clamp(p.X, 0, math.max(0, vp.X - sz.X)),
		math.clamp(p.Y, 0, math.max(0, vp.Y - sz.Y))
	)
end

-- default spot of a HUD label: stacked under Roblox's top bar on the left or right edge
function Functionality.hudPos(side, row, width)
	local x = 12
	if side == "right" then
		x = screenSize().X - (width or 100) - 12
	end
	return Vector2.new(x, GuiService:GetGuiInset().Y + 12 + (row or 0) * 28)
end

-- where the user dragged each label, for saving / loading: { key = { x, y } }
function Functionality.getPositions()
	local out = {}
	for key, p in pairs(positions) do
		out[key] = { math.floor(p.X + 0.5), math.floor(p.Y + 0.5) }
	end
	return out
end

function Functionality.setPositions(t)
	table.clear(positions)
	if type(t) == "table" then
		for key, p in pairs(t) do
			if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" then
				positions[key] = Vector2.new(p[1], p[2])
			end
		end
	end
	for _, info in ipairs(huds) do
		info.place()
	end
end

-- Makes a HUD element draggable (mouse or touch). Until the user moves it, it sits at its default spot
-- (side = "left" | "right", row = how far down the stack); after that it stays where it was put.
function Functionality.draggable(obj, key, side, row)
	obj.Active = true
	obj.AnchorPoint = Vector2.zero
	local info = { obj = obj, side = side or "left", row = row or 0 }
	local function place()
		local p = positions[key] or Functionality.hudPos(info.side, info.row, obj.AbsoluteSize.X)
		p = clampPos(obj, p)
		obj.Position = UDim2.fromOffset(p.X, p.Y)
	end
	place()
	-- text changes resize the label: keep right-side labels flush and everything on screen
	obj:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	obj.InputBegan:Connect(function(input)
		if isPress(input) and not hudLocked then
			-- Delta based: remember where the pointer and the label were when the press started and move the label
			-- by how far the pointer has travelled since. Mixing AbsolutePosition (screen space) with Position
			-- (relative to the HUD gui) is what used to make labels jump away from the cursor.
			dragging = {
				info = info,
				key = key,
				input = input,
				start = Util.pointer(input),
				from = Vector2.new(obj.Position.X.Offset, obj.Position.Y.Offset),
			}
		end
	end)
	info.place = place
	huds[#huds + 1] = info
	return info
end

-- pill-shaped label that fits its text. Builds hudGui children, so only call it from a feature's init.
local function hudLabel(name, color, font)
	local l = make("TextLabel", {
		Name = name,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		BackgroundColor3 = Color3.fromRGB(22, 24, 31),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Font = font or Enum.Font.Code,
		TextSize = 14,
		TextColor3 = color or Color3.fromRGB(236, 238, 244),
		Visible = false,
		Text = "",
	}, hudGui)
	l:SetAttribute("baseColor", l.TextColor3)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, l)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, l)
	make("UISizeConstraint", { MinSize = Vector2.new(72, 22) }, l)
	return l
end

-- text size, background opacity and tint from a HUD row's right-click options (noBg: the caller sets the background)
local function styleHud(label, o, noBg)
	if not label then
		return
	end
	if o.textSize then
		label.TextSize = o.textSize
	end
	if o.bg and not noBg then
		label.BackgroundTransparency = 1 - o.bg
	end
	if o.tint then
		label.TextColor3 = Color3.fromHSV(o.hue or 0, 0.75, 1)
	else
		label.TextColor3 = label:GetAttribute("baseColor") or label.TextColor3
	end
end

-- fps / ping / clock: draggable, start stacked on the right
local function statLabel(name, row)
	local l = hudLabel(name)
	Functionality.draggable(l, name, "right", row)
	return l
end

---------------------------------------------------------------------
-- HUD features
---------------------------------------------------------------------

-- overlay: watermark, value = opacity. Every HUD label below can be dragged anywhere on screen.
do
	local label
	features.overlay = {
		init = function(c)
			label = hudLabel("Overlay", Color3.fromRGB(139, 125, 255), Enum.Font.GothamBold)
			label.Text = "FMenu | " .. c.profileName
			Functionality.draggable(label, "Overlay", "left", 0)
		end,
		set = function(on, v, _c, o)
			label.Visible = on
			label.TextTransparency = 1 - v / 100
			label.BackgroundTransparency = 1 - (o.bg or 0.65) * v / 100
			styleHud(label, o, true)
		end,
	}
end

-- crosshair: value = size (4 to 40 px), options = thickness, opacity, color
do
	local holder, horiz, vert
	features.crosshair = {
		init = function()
			holder = make("Frame", {
				Name = "Crosshair",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(20, 20),
				BackgroundTransparency = 1,
				Visible = false,
			}, hudGui)
			horiz = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0,
			}, holder)
			vert = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0,
			}, holder)
		end,
		set = function(on, v, _c, o)
			holder.Visible = on
			local size = 4 + v * 0.36
			holder.Size = UDim2.fromOffset(size, size)
			local t = o.thickness or 2
			horiz.Size = UDim2.new(1, 0, 0, t)
			vert.Size = UDim2.new(0, t, 1, 0)
			local color = o.tint and Color3.fromHSV(o.hue or 0, 0.85, 1) or Color3.fromRGB(255, 255, 255)
			local transparency = 1 - (o.alpha or 1)
			for _, f in ipairs({ horiz, vert }) do
				f.BackgroundColor3 = color
				f.BackgroundTransparency = transparency
			end
		end,
	}
end

-- fps: value = refresh rate (1 to 10 updates per second)
do
	local label, enabled, interval, acc, frames = nil, false, 0.5, 0, 0
	features.fps = {
		init = function()
			label = statLabel("Fps", 0)
		end,
		set = function(on, v, _c, o)
			enabled = on
			label.Visible = on
			interval = 1 / (1 + 9 * v / 100)
			styleHud(label, o)
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			frames += 1
			if acc >= interval then
				label.Text = ("%d fps"):format(math.floor(frames / acc + 0.5))
				acc, frames = 0, 0
			end
		end,
	}
end

-- ping: server data ping, value = refresh rate (1 to 10 per second)
do
	local label, enabled, interval, acc = nil, false, 0.5, 0
	features.ping = {
		init = function()
			label = statLabel("Ping", 1)
		end,
		set = function(on, v, _c, o)
			enabled = on
			label.Visible = on
			interval = 1 / (1 + 9 * v / 100)
			styleHud(label, o)
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			if acc >= interval then
				acc = 0
				local ok, ms = pcall(function()
					return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
				end)
				label.Text = ok and ("%d ms"):format(math.floor(ms + 0.5)) or "-- ms"
			end
		end,
	}
end

-- clock: local time, value = 24h at 0-49, 12h at 50-100
do
	local label, enabled, twelve, acc = nil, false, false, 1
	features.clock = {
		init = function()
			label = statLabel("Clock", 2)
		end,
		set = function(on, v, _c, o)
			enabled = on
			twelve = v >= 50
			label.Visible = on
			acc = 1
			styleHud(label, o)
		end,
		step = function(dt)
			if not enabled then
				return
			end
			acc += dt
			if acc >= 1 then
				acc = 0
				label.Text = os.date(twelve and "%I:%M:%S %p" or "%H:%M:%S")
			end
		end,
	}
end

-- compact: shrinks the menu itself, value = how much (up to 25%)
features.compact = {
	set = function(on, v, c)
		c.ui:setScale(on and (1 - 0.25 * v / 100) or 1)
	end,
}

---------------------------------------------------------------------
-- player features
---------------------------------------------------------------------

-- speed: value = WalkSpeed 16 to 150
do
	local enabled, target, orig = false, 16, nil
	features.speed = {
		set = function(on, v, _c, o)
			local hum = Util.humanoid()
			if on and not enabled and hum then
				orig = hum.WalkSpeed
			end
			enabled = on
			target = 16 + (lerp(16, 150, v) - 16) * Util.level(o.mode).power -- Mode scales the boost above normal
			if not on and hum then
				hum.WalkSpeed = orig or 16
			end
		end,
		step = function()
			if not enabled then
				return
			end
			local hum = Util.humanoid()
			if hum and hum.WalkSpeed ~= target then
				hum.WalkSpeed = target
			end
		end,
	}
end

-- jump: value = jump power 50 to 300 (jump height 7 to 50 when the game uses JumpHeight)
do
	local enabled, power, height, orig = false, 50, 7.2, nil
	features.jump = {
		set = function(on, v, _c, o)
			local hum = Util.humanoid()
			if on and not enabled and hum then
				orig = { hum.JumpPower, hum.JumpHeight }
			end
			enabled = on
			local p = Util.level(o.mode).power
			power = 50 + (lerp(50, 300, v) - 50) * p
			height = 7.2 + (lerp(7.2, 50, v) - 7.2) * p
			if not on and hum and orig then
				hum.JumpPower, hum.JumpHeight = orig[1], orig[2]
			end
		end,
		step = function()
			if not enabled then
				return
			end
			local hum = Util.humanoid()
			if not hum then
				return
			end
			if hum.UseJumpPower then
				if hum.JumpPower ~= power then
					hum.JumpPower = power
				end
			elseif hum.JumpHeight ~= height then
				hum.JumpHeight = height
			end
		end,
	}
end

-- infjump: jump again in the air
do
	local bag = Util.bag()
	features.infjump = {
		set = function(on)
			bag:clean()
			if on then
				bag:add(UserInputService.JumpRequest:Connect(function()
					local hum = Util.humanoid()
					if hum then
						hum:ChangeState(Enum.HumanoidStateType.Jumping)
					end
				end))
			end
		end,
	}
end

-- noclip: walk through walls
do
	local bag = Util.bag()
	local flipped = {}
	features.noclip = {
		set = function(on)
			bag:clean()
			if on then
				bag:add(RunService.Stepped:Connect(function()
					local char = Util.character()
					if not char then
						return
					end
					for _, p in ipairs(char:GetDescendants()) do
						if p:IsA("BasePart") and p.CanCollide then
							flipped[p] = true
							p.CanCollide = false
						end
					end
				end))
			else
				for p in pairs(flipped) do
					if p.Parent then
						p.CanCollide = true
					end
				end
				table.clear(flipped)
			end
		end,
	}
end

-- fly: WASD + camera direction, Space up, Shift/Ctrl down. value = speed 20 to 200.
-- options: up / down speed multiplier, smoothing (0 = instant, higher = floatier)
do
	local enabled, speed, bv, cfg, cur = false, 60, nil, {}, Vector3.zero
	local function stop()
		if bv then
			bv:Destroy()
			bv = nil
		end
		cur = Vector3.zero
		local hum = Util.humanoid()
		if hum then
			hum.PlatformStand = false
		end
	end
	features.fly = {
		set = function(on, v, _c, o)
			speed = 20 + (lerp(20, 200, v) - 20) * Util.level(o.mode).power
			cfg = o
			if on == enabled then
				return
			end
			enabled = on
			if not on then
				stop()
			end
		end,
		step = function(dt)
			if not enabled then
				return
			end
			local root, hum = Util.root(), Util.humanoid()
			if not root or not hum then
				return
			end
			if not bv or bv.Parent ~= root then
				if bv then
					bv:Destroy()
				end
				bv = make("BodyVelocity", {
					MaxForce = Vector3.new(1e9, 1e9, 1e9),
					Velocity = Vector3.zero,
				}, root)
			end
			hum.PlatformStand = true

			local cam = workspace.CurrentCamera
			local dir = Vector3.zero
			local k = UserInputService
			if k:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
			if k:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
			if k:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
			if k:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
			if dir.Magnitude == 0 and hum.MoveDirection.Magnitude > 0 then
				dir = hum.MoveDirection -- touch / gamepad
			end
			local up = 0
			if k:IsKeyDown(Enum.KeyCode.Space) or hum.Jump then up += 1 end
			if k:IsKeyDown(Enum.KeyCode.LeftShift) or k:IsKeyDown(Enum.KeyCode.LeftControl) then up -= 1 end

			local want = (dir.Magnitude > 0 and dir.Unit * speed or Vector3.zero) + Vector3.yAxis * up * speed * (cfg.vert or 1)
			local smooth = cfg.smooth or 0
			if smooth <= 0 then
				cur = want
			else
				cur = cur:Lerp(want, 1 - math.exp(-dt * (30 - 27 * smooth)))
			end
			bv.Velocity = cur
		end,
	}
end

-- clicktp: hold a key (option) and click to teleport to the clicked spot
do
	local bag = Util.bag()
	local cfg = {}
	local function modifierHeld()
		local k = UserInputService
		local name = cfg.key or "Ctrl"
		if name == "None" then
			return true
		elseif name == "Alt" then
			return k:IsKeyDown(Enum.KeyCode.LeftAlt) or k:IsKeyDown(Enum.KeyCode.RightAlt)
		elseif name == "Shift" then
			return k:IsKeyDown(Enum.KeyCode.LeftShift) or k:IsKeyDown(Enum.KeyCode.RightShift)
		end
		return k:IsKeyDown(Enum.KeyCode.LeftControl) or k:IsKeyDown(Enum.KeyCode.RightControl)
	end
	features.clicktp = {
		set = function(on, _v, _c, o)
			cfg = o
			bag:clean()
			if on then
				local mouse = lp:GetMouse()
				bag:add(UserInputService.InputBegan:Connect(function(input, processed)
					if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
						return
					end
					if not modifierHeld() then
						return
					end
					local root = Util.root()
					if root and mouse.Hit then
						root.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, cfg.lift or 3, 0))
					end
				end))
			end
		end,
	}
end

---------------------------------------------------------------------
-- visual features
---------------------------------------------------------------------

-- esp: highlight + name / distance / health on every other player. value = max distance 100 to 2000.
-- Everything about how it looks comes from the row's right-click options (esp:configure).
do
	local esp
	features.esp = {
		init = function()
			esp = ESP.new({
				maxDistance = 1000,
				resolve = function(plr, char, dist, style)
					if style.hideTeam and Util.isTeammate(plr) then
						return nil
					end
					return ESP.color(plr, char, Color3.fromRGB(255, 90, 90), style), ESP.text(plr, char, dist, nil, style)
				end,
			})
		end,
		set = function(on, v, _c, o)
			esp:configure(o)
			esp:setDistance(lerp(100, 2000, v))
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

-- tracers: line from the bottom / middle / top of the screen to every player. value = thickness 1 to 4
do
	local enabled, thickness, lines = false, 1, {}
	local style = ESP.newStyle()
	local function newLine()
		local f = make("Frame", {
			Name = "Tracer",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(255, 90, 90),
			BorderSizePixel = 0,
			Visible = false,
		}, hudGui)
		lines[#lines + 1] = f
		return f
	end
	features.tracers = {
		set = function(on, v, _c, o)
			ESP.applyStyle(style, o)
			enabled = on
			thickness = lerp(1, 4, v)
			if not on then
				for _, l in ipairs(lines) do
					l.Visible = false
				end
			end
		end,
		step = function()
			if not enabled then
				return
			end
			local cam = workspace.CurrentCamera
			local vp = cam.ViewportSize
			local from = style.tracerFrom
			local origin = Vector2.new(vp.X / 2, from == "Top" and 0 or (from == "Center" and vp.Y / 2 or vp.Y))
			local used = 0
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= lp and Util.isAlive(plr.Character) and not (style.hideTeam and Util.isTeammate(plr)) then
					local root = Util.rootOf(plr.Character)
					if root then
						local p, onScreen = cam:WorldToViewportPoint(root.Position)
						if onScreen then
							used += 1
							local line = lines[used] or newLine()
							local target = Vector2.new(p.X, p.Y)
							local delta = target - origin
							local mid = (origin + target) / 2
							line.Size = UDim2.fromOffset(delta.Magnitude, thickness)
							line.Position = UDim2.fromOffset(mid.X, mid.Y)
							line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
							line.BackgroundColor3 = ESP.color(plr, plr.Character, Color3.fromRGB(255, 90, 90), style)
							line.BackgroundTransparency = 1 - style.alpha
							line.Visible = true
						end
					end
				end
			end
			for i = used + 1, #lines do
				lines[i].Visible = false
			end
		end,
	}
end

-- fov: value = 40 to 120
do
	local original = 70
	features.fov = {
		init = function()
			local cam = workspace.CurrentCamera
			if cam then
				original = cam.FieldOfView
			end
		end,
		set = function(on, v)
			local cam = workspace.CurrentCamera
			if cam then
				cam.FieldOfView = on and (40 + v * 0.8) or original
			end
		end,
	}
end

-- brightness: value = 0 to 6
do
	local original = Lighting.Brightness
	features.brightness = {
		init = function()
			original = Lighting.Brightness
		end,
		set = function(on, v)
			Lighting.Brightness = on and (v / 100 * 6) or original
		end,
	}
end

-- fullbright: kills shadows and lifts ambient light. value = how bright (50% to 100% grey)
do
	local saved, enabled, level = nil, false, 1
	features.fullbright = {
		set = function(on, v)
			level = v / 100
			if on and not saved then
				saved = { Lighting.Ambient, Lighting.OutdoorAmbient, Lighting.GlobalShadows }
			end
			enabled = on
			if not on and saved then
				Lighting.Ambient, Lighting.OutdoorAmbient, Lighting.GlobalShadows = saved[1], saved[2], saved[3]
				saved = nil
			end
		end,
		step = function()
			if not enabled then
				return
			end
			local g = 0.5 + 0.5 * level
			local c = Color3.new(g, g, g)
			if Lighting.Ambient ~= c then
				Lighting.Ambient = c
			end
			if Lighting.OutdoorAmbient ~= c then
				Lighting.OutdoorAmbient = c
			end
			if Lighting.GlobalShadows then
				Lighting.GlobalShadows = false
			end
		end,
	}
end

-- nofog: removes fog and atmosphere haze
do
	local saved, enabled = nil, false
	features.nofog = {
		set = function(on)
			if on and not saved then
				local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
				saved = {
					fogEnd = Lighting.FogEnd,
					fogStart = Lighting.FogStart,
					atmo = atmo,
					density = atmo and atmo.Density,
				}
			end
			enabled = on
			if not on and saved then
				Lighting.FogEnd, Lighting.FogStart = saved.fogEnd, saved.fogStart
				if saved.atmo and saved.atmo.Parent then
					saved.atmo.Density = saved.density
				end
				saved = nil
			end
		end,
		step = function()
			if not enabled then
				return
			end
			if Lighting.FogEnd < 9e8 then
				Lighting.FogEnd = 9e8
			end
			local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
			if atmo and atmo.Density ~= 0 then
				atmo.Density = 0
			end
		end,
	}
end

---------------------------------------------------------------------
-- utility features
---------------------------------------------------------------------

-- timeOfDay: value = hour 0 to 24
do
	local original = Lighting.ClockTime
	features.timeOfDay = {
		init = function()
			original = Lighting.ClockTime
		end,
		set = function(on, v)
			Lighting.ClockTime = on and (v / 100 * 24) or original
		end,
	}
end

-- lowgfx: turns off particles, trails, fire, smoke and sparkles
do
	local active = false
	local disabled = {}
	features.lowgfx = {
		set = function(on)
			if on == active then
				return
			end
			active = on
			if on then
				for _, d in ipairs(workspace:GetDescendants()) do
					if (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles"))
						and d.Enabled then
						disabled[d] = true
						d.Enabled = false
					end
				end
			else
				for d in pairs(disabled) do
					if d.Parent then
						d.Enabled = true
					end
				end
				table.clear(disabled)
			end
		end,
	}
end

-- antiafk: stops the 20 minute idle kick
do
	local bag = Util.bag()
	features.antiafk = {
		set = function(on)
			bag:clean()
			if on then
				local vu = game:GetService("VirtualUser")
				bag:add(lp.Idled:Connect(function()
					vu:CaptureController()
					vu:ClickButton2(Vector2.zero)
				end))
			end
		end,
	}
end

---------------------------------------------------------------------
-- more universal features
---------------------------------------------------------------------

-- coords / speedometer: HUD labels (drag to move)
do
	local label, enabled, acc = nil, false, 0
	features.coords = {
		init = function()
			label = statLabel("Coords", 3)
		end,
		set = function(on, _v, _c, o)
			enabled = on
			label.Visible = on
			styleHud(label, o)
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
			local root = Util.root()
			if root then
				local p = root.Position
				label.Text = ("%d, %d, %d"):format(math.floor(p.X), math.floor(p.Y), math.floor(p.Z))
			end
		end,
	}
end

do
	local label, enabled, acc = nil, false, 0
	features.speedo = {
		init = function()
			label = statLabel("Speed", 4)
		end,
		set = function(on, _v, _c, o)
			enabled = on
			label.Visible = on
			styleHud(label, o)
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
			local root = Util.root()
			if root then
				local v = root.AssemblyLinearVelocity
				label.Text = ("%d st/s"):format(math.floor(Vector3.new(v.X, 0, v.Z).Magnitude + 0.5))
			end
		end,
	}
end

-- bunny hop: hold space to keep jumping
do
	local enabled = false
	features.bhop = {
		set = function(on)
			enabled = on
		end,
		step = function()
			if not enabled or UserInputService:GetFocusedTextBox() then
				return
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				local hum = Util.humanoid()
				if hum and hum.FloorMaterial ~= Enum.Material.Air then
					hum:ChangeState(Enum.HumanoidStateType.Jumping)
				end
			end
		end,
	}
end

-- gravity: games like to reset it, so it is re-applied every frame while on
do
	local orig, enabled, target = nil, false, 196.2
	features.gravity = {
		set = function(on, v)
			if on and not enabled then
				orig = workspace.Gravity
			end
			enabled = on
			target = lerp(20, 196.2, v)
			if on then
				workspace.Gravity = target
			elseif orig then
				workspace.Gravity = orig
				orig = nil
			end
		end,
		step = function()
			if enabled and workspace.Gravity ~= target then
				workspace.Gravity = target
			end
		end,
	}
end

-- anti-void: remembers the last place you stood on, sends you back if you fall out of the map
do
	local enabled, safe = false, nil
	features.antivoid = {
		set = function(on)
			enabled = on
			safe = nil
		end,
		step = function()
			if not enabled then
				return
			end
			local root, hum = Util.root(), Util.humanoid()
			if not root or not hum or hum.Health <= 0 then
				return
			end
			if hum.FloorMaterial ~= Enum.Material.Air then
				safe = root.CFrame
			end
			if safe and root.Position.Y < workspace.FallenPartsDestroyHeight + 80 then
				root.AssemblyLinearVelocity = Vector3.zero
				root.CFrame = safe + Vector3.new(0, 5, 0)
			end
		end,
	}
end

-- box ESP: boxes that scale with distance. Look comes from the row's right-click options.
do
	local esp
	features.boxes = {
		init = function()
			esp = ESP.new({
				make = ESP.box,
				maxDistance = 1000,
				resolve = function(plr, char, dist, style)
					if style.hideTeam and Util.isTeammate(plr) then
						return nil
					end
					return ESP.color(plr, char, Color3.fromRGB(255, 90, 90), style), ESP.text(plr, char, dist, nil, style)
				end,
			})
		end,
		set = function(on, v, _c, o)
			esp:configure(o)
			esp:setDistance(lerp(100, 2000, v))
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

-- hold C to zoom the camera (value = zoom FOV)
do
	local enabled, zoomFov, base = false, 30, nil
	local function restore()
		local cam = workspace.CurrentCamera
		if base and cam then
			cam.FieldOfView = base
		end
		base = nil
	end
	features.zoom = {
		set = function(on, v)
			enabled = on
			zoomFov = lerp(10, 60, v)
			if not on then
				restore()
			end
		end,
		step = function()
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			if enabled and UserInputService:IsKeyDown(Enum.KeyCode.C) and not UserInputService:GetFocusedTextBox() then
				base = base or cam.FieldOfView
				cam.FieldOfView = zoomFov
			else
				restore()
			end
		end,
		destroy = restore,
	}
end

-- unlock how far the camera can zoom out
do
	local orig = nil
	features.maxzoom = {
		set = function(on, v)
			if on then
				orig = orig or lp.CameraMaxZoomDistance
				lp.CameraMaxZoomDistance = lerp(20, 1000, v)
			elseif orig then
				lp.CameraMaxZoomDistance = orig
				orig = nil
			end
		end,
	}
end

-- auto clicker: clicks at the slider rate. Option "only while holding" (default) = hold left mouse, off = always
do
	local enabled, interval, last, cfg = false, 0.1, 0, {}
	features.autoclick = {
		set = function(on, v, _c, o)
			enabled = on
			cfg = o
			interval = 1 / (4 + (lerp(4, 30, v) - 4) * Util.level(o.mode).power)
		end,
		step = function()
			if not enabled or not mouse1click or UserInputService:GetFocusedTextBox() then
				return
			end
			if cfg.hold ~= false and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				return
			end
			local now = os.clock()
			if now - last >= interval then
				last = now
				mouse1click()
			end
		end,
	}
end

---------------------------------------------------------------------
-- menu features
---------------------------------------------------------------------

-- saving: autosave switch and two buttons (the config object comes from the loader through ctx.config)
features.autosave = {
	set = function(on, _v, c)
		if c.config then
			c.config.autosave = on
		end
	end,
}
features.cfgSave = {
	set = function(on, _v, c)
		if not on or not c.config then
			return
		end
		if not c.config:available() then
			c.notify("your executor has no file access, nothing can be saved", Color3.fromRGB(255, 84, 96))
		elseif c.config:save() then
			c.notify("config saved", Color3.fromRGB(72, 214, 134))
		else
			c.notify("saving failed (see output)", Color3.fromRGB(255, 84, 96))
		end
	end,
}
-- cheat level: while ON, every cheat with a Mode option is switched to the chosen level (Blatant / Semi / Legit).
-- Each cheat's own Mode can still be changed afterwards in its right-click menu. The first call (menu start-up,
-- restoring saved settings) only records the state so saved per-cheat modes are not overwritten.
do
	local started, lastOn, lastLevel = false, false, nil
	features.cheatLevel = {
		set = function(on, v, c)
			local level = v < 34 and "Blatant" or (v < 67 and "Semi" or "Legit")
			local apply = started and on and (not lastOn or level ~= lastLevel) and not c.ui.bulk
			started, lastOn, lastLevel = true, on, level
			if apply then
				c.ui:setOptionAll("mode", level)
				c.notify("cheat level: " .. level, Color3.fromRGB(139, 125, 255))
			end
		end,
	}
end

features.cfgReset = {
	set = function(on, _v, c)
		if not on then
			return
		end
		c.ui:resetAll()
		Functionality.resetPositions()
		if c.config then
			c.config:touch()
		end
		c.notify("everything reset to defaults", Color3.fromRGB(255, 214, 64))
	end,
}

-- reducedMotion: kills menu animations (instant transitions)
features.reducedMotion = {
	set = function(on, _v, c)
		c.animations.Enabled = not on
	end,
}

-- menuOpacity: on = see-through menu (value 0-100 -> 25-100% opaque), off = solid
features.menuOpacity = {
	set = function(on, v, c)
		c.ui:setOpacity(on and lerp(0.25, 1, v) or 1)
	end,
}

-- hudlock: stops HUD labels from being dragged by accident
features.hudlock = {
	set = function(on)
		hudLocked = on
		if on then
			dragging = nil
		end
	end,
}

-- notifs: off = no toasts (role alerts etc. stay silent)
features.notifs = {
	set = function(on)
		notifyOn = on
	end,
}

-- autohide: off = menu stays pinned open, value = delay (1 to 10 s)
features.autohide = {
	set = function(on, v, c)
		c.ui:setAutoHide(on, 1 + 9 * v / 100)
	end,
}

---------------------------------------------------------------------
-- toasts
---------------------------------------------------------------------
function Functionality.notify(text, color)
	if not toasts or not notifyOn then
		return
	end
	local label = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Color3.fromRGB(22, 24, 31),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = color or Color3.fromRGB(236, 238, 244),
		Text = text,
	}, toasts)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, label)
	task.delay(3.5, function()
		if label.Parent then
			local t = ctx.animations.tween(label, "ease", { TextTransparency = 1, BackgroundTransparency = 1 })
			t.Completed:Once(function()
				label:Destroy()
			end)
		end
	end)
end

---------------------------------------------------------------------
-- public api
---------------------------------------------------------------------
function Functionality.register(id, def)
	features[id] = def
	if ctx and def.init and not def._inited then
		def._inited = true
		def.init(ctx, hudGui)
	end
end

function Functionality.init(c)
	ctx = c
	ctx.notify = Functionality.notify
	hudGui = make("ScreenGui", {
		Name = "MenuWidgetHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1000, -- above Roblox's core gui, below the menu itself
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	Util.mount(hudGui)
	ctx.hud = hudGui
	-- helpers for features that put labels on the HUD (see Games' modules)
	ctx.hudLabel = hudLabel
	ctx.draggable = Functionality.draggable
	ctx.hudPos = Functionality.hudPos

	-- toasts sit bottom centre so they never land on the menu, whatever height it has
	toasts = make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -110),
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, hudGui)
	make("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
	}, toasts)

	-- dragging HUD labels: follow the pointer anywhere on screen until it is released
	hudConns[#hudConns + 1] = UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input == dragging.input then
			local p = clampPos(dragging.info.obj, dragging.from + (Util.pointer(dragging.input) - dragging.start))
			positions[dragging.key] = p
			dragging.info.obj.Position = UDim2.fromOffset(p.X, p.Y)
		end
	end)
	hudConns[#hudConns + 1] = UserInputService.InputEnded:Connect(function(input)
		if dragging and isPress(input) then
			dragging = nil
			if Functionality.onHudMoved then
				Functionality.onHudMoved() -- saves the new spot
			end
		end
	end)
	-- screen resized: pull every label back on screen
	hudConns[#hudConns + 1] = hudGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		for _, info in ipairs(huds) do
			info.place()
		end
	end)

	for id, def in pairs(features) do
		if def.init and not def._inited then
			def._inited = true
			local ok, err = pcall(def.init, ctx, hudGui)
			if not ok then
				warn(("[FMenu] feature '%s' init failed: %s"):format(id, tostring(err)))
			end
		end
	end

	conn = RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		for id, def in pairs(features) do
			if def.step and now >= (def._retryAt or 0) then
				local ok, err = pcall(def.step, dt, ctx)
				if not ok then
					-- back off for a second and try again: one bad frame must never switch a feature off for good
					def._retryAt = now + 1
					local msg = tostring(err)
					if def._lastErr ~= msg then
						def._lastErr = msg
						warn(("[FMenu] feature '%s' step failed (retrying): %s"):format(id, msg))
					end
				end
			end
		end
	end)
end

function Functionality.resetPositions()
	Functionality.setPositions(nil)
end

function Functionality.set(id, enabled, value, opts)
	local def = features[id]
	if not def then
		warn(("[FMenu] no feature registered for row '%s'"):format(id))
		return
	end
	opts = opts or {}
	state[id] = { on = enabled, value = value, opts = opts }
	local ok, err = pcall(def.set, enabled, value, ctx, opts)
	if not ok then
		warn(("[FMenu] feature '%s' failed: %s"):format(id, tostring(err)))
	end
end

function Functionality.destroy()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	-- undo everything that is still on so nothing leaks after the menu is gone
	for id, st in pairs(state) do
		local def = features[id]
		if def and st.on then
			pcall(def.set, false, st.value, ctx, st.opts)
		end
	end
	for _, def in pairs(features) do
		if def.destroy then
			pcall(def.destroy)
		end
	end
	for _, c in ipairs(hudConns) do
		c:Disconnect()
	end
	table.clear(hudConns)
	table.clear(huds)
	dragging = nil
	if hudGui then
		hudGui:Destroy()
		hudGui = nil
	end
end

-- anti-fling, no collision, stabilizer, cheat detection (src/Defense.lua)
for id, def in pairs(Defense.features) do
	features[id] = def
end

-- trolling (src/Troll.lua)
for id, def in pairs(Troll.features) do
	features[id] = def
end

-- vehicle controller (src/Vehicle.lua)
for id, def in pairs(Vehicle.features) do
	features[id] = def
end

return Functionality
