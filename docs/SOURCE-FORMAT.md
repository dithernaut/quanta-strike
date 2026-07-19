# quanta-strike source format (`src/*/*.json` + `.png`)

Each strike is a **pixel sheet**: one PNG (the drawn glyphs) plus one JSON (the grid
geometry and font settings) sitting next to it, at
`src/quanta-strike-N/regular/quanta-strike-N.{png,json}`. `scripts/png-to-ttf.py` is the only
thing that reads this pair; it turns them into the strike's TTF (a build artifact). The
PNG + JSON are the **only real source** — see [AGENTS.md](AGENTS.md) for the pipeline and
the pixel invariant.

This document is the authoritative shape — if it disagrees with `scripts/png-to-ttf.py`, the
script wins.

---

## The grid

Glyphs are laid out on a regular grid of cells. Cell `(row, col)` has its **top-left** at

```
x = glyph-ofs-x + col * (glyph-width  + glyph-sep-x)
y = glyph-ofs-y + row * (glyph-height + glyph-sep-y)
```

`row`/`col` come from `in-glyphs`: each string is one row, and each **character** is one
cell, advancing the column by one **per codepoint** (an astral character still takes a
single cell). The PNG canvas is usually larger than the grid — the extra area is ignored,
so image dimensions need not divide evenly by the cell count.

Within a cell, a pixel at cell-column `c`, cell-row `r` becomes a `font-px-size`-unit
square whose lower-left maps to

```
x = (c - glyph-base-x) * font-px-size      # mono; proportional shifts to a 0 bearing
y = (glyph-baseline - r) * font-px-size
```

A pixel counts as **ink** per `glyph-color` (default `black` = a weighted-luminance
threshold, `alpha >= 128 and 3r + 5g + b <= 1024`, *not* a pure black test — so light or
transparent alignment guides drawn in the art stay out of the font, but a dark guide
would become ink).

---

## Keys `scripts/png-to-ttf.py` reads

### Grid geometry (required)

| Key | Type | Meaning |
|---|---|---|
| `in-glyphs` | array of strings | Rows of the grid, in PNG order. One cell per codepoint. Only the **first** space in the whole sheet becomes a glyph; later spaces just leave a gap. |
| `glyph-width` | int | Cell width in pixels. In the proportional variant this is conceptually the **max** width. |
| `glyph-height` | int | Cell height in pixels. |
| `glyph-ofs-x` / `glyph-ofs-y` | int | Grid origin — top-left of cell `(0,0)`. |
| `glyph-sep-x` / `glyph-sep-y` | int | Gap (px) between adjacent cells. |
| `glyph-base-x` | int | The cell column that maps to pen `x = 0` (the left side bearing origin) in the mono variant. |
| `glyph-baseline` | int | The cell **row** that sits on the baseline. |

### Font settings (required)

| Key | Type | Meaning |
|---|---|---|
| `font-px-size` | int | Font units per pixel — **always `128`**. This is THE invariant; do not change it. |
| `font-em-square` | int | The em, `= N × 128` for strike-N. The strike size is derived as `N = font-em-square / font-px-size`. |
| `contour-type` | string | Must be `"pixel"` (one square per ink pixel, unmerged). Any other value is an error. |

### Font settings (optional)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `glyph-color` | string | `"black"` | Ink test: `black` (luminance ≤ threshold), `white` (above it), `opaque` (any `alpha ≥ 128`), `color` (any `alpha > 0`). An unknown value auto-detects from the top-left pixel. |
| `glyph-spacing` | int | `0` | Added to `glyph-width` for the **mono** advance: `(glyph-width + glyph-spacing) × 128`. Also the advance given to empty glyphs (space, hidden) in **both** variants. Left at `0` for the default mono packing. |
| `spacing` (alias `prop-gap`) | int or `"auto"` | `"auto"` | **Proportional variant only** — the inter-glyph gap for this strike (`advance = (ink-width + gap) × 128`). `"auto"` scales with size: 1px for N < 11, 2px for 11–18, 3px for N > 18. Overridden by the build's `--spacing`; ignored by the mono variant (which uses `glyph-spacing`). See [AGENTS.md](AGENTS.md) for the full precedence. |
| `font-is-upper` | bool | `false` | If `true`, every uppercase glyph is **also** copied onto its lowercase codepoint (a caps-only sheet that fills both cases). |
| `overrides` | array of strings | `[]` | Per-glyph rules, one per line; `#` starts a comment. Only **`hide <glyphs>`** is implemented — it keeps the advance but drops the ink. `\s` expands to every space codepoint (so `hide \s` blanks the spaces while keeping their width). Escapes: `\uXXXX`, `\u{…}`, `\xXX`, and `\0 \r \n \t \" \' \- \\`. Any other rule is warned about, not applied. |

### Vertical metrics (required, but re-anchored)

These are **required** (`scripts/png-to-ttf.py` reads them directly and errors if missing), but
`scripts/anchor-em.py` later re-anchors the em to `N × 128` and derives the final metrics from the
measured ink — so their exact values here are not critical. The outlines, advances, and
cmap are what must be right.

| Key | Type | Meaning |
|---|---|---|
| `font-ascend` | int | Initial ascent, in font units. |
| `font-descend` | int | Initial descent, in font units — **negative** in the file (e.g. `-384`); the sign is flipped internally. |

(`font-em-square` and `font-px-size`, listed under *Font settings (required)* above, are
also part of the vertical metrics.)

### Naming seeds (overwritten downstream)

These give the font sensible initial names; the metadata patcher overwrites them from
`scripts/default-metadata.json`, so they are only a fallback.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `font-name` | string | out-dir basename | Family name. |
| `font-style` | string | `"Regular"` | Style/weight name. |
| `font-author` | string | `""` | Combined with `font-copy` into the copyright notice (name ID 0) — set explicitly so FontForge doesn't ship the OS account's real name. |
| `font-copy` | string | `""` | See `font-author`. |

---

## Variant-specific sheets

By default both the mono and proportional variants build from the one
`quanta-strike-N.{png,json}`. A strike may optionally ship a dedicated **mono** sheet at
`quanta-strike-N-mono.{png,json}` (same directory); when present, the mono variant builds
from it while the proportional variant still uses the plain sheet. With no `-mono` sheet,
both share the plain source. (General rule: a variant with a non-empty suffix uses
`<family><suffix>.{png,json}` when both files exist.)

---

## Minimal example

```json
{
  "in-glyphs": [
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    " 0123456789.,:;!?"
  ],
  "glyph-color": "black",
  "glyph-width": 8,
  "glyph-height": 17,
  "glyph-ofs-x": 1,
  "glyph-ofs-y": 1,
  "glyph-sep-x": 1,
  "glyph-sep-y": 1,
  "glyph-base-x": 0,
  "glyph-baseline": 14,
  "glyph-spacing": 0,
  "spacing": "auto",

  "font-px-size": 128,
  "font-em-square": 1792,
  "font-ascend": 1408,
  "font-descend": -384,
  "contour-type": "pixel",
  "font-is-upper": false,

  "font-name": "quanta-strike-14",
  "font-style": "Regular",
  "font-author": "dithernaut",
  "font-copy": "(c)",

  "overrides": ["hide \\s"]
}
```

Build one strike standalone with:

```
python3 scripts/png-to-ttf.py src/quanta-strike-14/regular/quanta-strike-14.json out/
python3 scripts/png-to-ttf.py --proportional src/quanta-strike-14/regular/quanta-strike-14.json out/
```
