#!/usr/bin/env bash
# Renders the README's stills from a screenshot of your own display.
#   Scripts/stills.sh shot.png
#
# filmstrip.sh writes one full-size frame per angle, named by the angle. The
# README wants three of them at a fixed width plus a larger hero, under the
# names it already references, so this does the sizing and naming.
set -euo pipefail
cd "$(dirname "$0")/.."

IN="${1:?usage: Scripts/stills.sh shot.png}"
OUT=.build/stills

Scripts/filmstrip.sh --input "$IN" --out "$OUT" --angles 100,50,22

sips -Z 520  "$OUT/fold-100.png" --out docs/readme/fold-rest.png    >/dev/null
sips -Z 520  "$OUT/fold-050.png" --out docs/readme/fold-mid.png     >/dev/null
sips -Z 520  "$OUT/fold-022.png" --out docs/readme/fold-closing.png >/dev/null
sips -Z 1200 "$OUT/fold-022.png" --out docs/readme/hero.png         >/dev/null

echo "Wrote docs/readme/{fold-rest,fold-mid,fold-closing,hero}.png"
