<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="assets/peep-readme-dark.png"><img src="assets/peep-readme.png" width="132" alt="Blurt"></picture></p>
<h1 align="center">Blurt</h1>
<p align="center"><b>The keyboard for the agent era.</b><br>
Tell your agents what you want by voice, screenshot and screen recording. Runs locally. Free and open source.<br>
<a href="https://blurt.work/en/">Website</a> · <a href="README.zh-CN.md">中文</a> · <a href="docs/guide.md">User guide</a> · <a href="#community">WeChat group</a></p>

<p align="center"><a href="https://blurt.work/en/#film"><img src="assets/film-poster.jpg" width="720" alt="Watch the 2-minute film"></a></p>
<p align="center"><sub>Watch the 2-minute film, sound on · <a href="https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg">Download for Mac</a></sub></p>

---

Blurt works with the agents you already use, like Claude Code, Codex, Cursor, Claude and ChatGPT. It gets what you say, see and record into
their input box. It isn't an agent and doesn't replace yours.

The Mac app does the most. Blurt also runs on Windows, Linux, iPhone, iPad and Android.

## What it does

| | Key | |
|---|---|---|
| **Dictation** | `Fn` | Tap it in any app, talk, and tap again. The words are typed at the cursor, and a double tap sends them too. Filler words are removed and punctuation added; your words aren't rewritten. While talking, double-tap `⇧` for a list or `⌘` to translate. |
| **Snap** | `⌥A` | Drag over part of the screen, say what's wrong, and draw on it if you like. The snap becomes a card. Drag it into an agent, a chat or a terminal, and the picture goes in with your words. |
| **Voice Note** | `⌥V` | A snap without the picture. |
| **Copy Text from Screen** | `⌥C` | Drag over text you can't select in a screenshot, a video, a page or a terminal. In about 0.2 s it's on the clipboard and pasted into the app in front, with lists, tables and code indentation as they were. |
| **Translate Text from Screen** | `⌥T` | The same drag. The text is translated, then pasted or copied. |
| **Record** | `⌥R` | Talk while you use your product. Your agent turns the recording into items, each with a screenshot, the spot marked on it, steps to reproduce and the related code. Review them, then hand them to your agent or send a teammate a `.zip`. |
| **Remote Control** | | Use your phone as the computer's trackpad, keyboard and microphone, and see its screen. One computer can control another too. [More below](#remote-control). |

Keys shown are the Mac's. On Windows, ⌥ is Alt+Shift and dictation is Right Alt; on Linux you pick the dictation key the first time. Every
shortcut can be changed in Settings.

## Install

**Mac** (macOS 13 or later): [download](https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg) and drag it to Applications.
It's signed and notarized, and updates itself. Or run:

```bash
curl -fsSL https://blurt.work/install.sh | sh
```

On macOS 26 dictation works right away with the Mac's own speech recognition, while a local model downloads in the background. The local model
is more accurate and works offline. On macOS 13–15, download a model or add a cloud key first. Local models need Apple silicon.

**Windows and Linux** (test builds): download from [Releases](https://github.com/AGIHunt/blurt/releases). Windows 10 (1903 or later) and 11;
Ubuntu 24.04 or later, Debian 13 or later. They have dictation, voice notes, recording and Remote Control. Windows also has snaps, Copy Text
from Screen and Translate Text from Screen. The Windows installer isn't signed yet, so when SmartScreen asks, choose More info → Run anyway.

**Phones**: the Android APK is on [Releases](https://github.com/AGIHunt/blurt/releases). The iPhone and iPad app isn't in the App Store yet, so
[build it yourself](apps/ios/README.md#build-it-yourself).

## With your agents

In Settings → Agents, click Connect…, and Blurt adds its skill and MCP to your agents, such as Claude Code, Codex, Cursor, Gemini CLI, Kimi Code,
OpenCode and WorkBuddy. Then start a session and say "start blurt", or ask about your items.

- Reviewed items become one instruction to paste into your agent (`⌘↩`). The agent reports progress over MCP, and an item is done when you say so.
- Blurt only writes files and has no Slack, Linear or GitHub connectors. To file or post something there, ask your agent.

Without the app, the skill works on its own: `npx skills add AGIHunt/blurt -g`.

## Remote Control

On the computer you want to control, open Settings → Remote Control → Add Device…. Scan the code with your phone, or paste the pairing link on
another computer. When both show the same digits, click Allow on the computer.

- **Phone to computer**: an iPhone, iPad, or Android phone or tablet controls a Mac, Windows or Linux computer. The phone's talk key dictates on
  the computer, like Fn, and the keyboard matches the computer you control.
- **Computer to computer**: any of Mac, Windows and Linux, with one window per computer.

**How it connects.** On the same network, directly. On different networks, Blurt's public connection service tries a direct connection. When it
can't make one, the session goes through Blurt's server in Hong Kong. That server is free and shared, with no guarantee. The picture is limited to
Data Saver quality and may be slow in the evening, and when the server is busy you get keys, the pointer and voice without the picture. For a
faster, steadier connection, set up [your own relay](tools/remote-relay/README.md) on the computer.

**Security.** Only devices you paired and allowed on the computer can connect. The picture, keystrokes, voice and files are encrypted end to end.
Only your two paired devices hold the keys, so no relay, Blurt's server included, can read or change them. A relay sees both devices' IP
addresses, when they connect and how much data passes, and Blurt's server writes none of this to disk. The controlled computer always shows which
device is controlling it, and you can disconnect at any time. Don't share your pairing code or link.

## Privacy

- Dictation, Copy Text from Screen and recording transcripts are processed on your device by default. Audio or text goes to a cloud service only
  when you add its key and turn that feature on.
- No account needed.
- Snaps, recordings and items stay in your folders (`~/Blurt`, or `.blurt/` in a project). Dictation history is kept for 30 days. You can change
  this, or stop keeping the audio.
- When your agent organizes a recording, the transcript and a few screenshots go to that agent's provider, like anything else you give it.
- Send Feedback sends only the dictations you select. Only Blurt's developers can see them, and they're deleted within 14 days.

More:

- The [user guide](docs/guide.md) covers every feature.
- The [FAQ](docs/faq.md) has the models and their sizes, what it costs, the full privacy notes and a comparison with similar apps.
- [SKILL.md](skills/blurt/SKILL.md) is for agents.

## Community

Questions, feedback and release news are in the WeChat group 口喷鸡狂喷群. To join, reply 口喷 to the WeChat account AGI Hunt. Bugs and ideas
are welcome as [GitHub issues](https://github.com/AGIHunt/blurt/issues).

<p align="center"><sub>MIT · Made by <a href="https://github.com/AGIHunt">AGI Hunt</a></sub></p>
