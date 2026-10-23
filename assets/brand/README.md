# blurt brand mark (v0.8, the 4A line chick)

The chick that blurts it out: a front-facing round chick in one even line — a tuft of three bumps, two dot eyes, a
small diamond beak, wing nubs — with two sound arcs at its top right. Monochrome and graphic: black line on light,
white line on dark. It replaces direction A (the side-profile hen, kept in git history before this change and as
`assets/logo-v0.8a.png`). The colour 1A chick in `assets/mascot/` stays the mascot for moments; this is the mark.

Everything here is vector, and `chick.swift` is the one source: it holds the geometry and writes every SVG below.
`build.py` renders the bitmaps the app, site and installers use.

| File | What it is |
| --- | --- |
| `chick.swift` | The geometry (in the space of the `d4a-hero` raster the design came from) and the SVG writer. The outline is body ∪ tuft and the wings are the part of their loop outside the body, computed with CoreGraphics (`CGPath.union`, `lineSubtracting`; macOS 13+). |
| `chick-line.svg` | The line master: black line, transparent. For small and monochrome use. |
| `chick-filled.svg` | The filled master: the same line over a flat white fill (body and wings), as on the app icon. |
| `app-icon.svg` | The app icon, 1024 canvas on the macOS 26 grid: an 824 px superellipse tile at (100, 100) with a soft shadow and a hairline rim; group `#tile` is the tile, `#chick` the art. Tile (a): a warm yellow gradient, the chick in a black 30 px line over a white body. |
| `app-icon-small.svg` | The 32 px slot (16@2x) and the favicon: a heavier line, one sound arc, a filled beak, no eye glints, the chick a little bigger. |
| `app-icon-16.svg` | The 16 px slot: no arcs, chunkier line, eyes and beak. |
| `logo.svg` | The logo: the app icon's chick without the tile, on a white sticker edge so the black line and arcs read on dark pages too (GitHub dark). |
| `glyph.svg` | The macOS menu-bar icon (an 18 pt template image) and the tray glyph. Drawn directly on the 18 pt grid with a 1.5 pt line (3 px at 2x), slightly heavier than SF Symbols at menu-bar size so the small face reads, and stored as filled outlines in the family's 24 grid (the family strokes at a fixed 1.75). Hinted by construction: the body's outer edges sit on whole points, the eyes are 2 pt dots centred on whole points (2 × 2 px at 1x). Three layers: the chick, the inner arc, the outer arc. `assets/icons/blurt.svg` is a copy of it. |
| `build.py` | Renders every bitmap below. |

Why tile (a). The three treatments were (a) black line, white body, warm yellow tile; (b) white line on a near-black
tile; (c) black line, yellow body and coral arcs on a white tile (all in `promo/cases/v0.8-logo/4a-final.png`,
untracked). (a) keeps the monochrome line art the mark is about and still owns a colour: the chick's yellow, which
stands out in a Dock of white, grey and dark tiles in both light and dark mode, where (b) sinks into a dark Dock and
(c) is one more white tile. It also carries over the warm tile of the earlier icons.

The menu bar shows the chick **in monochrome only**, like every other menu-bar icon: `glyph.svg` as a template image,
which macOS tints for light, dark and highlighted bars. The colour option of the hen (Settings → General → "Colour
menu-bar icon", `Icons/MenuHen.swift`) is gone; the old setting keys are removed at launch. `App/MenuGlyph.swift`
moves it: while voice input listens the arcs pulse outward (inner, then outer), and it hops when something is done;
with Reduce Motion it stays still.

## Regenerate

```sh
swift assets/brand/chick.swift                      # the SVGs (add --alts DIR for the three tile treatments)
python3 assets/brand/build.py                       # all brand bitmaps (needs rsvg-convert and Pillow; .icns needs macOS)
cp assets/brand/glyph.svg assets/icons/blurt.svg    # if the glyph changed
python3 assets/icons/tools/build.py                 # → BlurtIconPaths.swift, web icons + sprite, Tk PNGs, Tauri tray
```

`build.py` writes:

- `skills/blurt/assets/icon.png` (the 1024 master) and `icon-16.png` / `icon-32.png` (from the small SVGs).
  `record.py make_icns` builds `Blurt.app/Contents/Resources/AppIcon.icns` from these at build time, and
  `scripts/release-mac.sh` goes through the same path. The review page's logo and favicon (`icon.png`, served by
  `review.py` and the app's scheme handler) come from this file too.
- `assets/logo.png`: `logo.svg`, transparent, 1024 px. It is used in the README. The previous logos are kept as
  `assets/logo-v0.8a.png` (the A hen) and `assets/logo-v0.7.png`.
- `site/assets/logo.png` (320 px), `favicon.png` (64 px, small variant), `apple-touch-icon.png` (180 px, full-bleed)
  and `og.png` (the social card; only the logo slot is repainted, the text is left as it is).
- `apps/desktop/src-tauri/icons/` (PNGs, `icon.icns`, `icon.ico`) and `crates/blurt-capture/demo/icons/`.

Pixel sizes of 16 and below come from `app-icon-16.svg`, 17–32 from `app-icon-small.svg`, larger ones from
`app-icon.svg`.

## Editing notes

- Edit `chick.swift`, not the SVGs. `Chick` is one parametric drawing (body, tuft, wings, eyes, beak, arcs); the master,
  the small sizes and the glyph are instances of it. The tile is `M…C…Z` cubic Béziers fitted to the superellipse
  |x|⁵ + |y|⁵ = 1, within 0.25 px.
- `build.py` makes the apple-touch icon by swapping `<g id="tile">` in `app-icon.svg` for a full-bleed square; keep that
  id.
- The glyph must pass the icon family lint (`assets/icons/tools/iconlib.py`): the 24 grid and geometry inside 0.5–23.5.
  `MenuGlyph` draws its layers one by one, so keep the order chick, inner arc, outer arc (`tests/test_icons.py` checks).
  Check 1x and 2x with the app's self-test hook `menuglyph DIR`: the rest, listen and hop poses tinted for light and
  dark bars, and the real status button (with a count) in each appearance, at rest and highlighted.
- Not done yet: a Liquid Glass `.icon` (Icon Composer) layer set for macOS 26. Until then macOS uses the `.icns`. The
  tile already fills the grid, so macOS 26 doesn't add its grey frame.
