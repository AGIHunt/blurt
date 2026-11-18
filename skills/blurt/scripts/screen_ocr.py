# /// script
# requires-python = ">=3.11"
# dependencies = ["rapidocr==3.10.0", "onnxruntime==1.31.1", "numpy==2.3.4", "truststore==0.10.5"]
# ///
"""Copy Text from Screen's reading on Windows and Linux (docs/design/screen-text.md, docs/design/windows-models.md):
PP-OCRv6 tiny through RapidOCR on the CPU (onnxruntime), where the Mac reads with Apple Vision. The two models (6.3 MB,
PaddlePaddle's own ONNX exports) come down at the first use, from Hugging Face, or ModelScope first with the mirror on,
checked against their SHA-256, into $BLURT_HOME/models/ocr/PP-OCRv6-tiny; while neither site answers, it reads with
the v6 small models RapidOCR's wheel carries. Windows' own OCR (Windows.Media.Ocr) was
tried first and misread ordinary 11 pt Chinese UI text (登录页面 → 而面, 用 → 厍, 。 → O); the app keeps it as the
fall-back while this isn't installed yet.

Why v6 tiny, read at the picture's own size (tests/fixtures/screen_ocr: 13 crops of real GNOME / Windows UI and editor
text plus rendered Chinese, English and code; `screen_ocr.py eval`): 0.74% of characters wrong, where PP-OCRv4 mobile,
what shipped before, got 8.6% at the 2× it used (it glued English words: "Withacloud model set,itreads") and 3.9% at
1×; v6 small 0.63% at five times the size and 2.5× the time. Warm on 4 threads: v6 tiny 0.15–0.22 s, v4 0.37–0.54 s.
Numbers: docs/design/windows-models.md §Copy Text's reader.

Lines come back with their boxes; the app's rules (screen_text/rules.rs, the Mac's ScreenText) lay them out. The only
change made to the text: a space between Chinese / Japanese and Latin letters or digits, which the recogniser drops
(用ClaudeCode跑 → 用 ClaudeCode 跑) — a mechanical spacing rule, nothing read into the words.

  screen_ocr.py ocr IMAGE                 → {"ok", "lines": [{"text", "box": [x, y, w, h], "conf"}], "ms"}
  screen_ocr.py setup                     → the models, downloaded if missing: {"ok", "dir"}
  screen_ocr.py eval [DIR]                → character error rate over tests/fixtures/screen_ocr: {"ok", "cer", "cases"}
  screen_ocr.py serve [--parent PID] [--idle 600] [--preload]
      one JSON line in ({"token", "cmd": "ping" | "ocr" | "exit", "image"}), one out — polish.py serve's protocol;
      $BLURT_HOME/run/screen-ocr.json holds {pid, port, token, parent, started}
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import sys
import time
import uuid
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import (BLURT_HOME, MODELS_DIR, SERVE_IDLE, begin_download, download_lock, end_download, fetch,  # noqa: E402
                     folder_complete, global_config, load_json, save_json, serve_exit_reason, serve_said, use_system_certs,
                     write_text_atomic)

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


# PaddlePaddle's ONNX exports of PP-OCRv6 tiny, the same files on Hugging Face (at these commits) and ModelScope;
# rec.yml carries the recogniser's character list.
MODEL_DIR = MODELS_DIR / "ocr" / "PP-OCRv6-tiny"
MODEL_FILES = [
    {"path": "det.onnx", "repo": "PP-OCRv6_tiny_det_onnx", "rev": "2ba1506c0380b8f0b03dd142459aac66d4421f6c",
     "file": "inference.onnx", "size": 1780590,
     "sha256": "193bab7a04fca699a6c82e6abb5b81bdb28177f0abd4062552b04908dafb19f8"},
    {"path": "rec.onnx", "repo": "PP-OCRv6_tiny_rec_onnx", "rev": "2612ab37152ae0a677521bae4e1e3d4fb4cf7c30",
     "file": "inference.onnx", "size": 4462639,
     "sha256": "9ef676d6ed3c88256a2d92c640c44f25b0c40947e111b14b8be8f594091563e6"},
    {"path": "rec.yml", "repo": "PP-OCRv6_tiny_rec_onnx", "rev": "2612ab37152ae0a677521bae4e1e3d4fb4cf7c30",
     "file": "inference.yml", "size": 55571,
     "sha256": "66170210bad538e83fff3c4a3867e547d6bf20b50d64b20347c4b913f3034ea1"},
]


def mirror_on() -> bool:
    return bool(os.environ.get("BLURT_HF_MIRROR")) or bool((global_config().get("asr") or {}).get("hf_mirror"))


def model_urls(f: dict, mirror: bool) -> list[str]:
    """Where a model file comes from: Hugging Face at its pinned commit, ModelScope (first with the mirror on)."""
    hf = f"https://huggingface.co/PaddlePaddle/{f['repo']}/resolve/{f['rev']}/{f['file']}"
    ms = f"https://modelscope.cn/models/PaddlePaddle/{f['repo']}/resolve/master/{f['file']}"
    return [ms, hf] if mirror else [hf, ms]


def sha256_of(p) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        while chunk := fh.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def ensure_models(d=None) -> "os.PathLike":
    """The models in `d` (MODEL_DIR), downloaded the first time; a file whose hash doesn't match is not kept."""
    d = d or MODEL_DIR
    if folder_complete(d):
        return d
    with download_lock("ocr-PP-OCRv6-tiny"):
        if folder_complete(d):
            return d
        begin_download(d, MODEL_FILES)
        mirror = mirror_on()
        for f in MODEL_FILES:
            dest = d / f["path"]
            if dest.is_file() and dest.stat().st_size == f["size"]:
                continue
            tmp = d / (f["path"] + ".part")
            last = None
            for url in model_urls(f, mirror):
                try:
                    fetch(url, tmp, f["size"], timeout=30)
                    if sha256_of(tmp) == f["sha256"]:
                        os.replace(tmp, dest)
                        break
                    last = f"{url}: SHA-256 doesn't match"
                except OSError as e:  # urllib's errors are OSErrors
                    last = f"{url}: {e}"
                tmp.unlink(missing_ok=True)
            else:
                raise Fail(f"could not download the text reader ({f['path']}): {last}", "network")
        end_download(d)
    return d


