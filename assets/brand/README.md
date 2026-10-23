# blurt brand mark (v0.8, direction A)

The hen that blurts it out: a yellow hen head in profile, red three-lobe comb and wattle, the beak wide open, three
coral shout strokes, on a warm cream tile. Everything here is vector. The bitmaps the app, site and installers use
are rendered from these files.

| File | What it is |
| --- | --- |
| `app-icon.svg` | The master app icon. 1024 canvas on the macOS 26 icon grid: an 824 px superellipse tile at (100, 100) with a soft drop shadow, a cream gradient and a top sheen. On top sits the hen (`<g id="hen">`): flat fills with gentle gradients, sheen, and a soft shadow under the art. The hen alone is the logo. |
| `app-icon-small.svg` | The 16 and 32 px icon slots and the favicon, simplified the way Apple does its small icons. It has a heavier outline, two chunkier shout strokes instead of three, a bigger eye and no sheen, and the hen is 7 % larger. |
| `glyph.svg` | The tray glyph, and the macOS menu bar's monochrome option (Settings → General → "Monochrome menu-bar icon"): the same hen as a monochrome line drawing on the icon family's 24 grid with the 1.75 stroke. It has an outlined head, a solid comb, an open beak, a pixel-snapped eye and two shout strokes. `assets/icons/blurt.svg` is a copy of it. |
| `build.py` | Renders every bitmap below. |

The macOS menu bar shows the hen **in colour** by default: `skills/blurt/recorder/macos/Sources/BlurtApp/Icons/MenuHen.swift`
redraws this art without the tile for 18 pt, in code, on a 36-unit grid (bold dark outline, a light rim on dark,
tinted and highlighted bars, a 2 × 2 eye at 1x). It is not generated from these files: if the hen changes here, redraw
it there and check it with `menuglyph DIR`.

## Regenerate

```sh
python3 assets/brand/build.py                       # all brand bitmaps (needs rsvg-convert and Pillow; .icns needs macOS)
cp assets/brand/glyph.svg assets/icons/blurt.svg    # if the glyph changed
python3 assets/icons/tools/build.py                 # → BlurtIconPaths.swift, web icons + sprite, Tk PNGs, Tauri tray
```

`build.py` writes:

- `skills/blurt/assets/icon.png` (the 1024 master) and `icon-16.png` / `icon-32.png` (from the small SVG).
  `record.py make_icns` builds `Blurt.app/Contents/Resources/AppIcon.icns` from these at build time, and
  `scripts/release-mac.sh` goes through the same path. The review page's logo and favicon (`icon.png`, served by
  `review.py` and the app's scheme handler) come from this file too.
- `assets/logo.png`: the hen without the tile, transparent, 1024 px. It is used in the README. The previous logo is
  kept as `assets/logo-v0.7.png`.
- `site/assets/logo.png` (320 px), `favicon.png` (64 px, small variant), `apple-touch-icon.png` (180 px, full-bleed)
  and `og.png` (the social card; only the logo slot is repainted, the text is left as it is).
- `apps/desktop/src-tauri/icons/` (PNGs, `icon.icns`, `icon.ico`) and `crates/blurt-capture/demo/icons/`.

Pixel sizes of 32 and below always come from `app-icon-small.svg`, larger ones from `app-icon.svg`.

## Editing notes

- The hen's paths are in 1024-canvas coordinates. The tile is `M…C…Z` cubic Béziers fitted to the superellipse
  |x|⁵ + |y|⁵ = 1, within 0.25 px.
- `build.py` makes the logo by dropping `<g id="tile">`, the tile clip and the art shadow from `app-icon.svg`. Keep
  those ids if you restructure the file.
- The glyph must pass the icon family lint (`assets/icons/tools/iconlib.py`): the 24 grid, geometry inside 1–23
  including strokes, and currentColor only. The eye is centred on a pixel corner at 18 pt (x 10.67, y 12), so it
  renders as a solid 2 × 2 dot at 1x and 4 × 4 at 2x. Check 1x and 2x with the app's self-test hook
  `menuglyph DIR`, which writes the rest, listen and hop poses tinted for light and dark menu bars, the colour hen in
  both looks, and the real status button (with a count) in each appearance.
- The art was traced from the chosen raster (`promo/cases/v0.8-logo/icons/a-1024.png`) with potrace, then cleaned up:
  a geometric eye and highlight, the shout strokes rebuilt as an even fan of tapered capsules, and recoloured
  gradients. The trace scripts are in `promo/cases/v0.8-logo/src/` (untracked).
- Not done yet: a Liquid Glass `.icon` (Icon Composer) layer set for macOS 26. Until then macOS uses the `.icns`. The
  tile already fills the grid, so macOS 26 doesn't add its grey frame.
