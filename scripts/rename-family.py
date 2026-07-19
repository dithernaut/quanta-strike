#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Rename a font's family / style naming in place, preserving all other SFNT
name records (copyright, version, license, designer URL, ...).

Usage: fontforge -lang=py -script scripts/rename-family.py <font> <family> <style>
"""
import sys

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded.")


def main():
    path   = sys.argv[1]
    family = sys.argv[2]
    style  = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else 'regular'

    psname = f"{family}-{style.replace(' ', '')}"
    human  = f"{family} {style}"

    f = fontforge.open(path)
    f.familyname = family
    f.fontname   = psname
    f.fullname   = human

    # Override only the naming records; keep everything else (copyright/version/etc.)
    override = {
        'Family':           family,
        'SubFamily':        style,
        'Fullname':         human,
        'PostScriptName':   psname,
        'Preferred Family': family,
        'Preferred Styles': style,
        'Compatible Full':  human,
        'UniqueID':         psname,
    }
    kept = [(lang, key, val) for (lang, key, val) in f.sfnt_names if key not in override]
    f.sfnt_names = tuple(kept)
    for key, val in override.items():
        f.appendSFNTName('English (US)', key, val)

    f.generate(path, flags=('opentype', 'PfEd-comments', 'no-FFTM-table'))
    f.close()


if __name__ == '__main__':
    main()
