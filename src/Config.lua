-- ModuleScript: Config
-- Saves every row (on / slider value / right-click options) plus the spots you dragged the HUD labels to,
-- one JSON file per game profile: FMenu/<profile>.json in the executor's workspace folder.
--   local cfg = Config.new(profileName)
--   local saved = cfg:load()               -- table or nil (no file / no file access)
--   Config.apply(tabs, saved)              -- call before UI:build: rows start from the saved values
--   cfg.collect = function() return {...} end   -- builds the table that gets written
--   cfg:touch()                            -- "something changed": saves a second after the last change
--   cfg:save() / cfg:delete()
-- Needs the executor's writefile / readfile / isfile. Without them everything still works, nothing is saved.

local import = ...

local HttpService = game:GetService("HttpService")

local Config = {}
Config.__index = Config

local ROOT = "FMenu"
local VERSION = 1

local function hasFiles()
	return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

function Config.new(profileName)
	local self = setmetatable({}, Config)
	local safe = tostring(profileName or "Universal"):gsub("[^%w_%-]", "_")
	self.path = ROOT .. "/" .. safe .. ".json"
	self.autosave = true
	self.ready = false -- false while the menu is still being built, so the starting state is not "saved"
	self.collect = nil
	self._token = 0
	return self
end

function Config:available()
	return hasFiles()
end

function Config:load()
	if not hasFiles() then
		return nil
	end
	local ok, data = pcall(function()
		if not isfile(self.path) then
			return nil
		end
		return HttpService:JSONDecode(readfile(self.path))
	end)
	if ok and type(data) == "table" and data.version == VERSION then
		return data
	end
	return nil
end

function Config:save()
	if not hasFiles() or not self.collect then
		return false
	end
	local ok, err = pcall(function()
		if makefolder and isfolder and not isfolder(ROOT) then
			makefolder(ROOT)
		end
		local data = self.collect()
		data.version = VERSION
		writefile(self.path, HttpService:JSONEncode(data))
	end)
	if not ok then
		warn("[FMenu] could not save config: " .. tostring(err))
	end
	return ok
end

-- debounced autosave: waits until nothing changed for a second (dragging a slider is one save, not fifty)
function Config:touch()
	if not self.ready or not self.autosave then
		return
	end
	self._token += 1
	local token = self._token
	task.delay(1, function()
		if token == self._token and self.autosave then
			self:save()
		end
	end)
end

function Config:delete()
	if delfile and isfile and isfile(self.path) then
		pcall(delfile, self.path)
	end
end

-- writes saved values into the row definitions of the tabs (before the UI is built).
-- Remembers the original defaults on the row (defOn / defValue) so "reset" still knows them.
function Config.apply(tabs, saved)
	local rows = saved and saved.rows
	if type(rows) ~= "table" then
		return
	end
	for _, tab in ipairs(tabs) do
		for _, data in ipairs(tab.rows) do
			local s = data.id and rows[data.id]
			if type(s) == "table" then
				if data.defOn == nil then
					data.defOn = data.on == true
				end
				if data.defValue == nil then
					data.defValue = data.value
				end
				if type(s.on) == "boolean" and not data.button then
					data.on = s.on
				end
				if type(s.value) == "number" then
					data.value = math.clamp(math.floor(s.value + 0.5), 0, 100)
				end
				if type(s.opts) == "table" then
					data.optv = s.opts -- UI checks every key against the row's option definitions
				end
			end
		end
	end
end

return Config
