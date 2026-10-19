-- ModuleScript: ServerShare
-- Type /share in chat and the current server is posted to your Discord webhook: game name, game link and a join
-- link for this exact server (JobId). Nothing about other players is sent, only how many are in the server.
--
-- Where the webhook lives (never put it in the repo, anyone who can read the repo could spam or delete it):
--   * getgenv().FMENU_WEBHOOK = "https://discord.com/api/webhooks/..." before running the loader, or
--   * a file FMenu/webhook.txt in the executor's workspace folder containing only the url
--
-- /share is a TextChatCommand on the new chat (not sent to the server, nobody sees it). On old chat it falls back
-- to Player.Chatted, where the line is visible.
--
--   ServerShare.new({ notify = Functionality.notify }) -> object with :send() :destroy()

local import = ...

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")

local lp = Players.LocalPlayer

local ServerShare = {}
ServerShare.__index = ServerShare
ServerShare.COMMAND = "/share"

local RED = Color3.fromRGB(255, 84, 96)
local GREEN = Color3.fromRGB(72, 214, 134)
local YELLOW = Color3.fromRGB(255, 214, 64)

local function trim(s)
	return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
end

local function webhookUrl()
	local g = (getgenv and getgenv()) or _G
	local url = trim(g.FMENU_WEBHOOK)
	if url == "" and type(isfile) == "function" and type(readfile) == "function" then
		local ok, text = pcall(function()
			if isfile("FMenu/webhook.txt") then
				return readfile("FMenu/webhook.txt")
			end
		end)
		url = ok and trim(text) or ""
	end
	if url:match("^https://discord%.com/api/webhooks/") or url:match("^https://discordapp%.com/api/webhooks/") then
		return url
	end
	return nil
end

function ServerShare.new(deps)
	local self = setmetatable({}, ServerShare)
	self.notify = deps.notify or function() end
	self._conns = {}
	self.busy = false
	self:_hookChat()
	return self
end

function ServerShare:send()
	if self.busy then
		return
	end
	local url = webhookUrl()
	if not url then
		self.notify("share: put your webhook in FMenu/webhook.txt or getgenv().FMENU_WEBHOOK", YELLOW)
		return
	end
	local fn = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
	if not fn then
		self.notify("share: your executor has no request() function", RED)
		return
	end
	self.busy = true
	task.spawn(function()
		local placeId, jobId = game.PlaceId, game.JobId
		local name = "Roblox server"
		pcall(function()
			name = MarketplaceService:GetProductInfo(placeId).Name
		end)
		local count = #Players:GetPlayers()
		local body = HttpService:JSONEncode({
			username = "FMenu",
			embeds = { {
				title = name,
				url = ("https://www.roblox.com/games/%d"):format(placeId),
				color = 0x8B7DFF,
				fields = {
					{ name = "Players", value = ("%d / %d"):format(count, Players.MaxPlayers), inline = true },
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
		self.busy = false
		local code = ok and type(res) == "table" and res.StatusCode or nil
		if code and code >= 200 and code < 300 then
			self.notify("share: server posted", GREEN)
		else
			self.notify("share: failed" .. (code and (" (" .. code .. ")") or ""), RED)
		end
	end)
end

function ServerShare:_hookChat()
	local hooked = false
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		local ok, cmd = pcall(function()
			local c = Instance.new("TextChatCommand")
			c.Name = "FMenuShare"
			c.PrimaryAlias = ServerShare.COMMAND
			c.Parent = TextChatService
			return c
		end)
		if ok and cmd then
			self.cmd = cmd
			table.insert(self._conns, cmd.Triggered:Connect(function()
				self:send()
			end))
			hooked = true
		end
	end
	if not hooked then
		table.insert(self._conns, lp.Chatted:Connect(function(msg)
			if msg:lower():match("^%s*" .. ServerShare.COMMAND:gsub("%p", "%%%0") .. "%s*$") then
				self:send()
			end
		end))
	end
end

function ServerShare:destroy()
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self.cmd then
		pcall(self.cmd.Destroy, self.cmd)
	end
end

return ServerShare
