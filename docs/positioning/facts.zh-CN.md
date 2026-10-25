# 口喷鸡（Blurt）定位事实表

[English](facts.md) · [中文](facts.zh-CN.md)

给官网、README、发布文章（包括公众号文章）和宣传视频用的素材。每个数字后面都写了出处；不知道的数字写「没测」或「未公开」。

- **整理时间：** 2026-10-25，分支 `feat/live-snap`（`fa798046` 之后，即听写实时文字合并之后）。
- **竞品信息核对时间：** 2026-10-25。价格和政策会变，发布前请再核对一次。
- **多语言：** 每种语言一个文件 `facts.<语言>.md`，章节编号、表格行的顺序都和英文版一致；数字和出处不改，只翻译正文。

---

## 0. 标题和副标题

| | 中文 | English |
|---|---|---|
| 标题 | Agent 时代的输入法 | The keyboard for the agent era. |
| 副标题 | 用最高效的方式与你的 Agent 们互动，支持文字、语音、截图、录屏等。本地运行、免费开源。 | The fastest way to work with your agents, by text, voice, screenshot or screen recording. Runs locally. Free and open source. |

## 1. 定位

### 一段话

口喷鸡是一个菜单栏 App，给每天和 AI Agent 打交道的人用，比如 Claude Code、Codex、Cursor、Claude、ChatGPT、豆包。它管的是
Agent 开始干活之前的那一段：把你想说的放进 Agent 的输入框。按 `Fn` 说话，文字打在任意 App 的光标处；截一块屏幕，说一句哪里不对，
把图和备注拖进 Agent 所在的聊天框或终端；一边录屏一边讲，你的 Agent 把录屏整理成条目，带截图、复现步骤和最可能出问题的代码。
语音在你自己的电脑上转成文字。口喷鸡配合你已经在用的 Agent 工作：它自己不做 Agent，也不重复做 Agent 已有的集成。

### 三项能力

**1. 听写。** 按 `Fn` 说话，说的内容打在光标所在的位置，任何 App 都行。

- 按一下 `Fn` 开始、再按一下结束，或者按住 `Fn` 说、松开结束。连按两下 `Fn` 发送（回车）。也可以改用右 Option 或任一 Option 键。
  （`docs/guide.md` §7）
- 识别和润色都在 Mac 上运行：识别用 Qwen3-ASR（32 GB 及以上内存用 1.7B，16–24 GB 用 0.6B），润色用 Gemma 4 E2B，都通过 MLX。
  （`docs/design/dictation.md` §Recognition model、§Defaults by hardware tier）
- 默认的「轻整理」去掉语气词和口吃，加标点；不改写、不概括、不翻译，也不把话排成清单。说话时单按 `⇧` 切到「结构化」：你确实在列点时
  排成清单。`⌥⇧L` 重排上一条听写。（`docs/guide.md` §7）
- 说话时，识别出的文字显示在刘海下方，大约落后一秒，你可以在文字进去之前决定直接发送还是先改。（`docs/design/dictation.md` §Live text）
- 聊天软件、邮件、编辑器、终端都能用；在终端和代码编辑器里文字保持一行；不会往密码框里打字。（`docs/guide.md` §7）

**2. 截图和语音备注变成卡片。** 截图或语音备注作为卡片留在刘海下方，用的时候拖进或粘贴到任意 App。

- `⌥⇧A` 截图：框一块区域，说一句（或打字）哪里不对，停约 2 秒就保存；可以在图上拖动圈出位置。`⌥⇧V` 语音备注：最长 10 分钟。
  （`docs/guide.md` §1）
- 把卡片拖进 Claude、ChatGPT、Slack、Notion、飞书、微信：图片作为附件进去，口喷鸡再把备注贴进同一个输入框。拖进 Terminal、iTerm2、
  Ghostty、Warp：Claude Code 或 Codex 拿到图片和一个写着备注的 Markdown 文件的路径。（`docs/guide.md` §3）
