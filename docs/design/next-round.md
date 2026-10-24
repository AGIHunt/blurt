# 下一轮方案（v0.7，待 review）

2026-10-22，根据 v0.6 试用反馈和两轮讨论整理。各工作包按文末「v0.7 契约」实现（它和「决定」一起优先于正文）。

## 决定（2026-10-22 review 后定稿，优先于下文）

- **项目 = 打开本机一个文件夹**（同 VS Code / Claude Code）：最近打开列表、拖文件夹进来；非代码项目也就是一个普通文件夹。
  条目存在 `<项目>/.blurt/`（Markdown），**不进 git**：自动写进该仓库的 `.git/info/exclude`（不改用户的 .gitignore）。
  没归属的捕获在全局 `~/Blurt/inbox/`。
- **tmux**：macOS / Linux 用 tmux（没装就提示安装，或随 App 打包）；没有 tmux 时退回普通 pty（关掉 App 会话就没了）；Windows 用 ConPTY。
  **一个项目一个 tmux 会话，每次派发 = 会话里的一个窗口**（窗口以条目编号命名，状态逐窗口提醒）。tmux 是单个服务进程
  （本机实测常驻约 4 MB），多会话 / 多窗口的开销可以忽略，大头是 agent 进程本身。
  批量派发两种：**一起处理**（一个窗口一个对话，默认）/ **并行**（每条一个窗口 + 各自 worktree）。
  不用 worktree 时，同一项目开多个窗口会**提醒**「同时改文件可能冲突，建议用 worktree」，不禁止。
- **MCP 已经有**（v0.6 的 `mcp_server.py`，7 个工具，Codex 实测通过）；设置 → Agent 可一键装进 Claude Code / Codex，
  外部 agent 装了就能自动回报状态。
- **鸡爪卡片 = 还没归属项目的捕获**：选了当前项目时，捕获被鸡爪直接抓回刘海岛（归档并开始整理），不挂着；没选项目时卡片
  挂在上方，拖到刘海岛展开的项目列表上 = 归属并开始整理；卡片多时「交给 AI 分」。录屏不挂卡片，结束即整理，按条分项目。
  截图飞上去、摆动、悬停抬起、拖出、掉落等动效保留。
- **2026-10-22 更新：不要鸡爪。** 从上往下伸的鸡爪看着瘆人，改成**细线**：没归属的卡片用一根细线挂在刘海岛下沿，线从岛里垂下来。
  线头一个小圆扣，用品牌色。几张卡就是几根长短略有错落的线，像风铃，不是一根横绳，避开晾衣架的样子。动效全保留：
  - 飞上去挂住
  - 随线轻摆
  - 悬停时线收短、卡片抬起
  - 拖出时线拉长再断开
  - 删除时线松开、卡片掉落
  - 整理时线收回岛里

  品牌形象（完成提示里的小鸡等）用 codex 生成可爱的插画方案做参考，再做成干净的矢量；捕获流程里不出现爪子。
- **本地语音识别按机器自适应**：根据芯片 / 内存 / GPU 和用户语言推荐并自动选择模型（例：高配 Apple Silicon 上多语种用
  Whisper large-v3-turbo（MLX）等，中英日韩粤可继续用 SenseVoice），给出识别质量 / 速度 / 占用对比；限制并发和线程、
  低优先级运行，给系统留余量；多语种必须覆盖（面向全球）。
- **全球化**：UI、文案、动效都按全球用户设计：完整的 en / zh-Hans 本地化 + 可扩展的本地化结构（日期 / 数字 / 复数）、
  不依赖中文语境的视觉隐喻、精致的排版与动效。

## 0. 定位

Claude Code、Codex 是「干活的」：一个文件夹里跑各种会话。口喷鸡是「帮你整理要干什么活」：把你说的、截的、录的整理成一件件事，归到对应项目，再交给 agent 去做。

交出去有两条路，都要好用：

- **在口喷鸡里做**：内嵌终端，在一个 tmux 会话里跑 Claude Code 或 Codex，状态实时可见。
- **交给你自己的 Claude Code / Codex 桌面端**：复制一段指令贴过去，状态由你手动标，接了 MCP 的也能自动回报。

---

## 1. 条目的「来源、归属、状态」（先定数据模型，后面都靠它）

### 1.1 来源（为团队协作预留，这轮先记录不做分派）

每条记录：

- `source.type`：recording / snap / voice / url / import
- `source.by`：谁说的，默认本机用户，团队版换成成员
- `source.role`：产品、测试、开发、调研…，可选
- `source.app`、`source.url`、`source.session`：从哪个录屏或截图批次来

下一轮的团队协作就基于这几个字段，加上 `assignee`、`module` 做分派。

### 1.2 归属哪个项目：三层，按优先级

1. **先指定**：刘海岛上始终显示「当前项目」，点它或按快捷键切换。切了之后，录屏、截图、语音都默认归它。
2. **AI 分**：当前项目是「自动」时（默认），整理时 AI 按项目的名称、描述、文件夹和模块，给每条建议一个项目并附置信度。低置信度的进「待分配」。
3. **事后改**：审核时每条都有项目下拉，可以一次拖一批到某个项目。改过的记成用户决定，AI 不再覆盖。

项目本身 = 名称 + 描述 + 可选的本机代码文件夹（没有文件夹就是纯记录型项目，比如「日常想法」）+ 默认 agent + worktree 偏好。

### 1.3 状态：分开「审核」和「处理」，处理状态不假装知道

| 维度 | 取值 | 谁来改 |
|---|---|---|
| 审核 | 待审 / 保留 / 丢弃 | 用户 |
| 处理 | 待处理 → 已交出（交给谁：口喷鸡会话 / 外部复制）→ 进行中 → **待验证** → 已完成；也可以标「不处理」 | 见下 |

- 在口喷鸡会话里跑的：自动推进到「待验证」。agent 说修好了不算数，**你确认才变「已完成」**。
- 复制给外部 agent 的：停在「已交出」，你手动标后续状态。如果那边装了口喷鸡的 MCP，agent 调 `mark_fixed` 也会自动变成「待验证」。
- 列表上用一个状态小圆环表示（空心 / 半满 / 满 / 打勾），不画在蛋上。

---

## 2. 在口喷鸡里做：内嵌终端 + tmux 会话

- **会话**：每次派发（一条或勾选一批）= 一个 tmux 会话 `blurt-<项目>-<编号>`，里面跑**交互式**的 Claude Code 或 Codex（不是后台 `-p`），初始提示词已经填好。你随时能接手打字。
- **内嵌终端**：
  - macOS 用 SwiftTerm，Windows/Linux 用 xterm.js。主窗口右侧 attach 到选中的会话。
  - 能新建会话（选项目、agent、要不要 worktree），也能「在系统终端打开」（Terminal / iTerm / Ghostty）。
  - 关掉口喷鸡，会话照常在跑；再开时自动重新连上。
- **worktree 可选**：项目设置里定默认值（默认开），派发时可以临时改。
  - 开：在 `<项目>/../.<项目>-worktrees/blurt-<编号>`（位置可配）建 worktree 和分支 `blurt/<条目简称>`。跑完给你看 diff，选合并、开 PR 或丢弃。
  - 关：直接在项目目录里改，同一项目同时只允许一个这样的会话。
- **状态打通（这轮的亮点）**：
  - **Claude Code**：启动时用 `--settings <临时文件>` 注入只对这个会话生效的 hooks，不改你的全局配置。监听这几类事件：
    - SessionStart（开始）
    - Stop（一轮结束，在等你）
    - Notification（要权限 / 在问你问题）
    - SessionEnd（退出）
    
    每个 hook 都通过 `blurt hook` 把事件告诉口喷鸡。
  - **Codex**：用 `-c notify=[…]` 按次注入，拿到「这一轮完成」的事件。Codex 没有「在等你确认」这类事件（待实测），就用终端输出做兜底判断。
  - 口喷鸡统一显示每个会话「运行中 / 等你回答 / 本轮完成 / 已退出 / 出错」，每条都标明项目和条目。会话多了也知道提醒来自哪里，点一下直接跳到对应终端。
- **agent 范围**：这轮先支持 Claude Code 和 Codex。国产的（Kimi Code 等）有交互式命令行的就接上，状态只有「运行中 / 已退出」。不好接的先不接，但保留「复制给它」。

## 3. 交给外部 agent：复制指令

- 每条或每批生成一份交接文件 `~/.blurt/handoff/<编号>.md`，放在固定目录，不放 tmp，以免被清掉。内容包括：
  - 标题、你的原话、实际效果和预期效果、复现步骤、疑似代码位置；
  - 截图用**绝对路径**引用（Claude Code、Codex 都能直接读本机图片）。
- 「复制指令」复制的是一句话，例如：

  ```
  请处理这 3 个问题，详情和截图见 /Users/john/.blurt/handoff/H-0012.md。做完后如果有 blurt MCP，调用 mark_fixed。
  ```

- 另有「复制全文」，把 Markdown 正文直接复制过去，图片仍用路径。
- 状态变成「已交出（外部）」，之后手动标。

## 4. 存储改为 Markdown

- **一条一个文件**：`<项目>/items/<编号>-<简称>.md`。
  - YAML 头放结构化字段（kind、状态、来源、项目、时间、截图路径、fix 记录）。
  - 正文放原话、描述和步骤，图片用相对路径，任何 Markdown 工具都能打开。
- **库的位置**（需要你拍板）：
  - **A**：统一放在 `~/Blurt/<项目>/`，代码项目只记录它的文件夹路径。适合纯记录型项目，也方便以后做团队同步。
  - **B**：代码项目放在仓库里的 `<repo>/.blurt/`，能跟着 git 和团队走；纯记录型项目放在 `~/Blurt/`。
  - 我建议默认 A，每个项目可以单独改成 B。
- **索引和搜索**：SQLite 只做索引，随时能从 Markdown 重建。`items.py` 仍然是唯一的写入口，改成写 Markdown，同时继续支持读旧的 `items.json`，并提供一键迁移。
- **原始素材**：录屏和截图批次的原始素材仍放在会话目录里，Markdown 引用它们。

## 5. 输入方式

| 输入 | 快捷键（可改） | 说明 |
|---|---|---|
| 录屏 | ⌥⇧R | 不变 |
| 截图 | ⌥⇧A | 截完说一句或打字 |
| **语音输入（新）** | ⌥⇧V 按一下开始，静音自动结束；也支持按住说话 | 不录屏，只录音转文字。说完生成一条记录，归当前项目 |
| 切换当前项目 | ⌥⇧O | 在刘海岛上弹出项目列表 |

**录屏中截图，已确认现状**：快捷键 ⌥⇧A **不暂停**。悬浮条上的 📸 按钮**第一次点是截图，之后再点却变成「打开备注并暂停」**，同一个按钮干两件事，所以你记得「会暂停」。

改法建议：**快捷键 = 只截不停；点按钮 = 截图并暂停，弹出备注框，填完继续**。两种意图分开，按钮不再一键两义。

## 6. 视觉与动效

- **种类图标**：问题、想法、笔记、任务改用常见图标（bug、灯泡、文档、勾选清单），每种一个颜色，不再用蛋。「蛋」只留在品牌和动效里（整理中、孵化），不承担种类和状态。
- **刘海岛**（屏幕顶部中间）：录屏控制条、当前项目、语音输入、捕获计数合成一个组件，悬停展开。Windows/Linux 做成顶部居中的浮动胶囊，功能一样，动效弱一些。
- **鸡爪抓卡片**（去掉绳子）：
  - **卡片 = 一次「还没整理的捕获」**：截图加备注、一段语音输入、录屏中 AI 识别出的一个问题。有图显示缩略图，没图显示一行文字。它代表「已经记下、等着整理」的东西，不是截图展示柜。
  - 每张卡被一只从屏幕上方伸下来的鸡爪抓着。截图或语音结束时，卡片飞上去被爪子接住，保留现在的弹簧、摆动、悬停抬起、拖出和掉落动效。
  - 点「整理」后，爪子把卡片一起拽回刘海岛：被收走，变成条目。
  - **录屏期间不挂卡片**，以免挡住你演示。识别到的问题只在刘海岛里计数，结束后再一起展示。
- **孵化中**：只在「点了整理、正在处理那批卡片」时出现，位置就在那批卡片收进去的刘海岛上。完成即消失。
- **完成提示里的鸡**：重画成高质量的插画风（多层矢量，几种表情），配合「待验证 / 已完成」出现，不再每件事都弹。
- **不自动弹审核**：只在刘海岛和菜单栏上 +1，主窗口「收件箱」有待审标记，点了才看。审核嵌进主窗口。

## 7. 这轮范围

**做**：

- 1 数据模型（来源、归属、状态）
- 2 内嵌终端 + tmux 会话 + worktree 可选 + 状态打通（Claude Code、Codex）
- 3 复制给外部 agent
- 4 Markdown 存储和迁移
- 5 语音输入、切换项目、截图按钮改义
- 6 全部视觉改动
- v0.6 反馈里的明确改动：任务状态、降密、不弹窗、主窗口首页改成「收件箱 + 项目」

**下一轮**：团队分派（基于 1.1 的字段）、网址探索、手机端、Windows/Linux 真机验证。

**删除和收敛**：

- 绳子物理（`Rope.swift`）
- 独立审核窗口和自动弹出
- 按种类区分的彩蛋图标
- 后台 `-p` 方式的「交给 agent 修」：被 tmux 会话替代，headless 只留给「整理」用

## 8. 要你拍板

1. 库的位置：A（统一放 `~/Blurt`）还是 B（代码项目放进仓库），或者按我建议「默认 A、可单独改 B」？
2. 截图按钮改义（快捷键不停，按钮暂停并写备注）行吗？
3. 鸡爪抓的卡片 =「还没整理的捕获」，录屏期间不挂卡，这样贴合吗？

---

## v0.7 契约

2026-10-22 定稿。8 个工作包（P1–P8）在各自的 worktree 里按这里实现，彼此不沟通；这里没写的细节由拥有该文件的包自己定。
要改契约：先在 `feat/live-snap` 上改本节并提交，再通知其他包。每个包可以在**自己负责的 K 节末尾**追加「细则（Pn）」，不改别的节。
沿用 `docs/design/desktop-app.md` §5 的 C1–C8，凡是和本节冲突的以本节为准（主要是 C1 的存储、C3 的表结构、C6 的文档形状）。

通用约定：
- **时间**：落盘的时间一律 ISO 8601 带时区偏移（`2026-10-22T10:15:00+08:00`）；只有 `_user` 里的值沿用 epoch 秒（内部用）。
- **路径**：给宿主和 agent 看的路径一律绝对路径；只有 Markdown 正文里的图片链接和 front-matter 里的 `frames[].path` / `clip` 用相对路径（相对 store 根）。
- **CLI**：Python 脚本每次调用 stdout 输出一行 JSON；成功带 `"ok": true`；失败 `{"ok": false, "error": "<英文，给日志>", "code": "<机器码>"}`，
  同时写 stderr，退出码 1（参数或数据）/ 3（等锁超时）/ 4（缺依赖，比如没装 tmux）。UI 按 `code` 本地化，不直接显示 `error`。
- **环境变量**：`BLURT_HOME`（默认 `~/.blurt`）、`BLURT_WORKSPACE`（默认 `~/Blurt`）照旧；新增 `BLURT_JOB`、`BLURT_PROJECT`、
  `BLURT_TMUX_SOCKET`（默认 `blurt`）。测试一律用临时的 `BLURT_HOME` / `BLURT_WORKSPACE` 和 `BLURT_TMUX_SOCKET=blurt-test-<name>`。
- **不用 emoji 和文字字符当图标**（`check_glyphs.py`）；用户可见文案一律走 K10 的本地化，en 和 zh-Hans 都要齐。

### K1 · Markdown 条目存储

**store** = 一个存条目的目录。每个项目一个：`<项目文件夹>/.blurt/`；没归属的条目在 inbox store：`$BLURT_WORKSPACE/inbox/`（默认
`~/Blurt/inbox/`，Blurt 自己的文件夹，所以不加点）。两者布局相同：

```
<store>/
  store.json                {"schema": 3, "project": "<project id>", "key": "BA", "next": 13}   条目编号计数器（锁内读写）
  .lock                     store 锁：分配编号、写 / 移动这个 store 里的任何条目都先拿它（flock / msvcrt，同 items_lock）
  items/<id>-<slug>.md      一条一个文件，例：items/BA-12-登录按钮点击后无响应.md
  assets/<uid>/             这条的截图、笔迹图、片段：1.png、1.marked.png、clip.mp4（从会话目录硬链接，跨卷就复制）
  sessions/<ts>[-shots|-voice]/   原始素材（录屏、截图批次、语音），布局同 v0.6（meta.json、recording.mp4、shots.jsonl、shots/、live/、frames/…）
  config.json, lenses/      不变（仓库级配置、自定义 lens）
```

- **不进 git**：`store.py` 每次创建或打开一个项目 store 时（`projects.py add`、`items.py` 第一次写、`migrate`），如果项目文件夹在
  git 工作区里（`git rev-parse --git-common-dir`，兼容 worktree），确保 `<common-dir>/info/exclude` 里有一行匹配它，写法是
  `/<相对仓库根的路径>/.blurt/`，前面一行注释 `# blurt: local items and recordings (never committed)`。已有匹配就不写；
  不改 `.gitignore`。如果 `.blurt/` 下已经有被跟踪的文件，`doctor.py` 报警告，不自动取消跟踪。
- **编号**：`id = "<KEY>-<n>"`。KEY 是项目的短码（K2），inbox 固定为 `IN`；n 从 1 起，只增不复用。id 只是给人看的标签，
  **uid（ULID，C1 规则不变）才是身份**：条目换项目时 id 变、uid 不变，旧 id 记进 `aliases`。
- **文件名**：`<id>-<slug>.md`。slug 由创建时的标题生成：NFKC、小写、保留各语种的字母和数字、其它字符连成一个 `-`、去掉首尾 `-`、
  最长 48 个字符（按字符截断，不切半个字）；标题为空或 slug 为空时就是 `<id>.md`。**改标题不改文件名**。按 id 找文件用 glob `items/<id>-*.md` 加 `items/<id>.md`。
- **写入**：只有 `items.py`（及它用的 `store.py`）写 `.md`。原子写（同目录临时文件 + `os.replace`），锁内读改写。
  别的进程（应用、agent、用户的编辑器）读文件随意；用户手改文件也合法，下次读取时按下面的规则解析。

**front-matter**：`---` 开头和结尾。每个键一行，值是 JSON（JSON 是 YAML 1.2 的合法子集，任何 Markdown 工具都能显示）；
字符串值如果匹配 `^[A-Za-z0-9][A-Za-z0-9_.:/+-]*$` 且不是 `true false null yes no on off ~` 或数字，就不加引号。
读取时：值以 `{ [ "` 开头或是 JSON 数字 / true / false / null → `json.loads`；否则当普通字符串（去掉首尾空白）。
别的工具写进来的块状 YAML：只认「`key:` 后面跟若干行 `  - 标量`」这一种（读成字符串列表），其它解析不了的，这个文件在索引里标
`parse_error`、`items.py` 拒绝写它（`code: "unparseable"`），绝不覆盖。

键的顺序固定（写入时按这个顺序，之后的未知键按字母序，读到的未知键原样保留）：

