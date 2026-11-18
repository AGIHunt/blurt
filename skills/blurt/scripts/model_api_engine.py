"""Serve Blurt's already installed weights. Importing or listing models needs only Python.

Inference runs in a dedicated, single-request-at-a-time process owned by the API server.
Only that process loads model libraries. A model change retires the process and all its weights.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import wave
from argparse import Namespace
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import polish
import screen_ocr
import screen_text
import transcribe as speech
from _common import BLURT_HOME, file_lock, folder_complete, load_json, private_dir, write_text_atomic
from model_api_native_tools import NativeReply, template_messages

HERE = Path(__file__).resolve().parent
MAX_AUDIO_SECONDS = 600
TINY_OCR = "pp-ocrv6-tiny"


@dataclass(frozen=True)
class Model:
    id: str
    name: str
    capability: str
    backend: str
    path: Path


def _has_chat_template(path: Path) -> bool:
    if (path / "chat_template.jinja").is_file():
        return True
    config = load_json(path / "tokenizer_config.json", None)
    return isinstance(config, dict) and bool(config.get("chat_template"))


def _models():
    # These checks use Blurt's manifests and recognize both its mirror and HF snapshot layout.
    for item in speech.entries(local_only=True):
        if not item.get("install") or item["backend"] not in speech.LOCAL or not speech.runs_here(item):
            continue
        path = speech.model_path(item)
        if path and (speech.BUNDLED_VAD.is_file() or (speech.MODELS_DIR / "silero_vad.onnx").is_file()):
            yield Model(item["id"], item["name"], "transcription", item["backend"], path)
    if polish.supported():
        for item in polish.registry()["models"]:
            path = polish.model_path(item)
            if path and _has_chat_template(path):
                yield Model(item["id"], item["name"], "chat", "mlx-lm", path)
        path = screen_text.model_path()
        if path:
            yield Model(screen_text.MODEL["id"], screen_text.MODEL["name"], "ocr", "mlx-vlm", path)
    if folder_complete(screen_ocr.MODEL_DIR) and all((screen_ocr.MODEL_DIR / f["path"]).is_file()
                                                     for f in screen_ocr.MODEL_FILES):
        yield Model(TINY_OCR, "PP-OCRv6 tiny", "ocr", "rapidocr", screen_ocr.MODEL_DIR)


def available_models() -> list[dict]:
    return [{"id": m.id, "name": m.name, "capability": m.capability} for m in _models()]


def _find(model_id: str, capability: str | None = None) -> Model:
    model = next((m for m in _models() if m.id == model_id), None)
    if model is None:
        raise LookupError("The requested local model is not installed for this platform.")
    if capability and model.capability != capability:
        raise ValueError(f"This model does not support {capability}.")
    return model


def _requirements(model: Model) -> tuple[str, str | None, list[str]]:
    if model.capability == "transcription":
        script = "transcribe.py"
        package = speech.EXTRA_PACKAGES.get(model.backend)
        extra = speech.PACKAGE_PINS.get(package, package)
        modules = ["numpy", "sherpa_onnx", "opencc"]
        if package:
            modules.append(package.replace("-", "_"))
    elif model.capability == "chat":
        script, extra, modules = "polish.py", polish.MLX_PACKAGE, ["mlx_lm", "numpy"]
    elif model.backend == "mlx-vlm":
        script, extra, modules = "screen_text.py", screen_text.MLX_VLM_PACKAGE, ["mlx_vlm", "PIL"]
    else:
        script, extra, modules = "screen_ocr.py", None, ["rapidocr", "onnxruntime", "PIL"]
    return script, extra, modules


def _uv() -> str:
    exe = "uv.exe" if os.name == "nt" else "uv"
    uv = shutil.which(exe)
    if not uv:
        # Desktop onboarding and the user's uv installer may live outside a GUI app's PATH.
        dirs = (BLURT_HOME / "bin", Path.home() / ".blurt/bin", Path.home() / ".local/bin", Path.home() / ".cargo/bin")
        uv = next((str(d / exe) for d in dirs if (d / exe).is_file()), None)
    if not uv:
        raise RuntimeError("Install Blurt's Python runtime (uv), then retry.")
    return uv


def _indexes(model: Model) -> list[str]:
    if model.backend in ("mlx-lm", "mlx-vlm") and polish.mirror_on() and not (
            os.getenv("UV_DEFAULT_INDEX") or os.getenv("UV_INDEX_URL")):
        return ["--index", "https://mirrors.aliyun.com/pypi/simple/"]
    return []


def _environment(script: str, extra: str | None) -> Path:
    # Only changes to PEP 723 metadata and optional dependencies need a new runtime.
    with (HERE / script).open("rb") as source:
        if source.readline().strip() != b"# /// script":
            raise RuntimeError("The bundled runtime requirements are missing.")
        digest = hashlib.sha256((extra or "").encode())
        for line in source:
            if line.strip() == b"# ///":
                break
            digest.update(line.rstrip() + b"\n")
        else:
            raise RuntimeError("The bundled runtime requirements are incomplete.")
    key = f"{speech.platform_key()}-py312-{Path(script).stem}-{digest.hexdigest()[:16]}"
    return BLURT_HOME / "model-api" / "runtimes" / key


def _env_python(env: Path) -> Path:
    return env / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def _prepare_step(command: list[str], stage: str) -> None:
    # Package installation can contact the configured package index. Import validation may use only local files.
    env = {**os.environ, "BLURT_NO_DOWNLOAD": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
           "HF_HUB_DISABLE_TELEMETRY": "1"}
    try:
        subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=env, check=True, timeout=900)
    except (OSError, subprocess.SubprocessError):
        # uv output may contain user-configured index URLs, including credentials.
        raise RuntimeError(f"{stage} failed. Check the package index, disk space and platform support, then retry.") from None


def prepare_runtime(model_id: str) -> dict:
    """Explicitly prepare a durable Python environment; no model loader is invoked here."""
    model = _find(model_id)
    script, extra, modules = _requirements(model)
    directory = _environment(script, extra)
    python = _env_python(directory)
    marker = directory / ".blurt-ready"
    verify = [str(python), "-I", "-c", "import " + ", ".join(modules)]
    result = {"id": model.id, "prepared": True}
    private_dir(directory.parent)
    with file_lock(directory.with_suffix(".lock"), timeout=1800):
        if marker.is_file() and python.is_file():
            try:
                _prepare_step(verify, "Validating the model runtime")
                return result
            except RuntimeError:
                pass  # Repair a previously prepared environment with missing/broken dependencies.
        marker.unlink(missing_ok=True)
        repair = python.is_file()
        uv = _uv()
        _prepare_step([uv, "venv", "--no-project", "--allow-existing", "--python", "3.12", str(directory)],
                      "Preparing Python 3.12")
        install = [uv, "pip", "install", "--python", str(python), "-r", str(HERE / script), *_indexes(model)]
        if extra:
            install.append(extra)
        if repair:
            install.append("--reinstall")
        _prepare_step(install, "Installing the model runtime packages")
        _prepare_step(verify, "Validating the model runtime")
        write_text_atomic(marker, "ready\n")
    return result


def worker_command(model_id: str, worker_script: str) -> list[str]:
    """Prefer the durable env; otherwise use the current interpreter or uv's offline package cache."""
    model = _find(model_id)
    script, extra, modules = _requirements(model)
    directory = _environment(script, extra)
    python = _env_python(directory)
    if (directory / ".blurt-ready").is_file() and python.is_file():
        return [str(python), "-u", worker_script]
    if all(importlib.util.find_spec(name) is not None for name in modules):
        return [sys.executable, "-u", worker_script]
    cmd = [_uv(), "run", "--python", sys.executable, "--offline", "--no-python-downloads", "--no-project", "-q",
           "--with-requirements", str(HERE / script), *_indexes(model)]
    if extra:
        cmd.extend(["--with", extra])
    return [*cmd, "python", "-u", worker_script]


