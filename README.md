# quanta-strike

![quanta-strike shown at every strike size](docs/quanta-strike.png)

A pixel typeface with one font per size.

Most fonts take one design and stretch it to every size. That breaks pixel art. A
pixel has to land on the screen grid, and stretching pushes it off. So quanta-strike
never stretches. It ships a separate font for each size. I draw each one by hand.

Today it ships eight sizes: **6, 10, 12, 14, 16, 18, 20, 32**. More will come.

📖 **Read the story:** [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling)

## Use it on the web

Install the package.

```bash
npm install @dithernaut/quanta-strike
```

Then pick one of two ways to use it.

### Locked mode

Import the utilities and use the class. Nothing else to set up.

```js
import "@dithernaut/quanta-strike/utilities.css";
```

```html
<p class="qs-16">Sharp at sixteen pixels.</p>
<code class="qs-12-mono">const pixel = 1;</code>
```

Every class pins its own size in `px`, so one source pixel always covers exactly
1 CSS px. Nothing on the page can knock it off the grid.

Need one size only? Import one file. It carries its own classes.

```js
import "@dithernaut/quanta-strike/16.css";
```

No build step? Link the CDN copy.

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@dithernaut/quanta-strike/utilities.css">
```

### Scalable mode

Import the fonts alone and wire them into your own type scale.

```js
import "@dithernaut/quanta-strike";
```

You get a custom property per strike. Pair each one with its size:

```css
h1   { font-family: var(--font-strike-32); font-size: 2rem; }
body { font-family: var(--font-strike-16); font-size: 1rem; }
```

This costs you a little setup and buys you a zoom knob. See
[Scale the whole thing](#scale-the-whole-thing) below.

Prefer to host the files yourself? Grab the release zip. It carries the WOFF2 fonts,
the CSS, and the licence.

## The one rule

The size and the family go together. `quanta-strike-16` is sharp at 16px. It blurs
at every size in between. So bind them in the same rule and never split them.

```css
.headline {
  font-family: var(--font-strike-32);
  font-size: 32px;
}
```

Never set the size alone. Never set the family alone. The `.qs-N` classes exist to
make that impossible.

| strike | class | custom property |
|--------|-------|-----------------|
| `quanta-strike-6`  | `.qs-6`  | `--font-strike-6`  |
| `quanta-strike-10` | `.qs-10` | `--font-strike-10` |
| `quanta-strike-12` | `.qs-12` | `--font-strike-12` |
| `quanta-strike-14` | `.qs-14` | `--font-strike-14` |
| `quanta-strike-16` | `.qs-16` | `--font-strike-16` |
| `quanta-strike-18` | `.qs-18` | `--font-strike-18` |
| `quanta-strike-20` | `.qs-20` | `--font-strike-20` |
| `quanta-strike-32` | `.qs-32` | `--font-strike-32` |

## Scale the whole thing

Every strike shares one pixel size. So one knob scales the entire system at once,
and the strikes stay in proportion with each other.

Size your text in `rem` and move the root:

```css
html { font-size: 100%; }  /* 1 source pixel = 1 CSS px */
html { font-size: 200%; }  /* 1 source pixel = 2 CSS px, still crisp */
```

Whole multiples stay sharp. This is integer scaling, the same trick an emulator
uses. Land between them and the edges go soft, which is sometimes what you want.
`pixel-scale.py` does the same job at build time.

The `.qs-N` classes opt out of this on purpose. They use `px`, so they ignore the
root and stay locked at 1.0.

## Switch to mono

Add `.qs-mono` to any element. Every strike inside it turns mono, and no font-size
changes at all.

```html
<article>
  <p>Proportional text.</p>
  <div class="qs-mono">
    <p>The same sizes, now mono.</p>
  </div>
</article>
```

The class redefines the `--font-strike-N` properties on that subtree. Your type
scale never learns about it.

## Tailwind

Import the fonts, set your sizes in `@theme`, then pair each step with its strike.
Tailwind names steps semantically, so you decide which strike each step means.

```css
@import "tailwindcss";
@import "@dithernaut/quanta-strike";

@theme {
  --text-base: 1rem;
  --text-base--line-height: 1;
  --text-2xl: 2rem;
  --text-2xl--line-height: 1;
}

