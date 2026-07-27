# quanta-strike — pixel font build pipeline

quanta-strike is a pixel font built from drawn pixel sheets. The rules below were
worked out carefully and are non-negotiable unless the user says otherwise. Read this
before doing anything.

## What it is
- A family of **strikes** — one design per target size: `quanta-strike-6`, `-10`, `-12`,
  `-14`, `-16`, `-18`, `-20` (more may exist). Each strike is its **own font family**
  named `quanta-strike-N`. The different SIZES are NOT weights/styles of one family
  (weights are — see below).
- Source art is a drawn pixel sheet: each strike is a PNG + JSON in
  `src/quanta-strike-N/<style>/`. `scripts/png-to-ttf.py` turns that pair into the TTF, so the TTF is a
  **build artifact** — the PNG + JSON are the only real source. (The TTF used to be
  exported by hand; that step is now scripted, and the build is self-contained.)
- **Weights ARE styles of one strike.** `<style>` is the weight folder: `regular/` is the
  one every strike has, and any sibling (`bold/`, `light/`, `semibold/`, `bold-italic/`)
  is another weight of that same strike family. Drop the folder in and the build picks it
  up — no registration anywhere. The sheet inside may spell the weight out or not
  (`bold/quanta-strike-12-bold.{png,json}` and `bold/quanta-strike-12.{png,json}` are the
  same sheet; `pick_sheet` in build.sh owns the precedence, most specific first, with a
  `-mono` variant sheet outranking either). The folder name is the only weight signal and must be a
  word from `WEIGHT_MAP` in `scripts/font-metadata-patcher.py`; an unrecognised one
  **fails the build** rather than silently shipping at weight 400 and colliding with
  regular. See [docs/SOURCE-FORMAT.md](docs/SOURCE-FORMAT.md#weights).
  - This is the ONE axis where strikes do behave like a normal family. Sizes are still
    separate families, and mono vs proportional are still separate families — only
    weights live inside a family, on one `font-family` with distinct `font-weight`s.
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
  - A style with no PNG+JSON falls back to a prebuilt `src/<family>/<style>/<family>.ttf`
    (copied into the staging dir); with neither, the build fails loudly.
  - Output name is `<family>.ttf` for `regular`, `<family>-<style>.ttf` otherwise, so one
    out dir can hold every weight of a strike without collisions.
- **scripts/font-metadata-patcher.py** — names/version/license/OS2 class etc. NEVER touches
  vertical metrics (keeps the pixel grid). `--flat` writes all strikes of one variant
  into a single folder (`build/ttf/quanta-strike/` for proportional,
  `build/ttf/quanta-strike-mono/` for mono). The internal family name comes from the
  staging folder name, so the mono strikes (staged under `<family>-mono/`) get the
  `-mono` family for free. `--type` is set per variant — `sans` (or `serif`) for
  proportional, always `monospace` for mono — and is deliberately NOT read from
  `scripts/default-metadata.json` (build_variant appends it last so it wins). The proportional
  type can be set via a `prop-type` key in scripts/default-metadata.json (default `sans`).
  - **The weight comes from the style FOLDER**, never the filename (the filename is the
    family and holds no weight at all — reading it there is why every style used to come
    out at 400). `WEIGHT_MAP` here is the single source of truth for weight names; the
    tables in `scripts/generate-css.py` and `scripts/generate-nerd-fonts` mirror it and
    must be kept in step. An unrecognised style folder aborts the build.
  - Name IDs 1/2 only accept Regular/Bold/Italic/Bold Italic, so any other weight gets
    its own **legacy family** (`quanta-strike-12 light` / `regular`) while IDs 16/17 put
    it back as one family. Without that split, Light installs as a separate family on
    Windows and can win the Regular slot. `ribbi_names()` owns this.
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
  - Metrics are computed **per family, not per file**: all weights of a strike are
    anchored to the UNION of their ink, so they come out with identical metrics. Derived
    per file, bold's deeper descenders would move the baseline the moment text is bolded.
  - Also snaps the **underline and strikeout to whole pixels** (`decorate()`): stroke is
    `max(1, (N+8)//16)` px, underline top `underline_gap()` below the baseline, strikeout
    bottom on the half x-height. Both position fields hold the TOP of the stroke on disk, but
    FontForge's `upos` is the stroke's CENTER and it writes `top = upos + uwidth/2` —
    `os2_strikeypos` is written through verbatim. Left unset, FontForge's own defaults are
    percentages of the em and land on fractional pixels (0.797px at the 16).
  - `underline_gap()` = `2*stroke - 1`, clamped to `descent - stroke`. The air grows with
    the stroke (1px under the 1px rule, 3px under the 2px rule on the 32) so the underline
    hangs off the baseline by the same proportion at every strike. The clamp keeps the
    whole rule inside the em: with the emitted `line-height: 1` the first row below the em
    is the NEXT line's, and a stroke there lands on its ascenders — measured on the 6,
    where forcing the gap to 1 puts the rule on row 7, the next line's top glyph row,
    leaving row 6 empty under its own text. The 6's 1px descender leaves no room, so its
    gap clamps to 0 and the stroke shares the descender row. Gaps: 0 on the 6, 1 on the
    10–20, 3 on the 32 (whose 5px descender holds 3 + 2 exactly).
  - **Chromium ignores `OS/2 yStrikeoutPosition`** — measured: a font asking for 11px
    above the baseline still drew at 5px, because Chromium centres line-through on half
    the x-height and computes its own. Firefox honours the field. So the strikeout
    metrics here land for Firefox and for apps that read the font (Word, InDesign, PDF),
    and in Chromium a strike whose x-height is an EVEN number of pixels (the 6, 12, 14)
    gets a half-pixel line. Nothing in CSS can move a line-through; the only lever is
    stroke thickness parity, which `text-decoration-thickness` shares with the underline.
    Deliberately not traded away — a uniform 1px underline is worth more.
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
keep, Nerd Fonts = no (opt-in), console PSF = no (opt-in). Prompts still print the
assumed answer so the log stays auditable. Any new prompt must honour `$NON_INTERACTIVE`
or it will hang a non-interactive build.

## Build output
Quiet by default: each sub-command's stdout/stderr is captured to a temp log and the
terminal shows a two-line block, redrawn in place — the strike being worked on on the
first line, a braille spinner + gauge + percent on the second — plus phase headers,
warnings and the final summary. Two lines rather than one so neither wraps in a narrow
window; a wrapped line would break the cursor-up redraw and leave debris. The gauge is
second because it has a FIXED width, so the cursor comes to rest at a stable column
instead of jittering with the label. The gauge shrinks with the window and the label
truncates, both re-measured as the build runs, so resizing mid-build is safe.

While the bar is live, anything printed must go through `print_line` or a `print_*`
helper — a bare `echo` writes at the cursor and shifts the block without the bar
knowing, so the next redraw clears the wrong rows and strands a stale gauge in the log. A step that FAILS dumps
its captured output, so nothing is lost when it matters. `--verbose` / `-v` runs every
step inline with output passed straight through (the pre-existing behaviour). Piped
output (not a TTY) never animates: one plain line per step instead, so CI logs stay
readable. New pipeline steps should go through `run_step "<label>" <cmd>...` so they
tick the bar and get the capture-on-failure treatment for free; bump the budget in
main()'s "Budget the progress bar" block when you add one.

The prompts are grouped into five numbered sections — Strikes, Release, Typography,
Outputs, Review — and Review reprints every answer on one screen before the slow part
starts. Use `ask_yes_no`, `ask_choice` and `prompt_line` so new questions inherit the
alignment and the `$NON_INTERACTIVE` handling.

CLI flags that pin choices (honoured in `--defaults` runs too):
- **`--verbose`** (alias `-v`): print every sub-command's output as it runs instead of
  the progress line. Use it when a build misbehaves and you want the full trace.
- **`--nerd-fonts`** (alias `--nerd`): opt IN to Nerd Font generation (mono variant
  only, the slow step). Off unless given, so a plain `--defaults` build skips it.
- **`--psf`** (alias `--psf-fonts`): opt IN to console PSF fonts (Linux framebuffer /
  Raspberry Pi Lite). Off unless given. `--charset` / `--psf-scale` also turn it on.
  The main release zip skips PSF. Use it for local builds, or ship an optional
  `…-console-psf.zip` release asset. `--no-psf` forces a skip.
- **`--spacing V`**: FORCE the proportional inter-glyph gap for every strike: a pixel
  count, or `auto` (scale with strike size: 1px N<11, 2px 11–18, 3px N>18). When omitted,
  each strike falls back to its own JSON `spacing` key, then `auto`. `--spacing`
  overrides the per-strike JSON. Also settable repo-wide via a `spacing` key in
  scripts/default-metadata.json (same force-all effect). Mono is unaffected (its packing is
  `glyph-spacing`).
So `./build.sh -y --spacing 2 --nerd-fonts` = non-interactive, fixed 2px proportional gap
everywhere, with the mono Nerd variants and no PSF. Plain `./build.sh -y` lets each
strike's JSON (or auto) decide and skips Nerd + PSF.

## Sizing choice in build.sh
Always anchors pixel-perfect first, then prompts `Scale factor [enter = 1, pixel-perfect]`.
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
- **`text-decoration-thickness` does NOT inherit** (CSS Text Decoration 4);
  `text-underline-offset` does. Setting the stroke on a container therefore never reaches
  the `<a>`, `<u>`, `<s>` or `<del>` that actually draws the line — it computes `auto` and
  each engine picks its own (a hairline in WebKit, differently in Gecko and Blink). This
  looks exactly like the font being wrong and is not. generate-css.py emits
  `:where(<every strike class>) * { text-decoration-thickness: inherit; }`, zero
  specificity so a nested `.qs-N` still wins and passes its own stroke down. **Any new
  rule that sets the stroke needs the matching inherit rule**, or decorated children
  silently fall back.
- **Underline / strikethrough**: the fonts carry whole-pixel metrics, but only Chromium
  and WebKit read them — Firefox draws its own line and ignores `from-font` on both
  `text-decoration-thickness` and `text-underline-offset` (measured: its `auto` and
  `from-font` renders are identical). So the CSS always states the stroke as a LENGTH,
  which all three engines honour, in whatever unit that mode's `font-size` uses: **px** in
  the locked `.qs-N` classes (px font-size, so `html { font-size: … }` moves neither), and
  **rem** in the scale presets (`0.0625rem` = 1/16rem = one source pixel, so at
  `html { font-size: 200% }` the text doubles and the rule doubles with it — verified 2px
  stroke at +2px in both engines). `text-underline-offset` is the gap from the baseline to
  the TOP of the stroke, matching post `underlinePosition`. generate-css.py READS both
  numbers out of the built TTFs (`load_decoration`, `--ttf-dir`, defaulting to a `ttf/`
  folder beside the woff2 tree) instead of re-deriving them: the gap depends on each
  strike's descender depth, which is art, not arithmetic. WOFF2 table data is
  brotli-compressed, hence the TTFs. Strikethrough has NO CSS position control and
  Chromium ignores the font's — see the anchor-em notes above.

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
