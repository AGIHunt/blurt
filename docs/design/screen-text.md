# 设计：截图取字（Copy Text from Screen，⌥C）

2026-10-29。对标 Bob 的「静默截图 OCR」（⌥C）：框选屏幕上的文字，松手就在剪贴板里，像自己选中复制的一样。
要求：速度和 Bob 一样快，质量明显更好；不下载任何模型就能用；低配 Mac、以后的 Windows / Linux 都有路可走。

## 1. 用户看到的

1. ⌥C（菜单栏「截图取字」，设置 → 快捷键可改；想和 Bob 一样用 ⌥C 就在那里改）→ 十字光标，直接拖：
   不加蒙板、不能点窗口、没有工具栏（和 Bob、⌘⇧4 的拖选一样）。Esc 或只点不拖 = 取消。
2. 松手即识别：约 0.1–0.2 秒后刘海耳朵里出现「已复制」。不存卡片、不存文件、没有快门声。
   前台是别的 App 时，按听写的规则（BlurtCore `DictationPastePolicy`，§1c）同时 ⌘V 粘贴进去，剪贴板保留这段文字（和 Bob 一样）。
   刘海只说确认过的事：粘贴后读回输入框、看到了这段文字才说「已粘贴」；确认不了（微信这类读不出内容的输入框，或 1.5 秒内没看到）
   说「已复制 · ⌘V 粘贴」；没有粘贴说「已复制」。本机二次识别已热着时，等它（最多 1.2 秒）再粘贴，粘贴的是修正后的版本。
3. 没识别到字：「这里没有识别到文字」。没有屏幕录制权限：和截图一样的权限引导。
4. 开了二次识别：剪贴板先是第一段结果；第二段读完后，**只要剪贴板还是这份草稿**（这期间没复制别的），就换成修正后的版本。
   立刻粘贴拿到草稿，稍后粘贴拿到修正版，永远不会覆盖用户自己复制的东西。

## 1b. 截图翻译（⌥T）

同样拖选 → 取字 → `polish.py translate`（`translate_system`：保留换行、列表、Tab、代码、路径、URL 和产品名）。
翻成什么：「设置 → 截图取字 → ⌥T 翻译成」，⌥T 自己的设置（§1f；2026-10-30 起不再和听写共用）。
「自动」是你的语言 ↔ 另一种（§1f，比如「自动：简体中文 ↔ English」），由模型判断语种：是你的语言就译成另一种，否则译成你的语言；选了某种语言（比如 English）就**总是**
得到这种语言（2026-10-30，§1d）。用哪个模型翻译看「设置 → 模型」的「翻译」一行（v1.0.8，和听写的翻译同一行）：自动 = 已连接的最好的云服务，没有就用本机润色模型；云端失败时本机模型接手。
刘海里先显示「正在翻译…」，出结果后：刘海那一行只说状态（「已粘贴译文」/「已复制 · ⌘V 粘贴」/「已复制译文」），
完整译文在刘海下面的小卡片里（§1e）；译文在剪贴板里，按 §1c 的规则粘贴。翻译失败：照旧 ⚠「翻译失败，已复制原文」+「再试一次」。
听写的翻译模式复用同一个请求。

| | 质量（6 段：路径、列表、英文段落、混排列表、代码、勾选列表） | 时间 | 费用 |
|---|---|---|---|
| 云端 DeepSeek（用户自己的 key，直连） | 自然；路径、代码、列表原样 | 1.4 s（App 端到端） | 每次约 ¥0.0013 |
| 本机 Gemma 4 E2B（已装的润色模型） | 可用；会把路径里的中文文件名翻掉，混排列表有一次没翻 | 0.6–1.6 s | 免费 |

## 1c. 粘贴规则和「已粘贴」（2026-10-30，创始人反馈）

- 问题：光标在 Claude Code、飞书的输入框里，⌥C / ⌥T 会粘贴进去；在微信里只复制。原因是 `fieldInFront()` 要求辅助功能
  认出可编辑的文本控件，微信的输入框不是。听写在微信里能粘贴，因为它走 `DictationPastePolicy`。
- 现在 ⌥C / ⌥T 用同一套规则（`BlurtCore/DictationPastePolicy.swift` 的 `ScreenTextPaste.decide`，调的就是
  `DictationPastePolicy.decide`，不另写一份）：前台是别的 App 就 ⌘V，除非没有前台 App、开着安全输入或焦点是密码框、
  没有辅助功能权限，或者辅助功能读到焦点不是输入框（桌面、没有焦点输入框的网页）——这一条是 ⌥C
  比听写多的：听写会粘贴并在刘海里留着文字，⌥C 的文字本来就在剪贴板里。交付时（和听写粘贴时一样）用
  `DictationInsert.situation()` 读当时的情况，按的是那时的前台 App。
