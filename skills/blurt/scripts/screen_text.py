# /// script
# requires-python = ">=3.10"
# dependencies = ["truststore==0.10.5"]
# ///
"""Copy Text from Screen's second pass (docs/design/screen-text.md). The app copies Vision's reading at once (BlurtCore
ScreenText: what the edges cut left out, wrapped lines joined, lists, tables and code kept); this reads the same picture
again with a small OCR model (PaddleOCR-VL 1.6, 0.9 B, MLX, ~0.3 s warm on an M5 Max) and merges the two:

  the draft decides which lines there are and how they are laid out — its markers, indentation and line breaks; the
  model decides the characters inside a line it read too: l / I / /, 0 / O / @, [ read as I, missing → and ·, the
  backticks and underscores of code. Never taken from the model: a line the draft doesn't have (the model writes out
  the half line the edge cut: 网关数掂米果…), ideographs and CJK punctuation where the two disagree (one of them
  guessed: the draft's stay), a space the draft saw, Markdown it added (**, `), LaTeX ($\\to$), a dash's style.

Measured (tests/fixtures/screen_text, 17 crops, M5 Max): the draft 0.74 % of characters wrong, merged 0.27 %; the
model alone 13.5 % (the cut lines it invents). Gemma 4 E2B (the polish model, it has a vision tower) was tried first and
rewrote Chinese words (访问 → 调用): not for this.

  screen_text.py models                                    the model, whether it is installed, its path
  screen_text.py setup [--parent PID]                      download it ("  N/M MB" lines on stderr; the mirror when on)
  screen_text.py serve [--preload] [--idle 600] [--parent PID]   keep it warm (127.0.0.1; $BLURT_HOME/run/screen-text-serve.json)
  screen_text.py read --image PNG [--draft T | --draft-file F] [--no-server] [--stdin] [--cloud deepseek …]
        → {"ok","text","raw","changed","ms","load_ms"}   (text = the merge; without a draft: the model's own reading)
  screen_text.py merge --draft-file D --model-file M      the merge alone (no model)
  screen_text.py eval [--set DIR]                         the fixture set through Vision's drafts (needs the app's
                                                          drafts in DIR/drafts/*.txt) and the model: error rates, time

Config: record.screen_text.refine (true once the model is installed and the user turned it on; Settings → General).
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import socket
import sys
import time
import unicodedata
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (BLURT_HOME, MODELS_DIR, SERVE_IDLE, download_lock, load_json, save_json,  # noqa: E402
                     server_exit, serve_exit_reason, serve_said, watch_parent)

HERE = Path(__file__).parent
RUN_DIR = BLURT_HOME / "run"
SERVE_FILE = RUN_DIR / "screen-text-serve.json"
MODEL_DIR = MODELS_DIR / "screen_text"
MLX_VLM_PACKAGE = "mlx-vlm==0.7.11"      # pinned: bumped on purpose, per release
MODEL = {"id": "paddleocr-vl-1.6", "name": "PaddleOCR-VL 1.6", "repo": "mlx-community/PaddleOCR-VL-1.6-4bit",
         "size_mb": 720, "prompt": "OCR:"}
MAX_PIXELS = 4_000_000      # a bigger capture (a whole Retina screen) is left as the draft: seconds, not a moment
MAX_DRAFT = 3000            # characters


class Fail(Exception):
    def __init__(self, message: str, code: str = "error", exit_code: int = 1):
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


# ------------------------------------------------------------------ the merge (pure, no model)
def is_han(c: str) -> bool:
    return 0x3400 <= ord(c) <= 0x9FFF or 0xF900 <= ord(c) <= 0xFAFF or 0x20000 <= ord(c) <= 0x2FFFF


def is_key_symbol(c: str) -> bool:
    """⌘ ⌥ ⌃ ⎋ ⌫ ⏎ (Miscellaneous Technical) and ⇧ ⇥ ↩ → (Arrows): what every OCR engine misreads as letters or
    ideographs (Vision: ⌥⇧T → T个T, ⌘⇧4 → 214) and a vision model sometimes gets right."""
    return 0x2190 <= ord(c) <= 0x21FF or 0x2300 <= ord(c) <= 0x23FF


def is_cjk_punct(c: str) -> bool:
    return 0x3000 <= ord(c) <= 0x303F or 0xFF00 <= ord(c) <= 0xFF65


DASHES = set("-–—‐−")
# the draft's own line start: indentation, then "- ", "N. ", "a. " (ScreenText writes markers that way)
DRAFT_LEAD = re.compile(r"^(\s*)(- |\d{1,3}[.)、] |[a-zA-Z][.)] )?")
# the model's: any one or two symbols and a space (•, ◦, ♡ for a check icon…), a number, a letter
MODEL_LEAD = re.compile(r"^\s*([^\w\s一-鿿]{1,2}\s|\d{1,3}[.)、]\s*|[a-zA-Z][.)]\s)?")


def _key(s: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", s))


def _opcodes(a: str, b: str) -> list[tuple]:
    """difflib's edits with a delete next to an insert made one replace (difflib may split "!" → '"' in two)."""
    out: list[list] = []
    for op, a0, a1, b0, b1 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if out and {op, out[-1][0]} <= {"delete", "insert", "replace"} and op != "equal" and out[-1][0] != "equal":
            out[-1] = ["replace", out[-1][1], a1, out[-1][3], b1]
        else:
            out.append([op, a0, a1, b0, b1])
    return [tuple(o) for o in out]