def _offline():
    # Set before importing a library which caches the hub's offline flag at import time.
    os.environ.update(BLURT_NO_DOWNLOAD="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                      HF_HUB_DISABLE_TELEMETRY="1")


@lru_cache(maxsize=1)
def _ffmpeg_input(ffmpeg: str) -> tuple[str, str]:
    # fd preserves seeking in M4A files with a trailing index. Older ffmpeg builds only have pipe.
    protocols = subprocess.run([ffmpeg, "-protocols"], capture_output=True, timeout=5).stdout.split()
    return ("fd", "fd:") if b"fd" in protocols else ("pipe", "pipe:0")


def _audio(path: str):
    import numpy as np
    limit = speech.SR * MAX_AUDIO_SECONDS
    try:
        with wave.open(path, "rb") as w:
            if (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (speech.SR, 1, 2):
                if w.getnframes() > limit:
                    raise ValueError(f"Audio exceeds {MAX_AUDIO_SECONDS} seconds.")
                data = w.readframes(w.getnframes())
                if not data or len(data) != w.getnframes() * 2:
                    raise ValueError("Empty or incomplete WAV audio.")
                return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768
    except (wave.Error, EOFError):
        pass
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise ValueError("Use a mono 16 kHz 16-bit PCM WAV, or install ffmpeg for other audio formats.")
    # Only the uploaded descriptor and self-contained audio containers. Bound decoded output independently of upload size.
    protocol, source = _ffmpeg_input(ffmpeg)
    with open(path, "rb") as upload:
        result = subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-protocol_whitelist", protocol, "-format_whitelist",
                                 "wav,mp3,flac,ogg,aac,mov,matroska,webm", "-i", source, "-map", "0:a:0",
                                 "-t", str(MAX_AUDIO_SECONDS + 1), "-ac", "1", "-ar", str(speech.SR), "-f", "s16le",
                                 "pipe:1"], stdin=upload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
    if result.returncode or not result.stdout:
        raise ValueError("Unreadable or unsupported audio upload.")
    if len(result.stdout) > limit * 2:
        raise ValueError(f"Audio exceeds {MAX_AUDIO_SECONDS} seconds.")
    return np.frombuffer(result.stdout, dtype="<i2").astype(np.float32) / 32768


_recognizer = None
_recognizer_key = None


def transcribe(model_id: str, path: str, language: str | None = None) -> str:
    global _recognizer, _recognizer_key
    m = _find(model_id, "transcription")
    _offline()
    samples = _audio(path)
    language = None if language in (None, "", "auto") else language
    key = (m, language)
    if _recognizer_key != key:
        if hasattr(_recognizer, "close"):
            _recognizer.close()
        _recognizer = _recognizer_key = None
        args = Namespace(model=str(m.path.resolve()), model_id=m.id, prompt=None, language=language,
                         threads=speech.limits()["threads"])
        _recognizer = speech.BACKENDS[m.backend](args)
        _recognizer_key = key
    results, _, _ = speech.transcribe_track(samples, _recognizer, m.backend, workers=1, quiet=True)
    return speech.note_text(results)[0]


@lru_cache(maxsize=1)
def _chat_model(path: Path):
    from mlx_lm import load
    polish.cap_memory()
    model, tokenizer = load(str(path.resolve()), lazy=True)
    polish.offload_per_layer_embeddings(model, path)
    return model, tokenizer


class ContextLengthExceeded(ValueError):
    def __init__(self, prompt_tokens: int, context_window: int):
        self.prompt_tokens = prompt_tokens
        self.context_window = context_window
        super().__init__(f"The prompt uses {prompt_tokens} tokens in a {context_window}-token context window.")


def _context_window(path: Path, tokenizer):
    config = load_json(path / "config.json", {})
    # Multimodal checkpoints put the language model's limit inside text_config.
    text_config = config.get("text_config") or {}
    for limit in (text_config.get("max_position_embeddings"), config.get("max_position_embeddings"),
                  getattr(tokenizer, "model_max_length", None)):
        if type(limit) is int and limit > 0:
            return limit
    return None


def chat_events(model_id: str, messages: list[dict], max_tokens: int, temperature: float, options=None):
    m = _find(model_id, "chat")
    _offline()
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler
    model, tokenizer = _chat_model(m.path)
    reply = NativeReply(tokenizer, messages, options or {})
    template_args = {"tools": reply.tools} if reply.tools else {}
    tokens = tokenizer.apply_chat_template(template_messages(messages), add_generation_prompt=True, tokenize=True,
                                           enable_thinking=False, **template_args)
    if messages[-1]["role"] == "tool" and reply.start == "<|tool_call>":
        # Gemma 4's bundled template can stop exactly at the tool response, where E2B predicts EOS.
        # Open its next model turn only for templates that omitted the generation prompt.
        response_end = tokenizer.encode("<tool_response|>", add_special_tokens=False)
        if response_end and tokens[-len(response_end):] == response_end:
            tokens = [*tokens, *tokenizer.encode("<turn|>\n<|turn>model\n", add_special_tokens=False)]
    if reply.force:
        # Continue inside a native call. The model must still generate a valid declared name and arguments.
        tokens = [*tokens, *tokenizer.encode(reply.start, add_special_tokens=False)]
    prompt_tokens = len(tokens)
    window = _context_window(m.path, tokenizer)
    if window is not None:
        if prompt_tokens >= window:
            raise ContextLengthExceeded(prompt_tokens, window)
        max_tokens = min(max_tokens, window - prompt_tokens)
    yield "prompt_tokens", prompt_tokens
    text = []
    completion_tokens = 0
    reason = "stop"
    parts = stream_generate(model, tokenizer, tokens, max_tokens=max_tokens, sampler=make_sampler(temp=temperature))
    try:
        for completion_tokens, part in enumerate(parts, 1):
            for delta in reply.feed(part.text):
                text.append(delta)
                yield "delta", delta
            reason = getattr(part, "finish_reason", None) or "stop"
            if reply.complete:
                break
    finally:
        if hasattr(parts, "close"):
            parts.close()
    tail = reply.finish(reason)
    if tail:
        text.append(tail)
        yield "delta", tail
    result = {"text": "".join(text), "finish_reason": reason, "usage": {
        "prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens}}
    if reply.calls:
        result.update(tool_calls=reply.calls, finish_reason="tool_calls")
    yield "done", result


def chat_stream(model_id: str, messages: list[dict], max_tokens: int, temperature: float):
    for kind, value in chat_events(model_id, messages, max_tokens, temperature):
        if kind == "delta":
            yield value


def chat(model_id: str, messages: list[dict], max_tokens: int, temperature: float) -> str:
    return "".join(chat_stream(model_id, messages, max_tokens, temperature))


@lru_cache(maxsize=1)
def _reader(backend: str):
    return screen_text.Engine() if backend == "mlx-vlm" else screen_ocr.Engine(installed_only=True)


def ocr(model_id: str, path: str) -> str:
    m = _find(model_id, "ocr")
    _offline()
    from PIL import Image, UnidentifiedImageError
    try:
        with Image.open(path, formats=["PNG", "JPEG"]) as im:
            if im.width * im.height > screen_text.MAX_PIXELS or getattr(im, "n_frames", 1) != 1:
                raise ValueError(f"Use one image of at most {screen_text.MAX_PIXELS:,} pixels.")
            im.load()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, SyntaxError) as e:
        raise ValueError("Unreadable image. Supply one PNG or JPEG.") from e
    reader = _reader(m.backend)
    if m.backend == "mlx-vlm":
        return reader.read(path, draft=None)["text"]
    return screen_ocr.rows(reader.read(path)["lines"])
