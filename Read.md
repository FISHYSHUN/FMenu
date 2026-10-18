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
| **reset** in the popover | Put that row back to its defaults |
| Drag a HUD label | Move it (position is saved) |
| `Insert` or click the header | Hide / show the menu |

Rows whose slider is "Unused" and that have no options do nothing on right-click.

## Tabs

| Tab | Contents |
|---|---|
| **Main** | Speed, jump, infinite jump, bunny hop, fly, noclip, click teleport, gravity, anti-void, auto-clicker, anti-AFK |
| **Visual** | Player ESP, Box ESP, tracers, time of day, brightness, fullbright, no fog, low graphics, FOV, hold-C zoom, max zoom out |
| **Troll** | See below |
| **Defense** | Anti-fling, no player collision, stabilizer, cheat detection, flag markers |
| *Game tab* | Only in recognised games (MM2, Rivals, Natural Disaster Survival) |
| **Config** | Overlay and stat labels, crosshair, menu look, behaviour, saving |

## Per-feature settings

Everything that used to live in the Style tab is now in the right-click menu of the feature it affects.

- **Player ESP / Box ESP:** chams, fill and outline transparency, name / distance / health / held tool, text size, color mode (Default, Custom, Rainbow, Health, Wall check), hue, rainbow speed, hide teammates, update rate. Box ESP adds box fill, thickness and health bar.
- **Tracers:** origin (Bottom / Center / Top), opacity, color mode, hide teammates.
- **Fly:** up/down speed multiplier, smoothing.
- **Click teleport:** hold key (Ctrl / Alt / Shift / None), landing height.
- **Crosshair:** thickness, opacity, custom color.
- **HUD labels (overlay, FPS, ping, clock, coordinates, speedometer):** text size, background opacity, custom color.
- **Auto-clicker:** only click while holding left mouse (on by default).
- **Defense:** which detectors run (speed / teleport / fly), alert cooldown, how long a flag lasts.
- **Rivals:** aim dead zone, edge falloff, FOV ring look, trigger interval, enemy ESP options.
- **MM2:** coin collect interval, role ESP options.
- **NDS:** sky platform size.

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