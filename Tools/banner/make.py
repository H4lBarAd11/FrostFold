#!/usr/bin/env python3
"""Draws docs/readme/banner.svg in the house format: 1280x360, DM Sans embedded
as base64 so GitHub renders it without a network font, sage into caramel on the
ivory ground.

With --social PATH it also draws the repository's social preview at 1280x640,
the size GitHub asks for. That one is only a step on the way to a PNG, since
GitHub won't take an SVG there; Scripts/social-preview.sh does the rest."""
import argparse, base64, pathlib, sys

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

def n(v):
    """Whole numbers print without a decimal point, so the banner at scale 1
    comes out exactly as it did before the drawing took a scale."""
    v = round(v, 2)
    return str(int(v)) if v == int(v) else str(v)

BG, INK, INK_SOFT = "#F9F8EF", "#404040", "#7A7A76"
SAGE, CARAMEL, LINE = "#6E8B6E", "#9A6636", "#D9D5C4"

LABEL = ("FrostFold — a pane of frosted glass, hinged along the bottom edge of "
         "your MacBook's display, driven by the lid-angle sensor")

def defs():
    return f'''<defs>
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
</defs>'''

def drawing(cx, top, s=1):
    """The pane, converging as it folds away, hinged along its bottom edge.
    `top` is the top of the display behind it; `s` scales the whole thing."""
    hinge_y, top_y = top + 216*s, top + 26*s
    hinge_half, top_half = 168*s, 104*s
    quad = (f"M{n(cx-hinge_half)} {n(hinge_y)} L{n(cx+hinge_half)} {n(hinge_y)} "
            f"L{n(cx+top_half)} {n(top_y)} L{n(cx-top_half)} {n(top_y)} Z")
    return f'''<!-- the display the pane has lifted off, with nothing left to show -->
<rect x="{n(cx-hinge_half-26*s)}" y="{n(top)}" width="{n(2*(hinge_half+26*s))}" height="{n(252*s)}" rx="{n(10*s)}" fill="#14150F" opacity="0.92"/>
<path d="{quad}" fill="url(#pane)"/>
<path d="{quad}" fill="url(#frost)"/>
<path d="M{n(cx-hinge_half)} {n(hinge_y)} L{n(cx+hinge_half)} {n(hinge_y)}" stroke="url(#hinge)" stroke-width="{n(3*s)}" stroke-linecap="round"/>'''

def words(x, y, s=1, rule=421):
    """The wordmark and its lines. `y` is the wordmark's baseline; everything
    else hangs off it, so the block scales as one. `rule` is the divider's
    length, which doesn't scale with the rest: it's set by what sits beside it."""
    # The lines below the wordmark sit 3 units in from it, which reads as
    # aligned: the F's stem has side bearing the smaller sizes don't.
    t = x + 3*s
    return f'''<g font-family="DM Sans, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif">
  <text x="{n(x)}" y="{n(y)}" font-size="{n(70*s)}" font-weight="700" letter-spacing="{n(-1.8*s)}" fill="{SAGE}">FrostFold</text>
  <text x="{n(t)}" y="{n(y+44*s)}" font-size="{n(20*s)}" font-weight="400" fill="{INK}">Glass that follows your hinge.</text>
  <text x="{n(t)}" y="{n(y+82*s)}" font-size="{n(15*s)}" font-weight="400" fill="{INK_SOFT}">Your display tips back behind frosted glass</text>
  <text x="{n(t)}" y="{n(y+104*s)}" font-size="{n(15*s)}" font-weight="400" fill="{INK_SOFT}">as you close the lid.</text>
  <line x1="{n(t)}" y1="{n(y+130*s)}" x2="{n(t+rule)}" y2="{n(y+130*s)}" stroke="{LINE}" stroke-width="1"/>
  <text x="{n(t)}" y="{n(y+156*s)}" font-size="{n(11*s)}" font-weight="700" letter-spacing="{n(1.7*s)}" fill="{CARAMEL}">MACOS 14+ · METAL · OPEN SOURCE</text>
</g>'''

def svg(w, h, body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="{LABEL}">
<title>FrostFold</title>
{defs()}

<rect width="{w}" height="{h}" fill="{BG}"/>

{body}
</svg>
'''

def banner():
    return svg(1280, 360, drawing(1032, 70) + "\n\n" + words(96, 152))

def social():
    # 2:1, and shown small: in a chat client's link preview the card is often
    # under 500 pixels wide, so everything is half again as large as the
    # banner. The outer 80 or so pixels stay clear, because some sites crop the
    # card to 1.91:1 and trim its sides.
    #
    # The display spans the text block: its top on the wordmark's cap height,
    # its foot on the caramel line's baseline. The divider stops well short of
    # it, so the two columns read apart.
    return svg(1280, 640, drawing(938, 170, 1.22) + "\n\n" + words(96, 244, 1.5, rule=520))

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    try:
        shown = path.relative_to(ROOT)
    except ValueError:
        shown = path
    print(f"  wrote {shown}  ({len(text)//1024} KB)")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--social", type=pathlib.Path, metavar="PATH",
                    help="also write the 1280x640 social preview SVG here")
    args = ap.parse_args()
    write(OUT, banner())
    if args.social:
        write(args.social.resolve(), social())
