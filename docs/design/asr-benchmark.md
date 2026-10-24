# Local speech recognition: benchmark and per-machine choice

2026-10-22, for K9 in `next-round.md`. The results decide which model `transcribe.py recommend` picks for each kind of
machine, and they supply the reference numbers in `skills/blurt/scripts/asr_models.json` (`rtf_ref`, `ram_mb`,
`error_ref`). The Settings → Speech pane shows those numbers until the user measures the models on their own Mac.

## Method

- **Machine:** Apple M5 Max, 128 GB unified memory, 40-core GPU, 18 CPU cores (6 Super and 12 Performance), macOS 26.
  Other build agents were running at the same time, so treat speeds as ±20 %. Accuracy is deterministic.
- **Speech:** generated with macOS `say` in seven languages: zh, en, ja, ko, es, fr and de. Each language has seven
  product-feedback sentences (sign-in fails, a pale button, a dropdown, an export idea, a deadline), separated by
  0.9 s pauses. Each language is spoken by two voices, for example Tingting and the Eddy voice for Chinese, or
  Samantha and Daniel for English. That gives 14 files and 9.5 minutes of audio. The scripts are the `bench` samples
  in `asr_models.json`.
  Synthetic speech is cleaner than a real microphone, so absolute error rates are optimistic. The ranking is what
  matters here.
- **Pipeline:** Blurt's own path (`transcribe.py`): Silero VAD, then chunks of at most 30 s (10 s for SenseVoice),
  then the backend. The chunk outputs are joined and compared with the script.
- **Error rate:** CER for zh, ja and ko; WER for es, fr, de and en. Text is NFKC-normalised, lower-cased, and
  punctuation is dropped (`transcribe.error_rate`).
- **Resource caps on every run:** `asr.limits` defaults, meaning 3 threads, `taskpolicy -c utility` with nice 10
  (batch priority), and an MLX memory cap at 25 % of RAM. A warm-up chunk is not timed.
- **Measures:**
  - RTF is decode time divided by audio length.
  - Peak RAM is the process's lifetime-maximum physical footprint, which on Apple Silicon includes GPU buffers.
  - "MLX GPU" is `mx.get_peak_memory()`.
  - CPU is CPU-seconds per wall-second while decoding.
  - GPU is mean `Device Utilization %` from IOAccelerator, sampled every 200 ms. It is system-wide, so it includes
    other apps.

The harness is a scratch script that calls `transcribe.py`'s functions. The product command is
`transcribe.py bench --model-id ID [--languages …]`. It measures the same quantities on one voice per language and
stores them in `$BLURT_HOME/asr-bench.json`.

## Results

Error rate in %, lower is better. "fails" means the model doesn't speak the language: it returns noise or English
words.

| model | zh | en | ja | ko | es | fr | de | RTF | peak RAM GB | MLX GPU GB | CPU cores | GPU % | load s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Whisper large-v3-turbo (MLX fp16)** | 1.6 | 1.9 | 0.8 | 0.5 | 0.5 | 1.2 | 0.5 | 0.022 | 3.59 | 2.39 | 0.6 | 86 | 2.6* |
| **Whisper large-v3-turbo 4-bit (MLX)** | 3.3 | 1.9 | 1.5 | 0.8 | 0.0 | 1.7 | 1.1 | 0.025 | 2.51 | 1.25 | 0.6 | 89 | 3.5 |
| **SenseVoice Small (sherpa-onnx int8, CPU)** | 3.3 | 2.4 | 1.7 | 10.5 | fails | fails | fails | 0.026 | 0.53 | – | 2.3 | 7 | 0.5 |
| **Qwen3-ASR 0.6B int8 (sherpa-onnx, CPU)** | 4.2 | 1.0 | 5.3 | 13.3 | 6.8 | 15.0 | 7.4 | 0.254 | 2.51 | – | 2.2 | 21 | 1.6 |
| Whisper large-v3-turbo (CTranslate2 int8, CPU) | 2.3 | 1.9 | 1.1 | 0.5 | 0.0 | 1.2 | 0.5 | 2.18 | 1.63 | – | 2.3 | 18 | 13.6 |
| Qwen3-ASR 0.6B (MLX bf16, mlx-qwen3-asr) | 1.3 | 1.9 | 5.5 | 13.5 | 3.2 | 8.8 | 4.2 | 0.043 | 3.41 | 2.92 | 1.1 | 53 | 2.0 |
| Qwen3-ASR 1.7B (MLX bf16, mlx-qwen3-asr) | 1.3 | 1.9 | 2.5 | 31.1 | 0.9 | 5.0 | 1.6 | 0.050 | 7.83 | 7.60 | 0.9 | 62 | 2.3 |
| Parakeet TDT 0.6B v3 (MLX, parakeet-mlx) | – | 2.4 | – | – | 0.5 | 4.2 | 2.7 | 0.016 | 4.56 | 2.45 | 0.7 | 44 | 1.2 |
| Whisper small (MLX) | 16.3 | 1.9 | 3.2 | 5.4 | 0.9 | 6.7 | 3.2 | 0.026 | 2.55 | 1.37 | 1.2 | 64 | 2.1 |
| Whisper medium (MLX) | 25.2 | 1.9 | 2.8 | 3.8 | 0.5 | 3.3 | 6.9 | 0.060 | 3.46 | 2.08 | 1.1 | 64 | 2.9 |
| distil-whisper large-v3 (MLX, English only) | – | 2.9 | – | – | – | – | – | 0.017 | 2.81 | 2.29 | 0.5 | 81 | 1.9 |
| FireRedASR2 CTC int8 (sherpa-onnx, CPU) | 3.3 | 12.1 | – | – | – | – | – | 0.260 | 1.46 | – | 1.6 | 20 | 0.8 |

