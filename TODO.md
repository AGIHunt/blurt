# TODO / Roadmap

## v0.1 (current)
- [x] Recorder: ffmpeg video (macOS avfoundation, Windows ddagrab/gdigrab) + PortAudio mic, wall-clock A/V sync
      (verified ≤ 1 frame on macOS; ffmpeg's own mic capture dropped ~10% of samples, so it's not used)
- [x] VAD-first ASR: SenseVoice (local), mlx-whisper, faster-whisper, OpenAI-compatible, DashScope
- [x] Frame tools: activity scan, diverse candidates, contact sheets, red-box/crop grab, clips
- [x] Local review page (edit / delete / merge / jump-to-moment / confirm)
- [x] Export: Markdown + CSV, Feishu (lark-cli guide + OpenAPI fallback), GitHub/other guides — v0.9: the Feishu
      exporter is removed; Markdown/CSV and the hand-off bundle (`export_local.py bundle`, MCP `bundle_items`) stay,
      every other destination goes through the agent's own tools
- [x] Verified on macOS 26 (Apple Silicon): real screen + mic, transcription, frames, review, Feishu export
- [ ] Verify on Windows 10/11 (ddagrab/gdigrab, WASAPI mic via sounddevice, DPI scaling, wall-clock sync)
  — 2026-10-18 on a Windows Server 2022 VM over RDP: full pipeline, ddagrab→gdigrab fallback, no-mic path OK.
  Still open: a real mic (WASAPI), high DPI, multi-monitor, hardware encoders (#7: h264_qsv passes the lavfi probe but starves)
- [x] End-to-end Feishu export with lark-cli (multi-attachment cells, resumable)
- [x] Logo (口喷鸡, 3 variants in assets/)
- [x] Project homepage: `site/` (static, zh + en), on Cloudflare Pages → blurt.agihunt.info (`site/README.md`)
- [ ] Windows sound/notification polish; macOS menu-bar "stop" button (today: say "done" in chat)

## v0.2
- [x] Native macOS recorder (ScreenCaptureKit): region picker, countdown, floating bar (pause / restart / finish),
      hotkeys, never-captured chrome, events.jsonl (pauses, clicks, cursor samples)
- [x] Tk recorder for Windows (+ macOS fallback): same flow, ffmpeg segments for pause, WDA_EXCLUDEFROMCAPTURE
- [x] Standalone Blurt app + recordings inbox (~/Movies/Blurt), `record.py inbox`, batch processing in SKILL
- [x] Review page v2: focus mode with keyboard triage, list view, undo, merge, answers to open questions
- [ ] Verify the Tk recorder + Start-menu shortcut on real Windows 10/11 (DPI, multi-monitor, gdigrab region)
  — 2026-10-18 VM: picker (drag / F / Esc), countdown, region crop, bar hidden from capture, Alt+Shift P/M/S,
  chat pause/resume/stop, Start-menu shortcut OK at 100% scale, one monitor
- [ ] Use events.jsonl clicks/cursor in frame selection (auto red circle at the click position)

## v0.3
- [x] Generalized beyond bugs: items with kinds (issue / idea / note / task) + custom lenses, session digest
- [x] Review page: per-kind layouts, generic fields for custom lenses, Overview tab, kind filters
- [x] Exports: Markdown grouped by kind, one CSV per kind, Feishu `--kind` with per-kind default columns
- [x] Menu-bar resident app: ⌥⇧R start/finish, ⌥⇧B menu, workspaces (~/Blurt or bound project), recent recordings
      (copy to share / reveal / process), background processing via Claude Code or Codex, open at login
- [x] Region picker fixes: click-through hole, drag vs move, Esc/Enter without app activation
- [x] Universal Blurt.app built in CI (attach to releases on `v*` tags)
- [ ] Developer ID signing + notarization (no right-click-Open on first launch)
- [ ] Demo GIF / video for the README
- [ ] Windows tray app (resident mode parity)

## v0.6 (feat/live-snap) — snap mode, live pipeline, perch — design: docs/design/snap-and-live.md
- [x] Live pipeline: recorder → live/audio.pcm, `live.py` streaming ASR (transcript ready ~1 s after stop) + drafts
      via a small model (claude haiku or codex, whichever CLI is logged in) → eggs in the HUD nest, live caption
- [x] Text-first processing: `items.py` patches under a lock, review page opens as soon as items exist, frames stream in;
      user edits win (measured: stop → review ~74 s, all frames ~115 s in the integrated app run with codex)
- [x] Snap mode ⌥⇧A: standalone (release-to-capture, auto-listening voice note / typing / ink, batch `-shots` session,
      "🐔 整理 N 张") and during recording (no pause, full-res still anchors an item); Tk: in-recording snap only
- [x] Perch (top-of-screen shelf, chicken-foot clips, spring / swing / gravity, drag-out, never captured); kind eggs
- [x] App unattended runs: agent launched with the user's login-shell env (not the opening session's); login preflight
- [x] Homepage: playable snap demo, eggs, speed copy, dark mode, `site/llms.txt` (not deployed yet)
- [ ] Verify on Windows/Linux VMs: live/audio.pcm sidecar from MicRecorder, in-recording snap (ffmpeg frame grab)
- [ ] Real mic: silence endpointing of voice notes; real ⌥⇧A / hold-⌃ pen in the integrated app (tests used hooks)
- [ ] Frames phase: first `frames.py` call inside codex spent ~59 s installing numpy/pillow — warm deps or pre-scan
- [ ] Standalone snap + perch on Windows/Linux; "收集系统截图" toggle and drop-into-Terminal untested
- [ ] Rebuild the Kai font subset for the new homepage copy (full source not on the build machine)
- [ ] `live/audio.pcm` kept after the run (~115 MB/h) — delete after transcript.json once the mp4 is verified

