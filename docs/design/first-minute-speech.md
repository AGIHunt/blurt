# 设计：第一分钟就能用的语音（不下载模型）

2026-10-29。问题：新用户装好 Blurt，按 Fn 只看到「还没有语音模型（2.5 GB）· 下载」。在那之前还要同意安装 uv、
等 Python 和依赖（uv 44 MB + Python 约 55 MB + numpy / sherpa-onnx 等约 55 MB，合计约 150 MB）。听写、语音笔记（⌥⇧V）、录屏转写都卡在这一步。

目标：装好就能按 Fn 出字，不下载任何模型；想要更准、要离线、要省钱的人，再换成本机模型。普通 Mac（8 / 16 GB）
也要顺；以后 Windows / Linux 有对应的路；云端费用对用户是免费或每月几块到几十块钱。

本文先给测量结果（§1–§3），再给方案（§4–§6），最后是要创始人拍板的几件事（§7）。

## 1. 测了什么

| 测试集 | 内容 | 参考答案 |
|---|---|---|
| Lab 金标（13 条） | 创始人在 Dictation Lab 里录的、改过正确答案的口述，1.7–11 秒，中文夹英文术语 | 人工改过的正确文本 |
| 保留的听写（270 条） | 10-23 到 10-29 真实听写里保留了音频的全部，中位 9 秒，最长 2 分多钟，共 79 分钟 | 当时实际打出来的字（Qwen3-ASR 1.7B + 润色，用户没改） |
| LibriSpeech（100 条） | test-clean 60 + test-other 40，英文朗读 | 数据集标注 |

- 错误率用 Dictation Lab 自己的口径（`dictation_lab.py score`）：一个汉字、一个英文词各算一个单位，不计标点、
  不分大小写。数字写法不同（30 / 三十）也算错，所有引擎一样吃亏。
- 「保留的听写」的参考答案本身是 1.7B 加润色的结果，所以 **1.7B 在这一列天然占便宜**，只能看作上限；其它引擎
  之间的比较是公平的。
- 词表：创始人现在的 36 个自定义词（Claude Code、Codex、tmux、口喷鸡……）。每个引擎都按它能接受的方式喂进去
  （Qwen 的上下文、Apple 的 `contextualStrings`；SenseVoice 不支持）。「术语」列是这些词在参考答案里出现的 35 次里
  认对了几次。
- 机器：M5 Max 128 GB，macOS 26.5。整段一次识别（不切片）。数据和脚本：`promo/cases/first-minute-asr/`（不进 git）。

## 2. 结果

### 2.1 识别本身（未润色）

| 引擎 | 要下载 | 内存 | Lab 金标 | 保留的听写 | 术语 | 英文 Libri | 处理 1 秒音频 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Apple SpeechTranscriber**（macOS 26，zh_CN / en_US） | 0（系统语言包，见 §2.3） | 系统进程约 0.45 GB | 4.6 % | 10.1 % | 5 / 35 | 4.0 % | 14 ms |
| Apple DictationTranscriber（macOS 26） | 0 | 同上 | 10.0 % | 15.1 % | 12 / 35 | 12.3 % | 39 ms |
| SenseVoice Small | 228 MB | 0.54 GB | 3.9 % | 8.8 % | 3 / 35 | 6.4 % | 14 ms |
| Qwen3-ASR 0.6B（MLX） | 1.0 GB | 2.1 GB | 4.6 % | 7.1 % | 25 / 35 | 3.2 % | 22 ms |
| Qwen3-ASR 1.7B（MLX，现在的默认） | 2.5 GB | 3.1 GB | 6.4 % | 5.2 %（上限） | 28 / 35 | 2.7 % | 30 ms |

看点：
- **Apple 的 SpeechTranscriber 能用**：中文比 SenseVoice 差 1.3 个点、比 Qwen 0.6B 差 3 个点；英文比 SenseVoice
  好、接近 Qwen 0.6B。错误主要是近音词（「云端润色」→「云朵的云色」、「语种」→「鱼种」）和长句中间乱断句号。
  空白清晰的短句基本全对。
- **DictationTranscriber 不行**：名字像是给听写用的，但会吞句尾的字（「他应该 get 了」→「他应该get」，
  「合并到 main 分支」→「何必让慢分之」），三个测试集都最差。不用。
- **自定义词只有 Qwen 真正吃得进去**（25–28 / 35）。Apple 的 `contextualStrings` 几乎没用（5 / 35）。
- 金标只有 13 条，几个引擎相差一两个字，排名不稳；看 270 条那一列。

### 2.2 加上云端润色（已配置的 DeepSeek Flash，Light 提示词 + 36 个词）

同一批识别结果送 `polish_cloud.py`（和 app 里一样的提示词），再和参考答案比：

