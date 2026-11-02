# Windows Agent 会话对齐 Mac（审计 + 实施记录）

范围：Agent 会话——会话列表、状态、会话窗格（标题栏、提示条、终端、结束卡片、桌面卡片）、交接面板（Hand Off to Agent /
New Session）、审核面板（Review Changes）、重启 / 收回、等你时的系统通知、应用重开后的恢复、在外部终端 / Claude 桌面版打开、
终端的样子。不含：主窗口怎么进到会话窗格（归主窗口那位：侧栏去掉「Agent 会话」行，任务列在列表上方，点开详情是本窗格）、
设置 → Agents（Windows 的 Agents 页写在 `SettingsView.tsx` 里，不是单独组件，整页归设置那位，本文不动）。

规格是 Mac 源码：`Terminal/SessionsModel.swift`、`SessionsPane.swift`、`SessionsViews.swift`、`DispatchPanel.swift`、
`FinishPanel.swift`、`HandoffKit.swift`、`SessionNotifier.swift`、`SessionRecovery.swift`、`TerminalSurface.swift`、
`TerminalStyle.swift`、`DesktopApp.swift`、`TerminalModule.swift`，BlurtCore 的 `Jobs.swift`（AgentInfo）、
`SessionOutcome.swift`。文案一字不改取自 `Resources/{en,zh-Hans}.lproj/Terminal.strings(dict)` 和 `Common.strings`
（`session.*`），放在 `web/apps/desktop/src/locales/*.json` 的 `ses.*` 下。

只在两种情况下和 Mac 不一样：Windows 的惯例（Ctrl 不是 ⌘、「在文件资源管理器中显示」、Cascadia Mono），或者系统能力不同
（Windows 没有 tmux：会话总在 Blurt 自己的 ConPTY 里跑）。每一处都写了原因。

「Windows 之前」= 本分支 2026-11-02 的 `SessionsView.tsx` / `DispatchSheet.tsx` / `Terminal.tsx`（截图
`before-sessions-{en,zh}.png`）。

## 1. 会话从哪来、怎么排

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 1.1 | 行来自 JobStore 的 agent 任务（`jobs/*.json` 折叠后的状态），实时 | `sessions.py list --all` 的行，`jobs://changed` 时重取 | 对齐：新命令 `sessions_rows` 读 agent 任务（同一份折叠后的 JSON），前端 `sessions.ts` 按 Mac 规则算 | 已做（mock 截图核对） |
| 1.2 | 留哪些：活着的；有 worktree 还没处理的；结束不到 24 小时的；用户「移除会话」的永远不列 | 全部 | 对齐（`$BLURT_HOME/ui/terminal.json` 的 `removed`，和 Mac 同一个文件） | 已做（mock 截图核对） |
| 1.3 | 排序：活着的在前（要你动手的最上：等输入 → 出错 → 本轮完成 → 运行中），然后结束的按新到旧 | 脚本给的顺序 | 对齐 | 已做（mock 截图核对） |
| 1.4 | 按项目分组，组名是项目名（收件箱 = 未归类名；设置会话 = 「设置会话」；没登记的用文件夹名） | 不分组，行里写项目 | 对齐 | 已做（mock 截图核对） |
| 1.5 | 行标题：tmux 窗口名（「BA-12, BA-13」）→ 事项编号 → 任务标题；副标题：第一个事项的标题（交接单 `## 1. BA-12 · 标题`），多个时「标题 +1」，最多两行不截断 | agent 名 + 窗口名；副标题 状态 · 项目 | 对齐：交接单标题由 Rust 读 `handoff/<H>.md` | 已做（mock 截图核对） |
| 1.6 | 一处措辞（`stateText`）：活着 = 状态词（「Working / Waiting for input / Waiting for you」），看门狗放弃 = 「No response」；结束 = 「Ready to review / Couldn’t start / Stopped with an error / Ended · no changes / Exited / Merged / Pull request opened / Pushed / Discarded / Kept for later / Taken back / Started again」；文件夹没了 =「Folder is gone」 | `session.<status>` 五个词 | 对齐 | 已做（mock 截图核对） |
| 1.7 | 状态记号（`SessionMark`，一个状态一个形状）：转圈弧 = 在干活；注意色圆环 + 点（变成时呼吸一次）= 轮到你（提问、本轮完成、可审核、没响应）；ok 圆 + 勾 = 已合并 / 已开 PR；错误圆 + × = 失败；空心环 = 结束没事可做；外指箭头 = 在桌面版里。减弱动态时不转不呼吸 | 8 px 圆点五种颜色 | 对齐：`StatusMark.tsx`（SVG），无障碍名用 `mark.*` | 已做（mock 截图核对） |
| 1.8 | 文字颜色：轮到你 = attnInk；失败 = err；其余次要色。结束且不等你的行 62 % 透明 | 无 | 对齐 | 已做（mock 截图核对） |
| 1.9 | 打开窗格时选谁：这个窗格上次看的（`ui/terminal.json` 的 `panes`）→ 要你动手的 / 最新活着的 → 第一行 | 第一行 | 对齐（窗格 id：完整窗格 `window`，主窗口嵌入 `main`） | 已做（mock 截图核对） |