- 拖选、识别或翻译期间换了 App（2026-10-31，和听写同一条规则，见 dictation.md §Insert 5）：照样按上面的规则粘贴到
  文字好时的前台 App。以前只复制（`ScreenTextPaste` 判断 `appChanged` → `copy(app_changed)`），这个判断删了；按键时的
  前台 App 仍记下（拖选窗口不抢焦点），只用来在 `screen_text_delivered` 里记 `app_changed`。刘海的话不变：确认落地才说
  「已粘贴」/「已粘贴译文」，否则「已复制 · ⌘V 粘贴」，没粘贴说「已复制」。Electron App 在按键时
  和听写一样先唤醒辅助功能树（`wakeWebAccessibility`），交付时输入框才读得到、粘贴才确认得了。
- 「已粘贴」必须是真的：以前 ⌘V 一发出去就说「已粘贴」。现在粘贴前读一次输入框（`DictationField.focused().read()`），
  粘贴后用听写的落地检查（`DictationInsert.confirmLanding`，即 `DictationPasteLanding.landed`，每 30 ms 读一次，最多 1.5 秒）
  看到文字才说「已粘贴」/「已粘贴译文」；确认不了说「已复制 · ⌘V 粘贴」。文字始终留在剪贴板（`pasteKeeping`）。
  选哪句话：`ScreenTextPaste.outcome` / `lineKey`（`DictationPastePolicyTests`）。

## 1d. 翻成固定语言时：总是这种语言（2026-10-30）

- 1.0.6 的规则：选了 X，原文已经是 X 就翻成系统语言（`request(home:)` 发 `X|home`）。设成 English 时，⌥T 一段英文得到的是中文。
- 现在：选了 X 就总是得到 X。⌥T 发 `X|keep`（`DictationTranslateTarget.request`）：polish.py 让模型「翻成 X；已经是 X 就原样返回」，
  守卫对 `X|keep` 按 X 检查（原样返回本来就通过）。App 看到返回的和原文一样（只比较空白以外的字符：
  `DictationTranslateRoute.keptAsIs`；判断语种的是模型，不是规则），就原样复制原文、不粘贴、不弹卡片，
  刘海说「已是英语 · 原文已复制」（语言名按界面语言本地化）。
- 听写共用这个设置，规则也改成一样（代码里本来共用 `request`，否则「同一个设置」在两处意思不同）：说的已经是 X 就不发请求、
  按原话输入（1.0.6 之前就是这样）；语音模型没判出语种时发 `X|keep`。`DictationTranslateRoute.home` 和 `Dictation.homeLanguage` 删掉了。
- 「自动」见 §1f（2026-10-30 起按用户自己的语言来，不再固定中文 ↔ 英文）。

## 1e. ⌥T 的译文卡片（2026-10-30）

以前译文前 280 字塞进刘海的 toast：折成好几行、字号不一、不能点也不能复制，也没说已在剪贴板。现在（`Capture/ScreenTextCard.swift`）：

- 是刘海的下半部分，和听写的实时字幕面板同一族（system.md §3.2「Live-text panel」）：刘海的黑色，刘海下 6 pt
  （吊着卡片时在卡片下），宽度和圆角同字幕面板（`IslandLayout.livePanelWidth` / `livePanelRadius`），系统柔和阴影，无模糊无边框；
  没有刘海的屏幕上胶囊同样加宽（`liveCapsuleWidth`）。
- 一种字号：14 pt、92 % 白、20 pt 行高；最多 8 行（`IslandLayout.liveTypedLines`），多了滚动（覆盖式滚动条）。
- 右下角「复制」：toast 动作的同款安静胶囊（`IslandButton.quiet`）；点了变成 ✓「已复制」1.6 秒。
- Esc 关闭，但**只在指针停在卡片上时**：指针进入卡片才注册 Carbon 热键（`HK.translateEsc`），离开或卡片关闭就注销
  （和吊卡片的 Esc 同一规则）。用户在前台 App 里按的 Esc（打断 Claude Code、关对话框）从不被卡片吃掉（2026-10-30 复审：
  最初是卡片显示的 10 秒里一直占着 Esc）。指针不在卡片上时，卡片靠 10 秒计时或点「复制」后自己收起。卡片是不能成为
  key 的非激活面板，点「复制」、滚动都不会把焦点从正在打字的 App 抢走。
