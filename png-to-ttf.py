#!/usr/bin/env python3
"""Build a strike's TTF from its yal source (PNG + JSON).

This is a faithful reimplementation of the yal.cc pixelfont converter that is
vendored in `pixelfont/` — the step that used to be done by hand ("load the
PNG+JSON in yal, hit Build, save the TTF"). With this, `src/quanta-strike-N/`
only needs the PNG + JSON; the TTF is a pure build artifact.

Behaviour is taken from `pixelfont/script.js` (minified Haxe), not guessed:

  cell(row, col) top-left = (glyph-ofs-x + col*(glyph-width  + glyph-sep-x),
                             glyph-ofs-y + row*(glyph-height + glyph-sep-y))
  a pixel is ink   ("black")  <=>  alpha >= 128 and 3r + 5g + b <= 1024
  pixel (col,row) -> square   x = (col - glyph-base-x) * font-px-size
                              y = (glyph-baseline - row) * font-px-size
                    wound (x,y) (x+1,y) (x+1,y-1) (x,y-1) = clockwise
  advance (mono)   = (glyph-width + glyph-spacing) * font-px-size

`contour-type: pixel` emits one independent square per filled pixel and does
NOT merge them — so the output matches yal contour-for-contour. Nothing is
rescaled: 1 pixel stays exactly font-px-size (128) units. See CLAUDE.md.

Vertical metrics are taken from the JSON, but anchor-em.py re-anchors them
downstream anyway; what has to be right here is outlines, widths and cmap.

Usage:
    png-to-ttf.py SRC [OUT] [--family NAME]...

    SRC   a src/ directory, a strike directory, or a .json file
    OUT   a directory to write <family>.ttf into (default: next to the JSON)
"""

import argparse
import glob
import os
import struct
import sys
import zlib

try:
    import fontforge
except ImportError:
    sys.exit("error: FontForge python bindings not found (brew install fontforge)")


# ── PNG ────────────────────────────────────────────────────────────────────
# A small decoder so the build needs no imaging library. The yal sources are
# all 8-bit non-interlaced RGB/RGBA, which is what we accept.

PNG_SIG = b"\x89PNG\r\n\x1a\n"


class Image:
    """8-bit RGBA pixels. Reads outside the canvas are transparent, which is
    what a browser canvas' getImageData() gives yal for out-of-bounds cells."""

    def __init__(self, width, height, rgba):
        self.width = width
        self.height = height
        self.rgba = rgba

    def pixel(self, x, y):
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return (0, 0, 0, 0)
        i = (y * self.width + x) * 4
        return tuple(self.rgba[i:i + 4])


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def decode_png(path):
    data = open(path, "rb").read()
    if data[:8] != PNG_SIG:
        raise ValueError(f"{path}: not a PNG")

    idat = bytearray()
    width = height = depth = color = interlace = None
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length  # length + type + body + crc
        if kind == b"IHDR":
            width, height, depth, color, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break

    if width is None:
        raise ValueError(f"{path}: no IHDR")
    if depth != 8 or interlace != 0 or color not in (2, 6):
        raise ValueError(
            f"{path}: unsupported PNG (bit depth {depth}, colour type {color}, "
            f"interlace {interlace}); expected 8-bit non-interlaced RGB/RGBA"
        )

    bpp = 3 if color == 2 else 4
    stride = width * bpp
    raw = zlib.decompress(bytes(idat))
    if len(raw) < height * (stride + 1):
        raise ValueError(f"{path}: truncated image data")

    # Undo the per-scanline filters (PNG spec §9).
    out = bytearray(height * stride)
    prev = bytearray(stride)
    src = 0
    for y in range(height):
        ftype = raw[src]
        src += 1
        line = bytearray(raw[src:src + stride])
        src += stride
        if ftype == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        elif ftype != 0:
            raise ValueError(f"{path}: bad filter type {ftype} on row {y}")
        out[y * stride:(y + 1) * stride] = line
        prev = line

    if bpp == 4:
        return Image(width, height, out)

    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        rgba[i * 4:i * 4 + 3] = out[i * 3:i * 3 + 3]
        rgba[i * 4 + 3] = 255
    return Image(width, height, rgba)


# ── ink test ───────────────────────────────────────────────────────────────
# script.js maps glyph-color to a mode, then tests each pixel. Note that
# "black" is a weighted-luminance test, not an equality check: mid-tones count
# as ink, and only light or transparent pixels are ignored (which is how
# alignment guides drawn in the source art stay out of the font).

