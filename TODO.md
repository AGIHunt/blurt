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
- [x] End-to-end Feishu export with lark-cli (multi-attachment cells, resumable)
- [x] Logo (吐槽鸡, 3 variants in assets/)
- [ ] Project homepage
- [ ] Windows sound/notification polish; macOS menu-bar "stop" button (today: say "done" in chat)

## v0.2
- [x] Native macOS recorder (ScreenCaptureKit): region picker, countdown, floating bar (pause / restart / finish),
      hotkeys, never-captured chrome, events.jsonl (pauses, clicks, cursor samples)
- [x] Tk recorder for Windows (+ macOS fallback): same flow, ffmpeg segments for pause, WDA_EXCLUDEFROMCAPTURE
- [x] Standalone Blurt app + recordings inbox (~/Movies/Blurt), `record.py inbox`, batch processing in SKILL
- [x] Review page v2: focus mode with keyboard triage, list view, undo, merge, answers to open questions
- [ ] Verify the Tk recorder + Start-menu shortcut on real Windows 10/11 (DPI, multi-monitor, gdigrab region)
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

## Next
- [ ] **Cursor track as data** (macOS part done: clicks + cursor in events.jsonl): circle-gesture detection,
      Windows hook → precise crops and auto red circles, no pixel guessing
- [ ] **Annotation overlay**: transparent click-through window; hold a key to draw circles/arrows that fade; click ripples
- [x] Marker hotkey ⌥⇧M exists (no button — too obscure); markers go to events.jsonl
- [ ] **Browser telemetry** (extension or injected script): console errors, failed network requests, URL changes,
      clicked element selector/text — timestamp-aligned with the video → exact component lookup
- [ ] Native recorder binaries (ScreenCaptureKit / Windows.Graphics.Capture) for lower CPU and better cursor capture
- [ ] Mobile: `xcrun simctl io booted recordVideo`, `adb screenrecord` / scrcpy
- [ ] Qwen3-ASR (sherpa-onnx int8) as optional local multilingual backend; auto-benchmark on install
- [ ] Linux support (x11grab / PipeWire portal)
- [ ] More exporters as scripts where CLIs are awkward (Linear, Jira, Notion)
- [ ] Hosted ASR API (paid, with free trial minutes) — later
