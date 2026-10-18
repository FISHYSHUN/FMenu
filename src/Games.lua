-- ModuleScript: Games
-- Every game gets the universal tabs below. If the place is recognised, one extra tab with that
-- game's rows is inserted before Config and the game module's features are registered.
--
-- row = { id, label, slider (popover title), value (0-100), on, fmt? }
--   id must match a feature in Functionality.lua or in the game module's `features` table.
--   fmt turns the 0-100 slider value into what the user sees (Util.range(lo, hi, unit)).
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
local baseTabs = {
	{ name = "Main", rows = {
		{ header = "Overlay & stats" },
		{ id = "overlay", label = "Overlay", slider = "Opacity", value = 80, on = true, fmt = range(0, 100, "%") },
		{ id = "fps", label = "Show FPS", slider = "Refresh rate", value = 60, on = true, fmt = range(1, 10, "/s") },
		{ id = "ping", label = "Show ping", slider = "Refresh rate", value = 40, on = false, fmt = range(1, 10, "/s") },
		{ id = "clock", label = "Show clock", slider = "24h / 12h (50+)", value = 0, on = false, fmt = function(v) return v >= 50 and "12h" or "24h" end },
		{ id = "coords", label = "Coordinates", slider = "Unused", value = 0, on = false },
		{ id = "speedo", label = "Speedometer", slider = "Unused", value = 0, on = false },
		{ header = "Screen" },
		{ id = "crosshair", label = "Crosshair", slider = "Crosshair size", value = 40, on = false, fmt = range(4, 40, "px") },
	} },
	{ name = "Player", rows = {
		{ header = "Movement" },
		{ id = "speed", label = "Speed", slider = "Walk speed", value = 30, on = false, fmt = range(16, 150) },
		{ id = "jump", label = "High jump", slider = "Jump power", value = 25, on = false, fmt = range(50, 300) },
		{ id = "infjump", label = "Infinite jump", slider = "Unused", value = 0, on = false },
		{ id = "bhop", label = "Bunny hop", slider = "Unused", value = 0, on = false },
		{ id = "fly", label = "Fly", slider = "Fly speed", value = 35, on = false, fmt = range(20, 200) },
		{ id = "noclip", label = "Noclip", slider = "Unused", value = 0, on = false },
		{ header = "Teleport & physics" },
		{ id = "clicktp", label = "Ctrl+click TP", slider = "Unused", value = 0, on = false },
		{ id = "gravity", label = "Gravity", slider = "Gravity", value = 50, on = false, fmt = range(20, 196) },
		{ id = "antivoid", label = "Anti-void", slider = "Unused", value = 0, on = false },
	} },
	-- Visual = what gets drawn on other players (looks are tuned in Style). World / camera settings are in Utility.
	{ name = "Visual", rows = {
		{ header = "Players" },
		{ id = "esp", label = "Player ESP", slider = "Max distance", value = 50, on = false, fmt = range(100, 2000, " st") },
		{ id = "boxes", label = "Box ESP", slider = "Max distance", value = 50, on = false, fmt = range(100, 2000, " st") },
		{ id = "tracers", label = "Tracers", slider = "Thickness", value = 0, on = false, fmt = range(1, 4, "px") },
		{ header = "Filters" },
		{ id = "hideteam", label = "Hide teammates", slider = "Unused", value = 0, on = false },
		{ id = "wallcheck", label = "Wall check", slider = "Unused", value = 0, on = false },
	} },
	{ name = "Style", rows = {
		{ header = "Chams & outline" },
		{ id = "chams", label = "Chams fill", slider = "Fill transparency", value = 80, on = true, fmt = range(0, 100, "%") },
		{ id = "outline", label = "Outline", slider = "Outline transparency", value = 0, on = true, fmt = range(0, 100, "%") },
		{ header = "Labels" },
		{ id = "espNames", label = "Names", slider = "Text size", value = 30, on = true, fmt = range(10, 20, "px") },
		{ id = "espDist", label = "Distance", slider = "Unused", value = 0, on = true },
		{ id = "espHealth", label = "Health text", slider = "Unused", value = 0, on = true },
		{ id = "espTool", label = "Held tool", slider = "Unused", value = 0, on = false },
		{ header = "Boxes" },
		{ id = "healthbar", label = "Health bar", slider = "Unused", value = 0, on = true },
		{ id = "boxfill", label = "Box fill", slider = "Fill opacity", value = 20, on = false, fmt = range(0, 100, "%") },
		{ id = "boxthick", label = "Box thickness", slider = "Thickness", value = 17, on = true, fmt = range(1, 4, "px") },
		{ header = "Colors" },
		{ id = "hpcolor", label = "Health colors", slider = "Unused", value = 0, on = false },
		{ id = "rainbow", label = "Rainbow", slider = "Speed", value = 30, on = false, fmt = range(1, 10) },
		{ id = "customcolor", label = "Custom color", slider = "Hue", value = 0, on = false, fmt = range(0, 360, "deg") },
		{ header = "Tracers & speed" },
		{ id = "tracerFrom", label = "Tracer origin", slider = "Bottom / Center / Top", value = 0, on = true, fmt = function(v) return v < 34 and "Bottom" or (v < 67 and "Center" or "Top") end },
		{ id = "espRate", label = "ESP refresh", slider = "Updates per second", value = 40, on = true, fmt = range(4, 30, "/s") },
	} },
	{ name = "Utility", rows = {
		{ header = "World" },
		{ id = "timeOfDay", label = "Time of day", slider = "Hour (0-24)", value = 60, on = false, fmt = range(0, 24, "h") },
		{ id = "brightness", label = "Brightness", slider = "Brightness (0-6)", value = 35, on = false, fmt = range(0, 6) },
		{ id = "fullbright", label = "Fullbright", slider = "Ambient level", value = 100, on = false, fmt = range(50, 100, "%") },
		{ id = "nofog", label = "No fog", slider = "Unused", value = 0, on = false },
		{ id = "lowgfx", label = "Low graphics", slider = "Unused", value = 0, on = false },
		{ header = "Camera" },
		{ id = "fov", label = "Field of view", slider = "FOV (40-120)", value = 50, on = false, fmt = range(40, 120) },
		{ id = "zoom", label = "Hold-C zoom", slider = "Zoom FOV", value = 40, on = false, fmt = range(10, 60) },
		{ id = "maxzoom", label = "Max zoom out", slider = "Distance", value = 30, on = false, fmt = range(20, 1000, " st") },
		{ header = "Other" },
		{ id = "autoclick", label = "Auto-clicker", slider = "Clicks per second", value = 40, on = false, fmt = range(4, 30, "/s") },
		{ id = "antiafk", label = "Anti-AFK", slider = "Unused", value = 0, on = true },
	} },
	-- protection from other players' cheats. Everything here is client side: it changes what YOUR game does
	-- about other players (collisions, your own velocity, warnings), it cannot kick or ban anyone.
	{ name = "Defense", rows = {
		{ header = "Anti-fling" },
		{ id = "antifling", label = "Anti-fling", slider = "Velocity limit", value = 30, on = false, fmt = range(80, 400, " st/s") },
		{ id = "nocollide", label = "No player collision", slider = "Unused", value = 0, on = false },
		{ id = "stabilize", label = "Stabilizer", slider = "Speed cap when flung", value = 30, on = false, fmt = range(40, 300, " st/s") },
		{ header = "Cheat detection" },
		{ id = "detMove", label = "Speed / fly / tp", slider = "Sensitivity", value = 50, on = false, fmt = range(0, 100, "%") },
		{ id = "detSpin", label = "Spin / fling", slider = "Sensitivity", value = 50, on = false, fmt = range(0, 100, "%") },
		{ id = "detAim", label = "Aim snap", slider = "Sensitivity", value = 50, on = false, fmt = range(0, 100, "%") },
		{ id = "flagEsp", label = "Flag markers", slider = "Unused", value = 0, on = false },
	} },
	{ name = "Config", rows = {
		{ header = "Menu" },
		{ id = "menuOpacity", label = "Translucent menu", slider = "Opacity", value = 60, on = false, fmt = range(25, 100, "%") },
		{ id = "compact", label = "Compact mode", slider = "Shrink amount", value = 50, on = false, fmt = range(0, 25, "%") },
		{ id = "reducedMotion", label = "Reduced motion", slider = "Unused", value = 0, on = false },
		{ header = "Behaviour" },
		{ id = "autohide", label = "Auto-hide", slider = "Delay (1-10 s)", value = 33, on = true, fmt = range(1, 10, "s") },
		{ id = "hudlock", label = "Lock HUD", slider = "Unused", value = 0, on = false },
		{ id = "notifs", label = "Notifications", slider = "Unused", value = 0, on = true },
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
