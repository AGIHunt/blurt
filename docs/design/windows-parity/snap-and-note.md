# Windows 截图与备注气泡对齐 Mac（审计 + 实施记录）

范围：截图（Alt+Shift+A）从选区到卡片的整条路：区域选择器、选完之后定格在原地的画面和画笔、紧贴画面的备注气泡（说话 / 打字 /
选项目 / 选类型 / Tab / ↩ / Esc）、备注的语音、关掉之后这张截图去哪。顺带：同一个选择器在录屏和「复制屏幕文字 / 翻译」里的样子，
Copy Text / Translate 的结果。
不含：灵动岛本身和挂着的卡片（卡片的拖出、Recently Taken、SmartPaste、卡片菜单），独立的语音备注（Alt+Shift+V），录屏引擎。

规格是 Mac 源码：`Capture/Snap.swift`、`Captures.swift`（Snapper.pick / capture / present / retarget / discard）、
`NoteBubble.swift`、`InkStage.swift`、`InkView.swift`（InkCanvas）、`KindChip.swift`、`ProjectChip.swift`、`Picker.swift`、
`Loupe.swift`、`ScreenTextCopy.swift`、`ScreenTextCard.swift`，BlurtCore 的 `NoteKeys`、`NoteKind`、`Ink.swift`（InkStroke /
InkFit / InkStyle / InkHint / BubbleDock）、`CaptureRules.swift`（NoteEsc / NoteTyping / LastArea）、`CaptureEdits.swift`
（NoteEdit）、`Projects/Assignment.swift`（ProjectPick），文案取 `Resources/{en,zh-Hans}.lproj/Capture.strings`。

只在两种情况下和 Mac 不一样：Windows 自己的惯例（Ctrl / Alt / Shift 而不是 ⌘ / ⌥ / ⇧，Win 11 窗口圆角 8，任务栏代替菜单栏），
或者系统能力不同。每一处都写了原因。

「Windows 之前」= 2026-11-02 创始人试用的版本：选区 → 截图 → 灵动岛下面弹一个「这张图想说什么？直接打字」的框（图的缩略图 +
文本框 + 跳过 / 保存），只能打字。

## 1. 截图之后：定格画面 + 画笔（InkStage）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 1.1 | 松手即截：画面定格在原处 1:1，屏幕其余部分保持选择器的 42 % 暗色；选择器的暗色一直留到定格画面出来，不闪 | 选择器关掉，图片缩成缩略图放进灵动岛下的气泡 | 对齐 | 已对齐：选择器松手后冻结（只剩暗色和线），舞台窗口画好（`ready`）才关掉它；截图同时在后台拍（舞台和所有浮层一样不进截图） |
| 1.2 | 定格画面的边：选择器那条 2 pt 实线（Island.selection），画在画面外；画面下有看得见的投影（黑 55 %、24 pt、下移 8） | 无 | 对齐 | 已对齐（`.hole`：2 px `--selection` 线 + 黑 55 % 24 px 投影） |
| 1.3 | 画笔直接画在定格画面上：拖动 = 手绘，⇧ 拖 = 方框，⌥ 拖 = 椭圆；修饰键每次移动都重读；手绘末尾停 0.5 s 吸附成直线 / 方框 / 椭圆（InkFit） | 无画笔 | 对齐（逻辑照搬 InkStroke / InkFit）；键是 Shift / Alt（Windows 惯例） | 已对齐：`notecore.ts` InkStroke / inkFit 逐行移植，测试照搬 InkTests |
| 1.4 | 笔：markup 色，圆头，柔和暗影；线宽 InkStyle（屏幕短边 / 260，3–6 pt） | 无 | 对齐 | 已对齐（`--markup`，阴影，`inkWidth`） |
| 1.5 | ⌘Z 撤销最后一笔（最后做的是画画，或文本框是空的）；悬停气泡时脚栏出现撤销箭头 | 无 | 对齐，Ctrl+Z | 已对齐：Ctrl+Z；悬停时脚栏出撤销箭头 |
| 1.6 | 画面上方一条淡提示「Drag to draw · ⇧ box · ⌥ ellipse · Esc discards」，只前 3 次（record.ink_hint_shown），第一笔或 6 s 后消失 | 无 | 对齐，文案换成 Shift / Alt | 已对齐：record.ink_hint_shown 计数（Rust），文案换 Shift / Alt |
| 1.7 | 点暗处（画面外）= 完成（保存） | 无 | 对齐 | 已对齐 |
| 1.8 | 笔迹烧进 shots/NNN.marked.png（复制 / 拖出用它），NNN.png 保持原样，strokes 存进 shots.jsonl 可再编辑 | 无 | 对齐（Rust 里画，规则同 renderMarked） | 已对齐：Rust `capture/snap.rs` ink::burn（中点二次曲线、单点画环、阴影），png 写出；strokes / marked 进 shots.jsonl |
| 1.9 | 完成后标记过的图从选区飞到刘海变成卡片；丢弃时只淡出 | 卡片从灵动岛下方飞入 | 对齐 | 已对齐：舞台立刻淡出；卡片带 `from`（选区换算成灵动岛页面坐标，`island::screen_to_css`）从截图的地方飞起 |

