# Windows 对齐审计：听写与语音备注

对照的是 Mac 版（规格）：`Capture/Dictation/*`、`VoiceInput.swift`、`LiveAudio.swift`、`LiveFeeds.swift`，以及 BlurtCore 的
`DictationTakeFlow`、`DictationASRLine`、`DictationPastePolicy`、`DictationSendRule`、`DictationAccess`（FnClash）、
`DictationStyle`、`IslandToasts`、`NothingHeard`、`VoiceNoteStyle`、`CaptureRules`（VoiceKeep / VoiceDiscard）和它们的测试。
`AppleSpeech.swift` 是 Mac 自带识别器，不适用。

「Windows 之前」= 本分支 2026-11-02 审计开始时的 `apps/desktop/src-tauri/src/dictation/*`。
处理：**对齐**（照 Mac 做）/ **保留不同**（Windows 的惯例或系统能力不同，写明原因）/ **做不到**。
纯规则都移植成平台无关的 Rust 模块，测试照搬 Mac 的（`cargo test --lib` 在 Mac 上跑）：

| 模块 | 来自 Mac | 内容 |
|---|---|---|
| `dictation/flow.rs` | DictationTakeFlow、DictationASRLine、DictationSendRule、DictationFnClash、DictationToastKeys、NothingHeard | 跑飞的免手持、首几次提示、识别失败的说法、截止时间、送达那一行、复制后的双击、保留文字的预览、双击才发送、其他听写软件、岛上的 key |
| `dictation/rehear.rs` | DictationStitch.closesWindow / rehearGroups、DictationStream §Hearing again | 重听窗口（≤ 20 s） |
| `dictation/context.rs` | DictationContext | 光标前后 500 字、给识别的 300 字 |
| `dictation/apps.rs` | DictationAppCategory、polishVariant | 按 exe 的 App 类别、终端 / 聊天变体、Typeless / Wispr Flow 进程名 |
| `dictation/prefs.rs` | Dictation.swift 的设置读取、DictationSound、DictationStyle(Config/Router) | `record.dictation.*`、取消键、风格 |
| `dictation/voice_rules.rs` | LoneShift、VoiceNoteStructure、VoiceKeep、VoiceDiscard | 语音备注的结构化、丢弃与撤销 |
| `dictation/words.rs` | DictationVocabulary 的编辑 | 词库增删改 |
| `dictation/fit.rs` | DictationFit（+ Dictation.fit 的清单规则） | 光标处的衔接 |
| `dictation/learn.rs` | DictationLearn.EditWatch / locate、DictationReformat.span | 改字后学新词、重排时找回原文 |
| `prefs.rs` 的 `remember` | DictationRemember | 按 App 记住结构化 / 翻译 |
| `flow.rs` 的 `speech_models`、`CloudReminder` | DictationSpeechModels、DictationCloudReminder | 「下载…」拿什么（云端模型缺 Key → 设置）、较弱模型提醒、云端润色提醒 |
| `dictation/style_learn.rs` | DictationStyleLearn、DictationReformat.reverted | 从用户的操作学风格，问一次 |
| `cloud.rs` 的 `volc_split` | VolcengineSpeech.split | 火山的 App ID + Access Token |

## 键与开始 / 结束

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 1 | 键：Fn / 右 Option / 任一 Option | 右 Alt / 任一 Alt，只在启动时读 | 保留不同：Windows 读不到 Fn，键是右 Alt / 任一 Alt（同一个配置值 `right_option` / `either_option`）。对齐：设置改了立刻生效（`prefs.rs`，配置文件变了就重读；Mac 的 `reloadIfChanged`），正在听的那段键变了就当键抬起结束（`keyChangeEndsTake`），方式变了等这段结束再换 | 已做 |
| 2 | 方式：自动 / 按一下 / 按住 | 有 | 对齐（同上，热更新） | 已做 |
| 3 | 按两下发送（`double_tap_send`），只在刚输入过一段、且还是那个 App 时按回车（DictationSendRule，60 s） | 写死开；任何时候都按回车 | 对齐 | 已做 |
| 4 | Esc 取消正在听的一段，听的时候 Esc 不传给前台 App（系统热键） | 取消，但 Esc 也传给了 App | 对齐：听的时候钩子吞掉 Esc（`keys_win::ESC_DICTATION`），停了就还给 App | 已做 |
| 5 | 取消键：Esc / ⌃Esc / ⇧Esc（`cancel_key`） | 只有 Esc | 对齐：Esc / Ctrl+Esc / Shift+Esc；不是取消键的 Esc 对触发器只是普通键，钩子也不吞 | 已做 |
| 6 | 路上的一段（识别 / 润色中）按 Esc 停下，不输入，「已取消 · 撤销」5 秒，录音留到那时 | 直接丢掉，wav 永远留着 | 对齐：撤销 = 整段录音重听再输入（Mac 的 retry）；还在粘贴队列里的直接放回；5 s + 1 s 后删 wav | 已做 |
| 7 | 正在润色时 Esc：不等润色，按原话输入（「还在润色… Esc 不润色直接输入」） | 无 | 对齐（润色请求的 give_up） | 已做 |
| 8 | 按住说话的第一秒里别的键加入 = 快捷键，安静取消（`joinedEarly`） | 有「已取消」 | 对齐 | 已做 |
| 9 | 按住模式按了一下 / 按一下模式按住：说怎么用（按住模式每天一次，等双击窗口过去） | 无 | 对齐 | 已做 |
| 10 | ⇧ 双击结构化、⌘ 双击翻译，单击 / 双击可设（`modifier_tap*`） | 写死双击（⇧ / Ctrl） | 对齐（读设置）；⌘ 对应 Ctrl（Windows 快捷键在 Ctrl 上） | 已做 |
| 11 | Fn 不让 macOS 抢（`fn_capture`） | — | 做不到：没有 Fn | 不变 |
| 12 | 权限：输入监控 / 辅助功能引导，岛上每天提醒 | 无 | 保留不同：低级键盘钩子不需要权限，装不上只记日志 | 不变 |
| 13 | 两个口喷鸡同时运行时只有一个听键 | 未查 | 未做（Windows 版是否允许多开没查） | 待查 |

