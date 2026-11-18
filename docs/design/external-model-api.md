# 已下载模型供其他应用使用

这项功能服务两种人：希望把 Blurt 当作本地模型提供商的桌面用户，以及希望从手机、另一台电脑或脚本调用它的开发者。模型权重保留在下载它的电脑上。客户端只需要知道服务地址、API Key、模型 ID，以及该模型可以接收什么输入。

## 用户如何使用

1. 打开「设置 → 模型 → 外部模型 API」。选择仅本机，启动服务。在家中从手机或其他电脑使用时，选择受信任的局域网再启动。局域网模式使用 HTTP，地址和密钥仅应提供给可信设备。有多个网卡时可在 CLI 指定局域网地址。
2. 从实际已下载且适合本机的模型中选择一个。语音模型接收音频，文本模型接收消息，OCR 模型接收图片。缺少模型时，用户可以返回同一页的模型管理下载。只有权重、缺少推理依赖时，选中模型并点击「准备运行环境」，首次准备可能下载 Python 和运行库。此操作可在服务开启或关闭时执行。
3. 选中聊天模型后，在「API 格式」中选择目标应用使用的 OpenAI Chat Completions 或 Messages-compatible API。可以分别复制地址、密钥和模型 ID，也可以复制包含三个字段的 JSON 或对应 SDK 的 Python 示例。两种协议共用同一密钥和模型 ID。
4. 在目标应用中发起一次真实请求。关闭设置窗口后可继续调用，点击停止会中断推理并释放资源。重启服务后密钥可继续使用；丢失密钥时可停止服务并更换。

## 接口与客户端适配

| 场景 | 接口 | 接入约定 |
|---|---|---|
| 模型下拉列表 | GET /v1/models | OpenAI 返回带 capability 的模型列表。带 anthropic-version 的请求返回 Messages SDK 可读取的聊天模型列表 |
| 聊天或翻译 | POST /v1/chat/completions | 文本消息、温度、输出上限，支持一次性 JSON 或 stream=true 的 SSE |
| 聊天和客户端工具 | POST /v1/messages | Anthropic Messages 的文本块、工具调用与结果、多轮对话、JSON 和 SSE；支持 x-api-key 或 Bearer |
| 语音转文字 | POST /v1/audio/transcriptions | multipart 的 file、model、可选 language，response_format 为 json 或 text |
| 图片取字 | POST /v1/chat/completions | 选 OCR 模型，user 消息提供一张 PNG/JPEG 的 image_url，内容为 base64 data URL；返回提取的文字 |

### 在截图中的模型提供商表单接入

| 设置项 | Messages-compatible API | OpenAI Chat Completions |
|---|---|---|
| 接口地址 | Blurt 展示的主机和端口 | 同一主机和端口 |
| API 密钥 | 从 Blurt 复制 | 从 Blurt 复制 |
| 主模型或轻量模型 | `gemma4-e2b` | `gemma4-e2b` |
| SDK 的 Base URL | `http://主机:端口` | `http://主机:端口/v1` |

表单会追加完整接口路径。例如，Blurt 当前显示的局域网地址若为 `http://192.168.22.145:11435`，两个选项都可以直接填这个地址。服务也容忍客户端在复制的地址后再次追加一层 `/v1`。同一台电脑可用回环地址，其他设备需要选择「受信任的局域网」并使用电脑的可达地址。

### 工具调用

1. 客户端随请求声明函数名、描述和 JSON 参数结构。OpenAI 通过 `tools[].function` 声明，Messages 使用 `tools[].input_schema`。调用者可以让模型自动决定、要求调用、指定函数或禁用工具。
2. Gemma 使用本地模型的工具模板生成函数名与参数。OpenAI 返回 `tool_calls` 和 `finish_reason: tool_calls`，Messages 返回 `tool_use` 块和同名停止原因。流式客户端收到协议规定的工具事件，工具参数在模型生成完整调用并解析成功后发送。
3. 客户端验证参数、执行自己注册的函数，并在下一次请求保留上一轮助手消息。OpenAI 用 `role: tool` 和 `tool_call_id` 回填，Messages 用用户消息中的 `tool_result` 和 `tool_use_id` 回填。服务核对 ID 后让模型继续回答。多个调用需要逐一回填。
4. 工具依赖本机模型模板。缺少工具模板时返回 400，截断或生成无效工具调用时返回错误。工具注册、权限和执行归调用端管理。Messages 客户端请求自适应思考时，本地服务可直接作答；不提供带预算的强制思考、托管工具或严格 JSON Schema 解码。

语音转写和 OCR 继续使用表内的 OpenAI 接口。OCR 提供取字，Gemma 此处接受文本聊天与函数调用。Responses、Realtime、嵌入和厂商托管工具需要各自的接口。

