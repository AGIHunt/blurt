# Dictation quality, 2026-10-31: where the errors come from, and what fixes them

The founder's report (2026-10-31): dictation is noticeably worse than Typeless. They said the same sentence many times
with different engines (Apple Speech, Qwen3-ASR 0.6B / 1.7B, the cloud Qwen3-ASR Flash, which failed), local polish
(Gemma 4 E2B), cloud polish off, and still fixed it by hand. Typical misses: Blurt → 不乐, 手动 → 少动,
调整 → 条件, macOS Speech → "Mike ays speech", Whisper Large V3 Turbo → "Whisper large, without tube".

This document measures where those errors come from, using the founder's own takes. Method details are in §6. Scripts,
raw outputs and the references are in the session scratchpad (`dictation-research/`, see its `RERUN.txt`; not in git).
The real errors are saved as 34 Dictation Lab cases.

## 1. Summary

| | Error (units) | Terms right |
|---|---:|---:|
| **What was typed** (the history, mostly 0.6B, 9 takes on Apple Speech, 2 cloud failures) | **6.05 %** | 65 % |
| … without the 2 takes the cloud recognizer lost | 5.41 % | 65 % |
| The app's pipeline replayed with **0.6B** (10 s windows + Gemma 4 E2B) | 5.17 % | 70 % |
| … with **1.7B** | 4.12 % | 82 % |
| **1.7B + 30 s windows + the field's text as context + Gemma** (fixes 1–3 below) | **3.07 %** | 84 % |
| 1.7B, 10 s windows, cloud polish given a second recognizer's transcript (fix 4, prototype) | 3.51 % | **92 %** |
| Best recognizer output alone: 1.7B, whole take, field context | 2.63 % | 84 % |

43 of the founder's takes (18 min, 2,961 units); a unit is a Chinese character or an English word; punctuation not
counted.

**Root causes, ranked by measured effect:**

1. **The recognizer.** The 0.6B model (the default since v1.0.6, on pro Macs too) makes 30 % more errors than the 1.7B
   on this speech (4.76 vs 3.65 % as streamed) and gets 10 points fewer terms right. Apple Speech, which carried most of
   the repeated-sentence takes today, makes 2.3 times the 1.7B's errors (8.44 %) and gets 40 % of the terms right.
   Every named example except "without tube" is Apple Speech's (§3).
2. **Cutting the take into 10 s windows.** The same model on the whole take makes 17–22 % fewer errors (0.6B 4.76 →
   3.71 %, 1.7B 3.65 → 3.04 %). Words are lost where a short piece heard nothing (备忘录, 这样的风格。然后, 它是能看), and
   names come out worse without the rest of the sentence (Option M → OpenM). 30 s windows recover nearly all of it.
3. **Local polish can't fix misheard words, and slightly damages text.** Gemma 4 E2B made the replays worse on both
   models (+0.4 points). It was better on 4 takes and worse on 11. It swaps unknown names for listed ones (爱范儿 →
   Claude, Pagagent → Bug-agent), writes "A P P" as API, and twice answered with the text before the cursor. A prompt
   change did nothing (§3.3).
4. **The recognizer never sees the conversation.** The field's text only ranks the word list. Given its last 300
   characters as context, the 1.7B goes from 3.04 to 2.63 % (截了, blurt, macOS Speech, Typeless).
5. **The word list doesn't hold the founder's words**, and learning hasn't added any. There are 21 active words; the 9
   learned suggestions are fragments (面有提, 们, 也是). macOS, Whisper, Option, hover, Seed and AppSo are missing.
   Adding 13 of these: 1.7B 3.04 → 2.77 %, at the cost of 2 false insertions in 360 decodes.
6. **Cloud polish as configured invents names on a noisy transcript.** On 0.6B's output it wrote Typeless for Blurt,
   Claude for main 分支, and "Claude、Kimi、Qwen、Typeless" for 派个子 agent: 9 wrong names in 6 of 43 takes.
   Separately, it fails silently through OpenRouter: the hybrid-thinking model spends its tokens thinking, the answer
   comes back empty, and the local model answers instead.

Not causes: the language tag (299 of 300 pieces tagged Chinese, the 1 English one was English, none close to the line);
polish fall-backs (6 of 176 takes); traditional characters; VAD.

## 2. Results

### 2.1 Every configuration on the 43-take reference set