## Dictation (v0.8) — design: docs/design/dictation.md

- [x] macOS: right ⌥ / Fn tap or hold → SenseVoice → local polish (MLX, Qwen) with a content-loss guard → paste into
      the front app (pasteboard saved and restored) → history (search, raw text, turn into item)
- [ ] **Windows** (Tauri app): a low-level keyboard hook (`WH_KEYBOARD_LL`) for right Alt (`VK_RMENU`, ignore the
      `LCtrl` that AltGr layouts inject, ignore it as a modifier exactly like the macOS state machine — port
      `DictationTrigger` with its v0.9 rules: `pending` while a take is typed (a tap past the double-tap window starts
      the next take, Esc cancels the one on its way, a third tap after a send is a bounce, `endedByItself`, `miss`), the double-tap window from the system's
      double-click time (`GetDoubleClickTime`, clamped 0.3–0.5 s), push-to-talk → release, double tap, the near miss,
      events stamped with their own time; `DictationTriggerTests` are the spec), and start the warm servers with
      `--parent <app pid>` so they end with the app), insert with `SendInput` Ctrl+V after saving / restoring the clipboard (all formats);
      UIPI blocks input into elevated windows: detect and fall back to copy. Polish: no MLX — llama.cpp / ONNX Runtime
      GenAI with the same Qwen models (GGUF / ONNX), same guard, same eval set.
- [ ] **Linux** (Tauri app): X11 — XRecord / XInput2 for the key, `xdotool key ctrl+v`; Wayland — no global key
      listening for normal apps: evdev (`/dev/input`, needs the `input` group) or a compositor shortcut that runs
      `blurt dictate toggle`; insert with `wtype` / `ydotool` (needs uinput) or the clipboard + a toast; terminals
      want Ctrl+Shift+V. Detect the session type and say what works in Settings.
