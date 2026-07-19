#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Old-Style Figures Feature Adder

Adds the OpenType `onum` (oldstyle numerals) GSUB feature to font files,
mapping lining digits 0–9 to alternate figure glyphs.

Four glyph sources:
  circled     — ⓿①②③④⑤⑥⑦⑧⑨  (U+24FF, U+2460–U+2468)  [default]
  superscript — ⁰¹²³⁴⁵⁶⁷⁸⁹  (U+2070, U+00B9/B2/B3, U+2074–U+2079)
  subscript   — ₀₁₂₃₄₅₆₇₈₉  (U+2080–U+2089)
  lining      — 0123456789    (identity placeholder)
"""

import sys
import logging
import argparse
from pathlib import Path

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded. Install with: brew install fontforge")

# ---------------------------------------------------------------------------
# Digit maps
# ---------------------------------------------------------------------------

# ⓿ is the *negative* (filled) circled zero to match the style of ①–⑨
CIRCLED = {
    '0': 0x24FF,  # ⓿ NEGATIVE CIRCLED DIGIT ZERO
    '1': 0x2460,  # ① CIRCLED DIGIT ONE
    '2': 0x2461,  # ② CIRCLED DIGIT TWO
    '3': 0x2462,  # ③ CIRCLED DIGIT THREE
    '4': 0x2463,  # ④ CIRCLED DIGIT FOUR
    '5': 0x2464,  # ⑤ CIRCLED DIGIT FIVE
    '6': 0x2465,  # ⑥ CIRCLED DIGIT SIX
    '7': 0x2466,  # ⑦ CIRCLED DIGIT SEVEN
    '8': 0x2467,  # ⑧ CIRCLED DIGIT EIGHT
    '9': 0x2468,  # ⑨ CIRCLED DIGIT NINE
}

SUPERSCRIPT = {
    '0': 0x2070,  # ⁰ SUPERSCRIPT ZERO
    '1': 0x00B9,  # ¹ SUPERSCRIPT ONE
    '2': 0x00B2,  # ² SUPERSCRIPT TWO
    '3': 0x00B3,  # ³ SUPERSCRIPT THREE
    '4': 0x2074,  # ⁴ SUPERSCRIPT FOUR
    '5': 0x2075,  # ⁵ SUPERSCRIPT FIVE
    '6': 0x2076,  # ⁶ SUPERSCRIPT SIX
    '7': 0x2077,  # ⁷ SUPERSCRIPT SEVEN
    '8': 0x2078,  # ⁸ SUPERSCRIPT EIGHT
    '9': 0x2079,  # ⁹ SUPERSCRIPT NINE
}

SUBSCRIPT = {
    '0': 0x2080,  # ₀ SUBSCRIPT ZERO
    '1': 0x2081,  # ₁ SUBSCRIPT ONE
    '2': 0x2082,  # ₂ SUBSCRIPT TWO
    '3': 0x2083,  # ₃ SUBSCRIPT THREE
    '4': 0x2084,  # ₄ SUBSCRIPT FOUR
    '5': 0x2085,  # ₅ SUBSCRIPT FIVE
    '6': 0x2086,  # ₆ SUBSCRIPT SIX
    '7': 0x2087,  # ₇ SUBSCRIPT SEVEN
    '8': 0x2088,  # ₈ SUBSCRIPT EIGHT
    '9': 0x2089,  # ₉ SUBSCRIPT NINE
}

SOURCE_MAPS = {
    'circled':     CIRCLED,
    'superscript': SUPERSCRIPT,
    'subscript':   SUBSCRIPT,
}

DIGITS = list('0123456789')

RED    = '\033[0;31m'
GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE   = '\033[0;34m'
CYAN   = '\033[0;36m'
DIM    = '\033[2m'
NC     = '\033[0m'


# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------

def ask_choice(question, choices, default=None):
    styled = '/'.join(c.upper() if c == default else c for c in choices)
    while True:
        raw = input(f'{YELLOW}?{NC} {question} [{styled}]: ').strip().lower()
        if not raw and default:
            return default
        if raw in choices:
            return raw
        print(f'  Please enter one of: {", ".join(choices)}')


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logger(debug=False):
    logger = logging.getLogger('old-style-figures')
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    h = logging.StreamHandler()
    h.setFormatter(logging.Formatter('%(levelname)s: %(message)s'))
    logger.addHandler(h)
    return logger


# ---------------------------------------------------------------------------
# FontForge helpers
# ---------------------------------------------------------------------------

def glyph_exists(font, codepoint):
    try:
        g = font[codepoint]
        return g is not None and g.isWorthOutputting()
    except (TypeError, KeyError):
        return False


def get_glyph_name(font, codepoint):
    try:
        g = font[codepoint]
        if g is not None:
            return g.glyphname
    except (TypeError, KeyError):
        pass
    return None


# ---------------------------------------------------------------------------
# GSUB
# ---------------------------------------------------------------------------

def add_gsub_single(font, lookup_name, subtable_name, feature_tag, subs, logger):
    if not subs:
        return 0
    try:
        font.removeLookup(lookup_name)
    except Exception:
        pass
    font.addLookup(
        lookup_name,
        'gsub_single',
        (),
        [(feature_tag, [('latn', ('dflt',))])]
    )
    font.addLookupSubtable(lookup_name, subtable_name)
    count = 0
    for src, dst in subs.items():
        try:
            font[src].addPosSub(subtable_name, dst)
            count += 1
        except Exception as e:
            logger.warning(f'{feature_tag}: could not add {src} → {dst}: {e}')
    return count


# ---------------------------------------------------------------------------
# Per-font processing
# ---------------------------------------------------------------------------

def process_font(font_path, output_path, source, logger):
    font = fontforge.open(str(font_path))

    onum_subs = {}

    for digit in DIGITS:
        lining_name = get_glyph_name(font, ord(digit))
        if not lining_name:
            print(f'  {DIM}{digit} → (no lining glyph, skipped){NC}')
            continue

        if source == 'lining':
            print(f'  {DIM}{digit} → {lining_name} (identity){NC}')
            continue

        target_cp   = SOURCE_MAPS[source][digit]
        target_name = get_glyph_name(font, target_cp)

        if not target_name:
            print(f'  {DIM}{digit} → U+{target_cp:04X} (glyph not in font, skipped){NC}')
            continue

        print(f'  {digit} → {target_name}')
        onum_subs[lining_name] = target_name

    n = add_gsub_single(font, 'onum_lookup', 'onum_subtable', 'onum', onum_subs, logger)
    logger.info(f'onum: {n} substitutions')

    output_path.parent.mkdir(parents=True, exist_ok=True)
    font.generate(str(output_path), flags=('opentype', 'PfEd-comments', 'no-FFTM-table'))
    font.close()
    logger.info(f'Written: {output_path}')


# ---------------------------------------------------------------------------
# Font discovery
# ---------------------------------------------------------------------------

def find_fonts(path, family_filter=None):
    p = Path(path)
    if p.is_file():
        return [p] if p.suffix.lower() in ('.ttf', '.otf') else []
    fonts = []
    for ext in ('*.ttf', '*.otf', '*.TTF', '*.OTF'):
        fonts.extend(p.rglob(ext))
    fonts = sorted(set(fonts))
    if family_filter:
        fonts = [f for f in fonts if family_filter.lower() in f.stem.lower()]
    return fonts


# ---------------------------------------------------------------------------
# Interactive prompt
# ---------------------------------------------------------------------------

def interactive_prompt():
    print(f'\n{CYAN}╔══════════════════════════════════════════════════╗')
    print(f'║        Old-Style Figures Feature Adder          ║')
    print(f'║               quanta-strike                    ║')
    print(f'╚══════════════════════════════════════════════════╝{NC}\n')

    print('Choose the glyph source for old-style figures (onum):\n')
    print(f'  {CYAN}circled{NC}     — ⓿①②③④⑤⑥⑦⑧⑨  (U+24FF, U+2460–U+2468)')
    print(f'  {CYAN}superscript{NC} — ⁰¹²³⁴⁵⁶⁷⁸⁹  (U+2070, U+00B9/B2/B3, U+2074–U+2079)')
    print(f'  {CYAN}subscript{NC}   — ₀₁₂₃₄₅₆₇₈₉  (U+2080–U+2089)')
    print(f'  {CYAN}lining{NC}      — same as regular digits (identity placeholder)')
    print()

    return ask_choice('Source', ['circled', 'superscript', 'subscript', 'lining'], default='circled')


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Add OpenType onum old-style figures feature to fonts',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  python3 scripts/add-old-style-figures.py
  python3 scripts/add-old-style-figures.py --source circled --family picosans
  python3 scripts/add-old-style-figures.py --src build/picotype --output build/picotype-osf
        '''.strip()
    )
    parser.add_argument('--src', '-s', default='build',
                        help='Source font file or directory (default: build)')
    parser.add_argument('--output', '-o', default=None,
                        help='Output file or directory (default: overwrite in-place)')
    parser.add_argument('--family', help='Process only fonts whose filename contains this string')
    parser.add_argument('--source', choices=['circled', 'superscript', 'subscript', 'lining'],
                        help='Figure source (omit to use interactive prompt)')
    parser.add_argument('--debug', action='store_true')
    args = parser.parse_args()

    logger = setup_logger(args.debug)

    font_paths = find_fonts(args.src, args.family)
    if not font_paths:
        logger.error(f'No font files found in: {args.src}')
        sys.exit(1)

    print(f'\n{BLUE}ℹ{NC} Found {len(font_paths)} font file(s):')
    for p in font_paths:
        print(f'  • {p}')

    source = args.source if args.source else interactive_prompt()

    src_base = Path(args.src)
    out_base = Path(args.output) if args.output else None

    errors = 0
    for font_path in font_paths:
        if out_base:
            if out_base.suffix:
                output_path = out_base
            else:
                try:
                    rel = font_path.relative_to(src_base)
                    output_path = out_base / rel
                except ValueError:
                    output_path = out_base / font_path.name
        else:
            output_path = font_path

        print(f'\n{CYAN}▶{NC} {font_path.name}')
        try:
            process_font(font_path, output_path, source, logger)
            print(f'{GREEN}✓{NC} {output_path}')
        except Exception as e:
            print(f'{RED}✗{NC} {font_path.name}: {e}')
            errors += 1
            if args.debug:
                raise

    print()
    if errors:
        print(f'{RED}✗{NC} Completed with {errors} error(s).')
        sys.exit(1)
    else:
        print(f'{GREEN}✓{NC} All fonts processed.')


if __name__ == '__main__':
    main()