## 2. 列表栏

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 2.1 | 列表顶上一条和标题栏同高的条：右边「隐藏会话列表」「新会话…」两个无边框图标按钮（Mail / 备忘录的样子）；列表隐藏时这两个按钮移到标题栏最左 | 无 | 对齐 | 已做（mock 截图核对） |
| 2.2 | 行：记号 10 · 标题 12.5 半粗 · 右上开始时间（「2 分钟前」，30 s 刷新）· 副标题 11.5 · 第三行「状态 · agent 名 · 分支图标」 | 两行 | 对齐 | 已做（mock 截图核对） |
| 2.3 | 底部计数，按同一套记号：「1 working · 1 waiting on you」，没有就不显示 | 无 | 对齐 | 已做（mock 截图核对） |
| 2.4 | 列表宽 220–340，默认 250 | 280 固定 | 对齐（250，可拖 220–340） | 已做（mock 截图核对） |
| 2.5 | 没有会话：列表让开，整个窗格就是空状态（「Your agents work here」+ 新会话… 按钮，中线在 40 % 高） | 空状态没有按钮，文案不同 | 对齐 | 已做（mock 截图核对） |
| 2.6 | 主窗口里嵌入时（`embedded`）：列表隐藏，标题栏不画列表开关和新会话 | 无嵌入模式 | 对齐：`<SessionsView embedded>`，主窗口那位用 | 已做（mock 截图核对） |