## 收音

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 14 | 按下键就开麦（预录），压成快捷键就关 | 有 | — | 已有 |
| 15 | 麦克风：`builtin_mic`（默认输入是蓝牙时用 Mac 自带的） | 系统默认输入 | 保留不同：Windows 认不准「自带麦克风」，改成按名字选（`record.dictation.mic`，不设 = 系统默认；那个设备拔了退回默认）。`dictation_mics` 命令列出设备给设置页 | 后端已做（设置页那位接 UI） |
| 16 | 提示音：开始的开（`sounds`）、结束和取消的关（`stop_sound`）；录屏时不响 | 一个 `sounds` 开关管全部，结束音默认响 | 对齐（两个开关，Mac 的默认） | 已做 |
| 17 | 开始音等第一帧声音到了才响 | 键一按就响 | 对齐 | 已做 |
| 18 | 没听到：说用的哪个麦克风；麦克风一直没声音时说「X 没有声音」；「换麦克风…」 | 「未检测到语音」 | 对齐（`nothing_heard`；按钮打开 设置 → 听写 → 麦克风，`nav` 的 `dictation/mic`） | 已做 |
| 19 | 麦克风打不开：「麦克风不可用」/「未获得麦克风权限 · 打开设置」 | 「无法打开麦克风」 | 对齐：读 Windows 隐私开关，拒绝时按钮打开 `ms-settings:privacy-microphone`，否则「麦克风不可用 · 声音设置」（`ms-settings:sound`） | 已做 |
| 20 | 免手持没人停：20 s 没说话「还在听 · 按 键 结束 · Esc 取消」，4:30 起时钟倒数（注意色），5 分钟到点说出来，之后 4 s 内那一下是停止 | 只有 5 分钟上限 | 对齐（`flow::Runaway`；岛上的倒数在 `island.ts` 的 `dictClock`） | 已做 |
| 21 | 录屏时、语音备注时听写不可用 | 只拦录屏 | 对齐 | 已做 |
| 22 | 只听我的声音（声纹） | 无 | 对齐：识别服务按 `record.dictation.only_my_voice` 自己读（请求带 `purpose: dictation`），所以设置一开就生效；录声纹的界面归设置页那位；声纹模型在 Windows 上能不能跑没验证 | 未验证 |