\* The first load took 13.7 s: that run also built the uv environment and compiled the imports. Warm loads take
2.6–3.1 s.

**Bold** rows are in the registry. The others were measured and left out, for these reasons:

- **Qwen3-ASR on MLX** (0.6B and 1.7B) is slower than Whisper turbo and less accurate in ja, ko and fr. The 1.7B model
  needs 7.8 GB. With one of the two Korean voices it recognised the first chunk as Indonesian (31 % error). Its edge
  is Chinese, 1.3 % against 1.6 %, which is too small to justify a second GPU stack.
  `mlx-qwen3-asr` 0.4.4 worked without problems.
- **Parakeet TDT v3** is the fastest model (RTF 0.016), but Whisper turbo is more accurate in every language they
  share. Parakeet also uses more memory (4.6 GB) and speaks no Asian languages.
- **Whisper small and medium** mix traditional characters into Simplified Chinese ("上傳頭像"), which gives 16–25 % CER.
  The 4-bit turbo has the same footprint as small and is better everywhere.
- **distil-whisper** is English only.
- **FireRedASR2** matches SenseVoice in Chinese but has 12 % error in English, writes no punctuation, and runs
  10× slower.
- **Whisper on CTranslate2** is accurate, but on this ARM CPU with 3 threads it runs at 2.2× real time, slower than the
  audio. The registry keeps it for NVIDIA GPUs (CUDA), where CTranslate2 is fast. That case wasn't measured here.

### Threads and priority (SenseVoice, same 9.5 minutes)

| threads | priority | RTF | CPU cores busy |
|---|---|---|---|
| 3 | utility (QoS clamp + nice 10) | 0.027 | 2.3 |
| 3 | user-initiated | 0.015 | 2.5 |
| 8 | user-initiated | 0.012 | 5.8 |

With 3 threads SenseVoice reaches 80 % of the 8-thread speed while keeping 3.5 fewer cores busy. Utility QoS roughly
halves the speed when the machine is busy, and that is the point: recordings are transcribed after the user stops, so
a 10-minute recording still takes about 16 s. The same holds for Qwen3-ASR on the CPU: 8 threads give RTF 0.128
against 0.254 with 3 threads, at 5.5 busy cores instead of 2.2.

The process accounts for all of its worker threads' CPU time under `utility` (`proc_pid_rusage`). This works only
through the `taskpolicy -c utility` clamp: threads that onnxruntime or CTranslate2 start do not inherit
`pthread_set_qos_class_self_np`. `tests/test_asr_select.py` checks this.

### Voice notes (one 2–5 s note, `transcribe.py note`)

| model | cold, new process | warm, `transcribe.py serve` |
|---|---|---|
| SenseVoice | 1.0–2.0 s | 0.28–0.34 s (55–100 ms of compute) |
| Whisper turbo (MLX) | 4.6 s (63 s the very first time: building the uv environment) | 0.42–1.0 s (200–400 ms of compute) |

Starting `serve --preload` when the user begins a voice note means the model loads while they speak.

