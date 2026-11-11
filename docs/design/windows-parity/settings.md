# Windows 设置 / 托盘菜单 / 快捷键 / 应用级时刻对齐 Mac（审计 + 实施记录）

> 2026-11：Agent 会话（终端窗格、交给 Agent 面板、查看改动 / 合并、Claude 桌面端、tmux）已整体删除，`agent-sessions.md` 也删了。下面表里和会话有关的行只是历史记录。

范围：设置（窗口骨架、搜索、九个面板里除 Agents 细节外的每一行）、菜单栏菜单 → 托盘菜单、全局快捷键、开机启动、
应用级时刻（LaunchMessages、BrandMoments、Housekeeping、Updater、Support）。

规格是 Mac 源码：`Settings/SettingsWindow.swift`、`SettingsSearch.swift`、`SettingsKit.swift`、`GeneralPane.swift`、
`DictationPane.swift`、`ScreenTextPane.swift`、`SpeechPane.swift`、`CloudServicesPane.swift`、`ProjectsPane.swift`、
`PrivacyStoragePanes.swift`、`TranslateTargets.swift`，`App/AppDelegate.swift` 的 `menuNeedsUpdate`、`SnapApp.swift` 的
`addSnapMenuItems` / `addWaitingMenuItems`、`Hotkeys.swift`、`HotkeySettings.swift`，BlurtCore 的 `SettingsCatalog.swift`、
`Hotkeys.swift`、`DictationTranslate.swift`。文案一字不改取自 `Resources/{en,zh-Hans}.lproj/{Settings,Dictation,Capture,
Speech,Models,Main,Common}.strings`，放在 `web/apps/desktop/src/locales/settings.{en,zh-Hans}.json` 的 `st.<Mac 的 key>` 下
（生成脚本 `web/apps/desktop/tools/settings_strings.py` 把 ⌘/⌥/⇧ 换成 Ctrl/Alt/Shift、macOS→Windows、Finder→文件资源管理器、钥匙串→Windows 凭据管理器；Mac 专有的句子
逐条改写在 `settings_strings.overrides.json`，`st.win.*` 是 Windows 才有的几句；改了重新跑脚本，不手改输出）。托盘菜单文案在 `apps/desktop/src-tauri/locales/*.json` 的 `tray.*`。

只在两种情况下和 Mac 不一样：Windows 的惯例，或者系统能力 / 后端不同。每一处都写了原因。
「Windows 之前」= 本分支 2026-11-02 的 `SettingsView.tsx` / `DictationSettings.tsx` / `lib.rs tray()`（截图 `before-*.png`）。

处理一栏：**对齐** = 照 Mac 做了；**保留不同** = 有意不同，后面是原因；**做不到** = 缺系统能力或后端，写明缺什么、归谁。

后端：`apps/desktop/src-tauri/src/housekeeping.rs`（启动消息队列、housekeeping、更新、存储、各功能模型、Agents、反馈），`tray.rs`。

## 1. 托盘菜单（Mac 的菜单栏菜单）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 1.1 | 菜单每次打开都重建（`menuNeedsUpdate`） | 启动时建一次，只有「录屏 / 结束录屏」会改字 | 对齐结果，换做法（第五轮）：Windows 不能在菜单要弹出或正弹着时换掉它（换下的 HMENU 被销毁，弹出来是 6 px 的空框）。`tray.rs` 建一次菜单并留着各行的句柄；字、键、计数、勾、下载的「x / y」原地改（muda 改的是正在显示的 HMENU，安全）；只有行的组成变了（空闲 ↔ 录屏、任务来去、项目列表）才建新菜单，而且菜单开着时（`GetGUIThreadInfo` 的 menu mode）等它关了再换。指针移到图标上时刷新一次（原地）；右键按下不再重建 | 已做 |
| 1.2 | 左键点图标就弹菜单 | 左键开窗口，右键菜单 | 保留不同：Windows 托盘惯例是左键开主窗口、右键菜单 | 不变 |
| 1.3 | 空闲时四组：采集动词（开始录屏 · 截图 · 截图取字 · 截图翻译 · 语音备注，各带快捷键）— 等你的（打开口喷鸡 + 计数 · 显示卡片 · 听写历史… · 运行中的任务 ≤5）— 项目（「项目」小标题 + 当前项目子菜单）— 设置… · 检查更新…  — 退出口喷鸡 | 打开 Blurt — 录屏 · 截图 · 语音输入 — 退出 | 对齐：同样的组、顺序和字（`tray.*` 全部取 Mac 原文，zh 用「口喷鸡」）；截图取字 / 截图翻译只在 Windows 版出现（Linux 没有） | 已做 |
| 1.4 | 快捷键显示在行尾，只在它真能用时显示（`showHotkey` / `worksInMenu`），不能用时行下副标题说「⌥R 用不了」 | 无快捷键 | 对齐前半：只在 `hotkeys::rows` 里 `result == ok` 时把 `Alt+Shift+R` 放到行尾。保留不同（后半）：Windows 菜单没有副标题，不能用的键只是不显示，原因在设置 → 快捷键那一行 | 已做 |
| 1.5 | 「打开口喷鸡」：有新事项 / 待验证时打开收件箱，计数做徽章（「9 个新的」）和副标题（「6 个待验证」）；macOS 14.4 以前写进标题「打开口喷鸡 · 9 个新的 · 6 个待验证」 | 「打开 Blurt」，无计数 | 对齐：Windows 菜单没有徽章和副标题，用 Mac 14.4 前的写法放进标题；有计数时打开收件箱（`nav {view: inbox}`），否则只开窗口 | 已做 |
| 1.6 | 按住 ⌥ 时「开始录屏」变成「录制上次的区域」（alternate item） | 无 | 做不到：Windows 菜单没有按修饰键切换的备选项；Windows 录屏的选区框本身提供上次区域 | 不变 |
| 1.7 | 「显示卡片」（有挂着的卡片或 7 天内用过时） | 无 | 对齐：有卡片挂着时出现，点了让岛下的卡片落下（`island::send {op: reveal}`，岛那位给的接口）；同一个动作也是快捷键 `cards`（Alt+Shift+H，Mac 的 ⌥H）。做不到：「7 天内用过」——Windows 没有卡片历史面板 | 已做 |
| 1.8 | 「听写历史…」 | 无 | 对齐：打开主窗口的听写页（`nav {view: dictation}`）；Linux 没有听写，不显示 | 已做 |
| 1.9 | 运行中的任务（≤5 行，「类型 · 标题 · 状态」），点了在主窗口打开 | 无 | 对齐：`jobs::list(true)` 前 5 个，标题 = agent 名或 `job.type.*`（+ 任务标题），状态 = 会话状态词或当前步骤 `job.step.*`，点了 `nav {job}` | 已做 |
| 1.10 | 项目：小标题「项目」+ 当前项目名做子菜单；子菜单：未归类（勾）— 项目（最近用过的在前，≤12，勾当前）— 切换项目…（带键）· 打开文件夹… | 无 | 对齐子菜单内容和顺序；保留不同：Windows 菜单没有小标题，用 Mac 14 前的写法「当前项目：X ▸」。选中项目走 `projects.py use`（未归类 = `auto`） | 已做 |
| 1.11 | 设置… ⌘, | 无 | 对齐：打开主窗口的设置页（`nav {view: settings}`）；保留不同：不标 Ctrl+, 快捷键（托盘菜单里的键只能在菜单开着时用） | 已做 |
| 1.12 | 有更新器时：「检查更新…」，后台找到新版本时「更新到口喷鸡 X…」 | 设置里有按钮 | 对齐：配了更新公钥的构建才显示；后台在启动 20 秒后和每天查一次（`housekeeping.rs`），找到时岛上一行「口喷鸡 X 现已推出 · 更新…」，托盘这一行变成「更新到口喷鸡 X…」，点了直接下载安装并重启 | 已做 |
| 1.13 | 首行提示听写不能用：开启听写…（权限）/ 设置听写…（语音组件没下）/ 下载语音模型…（没模型） | 无 | 对齐「下载语音模型…」（`READY == false` 且听写开着时，点了打开设置 → 模型）。保留不同：Windows 不需要辅助功能 / 输入监控权限，没有「开启听写…」；「设置听写…」（uv 没装好）由欢迎页处理 | 已做 |
| 1.14 | 模型下载中：「正在下载语音模型 · 412 MB / 950 MB」+ 子菜单「查看 / 停止」 | 无 | 对齐：标题、「查看」、「停止」（`model_download_cancel`）；每条进度只原地改子菜单的标题 | 已做 |
| 1.15 | skill 和 App 契约不一致时一行警告 + 如何更新 | 无 | 对齐：读 skill 的 `_common.py` 里 `CONTRACT = n`，和 App 的 1 比；不一致时托盘首行「口喷鸡 skill 比 App 旧/新」，点了：App 旧且能更新 → 设置 → 通用并检查更新，否则打开指南的「更新」一节；设置 → 通用的关于行上方也说 | 已做 |
| 1.16 | 录屏中：完成录屏 · 只保存视频 · 暂停/继续 · 重新录屏 · 丢弃录屏 — 截图 · 实时字幕（勾） | 打开 · 结束录屏 · 截图 · 语音 · 退出 | 对齐：完成录屏 · 只保存视频 · 暂停/继续 · 重新录屏 · 丢弃录屏 — 截图 · 实时字幕（勾）— 退出；后三项由录屏那位接（`recording.md`），字和顺序已核对与 Mac 一致 | 已做 |
| 1.17 | 选区时：「正在选择区域…」（灰） | 无 | 对齐（`capture.state().picking`） | 已做 |
| 1.18 | 每行都有 SF Symbol | 无 | 保留不同：Windows 托盘菜单惯例不带图标；带图标要给每行做位图，勾选项在 Win32 菜单里和图标抢同一列 | 不变 |
| 1.19 | 图标：静止时 Peep 单色模板，录屏时红点 + 计时，有待办时旁边数字 | 单色 Peep；提示文字带待办数 | 对齐模板图标「总是看得清」：黑 / 白 Peep 跟任务栏的主题走（`SystemUsesLightTheme`，不是应用主题——Windows 10 默认深色任务栏 + 浅色应用），主窗口 ThemeChanged 时和每 3 秒读一次注册表（只改任务栏颜色时应用收不到通知）。录屏时对齐 Mac 的菜单栏：红色录制点（`record-fill`，token `rec`），暂停时注意色的暂停符（`pause-fill`，token `attn`），按任务栏深浅各一张（`import_peep.py --only tray` 生成 `tray-{rec,paused}-{light,dark}.png`），结束后回到 Peep。保留不同：Windows 托盘图标旁不能放文字，Mac 图标旁的计时放进提示文字（「正在录屏 · 1:23」「录屏已暂停 · 1:23」，每秒更新），待办计数也在提示文字里 | 已做 |

