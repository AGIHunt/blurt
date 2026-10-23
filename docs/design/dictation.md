# Dictation (听写) — v0.8, macOS

Typeless-style dictation: you talk, and the words are typed into **whichever app has the focus**. It is separate from
the voice note: `⌥⇧V` still files what you say into Blurt, and the two never share a key.

## Flow

```
right ⌥ tap ──▶ DictationTrigger ──▶ NoteVoice (mic → 16 kHz wav) ──▶ ASR (warm transcribe.py serve, dictation model,
  (DictationListener: tap   │ arm: warm ASR + polish servers           │   biased toward the custom words; exact
   or AX monitor)           │ start: read the text around the cursor   │   sounds-likes fixed: dictation_vocab.py)
                            ▼                                         ▼
                   island ears: keyboard + mint level      polish (warm polish.py serve, ≤ 3 s, guard)
                                                           + custom words + context as spelling hints
                                                                      │
          history.jsonl ◀── DictationInsert: save pasteboard → text → ⌘V → restore after 0.6 s
                                                                      │
          vocabulary.json ◀── DictationWatch: the same field for 60 s → DictationLearn: the user's fixes
```

| Piece | Where |
|---|---|
| Trigger state machine (pure, unit-tested) | `BlurtCore/DictationTrigger.swift`, `Tests/BlurtCoreTests/DictationTriggerTests.swift`, selftest `dictation_trigger` |
| Which listener runs (pure, unit-tested) | `BlurtCore/DictationListener.swift`, `DictationListenerTests`, selftest `dictation_listener` |
| Event tap / monitor, permissions | `Capture/Dictation/DictationKeys.swift` |
| Custom words: store, seed, learning (pure, unit-tested) | `BlurtCore/DictationVocabulary.swift`, `BlurtCore/DictationLearn.swift`, `DictationVocabularyTests`, selftest `dictation_vocab` |
| Context, the after-typing watch | `Capture/Dictation/DictationContext.swift` |
| Custom words in ASR and polish | `scripts/dictation_vocab.py`, `transcribe.py` (`note --dictation --vocab`, `dictation-models`), `polish.py`, `tests/test_dictation_vocab.py` |
| Controller (capture → ASR → polish → insert → history) | `Capture/Dictation/Dictation.swift` |
| Insertion | `Capture/Dictation/DictationInsert.swift` |
| Warm-server client (no `uv run` per request) | `BlurtCore/WarmServer.swift` |
| History file | `BlurtCore/DictationHistory.swift`, `scripts/dictation.py` (list / prune / turn into item) |
| Polish model + guard + eval | `scripts/polish.py`, `scripts/polish_models.json`, `tests/fixtures/polish_eval.jsonl`, `tests/test_polish.py` |
| UI | island ears (`Island/Ears.swift`), Settings → Dictation (`Settings/DictationPane.swift`), the main window's Dictation page (`MainWindow/DictationPage.swift`: a sidebar place; the menu-bar menu, `⌥⌘D` and the palette open it) |

## Trigger

- Right ⌥ (keyCode 61, device bit `NX_DEVICERALTKEYMASK` 0x40) by default, or Fn (keyCode 63, `.maskSecondaryFn`), or
  either ⌥ (keyCodes 58 / 61, `NX_DEVICELALTKEYMASK` 0x20 / 0x40: whichever side is tapped alone; both sides at once
  is not a tap).
  Modifier-only keys can't be Carbon hotkeys, so a **listen-only** `CGEventTap` (`flagsChanged`, `keyDown`, mouse down)
  feeds the state machine. It never blocks or changes an event.
- **Tap** (default): down and up within 400 ms, no other key, modifier or click in between, and no other modifier held
  when it went down. One tap starts, the next stops. So ⌥-letter and ⌥⇧V never trigger.
- **Hold**: held alone for 250 ms starts (the caller ticks at `deadline`), release stops, and another key or a click
  joining in cancels.
