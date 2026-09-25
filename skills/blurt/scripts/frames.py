# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""Frame tools for screen recordings. The agent decides *which* moments matter; this script makes it cheap to look.

  frames.py scan  VIDEO                         build a visual-activity index (scan.npz) at 2 fps, once per video
  frames.py candidates VIDEO --from S --to E    suggest diverse, settled frame times inside a window (JSON)
  frames.py sheet VIDEO --from S --to E -o x.jpg   contact sheet of candidates with timestamps (one image to review)
  frames.py sheet VIDEO --at 12.5 14 20 -o x.jpg   contact sheet of explicit times
  frames.py grab  VIDEO --at T -o x.jpg [--box x,y,w,h] [--crop x,y,w,h]   full-res frame, optional red box / crop
  frames.py clip  VIDEO --from S --to E -o x.mp4   small shareable clip (with audio)

Coordinates for --box/--crop are fractions (0-1) of width/height, so they work at any resolution.
"""
from __future__ import annotations

import argparse
import json
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
    g = sub.add_parser("grab")
    g.add_argument("video")
    g.add_argument("--at", type=float, required=True)
    g.add_argument("-o", "--out", required=True)
    g.add_argument("--box", action="append", help="x,y,w,h (fractions or px) to outline in red; repeatable")
    g.add_argument("--crop", help="x,y,w,h (fractions or px) to crop to, applied after boxes")
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
    elif a.cmd == "grab":
        im = grab(video, a.at, a.max_width)
        d = ImageDraw.Draw(im)
        for b in a.box or []:
            x0, y0, x1, y1 = _frac_box(b, im.width, im.height)
            d.rounded_rectangle([x0, y0, x1, y1], radius=6, outline="#ff2d2d", width=max(3, im.width // 400))
        if a.crop:
            x0, y0, x1, y1 = _frac_box(a.crop, im.width, im.height)
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
