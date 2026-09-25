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

## Already have a video?

"Turn `~/Desktop/feedback.mov` into issues" works too — any recorder (QuickTime, OBS, Loom, phone).

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

MIT License.
