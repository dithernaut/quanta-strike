#!/usr/bin/env python3
"""Build Linux console PSF fonts from a strike's PNG + JSON sheet.

Trims the sheet to a glyph allowlist (console-charset.json by default, or
console-charset-hr.json, …) so the result fits the console's 256/512 glyph cap.
Emits PSF2 with a Unicode map (.psfu), optionally gzip-compressed (.psfu.gz).
setfont on Raspberry Pi Lite / fbcon expects that format.

Glyphs 0x00..0x7F use identity-mapped ASCII so the Linux console's
"fill with glyph 0x20" quirk gets a real blank space. Otherwise the screen
fills with '@'.

Mono only: each glyph is the fixed cell (glyph-width × glyph-height). No
FontForge dependency; reuses the same PNG ink rules as scripts/png-to-ttf.py.

Usage:
    scripts/png-to-psf.py SRC [OUT]
        [--charset console-charset.json] [--family NAME]... [--no-gzip]

    SRC   a src/ directory, a strike directory, or a .json file
    OUT   directory for <family>.psfu[.gz] (default: next to the JSON)
"""

from __future__ import annotations

import argparse
import glob
import gzip
import json
import os
import struct
import sys
import zlib

# ── PNG (same decoder / ink rules as png-to-ttf; kept local so this script
# needs no FontForge) ───────────────────────────────────────────────────────

PNG_SIG = b"\x89PNG\r\n\x1a\n"

PSF2_MAGIC = b"\x72\xb5\x4a\x86"
PSF2_HAS_UNICODE = 0x01
UNICODE_SEPARATOR = b"\xff"


class Image:
    def __init__(self, width, height, rgba):
        self.width = width
        self.height = height
        self.rgba = rgba

    def pixel(self, x, y):
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return (0, 0, 0, 0)
        i = (y * self.width + x) * 4
        return tuple(self.rgba[i : i + 4])


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
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _comp, _filt, interlace = struct.unpack(
                ">IIBBBBB", body
            )
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

    out = bytearray(height * stride)
    prev = bytearray(stride)
    src = 0
    for y in range(height):
        ftype = raw[src]
        src += 1
        line = bytearray(raw[src : src + stride])
        src += stride
        if ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        elif ftype != 0:
            raise ValueError(f"{path}: bad filter type {ftype} on row {y}")
        out[y * stride : (y + 1) * stride] = line
        prev = line

    if bpp == 4:
        return Image(width, height, out)

    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        rgba[i * 4 : i * 4 + 3] = out[i * 3 : i * 3 + 3]
        rgba[i * 4 + 3] = 255
    return Image(width, height, rgba)


def ink_test(glyph_color, image):
    if glyph_color == "black":
        return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b <= 1024
    if glyph_color == "white":
        return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b > 1024
    if glyph_color == "opaque":
        return lambda r, g, b, a: a >= 128
    if glyph_color == "color":
        return lambda r, g, b, a: a > 0
    r, g, b, a = image.pixel(0, 0)
    if a < 64:
        return lambda r, g, b, a: a >= 128
    if 3 * r + 5 * g + b <= 1024:
        return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b > 1024
    return lambda r, g, b, a: a >= 128 and 3 * r + 5 * g + b <= 1024


SPACE_CODEPOINTS = [
    0x09,
    0x0B,
    0x0C,
    0x20,
    0xA0,
    0x1680,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200A,
    0x202F,
    0x205F,
    0x3000,
    0x200B,
    0xFEFF,
]
ESCAPES = {"0": 0, "r": 13, "n": 10, "t": 9, '"': 34, "'": 39, "-": 45, "\\": 92}


def parse_glyph_spec(spec):
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
                out.append(int(spec[i + 1 : end], 16))
                i = end + 1
            else:
                n = 2 if esc == "x" else 4
                out.append(int(spec[i : i + n], 16))
                i += n
        elif esc in ESCAPES:
            out.append(ESCAPES[esc])
        else:
            raise ValueError(f"unknown escape \\{esc}")
    return out


def parse_overrides(lines):
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


def iter_cells(rows):
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


# ── charset ────────────────────────────────────────────────────────────────

