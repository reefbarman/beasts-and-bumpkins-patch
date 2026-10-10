# In-game resolution setting

Goal: choose the mission resolution from inside the game instead of `bb.py install --resolution`.

## The game has no options menu

All menus are pages of one menu object (`0x5CA308`, the same object as the pause menu). Item text comes from `strings0.txt` in `MISC.BOX`, loaded into the string table at `0x6034E8` (entry N at `0x6034E8 + 4N`, loader `0x42A870`, file name pattern `strings%d.txt` at `0x486DE0`, the language from `0x484264`).

| Page       | Contents (string entries)                                                                  |
| ---------- | ------------------------------------------------------------------------------------------ |
| 1          | Main menu: NEW GAME, LOAD GAME, INTRO, CREDITS, QUIT (171-175)                             |
| 5          | Pause menu: CONTINUE, LOAD GAME, SAVE GAME, RESTART MISSION, SURRENDER (176, 172, 177-179) |
| 8, 9, 13   | Save/load slot lists: 10 slots plus BACK TO MENU (180)                                     |
| 10, 11, 14 | Quit, surrender and restart confirmations (182-184, 267/268)                               |
| 15         | Save description entry (181)                                                               |
| 16         | Empty page (count 0)                                                                       |

Video, sound and difficulty settings don't exist in the menus. Anything we add is a new item or page.

## Menu object

| Offset             | Meaning                                                           |
| ------------------ | ----------------------------------------------------------------- |
| `+0x00`            | Menu open (dword)                                                 |
| `+0x06`            | Current page                                                      |
| `+0x0A`            | Selected item                                                     |
| `+0x0E`, `+0x12`   | Title position: x = `g_width / 2` (centred), y = 180 (`0x41E6CA`) |
| `+0x16`            | Item count (max 32)                                               |
| `+0x1E`            | Title text                                                        |
| `+0x11E + i*0x11C` | Item i: type (0 = normal text, 1 and 2 = other styles)            |
| `+0x122 + i*0x11C` | Item i text (copied in, up to 0x100 bytes)                        |
| `+0x222 + i*0x11C` | Item i rect x, y, w, h (written by the draw, used for mouse hits) |
| `+0x232 + i*0x11C` | Item i extra gap below (default 0)                                |
| `+0x236 + i*0x11C` | Item i selectable (default 1; skipped by the cursor when 0)       |

Functions (all thiscall on the menu object):

- `0x41E6C0` menu init: centres the title, calls the builder for page 1.
- `0x41ED10(page)` builder: clears all 32 items, then a per-page case (index table `0x41F784`, jump table `0x41F758`) sets the title, count and item text.
- `0x41F7A0(page)` show page: resets the selection when the page changes, calls the builder (call at `0x41F7B7`), moves the selection to the first selectable item.
- `0x41F810()` select handler: switches on page (1..15, `0x41FF54`) and, for page 1, on the item (`cmp eax, 4` at `0x41F82D`, table `0x41FF90`). Page 1 items above 4 fall to the default (do nothing).
- `0x41E700` draw: title, then items top to bottom, each 32 px plus its extra gap below the previous one. The selected item uses font `0x69C758`, others `0x5C78F0`. `0x4309B0` draws and records the rect.

Layout room: the main menu's five items sit at about y 212 to 340, so a sixth item (about y 372) or a short extra page fits easily in 480.

## Display size today

- `on_registry_read` (screenmode) keeps the registry `DisplayWidth`/`DisplayHeight` as `mission_w`/`mission_h` and starts at 640x480. `sync_for` switches to `mission_w` x `mission_h` when a mission starts or the pause menu closes, and to 640x480 otherwise.
- The map view is built at mission start, after the switch, so changing `mission_w`/`mission_h` between missions follows the same path as the first mission after launch.
- The portrait position is set in its constructor (`0x42A310`, hooked by `on_portrait_init`), called from `0x41489F` and `0x429D53`. `0x41489F` looks like part of mission setup; to confirm before relying on it.
- Persistence: the game imports `RegOpenKeyExA`, `RegEnumValueA`, `RegCloseKey` and `RegDeleteKeyA`, but not `RegSetValueExA`. It does import `LoadLibraryA` and `GetProcAddress`, so a patch can call `advapi32!RegSetValueExA` and `RegCreateKeyExA` dynamically.

