# quanta-strike

<img src="https://raw.githubusercontent.com/dithernaut/quanta-strike/main/docs/quanta-strike.png" alt="quanta-strike shown at different strike sizes" width="100%">

A modern pixel typeface. I draw each size by hand. Pixels shouldn't be scaled by non-integer factors. That's why quanta-strike ships a familty of _strikes_. Each strike is
its own pixel design, drawn for one target size.

📖 **Read the story:** [dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling)

![All the available strikes of `quanta-strike`](https://raw.githubusercontent.com/dithernaut/quanta-strike/main/docs/quanta-strikes.avif)

```bash
npm install quanta-strike
```

## Use it

Import the CSS, then use the class.

```js
import "quanta-strike";
```

```html
<p class="qs-16">Sharp at sixteen pixels.</p>
<code class="qs-12-mono">const pixel = 1;</code>
```

That is the whole setup. The class sets the family and the size together.

Import one size instead of all eight if you only need one:

```js
import "quanta-strike/16.css";
```

## Sizes

The package ships eight strikes: `6`, `10`, `12`, `14`, `16`, `18`, `20`, `32`.

Each strike gets two classes.

| class         | use for            |
| ------------- | ------------------ |
| `.qs-16`      | body text and UI   |
| `.qs-16-mono` | code and terminals |

Swap the number for any size in the list.

## The one rule

The size and the family go together. `quanta-strike-16` is sharp at 16px and
blurry everywhere else. The `.qs-16` class binds both, so use the class and you
stay safe.

If you write your own CSS, keep them in the same rule:

```css
.headline {
  font-family: var(--font-strike-32);
  font-size: 32px;
}
```

Never set the size on its own. Never set the family on its own.

## Tailwind

Import a theme preset to wire the Tailwind type scale. Every `text-*` step gets
its strike paired in.

```css
@import "tailwindcss";
@import "quanta-strike";
@import "quanta-strike/theme/base-16.css";
```

`text-base` is strike 16 at `1rem`. For a denser body, use `base-12` instead:

```css
@import "quanta-strike/theme/base-12.css";

html {
  font-size: 187.5%; /* optional uniform zoom */
}
```

Rem sizes are always `N / 16 × 1rem`. Picking a different base only changes which
strike is `text-base` — it does not change the rem math, so the zoom knob stays
honest. Every strike has a `theme/base-N.css`.

## Responsive text

You cannot scale this font with `clamp()`. Change the size and you must change the
family too. So swap the whole class at a breakpoint:

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

- `quanta-strike` loads every strike.
- `quanta-strike/16.css` loads one strike.
- `quanta-strike/theme/base-16.css` (and `base-12`, …) — Tailwind type scale.
- `--font-strike-16` and `--font-strike-16-mono` custom properties for every size.
- `.qs-16` and `.qs-16-mono` classes for every size.

## Licence

SIL Open Font License 1.1. See `OFL.txt`.

Read the full story at
[dithernaut.com/posts/pixel-scaling](https://dithernaut.com/posts/pixel-scaling).
Source and build pipeline at
[github.com/dithernaut/quanta-strike](https://github.com/dithernaut/quanta-strike).
