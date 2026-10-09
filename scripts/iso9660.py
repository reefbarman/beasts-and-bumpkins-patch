#!/usr/bin/env python3
"""Minimal ISO 9660 extractor (primary volume descriptor, no Joliet/Rock Ridge).

Enough for the Beasts & Bumpkins data track, which uses plain 8.3 names.
Pure Python so it behaves the same on macOS, Windows and Linux.

Usage: iso9660.py <image.iso> <output-dir> [--exclude TOPDIR ...]
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

SECTOR = 2048


def _records(f, lba: int, size: int):
    f.seek(lba * SECTOR)
    data = f.read(size)
    pos = 0
    while pos < len(data):
        length = data[pos]
        if length == 0:
            # Records never span sectors; skip padding to the next sector.
            pos = (pos // SECTOR + 1) * SECTOR
            continue
        rec = data[pos : pos + length]
        extent, data_len = struct.unpack_from("<I", rec, 2)[0], struct.unpack_from("<I", rec, 10)[0]
        flags, name_len = rec[25], rec[32]
        name = rec[33 : 33 + name_len]
        pos += length
        if name in (b"\x00", b"\x01"):
            continue
        yield name.decode("ascii").split(";")[0].rstrip("."), extent, data_len, bool(flags & 0x02)


def extract(iso: Path, out: Path, exclude: tuple[str, ...] = ()) -> int:
    excluded = {e.upper() for e in exclude}
    count = 0
    with iso.open("rb") as f:
        f.seek(16 * SECTOR)
        pvd = f.read(SECTOR)
        if pvd[0] != 1 or pvd[1:6] != b"CD001":
            raise SystemExit(f"{iso}: no ISO 9660 primary volume descriptor")
        root = pvd[156:190]
        stack = [(struct.unpack_from("<I", root, 2)[0], struct.unpack_from("<I", root, 10)[0], out, True)]
        while stack:
            lba, size, dest, top = stack.pop()
            dest.mkdir(parents=True, exist_ok=True)
            for name, extent, data_len, is_dir in list(_records(f, lba, size)):
                if top and name.upper() in excluded:
                    continue
                if is_dir:
                    stack.append((extent, data_len, dest / name, False))
                    continue
                here = f.tell()
                f.seek(extent * SECTOR)
                remaining = data_len
                with (dest / name).open("wb") as o:
                    while remaining:
                        chunk = f.read(min(remaining, 1 << 20))
                        if not chunk:
                            raise SystemExit(f"{iso}: truncated reading {name}")
                        o.write(chunk)
                        remaining -= len(chunk)
                f.seek(here)
                count += 1
    return count


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("iso", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--exclude", action="append", default=[])
    a = p.parse_args()
    print(f"extracted {extract(a.iso, a.out, tuple(a.exclude))} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