## 2. 备注气泡（NoteBubble，新截图 = listen 模式）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 2.1 | 气泡贴在定格画面旁边，从不盖住它：右边，放不下左边，再下面、上面；整屏选区才放在里面右下角（BubbleDock）；尖角指向画面 | 灵动岛下方居中，尖角朝上 | 对齐 | 已对齐：`dock()` = BubbleDock（CSS 坐标），尖角朝画面；用工作区（不含任务栏） |
| 2.2 | 一打开就听（用户松开鼠标时往往已经开口）；暖着的语音服务，不冷启动模型 | 不听，只能打字 | 对齐：Blurt 自己的麦克风 + 暖着的语音服务（和听写、语音备注同一条路），按停顿切段，每段识别完立刻显示 | 已对齐：`dictation/snap_voice.rs`（cfg(windows)）——mic.rs + segmenter + engine::recognise，模型由 server::ensure 先暖 |
| 2.3 | 不会自己结束：没有停顿结束、没有倒计时；20 s 什么都没说麦克风停（气泡留着，只能打字），最长 120 s | — | 对齐 | 已对齐：20 s 没说话停（画画时顺延 1.5 s）、120 s 停、麦克风断开停；不会因停顿结束 |
| 2.4 | 说的话实时出现在文本框的位置，灰色（已定的次要色，还在说的部分更淡） | — | 对齐；Windows 是按段出字（每段说完一停就出），没有 Mac 那种每秒一次的中间结果 | 保持差异，原因是 CPU：Windows 上语音模型跑在 CPU 上（没有 Mac 的 Metal），每秒把正在说的那段整段再解一次会让一次截图备注占满一个核、拖慢之后每段出字；所以按段出字——说完一停（约 0.5 s）那段就出来。**2026-11-02 dogfood 后**：第一段最长 3 s（不停顿地说，约 3 s 就有第一批灰字；之前 8 s 才有，看着像没在听），之后每段最长 8 s；还没出字时状态栏显示计时，不再先显示「Tab 采用识别结果」（VM 实测：首批灰字从 ~8 s 提前到 ~3–4 s，`promo/cases/dogfood-win-2026-11-02/capture/fixed/after-grey-words-*.png`） |
| 2.5 | 字段 15 pt，是气泡里最显眼的；左边 16 pt 的字形列：听的时候三根电平条（静时低呼吸，有声升起），停了有话 = 波形，键盘接管 = 键盘，听不了 = mic.slash | 「这张图想说什么？直接打字」文本框 + 缩略图 | 对齐 | 已对齐：三根电平条（呼吸 / 随声）、波形、键盘、划掉的麦克风 |
| 2.6 | 占位文字：Speak or type… / Add a note (optional) / Mic unavailable. Type a note / Mic disconnected. Type a note / A voice note is recording. Type a note here | What’s this about? Just type. | 对齐，用 Mac 原文 | 已对齐 |
| 2.7 | 脚栏固定格子：项目 chip · 类型 chip · 悬停工具（撤销笔迹、垃圾桶）· 状态槽（右对齐：计时「0:04」，灰字时「Tab accept · type to replace」，「Saved」）· 主按钮「Done ↩」 | 提示行「↩ 保存 · ⇧↩ 换行 · Esc 跳过」+ 跳过 + 保存 | 对齐 | 已对齐；宽度一开始就按「chip + 类型 + 垃圾桶 + 键提示 + Done」算好，上限 470（Segoe UI 比 SF 宽约 6 %，Mac 是 440） |
| 2.8 | ↩ / Done：提交——打的字、原样的灰字（录音留下，卡片稍后拿到最终识别结果）、或什么都没有（照样留下这张截图） | ↩ 保存文字 | 对齐 | 已对齐（逐条跑过：灰字 ↩ = 留录音、等最终字） |
| 2.9 | ⇧↩ 换行（⌃↩ / ⌥↩ 也是）；灰字时先采用再换行；新截图空框时什么都不做 | ⇧↩ 换行 | 对齐（Shift+Enter；Ctrl+Enter / Alt+Enter 同） | 已对齐 |
| 2.10 | Tab：采用灰字（变黑进框，停止听，光标在末尾，之后键盘接管）；没灰字时打开项目列表 | 无 | 对齐 | 已对齐（Tab → `note.mic` 停止并保留 → Rust 识别完发 `words`，框里替换成最终字） |
| 2.11 | 灰字时打字 = 替换：麦克风停，录音先放一边（删空又显示灰字，↩ 保留它们；有字 ↩ 则丢掉录音）；还没说话就打字 = 打字备注（麦克风停，什么都不留） | 无 | 对齐；只算提交了的字（输入法组字不算） | 已对齐（输入法组字不算打字） |
| 2.12 | Esc（NoteEsc）：先清掉打的字；再按一次丢弃这张截图（「Snap discarded · Undo」5 s） | Esc = 跳过（截图照样留下，没备注） | 对齐；撤销走灵动岛的提示按钮 | 已对齐：第二次 Esc 写 `deleted`，灵动岛「Snap discarded · Undo」5 s（island.rs 加了 `snap.undo`） |
| 2.13 | 采用后的最终字：框里仍以采用的字开头时用最终识别结果替换（后面打的保留，光标跟着）；改过就以框为准（NoteEdit） | — | 对齐 | 已对齐（`takenNote` = NoteEdit.apply） |
| 2.14 | 「Saved」：说出来的备注提交时，勾（ok 色）+「Saved」停 0.45 s 再淡出；打字的直接走 | 无 | 对齐 | 已对齐（勾用 `--ok`，0.45 s 后淡出，Rust 延迟关窗） |
| 2.15 | 关闭只有：↩、Done、Esc、⌥A（下一张）、点画面外、切到别的应用后 3 s（麦克风停，说过的保留） | 失焦不管 | 对齐：窗口失焦 3 s 后保存 | 已对齐：窗口失焦 3 s 后保存 |
| 2.16 | ⌥A 在气泡打开时：保存当前的，接着截下一张 | 第二次按无效（忙） | 对齐（Alt+Shift+A） | 已对齐：Rust 给打开的气泡发 `commit`，等它关上再开选择器 |
| 2.17 | ⌥V 语音备注正在听：气泡只能打字（不开第二个麦克风） | — | 对齐 | 已对齐（`voice::active()` → busy） |
| 2.18 | 听写正在听：气泡不抢麦克风，只能打字 | — | 对齐 | 已对齐（`voice::dictation_busy()` → 不开麦克风） |
| 2.19 | 麦克风中途断开：没说过话 = 气泡留着「Mic disconnected · type a note」；说过 = 以已有的结束 | — | 对齐 | 已对齐（1.5 s 没有音频 = 断开） |
| 2.20 | 每次打开有代数，旧气泡的淡出不会关掉新开的 | — | 对齐（新的窗口替换旧的；页面内按代数忽略迟到消息） | 已对齐：每个气泡有代数 `g`，旧的 mic / 字的消息页面不认 |
| 2.21 | 外观随系统浅色 / 深色：深色 #2C2C2C 不透明 + 白 14 % 细线；浅色近白 + 黑 12 % 细线 + 窗口投影；圆角 14，卡片和尖角一条轮廓 | 永远深色玻璃 | 对齐 | 已对齐：`prefers-color-scheme` 两套表面；卡片 + 尖角一条 SVG 路径；投影用 drop-shadow |
| 2.22 | 气泡出现：弹簧放大 0.92→1；Reduce Motion 只淡入 | pop 动画 | 对齐 | 已对齐 |
| 2.23 | 前几次（InkHint 次数）项目列表下显示它的键「↑↓ choose · ↩ pick · Esc back」 | — | 对齐 | 已对齐（和舞台提示同一个「前 3 次」） |

## 3. 项目 chip 和类型 chip

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.1 | 项目 chip：项目的彩色文件夹 + 名字，或虚线圈 + Unassigned；静止次要色，悬停 / 打开全色 + 淡底；弹出菜单的上下箭头 | 无（截图去当前项目，改不了） | 对齐 | 已对齐（2026-11-02）：项目颜色和岛的切换器同一个算法（`web/apps/overlays/src/projectlook.ts`，FNV-1a → Mac 的 8 个颜色），chip 和列表都画彩色文件夹（文件夹主体 28 % 填充）；找不到文件夹的仍是灰色 |
| 3.2 | 列表在气泡里 chip 下方展开：过滤框（放大镜）、最多 6 个最近项目、Unassigned 在最后（细线隔开，附「stays as a card」）；输入过滤（键完全相同 > 名字开头 > 词开头 > 键开头 > 包含）；↑↓ ↩ Esc；光标开在当前的位置 | 无 | 对齐（ProjectPick 规则照搬） | 已对齐（`placeChoices` / `filterPlaces` = ProjectPick，测试照搬） |
| 3.3 | 选了别的项目：只这张截图改去那里（retarget），灵动岛的当前项目不变；文件夹找不到的项目：问号文件夹、暗名、「folder not found」，选了就留作卡片 | 无 | 对齐 | 已对齐：选别的项目写 `{"n","project","assigned_by":"capture"}`，选未归类写 project null；找不到文件夹的项目选了 = 留作卡片 |
| 3.4 | 类型 chip：未设置 =「Type」+ 次要色标签图标；设了 = 种类图标（种类色）+ 名字 | 无 | 对齐 | 已对齐（种类色从 tokens.json 生成进浮层主题：build.py 加了 `--kind-*` 和 `--selection`） |
| 3.5 | 类型列表：问题 / 想法 / 笔记 / 待办，细线下「Not set · decided when organized」；每行右侧显示键 ⌘1–⌘4 / ⌘0；↑↓ ↩，Esc / Tab 回到备注，打字继续进备注（列表收起） | 无 | 对齐，键是 Ctrl+1–4 / Ctrl+0 | 已对齐 |
| 3.6 | ⌘1–⌘4 / ⌘0 在气泡里任何时候都能设类型；存进 shots.jsonl `kind` | 无 | 对齐，Ctrl+数字 | 已对齐，`kind` 写进 shots.jsonl |

