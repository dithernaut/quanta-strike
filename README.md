# quanta-strike

A pixel typeface authored with the [yal.cc pixel-font tool](https://yal.cc/tools/pixel-font/),
shipped as four **strikes** — `quanta-strike-8`, `-12`, `-16`, `-20` — plus a
build pipeline that adds proper metadata and derived OpenType features.

## What a "strike" is

Each strike is tuned for one rendering size:

| strike | use at `font-size` |
|--------|--------------------|
| `quanta-strike-8`  | `8px`  |
| `quanta-strike-12` | `12px` |
| `quanta-strike-16` | `16px` |
| `quanta-strike-20` | `20px` |

They are **separate font families** (not weights/styles of one family) so each is
trivial to target in CSS.

### The pixel-alignment guarantee

Every strike uses a fixed grid: **1 source pixel = 128 font units**, and the em is
an exact whole number of pixels (`em = strike# × 128`). Rendered at its nominal
size, one pixel is therefore exactly **1 CSS px**:

```
pixel size in CSS px = font-size × 128 / em = N × 128 / (N × 128) = 1.0
```

So a strike used at its size lands perfectly on the device pixel grid, and one
pixel of `quanta-strike-8` @ 8px is the same size as one pixel of
`quanta-strike-12` @ 12px — they align.

**Because of this, the pipeline never alters vertical metrics** (em / ascent /
descent / line gap). It only rewrites naming/metadata and adds glyph features.
Changing the em (e.g. "tightening" the line height) would push pixels off the
grid and blur them, so it is deliberately not done here.

```css
@font-face { font-family: "quanta-strike-8";  src: url("quanta-strike-8-regular.ttf");  }
@font-face { font-family: "quanta-strike-12"; src: url("quanta-strike-12-regular.ttf"); }

.qs-8  { font-family: "quanta-strike-8";  font-size: 8px;  line-height: 1; }
.qs-12 { font-family: "quanta-strike-12"; font-size: 12px; line-height: 1; }
```

## Layout

```
src/                     # authored fonts (input) — never modified by the build
  quanta-strike-8/regular/quanta-strike-8.{json,png,ttf}
  quanta-strike-12/...
  ...
build/                   # generated output (git-ignored)
patcher/                 # vendored Nerd Fonts font-patcher + glyph sets
```

## Requirements

- [FontForge](https://fontforge.org/) with Python bindings (`brew install fontforge`)
- Python 3

## Build

### Interactive

```bash
./build.sh
```

Walks you through: select strikes → metadata (names, type, version bump,
license/URLs) → optional features (small caps, old-style figures) → optional
Nerd Font variants.

### Manual / scripted

```bash
# 1) Metadata — writes build/<strike>/<strike>-regular.ttf
fontforge -lang=py -script font-metadata-patcher.py \
    --src src --output build \
    --lowercase --type monospace \
    --license "(c) 2026 dithernaut" \
    --designerurl "https://dithernaut.com"

# 2) Small caps (smcp + c2sc) from existing glyphs
python3 add-small-caps.py --src build --source phonetic     # or: lowercase | capital

# 3) Old-style figures (onum) from existing glyphs
python3 add-old-style-figures.py --src build --source circled   # or: superscript | subscript | lining

# 4) Nerd Font variants -> build/<strike>-nerd/<strike>-nerd-regular.ttf
./generate            # all built strikes
./generate-nerd-fonts quanta-strike-8   # a single strike
```

## Scripts

| script | does |
|--------|------|
| `font-metadata-patcher.py` | Sets family/style names, OS-2, weight/width, version, copyright & URLs. **Never touches metrics** (preserves pixel alignment). |
| `add-small-caps.py`        | Adds `smcp`/`c2sc` OpenType features, sourced from phonetic small-caps, lowercase, or capital glyphs. |
| `add-old-style-figures.py` | Adds the `onum` feature, mapping digits to circled / superscript / subscript figures. |
| `generate-nerd-fonts`      | Patches a built strike with Nerd Font icons → its own `<strike>-nerd` family. |
| `generate`                 | Runs the Nerd Font patcher over every built strike. |
| `rename-family.py`         | Helper: sets a font's family/style naming while preserving other metadata. |

## Features

- **Metadata** — per-strike families, semver, license/copyright, designer/license URLs.
- **Small caps** — `smcp` (lowercase→small caps) and `c2sc` (caps→small caps), built from the font's own glyphs.
- **Old-style figures** — `onum`, built from the font's own alternate digit glyphs.
- **Nerd Fonts** — icon-patched variants for terminal use.
