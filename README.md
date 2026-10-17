# FMenu

Roblox executor menu. Universal features in every game, plus an extra tab when the place is recognised.

## Run

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/FISHYSHUN/FMenu/main/loader.lua"))()
```

Re-running tears down the old menu first. Insert hides / shows it. Click a row to toggle it, right-click
(or long-press on touch) for its slider.

## Layout

```
loader.lua              entry point, fetches src/* from raw.githubusercontent.com
src/Animations.lua      every tween
src/UI.lua              gui, input, slider popover, status dot
src/Functionality.lua   feature registry + universal features
src/Util.lua            helpers
src/ESP.lua             highlight + name tag engine
src/Games.lua           tabs + place id index
src/games/MM2.lua
src/games/Rivals.lua
src/games/NaturalDisasters.lua
```

## Universal features

| Tab | Rows |
| --- | --- |
| Main | overlay, crosshair, fps, ping, clock, compact |
| Player | speed, high jump, infinite jump, noclip, fly, ctrl+click teleport |
| Visual | player ESP, tracers, fov, brightness, fullbright, no fog |
| Utility | time of day, low graphics, anti-AFK |
| Config | reduced motion, auto-hide |

## Game tabs

- **MM2**: role ESP, role alerts, gun drop ESP, auto grab gun, coin collect
- **Rivals**: aim assist (hold right mouse), FOV ring, triggerbot, enemy ESP, visible-only, team check
- **Natural Disaster Survival**: disaster HUD, sky platform, fall speed limit

## Adding a game

1. In the executor: `print(game.PlaceId, game.GameId)`.
2. Add an entry to `Games.index` in `src/Games.lua`.
3. Create `src/games/<Name>.lua` returning `{ name, tab = { name, rows }, features = { id = { init?, set, step?, destroy? } } }`.

A feature's `set(enabled, value, ctx)` runs on toggle and on slider change (value 0-100). `set(false, ...)`
must undo whatever the feature did, it is also called for every active feature when the menu is destroyed.

## Notes

- Place ids and object names for the three games are from memory and have not been checked in the live
  games. If the tab doesn't show up, add the real ids as above.
- `firetouchinterest`, `mouse1click`, `getgenv`, `loadstring` and `game:HttpGet` are executor features.
