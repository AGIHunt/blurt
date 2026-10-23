# Dictation (听写) — v0.8, macOS (with the v0.8 speed work: streaming, start of speech, paste, repair)

Typeless-style dictation: you talk, and the words are typed into **whichever app has the focus**. It is separate from
the voice note: `⌥⇧V` still files what you say into Blurt, and the two never share a key.

## Flow

```
Fn down ──▶ DictationTrigger ── arm ──▶ the mic opens now (MicEngine: prepared at launch, started off the main thread)
  (DictationListener: tap   │            + warm ASR / polish servers (offline-first spawn)
   or AX monitor)           │ start (key-up of a tap, or 300 ms held): keeps that audio; the text around the cursor
                            ▼
      NoteVoice (16 kHz) ──▶ DictationStream: DictationSegmenter cuts at pauses ≥ 0.5 s (pieces 3–20 s)
      island: "listening" once        │ each piece, while the user still talks:
      audio actually arrives          ├─▶ ASR (warm transcribe.py serve; custom words + the text so far as context)
                                      └─▶ polish (warm polish.py serve; the polished text so far as "before the
                                          cursor"; the guard, and the repair that puts dropped words back)
      key-up ──▶ only the last piece is left ──▶ DictationStitch joins the pieces ──▶ the joined guard
                                                                      │
          history.jsonl ◀── DictationInsert: ⌘V into any app in front (DictationPastePolicy) → clipboard restored
          (timings: asr / polish / load / total ms)                   │
          vocabulary.json ◀── DictationWatch: the same field for 60 s → DictationLearn: the user's fixes
```

| Piece | Where |
|---|---|
| Trigger state machine, double tap (pure, unit-tested) | `BlurtCore/DictationTrigger.swift`, `Tests/BlurtCoreTests/DictationTriggerTests.swift`, selftest `dictation_trigger` |
| Which listener runs (pure, unit-tested) | `BlurtCore/DictationListener.swift`, `DictationListenerTests`, selftest `dictation_listener` |
| Event tap / Fn filter / monitor | `Capture/Dictation/DictationKeys.swift` |
| Permission guide: walk order, 🌐 setting, docking (pure, unit-tested) | `BlurtCore/PermissionFlow.swift`, `PermissionFlowTests`, selftest `permission_flow` |
| Permission guide: flow, helper panel, macOS reads / requests, test hooks | `Onboarding/PermissionGuide.swift`, `Onboarding/HelperPanel.swift`, `Onboarding/SystemAccess.swift`, `Onboarding/PermissionTestHooks.swift` |
| Custom words: store, seed, learning (pure, unit-tested) | `BlurtCore/DictationVocabulary.swift`, `BlurtCore/DictationLearn.swift`, `DictationVocabularyTests`, selftest `dictation_vocab` |
| Context, the after-typing watch | `Capture/Dictation/DictationContext.swift` |
| Custom words in ASR and polish | `scripts/dictation_vocab.py`, `transcribe.py` (`note --dictation --vocab`, `dictation-models`), `polish.py`, `tests/test_dictation_vocab.py` |
| Controller (capture → ASR → polish → insert → history) | `Capture/Dictation/Dictation.swift` |
| Streaming: cut, transcribe and polish while talking; punctuation at the seams (pauses, polish windows) | `Capture/Dictation/DictationStream.swift`; pure: `BlurtCore/DictationSegmenter.swift` (cuts, pause lengths), `BlurtCore/DictationStitch.swift` (joins, `seam`, `commitSplit`) (`DictationSegmenterTests`, `DictationStitchTests`) |
| The mic: engine prepared at launch, built-in mic choice | `Capture/NoteBubble.swift` (`NoteVoice`, `MicEngine`, `AudioDevices`); pure: `DictationMicChoice` |
| Insertion, fitting at the cursor, Return for a double tap | `Capture/Dictation/DictationInsert.swift`; the rules: `BlurtCore/DictationPastePolicy.swift` (`DictationPastePolicy`, `DictationSendPolicy`; `DictationPastePolicyTests`), `BlurtCore/DictationFit.swift` (`DictationFitTests`) |
| Warm-server client (no `uv run` per request) | `BlurtCore/WarmServer.swift` |
| History file | `BlurtCore/DictationHistory.swift`, `scripts/dictation.py` (list / prune / turn into item) |
| Polish model + guard + repair + eval | `scripts/polish.py`, `scripts/polish_models.json`, `tests/fixtures/polish_eval.jsonl`, `tests/fixtures/polish_overdelete.jsonl`, `tests/test_polish.py` |
| UI | island ears (`Island/Ears.swift`), Settings → Dictation (`Settings/DictationPane.swift`), the main window's Dictation page (`MainWindow/DictationPage.swift`: a sidebar place; the menu-bar menu, `⌥⌘D` and the palette open it) |

## Trigger

- **Fn** (keyCode 63, `.maskSecondaryFn`) by default, like Typeless; or right ⌥ (keyCode 61, device bit
  `NX_DEVICERALTKEYMASK` 0x40), or either ⌥ (keyCodes 58 / 61, `NX_DEVICELALTKEYMASK` 0x20 / 0x40: whichever side is
  tapped alone; both sides at once is not a tap). Pickers list Fn first.
  - Migration: `record.dictation.key` unset = Fn. ≤ 0.8 stored nothing for right ⌥ (the old default), so a user who
    never changed the key gets Fn; any key picked from now on is stored explicitly, the default included.
  Modifier-only keys can't be Carbon hotkeys, so an event tap (`flagsChanged`, `keyDown`, mouse down) feeds the state
  machine: the Fn filter (below) when the key is Fn, else a **listen-only** tap that never blocks or changes an event.
- **Auto** (default, `mode` unset): a clean press released within 300 ms (`autoHold`) starts hands-free and the next
  clean press stops it (however long); held alone for 300 ms (the caller ticks at `deadline`) is push-to-talk and
  release stops it. `pushToTalk` tells the app which (push-to-talk has no "nothing said" timeout). Another key or a
  click while held cancels push-to-talk; a stop press that turned into a shortcut doesn't stop.
- **Tap**: down and up within 400 ms, no other key, modifier or click in between, and no other modifier held
  when it went down. One tap starts, the next stops. So ⌥-letter, ⌥⇧V and Fn-← never trigger.
- **Hold**: held alone for 250 ms starts (the caller ticks at `deadline`), release stops, and another key or a click
  joining in cancels.
- `Esc` cancels. `arm` on a clean key-down warms the models and opens the mic while the user starts talking
  (§Start of speech).
