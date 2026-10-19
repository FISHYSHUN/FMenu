-- ModuleScript: Spotify
-- Spotify as the source for the pill: cover, artist, title, REAL playback position, and buttons on the pill to
-- go to the previous song, pause / resume and skip. Takes priority over the Last.fm source while it has a song.
--   Spotify.features  { spotify = { set, step, destroy } }, merged into Functionality's registry
--
-- Setup (details in the README):
--   1. Create an app at https://developer.spotify.com/dashboard, add the redirect URI http://127.0.0.1:8888/callback
--   2. Run tools/spotify_auth.py once, it prints a refresh token
--   3. Right-click the "Spotify on pill" row and enter Client ID, Client Secret and the refresh token.
--      (Quick test instead: paste a 1 hour access token from the Spotify web console into "Access token".)
--
-- Reading what is playing works for any account. Pause / skip need Spotify Premium and an active device (open
-- Spotify somewhere). The executor must provide request() / http_request().

local import = ...
local Util = import("Util")

local HttpService = game:GetService("HttpService")

local lerp = Util.lerp

local Spotify = { features = {} }
local features = Spotify.features

local API = "https://api.spotify.com/v1"
local TOKEN_URL = "https://accounts.spotify.com/api/token"
local RED = Color3.fromRGB(255, 84, 96)
local YELLOW = Color3.fromRGB(255, 214, 64)

local function trim(s)
	return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
end

