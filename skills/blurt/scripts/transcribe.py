# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy==2.3.4; python_version >= '3.11'", "numpy==2.2.6; python_version < '3.11'", "sherpa-onnx==1.13.8", "truststore==0.10.5", "opencc-python-reimplemented==0.1.7"]
# ///
"""Speech-to-text with timestamps, adapted to the machine it runs on (docs/design/next-round.md K9).
Always VAD-first: silence is dropped, speech is chunked, and every chunk keeps its offset in the original
video, so any backend (even ones without timestamps) works.

  transcribe.py run    <video|audio> [--out DIR]     transcribe; writes transcript.json + transcript.txt
                                                     instant when live.py already transcribed the recording
                                                     while it was made (<session>/live/); --force redoes it
  transcribe.py run    <session dir>                 a shots session (snap mode): transcribe each voice note
                                                     shots/NNN.wav into its shots.jsonl record ("said")
  transcribe.py note   <wav> [--language auto] [--dictation] [--vocab] [--no-server] [--no-download]
                                                     one voice note, fast path → {"ok","text","language","ms","model"}
                                                     (uses a running `serve` when there is one). --dictation: the
                                                     dictation model (record.dictation.asr_model); --vocab: bias it
                                                     toward the words (dictation_vocab.py) where the model can be
                                                     biased; they are hints, the text is as heard → + "asr_text","biased"
  transcribe.py serve  [--preload] [--model-id ID | --purpose dictation] [--no-download] [--idle 600] [--parent PID]   keep the
                                                     voice-note (or dictation) model warm; ends after --idle s unused
                                                     (the memory goes back), with the --parent app, or on "exit".
                                                     A request with "interim": true (live words while talking) is
                                                     stopped as soon as another request waits → code "interrupted"
                                                     (a quick model, SenseVoice, decodes it whole)
  transcribe.py dictation-models                     the models dictation can use here: selected, recommended, ready (runs with nothing downloaded, VAD included), missing
  transcribe.py probe                                hardware → tier (pro / standard / light / minimal)
  transcribe.py recommend [--languages zh,en] [--purpose batch|live|note]
  transcribe.py auto   [--apply]                     pick a model per purpose for this machine (asr.models);
                                                     lists what still has to be downloaded
  transcribe.py models                               the registry (asr_models.json) + installed, measured, selected
  transcribe.py setup  --model ID [--use all|batch,live,note] [--parent PID]   download a model (progress on
                                                     stderr): one at a time per model (a second one waits), a
                                                     partial file continued (HTTP Range), a mirror folder installed
                                                     only once every file of its manifest is in; ends with --parent
  transcribe.py bench  [AUDIO] [--model ID] [--languages zh,en]  real-time factor, peak memory, CPU load and (on the
                                                     built-in `say` samples) the error rate per language
                                                     → $BLURT_HOME/asr-bench.json
  transcribe.py backends                             backends and whether they are ready (legacy)

Which model: --model ID / --backend B win; else config asr (auto: per purpose from `recommend`, only what is
installed; asr.auto false: asr.models / the legacy asr.backend + asr.model). Resource caps (asr.limits): threads,
one batch job at a time ($BLURT_HOME/run/asr.lock, the rest queue), low priority for batch work, an MLX memory cap.
Chinese comes back in the user's script: for zh-Hans users (or asr.chinese_script "hans") traditional characters
become simplified (OpenCC t2s, `to_user_script`); zh-Hant users keep what the model wrote.
Dependencies are pinned (here and in every `--with`, PACKAGE_PINS): a new release is taken on purpose, per release.

Backends (models: asr_models.json; measured: docs/design/asr-benchmark.md)
  sensevoice      local CPU, sherpa-onnx + SenseVoice-Small int8 (~230 MB). zh/en/ja/ko/yue.
  qwen3-asr-onnx  local CPU (any OS), sherpa-onnx + Qwen3-ASR 0.6B int8, 30 languages. Hotwords per stream.
  qwen3-asr-mlx   local, Apple Silicon (MLX), Qwen3-ASR 0.6B 8-bit, 30 languages, `context` biasing per request
                  (dictation's default: docs/design/dictation.md §Recognition model).  needs mlx-qwen3-asr
  mlx-whisper     local, Apple Silicon (MLX), Whisper large-v3-turbo (fp16 / 4-bit).  needs mlx-whisper
  faster-whisper  local, NVIDIA CUDA (or CPU), Whisper large-v3-turbo (CTranslate2).  needs faster-whisper
  openai          any OpenAI-compatible /audio/transcriptions API (OpenAI, Groq, SiliconFlow, ...)
                  env: BLURT_ASR_API_KEY (or OPENAI_API_KEY / GROQ_API_KEY), BLURT_ASR_BASE_URL, BLURT_ASR_MODEL
  dashscope       Alibaba Qwen3-ASR (qwen3-asr-flash) via DashScope OpenAI-compatible chat API. env: DASHSCOPE_API_KEY
Backends that need a package re-run themselves with `uv run --with <package>` when it is missing.
"""
from __future__ import annotations

import argparse
import contextlib
import base64
import io
import json
import os
import platform
import re
import select as _select  # `select` is this module's model pick
import shutil
import socket
import subprocess
import tempfile
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import dictation_vocab  # noqa: E402
from _common import (BLURT_HOME, IS_MAC, IS_WIN, MODELS_DIR, SERVE_IDLE, die, ffmpeg_bin, fmt_ts, global_config,  # noqa: E402
                     landed_in, load_json, probe_duration, progress_line, save_config_if_readable, save_json,
                     server_exit, serve_exit_reason, serve_said, use_system_certs)
from _common import (begin_download, download_lock, end_download, fetch, folder_complete,  # noqa: E402
                     safetensors_complete, watch_parent, write_text_atomic)

use_system_certs()

SR = 16000
HERE = Path(__file__).parent
VAD_URLS = [
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
    "https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx",
    "https://hf-mirror.com/csukuangfj/vad/resolve/main/silero_vad.onnx",
]
PURPOSES = ("batch", "live", "note")
# The VAD ships with the skill (models/silero_vad.onnx, 0.6 MB; Silero VAD, MIT, as k2-fsa/sherpa-onnx publishes it —
# the same bytes as VAD_URLS[0]). v1.0.6: on a fresh Mac it was all a local model lacked, and the island and the setup
# said "no speech model · 1 MB" for it. bundled_vad() puts it where the models live before anything looks for it.
BUNDLED_VAD = HERE.parent / "models" / "silero_vad.onnx"


def bundled_vad() -> None:
    dest = MODELS_DIR / "silero_vad.onnx"
    if dest.exists() or not BUNDLED_VAD.is_file():
        return
    try:
        MODELS_DIR.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".part")
        shutil.copyfile(BUNDLED_VAD, tmp)
        tmp.replace(dest)
    except OSError:
        pass            # the download still works
BENCH_FILE = BLURT_HOME / "asr-bench.json"
RUN_DIR = BLURT_HOME / "run"


class Fail(Exception):
    """A CLI failure with a machine code (next-round.md: {"ok": false, "error", "code"}, exit 1 / 3 / 4)."""

    def __init__(self, message: str, code: str = "error", exit_code: int = 1):
        super().__init__(message)
        self.code, self.exit_code = code, exit_code


class Interrupted(Exception):
    """An interim decode (dictation's live text) stopped because another request is waiting (docs/design/dictation.md
    §Live text): the final pieces never wait for one."""


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


# ------------------------------------------------------------------ the model registry (asr_models.json)
_REGISTRY: dict | None = None


def registry() -> dict:
    global _REGISTRY
    if _REGISTRY is None:
        _REGISTRY = json.loads((HERE / "asr_models.json").read_text(encoding="utf-8"))
    return _REGISTRY


def entries(local_only: bool = False) -> list[dict]:
    return [m for m in registry()["models"] if not local_only or m.get("local", True)]


def entry(model_id: str | None) -> dict | None:
    return next((m for m in registry()["models"] if m["id"] == model_id), None)


def entry_for(backend: str, model: str | None = None) -> dict | None:
    """The registry entry a legacy (backend, model) pair means; the backend's first entry when model is None."""
    cands = [m for m in registry()["models"] if m["backend"] == backend]
    if model:
        for m in cands:
            if model in (m["model"], m["id"]) or (m["model"] and m["model"].split("/")[-1] == model):
                return m
        if backend == "faster-whisper" and model == "large-v3-turbo":
            return entry("whisper-large-v3-turbo-ct2")
        return None
    return cands[0] if cands else None


def speaks(m: dict, lang: str) -> bool:
    langs = m.get("languages")
    return langs == "multi" or lang in (langs or [])


def platform_key() -> str:
    arch = platform.machine().lower()
    arch = {"amd64": "x86_64", "x64": "x86_64", "aarch64": "arm64"}.get(arch, arch)
    osname = "darwin" if IS_MAC else "windows" if IS_WIN else "linux"
    return f"{osname}-{arch}"


def runs_here(m: dict, plat: str | None = None) -> bool:
    plats = m.get("platforms") or ["*"]
    return "*" in plats or (plat or platform_key()) in plats


# ------------------------------------------------------------------ hardware probe and tiers
def _sysctl(name: str) -> str | None:
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=5).stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def _ram_bytes() -> int:
    try:
        if IS_MAC:
            return int(_sysctl("hw.memsize") or 0)
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
            return int(st.ullTotalPhys)
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (OSError, ValueError, AttributeError):
        return 0


def _cores() -> tuple[int, int, list[dict]]:
    """(performance cores, efficiency cores, per-level detail). Apple Silicon reports its core clusters as perf
    levels (M1–M4: Performance + Efficiency; M5 Pro / Max: Super + Performance); level 0 is the fastest."""
    total = os.cpu_count() or 1
    if IS_MAC:
        levels = []
        for i in range(int(_sysctl("hw.nperflevels") or 0)):
            n = int(_sysctl(f"hw.perflevel{i}.physicalcpu") or 0)
            levels.append({"name": _sysctl(f"hw.perflevel{i}.name") or f"level{i}", "cores": n})
        if levels:
            return levels[0]["cores"], sum(lv["cores"] for lv in levels[1:]), levels
        phys = int(_sysctl("hw.physicalcpu") or total)
        return phys, 0, []
    try:  # physical cores where the OS tells us (Linux: unique core ids)
        if not IS_WIN and Path("/proc/cpuinfo").exists():
            ids = set(re.findall(r"physical id\s*:\s*(\d+)[\s\S]*?core id\s*:\s*(\d+)", Path("/proc/cpuinfo").read_text()))
            if ids:
                return len(ids), 0, []
    except OSError:
        pass
    return max(1, total // 2) if total > 2 else total, 0, []


def _apple_gpu() -> dict | None:
    try:
        out = subprocess.run(["ioreg", "-r", "-c", "AGXAccelerator", "-d", "1"], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    cores = re.search(r'"gpu-core-count"\s*=\s*(\d+)', out)
    name = re.search(r'"model"\s*=\s*"([^"]+)"', out)
    return {"kind": "apple", "name": name.group(1) if name else "Apple GPU", **({"cores": int(cores.group(1))} if cores else {})}


def _nvidia_gpu() -> dict | None:
    if not shutil.which("nvidia-smi"):
        return None
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout.strip().splitlines()
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not out:
        return None
    name, _, mem = out[0].rpartition(",")
    try:
        vram = round(float(mem) / 1024, 1)
    except ValueError:
        vram = None
    return {"kind": "nvidia", "name": name.strip(), **({"vram_gb": vram} if vram else {})}


def on_battery() -> bool:
    try:
        if IS_MAC:
            out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
            return "Battery Power" in out
        if IS_WIN:
            import ctypes

            class SPS(ctypes.Structure):
                _fields_ = [("ACLineStatus", ctypes.c_byte), ("BatteryFlag", ctypes.c_byte),
                            ("BatteryLifePercent", ctypes.c_byte), ("SystemStatusFlag", ctypes.c_byte),
                            ("BatteryLifeTime", ctypes.c_ulong), ("BatteryFullLifeTime", ctypes.c_ulong)]
            s = SPS()
            return bool(ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s))) and s.ACLineStatus == 0
        mains = [p for p in Path("/sys/class/power_supply").glob("*") if (p / "online").exists()]
        return bool(mains) and all((p / "online").read_text().strip() == "0" for p in mains)
    except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired):
        return False


def tier_for(hw: dict) -> str:
    """K9 tiers. Apple Silicon by unified memory; NVIDIA by VRAM; other machines by cores and RAM."""
    ram, cores, gpu = hw["ram_gb"], hw["perf_cores"] + hw["eff_cores"], hw["gpu"]
    if ram < 7.5 or cores <= 2:
        return "minimal"
    if hw["arch"] == "arm64" and hw["os"] == "darwin":
        return "pro" if ram >= 30 else "standard" if ram >= 15 else "light"
    vram = gpu.get("vram_gb") or 0
    if gpu.get("kind") == "nvidia" and vram >= 8:
        return "pro"
    if gpu.get("kind") == "nvidia" and vram >= 4:
        return "standard"
    if cores >= 8 and ram >= 15:
        return "standard"
    return "light"


_HW: dict | None = None


def probe(refresh: bool = False) -> dict:
    global _HW
    if _HW is not None and not refresh:
        return _HW
    perf, eff, levels = _cores()
    osname = "darwin" if IS_MAC else "windows" if IS_WIN else "linux"
    arch = platform_key().split("-", 1)[1]
    gpu = (_apple_gpu() if IS_MAC and arch == "arm64" else None) or _nvidia_gpu() or {"kind": "none", "name": None}
    chip = (_sysctl("machdep.cpu.brand_string") if IS_MAC else None) or platform.processor() or platform.machine()
    hw = {"os": osname, "arch": arch, "chip": chip, "perf_cores": perf, "eff_cores": eff,
          "ram_gb": round(_ram_bytes() / 2**30, 1), "gpu": gpu, "ane": IS_MAC and arch == "arm64",
          "on_battery": on_battery()}
    if levels:
        hw["core_levels"] = levels
    hw["tier"] = tier_for(hw)
    hw["fingerprint"] = f"{chip}|{hw['ram_gb']:.0f}GB|{gpu.get('name')}|{gpu.get('cores') or gpu.get('vram_gb') or ''}"
    _HW = hw
    return hw


# ------------------------------------------------------------------ languages
def system_languages() -> list[str]:
    """The OS's preferred languages as ISO 639-1 codes (zh-Hant-HK → zh, yue stays yue), first = most preferred."""
    out: list[str] = []
    for tag in system_language_tags():
        code = re.split(r"[-_.@]", tag)[0].lower()
        if code in ("c", "posix", ""):
            continue
        if tag.lower().startswith(("zh-hk", "zh_hk", "yue")):
            code = "yue" if tag.lower().startswith("yue") else "zh"
        if code not in out:
            out.append(code)
    return out


def system_language_tags() -> list[str]:
    """The OS's preferred languages as it names them (zh-Hans-CN, en-US …), first = most preferred."""
    raw: list[str] = []
    try:
        if IS_MAC:
            out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True, timeout=5).stdout
            raw = re.findall(r'"?([A-Za-z]{2,3}(?:-[A-Za-z0-9]+)*)"?\s*,?\s*\n', out)
        elif IS_WIN:
            import ctypes
            n, size = ctypes.c_ulong(), ctypes.c_ulong()
            if ctypes.windll.kernel32.GetUserPreferredUILanguages(8, ctypes.byref(n), None, ctypes.byref(size)):
                buf = ctypes.create_unicode_buffer(size.value)
                ctypes.windll.kernel32.GetUserPreferredUILanguages(8, ctypes.byref(n), buf, ctypes.byref(size))
                raw = [s for s in buf[:size.value].split("\0") if s]
        else:
            raw = [p for p in (os.environ.get("LANGUAGE") or os.environ.get("LC_ALL") or os.environ.get("LANG") or "").split(":") if p]
    except (OSError, subprocess.TimeoutExpired, AttributeError):
        pass
    return raw


# The Chinese script the user reads (desi065): Whisper large-v3-turbo writes Mandarin in traditional characters, or
# a mix ("登录頁面周五之前要上線"), for a zh-Hans user. Whisper has no setting for the script (its language token is
# just "zh"), and the usual trick — an initial prompt in simplified Chinese — was measured and dropped: it fixed the
# characters, but on an English note it once sent the model into a loop ("段段段…") and it glued English names to
# the Chinese around them. So text heard as Chinese is converted character by character to the user's script
# (OpenCC's t2s tables: a mechanical script mapping that reads no meaning). zh-Hant users (zh-TW / zh-HK / zh-MO, or
# asr.chinese_script "hant") keep what the model wrote: nothing is converted for them. Qwen3-ASR (dictation) and
# SenseVoice write simplified already; the conversion changes nothing there.
_HANT_TAGS = ("zh-hant", "zh_hant", "zh-tw", "zh_tw", "zh-hk", "zh_hk", "zh-mo", "zh_mo", "yue")
_script: dict = {}


def chinese_script(cfg: dict | None = None) -> str | None:
    """"hans" | "hant" | None: asr.chinese_script, else the first Chinese entry of the OS's preferred languages
    (zh-Hans-CN, zh-CN, zh → hans; zh-Hant-*, zh-TW, zh-HK, zh-MO, yue → hant); None without Chinese. Read once a
    process."""
    cfg = asr_config() if cfg is None else cfg
    if cfg.get("chinese_script") in ("hans", "hant"):
        return cfg["chinese_script"]
    if "system" not in _script:
        tag = next((t.lower() for t in system_language_tags() if t.lower().startswith(("zh", "yue"))), None)
        _script["system"] = None if tag is None else "hant" if tag.startswith(_HANT_TAGS) else "hans"
    return _script["system"]


_KANA = re.compile(r"[぀-ヿ]")


