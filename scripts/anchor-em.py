#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
anchor-em.py — anchor each strike's em to N x 128 (pixel-perfect) and set the
line metrics to the full ink extent, so accents drawn ABOVE the em never clip.

Use this when you draw a strike on a slightly TALLER canvas (e.g. 17 rows for
the 16) so the accents get real room: the extra row(s) hang above the em.

  em      = N * 128                     -> pixel-perfect: 1px at font-size N
  descent = measured descender depth (snapped up to a whole pixel)
  ascent  = N*128 - descent             -> em top; accents above it overshoot
  win / typo / hhea = full ink extent   -> tight line spacing, no clipping
  use_typo_metrics = True
  glyph outlines untouched              -> 1 pixel stays 128 units

Whatever em the source exports (N*128 already, or the taller canvas height), this
re-anchors it to N*128 and captures the overshoot in the line metrics.

Usage:
  python3 scripts/anchor-em.py <dir>
"""

import sys
import os
import re
import glob
import math

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded. Install with: brew install fontforge")

PIXEL = 128
NAME_RE = re.compile(r'quanta-strike-(\d+)')

GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
RED = '\033[0;31m'
DIM = '\033[2m'
NC = '\033[0m'


def ink_extent(font):
    """Highest / lowest inked point across every drawn glyph (accents included)."""
    top = None
    bot = None
    for g in font.glyphs():
        if not g.isWorthOutputting():
            continue
        bb = g.boundingBox()
        if bb == (0, 0, 0, 0):
            continue
        top = bb[3] if top is None else max(top, bb[3])
        bot = bb[1] if bot is None else min(bot, bb[1])
    return top, bot


def anchor(path):
    m = NAME_RE.search(os.path.basename(path)) or NAME_RE.search(path)
    if not m:
        print(f"  {YELLOW}skip{NC} (no strike number): {os.path.basename(path)}")
        return False

    N = int(m.group(1))
    f = fontforge.open(path)
    old_em = f.em

    ink_top, ink_bot = ink_extent(f)
    if ink_top is None:
        ink_top, ink_bot = f.ascent, -f.descent

    new_em = N * PIXEL

    # em descent = descender depth, snapped up to a whole pixel so the em bottom
    # sits on the grid and covers the deepest descender.
    descent = int(math.ceil(max(0, -ink_bot) / PIXEL)) * PIXEL
    if descent >= new_em:
        descent = new_em - PIXEL  # safety for pathological input
    ascent = new_em - descent

    # full ink extent -> line metrics (clip safety + line spacing)
    line_asc = max(int(round(ink_top)), ascent)   # covers accent overshoot
    line_desc = max(int(math.ceil(max(0, -ink_bot))), descent)

    f.os2_winascent = line_asc
    f.os2_windescent = line_desc
    f.os2_typoascent = line_asc
    f.os2_typodescent = -line_desc
    f.os2_typolinegap = 0
    f.hhea_ascent = line_asc
    f.hhea_descent = -line_desc
    f.hhea_linegap = 0

    # em = N*128 (pixel-perfect). Glyphs are untouched; accents above `ascent`
    # simply hang above the em.
    f.ascent = ascent
    f.descent = descent
    f.os2_use_typo_metrics = True

    f.generate(path, flags=('opentype', 'PfEd-comments', 'no-FFTM-table'))

    overshoot = max(0, line_asc - ascent)
    f.close()

    print(f"  {os.path.basename(path):34s} N={N:2d}  em {old_em}->{new_em}  "
          f"ascent={ascent} descent={descent}  line={line_asc}/{line_desc} "
          f"(overshoot {overshoot}u={overshoot / PIXEL:.2f}px)  pixel=1.0000px")
    return True


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: scripts/anchor-em.py <dir>")
    d = sys.argv[1]
    fonts = sorted(glob.glob(os.path.join(d, '**', '*.ttf'), recursive=True))
    if not fonts:
        sys.exit(f"{RED}no .ttf files found in {d}{NC}")

    print("anchor-em: em = N*128 (pixel-perfect), line metrics = full ink extent")
    n = 0
    for p in fonts:
        if anchor(p):
            n += 1
    print(f"\n{GREEN}✓ anchored {n} strike(s); em = N*128, pixel = 1.0000px, "
          f"accent overshoot captured in line metrics{NC}")


if __name__ == '__main__':
    main()