```yaml
schema: 3
id: BA-12
uid: 01JB7ZK3Q4M8W2E5R6T9Y0ABCD
kind: issue                       # issue | idea | note | task | <自定义 lens>
title: "登录按钮点击后无响应"
state: new                        # 唯一的状态（K3 改版）：new | todo | handed_off | in_progress | to_verify | done | wontfix | discarded
work: {"to": …, "agent": …, ...}  # 最近一次交出 / 处理的细节，K3；没交出过就没有这个键
project: 3f2a9c1b7e44             # 项目 id（K2），inbox 里的条目是 inbox
project_by: capture               # capture（捕获时就有当前项目）| ai | user | migrate
project_confidence: null          # ai 分的置信度 0–1
suggested_project: {"id": "…", "confidence": 0.58, "reason": "…"}   # 低于阈值时只建议不移动；没有就不写
created: "2026-10-22T10:15:00+08:00"
updated: "2026-10-22T10:20:41+08:00"   # 每次 items.py 写入都更新
source: {"type": "recording", "by": "john", "role": null, "app": "Chrome", "url": "https://…",   # 示例为排版折行，实际写在一行
         "session": "/Users/john/workspace/bug-agent/.blurt/sessions/20261022-101500", "shot": null, "local_id": "I-001"}
language: zh
severity: high                    # 以下是 lens 字段（issue：module owner severity type code_refs；task：owner due…）
module: auth
owner: ""
assignee: null                    # 预留给下一轮团队分派，这轮只读写不显示
tags: ["登录"]
confidence: high
time: {"start": 12.4, "end": 30.1}
frames: [{"path": "assets/01JB…/1.png", "t": 14.2, "caption": "登录按钮是灰的"}]   # 相对 store 根；第一张是主图
clip: assets/01JB…/clip.mp4
code_refs: ["web/src/Login.tsx:42"]
exported: {}
merged_into: null                 # 用户把它并进了哪条（uid）；并掉的条目 state 为 discarded
merged_from: []                   # uid 列表
aliases: ["IN-3"]                 # 以前的 id（换项目时追加）
work_history: []
_user: {"title": 1792560123.4}    # 用户改过的字段 → epoch；agent 写入不覆盖（同 v0.6）
```

- `source.type`：`recording | snap | voice | url | import | service`；`source.by` 默认本机用户名（`meta.json.author`，没有就是
  `getpass.getuser()`）；`source.role` 这轮总是 null；`source.session` 是原始会话目录的绝对路径（纯手动新建的条目为 null）；
  `source.shot` 是 `shots.jsonl` 里的 `n`；`source.local_id` 是 agent 在会话草稿里给它的号（`I-001`）。
- v2 的 `fix` / `fix_history`、早期 v0.7 的 `status` + `work.state` 不再写；读到旧文件时按 K3 的迁移规则换成 `state`（+ `work` / `work_history`）。

**正文**：一组 `## 标题` 小节，没有 H1（标题在 front-matter 里）。写入时按条目的 `language` 选标题文字（`zh*` 用中文，其它用英文），
读取时两套标题都认（不分大小写、去掉首尾空白）。字段 ↔ 标题：

| 字段 | en | zh | 格式 |
|---|---|---|---|
| `quote` | Said | 原话 | 每行 `> ` 开头 |
| `summary` | Summary | 概要 | 段落 |
| `why` | Why | 为什么 | 段落 |
| `inspired_by` | Inspired by | 灵感来源 | 段落 |
| `actual` | Actual | 实际效果 | 段落 |
| `expected` | Expected | 预期效果 | 段落 |
| `steps` | Steps | 复现步骤 | 有序列表 → 字符串列表 |
| `details` | Details | 详情 | 原样 Markdown |
| `next_steps` | Next steps | 下一步 | 无序列表 → 字符串列表 |
| `open_questions` | Open questions | 待定问题 | 无序列表 |
| `questions` | Questions for you | 需要你确认 | 无序列表 |
| `answer` | Your answer | 你的回答 | 段落 |
| `frames`（生成） | Screenshots | 截图 | `![caption · m:ss](../assets/<uid>/1.png)`，每次写入重新生成，读取时忽略 |

自定义 lens 的字段：含换行或超过 200 字符的字符串放正文，标题就是字段名本身（`## competitor_notes`），按字段名读回；其余放 front-matter。
不认识的小节原样保留在原位置（读进 `_sections`，写回时照抄）。小节顺序：quote、summary、why、inspired_by、actual、expected、steps、
details、next_steps、open_questions、questions、answer、自定义字段、未知小节、frames。

**批次文件** `<session>/batch.json`（原来 items.json 里会话级的东西；审核页的「一批」= 一个会话）：

```jsonc
{"schema": 3, "session": "20261022-101500", "title": "官网改版的一些想法", "digest": "## 总览…", "language": "zh",
 "project": "3f2a9c1b7e44" | null,        // 这个会话的默认项目（捕获时的当前项目；auto 时为 null）
 "processing": true, "reviewed": false, "agent_at": "…ISO…", "source_video": "recording.mp4" | null,
 "items": ["<uid>", …],                   // 审核页的顺序
 "local": {"I-001": "<uid>", …},          // agent 草稿号 → uid，旧的 `items.py patch SESSION I-001` 靠它定位
 "removed": {"<uid>": "<into uid>" | ""}} // 用户并掉 / 删掉的（对应 v2 的 _removed）
```

**agent 的处理流程不变**（SKILL.md §3）：agent 仍然先整份写 `<session>/items.json`（v2 格式），然后：
- `items.py ingest SESSION`：把 items.json 里的每条变成 Markdown 条目，写 batch.json，把 items.json 改名为 `items.ingested.json`
  （留作排查，不删）。归属：条目自带 `project` → 用它；否则会话的 `batch.project` / `$BLURT_PROJECT`；都没有 → 先进 inbox，再跑
  `projects.py route --apply`（K2）。会话目录下的 `frames/…` 等文件复制进各自 store 的 `assets/<uid>/`。
- **之后任何 `items.py` 写命令遇到还没 ingest 的 items.json，都先自动 ingest**（所以按旧 SKILL.md 干活的 agent 也能用）。

**items.py v3**（P1）。`REF` = uid | `KEY-n`（含 aliases）| `.md` 的路径；旧写法 `SESSION ID`（第一个位置参数是存在的目录）照常支持，
ID 可以是草稿号 `I-001`（经 `batch.local`）或 uid。

```
items.py ingest     SESSION                                  → {"ok","items":[{"local","uid","id","path","project"}],"inbox":n}
items.py add        (SESSION | --project P|inbox) --json '{…}' [--after REF]   → {"ok","id","uid","path"}
items.py patch      REF | SESSION ID  --set k=V … [--unset k …] [--force]     (同 v2：保留 _user，PROTECTED 多了 state restore_to work work_history project path)
items.py set-frames REF | SESSION ID  PATH[@T][#CAPTION] … [--append]          PATH 相对 SESSION 或绝对；复制进 assets/<uid>/
items.py done       SESSION                                  batch.processing 去掉
items.py get        REF | SESSION ID                         → {"ok","item":{…, "path","store","project"},"session":abs|null}
items.py list       [SESSION] [--project P|inbox] [--kind K]… [--state S]…（旧的 --status / --work / --fix-state 换算成 state）   → {"ok","items":[…]}
items.py state      REF … (--state S | --action A)（旧名 work，K3）
                    [--to session|external] [--agent A] [--job J] [--handoff H] [--claim fixed|wontfix]
                    [--commit SHA] [--pr URL] [--note TEXT] [--by user|agent|app]   → {"ok","items":[{"uid","id","state","work"}]}
items.py fix        REF | SESSION ID --state fixing|fixed|wontfix|reopened …    v2 别名，按 K3 映射成 state
items.py move       REF … --project P|inbox [--by user|ai] [--confidence X] [--reason T]   → {"ok","moved":[{"uid","from","to","id","path"}]}
items.py doc        SESSION | --project P|inbox [--state S]… [--kind K]…     → {"ok","doc":{…},"etag"}
items.py poll       (同 doc 的范围) --etag E                  → {"ok","etag"} 或 {"ok","doc","etag"}
items.py user-ops   SESSION | --project P  (--json OPS | --stdin) [--confirm]  → {"ok","etag","doc"}
items.py migrate    [--all | SESSION … | --root DIR] [--dry-run]               → {"ok","sessions":n,"items":n,"skipped":[{"dir","why"}]}
items.py path       REF                                      → {"ok","path","store","project","uid","id"}
items.py ensure-uids SESSION                                 v2 遗留会话用；已迁移的会话什么都不做
```

- 写命令的 agent/job 默认值：`--agent` ← `$BLURT_AGENT`，`--job` ← `$BLURT_JOB`（`$BLURT_RUN_ID` 作为旧别名）。
- 状态变化的合法性见 K3 的动作表；不合法 → `code: "bad_transition"`。
- 每次写成功后进程内调 `index.update_paths([...])`（替代 `update_sessions`，失败忽略，规则同 C2）。
- **doc**（C6 审核组件吃的文档，形状和 v2 的 items.json 一样，组件改动最小）：
  `{"schema": 3, "scope": {"session": abs} | {"project": id, …filters}, "title", "digest", "language", "processing", "reviewed",
  "agent_at", "source_video": abs|null, "_video": bool, "items": [条目（front-matter + 正文字段，**所有路径都是绝对路径**，
  加 `path`、`project`、`_project: {id, name, key}`）], "_removed": {uid: into}, "projects": [{id, name, key, path}]}`。
  会话范围按 `batch.items` 排序；项目范围按 `created` 倒序。
  `etag = file_etag(json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode())`。
- **user-ops**：op 的 `id` 可以是 uid（组件应该一律用 uid，因为换项目会改 id）或 id。op 种类：
  `set` / `remove` / `add`（同 v2）；`set` 里的 `project` 键 = 用户换项目（等同 `move --by user`，记进 `_user.project`，AI 以后不再改它）；
  新增 `{"op": "state", "id", "action" | "state", "note"?, "undo"?}`（K3；旧名 `work`）。返回值总是带合并后的 `doc`。
- **migrate**：v1/v2 会话（有 items.json、没有 batch.json）→ 对应 store：`<repo>/.blurt/sessions/S` → `<repo>/.blurt`；
  `$BLURT_WORKSPACE/recordings/S` → inbox store（会话目录原地不动，`source.session` 指向它）。uid 保留（含 legacy `L…`），按会话里的
  顺序分配新 id，`status` + `fix` → `state` + `work`（K3），`_removed` → `batch.removed`（被并掉的条目不生成文件），`project_by: migrate`。
  items.json 改名 `items.v2.json`。幂等：已有 batch.json 的会话跳过。应用每次启动跑一次 `items.py migrate --all`（后台，静默）。
- **review.py**（P1）：`review.py SESSION` 或 `review.py --project P`；`GET /api/items` 返回 doc（带 ETag）、`POST /api/items {ops}`、
  `POST /api/confirm`；文件走 `GET /files/<百分号编码的绝对路径>`，只放行已登记的 store、会话目录和 `$BLURT_HOME/handoff`；
  旧的 `/files/<相对会话路径>` 继续支持。

**index.db schema v2**（P1 写 `docs/contracts/index-schema.sql` 和 `index.py`，读者 P4 / P8 / mcp_server 照这里写查询）。
`meta.schema_version = '2'`；`index.py` 发现版本不同就删库重建（索引随时可重建）。

```sql
CREATE TABLE projects (
  id TEXT PRIMARY KEY,               -- K2 的项目 id；inbox 为 'inbox'
  path TEXT NOT NULL UNIQUE,         -- 项目文件夹（inbox：inbox store 本身）
  store TEXT NOT NULL UNIQUE,        -- <path>/.blurt（inbox：同 path）
  name TEXT NOT NULL, key TEXT NOT NULL, slug TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('inbox', 'folder', 'repo')),
  registered INTEGER NOT NULL DEFAULT 1,   -- 0 = 磁盘上发现的旧工作区，还没进 projects.json
  last_seen REAL
);
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,               -- "<project_id>:<会话目录名>"
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,   -- 会话目录所在的 store
  dir TEXT NOT NULL UNIQUE,
  mode TEXT NOT NULL CHECK (mode IN ('video', 'shots', 'voice')),
  title TEXT, author TEXT, created REAL, duration REAL,
  shot_count INTEGER NOT NULL DEFAULT 0,
  card_count INTEGER NOT NULL DEFAULT 0,   -- 还没归属项目、还没整理的捕获（= 刘海岛下挂的卡片），K7
  item_count INTEGER NOT NULL DEFAULT 0,   -- source.session = dir 的未删除条目
  processed INTEGER NOT NULL DEFAULT 0, processing INTEGER NOT NULL DEFAULT 0, reviewed INTEGER NOT NULL DEFAULT 0,
  legacy INTEGER NOT NULL DEFAULT 0,       -- 还没迁移的 v1/v2 会话（只读显示）
  items_mtime REAL, shots_mtime REAL, indexed_at REAL NOT NULL
);
CREATE TABLE items (
  uid TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  path TEXT NOT NULL UNIQUE,         -- .md 的绝对路径；legacy："<items.json 绝对路径>#<id>"
  item_id TEXT NOT NULL,             -- "BA-12"（legacy："I-001"）
  kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', quote TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL,               -- K3：new | todo | handed_off | in_progress | to_verify | done | wontfix | discarded（schema v3）
  work_to TEXT, work_agent TEXT, work_job TEXT, work_claim TEXT,
  severity TEXT, owner TEXT, module TEXT, assignee TEXT, confidence TEXT,
  source_type TEXT, source_by TEXT, source_app TEXT, source_url TEXT,
  project_by TEXT, project_confidence REAL, suggested_project TEXT, suggested_confidence REAL,
  t_start REAL, primary_frame TEXT, frame_count INTEGER NOT NULL DEFAULT 0, has_code_refs INTEGER NOT NULL DEFAULT 0,
  exported TEXT NOT NULL DEFAULT '{}', user_edited INTEGER NOT NULL DEFAULT 0, parse_error TEXT,
  created REAL NOT NULL, updated REAL NOT NULL, mtime REAL,
  UNIQUE (project_id, item_id)
);
CREATE INDEX items_updated ON items(updated DESC);
CREATE INDEX items_proj ON items(project_id, state);
-- items_fts（title, quote, body, tags；trigram）和三个触发器与 v1 相同
```

- `index.py update PATH …` 接受 `.md` 文件、store 目录、会话目录（删掉的路径 → 删行）；`index.py scan` 的范围 = projects.json 里的项目、
  inbox store、`$BLURT_WORKSPACE/recordings`（旧）、`--root`。Python API：`update_paths(paths)`、`scan(roots, full)`、`search(...)`。
- `index.py search` 的筛选：`--project ID|路径|名字|inbox`（`--workspace` 作为别名保留）、`--state S`（可重复；旧的 `--status` / `--work` 换算成 state）、`--kind`、
  `--session`、`--source-type`、`--fix-state`（旧别名，按 K3 映射）；排序 `updated|created|t_start|title`。
  **ItemRow v2** = `{uid, project_id, project_name, project_key, session_id, session_dir, path, item_id, kind, title, state,
  work_to, work_agent, severity, primary_frame, created, updated, snippet, suggested_project}`。查询词规则同 C3。
- **监听**：宿主监听每个 store 的 `items/` 和 `sessions/`（FSEvents / notify，防抖 300 ms），变化后 `index.py update <路径>`。

**MCP**（P1，`mcp_server.py`）：7 个工具名和参数不变（不破坏已装好的用户），行为改为：`list_projects` 返回 `{id, name, key, path, kind,
open_items, unassigned}`（open = state ∈ new / todo / handed_off / in_progress）；`search_items` 加可选 `state: [str]`（`work_state` / `status` 照旧能用）；
`get_item` 的 item 带 `path`、`project`；`mark_fixed(uid, state)` 映射：`fixing` → `in_progress`，`fixed` → `to_verify`（claim fixed），
`wontfix` → `to_verify`（claim wontfix），`reopened` → `todo`；`job` 取 `$BLURT_JOB`。工具描述里写明「agent 说修好了只到待验证，用户确认才算完成」。

**细则（P1）**（实现：`scripts/store.py`、`items.py`、`index.py`、`review.py`、`mcp_server.py`）：
- **错误码**（`code`）：items.py `bad_args` `not_found` `no_project` `protected`（PROTECTED 字段）`user_only`（agent 不带 `--force` 改
  status 为非 draft）`bad_value` `bad_transition` `deleted`（丢弃的条目不能交出 / 开始）`merged`（get 一条被并掉的）`taken`（add 的 id / uid 已占用）
  `unparseable` `bad_json`（items.json / batch.json 解析不了，文件原样留着）`locked`（退出码 3）。
- **front-matter 引号**：除了契约的正则规则，数字开头且含 `:` 或 `-` 的字符串（日期、时间、`1:20`）也加引号，任何 YAML 读出来都还是字符串
  （和上面示例里 `created` 带引号一致）。块状列表只认 `key:` 后紧跟的 `  - 标量` 行。
- **正文转义**：字段文本里行首的 `## `（代码块外）写入时多加一个 `\`，读回时去掉；没闭合的 ``` 写入时补齐，免得吞掉后面的小节。列表项的续行
  缩进 = 该项标记的宽度，读回时只去掉这部分缩进。截图 alt 里的 `[` `]` 换成 `(` `)`。
- **assets 文件名**：`<n>[.marked].<ext>`（n 取目录里没用过的最小正整数，不复用）、片段 `clip[-n].<ext>`；同卷硬链接、跨卷复制。源文件不存在的
  帧保留为原来的绝对路径（不丢信息，下次 `set-frames` 修正）。条目换项目时 `assets/<uid>/` 整个搬走，帧的相对路径不变。
- **ingest 的归属顺序**：shots.jsonl 里该截图的归属行（`assigned_by` → `project_by`）> 条目自带的 `project`（agent 提议，见 K2 细则）>
  items.json 的 `project` / batch.project / `meta.json.project` / `$BLURT_PROJECT` / 会话所在的项目 store > inbox。项目 id、key、slug、名字都认，
  不认识的当没写。已 ingest 过的会话再出现 items.json：按草稿号对上已有条目，当 agent 的 patch 处理（保留 `_user`，不改 state），新的追加。
- **user-ops**：`remove` = state discarded（`restore_to` 记原状态）+ `merged_into`（into 的 uid，没有 into 为 null），并从 `batch.items` 拿掉、记进
  `batch.removed`；`add` 遇到已存在的 uid / id 就是撤销合并（字段照 op 恢复、`merged_into` 清空、放回 `after` 后面），否则新建。`merged_from`
  里的 id / 草稿号存成 uid。页面把 doc 给的绝对帧路径原样发回时，store 里的路径转回相对路径。未知 id 忽略（同 v2）。
- **doc** 多两个键：`project`（batch.project）和每条的 `store`。review.py 不再接受整份文档的 POST（400，v0.5 的旧页面）；`/files/` 同时认
  `/files/%2FUsers%2F…` 和 `/files//Users/…`（页面把 `files/` 和绝对路径直接拼起来），会话相对路径照旧；确认后的摘要多 `items: [{id, uid, path}]`，
  `file` 是 batch.json。
- **index**：多一个索引 `items_session ON items(session_id)`；解析不了的文件也有一行（`parse_error`，没有 uid 时 uid =
  `"X" + sha1(path)[:25]`，item_id = 文件名）；同一项目两个文件同一个 id（手工复制）时后来的 item_id 加 `~<uid 后 4 位>`。`index.py update` 也收会话里的
  `items.json` / `batch.json` / `shots.jsonl` / `meta.json`（= 它的会话）；search 多 `--sort title`。还没迁移的 v1/v2 会话，条目行挂在它将来所在的项目
  （store）下；`--root` 发现的未登记项目 `registered = 0`，key 用 store.json 的或默认规则算出的。