def to_user_script(text: str, lang: str | None, script: str | None = None) -> str:
    """Text the speech model heard as Chinese (or with no language said), in a zh-Hans user's script: traditional
    characters → simplified, one by one. Japanese (kana, or tagged ja) and everyone else's text are left alone."""
    script = script if script is not None else chinese_script()
    if script != "hans" or not text or (lang and lang not in ("zh", "yue")) or _KANA.search(text):
        return text
    if not re.search(r"[㐀-鿿]", text):
        return text
    conv = _script.get("t2s")
    if conv is None:
        try:
            from opencc import OpenCC
            conv = OpenCC("t2s").convert
        except Exception as e:  # noqa: BLE001 — the package missing must not cost the words
            print(f"script conversion unavailable: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            conv = False
        _script["t2s"] = conv
    return conv(text) if conv else text


SWITCH_LANGUAGES = {"zh": "Chinese", "yue": "Cantonese", "ja": "Japanese", "ko": "Korean"}


def switch_language(langs: list[str]) -> str | None:
    """The language a user mixes English names into, as Qwen3-ASR names it: the first of their languages that people
    commonly speak with English words inside it (zh → "Chinese"). None for English-only users."""
    return next((SWITCH_LANGUAGES[c] for c in langs if c in SWITCH_LANGUAGES), None)


def user_languages(cfg: dict | None = None) -> list[str]:
    """asr.languages, else the system's preferred languages ∪ {en}."""
    cfg = asr_config() if cfg is None else cfg
    langs = cfg.get("languages")
    if isinstance(langs, str):
        langs = [x.strip() for x in langs.split(",") if x.strip()]
    if not langs:
        langs = system_languages()
        if cfg.get("language") and cfg["language"] not in langs:  # the spoken language the user picked
            langs.insert(0, cfg["language"])
        if "en" not in langs:
            langs.append("en")
    return list(dict.fromkeys(langs))


# ------------------------------------------------------------------ configuration
def asr_config() -> dict:
    c = global_config().get("asr")
    return c if isinstance(c, dict) else {}


def is_auto(cfg: dict) -> bool:
    """asr.auto, default true — except for a legacy explicit choice of a non-default backend (kept as the user's)."""
    if "auto" in cfg:
        return cfg["auto"] is not False
    return not (cfg.get("backend") and cfg.get("backend") != "sensevoice")


def local_only() -> bool:
    return bool((global_config().get("privacy") or {}).get("local_asr"))


def limits(hw: dict | None = None, cfg: dict | None = None) -> dict:
    """asr.limits with K9 defaults: threads = max(1, min(4, perf_cores // 2)); one batch job at a time;
    batch at utility / nice 10, live and voice notes at user-initiated; MLX may use a quarter of the memory."""
    hw = hw or probe()
    lim = dict((cfg if cfg is not None else asr_config()).get("limits") or {})
    prio = {"batch": "utility", "live": "user-initiated", "note": "user-initiated", "bench": "utility"}
    if isinstance(lim.get("priority"), dict):
        prio.update(lim["priority"])
    elif isinstance(lim.get("priority"), str):
        prio["batch"] = prio["bench"] = lim["priority"]
    return {"threads": max(1, int(lim.get("threads") or max(1, min(4, hw["perf_cores"] // 2)))),
            "max_concurrent": max(1, int(lim.get("max_concurrent") or 1)),
            "priority": prio,
            "max_memory_fraction": min(0.9, max(0.05, float(lim.get("max_memory_fraction") or 0.25)))}


# ------------------------------------------------------------------ resource caps
QOS = {"user-interactive": 0x21, "user-initiated": 0x19, "default": 0x15, "utility": 0x11, "background": 0x09}


def apply_priority(level: str, reexec: bool = True) -> dict:
    """Lower this process's priority before any model or worker thread exists. macOS: worker threads that runtimes
    create (onnxruntime, CTranslate2) do not inherit the creating thread's QoS, so utility / background work re-runs
    itself once under `taskpolicy -c <level>` (a QoS clamp on every thread of the process) — plus nice; the calling
    thread's QoS is set either way. Windows: priority class. Linux: nice. Returns what was applied."""
    done: dict = {"level": level}
    nice = {"background": 15, "utility": 10}.get(level, 0)
    if IS_MAC and reexec and level in ("utility", "background") and os.environ.get("BLURT_QOS_CLAMP") != level \
            and Path("/usr/sbin/taskpolicy").exists() and sys.argv and sys.argv[0].endswith(".py"):
        os.environ["BLURT_QOS_CLAMP"] = level
        sys.stdout.flush()
        sys.stderr.flush()
        os.execv("/usr/sbin/taskpolicy", ["taskpolicy", "-c", level, sys.executable, os.path.abspath(sys.argv[0]),
                                          *sys.argv[1:]])
    if IS_MAC and os.environ.get("BLURT_QOS_CLAMP") == level:
        done["clamp"] = level
    if IS_MAC:
        try:
            import ctypes
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            if lib.pthread_set_qos_class_self_np(ctypes.c_uint(QOS.get(level, 0x15)), 0) == 0:
                done["qos"] = level
        except (OSError, AttributeError):
            pass
    if IS_WIN:
        try:
            import ctypes
            cls = {"background": 0x40, "utility": 0x4000}.get(level, 0x20)  # IDLE / BELOW_NORMAL / NORMAL
            if ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), cls):
                done["priority_class"] = cls
        except (OSError, AttributeError):
            pass
    elif nice:
        try:
            cur = os.getpriority(os.PRIO_PROCESS, 0)
            if cur < nice:
                os.setpriority(os.PRIO_PROCESS, 0, nice)
            done["nice"] = os.getpriority(os.PRIO_PROCESS, 0)
        except (OSError, AttributeError):
            pass
    return done


def cap_threads(n: int) -> None:
    """BLAS / OpenMP pools size themselves at import: set the caps first."""
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
              "NUMEXPR_NUM_THREADS", "RAYON_NUM_THREADS"):
        os.environ[k] = str(n)


# MLX's cache of freed buffers, kept for reuse. It used to be min(limit / 4, 2 GB): the warm servers then held what
# their warm-up had freed (polish's two prompt prefills: ~1.5 GB) until the first request — 4.6 GB instead of 3.1 GB
# for Gemma 4 E2B. 64 MB costs 2.4 ms a polish request with the same output (0 MB: +68 ms); docs/design/dictation.md
# §Memory.
MLX_CACHE_BYTES = 64 << 20


def cap_mlx_memory(fraction: float) -> int | None:
    """Keep MLX (which otherwise grows its buffer cache to most of unified memory) inside fraction × RAM, and its cache
    of freed buffers small (MLX_CACHE_BYTES)."""
    try:
        import mlx.core as mx
    except ImportError:
        return None
    total = _ram_bytes()
    if not total:
        return None
    limit = int(total * fraction)
    for fn, val in (("set_memory_limit", limit), ("set_cache_limit", min(limit // 4, MLX_CACHE_BYTES))):
        f = getattr(mx, fn, None) or getattr(getattr(mx, "metal", None), fn, None)
        if f:
            try:
                f(val)
            except Exception:  # noqa: BLE001 — an older MLX without the call
                pass
    return limit


class AsrSlot:
    """At most N concurrent batch transcriptions machine-wide: byte-range locks on $BLURT_HOME/run/asr.lock
    (released by the OS when a process dies). Waiting = queued: said on stderr and, under a job ($BLURT_JOB),
    as events in jobs/<id>.events.jsonl (K4). A run that can't write $BLURT_HOME (an organizing agent in its
    sandbox) transcribes without a slot."""

    _held: set[int] = set()       # slots this process holds (record locks are per process, not per thread)
    _guard = threading.Lock()
    _file = None                  # one descriptor per process: closing any descriptor drops all of its locks

    def __init__(self, n: int, timeout: float = 6 * 3600, poll: float = 0.25):
        self.n, self.timeout, self.poll = n, timeout, poll
        self.fh = None
        self.slot: int | None = None
        self.waited = 0.0

    def _try(self, i: int) -> bool:
        with AsrSlot._guard:
            if i in AsrSlot._held or not self._lock(i):
                return False
            AsrSlot._held.add(i)
            return True

    def _lock(self, i: int) -> bool:
        try:
            if IS_WIN:
                import msvcrt
                self.fh.seek(i)
                msvcrt.locking(self.fh.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.lockf(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, i, 0)
            return True
        except OSError:
            return False

    def __enter__(self):
        with AsrSlot._guard:
            if AsrSlot._file is None:
                try:
                    RUN_DIR.mkdir(parents=True, exist_ok=True)
                    AsrSlot._file = open(RUN_DIR / "asr.lock", "a+b")
                except PermissionError:
                    print("asr: $BLURT_HOME/run is read-only here (a sandboxed run): not queued", file=sys.stderr, flush=True)
                    return self
        self.fh = AsrSlot._file
        t0 = time.time()
        queued = False
        while True:
            for i in range(self.n):
                if self._try(i):
                    self.slot = i
                    self.waited = time.time() - t0
                    if queued:
                        print("asr: slot free, starting", file=sys.stderr, flush=True)
                        job_event("asr.started", {"id": "transcribe", "state": "running"}, {"waited_seconds": round(self.waited, 1)})
                    return self
            if not queued:
                queued = True
                print(f"asr: queued (max_concurrent={self.n}; another transcription is running)", file=sys.stderr, flush=True)
                job_event("asr.queued", {"id": "transcribe", "state": "pending"}, {"queued": True, "max_concurrent": self.n})
            if time.time() - t0 > self.timeout:
                raise Fail(f"waited {self.timeout:.0f}s for a free ASR slot", "lock_timeout", 3)
            time.sleep(self.poll)

    def __exit__(self, *exc):
        if self.slot is None:
            return False
        with AsrSlot._guard:
            try:
                if IS_WIN:
                    import msvcrt
                    self.fh.seek(self.slot)
                    msvcrt.locking(self.fh.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.lockf(self.fh, fcntl.LOCK_UN, 1, self.slot, 0)
            except OSError:
                pass
            AsrSlot._held.discard(self.slot)
        return False


def job_event(event: str, step: dict | None = None, detail: dict | None = None) -> None:
    job = os.environ.get("BLURT_JOB")
    if not job or not re.fullmatch(r"[A-Za-z0-9._-]+", job):
        return
    line = {"t": datetime.now().astimezone().isoformat(timespec="seconds"), "source": "asr", "event": event}
    if step:
        line["step"] = step
    if detail:
        line["detail"] = detail
    try:
        (BLURT_HOME / "jobs").mkdir(parents=True, exist_ok=True)
        fd = os.open(BLURT_HOME / "jobs" / f"{job}.events.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (json.dumps(line, ensure_ascii=False) + "\n").encode())
        finally:
            os.close(fd)
    except OSError:
        pass


def peak_memory_mb() -> float | None:
    """This process's peak memory: macOS lifetime max physical footprint (counts GPU buffers in unified memory),
    Linux max RSS, Windows peak working set."""
    try:
        if IS_MAC:
            import ctypes
            buf = (ctypes.c_uint64 * 64)()
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            if lib.proc_pid_rusage(os.getpid(), 4, ctypes.byref(buf)) == 0:  # RUSAGE_INFO_V4
                return round(buf[2 + 28] / 2**20, 1)  # after the 16-byte uuid: ri_lifetime_max_phys_footprint
            return None
        if IS_WIN:
            import ctypes
            from ctypes import wintypes

            class PMC(ctypes.Structure):
                _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                            ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                            ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]
            c = PMC()
            c.cb = ctypes.sizeof(PMC)
            ctypes.windll.psapi.GetProcessMemoryInfo(ctypes.windll.kernel32.GetCurrentProcess(), ctypes.byref(c), c.cb)
            return round(c.PeakWorkingSetSize / 2**20, 1)
        import resource
        return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1)
    except Exception:  # noqa: BLE001 — measurement only
        return None


def qos_cpu_seconds() -> dict | None:
    """macOS: CPU seconds this process spent per QoS class (proves the priority took effect)."""
    if not IS_MAC:
        return None
    try:
        import ctypes
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        buf = (ctypes.c_uint64 * 64)()
        if lib.proc_pid_rusage(os.getpid(), 4, ctypes.byref(buf)) != 0:
            return None
        tb = (ctypes.c_uint32 * 2)()  # mach_timebase_info: the counters are in mach ticks (41.67 ns on Apple Silicon)
        lib.mach_timebase_info(ctypes.byref(tb))
        ns = tb[0] / tb[1] if tb[1] else 1.0
        names = ("default", "maintenance", "background", "utility", "legacy", "user_initiated", "user_interactive")
        return {n: round(buf[2 + 18 + i] * ns / 1e9, 2) for i, n in enumerate(names) if buf[2 + 18 + i]}
    except (OSError, AttributeError):
        return None


# ------------------------------------------------------------------ downloads
def _download_url(urls: list[str], dest: Path, label: str, aux: str | None = None) -> Path:
    if os.environ.get("BLURT_HF_MIRROR"):  # the China-friendly mirror first
        urls = sorted(urls, key=lambda u: "hf-mirror" not in u)
    dest.parent.mkdir(parents=True, exist_ok=True)
    last = None
    for url in urls:
        try:
            serve_said(f"downloading {label} <- {url}")
            tmp = dest.with_suffix(dest.suffix + ".part")      # a partial one from last time is continued (Range)
            t0 = [time.time()]

            def progress(done: int, total: int) -> None:
                if total and time.time() - t0[0] > 1:
                    serve_said(progress_line(done, total, aux))
                    t0[0] = time.time()
            fetch(url, tmp, progress=progress, timeout=30)
            os.replace(tmp, dest)
            return dest
        except Exception as e:  # noqa: BLE001 — try the next mirror
            last = e
            print(f"  failed: {e}", file=sys.stderr)
    raise Fail(f"could not download {label}: {last}. Set BLURT_HF_MIRROR=1 or download manually to {dest}", "network")


def download(rel: str, aux: str | None = None) -> Path:
    """A single model file under MODELS_DIR (the VAD, SenseVoice's files). `aux`: fetched on the way to another
    model (its progress lines are named so: progress_line)."""
    dest = MODELS_DIR / rel
    if rel == "silero_vad.onnx":
        bundled_vad()
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    if os.environ.get("BLURT_NO_DOWNLOAD"):  # live.py: never start a download in the middle of a recording
        raise Fail(f"{rel} is not downloaded", "model_missing")
    urls = VAD_URLS if rel == "silero_vad.onnx" else next(
        (u for m in entries() for f, u in ((m.get("install") or {}).get("files") or {}).items() if f == rel), None)
    if not urls:
        raise Fail(f"no download source for {rel}", "model_missing")
    return _download_url(urls, dest, rel, aux)


def hf_cache() -> Path:
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"])
    return Path(os.environ.get("HF_HOME") or Path.home() / ".cache" / "huggingface") / "hub"


def _hf_record(repo: str) -> Path:
    """What a finished `snapshot_download` of `repo` left: MODELS_DIR/asr/.hf/<repo>.json (its snapshot and files)."""
    return MODELS_DIR / "asr" / ".hf" / (repo.replace("/", "--") + ".json")


def _snapshot_complete(s: Path, repo: str) -> bool:
    """A Hugging Face snapshot is a whole model. One `setup` saw finish: every file it listed is there. One from before
    that record (or fetched by something else): its weights, its config, every shard its index names, and the
    tokenizer its tokenizer_config.json asks for — a setup cut short between files leaves one of them out."""
    rec = load_json(_hf_record(repo), None)
    if isinstance(rec, dict) and rec.get("snapshot") == s.name and isinstance(rec.get("files"), list):
        return all((s / f).is_file() for f in rec["files"])
    names = {f.name for f in s.iterdir()} if s.is_dir() else set()
    if not any(f.endswith((".safetensors", ".npz", ".bin")) and not f.startswith("training_args") for f in names):
        return False
    if "config.json" not in names or any(f.endswith((".part", ".incomplete")) for f in names):
        return False
    if any(f.endswith(".safetensors") for f in names) and not safetensors_complete(s):
        return False
    if "tokenizer_config.json" in names and not names & {"tokenizer.json", "vocab.json", "tokenizer.model"}:
        return False
    if "tokenizer_config.json" in names and "vocab.json" in names and "tokenizer.json" not in names \
            and "merges.txt" not in names:          # a BPE tokenizer in two files: both
        return False
    return True


def hf_snapshot(repo: str) -> Path | None:
    """The newest complete snapshot of `repo` in the Hugging Face cache (_snapshot_complete), else None."""
    root = hf_cache() / ("models--" + repo.replace("/", "--"))
    snaps = sorted((root / "snapshots").glob("*"), key=lambda p: p.stat().st_mtime, reverse=True) if root.is_dir() else []
    if any((root / "blobs").glob("*.incomplete")):
        return None
    for s in snaps:
        if _snapshot_complete(s, repo):
            return s
    return None


def model_path(m: dict) -> Path | None:
    """Where an installed model lives, or None when it is not installed."""
    inst = m.get("install") or {}
    if inst.get("files"):
        paths = [MODELS_DIR / f for f in inst["files"]]
        return paths[0].parent if all(p.exists() and p.stat().st_size > 0 for p in paths) else None
    if inst.get("archive"):
        d = MODELS_DIR / inst["dir"]
        need = [d / k.rstrip("/") for k in inst.get("keep", [])]
        return d if d.is_dir() and all(p.exists() for p in need) else None
    if inst.get("hf"):
        own = MODELS_DIR / "asr" / inst["hf"].split("/")[-1]       # a ModelScope download (the mirror)
        if folder_complete(own, legacy=_own_legacy_complete):
            return own
        snap = hf_snapshot(inst["hf"])
        if snap is None and m["backend"] == "faster-whisper":  # older Blurt downloaded it under models/faster-whisper
            legacy = MODELS_DIR / "faster-whisper"
            if legacy.is_dir():
                snap = next((p for p in legacy.rglob("model.bin") if "turbo" in str(p)), None)
                snap = snap.parent if snap else None
        return snap
    return None


def _own_legacy_complete(d: Path) -> bool:
    """A mirror download from before the manifest: its config, every weight shard, and no file still partial."""
    return (d / "config.json").exists() and safetensors_complete(d) and not any(d.glob("*.part"))


def installed(m: dict) -> bool:
    if not m.get("local", True):
        return any(os.environ.get(k) for k in m.get("keys", []))
    if m.get("builtin"):
        return apple_speech_ok()
    return model_path(m) is not None


# macOS's own speech recognition (docs/design/first-minute-speech.md): SpeechTranscriber, macOS 26+, run by the Blurt
# app's executable (`blurt-recorder --speech WAV`: Capture/AppleSpeech.swift). Nothing to download from Blurt; the
# language's files are macOS's own (the app asks for them; a run without them fails "model_missing").
APPLE = "apple-speech"
APPLE_LOCALES = {"zh": "zh-CN", "zh-hant": "zh-TW", "yue": "yue-CN", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR",
                 "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-BR"}


def apple_speech_helper() -> Path | None:
    """The Blurt executable that answers `--speech` (BLURT_APP_BIN from the app, else an installed Blurt.app)."""
    cands = [os.environ.get("BLURT_APP_BIN") or "", str(BLURT_HOME / "Blurt.app/Contents/MacOS/blurt-recorder"),
             "/Applications/Blurt.app/Contents/MacOS/blurt-recorder",
             str(Path.home() / "Applications/Blurt.app/Contents/MacOS/blurt-recorder")]
    return next((Path(c) for c in cands if c and os.access(c, os.X_OK)), None)


_APPLE_OK: bool | None = None


def apple_speech_ok() -> bool:
    """macOS 26 or later, and a Blurt that can run it."""
    global _APPLE_OK
    if os.environ.get("BLURT_NO_APPLE_SPEECH"):     # tests: a Mac before macOS 26
        return False
    if _APPLE_OK is None:
        try:
            major = int((platform.mac_ver()[0] or "0").split(".")[0]) if IS_MAC else 0
        except ValueError:
            major = 0
        _APPLE_OK = major >= 26 and apple_speech_helper() is not None
    return _APPLE_OK


def apple_locale(language: str | None) -> str | None:
    """The locale for an explicit language (or asr.language), else the app's "Automatic" (AppleSpeech.automatic, the
    same rule so recordings and dictation hear the same language): of the user's languages the first one people mix
    English into (SWITCH_LANGUAGES: its recogniser hears the English words too), else the first one macOS's
    recogniser speaks. An English Mac that lists Chinese too listens for Chinese, English included."""
    picked = asr_config().get("language")
    if language and language not in ("auto", ""):
        langs = [language]
    elif picked and picked != "auto":
        langs = [picked]
    else:
        spoken = [x for x in user_languages() if x in APPLE_LOCALES]
        langs = [x for x in spoken if x in SWITCH_LANGUAGES] + spoken
    for lang in langs:
        if lang == "zh" and chinese_script() == "hant":
            lang = "zh-hant"
        if lang in APPLE_LOCALES:
            return APPLE_LOCALES[lang]
    return None


def _du_mb(p: Path) -> float:
    if p.is_file():
        return round(p.stat().st_size / 2**20, 1)
    total = 0
    for f in p.rglob("*"):
        try:
            total += f.stat().st_size if f.is_file() else 0  # stat follows the HF cache's symlinks into blobs/
        except OSError:
            pass
    return round(total / 2**20, 1)


def _progress_poller(target: Path, total_mb: float, stop: threading.Event) -> None:
    """HF downloads: report '  N/M MB' from what has landed on disk (incl. *.incomplete blobs: _common.landed_in)."""
    while not stop.wait(1.0):
        if target.exists():
            serve_said(progress_line(min(landed_in(target), total_mb * 2**20), total_mb * 2**20))


def install_model(m: dict) -> Path:
    """Download a registry model (and the VAD every local backend needs). Progress on stderr. One download of a
    model at a time (download_lock): a second caller waits, then finds it installed."""
    download("silero_vad.onnx", aux="vad")      # its own named progress: not the model's (progress_line)
    if not m.get("local", True):
        return MODELS_DIR
    have = model_path(m)
    if have:
        return have
    if os.environ.get("BLURT_NO_DOWNLOAD"):
        raise Fail(f"{m['id']} is not downloaded", "model_missing")
    if not runs_here(m):
        raise Fail(f"{m['id']} does not run on {platform_key()}", "unsupported")
    with download_lock(m["id"]):
        have = model_path(m)                  # the other download finished while this one waited
        if have:
            return have
        return _install_unlocked(m)


def _install_unlocked(m: dict) -> Path:
    inst = m["install"]
    if inst.get("files"):
        for rel in inst["files"]:
            download(rel)
    elif inst.get("archive"):
        _install_archive(m)
    elif inst.get("hf"):
        ensure_package(m)
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")  # our "  N/M MB" lines are the progress
        from huggingface_hub import snapshot_download
        if os.environ.get("BLURT_HF_MIRROR"):
            os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
        mirrored = inst["hf"].startswith("mlx-community/")      # ModelScope mirrors mlx-community (fast from China)
        if mirrored and os.environ.get("BLURT_HF_MIRROR"):
            _modelscope(inst["hf"], float(m["size_mb"]))
        else:
            print(f"downloading {inst['hf']}", file=sys.stderr, flush=True)
            stop = threading.Event()
            target = hf_cache() / ("models--" + inst["hf"].replace("/", "--"))
            th = threading.Thread(target=_progress_poller, args=(target, float(m["size_mb"]), stop), daemon=True)
            th.start()
            try:
                snap = Path(snapshot_download(inst["hf"]))
                # it finished: what it brought is the model (hf_snapshot checks against this list from now on)
                write_text_atomic(_hf_record(inst["hf"]), json.dumps(
                    {"snapshot": snap.name, "files": sorted(str(f.relative_to(snap)) for f in snap.rglob("*") if f.is_file())}))
            except Exception as e:  # noqa: BLE001
                if not mirrored:
                    raise Fail(f"could not download {inst['hf']}: {e}", "network")
                print(f"  Hugging Face failed ({e}); trying ModelScope", file=sys.stderr, flush=True)
                _modelscope(inst["hf"], float(m["size_mb"]))
            finally:
                stop.set()
    path = model_path(m)
    if not path:
        raise Fail(f"{m['id']}: download finished but the files are not complete", "model_missing")
    return path


def _modelscope(repo: str, total_mb: float) -> Path:
    """An mlx-community repo from ModelScope's mirror → MODELS_DIR/asr/<name>: the manifest and the download marker
    first (the folder is a model only once every file is in: folder_complete), each file through <name>.part,
    continued where a cut-short download left it."""
    dest = MODELS_DIR / "asr" / repo.split("/")[-1]
    api = f"https://modelscope.cn/api/v1/models/{repo}/repo/files?Recursive=true"
    try:
        with urllib.request.urlopen(urllib.request.Request(api, headers={"User-Agent": "blurt"}), timeout=30) as r:
            files = json.load(r)["Data"]["Files"]
    except Exception as e:  # noqa: BLE001
        raise Fail(f"could not download {repo} from ModelScope: {e}", "network")
    want = [x for x in files if x.get("Type") == "blob" and not x["Path"].endswith((".md", ".gitattributes"))]
    begin_download(dest, [{"path": x["Path"], "size": x.get("Size")} for x in want])
    done = 0.0
    serve_said(f"downloading {repo} (ModelScope)")
    for x in want:
        p = dest / x["Path"]
        if p.exists() and p.stat().st_size == x.get("Size"):
            done += p.stat().st_size / 2**20
            continue
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".part")
        url = f"https://modelscope.cn/models/{repo}/resolve/master/{x['Path']}"
        t0 = [time.time()]

        def progress(have: int, _total: int) -> None:
            if time.time() - t0[0] > 1:
                serve_said(f"  {int(done + have / 2**20)}/{int(total_mb)} MB")
                t0[0] = time.time()
        got = 0
        for attempt in range(3):
            try:
                got = fetch(url, tmp, x.get("Size"), progress)       # each try continues the last one's bytes
            except Exception as e:  # noqa: BLE001
                if attempt == 2:
                    raise Fail(f"could not download {repo} from ModelScope: {e}", "network")
                continue
            if not x.get("Size") or got == x["Size"]:          # a dropped connection can end the read quietly
                break
            if attempt == 2:
                raise Fail(f"could not download {repo} from ModelScope: {x['Path']} came short", "network")
        done += got / 2**20
        os.replace(tmp, p)
    end_download(dest)
    return dest


def _install_archive(m: dict) -> None:
    import tarfile
    inst = m["install"]
    dest = MODELS_DIR / inst["dir"]
    tmp = MODELS_DIR / f".{inst['dir']}.tar.bz2"
    _download_url([inst["archive"]], tmp, m["id"])
    staging = MODELS_DIR / f".{inst['dir']}.extract"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    keep = inst.get("keep") or []
    with tarfile.open(tmp, "r:bz2") as tar:
        members = []
        for mem in tar.getmembers():
            parts = Path(mem.name).parts
            rel = "/".join(parts[1:])  # drop the archive's top folder
            if not rel or ".." in parts or mem.name.startswith("/") or not (mem.isfile() or mem.isdir()):
                continue
            if keep and not any(rel == k or (k.endswith("/") and rel.startswith(k)) for k in keep):
                continue
            mem.name = rel
            members.append(mem)
        print(f"unpacking {m['id']}", file=sys.stderr, flush=True)
        tar.extractall(staging, members=members, **({"filter": "data"} if sys.version_info >= (3, 12) else {}))
    shutil.rmtree(dest, ignore_errors=True)
    os.replace(staging, dest)
    tmp.unlink(missing_ok=True)


# ------------------------------------------------------------------ optional packages
def ensure_package(m: dict | str) -> None:
    """Backends that need a Python package (mlx-whisper, parakeet-mlx, …): re-run this very command under
    `uv run --with <package>` when it is missing, so callers never need to know."""
    pkg = m if isinstance(m, str) else m.get("package")
    if not pkg:
        return
    import importlib.util
    mod = pkg.replace("-", "_")
    if importlib.util.find_spec(mod) is not None:
        return
    uv = shutil.which("uv") or str(BLURT_HOME / "bin" / ("uv.exe" if IS_WIN else "uv"))
    tried = [p for p in os.environ.get("BLURT_ASR_REEXEC", "").split(",") if p]
    if pkg in tried or not Path(uv).exists() or not sys.argv[0].endswith(".py"):
        raise Fail(f"{pkg} is not installed (run with: uv run --with {pkg} {Path(sys.argv[0]).name} …)", "deps", 4)
    os.environ["BLURT_ASR_REEXEC"] = ",".join(tried + [pkg])
    sys.stdout.flush()
    sys.stderr.flush()
    withs = [x for p in tried + [pkg] for x in ("--with", PACKAGE_PINS.get(p, p))]
    os.execvp(uv, [uv, "run", "-q", *withs, os.path.abspath(sys.argv[0]), *sys.argv[1:]])


# ------------------------------------------------------------------ audio + VAD
def audio_tracks(path: Path) -> int:
    info = subprocess.run([ffmpeg_bin(), "-nostdin", "-hide_banner", "-i", str(path)], capture_output=True, text=True,
                          errors="replace").stderr
    return sum(1 for line in info.splitlines() if "Stream #" in line and "Audio:" in line)


def load_audio(path: Path, track: int = 0) -> np.ndarray:
    raw = subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-i", str(path), "-map", f"0:a:{track}", "-ac", "1",
                          "-af", "aresample=async=1000:first_pts=0", "-ar", str(SR), "-f", "s16le", "-"], capture_output=True).stdout
    if not raw:
        die(f"No audio track decoded from {path}")
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768


def read_wav(path: Path) -> np.ndarray:
    """A 16 kHz mono 16-bit WAV without ffmpeg (voice notes); anything else goes through load_audio."""
    try:
        with wave.open(str(path)) as w:
            if w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2:
                return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
    except (wave.Error, EOFError, OSError):
        pass
    return load_audio(path)


def make_vad(max_speech: float = 25):
    """Silero VAD as used everywhere (whole-file runs and live.py's streaming run share these settings)."""
    import sherpa_onnx
    cfg = sherpa_onnx.VadModelConfig()
    cfg.silero_vad.model = str(download("silero_vad.onnx"))
    cfg.silero_vad.threshold = 0.45
    cfg.silero_vad.min_silence_duration = 0.3
    cfg.silero_vad.min_speech_duration = 0.25
    cfg.silero_vad.max_speech_duration = max_speech
    cfg.sample_rate = SR
    cfg.num_threads = 1
    return sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=60), cfg.silero_vad.window_size


def pad_segment(s: float, e: float, dur: float = float("inf")) -> tuple[float, float]:
    """Pad a little so words at the edges are not clipped."""
    return max(0.0, s - 0.15), min(dur, e + 0.2)


def vad_segments(samples: np.ndarray, max_speech: float = 25) -> list[tuple[float, float]]:
    vad, win = make_vad(max_speech)
    segs = []

    def drain():
        while not vad.empty():
            seg = vad.front
            segs.append((seg.start / SR, (seg.start + len(seg.samples)) / SR))
            vad.pop()

    for i in range(0, len(samples), win):
        vad.accept_waveform(samples[i:i + win])
        drain()
    vad.flush()
    drain()
    dur = len(samples) / SR
    return [pad_segment(s, e, dur) for s, e in segs]


def group_chunks(segs: list[tuple[float, float]], max_len: float, max_gap: float = 1.0) -> list[tuple[float, float]]:
    """Merge neighbouring speech segments into contiguous windows (original timeline, no remapping needed)."""
    chunks: list[list[float]] = []
    for s, e in segs:
        if chunks and s - chunks[-1][1] <= max_gap and e - chunks[-1][0] <= max_len:
            chunks[-1][1] = e
        else:
            chunks.append([s, e])
    return [(s, e) for s, e in chunks]


def wav_bytes(samples: np.ndarray) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype(np.int16).tobytes())
    return buf.getvalue()


# ------------------------------------------------------------------ backends
# each backend: transcribe(samples) -> list[(rel_start, rel_end, text)] or [(…, text, language)]
LANG_NAMES = {"zh": "Chinese", "en": "English", "yue": "Cantonese", "ja": "Japanese", "ko": "Korean", "es": "Spanish",
              "fr": "French", "de": "German", "it": "Italian", "pt": "Portuguese", "ru": "Russian", "ar": "Arabic",
              "hi": "Hindi", "th": "Thai", "vi": "Vietnamese", "id": "Indonesian", "ms": "Malay", "tr": "Turkish",
              "nl": "Dutch", "sv": "Swedish", "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech",
              "el": "Greek", "hu": "Hungarian", "ro": "Romanian", "fa": "Persian", "fil": "Filipino", "mk": "Macedonian"}
LANG_CODES = {v.lower(): k for k, v in LANG_NAMES.items()}


def lang_code(v) -> str | None:
    """'<|zh|>' / 'Chinese' / 'zh' → 'zh'."""
    if not v or not isinstance(v, str):
        return None
    v = v.strip().strip("<|>").strip()
    return LANG_CODES.get(v.lower()) or (v.lower() if re.fullmatch(r"[a-z]{2,3}", v.lower()) else None)


_CJK = r"぀-ヿ㐀-鿿가-힯"


def syllables(text: str) -> int:
    """Rough syllable count in any script: a CJK character, kana or Hangul block is one; elsewhere a vowel group."""
    n = 0
    for w in re.findall(r"\w+", unicodedata.normalize("NFKC", text)):
        n += len(re.findall(f"[{_CJK}]", w))
        n += sum(max(1, len(re.findall(r"[aeiouyàáâãäåæèéêëìíîïòóôõöøœùúûüýÿаеёиоуыэюя]+", p.lower())))
                 for p in re.sub(f"[{_CJK}]", " ", w).split())
    return n


_FULLWIDTH = {",": "，", "?": "？", "!": "！", ":": "：", ";": "；"}


def cjk_punctuation(text: str) -> str:
    """Whisper writes Chinese / Japanese with ASCII commas ("页面,输入"): use the full-width marks readers expect."""
    return re.sub(f"(?<=[{_CJK}])([,?!:;])\\s*", lambda m: _FULLWIDTH[m.group(1)], text)


def _threads(args) -> int:
    return getattr(args, "threads", None) or limits()["threads"]


def _model_dir(args, default: str) -> Path:
    m = getattr(args, "model", None) or default
    return Path(m) if os.path.isabs(m) else MODELS_DIR / m


class SenseVoice:
    # SenseVoice degrades on long, mixed-language chunks (drops whole clauses); keep utterances short
    max_chunk = 10
    model = "sense-voice-small-int8"
    # Non-autoregressive (one CTC pass): a piece decodes in one call of about 60–120 ms on the CPU (a 4 s piece:
    # 59–84 ms, M-series), so there is nothing to stop halfway — an interim request (the live words of a voice note,
    # a snap's note, dictation) is served whole after one look for a waiting request (NoteEngine.note).
    quick_decode = True

    def __init__(self, args):
        import sherpa_onnx
        lang = args.language if args.language in ("zh", "en", "ja", "ko", "yue") else "auto"
        self.rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(download("sensevoice/model.int8.onnx")), tokens=str(download("sensevoice/tokens.txt")),
            num_threads=_threads(args), use_itn=True, language=lang)

    def transcribe(self, x):
        st = self.rec.create_stream()
        st.accept_waveform(SR, x)
        self.rec.decode_stream(st)
        return [(0.0, len(x) / SR, st.result.text.strip(), lang_code(getattr(st.result, "lang", None)))]

    # No set_vocab: sherpa-onnx can't bias SenseVoice (greedy CTC only; create_stream(hotwords=…) aborts the process
    # with "Only transducer models support contextual biasing"). Its words go to polish.