| 识别 + DeepSeek 润色 | 保留的听写 | 术语 | 润色耗时（中位 / p90） |
|---|---:|---:|---:|
| Apple SpeechTranscriber + DeepSeek | 9.4 % | **32 / 35** | 1.0 / 1.4 s |
| SenseVoice + DeepSeek | 8.6 % | 30 / 35 | 1.0 / 1.3 s |
| Qwen3-ASR 0.6B + DeepSeek | 8.0 % | 29 / 35 | 1.0 / 1.3 s |

- 润色把 Apple 认错的术语几乎全救回来（5 → 32）。错误率这一列润色后反而有升有降，是因为参考答案是本机 Gemma
  润色的文风，DeepSeek 改写的地方也算「错」；三行之间可比，和 §2.1 不可比。
- 结论：**Apple 识别 + 一个云端 key 润色**，和本机 Qwen 0.6B + 润色的差距缩到 1.4 个点，术语还更好。
  这就是「第一分钟」该给的组合。
- 每条润色约 925 个输入 token、30 个输出 token。

### 2.3 Apple 引擎的延迟、首次、内存

| 项目 | 结果 |
|---|---|
| 松手到文字（按真实速度喂 100 ms 的音频块，松手后 finalize） | SpeechTranscriber 中位 **58 ms**，p90 144 ms（13 条）；对比本机 Qwen 整条流程约 0.31 s（dictation.md §Recognition model） |
| 冷启动（新进程第一次识别一条 11 秒的音频，含加载） | 0.29–0.37 s |
| 系统语言包 | 这台 Mac 上 zh_CN 已经在（系统听写用过）；en_US 没有，`AssetInventory` 下载装好用了 25 秒，约 390 MB，存在系统目录里，不算 Blurt 的磁盘 |
| 权限 | `SpeechAnalyzer` 不用「语音识别」权限，没有弹窗（老的 `SFSpeechRecognizer` 要） |
| 内存 | 我们的进程 +19 MB；识别在系统的 `localspeechrecognition` 进程里，用的时候约 0.45 GB，闲了系统自己收 |
| 语言 | SpeechTranscriber 支持 30 个地区（zh_CN / zh_TW / zh_HK / yue_CN / en_* / ja / ko / fr / de / es / it / pt…）；**一个识别器一种语言，没有自动判断**。中文识别器认得中间的英文词（AI、case、GA、get），所以中英混说用 zh_CN 就行；只说英文的用户用 en_US |
| 系统版本 | 只有 macOS 26 起有；macOS 13–15 只能用老的 `SFSpeechRecognizer`（要权限，本次没测，见 §7） |
| 实时字 | 有「临时结果」（volatile），说话时就能显示，不用像现在这样每秒重解一次 |

### 2.4 云端识别：百炼 qwen3-asr-flash，原速 / 1.5 倍速 / 2 倍速

创始人提供了百炼 key（2026-10-29）。同样的三个测试集，整条音频一次送（OpenAI 兼容接口，36 个词作上下文，
`enable_itn`），并发 4（限流是每分钟 100 次，超了的单独重试）。加速用 ffmpeg `atempo`（音调不变），再转回
16 kHz。计费看接口返回的 `usage.seconds`：按每次请求的秒数取整（向下），所以实付比音频时长还少约 3 %。

| | 保留的听写（270 条） | 术语 | Lab 金标 | 英文 Libri | 计费秒数 / 原音频 | 延迟（≤ 10 秒的条，中位 / p90） |
|---|---:|---:|---:|---:|---:|---:|
| 原速 | **6.8 %** | 27 / 35 | 6.8 % | 3.5 % | 97 % | 758 / 1138 ms |
| 1.5 倍速 | 8.0 % | 26 / 35 | 6.8 % | 3.7 % | 64 % | 691 / 974 ms |
| 2 倍速 | 11.6 % | 23 / 35 | 11.4 % | 4.7 % | 47 % | 664 / 900 ms |

对比（§2.1，同一批音频）：本机 Qwen3-ASR 0.6B 7.1 %、Apple 10.1 %、1.7B 5.2 %（上限）。云端原速和本机 0.6B 差不多，
术语 27 / 35 也接近（0.6B 25、1.7B 28）。注意：参考答案是本机 Qwen3-ASR 的结果，云端也是 Qwen3-ASR 家族，
可能有一点同源的便宜。

**加速划不划算：**
- **1.5 倍：可以。** 钱省 34 %，中文错误率多 1.2 个点（6.8 → 8.0），英文几乎不变（3.5 → 3.7），延迟还快了约 70 ms
  （要传、要算的音频少了）。
- **2 倍：不行。** 钱省 51 %，但中文错误多了七成（6.8 → 11.6），术语掉到 23 / 35，而且 2 条音频模型没认出话来，
  直接把上下文里的词表当成结果吐了出来（「Claude Code，Codex，blurt，口喷鸡，ordo-platform……」）。原速和 1.5 倍
  一次都没有。中文本来就快，两倍以后很多字挤在一起，听成别的词（「启动阶段」→「去到阶段」）。
