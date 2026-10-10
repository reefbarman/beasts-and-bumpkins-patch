#!/bin/bash
# Double-click to set up Beasts & Bumpkins on macOS (needs CrossOver).
# It asks for your disc, then prepares, installs and (optionally) starts the game.
cd "$(dirname "$0")" || exit 1

if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    echo "Python 3.9 or newer is needed."
    echo "If macOS just offered to install the command line developer tools, accept,"
    echo "wait for it to finish, then double-click Install.command again."
    exit 1
fi

python3 scripts/bb.py setup "$@"
