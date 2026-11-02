"""Cuts the codex-generated 1A frame sheets (one image per animation, a grid of frames) into aligned frames and writes
the mascot's sprite strips — the single source every platform plays.

    uv run -q --with numpy --with pillow --with scipy python assets/mascot/tools/cut.py RAW_DIR [--out assets/mascot]
        [--frames DIR]   also write every aligned frame as PNG (for checking)

RAW_DIR holds <sheet>.png for every sheet below (1536×1024, transparent; made by assets/mascot/prompts/gen.sh from the
prompts beside it).
Then run assets/mascot/tools/build.py to copy the strips into the app and the web package.

How a sheet becomes frames:
  1. split the grid at the emptiest column/row near each expected boundary;
  2. find the subject: for the chick, the largest connected blob of yellow pixels (sparkles, sound arcs, thought dots
     and the ladybug are separate blobs); for the egg, the largest opaque blob;
  3. scale each frame so the chick's size (√ of its yellow area) is the same in every frame of every animation —
     the image model draws it a few percent bigger or smaller from cell to cell, and that reads as flicker;
     the egg sheet uses one scale for the whole sheet (the egg's median height);
  4. put the subject's foot on one baseline at one x (centroid), then add the motion the sheet is meant to have
     (`lift`: a hop or bob in px; `rot`: a tilt in degrees) — drawn hops land at random heights, so we set them;
  5. clean the alpha (premultiplied resampling, no specks, no faint haze) and pack the frames left to right.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

SIZE = 160                 # px per frame: 80 pt at 2× (the largest the app shows it)
BASE_Y = 148               # the baseline (px from the top)
CHICK = 84.0               # √(yellow area) of the chick, px
EGG_H = 98.0               # the egg's height, px

SHEETS = {
    # name: grid, subject, anchor x (fraction), per-frame lift (px, up) and rotation (deg, + = counter-clockwise)
    "idle": dict(grid=(4, 2), subject="chick", x=0.5),
    "listening": dict(grid=(4, 2), subject="chick", x=0.5, rot=[-3, -5, -7, -9, -9, -7, -5, -4]),
    "thinking": dict(grid=(4, 2), subject="chick", x=0.5, lift=[0, 3, 6, 8, 6, 3, 0, 0]),
    "hatching": dict(grid=(4, 3), subject="egg", x=0.5),
    "happy": dict(grid=(4, 3), subject="chick", x=0.5, lift=[0, 0, 7, 17, 20, 12, 0, 0, 0, 0, 0, 0]),
    "peck": dict(grid=(4, 3), subject="chick", x=0.37),
}


def split(im: np.ndarray, cols: int, rows: int):
    a = im[:, :, 3].astype(float)
    H, W = a.shape

    def cuts(profile, n, length):
        out = [0]
        for k in range(1, n):
            c = length * k // n
            lo, hi = c - length // (n * 5), c + length // (n * 5)
            seg = profile[lo:hi]
            m = np.where(seg <= seg.min() + 1e-6)[0]
            out.append(lo + int(m[len(m) // 2]))
        return out + [length]

    ys = cuts(a.sum(1), rows, H)
    cells = []
    for r in range(rows):
        band = a[ys[r]:ys[r + 1]]
        xs = cuts(band.sum(0), cols, W)
        cells += [(xs[c], ys[r], xs[c + 1], ys[r + 1]) for c in range(cols)]
    return cells


def yellow(px: np.ndarray) -> np.ndarray:
    r, g, b, a = (px[:, :, i].astype(int) for i in range(4))
    return (a > 128) & (r > 200) & (g > 140) & (g < 235) & (b < 150) & (r - b > 90)


def largest(mask: np.ndarray) -> np.ndarray:
    lab, n = ndimage.label(mask)
    if n == 0:
        return mask
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    return lab == (int(np.argmax(sizes)) + 1)


def clean_alpha(px: np.ndarray) -> np.ndarray:
    """No faint haze, no stray specks far from everything else."""
    px = px.copy()
    a = px[:, :, 3]
    a[a < 10] = 0
    lab, n = ndimage.label(a > 40)
    if n:
        sizes = ndimage.sum(np.ones_like(a), lab, range(1, n + 1))
        for i, s in enumerate(sizes, 1):
            if s < 12:
                px[lab == i] = 0
    px[px[:, :, 3] == 0] = 0
    return px


def place(cell: Image.Image, scale: float, anchor: tuple[float, float], x_frac: float, lift: float, rot: float) -> Image.Image:
    """Scale about the anchor (the subject's foot), drop it on (x_frac·SIZE, BASE_Y − lift), tilt about the anchor."""
    big = cell.convert("RGBa")    # premultiplied: no dark fringes when resampling
    w, h = big.size
    big = big.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    ax, ay = anchor[0] * scale, anchor[1] * scale
    out = Image.new("RGBa", (SIZE, SIZE))
    tx, ty = SIZE * x_frac - ax, BASE_Y - lift - ay
    out.paste(big, (round(tx), round(ty)))
    if rot:
        # tilt around the middle of the body (anchor raised by ~ half the chick), like a head tilt
        cx, cy = SIZE * x_frac, BASE_Y - lift - CHICK * 0.5
        out = out.rotate(rot, resample=Image.BICUBIC, center=(cx, cy))
    return out.convert("RGBA")


def cut(raw: Path, name: str, spec: dict, frames_dir: Path | None) -> list[Image.Image]:
    src = np.array(Image.open(raw / f"{name}.png").convert("RGBA"))
    cells = split(src, *spec["grid"])
    crops = [src[y0:y1, x0:x1] for (x0, y0, x1, y1) in cells]
    infos = []
    for c in crops:
        if spec["subject"] == "chick":
            m = largest(yellow(c))
        else:
            m = largest(c[:, :, 3] > 128)
        ys, xs = np.nonzero(m)
        foot = ys.max()
        if spec["subject"] == "chick":
            cx = xs.mean()
        else:   # the egg/shell: centre of its lowest 15 % (the flying top shell doesn't count)
            low = ys >= ys.min() + (ys.max() - ys.min()) * 0.85
            cx = xs[low].mean()
        infos.append(dict(area=m.sum(), h=ys.max() - ys.min() + 1, foot=foot, cx=cx))
    if spec["subject"] == "chick":
        raw_scales = [CHICK / np.sqrt(i["area"]) for i in infos]
        med = float(np.median(raw_scales))
        scales = [min(max(s, med * 0.88), med * 1.12) for s in raw_scales]
    else:
        med = float(np.median([i["h"] for i in infos[:4]]))
        scales = [EGG_H / med] * len(infos)
    lift = spec.get("lift", [0] * len(crops))
    rot = spec.get("rot", [0] * len(crops))
    out = []
    for k, (c, i, s) in enumerate(zip(crops, infos, scales)):
        f = place(Image.fromarray(clean_alpha(c)), s, (i["cx"], i["foot"]), spec["x"], lift[k], rot[k])
        f = Image.fromarray(clean_alpha(np.array(f)))
        out.append(f)
        if frames_dir:
            frames_dir.mkdir(parents=True, exist_ok=True)
            f.save(frames_dir / f"{name}-{k:02d}.png")
    print(f"{name}: {len(out)} frames, scale {min(scales):.3f}–{max(scales):.3f}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path)
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--frames", type=Path)
    ap.add_argument("--only")
    a = ap.parse_args()
    names = a.only.split(",") if a.only else list(SHEETS)
    for name in names:
        frames = cut(a.raw, name, SHEETS[name], a.frames)
        strip = Image.new("RGBA", (SIZE * len(frames), SIZE))
        for k, f in enumerate(frames):
            strip.paste(f, (k * SIZE, 0))
        p = a.out / f"{name}.webp"
        strip.save(p, "WEBP", quality=90, alpha_quality=100, method=6)
        print(f"  → {p.name} {p.stat().st_size // 1024} KB")
    total = sum(p.stat().st_size for p in a.out.glob("*.webp"))
    print(json.dumps({"total_kb": round(total / 1024, 1)}))


if __name__ == "__main__":
    main()