class Qwen3Onnx:
    """Qwen3-ASR 0.6B int8 on the CPU through sherpa-onnx: 30 languages on any OS."""
    max_chunk = 20
    max_terms = dictation_vocab.MAX_TERMS     # its hotwords

    def __init__(self, args):
        import sherpa_onnx
        d = _model_dir(args, "qwen3-asr-0.6b-int8")
        if not (d / "decoder.int8.onnx").exists():
            raise Fail("Qwen3-ASR (CPU) is not downloaded: transcribe.py setup --model-id qwen3-asr-0.6b-onnx", "model_missing")
        self.model = "qwen3-asr-0.6b-int8"
        self.rec = sherpa_onnx.OfflineRecognizer.from_qwen3_asr(
            conv_frontend=str(d / "conv_frontend.onnx"), encoder=str(d / "encoder.int8.onnx"),
            decoder=str(d / "decoder.int8.onnx"), tokenizer=str(d / "tokenizer"), num_threads=_threads(args),
            max_total_len=1024, max_new_tokens=400, hotwords=args.prompt or "")
        self.hotwords = ""

    def set_vocab(self, terms: list[dict]) -> bool:
        """Per stream (no rebuild): "; "-joined — sherpa splits ASCII commas and re-joins them with spaces."""
        self.hotwords = dictation_vocab.hotwords(terms)
        return bool(self.hotwords)

    def transcribe(self, x):
        st = self.rec.create_stream()
        if self.hotwords:
            try:
                st.set_option("hotwords", self.hotwords)
            except Exception:  # noqa: BLE001 — an older sherpa-onnx: no per-stream hotwords
                pass
        st.accept_waveform(SR, x)
        self.rec.decode_stream(st)
        return [(0.0, len(x) / SR, st.result.text.strip(), lang_code(getattr(st.result, "lang", None)))]


