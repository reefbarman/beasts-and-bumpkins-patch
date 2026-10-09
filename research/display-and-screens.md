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

## Open questions to settle while implementing

- Which state the mission briefing runs in. If it's state 2, it needs its own 640x480 scope around the briefing call.
- Whether the in-mission Esc menu and save dialog are 640-only layouts (they're drawn in state 2).
- Whether anything allocates buffers from the globals once at startup and keeps them. Startup would then see 640x480 and missions would overflow. Check every `g_width`/`g_height` reference reached from `Display_Init` and the mission-setup paths before enabling the patch.
- Remaining HUD items at large sizes: event icon, thought bubble, grey message bar.
