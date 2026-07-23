#!/usr/bin/env bash
#
# build-package.sh — assemble the npm package from a finished build.
#
# The package ships fonts and CSS. Nothing else. No JavaScript, no build step for
# the consumer. It copies the WOFF2 files into package/fonts/, generates the CSS
# that points at them, and copies the licence, which the OFL requires.
#
# Run ./build.sh first. This script only moves finished files around.
#
#   ./build-package.sh            # assemble package/
#   ./build-package.sh --pack     # assemble, then npm pack to inspect the tarball
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WOFF2_DIR="$SCRIPT_DIR/build/woff2"
PKG_DIR="$SCRIPT_DIR/package"
FONTS_DIR="$PKG_DIR/fonts"
LICENSE_FILE="$SCRIPT_DIR/OFL.txt"

DO_PACK=false
[ "${1:-}" = "--pack" ] && DO_PACK=true

if [ ! -d "$WOFF2_DIR" ]; then
    echo "error: $WOFF2_DIR not found. Run ./build.sh first." >&2
    exit 1
fi

# Wipe the generated parts. Everything else in package/ is source.
rm -rf "$FONTS_DIR" "$PKG_DIR/theme" "$PKG_DIR/scale"
rm -f "$PKG_DIR"/*.css
mkdir -p "$FONTS_DIR"

# Flatten both variants into one fonts/ folder. Filenames already carry the
# variant, so nothing collides.
count=0
for f in "$WOFF2_DIR"/quanta-strike/*.woff2 "$WOFF2_DIR"/quanta-strike-mono/*.woff2; do
    [ -e "$f" ] || continue
    cp "$f" "$FONTS_DIR/"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "error: no woff2 files found under $WOFF2_DIR" >&2
    exit 1
fi

# CSS pointing at the flat fonts/ folder.
python3 "$SCRIPT_DIR/scripts/generate-css.py" "$WOFF2_DIR" \
    --out "$PKG_DIR" --flat --url-prefix "fonts/"

# Per-strike files publish as 16.css, not quanta-strike-16.css, so an import
# reads "quanta-strike/16.css". Digits only, so the utilities file
# below is not caught by this.
for f in "$PKG_DIR"/quanta-strike-[0-9]*.css; do
    [ -e "$f" ] || continue
    size="$(basename "$f" .css)"
    size="${size#quanta-strike-}"
    mv "$f" "$PKG_DIR/$size.css"
done

# Same idea: "quanta-strike/utilities.css" / "quanta-strike/mono.css".
# Per-strike files (16.css, 16-mono.css) are renamed above; the all-strikes
# mono core and both utilities files need their publish names here.
mv "$PKG_DIR/quanta-strike-utilities.css" "$PKG_DIR/utilities.css"
mv "$PKG_DIR/quanta-strike-utilities-mono.css" "$PKG_DIR/utilities-mono.css"
mv "$PKG_DIR/quanta-strike-mono.css" "$PKG_DIR/mono.css"
# utilities-mono was generated against the pre-rename core name.
python3 -c "
from pathlib import Path
p = Path('$PKG_DIR/utilities-mono.css')
p.write_text(p.read_text().replace('./quanta-strike-mono.css', './mono.css'))
"

cp "$LICENSE_FILE" "$PKG_DIR/"

# The fonts carry the release number, so the package copies it from them. One
# source of truth, and the package can never drift from what it ships.
python3 - "$SCRIPT_DIR/build/ttf/quanta-strike" "$PKG_DIR/package.json" <<'PY'
import glob, json, os, sys

ttf_dir, pkg_path = sys.argv[1], sys.argv[2]

fonts = sorted(glob.glob(os.path.join(ttf_dir, "*.ttf")))
if not fonts:
    print(f"warning: no TTFs in {ttf_dir}, leaving the package version alone")
    sys.exit(0)

import fontforge
font = fontforge.open(fonts[0])
raw = (font.version or "").strip()
font.close()

# FontForge writes a fixed-point string like "001.000". Strip the padding and
# pad out to three semver parts.
parts = [p for p in raw.split(".") if p != ""]
try:
    numbers = [int(p) for p in parts]
except ValueError:
    print(f"warning: cannot read '{raw}' as a version, leaving the package alone")
    sys.exit(0)
while len(numbers) < 3:
    numbers.append(0)
version = ".".join(str(n) for n in numbers[:3])

pkg = json.load(open(pkg_path))
old = pkg.get("version")
if old == version:
    print(f"Version: {version} (fonts and package agree)")
    sys.exit(0)

pkg["version"] = version
with open(pkg_path, "w") as fh:
    json.dump(pkg, fh, indent=2)
    fh.write("\n")
print(f"Version: {old} -> {version}, copied from the fonts (was '{raw}')")
PY

echo
echo "Packaged $count font file(s) into $PKG_DIR"
echo "Version: $(node -p "require('$PKG_DIR/package.json').version" 2>/dev/null || echo "see package.json")"
echo
echo "Next:"
echo "  cd package && npm publish"
echo
echo "The version above came from the fonts. To change it, rebuild the fonts with"
echo "a version bump (./build.sh, option 1-4) and run this script again."

if [ "$DO_PACK" = true ]; then
    echo
    (cd "$PKG_DIR" && npm pack --dry-run)
fi