def merge_line(d: str, m: str) -> str:
    """The draft's line with the model's characters where the two read the same line differently (rules: above)."""
    lead = DRAFT_LEAD.match(d)
    prefix, dbody = lead.group(0), d[len(lead.group(0)):]
    mbody = m[len(MODEL_LEAD.match(m).group(0)):] if lead.group(2) else m.strip()
    if prefix and not prefix.strip() and m[:1] == " ":       # code: the model's indentation (it counts characters)
        prefix = m[:len(m) - len(m.lstrip(" "))]
    out = []
    for op, a0, a1, b0, b1 in _opcodes(dbody, mbody):
        da, mb = dbody[a0:a1], mbody[b0:b1]
        if op == "replace" and mb.strip() and all(is_key_symbol(c) or c.isspace() for c in mb) and len(da) <= 3 * len(mb):
            out.append(mb)          # key symbols where the draft has the garbage they were read as
            continue
        keep = op == "equal" \
            or (op == "delete" and not re.fullmatch(r"[\s.,;:'\"`·•]+", da)) \
            or (op == "replace" and len(da) > 3 and len(mb) < len(da) / 2) \
            or (op == "insert" and (a0 == 0 or a0 == len(dbody)) and any(c.isalnum() for c in mb)) \
            or any(is_han(c) or is_cjk_punct(c) for c in da + mb) \
            or (set(da) <= DASHES and set(mb) <= DASHES) \
            or "$" in mb or ("\\" in mb and "\\" not in dbody) \
            or ("*" in mb and "*" not in dbody) or ("`" in mb and "`" not in dbody) \
            or (da and not da.strip())          # the draft's spacing (tabs between cells, indentation) is its layout
        out.append(da if keep else mb)
    return prefix + "".join(out)


def merge(draft: str, model: str) -> tuple[str, int]:
    """(merged text, lines changed). Each draft line is paired with the model's line — or a run of consecutive lines,
    when the model kept the wrapping the draft joined — that reads most like it (at least 70 % alike); unpaired lines
    stay. Inside a pair, never taken: a deletion (the model left out what the draft saw), a much shorter replacement,
    a letter or digit inserted at the line's start or end (how a character the edge cut comes back), and the rules above."""
    D = draft.split("\n")
    M = [l for l in (model or "").strip().split("\n") if l.strip()]
    # each model line, and runs of up to 8 consecutive ones (the model kept the screen's wrapping, the draft joined it)
    cands = [" ".join(x.strip() for x in M[j:j + n]) if n > 1 else M[j] for n in range(1, 9) for j in range(len(M) - n + 1)]
    keys = [_key(MODEL_LEAD.sub("", c)) for c in cands]
    out, changed = [], 0
    for d in D:
        dk = _key(DRAFT_LEAD.sub("", d))
        if not dk:
            out.append(d)
            continue
        best, bi = 0.0, -1
        for i, k in enumerate(keys):
            if not k:
                continue
            sm = difflib.SequenceMatcher(None, dk, k, autojunk=False)
            if sm.real_quick_ratio() < best or sm.quick_ratio() < best:
                continue
            r = sm.ratio()
            if r > best:
                best, bi = r, i
        new = merge_line(d, cands[bi]) if bi >= 0 and best >= 0.7 else d
        changed += new != d
        out.append(new)
    return "\n".join(out), changed


# ------------------------------------------------------------------ the model
@contextmanager
def _polish_dirs():
    """polish.py's downloader (Hugging Face / ModelScope, resumable, complete-only) pointed at our folder."""
    import polish
    saved = polish.POLISH_DIR
    polish.POLISH_DIR = MODEL_DIR
    try:
        yield polish
    finally:
        polish.POLISH_DIR = saved


