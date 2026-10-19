-- ModuleScript: Audio
-- One 0-100 volume slider for the whole game's audio.
--   Audio.features  { audio = { set, destroy } }, merged into Functionality's registry
--
-- "Game sounds" (default): every Sound that exists right now is scaled by the slider, and so is every Sound the
--   game creates later (game.DescendantAdded picks them up the moment they are parented). If the game changes a
--   Sound's Volume itself (fades, footsteps, music crossfades) that new value becomes the sound's baseline and is
--   scaled again, so the slider keeps working over the game's own volume changes. Turning the row off puts every
--   Sound back to its own volume.
-- "Master volume": changes Roblox's own game volume setting instead (UserGameSettings.MasterVolume), which also
--   covers Roblox's built-in sounds. The original value is restored when the row is turned off. If the executor
--   does not allow it, switch back to "Game sounds".
--
-- Slider: 0 = silent, 100 = the game's normal volume (it only ever turns things DOWN, never above the game's level).

local import = ...

local Audio = { features = {} }
local features = Audio.features

local state = {
	on = false,
	factor = 0.5,
	scope = "Game sounds",
	tracked = setmetatable({}, { __mode = "k" }), -- Sound -> { base, set, conns }
	added = nil, -- game.DescendantAdded connection while the sound hook is active
	token = 0, -- bumped to cancel an unfinished initial scan
	origMaster = nil,
}

---------------------------------------------------------------------
-- game sounds
---------------------------------------------------------------------
local function write(snd, rec)
	local v = rec.base * state.factor
	rec.set = v
	pcall(function()
		snd.Volume = v
	end)
end

local function untrack(snd, restore)
	local rec = state.tracked[snd]
	if not rec then
		return
	end
	state.tracked[snd] = nil
	for _, c in ipairs(rec.conns) do
		c:Disconnect()
	end
	if restore then
		pcall(function()
			snd.Volume = rec.base
		end)
	end
end

local function track(snd)
	if state.tracked[snd] then
		return
	end
	local ok, base = pcall(function()
		return snd.Volume
	end)
	if not ok then
		return -- a sound this executor may not touch
	end
	local rec = { base = base, set = nil, conns = {} }
	state.tracked[snd] = rec
	rec.conns[1] = snd:GetPropertyChangedSignal("Volume"):Connect(function()
		local v = snd.Volume
		if rec.set and math.abs(v - rec.set) < 1e-4 then
			return -- that was our own write
		end
		rec.base = v -- the game changed it: that is the new "normal" volume of this sound
		write(snd, rec)
	end)
	rec.conns[2] = snd.Destroying:Connect(function()
		untrack(snd, false)
	end)
	write(snd, rec)
end

local function refreshAll()
	for snd, rec in pairs(state.tracked) do
		write(snd, rec)
	end
end

local function startSounds()
	if state.added then
		refreshAll()
		return
	end
	-- incoming audio: every Sound that shows up from now on
	state.added = game.DescendantAdded:Connect(function(d)
		if d:IsA("Sound") then
			pcall(track, d)
		end
	end)
	-- current audio: everything that already exists (in slices so a big game does not hitch)
	state.token += 1
	local token = state.token
	task.spawn(function()
		local ok, list = pcall(function()
			return game:GetDescendants()
		end)
		if not ok then
			return
		end
		for i, d in ipairs(list) do
			if token ~= state.token then
				return
			end
			if d:IsA("Sound") then
				pcall(track, d)
			end
			if i % 400 == 0 then
				task.wait()
			end
		end
	end)
end

local function stopSounds()
	state.token += 1
	if state.added then
		state.added:Disconnect()
		state.added = nil
	end
	local list = {}
	for snd in pairs(state.tracked) do
		list[#list + 1] = snd
	end
	for _, snd in ipairs(list) do
		untrack(snd, true)
	end
end

---------------------------------------------------------------------
-- Roblox master volume
---------------------------------------------------------------------
local function settings()
	local ok, gs = pcall(function()
		return UserSettings():GetService("UserGameSettings")
	end)
	return ok and gs or nil
end

local function setMaster(on)
	local gs = settings()
	if not gs then
		return false
	end
	if on then
		if state.origMaster == nil then
			state.origMaster = gs.MasterVolume
		end
		pcall(function()
			gs.MasterVolume = state.origMaster * state.factor
		end)
	elseif state.origMaster ~= nil then
		local orig = state.origMaster
		state.origMaster = nil
		pcall(function()
			gs.MasterVolume = orig
		end)
	end
	return true
end

---------------------------------------------------------------------
-- feature
---------------------------------------------------------------------
features.audio = {
	set = function(on, v, ctx, o)
		state.factor = math.clamp(v / 100, 0, 1)
		state.scope = o.scope or "Game sounds"
		if on then
			if state.scope == "Master volume" then
				stopSounds()
				if not setMaster(true) and ctx and ctx.notify and not state.on then
					ctx.notify("audio: master volume is not available here, use Game sounds", Color3.fromRGB(255, 214, 64))
				end
			else
				setMaster(false)
				startSounds()
			end
		else
			stopSounds()
			setMaster(false)
		end
		state.on = on
	end,
	destroy = function()
		stopSounds()
		setMaster(false)
		state.on = false
	end,
}

return Audio
