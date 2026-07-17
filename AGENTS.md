# quanta-strike — pixel font build pipeline

quanta-strike is a pixel font from the yal.cc pixel-font tool. The rules below were
worked out carefully and are non-negotiable unless the user says otherwise. Read this
before doing anything.

## What it is
- A family of **strikes** — one design per target size: `quanta-strike-6`, `-10`, `-12`,
  `-14`, `-16`, `-18`, `-20` (more may exist). Each strike is its **own font family**
  named `quanta-strike-N`. They are NOT weights/styles of one family.
- Source art comes from yal.cc (vendored in `pixelfont/`): each strike is a PNG + JSON
  in `src/quanta-strike-N/`. `png-to-ttf.py` turns that pair into the TTF, so the TTF
  is a **build artifact** — the PNG + JSON are the only real source. (Historically the
  TTF was made by hand in the yal web tool; that step is now scripted.)

## THE hard invariant (never break this)
- **1 pixel = 128 font units**, always. Glyph coordinates are multiples of 128.
- **em (unitsPerEm) = N × 128** for strike-N. So at font-size N px, one source pixel
  renders at exactly **1.0 CSS px**.
- Consequence: at each strike's **native size** (N px), the pixel is the SAME physical
  size on EVERY strike. This cross-strike pixel identity is the whole point of the
  family and must survive end-to-end (metadata, features, WOFF2).
- Rendered pixel = `font-size / N`, **independent of the units-per-pixel number**. So
  128 is arbitrary — do NOT try to "scale by changing units per pixel", it's a no-op.

## Authoring rules (how a strike is drawn)
- Canvas may be TALLER than N. The body (caps, x-height, descenders) lives in the
  bottom N pixels = the em; **accents/diacritics are drawn ABOVE the em and overshoot**
  (keeps caps full-size and accents legible without shrinking anything).
- Baseline = the bottom edge of the LAST filled pixel of capital `A`.
- Let `D` = pixel rows below the baseline (descender depth). Then:
  ```
  em      = N × 128
  descent = D × 128
  ascent  = (N − D) × 128     # = em − descent; this is the em TOP
  ```
  Draw caps to height `(N − D)` so their top lands on the em top; accents go above it.
- Only `D` is read from the drawing; caps/accents just fit under or overshoot the
  ascent line. Everything else follows from `N` and `D`.

## Build pipeline (`build.sh` orchestrates; scripts run via FontForge python)
Order: `png-to-ttf → metadata → small caps → old-style figures → anchor-em →
(optional scale) → guard → WOFF2 → Nerd`.
- **png-to-ttf.py** — builds each strike's TTF from its PNG + JSON, replacing the old
  manual "save a TTF out of yal" step. A reimplementation of the vendored
  `pixelfont/script.js`, verified bit-identical to yal's own output on every strike
  (same contours, widths, cmap). Reads the geometry from the JSON, so the strike's cell
  grid / baseline / overrides are honoured; ink = `alpha >= 128 and 3r+5g+b <= 1024`
  (yal's "black" test) — so light/transparent alignment guides in the art stay out of
  the font, but a DARK guide would become ink. Emits 1 px = 128 units; never rescales.
  - **Never writes into `src/`.** build.sh stages the TTFs in **`build/tmp/src/`**,
    mirroring the `<family>/<style>/` layout the patcher expects; that dir is wiped at
    the start of every run and is gitignored with the rest of `build/`. `src/` holds the
    PNG + JSON only. Run standalone as `png-to-ttf.py <json> <out-dir>`; with no
    out-dir it writes next to the JSON, so pass one unless you want it in src/.
  - A strike with no PNG+JSON falls back to a prebuilt `src/<family>/regular/<family>.ttf`
    (copied into the staging dir); with neither, the build fails loudly.
- **font-metadata-patcher.py** — names/version/license/OS2 class etc. NEVER touches
  vertical metrics (keeps the pixel grid). `--flat` writes all strikes into one
  `build/ttf/quanta-strike/` folder.
- **add-small-caps.py / add-old-style-figures.py** — add `smcp`/`c2sc` and `onum` GSUB
  features from existing glyphs (sources: phonetic/lowercase/capital; circled/super/sub).
- **anchor-em.py** — the **pixel-perfect step (DEFAULT)**. Sets `em = N×128`,
  `descent = measured descender`, `ascent = the rest`; sets hhea/OS2 line metrics to the
  FULL ink extent so overshooting accents don't clip. Re-anchors whatever em yal exported
  (N×128 or the full canvas) back to N×128. Glyphs never rescaled.
- **pixel-scale.py** — OPTIONAL uniform scale-up applied ON TOP of anchor (default
  factor 1 = no-op). Shrinks every em by one shared factor so the family renders bigger
  while the pixel stays identical across strikes. Non-integer factor → slightly soft
  edges (accepted); factor 1 is crisp. UNIFORM only — can't fix per-strike proportions,
  and can't give "a bit bigger AND crisp" (crisp only at whole multiples ×2, ×3).
- **verify-pixel-grid.py** — the GUARD. Asserts every strike shares the same `em/N`
  (same pixel) and all glyphs are on the 128 grid. Build refuses to ship if violated.
- **generate-nerd-fonts / rename-family.py** — Nerd Font variants (`quanta-strike-N-nerd`),
  vendored patcher in `patcher/`.
- **convert-woff2.py** — mirrors `build/ttf → build/woff2` (base only by default,
  `--include-nerd` optional), via FontForge's native WOFF2.

Output: `build/ttf/quanta-strike/`, `build/ttf/quanta-strike-nerd/`, `build/woff2/quanta-strike/`.

## Sizing choice in build.sh
Always anchors pixel-perfect first, then prompts `Scale factor on top [default 1]`.
`1` = leave pixel-perfect (crisp). `>1` = uniform bigger (soft, pixel still identical).

## Using the fonts (CSS)
- Use each strike at its native size: `font-size = N px` = `N/16 rem` on a 16px base
  (so `strike-16 = 1rem`, `strike-12 = 0.75rem`, `strike-14 = 0.875rem`, …).
- **Size and family are a pair** — a rem value only gives 1px-per-pixel with its matching
  `font-family`. Bind them in one class; never expose size alone.
- Fonts ship with tight ink-based line metrics (line-height ~1.06–1.33, larger on small
  strikes). Set `line-height` explicitly for uniform leading.

## yal source format (`pixelfont/`, `src/*/*.json`)
Self-contained client-side app (`index.html` + `script.js` + `fonthx-assets.js`) that
turns PNG + JSON into a TTF in the browser. JSON keys of note: `in-glyphs` (rows of
chars = PNG grid order), `glyph-width`/`glyph-height` (cell size), `glyph-ofs-x/y`,
`glyph-baseline` (baseline row in cell), `font-px-size` (= 128 units/pixel),
`font-em-square`, `contour-type: pixel`, `overrides` (e.g. `hide \s`).

## Working conventions
- **NEVER** git commit / push / merge / stage or open PRs. Leave the working tree dirty;
  the user reviews and commits manually.
- Don't modify `src/` unless explicitly asked. Verify claims by MEASURING the actual TTFs
  with FontForge — don't assume.
