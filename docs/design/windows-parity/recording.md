# Windows 录屏对齐 Mac（审计 + 实施记录）

范围：录屏从开始到结束的整条路——开始、选区、倒计时、录制中的界面（录制框、岛之外的部分）、暂停 / 继续、丢弃、重新录屏、
只保存视频、完成、录制中的画笔、实时字幕、系统声音、指针和点击记录，以及结束之后：整理、岛上的那一刻、失败时说什么。
不含：选择器页面本身（snap-and-note §5，同一个页面）、岛的录屏内容和「···」菜单的样子（island §3，岛那位）、录屏中的截图流程
（snap-and-note §7）、托盘菜单的其它行（settings §1）、设置页的录屏几行（settings §3.4，界面归设置那位，后端在这里）。

规格是 Mac 源码：`Capture/Recorder.swift`、`Chrome.swift`（录制框、倒计时、字幕条）、`LiveAudio.swift`、`LiveFeeds.swift`、
`Island/IslandRecording.swift`（RecordingWatch、RecordingDone）、`InkView.swift`（录制中的画笔）、`App/AppDelegate.swift`
（`startRecording` / `begin` / `countdown` / `takeEnded` / `savedVideoOnly` / `failedTake` / 菜单的录屏几行）、`SnapApp.swift`
（实时字幕菜单项）、`Refile.swift`（`offerRecording`），BlurtCore `RecordingFailure.swift`、`OverlayFit.swift`、`TakeProgress.swift`。
文案一字不改取自 `Resources/{en,zh-Hans}.lproj/{Capture,Main}.strings`（Finder → 文件资源管理器，⌥/⌘ → Alt/Ctrl）。

「Windows 之前」= 本分支 2026-11-02 的 `apps/desktop/src-tauri/src/capture.rs`、`crates/blurt-capture/src/engine.rs`、
`skills/blurt/scripts/record.py`（ffmpeg 引擎，`--status-jsonl`）。

处理一栏：**对齐** = 照 Mac 做；**保留不同** = 有意不同，后面是原因；**做不到** = 缺系统能力或后端，写明缺什么、归谁。
结果一栏：已做 / 部分 / 未做 / 不变。标 *Windows 未验证* 的是只在 Mac 上编过（`cargo check --target x86_64-pc-windows-msvc`），
要在 Windows 虚拟机上跑一遍。

## 1. 开始

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 1.1 | 入口：⌥R、菜单「开始录屏」、岛的录屏按钮、`blurt://record` | Alt+Shift+R、托盘、岛、`blurt://record` | 对齐（已有） | 不变 |
| 1.2 | `blurt://record` / `blurt://snap` 从别处来的链接先在岛上问一句「一个链接想开始录屏 · 开始录屏」（口喷鸡本来就在前台除外） | 直接开始 | 对齐（Windows）：`lib.rs handle_url` 在主窗口不在前台、也没在录时不直接开始，岛上一条带按钮的提示（`rec.url:record`），点了才开始；不点就过去。快捷键不走链接，不受影响。保留不同（Linux）：Wayland 上用户把系统快捷键绑到 `blurt://record`，每次都问就没法用 | 已做（*Windows 未验证*） |
| 1.3 | 开始前：开着的备注气泡先保存（`NoteBubble.commit`） | 无 | 归截图那位（备注气泡）；录屏这边不另做 | 不变 |
| 1.4 | 磁盘可用空间不到 2 GB：岛上说「磁盘可用空间仅剩 X，可能不够长时间录屏」，照样录 | 无 | 对齐：`record.py` 开录前看会话目录所在盘（`shutil.disk_usage`），发 `{"ev":"low_space","free":…}`，岛上一句 || 已做（*Windows 未验证*） |
| 1.5 | 没有屏幕录制权限 / 旧授权：岛上说并给权限向导，不开始 | — | 保留不同：Windows 录屏不需要权限 | 不变 |
| 1.6 | 录到哪：开始时的当前项目（`takeProject`），未归类 = 收件箱 | 同 | 对齐（已有） | 不变 |

