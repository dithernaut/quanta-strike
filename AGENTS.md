# quanta-strike — pixel font build pipeline

quanta-strike is a pixel font built from drawn pixel sheets. The rules below were
worked out carefully and are non-negotiable unless the user says otherwise. Read this
before doing anything.

## What it is
- A family of **strikes** — one design per target size: `quanta-strike-6`, `-10`, `-12`,
  `-14`, `-16`, `-18`, `-20` (more may exist). Each strike is its **own font family**
  named `quanta-strike-N`. They are NOT weights/styles of one family.
- Source art is a drawn pixel sheet: each strike is a PNG + JSON in
  `src/quanta-strike-N/`. `scripts/png-to-ttf.py` turns that pair into the TTF, so the TTF is a
  **build artifact** — the PNG + JSON are the only real source. (The TTF used to be
  exported by hand; that step is now scripted, and the build is self-contained.)
- **Two variants per strike, from the same source by default.** Every strike is built
  twice:
  - **mono** — `quanta-strike-N-mono`, the original fixed-advance behaviour
    (advance = `(glyph-width + glyph-spacing) × 128`). Used for coding/TUIs; this is
    the variant that gets Nerd Fonts. Its generation is unchanged, byte-for-byte.
  - **proportional** — `quanta-strike-N` (the base name), each glyph trimmed to its own
    ink (zero left side bearing, advance = `(ink-width + gap) × 128`). The gap is chosen
    per strike in precedence order: `--spacing V` (forces all strikes) → the strike
    JSON's `spacing` key → **`auto`**, which scales with strike size N (1px N<11, 2px
    11–18, 3px N>18; bigger strikes get more air). A `spacing` value is a pixel count or
    `"auto"`. More legible for body text; `glyph-width` is now conceptually the *max*
    width. No Nerd Fonts.
  Both are still their own font families (mono and proportional are NOT styles of one
  family) and both hold the pixel invariant below — trimming only removes whole empty
  pixel columns, so widths stay on the 128 grid and the cross-strike pixel is untouched.
  - **Optional dedicated mono sheet.** By default both variants build from the one
    `quanta-strike-N.{png,json}`. If a strike also has a `quanta-strike-N-mono.{png,json}`
    pair next to it, the **mono** variant is built from that sheet instead (the
    proportional variant always uses the plain one). This lets a strike ship a
    hand-tuned monospace design while keeping the shared source for everything else;
    with no `-mono` sheet, mono just uses the plain source. (Generally: a variant with
    a non-empty suffix uses `<family><suffix>.{png,json}` when both are present.)

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
The full pipeline (`png-to-ttf → metadata → small caps → old-style figures → anchor-em
→ (optional scale) → guard`) runs **once per variant** — proportional first, then mono
— via the `build_variant` helper, each into its own group dir. Then `WOFF2` (both
variants at once) and finally `Nerd` (mono variant only, the slow step) run once at the
end. `build_variant` swaps the `STAGE_DIR`/`TTF_GROUP_DIR` globals the `run_*` helpers
read, so the per-step scripts below are variant-agnostic.
- **scripts/png-to-ttf.py** — builds each strike's TTF from its PNG + JSON, replacing the old
  manual export step. Verified bit-identical to the reference TTFs on every strike —
  same contours, widths, cmap. Reads the geometry from the JSON, so the strike's cell
  grid / baseline / overrides are honoured; ink = `alpha >= 128 and 3r+5g+b <= 1024`
  (a luminance threshold, NOT "is it black") — so light/transparent alignment guides in
  the art stay out of the font, but a DARK guide would become ink. Emits 1 px = 128
  units; never rescales. Standalone — the script's header documents every rule.
  - **`--proportional [--prop-gap V]`** switches from the default fixed mono advance to
    per-glyph trimmed widths. `V` is a pixel count or **`auto`** (default): auto reads
    the strike size N (= em/px) and picks 1/2/3px by size (1px N<11, 2px 11–18, 3px N>18)
    — so the smart-spacing policy lives here, where N is known, and standalone runs get
    it too. This is a CLI flag, driven by build.sh per variant — NOT the JSON
    `font-is-mono` key, which is untouched. Empty glyphs (space, `hide`) keep the mono
    cell advance in both modes. Widths stay whole pixels, so the grid invariant holds
    either way.
  - It implements exactly what these sources use (`contour-type: pixel`, mono OR
    proportional advance, `hide`). Anything else — `contour-type: smart`, the
    `kern`/`left`/`right`/`ignore`/`default_char` overrides — is NOT implemented; it
    errors or warns rather than guessing.
  - **Never writes into `src/`.** build.sh stages the TTFs under **`build/tmp/`** (the
    proportional variant in `build/tmp/src/`, the mono variant in `build/tmp/src-mono/`,
    with the mono strikes staged under `<family>-mono/` folders so the patcher picks up
    that family name), mirroring the `<family>/<style>/` layout the patcher expects. Only
    png-to-ttf and the metadata patcher read it; everything after works off `build/ttf/`,
    so build.sh **removes `build/tmp` at the end** of a successful build (and wipes it at
    the start of each run too). Pass `--keep-tmp` to keep it for inspection. It's
    gitignored with the rest of `build/`. `src/` holds the PNG + JSON only. Run standalone
    as `scripts/png-to-ttf.py <json> <out-dir>`;
    with no out-dir it writes next to the JSON, so pass one unless you want it in src/.
  - A strike with no PNG+JSON falls back to a prebuilt `src/<family>/regular/<family>.ttf`
    (copied into the staging dir); with neither, the build fails loudly.