- [ ] **Windows / Linux: the v0.9 dictation dogfood fixes** (macOS done; docs/design/dictation.md §Takes in flight,
      BlurtCore `DictationTakeFlow` + `DictationTakeFlowTests` are the spec): takes in flight pasted in order
      (`DictationPasteQueue`), paste only into the app the take started in (foreground window's process at key-down vs
      at paste; else copy + "Copied — paste with Ctrl+V", Return dropped), Esc cancels a take on its way, the typed
      text shown in the live panel for 1.5 s after the stop, no-model refusal + `getSpeechModel` (one downloader entry),
      `no_download` on every dictation request and `note --no-server --no-download` as the CLI fallback, recognition
      failures keep the wav + a history row + Retry, the server timeout scaled to the audio and a hung server ended,
      the forgotten hands-free take (`DictationRunaway`: 20 s reminder, countdown from 4:30, the limit said), skipped
      Return / wrong-mode press / model fallback notices, first-takes tips (`DictationTip`), reformat toasts bound to
      their take, Clear History keeping live audio, learning once at the watch's end (`DictationLearn.EditWatch`),
      split fixes + no punctuation in terms, Save Correction suggesting with Add / Undo / ⌘Z, the Words tab's keyboard,
      Undo, rename and "a, b, c" adding. `dictation_vocab.py` already has the Python side of the learning rules.
      Review round: readiness from `dictation-models`' `ready` / `missing` (`DictationSpeechModels`: the VAD counts, a
      cloud model is judged by itself, the configured model is what Download… gets), Retry offered once the model
      arrives, Undo on "Cancelled" for takes stopped on their way (audio kept 5 s), ⌥⇧L bound to its take
      (`DictationReformatAfterPaste`), a miss reported once (`takeMiss`), a given-up server by pid and not ended while a
      voice note waits on it, the typed check in the live panel, the top line's fade, the aura after the double-tap
      window (`DictationGlow`).
- [ ] **Windows / Linux first run**: the macOS setup assistant is dictation first (docs/design/desktop-app.md §2.2:
      welcome → dictation's permissions → one "Download recommended models" for the machine's tier → try it, with
      "open at login" on); the Tauri app has no first run yet — give it the same four steps once dictation lands there.
