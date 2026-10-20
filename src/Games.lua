-- ModuleScript: Games
-- Every game gets the universal tabs below. If the place is recognised, one extra tab with that
-- game's rows is inserted before Config and the game module's features are registered.
--
-- row = { id, label, slider (popover title), value (0-100), on, fmt?, opts?, button? }
--   id must match a feature in Functionality.lua or in the game module's `features` table.
--   fmt turns the 0-100 slider value into what the user sees (Util.range(lo, hi, unit)).
--   slider = "Unused" hides the main slider in the right-click menu.
--   opts = extra controls in the right-click menu, each { type, key, label, default, ... }:
--       slider  min, max, step, unit? | pct? (shows value * 100 %) | fmt?
--       hue     a rainbow slider, value 0..1
--       toggle
--       choice  choices = { "A", "B" }, value is the chosen string
--     the feature's set(enabled, value, ctx, optsTable) receives the current values by key.
--   button = true makes a row that runs once per click (set is called with enabled = true) instead of switching.
--   any number of rows per tab: the menu grows to fit the tab and scrolls if the screen is too short.
--
-- Recognising a game (Games.index entry):
--   places    = exact PlaceIds
--   universes = GameIds (game.GameId). One universe covers every place of an experience, which is what
--               you want for games that teleport you between a lobby and match places (Rivals).
--   names     = lowercase fragments of game.Name, last resort
--
-- To add a game: print(game.PlaceId, game.GameId) in the executor, add an entry to Games.index and a
-- module in src/games/ that returns { name, tab = { name, rows }, features = { ... } }.

local import = ...
local Util = import("Util")
local ESP = import("ESP")
local Troll = import("Troll")
local Vehicle = import("Vehicle")
local Movement = import("Movement")
local range = Util.range

local Games = {}

Games.index = {
	mm2 = { module = "games/MM2", places = { 142823291 }, names = { "murder mystery" } },
	-- the lobby is 17625359962, matches run in other places of the same universe (GameId from memory,
	-- check it with print(game.GameId) if the tab still does not show up)
	rivals = { module = "games/Rivals", places = { 17625359962 }, universes = { 6035872082 }, names = { "rivals" } },
	nds = { module = "games/NaturalDisasters", places = { 189707 }, names = { "natural disaster" } },
	flee = { module = "games/FleeTheFacility", places = { 893973440, 17600423422 }, names = { "flee" } },
}

-- { header = "Title" } starts a titled section inside a tab (rows after it sit in their own 2 column grid)