- **scripts/font-metadata-patcher.py** — names/version/license/OS2 class etc. NEVER touches
  vertical metrics (keeps the pixel grid). `--flat` writes all strikes of one variant
  into a single folder (`build/ttf/quanta-strike/` for proportional,
  `build/ttf/quanta-strike-mono/` for mono). The internal family name comes from the
  staging folder name, so the mono strikes (staged under `<family>-mono/`) get the
  `-mono` family for free. `--type` is set per variant — `sans` (or `serif`) for
  proportional, always `monospace` for mono — and is deliberately NOT read from
  `scripts/default-metadata.json` (build_variant appends it last so it wins). The proportional
  type can be set via a `prop-type` key in scripts/default-metadata.json (default `sans`).
  - Values come from **`scripts/default-metadata.json`** at the repo root; when it exists
    build.sh reads it and asks no metadata questions (delete it to get the prompts
    back). The one exception is the **version bump, which is ALWAYS asked** and must
    never be moved into the defaults — it's a per-release decision, not a constant.
  - **The version itself lives in `VERSION`** (repo root, tracked, one semver line).
    It is the single source of truth for the release number. The prompt still asks
    every build — that rule is unchanged — but it now asks *relative to* `VERSION`,
    and a successful build writes the result back. Every strategy, INCLUDING "keep",
    passes an explicit `--version` to the patcher: png-to-ttf rebuilds each TTF from
    scratch, so with no flag the font silently falls back to FontForge's default 1.0
    and "keep" would reset the release number instead of keeping it. Do NOT read the
    current version out of `build/ttf/` — that's a git-ignored artifact, so wiping
    `build/` would lose the version history.
  - `build-package.sh` reads the version back out of a built TTF and writes it into
    `package/package.json`, so the npm package can never drift from the fonts it
    ships. The chain is `VERSION` → fonts → package. Nothing publishes automatically.
  - Author is `dithernaut` / dithernaut.com; licence is **OFL-1.1**, the only practical
    choice since Google Fonts accepts only OFL-1.1 / Apache-2.0 / UFL (not MIT, not
    Creative Commons). OFL permits donations and bundling; it forbids selling the font
    on its own.
  - **`OFL.txt`** (repo root) is the canonical SIL text, verbatim from
    openfontlicense.org, with the placeholder header replaced by our notice and NO
    Reserved Font Name (the Google Fonts convention). Its first line must stay
    byte-identical to `copyright` in scripts/default-metadata.json — Google Fonts compares
    them. `run_copy_license` copies it into every build output folder holding fonts,
    because the OFL requires the licence to travel with them.
  - Three DIFFERENT name-table fields, easy to conflate: `--license` = copyright
    notice (ID 0), `--licensedesc` = the licence text (ID 13), `--designer` = author
    (ID 9). Google Fonts checks all of them.
  - **FontForge pre-fills copyright with the OS account's real name**, so it must
    always be set explicitly or the builder's legal name ships in the font.
    scripts/png-to-ttf.py sets it from the JSON, and the patcher overwrites it.
- **scripts/add-small-caps.py / scripts/add-old-style-figures.py** — add `smcp`/`c2sc` and `onum` GSUB
  features from existing glyphs (sources: phonetic/lowercase/capital; circled/super/sub).
- **scripts/anchor-em.py** — the **pixel-perfect step (DEFAULT)**. Sets `em = N×128`,
  `descent = measured descender`, `ascent = the rest`; sets hhea/OS2 line metrics to the
  FULL ink extent so overshooting accents don't clip. Re-anchors whatever em the source
  exported (N×128 or the full canvas) back to N×128. Glyphs never rescaled.
- **scripts/pixel-scale.py** — OPTIONAL uniform scale-up applied ON TOP of anchor (default
  factor 1 = no-op). Shrinks every em by one shared factor so the family renders bigger
  while the pixel stays identical across strikes. Non-integer factor → slightly soft
  edges (accepted); factor 1 is crisp. UNIFORM only — can't fix per-strike proportions,
  and can't give "a bit bigger AND crisp" (crisp only at whole multiples ×2, ×3).
- **scripts/verify-pixel-grid.py** — the GUARD. Asserts every strike shares the same `em/N`
  (same pixel) and all glyphs are on the 128 grid. Build refuses to ship if violated.
