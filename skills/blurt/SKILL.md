---
name: blurt
description: >-
  Turn a narrated screen recording into a clean list of bug/feedback issues (title, module, owner, actual vs
  expected, repro steps, screenshots, clips, suspected code) and export them to Feishu/Lark Bitable, CSV/Markdown,
  GitHub Issues or wherever the user wants. Use when the user wants to record feedback / QA / polish notes by talking
  while using their app, hands over such a video, or wants to process recordings made with the Blurt app.
  Triggers: "blurt", "/blurt", "start blurt", "开始吐槽", "吐槽鸡", "开始录反馈", "录屏提 bug", "record feedback",
  "turn this recording into issues", "处理我录的视频", "process my recordings".
---

# blurt 🐔 — say it while you use it, get tickets

The user demos their product and rants out loud — jumping between modules, correcting themselves, pointing at
things. Your job: capture that cheaply, then do the tedious part (splitting, writing, screenshotting, filing)
with care. Optimise for the user's flow: never interrupt a recording, ask few questions, and make review fast.

Scripts live in `scripts/` next to this file; run them with `uv run <skill-dir>/scripts/<name>.py ...`
(each declares its own deps; `uv` installs them on first use). Every script has `--help`.
Always reply in the user's language; write issue content in the language the user spoke.

## 0. Setup (first run, or when something fails)

- `doctor.py` → JSON report: OS, RAM/GPU, ffmpeg, configured ASR, recommendations, `todo` list.
- Missing ffmpeg/uv: offer the install command; run it only after the user agrees.
- ASR: if none configured, pick using `asr_recommendations` + the language the user speaks, tell the user in one
  line what you picked and why (size, local vs cloud, cost), then run the `setup` command. Details:
  `reference/asr.md`. Keys for cloud ASR must be set by the user in their env — never ask them to paste keys in chat.
- Recorder: on first setup run `record.py build` — on macOS it compiles the native recorder (needs Xcode Command
  Line Tools, else a Tk fallback is used) and installs the standalone **Blurt** app into ~/Applications; on Windows
  the Start-menu shortcut is created on first recording. Mention it to the user in one line.
- Recording check: `record.py test` → look at the returned `frame` image yourself. Wallpaper-only/black frame or
  `ok: false` ⇒ Screen Recording permission missing; `mic_silent: true` ⇒ Microphone permission / wrong mic.
  On macOS the permission belongs to the app hosting you (Terminal, iTerm, VS Code, Claude, Codex…), and that app
  must be restarted after granting. macOS 15+ may also show a one-off "allow … to bypass the window picker"
  prompt — the user must click Allow themselves. `record.py devices` lists screens/mics; persist a choice in
  `~/.blurt/config.json` (`{"record": {"mic": "<name>", "screen": <idx>}}`).
- Project config (optional) `.blurt/config.json` in the repo: export target, owners/module map, column mapping.
  Suggest adding `.blurt/sessions/` to `.gitignore`.

## 1. Record

1. If the app under test is a local dev server/app in this repo, check it is running (start it if the user wants).
2. Start **in the background**: `record.py start` (add `--last-region` if the user wants the same area as last
   time). Then tell the user, briefly, what happens next and end your turn:
   - a dimmed overlay appears: drag to select the area to record (or click a window, F = full screen) → **开始录制**;
     only that area is recorded — tabs, bookmarks, other windows stay private;
   - 3-2-1 countdown (click to skip), then a small floating bar: timer · mic level · ⏸ pause · ↺ restart/discard ·
     **完成**. Shortcuts: ⌥⇧P pause/resume, ⌥⇧S finish (Windows: Alt+Shift). The bar is never in the recording;
   - talk naturally — what's wrong, what they expected, who should own it; point with the mouse;
   - click **完成** when done. No need to come back to the chat — you'll be notified.
3. The background task ends with `DONE video=…` (or `CANCELLED`, exit 2 → acknowledge and stop). Continue with §2.
   From the chat you can also `record.py stop | pause | resume | restart`.

Existing videos: if the user hands over a file (QuickTime, OBS, Loom, phone…), create
`.blurt/sessions/<timestamp>/`, copy/link it in as `recording.<ext>`, and continue with §2.

