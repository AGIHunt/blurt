"""Imports Peep, the brand character, into the repo from its release package — the one source.

Peep is a 3D clay chick modelled and rendered in Blender (blurt-media/logo/peep/peep.py). Its renders are packaged in
blurt-media/logo/peep/release/ (MANIFEST.md lists the files). Nothing in this repo draws Peep: this script copies and
converts that package, and the app, the review page and the README use what it writes.

    python3 assets/brand/import_peep.py                  # from ~/workspace/blurt-media/logo/peep/release
    python3 assets/brand/import_peep.py --src DIR        # from another folder with the same layout
    python3 assets/brand/import_peep.py --list           # print the outputs and exit

Needs Pillow; the app icon's Assets.car needs Xcode's actool (assets/color/build.py --car compiles it).

The package's layout (what this reads; the app's part is under app/, the site's under web/):
  <set>/<state>/NNNN.png           512 px, 30 fps, transparent (or anim/<set>/…). set: paper (light backgrounds) or
                                    dark (the notch, dark mode; the dark-notch beak). state: idle hello listening
                                    talking thinking done error
  glyph/<state>/NNNN@1x.png, @2x   the menu-bar template frames (22 × 18 pt, black + alpha), same states
  glyph/peep-glyph.svg             the glyph at rest
  icon/paper/Peep-paper.icns, icon/paper/icon_<n>.png, icon/dark/icon_<n>.png   the app icon tiles (16…1024)
  icon-layers/peep-<paper|dark>-1024.png   the clay Peep alone, for the macOS 26 icon's layer
  stills/peep-side[-dark][-2048].png       2048 px clay stills (README)
  vector/peep-vector[-dark].svg, flat/peep-flat.svg, flat/peep-mono[-white].svg

What it writes
  macOS app   skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Peep/
                <set>-<state>.webp       a sprite sheet per clip (10 columns of `cell` px frames); Icons/Mascot.swift
                glyph-<state>.png, glyph-<state>@1x.png   the menu-bar frames as strips (44 × 36 / 22 × 18 px cells); MenuGlyph
                peep.json                the sheets' geometry, fps, the talking frames' beak opening and the blink
              skills/blurt/assets/AppIcon.icns          the paper tile (record.py puts it in Blurt.app; macOS 13–15)
              skills/blurt/assets/icon.png, icon-16.png, icon-32.png   the paper tile (review page server, fallbacks)
              assets/brand/AppIcon.icon                 the macOS 26 icon (Icon Composer format): Peep on the paper
                                                        tile's light, the dark tile's for the dark appearance →
                                                        Assets.car (CFBundleIconName)
  brand       assets/brand/peep/*.svg (vector, flat, mono, glyph), app-icon-paper.png, app-icon-dark.png (1024)
  README      assets/peep-readme.png, assets/peep-readme-dark.png (264 px: the 132 px header @2x); assets/logo.png
  web         web/packages/ui/src/assets/app-icon.png (160)
              skills/blurt/assets/peep-done.webp, peep-done-dark.webp, favicon.png   served next to the review page
                (the Done screen's clay done pose; the flat-mark favicon)
              web/packages/review/src/assets/peep-vector.svg (the top bar; numbers rounded:
                the page is one file under a 400 KB budget), peep-thinking.png (the organising pill: every third
                thinking glyph frame, a CSS mask strip)
"""
from __future__ import annotations

import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SRC = Path.home() / "workspace/blurt-media/logo/peep/release"
MAC_RES = REPO / "skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Peep"
SKILL_ASSETS = REPO / "skills/blurt/assets"
BRAND = REPO / "assets/brand"
REVIEW_ASSETS = REPO / "web/packages/review/src/assets"