## 4. 关闭之后：这张截图去哪（Snapper.settled / discard）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 4.1 | 有项目 → 直接归档进去（captures.py，没有 agent），没备注也归；没项目 → 挂成卡片；岛上一行「已归入 X · KEY-12 · 更改」 | 等 8 s 合并后起一次 agent 整理（花 token，几分钟后才有事项，岛上什么都不说） | 对齐（2026-11-02 dogfood 后改）：`capture::file_now` 立刻跑 `captures.py file`（不起 agent、0 token），照样记一个 process job（带 `filed: true`，结束时不再弹「已整理」）；成功后岛上「已归入 X · AS-1 · 更改」，「更改」= 岛的项目选择器 → `items.py move`（只移还在原项目里的）→「已移到 Y · 撤销」；项目文件夹不在 → 留作卡片 +「找不到 X 的文件夹 · 卡片已保留 · 找到…」；captures.py 失败 → 留作卡片 + 一行说明。同一条路也用于：岛上把卡片拖到项目 / 未归类、Edit Note 里改项目、有当前项目时的语音备注和撤销回来的截图。去掉了 8 s 合并（COALESCE） | 已做；VM 实测：回车后 ~1 s 内岛上出现「已归入 api-server · AS-1 · 更改」，`C:\work\api-server\.blurt\items` 里已有 AS-1（`fixed/after-filed-*.png`） |
| 4.2 | 说出来的备注：wav 存 shots/NNN.wav，`voice` + `said` 写进同一行；有项目时等字到了再归档 | 无语音 | 对齐 | 已对齐：wav 写 shots/NNN.wav，`voice` + `said` 一行写入；卡片 / 整理在字到了之后才开始 |
| 4.3 | 丢弃：`{"n","deleted":true}`，文件进废纸篓，5 s 内可撤销 | 「跳过」= 照样留下 | 对齐 | 已对齐：写 `deleted` 行，灵动岛 Undo 5 s；撤销窗口（6 s）过了文件才进回收站（SHFileOperationW + FOF_ALLOWUNDO，可从回收站还原；Linux 用 `gio trash`）——和 Mac 卡片删除「撤销期间文件不动」同一做法。**2026-11-02**：丢弃不再等语音识别——先写 `deleted` 行、立刻出「截图已丢弃 · 撤销」并刷新卡片，说过的话在自己的线程里识别完再写进那一行（撤销还能带回来），回收站那步等它写完；`NoteMic::finish(keep=false)` 立刻返回，监听线程收到 Stop(false) 就不再识别剩下的段（打字盖掉灰字后保存也不再等）。VM 实测：两次 Esc 后 0.2 s 就有撤销行（之前 ~4 s）。项目仓里改成未归类的卡片重启后找不回：已修（`load_cards` 也扫项目仓的 -shots 批次里 project 为 null 的行；island.rs `session_of` 接受项目仓） |

## 5. 区域选择器（Picker.swift，截图模式）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 5.1 | 截图模式：拖完松手立刻截（像 ⌘⇧4），不出工具栏 | 拖完出工具栏，要点「截图」或按 ↩ | 对齐 | 已对齐 |
| 5.2 | 单击 = 指针下的窗口（悬停时窗口高亮：薄荷色 10 % 底 + 2 pt 线，窗口自己的圆角；前几次中间写「Click to snap this window」）；点到桌面什么都不做 | 单击 = 整个屏幕 | 对齐：Windows 上用 Rust 列出可见的顶层窗口（cfg(windows)）；圆角 8（Win 11） | 已对齐：`visible_windows()`（EnumWindows，去掉自己的、最小化的、cloaked、工具窗口、桌面和任务栏，取 DWM 可见边框）；Linux 没有窗口列表 → 单击仍是整屏 |
| 5.3 | 没选区时的暗色 22 %，悬停窗口 / 有选区时 42 % | 38 % | 对齐 | 已对齐 |
| 5.4 | 提示在屏幕底部居中（悬停窗口挡住时挪到顶部）：模式图标 + 一句话 + 键帽 [F] Full screen [L] Last area [esc] Cancel；键帽只前几次，之后只剩 [esc] Cancel；? 切换 | 屏幕 42 % 高处的一行字「拖动选择截图区域 · 单击 = 全屏 · Esc 取消」 | 对齐，Mac 原文 | 已对齐（图例次数记在 record.hints.picker） |
| 5.5 | 键：Esc 取消（有选区时 ⇧Esc 清掉选区）、↩ / 空格确认、F 全屏、L 上次区域、? 图例、方向键挪 1 pt（⇧ 10） | Esc、↩ | 对齐 | 已对齐 |
| 5.6 | 选区：一条 2 pt 实线（Island.selection），画在区域外；8 个把手（9 pt 圆角方块，白 1.5 环，阴影）；拖把手改大小，拖里面移动（来自窗口 / F / L 的选区拖动 = 重画）；双击里面确认 | 渐变虚线、拖动时滚动；无把手 | 对齐 | 已对齐 |
| 5.7 | 尺寸：玻璃小药丸「W × H」（物理像素），在选区左上方，没地方就放里面 | 薄荷色药丸 | 对齐 | 已对齐 |
| 5.8 | 工具栏（录屏模式，或有选区未松手提交时）：选区下方居中：Cancel esc · Full screen F · Last area L ｜ Snap ↩ / Start recording ↩（渐变，带图标） | Last Area · Whole Screen · Cancel · Capture ↩，右对齐 | 对齐，Mac 原文 | 已对齐（录屏选择器一起改了：同一个页面） |
| 5.9 | 放大镜：打开时把每块屏定格一张，指针附近 8× 放大，像素格 + 十字，下面标尺寸 | 无 | 对齐 | 已对齐：选择器打开前 Rust 把这块屏截一张（`monitor_still`，BMP 进临时目录，选择器不在里面），页面里 120 px、8× 最近邻、中间像素框 + 十字（`--selection`）、白边；只在帮着对边时出现（不在工具栏旁，有选区时只在边附近或拖动时）；复制文字的拖动下面标尺寸 |
| 5.10 | 没有屏幕录制权限 → 不开选择器，说明怎么开 | — | 保留差异（Windows 没有这个权限） | 保留差异 |