## 2. 选区

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 2.1 | 选择器：拖、点窗口、F 全屏、L 上次区域、↩ 开始录屏、Esc 取消 | 同一个页面 | 归截图那位（snap-and-note §5.8，录屏模式一起改了） | 不变 |
| 2.2 | 选好的区域记作上次区域（`record.last_region`） | `record.last_region_px` | 对齐（已有；物理像素，Windows 的坐标） | 不变 |
| 2.3 | 菜单里按住 ⌥ 变成「录制上次的区域」 | 无 | 做不到：Windows 菜单没有按修饰键切换的备选项（settings §1.6） | 不变 |

## 3. 倒计时

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 3.1 | 长度来自 `record.countdown`（设置：无 / 3 / 5 秒，默认 3）；0 = 不倒计时 | 没有倒计时，选完立刻录 | 对齐：`capture.rs` 读 `record.countdown` 传 `--countdown N`；`record.py` ffmpeg 引擎在 host 模式下倒数，每秒一行 `{"ev":"countdown","n":…}` || 已做（*Windows 未验证*） |
| 3.2 | 样子：岛的一块——黑底（#000，圆角 24，0.5 白 12 % 描边，柔和阴影），92 的圆环（3 粗，白 12 % 底轨，`rec` 红随时间排空，从 12 点顺时针），中间 44 号半粗数字（白 92 %，换数字 0.14 s 淡入淡出），下面 Peep 听着 +「准备开始」（14 半粗），再下按键提示「[⌥P] 暂停  [⌥S] 完成」（白 60 %，两个都关了就没有），最下「现在开始」薄荷色小按钮 | 无 | 对齐：新页面 `overlays/rec.html?mode=countdown`（`rec.ts`），数和颜色照 `CountdownView`；键名用用户真实的键（`Alt+Shift+P`），Peep 用岛的同一张图 || 已做（*Windows 未验证*） |
| 3.3 | 窗口 = 录制区域（区域太小时 = 面板 + 每边 40 的阴影位），居中，夹在屏幕内（`OverlayFit.frame`）；点窗口任意处或「现在开始」立刻开始 | — | 对齐：同样的算法（`chrome.rs countdown_rect`）；点击发 `go` || 已做（*Windows 未验证*） |
| 3.4 | 每个数字响一声 Pop | — | 对齐时刻，换成自己的声音：Pop 是 macOS 的系统声，不能随 App 分发。`assets/sounds/build.py` 合成一个短促的「啵」（1.6→0.6 kHz 下滑，60 ms）→ `sounds/rec-tick.wav`，每个数字响一次（`chrome::sound`，和听写的提示音一样用 PlaySoundW）；录制开始前就响完，不进视频 | 已做（*Windows 未验证*） |
| 3.5 | 减少动态效果：圆环满且不动 | — | 对齐：`prefers-reduced-motion` || 已做（*Windows 未验证*） |
| 3.6 | 倒计时不进视频：它消失 0.12 s 后才开始录，而且被录屏排除 | — | 对齐：`record.py` 倒数完才起 ffmpeg（编码器探测和 ddagrab 探测提前在倒数时做完，起录只剩起进程）；窗口 content-protected || 已做（*Windows 未验证*） |
| 3.7 | 倒计时期间岛还不是录屏状态（`recordingStarted` 在画面开始后才调） | Starting 就算录屏，岛显示 0:00 | 对齐：`capture.state()` 多一个 `countdown`，`island.rs` 倒计时期间不把它当录屏 || 已做（*Windows 未验证*） |
| 3.8 | 倒计时中「完成」/「丢弃」：什么都没录，不留文件夹（Mac 的「完成」在这里会走 no_frames，弹「录屏未保存」——看着是个漏洞） | — | 对齐「不留东西」：`record.py` 倒数中收到 `stop` / `discard` 直接 `discarded`，不弹错 || 已做（*Windows 未验证*） |
| 3.9 | 菜单栏 Peep 倒计时时在听 | — | 保留不同：托盘图标是静态的（settings §1.19） | 不变 |

