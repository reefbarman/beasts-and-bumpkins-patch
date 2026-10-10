#!/usr/bin/env python3
"""Produce a patched copy of BEASTS.EXE from a known original.

Byte edits are derived from bb-patch (https://github.com/bb-patch/bb-patch,
GPL-3.0, commit f2312876) or our own analysis, verified against the EU CD
release below. The input is never modified, unknown inputs are refused and
every edit checks its original bytes first. Output is always built from the
original, so applying is idempotent.

Code patches (qol, screenmode) are our own assembly in patches/*.asm,
assembled with nasm into patches/*.bin (committed, so applying needs no nasm),
appended as new PE sections, and reached through call hooks at known sites.
Each blob is assembled for a fixed address: qol at 0x71F000, screenmode right
after it at 0x720000, so screenmode needs qol.

Usage:
  bbpatch.py inspect <BEASTS.EXE>
  bbpatch.py apply <BEASTS.EXE> <output.exe> [--patch NAME ...] [--resolution WxH]
  bbpatch.py assemble          (rebuild patches/*.bin with nasm)

Default patches: nocd. Optional: console, console-f12 / console-z (developer
mode on F12 or Z instead of F11), qol (WASD scrolling, F5 quicksave, F9
quickload), screenmode (640x480 front end, registry size in missions, main
menu OPTIONS page to change it; needs qol), resolution (bb-patch's EXE
default edits; superseded by screenmode plus the DisplayWidth/DisplayHeight
registry values).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

# EU CD release, md5 2d2852fcb22e6f65a0cf3415abaf4411 (the bb-patch test target).
KNOWN_ORIGINAL_SHA256 = "b30d7d0762dbd808407f0d95c6fdafa0b52ce67d0b0f20c8fbb7fa66a2213e89"
KNOWN_ORIGINAL_SIZE = 916992

PATCHES_DIR = Path(__file__).resolve().parent.parent / "patches"
IMAGE_BASE = 0x400000
TEXT_VA, TEXT_RAW, TEXT_SIZE = 0x401000, 0x400, 0x80A00


@dataclass(frozen=True)
class Edit:
    offset: int
    original: bytes
    replacement: bytes


def u32(value: int) -> bytes:
    return struct.pack("<I", value)


def text_offset(va: int) -> int:
    if not TEXT_VA <= va < TEXT_VA + TEXT_SIZE:
        raise ValueError(f"{va:#x} is outside .text")
    return va - TEXT_VA + TEXT_RAW


def patch_nocd() -> list[Edit]:
    # jmp at VA 0x0042EA39 skips into the CD check failure path; NOP it out.
    return [Edit(0x2DE39, bytes.fromhex("e962fdffff"), b"\x90" * 5)]


def patch_console() -> list[Edit]:
    # Developer console flag (F11), VA 0x004842A3.
    return [Edit(534691, u32(0), u32(1))]


CONSOLE_KEYS = {"F12": 0x7B, "Z": 0x5A}


def patch_console_key(key: str) -> list[Edit]:
    # Move the developer-mode key off F11 (VK 0x7A); macOS takes F11 for Show
    # Desktop. Our own analysis, not from bb-patch. F11 cycles normal -> Edit
    # ("CHEAT", single-key commands) -> Script (typed commands) -> normal.
    # The normal and Edit mode key switches dispatch through byte index tables
    # (VA 0x004061C4, keys 0x25..0xBD; VA 0x00406304, keys 0x09..0xBD): swap the
    # F11 entry with the new key's, which hits the default case in both. The
    # Script mode text handler compares the key directly (cmp ecx, 0x7A at VA
    # 0x0042697D). For a letter it also accepts A-Z as text first (cmp ecx, 0x5A
    # at VA 0x004268EA), so for Z we end that range at Y; Z can't be typed.
    vk = CONSOLE_KEYS[key]
    edits = [
        Edit(0x55C4 + 0x7A - 0x25, b"\x05", b"\x07"),
        Edit(0x55C4 + vk - 0x25, b"\x07", b"\x05"),
        Edit(0x5704 + 0x7A - 0x09, b"\x25", b"\x28"),
        Edit(0x5704 + vk - 0x09, b"\x28", b"\x25"),
        Edit(0x25D7D, bytes.fromhex("83f97a"), bytes([0x83, 0xF9, vk])),
    ]
    if vk == 0x5A:
        edits.append(Edit(0x25CEA, bytes.fromhex("83f95a"), bytes.fromhex("83f959")))
    return edits


def patch_resolution(width: int, height: int) -> list[Edit]:
    # Screen size (VA 0x00484444/48) and the portrait position (VA 0x0042A310/2A).
    # Experimental: menus and videos are not rescaled and UI glitches remain.
    if width < 640 or height < 480:
        raise SystemExit("resolution must be at least 640x480")
    return [
        Edit(0x82A44, u32(640), u32(width)),
        Edit(0x82A48, u32(480), u32(height)),
        Edit(0x29714, u32(540), u32(width - 100)),
        Edit(0x2972D, u32(380), u32(height - 100)),
    ]


# ------------------------------------------------------------ code patches


@dataclass(frozen=True)
class Section:
    name: bytes
    va: int
    payload: bytes


# Section characteristics: code | initialised data | execute | read | write.
SECTION_FLAGS = 0xE0000060
QOL_VA = 0x71F000
SCREENMODE_VA = 0x720000

# Hook sites for patches/qol.asm, same format as SCREENMODE_HOOKS below.
QOL_HOOKS = [
    (0x403F5F, "8d43db3d98000000", 0),       # key down: arrow-key table lookup
    (0x405493, "8d43f083f818", 1),           # key up: arrow-key table lookup
    (0x40B287, "a16c424800", 2),             # main loop: mov eax, g_screen
]
QOL_JUMPS = {0x403F5F, 0x405493}

# Hook sites for patches/screenmode.asm: (VA, original bytes, header entry
# index or None to NOP). A hooked site becomes "call entry" padded with NOPs,
# or "jmp entry" for sites in SCREENMODE_JUMPS (function entries whose stub
# runs the displaced instructions and jumps back).
SCREENMODE_HOOKS = [
    (0x406B3A, "e871f9ffff", 0),             # WinMain: call ReadRegistry
    (0x41F851, "c7056c42480002000000", 1),   # g_screen = 2, new game
    (0x41F9F3, "c7056c42480002000000", 1),   # g_screen = 2, load game
    (0x41FD8D, "c7056c42480002000000", 1),   # g_screen = 2, next mission
    (0x41FD3E, "c7056c42480001000000", 2),   # g_screen = 1, menu handler
    (0x42DF88, "c7056c42480001000000", 2),   # g_screen = 1, return to menu
    (0x432F0E, "c7056c42480003000000", 3),   # g_screen = 3, PlayVideo
    (0x432F58, "892d6c424800", 4),           # g_screen = ebp, PlayVideo restore
    (0x4330DE, "892d6c424800", 4),           # g_screen = ebp, PlayVideo restore
    (0x40B244, "a16c424800", 5),             # main loop: mov eax, g_screen
    (0x42A310, "33c0c7011c020000", 6),       # portrait x = 540
    (0x42A32A, "c741047c010000", None),      # portrait y = 380
    (0x41FFC0, "56578bf18b4c240c", 7),       # Menu_SetActive(flag) entry
    (0x42B260, "56a13c444800", 8),           # SetViewMode(mode) entry
    (0x40BBA1, "a0bc474800", 9),             # mission frame: full repaint above 640x480
    (0x40BEF2, "b9a0195d00", 10),            # before toolbar: clear strip right of it
    (0x419ABC, "e8cf620100", 11),            # toolbar background blit
    (0x419C46, "bf59020000", 12),            # toolbar slots: x of slot 0
    (0x419D80, "8b44240853", 13),            # Toolbar_Click(x, y) entry
    (0x41A0B0, "83ec04b9ffffffff", 14),      # Toolbar_Tooltip(x, y, buf) entry
    (0x40BF76, "b87f020000", 15),            # season icon x: 0x27F - width
    (0x40BFA2, "b87f020000", 15),            # season icon dirty rect x1
    (0x40BF9B, "6880020000", 16),            # season icon dirty rect x2
    (0x42AE5A, "3d58020000", 17),            # season hover zone left
    (0x42AE6A, "3d80020000", 18),            # season hover zone right
    (0x40C4AD, "6876020000", 19),            # CHEAT label x
    (0x41A76E, "6890010000", 20),            # message-log tab x
    (0x41A79C, "6890010000", 20),            # message-log tab dirty rect x1
    (0x41A787, "68f4010000", 21),            # message-log tab dirty rect x2
    (0x414D48, "3d90010000", 22),            # message-log tab click zone left
    (0x4150F3, "3d90010000", 22),            # message-log tab hover zone left
    (0x414D4F, "3df4010000", 23),            # message-log tab click zone right
    (0x4150FA, "3df4010000", 23),            # message-log tab hover zone right
    (0x41A714, "e877560100", 24),            # bottom panel stone filler blit
    (0x41ED10, "83ec045356", 25),            # Menu_Build(page) entry: OPTIONS page
    (0x41F810, "53568b4106", 26),            # Menu_Select() entry: OPTIONS page
]
SCREENMODE_JUMPS = {0x41FFC0, 0x42B260, 0x419D80, 0x41A0B0, 0x41ED10, 0x41F810}


def load_blob(name: str, va: int, magic: bytes, entries: int) -> tuple[bytes, list[int]]:
    path = PATCHES_DIR / f"{name}.bin"
    if not path.exists():
        raise SystemExit(f"{path} missing; run: bbpatch.py assemble")
    blob = path.read_bytes()
    if blob[:4] != magic:
        raise SystemExit(f"{path}: bad magic {blob[:4]!r}")
    targets = list(struct.unpack_from(f"<{entries}I", blob, 8))
    for t in targets:
        if not va <= t < va + len(blob):
            raise SystemExit(f"{path}: entry {t:#x} outside the blob (assembled for another address?)")
    return blob, targets


def patch_hooked_blob(name: str, section: bytes, va: int, magic: bytes,
                      hooks: list, jumps: set[int]) -> tuple[list[Edit], Section]:
    entries = 1 + max(e for _, _, e in hooks if e is not None)
    blob, targets = load_blob(name, va, magic, entries)
    edits = []
    for site, original_hex, entry in hooks:
        original = bytes.fromhex(original_hex)
        if entry is None:
            replacement = b"\x90" * len(original)
        else:
            rel = (targets[entry] - (site + 5)) & 0xFFFFFFFF
            opcode = b"\xe9" if site in jumps else b"\xe8"
            replacement = opcode + u32(rel) + b"\x90" * (len(original) - 5)
        edits.append(Edit(text_offset(site), original, replacement))
    return edits, Section(section, va, blob)


def patch_qol() -> tuple[list[Edit], Section]:
    return patch_hooked_blob("qol", b".bbqol", QOL_VA, b"BBQL", QOL_HOOKS, QOL_JUMPS)


def patch_screenmode() -> tuple[list[Edit], Section]:
    return patch_hooked_blob("screenmode", b".bbsm", SCREENMODE_VA, b"BBSM", SCREENMODE_HOOKS, SCREENMODE_JUMPS)


def pe_layout(data: bytes) -> tuple[int, int, int]:
    """Return (optional header offset, section table offset, section count)."""
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    return pe + 24, pe + 24 + opt_size, count


def section_names(data: bytes) -> list[bytes]:
    _, table, count = pe_layout(data)
    return [data[table + 40 * i : table + 40 * i + 8].rstrip(b"\0") for i in range(count)]


def append_section(data: bytearray, sec: Section) -> None:
    opt, table, count = pe_layout(data)
    sect_align, file_align = struct.unpack_from("<II", data, opt + 32)
    size_of_headers = struct.unpack_from("<I", data, opt + 60)[0]
    slot = table + 40 * count
    if slot + 40 > size_of_headers or any(data[slot : slot + 40]):
        raise SystemExit("no free section header slot")
    last = table + 40 * (count - 1)
    last_vsize, last_va = struct.unpack_from("<II", data, last + 8)
    va = -(-(last_va + last_vsize) // sect_align) * sect_align
    if IMAGE_BASE + va != sec.va:
        raise SystemExit(f"section {sec.name!r} expects VA {sec.va:#x}, next free is {IMAGE_BASE + va:#x}")
    if len(data) % file_align:
        raise SystemExit("file end is not aligned; refusing to append")
    raw_size = -(-len(sec.payload) // file_align) * file_align
    vsize = -(-len(sec.payload) // sect_align) * sect_align
    header = sec.name.ljust(8, b"\0") + struct.pack("<IIIIIIHHI", len(sec.payload), va, raw_size, len(data),
                                                     0, 0, 0, 0, SECTION_FLAGS)
    data[slot : slot + 40] = header
    struct.pack_into("<H", data, opt - 20 + 2, count + 1)  # FileHeader.NumberOfSections
    struct.pack_into("<I", data, opt + 56, va + vsize)     # SizeOfImage
    data += sec.payload.ljust(raw_size, b"\0")


def cmd_assemble() -> int:
    nasm = shutil.which("nasm")
    if not nasm:
        raise SystemExit("nasm not found (macOS: brew install nasm; Windows: https://nasm.us)")
    for src in sorted(PATCHES_DIR.glob("*.asm")):
        out = src.with_suffix(".bin")
        subprocess.run([nasm, "-f", "bin", "-o", str(out), str(src)], check=True)
        print(f"assembled {out.relative_to(PATCHES_DIR.parent)} ({out.stat().st_size} bytes)")
    return 0


def identify(data: bytes) -> str:
    if len(data) != KNOWN_ORIGINAL_SIZE:
        return "unknown"
    if hashlib.sha256(data).hexdigest() == KNOWN_ORIGINAL_SHA256:
        return "original"
    return "unknown-same-size"


def state_of(data: bytes, edits: list[Edit]) -> str:
    states = set()
    for e in edits:
        current = data[e.offset : e.offset + len(e.original)]
        if current == e.original:
            states.add("original")
        elif current == e.replacement:
            states.add("applied")
        else:
            states.add("conflict")
    return states.pop() if len(states) == 1 else "mixed"


def cmd_inspect(path: Path) -> int:
    data = path.read_bytes()
    print(f"{path}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    print(f"identity: {identify(data)}")
    checks = [("nocd", patch_nocd()), ("console", patch_console())]
    checks += [(f"console-{k.lower()}", patch_console_key(k)) for k in CONSOLE_KEYS]
    for name, edits in checks:
        print(f"  {name}: {state_of(data, edits)}")
    for name, table, section in (("qol", QOL_HOOKS, b".bbqol"), ("screenmode", SCREENMODE_HOOKS, b".bbsm")):
        hooks = [Edit(text_offset(va), bytes.fromhex(o), b"") for va, o, _ in table]
        hooked = "original" if state_of(data, hooks) == "original" else "hooked"
        print(f"  {name}: {hooked}, section {'present' if section in section_names(data) else 'absent'}")
    w, h = struct.unpack_from("<II", data, 0x82A44)
    print(f"  resolution (EXE default): {w}x{h}")
    return 0


def cmd_apply(src: Path, dest: Path, names: list[str], resolution: str | None) -> int:
    data = bytearray(src.read_bytes())
    if identify(bytes(data)) != "original":
        raise SystemExit(f"refusing: {src} is not the known original BEASTS.EXE")
    if dest.resolve() == src.resolve():
        raise SystemExit("refusing: output must differ from input")

    edits: list[Edit] = []
    sections: list[Section] = []
    for name in names:
        if name == "nocd":
            edits += patch_nocd()
        elif name == "console":
            edits += patch_console()
        elif name.startswith("console-") and name[8:].upper() in CONSOLE_KEYS:
            edits += patch_console_key(name[8:].upper())
        elif name == "resolution":
            if not resolution:
                raise SystemExit("--resolution WxH is required for the resolution patch")
            w, h = (int(x) for x in resolution.lower().split("x"))
            edits += patch_resolution(w, h)
        elif name in ("qol", "screenmode"):
            if name == "screenmode" and "qol" not in names:
                raise SystemExit("screenmode needs the qol patch too (its section follows qol's)")
            hook_edits, section = patch_qol() if name == "qol" else patch_screenmode()
            edits += hook_edits
            sections.append(section)
        else:
            raise SystemExit(f"unknown patch {name}")

    spans = sorted((e.offset, e.offset + len(e.original)) for e in edits)
    for (_, end), (start, _) in zip(spans, spans[1:]):
        if start < end:
            raise SystemExit(f"overlapping edits at {start:#x}; these patches can't be combined")
    for e in edits:
        current = bytes(data[e.offset : e.offset + len(e.original)])
        if current != e.original:
            raise SystemExit(f"preimage mismatch at {e.offset:#x}: {current.hex()} != {e.original.hex()}")
        if len(e.replacement) != len(e.original):
            raise SystemExit(f"edit at {e.offset:#x} changes length")
    for e in edits:
        data[e.offset : e.offset + len(e.replacement)] = e.replacement
    for sec in sorted(sections, key=lambda s: s.va):
        append_section(data, sec)

    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=".bbpatch-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        if Path(tmp).read_bytes() != bytes(data):
            raise SystemExit("verification of written output failed")
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(f"wrote {dest} ({', '.join(names)}), sha256 {hashlib.sha256(data).hexdigest()}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_inspect = sub.add_parser("inspect")
    p_inspect.add_argument("exe", type=Path)
    p_apply = sub.add_parser("apply")
    p_apply.add_argument("exe", type=Path)
    p_apply.add_argument("output", type=Path)
    p_apply.add_argument("--patch", action="append",
                         choices=["nocd", "console", "console-f12", "console-z", "qol", "screenmode",
                                  "resolution"])
    p_apply.add_argument("--resolution")
    sub.add_parser("assemble")
    args = parser.parse_args()
    if args.cmd == "inspect":
        return cmd_inspect(args.exe)
    if args.cmd == "assemble":
        return cmd_assemble()
    return cmd_apply(args.exe, args.output, args.patch or ["nocd"], args.resolution)


if __name__ == "__main__":
    sys.exit(main())
