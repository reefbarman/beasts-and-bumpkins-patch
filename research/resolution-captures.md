# Resolution capture checklist

Screenshots stay local (they contain game art). Save as PNG, same file names in both folders:

- 640x480 reference: `.local/captures/640x480/`
- 1280x720 test: `.local/captures/1280x720/`

Capture the game window only: Cmd+Shift+4, Space, click the window (hold Option to drop the shadow). To save straight into the folder: Cmd+Shift+5 > Options > Save to > Other Location.

## Screens

- [ ] `01-intro-video.png`: any frame of the startup video
- [ ] `02-main-menu.png`
- [ ] `03-load-game.png`: load screen from the main menu
- [ ] `04-mission-select.png`: mission or campaign map, if there is one
- [ ] `05-briefing.png`: mission briefing
- [ ] `06-ingame.png`: a mission just started, nothing selected
- [ ] `07-villager-selected.png`: a villager selected (portrait and its panel)
- [ ] `08-building-selected.png`: a building selected
- [ ] `09-build-menu.png`: the build or construction menu open
- [ ] `10-other-panels-*.png`: any other panel or button bar, one each (e.g. `10-other-panels-spells.png`)
- [ ] `11-map-top-left.png`: scrolled to the top-left map corner
- [ ] `12-map-bottom-right.png`: scrolled to the bottom-right map corner
- [ ] `13-ingame-menu.png`: the in-game menu (Esc)
- [ ] `14-save-dialog.png`: save dialog from the in-game menu
- [ ] `15-dev-edit.png`: developer Edit mode (`CHEAT` showing)
- [ ] `16-dev-script.png`: developer Script mode
- [ ] `17-mission-end.png`: win or lose screen (optional, if easy to reach)

## Findings at 1280x720 (bb-patch edits only, 2026-10-09)

Install: `bb.py install --console --console-key Z --resolution 1280x720` (cnc-ddraw window 1280x720, 1x). Reference captures at 640x480 were skipped.

| Screen              | Observed                                                                                       | Hypothesis                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Main menu           | 640x480 background at top-left; menu items centred on the 1280 width (around x 645, y 240-370) | Background blitted at 0,0; item positions use `width/2`                             |
| Mission video       | Drawn at x 640-1280, y 168-552; correct vertically, shifted a full 640 right                   | Video x offset uses `width` in a 640-only formula                                   |
| Briefing            | 640x480 picture top-left; rows 480-705 filled with streaks; last text line repeated near y 700 | Text area anchored to `height`, but the backdrop or back buffer only holds 480 rows |
| In-game map         | Works and shows much more of the map; scrolling and selection OK                               | Driven by the globals                                                               |
| Top bar and minimap | Drawn at 640 width in the top-left, which works                                                | Fine as is; widening is optional polish                                             |
| Portrait            | Bottom-right, correct                                                                          | bb-patch's `width-100` / `height-100` edits                                         |
| Event icon (flower) | Around x 617, y 63: still at its 640 position under the top bar                                | Hard-coded x                                                                        |
| Thought bubble      | Bottom centre, around x 600-660, y 600-660                                                     | Position unclear, compare with 640x480                                              |
| Grey bar            | Cut off at bottom centre, around x 400-500, y 714+                                             | Possibly the letter/message tab, positioned from 480 or partially off-screen        |
| Message text        | "A letter has arrived!" centred at the bottom, correct                                         | Uses globals                                                                        |

Gameplay works "with some small glitches" (Tristan). No crash seen.

Takeaway: full-screen 640x480 screens (menu, briefing, video) are the worst. Fix those by running them in a 640x480 mode and switching to the large mode for missions. Then fix the handful of HUD elements individually.

## At 1280x720, also note

- [ ] Anything drawn in the wrong place, cut off, or missing
- [ ] Clicks that miss what's drawn (buttons, portrait, minimap)
- [ ] Whether scrolling stops at the map edges correctly
- [ ] Crashes, with roughly what you were doing