## 4. 录制中的界面（岛以外）

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 4.1 | 录制框：区域外 4 pt 一圈，圆角 4；录制中 `rec` 红实线 2.5 + 下面 35 % 黑 4 粗；暂停 = `attn` 琥珀虚线（10 / 6，四角实心、每边的虚线首尾都落在角上，下衬也是虚的）；不进视频 | 无 | 对齐：`overlays/rec.html?mode=frame`，`BorderView.dashedPieces` 原样搬成 SVG；点不到（穿透），content-protected || 已做（*Windows 未验证*） |
| 4.2 | 全屏录：框留在屏幕上（压在边缘像素上，但被录屏排除） | — | 对齐：框窗口夹在显示器内 || 已做（*Windows 未验证*） |
| 4.3 | 岛：红点 + 时间、展开后暂停 / 截图 / ··· / 完成 | 有 | 归岛那位（island §1.6、§3） | 不变 |
| 4.4 | 菜单栏图标：红点 + 时间 | — | 保留不同：托盘图标旁不能放字（settings §1.19） | 不变 |
| 4.5 | 指针位置（0.1 s 一次）和点击（左 / 右键，区域内 0–1 坐标）写进 events.jsonl，`frames.py` 用来挑画面、标指针 | 只有暂停 / 继续 / 截图 / 停止 | 对齐（Windows）：`record.py` 用 `GetCursorPos` / `GetAsyncKeyState` 轮询（20 ms，点击取按下沿），进程设成 per-monitor DPI aware 才和区域的物理像素对得上。Linux 不做（X11 没有不装依赖的全局指针读法） || 已做（*Windows 未验证*） |
| 4.6 | 录制中的画笔：按住 ⌃（`record.draw_key`）画，⌃⇧ 方框、⌃⌥ 椭圆，⌥D 锁定（「···」里「画笔」带勾和键，锁定时 Esc 放下）；画的线进视频，3 s 后 0.5 s 淡出；手绘停 0.5 s 吸附成形；每笔写 events.jsonl（shape、≤120 个 0–1 点、t0）；暂停时笔放下 | 无 | 对齐「锁定」这一种：Alt+Shift+D（`hotkeys.rs` 加回 `pen`，只在录屏时注册）或「···」的「画笔」打开 / 关掉，开着时 Esc 放下；拖 = 手绘，Shift 方框，Alt 椭圆（和截图的笔同一套键与 InkStroke / inkFit，`notecore.ts`）。新窗口 `rec.html?mode=ink`（`recink.ts`）正好盖住录制区域、**不**加 content protection（线要进视频），笔关着时鼠标穿透，开着时接管拖动并在指针处显示笔的圆环；`stroke` → `record.py stroke:` 写 events.jsonl。保留不同：不做「按住 Ctrl 画」——Windows 上 Ctrl+点击（多选、Ctrl+滚轮缩放）天天用，录屏时按住 Ctrl 会被笔抢走；Ctrl+Alt 又是很多键盘上的 AltGr（打 @、€ 时按着），也不行。所以只有锁定这一种用法 | 已做（*Windows 未验证*） |

## 5. 控制

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 5.1 | 暂停 / 继续：⌥P、岛、菜单；暂停时视频不录、麦克风不录，框变虚线 | 有（ffmpeg 分段 + 麦克风闸门） | 对齐（已有）+ 框跟着变 || 已做（*Windows 未验证*） |
| 5.2 | 完成：⌥S、岛、菜单「完成录屏」 | 有 | 对齐（已有） | 不变 |
| 5.3 | 丢弃：岛上先问（岛那位），菜单「丢弃录屏」直接丢 | 有 | 对齐（已有） | 不变 |
| 5.4 | 重新录屏：丢掉这段，**同一区域**不再选、重新倒计时开始；这段的卡片一起走 | 岛的「重新录屏」= 丢弃后再弹选择器 | 对齐：`Capture::restart`（记住这段的区域，丢完用它直接开始，倒计时照常）；岛的 `restart` 动作改调它；托盘加「重新录屏」 || 已做（*Windows 未验证*） |
| 5.5 | 只保存视频：岛「···」最上一项、菜单「只保存视频」；= 完成但不整理 | 无 | 对齐：`Control::VideoOnly`（`videoonly`）：记在这段上，发 `stop`；结束时见 §6.3；岛「···」和托盘加这一项 || 已做（*Windows 未验证*） |
| 5.6 | 菜单录屏时的顺序：完成录屏 · 只保存视频 · 暂停/继续 · 重新录屏 · 丢弃录屏 — 截图 · 实时字幕（勾） | 完成录屏 · 暂停/继续 · 丢弃录屏 — 截图 | 对齐：补「只保存视频」「重新录屏」「实时字幕」（`tray.rs` 小改） || 已做（*Windows 未验证*） |
| 5.7 | 录屏中退出 App：录完的保留 | `stop_and_wait` | 对齐（已有） | 不变 |
| 5.8 | 录屏中 ⌥A（和岛的截图按钮）= 截图那套流程：选区、原地备注、卡片挂在线上，写进这次录制（t = 视频时间），录制不停 | 热键只截录制区域一帧；岛的按钮 = 暂停 + 截一帧 + 岛下打字 | 对齐：两者都调 `snap::run_in_take`（截图那位，snap-and-note §11）；这边给 `shoot(region)`：`record.py` 新命令 `snap-region:x,y,w,h`（用它自己的编号、写 shots/NNN.png + shots.jsonl 行 + events.jsonl `snap` via=picker、状态行 `snap`），`Capture::shoot_in_take` 等这条状态行，失败或 20 s 返回 None；录制结束 `island::refresh_cards` 让这些卡片下线 | 已做（*Windows 未验证*） |
| 5.9 | 录屏里看得见口喷鸡自己的窗口（主窗口、岛、卡片、备注气泡、截图流程、画笔）；只排除倒计时、录制框，以及「不录刘海」时的岛和字幕 | Windows 的浮层（岛、卡片、选择器、备注气泡、字幕）一律 content-protected，录不进去；主窗口能录进去 | 保留不同：Windows 上视频和截图都是同一种整屏抓取（gdigrab / ddagrab），浮层一旦可被捕获，录制中截图的那张静帧里也会带上选择器的暗罩和气泡；Mac 的 ScreenCaptureKit 能按窗口过滤，这里不能。所以录制中这些浮层仍不进视频 | 不变 |