STATES = ("idle", "hello", "listening", "talking", "thinking", "done", "error")
# which clips each light set ships: paper is for light backgrounds (onboarding, empty states, About, notifications),
# dark for the notch and dark mode — every clip
SETS = {"dark": STATES, "paper": ("idle", "hello", "done")}
# the side of the chick's square in the sheets, px: dark covers the island (≤ 50 pt) and the 80 pt empty state @2x;
# paper the onboarding hero (108 pt @2x)
SQUARE = {"dark": 160, "paper": 216}
COLS = 10
# idle is a slow 3 s breath with one blink: every other frame (15 fps) is enough and halves the sheet
STEP = {"idle": 2}
# the done clip's happy closed-eye moment (peep.py: happy from frame 20 to 38): the notification picture
DONE_STILL = 26
PACKAGE = DEFAULT_SRC
MANIFEST_TEXT = ""


def src_dir(src: Path, *parts: str) -> Path:
    for root in (src / "anim", src):
        p = root.joinpath(*parts)
        if p.exists():
            return p
    return src.joinpath("anim", *parts)


def frames(src: Path, st: str, state: str) -> list[Image.Image]:
    d = src_dir(src, st, state)
    files = sorted(d.glob("[0-9]*.png"))
    if not files:
        sys.exit(f"no frames in {d}")
    return [Image.open(f).convert("RGBA") for f in files]


def solid_box(im: Image.Image, th: int = 200) -> tuple[int, int, int, int]:
    return im.getchannel("A").point(lambda v: 255 if v > th else 0).getbbox()


def ink_box(im: Image.Image, th: int = 8) -> tuple[int, int, int, int]:
    return im.getchannel("A").point(lambda v: 255 if v > th else 0).getbbox()


def beak_open(im: Image.Image, rest: tuple[int, int, int, int]) -> float:
    """How far the beak is open in a side-view frame: the gap between its halves — in each column of the beak's part
    of the frame (right of the body: the rightmost 24 % of the chick at rest), the empty pixels between the top and
    bottom ink — summed, as a fraction of the chick's height squared ×100 (0 = shut)."""
    x0, y0, x1, y1 = rest
    a = im.getchannel("A").point(lambda v: 1 if v > 128 else 0)
    w, h = a.size
    px = a.load()
    gap = 0
    for x in range(int(x1 - 0.24 * (x1 - x0)), w):
        ink = [y for y in range(h) if px[x, y]]
        if len(ink) > 1:
            gap += (ink[-1] - ink[0] + 1) - len(ink)
    return round(100 * gap / (y1 - y0) ** 2, 3)


def eye_hole(im: Image.Image) -> int:
    """Transparent pixels enclosed by the ink (the eye hole in a template glyph): flood the outside, count the rest."""
    a = im.getchannel("A").point(lambda v: 255 if v > 128 else 0)
    pad = Image.new("L", (a.width + 2, a.height + 2), 0)
    pad.paste(a, (1, 1))
    ImageDraw.floodfill(pad, (0, 0), 128)
    return sum(1 for v in pad.getdata() if v == 0)


def square_of(rest: tuple[int, int, int, int]) -> tuple[float, float, float]:
    """The chick's square in source pixels: its solid body and beak at rest, centred, with 2 % air."""
    x0, y0, x1, y1 = rest
    side = max(x1 - x0, y1 - y0) * 1.04
    return (x0 + x1) / 2 - side / 2, (y0 + y1) / 2 - side / 2, side


