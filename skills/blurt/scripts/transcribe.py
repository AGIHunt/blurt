# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "sherpa-onnx>=1.12", "truststore"]
# ///
"""Speech-to-text with timestamps. Always VAD-first: silence is dropped, speech is chunked, and every
chunk keeps its offset in the original video, so any backend (even ones without timestamps) works.

  transcribe.py setup  --backend sensevoice          download models for a local backend
  transcribe.py run    <video|audio> [--out DIR]     transcribe; writes transcript.json + transcript.txt
                                                     instant when live.py already transcribed the recording
                                                     while it was made (<session>/live/); --force redoes it
  transcribe.py run    <session dir>                 a shots session (snap mode): transcribe each voice note
                                                     shots/NNN.wav into its shots.jsonl record ("said")
  transcribe.py backends                             list backends and whether they are ready
  transcribe.py models                               ASR models: installed / downloadable, size, languages (JSON)
  transcribe.py bench [AUDIO] [--backend B] [--seconds 30]
                                                     real-time factor on a sample (first 30 s of AUDIO; default a
                                                     macOS `say` sample) → {"rtf", "load_seconds", …}

Backends
  sensevoice   local, sherpa-onnx + SenseVoice-Small int8 (~240MB). zh/en/ja/ko/yue, fast on any CPU.  [default]
  mlx-whisper  local, Apple Silicon only.   run with: uv run --with mlx-whisper transcribe.py ...
  faster-whisper local, CPU / NVIDIA CUDA.  run with: uv run --with faster-whisper transcribe.py ...
  openai       any OpenAI-compatible /audio/transcriptions API (OpenAI, Groq, SiliconFlow, ...)
               env: BLURT_ASR_API_KEY (or OPENAI_API_KEY / GROQ_API_KEY), BLURT_ASR_BASE_URL, BLURT_ASR_MODEL
  dashscope    Alibaba Qwen3-ASR (qwen3-asr-flash) via DashScope OpenAI-compatible chat API. env: DASHSCOPE_API_KEY
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import (MODELS_DIR, die, ffmpeg_bin, fmt_ts, global_config, load_json, probe_duration,  # noqa: E402
                     save_json, update_global_config, use_system_certs)

use_system_certs()

SR = 16000
SENSEVOICE_REPO = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODEL_FILES = {
    "silero_vad.onnx": [
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
        "https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx",
        "https://hf-mirror.com/csukuangfj/vad/resolve/main/silero_vad.onnx",
    ],
    "sensevoice/model.int8.onnx": [
        f"https://huggingface.co/{SENSEVOICE_REPO}/resolve/main/model.int8.onnx",
        f"https://hf-mirror.com/{SENSEVOICE_REPO}/resolve/main/model.int8.onnx",
    ],
    "sensevoice/tokens.txt": [
        f"https://huggingface.co/{SENSEVOICE_REPO}/resolve/main/tokens.txt",
        f"https://hf-mirror.com/{SENSEVOICE_REPO}/resolve/main/tokens.txt",
    ],
}


# ------------------------------------------------------------------ downloads
def download(rel: str) -> Path:
    dest = MODELS_DIR / rel
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    if os.environ.get("BLURT_NO_DOWNLOAD"):  # live.py: never start a 240 MB download in the middle of a recording
        die(f"{rel} is not downloaded")
    dest.parent.mkdir(parents=True, exist_ok=True)
    urls = MODEL_FILES[rel]
    if os.environ.get("BLURT_HF_MIRROR"):  # force the China-friendly mirror first
        urls = sorted(urls, key=lambda u: "hf-mirror" not in u)
    last = None
    for url in urls:
        try:
            print(f"downloading {rel} <- {url}", file=sys.stderr, flush=True)
            tmp = dest.with_suffix(dest.suffix + ".part")
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "blurt"}), timeout=30) as r, \
                    open(tmp, "wb") as f:
                total, done, t0 = int(r.headers.get("content-length") or 0), 0, time.time()
                while chunk := r.read(1 << 20):
                    f.write(chunk)
                    done += len(chunk)
                    if total and time.time() - t0 > 2:
                        print(f"  {done >> 20}/{total >> 20} MB", file=sys.stderr, flush=True)
                        t0 = time.time()
            os.replace(tmp, dest)
            return dest
        except Exception as e:  # try next mirror
            last = e
            print(f"  failed: {e}", file=sys.stderr)
    die(f"Could not download {rel}: {last}. Set BLURT_HF_MIRROR=1 or download manually to {dest}")


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
# each backend: transcribe(samples) -> list[(rel_start, rel_end, text)]
class SenseVoice:
    # SenseVoice degrades on long, mixed-language chunks (drops whole clauses); keep utterances short
    max_chunk = 10

    def __init__(self, args):
        import sherpa_onnx
        self.rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(download("sensevoice/model.int8.onnx")), tokens=str(download("sensevoice/tokens.txt")),
            num_threads=getattr(args, "threads", None) or min(8, os.cpu_count() or 4), use_itn=True, language=args.language or "auto")

    def transcribe(self, x):
        st = self.rec.create_stream()
        st.accept_waveform(SR, x)
        self.rec.decode_stream(st)
        return [(0.0, len(x) / SR, st.result.text.strip())]


class MlxWhisper:
    max_chunk = 30

    def __init__(self, args):
        try:
            import mlx_whisper
        except ImportError:
            die("mlx-whisper not installed. Run with: uv run --with mlx-whisper transcribe.py ...")
        self.m, self.args = mlx_whisper, args
        self.repo = args.model or "mlx-community/whisper-large-v3-turbo"

    def transcribe(self, x):
        r = self.m.transcribe(x, path_or_hf_repo=self.repo, language=self.args.language, initial_prompt=self.args.prompt,
                              condition_on_previous_text=False, verbose=None)
        return [(s["start"], s["end"], s["text"].strip()) for s in r.get("segments", [])]


class FasterWhisper:
    max_chunk = 30

    def __init__(self, args):
        try:
            from faster_whisper import WhisperModel
        except ImportError:
            die("faster-whisper not installed. Run with: uv run --with faster-whisper transcribe.py ...")
        self.args = args
        self.model = WhisperModel(args.model or "large-v3-turbo", device="auto", compute_type="auto",
                                  download_root=str(MODELS_DIR / "faster-whisper"))

    def transcribe(self, x):
        segs, _ = self.model.transcribe(x, language=self.args.language, initial_prompt=self.args.prompt,
                                        condition_on_previous_text=False, vad_filter=False)
        return [(s.start, s.end, s.text.strip()) for s in segs]


class OpenAICompat:
    """POST {base}/audio/transcriptions. verbose_json gives segment timestamps where supported."""

    def __init__(self, args):
        self.key = (os.environ.get("BLURT_ASR_API_KEY") or os.environ.get("OPENAI_API_KEY")
                    or os.environ.get("GROQ_API_KEY"))
        if not self.key:
            die("No API key. Set BLURT_ASR_API_KEY (or OPENAI_API_KEY / GROQ_API_KEY).")
        default_base = "https://api.groq.com/openai/v1" if (os.environ.get("GROQ_API_KEY") and not os.environ.get(
            "BLURT_ASR_API_KEY")) else "https://api.openai.com/v1"
        self.base = (os.environ.get("BLURT_ASR_BASE_URL") or default_base).rstrip("/")
        self.model = args.model or os.environ.get("BLURT_ASR_MODEL") or (
            "whisper-large-v3-turbo" if "groq" in self.base else "whisper-1")
        self.verbose = not self.model.startswith("gpt-4o")  # gpt-4o-*-transcribe has no segment timestamps
        # Longer chunks = fewer requests (Groq bills >=10s per request); shorter when no timestamps come back.
        self.max_chunk = 60 if self.verbose else 20
        self.args = args

    def transcribe(self, x):
        fields = {"model": self.model, "response_format": "verbose_json" if self.verbose else "json"}
        if self.args.language:
            fields["language"] = self.args.language
        if self.args.prompt:
            fields["prompt"] = self.args.prompt
        boundary = uuid.uuid4().hex
        body = io.BytesIO()
        for k, v in fields.items():
            body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
                   f'Content-Type: audio/wav\r\n\r\n'.encode())
        body.write(wav_bytes(x))
        body.write(f"\r\n--{boundary}--\r\n".encode())
        data = _post(f"{self.base}/audio/transcriptions", body.getvalue(),
                     {"Authorization": f"Bearer {self.key}", "Content-Type": f"multipart/form-data; boundary={boundary}"})
        if data.get("segments"):
            return [(s["start"], s["end"], s["text"].strip()) for s in data["segments"]]
        return [(0.0, len(x) / SR, (data.get("text") or "").strip())]


class DashScope:
    max_chunk = 20

    def __init__(self, args):
        self.key = os.environ.get("DASHSCOPE_API_KEY") or die("Set DASHSCOPE_API_KEY")
        self.base = (os.environ.get("BLURT_ASR_BASE_URL") or "https://dashscope.aliyuncs.com/compatible-mode/v1").rstrip("/")
        self.model = args.model or "qwen3-asr-flash"
        self.args = args

    def transcribe(self, x):
        audio = "data:audio/wav;base64," + base64.b64encode(wav_bytes(x)).decode()
        payload = {"model": self.model, "stream": False,
                   "messages": [{"role": "system", "content": [{"text": self.args.prompt or ""}]},
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
            die(f"ASR API error {e.code}: {msg}")
        except urllib.error.URLError as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
                continue
            die(f"ASR API unreachable: {e}")


BACKENDS = {"sensevoice": SenseVoice, "mlx-whisper": MlxWhisper, "faster-whisper": FasterWhisper,
            "openai": OpenAICompat, "dashscope": DashScope}
LOCAL = {"sensevoice", "mlx-whisper", "faster-whisper"}


# ------------------------------------------------------------------ shared pipeline (also used by live.py)
EXTRA_PACKAGES = {"mlx-whisper": "mlx_whisper", "faster-whisper": "faster_whisper"}  # needs `uv run --with <name>`
API_KEYS = {"openai": ("BLURT_ASR_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY"), "dashscope": ("DASHSCOPE_API_KEY",)}


def resolve_backend(a) -> str:
    """Backend from --backend or the configured one; fills a.model / a.language / a.prompt from config."""
    cfg = global_config().get("asr", {})
    name = getattr(a, "backend", None) or cfg.get("backend") or "sensevoice"
    a.model = getattr(a, "model", None) or (cfg.get("model") if name == cfg.get("backend") else None)
    a.language = getattr(a, "language", None) or cfg.get("language")
    a.prompt = getattr(a, "prompt", None)
    if name not in BACKENDS:
        die(f"unknown backend {name}; choose from {list(BACKENDS)}")
    return name


def backend_ready(name: str) -> str | None:
    """None when `name` can run right now without downloading anything or asking for a key, else why not."""
    have = lambda rel: (MODELS_DIR / rel).exists()  # noqa: E731
    if name not in BACKENDS:
        return f"unknown backend {name}"
    if not have("silero_vad.onnx"):
        return "VAD model not downloaded (transcribe.py setup)"
    if name == "sensevoice" and not (have("sensevoice/model.int8.onnx") and have("sensevoice/tokens.txt")):
        return "SenseVoice model not downloaded (transcribe.py setup)"
    if name in API_KEYS and not any(os.environ.get(k) for k in API_KEYS[name]):
        return f"no API key in the environment ({' / '.join(API_KEYS[name])})"
    return None


def model_label(name: str, backend, a) -> str | None:
    if name == "sensevoice":
        return "sense-voice-small-int8"
    m = getattr(backend, "model", None)
    return m if isinstance(m, str) else getattr(backend, "repo", None) or a.model


def decode_slice(backend, x: np.ndarray, s: float, e: float) -> list[tuple[float, float, str]]:
    """Transcribe x (= the samples of chunk s..e seconds) → segments on the original timeline."""
    return [(s + rs, s + min(re_, e - s), t) for rs, re_, t in backend.transcribe(x)]


def decode_chunk(backend, samples: np.ndarray, s: float, e: float) -> list[tuple[float, float, str]]:
    return decode_slice(backend, samples[int(s * SR):int(e * SR)], s, e)


def is_blank(results) -> bool:
    return not any(ch.isalnum() for *_, t in results for ch in t)


def build_transcript(source: str, name: str, backend, a, duration: float, speech: float, blank: float,
                     results: list, elapsed: float) -> dict:
    """results: [(start, end, text, speaker|None)] → the transcript.json document."""
    results = sorted(results, key=lambda r: r[0])
    segments = [{"start": round(s, 2), "end": round(e, 2), "text": t, **({"speaker": lb} if lb else {})}
                for s, e, t, lb in results if t]
    data = {"source": source, "backend": name, "model": model_label(name, backend, a),
            "duration": round(duration, 2), "speech_seconds": round(speech, 2),
            "elapsed_seconds": round(elapsed, 1), "segments": segments}
    # SenseVoice knows only zh/en/ja/ko/yue; other languages (German…) mostly come back as "." tagged <|en|>, so
    # the language tag can't catch it. Supported speech that VAD kept practically never decodes to nothing.
    # Mic track only: system audio may be music or effects.
    if name == "sensevoice" and speech >= 5 and blank / speech > 0.3:
        data["warning"] = (f"{blank:.0f}s of {speech:.0f}s of speech decoded to nothing: the language is probably "
                           "not zh/en/ja/ko/yue, which is all SenseVoice supports. Re-run with a Whisper or cloud "
                           "backend (see reference/asr.md) and pass --language.")
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
    """VAD → chunks → backend. Returns ([(start, end, text, label)], speech seconds, seconds that decoded to nothing)."""
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
            results.extend((s_, e_, t, label) for s_, e_, t in r)
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


def transcribe_shots(session: Path, a) -> None:
    latest = read_shots(session)
    todo = [(n, rec, wav) for n, rec in latest.items()
            if (wav := shot_voice(session, n, rec)) and (a.force or "said" not in rec)]
    name = resolve_backend(a)
    t0 = time.time()
    done = []
    if todo:
        backend = BACKENDS[name](a)
        workers = 1 if name in LOCAL else a.concurrency
        for n, rec, wav in todo:
            results, _, _ = transcribe_track(load_audio(wav), backend, name, workers, quiet=True)
            said = " ".join(t for _s, _e, t, _lb in sorted(results, key=lambda r: r[0]) if t).strip()
            # an update line with the same n (full record + "said"); later lines win — docs/design/snap-and-live.md
            with open(session / "shots.jsonl", "a", encoding="utf-8") as fh:
                fh.write(json.dumps({**rec, "said": said}, ensure_ascii=False) + "\n")
            done.append({"n": n, "said": said})
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
        if meta.get("mode") == "shots" or (not recs and (src / "shots.jsonl").exists()):
            return transcribe_shots(src, a)
        if not recs:
            die(f"no recording.* in {src}")
        src = recs[0]
    out = Path(a.out or src.parent)
    explicit = {"backend": a.backend, "model": a.model, "prompt": a.prompt}
    name = resolve_backend(a)

    data = live_transcript(src, out, a, explicit)
    n_tracks = max(1, audio_tracks(src))
    if data is not None and (n_tracks == 1 or any(s.get("speaker") == "system" for s in data["segments"])):
        files = [str(out / "transcript.json"), str(out / "transcript.txt")]
        if not (out / "transcript.txt").exists():
            files = write_transcript(out, data)
        print("transcript was already made during the recording (live/); --force redoes it", file=sys.stderr, flush=True)
        return print_summary(data, files, live=True)

    t0 = time.time()
    backend = BACKENDS[name](a)
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


def cmd_setup(a):
    name = a.backend
    if name == "sensevoice":
        for rel in MODEL_FILES:
            download(rel)
    else:
        download("silero_vad.onnx")
        if name in ("mlx-whisper", "faster-whisper"):
            print(f"Model weights download on first run. Always invoke with: uv run --with {name} transcribe.py run ...")
    patch = {"backend": name}
    if a.model:
        patch["model"] = a.model
    if a.language:
        patch["language"] = a.language
    update_global_config({"asr": patch})
    print(json.dumps({"ok": True, "asr": global_config()["asr"]}, ensure_ascii=False))


def cmd_backends(_a):
    have = lambda rel: (MODELS_DIR / rel).exists()  # noqa: E731
    print(json.dumps({
        "configured": global_config().get("asr"),
        "sensevoice_ready": have("sensevoice/model.int8.onnx") and have("sensevoice/tokens.txt") and have("silero_vad.onnx"),
        "api_keys": {k: bool(os.environ.get(k)) for k in ("BLURT_ASR_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY", "DASHSCOPE_API_KEY")},
    }, indent=2))


# ------------------------------------------------------------------ models / bench (for the apps' ASR settings)
# Sizes are what the download weighs (MB, approximate when not installed); "installed" is checked on disk.
CATALOG = [
    {"id": "silero-vad", "backend": "vad", "role": "vad", "local": True, "size_mb": 0.6, "languages": ["*"],
     "files": ["silero_vad.onnx"], "setup": "transcribe.py setup --backend sensevoice"},
    {"id": "sense-voice-small-int8", "backend": "sensevoice", "role": "asr", "local": True, "size_mb": 228,
     "languages": ["zh", "en", "ja", "ko", "yue"], "files": ["sensevoice/model.int8.onnx", "sensevoice/tokens.txt"],
     "setup": "transcribe.py setup --backend sensevoice", "default": True},
    {"id": "mlx-community/whisper-large-v3-turbo", "backend": "mlx-whisper", "role": "asr", "local": True,
     "size_mb": 1600, "languages": ["99 languages"], "platform": "macos-arm64",
     "hf_cache": "models--mlx-community--whisper-large-v3-turbo",
     "setup": "uv run --with mlx-whisper transcribe.py setup --backend mlx-whisper"},
    {"id": "large-v3-turbo", "backend": "faster-whisper", "role": "asr", "local": True, "size_mb": 1600,
     "languages": ["99 languages"], "dir": "faster-whisper",
     "setup": "uv run --with faster-whisper transcribe.py setup --backend faster-whisper"},
    {"id": "openai-compatible", "backend": "openai", "role": "asr", "local": False, "size_mb": 0,
     "languages": ["depends on the model"], "keys": list(API_KEYS["openai"])},
    {"id": "qwen3-asr-flash", "backend": "dashscope", "role": "asr", "local": False, "size_mb": 0,
     "languages": ["zh", "en", "ja", "ko", "yue", "+"], "keys": list(API_KEYS["dashscope"])},
]


def _du_mb(paths: list[Path]) -> float:
    total = 0
    for p in paths:
        if p.is_file():
            total += p.stat().st_size
        elif p.is_dir():
            total += sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    return round(total / 2**20, 1)


def model_rows() -> list[dict]:
    cfg = global_config().get("asr") or {}
    hf = Path(os.environ.get("HF_HOME") or Path.home() / ".cache" / "huggingface") / "hub"
    rows = []
    for m in CATALOG:
        r = {k: v for k, v in m.items() if k not in ("files", "hf_cache", "dir", "keys")}
        if m.get("files"):
            paths = [MODELS_DIR / f for f in m["files"]]
            r["installed"] = all(p.exists() and p.stat().st_size > 0 for p in paths)
            r["path"] = str(MODELS_DIR / Path(m["files"][0]).parts[0])
        elif m.get("hf_cache"):
            paths = [hf / m["hf_cache"]]
            r["installed"], r["path"] = paths[0].is_dir(), str(paths[0])
        elif m.get("dir"):
            d = MODELS_DIR / m["dir"]
            paths = list(d.glob(f"*{m['id']}*")) if d.is_dir() else []
            r["installed"], r["path"] = bool(paths), str(paths[0]) if paths else str(d)
        else:
            paths = []
            r["installed"] = any(os.environ.get(k) for k in m["keys"])  # cloud: "installed" = a key is set
            r["keys"] = m["keys"]
        if r["installed"] and paths:
            r["size_mb"], r["approx"] = _du_mb(paths), False
        else:
            r["approx"] = bool(m["local"])
        if m["backend"] in EXTRA_PACKAGES:
            r["package"] = m["backend"]
        r["configured"] = m["role"] == "asr" and m["backend"] == (cfg.get("backend") or "sensevoice")
        rows.append(r)
    return rows


def cmd_models(_a):
    print(json.dumps({"models_dir": str(MODELS_DIR), "configured": global_config().get("asr"), "models": model_rows()},
                     ensure_ascii=False, indent=2))


BENCH_TEXT = ("大家好，这是一段用来测试语音识别速度的样本。我们先打开登录页面，输入账号和密码，然后点击登录按钮。"
              "按钮点了之后没有任何反应，控制台也没有报错。接着看一下设置页，保存按钮的颜色太浅了，看不出来可以点击。"
              "最后还有一个想法，以后可以加一个导出表格的功能，方便发给运营的同事。")


def bench_sample(seconds: float) -> Path:
    """A spoken sample made with macOS `say` (repeated to fill `seconds`), cached under $BLURT_HOME/bench/."""
    import shutil
    out = MODELS_DIR.parent / "bench" / f"sample-{int(seconds)}s.wav"
    if out.exists():
        return out
    if not shutil.which("say"):
        die("no AUDIO given and no `say` to make a sample: pass a recording, e.g. transcribe.py bench clip.mp4")
    out.parent.mkdir(parents=True, exist_ok=True)
    raw = out.with_suffix(".aiff")
    subprocess.run(["say", "-v", "Tingting", "-o", str(raw), BENCH_TEXT * 3], check=False, capture_output=True)
    if not raw.exists():
        subprocess.run(["say", "-o", str(raw), "This is a speech recognition speed test. " * 20], check=True)
    subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-i", str(raw), "-t", str(seconds), "-ar",
                    str(SR), "-ac", "1", str(out)], check=True)
    raw.unlink(missing_ok=True)
    return out


def cmd_bench(a):
    src = Path(a.input) if a.input else bench_sample(a.seconds)
    if not src.exists():
        die(f"{src} not found")
    name = resolve_backend(a)
    samples = load_audio(src)[: int(a.seconds * SR)]
    audio_s = len(samples) / SR
    t0 = time.perf_counter()
    backend = BACKENDS[name](a)
    load_s = time.perf_counter() - t0
    t1 = time.perf_counter()
    results, speech, _blank = transcribe_track(samples, backend, name, 1 if name in LOCAL else a.concurrency, quiet=True)
    dec_s = time.perf_counter() - t1
    text = "".join(t for _, _, t, _ in results)
    print(json.dumps({"backend": name, "model": model_label(name, backend, a), "audio": str(src),
                      "audio_seconds": round(audio_s, 2), "speech_seconds": round(speech, 2),
                      "load_seconds": round(load_s, 2), "decode_seconds": round(dec_s, 2),
                      "rtf": round(dec_s / audio_s, 4) if audio_s else None,
                      "cpu_count": os.cpu_count(), "chars": len(text), "text_preview": text[:120]},
                     ensure_ascii=False, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("input")
    r.add_argument("--out", help="output dir (default: next to input)")
    r.add_argument("--backend", choices=list(BACKENDS))
    r.add_argument("--model")
    r.add_argument("--language", help="e.g. zh, en; default auto-detect")
    r.add_argument("--prompt", help="glossary / context: product & module names, jargon (Whisper/API backends)")
    r.add_argument("--concurrency", type=int, default=4)
    r.add_argument("--force", action="store_true", help="transcribe again even if live.py already did")
    s = sub.add_parser("setup")
    s.add_argument("--backend", choices=list(BACKENDS), default="sensevoice")
    s.add_argument("--model")
    s.add_argument("--language")
    sub.add_parser("backends")
    sub.add_parser("models")
    b = sub.add_parser("bench")
    b.add_argument("input", nargs="?", help="audio / video file (default: a spoken sample made with `say`)")
    b.add_argument("--backend", choices=list(BACKENDS))
    b.add_argument("--model")
    b.add_argument("--language")
    b.add_argument("--prompt")
    b.add_argument("--seconds", type=float, default=30)
    b.add_argument("--concurrency", type=int, default=4)
    a = p.parse_args()
    {"run": cmd_run, "setup": cmd_setup, "backends": cmd_backends, "models": cmd_models, "bench": cmd_bench}[a.cmd](a)


if __name__ == "__main__":
    main()
