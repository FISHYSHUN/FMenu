# FMenu

A client-side Roblox menu: movement, visuals, defense, trolling and per-game tabs, with per-feature settings and saved configs.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/FISHYSHUN/FMenu/main/loader.lua"))()
```

Re-running the loader tears down the old menu first. It also queues itself with `queue_on_teleport`, so the menu is rebuilt after a teleport (e.g. Rivals lobby to match).

To test a fork or branch, set this before running the loader:

```lua
getgenv().FMENU_BASE = "https://raw.githubusercontent.com/<user>/FMenu/<branch>/src/"
```

## Using the menu

| Action | Result |
|---|---|
| Click a row | Toggle the feature |
| Right-click / long-press a row | Open its settings popover |
| Mouse wheel over a slider | Nudge it |
| **Keybind** in the popover | Click it, press a key; that key toggles the row (Backspace clears, Escape cancels). Saved with the config |
| **reset** in the popover | Put that row back to its defaults (also clears its keybind) |
| Mouse wheel / drag / arrows on the tab bar | Scroll the tabs. Three are visible at once and the bar loops: scrolling either way never ends and never shows empty space |
| Drag a HUD label | Move it (position is saved) |
| `Insert` or click the header | Hide / show the menu |

Rows whose slider is "Unused" and that have no options do nothing on right-click.

## Tabs

| Tab | Contents |
|---|---|
| **Main** | Speed, jump, infinite jump, bunny hop, fly, noclip, click teleport, gravity, anti-void, auto-clicker, anti-AFK |
| **Visual** | Player ESP, Box ESP, tracers, time of day, brightness, fullbright, no fog, low graphics, FOV, hold-C zoom, max zoom out |
| **Vehicle** | Vehicle controller, see below |
| **Troll** | See below |
| **Defense** | Anti-fling, no player collision, stabilizer, cheat detection, flag markers |
| *Game tab* | Only in recognised games (MM2, Rivals, Natural Disaster Survival) |
| **Config** | Overlay and stat labels, crosshair, menu look, behaviour, saving |

## Now playing on the pill (Last.fm)

When the menu is minimized and a song is playing, the pill becomes the player: round cover on the left, artist, title and a progress bar with the time next to it. The status dot and the "FMenu" text fade out while a song is showing, so only the player is visible. It shrinks back to the normal pill when nothing is playing.

Setup:
1. Create a free API key at `https://www.last.fm/api/account/create`.
2. Make sure your player scrobbles to your Last.fm account (Spotify, Apple Music, the desktop scrobbler...).
3. **Config > Last.fm on pill**: switch it on, right-click it and enter your username and API key. The slider is how often it checks (5 to 30 s).

Alternative: `getgenv().FMENU_LASTFM = { user = "name", key = "apikey" }` before running the loader.

Limits:
- Last.fm does not report the playback position. The time is an estimate (see the top of `src/LastFm.lua`) and does not notice pausing or seeking.
- Covers need `writefile` and `getcustomasset` in the executor (cached in `FMenu/cache/`). Without them the circle shows the first letter of the title.
- Your API key is saved in plain text in the config file, so do not share `FMenu/*.json`.

## Spotify on the pill (with skip buttons)

Spotify is a second source for the pill. It shows the real playback position instead of an estimate and adds three small buttons under the progress bar and timestamp, inside the pill: previous, pause / resume and next. They are drawn as filled icons (bar + triangle, two bars, triangle + bar) and animate on hover, press and play / pause. It takes priority over Last.fm while it has a song; when it stops, Last.fm takes the pill back.

Setup:
1. `https://developer.spotify.com/dashboard` > Create app. Redirect URI: `http://127.0.0.1:8888/callback`, tick Web API.
2. On your computer run `python tools/spotify_auth.py <client_id> <client_secret>`. Your browser opens, you press Agree, and it prints a **refresh token** (one-time step).
3. **Config > Spotify on pill**: switch it on, right-click it and paste Client ID, Client secret and Refresh token.
   For a quick test you can paste a 1 hour access token into "Access token" instead.

Notes:
- Reading what is playing works for free accounts; pause / skip need **Spotify Premium** and an active device (open Spotify on a phone or computer).
- Needs `request()` / `http_request()` in the executor.
- Client secret and refresh token are saved in plain text in `FMenu/<game>.json`. Do not share that file.

## Audio volume

**Config > Audio volume** is a 0-100 volume slider for the whole game (right-click the row, the slider is the first control; 100 = the game's normal volume). Switch the row on to apply it.

- **Game sounds** (default): scales every Sound that exists now and every Sound the game creates later. When the game changes a sound's volume itself the new value is scaled too. Switching the row off puts every sound back.
- **Master volume**: changes Roblox's own game volume instead (also covers Roblox's built-in sounds) and restores it when switched off.