def keys_file(d) -> "os.PathLike":
    """The recogniser's characters, one per line, from rec.yml (what RapidOCR reads)."""
    keys = d / "keys.txt"
    if not keys.is_file():
        import yaml  # noqa: PLC0415 — RapidOCR's own dependency
        chars = yaml.safe_load((d / "rec.yml").read_text(encoding="utf-8"))["PostProcess"]["character_dict"]
        write_text_atomic(keys, "\n".join(str(c) for c in chars) + "\n")
    return keys


def spaced(text: str) -> str:
    """A space between CJK and Latin letters / digits (the recogniser drops it)."""
    return _SPACE_B.sub(r"\1 \2", _SPACE_A.sub(r"\1 \2", text))


class Engine:
    def __init__(self):
        self.ocr = None
        self.last = time.time()
        self.load_ms = 0
        self.fallback = False

    def load(self):
        if self.ocr is None:
            t0 = time.perf_counter()
            from rapidocr import ModelType, OCRVersion, RapidOCR  # noqa: PLC0415
            v6 = OCRVersion.PPOCRV6
            params = {"Global.use_cls": False,  # screen text is never upside down
                      "Det.ocr_version": v6, "Rec.ocr_version": v6}
            try:
                d = ensure_models()
                params.update({"Det.model_type": ModelType.TINY, "Det.model_path": str(d / "det.onnx"),
                               "Rec.model_type": ModelType.TINY, "Rec.model_path": str(d / "rec.onnx"),
                               "Rec.rec_keys_path": str(keys_file(d))})
            except (Fail, OSError, ValueError, KeyError) as e:
                # neither site answers: v6 small, which comes in RapidOCR's wheel (as accurate, ~2.5× slower)
                print(f"screen_ocr: reading with the bundled v6 small model ({e})", file=sys.stderr, flush=True)
                params.update({"Det.model_type": ModelType.SMALL, "Rec.model_type": ModelType.SMALL})
                self.fallback = True
            self.ocr = RapidOCR(params=params)
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
        r = self.ocr(img)
        self.last = time.time()
        lines = []
        for box, text, conf in zip(r.boxes if r.boxes is not None else [], r.txts or [], r.scores or []):
            xs, ys = [float(p[0]) for p in box], [float(p[1]) for p in box]
            lines.append({"text": spaced(str(text)), "box": [round(min(xs), 1), round(min(ys), 1), round(max(xs) - min(xs), 1),
                                                              round(max(ys) - min(ys), 1)], "conf": round(float(conf), 3)})
        lines.sort(key=lambda r: (r["box"][1], r["box"][0]))
        return {"ok": True, "lines": lines, "ms": int((time.perf_counter() - t0) * 1000), "load_ms": self.load_ms,
                "model": "PP-OCRv6 small (bundled)" if self.fallback else "PP-OCRv6 tiny"}


