# /// script
# requires-python = ">=3.10"
# ///
"""Environment check + ASR recommendation. Prints JSON; the agent explains it to the user.

  doctor.py            full report
"""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import IS_MAC, IS_WIN, MODELS_DIR, global_config, run, system_info  # noqa: E402


def recommend(info: dict) -> list[dict]:
    """Ordered ASR options for this machine. SenseVoice covers zh/en/ja/ko/yue on any CPU; Whisper for other languages."""
    ram = info.get("ram_gb") or 8
    recs = [{"backend": "sensevoice", "why": "Local, ~240MB, very fast on CPU, great for Chinese/English/Japanese/Korean/"
             "Cantonese incl. code-switching. Default choice.", "setup": "transcribe.py setup --backend sensevoice"}]
    if info["apple_silicon"] and ram >= 16:
        recs.append({"backend": "mlx-whisper", "model": "mlx-community/whisper-large-v3-turbo",
                     "why": "Local on Apple GPU, 99 languages, ~1.6GB. Pick when speech is not zh/en/ja/ko/yue.",
                     "setup": "uv run --with mlx-whisper transcribe.py setup --backend mlx-whisper"})
    elif info.get("nvidia_gpu"):
        recs.append({"backend": "faster-whisper", "model": "large-v3-turbo",
                     "why": "Local on NVIDIA GPU, 99 languages. Needs CUDA 12 + cuDNN 9 runtime.",
                     "setup": "uv run --with faster-whisper transcribe.py setup --backend faster-whisper"})
    elif ram >= 8:
        recs.append({"backend": "faster-whisper", "model": "small",
                     "why": "Local CPU fallback for other languages (slower, ~0.5GB).",
                     "setup": "uv run --with faster-whisper transcribe.py setup --backend faster-whisper --model small"})
    recs.append({"backend": "openai", "why": "Cloud, user's own key. Groq whisper-large-v3-turbo ≈ $0.04/audio-hour; "
                 "OpenAI whisper-1 ≈ $0.36/h; gpt-4o-mini-transcribe ≈ $0.18/h. Only speech (after VAD) is billed.",
                 "setup": "export GROQ_API_KEY=... (or BLURT_ASR_API_KEY + BLURT_ASR_BASE_URL + BLURT_ASR_MODEL)"})
    recs.append({"backend": "dashscope", "why": "Cloud, Alibaba Qwen3-ASR-Flash, strong Chinese; roughly ¥1/audio-hour "
                 "(check console pricing).", "setup": "export DASHSCOPE_API_KEY=..."})
    return recs


def main():
    info = system_info()
    ff = shutil.which("ffmpeg")
    report = {
        "system": info,
        "ffmpeg": run([ff, "-version"]).stdout.splitlines()[0] if ff else None,
        "uv": shutil.which("uv"),
        "lark_cli": shutil.which("lark-cli"),
        "gh": shutil.which("gh"),
        "disk_free_gb": round(shutil.disk_usage(Path.cwd()).free / 2**30, 1),
        "asr_configured": global_config().get("asr"),
        "sensevoice_downloaded": (MODELS_DIR / "sensevoice" / "model.int8.onnx").exists(),
        "api_keys": {k: bool(os.environ.get(k)) for k in
                     ("BLURT_ASR_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY", "DASHSCOPE_API_KEY")},
        "asr_recommendations": recommend(info),
        "todo": [],
    }
    if not ff:
        report["todo"].append("Install ffmpeg: " + ("brew install ffmpeg" if IS_MAC else "winget install Gyan.FFmpeg"))
    if not report["asr_configured"]:
        report["todo"].append("Choose an ASR backend (see asr_recommendations) and run its setup command")
    if IS_MAC:
        report["todo"].append("Run `record.py test` once: macOS needs Screen Recording + Microphone permission for the "
                              "app hosting this agent (Terminal/iTerm/VS Code/Claude/Codex), then a restart of that app")
    if IS_WIN and ff and "ddagrab" not in run([ff, "-hide_banner", "-filters"], check=False).stdout:
        report["todo"].append("ffmpeg lacks ddagrab (needs ffmpeg ≥ 6); gdigrab will be used (fine, a bit heavier)")
    if report["disk_free_gb"] < 5:
        report["todo"].append("Low disk space: recordings use ~1–2 GB per hour")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
