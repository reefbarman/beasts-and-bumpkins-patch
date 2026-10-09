# Disc release and executable identity

## Source

- Page: https://www.myabandonware.com/game/beasts-bumpkins-bh1, "ISO Version", English
- Resolved file: `https://d2.xp.myabandonware.com/t/<token>/Beasts-Bumpkins_Win_EN_ISO-Version.zip` (token is per-session)
- Retrieved: 2026-10-09T11:34:25Z
- Archive: `Beasts-Bumpkins_Win_EN_ISO-Version.zip`, 343,691,233 bytes, sha256 `cfc21e9a22fe0430a1273b0de4fbfcf3a1345c7e9393fd59ba3133470c0a0735`

## Contents

| File                                                 |       Bytes | sha256                                                             |
| ---------------------------------------------------- | ----------: | ------------------------------------------------------------------ |
| `Beasts_and_Bumpkins-THEiSOZONE/BEASTS&BUMPKINS.bin` | 396,991,728 | `fcca747e79712ca1503c51a136706320beb8aeb983f4da9b3c982cbcd77e8243` |
| `Beasts_and_Bumpkins-THEiSOZONE/BEASTS&BUMPKINS.cue` |         368 | `c4382223b58e09e183dfa74e3c5aed96e2c6cdc834ece05c3bf563669c43eee9` |

The CUE describes one `MODE2/2352` data track (volume label `EAEUROPE`, 117,958 sectors) and seven CD audio tracks (tracks 2 to 8). The game plays music from those tracks via MCI `cdaudio` (`open cdaudio`, `play cdaudio from %d`), so no-CD installs lose music unless CD audio is emulated or redirected.

`scripts/bincue.py` splits the image into `track01.iso` plus `track02.wav` to `track08.wav`.

## BEASTS.EXE

| Property | Value                                                                                                                                                                 |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Size     | 916,992 bytes                                                                                                                                                         |
| md5      | `2d2852fcb22e6f65a0cf3415abaf4411` (matches the bb-patch tested build)                                                                                                |
| sha256   | `b30d7d0762dbd808407f0d95c6fdafa0b52ce67d0b0f20c8fbb7fa66a2213e89`                                                                                                    |
| Format   | PE32, i386, GUI, image base `0x400000`, entry RVA `0x6d3d0`                                                                                                           |
| Linked   | 1997-07-10 13:37:48Z                                                                                                                                                  |
| Sections | `.text .rdata .data .idata UVA_DATA .rsrc .reloc`, not packed                                                                                                         |
| Imports  | DDRAW (`DirectDrawCreate`), DSOUND, QMIXER95 (QSound mixer, shipped on disc), WINMM (MCI, multimedia timers, MIDI), GDI32, USER32, ADVAPI32 (registry read), KERNEL32 |

Registry key read: `Software\Worldweaver Productions\Beasts and Bumpkins` (values `Working`, `MissionText`, `Speech`, `Language`, `Installed`, and box file paths). Saves use `savegam%d.sav`.

## bb-patch preimages

Checked against bb-patch commit `f2312876412ee356f7496fd66d72f88364b73bbe`. All match this executable:

| Patch                   | File offset           | Original         | Replacement            |
| ----------------------- | --------------------- | ---------------- | ---------------------- |
| No-CD                   | `0x2DE39`             | `E9 62 FD FF FF` | `90 90 90 90 90`       |
| Developer console (F11) | `0x828A3` (534691)    | dword `0`        | dword `1`              |
| Screen width / height   | `0x82A44` / `0x82A48` | `640` / `480`    | width / height         |
| Portrait X / Y          | `0x29714` / `0x2972D` | `540` / `380`    | width-100 / height-100 |

No-CD output (`nocd` only): sha256 `3d6934988b8a4721f0018d5aeadb2082e315c1467891f6191d5f5310f52c5f3d`, 5 bytes changed.

bb-patch's "lag fix" is not an EXE patch: it drops dxwrapper (DDrawCompat) in as `ddraw.dll`. We use cnc-ddraw as `ddraw.dll` instead, which replaces DirectDraw entirely; gameplay speed confirmed normal under CrossOver.

## Developer mode

The console flag is the dword at VA `0x4842A0`; bb-patch writes `1` at `0x4842A3`, setting its top byte, which is enough for the `test eax, eax` checks. With it set, VK `0x7A` (F11) cycles `byte [0x4843E8]` through 0, 1, 2:

| State | Label (top-right) | Input                                                                     |
| ----: | ----------------- | ------------------------------------------------------------------------- |
|     0 | none              | normal play                                                               |
|     1 | `CHEAT`           | Edit mode, single-key commands (`G` gold, `o103`, `o110`, `C`, Ctrl+F6)   |
|     2 | Script            | typed commands (`loadmission`, Enter, mission number), handler `0x4268D0` |

Key dispatch (all VK codes from `WM_KEYDOWN`):

| Where                   | Mechanism                                      | Index table (VA / file) | Key range     | F11 entry |
| ----------------------- | ---------------------------------------------- | ----------------------- | ------------- | --------: |
| Normal play, `0x403F5F` | byte index table, pointers at `0x4061A4`       | `0x4061C4` / `0x55C4`   | `0x25`-`0xBD` |    `0x05` |
| Edit mode, `0x40414E`   | byte index table, pointers at `0x406260`       | `0x406304` / `0x5704`   | `0x09`-`0xBD` |    `0x25` |
| Script text, `0x4268D0` | `cmp ecx, 0x7A` at `0x42697D` (file `0x25D7D`) | n/a                     | any           |       n/a |

The Script handler accepts `0-9`, `A-Z` (`cmp ecx, 0x5A` at `0x4268EA`, file `0x25CEA`), space and `, - ; .` as text before checking the toggle key. Letters without an Edit mode command: B J Q W X Y Z. `bbpatch.py` `console-f12` / `console-z` swap the F11 index entries with the new key's (both default case) and change the Script compare; `console-z` also ends the text range at `Y`.

## ogg-winmm (CD music)

v2025.01.16 `winmm.dll` (sha256 `9d2bf7f5…dcdd5`) crashes under Wine on `open cdaudio`: its `fake_mciSendStringA` calls the real `mciSendCommandA(0xCDDA, MCI_OPEN, 0, NULL)` and Wine's `MCI_Open` writes through the NULL (`page fault on write access to 00000004`, return address `winmm+0x255A`). Upstream issue ayuanx/ogg-winmm#25, fixed in commit `11c13ec` by removing the call, not released. `bb.py` NOPs the call and its `sub esp, 0x10` (file offset `0x1955`, `E8 16 15 00 00 83 EC 10`); the path then returns 0 as upstream does. Patched sha256 `6ef5ec89…2998`.