- 单击卡片复制，再 `⌘V`；按住 `⌘` 点几张，一起复制；`⌥⇧H` 放下卡片，用键盘操作。（`docs/guide.md` §3）
- 拖走的卡片 7 天内还能找回；删除的卡片 5 秒内可以撤销。（`docs/guide.md` §3）

**3. 录屏整理成条目，再交给 Agent。** 一边录屏一边讲，拿回一份 Agent 可以接着做的条目清单。

- `⌥⇧R` 开始、再按一次结束，可以录一块区域、一个窗口或全屏。按住 `⌃` 拖动可以在屏幕上圈出来，笔迹 3 秒后消失。
  （`README.zh-CN.md` §用起来是什么样）
- 你的 coding agent 把录屏拆成条目（问题、想法、笔记、任务），给每条挑一帧截图、框出位置，写好实际效果和预期效果、复现步骤、
  可能有关的代码。（`README.zh-CN.md`）
- 用键盘一条条过（`A` 要做、`X` 丢弃、`J/K` 下一条/上一条），然后导出成 Markdown/CSV 或交接包（`.zip`），让 Agent 用它自己的工具
  建到团队在用的地方（GitHub、Linear、飞书、Slack……），或者让 Agent 去改。（`README.zh-CN.md`、`skills/blurt/reference/export-other.md`）
- 「交给 Agent」（`⌘↩`）在口喷鸡里、在项目文件夹中启动 Claude Code 或 Codex，可以每个条目一个 git worktree。「复制指令」给你自己的
  Agent 一行指令，指向一份交接说明：条目、你说的话、步骤、可能有关的代码和截图。Agent 通过口喷鸡的 MCP 汇报进度；Agent 说「修好了」
  一律只算「待验证」。（`docs/guide.md` §5、`skills/blurt/reference/sessions.md`）
- 没有代码的同事也能用 App 录屏，把视频发过来，开发这边的 Agent 结合代码处理。（`README.zh-CN.md`）

---

## 2. 对比：口喷鸡、Typeless、Wispr Flow、Superwhisper、Aqua Voice

**对比日期：2026-10-25。**

先看这几条：
- 口喷鸡的数字来自自己的测试，**只在一台机器上测过：Apple M5 Max、128 GB 内存**；语音是 macOS `say` 生成的，当作麦克风实时输入。
  合成语音比真实麦克风干净，错误率偏乐观。更小内存的 Mac、真实麦克风、口音：**没测**。
- 竞品的数字来自不同的人、机器和方法，和口喷鸡的数字、彼此之间都不能直接比。有几项来自竞争厂商，已经标出。

### 2.1 听写延迟（说完 → 文字出现在光标处）