def load_charset(path):
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)

    max_glyphs = int(cfg.get("max-glyphs", 256))
    if max_glyphs not in (256, 512):
        raise SystemExit(
            f"error: {path}: max-glyphs must be 256 or 512 (got {max_glyphs})"
        )

    glyphs = cfg.get("glyphs")
    if glyphs is None:
        raise SystemExit(f"error: {path}: missing 'glyphs'")

    # Accept a list of row-strings (preferred), one big string, or a list of
    # single-char / U+XXXX tokens.
    ordered = []
    seen = set()
    if isinstance(glyphs, str):
        sequences = [glyphs]
    elif isinstance(glyphs, list):
        sequences = glyphs
    else:
        raise SystemExit(f"error: {path}: 'glyphs' must be a string or list")

    for item in sequences:
        if not isinstance(item, str):
            raise SystemExit(f"error: {path}: glyph entries must be strings")
        if item.startswith("U+") or item.startswith("u+"):
            chars = [chr(int(item[2:], 16))]
        else:
            chars = list(item)
        for ch in chars:
            if ch in seen:
                raise SystemExit(
                    f"error: {path}: duplicate glyph U+{ord(ch):04X} ({ch!r})"
                )
            seen.add(ch)
            ordered.append(ch)

    if len(ordered) > max_glyphs:
        raise SystemExit(
            f"error: {path}: {len(ordered)} glyphs listed, max-glyphs is {max_glyphs}"
        )
    return ordered, max_glyphs


# ── PSF2 writer ────────────────────────────────────────────────────────────

def pack_glyph(bits_rows, width):
    """Pack a glyph's rows of 0/1 bits into PSF byte rows (MSB = leftmost)."""
    bytes_per_row = (width + 7) // 8
    out = bytearray()
    for row in bits_rows:
        for byte_i in range(bytes_per_row):
            byte = 0
            for bit in range(8):
                x = byte_i * 8 + bit
                if x < width and row[x]:
                    byte |= 0x80 >> bit
            out.append(byte)
    return bytes(out)


def scale_bits(bits_rows, factor):
    """Nearest-neighbor upscale of a glyph's bit rows (integer factor ≥ 1)."""
    if factor == 1:
        return bits_rows
    if factor < 1 or int(factor) != factor:
        raise ValueError(f"scale factor must be an integer ≥ 1 (got {factor})")
    factor = int(factor)
    out = []
    for row in bits_rows:
        scaled = []
        for bit in row:
            scaled.extend([bit] * factor)
        for _ in range(factor):
            out.append(list(scaled))
    return out


