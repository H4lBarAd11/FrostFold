#!/usr/bin/env bash
# Draws the repository's social preview, the card a link to it unfurls into.
#   Scripts/social-preview.sh
#
# GitHub takes it only as an upload, under Settings → General → Social preview,
# and wants a PNG or JPG under 1 MB, ideally 1280x640. There is no API for it,
# so this writes docs/social-preview.png and the upload is done by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=.build/social
mkdir -p "$WORK"
python3 Tools/banner/make.py --social "$WORK/social-preview.svg"
swiftc -O Tools/banner/rasterise.swift -o "$WORK/rasterise"
"$WORK/rasterise" "$WORK/social-preview.svg" docs/social-preview.png 1280 640

echo "docs/social-preview.png  ($(du -h docs/social-preview.png | cut -f1))"