@layer base {
  body { font-family: var(--font-strike-16); font-size: var(--text-base); }
  h1   { font-family: var(--font-strike-32); font-size: var(--text-2xl); }
}
```

Keep the rem value and the strike in step. `--text-base: 1rem` means 16px at a 100%
root, so it pairs with `--font-strike-16`. Change one and you must change the other.

## Responsive text

`clamp()` will not work here. Change the size and you change the font. So swap the
whole pair at a breakpoint.

```css
.title { font-family: var(--font-strike-16); font-size: 16px; }

@media (min-width: 48rem) {
  .title { font-family: var(--font-strike-32); font-size: 32px; }
}
```

### Two variants per size

The build makes every strike twice from the same art.

- **proportional** (`quanta-strike-16`, class `.qs-16`) trims each glyph to its own
  ink. Use it for body text and UI.
- **mono** (`quanta-strike-16-mono`, class `.qs-16-mono`) fixes the advance width.
  Use it for code, terminals, and TUIs. This variant also gets Nerd Font icons.

Each one is its own family. Mono is not a style of the proportional family. Both hold
the pixel grid. Trimming only drops empty pixel columns, so the pixel never moves.

## Why it works

A pixel font has one job. Every pixel must land on the screen's pixel grid. Then the
art stays sharp.

A normal font is one set of outlines, and the renderer resizes them to whatever you
ask for. Smooth typefaces survive that. Pixel art does not. Ask for a size the design
was not drawn for and the renderer resamples it. Pixel edges fall between screen
pixels. The rasterizer smears them. Your blocky art turns muddy.

quanta-strike stops scaling instead. Every strike sits on a grid where 1 source pixel
equals 128 font units. The em holds a whole number of pixels. For `quanta-strike-N`
the em is N times 128. Render a strike at its own size and one source pixel covers
exactly 1 CSS px:

```
pixel size in CSS px = font-size × 128 / em = N × 128 / (N × 128) = 1.0
```

Every strike shares those units. One pixel of `quanta-strike-12` at 12px matches the
size of one pixel of `quanta-strike-20` at 20px. I draw them apart. They still agree.

The pipeline protects that. It never touches vertical metrics. It rewrites naming and
metadata, and it adds glyph features. It leaves the em, ascent, descent, and line gap
alone. Changing the em would push pixels off the grid, so it never does.

## Build it yourself

You need [FontForge](https://fontforge.org/) with Python bindings
(`brew install fontforge`) and Python 3.

```bash
./build.sh                  # interactive
./build.sh --defaults       # take every default, ask nothing (-y works too)
./build.sh -y --nerd-fonts  # add Nerd Font icons (mono only, the slow step)
./build.sh -y --spacing 2   # force a 2px proportional gap on every strike
```

The interactive build walks you through it. You pick the strikes and the optional
features. It builds both variants for every strike, proportional first, then mono. It
writes the WOFF2 files and the CSS. It patches Nerd Fonts last, and only if you ask.

`--defaults` answers every prompt with its default and builds every strike. Use it for
CI or a repeatable release. The defaults are not all "yes". The version keeps. Nerd
Fonts stay off. That is why the flag is not `--yes`. Every prompt still prints the
answer it took, so the log stays honest.

The build reads author, licence, URLs, and type from `default-metadata.json`, so it
does not ask for them. Edit that file to change them. Delete it to get the prompts
back. The build always asks for the version. That one is a per-release choice.

### Versions

The release number lives in [`VERSION`](VERSION) at the repo root. One line, one
semver. That file is the source of truth, and everything downstream copies it.

```
VERSION  →  the fonts  →  package.json
```

Every build asks you for the bump and shows the current number. Pick patch, minor,
major, a custom value, or keep. A build that succeeds writes the result back to
`VERSION`, so the next build starts from the right place.

Check the current version four ways:

```bash
cat VERSION                                    # the source of truth
./build.sh                                     # the prompt shows it, and so does the summary
python3 -c "import fontforge; print(fontforge.open('build/ttf/quanta-strike/quanta-strike-16-regular.ttf').version)"
```

The last one reads it straight out of a built font, which is the real proof. On a
Mac you can also open the TTF in Font Book and read the version there.

### Publish the npm package

```bash
./build.sh               # build the fonts and CSS, answer the version prompt
./build-package.sh       # copy them into package/, version and all
cd package && npm publish
```

`build-package.sh` reads the version out of a built font and writes it into
`package/package.json`, so the package always matches the fonts it ships. Nothing
publishes on its own. You run `npm publish` yourself.

[PUBLISHING.md](PUBLISHING.md) walks through a full release, fonts and package
together.

## Layout

```
src/                              # the art. the build never touches it
  quanta-strike-6/regular/quanta-strike-6.{json,png}
  quanta-strike-10/...
