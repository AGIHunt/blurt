# blurt.agihunt.info

The project homepage: static files, no build step. `index.html` is Chinese, `en/index.html` English; both share
`style.css` and `main.js`. The two pages have the same sections in the same order; change copy in both.

```bash
python3 -m http.server 4173 --directory site      # preview at http://localhost:4173 (no Range: steps won't seek)
npx wrangler pages deploy site --project-name blurt --branch main      # publish (Cloudflare Pages)
```

**When `style.css`, `main.js`, a font or an asset changes, bump `?v=`** (both pages' `<link>`, `<script>`, font
preloads, `<video>`/`poster`, og images, and the `url()`s at the top of `style.css`). The agihunt.info zone's Browser
Cache TTL (4 h) overrides `_headers` on the custom domain, so without a new URL visitors get new HTML on top of old
CSS. `_headers` (revalidate every visit) does apply on `*.pages.dev`. Current: `?v=0.9.0-8`.

The pages are generated (`blurt-media/site/src/build_pages7.py`, outside the repo; its `LOCKED_COPY` block holds the title, lede, button and every section headline); if you hand-edit one page, make the
same change in the other.

## Type

Display: Noto Serif SC 700/900 (self-hosted subsets, `fonts/serif-*.woff2`). Measured figures, commands and paths:
IBM Plex Mono 500 (`fonts/mono-500.woff2`). Everything else is the system font, the app's own. After changing copy,
rebuild the subsets so new characters don't fall back: `python3 site/fonts/build.py <dir>` (its docstring lists the
full fonts it expects).

## Colour

Tokens on `:root` from `assets/color/tokens.json` (docs/design/system.md), dark values under
`prefers-color-scheme: dark`. Mint is the "live" colour: the caret, the listening level, Blurt's bar in the speed
chart, the download button (flat `--mint-ink`; no gradient on the page). Text set straight on the wallpaper uses
`--over` / `--over-2`. The hand-off scene and the privacy band are night (`#12171A`) in both modes.

## The page: your Mac, the notch, and the day passing

- **The notch** (`#isl`) is fixed at the top centre of the viewport. It is hidden off-stage and drops in when a desktop
  scene is pinned; each scene sets its mode (`listen`, `list`, `done`, `rec`, `verify`, `hello`) and the live text
  that grows out of it. Without JS and under reduced motion each stage draws its own static notch (`.snotch`).
- **Scenes** (`section.sc[data-scene]`): a tall section with a sticky 100vh stage in three depths: the wallpaper
  (`assets/wall/`, generated for round 6, slowest), the windows (`.view`), and the copy with keycaps in front. `main.js`
  maps scroll progress to steps (`data-steps` thresholds → cumulative classes `on1…onN`) plus scrubbed values (words,
  the speed clock, the recording timer and transcript, the item count) and the parallax variables `--p`, `--d`, `--sy0`.
  The HTML ships with every step on, so no-JS, reduced motion and the font subsetter all see each scene's end state
  with every caption listed. Order: hero over the dictation desktop (the hero scrolls away while the desktop holds),
  speed (a time axis with a moving now-line), the five-app matrix, lists (Shift / ⌥⇧L), snap → card under the notch →
  dragged into Claude, record → 52 items → OR-21, hand-off (night) → the team bundle, privacy, the film, install.
- **Desk units**: inside `.lay`, 1em = 1% of the desk width (container query units), so a scene scales as one picture.
  On phones `.view` is a camera over the same coordinates (`--cx`, `--cy` per scene and step) and the copy sits on a
  paper sheet at the bottom; desktop coordinates in `style.css` are shared by both.
- **Primary action**: *Download for Mac* in the hero and the install section, pointing at
  `https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg`. `scripts/release-mac.sh` writes the disk image
  twice, `Blurt-$VERSION.dmg` and `Blurt.dmg`: attach both to every release. **The link works only once the v0.9.0
  release is published.**
- **Film**: the poster (`assets/poster-6.jpg`, a frame at 1:19: the two cards under the notch) and chapter links that
  open the film at that time. Chapter times are scene starts from `blurt-media/film/say2/timeline.json`, rounded up to
  0.1 s. The round-5 title-card poster is still `assets/poster.jpg` if you prefer it (one line in the generator).
- **Speed**: talk for a minute, stop, until it's done: Blurt 0.39 s (own test, median of 3 takes) next to Wispr Flow about 1.5 s and Typeless about 3.0 s (VoiceDash, a competing
  vendor, linked); Blurt's CER 2.7% and WER 1.9% sit under the matrix, the other figures and the method in a disclosure.
- **Install**: the download button, the agent path (`npx skills add AGIHunt/blurt`, copy button), six keys as keycaps,
  and a link to the user guide for every other key; then the specs (system, models, languages, words, history,
  permissions, other dictation apps, source).
- Headlines: phrases are no-break spans (`|` in the generator) on desktop; on phones they wrap normally.

## Assets

- `assets/promo.mp4`: the v0.9 film, one file for both pages (English voice-over, Chinese and English subtitles),
  loaded on click. `assets/poster-6.jpg`: its poster (see above).
- `assets/wall/light.jpg`, `dark.jpg` (+ `-m` crops for phones): the desktop wallpaper, morning fog and dusk, made with
  an image model for this page (`blurt-media/site/gen6/`).
- `assets/rec-frame.jpg`: the frame on the OR-21 item, also used for the recording's film strip and the attachment
  thumbnail.
- `assets/og.png`, `assets/og-en.png`: social cards, 1200×630, from `blurt-media/site/og/make_og6.py`: the fog desktop,
  the notch with live text, the title.
- `assets/logo.svg`: the 4A line chick; `favicon.png`, `apple-touch-icon.png`, `logo.png` come from
  `../assets/brand/build.py`. The colour chick is inline SVG.
- `assets/loops/`, `assets/team.jpg`: round-5 media, no longer on the page (kept for now; delete when you commit if you
  don't want them deployed).

## Install path

The primary action is the DMG download (above). The second path, for agents, is `npx skills add AGIHunt/blurt` (copy
button), then "start blurt" to the agent, as in the repo README.

## Copy

Say how things work and how long they take now, with measured numbers and their sources (docs/positioning/facts.md).
Competitor numbers are labelled with who measured them. No version history, no before/after.

`llms.txt` is the fact sheet for AI agents (linked from both pages' `<head>` and footer). Only put in it what the
README or the design docs back up, and update it with the pages.
