#!/usr/bin/env bash
# Draws the app icon and packs it into Resources/FrostFold.icns, plus a PNG for
# the README. Run it after changing Tools/icon/main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=.build/icon
mkdir -p "$WORK"
swiftc -O Tools/icon/main.swift -o "$WORK/drawicon"
"$WORK/drawicon" "$WORK"

iconutil -c icns "$WORK/FrostFold.iconset" -o Resources/FrostFold.icns
mkdir -p docs/images
cp "$WORK/icon.png" docs/images/icon.png

echo "Resources/FrostFold.icns  ($(du -h Resources/FrostFold.icns | cut -f1))"