- 10 秒后自己收起；指针在卡片上时不收，离开后再等 10 秒。下一次 ⌥C / ⌥T、听写的实时字幕出现时它让位。
- 测试命令：`textcard TEXT | state | copy | esc | close | hover on|off | line OUTCOME`。
- 隔离测试版 App 里验证过（2026-10-30，只截测试 App 自己的窗口）：⌥C 粘贴进测试输入框，读回确认「已粘贴」；13 行英文 /
  10 行中文译文显示 8 行、可滚动、最后一行淡出；「复制」→「已复制」；Esc 热键只在指针在卡片上时注册，离开即注销；10 秒自动收起，指针停留 11 秒仍在、
  离开 5 秒仍在、离开 11 秒收起。截图：`promo/cases/screen-text/translate-card-2026-10-30/`（卡片 + 刘海、已复制、
  「已是英语」、设置 → 通用 / 听写，中英各一套）；§1f 的设置页截图在 `promo/cases/screen-text/settings-2026-10-30/`。

## 1f. 设置：截图取字自己一页，⌥T 和听写各有各的目标语言（2026-10-30，创始人定的设计）

- 想清楚用法：听写的 ⌘ 翻译是把**你自己说的话**译成别的语言（写给外国人）；⌥T 是把**屏幕上的外文**译成你的语言（读）。
  方向通常相反，所以两者的目标语言各自独立。用哪个模型（云端还是本机）不在这一页选：v1.0.8 起统一在「模型」页的「翻译」一行，
  这里只显示一行「用 deepseek-flash · 云端」和「更改…」（原来两边各自的「用云端模型翻译」开关去掉了，迁移时照原来的走向保留）。
- 设置侧栏：通用 / 听写 / **截图取字** / 模型 / 快捷键 …（`SettingsCatalog` 的 pane `screentext`，`ScreenTextPane.swift`）。
  页面两组：「取字（⌥C）」——精确识别（原「通用 → 截图取字」，旧行 id 在 `movedRows` 里重定向）；「翻译（⌥T）」——
  「⌥T 翻译成」[自动 ▾ + 各语言] 和它自己的「用云端模型翻译」。通用页不再有这一组。
- 存储：`record.screen_text.translate = {"cloud": bool, "target": …}`（BlurtCore `ScreenTranslateConfig`）。迁移：第一次启动时
  （`ScreenTextCopy.migrateTranslateConfig`）原来的 `record.dictation.translate.target / cloud` 留给听写，⌥T 从「自动」开始，
  云端开关沿用听写当时的值；写入后键存在就不再迁移。
- **「自动」以用户为准（global-first），两个功能同一条规则**（BlurtCore `TranslateAutoPair`）：home = 用户自己的语言——在口喷鸡
  里选了界面语言就用它，否则用系统的首选语言列表里第一个在翻译列表里的（都没有就是 English）；other = home 不是英语时是
  English；home 是英语时是系统里下一个在列表里的语言，没有就没有配对：「自动」只把别的语言译成英语，英语原样保留，
  行下面一行字提示「要翻译英语，请选一种语言」。规则：home 的文字 → other，其他 → home。标签照列表里的写法（各语言自己的名字）：
  「自动：简体中文 ↔ English」「Auto: English ↔ 日本語」；没有配对时「自动：译成English」/「Auto: into English」。系统语言从用户的全局偏好读
  （口喷鸡选了界面语言时会改掉本进程的 AppleLanguages）。
- polish.py：目标写成 `auto:H|O`（`auto_pair`），prompt 里的那对语言就是 H 和 O；旧的 `auto`（中文 ↔ 英文）照样认。没有配对时发 `H|keep`。
  判断语种仍然是模型的事，不加规则。听写的「自动」：语音模型判出的语种是 home → other（没有 other 就按原话输入），
  是列表里别的语言 → home，没判出 → `auto:H|O`。
- 固定语言照旧：总是这种语言；原文已经是这种语言就原样保留并说明（`keptAsIs(request:)`：请求以 `|keep` 结尾、模型原样返回）。
- 测试：`DictationTranslateTests`（`testAutoIsYourLanguageAndTheOtherOne`、`testTheTargetIsTheOtherLanguageOfTheOneHeard`、
  `testScreenTranslateHasItsOwnSettings`），`SettingsCatalogTests`（旧行重定向），`tests/test_polish_cloud.py`（`auto:H|O`）。

## 2. 两段式

### 第一段：系统 Vision + 版面重建（默认，零下载，所有 Mac）