- 加速在本机做（app 里用 AVAudio 的变速不变调），几毫秒，不另花钱。

**云端识别 + 润色（保留的听写，和参考答案比）：**

| 组合 | 错误率 | 术语 | 每月（普通用户） |
|---|---:|---:|---:|
| 百炼原速 + DeepSeek 润色 | **7.6 %** | 31 / 35 | ¥8.5 + ¥3 ≈ ¥11 |
| Apple + DeepSeek 润色 | 9.4 % | 32 / 35 | ¥3 |
| 本机 Qwen 0.6B + DeepSeek 润色 | 8.0 % | 29 / 35 | ¥3 |

云端识别比 Apple 好 1.8 个点，每月多花约 ¥8.5（1.5 倍速是 ¥5.6）。

### 2.5 一个阿里云百炼的 key：润色、翻译、截图取字

创始人定：国内默认推荐阿里的 key（2026-10-29）。百炼上能用的模型很多（`/compatible-mode/v1/models` 列出 184 个），
除了千问，还托管了 DeepSeek V4.1 Flash。问题出在旧的 `qwen-flash` / `qwen-plus` 别名，不在提示词：换模型、
关掉思考（`enable_thinking: false`，Qwen3.x 和 DeepSeek 在百炼默认会思考）之后，同一个提示词就不改写了。

**润色**（同一个 Light 提示词、同样的 Apple 识别结果，270 条保留的听写 + 13 条金标）：

| 润色模型 | 保留的听写 | 术语 | 金标 | 耗时（中位 / p90） |
|---|---:|---:|---:|---:|
| DeepSeek Flash（DeepSeek 官方，对照） | **9.4 %** | **32 / 35** | 4.3 % | 1.0 / 1.4 s |
| **DeepSeek V4.1 Flash（百炼）** | 9.6 % | **32 / 35** | 3.2 % | **0.8** / 1.2 s |
| qwen3.6-flash | 9.7 % | 25 / 35 | 2.1 % | 0.6 / 1.0 s |
| qwen3.7-flash | 10.0 % | 27 / 35 | 2.1 % | 0.8 / 1.3 s |
| qwen3.8-flash | 10.0 % | 30 / 35 | 2.8 % | 1.0 / 1.8 s |
| qwen-flash（旧别名） | 15.4 % | 28 / 35 | 4.6 % | 0.6 / 1.1 s |
| qwen-plus（旧别名） | 18.2 % | 26 / 35 | 4.3 % | 0.9 / 2.1 s |

旧别名会改写、压缩，甚至补出没说过的内容（把「binlog 解析」写成「通过阿里 DTS 或者其他服务」）；新的 Qwen3.x
和 DeepSeek 都不会。百炼上的 DeepSeek V4.1 Flash 和官方 DeepSeek 几乎一样（术语一样多），还快 0.2 秒。

**翻译**（听写翻译那套 60 条：40 条中文 + 20 条英文，`translate_system` 共用提示词，对 Light 结果翻译；两位盲评，
相关系数 0.94；1–10 分 =「能不能不改就发出去」）：

| 翻译模型 | 质量 | 必须改 | 中→英 | 英→中 | 耗时（中位 / p90） |
|---|---:|---:|---:|---:|---:|
| qwen3.8-flash | **8.5** | 3 / 60 | 8.2 | 9.1 | 1.1 / 1.8 s |
| DeepSeek Flash（官方，对照） | 8.4 | 3 / 60 | 8.0 | 9.2 | 1.0 / 1.3 s |
| **DeepSeek V4.1 Flash（百炼）** | 8.4 | 3 / 60 | 8.0 | 9.2 | 0.9 / 1.2 s |
| qwen3.6-flash | 7.8 | 7.5 / 60 | 7.5 | 8.3 | 0.7 / 1.2 s |

**截图取字的云端第二段**（`tests/fixtures/screen_text`，17 张有草稿的截图；字符错误率：Vision 草稿 / 模型自己读 / 合并后）：

| 模型 | 草稿 | 模型自己 | 合并后 | 耗时（中位 / 最长） |
|---|---:|---:|---:|---:|
| DeepSeek Flash（官方，对照） | 0.74 % | 19.7 % | **0.16 %** | 1.1 / 1.7 s |
| **qwen3.6-flash** | 0.74 % | 19.5 % | **0.16 %** | **0.8** / 1.5 s |
| qwen3.5-flash | 0.74 % | 19.5 % | 0.16 % | 0.9 / 1.9 s |
| qwen3.8-flash | 0.74 % | 19.6 % | 0.19 % | 1.3 / 3.1 s |
| qwen3-vl-plus | 0.74 % | 18.6 % | 0.20 % | 2.4 / 5.0 s |
| qwen3.5-ocr | 0.74 % | 23.4 % | 1.32 % | 0.7 / 1.6 s |
| qwen-vl-ocr | — | — | 4.6 %，2 张返回空 | 1.1 / 1.8 s |
| DeepSeek V4.1 Flash（百炼） | — | — | 13 张里 3 张超时 / 503，中位 26 秒，不能用 | |

