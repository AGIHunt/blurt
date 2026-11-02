# Windows: speech and polish models on a CPU-only PC (2026-11-02)

The question: what does Blurt run out of the box on a typical Windows PC — about ¥5,000, no discrete GPU, a recent
8-core CPU, 16 GB — and does polish need the cloud there?

## Answers

- **Windows has no built-in recogniser Blurt can use.** Win+H voice typing is not callable from other apps. The
  callable WinRT `Windows.Media.SpeechRecognition` is the old generation, and its dictation depends on Microsoft's
  online speech service. Blurt brings its own model, as on Linux.
- **Speech runs locally on the CPU** (sherpa-onnx int8, the backend `transcribe.py` already uses on every OS):
  - **Fun-ASR-Nano int8** is the accurate default for people who speak zh / en / ja, and the slower one.
  - **SenseVoice** is the fast one: the first-minutes model and the model for weak machines.
  - **Qwen3-ASR 0.6B int8** covers the other languages.
- **Polish is cloud-only on Windows.** No local LLM: on the Mac, local polish was already neutral on words on weaker
  machines (dictation.md §Defaults by Mac, ±0.2 points) and blind judges gave it 4.2 / 10 against DeepSeek Flash's 7.2.
  A CPU only adds seconds to that. Without a cloud key, dictation types the recogniser's text (both models write
  punctuation).

## Speed on the CPU

**Machine:** Alibaba Cloud ecs.c8ae.4xlarge in Hangzhou, Windows Server 2025 24H2 (build 26100, Windows 11's
kernel). It has an AMD EPYC 9T34 (Zen 4) with 8 cores / 16 threads and 32 GB. That's comparable to a Ryzen 7
8845H-class laptop: the laptop boosts higher but throttles under sustained load.

**Setup:** sherpa-onnx 1.13.8 on Python 3.12. Clips are cut from AISHELL / ASCEND / LibriSpeech, 6 per length. The
time measured is one window's decode, warm.

| Model | Threads | 5 s | 10 s | 20 s | RTF | Memory |
|---|---:|---:|---:|---:|---:|---:|
| Fun-ASR-Nano int8 | 4 | 0.60 s | 1.12 s | 2.38 s (one 6.2 s) | 0.12 | 2.4 GB |
| Fun-ASR-Nano int8 | 8 | 0.56 s | 1.08 s | 2.32 s | 0.11 | 2.4 GB |
| Qwen3-ASR 0.6B int8 | 4 | 0.82 s | 1.49 s | 3.42 s | 0.16 | 3.1 GB |
| SenseVoice int8 | 4 | 0.12 s | 0.23 s | 0.45 s | 0.023 | 0.46 GB |
| SenseVoice int8 | 8 | 0.08 s | 0.16 s | 0.29 s | 0.016 | 0.46 GB |

- **Threads.** Fun-ASR-Nano is an LLM decoder (Qwen3-0.6B), so 8 threads buy almost nothing over 4. Use 4.
- **Wait after key-up.** The wait is the decode of the last piece not yet heard. With pieces of 3–10 s, that's
  0.4–1.1 s for Fun-ASR-Nano and 0.1–0.25 s for SenseVoice. On an M5 Max with MLX, Fun-ASR-Nano takes 0.07–0.17 s
  (dictation.md §Fun-ASR-Nano).
- **Hearing again while the user talks.** Each 10–20 s re-decode keeps about half a core busy (RTF 0.12 × 4 threads).
- **Qwen3-ASR 0.6B int8 is a third slower than Fun-ASR-Nano** (RTF 0.16 against 0.12, the same with 8 threads), and it
  handles 30 s windows. It isn't on hf-mirror or ModelScope under its release name, so the VM got it from the Mac.

## Accuracy of the int8 ONNX builds

**The founder's 95 takes** (the 2026-10-31 eval's hand-written references; audio from the
`~/Blurt-backup-2026-10-31` copy, `EVAL_DICTATION` in the harness). Each take is cut at its own pauses into pieces of
at most 20 s (10 s for SenseVoice), and the custom words go in as hotwords. The ONNX models ran on the Mac's CPU, with
the same weights as on Windows.

