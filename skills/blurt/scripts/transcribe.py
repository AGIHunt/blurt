# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "sherpa-onnx>=1.12"]
# ///
"""Speech-to-text with timestamps. Always VAD-first: silence is dropped, speech is chunked, and every
chunk keeps its offset in the original video, so any backend (even ones without timestamps) works.

  transcribe.py setup  --backend sensevoice          download models for a local backend
  transcribe.py run    <video|audio> [--out DIR]     transcribe; writes transcript.json + transcript.txt
  transcribe.py backends                             list backends and whether they are ready

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
from _common import MODELS_DIR, die, ffmpeg_bin, fmt_ts, global_config, save_json, update_global_config  # noqa: E402

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
def load_audio(path: Path) -> np.ndarray:
    raw = subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-i", str(path), "-vn", "-ac", "1",
                          "-af", "aresample=async=1000:first_pts=0", "-ar", str(SR), "-f", "s16le", "-"], capture_output=True).stdout
    if not raw:
        die(f"No audio track decoded from {path}")
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768


def vad_segments(samples: np.ndarray, max_speech: float = 25) -> list[tuple[float, float]]:
    import sherpa_onnx
    cfg = sherpa_onnx.VadModelConfig()
    cfg.silero_vad.model = str(download("silero_vad.onnx"))
    cfg.silero_vad.threshold = 0.45
    cfg.silero_vad.min_silence_duration = 0.3
    cfg.silero_vad.min_speech_duration = 0.25
    cfg.silero_vad.max_speech_duration = max_speech
    cfg.sample_rate = SR
    vad = sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=60)
    win = cfg.silero_vad.window_size
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
    # pad a little so words at the edges are not clipped
    dur = len(samples) / SR
    return [(max(0.0, s - 0.15), min(dur, e + 0.2)) for s, e in segs]


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
            num_threads=min(8, os.cpu_count() or 4), use_itn=True, language=args.language or "auto")

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


# ------------------------------------------------------------------ commands
def cmd_run(a):
    src = Path(a.input)
    if not src.exists():
        die(f"{src} not found")
    out = Path(a.out or src.parent)
    cfg = global_config().get("asr", {})
    name = a.backend or cfg.get("backend") or "sensevoice"
    a.model = a.model or (cfg.get("model") if name == cfg.get("backend") else None)
    a.language = a.language or cfg.get("language")
    if name not in BACKENDS:
        die(f"unknown backend {name}; choose from {list(BACKENDS)}")

    t0 = time.time()
    samples = load_audio(src)
    duration = len(samples) / SR
    backend = BACKENDS[name](a)
    segs = vad_segments(samples, max_speech=min(25, backend.max_chunk))
    chunks = group_chunks(segs, backend.max_chunk)
    speech = sum(e - s for s, e in chunks)
    print(f"audio {fmt_ts(duration)}, speech {fmt_ts(speech)} in {len(chunks)} chunks → {name}", file=sys.stderr, flush=True)

    def work(ch):
        s, e = ch
        return [(s + rs, s + min(re_, e - s), t) for rs, re_, t in backend.transcribe(samples[int(s * SR):int(e * SR)])]

    workers = 1 if name in LOCAL else a.concurrency
    results = []
    with ThreadPoolExecutor(workers) as pool:
        for i, r in enumerate(pool.map(work, chunks)):
            results.extend(r)
            if (i + 1) % 20 == 0:
                print(f"  {i + 1}/{len(chunks)} chunks", file=sys.stderr, flush=True)

    segments = [{"start": round(s, 2), "end": round(e, 2), "text": t} for s, e, t in results if t]
    data = {"source": src.name, "backend": name, "model": getattr(backend, "model", None) if name != "sensevoice" else "sense-voice-small-int8",
            "duration": round(duration, 2), "speech_seconds": round(speech, 2),
            "elapsed_seconds": round(time.time() - t0, 1), "segments": segments}
    save_json(out / "transcript.json", data)
    lines = [f"[{fmt_ts(s['start'])}-{fmt_ts(s['end'])}] {s['text']}" for s in segments]
    (out / "transcript.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in data.items() if k != "segments"} | {"segments": len(segments),
                                                                              "files": [str(out / "transcript.json"), str(out / "transcript.txt")]},
                     ensure_ascii=False, indent=2))


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
    s = sub.add_parser("setup")
    s.add_argument("--backend", choices=list(BACKENDS), default="sensevoice")
    s.add_argument("--model")
    s.add_argument("--language")
    sub.add_parser("backends")
    a = p.parse_args()
    {"run": cmd_run, "setup": cmd_setup, "backends": cmd_backends}[a.cmd](a)


if __name__ == "__main__":
    main()
