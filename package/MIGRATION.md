# Migrating to 0.6.0

Not a breaking change — old paths still resolve. Imports can just be cleaner.

**Tailwind:** one file instead of three.

```css
/* before */
@import "quanta-strike";
@import "quanta-strike/scale/base-12.css";
@import "quanta-strike/grid.css";
html { font-size: 200%; }

/* after */
@import "quanta-strike/base-12.css";
:root { --qs-zoom: 2; } /* optional — base-12 already defaults to 2 */
```

**Plain CSS:** `utilities.css` → `quanta-strike`. Faces-only → `fonts.css`.

Zoom is `--qs-zoom` now, not `html { font-size }`. See the [README](./README.md).