- **MCP**：`list_projects.unassigned` = inbox 行是它的条目数，项目行是 AI 建议归它、还在 inbox 里的条目数；`mark_fixed` 返回
  `{ok, uid, id, state, work, next}`；碰到还在 v0.6 会话里的条目（索引里 path 带 `#`）先 `items.py migrate` 那个会话。

### K2 · 项目 = 打开的文件夹

**注册表** `$BLURT_HOME/projects.json`（**不放 config.json**：config.json 有 Swift、Rust、Python 三个写入方各自整份写，项目列表放进去会互相覆盖；
projects.json 只有 `projects.py` 写，锁 `$BLURT_HOME/.projects.lock`，原子写。应用直接读文件并监听它）：

```jsonc
{"schema": 1,
 "current": "auto",                      // "auto" 或项目 id。录屏 / 截图 / 语音默认归它
 "route_threshold": 0.75,                // AI 分项目的置信度阈值
 "projects": [{
   "id": "3f2a9c1b7e44",                 // sha1(realpath(path)).hex[:12]，和 v1 索引的 workspace id 同一公式
   "path": "/Users/john/workspace/bug-agent",
   "name": "bug-agent",                  // 默认文件夹名
   "key": "BA",                          // 条目编号前缀：^[A-Z][A-Z0-9]{1,4}$，在注册表里唯一，"IN" 保留给 inbox
   "slug": "bug-agent",                  // ^[a-z0-9][a-z0-9-]{0,31}$，唯一；tmux 会话名用它（K5）
   "description": "",                    // 给 AI 分项目用，用户可写
   "default_agent": null,                // agents.json id；null = 全局默认
   "worktree": true,                     // 派发时默认开 worktree（不是 git 仓库时忽略）
   "worktree_root": null,                // null = <仓库根>/../.<仓库名>-worktrees
   "modules": [{"name": "review page", "paths": ["web/packages/review"], "description": ""}],   // 预留给分派，这轮只给 AI 分项目当提示
   "hints": {"domains": ["blurt.dev"], "apps": ["Blurt"]},   // 来源网址 / 应用命中 → 高置信度
   "opened": "…ISO…", "last_used": "…ISO…", "pinned": false}]}
```

- **key 的默认值**：文件夹名按 `-_ .` 和驼峰切词，取前 2–3 个词的首字母（`bug-agent` → `BA`）；只有一个词就取前 3 个字母（`airank` → `AIR`）；
  非拉丁字母的名字 → `P` + 两位数字；撞了就在后面加数字。项目里还没有条目时可以改 key。
- **slug 的默认值**：文件夹名转小写 ASCII，其它字符变 `-`；结果为空 → `p-<id 前 6 位>`；撞了加 `-2`。
- **inbox** 不在列表里，固定 `{"id": "inbox", "key": "IN", "name": 本地化的「待分配 / Unassigned」, "path": "$BLURT_WORKSPACE/inbox"}`。
- **迁移**：`projects.py migrate` 把 config.json 的 `record.workspaces` 登记成项目，`record.workspace`（不是默认工作区时）设为 current；幂等。
  之后 `record.workspace(s)` 不再读写（Swift `Workspaces.swift` 的 `currentWorkspace()` 等改由 ProjectStore 提供）。

**CLI**（P1，`projects.py`）：

```
projects.py list                           → {"ok","current","projects":[Row],"inbox":Row}
     Row = 注册表的项 + {exists, git: bool, store, open_items, unassigned?(仅 inbox)}，按 pinned、last_used 排序
projects.py add PATH [--name N] [--key K] [--description D]    打开文件夹：登记、建 store、写 git exclude → {"ok","project":Row,"created":bool}
projects.py remove ID                      只取消登记，绝不删 .blurt → {"ok"}
projects.py set ID --json '{patch}'        改设置（name description default_agent worktree worktree_root modules hints key pinned）→ {"ok","project":Row}
projects.py use ID|auto                    切换当前项目（并更新 last_used）→ {"ok","current"}
projects.py current                        → {"ok","current":"auto"|id,"project":Row|null}
projects.py resolve PATH                   PATH 属于哪个项目（最深的那个）→ {"ok","project":Row|null}
projects.py route --items REF … [--apply] [--threshold X] [--agent ID] [--no-llm]
     → {"ok","suggestions":[{"uid","project":id|null,"confidence","reason","by":"rule"|"llm"}],"moved":[uid…]}
projects.py migrate                        → {"ok","added":n,"current"}
```

**AI 分项目**（`route`）：先规则（`code_refs` 的路径只在一个项目里存在 → 0.95；`source.url` 的域名或 `source.app` 命中 `hints` → 0.9；
`module` 命中 `modules[].name` → 0.8），没命中再问小模型（`agents.py command <id> headless`，和 live 草稿同一个模型和超时 60 秒；
输入是各项目的 name / description / modules 和条目的 title / quote / source，输出 `{project|null, confidence, reason}`）。
`--apply`：≥ 阈值 → `items.py move --by ai`；< 阈值 → 留在 inbox，写 `suggested_project`。`_user.project` 存在的条目永远跳过。
route 由 `items.py ingest` 在 auto 模式下调用（后台、写 K4 的 route 任务）；失败只是条目留在 inbox。

**捕获时的归属**：current = 项目 X → 会话写进 X 的 store、条目 `project_by: capture`；current = auto → 会话写进 inbox store，
录屏整理完按条 route；截图和语音变成卡片等用户分（K7）。录屏中途在刘海岛上换项目 → 更新该会话 `meta.json.project` 和 `batch.project`。

**细则（P1）**：
- **key 默认值**：按 `-_ .` 和驼峰切词时只留 ASCII 字母数字；开头不能是数字（去掉前导数字，不够 2 位就取名字里前 3 个拉丁字母，`3d-viewer` → `DVI`）；
  加数字后超过 5 位就截断。`opened` / `last_used` 精确到毫秒（最近列表靠它排序）。`projects.json` 多一个 `_migrated: true`（`migrate` 只在第一次把
  `record.workspace` 设为 current，之后用户改回 auto 不再被覆盖）。
- **错误码**：`not_found` `not_a_folder` `reserved`（Blurt 自己的文件夹）`bad_key` `key_taken` `key_in_use` `bad_field` `no_project` `locked`。
- **inbox 的名字**按 config `lang`（auto 跟随系统首选语言）给 Unassigned / 待分配。
- **agent 提议归属**（SKILL.md §3）：auto 模式下 agent 可以在 items.json 的每条里写 `project`（id 或 key）、`project_confidence`、`project_reason`；
  ≥ 阈值直接归过去（`project_by: ai`，记 `project_confidence`），< 阈值留在 inbox 并写 `suggested_project`（不再后台 route）；都没写的才后台 route。
- **route 的小模型**：`$BLURT_ROUTE_CMD`（从 stdin 读提示词、stdout 输出答案，测试和其它 agent 用）；否则按 `record.live_drafts_agent` → `record.agents`
  顺序找第一个装了的 claude / codex，`agents.py command <id> headless`（不带事件流和 MCP），claude 加 `--model <record.live_drafts_model>`；
  cwd = `$BLURT_HOME/tmp`，60 秒超时。一次调用给所有条目，答案里取第一个 JSON；失败时条目留在 inbox，reason 写原因。
- `items.py move --by ai` 和 route 都跳过 `_user.project`；`move --by user` 记 `_user.project`、清掉 `suggested_project`；AI 移动时多写 `project_reason`。

### K3 · 条目状态：一条生命线

**2026-10-22 改版**（用户反馈：两条状态轴——审核 draft / confirmed / deleted 和处理 work.state——难懂；「不处理」了的条目还算在收件箱里）。
现在每条只有**一个**用户看得见的状态 `state`：

```
新 New ─要做─▶ 要做 To do ─交出─▶ 已交出 Handed off ─▶ 进行中 In progress ─▶ 待验证 To verify ─标为完成─▶ 完成 Done
                 ▲   ▲                    │                    │                     │
                 │   └────────收回────────┴────────────────────┘                     │
                 └──────────────────────────────退回─────────────────────────────────┘
不做 Won't do：没结束的状态都能到；完成 / 不做 都能「重新打开」回到要做。
丢弃 Discard：任何状态都能丢进「已丢弃」（垃圾桶），能恢复到丢弃前的状态。
```

| `state` | en | zh-Hans | 意思 |
|---|---|---|---|
| `new` | New | 新 | 刚捕获 / 整理出来，你还没看过 |
| `todo` | To do | 要做 | 你留下了，要做 |
| `handed_off` | Handed off | 已交出 | 交给了 agent（口喷鸡里的会话，或复制给你自己的 agent），还没开始 |
| `in_progress` | In progress | 进行中 | agent 在做 |
| `to_verify` | To verify | 待验证 | agent 说做好了（或说不该做），等你确认 |
| `done` | Done | 完成 | 你确认做好了 |
| `wontfix` | Won't do | 不做 | 你决定不做（留着记录） |
| `discarded` | Discarded | 已丢弃 | 丢掉了，在「已丢弃」里，能恢复 |

**分组**（所有界面和计数都按这个，只在这里定义）：
- **收件箱 = 需要你看的 = `new` + `to_verify`**。侧栏、菜单栏数字、刘海岛、Tauri 应用的数字都是它；标了不做 / 完成 / 丢弃的条目立刻离开收件箱。
- 未结束（MCP 的 `open_items`、backlog）= `new` `todo` `handed_off` `in_progress`；进行中（侧栏）= `handed_off` `in_progress` `to_verify`；
  已结束 = `done` `wontfix`；`discarded` 只在「已丢弃」筛选里出现，其它列表和计数都不含它。

**文件**（K1 front-matter）：

```yaml
state: to_verify                  # 唯一的状态
restore_to: todo                  # 只在 discarded 时写：恢复回哪个状态
work: {"to": "session", "agent": "claude", "job": "j-…", "handoff": null, "claim": "fixed",
       "note": "", "commit": null, "pr": null, "at": "…ISO…", "by": "agent"}   # 最近一次交出 / 处理的细节，没有 state 键
work_history: [{"state": "in_progress", "to": …}]   # 处理环节的每次变化：追加变化前的 {state, …work}
```
`work` 的 10 个键（`WORK_KEYS`）总是写齐：`to` session | external | null；`agent` agents.json 的 id 或 `human`；`job` K4 任务 id；
`handoff` K6 交接单 id；`claim` 只在 to_verify 时有值：fixed | wontfix；`note` `commit` `pr`；`at` `by`（user | agent | app）。
keep / discard / restore 只改 `state`（和 `restore_to`），不动 `work`。

**迁移**（读的时候换算，`items.py` 第一次写这个文件时落盘；不需要一次性改写所有文件）。没有 `state` 键（或值不认识）时：
1. `status: deleted` → `discarded`，`restore_to` = 按 2–3 算出的状态；
2. 否则处理状态（`work.state`；v2 的 `fix` 先按下面的映射换算）不是 todo → 就是它（所以 draft + wontfix = `wontfix`，离开收件箱）；
3. 否则 `draft`（或没有 status）→ `new`，`confirmed` → `todo`。

写回时写 `state`，去掉 `status` 和 `work.state`。v2 `fix` 映射不变：`fixing → in_progress`，`fixed → to_verify`（claim fixed），
`wontfix → to_verify`（claim wontfix；旧文件里 `agent: human` 的 wontfix 是你自己的决定 → `wontfix`），`reopened → todo`。
v2 的 items.json（还没迁移的会话）、agent 写的 items.json、`add --json` 里的 `status` / `work` / `fix` 都按同一规则得出 `state`。

**动作**（用户能做的就是这张表；界面上点状态只列当前状态下的这几个动作，标签是动词 + 一句说明，文案键见 K10 的 `action.*`）：

| 动作 | 从 | 到 | 快捷键 | en | zh-Hans |
|---|---|---|---|---|---|
| `keep` | new | todo | A（审核模式还有 ↩） | Keep — add it to To do | 要做 — 留下，放进要做 |
| `hand_off` | new, todo | handed_off | ⌘↩ | Hand off… — start it in Blurt, or copy an instruction | 交给 agent… — 在口喷鸡里开始，或复制指令 |
| `done` | todo, handed_off, in_progress, to_verify | done | D | Mark as done — it's handled（to_verify 时：— you checked, it's fixed） | 标为完成 — 已经处理好了（to_verify 时：— 确认已修好） |
| `send_back` | to_verify | todo | R | Send back — not fixed yet, back to To do | 退回 — 还没好，回到要做 |
| `take_back` | handed_off, in_progress | todo | R | Take back — stop waiting on the agent, back to To do | 收回 — 不等 agent 了，回到要做 |
| `wontfix` | new, todo, handed_off, in_progress, to_verify | wontfix | W | Won't do — keep a record, out of your inbox | 不做了 — 留个记录，移出收件箱 |
| `reopen` | done, wontfix | todo | R | Reopen — back to To do | 重新打开 — 回到要做 |
| `discard` | 除 discarded 外都可以 | discarded | X、⌫ | Discard — move to Discarded; you can restore it | 丢弃 — 放进已丢弃，可以恢复 |
| `restore` | discarded | `restore_to`（没有就 new） | R | Restore — put it back where it was | 恢复 — 放回丢弃前的状态 |

- 每个状态最多一个「往回」的动作（send_back / take_back / reopen / restore），所以 R 总是唯一的；`S` 打开当前条目的状态菜单。
  `hand_off` 只在宿主能派发 / 交接时出现：它打开派发面板或复制指令，状态由 `sessions.py dispatch`（app，to: session）或
  `handoff.py --mark`（user，to: external）写，不走 state op。
- 同一张表在三处实现，用同一个夹具 `tests/fixtures/lifecycle.json` 测：Python `_common.LIFECYCLE`、web `@blurt/ui` 的 `lifecycle.ts`、
  Swift `BlurtCore/Lifecycle.swift`。

**agent 和 app 能做的**（`by: agent` / `app`。它们不能 keep / done / wontfix / discard / restore——留下、完成、不做、丢弃只由你决定）：

| 从 → 到 | 谁 | 什么时候 |
|---|---|---|
| new / todo → handed_off | app | `sessions.py dispatch`（handed_off 再派发 = 只更新细节） |
| new / todo / handed_off / to_verify → in_progress | agent、app | `mark_fixed(fixing)`；会话第一次进入 running |
| new / todo / handed_off / in_progress / to_verify → to_verify | agent、app | `mark_fixed(fixed / wontfix)` → claim；会话退出时还在 in_progress（claim null）；worktree merge / PR 完成 |
| in_progress / to_verify → todo | agent、app | 收回自己的说法（`mark_fixed(reopened)`） |

不合法 → `code: "bad_transition"`；`discarded` 的条目不能交出 / 开始（`code: "deleted"`）。

**接口**
- `items.py state REF … (--state S | --action A) [--to session|external] [--agent A] [--job J] [--handoff H] [--claim fixed|wontfix]
  [--commit SHA] [--pr URL] [--note TEXT] [--by user|agent|app]` → `{"ok","items":[{"uid","id","state","work"}]}`。
  `items.py work …` 是它的旧名字（同样的参数）；`--by` 默认 agent；`--to` 不写时 user 交出 = external、app 交出 = session。
- `items.py list / doc` 的筛选 `--state S`（可重复）；旧的 `--status` / `--work` / `--fix-state` 照旧能用，换算成 state：
  status `draft → new`、`confirmed →` todo … wontfix、`deleted → discarded`；work `todo →` new + todo，其余同名。不给筛选 = 除 discarded 外全部。
- `items.py patch --set status=…` 只为旧调用方保留，要 `--force`（用户在对话里要求的）：`confirmed` = keep、`deleted` = discard、`draft` 不变。
  `state` 不能 patch（`code: "protected"`，用 `items.py state`）。
- user-ops：`{"op": "state", "id", "action"?: A, "state"?: S, "note"?}`（界面一律发 `action`）；旧的 `{"op": "work", …}` 是别名；
  `set` 里的 `state` / `status` 键按用户的状态变化处理；`remove` = discard（有 `into` 时记 `merged_into`）；撤销合并的 `add` 回到 `restore_to`。
- doc 和 `items.py get / list` 的每条带 `state`、`work`、`restore_to`（discarded 时），不再有 `status`。
- index.db v3：`state` 列取代 `status` + `work_state`（K1）；MCP 见 K1。

显示：K8 的状态圆环，每条一个，可以点：列出上面的动作。

### K4 · 任务（jobs）

所有「正在发生的事」统一成任务：录屏、截图批次、语音、整理、分项目、agent 会话。存储 `$BLURT_HOME/jobs/`：

```
jobs/<id>.json             任务本身。只有 owner 写（原子替换）；多个进程可能写同一任务时（sessions.py 的几个子命令）owner 先拿 jobs/<id>.lock
jobs/<id>.events.jsonl     其他人报告进展：每次追加一行（O_APPEND，单行 < 4 KB）。hook、items.py、agent 都只追加，不改 json
jobs/<id>.log              原始输出（整理时 agent 的 stream-json，会话的 hook 原文）
jobs/<id>.claude-settings.json / <id>.diff / <id>.prompt.md   会话用的附属文件（K5）
```

```jsonc
{"schema": 1, "id": "j-20261022-101500-ab12",       // j-YYYYMMDD-HHMMSS-4 位小写 base32
 "type": "record",                                    // record | snap | voice | process | route | agent
 "state": "running",                                  // queued | running | done | failed | cancelled
 "owner": "app",                                      // app（Swift / Tauri）| sessions.py | projects.py
 "project": "3f2a9c1b7e44" | "inbox" | null,
 "session": "/abs/会话目录" | null,
 "parent": "j-…" | null,                              // 例：录屏结束后的 process 任务 parent = 那个 record 任务
 "title": null,                                       // 有就显示（会话标题）；没有时 UI 按 type 拼本地化标题
 "items": ["<uid>"], "captures": [3, 4],              // 产出或处理的条目；涉及的 shots.jsonl n
 "steps": [{"id": "transcribe", "state": "running", "progress": 0.4, "started": "…", "ended": null}],
 "progress": 0.4 | null,
 "created": "…", "started": "…", "ended": null, "updated": "…",
 "events_offset": 0,                                  // owner 已经并进来的 events.jsonl 字节数
 "app_pid": 4242,                                     // owner app 时：写它的 App 进程；下次启动发现进程已不在、任务还在跑 → 标为 failed（hint main.job.hint.interrupted）
 "error": null | {"code": "auth|quota|network|model|skill|tmux|git|conflict|io|unknown", "message": "…", "hint_key": "…"|null},
 "agent": { … }                                       // 只有 type agent，见 K5
}
```

- **steps 的 id 是固定的**（UI 用本地化键 `job.step.<id>` 显示）：record `capture, finalize`；snap `capture`；voice `listen, transcribe, file`；
  process `prepare, transcribe, write, frames, route`；route `route`；agent `launch, work, finish`。
- **events.jsonl 的一行**：`{"t": ISO, "source": "hook|tty|tmux|app|items", "event": "<名字>", "status"?: K5 状态, "state"?: 任务状态,
  "step"?: {"id", "state", "progress"?}, "items"?: [uid], "progress"?: n, "detail"?: {…}}`。
  **读者算「有效状态」**：读 json，再从 `events_offset` 开始按顺序把事件叠上去（step 按 id 覆盖；status → `agent.status/status_at/status_source`；
  state、progress 覆盖；items 取并集）。Swift、Rust、Python 三处实现同一规则，所以 owner 没在跑（应用关了）时状态也是新的。
- **谁是 owner**：record / snap / voice / process 由应用（AgentHub、Capture、Tauri）建和写；route 由 projects.py；agent 由 sessions.py。
  `items.py ingest / done` 看到 `$BLURT_JOB` 时往那个任务的 events 里追加 `write` / `frames` 步骤完成。
