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
CSS. `_headers` (revalidate every visit) does apply on `*.pages.dev`. Current: `?v=0.9.0-5`.

The pages are generated (`blurt-media/site/src/build_pages5.py`, outside the repo); if you hand-edit one page, make the
same change in the other.

## Type

Display: Noto Serif SC 700/900 (self-hosted subsets, `fonts/serif-*.woff2`). Measured figures, commands and paths:
IBM Plex Mono 500 (`fonts/mono-500.woff2`). Everything else is the system font, the app's own. After changing copy,
rebuild the subsets so new characters don't fall back: `python3 site/fonts/build.py <dir>` (its docstring lists the
full fonts it expects).

## Colour

Tokens on `:root` from `assets/color/tokens.json` (docs/design/system.md), dark values under
`prefers-color-scheme: dark`. Mint is the "live" colour: the caret, the listening level, the live-text cursor, the
progress of each loop and its current step, the install button (flat mint). There is no gradient surface on the page;
the gradient is kept for the og cards and the item card's "Hand off" button. The colour chick sits in the hero's
notch; the 4A line chick (stroke, mint sound arcs) heads the record section, and only there. The Snap band has its own
surface in both modes (`--band`: near-black in light, a deep mint-tinted black in dark). Product footage sits in a dark
bezel (`.bezel`) and is dimmed slightly in dark mode (`--media-dim`).

## The page

- **Hero stage** (HTML): the top of a Mac screen, flat paper, the notch at the centre, Claude Code full screen below.
  `main.js` plays one dictation in tap mode at measured timings: tap, a 3-second sentence with live words under the
  notch, then a double tap in place of the second tap: the text is at the cursor 0.29 s later, Return goes, the
  prompt moves into the transcript and Claude Code starts reading. The page rests (no JS, reduced motion, the end of a
  take) on that sent state. The key score under the hero is one time axis (0–4.4 s); the double-tap mark and the end
  of the talk bar sit at 68.2 % (`TALK` / `TOTAL` in `main.js`), the lag bar spans 6.6 % (`PASTE` − `TALK`); keep
  them in step.
- **Primary action**: *Download for Mac*, the one gradient button, in the hero and the install section. It points at
  `https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg`. `scripts/release-mac.sh` writes the disk
  image twice, `Blurt-$VERSION.dmg` and the same file as `Blurt.dmg`: attach both to every release, so the button
  keeps working when a later release becomes latest. **The link works only once the v0.9.0 release is published.**
- **Film**: a compact block, the poster with the play button, and chapter links that open the film at that time.
  Chapter times are the film's scene starts from `blurt-media/film/say2/timeline.json`, rounded up to 0.1 s.
- **Dictation**: the claim as the headline (with an inline `fn` keycap), one take set as type (its words go grey →
  ink once when it scrolls into view and rest all ink), then tap mode as a picture: tap, talk, tap again, or a double
  tap instead of the second tap to stop and send. Hold-to-talk is the last spec item.
- **Structured**: ⇧ as a switch, with the notch drawn twice (Light; Structured with the list mark beside the time),
  then the same speech side by side, Light and Structured (real outputs, unedited).
- **Comparison**: one bar chart (end of speech to text at the cursor: Blurt 0.29 s, own test; Wispr Flow about 1.5 s
  and Typeless about 3.0 s from VoiceDash, a competing vendor, linked), with local vs cloud and free vs Typeless Pro
  beside it. Then the five-product table on wide screens (one block per row on phones). Accuracy is a three-row table;
  the other products' figures and the test conditions sit in a disclosure under it.
- **Snap** (the band) and **Hand-off**: muted loops drawn for the site from the film's own parts, not cut from the film
  (`blurt-media/site/clean/`: `src/site.tsx`, `render4.sh`, then `cut4.py`). The camera never moves: every frame is a
  whole Mac screen with the menu bar end to end and the notch at the centre. Desktop: `{name}-{lang}.mp4`, 1920×1080;
  phones: `{name}-{lang}-m.mp4`, a smaller 1080×1080 screen with larger type, no panning, picked by `<source media>`.
  Snap rests on both cards under the notch; the hand-off on two sessions with OR-21 To verify in the notch.
  Snap has five steps (`<li data-t>`, seconds in the loop, from `SNAP_T`); the hand-off has one caption line that
  changes with the loop (`HAND_T`). `main.js` highlights the current one; Snap's steps seek on click. The pause button
  sits under each loop, never on the footage. Loops play only while on screen and never under reduced motion.
- **Record**: three steps as text, the 52-item walkthrough as the number, and one item at full size (HTML, built
  from the film's OR-21), with the recording frame `assets/rec-frame.jpg` (a still from the same source, 1200×600).
- **Teams**: the hand-off bundle (.zip) or a request to your agent, with `assets/team.jpg` (from the film at 1:55:
  the Export Hand-off Bundle… menu and the Slack window with the zip, cut at their edges and set close together so the
  text reads at page size; `film5.py`).
- **Install**: the download button, then the agent path (the command, copy button), three lines of requirements, the
  six keys to start with, and every key behind a disclosure.
- **Headlines**: phrases are no-break spans (`|` in the generator), so a line only breaks between phrases, in both
  languages; `text-wrap: balance`. No `palt`: zh commas keep their full width. Body copy uses `text-wrap: pretty`, and
  phrases that must not split (本地运行、免费开源) are no-break spans.
- Every part renders its end state with JS off and under reduced motion (videos then show native controls).

The mock world (Orbit, Maya, Leo, items OR-21 to OR-23) is fictional and comes from the film.

## Assets

- `assets/promo.mp4`: the v0.9 film, one file for both pages (English voice-over, Chinese and English subtitles), from
  `blurt-media/film/out/blurt-v09-say-it-v2.mp4` via `blurt-media/site/clean/film5.py`, loaded on click: 1920×1080, H.264 High yuv420p, `-preset veryslow
  -tune animation -crf 26`, AAC 96 kbps, `+faststart`, about 8.6 MB.
  `assets/poster.jpg` (1600×900): the film's title card at 6.05 s, between two subtitle lines.
- `assets/loops/`, `assets/rec-frame.jpg`: see above.
- `assets/og.png`, `assets/og-en.png`: social cards, 1200×630: the notch with live text, the title, the download line
  and the platforms on the dark ground.
- `assets/logo.svg`: the 4A line chick; `favicon.png`, `apple-touch-icon.png`, `logo.png` come from
  `../assets/brand/build.py`. The colour chick is inline SVG (`assets/brand/chick-filled.svg`).

## Install path

The primary action is the DMG download (above). The second path, for agents, is `npx skills add AGIHunt/blurt` (copy
button), then "start blurt" to the agent, as in the repo README.

## Copy

Say how things work and how long they take now, with measured numbers and their sources (docs/positioning/facts.md).
Competitor numbers are labelled with who measured them. No version history, no before/after.

`llms.txt` is the fact sheet for AI agents (linked from both pages' `<head>` and footer). Only put in it what the
README or the design docs back up, and update it with the pages.