## 文字

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 23 | 说话时按停顿切片、边说边识别 | 有 | — | 已有 |
| 24 | 重听：片段再按窗口听一遍（Mac 按模型 10/20/30 s），打出来的字来自窗口 | 无 | 对齐，但窗口 ≤ 20 s：Fun-ASR-Nano 最多解码 512 token（约 25 s 带词表）。Mac 是「跨过窗口长度就关」，会超长；这里跨过 10 s 就在停顿处关，下一片会超 20 s 就在它前面的停顿关；从不在硬切处关（窗口不共用音频）。抬键时剩下的那个窗口连最后一片一起听；窗口失败用片段的字，最后一片只在失败的窗口里 → 整段重听。语音备注同样（`record.voice.rehear`）。`record.dictation.rehear` / `rehear_window_s` 可关 / 可改短 | 已做（抬键后延迟没在 VM 上量） |
| 25 | 说话时的临时字（每秒解码一次正在说的那片） | 无 | 保留不同（暂时）：CPU 上的 Fun-ASR 每秒重解码太贵，要先找便宜的路 | 不变 |
| 26 | 第二份转写（Mac 识别器）给云端润色 | — | 做不到：没有 Mac 识别器 | 不变 |
| 27 | 云端识别（Qwen3-ASR Flash 整段、火山流式） | 无 | 对齐 Qwen3-ASR Flash、OpenAI 兼容服务、火山 Seed-ASR 2.0：同一个 `transcribe.py serve`，Key 从凭据管理器进识别服务的环境变量（只给 transcribe.py，`cloud::speech_env`；火山存成一条 `<App ID>:<Access Token>`，和 Mac 同；连 / 断服务时服务重启）。Qwen / OpenAI：不切片、不重听，抬键后整段一次，带光标前的字。火山：说话时就把麦克风的 PCM 推给服务的 `stream`（`server::Stream`，开头一行等光标前的字最多 0.4 s），抬键只剩最后一块；连不上就退回整段一次。保留不同：说话时没有字——`stream` 的协议只在最后回一行（Mac 的实时字来自它自带的识别器，Windows 没有） | 已做（火山预设由设置那位加，未在 VM 上验证） |
| 28 | 光标前的字：识别拿 300 字，润色拿前后 500 字 + 窗口标题；密码框从不读 | 无 | 对齐：UI Automation（TextPattern，退而 ValuePattern）在开始时读，`record.dictation.context` 可关；历史里不存 | 已做 |
| 29 | 终端变体（命令还是命令）、聊天变体 | 无 | 对齐：按 exe 认 Windows Terminal、PowerShell、cmd、conhost、WezTerm、Alacritty…；微信、QQ、企业微信、钉钉、飞书、Slack、Teams… 是聊天 | 已做 |
| 30 | 风格：原话 / 轻整理 / 结构化 / 自动，按 App > 类别 > 默认（`styles`），⇧ 切到结构化再切回 | 只有润色开关 + ⇧ | 对齐（`prefs::Styles`；结构化走云端的 structure，自动只在排成清单时用）；Windows 没有本机润色模型，所以结构化 / 自动 / 轻整理都要连了云端服务 | 已做 |
| 31 | 按 App 记住 ⇧ / ⌘ 的切换（`learn_styles`），前三次说一句；隔一小时再用时提醒「沿用上次的设置」；换了 App 的那段不记。学风格：⇧ / 岛上切换、重排保留或撤销、清单被拆开、「这条像清单」没理会，各算一次；同一 App 最近 10 次里 ≥ 3 次且 ≥ 70 % 一致 → 问一次「以后在 X 里自动排成清单？」（12 s，不答 = 不） | 无 | 对齐（`prefs::remember`、`style_learn.rs`）。保留不同：Mac 从历史记录的风格字段读这些信号，Windows 单独存 `dictation/style_signals.json`（历史行的 `style` 在 Windows 的听写页是个字符串） | 已做 |
| 32 | ⌥L 换风格重排刚输入的一段：原话 → 轻整理 → 结构化，原文没动过就在输入框里替换（5 分钟内），否则复制；撤销；路上的那段按了就等它输入完；提示 | 无 | 对齐：Alt+Shift+L（`hotkeys.rs` 的 `reformat`；UIA TextPattern 选中原文——选中后读回必须一字不差，否则复制）；首几次提示里的这一条回来了。「这条像清单 · 排成清单」：按轻整理输入、可能含清单的一段，粘贴后在后台跑结构化，排出 ≥ 2 行清单才出（`suggest_lists`）。用户改过原文：照 Mac 的规则——找得到改后的那段就按新风格重新过一遍（轻整理：润色；结构化：结构化；原话：原样）再复制，输入框不动（「已按 X 复制修改后的文字」）；找不到就复制原听写的那个风格（「文字已修改，已按原始听写排成 X 并复制」） | 已做 |
| 33 | 本机润色模型（MLX） | — | 做不到（docs/design/windows-models.md） | 不变 |
| 34 | 光标处的衔接（DictationFit：重复的字和标点、句中小写、空格；清单另起一行，清单项后另起一段） | 无 | 对齐（`fit.rs`，测试照搬；粘贴前读输入框前后 500 字，读不到就原样） | 已做 |
| 35 | 词库：每个请求带词，润色当拼写提示 | 发了，但「已拒绝 / 建议」的词也给了润色 | 对齐：只用 active 的词；`dictation_words` / `dictation_words_edit` 命令（加、删、改名、接受 / 拒绝建议、"a, b, c" 一次加多个）给设置页 | 后端已做 |
| 36 | 改字后学新词（DictationWatch / Learn）：输入后一分钟每 1.5 s 读一次，结束时（时间到 / 焦点走了 / 文字没了 / 下一段）学一次；「记住了“X” · 撤销」 | 无 | 对齐（`learn.rs` + UIA；修正规则用 `dictation_vocab.py learn --suggest`，和 Mac 的 DictationLearn 同一套）；重排替换掉的不学。只记前后 40 字找回原文，结束就丢 | 已做 |

## 路上的一段

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 37 | 停了马上能开下一段，按说的顺序输入 | 有 | — | 已有 |
| 38 | 停了 3 s 还没好：「还在识别… Esc 取消」/「还在润色… Esc 不润色直接输入」，好了就收 | 无 | 对齐（key `dictation.slow`） | 已做 |
| 39 | 永远不会一直等：抬键后最多 45 s + 音频的一半（≤ 180 s），然后「语音模型无响应 — 录音已保留 · 重试」 | 无（片段可能等 90 s × 片数） | 对齐（`TakeDeadline`；单个请求的超时也按音频长度：15 + 1.5×） | 已做 |
| 40 | 服务卡死：没 CPU 就结束 | 有（server.rs） | — | 已有 |
| 41 | 识别失败：留录音、历史里一行、岛上按原因说（Key 无效 → 设置…；连不上 / 额度 / 太慢 / 其他 → 重试）；没模型：「下载…」（缺什么下什么：DictationSpeechModels.toGet），下载中「查看」，下完后那段「语音模型已就绪 · 重试」 | 说「未检测到语音」，留了历史 | 对齐（`AsrLine`、`speech_models::to_get`、commands.rs 下完后 `model_arrived`）；按键时没模型也给「下载…」 | 已做 |
| 42 | 有片段失败：整段录音再听一次；确定的错误（没模型、Key、仅本机）不再试 | 失败的片段直接空着输入 | 对齐 | 已做 |

