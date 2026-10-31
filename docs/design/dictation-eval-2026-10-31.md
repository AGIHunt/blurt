# Dictation eval, 2026-10-31: which recognizer and polish, for whom

The founder asked for "very good recognition, not good enough", and for three choices users can make knowingly: out of
the box, the best on this Mac, and the best with the cloud. This doc measures every local and cloud candidate we could
reach on the same audio with one scorer. It follows this morning's study (dictation-quality-2026-10-31.md), which found
the causes; this one compares the options.

Harness, references, raw outputs and logs are in `/Users/john/blurt-eval-2026-10-31/` (not in git; the rerun recipe is in §8). Every number below is from `raw/*.jsonl` through `harness/score.py`.

## 1. Summary

**The founder's speech (95 takes, 34 min, Mandarin with English terms), error per unit (a Chinese character or an
English word), lower is better:**

| Configuration | Error | Names / English terms right | Leaves the Mac |
|---|---:|---:|---|
| **Local 1.7B (30 s windows, field context, as shipped) + cloud polish with Apple's transcript as a second opinion** (DeepSeek V4.1 Flash on Model Studio) | **2.20 %** | **89 %** | the text |
| Cloud Qwen3-ASR Flash, whole take, words + field text + the same polish | 2.17 % | 89 % | audio + text |
| Local 1.7B, as shipped, no polish | 2.50 % | 79 % | nothing |
| … + local polish (Gemma 4 E2B, as shipped) | 2.68 % | 81 % | nothing |
| Local 0.6B (20 s windows, as shipped) | 3.34 % | 75 % | nothing |
| Apple Speech (macOS 26, nothing to download), streamed | 6.72 % | 45 % | nothing |
| **Cloud Qwen3-ASR Flash as the app sends it today** (pieces, 1.5×, field text) | **26.6 %** | 77 % | audio + text |

What decides it, in order:

1. **The recognizer.** Apple Speech makes 2.7× the 1.7B's errors on this speech and misses every "Blurt" and
   "Typeless". The 0.6B makes a third more than the 1.7B.
2. **The custom words.** Cloud recognizers that can't take a word list (everything through OpenRouter) spell the
   founder's names wrong however good they are otherwise: Blurt 0–3 of 9 (Qwen with the list: 8 of 9), Typeless 0–1 of
   4 (Qwen: 4 of 4). Microsoft's MAI-Transcribe-2 is as accurate as Qwen3-ASR Flash overall (2.06 vs 2.00 %) and still
   writes "不乐" for Blurt.
3. **Polish helps only when it gets evidence about the sounds.** Cloud polish given the recognizer's text alone makes
   the 1.7B's output worse (2.50 → 3.16 %); given Apple's transcript of the same audio as a second opinion it makes it
   better (→ 2.20 %, names 79 → 89 %). Local Gemma 4 E2B is slightly worse on every recognizer (+0.1 to +0.2 points).
4. **A bug, not a model limit: the app's cloud Flash path types the field's text and the word list.** On 16 of 95
   takes the shipped request (short pieces with the field text as context) came back with the text before the cursor or
   "Claude, DeepSeek, Anthropic, BA, blurt…" in it. Without the field text: 5.4 %; the whole take with it: 2.0 %. §4.1.

**Recommended defaults** (§6 has the exact configurations):

- **Out of the box:** Apple Speech for the first dictations (0 MB) while the Qwen3-ASR 0.6B downloads (1.0 GB), then
  the 0.6B. If the user adds a Model Studio (百炼) or DeepSeek key in setup, cloud polish with Apple + 0.6B as two
  transcripts.
- **Best on this Mac:** 8 GB → 0.6B, no local polish. 16 GB → 1.7B (3.1 GB RAM) with polish off or Gemma 4 E2B; 32 GB+
  → 1.7B + Gemma 4 E2B (as shipped). M1/M2 base chips: 0.6B (latency, §5).
- **Best with the cloud:** keep the 1.7B (or 0.6B) on the Mac and send only the text to cloud polish with Apple's
  transcript as a second opinion: 2.20 % (0.6B: 2.84 %), about ¥0.002 a dictation, ~0.8 s. A cloud recognizer
  (Qwen3-ASR Flash) only once the echo is fixed; MAI-Transcribe-2 for users outside China (no word list, so it needs the
  polish to spell names).

**For global users** (public speech, §3): locally, the 1.7B is as good as the cloud on English (LibriSpeech clean
1.16 %) and on Mandarin (AISHELL 1.64 %), but not on German (7.6 % vs 3.0 % for Voxtral Small) or Japanese (16 % vs
7.9 %), where Apple Speech is the better local choice for Japanese (14.1 %). In the cloud, Mistral Voxtral Small,
ElevenLabs Scribe and MAI-Transcribe-2 lead on European languages and Japanese.

