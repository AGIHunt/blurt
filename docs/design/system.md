# blurt design system (v0.8)

> **中文摘要**
> 这是口喷鸡的设计系统 v2，macOS 应用和 Tauri（Windows / Linux）应用已经按它实现；官网之后按它重做，这次没改。
> - **品牌色是薄荷 `#61DBBD`**，含义：口喷鸡正在听、正在截、正在替你动手；另外用于每屏唯一的主操作和列表选中行的浅薄荷底。
> - **品牌渐变**：清新绿 `#66D97A` → 薄荷 `#61DBBD` → 天蓝 `#4AABE2`，薄荷是中间发亮的分界。大面积版本（field）带弧形分界和细颗粒（grain）。
> - **主按钮用更深的"按钮渐变"**（`#028932` → `#02866F` → `#087EB3`，同一条色相路径），上面是**白色粗体字**，每一点都 ≥ 4.5 : 1。薄荷小标签、徽章仍用深绿字。
> - **渐变字只剩引导页标题**（24 pt）；空状态标题、Lab 分数、听写页统计都改回中性色。
> - **系统控件用品牌色**：App 声明了 `AccentColor`（浅色 `#0B735E`，深色 `#1CA288`），开关、复选框、滑块、焦点环跟着走；网页端用 CSS `accent-color`。
> - **多彩"光谱"渐变**（加黄和紫）**只出现在引导页主视觉**（小鸡背后一团静止、模糊的光）。**(收敛)** 去掉了"AI 正在处理"的旋转彩色光圈和完成时的庆祝光环。
> - **"AI 正在处理"** = 原有的转圈 + 一条静止的 **1 pt 薄荷细线**（`brand.working`，半透明的品牌墨绿）围住正在处理的那一行；横幅只换成转圈，不加边框。不旋转、不多色、不发光。
> - **空状态**统一用一个组件：App 图标（渐变底板上的 4A 小鸡，80 pt 画布、64 pt 底板），下面中性标题、中性说明、最多一个主按钮。
> - 实时文字面板下的渐变横线去掉了。所有装饰性的渐变、光晕、描边的去留见 §14。
> - **最近拖走的（v0.9）**：紧凑的行（缩略图、一行备注、拖走时间和保留天数）；鼠标指到的那一行才出现浅薄荷底、「复制」主按钮和「···」，同一时间只有一个主按钮。语音备注的缩略图是浅薄荷小方块 + 品牌墨绿的声波 + 时长，不再是放大的麦克风。完成类提示（已保存、已复制）带叶绿 ✓。
> - 红 = 正在录，琥珀 = 要你处理，叶绿 + ✓ = 完成。珊瑚只剩画笔。task 类型改为紫色。
> - **App 图标**：白身黑线的鸡（方案 A）放在渐变 field 底板上。
> - **吉祥物就是 logo 那只鸡**（§6.1）：4A 线条小鸡本身的几何，暖黄身体、图标的黑线、珊瑚色嘴，用代码画、用代码动（跳、眨眼、扇翅膀、声波跳动、破壳）；之前那只 1A 位图圆鸡在 Mac 上退役，网页端暂时还在用。
> - 唯一来源：`assets/color/tokens.json` + `assets/color/build.py`（生成 Swift `BrandColor`、CSS 变量、`AccentColor`，`--check` 检查过期和对比度）。

Status: **v2, implemented; toned down (v2.1, "restrained", §14)** in the macOS app (`skills/blurt/recorder/macos`), the web UI packages (`web/packages/ui`,
`web/packages/review` → `skills/blurt/scripts/review.html`) and the Tauri app's UI (`web/apps/desktop`,
`web/apps/overlays`). The site (`site/`) is not migrated (§3.8). It supersedes the v1 colour proposal and the visual
parts of [desktop-app.md §2.4](desktop-app.md#24-视觉语言).

The user amended the v2 proposal before it shipped; those amendments are folded in below and marked **(amended)**:
gradient text for large headlines, native controls in the brand accent, white text on a deeper button gradient, and a
multi-hue spectrum for special moments. v2.1 then toned it down (§14): the spectrum is left only in the onboarding
hero, "AI is working" is a spinner plus a 1 pt hairline, empty states show the app icon.

Mock-ups and screenshots (untracked, in `promo/cases/v0.8-color/`):

| File | What it shows |
|---|---|
| `restrained/sheet*.png` | **v2.1**: job rows + banner, island job row, live-text panel, empty states, before (d3e80209) / after, light and dark. |
| `applied/contact-sheet*.png` | **Real screenshots** of the test builds, before (77f1ddd9) and after, light and dark, en and zh; the icon. |
| `applied/web/`, `applied/icon/` | The web UIs (review page, Tauri app, overlays) before / after; the icon at every size. |
| `v2-palette.png`, `v2-surfaces.png`, `v2-app-icon.png`, `v2-dos-donts.png` | The synthetic v2 proposal (before the amendments). |
| `palette.png`, `before-after.png`, `app-icon-options.png` | v1 (flat mint, yellow icon), kept for the record. |

---

## 1. Principles

1. **Mint marks blurt in the act**: listening, capturing, or about to act for you. It also marks the one primary
   action on a screen and the selection in lists blurt draws. If a new use can't be described by that sentence, it
   doesn't get mint.
2. **The gradient is mint's premium form**, for *few, large or hero* things. It is never a background for reading,
   and never a thin line, except the one capture selection.
2a. **Use it with reason (v2.1).** Every coloured effect must say something the plain UI doesn't (blurt listens,
   this is the selection, this is the primary). Decoration that only adds sparkle goes: no rotating or multi-colour
   rims, no glow halos around rows or banners, no completion blooms, no decorative underlines.
3. **Most of the app is grey.** Neutral surfaces and text. Colour is information.
4. **Native stays native, in the brand accent (amended).** Switches, checkboxes, radios, sliders, focus rings and
   selection are the system's own controls, tinted by the app's `AccentColor` (`brand.accent`). If the user picked a
   system accent other than Multicolor, macOS uses theirs, as for every app.
5. **Every coloured state has a shape twin**: dashed vs solid, dot vs ring, check vs "!". It must survive grayscale,
   colour blindness and Reduce Motion.
6. **One direction.** Green is up / start, azure is down / end. No reversed gradients. Extra hues (yellow, violet)
   only in the spectrum, and the spectrum only in the onboarding hero art (§2.2).

## 2. Colour tokens

Contrast is WCAG 2.x relative luminance. Floors: **4.5 : 1** for text, **3 : 1** for icons and UI strokes. "Light
surfaces" are `#FFFFFF / #F6F6F6 / #ECECEC`; "dark surfaces" are `#1E1E1E / #2A2A2A / #323232`. The island and the
capture chrome are always dark, so tokens have an `island` value. Hues are OKLab.

### 2.1 Brand: flat

| Token | Light | on light surfaces | Dark | on dark surfaces | Island | Use |
|---|---|---|---|---|---|---|
| `brand.fill` | `#61DBBD` | 1.70 / 1.57 / 1.44 | `#61DBBD` | 9.82 / 8.46 / 7.56 | `#61DBBD` (12.38 on black) | Small mint fills that carry `brand.on` text (badge, size label, handle, clasp). Marks on dark and over screen content. **Never a line or text on a light surface.** |
| `brand.ink` | `#0B735E` | **5.79 / 5.36 / 4.90** | `#61DBBD` | **9.82 / 8.46 / 7.56** | — | Brand as text, icons, state rings, underlines, 1–2 pt lines. |
| `brand.tint` | mint @ 18 % (= `#E3F9F3` on white) | `brand.ink` on it 5.27 | mint @ 16 % (= `#293C37` on `#1E1E1E`) | `brand.ink` on it 6.89 | @ 20 % (= `#132C26`) | The pale mint wash: selected row, drop target, badge / chip background. Text on it stays neutral `ink`. Increase Contrast: `#0B735E` @ 20 % / mint @ 32 %. |
| `brand.working` **(v2.1)** | `#0B735E` @ 60 % | 2.64 / 2.56 / 2.46 (composited) | `#61DBBD` @ 50 % | 3.47 / 3.25 / 3.07 | `#61DBBD` @ 50 % (3.53 on black) | "AI is working on this": the one static **1 pt hairline** just inside the working row's rounded edge (`WorkingOutline`, `.aiWorking`, CSS `.ai-working`). An accent next to the spinner, which carries the state. Floor 2 : 1 composited (`minOver`); Increase Contrast `#035948` @ 80 % / `#7FE6CC` @ 70 %. |
| `brand.on` | `#04261E` | 9.51 on fill, ≥ 6.31 on the gradient | `#04261E` | same | `#04261E` | Text and glyphs on mint and on the gradient. |
| `brand.onInk` | `#FFFFFF` | 5.79 on `brand.ink` | `#04261E` | 9.51 | — | Rare: text on a `brand.ink` fill. |
| `brand.accent` **(amended)** | `#0B735E` | 5.79 / 5.36 / 4.90; white on it 5.79 | `#1CA288` | 5.22 / 4.49 / 4.01; white on it 3.19 | — | Native controls: the `AccentColor` asset and CSS `accent-color`. Switch-on track, checkbox / radio fill, slider, focus ring, selection. |

`brand.ink` under Increase Contrast: `#035948` (light) / `#7FE6CC` (dark).

