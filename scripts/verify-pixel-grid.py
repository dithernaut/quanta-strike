#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pixel-grid invariant verifier for quanta-strike.

The family's hard rule: at each strike's native size N, one pixel renders at
the SAME physical size on every strike. That holds iff two things are true:

  1. every strike shares the same "units per grid-pixel"  e = em / N
     → then pixel@native = 128 / e px, identical for every strike.
       (pixel-perfect builds have e = 128 → pixel = 1.000px;
        a uniformly-scaled family has e < 128 → a larger, but still shared, pixel.)

  2. every glyph point + composite reference offset is a multiple of 128
     → glyphs sit exactly on the pixel grid.

Exit status 0 if all strikes agree, 1 if any strike breaks the shared pixel
(so it can be used as a build gate / pre-commit check).

Usage:
  python3 scripts/verify-pixel-grid.py <dir-or-file> [<dir-or-file> ...]

Note: Nerd Font variants are intentionally NOT part of this guarantee (the
patcher may rescale them); point this at the base TTFs / src, not the nerd dir.
"""

import sys
import os
import re
import glob

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded. Install with: brew install fontforge")

PIXEL = 128
NAME_RE = re.compile(r'quanta-strike-(\d+)')

RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
DIM = '\033[2m'
NC = '\033[0m'


def find_fonts(arg):
    if os.path.isfile(arg):
        return [arg] if arg.lower().endswith(('.ttf', '.otf')) else []
    fonts = []
    for ext in ('*.ttf', '*.otf', '*.TTF', '*.OTF'):
        fonts.extend(glob.glob(os.path.join(arg, '**', ext), recursive=True))
    return sorted(set(fonts))


def inspect_font(path):
    """Return dict: N, em, off-grid count (None on parse failure)."""
    m = NAME_RE.search(os.path.basename(path)) or NAME_RE.search(path)
    if not m:
        return {'path': path, 'N': None, 'em': None, 'offgrid': None,
                'reason': 'cannot parse strike number from name'}

    N = int(m.group(1))
    f = fontforge.open(path)
    em = f.em

    offgrid = 0
    scaled_refs = 0
    for g in f.glyphs():
        for c in g.foreground:
            for pt in c:
                if round(pt.x) % PIXEL or round(pt.y) % PIXEL:
                    offgrid += 1
        for ref in g.references:
            tr = ref[1]  # (xx, xy, yx, yy, dx, dy)
            if round(tr[4]) % PIXEL or round(tr[5]) % PIXEL:
                offgrid += 1
            if round(tr[0], 3) != 1 or round(tr[3], 3) != 1:
                scaled_refs += 1
    f.close()

    reason = ''
    if scaled_refs:
        reason = f'{scaled_refs} scaled reference(s)'
    return {'path': path, 'N': N, 'em': em, 'offgrid': offgrid, 'reason': reason}


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit('Usage: scripts/verify-pixel-grid.py <dir-or-file> [<dir-or-file> ...]')

    fonts = []
    for a in args:
        fonts.extend(find_fonts(a))
    fonts = sorted(set(fonts))

    if not fonts:
        print(f'{YELLOW}no fonts found in: {" ".join(args)}{NC}')
        sys.exit(0)

    rows = [inspect_font(p) for p in fonts]

    # Reference pixel = em/N of the first parseable strike; all must match it.
    ref = next((r for r in rows if r['N'] is not None), None)

    print(f"{'font':40s} {'N':>3s} {'em':>5s} {'e=em/N':>7s} {'pixel@N':>8s}  verdict")
    all_ok = True
    for r in rows:
        name = os.path.basename(r['path'])
        if r['N'] is None:
            print(f"{name:40s}  {RED}SKIP  {r['reason']}{NC}")
            all_ok = False
            continue

        e = r['em'] / r['N']
        pixel = PIXEL / e if e else 0.0

        problems = []
        if r['offgrid']:
            problems.append(f"{r['offgrid']} off-grid point(s)/ref(s)")
        if r['reason']:
            problems.append(r['reason'])
        # shared-pixel check: em_i * N_ref == em_ref * N_i  (exact, no float drift)
        if ref is not None and r['em'] * ref['N'] != ref['em'] * r['N']:
            problems.append(f"pixel {pixel:.4f}px != {PIXEL / (ref['em'] / ref['N']):.4f}px (others)")

        ok = not problems
        all_ok = all_ok and ok
        color = GREEN if ok else RED
        verdict = 'OK' if ok else 'FAIL — ' + '; '.join(problems)
        print(f"{name:40s} {r['N']:3d} {r['em']:5d} {e:7.2f} {pixel:7.4f}px  {color}{verdict}{NC}")

    print()
    if all_ok:
        shared = PIXEL / (ref['em'] / ref['N'])
        print(f"{GREEN}✓ pixel-grid invariant holds: every strike renders {shared:.4f}px "
              f"per pixel at its native size{NC}")
        sys.exit(0)
    else:
        print(f"{RED}✗ pixel-grid invariant VIOLATED — the pixel is not shared across strikes{NC}")
        sys.exit(1)


if __name__ == '__main__':
    main()