**Spend:** $3.94 in total (§8). **New local models:** Fun-ASR-Nano (0.8B, Alibaba, Dec 2025) is the strongest small
local candidate: 2.84 % on the founder's takes (0.6B 3.34 %), best local on ASCEND code-switching (6.6 %), but no
German. MiMo-V2.5-ASR, Ming-3.0-asr-tiny and Cohere Transcribe weren't measured: this Mac's link gave ~1–2 MB/s and
they are 4–7 GB each (§8).

## 2. The founder's takes

### 2.1 Recognizers

95 takes (34.1 min, 5,449 units, 150 terms; median take 10.7 s, longest 153 s). "34 Lab cases" is the same score on
the 34 takes whose references were written this morning, before today's engines existed: a check that today's
references don't favour the engines that helped write them (nearly the same order; MAI-Transcribe-2, which had no part in
the references, stays level with Flash).

| Recognizer | Where | Error | Terms | 34 Lab cases | $ / audio hour |
|---|---|---:|---:|---:|---:|
| Qwen3-ASR Flash, whole take, words + field text ¹ | DashScope | **2.00 %** | 80 % | 3.19 % | 0.11 |
| Microsoft MAI-Transcribe-2 | OpenRouter | 2.06 % | 78 % | 3.15 % | 0.10 |
| Qwen3-ASR Flash, whole take, nothing else ¹ | DashScope | 2.24 % | 74 % | 3.54 % | 0.11 |
| **Qwen3-ASR 1.7B, 30 s windows + field context (shipped)** | local | **2.50 %** | 79 % | 3.30 % | — |
| Qwen3-ASR 1.7B, whole take | local | 2.57 % | 78 % | 3.34 % | — |
| Fun-ASR-Nano-2512 (mlx-audio, words as hotwords, ≤ 30 s pieces) | local | 2.84 % | 74 % | 4.09 % | — |
| ElevenLabs Scribe v2 | OpenRouter | 2.86 % | 75 % | 3.78 % | 0.22 |
| Qwen3-ASR 0.6B, whole take | local | 3.27 % | 73 % | 4.29 % | — |
| **Qwen3-ASR 0.6B, 20 s windows (shipped)** | local | **3.34 %** | 75 % | 4.60 % | — |
| OpenAI gpt-transcribe | OpenRouter | 3.36 % | 74 % | 4.21 % | 0.28 |
| Mistral Voxtral Small Transcribe 3 | OpenRouter | 3.38 % | 71 % | 4.48 % | 0.23 |
| Mistral Voxtral Mini Transcribe 3 | OpenRouter | 3.45 % | 70 % | 4.21 % | 0.20 |
| AssemblyAI Universal-3.5 Pro | OpenRouter | 4.06 % | 63 % | 5.35 % | 0.30 |
| OpenAI gpt-4o-mini-transcribe | OpenRouter | 4.24 % | 66 % | 5.00 % | 0.09 |
| SenseVoice Small, whole take | local | 5.14 % | 57 % | 7.04 % | — |
| xAI Grok STT 1.0 | OpenRouter | 5.19 % | 68 % | 7.08 % | 0.10 |
| SenseVoice Small, 10 s windows | local | 5.74 % | 52 % | 8.06 % | — |
| Google Chirp 3 | OpenRouter | 5.93 % | 65 % | 7.75 % | 0.98 |
| Apple Speech, whole take | local | 6.15 % | 51 % | 7.91 % | — |
| **Apple Speech, 10 s windows (shipped)** | local | **6.72 %** | 45 % | 8.73 % | — |
| Google Gemini 3.5 Transcribe | OpenRouter | 7.25 % | 67 % | 7.59 % | 0.26 |
| Groq Whisper large-v3-turbo / large-v3 (words as prompt) ² | Groq | 7.43 / 7.67 % | 60 / 71 % | 8.56 / 10.94 % | 0.04 / 0.11 |
| Whisper large-v3-turbo (MLX), whole take / 10 s windows | local | 8.46 / 9.12 % | 71 / 68 % | 11.92 / 12.39 % | — |
| NVIDIA Nemotron 3.5 Transcribe | OpenRouter | 9.78 % | 43 % | 8.06 % | 0.12 |
| **Qwen3-ASR Flash as the app sends it** (pieces, 1.5×, words + field text) | DashScope | **26.6 %** | 77 % | 40.3 % | 0.07 |
| Gemini 3.8 Flash as a transcriber (chat, audio in) ³ | OpenRouter | 15.3–21.1 % | — | — | 0.09 |
| Deepgram Nova-3 | OpenRouter | doesn't speak Chinese | — | — | 0.26 |

