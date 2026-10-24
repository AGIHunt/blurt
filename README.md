<p align="center"><img src="assets/logo.png" width="132" alt="blurt"></p>
<h1 align="center">blurt 🐔</h1>
<p align="center"><b>Show it. Say it. Your AI gets it.</b><br>
Record your screen, think out loud — your coding agent turns it into bug tickets, idea boards and todos.<br>
<a href="https://blurt.agihunt.info/en/">Website</a> · <a href="README.zh-CN.md">中文</a> · works with Claude Code, Codex and any agent that runs skills</p>

https://github.com/user-attachments/assets/334087d3-9b56-48fa-808a-2fb229ab666a

<p align="center"><sub>▶ 80 seconds, sound on 🐔 · made entirely in code — <a href="promo/">source</a></sub></p>

---

**Voice alone is blind. Screenshots plus typing is slow.** The most natural way to tell an AI what you mean is the
way you'd tell a colleague sitting next to you: point at the screen and talk. blurt records exactly that, and
your agent does the rest:

- splits a rambling half hour into separate items, even when you jump between topics and correct yourself
- picks the right frame for each one and boxes the exact spot, using where your mouse actually was. Want it exact?
  **Hold ⌃ and circle it on screen**
- writes it up: actual vs. expected, repro steps, owner, and **the code that's probably responsible**
- lets you triage it one item at a time with the keyboard (in the Blurt app on a Mac, a review page elsewhere)
- files it to Feishu/Lark, GitHub, Linear or Markdown, or goes straight to fixing it

> What used to take two days of screenshots, red boxes and spreadsheet rows is now a 30-minute walkthrough.

## What people blurt

| | |
|---|---|
| 🐞 **Polish a vibe-coded product** | An agent built it overnight; now you walk through every page and rant. You get a clean bug list with code pointers, ready for the agent to fix. That's how you push AI to the finish line. |
| 💡 **Capture ideas while browsing** | "I like how this site does onboarding… and this pricing page…" You get an idea board: each idea, why you had it, where it came from, the next step, plus a one-page digest. |
| 📐 **Browse, then get the spec** | Building a landing page or a store? Tour a few dozen reference sites, circle what you like and say why. Your agent turns it into a requirements doc and a design doc, each requirement next to the frame you circled, ready to build from. |
| 🤝 **Hand off from anyone** | PMs, designers, ops, clients: anyone can record with the Blurt app, no repo needed, and send the video. The developer's agent processes it with the code at hand. |
| 🔎 **Research and walkthroughs** | Competitor tours, UX research, "how this works": you get notes and findings with the frames to prove them. |
| 🖥️ **Not just web apps** | Terminals, TUIs and desktop apps record and get boxed the same way. For phones, use the built-in screen recorder with the mic on; for hardware, film it with your phone. Hand the video to your agent: "process this video". |

