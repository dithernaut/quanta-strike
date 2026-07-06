#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Small Caps Feature Adder

Adds OpenType smcp (lowercase → small caps) and c2sc (uppercase → small caps)
GSUB features to font files.

Three glyph sources are supported:
  phonetic  — Unicode "Latin Letter Small Capital" characters (e.g. ɢ U+0262 for G)
  lowercase — use the existing lowercase glyph as the small cap
  capital   — use the existing uppercase glyph as the small cap

Fallback order when source is 'phonetic': phonetic → lowercase → capital
"""

import argparse
import logging
import os
import sys
from pathlib import Path

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded. Install with: brew install fontforge")

# ---------------------------------------------------------------------------
# Unicode codepoints for "Latin Letter Small Capital" characters
# Sources: IPA Extensions (U+0250–U+02AF), Phonetic Extensions (U+1D00–U+1D7F),
#          Latin Extended-D (U+A720–U+A7FF)
# x has no standard Unicode small-capital equivalent
# ---------------------------------------------------------------------------
PHONETIC_SMALL_CAPS = {
    'a': 0x1D00,  # ᴀ LATIN LETTER SMALL CAPITAL A
    'b': 0x0299,  # ʙ LATIN LETTER SMALL CAPITAL B
    'c': 0x1D04,  # ᴄ LATIN LETTER SMALL CAPITAL C
    'd': 0x1D05,  # ᴅ LATIN LETTER SMALL CAPITAL D
    'e': 0x1D07,  # ᴇ LATIN LETTER SMALL CAPITAL E
    'f': 0xA730,  # ꜰ LATIN LETTER SMALL CAPITAL F
    'g': 0x0262,  # ɢ LATIN LETTER SMALL CAPITAL G
    'h': 0x029C,  # ʜ LATIN LETTER SMALL CAPITAL H
    'i': 0x026A,  # ɪ LATIN LETTER SMALL CAPITAL I
    'j': 0x1D0A,  # ᴊ LATIN LETTER SMALL CAPITAL J
    'k': 0x1D0B,  # ᴋ LATIN LETTER SMALL CAPITAL K
    'l': 0x029F,  # ʟ LATIN LETTER SMALL CAPITAL L
    'm': 0x1D0D,  # ᴍ LATIN LETTER SMALL CAPITAL M
    'n': 0x0274,  # ɴ LATIN LETTER SMALL CAPITAL N
    'o': 0x1D0F,  # ᴏ LATIN LETTER SMALL CAPITAL O
    'p': 0x1D18,  # ᴘ LATIN LETTER SMALL CAPITAL P
    'q': 0xA7AF,  # ꞯ LATIN LETTER SMALL CAPITAL Q
    'r': 0x0280,  # ʀ LATIN LETTER SMALL CAPITAL R
    's': 0xA731,  # ꜱ LATIN LETTER SMALL CAPITAL S
    't': 0x1D1B,  # ᴛ LATIN LETTER SMALL CAPITAL T
    'u': 0x1D1C,  # ᴜ LATIN LETTER SMALL CAPITAL U
    'v': 0x1D20,  # ᴠ LATIN LETTER SMALL CAPITAL V
    'w': 0x1D21,  # ᴡ LATIN LETTER SMALL CAPITAL W
    # x: no standard Unicode small cap
    'y': 0x028F,  # ʏ LATIN LETTER SMALL CAPITAL Y
    'z': 0x1D22,  # ᴢ LATIN LETTER SMALL CAPITAL Z
}

LETTERS = list('abcdefghijklmnopqrstuvwxyz')

# ANSI colours
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

def ask_yn(question, default='y'):
    prompt = '[Y/n]' if default == 'y' else '[y/N]'
    raw = input(f'{YELLOW}?{NC} {question} {prompt}: ').strip().lower()
    if not raw:
        return default == 'y'
    return raw in ('y', 'yes')


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
    logger = logging.getLogger('small-caps')
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    h = logging.StreamHandler()
    h.setFormatter(logging.Formatter('%(levelname)s: %(message)s'))
    logger.addHandler(h)
    return logger


# ---------------------------------------------------------------------------
# FontForge helpers
# ---------------------------------------------------------------------------

def glyph_exists(font, codepoint):
    """Return True if the font contains a drawable glyph at the given Unicode codepoint."""
    try:
        g = font[codepoint]
        return g is not None and g.isWorthOutputting()
    except (TypeError, KeyError):
        return False


def get_glyph_name(font, codepoint):
    """Return the glyph name for a codepoint, or None."""
    try:
        g = font[codepoint]
        if g is not None:
            return g.glyphname
    except (TypeError, KeyError):
        pass
    return None


def copy_glyph(font, src_cp, dst_cp, logger):
    """
    Duplicate the glyph at src_cp into the slot for dst_cp (creating it if needed).
    Returns the new glyph name, or None on failure.
    """
    try:
        src_name = get_glyph_name(font, src_cp)
        if not src_name:
            return None

        font.selection.none()
        font.selection.select(src_name)
        font.copy()

        # Create destination slot if absent
        try:
            dst_glyph = font[dst_cp]
        except (KeyError, TypeError):
            try:
                dst_name = fontforge.nameFromUnicode(dst_cp)
            except Exception:
                dst_name = f'uni{dst_cp:04X}'
            dst_glyph = font.createChar(dst_cp, dst_name)

        font.selection.none()
        font.selection.select(dst_glyph.glyphname)
        font.paste()

        # Carry over advance width
        font[dst_cp].width = font[src_cp].width

        return font[dst_cp].glyphname

    except Exception as e:
        logger.warning(f'Could not copy U+{src_cp:04X} → U+{dst_cp:04X}: {e}')
        return None


# ---------------------------------------------------------------------------
# Small-cap resolution
# ---------------------------------------------------------------------------

def resolve_small_cap(font, letter, source, populate_phonetic, logger):
    """
    Return (glyph_name, was_newly_created) for the best small-cap representation
    of `letter` given `source`.

    Fallback when source='phonetic': phonetic slot → lowercase → capital
    Fallback when source='lowercase':                 lowercase → capital
    Fallback when source='capital':                   capital   → lowercase
    """
    lower_cp    = ord(letter)
    upper_cp    = ord(letter.upper())
    phonetic_cp = PHONETIC_SMALL_CAPS.get(letter)

    if source == 'phonetic':
        if phonetic_cp:
            if glyph_exists(font, phonetic_cp):
                return get_glyph_name(font, phonetic_cp), False

            if populate_phonetic:
                # Copy from best available fallback into the phonetic slot
                fallback_cp = None
                if glyph_exists(font, lower_cp):
                    fallback_cp = lower_cp
                elif glyph_exists(font, upper_cp):
                    fallback_cp = upper_cp

                if fallback_cp is not None:
                    name = copy_glyph(font, fallback_cp, phonetic_cp, logger)
                    if name:
                        return name, True

        # Phonetic unavailable or no codepoint (q, x) — fall through
        if glyph_exists(font, lower_cp):
            return get_glyph_name(font, lower_cp), False
        if glyph_exists(font, upper_cp):
            return get_glyph_name(font, upper_cp), False

    elif source == 'lowercase':
        if glyph_exists(font, lower_cp):
            return get_glyph_name(font, lower_cp), False
        if glyph_exists(font, upper_cp):
            return get_glyph_name(font, upper_cp), False

    elif source == 'capital':
        if glyph_exists(font, upper_cp):
            return get_glyph_name(font, upper_cp), False
        if glyph_exists(font, lower_cp):
            return get_glyph_name(font, lower_cp), False

    return None, False


# ---------------------------------------------------------------------------
# OpenType GSUB
# ---------------------------------------------------------------------------

def add_gsub_single(font, lookup_name, subtable_name, feature_tag, subs, logger):
    """Create (or replace) a GSUB single-substitution lookup for the given feature."""
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

def process_font(font_path, output_path, source, populate_phonetic, add_c2sc, logger):
    """Open a font, add small-caps features, and write to output_path."""
    font = fontforge.open(str(font_path))

    smcp_subs = {}  # lowercase glyph  → small-cap target
    c2sc_subs = {}  # uppercase glyph  → small-cap target
    rows = []

    for letter in LETTERS:
        lower_name = get_glyph_name(font, ord(letter))
        upper_name = get_glyph_name(font, ord(letter.upper()))

        target, created = resolve_small_cap(font, letter, source, populate_phonetic, logger)

        if not target:
            rows.append(f'  {DIM}{letter}/{letter.upper()} → (skipped — no glyph available){NC}')
            continue

        tag = f' {CYAN}[new]{NC}' if created else ''
        rows.append(f'  {letter}/{letter.upper()} → {target}{tag}')

        if lower_name and lower_name != target:
            smcp_subs[lower_name] = target
        if add_c2sc and upper_name and upper_name != target:
            c2sc_subs[upper_name] = target

    for row in rows:
        print(row)

    n_smcp = add_gsub_single(font, 'smcp_lookup', 'smcp_subtable', 'smcp', smcp_subs, logger)
    n_c2sc = add_gsub_single(font, 'c2sc_lookup', 'c2sc_subtable', 'c2sc', c2sc_subs, logger) if add_c2sc else 0

    logger.info(
        f'smcp: {n_smcp} substitutions'
        + (f', c2sc: {n_c2sc} substitutions' if add_c2sc else '')
    )

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
    print(f'║           Small Caps Feature Adder              ║')
    print(f'║               quanta-strike                    ║')
    print(f'╚══════════════════════════════════════════════════╝{NC}\n')

    print('Choose the glyph source for small capitals:\n')
    print(f'  {CYAN}phonetic{NC}  — Unicode "Latin Letter Small Capital" characters')
    print(f'            (e.g. ɢ U+0262 for G, ᴀ U+1D00 for A)')
    print(f'            If the phonetic glyph is missing, it will be copied from')
    print(f'            the existing lowercase (then uppercase) glyph.')
    print(f'  {CYAN}lowercase{NC} — use the existing lowercase glyph as-is')
    print(f'  {CYAN}capital{NC}   — use the existing uppercase glyph as-is')
    print()

    source = ask_choice('Source', ['phonetic', 'lowercase', 'capital'], default='phonetic')

    populate_phonetic = False
    if source == 'phonetic':
        print()
        print('When a phonetic small-cap slot is missing from the font, the script')
        print('can copy the fallback glyph into that Unicode codepoint so the')
        print('character is also directly accessible (e.g. typing ɢ gives the glyph).')
        populate_phonetic = ask_yn(
            'Populate missing phonetic slots by copying from fallback?',
            default='y'
        )

    print()
    add_c2sc = ask_yn(
        'Also add c2sc feature (uppercase letters → small caps, in addition to smcp)?',
        default='y'
    )

    return source, populate_phonetic, add_c2sc


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Add OpenType smcp/c2sc small-caps features to fonts',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  # Interactive — processes all fonts in build/
  python3 add-small-caps.py

  # Non-interactive — capitals as small caps, single family
  python3 add-small-caps.py --source capital --family picosans

  # Output to a separate directory instead of overwriting
  python3 add-small-caps.py --src build/picotype --output build/picotype-sc
        '''.strip()
    )
    parser.add_argument('--src', '-s', default='build',
                        help='Source font file or directory (default: build)')
    parser.add_argument('--output', '-o', default=None,
                        help='Output file or directory (default: overwrite source in-place)')
    parser.add_argument('--family', help='Process only fonts whose filename contains this string')
    parser.add_argument('--source', choices=['phonetic', 'lowercase', 'capital'],
                        help='Small-cap glyph source (omit to use interactive prompt)')
    parser.add_argument('--no-populate', action='store_true',
                        help='Do not copy glyphs to phonetic extension codepoints')
    parser.add_argument('--no-c2sc', action='store_true',
                        help='Skip c2sc (uppercase → small caps); only add smcp')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    args = parser.parse_args()

    logger = setup_logger(args.debug)

    font_paths = find_fonts(args.src, args.family)
    if not font_paths:
        logger.error(f'No font files found in: {args.src}')
        sys.exit(1)

    print(f'\n{BLUE}ℹ{NC} Found {len(font_paths)} font file(s):')
    for p in font_paths:
        print(f'  • {p}')

    # Decide source / options
    if args.source:
        source           = args.source
        populate_phonetic = not args.no_populate
        add_c2sc         = not args.no_c2sc
    else:
        source, populate_phonetic, add_c2sc = interactive_prompt()

    # Resolve output paths
    src_base = Path(args.src)
    out_base = Path(args.output) if args.output else None

    errors = 0
    for font_path in font_paths:
        if out_base:
            if out_base.suffix:                  # Single explicit output file
                output_path = out_base
            else:                                 # Mirror structure under out_base
                try:
                    rel = font_path.relative_to(src_base)
                    output_path = out_base / rel
                except ValueError:
                    output_path = out_base / font_path.name
        else:
            output_path = font_path              # In-place

        print(f'\n{CYAN}▶{NC} {font_path.name}')
        try:
            process_font(font_path, output_path, source, populate_phonetic, add_c2sc, logger)
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
