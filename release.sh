#!/usr/bin/env bash
#
# release.sh — package a finished ./build.sh run into release zips.
#
# Doesn't build anything. Run ./build.sh yourself first (interactively, so
# you get the version-bump prompt), then run this to zip what it produced:
#   quanta-strike.zip              ttf + woff2, both variants, NO nerd
#   quanta-strike-nerd.zip         mono-nerd ttf only — only if build/ttf/quanta-strike-mono-nerd exists
#   quanta-strike-console-psf.zip  console PSF fonts — only if build/psf exists
#
# Filenames are unversioned — the release TAG carries the version, so the
# Homebrew cask URL only needs to change `v#{version}` between releases.
#
#   ./build.sh              # answer the version prompt yourself, --nerd-fonts / --psf as wanted
#   ./release.sh            # zips whatever build/ has

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ -d build/ttf/quanta-strike ] || {
    echo "error: build/ttf/quanta-strike not found — run ./build.sh first" >&2
    exit 1
}

DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$DIST_DIR/stage"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# --- base zip: everything in build/ttf + build/woff2 except the nerd ttfs ---
base_stage="$STAGE_DIR/quanta-strike"
mkdir -p "$base_stage"
cp -R build/ttf "$base_stage/ttf"
rm -rf "$base_stage/ttf/quanta-strike-mono-nerd"
cp -R build/woff2 "$base_stage/woff2"
(cd "$STAGE_DIR" && zip -qr "$DIST_DIR/quanta-strike.zip" quanta-strike)
rm -rf "$STAGE_DIR"

# --- nerd zip: mono-nerd ttf only, if it was built ---
if [ -d build/ttf/quanta-strike-mono-nerd ]; then
    nerd_stage="$STAGE_DIR/quanta-strike"
    mkdir -p "$nerd_stage/ttf"
    cp -R build/ttf/quanta-strike-mono-nerd "$nerd_stage/ttf/"
    (cd "$STAGE_DIR" && zip -qr "$DIST_DIR/quanta-strike-nerd.zip" quanta-strike)
    rm -rf "$STAGE_DIR"
else
    echo "skip: quanta-strike-nerd.zip (build/ttf/quanta-strike-mono-nerd not built — pass --nerd-fonts to build.sh to include it)"
fi

# --- console psf zip, if it was built ---
if [ -d build/psf ]; then
    psf_stage="$STAGE_DIR/quanta-strike"
    mkdir -p "$psf_stage/psf"
    cp -R build/psf/. "$psf_stage/psf/"
    (cd "$STAGE_DIR" && zip -qr "$DIST_DIR/quanta-strike-console-psf.zip" quanta-strike)
    rm -rf "$STAGE_DIR"
else
    echo "skip: quanta-strike-console-psf.zip (build/psf not built — pass --psf to build.sh to include it)"
fi

echo
echo "release zips in $DIST_DIR:"
ls -la "$DIST_DIR"/*.zip
echo
VERSION="$(cat VERSION)"
echo "next (run yourself — this script doesn't touch git or GitHub):"
echo "  gh release create v$VERSION $DIST_DIR/*.zip --title \"quanta strike v$VERSION\""
echo "  # or, if the release already exists:"
echo "  gh release upload v$VERSION $DIST_DIR/*.zip"
echo
echo "sha256 for the Homebrew casks:"
shasum -a 256 "$DIST_DIR"/*.zip
