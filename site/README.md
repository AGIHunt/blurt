# blurt.work

The project homepage: static files, no build step. `index.html` is Chinese, `en/index.html` English; both share
`style.css` and `main.js`. The two pages have the same sections in the same order; change copy in both.

```bash
python3 -m http.server 4173 --directory site      # preview at http://localhost:4173 (no Range: steps won't seek)
npx wrangler pages deploy site --project-name blurt --branch main      # publish (Cloudflare Pages)
```

The production domain is `blurt.work`, bound to the existing Pages project `blurt`
(`blurt-bvn.pages.dev`). Its Cloudflare nameservers are `athena.ns.cloudflare.com` and
`kai.ns.cloudflare.com`; the domain registration remains at Alibaba Cloud.

The `agihunt.info` zone has a Single Redirect named **Blurt official site to blurt.work**:
match `(http.host eq "blurt.agihunt.info")`, redirect with
`concat("https://blurt.work", http.request.uri.path)`, status **301**, and preserve the query string.
Keep the old DNS record and Pages binding so old links and install commands keep working.

If a stale global API key overrides Wrangler OAuth, run the deployment command with
`env -u CF_API_KEY -u CLOUDFLARE_API_KEY` prefixed. Use the account
`2f0c4283882da012b8a3283dcee20cc7`.

**When `style.css`, a font or an asset changes, bump `?v=`** (`V` in the generator: both pages' `<link>`, font and
image preloads, `<video>`/`poster`, og images; by hand: the `url()`s in `style.css`). `_headers` lets browsers keep
`style.css`, `fonts/` and `assets/` for a year without asking (immutable), so a file changed under the same `?v=`
never reaches a returning visitor. The pages themselves always revalidate. Current: `?v=1.0.6-2`.

**The first paint.** `peep.js` and `main.js` are inlined at the end of each page (the generator reads them from this
folder), and the `<head>` script sets `motion` before anything renders. The scripts then run before the first paint
(they wait for `style.css`, as the paint does), so the first frame is already the notch, the first scene's step and
its window position. With deferred files the browser painted the no-script layout first (a second notch on the
desktop, the window lower) and jumped a round trip later. After editing either script, rebuild the pages. The
first scene's wallpaper is fetched at high priority, the others lazily; wallpapers are WebP (the JPEGs stay for the
og cards). The serif is `font-display: block` (the title appears once, in its own face), and the nav's star count
is baked in at build time (main.js refreshes it), so the header never changes width.

The pages are generated (`blurt-media/site/src/build_pages9.py`, outside the repo; its `LOCKED_COPY` block holds the title, lede, button and every section headline); if you hand-edit one page, make the
same change in the other.

## Type

Display: Noto Serif SC 700/900 (self-hosted subsets, `fonts/serif-*.woff2`). Measured figures, commands and paths:
IBM Plex Mono 500 (`fonts/mono-500.woff2`). Everything else is the system font, the app's own. After changing copy,
rebuild the subsets so new characters don't fall back: `python3 site/fonts/build.py <dir>` (its docstring lists the
full fonts it expects).

## Colour

Tokens on `:root` from `assets/color/tokens.json` (docs/design/system.md), dark values under
`prefers-color-scheme: dark`. Mint is the "live" colour: the caret, the listening level, Blurt's bar in the speed
chart. Buttons (download, copy, the film's play button) use the button gradient (`gradient.button` in tokens.json,
white text), lifted off the wallpaper by a white halo, a thin dark rim and a deep tinted shadow, with a sheen
on hover; no other gradient on the page. Text set straight on the wallpaper uses
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
  speed (a time axis with a moving now-line), the five-app matrix, lists (Shift / ⌥L), snap → card under the notch →
  dragged into Claude, record → 52 items → OR-21, hand-off (night) → the team bundle, privacy, the film, install.
- **Desk units**: inside `.lay`, 1em = 1% of the desk width (container query units), so a scene scales as one picture.
  On phones `.view` is a camera over the same coordinates (`--cx`, `--cy` per scene and step) and the copy sits on a
  paper sheet at the bottom; desktop coordinates in `style.css` are shared by both.
- **Primary action**: *Download for Mac* in the hero and the install section, pointing at
  `https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg`. `scripts/release-mac.sh` writes the disk image
  twice, `Blurt-$VERSION.dmg` and `Blurt.dmg`: attach both to every release. **The link works only once the v1.0.0
  release is published.**
- **Film**: the v1 film (1:42) with its poster (`assets/poster-v1.jpg`, the title card: Peep in the notch) and chapter
  links that open the film at that time. Chapter times are the beat starts in `blurt-media/film/v3/src/timeline.json`,
  rounded up to 0.1 s; `python3 build_pages9.py film` re-encodes the web copy and rewrites them.