## cnc-ddraw window

From cnc-ddraw's `config.c` (v7):

- `width`/`height` = 0: the window follows the size the game asks for, resizing (and recentring, `center_window=1`) on every mode switch. Non-zero: a fixed window, and the game's image is scaled into it (`maintas` keeps the aspect ratio).
- `resizable=true` lets the user resize the window; `savesettings=1` writes the window size back to `ddraw.ini` on exit (we set 0 so runs are reproducible).
- `bb.py` writes a fixed window today (2x for 640x480, 1x for larger sizes), so menus at 640x480 are scaled into the mission-sized window, letterboxed by `maintas`.

## Proposed design

### Menu

Add an OPTIONS item to the main menu (sixth item, before QUIT) that opens a new page 17:

```
OPTIONS
  RESOLUTION  1280 X 720
  BACK
```

- Selecting RESOLUTION (click or Enter) cycles through presets and rebuilds the page with the new text. Presets: 640 X 480, 800 X 600, 1024 X 768, 1280 X 720, 1280 X 800, 1366 X 768, 1600 X 900, 1920 X 1080, plus the registry value if it isn't one of them.
- BACK (and Escape, if the generic handler doesn't already cover it) returns to page 1.
- Main menu only. Changing size mid-mission would need the map view and portrait rebuilt, so the pause menu doesn't get it.
- A page rather than a single cycling main-menu item, so later settings (game speed, scroll speed, autosave) have a home.

### Hooks (in `qol`)

| Site                                          | Change                                                                                                                  |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `0x41F7B7` and `0x41E6E4`: `call 0x41ED10`    | Wrapper: call the builder, then for page 1 insert OPTIONS before QUIT (count 6), and for page 17 build the options page |
| `0x41F82A`: `mov eax, [ebx+0xA]; cmp eax, 4`  | Page 1: item 4 is OPTIONS (show page 17), item 5 runs the original QUIT case                                            |
| `0x41F812`: page switch in the select handler | Page 17: RESOLUTION cycles and saves; BACK shows page 1                                                                 |

The builder and handler only know pages up to 16 and 15, so page 17 falls to their default cases and our wrapper owns it completely. Inserting OPTIONS before QUIT keeps QUIT last; the handler hook maps item indexes back for the original cases.

### Applying and saving

- On change, write `DisplayWidth`/`DisplayHeight` to `HKCU\Software\...\Beasts & Bumpkins` (the key `bb.py` already writes) through `LoadLibraryA("advapi32")` + `GetProcAddress`, and set `mission_w`/`mission_h` directly. The next mission start or load uses the new size with no restart. The registry stays the single source of truth, so `bb.py install --resolution` keeps working as the default.
- This needs `mission_w`/`mission_h` in `qol`, or screenmode exporting them. Simplest: move the "mission size" state and `on_registry_read` into `qol`, and have screenmode read it from a fixed address in the `qol` header.
- screenmode must then be installed at every resolution (it already does nothing at 640x480), so a 640x480 install can switch to 1280x720 from the menu. `bb.py install` would always add it, and `--resolution` becomes only the initial default.

### Window

Two options:

1. **Fixed window, scaled (recommended).** Keep a fixed `width`/`height` and enable `savesettings=1`, so whatever size you drag the window to sticks. The game resolution controls how much of the map you see; the window controls how big it is on screen. Menus and missions both scale into the same window with no resizing or jumping. Downside: at non-integer scales nearest-neighbour pixels are uneven (a sharper/softer shader choice could be a later setting).
2. **Window follows the game.** `width=0`/`height=0`: the window snaps to 640x480 for menus and to the mission size in missions, recentring each time. Pixel-perfect, but the window jumps size on every menu/mission switch, which is jarring and fights the macOS window manager.

## Implemented (screenmode v6)

- `on_menu_build` (jump from `0x41ED10`) runs the original builder, then inserts OPTIONS before QUIT on page 1 and builds page 17. `on_menu_select` (jump from `0x41F810`) opens page 17 from item 4, passes item 5 (QUIT) to the original as item 4, and handles page 17. It lives in `screenmode` (which owns `mission_w`/`mission_h`), and `bb.py install` now always applies screenmode.
- The menu font (type 0) has no digits: they draw as blank space. The resolution line uses the save-slot font (type 1, item field `-4`), which does. Page 17 is just Resolution and BACK.
- Saved with `RegSetValueExA` looked up through `GetModuleHandleA("advapi32.dll")` + `GetProcAddress`, on the key the game reads (`0x484134`).
- `on_enter_mission` also sets the portrait position (`0x6A98E0`), since its constructor runs once at startup (`0x41489F`, next to the menu init).
- cnc-ddraw: `savesettings=1`; `bb.py run` keeps the installed `ddraw.ini` window size and only updates `fullscreen=`.
- Tested at 1280x720: the page works, the numbers show, and a new size takes effect in the next mission.

## Window follows the chosen resolution

Originally the window stayed at the install-time size, and choosing a larger resolution made cnc-ddraw grow (and recentre) the window whenever the mission mode exceeded it, then shrink back for 640x480 screens. Now the window is set once to the chosen size and every game mode is scaled into it.

- cnc-ddraw (`dd_SetDisplayMode`) sizes the window to its configured `window_rect`, only enlarging it for a game mode larger than that. With `window_rect` equal to the mission size, the 640x480 to mission switches leave the window alone.
- The only way to change `window_rect` at run time is a user resize. One second after the last change on the OPTIONS page (`resize_at`, checked from the main-loop hook), `resize_window` replays one by sending to the game window (`0x5CD7C4`): `WM_ENTERSIZEMOVE`; `WM_SIZING` with wParam 0 (skips the aspect and minimum-size edits) and an outer rect made with `AdjustWindowRectEx` from the client rect at -32000,-32000 (cnc-ddraw's "centre it" position); `WM_EXITSIZEMOVE`, which re-runs `SetDisplayMode` and moves/sizes the window. `SendMessageA`, `GetWindowLongA` and `AdjustWindowRectEx` come from `GetProcAddress` on user32.
- cnc-ddraw fakes `GetWindowRect`, `GetClientRect` and `GetSystemMetrics` (they report the game mode, 640x480) and ignores `SetWindowPos`/`MoveWindow` on the game window, so none of them can be used.
- After the resize, the cursor stayed clipped to the old area: cnc-ddraw re-locks the mouse inside `SetDisplayMode` before Wine on macOS has moved the window. 300 ms later a `WM_WINDOWPOSCHANGING` with only `SWP_NOMOVE | SWP_NOSIZE` triggers its focus-steal workaround (unlock, lock), which re-clips to the new position.
- `savesettings=1` saves the size on exit, so the next launch opens at the chosen size. `bb.py install --resolution` sets both the registry and `ddraw.ini` to the same size.
- Tested at 1280x720 to 1600x900 and 1024x768: one resize, no size change through briefing, videos and missions, cursor reaches every edge.

## Risks to check while implementing

- The menu font must have the digits and `X` (the save slot names suggest digits render; to confirm on screen).
- Sizes larger than the macOS screen or very wide ratios: the map, camera clamp (`±0x1E00`) and HUD layout have only been tested at 1280x720.
- Confirm the portrait constructor runs per mission, or set the position again in `on_enter_mission`.
- Escape on page 17: check the generic key handling for pages it doesn't know.
