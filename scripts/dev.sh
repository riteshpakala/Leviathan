#!/bin/bash
# WHAT: Build + run the Mac app.
# PIN:  Builds the whole package, not just the app, so .build/$CONFIG/leviathan runs the same
#       core as the window it opens.
# PIN:  No signing step, unlike Ambient's and Craft's. Keys go through /usr/bin/security, so the
#       Keychain items trust that tool rather than this binary's cdhash and survive rebuilds
#       already; the app asks for no TCC grants.
# OUT:  exec .build/$CONFIG/LeviathanApp with any arguments passed through.
#
#   ./scripts/dev.sh
#   CONFIG=release ./scripts/dev.sh
#   LEVIATHAN_ROOT=/path/to/workspace ./scripts/dev.sh      # open another workspace
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
cd "$REPO_ROOT"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG"

exec "$REPO_ROOT/.build/$CONFIG/LeviathanApp" "$@"
