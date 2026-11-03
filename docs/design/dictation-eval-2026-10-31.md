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

**Added in the afternoon: five providers reached directly** (§8 has the setup). None beats the best above on the
founder's speech:

- ElevenLabs Scribe v2 direct with the word list as keyterms: 2.17 %. That is level with Flash (2.00 %) and MAI-2 (2.06 %),
  down from 2.86 % without the list (through OpenRouter), and Blurt comes out right 8 of 9 times.
- Volcengine 豆包 Seed-ASR 2.0, streamed (`bigmodel_nostream`): 2.18 %. Its word list barely works (Blurt 3 of 9).
- AssemblyAI Universal-3.5 Pro direct: 4.02 %. Tencent's free general engine: 4.42 % (the `16k_zh_en` large model
  needs a paid resource pack). Speechmatics `cmn_en`: 7.01 %.

Volcengine is the one with a dictation-grade delay: 0.45 s after key-up on short takes and 0.52 s on minute-long ones,
streamed from this Mac in China, at ¥1 an hour. It is a candidate for option B once its names are fixed by polish
(§6.3). ElevenLabs direct is the more accurate on names but takes 3.6–5.1 s as a batch request from China. Its realtime
model is fast (0.5 s) but makes 4.90 % errors.

**Spend:** $3.94 in total in the morning (§8), plus the afternoon's free trials and credits. **New local models:** Fun-ASR-Nano (0.8B, Alibaba, Dec 2025) is the strongest small
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
| *ElevenLabs Scribe v2, direct, words as keyterms* ⁴ | ElevenLabs | 2.17 % | 83 % | 2.87 % | 0.26 |
| *Volcengine Seed-ASR 2.0, streamed (`bigmodel_nostream`), words as hotwords + field text as dialog context* ⁴ | Volcengine | 2.18 % | 79 % | 3.34 % | 0.14 (¥1) |
| *… the same, words also as a context line* | Volcengine | 2.29 % | 79 % | 3.58 % | 0.14 |
| *… the same, no words, no field text* | Volcengine | 2.33 % | 75 % | 3.50 % | 0.14 |
| *Volcengine Seed-ASR 2.0, file API (`volc.seedasr.auc`), words + field text* | Volcengine | 2.33 % | 77 % | 3.62 % | 0.11 (¥0.8) |
| *Volcengine Seed-ASR 2.0, two-pass streaming (`bigmodel_async` + `enable_nonstream`)* | Volcengine | 2.72 % | 76 % | 4.13 % | 0.14 |
| *Volcengine Seed-ASR 2.0, streamed, automatic language (`enable_auto_lang`)* | Volcengine | 2.84 % | 68 % | 4.09 % | 0.14 |
| **Qwen3-ASR 1.7B, 30 s windows + field context (shipped)** | local | **2.50 %** | 79 % | 3.30 % | — |
| Qwen3-ASR 1.7B, whole take | local | 2.57 % | 78 % | 3.34 % | — |
| Fun-ASR-Nano-2512 (mlx-audio, words as hotwords, ≤ 30 s pieces) | local | 2.84 % | 74 % | 4.09 % | — |
| ElevenLabs Scribe v2 | OpenRouter | 2.86 % | 75 % | 3.78 % | 0.22 |
| Qwen3-ASR 0.6B, whole take | local | 3.27 % | 73 % | 4.29 % | — |
| **Qwen3-ASR 0.6B, 20 s windows (shipped)** | local | **3.34 %** | 75 % | 4.60 % | — |
| OpenAI gpt-transcribe | OpenRouter | 3.36 % | 74 % | 4.21 % | 0.28 |
| Mistral Voxtral Small Transcribe 3 | OpenRouter | 3.38 % | 71 % | 4.48 % | 0.23 |
| Mistral Voxtral Mini Transcribe 3 | OpenRouter | 3.45 % | 70 % | 4.21 % | 0.20 |
| *AssemblyAI Universal-3.5 Pro, direct, words as `keyterms_prompt`* | AssemblyAI | 4.02 % | 66 % | 4.72 % | 0.26 |
| AssemblyAI Universal-3.5 Pro | OpenRouter | 4.06 % | 63 % | 5.35 % | 0.30 |
| *AssemblyAI Universal-3.5 Pro, direct, field text + words as `prompt`* | AssemblyAI | 4.09 % | 65 % | 4.80 % | 0.26 |
| *Tencent Cloud general engine `16k_zh` (real-time, words as hotwords; free quota)* ⁵ | Tencent | 4.42 % | 67 % | 6.06 % | 0.45 (¥3.2) |
| *ElevenLabs Scribe v2 Realtime, keyterms + field text as `previous_text`* | ElevenLabs | 4.90 % | 77 % | 6.53 % | 0.47 |
| *AssemblyAI Universal-3.6 Pro streaming, keyterms + prompt* | AssemblyAI | 4.96 % | 74 % | 6.37 % | 0.50 |
| OpenAI gpt-4o-mini-transcribe | OpenRouter | 4.24 % | 66 % | 5.00 % | 0.09 |
| SenseVoice Small, whole take | local | 5.14 % | 57 % | 7.04 % | — |
| xAI Grok STT 1.0 | OpenRouter | 5.19 % | 68 % | 7.08 % | 0.10 |
| SenseVoice Small, 10 s windows | local | 5.74 % | 52 % | 8.06 % | — |
| *Speechmatics Melia 1 (`language: multi`, takes no word list)* | Speechmatics | 5.73 % | 63 % | 7.20 % | 0.24 |
| Google Chirp 3 | OpenRouter | 5.93 % | 65 % | 7.75 % | 0.98 |
| *Speechmatics Enhanced `cmn_en` (zh-en pack), words as `additional_vocab`; batch / real-time* | Speechmatics | 7.01 / 8.50 % | 57 / 50 % | 9.21 / 10.70 % | 0.75 / 0.80 |
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
*Italic* rows were added in the afternoon. They were reached directly with the provider's own key and $ are list prices
(¥ at 7.1 per $). ⁴ Streaming engines got 200 ms packets of the whole take. Volcengine's `nostream` endpoint is
re-recognised in ~15 s blocks, so the result doesn't depend on pace; the realtime models were paced at 1×.
Volcengine's word list is the documented inline `hotwords`, and the field text is one `dialog_ctx` turn. ⁵ Tencent's
large-model engines (`16k_zh_en`, `Hy-ASR-3.0-preview`, `16k_zh_en_2.0`) answered "资源包耗尽" (no resource pack): the
account's free hours cover only the general engines. Hotwords can't contain spaces, so "Claude Code" was left out.

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