**结论：一个百炼 key 就够。** 润色和翻译用百炼上的 DeepSeek V4.1 Flash（和官方 DeepSeek 一样好），截图取字用
qwen3.6-flash（看图的模型；百炼上的 DeepSeek 看图太慢），语音识别用 qwen3-asr-flash（1.5 倍速）。
价格：DeepSeek V4.1 Flash 在百炼和官方同价（输入 ¥2、输出 ¥8 / 百万 token，闲时半价）；qwen3.6-flash 输入 ¥1.2、
输出 ¥7.2。普通用户（每天 100 条、30 分钟）每月约：识别 ¥5.6 + 润色 ¥3 ≈ **¥9**；用 Apple 识别只要润色那 ¥3。

本节花费（按返回的 token 数和单价估算）：润色约 ¥1.5、截图取字约 ¥0.3、翻译约 ¥0.3，约 ¥2；§2.4 的识别另花了约 ¥2.9。数据：
`promo/cases/first-minute-asr/out/`（`*+deepseek-v4.1-flash.jsonl`、`st-*.json` 等）。

## 3. 每月花多少钱

用量按创始人自己的记录估：10-23 到 10-29 每天 37–155 条、12–55 分钟，平均每天约 90 条、25 分钟。

| 用户 | 每天说话 | 每天条数 | 每月天数 |
|---|---:|---:|---:|
| 轻度 | 10 分钟 | 35 | 22 |
| 普通 | 30 分钟 | 100 | 22 |
| 重度 | 60 分钟 | 200 | 30 |

| 方案 | 轻度 | 普通 | 重度 |
|---|---:|---:|---:|
| Apple 识别，不润色 | ¥0 | ¥0 | ¥0 |
| Apple 识别 + DeepSeek 润色（实测 ≈ ¥0.0013 / 条） | ¥1 | ¥3 | ¥8 |
| 百炼 qwen3-asr-flash 识别，原速（实测计费 = 音频的 97 %） | ¥2.8 | ¥8.5 | ¥23 |
| 同上，1.5 倍速（计费 64 %，错误率 +1.2 点） | ¥1.9 | ¥5.6 | ¥15 |
| 同上，2 倍速（计费 47 %，错误率 +4.8 点，不推荐） | ¥1.4 | ¥4.1 | ¥11 |
| 百炼识别（原速）+ DeepSeek 润色 | ¥4 | ¥11.5 | ¥31 |
| 上面再加「重听」（每段在 10 秒窗口里再识别一遍，云端费用翻倍） | ¥7 | ¥20 | ¥55 |
| 本机模型 | ¥0（一次下载 1–6 GB） | ¥0 | ¥0 |

- 都在「免费到几十块」之内。**最省的有效组合是 Apple 识别 + 云端润色：普通用户每月约 ¥3。**
- 云端识别不能照搬现在的做法：现在说话时每秒重解一次当前片段（实时字），每段音频要送好几遍，费用跟着翻几倍。用云端识别时，
  实时字改用 Apple 的临时结果（免费、本机），云端只识别切好的片段；「重听」在云端默认关。
- 录屏转写：1 小时录音 ¥0.79（百炼）。语音笔记跟听写同价。截图取字云端第二段 ≈ ¥0.001 / 次（screen-text.md）。

## 4. 方案：先能用，再换本机模型

### 4.1 三档

| 档 | 识别 | 润色 | 要下载 | 什么时候 |
|---|---|---|---|---|
| **马上用**（默认） | Apple SpeechTranscriber（macOS 26+） | 有 key：云端；没有：不润色，打出带标点的原文 | 0 | 装好就是这一档 |
| **加一个 key** | 同上，或云端识别（百炼 / OpenAI 兼容） | 云端 | 0 | 用户在一个地方填 key |
| **本机模型** | Qwen3-ASR 0.6B / 1.7B | Gemma 4 E2B，或继续云端 | 1–6 GB | 用户点「换成本机模型」 |

- 「马上用」时 Fn 不再等任何下载：麦克风 + 辅助功能权限一开就能说。
- Python 工具（uv、依赖，约 150 MB）只在要润色、要本机模型、要转写录屏时才需要；在后台装，不挡听写。
- 本机模型下好之后自动接手（现在的「自动」逻辑不变：装好的推荐模型优先）。Apple 留作兜底：本机模型没装好、
  内存紧张被系统收掉、或者下载中途，听写都不会停。

### 4.2 设置助手的模型这一步

现在：三行模型 + 总大小 + 「下载模型」（主按钮）。

改成：

