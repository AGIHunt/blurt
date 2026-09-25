# Speech recognition

Pipeline (all backends): ffmpeg → 16 kHz mono → Silero VAD (drops silence, typically 30–50% of a feedback
recording) → speech chunks that keep their original offsets → backend → `transcript.json`. Because chunks carry
offsets, backends without timestamps still produce usable timing (chunk-level, ≤ 20 s).

| backend | where | size | languages | notes |
|---|---|---|---|---|
| `sensevoice` (default) | local CPU, macOS/Windows/Linux | ~240 MB | zh, en, ja, ko, yue (+ code-switching) | sherpa-onnx; ~1 min audio per 2–4 s CPU |
| `mlx-whisper` | Apple Silicon GPU | 1.6 GB (large-v3-turbo) | 99 | `uv run --with mlx-whisper …` |
| `faster-whisper` | NVIDIA GPU or CPU | 0.5–1.6 GB | 99 | `uv run --with faster-whisper …`; CUDA 12 + cuDNN 9 for GPU |
| `openai` | cloud, user key | – | 99 | any OpenAI-compatible `/audio/transcriptions`: OpenAI, Groq, SiliconFlow… |
| `dashscope` | cloud, user key | – | zh-strong, multilingual | Qwen3-ASR-Flash, no native timestamps (VAD chunks cover it) |

Choosing: user speaks zh/en/ja/ko/yue → `sensevoice`. Other languages → Whisper on GPU if available, else cloud.
Weak machine / no disk / user prefers cloud → `openai` (Groq is cheapest) or `dashscope`.

Approximate cloud cost per hour of *speech* (verify on the vendor's pricing page before quoting):
Groq whisper-large-v3-turbo ≈ $0.04 · OpenAI gpt-4o-mini-transcribe ≈ $0.18 · OpenAI whisper-1 ≈ $0.36 ·
DashScope qwen3-asr-flash ≈ ¥0.8–1. A 30-minute rant usually has ~15–20 minutes of speech.

Env for cloud: `BLURT_ASR_API_KEY`, `BLURT_ASR_BASE_URL` (e.g. `https://api.groq.com/openai/v1`),
`BLURT_ASR_MODEL`; or just `GROQ_API_KEY` / `OPENAI_API_KEY` / `DASHSCOPE_API_KEY`.
`gpt-4o-*-transcribe` models return no segment timestamps; the script shortens chunks to compensate.

Models download to `~/.blurt/models` (override with `BLURT_HOME`). In mainland China set `BLURT_HF_MIRROR=1`
to prefer hf-mirror.com.

Quality tips: pass `--prompt` with product vocabulary (Whisper/API only); fix remaining errors while writing
issues using repo vocabulary and what's on screen — you are the post-processor.