The afternoon's providers are counted by occurrence with `harness/names.py`, which counts every "Option + letter"
shortcut. Three morning columns are recounted the same way for comparison:

| Name | 1.7B | Flash (words) | MAI-2 | Scribe direct (keyterms) | Volc 2.0 stream (hotwords) | Volc + cloud polish (2nd) | AAI direct | Tencent general | Speechmatics `cmn_en` |
|---|---|---|---|---|---|---|---|---|---|
| Blurt (9) | 9 | 9 | 1 | 8 | 3 | 8 | 8 | 3 | 0 |
| Typeless (4) | 4 | 3 | 1 | 4 | 1 | 4 | 4 | 0 | 2 |
| DeepSeek (10) | 9 | 10 | 10 | 10 | 10 | 10 | 10 | 1 | 3 |
| Option + letter (14) | 14 | 14 | 14 | 14 | 14 | 14 | 14 | 11 | 9 |
| Whisper (2) | 2 | 2 | 2 | 1 | 1 | 2 | 1 | 2 | 1 |

ElevenLabs' keyterms work: Blurt went from 1 of 9 without them to 8 of 9. Volcengine's inline hotwords barely work. It
writes "Blot", "TypeS", "TypeScript" and "Tabless", with or without the field text, and putting the words in a context
turn as well gets Blurt 5 of 9. Cloud polish with Apple's transcript fixes the names (8 of 9, 4 of 4).

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
| *Volcengine Seed-ASR 2.0 stream (2.18 %)* | DeepSeek V4.1 Flash + 2nd: Apple | 2.37 % | **91 %** | 0.74 |
| *ElevenLabs Scribe v2 direct (2.17 %)* | DeepSeek V4.1 Flash + 2nd: Apple | 3.05 % | 86 % | 0.81 |
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
| *Volcengine Seed-ASR 2.0 stream, automatic language* | 1.08 | **1.68** | 3.28 | 7.95 | 10.44 | 4.55 |
| *… zh-en default (no language set, as for a Chinese user)* | 2.93 | 5.72 | 2.70 | 7.27 | — | — |
| *ElevenLabs Scribe v2 direct* | 1.23 | 2.36 | 1.64 | 7.50 | 9.71 | 3.90 |
| *AssemblyAI Universal-3.5 Pro direct* | 1.31 | 2.47 | 3.05 | 14.66 | 14.08 | 7.58 |
| *Speechmatics Melia 1 (`multi`)* | 1.85 | 3.82 | 2.58 | 6.25 | **7.61** | 3.90 |
| *Speechmatics Enhanced `cmn_en`* | 2.55 | 5.72 | 3.63 | 10.45 | — | — |
| *Tencent general engines, language set (`16k_zh` / `16k_en` / `16k_ja` / `16k_de`)* | 2.08 | 2.81 | 2.70 | 7.39 | 18.93 | 7.79 |

