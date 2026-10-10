# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""Frame tools for screen recordings. The agent decides *which* moments matter; this script makes it cheap to look.

  frames.py scan  VIDEO                         build a visual-activity index (scan.npz) at 2 fps, once per video
  frames.py candidates VIDEO --from S --to E    suggest diverse, settled frame times inside a window (JSON)
  frames.py sheet VIDEO --from S --to E -o x.jpg   contact sheet of candidates with timestamps (one image to review)
  frames.py sheet VIDEO --at 12.5 14 20 -o x.jpg   contact sheet of explicit times
  frames.py grid  VIDEO --at T -o x.jpg          frame with a labelled 0–1 coordinate grid + where the cursor / clicks
                                                were (from events.jsonl) — read positions off this, don't guess
  frames.py pointer VIDEO --at T                 cursor position and nearby clicks / pen strokes at T (JSON)
  frames.py marks VIDEO                          everything the user drew with the pen (⌃-drag) and every marker: when,
                                                where (box), what shapes, what was being said, and the time to grab
  frames.py grab  VIDEO --at T -o x.jpg [--box x,y,w,h|stroke] [--ring cursor|click|x,y] [--crop x,y,w,h|stroke]
                                                full-res frame with red box / ring, optional crop
  frames.py clip  VIDEO --from S --to E -o x.mp4   small shareable clip (with audio)

Coordinates for --box/--crop/--ring are fractions (0-1) of the frame, so they work at any resolution. The native
recorder logs the cursor and clicks in events.jsonl (same fractions): when the user pointed at or clicked the thing,
`--ring cursor` / `--ring click` marks it exactly. Pen strokes are in the video itself (visible for ~3 s) and in
events.jsonl: grab at a mark's `frame_t` and the user's own circle is the annotation; `--crop stroke` zooms in on it,
`--box stroke` re-draws its box on a frame where the ink is gone.
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, ffmpeg_bin, fmt_ts, probe_duration, probe_size  # noqa: E402

SCAN_FPS = 2
THUMB_W = 192


# ------------------------------------------------------------------ scan
def scan_path(video: Path) -> Path:
    return video.with_name(video.stem + ".scan.npz")


def scan(video: Path, force: bool = False) -> dict:
    out = scan_path(video)
    if out.exists() and not force:
        d = np.load(out)
        return {"times": d["times"], "thumbs": d["thumbs"], "change": d["change"]}
    w, h = probe_size(video)
    th = max(2, int(round(THUMB_W * h / w / 2)) * 2)
    proc = subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-i", str(video), "-an",
                           "-vf", f"fps={SCAN_FPS},scale={THUMB_W}:{th},format=gray", "-f", "rawvideo", "-"],
                          capture_output=True)
    if proc.returncode != 0:
        die(proc.stderr.decode(errors="replace")[-800:])
    thumbs = np.frombuffer(proc.stdout, dtype=np.uint8).reshape(-1, th, THUMB_W)
    times = (np.arange(len(thumbs)) / SCAN_FPS).astype(np.float32)
    # fraction of pixels that changed noticeably vs previous sample: robust to tiny UI changes (toasts, tooltips)
    diff = np.abs(np.diff(thumbs.astype(np.int16), axis=0)) > 18
    change = np.concatenate([[0.0], diff.mean(axis=(1, 2))]).astype(np.float32)
    np.savez_compressed(out, times=times, thumbs=thumbs, change=change)
    return {"times": times, "thumbs": thumbs, "change": change}


def candidates(video: Path, start: float, end: float, n: int = 6, pad_before: float = 3.0, pad_after: float = 1.5):
    """Settled frames after each visual change + anchors, then farthest-point sampling for diversity."""
    s = scan(video)
    times, thumbs, change = s["times"], s["thumbs"], s["change"]
    dur = float(times[-1]) if len(times) else probe_duration(video)
    lo, hi = max(0.0, start - pad_before), min(dur, end + pad_after)
    idx = np.where((times >= lo) & (times <= hi))[0]
    if len(idx) == 0:
        return [round((start + end) / 2, 2)]
    moving = change > 0.002
    pool: list[int] = []
    for i in idx:  # first quiet sample after motion = UI has settled into a new state
        if i > 0 and moving[i - 1] and not moving[i]:
            pool.append(int(i))
    for t in (start, (start + end) / 2, end):  # speech anchors: user usually points while talking
        pool.append(int(np.argmin(np.abs(times - t))))
    pool = sorted(set(pool))
    if not pool:
        pool = list(idx)
    vecs = thumbs[pool].reshape(len(pool), -1).astype(np.float32)
    # start from the settled frame with the most prior motion inside the window (most "eventful")
    first = int(np.argmax([change[max(0, p - 3):p + 1].sum() for p in pool]))
    chosen = [first]
    dist = np.abs(vecs - vecs[first]).mean(axis=1)
    while len(chosen) < min(n, len(pool)):
        j = int(np.argmax(dist))
        if dist[j] < 1.5:  # everything left is a near-duplicate
            break
        chosen.append(j)
        dist = np.minimum(dist, np.abs(vecs - vecs[j]).mean(axis=1))
    return sorted(round(float(times[pool[c]]), 2) for c in chosen)