## Menu fit

A tab that is taller than the screen now shrinks the whole menu (down to 65%) so everything stays visible, and only scrolls if that is still not enough. Compact mode sets the base size and the auto-fit works on top of it. The menu also re-measures the screen every frame, so it can no longer stay at a stale height.

## Translucent menu

**Config > Translucent menu** now fades every menu surface together: the window, tab bar, tab buttons, rows, value badges, countdown bar, choice buttons and toasts. The settings popover never goes below 60% opacity so it stays readable over the game. Text and switches stay solid. HUD labels (FPS, ping...) have their own background option.

## Per-feature settings

Everything that used to live in the Style tab is now in the right-click menu of the feature it affects.

- **Player ESP / Box ESP:** chams, fill and outline transparency, name / distance / health / held tool, text size, color mode (Default, Custom, Rainbow, Health, Wall check), hue, rainbow speed, hide teammates, update rate. Box ESP adds box fill, thickness and health bar.
- **Tracers:** origin (Bottom / Center / Top), opacity, color mode, hide teammates.
- **Fly:** up/down speed multiplier, smoothing.
- **Click teleport:** hold key (Ctrl / Alt / Shift / None), landing height.
- **Crosshair:** thickness, opacity, custom color.
- **HUD labels (overlay, FPS, ping, clock, coordinates, speedometer):** text size, background opacity, custom color.
- **Auto-clicker:** only click while holding left mouse (on by default).
- **Infinite jump:** limit on air jumps (0 = unlimited).
- **Bunny hop:** speed gained per hop and a speed cap.
- **Anti-void:** how far above the void it triggers and how high it puts you back.
- **FOV:** re-applied every frame, so games that reset it (sprint, scopes) no longer win.
- **Zoom:** choose the key (C / Z / X / V / Q / E) and smooth or instant.
- **Rivals aim assist / lock:** choose the aim key (Right mouse / Left mouse / Shift / Always).
- **Defense:** which detectors run (speed / teleport / fly), alert cooldown, how long a flag lasts.
- **Rivals:** aim dead zone, edge falloff, FOV ring look, trigger interval, enemy ESP options.
- **MM2:** coin collect interval, role ESP options.
- **NDS:** sky platform size.

## Vehicle tab

The controller detects your car automatically: whenever your humanoid sits in an unanchored seat (`VehicleSeat` or a plain `Seat` on a custom car), that seat's assembly is the vehicle. Stand up and everything idles; sit in another car and it follows you.

| Row | What it does |
|---|---|
| Vehicle info | Draggable readout: car name and speed (st/s, km/h or mph) |
| Top speed | Raises the speed ceiling (`MaxSpeed` plus extra push); option: acceleration |
| Nitro | Hold a key for extra forward acceleration; options: key, max boost speed |
| Drift | Velocity direction lags the car's heading so it slides. Slider = how long it slides; options: drift while holding (Always / Shift / Ctrl / Alt / E / Q), hold speed while sliding |
| Steering | Sets the yaw rate directly; option: less turning at speed |
| Brake | Hold a key to shed speed fast |
| Stability | Downforce plus anti-roll |
| Auto-flip | Rights the car when upside down; option: instant flip key |
| Car jump | Hop key |
| Stay seated | Stops Space from ejecting you |

Input comes from the seat (`ThrottleFloat` / `SteerFloat`) or W A S D / arrows on custom chassis. Forward is the seat's `LookVector`. Games with server-driven cars or their own anti-cheat can override or rubber-band this.

## Cheat level (Blatant / Semi / Legit)

Cheats that scale have a **Mode** option in their right-click menu: Speed, High jump, Fly, Auto-clicker, the vehicle Top speed / Nitro / Car jump, and in Rivals Aim assist, Aim lock, FOV ring and Triggerbot.

| Mode | Effect |
|---|---|
| Blatant | Full slider values (default, same as before) |
| Semi | About 55% of the boost above normal; aim pull 60%, FOV 70%, lock smoothing at least 35%, trigger delay at least 80 ms plus random jitter |
| Legit | About 25% of the boost; aim pull 35%, FOV 50%, smoothing at least 70%, trigger delay at least 150 ms plus more jitter |

Set one cheat at a time in its own menu, or use **Config > Cheat level > Apply level to all**: switch it on and pick the level with its slider to set every Mode at once. Settings saved earlier are not overwritten when the menu starts.

## Troll tab

Client-side only. These move your own character or camera; nothing touches other players' characters, chats or spams.