def cmd_ocr(a):
    emit(Engine().read(a.image))


FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "fixtures", "screen_ocr")


def rows(lines: list[dict]) -> str:
    """The boxes as text rows (a box joins the row whose middle it shares), left to right — enough to score the
    reader; the app's own layout is screen_text/rules.rs."""
    out: list[list] = []
    for ln in sorted(lines, key=lambda r: r["box"][1] + r["box"][3] / 2):
        x, y, w, h = ln["box"]
        if out and abs(y + h / 2 - out[-1][0]) < h / 2:
            out[-1][1].append((x, ln["text"]))
        else:
            out.append([y + h / 2, [(x, ln["text"])]])
    wide = re.compile(r"[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]")
    text = []
    for _, parts in out:
        row = ""
        for _, t in sorted(parts):
            t = t.strip()
            if row and t and not (wide.match(row[-1]) or wide.match(t[0])):
                row += " "
            row += t
        text.append(row)
    return "\n".join(text)


def edits(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cmd_eval(a):
    """Character error rate over tests/fixtures/screen_ocr (cases.jsonl: image, text), whitespace runs as one space."""
    eng, errs, total, cases = Engine(), 0, 0, []
    norm = lambda t: re.sub(r"\s+", " ", t).strip()  # noqa: E731
    with open(os.path.join(a.dir, "cases.jsonl"), encoding="utf-8") as fh:
        for row in filter(str.strip, fh):
            c = json.loads(row)
            r = eng.read(os.path.join(a.dir, c["image"]))
            got, want = norm(rows(r["lines"])), norm(c["text"])
            e = edits(got, want)
            errs, total = errs + e, total + len(want)
            cases.append({"image": c["image"], "errors": e, "ms": r["ms"], **({"read": got} if e else {})})
    emit({"ok": True, "model": "PP-OCRv6 small (bundled)" if eng.fallback else "PP-OCRv6 tiny",
          "cer": round(100 * errs / max(total, 1), 2), "errors": errs, "chars": total, "cases": cases})


def cmd_setup(a):
    emit({"ok": True, "dir": str(ensure_models())})


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
    sub.add_parser("setup")
    ev = sub.add_parser("eval")
    ev.add_argument("dir", nargs="?", default=FIXTURES)
    s = sub.add_parser("serve")
    s.add_argument("--parent", type=int)
    s.add_argument("--idle", type=float, default=SERVE_IDLE)
    s.add_argument("--exit-after", type=float, default=120)
    s.add_argument("--preload", action="store_true")
    a = ap.parse_args()
    try:
        {"ocr": cmd_ocr, "setup": cmd_setup, "eval": cmd_eval, "serve": cmd_serve}[a.cmd](a)
    except Fail as e:
        emit({"ok": False, "error": str(e), "code": e.code})
        sys.exit(1)


if __name__ == "__main__":
    main()
