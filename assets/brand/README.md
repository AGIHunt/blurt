# blurt brand mark (v0.8, the 4A line chick)

The chick that blurts it out: a front-facing round chick in one even line — a tuft of three bumps, two dot eyes, a
small diamond beak, wing nubs — with two sound arcs at its top right. Monochrome and graphic: black line on light,
white line on dark. It replaces direction A (the side-profile hen, kept in git history before this change and as
`assets/logo-v0.8a.png`). The colour 1A chick in `assets/mascot/` stays the mascot for moments; this is the mark.

Everything here is vector, and `chick.swift` is the one source of the drawing: it holds the geometry and writes every
SVG below. The icon tile's colour is not in it: `chick.swift` reads `gradient.field`, `gradient.deep`,
`gradient.linear` and `gradient.grain` from `assets/color/tokens.json` (the one source of colour,
`docs/design/system.md` §2.2 and §6) each time it runs. `build.py` renders the bitmaps the app and installers use.

| File | What it is |
| --- | --- |
| `chick.swift` | The geometry (in the space of the `d4a-hero` raster the design came from) and the SVG writer. The outline is body ∪ tuft and the wings are the part of their loop outside the body, computed with CoreGraphics (`CGPath.union`, `lineSubtracting`; macOS 13+). |
| `chick-line.svg` | The line master: black line, transparent. For small and monochrome use. |
| `chick-filled.svg` | The filled master: the same line over a flat white fill (body and wings), as on the app icon. |
| `app-icon.svg` | The app icon, 1024 canvas on the macOS 26 grid: an 824 px superellipse tile at (100, 100) with a soft shadow and a 3 px white 22 % rim; group `#tile` is the tile, `#chick` the art (a black `#17140f` 30 px line over a white body, white eye glints). The tile is the brand **gradient field** (`#tile-field`, see below) with grain (`#tile-grain`). |
| `app-icon-small.svg` | The 32 px slot (16@2x) and the favicon: a heavier line, one sound arc, a filled beak, no eye glints, the chick a little bigger. The tile is plain `gradient.linear`, top → bottom (green → mint → azure): no radial layers, no grain. |
| `app-icon-16.svg` | The 16 px slot: no arcs, chunkier line, eyes and beak; the same plain linear tile. |
| `app-icon-dark.svg` | The master on `gradient.deep`: the icon's optional dark appearance. Not shipped yet (see the last editing note). |
| `logo.svg` | The logo: the app icon's chick without the tile, on a white sticker edge so the black line and arcs read on dark pages too (GitHub dark). |
| `glyph.svg` | The macOS menu-bar icon (an 18 pt template image) and the tray glyph. Drawn directly on the 18 pt grid with a 1.5 pt line (3 px at 2x), slightly heavier than SF Symbols at menu-bar size so the small face reads, and stored as filled outlines in the family's 24 grid (the family strokes at a fixed 1.75). Hinted by construction: the body's outer edges sit on whole points, the eyes are 2 pt dots centred on whole points (2 × 2 px at 1x). Three layers: the chick, the inner arc, the outer arc. `assets/icons/blurt.svg` is a copy of it. |
| `build.py` | Renders every bitmap below. |

### The tile: the brand gradient field

v0.8 shipped tile (a) of three treatments: (a) black line, white body, warm yellow tile; (b) white line on a
near-black tile; (c) black line, yellow body and coral arcs on a white tile (`promo/cases/v0.8-logo/4a-final.png`,
untracked; `--alts` still writes them). The colour system (`docs/design/system.md`) then made the brand a
green → mint → azure gradient, so the icon's tile became that gradient and the yellow went: the icon is now the
brand's largest gradient surface, and the chick stays exactly as drawn (variant A of
`promo/cases/v0.8-color/v2-app-icon.png`: of the three v2 treatments it keeps the most contrast at every size and the
same black-line mark as the logo and README; a white-line chick lost its edge on the light green top at 32 / 16 px).
The colour lives in the tile; the mark stays monochrome.

How the tile is built (`tileSVG` in `chick.swift`, layers from `tokens.json`, bottom → top):

1. `#tile-bg`: `gradient.field`'s base linear, 180° (`#66D97A` → `#69DC95`), in user space over the 824 box. The
   first tile path draws it with the soft shadow.