- **CLI**（P2，`jobs.py`；Python 的 owner 都用它的库函数）：
  `jobs.py new --type T [--project P] [--session S] [--parent J] [--title T]` → `{"ok","id","path"}`；
  `jobs.py step J STEP --state S [--progress X]`、`jobs.py event J --json '{…}'`（追加事件）、`jobs.py finish J --state done|failed|cancelled [--error-code C --message M]`；
  `jobs.py get J` → 有效状态；`jobs.py list [--active] [--type T] [--project P] [--limit 50]` → `{"ok","jobs":[…]}`（新的在前）；
  `jobs.py watch` → 每当有任务变化输出一行有效状态（给没有文件监听的宿主）；`jobs.py gc` → 删 14 天前结束、且不在最近 300 个里的任务及附属文件，
  还有窗口活着的 agent 任务永不删。应用启动时跑一次 gc。旧的 `$BLURT_HOME/runs/` 不再写，只读不迁移。
- **宿主怎么看**：macOS FSEvents 监听 `jobs/`（防抖 100 ms），Tauri 用 notify，然后各自重算有效状态。
- **提醒规则**（P4 / P8 实现，P5 显示在刘海岛上）：
  - **绝不自动打开**审核页、主窗口或浏览器。
  - 整理完成：刘海岛和菜单栏图标上的数字 +N，主窗口「收件箱」有待审数；刘海岛可见时在岛内安静地显示一句（2.4 秒，不抢焦点，
    「录屏整理好了 · 5 条待审」，点了打开主窗口的这批）。系统通知只在：应用不在前台、任务跑了 20 秒以上、设置 `notify.done` 开（默认开）；不出声。
  - 录屏中不弹任何提示，只更新计数。
  - agent 会话「等你回答」：刘海岛上该会话的小标记变成提醒色并轻微脉动一次；应用不在前台时发系统通知（`notify.agent`，默认开，不出声）；
    点击 = 主窗口跳到那个会话的终端。「本轮完成」只更新标记，应用不在前台时也通知（同一开关）。
  - 失败：岛内一句原因加「重试 / 查看日志」；不在前台时系统通知。
  - 同类通知 10 秒内合并成一条。

**细则（P2）**：
- `jobs.py step / event / finish` 在命令行上都是**追加事件**（谁都能调）；owner 自己用库函数（`create`、`update`、`absorb`）写 json。
- 新建任务时 `steps` 按 type 的固定 id 全部列出（`pending`），step 进入 running / 结束时由叠加规则补 `started` / `ended`。
- `finish` 事件的 `detail.error` 不在共享的叠加规则里：owner 合并事件时才写进 `error`（读者在那之前只看到 state = failed）。
- 追加时如果文件最后一个字节不是换行（之前的写入方崩在半行），先补一个换行，半行变成一行坏 JSON，读者跳过。
- `gc` 判断不了哪些 tmux 窗口还在（没有 tmux 之外的错误）时，agent 任务一律保留。

### K5 · agent 会话（tmux）

- **tmux**：私有 socket `tmux -L $BLURT_TMUX_SOCKET`（默认 `blurt`），绝不碰用户默认的 tmux 服务。服务启动时用 `-f $BLURT_HOME/tmux.conf`
  （sessions.py 生成）：`status off`、`mouse on`、`history-limit 50000`、`escape-time 10`、`focus-events on`、`set-clipboard on`、
  `extended-keys on`、`default-terminal` = `tmux-256color`（本机 `infocmp tmux-256color` 失败时用 `screen-256color`，macOS 自带的 ncurses 可能没有前者）、`remain-on-exit on`（退出后窗口留着，便于看结果和退出码）。要求 tmux ≥ 3.2，
  没有或版本太低 → 退回 app runner（见下）并提示安装（macOS `brew install tmux`，Linux 包管理器）。
- **命名**：一个项目一个 tmux 会话 `blurt-<项目 slug>`；一次派发 = 其中一个窗口，窗口名 = 条目 id 用逗号连起来（`BA-12`、`BA-12,BA-13`；
  超过 3 个写成 `BA-12,BA-13,BA-14+2`），最长 40 字符。窗口上设用户选项 `@blurt_job`（任务 id）、`@blurt_items`（uid 空格分隔）、`@blurt_agent`。
  sessions.py 一律按 `@blurt_job` 找窗口，不靠名字。
- **派发方式**：`together`（默认）= 一个窗口一个对话处理全部所选条目；`parallel` = 每条一个窗口，worktree 强制开（不是 git 仓库时退化为
  不开 worktree 的并行，并给 `no_git` 警告）。
- **worktree**：默认取项目设置（`worktree: true`），派发时可改。位置 `<worktree_root>/<窗口名里的第一个 id>[-n]`，默认 `worktree_root` =
  `<仓库根>/../.<仓库名>-worktrees`（放在仓库外面，免得项目自己的构建、测试、搜索扫到重复的代码）。分支 `blurt/<id 小写>-<ASCII slug ≤ 24>`
  （slug 为空就只有 id，撞了加 `-2`），从项目当前分支的 HEAD 切出；agent 的 cwd = worktree 里对应项目子目录。
  worktree 模式下提示词让 agent **在分支上提交、不推送**；不用 worktree 时提示词让 agent **不提交**。
- **不用 worktree 时的并发**：同一项目里已有一个活着的、不用 worktree 的会话时，dispatch 照样执行，结果里带警告
  `{"code": "concurrent_edit", "jobs": [...]}`；UI 在派发前（`--dry-run`）显示一句提醒和两个按钮，不禁止：
  en「Another session is already changing files in {project}. Editing the same files at the same time can cause conflicts — a worktree keeps them apart.」
  按钮「Use a worktree」/「Continue」；zh「{project} 里已经有一个会话在直接改文件。同时改同一批文件可能冲突，建议用 worktree 分开。」按钮「用 worktree」/「继续」。
- **启动的命令**（P2 写进 `agents.json` 每个条目的 `interactive.session`，Swift / Rust 不自己拼）：
  - Claude Code：`claude --settings <jobs/<id>.claude-settings.json> [--mcp-config <blurt 服务的 json>] "<提示词>"`；
    `--mcp-config` 只在用户没装 blurt MCP 时加（`agents.py install` 的 check 逻辑）。settings 文件只放 hooks，`--settings` 是叠加的，
    不改用户的全局配置：`SessionStart`、`UserPromptSubmit`、`PostToolUse`（matcher `*`，用来在批准权限后切回「运行中」）、`Notification`、
    `Stop`、`SessionEnd`，每个都是 `{"type": "command", "command": "'<python>' '<scripts>/sessions.py' hook --job <id> --agent claude", "timeout": 5}`。
    `<python>` = 执行 dispatch 的那个解释器的绝对路径（`sys.executable`），hook 只用标准库，不经过 uv。
  - Codex：`codex -c 'notify=["<python>","<scripts>/sessions.py","hook","--job","<id>","--agent","codex"]' [-c mcp_servers.blurt.…（同 C5 的 headless_mcp，没装时才加）] "<提示词>"`。
    notify 只有「本轮完成」；P2 实测 Codex 当前版本是否支持按次注入的 hooks（SessionStart / UserPromptSubmit / Stop），支持就也接上 ⚠。
  - 其他（Kimi Code、OpenCode…）：有交互式命令就 `interactive.session.argv`，提示词放不进参数的就启动后用 `sessions.py send` 粘贴；状态只有运行中 / 已退出。
  - 环境：`BLURT_JOB`、`BLURT_AGENT`、`BLURT_PROJECT`、`BLURT_HOME`、`BLURT_WORKSPACE`，以及 `BLURT_RUN_ID = BLURT_JOB`（旧别名）。
  - 提示词（`agents.py prompt work --items … --mode session|external --worktree on|off`，P2，替代 C5 的 `prompt fix`）总是很短：
    指向 K6 的交接单，例如「Read /Users/john/.blurt/handoff/H-0012.md and handle the items in it. …」，说明完成后调 `mark_fixed`（或 `items.py work`）、提交规则见上。
- **状态**（`agent.status`）：`running` 运行中 / `waiting_input` 等你回答 / `turn_done` 本轮完成 / `exited` 已退出 / `error` 出错。

  | 来源 | 事件 | → 状态 |
  |---|---|---|
  | Claude hook | SessionStart、UserPromptSubmit、PostToolUse | running |
  | Claude hook | Notification，`notification_type` = permission_prompt / elicitation_dialog（或没有类型） | waiting_input |
  | Claude hook | Notification，idle_prompt | 不变（已经是 turn_done） |
  | Claude hook | Stop | turn_done |
  | Claude hook | SessionEnd | exited |
  | Codex notify | `agent-turn-complete` | turn_done |
  | tmux（monitor） | `pane_dead` = 1：`pane_dead_status` 0 → exited，非 0 → error | |
  | 终端输出兜底 | 只用于没有对应 hook 的 agent：每秒 `capture-pane -p -S -15`，命中 `interactive.waiting_patterns`（agents.json，正则）→ waiting_input；之后窗口有新输出且不再命中 → running；窗口 8 秒没有新输出（`window_activity`）且上一个状态是 running → turn_done | |

  hook 进程（`sessions.py hook`）：从 stdin（Claude）或最后一个 argv（Codex）读 JSON，往 `jobs/<id>.events.jsonl` 追加一行
  `{"t","source":"hook","event","status","detail":{"notification_type"?, "message"?（≤ 200 字）, "agent_session_id"?}}`，
  原文写进 `<id>.log`；**stdout 不输出任何东西**、总是退出 0、1 秒内结束，绝不影响 agent。状态没变（例如连续的 PostToolUse）时不追加。
  `exited` / `error` 不移动条目：只有 agent 自己报告（`items.py state --state to_verify --claim …`、MCP `mark_fixed`）才到
  to_verify。退出或崩溃却没报告的会话，条目留在进行中，App 在条目上方说「会话已结束，未报告完成」，给「打开会话 / 标为完成」
  （会话记录不在了就是「收回 / 标为完成」）。`jobs.py gc` 不删未完成条目还指着的会话和没收尾的 worktree；`items.py migrate --all`
  一次性忘掉指向不存在会话的 `work.job`（v0.6 的 r-… 运行、已删的任务）。
- **agent 任务的 `agent` 对象**：
  `{"id": "claude", "mode": "together|parallel", "runner": "tmux|app", "tmux": {"socket", "session", "window": "@12", "name": "BA-12"} | null,
  "cwd": abs, "worktree": {"path", "branch", "base", "base_sha"} | null, "status", "status_at", "status_source", "exit": null|n,
  "handoff": "H-0012", "agent_session_id": null|"…", "finish": null | {"action", "at", "result"}}`。任务 state：活着 = running，
  exited → done，error → failed，用户停止 → cancelled。
- **CLI**（P2，`sessions.py`）：

```
sessions.py dispatch --items REF … [--agent ID] [--mode together|parallel] [--worktree on|off|auto] [--runner tmux|app|auto]
                     [--dry-run] [--lang en|zh]
     → {"ok","jobs":[{"id","project","window","worktree"?,"branch"?,"cwd","items":[uid]}],
        "warnings":[{"code":"concurrent_edit|no_git|no_tmux|draft_confirmed","jobs"?:[…],"items"?:[…]}],
        "launch":[{"job","argv","env","cwd"}]   // 只在 runner = app 时：由应用自己在 pty 里跑
       }
     条目必须属于同一个有文件夹的项目（inbox 的 → code "needs_project"）；agent 默认 = 项目 default_agent → 全局 → agents.py detect 的 pick。
     会写交接单（K6，to = session）、把条目设为 handed_off、建任务、起 tmux 窗口。--dry-run 只返回 warnings 和将要用的参数，什么都不改。
sessions.py list [--project ID] [--all]          → {"ok","sessions":[{job, project, agent, items, window, status, status_at, worktree, branch,
                                                     cwd, started, ended, exit, attached}]}（默认只列窗口还在的；顺带做一次 monitor 检查）
sessions.py attach-cmd JOB                       → {"ok","argv","env"}：建一个分组视图会话（`new-session -t blurt-<slug> -s blurt-<slug>~<n>`，
                                                     `destroy-unattached on`，再选中这个任务的窗口），每个嵌入终端各自一个，互不抢当前窗口
sessions.py open-external JOB [--terminal auto|terminal|iterm|ghostty|wezterm|kitty|gnome-terminal|konsole|wt]   在系统终端里打开同样的视图（视图会话开 status 栏）
sessions.py send JOB --text T [--enter]          粘贴到窗口（bracketed paste）
sessions.py stop JOB [--kill]                    先发 C-c，--kill 关窗口；任务 → cancelled
sessions.py finish JOB --action diff|merge|pr|discard|keep [--keep-branch]
     diff → {"base","branch","stat":[{"path","added","deleted"}],"patch":"<jobs/<id>.diff>","uncommitted":n}
     merge：主工作区必须干净且在 base 分支，`git merge --no-ff --no-edit <branch>`；冲突 → `git merge --abort`，code "conflict"；成功后删 worktree 和分支
     pr：`git push -u origin <branch>`，有 gh 就 `gh pr create --fill --head <branch>`，否则返回仓库的 compare 网址（只在用户点了按钮后执行）
     discard：`git worktree remove --force` + `git branch -D`；keep：什么都不做。merge / pr 成功后条目 → to_verify（已经是的不变）
sessions.py hook --job J --agent A               见上
sessions.py event --job J --event pane-dead --exit N     app runner 报告退出
sessions.py monitor [--once] [--interval 1.0]    轮询 tmux（`list-panes -a -F …`）+ 终端兜底，写状态事件；应用运行期间常驻一个（锁 $BLURT_HOME/run/monitor.lock）
sessions.py doctor                               → {"ok","tmux":{"path","version"}|null,"socket","agents":[{id, session: bool}]}
```

- **没有 tmux / Windows**：`--runner app`（没有 tmux 时 auto 也选它）：sessions.py 照样建任务、交接单和 settings 文件，返回 `launch`，
  由应用在自己的 pty 里跑（macOS SwiftTerm 的 LocalProcess；Tauri 用 portable-pty，Windows 是 ConPTY），退出时调 `sessions.py event`；
  hook 照常工作。界面上明确写「关掉口喷鸡会结束这个会话」。终端兜底检测由应用按同一份 `waiting_patterns` 做。
- **嵌入终端**：macOS SwiftTerm（P3，源码 vendored，见「所有权」），Tauri xterm.js（P8）。终端里执行 `attach-cmd` 的 argv。
  关掉应用会话照常在跑；再打开时主窗口的会话列表来自 `sessions.py list` 和任务文件。

**细则（P2，2026-10-22 用 Codex 0.157 和 Claude Code 2.1.259 实测）**：
- **Codex 支持按次注入 hooks**：`-c 'hooks.<事件>=[{hooks=[{type="command", command="…", timeout=5}]}]'`，接了 SessionStart、
  UserPromptSubmit、PostToolUse（→ running）、**PermissionRequest（→ waiting_input）**、Stop（→ turn_done）、SessionEnd（→ exited）。
  Codex 会让用户**信任一次**这些 hooks（「Hooks need review」），按命令内容记住，所以 hook 命令里**不带任务 id**
  （`'<python>' '<scripts>/sessions.py' hook --agent codex`，任务取 Codex 传给 hook 的 `$BLURT_JOB`，实测可用），换安装位置才会再问。
  notify 不需要信任，照旧带 `--job`。用户信任之前（或选了不信任）Codex 的「等你」靠终端兜底（`waiting_patterns` 含 Codex 底部的
  「enter confirm · esc skip」「Press enter to confirm or esc to cancel」和信任提示本身）。Codex 还会为生成标题等旁支线程发 notify，
  `thread-id` 和 SessionStart 记下的 `agent_session_id` 不同的忽略。
- Codex 对 worktree 的「信任这个文件夹」作用在**仓库根**上：信任过项目后，并行派发的每个 worktree 都不再问。
- **Claude Code 的 `--mcp-config` 吃多个值**，会把后面的提示词当成第二个配置文件：会话命令在提示词前加 `--`
  （`claude --settings F [--mcp-config J] -- "<提示词>"`）。没登录时交互界面停在登录页、hooks 不触发；`-p` 模式下 SessionStart /
  UserPromptSubmit / SessionEnd 都经 `sessions.py hook` 实测到达。
- hook 用的解释器是 dispatch 进程的**基础解释器**（`sys._base_executable`，不用 `uv run` 的缓存 venv，那个会被清掉）。
- tmux：服务进程用去掉 agent 会话变量的环境启动（同 `agents.clean_env`），保证 UTF-8（没有就设 `LC_CTYPE`），客户端一律 `tmux -u`；
  tmux.conf 另加 `allow-rename off`、`automatic-rename off`、`renumber-windows off`，窗口名不被 agent 改掉。
  `list-panes` 的格式用 `|` 分隔（tmux 会把 tab 转义成 `_`）。
- **attach-cmd**：视图会话由 sessions.py 先建好（`new-session -d -t =blurt-<slug> -s blurt-<slug>~<n>`、选中窗口），返回的 argv 只是
  `tmux -u -L <socket> -f <conf> attach-session -t =<视图>`，不靠 `;` 串命令（启动器可能改写它）。`destroy-unattached` 在终端
  **连上之后**由 `client-attached` hook 打开（提前设会让还没人连的视图立刻被销毁）；建好 60 秒还没人连的视图下次调用时清掉。
- 终端兜底：`waiting_patterns` 只在窗口**最后 6 行非空内容**里找（往上滚走的提示已经答过了）。
- 全局默认 agent：config `record.default_agent`；都没设时用 `agents.py detect` 里第一个装了、能开会话的（先 ready 再 configured / unknown）。
- dispatch 的结果里每个 job 多一个 `handoff`；`launch[]` 多 `paste`（`interactive.session.prompt = "paste"` 的 agent，应用起来后粘贴）和
  `patterns`（应用做终端兜底用）。tmux 下的 paste 由后台的 `sessions.py send --after 3` 完成。条目改状态失败时多一个警告
  `{"code": "items_not_updated", "items", "message"}`（会话已经起来了）。
- 错误码：dispatch `needs_project`、`mixed_projects`、`deleted`、`bad_transition`（条目不是 todo / handed_off）、`bad_agent`、`no_agent`、
  `no_tmux`（退出码 4）、`tmux`、`git`；finish `no_worktree`、`running`（merge 前要先停 agent）、`uncommitted`（worktree 里有没提交的改动，
  带 `count`）、`wrong_branch`、`dirty`、`nothing`（分支没有新提交）、`conflict`（已 `merge --abort`）、`no_remote`、`push`、`gone`。
- agent 对象另有（owner 内部用，读者可忽略）：`worktree.repo`（主仓库路径）、`base_sha`（不用 worktree 时派发那一刻的 HEAD，给 diff 用）、
  `started` / `closed`（条目已经推到 in_progress / to_verify）、`hooks_live`（收到过生命周期 hook）、`items_error`。
- `stop`：发两次 C-c（间隔 0.4 秒）、最多等 3 秒；任务一律变成 cancelled（即使 agent 自己的 SessionEnd 先到）。`discard` 不改条目状态
  （in_progress → todo 不在 K3 的表里），由用户在界面上重新打开。merge 成功后也关掉那个窗口。

