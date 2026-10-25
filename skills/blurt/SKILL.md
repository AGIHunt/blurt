---
name: blurt
description: >-
  Screen + voice → structured work. The user records their screen while talking (demoing their product, browsing,
  exploring an idea); turn the recording into items — bug/polish issues with repro steps, frames and suspected code,
  ideas with the inspiration behind them, notes, todos — let them review on a local page, then export (Feishu/Lark
  Bitable, CSV/Markdown, GitHub Issues…) or start fixing. Use when the user wants to record feedback / QA / ideas by
  talking while using their screen, hands over such a video, or wants to process recordings from the Blurt app.
  Triggers: "blurt", "/blurt", "开始口喷", "口喷鸡", "开始录", "录屏提 bug", "录一下我的想法", "record feedback",
  "turn this recording into issues", "处理我录的视频", "process my recordings".
---

# blurt — show it, say it, get structured work back

People think best out loud with their eyes on the screen. They jump between topics, correct themselves, point at
things. Your job: capture that with no friction, then do the tedious part (splitting, writing up, picking and
marking screenshots, finding the code, filing) with care. Optimise for the user's flow: never interrupt a
recording, ask few questions, make review fast.

Scripts live in `scripts/` next to this file; run them with `uv run <skill-dir>/scripts/<name>.py ...` (each
declares its deps; `uv` installs them on first use). Every script has `--help`. Always reply in the user's
language; write items in the language the user spoke.

## 0. Setup (first run, or when something fails)

- `doctor.py` → OS, RAM/GPU, ffmpeg, configured ASR, recommendations, `todo` list.
- Missing ffmpeg/uv: offer the install command; run it only after the user agrees.
- ASR: if none configured, pick from `asr_recommendations` + the language the user speaks, tell the user in one
  line what and why (size, local vs cloud, cost), run its `setup`. Details: `reference/asr.md`. Cloud keys are set
  by the user in their env — never ask them to paste keys in chat.
- `record.py build` — macOS: compiles the native recorder (Xcode Command Line Tools; else a Tk fallback) and
  installs the **Blurt** menu-bar app into ~/Applications. Windows: the Start-menu shortcut appears on first
  recording. Mention it in one line: "Blurt is also in your Applications — ⌥⇧R records from anywhere".
- `record.py test` → look at the returned `frame` yourself. Wallpaper-only/black or `ok: false` ⇒ Screen Recording
  permission missing; `mic_silent: true` ⇒ Microphone permission / wrong mic. On macOS the permission belongs to the
  app hosting you (Terminal, iTerm, VS Code, Claude, Codex…) and that app must be restarted after granting.
  macOS 15+ may show an "allow … to bypass the window picker" prompt — the user clicks Allow themselves.
- Optional project config `.blurt/config.json`: export target, owners/module map, column mapping, custom lenses in
  `.blurt/lenses/`. `.blurt/` is never committed: items.py / projects.py add it to `.git/info/exclude` (not
  `.gitignore`) the first time they write there.

## 1. Record (or pick up a recording)

**From the chat:** if the thing to look at is a local dev server/app in this repo, check it is running. Start
`record.py start` **in the background** (`--last-region` to reuse the last area) and tell the user in a few lines
what happens:
- a dimmed overlay: drag to draw the area (or click a window, F = full screen) → **开始录制** / Enter. Only that area
  is recorded — tabs, bookmarks and other windows stay private;