`BlurtCore/ScreenText.swift`。Vision `VNRecognizeTextRequest`（.accurate，zh-Hans / zh-Hant / en-US，用户词表作 customWords）
就是 Bob 用的引擎；Bob 的问题都出在识别之后。我们只用几何信息（不加语言规则）重建版面：

| Bob 的问题（视频里逐个复现） | 我们的处理 |
|---|---|
| 半行被截：读成「网关数掂米果力条•…」「海议吸姓•生洁主…」 | 字形碰到上/下边缘且行高不足一整行 → 丢掉 |
| 半个字：「产库现ㄐ」「三产库现北」 | 比同行同类字窄、且碰到左右边缘有墨迹 → 去掉这个字 |
| 列表项按屏幕换行硬断开 | 经典回流判断：下一行的第一个词放得进上一行末尾就不是换行 → 合并 |
| 勾选图标读成 `•` `◎`，空心圆读成 `。` | 行首孤立符号 + 空格 → `- `，按缩进嵌套 |
| `2.ordo_ai` 丢空格；低分辨率漏读 `2.` | 编号后补空格；1 和 3 之间缺一个编号就补回 |
| 表格每格一行 | 同一基线、间距大于一个行高 → Tab；多列行成块即表格 |
| 代码/终端被合并成段 | 起始 x 不一致或大多不换行的块保留原行，按字符宽度还原缩进 |
| 代码里全角 `（）：；` | 两侧都不是 CJK 的全角标点 → ASCII |
| 路径在连字符处断行，Bob 丢了 `-` 或多出空格 | 行尾 `-` `/` `_` 直接相连；中英之间是否加空格跟随截图本身的习惯 |

### 第二段：模型再读一遍（可选：本机 / 云端）

