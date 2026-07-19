# quanta-strike

A modern pixel typeface. I draw each size by hand. Most fonts take one design and stretch
it to every size. quanta-strike does not. It ships a family of *strikes*. Each strike is
its own pixel design, drawn for one target size. Text stays crisp at the size you drew it
for. It resamples nothing.

The build works straight from pixel sheets. Each strike is a PNG plus a JSON file. A
pipeline compiles that pair into fonts. It adds proper metadata and extra OpenType
features along the way.

📖 **Read the full story:** [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling)

> This is a starting point. The family will grow. Today it ships **8 strikes**: **6, 10,
> 12, 14, 16, 18, 20, and 32**. Use each one at its matching pixel size.

## Why it exists

A pixel font has one job. Every pixel must land on the screen's pixel grid. Then the art
stays sharp. Scaling breaks this.

A normal font is one set of outlines. The renderer resizes those outlines to any size you
ask for. Smooth typefaces handle that fine. A pixel design does not. It looks right at one
size only. That size lines its pixels up with the device grid. Ask for another size and
the renderer has to resample. Pixel edges fall between device pixels. The rasterizer
smears them with anti-aliasing. Your crisp blocky art turns muddy. One pixel design cannot
stay sharp at 12px and 16px and 20px. The grids do not line up.

quanta-strike takes a different path. It stops scaling. I draw each size on purpose. Every
strike sits on a grid where 1 source pixel equals 128 font units. The em holds a whole
number of pixels. For `quanta-strike-N` the em is N times 128. Render a strike at its own
size and one source pixel equals exactly 1 CSS px:

```
pixel size in CSS px = font-size × 128 / em = N × 128 / (N × 128) = 1.0
```

So each strike lands on the device pixel grid at its own size. No resampling. No blur.
Every strike shares the same units per pixel. One pixel of `quanta-strike-12` at 12px
matches the physical size of one pixel of `quanta-strike-20` at 20px. I draw them apart.
They still line up.

## What a "strike" is

Each strike targets one rendering size. Each strike is its own font family. It is not a
weight or a style of a shared family. So you target it directly in CSS.

| strike | use at `font-size` | rem @ 16px base |
|--------|--------------------|-----------------|
| `quanta-strike-6`  | `6px`  | `0.375rem` |
| `quanta-strike-10` | `10px` | `0.625rem` |
| `quanta-strike-12` | `12px` | `0.75rem`  |
| `quanta-strike-14` | `14px` | `0.875rem` |
| `quanta-strike-16` | `16px` | `1rem`     |
| `quanta-strike-18` | `18px` | `1.125rem` |
| `quanta-strike-20` | `20px` | `1.25rem`  |
| `quanta-strike-32` | `32px` | `2rem`     |

Size and family go together. A rem value gives you one pixel per pixel only with its
matching family. Bind them in one CSS class. Never expose the size on its own.

### Two variants per strike

The build makes every strike twice from the same art:

- **proportional** (`quanta-strike-N`) trims each glyph to its own ink. Use it for body
  text and UI.
- **mono** (`quanta-strike-N-mono`) fixes the advance width. Use it for code, terminals,
  and TUIs. This variant also gets Nerd Font icons.

Both stay separate families. Mono is not a style of the proportional family. Both hold the
pixel grid. Trimming only drops whole empty pixel columns. Widths stay on the 128 grid.
The cross-strike pixel never moves.

### The pixel-alignment guarantee

Landing on the grid is the whole point. So the pipeline never changes vertical metrics. It
leaves the em, ascent, descent, and line gap alone. It only rewrites naming and metadata
and adds glyph features. Changing the em would push pixels off the grid and blur them. So
it never does.

```css
@font-face { font-family: "quanta-strike-16";      src: url("woff2/quanta-strike/quanta-strike-16-regular.woff2")      format("woff2"); }
@font-face { font-family: "quanta-strike-16-mono";  src: url("woff2/quanta-strike-mono/quanta-strike-16-mono-regular.woff2") format("woff2"); }

/* proportional, for body text */
.qs-16      { font-family: "quanta-strike-16";      font-size: 16px; line-height: 1; }
/* mono, for code */
.qs-16-mono { font-family: "quanta-strike-16-mono"; font-size: 16px; line-height: 1; }
```

The fonts ship with tight line metrics based on the ink. Set `line-height` yourself if you
want uniform leading.

## Layout