def model_path() -> Path | None:
    with _polish_dirs() as polish:
        return polish.model_path(MODEL)


def supported() -> bool:
    import platform
    return sys.platform == "darwin" and platform.machine() == "arm64"


def ensure_vlm() -> None:
    """mlx-vlm is only needed to run the model: re-run under `uv run --with mlx-vlm` when it is missing."""
    import importlib.util
    if importlib.util.find_spec("mlx_vlm") is not None:
        return
    if not supported():
        raise Fail("the OCR model needs Apple Silicon (MLX)", "unsupported", 4)
    import shutil
    uv = shutil.which("uv") or str(BLURT_HOME / "bin" / "uv")
    if os.environ.get("BLURT_SCREEN_TEXT_REEXEC") or not Path(uv).exists() or not sys.argv[0].endswith(".py"):
        raise Fail(f"mlx-vlm is not installed (run with: uv run --with {MLX_VLM_PACKAGE} {Path(sys.argv[0]).name} …)", "deps", 4)
    os.environ["BLURT_SCREEN_TEXT_REEXEC"] = "1"
    with _polish_dirs() as polish:
        if polish.mirror_on():
            os.environ.setdefault("UV_DEFAULT_INDEX", "https://mirrors.aliyun.com/pypi/simple/")
    sys.stdout.flush()
    sys.stderr.flush()
    os.execvp(uv, [uv, "run", "-q", "--with", MLX_VLM_PACKAGE, os.path.abspath(sys.argv[0]), *sys.argv[1:]])


class Engine:
    def __init__(self):
        self.model = self.proc = None
        self.load_ms = 0
        self.last = time.time()

    def load(self) -> None:
        if self.model is not None:
            return
        p = model_path()
        if not p:
            raise Fail("the OCR model is not installed (screen_text.py setup)", "no_model")
        os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
        t0 = time.time()
        from mlx_vlm import load
        self.model, self.proc = load(str(p), trust_remote_code=True)
        import mlx.core as mx
        mx.set_cache_limit(64 << 20)       # as polish.py: what MLX keeps between requests stays small
        self.load_ms = int((time.time() - t0) * 1000)

    def read(self, image: str, draft: str | None) -> dict:
        from PIL import Image
        with Image.open(image) as im:
            w, h = im.size
        if w * h > MAX_PIXELS or len(draft or "") > MAX_DRAFT:
            return {"ok": True, "text": draft or "", "raw": None, "changed": 0, "skipped": "large", "ms": 0, "load_ms": 0}
        loaded = self.model is None
        self.load()
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template
        prompt = apply_chat_template(self.proc, self.model.config, MODEL["prompt"], num_images=1)
        # room for the draft's length and some (the model may read a little the draft left out), never runaway
        budget = min(2048, 64 + 2 * len(draft)) if draft else 1024
        t0 = time.time()
        r = generate(self.model, self.proc, prompt, [image], max_tokens=budget, temperature=0.0, verbose=False)
        raw = (r.text if hasattr(r, "text") else str(r)).strip()
        ms = int((time.time() - t0) * 1000)
        import mlx.core as mx
        mx.clear_cache()
        self.last = time.time()
        if draft is None:
            return {"ok": True, "text": raw, "raw": raw, "changed": 0, "ms": ms, "load_ms": self.load_ms if loaded else 0}
        text, changed = merge(draft, raw)
        return {"ok": True, "text": text, "raw": raw, "changed": changed, "ms": ms, "load_ms": self.load_ms if loaded else 0}


# ------------------------------------------------------------------ the cloud (the user's own provider and key)
CLOUD_PROMPT = ("Transcribe all the text in this screenshot exactly as written, in reading order: one line per line of "
                "text, code with its indentation, table cells separated by tabs. No Markdown, no notes: the text only.")


