# Blurt user guide · 使用指南

[English](#english) · [中文](#中文)

---

## English

Blurt turns what you say, snap and record into items — bugs, ideas, notes, tasks — files them into your projects,
and hands them to a coding agent. This page covers everything you do in the app. Shortcuts are the macOS defaults;
on Windows and Linux read `⌥` as `Alt` and `⇧` as `Shift`. Every shortcut can be changed in Settings.

### 1. Capture

The **island** at the top of the screen (around the notch on a MacBook; a small capsule on other screens, Windows and
Linux) is where capture starts. Hover it to see your current project and the three ways to capture.

| | Shortcut | What happens |
|---|---|---|
| **Snap** | `⌥⇧A` | Drag an area and let go, then say (or type) what's wrong; stop talking for about 2 s and it's saved (room noise doesn't keep it open). Hold `⌃` and drag to circle the exact spot. |
| **Voice** | `⌥⇧V` | Press once and talk; a pause of 1.5 s ends it. Or hold the keys and let go when you're done. `Esc` cancels. |
| **Record** | `⌥⇧R` | Pick an area, a window or the full screen, then talk while you use your product. `⌥⇧R` again (or *Finish* on the island) stops. |

While recording: `⌥⇧P` pause, `⌥⇧A` snap a full-resolution still without pausing, hold `⌃` and drag to draw on the
screen (the ink fades after 3 seconds), `⌥⇧D` keeps the pen on. Use a recording for flows, animations and timing;
use a snap or a voice note for everything that fits in one screen or one sentence.

In the menu-bar menu, hold `⌥` to turn *Start Recording* into *Record the Last Area*. The countdown, system audio and
what happens after a recording are in *Settings → General*. The menu-bar icon is the line chick in monochrome, like
the other icons up there: its sound arcs pulse while voice input listens, and it hops when something is done.

Speech is transcribed on your computer. Nothing leaves it unless you choose a cloud speech service.

### 2. Projects and the current project

A **project** is a folder on your computer, the way an editor opens one: *Open Folder…* (`⌘O`) in the main window, or
drag a folder onto it. Items live inside the folder in `.blurt/`, which Blurt keeps out of git for you.

The **current project** decides where new captures go. Press `⌥⇧O` (or click the project name on the island) to
switch:
- **A project** — every snap and voice note goes straight into it and is processed right away.
- **Auto** — captures wait as cards (below) until you say where they belong.

A recording is never a card: when it ends it is processed, and each item is filed into the project it is about.
Items Blurt can't place go to **Unassigned**; move them later by dragging them onto a project in the sidebar.

### 3. Hanging cards

In Auto mode each snap or voice note hangs under the island on a thin thread, like a wind chime. They tuck away into
the island when you're not looking (the number left of the notch counts them) and come back when you need them:

- **Point at the island** (or open it): every card drops down with the island's details and moves with the island as
  it opens. They stay while the pointer is on the island, on the cards or in the gap between them, and tuck away a
  moment after it leaves all of that; come back while they're going up and they turn round.
- **Click the count** left of the notch, press **`⌥⇧H`** (*Show hanging cards*), or use the menu's *Show N Hanging
  Cards*: the cards come down and stay until you've pointed at them and moved away, or press `Esc`.
- In the main window, the Inbox shows **Unfiled captures: N** at the top while cards are waiting; click it to bring them
  all down under the island.

What you can do with a card:

- **Drag a card onto a project** in the island's list to file it there and start processing.
- Drag it onto **Unassigned** to process it without a project, or choose **Auto-sort** to process all the cards
  and file each item into the project it is about.
- **Read it on the card**: a snap shows its note along the bottom of the picture — what you typed first, then what you
  said. The small mic mark means the words were spoken. While your words are still being written down the card says
  *Transcribing…*; if that fails it says *Couldn't transcribe* and the right-click menu has *Retry Transcription*. If
  you started talking and then typed instead (or the mic only heard the room), the recording is dropped: the card
  keeps what you typed and shows no mic.
- **Click to copy**, then `⌘V` anywhere: a snap copies its picture and its note together. Where a paste can take
  both at once — Notes, TextEdit, Mail, Pages — they go in as one, the way copying a picture-and-text message does.
  Chat apps — browsers (DeepSeek, ChatGPT, Claude on the web), Claude, Feishu/Lark, Slack, WeChat, QQ and other apps
  that keep only the picture when a paste has one — get the picture and then the note as a second paste (several
  cards: each picture, then its note), and the island says *Picture + text pasted*. This works for 2 minutes after
  you click, as long as you haven't copied something else; the card copy is back on the clipboard afterwards, so `⌘V`
  works again. Terminals and the Finder get a normal paste. A voice note copies its words. Right-click for *Copy
  Image* or *Copy Text* on their own.
- **Copy several at once**: `⌘`-click cards to pick them (a coloured ring shows which); each `⌘`-click copies all the
  picked cards as one — pictures and notes in the order they hang, like `⌘A` `⌘C` over a run of messages. A plain
  click, or the cards tucking away, ends the selection. *Copy All N Cards* in a card's right-click menu (or *Copy All N
  Hanging Cards* in the island's) does it for every card.
- **Drag it out** into any app: a snap brings its picture (`Screenshot-153012.png`, with your ink if you drew on it)
  and its note — the picture first, then the text:

  | Drop it on | You get |
  | --- | --- |
  | Notes, TextEdit, Mail, Messages, Pages, Keynote | the picture and the note together, in one go |
  | Chrome, Safari and other browsers (DeepSeek, ChatGPT, Claude…), Claude (desktop app), Feishu/Lark, Slack, VS Code, Notion, other Electron apps, WeChat, QQ, any other app | the picture as an attachment, then Blurt pastes the note into the same message box (needs Accessibility) |
  | Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm, Alacritty | the paths of the picture and of a small Markdown file with the note (`Screenshot-153012-note.md`), so Claude Code or Codex can see the picture and read the note (the note itself is never typed into the shell) |
  | Finder or the Desktop | the picture file |

  The note is pasted into the message box you dropped on: Blurt brings that window forward, puts the cursor after the
  picture, pastes, and puts your clipboard back. It never pastes into Blurt itself, into a password field, or into
  another window. *Settings → General → Also attach the note as a .md file* adds the Markdown file for chat apps and
  the Finder too (off by default). The note is also written into the picture's own description (Preview's *Get
  Info* shows it). A voice note is just text you happened to say, so it drops its words, never an audio file. A drag
  you let go of over nothing comes back to its thread. (Drag a voice note before its words are written down and it
  waits a moment for them, or tells you they aren't ready yet.)
- **After a drop**, the card has done its job and leaves its thread — but it isn't thrown away. The island says what
  went in: *Dragged out · picture and note*, or *… picture and note paths* in a terminal. When the note couldn't be
  pasted after the picture (no Accessibility, *Chat apps: the picture, then the note* turned off, the app didn't come
  forward, or it was the Finder), the note goes on the clipboard instead — *Dragged out · picture · note copied, ⌘V to
  paste* — so `⌘V` brings the words back; this replaces what was on your clipboard, and *Undo* puts the card back on
  its thread and your clipboard as it was. You can turn this off in *Settings → General → If the note didn't go in
  with a drop, copy it*; the two-step paste itself is *Settings → General → Chat apps: the picture, then the note*.
- **Recently Taken**: cards you dragged out stay findable for 7 days. Right-click the island (or the count left of
  the notch) → *Recently Taken (N)*, or click *Recently taken: N* at the top of the Inbox or Unassigned in the main
  window. Each one can be copied (picture and note, or either alone), dragged out again (drag its picture), or put
  back on its thread. After 7 days it goes to the Trash.
- Optional: *Settings → General → Add the note under the picture when dragging* drops a copy of the picture with the
  note in a strip under it, for apps that take one picture and nothing else. Off by default; the capture itself stays
  clean.
- Hover to read the note, double-click to edit it, or click × to throw it away.
- Up to seven cards hang side by side; older ones stack up as **+N**. Click the stack to bring them forward.
- While you record, the cards stay tucked away (they would cover what you're showing); `⌥⇧H` still brings them down.

While Blurt processes captures you see a small egg on the island; when it hatches, the new items are in your inbox.

### 4. Review

The main window (`⌥⇧B` → *Open Blurt*) has the **Inbox** at the top of the sidebar, then your projects.

The Inbox holds what needs you, and its header says so: *Needs you: 3 new · 2 to verify*. Select an item to see
everything about it on the right — what you said, the frames, steps, the suspected code — and edit any field; changes
save as you type. To go through a freshly processed capture quickly, open the capture and use the keyboard: `J`/`K` next and
previous, `A` keep, `X` discard, `Z` undo, `M` merge into the previous item, `G` list view, `?` all shortcuts.

### 5. Hand off to an agent

Select one or more items and choose how they get done:

- **Start in Blurt** (`⌘↩`) — runs Claude Code or Codex in a terminal inside Blurt, in the project folder. Several
  items can go to one conversation (*Together*) or one each (*In parallel*, each in its own git worktree so they
  don't edit the same files). The session keeps running if you close the window; Blurt tells you when it needs an
  answer or has finished a turn.
- **Copy instruction** — a one-line instruction pointing at a note with everything the agent needs (screenshots
  included). Paste it into the agent you already use. **Copy full text** copies the note itself.

Agents that have the Blurt MCP installed (Blurt offers it when you set it up) report back on their own: you'll see the item move to
*In progress*, then *To verify*.

### 6. Item states

Every item has one state.

```
New ──keep──▶ To do ──hand off──▶ Handed off ──▶ In progress ──▶ To verify ──mark as done──▶ Done
                ▲                      │              │              │
                ├── take back ─────────┴──────────────┘              │
                └── send back ───────────────────────────────────────┘
```

- **New** — just captured; you haven't looked yet. **To do** — you kept it.
- **Handed off** → **In progress** — an agent has it and is working on it.
- **To verify** — the agent says it's finished. Check it: **Mark as done**, or **Send back** if it isn't right.
- **Done** — you confirmed it. **Won't do** — you decided not to (from any state that isn't finished).
  Both can be reopened.
- **Discarded** — the trash; **Restore** puts an item back where it was.

Your Inbox is *New* + *To verify*: marking something *Won't do*, *Done* or *Discarded* takes it out immediately. An
agent can never mark an item done — "fixed" from an agent always means *to verify*.

Click the status ring in front of an item to change its state; the menu only lists the steps that make sense right
now. Keys in the list: `A` keep · `D` mark as done · `R` back (send back, take back, reopen or restore — whichever
fits) · `W` won't do · `X` discard · `S` open the menu.

### 7. Dictation (macOS)

Dictation types what you say into **whichever app has the focus**: a chat box, an email, your editor, a terminal.
It is separate from the voice note: `⌥⇧V` keeps what you say in Blurt, and dictation puts it where you're typing.

- **Tap Fn** (🌐, alone), talk, **tap it again**. Or **hold Fn** while you talk and let go to stop: anything held
  longer than about 0.3 s is push-to-talk. The island's ears show a keyboard and a mint level while it listens, then
  a few dots while it transcribes and polishes. `Esc` cancels. Fn used with another key (`Fn`-arrow, `Fn`-F-keys…)
  never starts a dictation.
- **Dictating into the middle of a sentence.** Blurt looks at the text on both sides of the cursor and inserts only
  what's new: put the cursor in 「我知道你就是▮的。」, say 「就是从老家回来的」, and you get 「我知道你就是从老家回来的。」 —
  not the repeated 「就是」 or a second full stop. Punctuation and spaces fit the sentence too. It only trims what it
  types, never what's already there, and where the field's text can't be read (WeChat) the words go in as said.
- **Double-tap Fn to send.** Two quick taps press Return in the app in front. Right after you dictate, tap twice
  instead of once: the dictation stops, the text goes in, and then it is sent — the Return you'd press yourself in a
  chat. (With push-to-talk: let go, then tap once quickly.) The island says "Sent ↩︎". It works with whichever key
  you set, never types into Blurt itself or a password field, and can be turned off in *Settings → Dictation*
  (*Double-tap Fn to send (Return)*).
- *Settings → Dictation* (or the setup assistant) switches the key to **right Option** or **either Option key** (left
  or right, still only when tapped alone), and the mode to **tap to start, tap to stop** or **hold to talk** only. If
  you never picked a key before, you now have Fn; a key you chose stays.
- **Fn and macOS.** macOS has its own use for Fn (System Settings → Keyboard → "Press 🌐 key to": emoji, input
  source or system dictation). With Accessibility allowed, Blurt keeps the Fn press to itself so that action doesn't
  run as well (*Keep Fn for dictation*, on by default). Settings → Dictation also shows what that macOS setting is; if
  it isn't "Do Nothing", **Fix…** opens Keyboard settings with a note saying what to change. Blurt never changes it
  for you. If Typeless or Wispr Flow is running, Settings says so: both apps would react to Fn, so quit one or give one
  of them another key.
- **Polish** (Light, the default) runs a small model on your Mac. It removes fillers (嗯, 那个, um, uh) and stutters,
  and adds punctuation and paragraphs. Everything else you said stays — when you correct yourself ("周三，不对，周四",
  "at two, I mean three"), both versions are typed as you said them; *Structured* (below) is the style that settles on
  the corrected one. A pause to breathe in the
  middle of a sentence doesn't end it: the full stop comes where the sentence does. It doesn't rewrite, summarize,
  translate or answer. When its output looks like any of that, or it takes longer than the time limit (3 s), you
  get the words exactly as spoken. The first time, install a model in Settings; the recommended one depends on your
  Mac's memory. *Off* types the raw transcript.
- **Styles.** By default every app gets *Light*: the tidy-up above, and nothing more. It never turns what you say into
  a list, never drops a correction you made, and never changes your tone. A little of it depends on the app: in chat
  apps (WeChat, Slack, Feishu, Telegram…) the model is asked to keep 吧 / 呢 / 啊 and a one-sentence message gets no
  full stop; in terminals and code editors the text stays on one line. When you *want* it tidier — a list, or just
  the version you settled on:
  - **press ⇧ on its own while you talk** (any time, even halfway through, and also while holding Fn): *Structured*.
    The island's right ear shows a list mark. When you let go, the same local model goes over the whole dictation once
    more: what you took back or restated goes (in whatever words you did it), and points you counted off or listed
    become a numbered list with the sentence before them as its heading — only when you really enumerated; otherwise
    it stays a paragraph. It never rewrites or summarizes: if its result loses anything, you get the Light text. This
    takes a little longer (about 0.1–0.3 s more on an M-series Mac). Press ⇧ again to go back. **Fn+⇧** starts a
    dictation in Structured. A click on the island while it listens does the same;
  - **⌥⇧L reformats the last dictation**: Light → Structured → Verbatim (exactly what the speech model heard) → Light,
    with **Undo** on the island. It replaces the text in the field only while it is exactly as it was typed; if you
    have edited it, the new version goes to the clipboard instead, and your edits stay. After a longer dictation that
    went in as prose, the model checks it for a list in the background (the paste never waits for it); if it finds
    one, the island offers **Make a List** for a few seconds.
  - Nothing you *say* switches the style: "make a list" or 「帮我列个清单」 is typed like any other words, because it is
    often an instruction meant for an AI agent.
  - *Settings → Dictation → Style* sets a style per kind of app (Chat, Code and terminals, Mail, Notes and documents,
    Other): Light, Verbatim, Structured, or Auto lists (the structured text only when the model made it a list).
    When you keep switching the same way in one app (three times or more), the island asks once whether to make that
    the app's style; it never changes anything by itself, and what it learned shows (and resets) in Settings.
- **Custom words** (*Settings → Dictation*): the names and terms you say often — "Claude Code", "tmux", a project's
  name. Dictation writes them exactly the way they're listed, so "Claude" doesn't come out as "cloud" and "option"
  isn't cut to "op". Blurt starts the list for you with Claude Code, Codex, blurt / 口喷鸡 and your projects' names and
  keys (remove any you don't want). The recommended **recognition model** (Qwen3-ASR on Apple silicon, a 1 GB
  download) listens for these words directly; with the others, the words are corrected afterwards.
- **It learns from your fixes.** For a minute after a dictation, if you correct a word it typed (pool request →
  pull request), Blurt notices. The second time you make the same fix, or at once for a capital letter or a space
  ("github" → "GitHub"), the word joins your list and the island says *Learned "pull request"* with **Undo**.
  Suggestions it isn't sure about wait in Settings for you to add or ignore.
- **The text around the cursor** helps too: when you start talking, Blurt reads about 500 characters before and after
  the cursor (and the window's title) so names are spelled the way the document spells them. It is used for that one
  dictation and not kept; password fields are never read. Both this and learning can be turned off in Settings.
- **Permissions:** Accessibility lets Blurt paste, read the text around the cursor and hear Fn; Input Monitoring is
  what it uses to hear the other keys; and the microphone, of course. Settings → Dictation shows each one, whether the
  key is actually heard, and when it was last heard while another app was in front. Until it is, the menu-bar menu
  starts with *Turn On Dictation…* and the island reminds you about once a day. Both, and *Turn On…* in Settings, start
  the **permission guide** (below); dictation starts working within a few seconds of the switch, no restart needed.
  Without Accessibility, or when the focus isn't a text field, the text is copied and the island says so: paste it
  with `⌘V`. Your clipboard is put back after a paste.
- **The permission guide.** *Set Up Permissions…* (the setup assistant, Settings → Privacy, Settings → Dictation) and
  each permission's *Allow…* do the clicking-around for you, one missing permission at a time: Blurt puts itself in
  the list (macOS may show its own prompt the first time), opens the exact page of System Settings, and a small panel
  next to the System Settings window says what to do — usually just "Turn on Blurt here". If Blurt isn't in the list,
  drag the Blurt icon from the panel into it. The panel follows the window, shows every step's state, and moves on by
  itself as soon as a switch is on; *Skip* leaves one for later. At the end Blurt comes back to the front with a check
  mark: "Done — dictation works in every app now." Screen Recording sometimes needs Blurt restarted; the panel and
  Settings → Privacy have a **Restart Blurt** button for that. Blurt never clicks or changes anything in System
  Settings itself.
- **Dictation** is a place in the main window's sidebar, under All Items (also menu bar → *Dictation History…*,
  `⌥⌘D`, or the command palette). It lists every dictation by day: the app it went into, the time, the text, and small
  marks for polished, typed as spoken (polish fell back) and terms applied. The toolbar's search field searches it.
  Above the list are today's numbers (dictations, words, roughly the minutes saved) and a link to *Dictation
  Settings…*. Select a dictation to see it on the right: what was typed and what the speech model heard, one at a time
  or side by side, each with its own Copy button. From there you can **turn it into an item** in the current project
  (or Unassigned) or delete it. The detail also shows the app, the length, and how it was typed. Keys: `↑` `↓` to move,
  `⌘C` to copy, `⌫` to delete (`⌘Z` puts it back), `⌘F` to search. With no dictations yet, the page explains which key
  to tap and says when dictation is off or can't hear its key yet. History is kept for 30 days (Settings), and the
  audio is deleted right after transcription unless you choose to keep it.
- Dictation is off while a screen recording runs, because the recording is using the microphone. Dictation and the
  voice note never listen at the same time: whichever started first keeps the microphone until it's done.

#### Dictation Lab

The Dictation page has two tabs: **History** and **Lab** (also *Go → Dictation Lab*, `⌥⌘L`). The lab is where you
find out why a dictation came out wrong and keep the evidence. Everything in it stays on this Mac.

- **Record a take**: click the big button (or tap your dictation key while the lab is in front) and talk. Pick the
  microphone next to it, or **Import Audio…** to play a file in as the microphone. Nothing is typed anywhere.
- You see **each stage** side by side with its milliseconds: what the speech model heard for every piece, the stitched
  transcript, the polished text and the text that would have been typed (fitted into the "text around the cursor"
  you can fill in), plus the custom words used, the guard's verdict and anything it put back.
- Write **what you meant** (before or after the take) or the **corrected text**, and the lab shows the difference
  (Chinese by character, English by word) with WER, CER, punctuation and term accuracy. Mark what went wrong with the
  chips (wrong name, Chinese turned into English, punctuation, filler kept, content dropped, made-up words, wrong
  segmentation, start or end cut off, too slow), add a note and a rating, and **Save as Case**. A correction teaches
  the custom words; the lab shows what it learned, with **Undo**.
- **Compare** runs a saved case again through other settings: another speech model, polish off or another polish
  model, no custom words, no context.
- **Read a Script**: the lab shows a sentence, you read it aloud, and its text becomes the reference. Read it again if
  you stumbled (every take is kept; *Keep only this* tidies up), then go to the next one. A built-in script covers
  short and long sentences, chat, code, email and meetings, names, numbers, self-corrections, fillers and spoken lists.
  *Import a Script…* adds your own; *Generate 10 More* writes more in the same style.
- **Run All Cases** runs every saved case through the current pipeline in the background and shows what got better or
  worse, with an overall score and a breakdown by dimension. Agents and CI can run the same check:
  `uv run skills/blurt/scripts/dictation_lab.py run`.
- **Add to Lab** on any dictation in History makes it a case (with its audio if it was kept, else text only). *Keep
  the audio of my next dictations* keeps the audio of the next few real dictations so you can add them.
- **Export…** saves every case as a dataset (`manifest.jsonl` + 16 kHz WAVs) for evaluation or fine-tuning. *Move to
  Trash* deletes a case.

---

## 中文

口喷鸡把你说的、截的、录的整理成一条条事情——问题、想法、笔记、任务——归到对应的项目，再交给写代码的 agent 去做。
这页讲的是在 App 里怎么用。下面的快捷键是 macOS 的默认值；Windows 和 Linux 上 `⌥` 是 `Alt`，`⇧` 是 `Shift`。所有快捷键都能在设置里改。

### 1. 捕获

屏幕顶部的**刘海岛**（MacBook 上围着刘海；其它屏幕、Windows 和 Linux 上是一个小胶囊）是捕获的入口。鼠标移上去，能看到当前项目和三种捕获方式。

| | 快捷键 | 做什么 |
|---|---|---|
| **截图** | `⌥⇧A` | 框一块区域，松手，接着说（或者打字）哪里不对。按住 `⌃` 拖动可以圈出具体位置。 |
| **语音** | `⌥⇧V` | 按一下开始说，停顿 1.5 秒自动结束；也可以按住说、松开结束。`Esc` 取消。 |
| **录屏** | `⌥⇧R` | 选区域、窗口或全屏，一边用产品一边说。再按 `⌥⇧R`（或岛上的「完成」）结束。 |

录屏时：`⌥⇧P` 暂停；`⌥⇧A` 截下这一刻的全分辨率画面，不用暂停；按住 `⌃` 拖动在屏幕上画（笔迹 3 秒后消失）；`⌥⇧D` 让画笔常开。
操作流程、动画、时序问题用录屏；一个画面、一句话能说清的，用截图或语音。

菜单栏菜单里按住 `⌥`，「开始录制」会变成「录制上次的区域」。倒计时、是否录系统声音、录完之后做什么，都在「设置 → 通用」里。菜单栏图标是单色的小鸡，和菜单栏里其它图标一致；想要彩色的，打开「设置 → 通用 → 彩色菜单栏图标」。

语音在你的电脑上转写。除非你选了云端语音服务，内容不会离开这台电脑。

### 2. 项目和当前项目

**项目**就是你电脑上的一个文件夹，跟编辑器打开文件夹一样：在主窗口里「打开文件夹…」（`⌘O`），或者把文件夹拖进来。
条目存在这个文件夹的 `.blurt/` 里，口喷鸡会自动让它不进 git。

**当前项目**决定新捕获去哪。按 `⌥⇧O`（或点岛上的项目名）切换：
- **某个项目**：截图和语音直接进这个项目，马上开始整理。
- **自动**：捕获先挂成卡片（见下），等你决定放哪。

录屏不会挂卡片：结束就开始整理，每一条按内容归到对应的项目。归不了类的进「**未归类**」，之后在侧栏里拖到项目上就行。

### 3. 挂着的卡片

自动模式下，每张截图、每段语音用一根细线挂在岛的下方，像风铃。你不看的时候它们会收进岛里（刘海左边的数字就是有几张），需要时再放下来：

- **鼠标移到岛上**（或者打开岛）：所有卡片跟着岛的详情一起垂下来，岛展开时跟着岛一起往下走。鼠标在岛上、卡片上或两者之间时一直挂着，全部离开片刻后才收起；收到一半时鼠标回来，卡片就原地停下、重新垂下。
- **点刘海左边的数字**、按 **`⌥⇧H`**（「显示挂着的卡片」），或者用菜单里的「显示 N 张挂着的卡片」：卡片放下来并一直挂着，直到你把鼠标移过来再移走，或者按 `Esc`。
- 主窗口「待处理」的顶部会显示「**未归类的捕获 N 条**」，点一下就把它们全部放到岛下面。

卡片能做的事：

- **把卡片拖到岛上列出的某个项目**：归到那个项目，开始整理。
- 拖到「**未归类**」：先整理，稍后再选项目；或者点「**自动归类**」：把所有卡片一起整理，每一条按内容归到对应的项目。
- **单击复制**，然后在任何地方 `⌘V`：截图会把图片和备注一起复制。备忘录、文本编辑、邮件、Pages 这类一次就能连图带字收下的应用，直接一起贴进去，就像复制一条图文消息。聊天应用——浏览器（网页版 DeepSeek、ChatGPT、Claude）、Claude、飞书/Lark、Slack、微信、QQ，以及其他粘贴里只要有图片就只收图片的应用——会先贴图片，再把备注作为第二次粘贴贴上（多张卡片就一张图一段备注依次贴），岛上显示「图 + 文已粘贴」。点卡片后的 2 分钟内有效，前提是你没有再复制别的；贴完剪贴板里还是这份卡片，可以再按 `⌘V`。终端和访达拿到的是普通的粘贴。语音卡片复制说的话。右键可以单独「拷贝图片」或「拷贝文字」。
- **一次复制好几张**：按住 `⌘` 点卡片来选（选中的有一圈彩色边框），每次 `⌘` 点都会把选中的卡片作为一份内容复制好——图片和备注按挂着的顺序排，就像对一串消息 `⌘A` `⌘C`。普通单击或者卡片收起来，选择就结束。卡片右键菜单里的「拷贝全部 N 张卡片」（或者岛的右键菜单里「拷贝全部 N 张挂着的卡片」）一次复制所有卡片。
- **拖到别的应用里**：截图拖出去是图片（`截图-153012.png`，画过就带笔迹）连同备注——先图片，后文字：

  | 拖到 | 得到 |
  | --- | --- |
  | 备忘录、文本编辑、邮件、信息、Pages、Keynote | 图片和备注，一次一起进去 |
  | Chrome、Safari 等浏览器（DeepSeek、ChatGPT、Claude…）、Claude（桌面版）、飞书/Lark、Slack、VS Code、Notion、其他 Electron 应用、微信、QQ、其他应用 | 图片作为附件放进去，然后口喷鸡把备注贴进同一个输入框（需要「辅助功能」权限） |
  | 终端、iTerm2、Ghostty、Warp、kitty、WezTerm、Alacritty | 图片和一个写着备注的 Markdown 小文件（`截图-153012-备注.md`）的路径，Claude Code、Codex 能看到图片、读到备注（备注文字本身不会打进命令行） |
  | 访达或桌面 | 图片文件 |

  备注会贴进你拖进去的那个输入框：口喷鸡把那个窗口带到前面，把光标放到图片后面，粘贴，再把你的剪贴板还原。它不会贴进口喷鸡自己、密码框或者别的窗口。「设置 → 通用 → 同时附上备注的 .md 文件」可以让聊天应用和访达也收到这个 Markdown 文件（默认关闭）。备注也写进了图片自带的描述里（预览的「显示简介」能看到）。语音本来就是说出来的文字，所以拖出去只有文字，不会是音频文件。拖到空白处松手，卡片会回到线上。（语音还没转成文字时拖它，会稍等一下；还没好就提示你稍后再拖。）
- **拖进去以后**：卡片用完了，会从线上离开，但不会被扔掉。岛上会说放进去了什么：「已拖走 · 图片和备注」，终端里是「已拖走 · 图片和备注的路径」。备注没能贴在图片后面时（没有「辅助功能」权限、关掉了「聊天应用：先放图片，再贴备注」、应用没到前台，或者拖进了访达），备注会改放进剪贴板——「已拖走 · 图片 · 备注已复制，⌘V 可粘贴」——在那里按 `⌘V` 就行；这会替换剪贴板里原来的内容，点「撤销」会把卡片放回线上，剪贴板也还原。不想要这一步，可以在「设置 → 通用 → 拖进去后备注没贴上时，拷贝到剪贴板」里关掉；两步粘贴本身在「设置 → 通用 → 聊天应用：先放图片，再贴备注」。
- **最近拖走的**：拖出去的卡片保留 7 天。右键点岛（或刘海左边的数字）→「最近拖走的（N）」，或者点主窗口「待处理」「未归类」顶部的「最近拖走的：N 张」。每一张都可以再拷贝（图片和备注一起，或者单独一样）、把图片再拖出去，或者放回线上。7 天后移到废纸篓。
- 可选：「设置 → 通用 → 拖出图片时把备注印在图片下方」，拖出去的是一份在下方加了备注条的图片副本，给只收一张图片的应用用。默认关闭；原来的截图不变。
- 悬停看备注，双击改备注，点 × 扔掉。
- 最多并排挂 7 张，更早的叠成「+N」，点一下就换到前面来。
- 录屏时卡片收着不放下来（免得挡住你要演示的东西），按 `⌥⇧H` 仍然可以放下来看。

整理时岛上会出现一个小蛋；蛋破壳了，新条目就出现在「待处理」里。

### 4. 审核

主窗口（`⌥⇧B` →「打开口喷鸡」）侧栏最上面是**待处理**，下面是你的项目。

「待处理」里是需要你看的，标题会直接告诉你：「需要你看的：3 条新的 · 2 条待验证」。选中一条，右边是它的全部内容——原话、截图、步骤、
可能相关的代码——每个字段都能改，边打边保存。刚整理好的一次捕获想快速过一遍，就打开它，用键盘：`J` / `K` 下一条 / 上一条，
`A` 要做，`X` 丢弃，`Z` 撤销，`M` 并进上一条，`G` 列表视图，`?` 查看全部快捷键。

### 5. 交给 agent

选中一条或几条，选一种交法：

- **在口喷鸡里开始**（`⌘↩`）：在口喷鸡内置的终端里、在项目文件夹中运行 Claude Code 或 Codex。几条可以放进一个对话（**一起处理**），
  也可以每条一个（**并行**，各自在独立的 git worktree 里，互不改到同一个文件）。关掉窗口会话也继续跑；需要你回答、或者一轮做完了，口喷鸡会提醒你。
- **复制指令**：一句话的指令，指向一份交接单，agent 需要的东西（包括截图）都在里面。粘贴给你平时用的 agent 就行。「**复制全文**」复制的是交接单本身。

装了口喷鸡 MCP 的 agent（首次设置时口喷鸡会帮你装）会自己回报：你会看到条目变成「进行中」，再变成「待验证」。

### 6. 条目状态

每条只有一个状态。

```
新 ──要做──▶ 要做 ──交出──▶ 已交出 ──▶ 进行中 ──▶ 待验证 ──标为完成──▶ 完成
               ▲               │          │          │
               ├── 收回 ───────┴──────────┘          │
               └── 退回 ─────────────────────────────┘
```

- **新**：刚捕获，你还没看。**要做**：你留下了。
- **已交出** → **进行中**：agent 接手了，正在做。
- **待验证**：agent 说做好了。看一眼：没问题就「**标为完成**」，不对就「**退回**」。
- **完成**：你确认过了。**不做**：你决定不做（没结束的条目都能标）。两者都能重新打开。
- **已丢弃**：垃圾桶；「**恢复**」会把条目放回丢弃前的状态。

待处理 = 新 + 待验证：标了不做、完成或丢弃的条目会立刻从待处理里消失。agent 永远不能把条目标为完成——agent 说「修好了」，一律是待验证。

点条目前面的状态圆环就能改状态，菜单里只列现在说得通的几步。列表里的快捷键：`A` 要做 · `D` 标为完成 ·
`R` 往回（退回、收回、重新打开或恢复，哪个适用就是哪个）· `W` 不做 · `X` 丢弃 · `S` 打开菜单。

### 7. 听写（macOS）

听写把你说的话打进**当前有焦点的 App**：聊天框、邮件、编辑器、终端都行。它和语音备注是两回事：`⌥⇧V` 把说的话存进口喷鸡，听写把它打在你正在输入的地方。

- **按一下 Fn**（🌐 键，单独按），说话，**再按一下**结束。也可以**按住 Fn** 说话，松开就结束：按住超过约 0.3 秒就是按住说话。听的时候岛的两侧显示键盘和薄荷色的音量条，转写和润色时变成几个跳动的点。`Esc` 取消。Fn 和别的键一起用（Fn 加方向键、Fn 加功能键等）时不会开始听写。
- **在句子中间听写。** 口喷鸡会看光标前后的文字，只插入新的部分：光标放在「我知道你就是▮的。」里，说「就是从老家回来的」，得到的是「我知道你就是从老家回来的。」，不会重复「就是」，也不会多一个句号。标点和空格也会顺着句子来。它只修剪自己要输入的文字，从不改动框里已有的内容；读不到输入框文字的地方（比如微信），就照说的输入。
- **双击 Fn 发送。** 快速连按两下，就是在前台 App 里按回车。说完时把「再按一下」换成「连按两下」：听写结束，文字填进去，然后发送出去，就像在聊天框里自己按回车。（按住说话时：松开后马上再按一下。）岛上会显示「已发送 ↩︎」。换成其他按键也一样；不会往口喷鸡自己或密码框里按回车；不需要的话在「设置 → 听写」里关掉「双击 Fn 发送（回车）」。
- 在「设置 → 听写」（或设置助手）里可以把按键换成**右 Option** 或**任一 Option 键**（左右都行，同样只认单按），方式换成只用「按一下开始，再按一下结束」或只用「按住说话」。以前没改过按键的，现在默认是 Fn；自己选过的按键保持不变。
- **Fn 和 macOS。** macOS 自己也会用 Fn（「系统设置 → 键盘 → 按下 🌐 键时」：表情、切换输入法或系统听写）。开启「辅助功能」后，口喷鸡会把 Fn 留给自己，macOS 的这个功能就不会同时触发（「Fn 只用来听写」，默认开启）。「设置 → 听写」也会显示这项系统设置现在是什么；不是「不执行任何操作」时，点**去设置…**会打开键盘设置，并提示你改哪一项。口喷鸡不会替你改它。如果 Typeless 或 Wispr Flow 正在运行，设置页会提示：两边都会响应 Fn，退出其中一个，或者给其中一个换个键。
- **润色**（默认「轻度」）在本机跑一个小模型：去掉语气词（嗯、那个、um、uh）和口吃，加标点、分段。其余你说的话都保留——中途改口（「周三，不对，周四」「at two, I mean three」）时，前后两种说法都照你说的打出来；只想要改口后那一版，用下面的「结构化」。说到一半停下来换口气不算一句话结束：句号只加在句子真正说完的地方。它不改写、不总结、不翻译、不回答问题。一旦输出像在做这些，或者超过时限（3 秒），就照你说的原话输入。第一次用要在设置里装一个模型，推荐哪个取决于这台 Mac 的内存。选「关」就直接输入识别原文。
- **风格。** 默认所有 App 都是「轻整理」：只做上面这些整理，不多做。它不会把你的话排成清单，不会删掉你的改口，也不改语气。按 App 稍有不同：在聊天 App（微信、Slack、飞书、Telegram 等）里会让模型保留「吧、呢、啊」这类语气词，只有一句话时不加句号；在终端和代码编辑器里不换行，打成一行。想要更整齐（排成清单，或者只留改口后的说法）时：
  - **说话时单按一下 ⇧**（随时都行，说到一半也行，按住 Fn 说话时也行）：这一条就是「结构化」，岛右侧会出现清单标记。松开按键后，同一个本地模型会把整段话再过一遍：你收回或重说的部分（不管你怎么说的）会去掉，你一条条数出来或列出来的要点会排成编号清单，前面那句话留作标题——只有真的在列举时才排，否则还是一段话。它不改写、不总结：结果一旦丢了内容，就打轻整理的版本。这会多花一点时间（M 系列 Mac 上大约多 0.1–0.3 秒）。再按一下 ⇧ 切回。按 **Fn+⇧** 开始，这一条直接就是结构化。听写时点一下岛也一样。
  - **⌥⇧L 重排上一条**：轻整理 → 结构化 → 原话（语音模型听到的原样）→ 轻整理，岛上可以**撤销**。只有那段文字还和输入时一模一样，才会在原处替换；你改过它的话，新版本放进剪贴板，你的修改不动。较长的一条按普通段落打进去以后，模型会在后台看一下它是不是清单（输入从不等它）；是的话，岛上会出现几秒「排成清单」。
  - 说出来的话不会切换风格：「帮我列个清单」「make a list」就照字面打出来，因为这往往是说给 AI agent 的指令。
  - 「设置 → 听写 → 风格」可以按 App 类别（聊天、代码和终端、邮件、笔记和文档、其他应用）选：轻整理、原话、结构化，或「自动排清单」（只有模型排成了清单才用结构化的版本）。如果你在某个 App 里总是同样地切换（三次以上），岛上会问一次要不要把它设成这个 App 的风格；它从不自己改，学到的设置在设置页里能看到，也能恢复默认。
- **自定义词**（「设置 → 听写」）：你常说的名字和术语，比如「Claude Code」「tmux」、项目名。听写会照列表里的写法输出，「Claude」不会变成「cloud」，「option」也不会只剩「op」。口喷鸡会先帮你填好 Claude Code、Codex、blurt / 口喷鸡，以及你的项目名和项目代号（不想要的可以移除）。推荐的**识别模型**（Apple 芯片上用 Qwen3-ASR，下载约 1 GB）在识别时就会照顾这些词；用其他模型时，这些词在识别之后再改。
- **它会从你的修改中学习。** 听写后一分钟内，如果你改了它打错的词（pool request → pull request），口喷鸡会注意到。同样的修改第二次出现时，或者只是改大小写、空格（「github」→「GitHub」）时，这个词就会加入列表，岛上显示「记住了 pull request」，可以**撤销**。拿不准的会作为建议留在设置里，由你决定添加还是忽略。
- **光标附近的文字**也有帮助：开始说话时，口喷鸡会读取光标前后各约 500 个字和窗口标题，让名字和文档里的写法一致。只用于这一次听写，不会保存，也从不读密码框。这项和自动学习都可以在设置里关掉。
- **权限**：「辅助功能」用来粘贴、读取光标附近的文字和听到 Fn；「输入监控」用来听到其他按键；还有麦克风。「设置 → 听写」显示每一项的状态，也会显示按键现在能不能被听到，以及上次在其他 App 里听到按键的时间。听不到的时候，菜单栏菜单第一行是「开启听写…」，岛上大约每天提醒一次。这两处和设置里的「开启…」都会打开**权限向导**（见下）；开关打开后几秒内自动生效，不用重启。没有辅助功能权限、或者焦点不在输入框上时，文字会复制到剪贴板，岛上会提示「已复制，可粘贴」，按 `⌘V` 粘贴即可。粘贴之后，你原来的剪贴板内容会还原。
- **权限向导。**「设置权限…」（设置助手、「设置 → 隐私」「设置 → 听写」）和每项权限的「允许…」会替你跑腿，一次处理一项还没开的权限：口喷鸡先把自己加进列表（第一次 macOS 可能弹出自己的提示），打开「系统设置」里正好那一页，再在「系统设置」窗口旁边放一个小面板告诉你怎么做，通常就是「在这里打开口喷鸡的开关」。列表里没有口喷鸡时，把面板上的口喷鸡图标拖进列表就行。面板跟着窗口走，显示每一步的状态，开关一打开就自动进入下一步；「跳过」可以留到以后。全部完成后口喷鸡回到最前面，打个勾：「好了，现在在任何 App 里都能听写。」录屏权限有时要重新打开口喷鸡才生效，面板和「设置 → 隐私」里有**重新打开口喷鸡**按钮。口喷鸡从不替你点击或修改「系统设置」里的任何东西。
- **听写**是主窗口侧栏里的一页，在「全部条目」下面（也可以从菜单栏 →「听写历史…」、`⌥⌘D` 或命令面板进入）。它按天列出所有听写：打到了哪个 App、时间、文字，以及几个小标记：润色过、按原话输入（润色没成功）、用到了术语。工具栏的搜索框搜的就是这一页。列表上方是今天的数字（听写次数、字数、大约省下的分钟）和「听写设置…」入口。选中一条，右边显示详情：输入的文字和语音模型识别的原文，可以分开看，也可以对照看，各有复制按钮。在这里还能**转为条目**（进当前项目，没有当前项目就进「未归类」）或删除，并能看到 App、时长和输入方式。按键：`↑` `↓` 切换，`⌘C` 复制，`⌫` 删除（`⌘Z` 撤销），`⌘F` 搜索。还没有听写时，这一页会告诉你按哪个键，听写关着或还听不到按键时也会说明。历史默认保留 30 天（可在设置里改）；录音转写完就删，除非你选择保留。
- 录屏时听写不可用，因为麦克风正被录屏占用。听写和语音备注不会同时听：先开始的那个用完麦克风，另一个才能用。

#### 听写测试台

听写页有两个标签：**历史**和**测试台**（也可以从菜单「前往 → 听写测试台」或 `⌥⌘L` 进入）。听写哪里出了错、为什么错，都可以在测试台里查清楚，并把证据留下来。这里的一切都只存在这台 Mac 上。

- **录一段**：点大按钮（测试台在前面时也可以按听写键），然后说话。旁边可以选麦克风，也可以**导入音频**，把文件当作麦克风的声音放进来。不会往任何地方打字。
- **每一步的结果**并排显示，各带耗时：每一段识别出的原文、拼接后的原文、润色结果，以及最终会输入的文字（按你填的「光标附近的文字」衔接过），还有用到的自定义词、检查的结论和补回的内容。
- 写下**你想说的**（录之前或之后都行）或者**修正后的文字**，测试台会标出差别（中文按字、英文按词），给出词错率、字错率、标点和术语的准确率。用标签标出哪里错了（名字或术语错了、中文变成了英文、标点、口头禅没去掉、内容丢了、多出了没说的话、断句不对、开头或结尾被截掉、太慢），写备注、打分，然后**存为用例**。修正会让自定义词学到东西，测试台会显示学到了什么，可以**撤销**。
- **对比**：把存好的用例换一种设置再跑一遍，比如换识别模型、不润色或换润色模型、不用自定义词、不看上下文。
- **照稿朗读**：测试台给出一句话，你照着读，这句话自动成为参考文本。读错了就重读（每一遍都会留下，「只留这一遍」可以清理），然后读下一句。自带的稿子覆盖长短句、聊天、编程指令、邮件、会议纪要、名字、数字、说错改口、口头禅和口头列举。「导入稿子…」可以加你自己的，「再生成 10 句」会按同样的风格再写一些。
- **全部重跑**：在后台把所有用例按现在的流程再跑一遍，标出哪些变好、哪些变差，给出总分，并按维度拆开看。智能体和 CI 也能跑同样的检查：`uv run skills/blurt/scripts/dictation_lab.py run`。
- 在历史里任意一条听写上点**加到测试台**，就会生成一个用例（留了录音就带录音，没留就只有文字）。勾选「保留接下来几次听写的录音」，就能把接下来几次真实听写的录音留下来，再加进测试台。
- **导出…**会把所有用例存成一个数据集（`manifest.jsonl` 加 16 kHz 的 WAV），可以拿去做评测或微调。「移到废纸篓」删除用例。