## 6. 复制屏幕文字 / 翻译的选择器和结果

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 6.1 | ⌥C / ⌥T：只有十字光标，一拖一放，不暗屏、不点窗口、没有工具栏；拖的区域薄荷 10 % 底 + 2 pt 线 | 和截图一样的暗屏 + 工具栏 + 确认 | 对齐 | 已对齐（选择器 `purpose=text|translate` 走十字光标模式） |
| 6.2 | 结果直接粘进前台的输入框（按听写的规则），剪贴板也留一份；灵动岛只说结果（Pasted / Copied · ⌘V to paste / Copied） | 只复制 + 提示 | 对齐 | 已对齐：`flow.rs` `deliver`——paste_policy::screen_text 决定（UIA 读焦点：文本框 / 读不出 = 粘；密码框 / 明显不是输入框 / Blurt 自己 = 只复制），Ctrl+V 后读回输入框确认落地（最多 1.5 s）；灵动岛说 Pasted / Copied · Ctrl+V to paste / Copied（Mac 原文）。第二遍读（ScreenTextRefine）：record.screen_text.refine 开 + 接了能看图的云模型时 `screen_text.py read --stdin` 合并，剪贴板还是草稿才替换；Mac 的本地读图模型是 MLX，Windows 没有（系统能力差异） |
| 6.3 | 翻译结果在灵动岛下的卡片里（ScreenTextCard：可复制、10 s 后消失、指针在上面不消失、Esc 只在指针在上面时关） | live 文字 6 s | 对齐 | 已对齐：新窗口 `textcard.html`（Kind::TextCard，不抢焦点）在灵动岛下方 live 面板的位置，14 px / 20 px 行、最多 8 行后滚动、最后一行渐隐、Copy → Copied（勾）；指针离开 10 s 后消失；指针在上面时才注册全局 Esc（global-shortcut），离开就放掉；下一次 Alt+Shift+C/T 换掉它。「Translating…」、已是目标语言、翻译失败（Key / 额度 / 连不上 / 其他 + Try Again）用 Mac 原文；没有云模型时说 translate_needs_model（Windows 只有云端翻译）。位置用 `island::below_cards`：挂着卡片时在卡片下面 |

## 7. 录屏中的截图

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 7.1 | 录屏中 ⌥A = 同一套截图流程（选择器、原地备注、卡片），写进这次录制（t = 视频时间），录制继续 | 热键只截一帧不问；灵动岛按钮 = 暂停 + 截一帧 + 灵动岛下打字 | 截图这边已就绪 | 截图这边做完：`capture::snap::run_in_take(app, TakeSnap { session, project, shoot })`——同一个选择器、原地备注、卡片挂着（不单独归档，随录制走）。录屏那边要接的见 §11 |

## 8. Windows 上的键

| Mac | Windows |
|---|---|
| ⌥A | Alt+Shift+A |
| ⇧ 拖 / ⌥ 拖 | Shift 拖 / Alt 拖 |
| ⌘Z | Ctrl+Z |
| ⌘1–⌘4 / ⌘0 | Ctrl+1–Ctrl+4 / Ctrl+0 |
| ↩ ⇧↩ Tab Esc | Enter Shift+Enter Tab Esc（显示时仍用 ↩ 和 Esc） |

## 8b. Edit Note（卡片上的「编辑备注…」）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 8b.1 | 同一个气泡：整条备注（打的 + 说的）在框里，未标记的原图放大（≤ 540 × 320）带笔迹，可继续画、⌘Z | 灵动岛下的小框，只能改文字 | 对齐 | 已对齐（`note.html?mode=edit`，`capture::edit_note`；改了笔迹就重新烧 marked.png，全撤掉就删掉它） |
| 8b.2 | 字形列是按钮：有语音 = 播放，没有 = 录一段；悬停工具里有「重录」；重录时状态槽「0:02 · recording again」，说过话后「0:04 · Tab to stop」 | 无 | 对齐 | 已对齐：重录走同一个 snap_voice 麦克风；Tab / Save 保留，替换原 wav，字用新录音的；Esc 或没说话 = 原样 |
| 8b.3 | 类型 chip、项目 chip（Save 时卡片移过去，Esc 不动）；Save ↩，Esc 还原（NoteEdit.apply） | 无 | 对齐 | 已对齐（`editApply` = NoteEdit.apply，测试照搬）；选了项目 = 和 card.assign 同一条 `sessions::process` |
| 8b.4 | 气泡锚在卡片下方 | 灵动岛下方 | 保持差异：锚在灵动岛下方正中（卡片画在灵动岛页面里，Rust 拿不到单张卡片的屏幕位置）；窗口按气泡大小缩放（页面发 `note.size`） | — |

## 9. 实现在哪

| 部分 | 文件 |
|---|---|
| 规则（NoteKeys / NoteEsc / InkStroke / InkFit / BubbleDock / ProjectPick / NoteEdit） | `web/apps/overlays/src/notecore.ts`，测试 `tests/notecore.test.ts` |
| 翻译卡片 | `web/apps/overlays/textcard.html`、`src/textcard.ts`、`src/textcard.css`；Rust `screen_text/flow.rs` |
| 复制文字的粘贴、第二遍读 | `apps/desktop/src-tauri/src/screen_text/flow.rs`（cfg(windows)） |
| 定格画面 + 画笔 + 气泡 | `web/apps/overlays/note.html`、`src/note.ts`、`src/note.css`（`mode=snap`；不带 mode = 卡片的 Edit Note，同一个外观） |
| 选择器 | `web/apps/overlays/picker.html`、`src/picker.ts`、`src/picker.css` |
| 窗口 | `crates/blurt-capture/src/overlay.rs`：`pick_region_with(hold)`、`snap_note`、`set_picker_hooks`、`ev::NOTE` |
| 流程、写盘、笔迹烧图、窗口列表 | `apps/desktop/src-tauri/src/capture/snap.rs` |
| 气泡的麦克风（Windows） | `apps/desktop/src-tauri/src/dictation/snap_voice.rs` |
| 文案 | `web/apps/overlays/src/locales/{en,zh-Hans}.json` 的 `note.*` / `picker.*` / `snap.*`（Mac 原文） |

页面和 Rust 之间：Rust → `blurt://note`（shot / voice / level / speech / live / ended / words / commit / failed，带 `g`）；
页面 → `blurt://action` `note.mic {keep}`、`note.activity`，`blurt://note-done`（save、text、said、voice、kind、place、
strokes、flash、lw、selW、g）。

## 10. 还没验证的

- 全部只在 Mac 的浏览器里跑过页面（截图在 scratchpad `parity/snap-and-note/`），Windows 上没跑：麦克风、暖服务出字、
  Alt 拖动（Alt 松开是否让窗口进菜单模式——页面里 preventDefault 了）、WebView2 失焦事件、窗口列表的准确度。
- 截图时冻结的选择器和舞台都还在屏幕上，靠 content protection（WDA_EXCLUDEFROMCAPTURE）不进 gdigrab 的画面——灵动岛录屏一直靠
  这个，但截图这条路以前是先关窗再拍。要在 Windows 上确认截出来的图里没有暗色。

- 回收站（SHFileOperationW）、放大镜的整屏截图耗时（4K BMP 写到 $BLURT_HOME/run，在 asset 协议的范围里）、翻译卡片的全局 Esc、粘贴落地确认、Edit Note 的窗口缩放：都只在 Mac 上编译、在浏览器里看过。

## 11. 录屏中的截图：录屏那边要接的

截图这边：`crate::capture::snap::run_in_take(&app, TakeSnap { session, project, shoot })`（阻塞，放在工作线程）。录屏那边：

1. 录制中 Alt+Shift+A（`capture::snap` 里 `cap.recording()` 那支）和灵动岛的截图按钮（`snap_with_note` 录制那支）都改成调
   `run_in_take`，不再 `Control::Snap` / 暂停；`session` = 这次录制的会话，`project` = 录制的项目。
2. `shoot: Box<dyn FnOnce(Region) -> Option<(u32, String)> + Send>`：拍 `region`（桌面物理像素，用户选的区域，不是录制区域）进这次
   录制——record.py 需要一条新命令（例如 `snap-region x,y,w,h`），用它自己的计数器（`self.shots`，不和 tk_recorder 的编号撞）分配 n、
   写 shots/NNN.png、`shot_line(n, t=视频时间, region)`、events.jsonl 记 `snap`（via=picker）、状态行 `snap {n, file, t}`；`shoot`
   等这条状态行（on_status 的 `StatusEvent::Snap`）返回 `(n, file)`，出错或 20 s 没来返回 None。
