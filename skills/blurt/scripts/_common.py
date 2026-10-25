"""Shared helpers for blurt scripts (stdlib only)."""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

IS_MAC = sys.platform == "darwin"
IS_WIN = os.name == "nt"
IS_LINUX = sys.platform.startswith("linux")

BLURT_HOME = Path(os.environ.get("BLURT_HOME", Path.home() / ".blurt"))
MODELS_DIR = BLURT_HOME / "models"
GLOBAL_CONFIG = BLURT_HOME / "config.json"
STATE_FILE = BLURT_HOME / "recording.json"

# The version of the contracts between these scripts and the apps that run them (items.py's documents, jobs, the
# transcribe / polish serve protocols, the CLIs' JSON). Bump it when one changes in a way an older app or skill can't
# follow; the Mac app reads this line (BlurtCore/SkillContract.swift) and says once when the two don't match.
CONTRACT = 1


def ensure_utf8_stdio() -> None:
    # Windows consoles default to a legacy code page; keep CJK output intact.
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8")
        except Exception:
            pass


ensure_utf8_stdio()


def use_system_certs() -> None:
    """Verify TLS through the OS (truststore) when available. A fresh Windows fetches many root CAs on demand
    (e.g. the one behind huggingface.co); Python's own store lookup never triggers that and fails verification."""
    try:
        import truststore
        truststore.inject_into_ssl()
    except ImportError:
        pass


def die(msg: str, code: int = 1) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def ffmpeg_bin(name: str = "ffmpeg") -> str:
    path = shutil.which(name)
    if not path:
        hint = "brew install ffmpeg" if IS_MAC else "winget install Gyan.FFmpeg" if IS_WIN else "sudo apt install ffmpeg"
        die(f"{name} not found on PATH. Install it first: {hint}")
    return path


def run(cmd: list[str], check: bool = True, capture: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, check=check, capture_output=capture, text=True, encoding="utf-8", errors="replace", **kw
    )


def probe_duration(video: Path) -> float:
    out = run([ffmpeg_bin("ffprobe"), "-v", "error", "-show_entries", "format=duration",
               "-of", "default=nw=1:nk=1", str(video)]).stdout.strip()
    return float(out or 0)


def probe_size(video: Path) -> tuple[int, int]:
    out = run([ffmpeg_bin("ffprobe"), "-v", "error", "-select_streams", "v:0",
               "-show_entries", "stream=width,height", "-of", "csv=p=0", str(video)]).stdout.strip()
    w, h = out.split(",")[:2]
    return int(w), int(h)


def load_json(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))  # utf-8-sig: PowerShell/Notepad write a BOM
    except FileNotFoundError:
        return default


def _under_home(path: Path) -> bool:
    try:
        return Path(os.path.abspath(path)).is_relative_to(os.path.abspath(blurt_home()))
    except (OSError, ValueError):
        return False