## 3. 标题栏（终端上方）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.1 | 记号 12 · 标题 13 半粗 + 项目名 12 次要 · 第二行「状态 · agent · 分支词（去掉 blurt/ 和事项编号，等宽，提示里是全名和基线）· 退出 Blurt 就结束」 | agent 名 + 窗口名 + 状态胶囊；第二行 项目 · 分支 · 开始时间 · 「在 Blurt 里运行…」 | 对齐 | 已做（mock 截图核对） |
| 3.2 | 右边固定一组：「在 Terminal 中打开」分体按钮（点 = 首选终端，箭头 = 其他已装终端）+ ⋯。只有活着、不是应用内运行、不在桌面版时才出现 | 「在终端中打开」「停止」「审核改动」三个按钮常驻 | 对齐；**Windows 上分体按钮不出现**：没有 tmux，会话跑在 Blurt 的 ConPTY 里，别的终端接不上（Mac 对应用内运行的会话也是同一规则）。Linux 有 tmux 时出现，菜单列 gnome-terminal / konsole / wezterm / kitty 里装了的 | 已做；Windows 不出现（应用内运行）；Linux 菜单项没在真机验证 |
| 3.3 | 结束且等审核、正在看输出时：标题栏多一个普通「Review Changes…」 | 有 worktree 就常驻主按钮 | 对齐 | 已做（mock 截图核对） |
| 3.4 | ⋯ 菜单：活着 → 中断（Control-C）、结束会话…、（没响应时）重启会话；结束 → 显示输出；可审核且活着 → Review Changes…；在列表中显示事项；在新窗口中打开；在访达中显示文件夹；打开交接说明；显示日志 | 无 | 对齐；Windows 名称「Interrupt (Ctrl+C)」「Show Folder in File Explorer」/「在文件资源管理器中显示文件夹」；「在新窗口中打开」**没做**（Tauri 应用现在只有一个主窗口，第二个会话窗口要新的窗口路由，留作后续）；「在列表中显示事项」交给主窗口（`onShowItem`） | 已做（菜单用主窗口那位的 Menu.tsx，它的 .mw-menu 样式他们还没加，暂时看不见菜单外观）；新窗口没做 |
| 3.5 | 结束会话先问（NSAlert 表单）：「End this session?」/ 正文 / End Session（破坏性）· Cancel | 「停止」直接停，而且对应用内运行的会话是直接杀进程、不告诉 sessions.py | 对齐：对话框；停止流程改对：先 Ctrl+C 两次等它退，再 `sessions.py stop`（标记 cancelled），「结束」再杀掉 | 已做；Windows 停止流程未在真机验证 |
| 3.6 | 应用内运行的会话：第二行注意色「Ends when you quit Blurt」，提示说装 tmux | 第二行「在 Blurt 里运行：退出 Blurt 会结束这个会话」 | 对齐措辞；提示文案按平台：Windows「Windows 上会话在 Blurt 里运行…」（没有 tmux 可装），Linux 照 Mac 说装 tmux | 已做（mock 截图核对） |
| 3.7 | 提示条：agent 卡在启动问题（信任文件夹 / Codex 的 hooks）时，标题栏下一行 info 图标 + 一句怎么答 | 无 | 对齐 | 已做（mock 截图核对） |
| 3.8 | ⋯「Continue in Claude Desktop…」：Claude 桌面版在、会话活着、已报告对话 id、desktop-check 说可以（10 分钟缓存）才出现；先问（没 MCP 时说要手动标记，并给 Install…）；然后 `claude --desktop --resume <id>` | 无 | 对齐。Windows 的会话在应用内运行，sessions.py 原来只接 tmux：`continue-desktop --stage prepare`（检查、先把任务标成已移走）→ 应用结束它的 pty → `--stage launch`（resume）；tmux 一步不变（tests/test_agent_handover.py 新增一例） | 已做；**未在 Windows 验证** `claude --desktop --resume` |

## 4. 终端区域没东西可显示时（覆盖层）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 4.1 | 连接中：品牌转圈 +「Connecting…」 | 无 | 对齐 | 已做（mock 截图核对） |
| 4.2 | 断开（tmux 客户端退了、会话还在）：图标、「Disconnected」、正文、Reconnect | 底部小条「会话已结束（码）」 | 对齐（只在 Linux tmux 会发生） | 已做（只在 Linux tmux；未真机验证） |
| 4.3 | 结束卡片：24 pt 记号 · 一句话标题（Ready to review / Codex couldn’t start / … stopped at its trust question / Ended with no changes / Session ended / Merged…）· 事项行（种类图标、编号、标题，最多 5）· 失败时原因 + 它最后 8 行输出（等宽框）+ 太旧时的更新命令 · 一行「现在在等什么」· 一个下一步做原生默认按钮：Review Changes… / Restart Session（失败）/ Show 事项（合并后）；旁边 Take Back、Show Output、Mark as Done 普通按钮；重启 / 收回进行中时按钮灰掉加转圈。文件夹没了：Take Back Items 或 Remove Session | 死掉的终端 + 底部小条 | 对齐 | 已做（mock 截图核对） |
| 4.4 | 显示输出：结束的会话看它留下的屏幕 | 无 | 对齐：应用内运行的会话退出后保留最后 1 MB 输出，「显示输出」回放（只读） | 已做（mock 截图核对） |
| 4.5 | 失败（接不上）：警告图标 + 原因 + Try Again；应用内运行的会话在 Blurt 退出后丢了 =「This session ran inside Blurt and ended when Blurt quit.」 | toast | 对齐 | 已做（mock 截图核对） |
| 4.6 | 桌面版卡片（Claude desktop）：窗口图标、「Working in Claude」、说明、事项、Review Changes…（有 worktree）+ Go to Claude（默认） | 无 | 对齐；Go to Claude 走 Rust `sessions_go_desktop`（打开 agents.json 的 `open`，claude://） | 已做 |
| 4.7 | 「在别的窗口显示中」（应用内运行的终端只能出现在一个窗格） | 无 | 保留差异：不需要——Windows 的终端是把 pty 输出广播给每个视图，几个窗格同时看都行 | 保留差异 |

