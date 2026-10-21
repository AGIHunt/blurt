"""WP8 acceptance (CI, X11 under xvfb + openbox + xcompmgr): the overlay windows render, are transparent around what
they draw, and stay above a normal window opened after them.

  python3 crates/blurt-capture/ci/check_overlays.py DEMO_BINARY OUT_DIR

Runs `DEMO overlays` (the island open with three cards held by the claw, the note bubble, at their app positions), then
opens a blue full-screen Tk window, takes a root screenshot (ImageMagick `import`) and checks:
  • on top: the island's panel at the top centre and the middle of the note bubble are drawn (not blue);
  • transparent: the island window's empty corners show the blue window underneath;
  • _NET_WM_STATE has ABOVE (and SKIP_TASKBAR) on every overlay window.
Without a compositor the transparent parts are black, so this also fails if transparency is lost.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

BLUE = (0, 64, 255)


def is_blue(px) -> bool:
    return abs(px[0] - BLUE[0]) < 40 and abs(px[1] - BLUE[1]) < 40 and abs(px[2] - BLUE[2]) < 40


def main() -> int:
    demo, out = sys.argv[1], Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, WEBKIT_DISABLE_DMABUF_RENDERER="1", LIBGL_ALWAYS_SOFTWARE="1", GDK_BACKEND="x11")
    p = subprocess.Popen([demo, "overlays", "--seconds", "40"], env=env, stdout=subprocess.PIPE,
                         stderr=open(out / "demo.stderr.log", "w"), text=True)
    windows = None
    t0 = time.time()
    while time.time() - t0 < 90:
        line = p.stdout.readline()
        if not line:
            break
        print("demo:", line.strip(), flush=True)
        if line.startswith("{") and "windows" in line:
            windows = json.loads(line)["windows"]
            break
    if not windows:
        print((out / "demo.stderr.log").read_text()[-3000:])
        return fail("the demo printed no window rects")

    w, h = subprocess.run(["xdotool", "getdisplaygeometry"], capture_output=True, text=True).stdout.split()
    blue = subprocess.Popen([sys.executable, "-c", (
        "import tkinter as tk; r = tk.Tk(); r.title('blue'); "
        f"r.geometry('{w}x{h}+0+0'); r.configure(bg='#0040ff'); r.after(500, r.lift); r.mainloop()")])
    time.sleep(4)
    shot = out / "overlays.png"
    subprocess.run(["import", "-window", "root", str(shot)], check=True)
    states = {}
    for wid in subprocess.run(["xdotool", "search", "--name", "^Blurt$"], capture_output=True, text=True).stdout.split():
        states[wid] = subprocess.run(["xprop", "-id", wid, "_NET_WM_STATE"], capture_output=True, text=True).stdout.strip()
    blue.terminate()
    p.terminate()

    im = Image.open(shot).convert("RGB")
    problems = []

    def px(x, y):
        return im.getpixel((max(0, min(im.width - 1, int(x))), max(0, min(im.height - 1, int(y)))))

    if is_blue(px(5, 5)) is False and is_blue(px(im.width // 2, im.height // 2)) is False:
        problems.append("the blue window is not on screen (test setup)")
    for label, (x, y, ww, hh) in windows.items():
        mid = px(x + ww / 2, y + hh / 2)
        corner = px(x + 2, y + 2)
        print(label, (x, y, ww, hh), "middle", mid, "corner", corner)
        if label.endswith("island"):
            panel = px(x + ww / 2, y + 24)
            empty = [px(x + 6, y + hh - 6), px(x + ww - 6, y + hh - 6), px(x + 6, y + 6)]
            print(label, "panel", panel, "empty", empty)
            if is_blue(panel):
                problems.append(f"{label}: the island isn't drawn above the blue window")
            for e in empty:
                if not is_blue(e):
                    problems.append(f"{label}: empty area not transparent ({e})")
        if label.endswith("note") and is_blue(mid):
            problems.append(f"{label}: bubble not drawn above the blue window")
    if len(states) < 2:
        problems.append(f"expected 2 overlay windows titled Blurt, found {len(states)}")
    for wid, s in states.items():
        print("xprop", wid, s)
        if "_NET_WM_STATE_ABOVE" not in s:
            problems.append(f"window {wid} lacks _NET_WM_STATE_ABOVE: {s}")
        if "_NET_WM_STATE_SKIP_TASKBAR" not in s:
            problems.append(f"window {wid} lacks _NET_WM_STATE_SKIP_TASKBAR: {s}")
    print(json.dumps({"problems": problems}, indent=2))
    return 1 if problems else 0


def fail(msg: str) -> int:
    print("FAIL:", msg)
    return 1


if __name__ == "__main__":
    sys.exit(main())