## 输入

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 43 | 粘贴进粘贴时在前台的 App（2026-10-31：在 A 说要打到 B），双击的回车跟过去 | 只粘进开始时的 App，换了就复制 | 对齐 | 已做 |
| 44 | 粘贴落地：读回输入框，看到字了才按回车（最晚 0.6 s），再过 0.15 s 还原剪贴板；读不到的 0.6 s / 1.5 s | 固定 0.6 s / 1.5 s | 对齐：UI Automation 每 30 ms 读一次（TextPattern / ValuePattern，最多 2 万字） | 已做（VM 未验证） |
| 45 | 一行说清结果：已复制 / 已复制，未发送 / 未发送 / 已粘贴 · 再复制一次 / 未找到输入框 · 文字如下 · 复制 / 密码框 · 复制 | 只有「已复制」「密码框」 | 对齐（`DeliveredLine`）。保留不同：「未找到输入框」在岛上留 60 s 而不是一直留、没有「关闭」第二个按钮（岛上一行只有一个按钮），下一段开始就收 | 已做 |
| 46 | 刚复制完 15 s 内没按过键就双击：不按回车，说「已复制，未发送」 | 无 | 对齐（`CopiedGuard`） | 已做 |
| 47 | 结构化没排成清单：「无法排成清单，已保留原文」 | 无 | 对齐 | 已做 |
| 48 | 以管理员身份运行的窗口（UIPI）收不到按键 → 复制 | 有 | 保留不同：Windows 才有 | 已有 |
| 49 | 没给辅助功能 → 只能复制，说为什么 | — | 不适用（Windows 发按键不需要权限） | 不变 |
| 50 | Electron 的无障碍树要先叫醒（AXManualAccessibility） | — | 保留不同：Chromium 在有 UIA 客户端查询时自己打开；开始时读光标前文字那一下就会叫醒。未验证 | 未验证 |
| 51 | 停后在实时字幕里显示实际输入的字 1.5 s | 有 | — | 已有 |

## 输入之后

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 52 | 首几次的提示（聊天 App 里「按两下 键 发送」5 次，别处「说话时双击 ⇧，排成清单」1 次），用过就不再说，不盖住别的话 | 无 | 对齐（`Tip`，计数在 `app.dictation_tips`，和 Mac 同一个键） | 已做 |
| 53 | Typeless / Wispr Flow 也在跑：每天每个 App 说一次，不在正在听的时候说（听完再说），「改用右 Option」 | 无 | 对齐时机（`Clash`）。保留不同：Mac 只在键是 Fn 时说，Windows 没 Fn，它们的键自己能改，所以只要在跑就说「X 也在运行，文字可能输入两次」；没有「换键」按钮（右 Alt / 任一 Alt 都可能撞）；在启动时和每段开始时查进程，不监听它们启动（Windows 要 WMI）。进程名 Typeless.exe / Wispr Flow.exe 未在真机核对 | 已做（进程名未验证） |
| 54 | 每天一次的提醒：润色模型没有、云端 Key 被拒、跑的是较弱的识别模型；10 段后提醒一次云端润色 | 无 | 对齐：云端润色 Key 被拒（设置…）、较弱的识别模型（下载）、10 段后一次「添加云端模型」（设置…）。保留不同：没有「润色模型没下载」——Windows 没有本机润色，没连服务就是那条云端提醒 | 已做 |
| 55 | 保留录音（`keep_audio`，默认开） | 总是保留 | 对齐（关掉时输入完就删；失败的那段留着给重试） | 已做 |
| 56 | 历史记录各字段 | 有 | 多记 `windows`、`variant`、`context_used`、风格名 | 已做 |

## 语音备注

| # | Mac | Windows 之前 | 处理 | 结果 |
|---|-----|-------------|------|------|
| 57 | 听的时候双击 ⇧（或岛上的「结构化」）切结构化；结束后走结构化，卡片的字是整理后的，原话存 `said_raw` | 无 | 对齐（`LoneShift`；岛上的按钮发 `voice.structured`）；只在连了云端服务时整理，否则留原话 | 已做 |
| 58 | Esc 丢弃（前 10 s）：说过话的 → NNN.discarded.wav 等 5 s，「语音备注已丢弃 · 撤销」 | 直接删 | 对齐（撤销时整段重听再存卡片；退出 / 崩溃留下的 discarded 文件下次录时清掉） | 已做 |
| 59 | 用户结束了但什么都没听到：「未检测到声音 · 留下」 | 存一张没字的卡 | 对齐（`VoiceKeep`：太短 / 数字静音直接丢，有声音就问） | 已做 |
| 60 | 片段重听（10 s 窗口） | 无 | 对齐（10–20 s，同 #24） | 已做 |
| 61 | 只在前 10 s 吞 Esc | 有 | — | 已有 |

## cfg(windows) 改动（要在 Windows VM 上编译和测）

在 Mac 上用 `cargo check --target x86_64-pc-windows-msvc`（假 cc / ar）类型检查通过，没有运行过。

- `dictation/engine.rs`：基本重写——上面的取消 / 撤销、慢提示、截止、重听窗口、整段重听、失败与重试、粘贴落地、送达一行、
  复制后的双击、提示、其他听写软件、设置热更新、取消键、麦克风选择、风格、保留录音；岛上的按钮走 `island_action`。
- `dictation/insert_win.rs`：`focus_read`（UIA：密码框、是不是输入框、TextPattern / ValuePattern 读字和选区，500 ms 超时）、
  `field_text`、`window_title`、`running_exes`（EnumProcesses）。