## 5. 终端

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 5.1 | 配色：浅色 白底 #FFFFFF / 字 #1D1D1F；深色 #1C1C1E / #E8E8ED；16 色 ANSI 两套（TerminalTheme） | 自己的一套（#fbfbfa / #141416） | 对齐，逐色照抄 | 已做（mock 截图核对） |
| 5.2 | 字体 SF Mono 12.5（`terminal.font_size` 可调） | 13 px，Cascadia Mono 等 | 对齐字号和配置项；字体保留差异：Windows 用 Cascadia Mono（系统自带的等宽字体，Windows Terminal 的默认） | 已做（字体保留 Cascadia Mono） |
| 5.3 | 终端铺满到窗口边，文字内边距 上 8 左 14 下 8 右 8，边距是终端自己的底色 | 内边距 10/4/6/12，深色外框写死 #141416 | 对齐 | 已做（mock 截图核对） |
| 5.4 | 选区：系统强调色（macOS 默认蓝 #0A84FF）22 % / 36 % | 品牌 focus 色 22 % / 36 % | 保留差异：Windows 用 `--focus`（跟系统强调色，Windows 的选区惯例），比例照 Mac | 保留差异 |
| 5.5 | 不响铃（状态和通知会说什么时候要你） | xterm 默认（不响） | 一致 | 一致 |
| 5.6 | agent 打印的链接（http/https/file）可点开 | 不能点 | 对齐（xterm link provider，Ctrl+点击是 Windows 终端的惯例，这里点击即开，同 Mac） | 已做（未真机验证） |
| 5.7 | tmux 时隐藏滚动条（滚动交给 tmux），应用内运行时保留 | 一律有 | 对齐（Windows 永远是应用内运行 → 保留） | 已做（mock 截图核对） |

