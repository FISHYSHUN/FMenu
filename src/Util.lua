-- ModuleScript: Util
-- Small shared helpers for Functionality, ESP and the per-game modules.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Util = {}

function Util.make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

-- slider value (0-100) -> lo..hi
function Util.lerp(lo, hi, v)
	return lo + (hi - lo) * v / 100
end

-- Cheat level. Every cheat that has a "Mode" option scales itself by one of these profiles.
--   power   how much of the slider's boost above normal is applied (speed, jump, fly, vehicle, clicks)
--   aim     aim assist pull strength multiplier        fov     aim FOV radius multiplier
--   smooth  minimum aim-lock smoothing (0-100)         delay / jitter  minimum trigger reaction and random extra (ms)
local PROFILES = {
	Blatant = { power = 1, aim = 1, fov = 1, smooth = 0, delay = 0, jitter = 0 },
	Semi = { power = 0.55, aim = 0.6, fov = 0.7, smooth = 35, delay = 80, jitter = 60 },
	Legit = { power = 0.25, aim = 0.35, fov = 0.5, smooth = 70, delay = 150, jitter = 120 },
}
Util.LEVELS = { "Blatant", "Semi", "Legit" }

function Util.level(name)
	return PROFILES[name] or PROFILES.Blatant
end

-- the "Mode" control for a row's right-click menu
function Util.modeOption()
	return { type = "choice", key = "mode", label = "Mode", choices = Util.LEVELS, default = "Blatant" }
end

-- row formatter: shows the real value instead of 0-100, e.g. fmt = Util.range(16, 150, " sp")
function Util.range(lo, hi, unit)
	return function(v)
		return ("%d%s"):format(math.floor(Util.lerp(lo, hi, v) + 0.5), unit or "")
	end
end

-- connection / instance / callback bag. bag:add(x) returns x, bag:clean() releases everything.
function Util.bag()
	local items = {}
	local bag = {}
	function bag:add(x)
		items[#items + 1] = x
		return x
	end
	function bag:clean()
		for i = #items, 1, -1 do
			local x = items[i]
			local t = typeof(x)
			if t == "RBXScriptConnection" then
				x:Disconnect()
			elseif t == "Instance" then
				x:Destroy()
			elseif t == "function" then
				pcall(x)
			elseif t == "thread" then
				pcall(task.cancel, x)
			elseif t == "table" and x.destroy then
				pcall(x.destroy, x)
			end
			items[i] = nil
		end
	end
	return bag
end

function Util.character()
	return Players.LocalPlayer.Character
end

function Util.root(char)
	char = char or Players.LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

function Util.humanoid(char)
	char = char or Players.LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function Util.alive(char)
	local hum = Util.humanoid(char)
	return hum ~= nil and hum.Health > 0
end

-- Strict versions for OTHER players' characters. The plain root/humanoid/alive above fall back to YOUR
-- character when given nil, which silently turns "player has no character" into "you" (that is what made
-- ESP throw while somebody was respawning).
function Util.isAlive(char)
	if not char then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

function Util.rootOf(char)
	return char and char:FindFirstChild("HumanoidRootPart") or nil
end

-- settings several modules read (set by Functionality's rows)
Util.flags = { hideTeam = false }

function Util.isTeammate(plr)
	return plr.Team ~= nil and plr.Team == Players.LocalPlayer.Team
end

-- walks up from a part to the Player whose character contains it
function Util.playerFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local plr = Players:GetPlayerFromCharacter(model)
		if plr then
			return plr
		end
		local parent = model.Parent
		model = parent and parent:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- line of sight from `origin` to `part` (ignores the local character)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

function Util.rayParams()
	local char = Players.LocalPlayer.Character
	rayParams.FilterDescendantsInstances = char and { char } or {}
	return rayParams
end

function Util.visible(origin, part)
	local hit = workspace:Raycast(origin, part.Position - origin, Util.rayParams())
	return hit == nil or hit.Instance:IsDescendantOf(part.Parent)
end

-- Parents a ScreenGui where it draws above Roblox's own core gui (top bar, chat, player list):
-- gethui() / CoreGui when the executor allows it, PlayerGui otherwise (core gui can cover it there).
function Util.mount(gui)
	local parent
	if gethui then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then
			parent = h
		end
	end
	if not parent then
		local ok, core = pcall(game.GetService, game, "CoreGui")
		if ok then
			parent = core
		end
	end
	if parent then
		local ok = pcall(function()
			gui.Parent = parent
		end)
		if ok and gui.Parent == parent then
			return gui
		end
	end
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

-- pointer position of an input in the same space as a gui with IgnoreGuiInset = true
function Util.pointer(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
	end
	return UserInputService:GetMouseLocation()
end

-- Downloads a web image into FMenu/cache/ and returns a rbxasset url for an ImageLabel (Roblox cannot load web
-- images itself). nil when the executor has no writefile / getcustomasset or the download fails.
function Util.coverAsset(url)
	if not (writefile and isfile and getcustomasset) then
		return nil
	end
	local name = (url:match("([^/]+)$") or "cover"):gsub("[^%w%._%-]", "_")
	if not name:match("%.%w+$") then
		name = name .. ".jpg"
	end
	pcall(function()
		if makefolder and isfolder then
			if not isfolder("FMenu") then
				makefolder("FMenu")
			end
			if not isfolder("FMenu/cache") then
				makefolder("FMenu/cache")
			end
		end
	end)
	local path = "FMenu/cache/" .. name
	if not isfile(path) then
		local ok, data = pcall(function()
			return game:HttpGet(url)
		end)
		if not ok or type(data) ~= "string" or #data == 0 then
			return nil
		end
		if not pcall(writefile, path, data) then
			return nil
		end
	end
	local ok, asset = pcall(getcustomasset, path)
	return ok and asset or nil
end

return Util
