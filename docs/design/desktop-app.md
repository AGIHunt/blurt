# 设计：Blurt 桌面应用（macOS / Windows / Linux）

2026-10-21 · 状态：决策稿，等拍板 · 基于 `feat/live-snap`（v0.6）的代码现状

目标：把「菜单栏小工具 + 浏览器审核页 + Python 脚本」升级成一个**给 vibe coder 用的想法/bug 管理器**：
跨项目管理录屏和截图批次、浏览历史条目、在应用内审核、一键交给 coding agent 修，并能看到修复结果回来。
总原则不变：**录制中绝不打断**；文件即契约（agent 只通过 `items.py` / 文件和我们对接）；默认本地、不上传。

文中 [S#] 指文末来源。标「⚠ 待验证」的是没找到一手资料、或要在 spike 里实测的结论。

---

## 0. 结论先行（TL;DR）

1. **UI 外壳用 Tauri 2**（Rust + 系统 WebView），前端 React + TypeScript；**采集和浮层按平台各写一个原生 helper**：
   macOS 直接复用现有 Swift 代码（ScreenCaptureKit 录制、选区、HUD、画笔、鸡舍、气泡）改成无菜单的 `blurt-capture` 子进程；
   Windows / Linux 用 Rust 写（Windows.Graphics.Capture / PipeWire portal），浮层先用 Tauri 的透明 WebView 窗口。
2. **审核页只写一份**：把 `review.html` 改写成前端模块，同一份构建产物既嵌在应用里，也打成单文件 HTML 随 skill 发布，
   给 SSH / 无桌面环境的 `review.py` 继续用。
3. **文件仍是唯一真相**（`items.json`、`shots.jsonl`、`live/`），应用加一个**可随时重建的 SQLite 索引**（FTS5 全文搜索），
   只读文件、只通过同一套「补丁 + 锁」语义写回。`items.py` CLI 继续作为 agent 的写入契约。
4. **Agent 集成三层**：SKILL.md（Claude Code / Codex / Kimi Code / ZCode 都能读）→ 本地 **MCP server**
   （`list_items`、`get_item`、`mark_fixed`…，四家都支持 MCP）→ 应用直接拉起 headless 运行（`claude -p` / `codex exec` /
   `kimi --print`）或用 deep link 打开交互式会话。ZCode 目前没有公开的 CLI/headless 模式，只能走 skill + MCP。
5. **Python 不进安装包**：安装包只带 `uv`（单个二进制）；转写和实时 ASR 改用 sherpa-onnx 的官方 Rust 绑定在应用内跑；
   frames / 导出等脚本仍由 agent 通过 `uv run` 调用，Python 和依赖首次用到时再下载。
   安装包目标：macOS ≤ 30 MB（universal），Windows ≤ 25 MB，Linux .deb ≤ 20 MB；语音模型（SenseVoice 约 240 MB）在应用内按需下载。

---

## 1. 框架选型

### 1.1 硬约束（从产品需求倒推）

| 约束 | 为什么关键 |
|---|---|
| 永不被录进去的浮层（HUD、鸡舍、气泡、选区遮罩、画笔墨迹） | 产品核心体验；现在 macOS 用 `sharingType = .none` 加 `SCContentFilter(excludingWindows:)`，Windows Tk 用 `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` |
| 非激活浮窗（点鸡舍不抢焦点、不把全屏 App 踢出 Space） | macOS 要 `NSPanel` + `.nonactivatingPanel`，WebView 框架默认做不到 |
| 全局快捷键（⌥⇧R/A/S/P/D、按住 ⌃ 画笔） | 「按住修饰键」不是普通 hotkey，要事件监听 |
| 平台采集 API | SCK（mac）、WGC（Win）、PipeWire portal（Wayland）；音视频同步已在 Swift 里调到一帧以内 |
| 安装包小、开发人力少（1 人 + AI agent） | 想做成爆款开源，下载体积和「看起来精致」都直接影响 star |
| 复用 | 约 5.8k 行 Swift、约 5k 行 Python、868 行 `review.html` |

### 1.2 对比

体积和内存优先用同一套方法的数据：Elanis 的空应用基准在 GitHub CI 上跑，数据更新到 2026-10 [S1]。

| | Tauri 2 | Electron | Wails v3 | Flutter | Compose MP | Qt 6 | 原生×3 |
|---|---|---|---|---|---|---|---|
| 空应用构建体积 Win/mac/Linux [S1] | ≈3 / 5 / 4 MB | ≈385 / 320 / 296 MB | ≈11 / 8 / 9 MB | ≈25 MB（Win） | DMG 约 100 MB（社区报告）[S11] | ⚠ 约 30–60 MB（经验值，未实测） | 最小 |
| 真实应用安装包 | 一组同功能对比：12–18 MB，对 Electron 201–290 MB [S2]（方法未公开） | 同左 | — | — | — | — | — |
| 内存（Release，主进程加子进程中位数）[S1] | mac ≈96 MB，Win ≈307 MB（WebView2 就是 Chromium） | mac ≈364 MB，Win ≈279 MB | mac ≈100 MB | — | 启动约 100 MB [S11] | 低 | 最低 |
| 原生观感 | WebView 自绘；能用 vibrancy / Mica 材质和系统字体 | 同左 | 同左 | Skia 自绘，不像任何平台 | Skia 自绘 [S11] | Widgets 接近原生，QML 要自己调 | 最好 |
| 采集 API | Rust crate：`windows-capture`、`screencapturekit-rs`、scap、xcap [S12]；Cap 就是 Tauri + Rust 录屏 [S13] | `desktopCapturer`（Chromium） | Go 生态弱 | 要写平台插件 | JNI | C++ 直接调 | 直接调 |
| 浮层：不被采集 | `contentProtected`（tao 已修过 mac 崩溃）[S8] | `setContentProtection`；对第三方 SCK 采集是「尽力而为」[S9] | 有 | 插件 | 无 | 直接调 | 直接调 |
| 非激活面板 | `tauri-nspanel` 插件 [S7] | 要写 native addon | 无 | 无 | 无 | 可以 | 可以 |
| 全局快捷键 / 托盘 | 官方插件（global-shortcut、tray 在核心）[S4]；**Wayland 下快捷键插件不可用** [S15] | 有；Wayland 同样受限 | 有 | 社区插件 | 社区 | 自己写 | 自己写 |
| 自动更新 / 签名 | 官方 updater（签名更新包），mac 公证、Win 签名都有内置流程 | electron-updater，最成熟 | 一般 | 弱 | jpackage | 自己搭 | 每个平台各搭一套 |
| 复用现有资产 | review.html 直接迁；Swift 作为 sidecar；Python 用 sidecar 或 `uv` | 同左，另可跑 Node | 同左（Go） | 审核页要重写 | 要重写 | PySide6 能复用 Python，但包大 | Swift 全复用，Win/Linux 全部重写 |
| 稳定性 | 2.x 稳定 | 最稳 | **v3 仍是 beta**（v3.0.0-beta.12 标为 pre-release）[S10] | 稳 | 稳 | 稳 | — |
| 1 人 + AI 的维护成本 | 中：一份 UI，三份采集 | 低 | 中 | 中 | 中 | 高（C++/QML） | **很高**：三份 UI |

### 1.3 决策：Tauri 2 外壳 + 各平台原生采集 helper

理由：

- **体积**：比 Electron 小一个数量级 [S1][S2]，这是唯一一个和「小安装包」诉求直接冲突的选项。
  ZCode、Claude 桌面版这些 agent 工具本身多是 Electron，我们小就是卖点。
- **一份 UI**：AI agent 写 React/TS 最熟练；审核页本来就是 Web，迁移成本最低。三套原生 UI 对一个人来说维护不过来。
- **Rust 生态正好覆盖我们的难点**：sherpa-onnx 有官方 Rust 绑定（默认静态链接，自动下载预编译库）[S17]，
  有 WGC / SCK / PipeWire 的采集 crate [S12]；Cap（开源 Loom）证明 Tauri + Rust 采集能做成产品 [S13]。
- **最难的浮层留在原生**：macOS 的选区、HUD、画笔、鸡舍、气泡已经调好，用 `NSPanel` + `sharingType none`，
  还在自己的 `SCContentFilter` 里排除了这些窗口。这些东西搬进 WebView 只会变差，所以整块保留成 Swift helper。

已知风险及对策：

| 风险 | 对策 |
|---|---|
| 三个 WebView 引擎不同（mac 是 WebKit，Win 是 WebView2/Chromium，Linux 是 WebKitGTK） | CI 跑 Playwright WebKit 和 Chromium 两套；不用前沿 CSS |
| Linux WebKitGTK 在 NVIDIA 下黑屏、闪烁，WebGL 慢 [S6] | 不用 WebGL；文档里给出 `WEBKIT_DISABLE_DMABUF_RENDERER=1` 这个开关 |
| Wayland：全局快捷键插件不可用 [S15]；GNOME 不能程序化置顶，也不支持 layer-shell [S16] | 快捷键走 GlobalShortcuts portal（GNOME 48+、KDE 支持）[S14]；GNOME Wayland 下鸡舍降级为「窗口内托盘 + 系统通知」；X11 下功能完整 |
| macOS 屏幕录制权限归属：helper 是子进程 | helper 放进 `Blurt.app/Contents/MacOS/`，由主进程拉起，TCC 应该认主 App（⚠ 待验证，spike 第一天就测） |
| 新增 Rust 技术栈 | Rust 只做薄层（IPC、索引、ASR、进程管理），业务判断仍在 agent / skill 里 |

否决的选项：

- **Electron**：安装包 200–300 MB，内存在 mac 上是 Tauri 的 3–4 倍 [S1]。唯一优势是生态和 Chromium 行为一致。
- **Wails**：v3 还没正式发布 [S10]，Go 侧没有 sherpa-onnx 和 NSPanel 的现成方案。
- **Flutter / Compose**：自绘 UI 不像任何平台，审核页要重写，浮层和采集要自己写插件。
- **Qt / PySide6**：能复用 Python，但 C++/QML 对 AI 不友好，PySide6 包很大，LGPL 合规也费事。
- **原生×3**：观感最好，但 UI 工作量变三倍。保留一个演进方向：如果 Tauri 在 mac 上观感不达标，
  只把 mac 主窗口换成 SwiftUI，前端组件继续给 Win/Linux 用。

### 1.4 进程结构

```
Blurt.app / Blurt.exe / blurt (Tauri 主进程, Rust)
├─ WebView：主窗口 / 审核 / 设置（React）
├─ core（Rust）：SQLite 索引 · 文件监视 · items 补丁与锁 · ASR（sherpa-onnx）· agent runner · MCP server · 快捷键注册表
├─ 子进程 blurt-capture（JSON-lines over stdio）
│    macOS: Swift（现有 Recorder / Snapper / Perch / HUD / InkView / NoteBubble，去掉 NSStatusItem）
│    Windows: Rust（windows-capture + WASAPI + Media Foundation H.264；浮层 = Tauri 透明窗口 + contentProtected）
│    Linux: Rust（X11: ffmpeg x11grab 先用起来；Wayland: xdg-desktop-portal ScreenCast + PipeWire + GStreamer）
├─ 子进程 agent（claude / codex / kimi，用用户登录 shell 的环境）
└─ 子进程 uv run …/scripts/*.py（frames、export、feishu；agent 也这样调）
```

IPC 协议示意：`{"cmd":"start_recording","region":…,"session":"…"}` → helper 推送事件
`{"ev":"level"}`、`{"ev":"snap","n":3}`、`{"ev":"stopped","video":…}`。live 管线照旧走文件（`live/audio.pcm` 等），
主进程里的 Rust ASR 直接 tail 这个文件，所以 `live.py` 的约定一字不改。

### 1.5 Python 管线和本地 ASR 怎么发布

| 方案 | 安装包增量 | 首次使用 | 结论 |
|---|---|---|---|
| A. 打包 python-build-standalone 加 numpy / sherpa-onnx | 解压后 100 MB 以上；压缩包 30–60 MB/平台 [S19] | 即用 | ✗ 包太大 |
| B. PyInstaller sidecar | 约 70 MB/个（社区报告）[S5] | 即用 | ✗ |
| **C. 只带 `uv` 二进制，脚本由 `uv run` 按需装依赖** | ⚠ 压缩后约 15 MB（待测） | 首次装 Python 和依赖，约 1 分钟 | ✓ 用于 frames / 导出 / 飞书 |
| **D. 热路径改 Rust：ASR、items 补丁 / 锁、索引** | sherpa-onnx 加 onnxruntime 静态库 ⚠ 约 15–25 MB/架构（待测） | 即用 | ✓ 用于转写、实时字幕、语音备注 |

做法：

- **转写和实时 ASR 用 Rust**（sherpa-onnx 官方 crate [S17]，SenseVoice int8 约 241 MB [S18]，Silero VAD）。
  分段逻辑照搬 `transcribe.py`：≤1 s 的间隙合并，单段最长取后端上限。用现有 `tests/test_live.py` 的音频做对拍，
  保证 Rust 和 Python 转出的 `transcript.json` 逐段一致。`transcribe.py` 保留，给没装应用的 skill 用户。
- macOS 安装包只带 arm64 + x86_64 两份 onnxruntime，两份都嫌大就分两个 DMG 发布。
- **云 ASR**（Groq / OpenAI / DashScope）在 Rust 里就是 HTTP 调用；key 存系统钥匙串（keyring crate），不写明文配置。
- frames.py（numpy / pillow）等脚本暂时不动：本来就是 agent 在调用。应用把自带的 `uv` 放进 agent 进程的 `PATH`，
  并在空闲时预热依赖，解决 TODO 里「codex 第一次跑 frames.py 花 59 秒装 numpy」的问题。
- 远期（第 4 阶段）：做一个 Rust 写的 `blurt` CLI，取代 `items.py` / `frames.py` 的热路径，Python 版降为后备。

---

## 2. 产品与信息架构

### 2.1 主窗口

```
┌ Blurt ─────────────────────────────────────────────────────────── ⌘K 搜索 ─┐
│ ● 录制 ⌥⇧R   📸 截图 ⌥⇧A          项目: [ my-saas ▾ ]            🥚 整理中 1 │
├──────────────┬──────────────────────────────────────┬──────────────────────┤
│ 收件箱    3  │ 条目  [issue ✓][idea][note][task]     │ I-014 · issue · P1   │
│ 全部条目  128│ 状态: 待处理 ▾  项目: 全部 ▾  时间 ▾  │ 登录按钮点击无响应    │
│ 会话         │ ──────────────────────────────────── │ ┌──────────────────┐ │
│ Agent 运行 ● │ 🐞 登录按钮点击无响应    my-saas  2h  │ │  frame #1 (红框)  │ │
│ 导出         │ 🐞 价格页移动端溢出      my-saas  2h  │ └──────────────────┘ │
│ ── 项目 ──   │ 💡 学 Linear 的空状态    ideas    1d  │ ◀ 1/3 ▶  ▶ 片段 0:14 │
│  my-saas     │ ✓ 🐞 头像上传 500  → 已修 #a1c3   3d  │ "这个登录按钮点了…"   │
│  blog        │ ☐ 联系设计确认配色       (task)  3d  │ 实际/期望/步骤…       │
│  ~/Blurt     │                                      │ 代码: src/auth/Login… │
│              │                                      │ [让 Claude 修 ⌘↩] [导出]│
│ ⚙ 设置       │                                      │ 历史: 创建→确认→已修   │
└──────────────┴──────────────────────────────────────┴──────────────────────┘
```

- **收件箱**：还没整理或还没审核的录屏和截图批次，每个显示状态蛋：🥚 待整理 → 晃动 = 整理中 → 🐣 待审核。
  按 `↩` 开始整理，选择用哪个 agent。
- **全部条目**：跨项目、跨历史的条目库，用 SQLite FTS 支撑。筛选维度：kind、状态（draft / confirmed / exported /
  fixing / fixed / dropped）、项目、严重度、时间、负责人、有没有代码引用、导出到了哪里。可以存成「智能视图」。
- **会话**：时间线视图。点开是会话详情：视频播放器加字幕滚动（点字幕跳到对应时刻），条目在时间轴上标点，
  旁边是 digest（总览）。
- **条目详情**：多帧轮播（标框）、片段、原话、lens 字段、`code_refs`（点开在编辑器里打开：`vscode://file/…`、
  `cursor://`、`zed://`）、问题和回答、事件历史（谁在什么时候改了什么、导出链接、修复运行记录）。
- **审核模式**（`R` 或从收件箱进入）：全屏，照搬现在的键位：A 保留 · X 丢弃 · J/K 下一条/上一条 · Z 撤销 · G 列表 · V 总览。
  整理还在进行时，帧陆续补进来，这个机制和 v0.6 一样。
- **Agent 运行**：每次 headless 运行一行，显示 agent、项目、触发条目、状态和耗时、费用（`claude -p --output-format json`
  里有 `total_cost_usd` [S21]）。点开看流式日志（stream-json 解析成步骤列表）。
- **导出**：导出目标的历史，以及失败后可续传的任务。

### 2.2 菜单栏 / 托盘、浮层

- **托盘菜单**：录制 / 截图 / 显示鸡舍 / 当前项目切换 / 最近 5 个会话（带状态蛋）/ 打开 Blurt（⌥⇧B）/ 退出。
  图标状态：待机 🐔、录制中红点、整理中蛋晃动。
- **浮层**（全部是独立窗口，不被采集）：选区遮罩、倒计时、HUD（计时、电平、⏸ ↺ 📸 ✎ 完成、下蛋小窝、实时字幕）、
  画笔墨迹层、鸡舍、备注气泡。macOS 用 Swift 原生实现；Win/Linux 用透明 Tauri 窗口（`alwaysOnTop`、`focus: false`、
  `skipTaskbar`、`contentProtected`），动效用 CSS spring 和 canvas 移植 `Perch.swift` 里的弹簧参数。
- **「修好了」时刻**：agent 标记 fixed 时，主窗口条目划掉，托盘弹一个小鸡把虫子啄掉的动效加通知
  （design 文档 §2 留的伏笔）。

### 2.3 首次引导（4 步，可跳过）

1. **权限**：屏幕录制、麦克风；macOS 要按住 ⌃ 画笔还需要辅助功能权限。每项旁边有「去系统设置」按钮，授权后实时变绿。
2. **语音模型**：检测 CPU / GPU 和系统语言后推荐一个（中英文推荐 SenseVoice 240 MB，其他语言推荐 Whisper）。
   下载时显示进度，国内自动用 hf-mirror。也可以选云端，key 存钥匙串。
3. **Agent**：自动探测 `claude` / `codex` / `kimi`，以及 ZCode 是否安装，显示登录状态。
   一键「安装 skill + MCP」：列出会写哪些文件，用户确认后才写。
4. **绑定项目**：选一个仓库目录，创建 `.blurt/`，建议把 `.blurt/sessions/` 加进 `.gitignore`。
   最后让用户截一张图试一下，20 秒体验完整闭环。

### 2.4 设置

| 页 | 内容 |
|---|---|
| 快捷键 | 录入式编辑。冲突检测分三层：① 本应用内部重复；② 已知系统快捷键表（⌘⇧3/4/5、Win+Shift+S…）；③ 向系统注册失败就判定为被其他 App 占用。Wayland 下显示「由系统设置管理」，走 portal [S14] |
| 语音 | 模型列表：已装 / 可下载、大小、语言、本机实测 RTF（「跑分」用内置的 30 s 样本音频）、设为默认、删除；云端 key；麦克风测试 |
| Agent | 默认 agent，可按项目覆盖；草稿用的小模型；无人值守运行的权限模式（默认 Claude `--permission-mode acceptEdits`、Codex `--sandbox workspace-write`）；安装或卸载 skill / MCP；登录状态 |
| 导出 | 飞书 / GitHub / Linear / Markdown 目标，按项目设置（写进 `.blurt/config.json` 的 `export`） |
| 隐私 | 纯本地模式（禁用云 ASR 和远程导出）；保留策略（`live/audio.pcm` 在转写校验后删除，录屏 N 天后清理）；列出哪些数据会离开本机 |
| 存储 | 默认工作区位置、各项目占用空间、一键清理 |

### 2.5 视觉语言：让它在每个平台都像「本地人」

- **材质**：mac 侧栏用 vibrancy（`sidebar` 材质），Win11 用 Mica，Linux 用不透明的 libadwaita 色板。
  通过 Tauri 的窗口效果配置实现，按 `data-platform` 切换（⚠ 各平台的材质名在 spike 里核对）。
- **字体和控件**：系统字体栈（SF Pro / Segoe UI Variable / Cantarell、Noto 加 PingFang / 微软雅黑）；
  mac 用圆角 6 的小控件，Win 用 Fluent 的 4px 圆角和焦点环，GNOME 用 libadwaita 的大圆角按钮。
  只做三套 token，组件只写一份。
- **暗色模式重做**（现在的问题是对比度和层级都靠一种灰）：
  - 层级用**亮度递增的表面**，不靠阴影：mac 是 `#1E1E1E` 窗口 / `#2A2A2A` 卡片 / `#323232` 悬停；
    Win 是 Mica 上 `#202020` / `#2B2B2B`；GNOME 是 `#242424` / `#303030`（与 libadwaita 一致）。
  - 分隔线 `rgba(255,255,255,.08)`；文字三档 92% / 64% / 40%。
  - 品牌橙 `#FF5C3D` 在暗色下降饱和、提亮度（约 `#FF7A5C`），只用在主按钮和选中态，大面积不用。
  - 截图和视频周围加 1px 内描边，避免深色截图和背景糊成一片。
  - 跟随系统，也允许手动覆盖；强调色优先用系统强调色（CSS `AccentColor`，⚠ 各 WebView 是否支持待测，不支持就回退品牌色）。
- **动效**：蛋、鸡舍、啄虫要有趣，但列表、表单要克制；尊重「减弱动态效果」设置。

### 2.6 键盘优先

`⌘K` 命令面板（跳转项目 / 会话 / 条目，执行「修这个」「导出」）· `/` 搜索 · `J/K` 移动 · `↩` 打开 · `⌘↩` 交给 agent ·
`E` 编辑标题 · `1-4` 改 kind · `S` 改状态 · `⌘E` 导出 · `R` 审核模式 · `?` 键位表。所有全局快捷键都可改。

---

## 3. 数据模型与存储

### 3.1 原则：文件是真相，SQLite 是索引

现有布局保持不变，这是 skill 和 agent 的契约：

```
~/Blurt/recordings/<ts>/          默认工作区（没绑定项目时）
<repo>/.blurt/sessions/<ts>/      绑定项目
   meta.json  recording.mp4  events.jsonl  transcript.json  items.json  shots.jsonl  shots/  frames/  clips/  live/
<repo>/.blurt/config.json  lenses/      项目配置
~/.blurt/config.json  models/            全局配置（record.workspaces 列出绑定的项目）
```

应用新增 `<AppData>/Blurt/index.db`（mac：`~/Library/Application Support/Blurt/`）。删掉它就从文件重建，不丢任何东西。

```sql
workspaces(id, path, name, kind /*default|repo*/, last_seen)
sessions(id /*ws_id:ts*/, workspace_id, dir, mode /*video|shots*/, title, author, created, duration,
         processed, reviewed, processing, items_mtime)
items(uid, session_id, item_id /*I-001*/, kind, title, status, severity, owner, module,
      t_start, primary_frame, has_code_refs, exported_json, fix_json, updated)
items_fts USING fts5(title, quote, body, tags, content='items')
item_events(uid, at, actor /*user|agent:claude|app*/, op, payload)   -- 来自 items.json 的差异和应用操作
agent_runs(id, agent, workspace_id, session_id, item_uids, cmd, status, started, ended, cost_usd, log_path)
```

- **索引**：用 `notify` crate 监听所有工作区的 `sessions/`，`items.json` 或 `shots.jsonl` 一变就重新解析该会话
  （按 mtime 去重）。启动时全量扫描一次，等价于 `record.py inbox` 的 `recording_roots()`。
- **写入**：应用的编辑（审核、改状态）走和 `review.py` 一样的「字段补丁 + `_user` 标记」语义，并且持有同一把
  `.items.lock`。把 `_common.items_lock` 和 `review.apply_user_ops` 移植到 Rust，用 `tests/test_items_merge.py`
  的用例导出 JSON 夹具，Rust 和 Python 两边跑同一套用例。
  ⚠ Windows 上 Python 的 `msvcrt.locking` 和 Rust `LockFileEx` 互斥要实测。
- **schema v2**（向后兼容，只加字段）：
  - 顶层 `schema: 2`。
  - 条目上加 `uid`（ULID，由 `items.py add` 和首次索引时补写）：跨会话引用和 MCP 都用它。
  - 加 `fix: {state:"fixing|fixed|wontfix", agent, run_id, commit, pr, at, note}`。
  - `status` 维持现有的 `draft|confirmed|deleted`；「已修」放在 `fix.state`，不和审核状态混在一起。

### 3.2 和仓库内 `.blurt/` 同步

- 会话**留在原地**，应用不搬文件，所以 agent 在仓库里照常能看到。
- 可选「项目待办快照」：`blurt sync` 生成 `.blurt/BACKLOG.md`（未修的 confirmed 条目，带帧的相对路径），
  默认放进 gitignore；团队想提交就自己打开。这让没装应用的队友和 agent 也能看到待办。
- 团队共享目录（多个人录到同一个绑定目录）：索引按 `meta.json.author` 区分作者，不需要额外同步机制。

### 3.3 迁移

- 没有数据迁移：首次启动读取 `~/.blurt/config.json` 里的 `record.workspaces` 和 `~/Blurt`，建立索引即可。
- 替换旧版菜单栏 App：新版检测到 `~/Applications/Blurt.app`（旧版 Swift 单体）在运行，就提示「新版接管快捷键」，
  然后退出旧进程、移除旧的登录项。`record.py build` 改为提示下载新版（skill 侧保留 Tk 录制器作为无应用环境下的后备）。
- 配置键（`record.workspace`、`record.workspaces`、`record.live_drafts`、ASR 配置）全部沿用。

### 3.4 Agent 怎么读写

- **写**：`items.py` 仍是唯一允许的写入口（加 `fix` 子命令：`items.py fix SESSION ID --state fixed --commit …`）。
  MCP 的写工具内部也走同一套逻辑。
- **读**：直接读文件，或者用 MCP（更省 token，也能跨项目）。SKILL.md 里写清楚：有 MCP 就优先用 MCP 查询，
  写入仍然可以用 `items.py`。

---

## 4. Agent 集成

### 4.1 各家现状（2026-10 调研）

| | Claude Code | Codex | Kimi Code CLI | ZCode（智谱） |
|---|---|---|---|---|
| 形态 | CLI、IDE、桌面版 | CLI、IDE、桌面版 | CLI（`kimi`），旧 Kimi CLI 已归档 [S27] | **桌面应用**（v3.16.2，mac / Win / Linux）[S28] |
| Skill | `SKILL.md`；插件可打包 skills、MCP、hooks、`bin/` [S22] | `SKILL.md`；扫描 `.agents/skills`（仓库，向上到根）、`~/.agents/skills`；插件分发 [S24] | `SKILL.md`；**会读 `.claude/skills`、`.codex/skills`、`.agents/skills`、`~/.config/agents/skills`** [S27] | 设置 → Skills 导入 SKILL.md（第三方文档）[S28] |
| MCP | `.mcp.json`、插件 `mcpServers`、`--mcp-config` | `config.toml` `[mcp_servers]`、插件 [S24] | `kimi mcp add`、`--mcp-config-file` [S27] | 设置 → MCP 服务器，支持 stdio（第三方文档）[S28] |
| Headless | `claude -p --output-format stream-json`；`--permission-mode`、`--resume` [S21] | `codex exec --json`、`-o`、`--sandbox workspace-write`、`exec resume` [S25] | `kimi --print --output-format stream-json`、`-w`；exit 75 表示可重试 [S27] | **没有公开的 CLI 或 headless 模式**；可以通过微信 / 飞书 / Telegram 远程唤起 [S28] |
| 嵌入协议 | Agent SDK；ACP（Zed 的 ACP 注册表有收录）[S29] | **app-server**（JSON-RPC over stdio，桌面版和 VS Code 插件都用它）[S26] | `kimi acp` [S27] | 未知 |
| Deep link | `claude-cli://`：开终端、预填 prompt 和目录，不自动执行 [S23]；桌面版 `claude://code/new` [S30] | ⚠ 未找到 | ⚠ 未找到 | ⚠ 未找到 |
| 登录检测 | `claude auth status --json`（现已在用） | `codex login status`（现已在用） | ⚠ 没有 status 命令；用 `kimi --print --quiet -p ping` 加超时探测，看 exit code 1 和输出内容 | 只能检测是否安装 |

**关键发现**：SKILL.md 已经是事实标准。Kimi 直接读 `.claude/skills`，Codex 读 `.agents/skills`。
所以 **skill 装两处（`~/.claude/skills/blurt` 和 `~/.agents/skills/blurt`，后者用符号链接）就能覆盖三家**，ZCode 手动导入一次。
MCP 是第二个通用层，四家都支持。

### 4.2 集成三层

**L1 · Skill（现有，继续是主契约）**
`npx skills add AGIHunt/blurt` 或 Claude 插件市场。插件里加三样东西：
- `mcpServers`：`blurt mcp`
- `bin/blurt`：Claude Code 运行时这个命令会在 PATH 上 [S22]
- 一个 `Stop` hook：会话结束时调用 `blurt notify`，让应用刷新

**L2 · MCP server（新）**：`blurt mcp`，stdio 传输，由应用的 Rust core 提供。没开应用时由 CLI 只读运行。

| tool | 说明 |
|---|---|
| `list_projects()` / `list_sessions(project?, status?)` | 工作区和会话 |
| `list_items(project?, kind?, status?, fix_state?, query?, limit)` | FTS 搜索，跨历史 |
| `get_item(uid, frames: true)` | 字段加帧（MCP image content，主帧缩到 1280px）加原话加 code_refs |
| `get_session_transcript(session, from?, to?)` | 按时间窗取字幕，省 token |
| `update_item(uid, patch)` | 同 `items.py patch`，保护 `_user` 字段 |
| `mark_fixed(uid, commit?, pr?, note?)` / `mark_wontfix` | 写 `fix`，应用收到后播放啄虫动画 |
| `add_snap(png, note)`（可选） | agent 也能往鸡舍挂图，比如把修好后的截图挂上去对比 |

资源：`blurt://item/<uid>`、`blurt://session/<id>/digest`。

**L3 · 应用驱动 agent**

- **后台整理**（现有功能升级）：录完或点「整理」时运行
  `claude -p "/blurt process <session>" --output-format stream-json --permission-mode acceptEdits`；
  Codex 是 `codex exec --json --sandbox workspace-write`，Kimi 是 `kimi --print --output-format stream-json -w <repo>`。
  解析事件流，在「Agent 运行」里显示进度。沿用 v0.6 的做法：继承登录 shell 的环境，不用 bare 模式，
  因为 bare 不读 OAuth 登录状态 [S21]。
- **「让 agent 修这个」**（`⌘↩`，或者多选后「修这 5 个」）：
  1. 在条目所属的仓库里生成提示词：条目 uid 加一句「用 blurt MCP 读取详情，修完调用 mark_fixed」。
  2. 默认**交互式**：Claude 用 `claude-cli://` deep link，打开用户惯用的终端并预填 prompt，用户按回车才执行 [S23]；
     装了 Claude 桌面版可以选 `claude://code/new`。Codex / Kimi 没有 deep link，就在用户的终端里打开
     `codex "<prompt>"` 或 `kimi`（mac 用 AppleScript 驱动 Terminal / iTerm，Win 用 `wt.exe`）。
  3. 可选**后台修**：headless 运行，结束后在运行详情里显示 diff 摘要。不自动提交、不推送，只把 `fix.state` 标成
     `fixing → fixed`，由用户验收。
- **状态回传**：agent 调用 `mark_fixed`，或者执行 `items.py fix`，写入 `items.json`；文件监视触发后更新 UI，
  并播放啄虫动画加通知。Claude 插件的 Stop hook 再兜一层底。
- **选 agent 的顺序**：项目级设置 → 全局默认 → 已登录的那个（Claude Code → Codex → Kimi）→ 都没登录就显示
  「复制提示词」和「去登录」的说明（现有 preflight 逻辑扩展到 Kimi）。ZCode 用户：引导一次性导入 skill 和 MCP，
  「修这个」变成复制提示词，提示用户粘贴到 ZCode。
- **以后可选**：内嵌对话面板，通过 ACP 连接 `kimi acp` 和注册表里的 Claude / Codex 适配器 [S29]，
  或者 Codex app-server [S26]。这是第 4 阶段的事，MVP 不做，避免变成又一个 agent 客户端。
- **其他 agent**（Gemini CLI、OpenCode、Qwen Code、Cursor CLI…）：提供「自定义 agent」模板，
  `command: "xxx -p {prompt}"`、`cwd: {repo}`、`login_check: …`。⚠ 这些没逐个调研。

---

## 5. 路线图

估算口径：1 名开发者加 AI agent 并行，单位是周（含测试和打包），乐观到保守的范围。

| 阶段 | 内容 | 估算 |
|---|---|---|
| **P0 Spike** | Tauri 壳加托盘；拉起 Swift helper 并用 stdio 通信；**验证 TCC 权限归属**；新 React 审核页渲染真实的 `items.json`；SQLite 索引扫描 `~/Blurt`；实测 universal DMG 体积和 sherpa-onnx 静态库体积 | 1–1.5 |
| **P1 macOS MVP**（取代菜单栏 App） | Swift 改成 `blurt-capture`（去掉 NSStatusItem 和菜单，保留所有浮层和快捷键，加 IPC）；主窗口：收件箱、条目库、会话、条目详情、审核模式；设置：快捷键、Agent、语音（只做切换和下载）；Rust ASR 替代 `live.py` 的实时转写（Python 版保留作后备）；后台整理迁移进来，运行日志可见；`blurt mcp` v1（只读接口加 `mark_fixed`）；签名、公证、updater；**Win/Linux 保持现有 Tk 录制器加浏览器审核**，新审核页的单文件构建同时给 `review.py` 用 | 5–7 |
| **P2 Windows 对齐** | Rust 采集（WGC + WASAPI + MF 编码，音视频同步对齐 mac 的指标）；WebView 浮层：选区、HUD、鸡舍、气泡（`contentProtected`）；全局快捷键加画笔（低级鼠标钩子加墨迹层）；托盘；NSIS 或 MSI 安装包；Azure Artifact Signing（$9.99/月，限美加和欧英，个人申请有地区限制 [S20]） | 5–6 |
| **P3 Linux** | X11：沿用 ffmpeg x11grab，功能完整；Wayland：portal ScreenCast 加 PipeWire，GlobalShortcuts portal，GNOME 上鸡舍降级；.deb、.rpm、AppImage（Flatpak 以后再说） | 3–4 |
| **P4 深度** | 模型管理完整版（跑分、Qwen3-ASR）；应用内导出（飞书、GitHub、Linear）；ACP 对话面板；Kimi 和 ZCode 适配加深；Rust `blurt` CLI 取代 Python 热路径；浏览器遥测（TODO 里的 console 和 network 对齐） | 6–8 |

合计约 20–27 周，到 Linux 对齐约 14–19 周。MVP（P0 + P1）约 6–8 周。

**安装包体积目标**（不含模型；模型按需下载）：

| 平台 | 格式 | 目标 | 依据 |
|---|---|---|---|
| macOS | universal DMG | ≤ 30 MB（仅 arm64 ≤ 18 MB） | Tauri 空应用约 5 MB [S1]，加 Swift helper（<2 MB）、onnxruntime ×2 ⚠、uv |
| Windows | NSIS .exe | ≤ 25 MB | 空应用约 3 MB [S1]；WebView2 系统自带；MF 编码器系统自带，不带 ffmpeg |
| Linux | .deb / .rpm | ≤ 20 MB | 依赖系统的 WebKitGTK 和 ffmpeg |
| Linux | AppImage | ≤ 90 MB ⚠ | 要打包 WebKitGTK，体积待测 |

**保留什么**：

- Swift：`Recorder`、`Snapper` / `OneShotCapture`、`PickerController`、`HUD`、`InkView`、`Perch`、`NoteBubble`、
  `Eggs`、`LiveAudio`（约 90%）。去掉 `App` 里的菜单栏、工作区菜单、agent 启动和 preflight，这些逻辑迁到 Rust。
- Python：全部保留，是 skill 的工具链。`live.py` 和 `transcribe.py` 在应用内被 Rust 实现替代，但仍然随 skill 发布。
- `review.html` 的交互设计、键位和补丁协议全部保留，用组件化方式重写。
- 文件约定（`live/`、`shots.jsonl`、`items.json` 加 `_user` / `_removed`）一字不改，只加字段。

**主要风险**：

1. macOS 子进程的录屏权限归属（P0 第一天验证；不行就把 Swift 编成静态库，通过 `swift-rs` 链进主进程）。
2. Windows 上 WebView 浮层的「非激活加不被采集」组合体验不如原生（备选方案：浮层用 Rust + Win32 分层窗口）。
3. GNOME Wayland 的置顶限制：产品层面接受降级。
4. 一个人的精力：P2 / P3 可以等 MVP 证明有吸引力之后再投入，Win/Linux 用户在这之前继续用 Tk 版。
5. 各家 agent CLI 变化很快（Codex 的 `--full-auto` 已经移除 [S25]，mcp-server 也在退场 [S26]）：
   所有调用集中在一个 `agents/*.toml` 适配表里，CI 每周跑一次冒烟测试。

---

## 6. 下周先做什么

1. **TCC spike（第 1 天）**：Tauri 空壳加托盘，把现有 `BlurtRecorder` 编成 `Contents/MacOS/blurt-capture` 由主进程拉起，
   录一段视频，确认权限弹窗显示为 Blurt、授权后不用重启。这一项决定 helper 方案能不能成立。
2. **体积实测**：universal DMG（Tauri、helper、uv、sherpa-onnx 静态库）实际多大，写回 §5 的表格。
3. **审核页组件化**：React + Vite 重写 `review.html` 的聚焦模式和列表模式；两种宿主（Tauri 命令 / `review.py`
   的 HTTP 接口）共用一个 `DataSource` 接口；顺带做新的暗色 token。
4. **SQLite 索引原型**：扫描 `~/Blurt` 和绑定项目，做 FTS 搜索，在主窗口三栏里展示真实历史。
5. **`blurt mcp` 最小版**：`list_items`、`get_item`（带图）、`mark_fixed`。在 Claude Code、Codex、Kimi 里各连一次，
   确认图片内容能被看到。
6. **补齐 Kimi 的 headless 闭环**：`kimi --print --output-format stream-json -w <repo>` 加 skill（放在 `~/.claude/skills`
   里它自己就能读到），实测能完成一次后台整理；同时确认用什么办法检测登录状态。
7. 写一页 `docs/design/desktop-ipc.md`：helper 的 JSON-lines 命令和事件表，让 Swift 和 Rust 两边可以并行开工。

---

## 来源

- [S1] Elanis, web-to-desktop framework comparison（空应用基准，GitHub CI，2026-10 更新）https://github.com/Elanis/web-to-desktop-framework-comparison
- [S2] 社区实测对比（Tauri 12–18 MB 对 Electron 201–290 MB，方法未完全公开）https://www.digitalapplied.com/blog/desktop-apps-web-stack-tauri-electron-deno-wails-2026 ；另见 https://hackernoon.com/six-months-with-tauri-the-benefits-and-the-bill
- [S4] Tauri 官方插件列表 https://v2.tauri.app/plugin/
- [S5] Tauri sidecar 文档 https://v2.tauri.app/develop/sidecar/ ；NSIS 替换 sidecar 的问题 https://github.com/tauri-apps/tauri/issues/15134
- [S6] Tauri Linux 图形问题 https://v2.tauri.app/develop/debug/linux-graphics/
- [S7] tauri-nspanel https://github.com/ahkohd/tauri-nspanel ；Apple 论坛上关于非激活浮窗的讨论 https://origin-devforums.apple.com/forums/thread/826308
- [S8] tao 0.32.1 发布说明（修复 macOS content protection 崩溃）https://v2.tauri.app/release/tao/v0.32.1
- [S9] Electron content protection 与 SCK https://github.com/electron/electron/issues/19880 ；https://developer.apple.com/forums/thread/808016
- [S10] Wails releases（v3 beta）https://github.com/wailsapp/wails/releases
- [S11] Compose Desktop 体积和内存（社区）https://slack-chats.kotlinlang.org/t/32833859/hello-i-m-exploring-using-compose-desktop-for-a-project-and- ；Skia 自绘 https://www.infoq.com/news/2021/10/compose-multiplatform-beta
- [S12] windows-capture https://docs.rs/windows-capture ；xcap https://docs.rs/crate/xcap/0.9.8/source/README.md ；scap https://lib.rs/crates/scap
- [S13] Cap（Tauri + Rust 录屏）https://github.com/CapSoftware/Cap
- [S14] GNOME 48 开发者说明（GlobalShortcuts portal）https://release.gnome.org/48/developers/
- [S15] Tauri 快捷键在 Wayland 下不可用：https://pot-app.com/en/docs/wayland.html ；https://github.com/tauri-apps/tauri/discussions/10017
- [S16] GNOME Wayland 无法程序化置顶 https://discourse.gnome.org/t/any-way-to-set-window-always-on-top-programmatically/31579 ；mutter layer-shell https://gitlab.gnome.org/GNOME/mutter/-/issues/973
- [S17] sherpa-onnx Rust crate https://docs.rs/sherpa-onnx
- [S18] SenseVoiceSmall ONNX（int8 241 MB）https://huggingface.co/OpenVoiceOS/sensevoice-small-onnx
- [S19] python-build-standalone https://pydevtools.com/handbook/reference/python-build-standalone/
- [S20] Azure Artifact Signing 价格和地区限制 https://www.devclass.com/security/2026/01/14/code-signing-windows-apps-may-be-easier-and-more-secure-with-new-azure-artifact-service/4079554
- [S21] Claude Code headless https://code.claude.com/docs/en/headless
- [S22] Claude Code 插件清单参考 https://code.claude.com/docs/en/plugins-reference
- [S23] Claude Code deep links https://code.claude.com/docs/en/deep-links
- [S24] Codex skills https://learn.chatgpt.com/docs/build-skills
- [S25] Codex 非交互模式 https://learn.chatgpt.com/docs/non-interactive-mode
- [S26] Codex app-server https://developers.openai.com/codex/app-server ；mcp-server 退场 https://codex.danielvaughan.com/2026/08/28/codex-mcp-server-deprecated-app-server-migration-guide/
- [S27] Kimi Code CLI：开始使用 https://moonshotai.github.io/kimi-cli/en/guides/getting-started.md ；Print 模式 https://moonshotai.github.io/kimi-cli/en/customization/print-mode.md ；Skills https://moonshotai.github.io/kimi-cli/en/customization/skills.md ；命令参考 https://moonshotai.github.io/kimi-cli/en/reference/kimi-command.md ；插件 https://moonshotai.github.io/kimi-cli/en/customization/plugins.md
- [S28] ZCode 官网 https://zcode.z.ai ；第三方集成文档：https://mem.nowledge.co/docs/integrations/zcode ，https://docs.cloudbase.net/en/ai/cloudbase-ai-toolkit/ide-setup/zcode
- [S29] Zed ACP 注册表 https://zed.dev/blog/acp-registry
- [S30] 用链接打开 Claude 桌面版 https://support.claude.com/en/articles/14729294