```
src/                              # authored art. the build never touches it
  quanta-strike-6/regular/quanta-strike-6.{json,png}
  quanta-strike-10/...
  ...
build/                            # generated output. git-ignored
  tmp/                            #   TTFs compiled from PNG + JSON. staging, removed on success
  ttf/
    quanta-strike/                #   proportional strikes, one folder
    quanta-strike-mono/           #   mono strikes
    quanta-strike-mono-nerd/      #   Nerd Font-patched mono strikes. opt-in
  woff2/
    quanta-strike/                #   proportional web fonts
    quanta-strike-mono/           #   mono web fonts
patcher/                          # vendored Nerd Fonts font-patcher + glyph sets
```

[SOURCE-FORMAT.md](SOURCE-FORMAT.md) documents the `src/*.json` pixel-sheet format field by
field.

## Requirements

- [FontForge](https://fontforge.org/) with Python bindings (`brew install fontforge`)
- Python 3

## Build

```bash
./build.sh                       # interactive
./build.sh --defaults            # non-interactive. take every default, ask nothing (-y works too)
./build.sh -y --nerd-fonts       # add Nerd Font icons (mono variant, the slow step)
./build.sh -y --spacing 2        # force a fixed 2px proportional gap on every strike
```

The interactive build walks you through it. You pick strikes and optional features. The
build makes both variants for each strike. It does proportional first, then mono. Then it
writes WOFF2 for both. Then it patches Nerd Fonts for the mono variant, but only if you opt
in.

`--defaults` answers every prompt with its default. It builds all strikes. Use it for CI or
a repeatable release. The defaults are not all "yes". Version keeps. Nerd Fonts stay off.
That is why the flag is not `--yes`. Each prompt still prints the answer it took, so the log
stays clear.

The build reads metadata from `default-metadata.json`: author, licence, URLs, and type. So
it does not ask. Edit that file to change it. Delete it to get the prompts back. The build
always asks for the version bump. The version is a per-release choice, so it stays out of
the defaults.

## Scripts

| script | does |
|--------|------|
| `png-to-ttf.py`            | Compiles a strike's PNG plus JSON into a TTF. 1 pixel becomes 128 units. The TTF is a build artifact, so `src/` holds only the art. `--proportional` trims each glyph instead of using the mono advance. |
| `default-metadata.json`    | Not a script. Holds the author, licence, and URL defaults `build.sh` applies instead of prompting. Delete it to answer by hand. |
| `font-metadata-patcher.py` | Sets family and style names, OS-2, weight, width, version, copyright, and URLs. `--flat` writes all strikes of one variant into one folder. It never touches metrics, so pixel alignment holds. |
| `add-small-caps.py`        | Adds the `smcp` and `c2sc` features from phonetic small-caps, lowercase, or capital glyphs. |
| `add-old-style-figures.py` | Adds the `onum` feature. It maps digits to circled, superscript, or subscript figures. |
| `anchor-em.py`             | Runs the pixel-perfect step. It re-anchors the em to N times 128 and sets ink-based line metrics. It never rescales glyphs. |
| `pixel-scale.py`           | Scales every strike up by one shared factor on top of anchor. The default factor 1 does nothing. |
| `verify-pixel-grid.py`     | Guards the build. It checks that every strike shares the same pixel and every glyph sits on the 128 grid. The build stops if this fails. |
| `generate-nerd-fonts`      | Patches every `.ttf` in a folder with Nerd Font icons. It writes them to a sibling `-nerd` folder. |
| `convert-woff2.py`         | Mirrors `build/ttf` to `build/woff2` as WOFF2. It skips `-nerd` unless you pass `--include-nerd`. |
| `rename-family.py`         | Sets a font's family and style naming. It keeps the rest of the metadata. |

## Features

- **Two variants:** proportional (`quanta-strike-N`) for body text, mono (`quanta-strike-N-mono`) for code.
- **Metadata:** per-strike families, semver, license and copyright, designer and license URLs.
- **Small caps:** the build adds `smcp` and `c2sc` from the font's own glyphs.
- **Old-style figures:** the build adds `onum` from the font's own alternate digits.
- **Nerd Fonts:** icon-patched mono strikes for the terminal. Opt in to get them.
- **WOFF2:** compact web fonts for both variants. The build skips the Nerd variants by default.

## Licence

Google Fonts accepts only OFL-1.1, Apache-2.0, or UFL. So the fonts use **OFL-1.1**, the
SIL Open Font License. OFL allows redistribution, modification, bundling, and donations. It
does not allow selling the font on its own.

The licence lives in [`OFL.txt`](OFL.txt) at the repo root. `build.sh` copies it into every
output folder that holds fonts. The OFL requires the licence to travel with them, so never
ship a font folder without it.

## Thanks

Thanks to [yal.cc](https://yal.cc) for the inspiration on the underlying algorithm. Check
out [YAL's pixel font generator](https://yal.cc/tools/pixel-font/).
