# Beasts & Bumpkins: restore first, reconstruct later

Status: proposed, awaiting approval before implementation.

## Overview

The goal is a reliably playable original game for personal use, followed by enhancements and eventually recovered source that can build natively for Mac. Start with the Windows executable running through CrossOver on this Apple Silicon Mac. Patching is the first milestone, not the permanent limit of the project.

The existing fan patch supplies useful fixes, but it is not a rebuilt game engine. We should reuse its research without depending on its Windows GUI or applying unchecked binary edits. REA and Ghidra will support targeted investigation when a failure needs more than configuration changes.

## Key decisions

- Preserve an untouched full disc release and identify its executable before patching.
- Establish a 640×480 reference configuration before changing resolution or gameplay.
- Apply the smallest required fixes to a disposable copy, with explicit version checks and rollback.
- Test through the installed CrossOver first. Do not label that as validation on Windows itself.
- Use selective decompilation for fixes now; make a full source reconstruction a separate, evidence-gated phase.
- Keep original game files, saves, raw decompiler exports and analysis databases local. No publishing is proposed.

## Current evidence and limits

| Evidence                                                                                                                                                                | Consequence                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Workspace contains no game or source project and is not a Git repository.                                                                                               | There is no existing build or delivery convention to inherit.                                                                                   |
| Local host is macOS 26.7.1, Apple Silicon, with CrossOver 26.3 installed. Python 3.14.7 and Node 26.10.0 run.                                                           | We can begin locally. CrossOver licence/readiness and a suitable bottle still need checking.                                                    |
| The work targets an untouched English full disc image, not an altered RIP/repack.                                                                                       | Actual contents are not yet inspected.                                                                                                          |
| bb-patch documents one tested BEASTS.EXE, MD5 `2d2852fcb22e6f65a0cf3415abaf4411`. [1]                                                                                   | Treat that as a version clue, not a trust signature. Establish our own SHA-256 identity and verify patch preimages against the supplied binary. |
| Source uses fixed-offset edits, registry setup and bundled DirectDraw wrapper files. It lacks input-hash checks and reliable transactional recovery. [2]                | Do not run it against the only copy or assume its Remove action restores the prior state.                                                       |
| An upstream issue reports the patcher failing in CrossOver. CodeWeavers records limited game functionality on older CrossOver 24.0.1. [3][4]                            | The patcher's GUI is not a prerequisite; current CrossOver compatibility must be tested rather than assumed.                                    |
| High-resolution edits adjust only some dimensions/positions. No save repair or simulation-clock repair appears in the patch list. Mission 24 has a crash report. [2][5] | Higher resolution, timing, saves and late-game stability are separate checks, not solved features.                                              |

No game has been downloaded, installed, patched or run during planning. Reports are leads, not reproduced defects.

## Phase 1: acquire, identify and establish a playable baseline

### 1. Preserve and inspect

1. Add ignore rules before bringing proprietary files into the workspace. Initial work stays local; any future remote or publication needs a separate decision.
2. Take the user-supplied English full disc image and record its file sizes and SHA-256. Do not execute supplied installers automatically.
3. Keep the image outside the repository, extracting only into `.local/`. Preserve any BIN/CUE pair and audio tracks as supplied; converting only the data track could lose music.
4. Inventory executable and asset files. Record PE architecture, imports, executable hashes, edition/language and whether packing or unusual installer requirements are present. MD5 comparison alone is not sufficient to approve an edit.
5. Create a working installation in a dedicated CrossOver bottle. Use the supplied installer if practical; use a verified file-copy/registry setup only if needed. Record the actual bottle-visible Windows paths, not macOS paths.

### 2. Run the smallest compatibility experiment

