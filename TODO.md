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

## Next
- [ ] **Cursor track as data**: record mouse position / clicks / "circle" gestures to `cursor.jsonl` (macOS CGEventTap,
      Windows low-level hook) → precise crops and auto red circles, no pixel guessing
- [ ] **Annotation overlay**: transparent click-through window; hold a key to draw circles/arrows that fade; click ripples
- [ ] **Marker hotkey**: one key = "new issue starts here" (optional hint for segmentation)
- [ ] **Browser telemetry** (extension or injected script): console errors, failed network requests, URL changes,
      clicked element selector/text — timestamp-aligned with the video → exact component lookup
- [ ] Native recorder binaries (ScreenCaptureKit / Windows.Graphics.Capture) for lower CPU and better cursor capture
- [ ] Mobile: `xcrun simctl io booted recordVideo`, `adb screenrecord` / scrcpy
- [ ] Qwen3-ASR (sherpa-onnx int8) as optional local multilingual backend; auto-benchmark on install
- [ ] Linux support (x11grab / PipeWire portal)
- [ ] More exporters as scripts where CLIs are awkward (Linear, Jira, Notion)
- [ ] Hosted ASR API (paid, with free trial minutes) — later
