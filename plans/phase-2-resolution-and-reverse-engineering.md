# Phase 2: higher resolution, then reverse engineering toward a rebuild

Status: approved 2026-10-09, see Decisions.

## Where we are

Phase 1 is done. The original EXE runs on macOS through CrossOver with a verified no-CD patch, cnc-ddraw for display and input, ogg-winmm for CD music, and optional developer mode. Saves, music, speed and cheats are confirmed in play. Everything is reproducible from `scripts/bb.py` and committed without game files.

The game still renders at 640x480. cnc-ddraw scales that up cleanly, but you see the same amount of map as in 1997. bb-patch offers higher resolutions by changing the screen-size globals and the portrait position. Its own README says icons end up in the wrong place and menus and videos aren't rescaled.

## Recommendation

Do two tracks in order, sharing one toolchain:

1. **Higher resolution as a patch on the original EXE.** It's the most visible improvement and needs the same analysis skills as the decompile, on a bounded slice of the game.
2. **Map the whole binary with rea and Ghidra, then reconstruct one subsystem.** Use what the resolution work teaches us about rendering and UI as the starting point.

Decide matching versus functional decompilation (see below) after the first reconstructed functions, not before.

## Evidence so far

| Finding                                                                                                                                                                                            | Consequence                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Width and height live in globals at VA `0x484444` / `0x484448`, with 58 and 71 references. Literal `640`/`480`/`639` appear only 8 times, and bb-patch's portrait constants (`540`/`380`) 7 times. | Most drawing already follows the globals. The glitches should come from a modest number of hard-coded or derived coordinates, not from the whole engine. Still to confirm in Ghidra.  |
| bb-patch changes 4 dwords: width, height and two portrait offsets.                                                                                                                                 | A starting point, not a solution. Values derived from 640 or 480 (centres, right/bottom anchors, scroll limits) are still unaccounted for.                                            |
| The linker version is 4.20, with no Rich header and the CRT statically linked (Visual C++ debug-library strings present).                                                                          | Built with MSVC 4.2. That's the same compiler as the LEGO Island decompilation (isledecomp), whose `reccmp` tooling compares recompiled functions against the original byte for byte. |
| cnc-ddraw presents whatever mode the game asks for, scaled to the window.                                                                                                                          | Menus and videos could stay 640x480 while gameplay uses a larger mode, if the game can switch modes between screens. Needs checking against how and when it calls `SetDisplayMode`.   |
| rea supports Ghidra 12.1.x with JDK 21 on macOS arm64, and x86 PE targets. It works as an MCP server or a CLI. AgentLink isn't one of its setup clients.                                           | Install JDK 21 and Ghidra ourselves. Start with the rea CLI and add an MCP registration to AgentLink by hand only if the CLI round trips become the bottleneck.                       |
| `java` is not installed. Ghidra and rea are not installed.                                                                                                                                         | Tool installation is the first step and needs approval.                                                                                                                               |

## Track A: higher resolution

Goal: a selectable resolution (for example 1280x720 or 1024x768) that shows more of the map, with the HUD, panels, portrait, minimap, mouse and scrolling all correct, and menus and videos shown correctly rather than stuck in a corner.

### A1. Reference captures

Before changing anything, capture every screen type at 640x480: main menu, mission briefing, in-game HUD, each panel, save/load, mission end, a video and the developer modes. These are the reference for what "correct" looks like. Automated screen capture timed out in Phase 1, so this needs your screenshots, or a working capture route (computer-use MCP or `screencapture` with permissions).

### A2. Reproduce bb-patch's resolution and catalogue the defects

Install with `bbpatch.py --patch resolution --resolution 1280x720`, keeping cnc-ddraw in charge of the window. Record each defect against the reference capture: what's wrong, on which screen, and at which resolution. Test at least two resolutions so the position errors show whether they're fixed offsets or proportional.

### A3. Trace the cause of each defect

In Ghidra, for each defect:

- follow the drawing or hit-test code back to the coordinate it uses
- classify it as a literal, a value derived from 640/480 (such as `540 = 640 - 100`), a table of positions, or a value baked into an asset
- check the clipping rectangles, mouse bounds and scroll limits that share the same assumption

Also find how the game sets the display mode and whether menus, videos and gameplay go through one call or several.

### A4. Fix, smallest mechanism first

