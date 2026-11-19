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
| Items not in a project | 未归类 | Unsorted |
| Card tabs | 当前 / 历史 | Current / History |

Add to this table whenever a new concept reaches the UI.
