**Blurt 1.0.1**

**Download:** [Blurt-1.0.1.dmg](https://github.com/AGIHunt/blurt/releases/download/v1.0.1/Blurt-1.0.1.dmg) (macOS 13 or later, signed and notarized). Already on 1.0.0: Check for Updates… in the menu.

- **The app is all you install.** The app now brings the skill's scripts with it, so the DMG works on its own. In 1.0.0 the app also needed the skill from `npx skills add`; without it, setup stopped at "the speech tools didn't install", and an older skill could clash with a newer app. To use Blurt from Claude Code, Codex and other agents, go to Settings → Agents → Connect…, which links them to the app's copy and keeps them updated with it.
- **Let your agent install it:** `curl -fsSL https://blurt.agihunt.info/install.sh | sh` downloads the latest release, checks that it's signed and notarized, puts it in Applications and opens it.
- **Dictation with no text field in focus** (the desktop, a page with nothing selected): the notch now keeps the text with Copy until you copy it, close it or start the next dictation. Before, it said "Pasted" and the text disappeared. A double tap doesn't press Return there.
- The 1.0.0 downloads were briefly replaced by an unsigned CI build. If macOS said it couldn't check Blurt for malicious software, download it again.

---

**口喷鸡 1.0.1**

**下载：** [Blurt-1.0.1.dmg](https://github.com/AGIHunt/blurt/releases/download/v1.0.1/Blurt-1.0.1.dmg)（macOS 13 及以上，已签名并通过 Apple 公证）。已经装了 1.0.0：在菜单里点「检查更新…」。

- **只装 App 就够了。** App 现在自带 skill 的脚本，下载 DMG 装好就能用。1.0.0 还需要另外用 `npx skills add` 装 skill，没装的话设置会停在「语音工具没装好」；skill 比 App 旧时也会出错。想在 Claude Code、Codex 等 Agent 里用口喷鸡，到「设置 → Agent」点「连接…」，它们会用 App 自带的这一份，跟着 App 一起更新。
- **让 Agent 帮你装：** `curl -fsSL https://blurt.agihunt.info/install.sh | sh` 会下载最新版，确认已签名并经过公证，放进「应用程序」并打开。
- **光标不在输入框时听写**（比如在桌面上，或者网页里没点中输入框）：刘海里会留着这段文字，带「复制」按钮，直到你复制、关闭或开始下一次听写。之前会显示「已粘贴」，然后文字就不见了。这时双击也不会按回车。
- 1.0.0 的下载文件曾被 CI 的未签名版本短暂覆盖。如果 macOS 提示无法检查口喷鸡是否含有恶意软件，请重新下载。
