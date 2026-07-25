#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Rename a font's family / style naming in place, preserving all other SFNT
name records (copyright, version, license, designer URL, ...).

Usage: fontforge -lang=py -script scripts/rename-family.py <font> <family> <style>
"""
import importlib.util
import os
import sys

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded.")


def _patcher():
    """The metadata patcher, loaded by path (its name has hyphens in it).

    Borrowed for the RIBBI naming rules only, so the weight-name knowledge lives
    in exactly one place instead of being copied here and drifting.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        'font_metadata_patcher', os.path.join(here, 'font-metadata-patcher.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    path   = sys.argv[1]
    family = sys.argv[2]
    style  = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else 'regular'

    psname = f"{family}-{style.replace(' ', '')}"
    human  = f"{family} {style}"

    # Name IDs 1/2 can only hold Regular/Bold/Italic/Bold Italic, so anything
    # else (Light, Black) needs its own legacy family. Same split the patcher
    # applies upstream — this just re-applies it after the Nerd Font rename.
    fmp = _patcher()
    style_info = fmp.style_info_from_name(style)
    legacy_family, legacy_style, pref_family, pref_style = fmp.ribbi_names(family, style_info)
    if style.islower():
        legacy_family, legacy_style = legacy_family.lower(), legacy_style.lower()
        pref_family, pref_style = pref_family.lower(), pref_style.lower()

    f = fontforge.open(path)
    f.familyname = family
    f.fontname   = psname
    f.fullname   = human

    # Override only the naming records; keep everything else (copyright/version/etc.)
    override = {
        'Family':           legacy_family,
        'SubFamily':        legacy_style,
        'Fullname':         human,
        'PostScriptName':   psname,
        'Preferred Family': pref_family,
        'Preferred Styles': pref_style,
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
