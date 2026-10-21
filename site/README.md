# blurt.agihunt.info

The project homepage: static files, no build step. `index.html` is Chinese, `en/index.html` English; both share
`style.css` and `main.js`. Change copy in both pages.

```bash
python3 -m http.server 4173 --directory site      # preview at http://localhost:4173
npx wrangler pages deploy site --project-name blurt --branch main      # publish (Cloudflare Pages)
```

**When `style.css`, `main.js` or a font changes, bump `?v=`** (both pages' `<link>`/`<script>`/font preload, and the
`url()`s at the top of `style.css`). The agihunt.info zone's Browser Cache TTL (4 h) overrides `_headers` on the custom
domain, so without a new URL visitors get new HTML on top of the old CSS. `_headers` (revalidate every visit) does
apply on `*.pages.dev`.

Fonts are self-hosted subsets (Noto Serif SC, LXGW WenKai, IBM Plex Mono; all OFL). After changing copy, rebuild them
from the full fonts so new characters don't fall back: `python3 site/fonts/build.py <dir>` (the docstring lists the
files it expects).

`assets/promo.mp4` is a 1280-wide re-encode of `../assets/blurt-promo.mp4`, `assets/poster.jpg` its title card at
0:31; `assets/media/chicken.*` is a Veo-generated loop keyed to alpha (`.mov` HEVC for Safari, `.webm` VP9 elsewhere);
`assets/og.png` is the social card; `assets/perch*.jpg` are crops of the real app's perch (below the menu bar, so no
personal menu-bar icons), light and dark.

The snap-mode section is a playable demo with no assets: the "screenshot" is a scaled DOM clone of the mock billing
app (sized in `em`, so a clone renders the same at any size), the eggs, chicken-foot clip and nest are the SVG sprite
at the top of each page (same shapes as `skills/blurt/scripts/review.html`). Strings in the `@fonts:system-ui` blocks
of `main.js` render in the system font, so `fonts/build.py` leaves them out of the subsets.

`llms.txt` is the fact sheet for AI agents (linked from both pages' `<head>` and footer). Only put in it what the
README or the design docs back up, and update it with the pages.
The page grew out of a blurt recording: six reference sites, things circled with the pen, then a requirements and a
design doc written by the agent.
