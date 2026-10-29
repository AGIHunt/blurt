# Dictation (听写) — v0.8, macOS (with the v0.8 speed work: streaming, start of speech, paste, repair; and the model-first work: §Rules vs model)

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
| Names inside Chinese speech: the language tag, learning from a correction (`learn`, the lab's API) | `transcribe.py` (`Qwen3Mlx._decode_tagged`, `switch_language`), `dictation_vocab.py` (`choose_tag`, `translated_glue`, `context_dump`, `fixes`, `learn`), `tests/test_dictation_vocab.py` (`CodeSwitch`, `TaggedDecode`, `FalseCorrections`, `LearnFromCorrection`), `tests/fixtures/dictation_false_corrections.jsonl`; the page's **Correct**: `MainWindow/DictationPage.swift`, `DictationVocabulary.learnCorrection`, `DictationHistory.correct` |
| Controller (capture → ASR → polish → insert → history) | `Capture/Dictation/Dictation.swift` |
| Streaming: cut, transcribe and polish while talking; punctuation at the seams (pauses, polish windows) | `Capture/Dictation/DictationStream.swift`; pure: `BlurtCore/DictationSegmenter.swift` (cuts, pause lengths), `BlurtCore/DictationStitch.swift` (joins, `seam`, `mark`, `commitSplit`, `fallbackSeam`, `keepCase`, `listLines`) (`DictationSegmenterTests`, `DictationStitchTests`); its Python port for the lab, `scripts/dictation_stitch.py` (`tests/test_dictation_stitch.py`; `tests/fixtures/dictation_seams.jsonl` is shared by both) |
| Live text: the words while talking, the piece still being said decoded as interim requests (§Live text) | `Capture/Dictation/DictationStream.swift` (`interimIfDue`, `publish`), `Capture/LiveTranscript.swift` (`LiveTextLines`); pure: `BlurtCore/DictationLiveDecode.swift` (when, stale answers, `compose`; `DictationLiveDecodeTests`); the server's stop check: `transcribe.py` (`cmd_serve`, `Qwen3Mlx._check`, `Interrupted`; `tests/test_transcribe_interim.py`) |
| The mic: engine prepared at launch, built-in mic choice | `Capture/NoteBubble.swift` (`NoteVoice`, `MicEngine`, `AudioDevices`); pure: `DictationMicChoice` |
| Insertion, fitting at the cursor, Return for a double tap | `Capture/Dictation/DictationInsert.swift`; the rules: `BlurtCore/DictationPastePolicy.swift` (`DictationPastePolicy`, `DictationSendPolicy`; `DictationPastePolicyTests`), `BlurtCore/DictationFit.swift` (`DictationFitTests`) |
| Styles: the router, categories, which text a style types (`DictationStyle.pick`), variants, history records, reformat's rules, learning (pure, unit-tested) | `BlurtCore/DictationStyle.swift`, `DictationStyleRecord.swift`, `DictationStyleLearn.swift`; `DictationStyleTests`, `DictationStyleLearnTests`; `scripts/dictation_styles.py`, `tests/test_dictation_styles.py` |
| Styles in the app: ⇧ / the island, the structuring pass at key-up (`DictationStream.finish(structure:)`), reformat-last, the list chip, suggestions | `Capture/Dictation/DictationStyles.swift`, `DictationStream.swift`, `Dictation.structure`; the ear's chip in `Island/Island.swift` / `Ears.swift`; Settings → Dictation → Style |
| Warm-server client (no `uv run` per request) | `BlurtCore/WarmServer.swift` |
| History file | `BlurtCore/DictationHistory.swift`, `scripts/dictation.py` (list / prune / turn into item) |
| Polish model (Light) + the structuring pass (Structured) + guard + repair + eval | `scripts/polish.py` (`Engine.polish`, `Engine.structure`, `guard`, `repair`), `scripts/polish_models.json`, `tests/fixtures/polish_eval.jsonl` (Light references + `structured` expectations), `tests/fixtures/polish_overdelete.jsonl`, `tests/test_polish.py` |
| Dictation Lab (record, stages, compare, mark up, cases, scripts, regression) | §Lab: `MainWindow/DictationLab.swift`, `DictationLabViews.swift`; pure: `BlurtCore/DictationLab.swift` (`DictationLabTests`); `scripts/dictation_lab.py`, `scripts/lab_packs/`, `tests/test_dictation_lab.py`, `tests/fixtures/lab_metrics.jsonl` |
| UI | island ears (`Island/Ears.swift`), Settings → Dictation (`Settings/DictationPane.swift`: the essentials on one short page), dictation's models in Settings → Speech (`Settings/DictationModels.swift`), the main window's Dictation page (`MainWindow/DictationPage.swift`: a sidebar place; the menu-bar menu, `⌥⌘D` and the palette open it; tabs History / Words (`DictationWords.swift`) / Lab) |

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
  (§Start of speech). (v1.0.4) Esc also has a Carbon hotkey for as long as a take listens (`.dictationEsc`): where the
  event tap doesn't see it — secure event input on, another tool holding the key — the hotkey still cancels. A press
  both see counts once (`Dictation.escTwin`, 0.4 s); `dictation_secure_input` logs when secure input was on.
- **⇧ is the style toggle** (§Styles): ⇧ pressed and released alone (within 1 s) while dictating says `.style`, in
  push-to-talk too — the one key that joins a held press without cancelling it (⇧ with another key still cancels, as
  any shortcut does). A click on the island while listening (`.islandClick`: `Dictation.handle` turns a mouse-down over
  the island's frame into it) is the same toggle and never cancels. **Fn+⇧** — ⇧ held when Fn goes down, or pressed
  while it is down — is still a clean press and starts in Structured (`startShift`); Fn+⇧+a key is a shortcut as
  before. Only with Fn: with an ⌥ key ⇧ stays a modifier, so ⌥⇧V and Blurt's other ⌥⇧ shortcuts never start
  anything. While a take listens (or its key is down) the Fn filter also keeps a lone ⇧ from the app in front (an input
  method would switch between Chinese and English on it): only a ⇧ press with no other modifier, and its release only
  when its press was kept. The listen-only tap and the monitor can't do that, so with an ⌥ key the ⇧ still reaches
  the app.
- **Double tap = Return ("send")** — `record.dictation.double_tap_send`, on by default; Settings → Dictation 「按两下发送」
  / "Double-tap to send", the key named in its description ("Double-tap Fn to press Return after the text"). In chat apps the user presses
  Return after ~80 % of dictations; now two quick taps do it. Two clean taps, the second going down within
  `doubleTapWindow` of the first one's release, give `.send` (BlurtCore `DictationTrigger`, `DictationTriggerTests`).
  The window is macOS's own double-click interval (`NSEvent.doubleClickInterval`, System Settings → Accessibility →
  Pointer Control) clamped to 0.3–0.5 s — 0.5 s by default. It was a fixed 300 ms, and a Fn tap with the little
  finger is slower than a mouse click: the audit's real "double taps" were 320 ms apart and missed.
  The first tap is never delayed: it does what it always did, at once, and the second one decides:
  - **idle** (auto / tap mode): the first tap started a dictation; the second cancels it (`.cancel`: audio dropped,
    nothing pasted, no history entry) and Return goes to the app in front now;
  - **dictating, hands-free** ("dictate, then send", the useful case): the first tap stopped it and the paste starts
    as usual; the second one (no mic opened for it) queues Return, posted once `DictationInsert` reports the paste
    done — once the field shows the text (`DictationPasteLanding`, read every 30 ms; a field that can't be read:
    0.6 s, as keys reach the app in order), so the ⌘V has landed. Not when the text was only copied (the app
    changed, Blurt in front …), held (a password field) or nothing was heard: Return would then send something else
    — "已复制，没有发送 · ⌘V 粘贴" is then one line (v0.9 dogfood: "copied" replaced "not sent" in the same frame);
  - **push-to-talk** (hold mode, or auto held): letting go stops it; a **double tap** right after sends it the same
    way — release, tap, tap, as the help text says (「刚说完时连按两下」 / "right after you dictate"). A tap within the
    window of the release does nothing by itself (it is the double tap's first tap); before, that single tap already
    sent, so the user's second tap started an unwanted dictation. In hold mode two quick taps (which start nothing
    there) press Return;
  - **while the last take is still on its way** (transcribing, polishing or pasting — the app sets
    `DictationTrigger.busy`): a press starts nothing — no mic, no start, no push-to-talk — and can't cancel that take.
    A tap then is a double tap's first tap: two taps queue Return after the paste. Before, a tap there started a
    dictation the app refused without telling the trigger, which then took the next tap for a stop (Fn "did
    nothing") or, as the second of a double tap, cancelled the take being transcribed — the words were lost and
    Return still went out (audit dict019 / dict020, their key sequences are unit tests now);
  - **a near miss** (`nearMissWindow`, 0.8 s): the first tap started a hands-free take and the second, a little outside
    the window, stopped it; when nothing was heard the app presses Return instead of saying "nothing heard"
    (`quickStop`; only timing and the voice detector decide, no words);
  - a second press held past the hold threshold is push-to-talk as usual; one joined by another key or a click
    (Fn-←, ⌘), or any key / click between the taps, is never a double tap; a third tap starts afresh;
  - a start the app refuses (a screen recording has the mic, the mic failed) resets the trigger but keeps the tap
    (`reset(active:keepTap:)`), so the second tap still sends — Return needs no mic.
  - The events' own timestamps count (`DictationTrigger.eventTime`: CGEventTimestamp, which is mach ticks on Apple
    Silicon, or NSEvent.timestamp), not when the main thread handled them — opening the mic on the key-down can delay
    the next event by more than the window. The same key reported down twice is one press; a Globe-key keyDown (179)
    with the Fn change is part of the press, not "another key". `record.dictation.key_trace` (off) logs each event
    the trigger got (`dictation_keytrace`: dictation key or not, Δt, what it said; no key codes) to check a real
    keyboard.
  - Return is a `CGEvent` (`kVK_Return`, no modifiers, HID level) posted only when `DictationSendPolicy` allows it:
    another app in front (never Blurt), secure input off, Accessibility granted (the Fn filter already needs it).
    The island's right ear says 「已发送」 / "Sent" with the ok check for 1.6 s (`Island.dictationSent`: no toast, the
    island doesn't grow for one word); while a queued Return waits for the paste the ear shows the working dots.
    Dictation's toasts about the last take (reformat's Undo, the ≡ chip, "nothing heard", "copied", why a Return
    wasn't sent) share one key (`Dictation.toastKey`, "dictation"): a newer one replaces the one showing at once, and
    a new take clears them (BlurtCore `ToastQueue`). The rest have their own keys, so they don't take each other's
    place and a new take doesn't drop them: ⇧'s line (`dictation.style`), "Cancelled · Undo" (`dictation.cancel`), a
    failed take's Retry (`dictation.failed.<id>`, one per take), "no model · Download…" / "model ready · Retry"
    (`dictation.model`); the forgotten-take reminder, the once-a-day notices and the first takes' tips are passive
    lines (they wait behind replies). Every toast stays at least 5 s (`ToastQueue.minSeconds`). A toast's Undo and the ≡ chip's "Make a list" act on the take they
    were shown for (`reformat(lp, …)`): after a newer take they do nothing (`dictation_reformat` result `stale`), never
    rewrite the newer text. ⇧'s line ("Structured: tidied into a list when you finish · ⇧ to go back") shows the first
    two times ever (`DictationStyleToggleHint`, `record.dictation.style_hint_shown`); after that the ear's list mark
    alone says it. Test builds never post it: `dictation_test_send` logs
    "would press Return" (with the hooks' simulated Accessibility), and `dictation send-policy front=… secure=… ax=…`
    reports the policy.
  - Price: two quick taps no longer mean "start, then stop at once" (that dictated nothing anyway); someone used to
    macOS's "Press 🌐 twice" for system dictation now sends Return instead. A single tap right after letting go of
    push-to-talk no longer sends (two do), and a tap while a take is still being typed doesn't start the next one.
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
  running are named in Settings → Dictation and the assistant: both apps would react to Fn. They are also said where
  it matters (v0.9 dogfood: a user who never reopens Settings saw the text typed twice and blamed Blurt): when a Fn
  take starts, or one of them launches, once a day per app — "Typeless 也在听 Fn，文字可能输入两次" with **改用右
  Option** (the key changes at once) and **设置…** (`DictationFnClash`, `Dictation.fnClashNotice`). Never over a take
  that is listening: it waits for that take to end and comes after the island's line about it (`moment` →
  `.afterTake`, a passive line). Any key change while a take listens (Settings, this button) ends the take as if its
  key came up (`keyChangeEndsTake`; review: a click on the button mid-take left a Fn take listening 135 s with no key
  to stop it).
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
  - "Dictation works" = the listener is global (`tap` or `monitor`). Settings → Dictation shows one `attn` notice at
    the top only while something is in the way — a permission missing (*Dictation needs Accessibility · Allow…*, the
    guide), else the key not heard (*Blurt can't hear Fn yet · Turn On…*), else macOS's own Fn action (*Fix…*) — and
    nothing once all is well (no Permissions section). Which listener runs and *Last heard in another app: 13:46:57*
    (taken from the listener itself whenever the dictation key changes while another app is in front) are the
    tooltip of *Dictate into any app*. Only the user can make that line appear.
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
   - **Microphone: Automatic / This Mac's microphone / Default input** (`record.dictation.builtin_mic` unset / true /
     false; Settings → Dictation, a popup, as System Settings' microphone source): Automatic = the built-in mic while
     the default input is Bluetooth (CoreAudio transport type), when the Mac has a built-in mic.
     The input unit's device is switched before it starts. Trade-off: the built-in mic is ready at once and the
     headset's music keeps its quality (HFP drops it to call quality), but it is farther from the mouth and hears
     more of the room. `DictationMicChoice` (pure, tested) decides.
   - **The island says "listening" only once audio arrives** (`NoteVoice.onFirstAudio` → `Dictation.micLive`):
     until then the keyboard glyph with dots (`shots/island-mic-starting.png`), then the mint level and the clock
     (`shots/island-listening.png`). `dictation_mic_live` records `from_key_ms`.
   - **Sounds** (v1.0.6, on: `record.dictation.sounds`; `DictationSound`): Peep's cluck when the first audio arrives
     (talk now), a double peck when the take stops (after the mic closed, so it isn't in the take), one softer peck
     when Esc cancels it; voice notes the same. Never while a screen recording runs. Why (the founder): a Fn press that
     didn't register went unnoticed — they talked, pressed again to stop, and that press started the take. Silence
     after a press now says nothing started. The clips come from the film (`assets/sounds/build.py`: its public-domain
     cluck and synthesized peck). Replaces v0.9's optional Tink (`start_sound`, off).
- Only the user can measure the real devices: the built-in mic's start-up and AirPods' HFP switch on their Mac
  (`dictation_mic_live.from_key_ms` in the log), and whether the prepared engine really leaves the mic indicator off.

## Permissions (the guide)

Granting a permission used to mean System Settings, "+", and hunting for the app. The guide does what CleanShot,
Raycast or Loom do (`BlurtCore/PermissionFlow.swift` + `Onboarding/PermissionGuide.swift`, `HelperPanel.swift`,
`SystemAccess.swift`):

- **One walk, the missing ones in order.** `all` (Settings → Privacy): Microphone, Accessibility, Input Monitoring,
  the 🌐 key, Screen Recording last (its restart shouldn't cut the walk short). `dictation` (the setup assistant,
  Settings → Dictation, the menu row, the island's button, the Dictation page): Accessibility, Input Monitoring,
  Microphone, the 🌐 key. A row's *Allow…* walks just that one. Screen Recording is never asked up front: the first
  snap that fails without it shows *Allow…* on its toast, and the recording's alert starts the guide for it. A step is skipped when satisfied: Input Monitoring once the key is heard by a tap (the Fn filter
  needs only Accessibility); the 🌐 key once Fn isn't the key, dictation is off, or `AppleFnUsageType` is 0.
- **Register first, on the user's click** (never at launch): `CGRequestScreenCaptureAccess()`,
  `AVCaptureDevice.requestAccess` (macOS's dialog; no pane), `AXIsProcessTrustedWithOptions(prompt: true)`,
  `CGRequestListenEventAccess()`. Each lists Blurt in the pane (and shows macOS's own prompt the first time), so the
  user only flips a switch.
- **The exact pane**, 0.35 s later: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` /
  `Privacy_Microphone` / `Privacy_Accessibility` / `Privacy_ListenEvent`, and
  `x-apple.systempreferences:com.apple.Keyboard-Settings.extension` for the 🌐 key. All five open the right page on
  macOS 26.5 (checked by window title and screenshots of the System Settings window).
- **The helper panel**: a non-activating floating `NSPanel`, a compact strip docked **under the System Settings
  window's list** (v0.9.x, after Doubao's, without its offset and bulk). Its frame comes from
  `CGWindowListCopyWindowInfo` — only bounds, owner pid (`com.apple.systempreferences`) and layer are read — every
  0.25 s, so the panel follows the window. `HelperDock.dock`: under the window, its card as wide as the list column
  (the window right of its sidebar — 31 % of the window, 190–260 pt — less the list's 20 pt insets, 340–460 pt) and
  centred on it, the notch's tip 2 pt under the window and over the tile; no room below on that screen → right of the
  window (340 pt), else left, else inside its lower right corner; no window = the screen's top right with *Open
  System Settings*. It shows, in about 110 pt: the walk's dots, step N of M and the name, *Skip* and close on one
  line; then the **Blurt tile to drag into the list** (an `NSDraggingSource` whose pasteboard item is the app
  bundle's file URL, as Finder's drag of an app — for the "+" lists) beside the headline ("Turn on Blurt in the
  list"; the 🌐 step: 「把『按下 🌐 键时』设为『不执行任何操作』」; the microphone: "Click Allow in macOS's prompt"), why
  it's needed, and the drag hint. *Open System Settings* / *Restart Blurt* only when they apply.
- **Detect, then move on**: every 0.25 s while the panel shows. Accessibility or Input Monitoring changing re-plans
  dictation's listener at once (the tap made before the grant is made again). A satisfied step with more to come shows
  its check for 0.8 s, then the next one opens; the last one goes straight to "Done — …", and the panel closes by
  itself 1.4 s later (about 1.5 s from the switch flipping to the panel gone); Blurt is activated and
  the window the walk started from comes back (`orderFrontRegardless`, also when macOS keeps the focus on System
  Settings) with a check-mark line: "Done — dictation works in every app now." (dictation works) / "Done — Blurt has
  every permission it needs." / "Done for now — allow the rest here any time." (something skipped).
- **Screen Recording** may need a relaunch: the panel's step and Settings → Privacy have *Restart Blurt*
  (`open -n` of our own bundle once this process has exited, then terminate; the rest of the walk is kept in
  `app.permission_resume` and continues after the relaunch, within 10 minutes — with nothing left, as when Screen
  Recording is the walk's last step, the relaunched Blurt shows the done line and brings back the window the walk
  started from).
- Blurt never clicks, scripts or writes anything in System Settings, and never writes `AppleFnUsageType`.
- Test builds never register, never open a pane (unless `BLURT_TEST_OPEN_PANES=1`) and never relaunch; they emit
  `perm_request` / `perm_open_pane` / `perm_relaunch`. States are simulated with `BLURT_TEST_SCREEN_RECORDING`,
  `BLURT_TEST_MICROPHONE` (granted | denied | not_asked), `BLURT_TEST_ACCESSIBILITY`, `BLURT_TEST_INPUT_MONITORING`,
  `BLURT_TEST_FN_USAGE`, `BLURT_TEST_FN_APPS`, or the `perm …` hooks (`perm screen|mic|ax|im|fn …`, `perm guide`,
  `perm skip|cancel|restart`, `perm resume KINDS|- FLOW SOURCE` (the relaunched side), `perm standin …` — a window of the test app standing in for System Settings —, `perm drag
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
  with `prior` = the tail of the text so far appended to the custom-word context: Qwen3-ASR keeps a name spelled
  the same way all through. Measured below: on short takes it never leaked into the output, and it helped 1.7B.
  - **The echo (dict023, v0.9).** On a 43 s take whose speech repeats itself, the 5.5 s last piece came back as the
    text so far written out again (78–165 characters for 24 spoken; ~40 % of the take typed twice, and polish's
    correct de-duplication refused by the content-loss guard as `dropped`). Measured on that piece with 1.7B: 200
    characters of prior echoed every run, with or without the 146-word list; 80 or 40 characters gave the right 24
    every run, and the size of the word list made no difference. So `transcribe.py` sends only the last 80
    characters (`PRIOR_CHARS`, never starting inside a Latin word) and, with a prior, only the 32 most relevant words
    (`PRIOR_TERMS`, `dictation_vocab.ranked`). Behind that, a meaning-free net (`echoes_prior`): an answer with more
    syllables than its audio can hold (10 a second) or a run of ≥ 12 characters of the prior in it (spaces and
    punctuation aside) is decoded once more with the words only, and that answer is kept when it is clearly shorter
    (< 80 %) — someone who really says the same thing again gets the same text back and keeps it (`tag.echo` in the
    answer). With a forced 200-character prior the net turned 165 characters back into the right 24, three runs of
    three; it costs one more decode (~0.2 s) only when it fires.
- **…and polished right after** (a second serial queue): the polished text so far goes along as the request's
  `dictated` context, which polish shows as **the turn before** this one (§Polish windows: context, not output), so
  polish sees what came before but may not change or continue it (the guard's `copied` check, below).
  No piece is merged or held back for what it says (the v0.8.x correction merge and end-marker carry are gone:
  §Rules vs model): Light keeps a self-correction as said, and Structured resolves it over the whole take at key-up.
- **A cut is a pause, not a sentence end** (§Punctuation at the seams): a piece's own ending isn't final, and polish
  works over a window that spans the seam.
- **At key-up only the last piece is left** (polished together with the clause carried from the window before);
  with a pause ≥ 0.5 s before the release there is nothing left at all. Structured then runs the structuring pass
  once over the joined text (§Styles).
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

### Hearing again (v1.0.4)

What the user saw on long takes: whole words misheard — 德宝 / 豆宝 / 多宝 for 豆包, 巨幅 for GIF, 强势了 for 尝试了,
请问 for 千问 — and many manual fixes. A piece is cut at the first pause after 3 s, so most pieces are 3–8 s: half a
sentence, heard without the rest of it. Replayed through the app's own decode (`transcribe.py`'s `NoteEngine.note`,
the words, the text so far as prior) on 16 of the user's own takes with misheard words in them:

| What was decoded | Fixed (of 17) | Misheard words left (of 21) | The last decode at key-up (median / max) |
|---|---:|---:|---:|
| the take's own pieces (replayed) | 3 | 19 | 0.14 / 0.49 s |
| windows of the pieces, ≥ 10 s | 6 | 11 | 0.20 / 0.55 s |
| windows, ≥ 15 s | 7 | 11 | 0.25 / 0.76 s |
| windows, ≥ 20 s | 6 | 11 | 0.33 / 0.76 s |

So `DictationStream` hears the pieces **again in windows** while the user still talks (`DictationStitch.rehearGroups`,
`rehearWindow` = 10 s; `record.dictation.rehear`, `rehear_window_s`):

- **A window closes after a piece** once it spans 10 s and the cut after the piece was a pause — never at a hard cut,
  so windows never share audio: no overlap to drop, nothing deduplicated. Its audio (the take's own samples, from
  its first piece's start to its last piece's end) goes to the warm speech server once, with the windows' text so far
  as prior (the same request a piece makes).
- **Polish then works window by window** (the same carried-clause windows as before, §Polish windows), so polish sees
  whole sentences too. The pieces' own transcripts are still the live text while talking; what is typed comes from
  the windows.
- **At key-up the open window is what is left**: the pieces since the last window, with the last piece heard only
  there (`covered`: its own transcript would be thrown away). It is decoded like every other window — its audio and
  the text before it — so it is never worse than the old last piece; with a short tail it is just that piece.
- A window of one piece keeps that piece's transcript (the same audio); one the model fails on, or answers nothing for,
  keeps its pieces' (`dictation_rehear`: `ok`, `changed`); a covered piece in a failed window sends the take down the
  safety path (the whole recording), as a failed piece does.
- The history keeps both: `pieces` (each with `hard`, `covered`) and `windows` (`pieces`, `pieces_text`, `raw`,
  `asr_ms`), and `timing` has `windows` and `rehear_ms_all`. The Lab replays it (`rehear=on`, the default;
  `dictation_stitch.rehear_groups` is the port, the same cases in both test suites).

End to end in the Lab (22 of the user's takes, Qwen3-ASR 1.7B + Gemma 4 E2B, `mode=windows`): misheard words left 17 →
11 of 22 with 10 s windows (10 with 15 s), the work after key-up 266 → 376 ms (median; 601 ms with 15 s windows), so
10 s it is. Voice notes hear their pieces again the same way (`VoiceNoteStream`, `record.voice.rehear`): the card gets the windows' text, the panel the pieces' (`voice_rehear`).

### Punctuation at the seams

What the user saw: the meaning was kept, but there was **a full stop at every pause**, in the middle of sentences
(「…在路上的时候。不用再…」, 「好像是因为。网络断开…」, 「但是呢。它识别出来…」), and in English a capital after
it. Each piece was transcribed and polished as if it were a whole utterance, so Qwen3-ASR ended it with 。 and polish
kept it (polish only saw `before ▮` and the piece). Now (`DictationStitch`, `DictationStream`; pure parts in
`DictationStitchTests`):

- **The segmenter measures each pause** (`DictationSegmenter.pauses`: from the last speech frame before a cut to the
  first one after it, known once speech resumes; 0 for a hard cut).
- **A piece's trailing punctuation isn't final** (`seam`, `joinPieces`): 。.!?！？ and ，, at a seam are taken off
  after a breath; after a long pause (`longPause`, ≥ 1.2 s) the speech model's own mark stays (`mark`: its sentence
  end, else its comma). Mechanical: the v0.8.x stop-word test (`plausiblyFinal`: 的时候 / 是 / 也 / the / is … never
  end a sentence) and the ordinary-word list that lowered the capital a cut gave (`decapitalize`) are gone (§Rules vs
  model) — with polish on, the model decides both over a window that spans the seam. This is what polish-off
  dictation types, what a fall-back types, the joined transcript the stitch guard checks against, and the ASR's
  `prior`; there a long pause keeps the speech model's mark as it is, and a capital stays.
- **Polish decides over a sliding window** (`DictationStream.polish`): the window is the clause carried from the
  window before + the new piece (its ending taken off). What polish writes up to its last sentence end **or comma**
  is committed (`commitSplit`); the clause after it is carried and polished again with the next piece, so the
  punctuation across the pause is decided with both sides in view. Every comma inside a window was written with the
  words on both sides in view; only the window's own end wasn't, and that is what is carried. Carrying the whole
  unfinished sentence (the first version) made the window at key-up as long as the sentence: polish after key-up
  went from 150 to 302 ms (median) on these clips; one clause costs ~25 ms. The carried clause goes into the next window
  **with no mark, however long the pause** (`windowInput`, since v1.0.2: §Thinking pauses below; before, a long pause
  added the mark the window before ended in, and v0.8.x committed it as it was when a stop-word test judged the
  sentence whole). The last piece's window keeps its ending: the dictation ended there. A carried clause left when the dictation ends (nothing after the last cut) is
  typed with the punctuation polish gave it — no work after key-up.
- **The prompt** says it too: "fix punctuation across what are just pauses in speech; don't end a sentence at a pause
  unless the sentence is complete … and a capital the recognizer gave a word only because a pause came before it goes
  too" (with a synthetic example).
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

### Thinking pauses on real speech (v1.0.2)

What the user saw (real takes, Qwen3-ASR 1.7B + Gemma 4 E2B): a mark wherever they stopped to think, mid-clause —
「你可以，在我告诉你的时候」, 「针对性的进行，优化」, 「看一下，为什么识别错？以及？」, 「去在不同的界面去。展示」; 63 of 197
multi-piece takes had a 1–3 character fragment between two marks. The `say` clips above never showed it: their pauses
were 0.6–1.0 s inside a clause and 1.3 s at a sentence end, so a long pause always was an end.

Where the marks came from — replaying real spontaneous speech through the app's own pipeline (below):

- **After a long pause the window got a mark polish itself had written.** The carried clause went into the next
  window with `carryEnd`, the mark the window before had ended it with — polish's own, written without seeing what
  came next, so nearly always 。 (the speech model's is no better: it ends every piece with one). Given 「…但是。我报的是…」
  the model turned 。 into ， instead of dropping it: 5 of 15 mid-clause pauses ≥ 1.2 s at a cut kept a mark.
- **Inside a piece the marks are the speech model's.** At mid-clause pauses that didn't fall on a cut (the piece was
  still < 3 s, or the pause < 0.5 s of quiet), 35 % had a mark from Qwen3-ASR; polish took out a third of them
  and added none (the 12 left are all the speech model's). Not changed here: taking the speech model's marks out (`bare` below) lost
  a third of the marks said without a pause.
- **Polish's own commas at short seams**: 10 % of mid-clause pauses < 1.2 s at a cut, the same with every variant —
  the model's reading of the words.

Now (`DictationStitch.windowInput`, `DictationStream.polish`, `dictation_stitch.window_input`): **no pause puts a mark
into a window**; the carried clause and the new piece go in as one run of words and the model decides from them
whether the sentence ended. The seam rule (`seam`, `longPause`) still writes the transcript as said — polish off, a
refused window (`fallbackSeam`), the speech model's prior.

Eval (`scratchpad/…/seams/`, see its RERUN.txt; not in git): **real spontaneous speech with human punctuation** —
MagicData's open multi-stream conversation sample (HF `MagicDataTech/multi-stream-spontaneous-conversation-training-
datasets_chinese`: two people talking on their own phones, each on their own track, 10 h; a clip = one speaker's turn,
8–40 s, 200 clips with a pause) and 86 contextual-earnings22 chunks (English calls, 15 s). Qwen3-ForcedAligner-0.6B
timed every reference character; the app's own loudness rule found the quiet runs (≥ 0.6 s); each was placed in its
reference gap and classed by the reference's punctuation there (fillers 嗯/呃 out of the reference; the annotators'
segment-final commas, often at a hesitation, labelled by hand: 35 mid-clause, 16 clause breaks). The replay is the
Lab's `mode=windows` (`dictation_lab.run_case`: transcribe.py / polish.py serve, the prior, the windows, the stitch
guard) on cuts made by a port of `DictationSegmenter`; Qwen3-ASR 1.7B + Gemma 4 E2B, the scripts of 1d354c2b, the same
cached transcripts for every variant, the typed text aligned to the reference by units:

| 286 clips, 171 mid-clause pauses, 220 sentence ends at a pause | Before | **Now** (no mark) | Comma at a long pause | Mark only ≥ 2 s | "…" at a long pause | Polish off |
|---|---:|---:|---:|---:|---:|---:|
| Mid-clause pauses with a mark — all | 14.6 % | **11.8 %** | 14.6 % | 12.4 % | 14.7 % | 18.2 % |
| … ≥ 1.2 s at a cut (n = 15) | **33.3 %** | **0 %** | 33.3 % | 7.1 % | 35.7 % | 80 % |
| … ≥ 1.2 s, cut or not (n = 23) | 43.5 % | 22.7 % | 43.5 % | 27.3 % | 45.5 % | 72 % |
| … < 1.2 s | 10.1 % | 10.1 % | 10.1 % | 10.1 % | 10.1 % | 10.2 % |
| Sentence ends with any mark — all | 87.7 % | 83.8 % | 87.7 % | 84.3 % | 87.3 % | 40.4 % |
| … after ≥ 1.2 s (n = 65) | 95.4 % | **82.0 %** | 95.4 % | 83.9 % | 93.8 % | 92.9 % |
| … after ≥ 1.2 s, as a sentence end | 58.5 % | 39.3 % | 36.9 % | 41.9 % | 49.2 % | 87.1 % |
| Clause commas at a pause with a mark (n = 141) | 75.2 % | 73.8 % | 75.2 % | 73.8 % | 75.0 % | 22.0 % |
| Marks said without a pause, kept (n = 1025) / in fast speech ≥ 5.5 units/s (n = 132) | 87.9 / 97.0 % | 87.8 / 97.0 % | 87.9 / 97.0 % | 87.8 / 97.0 % | 87.8 / 97.0 % | 85.1 / 93.0 % |
| Punctuation F1 (a mark) / `<end>` F1 / `<pause>` F1 | 81.6 / 50.2 / 66.2 | 81.2 / 47.5 / 66.1 | 81.6 / 47.6 / 65.9 | 81.2 / 47.8 / 66.1 | 81.5 / 49.1 / 66.0 | 71.7 / 46.4 / 61.1 |
| CER | 9.49 % | 9.52 % | 9.47 % | 9.51 % | 9.49 % | 9.49 % |
| Polish after key-up (last window), median | 309 ms | 294 ms | 304 ms | 298 ms | 294 ms | — |

- **Thinking pauses at a cut: 5 of 15 got a mark, now none.** Those are the user's: 「报过绘画班但是，我报的是」,
  「草制药这种行业是需要，很多专业知识」, 「交给。对对对」. A pause ≥ 1.2 s that didn't fall on a cut is the speech
  model's mark (above), unchanged.
- **The price: some real sentence ends after a long pause lose their mark** — with any mark 95 → 82 % (11 of 61 without
  one, 3 of 65 before: 「…领导人对话会强调要携手…」, 「…加倍的努力还有许许多…」), and more of them are commas (59 → 39 %): Gemma 4
  E2B, deciding from the words, runs some sentences together. In a conversation long pauses at a sentence end are
  three times as common as thinking pauses; in dictation the thinking pauses are what the user reported, and the
  marks there read as errors where a missing full stop reads as a run-on. Overall F1 −0.4, `<end>` F1 −2.7.
- Fast, dense speech is untouched: the marks said without a pause are the same (87.9 → 87.8 %; 97 % in the fastest).
- A weaker hint isn't a middle ground: a comma or "…" at the long pause gives the same 33–36 % mid-clause marks
  (the model keeps a mark it's given); a mark only after ≥ 2 s gives 7 % and 84 % — the user's thinking pauses are
  often longer than that. The speech model's own end mark instead of polish's: no difference (it ends every piece).
  Carrying the whole sentence (63 clips): a long pause still kept its mark (3 of 4) and polish after key-up took
  +440 ms. Taking out the speech model's marks
  inside pieces (`bare`, 63 clips): mid-clause marks inside a piece 23 → 0 %, but marks said without a pause kept
  89 → 68 % and sentence ends 81 → 73 %: no. A prompt line asking for a full stop where a sentence is complete
  and the next starts, even with no mark there (a local copy of polish.py, with no mark): long-pause ends 82 → 83 %,
  takes that fell back 12 → 18 — not taken.
- Polish off keeps the seam rule (the speech model's mark after a long pause): with no model to decide, dropping it
  would leave the sentence ends there without a mark (93 % have one now).

### Polish windows: context, not output (v0.8.x)

What the `say` list clips showed (dictation-styles.md §3.7): on a list-like or longer take Gemma 4 E2B **repeated the
text so far in front of the new piece** (「明天要做三件事，第一，明天要做三件事，第一，把测试全部跑完…」), or answered with
the text so far alone; the guard rightly refused it (`copied`, `grew`), the window typed its transcript, and at a short
pause a transcript has no mark (「…跑完第二，把文档…」). The text so far was a "Near the cursor: …▮" line in the same
message as the new words. Now (`polish.py`, `DictationStream`, `scripts/dictation_stitch.py` for the lab):

- **The text so far is the previous exchange** (`context.dictated`, its last ~120 characters from a clause start):
  user → that text, assistant → that text, then the new piece. The model has just "answered" it, so it continues
  instead of repeating. On 15 hand-made list windows: repeated or refused 8 → 0 (`results/variants-*.txt`); a labelled
  "Already typed (context only — don't repeat it):" line with an example only got to 2–4. The field's own text stays
  "Near the cursor"; the cached prefix (rules + examples) is unchanged, and the extra turn is fewer tokens than the
  300 characters of context it replaces.
- **An echo is trimmed before the repair and the guard** (`polish.strip_echo`, DictationFit's overlap trim on polish's
  own output): the longest run at the start of the output that repeats the end of the text before the cursor —
  exactly, or ≥ 85 % alike (re-punctuated) for more than 4 units, and ending where that text ends — goes, unless the
  transcript itself starts with those words (said again). `echo` (units trimmed) in the answer.
- **One window falls back, not the take**: a refused window types its own transcript and the other windows keep their
  polish (as before), and now its seam — the pause before the piece — still gets punctuation
  (`DictationStitch.fallbackSeam`): the seam rule after a long pause; after a short one a comma where the speech model
  heard a boundary (it ended the piece with a mark) — no longer second-guessed by a list of words that "bind" to the
  next (把 / 的 / to / the: gone, §Rules vs model; the price, a rare 「把，」 in a refused window). When the joined
  result fails the stitch guard, the take types `joinPiecesForFallback` (the same commas) as said.
- **The capital a window gave itself goes** (`keepCase`): the input's first word was lower case (the sentence goes on),
  so "Update the docs" → "update the docs" — mechanical (the input's own case); the ordinary-word list
  (`decapitalize`) is gone.
- (v0.8.x kept a list's ordinals — first / second / finally — from being dropped by the repair with a word list; the
  repair is mechanical now, §Repair.)

Measured with the lab's replay of the windows (`dictation_lab.py run --config mode=windows`, below) on 60 synthetic
`say` cases (`promo/cases/v0.8-dictation-polish-fix/`, not in git: the 30 prompts of the built-in pack, 16 list-like /
long takes, 14 self-corrections and sentences where 不对 / 不是 is content; Tingting / Samantha, the fragments joined
by 0.6–0.9 s pauses, 1.3 s at sentence ends, cut where the segmenter would), Qwen3-ASR 1.7B + Gemma 4 E2B, the same
cases and servers, before = the scripts of a02db2de with the old windows (`legacy`):

| Lab, `mode=windows`, 3 rounds | Before (a02db2de) | Now |
|---|---:|---:|
| List-like / long takes (16 × 3): fell back | **36 / 48 (75 %)** — `copied` 24, `grew` 12 | **0 / 48** |
| The pack's prompts of ≥ 2 pieces (18 × 3) | 15 / 54 (28 %) — `copied` 12, `stitch_correction` 3 | **0 / 54** |
| The pack's one-piece prompts (12 × 3) | 0 / 36 | 0 / 36 |
| WER, list-like takes / everything else | 2.1 % / 8.6 % | 0.2 % / 2.7 % |
| Polish's 41-case eval: fall-backs, kept, unwanted words dropped, similarity | 0 %, 97.6 %, 95.1 %, 0.969 | 0 %, 97.6 %, 97.6 %, 0.974 |
| The over-deletion set (22): kept after the repair | 100 % | 100 % |

In the app itself (`results/app-e2e.jsonl`): the isolated test builds of a02db2de and of this change side by side,
the same models, 19 `say` WAVs fed in real time as the mic (`dictation wav`, released 0.1 s after the last word),
interleaved, two rounds — the styles eval's zh-list / en-list / zh-corr, 8 list-like clips, 3 corrections, 4 long
prompts of the pack, one plain sentence:

| In the app | Before | Now |
|---|---:|---:|
| Takes that fell back (any reason) | **28 / 38 (74 %)** — `copied` 15, `grew` 7, `correction` 6 | **0 / 38** |
| … of the multi-piece takes | 24 / 28 | 0 / 30 |
| Key-up → paste (`total_ms`), median / p90 | 462 / 631 ms | 382 / 477 ms |
| Paired difference, all takes / takes both polished (n = 8) | | **−58 ms / −24 ms** |
| Polish after key-up (the last window), median, multi-piece takes | 299 ms | 190 ms |
| Every window's polish (`polish_ms_all`, mostly while talking), median | 856 ms | 700 ms |

- It got faster, not slower: a model that repeated the text so far wrote twice the tokens, and a refusal had already
  paid for them. With both polished the turn costs nothing measurable (−24 ms paired, within the run's spread).
- Seen in the app run and fixed after it: Gemma 4 E2B wrote 「二 是改一下…，三 是…」 for a window that starts with a
  numeral; `clean_output` now never leaves a space between two CJK characters. A third round after that fix
  (`results/app-e2e-r2.jsonl`, 19 takes each): fell back 15 / 19 → 0 / 19, key-up → paste 413 → 346 ms median
  (paired −49 ms; −7 ms on the 4 takes both polished), no stray spaces.
- What the lab replay can't show: the fit at the cursor; real voices and rooms (only the user can check those).

## Live text (v0.9)

The report: "When I press Fn and talk, the recognised text isn't shown live. Double-tapping Fn sends straight away,
so seeing the text tells me whether to fix it by hand first or just send it." Before, the panel under the island
(`LiveTranscript`, `record.live_text`) showed only the finished pieces' transcripts: a take without pauses showed
nothing for up to 20 s, then a whole piece at once. Now the words keep up with the speech, as Typeless and Wispr Flow
do:

- **Interim decodes** (`DictationStream.interimIfDue`, on its own serial queue): about once a second, while the user
  talks, the open piece's audio so far (at most its last 20 s — the segmenter cuts at 20 s anyway) goes to the same
  warm speech server as a `note` request with `"interim": true`, with the same prior (the finished pieces' text) and
  words as a final piece. Only the warm server: no CLI fallback, no server start (a missing server is tried again
  later). Its text is never typed, filed or polished.
- **The final pieces always come first.** `BlurtCore/DictationLiveDecode` (pure, `DictationLiveDecodeTests`) sends an
  interim request only when none is in flight and no final piece is queued or being transcribed (`finalQueued` is
  counted on the main thread before the final request leaves; `finalDone` when its transcript is in). A cut that
  comes while an interim decode runs can't wait for it either: `transcribe.py serve` gives an interim request a stop
  check — is another connection waiting on the listening socket (`select`, no accept)? — and `Qwen3Mlx` looks at it
  before each chunk, before the prefill and between tokens, raising `Interrupted` (answer `{"ok": false, "code":
  "interrupted"}`). Interim requests always go through the tag-aware decode loop (it is ours, so it can stop; without
  a preferred language it takes the model's own tag, as the plain decode does). A quick backend (`quick_decode`:
  SenseVoice, one ~0.1 s CTC pass) is asked once before and then decodes whole — a final piece waits that long at
  most. A slow backend that can't stop halfway (Whisper on CT2, Qwen3-ASR on the CPU, a Qwen whose tag-aware decoder
  failed) answers `interim_unsupported`; the client waits `refusalBackoff` (4 s) and asks again, and only 3 refusals
  in a row stop interim text for the take (v0.9-fix2: one refusal used to turn it off, and SenseVoice — every tier's
  note model — refused them all, so notes never showed live words). Stale answers are dropped: a piece whose final transcript has landed, or an answer older than one
  already shown. At key-up nothing more is sent; an answer under way still shows until its piece is in.
- **Adaptive**: the interval is twice the smoothed decode time, within 0.8–1.2 s; smoothed over ≥ 3 decodes above
  0.9 s (a slow machine, a 20 s window on a slow model) turns interim decodes off for the take
  (`dictation_interim_off`); so do 3 failures in a row. The first decode of a session also waits for the model to
  warm up and doesn't count alone. For dictation the light / minimal tiers (< 16 GB, as `transcribe.py tier_for`)
  never start them: `record.dictation.live_partial` unset = by the machine, `true` / `false` to force. Voice notes and
  a snap's spoken note ask on every tier (`VoiceInput.liveWords`): their model is quick; only `record.live_text` off
  or an explicit `live_partial = false` turns them off.
- **What shows** (`DictationLiveDecode.compose`, mechanical only): the finished pieces' transcripts joined as the
  transcript is (`DictationStitch.joinPieces`: committed, 92 % white), then the interim texts of the pieces not final
  yet (pending, 60 %); an interim after a hard cut loses the words the piece before already has
  (`DictationStitch.dropOverlap`); when the seam mark of the committed text changes because more follows, the common
  part stays committed. No words are read for meaning.
- **The panel** (`LiveTextLines`): up to three lines while listening, newest at the bottom; the text typed after the
  stop is shown from its top, up to eight lines (the last fades out when there is more: `IslandLayout.liveLines`), so a
  Structured list's heading and first item are checked before a double tap sends it (v0.9 dogfood). The piece still being said never ends in the
  model's 。/? (`DictationLiveDecode.openEnded`, display only). A press shows no words until it has become a
  dictation (a hold in tap-only mode, Fn+← no longer flash them). The panel keeps the height it reached
  during the take (no shrinking back when an interim is revised shorter); the lines are laid out from a line start
  that only moves forward while the text before it is unchanged, so the lines showing don't re-wrap as the text grows;
  only the characters that changed since the last update fade in (the common prefix stays). The mint caret, the
  position rules and the no-rule look (`system.md`) are unchanged. After key-up the panel shows the final transcripts
  until the text is pasted, as before.
- Logged: `dictation_interim` (piece, audio_s, window_s, ms, result, shown), `dictation_live` (each update: committed /
  pending characters, `lag_ms` = now − when the newest audio the shown text covers arrived), `dictation_interim_off`;
  `dictation_text` carries `interim_sent` / `interim_shown`; `dictation_piece_text` the server's own `server_ms` (the
  rest of `ms` is the wait at the server's door).

Measured in the isolated test app (`promo/cases/v0.9-polish/livetext/`, not in git: `audio/` three `say` clips with
few pauses — zh 53.6 s, en 42.0 s, zh/en mixed 45.1 s; `results/`, `shots/`, `scripts/`), Qwen3-ASR 1.7B and Gemma 4
E2B warm, M5 Max, the wav fed in real time as the mic, released 0.1 s after the last word (the worst case: the last
piece is all still to do), interim decodes on and off alternately, 4 takes each (`results/summary-r3.txt`):

| Clip | first words shown (off → on) | lag, time-weighted mean | worst moment | key-up → paste, off | on |
|---|---:|---:|---:|---:|---:|
| zh, 53.6 s, 3 pieces | 20.5 s → 0.64 s | 10.2 s → 0.86 s | 19.9 s → 2.4 s | 1065–1218 ms (one 3664) | 1035–1552 ms |
| en, 42.0 s, 3 pieces | 20.8 s → 0.63 s | 10.4 s → 0.99 s | 20.8 s → 2.9 s | 509–556 ms | 506–583 ms |
| mixed, 45.1 s, 3 pieces | 21.0 s → 0.62 s | 9.7 s → 1.26 s | 20.4 s → 3.7 s | 621–798 ms | 600–760 ms |

- Lag: how far the newest word shown is behind the audio, over the time the user talks (it grows between updates and
  drops at each). Right at an update it is 330–410 ms (median; p90 0.58–1.02 s): the decode of the open piece so far,
  ~0.1 s for 1–2 s of it, 0.3–0.7 s for 10 s, ~1.1 s for 16 s of mixed speech. Mixed speech's long windows stretch
  the interval toward 2 s, hence its worse mean.
- Key-up → paste: no difference beyond the takes' own spread (median of all 12: 639 ms on, 652 ms off). The final
  pieces' wait at the server's door (`ms − server_ms`): median 2 ms either way, at most 63 ms with interim decodes on
  (27 interim decodes stopped for a final piece; the wait is one decoding step, or the prefill under way), ≤ 2 ms off.
- 39–59 interim requests a take, 95 % shown (the rest stale or stopped).
- Found on the way: `dictation stop-after` was a wall-clock timer, and a background test app's timers are coalesced —
  the release came 0.2–1.8 s late, later when the app was idle (interim decodes off), so the first comparison made
  "off" look ~1 s faster (the last piece was already done when the late release came). It now counts the audio fed
  (`Dictation.beginCapture`), exact to the 0.1 s buffer.

## Insert

1. Save the general pasteboard: every item, every type, as data.
2. Put the text, marked `org.nspasteboard.TransientType` so clipboard managers skip it.
3. Post ⌘V (HID level). `DictationPastePolicy` (BlurtCore, unit-tested) decides, the way Typeless does: **⌘V goes to
   any other app in front**, whatever its focused element looks like to Accessibility. Refused only when
   - there is no app in front;
   - Blurt itself is in front (its own text views get a `paste:` action; panels get nothing);
   - secure event input is on (`IsSecureEventInputEnabled()`: a password field anywhere), or the focused element is an
     `AXSecureTextField` (role or subrole) — then nothing is typed **or copied** (`hold`): the text stays in the
     history and the island says "光标在密码框里，没有输入" with **复制** — what was said there by accident never
     lands on the clipboard by itself, where clipboard managers keep it (v0.9 dogfood);
   - Accessibility isn't granted (a posted ⌘V wouldn't arrive).
4. Restore the old pasteboard once the paste has landed — 0.15 s after the field shows the text, or 1.5 s after
   ⌘V when the field can't be read (WeChat, Electron) — unless something else has changed it since (before: a fixed
   0.6 s that a slow app could beat, then paste — and send — the user's old clipboard). A double tap's Return goes
   when the field shows the text, or after 0.6 s at the latest (a field that never shows it exactly — it turns
   quotes or emoji into its own — only delays the clipboard). While pastes overlap (a
   reformat right after a dictation) one snapshot is held: the last paste to finish puts it back, so the user's
   clipboard is never replaced by dictated text (v0.9 dogfood #27).
5. Only into the app the take started in: when the app in front isn't the one at the key-down (compared by pid), the
   policy says `copy(app_changed)` — "已复制，⌘V 粘贴" / "Copied — paste with ⌘V" — and a queued Return is dropped.
   Test builds compare a simulated front app (`dictation front NAME`) and use a private pasteboard
   (`BLURT_TEST_PASTEBOARD`, else one of their own): a test never touches the user's clipboard.

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
  。.!?！？ (between two whole sentences it stays). The text before ends mid-sentence → no leading 「，」; it ends in
  punctuation → no second mark at the start (seen: polish repeated the field's 「今天的安排：」 — the overlap and its
  「：」 went);
- **the first word's capital** when the text before stops mid-sentence ("I think ▮"): polish's model decides, as a
  language model — is " the" or " The" the likelier next word after the text before (`polish.py sentence_case`, on the
  model's thread, ~20 ms warm)? A capital that only started a sentence goes (margin > 2 nats: a sentence word scored
  5–11 after "I think"; "Thursday", "John", "Python", "GitHub" keep theirs). Only a word written like a sentence start
  is asked ("The", not "iOS", "API" or "I"); a word of the user's own list keeps its spelling unasked. A reply too
  short to polish is asked too (`cmd: "case"`), by a model already loaded only — never a wait. Without polish the words
  go in as heard (only a transcript heard in lower case keeps it: `keepCase`). The v0.9 dogfood's "I think The new
  layout is fine." came from the speech model capitalising every piece; the prompt's note alone didn't move the 2B
  model (`tests/test_polish_case_model.py` with the model: `BLURT_TEST_POLISH_MODEL=…`);
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
- When Accessibility couldn't read the focus at all (`focusIsText` unknown: WeChat), the island says "Pasted" for a
  few seconds with **Copy Again**, in case it didn't land; the history keeps every text (copy from the Dictation page).
- When it read the focus and it isn't a text field (`focusIsText` false: the desktop, a web page with nothing focused,
  a list), ⌘V still goes (a spreadsheet or canvas may take it), but the text most likely went nowhere: the island
  keeps it — 「没找到输入框，文字在这里」 / "No text field here. Your text:", its first 80 characters, **Copy** and
  **Close** — until it is copied, closed or the next take starts (1.0.1; v1.0.0 said "Pasted" for 5 s and the text
  was gone from view, unlike Typeless). A double tap's Return isn't pressed there (it would rename the selected file
  or follow a link).
- Refused → the text stays on the clipboard and the island says "已复制，可粘贴" / "Copied — paste it with Command-V".
- **Test builds never post an event or create a tap.** A test build is one with `BLURT_TEST_COMMANDS=1` *or* a bundle
  id other than `dev.blurt.recorder`. In a test build the text goes only into the app's own test pad;
  `dictation paste-policy front=other text=unknown …` reports what the policy would decide.

## Takes in flight (v0.9 dogfood fixes)

What happens between a take's stop and its text being in (`Capture/Dictation/DictationTakes.swift`; the rules are
BlurtCore's `DictationTakeFlow.swift`, `DictationTakeFlowTests`):

- **The key is free at the stop.** Each stopped take is a `DictationTake` with everything its text needs (the app and
  pid at the key-down, the style decision, the context, its stream). A tap once the double-tap window of the stop has
  passed starts the next take while the last is still transcribing or structuring (before: `trigger.busy` swallowed
  it, and what the user said next was lost). `DictationPasteQueue` pastes the takes in the order they were said, one
  at a time, whichever finishes first. The trigger is told `pending`: a tap within the window is still the double
  tap's second one (Return after the paste); a third tap right after a send is a bounce and starts nothing.
- **Esc cancels a take on its way** (and the menu's Cancel): never pasted, its Return dropped, the island says
  "已取消" / "Cancelled" — with **Undo** for 5 s (`Dictation.undoSeconds`): Esc isn't swallowed, so an Esc meant for
  the app in front (vim, an autocomplete, a popover) would otherwise cost the take. The stopped takes keep their audio
  for that time (`cancelledTakes`, also in `DictationHistory.liveIDs`); Undo runs them again like Retry (pasted into
  the app they started in, else copied). Esc while listening says "已取消" too (it used to vanish silently; nothing is
  kept — the take was in front of the user). A paste already under way (⌘V until it has landed) can't be taken back.
  Another key or a click in push-to-talk's first second, before anything was cut, is a shortcut (Fn+← is Home): the
  take goes without "已取消" (`DictationTrigger.joinedEarly`).
- **Check before send.** After the stop the live panel shows the text actually typed — polished, structured — for
  1.5 s (`LiveTranscript.showTyped`; up to 4 s for a longer text), instead of disappearing 0.6 s after the paste with
  the raw transcript in it.
  Two ways to send are taught (guide, the setting's detail, a quiet tip for the first five takes in chat apps):
  tap to stop → check → double-tap; or double-tap instead of the stop tap. The near-miss double tap (≤ 0.8 s, nothing
  heard) still sends (product decision). While the panel shows the typed text, the caret after the words becomes the
  ok check (the design system's done shape): that is what is in. A top line that continues text above it fades in
  from its left edge (28 pt), so it reads as continued rather than cut mid-sentence. A tap-started take's listening
  aura waits out the double-tap window (`DictationGlow`), so an idle double tap (a send) never flashes it.
- **No speech model.** `transcribe.py dictation-models` is read at launch and whenever Settings reloads its model
  list (`DictationModels.$asr`); BlurtCore's `DictationSpeechModels` reads it. Its `ready` says whether a take can run
  with nothing downloaded: the selected model (local and on this Mac, or a cloud one with its key — judged by itself,
  not by being one of the Settings rows) **and** the VAD every take goes through (`silero_vad.onnx`, 0.6 MB, in
  `$BLURT_HOME/models`; a model in the Hugging Face cache counts as installed without it). `missing` lists what a
  download would bring. `transcribe.py dictation-models` is read once, by `DictationModels` (Settings' rows, the
  download manager's sizes, `dictationReady` for the welcome line and the assistant), and Dictation follows its
  `$asr` — one answer for every surface. Not ready: the key doesn't listen (no mic, no warm-up) and the island says
  "还没有语音模型（2.5 GB）· 下载" — or, with the model there and only the VAD missing, "还缺语音检测文件（不到 1 MB）·
  下载"; while that download runs, "语音模型还在下载（1.2 / 2.5 GB）· 查看"; the list unreadable: "还没有语音模型 ·
  查看模型…". The button calls `Dictation.getSpeechModel` — the one entry for a dictation's model download: one job
  in the app's one download manager (`ModelDownloads`; `DictationModels.dictationJob`) for
  `DictationSpeechModels.toGet`: the configured model when that is the one missing, else the recommended one; only the
  VAD → the selected model's `setup` (which brings just it, 0.6 MB) — never pinning the choice. The island says it
  started ("开始下载语音模型（2.5 GB）· 下载好就能按 Fn 听写 · 查看").
  A take that fails with model_missing asks `dictation-models` again (never assumes), and when the model (or VAD) is
  there later, the island offers **Retry** for the newest such take ("语音模型好了，刚才那段录音还在") — it is never
  pasted by itself minutes later.
- **Nothing is downloaded for a dictation.** Every dictation request carries `no_download` (finals and interims);
  the server also treats any `purpose: dictation` request that way; the CLI fallback runs `note --no-server
  --no-download`; dictation's preload is `serve --no-download` (a missing model stays unloaded). Before: an interim
  request loaded a missing model and began a 241 MB download mid-take, and the text came 110 s later.
- **Recognition failed.** `Dictation.transcribe` always answers — `ok`, or `code` (model_missing, timeout, …) — and
  `DictationStream.Result.asrError` carries it; an empty text is silence only when recognition worked. A failed take
  keeps its wav and a history row (`insert: none`, `reason: asr_failed:<code>`), and the island says what failed
  with **Retry** (no model: "还没有语音模型，录音还在" with **Download…**). Retry (the island, the Dictation page) runs
  the whole recording again and pastes like any take (from the page: copied). Before: "没听到内容", the audio
  deleted, nothing in the history.
- **A hung or slow server.** A server call gets `15 s + 1.5 × the audio` (`DictationASRFailure.serverTimeout`), not
  a flat minute; a server that doesn't answer in that time is given up on for a minute — that server, by its pid
  (`DictationServerGiveUp`): a fresh one started by the next key-down is used as soon as it is up — and, when Blurt
  started it, ended (the Python server, then `uv`), except while a voice note is waiting on it (it may only be busy
  with that note; the note has its own timeout and CLI fallback); the CLI no longer asks that same server first. Measured with the scratch
  app's server stopped (SIGSTOP): 25 s from the stop to the text for a 6 s take (before: 243 s).
- **A hang is told by the server's behaviour** (v0.9 dogfood: 21.6 s of dots for a 3 s take with the server
  stopped; most users would dictate again). The call is asked every ¼ s (`WarmServer.call(giveUp:)`) and given up on
  as soon as there is no answer after 3 s **and** the server's CPU time hasn't moved for 2 s, whatever the audio's
  length (`DictationASRFailure.hung`, `CPUWatch`) — a server that is loading or decoding keeps its CPU moving (~0.5 s
  of CPU per 0.5 s on a 4-minute file) and is waited for, up to `serverTimeout`; waiting half the audio as well held a
  stopped server's 20 s take 9.5 s. 3 s after the stop a take still on its way says so,
  with the way out: "还在识别… Esc 取消" / "还在润色… Esc 取消" (`Dictation.slowToastKey`; gone when it lands or is
  cancelled).
- **A stuck server is replaced, also one an earlier app left behind.** Servers end with `os._exit` after removing
  their run file (`_common.server_exit`; a preload that fails is inside the same `finally`): three servers of apps
  long gone sat deadlocked in Python's teardown for hours here, still holding their models, one still listening with
  its run file in place — and every dictation (relaunches included) waited ~20 s for it, then ran the CLI (~9 s).
  At the key-down (and the launch prewarm) the server the run file names is pinged (0.5 s) and looked at
  (`WarmServer.health`, `ProcessProbe`): it answers or its CPU moves → left alone; its process is gone or the pid now
  belongs to something else (its command line isn't `transcribe.py serve`, it started after the file was written) →
  the file goes; alive, a server, no answer, no CPU → stuck: ended (SIGKILL) whoever started it, the file removed, a
  fresh server started (`VoiceInput.replaceIfStuck`; the polish server the same way in `Dictation.warm`). A request
  that hung does the same. `dictation_asr_server given_up` says `ended` only when a process really went. A `uv` ended
  on purpose is not started again online (`WarmSpawn.retire`).
- **The forgotten hands-free take** (`DictationRunaway`): after 20 s without speech (`NoteEndpointer.quietSeconds`)
  "还在听 · 按 Fn 结束 · Esc 取消"; from 4:30 the ear counts down (`Dictation.earClock`, "−0:29"); at 5:00 "已到 5
  分钟上限，听写已结束" and the text goes in (only into the app it started in); the next tap within 4 s — as long as
  that line shows (`DictationTrigger.limitGrace`, `endedByItself`) — is taken as the stop that came late, not a new
  take (v0.9 dogfood: a tap 2–4 s later started one under the line). The last 30 s show the clock in the island's
  attention colour with one quiet "还剩 30 秒". A new take drops what the island said about the last one: its tip, the
  5-minute line, "还在识别…"; the stop drops ⇧'s Structured line (⇧ works only while listening).
- **What used to end in silence**: a skipped Return says why ("没有发送：需要辅助功能权限", "…光标在密码框里",
  "文字已复制，没有发送"); a press the mode doesn't use (`DictationTrigger.miss`: a tap in hold mode, a long press in
  tap mode) says how this mode starts, once a day — reported once (`DictationTrigger.takeMiss`), not again on every
  key and click that follows; a polish model or the recommended speech model missing says so once a day with
  Download… (not when the model that ran is the one the user chose in Settings).
- **Reformat and its toasts belong to a take.** ⌥⇧L while a take is on its way waits for it — the take said last,
  bound by id (`DictationReformatAfterPaste`): when that take is cancelled, fails or hears nothing, the request goes
  with it, and it never runs for a later take; the list
  chip and Undo act on the `DictationLastPaste` they were shown for, carry the key `dictation` (`Dictation.toastKey`)
  and go when the next take starts (`Island.dropToasts`). A reformat replaced in the field writes its `text` (and `before`) to the
  history, so the page shows the text as it stands, the first version under it.
- **Clear History** (Settings) never deletes the audio of a take still listening or on its way
  (`DictationHistory.liveIDs`), and posts `DictationHistory.changed`: reformat-last and the after-typing watch forget
  the cleared (or deleted) takes. It asks first in an alert sheet with the app icon (`DictationSettings.askClear`):
  *Clear dictation history?*, how many go (a plural) and their recordings only when some are still on disk, then *You
  can't undo this.* on its own line; Cancel is the default (↩ and Esc), *Clear History* the quiet red one.

## Polish

`polish.py serve --preload` keeps one MLX model warm:
- 127.0.0.1 with a token, in `$BLURT_HOME/run/polish-serve.json`;
- **ends** after 10 minutes without a request (`SERVE_IDLE`, `serve_exit_reason` in `_common.py`; the same for
  `transcribe.py serve`): unloading the model is ending the process. An "unload" (gc + `mx.clear_cache`) left most
  of the memory resident — Qwen3-ASR 1.7B went from 2.5 GB to 1.8 GB and stayed there until the process exited
  (arch091) — and the old rules kept the model up to 30 min and the server up to 4 h, ~5 GB for both, after Blurt
  had quit (dict026). Now: it ends after 10 idle minutes (`IDLE_CAP`: frequent use no longer stretches it), when the
  app that started it is gone (`--parent <pid>`, added by `WarmSpawn` to every server the app starts; checked
  between requests, so a CLI or agent request in flight is answered first, and a crash counts too), and on
  `{"cmd": "exit"}`. The next key-down starts it again (offline, `WarmSpawn`); the speech model is also warmed a few
  seconds after launch (`Dictation.prewarm`: dictation on, key heard, ≥ 16 GB, the dictation model installed — the
  first dictation took 5.9 s of ASR on a cold model, newc008), and as soon as the app's download manager brings
  dictation's model in (`ModelDownloads`: the Try-it moment after the assistant's download isn't cold), which costs its
  memory for those 10 minutes only;
- never downloads: the servers and the CLI fallback run with `BLURT_NO_DOWNLOAD=1` (a missing model is `model_missing`,
  never a three-minute hidden download behind a key press), and without a recogniser to run on
  (`DictationSpeechModels.ready`, §No speech model) the key starts nothing — the island says "no speech model yet
  (2.5 GB) · Download" or "still downloading (1.2 of 2.5 GB) · Show" instead of a false "nothing heard" (a model
  counts only with its VAD, `silero_vad.onnx`; when that is all that's missing, the offer is just it); while that
  isn't known yet (the list not read, or unreadable) the take goes ahead, and a `model_missing` answer fails the take
  (its recording kept, Retry once the model is in: §Recognition failed);
- says which mic when nothing was heard: "Didn't catch anything (AirPods) · Change Mic…", or "No sound from AirPods"
  when the level never left the floor the whole take (muted, the wrong input, a headset still connecting —
  `BlurtCore/NothingHeard`); Change Mic… opens Settings → Dictation's microphone;
- uses the ASR caps: `asr.limits` threads (3 here), MLX memory limit = 25 % of RAM, utility QoS + nice 10.
  Utility vs user-initiated made no difference to latency (108 vs 118 ms median: the work is on the GPU).

### Cloud polish (v1.0.4)

Opt-in (Settings → Models → Cloud polish, `speech.cloud_polish`; `DictationCloud`, `Settings/DictationCloudSheet.swift`): Light's windows
and Structured's pass at key-up go to a model the user set up — DeepSeek (the preset: `https://api.deepseek.com`,
`deepseek-flash`, thinking off), or their own OpenAI- or Anthropic-compatible API (base URL, model) — through the same
warm polish server (`polish.py` `cloud_polish`, `scripts/polish_cloud.py`). Every failure — no network, a refused key,
past its time (4 s + 6 ms a character), an answer the guard refuses — is answered by the local model instead
(`cloud_error` in the answer); without a local polish model the cloud one is the only one.

- **Measured** (30 of the user's takes, blind, Opus subagents and Codex): local Gemma 4 E2B 4.2 / 10, DeepSeek Flash
  with this prompt and the recent dictations 7.2 (the local prompt on DeepSeek: 6.2; Qwen3.6 27B 6.7, 35B-A3B 6.0,
  Qwen3.5 9B 5.5, Claude Haiku 5.5 6.3); the manual edits a take 3.9 → 1.4. DeepSeek from Beijing: 0.95 s median a
  call, p90 2.1 s; ≈ ¥0.0013 a take (¥3–4 a month at 80 takes a day, peak price).
- **The prompt** (`polish_cloud.LIGHT`): fix misheard words from the sentence, the words, the recent dictations, the
  app and what the model knows — only to a word that sounds alike; punctuate by meaning, not by pauses; leave out
  fillers, restarts and taken-back words; keep every point, number, name and the speaker's tone; never answer the
  text. Its examples name none of the evaluated takes' words.
- **What it is told besides the text**: the custom words (ranked as for the local model), the app's name (and the chat
  / terminal note), the text around the cursor, the stream's text so far (as the turn before), and the last 3
  dictations in the same app in the last 30 minutes (`DictationCloud.recent`, only with `context` on): they named
  the topic — 豆宝 → 豆包 needed them.
- **Structured stays two passes** (Light while talking, the structuring prompt over the whole take at key-up, as
  locally): one combined prompt, even tuned, left the 8-point list of a 241 s take a paragraph (lists in 2 of 3
  enumerating takes; two passes: 3 of 3).
- **The guard** trusts a cloud answer (`cloud=True`; the user's call, v1.0.4: the word-by-word rules were made for a 2B
  model and refused good answers — a fixed word in the other script (请问 → Qwen) was "translated", a joined take with
  three such fixes went back to the transcript). Only what is plainly not the dictation any more is refused: nothing
  at all, another language (the text's CJK share moved by > 0.25), a summary (more lost than Structured allows), an
  answer or a preface added, a list in Light. No word counts, no kept-word check, no number check, no repair. Every
  answer of the six evaluated models on the 30 takes passes; an answer to the text, or a summary, is still refused
  (`tests/test_polish_cloud.py`). The stitch guard over the joined windows uses the same allowance.
- **The key** is in the login Keychain (service "Blurt Cloud Polish", account = provider); the app sends it with each
  request to the local server, never to a file or a log. Test (in the sheet) runs `polish_cloud.py check` with the key
  on stdin. Never sent: the recording.
- **The reminder**: while it isn't on, the first dictation of each day ends with one island line — "Turn on cloud
  polish…" · Set Up… · Don't Remind Me (`cloud_hint` = false); `cloud_hint_day` is the day it was shown.
- Everywhere polish runs: dictation's windows and the safety path, Structured, reformat-last, a snap's / voice note's
  structuring pass. The Lab: `cloud=on` (the key from `BLURT_POLISH_API_KEY`).

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
- **Allowed (Light):** remove hesitations, fillers, stutters and repeats; add punctuation and paragraphs; fix obvious
  homophones. **Self-corrections stay as said** (since the model-first work): "use the model's intelligence, not
  hard-coded rules … if a self-correction isn't resolved, leaving the original wording is fine; resolve corrections
  in Structured, in Light don't adjust them." Structured is where a correction is resolved (§Styles).
- **Not allowed:** rewrite, summarize, translate, change the tone, answer or carry out the text, turn it into a list,
  or drop content. Mixed Chinese and English stays as spoken. **Numbers stay as said** (一点二万 never becomes 一万二).
- The prompt says it in so many words since the user's dictations lost a condition clause (turning "faster when
  short, slower when long" into "faster, slower when long") and an "or …" alternative, and wrote 「一点二万」 as
  「一万二」: "Apart from the
  fillers, stutters and the part a speaker took back, every word stays. Never remove a phrase that carries meaning,
  even when the sentence sounds clumsy with it: a condition, a contrast, an alternative, a name, a number."
  The price: Gemma 4 E2B now leaves a filler in 4 of the 41 sentences (就是那个, 就是说, 那个, like: fillers removed
  97 % → 88 %). A first version that also said "When unsure, keep it" left a correction unapplied as well, so that
  sentence went.

**The model-first prompt** (Light): the fillers are described as "words that only fill a pause and carry no meaning
here" (examples given, not a list the code applies), and "Self-corrections are not fillers: … keep what they said
first, the words with which they corrected themselves, and the new version". What it cost on the 41-case eval (Gemma
4 E2B, `results/polish-polish_eval-*.json` in `promo/cases/v0.8-dictation-model-first/`; the correction cases now
expect every word kept): fillers removed 91.2 % → 73.5 %, similarity 0.974 → 0.969, fall-backs 0 → 1 (en-04: the
model resolved "Alice, sorry, I mean to Bob", the repair put back more than 40 %, the transcript was typed — every
word), untouched sentences 100 % both, warm 127 → 138 ms median. The over-deletion set: every phrase kept after the
repair both (100 %), fillers removed 87.5 → 81.2 %. Where the fillers went: the model now leaves some 就是说 / 那个 / 啊
(it was told every other word stays), and the mechanical repair puts back a three-unit filler run the model did drop
mid-sentence (就是那个, "you know it just", 呢然后): without a filler list it can't tell those from three words of
content. A prompt that repeated "always remove them, wherever they are" won one more filler of 31 (adopted); an extra
filler-heavy example made the model translate an English sentence (not adopted).

A prompt variant with a "translate this to Japanese" example primed the models to translate and formalize: fall-backs
went 7 % → 22 % (Qwen3 4B) and 12 % → 63 % (Gemma 3 4B). So the examples avoid instruction-shaped sentences.

### Content-loss guard

Every output is checked. On any failure the dictation types the **raw** text, and the history marks it "fell back"
with the reason. Units counted: each CJK character, each Latin word, each digit. What was said twice in a row is
counted once (a stutter is no content). **Mechanical only** (§Rules vs model): alignment, counts, scripts, layout —
no filler, correction-marker, question or preface word lists; what the words mean is the model's job.

| Check | Falls back when |
|---|---|
| `empty` | the output has no units |
| `term` | a custom word that was spoken (any case or spacing) is missing from the output |
| `translated` | a spoken Latin word vanished while ≥ 2 new CJK characters appeared, or the reverse |
| `shrunk` | loss > max(8 units, 25 % of the input); Structured: max(12, 40 %) + 2 per list line (the counting word its number stands for) |
| `grew` | output > 1.25 × input + 8 units |
| `chatty` | ≥ 3 units in a row at the start or the end of the output that follow nothing that was said (each unit and the next were never said one after the other, and neither is a custom or context word): a preface ("好的，下面是…", "Sure, here is…"), a sign-off ("Hope this helps"), an answer. A run ends at a line break: one-word list items ("1. Speed\n2. Cost") are neighbours only on the page |
| `novel` | more than max(4, 15 % of output) units that aren't in the input (digits exempt: 五零零 → 500), the custom words or the context — or more than half of the output |
| `listed` | Light: more numbered / bulleted lines than the input had |
| `dropped` (Structured) | one run of the input left out (not moved) is longer than 14 units: content, not a taken-back phrase |
| `number` (Structured) | a number it wrote wasn't said (as said, or the same value in digits): 「三百，三百五」 → 「三百三十五」 |
| `copied` | 6 units in a row of the context (the text around the cursor, or a streamed dictation's polished text so far) that weren't spoken: the model continued the document |
| `dropped` | the repair (below) had to put back more than 40 % of the content: the polish was bad |
| `timeout` | no answer within `record.dictation.polish_timeout_ms` (3000) after the model is loaded; the server stops generating at the deadline |
| `error` / `unavailable` | the model raised, or the server never came up within the load budget |

Why these thresholds:
- Every hand-written reference output in the eval set passes (Light's, and the structured references through the
  structured guard). Light keeps corrections now, so its largest legitimate shrink is a few units of fillers and
  stutters, inside the flat 8; Structured's — a correction resolved in a short sentence plus the counting words that
  became numbers — gets max(12, 40 %) plus 2 units per list line, with the 14-unit run and the number check keeping a
  summary out.
- v1.0.3 (issue #14): max(12, 40 %) alone refused 9 of 35 correct short lists from Gemma 4 E2B (「帮我做三件事，第一，改
  登录页；第二，修那个按钮，不对，是修导航栏；第三，写测试」 31 → 17 units: the counting words and the taken-back phrase
  are half of it), so ⇧ typed the plain text. 2 per list line passes all of them; 12 of 18 hand-written bad outputs
  (summaries, dropped items) are still caught, as before, but 6 short ones now pass — a 3-item list that drops 买 from
  every item, a 5-item list cut to 3: short enough to see at a glance, and the model wrote none of them in 35 runs.
  14 units per run: a correction that repeats its counting word (第四是酒店，不对，酒店不用，第四是保险). Fixture:
  `tests/fixtures/structured_guard.jsonl`. A refused list says so on the island (「没能排成清单，文字保持原样」).
- A summary or a list rewrite loses 30–60 % of a long input, well past 25 %.
- Short inputs get the flat 8, because one dropped clause in a 12-unit sentence is still a meaningful loss, and a
  pure ratio would allow almost nothing there.
- Homophone fixes add 1–2 new characters (部署, 再), under the novel slack of 4.

(v0.8: on all 410 model outputs of the final run, the guard caught 61 of the 88 outputs that the scripted check
marks as losing a key term or touching an untouched sentence, and fell back on 7 of 322 good outputs.) Without the
question pattern, a short answer that reuses the question's words ("what's the capital of France" → "The capital of
France is Paris.") can pass: `answered` was a regex on the language; the prompt forbids answering, and longer answers
are `chatty` / `novel`.

### Repair: dropped words go back in

The guard counts totals, so one dropped clause in a long dictation stayed inside its slack (D's condition clause
passed).
`polish.repair` (before the guard) aligns the transcript with the output (difflib over units) and looks at every span
the output left out. **Mechanical** (§Rules vs model) — no filler, discourse-word, marker or "always keep" lists:
- **may go**: what was said twice (a stutter, a repetition right before or after, a restart that says the same words
  again); words that were only moved (they appear where the output has words the transcript doesn't); and a span of
  at most `DROP_MAX` = 2 units once its repetitions are out (3 at the very start of the text, where hesitations pile
  up: 嗯那个…, um so…) — the size of a hesitation or a filler, which the model removes on the prompt's say-so;
- **anything else is put back where it was said**, as said (punctuation from the transcript before and after it),
  instead of throwing the whole polish away — **a self-correction's corrected-away words included**: Light keeps them
  (the prompt says so; this makes sure). A restart that says something different the second time (改成十四，改成十六)
  is a restatement, never a stutter. Words said elsewhere written in a span's place ("thirty seconds, no, make it
  sixty" → "sixty seconds") are a substitution: what was said there goes back, whatever its size;
- **numbers**: a number run written differently — or with numerals left out of it — is replaced by the spoken one
  unless it is the same value in digits (三十 → 30, 十七点二 → 17.2, 五零零 → 500, 二点三点一 → 2.3.1) or a value said
  elsewhere in the dictation. 一点二万 → 一万二, 三千五百 → 三千五 and 四十二点五 → 四十二 go back. (Numerals are a
  notation compared by value, not words read for meaning.)
- More than 40 % of the content put back → `dropped` (the raw text). The history keeps the spans (`repaired`).
- Calibration (`tests/test_polish.py::Repair`): every over-deleting output of the over-deletion set gets its phrases
  back but one — 「凌晨」 (two units on their own, a filler's size: the one loss a size rule can't tell from a
  hesitation). Four references of the 41-case set drop a three-unit filler mid-sentence (就是说, 就是那个, "you know it
  just", 呢然后): the repair puts those words back (with no filler list it can't tell 就是说 from 或辅导); the model
  itself mostly keeps those fillers now anyway.

### Self-corrections: the speaker's words in Light, the model's call in Structured (model-first)

The user's principle: "use the model's intelligence, not hard-coded rules … if a self-correction isn't resolved,
leaving the original wording is fine. Resolve corrections in the Structured style; in Light, don't adjust them." And
「不对」 was only their example: nothing may be built around particular words, in either direction.

- **Light keeps them.** The prompt says so in words ("Self-corrections are not fillers: … keep what they said first,
  the words with which they corrected themselves, and the new version — all of it, just punctuated; the reader
  decides which version counts, not you"), and two of its examples keep a correction, in different words (哦不,
  "actually no"). Nothing forces a correction: the guard has no correction check, and when the model resolves one
  anyway the repair puts the corrected-away words back (they are more than a hesitation's size, §Repair); a restart
  that says something different the second time (改成十四，改成十六) is never taken for a stutter.
- **Structured resolves them**, in the same model pass that lays out lists (polish.py `structure`, §Styles): "when the
  speaker takes something back or restates it — in whatever words, or just by saying it again differently — keep only
  the version they settled on … When you can't tell whether something was taken back, keep it." Its examples use
  哦不是, 算了还是, a bare restatement ("twenty thousand, twenty-five thousand") and a postposed "I mean". Unresolved is
  fine: the text keeps what was said. Its guard lets a taken-back phrase go (≤ 14 units in a run, ≤ max(12, 40 %) + 2
  per list line in all) but not a clause, a custom word (`term`) or a number that wasn't said (`number`): then Light's text is typed.
- **Gone** (v0.8.x, §Rules vs model): `dictation_corrections.py` (the deterministic pass before the model — its marker
  table, the shapes it resolved, the two extra prompt examples for unresolved markers), the stream's correction merge
  and end-marker carry (`startsWithCorrection`, `endsWithCorrection`, `commaJoin`), the guard's `correction` check and
  marker / lead-in lists, the repair's marker lists, the stitch guard's "passes with the corrections resolved".

Measured with the Dictation Lab's replay of the windows (`mode=windows`), the 60 cases of
`promo/cases/v0.8-dictation-polish-fix/` + 28 new ones (`promo/cases/v0.8-dictation-model-first/`: 20 self-corrections
in varied words — 哦不, 我是说, 改成…改成, 算了还是, 应该是…应该是, 错了, 啊不是, a bare restatement, 等一下, 不，, 换成, I mean,
actually, no make it, or rather, wait, scratch that, sorry, an implicit "the left, um, the right" — and 8 sentences
where 我说的不是 / 我是说过 / 算了 / 错了 / I mean it / Actually / No, wait for me / Sorry are content), Tingting /
Samantha, Qwen3-ASR 1.7B + Gemma 4 E2B, two rounds each, before = the scripts of 85783513 (the deterministic pass +
the old prompt; Structured = the rule-based list renderer), interleaved. 34 takes with a correction (14 old + 20 new):

| | Before | Now |
|---|---:|---:|
| Light: every word of the correction typed (first version, the correcting words, the new version) | 20 / 68 (29 %) | **66 / 68 (97 %)** |
| Structured: resolved (only the settled version) | 46 / 68 (68 %) | **56 / 68 (82 %)** |
| Structured: left as said (fine) | 22 / 68 | 10 / 68 |
| Structured: the settled version lost | 0 / 68 | 2 / 68 |
| Sentences where the same words are content (12 × 2), kept | 22 / 24 | **24 / 24** |

- Light's two misses are one case twice: 「把这个文件，不对，这两个文件…」 — the model wrote the first version as 「这两个文件」
  too (a word added, not dropped: the repair doesn't see it).
- Structured's two losses are one case twice: 「把这一段删掉，不，保留，只改第一句」 → 「只改第一句。」 (8 units gone — within
  the guard's allowance for a taken-back phrase). Its refusals (4) typed Light's text: 「三百，三百五」 written 「三百三十五」
  (`number`), and 「用 Claude 写，不对，用 Codex 写」, which drops a custom word (`term`).
- Before, Light resolved most corrections itself (the deterministic pass and the old prompt), and some went wrong
  without a refusal: 「这个接口应该是 POST，呃，应该是 PUT 才对」 → 「…应该是 PUT，应该是 POST 才对。」 (swapped),
  「颜色用蓝色，算了还是用灰色」 → 「颜色用蓝色，还是用灰色？」, "I mean it, this is the best version" → "This is the best
  version" (content dropped). None of those now.
- The 41-case polish eval (its correction cases' references now keep every word for Light; a `structured` block holds
  the resolved ones): Structured resolves all 8 of its corrections (`polish.py eval --style structured`).

## Styles

The plan and the research behind it: `dictation-styles.md` (§3, build steps 1–4 and 6; step 5, spoken triggers, was
dropped: the user dictates instructions to AI agents, where 「帮我列个清单」 / "make a list" is content). Light — the
polish above — stays the default everywhere and never restructures. Which style a take gets is the user's choice
(settings, ⇧, the island); what a style does with the words is the polish model's (§Rules vs model).

| Style | What is typed | How |
|---|---|---|
| Verbatim | the transcript (custom words fixed), its punctuation | polish skipped for the whole take (decided at the key-down) |
| Light (default) | polish's text: every word said, self-corrections included; never a list | unchanged |
| Structured | Light's text after one more pass of the same model: self-corrections resolved, and what the speaker enumerated as `1. …` lines (the sentence before them a line ending in 「：」/ ":") — or a paragraph when nothing was enumerated | polish.py `structure` on the stitched text at key-up (`DictationStream.finish(structure:)`); its own guard; a refusal types Light's |
| Auto lists | Light, and the structured text only when the model made it a list (≥ 2 list lines) | the same pass |

- **Router** (`DictationStyleRouter`, the user's choices): explicit this take (⇧, the island, Fn+⇧) > the app's own
  style (`styles.apps`) > its category's > `styles.default` > light. Categories (`DictationAppCategory`, exact bundle
  ids, then whole parts of the id — never substrings, so 1Password isn't Word): chat (WeChat, QQ, Slack, Telegram,
  Messages, Discord, Feishu / Lark, DingTalk, WhatsApp, Teams…), code (Terminal, iTerm2, Warp, Ghostty, VS Code,
  Cursor, Xcode, JetBrains, Zed…), mail, notes (Notes, Obsidian, Notion, Bear, Pages, Word…), other.
- **Variants of light** (`DictationStyleVariant`, before the fit): chat — polish's request carries `variant: "chat"`,
  and the last message says "a chat message: keep its tone words and sentence-final particles" (after the cached
  prefix, which is the same for every variant; the v0.8 particle list in the repair is gone) — and the closing 。 / .
  of a one-sentence message goes (not ？！, an ellipsis or a decimal), blank lines become single ones; code and
  terminals get one line (a multi-line paste collapses into "[Pasted N lines]" in Claude Code), unless a list was
  typed; mail and notes as light. Layout only.
- **The structuring pass** (`polish.py` `Engine.structure`, `SYSTEM_STRUCTURE` + 9 examples, its own cached prefix):
  1. resolve self-corrections (§Self-corrections); 2. lists only when the speaker really enumerates — counts off points
  or steps, or announces several items and names them — with the counting words (第一, 首先, first …) becoming the
  numbers; otherwise the text comes back as it is; 3. (v1.0.3) a long text that moves from part to part gets a
  paragraph per part, a list inside a part as above — a 280 s take with 「第一个是…第二个是…再有是…」 inside its second
  part came back as one block, now a paragraph and a 3-item list (same 3.3 s). Never rewrite, summarize, add headings or words, translate, answer.
  The examples are varied on purpose: two Chinese lists (首先…其次…最后 with a correction inside; 第一个是…第二个是…),
  an English one, a long one in parts (paragraphs, a list in the last), an implicit one (「三点进展：…，…，…」), prose with a correction, a bare restatement, and two
  sentences that look like lists but aren't (「我第一次用…」, "At first I thought…"). Output: Markdown emphasis and
  heading marks taken off (`clean_structured`); the guard in structured mode (§Guard: numbers aren't words, a run
  > 14 units lost is `dropped`, a number not said is `number`).
- **At key-up** the windows finish as for Light (the last one included), the stitch guard checks the joined text, then
  the structuring pass runs once on it (`structure_timeout_ms`, 10 s); the island stays on "polishing". Tried and
  measured, not kept: feeding the last piece to the structuring pass as heard (skipping its Light window) saved
  ~120 ms after key-up but resolved fewer corrections (25 vs 28 of 34 on one round) — the model had to tidy and
  structure at once.
- **At the cursor**: a list skips `DictationFit`'s trimming and starts on a line of its own when the text before the
  cursor doesn't end in a line break; a structured paragraph is fitted like Light.
- **⇧ during the take / Fn+⇧ / the island** (§Trigger): `Dictation.toggleStyle` flips Structured ↔ the take's own
  style (`DictationStyleRouter.toggled`); the island's right ear shows a list mark beside the clock while Structured
  (quotes while Verbatim, nothing for light), and the first two times a one-line toast says what Structured does (`DictationStyleToggleHint`). A take whose app is Verbatim stays
  unpolished when ⇧ makes it Structured (polish was decided at the key-down); the structuring pass runs on the
  transcript (its prompt also tidies hesitations and punctuation).
- **Reformat-last** (`⌥⇧L`, `record.hotkeys.reformat`, configurable in Settings → Shortcuts; no clash with Blurt's
  ⌥⇧ keys, ⌥⌘D or the lab's ⌥⌘L): the last take in the next style of the cycle verbatim → light → structured →
  verbatim that reads differently. Light for a verbatim take and the structured text for a light one are made on demand
  by the same model passes (`withLight`, `withStructured`; off the dictation's path; a take that was typed Structured
  keeps its pass's text). It replaces the text in the field only while it is exactly as typed, between the same
  40-character anchors (`DictationReformat.span`; the field re-read, the span selected — the test pad's text view,
  another app's field through Accessibility, read back — and pasted as a dictation is); otherwise, after 5 minutes, or
  in a field that can't be read (WeChat), the new version goes to the clipboard and the island says so. The island
  offers **Undo** (back to the style it was typed in). The after-typing watch restarts on the new text.
- **The list chip** (`suggest_lists`): after a light take long enough to hold a list is pasted (24 CJK characters or
  12 Latin words — a word counts as two characters, `DictationStitch.mayHoldList`; counting both alike, the English
  three-point list never got the chip), the structuring pass runs in the
  background; when the model made it a list, the island offers **Make a List** for 6 s (one click types the list it
  already has) and the history records `suggest`. Nothing on the dictation's path waits for it. (v0.8 offered it when
  the rule-based renderer counted ≥ 2 ordinal markers.)
- **History** (§History): `style`, `style_source`, `style_router`, and `reformats` — every reformat, undo, `revert`
  (the watch saw a typed list taken apart: ≥ 2 numbered lines → < 2, ≥ 70 % of the words still there) and `suggest`;
  `structure_ms` in the timings, `dictation_structure` events (ms, list, fell_back, reason).
- **Learning** (`DictationStyleLearn`, `learn_styles`): each take may say what the user wants in its app — a kept
  reformat or an undo, ⇧ / the island / Fn+⇧, a revert, a list the island offered and the user left as prose. With ≥ 3
  signals among the app's last 10 and ≥ 70 % of them one way, different from the app's style now, the island asks once
  (「以后在 备忘录 里自动排清单？」 好 / 不用; lists → Auto lists, never Structured always) and remembers it asked
  (`style_asked`). Yes sets `styles.apps[bundle]` and marks it learned; Settings → Dictation → Style shows it with
  Reset. Nothing ever changes by itself.
- **Settings → Dictation → Style** (v0.9: polish Off / Light and Style were two overlapping controls, audit newc010 /
  dict027): **one** choice, a popup in the page's popup column — Verbatim / Light / Structured / Auto — with one line
  under the title on what the chosen one does
  (`BlurtCore/DictationStyleChoice`, over the keys the engine already reads: Verbatim = `polish: "off"` plus
  `styles.default: "verbatim"`, so its takes say Verbatim in the history; the others = `polish` unset plus their
  style as `styles.default`, Light unset). Folded under *By kind of app* (not shown for Verbatim): one picker per
  category (*Same as above (…)* or a style), the apps set on their own, *Offer a list when a take sounds like one*,
  *Suggest an app's style from how I switch*, the polish time limit and the keys.
- **History detail** reports the style that **ran** (`DictationEntryReport.styleRan`: Verbatim when nothing polished
  the take — style, polish off, no model, a fall-back —, Light when Structured's pass gave nothing back or Auto made no
  list) and what polish did (`DictationEntryReport.polish`: the model by name, typed as heard, too short, off, or *No
  polish model · Download…*), and both models by their names (`DictationModels`), never their ids.
- **Dictation Lab**: Compare has Style: Verbatim / Structured / Auto lists; `dictation_lab.py` takes `style=` and
  `category=` (default: the case's app); Structured / Auto call polish.py's `structure` on Light's stitched text, as the
  app does (rows carry `structured`: list, fell_back, reason, ms; timings `structure_ms`, `last_polish_ms`,
  `after_keyup_ms`), and every run counts `listed` — a light (or verbatim) output with more numbered lines than its
  truth — in `overall.listed`; `--fail-on-regression` fails on it.
- Test hooks: `dictation keys … shift-down@… shift-up@… island@…`, `dictation style status | toggle [island] | reformat
  | chip | undo | set CATEGORY|BUNDLE STYLE|- | app BUNDLE | suggest BUNDLE | answer yes|no | reset`.

Measured (the lab's replay of the windows, the 88 cases above, two rounds each, interleaved, before = 85783513):

| Lab, `mode=windows` | Before | Now |
|---|---:|---:|
| Light: a list typed | 0 / 176 | 0 / 176 |
| Light: words (WER vs the truth, cases without a correction) | 1.26 % | 1.35 % |
| Light: punctuation errors (marks in changed chunks / the truth's marks) | 14.1 % | 16.7 % |
| Light: fall-backs | 4 (2 `dropped`, 2 `correction`) | 4 (`dropped`: the transcript typed, every word) |
| Light: what is left after key-up (the last window's polish), median / p90 | 111 / 184 ms | 120 / 191 ms |
| … multi-piece takes | 134 / 225 ms | 140 / 214 ms |
| Structured: list decisions right (21 takes whose truth clearly is / isn't a list, × 2) | 18 / 24 | 18 / 24 |
| Structured: words kept in the list takes (counting words and numbers aside) | 99.4 % | 97.4 % |
| Structured: refused (Light's text typed) | — | 4 / 176 (`number` 2, `term` 2) |
| Structured: after key-up (last window + the pass), median / p90 | 131 / 198 ms (renderer ≈ 0) | 277 / 553 ms |
| … the structuring pass alone | — | 130 / 367 ms |

- Lists: the misses moved. Before, the renderer missed lists where a seam had lost its comma or "first, …" lacked the
  capital it wanted (l01, l06, l16); now the model leaves three enumerations as prose — 首先…其次…最后 in one breath
  (b010), 「第一个问题是…第二个问题是…第三个问题是…」 inside one long sentence (l13), and 第一期 / 第二期 (l16). Prompt
  variants that insisted ("counting off two or more points is always a list", one more example) didn't move them.
- Words kept in lists: the model drops counting phrases with the ordinals (一个是…，一个是…，还有 → items), which the
  measure counts as loss, and once a word.
- Latency is the price of a model pass, paid only when Structured is asked for: +~0.15 s median, +~0.35 s p90 after
  key-up on these 3–15 s takes (the 41-case eval: 148 ms median for the pass). Light's own latency is unchanged (the
  +9 ms median is within the rounds' spread: the same code path, one prompt longer by a few tokens).

In the app (`results/app-e2e.jsonl`): the isolated test build of this change, 10 `say` WAVs fed in real time as the
mic (`dictation wav`, released 0.1 s after the last word), each typed in Light and in Structured back to back, two
rounds, warm models (M5 Max). Key-up → paste (`total_ms`):

| | Median | p90 |
|---|---:|---:|
| Light (20 takes) | 342 ms | 382 ms |
| Structured (20 takes) | 477 ms | 647 ms |
| Structured − Light, paired | +148 ms | max +501 ms (a 25 s English take: the pass wrote ~90 words) |
| the structuring pass (`structure_ms`) | 151 ms | — |

- Lists typed: list-l01 (第一…第二…第三) and list-l02 (First … second … finally) both rounds; list-l13 (第一个问题是…
  inside one sentence) and lab-b026 (an English run-on plan) stayed prose. Corrections resolved in Structured: vc01
  哦不, vc10 等一下, vc17 I mean, vc22 scratch that; left as said: corr-c01 (heard 「把这个不对，这两个…」, no mark
  before 不对) and lab-b030.
- Light kept every correction's words in 5 of the 6 correction clips; in lab-b030 (「资料我晚上发群里，不对，下午就发」)
  the model dropped 「不对」 in both rounds and the repair let it go — two units, a filler's size (§Repair: the price of
  having no marker list; `DROP_MAX` = 1 would keep it but, on the 41-case eval, cut the fillers removed from 73.5 % to
  50 %). The lab replay of the same clip kept it.
- Not measured in the app: a before build side by side (the Light path is the same code; the lab's paired rounds
  above show its latency unchanged).

## Rules vs model

The user's principle (the model-first work): "use the model's intelligence, not hard-coded rules. Regexes and word
lists for understanding language shouldn't appear." Every hard-coded language rule the dictation pipeline had, and
what became of it: **(a)** replaced with the model (the polish pass already sees the window; the structuring pass the
whole take), **(b)** kept as a mechanical safety net that doesn't interpret meaning, **(c)** removed.

| Rule (where) | What it did | Decision |
|---|---|---|
| Self-correction pass (`dictation_corrections.py`: marker table 不对 / 我是说 / 哦不 / no wait / I mean …, the shapes it resolved, two extra prompt examples when a marker was left) | resolved corrections before the model | **(c)**: deleted. Light keeps corrections; Structured's model pass resolves them (§Self-corrections) |
| Stream: `startsWithCorrection` / `endsWithCorrection` / `commaJoin` (marker lists; 不对称 & co. exceptions) | merged a correction piece with the window before, carried a piece ending on a marker | **(c)**: no piece is merged or held back for its words |
| Guard: `correction` check, `_CORRECTION` / `_CANCEL` markers, `cancelled`, `_LEAD_IN` words, `CORRECTION_SLACK`, the taken-back custom word | refused an unapplied correction; allowed more shrink per marker | **(c)**: Light keeps corrections; Structured's guard allows a taken-back run by size (≤ 12 units) |
| Repair: `_MARKERS`, `_STRONG_MARKERS`, `_SOFT` discourse words, `_KEEP_ALWAYS` (不 / 没 / 或 / only … and first / second …) | decided which dropped spans "carry meaning" | **(b)**, made mechanical: a dropped span goes back unless it was said twice, moved, or ≤ 2 units (3 at the start) once repetitions are out; a substitution always goes back (§Repair) |
| Filler lists (`_FILLERS_ZH` / `_FILLERS_EN` in the guard and the repair's put-back cleaning) | stripped fillers before comparing; cleaned put-back spans | **(a)** + **(b)**: the model removes fillers (the prompt describes them); the guard collapses only what was said twice; a put-back span comes back as said |
| Guard `chatty` (`_CHATTY` phrase regexes: 好的 / 以下是 / Sure / here is / hope this helps …) | caught a preface or sign-off | **(b)**, made mechanical: a run of ≥ 3 units at either end that follows nothing said (unit pairs never said in sequence) |
| Guard `answered` (`_QUESTION_ZH` / `_QUESTION_EN`: wh-words, auxiliaries, 吗 / 呢 / 为什么 …) | caught an answer to a dictated question | **(c)**: answers are `novel` / `chatty` (words nobody said); a short answer reusing the question's words can pass (the prompt forbids answering) |
| Boundary stop words (`plausiblyFinal`: 的时候 / 以后 / 是 / 也 / 在 …, the / and / is / that …; `openStarts` 但是呢 / and so) | decided "sentence complete?" after a long pause | **(a)**: after a long pause the carried clause goes into the next window with its mark, and the model decides; polish off / a fall-back keep the speech model's mark (`seam`, `mark`) |
| Ordinary English words (`DictationStitch.ordinary`, `decapitalize`; DictationFit's capital rule) | lowered the capital a cut (or the cursor) gave | **(a)** with polish (windows span the seam; the prompt says to drop a capital a pause caused; `keepCase` restores the input's own case, mechanically); **(c)** without polish and at the cursor (the case stays as written) |
| `binds` / `bindingZH` (把 / 的 / to / the …) | no comma at a refused window's seam after such a word | **(c)**: a comma where the speech model heard a boundary (a rare 「把，」 in a refused window) |
| List renderer (`DictationList.swift`, `dictation_styles.py`: ordinal tables 第一 / 首先 / 一是 / first / number one …, never-markers 以及 / 其他 / 然后 / also, 第一次 exceptions; `tests/fixtures/dictation_lists.jsonl`) | made Structured's lists | **(a)**: the structuring pass (§Styles); "reformat last" and the island's chip use it too; the chip's trigger (≥ 2 markers) is the pass finding a list |
| Chat particles (`CHAT_PARTICLES` 吧 / 呢 / 啊 … put back by the repair; `DictationStyleVariant.chatParticles`) | kept a chat message's tone | **(a)**: the request says it is a chat message whose tone words and sentence-final particles stay |
| Repair `_STARTERS` (It / The / This …) | lowered a sentence start after a span put back at the front | **(b)**, mechanical: lowered only when the transcript had that word in lower case |
| Code-switch: `translated_glue`'s English function words (a / the / of / is …) and `common_word` | re-decoded an English answer "made of names and function words" | **(c)** for the word list (1 piece of 218 in the names eval); **(b)** kept: an English-tagged answer with Chinese characters in it (the script) is decoded again under the user's language; the language tag by probability threshold (`choose_tag`) stays |
| `context_dump` separators (和 / 与 / 及 among the punctuation) | spotted the speech model writing its word list out | **(b)**, mechanical: listed names in the list's order with only punctuation / spaces between |
| Near-miss name correction (`snap`: edit distance against the vocabulary, guarded by `/usr/share/dict/words` + `_MODERN_WORDS` + inflection rules) | Typless → Typeless, Asopic → Anthropic | **(a)**: polish gets the words and writes a misspelt name the listed way (in the names eval `snap` fired 0 times) |
| Respelling a term (`dictation_vocab.apply`: "github" → "GitHub", guarded by `_MODERN_WORDS`; later only a term written in pieces, "ba 12" → "BA-12", "claude code" → "Claude Code", guarded by `/usr/share/dict/words`) | spelled a term in the transcript, also with polish off | **(a)** (v0.9 review): polish's call, it sees the sentence. The join rewrote paths and package names dictated into a terminal ("npm install @anthropic-ai/claude-code" → "…/Claude Code", "cd ~/src/claude-code") and needed a word list to tell "type less" from a name; nothing rewrites the transcript now |
| Sounds-likes (`dictation_vocab.apply`: the seed's "codec → Codex", "type less → Typeless", "cloud code → Claude Code", and every learned one) | rewrote what was heard into the term, also with polish off | **(a)** (v0.9, audit dict024 / arch088: "a better video codec" became "…video Codex", "you can type less" "you can Typeless"): a sounds-like only ranks the word as relevant, so the speech model and polish are told about it; nothing is substituted. The seed ships none |
| English label ("Dictation (English: keep it in English)") | stops Gemma translating an English dictation | **(b)**: chosen by script (no CJK, some Latin), a note to the model |
| `clean_output` label regex (Output: / Dictation: …), think blocks, code fences, quotes | the model's output format | **(b)**: format, not the speaker's words (the Chinese labels 输出 / 结果 / 润色后 … are gone) |
| Numbers (`cn_number`, `same_number`, `_NUMERAL`) | "numbers stay as said" in the repair; Structured's `number` check | **(b)**: a notation compared by value |
| CJK–Latin spacing, no space between two CJK characters, overlap trim at the cursor (`DictationFit`), echo strip (`strip_echo`), hard-cut overlap (`dropOverlap`), commit split at marks, `keepCase`, list-line counting | layout and alignment | **(b)** |
| Learning from the user's fixes (`DictationLearn.fixes`, `dictation_vocab.fixes`: function-word list, pinyin / consonant similarity) | which edits become vocabulary | kept for now: not on the typed text's path (it only suggests words, the user confirms); a candidate for the same treatment |
| Eval-only lists (`polish.py score`'s `_EVAL_FILLERS`, the lab scorer's) | measuring | kept: measurement, not the pipeline |

Tests that hold the line: `tests/test_polish.py::Guard::test_no_language_rules_in_the_guard` (none of the old lists in
polish.py; `dictation_corrections.py` gone), `tests/test_dictation_stitch.py::test_no_word_lists_left`,
`tests/test_dictation_styles.py::test_no_list_renderer_left`, `tests/test_dictation_vocab.py::FalseCorrections`.

## Custom words

`$BLURT_HOME/dictation/vocabulary.json`, owned by the app (`BlurtCore/DictationVocabulary.swift`), read by
`scripts/dictation_vocab.py`:

```json
{"schema": 2, "terms": [{"term": "Claude Code", "sounds_like": ["clod code"], "source": "default",
                         "state": "active", "added": "2026-10-23T13:00:00+08:00", "hits": 3, "seen": 0}]}
```

- The words are **hints to the models, never rules**: the speech model is told them where it can be, polish gets the
  relevant ones as its word list. Nothing replaces one string with another (v0.9; the sounds-like substitution that
  turned "a better video codec" into "…video Codex" is gone, §Rules vs model).
- `source`: `manual` (the user's own), `learned` (from a fix), `project` (the projects' names and keys), `default`
  (built in). `state`: `active` (used), `suggested` (learned once), `rejected` (a suggestion the user ignored: never
  suggested again), `removed` (a seed the user removed: never seeded again). A removed manual word just goes.
- `sounds_like`: what a speech model wrote instead, learned from the user's fixes. Only a hint that the word is
  relevant when it is heard (`ranked` / `relevant` list it first, so the models hear about it); the seed has none.
- The Words tab shows the user's own words (added, learned) as **你的词**, the projects' names and keys under their
  own heading **来自你的项目** with where they come from (v0.9 dogfood: "Atlas Web, AW, BA" under "Your words" left the
  user wondering whether to delete them), and the built-in ones folded; the filter shows from 20 of the first two.
- The seed, once per launch and when the Words tab or Settings → Dictation opens, adds what's missing: each project's
  name and key (`project`; 2–40 characters, at most three words) and, as `default`, a short list of the products this
  app's users dictate about (`DictationVocabulary.builtIn`, 19): Claude Code, Claude, Codex, Cursor, Typeless, MCP,
  GitHub, worktree, tmux, OpenAI, Anthropic, ChatGPT, DeepSeek, Qwen, Gemini, Kimi, Ollama, blurt, 口喷鸡. No people's
  names. The Words tab shows the built-in ones on one folded line; each is removable like any word.
- **Schema 1 → 2** (`DictationVocabulary.migrate`, once, in `seed`): the longer v0.8 seed (people's names among it:
  Sam Altman, Dario, Musk; and Grok, xAI, Llama, Midjourney, Sora …) goes where the user never touched it (still
  `default`, never used, no sounds-like of the user's own); Claude Code, Codex, blurt and 口喷鸡 (`project` then)
  become `default`; the sounds-likes the old seed shipped ("cloud code", "codec", "type less" …) are dropped, the
  learned ones stay. A retired seed or a too-long project name the user did touch (used, or taught a sounds-like by a
  correction) stays as the user's own word (`learned`, active), with its hints and hits.
- Every dictation request carries the active words. What happens to them:
  1. **ASR biasing** where the model takes it: Qwen3-ASR (MLX) gets an English sentence as its `context` ("Notes
     about Claude Code, Codex, … and Whisper."), Whisper a comma list as `initial_prompt`, Qwen3-ASR (onnx)
     `"; "`-joined hotwords on each stream (an ASCII comma is split and re-joined with spaces by sherpa-onnx, which
     ran the words together). SenseVoice can't be biased: sherpa-onnx only does greedy CTC for it, and
     `create_stream(hotwords=…)` aborts the process ("only transducer models support contextual biasing").
     At most 40 words (64 for Qwen3-ASR MLX, `QWEN_MAX_TERMS`: ~2 tokens a word, prefilled with the audio), the
     relevant ones first: a sounds-like heard, a word spelled like one, a word in the context — for the speech model
     that is the request's `hint` (the target window's title and 300 characters each side of the cursor,
     `DictationContext.hint`; only used to order the list, never sent to the model) and the dictation so far —, then
     manual before learned before seeded, then by hits.
  2. **Nothing rewrites the transcript.** What the speech model wrote is what polish gets, and what is typed when
     polish is off (Verbatim): no sounds-like substitution, no spelling pass. Whether "claude-code" is a path, "cloud
     code" a product or "github" the name takes the sentence (v0.9 review: the spelling pass turned
     "npm install @anthropic-ai/claude-code" into "…/Claude Code"). The near-miss pass (`snap`, edit distance plus
     word lists) went before it, §Rules vs model.
  3. **Polish** gets `Words: …` and `Near the cursor: ▮ …` (the text after the cursor) lines before `Dictation: …` in
     the last message, and the text before the cursor as the turn before it (since v1.0.2, §Real takes; the
     cached prefix is unchanged). The prompt says to write a word that sounds or looks like a listed one the listed
     way, never to add one that wasn't spoken, and never to copy the context. Two examples show it. The guard accepts
     units from the words and the context as not new, accepts a lost Latin word replaced by a similar listed one,
     and adds `term`: a word that was spoken must survive (the eval caught Gemma dropping "口喷鸡在" otherwise).
- `terms_applied` in the history: the words polish wrote, plus listed words in the text when the speech model was
  told about them.

## Names inside Chinese speech (code-switching)

What the user saw in WeChat (no readable field: the context was the window title only). They said, in Chinese, that
they were trying names such as OpenAI 和 Musk 的 Grok and 和 CEO 是 Dario 的 Anthropic. The speech model wrote
"…open AI and Musk's Grok, and呃，CEO是Dario的Asopic…" — 和 became "and", Musk 的 became "Musk's" —, polish was
rightly refused (`translated`: English where Chinese was spoken), the raw text was pasted, `terms_applied` was empty,
and the user's own fix of "Anthropic" in WeChat was never learned.

### Root cause: the language tag, not (only) the English context

Qwen3-ASR answers `language X<asr_text>…`: it first decodes a language tag, then writes the **whole** answer in that
language. A Chinese sentence dense with English names gets tagged English, and then the Chinese around the names is
**translated**: measured on spliced clips (the names in an English voice, the rest Chinese), forcing the tag shows it
both ways — tag English: 「Cursor 和 Codex 我都在用」 → "Cursor and Codex, I'm using Codex, the speed is faster.";
tag Chinese on English speech: "DeepSeek and Kimi both shipped new models" → 「DeepSeek 和 Kimi 都已发布新模型。」.
The English "Notes about …" context makes it worse but isn't the cause: with the longer list of English names, 11 → 16
of the 39 mixed pieces (spliced, clean) came back tagged English with Chinese still in them, and with no context at
all the model translated too. None of the context formats tried fixed the tag — a Chinese-framed note
「说话中可能提到这些名字：A、B…」, the notes plus a Chinese instruction to keep English names as they are, a bare comma
or space list —; the Chinese framing tagged even more pieces English and once copied the list out
(`results/explore2-sp.jsonl`, `explore3-pz.jsonl`), so the "Notes about …" sentence stays. The model's own probabilities at the tag separate the cases cleanly:
English speech ≥ 0.9985 English (of English + Chinese); the mixed pieces it translated 0.95–1.0.

**The fix** (`Qwen3Mlx._decode_tagged`, `dictation_vocab.choose_tag` / `translated_glue`): mlx-qwen3-asr's own decode
(the same prefill, KV cache and greedy loop), with the tag chosen here. The prompt is prefilled up to `language`, the
probabilities of " English" and of the user's language are read, and the tag is
- the user's language (Chinese for a user whose languages — `asr.languages`, else the system's — include zh; also when
  the dictation so far is ≥ 30 % Chinese) unless English has > 99.5 % of the two (`EN_TAG_THRESHOLD`);
- the model's own when it picks neither (None: noise; another language) — as before;
- an English answer with Chinese characters still in it is decoded once more under the user's language and that is
  kept when it has Chinese in it (~one more decode, only then). The script decides; the v0.8 check for "nothing but
  names and English function words" ("Anthropic, the CEO, Dario." — a list of function words) is gone (§Rules vs
  model; it caught 1 piece of 218 in the names eval).
- English-only users, or a language set in Settings (`asr.language`), keep the plain decode. If the library changes
  under it, the first failure switches back to the library's `transcribe` for good (`TaggedDecode` tests).
- **The tag is read without the Words** (v0.9 dogfood). With the Words on — the default, seeded with the project
  names — the app typed 「这个 feature 下周上线」 as "This feature will be launched next week." 3 times in 3: the
  Words' English sentence put the tag at p_en 0.9956 (0.948 without them), 0.0006 over the line, and a clean
  translation has no Chinese left for the redo to catch. Which side of the line it fell on also depended on the
  words' order (sorted by hits, so it changed after every take: 0.9958 in the app's order, 0.9886 in the file's).
  Now the tag comes from its own prefill of the prompt with only the text so far (`tag_context`: what
  `EN_TAG_THRESHOLD` was measured with), and the text is decoded with the full context — the Words still bias the
  spelling — under that tag. In-app takes (34: 20 mixed, 11 English, 3 Chinese): CER over the mixed ones 10.6 % →
  2.9 %; only the translated one changed. The request is also deterministic: `dictation_vocab.ranked` picks the terms
  by relevance, source and use, and orders them by name; the app sends the file's source and hits with each word,
  so the app and the Dictation Lab send the same words in the same order (`StableOrder` tests).
- What decided is kept: the server's `tag` (`p_en` / `p_<lang>` without the Words, `p_en_words` with them, `margin` =
  logit(English share) − logit(threshold): log-odds, so a clear English piece (0.9999) is +3.9 rather than the 0.005 a
  linear difference allows on that side of a 0.995 line, `redone`) goes into the history entry (`asr_tags`, one per
  piece) and the Lab's runs; the Lab flags a tag within 1.0 of the line (a share of about 0.987–0.998) as a close call (`fragile_tag`, the CLI's "fragile language tag", the
  stage view's line). The app-captured wav is a regression test
  (`tests/test_dictation_codeswitch_model.py`, with the model: `BLURT_TEST_QWEN_MODEL=…`), the decode path a model-free
  one (`tests/test_transcribe_language_tag.py`), and the built-in reading script has the sentence (b031).
- Cost: one more prefill of the prompt when the Words are in it (tens of ms; none without them — the one prefill
  does both). The probe is the tag step the model would run anyway.

Found on the way: on a noisy piece it couldn't make out, the model answered with the word list itself
("Claude Code、Codex、blurt、口喷鸡…" — the old pipeline would have pasted that). `dictation_vocab.context_dump` (≥ 4
listed names in the list's order with only separators between them) → the piece is decoded again with only the text
so far as context.

### The vocabulary for each piece, and the near-miss pass

- Every streamed piece does get the words (`DictationStream.transcribe` → `vocab` + `prior`); `terms_applied` was
  empty because none of the names was in the vocabulary. The `default` seed now has the AI names (§Custom words), and
  the ASR request carries a `hint` (title + text around the cursor) so words seen there are listed first. Qwen3-ASR
  gets up to 64 words (`QWEN_MAX_TERMS`).
- (v0.8 had `snap`, a near-miss pass — edit distance against the vocabulary, guarded by English word lists — in
  the ASR server. Removed in the model-first work, §Rules vs model: it fired 0 times in the names eval, and polish,
  given the words, writes a misspelt name the listed way.)
- **False corrections: 0** on `tests/fixtures/dictation_false_corrections.jsonl` — 40 sentences (Chinese and English)
  that use cloud, open, cursor, code, gemini (the sign), grok (the verb), musk (the scent), llama, mistral (the wind),
  copilot, windsurf, perplexity, codex (the book), apple, meta …, through the deterministic pass with the whole seeded
  vocabulary.
- The user's WeChat fix: §Learning from corrections (the page's **Correct**, and `dictation_vocab.learn` for the lab).

### Polish

- The `translated` guard was right and stays. With the tag fixed there is nothing to repair at the polish stage.
- Two polish problems the eval surfaced, both from the message format every app dictation uses ("Words: …" /
  "Near the cursor: …" before "Dictation: …"):
  - Gemma 4 E2B **translated English dictations into Chinese** once a word list was there (6 of 12 English clips; 2
    without the list): an English dictation is now labelled "Dictation (English: keep it in English): " → 0 of 12.
  - (v0.8.x, before the model-first work made Light keep self-corrections:) it **left spoken self-corrections in**
    (「把这个，不对，这两个…」 typed as said; 2 of 8 applied with the words and a title, 5 of 8 bare). Now polish lists only the words this dictation may need (`dictation_vocab.relevant`: heard,
    spelled alike, or in the field — the speech model already had them all), a title alone is no "Near the cursor"
    line (the guard still accepts its words), the first words example has a correction in it, and the rules say the
    corrections still apply with a word list → 14 of 16 typed right, old code 8 of 16 (8 cases × with / without words, `results/selfcorr-*.txt`; the one left is
    「先放到左边，不对，放到右边…」, kept whole by the model — typed as said).
  - The 41-case eval with the new prompt: fall-backs 0 / 0, kept 97.6 % / 97.6 %, unwanted words dropped 90.2 → 97.6 %,
    fillers removed 88 → 94 %, similarity 0.958 → 0.971; the over-deletion set: kept 100 % after the repair both
    (the model's own 95.5 % both), repairs 4.5 → 9.1 % of cases (`results/polish-*.json`).
- (v0.8.x had correction-marker lists in the guard and the repair — `cancelled`, the `correction` check, lead-in
  words, a custom word "said only in the taken-back words" — all gone in the model-first work: §Rules vs model,
  §Self-corrections.)

### Eval

`promo/cases/v0.8-dictation-names/` (not in git): 48 synthetic clips (`scripts/gen.py`): 28 Chinese sentences with
67 English names (OpenAI, Anthropic, Claude, Dario, Musk, Grok, Gemini, Codex, Cursor, Typeless, DeepSeek, Kimi, Qwen,
Sam Altman, Hugging Face, Llama, Mistral, Perplexity, Midjourney, Sora, MiniMax, Windsurf, Nvidia …, most of them next
to 和 / 的: the code-switch trap, one a paraphrase of the WeChat sentence), 4 Chinese-only, 4 Chinese with a whole
English sentence, 12 English. Six zh_CN `say` voices (they read the names with a Chinese accent, often unrecognisably:
"clean"), the same with pink noise at 10–16 dB SNR + hum + a reflection ("noisy"), and **spliced**: the Latin runs in
an English voice, the rest in the Chinese one — closer to how a Chinese speaker says the names, and the set that
reproduces the WeChat failure. 1–3 pause-cut pieces each, fed piece by piece like the stream (`prior` = the text so
far, `hint` = 「微信」 only), through `transcribe.py`'s `NoteEngine.note` (the warm server's code: ranking, biasing,
the tag, the passes) with Qwen3-ASR 1.7B 8-bit, then `polish.py` (Gemma 4 E2B) with the seeded words and the title.
Old = the scripts and seed of `86ea0e67`. Code-switch errors = English function words in the output that weren't
spoken (and, of, 's, the, is …). M5 Max, in-process, warm.

| Set (clips) | Terms old → new | Code-switch errors old → new (clips) | CER old → new | Polish fall-backs old → new |
|---|---:|---:|---:|---:|
| Spliced, clean (28) | 52 → **62** / 67 | 6 (3) → **0** | 14.2 → **6.1 %** | 1 → 0 |
| Spliced, noisy (28) | 28 → **49** / 67 | 3 (2) → **0** | 43.0 → **16.6 %** | 2 → 0 |
| zh voices, clean (28) | 31 → 34 / 67 | 8 (2) → **0** | 39.4 → 28.5 % | 1 → 1 |
| zh voices, noisy (28) | 19 → 24 / 67 | 0 → 0 | 44.6 → 39.8 % | 1 → 0 |
| Chinese only, clean / noisy (4) | — | 0 → 0 | 1.1 → 1.1 % / 9.0 → 11.2 % | 0 → 0 |
| Chinese + an English sentence (4 ×2) | 2 → 2 / 2 | 0 → 0 | 3.5 → 3.5 % / 31.5 → 18.9 % | 3 → 4 (`translated`) |
| English, clean (12) | 24 → **26** / 26 | — | 1.6 → **0.4 %** | 5 → **1** |
| English, noisy (12) | 18 → 21 / 26 | — | 26.4 → 20.2 % | 3 → **0** |

(raw ASR columns; after polish the terms are 63 / 52 on the spliced sets.) `results/pipeline-before.jsonl`,
`pipeline-after3.jsonl`, `scripts/summarize.py`.

Latency, old and new run interleaved (old, new, old, new; clean + spliced sets, 218 pieces a round), paired per piece:

| | Old: median / p90 | New: median / p90 | Paired difference (median) |
|---|---:|---:|---:|
| ASR, every piece (VAD + decode + passes) | 169 / 202 ms | 156 / 203 ms | −13 ms |
| ASR, the last piece (what is left after key-up) | 179 / 207 ms | 164 / 211 ms | −13 ms |
| Polish (whole transcript) | 115 / 157 ms | 121 / 163 ms | +3 ms |

The tag costs nothing (it is the model's own first step) and 64 instead of 15 words in the context are a few more
prefill tokens; the new decode came out 13 ms faster (not taken apart: the loop skips the library's per-step cache
evaluation, and translated answers were longer). Within the +30 ms budget either way.
`results/pipeline-*-lat{1,2}.jsonl`, `scripts/latency.py`.

- The zh-voice sets stay hard: those voices say "OpenAI 和 Anthropic" as 「郭困难和阿臭皮」, which no biasing reaches.
- What's left on the spliced set: Wispr Flow → "Whisper Flow" (real words: the passes leave it; learning takes it),
  xAI → "Z", Elon Musk → 「埃隆·马斯克」 (a translation the model keeps for a famous name).
- The Chinese-with-an-English-sentence clips: the English sentence stays English (a Chinese tag doesn't translate it:
  the probability says English there); polish still refuses some as `translated` (Gemma rewrites the English half).

### What auv taught (moeru-ai/auv)

The user pointed at [moeru-ai/auv](https://github.com/moeru-ai/auv) (Apache-2.0). It turned out to be OS automation
("Playwright for the OS": accessibility trees, screenshots, OCR), with no speech recognition, VAD or voice input in
it. Two ideas only, no code: its OCR (Apple Vision) gets a `customWords` list drawn from what it is looking for, and it
compares on-screen text after folding look-alike characters, case and punctuation. Taken: the words on screen — the
window title and the field's text — rank the custom words for the speech model and let the near-miss pass accept a
weaker match (`hint`); spelling-insensitive keys were already how the passes compare. Not taken: OCR of the window
for apps whose field can't be read (WeChat) — it needs Screen Recording for every dictation; a possible follow-up.

## Context

At the start of a dictation (read while the user talks, off the main thread; `DictationContext`): the focused
element's value around the cursor (500 characters each side, the selection), the focused window's title and the
app's name. Accessibility, read-only, 0.25 s timeouts. Skipped entirely for `AXSecureTextField` (role or subrole),
while secure event input is on, for Blurt's own windows (test builds read only the test pad), and when
`record.dictation.context` is off. Polish gets 300 characters each side; the guard accepts their words. The history
stores only `context_used`; the text itself only with `keep_audio` (on unless turned off).
- Apps whose focused element Accessibility can't read (WeChat's input box, some Electron apps): the front app's name
  and its focused window's title only (`DictationContext.titleOnly`: often the chat's or the document's name).
- (v1.0.4) Electron apps (Claude, VS Code, Slack…: `Contents/Frameworks/Electron Framework.framework`) build their
  Accessibility tree only when asked: at key-down Blurt sets `AXManualAccessibility` on the app once per pid
  (`DictationField.wakeWebAccessibility`, `dictation_web_ax`), and when the field still can't be read reads again after
  0.3 s. Without it the text around the cursor was empty, so a take after "。" started with "。" again and text already
  in the box was typed a second time.
- A streamed dictation's pieces get the polished text so far appended to "before the cursor".

## Auto-learn

After a paste, `DictationWatch` follows the same AX element (the one focused just before pasting) for 60 s, every
1.5 s:
- It finds the typed text again between 40-character anchors taken around it, nearest to where it went in. Only the
  anchors are held, in memory, and dropped when the watch ends.
- It stops when the focus moves to another element, the anchors vanish, the time is up or the next dictation goes in,
  and learns once, then, from what was typed to the last version it saw (`DictationLearn.EditWatch`). Nothing is
  learned mid-edit: a pause while typing used to be taken as the user's word (Kubernetes → Kuberneetes → K8s taught
  "Kuberneetes", and K8s was never learned).
- `DictationLearn.fixes` diffs typed against edited text (LCS over words, numbers and single CJK characters) and keeps
  replaced spans of ≤ 3 words / 4 characters (≤ 4 / 6 after the fix), at most 3, when at least half of the text
  survived. A pair counts when it's alike: same letters ignoring case / spaces / hyphens, normalised edit distance
  ≤ 50 %, cut short (op → option), the same consonant skeleton (cloud → Claude), or close in toneless pinyin
  (口喷机 → 口喷鸡, 克劳德 → Claude). One changed CJK character is learned with the unchanged ones before it. A fix
  to one ordinary word is learned as a phrase with its unchanged neighbour (pool request → pull request); fixes on
  function words (there → their) are grammar, not vocabulary — and so is a fix to any lower-case word the system's
  spelling dictionary knows (`DictationLearn.spelledRight`: NSSpellChecker; the word list has no contractions, so a
  fix to "you're" was offered as a word to learn, v0.9 dogfood). A replaced run is cut where the edited text has
  punctuation or changes script, and the typed tokens are shared out so each part pairs with what sounds like it
  (绘画 BA 三 → 会话，BA-3 is 绘画 → 会话, and BA 三 → BA-3 on its own); a term never has sentence punctuation in it
  (`DictationVocabulary.hasSentencePunctuation`, also refused by `learn`).
- `DictationVocabulary.learn` learns words, never replacements: a known word gains the sounds-like (a relevance hint,
  §Custom words); a new one is a suggestion, accepted the second time
  the same fix is seen, or at once when it is only case or spacing. The first time a word becomes active, the
  island says *Learned "pull request"* with **Undo** (记住了 pull request · 撤销). Never from secure fields; nothing of
  the surrounding text is kept; `record.dictation.learn` turns it off.

### Learning from corrections

The watch needs the field's text. In WeChat (and other apps whose input box Accessibility can't read) it sees
nothing, so a name the user fixed there by hand — 「…的 Asopic」 → 「…的 Anthropic」 — was never learned. Two other
ways in, both with the watch's rules (`DictationLearn.fixes`: small replaced spans that sound or look alike; a
rewrite teaches nothing):

- **The Dictation page**: the typed text has **Correct** (改正); it opens an editor with **Save Correction** (保存改正,
  ⌘↩) and Cancel. Saving appends `{"op":"correct","id","text"}` to the history (the entry keeps `text` and gains
  `corrected`; the page, copy, search and *Turn into item* use the correction) and offers every fix in it —
  `DictationVocabulary.learnCorrection` → `learn(…, explicit: false)`: a new word is a suggestion (v0.9: a fix of two
  words side by side had become one active junk term), a known one gains what was heard as a sounds-like, a rejected
  or removed one stays out. The note says 「已保存改正 · 发现 Anthropic」 with **加入词库** / "Add to Words" (then
  「已把 Anthropic 加入词库 · 撤销」); `⌘Z` puts the text back (`{"op":"correct","text":null}`) and forgets the words the
  correction suggested. The editor has the caret on open; `E` / `Return` on the list starts it, `Esc` cancels,
  `⌘Return` saves. Test hooks: `dictation history edit [ID]`, `dictation history correct ID TEXT`, `dictation history
  note add|undo` (event `dictation_history` action `correct` with the fixes and their results).
- **For tools outside the app** (the Dictation Lab): `scripts/dictation_vocab.py`, the same rules ported to Python
  (pinyin through macOS's own `CFStringTransform` via ctypes, as the app; `pypinyin` elsewhere when installed):
  - `learn(raw, corrected, explicit=True, path=None, dry_run=False)` → `{"ok", "fixes": [{"heard", "fixed",
    "kind": case|spelling|sound, "result": learned|suggested|known|null}], "path", "written"}`; writes
    `$BLURT_HOME/dictation/vocabulary.json` (read, change, atomic replace). `explicit=False` makes a suggestion, as
    the watch does. `fixes(raw, corrected)` only finds them.
  - CLI: `dictation_vocab.py learn --raw TEXT --corrected TEXT [--suggest] [--dry-run] [--file PATH]`,
    `dictation_vocab.py fixes --raw … --corrected …`.
  - The app holds no lock another process can see: a tool writing while the app seeds or counts hits can lose one of
    the two writes. Call it while the user isn't dictating (a lab session).

## Recognition model

`record.dictation.asr_model` (unset = automatic: the recommended model when installed; else the best Qwen3-ASR MLX
already on this Mac that fits next to the polish model — it takes the Words list — e.g. a 1.7B brought from a bigger
Mac, or the 0.6B on a pro Mac until the 1.7B is in; else the voice-note model — which, with nothing downloaded on
macOS 26, is macOS's own recogniser, `apple-speech`, run in the app's process: first-minute-speech.md). Memory is judged for the pair a
dictation holds warm, recogniser + polish model (`transcribe.py fits_with_polish`: within the 40 % share of RAM one
model may take; on a 16 GB Mac 0.6B 2.1 GB + Gemma 4 E2B 3.9 GB fits, 1.7B 3.1 GB + 3.9 GB doesn't; with polish off or
a smaller polish model it does). The rows' `fits` say the same.
`transcribe.py dictation-models` lists them for **Settings → Speech → Dictation** (`Settings/DictationModels.swift`,
the one place dictation's speech and polish models are chosen: the recommended pair with its total size and one
*Download (5.7 GB)* for what's missing; per model one verb — *Download* when it isn't on this Mac, *Use* when it is,
the one in use marked; sizes from the catalogues' `size_mb`, whole MB below 1 GB, one decimal above; the selected,
recommended and downloaded models shown, the rest under *Other models (n)*). Settings → Dictation shows both models
in one row: their names with *Change in Speech…* (a `brand.ink` text button that opens it there), or *Not on this Mac
yet · 2.4 GB* with one *Download* for everything missing (`DictationModels.missingJobs`) — while the download manager has it,
*Downloading · 1.2 GB of 2.5 GB* or *Waiting to download · 3.4 GB* with *Show*, never *Download…* beside a running
download. A radio is filled only for a model on this Mac (none while none is in; the recommended one says *Used once
it's downloaded*). Names come from the shipped catalogues (BlurtCore `ModelCatalog`) while the list loads or can't be
read — never an id. Nothing is downloaded until **Download**.

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

The whole dictation (v0.8, measured with the sounds-like pass, gone since v0.9): those outputs → the sounds-like pass → Gemma 4 E2B polish with the 21 words (the seed's
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
  the words still help through polish: 50 → 64 % with v0.8's sounds-like pass); Qwen3-ASR onnx for Macs without MLX is
  too slow for dictation here (0.64 s before polish).

What the misses look like without biasing: Claude → cloud / cloth, blurt → Blur / blt, option → op (in Chinese
speech), 口喷鸡 → 口喷机 / 鲲机, tmux → mux / Tmox, worktree → work tree, Codex → Codec / Kodex, Qwen → Qu / 坤,
Gemma → jamer, pytest → pi dust, BA-12 → "B A twelve", GitHub → jitop. With biasing what remains: 口喷鸡 → 口喷机,
Qwen inside Chinese speech, "Sense Voice" as two words (v0.8's sounds-like and spelling passes fixed these; since v0.9
polish does, seeing the sentence).

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

### Real takes (v1.0.2)

The user's own history (367 takes, 20–28 Oct, Qwen3-ASR 1.7B + Gemma 4 E2B, streamed) fell back to the raw transcript
in **12.8 %** of takes (`grew` 23, `dropped` 7, `term` 4, …), against 2 % on the eval set. Replayed whole and without
context, the same transcripts fell back in 1 %: the cause was the context, not the words. With the text typed into the
same app in the 10 minutes before as the text before the cursor (what a chat box holds), the fall-backs came back:
the model **rewrote or continued the text before the cursor** instead of the dictation, mostly on short takes
(「空中云会。」 → 「没问题。」, the previous message). And the takes that weren't polished showed what users see
most: 三D, 四十八小时, V 二, F N, C L I, H T M L as the speech model wrote them.

Changes (`polish.py`), each measured with Gemma 4 E2B on the replayed takes (39 that had fallen back + 60 that hadn't,
with their simulated field text), 30 formatting cases taken from those takes with the expected writing, 64 real-speech
homophone errors + 60 exact transcripts (AISHELL / ContextASR / FLEURS, Qwen3-ASR 1.7B), and the eval and
over-deletion sets, before = the committed code in the same conditions:

| | before | after |
|---|---:|---:|
| fell back, real takes that had (39) / hadn't (60) | 8 / 3 | **0 / 0** |
| formatting cases right (30) | 7 | **19** |
| eval set: fall-back / kept / fillers removed | 2.2 % / 95.7 % / 71 % | 2.2 % / 95.7 % / 71 % |
| over-deletion: kept (final) | 100 % | 95.5 % (od-01: 「要快」 → 「快」) |
| homophone spans fixed (81) | 0 | 0 |

- **The text before the cursor is the turn before** (`messages`), as a streamed dictation's text so far already was;
  `Near the cursor` keeps only the text after the cursor. And when the guard still says the model followed the
  context (`CONTEXT_FAULTS`: grew, copied, empty, chatty), Light tries once more without it (`retried` in the answer;
  only then, ~0.1–0.2 s).
- **Numbers in digits, the same value** — the prompt said 「三十 stays 三十」; now digits where a writer would use
  them, changing only the number (五百块 → 500 块, not 500 元: the first wording changed the words around it). The
  repair still puts a number back whenever its value changed (`same_number` accepts 1.2 万 for 一点二万). The eval's
  must-keep terms count a number written in digits (`in_digits`).
- **Letters spelled out are the word** for the guard (`units`: 「C L I」 = 「CLI」): writing the word was `dropped`.
- **Homophones are not polish's job:** told plainly to fix misheard same-sounding words, E2B fixed none of 81 real
  ones (买点 / 埋点, 绘画 / 会话 among them) and changed nothing else. **Nor is rescoring the speech model's own
  alternatives worth it** (prototype, `scratchpad/rescore/`, 929 real utterances per model): the right word is the
  runner-up in 57 % (1.7B) / 73 % (0.6B) of same-sound errors, but at ~7–16 % of the wrong word's probability; branching
  where the runner-up is ≥ 10 % and choosing by speech score + 0.3 × text score (the speech model's own decoder without
  audio judged best — Gemma 4 E2B and Qwen3.5 0.8B preferred wrong versions of correct sentences far more often) cut
  CER 4.07 → 4.02 (1.7B) / 5.27 → 5.20 (0.6B) with no correct sentence broken, fixed 0 of 66 / 3 of 103 same-sound
  spans, and missed both reported phrases (会话 at 2 % of 绘画). Not shipped. **The lever is context:** with the app
  name or the text before the cursor in the scorer's prompt, the margin for 会话 over 绘画 went +5.9 → +10.9 and
  for 埋点 over 买点 +4.9 → +11.8. The speech model gets the app name already (`note(app=…)`); whether the field's
  text as its context helps is measured on the user's kept takes (`keep_audio` keeps the context too), §Lab Review.
- Not fixed: two-letter keys (F N) stay apart; 三 D with a space, sometimes.

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
| standard | 16–24 GB | 4 GB | Gemma 4 E2B (2.2 GB peak since v1.0.2, §Memory; 3.5 GB before) |
| light | 8 GB | 2 GB | Gemma 3 1B since v1.0.2 (1.3 GB, 17 % fall-back in the v1.0.2 sweep); Qwen3 1.7B before (2.1 GB, 24 %) |
| minimal | < 8 GB | — | Gemma 3 1B (rarely harmful, rarely useful) |

**Memory together (arch098, v0.9).** What a 16 GB Mac holds while it dictates is the sum: dictation's speech model,
polish, and the voice-note model (one `asr-serve` holds one speech model at a time). Pro Macs (≥ 32 GB) keep
Qwen3-ASR 1.7B 8-bit + Gemma 4 E2B. On standard Macs dictation already gets the 0.6B Qwen3-ASR (2.1 GB, not 3.1), and
voice notes and live captions now prefer the 4-bit Whisper turbo (2.6 GB and a 442 MB download, not 3.7 GB / 1.5 GB;
3.3 % zh error vs 1.6 %), the full one only when it is what is installed; recordings keep the full one (accuracy
first, a one-off process). Polish stays Gemma 4 E2B: nothing lighter was good enough above (Qwen3.5 2B falls back
20 % of the time, Qwen3 1.7B 24 %). The bigger saving is time: every warm server now ends after 10 idle minutes and
with Blurt (§Polish), where the model used to stay up to 30 minutes and the process up to 4 hours. Only automatic
choices change: a model the user picked (`asr.models`, `record.dictation.asr_model`, `polish_model`) stays.

### Memory (v1.0.2)

**Field report.** A colleague's 24 GB Mac had 10.6 GB compressed and 17 GB of swap. Blurt's two warm servers held about 5.6 GB, and the notch stuttered. Measured on an M5 Max, footprint of the warm server, Gemma 4 E2B, 68 eval and over-delete cases, output compared byte for byte:

| | Polish server | Cost |
|---|---:|---|
| v1.0.1 | 4.6 GB after load, 3.1 GB after the first request | — |
| MLX cache of freed buffers capped at 64 MB (`MLX_CACHE_BYTES`; it was min(limit / 4, 2 GB)) | 3.1 GB from the start | +2.4 ms a request, same output |
| … and Gemma 4's per-layer embedding table read from its file (`CPUEmbedding`, an np.memmap gathered on the CPU) | **2.0 GB** | +40 ms a request, same output |

Why each change helped:

- **The cache cap.** The two prompt prefills freed about 1.5 GB of buffers at warm-up, and MLX kept them in its cache until the first generate.
- **The per-layer embedding table.** It is 1.26 GB of E2B's 2.48 GB of weights. A token reads one row of it, and in Metal memory it could only be compressed or swapped. Mapped from the file, its pages are dropped for free under pressure.
- **The wired limit.** mlx-lm raises it for each generate and puts it back afterwards. Changing it made no difference.

**Smaller models.** A sweep under the same conditions found nothing that holds up as well as E2B:

| Model | Fallback, eval | Fallback, 18 zh / zh-en cases | Footprint |
|---|---:|---:|---:|
| Gemma 4 E2B | 2.2 % | 0 | 3.1 GB |
| Gemma 3 1B QAT | 17 % | 6 | 1.3 GB |
| Qwen3.5 2B | 17 % | 2 | 1.6 GB |
| Hunyuan 1.8B | 37 % | 12 | 1.5 GB |
| MiniCPM5 1B | 35 % | 9 | 1.0 GB |
| LFM2.5 1.2B | 61 % | 16 | 1.0 GB |

**Speech server.** mlx-qwen3-asr kept up to 4 loaded models in its own LRU. A server that switched between dictation's model and a voice note's held both. A backend now keeps one, and a switch frees the old model first.

**One speech model.** For Chinese and English speakers on Apple Silicon with 16 GB or more, dictation, voice notes, live captions and recordings now share one Qwen3-ASR: the 1.7B from 32 GB, the 0.6B below (asr-benchmark.md §Real speech). One warm copy replaces a Qwen, a SenseVoice and a Whisper, and voice notes now get the user's words too. Settings → Speech shows them as one Speech recognition row, and every row's pop-up starts with Automatic. The library's Use gives a model every job.

**Memory pressure.** On a warning or critical event (`DispatchSource.makeMemoryPressureSource`), the app asks each idle warm server to exit (App/MemoryPressure.swift). A take in progress keeps its servers. The launch prewarm skips for 10 minutes after such an event.

Nothing is downloaded until the user presses **Download** in Settings → Speech → Dictation. The size is shown, and the download
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
- since the styles: `style`, `style_source` (shift | island | chord | app | category | default) and `style_router`
  (`category`, `base` — the app / category / default style —, `explicit`, `toggles`, `list_likely`, `rendered` (a list
  was typed), `variant`; `markers` only on entries from before the model-first styles), `reformats` (§Styles; since
  the model-first styles also `suggest`: the island offered a list), `structure_ms` in the timings;
- edit lines: `{"op":"delete","ids"}`, `{"op":"item","id","item","uid"}`, `{"op":"clear"}`, `{"op":"correct","id",
  "text"}` (the user's correction from the Dictation page: `corrected` on the entry; prune folds it into the line),
  `{"op":"style","id","action","from","to","replaced"}` (reformat-last, its undo, `revert`: a rendered list taken
  apart in the field, or `suggest`: the list chip shown; folded into `reformats`);
- since v0.9: `asr_tags` (per piece, the speech model's language tag: `tag`, `p_en` / `p_<lang>` without the Words,
  `p_en_words` with them, `margin` to the English line, `redone` — §Code-switching), and `insert` can be `held` (a
  password field had the focus: neither typed nor copied).

**Delete** (⌫, the detail's button) says so on the island with **Undo** (⌘Z does the same); the entries' kept
recordings wait in `audio/.deleted/` for two minutes and Undo puts them back, so Retry and Add to Lab still work on
the restored row (v0.9 dogfood: the audio went at once). Launch's retention and Clear History empty that folder.

**The page** says the one step in the way of a first dictation (`DictationPageStatus`): off → on, the key's
permission → Turn On, **the speech model** → "还没有语音模型（2.5 GB）" with **下载** and its progress while it comes
down (before: "✓ 听写已开启" with no model), and only then "听写已开启"; the list's header says a missing model in place
of the settings link. Every row keeps the app icon's slot (Blurt's own windows: its icon; an app that can't be found:
the generic app icon), the marks are 13 pt, and a take that fell back says **未润色** in words with the reason on
hover. Models are named from the skill's catalogs before the live list answers (`ModelCatalog`), apps never by a
bundle id (`AppNames`: else "未知 App"), and an old entry's raw context dict says only that it was used.

Retention (`record.dictation.retention_days`, 30) rewrites the file at launch and when the setting changes. Audio
(`dictation/audio/<id>.wav`) is deleted after transcription unless `keep_audio` is on, and with the take whenever its
result is dropped. A take cut short by a quit or a crash, or by a path that once forgot its file (dict025: five wavs
no entry referenced), is caught at launch: retention also removes every wav in `audio/` (pieces included) that no
entry points at and that is over an hour old (`DictationHistory.pruneOrphanAudio`, `dictation.py prune`). The Lab's
recordings live in `dictation/lab/` and are never touched.

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
| `structure_timeout_ms` | `10000`: Structured's one pass over the whole take (the generation only) |
| `load_budget_ms` | `12000`: how long a model coming up (server start + load) may take |
| `streaming` | `true`: transcribe and polish pieces while talking |
| `rehear` | `true`: hear the pieces again in windows while talking (§Hearing again); `rehear_window_s` (10) |
| `cloud_polish` | unset = off. `{"on", "provider": "deepseek"\|"openai"\|"anthropic", "base_url", "model"}` (§Cloud polish; the key is in the Keychain) |
| `cloud_hint` | unset: the daily reminder of cloud polish while it is off; `false` = never again (`cloud_hint_day`: the day it was last shown) |
| `live_partial` | automatic (unset: on from 16 GB, off on the light / minimal tiers) \| `true` \| `false`: the live text also shows the piece still being said (§Live text; needs `record.live_text`) |
| `precapture` | `true`: open the mic on the key-down, before the trigger has decided |
| `builtin_mic` | automatic (unset: on while the default input is Bluetooth) \| `true` \| `false` |
| `sounds` | `true`: the cluck / peck / soft peck when a take starts, stops, is cancelled (`false` = silent) |
| `polish_priority` | `utility` |
| `retention_days` | `30` |
| `keep_audio` | `true` since v1.0.3 (`false` turns it off; also keeps the context in the history, for the Lab and feedback reports: feedback.md) |
| `asr_model` | automatic (Qwen3-ASR 1.7B MLX on pro Macs, 0.6B on standard ones, when installed — a pro Mac falls back to an installed 0.6B —, else the voice-note model) |
| `context` | `true`: read the text around the cursor for polish |
| `learn` | `true`: watch the field after typing and learn the user's fixes |
| `double_tap_send` | `true`: a double tap of the key presses Return (after a dictation: once it is pasted) |
| `lab_keep_next` | unset: the Dictation Lab's "keep the audio of my next dictations" — keep the audio of this many more (§Lab) |
| `lab_mic` | unset (the default input): the Dictation Lab's microphone, by device name |
| `styles` | unset = light everywhere (§Styles). `{"chat"\|"code"\|"mail"\|"notes"\|"other"\|"default": STYLE, "apps": {BUNDLE: STYLE}, "learned": [BUNDLE]}`, STYLE = `verbatim` \| `light` \| `structured` \| `auto`; written as one dictionary (bundle ids have dots) |
| `suggest_lists` | `true`: after a light take that may hold a list (24 CJK characters or 12 Latin words), the structuring pass runs in the background (after the paste); when the model made it a list, the island offers *Make a List* |
| `learn_styles` | `true`: suggest an app's style from the user's switches (asks once; never switches by itself) |
| `style_asked` | the suggestions already asked (`BUNDLE\|STYLE`), whatever the answer |
| `style_hint_shown` | how often ⇧ → Structured was explained on the island (`DictationStyleToggleHint`: twice, then the ear's list mark alone) |

App state (not settings): `app.dictation_tips` (`{"takes", "send", "list", "reformat"}`: the first takes' tips shown,
§Takes in flight), `app.dictation_notices` (the day each once-a-day notice was last said).

## Lab

The Dictation page's second tab (`MainWindow/DictationLab.swift` — the model, `LabTake`, the test hooks —,
`DictationLabViews.swift`; Go → Dictation Lab, `⌥⌘L`, the palette). A testing tool for the user's own dictation: record
a take, see what every stage made of it, mark it up and keep it as a **case**. The cases are a dataset for tuning the
prompt and the strategy, for regression runs, and maybe fine-tuning later. Everything stays on the Mac; the page says
so. Pure parts in BlurtCore `DictationLab.swift` (`LabMetrics`, `LabCase`, `LabStore`, `LabVocab`;
`DictationLabTests`); the runner, export and packs in `scripts/dictation_lab.py` (`tests/test_dictation_lab.py`).

| Piece | What it does |
|---|---|
| **Take** | The real pipeline, nothing typed: `NoteVoice` (the microphone the user picks — `AudioDevices.inputs()`, a `MicEngine.make(device:)` engine that is never the spare — or a file played in real time as the mic: *Import Audio…*) → `DictationStream` (cuts, ASR + polish per piece, the stitch guard; `Result.pieces` carries each piece: times, heard, after custom words, the polish window's input, what it committed, ms) → `DictationFit` against the lab's own *before / after the cursor* fields (also polish's context). Started by the Record button or the dictation key: while the lab is visible and the main window key, `Dictation.handle` hands start / stop / cancel to `DictationLabSink` (the trigger's modes unchanged, no paste, no history entry). Test builds never open the mic: the `dictation wav` hook / `BLURT_TEST_MIC_WAV`, or an imported file. |
| **Stages** | Heard (stitched), polished (or polish off / fell back with the reason), typed (fitted); each piece's line; custom words applied, the guard, what the repair put back, the fit's changes, models, `asr / polish / load / total / fit` ms. |
| **Mark up** | Reference (what the user meant, before or after the take), corrected text (the ground truth; *Start from the output*), error chips, a note, 1–5 stars and good / bad, scenario tags (app, languages, noise, speed). The diff and the metrics follow every keystroke. |
| **Compare** | `dictation_lab.py rerun ID --config …` for a saved case: the installed ASR models (`transcribe.py dictation-models`), polish off / other installed polish models (`polish.py models`), no custom words, no context, the whole take at once. Rows show the diff against the truth, WER, terms, ms. |
| **Learn** | Saving a corrected text calls `dictation_lab.py learn` → `dictation_vocab.learn(raw, corrected)` **when the module has it** (feature-detected: `getattr`), which reports the term-by-term changes to `vocabulary.json`. Without it the app's own learner runs (`DictationLearn.fixes` on heard vs corrected → `DictationVocabulary.learn`). Either way the page lists what was learned with **Undo** (`LabVocab.revert`: each changed term goes back to how it was, only while it still looks as the learning left it). |
| **Run all cases** | `dictation_lab.py run --json [--config SPEC]` in the background; a table of before (the case's last run with the same configuration key) / after, the change, the text when it changed, an overall score and a breakdown by tag. |
| **History** | *Add to Lab* (context menu and the detail): `dictation_lab.py from-history ID` — the audio when it was kept, else a reference-only case (the typed text as its reference). *Keep the audio of my next dictations* (`record.dictation.lab_keep_next`, counts down in `Dictation.deliver`): the audio only, never the text around the cursor. Since v1.0.2 a kept take also keeps its streamed pieces (`pieces`: cuts, pauses, each polish window's input and commit — `DictationPieceRecord`), so a case from it replays the windows as they ran. |
| **Review** | `dictation_lab.py review [--since ISO] [--last N]`: every kept take heard again in one pass (`mode=whole`, polish off: no cuts, no prior) beside what was typed, with flags — `fell_back:<reason>`, `heard_differently` (and where), `seam_marks` (a mark typed where the one-pass transcript has none, in a take with pauses), `spelled_letters`, `numeral_format`. For a reviewer — the user, or an agent (`.claude/skills/blurt-dictation-review`) — who saves the real errors with `from-history ID --corrected … --tags …`: the user's own takes become the regression set. |
| **Export** | `dictation_lab.py export --out FILE.zip`. |
| **Delete** | *Move to Trash* (the case's folder; the CLI's `delete` removes it). |

### Storage: `$BLURT_HOME/dictation/lab/`

- `cases/<id>/audio.wav` (16 kHz mono 16-bit), `case.json`, `runs.jsonl` (every re-run: `{"at", "key", "label",
  "config", "outputs", "metrics"}`). `tmp/` holds a take until it is saved. `packs/` the user's reading scripts.
- `case.json`, schema 1 (unknown keys are kept by both writers):

```json
{"schema": 1, "id": "20261024-142037-85ed", "created": "…", "updated": "…",
 "source": "take|import|script|history", "history_id": null, "audio": "audio.wav", "duration": 11.4,
 "reference": "what the user meant", "corrected": "the ground truth", "errors": ["term", "punctuation"],
 "scenario": {"app": "chat", "languages": "mixed", "noise": "quiet", "speed": "normal"},
 "rating": {"stars": 3, "good": null}, "note": "",
 "app": {"bundle": "com.tencent.xinWeChat"},
 "context": {"included": false},
 "config": {"asr_model": "qwen3-asr-1.7b-mlx", "polish": true, "polish_model": "gemma4-e2b", "vocab": true,
            "context": false, "streaming": true, "language": "auto", "mic": "default", "vocab_terms": ["…"]},
 "take": {"segments": [{"index", "start", "end", "hard", "pause_after", "asr_text", "raw", "asr_ms", "polish_in",
                        "text", "polished", "polish_ms", "fell_back", "reason", "repaired", "load_ms"}],
          "raw": "…", "asr_text": "…", "polished": "…", "text": "…", "fitted": "…", "fit": ["punct"],
          "terms_applied": ["Codex"], "fell_back": false, "reason": null, "repaired": [],
          "timings": {"asr_ms", "polish_ms", "load_ms", "total_ms", "segments", "asr_ms_all", "polish_ms_all", "fit_ms"},
          "language": "zh", "asr_model": "…", "polish_model": "…", "context_used": false, "biased": true},
 "expected_terms": ["Codex", "worktree"], "metrics": {"wer", "cer", "punct", "exact", "ref_units", "hyp_units",
 "terms": {"expected", "hit", "missed", "accuracy"}}, "learned": [{"term", "before", "after"}],
 "prompt": {"pack": "builtin-basics", "id": "b006", "read": "…", "tags": {…}} , "app_version": "0.5.0+…"}
```

- Error tags: `term`, `code_switch`, `punctuation`, `filler`, `dropped`, `made_up`, `segmentation`, `clipped`, `slow`.
- Privacy: the app's bundle id only, never its name or the field's text. The text around the cursor is stored
  (`context.before/after`) only when the user ticks *Keep this text in the case*; `validate` rejects a case that
  carries it without `included`. A history import never takes the history's debug context.

### Metrics (the same in Swift and Python; `tests/fixtures/lab_metrics.jsonl` checks both)

- Tokens: each CJK character (and kana / hangul), each run of letters and digits (`'` inside a word) — the **units**;
  each punctuation mark is a token for the diff, never a unit. Keys are NFKC + lower case, so full-width forms and
  case don't count; 。.!?！？… compare as one "end" class, ，,、;；:： as one "pause" class.
- **WER** = edit distance over units / reference units (a CJK character counts as a word: for Chinese this is the
  CER, for English the WER, for mixed speech the "mixed error rate"). **CER** = over the characters of the units.
  **Punctuation** = marks inside changed chunks / the reference's marks (at most 1). **Terms** = the custom words the
  truth contains (`expected_terms`: the vocabulary's active terms found in it, a word inside a longer one not counted
  twice), hit when their units appear in a row in the output ("T mux" is not tmux, case ignored).
- The diff: a minimal edit script over all tokens (ties: substitution, then deletion, then insertion), consecutive
  changes merged into replace / insert / delete chunks that join back to both texts, spacing included. The page tints
  what was written instead and strikes through what is missing.
- Rounding half up to 4 places (Python's `round` is half-to-even: 5/32 must be 0.1563 in both).
- Not normalised: numbers written differently (3:30 vs three thirty count as errors); the `numbers` tag slices them.

### The runner (`dictation_lab.py`)

- Uses the app's own entry points: the warm servers (`transcribe.py serve`'s `note` with `purpose: dictation`,
  `model_id`, the custom words, `prior`; `polish.py serve`'s `polish` with `model`, `vocab`, `context`), started
  offline first when they aren't running (a fresh ASR server re-runs itself under `uv run --with` on its first request:
  that request is retried).
- `mode=pieces` (default) replays the take's cuts: each piece transcribed with the text so far as `prior`, joined
  (`DictationStitch.join`'s space rule; a seam's 。，. dropped after a pause < 1.2 s), then polished once with the guard.
  `mode=windows` replays the cuts and polishes them as the app does while the user talks: DictationStream's sliding
  windows ported in `dictation_stitch.py` (the carried clause, the text so far as `dictated`, a correction piece
  merged, a fall-back's seam, the stitch guard; §Polish windows). `mode=whole` transcribes the take in one go. The fit
  at the cursor is not replayed, so a re-run is compared with re-runs (the regression's "before" is the last run with
  the same key), never with the live take.
- Config SPEC: `current`, or overrides `asr=ID,polish=on|off|ID,vocab=on|off,context=on|off,mode=pieces|windows|whole,
  language=…` (or JSON); the key is canonical (`asr=current,polish=current,vocab=on,context=on,mode=pieces`).
- `run`: rows `{id, truth, before, after, change (better|worse|same|new|error|n/a), text, raw, changed_text,
  fell_back, timings, tags}`, `overall {cases, scored, wer, cer, term_accuracy, score = 100·(1 − mean WER), better,
  worse, same, new, errors, fell_back}`, `by_tag`. Better / worse: WER moved by more than 0.5 points, else term
  accuracy. `--fail-on-regression` exits 1 when anything got worse (CI); `--no-save` leaves `runs.jsonl` alone.

```
uv run skills/blurt/scripts/dictation_lab.py run [--config SPEC] [--cases A,B] [--json] [--no-save] [--fail-on-regression]
uv run skills/blurt/scripts/dictation_lab.py rerun ID --config current --config polish=off --config asr=sensevoice-small
uv run skills/blurt/scripts/dictation_lab.py score --ref "…" --hyp "…" [--terms "Claude Code,tmux"]
uv run skills/blurt/scripts/dictation_lab.py add --wav FILE [--reference T] [--corrected T] [--tags term,punctuation]
uv run skills/blurt/scripts/dictation_lab.py export [--out FILE.zip] [--include-context]
```

### Dataset export

A zip: `dataset.json` (`{"name": "blurt-dictation-lab", "schema": 1, "created", "cases", "with_audio",
"sample_rate": 16000, "channels": 1, "manifest": "manifest.jsonl"}`), `audio/<id>.wav` (16 kHz mono 16-bit) and
`manifest.jsonl`, one line per case:

```json
{"schema": 1, "id": "…", "audio": "audio/<id>.wav" | null, "duration": 11.4,
 "text": "the target: corrected, else reference", "reference": "…", "corrected": "…",
 "asr_raw": "…", "asr_text": "…", "polished": "…", "final": "what was typed",
 "language": "zh", "segments": [{"start": 0.0, "end": 5.8, "text": "…"}],
 "errors": ["term"], "scenario": {…}, "rating": {"stars": 3, "good": null}, "note": "",
 "terms": ["Codex"], "app_bundle": "com.tencent.xinWeChat", "asr_model": "…", "polish_model": "…",
 "source": "take", "created": "…", "app_version": "…", "prompt": {…} | null, "tags": ["length:medium", …],
 "context": {"before": "…", "after": "…"}}
```

`audio` + `text` is an ASR fine-tuning / eval pair; `asr_raw` (or `asr_text`) + `text` a polish pair; `tags`,
`errors` and `scenario` slice the results. `context` only with `--include-context` and only for cases whose user
included it. Reference-only cases (no audio) are polish / text cases.

### Reading scripts

*Read a Script*: a pack of prompts to read aloud. The prompt's `expected` text (what should be typed: fillers and
corrected-away words gone; else what is read) becomes the take's reference, and the case carries `prompt`. Every take
is saved as a case of its prompt (retakes pile up; *Keep only this* moves the others to the Trash); *Read Again*,
*Previous*, *Next* (the next prompt not read yet); progress = prompts with at least one take. *Run All Cases* reports
by tag (`length:short`, `feature:correction` …).

- Packs: built-in `scripts/lab_packs/*.json` (`builtin.json`: 30 synthetic prompts covering every value of every
  dimension) and the user's `$BLURT_HOME/dictation/lab/packs/*.json` (a user pack with a built-in's id wins).
  *Import a Script…* = `dictation_lab.py import-pack FILE` (validated). Schema:

```json
{"schema": 1, "id": "typeless-history", "name": "…", "name_zh": "…", "description": "…", "source": "builtin|typeless-history|…",
 "created": "…", "prompts": [{"id": "t001", "read": "what to say aloud", "expected": "what should be typed (optional)",
   "tags": {"length": "short|medium|long|xlong", "scenario": "chat|coding|email|notes|meeting",
            "languages": "zh|zh-terms|en",
            "features": ["names", "numbers", "correction", "fillers", "enumeration", "question", "run_on"]},
   "origin": "seed|variant|generated"}]}
```

- *Generate 10 More* = `dictation_lab.py generate --pack ID --n 10 [--engine auto|agent|local] [--focus TEXT]`: a
  prompt with a dozen of the pack's own prompts as examples and the dimensions; the configured processing agent
  (`agents.py`: the first ready one, headless, its processing model) answers, else the local polish model (MLX, loaded
  for that one generation). The JSON array is cleaned (unknown tags dropped, duplicates skipped) and appended; a
  built-in pack grows as the user's own copy.
- A pack made from the user's own dictation history (e.g. Typeless's, read-only) is theirs: it lives in their
  `packs/`, never in the repository.

## Verification

(Each entry describes the code of its time; later work may have replaced what it checked — the model-first entry says
what went.)

- Live text (`promo/cases/v0.9-polish/livetext/`, not in git: `audio/` the three `say` clips, `results/` the takes
  (`results-r3.jsonl`, `summary-r3.txt`, `waits.txt`; the two earlier rounds with the wall-clock release kept for the
  record), `shots/` the panel during the zh, en and mixed takes, `scripts/` the driver and the analysis): `swift test`
  `DictationLiveDecodeTests` (one at a time, never while a final piece is pending, the interval and the window, slow /
  unsupported / failing servers, stale answers dropped, key-up, a simulated 60 s take on a serial server where no final
  piece ever waits more than one step, `compose`); `pytest tests/test_transcribe_interim.py` (a final request ends a
  3 s interim decode in < 0.5 s and is answered; an interim alone answers; a model that can't stop takes none;
  `Interrupted` isn't taken for a broken tag-aware decoder; an interim request without a preferred language goes
  through the loop). The isolated test build (`dev.blurt.recorder.auditlivetext`, scratch `BLURT_HOME`, models
  symlinked read-only, LaunchServices, the `dictation wav` hook as the mic, nothing pasted — no test pad, so the
  clipboard is never touched —, screenshots of its own panel only) for the numbers in §Live text.

- Model first (`promo/cases/v0.8-dictation-model-first/`, not in git: `audio/` the 28 new `say` cases (`vc*.wav`),
  `results/` the lab rounds `before-*-r{1,2}.json` / `after-*-r{1,2}.json`, the polish evals `polish-*.json`,
  `app-e2e.jsonl`; the scripts — the case generator, the scorer, the prompt experiments, the e2e driver — under
  `scripts/`):
  - `pytest tests`: `test_polish.py` — `Guard` (every Light reference and every structured reference passes; no
    language lists left; `listed`, `dropped`, `number`, `chatty` by unit pairs), `LightKeepsCorrections` (13 phrasings,
    zh and en, explicit and implicit: the guard accepts every word kept, the repair puts back a correction the model
    resolved anyway, the structured guard accepts it resolved; the prompts say so), `Repair` (mechanical: hesitations
    and stutters go, restatements and substitutions come back, numbers), `EngineLight` / `EngineStructure` (stubbed
    models: the words reach the model as said; a list from Light falls back; chat is a note in the request; the
    structuring pass, its refusals, its own prefix); `test_dictation_stitch.py` (the shared seam fixture, no word
    lists, a long pause's mark goes to the model, the structuring pass on Light's stitched text, a refusal types
    Light's); `test_dictation_styles.py` (`pick`, Auto, no renderer, the lab's style runs); `test_dictation_vocab.py`
    (`FalseCorrections`: no near-miss pass, 0 false corrections); `test_dictation_lab.py` (the fake pipeline's
    structuring pass);
  - `swift test`: `DictationStitchTests` (the shared fixture, `mark`, the case left alone, `listLines`),
    `DictationStyleTests.testPick`, `DictationStyleLearnTests` (the `suggest` record), `DictationFitTests`;
  - the lab rounds and the polish evals in §Self-corrections, §Styles and §Polish; the isolated test build
    (`dev.blurt.recorder.modelfirstcur`, scratch `BLURT_HOME`, LaunchServices, `BLURT_ALLOW_MULTI`, the `dictation wav`
    hook as the mic, nothing posted or pasted outside the test pad), unregistered afterwards (§Styles: in the app).

- Polish windows and self-corrections (`promo/cases/v0.8-dictation-polish-fix/`, not in git: `audio/` the 60 `say`
  cases, `results/` the lab rounds `before-r*.json` / `after-r*.json`, the polish evals, `app-e2e.jsonl`, the prompt
  variants; `scripts/`): `tests/test_polish.py` (`Corrections`: 39 shapes resolved, 37 left alone, nothing but the
  cancelled span lost, the guard / repair / stitch guard accept them; `EngineCorrections`; `Echo`),
  `tests/test_dictation_stitch.py` and `DictationStitchTests.testSharedSeamFixture` (the same
  `dictation_seams.jsonl`), `tests/test_dictation_lab.py::test_windows_replay_the_apps_polish_windows`; the isolated
  test builds `dev.blurt.recorder.polishfixbase` / `polishfixcur` (scratch homes, LaunchServices, `BLURT_ALLOW_MULTI`,
  the `dictation wav` hook as the mic, nothing posted or pasted outside the test pad), unregistered afterwards.
- Found on the way, the flaky test (`uv run pytest tests -q`, 1 run in 2 after a `swift build`): `test_index.py`'s
  `test_updates_are_fast_and_track_changes` / `test_items_py_write_updates_index` timed one SQLite update by the
  wall clock (< 50 ms); with the disk busy (a build, other agents) one took 75–1400 ms — reproduced 3 of 8 runs with
  `dd` + busy loops beside it, 0 of 8 once the budget counts CPU time (`time.process_time`). The renderer's budget
  counts CPU time too, and the session hook's 1 s wall clock is 3 s.
- Styles (`promo/cases/v0.8-dictation-styles/`, not in git: `say` clips in `audio/`, `results/`, screenshots; isolated
  test build `dev.blurt.recorder.stylestest`, scratch `BLURT_HOME`, launched through LaunchServices, models symlinked
  read-only, no real mic, no tap, nothing posted, nothing pasted outside the test pad):
  - `swift test` (219): `DictationStyleTests` (the shared list fixture — 15 lists, 20 that must stay prose: 以及 /
    其他 / 然后 / 另外 / 第一次 / 第一时间 / 一是一，二是二 / 一是一是 / "at first" / "first time" / "also" / "last week"
    — only marker words go, < 5 ms, instructions to an agent stay content, the router's precedence, the toggle, the
    categories, the variants), `DictationStyleLearnTests` (replacement only while untouched, a list taken apart, the
    signals, ≥ 3 at ≥ 70 % asked once, the window, the history's style and reformats through prune),
    `DictationTriggerTests` (⇧ alone in hands-free, tap and push-to-talk; ⇧ with a key or a click; a long ⇧; Fn+⇧ tap
    and hold; Fn+⇧+← is a shortcut; ⌥⇧ never starts; the island click); `pytest tests` (449): `test_dictation_styles.py`
    (the same fixture, light never lists either polish eval set in any category, the chat particles in the repair
    without touching the eval references or a self-correction, the lab's `style=` re-runs and `listed`).
  - In the test build (`results/e2e.jsonl`): a light list-like take typed as prose with the *Make a List* chip, then
    reformat → Structured replaced in the pad, Undo → back; ⇧ during a take, the island click, Fn+⇧ and ⇧ in
    push-to-talk each typed the list; an edit inside the pasted text → reformat copied it instead (`edited`); chat kept
    「吧」 and lost the one-sentence 「。」; verbatim skipped polish and reformat polished it on demand; three ⇧ takes in an
    app → the island asked once, *好* set Auto lists there and the next take was a list.
  - Latency, key-up → paste (the app's `total_ms`, release 0.1 s after the last word, warm models, M5 Max), the
    ceefbaa6 build and scripts against this one, run in alternation (10 takes per clip each, light; the "after" column
    includes 3 takes per clip in Structured):

    | Clip | Before (median, range) | After | 
    |---|---:|---:|
    | 3 s, one sentence | 280 ms (263–323) | 274 ms (258–290) |
    | 10 s, 2 pieces | 392 ms (328–441) | 394 ms (373–476) |
    | 30 s, 3 pieces | 610 ms (590–624) | 605 ms (582–672) |
    | zh list, 14 s | 450 ms (437–478) | 440 ms (429–461) |
    | en list, 11 s | 448 ms (435–474) | 435 ms (422–482) |
    | self-correction, 3.5 s | 277 ms (257–296) | 265 ms (253–283) |

    The styling itself (`style_ms`) was 0 ms on every take; the differences are the run-to-run spread of ASR and
    polish. Reformat-last's own work is ~1 ms; the replacement is a paste, confirmed when the clipboard comes back
    (~0.63 s), off the dictation's path.
- Only the user can check: a real ⇧ during a take (and that the Fn filter keeps it from their input method), Fn+⇧ on
  their keyboard, a click on the real island, and ⌥⇧L replacing a dictation in real apps (Notes, Mail, browsers,
  Electron editors, terminals: the selection is set through Accessibility; apps whose field can't be read — WeChat —
  get the clipboard instead).
- Dictation Lab (`promo/cases/v0.8-dictation-lab/`, not in git: `say` clips in `audio/`, screenshots in `shots/`;
  isolated test build `dev.blurt.recorder.labtest`, scratch `BLURT_HOME`, launched through LaunchServices, models
  symlinked read-only, no real mic — the `dictation wav` hook and an imported file —, nothing pasted, no tap):
  - `swift test --filter DictationLabTests` (the shared metrics fixture, the case schema and store keeping unknown
    keys, context only with consent, Undo of learning); `pytest tests/test_dictation_lab.py` (the fixture, units, WER
    / CER by hand, term spelling, the diff joining back, the schema and `validate`, `add` with resampling,
    `from-history` with and without audio, pieces replayed with `prior` and seams, configs, context only when
    included, the regression's before / after / overall / by tag with a fake pipeline, a failing case, `run` with no
    cases, export, `learn` feature-detected, packs: validation, import, progress, generation parsing);
  - in the test build: a take (11 s mixed Chinese, Qwen3-ASR 1.7B + Gemma 4 E2B, 1.8 s after release cold) with
    every stage, the fit against the lab's cursor fields, a corrected text → the app's learner (`dictation_vocab.learn`
    isn't there yet) learned 要合进 ← 要合并, Undo put it back; Compare over current / 0.6B / SenseVoice / polish off /
    no custom words; *Add to Lab* with and without audio; a script prompt read twice and by the dictation key (start
    and stop routed to the lab, no history entry, nothing typed); Run All Cases (score, by tag); Export (5 WAVs +
    manifest); Import Audio; a pack imported; `generate --engine local` wrote 5 prompts with Gemma 4 E2B;
    `dictation_lab.py run` against the real servers from a cold start.
  - What the lab found on the first takes: 「把这个文件，不对，这两个文件…」 polished to 「把这个文件，这两个文件…」 (the
    corrected-away words kept, the guard passed), and "Let's meet at 2:30, no wait, make it 3:30" was polished right,
    then the repair put "two thirty. No, wait. Make it" back.
- Only the user can check: a take from the real microphone (and the picker's other inputs), the dictation key starting
  and stopping a lab take with the main window in front, `dictation_vocab.learn` once it is merged.
- Names inside Chinese speech (`promo/cases/v0.8-dictation-names/`, not in git):
  - `pytest tests`: `test_dictation_vocab.py` — `CodeSwitch` (the tag threshold, translated English, the word list
    written out, `switch_language`), `TaggedDecode` (the preferred language reaches the tag-aware decoder, English-only
    users keep the plain decode, a failing decoder falls back for good, a context dump is decoded again), `NearMiss`
    (close misses, a weak miss needs the context, English text untouched, **0 false corrections** on the 40-sentence
    fixture with the seeded vocabulary read from the Swift source), `LearnFromCorrection` (`fixes`, `learn` writes the
    app's file and the next dictation lists the word first, suggestions / rejected / dry run, the CLI), the
    polish message (`relevant`, no title line, the English label); `test_polish.py` — the two Dictation Lab cases, lead-in
    words, a custom word in the taken-back words, the repair keeping spoken corrections out;
  - `swift test`: `DictationVocabularyTests` (the AI names in the seed with no ordinary-word sounds-likes; an explicit
    correction learned at once, `learnCorrection`), `DictationHistoryTests.testACorrectionIsKeptBesideWhatWasTyped`;
  - the isolated test build (`dev.blurt.recorder.namestest`, scratch `BLURT_HOME`, LaunchServices, test hooks only,
    no mic, nothing posted): a WeChat-like entry corrected on the Dictation page (`dictation history edit` /
    `correct`) → `Asopic` became a sounds-like of the seeded Anthropic, the page says 「已保存改正 · 记住了 Anthropic」
    (`shots/page-correct-editing.png`, `page-correct-saved.png`);
  - the eval and latency tables above.
- Only the user can check: their own voice saying names inside Chinese (the eval's voices are synthetic), and a
  correction saved on the Dictation page after a real WeChat dictation.

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
- `pytest tests/test_polish.py tests/test_dictation.py tests/test_dictation_vocab.py` (no rewriting, ranking,
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
