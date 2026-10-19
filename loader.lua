-- FMenu loader
-- run:  loadstring(game:HttpGet("https://raw.githubusercontent.com/FISHYSHUN/FMenu/main/loader.lua"))()
--
-- Survives teleports: queues itself with queue_on_teleport so the menu is rebuilt (and the right game tab
-- picked) in every place you land in, e.g. Rivals lobby -> match.
--
-- Settings are saved per game to FMenu/<profile>.json (needs writefile / readfile in the executor).
--
-- Every module in src/ is fetched from the same branch, executed once and cached. Each module gets
-- `import` as its first vararg (`local import = ...`). Re-running the loader tears down the old menu
-- first, so you can execute it again after pushing changes.
--
-- Testing a fork or branch: set getgenv().FMENU_BASE = "https://raw.githubusercontent.com/<user>/FMenu/<branch>/src/"
-- before running the loader.

local genv = (getgenv and getgenv()) or _G

if genv.FMenu and genv.FMenu.destroy then
	pcall(genv.FMenu.destroy)
	genv.FMenu = nil
end

local BASE = genv.FMENU_BASE or "https://raw.githubusercontent.com/FISHYSHUN/FMenu/main/src/"
local cache = {}

local function import(name)
	if cache[name] ~= nil then
		return cache[name]
	end
	local ok, src = pcall(function()
		return game:HttpGet(BASE .. name .. ".lua")
	end)
	if not ok then
		error(("[FMenu] could not fetch %s (%s)"):format(name, tostring(src)), 0)
	end
	local fn, err = loadstring(src, "=FMenu/" .. name)
	if not fn then
		error(("[FMenu] %s failed to compile: %s"):format(name, tostring(err)), 0)
	end
	local mod = fn(import)
	if mod == nil then
		error(("[FMenu] %s returned nothing: is src/%s.lua uploaded completely (it must end with 'return')?"):format(name, name), 0)
	end
	cache[name] = mod
	return mod
end

if not game:IsLoaded() then
	game.Loaded:Wait()
end

-- Some games (Rivals) move you between places: the lobby is one place, every match another. A teleport
-- kills every running script, so queue this loader to run again as soon as the next place loads.
-- (FMENU_BOOTED stops duplicate queued copies from building the menu more than once per server.)
-- Opt out with getgenv().FMENU_NO_REQUEUE = true before running the loader.
local queueTp = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
if queueTp and not genv.FMENU_NO_REQUEUE then
	local loaderUrl = genv.FMENU_LOADER or "https://raw.githubusercontent.com/FISHYSHUN/FMenu/main/loader.lua"
	local lines = {
		"local g = (getgenv and getgenv()) or _G",
		"if g.FMENU_BOOTED == game.JobId then return end",
		"g.FMENU_BOOTED = game.JobId",
	}
	if genv.FMENU_BASE then
		lines[#lines + 1] = ("g.FMENU_BASE = %q"):format(genv.FMENU_BASE)
	end
	lines[#lines + 1] = ("loadstring(game:HttpGet(%q))()"):format(loaderUrl)
	pcall(queueTp, table.concat(lines, "\n"))
end

local Animations = import("Animations")
local UI = import("UI")
local Functionality = import("Functionality")
local Games = import("Games")
local Config = import("Config")

local profile = Games.resolve(game.PlaceId, game.Name)

-- saved settings: one file per game profile (FMenu/<profile>.json). Applied to the rows before the UI is built.
local cfg = Config.new(profile.name)
local saved = cfg:load()
Config.apply(profile.tabs, saved)
Functionality.setPositions(saved and saved.huds)
if saved then
	print(("[FMenu] loaded saved settings from %s"):format(cfg.path))
end

local ui = UI.new({ Animations = Animations, title = "FMenu", profileName = profile.name })
ui:build(profile.tabs)

Functionality.init({ ui = ui, animations = Animations, profileName = profile.name, config = cfg })
for id, def in pairs(profile.features) do
	Functionality.register(id, def)
end

-- what gets written: every switch row (value + right-click options) and where the HUD labels were dragged to
cfg.collect = function()
	local rows = {}
	for _, row in ipairs(ui:rows()) do
		if not row.button then
			rows[row.id] = { on = row.on, value = row.value, opts = row.optv, bind = row.bind }
		elseif row.bind then
			rows[row.id] = { bind = row.bind }
		end
	end
	return { rows = rows, huds = Functionality.getPositions() }
end

ui.onChanged = function(id, enabled, value, opts)
	Functionality.set(id, enabled, value, opts)
	cfg:touch()
end
-- a keybind fired: say what it did
ui.onBound = function(row)
	if not row.button then
		Functionality.notify(row.label .. (row.on and " on" or " off"), row.on and Color3.fromRGB(72, 214, 134) or Color3.fromRGB(150, 156, 172))
	end
end
Functionality.onHudMoved = function()
	cfg:touch()
end

-- apply the starting state of every row (restores originals for the ones that start off)
for _, row in ipairs(ui:rows()) do
	Functionality.set(row.id, row.on, row.value, row.optv)
end
ui:start()
cfg.ready = true -- from here on changes are autosaved

-- optional extras: if one fails to load or start the menu still works.
--   QuickMenu    hold Tab for the current game's cheats (src/QuickMenu.lua)
--   PlayerPanel  /isee in chat opens a player list with TP / Watch / Orbit / Mark (src/PlayerPanel.lua)
local extras = {}
local function loadExtra(name, args)
	local okMod, Mod = pcall(import, name)
	if not okMod then
		warn(("[FMenu] %s not loaded: %s"):format(name, tostring(Mod)))
		return
	end
	local okNew, obj = pcall(Mod.new, args)
	if okNew then
		extras[#extras + 1] = obj
	else
		warn(("[FMenu] %s failed to start: %s"):format(name, tostring(obj)))
	end
end
loadExtra("QuickMenu", { ui = ui, animations = Animations, profile = profile })
loadExtra("PlayerPanel", { animations = Animations, notify = Functionality.notify })

genv.FMenu = {
	profile = profile.name,
	destroy = function()
		if cfg.autosave then
			cfg:save()
		end
		for _, obj in ipairs(extras) do
			pcall(obj.destroy, obj)
		end
		Functionality.destroy()
		ui:destroy()
	end,
}