class MlxBackend:
    """MLX models. MLX streams belong to the thread that made them and some libraries keep the loading thread's
    stream, while callers decode on worker threads (transcribe_track's pool, live.py): so the model is loaded and
    every call runs on one thread of its own. The MLX memory cap is set before loading."""
    max_chunk = 30

    def __init__(self, args):
        self._ex = ThreadPoolExecutor(1, thread_name_prefix="mlx")
        self.args = args
        self._ex.submit(self._init, args).result()

    def _init(self, args):
        cap_mlx_memory(limits()["max_memory_fraction"])
        self.load(args)

    def transcribe(self, x):
        return self._ex.submit(self.decode, np.asarray(x, np.float32)).result()

    def close(self):
        try:
            self._ex.submit(self.release).result(timeout=10)   # before the next model loads, not racing it
        except Exception:  # noqa: BLE001 — a decode still running: the process ending frees it all the same
            pass
        self._ex.shutdown(wait=False)

    def release(self):
        """Drop this backend's model and MLX's buffer cache (on the MLX thread), so a replacement doesn't sit beside it."""
        try:
            cache = getattr(getattr(self, "holder", None), "_cache", None)
            if cache is not None and hasattr(cache, "_data"):
                cache._data.clear()
            import mlx.core as mx
            getattr(mx, "clear_cache", None) and mx.clear_cache()
        except Exception:  # noqa: BLE001 — best effort: the process ending frees it all the same
            pass


class MlxWhisper(MlxBackend):
    max_terms = dictation_vocab.MAX_TERMS     # its prompt (~224 tokens)

    def load(self, args):
        try:
            import mlx.core as mx
            import mlx_whisper
            from mlx_whisper.transcribe import ModelHolder
        except ImportError:
            raise Fail("mlx-whisper not installed (uv run --with mlx-whisper …)", "deps", 4)
        self.m, self.mx = mlx_whisper, mx
        self.repo = self.model = args.model or "mlx-community/whisper-large-v3-turbo"
        self.net = ModelHolder.get_model(self.repo, mx.float16)  # load now, not inside the first chunk
        self.langs = [] if args.language else user_languages()
        self.base_prompt = args.prompt

    def set_vocab(self, terms: list[dict]) -> bool:
        """initial_prompt per call: a plain comma list (dictation eval: no insertions, no loops)."""
        self.args.prompt = dictation_vocab.whisper_prompt(terms) or self.base_prompt
        return bool(terms)

    def decode(self, x):
        out = self.whisper(x, self.args.language)
        # Too little text for the speech (normal speech is 4–7 syllables a second in every language we measured):
        # for someone who speaks several languages, the chunk probably switched language and Whisper dropped a part.
        if len(self.langs) > 1 and len(x) > 4 * SR and syllables(" ".join(r[2] for r in out)) < 2.5 * len(x) / SR:
            try:
                runs = self.language_runs(x)
            except Exception as e:  # noqa: BLE001 — an MLX / library change must not cost the chunk
                print(f"language split skipped: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
                runs = []
            if len(runs) > 1:
                return [(s + a, s + b, t, lg) for s, e, lang in runs
                        for a, b, t, lg in self.whisper(x[int(s * SR):int(e * SR)], lang)]
        return out

    def whisper(self, x, language):
        r = self.m.transcribe(x, path_or_hf_repo=self.repo, language=language, initial_prompt=self.args.prompt,
                              condition_on_previous_text=False, verbose=None)
        lang = r.get("language")
        return [(s["start"], s["end"], cjk_punctuation(s["text"].strip()), lang) for s in r.get("segments", [])]

    def language_runs(self, x) -> list[tuple[float, float, str]]:
        """Whisper keeps one language per window: a chunk where one sentence is English and the next Chinese comes
        back as Chinese only (asr-benchmark.md). Find the language of each speech segment in the chunk and decode runs
        of one language apart, each with its language set."""
        segs = vad_segments(x)
        if len(segs) < 2:
            return []
        from mlx_whisper.audio import N_FRAMES, log_mel_spectrogram, pad_or_trim
        from mlx_whisper.decoding import detect_language
        runs: list[list] = []
        for s, e in segs:  # one at a time: a batch of 30 s mel windows costs a GB per segment
            mel = pad_or_trim(log_mel_spectrogram(x[int(s * SR):int(e * SR)], n_mels=self.net.dims.n_mels), N_FRAMES,
                              axis=-2).astype(self.mx.float16)
            p = detect_language(self.net, mel)[1]  # one 2-D mel in → one dict out
            p = p[0] if isinstance(p, list) else p
            lang = max(p, key=p.get)
            if runs and runs[-1][2] == lang:
                runs[-1][1] = e
            else:
                runs.append([s, e, lang])
        return [(s, e, lang) for s, e, lang in runs]


class Qwen3Mlx(MlxBackend):
    """Qwen3-ASR 0.6B on MLX (mlx-qwen3-asr): ~0.18 s for a 6 s dictation on an M5 Max, and the only fast local
    model here that takes a vocabulary per request (`context`) — dictation's default on Apple Silicon.
    Interruptible: with `stop_check` set (an interim request), the decode looks at it before each stage and each
    token and raises Interrupted — the tag-aware decoder below is a loop of ours, so it can stop between steps."""
    stop_check = None

    @property
    def interruptible(self) -> bool:
        return self.tagged

    def _check(self):
        if self.stop_check is not None and self.stop_check():
            raise Interrupted("another request is waiting")

    def load(self, args):
        try:
            import mlx.core as mx
            import mlx_qwen3_asr
            from mlx_qwen3_asr.load_models import _ModelHolder
        except ImportError:
            raise Fail("mlx-qwen3-asr not installed (uv run --with mlx-qwen3-asr …)", "deps", 4)
        self.m, self.mx = mlx_qwen3_asr, mx
        self.repo = self.model = args.model or "mlx-community/Qwen3-ASR-0.6B-8bit"
        # the package keeps up to 4 loaded models in its own LRU: a server that switched models (dictation ↔ a voice
        # note's pick) held both — about 1 GB more than the one it uses. One is all a backend ever needs.
        cache = getattr(_ModelHolder, "_cache", None)
        if cache is not None and hasattr(cache, "set_max_entries"):
            cache.set_max_entries(1)
        self.holder = _ModelHolder
        _ModelHolder.get(self.repo, dtype=mx.float16)  # load now, not inside the first chunk
        self.context = args.prompt or ""
        self.base_context = self.context
        self.names: list[str] = []
        # The language the user mixes English into (docs/design/dictation.md §Code-switching): Qwen3-ASR writes its
        # whole answer in the language of the tag it decodes first, so a Chinese sentence full of English names that
        # it tags English comes back translated (和 → "and", Musk 的 → "Musk's"). None = leave the tag to the model.
        self.prefer = None if args.language else switch_language(user_languages())
        self.tagged = True        # the tag-aware decoder below works with this mlx-qwen3-asr; False after it failed
        self.last: dict = {}

    def set_vocab(self, terms: list[dict]) -> bool:
        self.context = dictation_vocab.qwen_context(terms) or self.base_context
        self.names = [t["term"] for t in terms[:dictation_vocab.QWEN_MAX_TERMS]]
        return bool(terms)

    def set_prior(self, text: str) -> None:
        """A streamed dictation's text so far: after the names, in the same system prompt (docs/design/dictation.md
        §Streaming), so a name is spelled the same way in every piece."""
        self.prior = (text or "").strip()

    def decode(self, x):
        prior = getattr(self, "prior", "")
        ctx = (self.context + "\n" + prior).strip() if prior else self.context
        text, lang = self._decode(x, ctx, prior)
        # The model now and then answers with the word list itself (seen on a noisy piece it couldn't make out:
        # "Claude Code、Codex、blurt、…"): once more with only the text so far as context.
        dump = False
        if self.names and ctx != prior and dictation_vocab.context_dump(text, self.names):
            text, lang = self._decode(x, prior, prior)
            dump = True
        # The text so far written out again as this piece's words (dict023): once more without it, and the shorter
        # answer is the piece when it is clearly shorter — a speaker who really repeats themself gets the same text.
        echo = False
        if prior and echoes_prior(text, prior, len(x) / SR):
            redo, lang2 = self._decode(x, self.context, prior)
            if redo.strip() and len(redo) < 0.8 * len(text):
                text, lang, echo = redo, lang2, True
        if dump:
            self.last["context_dump"] = True
        if echo:
            self.last["echo"] = True
        return [(0.0, len(x) / SR, text, lang)]

    def _decode(self, x, ctx: str, prior: str) -> tuple[str, str | None]:
        prefer = self.prefer or ("Chinese" if not self.args.language and dictation_vocab.cjk_share(prior) >= 0.3 else None)
        self.last = {}
        # the language tag is read from the prompt without the Words (only the text so far): see _decode_tagged
        self.tag_context = prior
        # an interim request goes through our own loop even without a preferred tag: it has to be able to stop
        if (prefer or self.stop_check is not None) and self.tagged:
            try:
                return self._decode_tagged(x, ctx, prefer)
            except Interrupted:
                raise
            except Exception as e:  # noqa: BLE001 — another mlx-qwen3-asr: its own transcribe, as before
                self.tagged = False
                print(f"qwen3-asr: tag-aware decode unavailable ({type(e).__name__}: {e}); plain decode", file=sys.stderr, flush=True)
        r = self.m.transcribe(x, model=self.repo, context=ctx, language=self.args.language)
        return (r.text or "").strip(), lang_code(getattr(r, "language", None))

    def _decode_tagged(self, x, ctx: str, prefer: str | None) -> tuple[str, str | None]:
        """mlx-qwen3-asr's decode, with the language tag chosen here (docs/design/dictation.md §Code-switching).

        The tag comes from a prompt **without the Words** (`tag_context`: only the dictation's text so far): the
        prompt is prefilled up to `language`, the model's probabilities for English and `prefer` are read there, and
        `prefer` wins unless English is all but certain (dictation_vocab.choose_tag, whose threshold was measured
        without a word list). The text is then decoded with the full context (the Words, which bias the spelling) under
        that tag. The Words framed as an English sentence pushed the tag toward English and made it depend on their
        order: one app-captured mixed sentence went from p_en 0.948 (no Words) to 0.9956 — over the 0.995 line, a clean
        English translation typed — and back under it with the same words in another order (v0.9 dogfood).
        English that still has Chinese characters in it (translated around a name) is decoded once more under
        `prefer`. Cost: one more prefill of the prompt (tens of ms), only when the Words are in the context.
        prefer None (an interim request with no preferred language): the model's own tag under the full context, as
        the plain decode does. `self.last`: the tag chosen, its probabilities with and without the Words, and the
        margin to the threshold (the history and the Lab show it)."""
        mx = self.mx
        from mlx_qwen3_asr.audio import compute_features
        from mlx_qwen3_asr.chunking import split_audio_into_chunks
        from mlx_qwen3_asr.generate import GenerationConfig, detect_repetition, resolve_max_new_tokens
        from mlx_qwen3_asr.load_models import _ModelHolder
        from mlx_qwen3_asr.tokenizer import _TokenizerHolder, parse_asr_output
        model, _ = _ModelHolder.get(self.repo, dtype=mx.float16)
        tok = _TokenizerHolder.get(_ModelHolder.get_resolved_path(self.repo, dtype=mx.float16))
        eos = set(GenerationConfig().eos_token_ids)
        head = tok.encode("language")
        tag_ids = {name: tok.encode(" " + name)[0] for name in (prefer, "English") if name}
        tag_ctx = (getattr(self, "tag_context", "") or "").strip()

        def positions(a: int, b: int):
            p = mx.arange(a, b)[None, :]
            return mx.stack([p, p, p], axis=1)

        def prefill(af, budget: int, context: str):
            ids = tok.build_prompt_tokens(n_audio_tokens=af.shape[1], language=None, context=context) + head
            self._check()
            cache = model.create_cache(max_seq_len=len(ids) + budget + 8)
            logits = model.prefill(input_ids=mx.array([ids]), audio_features=af, position_ids=positions(0, len(ids)), cache=cache)
            return logits, cache, len(ids)

        def tag_probs(logits) -> tuple[float, float, bool]:
            lp = logits.reshape(-1).astype(mx.float32)
            lp = lp - mx.logsumexp(lp)
            top = int(mx.argmax(lp))
            return float(mx.exp(lp[tag_ids["English"]])), float(mx.exp(lp[tag_ids[prefer]])), top in tag_ids.values()

        def run(af, budget: int, tag: str | None, state=None) -> tuple[str, str | None, dict]:
            """The text under `tag` (None: the model's own tag), from the prompt with the full context."""
            logits, cache, pos = state or prefill(af, budget, ctx)
            info: dict = {}
            if prefer and state is None and ctx.strip() != tag_ctx:
                # what the Words alone would have tagged (only shown: the tag was picked without them)
                p_en, p_pref, _ = tag_probs(logits)
                info["p_en_words"] = round(p_en, 4)
            if tag is None:   # the model's own tag (no speech, another language): decode on from it, as before
                suffix = [int(mx.argmax(logits.reshape(-1)))]
            else:
                suffix = tok.encode(f" {tag}<asr_text>")
            logits = model.step_many(input_ids=mx.array([suffix]), position_ids=positions(pos, pos + len(suffix)), cache=cache)
            pos += len(suffix)
            token = int(mx.argmax(logits[0, -1]))
            out = [token]
            for _ in range(1, budget):
                if token in eos or detect_repetition(out):
                    break
                self._check()
                logits = model.step(input_ids=mx.array([[token]]), position_ids=positions(pos, pos + 1), cache=cache,
                                    validate_input_ids=False)
                pos += 1
                token = int(mx.argmax(logits.reshape(-1)))
                out.append(token)
            out = [t for t in out if t not in eos]
            raw = tok.decode((head + suffix + out) if tag is None else out)
            if tag is None:
                lang, text = parse_asr_output(raw)
            else:
                lang, text = tag, parse_asr_output(raw, user_language=tag)[1]
            return (text or "").strip(), lang, info

        def pick(af, budget: int):
            """The tag from the prompt without the Words → (tag or None, info, the prefill when it is the decode's own)."""
            state = prefill(af, budget, tag_ctx)
            p_en, p_pref, top_is_tag = tag_probs(state[0])
            info = {"p_en": round(p_en, 4), f"p_{lang_code(prefer) or prefer}": round(p_pref, 4),
                    "margin": dictation_vocab.tag_margin(p_en, p_pref)}
            tag = dictation_vocab.choose_tag(p_en, p_pref, prefer) if top_is_tag else None
            return tag, info, (state if ctx.strip() == tag_ctx else None)

        texts, langs, last = [], [], {}
        for chunk, _off in split_audio_into_chunks(np.asarray(x, np.float32), sr=SR):
            self._check()
            mel, fl = compute_features(chunk)
            af, _ = model.audio_tower(mel.astype(mx.float16), fl)
            budget = resolve_max_new_tokens(None, audio_duration_sec=len(chunk) / SR)
            if prefer:
                tag, info, state = pick(af, budget)
                text, lang, more = run(af, budget, tag, state)
                info.update(more)
            else:
                (text, lang, info), tag = run(af, budget, None), None
            if prefer and lang == "English" and dictation_vocab.translated_glue(text, self.names):
                text2, _, _ = run(af, budget, prefer)
                if dictation_vocab.cjk_share(text2) > 0:
                    text, lang = text2, prefer
                    info["redone"] = True
            info["tag"] = lang
            last = info
            texts.append(text)
            langs.append(lang)
        self.last = last
        lang = next((l for l in langs if l), None)
        return ("" if lang in ("Chinese", "Japanese", "Cantonese") else " ").join(t for t in texts if t).strip(), lang_code(lang)


class FasterWhisper:
    max_chunk = 30

    def __init__(self, args):
        try:
            from faster_whisper import WhisperModel
        except ImportError:
            raise Fail("faster-whisper not installed (uv run --with faster-whisper …)", "deps", 4)
        self.args = args
        name = args.model or "mobiuslabsgmbh/faster-whisper-large-v3-turbo"
        if name == "large-v3-turbo":
            name = "mobiuslabsgmbh/faster-whisper-large-v3-turbo"
        m = entry_for("faster-whisper", name)
        local = model_path(m) if m else None
        self.model = name
        self.net = WhisperModel(str(local) if local else name, device="auto", compute_type="auto", cpu_threads=_threads(args))

    def transcribe(self, x):
        segs, info = self.net.transcribe(x, language=self.args.language, initial_prompt=self.args.prompt,
                                         condition_on_previous_text=False, vad_filter=False)
        return [(s.start, s.end, cjk_punctuation(s.text.strip()), info.language) for s in segs]


class AppleSpeech:
    """macOS's recogniser through the Blurt executable: the whole audio at once (it finds its own pauses and gives
    each phrase its time), so no VAD — nothing for a first run to download."""
    max_chunk = 3600
    no_vad = True

    def __init__(self, args):
        self.helper = apple_speech_helper()
        if not self.helper or not apple_speech_ok():
            raise Fail("macOS speech recognition needs macOS 26 and the Blurt app", "model_missing")
        self.args = args
        self.terms: list[str] = []
        self.model = "SpeechTranscriber"

    def set_vocab(self, terms: list[dict]) -> bool:
        self.terms = [t["term"] for t in terms if t.get("term")]
        return bool(self.terms)

    def transcribe(self, x):
        loc = apple_locale(self.args.language)
        if not loc:
            raise Fail("macOS speech recognition doesn't speak this language", "unsupported_language")
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(wav_bytes(x))
            path = f.name
        try:
            cmd = [str(self.helper), "--speech", path, "--locale", loc]
            if self.terms:
                cmd += ["--words", "\n".join(self.terms)]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120 + len(x) / SR)
        finally:
            os.unlink(path)
        line = next((ln for ln in reversed(r.stdout.splitlines()) if ln.startswith("{")), "{}")
        data = json.loads(line)
        if not data.get("ok"):
            raise Fail(data.get("error") or "macOS speech recognition failed", data.get("code") or "error")
        lang = loc.split("-")[0]
        return [(s["start"], s["end"], s["text"], lang) for s in data.get("segments") or []]


