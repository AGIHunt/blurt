# blurt brand mark (v0.8, the 4A line chick)

The chick that blurts it out: a front-facing round chick in one even line — a tuft of three bumps, two dot eyes, a
small diamond beak, wing nubs — with two sound arcs at its top right. Monochrome and graphic: black line on light,
white line on dark. It replaces direction A (the side-profile hen, kept in git history before this change and as
`assets/logo-v0.8a.png`). It is also the mascot: the app's chick for moments is this drawing in colour (see "The
mascot" below), so there is one chick. (The earlier 1A round chick in `assets/mascot/` is left only for the web UIs.)

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
| `glyph.svg` | The macOS menu-bar icon (an 18 pt template image) and the tray glyph (v0.9): the chick as **one bold filled silhouette** — body, the three-bump tuft and the wing nubs — with the eyes (2.3 pt) and the beak knocked out, 16.5 pt tall and 17 wide in its 18 pt box, foot on a whole point. No arcs at rest. One layer, in the family's 24 grid. `assets/icons/blurt.svg` is a copy of it (`build.py` copies it and regenerates the family). See "The menu-bar icon" below. |
| `…/BlurtApp/App/MenuGlyphGeometry.swift` | The menu bar's two sound arcs (generated): centre, radii, angles and their 2 pt line in the glyph's 18 pt box. They sit to the right of the box, so they are not in `glyph.svg`. |
| `build.py` | Renders every bitmap below. |
| `…/BlurtApp/Icons/MascotGeometry.swift` | The mascot's drawing for the mac app (generated): the master and small chicks' outline as a path, their wings, eyes, glints, beak and arcs as numbers, and the mascot palette. |

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
menu-bar icon", `Icons/MenuHen.swift`) is gone; the old setting keys are removed at launch.

### The menu-bar icon (v0.9: the silhouette)

The v0.8 glyph was the line chick: a 1.5 pt line, 13 pt tall with two arcs beside it, 2 px dot eyes. Next to other
apps' menu-bar icons (bold silhouettes that fill most of the 16–18 pt height, as Apple's HIG asks of menu bar extras)
it read small and faint. Of three directions (`promo/cases/v0.9-next/menubar/compare.png`, untracked: (a) a filled
silhouette, (b) a 2 pt line chick with one arc, (c) the head alone, larger) the silhouette won: it carries the same
ink weight as the filled icons around it at 1x and 2x, and the chick still reads by its outline alone (three-bump
tuft, round body, wing nubs) with the eyes and beak cut out; the line versions stayed busy and greyer at 1x.

- At rest: the silhouette alone (`glyph.svg`, the 18 pt image). The arcs are a state, not decoration.
- Listening (voice input): the two sound arcs (2 pt, `MenuGlyphGeometry.swift`) appear to the right and pulse
  outward, inner then outer. The image is then 24 pt wide (`MenuGlyph.listenWidth`), so the count moves over once
  when listening starts and back when it stops, never per frame.
- Done: it hops (1.5 pt up, stretched 5 %, after a 10 % crouch). Every moving frame is 22 pt tall (the bar) with the
  18 pt box centred, as AppKit centres the 18 pt rest image, so the chick never jumps between the two.
- Reduce Motion: no hop and no pulse; while listening the arcs show still.
- The count (" 9") follows the image as the status button's title; the silhouette leaves under a point on its right,
  so the gap is the title's own space.

## The mascot

The mac app's mascot (onboarding hero, the island, notifications) is this chick in colour, moved in code — no frames:

- `chick.swift` writes `skills/blurt/recorder/macos/Sources/BlurtApp/Icons/MascotGeometry.swift` from `master` and
  `small`, plus the mascot palette (`mascotPalette`): the icon's `#17140F` line and eyes, a warm butter-yellow body
  `#FFC83D` (the yellow of the earlier 1A mascot), wings `#F7B52A`, a coral beak `#FF7A45`, faint cheeks, the egg's
  shell, and `#F4F1EA` for the free marks (arcs, thought dots) on dark backdrops, where the chick and egg also get a
  thin white rim (the sticker edge, thinner) so the black line reads on the island. The art's colours live here with
  the art; the UI's live in `tokens.json`.
- `Icons/MascotArt.swift` poses it part by part (hops, tilt, flapping wings drawn whole behind the body, blinks, ^ ^
  eyes, open beak, pulsing arcs, the egg it hatches from, sparkles, the bug in `peck`); `Icons/Mascot.swift` plays the
  clips on layers (`MascotView`, `MascotLayer`, `MascotImage`). At 32 pt and below it draws `small`.
- `docs/design/system.md` §6.1 has the clips and the rules; `swift assets/brand/chick.swift --check` (run by
  `tests/test_icons.py`) fails when the generated file is stale.

## Regenerate

```sh
swift assets/brand/chick.swift                      # the SVGs and the two Swift files, after a geometry, palette or
                                                    # tokens.json gradient change (--check: list stale outputs, write none)
                                                    # (add --alts DIR for the three v0.8 tile treatments)
python3 assets/brand/build.py                       # the brand bitmaps (needs rsvg-convert and Pillow; .icns needs macOS);
                                                    # if the glyph changed it also copies it to assets/icons/blurt.svg and
                                                    # runs assets/icons/tools/build.py (BlurtIconPaths.swift, web icons +
                                                    # sprite, Tk PNGs, Tauri tray)
python3 assets/brand/build.py --site                # …plus the site/ outputs: for the site redo, off by default
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
  It is one fill layer, at least 16 pt tall, foot on a whole point; the arcs live in `MenuGlyphGeometry.swift`
  (`tests/test_icons.py` checks). Check 1x and 2x with the app's self-test hook `menuglyph DIR`: the rest, listen,
  still-listen (Reduce Motion), hop and crouch poses tinted for light and dark bars, and the real status button (with a
  count) in each appearance, at rest and highlighted.
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