- **Double tap = Return ("send")** — `record.dictation.double_tap_send`, on by default; Settings → Dictation 「双击 Fn
  发送（回车）」 / "Double-tap Fn to send (Return)", named after whichever key is set. In chat apps the user presses
  Return after ~80 % of dictations; now two quick taps do it. Two clean taps, the second going down within 300 ms
  (`doubleTapWindow`) of the first one's release, give `.send` (BlurtCore `DictationTrigger`, `DictationTriggerTests`).
  The first tap is never delayed: it does what it always did, at once, and the second one decides:
  - **idle** (auto / tap mode): the first tap started a dictation; the second cancels it (`.cancel`: audio dropped,
    nothing pasted, no history entry) and Return goes to the app in front now;
  - **dictating** ("dictate, then send", the useful case): the first tap stopped it and the paste starts as usual; the
    second one (no mic opened for it) queues Return, posted once `DictationInsert` reports the paste done — after the
    clipboard comes back (0.6 s), so the ⌘V has landed. Not when the text was only copied (secure input, Blurt in
    front …) or nothing was heard: Return would then send something else;
  - **push-to-talk** (hold mode, or auto held): letting go stops it; a tap within 300 ms of the release sends it the
    same way. In hold mode two quick taps (which start nothing there) press Return;
  - a second press held past the hold threshold is push-to-talk as usual; one joined by another key or a click
    (Fn-←, ⌘), or any key / click between the taps, is never a double tap; a third tap starts afresh.
  - Return is a `CGEvent` (`kVK_Return`, no modifiers, HID level) posted only when `DictationSendPolicy` allows it:
    another app in front (never Blurt), secure input off, Accessibility granted (the Fn filter already needs it).
    The island says 「已发送 ↩︎」 / "Sent ↩︎" for a moment. Test builds never post it: `dictation_test_send` logs
    "would press Return" (with the hooks' simulated Accessibility), and `dictation send-policy front=… secure=… ax=…`
    reports the policy.
  - Price: two quick taps no longer mean "start, then stop at once" (that dictated nothing anyway); someone used to
    macOS's "Press 🌐 twice" for system dictation now sends Return instead.
- Off while a screen recording runs (it owns the mic) and while a voice note listens; both cases show a toast.
- Permissions: Accessibility for the paste, the context and the Fn filter; Input Monitoring for the listen-only tap.
- **The Fn filter.** macOS uses Fn itself (System Settings → Keyboard → "Press 🌐 key to", `com.apple.HIToolbox
  AppleFnUsageType`: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation — on macOS 26.5
  value 3 shows as "Start Dictation (Press 🌐 Twice)", checked against System Settings on this Mac; 0–2 follow the
  same order but weren't switched to, since tests never write that setting). When the key is Fn,
  `record.dictation.fn_capture` is on (default) and Accessibility is granted, the listener is an **active** tap
  (`.cghidEventTap`, `.headInsertEventTap`, `.defaultTap`) on a thread of its own: it drops `flagsChanged` of keyCode
  63 and passes every other event untouched at once (the callback copies the key code and flags and hands them to the
  main thread). macOS gives an Accessibility-trusted app's filter every app's events, so Fn is heard without Input
  Monitoring. Typeless 2.8.1 does the same: its `libKeyboardHelper.dylib` creates a HID-level head-insert default tap
  (keyDown / keyUp / flagsChanged / other mouse buttons) and returns NULL for the events its shortcut matches, and it
  isn't in the Input Monitoring list here. Whether dropping the press stops macOS's 🌐 action on macOS 26 can only be
  checked with a real Fn press (below), so Settings and the guide still offer the "Do Nothing" step when the setting
  isn't 0. If macOS refuses the filter, `filterRefused` sends the plan to the listen-only tap / monitor until
  Accessibility or the key changes. Typeless (`now.typeless.desktop`) and Wispr Flow (`com.electron.wispr-flow`)
  running are named in Settings → Dictation and the assistant: both apps would react to Fn.
- **Which listener** (BlurtCore `DictationListener`, `DictationListenerTests`). The bug it fixes: a listen-only tap
  made at launch **before** Input Monitoring was granted is accepted by macOS, but it only gets the events aimed at
  Blurt itself, and macOS never upgrades it. `start()` returned early because the tap existed, and the status said
  "installed", so right ⌥ worked only while Blurt was in front.
  - `CGPreflightListenEventAccess()` is the truth. A tap counts as global only when it was made with Input
    Monitoring (Accessibility for the Fn filter) and the grant is still there (`kind`: `tap` | `tap_local` | `monitor`
    | `none`). Steps: `create_tap`, `recreate_tap`, `create_filter_tap`, `recreate_filter_tap`, `remove_tap`,
    `install_monitor`, `remove_monitor`.
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
  - macOS is never asked at launch (≤ 0.8 called `CGRequestListenEventAccess()` once per version). The request APIs
    run when the user clicks Allow / Set Up (§Permissions);
  - the menu-bar menu's first row is "Turn On Dictation…" with a warning sign, naming the key in its subtitle. It
    (and the toast's button, Settings → Dictation's "Turn On…" and the Dictation page) opens Settings → Dictation and
    starts the permission guide's dictation walk;
  - the island says "To dictate with Fn, Blurt needs a permission" for 8 s at launch, when the voice-note key is
    pressed and when Settings opens, at most about once a day (`app.dictation_nudged_at`, 20 h). The ≤ 0.7 once-ever
    flag `app.dictation_prompted` is removed at launch;
  - the listener is re-planned every 3 s (and at once from the guide's poll); when the key becomes heard the island
    says "Dictation is on: tap Fn to talk, or hold it".
- Test builds never install a tap or a monitor, or call the request API. They simulate macOS:
  - `BLURT_TEST_DICTATION_TAP=ok|failed` (hook `dictation tap ok|failed`) is what `tapCreate` "answers";
    `BLURT_TEST_FILTER_TAP` / `dictation filter ok|failed` the Fn filter's, and `dictation filter-event CODE` reports
    whether the filter would drop that key change;
  - `BLURT_TEST_INPUT_MONITORING` / `BLURT_TEST_ACCESSIBILITY` (`dictation im|ax on|off`) are the permissions;
  - `dictation tap disable [stuck]` is the system disabling the tap, `dictation activate` Blurt being activated,
    `dictation heard CODE other|self` a key change as the listener reports it;
  - `dictation nudge REASON` / `dictation setup` drive the cues, and `BLURT_TEST_DICTATION_NUDGE_SECONDS` shortens the
    once-a-day rule.

## Start of speech

What the user's history showed (B): the first two or three words of a dictation were missing from the transcript —
the first ~0.5–1 s was never recorded. Two causes, both measured in the test build with a wav whose speech starts at its first sample, played as
the world's sound since the key went down (`BLURT_TEST_MIC_CLOCK=keydown`) through a simulated mic that takes
`BLURT_TEST_MIC_START_MS` to deliver its first buffer (a synthetic sentence that starts with a two-character
pronoun + verb; `promo/cases/v0.8-dictation-speed/results/clipped-start.jsonl`):

| Mic start-up | Press | Mic opened at the trigger's start (v0.8) | Mic opened on the key-down (now) |
|---:|---|---|---|
| 0 ms | tap | audio from 126 ms; all words kept | from 5 ms; all kept |
| 0 ms | hold (push-to-talk) | from 315 ms: **the first 4 words lost** (B's symptom) | from 6 ms; all kept |
| 150 ms | tap / hold | from 286 / 469 ms: the first word / 4 words lost | from 162 ms: the first word lost |
| 1000 ms (Bluetooth HFP) | tap / hold | from 1180 / 1322 ms: 5 / 6 words lost | from 1009 / 1054 ms: 5 words lost |

1. **The trigger decided late.** The mic opened at `start`: the key-up of a tap (~0.1 s) or 300 ms into a hold — and
   the engine was then made on the main thread. Now `arm` (the clean key-down) opens it, `start` keeps that audio,
   and a press that turns into something else (Fn-←, ⌥A, a click, let go too late) closes it again and drops it
   (`DictationTrigger.armedDown`; `dictation_precapture_dropped`). The price: the orange mic dot flashes for a
   moment on an Fn-arrow shortcut. `record.dictation.precapture` (default on) switches it off.
2. **The device takes time to start.** `MicEngine` makes the `AVAudioEngine` and its input node at launch (only when
   microphone access is already granted; nothing runs, so macOS shows no mic in use) and starts it off the main
   thread. That removes the engine set-up, not the device's own start-up. A Bluetooth headset (AirPods) switches to
   its call profile (HFP) when its mic opens: ~1 s with no audio, which no software can get back without keeping
   the mic open all the time (a pre-roll before the key-down would need exactly that: not done). So:
   - **"Use the Mac's microphone for dictation"** (`record.dictation.builtin_mic`; Settings → Dictation): unset =
     automatic, on while the default input is Bluetooth (CoreAudio transport type), when the Mac has a built-in mic.
     The input unit's device is switched before it starts. Trade-off: the built-in mic is ready at once and the
     headset's music keeps its quality (HFP drops it to call quality), but it is farther from the mouth and hears
     more of the room. `DictationMicChoice` (pure, tested) decides.
   - **The island says "listening" only once audio arrives** (`NoteVoice.onFirstAudio` → `Dictation.micLive`):
     until then the keyboard glyph with dots (`shots/island-mic-starting.png`), then the mint level and the clock
     (`shots/island-listening.png`). `dictation_mic_live` records `from_key_ms`.
   - An optional soft tick when listening starts (`record.dictation.start_sound`, off; never while recording).
- Only the user can measure the real devices: the built-in mic's start-up and AirPods' HFP switch on their Mac
  (`dictation_mic_live.from_key_ms` in the log), and whether the prepared engine really leaves the mic indicator off.

## Permissions (the guide)

Granting a permission used to mean System Settings, "+", and hunting for the app. The guide does what CleanShot,
Raycast or Loom do (`BlurtCore/PermissionFlow.swift` + `Onboarding/PermissionGuide.swift`, `HelperPanel.swift`,
`SystemAccess.swift`):

- **One walk, the missing ones in order.** `all` (the setup assistant, Settings → Privacy): Screen Recording,
  Microphone, Accessibility, Input Monitoring, the 🌐 key. `dictation` (Settings → Dictation, the menu row, the
  island's button, the Dictation page): Accessibility, Input Monitoring, Microphone, the 🌐 key. A row's *Allow…*
  walks just that one. A step is skipped when satisfied: Input Monitoring once the key is heard by a tap (the Fn filter
  needs only Accessibility); the 🌐 key once Fn isn't the key, dictation is off, or `AppleFnUsageType` is 0.
- **Register first, on the user's click** (never at launch): `CGRequestScreenCaptureAccess()`,
  `AVCaptureDevice.requestAccess` (macOS's dialog; no pane), `AXIsProcessTrustedWithOptions(prompt: true)`,
  `CGRequestListenEventAccess()`. Each lists Blurt in the pane (and shows macOS's own prompt the first time), so the
  user only flips a switch.
- **The exact pane**, 0.35 s later: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` /
  `Privacy_Microphone` / `Privacy_Accessibility` / `Privacy_ListenEvent`, and
  `x-apple.systempreferences:com.apple.Keyboard-Settings.extension` for the 🌐 key. All five open the right page on
  macOS 26.5 (checked by window title and screenshots of the System Settings window).
- **The helper panel**: a non-activating floating `NSPanel` docked next to the System Settings window. Its frame comes
  from `CGWindowListCopyWindowInfo` — only bounds, owner pid (`com.apple.systempreferences`) and layer are read —
  every 0.25 s, so the panel follows the window. `HelperDock`: right of the window if it fits on that screen, else left,
  else inside its lower right corner; no window = the screen's top right with *Open System Settings*. It shows: step
  N of M and the name, one line ("Turn on Blurt here"; the 🌐 step: 「把『按下 🌐 键时』设为『不执行任何操作』」; the
  microphone: "Click Allow in macOS's prompt"), an arrow toward the window, why it's needed, a **Blurt tile to drag
  into the list** (an `NSDraggingSource` whose pasteboard item is the app bundle's file URL, as Finder's drag of an app
  — for the "+" lists), every step with its live state, *Skip* and a close button.
- **Detect, then move on**: every 0.5 s while the panel shows. Accessibility or Input Monitoring changing re-plans
  dictation's listener at once (the tap made before the grant is made again). A satisfied step shows its check for
  0.8 s, then the next one opens. At the end the panel says "Done — …" for a moment and goes; Blurt is activated and
  the window the walk started from comes back (`orderFrontRegardless`, also when macOS keeps the focus on System
  Settings) with a check-mark line: "Done — dictation works in every app now." (dictation works) / "Done — Blurt has
  every permission it needs." / "Done for now — allow the rest here any time." (something skipped).
- **Screen Recording** may need a relaunch: the panel's step and Settings → Privacy have *Restart Blurt*
  (`open -n` of our own bundle once this process has exited, then terminate; the rest of the walk is kept in
  `app.permission_resume` and continues after the relaunch, within 10 minutes).
- Blurt never clicks, scripts or writes anything in System Settings, and never writes `AppleFnUsageType`.
- Test builds never register, never open a pane (unless `BLURT_TEST_OPEN_PANES=1`) and never relaunch; they emit
  `perm_request` / `perm_open_pane` / `perm_relaunch`. States are simulated with `BLURT_TEST_SCREEN_RECORDING`,
  `BLURT_TEST_MICROPHONE` (granted | denied | not_asked), `BLURT_TEST_ACCESSIBILITY`, `BLURT_TEST_INPUT_MONITORING`,
  `BLURT_TEST_FN_USAGE`, `BLURT_TEST_FN_APPS`, or the `perm …` hooks (`perm screen|mic|ax|im|fn …`, `perm guide`,
  `perm skip|cancel|restart`, `perm standin …` — a window of the test app standing in for System Settings —, `perm drag
  PB`, `perm status`).

## Streaming

Before, everything waited for the key to come up: the whole recording to the speech model, then the whole text to
polish — 1.1 s after a 30 s dictation, 2.3 s after a minute, growing with the length (Typeless felt faster on long
utterances, slower on short ones). Now (`DictationStream`):

- **Cut at pauses while talking** (`DictationSegmenter`, pure, tested): 20 ms frames against the room's level (the
  10th percentile of the last 3 s, rising at most 2 dB/s while someone talks); a cut goes in the middle of a pause
  of 0.5 s once the piece is ≥ 3 s long and has speech in it — between words, never inside one (Chinese has no
  spaces to find a word boundary in the text). A piece that reaches 20 s without such a pause is cut at the
  quietest 100 ms of its last 2 s; when even that is louder than the room + 6 dB, the cut is *hard*: the next piece
  starts 0.8 s earlier, and the words both pieces heard are dropped by `DictationStitch.dropOverlap` (the longest
  run of ≥ 2 units at the end of one that the other starts with, allowing one half-heard unit when ≥ 3 match).
- **Each piece is transcribed as it completes** (a serial queue; the warm ASR server; its wav written from memory),
  with `prior` = the last 200 characters of the text so far appended to the custom-word context: Qwen3-ASR keeps
  a name spelled the same way all through. Measured below: it never leaked into the output, and it helped 1.7B.
- **…and polished right after** (a second serial queue): the polished text so far is appended to "Near the cursor"
  (before ▮), so polish sees what came before but may not change or continue it (the guard's `copied` check, below).
  A piece that opens with a self-correction (不对 / 我是说 / no wait …; not 不对称 & co.) is polished together with
  the one before it, so the corrected-away words can still go.
- **A cut is a pause, not a sentence end** (§Punctuation at the seams): a piece's own ending isn't final, and polish
  works over a window that spans the seam.
- **At key-up only the last piece is left** (polished together with the clause carried from the window before);
  with a pause ≥ 0.5 s before the release there is nothing left at all.
  The pieces are joined (`DictationStitch.join`: a space only between Latin words), and the joined polish is
  checked once more against the joined transcript (`polish.py serve`'s `guard` command; `stitch_<reason>` falls
  back to the transcript).
- **Safety path**: a piece the speech model failed on → the whole recording is transcribed and polished in one go,
  the old way (`dictation_stream_fallback`). Polishing pieces is also safer than polishing a minute at once (below).
- A short dictation (no pause cut) is exactly the old path: one piece at key-up. `record.dictation.streaming` off
  forces that always.

Latency, key-up → paste, measured inside the app (`total_ms`; `results/latency-*.jsonl`), the `say` wavs fed in real
time as the mic, warm models, three takes each (median). "Quick release": the app stops itself 0.1 s after the last
word (`dictation stop-after`) — the worst case for streaming, the last sentence is still to do. M5 Max:

| Utterance | v0.8 (whole, after key-up) | Now, 0.6B, quick release | Now, 1.7B (pro default), quick release | Now, pause ≥ 0.5 s before release |
|---:|---:|---:|---:|---:|
| 3 s (1 sentence) | 269 ms (ASR 137 + polish 128) | 286 ms (1 piece) | 287 ms | 9 ms |
| 10 s | 536 ms (278 + 251) | 351 ms (2 pieces) | 375 ms | 12 ms |
| 30 s | 1159 ms (640 + 506) | 519 ms (3 pieces) | 538 ms | 11 ms |
| 60 s | 2406 ms (1357 + 1042) | 388 ms (11 pieces) | 394 ms | 13 ms |

- The target (< 1 s after a 30 s dictation, no worse for short ones) holds: the last piece's ASR + polish is all
  that is left, ~0.2 + 0.2 s, whatever the length. A one-sentence dictation is one piece: the same work as before
  (~15 ms more, within a run's spread: 265–281 ms before, 283–297 ms now).

### Punctuation at the seams

What the user saw: the meaning was kept, but there was **a full stop at every pause**, in the middle of sentences
(「…在路上的时候。不用再…」, 「好像是因为。网络断开…」, 「但是呢。它识别出来…」), and in English a capital after
it. Each piece was transcribed and polished as if it were a whole utterance, so Qwen3-ASR ended it with 。 and polish
kept it (polish only saw `before ▮` and the piece). Now (`DictationStitch`, `DictationStream`; pure parts in
`DictationStitchTests`):

- **The segmenter measures each pause** (`DictationSegmenter.pauses`: from the last speech frame before a cut to the
  first one after it, known once speech resumes; 0 for a hard cut).
- **A piece's trailing punctuation isn't final** (`seam`, `joinPieces`): 。.!?！？ and ，, at a seam are taken off,
  unless the pause was long (`longPause`, ≥ 1.2 s) **and** the text is plausibly a whole sentence
  (`plausiblyFinal`: the speech model ended it with 。!?, its last sentence has ≥ 4 CJK units / 3 words, it isn't a
  stub that opens with a connective — 「但是呢」, "and so" — and it doesn't stop on a word that needs more:
  的时候 / 以后 / 的话 / 因为 / 是 / 也 / 在 …, the / and / to / is / that …). Long but not whole → a comma (when there
  was punctuation). In English the next piece's first word loses the capital the cut gave it (`decapitalize`: only
  ordinary words; never "I", a custom word, an acronym or a name — Thursday, GitHub). This is what polish-off
  dictation types, what a fall-back types, the joined transcript the stitch guard checks against, and the ASR's
  `prior`.
- **Polish decides over a sliding window** (`DictationStream.polish`): the window is the clause carried from the
  window before + the new piece (its ending taken off). What polish writes up to its last sentence end **or comma**
  is committed (`commitSplit`); the clause after it is carried and polished again with the next piece, so the
  punctuation across the pause is decided with both sides in view. Every comma inside a window was written with the
  words on both sides in view; only the window's own end wasn't, and that is what is carried. Carrying the whole
  unfinished sentence (the first version) made the window at key-up as long as the sentence: polish after key-up
  went from 150 to 302 ms (median) on these clips; one clause costs ~25 ms. After a long pause that follows a whole
  sentence, the carried clause is committed as it is (with its sentence end). The last piece's window keeps its
  ending: the dictation ended there. A carried clause left when the dictation ends (nothing after the last cut) is
  typed with the punctuation polish gave it — no work after key-up.
- **The prompt** says it too: "fix punctuation across what are just pauses in speech; don't end a sentence at a pause
  unless the sentence is complete" (with a synthetic example). A self-correction piece is still polished together
  with what came before it (that piece's committed text + the carry).
- `dictation_window` events: units in, committed, carried, ms.
- **Found on the way: the last words could vanish.** Qwen3-ASR now and then answers nothing for a short last piece
  that follows a whole sentence of `prior` ("…on Wednesday." + 1.4 s of quiet + "and won't be back in time"): in a
  repro, 2 of 6 takes on the old build and 3–5 of 6 on this one lost it (the prior differs only in the seams; the
  same request replayed outside the app always worked, so it is a borderline decode, not the prior's wording). The VAD
  had heard speech, so `transcribe.py` decodes such a piece once more without the prior (`retried` in its answer;
  ~0.13 s, only then): 6 of 6 kept afterwards (`tests/test_dictation_vocab.py`).

Evaluation (`promo/cases/v0.8-dictation-punct/`, not in git): 20 synthetic clips made with `say` (8 Chinese
Tingting, 6 English Samantha, 6 mixed Tingting), 9–15 s, each fragment trimmed and joined by silences: **59 pauses
in the middle of a clause** (0.6–1.0 s; 32 of them long enough into a piece that the app cut there) and **10 real
sentence ends** (1.3–1.6 s), a −66 dBFS noise floor. Fed as the mic of the isolated test build (released 0.1 s
after the last word), the test pad emptied before each clip (a pad full of earlier clips was copied into the polish
as "near the cursor" context). The scorer finds both sides of every pause in the output (difflib over units) and
reads the punctuation between them.

Interleaved A/B (`results/ab-*.jsonl`): the old build and the new one running side by side on the same warm servers
and scripts, every clip dictated into one, then the other, three rounds (so whatever else loaded the machine — a 3D
render was running — weighed on both), polish on:

| | Old (dd403552) | New |
|---|---:|---:|
| Pauses in a clause with a full stop — all / where the app cut | **55 %** (99/180) / **100 %** (99/99) | **0 %** (0/180) / **0 %** (0/99) |
| … Chinese / English / mixed (all pauses) | 67 % / 42 % / 53 % | 0 % / 0 % / 0 % |
| English: a capital after a pause in a clause | 42 % (24/57) | 5 % (3/57) |
| Real sentence ends kept | 80 % (24/30) | 70 % (21/30) → **80 % (16/20)** after judging the whole sentence, not its last clause (`final-ends-cur.jsonl`) |
| Polish fall-backs (of 60 dictations) | 24 | 18 |
| Polish off (`base-raw` / `cur-raw`, one round): full stops at pauses | 54 % (32/59), all 32 cuts | 0 % |

The prompt line alone: the 41-case polish eval (same day, same model) — fall-backs 9.8 % (old prompt) → 4.9 %,
kept 97.6 % → 97.6 %, similarity 0.952 → 0.952, untouched sentences 100 %, fillers removed 76.5 % both; the
over-deletion set unchanged (100 % kept; one more filler left: 87.5 → 81.2 %). `results/polish-*.json`.

- Before, **every** cut gave a full stop (32/32); pauses that didn't fall on a cut never did (the speech model saw
  the whole clause). Now none does, with polish or without. The capital after a cut (English) is gone too.
- Real sentence ends: the same as before (8/10 kept, polish on). The two that go are pauses the segmenter didn't cut
  at (the speech model wrote a comma inside a piece) — not the seam rule.
- What polish does with a seam now: mostly a comma where the clause really breaks (「…尤其是在路上的时候，不用再…」),
  nothing inside a clause (「…默认是打开的。用户不想要的时候自己关掉…」). Gemma 4 E2B leaves some long Chinese
  sentences without a comma at a seam; polish off types the clause run together (no punctuation at the seam) —
  better than a wrong full stop, and only the default-off path.

Latency, key-up → paste (`total_ms`, the app's own clock), the same interleaved runs; quick release (0.1 s after
the last word), so the last piece is always still to do — the worst case:

| | Old: median / p90 | New: median / p90 | Paired difference (median) |
|---|---:|---:|---:|
| The 20 clips (9–15 s, 2–4 pieces) ×3 | 378 / 464 ms | 390 / 461 ms | +26 ms (polish +24, ASR −1) |
| 3 s, one piece | 328 ms | 331 ms | +12 ms (no window: the same work) |
| 10 s, 2 pieces | 393 ms | 461 ms | +64 ms (polish +28; ASR +25 is noise — unchanged code) |
| 30 s, 3 pieces | 639 ms | 681 ms | +29 ms (polish +28) |

- The last window is the carried clause + the last piece: ~20–30 ms more polish after key-up. Carrying the whole
  unfinished sentence instead (the first version) doubled it: polish after key-up 150 → 302 ms median (+144 ms
  paired, up to +408 ms; `results/archive/`).
- With a pause ≥ 0.5 s before the release nothing is left to do, as before: the carried clause is typed with the
  punctuation polish gave it.
- These absolute numbers are above the speed eval's (287 / 375 / 538 ms) because the machine was busy (a render on
  the GPU throughout); the paired differences are what to read.

## Insert

1. Save the general pasteboard: every item, every type, as data.
2. Put the text, marked `org.nspasteboard.TransientType` so clipboard managers skip it.
3. Post ⌘V (HID level). `DictationPastePolicy` (BlurtCore, unit-tested) decides, the way Typeless does: **⌘V goes to
   any other app in front**, whatever its focused element looks like to Accessibility. Refused only when
   - there is no app in front;
   - Blurt itself is in front (its own text views get a `paste:` action; panels get nothing);
   - secure event input is on (`IsSecureEventInputEnabled()`: a password field anywhere), or the focused element is an
     `AXSecureTextField` (role or subrole);
   - Accessibility isn't granted (a posted ⌘V wouldn't arrive).
4. Restore the old pasteboard 0.6 s later, unless something else has changed it since.

**Fitting at the cursor** (before step 1; BlurtCore `DictationFit`, `DictationFitTests`), like Typeless. The field
holds 「我知道你就是▮的。」 and the user says 「就是从老家回来的。」: pasted as it came, the field became
「我知道你就是就是从老家回来的。。」; fitted, only 「从老家回来」 goes in → 「我知道你就是从老家回来的。」. Right before
the paste, after polish and stitching, the focused field is read again (Accessibility, the same read the after-typing
watch needs; ≤ 500 characters each side of the cursor / selection), and the dictated text — only it — is trimmed:
- **overlap before**: its start repeats the end of the text before the cursor (no sentence end in between) → that
  start goes, with the punctuation after it. At least 2 CJK characters / digits or 1 Latin word: 「我们明天去▮」 +
  「去公园」 keeps its 「去」;
- **overlap after**: its end repeats the start of the text after the cursor → that end goes, with its punctuation. At
  least 2 units, or 1 when both end the same way right after it (「的。」 before 「的。」);
- **punctuation**: the text after starts with punctuation → no punctuation at the insertion's end; it continues the
  sentence (a CJK character, a lower-case word, a digit) while the text before ends mid-sentence → no closing
  。.!?！？ (between two whole sentences it stays). The text before ends mid-sentence → no leading 「，」 and no capital
  the speech model gave (ordinary words only, as at the seams); it ends in punctuation → no second mark at the start
  (seen: polish repeated the field's 「今天的安排：」 — the overlap and its 「：」 went);
- **spacing**: a space between Latin words at either seam; between CJK and Latin the field's own way (else the
  dictation's, else spaced, as polish writes);
- never: anything in the field is deleted or moved; a fit that would leave nothing to insert; a field whose text can't
  be read (WeChat, some Electron apps — the paste goes in as it came); `record.dictation.context` off.
- The history entry records `fitted` (`head`, `tail`, `punct`, `capital`, `space`); `dictation_fit` events. Checked
  in the test build with the test pad holding text around the cursor (`dictation testpad set 我知道你就是▮的。`;
  `results/fit.log`): 「我知道你就是从老家回来的。」, "I think we should move the meeting tomorrow." from "We should
  move the meeting.", and 「今天的安排：下午三点开会。」 (polish had repeated the field). Only the user can check real
  fields in real apps (Notes, Mail, browsers, Electron editors expose their text differently, or not at all).
- Why: v0.8 also required the focused element to belong to the app in front and not to be a button, list or table.
  WeChat's input box isn't an AX text role (no focused element can be read there at all), so every dictation into
  WeChat was left on the clipboard ("copied"), while Typeless pastes there fine (C).
- When Accessibility couldn't confirm a text field (`focusIsText` false or unknown: WeChat, many Electron and web
  editors), the island says "Pasted" for 4 s with **Copy Again**, in case it didn't land; the history keeps every
  text (copy from the Dictation page).
- Refused → the text stays on the clipboard and the island says "已复制，可粘贴" / "Copied — paste it with Command-V".
- **Test builds never post an event or create a tap.** A test build is one with `BLURT_TEST_COMMANDS=1` *or* a bundle
  id other than `dev.blurt.recorder`. In a test build the text goes only into the app's own test pad;
  `dictation paste-policy front=other text=unknown …` reports what the policy would decide.

## Polish

`polish.py serve --preload` keeps one MLX model warm:
- 127.0.0.1 with a token, in `$BLURT_HOME/run/polish-serve.json`;
- unloads after 180 s idle and exits after 30 min — longer while dictation is used often (`adaptive_idle` in
  `_common.py`, also for `transcribe.py serve`'s dictation requests): ×2 at 3+ requests in the last 30 min, ×5 at
  8+ (the model stays at most 30 min unused, the server 4 h). Only on the pro and standard tiers: on 8 GB Macs the
  model is too large a share of memory to keep around;
- uses the ASR caps: `asr.limits` threads (3 here), MLX memory limit = 25 % of RAM, utility QoS + nice 10.
  Utility vs user-initiated made no difference to latency (108 vs 118 ms median: the work is on the GPU).

### Why a polish was "unavailable" (A), and model loads

The history entry said `reason: unavailable`, `model: null` after a 19 s dictation: the app waited `polish_timeout_ms`
(3 s) after key-up for the server to write its address, and it hadn't — 22 s after the key-down had started it.
Starting a server is `uv run polish.py serve`, which resolves the script's packages, then re-runs itself under
`uv run --with mlx-lm`. Each resolution asks PyPI again once uv's index cache has expired: on this Mac the first
`uv run --with mlx-lm` of the day took 13.1 s against 2.5 s cached, and a cold `polish.py serve` with the cache
expired (`--refresh`) wrote its address after 6.6 s and had the model loaded at 9.5 s, against 0.5 s / 2.9 s
offline (`results/coldstart.jsonl`). Two slow resolutions on a slow network are > 20 s. (The other way to get there —
the server never started — leaves the same entry; the timings below now tell them apart.) Now:
- servers start **offline first** (`WarmSpawn`: `UV_OFFLINE=1`, so the cached packages are used as they are; only if
  that fails — nothing cached yet, the first use ever — again online);
- a model coming up gets its own **load budget** (`record.dictation.load_budget_ms`, 12 s: the server starting and
  the weights loading), never counted against `polish_timeout_ms`, which the server applies to the generation alone
  once the model is loaded (`load_ms` in its answer);
- both servers are still warmed on the key-down, in parallel with the recording, and stay warm longer while
  dictation is used (above);
- every history entry records `asr_ms`, `polish_ms` (what the user waited for after key-up), `load_ms` (model loads
  waited for), `total_ms` (key-up → paste) and `segments`.

The fixed prompt prefix (rules + 4 examples) is prefilled once and its KV cache copied per request. Thinking is off
(`enable_thinking=False`; `<think>` blocks are stripped anyway). Decoding is greedy, and max tokens = 1.6 × the input.
`run` is the one-shot form (it uses the server when there is one).

Rules, from the user:
- **Allowed:** remove fillers, stutters and repeats; apply self-corrections, keeping only the corrected version; add
  punctuation and paragraphs; fix obvious homophones.
- **Not allowed:** rewrite, summarize, translate, change the tone, answer or carry out the text, or drop content.
  Mixed Chinese and English stays as spoken. **Numbers stay as said** (一点二万 never becomes 一万二).
- The prompt says it in so many words since the user's dictations lost a condition clause (turning "faster when
  short, slower when long" into "faster, slower when long") and an "or …" alternative, and wrote 「一点二万」 as
  「一万二」: "Apart from the
  fillers, stutters and the part a speaker took back, every word stays. Never remove a phrase that carries meaning,
  even when the sentence sounds clumsy with it: a condition, a contrast, an alternative, a name, a number."
  The price: Gemma 4 E2B now leaves a filler in 4 of the 41 sentences (就是那个, 就是说, 那个, like: fillers removed
  97 % → 88 %). A first version that also said "When unsure, keep it" left a correction unapplied as well, so that
  sentence went.

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
| `copied` | 6 units in a row of the context (the text around the cursor, or a streamed dictation's polished text so far) that weren't spoken: the model continued the document |
| `dropped` | the repair (below) had to put back more than 40 % of the content: the polish was bad |
| `timeout` | no answer within `record.dictation.polish_timeout_ms` (3000) after the model is loaded; the server stops generating at the deadline |
| `error` / `unavailable` | the model raised, or the server never came up within the load budget |

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

### Repair: dropped words go back in

The guard counts totals, so one dropped clause in a long dictation stayed inside its slack (D's condition clause
passed).
`polish.repair` (before the guard) aligns the transcript with the output (difflib over units) and looks at every span
the output left out:
- **may go**: fillers (嗯 呃 那个 就是说 um uh …) and discourse words (然后 呢 就是 so and …); a stutter or a
  repetition (the same words right after or before); a restart (its end said again right after); the corrected-away
  part of a self-correction (a marker — 不对 / 不是 / 我是说 / no wait … — inside the span with ≤ 4 units after it
  that the output kept, or a strong marker right after the span); words that were only moved (they are in the
  output); a single unimportant unit (上面 → 上) — but never a lone 不 / 没 / 或 / 只 / 也 / 都 / not / or / only …;
- **anything else carries meaning: it is put back where it was said** (after the punctuation that preceded it in the
  transcript, fillers taken out), instead of throwing the whole polish away;
- **numbers**: a number run written differently is replaced by the spoken one unless it is the same value in
  digits (三十 → 30, 十七点二 → 17.2, 五零零 → 500, 二点三点一 → 2.3.1) or the corrected value of a correction
  (周三…不对周四 → 周四). 一点二万 → 一万二 and 三千五百 → 三千五 go back.
- More than 40 % of the content put back → `dropped` (the raw text). The history keeps the spans (`repaired`).
- Calibration: no reference output of either eval set gets anything put back; every over-deleting output of the
  over-deletion set gets its phrases back (`tests/test_polish.py::Repair`).

## Custom words

`$BLURT_HOME/dictation/vocabulary.json`, owned by the app (`BlurtCore/DictationVocabulary.swift`), read by
`scripts/dictation_vocab.py`:

```json
{"schema": 1, "terms": [{"term": "Claude Code", "sounds_like": ["cloud code"], "source": "project",
                         "state": "active", "added": "2026-10-23T13:00:00+08:00", "hits": 3, "seen": 0}]}
```

- `source`: `manual` (Settings), `learned` (from a fix), `project` (Blurt's own seed and the projects), `default`
  (the common product names). `state`: `active` (used), `suggested` (learned once), `rejected` (a suggestion the user
  ignored: never suggested again), `removed` (a seed the user removed: never seeded again). A removed manual word just
  goes.
- The seed, once per launch and when Settings opens, adds what's missing: Claude Code, Codex, blurt, 口喷鸡 (with the
  misrecognitions the eval found as sounds-likes) and each project's name and key (`project`); and, as `default`, the
  AI / dev products nearly every user says: Gemini, Claude, ChatGPT, Cursor, Typeless, OpenClaw, MCP, tmux, GitHub,
  PR, worktree (`DictationVocabulary.defaults`). Settings shows both seeds as "Automatic"; each is removable like any
  word. Typeless has no "TTS" sounds-like on purpose: that would rewrite every real "TTS" — the biasing does it
  instead.
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
- Apps whose focused element Accessibility can't read (WeChat's input box, some Electron apps): the front app's name
  and its focused window's title only (`DictationContext.titleOnly`: often the chat's or the document's name).
- A streamed dictation's pieces get the polished text so far appended to "before the cursor".

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

**Default (v0.8): Qwen3-ASR 0.6B MLX 8-bit** (`qwen3-asr-0.6b-mlx`, Apple silicon pro / standard tiers; the speed
eval below made the 1.7B the pro tier's default):
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

### Qwen3-ASR 1.7B (the v0.8 speed eval)

`mlx-community` has Qwen3-ASR 1.7B in bf16, 8-, 6-, 5- and 4-bit. Two test sets, all synthetic (none is the user's
own speech); data and scripts in `promo/cases/v0.8-dictation-speed/` (not in git):
- **new**: 28 Chinese sentences full of product and dev names (Gemini, Claude Code, Codex, Claw / OpenClaw,
  Typeless, tmux, worktree, MCP, API, PR, review, session, Chinese project names, 一点二万), 45 terms, six zh_CN
  `say` voices (Tingting, Eddy, Flo, Sandy, Shelley, Grandpa), each clip also with pink noise at 12–18 dB SNR, mains
  hum and an early reflection (a laptop in a room);
- **v0.8**: the 20 Chinese / mixed clips of the earlier eval (Tingting, Reed, Eddy), 29 terms.
Context = the default and project words plus every term of the set (~27 words). In-process, warm, M5 Max.

| Model | Download | Peak RAM | New clean: terms / CER | New noisy: terms / CER | v0.8: terms / CER | v0.8 + prior | Median / clip |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0.6B 8-bit (v0.8 default) | 1.0 GB | 1.3 GB | 53 % / 21.7 % | 36 % / 33.5 % | 72 % / 7.6 % | 72 % / 8.0 % | 124 ms |
| **1.7B 8-bit** | 2.5 GB | 3.0 GB | 51 % / **19.4 %** | 38 % / **26.7 %** | **90 % / 2.7 %** | **97 % / 1.7 %** | 149 ms |
| 1.7B 4-bit | 1.6 GB | 2.2 GB | 40 % / 34.1 % | 27 % / 40.8 % | 86 % / 3.7 % | 83 % / 4.0 % | 141 ms |

- Most of the new set's errors are the voices: Sandy, Grandpa and Shelley garble English names for every model
  (25–60 % CER); Tingting is 3–6 % for both. Per voice, 1.7B 8-bit is better on noisy audio for every voice but
  Tingting, and much better on the cleaner v0.8 set. Its own misses: Typeless → "TypePlus" (now a sounds-like of
  the seeded Typeless), letters spelled apart ("A P I").
- The 4-bit 1.7B is worse than the 0.6B 8-bit with context on the hard voices: quantisation below 8 bits costs more
  than the size buys.
- **Context format** (0.6B, new set clean): none 22 % / 30.9 %, "Notes about A, B … and Z." 53 % / 21.7 %, a bare
  comma list 44 % / 25.4 %, a Chinese glossary line (术语：A、B、C。) 51 % / 41.1 % — it **copied the glossary into one
  output**. The English sentence stays. Adding the text so far (`prior`, a streamed piece's context) changed little
  for 0.6B and helped 1.7B (90 → 97 % terms on v0.8); it never leaked into an output.
- **Default: 1.7B 8-bit on the pro tier (≥ 32 GB), 0.6B 8-bit on standard (16–24 GB)** (`dictation_models`). With
  streaming the extra 25 ms per piece only shows on the last one (the latency table: +6–19 ms). A pro Mac with only
  the 0.6B keeps using it until the 1.7B is installed: Settings → Dictation shows it as recommended, 2.5 GB.
- Downloads: an installed model is loaded from its folder (no Hugging Face lookup on the key-down); mlx-community
  repos come from ModelScope when the download mirror is on, or when Hugging Face fails (here: 2.9 MB/s from
  ModelScope, 0.12 MB/s from Hugging Face, 8 KB/s from hf-mirror). Files are checked against their listed size: a
  dropped connection once ended a 1.6 GB file at 550 MB without an error.

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

### Over-deletion (the v0.8 speed eval)

`tests/fixtures/polish_overdelete.jsonl`: 22 synthetic sentences like the user's D and E (a condition, a contrast, an
alternative, numbers said their own way, negations; Chinese, mixed, English), each with the phrases that must survive
and an over-deleting output for the repair's tests. Plus a long check: the Chinese ones joined four at a time (~30 s
of speech, like D), polished whole and piece by piece (with the polished text so far as context), 45 phrases.

| Model | 41-set fall-back | 41-set kept (final) | Fillers removed | Similarity | Over-deletion kept: model → final | Long, whole: model → final | Warm (median) | Peak RAM | Download |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Gemma 4 E2B, v0.8 prompt, no repair | 2.4 % | 98 % | 97 % | 0.970 | 91 % → 95.5 % (1 lost: 一点二万 → 一万二万) | 43 → 43 / 45 | 108 ms | 3.5 GB | 3.4 GB |
| **Gemma 4 E2B, now** | 2.4 % | 97.6 % | 88 % | 0.966 | 95.5 % → **100 %** | 44 → **45** / 45 | 111 ms | 3.9 GB | 3.4 GB |
| Gemma 4 E4B, now | **0 %** | **100 %** | **94 %** | **0.989** | 95.5 % → 95.5 % (reordered a sentence) | 45 → 45 | 166 ms | 5.4 GB | 5.2 GB |
| Qwen3.5 4B, now | 2.4 % | **100 %** | 79 % | 0.964 | **100 %** → 100 % | 45 → 45 | 137 ms | 4.0 GB | 3.1 GB |
| Qwen3.5 4B, v0.8 prompt | — | — | — | — | — | **36** → 43 (pieces: 43) | — | — | — |

- Gemma 4 E2B reproduces D's failure (od-01: the "when short" clause dropped) with either prompt; the repair puts it back. With
  the v0.8 prompt and a 30 s input, Qwen3.5 4B dropped 9 of 45 phrases; in pieces, 2: shorter inputs lose less. The
  new prompt brings every model to 44–45 on its own.
- Gemma 4 E4B has the best similarity and no fall-backs, but it rewrites more: it turned 「如果明天下雨的话，我们就改成线上
  开会，不下雨就还是去公司」 around (both halves swapped). Qwen3.5 4B keeps every phrase but leaves a fifth of the fillers.
- **Defaults unchanged: Gemma 4 E2B on pro and standard.** With the repair it loses nothing on either set, removes
  more fillers than Qwen3.5 4B, is the fastest and needs no new download. E4B (5.2 GB) and Qwen3.5 4B stay
  offered on pro Macs; streaming makes their extra 25–55 ms per piece affordable if the user prefers them.

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
  to polish), `context` (that text, only with `keep_audio`), and since the speed work `asr_ms`, `polish_ms` (waited
  for after key-up), `load_ms` (model loads waited for), `total_ms` (key-up → paste), `segments` (pieces streamed)
  `repaired` (spans polish dropped that were put back) and `fitted` (how it was fitted into the field at the cursor: head / tail / punct / capital / space). Older lines lack them: read as unknown. `prune` rewrites
  lines through `DictationEntry.json`, which carries them;
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
| `key` | `fn` (unset) \| `right_option` \| `either_option` |
| `mode` | `auto` (unset) \| `tap` \| `hold` |
| `fn_capture` | `true`: with Fn and Accessibility, keep the Fn press from macOS (the filter) |
| `polish` | `light` \| `off` |
| `polish_model` | by tier |
| `polish_timeout_ms` | `3000` (the generation only, once the model is loaded) |
| `load_budget_ms` | `12000`: how long a model coming up (server start + load) may take |
| `streaming` | `true`: transcribe and polish pieces while talking |
| `precapture` | `true`: open the mic on the key-down, before the trigger has decided |
| `builtin_mic` | automatic (unset: on while the default input is Bluetooth) \| `true` \| `false` |
| `start_sound` | `false`: a soft tick when listening starts |
| `polish_priority` | `utility` |
| `retention_days` | `30` |
| `keep_audio` | `false` (also keeps the context in the history: debugging) |
| `asr_model` | automatic (Qwen3-ASR 1.7B MLX on pro Macs, 0.6B on standard ones, when installed — a pro Mac falls back to an installed 0.6B —, else the voice-note model) |
| `context` | `true`: read the text around the cursor for polish |
| `learn` | `true`: watch the field after typing and learn the user's fixes |
| `double_tap_send` | `true`: a double tap of the key presses Return (after a dictation: once it is pasted) |

## Verification

- Punctuation at the seams and double tap = Return (`promo/cases/v0.8-dictation-punct/`, not in git: clips, scripts,
  results; isolated test builds `dev.blurt.recorder.puncttest` — the old one and the new one side by side —, scratch
  `BLURT_HOME`, launched through LaunchServices, no real mic, no tap, nothing posted, nothing pasted outside the test
  pad):
  - `swift test`: `DictationStitchTests` (a breath leaves no full stop — Chinese, English, mixed, a comma, a question
    mark —; a long pause after a whole sentence keeps it, after a stub or an open word it becomes a comma; the
    capital the cut gave goes, names / acronyms / "I" keep theirs; `plausiblyFinal`; `commitSplit` keeps the
    unfinished clause, not 3.5 / 1,000 / 10:30), `DictationSegmenterTests.testKnowsHowLongEachPauseWas`,
    `DictationFitTests` (the Typeless example, no overlap, a single-character false overlap, overlap only at the
    cursor, English, punctuation after the cursor, leading commas and doubled marks, spacing, mixed),
    `DictationTriggerTests` (single tap starts at once; idle double tap → cancel + send; while dictating → stop, then
    send; push-to-talk release + tap; hold mode; a held second press is push-to-talk; Fn + another key, ⌘, a click or
    Esc between the taps is never a double tap; the setting off; reset), `DictationPastePolicyTests.testSendPolicy`;
  - `pytest tests`: the prompt carries the pause rule; an empty piece after a prior is decoded once more without it;
  - the A/B and the latency above (`scripts/ab.py`, `score.py`); the double tap through the trigger hook in the test
    build (`scripts/dt.sh`, `results/double-tap.log`): idle → `dictation_cancel` + "would press Return", no history
    entry; dictating → paste into the test pad, `dictation_send queued`, then "would press Return" after the paste;
    push-to-talk + tap the same; simulated Accessibility off → skipped; `send-policy`; the setting off → two taps
    start and stop.
- Only the user can check: a real Fn double tap sending in WeChat, Claude and other chat apps (that Return lands
  after the paste in each — the paste is confirmed done 0.6 s after ⌘V, when the clipboard comes back), that a
  double tap with nothing dictated sends what is already in the box, and how the punctuation reads on their own
  speech (real pauses are messier than inserted silence: a breath can be 0.4 s or 1.5 s).
- The speed work (`promo/cases/v0.8-dictation-speed/`, not in git; isolated test build `dev.blurt.recorder.speedtest`,
  scratch `BLURT_HOME`, launched through LaunchServices, no real mic, no tap, nothing pasted outside its test pad):
  - `swift test` (116): `DictationSegmenterTests` (cuts in pauses, never too short, hard cuts with overlap, digital
    silence), `DictationStitchTests` (joins, the overlap drop, correction openers), `DictationPastePolicyTests`
    (WeChat-like focus pastes; Blurt, secure input, no app, no Accessibility don't; the mic choice),
    `DictationTriggerTests.testArmedDownSaysWhenThePressCanStillStart`, `DictationHistoryTests` (timings, repairs),
    `DictationVocabularyTests` (the `default` seed, removable);
  - `pytest tests` (320): `test_polish.py::Repair` (both eval sets' references untouched, every over-deletion put
    back, numbers, corrections, `copied`, adaptive idle), `test_dictation_vocab.py` (`prior` reaches the backend and is
    cleared; the 1.7B / 0.6B selection by tier, the 0.6B fallback);
  - test hooks: `dictation wav PATH` (the next "mic"), `dictation stop-after S` (a release timed to the audio),
    `dictation set KEY VALUE`, `dictation paste-policy …`; env `BLURT_TEST_MIC_CLOCK=keydown`,
    `BLURT_TEST_MIC_START_MS`;
  - the latency table, the clipped-start table, the island's two states (`shots/`), the cold start, the ASR and
    polish evals above.
- Only the user can check: the real mic's start-up after the key-down (built-in, and AirPods with the built-in-mic
  setting on and off: `dictation_mic_live.from_key_ms`), that the prepared engine leaves the mic indicator off until
  the key goes down and that an Fn-arrow only flashes it, ⌘V into WeChat (and other apps whose input isn't an AX text
  role) with the clipboard coming back, "Copy Again", and a cold polish server after a day off the network cache.

Earlier rounds:


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
- The permission guide and Fn (`dev.blurt.recorder.permtest`, simulated permissions; screenshots in
  `promo/cases/v0.8-permissions/`, not in git):
  - dictation walk from nothing granted, docked to a stand-in window, which moved (the panel switched sides):
    Accessibility on → the listener became the Fn filter (`recreate_filter_tap`, generation 2) and Input Monitoring
    was skipped; microphone; the 🌐 step with usage 3 → 0; "Done — dictation works in every app now." in Settings;
  - the `all` walk from Settings → Privacy with right ⌥, docked to the real System Settings window (panes opened, nothing
    in them touched): Screen Recording (Restart offered, `perm_relaunch` with the rest of the walk), Accessibility
    skipped, Input Monitoring on → `recreate_tap` (generation 2); "Done for now";
  - the Fn filter drops keyCode 63 and passes 61; refused → the monitor, back when allowed; auto mode through the
    trigger hook: a tap started hands-free (`push_to_talk: false`), a 0.9 s hold push-to-talk (`true`);
  - the island's Set Up and the menu row's start the dictation walk; the assistant's step 1 shows the guide button,
    the four rows and the key picker (Fn first) with Typeless detected running.
- Not verified here (only the user can): whether the request APIs list this build in each pane on a signed build;
  dragging the tile into a list; whether the Fn filter keeps macOS's 🌐 action (emoji / input source / system
  dictation) from running on macOS 26, and that Fn-arrow / Fn-F-keys still work with it; right ⌥ pressed while another app is in front, with the real tap after
  granting Input Monitoring (Settings shows *Last heard in another app*), and with Accessibility alone (the monitor);
  ⌘V into another app; the real AX context and the after-typing watch in real apps (Notes, Mail, a browser,
  Electron editors, terminals — some expose no AX value, and then there is simply no context and no learning).
  They need real grants, and reading or posting into other apps on this machine is off-limits for tests.
