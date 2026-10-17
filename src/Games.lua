-- ModuleScript: Games
-- Every game gets the universal tabs below. If the place is recognised, one extra tab with that
-- game's rows is inserted before Config and the game module's features are registered.
--
-- row = { id, label, slider (popover title), value (0-100), on, fmt? }
--   id must match a feature in Functionality.lua or in the game module's `features` table.
--   fmt turns the 0-100 slider value into what the user sees (Util.range(lo, hi, unit)).
--   max 6 rows per tab (UI.CONFIG.MaxRowsPerTab).
--
-- To add a game: print(game.PlaceId, game.GameId) in the executor, add an entry to Games.index and a
-- module in src/games/ that returns { name, tab = { name, rows }, features = { ... } }.

local import = ...
local Util = import("Util")
local range = Util.range

local Games = {}

Games.index = {
	mm2 = { module = "games/MM2", places = { 142823291 }, names = { "murder mystery" } },
	rivals = { module = "games/Rivals", places = { 17625359962 }, names = { "rivals" } },
	nds = { module = "games/NaturalDisasters", places = { 189707 }, names = { "natural disaster" } },
}

local baseTabs = {
	{ name = "Main", rows = {
		{ id = "overlay", label = "Overlay", slider = "Opacity", value = 80, on = true, fmt = range(0, 100, "%") },
		{ id = "crosshair", label = "Crosshair", slider = "Crosshair size", value = 40, on = false, fmt = range(4, 40, "px") },
		{ id = "fps", label = "Show FPS", slider = "Refresh rate", value = 60, on = true, fmt = range(1, 10, "/s") },
		{ id = "ping", label = "Show ping", slider = "Refresh rate", value = 40, on = false, fmt = range(1, 10, "/s") },
		{ id = "clock", label = "Show clock", slider = "24h / 12h (50+)", value = 0, on = false, fmt = function(v) return v >= 50 and "12h" or "24h" end },
		{ id = "compact", label = "Compact mode", slider = "Shrink amount", value = 50, on = false, fmt = range(0, 25, "%") },
	} },
	{ name = "Player", rows = {
		{ id = "speed", label = "Speed", slider = "Walk speed", value = 30, on = false, fmt = range(16, 150) },
		{ id = "jump", label = "High jump", slider = "Jump power", value = 25, on = false, fmt = range(50, 300) },
		{ id = "infjump", label = "Infinite jump", slider = "Unused", value = 0, on = false },
		{ id = "noclip", label = "Noclip", slider = "Unused", value = 0, on = false },
		{ id = "fly", label = "Fly", slider = "Fly speed", value = 35, on = false, fmt = range(20, 200) },
		{ id = "clicktp", label = "Ctrl+click TP", slider = "Unused", value = 0, on = false },
	} },
	{ name = "Visual", rows = {
		{ id = "esp", label = "Player ESP", slider = "Max distance", value = 50, on = false, fmt = range(100, 2000, " st") },
		{ id = "tracers", label = "Tracers", slider = "Thickness", value = 0, on = false, fmt = range(1, 4, "px") },
		{ id = "fov", label = "Field of view", slider = "FOV (40-120)", value = 50, on = false, fmt = range(40, 120) },
		{ id = "brightness", label = "Brightness", slider = "Brightness (0-6)", value = 35, on = false, fmt = range(0, 6) },
		{ id = "fullbright", label = "Fullbright", slider = "Ambient level", value = 100, on = false, fmt = range(50, 100, "%") },
		{ id = "nofog", label = "No fog", slider = "Unused", value = 0, on = false },
	} },
	{ name = "Utility", rows = {
		{ id = "timeOfDay", label = "Time of day", slider = "Hour (0-24)", value = 60, on = false, fmt = range(0, 24, "h") },
		{ id = "lowgfx", label = "Low graphics", slider = "Unused", value = 0, on = false },
		{ id = "antiafk", label = "Anti-AFK", slider = "Unused", value = 0, on = true },
	} },
	{ name = "Config", rows = {
		{ id = "reducedMotion", label = "Reduced motion", slider = "Unused", value = 0, on = false },
		{ id = "autohide", label = "Auto-hide", slider = "Delay (1-10 s)", value = 33, on = true, fmt = range(1, 10, "s") },
	} },
}

local function matchGame(placeId, gameName)
	for key, entry in pairs(Games.index) do
		for _, id in ipairs(entry.places) do
			if id == placeId then
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
	local key = matchGame(placeId, gameName)
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