`scripts/screen_text.py`。模型读同一张图，再与草稿**合并**：草稿决定有哪些行、怎么排；模型只决定一行里的字符。
模型单独用反而更差（错误率 13–20%，主要是把被截掉的半行编出来），合并后最好。合并时从不接受：草稿没有的行、
汉字和中文标点上的分歧（两边不一致说明有一边在猜）、删除、明显变短的替换、行首行尾插入的字母（截掉的字回来了）、
草稿的空白（Tab、缩进是版面）、Markdown（`**` `` ` ``）、LaTeX、破折号样式。

## 3. 实测（tests/fixtures/screen_text，17 张 Retina 截图，按 Bob 视频里的拖法 + 代码 / 终端 / 英文 / 表格 / 嵌套列表）

字符错误率（去掉空白后的编辑距离 / 期望长度），M5 Max：

| | 错误率 | 版面对 | 时间 |
|---|---|---|---|
| Vision 原样（= Bob） | 15.5 % | 6/17 | 0.03–0.2 s |
| 第一段 | 0.74 % | 16/17 | 同上（排版 < 5 ms） |
| + 本机 PaddleOCR-VL 1.6 | **0.16 %** | 16/17 | +0.07–0.6 s（平均 0.22 s） |
| + 云端 DeepSeek V4.1 Flash | 0.20 % | 16/17 | +4–7 s（经 OpenRouter；直连预计 1–3 s） |
| + 云端 Gemini 3.1 Flash-Lite / Qwen3-VL 30B / Gemini 2.5 Flash-Lite | 0.16 % | 16/17 | +4.5–8 s |
| 试过不用：Gemma 4 E2B（已装的润色模型，带视觉塔） | 单独 15.6 %，会改写中文 | | 0.9 s |
| 试过不用：GLM-OCR 0.9B | 合并后同 Paddle，单独 17 % 且会加 `**` | | 0.28 s |
| 试过不用：GPT-5 nano / Claude Haiku 5.5 | 有空回答 | | 5–11 s |

视频里的真实低分辨率帧（Claude 桌面版）也验证过：Bob 读成「王库是一王一备，备库个能读」的半截行被正确丢掉。

### 2026-10-29 晚：网站 demo 里发现的三个问题（已修，加进测试集第 18 例）

- 底部半截英文行：Vision 给的框离边缘还差几个像素，「碰到边缘」的判断没触发，乱码行（Ack Msus hofaro…）被保留。
  改为：框在边缘半个行高以内、且边缘那一行有墨迹，就用这一行**实际墨迹高度**（不信 Vision 的框）和完整行比，不足 90 % 就丢。
- 项目符号后面没空格（「•日志已经附在工单里」）：不会出现在正文开头的符号（• ◦ ○ ◎ ▪ ■ ● ◆ ◇ ► ▸ ✓ ✔ ☐ ☑）不要求后面有空格；
  `-` `*` `–` `。` `·` 仍然要求。
- 「不认 ？sort=price」：前面是空格、后面紧跟 ASCII 的全角标点 → ASCII（查询串，不是中文问号）。

18 例：Vision 原样 15.8 %、版面 6/18；第一段 0.70 %、**版面 18/18**（之前 16/17：墨迹高度的判断也修好了一例）；
加本机二次识别 0.16 %，平均 0.22 s。

## 4. 资源与档位

| | 下载 | 内存 | 速度 | 费用 |
|---|---|---|---|---|
| 关闭（默认） | 0 | 0 | 即时 | 免费 |
| 本机模型 | 720 MB（一次，经统一下载管理器；镜像可用） | 常驻约 1.1 GB，加载峰值 2.7 GB；闲置 10 分钟或 Blurt 退出即释放 | 0.2–0.6 s（M5 Max）；M1 估计 2–3 倍 | 免费 |
| 云端模型 | 0 | 0 | 1–7 s | 每次约 ¥0.001（DeepSeek：~300 输入 + ~220 输出 token），每天 100 次一个月约 ¥3 |

- 本机模型 16 GB 以上推荐；8 GB 的 Mac 仍可选，设置里会说明可能拖慢其他应用、云端不占内存。
- 读哪个模型：「设置 → 模型」的「截图取字」一行（v1.0.8）：自动 = 已连接、有看图模型的最好的云服务（DeepSeek 的 deepseek-flash、
  百炼的 qwen3.6-flash，或其他服务列表里标明能看图的模型），没有就是本机 PaddleOCR-VL。这一页只剩「精确识别」开关和一行「用 … · 云端」+「更改…」；
  `record.screen_text.refine` 变成 off / on（旧的 local / cloud 都算开，迁移时 local 记成「本机」，cloud 记成原来的服务和模型）。
  截图会发给那家服务，行下面写明。key 走 stdin，不进文件、参数和环境变量。
- 超过 4 MP 或 3000 字（整屏）不做第二段：要几秒，不划算。

## 5. 复用与以后

- 版面重建只用几何，`ScreenText.swift` 的逻辑与 Python 原型一致，Windows（`Windows.Media.Ocr`，系统自带、
  支持中文）和 Linux（RapidOCR / PaddleOCR ONNX）接上各自的行框就能复用；第二段的 `screen_text.py` 跨平台
  （云端不需要 MLX；本机模型换 ONNX / llama.cpp 版即可）。
- 和其他模型的关系：常驻、退出、下载、镜像都走润色模型那一套（`WarmSpawn`、`serve_exit_reason`、`ModelDownloads`）；
  云端用的是同一份配置。Gemma 4 E2B 虽然已在本机但不适合 OCR（见上表），没有强行复用。
- 待做：Windows / Linux 第一段；在 8 GB / 16 GB 的 M1、M2 上实测第二段；`○` 空心圆项目符号的嵌套层级；
  终端里恰好写满一行的软换行（`....F.` 被并到上一行）。

## 6. 测试

- `swift test --filter ScreenText`：fixture 全量过 Vision，断言错误率 < 2%、版面 ≥ 15/17，以及边缘、编号、标点单测。
  `BLURT_WRITE_DRAFTS=1` 时写出草稿给第二段评测用。
- `uv run pytest tests/test_screen_text.py`：合并守卫的每条规则 + 已提交的 Paddle 读数合并后不比草稿差、总体减半以上。
- `uv run screen_text.py eval`：本机模型对 fixture 的实时评测（错误率、耗时）。
- `BLURT_GUI_TESTS=1 [BLURT_SCREEN_TEXT_REFINE=1] uv run pytest tests/test_screen_text_app.py -s`：隔离的 App、私有剪贴板，
  第一段 + 第二段端到端。
- `swift test --filter DictationPastePolicyTests`：⌥C / ⌥T 的粘贴规则（听写会粘贴的地方 ⌥C 也粘贴，除了读到不是输入框）、
  只有确认了才说「已粘贴」、每种结果的文案两种语言都有。`--filter DictationTranslateTests`：固定语言总是这种语言（`X|keep`）、
  听写已是 X 不发请求、`keptAsIs`。
- `uv run pytest tests/test_polish_cloud.py`：`X|keep` 的 prompt 和守卫。
- 测试版 App：`dictation testpad` 打开测试输入框后，`screentext …` 粘贴进它并确认（`screen_text_delivered` 的 `outcome`）；
  `textcard TEXT` 显示译文卡片。