## 2. 设置骨架和搜索

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 2.1 | 独立的设置窗口（⌘,） | 主窗口里的一页，顶部 6 个标签 | 保留不同：设置留在主窗口里（Windows 11 的应用都这样），托盘「设置…」直接开到这页；页内其余全照 Mac。第五轮：设置显示时主窗口的侧栏让开（Mac 的两栏，不是三栏），设置导航顶上一行「‹ 返回」回到原来的位置 | 已做 |
| 2.2 | 左侧栏：搜索框在顶，下面三组 — 偏好：通用、听写、截图取字、模型、快捷键 · 工作：项目、Agent · 本机：隐私、存储 | 标签：通用、听写、云端、快捷键、Agents、语音 | 对齐：同样三组九页、同样顺序、同样图标含义；「This Mac」→「This PC」（zh 仍是「本机」）；「云端」并入「模型」（Mac 的 speech.services）；Linux 没有听写和截图取字两页 | 已做 |
| 2.3 | 页：标题是面板名，最宽 680，分节开放（标题加粗、行间细线），行 = 标题 + 一行说明 / 右侧一个控件，弹出框同宽 180（翻译目标 240），开关用品牌色，长说明在 ⓘ 里 | 表格 + 复选框 | 对齐：`settings/kit.tsx` + `settings.css` 按 SettingsMetrics 的数（gutter 28、行距 10、说明 12 px、分节间距 26–30） | 已做 |
| 2.4 | 搜索：标题、说明、关键词（中英两种语言都搜）、分节；按面板分组、最佳在前；输入面板名（「short」「快捷」）或只匹配面板关键词（「hotkey」）时整个面板命中并领头；Restore Defaults 只按自己的词找到；侧栏显示每页命中数、没命中的变灰；结果行说明为什么命中（UI 语言）；没结果时提示 + 常用搜索 + 清除搜索 | 无 | 对齐：`settings/catalog.ts` 逐行移植 `SettingsCatalog.results / score / reason / excerpt`，条目只列 Windows 真有的行；`settings.test.ts` 覆盖 | 已做 |
| 2.5 | ⌘F 聚焦搜索、Esc 清空、↑↓ 走结果、↩ 打开（打开后滚到那一行并用品牌色闪一下） | 无 | 对齐：Ctrl+F（Windows 惯例）、Esc、↑↓、Enter；`requestFlash` 滚动 + 闪 | 已做 |
| 2.6 | 打开时：链接指名的面板 / 行，否则上次的面板（`app.settings_pane`）；不认识的面板名开通用；搬走的面板（export）去新地方 | 总是通用 | 对齐（`MOVED` 加了 Windows 旧的 `cloud` → 模型） | 已做 |
| 2.7 | ⌘, 打开时光标在搜索框 | — | 对齐 | 已做 |
| 2.8 | `blurt://settings/<pane>[/<row>]` 打开到那一页那一行 | 不认 | 对齐（`lib.rs handle_url` → `nav {view: settings, pane}`） | 已做 |

## 3. 各面板

### 通用

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.1 | 应用：登录时打开口喷鸡（开关，「听写和快捷键需在口喷鸡运行时使用。」；失败时说去系统设置改） | 复选框，在路径下面 | 对齐；失败时说去「Windows 设置 > 应用 > 启动」；Windows 用 HKCU Run（`onboarding.rs`） | 已做 |
| 3.2 | 语言（跟随系统 / English / 简体中文，分隔线），改了说「下次打开口喷鸡时生效」+ 现在重新打开 | 下拉 | 对齐选项；保留不同：Windows 版改语言立刻生效（主窗口、岛、托盘菜单都重读），不需要重开 | 已做 |
| 3.3 | — | 两个系统通知开关（整理好了 / Agent 需要你） | 保留不同：Windows 用系统通知提醒（Mac 在岛上说），两行放在「应用」里，ⓘ 说「仅在口喷鸡不在前台时通知，且不发出声音」 | 已做 |
| 3.4 | 录屏：录完之后（整理成事项 / 只保存视频）、倒计时（无 / 3 / 5 秒）、录制系统声音、录屏时不录刘海 | 无 | 对齐（第三轮，录屏那位的后端已读这些键）：「录屏」一节三行，Mac 的字和默认（`record.process` auto / off，`record.countdown` 0/3/5 默认 3，`record.system_audio` 默认关）；做不到：刘海（Windows 没有） | 已做 |
| 3.5 | 语音备注：结束方式（再按一次快捷键 / 停顿 1.5 秒后）、实时显示识别文字 | 无 | 对齐（`record.voice.end_on_pause`、`record.live_text`，Windows 后端都读）；「刘海下方」改成「屏幕顶部」 | 已做 |
| 3.6 | 卡片：把 macOS 截图添加为卡片、截图快门声、把卡片拖进 App（先图后备注 / 印备注 / 只图片）、附上备注 Markdown | 无 | 对齐：四行都在（`record.collect_system_shots` / `snap_sound` / `smart_paste`+`drag_caption`+`drag_copy_note` 一个选择 / `drag_note_file`，后端是岛那位的 `island.rs`）。按 Windows 改写：「Windows 截图」= 存到「图片\屏幕截图」的截图；「先放图片，再贴备注」在 Windows 是复制备注、Ctrl+V 贴，不需要辅助功能权限（那句提醒去掉）；Linux 不显示 | 已做 |
| 3.7 | 关于：一行「口喷鸡 1.0.6 · 检查更新… · 使用指南 · 设置助手…」，契约不一致时上面一行警告 | 版本、检查更新按钮、设置助手按钮、各种路径、tmux | 对齐：同一行同样四项（检查更新只在配了更新时出现，结果跟在后面）；路径 / tmux 搬到 存储 → App 数据（Mac 也在那里） | 已做 |
| 3.8 | — | Linux：关闭 WebKit DMA-BUF | 保留不同（Linux 才有），搬到 存储 → App 数据 | 已做 |

