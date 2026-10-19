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
local range = Util.range

local Games = {}

Games.index = {
	mm2 = { module = "games/MM2", places = { 142823291 }, names = { "murder mystery" } },
	-- the lobby is 17625359962, matches run in other places of the same universe (GameId from memory,
	-- check it with print(game.GameId) if the tab still does not show up)
	rivals = { module = "games/Rivals", places = { 17625359962 }, universes = { 6035872082 }, names = { "rivals" } },
	nds = { module = "games/NaturalDisasters", places = { 189707 }, names = { "natural disaster" } },
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
		{ header = "Behaviour" },
		{ id = "autohide", label = "Auto-hide", slider = "Delay (1-10 s)", value = 33, on = true, fmt = range(1, 10, "s") },
		{ id = "hudlock", label = "Lock HUD", slider = "Unused", value = 0, on = false },
		{ id = "notifs", label = "Notifications", slider = "Unused", value = 0, on = true },
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

return Games
