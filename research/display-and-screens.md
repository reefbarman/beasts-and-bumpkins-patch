# Display setup and screen transitions

Analysis of the original BEASTS.EXE (sha256 `b30d7d07…3e89`) with rea 6.1.0 and Ghidra 12.1.4, cross-checked against objdump. Addresses are VAs. Names are ours.

## Resolution comes from the registry

The game reads `DisplayWidth` and `DisplayHeight` from `HKCU\Software\Worldweaver Productions\Beasts and Bumpkins` (the same key as `CD`, `Working` and so on). The parser around `0x406932`-`0x406A04` compares value names against the strings at `0x484AC0` and `0x484AB0`, and writes the globals `g_width` (`0x484444`) and `g_height` (`0x484448`). The defaults in the EXE are 640 and 480.

bb-patch changes those defaults in the EXE. Setting the two registry values does the same thing without touching the EXE. Its portrait edits are still needed for the portrait position.

## Display object

Global instance at `0x4EEBC8`, methods called with `this` in ECX.

| Offset           | Member                                               |
| ---------------- | ---------------------------------------------------- |
| `+0x08`, `+0x0C` | clip width and height (set from the globals at init) |
| `+0x2C`          | HWND                                                 |
| `+0x30`          | `IDirectDraw*` (global `0x4EEBF8`)                   |
| `+0x34`          | primary surface (flip chain)                         |
| `+0x38`          | back buffer                                          |
| `+0x40`..        | cursor surfaces                                      |
| `+0xB8`          | palette                                              |

