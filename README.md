# FMenu

Roblox executor menu. Universal features in every game, plus an extra tab when the place is recognised.

## Run

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/FISHYSHUN/FMenu/main/loader.lua"))()
```

Re-running tears down the old menu first. Insert hides / shows it. Click a row to toggle it, right-click
(or long-press on touch) for its slider.

- Each tab shows how many of its features are on. The menu is exactly as tall as the open tab needs, grows
  or shrinks smoothly when you switch tabs, and scrolls its rows if a tab is taller than the screen.
  Switching tabs slides left or right depending on which way you move.
- The FPS / ping / clock / overlay labels (and the NDS disaster HUD) can be dragged anywhere.
- The menu and HUD are parented with `gethui()` / CoreGui when the executor has it, so they draw above
  Roblox's own top bar, chat and player list. Without it they fall back to PlayerGui, where core gui can
  cover them.
- The loader queues itself with `queue_on_teleport`, so games that teleport you (Rivals: lobby -> match)
  get the menu and the right game tab again in the new place. `getgenv().FMENU_NO_REQUEUE = true` before
  running the loader turns that off.

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
| Visual | player ESP, tracers |
| Utility | time of day, brightness, fullbright, no fog, fov, low graphics, anti-AFK |
| Config | reduced motion, auto-hide |

## Game tabs

- **MM2**: role ESP, role alerts, gun drop ESP, auto grab gun, coin collect
- **Rivals**: aim assist (hold right mouse), FOV ring, triggerbot, enemy ESP, visible-only, team check
- **Natural Disaster Survival**: disaster HUD, sky platform, fall speed limit

## Adding a game

1. In the executor: `print(game.PlaceId, game.GameId)`.
2. Add an entry to `Games.index` in `src/Games.lua`. Use `places` for exact place ids and `universes` (the
   `GameId`) for games whose lobby and matches are different places.
3. Create `src/games/<Name>.lua` returning `{ name, tab = { name, rows }, features = { id = { init?, set, step?, destroy? } } }`.

A feature's `set(enabled, value, ctx)` runs on toggle and on slider change (value 0-100). `set(false, ...)`
must undo whatever the feature did, it is also called for every active feature when the menu is destroyed.

## Notes

- Place ids, the Rivals universe id and object names for the three games are from memory and have not been
  checked in the live games. The loader prints `place / universe -> game` to the console on every run; if
  the tab doesn't show up, add the real ids as above.
- `firetouchinterest`, `mouse1click`, `getgenv`, `loadstring` and `game:HttpGet` are executor features.