- Capture the original launch result first. Record exact versions, bottle settings, executable identity, display settings and failures.
- Keep the logical game resolution at 640×480. Prefer aspect-correct scaling/windowed presentation where supported rather than widescreen binary edits.
- Apply only required installation/media-path fixes. Keep console cheats and resolution modifications disabled by default.
- Test CrossOver's default graphics handling first. If it fails, compare one explicitly versioned DirectDraw compatibility option at a time, with a fresh working copy/configuration. Do not stack competing `ddraw.dll` wrappers or assume a Windows-specific wrapper works in Wine.
- Track sound effects, speech and CD music separately. Removing a disc prompt does not prove music playback is preserved.
- Prefer configuration fixes over code changes. If a defect persists, save the reproduction and investigate that specific code path with REA/Ghidra.

### 3. Minimal patch tooling, only where needed

Use a small Python 3 command-line tool on the Mac to prepare game copies rather than rebuilding the Fyne installer. Keep file manipulation separate from bottle registry changes. A generated `.reg` file or explicit bottle-scoped import must use confirmed Windows paths; do not delete an existing registry subtree.

Each supported patch profile records the input SHA-256, file size, offsets, expected original bytes, replacement bytes and evidence/source reference. The tool must:

- inspect/dry-run without writes and reject unknown, truncated or unexpectedly modified inputs;
- validate every edit before producing a new output file, never modify `.local/originals/`;
- recognise a known output as already patched rather than patch it twice;
- verify written output and report failures instead of claiming success;
- leave the active installation untouched until a complete candidate is ready.

Do not build a general launcher or plugin framework. If existing configuration is sufficient, avoid writing a patch engine at all. Any reused or translated bb-patch implementation retains applicable GPL obligations and attribution.

### Phase 1 acceptance checklist

- [ ] Full release retained, hashed and inventoried; originals remain unchanged.
- [ ] Exact launch/configuration steps are repeatable in the dedicated bottle.
- [ ] Menu and an early mission work, including selecting units, issuing orders, scrolling and opening UI panels.
- [ ] A save survives exit, relaunch and load, with expected units, resources and mission progress.
- [ ] Audio components and visible defects are recorded individually.
- [ ] Normal gameplay is observed across a meaningful in-game transition; an observed speed is not called historically accurate without a reference.
- [ ] Candidate changes can be removed by restoring the previous working copy/configuration without losing saves.

If launching remains blocked, deliver the acquisition/inventory and a reproducible failure report. That is useful progress but is not a completed playable baseline.

## Phase 2: stabilise and enhance

Prioritise reproduced defects: launch/rendering failures, save/load, crashes, input and timing, then presentation improvements. Validate reported mission 24 failure when a legitimate reproduction/save is available. Preserve that save before testing.

Use REA with Ghidra for strings, imports, disassembly, pseudocode and cross-references around the relevant fault. Prefer the pinned CLI initially to avoid unnecessary agent-configuration changes. Verify the chosen release's actual capabilities, Ghidra/JDK requirements and successful analysis of this executable. Direct Ghidra remains a fallback if REA integration is the blocker. Tool installation and configuration changes follow normal approval.

For each recovered function, retain its original executable hash, relative virtual address/file-offset mapping, calling convention, inferred types, supporting instructions and remaining uncertainty. Decompiler output is a hypothesis until checked against instructions and observed behaviour. Analysis is local, but tool excerpts passed to the model follow the model provider's data policy.

Only enable wider resolutions after investigating UI coordinates, clipping, mouse mapping, menus and videos together. Keep experimental gameplay changes separate from a stable compatibility profile. Do not silently alter save formats.

## Phase 3: decompile and rebuild

The longer-term goal is maintainable recovered source, not an unrelated remake. Decompilation does not recover the exact original source, names or build system, and compiling its raw output is not a complete port.

