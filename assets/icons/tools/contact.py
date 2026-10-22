"""Contact sheet: every icon at 16 / 24 / 48 px (rendered at 2×, as on a Retina screen) on light and dark. Dev tool — needs rsvg-convert and Pillow:

    uv run -q --with pillow python assets/icons/tools/contact.py OUT.png [--scale 2] [--only a,b] [--big 160]

--big N renders just the selected icons at N px (for checking geometry up close, with the 24-grid keylines).
"""
from __future__ import annotations

import argparse
import io
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
import iconlib  # noqa: E402

LIGHT = ("#ffffff", "#1d1d1f", "#86868b")
DARK = ("#1e1e1e", "#f2f2f2", "#8e8e93")


def render(svg: str, px: int) -> Image.Image:
    png = subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), "-f", "png"], input=svg.encode(),
                         capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def font(sz):
    for f in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(f, sz)
        except OSError:
            pass
    return ImageFont.load_default()


def sheet(icons, out: Path, scale: int):
    sizes = (16, 24, 48)
    cell_w, cell_h = 150 * scale, 92 * scale
    cols = 6
    rows = (len(icons) + cols - 1) // cols
    W, H = cols * cell_w, rows * cell_h + 40 * scale
    halves = []
    for bg, fg, sub in (LIGHT, DARK):
        im = Image.new("RGBA", (W, H), bg)
        d = ImageDraw.Draw(im)
        f = font(11 * scale)
        d.text((12 * scale, 12 * scale), f"blurt icons — {len(icons)} glyphs, 24 grid, 1.75 stroke · 16 / 24 / 48 px @{scale}x",
               fill=sub, font=font(13 * scale))
        for i, ic in enumerate(icons):
            cx, cy = (i % cols) * cell_w, (i // cols) * cell_h + 40 * scale
            x = cx + 12 * scale
            for s in sizes:
                g = render(iconlib.normalized_svg(ic, fg), s * scale)
                im.alpha_composite(g, (x, cy + (56 - s) * scale))
                x += (s + 12) * scale
            d.text((cx + 12 * scale, cy + 62 * scale), ic.name, fill=fg, font=f)
            d.text((cx + 12 * scale, cy + 76 * scale), ic.group, fill=sub, font=font(9 * scale))
        halves.append(im)
    full = Image.new("RGBA", (W * 2, H))
    full.paste(halves[0], (0, 0))
    full.paste(halves[1], (W, 0))
    full.save(out)
    print(out)


def big(icons, out: Path, px: int):
    cols = min(len(icons), 6)
    rows = (len(icons) + cols - 1) // cols
    pad = 24
    W, H = cols * (px + pad) + pad, rows * (px + pad + 20) + pad
    im = Image.new("RGBA", (W * 2, H), "#ffffff")
    d = ImageDraw.Draw(im)
    for half, (bg, fg, sub) in enumerate((LIGHT, DARK)):
        d.rectangle((half * W, 0, half * W + W, H), fill=bg)
        for i, ic in enumerate(icons):
            x = half * W + pad + (i % cols) * (px + pad)
            y = pad + (i // cols) * (px + pad + 20)
            if half == 0:   # keylines: 24 grid, safe area 2…22, centre lines
                u = px / 24
                for k in range(25):
                    c = "#eef2f7" if k % 2 else "#e2e8f0"
                    d.line((x + k * u, y, x + k * u, y + px), fill=c)
                    d.line((x, y + k * u, x + px, y + k * u), fill=c)
                d.rectangle((x + 2 * u, y + 2 * u, x + 22 * u, y + 22 * u), outline="#bcd3f5")
            im.alpha_composite(render(iconlib.normalized_svg(ic, fg), px), (int(x), int(y)))
            d.text((x, y + px + 3), ic.name, fill=sub, font=font(12))
    im.save(out)
    print(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--only")
    ap.add_argument("--big", type=int)
    a = ap.parse_args()
    icons = iconlib.load_all()
    if a.only:
        want = a.only.split(",")
        icons = [i for i in icons if i.name in want or any(w.endswith("*") and i.name.startswith(w[:-1]) for w in want)]
    for ic in icons:
        for e in iconlib.lint(ic):
            print("lint:", e, file=sys.stderr)
    if a.big:
        big(icons, a.out, a.big)
    else:
        icons.sort(key=lambda i: (i.group != "brand", i.name))
        sheet(icons, a.out, a.scale)


if __name__ == "__main__":
    main()
