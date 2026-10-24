# blurt design system (v0.8)

> **中文摘要**
> 这是口喷鸡的设计系统 v2，macOS 应用和 Tauri（Windows / Linux）应用已经按它实现；官网之后按它重做，这次没改。
> - **品牌色是薄荷 `#61DBBD`**，含义：口喷鸡正在听、正在截、正在替你动手；另外用于每屏唯一的主操作和列表选中行的浅薄荷底。
> - **品牌渐变**：清新绿 `#66D97A` → 薄荷 `#61DBBD` → 天蓝 `#4AABE2`，薄荷是中间发亮的分界。大面积版本（field）带弧形分界和细颗粒（grain）。
> - **主按钮用更深的"按钮渐变"**（`#028932` → `#02866F` → `#087EB3`，同一条色相路径），上面是**白色粗体字**，每一点都 ≥ 4.5 : 1。薄荷小标签、徽章仍用深绿字。
> - **大标题和大数字可以用渐变字**（引导页标题、空状态标题、Lab 分数、听写页统计）；浅色背景用更深的文字渐变（≥ 3 : 1），正文和小字不用。
> - **系统控件用品牌色**：App 声明了 `AccentColor`（浅色 `#0B735E`，深色 `#1CA288`），开关、复选框、滑块、焦点环跟着走；网页端用 CSS `accent-color`。
> - **多彩"光谱"渐变**（加黄和紫）只用于特别时刻：引导页主视觉、"AI 正在处理"的光晕（自动整理、润色、Lab 运行）、完成时的庆祝。日常界面只用核心渐变。
> - 红 = 正在录，琥珀 = 要你处理，叶绿 + ✓ = 完成。珊瑚只剩画笔。task 类型改为紫色。
> - **App 图标**：白身黑线的鸡（方案 A）放在渐变 field 底板上。
> - 唯一来源：`assets/color/tokens.json` + `assets/color/build.py`（生成 Swift `BrandColor`、CSS 变量、`AccentColor`，`--check` 检查过期和对比度）。

