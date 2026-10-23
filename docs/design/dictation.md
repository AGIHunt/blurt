# Dictation (听写) — v0.8, macOS

Typeless-style dictation: you talk, and the words are typed into **whichever app has the focus**. It is separate from
the voice note: `⌥⇧V` still files what you say into Blurt, and the two never share a key.

## Flow

```
right ⌥ tap ──▶ DictationTrigger ──▶ NoteVoice (mic → 16 kHz wav) ──▶ ASR (warm transcribe.py serve)
  (listen-only CGEventTap)  │ arm: warm ASR + polish servers           │
                            ▼                                         ▼
                   island ears: keyboard + mint level      polish (warm polish.py serve, ≤ 3 s, guard)
                                                                      │
          history.jsonl ◀── DictationInsert: save pasteboard → text → ⌘V → restore after 0.6 s
```

| Piece | Where |
|---|---|
| Trigger state machine (pure, unit-tested) | `BlurtCore/DictationTrigger.swift`, `Tests/BlurtCoreTests/DictationTriggerTests.swift`, selftest `dictation_trigger` |
| Event tap, permissions | `Capture/Dictation/DictationKeys.swift` |
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
- Permissions: Input Monitoring for the tap, Accessibility for the paste. A listen-only keyboard tap needs Input
  Monitoring: without it `CGEvent.tapCreate` returns nil, whatever Accessibility says. So "dictation works" means
  **the tap is installed**, never a permission check, and Settings → Dictation shows that state on its own row.
- Until the tap is installed (BlurtCore `DictationAccess` decides; `DictationAccessTests`):
  - at launch, `CGRequestListenEventAccess()` once per app version (`app.dictation_asked_version`), never while the
    setup assistant shows (it has its own row). This shows macOS's prompt and lists Blurt under Input Monitoring;
  - the menu-bar menu's first row is "Turn On Dictation…" with a warning sign, naming the key in its subtitle. It
    (and the toast's button, and Settings → Dictation's "Turn On…") opens Settings → Dictation and the Input
    Monitoring pane;
  - the island says "To dictate with right Option, allow Input Monitoring" for 8 s at launch, when the voice-note key is
    pressed and when Settings opens, at most about once a day (`app.dictation_nudged_at`, 20 h). The ≤ 0.7 once-ever
    flag `app.dictation_prompted` is removed at launch;
  - the app retries the tap every 3 s; when it comes up the island says "Dictation is on: tap right Option to talk".
- Test builds never install a tap or call the request API: `BLURT_TEST_DICTATION_TAP=ok|failed` (or the hook
  `dictation tap ok|failed`) is what `tapCreate` "answers", `dictation nudge REASON` / `dictation setup` drive the
  cues, and `BLURT_TEST_DICTATION_NUDGE_SECONDS` shortens the once-a-day rule.

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
| `novel` | more than max(4, 15 % of output) units that aren't in the input (digits exempt: 五零零 → 500) |
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
- one line per dictation: `id`, `t`, `app`, `bundle`, `duration`, `raw`, `polished` (or null), `text` (what was
  typed), `model`, `fell_back`, `reason`, `insert` (pasted | copied | none), `audio`, `asr_model`, `language`;
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
| `keep_audio` | `false` |

## Verification

- `swift test --filter DictationTriggerTests` (14 cases), and the `--selftest` checks `dictation_trigger` and
  `dictation_history` (no XCTest needed).
- `pytest tests/test_polish.py tests/test_dictation.py`.
- End to end in an isolated test build: `dev.blurt.recorder.dicttest`, launched through LaunchServices so it holds no
  permission grants.
  1. A synthetic right-⌥ tap goes into the trigger through the test hook (`dictation keys …`).
  2. `say`-generated audio stands in for the mic.
  3. Warm SenseVoice, then the polish server.
  4. The text is pasted into the app's own test pad, and the pasteboard is restored.
  5. A history entry is written.
- Not verified here: the real event tap and ⌘V into another app. They need real Input Monitoring and Accessibility
  grants, and posting into other apps on this machine is off-limits for tests. Verify them by hand.
