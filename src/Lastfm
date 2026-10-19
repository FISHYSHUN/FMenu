-- ModuleScript: LastFm
-- Shows the song you are listening to on the minimized pill: cover, artist, title, progress bar + time.
--   LastFm.features  { lastfm = { set, step, destroy } }, merged into Functionality's registry
--
-- Needs a Last.fm username and API key (free: https://www.last.fm/api/account/create) and a scrobbler that
-- reports to your Last.fm account (Spotify, Apple Music, Last.fm desktop scrobbler, ...). Both are typed into the
-- right-click menu of the "Last.fm on pill" row (Config tab). Alternative before running the loader:
--     getgenv().FMENU_LASTFM = { user = "name", key = "apikey" }
--
-- What Last.fm can and cannot tell us:
--   * "now playing" track, artist and cover: yes (user.getRecentTracks)
--   * song length: yes (track.getInfo), missing for some tracks
--   * the playback position: NO. The time shown is an estimate: the previous scrobble is stamped with the moment
--     that song started, so this song started roughly (that time + its length). When that does not add up the
--     counter starts from when the menu first noticed the song. Pausing or seeking is not visible to it.
--   * cover art needs writefile + getcustomasset from the executor (Roblox cannot load web images). Without them
--     the cover circle shows the first letter of the title. Covers are cached in FMenu/cache/.

local import = ...
local Util = import("Util")

local HttpService = game:GetService("HttpService")

local lerp = Util.lerp

local LastFm = { features = {} }
local features = LastFm.features

local API = "https://ws.audioscrobbler.com/2.0/"
local NO_ART = "2a96cbd8b46e442fc41c2b86b821562f" -- Last.fm's grey "no cover" placeholder

local function trim(s)
	return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
end

-- one API call -> decoded table, or nil + reason
local function call(params)
	local q = {}
	for k, v in pairs(params) do
		q[#q + 1] = k .. "=" .. HttpService:UrlEncode(tostring(v))
	end
	q[#q + 1] = "format=json"
	local ok, body = pcall(function()
		return game:HttpGet(API .. "?" .. table.concat(q, "&"))
	end)
	if not ok then
		return nil, "request failed"
	end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if not ok2 or type(data) ~= "table" then
		return nil, "bad response"
	end
	if data.error then
		return nil, data.message or ("error " .. tostring(data.error))
	end
	return data
end

local function artistOf(t)
	local a = t.artist
	if type(a) == "table" then
		return a["#text"] or a.name or ""
	end
	return tostring(a or "")
end

-- largest cover url (the list goes small -> extralarge), nil for the placeholder
local function imageOf(t)
	local best
	for _, im in ipairs(t.image or {}) do
		local url = im["#text"]
		if type(url) == "string" and url ~= "" then
			best = url
		end
	end
	if best and best:find(NO_ART, 1, true) then
		return nil
	end
	return best
end

local state = {
	on = false,
	cfg = {},
	interval = 10,
	acc = 0,
	prog = 0,
	busy = false,
	id = nil, -- "artist|title" of the song on the pill
	missing = 0, -- polls in a row without a now-playing song
	warned = false,
	base = 0,
	baseClock = 0,
	duration = nil,
	user = nil,
	key = nil,
}

local durations = {} -- "artist|title" -> seconds or false

local function durationOf(apiKey, artist, title)
	local id = artist .. "|" .. title
	if durations[id] ~= nil then
		return durations[id] or nil
	end
	local data = call({ method = "track.getInfo", api_key = apiKey, artist = artist, track = title, autocorrect = 1 })
	local ms = data and data.track and tonumber(data.track.duration) or 0
	durations[id] = ms > 0 and ms / 1000 or false
	return durations[id] or nil
end

-- downloads a cover into FMenu/cache and returns a rbxasset url, nil when the executor cannot do it
local function coverAsset(url)
	if not (writefile and isfile and getcustomasset) then
		return nil
	end
	local name = (url:match("([^/]+)$") or "cover"):gsub("[^%w%._%-]", "_")
	if not name:match("%.%w+$") then
		name = name .. ".png"
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

local function credentials()
	local g = (getgenv and getgenv()) or _G
	local fallback = type(g.FMENU_LASTFM) == "table" and g.FMENU_LASTFM or {}
	local user = trim(state.cfg.user)
	local key = trim(state.cfg.key)
	if user == "" then
		user = trim(fallback.user)
	end
	if key == "" then
		key = trim(fallback.key)
	end
	return user, key
end

local function clearPill(ctx)
	state.id, state.duration, state.missing = nil, nil, 0
	ctx.ui:setNowPlaying(nil)
end

local function poll(ctx)
	local user, key = credentials()
	if user == "" or key == "" then
		return
	end
	local data, err = call({ method = "user.getrecenttracks", user = user, api_key = key, limit = 2 })
	if not state.on then
		return
	end
	if not data then
		if not state.warned then
			state.warned = true
			ctx.notify("last.fm: " .. tostring(err), Color3.fromRGB(255, 84, 96))
		end
		return
	end
	state.warned = false

	local list = data.recenttracks and data.recenttracks.track
	if type(list) == "table" and list.name then
		list = { list } -- a single track comes back as an object, not a list
	end
	local first = type(list) == "table" and list[1]
	local playing = first and first["@attr"] and first["@attr"].nowplaying == "true"
	if not playing then
		state.missing += 1
		if state.missing >= 2 and state.id then
			clearPill(ctx) -- debounced: one empty answer is often just a track change
		end
		return
	end
	state.missing = 0

	local title, artist = tostring(first.name or ""), artistOf(first)
	local id = artist .. "|" .. title
	if id == state.id then
		return
	end
	state.id = id

	local duration = durationOf(key, artist, title)
	-- where in the song are we? see the note at the top of the file
	local elapsed = 0
	local prev = list[2]
	if prev and prev.date and tonumber(prev.date.uts) then
		local prevLen = durationOf(key, artistOf(prev), tostring(prev.name or ""))
		if prevLen then
			local e = os.time() - (tonumber(prev.date.uts) + prevLen)
			if e >= 0 and (not duration or e <= duration) then
				elapsed = e
			end
		end
	end
	state.base, state.baseClock, state.duration = elapsed, os.clock(), duration

	ctx.ui:setNowPlaying({ title = title, artist = artist, showProgress = state.cfg.progress ~= false })
	if state.cfg.notify then
		ctx.notify(("%s - %s"):format(artist, title), Color3.fromRGB(139, 125, 255))
	end

	local url = imageOf(first)
	if url then
		task.spawn(function()
			local asset = coverAsset(url)
			if asset and state.on and state.id == id then
				ctx.ui:setCover(asset)
			end
		end)
	end
end

features.lastfm = {
	set = function(on, v, ctx, o)
		state.cfg = o
		state.interval = lerp(5, 30, v)
		local user, key = credentials()
		local changed = user ~= state.user or key ~= state.key
		state.user, state.key = user, key
		if on and (not state.on or changed) then
			state.acc = state.interval -- poll right away
			state.warned = false
			if changed and state.id then
				clearPill(ctx)
			end
			if user == "" or key == "" then
				ctx.notify("last.fm: right-click this row and enter your username + API key", Color3.fromRGB(255, 214, 64))
			end
		end
		if not on and state.on then
			clearPill(ctx)
		end
		state.on = on
	end,
	step = function(dt, ctx)
		if not state.on then
			return
		end
		state.acc += dt
		if state.acc >= state.interval and not state.busy then
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
				ctx.ui:setProgress(state.base + (os.clock() - state.baseClock), state.duration)
			end
		end
	end,
	destroy = function()
		state.on = false
	end,
}

return LastFm
