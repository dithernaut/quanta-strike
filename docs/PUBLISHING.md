# Publishing

Two things ship: the fonts, as a GitHub release, and the npm package. They share one
version number. Build once, then publish both from that build.

Nothing here runs automatically. Every publish step is yours to run.

## The chain

```
VERSION  →  the fonts  →  package/package.json
```

`VERSION` at the repo root holds the release number. The build stamps it into every
font. `build-package.sh` reads it back out of a font and writes it into the package.
So the fonts and the package always agree, and you only decide the number once.

## Before you start

- Work on a clean tree. The build overwrites `build/`, and you want to see what
  changed.
- Decide the version. Look at `cat VERSION` and pick your bump.
- Follow semver. A new strike is a minor bump. A redrawn glyph is a patch. Anything
  that changes metrics or renames a family is a major bump, because it will move text
  on somebody's page.

## 1. Build

Build with Nerd Fonts. The release should carry every artifact, and Nerd Fonts are
opt-in, so ask for them here.

```bash
./build.sh --nerd-fonts
```

Answer the version prompt. It shows the current number first.

```
Current: 0.1.0 (from ./VERSION)
    1) patch bump
    2) minor bump
    3) major bump
    4) custom (same for all)
    5) keep
```

The build writes the new number back to `VERSION` when it succeeds. It also runs
`scripts/verify-pixel-grid.py`, which refuses to ship a font that broke the pixel grid. If
that guard fails, stop and fix the art. Do not publish around it.

## 2. Check the build

Read the summary. It prints the version and every output folder.

Then check a font yourself:

```bash
python3 -c "import fontforge; print(fontforge.open('build/ttf/quanta-strike/quanta-strike-16-regular.ttf').version)"
```

That number must match `VERSION`. If it does not, the build did not finish. Run it
again.

Confirm `OFL.txt` sits in every folder that holds fonts. The OFL requires the licence
to travel with them.

```bash
find build -name OFL.txt
```

## 3. Assemble the npm package

```bash
./build-package.sh
```

It copies the WOFF2 files into `package/fonts/`, generates the CSS that points at
them, copies the licence, and writes the version it found in the fonts into
`package/package.json`. The generated fonts and CSS stay gitignored.

Read the version line it prints. It must match `VERSION`.

```
Version: 0.1.0 (fonts and package agree)
```

## 4. Commit

Commit both version files together. The build output stays out of git.

```bash
git add VERSION package/package.json
git commit -m "Release $(cat VERSION)"
git tag v$(cat VERSION)
git push && git push --tags
```

Tag that commit. Then anyone can rebuild that exact release.

## 5. Publish the GitHub release

Zip the build folder and attach it to a release on the tag. A normal release
build (`./build.sh --nerd-fonts`, no `--psf`) only fills `build/ttf` and
`build/woff2` (plus `OFL.txt` next to the fonts), so zipping `build/` is fine.

```bash
rm -rf build/tmp                    # staging, only present if a build failed
find build -name .DS_Store -delete  # macOS clutter
zip -r quanta-strike-$(cat VERSION).zip build
```

If you built console PSF earlier in the same tree, drop it before the main zip
(`rm -rf build/psf`) or leave it for the optional asset below — don’t ship
personal charset builds in the primary download.

Both cleanup lines matter. `build/tmp` holds intermediate TTFs, and `.DS_Store` ships
noise to strangers.

The zip carries the TTFs, the WOFF2 files, the CSS, and the licence. That covers a
designer installing fonts and a developer wiring up a site.

### Optional: console PSF asset

Console PSF is opt-in and not part of the main zip. If you want a separate
download for Raspberry Pi / Linux framebuffer users:

```bash
./build.sh -y --psf --psf-scale 2          # or interactive, say yes to PSF
zip -r quanta-strike-$(cat VERSION)-console-psf.zip build/psf
```

Use the default Lat15 `console-charset.json` for that asset — keep personal
`console-charset-*.json` variants out of the release. Clones can always build
PSF locally: `./build.sh --psf`.

Create the release on GitHub, point it at the tag, and attach the zip(s). Name the
release after the version.

## 6. Publish the npm package

Look inside the tarball before you send it:

```bash
cd package && npm pack --dry-run
```

Then publish.

```bash
cd package && npm publish
```

## 7. Check what you shipped

```bash
npm view quanta-strike version
```

Load the CDN copy in a browser and confirm the fonts resolve:

```
https://cdn.jsdelivr.net/npm/quanta-strike/utilities.css
```

jsDelivr caches for a few minutes after a publish, so give it a moment.

## Quick reference

```bash
./build.sh --nerd-fonts        # 1. build, answer the version prompt
cat VERSION                    # 2. check the number
./build-package.sh             # 3. assemble the package
git add VERSION package/package.json
git commit -m "Release $(cat VERSION)"
git tag v$(cat VERSION) && git push && git push --tags
zip -r quanta-strike-$(cat VERSION).zip build   # 5. GitHub release
# optional: zip -r quanta-strike-$(cat VERSION)-console-psf.zip build/psf
cd package && npm publish      # 6. send the package
```

## Checklist

Every release:

- [ ] `./build.sh --nerd-fonts` (no `--psf` unless you also want a console asset)
- [ ] `./build-package.sh`, version line matches
- [ ] `git add VERSION package/package.json && git commit -m "Release $(cat VERSION)"`
- [ ] `git tag v$(cat VERSION) && git push && git push --tags`
- [ ] `rm -rf build/tmp && find build -name .DS_Store -delete` (optional, shouldn't be there anymore)
- [ ] `zip -r quanta-strike-$(cat VERSION).zip build`, attach to the GitHub release
- [ ] Optional: `./build.sh -y --psf` and attach `…-console-psf.zip` as a second asset
- [ ] `cd package && npm pack --dry-run`, read the list
- [ ] `npm publish`
- [ ] `npm view quanta-strike version` shows the new number