def private_dir(path: Path) -> Path:
    """Make a folder that holds the user's own data (under $BLURT_HOME): 0700, so other accounts on the Mac can't read
    it (BlurtCore/FilePrivacy.swift does the same for the app's folders at launch). No-op for the mode on Windows."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    if not IS_WIN:
        try:
            if path.stat().st_mode & 0o777 != 0o700:
                path.chmod(0o700)
        except OSError:
            pass
    return path


def save_json(path: Path, data) -> None:
    """Atomic. Under $BLURT_HOME (config, the model servers' tokens, jobs) the file is 0600 and a folder it makes is
    0700: only this account can read them."""
    path = Path(path)
    private = _under_home(path)
    if private and not path.parent.exists():
        private_dir(path.parent)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    if private and not IS_WIN:
        os.close(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
        tmp.chmod(0o600)  # an older leftover tmp keeps its mode otherwise
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    for attempt in range(20):  # Windows: replace fails while a reader has the target open
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.05)


def _config_path() -> Path:
    return Path(os.environ["BLURT_HOME"]) / "config.json" if os.environ.get("BLURT_HOME") else GLOBAL_CONFIG


def drop_trailing_commas(text: str) -> str:
    """A comma right before `}` or `]` (outside strings) left out — the one slip a hand edit makes most. The Mac app's
    Config (BlurtCore/Config.swift, `ConfigText.dropTrailingCommas`) reads the file the same way, so what one side
    can read the other can too. Until none is left (",, }" too): Swift's parser forgives one trailing comma, Python's
    none, so with none left both read exactly the same files."""
    while True:
        nxt = _drop_trailing_commas_once(text)
        if nxt == text:
            return text
        text = nxt


def _drop_trailing_commas_once(text: str) -> str:
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j >= n or text[j] not in "}]":
                out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def parse_config_text(text: str) -> dict | None:
    """config.json's text → the settings, or None when it doesn't parse even with trailing commas left out (or isn't
    an object)."""
    try:
        v = json.loads(drop_trailing_commas(text.lstrip("﻿")))
    except ValueError:
        return None
    return v if isinstance(v, dict) else None


_CONFIG_WARNED: set = set()


def _backup_unreadable(path: Path) -> Path | None:
    """A copy of a config.json that doesn't parse, once per version: config.json.bad-<time>, unless one with the same
    bytes is already there (the app makes the same copy: BlurtCore Config.refuse)."""
    try:
        data = path.read_bytes()
        for old in sorted(path.parent.glob(path.name + ".bad-*")):
            if old.read_bytes() == data:
                return old
        bak = path.with_name(f"{path.name}.bad-{datetime.now().strftime('%Y%m%d-%H%M%S')}")
        bak.write_bytes(data)
        if not IS_WIN:
            bak.chmod(0o600)
        return bak
    except OSError:
        return None


def read_global_config() -> tuple[dict, bool]:
    """(settings, readable). A missing file is readable ({}); one that doesn't parse gives {} — every setting at its
    default — and False: it is copied aside once and a `config_unreadable` line goes to stderr (once per process), so
    dictation, voice notes and processing keep working with the defaults instead of stopping on a hand edit."""
    path = _config_path()
    try:
        text = path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        return {}, True
    except (OSError, UnicodeDecodeError):
        text = None
    cfg = parse_config_text(text) if text is not None else None
    if cfg is not None:
        return cfg, True
    if str(path) not in _CONFIG_WARNED:
        _CONFIG_WARNED.add(str(path))
        bak = _backup_unreadable(path)
        print(json.dumps({"event": "config_unreadable", "path": str(path), "backup": str(bak) if bak else None}),
              file=sys.stderr)
    return {}, False


def global_config() -> dict:
    """The settings ({} when the file is missing or doesn't parse: read_global_config). Reading never raises."""
    return read_global_config()[0]


def update_global_config(patch: dict) -> dict:
    """Read-modify-write under $BLURT_HOME/.config.lock — the lock the app's Config.set takes too, so neither loses the
    other's change. An unreadable config.json is left as it is: the write raises (json.JSONDecodeError)."""
    path = _config_path()
    with file_lock(path.parent / ".config.lock"):
        cfg, ok = read_global_config()
        if not ok:
            raise json.JSONDecodeError("config.json doesn't parse", "", 0)
        for k, v in patch.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
        save_json(path, cfg)
    return cfg


def new_session_dir(root: Path | None = None) -> Path:
    root = Path(root or Path.cwd())
    d = root / ".blurt" / "sessions" / datetime.now().strftime("%Y%m%d-%H%M%S")
    d.mkdir(parents=True, exist_ok=True)
    return d


def fmt_ts(sec: float) -> str:
    sec = max(0.0, sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h)}:{int(m):02d}:{s:04.1f}" if h else f"{int(m):02d}:{s:04.1f}"


def system_info() -> dict:
    info = {
        "os": platform.system(),
        "os_version": platform.mac_ver()[0] if IS_MAC else platform.version(),
        "arch": platform.machine().lower(),
        "cpu_count": os.cpu_count(),
        "python": platform.python_version(),
    }
    info["apple_silicon"] = IS_MAC and info["arch"] in ("arm64", "aarch64")
    info["ram_gb"] = _ram_gb()
    info["nvidia_gpu"] = _nvidia_gpu()
    return info


def _ram_gb() -> float | None:
    try:
        if IS_MAC:
            return round(int(run(["sysctl", "-n", "hw.memsize"]).stdout) / 2**30, 1)
        if IS_WIN:
            import ctypes

            class MEMSTAT(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("sullAvailExtendedVirtual", ctypes.c_ulonglong)]
            st = MEMSTAT()
            st.dwLength = ctypes.sizeof(MEMSTAT)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
            return round(st.ullTotalPhys / 2**30, 1)
        return round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1)
    except Exception:
        return None


def _nvidia_gpu() -> str | None:
    if not shutil.which("nvidia-smi"):
        return None
    try:
        out = run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"]).stdout.strip()
        return out.splitlines()[0] if out else None
    except Exception:
        return None