- `dictation/keys_win.rs`：`ESC_DICTATION`、`CANCEL_MODS`、`held`。
- `dictation/mic.rs`：`Mic::open_named`（按名字选设备）。
- `dictation/voice.rs`：结构化、丢弃 / 留下、重听窗口、`key` 代替 `esc`、`toggle_structured`、`unpark`。
- `capture.rs`：Windows 的 `voice_start` 处理新的 `End`、`voice_filed`、`voice_undo`、状态里的 `structured`。
- `island.rs`：`dictation.*`、`voice.undo:*`、`voice.structured` 三个动作。
- `dictation/commands.rs`：`dictation_mics`（cpal）、下载完成后 `engine::model_arrived`；另外修了 `dictation_use` 会把整个 `record.dictation` 冲掉的问题（合并只有两层）。
- 第二轮：`engine.rs` 加了重排（`reformat_last`、`replace_last`）、改字学词（`start_watch`）、记住切换、每天一次的提醒、云端整段识别、开始音等声音、衔接；`insert_win.rs` 加了 `select_range`；`lib.rs` 的 `dispatch` 加了 `reformat`。平台无关的：`hotkeys.rs` 的 `reformat`（Alt+Shift+L）、`server.rs` / `scripts.rs` 给 transcribe.py 的环境变量（`run_env`）、`cloud.rs` 的 `speech_env`。
- 第三轮：`engine.rs` 加了火山流式（`stream_take`）、「这条像清单」（`list_chip`）、学风格（`style_signal`）、改过的文字重新排版后复制（`Replace::Edited`）、云端模型缺 Key 时的「设置…」（`model_action`）。平台无关的：`server.rs` 的 `Stream`（`stream` 命令的客户端）、`cloud.rs` 的火山（`volc_split`）、`style_learn.rs`。

## 要在 VM 上验证的

1. 重听窗口打开后抬键到出字的延迟（Fun-ASR-Nano int8，20 s 窗口最坏情况）；太慢就把 `rehear_window_s` 默认改小。
2. UIA 读回：记事本、Word、Chrome 的 textarea / contenteditable、微信、Windows Terminal 各粘一次，看 `confirmed` 和回车时机。
3. 「未找到输入框」：桌面、资源管理器的文件列表上听写（应保留文字 + 复制）；微信的输入框不应误报。
4. 取消键 Ctrl+Esc：Claude Code 里按 Esc 不应取消，Ctrl+Esc 取消且不传给终端。
5. Typeless / Wispr Flow 的进程名。
6. 改键 / 方式不用重启；听的时候改键会结束那一段。
7. 声纹（只听我的声音）在 Windows 上能不能跑。
8. Alt+Shift+L：记事本 / Word / Chrome 里替换（UIA 的「字符」单位和 UTF-16 对不上时会退成复制）；微信里应复制；先改一个字再按，应复制改后的文字。
9. 改字学词：在记事本里把刚听写的一个词改掉，一分钟后应出「记住了“X”」。
10. 云端识别：连 Model Studio，选 Qwen3-ASR Flash（模型页），听写一段，看历史的 `asr_model`；火山：抬键后到出字应在 1 s 左右（流式），服务的日志里有 `stream`。
11. 选了云端模型但没 Key 时按键：「听写需要语音模型 · 设置…」应打开 设置 → 语音服务。

## 11-02 第三轮（细节）

- 听写页标题左边不再放图标（和全部事项等列表标题一致；Mac 的标题在工具栏里，也没有图标）。
- 「发送反馈」和 Mac 的 LabBarButton 一样：纸飞机 + 「发送反馈」（不加省略号），12px 正文色，悬停一层淡底。
- 侧栏、设置、存储、命令面板里「听写」的图标是 `character-cursor`（Mac 的 character.cursor.ibeam）；没有记录时的空状态是 `align-left`
  （Mac 的 text.alignleft）。

## 11-02 Windows dogfood：听写的修复（VM 47.99.0.55 上复测）

dogfood 的发现在 `promo/cases/dogfood-win-2026-11-02/dictation/`（修复前的截图在 `shots/`，修复后的在 `fixed/`）。

