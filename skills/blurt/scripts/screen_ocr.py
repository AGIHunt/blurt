# /// script
# requires-python = ">=3.10"
# dependencies = ["rapidocr-onnxruntime==1.4.4", "truststore==0.10.5"]
# ///
"""Copy Text from Screen's reading on Windows and Linux (docs/design/screen-text.md, docs/design/windows-models.md):
PP-OCRv4 through RapidOCR on the CPU (onnxruntime; the models come in its wheel, ~15 MB), where the Mac reads with
Apple Vision. Windows' own OCR (Windows.Media.Ocr) was tried first and misread ordinary 11 pt Chinese UI text
(登录页面 → 而面, 用 → 厍, 。 → O on the same three lines this reads right, 0.33 s warm on 4 Zen 4 threads). The app
keeps Windows' OCR as the fall-back while this isn't installed yet.

Lines come back with their boxes; the app's rules (screen_text/rules.rs, the Mac's ScreenText) lay them out. The only
change made to the text: a space between Chinese / Japanese and Latin letters or digits, which the recogniser drops
(用ClaudeCode跑 → 用 ClaudeCode 跑) — a mechanical spacing rule, nothing read into the words.

  screen_ocr.py ocr IMAGE                 → {"ok", "lines": [{"text", "box": [x, y, w, h], "conf"}], "ms"}
  screen_ocr.py serve [--parent PID] [--idle 600] [--preload]
      one JSON line in ({"token", "cmd": "ping" | "ocr" | "exit", "image"}), one out — polish.py serve's protocol;
      $BLURT_HOME/run/screen-ocr.json holds {pid, port, token, parent, started}
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import time
import uuid
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import BLURT_HOME, SERVE_IDLE, load_json, save_json, serve_exit_reason, serve_said, use_system_certs  # noqa: E402

use_system_certs()


class Fail(Exception):
    def __init__(self, message: str, code: str = "error"):
        super().__init__(message)
        self.code = code


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)

RUN_DIR = BLURT_HOME / "run"
SERVE_FILE = RUN_DIR / "screen-ocr.json"
_CJK = r"぀-ヿ㐀-䶿一-鿿豈-﫿"
_SPACE_A = re.compile(rf"([{_CJK}])([A-Za-z0-9])")
_SPACE_B = re.compile(rf"([A-Za-z0-9])([{_CJK}])")


# A small selection is read at twice its size: PP-OCR's recogniser loses the spaces between English words in ~11 pt
# screen text ("the savebuttondoes nothing" off Notepad on the test VM; "the save button does nothing" at 2×). Up to
# this many pixels before scaling (a 1100×110 selection: ~2× more work, still well under 0.5 s warm).
UPSCALE_MAX_PX = 1_500_000


def upscale_factor(w: int, h: int) -> int:
    """2 for a selection small enough to read at twice its size, else 1."""
    return 2 if 0 < w * h <= UPSCALE_MAX_PX else 1


def spaced(text: str) -> str:
    """A space between CJK and Latin letters / digits (the recogniser drops it)."""
    return _SPACE_B.sub(r"\1 \2", _SPACE_A.sub(r"\1 \2", text))


class Engine:
    def __init__(self):
        self.ocr = None
        self.last = time.time()
        self.load_ms = 0

    def load(self):
        if self.ocr is None:
            t0 = time.perf_counter()
            from rapidocr_onnxruntime import RapidOCR  # noqa: PLC0415
            self.ocr = RapidOCR()
            self.load_ms = int((time.perf_counter() - t0) * 1000)
        return self

    def read(self, image: str) -> dict:
        if not image or not os.path.isfile(image):
            raise Fail(f"no image: {image}", "usage")
        self.load()
        t0 = time.perf_counter()
        import cv2  # noqa: PLC0415 — RapidOCR's own dependencies
        import numpy as np  # noqa: PLC0415
        # (imdecode, not imread: imread can't open a path with non-ASCII characters on Windows — a Chinese user name)
        img = cv2.imdecode(np.fromfile(image, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            raise Fail(f"unreadable image: {image}", "usage")
        k = upscale_factor(img.shape[1], img.shape[0])
        if k > 1:
            img = cv2.resize(img, None, fx=k, fy=k, interpolation=cv2.INTER_CUBIC)
        res, _ = self.ocr(img)
        self.last = time.time()
        lines = []
        for box, text, conf in res or []:
            xs, ys = [p[0] / k for p in box], [p[1] / k for p in box]
            lines.append({"text": spaced(str(text)), "box": [round(min(xs), 1), round(min(ys), 1), round(max(xs) - min(xs), 1),
                                                              round(max(ys) - min(ys), 1)], "conf": round(float(conf), 3)})
        lines.sort(key=lambda r: (r["box"][1], r["box"][0]))
        return {"ok": True, "lines": lines, "ms": int((time.perf_counter() - t0) * 1000), "load_ms": self.load_ms}


def cmd_ocr(a):
    emit(Engine().read(a.image))


def _server_call(req: dict, timeout: float) -> dict | None:
    info = load_json(SERVE_FILE, None)
    if not isinstance(info, dict) or not info.get("port"):
        return None
    try:
        with socket.create_connection(("127.0.0.1", int(info["port"])), timeout=0.3) as s:
            s.settimeout(timeout)
            s.sendall((json.dumps({**req, "token": info.get("token")}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf) if buf else None
    except (OSError, ValueError):
        return None


def cmd_serve(a):
    if (r := _server_call({"cmd": "ping"}, timeout=2)) and r.get("ok"):
        return emit({"ok": True, "already": True, "pid": r.get("pid")})
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    srv.settimeout(1.0)
    port = srv.getsockname()[1]
    save_json(SERVE_FILE, {"pid": os.getpid(), "port": port, "token": token, "parent": a.parent,
                           "started": datetime.now().astimezone().isoformat(timespec="seconds")})
    eng = Engine()
    why = None
    try:
        if a.preload:
            eng.load()
        last = time.time()
        uses: list[float] = []
        while not why:
            now = time.time()
            why = serve_exit_reason(eng.ocr is not None, now - eng.last, now - last, uses, "standard", a.idle,
                                    a.exit_after, a.parent)
            if why:
                break
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            with conn:
                conn.settimeout(10)
                try:
                    buf = b""
                    while not buf.endswith(b"\n") and len(buf) < 1 << 20:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                    req = json.loads(buf or b"{}")
                    if req.get("token") != token:
                        resp = {"ok": False, "error": "bad token", "code": "auth"}
                    elif req.get("cmd") == "ping":
                        resp = {"ok": True, "pid": os.getpid(), "loaded": eng.ocr is not None}
                    elif req.get("cmd") == "ocr":
                        last = time.time()
                        uses.append(last)
                        del uses[:-50]
                        resp = eng.read(str(req.get("image") or ""))
                    elif req.get("cmd") == "exit":
                        resp = {"ok": True, "pid": os.getpid()}
                        why = "asked"
                    else:
                        resp = {"ok": False, "error": "unknown cmd", "code": "usage"}
                except Fail as e:
                    resp = {"ok": False, "error": str(e), "code": e.code}
                except Exception as e:  # noqa: BLE001 — keep serving
                    resp = {"ok": False, "error": f"{type(e).__name__}: {e}"[:300], "code": "error"}
                try:
                    conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode())
                except OSError:
                    pass
    finally:
        info = load_json(SERVE_FILE, None)
        if isinstance(info, dict) and info.get("pid") == os.getpid():
            SERVE_FILE.unlink(missing_ok=True)
        srv.close()
        serve_said(f"serve: exiting ({why or 'error'})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("ocr")
    o.add_argument("image")
    s = sub.add_parser("serve")
    s.add_argument("--parent", type=int)
    s.add_argument("--idle", type=float, default=SERVE_IDLE)
    s.add_argument("--exit-after", type=float, default=120)
    s.add_argument("--preload", action="store_true")
    a = ap.parse_args()
    try:
        {"ocr": cmd_ocr, "serve": cmd_serve}[a.cmd](a)
    except Fail as e:
        emit({"ok": False, "error": str(e), "code": e.code})
        sys.exit(1)


if __name__ == "__main__":
    main()