2. `#tile-field`, a group clipped to the superellipse: the base again, then one 824 px rect per radial layer (each an
   elliptical `radialGradient`, `gradientUnits="userSpaceOnUse"` with `gradientTransform="translate(cx cy)
   scale(rx ry)"`, centre and radii being the token's fractions of the box): the azure ellipse rising from the
   bottom-left with its mint rim (the seam glow), the second azure from the bottom-right, the airy green top
   highlight.
3. `#tile-grain`: monochrome fractal noise (`feTurbulence` 2 octaves at `grain.iconFrequency` 0.6 per unit of the
   1024 canvas, saturate 0, contrast ×3) at `grain.icon` 7 %, `mix-blend-mode: overlay`. The base sits inside the
   group too, so the overlay blends with the whole field whether or not a renderer isolates the clipped group.
4. The rim: the tile path stroked 3 px white at 22 %.

The 32 / 16 px drawings use only `gradient.linear` (no radial layers, no grain: both turn to mud that small).

The menu bar shows the chick **in monochrome only**, like every other menu-bar icon: `glyph.svg` as a template image,
which macOS tints for light, dark and highlighted bars. The colour option of the hen (Settings → General → "Colour
menu-bar icon", `Icons/MenuHen.swift`) is gone; the old setting keys are removed at launch. `App/MenuGlyph.swift`
moves it: while voice input listens the arcs pulse outward (inner, then outer), and it hops when something is done;
with Reduce Motion it stays still.

## Regenerate

```sh
swift assets/brand/chick.swift                      # the SVGs, after a geometry or tokens.json gradient change
                                                    # (add --alts DIR for the three v0.8 tile treatments)
python3 assets/brand/build.py                       # the brand bitmaps (needs rsvg-convert and Pillow; .icns needs macOS)
python3 assets/brand/build.py --site                # …plus the site/ outputs: for the site redo, off by default
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
- `apps/desktop/src-tauri/icons/` (PNGs, `icon.icns`, `icon.ico`) and `crates/blurt-capture/demo/icons/`.
- Only with `--site` (the site will be redone, so a plain run leaves `site/` alone): `site/assets/logo.png` (320 px),
  `favicon.png` (64 px, small variant), `apple-touch-icon.png` (180 px, full-bleed field) and `og.png` (the social
  card; only the logo slot is repainted, the text is left as it is).

Pixel sizes of 16 and below come from `app-icon-16.svg`, 17–32 from `app-icon-small.svg`, larger ones from
`app-icon.svg`. The grain is dropped below 64 px. Sizes between 33 and 1023 px are rendered at 1024 and scaled down
(Pillow, Lanczos): rsvg-convert point-samples `feTurbulence` at the output pixel, so a direct 128 px render keeps the
grain at full per-pixel strength, where WebKit and CSS average it out with size.

## Editing notes

- Edit `chick.swift`, not the SVGs. `Chick` is one parametric drawing (body, tuft, wings, eyes, beak, arcs); the master,
  the small sizes and the glyph are instances of it. The tile is `M…C…Z` cubic Béziers fitted to the superellipse
  |x|⁵ + |y|⁵ = 1, within 0.25 px.
- `build.py` makes the apple-touch icon by swapping `<g id="tile">` in `app-icon.svg` for the contents of
  `#tile-field` (unclipped: a full-bleed field, no shadow or rim), and drops `#tile-grain` below 64 px; keep those ids,
  and keep `#tile`'s closing tag at column 0 (the nested group's is indented).
- rsvg-convert (2.62) and WebKit (Quick Look) agree on the 1024 master to within one level on average (the radial
  layers, the clipped group, `feTurbulence` and `mix-blend-mode: overlay`).
- The glyph must pass the icon family lint (`assets/icons/tools/iconlib.py`): the 24 grid and geometry inside 0.5–23.5.
  `MenuGlyph` draws its layers one by one, so keep the order chick, inner arc, outer arc (`tests/test_icons.py` checks).
  Check 1x and 2x with the app's self-test hook `menuglyph DIR`: the rest, listen and hop poses tinted for light and
  dark bars, and the real status button (with a count) in each appearance, at rest and highlighted.
- Not done yet: the dark appearance and a Liquid Glass `.icon` (Icon Composer) layer set for macOS 26. Until then
  macOS uses the `.icns`, which has no appearances. The tile already fills the grid, so macOS 26 doesn't add its grey
  frame. Checked with Xcode 26.0.1's actool: an `.appiconset` with `luminosity: dark` entries is ignored for the `mac`
  idiom ("unassigned children"); an `AppIcon.icon` (`icon.json` + `Assets/`: a full-bleed field layer per appearance,
  switched with `hidden-specializations`, and the chick on top) compiles into `Assets.car` with Aqua, DarkAqua and
  tintable stacks, plus a fallback `AppIcon.icns`, at deployment target 13.0. Shipping it means: build.py writes the
  `.icon` (`full_bleed()` of `app-icon.svg` / `app-icon-dark.svg` without `#chick` for the field layers, the chick
  alone for the top layer); `assets/color/build.py` passes it to the same actool run as `Assets.xcassets` with
  `--app-icon AppIcon` (one `Assets.car`); Info.plist gains `CFBundleIconName` = `AppIcon` next to `CFBundleIconFile`;
  `record.py` keeps its own `.icns` (it has the hand-drawn 16 / 32 px art, which an `.icon` can't carry). The grain
  costs size: the `.car` is 5.8 MB with grain in the field layers, 2.2 MB without.
