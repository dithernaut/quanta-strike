# quanta-strike

A pixel typeface drawn as pixel sheets and compiled straight to fonts, shipped as a
set of **strikes** — `quanta-strike-8`, `-12`, `-16`, `-20`, `-24` — plus a build
pipeline that adds proper metadata and derived OpenType features.

## What a "strike" is

Each strike is tuned for one rendering size:

| strike | use at `font-size` |
|--------|--------------------|
| `quanta-strike-8`  | `8px`  |
| `quanta-strike-12` | `12px` |
| `quanta-strike-16` | `16px` |
| `quanta-strike-20` | `20px` |
| `quanta-strike-24` | `24px` |

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
@font-face { font-family: "quanta-strike-8";  src: url("woff2/quanta-strike/quanta-strike-8-regular.woff2")  format("woff2"); }
@font-face { font-family: "quanta-strike-12"; src: url("woff2/quanta-strike/quanta-strike-12-regular.woff2") format("woff2"); }

.qs-8  { font-family: "quanta-strike-8";  font-size: 8px;  line-height: 1; }
.qs-12 { font-family: "quanta-strike-12"; font-size: 12px; line-height: 1; }
```

## Layout

```
src/                              # authored art (input) — never modified by the build
  quanta-strike-8/regular/quanta-strike-8.{json,png}
  quanta-strike-12/...
  ...
build/                            # generated output (git-ignored)
  tmp/src/                        #   TTFs compiled from the PNG + JSON (staging)
  ttf/
    quanta-strike/                #   all base strikes, one folder
    quanta-strike-nerd/           #   Nerd Font-patched strikes
  woff2/
    quanta-strike/                #   web fonts (base strikes; nerd excluded by default)
patcher/                          # vendored Nerd Fonts font-patcher + glyph sets
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
license/URLs) → optional features (small caps, old-style figures, Nerd Fonts,
WOFF2).

### Manual / scripted

```bash
# 0) Compile each strike's PNG + JSON into a TTF (src/ stays art-only)
python3 png-to-ttf.py src/quanta-strike-8/regular/quanta-strike-8.json \
    build/tmp/src/quanta-strike-8/regular

# 1) Metadata — all strikes into one folder: build/ttf/quanta-strike/
fontforge -lang=py -script font-metadata-patcher.py \
    --src build/tmp/src --output build/ttf/quanta-strike --flat \
    --lowercase --type monospace \
    --license "(c) 2026 dithernaut" \
    --designerurl "https://dithernaut.com"

# 2) Small caps (smcp + c2sc) from existing glyphs, in place
python3 add-small-caps.py --src build/ttf/quanta-strike --source phonetic      # or: lowercase | capital

# 3) Old-style figures (onum) from existing glyphs, in place
python3 add-old-style-figures.py --src build/ttf/quanta-strike --source circled # or: superscript | subscript | lining

# 4) Nerd Fonts -> build/ttf/quanta-strike-nerd/ (each keeps its own "<strike>-nerd" family)
#    build.sh runs this last and only for the strikes you selected
./generate                                       # all strikes
./generate-nerd-fonts build/ttf/quanta-strike    # equivalent, explicit
./generate-nerd-fonts build/ttf/quanta-strike build/ttf/quanta-strike-nerd quanta-strike-8  # one strike

# 5) WOFF2 -> build/woff2/  (base strikes only by default)
fontforge -lang=py -script convert-woff2.py build/ttf build/woff2
fontforge -lang=py -script convert-woff2.py build/ttf build/woff2 --include-nerd   # also convert nerd
```

## Scripts

| script | does |
|--------|------|
| `png-to-ttf.py`            | Compiles a strike's PNG + JSON pixel sheet into a TTF (1 pixel = 128 units). The TTF is a build artifact, so `src/` only holds the art. |
| `font-metadata-patcher.py` | Sets family/style names, OS-2, weight/width, version, copyright & URLs. `--flat` writes all strikes into one folder. **Never touches metrics** (preserves pixel alignment). |
| `add-small-caps.py`        | Adds `smcp`/`c2sc` OpenType features, sourced from phonetic small-caps, lowercase, or capital glyphs. |
| `add-old-style-figures.py` | Adds the `onum` feature, mapping digits to circled / superscript / subscript figures. |
| `generate-nerd-fonts`      | Patches every `.ttf` in a folder with Nerd Font icons into a sibling `-nerd` folder. |
| `generate`                 | Runs the Nerd Font patcher over `build/ttf/quanta-strike`. |
| `convert-woff2.py`         | Mirrors `build/ttf/**` to `build/woff2/**` as WOFF2 (skips `-nerd` unless `--include-nerd`). |
| `rename-family.py`         | Helper: sets a font's family/style naming while preserving other metadata. |

## Features

- **Metadata** — per-strike families, semver, license/copyright, designer/license URLs.
- **Small caps** — `smcp` (lowercase→small caps) and `c2sc` (caps→small caps), built from the font's own glyphs.
- **Old-style figures** — `onum`, built from the font's own alternate digit glyphs.
- **Nerd Fonts** — icon-patched variants for terminal use.
- **WOFF2** — compact web fonts (base strikes by default; add `--include-nerd` for the icon variants).

## Thanks
Thanks to [yal.cc](https://yal.cc) for the inspiration on how to make this algorithm. Check out [YAL's pixel font generator](https://yal.cc/tools/pixel-font/) live.
