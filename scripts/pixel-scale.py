#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pixel-scale.py — uniformly enlarge a quanta-strike family while keeping the
pixel size EXACTLY identical across every strike.

It shrinks every strike's em by the SAME factor, so at each strike's native
size N the pixel renders a little larger — but by the same amount on all
strikes — and sets the line metrics to the full ink extent (diacritics
included) so the overshooting accents never clip.

Glyph outlines are NEVER rescaled (1 pixel stays 128 units), so this is
reversible and the pixel stays perfectly constant across the family.

Mechanism (this is picotype's `--tighten` / apply_line_metrics, but driven by
one shared factor instead of per-font body bounds):

    e         = round(128 / scale)      # em units per grid-pixel, shared by all
    new_em(N) = e * N                   # integer for every strike
    pixel@N   = 128 / e  px             # IDENTICAL on every strike, exactly
    em        <- body (uniform)         # -> glyphs render bigger
    typo/hhea <- full ink extent        # -> tight line spacing, no clipping
    win       <- max extent             # -> clipping safety
    use_typo_metrics = True

    scale 1.0    -> e = 128 -> pixel 1.000px   (pixel-perfect, no size change)
    scale 8/7    -> e = 112 -> pixel 1.143px   (small strikes ~ Helvetica)

Usage:
  python3 scripts/pixel-scale.py <dir> [--scale S]     # default S = 8/7 ~= 1.143
"""

import sys
import os
import re
import glob
import argparse

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


def full_ink_extent(font):
    """Max top / min bottom across every drawn glyph (diacritics included)."""
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
    if top is None:
        top = font.ascent
    if bot is None:
        bot = -font.descent
    return top, bot


def scale_font(path, e):
    m = NAME_RE.search(os.path.basename(path)) or NAME_RE.search(path)
    if not m:
        print(f"  {YELLOW}skip{NC} (no strike number): {os.path.basename(path)}")
        return False

    N = int(m.group(1))
    f = fontforge.open(path)

    old_em = f.em
    asc_o, desc_o = f.ascent, f.descent

    new_em = e * N
    # split the new em in the same proportion as the original ascent/descent
    new_ascent = round(asc_o * new_em / old_em)
    new_descent = new_em - new_ascent

    # full ink extent (incl. diacritics) drives line spacing + clip safety
    full_top, full_bot = full_ink_extent(f)
    full_asc = int(round(full_top))
    full_desc = int(round(-full_bot))

    # line metrics = full extent (picotype apply_line_metrics)
    f.os2_winascent = max(f.os2_winascent, full_asc)
    f.os2_windescent = max(f.os2_windescent, full_desc)
    f.os2_typoascent = full_asc
    f.os2_typodescent = -full_desc
    f.os2_typolinegap = 0
    f.hhea_ascent = full_asc
    f.hhea_descent = -full_desc
    f.hhea_linegap = 0

    # em = uniform body -> glyphs render bigger; pixel = 128/e on every strike
    f.ascent = new_ascent
    f.descent = new_descent
    f.os2_use_typo_metrics = True

    f.generate(path, flags=('opentype', 'PfEd-comments', 'no-FFTM-table'))
    px = PIXEL / e
    line = (full_asc + full_desc) / new_em
    f.close()

    print(f"  {os.path.basename(path):34s} N={N:2d}  em {old_em}->{new_em}  "
          f"pixel={px:.4f}px  line-height={line:.3f}em")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dir', help='directory of quanta-strike TTFs to scale in place')
    ap.add_argument('--scale', type=float, default=8.0 / 7.0,
                    help='enlargement factor (default 8/7 ~= 1.143). 1.0 = pixel-perfect.')
    args = ap.parse_args()

    if args.scale < 1.0:
        sys.exit(f"{RED}--scale must be >= 1.0 (1.0 = no change, larger = bigger){NC}")

    e = round(PIXEL / args.scale)
    e = max(1, min(PIXEL, e))
    px = PIXEL / e

    print(f"pixel-scale: scale~{args.scale:.4f}  ->  e={e} units/pixel  ->  "
          f"pixel = {px:.4f}px {DIM}(identical on every strike){NC}")
    if e == PIXEL:
        print(f"  {YELLOW}note: e=128 -> this is pixel-perfect (no size change).{NC}")

    fonts = sorted(glob.glob(os.path.join(args.dir, '**', '*.ttf'), recursive=True))
    if not fonts:
        sys.exit(f"{RED}no .ttf files found in {args.dir}{NC}")

    n = 0
    for p in fonts:
        if scale_font(p, e):
            n += 1

    print(f"\n{GREEN}✓ scaled {n} strike(s); pixel is now {px:.4f}px family-wide, "
          f"identical across all strikes{NC}")


if __name__ == '__main__':
    main()