def fix_tcl_env() -> None:
    """uv-managed Pythons can't find Tcl/Tk inside venvs; point TCL_LIBRARY/TK_LIBRARY at the base install."""
    if os.environ.get("TCL_LIBRARY"):
        return
    base = Path(sys.base_prefix)
    for init in list(base.glob("lib/tcl*/init.tcl")) + list(base.glob("tcl/tcl*/init.tcl")):
        os.environ["TCL_LIBRARY"] = str(init.parent)
        ver = init.parent.name.replace("tcl", "")
        for tkdir in (init.parent.parent / f"tk{ver}", init.parent.parent / f"tk{ver.split('.')[0]}"):
            if tkdir.exists():
                os.environ["TK_LIBRARY"] = str(tkdir)
        return


# ------------------------------------------------------------------ where things live (read at call time: tests and
# the apps point BLURT_HOME / BLURT_WORKSPACE elsewhere after import)
# the warm model servers (transcribe.py / polish.py serve). Unloading the model is ending the process: MLX keeps
# ~1.8 GB of a 2.5 GB speech model resident after an unload (arch091), so a server idle this long exits, and the app
# starts it again on the next key-down. It also ends with the app that started it (`--parent`), and on `exit`.
SERVE_IDLE = 600         # a loaded model's server ends after this many seconds without a request (10 min)
IDLE_CAP = 600           # … at most this long even with frequent use (it used to be 30 min, holding ~5 GB)
EXIT_CAP = 4 * 3600      # a server with no model loaded waits at most this long for a request


def adaptive_idle(base: float, uses: list[float], tier: str, cap: float = IDLE_CAP, now: float | None = None) -> float:
    """How long to keep the model (or the server) without a request: `base`, longer while dictation is used often —
    ×2 at 3+ requests in the last 30 min, ×5 at 8+ (at most `cap`) — so the next dictation finds it warm. Only where
    memory allows: the light and minimal tiers keep `base` (the model is a large share of their RAM)."""
    if tier not in ("pro", "standard"):
        return base
    now = now or time.time()
    recent = sum(1 for t in uses if now - t < 1800)
    factor = 5 if recent >= 8 else 2 if recent >= 3 else 1
    return max(base, min(cap, base * factor))


def parent_alive(pid: int | None) -> bool:
    """The app that started a warm server is still running (no pid given: nobody to outlive)."""
    if not pid:
        return True
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError, ValueError):
        return True
    return True