| Function                           | What it does                                                                                                                                                                                                                                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x42EC40` `Display_Init`          | `DirectDrawCreate`, `SetCooperativeLevel`, `EnumDisplayModes`, `SetDisplayMode(g_width, g_height, 8)`, `Display_CreatePrimary`, cursor surfaces, clip `[0, 0, g_width, g_height]`                                                                                       |
| `0x42EE50` `Display_CreatePrimary` | primary flip surface with 1 back buffer, gets the back buffer                                                                                                                                                                                                           |
| `0x42F200` `Display_ClearScreen`   | clears both buffers (loops over `g_width`), resets fade values                                                                                                                                                                                                          |
| `0x432DF0` `PlayVideo(name)`       | saves the screen state, sets state 3, releases primary, `SetDisplayMode(g_width, g_height, 16)`, plays, `SetDisplayMode(g_width, g_height, 8)`, `Display_CreatePrimary`, `0x42B260`, restores state, `Display_ClearScreen`, `SetPalette(+0xB8)`, `0x401E80`, `0x401E30` |

`PlayVideo` already contains a complete mode switch with surface rebuild and palette restore.

## Screen state `g_screen` (`0x48426C`)

| Value | Meaning         | Set at                                                                                               |
| ----- | --------------- | ---------------------------------------------------------------------------------------------------- |
| 0     | startup         | initial value; main loop at `0x40B244`                                                               |
| 1     | front-end menus | `0x41FD3E` (menu handler), `0x42DF88` (`0x42DF40` return to main menu)                               |
| 2     | in mission      | `0x41F851` (new game), `0x41F9F3` (page 4, `default.map`), `0x41FD8D`; load game path via `0x415ED0` |
| 3     | video playing   | `0x432F0E`, restored after                                                                           |

Readers: main loop `0x40B244`, the key handler `0x403BF8` (developer keys only in state 2), `0x405CE3`, `0x4193F1`. `0x484274` is a sub-state reset to 0 on each change.

`0x41F810` is the front-end menu handler: page at `this+6`, selected item at `this+10`. Page 1 is the main menu: new game, load, intro (`intro.vid` / `introf.vid`), credits (`credits.vid`), quit.

## Why 1280x720 breaks the front end

Menus, briefing and videos were drawn for a 640x480 surface, but they run with the large globals. Text positions follow `g_width/2`, backgrounds are blitted at 0,0, and video placement and the briefing text area use the large size. In missions, nearly everything follows the globals, which is why gameplay works.

## Proposed patch: per-screen display mode

Keep the globals and display mode at 640x480 everywhere except in missions.

1. **Startup at 640x480.** Leave `DisplayWidth`/`DisplayHeight` unset, so the defaults stay 640x480. Store the mission size in a new PE section as two dwords written by `bbpatch.py`.
2. **`SetScreenMode(w, h)`, new code (about 80 bytes) in the added section:**
   - return if `g_width == w && g_height == h`
   - set `g_width`, `g_height`
   - release the primary (`+0x34`), `IDirectDraw::SetDisplayMode(w, h, 8)`
   - call `Display_CreatePrimary`, set clip `+0x08`/`+0x0C`, restore the palette with `SetPalette(+0xB8)`, and call `0x42B260` as `PlayVideo` does
3. **Call sites:**
   - entering a mission: just before each `g_screen = 2` write (`0x41F851`, `0x41F9F3`, `0x41FD8D`, and the load-game path), so mission setup (`0x414A20`, `0x415ED0`) sees the large size
   - returning to menus: before `g_screen = 1` (`0x41FD3E`, `0x42DF88`), and before the `Display_ClearScreen` that precedes it in `0x42DF40`
   - `PlayVideo`: `SetScreenMode(640, 480)` on entry and back to the previous size on exit, so mission-time videos also play at 640x480
   - backstop: a check in the main loop at `0x40B244` that the mode matches `g_screen`, to catch transitions not yet found
4. **Hook mechanics:** each call site's original 5+ bytes are replaced with a `jmp` to a stub in the new section that runs the displaced instructions, calls `SetScreenMode`, and jumps back. `bbpatch.py` gains "append section" and "hook" edits with the same preimage checks as now. Assemble with `nasm` (pinned) and commit the `.asm` source, not the game bytes.

cnc-ddraw handles each `SetDisplayMode` by rescaling into the same window, so the window doesn't need to change size between menus and missions. In practice: 640x480 screens stretch to fill the window with the aspect ratio kept (pillarboxed in a 16:9 window), and missions fill it at 1:1.

## Implemented: `screenmode` patch

Source `patches/screenmode.asm`, applied by `bbpatch.py --patch screenmode` as a new section `.bbsm` at VA `0x71F000`. `bb.py install --resolution WxH` writes `DisplayWidth`/`DisplayHeight` (always, 640x480 by default) and applies the patch for sizes above 640x480. It differs from the proposal above in three ways:

- **Mission size from the registry.** The `call 0x4064B0` (registry read) in WinMain at `0x406B3A` is wrapped: after the read, the globals are copied to `mission_w/h` and reset to 640x480 before `Display_Init`. The EXE has no size baked in.
- **Videos** only reset the globals and clip at the `g_screen = 3` write. `PlayVideo` then does its own release and `SetDisplayMode`. The two restores (`mov [g_screen], ebp`) resync to the mission size if they go back to state 2.
- **Portrait** constructor `0x42A310` computes `mission_w - 100`, `mission_h - 100` instead of the constants 540, 380.

Hooks: `0x406B3A`, `0x41F851`/`0x41F9F3`/`0x41FD8D` (state 2), `0x41FD3E`/`0x42DF88` (state 1), `0x432F0E`, `0x432F58`/`0x4330DE`, main loop `0x40B244` (backstop sync), `0x42A310`/`0x42A32A`. `0x40B261` (state 0 to 1) isn't hooked because both states are 640x480.

### Startup audit (g_width/g_height, 129 references)

- No buffers or surfaces are allocated once from the globals. All `CreateSurface` calls outside `Display_CreatePrimary` take sprite or video sizes. The only width×height product (`0x431AF0`) is the screenshot writer, computed per call.
- `0x402FA0` is a static initialiser (viewport `0x604638`, `0x513440`) that runs before the registry read, so it always saw 640x480. The per-frame view update `0x40BBA0` recomputes those values, the clip and the view centre from the globals every frame.
- Mission setup (`0x414C90`, the camera bounds `0x6A8F24/28`) runs after the state 2 hooks, so it sees the mission size.

### Test at 1280x720 (macOS, CrossOver, cnc-ddraw)

| Screen                               | Result                                                                                               |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Intro videos                         | Centred, scaled with the 640x480 frame (the video itself is smaller than 640x480, so it has borders) |
| Main menu                            | Correct, fills the window height with side bars                                                      |
| Mission                              | 1280x720 view, plays normally                                                                        |
| Return to menu, load game            | Both work                                                                                            |
| Briefing                             | Still drawn at 640x480 into the top-left of 1280x720, with garbage below row 480                     |
| In-mission pause (Esc) menu          | Same: top-left 640x480, and the cursor leaves trails outside it                                      |
| Thought bubble over unexplored black | Leaves a trail (the black area isn't redrawn)                                                        |

So the briefing and pause menu run in state 2.

### Briefing and pause menu (screenmode v2)

At the end of each mission frame (`0x40B7EE`) the loop picks what to draw: the menu (`0x41E700`) if the menu object's first dword `[0x5CA308]` is non-zero, the briefing (`0x42B3C0` on `0x6A9950`) if view mode `0x48443C == 4`, otherwise the map (`0x40BBA0`). Both screens draw their background once when entered, straight after a `ClearScreen`:

- `0x41FFC0` `Menu_SetActive(flag)`, thiscall: flag 1 sets `[menu] = 1` and builds the page; flag 0 redraws the mission panel `0x486DD8`.
- `0x42B260` `SetViewMode(mode)`, cdecl, the only writer of `0x48443C`: mode 4 draws the briefing background `0x4885EC`; leaving mode 4 redraws the mission panel. `PlayVideo` uses mode 5.

Both entries now `jmp` to stubs that switch first, using the pending argument, then run the displaced bytes and jump back. Every hook uses one rule (`sync_for`): 640x480 in states 0 and 1, and in state 2 while the menu is active or the view mode is 4. The mission size applies otherwise in state 2. The mode is left alone in state 3 and view mode 5.

Test at 1280x720: the briefing and the pause menu are correct (centred, full height, no cursor trails), Continue returns to the full mission view, and save and load work. Still open:

- After loading a game from inside a mission, black bars were left over the map. At first they flickered between frames, then they stayed until the camera scrolled over them. The map view seems to repaint only changed areas, so it needs a full redraw after a mode switch.
- The thought-bubble trail over unexplored black areas is unchanged.

### Redraw and trails: what has been ruled out

Mission frame (`0x40BBA0`, per the rea decompile in `.local/re/dec-0x40bba0.md`):

1. If byte `0x4847BC` is set, invalidate the whole screen (`0x418A10`) and decrement it. `0x403190` sets it to the buffer count `0x484454` (written by `CreatePrimary`). `screenmode` now calls `0x403190` after every size switch, as `SetViewMode` does.
2. World render (the function containing `0x40BA29`): `0x4187F0`, the scroll routine `0x419170` (which also turns the second list, `0x418A70` / count `+0x960C`, into dirty rects), dirty rects for each map object's old and new position (`0x418900`), then the repaint loop `0x419070`: for each rect, clip = viewport ∩ rect (`0x42F410`, `0x42F430`), then draw the map (`0x418F90`).
3. Toolbar `0x419AA0`, then HUD objects `0x429D60` (unit info icons at `w-30`, `h-30`), `0x41E440`, `0x41A430` (scrolling message bar), `0x41B1E0`, `0x41C360`, `0x429480`, then a sprite at `x = 0x27F - width` (right-aligned to 640), `0x4271C0`, `0x42A5F0`, and the bottom-centre text `0x430560(w/2, h-10)` with dirty rect `(w/2-80, h-40, w+80, h)`.
4. `0x4193F0(cam_x, cam_y, 1)` on `0x6B0830`, then flip (`0x42F240`).

Dirty list object `0x5D19E0`: per buffer `b`, count at `+0x9600+4b`, rects `{x1, y1, x2, y2, frames}` (24 bytes, up to 512) at `+0x600 + (512b+i)*24`; current buffer index at `+0x9610`.

Tried and reverted: filling each repaint rect black in the loop at `0x41912D` (lock via `0x42F150`, pitch `+0x5C`). A diagnostic build filling white never showed any white, so that fill never wrote anything. Drawing in this game is blit-based (only the clear, the screenshot writer and `0x432530` call `0x42F150`), so the lock or the rect path assumption was wrong. The repaint request alone didn't clear the post-load bars either, so they are probably drawn after the switch by something placed with 640-based coordinates.

Observed trail locations at 1280x720: under the thought bubble below y≈600 around x 590-660; tooltip text and cursor in the top strip (y < 41) right of x=640, above the map viewport and beyond the 640-wide toolbar. Both are outside anything the 640x480 layout ever drew. Next: find what restores HUD overlays and the top strip, probably a 640-wide background panel blit, and decompile the bubble owner among the HUD objects above.

### Trails and post-load bars fixed (screenmode v3)

Two more hooks, both inert at 640x480:

- `on_mission_frame` replaces `mov al, [0x4847BC]` at `0x40BBA1`. Above 640 wide it keeps the full-repaint counter at 1, so the mission frame invalidates the whole screen (`0x418A10`) every frame, as the game already does while scrolling. This removes the smear left by overlays that only mark their new position.
- `on_before_toolbar` replaces `mov ecx, 0x5D19A0` at `0x40BEF2`. It colour-fills RECT {640, 0, g_width, 0x29} black on the back buffer (`IDirectDrawSurface::Blt`, `DDBLT_COLORFILL | DDBLT_WAIT`) before the 640-wide toolbar is drawn, since the map viewport starts below the toolbar and nothing else repaints that strip.

Test at 1280x720: cursor, tooltip and thought-bubble trails are gone, no black bars after loading a save, no visible slowdown or flicker.

### Full-width toolbar and right-aligned HUD (screenmode v4)

The toolbar is one 640x41 sprite drawn by `Toolbar_Draw` (`0x419AA0`) with `Sprite_Blit(0, 0, 0xFF, 1)` at `0x419ABC`. `Sprite_Blit` (`0x42FD90`) clips against the display rect at `DISPLAY+0..+0xC` (x, y, w, h), so narrowing that rect cuts a sprite without touching the image data. Above 640 wide, `on_toolbar_bg` draws:

- the image at 0,0 (the buttons up to x 400);
- a 64-px stone slice from x 400 repeated across the gap;
- the right part (x 400-640: four slots and the end cap) shifted by `g_width - 640`.

The rest of the change:

- The slot icons start at `mov edi, 0x259` (`0x419C46`) and step left by 0x22, so that hook only adds the extra width.
- Clicks (`Toolbar_Click(x, y)`, `0x419D80`, called from `0x4058DD`) and tooltips (`Toolbar_Tooltip(x, y, buf)`, `0x41A0B0`, called from `0x42ABF2`) are hooked at entry. Both map screen x back to the 640 layout: the right part subtracts the extra width, and the filler maps to x 0x17D, which no button answers to.
- Right-aligned items in the 640 layout:
  - Season icon: drawn at `0x27F - width`, y 0x2E (`0x40BF76`); its dirty rect is at `0x40BF9B`/`0x40BFA2`; its hover zone is x 0x258-0x280, y 0x28-0x50 (`0x42AE5A`/`0x42AE6A`).
  - CHEAT label: x 0x276 (`0x40C4AD`, shown while cheat mode is on).
  All of these are shifted by the extra width. The hover tooltip already clamps to `g_width` (`0x42B09E`). It shows after the mouse has been still for 36 frames (`0x42AB8C`).

Message-log tab (`tab.mfb`, the "grey bar"): drawn at x 0x190-0x1F4 at the bottom once the level counter `0x5E5CC0` is non-zero (`0x41A74F`). The draw is at `0x41A76E`, the dirty rect at `0x41A787`/`0x41A79C`, and the click and hover zones at `0x414D48`/`0x414D4F` and `0x4150F3`/`0x4150FA`. All of these are shifted by half the extra width, so the tab keeps its place relative to the screen centre. Test at 1280x720: the tab sits right of centre and clicking it still opens the log. The panel it opens is the build panel (`0x41A430` on `0x5F90D8`). Its icon loop already runs until `g_width`, but the stone filler after the last icon (sprite `0x4EEBC4`, drawn at `0x41A714`) is one 640-wide image drawn once, so it ended around x 848. `on_panel_fill` repeats it, stepping by its width (`+0x44`), until the screen edge. The panel's dirty rect (`0x41A742`) already spans `g_width`. Test at 1280x720: the panel spans the full width, and the icons and their tooltips work.

### Camera and keyboard scrolling (screenmode v4, WASD)

- The camera position is `0x5FE288` (x, clamped to ±0x1E00) and `0x5FE290` (y, clamped to 0..0x1E00). The mission frame clamps them at `0x40BCAE` and copies them to the render globals `0x6024B8`/`0x602484`, which the scroll repaint `0x419170` compares against the previous frame. The camera moves by velocity doubles `0x4846F0`/`0x4846F8`, with friction `0x482198` (`0x414F5B`).
- Arrow-key scrolling already exists. The key-down table at `0x403F5F` (vk - 0x25, byte index `0x4061C4`, jump table `0x4061A4`) and the key-up table at `0x405493` (vk - 0x10, `0x406478`/`0x40645C`) set and clear the flags `0x484520` (up), `0x484524` (down), `0x484528` (left) and `0x48452C` (right). Edge scroll (`0x414C9F`) treats each flag like the mouse at that edge, but only while the byte `0x4843E8` (cycled 0..2 by F11) is 0. The only other key in the key-down table is F11.
- `on_key_down`/`on_key_up` translate W/A/S/D into the arrow codes for these two lookups only, leaving `ebx` unchanged. Test at 1280x720: the arrow keys and WASD both scroll and stop on release, and the console (Z) and save names still type normally.
- Caveat: this lives in the `screenmode` blob, so it is only installed above 640x480.

### Quicksave (F5) and quickload (F9) (screenmode v4)

- Save: `0x4159C0` is cdecl `SaveGame(path, description)`. It opens the file with `"w+b"` (`0x486ED4`) through fopen `0x46BDD0`, writes with fwrite `0x46CD20`, and returns 1 on success. The pause menu's Save item (`0x41FF18`) calls it with the name buffer `0x5E42D0` and `0x6044E8`, then `0x403190` (full repaint) and `Menu_SetActive(0)` (`0x41FFC0`).
- Load: `0x415ED0` is cdecl `LoadGame(path, from_archive)`. It resets the mission state before it opens the file (`"rb"`, `0x48416C`), so a missing file leaves the mission torn down. The pause menu's Load item (`0x41FD79`) runs `0x401110(0x5CA200, 0x6AFBE8)` on `0x513458`, sets `g_screen` 2 and `0x484274` 0, builds `savegam%d.sav` (`0x486FAC` + `0x486FA4`) into `0x6033D8`, clears the screen, calls `LoadGame(path, 0)`, then `0x403190`, `Menu_SetActive(0)`, clears `0x484278`, calls `0x42E060` (and `0x42E460` if `0x4843DC` is set) and `0x42B480(level 0x5E5CC3)` on `0x6A9950` (music).
- Messages: `0x41DE40` is thiscall `Messages_Add(text)` on `0x662C98`, the on-screen message line (also used for "Network sync has been lost!").
- F5 and F9 fall to the no-op entry of the key-down table. `on_key_down` records the request (only in missions, with no menu open and not typing, `0x4847B4` = 0), ignoring auto-repeat until `on_key_up` sees the release. `on_main_loop` runs it between frames with the same sequence as the menu, minus closing the menu. Quickload checks the file opens first. The quicksave uses its own file, `quicksav.sav`, so menu slots are never overwritten.
- Test at 1280x720: F9 without a quicksave shows a message and does nothing else, F5 saves, F9 restores with a full redraw and music, both are ignored with the pause menu open, and the menu's Load still works.

Test at 1280x720: the toolbar spans the full width and looks seamless, the season icon and the CHEAT label sit at the right edge, and the season tooltip works. Open: a little lag in missions (probably the per-frame full repaint), and skipping the intro video froze for about 30 seconds before the menu.

## Open questions to settle while implementing

- Which state the mission briefing runs in. If it's state 2, it needs its own 640x480 scope around the briefing call.
- Whether the in-mission Esc menu and save dialog are 640-only layouts (they're drawn in state 2).
- Whether anything allocates buffers from the globals once at startup and keeps them. Startup would then see 640x480 and missions would overflow. Check every `g_width`/`g_height` reference reached from `Display_Init` and the mission-setup paths before enabling the patch.
- Remaining HUD items at large sizes: event icon, thought bubble, grey message bar.