def ink_test(glyph_color, image):
    if glyph_color == "black":
        return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b <= 1024
    if glyph_color == "white":
        return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b > 1024
    if glyph_color == "opaque":
        return lambda r, g, b, a: a >= 128
    if glyph_color == "color":
        return lambda r, g, b, a: a > 0
    # yal's fallback: sample the top-left pixel and decide from it.
    r, g, b, a = image.pixel(0, 0)
    if a < 64:
        return lambda r, g, b, a: a >= 128
    if 3 * r + 5 * g + b <= 1024:
        return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b > 1024
    return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b <= 1024


# ── overrides ──────────────────────────────────────────────────────────────
# Only the rules the quanta-strike sources actually use are implemented; any
# other rule is reported rather than silently ignored, so a source change can't
# quietly lose meaning.

# script.js: Of = the codepoints \s expands to (all optional).
SPACE_CODEPOINTS = [
    0x09, 0x0B, 0x0C, 0x20, 0xA0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0x200B, 0xFEFF,
]

ESCAPES = {"0": 0, "r": 13, "n": 10, "t": 9, '"': 34, "'": 39, "-": 45, "\\": 92}


def parse_glyph_spec(spec):
    """Expand a `hide` rule's glyph list into codepoints (script.js Cf.$b)."""
    out = []
    i = 0
    while i < len(spec):
        ch = spec[i]
        if ch.isspace():
            break
        i += 1
        if ch != "\\":
            out.append(ord(ch))
            continue
        if i >= len(spec):
            raise ValueError("dangling escape in glyph spec")
        esc = spec[i]
        i += 1
        if esc == "s":
            out.extend(SPACE_CODEPOINTS)
        elif esc in ("u", "x"):
            if esc == "u" and i < len(spec) and spec[i] == "{":
                end = spec.index("}", i)
                out.append(int(spec[i + 1:end], 16))
                i = end + 1
            else:
                n = 2 if esc == "x" else 4
                out.append(int(spec[i:i + n], 16))
                i += n
        elif esc in ESCAPES:
            out.append(ESCAPES[esc])
        else:
            raise ValueError(f"unknown escape \\{esc}")
    return out


def parse_overrides(lines):
    """Return the set of codepoints to hide (keep the advance, drop the ink)."""
    hidden = set()
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        rule, _, rest = line.partition(" ")
        if rule == "hide":
            hidden.update(parse_glyph_spec(rest.strip()))
        else:
            print(f"  ! unsupported override ignored: {line!r}", file=sys.stderr)
    return hidden


# ── conversion ─────────────────────────────────────────────────────────────

def iter_cells(rows):
    """Walk in-glyphs the way script.js does, yielding (codepoint, row, col).

    Two details that matter: the grid column advances per codepoint (yal indexes
    by codepoint, so astral chars occupy one cell, not two), and only the FIRST
    space in the whole sheet becomes a glyph — later spaces just leave a gap.
    """
    seen_space = False
    for row, line in enumerate(rows):
        col = 0
        for ch in line:
            cp = ord(ch)
            if cp == 13:
                continue
            if cp == 32:
                if seen_space:
                    col += 1
                    continue
                seen_space = True
            yield cp, row, col
            col += 1