### 听写

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.9 | 在任意 App 里听写（开关 + 说明） | 复选框 | 对齐（视觉门 r1 改正）：Mac 关掉后各行原地变灰（`.disabled(!enabled)`），不是收起。Windows 现在也原地变灰（`st-set off`，`inert`），开关下加一句「打开后，在任意 App 里按右 Alt 听写。」；变灰的是只在听写时起作用的行（键、开始结束、麦克风……、风格、按 App 类型、参考光标文字、学新词、翻译目标），历史、保留录音、词库「管理…」、翻译模型、模型仍可用 | 已做 |
| 3.10 | 快捷键：Fn / 右 Option / 任一 Option（+ Fn 的「不让 macOS 抢 Fn」） | 右 Alt / 任一 Alt | 对齐：右 Alt / 任一 Alt 键，任一时说「仅单独按下时触发，不影响 Alt 组合键」；听写那位改成了实时生效，不再提示重开。保留不同：没有 Fn（Windows 读不到 Fn） | 已做 |
| 3.11 | 开始和结束（按一下或按住 / 按一下开始再按一下结束 / 按住说话），说明里带键名 | 下拉 + 提示 | 对齐（`dictation.mode.*.detail`，键名用 `dictation.key.*.inline`） | 已做 |
| 3.12 | Esc / 取消键、按两下发送、结构化 / 翻译键单击或双击 | 无 | 对齐：取消听写（Esc / Ctrl+Esc / Shift+Esc）、按两下发送、结构化 / 翻译键（双击 / 单击；Shift = 结构化，Ctrl = 翻译），写 `record.dictation.cancel_key` / `double_tap_send` / `modifier_tap`（听写那位的 `prefs.rs` 读） | 已做 |
| 3.13 | 麦克风选择、只听我的声音（声纹） | 无 | 对齐麦克风：系统默认输入（带设备名）+ 各输入设备（`dictation_mics`），写 `record.dictation.mic`；保留不同：没有 Mac 的「自动（避开蓝牙）」。对齐「只识别我的声音」（第三轮）：开关 + 有声音档案时旁边「声音档案」菜单（重新录制… / 删除声音档案）；没档案时打开开关 = 弹出「录制你的声音」（同一段朗读文字，Mac 改成 PC；麦克风电平进度条，读够 12 秒语音自动结束、≥6 秒且停顿 2.5 秒也结束、1 分钟封顶、8 秒没人说话就算太短；开始录音 / 完成 / 取消；模型没下时边读边下）。后端 `housekeeping.rs` `voiceprint_*`：用听写的麦克风（`dictation::mic`，`record.dictation.mic`）录 16 kHz WAV 到临时目录 → `transcribe.py voiceprint enroll`（CLI，可能下 ~28 MB 模型）→ 删 WAV、开 `record.dictation.only_my_voice`；状态 / 删除优先走常驻语音服务（`vp_status` / `vp_clear`），不在时走 CLI；档案没了就关掉开关（Mac 同）。过程用 `voiceprint://changed` 事件 | 已做；**录音部分未在 Windows 验证**（cfg(windows)，本机 macOS 无法交叉编译 Windows 目标） |
| 3.14 | 开始时提示音、结束时提示音（两个开关） | 一个开关 | 对齐：两行，`sounds`（开）和 `stop_sound`（关），Mac 的字 | 已做 |
| 3.15 | 风格：原话 / 轻整理 / 结构化 / 自动，下面一行说明；按 App 类型、建议清单、学风格、润色超时 | 「用云端模型润色」复选框 | 对齐：风格四选一（原话 = `polish: off`，其余写 `styles.default`）；按 App 类型：摘要一行 + 「管理…」展开聊天 / 代码和终端 / 邮件 / 笔记和文档 / 其他 App 五行（每行「跟随默认」或某风格）和单独设置过的 App（恢复默认）。第三轮：同一展开里加「像清单时提示整理成清单」（`suggest_lists`）、「为每个 App 记住结构化和翻译」（`learn_styles`，engine.rs 早就读）、「润色等待上限」（− / +，1–10 秒步长 0.5，说明里带改写键）。保留不同：润色上限默认 4 秒（Windows 云端润色的底数，Mac 本机模型是 3 秒）；`engine.rs` 改为读 `polish_timeout_ms` 替换这个底数（一行，听写那位的文件） | 已做 |
| 3.16 | 词库（读上下文、学新词） | 无 | 对齐：词库一行（已添加 N 个 · N 个待确认）+ 「管理…」展开：词条（移除）、待确认（添加 / 忽略）、添加框（`dictation_words` / `dictation_words_edit`）；「参考光标附近的文字」（`context`）和「从我的改正中学习」（`learn`，听写那位的 engine.rs 读）两个开关。保留不同：Mac 把这两个放在「管理」按钮的菜单里，Windows 是两行 | 已做 |
| 3.17 | 翻译：「双击 ⌘ 翻译成」（自动：中文 ↔ English / 各语言自称），翻译模型 + 更改… | 「翻译成」下拉（值用 zh-Hans） | 对齐：「双击 Ctrl 翻译成」，值改成 Mac 的（`zh`，旧的 `zh-Hans` 照样认）；「自动」写成 Windows 后端真正的方向「简体中文 ↔ English」；翻译模型行 + 「更改…」跳到 模型 → 翻译 | 已做 |
| 3.18 | 历史：「已存 N 条 · 30 天后删除」，菜单里保留天数（7/30/90/365）和清空历史… | 无 | 对齐：天数下拉 + 「清空历史…」（确认框）；保留不同：没有「打开历史…」主按钮（Windows 的历史就在主窗口侧栏「听写」） | 已做 |
| 3.19 | 保留录音开关 | 无 | 对齐：`keep_audio`，说明带保留天数 | 已做 |
| 3.20 | 模型：一行说正在用的模型 / 没下载 / 下载中 +「在『模型』里更换…」 | 模型列表和下载在这一页 | 对齐：只留一行 + 链接，下载搬到 模型 页（Mac：只有一个地方下载） | 已做 |
| 3.21 | 高级：听写测试台 | 无 | 做不到：Windows 没有测试台 | 不变 |

