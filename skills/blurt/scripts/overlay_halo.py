"""Composite the halo disc into a finished Windows recording (post-process pass).

Every window-based halo on this machine froze in or vanished from real gdigrab
recordings, and the opaque-slice disc showed seams, jaggies and full occlusion
(user take 20260929-161905) — see blurt-recorder-machine-quirks #6. The reliable
path is a second ffmpeg pass: an antialiased, truly semi-transparent PNG disc
overlaid along the interpolated cursor track from events.jsonl. Smooth edge,
real 50% alpha, nothing to freeze — it is just pixels in the file.

Usage: uv run overlay_halo.py <session-dir>
Records recording.mp4 in place (the raw capture is kept as recording.raw.mp4,
so the halo can be re-composited with a different colour/size/opacity anytime).
Style: ~/.blurt/config.json → record.halo_color / halo_size / halo_opacity and
record.click_color / click_size / click_opacity for the click marker.

Click feedback is composited too (user take 20260929-181524: the live sliver
ring captured as jagged red blocks; a translucent solid disc "对AI来说会明确
一些"): a solid disc of click_color flashes at every click point for
CLICK_HOLD seconds, then parks off-frame. There is no live click window.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from _common import ffmpeg_bin, global_config, probe_duration, run

GAP = 0.25  # s of missing cursor points (left the region / paused): hide the disc, don't interpolate
CLICK_HOLD = 0.45  # s a click disc stays visible on its point


def _style() -> dict:
    rec = global_config().get("record", {}) or {}

    def _rgb(name: str, fallback: str):
        m = re.fullmatch(r"#?([0-9a-fA-F]{6})", str(rec.get(name) or fallback).strip())
        return tuple(int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4)) if m else None

    def _size(name: str, fallback: int) -> int:
        return max(18, int(rec.get(name) or fallback))

    def _opacity(name: str, fallback: float) -> float:
        v = float(rec.get(name, fallback))
        if v <= 0.0:
            return 0.0  # explicit 0 = marker off (click-only mode), don't clamp to 5%
        return min(1.0, max(0.05, v))

    return {
        "rgb": _rgb("halo_color", "#ff2fd6") or (0xFF, 0x2F, 0xD6),
        "size": _size("halo_size", 100), "opacity": _opacity("halo_opacity", 0.5),
        "click_rgb": _rgb("click_color", "#ff2d2d") or (0xFF, 0x2D, 0x2D),
        "click_size": _size("click_size", 56), "click_opacity": _opacity("click_opacity", 0.5),
    }


def _disc_png(path: Path, rgb, d: int, opacity: float) -> None:
    from PIL import Image, ImageDraw
    ss = 4  # supersample then LANCZOS down: smooth edge, no jaggies
    img = Image.new("RGBA", (d * ss, d * ss), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse((0, 0, d * ss - 1, d * ss - 1), fill=rgb + (round(255 * opacity),))
    img.resize((d, d), Image.LANCZOS).save(path)


def _badge_png(path: Path, rgb, d: int, opacity: float, n: int) -> None:
    """Persistent numbered marker badge (user take 20260930-052441: 圈/序号"不要掉") — the video-side
    twin of the recorder's live numbered flash: same translucent disc as the click marker, white number."""
    from PIL import Image, ImageDraw, ImageFont
    ss = 4
    img = Image.new("RGBA", (d * ss, d * ss), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    dr.ellipse((0, 0, d * ss - 1, d * ss - 1), fill=rgb + (round(255 * opacity),))
    font = None
    for fp in ("arialbd.ttf", "arial.ttf", "segoeui.ttf"):
        try:
            font = ImageFont.truetype(fp, size=int(d * ss * 0.5))
            break
        except OSError:
            continue
    dr.text((d * ss / 2, d * ss / 2), str(n), fill=(255, 255, 255, 240),
            font=font, anchor="mm")
    img.resize((d, d), Image.LANCZOS).save(path)


def _track(events_path: Path, rw: int, rh: int) -> list:
    pts = []
    for line in events_path.open(encoding="utf-8"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("type") == "cursor":
            pts.append((float(e["t"]), float(e["x"]) * rw, float(e["y"]) * rh))
    return pts


def _clicks(events_path: Path, rw: int, rh: int) -> list:
    out = []
    for line in events_path.open(encoding="utf-8"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("type") == "click":
            out.append((float(e["t"]), float(e["x"]) * rw, float(e["y"]) * rh))
    return out


def _drags(events_path: Path, rw: int, rh: int) -> list:
    """Press-drag boxes [(t, x0, y0, x1, y1)] in video px. The live marquee is a plain captured
    window that now persists after release, so the video already carries the box — the composite
    only uses these to tell drag-start clicks (no disc: the marquee marks them, user take
    20260930-064755 又多了个实心圆) apart from plain clicks."""
    out = []
    for line in events_path.open(encoding="utf-8"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("type") == "drag":
            out.append((float(e["t"]), float(e.get("x", 0)) * rw, float(e.get("y", 0)) * rh,
                        float(e.get("x2", 0)) * rw, float(e.get("y2", 0)) * rh))
    return out


def _markers(events_path: Path, rw: int, rh: int) -> list:
    """Numbered voice bookmarks (bar button / Alt+Shift+M). Old takes without n get sequence numbers."""
    out = []
    for line in events_path.open(encoding="utf-8"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("type") == "marker":
            out.append((float(e["t"]), int(e.get("n") or len(out) + 1),
                        float(e.get("x", 0.5)) * rw, float(e.get("y", 0.5)) * rh))
    out.sort()
    return out


def _sync(session: Path) -> list:
    """Per-segment [offset, delta] from the recorder: video time t inside segment k is event time
    t - offset_k + delta_k (the first frame exists delta after the event clock's zero — capture
    startup latency; without this the disc trails the drawn cursor during fast motion, ring13)."""
    try:
        segs = json.loads((session / "sync.json").read_text(encoding="utf-8")).get("segs") or []
    except Exception:
        return []
    out = []
    for s in segs:
        try:
            off, dlt = float(s[0]), float(s[1])
        except Exception:
            continue
        out.append((off, dlt if -5 <= dlt <= 5 else 0.0))
    return out


def overlay(session: Path, region=None, video_name: str = "recording.mp4") -> str | None:
    video = session / video_name
    events_path = session / "events.jsonl"
    if region is None:
        meta_path = session / "meta.json"
        if meta_path.exists():
            region = (json.loads(meta_path.read_text(encoding="utf-8")) or {}).get("region")
    if not (video.exists() and events_path.exists() and region and len(region) == 4):
        return None
    _, _, rw, rh = region
    st = _style()
    png, cpng, cmds, outv = (session / ".halo.png", session / ".click.png",
                             session / ".halo.cmds", session / ".halo.mp4")
    fps, W, H = 30.0, rw, rh
    try:
        pr = run([ffmpeg_bin("ffprobe"), "-v", "error", "-select_streams", "v:0",
                  "-show_entries", "stream=r_frame_rate,width,height", "-of", "default=nw=1", str(video)])
        kv = dict(l.split("=", 1) for l in pr.stdout.split() if "=" in l)
        num, den = kv.get("r_frame_rate", "30/1").split("/")
        fps = float(num) / float(den or 1) or 30.0
        W, H = int(kv.get("width", rw)), int(kv.get("height", rh))
    except Exception:
        pass
    # the recorder scales to max_width (2560): the video is NOT region-sized — map the cursor
    # fractions onto the real video dimensions and scale the disc to match
    d = max(24, round(st["size"] * W / rw))
    cd = max(18, round(st["click_size"] * W / rw))
    r = d / 2
    cr = cd / 2
    pts = _track(events_path, W, H)
    clicks = _clicks(events_path, W, H)
    drags = _drags(events_path, W, H)
    clicks_note = ""
    if drags and clicks:
        n0 = len(clicks)
        clicks = [c for c in clicks
                  if not any(0.0 <= dt - c[0] <= 0.6 and abs(dx0 - c[1]) <= 12 and abs(dy0 - c[2]) <= 12
                             for dt, dx0, dy0, _, _ in drags)]
        if len(clicks) < n0:
            clicks_note = f"; {n0 - len(clicks)} drag-start disc(s) skipped (marquee marks them)"
    markers = _markers(events_path, W, H)
    # halo_opacity 0 = click-only mode (take 212004: the click disc is the AI signal, the
    # cursor-following halo is noise). No halo, no clicks and no markers → leave the video untouched.
    halo_on = st["opacity"] > 0.01 and len(pts) >= 2
    if not halo_on and not clicks and not markers:
        return None
    if halo_on:
        _disc_png(png, st["rgb"], d, st["opacity"])
    else:
        png.unlink(missing_ok=True)
    _disc_png(cpng, st["click_rgb"], cd, st["click_opacity"])
    bd = max(26, round(cd * 1.1))
    br = bd / 2
    for mt, mn, mx, my in markers:
        _badge_png(session / f".mk{mn}.png", st["click_rgb"], bd, st["click_opacity"], mn)
    segs = _sync(session)
    # frame clock: NOT i/fps. gdigrab labels the stream 30fps but delivers frames at wallclock
    # pace — under encode load a "30fps" take actually advances ~28.4fps, and the CFR assumption
    # drifted up to 2.7s across a minute (user take 181524: the disc floated seconds off the
    # cursor and covered random text). Key every command to each frame's real pts instead.
    times: list[float] = []
    try:
        pr = run([ffmpeg_bin("ffprobe"), "-v", "error", "-select_streams", "v:0",
                  "-show_entries", "frame=pts_time", "-of", "csv=p=0", str(video)])
        for tok in pr.stdout.split():
            try:
                v = float(tok.strip().rstrip(","))
            except ValueError:
                continue
            if not times or v > times[-1]:
                times.append(v)
    except Exception:
        pass
    if len(times) < 2:
        dur = probe_duration(video) or 0.0
        times = [i / fps for i in range(max(2, int(dur * fps) + 1))]
    lines = []
    j = 0
    k = 0
    for t in times:
        et = t
        for off, dlt in segs:
            if t >= off:
                et = t - off + dlt
        cx = cy = -2 * cd
        clicking = False
        if clicks:
            while k + 1 < len(clicks) and clicks[k + 1][0] <= et:
                k += 1
            clicking = clicks[k][0] <= et < clicks[k][0] + CLICK_HOLD
            if clicking:
                cx, cy = clicks[k][1] - cr, clicks[k][2] - cr
        if halo_on:
            while j + 1 < len(pts) and pts[j + 1][0] <= et:
                j += 1
            x = y = -2 * d  # parked off-frame: no cursor data (outside region / paused)
            if pts[0][0] <= et <= pts[-1][0]:
                a, b = pts[j], pts[min(j + 1, len(pts) - 1)]
                if b[0] > a[0] and b[0] - a[0] <= GAP:
                    f = 0.0 if et <= a[0] else (et - a[0]) / (b[0] - a[0])
                    x, y = a[1] + (b[1] - a[1]) * f - r, a[2] + (b[2] - a[2]) * f - r
            if clicking:
                # the cursor sits on the click point: the two discs would stack
                # (30%+35% ≈ 55% effective) and read as one solid blob — take 202612
                # "那一下就压住了这个 control". The disc alone marks the spot.
                x = y = -2 * d
            lines.append(f"{t:.4f} overlay@halo x {x:.1f};")
            lines.append(f"{t:.4f} overlay@halo y {y:.1f};")
        if clicks:
            lines.append(f"{t:.4f} overlay@click x {cx:.1f};")
            lines.append(f"{t:.4f} overlay@click y {cy:.1f};")
        for mt, mn, mx, my in markers:
            # persistent numbered badge: parked before its marker time, on the spot afterwards
            bx = by = -2 * bd
            if et >= mt:
                bx, by = mx - br, my - br
            lines.append(f"{t:.4f} overlay@mk{mn} x {bx:.1f};")
            lines.append(f"{t:.4f} overlay@mk{mn} y {by:.1f};")
    cmds.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # run with cwd=session so bare filenames avoid ':' escaping inside the filtergraph;
    # only feed the inputs the current mode actually needs
    inputs = ["-i", "recording.mp4"]
    parts: list[str] = []
    idx = 1
    if halo_on:
        inputs += ["-loop", "1", "-i", ".halo.png"]
        parts.append(f"[{idx}]format=rgba[disc]")
        idx += 1
    if clicks:
        inputs += ["-loop", "1", "-i", ".click.png"]
        parts.append(f"[{idx}]format=rgba[cdisc]")
        idx += 1
    for mt, mn, mx, my in markers:
        inputs += ["-loop", "1", "-i", f".mk{mn}.png"]
        parts.append(f"[{idx}]format=rgba[mk{mn}]")
        idx += 1
    parts.append("[0]sendcmd=f=.halo.cmds[base]")
    prev = "[base]"
    if halo_on:
        parts.append(f"{prev}[disc]overlay@halo=x=0:y=0:shortest=1[v1]")
        prev = "[v1]"
    if clicks:
        parts.append(f"{prev}[cdisc]overlay@click=x=0:y=0:shortest=1[v2]")
        prev = "[v2]"
    for mt, mn, mx, my in markers:
        parts.append(f"{prev}[mk{mn}]overlay@mk{mn}=x=0:y=0:shortest=1[vn{mn}]")
        prev = f"[vn{mn}]"
    parts.append(f"{prev}format=yuv420p[v]")
    proc = run([ffmpeg_bin(), "-y", "-v", "error", *inputs,
                "-filter_complex", ";".join(parts),
                "-map", "[v]", "-map", "0:a?", "-c:v", "libx264", "-crf", "28", "-preset", "veryfast",
                "-c:a", "copy", ".halo.mp4"], check=False, cwd=str(session))
    if proc.returncode != 0 or not outv.exists() or outv.stat().st_size == 0:
        sys.stderr.write(proc.stderr or "halo overlay: ffmpeg failed\n")
        png.unlink(missing_ok=True)
        cpng.unlink(missing_ok=True)
        cmds.unlink(missing_ok=True)
        for _, mn, _, _ in markers:
            (session / f".mk{mn}.png").unlink(missing_ok=True)
        return None
    raw = session / "recording.raw.mp4"
    if not raw.exists():
        video.rename(raw)  # first composite: the input video IS the raw capture — keep it
        # (a re-composite must never overwrite the raw with a previous composite's pixels)
    os.replace(outv, video)
    png.unlink(missing_ok=True)
    cpng.unlink(missing_ok=True)
    cmds.unlink(missing_ok=True)
    for _, mn, _, _ in markers:
        (session / f".mk{mn}.png").unlink(missing_ok=True)
    what = (f"halo {st['rgb']} {d}px @{round(st['opacity'] * 100)}% along {len(pts)} cursor points"
            if halo_on else "cursor halo off (click-only)")
    return (f"halo: {what} ({len(times)} frames, pts-keyed)"
            + (f"; event-sync {segs[0][1]:+.2f}s" if segs else "")
            + (f"; click flash {len(clicks)}× {st['click_rgb']} {cd}px @{round(st['click_opacity'] * 100)}% for {CLICK_HOLD}s"
               if clicks else "; no clicks")
            + clicks_note
            + (f"; badges {len(markers)}× persistent" if markers else "")
            + "; raw capture kept as recording.raw.mp4")


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    note = overlay(Path(sys.argv[1]).resolve())
    print(note or "halo: nothing to composite (no region/cursor events)")


if __name__ == "__main__":
    main()