Cloud prices are OpenRouter's billed cost per audio hour; Model Studio's and Groq's are list-price estimates. ¹ Our
request: the shipped DashScope body (system message = the words, then the last 300 characters before the cursor),
1×, takes over 50 s cut at the take's own pauses into ≤ 50 s parts. ² Groq's free tier allows 20 requests a minute;
6 turbo takes never got through. ³ It stops after a few words on many takes, with or without context (reasoning can't
be turned off through OpenRouter; the direct Gemini key had hit its monthly cap). Not a usable transcriber here.

### 2.2 Names

How often the founder's own names come out right (takes with the name in the reference):

| Name | 0.6B | 1.7B | Apple | Flash (words) | MAI-2 | Scribe | gpt-transcribe | 1.7B + cloud polish (2nd) |
|---|---|---|---|---|---|---|---|---|
| Blurt (9) | 7 | 8 | 0 | 8 | 3 | 3 | 0 | 8 |
| Typeless (4) | 4 | 4 | 0 | 3 | 1 | 0 | 0 | 4 |
| DeepSeek (10) | 10 | 10 | 0 | 10 | 10 | 10 | 10 | 10 |
| Option C / T (15) | 15 | 15 | 9 | 15 | 15 | 15 | 15 | 15 |
| Whisper (2) | 1 | 0 | 0 | 0 | 1 | 0 | 1 | 2 |

The word list is what gets a product's own name right; a better generic recognizer doesn't.

### 2.3 Polish