def serve_said(line: str) -> None:
    """A warm server's last word on stderr — which is the app's pipe, closed when the app quit or crashed: a write
    there must not stop the server from cleaning up after itself."""
    try:
        print(line, file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass


def serve_exit_reason(loaded: bool, model_idle: float, server_idle: float, uses: list[float], tier: str,
                      idle: float, exit_after: float, parent: int | None = None) -> str | None:
    """Why a warm model server should end now, or None. "parent_gone": the app that started it quit or crashed (a
    request in flight is answered first: this is checked between requests); "idle": its model went unused for `idle`
    s (adaptive, at most IDLE_CAP) — ending the process is what gives the memory back; "unused": no model loaded and
    no request for `exit_after` s."""
    if not parent_alive(parent):
        return "parent_gone"
    if loaded and model_idle > adaptive_idle(idle, uses, tier):
        return "idle"
    if not loaded and server_idle >= adaptive_idle(exit_after, uses, tier, cap=EXIT_CAP):
        return "unused"
    return None


def blurt_home() -> Path:
    return Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")


def blurt_workspace() -> Path:
    """The Blurt app's own folder (~/Blurt): the inbox store lives in it, and v0.6 recordings in recordings/."""
    return Path(os.environ.get("BLURT_WORKSPACE") or Path.home() / "Blurt")


def real(p: Path | str) -> Path:
    return Path(os.path.realpath(os.path.expanduser(str(p))))


# ------------------------------------------------------------------ time (contract: ISO 8601 with offset on disk)
def now_iso(t: float | None = None, timespec: str = "seconds") -> str:
    return datetime.fromtimestamp(time.time() if t is None else t).astimezone().isoformat(timespec=timespec)


def to_epoch(v) -> float | None:
    """ISO 8601 (any offset, or Z) or epoch seconds → epoch seconds; None when it is neither."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str) and v:
        try:
            d = datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError:
            return None
        return (d if d.tzinfo else d.astimezone()).timestamp()
    return None


# ------------------------------------------------------------------ locks
# One lock file per thing that has several writers (a store, a session's batch, projects.json), shared across
# processes (flock / msvcrt) and threads. Re-entrant within a thread, so a write that holds a store's lock can call
# helpers that take it again.
_THREAD_LOCKS: dict[str, threading.Lock] = {}
_HELD = threading.local()


@contextmanager
def file_lock(path: Path, timeout: float | None = None):
    path = Path(path)
    if timeout is None:
        timeout = float(os.environ.get("BLURT_LOCK_TIMEOUT") or 15)
    path.parent.mkdir(parents=True, exist_ok=True)
    key = str(path.resolve())
    held = getattr(_HELD, "paths", None)
    if held is None:
        held = _HELD.paths = {}
    if held.get(key):
        held[key] += 1
        try:
            yield
        finally:
            held[key] -= 1
        return
    tl = _THREAD_LOCKS.setdefault(key, threading.Lock())
    if not tl.acquire(timeout=timeout):
        raise TimeoutError(f"{path} is locked")
    try:
        fh = open(path, "a+b")
        try:
            deadline = time.monotonic() + timeout
            while True:
                try:
                    if IS_WIN:
                        import msvcrt
                        fh.seek(0)
                        msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"{path} is locked by another process")
                    time.sleep(0.02)
            held[key] = 1
            try:
                yield
            finally:
                held.pop(key, None)
                if IS_WIN:
                    import msvcrt
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()
    finally:
        tl.release()


def items_lock(session: Path, timeout: float | None = None):
    """A session's batch (batch.json, and a pending items.json): everything that reads-modifies-writes them."""
    return file_lock(Path(session) / ".items.lock", timeout)


def write_text_atomic(path: Path, text: str) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    for attempt in range(20):  # Windows: replace fails while a reader has the target open
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 19:
                tmp.unlink(missing_ok=True)
                raise
            time.sleep(0.05)


# ------------------------------------------------------------------ model downloads (transcribe.py / polish.py setup)
# The Mac app's one download manager (BlurtApp/App/ModelDownloads.swift) runs `setup` one model at a time; these
# helpers make each download safe to repeat, to cut short and to run twice:
#   complete    a folder we fill file by file (the ModelScope mirror) is installed only when it is complete: a
#               `.blurt-downloading` marker goes in before the first file and comes out after the last, and
#               `.blurt-manifest.json` lists every file with its size (folder_complete checks each one). A folder from an
#               older Blurt (no manifest) falls back to the caller's own test.
#   resumable   a partial file (<name>.part) is continued with an HTTP Range request, not started again from byte 0.
#   one at a time  download_lock: a second `setup` of the same model waits for the first, then finds it installed.
#   its app     watch_parent: a setup started by the app ends when the app is gone (quit, crash) instead of running on
#               as an orphan; what came down stays for the next try.
DOWNLOAD_MARKER = ".blurt-downloading"
DOWNLOAD_MANIFEST = ".blurt-manifest.json"
DOWNLOAD_LOCK_TIMEOUT = 6 * 3600     # a 3 GB model on a slow line; the waiting setup just waits


def download_lock(model_id: str):
    """One download of `model_id` at a time, across processes ($BLURT_HOME/run/download-<id>.lock)."""
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", model_id)
    return file_lock(blurt_home() / "run" / f"download-{safe}.lock", timeout=DOWNLOAD_LOCK_TIMEOUT)


def safetensors_complete(d: Path) -> bool:
    """Every shard a model.safetensors.index.json names is there (a folder without an index: its one file is)."""
    idx = load_json(d / "model.safetensors.index.json", None)
    if not isinstance(idx, dict):
        return any(d.glob("*.safetensors"))
    return all((d / f).is_file() for f in set((idx.get("weight_map") or {}).values()))


def folder_complete(d: Path, legacy=None) -> bool:
    """A model folder we downloaded file by file is complete: no download marker, and every file of its manifest at
    its size. Without a manifest (an older Blurt's download), `legacy(d)` decides (False when not given)."""
    if not d.is_dir() or (d / DOWNLOAD_MARKER).exists():
        return False
    man = load_json(d / DOWNLOAD_MANIFEST, None)
    if isinstance(man, list):
        for f in man:
            p = d / f["path"]
            if not p.is_file() or (f.get("size") and p.stat().st_size != f["size"]):
                return False
        return True
    return bool(legacy(d)) if legacy else False


def begin_download(d: Path, files: list[dict]) -> None:
    """Before the first file: the marker (the folder isn't a model until end_download) and the manifest
    ([{"path", "size"}])."""
    d.mkdir(parents=True, exist_ok=True)
    (d / DOWNLOAD_MARKER).write_text(str(os.getpid()))
    write_text_atomic(d / DOWNLOAD_MANIFEST, json.dumps([{"path": f["path"], "size": f.get("size")} for f in files]))


def end_download(d: Path) -> None:
    """After the last file went through os.replace."""
    (d / DOWNLOAD_MARKER).unlink(missing_ok=True)


def fetch(url: str, tmp: Path, size: int | None = None, progress=None, timeout: float = 60) -> int:
    """GET `url` into `tmp`, continuing what is already there (HTTP Range; a server that ignores it sends it all and
    we start over). `progress(have, total)` per chunk. Returns the bytes now in `tmp`."""
    import urllib.error
    import urllib.request
    have = tmp.stat().st_size if tmp.exists() else 0
    if size and have > size:
        tmp.unlink()
        have = 0
    if size and have == size:
        return have
    headers = {"User-Agent": "blurt"}
    if have:
        headers["Range"] = f"bytes={have}-"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout)
    except urllib.error.HTTPError as e:
        if e.code == 416 and have:          # nothing past what we have: it is all there
            return have
        raise
    with r:
        if have and getattr(r, "status", None) != 206:
            have = 0
        length = int(r.headers.get("content-length") or 0)
        total = size or (have + length if length else 0)
        tmp.parent.mkdir(parents=True, exist_ok=True)
        with open(tmp, "ab" if have else "wb") as o:
            while chunk := r.read(1 << 20):
                o.write(chunk)
                have += len(chunk)
                if progress:
                    progress(have, total)
    return have