# Cloud recognition hears the audio sped up (asr.cloud.speed, every provider; docs/design/first-minute-speech.md §2.4):
# billing is per second of audio sent. Measured with DashScope qwen3-asr-flash on 270 kept takes: 1x 6.8 % (full cost),
# 1.5x 8.0 % for 64 % of the cost (the default), 2x 11.6 % for 47 % — and twice it answered with the word list instead
# of the speech. Pitch is kept (ffmpeg atempo); the times that come back are put back on the original timeline.
CLOUD_SPEEDS = (1.0, 1.5, 2.0)
CLOUD_SPEED_DEFAULT = 1.5


def cloud_speed(cfg: dict | None = None) -> float:
    v = os.environ.get("BLURT_ASR_SPEED") or ((cfg if cfg is not None else asr_config()).get("cloud") or {}).get("speed")
    try:
        v = float(v) if v is not None else CLOUD_SPEED_DEFAULT
    except (TypeError, ValueError):
        v = CLOUD_SPEED_DEFAULT
    return min(CLOUD_SPEEDS, key=lambda s: abs(s - v))


def speed_up(x: np.ndarray, speed: float) -> np.ndarray:
    """x played `speed` times as fast, same pitch (ffmpeg atempo); x itself when 1x or ffmpeg isn't there."""
    if speed == 1.0 or not len(x) or not shutil.which("ffmpeg"):
        return x
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes()
    r = subprocess.run([shutil.which("ffmpeg"), "-nostdin", "-loglevel", "error", "-f", "s16le", "-ar", str(SR), "-ac", "1",
                        "-i", "-", "-filter:a", f"atempo={speed}", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-"],
                       input=pcm, capture_output=True)
    if r.returncode or not r.stdout:
        return x
    return np.frombuffer(r.stdout, dtype=np.int16).astype(np.float32) / 32768


class OpenAICompat:
    """POST {base}/audio/transcriptions. verbose_json gives segment timestamps where supported."""

    def __init__(self, args):
        self.key = (os.environ.get("BLURT_ASR_API_KEY") or os.environ.get("OPENAI_API_KEY")
                    or os.environ.get("GROQ_API_KEY"))
        if not self.key:
            raise Fail("no API key: set BLURT_ASR_API_KEY (or OPENAI_API_KEY / GROQ_API_KEY)", "auth")
        default_base = "https://api.groq.com/openai/v1" if (os.environ.get("GROQ_API_KEY") and not os.environ.get(
            "BLURT_ASR_API_KEY")) else "https://api.openai.com/v1"
        self.base = (os.environ.get("BLURT_ASR_BASE_URL") or default_base).rstrip("/")
        self.model = args.model or os.environ.get("BLURT_ASR_MODEL") or (
            "whisper-large-v3-turbo" if "groq" in self.base else "whisper-1")
        self.verbose = not self.model.startswith("gpt-4o")  # gpt-4o-*-transcribe has no segment timestamps
        # Longer chunks = fewer requests (Groq bills >=10s per request); shorter when no timestamps come back.
        self.max_chunk = 60 if self.verbose else 20
        self.args = args
        self.speed = cloud_speed()
        self.terms: list[str] = []

    def set_vocab(self, terms: list[dict]) -> bool:
        """The dictation's words, in the prompt (Whisper-style services read it as preceding text)."""
        self.terms = [t["term"] for t in terms if t.get("term")]
        return bool(self.terms)

    def transcribe(self, x):
        fields = {"model": self.model, "response_format": "verbose_json" if self.verbose else "json"}
        if self.args.language:
            fields["language"] = self.args.language
        prompt = self.args.prompt or (", ".join(self.terms) if self.terms else None)
        if prompt:
            fields["prompt"] = prompt
        boundary = uuid.uuid4().hex
        body = io.BytesIO()
        for k, v in fields.items():
            body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
                   f'Content-Type: audio/wav\r\n\r\n'.encode())
        body.write(wav_bytes(speed_up(x, self.speed)))
        body.write(f"\r\n--{boundary}--\r\n".encode())
        data = _post(f"{self.base}/audio/transcriptions", body.getvalue(),
                     {"Authorization": f"Bearer {self.key}", "Content-Type": f"multipart/form-data; boundary={boundary}"})
        lang = lang_code(data.get("language"))
        if data.get("segments"):
            k = self.speed
            return [(s["start"] * k, min(s["end"] * k, len(x) / SR), s["text"].strip(), lang) for s in data["segments"]]
        return [(0.0, len(x) / SR, (data.get("text") or "").strip(), lang)]


