<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="assets/peep-readme-dark.png"><img src="assets/peep-readme.png" width="132" alt="口喷鸡"></picture></p>
<h1 align="center">口喷鸡 Blurt</h1>
<p align="center"><b>Agent 时代的输入法</b><br>
用最高效的方式与你的 Agent 们互动，支持文字、语音、截图、录屏等。本地运行、免费开源。<br>
<a href="https://blurt.agihunt.info">官网</a> · <a href="README.md">English</a> · <a href="docs/guide.md#中文">使用指南</a></p>

<p align="center"><a href="https://blurt.agihunt.info/#film"><img src="assets/film-poster.jpg" width="720" alt="看两分钟的介绍视频"></a></p>
<p align="center"><sub>两分钟介绍视频，请打开声音 · <a href="https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg">下载 Mac 版</a></sub></p>

---

口喷鸡是一个 Mac 菜单栏 App，配合你已经在用的 Agent 工作，比如 Claude Code、Codex、Cursor、Claude、ChatGPT。
它负责 Agent 开始工作之前的那一步：把你想说的放进 Agent 的输入框。它自己不做 Agent，也不取代你的 Agent。

## 能做什么

**听写（`Fn`）。** 在任意 App 里按一下 `Fn`，说话，再按一下，字就打在光标处。结束时改成连按两下，会顺便发送出去（回车）。
语音识别用开源模型在你的 Mac 本地运行，模型下载好后无需联网；说话一分钟，停下后约 0.4 秒处理完。本机的模型会去掉语气词和口吃、
加上标点，但不改写、不概括、不翻译。说话时，识别出的文字显示在刘海下方。说话时按一下 `⇧` 切换到「结构化」（你在列举时排成清单），
再按一下切回来；`⌥⇧L` 重排上一条听写。也可以按住 `Fn` 说话。

**截图（`⌥⇧A`）和语音备注（`⌥⇧V`）。** 框选屏幕的一块区域，备注框就出现在选区旁边，说一句哪里不对。说话时可以直接在图上画：
拖动是自由画线，`⇧` 画方框，`⌥` 画椭圆，`⌘Z` 撤销。截图随后变成刘海下方的一张卡片。
把卡片拖进 Claude、ChatGPT、Slack、飞书，或运行着 Claude Code、Codex 的终端，图片和备注会一起进去；也可以点一下复制，
再按 `⌘V`。语音备注也一样，只是没有图片。

**录屏（`⌥⇧R`）。** 一边录屏一边讲：演示产品、浏览网页、讲一个想法都可以。你的 coding agent 会把录屏整理成条目
（问题、想法、笔记、任务），每条都带截图、标出的位置、复现步骤和可能有关的代码。录屏时实时语音转写，录屏结束后约一分钟即可处理完成；
一次 5 分钟的走查整理出了 52 条事项，每条都有原话和时间点。你用键盘逐条审核，再交给 Agent，或打成一个 `.zip` 发给同事。

截图、语音备注和录屏都会放进当前项目（在口喷鸡里打开的文件夹）。没有当前项目时，录屏放进「未归类」，截图作为卡片
留在刘海下方，等你选项目。所有快捷键都可以在设置里改。

## 安装

需要 macOS 13 或更新版本。听写和推荐的语音模型需要 Apple 芯片。

**[下载 Mac 版](https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg)**（已签名并经过 Apple 公证），打开后把口喷鸡拖进「应用程序」。之后的更新在 App 里完成。

也可以让你的 Agent 通过 skill 安装：

```bash
npx skills add AGIHunt/blurt
```

<sub>在 Claude Code 里也可以运行 <code>/plugin marketplace add AGIHunt/blurt</code>，或者把本仓库地址发给你的 Agent，让它安装这个 skill。</sub>