def watch_parent(pid: int | None, interval: float = 1.0) -> None:
    """A setup started by an app (`--parent PID`) ends when that app is gone, at once (what came down stays: the next
    setup continues it) — not orphaned, and not dying later on a closed stderr."""
    if not pid:
        return

    def run():
        while parent_alive(pid):
            time.sleep(interval)
        os._exit(143)

    threading.Thread(target=run, daemon=True, name="watch-parent").start()


# ------------------------------------------------------------------ identities (contract C1, unchanged in v3)
_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid(now: float | None = None) -> str:
    """26-char ULID: 48-bit ms timestamp + 80 random bits, Crockford base32 (sorts by creation time)."""
    n = (int((time.time() if now is None else now) * 1000) & (2**48 - 1)) << 80 | secrets.randbits(80)
    return "".join(_CROCKFORD[(n >> (5 * k)) & 31] for k in range(25, -1, -1))


def legacy_uid(session_name: str, item_id: str) -> str:
    """uid of an item written before v2 (no "uid" field): "L" + sha1("<session dir name>/<id>").hex[:25].
    26 chars like a ULID, and "L" is not in Crockford's alphabet, so the two never collide."""
    return "L" + hashlib.sha1(f"{session_name}/{item_id}".encode("utf-8")).hexdigest()[:25]


def item_uid(session: Path, item: dict) -> str:
    return item.get("uid") or legacy_uid(Path(session).resolve().name, item.get("id") or "")


def file_etag(raw: bytes) -> str:
    """sha1 of the bytes, 16 hex chars, quoted (HTTP ETag)."""
    return '"' + hashlib.sha1(raw).hexdigest()[:16] + '"'


def project_id(path: Path | str) -> str:
    """K2: sha1(realpath(path)).hex[:12] — the same formula as the v1 index's workspace id."""
    return hashlib.sha1(str(real(path)).encode("utf-8")).hexdigest()[:12]


class InvalidEdit(ValueError):
    """An edit the store refuses (review.py answers 400 with it, items.py exits 1 with it)."""


REQUIRED_TEXT = ("title",)  # an item without a title can't be listed, searched, exported or reviewed


def check_item_fields(sets: dict, unsets=(), where: str = "") -> None:
    """Raises InvalidEdit when an edit would leave an item's title empty / whitespace-only, or remove it."""
    for k in REQUIRED_TEXT:
        if k in (unsets or ()):
            raise InvalidEdit(f"{where}{k} can't be removed: every item needs a {k}")
        if k in sets and (sets[k] is None or (isinstance(sets[k], str) and not sets[k].strip())):
            raise InvalidEdit(f"{where}{k} can't be empty: keep the previous {k} or type a new one")


