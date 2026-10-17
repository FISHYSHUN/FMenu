-- ModuleScript: Functionality
-- Feature registry. A feature is keyed by the same id a row uses in Games.lua:
--   { init = function(ctx, hudGui) end,   -- optional, runs once (build hud elements, snapshot originals)
--     set  = function(enabled, value, ctx) end,  -- runs on toggle and on slider change (value 0-100)
--     step = function(dt, ctx) end,        -- optional, runs every RenderStepped
--     destroy = function() end }           -- optional, extra cleanup (set(false) is already called for you)
-- ctx = { ui, animations, profileName, notify(text, color?), hud }
-- Games register their own features through Functionality.register.
--
-- Everything in here is universal (works in any game). Game specific stuff lives in src/games/.

local import = ...
local Util = import("Util")
local ESP = import("ESP")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local make, lerp = Util.make, Util.lerp

local Functionality = {}

local features = {}
local state = {} -- id -> { on, value } (last values applied, used to undo everything on destroy)
local ctx = nil
local hudGui = nil
local toasts = nil
local conn = nil

local function statLabel(name, y)
	return make("TextLabel", {
		Name = name,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, y),
		Size = UDim2.fromOffset(160, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(236, 238, 244),
		TextStrokeTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Text = "",
	}, hudGui)
end

---------------------------------------------------------------------
-- HUD features
---------------------------------------------------------------------

-- overlay: watermark, value = opacity
do
	local label
	features.overlay = {
		init = function(c)
			label = make("TextLabel", {
				Name = "Overlay",
				Position = UDim2.fromOffset(12, 12),
				Size = UDim2.fromOffset(260, 18),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = Color3.fromRGB(139, 125, 255),
				TextStrokeTransparency = 0.5,
				TextXAlignment = Enum.TextXAlignment.Left,
				Visible = false,
				Text = "FMenu | " .. c.profileName,
			}, hudGui)
		end,
		set = function(on, v)
			label.Visible = on
			label.TextTransparency = 1 - v / 100
		end,
	}
end

-- crosshair: value = size (4 to 40 px)
do
	local holder
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
			make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0,
			}, holder)
			make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0,
			}, holder)
		end,
		set = function(on, v)
			holder.Visible = on
			local size = 4 + v * 0.36
			holder.Size = UDim2.fromOffset(size, size)
		end,
	}
end

-- fps: value = refresh rate (1 to 10 updates per second)
do
	local label, enabled, interval, acc, frames = nil, false, 0.5, 0, 0
	features.fps = {
		init = function()
			label = statLabel("Fps", 12)
		end,
		set = function(on, v)
			enabled = on
			label.Visible = on
			interval = 1 / (1 + 9 * v / 100)
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
			label = statLabel("Ping", 30)
		end,
		set = function(on, v)
			enabled = on
			label.Visible = on
			interval = 1 / (1 + 9 * v / 100)
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
			label = statLabel("Clock", 48)
		end,
		set = function(on, v)
			enabled = on
			twelve = v >= 50
			label.Visible = on
			acc = 1
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
		set = function(on, v)
			local hum = Util.humanoid()
			if on and not enabled and hum then
				orig = hum.WalkSpeed
			end
			enabled = on
			target = lerp(16, 150, v)
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
		set = function(on, v)
			local hum = Util.humanoid()
			if on and not enabled and hum then
				orig = { hum.JumpPower, hum.JumpHeight }
			end
			enabled = on
			power = lerp(50, 300, v)
			height = lerp(7.2, 50, v)
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

-- fly: WASD + camera direction, Space up, Shift/Ctrl down. value = speed 20 to 200
do
	local enabled, speed, bv = false, 60, nil
	local function stop()
		if bv then
			bv:Destroy()
			bv = nil
		end
		local hum = Util.humanoid()
		if hum then
			hum.PlatformStand = false
		end
	end
	features.fly = {
		set = function(on, v)
			speed = lerp(20, 200, v)
			if on == enabled then
				return
			end
			enabled = on
			if not on then
				stop()
			end
		end,
		step = function()
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
			if k:IsKeyDown(Enum.KeyCode.Space) or hum.Jump then dir += Vector3.yAxis end
			if k:IsKeyDown(Enum.KeyCode.LeftShift) or k:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
			bv.Velocity = dir.Magnitude > 0 and dir.Unit * speed or Vector3.zero
		end,
	}
end

-- clicktp: Ctrl + click teleports to the clicked spot
do
	local bag = Util.bag()
	features.clicktp = {
		set = function(on)
			bag:clean()
			if on then
				local mouse = lp:GetMouse()
				bag:add(UserInputService.InputBegan:Connect(function(input, processed)
					if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
						return
					end
					if not UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
						return
					end
					local root = Util.root()
					if root and mouse.Hit then
						root.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0))
					end
				end))
			end
		end,
	}
end

---------------------------------------------------------------------
-- visual features
---------------------------------------------------------------------

-- esp: highlight + name / distance / health on every other player. value = max distance 100 to 2000
do
	local esp
	features.esp = {
		init = function()
			esp = ESP.new({
				maxDistance = 1000,
				resolve = function(plr, char, dist)
					local hum = Util.humanoid(char)
					local color = plr.Team and plr.TeamColor.Color or Color3.fromRGB(255, 90, 90)
					return color, ("%s  %dm  %dhp"):format(plr.DisplayName, math.floor(dist), math.floor(hum and hum.Health or 0))
				end,
			})
		end,
		set = function(on, v)
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

-- tracers: line from the bottom of the screen to every player. value = thickness 1 to 4
do
	local enabled, thickness, lines = false, 1, {}
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
		set = function(on, v)
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
			local origin = Vector2.new(vp.X / 2, vp.Y)
			local used = 0
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= lp and Util.alive(plr.Character) then
					local root = Util.root(plr.Character)
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
							line.BackgroundColor3 = plr.Team and plr.TeamColor.Color or Color3.fromRGB(255, 90, 90)
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
-- menu features
---------------------------------------------------------------------

-- reducedMotion: kills menu animations (instant transitions)
features.reducedMotion = {
	set = function(on, _v, c)
		c.animations.Enabled = not on
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
	if not toasts then
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
		DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, lp:WaitForChild("PlayerGui"))
	ctx.hud = hudGui

	toasts = make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 268),
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, hudGui)
	make("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, toasts)

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
		for id, def in pairs(features) do
			if def.step and not def._stepFailed then
				local ok, err = pcall(def.step, dt, ctx)
				if not ok then
					def._stepFailed = true
					warn(("[FMenu] feature '%s' step failed: %s"):format(id, tostring(err)))
				end
			end
		end
	end)
end

function Functionality.set(id, enabled, value)
	local def = features[id]
	if not def then
		warn(("[FMenu] no feature registered for row '%s'"):format(id))
		return
	end
	state[id] = { on = enabled, value = value }
	local ok, err = pcall(def.set, enabled, value, ctx)
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
			pcall(def.set, false, st.value, ctx)
		end
	end
	for _, def in pairs(features) do
		if def.destroy then
			pcall(def.destroy)
		end
	end
	if hudGui then
		hudGui:Destroy()
		hudGui = nil
	end
end

return Functionality
