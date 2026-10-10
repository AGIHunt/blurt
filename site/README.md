# blurt.agihunt.info

The project homepage: static files, no build step. `index.html` is Chinese, `en/index.html` English; both share
`style.css` and `main.js`. Change copy in both pages.

```bash
python3 -m http.server 4173 --directory site      # preview at http://localhost:4173
npx wrangler pages deploy site --project-name blurt --branch main      # publish (Cloudflare Pages)
```

`assets/promo.mp4` is a 1280-wide re-encode of `../assets/blurt-promo.mp4`; `assets/og.png` is the social card.
The page grew out of a blurt recording: six reference sites, things circled with the pen, then a requirements and a
design doc written by the agent.
