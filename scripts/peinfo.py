#!/usr/bin/env python3
"""Print identity and structure of a 32-bit PE executable: hashes, header, sections, imports.

Usage: peinfo.py <file.exe> [--all-imports]
"""

from __future__ import annotations

import datetime
import hashlib
import struct
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    all_imports = "--all-imports" in sys.argv
    d = path.read_bytes()

    print(f"file      {path.name}  {len(d)} bytes")
    for algo in ("md5", "sha256"):
        print(f"{algo:<9} {hashlib.new(algo, d).hexdigest()}")

    if d[:2] != b"MZ":
        raise SystemExit("not an MZ executable")
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe : pe + 4] != b"PE\0\0":
        raise SystemExit("no PE header")
    machine, nsec, ts = struct.unpack_from("<HHI", d, pe + 4)
    opt_size = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    entry = struct.unpack_from("<I", d, opt + 16)[0]
    image_base = struct.unpack_from("<I", d, opt + 28)[0]
    subsystem = struct.unpack_from("<H", d, opt + 68)[0]
    linked = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
    print(
        f"machine   {machine:#x}  magic {magic:#x}  subsystem {subsystem}  "
        f"image_base {image_base:#x}  entry_rva {entry:#x}  linked {linked:%Y-%m-%d %H:%M:%S}Z"
    )

    sections = []
    so = opt + opt_size
    for i in range(nsec):
        name, vsize, va, rsize, raw = struct.unpack_from("<8sIIII", d, so + 40 * i)
        flags = struct.unpack_from("<I", d, so + 40 * i + 36)[0]
        name = name.rstrip(b"\0").decode(errors="replace")
        sections.append((va, max(vsize, rsize), raw))
        print(
            f"section   {name:<8} va {va:#08x} vsize {vsize:#08x} raw {raw:#08x} "
            f"rsize {rsize:#08x} flags {flags:#010x}"
        )

    def rva_to_off(rva: int) -> int:
        for va, size, raw in sections:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError(f"rva {rva:#x} outside sections")

    def cstr(off: int) -> str:
        return d[off : d.index(b"\0", off)].decode(errors="replace")

    import_rva = struct.unpack_from("<I", d, opt + 96 + 8)[0]
    if not import_rva:
        print("imports   none")
        return 0
    p = rva_to_off(import_rva)
    while True:
        olt, _, _, name_rva, ft = struct.unpack_from("<IIIII", d, p)
        if name_rva == 0:
            break
        dll = cstr(rva_to_off(name_rva))
        t = rva_to_off(olt or ft)
        funcs = []
        while (v := struct.unpack_from("<I", d, t)[0]) != 0:
            funcs.append(f"#{v & 0xFFFF}" if v & 0x80000000 else cstr(rva_to_off(v) + 2))
            t += 4
        shown = funcs if all_imports else funcs[:12]
        more = "" if len(shown) == len(funcs) else f", ... (+{len(funcs) - len(shown)})"
        print(f"import    {dll} ({len(funcs)}): {', '.join(shown)}{more}")
        p += 20
    return 0


if __name__ == "__main__":
    sys.exit(main())