Pooled unit error (Σ edits / Σ reference units). "Terms" is 83 terms in the references: every English word or name,
plus a few Chinese ones (千问, 智谱, 云端润色, 手动, 剪贴板…). Streamed rows replay the app's own cuts and windows
(`dictation_lab` `mode=windows`, the take's own pieces), with the text around the cursor as the app had it.

| Configuration | Recognizer output | After local polish (Gemma 4 E2B) | Terms (polished) |
|---|---:|---:|---:|
| Apple Speech, streamed | 8.44 % | 8.44 % | 57 % |
| Apple Speech, whole take | 7.60 % | — | 46 % (raw) |
| Whisper large-v3-turbo (MLX, direct), whole take / + word prompt | 6.86 / 7.43 % | — | 65 / 64 % (raw) |
| 0.6B, pieces only (no hearing again) | 5.40 % | — | 72 % (raw) |
| **0.6B, streamed, 10 s windows (as shipped)** | **4.76 %** | **5.17 %** | 70 % |
| 0.6B, 20 s windows | 3.82 % | — | 75 % (raw) |
| 0.6B, 30 s windows | 3.78 % | — | 74 % (raw) |
| 0.6B, whole take | 3.71 % | — | 74 % (raw) |
| 0.6B, 20 s windows + field context | 4.09 % | 4.15 % | 75 % |
| **1.7B, streamed, 10 s windows** | **3.65 %** | **4.12 %** | 82 % |
| 1.7B, 20 s windows | 3.55 % | — | 81 % (raw) |
| 1.7B, 30 s windows | 3.21 % | — | 82 % (raw) |
| 1.7B, whole take | 3.04 % | — | 82 % (raw) |
| **1.7B, 30 s windows + field context** | **2.90 %** | **3.07 %** | 84 % |
| 1.7B, whole take + field context (last 300 characters) | 2.63 % | 2.87 % ¹ | 86 % |
| 1.7B, whole take + 13 more words | 2.77 % | — | 87 % (raw) |
| Word list off: 0.6B / 1.7B, whole take | 4.22 / 3.72 % | — | 69 / 75 % (raw) |

¹ The joined text polished in one go; the streamed rows polish window by window, as the app does.

Cloud polish (DeepSeek V4.1 Flash through OpenRouter, reasoning off, the shipped cloud prompt and context):

| Input | Recognizer output | Cloud polish | Terms | Takes with a wrong name inserted |
|---|---:|---:|---:|---:|
| 0.6B streamed, window by window (as the app does) | 4.76 % | 5.03 % | 81 % | 6 |
| 1.7B streamed, window by window | 3.65 % | 3.99 % | 89 % | 3 |
| 1.7B streamed, joined, one call (prototype prompt format) | 3.65 % | 4.42 % | 89 % | 2 |
| **1.7B streamed, joined, + Apple Speech's transcript as "Also heard"** | 3.65 % | **3.51 %** | **92 %** | **1** |
| 1.7B whole take + field context | 2.63 % | 2.94 % | 87 % | 0 |

The references keep what was said, including a repeated phrase and a restart. Cloud polish deletes those, as its
prompt tells it to, so part of its higher error is intended rewriting. The wrong names are not: Blurt → Typeless,
main 分支 → Claude or worktree, 爱范儿 / AppSo → iOS / App Store, OpenM → OpenAI, B app → BA app (a project key
in the word list). One cloud answer also changed the meaning: 还是要粘贴进去 → 还是要解决一下.

Cloud speech recognizers (OpenRouter, ≤ 120 s clips, the skill's `cloud_ref.py`, $0.017 spent): 13 of today's
disputed takes, 470 units.

| On those 13 takes | Error | Terms |
|---|---:|---:|
| What was typed | 11.49 % | 55 % |
| Apple Speech, whole take | 9.36 % | 36 % |
| 0.6B streamed (replay) | 6.17 % | 73 % |
| 1.7B whole take | 3.83 % | 77 % |
| OpenAI gpt-transcribe (no words, no context) | 3.19 % | 64 % |
| **1.7B whole take + field context** | **2.55 %** | **86 %** |
| OpenAI whisper-large-v3 | 14.26 % | 36 % |

### 2.2 The Lab's own numbers on the 34 saved cases

`dictation_lab.py run --no-save`: the mean of per-case WER, polish on, no context, no numeral normalisation, so higher
than §2.1.

| Config | WER | Term accuracy |
|---|---:|---:|
| `asr=apple-speech,mode=windows` | 16.07 % | 43 % |
| `asr=qwen3-asr-0.6b-mlx,mode=windows` (as shipped) | 11.66 % | 71 % |
| … with `rehear_window_s` 30 | 10.80 % | 71 % |
| `asr=qwen3-asr-1.7b-mlx,mode=windows` | 9.47 % | 86 % |
| … with `rehear_window_s` 30 | **8.72 %** | 86 % |
| `asr=qwen3-asr-1.7b-mlx,mode=whole` | 8.87 % | 86 % |

### 2.3 Latency: the speech model's work left after key-up

Median / p90 over the 44 replayed takes. Other agents used the GPU at the same time, so absolute numbers run high; the
differences are what matter.

| Model | 10 s windows (shipped) | 20 s | 30 s | Takes ≥ 20 s: 10 / 20 / 30 s (median) |
|---|---:|---:|---:|---:|
| 0.6B | 215 / 316 ms | 254 / 427 ms | 281 / 492 ms | 169 / 253 / 400 ms |
| 1.7B | 272 / 388 ms | 339 / 535 ms | 376 / 642 ms | 221 / 322 / 515 ms |

Field context adds a few dozen prefill tokens: no measurable change. Cloud polish through OpenRouter took 2.4 s
median (p90 3.4 s), against 0.95 s for DeepSeek's own API (§Cloud polish in dictation.md); OpenRouter's routing is the
difference.

## 3. Where each error comes from

### 3.1 The founder's examples

| Said | Typed | Engine | Stage | Fixed by |
|---|---|---|---|---|
| 用 Blurt 来输入 | 使用。不乐他来输入 | Apple Speech | recognizer | 1.7B + field context → "blurt"; 1.7B alone → 布勒特 |
| 我还是手动做了很多调整 | 我还是少动，做了很多条件 | Apple Speech (streamed) | recognizer; Apple's whole-take pass gets 调整 | any Qwen run: 手动做了很多调整 |
| 或者 macOS Speech | 或者 Mike ays speech | Apple Speech | recognizer; polish then answered with the text before the cursor (`grew`) | Qwen 0.6B / 1.7B: Mac OS Speech |
| Whisper Large V3 Turbo (said alone, in English) | Whisper large, without tube | 1.7B, tagged English correctly | recognizer | only gpt-transcribe; the previous dictation in the field had the name, but context didn't flip it |
| 千问 0.6 的 ASR … Typeless | 请问 0.6 / ARR / 纤问 … Tipelex / Tavalize / Typlase | Apple Speech | recognizer; polish fixed Typeless twice, dropped 千问 | 1.7B whole take: 千问零点六的ASR … Typeless; + context: Qwen |
| 云端润色 | 云端运色 | Apple Speech | recognizer | every Qwen run |
| 从我的…记录里 | 从罗德…记录里 (not noticed by the founder either) | Apple Speech | recognizer | every other engine |

### 3.2 Recognizer (model) vs streaming (cuts)

Today's takes and the previous night's, against the whole-take decode by the same model: the stream was worse on 11
takes and better on 4. Across all 153 takes made on 0.6B, the stream differs from the whole-take decode on 4.3 % of
units. It drops 8 spans of 2 or more words that the whole take has.

- d-20261031-100944: a 3.5 s piece (这样的风格。然后) came back empty, and its 10 s window too. At the next cut, 它是能看
  was lost. Polish then wrote "A P P" as API twice.
- d-20261031-012604: 苹果的备忘录 → 苹果的。 inside a 22 s window. Every whole-take decode has it.
- d-20261031-022357: Option M → OpenM in the stream (the whole take: Option M); a Korean 그럼 was inserted.

What helps is audio context, not text context. Decoding each window without the text so far changes little (4.76 →
4.66 %, 0.6B). The pieces alone, without hearing again, are worse (5.40 %). Longer windows close the gap: 20 s gives
3.82 % (0.6B), and 30 s gives 3.21 % (1.7B).

Errors by kind (units in the 2,961):

| | Misheard Chinese | Name / English word | Dropped | Inserted |
|---|---:|---:|---:|---:|
| As typed | 65 | 40 | 66 (18 from the 2 cloud failures) | 9 |
| 0.6B streamed | 71 | 40 | 26 | 9 |
| 1.7B streamed | 46 | 28 | 29 | 12 |
| 1.7B whole + field context | 35 | 21 | 13 | 13 |
| Apple Speech, whole take | 133 | 76 | 9 | 15 |

What is left after the best recognizer is mostly hard: hover said inside Chinese (后玩 / 后挽), AppSo / 爱范儿, a dropped
到底行不行 at the very end (every Qwen run), and 用于 for 云端 (uncertain).

### 3.3 Polish

- **Local, Gemma 4 E2B.** On the streamed replays it was better on 4 takes and worse on 11, for both models
  (0.6B 4.76 → 5.17 %, 1.7B 3.65 → 4.12 %).
  - Real damage: 爱发儿 / 爱普搜 → Claude / DeepSeek, Pagagent → Bug-agent (listed project words), A P P → API ×2,
    去掉 → 给掉, and 箱子 dropped along with the meaning around it.
  - Style changes: 的 / 了 / 那个 dropped, 或 → 或者, 他俩 → 它们.
  - Fixes: Typeless spelled right twice, K 二 → K2, 剪贴板, 打磨, 麦分支 → main 分支 (1.7B input).
  - In the history, 2 of the 6 fall-backs were the model answering with the text before the cursor (101121 `dropped`,
    102236 `grew`). Both then typed the raw transcript.
  - A prompt variant (only a name that sounds like a listed one becomes it; A P P → APP) changed nothing: 3.99 % both.
  - This agrees with v1.0.2: told plainly to fix homophones, E2B fixed none of 81.
- **Cloud, current prompt.** It fixes names (terms +8–10 points) but deletes repetitions and restarts. On a noisy
  transcript it guesses names from the word list and the context, as listed in §2.1.
- **Cloud with two transcripts (prototype, `two_hyp.py`).** The same prompt plus one paragraph, given the 1.7B stream
  and Apple Speech's transcript of the same audio. It is the only polish that beat its input (3.65 → 3.51 %): terms
  92 %, and a wrong name in 1 take (爱范儿 → iPhone). The second transcript gives the model evidence about the sounds,
  so it doesn't have to guess from the context.

### 3.4 Words and context

- **The ASR request.** Qwen3-ASR gets "Notes about Anthropic, BA, blurt, … and 口喷鸡." (21 words, plus the app's
  name). The text around the cursor (`hint`) only orders that list. Polish gets the relevant words only (heard, spelled
  alike, or in the field). For d-20261031-101757 that included Typeless (it was in the field), and Gemma still typed
  Apple's "Tavalize".
- **The list's worth.** Words off: 0.6B 3.71 → 4.22 %, 1.7B 3.04 → 3.72 %.
- **More words aren't free.** With 13 more:
  - 1.7B gains (2.77 %, terms 87 %); 0.6B doesn't (3.75 %).
  - 86 of 360 decodes changed.
  - Two false insertions: 口喷鸡 → "口点agent", AirPods → "Apple Speech".
  - One regression: Typeless → Timeless.
- **The field's text as context** (prototype: the last 300 characters before the cursor, ahead of the text so far, in
  Qwen's context):
  - 1.7B whole take 3.04 → 2.63 %. It fixed 截了 (the field said 我刚截了), blurt, Typeless and macOS Speech.
  - 0.6B mixed: whole take 3.71 → 3.58 %, but 20 s windows 3.82 → 4.09 %.
- **Learning.** None of the founder's corrections reached the list; they correct in Claude's box after the paste. The 9
  learned suggestions are character fragments of Chinese sentences (面有提 / 面有题, 们 / man).

### 3.5 Routing, settings and reliability

- **Engine changes.** The config shows the founder switching engines to compare: 0.6B (the v1.0.6 default) until
  10:15, Apple Speech 10:16–10:22, the cloud Qwen3-ASR Flash at 10:27, and 1.7B from 10:29 (downloaded 10:17–10:24). The
  history's `asr_model` matches the selection each time.
- **Cloud Qwen3-ASR Flash.** 4 of 4 takes `asr_failed:error`, nothing typed, no log kept. Every local engine and
  gpt-transcribe hear 测试一下，看看效果如何. Another agent is on the cloud settings.
- **Whisper large-v3-turbo through `transcribe.py`.** It hangs; another agent is on it. Run directly (mlx-whisper
  0.4.3) it works but is weaker here: 6.86 %, terms 65 %, Typeless → "Table S". The word prompt doesn't help (7.43 %).
- **Cloud polish through an OpenAI-compatible provider that thinks by default** (OpenRouter's DeepSeek V4.1 Flash).
  Reasoning used up the token budget and the answer came back empty; Blurt answered with the local model without
  saying so. `polish_cloud.complete` turns thinking off only for deepseek.com and DashScope. The prototype sends
  `"reasoning": {"enabled": false}` to OpenRouter.
- **Polish limits.** Gemma 4 E2B, 4-bit. Windows are ~10 s with 120 characters of text so far and 300 before the
  cursor, so nothing came near a size limit. There were 2 timeouts in 176 takes (a 223 s take and one 19 s take).

## 4. Fix plan, by impact and effort

Every fix is a model, setting or context change; none is a word list or a language rule. Each works for any language
the recognizer speaks. "Before" is the shipped pipeline replayed on the 43 takes: 0.6B, 10 s windows, Gemma, 5.17 %.

| # | Fix | Effort | Before → after (43 takes) | Cost |
|---|---|---|---|---|
| 1 | **1.7B where it fits next to polish** (the pro tier, as before v1.0.6). v1.0.6 chose 0.6B from 13 Lab clips (4.6 vs 6.4 %); these 43 references say otherwise. | a line in `transcribe.py` `preference()` / `dictation_models()`, plus the doc | 5.17 → 4.12 % (−20 %); terms 70 → 82 %. Lab: 11.66 → 9.47 % | +57 ms at key-up (median); 1.5 GB more download, +1 GB memory |
| 2 | **Longer hearing-again windows**: `rehear_window_s` 10 → 30 on 1.7B, → 20 on 0.6B (or by machine speed) | the setting's default (DictationStream / `dictation_stitch` already take it) | raw: 1.7B 3.65 → 3.21 %, 0.6B 4.76 → 3.82 %. Lab: 1.7B 9.47 → 8.72 %, 0.6B 11.66 → 10.80 % | at key-up: 1.7B +104 ms median (+294 ms on takes ≥ 20 s); 0.6B +39 ms (+84) |
| 3 | **The field's text as the recognizer's context** (1.7B; Qwen3-ASR takes free text in any language). Send the last ~300 characters before the cursor ahead of the text so far; keep the echo net (`echoes_prior`) and the tag read without it. | small: `transcribe.py` request field + the app's `DictationContext` already has the text | 1 + 2 + 3: **5.17 → 3.07 %** (−41 %); vs what was typed 6.05 % (−49 %); terms 70 → 84 % | none measurable; not for 0.6B (mixed) |
| 4 | **Cloud polish with a second opinion**: give it Apple Speech's transcript of the same window (free, in-process; the cloud-ASR path already runs it for live text) and one prompt paragraph. Also send the provider's no-thinking switch for OpenAI-compatible hosts (OpenRouter `reasoning.enabled=false`). | medium: AppleSpeech on each window in parallel, a prompt line, the Lab's `cloud=on` with it | 1.7B stream: 3.65 → 3.51 % (current cloud prompt: 3.99 %); terms 81 → 92 %; wrong names 3 → 1 take | DeepSeek ~1 s per call; ≈ ¥0.0013 a take |
| 5 | **Local polish: fewer word changes, not more prompt** — it can't fix misheard words. Keep it for punctuation, fillers and digits; consider a larger local model on pro Macs (Gemma 4 E4B, Qwen3.5 4B: in the catalogue, not measured here: a 3–5 GB download) | measure first | today −0.4 points on both models | — |
| 6 | **Learn words from what the user sends** (the fix happens in the target app after the paste; the watch learned only fragments) and drop fragment suggestions | medium | the measured ceiling, 13 of their words: 1.7B 3.04 → 2.77 %, terms +5 | 2 false insertions in 360 decodes |
| 7 | **Apple Speech only as the zero-download fallback**, never offered as a peer for zh / en technical speech | copy in Settings | 8.44 % vs 4.12 % (1.7B) | — |

Fixes 1–3 together are what the founder can have locally today: **3.07 % against 6.05 % typed**, with about +100 ms
(median) after key-up on a pro Mac. Fix 4 is the cloud tier. Fixes 1 and 2 are setting changes. Fix 3 is one field in
the ASR request. All three should go through the Lab (the 34 saved cases) and the eval sets (`polish.py eval`,
`polish_overdelete.jsonl`) before shipping.

## 5. What Typeless-class products do, and what that takes here

Typeless, Wispr Flow and the like stream audio to a cloud recognizer that keeps the whole utterance in view. A large
LLM then rewrites the text with the app, the screen text and a personal dictionary. They also learn from the user's
edits. Their exact models are not public; Wispr Flow's engineering posts describe a fine-tuned LLM pass with a latency
budget of under a second.

What the measurements above say about copying that:

- **A strong cloud recognizer alone is not the gap.** gpt-transcribe, with no words and no context, scored 3.19 % on
  today's 13 takes. The local 1.7B with field context scored 2.55 %. What the founder felt today was Apple Speech and
  0.6B (9–11 %), not local recognition as such.
- **The rewrite only helps on a good transcript.** On 0.6B's output the cloud rewrite invented names in 6 of 43 takes,
  including the opposite product (Blurt → Typeless). The order is recognizer first, then the LLM, and the LLM needs
  evidence about the sounds: a second transcript (fix 4), and later n-best lists or the speech model's
  low-probability words.
- **Local-first path (no network):** 1.7B, 30 s windows and field context (3.07 % with Gemma), with a learned word list
  on top. The remaining errors are mostly names said inside Chinese that no list holds (hover, AppSo).
- **Cloud path:** a cloud recognizer that takes context (Qwen3-ASR Flash with the words and the field's text: its
  failure today has to be fixed first) or the local 1.7B, plus cloud polish with two transcripts and no-thinking. Cost
  ≈ ¥9 a month (first-minute-speech.md §3). Latency ~1 s with DeepSeek's own API, 2.4 s through OpenRouter.
- **Not measured here:** the full product loop. Typeless reportedly rewrites more freely (lists, tone); Blurt's Light
  keeps the speaker's wording, which the founder's own sent text also keeps (repetitions included).

## 6. Method

- **Data.** `~/.blurt/dictation/history.jsonl`: 180 takes, 2026-10-30 10:14 → 10-31 10:30, 57 min of audio, all with
  audio and pieces. Engines: 0.6B 153, Apple Speech 10, 1.7B 4, Whisper 9 (before polish was installed), failed 4.
- **What the founder actually sent.** Their Claude Code transcripts (user messages since 10-30, on this Mac) were
  matched to the takes: 104 of 180 takes appear in 59 sent messages, and 56 of the 104 were changed before sending.
  Some changes were rewrites (added content), not fixes.
- **References.** 43 takes (18 min, 2,961 units; `refs.json`), written by the reviewing agent from every engine's
  transcript, the two cloud speech models, the sent text and the field context. They keep what was said, without
  fillers. 16 spans in 12 takes are marked uncertain (e.g. 云端 / 用鱼, "base URL"); one take
  (AirPods / 爱范儿, 102925) was left out as unclear.
- **Scoring.** The Lab's units and diff (`dictation_lab.score`), after an eval-only normalisation:
  - traditional → simplified Chinese; 呃 / 嗯 removed;
  - 他 / 她 / 它 and 的 / 得 / 地 unified;
  - Chinese numerals → digits where they are a number (0.6, K2, V3, 1.0.5);
  - spelled letters joined (A S R = ASR);
  - 千问 = Qwen.
  
  "Mac OS" vs "macOS" still counts.
- **Replays.** Each take went through the Lab's own `run_case`, using the snapshot of `skills/blurt/scripts` (10:36,
  the committed state), in scratch `BLURT_HOME`s with the models linked. Nothing ran on the app's servers.
  - Whole take: `mode=whole,polish=off`.
  - The app's pipeline: `mode=windows,polish=on`, with the take's own cuts and pauses and its kept field context as the
    polish context.
  - Window lengths: `record.dictation.rehear_window_s` in the scratch config.
  - Field context: a scratch `transcribe.py` that lets the text so far be 400 characters.
  - Whisper: mlx-whisper 0.4.3 in-process, `language="zh"`.
- **Cloud.** Speech recognition: 15 disputed clips through the skill's `cloud_ref.py` ($0.017; ledger `spend.json`).
  Polish: OpenRouter `deepseek/deepseek-v4.1-flash`, text only, a few cents.
- **Lab cases.** 34 takes with real errors were saved with `dictation_lab.py from-history ID --corrected … --tags …
  --note "… — dictation-quality-2026-10-31"`. Tags: homophone 19, term 12, dropped 5, segmentation 4, code_switch 4,
  made_up 3, format 2.