3. `take.shots` 计数照旧（on_status 在 Snap 时 +1）。
4. 录制结束时 `island::refresh_cards`：录制会话不是 -shots 批次，`load_cards` 不列它们，挂着的这些卡片就下来了（Mac：take 结束卡片离开线）。
5. Mac 的录屏里看得见这套截图流程（选择器、气泡都在视频里）；Windows 的浮层都开了 content protection，录不进去——要录进去需要
   录屏那边决定这几个窗口在录制时可被捕获（`OverlayConfig.capturable`）。


## 12. 2026-11-02 Windows dogfood 之后（截图 / 卡片 / 选区）

前后对比截图：`promo/cases/dogfood-win-2026-11-02/capture/fixed/`（`before-*` 是 dogfood 当时的，`after-*` 是修完在 VM 上重跑的；`*-demo.png` 是浏览器里的页面 demo）。

| # | 问题 | 处理 | 结果 |
|---|------|------|------|
| 12.1 | 选择器 / 备注气泡有时拿不到键盘（Esc 不关、`/` 和备注打进记事本） | Windows 上 `SetForegroundWindow` 在前台锁下可能被拒。`blurt_capture::overlay::take_keys`：`set_focus` 之后交给 app 注册的 `set_focus_hook`（`capture/focus.rs`）：查 `GetForegroundWindow`，不是自己就 `AttachThreadInput` 到前台线程再 `BringWindowToTop` + `SetForegroundWindow` + `SetFocus`，每 30 ms 重试，最多 ~360 ms。选择器、气泡、岛的卡片面板 / 切换器（`Island::set_keyboard`）都走它 | VM：记事本在前，连按 3 次 Alt+Shift+A，3 次都是选择器拿到键，`/` 没进记事本，Esc 关掉（`after-focus-*.png`） |
| 12.2 | 截图刚松手就算成卡片（备注还开着计数就 +1，丢弃的也算，Done 时没有飞入） | `snap::NOTING`：拍到图后记下 (批次, n)，`card_lines` 不列它；备注结束（存 / 丢）才清掉——存下时由 `{op:'card', from}` 从选区飞进岛 | VM：备注开着时岛上没有多出的计数；丢弃的不计数 |
| 12.3 | 冻结画面出来前 ~1 s 空白 | 只在测试开关 `BLURT_OVERLAY_CAPTURABLE=1` 下出现（选择器松手就关、等截图再开舞台）。正常模式下选择器一直冻结到舞台 `ready`；另外舞台现在先用选择器放大镜那张整屏静帧按选区裁出来当冻结画面（Mac 的 LoupeStills.crop），图解码 + 两帧后才 `ready`，真正的 PNG 到了再换 | 测试模式下仍是测试本身的空白；正常模式没在 VM 上目测（浮层不进截图） |
| 12.4 | 全屏截图时画笔提示被岛挡住 | 提示不进岛那一条（工作区顶 + 44 px）：放不下就放到选区下面或选区里、但不高于这条线 | 页面里看过 |
| 12.5 | 截图 / 复制文字 / 翻译 / 录屏的岛上一行都带麦克风图标 | 岛新增 `kind: 'capture'`：自己的标记（✓ / ⚠）或没有，从不默认麦克风；复制文字：复制 / 粘贴成功 ✓，失败 ⚠，「没识别到文字」和「正在翻译…」不带（后者有转圈） | VM：丢弃、录屏完成、没识别到文字几行都没有麦克风 |
| 12.6 | 卡片悬停是系统白色 tooltip | 去掉 `title`；悬停 0.35 s 后、只在卡片把备注截断时，在卡片下面显示岛风格的提示（整段备注 + 「截图 · 14:32」）。Mac 的大图预览（CardPeek）没做：Windows 上卡片面板的预览已经有大图 | 页面里看过 |
| 12.7 | 卡片面板（Alt+Shift+H）一失焦就关，可能刚打开就被关 | 面板真正拿到过焦点、且打开超过 400 ms 后的失焦才关 | VM：Alt+Shift+H 打开，→ 和 Esc 都有效（`after-cards-panel-*.png`） |
| 12.8 | 翻译卡片阴影被窗口切成硬边灰条、卡片半透明；Edit Note 气泡同样 | 翻译卡片窗口左右各留 24、下面 34 给阴影，卡片纯黑 #000、去掉内描边；Edit Note 窗口四周留阴影位（左右 34、上 10、下 40） | 页面里看过（`after-textcard-demo.png`） |
| 12.9 | Done 之后卡片看起来是「出现」而不是飞进来 | 两个原因：① 舞台（全屏备注窗口）盖着岛的时候，WebView2 把岛当被遮住的页面，暂停它的动画帧；`card` 一到，第一帧就被当成「饿了」，飞行直接跳到终点——现在 Rust 等舞台窗口没了再发 `card`（`snap::note_gone`），岛收到新卡片时丢掉之前遮挡期间留下的那个帧请求、重新开始（`restartLoop`）；② 测试 VM 关了「动画效果」（prefers-reduced-motion），按设计卡片直接淡入（Mac 的 Reduce Motion 同样） | VM 打开动画效果后逐帧（~65 ms 一张）：舞台淡出，~0.35 s 卡片从选区飞起、摆动着挂到岛下，~0.9 s 停稳（`fixed/after-card-flight-frames-animations-on.png`） |
| 12.10 | 已归入那行的「更改」 | 点「更改」→ 岛的项目选择器（「移到」，当前项目打勾）→ 选 shop-web → `items.py move` →「已移到 shop-web · 撤销」；撤销把它移回 api-server | VM：AS-3 → shop-web → 撤销后回到 api-server（`fixed/after-filed-change-move-undo.png`、`after-filed-move-then-undo.png`） |
| 12.11 | 复制屏幕文字：英文单词之间的空格丢了（「the savebuttondoes nothing」）；dogfood 里「没识别到文字」是测试脚本的坐标问题（没开 DPI 感知，拖到了字下面），不是程序 | PP-OCR 的识别模型在 ~11 pt 的屏幕字上会吃掉英文词间的空格：`screen_ocr.py` 对不大的选区（≤ 1.5 MP）先放大 2 倍再读（框坐标再除回去），用 imdecode 读图（中文用户名路径也能开）。翻译后多行粘贴进记事本时，岛上说「已复制 · Ctrl+V 粘贴」其实已经粘上了：记事本读回来的换行是 `\r`，现在按统一换行再比一次（`flow.rs landed_lines`） | VM：记事本中英混排两行原样读出、带空格，「已粘贴」；翻译「已粘贴译文」+ 卡片；Edge 本地页面（标题、中英段落、列表、代码行）读对，焦点不在输入框时「已复制 · Ctrl+V 粘贴」（`fixed/after-copytext-*.png`）。还在的小问题：列表的圆点没读出来、`CSV` 读成 `CsV`（识别本身） |

留着没改：岛空闲时越来越宽、顶边 6 px 进不去、150 % 下主窗口超出屏幕是外壳那边的。

## 13. 2026-11-02 视觉评审第 1 轮之后（选择器 / 冻结画面 / 备注气泡 / Edit Note）

截图见 `promo/cases/visual-gate-win-2026-11-02/inventory/capture/`。下面是改了什么、为什么。**还没在 Windows 上重拍**：当时的测试 VM 已经自动释放（见末尾）。

