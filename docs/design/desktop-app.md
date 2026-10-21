# 设计：Blurt 桌面应用（macOS 原生 + Windows/Linux Tauri）

2026-10-21 · 第 2 版（第 1 版建议三平台都用 Tauri，修订原因见 §1.4）· 状态：已定，按 §5 和 §6 并行开工
· 基于 `feat/live-snap`（v0.6）

目标：把「菜单栏小工具 + 浏览器审核页 + Python 脚本」升级成一个给 vibe coder 用的**想法/bug 管理器**：
跨项目管理录屏和截图批次，浏览历史条目，在应用内审核，一键交给 coding agent 去修，修完后状态回传到应用。

总原则不变：
- **录制中绝不打断**；
- **文件即契约**：agent 只通过 `items.py` 和文件和我们对接；
- 默认本地处理，不上传。

文中 [S#] 指文末来源；标「⚠」的结论还没有一手证据，要在工作包里实测。

---

## 0. 结论（TL;DR）

1. **macOS 继续做原生应用**：在现有 Blurt.app 上演进（AppKit 为主，局部用 SwiftUI），整个应用只有一个进程。
   - 现状：Blurt.app 磁盘占用 976 KB；本机实测空闲时常驻内存 58–84 MB、CPU 0.3–0.6%。
   - 已有约 6.1k 行 Swift：录制、选区、HUD、画笔、鸡舍、下蛋、备注气泡、菜单栏、Carbon 快捷键、agent 启动。
   - 改成 Tauri 后反而要同时维护 React、Rust、Swift 三种语言，还多出一层 IPC 和录屏权限（TCC）归属的风险，
     而所有浮层仍然得用原生代码写。
2. **审核页和条目详情只做一份 Web 组件**（`web/packages/review`）。它有三个宿主：
   - macOS 应用里的 WKWebView；
   - `review.py` 打开的浏览器页（SSH 和无桌面环境继续能用）；
   - Windows/Linux 的 Tauri 应用。

   除这块画布以外，macOS 上的侧栏、条目表格（NSTableView，几万条也流畅）、搜索、右键菜单、拖放、Quick Look、
   设置、Spotlight、URL scheme 都用原生实现。
3. **跨平台逻辑放在 Python 层，只写一份**。这一层随 skill 发布，没装应用的用户也能用：
   - `items.py`：唯一的写入口；
   - `index.py`：唯一会写 SQLite 索引的程序；
   - `mcp_server.py`：MCP 服务；
   - `agents.json` 加 `agents.py`：agent 适配表；
   - `live.py` / `transcribe.py`：语音识别。

   原生应用只做三件事：直接只读打开 `index.db` 渲染界面；通过子进程调用上面这些 CLI 完成写入和重建索引；
   负责采集、浮层和界面。
4. **Agent 集成分三层，都基于标准机制**：
   - SKILL.md：Claude Code、Codex、Kimi Code、ZCode 都能读；
   - 本地 MCP：四家都支持；
   - 应用直接拉起运行：headless 用 `claude -p` / `codex exec --json` / `kimi --print`；交互式用 `claude-cli://open` deep link 或终端。

   agent 调用 `mark_fixed` 后，应用里小鸡把虫子啄掉。ZCode 目前没有 CLI 或 headless 模式，只接 skill 和 MCP 两层。
5. **不再排周期，直接并行开工**：8 个工作包分别在独立 worktree 里由 agent 同时推进（§6）。
   - 各包之间的契约在 §5 里写死：items v2、CLI、SQLite schema、MCP 工具、适配表、审核宿主协议、Swift 模块边界、Tauri 命令。
   - Windows/Linux 的 Tauri 应用现在就在 macOS 和 CI 上构建并做冒烟测试，真机验证放到 GCP 虚拟机上。

---

## 1. 框架选型

### 1.1 硬约束

| 约束 | 现状 |
|---|---|
| 浮层不能被录进去（HUD、鸡舍、气泡、选区遮罩、画笔墨迹） | macOS：`sharingType = .none`，同时在 `SCContentFilter(excludingWindows:)` 里排除这些窗口；Windows Tk：`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` |
| 浮窗不能抢焦点（点鸡舍不打断当前 App，也不把全屏 App 踢出 Space） | `NSPanel` 加 `.nonactivatingPanel` |
| 全局快捷键，加上「按住 ⌃ 画笔」 | Carbon `RegisterEventHotKey` 加修饰键监听 |
| 平台采集 API | SCK 加 AVAssetWriter，音画同步误差不超过一帧（macOS 已实测） |
| 安装包小、看起来精致、一个人加 AI 能维护 | 用户约 80% 在 macOS |

### 1.2 macOS 正面对比：原生 Swift vs Tauri 2

| 维度 | 原生（AppKit 为主，局部 SwiftUI） | Tauri 2（React + Rust + Swift helper） |
|---|---|---|
| 体积 | **976 KB**（Swift 运行时随系统自带，本机实测） | 空应用约 5 MB [S1]，再加 Swift helper、插件、前端资源 |
| 内存 / CPU | **58–84 MB RSS，0.3–0.6% CPU**（本机实测，含鸡舍和 HUD） | 空应用约 96 MB（Release）[S1]，还要加上 helper 进程 |
| 录屏权限（TCC） | 单进程，权限直接归属应用，没有歧义 | helper 子进程的权限归属待验证（第 1 版最大的风险） |
| 浮层（NSPanel、sharingType、画笔、Carbon 快捷键） | 已经做好，并调过一轮 | 还是得写原生代码，通过 tauri-nspanel [S7] 或 swift-rs 接进来 |
| 几千到几万条的列表 | NSTableView 处理 1–3 万行依然流畅；SwiftUI List 在 1 万行以上明显卡顿，10 万行要几分钟才能响应 [S31][S32]。所以列表用 NSTableView，不用 SwiftUI List | WKWebView 里的虚拟列表能扛住，但选择、键盘、拖拽的行为要自己模仿 |
| 中文输入法、文本输入 | NSTextView / NSTextField 原生输入法行为 | WebKit 长期存在的 bug：确认候选词的那次回车 `isComposing === false` [S39]，必须自己加防护 |
| 右键菜单、拖到访达或终端、Quick Look | NSMenu、`NSDraggingSource`（鸡舍已经在用）、`QLPreviewPanel` | 菜单 API 能用；往外拖文件要装 drag-rs 插件 [S33]，拖到访达能否落地未确认；Quick Look 要自己写 Swift |
| Spotlight、App Intents / 快捷指令、Services、分享扩展 | 直接用系统 API。App Intents 依赖 Xcode 构建阶段提取元数据 [S36]，分享扩展要单独的扩展 target，这两项后放 | 都没有，只能写 Swift 插件 |
| VoiceOver | AppKit 控件自带无障碍信息 | 只能靠 ARIA，要逐个补 |
| 毛玻璃、窗口恢复、设置窗口 | `NSVisualEffectView`、窗口状态自动保存、标准设置窗口 | 毛玻璃可以做；要手动处理 Reopen 事件 [S35]；窗口状态要靠插件 |
| 后台行为 | 原生定时器加 `beginActivity` 控制 App Nap | WebKit 隐藏后会降频，要开 `disableBackgroundThrottling`（macOS 14+）[S37]，或者另外禁用 App Nap |
| Deep link | 在 Info.plist 里声明 `CFBundleURLTypes` | 只能在配置里静态注册，开发模式下不生效 [S35] |
| 自动更新 | **Sparkle 2**：增量更新，EdDSA 加 Apple 签名双重校验 [S34]（要求 2.9.2 及以上，修复了 CVE-2026-47121） | 官方 updater 每次下载完整的 `.app.tar.gz`，不支持增量 [S34] |
| 公证 | 两边一样：Developer ID（年费 99 美元）加 `notarytool` | 同左（Tauri 有内置流程） |
| 和 AI 一起开发的成本 | 弱项：Swift 公开代码少，SwiftUI 在常见代码数据集里不到 1% [S38]，并发相关的错误是重灾区。缓解：用 AppKit 这种稳定 API，配合编译器加测试的闭环；已经有 6.1k 行能跑的代码和熟悉的模式 | React 是 AI 最擅长的；但调试要跨 React、Rust、Swift 三层，问题落在哪一层不好定位 |
| 和 Windows/Linux 共享代码 | 只共享 Web 审核组件和 Python 层（§1.5） | 界面外壳也能共享 |

**结论**：在 macOS 上，原生在体积、内存、权限、浮层、系统集成、更新这几项都占优，或者两者持平。
Tauri 只在两点上占优：AI 写得更熟，以及界面外壳能和 Windows/Linux 共享。
第二点可以靠「审核画布用 Web 组件、逻辑放 Python 层」拿回大半，第一点不足以抵消三语言和 IPC 的成本。
所以 macOS 继续原生，协调方给出的这个判断成立。

### 1.3 审核画布：WKWebView 混合方案 vs 全原生

| | WKWebView 里跑共享 Web 组件（选定） | 全原生 SwiftUI / AppKit |
|---|---|---|
| 实现份数 | **1 份**，`review.py`、macOS 应用、Tauri 共用 | macOS 一份，浏览器和 Tauri 还要再维护一份 |
| 保住已调好的交互（868 行：聚焦模式、合并 / 撤销、字段补丁、帧陆续补入） | 移植成组件，有对拍测试保证一致 | 全部重写 |
| 原生感 | 文本输入有回车 bug，要加防护；拖拽和 Quick Look 交给原生层处理（见 §6 WP5） | 最好 |
| 风险 | WKWebView 的回车 bug [S39]、拖拽桥接 | 两份实现会慢慢不一致 |

**选定混合方案**。重新评估的触发条件：用户试用后反馈审核页「不像 Mac 应用」，
那就只把 macOS 上的条目详情改成原生，Web 组件继续服务另外两个宿主。

### 1.4 被否决的方案及理由（保留备查）

- **三平台统一 Tauri（第 1 版的建议）**：在 macOS 上，React、Rust、Swift 三种语言加 IPC，helper 子进程的录屏权限
  归属有风险，浮层仍然要写原生代码，不支持增量更新，内存约是现在的 1.5 倍，体积大 5 倍以上。
  对 80% 的用户没有带来任何好处。Windows/Linux 仍然用 Tauri。
- **Electron**：安装包 200–300 MB [S1][S2]。
- **Wails**：v3 还在 beta [S10]。
- **Flutter / Compose**：界面自绘、不像原生，审核页得重写 [S11]。
- **Qt**：C++/QML 对 AI 不友好，LGPL 合规成本高。
- **Windows/Linux 也做原生**（WinUI、GTK）：界面要再写两份，一个人维护不过来。
- **共享逻辑用 Rust 写一个 `blurt-core`**：可以只写一份，但 macOS 上又多出一种语言；而且 skill 用户（`npx skills add`）
  拿不到二进制，MCP 和搜索会变成「装了应用才有」。Python 层随 skill 走，覆盖面最大。
  只有在 Python 的性能确实不够时，才把热路径换成 Rust，并保持 CLI 契约不变。

### 1.5 进程结构和共享逻辑放哪

```
macOS: Blurt.app（单进程，Swift）
├─ BlurtCapture：录制、选区、HUD、画笔、截图、鸡舍、备注气泡、下蛋、LiveAudio（现有代码）
├─ BlurtCore：配置、路径、ScriptRunner（uv、登录 shell 环境）、HotkeyCenter、IndexReader（只读 SQLite）、Agents
├─ BlurtApp：菜单栏、主窗口（NSSplitView + NSTableView + WKWebView 画布）、设置、引导、URL scheme、Spotlight、Services
└─ 子进程：uv run items.py / index.py / agents.py / live.py / transcribe.py；以及 agent CLI

Windows/Linux: Blurt（Tauri 2）
├─ React 外壳（web/apps/desktop）加 review 组件；浮层窗口（web/apps/overlays，透明、置顶、contentProtected）
├─ Rust：只读 SQLite（rusqlite）、脚本调用、托盘、快捷键、blurt-capture crate
└─ 子进程：同一组 Python CLI；录制先复用 record.py 的 ffmpeg 引擎（§5 C8），以后再换成 WGC / PipeWire 原生实现
```

| 逻辑 | 放在哪 | 原因 |
|---|---|---|
| 写 `items.json`（补丁、锁、`_user`、`_removed`、uid、fix） | `items.py`（Python） | 已有实现和测试；agent、`review.py`、两个应用都走这一个入口 |
| 索引和搜索 | `index.py` 写入 `index.db`；原生应用直接只读 | 只写一份；读 SQLite 很便宜，界面不用等子进程 |
| MCP 服务 | `mcp_server.py`（stdio，官方 `mcp` SDK） | 不依赖应用，四家 agent 都能接 |
| Agent 适配表 | `agents.json`（数据）加 `agents.py`（探测、生成命令、安装） | Swift 和 Rust 只执行它返回的 argv，不重复拼命令 |
| 实时和离线语音识别 | `live.py` / `transcribe.py`，沿用现有的文件约定 | 和 Swift HUD 已经通过 `live/` 目录对接好了；以后要原生化可以走 sherpa-onnx 的 Swift API [S40] 或 Rust crate [S17]，契约不变 |
| 录制、浮层、快捷键 | 各平台原生 | 本来就各不相同 |

**Python 怎么交付**：
- 应用**不打包** uv。本机的 uv 二进制有 44 MB，打进去会让安装包从约 1 MB 涨到约 20 MB。
- 引导时检测 uv；没有的话，经用户同意后用官方安装器装到 `~/.blurt/bin/uv`，然后在后台预装依赖和 Python。
  这样也解决了 TODO 里「第一次跑 frames.py 要等 59 秒」的问题。
- uv 没装好之前，主窗口只读已有的 `index.db`；没有索引时只列出会话目录，写入操作置灰。

**安装包目标**：
- macOS：≤ 3 MB（含 Sparkle 后 ≤ 6 MB ⚠）；
- Windows NSIS：≤ 25 MB；
- Linux .deb：≤ 20 MB，AppImage ≤ 90 MB ⚠。

语音模型（SenseVoice 约 241 MB [S18]）在应用内按需下载，不计入安装包。

---

## 2. 产品与信息架构

### 2.1 主窗口（macOS：原生外壳 + Web 画布；Tauri：React 实现同样的布局）

```
┌ Blurt ─────────────────────────────────────────────────────────── ⌘K 搜索 ─┐
│ ● 录制 ⌥⇧R   📸 截图 ⌥⇧A          项目: [ my-saas ▾ ]            🥚 整理中 1 │
├──────────────┬──────────────────────────────────────┬──────────────────────┤
│ 收件箱    3  │ 条目  [issue ✓][idea][note][task]     │ (WKWebView 画布)      │
│ 全部条目  128│ 状态: 待处理 ▾  项目: 全部 ▾  时间 ▾  │ I-014 · issue · P1    │
│ 会话         │ ──────────────────────────────────── │ ┌──────────────────┐ │
│ Agent 运行 ● │ 🐞 登录按钮点击无响应    my-saas  2h  │ │  frame #1 (红框)  │ │
│ 导出         │ 🐞 价格页移动端溢出      my-saas  2h  │ └──────────────────┘ │
│ ── 项目 ──   │ 💡 学 Linear 的空状态    ideas    1d  │ ◀ 1/3 ▶  ▶ 片段 0:14 │
│  my-saas     │ ✓ 🐞 头像上传 500  → 已修 #a1c3   3d  │ "这个登录按钮点了…"   │
│  ~/Blurt     │ (NSTableView，右键菜单、拖拽、空格 QL)  │ [让 Claude 修 ⌘↩]     │
│ ⚙ 设置       │                                      │ 历史: 创建→确认→已修   │
└──────────────┴──────────────────────────────────────┴──────────────────────┘
```

- **收件箱**：未整理和待审核的录屏、截图批次。每项用蛋表示状态：🥚 待整理，晃动表示整理中，🐣 待审核。按 `↩` 开始整理。
- **全部条目**：跨项目、跨历史，数据来自 `index.db`，支持全文搜索。
  - 筛选维度：kind、status、fix_state、项目、严重度、时间、负责人、有无代码引用、导出去向；
  - 可以存成智能视图。
- **会话**：时间线；详情页是视频加字幕滚动（点字幕跳到对应时刻），条目在时间轴上打点，旁边是 digest。
- **条目详情**：帧（带框）、片段、原话、lens 字段、`code_refs`（用 `vscode://`、`cursor://`、`zed://` 在编辑器打开）、问答、事件历史和修复记录。
- **审核模式**（`R`）：同一个组件的全屏 triage 模式，键位不变：A / X / J / K / Z / G / V。
- **Agent 运行**：每次运行一行，显示 agent、项目、条目、状态、耗时和费用（`claude -p --output-format json` 里有 `total_cost_usd` [S21]），可以展开看流式日志。
- **菜单栏和托盘**：录制、截图、显示鸡舍、切换项目、最近会话（带状态蛋）、打开 Blurt（⌥⇧B）。
- **浮层**：选区、倒计时、HUD、墨迹、鸡舍、气泡。macOS 继续用原生实现；Win/Linux 用透明 WebView 窗口重写同样的动效
  （弹簧参数照搬 `Perch.swift`）。GNOME Wayland 上没法置顶，鸡舍降级成窗口内的托盘加系统通知 [S16]。
- **「修好了」时刻**：条目划掉，小鸡把虫子啄掉，同时发系统通知。

### 2.2 引导

1. **权限**：屏幕录制、麦克风、辅助功能（画笔需要），实时显示授权状态。
2. **uv 和 Python**：检测，经用户同意后安装，再预热依赖。
3. **语音模型**：根据语言和硬件推荐一个，下载（国内走 hf-mirror）。
4. **Agent**：探测是否安装、是否登录，一键安装 skill 和 MCP，先预览要改动的文件，用户确认后才写。
5. **绑定项目**：创建 `.blurt/`，建议 gitignore。
6. **试一次**：截一张图，走完整个闭环。

### 2.3 设置

- **快捷键**：录入式修改。冲突检测分三层：本应用内部重复、和已知系统快捷键冲突、向系统注册失败。Wayland 下由系统设置管理。
- **语音**：模型列表、大小、实测 RTF、切换、删除；云端 key 存钥匙串。
- **Agent**：默认 agent，可按项目覆盖；草稿模型；无人值守时的权限档位；安装和卸载 skill、MCP。
- **导出目标**。
- **隐私**：纯本地模式、保留策略（`live/audio.pcm` 在校验后删除）。
- **存储**。

### 2.4 视觉语言

- **macOS 原生部分**：系统控件和系统颜色免费拿到原生观感，侧栏用 `NSVisualEffectView`。
- **Web 画布**：按 `data-platform` 切换三套 token（mac、win、gnome），设计目标是放进 macOS 窗口里不显得突兀。
- **暗色模式重做**：
  - 用亮度递增的表面表达层级，不用阴影：mac `#1E1E1E / #2A2A2A / #323232`，Win `#202020 / #2B2B2B`，GNOME `#242424 / #303030`；
  - 分隔线 `rgba(255,255,255,.08)`；文字三档 92% / 64% / 40%；
  - 品牌橙在暗色下用 `#FF7A5C`，只用于主按钮和选中态；
  - 截图加 1px 内描边。
- **强调色**：macOS 宿主把系统强调色注入成 CSS 变量，不依赖 WebView 是否支持 `AccentColor`。
- **动效**：尊重系统的「减弱动态效果」设置。

### 2.5 键盘优先

| 快捷键 | 作用 |
|---|---|
| `⌘K` | 命令面板 |
| `/` | 搜索 |
| `J` / `K` | 下一条 / 上一条 |
| `↩` | 打开 |
| `⌘↩` | 交给 agent |
| `E` | 编辑标题 |
| `1`–`4` | 改 kind |
| `S` | 改状态 |
| `R` | 审核模式 |
| `Space` | Quick Look |
| `?` | 显示键位表 |

---

## 3. 数据与存储

- **布局不变**：
  - `~/Blurt/recordings/<ts>/`；
  - `<repo>/.blurt/sessions/<ts>/`（`meta.json`、`recording.mp4`、`events.jsonl`、`transcript.json`、`items.json`、`shots.jsonl`、`shots/`、`frames/`、`clips/`、`live/`）；
  - `<repo>/.blurt/config.json`、`lenses/`；`~/.blurt/config.json`、`models/`。
- **新增** `~/.blurt/index.db`：schema 见 `docs/contracts/index-schema.sql`（契约 C3）。删掉不丢任何数据，`index.py scan` 能重建。
- **写入**：所有对 `items.json` 的修改都经过 `items.py`。应用内的审核编辑走 `items.py user-ops`，和 `review.py` 的
  `apply_user_ops` 是同一个函数。
- **触发重建索引**：
  - macOS 用 FSEvents 监听，Tauri 用 `notify` crate；变化后防抖 300 ms，再执行 `index.py update <session>`；
  - 启动时执行一次 `index.py scan`；
  - agent 通过 `items.py` 写入后，也会顺带更新索引（C2）。
- **迁移**：
  - 旧会话不需要改，没有 `uid` 的条目用确定性的 legacy uid（C1）；
  - 新版应用沿用 `dev.blurt.recorder` 这个 bundle id 和全部配置键，覆盖安装即可；
  - Sparkle 从这一版开始接入。
- **团队共享目录**：按 `meta.json.author` 区分是谁录的。
- **可选**：`index.py backlog <repo>` 生成 `.blurt/BACKLOG.md`，给没装应用的人和 agent 看。

---

## 4. Agent 集成

### 4.1 各家现状（2026-10）

| | Claude Code | Codex | Kimi Code CLI | ZCode（智谱） |
|---|---|---|---|---|
| 形态 | CLI、IDE、桌面版 | CLI、IDE、桌面版 | CLI `kimi`（旧 Kimi CLI 已归档）[S27] | 桌面应用 v3.16.2，三平台 [S28] |
| Skill | SKILL.md；插件可以打包 skills、MCP、hooks、`bin/` [S22] | SKILL.md；`.agents/skills`、`~/.agents/skills`；插件 [S24] | SKILL.md；读 `.claude/skills`、`.codex/skills`、`.agents/skills`、`~/.config/agents/skills` [S27] | 设置 → Skills 导入（第三方文档）[S28] |
| MCP | `.mcp.json`、插件 `mcpServers`、`--mcp-config` | `config.toml`、插件 [S24] | `kimi mcp`、`--mcp-config-file` [S27] | 设置 → MCP（stdio）[S28] |
| Headless | `claude -p --output-format stream-json --permission-mode …` [S21] | `codex exec --json --sandbox workspace-write`，以及 `exec resume`；`--full-auto` 已移除 [S25] | `kimi --print --output-format stream-json -w DIR`；退出码 75 表示可以重试 [S27] | 没有公开的 CLI 或 headless 模式 |
| 嵌入协议 | Agent SDK、ACP [S29] | app-server（JSON-RPC）；mcp-server 正在退场 [S26] | `kimi acp` | 未知 |
| Deep link | `claude-cli://open?q=…&cwd=…`：q 最多 5000 字符，只预填不执行 [S23]；桌面版用 `claude://code/new` [S30] | ⚠ 没找到 | ⚠ 没找到 | ⚠ 没找到 |
| 登录检测 | `claude auth status --json` | `codex login status` | 没有专门的命令；发一个极短的 `--print` 探测，看退出码是不是 1、输出里有没有登录相关字样 ⚠ | 只能检测是否安装 |

**WP2 在本机实测后的更正（2026-10-21，以此为准）**：
- **Kimi**：本机装的是新版 **Kimi Code 0.36.0**（`~/.kimi-code/bin/kimi`，单文件二进制），上表 Kimi 一列按旧版 kimi-cli 写的，
  大多不适用了：
  - 没有 `--print`、`-w`、`info`、`mcp` 子命令；headless 是 `kimi -p "<prompt>" [--output-format stream-json]`，
    在 cwd 里运行（没有工作目录参数，`--add-dir` 只是追加目录）；`-p` 不能和 `--yolo` / `--auto` 同时用。
  - MCP 没有命令行的添加方式，配置文件是 `~/.kimi-code/mcp.json`（`$KIMI_CODE_HOME`；项目级 `.kimi-code/mcp.json`），
    格式 `{"mcpServers": {"<name>": {"command", "args", "env", "cwd"}}}`（官方文档，未实跑）。
  - Skill 目录是 `~/.kimi-code/skills`、`~/.agents/skills` 和项目里的 `.kimi-code/skills`、`.agents/skills`；文档没提 `.claude/skills`。
  - 登录：没有状态命令；本机 `kimi -p` 退出码 1，stderr 为 `provider managed:kimi-code has no credential configured`；
    `~/.kimi-code/credentials/kimi-code.json` 里的 token 为空 → agents.json 的 `creds_json` 规则据此判为没登录（不花 token）。
    退出码 75 的说法在新版文档里找不到 ⚠。
- **Codex 0.157**：`codex mcp add <name> -- <cmd…>` 已在临时 `CODEX_HOME` 实测；`codex mcp get <name>` 存在时退出码 0；
  `codex exec … "<prompt>" --json` 带上 blurt MCP 真跑通过（search_items → get_item 看到图 → mark_fixed 写回）。
- **Claude Code 2.1.259**：`claude mcp add --scope user blurt -- uv run --script …` 只按 `--help` 核对了；本机 standalone CLI 没登录，
  `claude -p --mcp-config …` 的加分项没法跑。
- **OpenCode 1.1.56**（本机也装了）：headless `opencode run "<prompt>" [--format json]`；`opencode mcp add` 是交互式的，
  改成写 `~/.config/opencode/opencode.json` 的 `mcp.<name> = {"type": "local", "command": [...], "enabled": true}`（文档，未实跑）；
  登录看 `opencode auth list` 的凭据数。**Gemini CLI** 没装，条目全部来自文档。

结论：SKILL.md 是事实标准。skill 装两处（`~/.claude/skills/blurt`，再在 `~/.agents/skills/blurt` 放一个符号链接）
就能覆盖 Claude、Codex、Kimi 三家，ZCode 需要用户手动导入一次。MCP 是四家都支持的第二层。

### 4.2 三层

- **Skill**（主契约）：插件里加三样东西：
  - `mcpServers`：`uv run --script ${CLAUDE_PLUGIN_ROOT}/skills/blurt/scripts/mcp_server.py`；
  - `items.py fix` 的用法说明；
  - 一个 `SessionEnd` hook，会话结束时执行 `index.py update --workspace ${CLAUDE_PROJECT_DIR}`（`Stop` 每轮都触发，太频繁）。
- **MCP**：工具定义见 C4。
- **应用拉起 agent**：
  - **后台整理**和**后台修复**：从 `agents.py command <id> headless` 拿到 argv 后执行，解析 stream-json 显示进度；
    沿用 v0.6 的登录 shell 环境，不用 bare 模式，因为 bare 模式不读 OAuth 登录状态 [S21]。
  - **交互式修复**：Claude 用 `open "claude-cli://open?cwd=<repo>&q=<prompt>"`；Codex 和 Kimi 在用户的终端里打开
    `codex "<prompt>"` 或 `kimi`；ZCode 复制提示词并引导用户粘贴。
  - **选哪个 agent**：项目设置 → 全局默认 → 已登录的那个（Claude → Codex → Kimi）→ 「复制提示词」兜底。
  - 后台修复不会提交，也不会推送，只把 `fix.state` 改成 `fixing` / `fixed`，由用户验收。
- **以后再做**：ACP 对话面板、Codex app-server 内嵌、其他 CLI（Gemini、OpenCode、Qwen Code…）。后者在 `agents.json` 里加一条即可。

---

## 5. 契约（各工作包都按这里实现；要改契约，先改本节再通知其他包）

### C1 · items.json v2（只加字段，v1 文件照常能读）

```jsonc
{
  "schema": 2,                         // items.py writes it on first v2 write
  "items": [{
    "id": "I-001",
    "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABCD",   // ULID (26 chars, Crockford base32); never changes, survives edits
                                          // legacy items without uid: "L" + sha1("<session dir name>/<id>").hex[:25]
                                          // (index.py computes it read-only; `items.py ensure-uids` writes the same value)
    "fix": {                              // absent = never handed to an agent
      "state": "fixing",                  // fixing | fixed | wontfix | reopened
      "agent": "claude",                  // agents.json id, or "human"
      "run_id": "r-20261021-101500-ab12", // app's agent run id, or null
      "commit": null, "pr": null, "note": "", "at": 1792560000.0
    },
    "fix_history": [ /* previous "fix" objects, oldest first; items.py appends on every state change */ ]
  }]
}
```

`status` 仍然只有 `draft | confirmed | deleted`。「修复」状态单独放在 `fix.state`，不和审核状态混在一起。

细则（WP1 实现时补充）：
- **uid 落盘**：除 `user-ops` 外，`items.py` 的每次写入都会先给没有 uid 的条目写上 legacy uid（紧跟在 `id` 后面），
  并把 `"schema": 2` 放在文件第一个键；`add` 分配新的 ULID。legacy uid 以 `L` 开头，`L` 不在 Crockford 字母表里，
  所以和 ULID 不会撞。公式中的会话目录名 = `Path(session).resolve().name`。
- **`fix` 对象**总是带齐 7 个键：`state, agent, run_id, commit, pr, note, at`（`at` 为 epoch 秒，保留 1 位小数）。
- **`fix_history`**：只有 state 变化时，才把当前的 `fix` 追加进去；state 不变的再次调用只更新当前 `fix`（比如补上
  commit 或 pr），已有的字段保留。
- **agent / run_id 的取值顺序**：命令行参数 → 环境变量 `$BLURT_AGENT` / `$BLURT_RUN_ID`（应用拉起 agent 时注入）
  → 上一个 `fix` 是 `fixing` 时沿用它的值（同一次运行收尾）→ `"human"` / `null`。commit、pr、note 在 state 变化时不沿用。
- 共享实现在 `scripts/_common.py`：`new_ulid()`、`legacy_uid(session_name, item_id)`、`item_uid(session, item)`、
  `FIX_STATES`、`file_etag(raw)`、`apply_user_ops(data, ops)`。

### C2 · items.py CLI v2

每次调用输出一行 JSON；退出码 0 表示成功，1 表示参数或数据错误，3 表示等锁超时。
`ID` 既可以是 `I-001` 这样的条目号，也可以是 uid。

```
items.py patch      SESSION ID --set k=V … [--unset k …] [--force]        (existing)
items.py set-frames SESSION ID PATH[@T][#CAPTION] … [--append]            (existing)
items.py add        SESSION --json '{…}' [--after ID]                     (existing; now also assigns uid)
items.py done       SESSION                                               (existing)
items.py get        SESSION ID                → {"item": {...}, "session": "<abs dir>"}
items.py list       SESSION [--kind K] [--status S] [--fix-state F]  → {"items": [...]}
items.py fix        SESSION ID --state fixing|fixed|wontfix|reopened [--agent A] [--run-id R]
                                   [--commit SHA] [--pr URL] [--note TEXT]
                                              → {"ok": true, "uid": "...", "fix": {...}}
items.py user-ops   SESSION (--json '[op,…]' | --stdin) [--confirm]
                                              → {"ok": true, "etag": "\"<16 hex>\""}
     op = {"op":"set","id":"I-001","set":{…},"unset":[…]} | {"op":"remove","id":"I-004","into":"I-003"}
        | {"op":"add","item":{…},"after":"I-002"|null}
     Same semantics as review.py POST /api/items (apply_user_ops moves to _common.py; review.py imports it).
     --confirm = POST /api/confirm (sets "reviewed": true).
items.py ensure-uids SESSION                  → {"assigned": n}
After every successful write: best-effort `index.py update SESSION` in-process (import, not subprocess);
failures are ignored (the app's watcher catches up).
```

细则（WP1 实现时补充，以下以代码为准）：
- **输出**：成功时每个结果都多带一个 `"ok": true`（`get`、`list` 还会带 `"session": "<abs dir>"`，`add` 还会带 `"uid"`）。
  失败时 stdout 仍然是一行 `{"ok": false, "error": "…"}`，同时把错误信息写到 stderr；参数错误也返回 1（不是 argparse 默认的 2）。
  等锁超时返回 3，等待时长由 `$BLURT_LOCK_TIMEOUT` 控制，默认 15 秒。
- **ID**：可以是条目号、文件里的 uid，或者算出来的 legacy uid。被用户合并掉的条目也能用 legacy uid 定位，这时
  `patch` / `set-frames` / `fix` 返回 `"skipped"`，`get` 以 1 退出。`add --after` 也接受 uid。
- **`get` / `list`**：只读，不加锁；返回的每个条目都带 `uid`，文件里没有就现算 legacy uid，不写盘。
- **`list` 筛选**：`--kind`、`--status`、`--fix-state` 都可以重复给。不带 `--status` 时不返回 `deleted` 的条目。
  `--fix-state none` 表示从没交给 agent 的条目。
- **`fix`**：`patch` 不能改 `uid`、`fix`、`fix_history`、`schema`，改 fix 只能走 `items.py fix`；fix 的规则见 C1 细则。
- **`user-ops`**：
  - `--json` 也接受审核页 POST 的请求体 `{"ops": […]}`；只带 `--confirm`、不给 ops 也合法。
  - 不写 `agent_at`、`schema`、uid，所以写出的文件和 `review.py` 逐字节一致。
  - 返回的 `etag` 和 `GET /api/items` 的 ETag 同一算法（`file_etag`）。
  - 格式不对的 op 整批拒绝（返回 1），文件保持不动。
- **`ensure-uids`**：不写 `agent_at`；没有需要补的 uid、`schema` 也已经是 2 时，不重写文件。
- **重建索引**：写入成功后调用 `index.update_sessions([Path(session).resolve()])`（C3），stdout 被吞掉，Exception 和 SystemExit 都忽略。
  `$BLURT_HOME/index.db` 还不存在（没有人读索引）或设置了 `BLURT_NO_INDEX` 时跳过。
- `agent_at` 只由 `patch`、`set-frames`、`add`、`done`、`fix` 写入。

### C3 · index.db 和 index.py

- schema：`docs/contracts/index-schema.sql`（本次已提交，在 SQLite 3.50 上验证过：建表正常，中文 trigram 搜索能命中）。
- 写入方只有 `index.py`；读取方用只读方式打开（`?mode=ro`），WAL 模式。

```
index.py path                                  → {"db": "/Users/x/.blurt/index.db"}
index.py scan [--root DIR …]                   full rescan of recording_roots() (+ --root) → {"workspaces":n,"sessions":n,"items":n,"ms":n}
index.py update SESSION_DIR …                  re-index those sessions (deleted dir → rows removed) → {"updated":n,"ms":n}
index.py search [QUERY] [--kind K]… [--status S]… [--fix-state F]… [--workspace ID] [--session ID]
                [--sort updated|created|t_start] [--limit 50] [--offset 0]
                                               → {"total": n, "items": [ItemRow]}
     ItemRow = {uid, session_id, session_dir, item_id, kind, title, status, fix_state, severity,
                primary_frame, updated, snippet}
     QUERY ≥ 3 chars: FTS5 MATCH (trigram); 1–2 chars: LIKE fallback; empty: filters only.
index.py backlog REPO                          writes REPO/.blurt/BACKLOG.md → {"path": "...", "items": n}
In-process API (items.py uses it after each write; importing index has no side effects):
  index.update_sessions([session_dir, …]) -> {"updated": n, "ms": n}   raises on failure; honours $BLURT_HOME at call time
```

各宿主都要按同一种方式查询，SQL 模板写在 `index.py` 的 docstring 里，这里是关键部分：

```sql
SELECT i.* FROM items i JOIN items_fts f ON f.rowid = i.rowid
WHERE items_fts MATCH ?1 AND i.status != 'deleted' [AND i.kind IN (…)] ORDER BY i.updated DESC LIMIT ?2 OFFSET ?3
```

细则（WP2 实现时补充，以 `index.py` 为准）：
- **查询词**：QUERY 按空白切成多个词，全部要命中（AND）。≥ 3 个字符的词交给 FTS5，作为带引号的短语
  （`"` 写成 `""`，所以用户输入里的 FTS 语法只当普通文字）；1–2 个字符的词用
  `(i.title LIKE ? ESCAPE '\' OR i.quote LIKE ? ESCAPE '\' OR i.body LIKE ? ESCAPE '\')`，`%` `_` `\` 要转义。
  snippet：走 FTS 时用 `snippet(items_fts, -1, '[', ']', '…', 12)`；只有短词时由宿主自己截（`index.py` 截命中处前后约 20 字）。
- **筛选**：`--kind` / `--status` / `--fix-state` 都可以重复给；不带 `--status` 时排除 `deleted`；`--fix-state none` = `fix_state IS NULL`。
  `--workspace` / `--session` 接受 id 或目录（`--workspace` 还接受名字）。
  排序：`updated` = `i.updated DESC`；`created` = `s.created DESC, i.t_start`；`t_start` = `i.t_start, s.created DESC`；最后都按 `item_id`。
- **工作区判定**：`~/Blurt/recordings/<ts>` 属于默认工作区 `~/Blurt`（kind `default`，名字 `Blurt`）；`<repo>/.blurt/sessions/<ts>`
  属于 `<repo>`；其它目录里的会话归到它的父目录。会话目录 = 含 `meta.json`、`items.json`、`recording.mp4`、`shots.jsonl` 之一。
- **scan 的范围**：`~/Blurt/recordings`、`$BLURT_HOME/config.json` 的 `record.workspaces`、**索引里已有的工作区**、`--root`。
  默认跳过没变的会话（`items_mtime`、`shots_mtime` 相同，且 `meta.json` 不比 `indexed_at` 新），`--full` 全部重建。
  没有会话的工作区从表里删掉。实测本机 11 个会话、149 条：全量 37 ms，增量 2 ms。
- **`index.py update --workspace DIR`**：只重建 DIR 下变过的会话（插件 hook 用）；DIR 没有 `.blurt/sessions` 时什么都不做，也不建库。
- **同一个 uid 出现在两个会话里**（会话目录被复制）：先入库的保留，后面的跳过，`update` 的输出里带 `duplicate_uids`。
- **`body`**：条目里除 `id uid kind title quote tags status severity owner module confidence time frames clip exported fix
  fix_history merged_from` 和 `_` 开头之外的字段，把其中的字符串（含嵌套的列表 / 对象）按行拼起来。
- **`updated`** = max(`_user` 里的时间, `fix.at`, `items_mtime`)；**`t_start`** = `time.start`，没有就取首帧的 `t`。
- Python API 还有：`scan(roots, full)`、`search(...)`、`ensure_index()`（读者用：没有库就先 scan）、`connect(readonly=True)`、
  `legacy_uid(name, id)`、`read_shots(dir)`。实测 `items.py` 写入后的索引更新约 2 ms。

### C4 · MCP 服务 `blurt`（`mcp_server.py`，stdio，用官方 `mcp` Python SDK 的 FastMCP）

启动命令：`uv run --script <skill>/scripts/mcp_server.py`。不依赖应用；没有索引时先做一次 scan。

| tool | 参数 | 返回 |
|---|---|---|
| `list_projects` | – | `[{id, name, path, kind, sessions, open_items}]` |
| `list_sessions` | `project?: str, state?: "unprocessed"\|"processing"\|"unreviewed"\|"reviewed", limit=20` | `[{id, dir, mode, title, created, item_count, processed, reviewed}]` |
| `search_items` | `query?: str, project?, kind?: [str], status?: [str], fix_state?: [str], limit=20` | `[ItemRow]` |
| `get_item` | `uid: str, include_frames=true, max_frames=3` | 一段 JSON 文本（完整条目，路径为绝对路径），加最多 3 张 JPEG（长边 ≤1280 px） |
| `get_transcript` | `session: str, start?: float, end?: float` | `[{start, end, text, speaker?}]` |
| `update_item` | `uid: str, set: object, unset?: [str]` | 和 `items.py patch` 一样（保留 `_user` 改过的字段）：`{ok, written, kept_user}` |
| `mark_fixed` | `uid: str, state="fixed", commit?, pr?, note?, agent?` | 和 `items.py fix` 一样 |

工具描述里要写明：只能用这些工具或 `items.py` 改条目，不能直接写文件。

细则（WP2 实现时补充，以 `mcp_server.py` 为准）：
- **SDK 版本**：`mcp>=1.20,<2`（脚本头里声明，另加 `pillow`）。`mcp` 2.x 把 FastMCP 改名成 `MCPServer`，API 也变了，所以先钉在 1.x
  （实测 1.30.0）。注册时用 `uv run -q --script …`，`-q` 防止 uv 的提示混进 stdio。
- **写入**：`update_item` / `mark_fixed` 以子进程调用 `items.py patch|fix SESSION UID …`（同一个 Python），返回它输出的那行 JSON；
  items.py 失败时把它的 `error` 作为工具错误（`isError`）返回。之后再调一次 `index.update_sessions`，保证读者马上看到。
  `mark_fixed` 的 agent 不传时由 items.py 取 `$BLURT_AGENT`（应用拉起 agent 时注入，见 C5 `command` 的 `env`）。
- **`get_item`**：第一个 content 是 JSON 文本 `{item, session, session_id, session_title, language, source_video, author, how_to_change}`，
  `item` 带 `uid`，`frames[].path`、`clip` 都是绝对路径；后面是最多 `max_frames` 张 `image/jpeg`（长边 ≤ 1280 px，质量 82）。
  uid 先查索引，查不到就 scan 一次再查。
- **`get_transcript`**：`session` 接受会话 id 或目录；截图会话没有 transcript.json，返回每张图的备注
  `[{start: t|null, end: null, text, shot, file}]`。
- **`list_projects`**：`open_items` = 没删除且 `fix_state` 为空、`fixing` 或 `reopened` 的条目数。`project` 参数（`list_sessions` /
  `search_items`）接受工作区 id、名字或路径。
- 返回列表的工具同时给 structuredContent（`{"result": [...]}`）和每行一段 JSON 文本。

### C5 · agents.json 和 agents.py

**位置和来源**（WP2 修订）：注册表是 **`skills/blurt/scripts/agents.json`**（不是 `skills/blurt/agents.json`），
由 app-ux 先建（`status` / `order` / `classify`、Agents.swift、live.py 已经在用），WP2 在它上面只加字段和命令；
`record.py build` 把它拷进 `Blurt.app/Contents/Resources`。`agents.json` 是唯一的事实来源：顺序、探测、命令行、安装方式都只写在这里，
Swift、Rust、live.py 不各自拼命令。

```jsonc
{ "_doc": "…", "agents": [                // 数组顺序 = 默认的回退顺序：claude, codex, kimi, opencode, gemini, zcode
  { "id": "codex", "name": "Codex", "bins": ["codex"],
    "verified": "run",                     // run = 真跑过 | cli = 只核对了 --help | docs = 只看了文档
    // app-ux 的字段（Agents.swift 和 live.py 依赖，含义不变）
    "status": { "args": ["login", "status"], "logged_out": ["not logged in"], "ok_if": ["logged in"],
                "env_any": ["OPENAI_API_KEY"] },   // 另有 json_key、creds_json{path,keys}、configured_if、files_any、otherwise
    "run": ["exec", "--skip-git-repo-check", "--sandbox", "danger-full-access", "{prompt}"],   // headless，bin 后面的参数
    "fix": {"zh": "…", "en": "…"}, "install": {"zh": "…", "en": "…"}, "drafts": true,          // drafts = live.py 能用
    // WP2 加的字段
    "version": ["--version"],
    "events": { "args": ["--json"], "format": "codex-jsonl" },   // 追加在 run 后面，得到可解析的进度流
    "interactive": { "terminal": ["{prompt}"] },   // 或 {"url": "claude-cli://open?cwd={repo_q}&q={prompt_q}", "max_prompt": 5000}
                                                   // 或 {"terminal": [], "paste_prompt": true}（kimi）或 {"copy_prompt": true}（zcode）
    "skill_dir": "~/.agents/skills",
    "mcp": { "args": ["mcp", "add", "blurt", "--", "uv", "run", "--script", "{mcp_server}"],
             "check": ["mcp", "get", "blurt"], "verified": "run" } },
         // 或 {"json": {"path": "${KIMI_CODE_HOME:-~/.kimi-code}/mcp.json", "key": ["mcpServers", "blurt"], "value": {…}}}
  { "id": "zcode", "name": "ZCode", "bins": [], "app": { "macos": "/Applications/ZCode.app" },
    "headless": false, "interactive": { "copy_prompt": true }, … }
], "failures": [ … ] }                     // app-ux：skill | model | auth | quota | network，classify() 用
```

路径支持 `~` 和 `${VAR:-default}`；占位符：`{prompt}`、`{repo}`、`{repo_q}` / `{prompt_q}`（URL 编码）、`{mcp_server}`（mcp_server.py
的绝对路径）、`--var k=v` 给的任意 `{k}`。

**顺序**（app-ux 已实现，WP2 沿用）：`record.agents` 是**排他**列表——只用列出的 id，按列出的顺序，未知 id 忽略，全部无效时退回默认；
没设时用注册表顺序，旧的 `record.process`（`"claude"` / `"codex"`）提到最前；`record.agent_defs` 增加或覆盖条目。`"headless": false` 的条目（zcode）永远不进 order（默认顺序和 `record.agents` 都一样，Python `agent_order()` 和 Swift `AgentHub.order()` 同一规则）。
读 `$BLURT_HOME/config.json`；Python 侧带 `--repo` 时，`<repo>/.blurt/config.json` 里的 `record.agents` / `record.process` 优先，
`agent_defs` 合并（应用没有项目上下文时不用管）。

**探测**：`status` / `detect` 在去掉调用方 agent 会话变量（`CLAUDE*`、`ANTHROPIC_*`、`CODEX_*`、`MCP_*`、`OTEL_*` 等，
和 `isAgentSessionVar` 一致）的环境里跑，但保留 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`、`KIMI_CODE_HOME`（用户的配置位置）。
`install` 用调用方的环境，不做任何删减——配置写到哪儿由这些变量决定。

```
agents.py status [--json]          app-ux：[{id, name, path, state, why, fix}]，state = ready|configured|logged_out|unknown|not_installed
agents.py order [--json] [--repo DIR]   一行一个 id；--json → {"order": [...]}
agents.py classify FILE            app-ux：{"class": "auth|quota|network|model|skill"|null, "reason": "…"}
agents.py detect [--repo DIR] [--ids a,b] [--no-login] [--no-version] [--lang zh|en]
  → {"order": [ids], "pick": id|null,
     "agents": [{id, name, path, state, why, fix,                     // 与 status 的行完全相同
                 installed: bool, version: str|null,
                 login: "ok"|"logged_out"|"unknown"|"n/a",          // ready→ok，configured/unknown→unknown，not_installed→n/a
                 headless: bool, interactive: "url"|"terminal"|"copy"|null}]}
     agents 按 order 排，后面再跟上 order 之外的 app-only 条目（不带 --ids 时，供「复制提示词」用）；pick = order 里第一个 headless 且 ready 的，没有就第一个 configured，再没有就第一个 unknown，否则 null。
agents.py command ID headless|interactive (--prompt TEXT | --prompt-file F) --repo DIR [--var k=v …] [--no-events]
  → {"id", "mode", "argv": [abs bin, …]|null, "cwd": "<abs repo>", "env": {"BLURT_AGENT": id, "BLURT_RUN_ID"?: run_id},
     "url": null|"…", "events": "claude-stream-json"|"codex-jsonl"|"kimi-stream-json"|"opencode-json"|null,
     "terminal": bool, "clipboard": null|"…", "open_app": null|"…", "retry_exit": null|n, "prompt_file": null|"…"}
     headless：argv = bin + run + headless_mcp.args（--no-mcp 不加）+ events.args（--no-events 不加）；prompt 永远是单独一个
     argv 元素，不经过 shell。
     **headless_mcp**（codex，实测）：`codex exec` 的审批策略是 never，没批准过的 MCP 调用一律失败（"MCP tool call requires
     approval, but approval policy is never"）。所以 headless 命令带上整个 blurt 服务：`-c mcp_servers.blurt.command="uv"`、
     `…args=["run","-q","--script","<mcp_server.py>"]`、`…env_vars=["BLURT_HOME","BLURT_WORKSPACE","BLURT_AGENT",
     "BLURT_RUN_ID"]`（codex 给 MCP 服务的环境很干净，不转发的话 run_id 和改过位置的 BLURT_HOME 到不了服务）、
     `…default_tools_approval_mode="approve"`（可选值 auto|prompt|writes|approve）。必须给全：只对没注册的服务给一个
     `-c mcp_servers.blurt.<key>`，codex 会直接报 "invalid transport" 起不来。这样不管用户装没装 MCP，后台修复都能用。
     claude 的 `run` 在 `--allowedTools` 里加了 `mcp__blurt`（-p 模式下没放行的工具会被拒；未实跑 ⚠）。
     **应用要用 `command` 的 argv**：Agents.swift 现在直接拿 `run` 拼命令，拿不到 headless_mcp，要么改成调 `agents.py command`，
     要么照同样规则把 headless_mcp.args（替换 `{mcp_server_json}`）追加上。
     interactive：url（提示词超过 max_prompt 时写进 $BLURT_HOME/prompts/*.md，q 改成「Read <file> and do what it says.」）；
     或 terminal: true + argv（在用户的终端里跑）；paste_prompt / copy_prompt → clipboard；zcode 还给 open_app。
     --var run_id=R → env BLURT_RUN_ID（items.py fix 和 mark_fixed 的默认值）。出错：{"ok": false, "error"}，退出码 1。
agents.py install ID [--skill] [--mcp] [--dry-run]     （两个都不给 = 都做）
  → {"changes": [{"action": "symlink", "path", "target"} | {"action": "exists", "path"|"argv"} |
                 {"action": "conflict", "path", "points_to"} | {"action": "run", "argv", ok?, exit?, output?} |
                 {"action": "json_merge", "path", "key", "value", ok?} | {"action": "error"|"manual", …}],
     "applied": bool}
     skill：<skill_dir>/blurt → skill 根目录的符号链接；已有别的 skill 就报 conflict，绝不覆盖。
     mcp：args 形式先跑 check（退出码 0 = 已注册 → exists），否则跑 args；json 形式合并进配置文件（保留其它键，原子写）。
     --dry-run 什么都不改（args 形式的 check 照样会跑，它只读）。
agents.py prompt fix --items UID … [--repo DIR]
  → {"prompt": "…", "repo": "<abs>", "items": [uid…]}   修复提示词只在这里写：逐条 get_item → mark_fixed fixing → 修 →
     mark_fixed fixed|wontfix（带 note），不提交不推送，不许直接改 items.json；同时给出 items.py 的等价命令。
     --repo 不给时取第一个条目所在的仓库工作区，再不行用 cwd。uid 不在索引里 → 退出码 1。
```

Python API（live.py、测试用）：`agent_order(cfg)`、`definitions(cfg)`、`check(defn, env, lang)`、`config(repo)`、`detect(...)`、
`command(...)`、`install(...)`、`fix_prompt(uids, repo)`、`clean_env(env)`。

**本机实测（2026-10-21）**：`detect` → claude `logged_out`、codex `ok`（与 Swift preflight 一致），kimi `logged_out`
（creds_json），opencode `unknown`（configured），gemini / zcode 未安装，pick = codex。
各条目的 `verified`：claude run=`run`（app-ux）、mcp=`cli`；codex run=`run`、mcp=`run`；kimi `cli`、mcp=`docs`；
opencode `cli`、mcp=`docs`；gemini、zcode 全部 `docs`。

原生应用只执行 `command` 返回的 argv 或 url，并且注入登录 shell 的环境（沿用 `agentEnvironment()`）。

### C6 · 审核组件的宿主协议

```ts
// web/packages/review/src/host.ts
export type Host = 'browser' | 'macos' | 'tauri';
export interface SessionDoc { /* items.json as-is (C1) */ }
export interface BlurtHost {
  host: Host;
  load(): Promise<{ doc: SessionDoc; etag: string }>;
  poll(etag: string): Promise<{ doc?: SessionDoc; etag: string }>;   // no doc = unchanged
  sendOps(ops: UserOp[], confirm?: boolean): Promise<{ ok: boolean; etag: string }>;
  fileUrl(rel: string): string;                                        // session-relative → loadable URL
  // optional native affordances; the component hides the UI when absent
  reveal?(rel: string): void; quickLook?(rel: string): void; openCode?(ref: string): void;
  fixWithAgent?(itemIds: string[]): void; registerDragRects?(rects: DragRect[]): void;
}
// mount: mountReview(el, host, { mode: 'review' | 'item', itemId?, platform: 'mac'|'win'|'gnome', theme: 'auto'|'light'|'dark' })
```

- **browser**：沿用 `review.py` 的 HTTP 接口（`GET /api/items` 带 ETag，`POST /api/items {ops}`、`POST /api/confirm`、
  `/files/<rel>`），`review.py` 一行不改。
- **macos**：
  - 页面从 `blurt-app://ui/index.html?session=<abs>&mode=…` 加载，由 `WKURLSchemeHandler` 提供
    `blurt-app://ui/*`（打包进 app 的 `web/dist`）和 `blurt-app://session/<rel>`（会话里的文件）；
  - JS 调原生：`webkit.messageHandlers.blurt.postMessage({id, method, params})`，原生回调 `window.__blurtReply(id, result, error)`；
  - 方法名和 `BlurtHost` 的方法一一对应；`sendOps` 内部执行 `items.py user-ops --stdin`。
- **tauri**：用 `invoke('review_load' | 'review_poll' | 'review_ops' | 'reveal' | 'fix_with_agent', …)`，命令名见 C8。

组件里的所有回车处理都必须先判断 `e.isComposing || e.keyCode === 229`，并在 `compositionend` 之后 50 ms 内忽略回车 [S39]。

细则（WP3 实现时补充，以 `web/packages/review/src/host.ts` 为准）：
- **接口补充**（都是可选项，不影响已有宿主）：
  - `sendOps` 返回值可以带 `doc`（写入后合并好的文件，`review.py` 本来就返回）。不带时，组件会用写入**前**的 etag 调一次
    `poll` 取回合并结果再 rebase，所以原生宿主只回 `{ok, etag}` 即可（`items.py user-ops` 的输出）。
  - `download?(rel)`：把会话文件存到「下载」；`confirmed?()`：审核已确认，宿主可以关窗；
    `inApp?: boolean`：在应用窗口里（主题跟随系统、不显示主题按钮和会话名）。
  - 只给 browser 用：`saveDoc?(doc, confirm)`（没有 id 的手写 items.json 整份保存，和旧页面一样）、`downloadUrl?(rel)`（`?download=1`）。
  - `load` / `poll` 返回的 doc 要像 `review.py` 一样带 `_video`（`source_video` 文件是否存在；截图会话为 false）。etag 用 `file_etag`。
- **挂载**：`mountReview(el, host, opts)` 返回 `{setItem(id), setTheme(t), setPlatform(p), unmount()}`；单文件页面里挂在
  `window.blurtReview` 上。宿主也可以随时调 `window.__blurtSetAccent('#rrggbb' | null)`、`window.__blurtSetTheme('auto'|'light'|'dark')`。
  - URL 参数：`mode=review|item`、`item=<id|uid>`、`platform=mac|win|gnome`、`theme=auto|light|dark`、`lang=en|zh`、
    `host=browser|macos|tauri`（一般自动识别：`blurt-app:` → macos，有 Tauri IPC → tauri，其余 → browser）、`session=<abs>`（tauri）。
  - item 模式：`itemId` 可以是条目号或 uid；没有队列和保留/丢弃栏，键位只剩 ← → / Space / O / E / 1 2 3 / ⌘↩（= `fixWithAgent`）。
- **产物**：三个宿主用同一个单文件 `skills/blurt/scripts/review.html`（≈280 KB）。macOS 应用把它打包成 `blurt-app://ui/index.html`，
  旁边放 `ui/icon.png`（页面用相对路径 `icon.png`）。
- **macos 细节**（参考实现和验收：`web/packages/review/e2e/wkwebview/Harness.swift`，`pnpm -C web/packages/review test:wkwebview`
  在真实 WKWebView 里跑 17 项检查）：
  - document-start 注入 `window.blurtHostInfo = {host: "macos", methods: ["reveal","quickLook","openCode","fixWithAgent","registerDragRects","download"], accent: "#rrggbb"}`；
    `methods` 只列原生真正实现了的可选方法（组件据此显示按钮），`accent` 是 `NSColor.controlAccentColor`，只用于焦点环和选区，不替代品牌橙。
  - 请求：`load {}` → `{doc, etag}`；`poll {etag}` → `{etag}` 或 `{doc, etag}`；`sendOps {ops, confirm}` → `{ok, etag}`
    （`items.py user-ops SESSION --stdin [--confirm]`，stdin 是 `{"ops": [...]}`）。回复：`window.__blurtReply(id, result, null)`，失败时 `(id, null, "message")`。
  - `id: 0` 是通知，不回复：`reveal {rel}`、`quickLook {rel}`、`openCode {ref}`、`fixWithAgent {itemIds}`（uid 优先）、
    `registerDragRects {rects: [{rel, x, y, w, h}]}`（视口内的 CSS px，帧和缩略图；卸载时发空数组）、`download {rel}`、`confirmed {}`。
  - macOS 26 的 WebKit 对普通 `WKScriptMessageHandler` 的 `postMessage` 也返回一个 resolve 成 undefined 的 Promise；组件两种都认：
    Promise 给了值就用（`WKScriptMessageHandlerWithReply`），否则等 `__blurtReply`。
  - `blurt-app://session/<rel>` 必须支持 `Range`（206 + `Content-Range` + `Accept-Ranges`），否则 `<video>` 播不了片段和原录屏
    （已实测）；要拒绝 `..` 跳出会话目录。
- **当前的审核窗口**（`ReviewWindow.swift`，WKWebView 打开 `review.py` 的 http 页）**不需要改**：页面走 browser 宿主，识别
  `window.blurtApp`，确认后照旧发 `{type: "confirmed"}`，标题照旧走 `document.title`（已在本机构建的 Blurt.app 里用真实按键验证）。
  可选：在它的 document-start 脚本里加 `window.blurtHostInfo = {accent: "#rrggbb"}`（不带 `host`），就能用上系统强调色。
- **tauri**：`fileUrl` 用 `convertFileSrc(<session>/<rel>, 'asset')`，所以 shell 要把会话目录加进 asset 协议的 scope；
  `reveal` 传 `{path: <绝对路径>}`；`fix_with_agent` 传 `{session, itemIds}`。

### C7 · Swift 模块边界（`skills/blurt/recorder/macos/Package.swift`，只用 Command Line Tools 就能 `swift build`）

```
Sources/BlurtCore/      (library; everything the app uses from it is public — app files `import BlurtCore`)
   Paths.swift      public enum BlurtPaths { static var home, config, indexDB, workspace, skillDir, scripts: URL }
   Config.swift     public final class Config { static let shared; subscript(key: String) -> Any? { get set }   // dotted keys: "record.hotkeys"
                      func set(_ key: String, _ value: Any?); var all, record: [String: Any] }                // ~/.blurt/config.json, read fresh each time
                    public enum BlurtLocale { static var lang }                                               // the app sets it from --lang
   Script.swift     public enum ShellEnv { static func agentEnvironment() -> [String: String]; findExecutable(_:); runCapture(…)
                      isAgentSessionVar(_:)  // strips agent-session vars, keeps CODEX_HOME / CLAUDE_CONFIG_DIR / KIMI_CODE_HOME / *_HOME / *_CONFIG_DIR
                      static let inherited, loginShell; static let path }
                    public final class ScriptRunner { static let shared
                      func run(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> Data
                      func json(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> [String: Any]
                      func spawn(_ script: String, _ args: [String], onLine: @escaping (String) -> Void) throws -> Process   // lines on main
                      var uvAvailable: Bool; var uvPath: String? }                // PATH (login shell), then ~/.blurt/bin/uv
                    public enum ScriptError { uvMissing, scriptMissing(String), failed(status:stdout:stderr:), timeout(TimeInterval) }
                    // script = a name in <skill>/scripts ("items.py") or an absolute path; runs `uv run -q <script> …`
   Hotkeys.swift    public final class HotkeyCenter { static let shared
                      enum Action: String, CaseIterable {       // raw values = config keys of record.hotkeys (shared with _common.py)
                        case toggleRecord = "record", openMenu = "menu", snap, pause, marker, pen, finish = "stop", openMain = "main" }
                      func binding(_ a: Action) -> KeyCombo?; func state(_ a: Action) -> HotkeyResult
                      func set(_ c: KeyCombo?, for a: Action) -> HotkeyResult  // saves, re-registers at once, returns the new state
                      func restoreDefaults(); var conflicts: [Action]; var disabled: Set<Action>; var resident: Bool
                      var onFire: ((Action) -> Void)?; var onChange: (() -> Void)?
                      func registerRaw(_ id: UInt32, code: Int, mods: Int) -> OSStatus; var onRaw  // the app's fixed keys (ids < 100) }
                    public enum HotkeyResult { ok, off, notHere, duplicate(Action), failed(Int32), taken(pid_t), system }
                    public struct KeyCombo { mods, key, code; static func parse(String) -> KeyCombo?; spec ("opt+shift+R"); label ("⌥⇧R") }
                    // config: record.hotkeys {"record": "opt+shift+R", "snap": "off", …}; .taken = another running Blurt published
                    // those keys in ~/Library/Caches/dev.blurt.recorder/hotkeys/<pid>.json
   Index/           public final class IndexReader { init(url: URL = BlurtPaths.indexDB) throws
                      func workspaces() throws -> [WorkspaceRow]; func sessions(_ q: SessionQuery) throws -> [SessionRow]
                      func items(_ q: ItemQuery) throws -> [ItemRow]; func count(_ q: ItemQuery) throws -> Int }
                    public final class IndexWatcher { init(roots: [URL]); var onChange: (([URL]) -> Void)? }   // FSEvents（WP5）
   Agents/ (WP6)    C5 rows: AgentStatus (= one `agents.py detect` row), AgentDetect, AgentCommand, InstallPlan / InstallChange, FixPrompt
                    public final class SkillCLI { static let shared            // plain calls go through ScriptRunner; --with / extra env /
                      func run(_ script:, _ args:, stdin:, with packages: [String], env:, timeout:) async throws -> CLIResult   // separate
                      func spawn(_ script:, _ args:, with:, env:, onLine: (String, Bool) -> Void, onExit: (Int32) -> Void) }    // stderr
                    public final class Agents { static let shared
                      func detect(login: Bool = true, repo: URL? = nil) async throws -> AgentDetect
                      func detectAll(login:) async throws -> AgentDetect        // every registry id, configured order first
                      var order: [String]?                                      // record.agents
                      func command(_ id:, mode: "headless"|"interactive", prompt:, repo:, vars:, events:) async throws -> AgentCommand
                      func install(_ id:, skill:, mcp:, dryRun: Bool) async throws -> InstallPlan   // full login env, never scrubbed
                      func fixPrompt(_ uids: [String], repo: URL? = nil) async throws -> FixPrompt
                      func run(_ id:, prompt:, repo:, items:, runID:) async throws -> AgentRun       // headless; parses the event stream
                      func interactive(_ id:, prompt:, repo:) async throws -> AgentCommand }        // the app opens url / Terminal / clipboard
                    public final class AgentRun { id, agent, items, repo, lines, costUSD, exitStatus; onLine, onProgress, onExit; cancel() }
Sources/BlurtApp/       (executable "blurt-recorder"; bundle id dev.blurt.recorder, unchanged; one module)
   Capture/    Recorder, Picker, HUD, HUDLive, InkView, Snap, Perch, Rope, NoteBubble, Eggs, LiveAudio   (the existing capture code)
   App/ (WP4)  AppDelegate (the App class + status menu), AppEnvironment, AgentHub, Hotkeys (glue), HotkeySettings,
               ReviewWindow, SnapApp, Shell, Workspaces, Support, CarbonHotkeys, SelfTest, Updater
   MainWindow/, WebHost/ (WP5)     Settings/, Onboarding/, System/ (WP6)
   main.swift  launch code; `blurt-recorder --selftest [SESSION]` = GUI-less BlurtCore checks (JSON, exit 0 = pass)
```

- **BlurtCapture 不是单独的模块**，是 `BlurtApp` 里的 `Capture/` 目录（WP4 实施时改）。现有采集代码和应用代码共用一批全局量
  （`opts`、`L()`、`perch`、`snapper`、`App` 类的扩展），拆成库要给几千行代码补 `public`、再解开循环依赖，单进程应用得不到好处。
  需要的话以后再拆，届时只是把 `Capture/` 移成一个 target。
- 应用内沿用旧名字：`HotAction = HotkeyCenter.Action`、`Shortcut = KeyCombo`、`HotState = HotkeyResult`、`Hotkeys = HotkeyCenter`。
- 配置键沿用现有的 `record.hotkeys`（不是 `record.shortcuts`）；`openMain` 默认不绑定，主窗口注册之前不注册、也不在快捷键窗口里出现。
- `AppEnvironment`：`mainWindow: MainWindowHosting?`、`settings: SettingsHosting?`、`fixWithAgent: (([String]) -> Void)?`、
  `openURL: ((URL) -> Bool)?`。WP5 在 `MainWindow/MainWindowModule.swift` 的 `install()` 里设置，WP6 在 `Settings/SettingsModule.swift`
  的 `install()` 里设置（也在这里设 `NSApp.servicesProvider`）；菜单栏应用启动时调用这两个 `install()`。
  对应的菜单项（打开口喷鸡、设置…）只在钩子存在时出现；「快捷键…」在 `settings` 存在时打开 `show(pane: "shortcuts")`。
  `blurt://`、`blurt-app://` 先交给 `openURL`，返回 false 时外壳自己处理 `record`、`snap`。
- `MainWindowHosting`：`show()`、`reveal(uid:)`、`reveal(session:)`。
- `SettingsHosting`：`show(pane: String?)`。
- Info.plist 是文件 `recorder/macos/Info.plist`，由 WP4 维护，`record.py build` 拷进包里；已带 `CFBundleURLTypes`（`blurt`、`blurt-app`）、
  `NSServices`（"Add to Blurt"，`NSMessage` = `addToBlurt`）、`SUFeedURL`、`SUPublicEDKey`（仓库里为空，由 `release-mac.sh` 写入；
  为空时应用不启动 Sparkle）。WP6 只写这些声明背后的实现代码。
- 构建：`record.py build` = `swift build -c release --product blurt-recorder`（scratch 在 `$BLURT_HOME/build/swiftpm`），
  `BLURT_UNIVERSAL=1` 时 arm64 和 x86_64 各 `--triple` 构建一次再 `lipo`；然后组装 bundle、ad-hoc 签名。
- Sparkle（2.10.0，校验和固定）只进发布构建：`BLURT_SPARKLE=1` 时链接，`record.py build` 把 `Sparkle.framework` 放进
  `Contents/Frameworks` 并删掉非沙盒应用用不到的头文件和 XPC 服务。skill 用户本地构建不带 Sparkle、不需要联网，由 skill 自己更新；
  本地构建也不会覆盖或另装一份已安装的发布版（带 Sparkle 的那个自己更新）。体积：通用 + Sparkle 5.49 MB，本地 arm64 1.7 MB。
- 发布脚本在仓库根目录 `scripts/release-mac.sh`（不在 `skills/blurt/scripts/`，不随 skill 分发）：签名（Developer ID + hardened
  runtime）、DMG、公证和 staple、Sparkle zip 和 `appcast.xml`；钥匙串里没有 Developer ID 证书时自动 dry run（ad-hoc 签名、一次性 EdDSA 密钥）。
- 外部 URL：
  - `blurt://item/<uid>`
  - `blurt://session/<abs-path-encoded>`
  - `blurt://record`
  - `blurt://snap`
  - `blurt://settings[/<pane>]`（pane：`general`、`shortcuts`、`speech`、`agents`、`export`、`privacy`、`storage`）、`blurt://onboarding`（WP6 加）

细则（WP6 实现时补充，以代码为准）：
- **URL 安全**：任何网页都能打开 `blurt://`，所以 URL 只做「打开、定位」，不启动 agent，不写数据。`item` / `session` 先交给
  `mainWindow`（`show()` 后 `reveal(uid:)` / `reveal(session:)`），没有主窗口时打开该会话的审核窗口。
- **Agent 运行记录**：每次后台运行写 `$BLURT_HOME/runs/<run_id>.json`
  `{id, agent, repo, items: [uid], state: running|done|failed|cancelled, started, ended?, exit?, cost_usd?, summary?, log}`，
  原始事件流在同目录的 `<run_id>.log`。主窗口的「Agent 运行」读这些文件。开始前应用先对每个条目执行
  `items.py fix SESSION UID --state fixing --agent ID --run-id R`，agent 自己收尾时（mark_fixed）沿用这个 run_id（C1 规则）。
- **「修好了」**：应用用 FSEvents 监听所有工作区的会话目录，任何来源把某个条目的 `fix.state` 改成 `fixed`（应用拉起的 agent、
  终端里的交互式会话、同事同步过来的文件）都会触发啄虫动画和系统通知；第一次看到的文件只记基线，不补放旧的。
- **Spotlight**：domain `dev.blurt.items`，`uniqueIdentifier` = uid，内容来自 `index.db`；选中结果 = `blurt://item/<uid>`。
  测试用 `BLURT_SPOTLIGHT_DOMAIN` 换 domain，跑完删掉。
- **Services「Add to Blurt」**：当前工作区里每天一个收件箱会话 `<sessions>/<yyyyMMdd-HHmmss>-shots/`，`meta.json`
  `{"mode": "shots", "source": "service"}`；`items.json` 先写一个空的（items.py 要求文件存在），每条笔记用 `items.py add`
  加成 `kind: note`、`tags: ["inbox"]`、`source.app`，图片放 `frames/<id>-<n>.png` 再 `items.py set-frames`。
- **WP6 用到的配置键**（都在 `$BLURT_HOME/config.json`）：`lang`（和 record.py 共用）、`app.onboarded`、`app.settings_pane`、
  `app.asked_screen`、`fix.agent`、`fix.mode`（background | interactive）、`spotlight`（false = 关）、`privacy.local_asr`
  （只能选本地识别）、`privacy.keep_live_audio`（默认 false：转写完成、录屏文件在、10 分钟没写入后删 `live/audio.pcm`）、
  `asr.hf_mirror`（下载时传 `BLURT_HF_MIRROR=1`）；`asr.backend`、`asr.language`、`record.agents`、`review.open_in` 沿用。
  导出默认去向：项目写 `<repo>/.blurt/config.json` → `export`，默认工作区写全局 `export`。
- **index.db 只读打开的坑**（C3 的读者都要注意）：WAL 库在最后一个连接关闭后 SQLite 会删掉 `-wal` / `-shm`，这时
  `?mode=ro` 打开会在 prepare 时报 `SQLITE_CANTOPEN`。读者先试 `mode=ro`，失败就用 READWRITE（不带 CREATE）加
  `PRAGMA query_only = 1` 重开——只会重建 `-shm`，不写数据（WP5 的 IndexReader 和 WP6 的 IndexLookup 都这样做）。
- **测试钩子**：`BLURT_TEST_COMMANDS=1` 时 `dev.blurt.recorder.wp6[.$BLURT_TEST_CHANNEL]` 通知通道（见 `System/SelfTests.swift`）；
  `BLURT_NO_ONBOARDING` 不弹引导；`BLURT_AGENT_HOME` 让 `agents.py install` 在临时 HOME 里装；`BLURT_HOME` 非默认时从不请求通知权限
  （bundle id 和正式版共用）。

### C8 · Tauri（Windows/Linux）命令和录制引擎

Rust 命令（`apps/desktop/src-tauri`，WP7 实现）：

```
index_query(q: ItemQuery) -> {total, items: [ItemRow]}     index_sessions(q) -> [SessionRow]   index_workspaces() -> [...]
review_load(session) / review_poll(session, etag) / review_ops(session, ops, confirm)   (→ items.py user-ops)
agents_detect() / agent_run(id, prompt, repo) -> run_id    event "agent://line" {run_id, line}
settings_get() / settings_set(patch) / shortcut_set(action, combo) -> HotkeyResult
reveal(path) / open_external(url)
```

录制（WP8 的 `crates/blurt-capture` 加 `record.py` 的 ffmpeg 引擎）：

```
record.py start --engine ffmpeg --session DIR [--region=x,y,w,h] [--screen N] [--mic M|--no-mic] --status-jsonl
   stdout JSON lines: {"ev":"started","t0":…} {"ev":"level","rms":0.12} {"ev":"paused","t":…} {"ev":"resumed","t":…}
                      {"ev":"snap","n":3,"file":"shots/003.png","t":…} {"ev":"stopped","video":"recording.mp4","duration":…,"shots":…}
                      {"ev":"discarded"} {"ev":"error","msg":…,"code":…}
   control: existing `record.py stop|pause|resume|snap|discard` (cmd file), unchanged
   writes the same files as today (recording.mp4, events.jsonl, meta.json, live/audio.pcm, shots.jsonl)
Rust: blurt_capture::{start(&CaptureOptions, on_event) -> CaptureHandle, handle.pause/resume/snap/stop/discard/wait,
      overlay::pick_region(app, cfg, last) -> Option<Region>,
      overlay::{hud, perch, note, record}: transparent, always-on-top, non-focusable, content-protected windows}
```

- **状态行**：
  - 有 `--status-jsonl` 时 stdout 只有状态行，其余输出（`SESSION`、`DONE`、日志）都走 stderr；
  - 流一定以 `stopped`、`discarded`、`error` 三者之一结束，之后进程退出（退出码 0 / 2 / 非 0）；
  - `t` 是视频时间（秒），`t0` 是第一帧的墙钟时间；`level` 只在有麦克风时出现，约 10 Hz；
  - `{"ev":"error","code":"snap"}` 只表示这一张没截到，录制继续，不是结束行；
  - 字段只加不减，Rust 端遇到不认识的 `ev` 原样转给 HUD。
- **`--status-jsonl` 只配 `--engine ffmpeg`**，别的引擎直接报错。ffmpeg 引擎不支持 `restart`（先 `discard` 再重新 `start`）。
- **`--region` 的坐标**：Windows/Linux 是虚拟桌面的物理像素（gdigrab、x11grab 直接用），macOS 是主屏的点；
  宽高向下取偶数；x 可能为负，所以写成 `--region=x,y,w,h`。不给 `--region` 就录整个屏幕。
- **录制中截图**：Windows/Linux 另起一个 ffmpeg 抓一帧全分辨率（gdigrab、x11grab 可以和录像同时打开）；
  macOS 的 avfoundation 不能同时打开同一块屏幕（第二个会卡住），改用系统的 `screencapture`。暂停时也能截。
- **浮层窗口**（`blurt-overlay-picker|hud|perch|note`，页面在 `<frontendDist>/overlays/*.html`，由 `web/apps/overlays` 构建）：
  - 宿主应用（WP7）要给 `blurt-overlay-*` 窗口 `core:default` 权限，并打开 asset protocol（截图缩略图用）；
  - 页面和 Rust 之间只走事件：`blurt://status`（Rust→HUD，原样的状态行）、`blurt://action`（浮层→Rust，按钮）、
    `blurt://picked`（选区，窗口内 CSS 像素）、`blurt://hit-rects`（鸡舍可点区域，其余部分鼠标穿透）、
    `blurt://perch`（Rust→鸡舍：set/add/remove/show/hide/busy）、`blurt://note-done`、`blurt://ready`；
  - Linux X11 没有排除截屏的办法，所以 HUD 放在录制区域外面，放不下才贴着区域底边放在里面。

细则（WP7 实现时补充，以 `apps/desktop/src-tauri/src/lib.rs` 为准）：
- **参数名**：Rust 用 snake_case，JS `invoke` 用 camelCase（Tauri 默认），例如 `fix_with_agent(session, item_ids)` →
  `invoke('fix_with_agent', {session, itemIds})`。对象参数里的字段保持 C3 的写法（`q.fix_state`）。
- **`ItemQuery`** = `{query?, kind?: [], status?: [], fix_state?: [], severity?: [], workspace?: id|path, session?: id|dir,
  has_code_refs?: bool, sort?: "updated"|"created"|"t_start", limit=50, offset=0}`，查询规则照搬 C3 细则。
  返回 `{total, items, missing}`，`missing: true` 表示还没有 `index.db`（不是错误）。
  ItemRow 在 C3 的 12 个字段之外还带 `workspace_id, created, session_title, quote, tags, owner, module, t_start,
  frame_count, has_code_refs, user_edited, exported`。
- **`index_sessions(q?)`**：`q = {workspace?, state?: "unprocessed"|"processing"|"unreviewed"|"reviewed"|"inbox", limit, offset}`，
  `inbox` = 没整理、整理中或没审核；行 = `sessions` 表全部列 + `workspace_name, workspace_path, fixed_count`。
  `index_workspaces()` 的行 = `workspaces` 表 + `sessions, open_items`（open 的定义同 C4）。
- **review**：`review_load(session) → {doc, etag, session}`；`review_poll(session, etag) → {etag}`（没变）或 `{doc, etag}`；
  `review_ops(session, ops, confirm?) → items.py user-ops 的那行 JSON（{ok, etag}）`。ETag 与 `_common.file_etag` 相同。
  文件走 asset protocol（`convertFileSrc`）；应用把每个工作区的 sessions 目录和打开过的会话目录动态加进 asset scope。
- **agent**：`agents_detect() → agents.py detect 的输出`；`agent_run(id, prompt, repo) → run_id`（`r-YYYYMMDD-HHMMSS-xxxx`，
  提示词写进 `$BLURT_HOME/prompts/<run_id>.md`，用 `agents.py command … --prompt-file … --var run_id=…` 拿 argv，
  注入 `BLURT_AGENT` / `BLURT_RUN_ID`）。事件：`agent://started {run_id, agent}`、`agent://line {run_id, line, stream}`、
  `agent://exit {run_id, code, state}`；结束时发系统通知。补充命令：`agent_runs() → [AgentRun]`（最近 400 行日志、
  `total_cost_usd`）、`agent_stop(run_id)`、`agent_prompt(uids)`、
  `fix_with_agent(session, item_ids, agent?) → {run_id, agent, repo}`（会话必须在仓库工作区里；先 `items.py fix --state fixing`，
  agent 不给时用 detect 的 `pick`）、`process_session(session, agent?)`（提示词和 macOS 的 AgentHub / Snap 同一句）。
- **设置**：`settings_get() → {config, hotkeys: [HotkeyRow], hotkey_mode, wayland, export_targets, config_path}`；
  `settings_set(patch)` 按 `update_global_config` 的规则合并（顶层对象只合并一层），值为 `null` 删除该键。
- **快捷键**：配置沿用 `record.hotkeys`（不是 C7 写的 `record.shortcuts`，以现有代码为准），语法同 `_common.parse_hotkey`。
  常驻注册 `record` / `menu` / `snap`，其余录制中才注册。
  `HotkeyRow = {action, spec, label, default, active, result, of?, name?, hint?}`，
  `result = ok | off | idle（录制时生效）| duplicate（of）| system（name）| taken | unsupported（pen）| invalid | portal | pending | manual`。
  `shortcut_set(action, combo) → {result: ok|duplicate|system|taken|invalid, action?, name?, spec, label, hint?, row?}`，
  有冲突时不保存。Wayland：先用 GlobalShortcuts 门户（`hotkey_mode = portal`），没有门户时 `manual`，
  提示用户在系统设置里绑定命令 `blurt blurt://record`（单实例把 URL 转给正在运行的应用）。事件 `hotkeys://changed [HotkeyRow]`。
- **其它命令**：`app_status()`、`index_summary() → {missing, items, sessions, inbox, fixing}`、`index_item(uid)`、
  `index_rescan()`、`asr_models()`（`transcribe.py models`）、`open_path(path)`、`update_check()`、
  `capture_start(opts?: {session?, region?: [x,y,w,h], pick=true}) → session dir`（阻塞到开始录或取消，选区在 worker 线程里）、
  `capture_control("pause"|"resume"|"stop"|"snap"|"marker"|"discard")`、`capture_state()`。
  `open_external` 只放行 `http(s) vscode cursor zed claude-cli file` 这几种 scheme。
- **事件**：`index://changed {sessions}`（watcher 防抖 300 ms 后执行 `index.py update` 再发）、`index://status {scanning, error?}`、
  `capture://status`（状态行 + `session`，外加 `picking` / `cancelled`）、`nav {item: uid}|{session: dir}`（deep link）、
  `perch://action`。
- **deep link**：C7 的四个之外，`blurt://open|pause|stop|marker` 也认（给 Wayland 的系统快捷键用）。
- **配置键（新增）**：`record.last_region_px`（上次选区，物理像素）、`record.mic`（`false`/`"off"` = 不录麦克风，或设备名）、
  `app.editor`（`vscode`|`cursor`|`zed`，打开 code_refs 用）、`app.disable_dmabuf`（Linux：关 WebKit DMA-BUF 渲染；
  不设时检测到 NVIDIA 驱动就关）。
- **环境变量**：`BLURT_HOME`、`BLURT_WORKSPACE`、`HOME` 同 Python 侧；`BLURT_SCRIPTS`（脚本目录，默认依次找打包的
  `resources/scripts`、仓库、`~/.claude/skills/blurt/scripts`）；测试用：`BLURT_START_VIEW`、`BLURT_QUIT_ON_CLOSE`、
  `BLURT_LANG`、`BLURT_NO_SCAN`、`BLURT_NO_LOGIN_SHELL`、`BLURT_HOTKEY_MODS`、`BLURT_DISABLE_DMABUF`。
- **bundle id**：Tauri 应用用 `dev.blurt.desktop`（Windows/Linux 专用，和 macOS 的 `dev.blurt.recorder` 分开，以免在 Mac 上冒烟时冲突）。

---

## 6. 并行实施计划（8 个工作包）

**统一规则**：
- 每个包一个 worktree 和分支 `wp<N>-<name>`，都从本提交切出；
- 只改自己名下的路径；要改契约（§5），先在本文件提交，再通知其他包；
- `pnpm-lock.yaml` 和 `Cargo.lock` 不手工合并，合并时重新生成；
- 每个包的验收必须能在这台 Mac 上（或 CI 里）自动跑；只能在真机验证的项列进「延后到 VM」。

| WP | 名称 | 拥有的路径 | 提供 / 依赖的契约 | 合并顺序 |
|---|---|---|---|---|
| 1 | core-py | `scripts/items.py`、`scripts/_common.py`、`scripts/review.py`（只把 `apply_user_ops` 挪到 `_common`）、`reference/schema.md`、`tests/test_items_v2.py`、`tests/fixtures/sessions/**` | 提供 C1、C2 | 1 |
| 2 | services-py | `scripts/index.py`、`scripts/mcp_server.py`、`scripts/agents.py`、`scripts/agents.json`、`scripts/transcribe.py`（只新增 `models` / `bench` 子命令）、`SKILL.md`（新增 MCP 和 fix 两节）、`.claude-plugin/plugin.json`、`tests/test_index.py`、`test_mcp.py`、`test_agents.py`、`tests/fixtures/index/**` | 提供 C3、C4、C5；依赖 C1、C2 | 2 |
| 3 | web-review | `web/**`（pnpm workspace，`apps/*`、`packages/*` 用 glob 收录）、`skills/blurt/scripts/review.html`（构建产物，提交进仓库）、`.github/workflows/web.yml` | 提供 C6，含三种宿主适配；依赖 C1 | 3 |
| 4 | mac-shell | `skills/blurt/recorder/macos/**` 里的现有文件（迁到 C7 的目录结构）、`Package.swift`、`Sources/BlurtCore/{Paths,Config,Script,Hotkeys}.swift`、`Sources/BlurtApp/App/**`、Info.plist 模板、`record.py` 里构建和安装相关的函数、`.github/workflows/` 里现有的 mac 任务、`scripts/release-mac.sh`（签名、公证、Sparkle appcast） | 提供 C7 骨架 | 4 |
| 5 | mac-main-window | 新建：`Sources/BlurtApp/MainWindow/**`、`Sources/BlurtApp/WebHost/**`、`Sources/BlurtCore/Index/**` | 依赖 C3、C6、C7 | 5 |
| 6 | mac-settings-system | 新建：`Sources/BlurtApp/{Settings,Onboarding,System}/**`、`Sources/BlurtCore/Agents/**` | 依赖 C5、C7、C2 | 6 |
| 7 | tauri-shell | `apps/desktop/**`（不含 capture）、`web/apps/desktop/**`、`.github/workflows/desktop.yml` | 提供 C8 的命令；依赖 C2、C3、C5、C6 | 7 |
| 8 | tauri-capture | `crates/blurt-capture/**`（独立 crate）、`web/apps/overlays/**`、`record.py` 里 start 和 ffmpeg 引擎相关的函数（`--status-jsonl`） | 提供 C8 的录制部分 | 8（合并时在 WP7 的 `Cargo.toml` 里加一行 path 依赖） |

上表 `scripts/` 指 `skills/blurt/scripts/`。

**闸门**（为了能立刻开工又不撞文件）：
- WP4 的**第一个提交**只做两件事：机械地把文件迁到 C7 的目录结构；把 C7 里的 public API 签名写成桩函数，同时补全 Info.plist 的键。
  WP5、WP6 从这个提交切分支，在开工的第一小时内完成。
- WP2 先用自己的夹具开发，WP1 合并后改用 WP1 的夹具。
- WP7 的 `web/apps/desktop` 在 WP3 合并之前，用 `file:` 引用 WP3 分支上的 review 包。

### WP1 · core-py

- **范围**：实现 C1 和 C2，包括 uid（ULID 和 legacy 两种）、`fix` 加 `fix_history`、`get` / `list` / `fix` / `user-ops` / `ensure-uids`；
  把 `apply_user_ops` 挪到 `_common`；写夹具：v1 视频会话（没有 uid）、截图会话、带 fix 的 v2 会话。
- **验收**：
  - `uv run --with pytest pytest tests/` 全部通过，包括现有的 `test_items_merge.py` 和 `test_review_persistence.py`；
  - 同一组 ops 分别走 `items.py user-ops` 和 `review.py` 的 `POST /api/items`，写出的 `items.json` 逐字节一致；
  - legacy uid 和 C1 的公式一致；
  - 两个进程各并发执行 100 次 patch，不丢任何一次写入。
- **风险**：`review.py` 的运行行为不能有任何变化。

### WP2 · services-py

- **范围**：`index.py`（C3）、`mcp_server.py`（C4）、`agents.json` 加 `agents.py`（C5）、`transcribe.py models|bench`
  （输出已安装和可下载的模型，含大小和语言；在 30 秒样本上测 RTF）、SKILL.md 和插件清单。
- **验收**：
  - 夹具上执行 `scan`，计数正确；`search 登录按`（trigram）和 `search 登录`（LIKE 回退）都能命中；单个会话 `update` 少于 50 ms；
  - 用 MCP Python 客户端通过 stdio 调用全部 7 个工具，`get_item` 返回图片内容；
  - `agents.py detect` 在本机的结果和现有 Swift preflight 一致；`install --dry-run` 打印出正确的路径；
  - 手动加分项：`claude -p "用 blurt MCP 列出未修条目" --mcp-config …` 在本机能跑通。
- **风险**：codex 和 kimi 的 `mcp add` 语法（⚠ 实测后再固定）；trigram 在 1–2 个字的查询上效果一般，靠 LIKE 回退兜底。

### WP3 · web-review

- **范围**：
  - Vite、React、TypeScript 的 `packages/review`（`mode=review|item`）和 `packages/ui`（三平台 token，重做暗色模式）；
  - 三个宿主适配：browser、macos、tauri；
  - 用 `vite-plugin-singlefile` 生成 `review.html`；
  - 输入法回车防护。
- **验收**：
  - 用 Playwright 跑 WebKit 和 Chromium 两套，对象是 `review.py tests/fixtures/sessions/<v2>` 打开的页面；
  - 覆盖：A、X、J、K、Z、G、V；字段编辑后自动保存，`items.json` 里出现 `_user`；合并和撤销；
    agent 执行 `items.py set-frames` 后，页面 3 秒内显示新帧；模拟 keyCode 229 的回车不会触发提交；
  - 截图覆盖三平台 × 明暗两种主题；
  - 单文件产物不超过 400 KB ⚠；
  - 功能对照表逐项通过，以旧版 `review.html` 的行为为准。

### WP4 · mac-shell

- **范围**：
  - 迁移到 SwiftPM 模块结构（C7）；`record.py build` 改用 `swift build -c release` 加组装 bundle；
  - 把 `HotkeyCenter` 做成可配置（读 `record.shortcuts`），带冲突检测；
  - `ScriptRunner`（uv 检测，沿用 `agentEnvironment()`）；
  - Sparkle 2（不低于 2.9.2）和 appcast；
  - `release-mac.sh` 负责签名、公证、DMG，没有证书时走 dry-run。
- **验收**：
  - 只有 Command Line Tools 的环境下 `record.py build` 能产出可运行的 Blurt.app，且不超过 6 MB；
  - 现有的 `test_snap`、`test_live`、`test_e2e_recorder` 通过；
  - 手动清单：录制、截图、鸡舍、画笔、菜单都正常；
  - 改快捷键后立即生效；另起一个进程占用同一组合键时，返回 `.taken`；
  - 空闲 RSS 不超过 90 MB。
- **需要用户本人操作**：Developer ID 证书和公证账号，以及生成 Sparkle 的 EdDSA 密钥。

### WP5 · mac-main-window

- **范围**：
  - `NSSplitViewController`：侧栏 `NSOutlineView`（source list，带毛玻璃）；条目用 `NSTableView`，单元格基于视图、行高固定；
    详情区是 WKWebView，按 C6 的 macos 宿主协议实现；
  - `IndexReader` 用 SQLite3 C API 只读打开；`IndexWatcher` 用 FSEvents 触发 `index.py update`；
  - ⌘K 命令面板、右键菜单（复制路径、在访达中显示、在编辑器打开、让 agent 修：调用 `AppEnvironment` 里 WP6 注册的回调，
    没注册时置灰）、空格 Quick Look、窗口状态恢复；
  - 帧拖拽：画布通过 `registerDragRects` 上报帧的位置，原生层在对应区域铺透明的 `NSDraggingSource` 视图，拖出的是文件 URL。
- **验收**：
  - 用 C3 的 DDL 生成 2 万条合成数据：筛选并重载不超过 100 ms，输入搜索后 150 ms 内刷新（用 XCTest 计时）；
  - 在画布里编辑后，经 `items.py user-ops` 写盘；
  - 拖到访达生成文件，拖到终端粘贴的是路径（手动截图核对）；
  - VoiceOver 能读出每行的标题和状态（Accessibility Inspector）；
  - 明暗两种主题都要截图。
- **风险**：WKWebView 和透明拖拽视图之间的事件冲突（备选方案：只在按住 ⌥ 时拖拽）。

### WP6 · mac-settings-system

- **范围**：
  - 设置窗口：快捷键（录入、三层冲突检测）、语音（`transcribe.py models|bench|setup`）、Agent（`agents.py`）、导出、隐私、存储；
  - 引导流程（§2.2）；
  - `blurt://` URL 处理；CoreSpotlight 索引条目（标题、原话、主帧缩略图），点结果打开对应条目；
  - Services 里的「Add to Blurt」：把选中的文字或图片作为 note 放进收件箱；
  - `Agents` 封装和「让 agent 修」（headless 和交互式两种）。
- **验收**：
  - `open "blurt://item/<uid>"` 能定位到条目；
  - 在 Spotlight 里搜条目标题能找到（用 `CSSearchQuery` 写测试）；
  - 改快捷键后 `~/.blurt/config.json` 跟着更新；
  - 权限状态实时刷新（`CGPreflightScreenCaptureAccess`、`AVCaptureDevice.authorizationStatus`、`AXIsProcessTrusted`）；
  - 在本机用 Claude 跑通一次后台修复：fixture 仓库里修一个假 bug，执行 `mark_fixed`，应用里播放啄虫动画。
- **延后**：App Intents 需要 xcodebuild 提取元数据 [S36]，分享扩展需要扩展 target，这两项都要在 WP4 迁到 Xcode 工程之后再做。

### WP7 · tauri-shell（Windows/Linux）

- **范围**：
  - Tauri 2 加 React 外壳，复用 `packages/review` 和 `packages/ui`；
  - C8 的命令：rusqlite 只读，调用 Python 时用系统里的 uv 或 `~/.blurt/bin/uv`；
  - 托盘、全局快捷键（Windows 和 X11 用插件；Wayland 用 GlobalShortcuts portal [S14]，不可用时引导用户去系统设置绑定）、
    `notify` 文件监视、single-instance、deep-link、updater；
  - 打包：NSIS/MSI 和 deb/rpm/AppImage。
- **验收**：
  - 在这台 Mac 上 `pnpm tauri build` 能产出可运行的应用（只用于冒烟测试，不发布）；
  - CI 的 windows-latest 和 ubuntu-22.04 能构建全部安装包，并以 artifact 形式上传体积报告
    （目标：Windows ≤ 25 MB，deb ≤ 20 MB）；
  - Linux CI 在 xvfb 下用 tauri-driver 跑 e2e：打开夹具索引、搜索、打开条目、编辑后 `items.json` 被更新。
- **延后到 VM**：Windows 真机的托盘和快捷键、高 DPI、多显示器；Linux 上 GNOME 和 KDE 的托盘（appindicator）。
- **风险**：WebKitGTK 在 NVIDIA 显卡上黑屏 [S6]（关掉 WebGL，提供 `WEBKIT_DISABLE_DMABUF_RENDERER` 开关）。

### WP8 · tauri-capture（Windows/Linux）

- **范围**：
  - `record.py --engine ffmpeg --status-jsonl`（C8）；
  - `crates/blurt-capture`：选区遮罩、HUD、鸡舍、备注气泡用透明 WebView 窗口实现（`web/apps/overlays`），
    设为 contentProtected、always-on-top、不可聚焦；
  - 录制中截图走 ffmpeg 抽帧，写入 `shots.jsonl`。
- **验收**：
  - Ubuntu CI 在 xvfb 下用 x11grab 录 5 秒（无麦克风），产出 mp4、`events.jsonl` 和完整的状态行序列；
  - 录制中截图产出 `shots/001.png`，并写入符合契约的一行；
  - 在本机用 `--engine ffmpeg`（avfoundation）冒烟一次；
  - 浮层在 X11 CI 下能渲染（截图核对），并且是透明、置顶的。
- **延后到 VM**：Windows 上 `WDA_EXCLUDEFROMCAPTURE` 是否真的排除了浮层、ddagrab/gdigrab（#7 h264_qsv 卡死）、真实麦克风、
  Wayland portal ScreenCast、Windows 画笔。原生采集（`windows-capture` [S12]、PipeWire）作为后续工作包，契约 C8 不变。

### 合并后的集成检查（每合并一个包都在本机跑一遍）

1. `uv run --with pytest pytest tests/`
2. `pnpm -C web test && pnpm -C web build`
3. `record.py build` 后启动 Blurt.app，跑一次截图闭环：⌥⇧A → 鸡舍 → 整理 → 主窗口出现条目 → 审核 → 「让 Claude 修」→ 收到 `mark_fixed` → 播放啄虫动画
4. CI 上 desktop 的构建矩阵全绿

### 主要风险

| 风险 | 对策 |
|---|---|
| 应用写入依赖 Python 和 uv | 引导里安装并预热；没装好时只读降级；装 uv 前必须得到用户同意 |
| 契约跑偏 | 只有本文件 §5 算数；改契约要先提交本文件 |
| 迁移 WP4 时把现有功能搞坏 | 第一个提交是纯机械迁移，跑现有测试和手动清单后再改行为 |
| 输入法和拖拽在 WKWebView 里的体验 | C6 规定的回车防护，加 WP5 的原生拖拽层；不行就按 §1.3 的触发条件改成原生详情 |
| 签名、公证、Sparkle 密钥要用户本人操作 | WP4 先跑通 dry-run，拿到证书后再走一次真实发布 |
| 各家 agent CLI 变化快 | 改动集中在 `agents.json`；WP2 的测试用 `--dry-run` 校验 argv；CI 每周跑一次 detect |
| Windows/Linux 真机能力（WDA、DPI、Wayland）未验证 | 所有相关验收项明确标为「延后到 VM」，在 GCP 的 blurt-win / blurt-linux 上集中验证 |

---

## 来源

- [S1] Elanis, web-to-desktop framework comparison（GitHub CI 基准，2026-10）https://github.com/Elanis/web-to-desktop-framework-comparison
- [S2] Tauri 和 Electron 实测安装包对比 https://www.digitalapplied.com/blog/desktop-apps-web-stack-tauri-electron-deno-wails-2026 ；https://hackernoon.com/six-months-with-tauri-the-benefits-and-the-bill
- [S6] Tauri Linux 图形问题 https://v2.tauri.app/develop/debug/linux-graphics/
- [S7] tauri-nspanel https://github.com/ahkohd/tauri-nspanel
- [S10] Wails releases https://github.com/wailsapp/wails/releases
- [S11] Compose Desktop 体积和自绘界面 https://slack-chats.kotlinlang.org/t/32833859/hello-i-m-exploring-using-compose-desktop-for-a-project-and- ；https://www.infoq.com/news/2021/10/compose-multiplatform-beta
- [S12] windows-capture https://docs.rs/windows-capture ；scap https://lib.rs/crates/scap
- [S14] GNOME 48 GlobalShortcuts portal https://release.gnome.org/48/developers/
- [S16] GNOME Wayland 无法程序化置顶 https://discourse.gnome.org/t/any-way-to-set-window-always-on-top-programmatically/31579
- [S17] sherpa-onnx Rust crate https://docs.rs/sherpa-onnx
- [S18] SenseVoiceSmall ONNX int8 241 MB https://huggingface.co/OpenVoiceOS/sensevoice-small-onnx
- [S21] Claude Code headless https://code.claude.com/docs/en/headless
- [S22] Claude Code 插件清单 https://code.claude.com/docs/en/plugins-reference
- [S23] Claude Code deep links https://code.claude.com/docs/en/deep-links
- [S24] Codex skills https://learn.chatgpt.com/docs/build-skills
- [S25] Codex 非交互模式 https://learn.chatgpt.com/docs/non-interactive-mode
- [S26] Codex app-server https://developers.openai.com/codex/app-server ；mcp-server 退场 https://codex.danielvaughan.com/2026/08/28/codex-mcp-server-deprecated-app-server-migration-guide/
- [S27] Kimi Code CLI：https://moonshotai.github.io/kimi-cli/en/guides/getting-started.md ，print 模式 https://moonshotai.github.io/kimi-cli/en/customization/print-mode.md ，skills https://moonshotai.github.io/kimi-cli/en/customization/skills.md ，命令参考 https://moonshotai.github.io/kimi-cli/en/reference/kimi-command.md
- [S28] ZCode https://zcode.z.ai ；第三方集成文档 https://mem.nowledge.co/docs/integrations/zcode ，https://docs.cloudbase.net/en/ai/cloudbase-ai-toolkit/ide-setup/zcode
- [S29] ACP 注册表 https://zed.dev/blog/acp-registry
- [S30] 用链接打开 Claude 桌面版 https://support.claude.com/en/articles/14729294
- [S31] SwiftUI List 在大列表下的性能 https://www.hackingwithswift.com/forums/swiftui/swiftui-list-performance-with-row-count-2000/14259 ；https://developer.apple.com/forums/thread/761829
- [S32] 用 NSTableView 替换 SwiftUI https://mjtsai.com/blog/2024/04/15/nstableview-with-swiftui ；https://troz.net/post/2024/swiftui_lists/
- [S33] drag-rs（Tauri 往外拖文件）https://github.com/spacedriveapp/drag-rs ；https://docs.crabnebula.dev/plugins/drag-rs/
- [S34] Sparkle 2（增量更新、EdDSA）https://sparkle-project.org/documentation/upgrading/ ；CVE-2026-47121 https://www.mend.io/vulnerability-database/CVE-2026-47121/ ；Tauri updater https://v2.tauri.app/plugin/updater/
- [S35] Tauri deep linking（macOS 只能静态注册）https://v2.tauri.app/plugin/deep-linking/
- [S36] App Intents 元数据提取依赖 Xcode 构建 https://developer.apple.com/forums/thread/766501
- [S37] WebKit 后台降频和 wry 的 disableBackgroundThrottling https://github.com/tauri-apps/wry/pull/1445 ；https://v2.tauri.app/release/wry/v0.48.1/
- [S38] Swift 和 AI agent：https://iosdevweekly.com/issues/739 ；Apple UICoder（SwiftUI 在数据集中不到 1%）https://macdailynews.substack.com/p/apple-trains-llm-to-master-swiftui-interface-design
- [S39] WebKit 输入法回车 bug https://bugs.webkit.org/show_bug.cgi?id=165004
- [S40] sherpa-onnx Swift API 构建 https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/swift-api/build.rst
