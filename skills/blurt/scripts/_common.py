"""Shared helpers for blurt scripts (stdlib only)."""
from __future__ import annotations

import json
import os
import platform
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


def save_json(path: Path, data) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    for attempt in range(20):  # Windows: replace fails while a reader has the target open
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.05)


def global_config() -> dict:
    return load_json(GLOBAL_CONFIG, {}) or {}


def update_global_config(patch: dict) -> dict:
    cfg = global_config()
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict):
            cfg[k].update(v)
        else:
            cfg[k] = v
    save_json(GLOBAL_CONFIG, cfg)
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


# ------------------------------------------------------------------ session output: items.json
def load_session(session: Path) -> dict | None:
    return load_json(Path(session) / "items.json")


def save_session(session: Path, data: dict) -> None:
    save_json(Path(session) / "items.json", data)


# items.json has two writers once the review page is open: the agent (items.py) and the page (review.py). Every
# write is read-modify-write under one lock file per session, shared across processes and threads.
_THREAD_LOCKS: dict[str, threading.Lock] = {}


@contextmanager
def items_lock(session: Path, timeout: float = 15.0):
    path = Path(session) / ".items.lock"
    tl = _THREAD_LOCKS.setdefault(str(path.resolve()), threading.Lock())
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
            try:
                yield
            finally:
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


def find_item(data: dict, item_id: str) -> dict | None:
    return next((i for i in data.get("items", []) if i.get("id") == item_id), None)


def removed_into(data: dict, item_id: str) -> str | None:
    """Where an item the user merged away went ("" = removed without a target), else None."""
    gone = data.get("_removed") or {}
    if item_id in gone:
        return gone[item_id] or ""
    return next((i.get("id") for i in data.get("items", []) if item_id in (i.get("merged_from") or [])), None)


def live_items(data: dict, kind: str | None = None) -> list[dict]:
    return [i for i in data.get("items", []) if i.get("status") != "deleted" and (kind is None or i.get("kind") == kind)]


# ---------------------------------------------------------------- hotkeys (config record.hotkeys)
# Same grammar as the macOS app (Hotkeys.swift): "opt+shift+R", "ctrl+alt+F5", "⌥⇧A", "off". Stored canonically as
# "<ctrl+><opt+><shift+><cmd+>KEY". On Windows/Linux opt = Alt and cmd = the Windows / Super key.
HOTKEY_ACTIONS = ("record", "menu", "pause", "snap", "marker", "pen", "stop")
HOTKEY_DEFAULT_KEYS = {"record": "R", "menu": "B", "pause": "P", "snap": "A", "marker": "M", "pen": "D", "stop": "S"}
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