| Recogniser | Error | Names / terms |
|---|---:|---:|
| Qwen3-ASR 0.6B int8 (CPU) | **3.51 %** | 71 % |
| Fun-ASR-Nano int8 (CPU) | 3.69 % | 69 % |
| SenseVoice int8 (CPU) | 5.21 % | 55 % |
| *Mac, for reference:* Fun-ASR-Nano MLX, 20 s windows | 2.94 % | 76 % |
| *Mac:* Qwen3-ASR 0.6B MLX, 20 s windows | 3.34 % | 75 % |

On the founder's own speech the two CPU LLM recognisers are level: 0.18 points apart, which is within the spread of
one take. The public sets below favour Fun-ASR-Nano in Chinese and mixed speech. Fun-ASR-Nano stays the default for
zh / en / ja speakers. Qwen3-ASR 0.6B is the default for every other language and is offered to everyone.

**Public sets:** the eval's public sets and scorer, also run on the Mac's CPU.

| Set (error %) | Fun-ASR-Nano int8 | Fun-ASR-Nano MLX | Qwen3-ASR 0.6B int8 | Qwen3-ASR 0.6B MLX | SenseVoice int8 |
|---|---:|---:|---:|---:|---:|
| AISHELL-1 | **2.11** | 2.46 | 4.10 | 3.17 | 4.34 |
| ASCEND (zh-en mixed) | 7.39 | **6.59** | 9.43 | 8.86 | 8.98 |
| LibriSpeech clean | 13.89* | 1.62 | **1.39** | 1.54 | 2.31 |
| LibriSpeech other | **3.70** | 3.70 | 4.49 | 3.93 | 5.95 |

\* **The 512-token cap.** The sherpa-onnx export caps prompt + audio at 512 tokens. That is about 25 s of audio
without hotwords, and less with them. Two 28–30 s clips came back empty or cut short, and every 30 s VM clip came
back empty. Without those two clips the set is at the MLX build's level. So on Windows, Fun-ASR-Nano windows are at
most 20 s (`rehear_window_s` 20; the Mac's MLX build uses 30) and the Words list stays short. The alternative is a
re-export with a larger `max_total_len`, from Wasser1462/FunASR-nano-onnx.

The int8 Fun-ASR-Nano matches its MLX build. On the founder's takes the MLX build measured 2.92 %, against 5.74 % for
SenseVoice (dictation.md §Defaults by Mac). It is the best CPU model for Chinese and mixed speech. The int8 Qwen3-ASR
0.6B is worse than its MLX build in Chinese.

## Windows defaults (implemented: `transcribe.cpu_recognizer`)

| PC | Recogniser | Polish |
|---|---|---|
| first minutes, while the recogniser downloads | SenseVoice (228 MB) | cloud if a key is set |
| ≥ 8 GB and ≥ 4 cores, speaks only zh / en / ja | Fun-ASR-Nano int8 (950 MB, 20 s windows, 4 threads) | cloud if a key is set, else none |
| any other language | Qwen3-ASR 0.6B int8 (940 MB) | as above |
| < 8 GB or ≤ 2 cores | SenseVoice | as above |

## Downloads from mainland China

- From the Hangzhou VM, GitHub release downloads failed.
- ModelScope mirrors only Fun-ASR-Nano (`csukuangfj/asr-models`).
- hf-mirror has SenseVoice but not the Qwen3-ASR int8 release.
- Python came from npmmirror and packages from mirrors.aliyun.com.

So the Windows app's model downloads need a mirror Blurt controls for Qwen3-ASR, or Qwen3-ASR stays unavailable from
mainland China.

Scripts and raw rows: `/Users/john/blurt-eval-2026-10-31/win/` (`bench_onnx.py`, `speed_out.jsonl`) and
`raw/{aishell,ascend,ls-clean,ls-other}.jsonl` (engines `onnx-fun`, `onnx-q06`, `onnx-sv`), not in git.