## 6. 结束之后

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 6.1 | 完成：响一声 Submarine；岛的左耳红点原地变成 ✓ + 时长 1.6 s | 无声；岛直接回闲 | 对齐时刻，换成自己的声音：`sounds/rec-done.wav`（`build.py` 合成的低沉「啵咚」，520→470 Hz，0.6 s），每段保存下来的录屏（包括只保存视频）结束时响，录制已停所以不进视频。✓ 那一刻归岛那位：这边发 `{"op":"rec_done","length":"0:42"}` | 已做（岛的 ✓ 归岛那位；*Windows 未验证*） |
| 6.2 | `record.process` = 自动（默认）：马上整理，岛上一句「正在整理到 X / 通常约 N 分钟 · 完成后事项会显示在那里」+ 更改（移到…：项目选择器，选了 meta.json 立刻改，整理完后把这次的事项挪过去，再说「已移到 Y · 撤销」） | 总是整理，岛上不说 | 对齐：`capture/organize.rs`——估时照搬 OrganizeEstimate（Theil–Sen，≥3 次完整录屏的整理记录，从 `jobs` 读 started / ended 和 meta.json 的 duration）；「更改」→ 岛的切换器当选择器用（`{"op":"pick","title":"rec.move_to"}`，`island.ts` 小改：标题「移到」，选了发 `rec.move:<id>|<session>`）；`refile` 先改 meta.json，等这条录屏的 process 任务结束，再 `items.py move <batch.json 的 uids> --project 新 --from 旧`（用户自己挪过的不动），然后「已移到 Y · 撤销」（撤销 = 挪回去） | 已做（*Windows 未验证*） |
| 6.3 | 只保存视频：meta.json `video_only: true`，不整理，在 Finder 里选中视频，岛上「视频已保存 · 0:42\n未整理 · 已在访达中显示」+「在访达中显示」 | 无 | 对齐：Finder → 文件资源管理器（`explorer /select,`） || 已做（*Windows 未验证*） |
| 6.4 | `record.process` = 关：只保存；岛上「已保存 0:42」（刚说过 ✓ 就不再说），否则「录屏已保存 · 0:42」 | 无此设置 | 对齐：岛上「录屏已保存 · 0:42」（✓ 那一刻归岛那位，这边只发一句） || 已做（*Windows 未验证*） |
| 6.5 | 失败：有东西（截图、备注、能播的前半段）就留文件夹并在岛上说「录屏中途停止 / 录屏未保存」+ 原因 + 留下了什么 +「整理」；什么都没有就弹「录屏未保存」+ 原因 +「重新录」 | 只把任务标失败，用户什么也看不到 | 部分对齐：岛上「录屏未保存\n<原因>」+「重新录」（同一区域重来）；原因映射 `no_frames` → 未收到屏幕画面，其余 → 发生错误。做不到：留下半段视频（ffmpeg 引擎出错时分段没合成，`record.py` 已清掉），弹窗（岛就是 Windows 版说事的地方） || 部分 |
| 6.6 | 中途恢复：写入器失败换新文件、采集被系统停掉自动重启（每段最多 3 次，每次试 4 下，间隔 1 / 2 / 4 s；锁屏或睡眠时等着，最多 30 min）；显示器没了就以 display_gone 结束；结束时说丢了多少，或「前 3:12 已保留」 | 抓屏进程死了就结束这段（`warning`） | 对齐（ffmpeg 引擎）：抓屏进程自己退出时 `record.py restart_capture` 开新分段接着录（同样的 3 次 / 4 下 / 退避）；锁屏时（`OpenInputDesktop` 失败）等解锁，最多 30 min；区域所在的显示器没了（`MonitorFromRect`）多等几下，还没有就 display_gone；磁盘满不重试。这段 mkv 每 1 s 落一个 cluster（`-cluster_time_limit 1000 -flush_packets 1`，Mac 是 4 s mp4 片段），进程死了也能放到最后一秒。两段之间的画面和声音缺了，记进 meta.json（`recovered`、`lost_seconds`、`ended_early`）；岛上一句「录屏已保存 · 屏幕采集中断处缺少约 N 秒」或「录制的显示器已断开，前 3:12 已保留」。保留不同：Mac 的写入器失败换文件那一半 Windows 没有对应（ffmpeg 自己写文件，写坏了就是进程退出，走同一条路） | 已做（*Windows 未验证*） |