## 6. 交接面板（Hand Off to Agent / New Session）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 6.1 | 480 宽、24 边距、15 pt 标题「Hand Off to Agent」/「New Session」，右边是事项所属项目名（New Session 是项目弹出菜单）；没有图标头 | 「把 N 条交给 agent」 | 对齐 | 已做（mock 截图核对） |
| 6.2 | 标题下「交什么」：一条 = 种类图标、编号（固定 40 宽等宽数字）、标题；多条 =「6 items」+ 各种类图标和数目，展开列出 | 无 | 对齐 | 已做（mock 截图核对） |
| 6.3 | New Session：项目的 To Do 列表，标题右边 Select All / Deselect All；行首的种类图标在指针悬停或选中时变复选框；最多 7 行再滚动 | 没有 New Session | 对齐（列表栏的「新会话…」打开它） | 已做（mock 截图核对） |
| 6.4 | 一个设置框：Agent（弹出菜单，没登录的写「Codex (not signed in)」；说明行：检查登录中 / 「Sonnet · signed in」/ 注意色「Not signed in」+ 行内 Sign In…）、Sessions（多条时：One for all / One per item）、Separate branch（开关 + 一句话，分支名只在提示里；一条一个会话时锁定开） | 按钮组选 agent、模型下拉、Together / In parallel 卡片、worktree 复选框 | 对齐 | 已做（mock 截图核对） |
| 6.5 | › Options（记住开合）：Runs in（桌面版）、Model（「Default (Sonnet)」+ 列表） | 模型在主区域 | 对齐（Model 放进 Options；Runs in 见 6.9） | 已做（mock 截图核对） |
| 6.6 | 登录：先探选中的 agent（一两秒，Start 等它），再探全部；选择不会因为探测结果自己跳 | `agents.py detect` 全量带登录探测，选第一个装了的 | 对齐：`agents_detect` 加可选 `login` / `ids` | 已做；登录探测未在真机验证 |
| 6.7 | 不能开始的原因只说一次（提示块在事项下面），出路接管默认按钮：已在会话里 → Open Its Session；没登录 → Use Codex / Sign In…（弹出命令 + Check Again）；太旧 → 版本、最低版本、更新命令 + Check Again；没 agent → Open Agents Settings…；检查失败 → Try Again | 只有一行红字 | 对齐：Rust 把脚本错误里的 `job / version / need / fix / item_id / agent` 带回前端 | 已做（mock 截图核对） |
| 6.8 | 同时改同一个文件夹的提醒：提示块 + 底部两个按钮（Continue / Use a Separate Branch 默认）；其他警告是灰色提示块；no_git 归分支行，draft_confirmed 归底部那行 | 提醒框 + 两按钮；其他灰字 | 对齐 | 已做（mock 截图核对） |
| 6.9 | Runs in：Blurt 的终端（推荐）或 Claude 桌面版，按 agent 记住；桌面版没装 blurt MCP 时提示 Install… | 无 | 对齐：Options 里的「Runs in」（装了 Claude 桌面版才出现），记在 config `sessions.target`；Start 变成「Open in Claude」，底部说在 Claude 里确认文件夹并点发送；dispatch 回来的 `claude://code/new` 链接由 Rust 打开（只认 claude://）。是否安装：agents.json `desktop.app.windows`（`%LOCALAPPDATA%\AnthropicClaude\claude.exe`、`%LOCALAPPDATA%\Programs\Claude\Claude.exe`、Store 包的 `%LOCALAPPDATA%\Packages\Claude_*`）或注册了 `claude` 协议（HKCU / HKLM `Software\Classes\claude`）。没 MCP 的提示里 Install… 打开设置 → Agents（安装器归设置那位） | 已做；**未在 Windows 验证**：安装路径和包名、协议注册、Windows 版 Claude 是否接 `claude://code/new?folder=&q=` |
| 6.10 | 底部：左边一行实话（「SF-12 is new: handing it off accepts it.」「6 items · 1 new, accepted when handed off」或转圈 +「Starting…」）、Cancel、默认按钮按结果命名（Start Session / Start 6 Sessions） | Cancel + 开始会话；底下还有「或者复制给你自己的 agent」 | 对齐；复制那一行去掉（Mac 面板里没有，复制指令在事项的操作里，主窗口那位负责） | 已做（mock 截图核对） |
| 6.11 | Esc / Cancel 关闭；默认按钮回车 | Esc 关 | 对齐 | 已做（mock 截图核对） |
| 6.12 | 开始后：面板关，打开新会话 | 一样 + toast「Claude Code is on it」 | 对齐（去掉 toast，Mac 没有） | 已做（mock 截图核对） |

