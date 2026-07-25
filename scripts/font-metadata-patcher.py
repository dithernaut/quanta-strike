#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Font Metadata Patcher
Processes fonts in the src folder and adds proper metadata for each font family and style.

NOTE ON PIXEL ALIGNMENT
-----------------------
quanta-strike fonts are pixel fonts: each source pixel is a fixed number of font
units and the em is an exact whole number of those pixels, so a strike rendered at
its nominal size gives exactly 1 CSS px per pixel and stays crisp. This patcher
therefore NEVER touches the vertical metrics (em, ascent, descent, line gap) — it
only rewrites naming / OS-2 / SFNT metadata. Leaving the metrics untouched is what
preserves the pixel grid.
"""

import os
import sys
import argparse
import re
import logging
from pathlib import Path

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded. Try installing fontforge python bindings")

# Weight mapping for OS/2 weight class
WEIGHT_MAP = {
    'thin': 100,
    'hairline': 100,
    'extralight': 200,
    'ultralight': 200,
    'light': 300,
    'regular': 400,
    'normal': 400,
    'book': 400,
    'medium': 500,
    'semibold': 600,
    'demibold': 600,
    'bold': 700,
    'extrabold': 800,
    'ultrabold': 800,
    'black': 900,
    'heavy': 900
}

# Weight words that are two words run together, and how they should read in the
# name records. Anything not listed here just gets title-cased.
WEIGHT_DISPLAY = {
    'extralight': 'ExtraLight',
    'ultralight': 'UltraLight',
    'semibold': 'SemiBold',
    'demibold': 'DemiBold',
    'extrabold': 'ExtraBold',
    'ultrabold': 'UltraBold',
}

ITALIC_TOKENS = ('italic', 'oblique')

# Longest first, so "extrabold" is not read as "bold" by the substring fallback.
WEIGHTS_LONGEST_FIRST = tuple(sorted(WEIGHT_MAP, key=len, reverse=True))

# Splits a style folder or filename into words: "bold-italic", "bold_italic",
# "Bold Italic" all become ['bold', 'italic'].
TOKEN_SPLIT_RE = re.compile(r'[\s_-]+')

# Width mapping for OS/2 width class
WIDTH_MAP = {
    'ultracondensed': 1,
    'extracondensed': 2,
    'condensed': 3,
    'semicondensed': 4,
    'normal': 5,
    'medium': 5,
    'semiexpanded': 6,
    'expanded': 7,
    'extraexpanded': 8,
    'ultraexpanded': 9
}

# PFM Family mapping - FontForge expects integer values
PFM_FAMILY_MAP = {
    'serif': 1,
    'sans': 2,
    'monospace': 3,
    'script': 4,
    'decorative': 5
}

def setup_logger(debug=False):
    """Set up logging configuration"""
    logger = logging.getLogger('font-metadata-patcher')
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    
    handler = logging.StreamHandler()
    formatter = logging.Formatter('%(levelname)s: %(message)s')
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    
    return logger

def parse_style(name, allow_substring=False):
    """Read weight + italic out of a style folder name (or a filename).

    Words are matched WHOLE — 'light' in "light" is a weight, in "lighthouse" is
    not — so a family name that merely contains a weight word can't be misread.
    Glued forms are handled too: "bolditalic" splits into bold + italic.

    allow_substring re-enables a loose scan for names with no separators at all
    ("MyFontBold.ttf"); it is only used when parsing a bare filename, never a
    style folder, where the folder name IS the style and needs no guessing.

    Returns (weight, is_italic, unknown) — `unknown` being the words that meant
    nothing, which is how known_style tells a real weight from a typo.
    """
    base = os.path.splitext(name)[0].lower()
    tokens = [t for t in TOKEN_SPLIT_RE.split(base) if t]

    weight = 'regular'
    is_italic = False
    unknown = []

    for token in tokens:
        word = token
        # Peel a trailing italic/oblique off the word first, so "bolditalic"
        # and "italic" both reduce to the weight part (possibly empty).
        for suffix in ITALIC_TOKENS:
            if word.endswith(suffix):
                word = word[:-len(suffix)]
                is_italic = True
                break
        if word in WEIGHT_MAP:
            weight = word
        elif word:
            unknown.append(token)

    if weight == 'regular' and allow_substring:
        for candidate in WEIGHTS_LONGEST_FIRST:
            if candidate in base:
                weight = candidate
                break
        if not is_italic:
            is_italic = any(t in base for t in ITALIC_TOKENS)

    return weight, is_italic, unknown


def known_style(name):
    """Is every word in this style folder name one we understand?

    The folder name is the ONLY thing that sets the weight, so a typo has to be
    caught: 'semibld/' would otherwise parse as regular, get stamped weight 400,
    and overwrite the real regular on its way out.
    """
    _, _, unknown = parse_style(name)
    return not unknown


def style_display_name(weight, is_italic):
    """The style as it should read in the name records: 'SemiBold Italic'."""
    parts = []
    if weight != 'regular' or not is_italic:
        parts.append(WEIGHT_DISPLAY.get(weight, weight.title()))
    if is_italic:
        parts.append('Italic')
    return ' '.join(parts)


def style_info_from_name(name, allow_substring=False):
    """Full style record for a style folder name or a filename."""
    weight, is_italic, _ = parse_style(name, allow_substring)
    display = style_display_name(weight, is_italic)
    return {
        'style': display.lower(),
        'display': display,
        'weight': weight,
        'is_italic': is_italic,
        # RIBBI: only the true Bold member carries the bold bit. Black/ExtraBold
        # are their own legacy family (see ribbi_names), so flagging them bold
        # would make them fight the real Bold for the same slot.
        'is_bold': weight == 'bold',
    }


def parse_style_from_filename(filename):
    """Parse style information from a filename (loose match, no style folder)."""
    return style_info_from_name(filename, allow_substring=True)


def ribbi_names(family_name, style_info):
    """Split a style into the legacy (ID 1/2) and preferred (ID 16/17) names.

    Name ID 2 only has four legal values — Regular, Bold, Italic, Bold Italic —
    so a family with more than those has to hand every extra weight its OWN
    legacy family: "quanta-strike-12 Light" / "Regular". IDs 16/17 then put them
    back together as one family for anything that reads them, which is every
    browser and every modern app. Skip this and Light installs as a separate
    family on Windows and can win the Regular slot outright.
    """
    weight = style_info['weight']
    is_italic = style_info['is_italic']
    preferred_style = style_info['display']

    if weight in ('regular', 'bold'):
        # RIBBI proper: the style fits ID 2 as-is.
        return family_name, preferred_style, family_name, preferred_style

    legacy_family = f"{family_name} {WEIGHT_DISPLAY.get(weight, weight.title())}"
    legacy_style = 'Italic' if is_italic else 'Regular'
    return legacy_family, legacy_style, family_name, preferred_style


def get_style_map_flags(is_bold, is_italic):
    """Get OS/2 style map flags (fsSelection)"""
    flags = 0
    if is_italic:
        flags |= 1  # Italic bit
    if is_bold:
        flags |= 32  # Bold bit
    if not flags:
        flags |= 64  # Regular bit — mutually exclusive with the two above
    return flags

def set_font_metadata(font, family_name, style_info, args, logger):
    """Set comprehensive font metadata"""
    style = style_info['style']
    weight = style_info['weight']
    is_bold = style_info['is_bold']
    is_italic = style_info['is_italic']

    # Legacy (ID 1/2) vs preferred (ID 16/17) split — see ribbi_names.
    legacy_family, legacy_style, pref_family, pref_style = ribbi_names(family_name, style_info)

    # Apply lowercase if requested
    if args.lowercase:
        family_name = family_name.lower()
        style = style.lower()
        weight = weight.lower()
        legacy_family = legacy_family.lower()
        legacy_style = legacy_style.lower()
        pref_family = pref_family.lower()
        pref_style = pref_style.lower()

    # Generate names
    font_name = f"{family_name}-{style.replace(' ', '')}"
    human_name = f"{family_name} {style}"

    logger.info(f"Setting metadata for {font_name}")
    
    # Set PS Names
    font.fontname = font_name
    font.familyname = family_name
    font.fullname = human_name
    
    # Set version if provided
    if args.version:
        font.version = args.version
        font.sfntRevision = None  # Auto-set by fontforge
    
    # Set OS/2 metadata
    font.os2_weight = WEIGHT_MAP.get(weight, 400)
    font.os2_width = WIDTH_MAP.get(args.width.lower() if args.width else 'normal', 5)
    
    # Set PFM family if provided
    if args.type:
        pfm_value = PFM_FAMILY_MAP.get(args.type.lower())
        if pfm_value:
            # Set OS/2 family class (PFM family) - FontForge expects integer values
            # The family class is stored as (class << 8) + subclass
            # We use subclass 0 (no classification) so just shift the class value
            font.os2_family_class = (pfm_value << 8) + 0
            logger.debug(f"PFM family type: {args.type} -> class {pfm_value} -> encoded: {(pfm_value << 8) + 0}")
        else:
            logger.warning(f"Unknown font type: {args.type}")
    
    # Set style map
    font.os2_stylemap = get_style_map_flags(is_bold, is_italic)
    
    # Clear existing SFNT names to avoid conflicts
    font.sfnt_names = ()
    
    # Set TTF Names (SFNT names). Family/SubFamily are the legacy RIBBI pair;
    # Preferred Family/Styles carry the real grouping for weights that don't fit.
    font.appendSFNTName('English (US)', 'Family', legacy_family)
    font.appendSFNTName('English (US)', 'SubFamily', legacy_style)
    font.appendSFNTName('English (US)', 'Fullname', human_name)
    font.appendSFNTName('English (US)', 'PostScriptName', font_name)
    font.appendSFNTName('English (US)', 'Preferred Family', pref_family)
    font.appendSFNTName('English (US)', 'Preferred Styles', pref_style)
    font.appendSFNTName('English (US)', 'UniqueID', f"{family_name}-{style.replace(' ', '')}")
    
    # Set version in SFNT names
    version_string = f"Version {font.version}" if font.version else "Version 1.000"
    font.appendSFNTName('English (US)', 'Version', version_string)
    
    # Set compatible full name for legacy compatibility
    font.appendSFNTName('English (US)', 'Compatible Full', human_name)
    
    # Set designer name (name ID 9) if provided
    if args.designer:
        font.appendSFNTName('English (US)', 'Designer', args.designer)
        logger.debug(f"Designer set: {args.designer}")

    # Set designer URL if provided
    if args.designerurl:
        font.appendSFNTName('English (US)', 'Designer URL', args.designerurl)
        logger.debug(f"Designer URL set: {args.designerurl}")

    # Set license URL if provided
    if args.licenseurl:
        font.appendSFNTName('English (US)', 'License URL', args.licenseurl)
        logger.debug(f"License URL set: {args.licenseurl}")

    # Set the license description (name ID 13) — this is the licence itself, and
    # is a different field from the copyright notice below. Google Fonts checks
    # both: ID 0 must be the copyright line, ID 13 the OFL blurb.
    if args.licensedesc:
        font.appendSFNTName('English (US)', 'License', args.licensedesc)
        logger.debug(f"License description set: {args.licensedesc}")

    # Set the copyright notice (name ID 0). NB: FontForge pre-fills this from the
    # OS account name, so always set it explicitly — otherwise the builder's real
    # name ships inside the font.
    if args.license:
        font.appendSFNTName('English (US)', 'Copyright', args.license)
        font.copyright = args.license  # Also set the general copyright property
        logger.debug(f"License/Copyright set: {args.license}")
    
    # NOTE: vertical metrics (em / ascent / descent / line gap) are intentionally
    # left exactly as authored, to keep the pixel grid intact. quanta-strike is a
    # pixel font: em is a whole number of source pixels, so a strike rendered at its
    # nominal size gives exactly 1 CSS px per pixel. Changing the metrics would break
    # that, so this patcher only rewrites naming / OS-2 / SFNT metadata.

    logger.debug(f"Font metadata set: {font_name} ({human_name})")

def process_font_file(font_path, family_name, style_folder, output_dir, args, logger):
    """Process a single font file"""
    try:
        logger.info(f"Processing: {font_path}")
        
        # Open the font
        font = fontforge.open(str(font_path))
        
        # Parse style from folder name or filename
        if style_folder:
            # The style folder IS the style: src/<family>/bold/ -> Bold. Read it
            # from the folder, never the filename — the filename here is the
            # family (quanta-strike-12.ttf) and carries no weight at all, which
            # is why every style used to come out at weight 400.
            style_info = style_info_from_name(style_folder)
        else:
            style_info = parse_style_from_filename(font_path.name)
        
        # Set metadata
        set_font_metadata(font, family_name, style_info, args, logger)
        
        # Create output directory
        family_output_dir = output_dir if args.flat else output_dir / family_name
        family_output_dir.mkdir(parents=True, exist_ok=True)
        
        # Generate output filename
        output_name = f"{family_name}-{style_info['style'].replace(' ', '')}"
        if args.lowercase:
            output_name = output_name.lower()
        
        # Keep original extension or use specified one
        if args.extension:
            output_ext = f".{args.extension.lstrip('.')}"
        else:
            output_ext = font_path.suffix
        
        output_path = family_output_dir / f"{output_name}{output_ext}"
        
        # Generate the font
        logger.info(f"Generating: {output_path}")
        
        # Use appropriate flags for generation
        gen_flags = ["opentype", "PfEd-comments", "no-FFTM-table"]
        
        font.generate(str(output_path), flags=tuple(gen_flags))
        font.close()
        
        logger.info(f"Successfully generated: {output_path}")
        
    except Exception as e:
        logger.error(f"Error processing {font_path}: {str(e)}")
        raise

def find_font_files(directory):
    """Find all font files in a directory"""
    font_extensions = {'.ttf', '.otf', '.woff', '.woff2'}
    font_files = []
    
    for ext in font_extensions:
        font_files.extend(directory.glob(f"*{ext}"))
        font_files.extend(directory.glob(f"*{ext.upper()}"))
    
    return sorted(font_files)

def process_family_directory(family_dir, output_dir, args, logger):
    """Process all fonts in a family directory"""
    family_name = family_dir.name
    logger.info(f"Processing family: {family_name}")
    
    # Look for style subdirectories first
    style_dirs = [d for d in family_dir.iterdir() if d.is_dir()]
    
    if style_dirs:
        # Process each style directory
        for style_dir in style_dirs:
            style_name = style_dir.name

            # The folder name is the ONLY thing that sets the weight, so a typo
            # can't be allowed through: it would parse as regular, be stamped
            # weight 400, and overwrite the real regular in the output folder.
            if not known_style(style_name):
                logger.error(
                    f"'{style_name}' is not a weight I recognise — it is a style "
                    f"folder of {family_dir.name}, i.e. src/<strike>/{style_name}/. "
                    f"The style folder names the weight, so use one of: "
                    f"{', '.join(sorted(WEIGHT_MAP))}; add 'italic' for an italic "
                    f"(e.g. 'bold-italic')."
                )
                sys.exit(1)

            font_files = find_font_files(style_dir)
            
            if font_files:
                logger.info(f"Processing style: {style_name}")
                for font_file in font_files:
                    process_font_file(font_file, family_name, style_name, output_dir, args, logger)
            else:
                logger.warning(f"No font files found in style directory: {style_dir}")
    else:
        # No style subdirectories, process fonts directly in family directory
        font_files = find_font_files(family_dir)
        
        if font_files:
            for font_file in font_files:
                process_font_file(font_file, family_name, None, output_dir, args, logger)
        else:
            logger.warning(f"No font files found in family directory: {family_dir}")

def main():
    parser = argparse.ArgumentParser(
        description='Font Metadata Patcher - Sets proper metadata for font families and styles',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument('--src', '-s',
                        default='src',
                        help='Source directory containing font families (default: src)')
    
    parser.add_argument('--output', '-o',
                        default='build',
                        help='Output directory for processed fonts (default: build)')
    
    parser.add_argument('--version', '-v',
                        help='Set font version (e.g., "1.000")')
    
    parser.add_argument('--width',
                        choices=['ultracondensed', 'extracondensed', 'condensed', 'semicondensed', 
                                'normal', 'medium', 'semiexpanded', 'expanded', 'extraexpanded', 'ultraexpanded'],
                        default='normal',
                        help='Set OS/2 width class (default: normal)')
    
    parser.add_argument('--type',
                        choices=['serif', 'sans', 'monospace', 'script', 'decorative'],
                        help='Set PFM family type')
    
    parser.add_argument('--extension', '-ext',
                        help='Output file extension (e.g., ttf, otf)')
    
    parser.add_argument('--lowercase',
                        action='store_true',
                        help='Convert all font names to lowercase')

    parser.add_argument('--flat',
                        action='store_true',
                        help='Write all fonts directly into --output (no per-family subfolder)')
    
    parser.add_argument('--debug',
                        action='store_true',
                        help='Enable debug logging')
    
    parser.add_argument('--family',
                        help='Process only a specific font family')
    
    parser.add_argument('--designer',
                        help='Set designer/author name, name ID 9 (e.g., "dithernaut")')

    parser.add_argument('--designerurl',
                        help='Set designer URL (e.g., https://pico.com)')

    parser.add_argument('--licenseurl',
                        help='Set license URL (e.g., https://pico.com/license)')

    parser.add_argument('--licensedesc',
                        help='Set the license description, name ID 13 (e.g. the OFL blurb). '
                             'Distinct from --license, which is the copyright notice.')

    parser.add_argument('--license',
                        help='Set the copyright notice, name ID 0 (e.g., "Copyright 2026 ...")')
    
    args = parser.parse_args()
    
    # Set up logger
    logger = setup_logger(args.debug)
    
    # Validate paths
    src_dir = Path(args.src)
    output_dir = Path(args.output)
    
    if not src_dir.exists():
        logger.error(f"Source directory does not exist: {src_dir}")
        sys.exit(1)
    
    # Create output directory
    output_dir.mkdir(parents=True, exist_ok=True)
    
    logger.info(f"Font Metadata Patcher starting...")
    logger.info(f"Source: {src_dir}")
    logger.info(f"Output: {output_dir}")
    
    # Process families
    if args.family:
        # Process specific family
        family_dir = src_dir / args.family
        if not family_dir.exists():
            logger.error(f"Family directory does not exist: {family_dir}")
            sys.exit(1)
        
        process_family_directory(family_dir, output_dir, args, logger)
    else:
        # Process all families
        family_dirs = [d for d in src_dir.iterdir() if d.is_dir()]
        
        if not family_dirs:
            logger.error(f"No family directories found in: {src_dir}")
            sys.exit(1)
        
        for family_dir in family_dirs:
            try:
                process_family_directory(family_dir, output_dir, args, logger)
            except Exception as e:
                logger.error(f"Error processing family {family_dir.name}: {str(e)}")
                if args.debug:
                    raise
                continue
    
    logger.info("Font Metadata Patcher completed!")

if __name__ == '__main__':
    main() 