### 截图取字

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.22 | 复制（⌥C）：精确识别开关（第二遍模型读） | 无 | 对齐（视觉门 r1）：「模型 → 截图取字」已经能设云端视觉模型，所以截图取字面板补回「取字（Alt+Shift+C）→ 精确识别」一行，和模型页那行是同一个设置（`record.cloud.jobs.vision`）；翻译模型显示名字（DeepSeek V4.1 Flash），不显示 API id | 已做 |
| 3.23 | 翻译（⌥T）：「⌥T 翻译成」——自己的目标，不跟听写共用；翻译模型 + 更改… | 截图翻译用听写的目标 | 对齐：`record.screen_text.translate.target`（和 Mac 同一个键），标题里的键是用户真实的键（「Alt+Shift+T 翻译成」）；`screen_text/flow.rs` 改读这个键，固定语言发 `X|keep`（Mac 同） | 已做 |

### 模型

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.24 | 本机：推荐的下载（只在缺时出现），一个主按钮下载，下载中变进度条 | 听写页的提示框 | 对齐 | 已做 |
| 3.25 | 云端模型：每个已连接的服务一行（DeepSeek 标推荐，已连接 / 未设置 Key）+ 编辑…；还有能加的服务时「添加云端模型…」（空时说明 + 主按钮）；表单是一张 sheet：服务、Key（存钥匙串）、测试后才保存 | 「云端」标签页里的表单 | 对齐：同样的行、同样的 sheet，Key 存 Windows 凭据管理器。第三轮：sheet 里加「豆包语音（火山引擎）」（Mac 的 VolcengineSpeech：只在系统语言是中文或地区是中国时出现；App ID + Access Token 两栏，测试 = `transcribe.py check-cloud --model-id volcengine-seedasr`，两项走 stdin，通过后存成一项）。存法和 Mac 一致：preset / id `volcengine-speech`，凭据管理器目标 `Blurt Cloud Polish/volcengine-speech`，值 `<App ID>:<Access Token>`；`cloud.rs speech_env` 认 `volcengine-speech`（也认听写那位用过的 `volcengine`），给语音服务 `VOLC_APP_ID` / `VOLC_ACCESS_TOKEN`，连上后让常驻语音服务重启。保留不同：「编辑…」换成「移除」；做不到：地区、自定义模型。11-11：模型 → 听写可选百炼的实测语音模型（Qwen3-ASR Flash、Qwen Audio 3.1 ASR，`asr.cloud["qwen3-asr-flash"].model`，和 Mac 同一个设置）；没 Key 的云端识别写「· 需添加 Key」，选了打开只含语音服务的 sheet（windows-models.md §Cloud recognition on a weak PC） | 已做 |
| 3.26 | 各功能使用的模型：录屏 / 实时字幕 / 语音备注 / 听写 / 听写润色 / 翻译 / 截图取字，各一行带图标，右边是模型（自动或手选） | 只有听写模型单选 | 对齐：录屏、语音备注（自动 = `transcribe.py auto --apply`；手选写 `asr.models.<purpose>` 并关 `asr.auto`，自动时说明「现在：X」）、听写、听写润色、翻译、截图取字（第三轮：云端视觉模型，`record.cloud.jobs.vision`，没设时说「让截图取字（Alt+C）更准」）——自动，或已连接服务的实测模型；没 Key 的服务写「· 需添加 Key」，选了打开添加 sheet。下载中的模型旁有「停止」（`model_download_cancel`：结束下载进程树，清掉 `$BLURT_HOME/models` 下的 .part / .incomplete / 临时压缩包，发 `stopped` 不算失败）。做不到：实时字幕（归录屏那位） | 已做 |
| 3.27 | 语言、高级（线程、并发、内存、电池、镜像、云端语音 Key） | 无 | 做不到：Windows 后端没有这些设置（镜像由安装器按地区定，见 windows-models.md） | 不变 |
| 3.28 | 全部模型：「管理模型…」打开模型库 sheet（准确率、速度、内存、大小，下载 / 实测 / 删除） | 「语音」标签页的只读表 | 保留不同：Windows 只有两个听写模型，直接列在「全部模型」里（大小、推荐、已在本机 / 下载）；做不到：实测、删除（没有后端） | 部分 |
| 3.29 | 对比…（听写选项对比 sheet） | 无 | 做不到：没有测评数据 | 不变 |

### 快捷键

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.30 | 四节：截图、录屏和备注（录屏 · 截图 · 截图取字 · 截图翻译 · 语音备注）· 录屏时（暂停 · 画笔 · 完成）· 听写（开始听写 = 听写键，在听写设置中更改… · 改写上一条）· 打开与切换（切换项目 · 显示卡片 · 打开菜单栏菜单 · 打开口喷鸡窗口） | 一张表，顺序不同，还有「标记」 | 对齐分节、顺序、名字（`capture.action.*`）、截图取字 / 截图翻译 / 改写的说明行；去掉「标记」（Mac 1.0.7 起没有）。第三轮：「改写上一条听写」（`reformat`，Alt+Shift+L，听写那位接的后端）和「打开或关闭画笔」（`pen`，Alt+Shift+D，录屏那位加回）回到各自一节；画笔行的 ⓘ 说 Windows 只有锁定用法（打开后拖动画，Shift 方框、Alt 椭圆，Esc 放下；recording.md §4.6），Mac 那行的第二行（按住键）没有 | 已做 |
| 3.31 | 画笔、显示卡片、改写上一条 | 画笔显示「不可用」 | 做不到：Windows 没有画笔、卡片面板、改写 | 不变 |
| 3.32 | 打开菜单栏菜单（⌥B）+ 打开口喷鸡窗口（默认关） | 「打开 Blurt」（menu） | 保留不同：Windows 不能用键弹出托盘菜单，`menu` 动作就是打开窗口，用 Mac「打开口喷鸡窗口」的名字，默认 Alt+Shift+B | 已做 |
| 3.33 | 默认修饰键 ⌥（1.0.5 起） | Alt+Shift | 保留不同：Windows 应用的 Alt+字母是菜单访问键（Alt+F 文件菜单），全局占用会弄坏所有应用；保持 Alt+Shift | 不变 |
| 3.34 | 记录框：点了「按下新的快捷键…」，Esc 取消，⌫ 删除；冲突时「与「X」重复」→ 问「与 X 互换？它改用 ⌥A」（或「把 ⌥R 从 X 移过来？」），互换 / 取消；系统快捷键、被占用各一句；恢复默认 | 有记录框，冲突只报错 | 对齐：同样的文案和互换 / 移过来（先清自己、再给对方、再设自己）；「与 macOS 系统快捷键冲突」→「与 Windows 快捷键冲突：截图工具」；恢复默认按钮在页底。第五轮：记录框录键时口喷鸡自己的全局快捷键全部让开（`shortcuts_suspend`，Mac 的 `Hotkeys.shared.suspended`），否则按下别的动作占着的键会直接触发那个动作，互换永远问不出来；记录框失焦、主窗口失去焦点或一分钟后自动恢复。恢复默认一次写完（`shortcuts_reset` 删掉 `record.hotkeys`，Mac 的 `restoreDefaults()`）——逐个设会被互换过的那一对互相判成重复。清掉的键（⌫）也写进状态行。做不到：⌘Z 撤销互换 / 恢复 | 已做 |

### 项目

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.35 | 项目文件夹：每个项目一行（文件夹图标、名字、路径；右键：在访达中显示 / 重命名 / 新截图归到这里 / 移除），添加项目文件夹…，在访达中显示未归类，说明「每个项目对应一个文件夹…」 | 无 | 对齐：行 + 在文件资源管理器中显示 + 新截图归到这里 + 当前项目标记、添加项目文件夹…、显示未归类、说明；保留不同：重命名 / 移除在主窗口侧栏的项目菜单里（主窗口那位），这里不重复 | 已做 |
| 3.36 | 截图和语音备注：新的归到（未归类 / 各项目） | 无 | 对齐（`projects_use`） | 已做 |

