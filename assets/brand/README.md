# Brand: Peep

Peep is Blurt's character and mark: a soft 3D clay chick — a gradient sphere (green → mint → sky), two glossy black eyes
with one highlight each, a dark slate two-part beak. The brand book (`blurt-media/brand-book/index.html`) defines it:
the character, the four rendering families, the colours, every scene and every state.

## The one source

Peep is a Blender model, `blurt-media/logo/peep/peep.py`. Its renders are packaged in
`blurt-media/logo/peep/release/` (`MANIFEST.md` lists every file; the package is complete when its first line says
`Status: COMPLETE`). **Nothing in this repo draws Peep.** `import_peep.py` copies and converts the package:

```
python3 assets/brand/import_peep.py               # from ~/workspace/blurt-media/logo/peep/release
python3 assets/brand/import_peep.py --src DIR     # another package with the same layout
python3 assets/brand/import_peep.py --list        # what it writes
python3 assets/brand/import_peep.py --only windows  # only the Windows / Linux outputs (web Peep, Tauri icons, tray)
```

It needs Pillow, and Xcode's `actool` for the macOS 26 icon (it runs `assets/color/build.py --car`). Run it again
whenever the package changes, then rebuild the review page (`cd web && pnpm --filter @blurt/review build`).

## What it writes

| Output | From | Used by |
|---|---|---|
| `skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Peep/<set>-<state>.webp` | `app/<set>/<state>/NNNN.png` | the mascot (`Icons/Mascot.swift`): sprite sheets, 10 columns; `dark` has every state, `paper` idle, hello, done; idle at 15 fps, the rest 30 |
| `…/Resources/Peep/glyph-<state>.png`, `glyph-<state>@1x.png` | `app/glyph/<state>/NNNN@2x/@1x.png` | the menu bar (`App/MenuGlyph.swift`): template frames as strips |
| `…/Resources/Peep/peep.json` | measured from the frames | sheet geometry, fps, each talking frame's beak opening (the level → frame map), the blink's frames |
| `skills/blurt/assets/AppIcon.icns` | `app/icon/paper/Peep-paper.icns` | Blurt.app `CFBundleIconFile` (macOS 13–15; `record.py`) |
| `assets/brand/AppIcon.icon` | `app/icon-layers/` + the tile colours in `MANIFEST.md` | macOS 26 icon, light and dark → `Assets.car` (`CFBundleIconName`) |
| `skills/blurt/assets/icon.png`, `icon-16.png`, `icon-32.png` | `app/icon/paper/` | the review server's `/icon.png`, fallbacks |
| `skills/blurt/assets/peep-done.webp`, `peep-done-dark.webp`, `favicon.png` | the done clip's happy eye; `web/favicon-32.png` | served next to the review page (its Done screen, its favicon) |
| `assets/brand/app-icon-paper.png`, `app-icon-dark.png` | `app/icon/*/icon_1024.png` | reference |
| `assets/brand/peep/*.svg` | `app/vector`, `app/flat`, `app/glyph` | the vector, flat, mono and glyph drawings |
| `assets/peep-readme.png`, `peep-readme-dark.png`, `assets/logo.png` | `readme/peep-logo[-dark].png`, the side still | the README header (`<picture>`, GitHub light and dark) |
| `web/packages/review/src/assets/peep-vector.svg`, `peep-thinking.png` | `app/vector/peep-vector.svg` (numbers rounded), the thinking glyph frames | the review page's top bar and organising pill (inlined: the page has a 400 KB budget) |
| `web/packages/ui/src/assets/app-icon.png` | the paper tile at 160 | reference (the Tauri empty states show Peep alone now, as the Mac's) |
| `web/packages/icons/peep/<tier>-<state>.webp`, `peep.json` (`--only windows`) | `web/sprites/notch-<state>.webp` (the dark set without the contact shadow) | Windows / Linux: `@blurt/icons/mascot` (`mascotHtml`, `<Mascot>`; a shared 30 fps ticker, the still frame with reduced motion). Cut like the Mac's sheets, per tier: `xs` (32 px square) and `s` (64) for the island — idle, listening, talking (the beak with the level), thinking, done, error; `l` (192) for the app window — idle, hello, done. Each app imports its own tier (`@blurt/icons/peep-s`, `peep-l`) |
| `apps/desktop/src-tauri/icons/icon.ico`, `icon.png`, `32x32` `64x64` `128x128` `128x128@2x.png`, `icon.icns`; `crates/blurt-capture/demo/icons/` (`--only windows`) | `app/icon/paper/` | the Tauri app's icon (bundle, the window's title bar, the taskbar): the paper tile; the .ico holds 16 (flat), 24 and 32 (the vector), 48, 64 and 256 (clay) |
| `apps/desktop/src-tauri/icons/tray-black.png`, `tray-white.png` (`--only windows`) | `app/marks/tray-*.png`, centred on a 64 px square | the Tauri tray (`lib.rs`): white on dark panels, black on light ones and as the macOS template |

## Rules the app keeps

- The rendering family by size: clay from 56 device px up, the vector 24–56, the flat mark 16–24, the template glyph
  in the menu bar only.
- One eye size, one highlight per eye; the beak is slate, a step lighter on black, never white; no front view; no
  gradient behind Peep's gradient.
- Menu-bar frames are template images (black + alpha) with their ink at least half a point inside the 18 pt box in
  every frame (`PeepTests`).
- States: idle, hello, listening, talking, thinking, done, error (`docs/design/system.md` §6.1).

## Not done here

- The light (paper-lit) web sheets: `web/sprites/light-*` carry a contact shadow the Mac app dropped in v1.0.6, so the
  web plays the notch set on light surfaces too (the Mac does so for every clip its paper set lacks). A shadowless
  paper set in the package's `web/sprites/` (with hello) would let the window match the Mac's paper lighting.
- A full run also rebuilds the Mac's sheets from the package's `app/<set>/` frames, which have the contact shadow; the
  shipped v1.0.6 sheets came from `out/anim/{paper,dark}-noshadow` (outside the package). Until the package carries
  those, refresh the Windows outputs with `--only windows`.
- The site and the film keep their own copies (`blurt-media/site`, `blurt-media/film`).

## Legacy

`legacy/` keeps what Peep replaced, for reference only; nothing builds from it and its scripts no longer run from there:
`mascot/` (the 1A round chick's strips, the web's mascot until the Windows port moved to Peep),
`chick.swift` and `build.py` (the 4A line chick's generator and renderer, v0.9), its SVGs, and the earlier logos
(`logo-1/2/3.png`, `logo-v0.7.png`, `logo-v0.8a.png`, `logo-v0.9-4a.png`, `app-icon-v0.9-4a.png`, `LOGO_PROMPT.md`).