## 7. 实时字幕和实时识别

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 7.1 | 录制中 live.py 边录边转写（`live/transcript.jsonl`），边识别事项（`drafts.jsonl`，岛上「识别到 N 项」） | `record.py` 会起 live.py，但只用 PATH 里的 `uv`——App 装的 `~/.blurt/bin/uv` 不在 PATH，Windows 上从没跑起来 | 对齐：`record.py` 找 uv 和别处一样（PATH → `$UV` → `~/.blurt/bin/uv(.exe)`）。「识别到 N 项」归岛那位（这边在 state 里给 `spotted`） || 已做（*Windows 未验证*） |
| 7.2 | 字幕条：岛下面一行最近说的话（`record.live_caption`，默认开），最新的字在右（截头），出现 0.2 s 淡入、5 s 后 0.6 s 淡出；暂停时说完的一句等继续再显示；「录屏时不录刘海」打开时和岛一起不进视频 | 无 | 对齐：`capture.rs` 每秒读 `live/transcript.jsonl` 的新行，发岛 `{"op":"caption","text":…}`；画在岛的窗口里、岛的正下方（`island.ts` 小加一段，样式照 `CaptionPanel`）。岛窗口本来就 content-protected，所以字幕永远不进视频（Mac 默认是进的）——保留不同：Windows 的岛和字幕在一个窗口，没法单独让字幕进视频 || 已做（*Windows 未验证*） |
| 7.3 | 菜单「实时字幕」勾选 = 切换 `record.live_caption` | 无 | 对齐（托盘） || 已做（*Windows 未验证*） |

## 8. 系统声音

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 8.1 | `record.system_audio`（设置「录制系统声音」，默认关）：电脑播放的声音（通话对方、演示声）作为视频的第二条音轨；不录口喷鸡自己的声音；转写时分开，标出是谁说的 | 无 | 对齐：WASAPI loopback，不要装驱动——`cpal` 在默认输出设备上开输入流就是 loopback（`capture/sysaudio.rs`，cfg(windows)）。写 `<session>/system.pcm`（48 kHz 单声道 s16le）+ `system.json`（第一帧的墙钟时间）；没有声音播放时 WASAPI 不给数据，按墙钟补静音。`record.py --system-audio` 收尾时按每段视频第一帧的墙钟时间切出对应的一段，作为第 2 条音轨（`transcribe.py` 已经认第 2 条 = system） || 已做（*Windows 未验证*） |
| 8.2 | 不录口喷鸡自己的声音（`excludesCurrentProcessAudio`） | — | 做不到：loopback 录的是整个输出设备的混音；按进程排除要 Windows 10 2004+ 的 process loopback（`ActivateAudioInterfaceAsync`），cpal 没有。口喷鸡录屏时本来不出声（听写的提示音录屏时不响） | 不变 |

