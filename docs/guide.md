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
| **Snap** | `⌥⇧A` | Drag an area and let go, then say (or type) what's wrong. Hold `⌃` and drag to circle the exact spot. |
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
- **Click to copy**: a voice note copies its words; a snap copies the image (with your ink, if you drew on it), and its
  note or spoken words come along as text, so pasting into a text-only field gives you the words. Right-click for
  *Copy Image* or *Copy Text* on their own.
- **Drag it out** into any app: a snap drops its image file (and its words); a voice note is just text you happened to
  say, so it drops its words, never an audio file. Once another app takes it, the card has done its job and leaves
  its thread; *Dragged out · Undo* in the island puts it back. A drag you let go of over nothing comes back to its
  thread. (Drag a voice note before its words are written down and it waits a moment for them, or tells you they
  aren't ready yet.)
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

- **Tap right Option** (alone, nothing else held), talk, **tap it again**. The island's ears show a keyboard and a mint
  level while it listens, then a few dots while it transcribes and polishes. `Esc` cancels. Right Option used with
  another key (`⌥`-letter, `⌥⇧V`…) never starts a dictation.
- *Settings → Dictation* switches the key to **Fn** or **either Option key** (left or right, still only when tapped
  alone) and the mode to **hold to talk** (it starts after you've held the key
  for a quarter of a second and stops when you let go; pressing another key cancels it). For Fn, set System Settings →
  Keyboard → "Press fn key to" to "Do Nothing". If Typeless is also running on Fn, the two apps clash.
- **Polish** (Light, the default) runs a small model on your Mac. It removes fillers (嗯, 那个, um, uh), stutters and the
  words you corrected ("周三，不对，周四" → "周四"), and adds punctuation and paragraphs. It doesn't rewrite, summarize,
  translate or answer. When its output looks like any of that, or it takes longer than the time limit (3 s), you
  get the words exactly as spoken. The first time, install a model in Settings; the recommended one depends on your
  Mac's memory. *Off* types the raw transcript.
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
- **Permissions:** Input Monitoring lets Blurt notice the key; Accessibility lets it paste and read the text around
  the cursor. Settings shows both, with a button to the right System Settings pane, whether the key is actually
  heard, and when it was last heard while another app was in front. Until it is, the menu-bar menu starts with
  *Turn On Dictation…* and the island reminds you about once a day; once you allow Input Monitoring, dictation
  starts working within a few seconds, no restart needed. With Accessibility alone, Blurt still hears the key.
  Without Accessibility, or when the focus isn't a text field, the text is copied and the island says so: paste it
  with `⌘V`. Your clipboard is put back after a paste.
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
- **单击复制**：语音卡片复制说的话；截图复制图片（画过就带笔迹），备注或说的话作为文字一起放进剪贴板，粘到只收文字的地方就是那段话。右键可以单独「拷贝图片」或「拷贝文字」。
- **拖到别的应用里**：截图拖出去是图片文件（带上文字）；语音本来就是说出来的文字，所以拖出去只有文字，不会是音频文件。别的应用接住以后，这张卡片就用完了，会从线上离开；岛上「已拖走 · 撤销」可以把它放回来。拖到空白处松手，卡片会回到线上。（语音还没转成文字时拖它，会稍等一下；还没好就提示你稍后再拖。）
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

- **按一下右 Option**（单独按，不带别的键），说话，**再按一下**。听的时候岛的两侧显示键盘和薄荷色的音量条，转写和润色时变成几个跳动的点。`Esc` 取消。右 Option 和别的键一起用（`⌥` 加字母、`⌥⇧V` 等）时不会开始听写。
- 在「设置 → 听写」里可以把按键换成 **Fn** 或**任一 Option 键**（左右都行，同样只认单按），方式换成**按住说话**：按住约 0.25 秒开始，松开结束，中途按了别的键就取消。用 Fn 时，把「系统设置 → 键盘 → 按下 fn 键时」设为「不执行任何操作」；如果 Typeless 也在用 Fn，两边会冲突。
- **润色**（默认「轻度」）在本机跑一个小模型：去掉语气词（嗯、那个、um、uh）、口吃和说错改口的部分（「周三，不对，周四」→「周四」），加标点、分段。它不改写、不总结、不翻译、不回答问题。一旦输出像在做这些，或者超过时限（3 秒），就照你说的原话输入。第一次用要在设置里装一个模型，推荐哪个取决于这台 Mac 的内存。选「关」就直接输入识别原文。
- **自定义词**（「设置 → 听写」）：你常说的名字和术语，比如「Claude Code」「tmux」、项目名。听写会照列表里的写法输出，「Claude」不会变成「cloud」，「option」也不会只剩「op」。口喷鸡会先帮你填好 Claude Code、Codex、blurt / 口喷鸡，以及你的项目名和项目代号（不想要的可以移除）。推荐的**识别模型**（Apple 芯片上用 Qwen3-ASR，下载约 1 GB）在识别时就会照顾这些词；用其他模型时，这些词在识别之后再改。
- **它会从你的修改中学习。** 听写后一分钟内，如果你改了它打错的词（pool request → pull request），口喷鸡会注意到。同样的修改第二次出现时，或者只是改大小写、空格（「github」→「GitHub」）时，这个词就会加入列表，岛上显示「记住了 pull request」，可以**撤销**。拿不准的会作为建议留在设置里，由你决定添加还是忽略。
- **光标附近的文字**也有帮助：开始说话时，口喷鸡会读取光标前后各约 500 个字和窗口标题，让名字和文档里的写法一致。只用于这一次听写，不会保存，也从不读密码框。这项和自动学习都可以在设置里关掉。
- **权限**：「输入监控」用来识别按键，「辅助功能」用来粘贴和读取光标附近的文字。设置页显示两者的状态，并有按钮直达系统设置里对应的位置，也会显示按键现在能不能被听到，以及上次在其他 App 里听到按键的时间。听不到的时候，菜单栏菜单第一行是「开启听写…」，岛上大约每天提醒一次；允许「输入监控」后几秒内自动生效，不用重启。只有「辅助功能」时也能听到按键。没有辅助功能权限、或者焦点不在输入框上时，文字会复制到剪贴板，岛上会提示「已复制，可粘贴」，按 `⌘V` 粘贴即可。粘贴之后，你原来的剪贴板内容会还原。
- **听写**是主窗口侧栏里的一页，在「全部条目」下面（也可以从菜单栏 →「听写历史…」、`⌥⌘D` 或命令面板进入）。它按天列出所有听写：打到了哪个 App、时间、文字，以及几个小标记：润色过、按原话输入（润色没成功）、用到了术语。工具栏的搜索框搜的就是这一页。列表上方是今天的数字（听写次数、字数、大约省下的分钟）和「听写设置…」入口。选中一条，右边显示详情：输入的文字和语音模型识别的原文，可以分开看，也可以对照看，各有复制按钮。在这里还能**转为条目**（进当前项目，没有当前项目就进「未归类」）或删除，并能看到 App、时长和输入方式。按键：`↑` `↓` 切换，`⌘C` 复制，`⌫` 删除（`⌘Z` 撤销），`⌘F` 搜索。还没有听写时，这一页会告诉你按哪个键，听写关着或还听不到按键时也会说明。历史默认保留 30 天（可在设置里改）；录音转写完就删，除非你选择保留。
- 录屏时听写不可用，因为麦克风正被录屏占用。听写和语音备注不会同时听：先开始的那个用完麦克风，另一个才能用。