1. 标题「听写已经可以用了」。一行：「用 macOS 自带的语音识别，不用下载。」
2. **一个 key**（可选）：「加一个 AI 服务的 key，听写会帮你改错字、加标点、认对专有名词。」服务选择 + key 输入框
   + 测试。润色默认 DeepSeek（推荐），也可以选阿里云百炼（§2.5）或 OpenAI / Anthropic 兼容的服务；语音识别推荐阿里云百炼。
3. **本机模型**（升级，次要按钮）：「想离线用、或者更准：下载本机模型（1.0 GB）。」大小按这台 Mac 的档位
   （§5）。点了就进现在的下载管理器，后台下，不挡下一步。
4. 主按钮是「下一步」，不是下载。试一试那一步不再因为「识别模型还在下载」被挡住。

岛上的提示同步改：没有本机模型时不再说「还没有语音模型（2.5 GB）」，而是直接用 Apple；用了几天（比如 50 条后）
在听写页提一次「换成本机模型会更准，认得你的词」，可以关掉。

### 4.3 一个 key，四处用

现在 key 分三处：云端润色（Keychain「Blurt Cloud Polish」，按服务商）、云端识别（「Blurt Cloud Speech」，按模型）、
截图取字借用润色的。改成一个「AI 服务」：

| 服务 | 听写识别 | 润色 | 语音笔记 / 录屏转写 | 截图取字 |
|---|---|---|---|---|
| 阿里云百炼（国内推荐） | qwen3-asr-flash（1.5 倍速） | DeepSeek V4.1 Flash（百炼托管） | qwen3-asr-flash | qwen3.6-flash |
| OpenAI（或兼容） | gpt-4o-mini-transcribe | 用户填的模型 | 同左 | 同左（带图） |
| DeepSeek | —（继续 Apple / 本机） | deepseek-flash | — | deepseek（带图） |
| Groq | whisper-large-v3-turbo | 用户填的模型 | 同左 | — |

- 一份 Keychain 记录（服务 + key），四个功能按上表各取所需；不支持的那一项退回 Apple / 本机，界面上说清楚。
- 设置 → 模型 里原来的「云端润色」「云端识别」两个入口合成这一个；老用户的 key 迁过来，不用重填。
- 隐私说明合成一段：发出去的是什么（识别：音频片段；润色：文字和自定义词；截图取字：截图），不发什么。

## 5. 按内存的默认值

| 内存 | 马上用 | 推荐的本机升级 | 升级下载 | 升级后常驻内存 | 润色 |
|---|---|---|---:|---:|---|
| 8 GB | Apple | SenseVoice Small + Gemma 3 1B（沿用现有规则） | 0.96 GB | 约 2.2 GB | **推荐云端**：SenseVoice 中文只比 Apple 好 1.3 个点、英文更差；Gemma 3 1B 有 17 % 回退 |
| 16 GB | Apple | Qwen3-ASR 0.6B + Gemma 4 E2B | 4.4 GB | 4.4 GB（闲 10 分钟释放） | 本机或云端 |
| 24 GB | Apple | 同 16 GB | 4.4 GB | 4.4 GB | 本机或云端 |
| 32 GB 以上 | Apple | Qwen3-ASR 1.7B + Gemma 4 E2B | 5.9 GB | 5.4 GB | 本机或云端 |
| macOS 13–15（任何内存） | 没有 Apple 新引擎：设置助手第一行就是云端 key（百炼的 key 同时做识别和润色），也可以下载本机模型 | 同上 | | | 云端 |

- 档位就是 `transcribe.py tier_for` 现有的 light / standard / pro，只改了「没有本机模型时用什么」。
- Apple 引擎的那 0.45 GB 在系统进程里、用完系统自己收，8 GB 的 Mac 上比任何本机模型都轻。

## 6. Windows / Linux 以后怎么对应

| | macOS | Windows | Linux |
|---|---|---|---|
| 马上用（零下载） | Apple SpeechTranscriber | 云端 key（百炼 / OpenAI / Groq）；系统自带的 Windows 语音识别中文质量差、部分走微软云，未测 | 云端 key |
| 最小的本机模型 | SenseVoice 228 MB | SenseVoice（sherpa-onnx，CPU，已支持） | 同左 |
| 推荐本机模型 | Qwen3-ASR（MLX） | 有 NVIDIA：Whisper turbo（CUDA）；没有：SenseVoice（Qwen 0.6B 在 CPU 上 0.64 s，听写太慢） | 同左 |
| 润色 | 云端 / 本机 MLX | 云端（本机润色要另做，llama.cpp 一类） | 同左 |
| key 放哪 | 登录钥匙串 | Windows 凭据管理器 | Secret Service（libsecret） |

同一套选择：先零下载（系统引擎或云端 key），再小模型，再推荐模型；一个 key 四处用。区别只在「系统引擎」
这一格 macOS 有、另外两个没有，所以 Windows / Linux 的设置助手应该把「加一个 key」和「SenseVoice 228 MB」
并排放在第一屏。