## 9. 设置（后端）

| # | 键 | 之前 | 处理 | 结果 |
|---|----|------|------|------|
| 9.1 | `record.process`（`auto` / `off`） | 不读 | 对齐（§6.2 / 6.4） || 已做（*Windows 未验证*） |
| 9.2 | `record.countdown`（0 / 3 / 5） | 不读 | 对齐（§3.1） || 已做（*Windows 未验证*） |
| 9.3 | `record.system_audio` | 不读 | 对齐（§8.1） || 已做（*Windows 未验证*） |
| 9.4 | `record.live_caption` | 不读 | 对齐（§7.2） || 已做（*Windows 未验证*） |
| 9.5 | `record.hide_notch` | — | 保留不同：Windows 没有刘海；岛本来就不进视频 | 不变 |

## 10. 改了哪些文件

- `skills/blurt/scripts/record.py`（ffmpeg 引擎）：`--countdown`（host 模式的倒数行、`go` / `stop` / `discard`）、开录前的
  `low_space` 行、抓屏命令提前算好、Windows 指针 / 点击轮询（`watch_pointer`）、`--system-audio` 收尾时切 `system.pcm` 进第二
  条音轨、`snap-region:` 命令、live.py 找 uv（`uv_bin`）。测试：`tests/test_capture_ffmpeg.py`（倒计时、取消、系统声音轨、
  `snap-region`）。
- `crates/blurt-capture/src/engine.rs`：`CaptureOptions.countdown` / `system_audio` → `--countdown N` / `--system-audio`。
- `apps/desktop/src-tauri/src/capture.rs`（录屏那几段）：读 `record.countdown` / `system_audio` / `process` / `live_caption`；
  `Control::VideoOnly` / `Go`、`Capture::restart` / `shoot_in_take`；状态行驱动倒计时、录制框、字幕；结束后的整理 / 只保存视频 /
  只保存 / 失败几种说法；录制中的截图走 `snap::run_in_take`。新文件 `capture/chrome.rs`（倒计时和录制框窗口）、
  `capture/sysaudio.rs`（WASAPI loopback）。
- `apps/desktop/src-tauri/src/island.rs`：`restart` 改调 `Capture::restart`，加 `videoonly`、`rec.*` 动作；倒计时期间不是录屏状态；
  state 带 `spotted`。`tray.rs`：录屏时的「只保存视频」「重新录屏」「实时字幕」。
- `web/apps/overlays`：新页面 `rec.html` + `src/rec.ts` / `rec.css` / `recgeom.ts`（测试 `tests/rec.test.ts`）；`island.ts` 的
  「···」加「只保存视频」、`caption` op 和字幕条（`island.css` 末尾 `.caption`）；`host.ts` 的 `caption` / `rec_done` op 类型。
- 第二轮（同一天）：`assets/sounds/build.py` 加 `rec-tick.wav` / `rec-done.wav`（`tests/test_sounds.py`）；`capture/organize.rs`
  （估时、更改 / 移到）；`capture/chrome.rs` 的 `sound`、`ink`；`web/apps/overlays/src/recink.ts`（录制中的画笔）；`hotkeys.rs`
  加 `pen` 和 `transient`（锁定时的 Esc）；`lib.rs handle_url` 问一句；`record.py` 的 `restart_capture` / `stroke:` / mkv cluster；
  `island.ts` 的 `pick` 和「···」的「画笔」。测试：`tests/test_capture_ffmpeg.py`（抓屏中断重启、锁屏时完成、画笔）、
  `tests/rec.test.ts`（strokePoints）、`organize.rs` 的估时测试。
- 文案：`web/apps/overlays/src/locales/*.json` 的 `rec.*`、`island.rec.video_only`、`island.rec.pen`；`apps/desktop/src-tauri/locales/*.json` 的
  `tray.video_only` / `tray.restart` / `tray.live_caption`。

## 11. 交给别人的

- 岛那位：`{"op": "rec_done", "length": "0:42"}`（完成那一刻的 ✓ + 时长，Mac 的 RecordingDone）还没画；state.recording.spotted
  （「6 张截图 · 识别到 4 项」）还没显示。
- 设置那位：设置 → 通用 → 录屏这几行现在都有后端了：`record.process`（`auto` / `off`）、`record.countdown`（0 / 3 / 5）、
  `record.system_audio`（Windows）、`record.live_caption`。
