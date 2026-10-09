#!/usr/bin/env python3
"""Split a single-file BIN/CUE disc image into an ISO data track and WAV audio tracks.

Supports the layout used by the Beasts & Bumpkins disc: one BINARY file, a
MODE1/2352 or MODE2/2352 data track followed by AUDIO tracks. The source files
are only read, never modified.

Usage: bincue.py <image.cue> <output-dir>
"""

from __future__ import annotations

import re
import sys
import wave
from pathlib import Path

RAW_SECTOR = 2352
USER_DATA = 2048
# Offset of user data within a raw sector: 12 sync + 4 header, plus an 8-byte
# subheader for Mode 2 Form 1.
DATA_OFFSET = {"MODE1/2352": 16, "MODE2/2352": 24}


def msf_to_sectors(msf: str) -> int:
    m, s, f = (int(x) for x in msf.split(":"))
    return (m * 60 + s) * 75 + f


def parse_cue(cue: Path) -> tuple[Path, list[dict]]:
    bin_path: Path | None = None
    tracks: list[dict] = []
    for line in cue.read_text(errors="replace").splitlines():
        line = line.strip()
        if m := re.match(r'FILE\s+"(.+)"\s+BINARY', line):
            if bin_path is not None:
                raise SystemExit("multi-file CUE sheets are not supported")
            bin_path = cue.parent / m.group(1).replace("\\", "/")
            if not bin_path.exists():
                # CUE sheets often disagree with the real file name's case.
                matches = [p for p in cue.parent.iterdir() if p.name.lower() == bin_path.name.lower()]
                if matches:
                    bin_path = matches[0]
        elif m := re.match(r"TRACK\s+(\d+)\s+(\S+)", line):
            tracks.append({"number": int(m.group(1)), "mode": m.group(2)})
        elif m := re.match(r"INDEX\s+01\s+(\d+:\d+:\d+)", line):
            tracks[-1]["start"] = msf_to_sectors(m.group(1))
    if bin_path is None or not tracks:
        raise SystemExit("no BINARY file or tracks found in CUE sheet")
    return bin_path, tracks


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    split(Path(sys.argv[1]), Path(sys.argv[2]))
    return 0


def split(cue: Path, out: Path) -> None:
    bin_path, tracks = parse_cue(cue)
    size = bin_path.stat().st_size
    if size % RAW_SECTOR:
        raise SystemExit(f"{bin_path} size {size} is not a multiple of {RAW_SECTOR}")
    total = size // RAW_SECTOR
    out.mkdir(parents=True, exist_ok=True)

    with bin_path.open("rb") as src:
        for i, track in enumerate(tracks):
            start = track["start"]
            end = tracks[i + 1]["start"] if i + 1 < len(tracks) else total
            src.seek(start * RAW_SECTOR)
            name = f"track{track['number']:02d}"
            if track["mode"] == "AUDIO":
                dest = out / f"{name}.wav"
                with wave.open(str(dest), "wb") as wav:
                    wav.setnchannels(2)
                    wav.setsampwidth(2)
                    wav.setframerate(44100)
                    for _ in range(start, end):
                        wav.writeframes(src.read(RAW_SECTOR))
            elif track["mode"] in DATA_OFFSET:
                offset = DATA_OFFSET[track["mode"]]
                dest = out / f"{name}.iso"
                with dest.open("wb") as iso:
                    for _ in range(start, end):
                        sector = src.read(RAW_SECTOR)
                        iso.write(sector[offset : offset + USER_DATA])
            else:
                raise SystemExit(f"unsupported track mode {track['mode']}")
            print(f"{dest.name}: {end - start} sectors")


if __name__ == "__main__":
    sys.exit(main())
