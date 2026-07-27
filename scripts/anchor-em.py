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
  underline / strikeout = whole pixels  -> see decorate()
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


def rule_thickness(N):
    """Underline / strikeout stroke thickness in whole pixels for strike N.

    One pixel up to the 20, two from the 24 on, three from the 40 — the stroke
    stays ~1/16 of the em, so it reads the same weight at every strike.
    """
    return max(1, (N + 8) // 16)


def x_height(font):
    """Top of 'x' in em units, or None when the strike doesn't draw one.

    Measured off the outline rather than read from OS/2, because FontForge only
    fills that field in on generate — after this script has already run.
    """
    try:
        g = font['x']
    except (TypeError, KeyError):
        return None
    bb = g.boundingBox()
    if bb == (0, 0, 0, 0):
        return None
    return bb[3]


def underline_gap(thick_px, descent_px):
    """Clear pixel rows between the baseline and the top of the underline.

    The air grows with the stroke — 1px under a 1px rule, 3px under the 2px rule
    on the 32 — so the underline hangs away from the baseline by the same
    proportion at every strike instead of crowding it on the big ones.

    Bounded by what the descender depth can actually hold, because the rule has
    to stay inside the em: the emitted line-height is 1, so the first row below
    the em belongs to the NEXT line, and a stroke there lands on its ascenders.
    That bound is what pins the 6 — a 1px descender leaves no room for air, so
    the gap closes to nothing and the stroke shares the descender row, where
    skip-ink cuts it around the descenders.
    """
    return max(0, min(2 * thick_px - 1, descent_px - thick_px))


def decorate(f, N, descent):
    """Snap the underline and strikeout to the pixel grid.

    On disk both position fields hold the TOP of the stroke: post
    underlinePosition (negative below the baseline) and OS/2 yStrikeoutPosition.
    FontForge's `upos` is the stroke's CENTER and it writes
    top = upos + uwidth / 2, so the underline center sits half a stroke lower
    than the top being aimed for. `os2_strikeypos` is written through verbatim.

    Underline: a stroke of air under the baseline where the descender depth can
    hold it — see underline_gap() — then the stroke.
    Strikeout: bottom on the half x-height, so the stroke crosses the lowercase
    a touch above centre. Chromium ignores yStrikeoutPosition and centres the
    line on half the x-height itself, so this only lands for Firefox and for
    apps that read the font (Word, InDesign, PDF).

    Returns (underline_top_px, strikeout_top_px, thickness_px) for the log line.
    """
    thick_px = rule_thickness(N)
    thick = thick_px * PIXEL

    gap = underline_gap(thick_px, descent // PIXEL) * PIXEL
    f.uwidth = thick
    f.upos = -gap - thick // 2

    xh = x_height(f)
    xh_px = int(round(xh / PIXEL)) if xh else int(round(f.ascent / PIXEL)) // 2
    strike_top_px = xh_px // 2 + thick_px

    f.os2_strikeysize = thick
    f.os2_strikeypos = strike_top_px * PIXEL

    return -(gap // PIXEL), strike_top_px, thick_px


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

    under_px, strike_px, rule_px = decorate(f, N, descent)

    f.generate(path, flags=('opentype', 'PfEd-comments', 'no-FFTM-table'))

    overshoot = max(0, line_asc - ascent)
    f.close()

    print(f"  {os.path.basename(path):34s} N={N:2d}  em {old_em}->{new_em}  "
          f"ascent={ascent} descent={descent}  line={line_asc}/{line_desc} "
          f"(overshoot {overshoot}u={overshoot / PIXEL:.2f}px)  pixel=1.0000px  "
          f"rule={rule_px}px under@{under_px}px strike@{strike_px}px")
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
