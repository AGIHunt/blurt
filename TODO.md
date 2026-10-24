# TODO / Roadmap

## v0.1 (current)
- [x] Recorder: ffmpeg video (macOS avfoundation, Windows ddagrab/gdigrab) + PortAudio mic, wall-clock A/V sync
      (verified ≤ 1 frame on macOS; ffmpeg's own mic capture dropped ~10% of samples, so it's not used)
- [x] VAD-first ASR: SenseVoice (local), mlx-whisper, faster-whisper, OpenAI-compatible, DashScope
- [x] Frame tools: activity scan, diverse candidates, contact sheets, red-box/crop grab, clips
- [x] Local review page (edit / delete / merge / jump-to-moment / confirm)
- [x] Export: Markdown + CSV, Feishu (lark-cli guide + OpenAPI fallback), GitHub/other guides
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
      `DictationTrigger` with its v0.9 rules: `busy` while a take is typed, the double-tap window from the system's
      double-click time (`GetDoubleClickTime`, clamped 0.3–0.5 s), push-to-talk → release, double tap, the near miss,
      events stamped with their own time; `DictationTriggerTests` are the spec), and start the warm servers with
      `--parent <app pid>` so they end with the app), insert with `SendInput` Ctrl+V after saving / restoring the clipboard (all formats);
      UIPI blocks input into elevated windows: detect and fall back to copy. Polish: no MLX — llama.cpp / ONNX Runtime
      GenAI with the same Qwen models (GGUF / ONNX), same guard, same eval set.
- [ ] **Linux** (Tauri app): X11 — XRecord / XInput2 for the key, `xdotool key ctrl+v`; Wayland — no global key
      listening for normal apps: evdev (`/dev/input`, needs the `input` group) or a compositor shortcut that runs
      `blurt dictate toggle`; insert with `wtype` / `ydotool` (needs uinput) or the clipboard + a toast; terminals
      want Ctrl+Shift+V. Detect the session type and say what works in Settings.
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
