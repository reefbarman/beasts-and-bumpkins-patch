# Beasts & Bumpkins restoration

Scripts to get the 1997 Worldweaver/EA game running well on modern machines, using your own copy of the original disc. Supported targets:

- **macOS** via [CrossOver](https://www.codeweavers.com/crossover) (tested on Apple Silicon, CrossOver 26.3)
- **Windows** 10/11, natively (scripted but not yet tested on real hardware)

See `plans/beasts-and-bumpkins-restoration.md` for the roadmap and `research/` for verified findings.

## This repo contains no game files

You need to supply the game yourself. The scripts only work with the English EU CD release (the `BEASTS.EXE` with md5 `2d2852fcb22e6f65a0cf3415abaf4411`) and refuse anything else. Everything generated (extracted files, patched exe, music, downloaded wrappers, logs) goes into the ignored `.local/` folder.

The copy used for development is the "ISO Version" (English) from [MyAbandonware](https://www.myabandonware.com/game/beasts-bumpkins-bh1), which unzips to `BEASTS&BUMPKINS.bin` and `.cue`. Hashes are in `research/disc-and-executable.md`.

## What gets changed

| Fix                         | How                                                                                                                                |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| No CD needed                | 5-byte patch to a copy of `BEASTS.EXE` (from [bb-patch](https://github.com/bb-patch/bb-patch)), original bytes checked first       |
| No installer needed         | Registry values the game reads are written directly                                                                                |
| Black screen, jumping mouse | [cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw) v7.1.0.0 renders the 640x480 game into a scaled window and manages the cursor |
| Slow gameplay               | Also cnc-ddraw: it replaces DirectDraw outright, which covers the slowdown bb-patch fixes with dxwrapper/DDrawCompat               |
| CD music                    | Audio tracks ripped from the disc image to OGG, played by [ogg-winmm](https://github.com/ayuanx/ogg-winmm) v2025.01.16 (see below) |
| Developer mode (cheats)     | Optional 4-byte patch (`install --console`), from bb-patch. `--console-key F12` or `Z` moves it off F11                            |
| Bigger map view             | Optional (`install --resolution WxH`): missions run at that size, menus, briefings and videos stay 640x480 (our own code patch)    |

Wrappers are downloaded from their GitHub releases and checked against pinned SHA-256 hashes.

## Requirements

- Python 3.9+ (`python3` on macOS, `py` on Windows)
- An OGG Vorbis encoder for the music (optional, the game runs without it):
  - macOS: `brew install vorbis-tools`
  - Windows: `oggenc.exe` from vorbis-tools, or an `ffmpeg` build with libvorbis, on your `PATH`
- macOS only: CrossOver in `/Applications`

## Setup

```sh
# 1. Extract the disc, patch the exe, download wrappers, encode music
python3 scripts/bb.py prepare --cue "/path/to/BEASTS&BUMPKINS.cue"

# 2. Install
python3 scripts/bb.py install
#    macOS: creates/uses the CrossOver bottle "BeastsAndBumpkins" (--bottle NAME to change)
#    Windows: installs to C:\Games\Beasts (--target DIR to change, avoid Program Files)
#    --no-music skips the CD music wrapper
#    --resolution 1280x720 is experimental: missions at 1280x720, the rest at 640x480
#    --console enables developer mode on F11
#    --console --console-key Z (or F12) uses another key; macOS takes F11 for Show Desktop

# 3. Play
python3 scripts/bb.py run               # window sized to the chosen resolution
python3 scripts/bb.py run --fullscreen  # borderless fullscreen, aspect ratio kept
python3 scripts/bb.py stop              # close a running game (install and run do this first)
```

The main menu's OPTIONS page cycles the mission resolution. About a second after you stop on one, the window resizes to it and then stays that size: menus, briefings and videos (640x480) are scaled up into it.

On Windows use `py scripts\bb.py ...`. In game, Alt+Enter switches between window and fullscreen and Ctrl+Tab releases the mouse. Logs go to `.local/logs/`.

Re-running `install` refreshes the game files and keeps saves (`savegam*.sav` in the game folder).

### Developer mode

With `--console`, the developer key (F11 by default) cycles through three modes, shown top-right:

- **Edit** (`CHEAT`): single keys, e.g. `G` lots of gold, `o103` spawn a man or woman, `o110` a cow, `C` duplicate the last object, Ctrl+F6 remove fog of war
- **Script**: type `loadmission`, Enter, then a mission number (1-30)
- third press returns to normal play

With `--console-key Z`, Z can't be typed in Script mode.

## Why the wrappers

The game asks DirectDraw for a 640x480 fullscreen mode. On macOS the display can't switch to that, so with CrossOver's builtin DirectDraw the game draws in a corner and goes black; a Wine virtual desktop fixes the picture but the game's cursor warping makes the view jump. cnc-ddraw draws into a normal scaled window and owns the cursor, which fixes both and also avoids mode-switch problems on modern Windows. Settings live in `config/cnc-ddraw/ddraw.ini`.

The game plays music with MCI `cdaudio` commands. ogg-winmm v2025.01.16 forwards `open cdaudio` to the real winmm with a NULL parameter block, which crashes the game under Wine at startup ([ayuanx/ogg-winmm#25](https://github.com/ayuanx/ogg-winmm/issues/25)). Upstream removed that call in commit `11c13ec` but hasn't released it, so `bb.py` NOPs the same call in the downloaded DLL (8 bytes at file offset `0x1955`, with original and patched hashes pinned).

The game plays music with MCI `cdaudio` commands from the disc's 7 audio tracks, so without a disc there's no music. ogg-winmm intercepts those calls and plays `Music/Track02.ogg` to `Track08.ogg` instead.

## Scripts

| Script               | Purpose                                                                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `scripts/bb.py`      | Main CLI: `prepare`, `install`, `run`, `stop`                                                                                                                                              |
| `scripts/bbpatch.py` | Verified patches: `nocd` (default), `console`, `qol` (WASD scrolling, F5 quicksave, F9 quickload, press any key or click twice to skip a movie; always installed by `bb.py`), `screenmode` |
| `patches/*.asm`      | Our own x86 code patches (nasm source plus the assembled `.bin`)                                                                                                                           |
| `scripts/bincue.py`  | Split BIN/CUE into ISO data track and WAV audio tracks                                                                                                                                     |
| `scripts/iso9660.py` | Extract files from the ISO data track (pure Python)                                                                                                                                        |
| `scripts/peinfo.py`  | Print hashes, PE header, sections and imports                                                                                                                                              |

## Rollback

Your disc files are never modified. To reset, back up your saves, delete the game folder (or the CrossOver bottle) and rerun `install`.

## Credits and licences

The no-CD and console byte patches derive from bb-patch (GPL-3.0). cnc-ddraw (MIT) and ogg-winmm are downloaded at setup time, not redistributed here. Beasts & Bumpkins is © Worldweaver Productions / Electronic Arts.
