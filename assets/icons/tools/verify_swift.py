"""Checks that the Swift icons (BlurtIcon.swift + the generated BlurtIconPaths.swift) draw the same pixels as the SVGs.

Compiles BlurtIcon*.swift with a tiny offscreen driver (tools/swiftcheck/), renders every icon at
48 pt @2x in light and dark appearance, renders the normalized SVGs with rsvg-convert, and writes a side-by-side sheet
plus a per-icon mismatch score. Dev tool (macOS, swiftc, rsvg-convert, Pillow):

    uv run -q --with pillow python assets/icons/tools/verify_swift.py OUT_DIR
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import contact  # noqa: E402
import iconlib  # noqa: E402

HERE = Path(__file__).parent
SRC = iconlib.REPO / "skills/blurt/recorder/macos/Sources/BlurtApp"


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    exe = out / "render"
    subprocess.run(["swiftc", "-O", "-o", str(exe), str(SRC / "Icons/BlurtIcon.swift"), str(SRC / "Icons/BlurtIconPaths.swift"),
                    str(HERE / "swiftcheck/stub.swift"), str(HERE / "swiftcheck/main.swift")],
                   check=True)
    pngs = out / "swift"
    subprocess.run([str(exe), str(pngs)], check=True)
    icons = iconlib.load_all()
    px, pad = 96, 12
    cols = 8
    rows = (len(icons) + cols - 1) // cols
    W, H = cols * (px * 2 + pad * 3), rows * (px + pad * 3)
    sheets, worst = [], []
    for app, (bg, _, _), fg in (("aqua", contact.LIGHT, "#000000"), ("darkAqua", contact.DARK, "#ffffff")):
        im = Image.new("RGBA", (W, H), bg)
        d = ImageDraw.Draw(im)
        for i, ic in enumerate(icons):
            x, y = (i % cols) * (px * 2 + pad * 3) + pad, (i // cols) * (px + pad * 3) + pad
            ref = contact.render(iconlib.normalized_svg(ic, fg), px)
            sw = Image.open(pngs / f"{app}-{ic.name}.png").convert("RGBA")
            im.alpha_composite(ref, (x, y))
            im.alpha_composite(sw, (x + px + pad, y))
            diff = ImageChops.difference(ref.getchannel("A"), sw.getchannel("A"))
            score = sum(diff.tobytes()) / (255 * px * px)
            worst.append((score, ic.name, app))
            d.text((x, y + px + 2), f"{ic.name}  svg | swift  Δ{score:.3f}", fill=fg)
        sheets.append(im)
    full = Image.new("RGBA", (W, H * 2))
    full.paste(sheets[0], (0, 0))
    full.paste(sheets[1], (0, H))
    full.save(out / "swift-vs-svg.png")
    worst.sort(reverse=True)
    print("worst alpha mismatch (fraction of the icon area):", ", ".join(f"{n}/{a} {s:.4f}" for s, n, a in worst[:5]))
    print(out / "swift-vs-svg.png")
    bad = [w for w in worst if w[0] > 0.01]
    if bad:
        raise SystemExit(f"{len(bad)} icons differ by more than 1 %")


if __name__ == "__main__":
    main()