Sizes: LibriSpeech clean 50 utterances / 7.7 min, other 50 / 5.2, AISHELL-1 test 60 / 4.8, ASCEND test 60 / 4.5 (only
"mixed" utterances of 2–15 s), Common Voice 17 ja 50 / 4.4, de 50 / 4.9. Japanese CER is high for every engine: Common
Voice's references mix kanji and kana spellings the engines write differently; read the order, not the level.

English words inside Chinese (ASCEND, 80 English words): MAI-2 82 %, Fun-ASR-Nano 81 %, Scribe 84 %, Flash 76 %,
1.7B 75 %, 0.6B 69 %, SenseVoice 48 %, Apple 44 %. Afternoon: Volcengine 84 % (auto) / 80 % (zh-en), Scribe direct
82 %, Melia 81 %, Tencent 74 %, Speechmatics `cmn_en` 74 %, AssemblyAI direct 54 %.

On Volcengine the language mode matters. Automatic language (`enable_auto_lang`) is best on English: LibriSpeech other
1.68 %, the lowest measured. Its default zh-en mode is better on Mandarin: AISHELL 2.70 % against 3.28 %, and the
founder's takes 2.18 % against 2.84 %. Without either setting it can't do Japanese ("Do it as my state."). AISHELL counts
against it partly because it writes "7万" where the reference says 七万. The scorer reads these differently, and every
engine that writes digits is affected; leaving out the 22 utterances with spoken numbers gives 2.18 % against Flash's
1.03 %.

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

*Shipped the same day* (dictation.md §Cloud recognition): the whole take at key-up with the words and the field's text,
the echo net, 1× by default — re-measured through the shipped code: 2.02 % at 1× (3.32 % at 1.5×).

### 4.2 Polish needs a second transcript; ship it with the cloud polish

Apple Speech runs on every Mac with macOS 26 at no cost, in-process. Sending its transcript of the same window as
`Also heard:` turned cloud polish from harmful (2.50 → 3.16 %) to helpful (→ 2.20 %) on the 1.7B, and from useless to
the biggest single gain on Apple's own text when the 0.6B is the second opinion (6.72 → 3.08 %). Cost: one more line in
the request (~100 tokens).

*Shipped the same day* (dictation.md §Second transcript): macOS's recogniser hears each window, and cloud polish runs
once over the whole take at key-up with its text as `Also heard` — 2.20 / 2.28 / 2.55 % in three runs through the app's
path in the Lab; window by window it was 2.57–2.92 %. A single run of any cloud-polish row here moves by up to ±0.2
points: the Flash + polish row's 2.17 % came out 2.44 / 2.44 % when this eval's own script ran it again.

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

Afternoon additions:

