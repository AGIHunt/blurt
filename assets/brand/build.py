"""Renders every brand bitmap from the vector sources in assets/brand/ (the A hen, v0.8).

    python3 assets/brand/build.py            # write everything below
    python3 assets/brand/build.py --list     # just print the outputs

Sources (hand-editable SVG, 1024 canvas):
  app-icon.svg         the master app icon — 824 px superellipse tile at (100, 100) on the macOS 26 grid, soft shadow,
                       group #hen = the hen (also the logo)
  app-icon-small.svg   the 16 / 32 px slots and the favicon: heavier outline, two shout strokes, no sheen
  glyph.svg            the menu-bar / tray glyph (24 grid, 1.75 stroke) — a copy lives at assets/icons/blurt.svg, which
                       assets/icons/tools/build.py turns into Swift / web / Tk / tray icons

Outputs
  skills/blurt/assets/icon.png            1024 master (record.py make_icns → Blurt.app AppIcon.icns; review page logo)
  skills/blurt/assets/icon-16.png, -32.png the small variant for the icns 16 / 32 px slots
  assets/logo.png                         the hen without the tile, transparent, 1024 (README)
  site/assets/logo.png                    the same at 320 (site header / footer)
  site/assets/favicon.png                 64, small variant, tile cropped
  site/assets/apple-touch-icon.png        180, full-bleed square (iOS masks it)
  site/assets/og.png                      the social card: the left-hand logo slot is repainted with the hen; the text
                                          on the right is left as it is
  apps/desktop/src-tauri/icons/           32x32 / 64x64 / 128x128 / 128x128@2x / icon.png / icon.icns / icon.ico
  crates/blurt-capture/demo/icons/        32x32 / icon.png / icon.ico (the capture demo window)

Needs rsvg-convert (brew install librsvg) and Pillow; icon.icns needs macOS iconutil.
"""
from __future__ import annotations

import io
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ICON = HERE / "app-icon.svg"
SMALL = HERE / "app-icon-small.svg"
SMALL_MAX = 32                      # pixel sizes up to this use app-icon-small.svg


def svg(path: Path) -> str:
    return path.read_text()


def without_tile(src: str, pad: float = 24) -> str:
    """The hen alone: drop the tile, its clip and the art's drop shadow; crop to the hen (square, `pad` around)."""
    out, n1 = re.subn(r'<g id="tile">.*?</g>\n', "", src, flags=re.S)
    out, n2 = re.subn(r' clip-path="url\(#tile-clip\)"', "", out)
    out, n3 = re.subn(r' filter="url\(#art-shadow\)"', "", out)
    assert n1 == n2 == n3 == 1, "app-icon.svg no longer has the #tile / #art structure build.py expects"
    x0, y0, x1, y1 = hen_bbox(src)
    side = max(x1 - x0, y1 - y0) + 2 * pad
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    vb = f"{cx - side / 2:.1f} {cy - side / 2:.1f} {side:.1f} {side:.1f}"
    return re.sub(r'viewBox="[^"]*"', f'viewBox="{vb}"', out, count=1)


def hen_bbox(src: str):
    """Bounding box of the hen's outline path (#hen-ink) plus the shout strokes (absolute M/L/C/A coordinates)."""
    hen = src[src.index('<g id="hen">'):]
    nums = []
    for d in re.findall(r' d="([^"]+)"', hen):
        for cmd, args in re.findall(r"([MLCZA])([^MLCZA]*)", d):
            v = [float(x) for x in re.findall(r"-?\d+\.?\d*", args)]
            if cmd == "A":               # rx ry rot large sweep x y: only the end point
                v = [p for i in range(0, len(v), 7) for p in v[i + 5:i + 7]]
            nums += list(zip(v[0::2], v[1::2]))
    xs, ys = [p[0] for p in nums], [p[1] for p in nums]
    return min(xs) - 20, min(ys), max(xs) + 20, max(ys)    # shouts: + their round end caps


def crop(src: str, vb: str) -> str:
    return re.sub(r'viewBox="[^"]*"', f'viewBox="{vb}"', src, count=1)


def full_bleed(src: str) -> str:
    """Square, no transparency (apple-touch-icon): the tile's gradient fills the whole 824 square, no shadow / rim."""
    out = re.sub(r'<g id="tile">.*?</g>\n', '<rect x="100" y="100" width="824" height="824" fill="url(#tile-bg)"/>\n'
                 '<rect x="100" y="100" width="824" height="824" fill="url(#tile-sheen)"/>\n', src, flags=re.S)
    out = out.replace(' clip-path="url(#tile-clip)"', "")
    return crop(out, "100 100 824 824")


