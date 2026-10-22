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

In Auto mode each snap or voice note hangs under the island on a thin thread, like a wind chime. They tuck away when
you're not looking and come back when you point at the island.

- **Drag a card onto a project** in the island's list to file it there and start processing.
- Drag it onto **Unassigned** to process it without a project, or choose **Let AI sort** to process all the cards
  and let Blurt file each item where it belongs.
- Hover to read the note, double-click to edit it, click to copy the image, drag it out to drop the file anywhere,
  or click × to throw it away.

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

语音在你的电脑上转写。除非你选了云端语音服务，内容不会离开这台电脑。

### 2. 项目和当前项目

**项目**就是你电脑上的一个文件夹，跟编辑器打开文件夹一样：在主窗口里「打开文件夹…」（`⌘O`），或者把文件夹拖进来。
条目存在这个文件夹的 `.blurt/` 里，口喷鸡会自动让它不进 git。

**当前项目**决定新捕获去哪。按 `⌥⇧O`（或点岛上的项目名）切换：
- **某个项目**：截图和语音直接进这个项目，马上开始整理。
- **自动**：捕获先挂成卡片（见下），等你决定放哪。

录屏不会挂卡片：结束就开始整理，每一条按内容归到对应的项目。分不出来的进「**待分配**」，之后在侧栏里拖到项目上就行。

### 3. 挂着的卡片

自动模式下，每张截图、每段语音用一根细线挂在岛的下方，像风铃。你不看的时候它们会收起来，鼠标移到岛上又会垂下来。

- **把卡片拖到岛上列出的某个项目**：归到那个项目，开始整理。
- 拖到「**待分配**」：先整理，不归项目；或者点「**交给 AI 分**」：把所有卡片一起整理，每一条由口喷鸡归到合适的项目。
- 悬停看备注，双击改备注，单击复制图片，拖出去就是一个文件，点 × 扔掉。

整理时岛上会出现一个小蛋；蛋破壳了，新条目就到了收件箱。

### 4. 审核

主窗口（`⌥⇧B` →「打开口喷鸡」）侧栏最上面是**收件箱**，下面是你的项目。

收件箱里是需要你看的，标题会直接告诉你：「需要你看的：3 条新的 · 2 条待验证」。选中一条，右边是它的全部内容——原话、截图、步骤、
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

收件箱 = 新 + 待验证：标了不做、完成或丢弃的条目会立刻离开收件箱。agent 永远不能把条目标为完成——agent 说「修好了」，一律是待验证。

点条目前面的状态圆环就能改状态，菜单里只列现在说得通的几步。列表里的快捷键：`A` 要做 · `D` 标为完成 ·
`R` 往回（退回、收回、重新打开或恢复，哪个适用就是哪个）· `W` 不做 · `X` 丢弃 · `S` 打开菜单。