### Agent

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.37 | Agents 列表（顺序、状态、登录、修复）、整理用的模型、会话设置（保留会话、项目默认 agent、交接目标）、手动 agent、让你的 agent 发送事项 | 顺序表 | 对齐（协调人改派给本区，`AgentsSettings.tsx` 整页移植）：首行 + 再检查一次；每个 agent 一行（状态记号、名字、使用中、状态短语 + 版本 + ⓘ、修复按钮，开关），拖动排序或 ⋯ 菜单 / 右键，没装的折成一行；整理；会话（保留会话：Windows 没有 tmux，关且灰；当前项目的默认 agent；第三轮：「交给 Claude Code 时」——口喷鸡终端（推荐）/ Claude 桌面端，写 `sessions.target.<agent>`，和交接面板的「运行于」同一个键；桌面端没装时灰掉，ⓘ 说为什么）；其他 agent App；「让你的 agent」+ 示例…；详细信息 sheet；连接 sheet。新命令 `agents_registry` / `agents_install` / `agents_test` | 已做 |

### 隐私 / 存储

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.41 | 「交给 Agent 设置…」（agent-setup.md：复制一段指令给任意 agent，它通过 App 的控制 socket 连服务、选模型、跑测试听写；或在 Blurt 终端里开一个设置会话；实时进度列表、允许 / 停止） | 无 | 对齐（第三轮）。端点：`control.rs`，本机 TCP `127.0.0.1:<随机端口>`，运行文件 `$BLURT_HOME/run/control.json` `{pid, port, token, protocol}`（每次启动新 token，退出时删），每个请求带 `auth`（常量时间比较）——代替 Mac 的 unix socket + getpeereid；会话 token（2 小时）/ 允许窗口（30 分钟，第一次改设置时岛上问「允许…设置模型？」3 分钟不答算拒绝）和 Mac 同；操作 hello / status / connect / test / use / download / verify（verify 用 Windows 自带 System.Speech 念一句 16 kHz WAV，过语音服务 + 润色，≥0.6 算通过）。`setup.py`：Windows（或没有 unix socket 但有运行文件时）读运行文件走 TCP；connect 也收豆包语音（`app_id` + `access_token`）；状态里列出云端识别（Qwen3-ASR Flash、豆包语音）可选为听写。UI（模型 → 云端模型）：「添加云端模型」行里「交给 Agent 设置…」（服务都加完时它单独一行；没有能跑会话的 agent 时不出现）；sheet：说明、可选中的指令（指南和 setup.py 的真实路径）、Agent 能做什么的一句、「在终端中打开」（已装的能开会话的 agent）、取消 / 复制指令；下面的实时列表：「正在用 X 设置」+ 显示终端 / 停止（结束后「完成」），每步一行（转圈 / ✓ / ✗，Mac 的字），每完成一步重读本页的行 | 已做；**未在 Windows 验证**（端点、System.Speech 朗读、终端会话） |
| 3.38 | 隐私页首行承诺；权限：屏幕录制、麦克风、辅助功能、输入监控、Fn 键，各带状态和允许… | 无 | 对齐首行（按 Windows 真实情况改写：本机识别，文字只在连了云端模型时发出去）和「麦克风」一行（设备、已允许 / 在 Windows 设置中关闭、Windows 设置…）；保留不同：Windows 不需要另外几项权限 | 已做 |
| 3.39 | 数据：语音识别只在本机、转写后保留麦克风音频、在 Spotlight 中显示事项 | 无 | 做不到：Windows 没有云端语音识别、实时字幕音频、Windows 搜索索引 | 不变 |
| 3.40 | 存储：录屏（各文件夹大小、自动删除旧视频）、模型（大小）、App 数据（各文件夹大小、清理） | 路径在通用页 | 对齐（`StorageSettings.tsx` + `storage_scan`）：首行总大小 + 右边「X 可用」（第三轮：口喷鸡所在磁盘的剩余空间——Windows 用 PowerShell 的 .NET DriveInfo，不加 Win32 特性；Linux `df -Pk`）；录屏（全部录屏和截图、可删的视频——按 30/90/180 天或全部、「自动删除视频」）；模型；App 数据（⋯ 菜单：在文件资源管理器中显示 / 删除）+ 设置文件、脚本、uv 路径。删除进回收站，并给会话的 meta.json 写 `mode: video` / `video_removed`。保留不同：Mac 的岛上「撤销」→ Windows 用回收站还原 | 已做 |

## 4. 快捷键（全局）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 4.1 | Carbon 注册，不要权限；常驻：录屏、菜单、窗口、语音、项目、卡片、改写、取字、翻译；录屏时才注册：暂停、画笔、完成 | 插件注册；常驻 + 录屏时（含标记、画笔） | 对齐常驻 / 录屏时的分法；删 marker；加 `cards`（Alt+Shift+H）；`reformat`（Alt+Shift+L，常驻）和 `pen`（Alt+Shift+D，录屏时）由听写 / 录屏那位加回，设置页各有一行 | 已做 |
| 4.2 | 被另一个口喷鸡占用时说是哪个、可「退出另一个口喷鸡」 | 单实例插件：第二个直接把第一个叫到前台 | 保留不同：Windows 版只会有一个实例（single-instance），没有「另一个副本」 | 不变 |
| 4.3 | 菜单里的键只在能用时显示 | — | 对齐（§1.4） | 已做 |

## 5. 开机启动

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 5.1 | SMAppService 登录项；登录时启动不开窗口 | HKCU Run；登录启动只留托盘 | 保留不同（Windows 的登录项就是 HKCU Run）；行为一致 | 不变 |

## 6. 应用级时刻

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 6.1 | LaunchMessages：启动 3 秒内想说话的只说最重要的一条，90 秒内再来的丢掉 | 各自直接发 | 对齐：`housekeeping.rs` 的队列（同样的等级：模型建议 < 任务 < 项目 < 权限 < 快捷键 < 欢迎 < 模型下载 < skill < 配置；`still_true` / `shown`），岛上的一行（`launch.*` 字串在 overlays 的词表里），按钮的 `app.*` 动作经 `island.rs on_action` 加的一行转来 | 已做 |
| 6.2 | Housekeeping：启动时契约检查、迁移、gc、`transcribe.py auto --apply`、删过期拖出的截图和旧视频、常驻 `sessions.py monitor` | `setup.rs`、`watcher::initial_scan`（迁移、gc）、`sessions::start_monitor` | 对齐其余：契约检查；上次没跑完的 App 任务标成失败；v0.6 带过来的当前项目问一次；旧视频按设置每天删；语音模型建议；启动时有快捷键用不了说一句 + 更改…。第三轮：拖出去被别的 App 拿走的卡片（岛那位写 `{"n","taken"}`，卡片面板的历史留 7 天）满 7 天进回收站——图、标注图、语音、`out/<NNN>/`，再追加 `{"n","deleted":true}`（Mac 的 expireTaken）；启动时一次、之后每小时；测试运行（`BLURT_TEST_COMMANDS`）只写标记不动文件 | 已做 |
| 6.3 | Updater（Sparkle）：每天检查，找到时岛上一行 + 菜单「更新到 X…」 | 设置里手动检查 | 对齐（§1.12），代码不再改。源：Mac 的 Sparkle 读 GitHub 最新 release 的 appcast.xml，Windows 读同一个 release 里的 `latest.json`；大陆（`setup::mirror()` 开着时）先试 blurt.work，否则先试 GitHub。**发布流程还需要**：① 一对 Tauri 更新签名密钥——私钥（`TAURI_SIGNING_PRIVATE_KEY` + 密码）放进发布机 / CI 的密钥里，公钥写进 `tauri.conf.json` 的 `plugins.updater.pubkey`（没有公钥时整个更新不出现）；② 每个 release 上传安装包、它的 `.sig` 和 `latest.json`（`createUpdaterArtifacts`）；③ 大陆能下载的安装包地址：`latest.json` 只能写一个 url，GitHub 在大陆常下不动，所以安装包要再放一份到大陆能到的地方（R2 不能用：没绑卡；可用 blurt.work 所在的 Cloudflare Pages / 国内对象存储），blurt.work 上那份 `latest.json` 指向它，GitHub 那份指 GitHub | 已做（发布待配） |
| 6.4 | Support：使用指南链接；反馈（听写页的「发送反馈…」：选听写、是否带光标附近文字、上传 zip，给报告号） | 无 | 对齐：关于行「使用指南」；「发送反馈…」在听写页标题旁（`FeedbackSheet.tsx`，`feedback_send` → `feedback.py send`），同样的勾选、上限 100 MB、说明去哪、报告号可复制、错误句 | 已做 |
| 6.5 | BrandMoments：品牌主按钮、引导页光晕 | — | 不在本区：设置页的主按钮都用 `.primary`（品牌渐变），一页最多一个 | 已做 |