| # | 评审问题 | 处理（以 Mac 为准） | 文件 |
|---|---------|------------------|------|
| 13.1 | 放大镜下面没有读数（Mac C03 有「1236, 407」） | 放大镜下 6 px 画玻璃药丸：平时显示指针的物理像素坐标，拖选区 / 改大小时显示 W × H。复制文字也一样（5.9 原先只在复制文字时标尺寸，现在改成跟 Mac 一致） | `picker.ts` drawLoupe |
| 13.2 | 放大镜在 150 % 下是模糊的块，没有像素格 | 改为按整像素取 n×n（奇数，指针像素居中），每个像素在放大镜里是一样大的格子，格子之间画半透明细线；十字和中心框下垫一层深色晕，深色页面上也看得见；1.5 px 白环 + 1 px 深色外线 + 阴影（黑 35 %、12 px、y+4），在白页面上也有边 | `picker.ts` |
| 13.3 | 悬停窗口时放大镜和「点击截取这个窗口」叠在一起（150 % 下挡住字） | 按 5.9：悬停整窗、还没开始拖时不显示放大镜（单击就取整个窗口，没有边要对）。有选区时只在边的 16 px 内或拖动时出现。位置离指针 24 px，放在远离选区的一侧，出了工作区就翻到另一侧（复制文字放左上，不挡要读的字） | `picker.ts` loupeWanted / drawLoupe |
| 13.4 | 图例和任务栏的距离随缩放变化 | 统一距工作区底部 24 DIP | `picker.ts` render |
| 13.5 | 悬停窗口的边穿过底部提示（150 %）| 提示和悬停窗口的边相交（12 px 内）就挪到顶部岛下面（工作区顶 + 52），不行就放到窗口底边里面 | `picker.ts` |
| 13.6 | 键帽不统一（esc 是小写宽条，F / L 是方块），分隔线两边间距不一样 | 键帽一个组件：18 px 高、4 px 圆角、11 px 600；写作「Esc」。分隔线两边都 12 px，颜色白 26 %。图例 14 px，键说明 13 px | `picker.css` |
| 13.7 | 关掉图例（?）后没有办法知道怎么开回来；悬停标签也跟着消失 | 精简图例最后加一个淡的 [?] 键帽（tooltip「按 ? 显示或隐藏按键说明」）。「点击截取这个窗口」用自己的次数（前 3 次，和图例同一份 hint_budget），? 不再关它 | `picker.ts` |
| 13.8 | 中文提示啰嗦、动词不一致（拖拽 / 拖动） | 统一「拖动」：「拖动框选，或点击窗口截图」/「…窗口录制」；悬停「点击截取这个窗口」；画笔提示「拖动绘制 · Shift 方框 · Alt 椭圆 · Esc 丢弃」 | `locales/zh-Hans.json` |
| 13.9 | 中文字太粗（YaHei UI 只有 Regular 和 Bold，WebView2 把 500 也用 Bold 画） | overlays 的字体栈最前面加 `Blurt CJK`：只覆盖汉字区，300–500 用 YaHei UI Regular，600–900 用 Bold；拉丁字母还是 Segoe UI。另外图例和工具栏在 zh-Hans 下用 400 | `theme.css`、`picker.css` |
| 13.10 | 尺寸徽章和选区线贴在一起；徽章是一块平的黑；暗色页面上选区不明显 | 所有选择器上的浮层用同一个「capture glass」：rgb(30 30 32/.9) + 12 px 模糊 + 白 12 % 内线 + 0 4 12 黑 25 % 阴影。徽章离 2 px 线 6 px。选区外加 Mac 的柔和阴影（0 0 0 2px 黑 22 % + 0 8 24 黑 30 %），暗色系统下外面压暗 55 %（亮色 42 %） | `picker.css` |
| 13.11 | 录屏工具栏贴在任务栏上、不在选区底边上 | Mac C32：居中、跨在选区底边上；离工作区底至少 12 px，选区到底了就放在选区里面靠底 | `picker.ts` |
| 13.12 | 选择器开着时岛还很亮、上一张截图的「已丢弃 · 撤销」留在录屏选择器上、项目问题弹在选区上 | Rust 在选择器 / 备注 / 录屏开始期间发 `{op:'busy'}`：岛降到 35 %（Mac 的选择器盖住岛），清掉上一个非警告提示，可以等的提示（passive：问题、提示、任务完成）先放着，空闲 1.5 s 后再出 | `island.rs busy`、`snap.rs`、`capture.rs`、`screen_text/flow.rs`、`island.ts` |
| 13.13 | 冻结画面四周没压暗（WebView2 透明窗口把 100vmax 的阴影扩展剪掉了） | 单独一层 `.dim`（亮色 42 % / 暗色 55 %），用 `clip-path: path(evenodd)` 挖掉选区；选区线下再加 2 px 深色环和阴影 | `note.html`、`note.css`、`note.ts` |
| 13.14 | 全屏截图（F）看不出整屏被冻结 | 整屏时不压暗，线画在屏幕边以内（outline-offset −2），画笔提示放在顶部岛下；气泡距工作区右边和底边都是 16 px（和 Windows 通知一样） | `note.ts`、`note.css` |
| 13.15 | 画笔提示在暗色页面上没有底 | 用 capture glass（13 px / 500，中文 400，28 px 高），离选区 10 px | `note.css` |
| 13.16 | 气泡：光标压在占位文字第一个字上；字太小；Done 的 ↩ 是粗糊的字体符号；字形列的图标很淡 | 输入框左边留 3 px；底栏 chip 13 px / 26 px 高，状态 12 px，和 Done 之间 12 px；Done 26 px 高、13 px 600、12 px 左右内边距，↩ 换成 1.5 px 线的 SVG（白 80 %）；字形列所有状态（电平、波形、键盘、划掉的麦克风）16 px、`--b-fg2` | `note.css`、`note.ts` |
| 13.17 | 正在说的字一片灰，句号先出现再被改掉 | 已定的字用次要色，最新一段用更浅的三级色；还在听时最后一段末尾的句号 / 问号 / 感叹号先不显示（Tab、Enter 或下一段到了再显示）。录到字以后时间还在：「0:05 · Tab 采用识别结果 · 直接打字可替换」 | `note.ts` liveTail、render |
| 13.18 | 已保存时字还是灰的，Done 看起来还能点，尾巴指着空处 | 保存时字变主色（120 ms），字形列换成 16 px 的绿勾，「已保存」13 px 次要色，Done 降到 55 %，尾巴随冻结画面一起收掉 | `note.ts`、`note.css` |
| 13.19 | 语音备注占用麦克风时，气泡多出一行空白，原因只写在占位符里 | 空输入框按占位文字实际行数定高（一行就一行）；底栏状态位写「语音备注进行中」；英文占位改为 "Voice note in progress. Type here instead." | `note.ts` fitField、locales |
| 13.20 | 项目列表：找不到文件夹的排第一、图标只是灰文件夹；指针悬停没有反馈；行太挤；黄 / 橙看不出区别；只有一个结果时贴着底 | 找不到的项目排在能用的后面（仍在未归类上面），图标换成带问号的文件夹；指针下的行有自己的浅底，和键盘选中的薄荷底分开；行 32 px、14 px 字、说明 12 px（中文 12.5）；文件夹填充 60 %；列表底部留 8 px；勾 14 px 粗线 | `note.css`、`note.ts`、`notecore.ts` placeChoices |
| 13.21 | 气泡太宽，中间空一大块；停靠在下面时不对齐 | 最小宽度 360（原 384），按内容算、上限 470 DIP；停靠在选区上 / 下时以选区居中 | `note.ts` |
| 13.22 | Edit Note 在 150 % 下图被裁、只露出一部分 | 窗口先按 600×480 物理像素打开、再按 `note.size` 变成逻辑尺寸，中间页面被滚动过，图被推出去。现在布局时把页面滚回 0、聚焦时 `preventScroll`；图片 `object-fit: contain`，放在 8 px 圆角、1 px 细线、浅底的框里；卡片四边 12 px，保存按钮和 Done 一样大；字形列图标改为次要色（不再是看着像在录音的品牌绿麦克风）。播放 ▷ / 麦克风的选择保持原样（有录音 = ▷） | `note.ts`、`note.css` |

