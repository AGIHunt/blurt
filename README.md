<p align="center"><img src="assets/logo.png" width="132" alt="blurt"></p>
<h1 align="center">blurt 🐔</h1>
<p align="center"><b>Show it. Say it. Your AI gets it.</b><br>
Record your screen, think out loud — your coding agent turns it into bug tickets, idea boards and todos.<br>
<a href="README.zh-CN.md">中文</a> · works with Claude Code, Codex and any agent that runs skills</p>

https://github.com/user-attachments/assets/334087d3-9b56-48fa-808a-2fb229ab666a

<p align="center"><sub>▶ 80 seconds, sound on 🐔 · made entirely in code — <a href="promo/">source</a></sub></p>

---

**Voice alone is blind. Screenshots plus typing is slow.** The most natural way to tell an AI what you mean is the
way you'd tell a colleague sitting next to you: point at the screen and talk. blurt records exactly that, and
your agent does the rest:

- splits a rambling half hour into separate items, even when you jump between topics and correct yourself
- picks the right frame for each one and boxes the exact spot, using where your mouse actually was
- writes it up: actual vs. expected, repro steps, owner, and **the code that's probably responsible**
- lets you triage it in a review page, one item at a time with the keyboard
- files it to Feishu/Lark, GitHub, Linear or Markdown, or goes straight to fixing it

> What used to take two days of screenshots, red boxes and spreadsheet rows is now a 30-minute walkthrough.

## What people blurt

| | |
|---|---|
| 🐞 **Polish a vibe-coded product** | An agent built it overnight; now you walk through every page and rant. You get a clean bug list with code pointers, ready for the agent to fix. This is the fastest way to push AI to the finish line. |
| 💡 **Capture ideas while browsing** | "I like how this site does onboarding… and this pricing page…" You get an idea board: each idea, why you had it, where it came from, the next step, plus a one-page digest. |
| 🤝 **Hand off from anyone** | PMs, designers, ops, clients: anyone can record with the Blurt app, no repo needed, and send the video. The developer's agent processes it with the code at hand. |
| 🔎 **Research and walkthroughs** | Competitor tours, UX research, "how this works": you get notes and findings with the frames to prove them. |

One recording can mix all of these. The agent decides what each item is, and teams can add their own
[lenses](skills/blurt/reference/schema.md#custom-lenses) (e.g. `ux-research`, `sales-call`, `sop`).

## Get it

```bash
npx skills add AGIHunt/blurt
```
<sub>Claude Code: <code>/plugin marketplace add AGIHunt/blurt</code> · or just paste this repo's URL to your agent and ask it to install the skill.</sub>

Then, in any project, tell your agent **"start blurt"** / **「开始口喷」**.
The first run picks a speech model for your machine and installs the **Blurt** menu-bar app.

## How it feels

1. **Draw the area** to record: drag a region, click a window, or go full screen. Tabs, bookmarks and everything
   else stay out of the video.
2. **3-2-1**, then talk. A tiny floating bar shows time and mic level, with ⏸ pause, ↺ redo and **Finish**. The bar
   itself is never recorded. Shortcuts: `⌥⇧P` pause, `⌥⇧S` finish.
3. Click **Finish** and get back to work. Your agent transcribes locally, writes the items, and opens the review page.
4. **Triage like a feed**: `A` keep · `X` drop · `J/K` next/prev · `Z` undo · `G` list · `V` overview. Then export,
   or say "fix them".

**Always on:** the Blurt app lives in your menu bar. `⌥⇧R` starts a recording from anywhere and `⌥⇧R` again
finishes it; `⌥⇧B` opens the menu. Recordings go to a workspace: `~/Blurt` by default, or a project you bind, so
your agent can process them with the code. Turn on *After recording → Claude Code / Codex* and every recording gets
processed in the background, with the review page popping up when it's ready.

## Solo or team

- **Solo:** record → your agent in the same repo processes and fixes. No forms, no copy-paste.
- **Team:** teammates without a repo just [download Blurt for macOS](https://github.com/AGIHunt/blurt/releases/latest)
  (unzip, then right-click → Open the first time) and press `⌥⇧R`. Anyone records with the app, then uses *Recent recordings → Copy video* and pastes it into
  Slack/Feishu. Or bind a shared project folder. Items keep the recorder's name, and exports land in the team's
  existing tables with your column names.

## Under the hood

- **Local-first speech recognition.** [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) via sherpa-onnx is
  about 240 MB, very fast on any CPU, and handles mixed Chinese/English well. Whisper on Apple Silicon or NVIDIA.
  You can also bring your own Groq, OpenAI or DashScope key. By default nothing leaves your machine.
- **Native recorder.** ScreenCaptureKit on macOS with audio and video in sync to within one frame. Tk + ffmpeg on
  Windows.
- **Deterministic tools, flexible model.** Scripts handle the recording, speech-to-text, frames, the review page
  and exports. All the judgement is left to your agent (see [SKILL.md](skills/blurt/SKILL.md)), so it adapts to your
  product, your language and your team.
- **Any language in, same language out.** Speak Chinese, English, Japanese…; the items come back in your language.

## Roadmap

Browser capture (console errors and network failures lined up with the video) · circle-to-highlight gestures ·
Windows tray app · a hosted speech API · more lenses and exporters · toward a personal assistant that watches,
listens and keeps your projects moving. See [TODO.md](TODO.md).

<p align="center"><sub>MIT · made by <a href="https://github.com/AGIHunt">AGI Hunt</a> · 🐔 if blurt saved you a day, a ⭐ helps others find it</sub></p>