One recording can mix all of these. The agent decides what each item is, and teams can add their own
[lenses](skills/blurt/reference/schema.md#custom-lenses) (e.g. `ux-research`, `sales-call`, `sop`).

## Get it

```bash
npx skills add AGIHunt/blurt
```
<sub>Claude Code: <code>/plugin marketplace add AGIHunt/blurt</code> · or just paste this repo's URL to your agent and ask it to install the skill.</sub>

Then, in any project, tell your agent **"start blurt"** / **「开始口喷」**.
The first run picks a speech model for your machine and installs the **Blurt** menu-bar app. Its setup assistant walks
you through the permissions (Screen Recording, Microphone, Accessibility, Input Monitoring); then press `Fn` in any
text field to dictate, or `⌥⇧A` to snap. The [user guide](docs/guide.md) covers the whole app.

## How it feels

1. **Draw the area** to record: drag a region, click a window, or go full screen. Tabs, bookmarks and everything
   else stay out of the video.
2. **3-2-1**, then talk. On a Mac the island at the top of the screen shows the time and the mic level, with pause,
   snap, discard and **Finish**; it is never recorded (Windows and Linux: a small floating bar).
   Shortcuts: `⌥⇧P` pause, `⌥⇧A` snap, `⌥⇧R` or `⌥⇧S` finish (Windows: `Alt+Shift+P` / `A` / `S`).
   When you say "this", **hold `⌃` and drag** to circle or underline it (macOS). The ink fades after 3 seconds, and
   your agent sees exactly what you meant. To keep the pen on, press `⌥⇧D`; while it's on, clicks draw instead of
   reaching your app, and **`Esc`** or `⌥⇧D` again turns it off.
3. Click **Finish** and get back to work. Speech is transcribed locally while you talk, so the transcript is done when
   you stop; your agent writes the items as text and they show up in about a minute (in Blurt's main window on a Mac,
   on the review page elsewhere), with frames and code pointers streaming in while you review.
4. **Triage like a feed**: `A` keep · `X` discard · `J/K` next/prev · `Z` undo · `G` list · `V` overview. Then export,
   or say "fix them".

**Snaps and voice notes:** one screen and one sentence is often all you need. Press `⌥⇧A`, drag an area and let go,
then say what's wrong (or type it, or circle it with `⌃`). With a current project the snap goes straight into it;
on *Auto* it hangs as a **card** under the island until you drag it onto a project or click **Auto-sort**. Cards also
copy and drag into any app — a chat, a terminal, Notes — picture and note together. `⌥⇧V` does the same with just
your voice. Snapping during a recording (`⌥⇧A`) grabs a full-resolution still of that exact moment without pausing.
Use video for flows, animations and timing.

**Always on:** the Blurt app lives in your menu bar. `⌥⇧R` starts a recording from anywhere and `⌥⇧R` again
finishes it; `⌥⇧B` opens the menu. Recordings are filed into your projects (folders you open in Blurt), or kept in
`~/Blurt` when they aren't about one. With *Settings → General → After a recording* set to *Organize into Items*,
every recording gets processed in the background (Claude Code first; if it isn't installed or logged in, Codex, then
Kimi Code, OpenCode or Gemini CLI), and the items land in Blurt's Inbox when they're ready. Every shortcut can be
changed in *Settings → Shortcuts* (`⌘,` in the menu). *Settings → Storage* shows what takes space and can delete the
videos of organized recordings (never by default).

**Dictation (macOS):** tap **Fn** in any app, talk, and tap it again (or hold Fn while you talk). What you said is typed where your
cursor is: a local speech model (Qwen3-ASR on Apple silicon) transcribes it on your Mac, then a small local model (Gemma 4
or Qwen, via MLX) removes fillers and stutters and adds punctuation, in under half a second once it's warm. It never
rewrites, summarizes or translates. If the polish tries to, you get exactly what you said. Press `⇧` while you talk for
the *Structured* style (a list when you listed things, only the version you settled on when you corrected yourself);
`⌥⇧L` reformats the last dictation. `Esc` cancels. You can switch to right Option or to hold-to-talk in
*Settings → Dictation*, and give each kind of app its own style there. Dictation needs Input Monitoring (for the key) and Accessibility (to paste); without
Accessibility the text lands on your clipboard. Everything you dictate is kept in *Dictation History* for 30 days,
and any entry can be turned into an item. The voice note (`⌥⇧V`) still files what you say into Blurt instead.

## Item lifecycle

Every item has **one** state. The two that need you — **New** and **To verify** — make up your Inbox; everything
else is either waiting on someone or finished.

```
New ──keep──▶ To do ──hand off──▶ Handed off ──▶ In progress ──▶ To verify ──mark as done──▶ Done
                ▲                      │              │              │
                ├── take back ─────────┴──────────────┘              │
                └── send back ───────────────────────────────────────┘
```

| State | What it means |
|---|---|
| **New** | Just captured; you haven't looked at it yet. |
| **To do** | You kept it. |
| **Handed off** | Given to an agent: started in Blurt, or an instruction copied to your own agent. |
| **In progress** | The agent is working on it. |
| **To verify** | The agent says it's finished. Check it, then mark it done — or send it back. |
| **Done** | You confirmed it. |
| **Won't do** | You decided not to. Possible from any state that isn't finished; out of your inbox, kept on record. |
| **Discarded** | The trash. Restore puts it back where it was. |

An agent can only move an item to *In progress* or *To verify*: "fixed" means *to verify* until you say it's done.
Click an item's status ring to see what you can do next — only the steps that make sense right now. Keys:
`A` keep · `D` done · `R` back (send back, take back, reopen or restore) · `W` won't do · `X` discard · `S` the menu.
More in the [user guide](docs/guide.md).

## Solo or team

- **Solo:** record → your agent in the same repo processes and fixes. No forms, no copy-paste.
- **Team:** teammates without a repo just [download Blurt for macOS](https://github.com/AGIHunt/blurt/releases/latest)
  (if macOS says it can't check the app the first time: *System Settings → Privacy & Security → Open Anyway*) and
  press `⌥⇧R`. Anyone records with the app, then uses *Recent recordings → Copy video* and pastes it into
  Slack/Feishu. Or bind a shared project folder. Items keep the recorder's name, and exports land in the team's
  existing tables with your column names.

## Under the hood

- **Local-first speech recognition.** [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) via sherpa-onnx is
  about 240 MB, very fast on any CPU, and handles mixed Chinese/English well. Whisper on Apple Silicon or NVIDIA.
  You can also bring your own Groq, OpenAI or DashScope key. By default nothing leaves your machine.
- **Native recorder.** ScreenCaptureKit on macOS with audio and video in sync to within one frame. Turn on system
  audio for calls and demos: it goes on its own track, so the transcript tells your words from the other side's. Tk + ffmpeg on
  Windows and Linux (X11).
- **Deterministic tools, flexible model.** Scripts handle the recording, speech-to-text, frames, the items
  and exports. All the judgement is left to your agent (see [SKILL.md](skills/blurt/SKILL.md)), so it adapts to your
  product, your language and your team.
- **Any language in, same language out.** SenseVoice covers Chinese, English, Japanese, Korean and Cantonese; for
  German, French, Spanish and the rest (99 languages) use Whisper locally or a cloud key. The first run picks one for
  the language you speak, and items come back in that language.

## FAQ

**Does it burn a lot of tokens?** The video is never fed to the model. Speech is transcribed locally (free), the agent
reads the text, and it looks at a few frames only for the moments that become items. A longer recording barely costs
more; silence and clicking around cost nothing. Quality follows the model: use one with
vision, the stronger the better. Three real sessions (Claude Code, Opus 5.5, a production web app):

| recording | speech | items | transcription (local) | new input / output tokens | at API prices |
|---|---|---|---|---|---|
| 7.0 min | 2.8 min | 9 | 4 s | ~142k / ~19k | ~$2 |
| 14.3 min | 12.3 min | 23 | 12 s | ~138k / ~27k | ~$2.6 |
| 20.0 min | 17.7 min | 34 | 15 s | ~122k / ~27k | ~$2.1 |

<sub>Plus cache reads of the ongoing conversation (~3–5M tokens, 1/20 of the input price, included above), which depend
on how long your chat already is. The live drafts written while you record use a small model (Claude Haiku or Codex's
small one) and aren't in the table.</sub>

**How long until I can review?** About a minute after you click Finish; frames stream in while you review. Measured: a
111-second recording (Codex) opened for review after 74 s, with every frame in by 115 s; a real 5-minute, 12-item
session opened in 51 s.

**Does it run on Windows and Linux?** Yes. Recording, local transcription, frames, the review page and exports are
tested step by step on Windows and Linux, and CI runs on both. On Windows your agent starts the recorder, and after
the first recording there's a **Blurt** entry in the Start menu. Linux needs an X11 desktop. The tray app, the pen and
system audio are macOS-only for now. Setup (`doctor.py` tells you what's missing): Windows
`winget install astral-sh.uv` and `winget install Gyan.FFmpeg`; Ubuntu/Debian `sudo apt install ffmpeg libportaudio2 python3-tk`, plus
[uv](https://docs.astral.sh/uv/).

**Which agent processes my recordings?** The first one in *Settings → Agents* that is installed and logged in: by
default Claude Code, then Codex, Kimi Code, OpenCode, Gemini CLI. The list shows each one's state and the command that
fixes it; drag one to the top to try it first. When Blurt falls back it says so ("Claude Code isn't logged in — processing with Codex
this time"), and if a run fails the toast names the reason (login expired, quota / rate limit, network, model, skill
not found); details are in `agent.log` next to the recording. In `~/.blurt/config.json`:

```json
{"record": {"process": "auto", "agents": ["codex", "claude"]},
 "review": {"open_in": "app"}}
```

`agents` lists the ones to use, in order (leave it out for all of them); `review.open_in` is `"app"` (a Blurt window,
the default on macOS) or `"browser"`. `uv run skills/blurt/scripts/agents.py status` prints the same check.

**Can I change the shortcuts?** On macOS: *Settings → Shortcuts* records a new combination per action, turns one off
(⌫), restores the defaults, and warns when a shortcut is already taken (two actions on the same keys, another app,
a macOS system shortcut). The hints on the bar and in the menu follow your keys. The same setting in
`~/.blurt/config.json` also works on Windows (pause, snap, marker, finish):

```json
{"record": {"hotkeys": {"record": "ctrl+opt+R", "snap": "opt+shift+A", "pause": "off"},
            "draw_key": "control"}}
```

Actions: `record`, `menu`, `snap`, `pause`, `marker`, `pen`, `stop`. Modifiers `ctrl`, `opt`/`alt`, `shift`,
`cmd`/`win`; keys A–Z, 0–9, F1–F20, `Space`, arrows, punctuation. `draw_key` (hold to draw): `control`, `option`,
`fn` or `off`.

**I don't do frontend. Is it for me?** Yes, if you can see the problem on screen or film it with a phone. See
*Not just web apps* above.

## Roadmap

Browser capture (console errors and network failures lined up with the video) · the pen on Windows ·
Windows tray app · a hosted speech API · more lenses and exporters · toward a personal assistant that watches,
listens and keeps your projects moving. See [TODO.md](TODO.md).

<p align="center"><sub>MIT · made by <a href="https://github.com/AGIHunt">AGI Hunt</a> · 🐔 if blurt saved you a day, a ⭐ helps others find it</sub></p>
