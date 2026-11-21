# Writing Blurt's copy

Every word a user sees: the Mac app (`*.lproj/*.strings`), the desktop app (`web/apps/desktop/src/locales/*.json`), the phone apps
(`apps/android/**/strings.xml`, `apps/ios`), the README, the site and release notes. English and Chinese are equals. Read this before
writing or changing any of them, and give it to any agent that will.

## The standard

Write like macOS System Settings, not like an assistant explaining itself. Copy that reads as AI-written fails, however correct it is.

- **Labels** are nouns or short noun phrases: 中转地址, 公共连接服务, 云端润色（可选）. A switch's label names the thing, not what happens
  when it's on.
- **States** use the standard words: 已就绪, 使用中, 已连接, 未设置, 未经测试 (Ready, In Use, Connected, Not set, Not tested).
- **Descriptions** are one short sentence of common words: 系统自带，无需下载。 完成后自动启用。
- **Errors** say the problem, then the action: 无法直连。请在电脑上设置自建中转。
- **Privacy** is a plain fact: 录音不会上传。

**Terms:**

- **Use words people already use, one per concept.** No coined terms and no metaphors. A word that works in a chat or a design doc is not a UI
  term: 牵线 explained the go-between in conversation, but in the app it's 公共连接服务. A design doc's working name ("go-between") stays in the
  code and the docs.
- **No product name inside status or error text.** 未经测试, not 未经口喷鸡测试.
- **Never:** 这台 Mac (use 本机, or leave it out); counts phrased as 有 5 个 (write 已下载 5 个); fillers (好了, 换上, 认得, 都会, 再加, 随手,
  递给, 就出字); anthropomorphic lines about the system; 一键, 赋能, 丝滑, seamless, supercharge, unleash, magic.
- **Quality:** never state error counts or error rates. Say it as a level, or a positive word (识别更准), or not at all.
- **Global first:** examples lead with globally known apps (Slack, Notion, Claude). Chinese apps can be among them.

## Before you send it

1. Run `python3 tools/copy-check.py`. It prints every user-facing string your branch adds or changes, in each language, and fails on the
   banned words above.
2. Read every line it prints, in both languages. Cut each one: shorter, more common words, no explaining.
3. Where an older string already said it well, reuse it rather than writing a new one.

## Agreed terms

| Concept | 中文 | English |
|---|---|---|
| Blurt's public go-between (remote-go-between.md) | 公共连接服务 | Public connection service |
| The user's own relay | 自建中转 | Own relay |
| The relay address field | 中转地址 | Relay Address |
| Connection paths | 同一网络 · 直连 · Tailscale · 虚拟局域网 · 自建中转 · 公共连接服务 | Same network · Direct · Tailscale · Virtual network · Own relay · Public connection service |
| One computer driving another (remote-desktop-viewer.md) | 电脑 · 添加电脑 · 打开窗口 · 连接 · 移除 | Computers · Add Computer · Open Window · Connect · Remove |
| A computer's state in that list (sentence case: a state line, not a label) | 已连接 · 可连接 · 离线 · 需要自建中转 · 中转无响应 | Connected · Available · Offline · Needs its own relay · Relay not responding |
| That row's button and tooltip when it needs its own relay | 重试 · 从这个网络无法直接连到 X。请在 X 上打开口喷鸡设置 → 远程控制，填写中转地址。在同一网络下不需要中转。 | Try Again · X can't be reached directly from this network. On X, open Blurt Settings → Remote Control and set a relay address. On the same network, no relay is needed. |
| Add Computer's two ways in, and the digits step | 同一网络 · 其他网络 · 核对 X 上的数字 · 如果 X 显示相同的数字，请在那台电脑上点「允许」。 | On this network · On another network · Check the Digits on X · Click Allow on X if it shows these digits. |
| When the pairing code on screen gives way to a new one (the Mac renews it; the desktop app's expiring code says 还剩 1:40) | 1:40 后更换二维码 | New code in 1:40 |
| The viewer, when the public connection service finds no direct path | 无法直连。请在对方电脑上设置自建中转。 | Can't connect directly. Set up your own relay on the other computer. |
| The viewer's controls | 屏幕 · 按键发往远端 · 跟着远端指针换屏 · 在新窗口中打开 | Display · Keys to Remote · Follow the Pointer · Open in New Window |
| The release hint | 按 ⌃⌘ 交还键盘和鼠标 (Windows/Linux: Ctrl+Alt) | Press ⌃⌘ to release the keyboard and mouse |
| The feature, its main-window page with every paired device, and the Settings pane with its options (Home's row, the sidebar, the menu bar's row); on the Mac one key, `feature.phone` (2026-11-20, was 手机和电脑) | 远程控制 | Remote Control |
| That page's empty lists | 还没有配对的设备 · 还没有添加电脑 | No devices paired yet · No computers added yet |
| Settings → 远程控制's first row, the way to the page (nothing paired · paired) | 还没有配对的设备 · 添加设备… · 已配对 2 台设备 · 查看设备 | No devices paired yet · Add Device… · 2 devices paired · Show Devices |
| Settings → 远程控制's sections | 本机 · 其他网络 | On this Mac · Other networks |
| A new device asking the host for a yes | 允许 %@ 控制本机？ · %@ 显示相同的数字时才允许。 · 不允许 · 允许 | Allow %@ to control this Mac? · Allow only if %@ shows the same digits. · Don't Allow · Allow |
| Its two groups: what controls this computer · what this computer controls | 能控制本机的设备 · 本机可控制的电脑 | Devices That Can Control This Computer · Computers You Can Control |
| Pairing a new phone or computer on the host | 添加设备… · 拷贝链接 | Add Device… · Copy Link |
| The text form of the pairing code | 配对链接 | Pairing link |
| The viewer's ⋯ menu | ⌘ 当作 Ctrl · 共享剪贴板 | Use ⌘ as Ctrl · Share Clipboard |
| Picture quality (as on the phone) | 画质：自动 · 清晰 · 均衡 · 省流量 | Quality: Auto · Sharp · Balanced · Data Saver |
| Items not in a project | 未归类 | Unsorted |
| Card tabs | 当前 / 历史 | Current / History |
| A double tap of a key (Fn to send, ⇧, ⌘) | 双击 | double-tap |
| One dictation (the thing in History; "take" stays inside the Dictation Lab) | 听写 | dictation |

Add to this table whenever a new concept reaches the UI.