## 截图

`/private/tmp/claude-501/-Users-john-workspace-bug-agent/4f91d789-8387-4d85-8d1b-8414dcbffbf8/scratchpad/parity/settings/`：
`before-{general,dictation,cloud,shortcuts,agents,speech}.png`，`after-{general,general-zh,general-dark,dictation,dictation-zh,screentext,
speech,cloud-sheet,shortcuts,shortcuts-swap,shortcuts-bottom,projects,agents,privacy,storage}.png`，
`after-search-{short,mic,zh,none}.png`；第二轮：`after2-{general,dictation,models,storage,agents,agents-bottom,agent-details,agent-connect,feedback}.png`。截图用一个临时页（只渲染设置页，主窗口的侧栏当时正在别人手里改，整页跑不起来；用完已删）。
第三轮（整页 mock，`?platform=win`）：`after3-{general-recording,dictation-voice-styles,voiceprint-sheet,dictation-advanced,models-agent-progress-vision,agent-setup-sheet,volcengine-sheet,shortcuts-pen-reformat,agents-handoff-zh,storage-zh,storage-lead-zh}.jpg/.png`。
托盘菜单在 Mac 上看不到 Windows 的样子，没截。

## 第四轮（11-02 创始人：「截图取字」的图标和 Mac 不一致）

- 侧栏 9 个面板的图标全部对上 Mac 的 SF Symbols（通用 齿轮、听写 字 + 光标、截图取字 取景框里的文字、模型 芯片、隐私 举起的手、
  存储 硬盘），设置里各行的图标也一样，逐条见 `icons.md`；`tests/test_icons.py` 守着面板这一张。
- 文本框的焦点：Windows 上是 Fluent 的强调色下划线（2px，在框内，不挪位置），不再是 3px 光晕 + 设置搜索框自己再加的 2px 描边。

## 第五轮（11-02 Windows 试用：`promo/cases/dogfood-win-2026-11-02/shell/`，修后截图在 `fixed/`）

- **启动不再卡死**：`hotkeys::apply` 只在主线程跑（别的线程调用时交给主线程并等结果），所以两次 apply 不会交错，插件的
  register / unregister（它们把活交给主线程做）也不会等自己；任何 Hotkeys 锁都不跨插件调用或 emit 持有（`transient` 同样）。
  托盘的刷新一律另起线程算、再交主线程改，监听器里永远不会同步重建菜单。每个动作都有状态行（含 off），设置里清掉的键不再
  残留、重启后那一行也不会消失。
- **托盘菜单**：见 §1.1。行尾的键 Windows 上写进文字（`文字\tAlt+Shift+R`），和设置里一样的顺序（muda 会把加速键重排成
  Shift+Alt+R，托盘菜单的加速键本来也不起作用）。刷新是「尾沿」合并：一阵事件只算一次，最后一次永远会落地（以前 400 ms
  内的会被丢掉，停止下载后菜单可能一直停在下载中）。
- **主窗口的位置大小**：存逻辑尺寸 + 当时的缩放；恢复时按目标屏的缩放换算，不小于 960×520，不大于工作区，整个窗口拉回
  工作区里（100 % 存的 937×558 在 150 % 下不再低于最小值，2560 屏存的也不再比 1920 屏大）；屏幕小于最小值时最大化。
- **欢迎页就是窗口**：和 Mac 的设置助手一样，显示时主窗口变成它的大小（880×600，逻辑像素，放不下时按工作区缩小），不能
  拉伸，结束后回到用户自己的窗口（`mainwin.rs welcome_frame`；首次启动在建窗口时就设好，不会先大后小）。整页只有步骤内容
  一个滚动区。标题用品牌渐变字，当前步骤的点是 16×6 的胶囊。听写那一步直接选键（右 Alt / 任一 Alt），模型下载有「停止」，
  行尾不再重复状态、大小只显示一个；「添加…」打开设置里同一个添加云端模型的面板；「在设置里修改快捷键…」可以点。
  `blurt://onboarding` 重新打开它。
- **其余**：Ctrl+W 关窗口（缺 `core:window:allow-close`）；`blurt://record` / `snap` 链接不再把主窗口叫到前面（单实例回调
  只在没有链接时开窗口）；主窗口标题跟界面语言（口喷鸡 / Blurt）；WebView2 自己的刷新 / 查找 / 打印键关掉，浮层不弹浏览器
  的「返回 / 刷新」菜单，主窗口只在文本框和选中的文字上留着它；配置写入和 skill 一样在 `$BLURT_HOME/.config.lock` 下
  读改写，config.json 解析不了时不覆盖（`settings::update`）；`settings_strings.py` 换键名改成 Ctrl+Z、Ctrl+Enter、
  Alt+Shift+C（口喷鸡自己的键）、路径分隔统一成 →；键帽用界面字体；安装包用应用图标。
- **安装包**（第五轮补）：图标用应用图标；欢迎 / 完成页左侧 164×314 和内页页眉 150×57 两张图由
  `assets/brand/import_peep.py --only installer` 从 Peep 包生成（DMG 窗口的做法：#F2F2F2、薄荷光、点阵、品牌渐变星，
  加设置助手里的黏土 Peep）；`installer/hooks.nsh`（`installerHooks`）去掉页底那行（NSIS 把 copyright「MIT」印在那里，
  Mac 的 DMG 没有这行），界面字体改成 Segoe UI / Microsoft YaHei UI（简体中文默认宋体，欢迎 / 完成页 12pt 粗体标题是点阵字）。
- **托盘录屏状态**、**uv 下载进度条**（「正在安装语音工具」下面一条进度和「6 / 21 MB」，`setup.rs` 先 HEAD 拿大小，下载时
  每 0.5 秒看文件长度）、**听写图标中文是「字」**（`assets/icons/character-cursor-zh.svg`，`@blurt/icons` 在
  `<html lang="zh-*">` 时自动换，和 SF Symbols 的 character.cursor.ibeam 一样按语言换字）：第五轮补齐。
- **要你定**：版本号（0.7.0 vs Mac 1.0.11）和 productName（开始菜单、安装器里叫 Blurt）。

## 视觉门 r1（11-03，`promo/cases/visual-gate-win-2026-11-02/` 听写区的设置页）

- **一个控件宽度**：听写面板的弹出菜单都是 180 px（麦克风、翻译目标原来 240），长名字省略、悬停看全名；弹出列表是应用自己的
  菜单（kit.tsx 的 Popup，不再是 WebView 的 `<select>`：暗色下白底白字）。