# ------------------------------------------------------------------ extraction
def grab(video: Path, t: float, max_w: int | None = None) -> Image.Image:
    vf = [f"scale='min({max_w},iw)':-2"] if max_w else []
    cmd = [ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-ss", f"{t:.3f}", "-i", str(video), "-frames:v", "1"]
    cmd += (["-vf", ",".join(vf)] if vf else []) + ["-f", "image2pipe", "-c:v", "png", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    if not raw:  # past the end -> step back
        if t > 0.5:
            return grab(video, t - 0.5, max_w)
        die(f"could not grab frame at {t}")
    from io import BytesIO
    return Image.open(BytesIO(raw)).convert("RGB")


# ------------------------------------------------------------------ pointer (events.jsonl from the recorder)
def load_events(video: Path) -> list[dict]:
    f = video.parent / "events.jsonl"
    if not f.exists():
        return []
    out = []
    for line in f.read_text(encoding="utf-8").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def pointer_at(video: Path, t: float, window: float = 4.0) -> dict:
    ev = load_events(video)
    cur = [e for e in ev if e.get("type") == "cursor" and e["t"] <= t + 0.15]
    cursor = cur[-1] if cur and t - cur[-1]["t"] < 5 else None   # cursor is logged only when it moves
    clicks = sorted((e for e in ev if e.get("type") == "click" and abs(e["t"] - t) <= window), key=lambda e: abs(e["t"] - t))
    return {"t": t, "has_events": bool(ev),
            "cursor": {"x": cursor["x"], "y": cursor["y"], "since": round(t - cursor["t"], 2)} if cursor else None,
            "clicks": [{"x": c["x"], "y": c["y"], "t": round(c["t"], 2)} for c in clicks[:5]],
            "strokes": [s for s in strokes(video) if s["t0"] - window <= t <= s["t"] + window]}


# ------------------------------------------------------------------ pen strokes (drawn while recording)
def strokes(video: Path) -> list[dict]:
    """Pen strokes from events.jsonl with what the agent needs: box, shape, and the moment the ink is complete.
    Ink stays until `visible` seconds after the last stroke, so strokes drawn in one go form a `mark`: they are all
    on screen at the mark's `frame_t`."""
    raw = [e for e in load_events(video) if e.get("type") == "stroke" and e.get("points")]
    if not raw:
        return []
    w, h = probe_size(video)
    out: list[dict] = []
    for n, e in enumerate(raw, 1):
        pts = e["points"]
        xs, ys = [q[0] for q in pts], [q[1] for q in pts]
        box = [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]
        px = [(x * w, y * h) for x, y in pts]            # shape is judged in pixels, not in stretched 0–1 space
        length = sum(math.dist(a, b) for a, b in zip(px, px[1:]))
        gap, diag = math.dist(px[0], px[-1]), math.hypot(box[2] * w, box[3] * h)
        if len(pts) == 1:
            shape = "tap"                                 # the recorder rings the spot
        elif gap < 0.4 * diag and length > 2.2 * diag:
            shape = "loop"                                # circled something: the box is the thing
        elif length < 1.3 * gap:
            shape = "line"                                # underline, or an arrow from → to
        else:
            shape = "free"
        t0, vis = e.get("t0", e["t"]), e.get("visible", 3.0)
        joins = bool(out) and t0 <= out[-1]["t"] + out[-1]["_vis"]
        out.append({"n": n, "mark": out[-1]["mark"] if joins else (out[-1]["mark"] + 1 if out else 1),
                    "t0": round(t0, 2), "t": round(e["t"], 2), "shape": shape, "box": [round(v, 3) for v in box],
                    "from": pts[0], "to": pts[-1], "_vis": vis})
    for s in out:
        last = [o for o in out if o["mark"] == s["mark"]][-1]
        s["frame_t"] = round(last["t"] + min(0.3, last["_vis"] / 3), 2)
    for s in out:
        del s["_vis"]
    return out


def _union(boxes: list[list[float]]) -> list[float]:
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x1, y1 = max(b[0] + b[2] for b in boxes), max(b[1] + b[3] for b in boxes)
    return [round(x0, 3), round(y0, 3), round(x1 - x0, 3), round(y1 - y0, 3)]


def marks(video: Path) -> dict:
    """Pen marks (strokes drawn in one go) + markers, each with the words spoken around it (transcript.json next to
    the video, if present)."""
    tr = video.parent / "transcript.json"
    segs = json.loads(tr.read_text(encoding="utf-8")).get("segments", []) if tr.exists() else []

    def said(a: float, b: float) -> str:
        return " ".join(s["text"] for s in segs if s["end"] >= a - 1.5 and s["start"] <= b + 2.5)

    groups: dict[int, list[dict]] = {}
    for s in strokes(video):
        groups.setdefault(s["mark"], []).append(s)
    out = [{"mark": m, "t0": g[0]["t0"], "t": g[-1]["t"], "frame_t": g[-1]["frame_t"], "box": _union([s["box"] for s in g]),
            "strokes": [{"shape": s["shape"], "box": s["box"], "from": s["from"], "to": s["to"]} for s in g],
            "said": said(g[0]["t0"], g[-1]["t"])} for m, g in groups.items()]
    mk = [{"t": round(e["t"], 2), "said": said(e["t"], e["t"])} for e in load_events(video) if e.get("type") == "marker"]
    return {"marks": out, "markers": mk}


def _stroke_box(video: Path, t: float, pad: float, least: float = 0.0) -> str:
    """Box of the pen mark nearest to t, grown by pad × its size and to at least `least` of the frame per side."""
    st = strokes(video)
    if not st:
        die("no pen strokes in events.jsonl — give x,y,w,h instead")
    near = min(st, key=lambda s: 0 if s["t0"] <= t <= s["frame_t"] + 2.5 else min(abs(s["t0"] - t), abs(s["t"] - t)))
    x, y, bw, bh = _union([s["box"] for s in st if s["mark"] == near["mark"]])
    w, h = max(bw * (1 + 2 * pad), least, 0.02), max(bh * (1 + 2 * pad), least, 0.02)
    x0, y0 = min(max(0, x + bw / 2 - w / 2), 1 - min(w, 1)), min(max(0, y + bh / 2 - h / 2), 1 - min(h, 1))
    return f"{x0},{y0},{min(w, 1)},{min(h, 1)}"


def _point(spec: str, video: Path, t: float) -> tuple[float, float] | None:
    if spec in ("cursor", "click"):
        p = pointer_at(video, t)
        if spec == "cursor" and p["cursor"]:
            return p["cursor"]["x"], p["cursor"]["y"]
        if spec == "click" and p["clicks"]:
            return p["clicks"][0]["x"], p["clicks"][0]["y"]
        die(f"no {spec} position recorded near t={t} (events.jsonl missing or empty) — use --box instead")
    x, y = (float(v) for v in spec.split(","))
    return x, y


def draw_ring(im: Image.Image, x: float, y: float, r_frac: float = 0.028) -> None:
    d = ImageDraw.Draw(im)
    r = max(22, int(im.width * r_frac))
    cx, cy = int(x * im.width), int(y * im.height)
    w = max(3, im.width // 400)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline="#ff2d2d", width=w)


def grid_image(im: Image.Image, video: Path, t: float) -> dict:
    """Overlay a 0–1 grid (minor 0.05, labelled 0.1) and pointer markers so positions can be read, not guessed."""
    base = im.convert("RGBA")
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    W, H = base.size
    f = _font(max(13, W // 110))
    for i in range(1, 20):
        v = i / 20
        major = i % 2 == 0
        col = (0, 170, 255, 150) if major else (0, 170, 255, 70)
        x, y = int(v * W), int(v * H)
        d.line([(x, 0), (x, H)], fill=col, width=2 if major else 1)
        d.line([(0, y), (W, y)], fill=col, width=2 if major else 1)
        if major:
            lbl = f".{i // 2}"
            for pos in ((x + 3, 2), (x + 3, H - f.size - 4)):
                d.rectangle([pos[0] - 1, pos[1], pos[0] + f.size * 1.3, pos[1] + f.size + 2], fill=(0, 0, 0, 170))
                d.text(pos, lbl, fill=(255, 255, 255, 255), font=f)
            for pos in ((3, y + 2), (W - f.size * 1.5, y + 2)):
                d.rectangle([pos[0] - 1, pos[1], pos[0] + f.size * 1.3, pos[1] + f.size + 2], fill=(0, 0, 0, 170))
                d.text(pos, lbl, fill=(255, 255, 255, 255), font=f)
    info = pointer_at(video, t)
    r = max(10, W // 120)
    for c in info["clicks"]:
        cx, cy = c["x"] * W, c["y"] * H
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 200, 0, 255), width=3)
        d.text((cx + r + 3, cy - r), f"click {c['t']:.1f}s ({c['x']:.2f},{c['y']:.2f})", fill=(255, 200, 0, 255), font=f)
    for s in info["strokes"]:
        x, y, bw, bh = s["box"]
        d.rectangle([x * W, y * H, (x + bw) * W, (y + bh) * H], outline=(255, 110, 60, 255), width=3)
        d.text((x * W + 4, (y + bh) * H + 3), f"stroke #{s['n']} {s['shape']} {s['t']:.1f}s", fill=(255, 110, 60, 255), font=f)
    if info["cursor"]:
        cx, cy = info["cursor"]["x"] * W, info["cursor"]["y"] * H
        d.line([(cx - 2 * r, cy), (cx + 2 * r, cy)], fill=(255, 45, 45, 255), width=3)
        d.line([(cx, cy - 2 * r), (cx, cy + 2 * r)], fill=(255, 45, 45, 255), width=3)
        d.text((cx + r + 3, cy + 3), f"cursor ({info['cursor']['x']:.2f},{info['cursor']['y']:.2f})", fill=(255, 45, 45, 255), font=f)
    im.paste(Image.alpha_composite(base, ov).convert("RGB"))
    return info


def _font(size: int):
    for name in ("Arial.ttf", "DejaVuSans.ttf", "arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "C:/Windows/Fonts/arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except Exception:
            continue
    return ImageFont.load_default()


def _frac_box(spec: str, w: int, h: int) -> tuple[int, int, int, int]:
    x, y, bw, bh = (float(v) for v in spec.split(","))
    if max(x, y, bw, bh) > 1.0:  # pixels given
        return int(x), int(y), int(x + bw), int(y + bh)
    return int(x * w), int(y * h), int((x + bw) * w), int((y + bh) * h)


def contact_sheet(video: Path, times: list[float], out: Path, cols: int = 3, cell_w: int = 640) -> None:
    imgs = [grab(video, t, cell_w) for t in times]
    ch = max(i.height for i in imgs)
    rows = (len(imgs) + cols - 1) // cols
    cols = min(cols, len(imgs))
    sheet = Image.new("RGB", (cols * cell_w + (cols + 1) * 8, rows * (ch + 30) + 8), "#222")
    d, f = ImageDraw.Draw(sheet), _font(20)
    for k, (im, t) in enumerate(zip(imgs, times)):
        x, y = 8 + (k % cols) * (cell_w + 8), 8 + (k // cols) * (ch + 30)
        sheet.paste(im, (x, y + 26))
        d.text((x + 2, y + 2), f"#{k + 1}  t={t:.1f}s ({fmt_ts(t)})", fill="#ffd54a", font=f)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, quality=85)


# ------------------------------------------------------------------ commands
def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sc = sub.add_parser("scan")
    sc.add_argument("video")
    sc.add_argument("--force", action="store_true")
    for name in ("candidates", "sheet"):
        c = sub.add_parser(name)
        c.add_argument("video")
        c.add_argument("--from", dest="start", type=float)
        c.add_argument("--to", dest="end", type=float)
        c.add_argument("--at", type=float, nargs="+")
        c.add_argument("-n", type=int, default=6)
        if name == "sheet":
            c.add_argument("-o", "--out", required=True)
            c.add_argument("--cols", type=int, default=3)
    gr = sub.add_parser("grid")
    gr.add_argument("video")
    gr.add_argument("--at", type=float, required=True)
    gr.add_argument("-o", "--out", required=True)
    gr.add_argument("--crop", help="x,y,w,h: zoom into part of the frame (grid labels stay in full-frame fractions)")
    po = sub.add_parser("pointer")
    po.add_argument("video")
    po.add_argument("--at", type=float, required=True)
    g = sub.add_parser("grab")
    g.add_argument("video")
    g.add_argument("--at", type=float, required=True)
    g.add_argument("-o", "--out", required=True)
    g.add_argument("--box", action="append", help="x,y,w,h (fractions or px) to outline in red; repeatable; "
                                                  "'stroke' = the pen stroke nearest to --at")
    g.add_argument("--ring", action="append", help="cursor | click | x,y — red circle at the pointer / a point; repeatable")
    g.add_argument("--crop", help="x,y,w,h (fractions or px) to crop to, applied after boxes; "
                                  "'stroke' = around the pen stroke nearest to --at")
    mk = sub.add_parser("marks")
    mk.add_argument("video")
    g.add_argument("--max-width", type=int, default=1920)
    cl = sub.add_parser("clip")
    cl.add_argument("video")
    cl.add_argument("--from", dest="start", type=float, required=True)
    cl.add_argument("--to", dest="end", type=float, required=True)
    cl.add_argument("-o", "--out", required=True)
    cl.add_argument("--max-width", type=int, default=1280)
    a = p.parse_args()
    video = Path(a.video)
    if not video.exists():
        die(f"{video} not found")

    if a.cmd == "scan":
        s = scan(video, a.force)
        ch = s["change"]
        busy = [round(float(t), 1) for t, c in zip(s["times"], ch) if c > 0.02]
        print(json.dumps({"index": str(scan_path(video)), "samples": int(len(ch)), "fps": SCAN_FPS,
                          "significant_changes_at": busy[:300]}))
    elif a.cmd in ("candidates", "sheet"):
        if a.at:
            times = a.at
        elif a.start is not None and a.end is not None:
            times = candidates(video, a.start, a.end, a.n)
        else:
            die("give --from/--to or --at")
        if a.cmd == "candidates":
            print(json.dumps({"times": times}))
        else:
            contact_sheet(video, times, Path(a.out), a.cols)
            print(json.dumps({"sheet": a.out, "times": times, "labels": {f"#{i + 1}": t for i, t in enumerate(times)}}))
    elif a.cmd == "pointer":
        print(json.dumps(pointer_at(video, a.at)))
    elif a.cmd == "marks":
        print(json.dumps(marks(video), ensure_ascii=False))
    elif a.cmd == "grid":
        im = grab(video, a.at, 1920)
        info = grid_image(im, video, a.at)
        if a.crop:
            x0, y0, x1, y1 = _frac_box(a.crop, im.width, im.height)
            im = im.crop((max(0, x0), max(0, y0), min(im.width, x1), min(im.height, y1)))
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        im.save(a.out, quality=88)
        print(json.dumps({"grid": a.out, **info}))
    elif a.cmd == "grab":
        im = grab(video, a.at, a.max_width)
        d = ImageDraw.Draw(im)
        for b in a.box or []:
            x0, y0, x1, y1 = _frac_box(_stroke_box(video, a.at, 0.15) if b == "stroke" else b, im.width, im.height)
            d.rounded_rectangle([x0, y0, x1, y1], radius=6, outline="#ff2d2d", width=max(3, im.width // 400))
        for r in a.ring or []:
            draw_ring(im, *_point(r, video, a.at))
        if a.crop:
            x0, y0, x1, y1 = _frac_box(_stroke_box(video, a.at, 0.5, 0.45) if a.crop == "stroke" else a.crop, im.width, im.height)
            im = im.crop((max(0, x0), max(0, y0), min(im.width, x1), min(im.height, y1)))
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        im.save(a.out, quality=90)
        print(json.dumps({"frame": a.out, "t": a.at, "size": im.size}))
    elif a.cmd == "clip":
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        dur = max(0.5, a.end - a.start)
        r = subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-ss", f"{max(0, a.start):.2f}",
                            "-i", str(video), "-t", f"{dur:.2f}", "-vf", f"scale='min({a.max_width},iw)':-2",
                            "-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-pix_fmt", "yuv420p",
                            "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", a.out], capture_output=True)
        if r.returncode:
            die(r.stderr.decode(errors="replace")[-800:])
        print(json.dumps({"clip": a.out, "seconds": round(dur, 1), "mb": round(Path(a.out).stat().st_size / 2**20, 2)}))


if __name__ == "__main__":
    main()
