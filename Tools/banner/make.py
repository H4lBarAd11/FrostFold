#!/usr/bin/env python3
"""Draws docs/readme/banner.svg in the house format: 1280x360, DM Sans embedded
as base64 so GitHub renders it without a network font, sage into caramel on the
ivory ground."""
import base64, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FONTS = HERE / "fonts"
OUT = ROOT / "docs" / "readme" / "banner.svg"

def face(weight):
    p = FONTS / f"dm-sans-{weight}.woff2"
    if not p.exists():
        sys.exit(f"missing {p}")
    b64 = base64.b64encode(p.read_bytes()).decode()
    return ("@font-face{font-family:'DM Sans';font-style:normal;font-weight:%d;"
            "src:url(data:font/woff2;base64,%s) format('woff2')}" % (weight, b64))

BG, INK, INK_SOFT = "#F9F8EF", "#404040", "#7A7A76"
SAGE, CARAMEL, LINE = "#6E8B6E", "#9A6636", "#D9D5C4"

# The pane, converging as it folds away, hinged along its bottom edge.
hinge_y, top_y = 286, 96
hinge_half, top_half = 168, 104
cx = 1032

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="360" viewBox="0 0 1280 360" role="img" aria-label="FrostFold — a pane of frosted glass, hinged along the bottom edge of your MacBook's display, driven by the lid-angle sensor">
<title>FrostFold</title>
<defs>
<style>{face(400)}{face(700)}</style>
<linearGradient id="pane" x1="0" y1="1" x2="0.35" y2="0">
  <stop offset="0" stop-color="{SAGE}"/>
  <stop offset="0.55" stop-color="#84764F"/>
  <stop offset="1" stop-color="{CARAMEL}"/>
</linearGradient>
<linearGradient id="frost" x1="0" y1="1" x2="0" y2="0">
  <stop offset="0" stop-color="{BG}" stop-opacity="0"/>
  <stop offset="0.55" stop-color="{BG}" stop-opacity="0.6"/>
  <stop offset="1" stop-color="{BG}" stop-opacity="0.96"/>
</linearGradient>
<linearGradient id="hinge" x1="0" y1="0" x2="1" y2="0">
  <stop offset="0" stop-color="{CARAMEL}" stop-opacity="0.15"/>
  <stop offset="0.5" stop-color="{CARAMEL}" stop-opacity="0.85"/>
  <stop offset="1" stop-color="{CARAMEL}" stop-opacity="0.15"/>
</linearGradient>
</defs>

<rect width="1280" height="360" fill="{BG}"/>

<!-- the display the pane has lifted off, with nothing left to show -->
<rect x="{cx-hinge_half-26}" y="70" width="{2*(hinge_half+26)}" height="252" rx="10" fill="#14150F" opacity="0.92"/>
<path d="M{cx-hinge_half} {hinge_y} L{cx+hinge_half} {hinge_y} L{cx+top_half} {top_y} L{cx-top_half} {top_y} Z" fill="url(#pane)"/>
<path d="M{cx-hinge_half} {hinge_y} L{cx+hinge_half} {hinge_y} L{cx+top_half} {top_y} L{cx-top_half} {top_y} Z" fill="url(#frost)"/>
<path d="M{cx-hinge_half} {hinge_y} L{cx+hinge_half} {hinge_y}" stroke="url(#hinge)" stroke-width="3" stroke-linecap="round"/>

<g font-family="DM Sans, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif">
  <text x="96" y="152" font-size="70" font-weight="700" letter-spacing="-1.8" fill="{SAGE}">FrostFold</text>
  <text x="99" y="196" font-size="20" font-weight="400" fill="{INK}">Glass that follows your hinge.</text>
  <text x="99" y="234" font-size="15" font-weight="400" fill="{INK_SOFT}">Your display tips back behind frosted glass</text>
  <text x="99" y="256" font-size="15" font-weight="400" fill="{INK_SOFT}">as you close the lid.</text>
  <line x1="99" y1="282" x2="520" y2="282" stroke="{LINE}" stroke-width="1"/>
  <text x="99" y="308" font-size="11" font-weight="700" letter-spacing="1.7" fill="{CARAMEL}">MACOS 14+ · METAL · OPEN SOURCE</text>
</g>
</svg>
'''
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(svg)
print(f"  wrote {OUT.relative_to(ROOT)}  ({len(svg)//1024} KB)")