- **行尾动作两种**：去别处的用描边按钮（词库「管理…」、翻译模型「更改…」、模型「更换… / 下载…」）；原地展开的用整行 +
  旋转的箭头（按 App 类型，Mac 的 showByApp），不再用「管理…」文字链接展开、「收起」收回。
- **按 App 类型展开**：内容放进一个缩进的浅底块（说明一句 → 五类 → 两个开关 → 润色等待上限 → 一行按键说明）；各类的值
  默认写「跟随默认（轻整理）」；润色等待上限改成弹出菜单（1–10 秒），说明写它管什么（原来误用了按键说明）；原话风格下不显示。
- **历史**：一个控件——保留天数的菜单最后一项（分隔线下）是「清空历史…」，不再有常驻的破坏性按钮（Mac 的 historyRow 菜单）；
  确认框和听写页同一个（居中、写明条数和录音、两个等宽按钮、取消是默认）。
- **缺语音模型**：面板顶部一行提醒（⚠ + 缺哪个 + 下载…），最后一行「模型」写「Fun-ASR-Nano (CPU) · 未下载」（主语在前）。
- **词库**一行的「N 个待确认」用提醒色。
- **Only my voice 的朗读框**：居中、620 宽、朗读文字 15 px、状态行始终占位、隐私说明用淡色；打开前把焦点从开关上拿走。
- **模型页**：每个功能一行同一个写法——下拉框只写「自动」或模型名，说明写「做什么 · 当前：模型」（不再截断「自动 · DeepSee…」）；
  听写那行没模型时下拉框仍在（「未设置」）并用提醒色说去上面下载；下载中的行：按钮的位置换成 180 px 进度块 + 同尺寸「停止」；
  下载失败写在那一行（⚠ 没下载完 · 请检查网络 + 重试），不再是列表底下一句；已在本机 = ✓ + 字；「推荐」只标没下载的。
  标题用句首大写（Models by feature、This PC）。
- **添加云端模型**：先一句说用途和 Key 存哪；表单是一列右对齐的标签 + 等宽控件；「获取 DeepSeek 的 API Key」放在 Key 框下面。
- 所有面板 `.st-page` 预留滚动条位置，切换面板时内容列不再左右跳。
- 仍不同：云端服务一行仍是「移除」（Mac 是「编辑…」，没有编辑 sheet）；「用 Agent 设置…」位置不变。

## 视觉门 r2（11-03，听写 / 截图取字 / 模型三页逐行对 Mac）

- **一个菜单样式**：「声音档案 ▾」（只识别我的声音）和「交给 Agent 设置」sheet 里的「在终端中打开 ▾」改用应用自己的菜单
  （`Menu.tsx`，和 kit 的 Popup 同一个），不再是手写的 `.st-menu` 和 WebView 的 `<select>`（暗色下白底）。菜单开着时 Esc 只关菜单。
- **弹出菜单宽度**：都是固定宽度；两个「翻译成」都是 240 px（Mac 的 `TranslateTargets.popupWidth`，「自动：简体中文 ⇄ English」
  不再被截断），其余 180 px。r1 写的「翻译目标改成 180」作废。
- **模型名，不是 API id**：`modelName()` 按 Mac 的 `CuratedModels.option(job, on: service, model:)` 找名字——先找这个功能、这个服务的
  条目，再找别的功能 / 服务里同一个模型；只有 Blurt 没测过的模型才显示 id（Mac 的自定义模型也是）。听写页、截图取字页、模型页每处
  「当前：…」「… · 云端」都走它；别处（Agent 设置）选的、不在实测列表里的模型仍出现在下拉框里（按名字），不会显示成「自动」。
- **没有语音模型**：听写页顶部的提醒保留；模型页「本机」那行在本机一个语音模型都没有时改说「听写需要语音模型：X 还没有下载。」
  （提醒色 ⚠，旁边就是唯一的「下载」）。模型页「听写」一行和「全部模型」里下载失败的行原来有两个 ⚠，现在一个。
- **截图取字自己的快捷键**：「取字（Alt+Shift+C）」一节的标题和「翻译（…）」一样读用户真实的键（`hk('text')`，
  `settings.screen_text.section.copy` 改成带 `{1}`，overrides 里同步）。
- **对齐 Mac 的 ⓘ**：「开始和结束」说取消键和语音备注的键（`dictation.mode.help`），「按两下发送」说先停再发（`double_tap.help`）。
- **听写页「模型」一行**：风格不是「原话」时，名字后面加上润色模型（「SenseVoice Small · DeepSeek V4.1 Flash（云端）」，Mac 的 modelNames）。
- 浏览器 mock：`?models=0`（本机没有语音模型）、`?cloud=1`（已连 DeepSeek，润色走 `deepseek-flash`），curated 加了 vision。
- 仍不同（不变）：精确识别是下拉框（Mac 是开关 + 更改…：Windows 没有本机视觉模型，选云端模型就是打开它）；按 App 翻译的列表、
  听写测试台、Mac 的麦克风「自动（避开蓝牙）」。

## 视觉门 r1（11-03，shell 区：托盘、欢迎、设置骨架、快捷键、搜索、Agent、项目、隐私、存储）

**托盘（tray.rs、import_peep.py）**
- **图标按真实尺寸画**：`import_peep.py --only tray` 按 Mac 菜单栏模板（`glyph/peep-glyph.svg` 的比例）画 16 / 20 / 24 / 32 px
  四个尺寸，边缘落在整像素上：眼睛是透明方孔（16 px 3×3，20 / 24 px 4×4，32 px 5 px 圆），16 / 20 px 的嘴是一整块楔形
  （缝只有半个像素），24 / 32 px 才分上下两片。黑白两色用同一个 alpha 生成（包里的白色标记把眼睛填死了，深色任务栏上只剩一个
  白团）。`tray.rs` 按 `GetSystemMetrics(SM_CXSMICON)`（100/125/150/200 % → 16/20/24/32）选一张，DPI 变了也重选；64 px 的
  留给 Linux。录屏红点 / 暂停条同样按尺寸画（点 10/12/14/18 px，暂停条在点的框里，两根宽度是偶数所以在整像素上），直通 alpha，
  深色任务栏上没有暗边。
- **菜单从任务栏上方弹出**（1.x 新增「保留不同」→ 对齐 Windows 11）：tray-icon 自带的弹出点在指针处、底边对齐，菜单压在任务栏上，
  盖住口喷鸡自己的图标和时钟。现在右键由 Blurt 自己 `TrackPopupMenuEx`：底边在任务栏上沿往上 8 px，以图标为中心，排除图标矩形
  （任务栏在上 / 左 / 右时对应翻转）；菜单仍是 tray-icon 的窗口所有，选中照常走 muda。
- **录屏中的菜单**（改 1.16）：第一行灰色「正在录屏 · 1:23」/「录屏已暂停 · 1:23」（Mac 菜单栏旁的计时，菜单打开时提示文字
  看不到；每秒原地更新，1.17「正在选择区域…」是先例）；然后 完成 · 只保存视频 · 暂停/继续 · 重新录屏 — 丢弃录屏单独一组 — 截图 ·
  实时字幕。**录屏中不再有「退出」**，和 Mac 一样（退出会悄悄完成这次录屏，是第四种结束方式）。
- **快捷键只放在采集动词上**（改 1.4）：打开口喷鸡、显示卡片、切换项目不再带键——托盘菜单打开时快捷键不起作用，全部键在
  设置 → 快捷键里；右边那列安静下来。