1. **Data and immediate operands:** extend `bbpatch.py` with verified edits, the same as today.
2. **Expressions:** where a literal must become `width - n` or `width / 2`, and the instruction has no room, branch to new code in an added PE section. `bbpatch.py` gains one capability: append a section and write assembled bytes, with preimage checks on every hook site. Assemble with a pinned assembler (`nasm` or Keystone) so the bytes are reproducible.
3. **Menus and videos:** prefer switching to 640x480 for those screens if the mode-switch investigation supports it. cnc-ddraw then scales each screen to the window. The fallback is centring them in the larger surface.

Keep resolution an install option (`--resolution WxH`) with 640x480 as the default. Allow only the sizes we've tested.

### A5. Things to watch

- Gameplay effects: a wider view may change scrolling bounds, fog of war, AI that reacts to what's on screen, or performance. If it changes balance noticeably, document it rather than hiding it.
- Small maps may be narrower than the view at large resolutions.
- Saves made at one resolution must load at another.

### Track A acceptance

- [ ] Two resolutions tested, plus 640x480, with every reference screen checked
- [ ] HUD, panels, portrait and minimap anchored correctly; clicks hit what's drawn
- [ ] Scrolling reaches every map edge and no further
- [ ] Menus, briefings and videos display correctly
- [ ] A save crosses resolutions both ways
- [ ] An early and a late mission played for a while without new visual defects

## Track B: reverse engineering toward decompile/recompile

### B1. Toolchain

- JDK 21 (Temurin) and Ghidra 12.1.4, installed outside the repo (for example `~/tools/`), with versions and hashes recorded in `research/`.
- rea via `npx -y rea-agents@<pinned> ...` with `--provider ghidra`. Check readiness with `rea doctor --provider ghidra --json`.
- The Ghidra project lives in `.local/ghidra/` (ignored), as does raw decompiler output.

### B2. Map the binary

Goal: a named, navigable picture of the EXE, built so that each later step costs less.

1. Separate the statically linked MSVC 4.2 runtime from game code (Ghidra function ID or signatures), so we only reconstruct game functions.
2. Label subsystems from imports, strings and call graphs: DirectDraw rendering, DirectSound/QMixer audio, MCI music, input and the key switches, `.box`/`.fat`/`.mfb`/`.vid` file I/O, missions and scripts, units and AI, save/load.
3. Keep a committed symbol map (`research/symbols.csv`: address, name, size, confidence, evidence) alongside the notes. Addresses and names are our own analysis. Raw decompiled code stays local, as decided in Phase 1.

### B3. Asset formats

Write small Python readers for the container and image formats, so they can be verified against the running game. These are needed by any eventual port, and they're useful now for enhancements such as higher-resolution UI art.

### B4. First reconstruction

Pick a leaf-heavy routine with clear inputs and outputs, such as a coordinate or maths helper, or part of the resolution code from Track A. Reconstruct it in C and prove it against the original x86. Use emulated test cases (Unicorn or similar) as in rea's DX-Ball showcase, and byte comparison if we choose the matching route.

### B5. Decide the decompilation route

| Route          | What it means                                                                                                                                                         | For                                                                                                              | Against                                                                                                                       |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **Matching**   | Rebuild with MSVC 4.2 under Wine, and compare each function to the original bytes with `reccmp` (as isledecomp did).                                                  | Provable fidelity for every function, an established method for this exact compiler, and progress is measurable. | Needs a copy of the 1996 compiler (proprietary, not ours to redistribute). Matching compiler output is slow, careful work.    |
| **Functional** | Rebuild with a modern compiler (clang targeting i686 Windows). Prove behaviour with tests and emulation, and swap functions into the running game through a hook DLL. | Faster, and modern tooling. The hook DLL is also the vehicle for enhancements.                                   | Equivalence is only as good as the tests. Subtle behaviour such as float, integer and struct layout drift is harder to catch. |

Recommendation: run B4 both ways on the same small function, then choose with evidence. If MSVC 4.2 can't be sourced cleanly, functional is the route by default.

### B6. Then

Expand by subsystem until no original code sections execute, then port the platform layer (SDL or similar) to native macOS arm64, as already laid out in the Phase 1 plan's Phase 3. Progress is measured by verified functions, not lines of pseudocode.

## Out of scope for this phase

Widescreen UI art, gameplay or balance changes, mission 24 crash investigation (unless the B2 mapping makes it cheap), and Windows hardware testing.

## Decisions (2026-10-09)

1. Toolchain approved: JDK 21, Ghidra 12.1.4 in `~/tools`, and a pinned rea through npx (no agent registration).
2. The resolution goal is real higher resolution (more of the map visible), not only sharper scaling.
3. Decompile route: try both matching and functional on the first function, then decide.