**Why the dark accent is not mint.** macOS draws a white knob on the switch track and a white check in the checkbox.
White on mint is 1.70 : 1, so the dark accent is a deeper mint, `#1CA288` (OKLab L 0.64, the same hue): white on it
3.19 : 1 (Apple's own dark blue `#0A84FF` gives 3.65), and the track keeps ≥ 4 : 1 on every dark surface, so the on
state reads as clearly as the system's. In light mode the accent is `brand.ink`: the track is 5.79 : 1 on white and
the white knob / check 5.79 : 1 on it.

On light surfaces mint is 1.7 : 1, so it is only a fill there, with dark-green text. Anything thin uses `brand.ink`,
the same hue (174°) at a usable luminance. In dark mode one value does both.

### 2.2 Brand: the gradient

Three stops, sampled from the reference (fresh green top, airy azure bottom, mint where they meet):

| Stop | Hex | OKLab L / C / h | `brand.on` on it | white on it |
|---|---|---|---|---|
| green | `#66D97A` | 0.80 / 0.17 / 147° | 9.05 | 1.78 |
| mint (= `brand.fill`) | `#61DBBD` | 0.81 / 0.12 / 175° | 9.51 | 1.70 |
| azure | `#4AABE2` | 0.71 / 0.12 / 237° | 6.31 | 2.56 |

**Mint is the seam.** A straight OKLab mix of green and azure passes 178°, L 0.75 at the middle. `#61DBBD` sits on
that hue path, 0.06 lighter, and that is the glow where the colours meet. So the flat brand mint needs no re-tune: it
is the gradient's brightest point. Flat mint and gradient read as one family.

Variants (all in `tokens.json` → `gradient`):

| Token | Definition | Use |
|---|---|---|
| `gradient.linear` | `green 0 %` → `mint 45 %` → `azure 100 %`, **corner to corner** (CSS `to bottom right`; CAGradientLayer `startPoint (0, 1)` → `endPoint (1, 0)` in an unflipped layer). No grain. | The capture selection stroke, level bars (vertical), the listening glow; dark `brand.on` text where text sits on it. |
| `gradient.button` **(amended)** | `#028932 0 %` → `#02866F 45 %` → `#087EB3 100 %`, corner to corner: the same OKLab hues (147° / 175° / 237°) at L ≈ 0.55. **White semibold text ≥ 4.51 : 1 at every point** (≥ 4.22 at hover ×1.04). | Primary buttons (one per view), Snap / Record in the picker, the island's filled buttons, toast actions. |
| `gradient.text` **(amended)** | Light: `#14983C` → `#07957C` → `#248CC2` (≥ 3.17 : 1 on every light surface at every point). Dark: the base stops (≥ 5.02 : 1). Horizontal. | **The onboarding title only** (v2.1; 24 pt bold). Empty-state titles, the Lab score and the Dictation stats are neutral again. Flat `brand.ink` under Increase Contrast. |
| `gradient.spectrum` **(amended)** | `#FFD54F 0 %` → green 24 % → mint 46 % → azure 70 % → `#9D7BF7 100 %` (conic: the same stops round the circle) | **The onboarding hero art only** (v2.1): a still, blurred disc behind the mascot (`SpectrumGlow`). Never on rows, banners, buttons, rims, pills or celebrations. |
| `gradient.vertical` | Same stops, top → bottom, sized to the group (18 pt for the island level) | Level bars: one gradient across the whole bar group, so each bar shows the slice at its height (short bars read mint, tall ones show green tips and azure feet). |
| `gradient.field` | Bottom → top: base linear 180° `#66D97A` → `#69DC95`. A large azure ellipse rises from the bottom-left (centre (0.28, 1.16), radii (1.08, 0.80) of the box): `#3C9ED5` 0 → `#4AABE2` 0.5 → mint 0.70 → a glow `#A3F0DA` @ 60 % at 0.79 → clear at 0.93. A second azure from the bottom-right (1.02, 1.08; 0.58 × 0.52). An airy top highlight `#80E991` (0.62, −0.12; 0.75 × 0.48). Then **grain**. | Large surfaces ≥ 64 pt: the app icon tile and the onboarding hero (empty states now show the app icon itself, §3.5). The ellipse's mint rim is the large organic curve of the reference. |
| `gradient.deep` | The field with stops `#4ABF61` → `#43C1A4` → `#2C92C8` (0.08 darker in L), corners `#2786BD`, glow `#5FC9AC`. `brand.on` ≥ 4.65. | The field in dark mode (onboarding); the icon's optional dark appearance. |
| `gradient.glow` | `gradient.linear` horizontal, blurred 24 pt, 35–55 % | The island's listening aura only (it says "blurt hears you"). Only while listening. |
| `grain` | Monochrome fractal noise (base frequency 0.8 / px at 1x, 2 octaves, contrast ×3), **overlay** blend, **10 %** light / **8 %** dark, **7 %** on the app icon | Only on `field` / `deep` surfaces **≥ 64 pt** in both dimensions. Never on buttons, bars, strokes or text. Off with Reduce Transparency. |

Contrast on the gradient: `brand.on` holds ≥ 6.31 : 1 along `linear` and ≥ 4.65 along `deep`. White fails on the
base gradient (1.70–2.56), so **white text sits only on `gradient.button`** (≥ 4.51), which is why primaries use it;
dark `brand.on` text stays on flat mint chips, labels and badges, where it looks better (9.51 : 1) and the chip stays
light. As an edge against a light surface, the gradient is a fill, never a line. The capture stroke gets its own dark
under-stroke.

### 2.3 Semantic

| Token | Light | on light | Dark | on dark | Island | Use |
|---|---|---|---|---|---|---|
| `rec` | `#FF3B30` | 3.55 / 3.28 / 3.00 | `#FF453A` | 4.89 / 4.21 / 3.76 | `#FF453A` | The tape is rolling: record dot, recording frame, countdown ring, Stop. **Never text** (use `err`). |
| `attn` | `#B86E00` | 3.99 / 3.69 / 3.37 | `#F5A524` | 8.17 / 7.03 / 6.28 | `#FFC23D` | Needs you / paused / to verify: dots, rings, icons, the paused frame. |
| `attnInk` | `#946008` | **5.34 / 4.94 / 4.52** | `#F5A524` | 8.17 / 7.03 / 6.28 | — | Attention as text. |
| `onAttn` | `#FFFFFF` (3.99) | | `#2A1A00` (8.26) | | | The "!" on an attention disc. |
| `ok` | `#3F7414` | **5.65 / 5.22 / 4.78** | `#8ACB4E` | 8.52 / 7.34 / 6.55 | `#8ACB4E` | Done, saved, applied. **Always with a check shape.** |
| `onOk` | `#FFFFFF` (5.65) | | `#13250A` (8.28) | | | The check on a success disc. |
| `err` | `#C02F35` | **5.68 / 5.25 / 4.81** | `#FF6B6B` | 6.01 / 5.17 / 4.62 | `#FF6B6B` | Error text and icons. Destructive buttons use the system red. |
| `info` | `#3A5BD9` | 5.71 / 5.28 / 4.83 | `#8DA4EF` | 6.90 / 5.94 / 5.30 | — | Informational icons (rare). |
| `markup` | `#FF5C3D` | — | `#FF5C3D` | — | `#FF5C3D` | **The pen**: strokes burned into screenshots, with a 45 % black halo. Content, not UI. |

**Success vs mint.** `ok` is a leaf green (134° light, 132° dark): yellow-green against mint's blue-green, and
olive-dark against pale mint in light mode. The gradient's green stop (147°) is close to it, which is why `ok` is a
shape rule too. Done is always a filled disc with a check, "Saved" always has a check glyph, and the gradient never
carries a done state.

### 2.4 Neutrals and native

The platform surfaces stay as they are in `web/packages/ui/src/tokens.css`.

| | Light (mac) | Dark (mac) | Win / GNOME |
|---|---|---|---|
| bg / bg-2 | `#F6F6F6` / `#ECECEC` | `#1E1E1E` / `#242424` | see tokens.css |
| panel / raise | `#FFFFFF` / `#FFFFFF` | `#2A2A2A` / `#323232` | see tokens.css |
| ink / ink-2 / mute / faint | black 85 / 70 / 56 / 32 % | white 92 / 78 / 64 / 40 % | — |
| line / line-2 | black 8 / 13 % | white 8 / 13 % | — |
| island | `#000000` | `#000000` | — |
| capture glass | white 0.05–0.08 @ 72–82 % | same | — |

Text that must be read — item IDs, project keys, times, shortcut hints, however small — is at least `mute`
(`secondaryLabelColor` on the Mac). `faint` (`tertiaryLabelColor`, about 2 : 1) is for disabled text, closed states
(won't do, discarded) and decorative strokes only.

Neutrals never tint toward mint. **Native controls use the brand accent (amended)**: the app declares
`NSAccentColorName = AccentColor` (an asset compiled into `Assets.car`), so AppKit and SwiftUI controls, focus rings
and `Color.accentColor` resolve to `brand.accent` while the user's system accent is Multicolor (the default); a user
who picked another accent keeps it. The web UI sets CSS `accent-color: var(--brand-accent)` and
`--focus: var(--sys-accent, var(--brand-accent))` (the macOS host injects its accent as `--sys-accent`). Code that
means "brand" uses the explicit `BrandColor` token, never `controlAccentColor`, so it stays brand in every case.

### 2.5 Item kinds (icon colours)

These are icon tints only (and the kind chip in the review page). Floor 3 : 1 on every surface, including `#EAEAEA` /
`#383838`. **Balanced (v0.9)**: the four sit at one OKLCH lightness (≈ 0.56 light, ≈ 0.75 dark) and a moderate
chroma (0.12–0.17), so no kind shouts in a list. Before, the issue red (C 0.19) dominated a list of mostly issues on
light, and the idea yellow (L 0.85) did on dark.

| Kind | Light | on `#FFF / #F6F6F6 / #ECECEC / #EAEAEA` | Dark | on `#1E1E1E / #2A2A2A / #323232 / #383838` | vs v0.8 |
|---|---|---|---|---|---|
| issue | `#BB493A` | 5.09 / 4.71 / 4.31 / 4.23 | `#EE8771` | 6.62 / 5.70 / 5.09 / 4.66 | brick, calmer (was `#D9432A` / `#FF7A5C`, C 0.19) |
| idea | `#A26D05` | 4.44 / 4.11 / 3.76 / 3.69 | `#E1AE51` | 8.24 / 7.09 / 6.33 / 5.79 | dark much less bright (was `#A8710A` / `#FFC53D`) |
| note | `#4467D2` | 5.10 / 4.72 / 4.32 / 4.24 | `#90A7F1` | 7.13 / 6.14 / 5.48 / 5.02 | a touch less chroma (was `#3E63DD` / `#8DA4EF`) |
| task | `#7559CB` | 5.19 / 4.80 / 4.39 / 4.31 | `#AA98F2` | 6.73 / 5.80 / 5.18 / 4.74 | a touch less chroma (was `#7650D8` / `#A994F5`) |

Custom lenses (`KindStyle.customColor`, `kinds.ts customKindColor`): if the hashed hue lands in **145°–190°** (HSL),
add 60°, so no lens looks like brand or success.

### 2.6 Icons: the family (v0.9)

One line family for everything we draw ourselves (`assets/icons/*.svg` → `build.py` → Swift `BlurtIconPaths`, web
`@blurt/icons`, Tk PNGs). New icons follow these rules; `tests/test_icons.py` checks the mechanical ones.

- **Grid**: 24 × 24, y down. Keylines: the safe area is 2…22; a glyph's live area is about 3.5…20.5 (17 units).
  Circles and diagonals may reach 2.5 / 21.5 so they look as big as squares.
- **Line**: 1.75 units, round caps and joins, everywhere, at every size (a 16 px icon draws a 1.17 px line, an 18 pt
  one 1.31 pt). No hairlines, no mixed widths. Corners: radius 2.5–4 on boxes (4 on a 15-unit square), 2 on small
  joints. Fills only for dots (≤ 1.25 radius: an eye, a tag's hole) and the `-fill` media variants.
- **Detail**: as few strokes as the metaphor needs; nothing closer than 2 units (it fills in at 14 px). Counters in
  small shapes (a quote's dot, a circle) stay ≥ 2.5 units across.
- **Size in use**: 16 px / pt in rows, chips, cards and menus; 18 in macOS list rows and headings; 14 only for a
  glyph inside a button next to 12–13 px text. Never below 13.
- **Groups**: `brand` glyphs are always our drawing; `generic` ones use the SF Symbol on macOS (`sf-symbols.json`)
  and our drawing elsewhere. Toolbars and sidebars stay SF Symbols on macOS (native), the web draws ours.

**The kinds** are one set of their own and always our drawing, on every platform (never SF Symbols, so they never mix
two families in one column):

| Kind | Icon | Metaphor | Footprint |
|---|---|---|---|
| issue | `bug` | a beetle: one capsule body, a head line, a centre seam, two legs a side, two antennae | 17 × 17 |
| idea | `lightbulb` | a bulb with a shine arc and one base line | 14 × 18 |
| note | `document` | a page with a folded corner and two lines | 14.5 × 18 |
| task | `checkbox` | a rounded square (r 4) with a tick (not a list: a task is one thing to do) | 16.5 × 16.5 |
| custom lens | `tag` | a tag with its hole, in the lens's hue (§2.5) | 17 × 17 |

Each is drawn alone in its kind colour (outline, no tile, no duotone): rows stay calm and the colour stays a mark,
never a block. Sizes: 18 pt in macOS list rows (the 18 pt slot beside the 14 pt state ring), 16 in the filter
segments, menus, the palette and every web surface (queue rows, chips, cards, the detail's kind chip), 18 in overview
headings. Code: `KindStyle.image(kind, size:)` / `Look.kindImage` (macOS), `<KindIcon kind size/>` (web). The
comparison that chose this (today vs line / tinted chip / duotone, light and dark, real sizes) is in
`promo/cases/v0.9-next/kind-icons/`.

Neighbours, checked at the same sizes: the state rings (drawn, 1.5 pt line at 14 / 18) and the macOS toolbar and
sidebar (SF Symbols) sit well with the kinds. On the review page `quote` was the one clear outlier (a closed "99"
that read as bold digits) and is now two open rounded marks. Still to look at: `git-pull-request` (its 2.5-unit
circles close up at 13–14 px), `merge` (a narrow Y, lighter than its neighbours), `film` (a dense grid at 14) and
`languages` (letters, busier than the rest).

### 2.7 Work surfaces: marks that must not collide (dogfood-2)

- **Session status marks** (TerminalStyle `SessionStatusMark`): one shape per state, so they read in grayscale — running a
  turning arc, waiting an attn disc with "!", turn done an ok disc with a check, error an err disc with "×" (never a bare
  red dot: that is the recording dot, §2.3), exited a hollow ring, in the desktop app an outward arrow.
- **Places**: 进行中 (In Progress) uses the in-progress ring's shape (`circle.righthalf.filled`) in the sidebar and ⌘K —
  never `circle.dashed`, which is the new ring. All Items is `list.bullet.rectangle` everywhere.
- **⌘K / menus**: Copy Instruction `doc.on.doc` (the copy glyph, not the dense clipboard), Reveal in Finder
  `arrow.up.forward.app`, Move to Project… / Move to X `arrow.turn.up.right` — `folder` means a project only.
- **Organise** is `sparkles` on every surface (job rows, the item banner); the wand stays dictation polish, and the
  Settings → Agents pane uses the hand-off `paperplane`.
- **Key hints** (`kbd`) are set in the UI font, tabular figures, as macOS menus set their keys — in a monospace the letter
  O reads as zero.
- **The quote mark** (`quote`) is two open comma marks, a dot and a hook each — no closed counters, so it never reads as
  "66" at 16 px.

## 3. Usage by surface

Legend: **G** = gradient (`linear` unless noted), **B** = `gradient.button` with a white title, **S** = the
spectrum, **M** = flat mint (`brand.fill`), **I** = `brand.ink`, **T** = `brand.tint`, **—** = no brand colour.

### 3.1 Capture (picker, chrome, flashes): always over screen content

| Element | Brand | Detail |
|---|---|---|
| Selection outline | **G** stroke | 2 pt dashes (6 / 4), the gradient corner to corner across the selection, over a 2 pt `brand.on` @ 60 % solid under-stroke so it holds on white and black. The dashes march (10 pt/s) while dragging and stop with Reduce Motion. *The only thin gradient line in the system.* |
| Handles | M | 9 × 9, r 2.5, 1.5 pt white ring, 1 pt shadow |
| Size label | — | v0.9-overlays: one value, the snap's pixels ("1800 × 1120", 11.5 medium monospaced digits, thin spaces), on the capture surface (black 88 %, 0.5 pt white 14 % hairline — `CaptureGlass`), outside the selection's top-left corner (inside it when the selection meets the menu bar). The mint stays on the outline and the handles, so the label never outshouts the primary |
| Snap / Record button (picker toolbar) | **B** | white semibold title led by the island's own line glyph in white — `record` before "Start recording", `snap` before "Snap" — and its key, "↩", in white 60 % after it (`PillButton(icon:gradient:fg:key:)`) |
| Picker toolbar | — | v0.9-overlays: one row on the capture surface (`CaptureGlass`, radius 22, under the selection): Cancel, Full screen and Last area (when there is one) as quiet round glyphs (`GhostButton`: no fill at rest, white 12 % under the pointer; their names and keys in the tooltips — "Full screen  F"), a hairline, then the one primary. While a snap's drag draws there is no toolbar (letting go takes the shot, as ⌘⇧4) |
| Hint pill | — | v0.9-overlays: `PickerHint`, bottom centre 36 pt above the Dock (where the macOS screenshot bar sits, away from the notch and the island); at the top under the menu bar when the hovered window covers that spot; gone once there is a selection or a drag. The mode's glyph, one sentence (13 medium, white 92 %: "Drag an area or click a window to snap it"), a hairline, then the keys as keycaps (`KeyLine`): [F] Full screen  [L] Last area  [esc] Cancel (12, white 62 %). The legend shows the first three pickers only (`HintBudget`), then just [esc] Cancel; "?" brings it back |
| Dim outside the selection | — | black 42 % outside a selection or a hovered window; 22 % while nothing is under the pointer yet (the windows to choose from stay readable) |
| Window hover | M + T | 2 pt mint line, flat `brand.tint` (island, 20 %) inside; what a click does ("Click to snap this window" / "Click to select this window"), centred on it, on the capture surface with white text (v0.9-overlays: no longer a mint pill repeating the hint) |
| Countdown | `rec` ring, M chip | v0.9-userfix: a piece of the island over the area (black, radius 24, the window's soft shadow, 0.5 pt white 12 % hairline): the number (44 semibold, monospaced digits, white 92 %) in a 3 pt ring on a white 12 % track that drains in `rec` — the recording is committed; the 4A chick (26 pt, `listening`) beside "Get ready" (14 semibold); the pause / finish keys as keycaps, each with one word ("[⌥⇧P] Pause  [⌥⇧S] Finish", `KeyLine`, 11.5, white 60 %); *Start now* as the island's tint chip in mint (a click anywhere on the area starts too). Over an area smaller than the panel and its shadow, the countdown's window grows to fit, centred on the area and kept on its screen (BlurtCore `OverlayFit`) — the panel is never cut |
| Recording frame | `rec` | solid 2.5 pt with a 1 pt black 35 % keyline just outside it (it holds on red, white and busy content), all outside the recorded pixels. Paused: `attn` dashed. The switch from mint to red at the end of the countdown *is* the "now recording" signal. |
| Snap while recording (`borderFlash`) | M | 3 pt flat mint ring, 450 ms, outside the red frame (v2.1: no halo) |
| Standalone snap shutter | — | white flash |
| Pen strokes (InkView, InkCanvas on the frozen snap and in Edit Note, `renderMarked`) | `markup` | coral, with a 45 % black halo (shadow radius 0.4 × the width); 3–6 pt by display size (`InkStyle`) |
| Frozen snap (in-place markup) | G outline (still) | the picture at 1:1 where it was taken, the outside dimmed 42 % as in the picker; the selection outline stays, without handles and without marching; the pen hint is a faint pill above it (black 42 %, text white 65 %, 12 pt regular — quieter than the picture and the bubble; first 3 times only, gone at the first stroke) |
| Live caption, HUD text | — | white on glass |

### 3.2 Notch island and hanging cards

| Element | Brand | Detail |
|---|---|---|
| Listening (dictation, voice note): level bars | **G** vertical | one gradient across the bar group |
| Listening aura | **glow** | `gradient.glow` under the notch at 35–55 %, fades in over 200 ms when listening starts and out when it stops. Only while listening or capturing; never while idle. |
| Dictation keyboard glyph, voice mic glyph | M | |
| Voice note Structured (v0.9-userfix) | T + M | the open island's chip under the chick: the `list` glyph and "Structured" — quiet (white 8 %, text 60 %) while off, the mint tint chip with mint text while on (as *Pen on*); the right ear then shows dictation's list mark before the time, and a click on the ear toggles too |
| Recording ear | `rec` dot + white time | paused: the pause bars (not the dot) and the time in `attn` — never colour alone. The dot's breath is shallow (1.6 s, never below 80 %). The right ear: the pen while it is latched or its key is held (M), else the stills taken (the snap frame), markers apart (a flag), else the level — four bars that rest at staggered heights in white 30 % in silence and while paused, the **G** gradient only with a voice (never four mint dots). When a take ends (not a discarded one) the dot and time turn, in place, into the `ok` check and the take's length ("✓ 0:42") for 1.6 s, as dictation's "Sent" (`RecordingDone`). **Open** (v0.9-overlays): one row — pause (paused: a labelled *Resume* in `attn` on its 20 % tint), snap … a quiet ··· and *Finish* (the one filled thing: `rec` a step deeper, #D92D20, so its white title clears 4.5 : 1) — and, only when it has something to say, one quiet line: *Pen on · Esc to stop* (a tint chip, click = off), or for the first three takes the pen hint with every modifier a keycap, what was spotted, and the project as quiet text with its key badge. No meter in the row: the ear has the one. The ··· menu holds the rare things with their keys: Draw on the Screen (⌥⇧D), Add a Marker (⌥⇧M), Discard or Restart…. Discard asks first: the question alone on its line (13 semibold, never cut), what goes with it on a quiet second line ("Goes with it: 2 snaps and 1 marker"), then Discard · Restart · Keep Recording — Keep where Finish was, and the default: filled with the brand gradient like every suggested answer in the island, chosen by ↩ (the question takes the keyboard while it shows; Esc closes the island and keeps the take too); Discard furthest from it, a neutral pill with its title in `err` — a destructive button is never the one that stands out. The mic level is **G** (blurt hears you), but there is **no glow**: red owns that moment. |
| Ears | — | each ear's content sits 14 pt from the island's **outer** edge (`IslandLayout.earOrigin`), so a glyph keeps one leading x and a number one trailing x through every state; content wider than 56 pt widens both ears (`IslandLayout.earSpan`) rather than giving up the inset ("✓ 已发送" sat 4 pt from the corner); the other ear's content stays where it was (`IslandLayout.earReach`: measured from the notch by its own need, the extra black outside it), so a glyph never jumps because the ear across the notch grew; content never cross-fades (no implicit layer actions). One live meter at a time: with the voice island open the left ear shows the mic glyph, the waveform is the row's. **Every ear glyph is our line family at one weight** (`BlurtIcon`, 13 pt for a count): the cards count is the `cards` stack with its number in mint (the cards' clasp colour); the inbox count is the `inbox` tray at 60 %; stills the `snap` frame, markers the `flag` — no filled SF Symbols beside dictation's line keyboard. Dictation's clock turns `attn` from 4:30, when it counts down to the limit (not only a minus sign) |
| Island buttons | — | the round buttons and the glyphs in the island's pills are our line family too (`IslandButton(icon:)`: record / snap / mic on home, pause / snap / trash / stop while recording, the check on Done, the pencil on *Pen on*): the mic that starts a voice note is the mic on its card. The drawer's list rows keep SF Symbols, as any Mac list. Unassigned is `tray.2` everywhere (the chip, the switcher, the menu bar, the note's *Goes to*): the tray is the Inbox |
| A project whose folder is gone | — | `questionmark.folder` in tertiary, the name in secondary, "Folder not found · Locate…" — in the switcher, the drop drawer, a card's *Move To ▸* (and its VoiceOver actions), the note's *Goes to* list, and the island's project chip when it is the current one. Nothing is ever filed into it (`ProjectStore.filing` / `captureTarget`, `Snapper.keepAsCards`): captures stay cards, a recording goes to Unassigned, and the island says "Can't find X's folder — kept as a card · Locate…". Locate… (`MissingFolder.ask`, also the main window's) asks where the folder is now and only takes a folder holding this project's store — any other is refused inside the panel, which stays open; found (projects.py add relocates), it takes the kept cards |
| Live-text panel | M caret | the island's **lower half**, not a second pop-up: the island's black (`#000`), 6 pt under it, exactly the open island's width under a voice note (radius 22) and the ears + 24 pt a side under dictation (radius 14), with the window's soft shadow; no blur, no border. The width is the island's *without* a toast, so a toast during a take never re-wraps the words. On a capsule screen (no notch) the capsule widens to 292 pt while the panel shows (the notch-with-ears proportion; the panel 340, radius 15) — never a 340 pt panel under a 120 pt pill. Text 92 % white (committed) / 60 % (pending: dictation's piece still being said, provisional until its transcript lands). Up to three lines, newest at the bottom; the panel keeps the height it reached during a take. Once the text has gone in (white, the ok check), it shows from its top, up to eight lines, the last one fading out when there is more (`IslandLayout.liveLines`): a Structured list keeps its heading before a double tap sends it. While it fades it keeps its width and stays on the island's edge; under an open island (a voice note) it goes when the island closes (`IslandLayout.livePanelGoes`), never narrowing and dropping loose below the new card. A flat mint 2 pt caret while listening. **No rule under the text** (v2.1: the island's level bars already say blurt hears you). |
| Alert dot | `attn` | |
| List rows: selection / hover target | T (island 20 %) | |
| Check marks, progress, quoted query | M | |
| AI sort / organize running | `brand.working` | the row's own progress bar plus one static 1 pt hairline round the row (`WorkingOutline`, island value). When it finishes the chick hatching in the ear says so: no bloom. |
| Agent dots | M running · `attn` waiting · `err` error · `ok` finished | |
| Filled island buttons (Organize, voice Done, toast action) | **B** | white semibold title (`IslandButton(gradient:fg:)`), composed of layers (never drawn: a drawn view showed scanline seams while the island grew); the title is a picture of the line drawn with font smoothing (`TextImage`), since a `CATextLayer` draws without it and the semibold came out as light as regular |
| Stop / Discard | `rec` / system red | |
| Hanging-card threads | — | neutral hairline with an opposite-tone halo |
| Clasps | M | ringed in the card surface |
| Picked card border | M | 2.5 pt flat (thin, so no gradient) |
| Voice card mic mark | I on the card face | |
| Hover note's play button | M | flat mint circle, `brand.on` glyph (white on mint was 1.9 : 1). The note itself only shows what the card can't: the rest of a cut-off note, the play button |
| "+N" tile (the cards that don't hang) | — | the card surface, one offset edge behind, the count in `ink` — no ghost of the next picture under it (no pill, no colour); opens the overview. Never a "+1" for a card that fits (`CardRow.layout`). Recently Dragged Out and the overview open below the strip the cards hang in (`CardRow.panelTop`), so a card put back never covers them |
| Snap card shape | — | `CardShape`: 84 pt high, as wide as the picture wants within 84–150 pt; aspect fill while it cuts ≤ 40 % of the picture, else the whole picture on the card's opaque surface (a toolbar, a sidebar; the same surface as the "+N" tile, never a translucent grey that picks up the wallpaper) — the overview tiles and capture tiles follow the same rule. The marks (mic, ink) lead the dark band's first line in white — the note's, or the status line's when there is only a status; the dark capsule is only for a bare picture. "Couldn't transcribe" is in `attn` and keeps the mic mark (the audio is there to retry: `CardNote.marksMic` / `needsYou`), on the card, the voice card and the overview tile; "Transcribing…" stays quiet |
| Keyboard focus on a card / the tile (⌥⇧H) | `brand.accent` (native) | 2.5 pt ring, 4 pt outside the card (`BrandColor.accent`) |
| Project folder icons | project colour | `ProjectLook`, minus `.systemMint` / `.systemTeal` |
| Recently Dragged Out rows (v0.9) | T hover + **B** | compact rows (56 pt): the capture tile, the note on one line (a snap without one: "Snap · 19:03", its card's name, with its day once it isn't today's, in the user's 12/24-hour clock), "dragged out …" — and "· kept 1 more day" in `attnInk` only on its last day (the footer says "7 days" once for all). With no card hanging the panel opens right under the island; Put Back moves it down below the card strip as the card hangs again. The row under the pointer gets the `brand.tint` wash (r 8) and shows its actions: **Copy** as the one primary (`BrandButton`, 12 pt) and a quiet "···" (the rest; also the right-click). A row holding keyboard focus shows them the same way (never a focus ring on a hidden button). No buttons on the other rows; no row separators; a hairline above the hint |
| Capture tile (Recently Dragged Out, the island menu) | T + I | `CaptureThumb`: a shot fills a rounded tile (aspect fill, 0.5 pt hairline); a voice note is a `brand.tint` tile with the waveform (`BlurtIcon.waveform`, ≤ 18 pt) in `brand.ink` and its length (10 pt mono, secondary). One size per list (56 × 40 in the panel, 30 × 20 in menus), so titles line up. Never a bare glyph scaled up to the tile. Two voice marks on purpose: the **waveform** stands for a recording whose words are not shown (a tile, next to its title); the small **mic** on a card or an overview tile says "these words were spoken" over the words themselves (the same mic as a screenshot card's spoken note) |
| Done toast ("Recording saved", "Copied", "Reformatted as …") | `ok` ✓ | the check (SF `checkmark`, 13 pt semibold) in the island's `ok` before the text (`Island.Toast.icon`). Dictation’s "Sent" is the check and the word in the right ear for 1.6 s (no toast for one word; the ears widen just enough to keep it 14 pt in). A copy that couldn’t be sent says both in one line ("Copied, not sent · paste with ⌘V"); "sending" (a Return waiting for the paste) is the dots there |
| Toasts (all) | — | `ToastQueue`: the newest reply takes the slot (after the one showing has been up 1 s); same key = replaced at once; passive lines (launch, jobs) wait behind replies; stale ones dropped; a reply that goes up supersedes the plain replies before it (never shown after it, out of order); a pushed-out Undo or question comes back, an Undo for the time it had left; ≥ 5 s, held while pointed at. A click on the toast's line opens the island (the toast is held); only its button runs its action — except a line with no button (a peck's "open the item"), which is its own button. Content spans the whole shape (`IslandLayout.toast`): text 18 pt in, the button 14 pt from the right edge (under the right ear's number), a line alone centred. A line too long for the open width wraps — up to three lines, the row 17 pt taller for each — never "…" mid-word. What a toast says ends with what it describes: a new dictation take drops the last take's lines, its tip and the 5-minute limit (not the once-a-day notices with a button: their day is spent when posted); ⇧'s style line goes when the take stops listening (`DictationToastKeys`). The main window's page toasts show here too (host method `toast`): the page waits for "undo" from the button or "gone" the moment the island lets the toast go, and ⌘Z undoes the page's step after the toast is gone |

### 3.3 Main window (AppKit) and the Tauri app

| Element | Brand | Detail |
|---|---|---|
| Primary button (one per view) | **B** | `BrandButton` / `.buttonStyle(.brand)` / CSS `--brand-button`: white semibold title, 1 pt inner top highlight (white 18 %), 1 pt shadow (`brand.on` 25 %). Hover ×1.04, pressed ×0.92. Disabled: neutral fill, no gradient. Small dialog defaults (↩ in sheets and alerts) stay native and show `brand.accent`. |
| Secondary, tertiary buttons | — | native |
| Destructive | system red | |
| List and sidebar selection | T | rounded wash, r 6, text stays `ink`; neutral 6 % when the window is not key. In the sidebar the name is not the cell's `textField` (a source list repaints that one in the accent when selected) — the main window's sidebar and Settings' alike (`SettingsPaneCell`: the symbol in secondary ink, no accessibility description of its own, the cell says the pane once) |
| Status dots | ok / attn / err / quiet | 9 pt (`StatusDot`): every tone has its own shape — good a disc with a check, warn a disc with "!", bad a disc with "×", off a 1.5 pt hollow ring — so permissions, agents, the models step and the guide read in grayscale too. The permission guide's done line uses the same disc at 16 pt |
| Command palette chosen row | T | |
| Move popover (M) | T | one surface: a borderless field ("Move BA-1 to…" / "Move 3 items to…") with a hairline under it, then 28 pt rows. One grid: glyphs 12 pt from the edge, text 36 pt (the field's text and the names on one vertical); the chosen row is the palette's wash, inset 6 pt, r 6, text stays `ink`. Rows look like the sidebar's (outline folder in secondary ink, the key in 10 pt mono); the typed letters in semibold; where the items are now is dimmed with ✓ Current and is never the default. 300–360 pt wide, a longer name cut in the middle (its tooltip has it whole); as tall as its rows; no match: one line, then Open Folder… |
| Focus ring, text selection | `brand.accent` (native) | via `AccentColor`; the user's own system accent wins when set |
| Links | I underline | text `ink`, 1.5 pt `brand.ink` underline; standalone text / link buttons in `brand.ink` |
| State rings new / handed_off / in_progress, job spinner arc | I | one spinner everywhere: `BrandSpinner` (job rows, the item banner, the scanning empty state) is the running step's quarter arc, 1.1 s a turn, still under Reduce Motion; never the grey system spokes. SwiftUI (Settings, the setup assistant, panels) uses `BrandSpinnerView` (10 pt in a dot's column, 14 pt next to text); a bare `ProgressView()` spinner is refused by tests/test_shell_config.py. One signal per row: a row that says "Checking…" has no spinner of its own |
| Labels (en) | — | buttons and menu items in Title Case at display (`Look.menuCase`, web `menuCase`); the string catalogs keep sentence case, so the same words read right inside sentences |
| Kind icons in lists | kind tokens | the kind family (§2.6) at 18 pt in rows, 16 in the filter, menus and the palette; our drawing, never SF Symbols |
| to_verify / done / todo / wontfix / discarded | `attn` + "!" / `ok` + ✓ / secondary / tertiary | |
| "New" counts and badges | M | pill, `brand.on` digits (`CountPill`) on the Inbox only; a project's count is plain secondary digits, so the brand marks on screen stay few |
| The item list (v0.9, Linear's; one grammar in every place) | — | one coloured mark per row: the kind icon (a voice note's waveform in the note colour), then the id in a fixed left column (UI font, tabular, secondary), the title in regular 13 pt (closed items dim), the state ring only where the list doesn't already say it (never "new"; never in a list grouped by state — under the pointer or on the selected row it shows, as the state menu's click target), a short date ("10:42", "Mon", "Oct 24"). No column table anywhere (All Items included): sort is in the Filter menu and View ▸ Sort By. Grouping (`ListSections`): the Inbox by project in the one project order (pinned, then the most recently used — the sidebar, the pickers and ⌘K use it too), Unassigned last; In Progress, All Items and a project by state, what needs you first (To verify, In progress, Handed off, New, To do, Done, Won't do, Discarded), the header a 14 pt ring and the state's name; a search is one flat list; one group alone gets no header. The place's name is the list's 17 pt heading with its counts beside it ("12 of 52" while a search or a filter narrows it; a search's heading is 'Results for “login”'); the kind / state filter is the toolbar's Filter menu (with Sort By), the line "Showing … Clear" above the list only while it is on |
| Item detail (review page, item mode) | B primary + T voice card | one column: id · project breadcrumb with the actions at its end (a Copy split button, then the one primary: Hand Off to Agent, ⌘⏎ in its tooltip; an Unassigned item's primary is Move to Project… — an agent works in a project's folder), the title, one row of neutral properties (severity as bars, a type only once set: an unset one waits in Add Field), a voice note's recording (`brand.tint` panel, play, `brand.ink` waveform, tabular length, ⋯) and its words as the body (its empty Summary waits in Add Field), the fields under one heading style, pictures after the fields with their actions over the corner on hover, provenance as one mute footer line under the one hairline (the capture folder a quiet link, never brand ink) |
| Suggested project (an Unassigned row's "Looks like X · Move", the "Looks like X [Move All (3)]" line above the list) | `brand.ink` on the action word only | the project name in secondary label, "Move" in brand ink 11 pt medium, no pill and no wash: it is an offer, not a state; the group line's button is a plain small bordered button (the one primary stays the view's); the project's folder glyph in its own colour (`ProjectLook`) |
| State menu (a row's ring, S) | the system menu; `brand.ink` only on Hand Off's paperplane | `StateMenu`: hangs from the ring, its image column straight under it, its top just below the row. First line: where the item is (its own ring in its colour, the state, a check; several states: "3 items · New, To verify" with the mixed mark), a separator, then single-line verbs with the list's keys (Accept A, Hand Off to Agent… ⌘↩, Mark as Done D, Send Back / Take Back / Reopen / Restore R), a separator, and the set-aside group (Won't Do W, Discard ⌫). Each verb's image is the shape of the state it leads to in secondary ink at the same 1.5 pt line (`Look.target`): never a coloured ring, a filled disc or a centre dot, which read as the current value, and never a fainter closed state, which reads as off. Only Discard has a line under it ("You can restore it"); the other hints are tooltips and VoiceOver help |
| Several items selected (the detail) | **B** on the one action that can go | `SelectionView`, never the "nothing selected" placeholder: top-aligned at the 24 pt inset — "4 items selected" (17 pt semibold), one secondary line of what the batch is (each kind's 14 pt icon and count, then where the items are), one row of buttons, then the items on a quiet card (kind 16, ring 14, title on one line, key in a fixed mono column; at most 8, else "+N more"; × on hover takes a row out of the selection). The buttons (`MainWindowController.selectionPlan`): Hand Off… (named after the agent when it is already decided), Move to Project… (the Move popover, from the button) and the state action that moves the batch on (Keep, Mark as Done, Reopen…, "(n)" when it applies to some), the rest in a borderless ⋯ menu built from the same StateMenu and Item-menu entries. The primary is Hand Off when HandOffCheck lets it go, else the way out (Move to Project… for Unassigned or mixed projects), with the reason on one secondary line under the buttons. Shortcuts are in tooltips and the menu, never in prose |
| List selection of adjacent rows | T | one continuous band: the wash runs over the gap between rows and only the band's ends are rounded (`BrandRowView`) |
| The current project (where new recordings and snaps go) | — | one mark everywhere it is listed: the `scope` glyph (11 pt, secondary) after its name in the sidebar and in the Move popover, "Current project" in its heading's counts and in its ⌘K row, and the tooltip "new recordings and snaps go here"; Make Current Project uses the same glyph. The Move popover's check means something else: where the items are now ("Here now") |
| Notices above the list (captures waiting for a project, Recently Dragged Out) | `attn` when it waits on you · neutral otherwise | `NoticeCard` (ItemListController.swift): one card a list row high (30 pt), 8 pt below the toolbar, above the kind filter, inset on the list's own grid — its edges where a selected row's wash is, r 6, the glyph on the kind-icon column, the sentence on the title column, one small native button whose edge ends where the times end (`alignNotices` measures the columns). No hairline of its own: the wash (attn-soft, or black 5 % / white 7 %) sets it apart, and the filter bar keeps the one rule above the rows. A plain sentence, 13 pt regular with the count in medium ("3 captures are waiting for a project · Choose Projects…" / "3 条新记下的内容还没选项目 · 选项目…"); never a "Label: N" count, never "Unassigned / 未归类" for anything but that place, the glyph `cards` (the island's count glyph) in `attn`. The whole card is the target (pointer cursor, a 4 % hover wash); ↑ from the first item selects it like a row (the brand tint). No brand colour on it: mint stays live, primary and selection. |
| Move popover (M in the main window) | the system popover | type-to-filter field, rows: check (brand ink) where the items are now, folder glyph in the project's colour, name, key in mono secondary; Unassigned last |
| Project settings sheet (⌘I) | — (native default) | Settings' row grammar (§3.4) in a 480 pt sheet: the project's name (15 semibold) over "Project settings"; sections *Project* (Name, Key, Description) and *Hand-off* / 交给 Agent (Agent, Separate branch for each hand-off), each a 13 pt semibold heading, rows over a hairline, 12 pt between rows and 20 between sections, at most one 12 pt footnote. Labels in one left column, every value's text on one left edge; a locked key is a neutral mono token with a lock and a one-line "Used in item IDs" caption (why it is locked in the tooltip). Description is a 3-line scrolling text view (↩ a line, ⌘↩ saves). The agent popup names the default it resolves to; the branch switch is off with the reason as its description outside git. Footer: the folder (Show in Finder, full path in the tooltip) left, Cancel and the native default Save right |
| Job running (process) | `brand.working` | the spinner plus one static 1 pt hairline round the row (`WorkingOutline`). The item's "still organising" banner keeps its quiet ink wash and swaps its wand icon for a small spinner: no line, no rim. The spinner is always the brand arc (`BrandSpinner`), never the system's grey spokes. |
| Item banner of a hand-off | I wash while the agent works · `attn` wash when it waits for you · neutral 5 % wash once the session ended | `SessionBannerPlan`: the first button is the one primary; two inline at most, the rest in a borderless ⋯ menu (`more`). Ended without a report: Open Session, Restart Session · ⋯ Mark as Done, Take Back. Failed: Restart Session, Take Back · ⋯ Open Session, with the reason ("Codex couldn't start: …") and an `err` icon. Ready to review: Review Changes… (opens the sheet), Take Back · ⋯ Mark as Done. No response (watchdog): `attn`, Open Session, Restart Session. In Claude desktop (`desktop:`): I wash, "In Claude desktop · progress comes from the agent", Go to Claude · ⋯ Open Session, Review Changes… (with a worktree), Take Back — nothing live is claimed. Never Mark as Done as the primary. |
| A session in the agent's desktop app | neutral card | In place of the terminal: "Working in Claude" (the header line doesn't repeat where it is), that Blurt doesn't see it live (and, without the blurt MCP there, that the items need marking by hand) and progress comes from the agent, its items, Go to Claude as the B primary and Review Changes… plain (worktree). The hand-off panel's *Session* row is a radio pair, the terminal first and marked recommended; the desktop choice says once, in a caption, to confirm the folder and press Send in Claude, and without the blurt MCP a quiet info line with Install… (never a blocker). Continue in Claude Desktop… sits in the session's ⋯ menu only when it can work, and asks first; without the blurt MCP the question says progress can't be reported and offers Install… beside Continue. Its status mark is an outward arrow in a ring (`arrow.up.right.circle`), never the spinner and never the handed-off ring's dot, and it isn't counted as running. Without the blurt MCP the item's banner says no progress comes back and puts Mark as Done next to Go to Claude, and the session row reads "waiting for you to mark it". |
| A session's ended card | neutral | How it ended (`SessionOutcome`), the agent's last lines when it failed, one B primary: Review Changes… (changes) or Restart Session (failed); Take Back / Show Output plain. The dead terminal is never shown first. The header's Review Changes… is plain `.bordered` and only appears while the output is shown. Restart / Take Back are off while one runs. One wording per state everywhere (`AgentSessionRow.stateText`: the list, the header, the job row and detail): *Couldn't start* / 启动失败 in both the card title and the row. The review sheet's Merge / Commit and Merge is the B primary on ⌘↩ (no bare Return); Discard's confirmation defaults to Cancel. |
| Progress bars | I (light) / M (dark) | flat: too thin for the gradient |
| Kind icons | kind tokens | |
| Severity | — | a neutral chip with priority bars (one, two or three of three filled, in ink; High's in `kind.issue`). Never `attn`: amber means "needs you" only, so a Medium chip can't read as a second To verify |
| An item waiting to be verified (the detail) | neutral card + `attn` disc | `WorkPanel` (review page): a `panel-2` card with a hairline, the 16 pt to-verify disc leading, one semibold sentence ("Codex says it's fixed"; "The agent …" when the doc doesn't name it), one secondary line (when · commit · PR · Open Session), the agent's note; Mark as Done is the view's one **B** primary (D), Send Back… plain (opens a note field in place: "What's still wrong?", ⌘↩ sends, the note is kept on the work record), ⋯ holds Review Changes… (a session) and Won't Do. A "won't fix" claim swaps them (Won't Do primary, Mark as Done in ⋯). No status rings inside buttons; the state pill keeps the only amber wash. History with one entry is not shown; where it came from is one mute footer line. The picture sits on the page with its time in a capsule on it and its file actions on hover |
| Terminal | — | the ANSI palette is a terminal theme; selection = system accent |

### 3.4 Settings and onboarding

| Element | Brand | Detail |
|---|---|---|
| Settings window | — | One resizable window (860 × 620, at least 760 × 520): a full-height source-list sidebar under the window's buttons (the search field, then the panes in three small groups: General, Dictation, Speech, Shortcuts · Projects, Agents · Privacy, Storage; in dark mode a neutral `#262626` ground under it, so the material never carries the wallpaper's blue beside the neutral page) and a page. The pane's name is the window's title, in the unified toolbar (System Settings). **The page is inset grouped cards (v0.9, what ships)** on `controlBackgroundColor`: a section is a 13 pt semibold secondary heading outside (an accessory — a column's names, a section's total, one small button — over its right end, never making the line taller), its rows in one rounded box (r 10, ink @ 3.5 %, a 0.5 pt ink @ 7 % edge), 1 px `separatorColor` hairlines *between* rows inset 12 pt — none under the heading —, and a 12 pt secondary footnote outside under the box (never inside it; links in it in brand ink). **One grid for every pane** (`SettingsMetrics`, checked by the layout lint's `settingsgrid`): the box edges at the page column (28 pt gutters, at most 680 pt wide); every text — row titles, headings, lead lines, footnotes, the About line — at the box's 12 pt inset; a row with a leading glyph puts it in one 18 pt slot and its text 10 pt after (inset + 28), and only lists of things have one (Speech's jobs, Storage's files, the agents, the projects, a notice's disc): settings rows don't, and one box never mixes the two; every trailing control, value, size and keycap ends at the box's inset on the right; the page's first thing — a lead line, a notice, a heading or a box — starts 26 pt under the toolbar on every page, clear of its fade. A page may open with one 12 pt secondary lead line (what the page does, a fact about this Mac), with one small action at its right end (Agents' Check Again). A row is its title (13 pt) and one-line description (12 pt, secondary; the copy is cut to fit one line at the window's default width) on the left, **one control** on the right: a switch, or a pop-up at the one control width (`ChoicePopup`, 180 pt, flush right: every pop-up of every pane shares one left and one right edge; rare settings as check items after its choices), or a keycap recorder. A longer explanation is the title's tooltip; a small ⓘ (secondary) after the title only on a row with no description line. Rare actions sit in the row's ⋯ (`RowMenu`, shown on hover, its slot kept at rest; the same items in the context menu) or a split button's menu; a destructive one is never a button at rest. A fix the user must make is one small plain button before the row's control (Sign In…, Install…) or a brand-ink text link to where it is made (Download in Speech…). A state that concerns a whole page (a permission missing, the key not heard, another copy of Blurt holding the keys) is one `SettingsNotice` above the first section — the 16 pt status disc in the icon slot, what and why, one plain button — never a line per row. **Advanced is one pattern**: a disclosure heading ("› Advanced") whose box shows only while open, at the page's foot (Dictation, Speech). A group can be unboxed (General's closing About line: the version and quiet secondary text buttons). The one gradient primary of a page (Speech's recommended Download) is a step deeper in dark mode (under 14 % black), and a sheet's or dialog's filled default uses the light accent `#0B735E` in both appearances, so white titles stay ≥ 4.5 : 1. Under the toolbar the page's ground fades out over 10 pt, so scrolled rows slip under it rather than being cut. (`SettingsKit`: `SettingsPage`, `SettingsLead`, `SettingsGroup`, `SettingRow`, `ChoicePopup`, `RowMenu`, `SettingsNotice`, `SettingsGrid`.) |
| Settings sidebar selection | T | the main window's `BrandRowView` (rounded tint, text `ink`; neutral 6 % when the window isn't key); while searching, panes show their match count (plain digits) and panes without matches are dimmed |
| Settings: the row a search or a link lands on | T | a brief rounded tint behind the row, fading out over 0.7 s (none with Reduce Motion: it appears and goes) |
| Settings search results | T (chosen) | On the panes' own grid and components: the query is the window's title (“short”); the lead line says the count ("16 results") with ↑↓ / ↩ as keycaps on its right; one section per pane in the sidebar's counts — the pane's heading (its symbol, name, the count at the right) over one rounded box of one-line rows, best group first. A row is its title with the matched words in semibold (never brand), when the title doesn't hold them why it matched in 12 pt secondary — a sentence of its description or a keyword, **always in the UI's language** (a row found through its other-language name shows its own description, never English inside Chinese), whole from its start and cut at the row's end only, parentheses dropped — and on the right one thing: a shortcut's keys as keycaps, or the section it is in (no captions between rows). A pane found by its name leads with "Open Shortcuts settings", then its first 5 rows and "Show 9 more" (brand ink, its chevron at the trailing edge). Actions (Restore defaults) are found by their own words only, in brand ink. One row is ever tinted (full width inside its box; neutral 6 % when the window isn't key): the pointer moving onto a row makes it the keyboard's choice. No hits: the same frame, "No results", a hint, common searches and Clear Search. The bottom edge fades over 18 pt |
| Settings: Agents drag to reorder | I | a 2 pt `brand.ink` line where the dragged agent will land; the handle shows in the page margin on hover only |
| Settings → Agents | — (one T + I chip) | The lead ("Blurt uses the first agent that works, from the top.") with Check Again at its right end. One compact row per installed agent: its status mark in the icon slot (the ok check only for an agent known to run — signed in; attn = needs you; a hollow ring = off, not installed, or set up with no way to check its sign-in), its name, one neutral state line (colour is the mark's alone), a switch; the one fix it needs is a small plain button before the switch (Sign In…, Install…); ⋯ on hover (Details…, Test, Connect Skill and MCP…, Move Up / Down, Check Again). "In use" is the only chip. Agents that aren't installed are one folded line at the list's foot. Organizing is **one shared section** for every agent — model ("CLI's model" / "Cheapest model") and effort for recordings and for snaps and voice notes in two columns of the page's pop-up width, their names on the heading's line; an agent set differently keeps its own (named in the footnote) and is changed in its Details sheet, built from the same parts (heading, column names, box, footnote outside), whose pop-ups say an inherited value one way: "Default (Haiku)"; its header has the version, whether it works in sessions, and the status with Sign In… beside it. Sessions: "Keep sessions running" is a switch (on and fixed while tmux is there, its line says why). "Ask your agent" is the page's closing footnote with Examples… |
| Settings → Storage | — (greys) | The lead says the total ("Blurt uses 3.9 GB", size semibold, tabular) with the free space at its right ("436 GB available", no hundredths); each section's heading carries its own total over its rows' size column (no bar to decode). Rows of one anatomy: glyph in the icon slot, name, one plain line (never a path: that is the tooltip; a model says the jobs it does in Speech's words, "Used for live captions and voice notes"), the size flush with the trailing edge, "0 KB" for nothing. Actions (Show in Finder, Move to Trash, with Undo) sit in a ⋯ menu shown on hover or focus just before the size (its slot kept at rest) and in the right-click menu. The search index and the build files are one "Caches" row. Only the exception is labelled ("Not used"), never "In use" on every row |
| Settings: Agents Connect sheet (`InstallSheet`) | I on the add glyph · `brand.accent` default | 480 pt, 20 pt insets. Blurt's icon with the agent's app icon as a badge, "Connect Blurt to Claude Code" (15 semibold) and one 12 pt line on what the user gets. Rows in the system font, an 18 pt icon column: what Connect adds first (`plus.circle.fill` in brand ink, a caption with what it does and "in every project"), then what needs the user (`attn` only there, and the row says what to do), then "Already set up" (secondary `checkmark.circle`; another copy of Blurt in the skill folder is in place, not a warning). Commands and paths only under Details (collapsed): mono, selectable, one line each, scrolling sideways with a fade, ~ for home, a 5 % well with no stroke, a Copy button. Footer: "Nothing changes until you click Connect." on the left, Cancel and Connect (`.borderedProminent`, ↩); Done alone when nothing is left to do or after Connect |
| Text buttons in Settings ("Change in Dictation…") | I | plain text button in `brand.ink`, not the system link blue |
| Switches, checkboxes, radios, sliders, focus | `brand.accent` (native) | the `AccentColor` asset; no custom drawing |
| Mic test meter | **G** vertical (dark) / I (light) | idle bars neutral |
| "Recommended", "In use" badges | T + I | Settings → Agents: "In use" on the one agent that runs, only once its sign-in check is in |
| Selected choice card (dictation style, model) | I border + T ring | not a filled card |
| Hotkey recorder while listening for keys | I | One fixed-width well (140 pt) in every state, so a row never changes width. At rest a shortcut is small keycaps (one 20 pt chip per key, `ink-2` text — never under `mute`) flush with the trailing edge; unset is the quiet well itself (ink @ 5 %) with "Record Shortcut"; the dictation key (set in Dictation) is the same keycaps in the same well. Hover or focus: the well's faint ground and the × before the keycaps. Listening: an `ink` ring on `tint` across the well, "Type shortcut…" and an esc keycap, centred. **A key that doesn't work here is marked, never faded**: a 12 pt `attn` "!" disc before its full-ink keycaps, whatever the reason — its own conflict (with why under the action's name in `attnInk`) or another running Blurt holding it (one `SettingsNotice` above the first section names the cause once, with Quit Other Copy / Copies matching its count; the rows have no line of their own). Keys another action has: **asked in the row, no sheet** — the new keys stay in the well (`ink` on `tint`), the second line asks with the outcome in secondary ink ("Swap with Voice note? It gets ⌥⇧A.") with Swap (brand ink) and Cancel; the other action's keycaps get the "!" meanwhile; Return / Esc in the recorder do the same, ⌘Z undoes it |
| Onboarding hero panel | **field** + grain (light), **deep** + grain (dark), **S** glow | A 200 pt side panel (the window grows to 840 pt; the content column keeps 640): the mascot on a still, blurred spectrum glow — **the one place the spectrum appears**. Flat field without grain or glow under Reduce Transparency. |
| Onboarding title | gradient text | 24 pt bold, `gradient.text` |
| Onboarding Next / Done, or the step's own action | **B** | One per step: Set Up Permissions… / Download Recommended Models / Install uv while that is still to do (the footer then says Skip for Now, plain), else Next / Done. Done closes (the chick is already happy on the last step; v2.1: no bloom) |
| Onboarding step bars | I | |
| Permission rows | `ok` + ✓ granted · `attn` dot missing | |

### 3.5 Empty states

These cover the empty inbox, inbox zero, All Items / a project with nothing yet, no results, the Dictation page, the
sessions window, the Tauri inbox and sessions. **One component everywhere (v2.1)**: AppKit `EmptyStateView`, SwiftUI
`EmptyStateContent`, Tauri `EmptyState.tsx`, all on the `EmptyState` metrics (`Icons/BrandViews.swift`):

- **The brand mark**: the app icon itself — the 4A chick on its gradient tile, as in the Dock and the logo
  (`BrandMark`: Blurt.app's `AppIcon.icns`; the web UIs use `web/packages/ui/src/assets/app-icon.png`, 160 px, written
  by `assets/brand/build.py`). An **80 pt canvas**, so the tile is 64 pt, centred. The same mark for every friendly
  state: no per-page glyph tiles, no hop.
- 10 pt to a **neutral title** (15 pt semibold), 4 pt to a **neutral hint** (12 pt, secondary, ≤ 320 pt wide), 16 pt
  to at most **one primary** when it moves you on (Open Folder, Turn On Dictation…).
- Trouble states (scan failed, missing folder) and detail-pane placeholders keep a quiet SF symbol: warnings are never
  brand. So does **Settings search with no match**: a miss is a result, not a welcome. The page keeps its frame (the
  22 pt Search results title where the hits start) and, where the first group would be, shows `magnifyingglass` in
  tertiary, “No settings match “…”” (14 pt semibold, one line, the query cut in the middle past 24 characters), the
  hint, a few common searches in `brand.ink` that always find something (`SettingsCatalog.suggestions`), and a plain
  Clear Search (Esc in the field does the same). The sidebar's panes stay at rest: dimming means "no hits here" only
  when some pane has hits. A path in one is one line, cut in the middle; a missing project folder offers **Locate…**.
- One rule for the buttons: the first button is the brand primary (with ↩) only when it moves you on; a button that
  only undoes a filter (Clear Filters) is a plain native button and never takes ↩ (so it never draws as the system
  default). Sheets and dialogs (Project Settings, Rename, Hand Off) keep the native default button.
- **Three looks, one layout (v0.9, main window)**: *friendly* (the brand mark; its first button the brand primary when
  it moves you on), *miss* (a search or a filter that matched nothing: a quiet 34 pt symbol — magnifier, filter — and
  only plain buttons that undo it: Clear Search, Clear Filters, Search All Items), *trouble* (a scan that failed, a
  folder that's gone: a quiet symbol, the native default button, a path line, a quiet text link such as Remove from
  Blurt). Everything on one centre line, the group's middle at about 40 % of the pane (the space above two thirds of
  the space below); a hint that wraps is balanced. A first read of your items and the update after a new version show
  the mark with the brand spinner on its faint track where the button would be, and no button.
- **An empty place owns the window**: no rows and no search or filter emptied it (inbox zero, nothing in progress, a
  new project, a first run, nothing listed yet) — the detail column steps aside (back at its width with the first row
  or a job shown; ⌥⌘I is the user's), the heading has no counts, search is off until items are listed. A search or a
  filter that matches nothing keeps the columns, with a blank detail.

### 3.5a Dictation page and Lab

- **One header band (v0.9 redesign)** at the top of the list column, nothing else above the list: History | Words |
  Lab as a native segmented control with a **neutral** selected segment (a view is where you are, never a brand fill;
  every segment one width, so the control keeps its shape in both languages), on the rows' leading edge (16 pt), and
  on the right only the view's own commands (the Lab's New Take, Read a Script, Run All Cases, ⋯). The detail column's first
  row is a band of the same height (the app and when; the word; New Take), so the two columns read as one header.
  The toolbar's search field is History's: on Words (whose one field finds and adds) and the Lab it leaves the toolbar.
- **One count (round 2)**: the window subtitle is the page's only count and follows the tab and the search — "9
  dictations", "3 of 9 dictations", "26 words", "1 case". Headings never carry counts; today's numbers are the Today
  heading's tooltip.
- What stops dictation (no speech model, the key not heard, off, the model downloading) is one card above the list:
  its `StatusDot` (or the spinner), plain words, and — when it is the next step — the view's one **B** primary
  (Download Model; Choose Model… plain when nothing can be fetched); the detail's Turn into Item is plain meanwhile.
  Never amber link text.
- Rows: the app's icon (a neutral initial tile for an app not on this Mac, never the blank document), app name and time
  in secondary — the time always there — and the text as typed, one paragraph clamped to two lines. One neutral chip
  for how it went in when that wasn't simply polished at the cursor, in the same words as the detail's line ("As
  spoken", "Copied", "Copied · as spoken" / 原话, 仅复制, 仅复制 · 原话); the item it became is a link on the trailing
  side (its key, monospaced, ↗), never a chip. No per-row glyphs, no separators, day headings without a rule. While
  searching, the matched words are semibold (never brand). A row the AI writes an item from: the `brand.working`
  hairline only — the spinner is the detail button's (one spinner per job).
- Detail: the app as an 18 pt label beside its name and time; the text at 17 pt (a step over the 13 pt rows) straight
  on the pane, Copy and Correct on hover; Polished | As Spoken | Changes is the detail's own (the list always reads as
  typed), a small neutral segmented control. Changes: words polish left out struck through in `err`, words it added or
  respelled underlined in `attn` — a line, not a fill — in one text, punctuation-only changes unmarked, with a
  plain-words key. One line under the text says how it went in, with the reason ("Typed as spoken: polish took too
  long."). Turn into Item as the primary ("Writing Item…" with the spinner inside the same button at the same width);
  "⋯" for the rest (Delete last, red); then the facts as quiet rows under a hairline, always shown, labels in one
  fixed leading column. Correcting happens in place in a field a step off the pane (never a dark well), with the
  system focus ring; what saving teaches on its own line; Save (⌘↩ in the hint line and the tooltip, never a keycap
  inside the button) is the moment's **B**, Cancel plain.
- A search with no results: the shared empty state (the app's mark), the query said back, one hint, a plain Clear
  Search; the detail column folds away until something matches.
- Words: one field that finds as you type and adds on Return (the line under it says which); the words to review as
  plain rows chosen first (the list's tint only), whose Add (`brand.ink`, ⌘↩) and × show on the chosen row and on
  hover — the one place that decision is made; the detail only tells (why it was suggested, when it was found).
  Names: 词库 / Words everywhere (加入词库 / Add to Words). The projects' words one chip per project: its name, and its
  key set as the sidebar sets it. One heading form for every group (name, count in secondary), Built-in folded.
- The Lab: a case opens on its result (the scores on one row of neutral numbers, the done check only for an exact
  take, then the diff), each stage on its own full-width line with its name never cut (stages that wrote the same text
  merged), the facts in plain words (Speech, Safety check, At the cursor), then the recorder: a neutral disc at rest,
  red with a stop square only while it records. Move to Trash in the case's ⋯. The content fades out over 18 pt above
  the pinned Save bar. The command bar labels every button (New Take, Read a Script, Run All Cases) or none.
- The Lab score: 30 pt semibold, neutral (v2.1: no gradient, no bloom).
- The Lab's Run / Save / Next: **B**. While a take is processed the recorder card carries the `brand.working` hairline;
  Compare and Run All show their spinner (no rim).
- Diff: deletions `err` struck through, additions `attn` underlined; stars `attn`; chosen check and level bars
  `brand.ink`.

### 3.6 Menu-bar icon

No colour. `glyph.svg` is a template image: since v0.9 the chick as a bold filled silhouette (face knocked out),
the logo's chick scaled uniformly (17.2 × 16.2 pt in its 18 pt box: the logo's body and wings, a bolder tuft), with no arcs at rest; while voice input listens two sound arcs appear to its right and pulse (still under
Reduce Motion). The recording status item shows a `rec` dot and the time, or `attn` while paused.

### 3.7 Review page and overlays (web)

- **Review page** (`web/packages/review`): primary **B**; the "organising" pill carries `.ai-working` (its hatching egg
  is the motion); the Done screen's headline and logo are plain (v2.1); selected card 2 pt I ring; active tab 2 pt I
  underline (it marks the tab, not decoration);
  current transcript line and "now playing" mark I; drop zone T + I; links per §3.3; kind chips; triage's Keep ✓ `ok` (review mode only; never a button fill in the detail).
- **Overlays** (`web/apps/overlays`, Windows / Linux island and picker): exactly §3.1–3.2, island values; the voice
  card face is light, so its mark uses `--brand-ink-light`.
- **Tauri app** (`web/apps/desktop`): primary **B**; selection, badges, chips **T** + **I**; the sidebar's jobs box
  carries `.ai-working` while a process job runs; the empty inbox and sessions use `EmptyState.tsx` (the app-icon mark,
  §3.5).

### 3.8 Web and the site (later)

The site will be redone at the end of this revision on this system. **No site changes are planned now.** For the
redo:

- Neutrals: the light / dark neutrals above; one display face and one text face (the current site fonts are up for
  review then).
- Brand: the hero may use one **field** panel (with grain) as its art. One **B** primary per screen (the download), white text.
  Links I; focus I.
- Product mock-ups on the site follow the product rules exactly: a recording frame is `rec`, annotations are
  `markup`, the capture selection is the **G** stroke.
- The app icon (§6) replaces the yellow tile everywhere (favicon, og image, README logo tile).
- Yellow is no longer a brand colour. It remains only as `kind.idea` and in the mascot (the chick's body, §6.1).
- CSS: the variables and recipes in §5.2 (`--brand-gradient`, `--brand-field`, `--grain`), from the same
  `tokens.json`.

### 3.9 Never brand (flat or gradient)

- body text, titles, labels, placeholders;
- window, sidebar, panel, card-face and island backgrounds;
- warnings, errors, destructive actions;
- recording (red) and paused (amber);
- native controls;
- the menu-bar glyph;
- the pen and anything burned into a screenshot;
- data series in charts;
- gradient text below 20 pt (14 pt bold), or on body / labels; gradient icons (except the app icon tile), gradient
  rings or progress bars;
- the spectrum anywhere but the onboarding hero art;
- rims, glows or halos round rows, banners, pills or buttons; rotating or animated colour; completion blooms;
- decorative lines: rules or underlines under text that only decorate (links and the active tab keep theirs: they
  mean something).

## 4. Motion with colour

Existing motion vocabulary in the app: a spring with response 0.42 s and damping 0.82 (`Capture/Island/Motion.swift`,
used by the island and the hanging cards); short state fades of 0.14–0.2 s; flashes of 0.32–0.45 s; the spinner turns
every 1.1 s. On web the easing is `cubic-bezier(0.16, 1, 0.3, 1)` and hovers last 120 ms. Every motion respects
Reduce Motion: the still frame must still say the state.

| Moment | Colour | Motion (Reduce Motion → still frame) |
|---|---|---|
| Listening (dictation, voice note, mic test) | G bars + glow | Bars follow the level and settle to 2.5 pt dots in silence. The glow fades in over 200 ms and breathes ±10 % opacity with the level, never faster than 0.6 s. |
| Choosing an area | G dashed stroke, M handles / label | Dashes march while dragging. |
| Choosing a window | M line + 22 % wash | 120 ms cross-fade between windows |
| Countdown | `rec` ring | The ring drains each second (linear; the only thing that moves — the chick's listening loop aside); the number swaps with a 0.14 s fade; at 0 the selection stroke cross-fades G → `rec` in 200 ms. Reduce Motion: the ring full and still. |
| Recording | `rec` frame and dot | The island dot breathes (1.6 s, 80–100 %); the frame is still. At Finish the dot and time become ✓ and the length for 1.6 s, in place. |
| Paused | `attn` dashed | No motion: stillness is the signal. |
| Snap | white shutter / M ring | 320 / 450 ms, once |
| Card hung | M clasp | The card swings in on the spring; the clasp does not animate. |
| Cards come down | — | Only after the pointer rests 180 ms on the island (a brush past the notch drops nothing); up again 0.25 s after it leaves the cards and their threads. Reduce Motion: 0.2 s fades. |
| blurt working | I spinner arc, M dot | Quarter arc, 1.1 s per turn |
| Done | `ok` + ✓ | The check draws once (200 ms); the chick hops. The colour never pulses. |
| Needs you | `attn` | One pulse when it appears, then still. |
| Primary button | B | Brightness 1.04 on hover (120 ms). The gradient never animates or shifts. |
| AI working | spinner + `brand.working` hairline | The spinner (or the review page's hatching egg) is the only motion; the 1 pt hairline is static and fades in / out over 0.2 s (instantly with Reduce Motion). |
| Something big finished | `ok` + ✓ / the chick | No bloom (v2.1): the done check, the chick hatching or hopping, says it. |

Rules: at most one brand-coloured thing moves at a time on a screen; no gradient ever moves (no animated gradient
angles, no shimmer, no rotating rims); the listening glow only while listening; nothing in brand colour blinks for an
error.

Accessibility fallbacks, everywhere: **Reduce Transparency** → flat colours: no grain, no listening glow, no hero
glow (`reduceTransparency`, `prefers-reduced-transparency`); the working hairline is flat already and stays. **Increase Contrast** → the `hc`
values (deeper ink, stronger tint) and flat ink instead of gradient text (`BrandColor.increaseContrast`,
`prefers-contrast: more`). **Reduce Motion** → no marching dashes, no glow breathing, the working hairline appears without a fade.
Test builds force them with `BLURT_REDUCE_TRANSPARENCY=1`, `BLURT_INCREASE_CONTRAST=1`, `BLURT_REDUCE_MOTION=1`.

## 4a. Interaction (the Mac way)

- **Edit in place, undo over confirm.** A snap is marked up where it was taken, not in a copy; a wrong stroke is `⌘Z`,
  a discarded snap is *Undo* for 5 s — no "Are you sure?".
- **Return / Esc / ⌘Z everywhere.** `⏎` finishes, `Esc` steps back (typed text first, then the capture), `⌘Z` takes
  back the last stroke; a click outside the frozen picture is "done" too. Every pointer path has a keyboard path
  (Tab reaches the bubble's *Goes to* chip; ↑ ↓ ↩ in its list).
- **Same modifiers for snap and recording.** The pen draws the same strokes in both: a plain drag is freehand, ⇧ a
  box, ⌥ an ellipse, resting ~0.5 s at the end of a rough stroke snaps it to a clean line, box or ellipse. While
  recording the pen key is held as well (⌃-drag, ⌃⇧, ⌃⌥; with ⌥ as the pen key the ellipse is ⌃⌥), and it goes down
  first: ⌃ held alone a moment, then ⇧ or ⌥ joins. A chord pressed together (⌃⌥-drag moves windows in some window
  managers) stays the window manager's and never draws. One colour (`markup`), one width rule, one hint wording. The
  recording's hint is the open island's key line ("Hold ⌃ to draw · ⇧ box · ⌥ ellipse"), not a pill over the
  recorded area: nothing but the ink itself may land in the video, and the island is never captured.
- **Never cover what the user is pointing at.** The note bubble docks beside the frozen selection (right, left, below,
  above, on the selection's display), with its caret toward it.

## 5. Gradient recipes

### 5.1 AppKit / Core Animation (shipped)

| Surface | How | Where |
|---|---|---|
| Primary buttons | `BrandButton` (AppKit, layer-backed, `gradient.button` + white title) / `.buttonStyle(.brand)` (SwiftUI) | `Icons/BrandViews.swift` |
| Picker Snap / Record, island buttons | `PillButton(gradient:fg:dot:)`, `IslandButton(gradient:fg:)`: the gradient drawn clipped to the pill | `Capture/Picker.swift`, `Capture/Island/IslandContent.swift` |
| Capture stroke, level bars | `BrandGradient.layer(linearStops, .diagonal / .vertical)` **masked** by a `CAShapeLayer` (the dashed rect / the bars path) | `SelectionOutline` (Picker), `Ears`, `Bars` |
| Gradient text | `GradientLabel` (AppKit: glyphs as a mask) / `.brandGradientText()` (SwiftUI `foregroundStyle`) | `BrandViews.swift` |
| Onboarding hero | `FieldView` / `BrandField`: `BrandGradient.drawField` (`CGContext.drawRadialGradient` per layer) + `drawGrain` (a generated 256 px value-noise tile, overlay, one noise pixel per device pixel) | `BrandViews.swift`, `BrandColor.swift` |
| Empty states | `EmptyStateView` (AppKit) / `EmptyStateContent` (SwiftUI) on the `EmptyState` metrics; `BrandMarkView` / `BrandMark.image` (the app icon) | `BrandViews.swift`, `ItemListController.swift` |
| Listening glow | `GlowLayer.make`: the base gradient, blurred once with Core Image, cached as a layer image; `GlowLayer.fade` | `Island.swift` |
| AI working | `WorkingOutline` (a 1 pt `BrandColor.working` stroke, `island` for the island value) / `.aiWorking(active)` | `BrandViews.swift` |
| Spectrum (onboarding only) | `SpectrumGlow` | `App/BrandMoments.swift` |

`BrandColor.swift` is generated: `BrandColor.*` (dynamic light / dark / Increase Contrast `NSColor`s, all sRGB),
`BrandColor.Island.*`, `BrandColor.working` / `workingWidth`, `BrandColor.Kind.palette`, and `BrandGradient` (stops,
`layer(_:_:flipped:into:)`, `linear()`, `button()`, `draw(...)`, `drawField`, `grainTile`, `drawGrain`, listening-glow and
grain constants). Edit
`assets/color/tokens.json`, never this file.

### 5.2 CSS (shipped)

The generated block in `web/packages/ui/src/tokens.css` (between the `@generated colour` markers) defines, per theme:
`--brand`, `--brand-ink`, `--brand-tint`, `--brand-working`, `--on-brand`, `--on-brand-ink`, `--brand-accent`, `--rec`,
`--attn`, `--attn-ink`, `--on-attn`, `--ok`, `--on-ok`, `--err`, `--info`, `--markup`, `--kind-*`, `--g-green / -mint /
-blue`, `--brand-gradient` (diagonal), `--brand-gradient-v`, `--brand-gradient-h`, `--brand-button`,
`--on-brand-button`, `--brand-text`, `--brand-field` (deep in dark), `--grain`, `--grain-opacity`, `--glow-opacity`,
and `accent-color: var(--brand-accent)` (v2.1 removed `--brand-glow`, `--brand-spectrum*`, `--brand-wash`,
`--ai-glow-opacity`). `prefers-contrast: more` swaps in the `hc` ink / tint and sets
`--brand-text: none` (and the `hc` working line); `prefers-reduced-transparency: reduce` sets `--grain: none` and
`--glow-opacity: 0`. The
overlays' `theme.css` gets the island values (+ `--brand-ink-light` for the light voice-card face).

Utilities in `web/packages/ui/src/base.css`: `.btn.primary` (button gradient, white 600 text, highlight, shadow, hover
1.04, active 0.92, neutral disabled), `.ai-working` (`box-shadow: inset 0 0 0 1px var(--brand-working)`), and,
unused in the app UIs and kept for the site redo, `.g-text` (gradient text, flat `--ink` under `prefers-contrast` /
forced colours) and `.g-field` (field + grain `::after`). The old `--accent*`, `--keep*`, `--amber*`, `--warn`, `--sev-*` remain as unused aliases for one release.

The dashed gradient stroke has no pure-CSS form (`border-image` drops dashes): the overlays' picker uses an inline SVG
rect with a `<linearGradient gradientUnits="userSpaceOnUse">`, a 2 px `--on-brand` 60 % under-stroke, then
`stroke-dasharray="6 4"`.

Never: `background-clip: text` on body text; gradients on `border` of thin things; animated `background-position` of
brand gradients.

## 6. The app icon (shipped)

**Variant A**: the shipped chick unchanged (white body, `#17140F` line, white glints) on the gradient field.

- **Canvas**: 1024 × 1024, macOS 26 grid: the 824 px superellipse at (100, 100), the soft shadow, a 3 px white 22 %
  rim (`assets/brand/app-icon.svg`, group `#tile`).
- **Tile fill**: `gradient.field` mapped to the 824 box (azure corners from the bottom-left and bottom-right, the mint
  seam glow, the airy green top), then grain at **7 %** (overlay; `feTurbulence` base frequency 0.6 on the 1024
  canvas, 2 octaves, ×3 contrast).
- **Small sizes**: 32 px (`app-icon-small.svg`) and 16 px (`app-icon-16.svg`) use the plain vertical
  `gradient.linear`, no radial layers, no grain.
- **Build**: `chick.swift` reads `gradient.field / deep / linear / grain` from `assets/color/tokens.json` and writes the
  tile; `build.py` renders every size (masters between 33 and 1023 px are rendered at 1024 and scaled down, so the
  grain averages out as in WebKit). rsvg-convert and a WebKit render agree to about one level at 1024.
- **Outputs**: `skills/blurt/assets/icon.png` / `-16` / `-32` (→ `record.py make_icns` → Blurt.app `AppIcon.icns`;
  the review page's logo and favicon), the Tauri icons (PNGs, `.icns`, `.ico`), the capture demo icons. The README
  logo stays the bare chick on its sticker edge (unchanged). The site's favicon / apple-touch / og are written only with
  `build.py --site`, for the site redo.
- **Dark appearance**: not shipped. `app-icon-dark.svg` (the deep field) is rendered for preview. macOS shows a dark
  icon only from an Icon Composer `.icon` compiled by actool into `Assets.car` (`CFBundleIconName`); an
  `.appiconset` with dark entries is ignored for the mac idiom. It would fit the actool run `assets/color/build.py`
  already does, at the cost of a 2–6 MB `Assets.car` (`assets/brand/README.md`).
- **Menu bar**: unchanged (template glyph).

### 6.1 The mascot (shipped, v0.9)

**One chick.** The mascot for moments (the onboarding hero, the island's ears and quiet lines, the voice note,
notification pictures) is the mark itself — the 4A line chick of the icon, logo and menu bar — in colour. It replaces
the 1A round raster chick (frames from an image model), which did not look like the logo; the user kept its warm
yellow and its bounce.

- **Drawing**: the mark's own geometry (`assets/brand/chick.swift` writes `Icons/MascotGeometry.swift`: the outline,
  wings, eyes, beak, arcs), so it is the logo's chick by construction. 32 pt and below use the 32 px icon's drawing
  (heavier line, one arc, filled beak). The line is the icon's (`#17140F`, as thick relative to the art as on the
  1024 icon).
- **Colour**: a warm butter-yellow body (`#FFC83D`, the 1A yellow) under the line, wings a shade deeper, a coral beak,
  faint cheeks, a soft shade low on the body. The art's colours live in `chick.swift` with the art, like the icon's
  line and white body; the UI's colours stay in `tokens.json`. On a dark backdrop (the island, dark mode) the free
  marks (sound arcs, thought dots) turn light (`#F4F1EA`), the ground shadow goes, and the chick and the egg get a
  thin white rim (the logo's sticker edge, thinner) so their black line — the tuft, the wing nubs, the shell — still
  reads on the island's black; the arcs and sparkles get none. On the onboarding field it reads as on a light
  backdrop, like the icon on its tile. Notification pictures carry the logo's full white sticker edge.
- **Motion** (`Icons/MascotArt.swift`, vector, drawn for each moment at 60 fps while it plays): posed part by part
  about the foot — hops with squash and stretch, tilt, wings that flap (drawn whole behind the body, so at rest only
  the nub shows, as on the icon), blinks, glances, ^ ^ eyes, an open beak, sound arcs that pulse. Clips: `idle`
  (breathes, blinks, glances), `listening` (head tilted, the arcs pulse outward, inner then outer — like the menu-bar
  glyph), `thinking` (eyes up, thought dots where the arcs were), `wobble` (the egg rocking: organizing), `hatching`
  (the egg cracks, the cap flies off and shrinks away, the chick pops up and hops out, the cup sinks; shell pieces
  stay solid, never half-transparent; ending where `idle` begins), `happy` (two hops,
  wings up, sparkles), `peck` (spots a bug, pounces on it, the bug goes in a sparkle, a hop back). Sparkles are warm
  yellow and coral, without a line. The layer draws 4 % past its square (`MascotArt.bleed`), so a landing squash or
  the flying cap is never cut off; the `mascotcheck` self-test holds every clip inside that, keeps shell pieces
  solid, and checks the rim on black.
- **Reduce Motion**: each clip's still moment, which says the same thing (the happy face, the listening tilt with
  both arcs, the chick out of its egg).
- **Restraint**: the mascot is illustration, not UI: it never carries brand mint or the gradient, and only one
  mascot moves at a time on a screen. Empty states keep the app icon (§3.5).
- **Web** (Windows / Linux overlays, Tauri) still plays the 1A strips from `assets/mascot/`; porting is in TODO.md.
- Comparison sheet (untracked): `promo/cases/v0.9-polish/mascot/compare.png`, every clip before / after, light and
  dark, next to the app icon.

## 7. Typography (as used today)

| Role | macOS (SF Pro, system) | Web (`tokens.css`) |
|---|---|---|
| Body / list title | 13 pt regular; unread 13 medium | `--fs` 13 px (mac) / 14 (win) / 14.5 (GNOME) |
| Secondary line, captions | 11 pt regular; small labels 11 medium | 11–12 px |
| Island rows | title 13 medium, secondary 11.5 | — |
| HUD / pills / hints | 11.5–13 semibold or medium | — |
| Section headings | 13.5–15 semibold | — |
| Window / page titles | 17–20 semibold | `--fs-title` 20 px (21 GNOME) |
| Numbers (times, sizes, counts) | `monospacedDigitSystemFont`, 11–12 medium / semibold | `font-variant-numeric: tabular-nums`, `--mono` |
| Countdown | 44 semibold, monospaced digits | — |
| Chinese | system fallback PingFang SC | `--font` lists PingFang SC / YaHei / Noto CJK |

Rules: one family (the system face) in the app; weight, not colour, makes the hierarchy; brand colour never sets
the style of body text. Display faces are a site decision for the redo (§3.8).

## 8. Spacing, radius, elevation (as used today)

- **Spacing**: a 2 / 4 pt grid. Stack spacings are mostly 2, 4, 6, 8, 10 and 12. Hanging cards: 12 pt gap, 12 pt from
  screen edges, 18 pt below the island. Island rows: 18 pt side inset, selection inset 6 × 1. Controls 28 px high on
  mac web (`--ctl-h`), 32 win, 34 GNOME.
- **Radius**: 6 (rows, palette selection, small controls; web `--r-sm`), 7–9 (image cards, island row wash, buttons,
  note pill), 10 (panels, tips; web `--r` 10 mac / 8 win / 12 GNOME), 12 (voice cards, large cards), 14 (note bubble,
  island bottom corners). Pills and dots are height / 2. Handles 2.5. Gradient art tiles are ≈ 30 % of the side. The
  app icon is the macOS superellipse.
- **Elevation**: dark mode shows hierarchy with lighter surfaces, not shadows (`#1E1E1E → #2A2A2A → #323232`). Light
  mode has two shadows: `--shadow` (1 px + 10/28 soft) and `--shadow-pop` (0.5 px ring + 16/44). Hanging cards use a
  10–12 pt shadow radius; clasps 1.5. Capture chrome is glass (white 0.05–0.08 @ 72–82 %), not shadow. Screenshots get
  a 1 px inner stroke. The gradient adds no new elevation: a gradient button has the same 1 px shadow as any button.

## 9. Do's and don'ts

| Do | Don't |
|---|---|
| One button-gradient primary per view, white title; secondary actions native | Several gradient buttons side by side |
| White text only on `gradient.button` (≥ 4.5 : 1) | White text on mint or the base gradient (1.70–2.56 : 1) |
| `brand.on` dark text on flat mint chips, labels, badges | Gradient fills on small chips and badges |
| Gradient text for the onboarding title only, the deeper variant on light | Gradient text for body, labels, numbers or empty-state titles; gradient text under Increase Contrast |
| Native switches, checkboxes and focus in the brand accent (`AccentColor`) | Custom-drawn gradient switches; `controlAccentColor` where you mean "brand" |
| The field for the onboarding hero and the icon, with grain | The gradient as a window, sidebar or panel background, or as empty-state art |
| Thin things flat: rings, underlines, badges, clasps, progress | Gradient rings, icons or progress bars |
| The spectrum in the onboarding hero art only | The spectrum anywhere else |
| "AI is working" = the spinner + one static 1 pt `brand.working` hairline | **No rotating or multi-colour rims on rows or banners**; no glow halos round rows, banners or buttons |
| Done = the check / the chick | Completion blooms or celebration rings |
| Text with nothing under it; links and the active tab keep their meaning-carrying underline | **No decorative underlines** (a gradient rule under live text, a line under a heading for looks) |
| Empty states: the app-icon mark, one component, the same spacing | Per-page illustration tiles, glyphs on gradient tiles |
| Red frame while recording | A mint frame while recording |
| Done = `ok` + ✓ | Done as a mint dot |
| Green top / start → azure bottom / end | Reversed gradients; yellow or violet outside the spectrum |
| Grain only on fields ≥ 64 pt; none with Reduce Transparency | Grain on buttons and badges |
| Kind colours on icons | Kind colours as row fills |
| The pen in coral | The pen in mint (vanishes on white UI) |

## 10. What changed from v1

1. **App icon**: from the yellow tile to the gradient tile, with the chick unchanged (A). Yellow leaves the brand.
2. **Gradient added**: `gradient.linear / vertical / field / deep / wash / glow` and `grain`. The flat mint is
   unchanged; it is the gradient's seam.
3. **Primary buttons, Snap, island fill buttons** move from flat mint to the gradient.
4. **The capture selection** is a gradient dashed stroke; handles and size label stay flat.
5. **Island**: level bars are gradient; a glow while listening or capturing (not while recording).
6. **New surfaces**: onboarding hero, empty-state art, live-text rule (v2.1 kept the hero, replaced the art with the
   app-icon mark and dropped the rule).
7. **Site**: no migration now; §3.8 says how the redo uses the system.
8. Everything else (semantic, kinds, neutrals, rules) is as in v1.
9. **Amendments** (before shipping): white text on a deeper `gradient.button`; gradient text for large headlines;
   native controls in `brand.accent` via `AccentColor`; the multi-hue spectrum for special moments (v2.1: the
   onboarding hero only, §14).

## 11. Single source of truth (shipped)

```
assets/color/tokens.json       the values: brand (+ accent, working), semantic, kind, neutral (reference), checks,
                               gradient (stops, linear, button, text, spectrum, field, deep, grain, glow)
assets/color/build.py          writes, and with --check verifies (stale outputs, contrast floors, kind hue gap):
  skills/blurt/recorder/macos/Sources/BlurtApp/Icons/BrandColor.swift        generated Swift API (§5.1)
  skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Assets.xcassets      AccentColor source
  skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Assets.car           compiled with actool (Xcode), committed;
                                                                              record.py copies it, Info.plist names it
  web/packages/ui/src/tokens.css       the @generated colour block (light, dark, prefers-contrast, reduced transparency)
  web/apps/overlays/src/theme.css      the island values
  --table                              prints the token table below
assets/brand/chick.swift + build.py    read gradient.field / deep / linear / grain for the icon tile
```

`--check` enforces every `min` against `checks` (and the `hc` values), `on` tokens against the token they sit on,
white on `brand.accent`, `brand.ink` on the tint, `brand.on` along `linear` and `deep`, white along `gradient.button`
(and at hover), `gradient.text` on every surface of its theme, kinds at 3 : 1 on `kindSurfaces`, and kinds ≥ 20° from
the brand hue, and the working hairline (1 pt, ≥ 2 : 1 composited on every surface of its appearance). It reads
`Assets.car` back with `assetutil` and compares the AccentColor. `tests/test_icons.py` runs it and fails on hard-coded
brand colours in the app (`calibratedRed`, `controlAccentColor`, `.accentColor`, the old `accent` / `amber` globals);
`test_brand_effects_stay_restrained` fails on a spectrum rim, bloom, hearing rule or art tile coming back, the spectrum
or the field outside the onboarding, gradient text outside its title, and `ai-glow` / conic gradients / spectrum
variables in the web sources. `web/packages/ui/src/tokens.test.ts` reads the floors from the same file.

### 11.1 The token table (as shipped; `build.py --table`)

| Token | Light | on `#FFF / #F6F6F6 / #ECECEC` | Dark | on `#1E1E1E / #2A2A2A / #323232` | Island |
|---|---|---|---|---|---|
| `brand.fill` | `#61DBBD` | 1.70 / 1.57 / 1.44 (fill only) | `#61DBBD` | 9.82 / 8.46 / 7.56 | `#61DBBD` |
| `brand.ink` | `#0B735E` | 5.79 / 5.36 / 4.90 | `#61DBBD` | 9.82 / 8.46 / 7.56 | `#61DBBD` |
| `brand.tint` | `#61DBBD` 18 % | wash; ink on it ≥ 4.5 | `#61DBBD` 16 % | wash | `#61DBBD` 20 % |
| `brand.working` | `#0B735E` 60 % | line (≥ 2.46 composited) | `#61DBBD` 50 % | line (≥ 3.07) | `#61DBBD` 50 % |
| `brand.on` | `#04261E` | 9.51 on fill | `#04261E` | 9.51 on fill | `#04261E` |
| `brand.onInk` | `#FFFFFF` | 5.79 on ink | `#04261E` | 9.51 on ink | — |
| `brand.accent` | `#0B735E` | 5.79 / 5.36 / 4.90; white on it 5.79 | `#1CA288` | 5.22 / 4.49 / 4.01; white on it 3.19 | — |
| `rec` | `#FF3B30` | 3.55 / 3.28 / 3.00 | `#FF453A` | 4.89 / 4.21 / 3.76 | `#FF453A` |
| `attn` | `#B86E00` | 3.99 / 3.69 / 3.37 | `#F5A524` | 8.17 / 7.03 / 6.28 | `#FFC23D` |
| `attnInk` | `#946008` | 5.34 / 4.94 / 4.52 | `#F5A524` | 8.17 / 7.03 / 6.28 | — |
| `onAttn` | `#FFFFFF` | 3.99 on attn | `#2A1A00` | 8.26 on attn | — |
| `ok` | `#3F7414` | 5.65 / 5.22 / 4.78 | `#8ACB4E` | 8.52 / 7.34 / 6.55 | `#8ACB4E` |
| `onOk` | `#FFFFFF` | 5.65 on ok | `#13250A` | 8.28 on ok | — |
| `err` | `#C02F35` | 5.68 / 5.25 / 4.81 | `#FF6B6B` | 6.01 / 5.17 / 4.62 | `#FF6B6B` |
| `info` | `#3A5BD9` | 5.71 / 5.28 / 4.83 | `#8DA4EF` | 6.90 / 5.94 / 5.30 | `#8DA4EF` |
| `markup` | `#FF5C3D` | content | `#FF5C3D` | content | `#FF5C3D` |
| `kind.issue` | `#BB493A` | 5.09 / 4.71 / 4.31 | `#EE8771` | 6.62 / 5.70 / 5.09 | — |
| `kind.idea` | `#A26D05` | 4.44 / 4.11 / 3.76 | `#E1AE51` | 8.24 / 7.09 / 6.33 | — |
| `kind.note` | `#4467D2` | 5.10 / 4.72 / 4.32 | `#90A7F1` | 7.13 / 6.14 / 5.48 | — |
| `kind.task` | `#7559CB` | 5.19 / 4.80 / 4.39 | `#AA98F2` | 6.73 / 5.80 / 5.18 | — |

| Gradient | Stops | Contrast |
|---|---|---|
| `linear` (base) | `#66D97A` 0 → `#61DBBD` .45 → `#4AABE2` 1 | `brand.on` ≥ 6.31 at every point |
| `button` | `#028932` 0 → `#02866F` .45 → `#087EB3` 1 | **white ≥ 4.51** at every point; ≥ 4.22 at hover ×1.04 |
| `text` light | `#14983C` 0 → `#07957C` .45 → `#248CC2` 1 | ≥ 3.17 on every light surface (large text) |
| `text` dark | the base stops | ≥ 5.02 on every dark surface |
| `deep` | `#4ABF61` / `#43C1A4` / `#2C92C8` (+ layers) | `brand.on` ≥ 4.65 |
| `spectrum` | `#FFD54F` 0 → green .24 → mint .46 → azure .70 → `#9D7BF7` 1 | the onboarding hero art only, never under text |

## 12. Implementation status

Done: tokens and generator (§11); capture and island (A.2–A.3); the app icon (§6); main window, Settings, onboarding,
empty states, Dictation page, Lab, panels (A.4); web ui tokens, review page (rebuilt `review.html`), Tauri app UI,
overlays (A.5–A.8). Left: remove the deprecated CSS aliases next release; update `desktop-app.md` §2.4; retake promo
and README screenshots; the site redo; optionally the dark app icon (§6).

## 13. Open questions

- **Selection wash vs native selection**: if drawing selection ourselves fights VoiceOver or keyboard focus cues,
  fall back to native selection and keep mint for rings and badges.
- **Glow cost on the island**: the pre-rendered glow image is cheap. Verify that it doesn't fight the notch's black
  edge on external displays without a notch, where the island floats.
- **Colour-blind check**: run a deuteranopia simulation on the main list and the island (green stop vs `ok`).
- **Windows / Linux**: check the gradient and the island glow on Mica dark and GNOME dark.

---

## 14. Restraint audit (v2.1)

The user's verdict on v2 as first shipped: flashy, too complicated, overused — use it with reason. Every gradient,
spectrum, glow, rim and decorative line was audited; each one either says something the plain UI doesn't, or it went.
Before / after screenshots (untracked): `promo/cases/v0.8-color/restrained/sheet*.png`.

**Removed or changed**

| Where | Was | Now |
|---|---|---|
| Main window job rows (整理 · 未归类), Lab recorder card | `AIGlowView` / `.aiGlow`: 2 pt spectrum rim + 14 pt blurred rim, turning every 3.2 s | spinner + a static 1 pt `brand.working` hairline (`WorkingOutline`, `.aiWorking`) |
| "Still organising" banner (还在整理 · 查看进度) | spectrum rim | its wand icon becomes a small spinner; the banner's own quiet ink wash; no line |
| Island AI-sort / hand-off job row | spectrum rim | the row's progress bar + the 1 pt hairline (island value) |
| Island, AI sort finished | spectrum bloom round the island | none (the chick hatching in the ear says it) |
| Lab Compare / Run All buttons, Dictation "Make Item" | spectrum rim round the button | none: the spinner beside it |
| Lab score | 30 pt gradient text + spectrum bloom | 30 pt neutral |
| Dictation page stats | 15 pt bold gradient digits | neutral semibold digits |
| Onboarding Done | spectrum bloom, 1.1 s delay | closes at once |
| Live-text panel | 2 pt gradient "hearing" rule under the text | removed |
| Snap while recording | mint ring + blurred gradient halo | flat mint ring |
| Picker window hover | `gradient.field` wash at 22 % | flat `brand.tint` |
| Empty states (All Items / first launch, inbox zero, nothing in progress, all filed, a project, no results, no index, Dictation, sessions; Tauri inbox / sessions) | 104 pt field-and-grain tiles with a per-page white glyph (inbox zero hopped); Tauri: the mascot on a 112 px field tile | the app-icon mark (80 pt canvas / 64 pt tile), one component, one set of spacings |
| Review page "organising" pill | `.ai-glow` spectrum rim | `.ai-working` hairline (the hatching egg is the motion) |
| Review page Done screen | the logo turned the spectrum once; the headline in gradient text | plain logo, neutral headline |
| Tauri sidebar jobs box | `.ai-glow` | `.ai-working` |
| Tokens | `gradient.aiGlow`, `gradient.wash`, `brand.glow`; CSS `--brand-spectrum*`, `--ai-glow-opacity`, `--brand-wash`, `--brand-glow`; Swift `BrandGradient.spectrum()`, `aiGlow*`, `wash*`; views `AIGlowView`, `Celebration`, `.celebrate`, `HearingRule`, `EmptyArtTile`, `BrandArtTile` | removed; `brand.working` (+ `--brand-working`, `BrandColor.working`, `workingWidth`) added |

**Kept (each carries meaning)**

| Where | Why |
|---|---|
| Picker selection outline (gradient dashes over a dark under-stroke) | it is the selection, on any screen content |
| Primary buttons (`gradient.button`, white title): main window, banners, picker Snap / Record, island Organize / Done, toast action, onboarding Next / Done, Lab Run / Save | the one primary of a view |
| Island level bars (vertical gradient) and the listening glow under the island | blurt hears you (only while listening) |
| Handles, size label, window-hover line and label, clasps, picked card border, count pills (flat mint) | selection / blurt's own marks |
| Selection and drop-target tints (`brand.tint`), state rings, progress bars (flat ink) | state |
| Onboarding hero (field + grain + the still spectrum glow) and its gradient title | the one hero moment; the only spectrum and the only gradient text |
| The app icon tile (field + grain) | the brand mark; now also the empty-state mark |
| Links' and the active tab's underlines, the `ok` check on toasts and done states | they mean something |
| Native controls in `brand.accent` | system controls, the app's accent |

## Appendix A. Migration list

**Migrated** (v2 shipped); kept as the record of what moved where. Deviations: the countdown's G → `rec` cross-fade
is moot (`CountdownView` is unused; its ring is `rec`); the picker's 120 ms hover cross-fade is not done; the open
island's level bars are gradient (not flat mint); `WebHostController.accentHex` keeps `controlAccentColor` (it hands
the system focus colour to the web canvas). Line numbers are at `85783513` (feat/live-snap).
"→" gives the token. `BrandColor.*` is the generated Swift API (`fill`, `ink`, `tint`, `on`, `rec`, `attn`,
`attnInk`, `ok`, `err`, `info`, `markup`, and `BrandColor.Island.*` for the always-dark values). `BrandGradient` is §5.1;
`KindStyle.palette` is generated from `kind.*`. **Gradient** marks where v2 replaces a flat value.

The site (`site/`) is intentionally not in this list (§3.8).

### A.1 Swift: the definitions

| Where | Today | → |
|---|---|---|
| `App/Support.swift:99` `let accent = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.24…)` (coral) | global used by capture + island | **delete**; each use maps below to `BrandColor.Island.fill`, `.Island.rec` or `.markup` |
| `App/Support.swift:100` `let amber = …(1.0, 0.76, 0.24)` | island / capture amber | `BrandColor.Island.attn` (`#FFC23D`) |
| `Icons/StatusRing.swift:16` `accent = dynamic(0xF55B3E, 0xFF7A5C)` | state rings, list brand | `BrandColor.ink` |
| `Icons/StatusRing.swift:17` `attention = dynamic(0xB86E00, 0xF5A524)` | | `BrandColor.attn` (same values) |
| `Icons/StatusRing.swift:18` `keep = dynamic(0x15965F, 0x2B9466)` | | `BrandColor.ok` (`#3F7414` / `#8ACB4E`) |
| `Icons/StatusRing.swift:20` `attentionGlyph` | | `BrandColor.onAttn`; add `onOk` for the done check (today hard-coded white) |
| `Icons/KindStyle.swift:22-27` `palette` | issue/idea/note/task | generated from `kind.*` (issue `#D9432A`/`#FF7A5C`, task `#7650D8`/`#A994F5`) |
| `Icons/KindStyle.swift:59` `customColor` | hash hue | skip 145–190° (§2.5), same in `kinds.ts` |
| `Capture/Island/Ears.swift:239` `dictationTint = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.74…)` | mint | `BrandColor.Island.fill` (note: sRGB `#61DBBD`, today it is *calibrated* RGB, a hair different) |
| `MainWindow/ItemCells.swift:17` `Look.brand = StatusRing.accent` | | `BrandColor.ink` (and update the comment "Brand coral…") |
| `Terminal/TerminalStyle.swift:33-37` running `.controlAccentColor`, waiting `0xFFC53D/0xE5A000`, done `0x3DD68C/0x218358`, error `0xFF6B6B/0xD93D42` | | running `BrandColor.ink`, waiting `BrandColor.attn`, done `BrandColor.ok`, error `BrandColor.err` |
| `Icons/ProjectLook.swift:9-10` palette `[…, .systemTeal, …, .systemMint, …]` | project hues | drop `.systemMint` and `.systemTeal` (they read as brand); replace in place with `.systemOrange`, `.systemBrown` to keep 8 entries. Check whether the index is stored or hashed: if hashed, existing projects change colour once. |

### A.2 Swift: capture

| Where | Today | → |
|---|---|---|
| `Capture/Picker.swift:146` selection stroke `NSColor.white.withAlphaComponent(0.95)`, 1.5 pt | | under-stroke `BrandColor.Island.on` @ 0.6, 2 pt; then the **gradient stroke** (`BrandGradient.linear` masked by a 2 pt dashed `[6, 4]` CAShapeLayer, §5.1) |
| `Capture/Picker.swift:152-157` handles white fill + `accent` rim | | fill `Island.fill`, 1.5 pt white ring, shadow |
| `Capture/Picker.swift:164` size label `bg: NSColor(white: 0.08, alpha: 0.82)`, fg white | | `bg: Island.fill`, `fg: Island.on` |
| `Capture/Picker.swift:166-170` window hover `accent` 0.9, 3 pt dashed | | `Island.fill` 2 pt solid + `Island.tint` fill |
| `Capture/Picker.swift:174` hover label `bg: accent` 0.92, fg white | | `bg: Island.fill`, `fg: Island.on` |
| `Capture/Picker.swift:369` toolbar Start `PillButton(fill: accent)` | | **gradient** (`BrandGradient.linear`), title `Island.on` (PillButton needs a gradient fill and a title colour) |
| `Capture/Picker.swift:137,141,164,183,304,356-366` greys | | unchanged (neutral glass) |
| `Capture/Chrome.swift:7` `BorderView.color = accent` | recording border | `Island.rec` |
| `Capture/Chrome.swift:25` countdown ring `accent` | | `Island.rec` |
| `Capture/Recorder.swift:243` `borderView.color = isPaused ? amber : accent` | | `isPaused ? Island.attn (dashed) : Island.rec`; BorderView gains a `dashed` flag |
| `Capture/Snap.swift:465` `renderMarked` stroke `accent` | burned-in pen | `BrandColor.markup` |
| `Capture/Snap.swift:513-538` `borderFlash` white ring + white shadow | snap while recording | `Island.fill` 3 pt stroke + `gradient.glow` halo (mint, 24 pt, 35–55 %) |
| `Capture/Snap.swift:496` `shutterFlash` white | | unchanged |
| `Capture/InkView.swift:28-29,59` halo + stroke `accent` | pen | `BrandColor.markup` (halo 25 % stays) |
| `Capture/NoteBubble.swift:418` sketch stroke `accent` | pen | `BrandColor.markup` |
| `Capture/NoteBubble.swift:519` voice level bars `active ? accent : tertiary` | listening | `active ? BrandColor.ink : tertiary` (bubble is a light/dark panel) |
| `Capture/NoteBubble.swift:613` delete `iconColor: .systemRed` | destructive | unchanged |
| `Capture/NoteBubble.swift:724` `keepBtn.contentTintColor = .controlAccentColor` | primary in the bubble | `BrandColor.ink` |
| `Capture/NoteBubble.swift:1078-1079` saved `.systemGreen` | | `BrandColor.ok` (glyph already a check) |
| `Capture/NoteBubble.swift:588,591,696,767` greys | | unchanged |
| `Capture/CardExport.swift:176` text white | | unchanged |

### A.3 Swift: island and hanging cards

| Where | Today | → |
|---|---|---|
| `Capture/Island/Ears.swift:155,159` recording dot `systemRed` / paused `amber` | | `Island.rec` / `Island.attn` |
| `Capture/Island/Ears.swift:184` alert dot `amber` | | `Island.attn` |
| `Capture/Island/Ears.swift:199` iconText tint `dictationTint` | | `Island.fill` |
| `Capture/Island/Ears.swift:220` `drawLevel` `systemGreen` | recording level | **gradient bars** (bars path as the mask of a vertical `BrandGradient` over the 18 pt group box), no glow |
| `Capture/Island/Ears.swift:235` `drawWave` `accent` | voice note | **gradient bars** + listening glow |
| `Capture/Island/Ears.swift:254` `drawMirror` `dictationTint` | | **gradient bars** + listening glow |
| `Capture/Island/Ears.swift` keyboard glyph (`glyph(.keyboard, 14)`, white) | | `Island.fill` |
| `Capture/Island/IslandContent.swift:153` selected row `accent` 0.192 | | `Island.tint` |
| `Capture/Island/IslandContent.swift:169` check mark `accent` | | `Island.fill` |
| `Capture/Island/IslandContent.swift:206` progress `accent` | | `Island.fill` |
| `Capture/Island/IslandContent.swift:215` `Bars.color = .systemGreen` default | | `Island.fill` |
| `Capture/Island/IslandContent.swift:388` agent dot `amber / systemRed / systemGreen` | | `Island.attn` / `Island.err` / running `Island.fill`, finished `Island.ok` |
| `Capture/Island/IslandContent.swift:416,418` "hand to AI" `fill: accent` 0.9 | primary | **gradient**, title `Island.on` |
| `Capture/Island/IslandContent.swift:465,488` discard / stop `systemRed` | | discard system red (unchanged); stop `Island.rec` |
| `Capture/Island/IslandContent.swift:501` paused hint `amber` | | `Island.attn` |
| `Capture/Island/IslandContent.swift:526` voice panel `wv.color = accent` | | `Island.fill` |
| `Capture/Island/IslandContent.swift:559` quoted query `accent` | | `Island.fill` |
| `Capture/Island/IslandContent.swift:583` folder icon `calibratedRed 0.55/0.72/1` | | the project's `ProjectLook` colour |
| `Capture/Island/IslandContent.swift:608` AI sort wand `accent` | | `Island.fill` |
| `Capture/Island/IslandContent.swift:746` toast filled button `accent` 0.9 | | **gradient**, title `Island.on` |
| `Capture/Island/IslandContent.swift:770` live text `ink` | live-text panel | text neutral; caret flat `Island.fill`; 2 pt **gradient** "hearing" rule under the line (new) |
| `Capture/Island/IslandContent.swift:18-20,71,180,204,330,396,599,718` white tiers | | unchanged |
| `Capture/Island/HangingCards.swift:358` `tipPlay` `accent` | | `BrandColor.fill` |
| `Capture/Island/HangingCards.swift:381` clasp `accent` | | `BrandColor.fill` (ring stays the card surface) |
| `Capture/Island/HangingCards.swift:515` voice card mic `accent` 0.85 | | `BrandColor.ink` (card surface is light or dark) |
| `Capture/Island/HangingCards.swift:1468` picked border `accent` | | `BrandColor.fill` |
| `Capture/Island/HangingCards.swift:352-416,459-554,686,1305-1315,1463` surfaces, threads, scrims, text | | unchanged (neutral) |

### A.4 Swift: main window, settings, app

| Where | Today | → |
|---|---|---|
| `MainWindow/ItemCells.swift:33-35` `stateColor` | | `BrandColor.ink` / `.attnInk` / `.ok` |
| `MainWindow/ItemCells.swift:348` `ItemRowView` | native inset selection | override `drawSelection`: `BrandColor.tint` rounded (r 6), neutral 6 % when not key; `isEmphasized` false so text stays `labelColor` |
| `MainWindow/SidebarController.swift` sidebar row view, badge (`:247-259`) | native source-list selection; count text | selection as above; unread/new count as a mint pill (`fill` / `on`) |
| `MainWindow/JobViews.swift:45,231,345,421` `.systemRed` (failed) | | `BrandColor.err` (text / icon) |
| `MainWindow/JobViews.swift:46,186` `StatusRing.attention` | | `BrandColor.attn` |
| `MainWindow/JobViews.swift:196` selected `controlAccentColor` 0.14 | | `BrandColor.tint` |
| `MainWindow/JobViews.swift:390` spinner arc `StatusRing.accent` | | `BrandColor.ink` |
| `MainWindow/JobViews.swift:413` done disc `StatusRing.keep` + white check | | `BrandColor.ok` + `BrandColor.onOk` |
| `MainWindow/ItemListController.swift:180,184,221` banners `controlAccentColor` | captures banner | `BrandColor.ink`, then (v0.9) `NoticeCard`: `attn` glyph, neutral text, no brand colour |
| `MainWindow/CommandPalette.swift:269` chosen row `controlAccentColor` 0.85 (white text) | | `BrandColor.tint`, text `labelColor`; `isEmphasized` false |
| `MainWindow/ProjectSettings.swift:144` `.systemRed` key error | | `BrandColor.err` |
| `MainWindow/DictationLabViews.swift:15` `keepGreen` | | `BrandColor.ok` |
| `MainWindow/DictationLabViews.swift:243,252` diff deletions `systemRed`; `:247` additions `systemOrange` 0.28 | diff | deletions `BrandColor.err`; additions `BrandColor.attn` @ 0.28 (keep: a diff is not brand) |
| `MainWindow/DictationLabViews.swift:293-294` chip on `accentColor` 0.22 / 0.6 | selected chip | `BrandColor.tint` / `BrandColor.ink` |
| `MainWindow/DictationLabViews.swift:365` recording dot `systemRed : accentColor` | | `BrandColor.rec : BrandColor.ink` |
| `MainWindow/DictationLabViews.swift:597` stars `Color.orange` | rating | `BrandColor.attn` |
| `MainWindow/DictationLabViews.swift:715` level bars `accentColor` 0.8 | listening | `BrandColor.ink` |
| `MainWindow/DictationLabViews.swift:829` chosen check `accentColor` | | `BrandColor.ink` |
| `MainWindow/DictationLabViews.swift:939` worse `Color.red` 0.15 | | `BrandColor.err` @ 0.15 |
| `MainWindow/DictationPage.swift:419` `tint = .accentColor` | | `BrandColor.ink` |
| `MainWindow/DictationPage.swift:521` "can't work" dot `Color.orange` | | `BrandColor.attn` |
| `MainWindow/DictationPage.swift:614,778,843` `StatusRing.keep` | | `BrandColor.ok` |
| `MainWindow/DictationPage.swift:820` focused box `accentColor` 0.6 | | `BrandColor.ink` @ 0.6 |
| `WebHost/WebHostController.swift:111` `accentHex()` = `controlAccentColor` | → `blurtHostInfo.accent`, focus only | unchanged (focus = system) |
| `WebHost/WebHostController.swift:465` primary banner button `bezelColor = .controlAccentColor` | | a `BrandButton` (layer-backed, `BrandGradient.linear` fill, title `BrandColor.on`); `bezelColor` cannot carry a gradient |
| `WebHost/WebHostController.swift:477,483` tint `StatusRing.accent` | | `BrandColor.ink` |
| `WebHost/WebHostController.swift:491,497` tint `.controlAccentColor` (organising, suggested project) | | `BrandColor.ink` |
| `Settings/DictationPane.swift:511,708` selected `accentColor` | choice cards | `BrandColor.ink` border + `BrandColor.tint` ring |
| `Settings/DictationPane.swift:747-748` badge `tint: .accentColor` | | `BrandColor.ink` on `BrandColor.tint` |
| `Settings/SpeechPane.swift:457` sparkles `accentColor` | recommended | `BrandColor.ink` |
| `Settings/SpeechPane.swift:541-543,679-681` badges `accentColor` / 0.12 | | `BrandColor.ink` / `BrandColor.tint` |
| `Settings/AgentsPane.swift:259` "runs first" badge `accentColor` | | `BrandColor.ink` on `.tint` |
| `Settings/AgentsPane.swift:422` `applied ? .green : .accentColor` | | `applied ? BrandColor.ok : BrandColor.ink` |
| `Settings/Icons.swift:44-50` ok `.green`, failed `.red`, warning `.orange`, edit `.accentColor`, peck `.green` | log icons | `ok`, `err`, `attn`, `brand.ink`, `ok` |
| `App/HotkeySettings.swift:34,36,43` recording `controlAccentColor` | listening to keys | `BrandColor.ink` (fill `BrandColor.tint`) |
| `App/HotkeySettings.swift:36,42,350-354` conflict `systemOrange` | | `BrandColor.attnInk` |
| `App/AppDelegate.swift:374,377` status item rec `systemRed` / `amber` | | `BrandColor.rec` / `BrandColor.attn` |
| `App/AppDelegate.swift:388` urgent badge `StatusRing.attention` | | `BrandColor.attn` |
| `App/AppDelegate.swift:522` menu warning image `systemOrange` | | `BrandColor.attn` |
| `App/AppDelegate.swift:563`, `App/SnapApp.swift:426-427`, `System/Peck.swift:67` greys | | unchanged |
| `Onboarding/Onboarding.swift:101` step bars `accentColor` | | `BrandColor.ink` |
| `Onboarding/HelperPanel.swift:217` `accentColor` | | `BrandColor.ink` |
| `Terminal/FinishPanel.swift:87-88`, `Terminal/DispatchPanel.swift:210-211` icon + 0.12 circle `accentColor` | panel hero icon | `BrandColor.ink` + `BrandColor.tint` |
| `Terminal/TerminalStyle.swift:111-117` terminal fg/bg/selection | | unchanged |

### A.5 Web: `@blurt/ui` tokens and components

| Where | Today | → |
|---|---|---|
| `web/packages/ui/src/tokens.css` light/dark shared block: `--accent`, `--accent-ink`, `--accent-soft` | coral | generated: `--brand`, `--brand-ink`, `--brand-tint`, `--brand-glow`, `--on-brand`, `--brand-gradient`, `--brand-gradient-v`, `--brand-field`, `--brand-field-deep`, `--grain` (keep `--accent*` as deprecated aliases for one release: `--accent: var(--brand)`, `--accent-ink: var(--on-brand)`, `--accent-soft: var(--brand-tint)`; text uses must move to `--brand-ink`) |
| same: `--keep`, `--keep-ink`, `--keep-soft` | | `--ok`, `--ok-ink` (= `--ok`), `--ok-soft`; `--on-ok` |
| same: `--drop`, `--drop-ink`, `--drop-soft` | | `--err` (`#C02F35` / `#FF6B6B`); destructive fill stays `--drop` |
| same: `--amber`, `--amber-soft`, `--warn` | | `--attn-ink` (`--amber`), `--attn` (`--warn`), `--attn-soft` |
| same: `--sev-high/-medium/-low` | | `--kind-issue` / `--attn-ink` / `--info` |
| same: `--kind-*` | | generated (§2.5) |
| `web/packages/ui/src/base.css:37` `a { color: var(--accent) }` | | `color: inherit; text-decoration-color: var(--brand-ink)` |
| `base.css:133-135` `.btn.primary` | | `background: var(--brand-gradient); color: var(--on-brand)` + the inner highlight (§5.2) |
| `base.css:235,280` in_progress ring / pill text | | `var(--brand-ink)` |
| `base.css:237,283` done `--keep` / `--keep-ink` | | `--ok` |
| `web/packages/ui/src/kinds.ts:24` `SURFACE`, `customKindColor` | | hue gap 145–190° |
| `web/packages/ui/src/tokens.test.ts` | asserts `--accent*` | assert the new names and floors from `tokens.json` |

### A.6 Web: review page (`web/packages/review/src/styles/review.css`)

| Line / selector | Today | → |
|---|---|---|
| 198 `.qi.cur::before` background | `--accent` | `--brand-ink` |
| 233 `.qi.cur .qm .n` color | `--accent` | `--brand-ink` |
| 445 `.th.on` ring | `--accent` | `--brand-ink` |
| 472 `.th.vid .ic` | `--accent` | neutral `--mute` (a video badge is not brand) |
| 804 `.worklog .s-in_progress --wl` | `--accent` | `--brand-ink` |
| 870, 875 `.prov-sug` bg / icon | `--accent-soft` / `--accent` | `--brand-tint` / `--brand-ink` |
| 1073 `.quote .qmark` | `--accent` | `--mute` (quotes are text) |
| 1084, 1096 `.linkbtn` / hover | `--accent` / `--accent-soft` | `--brand-ink` / `--brand-tint` |
| 1425 `.wk` | `--accent` | `--brand-ink` |
| 1465-1467 `.pickbox.on` | `--accent` / `--accent-ink` | `--brand` / `--on-brand` |
| 1470-1476 `.card.sel` rings | `--accent` | `--brand-ink` |
| 1554-1562 `.dz.over` | soft / accent | `--brand-tint` / `--brand-ink` |
| 1641 `.toast button` | `--accent` | `--brand` on dark toast (toast is dark glass) |
| `src/hosts/macos.ts:10` example `accent: "#0a84ff"` | doc comment | unchanged (focus only) |

### A.7 Web: Tauri app (`web/apps/desktop`)

| Where | Today | → |
|---|---|---|
| `src/styles.css:6-7` `--rec: #e5484d; --attn: #f5a524` | local copies | remove, use generated `--rec` / `--attn` |
| `:50-56` `button.primary` (+ hover mix with black) | accent | `var(--brand-gradient)` / `--on-brand`; hover `filter: brightness(1.04)`, active `0.94` |
| `:134` `mark` | accent-soft | `--brand-tint` (search hits) |
| `:171-172` `.badge` | soft / accent | `--brand-tint` / `--brand-ink` |
| `:301,306` `.sidebar a.sel` + svg | soft / accent | `--brand-tint` / `--brand-ink` |
| `:309-310` `.sidebar a.drop` | soft + inset accent | `--brand-tint` + inset `--brand-ink` |
| `:324` `.sidebar .cur` | accent | `--brand-ink` |
| `:453` `.banner svg:first-child` | accent | `--brand-ink` |
| `:489-490, 509-510` `.batch .mode`, `.batch .pill` | soft / accent | `--brand-tint` / `--brand-ink` |
| `:530` `.hero-empty svg` | accent | `--mute` (empty states are neutral) |
| `:654, 663` `.fchip.on`, `.bulk` | soft | `--brand-tint` |
| `:686, 689` `.row.sel`, `.row.cur-row` | soft / 40 % accent | `--brand-tint` / 40 % `--brand-ink` |
| `:726` `.wnote.s-handed_off` | accent | `--brand-ink` |
| `:820` `.srow.sel` | soft | `--brand-tint` |
| `:832` `.sdot` | accent | `--brand` (running); waiting `--attn` |
| `:893-894` `.schip.s-running` | soft / accent | `--brand-tint` / `--brand-ink` |
| `:992` settings tab underline | accent | `--brand-ink` |
| `:995` `.note` | soft | `--brand-tint` |
| `:1010-1011` `.key-recorder.rec` | accent | `--brand-ink` |
| `:1089` `.palette li.sel` | soft | `--brand-tint` |
| `:1122` `.dispatch .switch input { accent-color }` | accent | `var(--focus)` (native control) |
| `:1148-1149` `.choice.on` | accent / soft | `--brand-ink` / `--brand-tint` |
| `src/components/Terminal.tsx:13,22` cursor `#ff7a5c` / `#e5482c` | | neutral (`#e6e6e9` / `#1f1f23`) |
| `src/components/Terminal.tsx:15,24` selection coral 0.28 / 0.2 | | `--focus` at 0.36 / 0.22 (matches SwiftTerm) |
| `src/components/Terminal.tsx:16-26` ANSI palette | | unchanged |

### A.8 Web: overlays (`web/apps/overlays`, Windows / Linux)

| Where | Today | → |
|---|---|---|
| `src/theme.css` `--accent: #ff7a5c; --rec: #ff3b30; --amber: #ffc23d` | | generated island values: `--brand: #61DBBD`, `--on-brand: #04261E`, `--brand-tint`, `--rec: #FF453A`, `--attn: #FFC23D`, `--ok`, `--err` |
| `src/picker.css:15` `.sel { outline: 2px solid var(--accent) }` | | an inline SVG rect: `--on-brand` 60 % under-stroke + gradient dashed stroke (§5.2) |
| `src/picker.css:71,76` `.bar button.primary` + hover `#ff9378` | | `var(--brand-gradient)` / `--on-brand`; hover `brightness(1.04)` |
| `src/island.css:128` `.badge` | accent | `--brand` + `--on-brand` |
| `src/island.css:138,143,163-166,466,558` red / amber halos as rgba | | `color-mix` of `--rec` / `--attn` |
| `src/island.css:173,189,427` `#f4e7d0` egg cream | illustration | unchanged |
| `src/island.css:201` `.wave i` | accent | gradient bars: `background: var(--brand-gradient-v) center / 100% 18px` |
| `src/island.css:423` `.tick` | accent | `--brand` |
| `src/island.css:441` `.bar i` (progress) | accent | `--brand` |
| `src/island.css:462` `.sdot` | accent | `--brand`; waiting `--attn` |
| `src/island.css:625,821` `.row.target.ai .ic`, `.sort .ic` | accent | `--brand` |
| `src/island.css:629-630` drop over | accent mixes | `--brand-tint` + `--brand` 45 % |
| `src/island.css:676` `.leg .clasp` | accent | `--brand` |
| `src/island.css:743` `.face.voice .ic` | accent | `--brand-ink` (card face can be light) |
| `src/note.css:70` textarea focus inset | accent | `--focus` (native-ish focus) |
| `src/note.css:97` `.row button.primary` | accent | `var(--brand-gradient)` / `--on-brand` |
| `src/note.ts` `#6b8fd6` | | check: likely `--info` |

### A.9 Brand assets, Tauri shell, tests, docs

| Where | → |
|---|---|
| `assets/brand/*.svg` (`#ffe36b`→`#ffc93a` tile, `#17140f` line, white body) | **tile replaced** by the gradient field (§6): `chick.swift` writes the field layers into `#tile`, `build.py` renders as today (rsvg-convert supports the radial gradients, `feTurbulence` and `mix-blend-mode`); 32 / 16 px use the base linear only |
| `assets/brand/README.md` tile option (c) "coral arcs" note | historical; no change |
| `apps/desktop/src-tauri/icons/tray.svg` (`#000`) | unchanged (template) |
| `assets/icons/*.svg` (`currentColor`) | unchanged |
| `tests/test_icons.py:109-121` (Swift ↔ tokens.css parity for accent / attention / keep) | replace with `assets/color/build.py --check` (generated files up to date) + contrast floors from `tokens.json` |
| `web/packages/ui/src/tokens.test.ts` | new names; read floors from `tokens.json` |
| `docs/design/desktop-app.md` §2.4 "品牌橙…" and line 625 "不替代品牌橙" | point here; "品牌薄荷" |
| `promo/` and README screenshots | retake after implementation |

