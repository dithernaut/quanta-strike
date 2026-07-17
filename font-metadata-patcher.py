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
    'extralight': 200,
    'ultralight': 200,
    'light': 300,
    'regular': 400,
    'normal': 400,
    'medium': 500,
    'semibold': 600,
    'demibold': 600,
    'bold': 700,
    'extrabold': 800,
    'ultrabold': 800,
    'black': 900,
    'heavy': 900
}

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

def parse_style_from_filename(filename):
    """Parse style information from filename"""
    filename_lower = filename.lower()
    
    # Remove file extension
    name_base = os.path.splitext(filename_lower)[0]
    
    # Check for style indicators
    is_bold = any(weight in name_base for weight in ['bold', 'black', 'heavy', 'extrabold', 'ultrabold'])
    is_italic = any(style in name_base for style in ['italic', 'oblique'])
    
    # Determine weight
    weight = 'regular'
    for w in ['thin', 'extralight', 'ultralight', 'light', 'medium', 'semibold', 'demibold', 'bold', 'extrabold', 'ultrabold', 'black', 'heavy']:
        if w in name_base:
            weight = w
            break
    
    # Build style name
    style_parts = []
    if weight != 'regular':
        style_parts.append(weight)
    if is_italic:
        style_parts.append('italic')
    
    style = ' '.join(style_parts) if style_parts else 'regular'
    
    return {
        'style': style,
        'weight': weight,
        'is_bold': is_bold,
        'is_italic': is_italic
    }

def get_style_map_flags(is_bold, is_italic):
    """Get OS/2 style map flags"""
    flags = 0
    if is_italic:
        flags |= 1  # Italic bit
    if is_bold:
        flags |= 32  # Bold bit
    return flags

def set_font_metadata(font, family_name, style_info, args, logger):
    """Set comprehensive font metadata"""
    style = style_info['style']
    weight = style_info['weight']
    is_bold = style_info['is_bold']
    is_italic = style_info['is_italic']
    
    # Apply lowercase if requested
    if args.lowercase:
        family_name = family_name.lower()
        style = style.lower()
        weight = weight.lower()
    
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
    
    # Set TTF Names (SFNT names)
    # Use appropriate case for style names
    style_display = style if args.lowercase else style.title()
    
    font.appendSFNTName('English (US)', 'Family', family_name)
    font.appendSFNTName('English (US)', 'SubFamily', style_display)
    font.appendSFNTName('English (US)', 'Fullname', human_name)
    font.appendSFNTName('English (US)', 'PostScriptName', font_name)
    font.appendSFNTName('English (US)', 'Preferred Family', family_name)
    font.appendSFNTName('English (US)', 'Preferred Styles', style_display)
    font.appendSFNTName('English (US)', 'UniqueID', f"{family_name}-{style.replace(' ', '')}")
    
    # Set version in SFNT names
    version_string = f"Version {font.version}" if font.version else "Version 1.000"
    font.appendSFNTName('English (US)', 'Version', version_string)
    
    # Set compatible full name for legacy compatibility
    font.appendSFNTName('English (US)', 'Compatible Full', human_name)
    
    # Set designer URL if provided
    if args.designerurl:
        font.appendSFNTName('English (US)', 'Designer URL', args.designerurl)
        logger.debug(f"Designer URL set: {args.designerurl}")
    
    # Set license URL if provided
    if args.licenseurl:
        font.appendSFNTName('English (US)', 'License URL', args.licenseurl)
        logger.debug(f"License URL set: {args.licenseurl}")
    
    # Set license/copyright if provided
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
            # Use folder name as style if available
            style_name = style_folder.replace('_', ' ').replace('-', ' ')
            # Still parse for weight and italic info
            style_info = parse_style_from_filename(font_path.name)
            style_info['style'] = style_name
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
    
    parser.add_argument('--designerurl',
                        help='Set designer URL (e.g., https://pico.com)')
    
    parser.add_argument('--licenseurl',
                        help='Set license URL (e.g., https://pico.com/license)')
    
    parser.add_argument('--license',
                        help='Set license/copyright text (e.g., "(c) pico 2025")')
    
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