# ------------------------------------------------------------------ K3: the item lifecycle (one state)
# One user-visible state per item (docs/design/next-round.md K3). The same table is in web/packages/ui/src/lifecycle.ts
# and BlurtCore/Lifecycle.swift; all three are tested against tests/fixtures/lifecycle.json.
STATES = ("new", "todo", "handed_off", "in_progress", "to_verify", "done", "wontfix", "discarded")
INBOX_STATES = ("new", "to_verify")                         # "needs you": every inbox count in every app
OPEN_STATES = ("new", "todo", "handed_off", "in_progress")  # MCP open_items, the backlog
ACTIVE_STATES = ("handed_off", "in_progress", "to_verify")
CLOSED_STATES = ("done", "wontfix")
WORK_KEYS = ("to", "agent", "job", "handoff", "claim", "note", "commit", "pr", "at", "by")  # `work`: hand-off details
WORK_BY = ("user", "agent", "app")
# the states a hand-off passes through: moving into or out of them rewrites `work` and appends to work_history
WORK_TRACKED = ("handed_off", "in_progress", "to_verify", "done", "wontfix")
_LIVE = STATES[:-1]
# action → (from states, to state; None = the item's restore_to). The user's state menu is exactly this table.
ACTIONS = {
    "keep": (("new",), "todo"),
    "hand_off": (("new", "todo"), "handed_off"),
    "done": (("todo", "handed_off", "in_progress", "to_verify"), "done"),
    "send_back": (("to_verify",), "todo"),
    "take_back": (("handed_off", "in_progress"), "todo"),
    "reopen": (("done", "wontfix"), "todo"),
    "restore": (("discarded",), None),
    "wontfix": (("new", "todo", "handed_off", "in_progress", "to_verify"), "wontfix"),
    "discard": (_LIVE, "discarded"),
}
_AGENT_MOVES = {("new", "in_progress"), ("todo", "in_progress"), ("handed_off", "in_progress"),
                ("to_verify", "in_progress"), ("new", "to_verify"), ("todo", "to_verify"), ("handed_off", "to_verify"),
                ("in_progress", "to_verify"), ("to_verify", "to_verify"), ("in_progress", "in_progress"),
                ("in_progress", "todo"), ("to_verify", "todo")}  # an agent may take back its own claim (reopened)
_APP_MOVES = _AGENT_MOVES | {("new", "handed_off"), ("todo", "handed_off"), ("handed_off", "handed_off")}
_USER_MOVES = {(f, to) for frm, to in ACTIONS.values() if to for f in frm} | {("handed_off", "handed_off")} \
    | {("discarded", s) for s in _LIVE}  # restore: back to where it was (restore_to)

# the shapes before one state (v1 / v2 items.json, early v0.7 files): accepted as input only
REVIEW_STATES = ("draft", "confirmed", "deleted")
LEGACY_WORK = ("todo", "handed_off", "in_progress", "to_verify", "done", "wontfix")
FIX_STATES = ("fixing", "fixed", "wontfix", "reopened")  # v2 (items.py fix, mark_fixed)
FIX_TO_WORK = {"fixing": ("in_progress", None), "fixed": ("to_verify", "fixed"), "wontfix": ("to_verify", "wontfix"),
               "reopened": ("todo", None)}


def state_of(item: dict) -> str:
    """The item's state. A file from before the one-state model (status + work.state, or a v2 fix) converts the way
    K3's migration says: deleted → discarded; a work state other than todo wins; else draft → new, confirmed → todo."""
    s = item.get("state")
    if s in STATES:
        return s
    if item.get("status") == "deleted":
        return "discarded"
    return _live_state(item)


def _live_state(item: dict) -> str:
    w = item.get("work")
    ws = w.get("state") if isinstance(w, dict) else None
    if ws not in LEGACY_WORK and isinstance(item.get("fix"), dict):
        ws = work_from_fix(item["fix"])["state"]
    if ws in LEGACY_WORK and ws != "todo":
        return ws
    return "todo" if item.get("status") == "confirmed" else "new"


def migrate_state(item: dict) -> dict:
    """In place: an item of any shape → `state` (+ `restore_to` while discarded), a `work` without a state key, no
    `status` / `fix` / `fix_history`. Idempotent; a file is written in this shape on its next write."""
    legacy = item.get("state") not in STATES
    state = state_of(item)
    if legacy and state == "discarded":
        item["restore_to"] = _live_state(item)
    if isinstance(item.get("fix"), dict) and not isinstance(item.get("work"), dict):
        item["work"] = work_from_fix(item["fix"])
    hist = [work_from_fix(f) for f in item.pop("fix_history", None) or [] if isinstance(f, dict)]
    if hist:
        item["work_history"] = hist + [h for h in item.get("work_history") or [] if isinstance(h, dict)]
    item.pop("fix", None)
    item.pop("status", None)
    if isinstance(item.get("work"), dict):
        item["work"] = {k: item["work"].get(k) for k in WORK_KEYS}
    item["state"] = state
    if state != "discarded":
        item.pop("restore_to", None)
    return item