**细则（整理用模型 / token 用量 / 派发选模型，2026-10-22）**：
- `agents.json` 每个 agent 多：`models`（`{list: [{id,name,cheap}]}` 固定列表，Claude Code 用别名；或 `{cache, config}` = CLI 自己的模型缓存和配置，
  Codex 是 `$CODEX_HOME/models_cache.json` 里 `visibility: list` 的，按 priority；描述含 fast / affordable 等的算 cheap）、`model_args`（`{model, effort}` 参数模板）、
  `processing`（整理默认 `{model: "cheapest", effort: "low"}`）、`usage`（`args` 让 CLI 报用量 + `format`，或 `pattern` 从输出里取数字，Codex `tokens used\n24,953`）。
  用户设置 `record.agent_processing.<id> = {model: id | "cheapest" | "default", effort}`（设置 → Agent「整理用模型」，默认值不写）。
- `agents.py models ID` → `{models, cheapest, cli_default, efforts, processing}`（不联网、不花 token）；`agents.py command … headless --processing` 加上整理模型、
  强度和用量参数（Tauri 整理也带它）；`agents.py usage ID FILE [--offset N]`。macOS 的 AgentHub 按同一规则自己拼（`AgentDef.processingArgs / tokensUsed`）。
- **K4 任务多一个 `usage`**：`{tokens: n | null, agent, model, effort}`（owner 在 agent 退出后从输出解析写入；直接归档的是 `{tokens: 0, agent: null}`）。
  主窗口任务详情副标题显示「用了约 5.9万 token · gpt-6-luna」/「未用 AI · 0 token」。
- `sessions.py dispatch … --model M`：会话命令在提示词前加 agent 的 `model_args.model`（没有的 agent 报错），`agent.model` 记在任务里；`default` / 不写 = CLI 自己的设置。
  派发面板（macOS `DispatchPanel`、Tauri `DispatchSheet`）在 agent 下多一个模型下拉（「默认（跟随 CLI 设置：…）」+ 该 agent 的模型），按项目 + agent 记住
  （macOS config `sessions.models.<project>.<agent>`，Tauri localStorage）。

**细则（P3，macOS）**：
- **SwiftTerm**：`mac/Vendor/SwiftTerm` 是 v1.20.0 的源码（去掉 iOS、文档和 Metal shader；Metal 渲染器上游默认关、我们不开），
  `SwiftTermBuildInfo.swift` 手写替代上游的构建插件，所以只有 Command Line Tools、离线也能 `swift build`。
  `Package.swift` 的 BlurtApp target `exclude: ["Resources"]`：`.lproj` 表由 `record.py build` 拷进包，不走 SwiftPM 资源。
  `record.py` 的 `swift_sources()`（P4）应把 `Vendor/**` 也算进哈希，否则升级 SwiftTerm 不会触发重建。
- **嵌入点**：`AppEnvironment.terminal.makePane()` 返回一个完整的会话面板（左边按项目分组的会话列表 + 右边标题栏和终端），
  `attach(job:)` 选中会话，`attach(nil)` = 这个面板上次看的那个（`$BLURT_HOME/ui/terminal.json`），否则「等你回答」的、否则最新的。
  P4 在主窗口里放它即可；面板自己能收起列表。没有主窗口实现 `reveal(job:)` 时，独立的「会话」窗口（`SessionsWindowController`）兜底。
- **每个终端一个 tmux 客户端**：执行 `attach-cmd` 的 argv（环境补 UTF-8 locale、`TERM=xterm-256color`、`COLORTERM=truecolor`），
  两个面板看同一项目的两个窗口互不影响。窗口被 merge / discard / `stop --kill` 关掉后，分组视图会话会滑到组里的别的窗口，
  所以面板看到任务 `finish.action ∈ {merge, discard}` 或 `cancelled` 时主动断开、显示结果。
- **attach-cmd 的 tmux 目标写法**（给 P2）：`set-option -t =<view>` 在 tmux 3.6 上报 `no such session`，整串命令就此中止，
  `select-window` 不执行（结果是两个面板都停在窗口 0、`destroy-unattached` 也没设上，视图会话越积越多）。要写成 `-t =<view>:`
  （带冒号）；`select-window -t =<view>:@N` 本身没问题。P3 的测试用的是改过这一处的 sessions.py 副本。
- **会话状态提醒**由 P3 的 `Terminal/SessionNotifier.swift` 发（type agent 的任务）；P4 的 `JobNotifier` 只管其它类型，避免重复。
  通知 `userInfo` 带 `job`（或 `uid`），点击 = `AppEnvironment.mainWindow.reveal(job:)`。没有别的 delegate 时 SessionNotifier 当
  `UNUserNotificationCenter` 的 delegate；谁接管 delegate 都要按 `job` / `uid` 路由。测试构建（非默认 `BLURT_HOME`）不发系统通知，
  只在 stdout 打 `session_notify`。
- **app runner**：`dispatch` 返回 `launch` 时由 `AppRunner` 在应用自己的 pty 里跑，面板借用它的视图；退出时调 `sessions.py event`。
  标题栏写明「退出口喷鸡会结束这个会话」。终端输出兜底（`waiting_patterns`）这一轮没做，只有 hook 的 agent 状态完整。
- **FixWatcher**：监听每个 store 的 `items/*.md`，front-matter 的 `work.state` 变成 `to_verify` 时啄一下（`FixRunner.announceFixed`）。
  路径一律 `realpath`（FSEvents 给 `/private/tmp`，URL 给 `/tmp`）。
- **G0 之外的公开 API**：`AgentInfo` 多了 `tmuxSocket statusSource statusMessage baseBranch finishAction finishResult`，
  `Job` 多了 `updated raw`，`DispatchResult` 多了 `launch rows`，`AppLaunch`、`SessionsError(code, message)`、`SessionsDoctor`，
  `JobStore.addObserver(_:) / removeObserver(_:)`（onChange 只有一个，多处要跟随任务时用它）、`JobFiles`（路径、`newID`、`appendEvent`）。

**细则（P8，Windows / Linux 的 Tauri 应用，2026-10-22 在本机用 P1 + P2 的脚本实测）**：
- **Tauri 命令**：契约里的名字全部实现；另有（参数 camelCase）`index_query / index_item / index_sessions / index_summary`（schema v2 的
  只读查询）、`projects_open_folder(makeCurrent)`（系统选文件夹 → `projects.py add`）、`items_work(uids, work, note)`、
  `items_move(uids, project)`、`agents_detect`、`sessions_stop(job, kill)`、`sessions_open_external(job, terminal)`、
  `sessions_send(job, text, enter)`、`pty_close(ptyId)`、`clipboard_write(text)`。`pty_open(job, cols, rows)` → `{ptyId, replay, owned}`
  （app runner 的会话留最后 1 MB 输出，后开的终端先回放）；`handoff_create(uids, full)` → `{id, path, text}`，Rust 用 `create --mark`
  并把 `text` 放进剪贴板。命令失败时消息末尾带 CLI 的机器码 ` [code]`，界面按 `error.<code>` 本地化，不显示英文原文。
  `jobs://changed` 的载荷是变了的那些任务（有效状态，Rust 的 `jobs::fold` 与 jobs.py 同一规则）。
- **派发**：runner 默认 Windows = `app`，其它 = `auto`。`launch[]` 由应用在 portable-pty（Windows 即 ConPTY）里起，`paste` 3 秒后用
  bracketed paste 粘进去，退出时 `sessions.py event --event pane-dead --exit N`。`sessions.py monitor` 在应用运行期间常驻（独立进程组，
  退出时整组结束——只杀 `uv run` 会留下它起的 Python）。app runner 的终端兜底（`launch[].patterns`）**还没做**；Claude / Codex 有 hooks，
  不受影响。
- **能开会话的 agent**：`agents.py detect` 的行里还没有「能开会话」的字段，界面暂用 `headless` 近似；建议 P2 每行加 `session: bool`
  （界面已经优先读它）。
- **岛**（`blurt-overlay-island`，`blurt_capture::overlay::island`）：一个窗口 = 指针所在屏幕工作区顶部整条、高 600 逻辑像素，透明、置顶、
  点穿（页面上报 hit rects；拖卡片时整窗接收鼠标），只在项目切换器打开时可聚焦。Rust → 页面 `blurt://island`：`state`（`IslandState`，见
  `web/apps/overlays/src/host.ts`）、`cards`、`card {card, pull}`、`toast {kind: sorted | failed | error}`、`switcher`、`peek`、`attention`、
  `status`、`level`；页面 → Rust `blurt://action`：`record snap voice pause resume stop discard voice.stop voice.cancel keyboard project.use
  project.open card.assign card.inbox card.ai_sort card.remove card.copy card.note open.inbox open.session retry log`。Linux 的录屏区域
  盖住岛时，岛移到区域下方（X11 没有截屏排除）。录屏 HUD 和鸡舍（perch）窗口删除，`overlay::record` 换成不带窗口的 `engine::record`。
- **录屏外的截图 / 语音**：`tk_recorder.py shot SESSION --region x,y,w,h [--project P]`、`tk_recorder.py voice SESSION [--project P]
  [--silence-ms] [--max] [--hold]`（`BLURT_TEST_MIC_WAV` 测试用），写 K7 的 shots.jsonl 行；转写用 `transcribe.py note`（P7），没有时 `said`
  留空、整理时再转写。有当前项目时 8 秒内的捕获合并成一个 process 任务（`process_captures` 不写归属行，归属已在捕获行里）；auto 下是卡片
  （= inbox store 里还开着的截图批次中 project 为 null、没删的行）。
- **整理**：process 任务由应用跑 `agents.py command <pick> headless`（`BLURT_JOB`、`BLURT_PROJECT`，输出进 `jobs/<id>.log`）；录屏一结束就
  整理（parent = record 任务），失败的原因按输出归到 `auth / quota / network / unknown`。
- **测试通道**（只给脚本化冒烟用）：`BLURT_TEST_EVAL=<文件>`——文件一变，第一行是窗口 label、其余是在那个窗口里执行的 JS；页面用
  `emit('blurt://test-result', …)` 回报，Rust 追加到 `<文件>.out`。不碰真实的鼠标键盘。

### K6 · 交给外部 agent：交接单

- 文件 `$BLURT_HOME/handoff/<H-id>.md`，id = `H-` + 4 位以上数字，全局递增（`handoff/.seq`，锁内读写）。派发到会话（K5）也写一份，
  所以两条路用同一份内容。保存 90 天以上（`jobs.py gc` 不删它们）。
- 格式（P2，`handoff.py`；标题和小节标题按 `--lang`，默认界面语言）：

```markdown
---
handoff: H-0012
created: "2026-10-22T10:15:00+08:00"
project: {"id": "3f2a9c1b7e44", "name": "bug-agent", "path": "/Users/john/workspace/bug-agent"}
items: ["01JB…", "01JC…", "01JD…"]
to: external
lang: en
---
# 3 items for bug-agent

Project folder: /Users/john/workspace/bug-agent
When you finish an item, call the blurt MCP tool `mark_fixed` with its uid (state "fixed" or "wontfix", plus a short note).
Without the MCP: `uv run --script <scripts>/items.py work <uid> --state to_verify --claim fixed --note "…"`.
Don't push. <worktree 规则：提交 / 不提交>

## 1. BA-12 · The login button does nothing
uid 01JB… · issue · high · module auth
**They said**
> …
**Actual** … **Expected** … **Steps** 1. … 2. …
**Suspected code** `web/src/Login.tsx:42`
![Frame 1 · 0:14 — login button greyed out](/Users/john/workspace/bug-agent/.blurt/assets/01JB…/1.png)
```

  图片一律**绝对路径**（Claude Code 和 Codex 都能直接读本机图片）。
- **复制指令**（一句话，按界面语言）：
  en 单条「Please handle BA-12 — details and screenshots are in /Users/john/.blurt/handoff/H-0012.md. When you're done, call mark_fixed if the blurt MCP is available.」
  en 多条「Please handle these 3 items — details and screenshots are in …H-0012.md. When you're done, call mark_fixed for each if the blurt MCP is available.」
  zh 单条「请处理 BA-12，详情和截图见 /Users/john/.blurt/handoff/H-0012.md。做完后如果有 blurt MCP，调用 mark_fixed。」
  zh 多条「请处理这 3 个条目，详情和截图见 …H-0012.md。做完后如果有 blurt MCP，逐条调用 mark_fixed。」
- **复制全文** = 去掉 front-matter 的正文。
- CLI：`handoff.py create --items REF … [--lang en|zh] [--to external|session] [--mark]` → `{"ok","id","path","instruction","full","items":[uid]}`；
  `--mark`（UI 在用户点了复制之后调用）把条目设为 `handed_off`、`to: external`、`handoff: H-…`。`handoff.py get H-0012` → 同样的字段。

**细则（P2）**：
- 交接单里「没有 MCP 时」的命令用 hook 同一个解释器直接跑 items.py（`'<python>' '<scripts>/items.py' work …`），**不用 `uv run`**：
  Codex 的沙箱里碰 uv 的缓存要用户批准（实测）。
- 标题：en `BA-12 for bug-agent` / `3 items for bug-agent`；zh `bug-agent · BA-12` / `bug-agent 的 3 个条目`。条目分属多个项目时
  front-matter 的 `project` 为 null、标题只有数量，每条的元信息行多一个项目名；inbox 的条目不写「项目文件夹」。
  会话用的交接单 front-matter 多一个 `branch`（用 worktree 时），并带对应的提交规则。每条的元信息行里种类和严重程度按语言本地化。
- `--mark` 写 `by: user`，`agent` 不填（外部是谁不知道）。图片只列存在的文件；路径里有空格或括号时用 `<…>` 包起来。

### K7 · 捕获交互：刘海岛、鸡爪卡片、语音、截图

组件：**刘海岛**（macOS，P5）/ **顶部胶囊**（Windows / Linux，P8，功能一样，动效弱一些）。它合并了录屏 HUD、当前项目、语音输入、
捕获计数、任务进度；独立的 HUD 条和绳子（`Rope.swift`）删除。窗口：非激活 NSPanel、`sharingType = .none` 并加进录屏的排除列表、
所有桌面空间可见、出现在指针所在的屏幕；Tauri 是 `blurt-overlay-island`（透明、置顶、不可聚焦、contentProtected）。

**几何**：有刘海的屏幕（`safeAreaInsets.top > 0`，刘海宽 = 屏幕宽 − 左右 `auxiliaryTop*Area` 宽）：收起时就是刘海本身（纯黑，
底部圆角 10），有事可显示时向两侧长出「耳朵」（各 56 pt）。没有刘海的屏幕：菜单栏下 6 pt 处的胶囊（高 30，最小宽 120），
没事时隐藏，指针在顶部中间 320×8 pt 的区域停 250 ms 才出现。展开：宽 480（420–560），高随内容（最多 420），圆角 22，
指针悬停 150 ms 或按快捷键展开，离开 400 ms 收起。

**状态和内容**：

| 状态 | 收起时（耳朵） | 展开后 |
|---|---|---|
| 空闲 | 无（没刘海时隐藏）；有待审时右耳显示待审数 | 第 1 行：当前项目（文件夹图标 + 名字 + chevron，点 = 切换项目）、右侧录屏 / 截图 / 语音三个图标按钮（悬停显示名称和快捷键）；第 2 区：进行中的任务（最多 3 个：图标、标题、当前步骤、进度）；第 3 区：需要你处理的 agent 会话（状态标记，点 = 跳到终端）；底部：「5 条待审」→ 打开主窗口收件箱 |
| 录屏中 | 左耳：红点（1 Hz 呼吸，减弱动态效果时不动）+ 已录时长（等宽数字）；右耳：截图数 | 暂停 / 继续、完成、放弃（要确认）、截图（= 截图 + 暂停 + 备注）、麦克风电平、「按住 ⌃ 画笔」提示、当前项目（可改，K2） |
| 语音备注 | 左耳：波形；右耳：时长 | 实时识别的文字（有就显示）+「再按 ⌥⇧V 结束 · Esc 取消」（Esc 只在前 10 秒，v0.8.7） |
| 整理中 | 右耳：孵化的蛋（轻轻晃）+ 正在整理的数量 | 任务行显示步骤 |
| 抽屉 | — | 项目列表（见下） |

**抽屉**（项目作为放置目标）：拖着卡片进入岛的范围就展开成抽屉；按 ⌥⇧O 是「切换器」模式。行：最近的项目（按 last_used，最多 8 个，
再多有「更多…」和输入即过滤）、每行文件夹图标 + 名字 + key；切换器模式顶部多一行「自动」，底部「打开文件夹…」（⌘O）；放置模式底部多
「待分配」和「交给 AI 分」两个目标。↑↓ 选择、↩ 确认、Esc 关闭。放置目标高亮：放大 1.02 + 12% 强调色底。

**鸡爪卡片**：
- **卡片 = 还没归属项目的捕获**（auto 模式下的截图加备注、一段语音）；录屏永远不挂卡片。有图：112×84 pt 缩略图；只有语音：168×44 pt，波形图标加一行文字。
- 每张卡被一只从屏幕顶边伸下来的鸡爪（现有的爪子矢量，`drawFoot`）抓着上沿，卡片上沿在岛底下 18 pt，以岛为中心左右排开，间距 12 pt，
  交替倾斜 ±2°，最多显示 7 张，其余叠成一张「+N」。（v0.9 改为：最新的在左，最多 5 张、整排不超过 780 pt，其余在末尾的「+N」后面，
  点开是全部卡片的总览；见 HangingCards.swift / BlurtCore CardRow.swift。）
- 当前项目已选时：捕获结束后卡片飞上来，爪子接住，随即把它拽进岛里（不挂着），岛轻轻一鼓，出现孵化的蛋（这一条进入整理）。
  多个捕获在 8 秒内连续发生时合并成一个 process 任务。
- 没选项目（auto）时卡片挂着。手势沿用鸡舍：单击复制图片；拖出 = 文件（附备注文字）；双击编辑备注；悬停抬起并显示备注；× 删除。
  **拖到岛上的某个项目 = 归属并开始整理**（爪子把卡拽回岛、孵化）；拖到「待分配」= 归属 inbox 并整理（条目进待分配）；
  「交给 AI 分」= 把所有卡片一起整理，按条 route（K2）。
- 动效（P5 定最终参数，P8 尽量对齐）：飞上来 = 弹簧（response 0.55 s，damping 0.72）；爪子下伸 0.35 s ease-out、接触时合拢；
  摆动按现有阻尼弹簧，1.2 秒内停稳；悬停抬起 6 pt、旁边的卡让位；拖走时爪子张开、0.3 s 缩回；没放到目标上弹回爪子；删除 = 爪子张开、
  卡片受重力掉落并淡出（0.5 s）；拽进岛 = 0.45 s ease-in，缩到岛中心 0.2 倍，岛 1.04 → 1（0.25 s）。系统开了「减弱动态效果」：一律 0.2 s 淡入淡出，不摆动。
- **孵化**只在整理这批卡片（或当前项目下的捕获）的 process 任务进行中出现，位置在岛上；完成时 0.6 s 破壳，变成待审数 +N。

