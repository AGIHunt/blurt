**Title:** v1.0.0: Blurt, the keyboard for the agent era (desktop app, dictation, cards, recordings into items, agent hand-off)

## What this is

Blurt (口喷鸡) becomes a Mac menu-bar app that sits next to the agents you already use (Claude Code, Codex, Cursor,
Claude, ChatGPT) and gets what you mean into their input box: by text, voice, screenshot or screen recording. Runs
locally. Free and open source. macOS today; Windows and Linux are coming soon.

## What's in it

**Dictation (`Fn`)**
- Tap `Fn` to start and again to stop (or hold it). Double-tap instead of the stop tap to send.
- Works in every app. In terminals and code editors the text stays on one line. Password fields are never typed into.
- Speech recognition and polish run on the Mac with open-source models (Qwen3-ASR, a local polish model, MLX).
- Live text under the notch while you talk.
- `⇧` switches between the normal style and Structured (lists), and the notch shows the list mark while it is on.
  `⌥⇧L` reformats the last dictation.
- Words list, learning from your fixes (suggestions, never silent replacements), and 30 days of history.

**Snaps and voice notes as cards (`⌥⇧A`, `⌥⇧V`)**
- Snap an area and draw on it in place (freehand, ⇧ rectangle, ⌥ ellipse, ⌘Z), with a note by voice or typing.
- Voice notes support Structured with `⇧` too.
- Cards hang under the notch. Drag them into Claude, ChatGPT, Slack, Notion, WeChat or Feishu/Lark (the picture, then
  the note), or into a terminal (paths for Claude Code or Codex). Click to copy, ⌘-click for several. Recently
  Dragged Out keeps them for 7 days.

**Recordings into items (`⌥⇧R`)**
- Transcribed while you record; items are ready about a minute after Finish.
- Your coding agent splits the recording into issues, ideas, notes and tasks, each with a frame, the spot marked, steps
  and suspected code.
- A take survives writer failures and screen lock: pieces are joined at Finish, and failure reasons are recorded in
  plain words.

**Review, projects, hand-off**
- Keyboard review (`A` / `X` / `J` / `K`).
- A manual current project, otherwise Unassigned. AI only suggests a project. Batch moves with Undo.
- Hand Off to Agent (`⌘↩`): Claude Code or Codex, inside Blurt, optionally one git worktree per item. Agents report
  back over MCP, and "fixed" always means *to verify*. Recordings are organized by the first signed-in agent: Claude
  Code, Codex, Grok, Kimi Code, OpenCode or Gemini CLI.
- Export Markdown/CSV or a hand-off bundle (`.zip`) for a teammate. No built-in connectors: your agent delivers with
  its own tools.

**App shell**
- Onboarding, with a permission helper docked to System Settings that closes itself once access is granted.
- Settings, including one-line agent rows with status.
- Main window, Dictation page and Lab.
- Command palette and project switcher.
- Peep, the new mascot, across the app: Dock icon (paper, with a dark appearance on macOS 26), a native template
  glyph in the menu bar (22 × 18 pt) that talks with your voice level during dictation, listens during the countdown and voice
  notes and thinks while organising, the notch, onboarding, empty states, notifications and the review page. Sprite
  frames come from one Blender model (`assets/brand/import_peep.py`); the old drawing is in `assets/brand/legacy/`.
- The notch island, hanging cards, snap note bubble, recording UI and hand-off panels redesigned as one component
  family (one grid, one toast layout, one project identity), each scored by independent reviewers.
- English and Simplified Chinese throughout.

**Release plumbing**
- Version 1.0.0.
- `scripts/release-mac.sh` builds a Developer ID signed, notarized and stapled DMG locally, with a Sparkle EdDSA
  appcast.
- CI (`.github/workflows/app.yml`) builds and tests and uploads an unsigned artifact. No signing secrets are on GitHub.
- README (en + zh) rewritten, with the Peep logo and the v1 film's poster; `docs/positioning/facts*.md` is the sourced fact sheet.

## How it was tested

- `swift build && swift test`: 675 XCTests, 0 failures.
- `uv run pytest tests -q`: 610 passed, 10 skipped.
- `cd web && pnpm -r test`: all packages pass.
- Layout lint over every screen in en and zh-Hans (`BLURT_GUI_TESTS=1 uv run pytest tests/test_gui_layout.py`):
  nothing reported.
- Dogfood runs in isolated scratch builds (dictation, snaps, voice notes, recordings, review, hand-off) and a visual
  gate with independent judges per screen.
- Manual on a real Mac: Fn dictation switching freely between AirPods, a DJI mic and the built-in mic; card drags
  into WeChat and Feishu.

## Notes for reviewers

- Mic start is now crash-proof when the input changes under a prepared engine (AirPods plus the built-in mic switch).
  `BlurtObjC.BlurtTry` catches AVFoundation's Objective-C exceptions. A configuration change right after the engine
  starts (the built-in mic settling on its own rate while AirPods are the default) restarts the tap and the take goes
  on, instead of ending with nothing heard.
- Review page: undoing a merge no longer leaves the merged text in the item above, and the finish dialog no longer
  pops up after an undo. The e2e suites (Chromium, WebKit, WKWebView) are back in step with the v3 store.
- CI: the app size budget is 30 MB; the Windows and Linux jobs run only when the repo variable `CROSS_PLATFORM_CI` is
  `true`, while those ports are in development.
- Card drags write an event log without any card text (`~/.blurt/logs/card-drag.log`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