Status: **v2, implemented** in the macOS app (`skills/blurt/recorder/macos`), the web UI packages (`web/packages/ui`,
`web/packages/review` → `skills/blurt/scripts/review.html`) and the Tauri app's UI (`web/apps/desktop`,
`web/apps/overlays`). The site (`site/`) is not migrated (§3.8). It supersedes the v1 colour proposal and the visual
parts of [desktop-app.md §2.4](desktop-app.md#24-视觉语言).

The user amended the v2 proposal before it shipped; those amendments are folded in below and marked **(amended)**:
gradient text for large headlines, native controls in the brand accent, white text on a deeper button gradient, and a
multi-hue spectrum for special moments.

Mock-ups and screenshots (untracked, in `promo/cases/v0.8-color/`):

| File | What it shows |
|---|---|
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
   and never a thin line, except the one capture selection (and the hearing rule under live text).
3. **Most of the app is grey.** Neutral surfaces and text. Colour is information.
4. **Native stays native, in the brand accent (amended).** Switches, checkboxes, radios, sliders, focus rings and
   selection are the system's own controls, tinted by the app's `AccentColor` (`brand.accent`). If the user picked a
   system accent other than Multicolor, macOS uses theirs, as for every app.
5. **Every coloured state has a shape twin**: dashed vs solid, dot vs ring, check vs "!". It must survive grayscale,
   colour blindness and Reduce Motion.
6. **One direction.** Green is up / start, azure is down / end. No reversed gradients. Extra hues (yellow, violet)
   only in the spectrum, only for special moments (§2.2).

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
| `gradient.linear` | `green 0 %` → `mint 45 %` → `azure 100 %`, **corner to corner** (CSS `to bottom right`; CAGradientLayer `startPoint (0, 1)` → `endPoint (1, 0)` in an unflipped layer). No grain. | The capture selection stroke, level bars (vertical), the snap ring halo, the live-text rule; dark `brand.on` text where text sits on it. |
| `gradient.button` **(amended)** | `#028932 0 %` → `#02866F 45 %` → `#087EB3 100 %`, corner to corner: the same OKLab hues (147° / 175° / 237°) at L ≈ 0.55. **White semibold text ≥ 4.51 : 1 at every point** (≥ 4.22 at hover ×1.04). | Primary buttons (one per view), Snap / Record in the picker, the island's filled buttons, toast actions. |
| `gradient.text` **(amended)** | Light: `#14983C` → `#07957C` → `#248CC2` (≥ 3.17 : 1 on every light surface at every point). Dark: the base stops (≥ 5.02 : 1). Horizontal. | Large headlines and hero numbers only (≥ 20 pt, or ≥ 14 pt bold): onboarding title, empty-state titles, the Lab score, the Dictation page stats. Flat `brand.ink` under Increase Contrast. |
| `gradient.spectrum` **(amended)** | `#FFD54F 0 %` → green 24 % → mint 46 % → azure 70 % → `#9D7BF7 100 %` (conic: the same stops round the circle) | **Special moments only**: the onboarding hero glow, the "AI is working" rim (`gradient.aiGlow`: auto-sort / organize, polish, Structured, the Lab run), the completion bloom. |
| `gradient.vertical` | Same stops, top → bottom, sized to the group (18 pt for the island level) | Level bars: one gradient across the whole bar group, so each bar shows the slice at its height (short bars read mint, tall ones show green tips and azure feet). |
| `gradient.field` | Bottom → top: base linear 180° `#66D97A` → `#69DC95`. A large azure ellipse rises from the bottom-left (centre (0.28, 1.16), radii (1.08, 0.80) of the box): `#3C9ED5` 0 → `#4AABE2` 0.5 → mint 0.70 → a glow `#A3F0DA` @ 60 % at 0.79 → clear at 0.93. A second azure from the bottom-right (1.02, 1.08; 0.58 × 0.52). An airy top highlight `#80E991` (0.62, −0.12; 0.75 × 0.48). Then **grain**. | Large surfaces ≥ 64 pt: the app icon tile, the onboarding hero, empty-state art. The ellipse's mint rim is the large organic curve of the reference. |
| `gradient.deep` | The field with stops `#4ABF61` → `#43C1A4` → `#2C92C8` (0.08 darker in L), corners `#2786BD`, glow `#5FC9AC`. `brand.on` ≥ 4.65. | The field in dark mode (onboarding, empty states); the icon's optional dark appearance. |
| `gradient.wash` | The field at **14 %** over a light surface, **18 %** over a dark one. | Window-hover wash (22 % over screen content), onboarding and empty-state backdrops. Text on it stays neutral `ink`. |
| `gradient.glow` | `gradient.linear` horizontal, blurred 24 pt, 35–55 % | The island's listening aura, the snap ring halo. Only while something is happening. |
| `grain` | Monochrome fractal noise (base frequency 0.8 / px at 1x, 2 octaves, contrast ×3), **overlay** blend, **10 %** light / **8 %** dark, **7 %** on the app icon | Only on `field` / `deep` surfaces **≥ 64 pt** in both dimensions. Never on buttons, bars, strokes or text. Off with Reduce Transparency. |
| `gradient.aiGlow` | The spectrum as a 2 pt rim plus a 14 pt soft rim at 55 %, turning once per 3.2 s | Around what AI is working on, only while it works. Still with Reduce Motion; gone with Reduce Transparency. |

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

Neutrals never tint toward mint. **Native controls use the brand accent (amended)**: the app declares
`NSAccentColorName = AccentColor` (an asset compiled into `Assets.car`), so AppKit and SwiftUI controls, focus rings
and `Color.accentColor` resolve to `brand.accent` while the user's system accent is Multicolor (the default); a user
who picked another accent keeps it. The web UI sets CSS `accent-color: var(--brand-accent)` and
`--focus: var(--sys-accent, var(--brand-accent))` (the macOS host injects its accent as `--sys-accent`). Code that
means "brand" uses the explicit `BrandColor` token, never `controlAccentColor`, so it stays brand in every case.

### 2.5 Item kinds (icon colours)

These are icon tints only (and the kind chip in the review page). Floor 3 : 1 on every surface, including `#EAEAEA` /
`#383838`.

| Kind | Light | on `#FFF / #F6F6F6 / #ECECEC / #EAEAEA` | Dark | on `#1E1E1E / #2A2A2A / #323232 / #383838` | vs today |
|---|---|---|---|---|---|
| issue | `#D9432A` | 4.39 / 4.06 / 3.71 / 3.65 | `#FF7A5C` | 6.50 / 5.60 / 5.00 / 4.57 | toward the retired coral (was `#D93D42` / `#FF6B6B`) |
| idea | `#A8710A` | 4.17 / 3.86 / 3.53 / 3.47 | `#FFC53D` | 10.56 / 9.09 / 8.12 / 7.43 | unchanged |
| note | `#3E63DD` | 5.21 / 4.82 / 4.41 / 4.33 | `#8DA4EF` | 6.90 / 5.94 / 5.30 / 4.85 | unchanged |
| task | `#7650D8` | 5.37 / 4.97 / 4.55 / 4.47 | `#A994F5` | 6.54 / 5.63 / 5.03 / 4.60 | green → violet (was `#218358` / `#3DD68C`) |

Custom lenses (`KindStyle.customColor`, `kinds.ts customKindColor`): if the hashed hue lands in **145°–190°** (HSL),
add 60°, so no lens looks like brand or success.

## 3. Usage by surface

Legend: **G** = gradient (`linear` unless noted), **B** = `gradient.button` with a white title, **S** = the
spectrum, **M** = flat mint (`brand.fill`), **I** = `brand.ink`, **T** = `brand.tint`, **—** = no brand colour.

### 3.1 Capture (picker, chrome, flashes): always over screen content

| Element | Brand | Detail |
|---|---|---|
| Selection outline | **G** stroke | 2 pt dashes (6 / 4), the gradient corner to corner across the selection, over a 2 pt `brand.on` @ 60 % solid under-stroke so it holds on white and black. The dashes march (10 pt/s) while dragging and stop with Reduce Motion. *The only thin gradient line in the system.* |
| Handles | M | 9 × 9, r 2.5, 1.5 pt white ring, 1 pt shadow |
| Size label | M | pill, `brand.on` monospaced digits |
| Snap / Record button (picker toolbar) | **B** | white semibold title; a small `rec` dot before "Record" (`PillButton(gradient:fg:dot:)`) |
| Hint pill, other toolbar buttons | — | dark glass, white text |
| Dim outside the selection | — | black 42 % |
| Window hover | M + wash | 2 pt mint line, `gradient.field` at 22 % inside, mint label pill with `brand.on` text |
| Countdown ring | `rec` | the recording is committed |
| Recording frame | `rec` | solid 2.5 pt. Paused: `attn` dashed. The switch from mint to red at the end of the countdown *is* the "now recording" signal. |
| Snap while recording (`borderFlash`) | M + glow | 3 pt mint ring with the `gradient.glow` halo, 450 ms, outside the red frame |
| Standalone snap shutter | — | white flash |
| Pen strokes (InkView, NoteBubble sketch, `renderMarked`) | `markup` | coral, with a 45 % black halo |
| Live caption, HUD text | — | white on glass |

### 3.2 Notch island and hanging cards

| Element | Brand | Detail |
|---|---|---|
| Listening (dictation, voice note): level bars | **G** vertical | one gradient across the bar group |
| Listening aura | **glow** | `gradient.glow` under the notch at 35–55 %, fades in over 200 ms when listening starts and out when it stops. Only while listening or capturing; never while idle. |
| Dictation keyboard glyph, voice mic glyph | M | |
| Recording ear | `rec` dot + white time | paused `attn`. The mic level bars there are **G** too (blurt hears you), but there is **no glow**: red owns that moment. |
| Live-text panel | M caret, **G** rule | text 92 % white (committed) / 60 % (pending). A flat mint 2 pt caret. A 2 pt `gradient.linear` (horizontal) "hearing" rule under the text while listening; it fades when the line commits. |
| Alert dot | `attn` | |
| List rows: selection / hover target | T (island 20 %) | |
| Check marks, progress, AI-sort wand, quoted query | M | |
| AI sort / organize running | **S** rim | `AIGlowView` around the running row; a spectrum bloom (`Celebration`) when it finishes |
| Agent dots | M running · `attn` waiting · `err` error · `ok` finished | |
| Filled island buttons (Organize, Auto-sort, voice Done, toast action) | **B** | white semibold title (`IslandButton(gradient:fg:)`) |
| Stop / Discard | `rec` / system red | |
| Hanging-card threads | — | neutral hairline with an opposite-tone halo |
| Clasps | M | ringed in the card surface |
| Picked card border | M | 2.5 pt flat (thin, so no gradient) |
| Voice card mic mark, stack "play" tip | I on the card face / M | |
| Project folder icons | project colour | `ProjectLook`, minus `.systemMint` / `.systemTeal` |

### 3.3 Main window (AppKit) and the Tauri app

| Element | Brand | Detail |
|---|---|---|
| Primary button (one per view) | **B** | `BrandButton` / `.buttonStyle(.brand)` / CSS `--brand-button`: white semibold title, 1 pt inner top highlight (white 18 %), 1 pt shadow (`brand.on` 25 %). Hover ×1.04, pressed ×0.92. Disabled: neutral fill, no gradient. Small dialog defaults (↩ in sheets and alerts) stay native and show `brand.accent`. |
| Secondary, tertiary buttons | — | native |
| Destructive | system red | |
| List and sidebar selection | T | rounded wash, r 6, text stays `ink`; neutral 6 % when the window is not key |
| Command palette chosen row | T | |
| Focus ring, text selection | `brand.accent` (native) | via `AccentColor`; the user's own system accent wins when set |
| Links | I underline | text `ink`, 1.5 pt `brand.ink` underline; standalone text / link buttons in `brand.ink` |
| State rings new / handed_off / in_progress, job spinner arc | I | |
| to_verify / done / todo / wontfix / discarded | `attn` + "!" / `ok` + ✓ / secondary / tertiary | |
| "New" counts and badges | M | pill, `brand.on` digits (`CountPill`); plain counts neutral |
| Job running (process / route) | **S** rim | `.aiGlow` on the running job row; the web host's "organising" banner too |
| Progress bars | I (light) / M (dark) | flat: too thin for the gradient |
| Kind icons | kind tokens | |
| Severity | `kind.issue` / `attnInk` / `info` | |
| Terminal | — | the ANSI palette is a terminal theme; selection = system accent |

### 3.4 Settings and onboarding

| Element | Brand | Detail |
|---|---|---|
| Switches, checkboxes, radios, sliders, focus | `brand.accent` (native) | the `AccentColor` asset; no custom drawing |
| Mic test meter | **G** vertical (dark) / I (light) | idle bars neutral |
| "Recommended", "Runs first" badges | T + I | |
| Selected choice card (dictation style, model) | I border + T ring | not a filled card |
| Hotkey recorder while listening for keys | I | conflict `attnInk` |
| Onboarding hero panel | **field** + grain (light), **deep** + grain (dark), **S** glow | A 200 pt side panel (the window grows to 840 pt; the content column keeps 640): the mascot on a still, blurred spectrum glow. Flat field without grain or glow under Reduce Transparency. |
| Onboarding title | gradient text | 24 pt bold, `gradient.text` |
| Onboarding Next / Done | **B** | Done blooms the spectrum once round the chick (not with Reduce Motion / Transparency), then closes |
| Onboarding step bars | I | |
| Permission rows | `ok` + ✓ granted · `attn` dot missing | |

### 3.5 Empty states

These cover the empty inbox, no recordings, no results, first launch of a page. One tile of art, 96–128 pt (104 in
the app: `EmptyArtTile` / `BrandArtTile`), r ≈ 30 % of the side: the **field** (light) or **deep** (dark) with grain,
and the white line chick (or a glyph from `assets/icons`) on it with a soft `brand.on` 30 % drop shadow. Below it a
neutral title (13 pt semibold; gradient text only when it is a large headline), a neutral hint (11 pt, `mute`), and at
most one primary button when it moves you on (Open Folder, Turn On Dictation…). Trouble states (scan failed, missing
folder) keep a quiet symbol: warnings are never brand.

### 3.5a Dictation page and Lab

- Today's stats: the digits in gradient text (15 pt bold), the words around them neutral.
- The Lab score: 30 pt gradient text; it blooms (spectrum) once when a run finishes.
- The Lab's Run / Save / Next: **B**; the recorder card, Compare and Run carry the **S** rim while processing.
- Diff: deletions `err`, additions `attn` @ 28 %; stars `attn`; chosen check and level bars `brand.ink`.

### 3.6 Menu-bar icon

No colour. `glyph.svg` is a template image; listening is shown by motion (the arcs pulse). The recording status item
shows a `rec` dot and the time, or `attn` while paused.

### 3.7 Review page and overlays (web)

- **Review page** (`web/packages/review`): primary **B**; the "organising" pill carries `.ai-glow`; the Done screen's
  headline is `.g-text` and its logo turns the spectrum once; selected card 2 pt I ring; active tab 2 pt I underline;
  current transcript line and "now playing" mark I; drop zone T + I; links per §3.3; kind chips; keep ✓ `ok`.
- **Overlays** (`web/apps/overlays`, Windows / Linux island and picker): exactly §3.1–3.2, island values; the voice
  card face is light, so its mark uses `--brand-ink-light`.
- **Tauri app** (`web/apps/desktop`): primary **B**; selection, badges, chips **T** + **I**; the sidebar's jobs box
  carries `.ai-glow` while a process job runs; the empty inbox shows the mascot on a 112 px `.g-field` tile.

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
- Yellow is no longer a brand colour. It remains only as `kind.idea` and in illustrations (the egg).
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
- the spectrum on everyday UI (it is for the hero, AI working and celebrations only).

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
| Countdown | `rec` ring | The ring drains each second; at 0 the selection stroke cross-fades G → `rec` in 200 ms. |
| Recording | `rec` frame and dot | The island dot breathes (1.6 s); the frame is still. |
| Paused | `attn` dashed | No motion: stillness is the signal. |
| Snap | white shutter / M ring + glow | 320 / 450 ms, once |
| Card hung | M clasp | The card swings in on the spring; the clasp does not animate. |
| blurt working | I spinner arc, M dot | Quarter arc, 1.1 s per turn |
| Done | `ok` + ✓ | The check draws once (200 ms); the chick hops. The colour never pulses. |
| Needs you | `attn` | One pulse when it appears, then still. |
| Primary button | B | Brightness 1.04 on hover (120 ms). The gradient never animates or shifts. |
| AI working | S rim | The spectrum turns once per 3.2 s while the job runs; still with Reduce Motion; none with Reduce Transparency. |
| Something big finished | S bloom | A spectrum ring grows 12 % and fades over 0.9 s, once. None with Reduce Motion or Transparency. |

Rules: at most one brand-coloured thing moves at a time on a screen; the core gradient never moves (no animated
gradient angles, no shimmer); only the spectrum rim turns, and only while AI works; the listening glow only while
listening or capturing; nothing in brand colour blinks for an error.

Accessibility fallbacks, everywhere: **Reduce Transparency** → flat colours: no grain, no listening glow, no AI rim,
no bloom, no hero glow (`reduceTransparency`, `prefers-reduced-transparency`). **Increase Contrast** → the `hc`
values (deeper ink, stronger tint) and flat ink instead of gradient text (`BrandColor.increaseContrast`,
`prefers-contrast: more`). **Reduce Motion** → no marching dashes, no glow breathing, the rim stands still, no bloom.
Test builds force them with `BLURT_REDUCE_TRANSPARENCY=1`, `BLURT_INCREASE_CONTRAST=1`, `BLURT_REDUCE_MOTION=1`.

## 5. Gradient recipes

### 5.1 AppKit / Core Animation (shipped)

| Surface | How | Where |
|---|---|---|
| Primary buttons | `BrandButton` (AppKit, layer-backed, `gradient.button` + white title) / `.buttonStyle(.brand)` (SwiftUI) | `Icons/BrandViews.swift` |
| Picker Snap / Record, island buttons | `PillButton(gradient:fg:dot:)`, `IslandButton(gradient:fg:)`: the gradient drawn clipped to the pill | `Capture/Picker.swift`, `Capture/Island/IslandContent.swift` |
| Capture stroke, level bars | `BrandGradient.layer(linearStops, .diagonal / .vertical)` **masked** by a `CAShapeLayer` (the dashed rect / the bars path) | `SelectionOutline` (Picker), `Ears`, `Bars` |
| Gradient text | `GradientLabel` (AppKit: glyphs as a mask) / `.brandGradientText()` (SwiftUI `foregroundStyle`) | `BrandViews.swift` |
| Field art, onboarding hero | `FieldView` / `BrandField`: `BrandGradient.drawField` (`CGContext.drawRadialGradient` per layer) + `drawGrain` (a generated 256 px value-noise tile, overlay, one noise pixel per device pixel) | `BrandViews.swift`, `BrandColor.swift` |
| Listening glow | `GlowLayer.make`: the base gradient, blurred once with Core Image, cached as a layer image; `GlowLayer.fade` | `Island.swift` |
| AI working | `AIGlowView` (two conic `CAGradientLayer`s masked by the rounded-rect stroke, the soft one blurred, rotating) / `.aiGlow(active)` | `BrandViews.swift` |
| Celebration | `Celebration.play(in:around:)` / `.celebrate(on:)` | `BrandViews.swift`, `App/BrandMoments.swift` |

`BrandColor.swift` is generated: `BrandColor.*` (dynamic light / dark / Increase Contrast `NSColor`s, all sRGB),
`BrandColor.Island.*`, `BrandColor.Kind.palette`, and `BrandGradient` (stops, `layer(_:_:flipped:into:)`, `linear()`,
`button()`, `spectrum()`, `draw(...)`, `drawField`, `grainTile`, `drawGrain`, glow / wash / grain constants). Edit
`assets/color/tokens.json`, never this file.

### 5.2 CSS (shipped)

The generated block in `web/packages/ui/src/tokens.css` (between the `@generated colour` markers) defines, per theme:
`--brand`, `--brand-ink`, `--brand-tint`, `--brand-glow`, `--on-brand`, `--on-brand-ink`, `--brand-accent`, `--rec`,
`--attn`, `--attn-ink`, `--on-attn`, `--ok`, `--on-ok`, `--err`, `--info`, `--markup`, `--kind-*`, `--g-green / -mint /
-blue`, `--brand-gradient` (diagonal), `--brand-gradient-v`, `--brand-gradient-h`, `--brand-button`,
`--on-brand-button`, `--brand-text`, `--brand-spectrum`, `--brand-spectrum-stops`, `--brand-spectrum-conic`,
`--brand-field` (deep in dark), `--grain`, `--grain-opacity`, `--brand-wash`, `--glow-opacity`, `--ai-glow-opacity`,
and `accent-color: var(--brand-accent)`. `prefers-contrast: more` swaps in the `hc` ink / tint and sets
`--brand-text: none`; `prefers-reduced-transparency: reduce` sets `--grain: none` and the glow opacities to 0. The
overlays' `theme.css` gets the island values (+ `--brand-ink-light` for the light voice-card face).

Utilities in `web/packages/ui/src/base.css`: `.btn.primary` (button gradient, white 600 text, highlight, shadow, hover
1.04, active 0.92, neutral disabled), `.g-text` (gradient text, flat `--ink` under `prefers-contrast` / forced
colours), `.g-field` (field + grain `::after`), `.ai-glow` (`conic-gradient(from var(--spin),
var(--brand-spectrum-stops))` rim, `@property --spin` over 3.2 s; static with reduced motion) and `.ai-glow.once` (the
celebration). The old `--accent*`, `--keep*`, `--amber*`, `--warn`, `--sev-*` remain as unused aliases for one release.

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
| Countdown | 64 bold | — |
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
| Gradient text for large headlines and hero numbers (≥ 20 pt), the deeper variant on light | Gradient text for body, labels or anything small; gradient text under Increase Contrast |
| Native switches, checkboxes and focus in the brand accent (`AccentColor`) | Custom-drawn gradient switches; `controlAccentColor` where you mean "brand" |
| The field for art and heroes, with grain | The gradient as a window, sidebar or panel background |
| Thin things flat: rings, underlines, badges, clasps, progress | Gradient rings, icons or progress bars |
| The spectrum for the hero, AI working and the completion bloom | The spectrum on everyday UI, or as a resting decoration |
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
6. **New surfaces**: onboarding hero, empty-state art, live-text rule.
7. **Site**: no migration now; §3.8 says how the redo uses the system.
8. Everything else (semantic, kinds, neutrals, rules) is as in v1.
9. **Amendments** (before shipping): white text on a deeper `gradient.button`; gradient text for large headlines;
   native controls in `brand.accent` via `AccentColor`; the multi-hue spectrum for special moments.

## 11. Single source of truth (shipped)

```
assets/color/tokens.json       the values: brand (+ accent), semantic, kind, neutral (reference), checks, gradient
                               (stops, linear, button, text, spectrum, field, deep, grain, wash, glow, aiGlow)
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
the brand hue. It reads `Assets.car` back with `assetutil` and compares the AccentColor. `tests/test_icons.py` runs it
and fails on hard-coded brand colours in the app (`calibratedRed`, `controlAccentColor`, `.accentColor`, the old
`accent` / `amber` globals). `web/packages/ui/src/tokens.test.ts` reads the floors from the same file.

### 11.1 The token table (as shipped; `build.py --table`)

| Token | Light | on `#FFF / #F6F6F6 / #ECECEC` | Dark | on `#1E1E1E / #2A2A2A / #323232` | Island |
|---|---|---|---|---|---|
| `brand.fill` | `#61DBBD` | 1.70 / 1.57 / 1.44 (fill only) | `#61DBBD` | 9.82 / 8.46 / 7.56 | `#61DBBD` |
| `brand.ink` | `#0B735E` | 5.79 / 5.36 / 4.90 | `#61DBBD` | 9.82 / 8.46 / 7.56 | `#61DBBD` |
| `brand.tint` | `#61DBBD` 18 % | wash; ink on it ≥ 4.5 | `#61DBBD` 16 % | wash | `#61DBBD` 20 % |
| `brand.glow` | `#61DBBD` 35 % | halo | same | halo | same |
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
| `kind.issue` | `#D9432A` | 4.39 / 4.06 / 3.71 | `#FF7A5C` | 6.50 / 5.60 / 5.00 | — |
| `kind.idea` | `#A8710A` | 4.17 / 3.86 / 3.53 | `#FFC53D` | 10.56 / 9.09 / 8.12 | — |
| `kind.note` | `#3E63DD` | 5.21 / 4.82 / 4.41 | `#8DA4EF` | 6.90 / 5.94 / 5.30 | — |
| `kind.task` | `#7650D8` | 5.37 / 4.97 / 4.55 | `#A994F5` | 6.54 / 5.63 / 5.03 | — |

| Gradient | Stops | Contrast |
|---|---|---|
| `linear` (base) | `#66D97A` 0 → `#61DBBD` .45 → `#4AABE2` 1 | `brand.on` ≥ 6.31 at every point |
| `button` | `#028932` 0 → `#02866F` .45 → `#087EB3` 1 | **white ≥ 4.51** at every point; ≥ 4.22 at hover ×1.04 |
| `text` light | `#14983C` 0 → `#07957C` .45 → `#248CC2` 1 | ≥ 3.17 on every light surface (large text) |
| `text` dark | the base stops | ≥ 5.02 on every dark surface |
| `deep` | `#4ABF61` / `#43C1A4` / `#2C92C8` (+ layers) | `brand.on` ≥ 4.65 |
| `spectrum` | `#FFD54F` 0 → green .24 → mint .46 → azure .70 → `#9D7BF7` 1 | decoration only, never under text |

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
| `MainWindow/ItemListController.swift:180,184,221` banners `controlAccentColor` | captures banner | `BrandColor.ink` |
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