- [ ] **Vocabulary / personal dictionary**: words the user teaches (names, product terms, code identifiers) as ASR
      hotwords (SenseVoice / Whisper prompt) and as a "spell these exactly" list in the polish prompt; learn candidates
      from edits made right after a paste (and from the history's raw → polished diffs), always opt-in.
- [ ] Per-app style (code editor: no trailing full stop; chat: casual), voice commands ("new line", "删掉上一句")
- [ ] Streaming: show the live transcript in the island while talking (live.py's streaming path)

## Next
- [ ] **Cursor track as data** (macOS part done: clicks + cursor in events.jsonl): Windows hook → precise crops and
      auto red circles, no pixel guessing
- [x] **Pen** (macOS): hold ⌃ and drag to circle / underline; ink fades 3 s after the last stroke, is in the video and
      in events.jsonl (`frames.py marks`, `grab --crop/--box stroke`); ✎ on the bar / ⌥⇧D keeps it on
- [ ] Pen on Windows (Tk overlay), click ripples, pen for the review page (draw on a frame to correct the agent)
- [ ] Windows / Linux counterparts of the v0.8.7 capture fixes (macOS done): a cancelled voice note keeps its audio
      for "Voice note discarded · Undo" (5 s); editing a card's note shows its spoken words to correct, and a re-record
      never overwrites the old wav until it is kept; cards never age out of the thread; when drag-out pastes notes,
      never into a code editor (VS Code, Cursor, Zed, JetBrains…)
- [ ] Hanging cards on Windows / Linux (web/apps/overlays island.ts, crates/blurt-capture overlay.rs): bring over the
      v0.9 Mac rules (BlurtCore CardRow.swift): newest first, at most 5 + a "+N" tile that opens an overview of every
      card (no paging); a 180 ms dwell before they drop and 0.25 s to go up; Delete / Delete All with Undo instead of
      none (deletes while the Undo shows join it); "Auto-sort" on one card vs "Auto-sort All Cards" in the island menu;
      the click's copy deferred past the double-click interval; the hover note only when the card cuts its note short;
      keyboard + screen-reader access (↩ copies and hands the keyboard back; ↩ on "+N" puts it in the overview); Esc
      only while pointed at or 4 s after a reveal, and a reveal never pointed at lapses after 10 s; the first-card hint

- [x] Documents from recordings (requirements / design doc with the marked frames): `reference/docs.md`
- [x] Marker hotkey ⌥⇧M exists (no button — too obscure); markers go to events.jsonl
- [ ] **Browser telemetry** (extension or injected script): console errors, failed network requests, URL changes,
      clicked element selector/text — timestamp-aligned with the video → exact component lookup
- [ ] Native recorder binaries (ScreenCaptureKit / Windows.Graphics.Capture) for lower CPU and better cursor capture
- [ ] Mobile: `xcrun simctl io booted recordVideo`, `adb screenrecord` / scrcpy
- [ ] Qwen3-ASR (sherpa-onnx int8) as optional local multilingual backend; auto-benchmark on install
- [x] Linux/X11 support (x11grab, Tk recorder; verified on Ubuntu 24.04 + Xvfb)
- [ ] Linux Wayland (PipeWire portal); global hotkeys on Linux
- [ ] More exporters as scripts where CLIs are awkward (Linear, Jira, Notion)
- [ ] Hosted ASR API (paid, with free trial minutes) — later
- [ ] Windows / Linux (Tauri) counterparts of the Mac's session fixes (2026-10): an item whose session ended without
      a report stays in progress — say "Session ended without reporting back" with Open Session / Mark as Done (Take
      Back + Mark as Done when the job is gone), one Open Session per item, failed session actions toasted; an organizing
      run there should also set BLURT_NO_ROUTE and run `projects.py route --apply --session DIR` itself afterwards
      (agents.json `run` is now least-privilege, `{writable}` = `--add-dir` per folder, Linux codex: landlock). Also:
      run it with cwd = the session folder (never the project), put `agents.py command`'s `env` (UV_CACHE_DIR,
      BLURT_NO_INDEX) in its environment, name `uv run <scripts>/<name>.py` with its `scripts` path in the prompt
      (Claude / Gemini may run nothing else), and re-index the batch afterwards
- [ ] Windows/Linux app (web/apps/desktop): follow the Mac main window's copy — the inbox subtitle is just the parts
      ("3 new · 2 to verify" under "Inbox", no "Needs you:" prefix; `inbox.needs_you`), the Dictation page without
      the items' toolbar actions, no filter chips and a blank detail while there are no items at all

## Windows / Linux app (Tauri) — counterparts of the Mac shell fixes (audit E2)
- [ ] **Export → hand-off bundle** (Mac v0.9, area nxbundle): feishu.py and reference/export-feishu.md are gone (git
      history keeps them), and so is the Mac's Settings → Export. The Tauri app still lists export targets with Feishu
      / Lark (`apps/desktop/src-tauri/src/settings.rs` `export_targets`, `web/apps/desktop/src/mock.ts`,
      `settings.tab.export` / `settings.export.*` in `web/apps/desktop/src/locales/*.json`): drop the Export tab, open
      Agents for an old `blurt://settings/export`, show each agent's skill + MCP state and the three "Ask your agent"
      requests (`agents.ask.*` in the Mac's Terminal.strings) with Copy. Main window: "Export Hand-off Bundle…" on the
      selection (Item menu, context menu, the Hand Off menu, Ctrl+K) → a native save dialog suggesting
      `<project>-<date>-<n items>.zip` (export_local.py `bundle_name`) → `export_local.py bundle --items … -o <file>`,
      then a toast with "Show in folder". No item changes state.
- [ ] Hand-off sessions (Mac v0.9 dogfood, docs/design/system.md §3.3 "A session's ended card"): show an ended
      session's card, not the dead terminal (`SessionOutcome`: couldn't start / ready to review only with changes /
      ended · no changes), with the agent's `agent.last_output` and `job.error`, Restart Session (`sessions.py restart`),
      Take Back and Show Output; the item banner by `SessionBannerPlan` (neutral once ended, never Mark as Done as the
      primary); the review sheet's Commit and Merge, no PR / merge of an empty branch, Esc everywhere, ⌘/Ctrl+Enter to
      merge; the hand-off panel refuses a logged-out agent inline and offers the other one. The Rust job fold: a
      finish event's `detail.error` becomes `error` (jobs.py / BlurtCore JobFold do). Review follow-ups: Restart /
      Take Back off while one runs (`sessions.py restart` already refuses a second one: code `finished`); the banner
      shows two buttons and a ⋯ menu (`SessionBannerPlan.more`), its Review Changes… opens the sheet; the watchdog's
      *No response* (`status_source: "watchdog"`) with Restart; the panel passes `--force` only after its own login
      check; one state wording everywhere (`AgentSessionRow.stateText`).
- [ ] Hand-offs beyond Blurt's terminal (Mac v0.9-next, next-round.md K5 "交接标题、Claude 桌面端"): the scripts do the
      title line and the Codex thread name on every platform already. The app side: the hand-off panel's *Run in
      Blurt's terminal (recommended) / Run in Claude desktop* (only when the Claude desktop app is installed: on
      Windows its install folder / protocol handler for `claude:`, on Linux whether `xdg-mime query default
      x-scheme-handler/claude` answers), remembered per agent in `sessions.target`, and the same row in Settings →
      Agents; `sessions.py dispatch --runner desktop` and open each row's `url` (only the `claude:` scheme, BlurtCore
      `DesktopLink`) — never under the test channel; the one line "confirm the folder and press Send"; the no-MCP
      callout with Install…; the banner *In Claude desktop · progress comes from the agent* + Go to Claude
      (`SessionBannerPlan` with `desktop:`); the session pane's desktop card instead of a terminal; *Continue in Claude
      Desktop…* only when `sessions.py desktop-check` says available (`DesktopContinue.offered`), asking first —
      with its `mcp: false` the question says items need marking by hand and offers Install…, and Continue passes
      `--without-mcp`; a desktop session's still status mark (no spinner, not in the running count) and the card's
      no-MCP wording (`agent.desktop.mcp`). `claude --desktop` itself: check on Windows that it opens the desktop app as on the Mac.