Standalone recordings: the user can record without you via the Blurt app (installed automatically in
~/Applications / the Start menu; `record.py install-app` reinstalls it). Recordings land in `~/Movies/Blurt/<timestamp>/` (Windows: `~/Videos/Blurt`).
`record.py inbox` lists them with `processed` flags. To process several: run §2–§4 per recording (fan out to
subagents if available), then review them together — one `review.py` per session, or merge into one session
directory when the user wants a single list — and export once.

## 2. Transcribe

`transcribe.py run <session>/recording.mp4` → `transcript.json` + `transcript.txt` (`[mm:ss.s-mm:ss.s] text`).
For Whisper/API backends pass `--prompt` with a short glossary (product name, module/page names, people named in
the project) — gather it from the repo (routes, nav labels, i18n files, CODEOWNERS). Also start
`frames.py scan <video>` now (visual-activity index; used by candidates/sheet).

## 3. Understand → issues

Read the whole transcript first. Then produce `<session>/issues.json` (schema: `reference/schema.md`).
Principles — use judgement, these are not rules:
- One issue = one thing to fix. People jump around, come back to an earlier point, correct themselves
  ("不对，是…"), or say two things in one sentence. Merge revisits, drop retracted remarks, split compounds.
- Fix ASR errors using context (the repo's vocabulary, what's on screen). Keep `quote` close to what was said.
- Fill `actual` / `expected` / `steps` from speech + what the frames show. Don't invent; when something is
  genuinely unclear, write your best guess, set `confidence: "low"` and add a short `questions` entry.
- `module`: use the product's own names (nav labels, routes). `owner`: whoever the user named; otherwise infer
  from project config / CODEOWNERS / git history of the suspected files, or leave empty.
- `code_refs` (the killer feature — you are inside the repo): for each issue, grep for the visible text/route/
  component and list the most likely `path:line`s. Keep it quick; skip if nothing credible.
- Positive remarks or ideas are fine as `type: "idea"`; pure narration ("ok, next page") is not an issue.

## 4. Evidence: frames & clips

For each issue, pick 1–3 frames that show the problem, not just the page:
- `frames.py sheet <video> --from S --to E -o <session>/sheets/<id>.jpg` shows ~6 diverse, settled candidates
  with timestamps in ONE image — look at it, pick the best time(s). `--at t1 t2 …` to inspect specific moments
  (e.g. when the user said "这里 / this / look"). Speech often trails the action, so glance a few seconds before S.
- `frames.py grab <video> --at T -o <session>/frames/<id>-1.jpg --box x,y,w,h` (fractions 0–1) outlines the spot
  in red; add a `--crop` second frame when the detail is tiny. The cursor is visible in the recording — use it.
- Animations / flows / timing bugs: add `frames.py clip --from --to -o <session>/clips/<id>.mp4` (keep < 20MB).
- Many issues (> ~12)? If your harness has subagents, fan out frame selection in batches, one issue list each.

## 5. Review with the user

- ≤ 5 issues: show a compact numbered list in chat (title · module · owner, plus any `questions`) and ask for
  corrections in one message.
- More: run `review.py <session>` **in the background** — it opens a local review page and exits when the user
  finishes. Tell the user in two lines: one issue at a time, **A** keep · **X** drop · **J/K** next/prev ·
  **Z** undo · **?** all shortcuts; fields are editable in place, there's a list view (G), and "完成审核" hands it
  back. End your turn, then reload `issues.json` when it finishes (dropped issues have `status: "deleted"`;
  answers to `questions` are in `answer`).
Apply corrections the user gives in chat directly to `issues.json`.

## 6. Export

Ask once where issues should go (then remember it in `.blurt/config.json` → `export`). Guides in `reference/`:
- Feishu/Lark Bitable → `feishu.py export <session> "<table url>"` (uses `lark-cli` if installed, else app
  credentials; maps to the classic bug-sheet columns, creates missing ones, uploads frames + clips, resumable).
  No table yet → `feishu.py create "<name>"`. Existing table with other columns → `feishu.py fields` then `--map`.
  Details: `reference/export-feishu.md`.
- CSV + Markdown → `export_local.py <session>` (always cheap; good as a local record too).
- GitHub Issues / Linear / Jira / Notion / anything else → `reference/export-other.md`; use whatever CLI or MCP
  tool the user already has. Map fields semantically to the destination's existing columns.
Before creating anything in an external system, confirm the destination and count with the user. Afterwards,
report links and offer the natural next step: "want me to start fixing these?" (you already have code_refs).