**uv 在 Windows / Ubuntu（以后做，这次不做）：** 和 macOS 一样，先找能用的 uv（`uv --version` 能跑），找到就不装：
- Windows：PATH、`%USERPROFILE%\.local\bin`、`%LOCALAPPDATA%\uv`、winget / scoop 装的位置、Blurt 自己的
  `%LOCALAPPDATA%\Blurt\bin`；都没有时静默运行官方的 `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`，
  设 `UV_INSTALL_DIR` 到 Blurt 自己的 bin、`UV_NO_MODIFY_PATH=1`（不改用户的 PATH）。
- Ubuntu：PATH、`~/.local/bin`、`~/.cargo/bin`、snap 装的 `/snap/bin/uv`、`~/.blurt/bin`；都没有时同 macOS 的
  `curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=… UV_NO_MODIFY_PATH=1 sh`（没有 curl 时用 wget）。
- 两边都只在后台装，不弹窗；失败了下次启动再试，设置助手里留一个「安装 uv」按钮。

## 7. 拍板记录（创始人，2026-10-29）

1. **默认识别换成 Apple SpeechTranscriber，本机模型变成升级项**：做。
2. **国内默认推荐阿里的 key**：后来改定为「语音识别优先推荐阿里，润色继续优先推荐 DeepSeek」，并且每个云端任务都能自己选模型（§8）。§2.5 测过一个百炼 key 也能管润色、翻译、截图取字，质量和 DeepSeek 一样，所以只用百炼也行。
3. **uv 静默安装，已有就不装**：做（§8）。Windows / Ubuntu 只写进 §6，这次不做。
4. **macOS 13–15**：问的是「是不是很老、能不能不支持、只给云端行不行」。数据：
   - Homebrew 30 天统计（2026-09-29 到 10-29，2,508 万次安装，开发者多，和 Blurt 的用户最像）里的 Mac：
     macOS 26 46.0 %、macOS 27 29.1 %、**macOS 15 19.1 %、14 2.4 %、13 1.6 %**，13–15 合计约 **23 %**，主要是 Sequoia。
   - StatCounter 分不出 macOS 11 以后的版本（Apple 的浏览器把它们都报成 10.15），没法用。
   - Blurt 自己：没有遥测；反馈服务现在没有报告；GitHub 上 5 个 issue 都没提到 13–15；下载量还很小
     （v1.0.2–1.0.4 每版十几次）。
   - 结论：每 4–5 台 Mac 就有一台在 13–15，不该不支持。**做法：13–15 上云端优先**：设置助手第一行是 AI 服务的
     Key，填了百炼的 key 就能直接听写（识别和润色都在云端，不用下载）；本机模型照旧能下载。这次已经做了
     （改动小，§8）。没测老的 `SFSpeechRecognizer`：它要多一个权限框，而云端的质量已经更好。

## 8. 已实现（2026-10-29，未提交）

| 部分 | 做法 | 文件 |
|---|---|---|
| Apple 识别引擎 | `SpeechAnalyzer` + `SpeechTranscriber`（`.transcription`），一个音频文件 → 带时间的分句；系统语言包不在时向系统要（磁盘上已有的约 50 ms 就能用，真要下载时听写最多等 4 秒，录屏等到下完）；去掉全角标点两边的空格 | `Capture/AppleSpeech.swift` |
| 选型 | 注册表新条目 `apple-speech`（`builtin`，0 MB，zh / en / yue / ja / ko / fr / de / es / it / pt）。`select()` 在什么都没装时选它（之前是会去下载的 SenseVoice）；`dictation-models` 没有本机模型时 selected = `apple-speech`、ready、不需要 VAD；推荐下载照旧（升级项） | `scripts/transcribe.py`、`scripts/asr_models.json` |
| 听写 | `Dictation.transcribe` / `transcribeInterim` 选中 `apple-speech` 时在 app 进程里识别，不起 Python 语音服务；`dictation-models` 读不出来（还没装 uv）时，系统语言包就绪就直接用它 | `Capture/Dictation/Dictation.swift` |
| 语音笔记 | 同上，在进程里识别；Python 那条路失败时也退回它 | `Capture/VoiceInput.swift` |
| 录屏转写 | `transcribe.py` 的 `apple` 后端调用 app 自己的可执行文件 `blurt-recorder --speech WAV`（整段送进去，不用 VAD，所以连 0.6 MB 的 VAD 也不用下）；app 启动的脚本都带 `BLURT_APP_BIN` | `main.swift`、`AppleSpeech.runCLI`、`BlurtCore/Script.swift` |
| 云端润色无本机模型也能跑 | 只开了云端润色、没有本机润色模型时也起润色服务（polish.py 从不自己下载模型） | `Dictation.warmPolish` |
| 设置助手 | 有 Apple 引擎时：「听写现在就能用」、AI 服务的 Key（添加… 打开云端润色那张表）、「本机模型（可选）」一行自带下载按钮；主按钮是「下一步」；试一试只会被权限或系统语言包挡住 | `Onboarding/Onboarding.swift`、`ModelSetup.swift` |
| 阿里云百炼作为润色服务 | 云端润色的服务里有「阿里云百炼」（可选；默认仍是 DeepSeek）：润色和翻译用 DeepSeek V4.1 Flash，截图取字自动换成 qwen3.6-flash（`vision_model`），同一个 key 也给云端语音识别（`DASHSCOPE_API_KEY`）；百炼的请求都关掉思考；在表里填了新 key 就默认打开 | `polish_cloud.py`（PRESETS、`enable_thinking`）、`screen_text.py`（`read_cloud` 用 `vision_model`）、`DictationCloud.swift`、`DictationCloudSheet.swift`、`CloudSpeechSheet.swift` |
| uv 静默安装 | 启动时和设置助手打开时：PATH、`~/.local/bin`、Homebrew、`~/.blurt/bin` 里有能跑（`uv --version`）的 uv 就用，没有才在后台用官方安装器装到 `~/.blurt/bin`（不改 shell 配置）；装好后重新读听写和润色模型；测试版不装 | `App/UVSetup.swift`、`AppDelegate.swift`、`Onboarding.swift` |
| macOS 13–15：云端优先 | 没有 Apple 引擎时，设置助手第一行是「用云端听写：AI 服务的 Key」；`select()` 在 Apple 之后、下载之前选有 key 的云端服务；这时主按钮是「下一步」，本机模型单独一个下载按钮 | `transcribe.py`、`Onboarding.swift` |