- [ ] Organising runs: start the agent in its own process group / job object (Mac: BlurtCore `ProcessGroup`), record
      `agent_pgid` and its leader's start time (`agent_pgid_start`), stop it on quit (ask first — not on logout /
      shutdown) and stop a leftover one at launch only while it is still that group (`ProcessGroup.isOurs`; a reused
      id is left alone); one organiser per recording, checked
      against the job files; failed organising stays in the jobs list with Retry / Dismiss (`dismissed: true`) —
      `JobFailures` in BlurtCore.
- [ ] Settings like the Mac's v0.9 window (docs/design/desktop-app.md §2.3): a sidebar with a search field and the
      panes in three groups (Preferences / Work / This Mac), a page of rows (title + one-line description, control on
      the right), search across every row in English and Chinese with per-row keywords (port BlurtCore
      `SettingsCatalog` — ids, string keys, the `settings.kw.*` keywords — so both apps search the same index), a hit
      opens its pane, scrolls to the row and flashes it; `blurt://settings/<pane>/<row>`
- [ ] `settings.rs` `write_config`: take `$BLURT_HOME/.config.lock` (the lock `_common.update_global_config` and the Mac
      `Config.set` share) and never overwrite a config.json that doesn't parse (copy it to `config.json.bad-<time>`, say
      so once) — BlurtCore/Config.swift
- [ ] `blurt://record` / `blurt://snap` from outside: ask in the app first unless it is in front (Mac: App.confirmFromURL)
- [ ] One model download manager (Mac v0.9: App/ModelDownloads.swift + BlurtCore ModelDownloadQueue, desktop-app.md
      §2.2 "Models"): every download (onboarding, Settings → Speech, the dictation key) through one queue — one at a
      time, never the same model twice, its progress in the tray menu and on the model's row ("Queued" for the rest),
      `$BLURT_HOME/model-downloads.json` so a quit or crash carries on at the next launch (one launch line), Stop /
      SIGTERM (143) never "failed", `setup --parent <pid>`, terminate the setup on quit, warm the dictation model when
      it lands. The scripts' side (lock per model, Range resume, the ModelScope manifest + marker) is shared already.
- [ ] Dictation key without a model: start nothing, say "no speech model yet · Download" / "still downloading · Show";
      spawn the warm server and the CLI fallback with `BLURT_NO_DOWNLOAD=1` (Mac: Dictation.speechModelMissing → noSpeechModel, WarmSpawn)
