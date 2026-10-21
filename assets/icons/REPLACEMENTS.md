# Emoji → icons: what replaced what, and how to use the family

Rule: no emoji and no text glyphs (✓ ✗ ● ▶ ⏸ ■ ✎ ⚠ ↺ …) as icons in any UI. Brand concepts use the blurt icon family
(`assets/icons/*.svg`). Generic actions use SF Symbols on macOS and the family's own drawing on web and Tk.
Key legends (⌘ ⌥ ⇧ ⌃ ⏎ ↩ ⌫ ⇥ ⎋, arrows) and typography (· … — × “ ”) are text and stay.
`python3 assets/icons/tools/check_glyphs.py` enforces this for Swift, TS/TSX/CSS/HTML, Rust and the Tk recorder, and
`tests/test_icons.py` runs it. A line that really needs a glyph as text can end with a `glyph-ok` comment that gives the reason.

## Status

Every occurrence is replaced. WP4, WP6 and WP7 had finished, so I edited their files directly.

| File | Was | Now |
|---|---|---|
| App/AppDelegate.swift · first-run toast | `口喷鸡已常驻 🐔` | `toast(…, icon: .chicken)`: chicken attachment before the text |
| App/AppDelegate.swift · status item while recording | `"● 00:12"` / `"❚❚ 00:12"` | `b.image = BlurtIcon.recordFill / .pauseFill .image(size: 11, color: red / amber)` with the title `" 00:12"` |
| App/AppDelegate.swift · recents menu | `📸 3`, `✓`, `✗ why` | title `3 张` / `3 shots`; `it.image` = `BlurtIcon.snap` (shots) or `.video` (SF); the `attributedTitle` ends with a `.check` (secondary) or `.x` (red) + why |
| App/AppDelegate.swift · "Process with X" | `  ✗ why` | `attributedTitle`: name + `BlurtIcon.x.label(why, …, iconColor: .systemRed, preferSymbol: true)` |
| App/AgentHub.swift · agent rows | `var mark: String` (✓ ✗ …) | `var markIcon: BlurtIcon?` (.check green / .x red / nil = "…"), drawn as attachments |
| App/HotkeySettings.swift · conflict note | `"⚠︎ " + text` | `BlurtIcon.warning.label(text, …, color: .systemOrange, preferSymbol: true)` |
| App/ReviewWindow.swift · load-failed page | `<div style="font-size:34px">🐔</div>` | `BlurtIcon.chicken.svg(size: 34)` (inline SVG, currentColor) |
| App/Support.swift · `pill()` | no icon parameter | `pill(…, icon: BlurtIcon?)`; `pillIconWidth(font)` gives the extra width |
| Capture/Picker.swift · snap hint | `📸 拖拽框选…` | `pill(hint, …, icon: .snap)` |
| Capture/NoteBubble.swift · status | `"● 0:04 在听…"`, `"✓ 已记下"` | `recLabel()` = `BlurtIcon.recordFill.label(…, iconColor: .systemRed)`; `BlurtIcon.check.label("已记下", color: .systemGreen, preferSymbol: true)` |
| Capture/Perch.swift · 整理 button | `🐔 整理 N 张` | `processIcon` (= `BlurtIcon.chicken.makeLayer(size: 15, color: white)`) placed before `整理 N 张` |
| Capture/Perch.swift · card badge | CATextLayer `🎙` / `✎` | CALayer `contents = Perch.badgeImage([.mic, .ink], color: accent)` |
| Capture/Perch.swift · voice-only caption | `🎙 语音备注` | `语音备注` (the mic badge shows) |
| Capture/Perch.swift · copied capsule | `✓ 已复制` | em space + `BlurtIcon.check.makeLayer(size: 11)` sublayer |
| Capture/Perch.swift · hatched label | `孵出来了 🐣` | `孵出来了` (the eggs in the nest hatch) |
| Capture/Perch.swift · note-tip play | CATextLayer `▶` | `BlurtIcon.playFill.makeLayer(size: 11)` sublayer |
| Settings/Icons.swift (WP6) | `.bug` = drawBug, `.chicken` = PeckArt | `UIIcon.brand` → `BlurtIcon.bug / .chicken / .peck` (new `.peck`); `brandImage` (SwiftUI) and `brandNSImage` (AppKit) |
| System/Peck.swift · peck card head | SF `checkmark.circle.fill` | `brandNSImage(.peck, size: 16)`, tinted `.systemGreen` |
| apps/desktop tray (WP7) | placeholder `tray.svg` (hatching egg) + `scripts/tray_icons.swift` | the `blurt` glyph; `build.py` writes `icons/tray.svg`, `tray-black.png` and `tray-white.png` (64 px) |
| web/apps/desktop/src/icons.tsx (WP7) | local path set | wraps `@blurt/icons`, keeping the app's names (record → record-fill, items → list, sessions → film, issue → bug, idea → spark, chick → hatched, fixing → wand, fixed → peck, back → arrow-left) |
| web/apps/overlays | `🐔 整理 N 张`, `×`, inline SVGs | `iconSvg('chicken')` + label, `iconSvg('x')`, HUD buttons `pause-fill / play-fill / snap / stop-fill / x` |
| web/packages/review | local stand-in `Icon.tsx` and `icons.tsx` | `export { Icon, … } from "@blurt/icons"` and `export { Egg, EggSprite } from "@blurt/icons"` |
| scripts/tk_recorder.py | `● ⏸ ▶ 📸 ↺ ■` | PNG glyphs through `tk_icon(widget, name)` (pause-fill, play-fill, snap, restart, stop-fill, record-fill); the recording light is a Canvas oval |