**The Chinese script (desi065).** Whisper turbo wrote a zh-Hans user's note half in traditional characters
(「登录頁面周五之前要上線，記得把按鈕顏色改深一點」, `say -v Tingting`). Whisper has no setting for the script (its
language token is `zh`), so the usual trick was tried first: an initial prompt in simplified Chinese. It fixed the
characters, but on an English note in the same run it once looped (「段段段…」 for a whole sentence) and it glued English
names to the Chinese around them, so it was dropped. Every transcript now passes `to_user_script` (in
`decode_slice`: voice notes, recordings, live captions and dictation alike): for a user whose first Chinese system
language is zh-Hans (or `asr.chinese_script: "hans"`), text heard as Chinese (or with no language tagged, and no
kana) is converted character by character with OpenCC's t2s tables (`opencc-python-reimplemented`, a pinned
dependency) — a script mapping, no meaning read. zh-Hant users (zh-TW / zh-HK / zh-MO, yue, or `"hant"`) keep what the
model wrote, Japanese is never touched. On the three test clips: all simplified, English unchanged.

### Live captions with the recordings model (pro Mac)

`live.py simulate` fed 80 s of English followed by Chinese in real time, using Whisper turbo as the live model:

- Results were ready 0.5 s after stopping.
- All 14 sentences came through, each tagged with its language.
- Because of that, `transcribe.py run` reuses the live transcript, and on a pro Mac the transcript is final when the
  recording stops.

This run also uncovered a Whisper bug, which is now fixed. When one 15 s chunk held two English sentences followed by
a Chinese one, Whisper returned only the Chinese one, as a single segment covering the whole 15 s. The fix applies to
people with more than one language in `asr.languages`. When a chunk produces too little text for its length (under
2.5 syllables per second; normal speech measured 4–7 in every language), the language of each speech segment is
detected and each language run is decoded separately. Mono-language accuracy and speed are unchanged (re-measured).
Whisper's ASCII commas in Chinese and Japanese text are converted to full-width marks.

## The choice per machine

`transcribe.py recommend` encodes the following (`preference()` in transcribe.py):

| machine | recordings | live captions | voice notes |
|---|---|---|---|
| Apple Silicon, ≥ 32 GB (pro) | Whisper turbo | Whisper turbo (the same model, so the live transcript is final) | SenseVoice¹, else Whisper turbo |
| Apple Silicon, 16–24 GB (standard) | Whisper turbo | SenseVoice¹, else Whisper turbo 4-bit³ | SenseVoice¹, else Whisper turbo 4-bit³ |
| Apple Silicon, 8 GB (light) | SenseVoice¹, else Whisper turbo 4-bit | SenseVoice¹, else turbo 4-bit | SenseVoice¹, else turbo 4-bit |
| NVIDIA ≥ 4 GB VRAM | Whisper turbo (CUDA) | SenseVoice¹, else turbo (CUDA) | SenseVoice¹, else turbo (CUDA) |
| CPU only (Windows / Linux / Intel Mac) | SenseVoice², else Qwen3-ASR 0.6B (CPU) | same | same |
| < 8 GB RAM or ≤ 2 cores (minimal) | SenseVoice on one thread; cloud recommended for other languages | same | same |

¹ When every language the user speaks is one SenseVoice handles well, meaning a reference error rate of at most 5 %:
zh, en, ja and yue. Korean is the exception at 10.5 %, against 0.5 % for Whisper.

² On a CPU, SenseVoice is 10× faster than the multilingual alternative and just as accurate in its own languages,
Korean included (Qwen3-ASR on the CPU also has 13 % error in Korean).

³ Their model stays warm next to dictation's and polish: 2.6 GB instead of 3.7 (a 442 MB download), at 3.3 % zh error
instead of 1.6 %; the full model when it is the one installed (arch098).

On battery, recordings drop one tier (`asr.on_battery`, default `lighter`). A model is considered only when its
measured peak memory fits within 40 % of RAM.

## What wasn't measured

- x86 CPUs, NVIDIA GPUs and Windows. The CUDA row and the CPU rows rely on the published behaviour of CTranslate2 and
  onnxruntime. The pane labels speeds on those machines as estimates until the user presses "Measure". Windows and
  Linux validation is planned for the VM round.
- Real microphones, noise, accents and spontaneous speech.
- Cantonese (yue). The bench text is ready (Sinji voice) but wasn't run in this round.
- Chinese dialects, where Qwen3-ASR claims 22, and languages outside the seven tested.