The same 95 takes. Polish was given what the app gives it (the words, the app's name, the field text near the cursor).
"2nd" = the transcript of a second recognizer of the same audio, as `Also heard:` with one paragraph in the system
prompt (§8; the morning study's prototype, rebuilt in `run_polish.py`). The cloud runs go through the shipped
`polish.cloud_polish` (the cloud prompt, thinking off per host, the guard); a guard refusal types the recognizer's text.

| Recognizer | Polish | Error | Terms | Median s (under load) |
|---|---|---:|---:|---:|
| 1.7B windows (2.50 %) | none | 2.50 % | 79 % | — |
| | **DeepSeek V4.1 Flash (Model Studio) + 2nd: Apple** | **2.20 %** | **89 %** | 0.77 |
| | DeepSeek Flash (deepseek.com) + 2nd: Apple | 2.46 % | 88 % | 0.81 |
| | GLM-5.3 Flash (OpenRouter) + 2nd | 2.46 % | 79 % | 6.5 |
| | MiMo-V2.6 Flash (OpenRouter) + 2nd | 2.61 % | 87 % | 4.6 |
| | Gemma 4 E2B, local (as shipped, window by window) | 2.68 % | 81 % | — |
| | Qwen3.8 Flash (Model Studio) + 2nd | 2.94 % | 89 % | 0.93 |
| | DeepSeek Flash, no 2nd | 3.01 % | 87 % | 1.2 |
| | MiniMax M3.1 Flash + 2nd | 3.08 % | 81 % | 3.3 |
| | DeepSeek V4.1 Flash (Model Studio), no 2nd | 3.16 % | 86 % | 0.85 |
| | Kimi K3 (OpenRouter, always thinks) + 2nd | 3.25 % | 83 % | 6.2 |
| | Qwen3.8 Flash, no 2nd | 3.29 % | 87 % | 2.2 |
| | Qwen3.8 27B + 2nd (the founder's current setting) | 3.30 % | 85 % | 1.2 |
| | Gemini 3.8 Flash (OpenRouter) + 2nd | 3.34 % | 82 % | 7.1 |
| | Seed 2.1 Turbo (OpenRouter) + 2nd | 6.44 % | 84 % | 6.2 |
| Qwen3-ASR Flash, whole take (2.00 %) | DeepSeek V4.1 Flash + 2nd: Apple | 2.17 % | 89 % | 0.81 |
| MAI-Transcribe-2 (2.06 %) | DeepSeek V4.1 Flash + 2nd: Apple | 2.35 % | 88 % | 0.79 |
| 0.6B windows (3.34 %) | DeepSeek V4.1 Flash + 2nd: Apple | **2.84 %** | 86 % | 0.78 |
| | Gemma 4 E2B, local | 3.56 % | 79 % | — |
| | DeepSeek Flash, no 2nd | 3.96 % | 83 % | 1.3 |
| Apple windows (6.72 %) | DeepSeek Flash + 2nd: 0.6B | 3.08 % | 86 % | 0.82 |
| | DeepSeek V4.1 Flash, no 2nd | 6.61 % | 82 % | 0.88 |
| | Gemma 4 E2B, local | 6.86 % | 66 % | — |
| SenseVoice windows (5.74 %) | DeepSeek V4.1 Flash + 2nd: Apple | 4.29 % | 82 % | 0.83 |

Reading it:

- **The second transcript is what makes cloud polish work.** Without it every cloud model made the 1.7B's text worse
  (it deletes repetitions the references keep, and guesses names from the context); with it the best one improved it.
  On Apple's text alone polish recovers almost nothing (6.72 → 6.61 %); with the 0.6B's as the second opinion, 3.08 %.
- **Which model:** DeepSeek V4.1 Flash on Model Studio and DeepSeek's own API are the two best and fastest; Qwen3.8 27B
  (the founder's polish setting today) is worse than no polish on the 1.7B. Models that think (Kimi K3, Gemini 3.8
  through OpenRouter) or route through OpenRouter take 5–7 s, too slow for dictation.
- **Seed 2.1 Turbo** rewrote freely (6.4 %); **MiniMax M3.1 Flash** returned empty answers (thinking) on ~10 % of takes.
- **Gemma 4 E2B** is within 0.2 points on every recognizer: it fixes a few names (terms +2) and costs as many words. The
  error measure doesn't credit what Light is for (fillers, punctuation): treat it as neutral on words.
- References keep repetitions and restarts ("我的用，我用的时候"); polish removes them on purpose. Part of every polish
  row's error is that, so the improvements above are understated.

## 3. Public speech (global users)

A few hundred utterances from public sets, through the same scorer (CER for Chinese and Japanese, WER for English and
German, a mixed unit error for ASCEND). Whole utterances; Apple Speech given the set's language (a user's Mac would be
set to it), every other engine on automatic language as dictation runs. Takes picked at random offsets, at most 5 in a
row (more speakers). 50–60 utterances per set: differences under ~0.5 points (English) / ~1 point (others) are noise.

| Engine | LibriSpeech clean (en) | LibriSpeech other (en) | AISHELL-1 (zh) | ASCEND (zh-en mixed) | Common Voice ja | Common Voice de |
|---|---:|---:|---:|---:|---:|---:|
| **Qwen3-ASR 1.7B** (local) | 1.16 | 2.47 | **1.64** | 7.50 | 16.02 | 7.58 |
| Qwen3-ASR 0.6B (local) | 1.54 | 3.93 | 3.17 | 8.86 | 20.15 | 9.31 |
| Fun-ASR-Nano (local) | 1.62 | 3.70 | 2.46 | **6.59** | 16.02 | no German |
| Apple Speech (local, language set) | 1.54 | 2.92 | 4.34 | 13.07 | **14.08** | 8.44 |
| SenseVoice Small (local) | 2.39 | 5.84 | 4.34 | 9.09 | 17.80 | no German |
| Whisper large-v3-turbo (local) | 1.70 | 2.81 | 6.21 | 16.25 | 15.61 | 8.01 |
| Qwen3-ASR Flash (cloud) | 1.47 | **1.91** | **1.52** | 7.27 | 12.22 | 3.68 |
| MAI-Transcribe-2 | 1.16 | 2.47 | 2.34 | **5.68** | 10.28 | 3.90 |
| ElevenLabs Scribe v2 | 1.08 | 2.47 | 1.64 | 7.16 | 9.95 | 3.46 |
| Mistral Voxtral Small 3 | **0.85** | 2.58 | 3.52 | 10.11 | **7.93** | **3.03** |
| Mistral Voxtral Mini 3 | 1.08 | 2.47 | 4.81 | 10.45 | 10.52 | 5.19 |
| OpenAI gpt-transcribe | 1.47 | 3.48 | 3.05 | 11.48 | 11.33 | 4.76 |
| AssemblyAI Universal-3.5 Pro | 1.23 | 2.58 | 3.17 | 8.07 | 12.22 | 3.68 |
| xAI Grok STT | 1.47 | 4.04 | 5.74 | 10.23 | 8.90 | 6.28 |
| Deepgram Nova-3 | 1.85 | 4.38 | — | — | 15.53 | 10.82 |
| Groq Whisper large-v3-turbo | 1.31 | 3.14 | 6.03 (32 of 60) | — | — | — |

Sizes: LibriSpeech clean 50 utterances / 7.7 min, other 50 / 5.2, AISHELL-1 test 60 / 4.8, ASCEND test 60 / 4.5 (only
"mixed" utterances of 2–15 s), Common Voice 17 ja 50 / 4.4, de 50 / 4.9. Japanese CER is high for every engine: Common
Voice's references mix kanji and kana spellings the engines write differently; read the order, not the level.

English words inside Chinese (ASCEND, 80 English words): MAI-2 82 %, Fun-ASR-Nano 81 %, Scribe 84 %, Flash 76 %,
1.7B 75 %, 0.6B 69 %, SenseVoice 48 %, Apple 44 %.

## 4. Findings to act on

### 4.1 The cloud Qwen3-ASR Flash path echoes the field and the word list (bug)

Replaying the app's own cloud path through the Lab (`asr=qwen3-asr-flash,mode=windows,rehear=off`: the take's pieces,
the shipped `transcribe.py` DashScope backend at the default 1.5× speed, the words and the field text before the cursor
as context) gave 26.6 % against 2.0 % for the same service on the whole take:

- 13 of 95 takes typed part of the field's text before the cursor; 3 typed the word list ("Claude, DeepSeek,
  Anthropic, BA, blurt, bug-agent, …").
- On the 27 takes run all three ways: 34.8 % as shipped, 26.2 % at 1× (speed isn't the cause), **5.4 % without the field
  text** (pieces at 1.5× and the words: still twice the whole take's 1.5 % on those takes).
- The MLX backend has the echo net (`echoes_prior`: decode again without the context); the DashScope backend has none,
  and a short piece gives the model little speech and a lot of context to repeat.

Fix before offering Flash as a dictation recognizer: send it the field text only with the whole recording (or not at
all), add the echo net to the DashScope backend, and consider not cutting it into pieces (each piece is billed anyway;
one whole-take request at key-up was 2.0 %).

### 4.2 Polish needs a second transcript; ship it with the cloud polish

Apple Speech runs on every Mac with macOS 26 at no cost, in-process. Sending its transcript of the same window as
`Also heard:` turned cloud polish from harmful (2.50 → 3.16 %) to helpful (→ 2.20 %) on the 1.7B, and from useless to
the biggest single gain on Apple's own text when the 0.6B is the second opinion (6.72 → 3.08 %). Cost: one more line in
the request (~100 tokens).

### 4.3 The founder's polish setting

`record.cloud.jobs.polish` is Model Studio `qwen3.8-27b`: 3.30 % on the 1.7B's text, worse than no polish (2.50 %).
DeepSeek V4.1 Flash on the same Model Studio key: 2.20 % with the second transcript, 0.8 s.

### 4.4 Fun-ASR-Nano is worth integrating as the mid-size local model

0.8B (1.66 GB MLX, 2.1 GB peak GPU memory, mlx-audio 0.6.3 `mlx-community/Fun-ASR-Nano-2512`; a sherpa-onnx int8 export
exists for CPU): 2.84 % on the founder's takes against the 0.6B's 3.34 %, best local on ASCEND, takes hotwords. It is
whole-utterance only here (≤ 30 s pieces at the take's cuts, no hearing again), zh / en / ja only.

### 4.5 Not usable as measured

Deepgram Nova-3 (no Chinese), Gemini 3.8 Flash through OpenRouter as a transcriber (truncates), Seed 2.1 Turbo as polish
(rewrites), MiniMax M3.1 Flash as polish (empty answers while thinking), Groq's free tier for dictation (20 requests a
minute), and the newer Model Studio speech models `qwen-audio-3.0-asr-flash` / `fun-asr-flash-2026-06-15` (the
compatible-mode chat endpoint refused inline audio: "format is empty").

## 5. Latency after key-up

Measured last, one engine at a time, nothing else of the eval running, on the M5 Max (128 GB, 40-core GPU), with Blurt's
own servers idle. 12 takes of 4–7 s and 6 of 50–70 s. Local rows replay the app's pipeline (the take's cuts, warm
server, second run counted): what is left at key-up is the last piece or open window heard again, plus its polish
window. Cloud recognizers: the whole take in one request (a service the app doesn't stream to). Cloud polish: one request
on the 1.7B's text with Apple's as the second transcript. From Beijing; `raw/latency.jsonl`.

| Engine | ~5 s takes, p50 / p90 | ~60 s takes, p50 / p90 |
|---|---:|---:|
| Qwen3-ASR 1.7B, 30 s windows | 0.16 / 0.20 s | 0.32 / 0.59 s |
| … + Gemma 4 E2B | 0.26 / 0.35 s | 0.66 / 1.03 s |
| Qwen3-ASR 0.6B, 20 s windows | 0.12 / 0.15 s | 0.20 / 0.36 s |
| … + Gemma 4 E2B | 0.22 / 0.31 s | 0.45 / 0.70 s |
| Apple Speech, 10 s windows | 0.17 / 0.18 s | 0.19 / 0.21 s |
| SenseVoice Small, 10 s windows | 0.07 / 0.08 s | 0.11 / 0.13 s |
| Whisper large-v3-turbo (MLX), 10 s windows | 0.32 / 0.60 s | 0.36 / 0.60 s |
| Fun-ASR-Nano (mlx-audio), the last ≤ 30 s piece | 0.08 / 0.10 s | 0.14 / 0.22 s |
| Qwen3-ASR Flash (Model Studio, direct) | 0.52 / 0.57 s | 1.47 / 1.74 s |
| MAI-Transcribe-2 (OpenRouter) | 3.49 / 3.76 s | 4.65 / 4.93 s |
| ElevenLabs Scribe v2 (OpenRouter) | 3.66 / 3.73 s | 5.37 / 5.61 s |
| OpenAI gpt-transcribe (OpenRouter) | 3.72 / 3.80 s | 6.00 / 6.29 s |
| Voxtral Mini 3 (OpenRouter) | 3.82 / 3.88 s | 5.47 / 5.82 s |
| Groq Whisper large-v3-turbo | 3.76 / 3.77 s | 6.38 / 7.64 s |
| Polish: DeepSeek V4.1 Flash (Model Studio) | 0.78 / 1.05 s | 1.13 / 1.33 s |
| Polish: DeepSeek Flash (deepseek.com) | 0.86 / 0.96 s | 1.15 / 1.24 s |
| Polish: Qwen3.8 Flash (Model Studio) | 0.81 / 0.94 s | 1.73 / 1.98 s |
| Polish: MiMo-V2.6 Flash (OpenRouter) | 2.56 / 2.75 s | 2.58 / 2.61 s |

- Locally everything is under a second; the 1.7B with Gemma is the slowest useful one (0.66 s median on a minute-long
  take). Cloud polish adds 0.8–1.1 s (direct APIs). So the recommended cloud option A is ~1–1.4 s after key-up.
- Every recognizer reached through OpenRouter took 3.5 s even for a 5 s clip (its relay, not the models): fine for
  accuracy comparisons, too slow for dictation. A direct key (Azure for MAI, ElevenLabs, Mistral) would be needed.
- A whole-take cloud request grows with the take (Flash 0.5 → 1.5 s); streaming pieces would hide it, but §4.1 must be
  fixed first.

## 6. The three tiers

Configurations are Blurt settings (`record.dictation.*`, `asr_models.json`). Accuracy numbers are the founder's takes
(§2) and, for other languages, §3.

### 6.1 Out of the box

| | Setting | Founder's takes | Download | Memory | Leaves the Mac |
|---|---|---:|---:|---:|---|
| First minutes | `asr_model` apple-speech (macOS 26), polish off | 6.72 % | 0 | ~0 | nothing |
| After the background download | qwen3-asr-0.6b-mlx, 20 s windows, polish off | 3.34 % | 1.0 GB | 2.1 GB | nothing |
| With a key added in setup (DeepSeek or Model Studio) | the above + cloud polish (DeepSeek V4.1 Flash, thinking off) with Apple's transcript as `Also heard` | 2.84 % (Apple alone: 3.08 % with 0.6B as the 2nd) | 1.0 GB | 2.1 GB | text of each dictation |

Apple Speech alone is not "very good" for Chinese + English (Blurt 0/9, 45 % of terms): the 0.6B download should start
at install, and Settings should say it's coming. For English-only users Apple Speech is fine (LibriSpeech 1.5 %); for
Japanese it is the best local engine measured.

### 6.2 Best on this Mac (local only)

| Mac | Recognizer | Polish | Founder's takes | Download | Memory (recognizer + polish) |
|---|---|---|---:|---:|---:|
| 8 GB (light) | Qwen3-ASR 0.6B, 20 s windows | off (Gemma 4 E2B doesn't fit beside it) | 3.34 % | 1.0 GB | 2.1 GB |
| 16 GB (standard) | **Qwen3-ASR 1.7B, 30 s windows, field context** | off, or Gemma 4 E2B for fillers / punctuation (±0.2 points) | 2.50 % (2.68 % with Gemma) | 2.5 GB (+3.4 GB) | 3.1 GB (+3.4 GB) |
| 32 GB+ (pro) | Qwen3-ASR 1.7B, 30 s windows, field context | Gemma 4 E2B (as shipped) | 2.68 % | 5.9 GB | 6.5 GB |
| M1 / M2 base chips, any RAM | Qwen3-ASR 0.6B, 20 s windows | as above | 3.34 % | 1.0 GB | 2.1 GB |

- Today the standard tier gets the 0.6B (v1.0.6 default): the 1.7B is 25 % fewer errors and fits 16 GB with room.
- M1 vs M3/M4: latency was measured on an M5 Max only (§5). The 1.7B's work at key-up is the last 30 s window; on a
  base M1 / M2 (7–10 GPU cores against 40) expect roughly 4× the M5 Max's time, i.e. over a second on long takes. Pick
  by measured speed (`transcribe.py bench` already records `rtf` per Mac), not by chip name: 1.7B when its rtf ≤ ~0.05.
- Global users: Qwen 1.7B for English and Chinese; Apple Speech for Japanese (14.1 vs 16.0 %); for German the 1.7B
  and Apple are close (7.6 / 8.4 %) and both far behind the cloud (3.0 %).
- Not measured (download speed): a bigger local polish (Qwen3.5 4B, Gemma 4 E4B), and the 4–7 GB local recognizers
  (MiMo-V2.5-ASR 8B, Ming-3.0-asr-tiny, Cohere Transcribe 2B).

### 6.3 Best with the cloud

| Option | Recognizer | Polish | Founder's takes | Cost | Leaves the Mac |
|---|---|---|---:|---|---|
| **A (recommended)** | local 1.7B (or 0.6B), as §6.2 | DeepSeek V4.1 Flash on Model Studio (or deepseek.com), thinking off, Apple's transcript as `Also heard` | **2.20 %** (0.6B: 2.84 %) | ≈ ¥0.002 / dictation (~1,500 tokens), ~¥1–3 a month | each dictation's text, the field's text near the cursor, the word list — to Alibaba Cloud or DeepSeek |
| B | Qwen3-ASR Flash, whole take at key-up, words + field text (after the §4.1 fix) | as A | 2.17 % | $0.11 / audio hour (≈ ¥0.0003 for a 10 s dictation) + polish | the audio, the field's text and the words — to Alibaba Cloud |
| C (outside China) | MAI-Transcribe-2 (via OpenRouter or Azure) | as A, with any OpenAI-compatible host | 2.35 % | $0.10 / audio hour + polish | the audio to Microsoft (through OpenRouter), the text to the polish host |

A is as accurate as B, needs no audio upload and keeps working offline (it falls back to the local text). B is for Macs
that can't run a local model well (8 GB, Intel) and for long takes, where the cloud has no 30 s window to wait for.

## 7. What to tell users (Settings)

One relative accuracy figure, the delay, the cost and where the data goes. Accuracy as "about one mistake every N words"
(N = 1 / error, on the founder's mixed speech; the per-language line from §3):

| Choice | Accuracy (Chinese + English) | Delay after you stop | Cost | Privacy |
|---|---|---|---|---|
| macOS Speech | 1 mistake every 15 words | ~0.2 s | free | stays on this Mac |
| Qwen3-ASR 0.6B | 1 every 30 words | ~0.1–0.2 s (+0.1–0.3 s with local polish) | free (1 GB download) | stays on this Mac |
| Qwen3-ASR 1.7B | 1 every 40 words | ~0.2–0.3 s (+0.1–0.4 s with local polish) | free (2.5 GB download) | stays on this Mac |
| + cloud polish (DeepSeek) | 1 every 45 words, names right 9 of 10 | + ~0.8 s | ≈ ¥0.002 a dictation | your text goes to DeepSeek / Alibaba Cloud |
| Cloud recognizer (Qwen3-ASR Flash) | 1 every 50 words | 0.5–1.5 s | ≈ ¥0.8 an hour of speech | your voice goes to Alibaba Cloud |

## 8. Method

- **Data.** The founder's kept takes (`~/.blurt/dictation/history.jsonl`, 204 with audio). A take is in the set when
  it is one of this morning's 34 Lab cases or its typed text was found (≥ 85 %) in a message the founder then sent in
  Claude Code (`~/.claude/projects/*/*.jsonl`, user messages since 10-30); 95 takes, 34.1 min.
- **References.** The 34 Lab cases keep this morning's references. For the other 61, a separate agent wrote what was
  said from the sent text (the founder's spellings and fixes) and 8 recognizers' transcripts (two Qwen 1.7B runs, Flash,
  gpt-transcribe, Scribe, Gemini, Voxtral, Apple): content follows the audio evidence (words the founder added when
  sending are left out, words they deleted are kept), spelling follows the founder where a recognizer heard it so. 24
  spans in 20 takes are marked uncertain (`refs/founder_refs.jsonl`). The bias check is the "34 Lab cases" column.
- **Scoring** (`harness/score.py`, one scorer for every engine and set): units are Chinese / Japanese characters and
  Latin words (`dictation_lab.units`); error = Σ edits / Σ reference units. Both sides normalised alike: NFKC,
  traditional → simplified, 呃 / 嗯 / uh / um removed, 他她它 and 的得地 unified, Chinese numerals → digits (cn2an),
  spelled letters joined (A S R → ASR), 千问 = Qwen, sound tags like [鸟叫声] dropped; English sets through Whisper's
  English normaliser. Punctuation not scored. Terms = each run of Latin words in the reference plus a short list of
  Chinese names (千问, 口喷鸡, 云端润色…); right when its units appear in a row.
- **Replays.** Local engines through the snapshot of `skills/blurt/scripts` at 64eefe7f (`dictation_lab.run_case` on
  scratch servers, one scratch `BLURT_HOME` per runner): "windows" = the take's own cuts and pauses, hearing again in
  the model's window (`asr_models.json` `rehear_window_s`: 1.7B 30 s, 0.6B 20 s, others 10 s), the field text as
  context where the registry says (1.7B), polish window by window; "whole" = the whole take in one request. Cloud
  recognizers: the whole take, 1× (§2.1 note ¹), plus the app's own Flash path through the Lab. Newer local models
  through mlx-audio 0.6.3. Cloud polish through the snapshot's `polish.cloud_polish` (`harness/run_polish.py`).
- **Permissions the founder granted for this eval (2026-10-31):** keys from ordo-backend `.env.prod`
  (`DEEPSEEK_API_KEY`, `QWEN_API_KEY`, `GROQ_API_KEY`, `MINIMAX_API_KEY`, < $3 each) and `OPENROUTER_API_KEY`, plus the
  Gemini key in `~/.config/gemini/gemini.env`; loaded into the process only, never printed or written. The founder's
  takes (~18 min, here 34 min) could go to OpenAI models via OpenRouter, DashScope qwen3-asr-flash, Groq Whisper, Gemini,
  and OpenRouter's other STT vendors (ElevenLabs, AssemblyAI, Deepgram, Mistral, xAI, NVIDIA, Google, Microsoft), about
  $3 extra in total. Blurt's Keychain was not read. Two DashScope models besides qwen3-asr-flash were tried on one take
  (both refused the request). Public sets went to the same services.
- **Resources.** Work dir `/Users/john/blurt-eval-2026-10-31/` (append-only JSONL per engine × item, every runner skips
  what is recorded). Each local runner checked free memory before loading (≥ 35 %, later ≥ 25 % and up to 12 runners at
  the founder's request); never two copies of one model at once; every server started was ended. Blurt's own servers
  were not touched. Latency ran last, one engine at a time.
- **Spend: $3.94** — OpenRouter speech $2.73 (founder takes $1.83, public $0.85, latency $0.05), OpenRouter LLMs $0.28,
  Model Studio $0.56 (estimated at list price), DeepSeek $0.22 (estimated), Groq $0.12, MiniMax $0.02, Gemini $0 (key
  capped).
- **Rerun.** `harness/`: `match_refs.py` (take ↔ sent text), `run_lab.py` (local, app pipeline), `run_cloud.py`,
  `run_local_mlx.py`, `run_polish.py`, `fetch_public.py`, `latency.py` + `latency_all.sh`, `score.py`, `report.py`
  (→ `report.md`, every table above). Keys: `harness/keys.py`.

## 9. Keys worth getting

| Provider | Why | Free allowance (official pages, 2026-10) | Signup |
|---|---|---|---|
| Volcengine 豆包 Seed-ASR 2.0 | strongest Chinese candidate not measured; hotwords and dialogue context up to 800 tokens | not stated on the billing page | Volcengine account, mainland real-name verification likely |
| Tencent Cloud ASR (`16k_zh_en` large model) | zh-en code-switch engine, hotwords | 5 h / month real-time + 10 h / month files | Tencent Cloud account (real-name for mainland) |
| Speechmatics (Melia) | states zh-en code-switching | $100 credit, no card to start | email |
| Deepgram (direct) | English / European; no Chinese on Nova-3 | $200 credit, no card | email |
| AssemblyAI (direct) | keyterms (1,000) | $50, no card | email |
| ElevenLabs (direct) | keyterms, which OpenRouter can't pass | 4.5 h batch + 2.5 h real-time a month (free plan) | email |
| Soniox | context (terms + text) | no free credit for new signups since 2025-10-27 | card |
| iFlytek 讯飞 dictation LLM | zh + dialects, hotwords | not stated | mainland account |

The most useful for the founder: Volcengine Seed-ASR (the one strong Chinese engine with context we couldn't reach) and
direct ElevenLabs (Scribe v2 with keyterms: it already is 2.86 % without them).
