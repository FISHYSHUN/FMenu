-- ModuleScript: Util
-- Small shared helpers for Functionality, ESP and the per-game modules.

local Players = game:GetService("Players")

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

return Util