| 发现 | 改法 | 复测 |
|---|---|---|
| 「未找到输入框」之后双击：在桌面 / 资源管理器里按了回车，岛上说「已发送」 | 没找到输入框的一段不算「输入过」（`last_paste` 不记），记成和复制一样要拦住回车（`copied_at`）；双击就说「未发送：光标不在输入框中 · 复制」（`no_field_take`） | 桌面、资源管理器各一次：没按回车，出这一行 |
| 资源管理器的文件被当成输入框（✓，字丢了） | `focus_read` 先看控件类型再看 ValuePattern 可不可写：文件和桌面图标是可写（改名用）的 ListItem。外加 `SHELLDLL_DefView` / `SysListView32` / `UIItemsView` 的空白处 | 日志：`type 50007 class "UIItem" writable Some(true) → editable Some(false)`，出「未找到输入框」 |
| 经典记事本读不到光标：衔接不生效，⌥L 重排总是复制 | 记事本的 Edit 在 UIA 里**没有 TextPattern**（VM 实测 `text_pattern false`），只有 ValuePattern。读不到光标时退到 Win32：`GetGUIThreadInfo` 找焦点窗口，类名是 `Edit` 就用 `EM_GETSEL` / `WM_GETTEXT`（偏移按 `\r\n` 算，和 Edit 自己一致）；重排选中用 `EM_SETSEL`，选中前先核对那段字一字不差 | 「我知道你就是▮的。」+「从老家回来」→「我知道你就是从老家回来的。」（之前是「…回来。的。」）；⌥L：「已重排为原话 · 撤销」，0.98 s，在记事本里原地替换 |
| Fun-ASR-Nano 重复循环（6 s 打出 2,123 字，双击还发出去了） | ① 识别器建的时候 `max_new_tokens`（第二轮改成 `32 + 8 × 20 = 192`，见下）（导出的上限是 512；说话每秒不到 8 个 token，20 s 一片要 ~160）；② 字数超过 `30 × 秒数 + 40` 就算循环：同一段连着出现 ≥ 4 次只留一次（`collapse_repeats`，只比字符，不理解内容），还超就在停顿处切两半重听；③ 引擎里同一个字数上限（`flow::SpeechLoop`）挡住双击发送：「未发送：语音模型重复输出了同一段」 | 单元测试（循环在 VM 上没复现出来）；VM 的 sherpa-onnx 有 `max_new_tokens` 参数 |
| 安静房间的底噪变成一句编出来的话 | `transcribe_track` 的整片路径（Fun-ASR、Mac 的 FunAsrMlx 也一样）先问 VAD 有没有语音，没有就不解码。只用来判断，片段本身照旧整片送，不裁边 | −55 dBFS 噪声：「未检测到语音（test wav）」，不打字，不记历史 |
| 没连云端服务时 Ctrl-Ctrl / Shift-Shift：照样打原话，还记成「在记事本中保持翻译」 | 按的时候就说「翻译需要云端模型 · 设置…」/「切换风格需要云端模型 · 设置…」，不切换。Mac 的说法是「需要云端模型或本机润色模型」，Windows 没有本机润色模型，所以只说云端。记住切换只记真的生效的：翻译了才记翻译，排成了清单才记结构化。翻译失败按原因说（Key 无效 / 额度 / 连不上 / 失败），请求带 `check: true`，和 Mac 一样 | 岛上出这一行（耳朵还在上面），`record.dictation.translate` 没写 |
| 首次按键等 ~18–20 s（没有预热） | 启动时如果听写开着、本机模型在、选的不是云端模型，就启动识别服务并预加载（Mac 也预热）。CPU 模型的服务空闲一小时才退（`_common.CPU_SERVE_IDLE`，只在 pro / standard 档；Mac 还是 10 分钟），重新加载约 17 s。真在加载时，3 s 后的那一行改说「正在加载语音模型，约 20 秒… Esc 取消」 | 启动后 4.4 s 服务就绪（文件缓存是热的）；第一段识别 1,759 ms、总共 3,734 ms（之前 17,653 / 19,878 ms） |
| 云端润色连不上：没有任何提示，历史里原因写成 `model_missing` | 轻整理的请求也带 `local_fallback: false`，polish.py 直接回云端的错误码；历史里的原因是 `cloud_network` 等。一小时最多说一次「无法连接云端润色，输入了原话 · 设置…」（额度用完另一句）；结构化那一段如果是因为连不上，就说这个原因，不说「无法排成清单」 | 代理拒绝连接：第一段出这一行，第二段不再出；历史 `reason=cloud_network` |
| 下载语音模型失败没有任何提示，按钮也不写大小 | 「下载（950 MB）」，「正在下载语音模型（950 MB）· 完成后按右 Alt 听写」，下载中按键说进度「（412 MB / 950 MB）」；失败说「语音模型下载失败 · 重试」（commands.rs 失败时通知引擎，stderr 的最后一行进日志和 `model-download` 事件） | 新的 BLURT_HOME 加代理拒绝：先出下载那一行，1 s 后出「下载失败 · 重试」 |
| 听的时候出任何一行，耳朵就没了（倒数、时钟看不见） | 听写正在听时，那一行放在耳朵下面（`ears-toast`：岛高 = 30 + 那一行，宽取两者大的，圆角 22），和 Mac 一样 | 翻译 / 结构化提示的截图：Peep、波形、标记、时钟都在 |
| 出现风格标记后时钟被切掉 | `.pill-in` 加上 `flex: none`：它是 flex 子项，岛还在变宽时会被压窄，量出来的宽度少了右边 14 px 的内边距 | 0:03 加清单标记：右边留 14 px |
| 岛上每一行都用麦克风图标；「已发送」是一行 | 标记照 Mac 的做：失败 / 需要处理的用警告三角，复制、学会了这类完成的用 ✓，其余不加（`toast_keys::mark`）。「已发送」改成耳朵里的一瞬：左边键盘，右边 ✓ + 字，1.6 s | — |
| 应用名显示成 exe 名（「在 notepad 中保持结构化」） | 用 exe 版本信息里的 FileDescription（`GetFileVersionInfoExW(FILE_VER_GET_LOCALISED)`，系统程序有 MUI，所以记事本是「记事本」），历史里也存成 `app_name`；听写页先用它，旧记录在中文界面下也用中文名 | 「在 记事本 中保持翻译」，听写页显示「记事本」 |
| 听写页：Ctrl+Z 撤不回删除；详情里写的是模型 id | 听写页在捕获阶段先处理 Ctrl+Z（App 的事项撤销也挂在 window 上，以前它先拿到）；模型名从 `dictation_models` 和 `cloud_curated` 取：「Fun-ASR-Nano (CPU)」、「DeepSeek V4.1 Flash」 | 删一条 293 → Ctrl+Z → 294 |
| 点岛上的按钮（撤销 / 复制 / 下载…）后岛展开、卡片盖住刚打的字 | 点了以后，鼠标从点的位置真的移开（> 12 px）之前，岛不因为悬停展开 | 点「复制」3 s 后岛没展开 |
| 打出来的字面板和下面那一行重叠；✓ 单独换行 | 面板只往下让、不往上跳；✓ 和最后几个字连在一起换行。找不到输入框的那段不显示带 ✓ 的面板（那一行已经把字留着了） | — |
| 「Typeless 也在运行」被别的行顶掉后又回来 | 已经显示过 1 s 以上的听写提示，被新的一行顶掉就不再回来 | 未在 VM 上测（没装 Typeless） |
| 第一、二次 Shift-Shift / Ctrl-Ctrl 没有说明 | 照 Mac：前两次说「结构化：结束后排成清单 · 再双击 Shift 切回」/「已开启翻译：中文 ↔ English · 再双击 Ctrl 关闭」（计数 `style_hint_shown` / `translate_hint_shown`） | 截图 |