def read_cloud(cloud: dict, image: str, draft: str | None, timeout: float = 20) -> dict:
    """The same reading through the model the user set up for cloud polish (polish_cloud.py: DeepSeek, or any OpenAI-
    or Anthropic-compatible API; the key comes with the request, from the app's Keychain, never from a file), then the
    same merge. Raises polish_cloud.CloudError (auth | rate_limited | timeout | network | server | config | empty)."""
    import base64
    import polish_cloud
    cfg = polish_cloud.settings(cloud)
    if not cfg["key"]:
        raise polish_cloud.CloudError("no key", "config")
    from_bytes = Path(image).read_bytes()
    b64 = base64.b64encode(from_bytes).decode()
    if cfg["protocol"] == "anthropic":
        content = [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}},
                   {"type": "text", "text": CLOUD_PROMPT}]
    else:
        content = [{"type": "text", "text": CLOUD_PROMPT},
                   {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]
    budget = min(4096, 200 + 3 * len(draft)) if draft else 2048
    r = polish_cloud.complete(cfg, [{"role": "user", "content": content}], timeout, budget)
    raw = re.sub(r"^```\w*\n|\n```$", "", r["text"].strip())
    text, changed = merge(draft, raw) if draft is not None else (raw, 0)
    return {"ok": True, "text": text, "raw": raw, "changed": changed, "ms": r["ms"], "load_ms": 0, "cloud": True,
            "usage": r.get("usage") or {}}


# ------------------------------------------------------------------ the server
def _server_call(req: dict, timeout: float) -> dict | None:
    info = load_json(SERVE_FILE, None)
    if not isinstance(info, dict) or not info.get("port"):
        return None
    try:
        with socket.create_connection(("127.0.0.1", int(info["port"])), timeout=0.3) as s:
            s.settimeout(timeout)
            s.sendall((json.dumps({**req, "token": info.get("token")}, ensure_ascii=False) + "\n").encode())
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
    """One warm OCR model per machine. One JSON line in ({"token","cmd":"ping"|"load"|"read"|"exit",…}), one out —
    polish.py serve's protocol; it ends as that one does (the model unused for --idle s, the --parent app gone, exit)."""
    if (r := _server_call({"cmd": "ping"}, timeout=2)) and r.get("ok"):
        return emit({"ok": True, "already": True, "pid": r.get("pid")})
    ensure_vlm()
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
        emit({"ok": True, "pid": os.getpid(), "port": port, "loaded": eng.model is not None})
        last = time.time()
        uses: list[float] = []
        while not why:
            now = time.time()
            why = serve_exit_reason(eng.model is not None, now - eng.last, now - last, uses, "standard", a.idle,
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
                    while not buf.endswith(b"\n") and len(buf) < 1 << 22:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                    req = json.loads(buf or b"{}")
                    if req.get("token") != token:
                        resp = {"ok": False, "error": "bad token", "code": "auth"}
                    elif req.get("cmd") == "ping":
                        resp = {"ok": True, "pid": os.getpid(), "loaded": eng.model is not None}
                    elif req.get("cmd") == "load":
                        last = time.time()
                        eng.load()
                        eng.last = time.time()
                        resp = {"ok": True, "load_ms": eng.load_ms}
                    elif req.get("cmd") == "read":
                        last = time.time()
                        uses.append(last)
                        del uses[:-50]
                        if req.get("cloud"):
                            import polish_cloud
                            try:
                                resp = read_cloud(req["cloud"], str(req.get("image") or ""), req.get("draft"))
                            except polish_cloud.CloudError as e:
                                resp = {"ok": False, "error": str(e), "code": e.code, "cloud": True}
                        else:
                            resp = eng.read(str(req.get("image") or ""), req.get("draft"))
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


# ------------------------------------------------------------------ commands
def cmd_models(a):
    p = model_path()
    emit({"ok": True, "model": MODEL, "installed": p is not None, "path": str(p) if p else None, "supported": supported()})


def cmd_setup(a):
    watch_parent(getattr(a, "parent", None))
    if not supported():
        raise Fail("the OCR model needs Apple Silicon (MLX)", "unsupported")
    ensure_vlm()        # mlx-vlm is fetched with the model, so the first ⌥⇧C after it isn't a package download
    with _polish_dirs() as polish:
        if not polish.model_path(MODEL):
            with download_lock(MODEL["id"]):
                if not polish.model_path(MODEL):
                    try:
                        polish._download(MODEL)
                    except polish.Fail as e:
                        raise Fail(str(e), e.code) from e
        p = polish.model_path(MODEL)
    emit({"ok": True, "model": MODEL["id"], "path": str(p)})


def _draft(a) -> str | None:
    if a.draft_file:
        return Path(a.draft_file).read_text(encoding="utf-8")
    return a.draft


def _cloud_arg(a) -> dict | None:
    """--cloud deepseek | openai | anthropic | custom (with --base-url), --model, --protocol; the key: BLURT_POLISH_API_KEY."""
    if not a.cloud:
        return None
    return {"provider": a.cloud, "model": a.model, "base_url": a.base_url, "protocol": a.protocol,
            "key": os.environ.get("BLURT_POLISH_API_KEY", "")}


def cmd_read(a):
    draft = _draft(a)
    image = str(Path(a.image).resolve())
    cloud = _cloud_arg(a)
    if a.stdin:     # the app: {"draft", "cloud": {…, "key"}} — the key never on a command line or in the environment
        o = json.loads(sys.stdin.read() or "{}")
        draft, cloud = o.get("draft", draft), o.get("cloud") or cloud
    if cloud:
        import polish_cloud
        try:
            return emit(read_cloud(cloud, image, draft))
        except polish_cloud.CloudError as e:
            raise Fail(str(e), e.code) from e
    if not a.no_server:
        r = _server_call({"cmd": "read", "image": image, "draft": draft}, timeout=60)
        if r is not None:
            if not r.get("ok"):
                raise Fail(r.get("error") or "server error", r.get("code") or "error")
            return emit({**r, "server": True})
    ensure_vlm()
    emit(Engine().read(image, draft))


def cmd_merge(a):
    text, changed = merge(Path(a.draft_file).read_text(encoding="utf-8"), Path(a.model_file).read_text(encoding="utf-8"))
    emit({"ok": True, "text": text, "changed": changed})


def _distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _content(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = re.sub(r"(?m)^\s*[-•◦○◎。·▪●*]\s+", "-", s)
    return re.sub(r"\s+", "", s)


def cmd_eval(a):
    """The fixture set: each case's draft (DIR/drafts/<name>.txt, written by the app's test or BlurtCoreTests) read
    again by the model and merged; character error rates of the draft, the model and the merge, and the time."""
    ensure_vlm()
    root = Path(a.set)
    cases = [json.loads(l) for l in (root / "cases.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    eng = Engine()
    eng.load()
    rows, tot = [], {"draft": 0.0, "model": 0.0, "merged": 0.0}
    for c in cases:
        dp = root / "drafts" / f"{c['name']}.txt"
        if not dp.exists():
            continue
        draft = dp.read_text(encoding="utf-8")
        r = eng.read(str(root / f"{c['name']}.png"), draft)
        e = _content(c["expected"])
        err = {k: _distance(_content(t), e) / max(1, len(e)) for k, t in (("draft", draft), ("model", r["raw"] or ""), ("merged", r["text"]))}
        for k in tot:
            tot[k] += err[k]
        rows.append({"name": c["name"], "ms": r["ms"], **{k: round(v, 4) for k, v in err.items()}})
    n = max(1, len(rows))
    emit({"ok": True, "cases": len(rows), "load_ms": eng.load_ms, **{k: round(v / n, 4) for k, v in tot.items()},
          "ms_mean": int(sum(r["ms"] for r in rows) / n), "ms_max": max((r["ms"] for r in rows), default=0), "rows": rows})


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("models")
    s = sub.add_parser("setup")
    s.add_argument("--parent", type=int, help="end when this process (the app that started the download) is gone")
    sv = sub.add_parser("serve")
    sv.add_argument("--preload", action="store_true")
    sv.add_argument("--idle", type=float, default=SERVE_IDLE, help="end after the model went unused this many seconds")
    sv.add_argument("--exit-after", type=float, default=60.0, help="end after this many seconds with no model and no request")
    sv.add_argument("--parent", type=int, help="end when this process (the app that started the server) is gone")
    r = sub.add_parser("read")
    r.add_argument("--image", required=True)
    r.add_argument("--draft")
    r.add_argument("--draft-file")
    r.add_argument("--no-server", action="store_true")
    r.add_argument("--stdin", action="store_true", help='{"draft", "cloud"} as JSON on stdin (the app\'s way)')
    r.add_argument("--cloud", help="deepseek | openai | anthropic | custom: the user's cloud model (key: BLURT_POLISH_API_KEY)")
    r.add_argument("--model")
    r.add_argument("--base-url")
    r.add_argument("--protocol", choices=["openai", "anthropic"])
    m = sub.add_parser("merge")
    m.add_argument("--draft-file", required=True)
    m.add_argument("--model-file", required=True)
    e = sub.add_parser("eval")
    e.add_argument("--set", default=str(HERE.parent.parent.parent / "tests" / "fixtures" / "screen_text"))
    a = p.parse_args()
    try:
        {"models": cmd_models, "setup": cmd_setup, "serve": cmd_serve, "read": cmd_read, "merge": cmd_merge,
         "eval": cmd_eval}[a.cmd](a)
    except Fail as e:
        print(f"ERROR: {e}", file=sys.stderr)
        emit({"ok": False, "error": str(e), "code": e.code})
        if a.cmd == "serve":
            server_exit(e.exit_code)
        sys.exit(e.exit_code)
    except Exception:  # noqa: BLE001 — a server never goes through the interpreter's teardown (server_exit)
        if a.cmd != "serve":
            raise
        import traceback
        traceback.print_exc()
        server_exit(1)
    if a.cmd == "serve":
        server_exit(0)


if __name__ == "__main__":
    main()