**捕获的落盘**（P5 写，P1 的 ingest 和 P4 的整理读）：截图和语音都追加进当前 store 里打开着的截图批次 `sessions/<ts>-shots/shots.jsonl`
（没有就新建；格式同 v0.6）。新增字段：`"type": "shot" | "voice"`（缺省 shot；voice 行 `file` 为 null、`voice` 是 wav 路径）、
`"project": id | "inbox" | null`（null = 卡片，还没分）。归属 = 追加一行 `{"n": 3, "project": "<id>", "assigned_by": "user"|"ai"|"capture"}`
（同 n 后写的为准）；然后调 `AppEnvironment.process(session, captures: [3], project: "<id>")`（Tauri：`process_captures`）。
「交给 AI 分」= `process(session, captures: 所有卡片, project: nil)`。删卡片 = 追加 `{"n", "deleted": true}`。
（v0.8.1）拖进别的应用、被接住的卡片 = 追加 `{"n", "taken": <wall>}`：不再是卡片，也没删（文件留着），在「最近拖走的」里保留 7 天
（`BlurtCore.TakenCaptures`），挂回刘海 = `{"n", "taken": null}`；7 天后启动整理 / 每小时的 `Snapper.expireTaken` 按删卡片处理（进废纸篓）。
`captures.py file` 跳过 taken 的（`reason: "taken"`）。这是捕获的标记，不是条目状态，K3 的 `lifecycle.json` 不变。
（v0.8.7，捕获审计）卡片不会自己消失：启动时读所有 `-shots` 批次里还有卡片（或拖走的）的那些，不管多久以前（之前只看最近 30 天，更早的卡片
重启后就不见了）；先只解析 `shots.jsonl`（`BlurtCore.CardBatches`），有卡片才读图片。编辑备注 = 完整备注（打的字 + 说的话）可直接改，
改了说的话就以改后的为准（`said` = 改后的文字，`text` = null，`BlurtCore.NoteEdit`）；重录先写 `shots/NNN.retake.wav`，留下才替换原来的 wav，
Esc 或没说话只删重录（`VoiceRetake`；之前直接覆盖原文件，Esc 后原语音就没了）。⌥⇧V 的 Esc 只在前 10 秒有效（Esc 是全局快捷键，
一直占着会让 Claude Code、vim 里的 Esc 失灵），取消后「语音备注已丢弃 · 撤销」5 秒，音频留到那时。截图的语音备注开始听时就拉起常驻语音服务，
转写不再冷启动。拖进代码编辑器（VS Code、Cursor、Windsurf、Zed、Xcode、JetBrains…，`ComposerKind.editor`）只放图片，备注进剪贴板，
口喷鸡不自己粘贴（落点可能是代码）。
卡片交出去的文件写在批次的 `out/<NNN>/`：`截图-HHMMSS.png`（备注写进 PNG 的 iTXt Description）+ `截图-HHMMSS-备注.md`（v0.8.2：只有备注，不再有图片行），
拖动 / 复制时是两个 pasteboard item：①图片文件 + PNG；②.md 文件 + 同一 item 上的备注文字（一行，`CardTransfer.dragText`）。
原因：用户把截图卡片拖进 Claude 桌面版（Electron），角标是 2，但只附上了图片——网页应用有文件时就不看散落的文字。
（v0.8.2）拖进微信却多出一个 .md 附件：第二个 item 改为按指针下的应用决定（`BlurtCore.DropTargets` / `CardDrag.swift`，懒提供数据，
指针进入另一类应用时重写拖动 pasteboard）：网页 / Electron = .md + 文字；微信、备忘录等 = 文字（图片另带 RTFD）；终端 = 只有两个路径；
访达 = 两个文件；不认识的应用 = .md + 文字。
拖走成功且有备注时，备注也放进剪贴板（`record.drag_copy_note`，默认开），岛上「已拖走 · 备注已复制，⌘V 可粘贴 · 撤销」；
`record.drag_caption`（默认关）把备注印在拖出去的图片副本下方。

**截图**：快捷键 ⌥⇧A 在录屏中 = 只截、不暂停、不弹框（截图飞进岛的计数）；点岛上的截图按钮 = 截图并暂停、弹出备注框，填完或关掉自动继续。
不在录屏时 ⌥⇧A = 选区截图 + 自动开麦的备注（同 v0.6），结果按上面的规则变成卡片或直接进岛。

**语音输入**：⌥⇧V。按一下 = 开始，静音 1.5 秒（`record.voice.silence_ms`）自动结束，最长 120 秒；按住超过 0.35 秒 = 按住说话，松开结束；
`record.voice.mode`：`auto`（两种都支持，默认）| `toggle` | `hold`。录音存成 `shots/<NNN>.wav`，用 K9 的 `transcribe.py note` 转写，
写进同一行的 `said`。有当前项目 → 直接进岛整理成一条；没有 → 挂一张语音卡片。录屏中按 ⌥⇧V 不生效（提示一句：录屏已经在录音）。

**快捷键**：新增两个动作，配置键在 `record.hotkeys` 里：`voice`（默认 V）、`project`（默认 O），默认修饰键同其它（⌥⇧）。
`_common.HOTKEY_ACTIONS` / `HOTKEY_DEFAULT_KEYS`（P1）、Swift `HotkeyCenter.Action`（P5：`case voice, project`）、Tauri（P8）同一份名字；
都可以在设置里改或关掉。⌥⇧V 需要按下和松开两个事件（Carbon `kEventHotKeyReleased`）。

**主窗口不再自动弹审核**；独立的审核窗口（`ReviewWindow.swift`）删除，审核嵌在主窗口（P4）。

**细则（P5）**：
- **文件**：`Capture/Island/`：`Island.swift`（窗口、几何、弹簧、悬停、抽屉、提示、孵化）、`IslandContent.swift`（展开后的内容）、
  `Ears.swift`（耳朵）、`Claws.swift` + `ClawArt.swift`（鸡爪卡片）、`Motion.swift`、`IslandRecording.swift`、`IslandModule.swift`、
  `FrameCapture.swift`（测试 / 文档用的离屏渲染）；`Capture/Captures.swift`（捕获的去处、批次、分配、合并 8 秒、恢复）、`Capture/VoiceInput.swift`。
  删除了 `Rope.swift`、`Perch.swift`、`HUD`（`Capture/HUD.swift` → `Chrome.swift` 只留边框、倒计时、字幕）、`HUDLive.swift`、`NestView`。
- **窗口层级**：卡片面板 `.statusBar`、岛 `.statusBar + 1`（盖住菜单栏和腿）、备注气泡 `.statusBar + 2`。`isFloatingPanel` 要在 `level` 之前设，
  否则 level 被重置成 `.floating`（v0.6 的鸡舍一直在这个坑里）。
- **卡片只在你看的时候挂着**：捕获后 3.2 秒、指针在岛上 / 卡片上、岛展开、拖动中、备注打开时爪子放下来；否则 0.4 秒后爪子把卡片拉出屏幕顶，
  左耳显示待分配的卡片数。卡片上沿 = 岛当前底边 + 18 pt（岛展开时卡片跟着下移，腿变长）。
  （v0.8）指针一到岛上就由岛推给卡片（`hanging.islandAttention()`），不再等卡片自己的轮询；指针在卡片上时岛保持展开。
  **故意放下来**：点左耳的数字、⌥⇧H「显示挂着的卡片」（`record.hotkeys.cards`）、菜单、主窗口收件箱顶上的「还没归属的捕获 N 条」→
  卡片一直挂着，直到指针到过卡片再离开，或 Esc。指针停在左耳上时岛 450 ms 才展开，好让数字点得到。
  坑：卡片面板收起时被 `orderOut`，视图的 display link 在屏幕外不再触发，`MotionDriver` 永远等不到「静止」，空闲轮询也就不跑了——
  这就是「语音之后卡片收进去就再也拿不回来」。现在 orderOut 前先 `driver.rest()`，`wake()` 遇到窗口不在屏幕上只轮询。
- **展开后的第一行用刘海两侧**：首页 = 左边当前项目、右边录屏 / 截图 / 语音；抽屉 = 左边标题、右边已输入的过滤词。录屏、语音、提示的内容从刘海下面开始，
  耳朵继续显示时间等。没有别的事时首页多一行快捷键提示。
- **悬停 vs 按键打开**：悬停打开的离开 400 ms 收起；快捷键 / 命令打开的（`setOpen(_, sticky: true)`）要等指针进来再离开才收，或 Esc。语音输入期间保持展开。
- **voice 行**：`{"n","type":"voice","file":null,"voice":"shots/NNN.wav","said":null|text,"duration":s,"project":…}`；`said` 在
  `transcribe.py note` 返回后再追加一行写入（没有这个命令时为 null，整理时 agent 转写）。按住手势里静音不结束；没听到语音的不归档。
- **「交给 AI 分」的标记行**：`{"n","project":null,"assigned_by":"ai"}`（不再是卡片；ingest 按条 route）。`assigned_by` 有值的都不是卡片。
- **合并**：带项目的捕获 8 秒内合并成一个 `process(session, captures, project)`；拖到项目 / 待分配的卡片 1.2 秒内合并（连续拖几张时一个任务）。
- **孵化**：`expectProcess(session, captures)` 立刻在右耳放蛋；`JobStore` 里 session 相同（realpath 比较）、captures 有交集的 process 任务接管它，
  结束时破壳 0.6 s → `+N`（N = 任务的 items 数），1.6 s 后换成待审数。120 秒没有任务接管就静默去掉。
- **完成的鸡**（`System/Peck.swift`）：`PeckCard.shared.play(title:detail:uid:state:)`，`state` = `to_verify`（pleased）| `done`（delighted）；
  10 秒内的多条合并成一句（「3 条待验证」），只在岛里显示，不再有右上角的卡片窗口。点 = 打开那一条（多条 = 收件箱）。
- **过渡期**：P4 的 AgentHub 还没写 process 任务时，`IslandModule` 装一个 `AppEnvironment.process` 的兜底（`LegacyProcess`：建 process 任务、
  走 v0.6 的 `App.process(dir)`），v0.6 AgentHub 的 `perch.hatch / hatched` 调用落到它上面；AgentHub 换成任务后删掉 `LegacyProcess` 和 `perch`。
- **测试钩子**（`BLURT_TEST_COMMANDS=1`）：`BLURT_TEST_STILL=<png>` 代替屏幕截图、`BLURT_TEST_PROCESS=done|failed` 代替真正的 agent 整理、
  `BLURT_TEST_MIC_WAV` / `BLURT_NOTE_WAV` 代替麦克风、`BLURT_TEST_PASTEBOARD=<名字>` 让卡片拷贝进私有剪贴板、`BLURT_ISLAND_DX=-560`
  把岛画到刘海左边（指针测试碰不到用户自己的岛）、`BLURT_TRACE_CARDS=1` 每帧变化时输出 `cards_frame`（最新一张卡片露在岛下的比例，查闪烁用）、
  `BLURT_TEST_WORDS_DELAY=<秒>` 让转写晚到（测语音卡片在文字出来前被拖）；命令见 `SnapApp.swift` 文件头（`island`、`voice down|up|tap`、`assign`、`aisort`、`project`、
  `framerec`、`mascotframes`、`mascot`、`fakerecording`、`peck`）。

**细则（polish，合并后）**：鸡爪已按「决定」换成细线（macOS `Capture/Island/HangingCards.swift`，`Claws.swift` / `ClawArt.swift` 删除；
Tauri `web/apps/overlays/src/island.ts` 同步）。线从岛下沿内 3 pt 出来，1 pt 发丝线（浅色 42% 黑、深色 55% 白，带反色光晕），线头 7 pt 品牌色圆扣
（1.5 pt 卡面色描边）；各位置额外线长 `[0, 9, 3, 12, 5, 10, 2]` pt（风铃，不齐）；岛比卡片窄时（无刘海的胶囊）线头收向岛内、呈扇形。
不看时卡片沿线收回岛里（缩到 0.7、淡出），不再从屏幕顶边拉走。拖走时线跟着卡片拉长，超出静止长度 44 pt 即断开回弹（outBack 0.32 s）；
没放到目标上时线重新垂下（0.3 s）接住、圆扣弹出。删除时线松开弹回、卡片掉落。按种类区分的彩蛋（`EggKind`、`assets/icons/eggs/`、
`<Egg>`）和 perch / claw / nest 图标一并删除；蛋只剩岛上孵化用的那一个。

**细则（省 token，2026-10-22 试用反馈后，优先于上文 K7 的「直接进岛整理」「8 秒合并」）**：agent 只在用户要求时跑，一批一次。
- **有备注 + 有项目 = 直接成条目，不跑 agent**：截图的备注（打字，或说话后本机 `transcribe.py note` 转写进同一行的 `said`）、语音输入的转写
  就是条目。`captures.py file SESSION --captures N… [--project P]`（新脚本，经 items.py 的 `add` 写）：title = 备注第一句（≤ 80 字），quote = 备注全文，
  kind = 本地关键词猜（issue / task / idea，其余 note，中英日西法德），frames = 截图（有墨迹的版本在前），`source.shot` = n，本地 id `C-NNN`（再调一次跳过），
  条目多一个 `enrich: pending`。应用照样建一个 process 任务（title「按备注直接归档」，`usage = {tokens: 0, agent: null}`），岛上孵化 +1，
  岛里一句「已归到 ordo-platform · OP-14」（项目 key 徽标、项目色）。
- **没备注 = 卡片**，即使选了当前项目（截图行改回 `project: null, assigned_by: null`，卡片留在原 store 的批次里；重启时 inbox 和各项目 store 的批次都恢复卡片）。
  current = auto 时有备注的捕获也是卡片。拖卡片到项目 / 待分配 = 同样用 `captures.py` 直接归档（没备注的标题是「截图 14:32」），不跑 agent。
- **交给 agent 的只有**：岛上「整理」（有当前项目时：所有卡片整理进它）/「交给 AI 分」（auto：按条分项目）—— 每个批次一次调用；
  主窗口右键「AI 补全」（`App.enrich(uids)`：一次调用，按 lens 补 kind / 步骤 / code_refs，`items.py patch … --unset enrich`）；录屏结束的整理。
  它们都用**整理用模型**（K5 细则）。
- **Esc = 取消**：备注气泡里 Esc（或垃圾桶按钮）丢弃这张截图（文件进废纸篓，追加 `{"n","deleted": true}`），岛上「已丢弃 · 撤销」3 秒；
  撤销把文件从废纸篓移回、追加 `{"n","deleted": false}`，连同已打的字 / 说的话按正常流程走。⏎（或 ✓ 按钮）= 留下（没备注就成卡片）。语音输入 Esc 照旧取消。
- **迁移后问一次**：`projects.json` 多 `current_by: "user" | "migrate"`（`projects.py use` 写 user；`migrate` 写 migrate；早先迁移过、没有这个键而 current
  不是 auto 的也补成 migrate）。应用启动整理完后，`current_by == "migrate"` 时岛上问「截图、语音默认归到 X（沿用旧设置）还是自动分配？」[归 X] [自动分配]，
  不会自动消失；两个答案都经 `projects.py use` 记成 user。
- **当前项目一眼可见**：岛上项目按钮 = 项目色的 key 徽标 + 名字（放不下时名字截断，徽标不截）；备注气泡状态行先写「→ 项目名」。

### K8 · 种类图标和状态圆环

- 种类图标（P6 新增到 `assets/icons/`，所有平台由 `build.py` 生成；macOS 上优先用 SF Symbol）：

  | kind | 图标名 | SF Symbol | 颜色（浅 / 深，起始值，P6 定终值，图标和背景对比度 ≥ 3:1） | 本地化键 |
  |---|---|---|---|---|
  | issue | `bug` | `ladybug` | `#D93D42` / `#FF6B6B` | `kind.issue` |
  | idea | `lightbulb` | `lightbulb` | `#B7791F` / `#FFC53D` | `kind.idea` |
  | note | `document` | `doc.text` | `#3E63DD` / `#8DA4EF` | `kind.note` |
  | task | `checklist` | `checklist` | `#218358` / `#3DD68C` | `kind.task` |
  | 自定义 lens | `tag` | `tag` | 名字哈希出色相，HSL(h, 55%, 42%) / HSL(h, 70%, 68%) | lens 名 |

  web token：`--kind-issue`、`--kind-idea`、`--kind-note`、`--kind-task`（`packages/ui/tokens.css`）；Swift：`KindStyle.icon(_ kind: String) -> BlurtIcon`、
  `KindStyle.color(_ kind: String) -> NSColor`（动态浅深色）。同一批新增图标：`terminal`（`apple.terminal`）、`folder-plus`（`folder.badge.plus`）、
  `git-branch`（`arrow.triangle.branch`）、`git-pull-request`（`arrow.triangle.pull`）、`send`（`paperplane`）、`bell`（`bell`）。
  在这批图标合并之前，其他包用名字查（Swift `BlurtIcon(named:)`、web `<Icon name="…">`），查不到时临时用现有图标，合并后删掉兜底。
- **状态圆环**（处理状态，列表 14 pt、详情 18 pt，线宽 1.5 pt）：

  | state（K3） | 画法 | 颜色 |
  |---|---|---|
  | new | 虚线圆环（8 段） | 品牌强调色 `--accent` |
  | todo | 空心圆环 | 次要文字色 |
  | handed_off | 圆环 + 中心 4 pt 圆点 | 品牌强调色 `--accent` |
  | in_progress | 圆环 + 半圆填充（右半） | `--accent` |
  | to_verify | 圆环 + 实心圆，中间一个小 `!` 形状（图形，不是文字） | 提醒色 `#E5A000` / `#FFC53D` |
  | done | 实心圆 + 勾 | `--keep`（绿） |
  | wontfix | 圆环 + 45° 斜线 | 三级文字色 |
  | discarded | 圆环 + ×（两条对角线） | 三级文字色 |

  **2026-10-22 改版（K3 一条生命线）**：每条只显示**一个**圆环（不再有行首的 draft 圆点和单独的「审核」列）。new 的虚线圆环 = 还没看过；
  discarded 只在「已丢弃」筛选里出现，标题变淡。圆环可以点：弹出 K3 的动作菜单（只列当前状态能做的，动词 + 一句说明 + 快捷键）。
  详情 / 检查器里是「状态胶囊」= 圆环 + 状态名 + 下拉箭头，同一个菜单。
  实现：web `StatusRing` 组件（`packages/ui`），Swift `StatusRing.image(_ state: String, size: CGFloat) -> NSImage`（模板化以外的彩色图，带无障碍描述 = `work.<state>` 的文案）。
- **蛋只用在品牌和动效**（整理中的孵化、破壳、完成时的鸡）。列表、侧栏、详情里不再用种类彩蛋和状态蛋（`EggKind` 只留给动效）。
  「完成提示里的鸡」重画成多层矢量插画，有几种表情，只在条目到「待验证 / 已完成」时出现（P5）。

**细则（P6）**

- **终值**：种类色 issue `#D93D42` / `#FF6B6B`，idea `#A8710A` / `#FFC53D`（浅色从 `#B7791F` 加深，在 `#EAEAEA` 上才够 3:1），
  note `#3E63DD` / `#8DA4EF`，task `#218358` / `#3DD68C`；圆环的提醒色 `--warn` = `#B86E00` / `#F5A524`（`#E5A000` 在浅底上只有 1.9:1），
  done 用 `--keep`（`#15965F` / `#2B9466`），handed_off / in_progress 用 `--accent`（`#F55B3E` / `#FF7A5C`）。to_verify 实心圆里的「!」
  浅色是白、深色是 `#2A1A00`；done 的勾是白。自定义 lens：色相 `h = (h·31 + UTF-16 码元) mod 360`，从 HSL(h, 55%, 42%) / HSL(h, 70%, 68%)
  起每次 2% 变深 / 变浅，直到在 `#EAEAEA` / `#383838` 上 ≥ 3:1。web（`tokens.css`、`ui/src/kinds.ts`）和 Swift（`KindStyle.swift`、
  `StatusRing.swift`）同值同几何，`tests/test_icons.py` 和 ui 的 vitest 校验。