def may_move(cur: str, new: str, by: str) -> bool:
    if by == "user":
        return (cur, new) in _USER_MOVES
    return (cur, new) in (_APP_MOVES if by == "app" else _AGENT_MOVES)


def action_target(action: str, cur: str, restore_to: str | None = None) -> str | None:
    """Where the user's action takes an item in state cur; None = the action isn't valid there."""
    frm, to = ACTIONS.get(action, ((), None))
    if cur not in frm:
        return None
    return to or (restore_to if restore_to in _LIVE else "new")


def work_from_fix(fix: dict) -> dict:
    """A v2 `fix` record → {state, …work} (K3 mapping). An old human wontfix is a decision, not a claim."""
    state, claim = FIX_TO_WORK.get(fix.get("state"), ("todo", None))
    agent = fix.get("agent") or None
    if fix.get("state") == "wontfix" and agent in (None, "human"):
        state, claim = "wontfix", None
    at = fix.get("at")
    return {"state": state, "to": "session" if fix.get("run_id") else None, "agent": agent,
            "job": fix.get("run_id") or None, "handoff": None, "claim": claim, "note": fix.get("note") or "",
            "commit": fix.get("commit") or None, "pr": fix.get("pr") or None,
            "at": now_iso(at) if isinstance(at, (int, float)) else (at or None),
            "by": "user" if agent in (None, "human") else "agent"}


def legacy_filter_states(statuses=(), works=(), fix_states=()) -> list[str] | None:
    """The old --status / --work / --fix-state filters as states (None = none given). Different kinds of filter
    narrow each other, as they did as columns."""
    sets = []
    if statuses:
        m = {"draft": {"new"}, "confirmed": set(LEGACY_WORK), "deleted": {"discarded"}}
        sets.append(set().union(*(m.get(s, set()) for s in statuses)))
    if works:
        sets.append(set().union(*({"new", "todo"} if w == "todo" else {w} for w in works)))
    if fix_states:
        m = {"fixing": {"in_progress"}, "fixed": {"to_verify", "done"}, "wontfix": {"wontfix", "to_verify"},
             "reopened": {"new", "todo"}, "none": {"new", "todo"}}
        sets.append(set().union(*(m.get(f, set()) for f in fix_states)))
    if not sets:
        return None
    out = set.intersection(*sets)
    return [s for s in STATES if s in out]


def append_job_event(job: str | None, event: dict) -> None:
    """K4: anyone but a job's owner reports progress by appending one line to jobs/<id>.events.jsonl (O_APPEND,
    one write < 4 KB). Best effort: a missing job or a read-only home never fails the caller."""
    if not job or not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", job):
        return
    path = blurt_home() / "jobs" / f"{job}.events.jsonl"
    if not (path.parent / f"{job}.json").exists():
        return
    line = json.dumps({"t": now_iso(), "source": "items", **event}, ensure_ascii=False) + "\n"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8")[:4000])
        finally:
            os.close(fd)
    except OSError:
        pass


# ---------------------------------------------------------------- hotkeys (config record.hotkeys)
# Same grammar as the macOS app (Hotkeys.swift): "opt+shift+R", "ctrl+alt+F5", "⌥⇧A", "off". Stored canonically as
# "<ctrl+><opt+><shift+><cmd+>KEY". On Windows/Linux opt = Alt and cmd = the Windows / Super key.
# voice / project: K7 (voice input, project switcher) — same names in HotkeyCenter.Action (Swift) and the Tauri app
HOTKEY_ACTIONS = ("record", "menu", "pause", "snap", "marker", "pen", "stop", "voice", "project")
HOTKEY_DEFAULT_KEYS = {"record": "R", "menu": "B", "pause": "P", "snap": "A", "marker": "M", "pen": "D", "stop": "S",
                       "voice": "V", "project": "O"}
_MOD_ALIASES = {"ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl", "^": "ctrl",
                "opt": "opt", "option": "opt", "alt": "opt", "⌥": "opt",
                "shift": "shift", "⇧": "shift",
                "cmd": "cmd", "command": "cmd", "⌘": "cmd", "win": "cmd", "super": "cmd", "meta": "cmd"}