- **Tencent's large models** need a paid resource pack or pay-as-you-go. The free monthly hours cover only the general
  engines, and those make twice the errors (4.42 %).
- **Speechmatics** is weak on this speech: `cmn_en` 7.0–8.5 %, Melia 5.7 %. It writes "C语言" for Seed and "Mac OS"
  for macOS.
- **AssemblyAI direct** is no better than through OpenRouter: 4.02 %, and the prompt doesn't help.
- **Realtime models get worse on long takes.** ElevenLabs realtime 4.90 % against 2.17 % in batch (one 10 s take came
  back as "类-类-类-"). AssemblyAI streaming 4.96 %. Volcengine two-pass 2.72 % against 2.18 % with `nostream`.

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
| *Volcengine Seed-ASR 2.0, `nostream`, streamed at 1×* | **0.45 / 0.58 s** | **0.52 / 0.70 s** |
| *Volcengine Seed-ASR 2.0, two-pass `async`, streamed* | 0.55 / 0.66 s | 0.39 / 0.60 s |
| *Volcengine Seed-ASR 2.0, file API (submit + poll)* | 1.31 / 1.91 s | 6.52 / 6.98 s |
| *ElevenLabs Scribe v2 direct (batch)* | 3.62 / 3.73 s | 5.13 / 5.54 s |
| *ElevenLabs Scribe v2 Realtime, streamed* | 0.49 / 1.00 s | 0.43 / 0.48 s |
| *AssemblyAI Universal-3.5 Pro direct (upload + job + poll)* | 8.35 / 8.50 s | 12.17 / 12.45 s |
| *AssemblyAI Universal-3.6 Pro streaming* ⁶ | 0.16 / 0.54 s (n=5) | 0.43 / 0.54 s (n=5) |
| *Speechmatics `cmn_en` batch / real-time* | 8.43 / 8.77 s · 0.63 / 0.72 s | 10.86 / 11.49 s · 0.93 / 1.09 s |
| *Tencent general `16k_zh`, real-time* | 0.10 / 0.14 s | 0.15 / 0.15 s |
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
- Afternoon rows are measured from this Mac in Beijing, one engine at a time (`harness/latency2.py`,
  `raw/latency.jsonl` kind `cloud2`). Each takes up to 4 takes at once as independent sessions, with the words and the
  field text.
  - **Streaming:** the latency counted is from the last 200 ms packet, sent at real time, to the final text.
    Volcengine's `nostream` stays at ~0.5 s however long the take, because it has heard all but the last ~15 s block by
    key-up.
  - **Batch APIs from China:** ElevenLabs takes 3.6–5 s. AssemblyAI and Speechmatics take 8–12 s with upload and
    polling.
  - **Tencent's general engine:** 0.1 s; its servers are in Guangzhou.
  - ⁶ AssemblyAI's free tier allows 5 new streams a minute; 4 of 14 latency sessions were refused ("policy
    violation"). When the last turn had already ended at key-up, the latency is counted as 0.

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

