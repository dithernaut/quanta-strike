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

Metrics are computed per FAMILY, not per file: all weights of a strike (regular,
bold, ...) are anchored to the union of their ink, so bolding a run of text can
never move the baseline or grow the line box.

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


def strike_of(path):
    """The strike number N from the filename, or None if this isn't a strike."""
    m = NAME_RE.search(os.path.basename(path)) or NAME_RE.search(path)
    return int(m.group(1)) if m else None


def measure(path):
    """(family, ink_top, ink_bot) for one font — the inputs to the metric math."""
    f = fontforge.open(path)
    top, bot = ink_extent(f)
    if top is None:
        top, bot = f.ascent, -f.descent
    # Group by the PREFERRED family (name ID 16). Weights that don't fit the four
    # legacy style slots carry their OWN Family (ID 1) — "quanta-strike-12 light" —
    # and FontForge mirrors that into familyname, so keying on familyname would
    # split Light into a group of one and hand it its own metrics.
    names = {key: value for _, key, value in f.sfnt_names}
    family = names.get('Preferred Family') or f.familyname or os.path.basename(path)
    f.close()
    return family, top, bot


def anchor(path, N, ink_top, ink_bot):
    f = fontforge.open(path)
    old_em = f.em

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

    # Measure first, then anchor — because every weight of a strike has to come
    # out with the SAME metrics. Bold usually has taller accents and deeper
    # descenders than regular; metrics derived per file would move the baseline
    # and the line box the moment a run of text is bolded. So the whole family
    # is anchored to the union of its ink.
    groups = {}
    for p in fonts:
        N = strike_of(p)
        if N is None:
            print(f"  {YELLOW}skip{NC} (no strike number): {os.path.basename(p)}")
            continue
        family, top, bot = measure(p)
        key = (N, family)
        if key in groups:
            prev_top, prev_bot, members = groups[key]
            groups[key] = (max(prev_top, top), min(prev_bot, bot), members + [p])
        else:
            groups[key] = (top, bot, [p])

    n = 0
    for (N, family), (top, bot, members) in sorted(groups.items()):
        if len(members) > 1:
            print(f"  {DIM}{family}: {len(members)} styles share one set of metrics{NC}")
        for p in members:
            if anchor(p, N, top, bot):
                n += 1
    print(f"\n{GREEN}✓ anchored {n} strike(s); em = N*128, pixel = 1.0000px, "
          f"accent overshoot captured in line metrics{NC}")


if __name__ == '__main__':
    main()