## 7. 审核面板（Review Changes）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 7.1 | 面板（480）：事项做标题（种类图标、编号、标题 +1），下面「分支 → 基线」只有分支等宽 | 终端上方的内嵌条 | 对齐：`FinishSheet.tsx` | 已做（mock 截图核对） |
| 7.2 | 文件框：标题「3 files changed +5 −2」+ 右边 Open Diff；目录变淡、文件名正常色；0 不显示；超过 6 行滚动；未提交改动一行说「Blurt commits the N uncommitted changes on this branch first.」 | 列表 + 「工作区有 N 处未提交改动」 | 对齐 | 已做（mock 截图核对） |
| 7.3 | 底部：左边有框 ⋯（Keep for Later、Discard…）、一行说明 / 转圈、Cancel、默认 Merge / Commit and Merge（⌘↩，裸回车不合并），箭头部分是 Open Pull Request | 丢弃 / 保留链接 + 开 PR + 合并到 main | 对齐；快捷键 Ctrl+Enter（Windows） | 已做（mock 截图核对） |
| 7.4 | agent 还开着：默认按钮是「End Session and Review」（先结束再重新看 diff），一行「Claude Code is still open.」 | 无 | 对齐 | 已做（mock 截图核对） |
| 7.5 | merge / pr 带上看过的 `reviewed`（`--expect`）：之后改过就拒绝，Review Again | 不带 | 对齐：`sessions_finish` 加 `expect` | 已做（mock 截图核对） |
| 7.6 | Discard 先确认，默认是 Cancel | 内嵌确认 | 对齐 | 已做（mock 截图核对） |
| 7.7 | 完成页：绿勾 + 「Merged」/ PR 链接 / 推送了但没开 PR… + 「Its items are waiting for you to verify.」+ Close · Show SF-9（默认） | toast | 对齐 | 已做（mock 截图核对） |
| 7.8 | 失败：会话或 worktree 没了 → 小警告（问号文件夹、标题、一句、Close）；其他 → 原因 + Close + Try Again / End Session and Review / Review Again | toast | 对齐 | 已做（mock 截图核对） |

## 8. 重启 / 收回 / 移除（SessionRecovery）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 8.1 | Restart Session：`sessions.py restart`，同样的事项、agent、模型开新会话；新会话打开 | 无 | 对齐：`sessions_restart`（应用内运行的会话直接在 ConPTY 里起） | 已做（未真机验证） |
| 8.2 | Take Back：`sessions.py take-back`；留了改动时 toast「Taken back. The session’s changes are still on its branch: review them first.」 | 无 | 对齐：`sessions_take_back` | 已做（未真机验证） |
| 8.3 | 同一个任务进行中再按无效，按钮灰 | 无 | 对齐 | 已做（mock 截图核对） |
| 8.4 | Remove Session（文件夹没了、事项也不在它那）：从列表永远去掉 | 无 | 对齐 | 已做：`sessions_memory(forget)` 写 `ui/terminal.json` |

## 9. 通知（SessionNotifier）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 9.1 | 何时：变成 等输入 / 本轮完成 / 结束 / 出错，Blurt 不在前台；用户自己结束的不报；开关 `notify.agent` | 等输入、本轮完成；结束不报；出错不报 | 对齐 | 已做（cargo test） |
| 9.2 | 标题「Needs your input · storefront」（项目名；设置会话写「设置会话」），正文「SF-9 · Avatar upload returns 500」+「and 1 more」；等输入时加上 agent 的问题；出错时加「Stopped with an error」 | 「Claude Code needs your input」/ 事项编号 | 对齐（Rust 读交接单标题） | 已做 |
| 9.3 | 10 秒内同类合成一条：「2 sessions need your input」，正文逐行列出 | 10 秒内第二条直接丢掉 | 对齐（同一个通知 id 不能改，Windows 上是再发一条合并后的） | 已做（Windows 上是再发一条合并后的通知，不是替换） |
| 9.4 | 不响 | silent | 一致 | 一致 |
| 9.5 | 点通知 → 打开那个会话 | 点了只把应用拉到前面 | 对齐：Windows 上会话通知改用 WinRT toast（`tauri-winrt-notification`，`on_activated` → `blurt://job/<id>` → 主窗口到前面并打开该会话）；toast 失败时退回插件的通知；安装版用应用 id `dev.blurt.desktop`，从 target\ 跑的开发版用 PowerShell 的 id | 已做；**未在 Windows 验证**；通知还在屏幕上时点击能打开会话，Blurt 已丢掉 toast 后从通知中心点可能只把 Blurt 拉到前面 |