然后对 Agent 说 **「开始口喷」**。第一次运行会检查你的电脑、选好语音模型，并把口喷鸡 App 编译安装到 `~/Applications`。
这需要 Xcode Command Line Tools 和 [uv](https://docs.astral.sh/uv/)，缺什么 Agent 会提出帮你安装。

**第一分钟。** 设置助手会请你开启麦克风和「辅助功能」权限（听写键不用 `Fn` 时还需要「输入监控」），然后下载语音模型：
32 GB 内存的 Mac 约 5.9 GB，16–24 GB 约 4.4 GB。点「下载」之前不会下载任何东西。之后在任意输入框里按 `Fn` 就能听写。
「屏幕录制」权限在你第一次截图或录屏时才会请求。

## 怎么配合你的 Agent

口喷鸡把你的话、截图和录屏送进 Agent，具体的工作由 Agent 来做。

| | 做什么 |
|---|---|
| **听写和卡片** | 文字和图片进入任何聊天框或终端，所以适用于所有 Agent。 |
| **Skill** | `blurt` skill 让你的 Agent 能录屏、转写、写条目、打开审核页和导出。 |
| **MCP** | `blurt` MCP 提供 `search_items`、`get_item`（带截图）、`get_transcript`、`update_item`、`mark_fixed`、`bundle_items` 等工具。在「设置 → Agent」里点「连接…」，会先列出要改的地方，再把 skill 和 MCP 装进这个 Agent。 |
| **交给 Agent**（`⌘↩`） | 在口喷鸡的终端里、在项目文件夹中运行 Claude Code 或 Codex，可以每个条目用一个单独的 git worktree。Claude Code 也可以在 Claude 桌面端运行。 |
| **复制指令** | 给其他任何 Agent 的一行指令，指向一份交接说明，里面有全部详情和截图。 |
| **交接包** | 一个 `.zip`，包含概要、每个条目和它的截图，给人看，而不是给 Agent。 |

Agent 通过 MCP 回报进度：条目先变成「进行中」，再变成「待验证」。Agent 说「修好了」，在你标为完成之前一律只算「待验证」。

录屏由第一个已安装并登录的 Agent 整理：依次是 Claude Code、Codex、Kimi Code、OpenCode、Gemini CLI、Grok。顺序可以在
「设置 → Agent」里调整。

**刻意不做连接器。** 你的 Agent 已经有 Slack、Linear、GitHub、Notion、Jira、飞书等工具。口喷鸡只写文件（Markdown、CSV
和交接包），投递交给 Agent。想把条目发到别处，直接跟 Agent 说，比如：「把结账页的问题打包，发到 Slack 的 #web 频道」。

## 和同类产品的对比

核对日期：**2026-10-25**。价格和政策会变。

口喷鸡的数字来自自己的测试，只在一台机器上测过：Apple M5 Max、128 GB 内存，语音由 macOS `say` 生成。合成语音比真实
麦克风干净，错误率偏乐观；内存更小的 Mac、真实麦克风和口音都没有测。竞品的数字来自不同的人和方法，有的来自竞争厂商，
不能直接比较。

| | **口喷鸡** | Typeless | Wispr Flow | Superwhisper | Aqua Voice |
|---|---|---|---|---|---|
| 价格 | 免费，MIT 协议，不限字数 | 免费版每周有额度；Pro 按年付每月 12 美元，按月付 30 美元 [1] | 免费版桌面端每周 2,000 词；Pro 每月 15 美元，按年付每月 12 美元 [2] | 用本地模型免费；Pro 每月 8.49 美元 [3] | 免费 1,000 词；Pro 每月 12 美元，按年付每月 10 美元 [4] |
| 语音在哪里处理 | 你的 Mac 上 | 云端 [5] | 云端 [6] | 本地或云端，自己选 [7] | 云端 [8] |
| 说完到文字出现 | 说 3–60 秒后 0.29–0.54 秒 | 约 3.0 秒 [9] | 约 1.5 秒 [9] | 未公开 | 「about 450ms」（厂商自述）[8] |
| 英文准确率 | WER 1.9 %（只看识别模型） | WER 约 7.9 % [9] | WER 约 3.9 % [9] | 取决于所选模型；未公开 | OpenASR 平均 WER 6.24（厂商）[10] |
| 中文准确率 | CER 1.3 %（只看识别模型） | 未公开 | 未公开 | 未公开 | 未公开 |
| 平台 | macOS；Windows 和 Linux 即将推出 | macOS、Windows、Linux、iOS、Android | Mac、Windows、iOS、Android | Mac、Windows、iOS、Android | Mac、Windows、iOS、Android |
| 离线 | 模型下载好后听写不需要联网（还没在断网状态下实测） | 不能 | 不能 | 能，用本地模型时 | 不能 |
| 截图、语音备注卡片，交给 Agent | 有 | 没有 | 没有 | 没有 | 没有 |
| 录屏整理成带截图和代码定位的条目 | 有 | 没有 | 没有 | 没有 | 没有 |
| 交给 coding agent，并通过 MCP 回报状态 | 有 | 没有 | 没有 | 没有 | 免费版列出了「MCP/CLI」，没有细看 |

<sub>口喷鸡的出处：延迟见 `docs/design/dictation.md`（每项 3 次取中位数，模型已预热）；准确率见
`docs/design/asr-benchmark.md`（Qwen3-ASR 1.7B，每种语言 7 句 × 2 个声音）。完整数据和没能核实的数字见
[docs/positioning/facts.zh-CN.md](docs/positioning/facts.zh-CN.md)。
[1] [typeless.com/pricing](https://www.typeless.com/pricing) ·
[2] [wisprflow.ai/pricing](https://wisprflow.ai/pricing) ·
[3] [superwhisper.com](https://superwhisper.com/) ·
[4] [aquavoice.com/pricing](https://aquavoice.com/pricing) ·
[5] [Typeless 数据说明](https://typeless.com/data-controls)，2026-10-13 更新 ·
[6] [Wispr Flow 数据说明](https://wisprflow.ai/data-controls)，2026-08-18 更新 ·
[7] [Superwhisper 文档](https://superwhisper.com/docs/llms-full.txt) ·
[8] [Aqua 博客，2026-08-17](https://aquavoice.com/blog/wispr-flow-alternatives) ·
[9] [VoiceDash](https://voicedash.ai/wispr-flow-vs-typeless/)，竞争厂商；同一篇文章另一处给 Typeless 的数字约 20 % ·
[10] [Aqua 博客，2025-10-08](https://aquavoice.com/blog/avalon-openasr-leaderboard)。</sub>

## 用户对其他听写工具的抱怨，以及口喷鸡的做法

来自 App Store 美区 Typeless 和 Wispr Flow 的低分评论（2026-10-24 读取），以及 r/macapps、V2EX、Product Hunt 上的讨论。
计数和原话见 [facts.zh-CN.md 第 3 节](docs/positioning/facts.zh-CN.md#3-用户在抱怨什么口喷鸡怎么做)。

| 抱怨 | 口喷鸡的做法 |
|---|---|
| 改了我说的话 | 默认风格只去掉语气词、加标点。润色如果丢了或多了内容，就改为输入原始转写。只有按 `⇧` 才排成清单。 |
| 说的内容丢了、被截断 | 说话时就能看到文字。每条听写在「听写历史」里保存 30 天。按下键的那一刻就开麦，开头的字不会丢。 |
| 字数额度和订阅 | 免费，不限字数，不用注册账号。 |
| 人名和中英混说写不对 | 「词库」里是你常说的名字和术语，识别模型会参考；会从你的修改里学（只作提示，从不替换），也参考光标前后的文字。 |
| 麦克风一直开着，担心隐私 | 语音在你的 Mac 上处理。只在听写时开麦。听写不截屏。 |
| 慢 | 测试机上从松开按键到文字出现约 0.3–0.5 秒。 |
| 快捷键和 Fn 冲突 | 口喷鸡把 `Fn` 留给听写；macOS 或其他听写工具也会响应 `Fn` 时会提示你。也可以改用右 Option 或任一 Option 键。 |
| 长段听写在 Claude Code 里折叠成「[Pasted N lines]」 | 在终端和代码编辑器里，文字保持一行。 |

还没做的：粘贴确认之前一直保留听写的音频；只识别你说的那几种语言的设置。

## 隐私

- 语音识别和润色都在你的 Mac 上运行。听写的音频转写完就删除，除非你选择保留；文字在「听写历史」里保存 30 天（可以改）。
- 开始说话时，口喷鸡会读取光标前后约 500 个字，让名字写对。只用于这一次听写，从不读密码框。这项可以关掉。
- 截图、语音备注、录屏和条目都留在你的文件夹里：`~/Blurt`，或项目里的 `.blurt/`（口喷鸡会让它不进 git）。
- 你的 Agent 整理录屏时，转写文字和几张截图会发给这个 Agent 的服务商，和你交给它的其他内容一样。
- 没有口喷鸡的服务器，也不用注册账号。联网只有这几种情况：下载模型、检查更新、你自己加的云端语音密钥（Groq、OpenAI 或
  DashScope，用于录屏），以及你的 Agent 发给它的服务商的内容。打开「设置 → 隐私 → 不用云端语音识别」，即使设置了密钥，
  语音也只在 Mac 上识别。

## 常见问题

**会取代我的 Agent 吗？** 不会。它配合你在用的 Agent：Claude Code、Codex、Cursor、Claude、ChatGPT，或者任何聊天框。

**要花钱吗？** 不用。录屏整理成条目用的是你自己 Agent 的 token。视频不会发给模型：语音在本地转写，Agent 读文字稿，
只看几张截图。三次真实使用（Claude Code、Opus 5.5、一个线上 Web 产品）：

| 录屏 | 说话 | 条目 | 本地转写 | 新输入 / 输出 token | 按 API 价格 |
|---|---|---|---|---|---|
| 7.0 分钟 | 2.8 分钟 | 9 条 | 4 秒 | 约 14 万 / 1.9 万 | 约 2 美元 |
| 14.3 分钟 | 12.3 分钟 | 23 条 | 12 秒 | 约 14 万 / 2.7 万 | 约 2.6 美元 |
| 20.0 分钟 | 17.7 分钟 | 34 条 | 15 秒 | 约 12 万 / 2.7 万 | 约 2.1 美元 |

<sub>上表已包含对话上下文的缓存读取（约 300–500 万 token，按输入价的 1/20 计费）。</sub>

**录完多久能审核？** 点「完成」后大约 1 分钟，截图在你审核时陆续补上。一段 5 分钟、12 条的真实录屏，51 秒就能开始审核。

**用哪些模型，多大？**

| 用途 | 模型 | 下载大小 |
|---|---|---|
| 听写，32 GB 及以上内存 | Qwen3-ASR 1.7B，8-bit，MLX | 2.5 GB |
| 听写，16–24 GB | Qwen3-ASR 0.6B，8-bit，MLX | 1.0 GB |
| 润色，16 GB 及以上 | Gemma 4 E2B，4-bit | 3.4 GB |
| 润色，8 GB | Qwen3 1.7B，4-bit | 0.9 GB |
| 语音备注；只有 CPU 的机器 | SenseVoice Small | 228 MB |
| 其他语言的录屏 | Whisper large-v3-turbo，MLX | 1.5 GB |

闲置 10 分钟后模型会退出内存。

**支持哪些语言？** 听写测过中文、英文和中英混说。录屏：SenseVoice 支持中、英、日、韩、粤语；Whisper 支持 99 种语言。
条目用你说的语言写。App 界面有英文和简体中文。

**Windows 和 Linux 能用吗？** 还不能：口喷鸡目前是 Mac App，Windows 和 Linux 版即将推出。想提前试的话，Skill 里的录屏脚本
（录屏、本地转写、审核页、导出）已经能在这两个系统上运行，Linux 需要 X11 桌面。准备工作：Windows 运行
`winget install astral-sh.uv` 和 `winget install Gyan.FFmpeg`；Ubuntu/Debian 运行
`sudo apt install ffmpeg libportaudio2 python3-tk`，再装 [uv](https://docs.astral.sh/uv/)。`doctor.py` 会告诉你缺什么。

**需要哪些权限？** 麦克风；「辅助功能」，用来粘贴和识别 `Fn`；「输入监控」，用来识别其他按键；「屏幕录制」，用来截图和录屏。

**没有代码的同事能用吗？** 能。他们用 App 录屏，把视频发给你，你的 Agent 结合代码处理。条目会保留录制人的名字。

**快捷键能改吗？** 能，在「设置 → 快捷键」里改。快捷键被其他功能、其他 App 或 macOS 占用时会提示。同样的设置也可以写在
`~/.blurt/config.json` 里，Windows 上也生效：

```json
{"record": {"hotkeys": {"record": "ctrl+opt+R", "snap": "opt+shift+A", "pause": "off"}, "draw_key": "control"}}
```

**完整的说明在哪？** [使用指南](docs/guide.md#中文)讲了所有功能，[SKILL.md](skills/blurt/SKILL.md) 是给 Agent 读的说明。

<p align="center"><sub>MIT · <a href="https://github.com/AGIHunt">AGI Hunt</a> 出品</sub></p>
