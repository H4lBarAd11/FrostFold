#!/usr/bin/env bash
# Renders the pane over a still image at a range of lid angles.
#   Scripts/filmstrip.sh --input shot.png --out docs/images --mode both
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/filmstrip-tool
mkdir -p "$(dirname "$OUT")"

swiftc -O \
  Sources/FrostFold/Shaders.swift \
  Sources/FrostFold/MetalRenderer.swift \
  Sources/FrostFold/Settings.swift \
  Tools/filmstrip/main.swift \
  -o "$OUT"

exec "$OUT" "$@"