build/                            # generated. git-ignored
  tmp/                            #   staging TTFs. removed on success
  ttf/
    quanta-strike/                #   proportional strikes
    quanta-strike-mono/           #   mono strikes
    quanta-strike-mono-nerd/      #   Nerd Font mono strikes. opt-in
  woff2/
    quanta-strike.css             #   @font-face, the vars, the mono swap
    quanta-strike-utilities.css   #   the .qs-N classes. imports the above
    quanta-strike-16.css          #   one strike, fonts and classes together
    quanta-strike/                #   proportional web fonts
    quanta-strike-mono/           #   mono web fonts
package/                          # the npm package. build-package.sh fills it
patcher/                          # vendored Nerd Fonts patcher and glyph sets
```

[SOURCE-FORMAT.md](SOURCE-FORMAT.md) documents the `src/*.json` pixel-sheet format
field by field.

## Scripts

| script | does |
|--------|------|
| `png-to-ttf.py`            | Compiles a strike's PNG and JSON into a TTF. 1 pixel becomes 128 units. `--proportional` trims each glyph instead of using the mono advance. |
| `font-metadata-patcher.py` | Sets family and style names, OS-2, weight, width, version, copyright, and URLs. It never touches metrics, so the pixel grid holds. |
| `add-small-caps.py`        | Adds `smcp` and `c2sc` from the font's own small-caps, lowercase, or capital glyphs. |
| `add-old-style-figures.py` | Adds `onum`. It maps digits to circled, superscript, or subscript figures. |
| `anchor-em.py`             | Anchors the em to N times 128 and sets ink-based line metrics. It never rescales glyphs. |
| `pixel-scale.py`           | Scales every strike by one shared factor on top of the anchor. Factor 1 does nothing. |
| `verify-pixel-grid.py`     | Guards the build. It checks that every strike shares the same pixel and every glyph sits on the 128 grid. The build stops if this fails. |
| `generate-nerd-fonts`      | Patches every `.ttf` in a folder with Nerd Font icons and writes them to a sibling `-nerd` folder. |
| `convert-woff2.py`         | Mirrors `build/ttf` to `build/woff2`. It skips `-nerd` unless you pass `--include-nerd`. |
| `generate-css.py`          | Writes the drop-in CSS from the built WOFF2 files. It pairs each family with its size. |
| `rename-family.py`         | Sets a font's family and style naming and keeps the rest of the metadata. |
| `build-package.sh`         | Assembles the npm package from a finished build. |
| `default-metadata.json`    | Not a script. Holds the author, licence, and URL defaults the build applies instead of asking. |

## Features

- **Two variants.** Proportional for text, mono for code.
- **Metadata.** Per-strike families, semver, licence and copyright, designer and
  licence URLs.
- **Small caps.** The build adds `smcp` and `c2sc` from the font's own glyphs.
- **Old-style figures.** The build adds `onum` from the font's own alternate digits.
- **Nerd Fonts.** Icon-patched mono strikes for the terminal. Opt in to get them.
- **WOFF2 and CSS.** Compact web fonts for both variants, plus the CSS to wire them
  up.

## Licence

The fonts use **OFL-1.1**, the SIL Open Font License. Google Fonts accepts only
OFL-1.1, Apache-2.0, or UFL, so that settles it. The OFL allows redistribution,
modification, bundling, and donations. It forbids selling the font on its own.

The licence lives in [`OFL.txt`](OFL.txt). `build.sh` copies it into every output
folder that holds fonts. The OFL requires the licence to travel with them, so never
ship a font folder without it.

## Thanks

Thanks to [yal.cc](https://yal.cc) for the inspiration behind the underlying
algorithm. Go look at [YAL's pixel font generator](https://yal.cc/tools/pixel-font/).