### 第二轮（对照 Mac 再补）

| 发现 | Mac 怎么做 | Windows 现在 | 复测 |
|---|---|---|---|
| 终端里的短命令不润色（「git status」→「get status」） | 一样不润色：`DictationStitch.nothingToPolish`（少于 3 个词 / 字）直接跳过，和 polish.py 的 `short` 同一条规则。但 Mac 给识别模型的请求带 `app`（前台 App 的名字，排在词表最前）和 `hint`（窗口标题 + 光标前后 300 字，只用来决定词表里哪些词排前面） | 照做：跳过的规则不变；识别请求补上 `app`（Windows 的显示名，如「Windows PowerShell」）和 `hint`（`Context::hint`，标题 + 光标前后 300 字），火山流式的 `app` 也改成显示名。保留不同：Fun-ASR-Nano（CPU）的热词是建识别器时定死的，换一组词就要重建（CPU 上约 3 s），所以它不把 App 名放进词表（`app_hint = False`），否则每换一个 App 就要等一次 | 单元测试 `the_speech_models_hint`；终端里的识别结果没在 VM 上重测（TTS 的 git status 本来就念得像 get） |
| 「用云端…」第二个按钮 | 完全没有语音模型时：「下载（大小）」+「用云端…」两个按钮，10 s（`DictationTakes.noSpeechModel`，`Toast.second`） | 岛上的一行可以有第二个按钮（`second`：安静的在左，主按钮填色在右，和 Mac 的排法一样）；只在一个本机模型都没有、也不是失败那段的「已保留」时出 | 新的 BLURT_HOME：「听写需要语音模型 · 用云端… · 下载（950 MB）」，点「用云端…」打开 设置 → 模型 的云端模型 |
| 听写页没有「词库」标签 | 历史 / 词库两个标签（`DictationWords.swift`）：一个输入框边找边加（回车添加，逗号分开一次加多个，已有的说出来），待确认的词一行一行（添加 / ×），你的词、来自项目的词（每个项目一个：名字 + 缩写）、内置词（折叠）都是小圆片；圆片能用键盘（← → 选，Delete 删，Enter / 双击改拼写），删 / 加 / 忽略都能撤销（⌘Z）；右边只讲这个词：来源、用到几次、常被识别成什么、添加时间 | `DictationWords.tsx` 照 Mac 移植，数据走已有的 `dictation_words` / `dictation_words_edit`（加了 `suggest`：撤销「添加 / 忽略」时让词回到待确认）。Ctrl+Z 在这个标签里只撤销词库的改动 | 待确认的「王晓明」（常被识别为 王小明，改正 2 次）；输入「Kubernetes, tmux」提示「按 Enter 添加 Kubernetes、tmux」，回车后两个都在；添加 → 「已加入 王晓明 · 撤销」；选中圆片 Delete → 「已移除 Kubernetes」，Ctrl+Z 回来 |
| 详情里的原生 `<audio controls>` | Mac 的详情里没有播放器，录音只在 ⋯ 里「在访达中显示」 | 去掉播放器，⋯ 里的「显示录音文件」保留 | — |
| 经典滚动条（▲▼） | Mac 是叠在内容上的细滚动条 | 全应用的滚动条已改成只有滑块、没有箭头（packages/ui 的 base.css，归外壳）；听写页不再单独设（`scrollbar-width` 会让 Chromium 退回带箭头的样式） | — |
| 每行都是字母方块 | 每行是 App 的图标 | 新命令 `app_icon`：exe 的图标（`SHGetFileInfoW`，32 px，转成 PNG）；历史里新存 `exe_path`，旧记录按 exe 名在 Windows 目录、App Paths、正在运行的进程里找；找不到才用字母方块。`SHGetFileInfo` 要在有 COM 的线程上、一次一个调用（一起请求时有的会空着回来） | 资源管理器、记事本、Edge、终端、cmd 都有图标 |
| 「已删除 · 撤销」盖住列表底部 | Mac 用岛上的一行 | 放在列表上方、底栏之上（不再挡「听写记录保留」和「清空历史…」） | 截图 |
| 耳朵里看不出往哪翻译 | 翻译图标旁边写目标：EN / 中 / 繁 / 日 / 한 / FR…，自动是 ⇄（`earTarget`） | 照做（`flow::ear_target`，状态里多一个 `target`） | 截图：文A ⇄ 0:02 |

#### 重复循环：在 VM 上复现和复测

- 自己造的音频复现不出来：32 段测试音频（AISHELL / LibriSpeech / ASCEND，5–30 s），整段 + 0 / −5 dB 噪声 + 音乐底 + 很小声，
  再加在 3 / 4.5 / 6 / 7.5 s 处截断（和抬键截在半个词上一样）+ 5 dB 噪声 / 音乐，有无词表热词各一遍，用导出原本的 512 上限解码
  624 + 数百次：**0 次循环**。
- dogfood 那两段循环的录音还在（`d-20261102-144930-cc62`、`…144954-6a99`，6.1 s 英文）：没有热词时每次都循环——512 上限下
  2,123 / 1,964 字、解码 14.2 / 13.8 s；有词表热词时不循环（106 字、0.9 s）。
