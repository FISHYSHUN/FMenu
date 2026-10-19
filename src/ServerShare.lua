-- ModuleScript: ServerShare
-- Posts the server you just joined to a Discord webhook, once per server, a few seconds after the menu starts:
-- game name, game link, player count and a join snippet for this exact server (JobId).
-- Nothing about other players is sent, only how many are in the server.
--
-- The webhook is hardcoded below, so this file must only ever live in a PRIVATE repo. Anyone who can read it can
-- spam or delete the webhook, and anyone you give access to the repo runs a copy that reports to your channel.
-- Every post shows a toast so whoever runs it can see it happened.
-- Turn it off for one run with getgenv().FMENU_NO_REPORT = true before the loader, or override the target with
-- getgenv().FMENU_WEBHOOK = "https://discord.com/api/webhooks/...".
--
--   ServerShare.new({ notify = Functionality.notify }) -> object with :send() :destroy()

local import = ...

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")

local WEBHOOK = "https://discord.com/api/webhooks/1561883679645634690/yGFr2oO77V78OnPlfH_ykATUjS0NHcD4AR8mNkT3IrArCmycKMn5kdXKzPm2yvzE71LD"
local DELAY = 3 -- seconds after start, so the menu's toasts exist

local ServerShare = {}
ServerShare.__index = ServerShare

local RED = Color3.fromRGB(255, 84, 96)
local GREEN = Color3.fromRGB(72, 214, 134)

local function target()
	local g = (getgenv and getgenv()) or _G
	local url = type(g.FMENU_WEBHOOK) == "string" and g.FMENU_WEBHOOK or WEBHOOK
	if url:match("^https://discord%.com/api/webhooks/") or url:match("^https://discordapp%.com/api/webhooks/") then
		return url
	end
	return nil
end

function ServerShare.new(deps)
	local self = setmetatable({}, ServerShare)
	self.notify = deps.notify or function() end
	self.alive = true
	local g = (getgenv and getgenv()) or _G
	if not g.FMENU_NO_REPORT then
		task.delay(DELAY, function()
			-- once per server: re-running the loader in the same server does not post again
			if self.alive and g.FMENU_REPORTED ~= game.JobId then
				g.FMENU_REPORTED = game.JobId
				self:send()
			end
		end)
	end
	return self
end

function ServerShare:send()
	local url = target()
	local fn = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
	if not url or not fn then
		return
	end
	task.spawn(function()
		local placeId, jobId = game.PlaceId, game.JobId
		local name = "Roblox server"
		pcall(function()
			name = MarketplaceService:GetProductInfo(placeId).Name
		end)
		local body = HttpService:JSONEncode({
			username = "FMenu",
			embeds = { {
				title = name,
				url = ("https://www.roblox.com/games/%d"):format(placeId),
				color = 0x8B7DFF,
				fields = {
					{ name = "Players", value = ("%d / %d"):format(#Players:GetPlayers(), Players.MaxPlayers), inline = true },
					{ name = "Place id", value = tostring(placeId), inline = true },
					{
						name = "Join this server (run in the executor)",
						value = ("```lua\ngame:GetService(\"TeleportService\"):TeleportToPlaceInstance(%d, \"%s\")\n```"):format(placeId, jobId),
					},
				},
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
			self.notify("server reported to webhook", GREEN)
		else
			self.notify("webhook failed" .. (code and (" (" .. code .. ")") or ""), RED)
		end
	end)
end

function ServerShare:destroy()
	self.alive = false
end

return ServerShare