### WP5 (MainWindow/**, WebHost/**, BlurtCore/Index/**)

I scanned WP5's code after merging it (71e8340) and found nothing to replace. `MainWindow/BrandIcons.swift` already
routes brand concepts through `BlurtIcon`, and generic ones use SF Symbols. For new UI, follow the same pattern:

- Kind eggs: `BlurtIcon.egg(EggKind(kind), size:)`. The cell code may keep `eggImage(…)`, which draws the same eggs.
- Session states: to process = `.egg`, hatching = `.hatch`, reviewed = `.hatched`. Fixed = `.peck`, fixing = `.wand` (SF `wand.and.stars`).
- Never put an emoji or a ✓ / ✗ / ● glyph into a title. Use `icon.label(text, font:, color:)` for NSTextField or
  NSMenuItem.attributedTitle, and `icon.makeLayer(…)` next to a CATextLayer, which can't draw attachments.

## Using the icons

**Swift** (`Sources/BlurtApp/Icons/`, `enum BlurtIcon`; the cases are the file names in camelCase):

```swift
BlurtIcon.chicken.image(size: 16)                     // template NSImage: tints like text, menu items, NSImageView.contentTintColor
BlurtIcon.chicken.image(size: 16, color: .labelColor) // a fixed or dynamic colour, resolved at draw time
BlurtIcon.check.symbolImage(pointSize: 13)            // SF Symbol for generic icons (falls back to our vector)
BlurtIcon.snap.menuImage                              // NSMenuItem.image
BlurtIcon.chicken.label("整理 3 张", font: f, color: .white)          // NSAttributedString: icon + text
BlurtIcon.x.attributed(font: f, color: .systemRed, preferSymbol: true) // icon only, baseline-aligned
BlurtIcon.mic.makeLayer(size: 12, color: cg)          // CALayer for layer-built UIs; .cgImage(size:scale:color:)
BlurtIcon.egg(.idea, size: 14)                        // full-colour kind eggs (drawEgg)
BlurtIcon.chicken.swiftUIImage(size: 22)              // SwiftUI template Image
BlurtIcon.chicken.svg(size: 34)                       // inline SVG for HTML the app writes itself
BlurtIcon(named: "close")                             // names and aliases, the same table as on the web
```

**Web** (`@blurt/icons`, `workspace:*`): `import { Icon, Egg, EggSprite, type IconName } from "@blurt/icons"`, then
`<Icon name="chicken" size={16} className="…" title="…"/>`. It always carries the class `ico`. Pages without React use
`import { iconSvg, useIconSvg, SPRITE, eggSvg, EGG_SPRITE } from "@blurt/icons/core"`. Single-file pages can inline
`web/packages/icons/sprite.svg`, which holds `<symbol id="bi-NAME">` plus `egg-KIND`.

**Tk**: `skills/blurt/assets/icons/NAME.png`, `@1.5x` and `@2x` (light `#f4f4f5` glyphs for the dark bar), loaded with
`tk_icon(widget, name)`. Kind eggs are `egg-KIND.png`.

## SF Symbols on macOS (generic icons)

Source: `assets/icons/sf-symbols.json`. The first name this macOS has wins. With none available, our vector is drawn.

| icon | SF Symbol | icon | SF Symbol |
|---|---|---|---|
| check | checkmark | x (close, discard) | xmark |
| chevron-up/down/left/right | chevron.* | arrow-left | arrow.left |
| plus | plus | more | ellipsis |
| download | arrow.down.to.line | external-link | arrow.up.forward.square → arrow.up.right.square |
| folder, reveal | folder | inbox | tray |
| list | list.bullet | home | house |
| eye | eye | wand | wand.and.stars |
| code | chevron.left.forwardslash.chevron.right | copy | doc.on.doc |
| moon / sun | moon / sun.max | keyboard | keyboard |
| languages | globe | settings | gearshape |
| play / play-fill | play / play.fill | pause / pause-fill | pause / pause.fill |
| stop / stop-fill | stop / stop.fill | record / record-fill | record.circle / circle.fill |
| restart | arrow.counterclockwise | undo | arrow.uturn.backward |
| camera | camera | film / video | film / video |
| help-circle / info | questionmark.circle / info.circle | warning | exclamationmark.triangle |
| quote | quote.opening → quote.bubble | merge | arrow.triangle.merge |
| pencil (pen, edit) | pencil | search | magnifyingglass |
| trash | trash | git-commit | circle.and.line.horizontal → smallcircle.filled.circle |

Brand icons are always our own vectors on every platform: chicken (= process / 整理), blurt (app mark, tray), egg,
egg-fill, hatch (processing), hatched (done), nest, perch, claw (chicken-foot clip), peck (fixed), bug (issue), spark
(idea), note, task, mic, waveform (listening), snap, snap-to-perch, agent, agent-run, mcp (plug), and ink (drawing on
screen). The closest SF Symbols are listed under `nearest` in the JSON, for reference only.

## Regenerating

Edit the SVGs (24 grid, 1.75 stroke with round caps and joins, currentColor, nothing outside 1…23), then run
`python3 assets/icons/tools/build.py`. It writes the Swift paths, the web package data and sprite, the Tk PNGs and the
tray icon. `contact.py` draws a contact sheet, and `verify_swift.py` compares the Swift rendering against the SVGs pixel by pixel.
