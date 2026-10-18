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
src/Defense.lua         anti-fling + cheat detection
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
| Main | overlay, fps, ping, clock, coordinates, speedometer, crosshair |
| Player | speed, high jump, infinite jump, bunny hop, noclip, fly, ctrl+click teleport, gravity, anti-void |
| Visual | player ESP, box ESP, tracers, hide teammates, wall check |
| Style | chams fill, outline, names / distance / health / held tool, health bar, box fill + thickness, health colors, rainbow, custom color, tracer origin, ESP refresh rate |
| Utility | time of day, brightness, fullbright, no fog, fov, hold-C zoom, max zoom out, auto-clicker, low graphics, anti-AFK |
| Defense | anti-fling, no player collision, stabilizer, speed / fly / teleport detect, spin / fling detect, aim snap detect, flag markers |
| Config | translucent menu, compact, reduced motion, auto-hide, lock HUD, notifications |

Tabs are split into titled sections. In `Games.lua` / game modules a `{ header = "Title" }` entry in `rows` starts
a new section.

### Defense

All client side: it changes what your own game does about other players, it cannot kick or ban anyone.

- **Anti-fling** turns off collisions with players that move or spin faster than the limit (they pass through
  you on your screen, so the push never lands). **No player collision** does it for everyone.
  **Stabilizer** cancels your own spin and caps your speed while a dangerous player is within 30 studs.
  Turn the stabilizer cap up if it fights your own fly / speed features.
- **Detection** flags speed hacks, teleports (two big jumps in 20 s), fly (hovering in the air for seconds), spin /
  fling and aim snap (turning from clearly away to exactly on you in one frame, several times in 30 s). Flags pop
  a toast and expire after 30 s; **Flag markers** puts an orange tag on flagged players. These are heuristics:
  vehicles, dashes and round-start teleports can look like cheating, so a flag means "take a look".

## Game tabs

- **MM2**: role ESP, role alerts, gun drop ESP, auto grab gun, coin collect, murderer distance readout, watch murderer
- **Rivals**: aim assist (gentle, speed limited pull) and aim lock (sticks to a target, snap or smoothed), both on
  right mouse and lock wins if both are on; FOV ring, aim part (head / chest / closest), prediction, triggerbot,
  enemy ESP, target info, visible-only, team check
- **Natural Disaster Survival**: disaster HUD, disaster alert, sky platform, air floor, fall speed limit

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