| Row | What it does |
|---|---|
| Spin | Rotates your character (slider = speed) |
| Moonwalk | Faces away from where you walk |
| Vibrate | Small random shake (slider = intensity) |
| Play dead | Lies down and stays down (pose option) |
| Emote spam | Replays an emote every few seconds |
| Orbit player | Circles a target (radius, speed, height) |
| Head sit | Parks on a target's head |
| Shadow | Walks after a target, stops at a keep-distance |
| Spectate | Camera follows a target |

Player pranks use the **Target** option (Nearest or Random). The target is picked when you enable the feature and kept until they die or leave. Changing the option re-picks.

## Saving

- One file per game profile: `FMenu/<profile>.json` in the executor's workspace folder.
- Saved: every row's on/off state, slider value, right-click options, and HUD label positions.
- Autosave waits one second after the last change, so dragging a slider is a single write.
- Config tab: **Autosave** switch, **Save now**, **Reset everything**.
- Needs `writefile`, `readfile` and `isfile`. Without them the menu works normally but nothing is saved.
- A file with a different `version` number is ignored (you start from defaults).

## File layout

```
loader.lua                  entry point, fetches modules, builds menu, wires saving
src/
  Animations.lua            every tween
  UI.lua                    gui, input, settings popover
  Functionality.lua         universal feature registry + HUD helpers
  ESP.lua                   highlights, boxes, per-instance styles, option presets
  Defense.lua               anti-fling, detectors, flag markers
  Troll.lua                 troll tab + features
  Vehicle.lua               vehicle controller tab + features
  LastFm.lua                Last.fm now playing on the pill
  Spotify.lua               Spotify now playing + prev / pause / skip on the pill
  Audio.lua                 0-100 volume slider for current and incoming game audio
tools/
  spotify_auth.py           one-time helper that prints your Spotify refresh token
  Config.lua                save / load
  Games.lua                 tab definitions, game detection
  Util.lua                  shared helpers
  games/
    MM2.lua  Rivals.lua  NaturalDisasters.lua
```

## Adding a row

A row is `{ id, label, slider, value, on, fmt?, opts?, button? }`. The `id` must match a feature.

```lua
{ id = "fly", label = "Fly", slider = "Fly speed", value = 35, on = false, fmt = range(20, 200), opts = {
    { type = "slider", key = "smooth", label = "Smoothing", min = 0, max = 1, step = 0.05, pct = true, default = 0 },
    { type = "toggle", key = "vertical", label = "Vertical control", default = true },
    { type = "choice", key = "mode", label = "Mode", choices = { "A", "B" }, default = "A" },
    { type = "hue",    key = "hue", label = "Color", default = 0.5 },
} }
```

| Option type | Fields | Value |
|---|---|---|
| `slider` | `min`, `max`, `step`, `unit?`, `pct?`, `fmt?` | number |
| `hue` | rainbow track, range 0 to 1 | number |
| `toggle` | none | boolean |
| `choice` | `choices` | the chosen string |
| `text` | `placeholder?` | string (a text box) |

- `slider = "Unused"` hides the main 0-100 slider.
- `button = true` makes a click-to-run row; `set` is called with `enabled = true` per click.
- `fmt` turns the 0-100 value into display text, e.g. `Util.range(16, 150, " sp")`.

A feature is:

```lua
features.fly = {
    init    = function(ctx, hudGui) end,         -- optional, once
    set     = function(enabled, value, ctx, opts) end,  -- toggle, slider or option change
    step    = function(dt, ctx) end,             -- optional, every frame
    destroy = function() end,                    -- optional extra cleanup
}
```

`opts` is a **live table**: the UI edits it in place, so a feature can keep the reference (`cfg = opts`) and read `cfg.key` every frame. Option keys that match ESP style keys can be passed straight to `esp:configure(opts)`.

## Adding a game

1. In the executor run `print(game.PlaceId, game.GameId)`.
2. Add an entry to `Games.index` (`places`, `universes` and/or `names`).
3. Create `src/games/<Name>.lua` returning `{ name, tab = { name, rows }, features = { ... } }`.

## Notes and limits

- Everything is client side and heuristic. Defense detectors can flag vehicles, dashes and round teleports, so treat a flag as "worth a look".
- Some tool and object names in the game modules (MM2 "Knife", "Gun", "GunDrop", "Coin_Server"; NDS disaster words) are from memory and may need adjusting against the live game.
- Roblox only renders about 31 Highlights at once. ESP caps them at 28 and the nearest players get them; the rest keep their name tag.
- Using scripts like this in online games breaks Roblox's Terms of Use and can get an account banned. Use at your own risk.
