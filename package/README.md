# quanta-strike

<img src="https://raw.githubusercontent.com/dithernaut/quanta-strike/main/docs/quanta-strike.png" alt="quanta-strike shown at different strike sizes" width="100%">

A modern pixel typeface. I draw each size by hand. Non-integer scaling ruins
pixels, so quanta-strike ships a family of _strikes_. Each strike is its own
design for one target size.

📖 **Read the story:** [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling)

![All the available strikes of `quanta-strike`](https://raw.githubusercontent.com/dithernaut/quanta-strike/main/docs/quanta-strikes.avif)

```bash
npm install quanta-strike
```

## Use it

Import the utilities, then use a class. The class sets family and size together.

```js
import "quanta-strike/utilities.css";
```

```html
<p class="qs-16">Sixteen pixels.</p>
<code class="qs-12-mono">const pixel = 1;</code>
```

One strike only:

```js
import "quanta-strike/16.css";
```

Or the CDN:

```html
<link
  rel="stylesheet"
  href="https://cdn.jsdelivr.net/npm/quanta-strike/utilities.css"
/>
```

Strikes: `6`, `10`, `12`, `14`, `16`, `18`, `20`, `32`.

## Type scale (Tailwind)

Tailwind names sizes by role (`text-base`, `text-lg`, `text-xl`). Strikes are
fixed pixel designs (`12`, `14`, `16`). You have to pick which strike is body
text. That pick is the base preset. It maps the whole ladder so every `text-*`
step keeps size and family paired.

A dense body often looks best on strike 12. Import `base-12`, then zoom the
page with the root font-size:

```css
@import "tailwindcss";
@import "quanta-strike";
@import "quanta-strike/theme/base-12.css";

html {
  font-size: 200%; /* zoom. 100% = 1 source pixel per CSS px */
}
```

`text-base` is now strike 12. Smaller and larger steps take the neighboring
strikes. Rem sizes stay at `N / 16`, so the zoom scales every strike together.

Want body at strike 16 and `1rem` at a 100% root? Use `base-16` instead:

```css
@import "quanta-strike/theme/base-16.css";
```

Every strike has a preset: `theme/base-6.css` through `theme/base-32.css`.

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

The `.qs-N` classes use `px`. They ignore the root font-size and stay at 1 CSS
px per source pixel.

## Mono

Add `.qs-mono` to a subtree. Every strike under it switches to mono. Sizes stay
put. The type scale never notices.

```html
<div class="qs-mono">
  <p class="text-base">Mono body.</p>
</div>
```

Each strike also ships as its own family: proportional for UI, mono for code.
Mono is not a style of the proportional family.

## Responsive text

`clamp()` will not work. Change the size and you must change the family. Swap
the whole pair at a breakpoint.

```css
.title {
  font-family: var(--font-strike-16);
  font-size: 16px;
}

@media (min-width: 48rem) {
  .title {
    font-family: var(--font-strike-32);
    font-size: 32px;
  }
}
```

## What you get

- `quanta-strike` loads every strike
- `quanta-strike/utilities.css` gives the locked `.qs-N` classes
- `quanta-strike/theme/base-12.css` (and every other base) wires the type scale
- `quanta-strike/16.css` loads one strike
- `--font-strike-16` / `--font-strike-16-mono` for hand-rolled CSS

## Licence

SIL Open Font License 1.1. See `OFL.txt`.

Story: [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling).
Source and build: [github.com/dithernaut/quanta-strike](https://github.com/dithernaut/quanta-strike).