| 产品 | 数字 | 出处 |
|---|---|---|
| **口喷鸡** | 说 3 秒一句后 0.29 秒；10 秒后 0.35–0.38 秒；30 秒后 0.52–0.54 秒；60 秒后 0.39 秒（每项 3 次取中位数，最后一个字后 0.1 秒松键，模型已预热）。松键前停顿 ≥ 0.5 秒时约 0.01 秒。 | `docs/design/dictation.md` §Streaming 延迟表 |
| 口喷鸡，长段落，实时文字打开 | 42–54 秒的片段，松键到粘贴 0.51–1.55 秒（12 次中位数 0.64 秒）；一段 3 分钟中英混说：0.58 秒 | `promo/cases/v0.9-polish/livetext/results/summary-r3.txt`；`promo/cases/v0.9-dogfood/dictation/timeline.md` D46 |
| Typeless | 约 3.0 秒 | VoiceDash 的对比文章（竞争厂商），引用「2026 controlled benchmarks」：[voicedash.ai](https://voicedash.ai/wispr-flow-vs-typeless/) |
| Wispr Flow | 约 1.5 秒 | 同一篇 VoiceDash 文章 |
| Superwhisper | 未公开，没找到 | — |
| Aqua Voice | 「about 450ms」（厂商自己的说法） | [Aqua 博客，2026-08-17](https://aquavoice.com/blog/wispr-flow-alternatives) |

### 2.2 边说边显示文字（口喷鸡）

| 片段 | 第一次出字 | 平均落后语音 | 出处 |
|---|---|---|---|
| 中文，53.6 秒 | 0.64 秒（加中间解码之前是 20.5 秒） | 0.86 秒 | `docs/design/dictation.md` §Live text；`summary-r3.txt` |
| 英文，42.0 秒 | 0.63 秒 | 0.99 秒 | 同上 |
| 中英混说，45.1 秒 | 0.62 秒 | 1.26 秒 | 同上 |

中间解码不影响松键到粘贴的时间（打开时中位数 639 毫秒，关闭时 652 毫秒）。内存小于 16 GB 的 Mac 上不显示还在说的灰色部分，文字在每次
停顿后出现。竞品实时文字的延迟：没测。

### 2.3 准确率

| 产品 | 中文 | 英文 | 中英混说 | 出处 |
|---|---|---|---|---|
| **口喷鸡**，只看识别模型（Qwen3-ASR 1.7B，MLX bf16），每种语言 7 句产品反馈 × 2 个声音 | CER 1.3 % | WER 1.9 % | 没有单独测 | `docs/design/asr-benchmark.md` |
| **口喷鸡**，听写测试集，Qwen3-ASR 1.7B 8-bit，20 段中文和中英混说，含产品名 | CER 2.7 %（带上前文时 1.7 %）；名词对 90–97 % | — | （算在中文一栏） | `docs/design/dictation.md` §Qwen3-ASR 1.7B |
| **口喷鸡**，同一模型，更难的测试集（6 个声音，加了房间噪声） | CER 26.7 %；名词对 38 % | — | — | 同上 |
| **口喷鸡**，16–24 GB Mac 上的完整听写流程（Qwen3-ASR 0.6B + Gemma 4 E2B 润色，带自定义词；v0.8 时测的） | CER 10.8 %（中文和混说合计）；名词对 86 % | WER 0 %（10 段） | （算在中文一栏） | `docs/design/dictation.md` §Recognition model |
| Typeless | 未公开 | WER 约 7.9 %（同一篇文章另一处写约 20 %） | 未公开 | VoiceDash，竞争厂商 |
| Wispr Flow | 未公开 | WER 约 3.9 % | 未公开 | VoiceDash，竞争厂商 |
| Superwhisper | 取决于选的模型；未公开 | 未公开 | 未公开 | — |
| Aqua Voice | 未公开 | OpenASR 排行榜平均 WER 6.24（Avalon v1）；自家编程术语测试集 97 % | 未公开 | [Aqua 博客，2025-10-08](https://aquavoice.com/blog/avalon-openasr-leaderboard)（厂商） |

润色保留了什么（口喷鸡，合成评测集）：
- 「轻整理」在 68 次带改口的听写里，66 次保留了改口的每个字（97 %）；「结构化」68 次里 56 次只留下改过之后的版本（82 %）。
  `docs/design/dictation.md` §Self-corrections
- Gemma 4 E2B：2.4 % 的输出退回原始转写，去掉 88 % 的语气词，「误删」测试集里的每个短语在修复后都保留，预热后每句约 0.11 秒。
  `docs/design/dictation.md` §Over-deletion

### 2.4 价格、隐私、平台、离线、自定义

| | **口喷鸡** | Typeless | Wispr Flow | Superwhisper | Aqua Voice |
|---|---|---|---|---|---|
| 价格 | 免费，MIT 协议，不限字数。录屏整理成条目用的是你自己的 coding agent；三段 7–20 分钟的真实录屏，按 API 价格每段约 2–2.6 美元（`README.md` FAQ）。 | 免费版每周有额度；Pro 按年付每月 12 美元，按月付 30 美元（[定价页](https://www.typeless.com/pricing)）。App Store 用户说免费额度从每周 8,000 字降到了 2,000 字。 | 免费版桌面端每周 2,000 词；Pro 每月 15 美元，按年付每月 12 美元（[定价页](https://wisprflow.ai/pricing)） | 免费版可用本地 Whisper 模型；Pro 每月 8.49 美元（[superwhisper.com](https://superwhisper.com/)）；第三方指南说按年 84.99 美元、买断 249.99 美元（[Voibe](https://www.getvoibe.com/resources/superwhisper-pricing/)，竞争厂商） | 免费 1,000 词；Pro 每月 12 美元，按年付每月 10 美元；Max 每月 24 美元（[定价页](https://aquavoice.com/pricing)） |
| 语音在哪里处理 | 在你的电脑上。可选：录屏可以用你自己的 Groq、OpenAI 或 DashScope（阿里云百炼）密钥。写条目由你选的 Agent 完成，它会把转写文字和几帧截图发给这个 Agent 的模型服务商。 | 云端：「Transcription is performed on the cloud」（[数据说明](https://typeless.com/data-controls)，2026-10-13 更新） | 云端：「Transcription always occurs on the cloud」（[数据说明](https://wisprflow.ai/data-controls)，2026-08-18 更新） | 本地模型或云端模型，自己选（[文档](https://superwhisper.com/docs/llms-full.txt)） | 云端：「dictation runs in the cloud」（[Aqua 博客](https://aquavoice.com/blog/wispr-flow-alternatives)） |
| 平台 | 听写和卡片：macOS。录屏整理成条目：macOS、Windows、Linux（X11）。 | macOS、Windows、Linux、iOS、Android（[官网](https://www.typeless.com/)） | Mac、Windows、iOS、Android | Mac、Windows、iOS、Android | Mac、Windows、iOS、Android |
| 离线 | 模型下载好之后，听写不需要联网；还没有在断网状态下实测。 | 不能（转写在云端） | 不能（转写在云端） | 能，用本地模型时（「works offline」） | 不能（云端） |
| 风格 | 原话、轻整理、结构化、自动；按 App 类型设风格（聊天、代码和终端、邮件、笔记、其他）；说话时按 `⇧`；事后 `⌥⇧L` | 没有风格选项；按 App 自动调语气（[官网](https://www.typeless.com/)） | 按类别设 Styles，只支持英文；整理程度从 None 到 High（[文档](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)） | 模式（Modes），可以写自己的 prompt，说话中途可以切换（[文档](https://superwhisper.com/docs/modes)） | 自定义指令（Pro） |
| 自定义词 | 词库，会从你的修改里学（可撤销），也参考光标前后的文字；词只作提示，从不替换 | 个人词典 | 词典 | 词汇和替换规则 | 个人词典（Pro） |
| 截图、语音备注卡片，交给 Agent | 有 | 没有 | 没有 | 没有 | 没有 |
| 录屏整理成带截图和代码定位的条目 | 有 | 没有 | 没有 | 没有 | 没有 |
| 交给 coding agent，并通过 MCP 回报状态 | 有（Claude Code、Codex；整理录屏还支持 Kimi Code、OpenCode、Gemini CLI） | 没有 | 没有 | 没有 | 免费版列出了「MCP/CLI」，没有细看 |

---

## 3. 用户在抱怨什么，口喷鸡怎么做

**计数方法。** 我们读了 App Store 美区的 Typeless iOS 评论（131 条，其中 3 星及以下 57 条）和 Wispr Flow iOS 评论（250 条，3 星及以下
29 条），2026-10-24 通过 Apple 的 RSS 接口取得，按主题数了低分评论。一条评论可能算进几个主题。这两个是手机 App，口喷鸡是 Mac App，
有些主题不适用。其余的调研（r/macapps、V2EX、Product Hunt、少数派、爱范儿、极客公园、各家文档）见
`docs/design/dictation-styles.md` §1。引用的用户原话都很短，保留原文。

| 抱怨 | 大致多常见 | 口喷鸡的做法 | 状态 |
|---|---|---|---|
| **改了我说的话**：改写、概括、硬排成清单。"now it just writes what it thinks I said"（akmeds301，Typeless iOS，2026-10-22） | `dictation-styles.md` 里排第一；Typeless 57 条低分里 4 条；Wispr 也因为同样的抱怨，在更新日志里加了整理程度档位 | 默认「轻整理」，从不重排、不概括。润色如果丢了或多了内容，就改打原始转写。「原话」打的就是识别模型听到的。只有按 `⇧` 才「结构化」，`⌥⇧L` 可以把上一条改回去。 | 已做 |
| **说的内容丢了、中途断了**。「频繁中断、内容直接丢失」（Hao wang11，Typeless iOS，2026-07-22）；"everything i said was just eaten"（nerdhappy，Wispr Flow iOS，2026-10-11） | Typeless 57 条低分里 5 条；Wispr 29 条低分里 5 条 | 说话时就能看到识别出的文字。每条听写在「听写历史」里保存 30 天，可以复制。按下键的那一刻就开麦，开头的字不会被吞（实测：麦克风即开时，从按键后 5–6 毫秒就有音频）。「粘贴确认之前一直保留音频」还在计划里，没做。 | 部分做了 |
| **价格和字数额度**。"2000 is way too low"（Yeahyea588，Typeless iOS，2026-09-28） | Typeless 57 条低分里约 11 条；Wispr 29 条里 3 条 | 免费开源，不限字数，不用注册账号。录屏整理用的是你自己 Agent 的 token。 | 已做 |
| **人名、语言、简繁**。"I spoke in Cantonese, but it showed the simplified Chinese"（plchan，Typeless iOS） | Typeless 57 条低分里约 6 条；V2EX、极客公园也提到名词和中英混说 | 有词库，识别模型会照着听；从你的修改里学（学的是词，不是替换规则）；参考光标前后的文字。简体用户得到简体字，繁体用户保留模型写的字。粤语没测。「听写只认你说的那几种语言」的设置：还没做。 | 部分做了 |
| **后台一直开着麦克风，隐私**。"the microphone stays on even when not using the keyboard"（RichardS_23，Typeless iOS） | Typeless 57 条低分里约 8 条，多数是 iOS 键盘的问题；Wispr 曾为了上下文发送截图（`dictation-styles.md` §1） | 语音在 Mac 上处理。按下键才开麦，结束就关。为了拼对名词，会读光标前后约 500 个字符，只用于这一次听写；从不读密码框。听写不截屏。 | 已做 |
| **慢**。一篇对比里 Typeless 约 3.0 秒 | r/macapps、V2EX 上常见（`dictation-styles.md` §1 第 6 条） | 测试机上从松键到粘贴约 0.3–0.5 秒（§2.1）。16 GB、8 GB 的 Mac 没测。 | 测试机上已做；其他机型没测 |
| **发送前看不到识别结果**。"It doesn't add the punctuation in real time"（Karen Fanboy，Wispr Flow iOS，2026-10-17） | 口喷鸡自己的用户提过，内部试用也发现了 | 刘海下方显示实时文字：约 0.6 秒出第一批字，平均落后 0.9–1.3 秒（§2.2）。 | 已做（16 GB 及以上） |
| **快捷键冲突**（占用表情键、和 macOS 自己的 Fn 功能冲突） | Product Hunt；Typeless 的帮助页让用户去关掉 macOS 的 Fn 设置 | 口喷鸡把 Fn 留给听写；macOS「按下地球仪键时」的设置也会响应时会提示，并打开对应的设置页；Typeless 或 Wispr Flow 也在用 Fn 时会说明。也可以改用右 Option 或任一 Option。 | 已做 |
| **长段听写在 Claude Code 里折叠成「[Pasted N lines]」** | Wispr 在更新日志里修过 | 终端和代码编辑器里，文字保持一行。 | 已做 |
| **某些词拒绝转写或被审查** | Typeless 57 条低分里 3 条 | 润色在你的 Mac 上跑。模型如果拒绝，或者去回答而不是整理，检查会退回原始转写。没有专门的测试集测过。 | 设计上已做；没测 |
| **学到的替换规则反复出现**（Typeless 把 "hot" 换成 "long"，`dictation-styles.md` §1） | 少数几条 | 学到的词只作提示，从不替换。每次学到都会显示「记住了 …」并可撤销，「词」页可以查看和删除。 | 已做 |
| **耗电、不自动锁屏、iOS 键盘切换麻烦** | 最多的一类：Typeless 57 条低分里约 20 条，Wispr 29 条里约 10 条 | 不适用：口喷鸡没有手机 App。 | 不适用 |

---

## 4. 证据和演示片段

每个片段后面写了支撑它的数字或文件。

1. **文字跟得上说话。** 不停顿地中英混说 45 秒，刘海下方从 0.6 秒起就有字。加中间解码之前，要 20 秒后才出字。（`summary-r3.txt`）
2. **松开键，文字就在那里。** 60 秒的听写，松开 `Fn` 后 0.39 秒进去；3 分钟的 0.58 秒。（`dictation.md` §Streaming；内部试用 D46）
3. **说什么打什么。** 在「轻整理」里说「周三，不对，周四」：两个都保留；按一下 `⇧`：只留「周四」。（内部试用 D30）
4. **插进句子中间。** 光标在「我知道你就是▮的。」，说「就是从老家回来的」，得到「我知道你就是从老家回来的。」。（内部试用 D23）
5. **截图卡片拖进 Claude。** `⌥⇧A`，圈出有问题的按钮，说一句，把卡片拖进 Claude 桌面版：先进去图片，再在同一个输入框里贴上备注。
   拍中文版时可以换成飞书或微信。
6. **同一张卡片拖进终端。** Claude Code 拿到图片路径和一份 Markdown 备注，命令行里什么都不会执行。
7. **录屏整理成条目。** 一段 5 分钟、12 条的录屏，点「完成」后 51 秒就能开始审；一段 14 分钟的录屏，本地转写 12 秒，整理出 23 条，
   Agent 的 token 约 2.6 美元。（`README.md` FAQ）
8. **条目交给 Agent，再收回来。** 在一个条目上按 `⌘↩`，Codex 在 worktree 里开工；Agent 调用 `mark_fixed` 后，0.5 秒内条目显示「待验证」。
   （`promo/cases/v0.9-dogfood/work/timeline.md`）
9. **同事录的屏，你的 Agent 来处理。** 设计师用 App 录好，通过 Slack 或飞书把视频发过来；你对 Agent 说「处理这个视频」。交接说明里
   是本机文件路径，所以目前要分享的是视频本身。
10. **拔掉网线。** 听写照常工作（模型在本地）。上镜前先实测一遍：断网状态还没测过。

拍摄前先确认 10 月内部试用中发现的这些问题（`promo/cases/v0.9-dogfood/*/timeline.md`，有些可能已经修了）：Codex 在 worktree 里
提交前要手动批准；英文句子中间插入时，首字母大写没去掉（"I think The new layout is fine"）。

---

## 5. 口喷鸡刻意不做什么，为什么

- **不做连接器。** 你的 Agent 已经有飞书、Linear、Jira、Notion、Slack、GitHub 等的 MCP 和命令行工具。口喷鸡负责把你的话、截图和
  录屏送进 Agent，投递交给 Agent。口喷鸡自己只写文件：Markdown、CSV，以及交接包（一个 `.zip`，有概要、每一条和它的截图，只用相对
  路径），由 Agent 或你发到团队在用的地方。没有飞书导出，也没有导出设置；「把 A 模块的问题打包发给飞书群里的张三」是对 Agent 说的话。
  （`skills/blurt/SKILL.md` §6、`export_local.py bundle`、MCP `bundle_items`）
- **不做自己的 Agent。** 录屏由你已经安装并登录的第一个 coding agent 处理：先 Claude Code，然后 Codex、Kimi Code、OpenCode、
  Gemini CLI。Agent 自己会变强，下一个新 Agent 出来，口喷鸡也能配合。
- **不做云服务。** 没有口喷鸡的服务器，也不用注册账号。语音在你的电脑上转写。联网只有这几种情况：下载模型、检查更新、你自己加的云端语音密钥、
  你的 Agent 发给它的服务商的内容。
- **听写不改写。** 不概括、不翻译、不回答、不改语气。想要更整齐的版本，按 `⇧` 或 `⌥⇧L`。
- **不认口头指令。** 「帮我列个清单」「make a list」照原样打出来，因为你常常是在给 Agent 口述指令。
- **不悄悄学习。** 发现你在某个 App 里总是同样地切换风格，只问一次；不会自己改设置。

---

## 6. 常见问题素材

**我的声音会离开电脑吗？** 听写、截图和语音备注不会：识别和润色都在你的 Mac 上。听写的音频转写完就删除，除非你选择保留；听写历史保存
30 天。截图、语音备注和录屏留在你的文件夹里，直到你删除。Agent 把录屏整理成条目时，转写文字和几帧截图会发给这个 Agent 的服务商，
和你交给这个 Agent 的其他内容一样。

**要花钱吗？** 口喷鸡免费，MIT 协议，不限字数。录屏整理成条目用的是你自己的 Agent：三段 7–20 分钟的真实录屏，按 API 价格每段约
2–2.6 美元（`README.md` FAQ）。

**用哪些模型，多大？**（`skills/blurt/scripts/asr_models.json`、`polish_models.json`）

| 用途 | 模型 | 下载 | 内存峰值 |
|---|---|---|---|
| 听写识别，32 GB 及以上 | Qwen3-ASR 1.7B，8-bit，MLX | 2.5 GB | 3.1 GB |
| 听写识别，16–24 GB | Qwen3-ASR 0.6B，8-bit，MLX | 1.0 GB | 2.1 GB |
| 润色，16 GB 及以上 | Gemma 4 E2B，4-bit | 3.4 GB | 3.9 GB |
| 润色，8 GB | Qwen3 1.7B，4-bit | 0.9 GB | 2.1 GB |
| 语音备注、兜底、只有 CPU 的机器 | SenseVoice Small | 228 MB | 0.5 GB |
| 录屏（其他语言） | Whisper large-v3-turbo，MLX（4-bit 版 442 MB） | 1.5 GB | 3.7 GB |

推荐的听写组合，32 GB 的 Mac 约下载 5.9 GB，16–24 GB 约 4.4 GB（上表两项相加）。不点「下载」就什么都不下载。闲置 10 分钟后模型会
退出内存。

**支持哪些平台？** 听写、截图、语音备注和卡片：macOS，推荐的模型需要 Apple 芯片。录屏、本地转写、截帧、审核页和导出：macOS、
Windows、Linux（X11）。Windows 和 Linux 上的听写在计划中，还没做（`TODO.md`）。没有手机 App。

**支持哪些语言？** 听写测过中文、英文和中英混说。口喷鸡的模型清单里 Qwen3-ASR 列了 30 种语言，其他语言没有测过听写。录屏：SenseVoice
支持中、英、日、韩、粤语；Whisper 支持 99 种语言。条目用你说的语言写。App 界面有英文和简体中文。

**会取代我的 Agent 吗？** 不会。它配合你在用的 Agent：Claude Code、Codex、Cursor、Claude、ChatGPT、豆包，或者任何聊天框。

**需要哪些权限？** 麦克风；辅助功能（粘贴、识别 `Fn`）；输入监控（识别其他按键）；录屏（截图和录屏用，第一次用到时才问）。

---

## 没有出处的数字

下面这些在调研中出现过，但没能核实出处，不要发布。

- Superwhisper 的延迟：没有找到公开或实测的数字。
- Typeless、Wispr Flow、Superwhisper、Aqua Voice 在中文和中英混说上的准确率：都没有公开。
- 其他厂商博客里引用的 Wispr Flow、Superwhisper 延迟（700 毫秒、1,805 毫秒、「1–2 秒」）：页面打不开，或页面里没有这个数字。
- Aqua 的 Avalon 1.5 WER（5.55）和一次 965 毫秒的延迟测试：只在搜索摘要里看到，没在能读到的页面上看到。
- Typeless 目前免费版的字数：定价页只写「Limited, reset weekly」；2,000 这个数来自用户评论。
- Superwhisper 的年付和买断价格：只有第三方指南。
- 口喷鸡在 8 GB、16 GB Mac 上，用真实麦克风、带口音时的表现：没测。
- 口喷鸡断网时的听写：没测。
- 口喷鸡在 16 GB 以下 Mac 上的实时文字延迟：不适用（那里不显示灰色实时文字）；口喷鸡的粤语准确率：没测。
