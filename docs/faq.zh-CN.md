# 口喷鸡：对比、隐私和常见问题

[README](../README.zh-CN.md) · [English](faq.md)

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
| 平台 | macOS；Windows 和 Linux 有测试版 | macOS、Windows、Linux、iOS、Android | Mac、Windows、iOS、Android | Mac、Windows、iOS、Android | Mac、Windows、iOS、Android |
| 离线 | 模型下载好后听写不需要联网（还没在断网状态下实测） | 不能 | 不能 | 能，用本地模型时 | 不能 |
| 截图、语音备注卡片，交给 Agent | 有 | 没有 | 没有 | 没有 | 没有 |
| 录屏整理成带截图和代码定位的事项 | 有 | 没有 | 没有 | 没有 | 没有 |
| 交给 coding agent，并通过 MCP 回报状态 | 有 | 没有 | 没有 | 没有 | 免费版列出了「MCP/CLI」，没有细看 |

<sub>口喷鸡的出处：延迟见 `docs/design/dictation.md`（每项 3 次取中位数，模型已预热）；准确率见
`docs/design/asr-benchmark.md`（Qwen3-ASR 1.7B，每种语言 7 句 × 2 个声音）。完整数据和没能核实的数字见
[docs/positioning/facts.zh-CN.md](positioning/facts.zh-CN.md)。
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
计数和原话见 [facts.zh-CN.md 第 3 节](positioning/facts.zh-CN.md#3-用户在抱怨什么口喷鸡怎么做)。

| 抱怨 | 口喷鸡的做法 |
|---|---|
| 改了我说的话 | 默认风格只去掉语气词、加标点。润色如果丢了或多了内容，就改为输入原始转写。只有按两下 `⇧` 才排成清单。 |
| 说的内容丢了、被截断 | 说话时就能看到文字。每条听写在「听写历史」里保存 30 天。按下键的那一刻就开麦，开头的字不会丢。 |
| 字数额度和订阅 | 免费，不限字数，不用注册账号。 |
| 人名和中英混说写不对 | 「词库」里是你常说的名字和术语，识别模型会参考；会从你的修改里学（只作提示，从不替换），也参考光标前后的文字。 |
| 麦克风一直开着，担心隐私 | 语音在你的 Mac 上处理。只在听写时开麦。听写不截图。 |
| 慢 | 测试机上从松开按键到文字出现约 0.3–0.5 秒。 |
| 快捷键和 Fn 冲突 | 口喷鸡把 `Fn` 留给听写；macOS 或其他听写工具也会响应 `Fn` 时会提示你。也可以改用右 Option 或任一 Option 键。 |
| 长段听写在 Claude Code 里折叠成「[Pasted N lines]」 | 在终端和代码编辑器里，文字保持一行。 |

还没做的：粘贴确认之前一直保留听写的音频；只识别你说的那几种语言的设置。

## 隐私

- 语音识别和润色都在你的 Mac 上运行。「听写历史」保存每条听写的文字、录音和光标附近的文字，留 30 天（时长可以改，也可以不留录音）。
- 开始说话时，口喷鸡会读取光标前后约 500 个字，让名字写对。从不读密码框。这项可以关掉。
- 截图、语音备注、录屏和事项都留在你的文件夹里：`~/Blurt`，或项目里的 `.blurt/`（口喷鸡会让它不进 git）。
- 你的 Agent 整理录屏时，转写文字和几张截图会发给这个 Agent 的服务商，和你交给它的其他内容一样。
- 不用注册账号。联网只有这几种情况：下载模型和 Python 运行环境、检查更新、你自己加的云端语音密钥（Groq、OpenAI 或 DashScope，在「设置 → 模型」里填）、
  打开了云端润色时（听写的文字发给 DeepSeek 或你设的接口，不发录音）、打开了云端翻译时（发文字）、
  截图取字选了云端二次识别时（发你框选区域的图片）、
  你的 Agent 发给它的服务商的内容、在外用手机连接（经你自己的中转，全程端到端加密），以及「发送反馈」：在听写页点它时，你勾选的听写（录音、每一步的文字、保留开关打开时的
  光标附近文字、Mac 的型号和设置）会发到口喷鸡在 Cloudflare 上的私有存储，只有口喷鸡的开发者能读，14 天内删除。把「设置 → 隐私 → 语音识别」设为「仅本机」，即使设置了密钥，
  语音也只在 Mac 上识别。

## 常见问题

**会取代我的 Agent 吗？** 不会。它配合你在用的 Agent：Claude Code、Codex、Cursor、Claude、ChatGPT，或者任何聊天框。

**要花钱吗？** 不用。录屏整理成事项用的是你自己 Agent 的 token。视频不会发给模型：语音在本地转写，Agent 读文字稿，
只看几张截图。三次真实使用（Claude Code、Opus 5.5、一个线上 Web 产品）：

| 录屏 | 说话 | 事项 | 本地转写 | 新输入 / 输出 token | 按 API 价格 |
|---|---|---|---|---|---|
| 7.0 分钟 | 2.8 分钟 | 9 条 | 4 秒 | 约 14 万 / 1.9 万 | 约 2 美元 |
| 14.3 分钟 | 12.3 分钟 | 23 条 | 12 秒 | 约 14 万 / 2.7 万 | 约 2.6 美元 |
| 20.0 分钟 | 17.7 分钟 | 34 条 | 15 秒 | 约 12 万 / 2.7 万 | 约 2.1 美元 |

<sub>上表已包含对话上下文的缓存读取（约 300–500 万 token，按输入价的 1/20 计费）。</sub>

**录完多久能审核？** 点「完成」后大约 1 分钟，截图在你审核时陆续补上。一段 5 分钟、12 条的真实录屏，51 秒就能开始审核。

**用哪些模型，多大？**

| 用途 | 模型 | 下载大小 |
|---|---|---|
| 语音识别，16 GB 及以上的 Mac | Qwen3-ASR 1.7B，8-bit，MLX | 2.5 GB |
| 语音识别，8 GB 的 Mac 和基础款 M1、M2，说中文、英文、日语的用户 | Fun-ASR-Nano | 1.6 GB |
| 同上，说其他语言的用户 | Qwen3-ASR 0.6B，8-bit，MLX | 1.0 GB |
| 润色，16 GB 及以上（8 GB 的 Mac 不在本机润色） | Gemma 4 E2B，4-bit | 3.4 GB |
| 只有 CPU 的机器上的语音备注；日语、韩语、粤语 | SenseVoice Small | 228 MB |
| 其他语言的录屏 | Whisper large-v3-turbo，MLX | 1.5 GB |

用的时候，1.7B 和 Gemma 分别占内存约 3.1 GB 和 2.3 GB。闲置 10 分钟后退出内存，内存紧张时会更早退出。macOS 26 上，
这台 Mac 的模型下载好之前，由系统自带的识别来听写。

**支持哪些语言？** 听写测过中文、英文和中英混说。录屏：SenseVoice 支持中、英、日、韩、粤语；Whisper 支持 99 种语言。
事项用你说的语言写。App 界面有英文和简体中文。

**Windows 和 Linux 能用吗？** 能，[GitHub Releases](https://github.com/AGIHunt/blurt/releases) 上有测试版：Windows 10（1903 及以上）和 11，Linux（Ubuntu 24.04
及以上、Debian 13 及以上；在 Ubuntu 的 GNOME + Wayland 上测过）。可以听写（Windows 上按右 Alt；Linux 上第一次使用时自己选快捷键）、
录语音备注和录屏，语音在本机 CPU 上识别（下载约 1 GB）。Windows 上还有截图和截图取字，Linux 上还没做好。润色需要云端 key，
刘海是一个小胶囊，更新要自己下载新版。Windows 安装包还没有签名，SmartScreen 会先提示，点「更多信息 → 仍要运行」。
不装 App 的话，Skill 里的录屏脚本（录屏、本地转写、审核页、导出）也能在这两个系统上运行，Linux 需要 X11 桌面。准备工作：Windows 运行
`winget install astral-sh.uv` 和 `winget install Gyan.FFmpeg`；Ubuntu/Debian 运行
`sudo apt install ffmpeg libportaudio2 python3-tk`，再装 [uv](https://docs.astral.sh/uv/)。`doctor.py` 会告诉你缺什么。

**需要哪些权限？** 麦克风；「辅助功能」，用来粘贴和识别 `Fn`；「输入监控」，用来识别其他按键；「屏幕录制」，用来截图和录屏。

**没有代码的同事能用吗？** 能。他们用 App 录屏，把视频发给你，你的 Agent 结合代码处理。事项会保留录屏人的名字。

**快捷键能改吗？** 能，在「设置 → 快捷键」里改。快捷键被其他功能、其他 App 或 macOS 占用时会提示。同样的设置也可以写在
`~/.blurt/config.json` 里，Windows 上也生效：

```json
{"record": {"hotkeys": {"record": "ctrl+opt+R", "snap": "opt+shift+A", "pause": "off"}, "draw_key": "control"}}
```

**完整的说明在哪？** [使用指南](guide.md#中文)讲了所有功能，[SKILL.md](../skills/blurt/SKILL.md) 是给 Agent 读的说明。
