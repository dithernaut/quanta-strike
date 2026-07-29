# quanta-strike

<img src="https://raw.githubusercontent.com/dithernaut/quanta-strike/main/docs/quanta-strike.png" alt="quanta-strike shown at different strike sizes" width="100%">

A modern pixel typeface. I draw each size by hand. Non-integer scaling ruins
pixels, so quanta-strike ships a family of _strikes_. Each strike is its own
design for one target size.

This package doesn't just ship fonts, but the whole scaling system for web. Type, spacing, borders,
and the rest share one source pixel. The page that uses it reads as a real low-res grid,
not a out of place pixel font on a normal website.

🌐 [**Playground**](https://quantastrike.dithernaut.com)

📖 **Read the story:** [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling)

![All the available strikes of `quanta-strike`](https://raw.githubusercontent.com/dithernaut/quanta-strike/main/docs/quanta-strikes.avif)

```bash
npm install quanta-strike
```

Upgrading from 0.5.x? See [MIGRATION.md](./MIGRATION.md).

## Tailwind (recommended)

One import gives you fonts, type scale, pixel grid, and zoom:

```css
@import "tailwindcss";
@import "quanta-strike/base-12.css";
```

`text-base` is strike 12. Neighbors fill the rest of the ladder. Type, spacing,
borders, radius, and shadows all follow `--qs-zoom`.

```css
:root {
  --qs-zoom: 3;
} /* optional. Integers stay sharp on every display. */
```

If you load a `base-N` preset, use `text-*`. Do not use `.qs-N`. That class
ignores `--qs-zoom`. Mixing them puts two pixel sizes on one page.

`base-12` defaults to `--qs-zoom: 2` (24px body). Under `48rem` it steps to
`1.5` (18px). If you set `--qs-zoom` yourself, you own every breakpoint. Write
both branches if you want a responsive pair:

```css
:root {
  --qs-zoom: 3;
}
@media (width < 48rem) {
  :root {
    --qs-zoom: 2;
  }
}
```

Other presets: `base-6` through `base-32`. Zoom defaults to `2` on 6, 10, and
12; `1` on 14 and up. Only `base-12` ships a mobile step. Mono:
`base-12-mono.css`.

## Plain CSS

```js
import "quanta-strike";
```

```html
<p class="qs-16">Sixteen pixels.</p>
<code class="qs-12-mono">const pixel = 1;</code>
```

Locked `.qs-N` classes use **px**. They keep 1 CSS px per source pixel. They
ignore `--qs-zoom`.

One strike only:

```js
import "quanta-strike/16.css";
```

Faces only. No classes. Use this when you bring your own type scale:

```js
import "quanta-strike/fonts.css";
```

Mono only:

```js
import "quanta-strike/mono.css";
// or one strike: import "quanta-strike/16-mono.css";
```

CDN:

```html
<link
  rel="stylesheet"
  href="https://cdn.jsdelivr.net/npm/quanta-strike/quanta-strike.css"
/>
```

Strikes: `6`, `10`, `12`, `14`, `16`, `18`, `20`, `32`.

### Weights

Weights share one family. `font-weight` and `<strong>` pick them. The class
stays the same:

```html
<p class="qs-12">body text with <strong>bold</strong> in it</p>
<p class="qs-12" style="font-weight: 300">light, if the strike draws it</p>
```

If a strike ships regular only, the browser synthesises bold.

## The one rule

Size and family travel together. `quanta-strike-16` is sharp at 16px. It blurs
everywhere else. Bind both in the same rule. Never split them.

| strike             | class    | custom property    |
| ------------------ | -------- | ------------------ |
| `quanta-strike-6`  | `.qs-6`  | `--font-strike-6`  |
| `quanta-strike-10` | `.qs-10` | `--font-strike-10` |
| `quanta-strike-12` | `.qs-12` | `--font-strike-12` |
| `quanta-strike-14` | `.qs-14` | `--font-strike-14` |
| `quanta-strike-16` | `.qs-16` | `--font-strike-16` |
| `quanta-strike-18` | `.qs-18` | `--font-strike-18` |
| `quanta-strike-20` | `.qs-20` | `--font-strike-20` |
| `quanta-strike-32` | `.qs-32` | `--font-strike-32` |

## `--qs-zoom`

`--qs-zoom` is the main knob. It scales the whole pixel system: type, spacing,
borders, and the rest. Integers stay sharp on every display. `1.5` works on
retina. Avoid values like `1.75`.

```css
:root {
  --qs-zoom: 2;
}
```

## Pixel grid

`base-N` already loads `grid.css`. Import it alone for hand-rolled setups:

```css
@import "quanta-strike/grid.css";
```

It snaps `border`, `outline`, `ring`, and `divide` to the pixel unit. It also
sets spacing, radius, tracking, leading, and shadow offsets.

Keep `--container-*` as static rem. Derived values break Tailwind
`@md:` / `@min-md:` container queries. For a grid-exact max-width, write
`max-w-[calc(var(--qs-px)*N)]`.

## Mono

Add `.qs-mono` to a subtree. Every strike under it switches to mono. Sizes stay
put.

```html
<div class="qs-mono">
  <p class="text-base">Mono body.</p>
</div>
```

Each strike ships as its own family: proportional for UI, mono for code. Mono is
not a style of the proportional family. Prefer `base-N-mono` or `mono.css` when
the whole page is mono.

## Responsive text

`clamp()` will not work. Change the size and you must change the family. Swap
the whole pair at a breakpoint. Or change `--qs-zoom` to scale every strike
together.

```css
.title {
  font-family: var(--font-strike-16);
  font-size: calc(var(--qs-px) * 16);
}

@media (min-width: 48rem) {
  .title {
    font-family: var(--font-strike-32);
    font-size: calc(var(--qs-px) * 32);
  }
}
```

## Underlines

Each strike draws its underline one source pixel thick. The `.qs-N` and `text-*`
classes set that stroke. If you bind `--font-strike-N` yourself, you skip them.
Safari then guesses and draws a thinner line. [`grid.css`](#pixel-grid) covers
the whole page. Or set it once:

```css
:where(a, u, s, ins, del, abbr) {
  text-decoration-thickness: var(--qs-px);
}
```

The `text-decoration` shorthand resets the stroke. Use `text-decoration-line`
instead.

## What you get

- `quanta-strike`: every strike and locked `.qs-N` classes
- `quanta-strike/fonts.css`: faces and vars only
- `quanta-strike/mono.css`: mono faces only
- `quanta-strike/base-12.css`: Tailwind happy path (fonts, grid, zoom, theme)
- `quanta-strike/base-12-mono.css`: same, mono
- `quanta-strike/grid.css`: pixel unit, border/ring/divide snaps
- `quanta-strike/16.css` / `16-mono.css`: one strike
- `--font-strike-16` / `--font-strike-16-mono`: hand-rolled CSS

## Linux console (headless / framebuffer)

This npm package ships WOFF2 for the web. For a headless Linux box or Raspberry
Pi Lite (the real VT/framebuffer console, not a terminal emulator), build the
PSF bitmap fonts from the
[source repo](https://github.com/dithernaut/quanta-strike):

```bash
git clone https://github.com/dithernaut/quanta-strike.git
cd quanta-strike
./build.sh --psf                  # or: ./build.sh -y --psf --psf-scale 2
```

The build writes them to `build/psf/`. Copy a `.psfu.gz` into
`/usr/share/consolefonts/` and run `setfont`. PSF is opt-in. The main release
zip does not include it. See [`build.sh --help`](https://github.com/dithernaut/quanta-strike)
and [PUBLISHING.md](https://github.com/dithernaut/quanta-strike/blob/main/docs/PUBLISHING.md)
for charset notes.

## Licence

SIL Open Font License 1.1. See `OFL.txt`.

Story: [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling).
Source and build: [github.com/dithernaut/quanta-strike](https://github.com/dithernaut/quanta-strike).