def write_sheets(src: Path, out: dict) -> None:
    MAC_RES.mkdir(parents=True, exist_ok=True)
    for old in MAC_RES.glob("*-*.webp"):
        old.unlink()
    for st, states in SETS.items():
        clips = {s: frames(src, st, s) for s in states}
        rest = solid_box(clips["idle"][0])
        sx, sy, side = square_of(rest)
        # the bleed: room past the square on every side for the hop, the shake and the contact shadow
        need = 0.0
        for s, fs in clips.items():
            for f in fs:
                b = ink_box(f)
                need = max(need, (sx - b[0]) / side, (sy - b[1]) / side, (b[2] - sx - side) / side, (b[3] - sy - side) / side)
        bleed = math.ceil(max(0.0, need) * 100 + 1) / 100
        sq = SQUARE[st]
        cell = int(round(sq * (1 + 2 * bleed) / 2) * 2)
        box = (sx - side * bleed, sy - side * bleed, sx + side * (1 + bleed), sy + side * (1 + bleed))
        info = {"square": sq, "cell": cell, "bleed": round((cell - sq) / 2 / sq, 4), "cols": COLS, "clips": {}}
        for s, fs in clips.items():
            step = STEP.get(s, 1)
            pick = fs[::step]
            n = len(pick)
            rows = math.ceil(n / COLS)
            sheet = Image.new("RGBA", (COLS * cell, rows * cell), (0, 0, 0, 0))
            for i, f in enumerate(pick):
                c = f.crop(tuple(round(v) for v in box)).resize((cell, cell), Image.LANCZOS)
                sheet.paste(c, ((i % COLS) * cell, (i // COLS) * cell))
            name = f"{st}-{s}.webp"
            sheet.save(MAC_RES / name, "WEBP", quality=88, alpha_quality=100, method=6)
            clip = {"frames": n, "fps": 30 // step}
            if s == "talking":
                clip["open"] = [beak_open(f, rest) for f in pick]
            info["clips"][s] = clip
            out.setdefault("written", []).append(MAC_RES / name)
        out["sets"][st] = info
    out["stills"] = {"done": DONE_STILL // STEP.get("done", 1)}


def write_glyphs(src: Path, out: dict) -> None:
    # the canvas in pt (wider than tall: the beak needs the room) from the package's frames.json; 18 × 18 before that
    meta = json.loads((src / "frames.json").read_text()).get("glyph", {}) if (src / "frames.json").exists() else {}
    w, h = int(meta.get("w", 18)), int(meta.get("h", 18))
    g = {"box": [w, h], "clips": {}}
    for s in STATES:
        d = src / "glyph" / s
        f2 = sorted(d.glob("*@2x.png"))
        f1 = sorted(d.glob("*@1x.png"))
        if not f2 or len(f1) != len(f2):
            sys.exit(f"glyph frames missing or unpaired in {d}")
        for files, (cw, ch), sfx in ((f2, (w * 2, h * 2), ""), (f1, (w, h), "@1x")):
            strip = Image.new("RGBA", (cw * len(files), ch), (0, 0, 0, 0))
            for i, f in enumerate(files):
                im = Image.open(f).convert("RGBA")
                if im.size != (cw, ch):
                    sys.exit(f"{f}: {im.size}, want {cw} × {ch} px")
                # a template image: black, the shape in alpha only
                a = im.getchannel("A")
                k = Image.new("RGBA", im.size, (0, 0, 0, 0))
                k.putalpha(a)
                strip.paste(k, (i * cw, 0))
            name = f"glyph-{s}{sfx}.png"
            strip.save(MAC_RES / name, optimize=True)
            out["written"].append(MAC_RES / name)
        ims = [Image.open(f).convert("RGBA") for f in f2]
        clip = {"frames": len(ims), "fps": 30}
        given = meta.get("clips", {}).get(s, {}).get("open")
        if s == "talking" and given and len(given) == len(ims):
            clip["open"] = given                    # the package's own opening per frame (0 closed … 1 wide)
        elif s == "talking":
            rest = ink_box(Image.open(sorted((src / "glyph/idle").glob("*@2x.png"))[0]).convert("RGBA"), 128)
            clip["open"] = [beak_open(im, rest) for im in ims]
        if s == "idle":
            holes = [eye_hole(im) for im in ims]
            top = max(holes)
            shut = [i for i, h in enumerate(holes) if h < top * 0.6]
            if shut:
                clip["blink"] = [max(0, shut[0] - 2), min(len(ims) - 1, shut[-1] + 3)]
        g["clips"][s] = clip
    out["glyph"] = g


def write_icons(src: Path, out: dict) -> None:
    paper, dark = src / "icon/paper", src / "icon/dark"
    icns = next(paper.glob("*.icns"), None)
    if not icns:
        sys.exit(f"no .icns in {paper}")
    w = out["written"]
    shutil.copy(icns, SKILL_ASSETS / "AppIcon.icns"); w.append(SKILL_ASSETS / "AppIcon.icns")
    shutil.copy(paper / "icon_1024.png", SKILL_ASSETS / "icon.png"); w.append(SKILL_ASSETS / "icon.png")
    for n in (16, 32):
        shutil.copy(paper / f"icon_{n}.png", SKILL_ASSETS / f"icon-{n}.png"); w.append(SKILL_ASSETS / f"icon-{n}.png")
    shutil.copy(paper / "icon_1024.png", BRAND / "app-icon-paper.png"); w.append(BRAND / "app-icon-paper.png")
    shutil.copy(dark / "icon_1024.png", BRAND / "app-icon-dark.png"); w.append(BRAND / "app-icon-dark.png")
    Image.open(paper / "icon_1024.png").convert("RGBA").resize((160, 160), Image.LANCZOS).save(
        REPO / "web/packages/ui/src/assets/app-icon.png", optimize=True)
    w.append(REPO / "web/packages/ui/src/assets/app-icon.png")
    layers = src / "icon-layers"
    write_icon_composer(paper / "icon_1024.png", dark / "icon_1024.png", layers if layers.is_dir() else None, out)


def srgb(px) -> str:
    r, g, b = px[:3]
    return f"srgb:{r / 255:.5f},{g / 255:.5f},{b / 255:.5f},1.00000"


def tile_fill(im: Image.Image, tone: str) -> dict:
    """The tile's light, top to bottom: the gradient MANIFEST.md gives for the tile ("**Paper tile** … `#F0EAE1` (top)
    → `#DED6C8` (bottom)"), else sampled inside the tile's left edge, clear of Peep and its shadow."""
    m = re.search(rf"\*\*{tone} tile\*\*[^`]*`(#[0-9A-Fa-f]{{6}})` \(top\) → `(#[0-9A-Fa-f]{{6}})` \(bottom\)",
                  MANIFEST_TEXT, re.I)
    if m:
        return {"linear-gradient": [srgb(tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))) for h in m.groups()]}
    im = im.convert("RGBA")
    return {"linear-gradient": [srgb(im.getpixel((150, 160))), srgb(im.getpixel((150, 880)))]}


def body_box(im: Image.Image, area: tuple[int, int, int, int]) -> tuple[float, float, float]:
    """Peep's body in an icon picture: the strongly coloured pixels (the gradient sphere; the slate beak, the tile and
    the shadow are greys) → (centre x, centre y, width) in pixels."""
    px = im.load()
    xs, ys = [], []
    for y in range(area[1], area[3], 2):
        for x in range(area[0], area[2], 2):
            r, g, b, a = px[x, y]
            if a > 200 and max(r, g, b) - min(r, g, b) > 60:
                xs.append(x)
                ys.append(y)
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, max(xs) - min(xs)


def fit_to_tile(layer: Image.Image, tile: Image.Image) -> Image.Image:
    """The release's icon layer, scaled and moved so Peep's body has the size and place it has on the 1024 tile (60 %
    of the 824 px tile, a little left of centre): the system draws the .icon's canvas as the tile itself."""
    tx, ty, tw = body_box(tile, (110, 110, 914, 914))
    lx, ly, lw = body_box(layer, (0, 0, 1024, 1024))
    k = (tw / 824) / (lw / 1024)                         # the tile's 824 px become the canvas's 1024
    want_x, want_y = (tx - 100) / 824 * 1024, (ty - 100) / 824 * 1024
    scaled = layer.resize((round(1024 * k), round(1024 * k)), Image.LANCZOS)
    out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    out.paste(scaled, (round(want_x - lx * k), round(want_y - ly * k)))   # onto nothing: a plain copy
    return out


def write_icon_composer(paper: Path, dark: Path, layers: Path | None, out: dict) -> None:
    """assets/brand/AppIcon.icon for macOS 26 (Icon Composer format): the system draws the rounded shape, the margin
    and the shadow, so the icon sits on the Dock's grid like every other one, and switches with the appearance. Fill:
    the tile's own light (paper; the dark tile in dark mode). Layer: the clay Peep alone (release icon-layers/, drawn for
    the full canvas), or — from a package without layers — the tile's square cropped from the 1024 tile. No glass and
    no specular: Peep is already lit clay."""
    ic = BRAND / "AppIcon.icon"
    shutil.rmtree(ic, ignore_errors=True)
    (ic / "Assets").mkdir(parents=True)
    fills = []
    for name, tile, tone in (("peep-paper.png", paper, "paper"), ("peep-dark.png", dark, "dark")):
        im = Image.open(tile).convert("RGBA")
        fills.append(tile_fill(im, tone))
        alone = layers / f"peep-{tone}-1024.png" if layers else None
        if alone and alone.exists():
            fit_to_tile(Image.open(alone).convert("RGBA"), im).save(ic / "Assets" / name, optimize=True)
            continue
        sq = im.crop((100, 100, 924, 924)).resize((1024, 1024), Image.LANCZOS)
        flat = Image.new("RGBA", sq.size, sq.getpixel((512, 40)))
        flat.alpha_composite(sq)
        flat.convert("RGB").save(ic / "Assets" / name, optimize=True)
    doc = {
        "fill-specializations": [{"value": fills[0]}, {"appearance": "dark", "value": fills[1]}],
        "groups": [{
            "layers": [{"image-name-specializations": [{"value": "peep-paper.png"}, {"appearance": "dark", "value": "peep-dark.png"}],
                        "name": "peep", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
            "specular": False,
        }],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (ic / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")
    out["written"].append(ic)


def trim_square(im: Image.Image, pad: float = 0.04) -> Image.Image:
    b = ink_box(im)
    side = max(b[2] - b[0], b[3] - b[1]) * (1 + 2 * pad)
    cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    return im.crop((round(cx - side / 2), round(cy - side / 2), round(cx + side / 2), round(cy + side / 2)))


def write_brand_and_readme(src: Path, out: dict) -> None:
    w = out["written"]
    peep = BRAND / "peep"
    shutil.rmtree(peep, ignore_errors=True)
    peep.mkdir(parents=True)
    for rel in ("vector/peep-vector.svg", "vector/peep-vector-dark.svg", "flat/peep-flat.svg", "flat/peep-mono.svg",
                "flat/peep-mono-white.svg", "glyph/peep-glyph.svg"):
        shutil.copy(src / rel, peep / Path(rel).name)
    w.append(peep)
    stills = src / "stills"

    def still(stem: str) -> Path:
        return next(p for p in (stills / f"{stem}-2048.png", stills / f"{stem}.png") if p.exists())
    readme = PACKAGE / "readme"
    for name, stem in (("peep-readme.png", "peep-side"), ("peep-readme-dark.png", "peep-side-dark")):
        logo = readme / name.replace("peep-readme", "peep-logo")
        if logo.exists():                # the package's README logo (512, the dark one for GitHub dark)
            shutil.copy(logo, REPO / "assets" / name)
        else:
            im = trim_square(Image.open(still(stem)).convert("RGBA"))
            im.resize((264, 264), Image.LANCZOS).save(REPO / "assets" / name, optimize=True)
        w.append(REPO / "assets" / name)
    im = trim_square(Image.open(still("peep-side")).convert("RGBA"))
    im.resize((1024, 1024), Image.LANCZOS).save(REPO / "assets/logo.png", optimize=True)
    w.append(REPO / "assets/logo.png")


def densest(d: str, tol: float = 0.0012) -> str:
    """A path traced as many tiny curves (the projected beak) as the polygon through their end points, with the points a
    straight line would skip dropped (Ramer–Douglas–Peucker, `tol` in the drawing's units: 1/2000 of Peep's width,
    far under a pixel at the sizes the page draws it). Any other path comes back as it was."""
    m = re.fullmatch(r"\s*M([^A-Za-z]+)C([^A-BD-Za-z]+)(Z?)\s*", d)
    if not m:
        return d
    nums = [float(v) for v in re.findall(r"-?\d*\.?\d+(?:e-?\d+)?", m.group(2))]
    if len(nums) % 6 or len(nums) < 6 * 20:
        return d
    start = [float(v) for v in re.findall(r"-?\d*\.?\d+", m.group(1))][:2]
    pts = [tuple(start)] + [(nums[i + 4], nums[i + 5]) for i in range(0, len(nums), 6)]
    steps = sorted(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))
    if steps[len(steps) // 2] > 0.02:
        return d                  # a real curve (the eye): its cubic segments stay

    def rdp(a: int, b: int, keep: list[int]) -> None:
        (x0, y0), (x1, y1) = pts[a], pts[b]
        L = math.hypot(x1 - x0, y1 - y0) or 1e-9
        far, at = 0.0, -1
        for i in range(a + 1, b):
            dist = abs((x1 - x0) * (y0 - pts[i][1]) - (x0 - pts[i][0]) * (y1 - y0)) / L
            if dist > far:
                far, at = dist, i
        if far > tol:
            rdp(a, at, keep)
            keep.append(at)
            rdp(at, b, keep)

    # a closed outline starts and ends on one point: split it at the point farthest from there first
    last = len(pts) - 1
    mid = max(range(last + 1), key=lambda i: math.hypot(pts[i][0] - pts[0][0], pts[i][1] - pts[0][1]))
    keep = [0, mid, last]
    rdp(0, mid, keep)
    rdp(mid, last, keep)

    def num(v: float) -> str:
        return re.sub(r"^(-?)0\.", r"\1.", f"{v:.3f}")
    order = sorted(set(keep))
    out = f"M{num(pts[0][0])} {num(pts[0][1])}L" + " ".join(f"{num(pts[i][0])} {num(pts[i][1])}" for i in order[1:])
    return out + ("Z" if m.group(3) else "")


def svg_min(s: str) -> str:
    """The same drawing in fewer bytes: numbers to 3 decimals without a leading zero, no whitespace between tags."""
    s = re.sub(r"-?\d*\.\d{4,}", lambda m: f"{float(m.group()):.3f}", s)
    s = re.sub(r"(?<![\d.])(-?)0\.(\d)", r"\1.\2", s)
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r">\s+<", "><", s)
    s = re.sub(r" (-)", r"\1", s)

    def path(d: str) -> str:
        d = densest(d)
        # a repeated command letter is implied; numbers split by commas (a data URL keeps a comma, spells a space %20)
        out, last = [], None
        for tok in re.findall(r"[A-Za-z]|[^A-Za-z]+", d):
            if tok.isalpha():
                if tok == last and tok in "CL":
                    out.append(",")
                    continue
                last = tok
                out.append(tok)
            else:
                out.append(re.sub(r" +", ",", tok.strip()))
        return re.sub(r",(-)", r"\1", "".join(out))
    s = re.sub(r'(?<![\w-])d="([^"]*)"', lambda m: f'd="{path(m.group(1))}"', s)
    return s.strip() + "\n"


def write_review(src: Path, out: dict) -> None:
    """The review page: the vector Peep (the top bar at 28 px, the Done screen at 88 px), and the menu-bar thinking
    frames as a strip for the organising pill (a CSS mask, so it takes the pill's colour). The page is one file with
    a 400 KB budget, so the clay renders stay out of it."""
    w = out["written"]
    REVIEW_ASSETS.mkdir(parents=True, exist_ok=True)
    for old in REVIEW_ASSETS.glob("peep-*"):
        old.unlink()
    (REVIEW_ASSETS / "peep-vector.svg").write_text(svg_min((src / "vector/peep-vector.svg").read_text()))
    strip = Image.open(MAC_RES / "glyph-thinking.png")
    w2, h2 = (2 * v for v in out["glyph"]["box"])     # the @2x cell (44 × 36): the page's CSS keeps its 22:18
    n = strip.width // w2
    picks = list(range(0, n, 3))
    out_strip = Image.new("RGBA", (w2 * len(picks), h2), (0, 0, 0, 0))
    for j, i in enumerate(picks):
        out_strip.paste(strip.crop((i * w2, 0, i * w2 + w2, h2)), (j * w2, 0))
    out_strip.save(REVIEW_ASSETS / "peep-thinking.png", optimize=True)
    out["review"] = {"thinking_frames": len(picks), "thinking_fps": 10}
    w += [REVIEW_ASSETS / "peep-vector.svg", REVIEW_ASSETS / "peep-thinking.png"]
    # served next to the page (review.py, the app's blurt-app://ui/, never inlined: the page has a size budget): the
    # Done screen's clay done pose (the happy eye) in each light set, and the flat-mark favicon
    for st, name in (("paper", "peep-done.webp"), ("dark", "peep-done-dark.webp")):
        f = frames(src, st, "done")[DONE_STILL]
        sx, sy, side = square_of(solid_box(frames(src, st, "idle")[0]))
        pad = side * 0.12
        c = f.crop((round(sx - pad), round(sy - pad), round(sx + side + pad), round(sy + side + pad)))
        c.resize((240, 240), Image.LANCZOS).save(SKILL_ASSETS / name, "WEBP", quality=90, alpha_quality=100, method=6)
        w.append(SKILL_ASSETS / name)
    fav = PACKAGE / "web/favicon-32.png"
    if fav.exists():
        shutil.copy(fav, SKILL_ASSETS / "favicon.png")
        w.append(SKILL_ASSETS / "favicon.png")


def main() -> int:
    args = sys.argv[1:]
    src = Path(args[args.index("--src") + 1]).expanduser() if "--src" in args else DEFAULT_SRC
    if "--list" in args:
        print(__doc__.split("What it writes", 1)[1])
        return 0
    manifest = src / "MANIFEST.md"
    if not manifest.exists():
        sys.exit(f"{manifest} not found: is the release package there? (--src DIR)")
    global PACKAGE, MANIFEST_TEXT
    PACKAGE, MANIFEST_TEXT = src, manifest.read_text()
    if "Status: COMPLETE" not in MANIFEST_TEXT and "interim" not in MANIFEST_TEXT:
        sys.exit(f"{manifest} does not say the package is complete yet")
    if (src / "app").is_dir():          # the package keeps the app's files under app/ (web/ is the site's)
        src = src / "app"
    out: dict = {"version": 1, "source": str(manifest.parent).replace(str(Path.home()), "~"),
                 "manifest": next((ln for ln in MANIFEST_TEXT.splitlines() if "Status" in ln), "")[:200], "sets": {}, "written": []}
    write_sheets(src, out)
    write_glyphs(src, out)
    write_icons(src, out)
    write_brand_and_readme(src, out)
    write_review(src, out)
    written = out.pop("written")
    (MAC_RES / "peep.json").write_text(json.dumps(out, indent=1) + "\n")
    written.append(MAC_RES / "peep.json")
    # the app icon's Assets.car (macOS 26: CFBundleIconName) is compiled with the accent colour
    r = subprocess.run([sys.executable, str(REPO / "assets/color/build.py"), "--car"], capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr.strip())
    for p in written:
        print("wrote", p.relative_to(REPO))
    size = sum(p.stat().st_size for p in MAC_RES.iterdir())
    print(f"app resources: {size / 1e6:.2f} MB in {MAC_RES.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