def render(src: str, px: int, w: int | None = None) -> bytes:
    if not shutil.which("rsvg-convert"):
        sys.exit("rsvg-convert not found (brew install librsvg)")
    return subprocess.run(["rsvg-convert", "-w", str(w or px), "-h", str(px), "-f", "png"], input=src.encode(),
                          capture_output=True, check=True).stdout


def icon_png(px: int) -> bytes:
    return render(svg(SMALL if px <= SMALL_MAX else ICON), px)


def put(rel: str, data: bytes):
    p = REPO / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    print("wrote", rel)


def ico(sizes) -> bytes:
    from PIL import Image
    imgs = [Image.open(io.BytesIO(icon_png(s))).convert("RGBA") for s in sizes]
    buf = io.BytesIO()
    imgs[-1].save(buf, format="ICO", sizes=[(s, s) for s in sizes], append_images=imgs[:-1])
    return buf.getvalue()


def icns() -> bytes | None:
    if not shutil.which("iconutil"):
        print("iconutil not found (macOS only): icon.icns not written", file=sys.stderr)
        return None
    with tempfile.TemporaryDirectory() as t:
        iconset = Path(t) / "AppIcon.iconset"
        iconset.mkdir()
        for s in (16, 32, 128, 256, 512):
            (iconset / f"icon_{s}x{s}.png").write_bytes(icon_png(s))
            (iconset / f"icon_{s}x{s}@2x.png").write_bytes(icon_png(s * 2))
        out = Path(t) / "icon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
        return out.read_bytes()


def og() -> bytes:
    """The social card keeps its text; the logo slot on the left (x < 400) is cleared to the card's background and
    the hen is placed there, centred where the old logo sat."""
    from PIL import Image
    p = REPO / "site/assets/og.png"
    card = Image.open(p).convert("RGB")
    bg = card.getpixel((4, 4))
    card.paste(bg, (0, 120, 398, 520))
    hen = Image.open(io.BytesIO(render(without_tile(svg(ICON), pad=0), 268))).convert("RGBA")
    layer = Image.new("RGBA", card.size, (0, 0, 0, 0))
    layer.alpha_composite(hen, (222 - hen.width // 2, 312 - hen.height // 2))
    out = card.convert("RGBA")
    out.alpha_composite(layer)
    buf = io.BytesIO()
    out.convert("RGB").save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def main():
    jobs = [
        ("skills/blurt/assets/icon.png", lambda: icon_png(1024)),
        ("skills/blurt/assets/icon-16.png", lambda: icon_png(16)),
        ("skills/blurt/assets/icon-32.png", lambda: icon_png(32)),
        ("assets/logo.png", lambda: render(without_tile(svg(ICON)), 1024)),
        ("site/assets/logo.png", lambda: render(without_tile(svg(ICON)), 320)),
        ("site/assets/favicon.png", lambda: render(crop(svg(SMALL), "84 84 856 856"), 64)),
        ("site/assets/apple-touch-icon.png", lambda: render(full_bleed(svg(ICON)), 180)),
        ("site/assets/og.png", og),
        ("apps/desktop/src-tauri/icons/32x32.png", lambda: icon_png(32)),
        ("apps/desktop/src-tauri/icons/64x64.png", lambda: icon_png(64)),
        ("apps/desktop/src-tauri/icons/128x128.png", lambda: icon_png(128)),
        ("apps/desktop/src-tauri/icons/128x128@2x.png", lambda: icon_png(256)),
        ("apps/desktop/src-tauri/icons/icon.png", lambda: icon_png(512)),
        ("apps/desktop/src-tauri/icons/icon.ico", lambda: ico([16, 24, 32, 48, 64, 256])),
        ("apps/desktop/src-tauri/icons/icon.icns", icns),
        ("crates/blurt-capture/demo/icons/32x32.png", lambda: icon_png(32)),
        ("crates/blurt-capture/demo/icons/icon.png", lambda: icon_png(64)),
        ("crates/blurt-capture/demo/icons/icon.ico", lambda: ico([16, 32, 64])),
    ]
    if "--list" in sys.argv:
        print("\n".join(r for r, _ in jobs))
        return
    for rel, fn in jobs:
        data = fn()
        if data is not None:
            put(rel, data)
    glyph = (HERE / "glyph.svg").read_text()
    if (REPO / "assets/icons/blurt.svg").read_text() != glyph:
        print("note: assets/icons/blurt.svg differs from assets/brand/glyph.svg — copy it over and run "
              "python3 assets/icons/tools/build.py", file=sys.stderr)


if __name__ == "__main__":
    main()