- 设置那位：快捷键 → 录屏时 那一节加「画笔」（`pen`，默认 Alt+Shift+D，`hotkeys.rs ACTIONS` 已加回）。
- 岛那位：打开的录屏岛上「按住使用画笔」那行提示（前 3 次）——Windows 是锁定用法，提示要改成「Alt+Shift+D 画笔」。


## 12. 2026-11-02 Windows dogfood 之后

截图：`promo/cases/dogfood-win-2026-11-02/capture/fixed/after-countdown-0.2s.png`、`after-pen-first-press.png`、`after-rec-island-pen-on-off.png`、`after-island-pen-demo.png`。

| # | 问题 | 处理 | 结果 |
|---|------|------|------|
| 12.1 | 第一次 Alt+Shift+D 画笔没反应：窗口刚建好就发 `{op:'ink', on:true}`，页面还没在听 | `chrome::ink` 建窗口时把 `on=1` 放进页面参数；倒计时、录制框、画笔三个窗口都记住最后一条状态，页面 `ready` 时再发一遍（`chrome::tell` / `LAST`） | VM：第一次按就能画，线在画面上 |
| 12.2 | 岛上看不出画笔开着 | 开着时右耳是薄荷色铅笔（代替电平表）；打开的录屏岛下面一行：开着「画笔已开 · Esc 关闭画笔」，关着且是前 3 次录屏时「Alt+Shift+D 画笔 · 拖动手绘 · Shift 方框 · Alt 椭圆」（次数存在岛页面的 localStorage） | VM 实测 |
| 12.3 | 按「开始录制」后 ~1 s 什么都没有，倒计时等 record.py 第一行才出来 | 选好区域、起 record.py 之前就打开倒计时窗口（`n = record.countdown`），record.py 的倒数行只往下翻数字；起不来时关掉 | VM：0.2 s 时倒计时已在 |
| 12.4 | 录屏中打开 / 悬停岛，所有旧卡片掉下来盖住录制区域 | 录屏或语音备注进行中，卡片只在明确要看（点耳朵上的数、Alt+Shift+H、菜单）或拖动时下来；开始录屏时清掉之前的「下来一会儿」 | VM：录屏中打开岛，卡片没下来 |
| 12.5 | 「现在开始」是实心薄荷按钮 | 改成岛的安静薄荷小胶囊（薄荷 20 % 底、薄荷字） | 页面里看过 |
| 12.6 | 录屏的几行（已保存、正在整理到…、失败、磁盘快满）带麦克风图标 | 改发 `kind: 'capture'`（见 snap-and-note.md §12.5） | VM 实测 |

## 13. Capture area r1（2026-11-02 visual gate）

- 倒计时：组合键拆成一个个小键帽（[Alt][Shift][P]），说明 12.5 px 70 % 白；「现在开始」28 px 高 13 px；卡片多一层 40 px 的软阴影。
- 录屏中不出能等的岛上消息（默认项目的问题等）：见 island.md §12 的 `busy` / `parkWaiting`；岛在倒计时、录屏框、画笔窗口之上（`chrome::island_on_top`）。
- 画笔：指针的圈只在指针真的移进来以后出现（不再停在窗口左上角）；笔画多一道向下 1 px 的阴影。
- 「正在整理到 X」行首是 X 的文件夹（不是 ✓）。

## 14. Capture area r2（2026-11-03 视觉评审第 2 轮）

- **倒计时的数字慢一秒**：评审的截图 1.3 s 还是 3、2.3 s 才 2。数字原来只在 record.py 的倒数行到了才翻，第一行要等 record.py 起来（约 1 s）；圆环的动画又靠 `requestAnimationFrame`，WebView2 不给帧时什么都不动。现在倒计时有自己的钟：窗口打开那一刻是第 0 秒，数字 = 总数 − 过去的整秒（最少到 1，停在 1 等录制真的开始、Rust 关窗口）；圆环有帧时逐帧走，另有 100 ms 的计时器保证数字按秒翻；record.py 的行只在它比钟快时把钟往前拨，从不让数字倒回去。浏览器里量过：0.3 / 1.3 / 2.3 s 是 3 / 2 / 1（`rec.ts` runClock）。
- 录屏结束 ✓ 那一刻：见 island.md §13。
- 没有在 Windows 上重拍（VM 已释放）。