- [ ] Shortcuts: refuse Ctrl+letter combos every app uses (Ctrl+C, Ctrl+V, Ctrl+Z, Alt+F4…; Mac: KeyCombo.reserved
      refuses ⌘ / ⇧⌘ + a typing key) with the reason inline; a key another action has asks to swap; undo; keyboard
      operable fields. Two running instances: the first keeps the dictation key and hotkeys, the other takes over
      when it quits (Mac: the registry's `dictation` / `started`, HotkeyCenter.dictationOwner, the 3 s liveness look)
- [ ] First-run line only with working keys (Mac: BlurtCore WelcomeLine); the permission guide's done line promises
      dictation only with a model; Input Monitoring "Not needed" when the key is heard another way; the skill
      contract mismatch persistent (tray menu row + Settings → General) and ranked above the welcome; a dropped model
      suggestion stays pending (`app.model_suggest_pending`) until seen
- [ ] Storage: Move to Trash at once with Undo (only the auto-delete policy asks); Privacy's "Never use cloud speech
      recognition" says what it does where things stand; Settings → General's language change offers Relaunch Now
- [ ] After the v0.9 shell review (Mac counterparts): a failed model ends only its own request (ModelDownloadQueue
      `group` / `ended`), Stop-all spares a model asked for while stopping, "Unpacking…" on the row and tray item,
      "Stop" everywhere; a model counts as installed only with the VAD (`dictation-models` `files` / `vad`) and the
      HF snapshot check (`transcribe.py _snapshot_complete`, shared); "nothing heard" names the mic with Change Mic…
      (BlurtCore NothingHeard); the Try-it step's second exercise (double tap = send); the Shortcuts swap is an
      exchange ("Move Here" when there's nothing to give); registry entries count only while their pid's start time
      matches (HotkeyCenter.isLive), and the dictation key goes to the instance that hears it; a denied permission's
      button says System Settings…; Storage Undo merges into a recreated folder and says what couldn't come back;
      toggle help phrased by state ("On: …" / "Off: …"); Feishu links on a private domain with a /base/ path
- [ ] One message at launch (Mac: LaunchMessages) and the skill contract check (`_common.CONTRACT`, Mac: SkillContract)
- [ ] Storage: per-model sizes, deleting videos of organized recordings (by hand, or after N days — off by default)
- [ ] Linux: `$BLURT_HOME` and `~/Blurt` 0700, tokens / history 0600 (the scripts already write 0600 under `$BLURT_HOME`)
- [ ] One chick on the web too: the Mac mascot is now the 4A logo chick in colour, drawn and moved in code
      (Icons/MascotArt.swift + the generated MascotGeometry.swift; docs/design/system.md §6.1). The overlays and the
      Tauri app still play the 1A raster strips (`@blurt/icons/mascot`, assets/mascot). Port: have chick.swift also write
      the geometry for TS (or SVG parts), draw it in a canvas / SVG with the same clips and timings, then drop the webp
      strips and assets/mascot.
- [ ] Brand pass (Mac v0.9, docs/design/system.md §3.2): the overlays have no Recently Dragged Out list yet — when they
      get one, use the Mac's row (tile, one-line note, "dragged out … · kept N days", Copy as the one primary on the
      row under the pointer + "···") and its capture tile (a voice note = a `--brand-tint` tile with the waveform in
      `--brand-ink` and its length; never a bare mic glyph). Done toasts ("Saved", "Copied") carry the `ok` check in
      the overlay island too; search hits that span lines show on one line (" · ") in the desktop app's lists.
- [ ] Island toasts and cards (Mac v0.9 fix pass, docs/design/system.md §3.2) in the overlays: the toast rule of BlurtCore
      `ToastQueue` (newest reply first, same key replaces at once, launch / job lines behind replies, stale ones dropped,
      ≥ 5 s and held while pointed at); toast content spanning the whole shape (`IslandLayout.toast`: text 18 pt in, the
      button under the right ear's number, a lone line centred); ears anchored to the outer edges, no cross-fades; one
      live meter in the open voice island; dictation's "Sent" as the ok check in the right ear; recording ear: pause
      bars when paused, the pen while latched, markers counted apart, the discard question naming the stills; the
      live-text panel in the island's black and width family; snap cards shaped by their picture (`CardShape`), the
      mic mark leading the caption, a clean "+N" count tile; the desktop app's page toasts on the island (host
      method `toast`). Follow-ups from the review: older plain replies superseded by a newer one (never shown after
      it), a pushed-out Undo back for its real remaining time, `onGone` answering a page toast "gone"; a click on a
      toast's line opens the island, only its button acts; the live panel's width ignoring toasts and, without a
      notch, the overlay widening to the panel's family; "Couldn't transcribe" in amber with the mic mark kept; ⇧'s
      style line only the first two times; the cards count in mint on the plain stack glyph.
- [ ] Capture fixes from the Mac v0.9 dogfood run (docs/design/next-round.md §K7 细则 v0.9; port BlurtCore
      `CaptureRules.swift` with its tests): the snap's note shows the words as they are heard and "Saved" with the final
      words; it never closes under the pen (a stroke holds the pause end; 2.5 s after the last stroke) or while typed
      text waits (committed text only, not an IME composition); Esc clears typed text first, then discards (Undo 5 s);
      a project capture without a note is filed into the project; a failed transcription — or a voice note with no
      words — keeps its project (`intended_project`), says so with Retry and files once Retry has the words (never an
      empty item); a voice note the user ends is kept unless it is short or held no sound above the room
      (`soundSeconds`: a fan or a hum is not a note; "No words recognized · Retry"); "check the microphone" when
      nothing was heard; a mic lost mid-note ends it with what was said (before speech: "Mic disconnected · type a
      note"); a cancelled voice note waits for its Undo as NNN.discarded.wav (a quit never brings it back); the Saved
      moment holds under the pointer and pins on a click into the words; a recording's notes pause once per session; one listener at a time (a snap during a voice note is
      typed only); quitting saves what is on its way and the next launch files it (and repairs a cut-off wav);
      Screen Recording missing / stale → one island line and the permission guide (re-add form for a stale grant);
      auto-sort with no agent leaves the cards; click-copy without the paste permission says only the picture pastes;
      a failed recording keeps its stills.
- [ ] Main window v0.9 fixes (Mac, branch fxmainwin) — the Tauri app's counterparts:
  - Detail pane: pass `--item UID` to `items.py doc/poll/user-ops` (`apps/desktop/src-tauri`), and in `ReviewPane.tsx`
    remount / reload when `handle.setItem()` returns false — never show the previous item for a discarded one.
  - Filters per place (BlurtCore `PlaceFilters`): the Inbox never applies a State filter; save `filters` per place.
  - Search by item id in `apps/desktop/src-tauri/src/index.rs` (the same rule as `index.py search` / IndexReader:
    an id-shaped term = `upper(item_id) = ?` or an FTS match, that item first).
  - Undo for Move to Project (each item back to its project; items.py gives it its old id back), a toast after
    A/D/R/W/X with Undo, and the reason when a key doesn't apply.
  - One undo stack per window: implement the host's `registerUndo` / `windowUndo` / `undone` / `focusList` in the
    Tauri host (review `host.ts`), so the detail page's steps share the list's undo.
  - Projects: rename in place in the sidebar, the user's order (`projects.py order`, drag to reorder; `⌘5`–`⌘9`
    follow it), Remove from Blurt with Undo (`projects.py remove` answers the entry, `restore` puts it back).
  - Rename an item in place (E), 1–4 = kind, the ? panel grouped and localized, one spinner (the brand arc).
  - Undo after review: register each undoable write when it is asked for and run the writes one after another
    (BlurtCore `SerialWork` / `UndoStep`), drop a failed write's step; ⌘⌫ / Delete on the list discards items (never a
    project); an id typed in the search that this place doesn't list says where the item is (Show it); ↑ from the first
    row reaches the banners above the list. (The page's per-step state undo is in the shared review store already.)
