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
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import IS_LINUX, IS_MAC, IS_WIN, MODELS_DIR, global_config, run, system_info  # noqa: E402


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


# Variables an agent session (Claude Code, the Claude / Codex desktop apps, codex) exports to its children; the Blurt
# app drops them before launching the agent (BlurtRecorder.swift: isAgentSessionVar) — e.g. CLAUDE_CODE_SIMPLE=1 makes
# `claude` skip the keychain login. Check login state the way the app will run the agent, not the way this session does.
_SESSION_PREFIXES = ("CLAUDE", "ANTHROPIC_", "CODEX_", "MCP_", "OTEL_")
_SESSION_NAMES = {"AI_AGENT", "BAGGAGE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "API_TIMEOUT_MS", "DISABLE_AUTOUPDATER",
                  "DISABLE_MICROCOMPACT", "BLURT_APP"}


def _is_session_var(k: str) -> bool:
    return k.startswith(_SESSION_PREFIXES) or k in _SESSION_NAMES


def agent_env() -> dict:
    """Like the app's agentEnvironment(): this env minus agent-session vars, plus what the user's login shell sets."""
    env = {k: v for k, v in os.environ.items() if not _is_session_var(k)}
    sh = os.environ.get("SHELL")
    if not IS_WIN and sh and os.path.isabs(sh) and os.access(sh, os.X_OK):
        try:
            out = run([sh, "-ilc", "printf '\\n__BLURT_ENV__\\n'; env -0"], check=False, env=env, timeout=8,
                      stdin=subprocess.DEVNULL).stdout
            _, sep, rest = out.partition("\n__BLURT_ENV__\n")
            for entry in rest.split("\0") if sep else []:
                k, eq, v = entry.partition("=")
                if eq and k and k not in ("SHLVL", "_", "PWD", "OLDPWD"):
                    env[k] = v
        except (OSError, subprocess.SubprocessError):
            pass
    return env


def agent_clis() -> dict:
    """The agent CLIs the Blurt app can hand recordings to: path, version, logged in (None = couldn't tell)."""
    env = agent_env()
    path = env.get("PATH")
    report = {}
    for name, login_args in (("claude", ["auth", "status", "--json"]), ("codex", ["login", "status"])):
        exe = shutil.which(name, path=path) or shutil.which(name)
        info: dict = {"path": exe, "version": None, "logged_in": None}
        if exe:
            try:
                v = run([exe, "--version"], check=False, env=env, timeout=15, stdin=subprocess.DEVNULL)
                info["version"] = (v.stdout or v.stderr).strip().splitlines()[0] if (v.stdout or v.stderr).strip() else None
                r = run([exe, *login_args], check=False, env=env, timeout=20, stdin=subprocess.DEVNULL)
                text = (r.stdout or "") + (r.stderr or "")
                info["logged_in"] = parse_login(name, r.returncode, text)
            except (OSError, subprocess.SubprocessError):
                pass
        report[name] = info
    return report


def parse_login(name: str, code: int, text: str) -> bool | None:
    if name == "claude" and "{" in text:
        try:
            v = json.loads(text[text.index("{"):]).get("loggedIn")
            if isinstance(v, bool):
                return v
        except ValueError:
            pass
    low = text.lower()
    if "not logged in" in low or "please run /login" in low:
        return False
    if name == "codex" and code == 0 and "logged in" in low:
        return True
    return None


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
        "agent_cli": agent_clis(),
        "todo": [],
    }
    for name, a in report["agent_cli"].items():
        if a["path"] and a["logged_in"] is False:
            fix = "run `claude` in a terminal and /login" if name == "claude" else "run `codex login` in a terminal"
            report["todo"].append(f"The `{name}` CLI ({a['path']}) is not logged in, so the Blurt app can't hand recordings "
                                  f"to it for background processing: {fix}")
    if not ff:
        report["todo"].append("Install ffmpeg: " + ("brew install ffmpeg" if IS_MAC else "winget install Gyan.FFmpeg" if IS_WIN
                                                     else "sudo apt install ffmpeg"))
    if not report["asr_configured"]:
        report["todo"].append("Choose an ASR backend (see asr_recommendations) and run its setup command")
    if IS_MAC:
        report["todo"].append("Run `record.py test` once: macOS needs Screen Recording + Microphone permission for the "
                              "app hosting this agent (Terminal/iTerm/VS Code/Claude/Codex), then a restart of that app")
    if IS_WIN and ff and "ddagrab" not in run([ff, "-hide_banner", "-filters"], check=False).stdout:
        report["todo"].append("ffmpeg lacks ddagrab (needs ffmpeg ≥ 6); gdigrab will be used (fine, a bit heavier)")
    if IS_LINUX:
        import ctypes.util
        if not ctypes.util.find_library("portaudio"):
            report["todo"].append("Recording the mic needs PortAudio: sudo apt install libportaudio2")
        if os.environ.get("XDG_SESSION_TYPE") == "wayland":
            report["todo"].append("Screen recording uses X11 (x11grab): log in with an Xorg session, or record with "
                                  "another tool and hand the video over")
    if report["disk_free_gb"] < 5:
        report["todo"].append("Low disk space: recordings use ~1–2 GB per hour")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