1. Select a bounded routine or subsystem from the real binary with clear inputs, outputs and manageable dependencies. Selection follows inspection, not a guessed function list.
2. Reconstruct it in C/C++ and compare it against the original x86 behaviour using a small test harness, captured cases or instruction emulation as appropriate. Behavioural equivalence is the target; byte-identical recompilation is optional evidence, not a project requirement.
3. Prove an integrated replacement in a Windows build or carefully scoped hybrid executable. Preserve x86 calling conventions, structure layouts, integer behaviour and ownership across any original/rebuilt boundary. A hybrid still depends on the original machine code and is not a full source rebuild.
4. Expand by subsystem, keeping recovered behaviour separate from intentional fixes. Use evidence-backed coverage, not the number of emitted pseudocode files, to measure progress.
5. Reach a Windows executable built from recovered source without executing original code sections. It may still load the original user-supplied assets.
6. Port platform boundaries to native macOS arm64. Windowing, graphics, audio, input, files and timing may use SDL or another appropriate backend after dependencies are mapped. Audit 32-bit assumptions and explicit save/asset serialisation. Recompiling x86 code alone does not make it a native Mac application.

Build portable recovered components on Mac early where practical, but do not commit to full-game reconstruction feasibility or a specific engine architecture before the first verified reconstruction succeeds. Availability of actual original source would change this plan substantially.

## Storage, validation and rollback

Proposed layout, created only as needed:

```text
plans/                     design and decisions
README.md                  exact restoration/launch steps
scripts/                   small inspection and patch utilities
tests/                     synthetic patch-safety fixtures
research/                  concise provenance and verified findings
.local/                    ignored downloads, originals, working copies,
                           saves, captures and analysis databases
```

Test any new patch utility with synthetic fixtures for unknown hashes, wrong preimages, truncated files, repeated application and write failures. Real-game validation remains local. Back up saves before each experiment and record the executable/profile used to create them. Keep originals, stable installation and experiments separate. Roll back by selecting the prior installation/bottle snapshot, not by blindly writing default bytes or deleting DLLs.

A CrossOver bottle is not a security sandbox. Run legacy files without elevated privileges, avoid exposing unnecessary host folders, and do not disable host protections to make a download run. Preserve unrelated bottles and settings.

Native Windows validation is deferred until a Windows test environment is available. No Windows compatibility claim, full-campaign claim or historical-timing claim follows from a short CrossOver smoke test.

## Trade-offs and boundaries

- **Patch first, recommended:** gets the original game into use and supplies a behavioural reference. It retains the original engine's limitations until individual systems are reconstructed.
- **Full reconstruction first:** aligns with a native port but delays playability and commits to unknown binary complexity. Revisit after a verified small reconstruction.
- **Historical-PC emulation:** useful as a fallback reference when modern compatibility is ambiguous, not a substitute for the enhancement goal. It requires separately sourced/licensed OS and firmware where applicable.
- Personal use does not establish redistribution rights. Keep the game and derived materials private; evaluate rights before publishing recovered code or game content. The patch project's GPL licence does not license the original game.

## Approval scope

Approve Phase 1: inspect a user-supplied disc image, prepare a dedicated CrossOver setup, and attempt a reversible 640×480 playable baseline with only necessary tooling/fixes. Report actual results before expanding into major enhancements or whole-game reconstruction. This does not approve public distribution, purchases, changes to unrelated applications or a broad rewrite.

## Sources

1. [bb-patch README and tested executable](https://github.com/bb-patch/bb-patch#usage).
2. [Patch application](https://github.com/bb-patch/bb-patch/blob/main/patch/patch.go), [patch list](https://github.com/bb-patch/bb-patch/blob/main/patch/patches.go), [resolution edits](https://github.com/bb-patch/bb-patch/blob/main/patch/set-resolution-patch.go), [registry setup](https://github.com/bb-patch/bb-patch/blob/main/patch/no-installation-patch.go).
3. [CrossOver patcher report, issue 2](https://github.com/bb-patch/bb-patch/issues/2).
4. [CodeWeavers compatibility report](https://www.codeweavers.com/compatibility/crossover/beasts-and-bumpkins).
5. [Mission 24 crash report, issue 5](https://github.com/bb-patch/bb-patch/issues/5).
6. [REA capabilities](https://github.com/morluto/rea) and [installation/release boundaries](https://github.com/morluto/rea/blob/main/docs/installation.md).

Upstream links are mutable. Pin revisions and downloaded tool versions before relying on them during implementation.