- **显示卡片带数量**（改 1.5）：「显示卡片 · 7」，和「打开口喷鸡 · 计数」一样写进标题（Mac 的徽章）。
- **项目**（改 1.10）：对齐 Mac——灰色小标题「项目」，下一行是项目名 ▸；子菜单里「未归类」和各项目是同一组勾选（中间不再有分隔线），
  然后 切换项目…（不带键）· 打开文件夹…。
- **下载中**（改 1.14）：标题短成「语音模型 · 164 / 716 MB」（两个数用总数的单位，跳数时宽度不变，菜单保持空闲时的宽度）；子菜单第一行灰色
  「正在下载 · 23%」，然后「查看下载」「停止下载」（说清楚对象）。欢迎页开着时「查看下载」回到欢迎页（那里正显示进度），否则去设置 → 模型。
- 仍不同：Windows 菜单没有图标列（1.18）；「下载语音模型…」没有加粗（muda 不能设默认项）；菜单圆角取决于系统（RDP / 无 GPU 下是方角）。

**欢迎（Welcome.tsx、styles.css、mainwin.rs、App.tsx）**
- 图标格改成中性底 + 次要色图标（品牌色只留给标题、步骤点和「下一步」）；键帽是无边框的浅底小块；「在设置里修改快捷键…」是品牌色链接，
  和图标列对齐；行高 62 px。Peep 的光不再漏到右边。
- 第 2 步按 Mac 的行：听写键（弹出菜单是应用自己的菜单，暗色下不再白底白字，选项带一句说明）— 「试一下听写键」一行，行尾
  「等待中」→ ✓「已检测到」（去掉虚线框）— 句首大写的「权限」— 麦克风写用途，设备名在状态的提示里 — 一行说明 Windows 上输入和截屏不需要其他权限。
  **这一步按听写键只是检测**：窗口有焦点时 App.tsx 看到 `[data-key-probe]` 就不转发，不会开始听写，岛也不会压在标题上。副标题只说检测到的东西。
- 第 3 步一个列表：听写一行的行尾是状态（✓ 已就绪 / 「下载（950 MB）」按钮 / 转圈 + 百分比），下载时下面一条整宽进度条 + 同尺寸「停止」；
  去掉「云端」小标题；「之后可在设置里更改」贴在底部。**底栏永远是 跳过设置 · 上一步 · 下一步**（不再有「以后再说」+ 下载顶替下一步）。
  大小只有一个来源：进度的总数取 max(下载总数, 按钮上的大小)，不会从 950 跳到 716。
- 第 4 步：练习框一个焦点提示（去掉里面的 Fluent 下划线），框撑满到登录那行上面；听的时候提示变成「正在听…再按一下右 Alt 结束」；成功后
  ✓「听写已就绪。」+ 缩进的发送提示，框回到中性边；没模型时是实心浅底卡片、中间琥珀色 ⚠、中性标题，主按钮「下载（950 MB）」和第 3 步同一个字。
  「开机时打开」那行贴底，下面只留一句「关闭窗口后口喷鸡仍在托盘里」（去掉那串快捷键）。开机启动默认开：Windows 上听写键要口喷鸡在运行（3.1）。
- 欢迎窗口和首次打开的主窗口居中后再往下挪到岛下面（48 px），岛不再压在窗口标题栏上。

**设置骨架（settings.css、kit.tsx、base.css）**
- 内容列贴着侧栏（40 px），不再在宽窗口里居中；`.st-page` 留滚动条位置。
- 所有弹出菜单（kit.tsx `Popup`）改用应用自己的 Menu：跟主题、圆角、当前项打勾，可带一句说明；不再用 WebView 的 `<select>`。
- Windows 上滚动条只画滑块（base.css 的 `::-webkit-scrollbar`）：`scrollbar-width: thin` 在 Chromium 里会画上下箭头且让 webkit 规则失效。
- 搜索框获得焦点时是安静的边框，不再是品牌色下划线；去掉 WebView 自带的粗 ✕。
- 通用页底部的关于行上面一条细线，「使用指南」「设置助手…」是链接样式。

**快捷键（SettingsView.tsx）**
- 每个快捷键是键帽（一键一块），静止时没有框，悬停才有底色；录制时 2 px 品牌色边 + 浅色底 +「按下新的快捷键…」+ 末尾 Esc 键帽，按住的修饰键实时显示。
- 冲突问「与『开始录屏』互换？它改用 Alt+Shift+A。」用次要色，后面跟两个文字按钮「互换」「取消」（Enter / Esc），输入框里显示刚按下的键（浅色底）；
  不再是两个按钮挤在行尾、橙色字。
- Windows 保留的键：输入框里划掉显示刚按的键 2.5 秒，说明写「Win+E 是 Windows 的『文件资源管理器』，加上 Alt 或 Ctrl 再试」，
  应用名本地化（`st.win.keys.app.*`）。去掉每个输入框的 title 提示；用法说明挪到页面标题下，「恢复默认」单独在底部。
- 听写键那行也用键帽，「在听写里更改…」放在说明行。

**搜索结果**：开头的总数 = 侧栏各面板计数之和；每组标题右边有数量；结果一行一个、细线分隔、匹配的字加粗；快捷键用键帽，听写那条显示右 Alt；
不再插入「采集 / 录屏时」小标题，组名等于面板名时不重复；「再显示 N 项」带箭头；只有一条结果时不显示键位提示。没有结果：标题保留查询词，
左边放大镜，「没有结果」+ 提示 + 常用搜索（品牌色链接）+ 真正的「清除搜索」按钮。

**Agent**：未安装那行写「Codex、Kimi Code、OpenCode 等 6 个」，不再省略号截断；拖动把手放进行首的状态列；行尾 ⋯ 的菜单挂在按钮下面右对齐；
只有一个已安装的 Agent 时不显示上移 / 下移。Windows 上「退出后会话继续运行」不再是灰掉的开关 + 橙色说明，而是一行中性的「退出口喷鸡时，会话随之结束」
（原因在 ⓘ）。交接只有一个去处时显示文字，不是灰掉的下拉框；「（推荐）」放进菜单。「重新检查」用次要色。示例改成锚在「示例…」上的浮层：
放不下时往上开、离窗口边 12 px、有小箭头、点外面 / Esc 关闭、整行点击复制（悬停才显示复制图标）。详情 sheet 加宽到 700，模型列 240 px，不再截断。
「接入技能和 MCP…」统一叫法。

**项目**：行上不再常驻「在文件资源管理器中显示」和「发送新截图到这里」，悬停出 ⋯（右键同一个菜单）；标题那行的「显示未归类」收进 ⋯；
去掉「当前」徽章（下面的「新截图存到」就是这个设置）；路径缩短为「…\code\acme-web」，全路径在提示里。

**隐私**：开头一句后面两个链接（模型… · 文件存在哪里…）；麦克风一行写「设备 · 用来听你说话」，行尾 ✓「已允许」，关着时才有「Windows 设置…」。

**存储**：设置文件 / 技能脚本 / uv 三行各有自己的图标，「在文件资源管理器中显示」收进 ⋯；uv 叫「Python 运行器（uv）」。

**Agent 设置模型的询问（control.rs、AgentSetupAsk.tsx）**：从 Windows 的浅色 MessageBox 改成主窗口里和「清空历史」同一个确认框（跟主题、居中、
应用图标 + 问题做标题）。默认焦点在「不允许」，**回车和 Esc 都是不允许**，只有点击「允许」才允许（Mac：回车不能允许；原来回车会授权 30 分钟）。
超时 Rust 关掉它，晚到的点击不算数。页面没加载时退回系统对话框。

**没做 / 交给别人**：设置 → 听写 / 模型 / 截图取字、发送反馈 sheet、清空历史确认框由听写区在改（同一批文件），这一轮没碰。
**还没在 Windows 上重拍**：测试 VM（101.37.190.224）11-03 00:00 自动释放了。