def write_psf2(path, glyphs, width, height, compress):
    """glyphs: list of (codepoint, bitmap-bytes).

    IMPORTANT: glyph index 0x20 must be U+0020 space with a blank bitmap.
    The Linux console fills the background from glyph slot 0x20 and ignores
    the Unicode map for that. If that slot is '@' (easy when you pack ASCII
    starting at index 0), the whole screen fills with @.
    """
    charsize = ((width + 7) // 8) * height
    if len(glyphs) > 0x20:
        cp20, bm20 = glyphs[0x20]
        if cp20 != 0x20 or any(bm20):
            raise ValueError(
                "glyph[0x20] must be blank U+0020 space (Linux console fill quirk); "
                f"got U+{cp20:04X} nonblank={any(bm20)}"
            )

    header = struct.pack(
        "<4sIIIIIII",
        PSF2_MAGIC,
        0,  # version
        32,  # headersize
        PSF2_HAS_UNICODE,
        len(glyphs),
        charsize,
        height,
        width,
    )

    body = bytearray(header)
    for _cp, bitmap in glyphs:
        if len(bitmap) != charsize:
            raise ValueError(
                f"glyph bitmap size {len(bitmap)} != charsize {charsize}"
            )
        body += bitmap

    for cp, _bitmap in glyphs:
        body += chr(cp).encode("utf-8")
        body += UNICODE_SEPARATOR

    raw = bytes(body)
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    if compress:
        with gzip.open(path, "wb") as fh:
            fh.write(raw)
    else:
        with open(path, "wb") as fh:
            fh.write(raw)
    return path


def assemble_glyphs(sheet, charset, blank, max_glyphs, quiet=False):
    """Pack glyphs for the Linux console.

    Slots 0x00..0x7F are identity-mapped to ASCII (U+0000..U+007F) so low-level
    console paths that ignore the Unicode table still work, and slot 0x20 is
    blank space (kernel background-fill quirk). Remaining charset codepoints
    fill 0x80..max_glyphs-1 in charset order.
    """
    # Bitmaps we can emit: everything in the charset that exists on the sheet,
    # plus any ASCII printable present on the sheet (identity slots need them).
    available = {}
    missing = []
    for ch in charset:
        cp = ord(ch)
        if cp in sheet:
            available[cp] = sheet[cp]
        else:
            missing.append(ch)
    for cp in range(0x20, 0x7F):
        if cp not in available and cp in sheet:
            available[cp] = sheet[cp]

    glyphs = []
    for cp in range(0x80):
        if cp in available:
            glyphs.append((cp, available[cp]))
        else:
            glyphs.append((cp, blank))

    # Slot 0x20 must stay blank even if the sheet somehow inked space.
    glyphs[0x20] = (0x20, blank)

    placed = set(range(0x80))
    dropped = []
    for ch in charset:
        cp = ord(ch)
        if cp in placed:
            continue
        if cp not in available:
            continue
        if len(glyphs) >= max_glyphs:
            dropped.append(ch)
            continue
        glyphs.append((cp, available[cp]))
        placed.add(cp)

    if dropped and not quiet:
        preview = "".join(dropped[:24])
        more = "…" if len(dropped) > 24 else ""
        print(
            f"  ! {len(dropped)} non-ASCII charset glyph(s) dropped "
            f"(need slots ≥0x80, only {max_glyphs - 0x80} free): "
            f"{preview}{more}",
            file=sys.stderr,
        )

    return glyphs, missing


# ── conversion ─────────────────────────────────────────────────────────────

def convert(json_path, out_path, charset, max_glyphs, quiet=False, compress=True,
            scale=1):
    with open(json_path, encoding="utf-8") as fh:
        cfg = json.load(fh)

    png_path = os.path.splitext(json_path)[0] + ".png"
    if not os.path.exists(png_path):
        raise SystemExit(
            f"error: {png_path} not found (a strike needs a PNG next to its JSON)"
        )

    if cfg.get("contour-type") != "pixel":
        raise SystemExit(
            f"error: only contour-type 'pixel' is supported "
            f"(got {cfg.get('contour-type')!r})"
        )

    scale = int(scale)
    if scale < 1:
        raise SystemExit(f"error: --scale must be an integer ≥ 1 (got {scale})")

    gw = cfg["glyph-width"]
    gh = cfg["glyph-height"]
    ofs_x, ofs_y = cfg["glyph-ofs-x"], cfg["glyph-ofs-y"]
    sep_x, sep_y = cfg["glyph-sep-x"], cfg["glyph-sep-y"]
    rows = cfg["in-glyphs"]

    image = decode_png(png_path)
    is_ink = ink_test(cfg.get("glyph-color", "black"), image)
    hidden = parse_overrides(cfg.get("overrides", []))

    # Sheet → bit rows per cell; scale then pack so PSF cell size is gw*scale.
    sheet = {}
    for cp, row, col in iter_cells(rows):
        x0 = ofs_x + col * (gw + sep_x)
        y0 = ofs_y + row * (gh + sep_y)
        bits = []
        for r in range(gh):
            row_bits = []
            for c in range(gw):
                ink = False
                if cp not in hidden:
                    ink = is_ink(*image.pixel(x0 + c, y0 + r))
                row_bits.append(1 if ink else 0)
            bits.append(row_bits)
        bits = scale_bits(bits, scale)
        sheet[cp] = pack_glyph(bits, gw * scale)

    out_w, out_h = gw * scale, gh * scale
    blank = pack_glyph([[0] * out_w for _ in range(out_h)], out_w)

    selected, missing = assemble_glyphs(
        sheet, charset, blank, max_glyphs, quiet=quiet
    )

    if missing and not quiet:
        preview = "".join(missing[:24])
        more = "…" if len(missing) > 24 else ""
        print(
            f"  ! {len(missing)} charset glyph(s) not on sheet "
            f"(skipped): {preview}{more}",
            file=sys.stderr,
        )

    if not any(cp == 0x20 for cp, _ in selected):
        raise SystemExit("error: assembled font is missing U+0020 space")

    if len(selected) > max_glyphs:
        raise SystemExit(
            f"error: {len(selected)} glyphs after trim exceeds max-glyphs "
            f"{max_glyphs}. Shrink the charset JSON."
        )

    write_psf2(out_path, selected, out_w, out_h, compress=compress)

    if not quiet:
        scale_note = f", ×{scale}" if scale > 1 else ""
        print(
            f"  {os.path.basename(out_path)}: {len(selected)} glyphs, "
            f"{out_w}×{out_h}px{scale_note}, PSF2 unicode (ASCII identity layout)"
            + (f" ({len(missing)} charset miss)" if missing else "")
        )
    return out_path


def style_of(json_path):
    return os.path.basename(os.path.dirname(os.path.abspath(json_path)))


def find_sources(src, families):
    """Same discovery rules as png-to-ttf (family/style JSON stems)."""
    if os.path.isfile(src):
        return [src]
    if not os.path.isdir(src):
        raise SystemExit(f"error: {src} not found")

    found = []
    for json_path in sorted(glob.glob(os.path.join(src, "*", "*", "*.json"))):
        family = os.path.basename(os.path.dirname(os.path.dirname(json_path)))
        style = style_of(json_path)
        stem = os.path.splitext(os.path.basename(json_path))[0]
        # Prefer -mono sheets when present; also accept plain / style-named.
        ok_stems = {
            family,
            f"{family}-{style}",
            f"{family}-mono",
            f"{family}-{style}-mono",
        }
        if stem not in ok_stems:
            continue
        if families and family not in families:
            continue
        found.append(json_path)

    if not found:
        family = os.path.basename(os.path.normpath(src))
        if not families or family in families:
            for style_dir in sorted(glob.glob(os.path.join(src, "*", ""))):
                style = os.path.basename(os.path.normpath(style_dir))
                for stem in (
                    f"{family}-{style}-mono",
                    f"{family}-mono",
                    f"{family}-{style}",
                    family,
                ):
                    direct = os.path.join(style_dir, stem + ".json")
                    if os.path.exists(direct):
                        found.append(direct)
                        break
    return found


def pick_preferred(sources):
    """One sheet per family/style: prefer a -mono stem when both exist."""
    by_key = {}
    for json_path in sources:
        family = os.path.basename(os.path.dirname(os.path.dirname(json_path)))
        style = style_of(json_path)
        stem = os.path.splitext(os.path.basename(json_path))[0]
        key = (family, style)
        is_mono = stem.endswith("-mono")
        prev = by_key.get(key)
        if prev is None or (is_mono and not prev[0]):
            by_key[key] = (is_mono, json_path)
    return [by_key[k][1] for k in sorted(by_key)]


def main():
    ap = argparse.ArgumentParser(
        description="Build console PSF fonts from PNG + JSON, trimmed to a charset."
    )
    ap.add_argument(
        "src",
        nargs="?",
        default="./src",
        help="src directory, a strike directory, or a .json file",
    )
    ap.add_argument(
        "out",
        nargs="?",
        help="directory to write .psfu[.gz] into (default: next to the JSON)",
    )
    ap.add_argument(
        "--charset",
        default="./console-charset.json",
        help="glyph allowlist JSON (default: ./console-charset.json)",
    )
    ap.add_argument(
        "--suffix",
        default="",
        help="extra filename suffix before the extension "
             "(e.g. 'hr' → quanta-strike-12-hr.psfu.gz)",
    )
    ap.add_argument(
        "--scale",
        type=int,
        default=1,
        metavar="N",
        help="integer nearest-neighbor upscale of each glyph (default 1). "
             "e.g. --scale 2 turns a 7×14 cell into 14×28",
    )
    ap.add_argument("--family", action="append", default=[], help="only this strike")
    ap.add_argument(
        "--no-gzip",
        action="store_true",
        help="write uncompressed .psfu instead of .psfu.gz",
    )
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.charset):
        raise SystemExit(f"error: charset file not found: {args.charset}")
    if args.scale < 1:
        raise SystemExit(f"error: --scale must be an integer ≥ 1 (got {args.scale})")

    charset, max_glyphs = load_charset(args.charset)
    sources = pick_preferred(find_sources(args.src, args.family))
    if not sources:
        raise SystemExit(f"error: no PNG+JSON strike sources found under {args.src}")

    compress = not args.no_gzip
    ext = ".psfu.gz" if compress else ".psfu"
    suffix = args.suffix.strip("-")
    suffix_part = f"-{suffix}" if suffix else ""
    scale_part = f"-{args.scale}x" if args.scale > 1 else ""

    for json_path in sources:
        if args.out:
            family = os.path.basename(os.path.dirname(os.path.dirname(json_path)))
            style = style_of(json_path)
            stem = family if style == "regular" else f"{family}-{style}"
            out_path = os.path.join(args.out, stem + suffix_part + scale_part + ext)
        else:
            out_path = os.path.splitext(json_path)[0] + suffix_part + scale_part + ext
        convert(
            json_path,
            out_path,
            charset,
            max_glyphs,
            quiet=args.quiet,
            compress=compress,
            scale=args.scale,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