## 10. 应用重开后

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 10.1 | tmux 会话活过应用；重开后窗格接回上次那个 | Windows 无 tmux；不记上次 | 对齐「接回上次那个」（1.9）；会话本身活不过退出是系统能力差异（标题栏 3.6 已说） | 已做（接回上次那个） |
| 10.2 | 应用内运行的会话：退出时结束；之后打开它 = 4.5 的失败卡片，可重启 / 收回 | 打开报错 toast | 对齐 | 已做 + 10.3 |
| 10.3 | （Mac 退出时 AppRunner 报告退出；tmux 会话活过退出） | 退出时应用内运行的会话被杀，退出事件常常来不及报，下次打开还是「运行中」转圈 | 保留差异（Windows 没有 tmux，每次退出都会发生）：下次打开时，启动前建的、没有 pty 在跑的应用内运行任务补报一次已退出，于是显示结束卡片（Restart Session / Take Back），不会一直转圈 | 已做（`sessions.rs` `orphaned`；未真机验证） |

## 11. Windows 试用（dogfood 11-02）修的

| # | 问题 | 处理 | 验证 |
|---|------|------|------|
| 11.1 | 交接面板在 Windows 上永远「没有可用的 Agent」：过滤读 `session`，可 `agents.py detect` 从不给（Mac 另外调 sessions doctor） | `detect` 每行带上 `session`（= doctor 的 `session_spec(d) is not None`），所有宿主一个来源；听写设置里的 Agent 列表同样好了 | test_agents.py；虚拟机交接面板列出 Claude Code、已登录（ww42-handoff-after） |
| 11.2 | 每次交接都停在「Read outside the working directories?」：交接单在 `$BLURT_HOME/handoff`，会话在项目 / worktree 里 | Claude 会话的 `--settings` 加 `permissions.additionalDirectories = [交接单目录]`（只加读写范围，用户自己的规则照旧）；Mac 一样受益 | test_agents.py；虚拟机两次真交接（worktree 开 / 关）都没有任何权限提问，读完交接单直接做完（ww45-handoff-unattended-after） |
| 11.3 | 应用内运行（ConPTY）的会话不读屏幕：信任提问、主题选择、提示页都显示「运行中」，没有信任那一行说明，没有一分钟看门狗，没登录也一直「运行中」 | 移植 Mac 读 tmux 窗格的那套：`pty.rs` 给应用内会话一个 vt100 屏幕，非空行和最后输出时间写到 `$BLURT_HOME/run/screens/<job>.json`（不在 jobs/ 里，免得每秒触发任务刷新），变了才写，最多一秒一次，结束删掉；`sessions.py` 的常驻 monitor 对 `runner == "app"` 读这个文件，走和 tmux 同一个 `_tty_fallback`（等待提问 + 说明、错误、看门狗）；agents.json 给 Claude 加首次运行的「Choose the text style」「Press Enter to continue」「Enter to continue · Esc to …」 | test_app_screen.py（信任 / 首次运行 / 没登录 / 看门狗）、pty.rs 单测；虚拟机新仓库：4 秒内「等待输入」+「Claude Code 每个仓库只问一次是否信任这个文件夹…」，答完转「运行中」（hook），做完「等你继续」（ww48-*-after） |
| 11.4 | Blurt 运行时用户的仓库文件夹改不了名、移不走（拒绝访问）：递归监视 `<项目>\.blurt` 一直开着目录句柄 | Windows 上项目的 store 改用轮询（1 秒，`notify::PollWatcher`），Blurt 自己的目录（收件箱、jobs、projects.json）仍用系统监视；被监视的 store 没了立刻刷新项目列表（显示找不到文件夹） | 虚拟机：Blurt 运行时 `os.rename` 项目文件夹成功，侧栏随即显示找不到（ww33-rename-while-running-after） |
| 11.5 | 主窗口「归入项目」（`process_captures` 带项目）还是启动整理用的 Agent | 和 Mac 的 Snapper.file 一样：选了项目的截图直接 `captures.py file`（`capture::file_now`），不用 Agent、不花 token；只有「让 AI 分」（不带项目）和整段录屏才走 Agent | 虚拟机：截图 1 归入 storefront → 立刻成为 STO-11，任务只有 prepare / write，没有 claude 进程 |
| 11.6 | 退出 Blurt 后整理用的 Agent 还在跑，任务一直「运行中」 | Agent 起在自己的进程组里；退出时 `sessions::end_organising` 结束整棵进程树，任务记为已停止（cancelled，没跑完的步骤记为跳过，不算失败），截图留在卡片里可以再整理 | 虚拟机：整理中从托盘退出 → claude.exe 没了，任务 cancelled |