- **Speed**: talk for a minute, stop, until it's done: Blurt 0.39 s (own test, median of 3 takes) next to Wispr Flow about 1.5 s and Typeless about 3.0 s (VoiceDash, a competing
  vendor, linked); Blurt's CER 2.7% and WER 1.9% sit under the matrix, the other figures and the method in a disclosure.
- **Install**: the download button, the agent path (`curl -fsSL https://blurt.work/install.sh | sh`, copy
  button; `install.sh` is served from this folder), six keys as keycaps,
  and a link to the user guide for every other key; then the specs (system, models, languages, words, history,
  permissions, other dictation apps, source).
- Headlines: phrases are no-break spans (`|` in the generator) on desktop; on phones they wrap normally.

## Assets

- `assets/promo.mp4`: the v1 film, one file for both pages (English voice-over, Chinese and English subtitles), H.264
  1080p with faststart, about 9 MB, loaded on click; `assets/film.json` records its length and poster. The v0.9
  poster `assets/poster-6.jpg` is no longer on the page.
- `assets/wall/light.webp`, `dark.webp` (+ `-m` crops for phones; WebP q80 of the `.jpg` masters, about 45 KB): the desktop wallpaper, morning fog and dusk, made with
  an image model for this page (`blurt-media/site/gen6/`).
- `assets/rec-frame.jpg`: the frame on the OR-21 item, also used for the recording's film strip and the attachment
  thumbnail.
- `assets/og.png`, `assets/og-en.png`: social cards, 1200×630, from `build_pages9.py import` (`og_cards()`): the
  wallpaper, the notch with Peep, the title and lede, the clay three-quarter Peep.
- `assets/peep/`: Peep, the mascot (round 9), all from the brand-book model (`blurt-media/logo/peep/`), copied and
  cut by `python3 build_pages9.py import` (it takes `logo/peep/release/web/` once its MANIFEST says COMPLETE):
  `n-<state>.webp` the notch sheets (dark set: idle, listening, talking, thinking, done, hello), `n-look.webp` the
  notch's 7 × 5 gaze grid, `f-<state>.webp` Peep out of the notch in the snap (done, peck), `peek.webp` the
  footer (three-quarter, 7 turns × 5 pitches × eyes open/shut, head top only; peep.js eases the gaze with a spring
  and cross-fades the four poses around it, the body leans and sways a little; on phones it looks where you tap and
  follows a finger dragged across the page, with passive listeners so the page still scrolls), `fd-<state>.webp` the same on dark pages
  (dark set), `n-still.webp` one still per scene for reduced motion; the hero: Peep perched on the first window's
  top-right corner, facing the window, no contact shadow: `perch.webm` / `perch.mov` / `perch.webp` (light pages,
  `out/anim/paper-ns/idle`) and `perch-d.*` (dark pages, `out/anim/dark/idle` with the shadow taken out), side view
  flipped to face left, VP9 and HEVC with alpha, the WebP is the first frame (poster, reduced motion). On desktop it
  drifts a little with the scroll (`--sy0`); on phones it sits at the screen's right edge over the first window, smaller; `logo.svg` /
  `logo-dark.svg` the header mark (3D vector), favicons. `peep.json` is the sheet table, inlined into each page.
  `peep.js` plays them (sprite sheets at 30 fps, lazy-loaded per state); `main.js` tells it the scene and step.
  Until a sheet arrives the notch shows `n-still.webp` (preloaded), so its ear is never empty.
  `assets/favicon.png` and `assets/apple-touch-icon.png` keep their names and now hold Peep; `/favicon.ico` too.
- `assets/loops/`, `assets/team.jpg`: round-5 media, no longer on the page (kept for now; delete when you commit if you
  don't want them deployed).

## Install path

The primary action is the DMG download (above). The second path, for agents, is `install.sh` (this folder): the agent
(or the user, in a terminal) runs `curl -fsSL https://blurt.work/install.sh | sh`, which installs the same DMG's
app and opens it. The app brings its own skill (`~/.blurt/skill`), so neither path needs `npx skills add`; that stays in
the repo README for using the skill without the app.

## Copy

Say how things work and how long they take now, with measured numbers and their sources (docs/positioning/facts.md).
Competitor numbers are labelled with who measured them. No version history, no before/after.

`llms.txt` is the fact sheet for AI agents (linked from both pages' `<head>` and footer). Only put in it what the
README or the design docs back up, and update it with the pages.