-- base64 for the Basic auth header (Roblox has no string base64 and executors differ)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(data)
	local bits = data:gsub(".", function(ch)
		local byte, r = ch:byte(), ""
		for i = 8, 1, -1 do
			r = r .. ((byte % 2 ^ i - byte % 2 ^ (i - 1) > 0) and "1" or "0")
		end
		return r
	end)
	bits = bits .. "0000"
	local out = bits:gsub("%d%d%d?%d?%d?%d?", function(chunk)
		if #chunk < 6 then
			return ""
		end
		local c = 0
		for i = 1, 6 do
			if chunk:sub(i, i) == "1" then
				c = c + 2 ^ (6 - i)
			end
		end
		return B64:sub(c + 1, c + 1)
	end)
	return out .. ({ "", "==", "=" })[#data % 3 + 1]
end

local function http(method, url, headers, body)
	local fn = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
	if not fn then
		return nil, "your executor has no request() function"
	end
	local ok, res = pcall(fn, { Url = url, Method = method, Headers = headers or {}, Body = body })
	if not ok or type(res) ~= "table" then
		return nil, "request failed"
	end
	return res
end

local function decode(body)
	local ok, data = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	return ok and type(data) == "table" and data or nil
end

local state = {
	on = false,
	cfg = {},
	interval = 3,
	acc = 0,
	prog = 0,
	busy = false,
	token = nil,
	expires = 0,
	id = nil,
	missing = 0,
	base = 0,
	baseClock = 0,
	duration = nil,
	playing = false,
	pauseUntil = 0, -- after a 429 (rate limit) polling waits until this os.clock()
	warned = nil, -- last problem that was shown, so the same one is not repeated every poll
	info = nil,
	cover = nil,
	credKey = nil,
}

local function warnOnce(ctx, text)
	if state.warned ~= text then
		state.warned = text
		ctx.notify("spotify: " .. text, RED)
	end
end

-- a usable access token: refreshed from the refresh token when those are filled in, else the pasted token
local function getToken()
	local o = state.cfg
	local id, secret, refresh = trim(o.clientId), trim(o.clientSecret), trim(o.refresh)
	if id ~= "" and secret ~= "" and refresh ~= "" then
		if state.token and os.time() < state.expires - 60 then
			return state.token
		end
		local res, err = http("POST", TOKEN_URL, {
			["Authorization"] = "Basic " .. b64(id .. ":" .. secret),
			["Content-Type"] = "application/x-www-form-urlencoded",
		}, "grant_type=refresh_token&refresh_token=" .. HttpService:UrlEncode(refresh))
		if not res then
			return nil, err
		end
		local data = decode(res.Body or "")
		if data and data.access_token then
			state.token = data.access_token
			state.expires = os.time() + (tonumber(data.expires_in) or 3600)
			return state.token
		end
		return nil, (data and (data.error_description or data.error)) or "token refresh failed"
	end
	local manual = trim(o.token)
	if manual ~= "" then
		return manual
	end
	return nil, "enter client id + secret + refresh token (or an access token) in this row's menu"
end

-- one Web API call -> response table { StatusCode, Body } or nil + reason. Refreshes the token once on a 401.
local function api(method, path)
	for attempt = 1, 2 do
		local token, err = getToken()
		if not token then
			return nil, err
		end
		local res, e = http(method, API .. path, {
			["Authorization"] = "Bearer " .. token,
			["Content-Type"] = "application/json",
		}, method ~= "GET" and "" or nil)
		if not res then
			return nil, e
		end
		if res.StatusCode == 401 and attempt == 1 and trim(state.cfg.refresh) ~= "" then
			state.token = nil -- expired: the loop gets a fresh one
		else
			return res
		end
	end
	return nil, "unauthorized"
end

local function currentSeconds()
	local e = state.base
	if state.playing then
		e += os.clock() - state.baseClock
	end
	return e
end

local function clearPill(ctx)
	state.id, state.duration, state.missing, state.info, state.cover = nil, nil, 0, nil, nil
	ctx.ui:setNowPlaying(nil, "spotify")
end

local function poll(ctx)
	local res, err = api("GET", "/me/player")
	if not state.on then
		return
	end
	if not res then
		warnOnce(ctx, tostring(err))
		return
	end
	local code = res.StatusCode
	if code == 429 then
		state.pauseUntil = os.clock() + 10
		return
	elseif code == 401 then
		warnOnce(ctx, "token rejected (expired or wrong scopes)")
		return
	elseif code == 204 or (code == 200 and (res.Body or "") == "") then
		state.missing += 1 -- nothing playing / no active device
		if state.missing >= 2 and state.id then
			clearPill(ctx)
		end
		return
	elseif code ~= 200 then
		warnOnce(ctx, "error " .. tostring(code))
		return
	end
	state.warned = nil

	local data = decode(res.Body or "")
	local item = data and data.item
	if not item then
		state.missing += 1
		if state.missing >= 2 and state.id then
			clearPill(ctx)
		end
		return
	end
	state.missing = 0

	state.base = (tonumber(data.progress_ms) or 0) / 1000
	state.baseClock = os.clock()
	state.playing = data.is_playing == true
	state.duration = (tonumber(item.duration_ms) or 0) / 1000
	ctx.ui:setPlaying(state.playing, "spotify")

	local id = tostring(item.id or item.name)
	if id == state.id then
		if state.info and not ctx.ui.npActive then
			ctx.ui:setNowPlaying(state.info, "spotify") -- the pill was taken and given back
			ctx.ui:setCover(state.cover, "spotify")
		end
		return
	end
	state.id, state.cover = id, nil

	local names = {}
	for _, a in ipairs(item.artists or {}) do
		names[#names + 1] = a.name
	end
	local artist = table.concat(names, ", ")
	if artist == "" and item.show then
		artist = item.show.publisher or item.show.name or "" -- podcasts
	end
	state.info = { title = tostring(item.name or ""), artist = artist, showProgress = state.cfg.progress ~= false }
	ctx.ui:setNowPlaying(state.info, "spotify")
	ctx.ui:setPlaying(state.playing, "spotify")
	if state.cfg.notify then
		ctx.notify(("%s - %s"):format(artist, state.info.title), Color3.fromRGB(30, 215, 96))
	end

	local images = (item.album and item.album.images) or (item.images) or {}
	local img = images[2] or images[1] -- sorted large -> small, the middle one is plenty for a 36 px circle
	if img and img.url then
		task.spawn(function()
			local asset = Util.coverAsset(img.url)
			if asset and state.on and state.id == id then
				state.cover = asset
				ctx.ui:setCover(asset, "spotify")
			end
		end)
	end
end

-- a pill button was pressed
local function control(ctx, what)
	task.spawn(function()
		local method, path
		if what == "next" then
			method, path = "POST", "/me/player/next"
		elseif what == "prev" then
			method, path = "POST", "/me/player/previous"
		else
			method, path = "PUT", state.playing and "/me/player/pause" or "/me/player/play"
			-- the button reacts at once, the next poll confirms
			state.base = currentSeconds()
			state.baseClock = os.clock()
			state.playing = not state.playing
			ctx.ui:setPlaying(state.playing, "spotify")
		end
		local res, err = api(method, path)
		if not res then
			ctx.notify("spotify: " .. tostring(err), RED)
		elseif res.StatusCode == 403 then
			ctx.notify("spotify: controls need Premium", YELLOW)
		elseif res.StatusCode == 404 then
			ctx.notify("spotify: no active device, open Spotify somewhere", YELLOW)
		elseif res.StatusCode >= 400 then
			ctx.notify("spotify: error " .. res.StatusCode, RED)
		end
		state.acc = math.max(state.acc, state.interval - 0.6) -- look again very soon
	end)
end

local function setControls(ctx, show)
	if show then
		ctx.ui:setControls({
			prev = function()
				control(ctx, "prev")
			end,
			toggle = function()
				control(ctx, "toggle")
			end,
			next = function()
				control(ctx, "next")
			end,
		}, "spotify")
	else
		ctx.ui:setControls(nil, "spotify")
	end
end

features.spotify = {
	set = function(on, v, ctx, o)
		state.cfg = o
		state.interval = lerp(2, 10, v)
		local credKey = table.concat({ trim(o.clientId), trim(o.clientSecret), trim(o.refresh), trim(o.token) }, "|")
		local changed = credKey ~= state.credKey
		state.credKey = credKey
		if changed then
			state.token, state.expires = nil, 0
		end
		if on and (not state.on or changed) then
			state.acc = state.interval -- poll right away
			state.warned = nil
			if changed and state.id then
				clearPill(ctx)
			end
			local haveRefresh = trim(o.clientId) ~= "" and trim(o.clientSecret) ~= "" and trim(o.refresh) ~= ""
			if not haveRefresh and trim(o.token) == "" then
				ctx.notify("spotify: right-click this row and fill in Client ID, secret and refresh token (see tools/spotify_auth.py)", YELLOW)
			end
		end
		if on then
			setControls(ctx, o.controls ~= false)
		elseif state.on then
			setControls(ctx, false)
			clearPill(ctx)
		end
		state.on = on
	end,
	step = function(dt, ctx)
		if not state.on then
			return
		end
		state.acc += dt
		if state.acc >= state.interval and not state.busy and os.clock() >= state.pauseUntil then
			state.acc = 0
			state.busy = true
			task.spawn(function()
				pcall(poll, ctx)
				state.busy = false
			end)
		end
		state.prog += dt
		if state.prog >= 0.25 then
			state.prog = 0
			if state.id then
				ctx.ui:setProgress(currentSeconds(), state.duration, "spotify")
			end
		end
	end,
	destroy = function()
		state.on = false
	end,
}

return Spotify
