#!/usr/bin/env python3
"""Beasts & Bumpkins restoration CLI for macOS (CrossOver) and Windows.

You supply your own copy of the game disc (BIN/CUE). Nothing from the game is
stored in this repository; everything generated lives in .local/.

  python3 scripts/bb.py prepare --cue "path/to/BEASTS&BUMPKINS.cue"
  python3 scripts/bb.py install            # CrossOver bottle (macOS) or C:\\Games\\Beasts (Windows)
  python3 scripts/bb.py run [--fullscreen]

prepare: splits the disc image, extracts game files, builds the verified
         no-CD BEASTS.EXE, downloads the pinned cnc-ddraw (graphics) and
         ogg-winmm (CD music) wrappers and encodes the music tracks.
install: builds BEASTS.EXE (no-CD, plus --console [--console-key KEY] for
         developer mode), copies everything into place and writes the registry
         values the game expects. Re-running it keeps existing saves.
run:     launches the game, window (default) or borderless fullscreen.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
LOCAL = ROOT / ".local"
DISC = LOCAL / "disc"
FILES = DISC / "files"
MUSIC = DISC / "music"
BUILD_EXE = LOCAL / "build" / "BEASTS.EXE"
DOWNLOADS = LOCAL / "downloads"
STATE = LOCAL / "install.json"
CONFIG = ROOT / "config"

sys.path.insert(0, str(SCRIPTS))
import bbpatch  # noqa: E402
import bincue  # noqa: E402
import iso9660  # noqa: E402

TRACKS = [f"{n:02d}" for n in range(2, 9)]

# Pinned third-party wrappers: (zip url, zip sha256, {member: sha256 as installed}).
WRAPPERS = {
    "cnc-ddraw": (
        "https://github.com/FunkyFr3sh/cnc-ddraw/releases/download/v7.1.0.0/cnc-ddraw.zip",
        "0b13ab89a64c9918189b1dadd449ef6ed3cb3b7b19cabd96d8adbd95505bb908",
        {"ddraw.dll": "85e0f7d530dfda134793a57cb3e76b0287dcc96892ee57162dd68f47283b03a9"},
    ),
    "ogg-winmm": (
        "https://github.com/ayuanx/ogg-winmm/releases/download/v2025.01.16/ogg-winmm_binary.zip",
        "f77b2c01e408bf5d1445c927f54d5932cd9101f46cd0cb4593bd20ef4b1af04b",
        {
            "winmm.dll": "6ef5ec89f259f948e5a24e436423ce2207e5ac600587020b72f0f82235c12998",
            "winmm.ini": "cd6be6bb8bd0346cef44430c5daad53e4b1d1d966e5d3d8d98febd5f10122be7",
        },
    ),
}

# Byte patches applied to wrapper members: {(wrapper, member): (original sha256, [(offset, old, new)])}.
#
# ogg-winmm v2025.01.16 forwards "open cdaudio" to the real winmm as
# mciSendCommandA(0xCDDA, MCI_OPEN, 0, NULL). Wine dereferences the NULL and
# crashes the game at startup. Upstream fixed this by dropping the call
# (ayuanx/ogg-winmm#25, commit 11c13ec) but has not released it, so we NOP the
# call and its stack readjustment; the function then returns 0 as upstream does.
WRAPPER_PATCHES = {
    ("ogg-winmm", "winmm.dll"): (
        "9d2bf7f573b195947cef8f83145748f9170ed15289888f6d731de67fb51dcdd5",
        [(0x1955, bytes.fromhex("e81615000083ec10"), b"\x90" * 8)],
    ),
}

# Disc files not needed by the installed game.
SKIP_FILES = {"AUTORUN.EXE", "AUTORUN.INF", "SETUP.EXE", "BBUNINST.EXE", "BEASTS.EXE"}
SKIP_PREFIX = "DSETUP"

REG_KEY = r"Software\Worldweaver Productions\Beasts and Bumpkins"

CROSSOVER_BIN = Path("/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin")
DEFAULT_BOTTLE = "BeastsAndBumpkins"
DEFAULT_WIN_DIR = r"C:\Games\Beasts"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def is_windows() -> bool:
    return platform.system() == "Windows"


# ---------------------------------------------------------------- prepare


def fetch_wrapper(name: str) -> Path:
    url, zip_sha, members = WRAPPERS[name]
    dest = DOWNLOADS / name
    if all((dest / m).exists() and sha256(dest / m) == h for m, h in members.items()):
        return dest
    dest.mkdir(parents=True, exist_ok=True)
    zpath = dest / Path(url).name
    if not zpath.exists() or sha256(zpath) != zip_sha:
        print(f"downloading {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "bb-restoration"})
        with urllib.request.urlopen(req) as r, zpath.open("wb") as f:
            shutil.copyfileobj(r, f)
    if sha256(zpath) != zip_sha:
        raise SystemExit(f"{zpath.name}: unexpected sha256 {sha256(zpath)}")
    with zipfile.ZipFile(zpath) as z:
        for m, h in members.items():
            data = bytearray(z.read(m))
            if (name, m) in WRAPPER_PATCHES:
                orig, patches = WRAPPER_PATCHES[(name, m)]
                if hashlib.sha256(data).hexdigest() != orig:
                    raise SystemExit(f"{name}/{m}: unexpected original sha256")
                for off, old, new in patches:
                    if data[off:off + len(old)] != old:
                        raise SystemExit(f"{name}/{m}: unexpected bytes at {off:#x}")
                    data[off:off + len(old)] = new
            if hashlib.sha256(data).hexdigest() != h:
                raise SystemExit(f"{name}/{m}: unexpected sha256")
            (dest / m).write_bytes(data)
    return dest


def find_encoder() -> list[str] | None:
    """Return an OGG Vorbis encoder command prefix, or None."""
    if shutil.which("oggenc"):
        return ["oggenc", "-Q", "-q", "6", "-o"]
    if shutil.which("ffmpeg"):
        out = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
        if "libvorbis" in out:
            return ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-c:a", "libvorbis", "-q:a", "6"]
    return None


def encode_music() -> bool:
    MUSIC.mkdir(parents=True, exist_ok=True)
    todo = [n for n in TRACKS if not (MUSIC / f"Track{n}.ogg").exists()]
    if not todo:
        return True
    enc = find_encoder()
    if enc is None:
        print("warning: no OGG encoder found, skipping CD music.\n"
              "  macOS: brew install vorbis-tools\n"
              "  Windows: install oggenc (vorbis-tools) or an ffmpeg build with libvorbis, then rerun prepare")
        return False
    for n in todo:
        wav, ogg = DISC / f"track{n}.wav", MUSIC / f"Track{n}.ogg"
        if enc[0] == "oggenc":
            cmd = enc + [str(ogg), str(wav)]
        else:
            cmd = enc[:5] + ["-i", str(wav)] + enc[5:] + [str(ogg)]
        subprocess.run(cmd, check=True)
        print(f"encoded {ogg.name}")
    return True


def cmd_prepare(args) -> int:
    cue = Path(args.cue)
    if not cue.exists():
        raise SystemExit(f"{cue} not found")
    iso = DISC / "track01.iso"
    if not iso.exists() or not all((DISC / f"track{n}.wav").exists() for n in TRACKS):
        bincue.split(cue, DISC)
    if not (FILES / "BEASTS.EXE").exists():
        print(f"extracted {iso9660.extract(iso, FILES, ('REDIST',))} files")
    bbpatch.cmd_apply(FILES / "BEASTS.EXE", BUILD_EXE, ["nocd"], None)
    for name in WRAPPERS:
        print(f"{name}: {fetch_wrapper(name)}")
    encode_music()
    print("prepare complete; next: python3 scripts/bb.py install")
    return 0


# ---------------------------------------------------------------- install


def registry_values(win_dir: str) -> dict:
    d = win_dir.rstrip("\\") + "\\"
    return {
        "Audio": d + "audio.box",
        "CD": d,
        "InstallDir": d[2:],
        "InstallDrive": d[:2],
        "Link": "",
        "Misc": d + "misc.box",
        "Missions": d + "missions.box",
        "MissionText": d + "mistext0.box",
        "Speech": d + "speech0.box",
        "Video": d + "video.box",
        "Working": d,
        "Installed": 1,
        "Language": 0,
    }


def copy_game(dest: Path, music: bool) -> None:
    if not BUILD_EXE.exists() or not (FILES / "BEASTS.EXE").exists():
        raise SystemExit("run prepare first")
    dest.mkdir(parents=True, exist_ok=True)
    for src in FILES.iterdir():
        if src.is_file() and src.name.upper() not in SKIP_FILES and not src.name.upper().startswith(SKIP_PREFIX):
            shutil.copyfile(src, dest / src.name)
    shutil.copyfile(BUILD_EXE, dest / "BEASTS.EXE")
    shutil.copyfile(DOWNLOADS / "cnc-ddraw" / "ddraw.dll", dest / "ddraw.dll")
    write_ddraw_ini(dest, fullscreen=False)
    if music:
        shutil.copyfile(DOWNLOADS / "ogg-winmm" / "winmm.dll", dest / "winmm.dll")
        shutil.copyfile(DOWNLOADS / "ogg-winmm" / "winmm.ini", dest / "winmm.ini")
        (dest / "Music").mkdir(exist_ok=True)
        for n in TRACKS:
            shutil.copyfile(MUSIC / f"Track{n}.ogg", dest / "Music" / f"Track{n}.ogg")
    else:
        for name in ("winmm.dll", "winmm.ini"):
            (dest / name).unlink(missing_ok=True)


def write_ddraw_ini(dest: Path, fullscreen: bool) -> None:
    text = (CONFIG / "cnc-ddraw" / "ddraw.ini").read_text()
    text = re.sub(r"(?m)^fullscreen=.*$", f"fullscreen={'true' if fullscreen else 'false'}", text)
    (dest / "ddraw.ini").write_text(text)


def reg_file_text(values: dict, overrides: dict) -> str:
    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    lines = ["REGEDIT4", "", f"[HKEY_CURRENT_USER\\{REG_KEY}]"]
    for k, v in values.items():
        lines.append(f'"{k}"=dword:{v:08x}' if isinstance(v, int) else f'"{k}"="{esc(v)}"')
    lines += ["", r"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\BEASTS.EXE\DllOverrides]"]
    for dll, mode in overrides.items():
        lines.append(f'"{dll}"=-' if mode is None else f'"{dll}"="{mode}"')
    return "\r\n".join(lines) + "\r\n"


def install_windows(args, music: bool) -> dict:
    import winreg

    if args.bottle:
        print("note: --bottle only applies to macOS CrossOver, ignoring")
    # Absolute, backslash form: the registry values split drive and folder.
    win_dir = os.path.abspath(args.target or DEFAULT_WIN_DIR)
    if "program files" in win_dir.lower():
        print("warning: installing under Program Files can break saves (UAC virtualisation)")
    copy_game(Path(win_dir), music)
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, REG_KEY) as key:
        for k, v in registry_values(win_dir).items():
            if isinstance(v, int):
                winreg.SetValueEx(key, k, 0, winreg.REG_DWORD, v)
            else:
                winreg.SetValueEx(key, k, 0, winreg.REG_SZ, v)
    return {"platform": "windows", "game_dir": win_dir}


def wine_cmd(bottle: str) -> list[str]:
    return [str(CROSSOVER_BIN / "wine"), "--bottle", bottle]


def install_crossover(args, music: bool) -> dict:
    if not (CROSSOVER_BIN / "wine").exists():
        raise SystemExit("CrossOver not found in /Applications (install supports macOS CrossOver and Windows)")
    if args.target:
        print("note: --target only applies to Windows, the bottle always uses C:\\Games\\Beasts")
    bottle = args.bottle or DEFAULT_BOTTLE
    prefix = Path.home() / "Library/Application Support/CrossOver/Bottles" / bottle
    if not (prefix / "drive_c").exists():
        print(f"creating CrossOver bottle {bottle}")
        subprocess.run([str(CROSSOVER_BIN / "cxbottle"), "--bottle", bottle, "--create", "--template", "winxp",
                        "--description", "Beasts and Bumpkins"], check=True)
    win_dir = DEFAULT_WIN_DIR
    game_dir = prefix / "drive_c" / "Games" / "Beasts"
    copy_game(game_dir, music)
    overrides = {"ddraw": "native,builtin", "winmm": "native,builtin" if music else None}
    with tempfile.NamedTemporaryFile("w", suffix=".reg", delete=False, newline="") as f:
        f.write(reg_file_text(registry_values(win_dir), overrides))
        reg = f.name
    try:
        subprocess.run(wine_cmd(bottle) + ["--no-gui", "regedit", "/S", "Z:" + reg.replace("/", "\\")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        os.unlink(reg)
    return {"platform": "crossover", "bottle": bottle, "game_dir": str(game_dir), "win_dir": win_dir}


def cmd_install(args) -> int:
    for name in WRAPPERS:
        fetch_wrapper(name)
    if not (FILES / "BEASTS.EXE").exists():
        raise SystemExit("run prepare first")
    patches = ["nocd"]
    if args.console:
        patches.append("console")
        if args.console_key != "F11":
            patches.append(f"console-{args.console_key.lower()}")
    bbpatch.cmd_apply(FILES / "BEASTS.EXE", BUILD_EXE, patches, None)
    music = not args.no_music and all((MUSIC / f"Track{n}.ogg").exists() for n in TRACKS)
    if not music and not args.no_music:
        print("warning: music tracks missing, installing without CD music (rerun prepare with an OGG encoder)")
    state = install_windows(args, music) if is_windows() else install_crossover(args, music)
    state["music"] = music
    state["patches"] = patches
    STATE.write_text(json.dumps(state, indent=2))
    print(f"installed to {state['game_dir']} (music: {'on' if music else 'off'}, patches: {', '.join(patches)})")
    print("next: python3 scripts/bb.py run")
    return 0


# ---------------------------------------------------------------- run


def cmd_run(args) -> int:
    if not STATE.exists():
        raise SystemExit("run install first")
    state = json.loads(STATE.read_text())
    game_dir = Path(state["game_dir"])
    write_ddraw_ini(game_dir, fullscreen=args.fullscreen)
    logs = LOCAL / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / f"run-{time.strftime('%Y%m%d-%H%M%S')}.log"
    print(f"launching ({'fullscreen' if args.fullscreen else 'window'}), log: {log}")
    if state["platform"] == "windows":
        cmd = [str(game_dir / "BEASTS.EXE")]
        env = None
    else:
        cmd = wine_cmd(state["bottle"]) + ["--workdir", state["win_dir"], state["win_dir"] + "\\BEASTS.EXE"]
        env = dict(os.environ, WINEDEBUG=os.environ.get("WINEDEBUG", "err+all,fixme-all"))
    with log.open("w") as out:
        return subprocess.run(cmd, cwd=game_dir, stdout=out, stderr=subprocess.STDOUT, env=env).returncode


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("prepare", help="extract, patch and download wrappers")
    pp.add_argument("--cue", required=True, help="path to BEASTS&BUMPKINS.cue (with its .bin alongside)")
    pi = sub.add_parser("install", help="install into CrossOver bottle (macOS) or folder (Windows)")
    pi.add_argument("--bottle", help=f"CrossOver bottle name (default {DEFAULT_BOTTLE})")
    pi.add_argument("--target", help=f"Windows install folder (default {DEFAULT_WIN_DIR})")
    pi.add_argument("--no-music", action="store_true", help="skip the ogg-winmm CD music wrapper")
    pi.add_argument("--console", action="store_true", help="enable developer mode (cheats, editor)")
    pi.add_argument("--console-key", choices=["F11", "F12", "Z"], default="F11",
                    help="developer mode key (default F11, which macOS uses for Show Desktop)")
    pr = sub.add_parser("run", help="launch the game")
    mode = pr.add_mutually_exclusive_group()
    mode.add_argument("--window", action="store_true", help="2x scaled window (default)")
    mode.add_argument("--fullscreen", action="store_true", help="borderless fullscreen")
    args = p.parse_args()
    return {"prepare": cmd_prepare, "install": cmd_install, "run": cmd_run}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