- `Esc` cancels. `arm` on a clean key-down warms the models while the user starts talking.
- Off while a screen recording runs (it owns the mic) and while a voice note listens; both cases show a toast.
- Permissions: Input Monitoring for the tap, Accessibility for the paste and the context.
- **Which listener** (BlurtCore `DictationListener`, `DictationListenerTests`). The bug it fixes: a listen-only tap
  made at launch **before** Input Monitoring was granted is accepted by macOS, but it only gets the events aimed at
  Blurt itself, and macOS never upgrades it. `start()` returned early because the tap existed, and the status said
  "installed", so right ⌥ worked only while Blurt was in front.
  - `CGPreflightListenEventAccess()` is the truth. A tap counts as global only when it was made with Input
    Monitoring and the grant is still there (`kind`: `tap` | `tap_local` | `monitor` | `none`).
  - While the listener isn't a global tap, it is re-planned every 3 s and whenever Blurt is activated
    (`NSApplication.didBecomeActive`). When the grant arrives, the tap is torn down and made again.
  - `tapDisabledByTimeout` / `tapDisabledByUserInput`: the tap is enabled again; if `CGEvent.tapIsEnabled` still
    says no, it is made again.
  - Input Monitoring missing, Accessibility granted: `NSEvent.addGlobalMonitorForEvents` + a local monitor for
    `flagsChanged`, `keyDown` and mouse-downs. AppKit documents that key events reach a global monitor only when the
    app is trusted for Accessibility, which it is here; delivery is asynchronous, so it never slows typing. The
    device bits (left / right ⌥) come from the event's `cgEvent.flags`. Whether macOS still delivers modifier
    changes from other apps this way can only be confirmed on a real machine (below).
  - One listener at a time (a Blurt-only tap next to the monitor would deliver Blurt's own keys twice), and the same
    flags change twice within 30 ms counts once while one listener replaces the other.
  - "Dictation works" = the listener is global (`tap` or `monitor`). Settings → Dictation shows which listener runs
    and *Last heard in another app: 13:46:57* — taken from the listener itself whenever the dictation key changes
    while another app is in front. Only the user can make that line appear.
- Until the key is heard globally (BlurtCore `DictationAccess` decides; `DictationAccessTests`):
  - at launch, `CGRequestListenEventAccess()` once per app version (`app.dictation_asked_version`), never while the
    setup assistant shows (it has its own row). This shows macOS's prompt and lists Blurt under Input Monitoring;
  - the menu-bar menu's first row is "Turn On Dictation…" with a warning sign, naming the key in its subtitle. It
    (and the toast's button, and Settings → Dictation's "Turn On…") opens Settings → Dictation and the Input
    Monitoring pane;
  - the island says "To dictate with right Option, allow Input Monitoring" for 8 s at launch, when the voice-note key is
    pressed and when Settings opens, at most about once a day (`app.dictation_nudged_at`, 20 h). The ≤ 0.7 once-ever
    flag `app.dictation_prompted` is removed at launch;
  - the listener is re-planned every 3 s; when the key becomes heard the island says "Dictation is on: tap right
    Option to talk".
- Test builds never install a tap or a monitor, or call the request API. They simulate macOS:
  - `BLURT_TEST_DICTATION_TAP=ok|failed` (hook `dictation tap ok|failed`) is what `tapCreate` "answers";
  - `BLURT_TEST_INPUT_MONITORING` / `BLURT_TEST_ACCESSIBILITY` (`dictation im|ax on|off`) are the permissions;
  - `dictation tap disable [stuck]` is the system disabling the tap, `dictation activate` Blurt being activated,
    `dictation heard CODE other|self` a key change as the listener reports it;
  - `dictation nudge REASON` / `dictation setup` drive the cues, and `BLURT_TEST_DICTATION_NUDGE_SECONDS` shortens the
    once-a-day rule.

## Insert

1. Save the general pasteboard: every item, every type, as data.
2. Put the text, marked `org.nspasteboard.TransientType` so clipboard managers skip it.
3. Post ⌘V (HID level). This happens **only** when all of these hold:
   - Accessibility is granted;
   - the AX focused element is not clearly a non-text control (button, list, table, menu…);
   - the focused element's pid equals the frontmost app's pid;
   - that app isn't Blurt.
4. Restore the old pasteboard 0.6 s later, unless something else has changed it since.
- Otherwise the text stays on the clipboard and the island says "已复制，可粘贴" / "Copied — paste it with Command-V".
- Blurt's own windows get a `paste:` action, never a keystroke. Panels (island, note bubble, cards) get nothing.
- **Test builds never post an event or create a tap.** A test build is one with `BLURT_TEST_COMMANDS=1` *or* a bundle
  id other than `dev.blurt.recorder`. In a test build the text goes only into the app's own test pad.

## Polish

`polish.py serve --preload` keeps one MLX model warm:
- 127.0.0.1 with a token, in `$BLURT_HOME/run/polish-serve.json`;
- unloads after 180 s idle and exits after 30 min;
- uses the ASR caps: `asr.limits` threads (3 here), MLX memory limit = 25 % of RAM, utility QoS + nice 10.
  Utility vs user-initiated made no difference to latency (108 vs 118 ms median: the work is on the GPU).

The fixed prompt prefix (rules + 4 examples) is prefilled once and its KV cache copied per request. Thinking is off
(`enable_thinking=False`; `<think>` blocks are stripped anyway). Decoding is greedy, and max tokens = 1.6 × the input.
`run` is the one-shot form (it uses the server when there is one).

Rules, from the user:
- **Allowed:** remove fillers, stutters and repeats; apply self-corrections, keeping only the corrected version; add
  punctuation and paragraphs; fix obvious homophones.
- **Not allowed:** rewrite, summarize, translate, change the tone, answer or carry out the text, or drop content.
  Mixed Chinese and English stays as spoken.

A prompt variant with a "translate this to Japanese" example primed the models to translate and formalize: fall-backs
went 7 % → 22 % (Qwen3 4B) and 12 % → 63 % (Gemma 3 4B). So the examples avoid instruction-shaped sentences.

### Content-loss guard

Every output is checked. On any failure the dictation types the **raw** text, and the history marks it "fell back"
with the reason. Units counted: each CJK character, each Latin word, each digit. Fillers are stripped from the input
before comparing.

| Check | Falls back when |
|---|---|
| `empty` | the output has no units |
| `chatty` | the output starts like an assistant ("好的", "以下是", "Sure", "Here is"…) or says "hope this helps" (and the input didn't) |
| `answered` | the input is a question (a wh-word + auxiliary, a leading auxiliary + subject, 为什么/怎么/吗/…), the output isn't |
| `correction` | the first 4 units after a correction marker (不对, 不是, 我是说, 算了, no wait, I mean, sorry, actually…) aren't all in the output: the model kept the wrong version |
| `translated` | a spoken Latin word vanished while ≥ 2 new CJK characters appeared, or the reverse |
| `shrunk` | loss > max(8 units, 25 % of the filler-free input) + 6 per correction (at most 2) |
| `grew` | output > 1.25 × input + 8 units |
| `novel` | more than max(4, 15 % of output) units that aren't in the input (digits exempt: 五零零 → 500), the custom words or the context |
| `term` | a custom word that was spoken (any case or spacing) is missing from the output |
| `timeout` | no answer within `record.dictation.polish_timeout_ms` (3000) after the model is loaded; the server stops generating at the deadline |
| `error` / `unavailable` | the model raised, or the server never came up |

Why these thresholds:
- Every hand-written reference output in the eval set passes. The largest legitimate shrink is
  "颜色改成蓝色算了还是改成绿色吧" → "颜色改成绿色吧" (−8 units of 15, allowed 20 with its two corrections).
  Without a correction the largest is a few units of fillers and stutters, inside the flat 8.
- A summary or a list rewrite loses 30–60 % of a long input, well past 25 %.
- Short inputs get the flat 8, because one dropped clause in a 12-unit sentence is still a meaningful loss, and a
  pure ratio would allow almost nothing there.
- Homophone fixes add 1–2 new characters (部署, 再), under the novel slack of 4.

On all 410 model outputs of the final run, the guard caught 61 of the 88 outputs that the scripted check marks as
losing a key term or touching an untouched sentence. It fell back on 7 of 322 good outputs (2 %). The 27 it missed
are small losses that stay within the slack: a dropped 我觉得 or 请, an un-fixed homophone. It also misses a model
that leaves a correction unapplied but keeps both versions (no loss).

## Custom words

`$BLURT_HOME/dictation/vocabulary.json`, owned by the app (`BlurtCore/DictationVocabulary.swift`), read by
`scripts/dictation_vocab.py`:

```json
{"schema": 1, "terms": [{"term": "Claude Code", "sounds_like": ["cloud code"], "source": "project",
                         "state": "active", "added": "2026-10-23T13:00:00+08:00", "hits": 3, "seen": 0}]}
```

- `source`: `manual` (Settings), `learned` (from a fix), `project` (the seed). `state`: `active` (used), `suggested`
  (learned once), `rejected` (a suggestion the user ignored: never suggested again), `removed` (a seed the user
  removed: never seeded again). A removed manual word just goes.
- The seed, once per launch and when Settings opens, adds what's missing: Claude Code, Codex, blurt, 口喷鸡 (with the
  misrecognitions the eval found as sounds-likes) and each project's name and key.
- Every dictation request carries the active words. What happens to them:
  1. **ASR biasing** where the model takes it: Qwen3-ASR (MLX) gets an English sentence as its `context` ("Notes
     about Claude Code, Codex, … and Whisper."), Whisper a comma list as `initial_prompt`, Qwen3-ASR (onnx)
     `"; "`-joined hotwords on each stream (an ASCII comma is split and re-joined with spaces by sherpa-onnx, which
     ran the words together). SenseVoice can't be biased: sherpa-onnx only does greedy CTC for it, and
     `create_stream(hotwords=…)` aborts the process ("only transducer models support contextual biasing").
     At most 40 words, the relevant ones first: a sounds-like heard, a word spelled like one, a word in the context,
     then manual before learned before seeded, then by hits.
  2. **The deterministic pass** (`dictation_vocab.apply`, in the ASR server, so it also runs when polish is off): an
     exact sounds-like match becomes the term, and a case / spacing / hyphen variant of a term gets its spelling
     ("sense voice" → "SenseVoice", "ba 12" → "BA-12"). Not when the sounds-like is a single ordinary English word
     ("cloud", "blur") or a single CJK character, and no case fix of a term that is itself an ordinary word ("swift"):
     those are polish's call, since it sees the sentence. Ordinary = a lower-case entry of `/usr/share/dict/words`.
  3. **Polish** gets `Words: …` and `Near the cursor: … ▮ …` lines before `Dictation: …` in the last message (the
     cached prefix is unchanged). The prompt says to write a word that sounds or looks like a listed one the listed
     way, never to add one that wasn't spoken, and never to copy the context. Two examples show it. The guard accepts
     units from the words and the context as not new, accepts a lost Latin word replaced by a similar listed one,
     and adds `term`: a word that was spoken must survive (the eval caught Gemma dropping "口喷鸡在" otherwise).
- `terms_applied` in the history: the words the sounds-like pass or polish wrote, plus listed words in the text when
  the speech model was told about them.

## Context

At the start of a dictation (read while the user talks, off the main thread; `DictationContext`): the focused
element's value around the cursor (500 characters each side, the selection), the focused window's title and the
app's name. Accessibility, read-only, 0.25 s timeouts. Skipped entirely for `AXSecureTextField` (role or subrole),
while secure event input is on, for Blurt's own windows (test builds read only the test pad), and when
`record.dictation.context` is off. Polish gets 300 characters each side; the guard accepts their words. The history
stores only `context_used`; the text itself only with `keep_audio` (the debugging setting).

## Auto-learn

After a paste, `DictationWatch` follows the same AX element (the one focused just before pasting) for 60 s, every
1.5 s:
- It finds the typed text again between 40-character anchors taken around it, nearest to where it went in. Only the
  anchors are held, in memory, and dropped when the watch ends.
- It stops when the focus moves to another element, the anchors vanish or the time is up, and learns from the last
  version it saw. An edit that stood still for one tick is learned right away.
- `DictationLearn.fixes` diffs typed against edited text (LCS over words, numbers and single CJK characters) and keeps
  replaced spans of ≤ 3 words / 4 characters (≤ 4 / 6 after the fix), at most 3, when at least half of the text
  survived. A pair counts when it's alike: same letters ignoring case / spaces / hyphens, normalised edit distance
  ≤ 50 %, cut short (op → option), the same consonant skeleton (cloud → Claude), or close in toneless pinyin
  (口喷机 → 口喷鸡, 克劳德 → Claude). One changed CJK character is learned with the unchanged ones before it. A fix
  to one ordinary word is learned as a phrase with its unchanged neighbour (pool request → pull request); fixes on
  function words (there → their) are grammar, not vocabulary.
- `DictationVocabulary.learn`: a known word gains the sounds-like; a new one is a suggestion, accepted the second time
  the same fix is seen, or at once when it is only case or spacing. The first time a word becomes active, the
  island says *Learned "pull request"* with **Undo** (记住了 pull request · 撤销). Never from secure fields; nothing of
  the surrounding text is kept; `record.dictation.learn` turns it off.

## Recognition model

`record.dictation.asr_model` (unset = automatic: the recommended model when installed, else the voice-note model).
`transcribe.py dictation-models` lists them for Settings → Dictation; nothing is downloaded until **Install**.

Test set: 30 clips of 4.7–7 s made with `say`: 12 mixed Chinese + English terms, 8 Chinese, 10 English (Tingting,
Reed and Eddy zh_CN, Samantha), with 52 expected terms (Claude Code, Codex, blurt, 口喷鸡, tmux, worktree, option,
MLX, Gemma, Qwen, SenseVoice, Typeless, GitHub, pytest, Swift, Xcode, BA-12, Input Monitoring, Accessibility,
Whisper, pull request). Data and scripts: `promo/cases/v0.8-dictation-vocab/asr/` (not in git). Apple M5 Max, CPU
engines at 3 threads, warm models; latency is VAD + decode of one clip. Term accuracy ignores case and spaces / the
second number is exact. "×Reed" leaves out the 4 Reed clips: that voice garbles English for every engine.

Raw ASR, biased where the engine allows:

| Engine | Biasing | Terms | ×Reed | CER zh+mix | WER en | Median / p90 | Cold load | Peak RAM |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| SenseVoice Small | not possible | 38 / 19 % | 47 % | 18.2 % | 9.7 % | 86 / 98 ms | 0.6 s | 0.4 GB |
| Whisper large-v3-turbo (MLX) | none | 60 / 31 % | 67 % | 14.4 % | 7.4 % | 218 / 229 ms | 3.8 s | 3.0–3.5 GB |
| Whisper large-v3-turbo (MLX) | comma list prompt | 81 / 67 % | 86 % | 15.3 % | 1.7 % | 214 / 229 ms | | |
| Qwen3-ASR 0.6B onnx (CPU) | none | 54 / 29 % | 65 % | 17.6 % | 8.0 % | 563 / 638 ms | 1.6 s | 1.9 GB |
| Qwen3-ASR 0.6B onnx (CPU) | `"; "` hotwords per stream | 73 / 56 % | 81 % | 9.8 % | 3.4 % | 640 / 690 ms | | |
| Qwen3-ASR 0.6B MLX 8-bit | none | 62 / 40 % | 74 % | 15.9 % | 6.8 % | 167 / 195 ms | 2.5 s | 2.1 GB |
| **Qwen3-ASR 0.6B MLX 8-bit** | **context sentence** | **83 / 71 %** | **93 %** | 11.1 % | **0 %** | **174 / 195 ms** | | |
| Fun-ASR-Nano int8 | hotwords (rebuild per list) | 69 / 38 % | 77 % | 10.6 % | 4.5 % | 520 / 572 ms | 1.9 s | |
| zipformer zh-en transducer | hotwords fail to encode | 19 / 0 % | 23 % | 24.7 % | 21 % | 58 / 68 ms | | |

The whole dictation: those outputs → the sounds-like pass → Gemma 4 E2B polish with the 21 words (the seed's
sounds-likes, the rest by hand) and, for "+ctx", a release-notes paragraph as the text around the cursor.
`e2e_vocab.py`; Whisper's CER is after converting its traditional characters to simplified (13.1 % as typed).

| Pipeline | Terms | ×Reed | CER zh+mix | WER en | Fall-backs | Total median / p90 |
|---|---:|---:|---:|---:|---:|---:|
| SenseVoice, polish without words | 50 / 35 % | 60 % | 17.9 % | 4.5 % | 4 | 212 / 238 ms |
| SenseVoice + polish with words + ctx | 64 / 62 % | 74 % | 14.8 % | 4.0 % | 4 | 219 / 246 ms |
| Whisper turbo (prompt) + polish with words + ctx | 88 / 79 % | 95 % | 7.0 % | 1.1 % | 6 | 360 / 381 ms |
| Qwen3-ASR onnx (hotwords) + polish with words + ctx | 81 / 71 % | 91 % | 9.8 % | 2.3 % | 3 | 782 / 840 ms |
| Qwen3-ASR MLX (context), polish off | 86 / 79 % | 98 % | 10.8 % | 0 % | — | 175 / 195 ms |
| **Qwen3-ASR MLX (context) + polish with words + ctx** | **86 / 81 %** | **98 %** | 10.8 % | **0 %** | 3 | **314 / 358 ms** |

**Default: Qwen3-ASR 0.6B MLX 8-bit** (`qwen3-asr-0.6b-mlx`, Apple silicon pro / standard tiers):
- the most terms of anything that fits the budget (98 % outside the Reed clips), no English errors, simplified Chinese;
- 0.17 s of ASR and about 0.31 s with polish after the key is released; 1.0 GB download, 2.1 GB of memory;
- it never hallucinated on silence or noise, while Whisper's prompt leaked into one output and looped for 3–5 s
  with a sentence-style prompt, and it writes traditional Chinese.
- Whisper turbo is offered (the best CER after conversion, 3.5 GB); SenseVoice stays the fallback (no biasing, but
  the words still help through the sounds-like pass and polish: 50 → 64 %); Qwen3-ASR onnx for Macs without MLX is
  too slow for dictation here (0.64 s before polish).

What the misses look like without biasing: Claude → cloud / cloth, blurt → Blur / blt, option → op (in Chinese
speech), 口喷鸡 → 口喷机 / 鲲机, tmux → mux / Tmox, worktree → work tree, Codex → Codec / Kodex, Qwen → Qu / 坤,
Gemma → jamer, pytest → pi dust, BA-12 → "B A twelve", GitHub → jitop. With biasing what remains: 口喷鸡 → 口喷机
(the sounds-like pass fixes it), Qwen inside Chinese speech, "Sense Voice" as two words (the spelling pass fixes it).

The 41-case polish eval with the new prompt (no words, no context, so the same path as before): Gemma 4 E2B 2.4 %
fall-backs, similarity 0.946 (model) / 0.970 (final), every untouched sentence kept, fillers removed 91 % (97 %
before: one 那个 more is kept). Putting the two custom-word examples after the old four made it translate en-04 into
Chinese and leave a correction unapplied; before them, nothing else changed.

## Evaluation

Setup:
- 41 disfluent sentences in `tests/fixtures/polish_eval.jsonl`: Chinese, English and mixed. They include
  self-corrections, code and product terms, numbers, homophones, questions and instructions that must not be answered
  or carried out, and 7 clean sentences that must come back untouched.
- Each case has must-keep and must-drop terms and a reference output.
- Run with `polish.py eval --model ID`: one process per model, in-process (no server), utility priority, 3 threads,
  25 % memory cap.
- Machine: Apple M5 Max, 128 GB, mlx-lm 0.32.2 / mlx 0.32.4.
- Models: the newest small instruct releases on `mlx-community` as of Oct 2026. Qwen3.5 (Mar 2026) is the newest small
  Qwen; Qwen3.8 only comes as 27B / Flash. Gemma 4 E2B / E4B (Apr 2026). Plus Qwen3 and Gemma 3 for comparison.
- All 4-bit. No Llama.

Columns:
- *Cold*: load + first sentence.
- *Warm*: per sentence once loaded.
- *Kept (model)*: the model's own output has every must-keep term.
- *Kept (final)*: the same, after the guard (a fall-back types the raw text).
- *Fillers removed*: of the filler words in the inputs.
- *Untouched kept*: clean sentences unchanged (letters and digits).
- *Similarity*: to the reference, after the guard.

| Model | Download | Peak RAM | Cold | Warm (median / p90) | Fall-back | Kept (model) | Kept (final) | Fillers removed | Untouched kept | Similarity |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Gemma 3 1B | 0.7 GB | 1.7 GB | 2.4 s | 110 / 192 ms | 10 % | 85 % | 95 % | 35 % | 71 % | 0.910 |
| **Gemma 4 E2B** | 3.3 GB | 3.5 GB | 2.5 s | 108 / 205 ms | **2 %** | 95 % | 98 % | **97 %** | **100 %** | 0.970 |
| Gemma 3 4B | 2.8 GB | 3.7 GB | 2.9 s | 149 / 295 ms | 12 % | 85 % | 95 % | 85 % | 86 % | 0.962 |
| Gemma 4 E4B | 4.8 GB | 5.1 GB | 3.9 s | 199 / 383 ms | 0 % | 98 % | 98 % | 91 % | 100 % | **0.987** |
| Qwen3 0.6B | 0.3 GB | 1.3 GB | 1.5 s | 66 / 127 ms | 46 % | 61 % | 98 % | 38 % | 86 % | 0.923 |
| Qwen3.5 0.8B | 0.6 GB | 1.5 GB | 1.9 s | 78 / 140 ms | 39 % | 54 % | 90 % | 50 % | 71 % | 0.911 |
| **Qwen3 1.7B** | 0.9 GB | 2.1 GB | 1.6 s | 84 / 152 ms | 24 % | 78 % | 95 % | 76 % | 100 % | 0.937 |
| Qwen3.5 2B | 1.6 GB | 2.3 GB | 2.1 s | 85 / 158 ms | 20 % | 71 % | 88 % | 76 % | 86 % | 0.933 |
| Qwen3 4B Instruct 2507 | 2.1 GB | 3.3 GB | 1.7 s | 126 / 213 ms | 7 % | 88 % | 95 % | 91 % | 100 % | 0.969 |
| Qwen3.5 4B | 2.9 GB | 3.7 GB | 2.2 s | 135 / 252 ms | 5 % | 93 % | 98 % | 82 % | 100 % | 0.963 |

Notes, including my own reading of every output:
- **Gemma 4 E2B** does exactly the job. It removes fillers almost everywhere and applies Chinese self-corrections
  correctly: 发给小王哦不是发给小李 → 发给小李, which both 4B Qwens got wrong (they kept 小王, and the guard caught it).
  It keeps English terms in mixed sentences and leaves clean sentences alone. Its single fall-back was carrying out
  "translate this into English".
- **Qwen3.5 4B** is as safe, but leaves more fillers (嗯, 就是说, 那个) and once turned a spoken list into a numbered
  list. Qwen3 4B 2507 is close behind and faster to load.
- **Gemma 4 E4B** is the best on similarity with zero fall-backs, but it is a 4.8 GB download, needs 5.1 GB, and takes
  ~0.2 s per sentence. It's an option on Pro Macs, not the default.
- Under 2B every model needs the guard constantly:
  - The Qwen 0.6–0.8B models translate mixed text into English, answer questions and apply corrections backwards.
  - Gemma 3 1B mostly just adds a full stop.
  - Qwen3 1.7B is the smallest that removes most fillers (76 %) with the guard catching the rest.
- Latency is never the problem on Apple silicon of this class: warm polish is 0.07–0.2 s per sentence. In the
  end-to-end run, a 9 s Chinese dictation took ASR 150 ms + polish 165 ms (Qwen3.5 2B, before the default changed).

**The user's prior (Qwen is better) is refuted at the size that matters.** At ~2–4 GB of memory, Gemma 4 E2B has
2 % fall-backs against Qwen3.5 2B's 20 % and Qwen3.5 4B's 5 %, and removes the most fillers. Qwen is still the
better choice under 2 GB, where Gemma 4 has no model.

### Defaults by hardware tier

`polish_models.json` `defaults`; tiers from `transcribe.py probe`. The polish process is capped at 25 % of RAM.

| Tier | Macs | Cap | Default |
|---|---|---:|---|
| pro | Apple silicon ≥ 32 GB | 8 GB | Gemma 4 E2B (Gemma 4 E4B and Qwen3.5 4B offered) |
| standard | 16–24 GB | 4 GB | Gemma 4 E2B (3.5 GB peak) |
| light | 8 GB | 2 GB | Qwen3 1.7B (2.1 GB peak; MLX's limit is relaxed, so it slightly overshoots instead of failing) |
| minimal | < 8 GB | — | Gemma 3 1B (rarely harmful, rarely useful) |

Nothing is downloaded until the user presses **Install** in Settings → Dictation. The size is shown, and the download
comes from Hugging Face, or from ModelScope when the download mirror is on (it mirrors mlx-community, and is fast from
mainland China). Until then dictation types the raw transcript. `mlx-lm` is added with `uv run --with` on first use
(through a PyPI mirror when the mirror is on).

## History

`$BLURT_HOME/dictation/history.jsonl` is append-only:
- one line per dictation: `id`, `t`, `app`, `bundle`, `duration`, `raw` (what the speech model wrote), `polished`
  (or null), `text` (what was typed), `model`, `fell_back`, `reason`, `insert` (pasted | copied | none), `audio`,
  `asr_model`, `language`, `terms_applied` (custom words it wrote), `context_used` (the text around the cursor went
  to polish), `context` (that text, only with `keep_audio`). Older lines lack the last three: read as unknown.
  `prune` rewrites lines through `DictationEntry.json`, which carries them;
- edit lines: `{"op":"delete","ids"}`, `{"op":"item","id","item","uid"}`, `{"op":"clear"}`.

Retention (`record.dictation.retention_days`, 30) rewrites the file at launch and when the setting changes. Audio
(`dictation/audio/<id>.wav`) is deleted after transcription unless `keep_audio` is on.

*Turn into item* runs `dictation.py item ID --project <current|inbox>`. That calls `items.py add` with:
- `title` = the first sentence, `quote` = the whole text;
- `kind` from the capture keyword guess;
- `source.type = "dictation"`, `source.app`;
- `enrich: pending`.

## Settings (`record.dictation.*`)

| Key | Default |
|---|---|
| `enabled` | `true` |
| `key` | `right_option` \| `fn` |
| `mode` | `tap` \| `hold` |
| `polish` | `light` \| `off` |
| `polish_model` | by tier |
| `polish_timeout_ms` | `3000` |
| `polish_priority` | `utility` |
| `retention_days` | `30` |
| `keep_audio` | `false` (also keeps the context in the history: debugging) |
| `asr_model` | automatic (Qwen3-ASR MLX when installed on Apple silicon, else the voice-note model) |
| `context` | `true`: read the text around the cursor for polish |
| `learn` | `true`: watch the field after typing and learn the user's fixes |

## Verification

- `swift test --filter DictationTriggerTests` (14 cases), and the `--selftest` checks `dictation_trigger` and
  `dictation_history` (no XCTest needed).
- `pytest tests/test_polish.py tests/test_dictation.py tests/test_dictation_vocab.py` (the sounds-like pass, ranking,
  prompt formats, the guard with words and context, the biased note path with a fake backend, dictation-models).
- `swift test --filter 'DictationListenerTests|DictationVocabularyTests|DictationLearnTests|DictationHistoryTests'`
  (recreate plans, the store, learn-from-diff, the new history fields surviving prune), selftest `dictation_listener`,
  `dictation_vocab`.
- In the isolated test build (`dev.blurt.recorder.vocabtest`), simulated permissions: launch without Input
  Monitoring → `tap_local`, needs setup; `dictation im on` → the poll made the tap again (generation 2) and the
  island said dictation is on; `tap disable` re-enabled it, `tap disable stuck` made it again (generation 3);
  Input Monitoring off + Accessibility on → `monitor`; `heard 61 other` set *Last heard in another app*.
- End to end in the same build with `say` audio and the test pad holding a document: Qwen3-ASR MLX biased (0.2 s
  warm), the context read (`context_used`), polish, pasted into the pad, the watch started. Editing "pool request"
  → "pull request" in the pad made a suggestion, the second time *Learned "pull request"* with Undo, and the next
  dictation wrote "pull request" (`terms_applied`). "Option 键" → "option 键" was learned at once (case only).
- End to end in an isolated test build: `dev.blurt.recorder.dicttest`, launched through LaunchServices so it holds no
  permission grants.
  1. A synthetic right-⌥ tap goes into the trigger through the test hook (`dictation keys …`).
  2. `say`-generated audio stands in for the mic.
  3. Warm SenseVoice, then the polish server.
  4. The text is pasted into the app's own test pad, and the pasteboard is restored.
  5. A history entry is written.
- Not verified here (only the user can): right ⌥ pressed while another app is in front, with the real tap after
  granting Input Monitoring (Settings shows *Last heard in another app*), and with Accessibility alone (the monitor);
  ⌘V into another app; the real AX context and the after-typing watch in real apps (Notes, Mail, a browser,
  Electron editors, terminals — some expose no AX value, and then there is simply no context and no learning).
  They need real grants, and reading or posting into other apps on this machine is off-limits for tests.