- **圆环几何**（size × size，线宽 1.5，`u = size / 14`）：new 的虚线 = 环周长 `2πR` 分成 16 等份，画 / 空交替（`dasharray = 2πR/16`），
  从 12 点方向开始；discarded 的 × = `(c−2.1u, c−2.1u)→(c+2.1u, c+2.1u)` 和 `(c+2.1u, c−2.1u)→(c−2.1u, c+2.1u)`；环半径 `size/2 − 1.25`；handed_off 中心圆点半径 `2u`；in_progress 右半圆半径
  `R − 1.75u`；to_verify / done 实心圆半径 `R + 0.75`；「!」= 竖线 `(c, c−3u)→(c, c+0.6u)` + 圆点 `(c, c+2.85u)` 半径 `0.95u`；勾 =
  `(c−2.9u, c+0.1u)→(c−0.9u, c+2u)→(c+3u, c−2.2u)`；wontfix 斜线是环内 45°。y 向下。
- **图标**：`note.svg` 改名 `document.svg`，`task.svg` 由 `checklist.svg` 取代；`note`、`task`、`todo`、`idea`、`issue`、`lens` 作为别名
  （各平台 `BlurtIcon(named:)` / `<Icon name>` 照常能查到）。`bug` 改为 generic（macOS 用 SF `ladybug`）。
- **web API**：`@blurt/ui` 导出 `KINDS`、`WORK_STATES`、`kindIcon`、`kindStyle`、`customKindColor`、`workStateOf`（含 v2 fix 映射）、
  `ringShapes`、`statusRingSvg`；React 组件在 `@blurt/ui/react`（`<KindIcon kind size title/>`、`<StatusRing state size label/>`），样式在
  `base.css`（`.kind-ic`、`.sring`）。`@blurt/i18n`：复数键必须有 `_other`，zh-Hans 只需要 `_other`；`checkCatalogs(en, zh)` 比较去掉复数后缀
  的键和占位符；`formatDuration` 的 clock 样式向下取整（0.9 秒 = 0:00，同播放器）。
- **审核组件宿主协议 v3（定稿）**：
  - `BlurtHost.scope` = `{session: 绝对路径}` | `{project: id, status?, work?, kind?}`。macOS 的消息参数：`load {scope}`、`poll {etag, scope}`、
    `sendOps {ops, confirm, scope}`、`confirmed {scope}`；返回值同 v2（`{doc, etag}` / `{etag, doc?}` / `{ok, etag, doc?}`，sendOps 可以只确认）。
    scope 来自 `blurtHostInfo.scope`，没有就看 URL 的 `?project=` / `?session=`。
  - 可选方法（`blurtHostInfo.methods` 列出才出现）：`reveal {path}`、`quickLook {path}`、`openCode {ref}`、`dispatch {uids}`、
    `handoff {uids, what: "instruction"|"full"}` → `{id, path, text}`（要回复；宿主复制 `text` 并调 `handoff.py --mark`）、`openSession {job}`（Mac 早期读 `jobId`，现在两个都认）、
    `registerDragRects {rects}`、`download {path}`。`blurtHostInfo.sessionBanner: true`（Mac）= 宿主在页面上方的横幅里放了「打开会话」，
    已交出 / 进行中的条目工作面板就不再放第二个。`fixWithAgent` 删除。`path` 是 doc 里的原样路径（v3 绝对，v2 相对会话）。
  - `fileUrl`：v3 的绝对路径——浏览器 `files/` + `encodeURIComponent(绝对路径)`（**整个路径一个段**，`/` 编成 `%2F`；review.py 解码后只放行
    已登记的 store、会话目录和 `$BLURT_HOME/handoff`）；macOS `blurt-app://file/` + `encodeURIComponent(绝对路径)`；Tauri `convertFileSrc(绝对路径)`。
    v2 的相对路径照旧（`files/<逐段编码>`、`blurt-app://session/<rel>`）。
  - Tauri：`items_doc {scope}` → `{doc, etag}`，`items_poll {scope, etag}` → `{etag, doc?}`，`items_ops {scope, ops, confirm}` → `{ok, etag, doc?}`，
    `handoff_create {uids, full}` → `{id, path, text}`（Rust 侧复制并 mark）。`dispatch` / `openSession` 是外壳的导航，由 `web/apps/desktop` 给
    `createTauriHost(scope)` 的结果补上。
  - 组件发的 op：字段改动 = `set`（v3 一律用 uid 作 `id`；`set.project` = 用户换项目）；`{op: "work", id, state, note?}` = 用户的确认完成 /
    重新打开 / 不处理；`add` / `remove` 同 v2（v3 的 `merged_from` 和 `into` 是 uid）。id、work、work_history、aliases、path、updated、created、
    project_by / project_confidence / suggested_project 永远以服务端为准，组件不发。
  - **review.py 可选**（P1）：doc 带 `"_caps": ["handoff"]` 并实现 `POST /api/handoff {uids, what}` → `{id, path, text}` 时，浏览器页也显示
    「复制指令 / 复制全文」（页面在点击里用 ClipboardItem 复制，Safari 也允许）；没有就不显示。
  - 挂载：`mountReview(el, host, {embedded})`——嵌进主窗口时不显示品牌、主题和语言按钮，不改 `document.title`，填满 `el`，浮层只盖住 `el`；
    macOS 宿主默认 embedded（URL `embedded=0|1` 可改）。宿主可调 `window.__blurtSetLang("en"|"zh-Hans")` 跟随应用的 `lang`。
  - 审核状态：v2 会话（items.json）里「待审」= 本次审核还没动过；v3 doc 里 `status` 是持久的（confirmed = 保留，draft = 待审，行首强调色圆点）。

### K9 · 本地语音识别：按机器自适应

- **硬件探测** `transcribe.py probe`（P7）→ `{"os","arch","chip","perf_cores","eff_cores","ram_gb","gpu":{"kind":"apple|nvidia|none","name","cores"?,"vram_gb"?},
  "ane": bool, "on_battery": bool, "tier": "pro|standard|light|minimal"}`。档位（起始规则，P7 实测后可调，改了写进细则）：
  - `pro`：Apple Silicon、内存 ≥ 32 GB；或 NVIDIA 显存 ≥ 8 GB；
  - `standard`：Apple Silicon 16–24 GB；NVIDIA 4–8 GB；x86 ≥ 8 核且 ≥ 16 GB；
  - `light`：Apple Silicon 8 GB；x86 4–8 核且 8–16 GB；
  - `minimal`：内存 < 8 GB 或 ≤ 2 核（推荐云端，本地退回 SenseVoice 单线程）。
  例：这台 M5 Max / 128 GB / 40 核 GPU = pro。
- **模型注册表** `skills/blurt/scripts/asr_models.json`（P7）：`{"models": [{"id", "backend", "model", "languages": ["zh","en",…] | "multi",
  "size_mb", "ram_mb", "platforms": ["darwin-arm64", …], "requires": ["mlx"|"cuda"|…], "streaming": bool, "tiers": […], "verified": "run|docs"}]}`。
  固定的 id（P7 实测后定稿，见 `docs/design/asr-benchmark.md`）：`sensevoice-small`（sherpa-onnx int8，zh / en / ja / ko / yue）、
  `whisper-large-v3-turbo-mlx`（mlx-whisper，多语种）、`whisper-large-v3-turbo-q4-mlx`（同一模型的 4-bit 版，light 档的多语种；
  **替代原定的 `whisper-small-mlx`**：体积相同，small 的中文混出繁体字、错误率 16 %）、`whisper-large-v3-turbo-ct2`（faster-whisper，NVIDIA CUDA；
  ARM CPU 上 3 线程比实时还慢，不在 macOS 上列出）、`qwen3-asr-0.6b-onnx`（sherpa-onnx int8，30 种语言，任何 CPU）。实测后没收的：
  Qwen3-ASR 0.6B / 1.7B 的 MLX 版、Parakeet TDT 0.6B v3、Whisper small / medium、distil-whisper、FireRedASR2（理由见基准文档）。
- **推荐** `transcribe.py recommend [--languages zh,en,ja] [--purpose batch|live|note]` → `{"tier","languages","pick":{"model","backend"},
  "candidates":[{"id","languages","size_mb","ram_mb","rtf_est","quality_note_key","installed","fits": bool}]}`。规则（实测后，取代起始规则）：
  语言 = 配置 `asr.languages`（默认：系统首选语言 ∪ {en}）。Apple Silicon：batch 在 pro / standard 用 whisper turbo（各语种都最准，
  中文 1.6 % 也好过 SenseVoice 的 3.3 %），light 在 SenseVoice 说得好的语言（zh / en / ja / yue，参考错误率 ≤ 5 %，韩语 10.5 % 不算）上用
  SenseVoice、其余用 turbo 4-bit；live / note 用 SenseVoice（同样条件），否则同档的多语种模型；**pro 的 live = batch 模型**，录完字幕即最终稿。
  NVIDIA：batch 用 turbo（CUDA），live / note 同上。只有 CPU：SenseVoice 能覆盖就用它（CPU 上快 10 倍、同样准），否则 Qwen3-ASR 0.6B（CPU）。
  minimal：SenseVoice 单线程，有它不覆盖的语言时 `cloud_recommended: true`。只考虑峰值内存 ≤ 内存 40 % 的模型。
  `transcribe.py models` 列注册表和已装的；`transcribe.py setup --model ID` 下载；`transcribe.py bench --model ID` 实测 RTF 和峰值内存，
  结果存 `$BLURT_HOME/asr-bench.json`，设置页的对比表用它（没测过的显示估计值）。
- **自动选择**：配置 `asr.auto`（默认 true）：应用首次启动和硬件变化时按推荐设置 `asr.model`（三个用途各一个：`asr.models = {"batch","live","note"}`），
  需要下载的先问用户（显示大小）。`asr.auto: false` 时沿用 `asr.backend` / `asr.model`（旧键）。
- **资源上限** `asr.limits`：`threads`（默认 `max(1, min(4, perf_cores // 2))`）、`max_concurrent`（默认 1，`$BLURT_HOME/run/asr.lock` 计数，
  多出来的排队，任务步骤显示 queued）、`priority`（batch = utility / nice 10，live 和 note = user-initiated）、`max_memory_fraction`（默认 0.25，
  MLX 设缓存上限）。用电池时 batch 可以换成更轻的模型（`asr.on_battery: "lighter"|"same"`，默认 lighter）。
- **语音输入的快路径** `transcribe.py note WAV [--language auto]` → `{"ok","text","language","ms","model"}`；P7 可以加一个常驻的
  `transcribe.py serve`（空闲 5 分钟卸载模型），`note` 有服务就用、没有就进程内跑。
- **多语种**：默认 `language: auto`；`transcript.json` 的每段带 `language`（后端给得出时）；界面和条目都不能假设只有中英。

**细则（P7）**

- 档位规则按起始规则实现（`tier_for`）。Apple Silicon 的 `perf_cores` = 最快一级（M5 Pro / Max 是 Super 核，这台 6 个），`eff_cores` = 其余各级之和；
  `probe` 另给 `core_levels`、`fingerprint`（芯片 | 内存 | GPU），`fingerprint` 变了即「硬件变化」。
- 注册表每个本地模型另有 `name`、`install`（`files` 单文件 / `archive` 解压后只留 `keep` / `hf` 仓库，走 Hugging Face 缓存）、`package`（需要的 Python 包；
  缺了 `transcribe.py` 自己用 `uv run --with` 重跑，调用方不用管）、`rtf_ref` / `error_ref` / `ram_mb`（参考机实测）、`quality_note_key`（`Speech.strings`）。
  `default: true` 只标在 `sensevoice-small` 上：引导页下载的是它，更好的模型在设置 → 语音里推荐。
- **选择顺序**：`--model-id` / `--backend` 显式参数 > `asr.auto: false` 时的 `asr.models[用途]` > 旧键 `asr.backend` / `asr.model` > 自动。
  `asr.auto` 缺省为 true，但旧配置里写了非 SenseVoice 的 `asr.backend` 视为用户已选（auto 缺省 false）。自动时只用**已安装**的模型：
  `asr.models[用途]`（`auto --apply` 写的）> 推荐 > 推荐列表里第一个已装且覆盖语言的 > SenseVoice。设置页里手动选某个用途的模型 = `asr.auto: false`
  并写全三个用途。
- `transcribe.py auto [--apply]` → `{"ok","auto","tier","languages","models":{用途:id},"recommended":{用途:id},"needs_download":[{"model","size_mb","purposes"}],
  "hardware_changed"}`；`--apply` 只在 auto 时写 `asr.models` 和 `asr.hardware`（fingerprint）。**给 P4 / P8**：应用启动时跑一次 `auto --apply`；
  `needs_download` 非空且 `hardware_changed` 时提示一次（显示大小），用户同意后 `setup --model-id ID`，完成后再 `auto --apply`。
- `transcribe.py models` → `{"ok","models_dir","configured","auto","tier","platform","hardware","limits","languages","languages_set","selected":{用途:id},
  "recommended":{用途:id},"local_only","models":[注册表字段 + "installed","path"?,"approx","runs_here","fits","purposes","configured","speaks","bench"?]}`。
  `setup --model-id ID [--use all|batch,live,note]`（`--use` = 手动选中）；旧的 `setup --backend B` 照旧写 `asr.backend`。`bench --model-id ID [--languages …]`
  用 `say` 生成各语言样本（`asr_models.json` 的 `bench.samples`），给出每种语言的错误率、RTF、峰值内存、CPU 核数、GPU 占用，存 `asr-bench.json` 的
  `results[id]`。
- **资源上限的落实**：batch / bench 在 macOS 上用 `taskpolicy -c utility` 重跑自己（钳住进程里所有线程的 QoS；onnxruntime 等自己开的线程不继承
  `pthread_set_qos_class_self_np`）+ nice 10；Windows 用 BELOW_NORMAL；Linux nice。线程数同时设 BLAS / OpenMP 的环境变量和后端参数。
  `max_concurrent` 只管 batch 和 bench（录完的整理、截图批次的语音备注）：live 和 note 是用户正在等的，不排队。排队时 stderr 打一行，
  有 `$BLURT_JOB` 时往该任务的 events 追加 `{"source":"asr","event":"asr.queued","step":{"id":"transcribe","state":"pending"},"detail":{"queued":true}}`，
  拿到后追加 `asr.started`（step running）。等锁超时退出码 3、`code: lock_timeout`。
- **MLX 后端**的加载和每次推理都在它自己的一个线程上（MLX 的 stream 按线程，live.py 和 transcribe_track 都在工作线程里调用）。
- **Whisper 的混合语言**：用户的语言多于一种、而一个块转出的文字明显偏少（< 2.5 音节 / 秒；各语言实测正常 4–7）时，按 VAD 段检测语言，
  同一语言的连续段分开解码。实测一段英文接中文的 15 秒块原来只剩中文，现在全保留；单语种的准确率和速度不变。Whisper 的中日文 ASCII 逗号等
  转成全角。
- **语音输入**：`note` 冷启动 SenseVoice 1–2 秒、Whisper turbo 约 4.6 秒；`serve` 常驻后 0.3 秒 / 0.4–1 秒。**给 P5 / P8**：按下语音输入时就起
  `transcribe.py serve --preload`（已有服务时立刻返回 `{"already":true}`），说话期间模型已就绪；`note` 自动用它。服务在 `$BLURT_HOME/run/asr-serve.json`
  （127.0.0.1 端口 + 随机 token），空闲 `--idle` 秒（默认 300）卸载模型，`--exit-after` 秒（默认 1800）无请求退出。
- 设置 → 语音：这台 Mac（芯片、内存、GPU、档位）、自动选择开关、三个用途各用哪个模型、推荐但未下载的模型（大小、对你的语言错误率的改善）、
  你说的语言（自称名的标签，可增删）、模型对比（对你的语言的准确率、速度、内存、下载大小；实测的带徽章）、资源占用（线程、同时转写数、
  GPU 内存比例、用电池时更轻）、云端密钥状态、识别语言、镜像。文案在 `Resources/*.lproj/Speech.strings`。

### K10 · 本地化

- **语言设置**：config `lang` = `auto`（默认，跟随系统首选语言：`zh-*` → zh-Hans，其它 → en）| `en` | `zh`（旧值，等于 zh-Hans）。
  日期、数字、复数按「界面语言 + 系统地区」格式化（Swift `Loc.locale`，web `Intl` 带同一个 locale）；时长用本地化的格式（`DateComponentsFormatter` / `Intl.DurationFormat` 的兜底），相对时间用 `RelativeDateTimeFormatter` / `Intl.RelativeTimeFormat`。
- **Swift**：`Sources/BlurtApp/Resources/{en,zh-Hans}.lproj/<Table>.strings`，复数用同名 `.stringsdict`；按包分表，各自只改自己的表：
  `Common`（P4：kind / review / work / session / project 等通用词，键名见下）、`Main`（P4）、`Settings`（P4）、`Terminal`（P3）、`Capture`（P5）、
  `Speech`（P7）。查找：`Loc.t("main.inbox.title", table: "Main")`、`Loc.plural("capture.cards", table: "Capture", count: n)`。
  `record.py build`（P4）把 `*.lproj` 拷进 `Contents/Resources/`，Info.plist 写 `CFBundleDevelopmentRegion = en`、`CFBundleLocalizations = [en, zh-Hans]`。
  **每个包把自己文件里的 `L(zh, en)` 全部换成表里的键**；最后合并时 P4 删掉两个 `L` 函数。键用点分的英文小写（`capture.voice.listening`）。
- **web**：新包 `web/packages/i18n`（P6）：`createI18n(catalogs, lang)` → `{t(key, params), plural(key, n, params), formatDate, formatNumber, formatDuration, formatRelative, lang, locale}`；
  消息格式 `{name}` 占位、复数键 `key_one` / `key_other`（`Intl.PluralRules`），无运行时依赖。目录：每个包 `src/locales/{en,zh-Hans}.json`；通用词在
  `web/packages/i18n/src/common/{en,zh-Hans}.json`。URL 参数 `lang=en|zh|zh-Hans` 都认。
- **Rust**（托盘、系统通知，P8）：`apps/desktop/src-tauri/locales/{en,zh-Hans}.json`。
- **Python**：机器输出只给 `code`；面向人的长文本（交接单、提示词）在 `handoff.py` / `agents.py` 里带 en 和 zh 两套。
- **校验**：每个平台都有测试检查 en 和 zh-Hans 的键完全一致、占位符一致（Swift 表由 `tests/test_l10n.py` 检查，P4；web 由 P6 的 vitest；Rust 由 P8）。
- **通用键**（所有平台同名同义，en / zh-Hans）：
  `kind.issue` Issue / 问题，`kind.idea` Idea / 想法，`kind.note` Note / 笔记，`kind.task` Task / 任务；
  状态（K3 改版，取代 `review.*` / `work.*`）：`state.new` New / 新，`state.todo` To do / 要做，`state.handed_off` Handed off / 已交出，
  `state.handed_off.session` With {agent} / 已交给 {agent}，`state.handed_off.external` Copied to your agent / 已复制给你的 agent，
  `state.in_progress` In progress / 进行中，`state.to_verify` To verify / 待验证，`state.done` Done / 完成，`state.wontfix` Won't do / 不做，
  `state.discarded` Discarded / 已丢弃，`state.menu` Change state / 更改状态；
  动作 `action.<keep|hand_off|done|send_back|take_back|reopen|restore|wontfix|discard>` 和 `action.<…>.hint`（+ `action.done.hint_verify`），
  文字见 K3 的动作表；收件箱 `inbox.needs_you` Needs you: {parts} / 需要你看的：{parts}，`inbox.part.new` {n} new / {n} 条新的，
  `inbox.part.verify` {n} to verify / {n} 条待验证（部分用 ` · ` 连，0 的不显示），`inbox.empty.title` Nothing needs you right now /
  现在没有需要你看的，`inbox.empty.body` New captures, and items an agent says are finished, show up here. / 新捕获的条目，和 agent 说做好了的条目，会出现在这里。；
  `session.running` Working / 运行中，`session.waiting_input` Needs your input / 等你回答，`session.turn_done` Turn finished / 本轮完成，
  `session.exited` Exited / 已退出，`session.error` Error / 出错；
  `project.auto` Auto / 自动，`project.inbox` Unassigned / 待分配，`project.ai_sort` Let AI sort / 交给 AI 分，`project.open_folder` Open Folder… / 打开文件夹…；
  `handoff.copy_instruction` Copy instruction / 复制指令，`handoff.copy_full` Copy full text / 复制全文；
  `job.type.<type>`、`job.step.<id>`（K4 的每个 type 和 step id 都要有）。

