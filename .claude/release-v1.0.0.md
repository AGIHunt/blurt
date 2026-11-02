**Blurt 1.0: the keyboard for the agent era.** A Mac menu-bar app that gets what you mean into your agents' input box, by text, voice, screenshot or screen recording. It runs on your Mac and is free and open source. Windows and Linux are coming.

**Download:** [Blurt-1.0.0.dmg](https://github.com/AGIHunt/blurt/releases/download/v1.0.0/Blurt-1.0.0.dmg) (macOS 13 or later, signed and notarized; dictation and the recommended speech models need Apple silicon). Open it and drag Blurt to Applications. Later versions install themselves from the menu.

- **Dictation (`Fn`):** tap to talk, tap again to stop, or double-tap to stop and send. It works in every app. Speech recognition and polish run on your Mac with open-source models. On our test Mac, text is in about 0.4 s after you stop a minute of talking. Chinese, English and more; `⇧` switches to lists.
- **Snaps and voice notes (`⌥⇧A`, `⌥⇧V`):** draw on the snap and add a note by voice or typing. The cards hang under the notch; drag them into Claude, ChatGPT, Slack, WeChat or Feishu/Lark, or into a terminal for Claude Code or Codex.
- **Recordings into items (`⌥⇧R`):** talk while you record. Your coding agent splits the recording into issues, ideas, notes and tasks, each with a frame and the spot marked. Items are ready about a minute after you finish.
- **Hand off:** send items to Claude Code or Codex inside Blurt (one git worktree per item if you like), or pack them into a `.zip` for a teammate.
- **Peep**, the new mascot, lives in the menu bar and the notch. It talks while you dictate and thinks while Blurt works.

For agents: `npx skills add AGIHunt/blurt`, then tell your agent "start blurt". Website: https://blurt.agihunt.info · Full list of changes: AGIHunt/blurt#10

---

**口喷鸡 1.0：Agent 时代的输入法。** 用最高效的方式与你的 Agent 们互动，支持文字、语音、截图、录屏。本地运行，免费开源。目前只有 Mac 版，Windows 和 Linux 版在做。

**下载：** [Blurt-1.0.0.dmg](https://github.com/AGIHunt/blurt/releases/download/v1.0.0/Blurt-1.0.0.dmg)（macOS 13 及以上，已签名并通过 Apple 公证；听写和推荐的语音模型需要 Apple 芯片）。打开后把 Blurt 拖进“应用程序”。之后的新版本在菜单里一键更新。

- **听写（`Fn`）：** 按一下开始说，再按一下停；双击停下并发送。所有 App 都能用。语音识别和润色用开源模型在你的 Mac 上完成。在我们的测试 Mac 上，说一分钟话，停下后约 0.4 秒出字。支持中文、英文等；按 `⇧` 直接得到清单。
- **截图和语音备注（`⌥⇧A`、`⌥⇧V`）：** 在截图上直接画，用语音或打字加备注。卡片挂在刘海下，拖进 Claude、ChatGPT、Slack、微信、飞书，或拖进终端交给 Claude Code、Codex。
- **录屏变条目（`⌥⇧R`）：** 边录边说。你的编程 Agent 把录屏整理成问题、想法、笔记和任务，每条带一帧画面和标出的位置。录完约一分钟就能看。
- **交给 Agent：** 在口喷鸡里把条目交给 Claude Code 或 Codex（可以每条一个 git worktree），也可以打包成 `.zip` 发给同事。
- **小鸡 Peep：** 新的吉祥物，住在菜单栏和刘海里。你听写时它说话，口喷鸡干活时它思考。