def convert(json_path, out_path, quiet=False):
    import json

    with open(json_path, encoding="utf-8") as fh:
        cfg = json.load(fh)

    png_path = os.path.splitext(json_path)[0] + ".png"
    if not os.path.exists(png_path):
        raise SystemExit(f"error: {png_path} not found (a strike needs a PNG next to its JSON)")

    gw = cfg["glyph-width"]
    gh = cfg["glyph-height"]
    ofs_x, ofs_y = cfg["glyph-ofs-x"], cfg["glyph-ofs-y"]
    sep_x, sep_y = cfg["glyph-sep-x"], cfg["glyph-sep-y"]
    base_x = cfg["glyph-base-x"]
    baseline = cfg["glyph-baseline"]
    px = cfg["font-px-size"]
    em = cfg["font-em-square"]
    ascend = cfg["font-ascend"]
    descend = cfg["font-descend"]
    rows = cfg["in-glyphs"]

    if cfg.get("contour-type") != "pixel":
        raise SystemExit(f"error: only contour-type 'pixel' is supported (got {cfg.get('contour-type')!r})")

    image = decode_png(png_path)
    is_ink = ink_test(cfg.get("glyph-color", "black"), image)
    hidden = parse_overrides(cfg.get("overrides", []))
    is_mono = cfg.get("font-is-mono", True)
    is_upper = cfg.get("font-is-upper", False)
    mono_width = (gw + cfg.get("glyph-spacing", 0)) * px

    font = fontforge.font()
    font.encoding = "UnicodeFull"
    font.em = em
    font.ascent = ascend
    font.descent = -descend
    # NB: setting is_quadratic on the layers up front segfaults FontForge here,
    # and it buys nothing — every contour is a straight-edged polygon with all
    # points on-curve, so the cubic->quadratic conversion at generate() time is
    # exact (verified against yal's TTF, point for point).

    font.familyname = cfg.get("font-name", os.path.basename(out_path))
    font.fontname = font.familyname
    font.fullname = font.familyname
    font.weight = cfg.get("font-style", "Regular")

    n_glyphs = n_ink = 0
    out_of_bounds = []

    for cp, row, col in iter_cells(rows):
        x0 = ofs_x + col * (gw + sep_x)
        y0 = ofs_y + row * (gh + sep_y)
        if x0 >= image.width or y0 >= image.height or x0 + gw > image.width or y0 + gh > image.height:
            out_of_bounds.append(chr(cp))

        # Read the cell, then turn each filled pixel into its own square.
        contours = []
        if cp not in hidden:
            for r in range(gh):
                for c in range(gw):
                    if not is_ink(*image.pixel(x0 + c, y0 + r)):
                        continue
                    left = (c - base_x) * px
                    top = (baseline - r) * px
                    right, bottom = left + px, top - px
                    contour = fontforge.contour()
                    contour.moveTo(left, top)       # clockwise in y-up:
                    contour.lineTo(right, top)      # TL -> TR -> BR -> BL
                    contour.lineTo(right, bottom)
                    contour.lineTo(left, bottom)
                    contour.closed = True
                    contours.append(contour)

        targets = [cp]
        if is_upper:
            ch = chr(cp)
            if ch.upper() == ch and ch.lower() != ch:
                targets.append(ord(ch.lower()))

        for target in targets:
            glyph = font.createChar(target)
            layer = fontforge.layer()
            for contour in contours:
                layer += contour
            glyph.foreground = layer
            glyph.width = mono_width if is_mono else (gw + cfg.get("glyph-spacing", 0)) * px
            n_glyphs += 1
            n_ink += len(contours)

    if out_of_bounds and not quiet:
        print(f"  ! {len(out_of_bounds)} cell(s) fall outside the PNG: "
              f"{''.join(out_of_bounds[:12])}{'…' if len(out_of_bounds) > 12 else ''}",
              file=sys.stderr)

    # yal ships the usual TrueType pair of empty glyphs alongside the sheet:
    # .notdef and a non-marking carriage return, both at the advance width.
    font.createChar(0x0D, "uni000D")
    for name in (".notdef", "uni000D"):
        glyph = font[name] if name in font else font.createChar(-1, name)
        glyph.width = mono_width

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    font.generate(out_path)
    font.close()

    if not quiet:
        print(f"  {os.path.basename(out_path)}: {n_glyphs} glyphs, {n_ink} pixels, "
              f"em {em}, advance {mono_width}")
    return out_path


# ── cli ────────────────────────────────────────────────────────────────────

def find_sources(src, families):
    """Locate <family>/regular/<family>.json under src (or accept a json path).

    Only a JSON whose basename matches its strike directory is a source, which
    keeps scratch files like *-old.json / *-alt.png out of the build.
    """
    if os.path.isfile(src):
        return [src]
    if not os.path.isdir(src):
        raise SystemExit(f"error: {src} not found")

    found = []
    for json_path in sorted(glob.glob(os.path.join(src, "*", "*", "*.json"))):
        family = os.path.basename(os.path.dirname(os.path.dirname(json_path)))
        if os.path.basename(json_path) != family + ".json":
            continue
        if families and family not in families:
            continue
        found.append(json_path)

    # Also allow pointing straight at a strike directory.
    if not found:
        family = os.path.basename(os.path.normpath(src))
        direct = os.path.join(src, "regular", family + ".json")
        if os.path.exists(direct) and (not families or family in families):
            found.append(direct)
    return found


def main():
    ap = argparse.ArgumentParser(
        description="Build strike TTFs from their yal PNG + JSON sources.")
    ap.add_argument("src", nargs="?", default="./src",
                    help="src directory, a strike directory, or a .json file")
    ap.add_argument("out", nargs="?",
                    help="directory to write <family>.ttf into (default: next to the JSON)")
    ap.add_argument("--family", action="append", default=[],
                    help="only build this strike (repeatable)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    sources = find_sources(args.src, args.family)
    if not sources:
        raise SystemExit(f"error: no PNG+JSON strike sources found under {args.src}")

    for json_path in sources:
        if args.out:
            family = os.path.basename(os.path.dirname(os.path.dirname(json_path)))
            out_path = os.path.join(args.out, family + ".ttf")
        else:
            out_path = os.path.splitext(json_path)[0] + ".ttf"
        convert(json_path, out_path, quiet=args.quiet)

    return 0


if __name__ == "__main__":
    sys.exit(main())
