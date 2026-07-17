#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Convert a tree of .ttf fonts to .woff2, mirroring the directory structure.

Usage:
  fontforge -lang=py -script convert-woff2.py <ttf-root> <woff2-root> [--include-nerd]
  e.g. fontforge -lang=py -script convert-woff2.py build/ttf build/woff2

For every build/ttf/<group>/<font>.ttf it writes build/woff2/<group>/<font>.woff2.

By default, "*-nerd" groups are SKIPPED — Nerd Font files are large (~2 MB) and
rarely wanted as web fonts. Pass --include-nerd to convert them too.

Uses FontForge's native WOFF2 export, so no extra dependencies are required.
"""
import os
import sys

try:
    import fontforge
except ImportError:
    sys.exit("FontForge module could not be loaded.")


def main():
    args = [a for a in sys.argv[1:]]
    include_nerd = '--include-nerd' in args
    positional = [a for a in args if not a.startswith('--')]

    if len(positional) < 2:
        sys.exit("Usage: fontforge -lang=py -script convert-woff2.py <ttf-root> <woff2-root> [--include-nerd]")

    ttf_root = os.path.abspath(positional[0])
    woff2_root = os.path.abspath(positional[1])

    if not os.path.isdir(ttf_root):
        sys.exit(f"Input directory not found: {ttf_root}")

    count = 0
    skipped = 0
    for dirpath, dirs, files in os.walk(ttf_root):
        # Optionally prune Nerd Font groups
        if not include_nerd:
            pruned = [d for d in dirs if d.endswith('-nerd')]
            for d in pruned:
                dirs.remove(d)
                skipped += 1

        for name in sorted(files):
            if not name.lower().endswith(".ttf"):
                continue
            src = os.path.join(dirpath, name)
            rel = os.path.relpath(src, ttf_root)
            dst = os.path.join(woff2_root, os.path.splitext(rel)[0] + ".woff2")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            f = fontforge.open(src)
            f.generate(dst)
            f.close()
            print(f"  {rel}  ->  woff2/{os.path.splitext(rel)[0]}.woff2")
            count += 1

    if count == 0:
        sys.exit(f"No .ttf files converted under {ttf_root}")
    msg = f"Converted {count} font(s) to WOFF2."
    if skipped and not include_nerd:
        msg += f" (skipped {skipped} '-nerd' group(s); use --include-nerd to convert them)"
    print(msg)


if __name__ == "__main__":
    main()