细则（P4）：
- macOS 的表：`Common`（上面的通用键，另有 `job.state.*`、`time.just_now`、`action.*` 几个通用按钮）、`Main`（主窗口、菜单栏菜单、通知：`main.*`、`menu.*`、`app.*`、`notify.*`）、
  `Settings`（设置窗口和设置助手：`settings.*`、`onboarding.*`）。BlurtApp 里的简写 `T("key", args…)` / `TP("key", n, args…)`（`App/Strings.swift`）
  按键的第一段选表，其余照 `Loc.t` / `Loc.plural`。占位符用 `%@` / `%ld`，顺序和语言有关时用 `%1$@`。
- 原生菜单和按钮按 macOS 的大小写习惯（en 用 Title Case：`main.cmd.mark_done` = Mark as Done），状态名等标签用通用键（Mark as done）。
- 语言：config `lang` = `auto | en | zh-Hans`（`zh` 视为 zh-Hans）；`--lang` 优先（`Loc.setting`）。界面语言变化在重开应用后生效。
- 表放在 `Sources/BlurtApp/Resources/<lang>.lproj/`，`Package.swift` 把 `Resources` 排除在 SwiftPM 之外，`record.py build` 拷进 `Contents/Resources/`；
  `swift build` 出来的二进制按源码位置找表（`Loc.searchRoots`），测试可用 `BLURT_L10N_DIR`。
- `tests/test_l10n.py`：每张表两种语言键完全一致、占位符一致、复数有 other（en 还要 one）、代码里按名字引用的键都在表里、Common 有上面的通用键。

### 所有权、闸门和合并

**闸门 G0（扇出之前，一个提交，≤ 1 小时，由 P4 或协调方做）**：把下面这些跨包接口写成能编译的桩（空实现），提交到 `feat/live-snap`，
8 个包都从这个提交切 worktree。G0 之后，每个桩文件归表里的拥有者。

```swift
// BlurtCore/Loc.swift（P4）
public enum Loc {
  public static var language: String { get }          // "en" | "zh-Hans"
  public static var locale: Locale { get }
  public static func t(_ key: String, table: String = "Common", _ args: CVarArg...) -> String
  public static func plural(_ key: String, table: String = "Common", count: Int, _ args: CVarArg...) -> String
}
// BlurtCore/Projects/Projects.swift（P4）
public enum SessionKind: String { case video, shots, voice }
public struct ProjectModule: Equatable { public let name: String; public let paths: [String]; public let description: String }
public struct Project: Equatable, Hashable, Identifiable {
  public let id, name, key, slug, description: String; public let path, store: URL
  public let isInbox, isGitRepo, worktree: Bool; public let defaultAgent: String?; public let modules: [ProjectModule]; public let lastUsed: Date? }
public final class ProjectStore {
  public static let shared: ProjectStore
  public private(set) var projects: [Project]              // 已登记的，pinned 和最近使用的在前，不含 inbox
  public var inbox: Project { get }
  public private(set) var currentID: String?               // nil = auto
  public var current: Project? { get }
  public func project(id: String) -> Project?
  public func use(_ id: String?) async throws              // projects.py use
  public func open(folder: URL) async throws -> Project    // projects.py add
  public func update(_ id: String, _ patch: [String: Any]) async throws
  public func newSessionDir(_ kind: SessionKind) -> URL    // 当前项目（auto 时 inbox）store 的 sessions/<ts>[-shots|-voice]
  public var onChange: (() -> Void)?                       // 主线程；projects.json 变化
  public func reload() }
// BlurtCore/Jobs/Jobs.swift（P3）
public enum JobType: String { case record, snap, voice, process, route, agent }
public enum JobState: String { case queued, running, done, failed, cancelled }
public enum StepState: String { case pending, running, done, failed, skipped }
public enum AgentSessionStatus: String { case running, waitingInput = "waiting_input", turnDone = "turn_done", exited, error }
public struct JobStep { public let id: String; public let state: StepState; public let progress: Double? }
public struct JobError { public let code: String; public let message: String; public let hintKey: String? }
public struct AgentInfo { public let agent, mode, runner: String; public let tmuxSession, tmuxWindow, windowName, branch, handoff: String?
  public let cwd: URL; public let worktree: URL?; public let status: AgentSessionStatus; public let statusAt: Date?; public let exit: Int32? }
public struct Job: Identifiable { public let id: String; public let type: JobType; public let state: JobState; public let project: String?
  public let session: URL?; public let parent, title: String?; public let items: [String]; public let captures: [Int]; public let steps: [JobStep]
  public let progress: Double?; public let created: Date; public let started, ended: Date?; public let error: JobError?; public let agent: AgentInfo?
  public var isActive: Bool { get } }
public final class JobStore { public static let shared: JobStore
  public private(set) var jobs: [Job]                      // 有效状态（K4 的叠加规则），新的在前
  public var active: [Job] { get }; public func job(_ id: String) -> Job?
  public var onChange: ((_ changed: [Job]) -> Void)?; public func start(); public func stop() }
public final class JobWriter {                             // 应用自己是 owner 的任务（record / snap / voice / process）
  public init(type: JobType, project: String?, session: URL?, parent: String? = nil, title: String? = nil)
  public let id: String
  public func step(_ id: String, _ state: StepState, progress: Double? = nil); public func setItems(_ uids: [String])
  public func setCaptures(_ n: [Int]); public func setProgress(_ p: Double?); public func finish(_ state: JobState, error: JobError? = nil) }
// BlurtCore/Sessions/AgentSessions.swift（P3）
public enum DispatchMode: String { case together, parallel }
public enum WorktreeChoice: String { case on, off, auto }
public struct DispatchWarning { public let code: String; public let jobs: [String]; public let items: [String] }
public struct DispatchResult { public let jobs: [String]; public let warnings: [DispatchWarning] }
public final class AgentSessions { public static let shared: AgentSessions
  public var tmuxAvailable: Bool { get }
  public func dispatch(items: [String], agent: String?, mode: DispatchMode, worktree: WorktreeChoice, dryRun: Bool) async throws -> DispatchResult
  public func attachCommand(job: String) async throws -> (argv: [String], env: [String: String])
  public func openExternal(job: String, terminal: String?) async throws
  public func send(job: String, text: String, enter: Bool) async throws
  public func stop(job: String, kill: Bool) async throws
  public func finish(job: String, action: String) async throws -> [String: Any] }
// BlurtApp/App/AppEnvironment.swift（P4）——在现有基础上加：
protocol TerminalPaneHosting: AnyObject { var viewController: NSViewController { get }; func attach(job: String?) }
protocol TerminalHosting: AnyObject { func makePane() -> TerminalPaneHosting; func newSession(project: String?, items: [String]) }
protocol IslandHosting: AnyObject { func showSwitcher(); func toast(_ text: String, actionTitle: String?, action: (() -> Void)?) }
//   static var terminal: TerminalHosting?（P3 的 TerminalModule.install() 设）
//   static var island: IslandHosting?（P5 的 IslandModule.install() 设）
//   static var dispatch: (([String]) -> Void)?   替代 fixWithAgent（打开 P3 的派发面板：agent、方式、worktree、并发提醒）
//   static var process: ((_ session: URL, _ captures: [Int]?, _ project: String?) -> Void)?   P4 的 AgentHub 设：建 process 任务并整理
//   installModules() 依次调 MainWindowModule、SettingsModule、TerminalModule（新文件 Terminal/TerminalModule.swift，P3）、IslandModule（新文件 Capture/Island/IslandModule.swift，P5）
// MainWindowHosting 加：reveal(job: String)、reveal(project: String)、showInbox()
// BlurtApp/Icons/KindStyle.swift、StatusRing.swift（P6）：K8 的 KindStyle.icon/color、StatusRing.image
// BlurtCore/Hotkeys.swift（P5）：Action 加 case voice, project
```

**闸门 G1（P6 的第一个提交）**：`web/packages/i18n` 的 API（可先只有 en / zh-Hans 的通用键）和 K8 的新图标（`build.py` 重新生成全部产物）。
协调方尽早把 G1 合进 `feat/live-snap`，P8 合并后再用；在那之前 P8 先做不依赖它的部分。

**所有权**（只改自己名下的路径；`scripts/` = `skills/blurt/scripts/`，`mac/` = `skills/blurt/recorder/macos/`，`Sources/` = `mac/Sources/`）：

| 包 | 拥有的路径 | 提供 | 依赖 |
|---|---|---|---|
| **P1 storage-py** | `scripts/{_common,items,store（新）,projects（新）,index,mcp_server,review,export_local,feishu,frames}.py`；`scripts/record.py`（除 P4 的构建函数）；`docs/contracts/index-schema.sql`；`SKILL.md`；`reference/`（除 `asr.md`、`sessions.md`）；`tests/test_{items_v2,items_merge,review_persistence,index,mcp,smoke}.py` 和新的 `test_store.py`、`test_projects.py`、`test_migrate.py`；`tests/fixtures/{sessions,stores}/**` | K1、K2、K3 的存储实现，MCP，审核页 browser 后端，`HOTKEY_ACTIONS` 加 voice / project | jobs.py 的事件追加（没有就跳过） |
| **P2 sessions-py** | `scripts/{sessions,jobs,handoff}.py`（新）、`scripts/agents.py`、`scripts/agents.json`、`scripts/doctor.py`；`reference/sessions.md`（新，SKILL.md 由 P1 加一行链接到它）；`.claude-plugin/**`；`tests/test_{agents,agent_cli,agents_hotkeys}.py` 和新的 `test_sessions.py`、`test_jobs.py`、`test_handoff.py` | K4 的 jobs、K5、K6；`agents.py prompt work` | `items.py work/get`（P1；没合并前测试按旧的 `SESSION ID` 写法或跳过） |
| **P3 mac-terminal** | `mac/Package.swift`；`mac/Vendor/SwiftTerm/**`（固定版本的源码，带 LICENSE，保证离线 `swift build`）；`Sources/BlurtApp/Terminal/**`（新）；`Sources/BlurtCore/{Jobs,Sessions}/**`；`Sources/BlurtCore/Agents/**`；`Sources/BlurtApp/System/{FixRunner,FixWatcher}.swift`（删掉后台修复窗口，`enum Notify` 保留原样；FixWatcher 改成看 work → to_verify）；`Sources/BlurtApp/Settings/AgentsPane.swift`；`Resources/*.lproj/Terminal.*` | 嵌入终端、会话列表和派发面板、完成动作（diff / 合并 / PR / 丢弃）界面、`AppEnvironment.terminal` / `dispatch`、JobStore | K4、K5 的 CLI；ProjectStore（G0） |
| **P4 mac-main** | `Sources/BlurtApp/{MainWindow,WebHost,Onboarding}/**`；`Sources/BlurtApp/App/**`（除 `Hotkeys.swift`、`CarbonHotkeys.swift`、`HotkeySettings.swift`、`SnapApp.swift`）；`Sources/BlurtApp/Settings/**`（除 `AgentsPane.swift`、`SpeechPane.swift`）；`Sources/BlurtApp/System/{URLRouter,Spotlight,IndexLookup,SelfTests}.swift` 和新的 `System/JobNotifier.swift`；`Sources/BlurtCore/{Paths,Config,Script,Loc（新）}.swift`、`Sources/BlurtCore/{Index,Projects}/**`；`Sources/BlurtApp/main.swift`；`Sources/BlurtApp/Resources/*.lproj/{Common,Main,Settings}.*`；`mac/Info.plist`；`scripts/record.py` 的构建和安装函数（`swift_sources`、`swift_build`、`native_binary`、`prune_sparkle`、`remember_skill_dir`、`ensure_app_installed`、`sign_app`、`make_icns`、`cmd_install_app`、`cmd_build`）；`scripts/release-mac.sh`；`tests/test_mac_shell.py`、`tests/test_l10n.py`（新）；`.github/workflows/app.yml` | G0；主窗口「收件箱 + 项目」、打开文件夹、项目设置、审核嵌入主窗口（删独立审核窗口和自动弹出）、列表的种类图标和状态圆环、整理任务（AgentHub 写 job）、提醒规则、启动时的 migrate / gc / monitor、IndexReader v2 | K1 的 doc / user-ops、K2、K4、K8 的 Swift API（P6） |
| **P5 mac-capture** | `Sources/BlurtApp/Capture/**`（含新的 `Capture/Island/**`、语音输入；删 `Rope.swift`）；`Sources/BlurtApp/App/{Hotkeys,CarbonHotkeys,HotkeySettings,SnapApp}.swift`；`Sources/BlurtCore/Hotkeys.swift`；`Sources/BlurtApp/System/{Peck,Services}.swift`；`Resources/*.lproj/Capture.*`；`tests/test_{snap,e2e_recorder}.py` | K7 的刘海岛、鸡爪卡片、截图改义、语音输入、项目切换器、完成时的鸡；`AppEnvironment.island` | ProjectStore、JobStore（G0）；`transcribe.py note`（P7） |
| **P6 web-review** | `web/packages/{review,ui,icons,i18n（新）}/**`；`assets/icons/**`（含 `tools/`、`sf-symbols.json`）和 `build.py` 的全部产物（`Sources/BlurtApp/Icons/**`、`skills/blurt/assets/icons/**`、托盘图标）；`scripts/review.html`；`tests/test_icons.py`；`.github/workflows/web.yml` | G1；审核组件 v3（doc 范围、用 uid 发 op、每条的项目下拉和批量拖到项目、work 状态和确认完成、派发和交接按钮）、K8 全部视觉、`KindStyle` / `StatusRing`（web + Swift） | K1 的 doc 形状 |
| **P7 asr** | `scripts/{transcribe,live}.py`、`scripts/asr_models.json`（新）、`reference/asr.md`、`Sources/BlurtApp/Settings/SpeechPane.swift`、`Resources/*.lproj/Speech.*`、`tests/test_live.py` 和新的 `test_asr_select.py` | K9 | — |
| **P8 tauri-parity** | `apps/desktop/**`、`web/apps/{desktop,overlays}/**`、`crates/**`、`scripts/tk_recorder.py`、`tests/test_capture_ffmpeg.py`、`.github/workflows/{desktop,capture}.yml` | Windows / Linux 上的 K2（项目、切换器）、K4（任务、提醒）、K5（xterm.js；Linux 用 tmux 的 attach-cmd，Windows 用 ConPTY 的 app runner）、K6、K7（顶部胶囊、鸡爪卡片、语音、快捷键）、K8、K10 | 全部 Python CLI；`web/packages/*`（P6，经 pnpm workspace） |

- 共用文件：`.github/workflows/check.yml`（Python 测试）不改；`pnpm-lock.yaml`、`Cargo.lock` 不手工合并，合并时重新生成；
  本文件每个包只在自己 K 节末尾追加细则（P1：K1–K3；P2：K4–K6；P5：K7；P6：K8；P7：K9；P4：K10；P3、P8 在 K5 末尾）。
- **Tauri 新命令**（P8 实现，名字固定，参数 camelCase）：`projects_list`、`projects_add(path)`、`projects_use(id)`、`projects_set(id, patch)`；
  `items_doc(scope)`、`items_poll(scope, etag)`、`items_ops(scope, ops, confirm)`（替代 `review_*`）；`jobs_list(active)`，事件 `jobs://changed [Job]`；
  `sessions_dispatch(opts)`、`sessions_list()`、`sessions_finish(job, action)`、`pty_open(job) -> ptyId`（跑 attach-cmd 或 app runner 的 launch）、
  `pty_write(ptyId, data)`、`pty_resize(ptyId, cols, rows)`，事件 `pty://data {ptyId, data}`（base64）、`pty://exit {ptyId, code}`；
  `handoff_create(uids, full)`；`process_captures(session, captures, project)`；`voice_start()` / `voice_stop()`。`fix_with_agent` 和 `agent_run` 删除。
- **审核组件宿主协议 v3**（C6 的增量，P6 定稿，P4 / P8 / P1 照做）：`load` / `poll` / `sendOps` 带 `scope`；`fileUrl(path)` 收**绝对路径**
  （macOS `blurt-app://file/<百分号编码的绝对路径>`，只放行已登记的 store、会话目录和 `$BLURT_HOME/handoff`）；可选方法 `fixWithAgent` 改名
  `dispatch(uids)`；新增可选 `handoff(uids, what: "instruction"|"full") → {id, path, text}`（宿主负责复制到剪贴板并调 `handoff.py --mark`）、
  `openSession(jobId)`。项目列表取 doc 里的 `projects`。

**合并顺序**：G0 → G1 → P1 → P2 → P7 → P6 → P4 → P3 → P5 → P8。每合并一个都在本机跑：
`uv run -q --with numpy --with pillow --with "mcp>=1.20,<2" --with pytest pytest tests -q`、`pnpm -C web install --no-frozen-lockfile && pnpm -C web -r test`、
`(cd skills/blurt/recorder/macos && swift build)`、`python3 assets/icons/tools/check_glyphs.py`。

**各包的验收重点**（细节自定，都要能在这台 Mac 上自动跑；截图、录屏按全局规则只截自己的窗口，并留存到 `promo/cases/v0.7/<包名>/`）：
- P1：v2 夹具迁移后条目数、uid、fix → work 全部对上；`.git/info/exclude` 写入且幂等、`git status` 看不到 `.blurt/`；同一组 ops 走 `items.py user-ops`
  和 `review.py` 结果一致；两个进程各并发 100 次写不丢；用户手改 `.md` 后能读回；索引 v2 搜索中英文都命中。
- P2：私有 socket 的 tmux 里真起一个假 agent（脚本模拟 Claude 的 hook 调用和 Codex 的 notify），状态依次走完五种；`--dry-run` 给出并发警告；
  worktree 的 diff / merge / discard 在临时仓库里跑通；hook 进程 1 秒内退出且 stdout 为空；交接单里的图片是存在的绝对路径。
- P3：SwiftTerm 嵌入后能 attach 到私有 socket 的会话、输入和缩放正常；两个面板看不同窗口互不干扰；关掉再开能重新连上。
- P4：两万条合成数据下列表筛选 ≤ 100 ms（沿用 v0.6 的预算）；收件箱 / 待分配 / 项目三类视图；整理完成不弹任何窗口；en 和 zh-Hans 截图各一套。
- P5：用 `BLURT_TEST_MIC_WAV` 跑通语音输入两种手势；auto 模式下卡片挂起、拖到项目后 shots.jsonl 有归属行并生成 process 任务；减弱动态效果下没有摆动。
- P6：组件在 WebKit 和 Chromium 下按 uid 发 op、换项目后 id 变化不丢编辑；状态圆环六种 × 明暗截图；i18n 键一致性测试。
- P7：`probe` / `recommend` 在本机给出 pro 档和合理的选择；限制线程和并发生效（测试里看实际线程数和排队）；多语种样本（say 生成的中、英、日、西）都能识别。
- P8：Linux CI 里 tmux attach 和 xterm.js 往返；Windows 的 ConPTY 路径能编译（真机延后到 VM）；顶部胶囊和卡片在 X11 下能渲染。