_MOD_ORDER = ("ctrl", "opt", "shift", "cmd")
_NAMED_KEYS = {"space": "Space", "spacebar": "Space", "tab": "Tab", "return": "Return", "enter": "Return",
               "left": "Left", "right": "Right", "up": "Up", "down": "Down",
               "←": "Left", "→": "Right", "↑": "Up", "↓": "Down"}
_PUNCT = set("-=[];',./\\`")
_OFF = ("off", "none", "disabled", "-", "")


def _hotkey_key(tok: str) -> str | None:
    if len(tok) == 1 and ((tok.isalnum() and tok.isascii()) or tok in _PUNCT):
        return tok.upper()
    low = tok.lower()
    if low in _NAMED_KEYS:
        return _NAMED_KEYS[low]
    if low.startswith("f") and low[1:].isdigit() and 1 <= int(low[1:]) <= 20:
        return "F" + low[1:]
    return None


def parse_hotkey(spec) -> tuple[tuple[str, ...], str] | None:
    """"opt+shift+R" / "⌥⇧R" / "Alt+Shift+r" → (("opt", "shift"), "R"). None for off / empty / unparseable.
    Needs ⌃ / ⌥ / ⌘ (shift alone would steal typing) — F-keys may stand alone."""
    if not isinstance(spec, str) or spec.strip().lower() in _OFF:
        return None
    s = spec.strip()
    mods: set[str] = set()
    while s and s[0] in "⌃⌥⇧⌘^":  # glyph prefixes: ⌥⇧R
        mods.add(_MOD_ALIASES[s[0]])
        s = s[1:]
    key = None
    for tok in s.replace(" ", "").split("+"):
        if not tok:
            continue
        mod = _MOD_ALIASES.get(tok.lower())
        if (mod and len(tok) > 1) or (len(tok) == 1 and tok in "⌃⌥⇧⌘"):
            mods.add(mod or _MOD_ALIASES[tok])
        elif key is None and _hotkey_key(tok):
            key = _hotkey_key(tok)
        else:
            return None
    if key is None:
        return None
    if not (mods - {"shift"}) and not (key.startswith("F") and len(key) > 1):
        return None
    return tuple(m for m in _MOD_ORDER if m in mods), key


def hotkey_spec(hk: tuple[tuple[str, ...], str] | None) -> str:
    return "+".join([*hk[0], hk[1]]) if hk else "off"


def hotkey_label(hk: tuple[tuple[str, ...], str] | None, mac: bool = IS_MAC) -> str:
    """What to show the user: "⌥⇧R" on macOS, "Alt+Shift+R" elsewhere; "" when off."""
    if not hk:
        return ""
    if mac:
        glyph = {"ctrl": "⌃", "opt": "⌥", "shift": "⇧", "cmd": "⌘"}
        keys = {"Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Return": "↩", "Tab": "⇥"}
        return "".join(glyph[m] for m in hk[0]) + keys.get(hk[1], hk[1])
    name = {"ctrl": "Ctrl", "opt": "Alt", "shift": "Shift", "cmd": "Win"}
    return "+".join([*(name[m] for m in hk[0]), hk[1]])


def hotkeys_from_config(cfg: dict | None = None) -> dict[str, tuple[tuple[str, ...], str] | None]:
    """action → hotkey (None = off). Missing / unparseable entries fall back to the default; the defaults' modifiers
    can be overridden for tests with BLURT_HOTKEY_MODS (e.g. "ctrl+opt+shift+cmd"), as in the app."""
    rec = (cfg if cfg is not None else global_config()).get("record", {})
    user = rec.get("hotkeys") if isinstance(rec.get("hotkeys"), dict) else {}
    env = os.environ.get("BLURT_HOTKEY_MODS") or ""
    want = {_MOD_ALIASES.get(t.strip().lower()) for t in env.split("+")}
    dmods = tuple(m for m in _MOD_ORDER if m in want) or ("opt", "shift")
    out: dict[str, tuple[tuple[str, ...], str] | None] = {}
    for a in HOTKEY_ACTIONS:
        v = user.get(a)
        if v is False or (isinstance(v, str) and v.strip().lower() in _OFF):
            out[a] = None
        elif parse_hotkey(v):
            out[a] = parse_hotkey(v)
        else:
            out[a] = (dmods, HOTKEY_DEFAULT_KEYS[a])
    return out
