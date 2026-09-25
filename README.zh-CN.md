<p align="center"><img src="assets/logo.png" width="140" alt="blurt 吐槽鸡"></p>
<h1 align="center">blurt 🐔 吐槽鸡</h1>
<p align="center"><b>边用边吐槽，AI 帮你提单。</b><br><a href="README.md">English</a></p>

---

Vibe coding 完之后的细节打磨，最累的是提反馈：截图、画框、写「预期 / 实际」、复现步骤、找 owner……一小时提 10～20
条就算高效了。**吐槽鸡**反过来：你只管一边用、一边像跟旁边同事说话一样吐槽——A 模块 B 模块随便跳、说错了改口、
拿鼠标指着说「这里」。录完交给 coding agent（Claude Code / Codex …），它会自动转写、拆分成一条条问题、挑图画框、
剪片段、**顺手在代码里定位疑似位置**，给你核对后导出到飞书多维表格 / CSV / GitHub…

```
你：/blurt 或「开始吐槽」       🐔 检查环境 → 开始录屏
你：（边用边说 30 分钟）
你：好了
🐔：本地语音识别 → 拆分问题 → 选帧标注 → 定位代码
🐔：打开核对页（少的话直接在对话里列）→ 你改两下 → 导出
```

## 亮点

- **一段录音 → N 条问题**：跳跃、改口、回头补充，都交给模型处理。
- **跑在你的代码仓库里**：每条问题带「疑似代码位置」，下一步「帮我改掉」就行。
- **本地优先的语音识别**：默认 SenseVoice（sherpa-onnx，约 240MB，普通 CPU 也很快，中英混说效果好）；
  Apple Silicon / NVIDIA 可用 Whisper；也可用自己的 Groq / OpenAI / 百炼 Key。默认不上传任何数据。
- **语言无关**：说什么语言，问题就用什么语言写。
- **Agent 原生**：录屏、识别、抽帧等确定性工作交给脚本，判断交给模型，少约束、强泛化。

## 安装

需要：macOS 或 Windows，[`uv`](https://docs.astral.sh/uv/)，`ffmpeg`。

**Claude Code**
```
/plugin marketplace add AGIHunt/blurt
/plugin install blurt@blurt
```
**Codex / 其他 agent**：把 `skills/blurt` 复制到对应的 skills 目录（如 `~/.codex/skills/blurt`、
`~/.claude/skills/blurt`），或 `npx skills add AGIHunt/blurt`。

然后在项目里说 **「开始吐槽」** 或 **/blurt**。首次运行会根据你的电脑推荐并下载语音模型（下载前会问你），并检查录屏 /
麦克风权限（macOS 需在「隐私与安全性」里给运行 agent 的那个 App 打开「录屏」和「麦克风」）。

## 录屏：不打扰、保隐私

- **只录你框的那块**：拖拽框选、单击选中某个窗口、或全屏。标签栏、收藏夹、其他窗口都不会被录进去；会记住上次的区域。
- **3-2-1 倒计时**（点一下可跳过），然后是一个很小的悬浮条：计时 · 音量 · ⏸ 暂停 · ↺ 重录 · **完成**。
  快捷键 `⌥⇧P` 暂停/继续、`⌥⇧S` 完成（Windows 为 `Alt+Shift`）。悬浮条本身不会出现在视频里。
- **点「完成」就行**：agent 会自动收到通知开始整理，不用切回对话框。
- macOS 用原生 ScreenCaptureKit 录制（首次使用时本地编译），Windows 用 Tk + ffmpeg。

## 先录，回头再处理

安装独立录屏 App：`record.py install-app` →「应用程序」/「开始菜单」里的 **Blurt**。随时录、录几段都行，也可以把 App
给同事用；视频存在 `~/Movies/Blurt`。之后对 agent 说「处理我录的吐槽视频」，它会把收件箱一次处理完。

已经有 QuickTime、OBS、Loom 或手机录好的视频？直接说「把 ~/Desktop/feedback.mov 整理成问题」即可。

## 审核像刷短视频，不像填表

一次看一条：左边大图/片段，右边字段可直接改。`A` 保留、`X` 丢弃、`J/K` 下一条/上一条、`Z` 撤销、`M` 并入上一条、
`1/2/3` 严重程度、`空格` 播放片段、`O` 跳到录屏里那一刻；按 `G` 切换成列表视图。

## 飞书多维表格

优先使用官方 `lark-cli`（用户身份登录，无需建应用），也支持自建应用凭证（`feishu.py`）。会按语义匹配你表里已有的列，
比如「预期效果与实际效果」「截图或视频」「对应 owner」。

路线图：鼠标轨迹记录、屏幕画圈标注层、浏览器 console / 网络请求捕获 —— 见 [TODO.md](TODO.md)。

MIT 协议。
