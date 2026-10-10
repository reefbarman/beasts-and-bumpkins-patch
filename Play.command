#!/bin/bash
# Double-click to start Beasts & Bumpkins on macOS (after Install.command).
cd "$(dirname "$0")" || exit 1
python3 scripts/bb.py run "$@"
