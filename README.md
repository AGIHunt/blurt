<p align="center"><img src="assets/logo.png" width="140" alt="blurt 吐槽鸡"></p>
<h1 align="center">blurt 🐔 吐槽鸡</h1>
<p align="center"><b>Just blurt it. Your agent files the bugs.</b><br>
Record your screen, rant out loud, get clean tickets. · <a href="README.zh-CN.md">中文</a></p>

---

Polishing an AI-built product means hundreds of small notes. Writing each one up — screenshot, red box,
"expected vs actual", repro steps, owner — caps you at 10–20 an hour. **blurt** flips it: you use the app and
talk, like you would to a colleague sitting next to you. Jump between modules, change your mind, point with the
mouse. Your coding agent (Claude Code, Codex, …) turns the recording into a reviewed issue list with
screenshots, clips and **suspected code locations**, then files it to Feishu/Lark Bitable, CSV, GitHub…

```
you: /blurt                       🐔 checks env → starts recording
you: (use the app, talk for 30 min)
you: done
🐔: transcribes locally → splits into issues → picks & marks frames → finds code
🐔: opens a review page (or lists them in chat) → you tweak → exports
```

## Why it's different

- **One recording → many issues.** Topic-jumping, corrections, and revisits are handled by the model.
- **Runs inside your repo.** Every issue gets `code_refs` — the fix is one prompt away.
- **Local-first ASR.** SenseVoice via sherpa-onnx (~240 MB, fast on any CPU, great zh/en code-switching);
  Whisper on Apple Silicon / NVIDIA; or your own Groq/OpenAI/DashScope key. Nothing leaves your machine by default.
- **Language-agnostic.** Speak any language; issues come out in it.
- **Agent-native.** Deterministic work (recording, ASR, frames) is in scripts; judgement is left to the model.

## Install

Requirements: macOS or Windows, [`uv`](https://docs.astral.sh/uv/), `ffmpeg`.

**Claude Code**
```
/plugin marketplace add AGIHunt/blurt
/plugin install blurt@blurt
```
**Codex / other agents** — copy `skills/blurt` into your agent's skills folder (e.g. `~/.codex/skills/blurt`,
`~/.claude/skills/blurt`), or `npx skills add AGIHunt/blurt`.

Then in your project: say **"/blurt"** or **"开始吐槽"**. First run sets up ASR (asks before downloading) and
checks screen/mic permissions (macOS: grant *Screen Recording* + *Microphone* to the app running your agent).

## Recording that stays out of your way

- **Pick exactly what's recorded** — drag an area, click a window, or full screen. Tabs, bookmarks and other
  windows stay private. The last area is remembered.
- **3-2-1 countdown** (click to skip), then a tiny floating bar: timer · mic level · ⏸ pause · ↺ restart ·
  **Finish**. `⌥⇧P` pause/resume, `⌥⇧S` finish (Windows: `Alt+Shift`). The bar is never in the video.
- **Finish on the bar** — your agent is notified and starts processing; no need to switch back to the chat.
- Native ScreenCaptureKit recorder on macOS (built locally on first use); Tk + ffmpeg on Windows.

## Record now, process later

The first time blurt records, it also installs a standalone **Blurt** app (Applications on macOS, Start menu on
Windows) — nothing extra to do. Record whenever (or hand the app to a teammate); videos land in `~/Movies/Blurt`. Later, tell your agent
"process my blurt recordings" and it works through the inbox in one go.

Already have a video from QuickTime, OBS, Loom or a phone? "Turn `~/Desktop/feedback.mov` into issues" works too.

## Review like triage, not like a form

One issue at a time, full-screen evidence on the left, editable fields on the right: `A` keep, `X` drop, `J/K`
next/prev, `Z` undo, `M` merge into previous, `1/2/3` severity, `Space` play the clip, `O` jump to that moment in
the recording. Or switch to a list with `G`.

## Pieces

| script | does |
|---|---|
| `doctor.py` | environment check + ASR recommendation for this machine |
| `record.py` | ffmpeg screen + mic capture (macOS avfoundation, Windows ddagrab/gdigrab) |
| `transcribe.py` | VAD → local/cloud ASR → timestamped transcript |
| `frames.py` | activity scan, candidate frames, contact sheets, red boxes, clips |
| `review.py` | local review page; blocks until you confirm |
| `export_local.py` / `feishu.py` | Markdown + CSV / Feishu Bitable |

Roadmap: cursor-trajectory capture, on-screen annotation overlay, browser console/network capture — see [TODO.md](TODO.md).

## Development checks

With Python 3.10+ installed, run from the repository root:

```sh
python -m compileall -q skills/blurt/scripts tests
python -m unittest discover -s tests -v
```

GitHub Actions runs these checks on Linux, macOS and Windows with Python 3.10 and 3.14 for pushes and pull
requests. The tests cover local Markdown/CSV export using temporary fixtures and the Python standard library;
they need no API keys, `ffmpeg` or ASR models. Recording, transcription and native UI still need manual testing.

MIT License.