local function append(dst, src)
	for _, o in ipairs(src) do
		dst[#dst + 1] = o
	end
	return dst
end

-- options shared by every HUD text label (fps, ping, clock...)
local function hudOpts()
	return {
		{ type = "slider", key = "textSize", label = "Text size", min = 10, max = 24, step = 1, unit = "px", default = 14 },
		{ type = "slider", key = "bg", label = "Background", min = 0, max = 1, step = 0.05, pct = true, default = 0.65 },
		{ type = "toggle", key = "tint", label = "Custom color", default = false },
		{ type = "hue", key = "hue", label = "Hue", default = 0.6 },
	}
end

local baseTabs = {
	{ name = "Main", rows = {
		{ header = "Movement" },
		{ id = "speed", label = "Speed", slider = "Walk speed", value = 30, on = false, fmt = range(16, 150), opts = { Util.modeOption() } },
		{ id = "jump", label = "High jump", slider = "Jump power", value = 25, on = false, fmt = range(50, 300), opts = { Util.modeOption() } },
		{ id = "infjump", label = "Infinite jump", slider = "Unused", value = 0, on = false, opts = {
			{ type = "slider", key = "limit", label = "Air jumps (0 = unlimited)", min = 0, max = 10, step = 1, default = 0 },
		} },
		{ id = "bhop", label = "Bunny hop", slider = "Unused", value = 0, on = false, opts = {
			{ type = "slider", key = "gain", label = "Speed gain per hop", min = 0, max = 0.2, step = 0.01, pct = true, default = 0 },
			{ type = "slider", key = "cap", label = "Speed cap", min = 30, max = 150, step = 5, unit = " st/s", default = 80 },
		} },
		{ id = "fly", label = "Fly", slider = "Fly speed", value = 35, on = false, fmt = range(20, 200), opts = {
			Util.modeOption(),
			{ type = "slider", key = "vert", label = "Up / down speed", min = 0.25, max = 2, step = 0.05, unit = "x", default = 1 },
			{ type = "slider", key = "smooth", label = "Smoothing", min = 0, max = 1, step = 0.05, pct = true, default = 0 },
		} },
		{ id = "noclip", label = "Noclip", slider = "Unused", value = 0, on = false },
		{ header = "Teleport & physics" },
		{ id = "clicktp", label = "Click teleport", slider = "Unused", value = 0, on = false, opts = {
			{ type = "choice", key = "key", label = "Hold key", choices = { "Ctrl", "Alt", "Shift", "None" }, default = "Ctrl" },
			{ type = "slider", key = "lift", label = "Land above spot", min = 0, max = 10, step = 1, unit = " st", default = 3 },
		} },
		{ id = "gravity", label = "Gravity", slider = "Gravity", value = 50, on = false, fmt = range(20, 196) },
		{ id = "antivoid", label = "Anti-void", slider = "Unused", value = 0, on = false, opts = {
			{ type = "slider", key = "depth", label = "Trigger height above void", min = 20, max = 300, step = 10, unit = " st", default = 80 },
			{ type = "slider", key = "lift", label = "Return height", min = 2, max = 30, step = 1, unit = " st", default = 5 },
		} },
		{ header = "Utility" },
		{ id = "autoclick", label = "Auto-clicker", slider = "Clicks per second", value = 40, on = false, fmt = range(4, 30, "/s"), opts = {
			Util.modeOption(),
			{ type = "toggle", key = "hold", label = "Only while holding left click", default = true },
		} },
		{ id = "antiafk", label = "Anti-AFK", slider = "Unused", value = 0, on = true },
	} },
	-- Visual = what gets drawn on other players, plus world and camera. How each ESP looks is set in its own
	-- right-click menu (colors, labels, chams, refresh rate...).
	{ name = "Visual", rows = {
		{ header = "Players" },
		{ id = "esp", label = "Player ESP", slider = "Max distance", value = 50, on = false, fmt = range(100, 2000, " st"), opts = ESP.options("player") },
		{ id = "boxes", label = "Box ESP", slider = "Max distance", value = 50, on = false, fmt = range(100, 2000, " st"), opts = ESP.options("box") },
		{ id = "tracers", label = "Tracers", slider = "Thickness", value = 0, on = false, fmt = range(1, 4, "px"), opts = ESP.options("tracer") },
		{ header = "World" },
		{ id = "timeOfDay", label = "Time of day", slider = "Hour (0-24)", value = 60, on = false, fmt = range(0, 24, "h") },
		{ id = "brightness", label = "Brightness", slider = "Brightness (0-6)", value = 35, on = false, fmt = range(0, 6) },
		{ id = "fullbright", label = "Fullbright", slider = "Ambient level", value = 100, on = false, fmt = range(50, 100, "%") },
		{ id = "nofog", label = "No fog", slider = "Unused", value = 0, on = false },
		{ id = "lowgfx", label = "Low graphics", slider = "Unused", value = 0, on = false },
		{ header = "Camera" },
		{ id = "fov", label = "Field of view", slider = "FOV (40-120)", value = 50, on = false, fmt = range(40, 120) },
		{ id = "zoom", label = "Hold-key zoom", slider = "Zoom FOV", value = 40, on = false, fmt = range(10, 60), opts = {
			{ type = "choice", key = "key", label = "Zoom key", choices = { "C", "Z", "X", "V", "Q", "E" }, default = "C" },
			{ type = "toggle", key = "smooth", label = "Smooth zoom", default = true },
		} },
		{ id = "maxzoom", label = "Max zoom out", slider = "Distance", value = 30, on = false, fmt = range(20, 1000, " st") },
	} },
	Vehicle.tab,
	Movement.tab,
	Troll.tab,
	-- protection from other players' cheats. Everything here is client side: it changes what YOUR game does
	-- about other players (collisions, your own velocity, warnings), it cannot kick or ban anyone.
	{ name = "Defense", rows = {
		{ header = "Anti-fling" },
		{ id = "antifling", label = "Anti-fling", slider = "Velocity limit", value = 30, on = false, fmt = range(80, 400, " st/s") },
		{ id = "nocollide", label = "No player collision", slider = "Unused", value = 0, on = false },
		{ id = "stabilize", label = "Stabilizer", slider = "Speed cap when flung", value = 30, on = false, fmt = range(40, 300, " st/s") },
		{ header = "Cheat detection" },
		{ id = "detMove", label = "Speed / fly / tp", slider = "Sensitivity", value = 50, on = false, fmt = range(0, 100, "%"), opts = {
			{ type = "toggle", key = "speed", label = "Check speed", default = true },
			{ type = "toggle", key = "tp", label = "Check teleports", default = true },
			{ type = "toggle", key = "fly", label = "Check flying", default = true },
			{ type = "slider", key = "cooldown", label = "Alert cooldown", min = 5, max = 60, step = 5, unit = "s", default = 15 },
		} },
		{ id = "detSpin", label = "Spin / fling", slider = "Sensitivity", value = 50, on = false, fmt = range(0, 100, "%") },
		{ id = "detAim", label = "Aim snap", slider = "Sensitivity", value = 50, on = false, fmt = range(0, 100, "%") },
		{ id = "flagEsp", label = "Flag markers", slider = "Unused", value = 0, on = false, opts = append({
			{ type = "slider", key = "duration", label = "Keep flag for", min = 10, max = 120, step = 5, unit = "s", default = 30 },
		}, ESP.options("chams")) },
	} },
	-- everything about the menu itself: HUD overlays, look, behaviour and saving
	{ name = "Config", rows = {
		{ header = "Overlay & stats" },
		{ id = "overlay", label = "Overlay", slider = "Opacity", value = 80, on = true, fmt = range(0, 100, "%"), opts = hudOpts() },
		{ id = "fps", label = "Show FPS", slider = "Refresh rate", value = 60, on = true, fmt = range(1, 10, "/s"), opts = hudOpts() },
		{ id = "ping", label = "Show ping", slider = "Refresh rate", value = 40, on = false, fmt = range(1, 10, "/s"), opts = hudOpts() },
		{ id = "clock", label = "Show clock", slider = "24h / 12h (50+)", value = 0, on = false, fmt = function(v) return v >= 50 and "12h" or "24h" end, opts = hudOpts() },
		{ id = "coords", label = "Coordinates", slider = "Unused", value = 0, on = false, opts = hudOpts() },
		{ id = "speedo", label = "Speedometer", slider = "Unused", value = 0, on = false, opts = hudOpts() },
		{ header = "Screen" },
		{ id = "crosshair", label = "Crosshair", slider = "Crosshair size", value = 40, on = false, fmt = range(4, 40, "px"), opts = {
			{ type = "slider", key = "thickness", label = "Thickness", min = 1, max = 6, step = 1, unit = "px", default = 2 },
			{ type = "slider", key = "alpha", label = "Opacity", min = 0.2, max = 1, step = 0.05, pct = true, default = 1 },
			{ type = "toggle", key = "tint", label = "Custom color", default = false },
			{ type = "hue", key = "hue", label = "Hue", default = 0.55 },
		} },
		{ header = "Menu" },
		{ id = "menuOpacity", label = "Translucent menu", slider = "Opacity", value = 60, on = false, fmt = range(25, 100, "%") },
		{ id = "compact", label = "Compact mode", slider = "Shrink amount", value = 50, on = false, fmt = range(0, 25, "%") },
		{ id = "reducedMotion", label = "Reduced motion", slider = "Unused", value = 0, on = false },
		{ header = "Now playing" },
		{ id = "lastfm", label = "Last.fm on pill", slider = "Check every", value = 30, on = false, fmt = range(5, 30, "s"), opts = {
			{ type = "text", key = "user", label = "Last.fm username", placeholder = "username", default = "" },
			{ type = "text", key = "key", label = "API key", placeholder = "paste your API key", default = "" },
			{ type = "toggle", key = "progress", label = "Progress bar + time", default = true },
			{ type = "toggle", key = "notify", label = "Toast on new song", default = false },
		} },
		{ id = "spotify", label = "Spotify on pill", slider = "Check every", value = 12, on = false, fmt = range(2, 10, "s"), opts = {
			{ type = "toggle", key = "controls", label = "Prev / pause / skip buttons", default = true },
			{ type = "toggle", key = "progress", label = "Progress bar + time", default = true },
			{ type = "toggle", key = "notify", label = "Toast on new song", default = false },
			{ type = "text", key = "clientId", label = "Client ID", placeholder = "from developer.spotify.com", default = "" },
			{ type = "text", key = "clientSecret", label = "Client secret", placeholder = "from developer.spotify.com", default = "" },
			{ type = "text", key = "refresh", label = "Refresh token", placeholder = "from tools/spotify_auth.py", default = "" },
			{ type = "text", key = "token", label = "Access token (1 h, optional)", placeholder = "quick test instead of the above", default = "" },
		} },
		{ header = "Audio" },
		{ id = "audio", label = "Audio volume", slider = "Volume", value = 50, on = false, fmt = range(0, 100, "%"), opts = {
			{ type = "choice", key = "scope", label = "Controls", choices = { "Game sounds", "Master volume" }, default = "Game sounds" },
		} },
		{ header = "Behaviour" },
		{ id = "autohide", label = "Auto-hide", slider = "Delay (1-10 s)", value = 33, on = true, fmt = range(1, 10, "s") },
		{ id = "hudlock", label = "Lock HUD", slider = "Unused", value = 0, on = false },
		{ id = "notifs", label = "Notifications", slider = "Unused", value = 0, on = true },
		{ id = "carry", label = "Carry to next game", slider = "Unused", value = 0, on = true },
		{ header = "Cheat level" },
		{ id = "cheatLevel", label = "Apply level to all", slider = "Blatant / Semi / Legit", value = 0, on = false, fmt = function(v) return v < 34 and "Blatant" or (v < 67 and "Semi" or "Legit") end },
		{ header = "Saving" },
		{ id = "autosave", label = "Autosave", slider = "Unused", value = 0, on = true },
		{ id = "cfgSave", label = "Save now", slider = "Unused", value = 0, button = true },
		{ id = "cfgReset", label = "Reset everything", slider = "Unused", value = 0, button = true },
	} },
}

local function matchGame(placeId, gameId, gameName)
	for key, entry in pairs(Games.index) do
		for _, id in ipairs(entry.places or {}) do
			if id == placeId then
				return key
			end
		end
		for _, id in ipairs(entry.universes or {}) do
			if id == gameId then
				return key
			end
		end
	end
	if gameName then
		local lname = gameName:lower()
		for key, entry in pairs(Games.index) do
			for _, pat in ipairs(entry.names or {}) do
				if lname:find(pat, 1, true) then
					return key
				end
			end
		end
	end
	return nil
end

-- returns { name, tabs, features }
function Games.resolve(placeId, gameName)
	local gameId = game.GameId
	local key = matchGame(placeId, gameId, gameName)
	print(("[FMenu] place %s  universe %s  ->  %s"):format(tostring(placeId), tostring(gameId), key or "universal"))
	local def = nil
	if key then
		local ok, mod = pcall(import, Games.index[key].module)
		if ok then
			def = mod
		else
			warn(("[FMenu] could not load game module '%s': %s"):format(key, tostring(mod)))
		end
	end

	local tabs = {}
	for _, t in ipairs(baseTabs) do
		tabs[#tabs + 1] = t
	end
	if def then
		table.insert(tabs, #tabs, def.tab) -- before Config
	end

	return {
		name = def and def.name or "Universal",
		tabs = tabs,
		features = def and def.features or {},
	}
end

---------------------------------------------------------------------
-- chat commands (no window): /tp /watch /orbit /mark /server
---------------------------------------------------------------------
-- Games.commands({ notify = Functionality.notify }) -> object with :destroy(), called once from loader.lua.
--   /tp <name>       teleport next to that player
--   /watch <name>    camera follows them (again, or /watch alone, to go back to yourself)
--   /orbit <name>    circle around them (again, or /orbit alone, to stop)
--   /mark <name>     yellow chams + name tag + distance, any number of players (/mark alone clears all)
--   /server [note]   posts the server you are in to your Discord webhook, like a bookmark
-- <name> is a partial match on username or display name.
--
-- Client side only: moves your own character / camera and draws markers, nothing is sent to anyone, except /server,
-- which posts game name + link, player count and a join snippet for this exact server (JobId) when you type it.
-- The webhook is not in the code: put the URL in FMenu/webhook.txt (one line) or set getgenv().FMENU_WEBHOOK.
--
-- With the new chat (TextChatService) the commands are TextChatCommands: they run locally and the text is NOT sent,
-- nobody sees it. With the old chat only Player.Chatted exists, which fires after sending, so the line is visible
-- there. Games.SERVER_KEY = Enum.KeyCode.<x> also sends /server with a key (nil = chat command only).

Games.SERVER_KEY = nil
Games.ORBIT_RADIUS, Games.ORBIT_SPEED, Games.ORBIT_HEIGHT = 10, 2, 2

function Games.commands(deps)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")
	local TextChatService = game:GetService("TextChatService")
	local HttpService = game:GetService("HttpService")
	local MarketplaceService = game:GetService("MarketplaceService")

	local notify = deps.notify or function() end
	local lp = Players.LocalPlayer
	local YELLOW = Color3.fromRGB(255, 214, 64)
	local RED = Color3.fromRGB(255, 84, 96)
	local GREEN = Color3.fromRGB(72, 214, 134)

	local conns, cmds = {}, {}
	local watch, orbit, angle = nil, nil, 0
	local marked = {}
	local posting = false

	local function trim(s)
		return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
	end

	local function usable(plr)
		return plr ~= nil and plr.Parent ~= nil and Util.isAlive(plr.Character) and Util.rootOf(plr.Character) ~= nil
	end

	local function findPlayer(query)
		query = query:lower()
		if query == "" then
			return nil
		end
		local prefix, partial
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local n, d = plr.Name:lower(), plr.DisplayName:lower()
				if n == query or d == query then
					return plr
				end
				if not prefix and (n:sub(1, #query) == query or d:sub(1, #query) == query) then
					prefix = plr
				end
				if not partial and (n:find(query, 1, true) or d:find(query, 1, true)) then
					partial = plr
				end
			end
		end
		return prefix or partial
	end

	local function resolveTarget(arg)
		local plr = findPlayer(arg)
		if not plr then
			notify(("no player matches '%s'"):format(arg), YELLOW)
		end
		return plr
	end

	local function restoreCamera()
		local cam, hum = workspace.CurrentCamera, Util.humanoid()
		if cam and hum then
			cam.CameraSubject = hum
		end
	end

	local esp = ESP.new({
		maxDistance = 5000,
		resolve = function(plr, char, dist, style)
			if marked[plr] then
				return YELLOW, ESP.text(plr, char, dist, "[MARK]", style)
			end
			return nil
		end,
	})

	-- actions ----------------------------------------------------------
	local function doTp(arg)
		local plr = resolveTarget(arg)
		if not plr then
			return
		end
		local root, troot = Util.root(), usable(plr) and Util.rootOf(plr.Character)
		if not (root and troot) then
			notify(plr.DisplayName .. " is not available", YELLOW)
			return
		end
		root.CFrame = troot.CFrame * CFrame.new(0, 0, 4)
		root.AssemblyLinearVelocity = Vector3.zero
	end

	local function doWatch(arg)
		if arg == "" then
			if watch then
				watch = nil
				restoreCamera()
			end
			return
		end
		local plr = resolveTarget(arg)
		if not plr then
			return
		end
		if watch == plr then
			watch = nil
			restoreCamera()
		else
			watch = plr
		end
	end

	local function doOrbit(arg)
		if arg == "" then
			orbit = nil
			return
		end
		local plr = resolveTarget(arg)
		if plr then
			orbit = (orbit ~= plr) and plr or nil
		end
	end

	local function doMark(arg)
		if arg == "" then
			table.clear(marked)
		else
			local plr = resolveTarget(arg)
			if not plr then
				return
			end
			marked[plr] = (not marked[plr]) or nil
		end
		esp:setEnabled(next(marked) ~= nil)
	end

	local function doServer(note)
		if posting then
			return
		end
		local g = (getgenv and getgenv()) or _G
		local url = trim(g.FMENU_WEBHOOK)
		if url == "" and type(isfile) == "function" and type(readfile) == "function" and isfile("FMenu/webhook.txt") then
			local ok, text = pcall(readfile, "FMenu/webhook.txt")
			url = ok and trim(text) or ""
		end
		if not (url:match("^https://discord%.com/api/webhooks/") or url:match("^https://discordapp%.com/api/webhooks/")) then
			notify("server: put your webhook URL in FMenu/webhook.txt (or getgenv().FMENU_WEBHOOK)", YELLOW)
			return
		end
		local fn = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
		if not fn then
			notify("server: your executor has no request() function", RED)
			return
		end
		posting = true
		task.spawn(function()
			local placeId, jobId = game.PlaceId, game.JobId
			local name = "Roblox server"
			pcall(function()
				name = MarketplaceService:GetProductInfo(placeId).Name
			end)
			local fields = {
				{ name = "Players", value = ("%d / %d"):format(#Players:GetPlayers(), Players.MaxPlayers), inline = true },
				{ name = "Place id", value = tostring(placeId), inline = true },
			}
			if note and note ~= "" then
				fields[#fields + 1] = { name = "Note", value = note:sub(1, 200) }
			end
			fields[#fields + 1] = {
				name = "Join this server (run in the executor)",
				value = ("```lua\ngame:GetService(\"TeleportService\"):TeleportToPlaceInstance(%d, \"%s\")\n```"):format(placeId, jobId),
			}
			local body = HttpService:JSONEncode({
				username = "FMenu",
				embeds = { {
					title = name,
					url = ("https://www.roblox.com/games/%d"):format(placeId),
					color = 0x8B7DFF,
					fields = fields,
				} },
			})
			local ok, res = pcall(fn, {
				Url = url,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body = body,
			})
			local code = ok and type(res) == "table" and res.StatusCode or nil
			if code and code >= 200 and code < 300 then
				notify("server bookmarked", GREEN)
			else
				notify("webhook failed" .. (code and (" (" .. code .. ")") or ""), RED)
			end
			posting = false
		end)
	end

	-- every frame: keeps watch / orbit going, drops targets that left or died --
	table.insert(conns, RunService.Heartbeat:Connect(function(dt)
		if watch then
			if usable(watch) then
				local cam, hum = workspace.CurrentCamera, Util.humanoid(watch.Character)
				if cam and hum and cam.CameraSubject ~= hum then
					cam.CameraSubject = hum
				end
			else
				watch = nil
				restoreCamera()
			end
		end
		if orbit then
			if usable(orbit) then
				local root, troot = Util.root(), Util.rootOf(orbit.Character)
				if root and troot then
					angle += Games.ORBIT_SPEED * dt
					local pos = troot.Position + Vector3.new(
						math.cos(angle) * Games.ORBIT_RADIUS,
						Games.ORBIT_HEIGHT,
						math.sin(angle) * Games.ORBIT_RADIUS
					)
					root.CFrame = CFrame.lookAt(pos, Vector3.new(troot.Position.X, pos.Y, troot.Position.Z))
					root.AssemblyLinearVelocity = Vector3.zero
				end
			else
				orbit = nil
			end
		end
		for plr in pairs(marked) do
			if plr.Parent == nil then
				marked[plr] = nil
			end
		end
		esp:step(dt)
	end))

	table.insert(conns, Players.PlayerRemoving:Connect(function(plr)
		if watch == plr then
			watch = nil
			restoreCamera()
		end
		if orbit == plr then
			orbit = nil
		end
		marked[plr] = nil
	end))

	if Games.SERVER_KEY then
		table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == Games.SERVER_KEY then
				doServer("")
			end
		end))
	end

	-- chat hooks -------------------------------------------------------
	local commands = {
		{ name = "FMenuTp", alias = "/tp", run = doTp },
		{ name = "FMenuWatch", alias = "/watch", run = doWatch },
		{ name = "FMenuOrbit", alias = "/orbit", run = doOrbit },
		{ name = "FMenuMark", alias = "/mark", run = doMark },
		{ name = "FMenuServer", alias = "/server", run = doServer },
	}
	-- text after the command: "/server good lobby" -> "good lobby"
	local function argsOf(text)
		return trim((tostring(text or ""):gsub("^%s*%S+", "", 1)))
	end
	local newChat = TextChatService.ChatVersion == Enum.ChatVersion.TextChatService
	for _, def in ipairs(commands) do
		local hooked = false
		if newChat then
			local ok, cmd = pcall(function()
				local c = Instance.new("TextChatCommand")
				c.Name = def.name
				c.PrimaryAlias = def.alias
				c.Parent = TextChatService
				return c
			end)
			if ok and cmd then
				table.insert(cmds, cmd)
				table.insert(conns, cmd.Triggered:Connect(function(_source, text)
					def.run(argsOf(text))
				end))
				hooked = true
			end
		end
		if not hooked then
			table.insert(conns, lp.Chatted:Connect(function(msg)
				local line = trim(msg):lower()
				if line == def.alias or line:sub(1, #def.alias + 1) == def.alias .. " " then
					def.run(argsOf(msg))
				end
			end))
		end
	end

	return {
		destroy = function()
			for _, c in ipairs(conns) do
				c:Disconnect()
			end
			table.clear(conns)
			if watch then
				restoreCamera()
			end
			watch, orbit = nil, nil
			table.clear(marked)
			esp:setEnabled(false)
			for _, cmd in ipairs(cmds) do
				pcall(cmd.Destroy, cmd)
			end
		end,
	}
end

return Games
