"""Shared helpers for blurt scripts (stdlib only)."""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

IS_MAC = sys.platform == "darwin"
IS_WIN = os.name == "nt"

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


def die(msg: str, code: int = 1) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def ffmpeg_bin(name: str = "ffmpeg") -> str:
    path = shutil.which(name)
    if not path:
        hint = "brew install ffmpeg" if IS_MAC else "winget install Gyan.FFmpeg" if IS_WIN else "apt install ffmpeg"
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
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def save_json(path: Path, data) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


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


def live_items(data: dict, kind: str | None = None) -> list[dict]:
    return [i for i in data.get("items", []) if i.get("status") != "deleted" and (kind is None or i.get("kind") == kind)]