不改的：Mac 的未归类图标在 C04 气泡里是收件箱，Windows 用虚线圆，这是 island.md 定下的「未归类 = 虚线圆，收件箱另有其图」（两边都要分清楚收件箱和未归类），保持。

**还要在 Windows 上重拍验证的**（VM 42.120.60.29 在 11-03 00:00 自动释放，本轮只做了 Mac `cargo check`、Windows 目标的 `cargo check`、overlays `tsc` + `vitest` 72/72）：picker-idle / hover-window / legend-off / dragging（含真正贴屏幕右边、下边的放大镜）/ record；snap-frozen-first-time；bubble-listening / grey-words / saved / accepted-typing / voice-busy / fullscreen；frozen-ink；bubble-project-list（指针真的放在非当前行上）/ filter；edit-note（100 / 125 / 150 %）。另外要确认 `Blurt CJK` 的 local() 名字在 WebView2 上命中（不命中就退回原来的 YaHei，不会更差）。

## 13. 2026-11-02 visual gate r1 之后（选择器、冻结画面、气泡、复制文字）

评审截图：`promo/cases/visual-gate-win-2026-11-02/inventory/capture/`。重拍放 `…/redesign/capture/r1/<screen-id>/`（见文末「还没验证的」）。

| # | 判断 | 处理 |
|---|------|------|
| 13.1 放大镜下面的读数 | Mac C03 / C16 放大镜下面一直有读数；Windows 原来只在复制文字的拖动里有，是缺口不是平台差异 | 每个选择器都有：没在拖时是指针位置（这块屏的物理像素「1236, 407」），拖 / 改大小时是选区尺寸（物理像素，复制文字也一样，不再是 DIP）。读数是和尺寸角标同一种玻璃胶囊，放大镜下 6 px |
| 13.2 放大镜本身 | 150 % 下是放大的模糊位图，白页面上没有边 | 只取整数个图像像素（奇数个，指针那一个在正中），每个像素画成同样大的格子，格子之间一根细线；1.5 px 白圈外面一根 1 px 深色细线，阴影 12 px / y+4；十字线薄荷色下面垫一道深色，深色页面上也看得见 |
| 13.3 放大镜什么时候出现（5.9） | 悬停一个窗口时没有要对齐的边，放大镜盖住窗口中间的提示 | 悬停窗口、没在拖：不出现；有选区：只在离边 16 px 内或拖动时；录屏工具条旁边不出现。位置：离指针 24 px，在离开选区那一侧（复制文字：左上，不挡要读的字），出了工作区就翻到另一侧（以前按窗口高度算，150 % 下会压到任务栏） |
| 13.4 按键说明条 | 离任务栏的距离随缩放变；悬停窗口的边从条中间穿过；键帽大小不一；中文显得太粗 | 离工作区底边固定 24 DIP；悬停窗口的边和条相交（12 px 内）时挪到顶上岛下面（工作区顶 + 52），顶上也相交就放进窗口底边里面；文字 14 px、键帽统一 18 px 高 4 px 圆角、`Esc` 首字母大写；分隔线两边各 12 px。中文字重见 13.10 |
| 13.5 「单击截取这个窗口」 | 原来和 ? 一起关掉，关了以后点窗口没有任何文字提示 | 跟前几次的次数走（`legend` 参数 = snap.rs `hint_budget`），不跟 ? 走；? 关掉说明后，条尾留一个淡的 `?` 键帽，提示能再打开 |
| 13.6 文案 | 「拖拽框选区域，或单击一个窗口来截图」太长、像翻译；动词和别处的「拖动」不一致 | 统一「拖动 / 点击」：「拖动框选，或点击窗口截图」「拖动框选，或点击窗口录制」「点击截取这个窗口」；画笔提示「拖动绘制 · Shift 方框 · Alt 椭圆 · Esc 丢弃」（Mac 的「拖动画笔」读起来像「拖动那支笔」，这里有意不同） |
| 13.7 选区和尺寸角标 | 深色页面上选区里外几乎一样；角标是平的黑块，贴着选区线 | 选区外加一圈 2 px 深色 + 8/24 的软阴影；系统深色模式下选区外暗 55 %（浅色仍 42 %）。角标、说明条、工具条、窗口标签、画笔提示是同一种玻璃：`rgb(30 30 32 / .9)` + 模糊 + 1 px 白 12 % 内线 + 0 4 12 阴影；角标离选区线 6 px |
| 13.8 录屏工具条 | 在选区下面贴着任务栏 | Mac C32：居中、压在选区底边上；放不下就收进选区底边里面，离工作区底至少 12 DIP |
| 13.9 冻结画面的暗 | WebView2 的全屏透明窗口把 100vmax 的 box-shadow 裁掉了，冻结画面外面根本没暗 | 单独一层 `.dim`（`clip-path: path(evenodd, …)` 把图片位置挖空），浅色 42 %、深色 55 %；冻结图外面 2 px 深色 + 软阴影。全屏截图（F）：不暗，选区线画在屏幕边里面（`outline-offset: -2px`），画笔提示放在顶部岛下面 |
| 13.10 中文字重 | 微软雅黑 UI 只有常规和粗体，WebView2 把 500 也画成粗体，中文一行比旁边的英文重一号 | `theme.css` 的 `Blurt CJK`：只管汉字 / 全角范围，300–500 用常规、600–900 用粗体；拉丁字还是 Segoe UI。所有浮层生效 |
| 13.11 气泡 | 字号、Done、光标压字、占位行、保存后的样子 | 输入框 15 px，左边 3 px，光标不再压在第一个字上；脚注 chip 13 px / 26 px 高，Done 26 px 高 13 px 半粗，回车键是 1.5 px 线的 SVG（字体里的 ↩ 是一团）；状态位和 Done 之间 12 px；字形列（电平、键盘、斜杠麦克风、波形）统一 16 px、次要色。听写中的字：已定的次要色，最新一段淡一级，正在说的一段末尾的句号先不显示（下一段来了或 Tab / Enter 才定）；有字之后时间不消失：「0:05 · Tab 采用识别结果 · 直接打字可替换」。保存：字变主色、✓ 16 px、「已保存」13 px、Done 退成 55 %、尾巴收起（图片已经在淡出）。语音备注占着麦克风：不再多留一行空白（空输入框按占位文字实际行数定高），状态位「语音备注进行中」，文案「正在录语音备注，这里可以打字」/「Voice note in progress. Type here instead.」。全屏截图的气泡离工作区右边和底边都是 16 px；停在选区上下时居中对着选区 |
| 13.12 项目列表 | 找不到文件夹的项目排第一、图标只是灰文件夹；指针在列表上没有变化 | 找不到文件夹的排在能用的后面（还在「未归类」上面），图标是带问号的文件夹；项目文件夹填 60 %（黄、橙在白底上分得开）；行 32 px / 14 px；说明 12 px（中文 12.5）；指针所在行一层淡底，键盘选中的薄荷行不跟着指针走；勾 14 px 粗一点；列表底下留 8 px，只剩一行时不贴底边 |
| 13.13 Edit Note 的图（150 % 阻断） | 窗口一开始比气泡小，聚焦输入框把页面滚下去了，图被切 | 聚焦不滚动（`preventScroll`），每次排版把页面滚回 0；图片 `contain`，圆角细边的「图框」；四周 12 px；Done/保存同 13.11；播放键是次要色，不是品牌绿的麦克风 |
| 13.14 复制文字 / 翻译之后 | 松手后 1 s 多什么都没有 | 选择器一关，岛的左耳就是 Peep 在想 + 三个点（`{op:'working'}`），结果那行一来就换掉；「没识别到文字」由 Peep 领头（`mark: 'peep'`），岛上任何一行都不再有空的图标位 |
| 13.15 翻译卡片 | 固定 400 宽、一行字也占两行、悬停不保持（不拿焦点的窗口收不到 pointerenter） | 宽度随内容（280–400）；只有一行时「复制」在这一行末尾；字 15/22，四边 14/16，复制 28 px 13 px；连续空行合成一个换行（只是显示）。悬停保持：Rust 每 100 ms 读指针位置发给卡片（`{op:'cursor'}`），页面自己判断在不在卡片上；悬停时复制按钮亮一级 |