- 新的处理（192 上限 + 只留一遍）在 app 自己的识别服务上：听写页「重试」这两段 → 139 / 142 字、识别 6.2 / 5.9 s，服务日志
  `funasr: a repetition loop in 6.1 s cut to 139 characters`。剩下的字到句子中间就断了（原话本来就说到一半），所以：
- 服务的回答带 `looped: true` → 那一段记成循环（`Done.looped`，历史里 `looped: true`），**双击一律不发送**，说「未发送：语音模型
  重复输出了同一段」。只看字数的规则（`SpeechLoop`）留着兜底（截完还超长的）。端到端：在 Edge 的输入框里，一段听写按 Esc 停在识别中，
  把它的录音换成循环的那段，点「撤销」重听，再马上双击——字打进去了（139 字），没有发送（`sent=0`），岛上出这一行。
- 用麦克风回放那段录音（5 种停的时机）在 app 里没有循环：切片和前后的静音和原来那一段不完全一样，循环对这些很敏感。

还没做的：识别服务挂起时 ping 不检查卡死（要等 45 s，P3）。设置 → 听写 里通往「词库」的「管理…」归设置页。


## 视觉门 r1（11-03）：听写页、词库

- **详情**：Correct / Copy 不再悬浮在文字上（盖住了最后几个字）；和「转为事项」「⋯」放在同一排，28 px 的淡底图标按钮，始终可见。
  标题两行：App 名（不截短）在上，「今天 4:03 PM · 0:14」和「已改正」小标签在下（点它看改动）；日期用短格式。
  正文 36em 宽、`text-wrap: pretty`，不留一两个字的尾行；结构化的清单渲染成真正的列表（列表行预览用「 · 」连）。
  改动视图：删掉的用红色加删除线，加上的用强调色下划线，两者之间一个细空格；说明句和「发生了什么」一句占同一个位置，切换不跳。
- **一种结果写法**：文字下面一句（复制了没输入 / 没润色 / 没输入），元数据只写事实——「润色」只写模型名或「关闭」，没润色时不显示
  「风格」，去掉「结果」一行；每个非默认结果在列表里有一个小标签（包括「未输入」「没能识别」）。模型 id 显示成名字，已不在本机的
  写「已不在这台电脑上 · 选择…」；有「上下文」时显示。
- **没能识别**：不再是灰色横幅 + 单独一行「⋯」：⚠ + 原因在文字的位置，下面「录音已保留 · 0:02」，动作一排（选择模型… 或 重试 + ⋯）。
  中文统一「没能识别」。列表行正文写「—」。
- **列表**：日期标题吸顶；搜索框里有清除按钮；匹配用浅色底标出；没有匹配时两栏保持（搜索框不拉满）；搜索总是选中第一条；
  「保留天数 / 清空历史…」从常驻的底栏移到「发送反馈」旁的「⋯」里（设置 → 听写里也有）。滚动条去掉了箭头（`scrollbar-width` 会让
  Chromium 忽略 `::-webkit-scrollbar`）。
- **撤销**：「已删除 · 撤销」停在列表底部自己的一条道里（列表下面留出它的高度），实底、阴影、撤销是安静的胶囊按钮；删除后焦点回列表。
- **菜单**：右键 / ⋯ 菜单宽度跟内容，右侧有快捷键（复制 Ctrl+C、改正 E、转为事项 Ctrl+Enter、删除 Del）；分组两边一致。
- **清空确认**：居中的 ContentDialog：20 px 标题、写明「将删除全部 N 条听写（含录音）」、底部两等宽按钮，取消是默认（有焦点环），
  清空用淡红底红字。
- **发送反馈**：sheet 最高窗口减 96，只有列表滚；行 38 px：勾 · 时间（96 px）· 文字 · 时长或「仅文字」；勾选的排最前；
  大小小于 1 MB 用 KB；按钮总带条数；说明拆成两段。
- **空状态 / 横幅**：横幅一行（关：中性底 + 电源图标 +「打开」直接开；没模型：提醒色底 + ⚠ +「这台电脑上没有语音模型」+ 选择模型…）；
  「转为事项」无论哪种状态都是主按钮（它不需要语音模型）。空状态说明居中平衡换行。
- **词库**：中文说明换成 Mac 的一句（不再留「容。」）；「添加」是品牌色；行的工具只在指针所在行（没有指针时才在选中行）；
  页头显示「N 个词」；「发送反馈」只在历史页；清除按钮在框里，框宽不变；英文写 Enter 不写 Return；没有匹配只说一次；
  查找时组标题写「1 / 9」、详情跟着第一个匹配，重复的词直接选中它。词片的 × 是 14 px 的实心小圆（细边、阴影），只在指针所在
  或键盘选中的词上，删掉后不立刻出现在下一个上；内置词更淡、没有 ×、展开时有一句说明；改拼写就在词片里（同样的胶囊、品牌色细边、
  宽度跟字）；⋯ 菜单对齐按钮右边、不再同时出浏览器的「更多」提示、带 F2 / Del；详情去掉了给段落留的空白、「听写里用到 2 次」、
  项目词显示「项目」和「缩写」两行；「发现于」用相对时间。没有词时：列表里一句「还没有词」+ 怎么加，详情空着。
- 仍不同：内置词表里只有 Blurt（没有中文名「口喷鸡」，词表来自 Python 的默认词）；词库的「加入词库」提示和 Mac 一样只说一次。
