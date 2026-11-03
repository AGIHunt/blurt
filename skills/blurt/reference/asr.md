# Speech recognition

Pipeline for every backend: ffmpeg → 16 kHz mono → Silero VAD (drops silence, typically 30–50 % of a feedback
recording) → speech chunks that keep their original offsets → model → `transcript.json`. Each segment carries the
`language` the model heard when it reports one, and the document lists the `languages` it found. Because chunks carry
offsets, backends without timestamps still produce usable timing (chunk-level, ≤ 30 s).

## Which model: chosen for the machine

`transcribe.py` picks a model for each job, based on the hardware tier and the languages the user speaks
(`asr.languages`, default: the system's preferred languages plus English):

- **recordings** (`batch`) — accuracy first;
- **live captions** (`live`) — while recording;
- **voice notes** (`note`) — latency first.

| machine (`transcribe.py probe` → tier) | recordings | live / voice notes |
|---|---|---|
| Apple Silicon ≥ 32 GB (pro) | Whisper large-v3-turbo (MLX) | live: the same model; notes: SenseVoice¹ |
| Apple Silicon 16–24 GB (standard) | Whisper large-v3-turbo (MLX) | SenseVoice¹, else Whisper turbo |
| Apple Silicon 8 GB (light) | SenseVoice¹, else Whisper turbo 4-bit | SenseVoice¹, else turbo 4-bit |
| NVIDIA GPU | Whisper large-v3-turbo (CTranslate2, CUDA) | SenseVoice¹, else the same |
| CPU only | SenseVoice, else Qwen3-ASR 0.6B (CPU) | same |
| < 8 GB / ≤ 2 cores (minimal) | SenseVoice on one thread; cloud for other languages | same |

¹ when all the user's languages are zh / en / ja / yue (SenseVoice is weak in Korean: 10 % error vs 0.5 %).

Measured accuracy and speed per model and language: `docs/design/asr-benchmark.md`. Only installed models are used. A
recommended model that isn't installed is listed by `transcribe.py auto` under `needs_download`. Ask the user first,
saying the size and what it improves, then run `transcribe.py setup --model-id ID`.

```
transcribe.py probe                         hardware, tier, limits
transcribe.py recommend --languages de,en   pick + candidates (size, memory, est. speed, installed, fits)
transcribe.py auto [--apply]                per-job pick for this machine; --apply writes asr.models
transcribe.py models                        registry + installed + measured + selected (the Settings pane's data)
transcribe.py setup --model-id ID           download (progress "  N/M MB" on stderr); --use all|batch,live,note selects it
transcribe.py bench --model-id ID           measure on this machine: accuracy per language (macOS `say` samples),
                                            RTF, peak memory, CPU / GPU load → $BLURT_HOME/asr-bench.json
transcribe.py note WAV                      one voice note → {"ok","text","language","ms","model"}
transcribe.py serve --preload               keep the voice-note model warm (unloads after 5 idle minutes)
```

Each command prints one JSON line. On failure it prints `{"ok": false, "error", "code"}` and exits with 1, with 3 when
it timed out waiting for the ASR slot, or with 4 when a package is missing.

Models (`scripts/asr_models.json`):

| id | runs on | size | languages |
|---|---|---|---|
| `sensevoice-small` | any CPU (sherpa-onnx) | 230 MB | zh, en, ja, ko, yue |
| `whisper-large-v3-turbo-mlx` | Apple Silicon GPU | 1.5 GB | 99 |
| `whisper-large-v3-turbo-q4-mlx` | Apple Silicon GPU | 0.45 GB | 99 |
| `whisper-large-v3-turbo-ct2` | NVIDIA CUDA (CPU works but is slow) | 1.5 GB | 99 |
| `qwen3-asr-0.6b-onnx` | any CPU (sherpa-onnx) | 0.9 GB | 30 |
| `openai-compatible` / `qwen3-asr-flash` | cloud, user's key | – | many |

Packages are added automatically: the script re-runs itself with `uv run --with mlx-whisper` (or `faster-whisper`)
when it needs one. Whisper weights live in the Hugging Face cache (`HF_HOME`). SenseVoice, Qwen3-ASR and the VAD go
to `$BLURT_HOME/models`. In mainland China, set `BLURT_HF_MIRROR=1` to prefer hf-mirror.com.

## Configuration (`$BLURT_HOME/config.json` → `asr`)

- `auto` (default true): the pick follows the machine. The app re-applies it when the hardware changes.
  - `false`: use `models: {"batch","live","note"}` as chosen.
  - An older config's explicit `backend` / `model` (anything but SenseVoice) counts as a manual choice.
- `languages`: what the user speaks, used to choose models. `language` forces recognition to one language (default:
  detect).
- `limits`:
  - `threads`: default `max(1, min(4, perf_cores // 2))`.
  - `max_concurrent`: default 1. Recordings past that queue, via `$BLURT_HOME/run/asr.lock`; under `$BLURT_JOB` the
    job gets `asr.queued` and `asr.started` events.
  - `priority`: recordings at utility (on macOS: `taskpolicy -c utility` + nice 10); live captions and voice notes at
    user-initiated.
  - `max_memory_fraction`: default 0.25, the cap on MLX memory.
- `on_battery`: `lighter` (default) drops recordings to the next lighter tier on battery; `same` keeps the tier.
- `privacy.local_asr: true` refuses cloud backends.

## Cloud

Choose cloud when the machine is minimal, when the user prefers it, or for a language no local model handles well.
Approximate cost per hour of *speech* (check the vendor's pricing page before quoting):

- Groq whisper-large-v3-turbo: about $0.04
- OpenAI gpt-4o-mini-transcribe: about $0.18
- OpenAI whisper-1: about $0.36
- DashScope qwen3-asr-flash: about ¥0.8–1

A 30-minute rant usually has 15–20 minutes of speech.

In the app: Settings → Models → Advanced → each cloud service → Set Up… (the key goes into the Keychain; the app hands
it to the scripts it starts as the variables below, over the shell's). From a terminal, keys come from the environment:

- `BLURT_ASR_API_KEY`
- `BLURT_ASR_BASE_URL` (for example `https://api.groq.com/openai/v1`)
- `BLURT_ASR_MODEL`
- or simply `GROQ_API_KEY`, `OPENAI_API_KEY` or `DASHSCOPE_API_KEY` (`DASHSCOPE_BASE_URL` for another region)

`gpt-4o-*-transcribe` returns no segment timestamps; the script shortens chunks to compensate.

## Quality tips

- Pass `--prompt` with product vocabulary (Whisper and API backends).
- Fix the remaining errors while writing items, using the repo's vocabulary and what's on screen: you are the
  post-processor.
- A `warning` in transcript.json means SenseVoice heard a language it doesn't speak. Re-run with
  `--model-id whisper-large-v3-turbo-mlx` (or the `recommend` pick) and `--language`.
