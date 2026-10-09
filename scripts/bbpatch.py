#!/usr/bin/env python3
"""Produce a patched copy of BEASTS.EXE from a known original.

Patches are byte-for-byte edits derived from bb-patch
(https://github.com/bb-patch/bb-patch, GPL-3.0, commit f2312876), verified
against the EU CD release below. The input is never modified, unknown inputs
are refused and every edit checks its original bytes first.

Usage:
  bbpatch.py inspect <BEASTS.EXE>
  bbpatch.py apply <BEASTS.EXE> <output.exe> [--patch NAME ...] [--resolution WxH]

Default patches: nocd. Optional: console, console-f12 / console-z (developer
mode on F12 or Z instead of F11), resolution.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

# EU CD release, md5 2d2852fcb22e6f65a0cf3415abaf4411 (the bb-patch test target).
KNOWN_ORIGINAL_SHA256 = "b30d7d0762dbd808407f0d95c6fdafa0b52ce67d0b0f20c8fbb7fa66a2213e89"
KNOWN_ORIGINAL_SIZE = 916992


@dataclass(frozen=True)
class Edit:
    offset: int
    original: bytes
    replacement: bytes


def u32(value: int) -> bytes:
    return struct.pack("<I", value)


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
    w, h = struct.unpack_from("<II", data, 0x82A44)
    print(f"  resolution: {w}x{h}")
    return 0


def cmd_apply(src: Path, dest: Path, names: list[str], resolution: str | None) -> int:
    data = bytearray(src.read_bytes())
    if identify(bytes(data)) != "original":
        raise SystemExit(f"refusing: {src} is not the known original BEASTS.EXE")
    if dest.resolve() == src.resolve():
        raise SystemExit("refusing: output must differ from input")

    edits: list[Edit] = []
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
        else:
            raise SystemExit(f"unknown patch {name}")

    for e in edits:
        current = bytes(data[e.offset : e.offset + len(e.original)])
        if current != e.original:
            raise SystemExit(f"preimage mismatch at {e.offset:#x}: {current.hex()} != {e.original.hex()}")
    for e in edits:
        data[e.offset : e.offset + len(e.replacement)] = e.replacement

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
    p_apply.add_argument("--patch", action="append", choices=["nocd", "console", "console-f12", "console-z", "resolution"])
    p_apply.add_argument("--resolution")
    args = parser.parse_args()
    if args.cmd == "inspect":
        return cmd_inspect(args.exe)
    return cmd_apply(args.exe, args.output, args.patch or ["nocd"], args.resolution)


if __name__ == "__main__":
    sys.exit(main())
