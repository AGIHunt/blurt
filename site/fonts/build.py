#!/usr/bin/env python3
"""Rebuild the self-hosted font subsets after changing copy on either page.

    python3 site/fonts/build.py SRC_DIR

SRC_DIR holds the full fonts (OFL, not kept in the repo):
  NotoSerifSC-700.ttf / -900.ttf   static instances of Noto Serif SC (google/fonts, NotoSerifSC[wght].ttf), made with
                                   fontTools.varLib.instancer.instantiateVariableFont(font, {"wght": 700})
  plexmono-500.woff2               @fontsource/ibm-plex-mono latin (copied as is, already small)

Body text is the system font (the app's own), so only the display serif and the mono for measured figures are subset.

Both pages are opened in headless Chromium; every text node is bucketed by the family and weight it is set in,
so each subset only carries the glyphs that face actually renders. Strings that only appear after a click
(data-* attributes, JS labels) are added from the HTML and main.js,
except the main.js blocks marked @fonts:system-ui-start/-end, which render in the system font.
"""
import functools, http.server, re, shutil, socketserver, sys, threading
from pathlib import Path
from fontTools import subset
from playwright.sync_api import sync_playwright

SITE = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1])
OUT = SITE / "fonts"

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(SITE)))
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}/"

COLLECT = """() => {
  const out = {};
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = walk.nextNode());) {
    const el = n.parentElement; if (!el || !n.textContent.trim()) continue;
    const cs = getComputedStyle(el);
    const fam = cs.fontFamily.split(',')[0].replace(/["']/g, '').trim();
    const key = fam + '|' + cs.fontWeight;
    out[key] = (out[key] || '') + n.textContent;
  }
  return out;
}"""

buckets = {}
with sync_playwright() as p:
    b = p.chromium.launch()
    for page in ("", "en/"):
        for w in (1440, 390):
            pg = b.new_page(viewport={"width": w, "height": 900})
            pg.goto(base + page, wait_until="load")
            pg.wait_for_timeout(400)
            for k, v in pg.evaluate(COLLECT).items():
                buckets[k] = buckets.get(k, "") + v
            pg.close()
    b.close()
srv.shutdown()

# strings that only show up after an interaction
extra = ""
for f in (SITE / "index.html", SITE / "en" / "index.html", SITE / "main.js", SITE / "style.css"):
    t = f.read_text()
    # main.js marks the strings that render in the system UI font (the snap desk, live captions): no need to subset those
    t = re.sub(r"// @fonts:system-ui-start.*?// @fonts:system-ui-end", "", t, flags=re.S)
    extra += "".join(re.findall(r'data-(?:done|saved|note|ph|heard|typed)="([^"]*)"', t))
    extra += "".join(re.findall(r'content: "([^"]*)"', t))
    extra += "".join(re.findall(r'"([^"\n]*[　-鿿][^"\n]*)"', t)) if f.suffix == ".js" else ""
ascii_ = "".join(chr(c) for c in range(0x20, 0x7f)) + "·—–…“”‘’「」『』，。、：；！？（）《》→↓←↑★✓✎−×"

def want(fam, weight):
    s = set(ascii_ + extra)
    for k, v in buckets.items():
        f, w = k.split("|")
        if f == fam and (weight is None or int(w) == weight):
            s |= set(v)
    return "".join(sorted(s))

def build(src, out, text):
    opts = subset.Options(); opts.flavor = "woff2"; opts.layout_features = ["*"]; opts.name_IDs = ["*"]
    font = subset.load_font(str(src), opts)
    sub = subset.Subsetter(opts); sub.populate(text=text); sub.subset(font)
    subset.save_font(font, str(out), opts)
    print(f"{out.name}: {len(set(text))} chars, {out.stat().st_size // 1024} KB")

for w in (700, 900):
    build(SRC / f"NotoSerifSC-{w}.ttf", OUT / f"serif-{w}.woff2", want("Blurt Serif", w))
shutil.copy(SRC / "plexmono-500.woff2", OUT / "mono-500.woff2")
print("families seen:", sorted({k.split('|')[0] for k in buckets}))