- 3-2-1 countdown (click to skip), then a small floating bar: timer · mic level · ⏸ pause · ↺ restart/discard ·
  **完成**. ⌥⇧P pause/resume, ⌥⇧S finish (Windows: Alt+Shift; these are the defaults — the user may have changed
  them in the app's Settings → Shortcuts / config `record.hotkeys`, and the countdown shows the real ones). The bar is
  never in the recording;
- talk naturally, point with the mouse; **hold ⌃ and drag to circle / underline what you mean** (macOS; ⌃⇧ box,
  ⌃⌥ ellipse — ⌃ first, then the other key — resting the pointer straightens a rough shape — a snap's markup uses the same strokes; the ink fades after 3 s; the pen button on the bar or ⌥⇧D keeps the pen on, Esc / ⌥⇧D turns it off); click **完成** — no need
  to send another chat message.
- **⌥⇧A snaps** (Windows/Linux Alt+Shift+A, or the camera button on the bar; ⌥⇧M too): a full-resolution still of
  the area right now, no pause → `shots/`. Best evidence there is — mention it in one line.
The task ends with `DONE video=…` → continue with §2 right away (`CANCELLED`, exit 2 → acknowledge and stop). From
the chat you can also `record.py stop | pause | resume | restart | snap`.

**Snap mode** (macOS app, not recording): ⌥⇧A → drag an area, let go = shot, with a spoken (or typed) note; ⌃-drag on
it circles things. With a current project the shot goes straight to it; in auto mode it waits as a card until the
user files it (or lets AI sort). The batch is `<ts>-shots/` (`meta.json` `"mode": "shots"`, no video; a line of
`shots.jsonl` may carry the `project` the user filed it into). Suggest it for "one screen + one sentence"
feedback (a wrong label, a layout glitch): faster to give and to process. Video is for flows, animations, timing and
long rambles — anything where what happened *between* screens matters.

**Waiting on a background step** (here and in §5): if your harness wakes you when a background task finishes (Claude
Code), end your turn — you'll be notified. If it doesn't (Codex), a finished turn can't be resumed by the child
process: keep the turn open and wait on that same tool session with long polls (no busy loop); don't send a final
response while it runs.

**Existing video** (QuickTime, OBS, Loom, phone, a teammate's Blurt recording…): create
`.blurt/sessions/<timestamp>/`, copy it in as `recording.<ext>` (with `events.jsonl` / `meta.json` if it came from
Blurt), continue with §2.

**Projects and the inbox.** A project is a folder the user opened in Blurt (`projects.py list`: id, key such as `BA`,
name, description, modules). Each has a store `<folder>/.blurt/`: items in `items/<KEY-n>-<slug>.md`, screenshots in
`assets/<uid>/`, raw captures in `sessions/<ts>/`. Captures that belong to no project yet live in the inbox store
`~/Blurt/inbox/` (shown as "Unassigned"). The user picks a current project, or "auto" (`projects.py current`).

**Blurt app recordings:** the menu-bar app records into the current project's store, or the inbox in auto mode.
`record.py inbox` lists them all with `processed` / `reviewed` flags (v0.6 recordings in `~/Blurt/recordings/` too).
"Process my recordings" → do §2–§4 for each unprocessed one (fan out to subagents if available), then one review per
session (or merge into one session dir if the user wants a single list). `meta.json` has `author` — keep it on items
when several people's recordings are combined.

## 2. Transcribe

`transcribe.py run <session>/recording.mp4` → `transcript.json` + `transcript.txt` (`[mm:ss.s-mm:ss.s] text`).
Recordings made with Blurt are usually transcribed *while* they record (`live/`): then it returns at once with
`"live": true` — same text as a whole-file run; `--force` redoes it (e.g. with a `--prompt` glossary). A shots
session (`meta.json` `"mode": "shots"`): `transcribe.py run <session>` turns each voice note into `"said"` in
`shots.jsonl`. `live/drafts.jsonl` (if present; later lines per `id` win, `drop` removes) is a small model's rough
outline made during the recording: a starting point for §3, not authoritative — check every item against the
transcript.
Recorded with system audio (`record.py start --system-audio`, or the app's Settings → General toggle — calls, product demos),
the other side's lines are marked `(system)` / `speaker: "system"`; unmarked lines are the user. Speaker bleed can
repeat a system line on the mic.
For Whisper/API backends pass `--prompt` with a short glossary (product, page/module names, people) from the repo.
Also run `frames.py scan <video>` (visual-activity index for candidates/sheets) and `frames.py marks <video>`: what
the user drew with the pen — when, where (box), what was being said — plus ⌥⇧M markers.
A `warning` in the output, or a transcript that reads as nonsense (SenseVoice turns unsupported languages such as
French into fake English), means the language needs another backend: set it up (`reference/asr.md`) and re-run.

## 3. Understand → items (text first), open the review page

The user is waiting: write the items as text, open the page, add frames while they read (§4). Read the whole
transcript. `live/drafts.jsonl` (items drafted during the recording; last line per `id` wins, `op: drop`
= gone) is your outline if it exists: check each draft against the transcript, merge / split / drop freely. Look at
frames now only when the words alone can't tell what an item is about. Decide **per item** what it is — the
recording decides, not a mode switch:

| kind | when | lens |
|---|---|---|
| `issue` | something in the product to fix or polish | `reference/lenses/issue.md` |
| `idea` | something to build / change / borrow ("这个网站的这里好") | `reference/lenses/idea.md` |
| `note` | an observation / finding / fact worth keeping | `reference/lenses/note.md` |
| `task` | an action item that isn't a product issue | `reference/lenses/task.md` |
| custom | a lens in `.blurt/lenses/` or `~/.blurt/lenses/` fits, or the user asked for it | that file |

Principles — judgement, not rules:
- A pen mark or a snap (screenshot in `shots.jsonl`) is the user saying "this, exactly": it anchors an item's time
  and subject. What they marked outranks your reading of a vague sentence — but a mark is not an item by itself,
  and items without marks are normal. A snap's image is its item's first frame: put it in `frames` right away.
- One item = one thing. People jump around, revisit, correct themselves ("不对，是…"), or say two things in one
  sentence: merge revisits, drop retracted remarks, split compounds. Pure narration is not an item.
- Fix ASR errors from context (repo vocabulary, what's on screen). Keep `quote` close to what was said.
- Don't invent. When unsure, write your best guess, set `confidence: "low"`, add a short `questions` entry.
- Give the session a `title`. For idea-heavy or exploratory recordings a `digest` (markdown: themes, the strongest
  ideas, how they connect, suggested next step) becomes the page's Overview — it can follow in §4.

**Which project** (only when the session is in the inbox — auto mode — and `projects.py list` has projects): for
each item propose `"project": "<id or key>"` with `"project_confidence": 0–1` and a few words in `"project_reason"`.
Evidence, strongest first: `code_refs` that exist in one project's folder, the source URL / app (the project's
`hints`), a module name, the project's description. 0.75 or more files the item there; below that it stays in
Unassigned with your suggestion for the user to accept. Unsure → leave `project` out; Blurt routes those itself.

Write `<session>/items.json` (schema: `reference/schema.md`) with `"processing": true` and every item's text, no
picked frames yet — but a snap's shot goes in its item's `frames` now (nothing to pick). Then `items.py ingest
<session>` turns it into one Markdown item per entry (any later `items.py` command on the session does it too).
**Right away** start `review.py <session>` **in the background** (on macOS it opens in the Blurt app's main window when
the app is installed, else the browser; exits when the user confirms — in either — or after 30 minutes nobody used
the page, `"reviewed": false` then; prints `REVIEW <url>`, a private local address with a token in it — give the user
that URL if no browser can open where you run: SSH, container) and tell the user in one short message:
- ≤ 5 items: the numbered list (kind · title · owner/module, plus `questions`); more: counts by kind, the headline
  items, open questions; screenshots are still filling in;
- two lines on the page: one item at a time — **A** keep · **X** drop · **J/K** next/prev · **Z** undo · **?** keys;
  fields editable in place; **G** list view; **V** overview; "完成审核" hands it back.

From here on the user edits the same items: change them **only** with `items.py` (`patch`, `set-frames`, `add`,
`done`; `--help`). Address an item as `<session> I-003` (your draft id), by its id (`BA-12`) or by its uid. It keeps
fields the user edited, and items they dropped or merged stay gone — never write items.json again, nor the `.md`
files.

## 4. Evidence: frames & clips (while the user reviews)

Pick 1–3 frames per item that show *the point* (the bug itself, the part of the page that inspired the idea). Work
top-down — the user reviews from the top — and write each item as soon as its frames are good:
`items.py set-frames <session> <id> frames/<id>-1.jpg@T#caption …`.
- `frames.py sheet <video> --from S --to E -o <session>/sheets/<id>.jpg` → ~6 diverse settled candidates with
  timestamps in one image; `--at t1 t2 …` for specific moments ("这里 / this / look"). Speech often trails the action.
- The user drew on it (`marks`)? Their ink is in the video: `frames.py grab --at <frame_t>` and the frame is already
  annotated — add no box. `--crop stroke` for a zoomed second frame; `--box stroke` on a frame where the ink is gone.
- Otherwise, marking the spot — never estimate coordinates from a thumbnail or contact sheet:
  1. `frames.py grid <video> --at T -o <session>/sheets/<id>-grid.jpg` → labelled 0–1 grid plus the recorded cursor
     and nearby clicks (events.jsonl — exact). Read box edges off the grid (`--crop` zooms, labels stay full-frame).
  2. `frames.py grab <video> --at T -o <session>/frames/<id>-1.jpg --box x,y,w,h`; `--ring cursor|click` when the user
     pointed at / clicked it. Tiny detail → second frame with `--crop`.
  3. **Look at every annotated frame before using it.** Box not on the point → fix and re-grab.
- **Shots** (`shots.jsonl`; later lines per `n` win; skip `"deleted": true`): the shot *is* the frame — use
  `shots/NNN.marked.png` when it exists (the user's ink is already on it, add no box), else `NNN.png`; no picking.
  Its note is `text` / `said` (voice) — plus, for a snap while recording, what was said around its `t`. `frames.py
  grab|grid shots/NNN.png` work on stills (`--crop stroke` = around their ink; `--ring cursor` for snaps while
  recording); `frames.py marks <video or session>` lists every snap.
- Animations / flows / timing: `frames.py clip --from --to -o <session>/clips/<id>.mp4` (< 20 MB) → `patch --set clip=…`.
- Same pass, via `items.py patch`: `source` (URL / product read off the frame), `code_refs` (issues, inside a repo:
  grep the visible text / route / component → likely `path:line`s), the `digest`, a better `confidence`.
- **Fan out** if your harness has subagents: split the items into 3–4 contiguous batches and run them all at once.
  Each gets the session dir, the video, its items (id, kind, title, time, quote, the marks / snaps that anchor them),
  this section, and the rule: write only your items, only with `items.py`. They report nothing back.
- Then `items.py done <session>` (it lists items still without frames — fine where none would help).
  `set-frames` copies the files into the store (`assets/<uid>/`): keep giving paths relative to the session.

## 5. Review with the user

The page has been open since §3. Wait as in §1 until the review summary prints. The user may finish before the
frames are in (`"processing": true` in the summary): complete §4 anyway, then `done`. Read the result with
`items.py list <session>` (each item has one `state`: `todo` = they kept it, `wontfix`, …; `--state discarded` for
what they threw away; answers are in `answer`; merged items are gone
on purpose — see the target's `merged_from`; `_user` lists fields the user edited; the user may have moved items to
another project: ids follow the project, uids never change) and continue with §6. If they reply in chat instead,
apply it with `items.py … --force` and close the page (`pkill -f "review.py <session>"`).

**Unattended runs** (started by the Blurt app via the first usable agent CLI — `claude -p`, `codex exec`,
`kimi -p`, `opencode run`, `gemini -p` (scripts/agents.json) — env `BLURT_APP=1` — or any other
non-interactive mode): don't ask anything; do §2–§4 the same way (text first with `processing`, frames via
`items.py`, `done`), then finish with a 2–3 sentence summary. The app's runs are sandboxed: the cwd is the session
folder, the project's code (named in the prompt) is for reading, and the only commands allowed are the scripts as
`uv run <skill-dir>/scripts/<name>.py …` with the path the prompt gives. With `BLURT_APP=1` don't start the review page — the
app opens it; otherwise start it detached right after §3 (`nohup uv run …/review.py <session> >/dev/null 2>&1 &`).
Never export to external systems unattended.

## 6. Export / act

Ask once where things go (remember in `.blurt/config.json` → `export`). Typical: issues → the team's bug table;
ideas → an ideas board / doc; notes → Markdown; tasks → the user's todo tool.
- Feishu/Lark Bitable → `feishu.py export <session> "<table url>" [--kind issue|idea|…]` (`--project <key>` for a
  whole project; lark-cli if installed,
  else app credentials; default columns per kind, creates missing ones, uploads frames + clips, resumable).
  No table yet → `feishu.py create "<name>"`. Other columns → `feishu.py fields` then `--map`.
  Details: `reference/export-feishu.md`.
- Markdown + CSV → `export_local.py <session>` or `export_local.py --project <key>` (all kinds: one document and a
  CSV per kind; the items themselves are Markdown files already).
- GitHub Issues / Linear / Jira / Notion / Obsidian / anything else → `reference/export-other.md`; use the CLI or
  MCP tool the user has; map fields by meaning.
- A document rather than a list ("整理成需求文档和设计文档", a brief, a comparison — typically after walking through
  reference sites or a competitor, often across several recordings) → `reference/docs.md`.
Confirm destination and count before creating anything remotely; report links afterwards. Then offer the natural
next step — for issues "want me to start fixing these?" (you have `code_refs`), for ideas "want a quick prototype /
spec of the top one?".

## 7. Work on items (and say so)

When the user asks you to handle items — "fix these", a Blurt session that started you, a handoff file
(`~/.blurt/handoff/H-….md`, see `reference/sessions.md`) — for each item:
1. Read it in full: MCP `get_item(uid)` (shows the screenshots), or `items.py get <uid|id>` and open the frame files
   (absolute paths). Look at the frames; they are the evidence.
2. `items.py state <uid> --state in_progress` (MCP: `mark_fixed(uid, state="fixing")`) before you start — the app
   shows it in progress.
3. Do it, smallest change that does it. Commit only when the handoff says so (a worktree session); never push.
4. `items.py state <uid> --state to_verify --claim fixed --note "<one line: what changed, which files>"`
   (`--commit SHA` / `--pr URL` if there is one; MCP: `mark_fixed(uid, state="fixed", note=…)`); can't or shouldn't →
   `--claim wontfix --note "<why>"`. That is your claim: the item waits in the user's inbox as *to verify* — only
   they mark it done, send it back or decide they won't do it.
Every item has one `state` (`reference/schema.md`): new → todo → handed_off → in_progress → to_verify → done, plus
wontfix and discarded. You only ever move items to `in_progress` / `to_verify` (or back to `todo` to take your own
claim back). `--agent` / `--job` default to `$BLURT_AGENT` / `$BLURT_JOB` (set by the app). The older forms
`items.py work …` and `items.py fix <session> <id> --state fixing|fixed|wontfix` still work. Never set `state` or
`work` with `patch`, and never edit item files yourself.

## 8. Across recordings: index and MCP

Every item on this machine (every project's store, the inbox, v0.6 sessions not migrated yet) is indexed in
`~/.blurt/index.db` (`index.py`; items.py keeps it fresh). To find things across projects:
`index.py search "<words>" [--kind issue] [--state todo] [--project <key|folder|inbox>]` → items with uid, id,
project, path, title, state (Chinese works; 1–2 character words too). `index.py backlog <repo>` writes
`.blurt/BACKLOG.md` with the open items. `items.py migrate --all` moves v0.6 sessions into the stores (the app does
it on start).

The same data as MCP tools — server `blurt` (`uv run --script scripts/mcp_server.py`, stdio): `list_projects`,
`list_sessions`, `search_items`, `get_item` (returns the screenshots as images), `get_transcript`, `update_item`
(= `items.py patch`, keeps the user's edits), `mark_fixed` (fixing → in progress; fixed / wontfix → to verify). The
plugin registers it for Claude Code; for Codex / Kimi / OpenCode: `agents.py install <id> --mcp` (`--dry-run` first
shows what changes). Prefer the tools when they are there; they write through items.py like everything else.

Agent sessions inside Blurt (tmux), worktrees, handoff files and the jobs the app shows: `reference/sessions.md`.