相关协议见 [OpenAI Function Calling](https://platform.openai.com/docs/guides/function-calling)、[Claude Messages](https://platform.claude.com/docs/en/api/messages/create)、[Messages 流式事件](https://platform.claude.com/docs/en/build-with-claude/streaming) 和 [OpenAI Audio Transcriptions](https://platform.openai.com/docs/api-reference/audio/createTranscription)。

## 平台与运行策略

| 角色 | 平台 | 能力取决于 |
|---|---|---|
| 服务主机 | macOS，包括 Intel 和 Apple 芯片 | 本机已安装、完整且可用的模型与运行库。MLX 模型要求 Apple 芯片 |
| 服务主机 | Windows、Linux | 使用仓库支持该平台的本地后端，例如 CPU 语音识别；下载列表按平台过滤 |
| 调用方 | macOS、Windows、Linux、iOS、Android | 客户端能访问主机并允许自定义 HTTP 地址。手机端复用电脑算力；主机需要保持开机、网络可达 |

每台电脑的外部服务默认关闭。仅本机模式绑定 127.0.0.1。局域网模式绑定一个本地私网地址，不自动更改防火墙或开启公网转发。密钥由主机生成，普通状态查询不包含密钥。HTTP 接口只接收上传的内容，不接受客户端指定主机文件路径。上传的音频和图片在推理结束后清理。

外部请求一次只执行一个推理；并发时快速返回 429 和 Retry-After。重复请求同一模型复用外部工作进程，切换模型、空闲、出错或超时时回收。前台听写继续使用既有运行路径，外部进程与前台进程仍会竞争 CPU/GPU/内存，同一份权重可能被两个运行时同时加载。低内存主机应以应用内听写与外部负载并行实测评估体验。

## 验收方法

- 准备隔离的 Blurt 数据目录。用空目录确认零模型状态；用已安装权重和合成输入检查真实返回，分别记录平台、模型与设备。
- 启动、重复启动、端口冲突、停止、重启与换钥。检查状态不输出密钥，旧密钥在更换后失效；另一台设备应使用主机局域网地址。
- 检查未知模型、错误能力、错误密钥、超大上传和忙碌请求的响应；连接断开或推理超时后服务应可以处理下一次请求。
- 核对桌面设置的显示状态、复制值、空状态及错误。逐项记录桌面构建、SDK、真机局域网和移动应用的实测范围。

## 参数、资源与故障处理

默认端口为 11435。每台主机默认只接受本机连接；访问范围的切换需先停止服务再启动。密钥随停止和重启保留，普通状态和模型列表不会回显密钥。命令行可在端口冲突或需要指定网卡时使用：

```sh
uv run skills/blurt/scripts/model_api.py start --scope local --port 11436
uv run skills/blurt/scripts/model_api.py status
uv run skills/blurt/scripts/model_api.py stop
uv run skills/blurt/scripts/model_api.py rotate-key
```

- **复制示例。** 「复制 Python 示例」按所选能力生成可执行代码，其中已填入客户端构造参数和模型 ID。按所选格式安装 `openai` 或 `anthropic`。转写示例读取当前目录的 `audio.wav`，OCR 示例读取 `image.png`。复制结果包含可调用服务的密钥。
- **文字。** 请求 JSON 最大 7 MiB，每次最多 128 条标准化消息和 128 个工具定义。服务使用所选模型的聊天模板和分词器，把系统消息、历史、工具定义及生成前缀一起计数。可输出的 token 数受剩余上下文空间约束。提示已占满模型窗口时返回 HTTP 400，并给出实际输入 token 数和模型窗口大小。OpenAI 默认最多生成 512 个 token，Messages 由客户端传入 max_tokens。服务将每次生成限制在 2,048 个 token 内。OpenAI 温度接受 0–2，Messages 接受 0–1。OpenAI 流式客户端可用 `stream_options.include_usage` 获取用量。
- **音频。** 单文件最多 25 MiB，解码后最长 10 分钟。16 kHz、单声道、16-bit PCM WAV 可以直接转写。其他采样率和 MP3、M4A 等容器需要主机有可用的 FFmpeg。
- **图片。** 单张最多 5 MiB、400 万像素，以内联 PNG/JPEG 提交。OCR 按模型的取字任务处理，复制示例带有完整消息结构。
- **资源。** 外部工作进程使用较低的 CPU 调度优先级；同一进程最多驻留一个外部模型，最后一次推理结束后空闲 90 秒回收。单次推理的时间预算为 180 秒。切换模型、工作进程异常或超时后，下一次请求会重新加载。
- **错误。** 401 时重新复制密钥；404 时刷新模型列表；413 时减小文件；429 时按 Retry-After 重试；503 时检查权重，然后在外部模型 API 区域点「准备运行环境」并重试。等效命令是 `uv run skills/blurt/scripts/model_api.py prepare --model 模型ID`。外部请求只使用已准备的环境或本地缓存，不触发模型或运行库下载。
- **连接范围。** 局域网模式使用主机的私有 IPv4 地址，可用 `start --scope lan --host 192.168.1.20` 明确指定已分配给主机的网卡地址。手机和电脑须能互相访问；防火墙、Wi-Fi 客户端隔离、浏览器混合内容限制、仅允许 HTTPS 的客户端都可能阻止连接。互联网远程访问和 TLS 终止需要单独配置。

仓库提供按需运行的三平台协议测试 [Model API compatibility](../../.github/workflows/model-api.yml)，覆盖模拟推理、真实 HTTP 通信及本机子进程启停。各硬件模型的推理结果需用相应平台与权重另行验证。

## 双协议 Mac 试用版的验证记录（2026-11-18）

下表使用本次 arm64 应用包内的服务脚本、M4 本机已有的 Gemma 4 E2B 4-bit 权重和两个官方 Python SDK。服务使用隔离目录和临时回环端口。每次工具结果都由测试客户端执行本地查表产生，首轮提示中没有提供答案。

| 场景 | OpenAI SDK 3.54.0 | Anthropic SDK 2.10.0 |
|---|---|---|
| 普通聊天、流式聊天 | 两次均回答 Paris，收到结束原因及用量 | 两次均回答 Paris，收到完整事件序列及用量 |
| 自动选择工具（JSON） | 返回 lookup_number 和参数 blue，回填后回答 74291 | 返回同名 tool_use，回填后回答 74291 |
| 指定工具（SSE） | 客户端重组 tool_calls，回填后流式回答 74291 | 客户端重组 input_json_delta，回填后流式回答 74291 |
| 设置页对应的 Python 示例 | 原样运行成功 | 原样运行成功 |

另在隔离的本机服务上调用了截图客户端 DataAgent 设置页实际使用的连接测试。Messages 与 OpenAI 两条探针均返回 HTTP 200，OpenAI 的请求转换、上游调用和响应转换也通过。OpenAI 表单分别验证了根地址和从 Blurt 原样复制的带 /v1 地址。另将真实 Gemma 流式返回送入 DataAgent 使用的 OpenAI 转换器，并对 Messages 直连路径运行同一对话；两条路径均重组出 lookup_number(color=blue)，回填后模型回答 74291。这些检查直接调用客户端代码，没有改动已保存的提供商。DataAgent 的 OpenAI 代理默认不请求流式 token 用量；有计量需求的客户端可设置 stream_options.include_usage。Messages SDK 测试包含客户端日常使用的 adaptive、medium effort、分块 system 与客户端元数据。执行 `uv run --python 3.12 tests/check_gemma_model_api.py` 可复验上述场景；本机应已下载 gemma4-e2b 并准备好运行环境。要检查应用包内的代码，可加 `--controller /应用包路径/Contents/Resources/skill/scripts/model_api.py`。

针对长工具列表的回归可用 `uv run --python 3.12 tests/check_gemma_model_api.py --large-tools` 复验。修复版在 M4 上使用 97 个客户端函数和自动工具选择。OpenAI 发送 73,208 字符，实际首轮输入 15,962 token；Messages 发送 70,395 字符，首轮输入 15,970 token。两条路径均收到正确的函数及参数，回填后回答 74291。

长工具列表修复版通过 81 项 Python 定向测试和 114 项桌面前端测试。双协议初版通过 13 项 Mac 设置目录测试。Mac 应用包通过本机临时签名校验。面向另一个设备时，局域网访问仍取决于用户所选接口、防火墙及目标应用的网络策略。

## 初版外部服务的验证记录（2026-11-18）

| 层面 | 实际结果 |
|---|---|
| Apple 芯片 Mac 应用 | 构建了包含中英文设置和服务脚本的 arm64 应用包，并通过本机临时签名校验。设置目录 13 项测试通过。 |
| 外部客户端真实推理 | OpenAI Python SDK 3.54.0 从独立进程调用服务。Gemma 4 E2B 完成流式聊天，Qwen3-ASR 1.7B 与 Fun-ASR-Nano 均正确转写合成语音。PP-OCRv6 tiny 识别合成中英文图片。应用包生成的聊天、转写和 OCR 三种 Python 示例均已原样运行。 |
| 运行环境 | 显式准备后，启动命令退出，再启动独立推理进程仍能使用同一运行环境。更换空的 uv 缓存后已准备的聊天和转写仍成功。 |
| Linux 主机和网络 | 在 Linux ARM64、CPython 3.12 上验证服务生命周期、实际 HTTP、合成推理工作进程及超时恢复。两个容器通过隔离的私网完成 Bearer 鉴权和模型列表查询。 |
| 设置与回归 | 共享桌面前端构建成功，113 项桌面前端测试通过；Mac 上本功能的 HTTP、适配器和运行环境定向测试 15 项通过。 |
| 待真实设备验证 | Windows 原生壳及推理、Linux 原生桌面壳及真实模型、Intel Mac、PaddleOCR-VL 权重，以及 iOS/Android 第三方客户端。跨容器验证覆盖连接协议，实体 Wi-Fi、防火墙配置和各款 App 的明文 HTTP 策略需分别验证。 |

API 的低优先级和限流已实施。这里的推理结果采用合成输入，尚无跨机型并发听写的延迟或内存基准。