## 实现位置

- Rust：`apps/desktop/src-tauri/src/sessions.rs`（Claude 桌面版 `desktop_apps` / `go_desktop` / `desktop_check` / `continue_desktop` / `open_links`、Windows toast `show_notification`、`rows`、`remember` / `forget`、`restart`、`take_back`、`finish --expect`、
  `stop` 的 Ctrl+C 流程、`detect_with`、错误附带字段 `rich`、通知文案 `notify_text` / `merge_recent`、`orphaned`），
  `pty.rs`（用户停止不算 agent 自己退出、结束后保留输出），`jobs.rs`（通知的状态转换）、`island.rs`（通知调用），
  `lib.rs`（新命令 `sessions_restart` / `sessions_take_back` / `sessions_rows` / `sessions_memory`，`agents_detect` 和
  `sessions_finish` 加可选参数），`locales/*.json`（`notify.session.*`）。`#[cfg(windows)]`：`sessions.rs` 的 `toast`（tauri-winrt-notification）和 `protocol_registered`（RegGetValueW），`Cargo.toml` 的 Windows 依赖加 `tauri-winrt-notification = "0.8"`（本来就经 notify-rust 在依赖树里）。Python：`sessions.py continue-desktop --stage prepare|launch`；agents.json 的 `desktop.app.windows` 和 `protocol`。
- 前端：`web/apps/desktop/src/sessions.ts`（模型，`sessions.test.ts`）、`components/SessionsView.tsx`、`StatusMark.tsx`、
  `Terminal.tsx`、`DispatchSheet.tsx`、`FinishSheet.tsx`、`HandoffKit.tsx`，文案 `locales/sessions.{en,zh-Hans}.json`
  （由 Mac 的 Terminal.strings 生成，`ses.*`），`styles.css` 末尾「agent sessions」一节（删掉了旧的 sessions / dispatch 样式）。
- 给主窗口那位：`<SessionsView embedded onShowItem onOpenSettings>`；`<DispatchSheet onOpenSession onOpenSettings>`
  （不传时「打开它的会话」退回 `onStarted`）。


## 12. 视觉评审第二轮（11-03）

细节见 main-window.md §14.14–14.20。要点：交接 / 新会话 / 审核改动面板改用设置页的主题化弹出按钮（不再是原生 `<select>`），次要按钮中性实心、默认按钮就是窗口的主按钮；结束卡片在 40 % 高处、「查看改动…」旁边有「收回」；应用内运行的会话在信任提问处退出时，`sessions.py event --event pane-dead` 也记 `stopped_at: trust` 和屏幕最后几行（原来只有 tmux 记），卡片说清原因；终端 `minimumContrastRatio: 4.5`、中文回落 Microsoft YaHei UI、细滚动条。没在 Windows 真机重拍（虚拟机已释放），只在 mock 里核对。