| *B′ (China, streamed; added in the afternoon)* | Volcengine Seed-ASR 2.0, `bigmodel_nostream` over a websocket during the take, inline hotwords + field text as `dialog_ctx` | as A (it fixes Volcengine's names: Blurt 3 → 8 of 9) | 2.18 % raw, 2.37 % polished (names 91 %) | ¥1 / audio hour (≈ ¥0.003 for a 10 s dictation) + polish | the audio as it is spoken, the field's text and the words — to ByteDance's Volcengine (mainland China) |
| *C′ (outside China)* | ElevenLabs Scribe v2 direct, keyterms | none (polish made it worse: 3.05 %) | 2.17 % | $0.26 / audio hour | the audio, the words — to ElevenLabs (US; EU / India / Singapore residency on Enterprise) |

A is as accurate as B, needs no audio upload and keeps working offline (it falls back to the local text). B is for Macs
that can't run a local model well (8 GB, Intel) and for long takes, where the cloud has no 30 s window to wait for.

Afternoon: none of the five direct providers beats A or B on accuracy, so §7 is unchanged.

- **Volcengine (B′)** is the cloud recognizer with the delay dictation needs. It streams while you speak and leaves
  ~0.5 s at key-up even after a minute, against 1.5 s for Flash on a whole take. It has no echo of the field (§4.1).
  Its weakness is the founder's own names, which the polish repairs.
- **Integrating it** means a new backend in `transcribe.py` (not done here: another agent is editing it):
  - a websocket client for `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream` with its 4-byte binary
    frames (gzip JSON request, raw PCM packets, a negative sequence on the last) and an App ID + Access Token pair;
  - resource `volc.seedasr.sauc.duration`;
  - the words as `corpus.context` `{"hotwords": [...]}` and the field text as a `dialog_ctx` turn;
  - leave the language unset for Chinese users (automatic language costs 0.7 points on Chinese) and set
    `enable_auto_lang` for others;
  - feed it the microphone's packets during the take rather than pieces at key-up.
- **The trial's concurrency is low.** At 6 parallel sessions it began refusing ("quota exceeded for types:
  concurrency"); one user needs one.
- **ElevenLabs direct (C′)** matches MAI-2 and spells names, but its batch call takes 3.6–5 s from China. Its realtime
  model is fast but twice as wrong.

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
- **Added 2026-10-31 (afternoon): five providers, direct.**
  - **Keys and permissions.** The founder got keys for Volcengine, ElevenLabs, Tencent Cloud, Speechmatics and
    AssemblyAI in `~/.blurt-eval-keys.env` (chmod 600). They were loaded into the process only (`harness/keys2.py`),
    never printed or written. The founder approved sending the 95 takes to these five; the public sets went too.
  - **Models.** Each provider's best current model for zh-en, from its docs on 2026-10-31:
    - Volcengine 豆包 Seed-ASR 2.0 (`volc.seedasr.*`): streaming `nostream` and two-pass, plus the file API with the
      audio inline.
    - ElevenLabs `scribe_v2` and `scribe_v2_realtime`.
    - AssemblyAI `universal-3-5-pro` batch and `universal-3-6-pro` streaming.
    - Speechmatics Enhanced `cmn_en` and `melia-1`.
    - Tencent: `16k_zh_en` and `Hy-ASR-3.0-preview` were refused (no resource pack), so the general engines were used.
  - **What the founder's takes got.** The word list as each API takes it: keyterms, hotwords or `additional_vocab`. The
    field text where an API takes context: Volcengine `dialog_ctx`, ElevenLabs realtime `previous_text`, AssemblyAI
    `prompt`.
  - **Runners and store.** `harness/run_cloud2.py` + `run_cloud2_all.sh`, `latency2.py`, `names.py`. The same
    append-only store; `probe-*` engines are smoke tests.
  - **Usage (audio sent, all within free trials and credits; list-price value in brackets):**

    | Provider | Audio sent | Out of | List-price value |
    |---|---|---|---|
    | Volcengine streaming | 4.4 h | 20 h trial | |
    | Volcengine file | 0.7 h | 20 h trial | |
    | Volcengine, both | | | ≈ ¥6.4 |
    | ElevenLabs batch | 1.2 h | 4.5 h a month | |
    | ElevenLabs real-time | 0.7 h | 2.5 h a month | |
    | ElevenLabs, both | | | $0.62 |
    | AssemblyAI | 2.6 h | $50 credit | $1.19 |
    | Speechmatics | 2.9 h | $100 credit | $1.67 |
    | Tencent, general engines | 1.3 h | 5 h a month real-time | free; list price would be ¥4.3 |
    | Model Studio (polish on two recognizers) | | | +$0.07 |

  - **Not touched:** Blurt's processes, `~/.blurt` (read-only use of the takes) and the app's sources.

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

Afternoon: Volcengine, ElevenLabs, Speechmatics, AssemblyAI and Tencent are now measured (§2.1). Tencent's free hours
cover only the general engines. Its large models need a resource pack or pay-as-you-go: real-time `16k_zh_en` is
¥4.8 / h, `Hy-ASR-3.0-preview` ¥1 / h. Not measured.