| 云端识别的播放速度 | `asr.cloud.speed`，所有云端服务（百炼、Groq、OpenAI 兼容）通用：1.5 倍速默认（推荐），1 倍、2 倍可选，每档一行实测代价；送出前本机用 ffmpeg `atempo` 变速，返回的时间换算回原时间轴（创始人 2026-10-29 定） | `transcribe.py`（`cloud_speed`、`speed_up`）、`CloudSpeechSheet.swift`、`Speech.strings` |
| 听写用云端识别 | 有 key 的云端服务出现在听写的模型列表里（「语音识别」一栏的弹出菜单）；选了它：词表作为上下文送过去，说话时的实时字用 Apple 的（免费、本机），只把切好的片段送云端，不「重听」（每多送一遍都要钱）；片段不用 VAD | `transcribe.py`（`DICTATION_CLOUD`、`selected_cloud`、云端 `set_vocab`）、`Dictation.swift`、`VoiceInput.swift`、`AppleSpeech.forLiveText` |

| 推荐：识别阿里、润色 DeepSeek | 创始人 2026-10-29 改定：语音识别优先推荐阿里云百炼，润色继续优先推荐 DeepSeek。云端润色的默认服务改回 DeepSeek（标「推荐」），百炼保留为可选；设置 → 模型 → 高级里百炼的云端识别排第一、标「推荐」；macOS 13–15 的设置助手第一行是百炼的语音识别 Key（云端识别那张表），第二行是润色的 Key | `DictationCloud.swift`、`SpeechPane.swift`、`Onboarding.swift` |
| 每个云端任务自己选模型 | 润色、翻译、截图取字、语音识别各有一个模型菜单：默认值（标「默认」）、这家服务现在的几个模型、「自定义…」（任意模型 ID）；选中的模型下面一行写实测结果，或「没有实测过」。存储不变：`Setup.model`（空 = 默认），新增 `translate_model` / `vision_model`（空 = 翻译跟润色一样、截图取字用这家的看图模型），百炼识别的模型存在 `asr.cloud.qwen3-asr-flash.model`，经 `DASHSCOPE_ASR_MODEL` 给脚本 | `Settings/CloudModels.swift`（新）、`DictationCloudSheet.swift`、`CloudSpeechSheet.swift`、`polish_cloud.py`、`polish.py`、`transcribe.py` |

各服务的模型清单（2026-10-29 从各家 `/models` 读到）和实测情况：