还没做 / 留给别人的：两段识别结果之间的句号（「…dark mode Make the border…」）是听写拼接（`stitch.rs` 的 seam）的事；OCR 的空格和大小写（`POsT`、`50430.0S`）、译文丢 € 和列表符号是 `screen_text` 识别 / `cloud.rs` 提示词的事，这一轮没动。截图的中文测试脚本以前在接受的文字后面打了一个前导空格（「看不见。 另外」），那是脚本本身，产品没有插空格。

## 14. 2026-11-03 视觉评审第 2 轮（截图区）

第 2 轮评审看的还是 11-02 22:13 左右拍的那批截图，比第 1 轮的改动（00:29–01:03）早，所以大部分意见（放大镜读数、键帽、中文字重、图例位置、项目问题、冻结画面的暗、气泡的光标 / ↩ / 已保存）第 1 轮已经改了，只是还没在 Windows 上重拍。这一轮补的是第 1 轮没覆盖到的：

| # | 评审问题 | 处理（以 Mac 为准） | 文件 |
|---|---------|------------------|------|
| 14.1 | 暗色下悬停窗口被薄荷色整片染绿，看不出窗口本来的颜色；外面也只暗 42 % | 暗色系统：窗口内的薄荷底降到 6 %（亮色保持 Mac 的 10 %，Picker.swift），外面和选区一样暗 55 %；高亮主要靠 2 px 线 | `picker.css` |
| 14.2 | 暗色页面上角标、读数、说明条的玻璃看不出边 | 暗色系统下玻璃亮一级（rgb 44 44 46 / .92），内线白 20 %，阴影 35 % | `picker.css` |
| 14.3 | 复制文字的放大镜在指针左上，挡住要瞄准的那一行上面的字（Total €162.14） | 和 Mac Loupe.frame 一样放在右下，出了工作区才翻；拖动时仍放在远离选区的一侧。更正 13.3 里「复制文字放左上」 | `picker.ts` drawLoupe |
| 14.4 | 白页面上放大镜像一块空白方块，像素格看不见 | 像素格线改为中灰 34 %（原 22 %），白底上也看得出是放大镜 | `picker.ts` |
| 14.5 | Tab 采用的字停在半句（被切开的段），接着打一个大写开头的新句子，连成「…border of Also the…」 | `joined`：采用的字以字母 / 数字结尾、打的字以大写字母开头时中间加「. 」；中文照旧什么都不加（「。」后面不加空格） | `notecore.ts`、`tests/notecore.test.ts` |
| 14.6 | 删除一张卡片：英文「Deleted」，中文「已删除 1 张卡片」，两种语言说的不一样 | 中文的复数规则永远是 other，`_one` 从来用不上。`plural()` 在 n = 1 时一律取 `_one`；中文 `_one` 改成「这张卡片」的说法（复制这张卡片 / 删除这张卡片 / 把这张卡片移到 / 已复制…），不再出现「复制全部 1 张卡片」 | `host.ts`、`locales/zh-Hans.json` |
| 14.7 | 翻译 Key 失败中文用逗号连成一句，没有英文那样的主次 | 「翻译服务 Key 无效 · 已复制原文」，和听写的同类提示一致 | `locales/zh-Hans.json` |
| 14.8 | 录屏红点截图时是暗红，像停了 | 按 system.md：呼吸 1.6 s、最暗 80 %，去掉外圈晕（Mac 的点没有） | `island.css` |
| 14.9 | 选择器：悬停窗口时外面根本没暗（zh-light 里壁纸和窗口一样亮，评审说是「白雾」），只剩窗口里的薄荷底 | 和 13.9 冻结画面同一个原因：WebView2 的透明窗口把 `0 0 0 100vmax` 的 box-shadow 裁在元素自己的框里。选择器的暗改成单独一层 `.mask`，用 `clip-path: path(evenodd, …)` 把悬停的窗口（按窗口圆角）或选区挖掉：没东西时 22 %，有洞时 42 %（暗色 55 %），选择器和冻结画面从此一样暗。悬停窗口：亮色是 Mac 的 10 % 薄荷底，暗色 6 %；2 px 线下面垫一道深色细线，白页面、黑页面上都看得见 | `picker.html`、`picker.css`、`picker.ts` holePath |
| 14.10 | 「编辑备注」打开后指针一离开，挂着的卡片收回去，气泡的尾巴指着空处，卡片留下半透明的影子 | Rust 在 Edit Note 窗口开着时发 `{op:'editing', on}`：岛把这一排卡片一直放下来（录屏中除外），关掉后再停 0.9 s 才按平常的规则收 | `capture/snap.rs` edit_note、`island.ts`、`host.ts` |

评审里不照做的（和 Mac 当前源码不一致）：「Start over」不改「Restart」（Mac Capture.strings 是 Start Over）；录屏 ··· 菜单四项之间各一条分隔线和 Mac showRecordingMenu 一样，保留；没在拖时放大镜下的坐标读数保留（Mac 当前不画，但三位评审都要它，13.1 已定）。

翻译提示词（`polish.py translate_system`）：一行原文是一行译文、不合并；数字和货币符号原样保留（€162.14 还是 €162.14）——评审看到的列表被「 · 」连成一行、€ 丢了。

还没找到原因的：语音备注按「完成」后出现「语音备注已丢弃 · 撤销」。只有 `Ended::Cancel`（Esc / `voice.cancel`）才会走到这句，「完成」发的是 `voice.stop`；需要在 Windows 上用 `BLURT_DEBUG_VOICE=1` 复现看是谁发的 Cancel（拍摄脚本这一步在重新启动之后，只点了「完成」）。

**本轮也没有在 Windows 上重拍**：测试 VM（42.120.60.29 等四台克隆）11-03 00:00 已自动释放，IP 已归别人。只做了 Mac `cargo check`、Windows 目标 `cargo check`（假编译器）、overlays `tsc --noEmit` + `vitest` 72/72。要重拍的同 §13 末尾的清单，外加 picker-text-crosshair（放大镜在右下）。