class DashScope:
    max_chunk = 20

    def __init__(self, args):
        self.key = os.environ.get("DASHSCOPE_API_KEY")
        if not self.key:
            raise Fail("no API key: set DASHSCOPE_API_KEY", "auth")
        # its own variable: BLURT_ASR_BASE_URL is the OpenAI-compatible service's (both can be set in the app)
        self.base = (os.environ.get("DASHSCOPE_BASE_URL") or "https://dashscope.aliyuncs.com/compatible-mode/v1").rstrip("/")
        # the model picked in Settings (CloudSpeech: DASHSCOPE_ASR_MODEL), else the registry's
        self.model = os.environ.get("DASHSCOPE_ASR_MODEL") or args.model or "qwen3-asr-flash"
        self.args = args
        self.speed = cloud_speed()
        self.terms: list[str] = []

    def set_vocab(self, terms: list[dict]) -> bool:
        """The dictation's words as Qwen3-ASR's context (measured: 27 of 35 terms with them, §2.4)."""
        self.terms = [t["term"] for t in terms if t.get("term")]
        return bool(self.terms)

    def transcribe(self, x):
        audio = "data:audio/wav;base64," + base64.b64encode(wav_bytes(speed_up(x, self.speed))).decode()
        payload = {"model": self.model, "stream": False,
                   "messages": [{"role": "system", "content": [{"type": "text", "text": self.args.prompt or ", ".join(self.terms)}]},
                                {"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": audio}}]}],
                   "asr_options": {"enable_itn": True, **({"language": self.args.language} if self.args.language else {})}}
        data = _post(f"{self.base}/chat/completions", json.dumps(payload).encode(),
                     {"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        text = data["choices"][0]["message"]["content"]
        if isinstance(text, list):
            text = "".join(p.get("text", "") for p in text)
        return [(0.0, len(x) / SR, text.strip())]


def _post(url: str, body: bytes, headers: dict, retries: int = 4) -> dict:
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")[:500]
            if e.code in (429, 500, 502, 503) and attempt < retries - 1:
                time.sleep(2 ** attempt * 2)
                continue
            raise Fail(f"ASR API error {e.code}: {msg}", "auth" if e.code in (401, 403) else "quota" if e.code == 429 else "network")
        except urllib.error.URLError as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
                continue
            raise Fail(f"ASR API unreachable: {e}", "network")


BACKENDS = {"sensevoice": SenseVoice, "qwen3-asr-onnx": Qwen3Onnx, "mlx-whisper": MlxWhisper,
            "qwen3-asr-mlx": Qwen3Mlx, "faster-whisper": FasterWhisper, "apple": AppleSpeech, "openai": OpenAICompat,
            "dashscope": DashScope}
LOCAL = {"sensevoice", "qwen3-asr-onnx", "mlx-whisper", "qwen3-asr-mlx", "faster-whisper", "apple"}
EXTRA_PACKAGES = {"mlx-whisper": "mlx-whisper", "faster-whisper": "faster-whisper",
                  "qwen3-asr-mlx": "mlx-qwen3-asr"}  # backend → `uv run --with` package
# The exact version each `--with` installs (arch101: no release is picked up by itself; bumped on purpose, per Blurt
# release, like the script header's). faster-whisper (NVIDIA, Windows / Linux) is pinned when it is next verified.
PACKAGE_PINS = {"mlx-whisper": "mlx-whisper==0.4.3", "mlx-qwen3-asr": "mlx-qwen3-asr==0.4.4"}
API_KEYS = {"openai": ("BLURT_ASR_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY"), "dashscope": ("DASHSCOPE_API_KEY",)}


# ------------------------------------------------------------------ recommendation
# The rules come from docs/design/asr-benchmark.md (2026-10-22, Apple M5 Max): Whisper large-v3-turbo on MLX was the
# most accurate in all seven test languages and the fastest multilingual model; its 4-bit build keeps nearly all of
# that in 2.6 GB; SenseVoice is the fastest and lightest for zh / en / ja / ko / yue; on a CPU without a usable GPU,
# Qwen3-ASR 0.6B (sherpa-onnx) was 9x faster than Whisper (CTranslate2) at a usable accuracy.
SV, TURBO, TURBO_Q4, CT2, QWEN_CPU = ("sensevoice-small", "whisper-large-v3-turbo-mlx", "whisper-large-v3-turbo-q4-mlx",
                                      "whisper-large-v3-turbo-ct2", "qwen3-asr-0.6b-onnx")


def hw_kind(hw: dict) -> str:
    """apple (Apple Silicon: MLX on the GPU) | nvidia (CUDA) | cpu"""
    if hw["os"] == "darwin" and hw["arch"] == "arm64":
        return "apple"
    return "nvidia" if hw["gpu"].get("kind") == "nvidia" else "cpu"


QWEN_FIRST_LANGS = ("zh", "en")   # where Qwen3-ASR measured best on real speech; Cantonese (36–39 % on the `say`
#                                  samples), Japanese, Korean and French keep the table's choice


def preference(kind: str, tier: str, purpose: str, sv_ok: bool, sv_good: bool, qwen_ok: bool = False) -> list[str]:
    """Models to try, best first (the first that fits and speaks every language wins). sv_ok: SenseVoice speaks
    every language; sv_good: and its reference error rate is ≤ 5 % in each (not Korean: 10 % vs Whisper's 0.5 %);
    qwen_ok: every language is one of QWEN_FIRST_LANGS."""
    multi = {"apple": {"pro": [TURBO, TURBO_Q4], "standard": [TURBO, TURBO_Q4], "light": [TURBO_Q4], "minimal": []},
             "nvidia": {"pro": [CT2, QWEN_CPU], "standard": [CT2, QWEN_CPU], "light": [QWEN_CPU], "minimal": []},
             "cpu": {"pro": [QWEN_CPU], "standard": [QWEN_CPU], "light": [QWEN_CPU], "minimal": []}}[kind][tier]
    # Apple Silicon with 16 GB or more: one model for every job — dictation, voice notes, live captions, recordings
    # (v1.0.2). Qwen3-ASR on MLX was the most accurate on real speech in every set measured (AISHELL-1 NE terms, ASCEND
    # zh-en, FLEURS zh, LibriSpeech, contextual earnings calls: docs/design/asr-benchmark.md §Real speech) and the only
    # one that takes the user's words; one model also means one warm copy instead of three (the 24 GB Mac that
    # swapped held a Qwen, a SenseVoice and a Whisper).
    # v1.0.6: the 0.6B on pro Macs too. On the founder's real takes the two are close — the 0.6B ahead on the Lab's
    # corrected takes (4.6 vs 6.4 %), the 1.7B ahead on English (2.7 vs 3.2 %) and custom words (28 vs 25 of 35) —
    # while the 1.7B is 2.5x the download and holds 1 GB more (docs/design/first-minute-speech.md §2.1). The 1.7B
    # stays a choice, and a Mac that already has it keeps using it.
    if kind == "apple" and tier in ("pro", "standard") and qwen_ok:
        return [QWEN_MLX] + ([QWEN_MLX_17] if tier == "pro" else []) + multi + ([SV] if sv_ok else [])
    # on a CPU the multilingual model is 10x slower and no more accurate in SenseVoice's languages
    prefer_sv = sv_ok if kind == "cpu" else sv_good
    fallback = [SV] if sv_ok else []
    if purpose == "batch" or (purpose == "live" and kind == "apple" and tier == "pro"):
        # recordings: accuracy first. Live on a pro Mac runs the recordings model itself, so the live transcript is
        # the final one (transcribe.py run reuses it).
        if prefer_sv and (kind == "cpu" or tier in ("light", "minimal")):
            return [SV] + multi
        return multi + fallback
    # live captions and voice notes: latency first. Their model stays warm next to dictation's: on a 16–24 GB Mac the
    # 4-bit Whisper (2.6 GB, a 442 MB download) comes before the full one (3.7 GB) — arch098; recordings above keep
    # accuracy first (a one-off process that ends with the job)
    if kind == "apple" and tier == "standard":
        multi = [TURBO_Q4, TURBO]
    return ([SV] if prefer_sv else []) + multi + fallback


def _bench_results() -> dict:
    d = load_json(BENCH_FILE, {}) or {}
    return d.get("results", {}) if isinstance(d, dict) else {}


def _fits(m: dict, hw: dict, lim: dict | None = None) -> bool:
    """Runs on this platform and its measured peak memory stays within 40 % of RAM (the rest is the user's)."""
    if not runs_here(m, f"{hw['os']}-{hw['arch']}"):
        return False
    if "cuda" in (m.get("requires") or []) and hw["gpu"].get("kind") != "nvidia":
        return False
    return m.get("ram_mb", 0) <= max(hw["ram_gb"] * 1024 * 0.4, 700)


def candidate_row(m: dict, hw: dict, lim: dict, bench: dict, langs: list[str]) -> dict:
    b = bench.get(m["id"]) or {}
    ref = m.get("rtf_ref")
    scale = {"pro": 1, "standard": 1.8, "light": 3.5, "minimal": 6}[hw["tier"]]
    row = {"id": m["id"], "name": m.get("name"), "backend": m["backend"], "languages": m["languages"],
           "size_mb": m["size_mb"], "ram_mb": b.get("peak_ram_mb") or m.get("ram_mb"),
           "rtf_est": b.get("rtf") if b.get("rtf") is not None else (round(ref * scale, 3) if ref else None),
           "measured": bool(b.get("rtf") is not None), "quality_note_key": m.get("quality_note_key"),
           "installed": installed(m), "fits": _fits(m, hw, lim), "speaks": [x for x in langs if speaks(m, x)],
           "local": m.get("local", True), "verified": m.get("verified")}
    if b.get("error"):
        row["error_rate"] = b["error"]
    elif m.get("error_ref"):
        row["error_rate_ref"] = {k: v for k, v in m["error_ref"].items() if k in langs}
    return row


def recommend(languages: list[str] | None = None, purpose: str = "batch", hw: dict | None = None,
              cfg: dict | None = None) -> dict:
    """K9 + docs/design/asr-benchmark.md (preference() has the order):
    - recordings: Apple Silicon pro / standard → Whisper large-v3-turbo (MLX); light → its 4-bit build; NVIDIA → turbo
      on CUDA; CPU only → SenseVoice for zh / en / ja / ko / yue, Qwen3-ASR 0.6B (CPU) for anything else;
    - live captions and voice notes: SenseVoice when it speaks every language, else the tier's multilingual model;
      a pro Mac runs live captions with the recordings model;
    - on battery (asr.on_battery = lighter, the default) recordings drop one tier;
    - minimal tier with a language SenseVoice doesn't speak → cloud_recommended (SenseVoice is still the local pick)."""
    hw = hw or probe()
    cfg = asr_config() if cfg is None else cfg
    lim = limits(hw, cfg)
    langs = languages or user_languages(cfg)
    tier = hw["tier"]
    if hw.get("on_battery") and purpose == "batch" and cfg.get("on_battery", "lighter") == "lighter":
        tier = {"pro": "standard", "standard": "light"}.get(tier, tier)
    sv = entry(SV)
    sv_ok = all(speaks(sv, x) for x in langs)
    sv_good = sv_ok and all((sv.get("error_ref") or {}).get(x, 0) <= 0.05 for x in langs)
    order = preference(hw_kind(hw), tier, purpose, sv_ok, sv_good, all(x in QWEN_FIRST_LANGS for x in langs))
    bench = _bench_results()
    pick = None
    for mid in dict.fromkeys(order):
        m = entry(mid)
        if m and _fits(m, hw, lim) and all(speaks(m, x) for x in langs):
            pick = m
            break
    cloud = tier == "minimal" and not sv_ok
    if pick is None:
        pick = sv  # nothing local covers it: SenseVoice is still the fastest thing that runs
    rows = [candidate_row(m, hw, lim, bench, langs) for m in entries(local_only=False)
            if m.get("local", True) or not local_only()]
    rank = {mid: i for i, mid in enumerate(dict.fromkeys(order + [m["id"] for m in entries()]))}
    rows.sort(key=lambda r: (not r["fits"], len(r["speaks"]) < len(langs), rank.get(r["id"], 99)))
    out = {"ok": True, "tier": hw["tier"], "effective_tier": tier, "purpose": purpose, "languages": langs,
           "pick": {"model": pick["id"], "backend": pick["backend"]}, "candidates": rows}
    if cloud:
        out["cloud_recommended"] = True
    return out


# ------------------------------------------------------------------ which model to run
def select(purpose: str, a=None) -> dict:
    """The registry entry (or a synthetic one for a legacy backend / model) this run uses."""
    cfg = asr_config()
    if a is not None and getattr(a, "model_id", None):
        m = entry(a.model_id)
        if not m:
            raise Fail(f"unknown model {a.model_id}; see transcribe.py models", "unknown_model")
        return m
    if a is not None and getattr(a, "backend", None):
        name = a.backend
        if name not in BACKENDS:
            raise Fail(f"unknown backend {name}; choose from {list(BACKENDS)}", "unknown_model")
        model = getattr(a, "model", None) or (cfg.get("model") if name == cfg.get("backend") else None)
        return entry_for(name, model) or {"id": f"{name}:{model or 'default'}", "backend": name, "model": model,
                                          "languages": "multi", "local": name in LOCAL}
    chosen = (cfg.get("models") or {}).get(purpose) if isinstance(cfg.get("models"), dict) else None
    if not is_auto(cfg):
        if chosen and entry(chosen):
            return entry(chosen)
        name = cfg.get("backend") or "sensevoice"
        model = cfg.get("model")
        return entry_for(name, model) or {"id": f"{name}:{model or 'default'}", "backend": name, "model": model,
                                          "languages": "multi", "local": name in LOCAL}
    rec = recommend(purpose=purpose, cfg=cfg)
    order = ([chosen] if chosen else []) + [rec["pick"]["model"]] + [c["id"] for c in rec["candidates"]
                                                                     if c["fits"] and len(c["speaks"]) == len(rec["languages"])]
    apple = entry(APPLE)
    apple_ok = bool(apple and runs_here(apple) and installed(apple) and all(speaks(apple, x) for x in rec["languages"]))
    # a local model hears through the VAD (0.6 MB) too: one whose own files are already here from elsewhere (a Whisper
    # in a shared Hugging Face cache) doesn't beat macOS's recogniser, which needs nothing, until the VAD is in
    bundled_vad()
    vad = (MODELS_DIR / "silero_vad.onnx").is_file()
    for mid in dict.fromkeys(order):
        m = entry(mid)
        if m and m.get("local", True) and runs_here(m) and installed(m) and (vad or m.get("builtin") or not apple_ok):
            return m
        if m and not m.get("local", True) and not local_only() and installed(m) and mid == chosen:
            return m
    # nothing downloaded: macOS's own recogniser when it speaks the user's languages (first-minute-speech.md)
    if apple_ok:
        return apple
    # no macOS recogniser (macOS 13–15, ~23 % of Macs): a cloud service whose key the user set — the setup assistant's
    # one key (Model Studio in China) says it recognises speech too — before a model that would have to download
    if not local_only():
        for mid in DICTATION_CLOUD:
            m = entry(mid)
            if m and installed(m):
                return m
    return entry("sensevoice-small")  # downloads on first use (never during a recording: BLURT_NO_DOWNLOAD)


def resolve_backend(a, purpose: str = "batch") -> str:
    """Backend for this run; fills a.model / a.model_id / a.language / a.prompt (explicit options win)."""
    cfg = asr_config()
    m = select(purpose, a)
    a.model = None if m["backend"] == "sensevoice" else m.get("model")
    if m["backend"] == "qwen3-asr-mlx":
        p = model_path(m)           # the folder it is in (HF cache snapshot or a ModelScope copy): loaded offline
        if p:
            a.model = str(p)
    a.model_id = m["id"]
    lang = getattr(a, "language", None) or cfg.get("language")
    a.language = None if lang in (None, "", "auto") else lang
    a.prompt = getattr(a, "prompt", None)
    if not m.get("local", True) and local_only():
        raise Fail("local-only recognition is on (privacy.local_asr): cloud ASR is not allowed", "privacy")
    return m["backend"]


def backend_ready(name: str, model_id: str | None = None) -> str | None:
    """None when `name` (or registry model `model_id`) can run right now without downloading anything or asking for
    a key, else why not."""
    if name not in BACKENDS:
        return f"unknown backend {name}"
    if name == "apple":
        return None if apple_speech_ok() else "macOS speech recognition needs macOS 26 and the Blurt app"
    bundled_vad()
    if not (MODELS_DIR / "silero_vad.onnx").exists():
        return "VAD model not downloaded (transcribe.py setup)"
    if name in API_KEYS:
        return None if any(os.environ.get(k) for k in API_KEYS[name]) else \
            f"no API key in the environment ({' / '.join(API_KEYS[name])})"
    m = entry(model_id) if model_id else entry_for(name)
    if m and m.get("install") and not installed(m):
        return f"{m['id']} is not downloaded (transcribe.py setup --model {m['id']})"
    return None


def throttle(purpose: str, threads: int | None = None) -> dict:
    """The process-wide caps for a CLI run (before any model or thread pool exists): thread pools and priority.
    In-process callers (tests, the app's helpers) don't call this, so importing transcribe never renices anyone."""
    lim = limits()
    cap_threads(threads or lim["threads"])
    return apply_priority(lim["priority"].get(purpose, "utility"))


def make_backend(name: str, a, purpose: str = "batch"):
    """Load the backend with the thread cap, after making sure its package and files are there."""
    a.threads = getattr(a, "threads", None) or limits()["threads"]
    m = entry(getattr(a, "model_id", None)) or entry_for(name)
    if name in EXTRA_PACKAGES:
        ensure_package(EXTRA_PACKAGES[name])
    if m and m.get("install") and m.get("local", True) and not m["install"].get("files"):
        if not installed(m):
            if os.environ.get("BLURT_NO_DOWNLOAD"):
                raise Fail(f"{m['id']} is not downloaded", "model_missing")
            install_model(m)
    b = BACKENDS[name](a)
    if name == "qwen3-asr-mlx" and purpose in ("batch", "live"):
        b.max_chunk = 15      # a segment per chunk: a recording's timestamps (frames, items) stay this fine
    return b


def model_label(name: str, backend, a) -> str | None:
    if name == "sensevoice":
        return "sense-voice-small-int8"
    if name == "apple":
        return "apple-speech-transcriber"
    m = getattr(backend, "model", None)
    return m if isinstance(m, str) else getattr(backend, "repo", None) or a.model


# ------------------------------------------------------------------ shared pipeline (also used by live.py)
def decode_slice(backend, x: np.ndarray, s: float, e: float) -> list[tuple]:
    """Transcribe x (= the samples of chunk s..e seconds) → segments on the original timeline:
    (start, end, text) or (start, end, text, language) when the backend says which language it heard. Chinese comes
    back in the user's script (to_user_script) whichever model wrote it: voice notes, recordings, live captions and
    dictation all pass here."""
    out = []
    for r in backend.transcribe(x):
        rs, re_, t, *lg = r
        seg = (s + rs, s + min(re_, e - s), to_user_script(t, lang_code(lg[0]) if lg and lg[0] else None))
        out.append(seg + (lg[0],) if lg and lg[0] else seg)
    return out


def decode_chunk(backend, samples: np.ndarray, s: float, e: float) -> list[tuple]:
    return decode_slice(backend, samples[int(s * SR):int(e * SR)], s, e)


def is_blank(results) -> bool:
    return not any(ch.isalnum() for r in results for ch in r[2])


def build_transcript(source: str, name: str, backend, a, duration: float, speech: float, blank: float,
                     results: list, elapsed: float) -> dict:
    """results: [(start, end, text, speaker|None[, language])] → the transcript.json document."""
    results = sorted(results, key=lambda r: r[0])
    segments = []
    for r in results:
        s, e, t, lb, *lg = r
        if t:
            segments.append({"start": round(s, 2), "end": round(e, 2), "text": t, **({"speaker": lb} if lb else {}),
                             **({"language": lg[0]} if lg and lg[0] else {})})
    data = {"source": source, "backend": name, "model": model_label(name, backend, a),
            "duration": round(duration, 2), "speech_seconds": round(speech, 2),
            "elapsed_seconds": round(elapsed, 1), "segments": segments}
    langs = [sg["language"] for sg in segments if sg.get("language")]
    if langs:
        data["languages"] = sorted(set(langs), key=lambda x: -langs.count(x))
    # SenseVoice knows only zh/en/ja/ko/yue; other languages (German…) mostly come back as "." tagged <|en|>, so
    # the language tag can't catch it. Supported speech that VAD kept practically never decodes to nothing.
    # Mic track only: system audio may be music or effects.
    if name == "sensevoice" and speech >= 5 and blank / speech > 0.3:
        data["warning"] = (f"{blank:.0f}s of {speech:.0f}s of speech decoded to nothing: the language is probably "
                           "not zh/en/ja/ko/yue, which is all SenseVoice supports. Re-run with a multilingual model "
                           "(transcribe.py recommend; reference/asr.md) and pass --language.")
    return data


def write_transcript(out: Path, data: dict) -> list[str]:
    save_json(out / "transcript.json", data)
    lines = [f"[{fmt_ts(s['start'])}-{fmt_ts(s['end'])}] {'(system) ' if s.get('speaker') == 'system' else ''}{s['text']}"
             for s in data["segments"]]
    (out / "transcript.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return [str(out / "transcript.json"), str(out / "transcript.txt")]


def print_summary(data: dict, files: list[str], **extra) -> None:
    print(json.dumps({k: v for k, v in data.items() if k != "segments"} | {"segments": len(data["segments"]),
                                                                              "files": files} | extra,
                     ensure_ascii=False, indent=2))


def transcribe_track(samples: np.ndarray, backend, name: str, workers: int, label: str | None = None,
                     quiet: bool = False):
    """VAD → chunks → backend. Returns ([(start, end, text, label[, language])], speech s, s that decoded to nothing).
    A backend that finds its own pauses (`no_vad`: macOS's recogniser) gets the whole audio."""
    # …and so does a cloud service for audio it takes in one request (a dictation's or voice note's piece, which the
    # app has already cut at a pause): no VAD file needed for it either
    whole = getattr(backend, "no_vad", False) or (name in API_KEYS and len(samples) / SR <= backend.max_chunk)
    if whole:
        dur = len(samples) / SR
        r = decode_slice(backend, samples, 0.0, dur) if dur > 0 else []
        return [(s_, e_, t, label, *lg) for s_, e_, t, *lg in r], dur, dur if is_blank(r) else 0.0
    segs = vad_segments(samples, max_speech=min(25, backend.max_chunk))
    chunks = group_chunks(segs, backend.max_chunk)
    sp = sum(e - s for s, e in chunks)
    if not quiet:
        print(f"audio {fmt_ts(len(samples) / SR)}{f' ({label})' if label else ''}, speech {fmt_ts(sp)} "
              f"in {len(chunks)} chunks → {name}", file=sys.stderr, flush=True)
    results, blank = [], 0.0
    with ThreadPoolExecutor(workers) as pool:
        decoded = pool.map(lambda ch: decode_chunk(backend, samples, *ch), chunks)
        for i, ((s, e), r) in enumerate(zip(chunks, decoded)):
            results.extend((s_, e_, t, label, *lg) for s_, e_, t, *lg in r)
            if is_blank(r):
                blank += e - s
            if (i + 1) % 20 == 0 and not quiet:
                print(f"  {i + 1}/{len(chunks)} chunks", file=sys.stderr, flush=True)
    return results, sp, blank


# ------------------------------------------------------------------ reuse live.py's transcript (docs/design/snap-and-live.md)
def live_transcript(src: Path, out: Path, a, explicit: dict, wait: float = 180) -> dict | None:
    """The transcript live.py finished during this very recording (same session, same length), else None.
    If live.py is still draining after the stop, wait for it — its status.json stays fresh while it works."""
    if getattr(a, "force", False) or out.resolve() != src.parent.resolve():
        return None
    live = src.parent / "live"
    deadline = time.time() + wait
    while True:
        st = load_json(live / "status.json") or {}
        if st.get("asr") == "done":
            break
        fresh = time.time() - float(st.get("updated") or 0) < 15
        if st.get("asr") != "running" or not (live / "stop").exists() or not fresh or time.time() > deadline:
            return None
        time.sleep(0.5)
    try:
        data = load_json(out / "transcript.json")
    except (ValueError, OSError):
        return None
    if not isinstance(data, dict) or data.get("source") != src.name or not isinstance(data.get("segments"), list):
        return None
    if explicit.get("backend") and explicit["backend"] != data.get("backend"):
        return None  # explicitly asked for another backend / model
    if explicit.get("model") and explicit["model"] != data.get("model"):
        return None
    if explicit.get("prompt") and data.get("backend") != "sensevoice":
        return None  # a glossary helps Whisper / API backends (live.py has none): redo with it
    try:
        dur = probe_duration(src)
    except Exception:
        return None
    if abs(dur - float(data.get("duration") or 0)) > max(2.0, 0.02 * dur):
        return None  # another take (restart) or a cut-short live run
    return data


# ------------------------------------------------------------------ shots (snap mode): voice notes → "said"
def read_shots(session: Path) -> dict:
    """shots.jsonl → {n: merged record}; later lines win."""
    latest: dict = {}
    log = session / "shots.jsonl"
    if log.exists():
        for line in log.read_text(encoding="utf-8").splitlines():
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(rec, dict) and rec.get("n") is not None:
                latest[rec["n"]] = {**latest.get(rec["n"], {}), **rec}
    return latest


def shot_voice(session: Path, n, rec: dict) -> Path | None:
    voice = rec.get("voice")
    if isinstance(voice, str) and voice:
        p = session / voice
        if not p.exists() and (session / "shots" / Path(voice).name).exists():
            p = session / "shots" / Path(voice).name
        return p if p.exists() else None
    if voice is False:
        return None
    try:
        p = session / "shots" / f"{int(n):03d}.wav"
    except (TypeError, ValueError):
        return None
    return p if p.exists() else None


def structure_note(text: str) -> str | None:
    """A Structured voice note's text through the warm polish model (polish.py serve) — the same `structure` request
    the app sends for dictation and voice notes (model-based: lists laid out, self-corrections resolved). None when no
    polish server runs, the text is empty, or the model fell back."""
    if not text.strip():
        return None
    try:
        import polish
        timeout = polish.structure_timeout_s()
        r = polish._server_call({"cmd": "structure", "text": text, "timeout": timeout}, timeout + 5)
    except Exception:  # noqa: BLE001 — no polish: the transcript stays the note
        return None
    if not isinstance(r, dict) or not r.get("ok") or r.get("fell_back"):
        return None
    out = (r.get("text") or "").strip()
    return out or None


def transcribe_shots(session: Path, a) -> None:
    latest = read_shots(session)
    todo = [(n, rec, wav) for n, rec in latest.items()
            if (wav := shot_voice(session, n, rec)) and (a.force or "said" not in rec)]
    name = resolve_backend(a, "note")
    t0 = time.time()
    done = []
    if todo:
        with AsrSlot(limits()["max_concurrent"]):
            backend = make_backend(name, a, "batch")
            workers = 1 if name in LOCAL else a.concurrency
            for n, rec, wav in todo:
                results, _, _ = transcribe_track(load_audio(wav), backend, name, workers, quiet=True)
                said = " ".join(r[2] for r in sorted(results, key=lambda r: r[0]) if r[2]).strip()
                upd = {"said": said}
                if rec.get("structure"):
                    # a Structured note (⇧ while it listened): its note is the structured text and the transcript stays
                    # as said_raw, as the app keeps it. No polish model: the transcript, and said_raw cleared — a
                    # stale one from an earlier pass would sit next to a note it no longer matches
                    s = structure_note(said)
                    upd = {"said": s, "said_raw": said} if s and s != said else {"said": said, "said_raw": None}
                # an update line with the same n (full record + "said"); later lines win — docs/design/snap-and-live.md
                with open(session / "shots.jsonl", "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({**rec, **upd}, ensure_ascii=False) + "\n")
                done.append({"n": n, **upd})
    print(json.dumps({"session": str(session), "mode": "shots", "shots": len(latest), "transcribed": len(done),
                      "backend": name, "elapsed_seconds": round(time.time() - t0, 1), "said": done},
                     ensure_ascii=False, indent=2))


# ------------------------------------------------------------------ commands
def cmd_run(a):
    src = Path(a.input)
    if not src.exists():
        die(f"{src} not found")
    if src.is_dir():  # a session dir: a shots session, or the recording inside it
        meta = load_json(src / "meta.json", {}) or {}
        recs = sorted(src.glob("recording.*"))
        if meta.get("mode") == "shots" or (not recs and meta.get("mode") != "video" and (src / "shots.jsonl").exists()):
            throttle("batch", a.threads)
            return transcribe_shots(src, a)
        if not recs:
            die(f"no recording.* in {src}")
        src = recs[0]
    out = Path(a.out or src.parent)
    explicit = {"backend": a.backend, "model": a.model, "prompt": a.prompt}

    data = live_transcript(src, out, a, explicit)
    n_tracks = max(1, audio_tracks(src))
    if data is not None and (n_tracks == 1 or any(s.get("speaker") == "system" for s in data["segments"])):
        files = [str(out / "transcript.json"), str(out / "transcript.txt")]
        if not (out / "transcript.txt").exists():
            files = write_transcript(out, data)
        print("transcript was already made during the recording (live/); --force redoes it", file=sys.stderr, flush=True)
        return print_summary(data, files, live=True)

    name = resolve_backend(a, "batch")
    throttle("batch", a.threads)
    with AsrSlot(limits()["max_concurrent"]):
        t0 = time.time()
        backend = make_backend(name, a, "batch")
        workers = 1 if name in LOCAL else a.concurrency
        # Blurt's native recorder writes the mic as track 0 and, with --system-audio, what the Mac played as track 1.
        # Transcribing them apart labels who spoke: the user ("mic") or the call / demo ("system").
        duration = speech = blank = 0.0
        results = []
        for track in range(min(n_tracks, 2)):
            label = ("mic", "system")[track] if n_tracks > 1 else None
            if track == 0 and data is not None:  # live.py already did the mic; only the system track is left
                results += [(s["start"], s["end"], s["text"], label) for s in data["segments"]]
                duration, speech = float(data["duration"]), float(data["speech_seconds"])
                print("mic track: reusing the live transcript", file=sys.stderr, flush=True)
                continue
            samples = load_audio(src, track)
            duration = max(duration, len(samples) / SR)
            r, sp, bl = transcribe_track(samples, backend, name, workers, label)
            results += r
            if track == 0:
                speech, blank = sp, bl

    data = build_transcript(src.name, name, backend, a, duration, speech, blank, results, time.time() - t0)
    if data.get("warning"):
        print("warning: " + data["warning"], file=sys.stderr, flush=True)
    print_summary(data, write_transcript(out, data))


# --- voice notes: the fast path and the warm server

# A streamed dictation's (or voice note's) text so far goes to the speech model as context, so a name is spelled the
# same way in every piece. Long, it gets echoed: the model answers with the earlier text instead of, or before, the
# new piece (dict023, measured on a 43 s take: a 5.5 s last piece with 200 characters of prior came back as 78–165
# characters, with 80 or 40 as the right 24, every run). So only the tail goes, and with it only the most relevant
# words of the list; `echoes_prior` is the meaning-free net behind that.
PRIOR_CHARS = 80
PRIOR_TERMS = 32
# More than this many syllables a second is no one's speech (normal speech is 4–7 in every language measured).
MAX_SYLLABLES_PER_SECOND = 10
# A run this long (characters, spaces and punctuation aside) shared with the text so far is worth one more look.
ECHO_RUN = 12


def prior_tail(prior: str, n: int | None = None) -> str:
    """The last `n` (PRIOR_CHARS) characters of the text so far, not starting inside a Latin word."""
    n = n or PRIOR_CHARS
    p = (prior or "").strip()
    if len(p) <= n:
        return p
    tail = p[-n:]
    if tail[0].isascii() and tail[0].isalnum() and p[-n - 1].isascii() and p[-n - 1].isalnum() and " " in tail:
        tail = tail[tail.index(" ") + 1:]
    return tail.strip()


def _bare(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKC", text or "").lower()
                   if not unicodedata.category(c).startswith(("P", "Z", "C", "S")))


def longest_shared_run(a: str, b: str) -> int:
    """The longest run of characters `a` and `b` share (spaces and punctuation aside)."""
    a, b = _bare(a), _bare(b)
    best, prev = 0, [0] * (len(b) + 1)
    for ca in a:
        cur = [0] * (len(b) + 1)
        for j, cb in enumerate(b, 1):
            if ca == cb:
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
        prev = cur
    return best


def echoes_prior(text: str, prior: str, seconds: float) -> bool:
    """A piece's answer that may be the context written out again, judged without reading it: more syllables than
    `seconds` of speech can hold, or a long run of the prior in it. Only a reason to decode once more without the
    prior (the caller keeps the shorter answer only when it is clearly shorter)."""
    if not text or not prior:
        return False
    if seconds >= 1 and syllables(text) > MAX_SYLLABLES_PER_SECOND * seconds:
        return True
    return longest_shared_run(text, prior) >= ECHO_RUN


def note_text(results: list) -> tuple[str, str | None]:
    results = sorted(results, key=lambda r: r[0])
    texts = [r[2] for r in results if r[2]]
    langs = [r[4] for r in results if len(r) > 4 and r[4]]
    sep = "" if langs and all(x in ("zh", "ja", "yue") for x in langs) else " "
    return sep.join(texts).strip(), (max(set(langs), key=langs.count) if langs else None)


class NoteEngine:
    """The voice-note model, loaded once (in-process `note`, or kept warm by `serve`)."""

    def __init__(self):
        self.backend = self.name = self.model_id = None
        self.last = time.time()

    def load(self, language: str | None = None, model_id: str | None = None):
        a = argparse.Namespace(backend=None, model=None, model_id=model_id, language=language, prompt=None)
        name = resolve_backend(a, "note")
        if self.backend is None or a.model_id != self.model_id or (language or None) != getattr(self, "language", None):
            if self.backend is not None and a.model_id != self.model_id and hasattr(self.backend, "close"):
                self.backend.close()     # its model goes before the next one loads (a language change keeps it)
            elif self.backend is not None and hasattr(self.backend, "_ex"):
                self.backend._ex.shutdown(wait=False)   # the same model: only its thread goes
            self.backend = make_backend(name, a, "note")
            self.name, self.model_id, self.language = name, a.model_id, language or None
        return self

    def note(self, wav: Path, language: str | None = None, model_id: str | None = None, vocab=None,
             purpose: str | None = None, prior: str | None = None, hint: str | None = None, stop=None,
             app: str | None = None) -> dict:
        """vocab: None = no words; True = the file's; a list = these (strings or term dicts). The model is biased toward
        them where it can be (Whisper's prompt, Qwen3-ASR's context / hotwords); they are hints, so `text` (and
        `asr_text`, the same) is what the model wrote. A misheard name is polish's to fix: it gets the words and sees
        the sentence.
        hint: the target app's window title and the text around the cursor — words seen there are listed to the model
        first.
        app: the name of the app the text goes into ("飞书"), named to the model before the words — what the speech is
        likely about where two words sound the same (飞书会话 vs 绘画: 4 → 8 of 12 synthetic takes right). Only for a
        backend that takes words (Qwen3-ASR's context); nothing else is said about the app.
        stop: an interim request (the live words of dictation and of notes) — a callable that says another request is
        waiting; the decode then raises Interrupted. An interruptible backend looks at it between steps; a quick one
        (`quick_decode`: SenseVoice, one ~0.1 s pass) is asked once before and then decodes whole — a waiting final
        piece waits that long at most. Any other backend (a slow one that can't stop: Whisper on CT2, Qwen3-ASR on the
        CPU) answers Fail "interim_unsupported"."""
        t0 = time.perf_counter()
        language = None if language in (None, "", "auto") else language
        if purpose == "dictation" and not model_id:
            model_id = dictation_models()["selected"]
        before = self.backend
        t_load = time.perf_counter()
        self.load(language, model_id)
        load_ms = int((time.perf_counter() - t_load) * 1000) if self.backend is not before else 0
        if stop is not None and not getattr(self.backend, "interruptible", False):
            if not getattr(self.backend, "quick_decode", False):
                raise Fail(f"{self.name} can't stop a decode halfway: no interim requests", "interim_unsupported")
            if stop():
                raise Interrupted("another request is waiting")
            stop = None     # one short pass: nothing to look at halfway

        x = read_wav(wav)
        terms = dictation_vocab.load() if vocab is True else dictation_vocab.normalize(vocab) if vocab else []
        biased = False
        if hasattr(self.backend, "set_vocab"):
            # the most relevant `cap` of them: ranked() cuts by relevance, then names them in a fixed order — a
            # backend that took fewer than it was given would cut alphabetically (Whisper's 40 of 64: a third of the
            # right words gone, contextual-earnings22)
            cap = getattr(self.backend, "max_terms", dictation_vocab.QWEN_MAX_TERMS)
            limit = min(PRIOR_TERMS, cap) if prior else cap
            use = dictation_vocab.ranked(terms, prior or "", hint or "", limit)
            name = " ".join(str(app or "").split())[:40]
            if name and not any(t["term"] == name for t in use):
                use = [{"term": name, "sounds_like": [], "source": "app", "hits": 0}] + use[:max(0, limit - 1)]
            biased = self.backend.set_vocab(use)
        if prior and hasattr(self.backend, "set_prior"):
            self.backend.set_prior(prior_tail(prior))
        retried = False
        if stop is not None:
            self.backend.stop_check = stop
        try:
            results, _speech, _blank = transcribe_track(x, self.backend, self.name, 1, quiet=True)
            # Qwen3-ASR now and then answers nothing for a short piece that follows a whole sentence of context (a
            # dictation's last words after a long pause: measured 2–5 of 6 takes of one synthetic clip, never when the
            # same request was replayed). The VAD heard speech, so once more without the context: ~0.13 s, only then.
            if prior and _speech >= 0.4 and not note_text(results)[0].strip() and hasattr(self.backend, "set_prior"):
                self.backend.set_prior("")
                results, _speech, _blank = transcribe_track(x, self.backend, self.name, 1, quiet=True)
                retried = True
        finally:
            if stop is not None:
                self.backend.stop_check = None
            if biased:
                self.backend.set_vocab([])  # a voice note after this gets no dictation words
            if prior and hasattr(self.backend, "set_prior"):
                self.backend.set_prior("")
        text, lang = note_text(results)
        out = {"ok": True, "text": text, "language": lang or language, "ms": int((time.perf_counter() - t0) * 1000),
               "model": self.model_id, "audio_seconds": round(len(x) / SR, 2), "load_ms": load_ms}
        if retried:
            out["retried"] = True
        tag = getattr(self.backend, "last", None)
        if tag:
            out["tag"] = tag      # the language tag chosen and the model's English / preferred probabilities
        if vocab is not None:
            out.update(asr_text=text, biased=biased)
        self.last = time.time()
        return out


SERVE_FILE = RUN_DIR / "asr-serve.json"


def _server_call(req: dict, timeout: float = 120) -> dict | None:
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


@contextlib.contextmanager
def no_download(on: bool):
    """While on: a model that isn't on this Mac is an error (model_missing), never a download — a dictation never waits
    for one (`note --no-download`, `serve --no-download` for its preload, a request's "no_download")."""
    if not on or os.environ.get("BLURT_NO_DOWNLOAD"):
        yield
        return
    os.environ["BLURT_NO_DOWNLOAD"] = "1"
    try:
        yield
    finally:
        os.environ.pop("BLURT_NO_DOWNLOAD", None)


def cmd_note(a):
    if getattr(a, "no_download", False):
        os.environ["BLURT_NO_DOWNLOAD"] = "1"
    wav = Path(a.wav).resolve()
    if not wav.exists():
        raise Fail(f"{wav} not found", "not_found")
    vocab = True if a.vocab else None
    purpose = "dictation" if a.dictation else None
    if not a.no_server:
        r = _server_call({"cmd": "note", "wav": str(wav), "language": a.language, "model_id": a.model_id,
                          "vocab": vocab, "purpose": purpose, "no_download": bool(getattr(a, "no_download", False))})
        if r is not None:
            if not r.get("ok"):
                raise Fail(r.get("error") or "server error", r.get("code") or "error")
            return emit({**r, "server": True})
    throttle("note")
    emit(NoteEngine().note(wav, a.language, a.model_id, vocab, purpose))


def cmd_serve(a):
    """One warm voice-note model per machine. Protocol: one JSON line in ({"token","cmd":"note"|"load"|"ping"|"exit",
    …}), one JSON line out. A "note" with "interim": true (dictation's live text: the piece still being said) is
    stopped as soon as another connection waits — a final piece never waits for it — and answers
    {"ok": false, "code": "interrupted"}; a quick model (SenseVoice) decodes it whole; a slow model that can't stop
    halfway answers "interim_unsupported". Ends (serve_exit_reason) when its model went unused for --idle s — an unload left most of
    the memory resident, so the process goes and the app starts it again on the next key-down — when the app that
    started it (--parent) is gone, on "exit", or after --exit-after s without a request while no model is loaded."""
    if (r := _server_call({"cmd": "ping"}, timeout=2)) and r.get("ok"):
        return emit({"ok": True, "already": True, "pid": r.get("pid")})
    throttle("note")
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    srv.settimeout(1.0)
    port = srv.getsockname()[1]
    save_json(SERVE_FILE, {"pid": os.getpid(), "port": port, "token": token, "parent": a.parent,
                           "started": datetime.now().astimezone().isoformat(timespec="seconds")})
    eng = NoteEngine()
    why = None
    # from here on the run file is ours to remove, whatever happens — a preload that fails included (a run file left
    # pointing at a dead or stuck process made the app wait for a server that never answered)
    try:
        if a.preload:
            mid = getattr(a, "model_id", None)
            if not mid and getattr(a, "purpose", None) == "dictation":
                mid = dictation_models()["selected"]
            # --no-download: a model that isn't here stays unloaded (the server still answers: model_missing)
            try:
                with no_download(getattr(a, "no_download", False)):
                    eng.load(None, mid)
            except Fail as e:
                if e.code != "model_missing":
                    raise
                serve_said(f"serve: preload skipped ({e})")
        emit({"ok": True, "pid": os.getpid(), "port": port, "model": eng.model_id})
        last = time.time()
        uses: list[float] = []          # dictation requests: kept warm longer while dictation is used often
        tier = probe()["tier"]
        while not why:
            now = time.time()
            why = serve_exit_reason(eng.backend is not None, now - eng.last, now - last, uses, tier, a.idle,
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
                    while not buf.endswith(b"\n") and len(buf) < 1 << 20:      # a vocabulary can be long
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                    req = json.loads(buf or b"{}")
                    if req.get("token") != token:
                        resp = {"ok": False, "error": "bad token", "code": "auth"}
                    elif req.get("cmd") == "ping":
                        resp = {"ok": True, "pid": os.getpid(), "model": eng.model_id, "loaded": eng.backend is not None}
                    elif req.get("cmd") == "note":
                        last = time.time()
                        interim = bool(req.get("interim"))
                        if req.get("purpose") == "dictation" and not interim:
                            uses.append(last)
                            del uses[:-50]
                        # an interim decode looks for a waiting connection (a final piece, anything) between steps
                        stop = (lambda: bool(_select.select([srv], [], [], 0)[0])) if interim else None
                        # a dictation (final or interim) never waits for a download, whatever the client sent
                        with no_download(bool(req.get("no_download")) or req.get("purpose") == "dictation"):
                            resp = eng.note(Path(req["wav"]), req.get("language"), req.get("model_id"), req.get("vocab"),
                                            req.get("purpose"), req.get("prior"), req.get("hint"), stop=stop,
                                            app=req.get("app"))
                        if interim:
                            resp["interim"] = True
                    elif req.get("cmd") == "load":       # warm a model now (dictation's key went down)
                        last = time.time()
                        mid = req.get("model_id") or (dictation_models()["selected"] if req.get("purpose") == "dictation" else None)
                        with no_download(bool(req.get("no_download")) or req.get("purpose") == "dictation"):
                            eng.load(None, mid)
                        eng.last = time.time()
                        resp = {"ok": True, "model": eng.model_id}
                    elif req.get("cmd") == "exit":       # the app is quitting (or someone wants the memory back now)
                        resp = {"ok": True, "pid": os.getpid()}
                        why = "asked"
                    else:
                        resp = {"ok": False, "error": "unknown cmd", "code": "usage"}
                except Fail as e:
                    resp = {"ok": False, "error": str(e), "code": e.code}
                except Interrupted:
                    resp = {"ok": False, "error": "interrupted", "code": "interrupted", "interim": True}
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


# --- probe / recommend / auto / models / setup
def cmd_probe(_a):
    emit({"ok": True, **probe(), "platform": platform_key(), "limits": limits()})


def _langs_arg(v) -> list[str] | None:
    return [x.strip() for x in v.split(",") if x.strip()] if v else None


def cmd_recommend(a):
    emit(recommend(_langs_arg(a.languages), a.purpose))


def auto_plan(apply: bool) -> dict:
    """The per-purpose pick for this machine and the user's languages. --apply writes asr.models (only models that
    are installed — the rest are listed under needs_download for the host to ask about) and the hardware fingerprint."""
    cfg = asr_config()
    hw = probe()
    picks, needs = {}, []
    for p in PURPOSES:
        r = recommend(purpose=p, hw=hw, cfg=cfg)
        mid = r["pick"]["model"]
        m = entry(mid)
        if installed(m):
            picks[p] = mid
        else:
            fallback = select(p)  # what runs today
            picks[p] = fallback["id"]
            needs.append({"purpose": p, "model": mid, "size_mb": m["size_mb"]})
    by_model: dict = {}
    for n in needs:
        by_model.setdefault(n["model"], {"model": n["model"], "size_mb": n["size_mb"], "purposes": []})["purposes"].append(n["purpose"])
    out = {"ok": True, "auto": is_auto(cfg), "tier": hw["tier"], "languages": user_languages(cfg), "models": picks,
           "recommended": {p: recommend(purpose=p, hw=hw, cfg=cfg)["pick"]["model"] for p in PURPOSES},
           "needs_download": list(by_model.values()),
           "hardware_changed": cfg.get("hardware") != hw["fingerprint"]}
    if apply and is_auto(cfg):
        # a config.json that doesn't parse: nothing saved, said (not a traceback) — the picks still run as defaults
        out["applied"] = save_config_if_readable({"asr": {"models": picks, "hardware": hw["fingerprint"]}})
        if not out["applied"]:
            out["saved"] = False
    return out


def cmd_auto(a):
    emit(auto_plan(a.apply))


# --- dictation's recognition model (record.dictation.asr_model; docs/design/dictation.md §Recognition model)
QWEN_MLX = "qwen3-asr-0.6b-mlx"
QWEN_MLX_17 = "qwen3-asr-1.7b-mlx"
DICTATION_MODELS = (QWEN_MLX, QWEN_MLX_17, SV, TURBO, TURBO_Q4, QWEN_CPU, CT2, APPLE)   # the local ones dictation offers, best
#                                                                                   first; macOS's own last (nothing to download)
DICTATION_CLOUD = ("qwen3-asr-flash", "openai-compatible")   # offered once their key is set (first-minute-speech.md §2.4)


def polish_ram_mb(hw: dict, cfg: dict | None = None) -> float:
    """The memory the polish model dictation runs next to takes (polish_models.json ram_mb): the configured one, else
    the tier's default — 0 where polish doesn't run (MLX: Apple Silicon only) or is turned off. Read here rather than
    from polish.py, which imports this module."""
    cfg = ((global_config().get("record") or {}).get("dictation") or {}) if cfg is None else cfg
    if hw_kind(hw) != "apple" or (isinstance(cfg, dict) and cfg.get("polish", "light") == "off"):
        return 0.0
    try:
        reg = json.loads((HERE / "polish_models.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0.0
    want = (cfg.get("polish_model") if isinstance(cfg, dict) else None) or (reg.get("defaults") or {}).get(hw["tier"])
    m = next((x for x in reg.get("models") or [] if x.get("id") == want), None)
    return float((m or {}).get("ram_mb") or 0)


def fits_with_polish(m: dict, hw: dict, polish_mb: float) -> bool:
    """`_fits`, counting the polish model too: a dictation holds both warm at once (ASR + polish), so the pair has to
    stay within the share of RAM one model may take (on a 16 GB Mac: 0.6B 2.1 GB + Gemma 4 E2B 3.9 GB fits; 1.7B
    3.1 GB + 3.9 GB doesn't)."""
    return _fits({**m, "ram_mb": (m.get("ram_mb") or 0) + polish_mb}, hw)


def dictation_models(hw: dict | None = None) -> dict:
    """configured (record.dictation.asr_model or None = automatic), recommended (by the dictation eval: Qwen3-ASR MLX
    on Apple Silicon pro / standard, else the voice-note pick), selected (what runs: the configured one when it is
    installed, else the recommended one when installed, else the best installed Qwen3-ASR MLX that runs here next to
    the polish model, else the voice-note model) and the rows for Settings. Memory is judged for the pair dictation
    holds — the recogniser plus the polish model (fits_with_polish)."""
    hw = hw or probe()
    cfg = (global_config().get("record") or {}).get("dictation") or {}
    configured = cfg.get("asr_model") if isinstance(cfg, dict) else None
    note_pick = select("note")
    apple = hw_kind(hw) == "apple"
    pmb = polish_ram_mb(hw, cfg if isinstance(cfg, dict) else {})

    def fits(mid: str) -> bool:
        m = entry(mid)
        return bool(m) and fits_with_polish(m, hw, pmb)
    # the 0.6B on pro and standard Macs (v1.0.6; before, the v0.8 speed eval's 1.7B on pro ones: preference() says why)
    # (the voice-note pick is macOS's own recogniser while nothing is downloaded: the download to offer is then the one
    # the voice-note rules would choose)
    note_rec = note_pick["id"] if note_pick["id"] != APPLE else recommend(purpose="note", hw=hw)["pick"]["model"]
    rec = QWEN_MLX if apple and hw["tier"] in ("pro", "standard") and fits(QWEN_MLX) else note_rec
    # what runs: the configured one (the user's choice, as it is), else the recommended one, else any Qwen3-ASR MLX
    # already here that runs next to polish, best first (it takes the Words list; the voice-note model doesn't) — a
    # 1.7B brought from a bigger Mac, or a 0.6B on a pro Mac until the 1.7B is in — all only when installed; else the
    # voice-note model
    usable = [mid for mid in (QWEN_MLX_17, QWEN_MLX) if mid != rec and apple and fits(mid)]
    # every local model hears through the VAD (silero_vad.onnx, 0.6 MB, which `setup` fetches first): without it a
    # dictation can't run ("model_missing" under BLURT_NO_DOWNLOAD), so a model counts as installed only with it;
    # `files` = the model's own files are in (then `setup` of it only fetches the VAD)
    bundled_vad()
    vad = (MODELS_DIR / "silero_vad.onnx").is_file()
    # without the VAD, macOS's recogniser (the voice-note pick then) runs before a model whose files only are here —
    # unless the user chose that model
    pick = (configured,) if not vad and note_pick["id"] == APPLE else (configured, rec, *usable)
    selected = next((mid for mid in pick if mid and entry(mid) and runs_here(entry(mid))
                     and installed(entry(mid))), note_pick["id"])
    rows = []
    for mid in DICTATION_MODELS + DICTATION_CLOUD:
        m = entry(mid)
        if not m or not runs_here(m):
            continue
        if not m.get("local", True) and (local_only() or not installed(m)):
            continue        # a cloud service: only with its key, never when recognition stays on this Mac
        have = installed(m)
        rows.append({"id": mid, "name": m.get("name"), "backend": m["backend"], "size_mb": m["size_mb"],
                     "ram_mb": m.get("ram_mb"), "installed": have and (vad or not m.get("local", True) or bool(m.get("builtin"))),
                     "files": have,
                     "builtin": bool(m.get("builtin")),
                     "vocab": m.get("vocab") or "none", "recommended": mid == rec, "fits": fits(mid)})
    # ready: a dictation can run right now with nothing downloaded (it never downloads: `no_download`) — the
    # selected model (local and on this Mac, or a cloud one with its key: judged by itself, not by being a row) and
    # the VAD every take goes through. missing: what a download would have to bring for that ("silero-vad" and/or
    # the selected model's id)
    sel = entry(selected)
    # macOS's recogniser hears without the VAD, and so does a cloud service for a dictation's pieces (transcribe_track)
    missing = [] if vad or selected == APPLE or bool(sel and not sel.get("local", True)) else ["silero-vad"]
    selected_installed = bool(sel and installed(sel))
    if not selected_installed:
        missing.append(selected)
    return {"configured": configured, "configured_installed": bool(configured and entry(configured)
                                                                     and installed(entry(configured))),
            "recommended": rec, "selected": selected, "selected_installed": selected_installed,
            # the dictation goes to a cloud service: the app shows live text from macOS's recogniser and doesn't hear it
            # again (each pass is billed)
            "selected_cloud": bool(sel and not sel.get("local", True)),
            "ready": not missing, "missing": missing, "vad": vad, "models": rows}


def cmd_dictation_models(_a):
    emit({"ok": True, **dictation_models()})


def selected_models() -> dict:
    out = {}
    for p in PURPOSES:
        try:
            out[p] = select(p)["id"]
        except Fail:
            out[p] = None
    return out


def cmd_models(_a):
    hw = probe()
    lim = limits(hw)
    bench = _bench_results()
    sel = selected_models()
    langs = user_languages()
    rows = []
    for m in entries():
        r = {k: v for k, v in m.items() if k not in ("install", "rtf_ref", "error_ref")}
        r["local"] = m.get("local", True)
        r["role"] = "asr"
        r["installed"] = installed(m)
        p = model_path(m) if r["local"] else None
        if p:
            r["path"] = str(p)
            r["size_mb"], r["approx"] = _du_mb(p), False
        else:
            r["approx"] = r["local"]
        r["runs_here"] = runs_here(m)
        r["fits"] = _fits(m, hw, lim)
        r["purposes"] = [k for k, v in sel.items() if v == m["id"]]
        r["configured"] = bool(r["purposes"])
        r["speaks"] = [x for x in langs if speaks(m, x)]
        if m["id"] in bench:
            r["bench"] = bench[m["id"]]
        for k in ("rtf_ref", "error_ref"):
            if m.get(k) is not None:
                r[k] = m[k]
        rows.append(r)
    bundled_vad()
    vad = MODELS_DIR / "silero_vad.onnx"  # every local model needs it; listed so hosts can show the whole download
    rows.append({"id": "silero-vad", "name": "Silero VAD", "backend": "vad", "role": "vad", "local": True,
                 "languages": ["*"], "installed": vad.exists(), "size_mb": _du_mb(vad) if vad.exists() else 0.6,
                 "approx": not vad.exists(), "path": str(vad), "purposes": [], "configured": False})
    cfg = asr_config()
    emit({"ok": True, "models_dir": str(MODELS_DIR), "configured": cfg, "auto": is_auto(cfg), "tier": hw["tier"],
          "platform": platform_key(), "hardware": hw, "limits": lim, "languages": langs,
          "languages_set": bool(cfg.get("languages")), "selected": sel,
          "recommended": {p: recommend(langs, p, hw, cfg)["pick"]["model"] for p in PURPOSES},
          "local_only": local_only(), "models": rows})


def cmd_setup(a):
    watch_parent(getattr(a, "parent", None))   # started by the app: ends with it (the next setup continues the files)
    if a.model_id:
        m = entry(a.model_id)
        if not m:
            raise Fail(f"unknown model {a.model_id}; see transcribe.py models", "unknown_model")
    else:  # legacy: setup --backend B [--model M]
        m = entry_for(a.backend, a.model) or entry_for(a.backend)
        if m is None:
            raise Fail(f"unknown backend {a.backend}", "unknown_model")
    path = install_model(m)
    patch: dict = {}
    if a.use:
        purposes = PURPOSES if a.use == "all" else [p for p in a.use.split(",") if p in PURPOSES]
        cur = selected_models()
        patch["models"] = {**cur, **{p: m["id"] for p in purposes}}
        patch["auto"] = False  # a hand-picked model is the user's choice: not replaced on hardware changes
    elif not a.model_id:  # legacy behaviour: setup --backend selects it
        patch["backend"] = a.backend
        if a.model:
            patch["model"] = a.model
    if a.language:
        patch["language"] = a.language
    # the download is done either way: a config.json that doesn't parse only leaves the choice unsaved ("saved": false)
    saved = save_config_if_readable({"asr": patch}) if patch else True
    emit({"ok": True, "model": m["id"], "path": str(path), "asr": asr_config(), **({} if saved else {"saved": False})})


def cmd_backends(_a):
    bundled_vad()
    have = lambda rel: (MODELS_DIR / rel).exists()  # noqa: E731
    emit({
        "ok": True,
        "configured": global_config().get("asr"),
        "sensevoice_ready": have("sensevoice/model.int8.onnx") and have("sensevoice/tokens.txt") and have("silero_vad.onnx"),
        "selected": selected_models(),
        "api_keys": {k: bool(os.environ.get(k)) for k in ("BLURT_ASR_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY", "DASHSCOPE_API_KEY")},
    })


# --- bench: speed, memory, CPU / GPU load, and accuracy on spoken samples
CER_LANGS = {"zh", "yue", "ja", "ko", "th"}


def normalize(text: str, lang: str) -> list[str]:
    t = unicodedata.normalize("NFKC", text).lower()
    t = "".join(" " if unicodedata.category(c)[0] in "PSZ" else c for c in t)
    if lang in CER_LANGS:
        return [c for c in t if not c.isspace()]
    return t.split()


def error_rate(ref: str, hyp: str, lang: str) -> float:
    """CER for zh / yue / ja / ko / th, WER otherwise (punctuation and case ignored)."""
    r, h = normalize(ref, lang), normalize(hyp, lang)
    if not r:
        return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        cur = [i] + [0] * len(h)
        for j, hc in enumerate(h, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rc != hc))
        prev = cur
    return round(prev[-1] / len(r), 4)


def say_voices() -> dict[str, list[str]]:
    """locale → voice names, from `say -v ?`."""
    try:
        out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    voices: dict[str, list[str]] = {}
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s{2,}([a-z]{2,3}_[A-Z0-9]{2,3})\s", line)
        if m:
            voices.setdefault(m.group(2), []).append(m.group(1).strip())
    return voices


def bench_samples(langs: list[str]) -> list[dict]:
    """Spoken samples for `langs` made with macOS `say`, cached under $BLURT_HOME/bench/: [{lang, path, text}]."""
    if not shutil.which("say"):
        raise Fail("no AUDIO given and no `say` to make samples: pass a recording, e.g. transcribe.py bench clip.mp4",
                   "usage")
    defs = registry()["bench"]["samples"]
    voices = None
    out = []
    for lang in langs:
        d = defs.get(lang)
        if not d:
            continue
        path = BLURT_HOME / "bench" / f"say-{lang}.wav"
        text = " ".join(d["text"])
        if not path.exists():
            voices = voices if voices is not None else say_voices()
            have = {v for vs in voices.values() for v in vs}
            voice = next((v for v in d["voices"] if v in have), None) or next(iter(voices.get(d["locale"], [])), None)
            if not voice:
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            aiff = path.with_suffix(".aiff")
            subprocess.run(["say", "-v", voice, "-o", str(aiff), " [[slnc 900]] ".join(d["text"])], check=True,
                           capture_output=True)
            subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(SR), "-ac", "1",
                            str(path)], check=True)
            aiff.unlink(missing_ok=True)
        out.append({"lang": lang, "path": path, "text": text})
    return out


class GpuSampler:
    """Apple GPU utilisation (system-wide, from IOAccelerator's PerformanceStatistics) sampled while decoding."""

    def __init__(self, every: float = 0.2):
        self.every, self.samples = every, []
        self.stop = threading.Event()
        self.th = threading.Thread(target=self._run, daemon=True) if IS_MAC else None

    def _run(self):
        while not self.stop.wait(self.every):
            try:
                out = subprocess.run(["ioreg", "-r", "-d", "1", "-c", "IOAccelerator"], capture_output=True, text=True,
                                     timeout=2).stdout
                m = re.search(r'"Device Utilization %"=(\d+)', out)
                if m:
                    self.samples.append(int(m.group(1)))
            except (OSError, subprocess.TimeoutExpired):
                pass

    def __enter__(self):
        if self.th:
            self.th.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        if self.th:
            self.th.join(1)
        return False

    def summary(self) -> dict | None:
        if not self.samples:
            return None
        return {"mean": round(sum(self.samples) / len(self.samples)), "max": max(self.samples)}


def run_bench(m: dict, a) -> dict:
    """Measure one model on this machine (in this process): load time, decode RTF, peak memory, CPU cores busy,
    GPU utilisation, and the error rate per language on the `say` samples (or just speed on a given AUDIO)."""
    langs = _langs_arg(a.languages) or (list(registry()["bench"]["samples"]) if a.all_languages else user_languages())
    if a.input:
        samples = [{"lang": None, "path": Path(a.input), "text": None}]
    else:
        samples = bench_samples([x for x in langs if speaks(m, x)] or langs[:1])
    if not samples:
        raise Fail("no bench sample for these languages", "usage")
    audio = [(s, (load_audio(s["path"]) if a.input else read_wav(s["path"]))[: int(a.seconds * SR)]) for s in samples]
    ns = argparse.Namespace(backend=None, model=None, model_id=m["id"], language=None, prompt=None,
                            threads=a.threads, concurrency=4)
    name = resolve_backend(ns, "batch")
    base_mem = peak_memory_mb()
    t0 = time.perf_counter()
    backend = make_backend(name, ns, "bench")
    load_s = time.perf_counter() - t0
    # warm-up (first-call kernel compilation on MLX), not timed
    transcribe_track(audio[0][1][: SR * 5], backend, name, 1, quiet=True)
    errors, texts, audio_s, dec_s, cpu_s = {}, {}, 0.0, 0.0, 0.0
    with GpuSampler() as gpu:
        for s, x in audio:
            c0, t1 = os.times(), time.perf_counter()
            results, _sp, _bl = transcribe_track(x, backend, name, 1 if name in LOCAL else 4, quiet=True)
            dt = time.perf_counter() - t1
            c1 = os.times()
            dec_s += dt
            cpu_s += (c1.user - c0.user) + (c1.system - c0.system)
            audio_s += len(x) / SR
            hyp, _lang = note_text(results)
            if s["lang"]:
                texts[s["lang"]] = hyp
                if s["text"] and len(x) / SR >= 0.95 * float(probe_wav_seconds(s["path"])):
                    errors[s["lang"]] = error_rate(s["text"], hyp, s["lang"])
    out = {"ok": True, "model": m["id"], "backend": name, "threads": ns.threads, "audio_seconds": round(audio_s, 1),
           "load_seconds": round(load_s, 2), "decode_seconds": round(dec_s, 2),
           "rtf": round(dec_s / audio_s, 4) if audio_s else None,
           "cpu_cores": round(cpu_s / dec_s, 2) if dec_s else None,
           "peak_ram_mb": peak_memory_mb(), "base_ram_mb": base_mem,
           "at": datetime.now().astimezone().isoformat(timespec="seconds"), "machine": probe()["fingerprint"]}
    if gpu.summary():
        out["gpu_util"] = gpu.summary()
    if qos_cpu_seconds():
        out["qos_cpu_seconds"] = qos_cpu_seconds()
    if errors:
        out["error"] = errors
    if a.show_text:
        out["text"] = texts
    return out


def probe_wav_seconds(p: Path) -> float:
    try:
        with wave.open(str(p)) as w:
            return w.getnframes() / w.getframerate()
    except (wave.Error, OSError):
        return 0.0


def cmd_bench(a):
    if a.model_id:
        m = entry(a.model_id)
        if not m:
            raise Fail(f"unknown model {a.model_id}; see transcribe.py models", "unknown_model")
    elif a.backend:
        m = entry_for(a.backend, a.model) or entry_for(a.backend)
    else:
        m = select("batch")
    if m is None:
        raise Fail("no such model", "unknown_model")
    throttle("bench", a.threads)
    with AsrSlot(limits()["max_concurrent"]):
        out = run_bench(m, a)
    if not a.no_save and not a.input:
        d = load_json(BENCH_FILE, {}) or {}
        d = d if isinstance(d, dict) else {}
        d["schema"] = 1
        d.setdefault("results", {})[m["id"]] = {k: v for k, v in out.items() if k not in ("ok", "text")}
        save_json(BENCH_FILE, d)
    emit(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def model_opts(sp, backend_default=None):
        sp.add_argument("--backend", choices=list(BACKENDS), default=backend_default)
        sp.add_argument("--model", help="the backend's model name / repo (legacy); --model-id picks from the registry")
        sp.add_argument("--model-id", dest="model_id", metavar="ID", help="a model id from asr_models.json")
        sp.add_argument("--language", help="e.g. zh, en, ja; default auto-detect")

    r = sub.add_parser("run")
    r.add_argument("input")
    r.add_argument("--out", help="output dir (default: next to input)")
    model_opts(r)
    r.add_argument("--prompt", help="glossary / context: product & module names, jargon (Whisper / Qwen3 / API backends)")
    r.add_argument("--concurrency", type=int, default=4)
    r.add_argument("--threads", type=int)
    r.add_argument("--force", action="store_true", help="transcribe again even if live.py already did")
    n = sub.add_parser("note")
    n.add_argument("wav")
    n.add_argument("--language", default="auto")
    n.add_argument("--model-id", dest="model_id", metavar="ID")
    n.add_argument("--no-server", action="store_true", help="always transcribe in this process")
    n.add_argument("--dictation", action="store_true", help="dictation's model (record.dictation.asr_model)")
    n.add_argument("--vocab", action="store_true", help="the dictation words: bias the model toward them (hints only)")
    n.add_argument("--no-download", action="store_true", help="a model that isn't here is an error (model_missing), never a download")
    sv = sub.add_parser("serve")
    sv.add_argument("--preload", action="store_true", help="load the voice-note model now (e.g. when recording starts)")
    sv.add_argument("--model-id", dest="model_id", metavar="ID", help="preload this model instead")
    sv.add_argument("--purpose", choices=["note", "dictation"], help="dictation: preload dictation's model")
    sv.add_argument("--no-download", action="store_true", help="the preload never downloads (a missing model stays unloaded)")
    sv.add_argument("--idle", type=float, default=SERVE_IDLE, help="end after the model went unused this many seconds")
    sv.add_argument("--exit-after", type=float, default=1800, help="with no model loaded: end after this many seconds without a request")
    sv.add_argument("--parent", type=int, help="end when this process (the app that started the server) is gone")
    sub.add_parser("probe")
    rc = sub.add_parser("recommend")
    rc.add_argument("--languages", help="comma-separated, e.g. zh,en,ja (default: asr.languages / the system's)")
    rc.add_argument("--purpose", choices=PURPOSES, default="batch")
    au = sub.add_parser("auto")
    au.add_argument("--apply", action="store_true", help="write asr.models for what is installed")
    s = sub.add_parser("setup")
    s.add_argument("--model-id", "--id", dest="model_id", metavar="ID")
    s.add_argument("--backend", choices=list(BACKENDS), default="sensevoice")
    s.add_argument("--model")
    s.add_argument("--language")
    s.add_argument("--use", help="also select it: all, or a comma list of batch,live,note")
    s.add_argument("--parent", type=int, help="end when this process (the app that started the download) is gone")
    sub.add_parser("backends")
    sub.add_parser("models")
    sub.add_parser("dictation-models")
    b = sub.add_parser("bench")
    b.add_argument("input", nargs="?", help="audio / video file (default: spoken samples made with `say`)")
    model_opts(b)
    b.add_argument("--prompt")
    b.add_argument("--languages", help="comma-separated (default: your languages that the model speaks)")
    b.add_argument("--all-languages", action="store_true", help="every bench language the registry has")
    b.add_argument("--seconds", type=float, default=60, help="at most this much of each sample")
    b.add_argument("--threads", type=int)
    b.add_argument("--show-text", action="store_true")
    b.add_argument("--no-save", action="store_true")
    a = p.parse_args()
    # `--model ID` with a registry id means --model-id (K9 writes it that way); other values stay backend model names
    if a.cmd in ("setup", "bench", "run") and not a.model_id and a.model and entry(a.model):
        a.model_id, a.model = a.model, None
    try:
        {"run": cmd_run, "note": cmd_note, "serve": cmd_serve, "probe": cmd_probe, "recommend": cmd_recommend,
         "auto": cmd_auto, "setup": cmd_setup, "backends": cmd_backends, "models": cmd_models, "bench": cmd_bench,
         "dictation-models": cmd_dictation_models}[a.cmd](a)
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