| 任务 | DeepSeek | 阿里云百炼 | 其他 |
|---|---|---|---|
| 润色 | **deepseek-flash**（默认，实测 9.4 %）、deepseek-v4-pro（未测） | **deepseek-v4.1-flash**（默认，9.6 %）、qwen3.8-flash（10.0 %）、qwen3.6-flash（9.7 %，词认得少）、qwen-flash / qwen-plus（实测会改写，标「不推荐」） | OpenAI / Anthropic 兼容：自己填 |
| 翻译 | 默认跟润色一样；deepseek-flash（8.4 分）、deepseek-v4-pro（未测） | 默认跟润色一样；deepseek-v4.1-flash（8.4）、qwen3.8-flash（8.5）、qwen3.6-flash（7.8） | 自己填 |
| 截图取字 | **deepseek-flash**（默认，0.16 %） | **qwen3.6-flash**（默认，0.16 %）、qwen3.5-flash（0.16 %）、qwen3-vl-plus（0.20 %）、qwen3.5-ocr（1.3 %）、qwen-vl-ocr（4.6 %，有空结果） | 默认跟润色一样，或自己填 |
| 语音识别 | — | **qwen3-asr-flash**（默认，6.8 %，1.5 倍速 8.0 %）；百炼其他识别模型（qwen-audio-3.0-asr-flash、fun-asr-flash）只支持百炼自己的接口，Blurt 用的 OpenAI 兼容接口调不通，所以不列出，要用可以「自定义…」填 qwen3-asr-flash 的快照版本 | OpenAI：whisper-1（默认，有时间戳）、gpt-4o-mini-transcribe、gpt-4o-transcribe；Groq：whisper-large-v3-turbo（默认）、whisper-large-v3；都未测 |

另外修了一处：百炼识别请求里的上下文缺 `"type": "text"`（qwen3-asr-flash 不挑，别的模型会拒绝）。

在隔离的测试 app 里（全新 BLURT_HOME、空的模型缓存）验证过：
- 模拟 macOS 13–15（`BLURT_NO_APPLE_SPEECH`）+ 一个百炼 key：启动就 `selected = qwen3-asr-flash, ready`；一条听写识别出「tmux」，再由百炼上的 DeepSeek V4.1 Flash 润色，松手后 10 ms 粘贴；设置助手截图 `screens/onb-models-oldmac-zh.png`，布局检查没问题。
- 百炼一个 key 走真实代码：润色检查 0.8 s（deepseek-v4.1-flash）、截图取字 1.1 s（自动用 qwen3.6-flash）、翻译 0.8 s。
- 听写选百炼（1.5 倍速，默认）：片段 845 ms 识别完（说话时就在做），松手后 14 ms 粘贴；词表里的 tmux 认对了；实时字 5 次都来自 Apple；没有重听。
- 启动即 `selected = apple-speech, ready`；系统语言包 37 ms 就绪。
- 一条真实听写（Lab 里那条 6 秒的「请看一下过去 48 小时……」）：松手到粘贴 171 ms，文字和参考一致，没起语音服务。
- 打开 DeepSeek 云端润色、没有本机模型：Apple 听成「teamax」，润色后打出「tmux」，松手到粘贴 844 ms。
- `transcribe.py run` 转写一段 67 秒的录音：1.4 秒，带时间戳，没下载任何东西。
- 设置助手第 3、4 步中英文的布局检查（`layoutcheck`）都没有问题；截图在 `promo/cases/first-minute-asr/screens/`。

还没做 / 没验证：
- 云端识别速度那一行的界面没有截图检查（表单里多一行弹出菜单和一行说明）。
- 「测试连接」走 `polish_cloud.py`，还没装 uv 时会失败。
- 语音笔记只验证了代码路径，没在测试 app 里录一条。
- 设置 → 模型 的库表里 `apple-speech` 的大小列显示 0 MB，没单独处理。

## 9. v1.0.6：默认 0.6B，语音检测文件随 App 带上

- **本机识别默认改成 Qwen3-ASR 0.6B**（pro 档的 Mac 也是；原来 32 GB 以上推荐 1.7B）。依据 §2.1：Lab 金标 0.6B 更好
  （4.6 % 对 6.4 %），保留的听写一栏 1.7B 占便宜（参考答案本身是它出的），英文 1.7B 稍好（2.7 % 对 3.2 %），术语
  28 对 25；而 1.7B 下载是 2.5 倍、内存多 1 GB。已经装了 1.7B 的 Mac 继续用它，不会被要求下载 0.6B
  （`transcribe.py` `preference()` / `dictation_models()`）。
- **模型库的「准确率」一列去掉了**：那列来自 7 句 `say` 合成语音（`asr_models.json` 的 `error_ref`），0.6B 中文 0 %、
  1.7B 0.7 %，看起来 0.6B 处处更好，和真实语音不符。改成每个模型一句「适合做什么」（推荐 / 准，认得你加的词 /
  英文稍好，体积 2.5 倍 / 最小最快，不认你加的词 / 系统自带，不用下载…），推荐的、在用的、已装的放上面，其余折进
  「更多模型」。「用于」一列改成「说明」，在用时写「在用：听写、语音备注」，不再是一排图标。
- **Silero VAD（0.6 MB）随 skill 一起装**（`skills/blurt/models/silero_vad.onnx`，和原来下载的是同一个文件，
  sha256 9e2449e1…）。新装的 Mac 上，本机模型唯一缺的常常就是它，刘海和设置助手因此说「还没有语音模型 · 1 MB」，
  设置页却显示 0 MB。现在 `transcribe.py` 在任何地方找它之前先把带的这份放进 `~/.blurt/models`。ONNX 文件与系统、
  芯片无关。