- **scripts/generate-nerd-fonts / scripts/rename-family.py** — Nerd Font variants, vendored patcher in
  `patcher/`. Run for the **mono variant only** (`quanta-strike-N-mono-nerd`), and last
  because patching is the slow step.
- **scripts/convert-woff2.py** — mirrors `build/ttf → build/woff2` (base only by default,
  `--include-nerd` optional), via FontForge's native WOFF2. One pass covers both variants
  since it walks the whole `build/ttf` tree.

Output (per variant): proportional → `build/ttf/quanta-strike/`, `build/woff2/quanta-strike/`;
mono → `build/ttf/quanta-strike-mono/`, `build/ttf/quanta-strike-mono-nerd/`,
`build/woff2/quanta-strike-mono/`.

## Non-interactive builds
`./build.sh --defaults` (aliases `-y`, `--yes`, `--non-interactive`) answers every
prompt with its DEFAULT and builds all strikes — both variants each — for CI /
repeatable releases. Not called `--yes` because the defaults aren't all yes: version =
keep, Nerd Fonts = no (opt-in). Prompts still print with the assumed answer so the log
stays auditable. Any new prompt must honour `$NON_INTERACTIVE` or it will hang a
non-interactive build.

Two CLI flags pin the choices that would otherwise be prompted (both honoured in
`--defaults` runs too):
- **`--nerd-fonts`** (alias `--nerd`) — opt IN to Nerd Font generation (mono variant
  only, the slow step). Off unless given, so a plain `--defaults` build skips it.
- **`--spacing V`** — FORCE the proportional inter-glyph gap for every strike: a pixel
  count, or `auto` (scale with strike size: 1px N<11, 2px 11–18, 3px N>18). When omitted,
  each strike falls back to its own JSON `spacing` key, then `auto` — so `--spacing`
  overrides the per-strike JSON. Also settable repo-wide via a `spacing` key in
  scripts/default-metadata.json (same force-all effect). Mono is unaffected (its packing is
  `glyph-spacing`).
So `./build.sh -y --spacing 2 --nerd-fonts` = non-interactive, fixed 2px proportional gap
everywhere, with the mono Nerd variants; plain `./build.sh -y` lets each strike's JSON (or
auto) decide.

## Sizing choice in build.sh
Always anchors pixel-perfect first, then prompts `Scale factor on top [default 1]`.
`1` = leave pixel-perfect (crisp). `>1` = uniform bigger (soft, pixel still identical).

## Using the fonts (CSS)
- Pick a variant by family: `quanta-strike-N` (proportional, better for body text) or
  `quanta-strike-N-mono` (fixed-width, for code/TUIs). Both share the same pixel; the
  native-size rules below apply identically to either.
- Use each strike at its native size: `font-size = N px` = `N/16 rem` on a 16px base
  (so `strike-16 = 1rem`, `strike-12 = 0.75rem`, `strike-14 = 0.875rem`, …).
- **Size and family are a pair** — a rem value only gives 1px-per-pixel with its matching
  `font-family`. Bind them in one class; never expose size alone.
- Fonts ship with tight ink-based line metrics (line-height ~1.06–1.33, larger on small
  strikes). Set `line-height` explicitly for uniform leading.

## Pixel-sheet source format (`src/*/*.json`)
The full field-by-field reference (every key png-to-ttf reads, plus a minimal example) is
in **[docs/SOURCE-FORMAT.md](docs/SOURCE-FORMAT.md)**. Summary below.

The JSON sitting next to each PNG; `scripts/png-to-ttf.py` is the only thing that reads it.
Keys of note: `in-glyphs` (rows of chars = PNG grid order, indexed by
CODEPOINT — astral chars take one cell), `glyph-width`/`glyph-height` (cell size),
`glyph-ofs-x/y` (grid origin), `glyph-sep-x/y` (gap between cells), `glyph-base-x`
(x-origin within the cell), `glyph-baseline` (baseline row in cell), `font-px-size`
(= 128 units/pixel), `font-em-square`, `contour-type: pixel`, `font-is-mono`,
`overrides` (e.g. `hide \s` = keep the advance, drop the ink).
- `spacing` (optional) — the **proportional** variant's inter-glyph gap for this strike:
  a pixel count or `"auto"` (size-based). Read only when the build doesn't force one via
  `--spacing`/default-metadata. The mono variant ignores it — mono uses `glyph-spacing`.
- Cell (row, col) is at `(ofs_x + col*(width+sep_x), ofs_y + row*(height+sep_y))`.
  The PNG canvas is usually BIGGER than the grid — the slack is ignored, so don't
  expect image height to divide by the row count.
- Only the FIRST space in the whole sheet becomes a glyph; later ones just leave a gap.

## Working conventions
- **NEVER** git commit / push / merge / stage or open PRs. Leave the working tree dirty;
  the user reviews and commits manually.
- Don't modify `src/` unless explicitly asked. Verify claims by MEASURING the actual TTFs
  with FontForge — don't assume.
