# Dictation styles: what users say about Typeless & co., and a plan for blurt

Research date: 2026-10-24. Scope: Typeless, Wispr Flow, Superwhisper, VoiceInk, Spokenly, Aqua Voice, Willow, MacWhisper,
闪电说, 豆包输入法, 微信输入法 and 讯飞. Sources: App Store reviews (pulled through Apple's RSS feed), r/macapps threads
(through the Arctic Shift archive, since reddit.com blocks crawlers), Product Hunt, V2EX, 少数派, 爱范儿, 极客公园, vendor
docs and changelogs. Vendor and competitor blogs are marked as such. User statements are paraphrased, with links.

## 中文摘要

- **最集中的抱怨就是"改太多"。** 用户说 Typeless 会改写原意、把话概括掉，还爱把内容硬套成结构，什么都排成列表；
  聊天里则把语气词这类缓冲删掉，读起来像机器。不过也有人就喜欢它自动分段、自动排要点。Wispr Flow 吃过同样的
  亏：它自己承认 Auto Cleanup 改得太狠，后来改成四档（None / Light / Medium / High），再加一个"撤销 AI 修改"。
  这说明"整理不整理"每个人要的不一样，同一个人在不同场合要的也不一样，所以默认绝不能主动重排。
- 排在后面的抱怨依次是：内容丢失或中途断掉、价格和额度、人名术语和中英混说（还有语言、简繁被认错）、隐私
  （云端处理、麦克风常开）、延迟。Typeless 在一篇对比里实测约 3 秒，V2EX 上也有人说它延迟一言难尽。
- 竞品怎么做：Wispr 按 App 类别设 Style，只管语气和标点，而且只支持英文；Superwhisper、VoiceInk、Spokenly 用
  "模式"（每个模式一套 prompt，有快捷键，可按 App 自动切换；Spokenly 还能在开头说一个触发词）；Typeless 不给
  风格设置，靠按 App 自动调语气加"个性化"在后台学习，列表默认自动排，要 Markdown 就选中文字用语音下指令；
  闪电说靠按法区分"直接说"和"帮我说"，风格分原话、轻度整理、深度整理三档。
- **对 blurt 的建议：**
  1. 默认只做轻整理，永不重排。
  2. 说话途中单按一下 ⇧ 就切到"结构化"（Fn+⇧ 起手也行），岛上显示当前风格，点一下可切换。
  3. 结构化不额外调一次模型：用确定性规则把明确的序数词（第一/第二、首先/其次/最后、一是/二是……）排成列表。
     "以及""其他""然后"这类词绝不触发。耗时约 0 ms。
  4. 按 App 设默认风格：聊天类保留语气词，句末不加句号；终端和代码类不换行；笔记类只在岛上建议，不自动排。
  5. "重排上一条"快捷键，可在 原话 ↔ 轻整理 ↔ 结构化 之间来回切，随时还原。
  6. 从用户的切换和还原里学偏好，但只提建议，从不自己悄悄改。
  7. 不做单独的分类器。
  先做 1–4，它们全部不增加延迟；5 不占听写的关键路径。
- **已上线**（§3.6、§3.7）：第 1–4 步和第 6 步。第 5 步「口头触发词」（开头说「列个清单」）**放弃**：用户常对 AI agent
  口述指令，「帮我列个清单」「写成邮件」是内容本身，当成命令会悄悄改掉原意；⇧、Fn+⇧、点岛、重排上一条已经够用。

---

## 1. What users complain about, ranked

The ranking is by how often a theme came up across independent sources. Typeless's own reviews are weighted most.

| # | Theme | What people say | Sources |
|---|---|---|---|
| 1 | **Over-editing: paraphrase, changed meaning, unwanted structure** | Typeless iOS reviews (Aug–Oct 2026): it used to type what was said and now writes what it *thinks* was said; it paraphrases and summarises long speech instead of transcribing it; recent updates made it overly aggressive, rewriting whole sentences and "annoyingly trying to convert everything to bullet points and numbered lists"; it added a "Thank you for watching" sign-off and big gaps between paragraphs to an Instagram comment; a Russian review says it decided on its own what to do with a monologue. A Chinese user who tried 闪电说, Typeless, Speakly and 智谱 went back to 闪电说: the AI tools change what they say so much that A comes out as B, and they impose structure that flattens casual, emotional speech. 爱范儿: in work chat, Typeless's output feels robotic, with the softening particles stripped out. Wispr Flow has the same problem: an App Store review complains it rewrites instead of transcribing, and Wispr itself traced its accuracy complaints to an Auto Cleanup setting that was too aggressive. | [Typeless App Store](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews), [X @gkxspace](https://x.com/gkxspace/status/2022656413722394685), [爱范儿](https://www.ifanr.com/1654016), [Wispr changelog](https://wisprflow.ai/whats-new), [Digital Trends](https://www.digitaltrends.com/computing/wispr-flow-asked-its-haters-what-was-wrong-and-more-than-700-people-answered/), [Voibe log (competitor)](https://www.getvoibe.com/resources/is-wispr-flow-reliable/) |
| 1b | …but structure is also loved, depending on the user and the app | A 5★ Chinese review praises Typeless for splitting paragraphs and adding bullet points on its own. On Product Hunt, one reviewer wants more numbered lists in Figma annotations and less structure in chat. Another wants their tone kept, with only fillers removed. 极客公园 counts Typeless's headed, numbered output as its main strength. | [App Store](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews), [Product Hunt](https://www.producthunt.com/products/typeless-2/reviews), [极客公园](https://www.geekpark.net/news/358358) |
| 2 | **Lost or interrupted takes** | Typeless Pro users report recordings that stop mid-sentence, with the speech neither saved nor transcribed; a 知乎 user lost a long take when a call came in. Wispr's own known issues include missing first words and transcriptions that never appear. | [App Store](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews), [知乎 via 少数派 roundup](https://sspai.com/post/105064), [Wispr known issues](https://docs.wisprflow.ai/collections/5686269587-known_issues) |
| 3 | **Price and quotas** | Typeless cut its free tier from 8,000 to 2,000 words a week; many 1–3★ reviews are about that cut, the $30/month price and constant upgrade prompts (one interrupted a take). On V2EX it is called the best, but too expensive. | [App Store](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews), [V2EX 1211319](https://www.v2ex.com/t/1211319), [V2EX 1193531](https://www.v2ex.com/t/1193531) |
| 4 | **Accuracy: names, terms, code-switching, language and script** | Typeless: Spanish or English heard as Chinese, with no way to limit the languages; bilingual users want a blocklist; Traditional Chinese set, Simplified written; Cantonese written as Simplified; a learned replacement ("hot" → "long") kept coming back. Wispr: weak on Chinese, product names and mixed Chinese–English (极客公园). V2EX: proper nouns still go wrong even when added to the dictionary. A commenter in the Superwhisper thread wants to fix one word by voice ("dog, not fog"). | [App Store](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews), [极客公园](https://www.geekpark.net/news/358358), [V2EX 1211319](https://www.v2ex.com/t/1211319), [r/macapps 1vvdr43](https://www.reddit.com/r/macapps/comments/1vvdr43/) |
| 5 | **Privacy** | One researcher's analysis of Typeless 0.9.3 found audio sent to AWS, despite its "on-device" wording (reported secondhand). iOS users complain the mic indicator stays on. Wispr was caught sending screenshots of the active window for context and apologised. Several V2EX users want local-only processing. | [kocpc (secondhand)](https://en.kocpc.com.tw/?p=5421), [Voibe (competitor)](https://www.getvoibe.com/resources/typeless-review/), [Laxis](https://laxis.com/blog/wispr-flow/), [V2EX 1193531](https://www.v2ex.com/t/1193531) |
| 6 | **Latency** | One comparison measured Typeless at about 3.0 s from end of speech to text, against about 1.5 s for Wispr, and blames Typeless's heavier rewriting pass. A V2EX user calls Typeless's latency hard to put up with. On r/macapps, speed is what decides it: for a Slack reply the ~0.7 s gap is the whole interaction, and one user drops a tool if it doesn't feel instant. Power users keep a no-AI mode because prompts add delay. | [voicedash](https://voicedash.ai/wispr-flow-vs-typeless/), [V2EX 1211319](https://www.v2ex.com/t/1211319), [r/macapps 1t6uffd](https://www.reddit.com/r/macapps/comments/1t6uffd/), [r/macapps 1r1oldq](https://www.reddit.com/r/macapps/comments/1r1oldq/) |
| 7 | **Hotkeys and app friction** | Typeless took over the emoji key (Product Hunt), and its help page tells users to clear macOS's own Fn actions. In WeChat on iOS, speech gets typed twice. Wispr had to stop long dictations collapsing into "[Pasted N lines]" in Claude Code and Codex. Its Flow Bar covered send buttons. Reddit users want text to stream at the cursor so they don't lose track during long takes. | [Product Hunt](https://www.producthunt.com/products/typeless-2/reviews), [Typeless help](https://www.typeless.com/help/troubleshooting/system-setting-conflicts), [Wispr changelog](https://wisprflow.ai/whats-new), [r/macapps 1r1oldq](https://www.reddit.com/r/macapps/comments/1r1oldq/) |
| 8 | Censorship and refusals | Typeless refused to transcribe some political wording. A local polish model can refuse too; blurt's guard falls back to the raw text. | [App Store](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews) |

**Praise, most common first:**
1. Fillers and self-corrections handled (少数派, Product Hunt, V2EX).
2. Faster than typing; heavy daily use (Product Hunt: 21k words in 19 days; 300 times a day).
3. Mixed Chinese–English and rare words recognised (App Store 5★).
4. Context-aware formatting: the right names from the screen, a different style for Slack and for email (r/macapps on
   Voquill, Wispr Styles).
5. One key, no knobs: some r/macapps users would rather have fewer settings and no waiting.

The main lesson: most complaints are about **unpredictability**: reviews say it used to type what they said, that the last
couple of updates made it worse, and on V2EX 1199506 that one update was enough to stop liking it. Users want light editing to be dependable and
heavy editing to happen only when they ask for it.

## 2. How competitors handle styles and modes

| Product | Default | Styles / modes | Per-app | Switching at dictation time | Restructuring / lists |
|---|---|---|---|---|---|
| **Typeless** | Heavy "intent" rewrite | No style picker. "Personalization" learns your tone silently and can only be switched on or off ([0.9.0](https://www.typeless.com/help/release-notes/macos/personalized-smarter)) | Tone adapts to the app automatically ([home](https://www.typeless.com/)) | Fn = dictate, Fn+Left ⇧ = translate, Fn+Space = "Ask anything" on a selection ([ask](https://www.typeless.com/help/quickstart/ask-anything), [translate](https://www.typeless.com/help/release-notes/macos/translation-mode)) | Lists, steps and key points are organised automatically ([home](https://www.typeless.com/)); Markdown lists also on a spoken command such as "turn this into a bulleted list" (0.9.0) |
| **Wispr Flow** | Auto Cleanup with 4 levels (None / Light / Medium / High) since Apr 2026, after the over-editing complaints; "Undo AI edit" restores the raw text ([changelog](https://wisprflow.ai/whats-new)) | **Styles** per category: Personal / Work / Email / Other; tones Formal, Casual, very casual, Excited. They cover capitalisation, punctuation and email greetings only, and English only ([docs](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)) | Category picked from the app or the web URL; terminals and AI assistants fall under "Other" | iOS has a quick style switcher on the keyboard that resets after 15 min. Command Mode: select text, hold Fn+Ctrl, say "make this a bullet list" ([docs](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)) | Only through Command Mode or the cleanup levels |
| **Superwhisper** | Whatever mode is active | Modes: Voice to Text (no AI), Message / Mail / Note with a Casual–Formal slider, Super (context), Custom (your own prompt) ([docs](https://superwhisper.com/docs/modes)) | Auto-activation rules per app or site; an auto-activated mode can't be overridden and doesn't switch back | "Change mode" shortcut (⌥⇧K, hold and cycle) works **before or during** a take; a shortcut per mode; or click the mode name in the recording window ([llms-full](https://superwhisper.com/docs/llms-full.txt)) | Through the prompt |
| **VoiceInk** | The default Power Mode | Power Modes, each with its own prompt and context | Per app or URL | ⌥1…⌥0 switch Power Mode while the recorder shows; ⌘1…⌘0 pick prompts ([shortcuts](https://tryvoiceink.com/docs/shortcuts)) | Through the prompt |
| **Spokenly** | The main mode; empty AI instructions = raw text | Modes with their own instructions, model and output action ([docs](https://spokenly.app/docs/modes)) | App and website triggers | **Trigger word at the start** ("email hey John…" runs Email and drops the word); precedence: trigger word > shortcut > website > app > main mode | Through instructions |
| **Aqua Voice** | Formats automatically (paragraphs, lists) | Custom instructions; "Deep Context" reads the screen | From the screen | — | Automatic (vendor claim) |
| **闪电说** | 直接说 (clean up and insert) | Styles: 原话 (verbatim) / 轻度整理 (light) / 深度整理 (deep), plus a voice persona; 帮我说 drafts a reply from screen context and memory ([site](https://shandianshuo.cn/)) | — | **The press decides the mode**: tap = 直接说, hold = 帮我说 | Deep style only |
| **豆包输入法 (Mac)** | Live text while speaking, smart punctuation | 智能文字整理 is a one-tap tidy-up afterwards (mobile) | — | — | On request |

What we learn:
- The tools users like for speed (Wispr, VoiceInk with Parakeet, Superwhisper S1) keep a **zero-AI or light path**
  and treat rewriting as opt-in.
- Per-app defaults are standard (Wispr, Superwhisper, VoiceInk, Spokenly). Rules that can't be overridden for the
  current take are a known annoyance (Superwhisper).
- Switching *during* the take exists only in Superwhisper (hold-and-cycle) and Wispr iOS (keyboard chip). Nobody has
  a one-key toggle while talking.
- After-the-fact restructuring (Wispr Command Mode, Typeless Ask anything and Markdown commands) is how the leaders
  offer heavy formatting **without making it the default**.
- Silent personalisation (Typeless) is the opposite of what the complaints ask for.

## 3. Proposal for blurt

### 3.0 Today's constraints (from `dictation.md`)

- Key-up → paste ≈ 0.3 s because pieces (cut at pauses ≥ 0.5 s, 3–20 s long) are transcribed and polished **while
  the user talks**. At key-up only the last piece is left.
- The polish model (Gemma 4 E2B) runs about 108 ms per sentence when warm. The guard and repair keep every meaningful
  unit. The prompt forbids rewriting, summarising and tone changes.
- So **anything that needs the whole text through an LLM after key-up is the expensive kind**: it can't overlap with
  speech. An LLM restructuring pass over a 20–60 s take would be roughly +0.5–1.5 s (an estimate from the
  per-sentence numbers; output ≈ input length; to be measured). That is the Typeless-style cost.
- The trigger state machine currently cancels push-to-talk when another key or a click joins in. Anything below that
  uses ⇧ or a click during a take needs a deliberate exception.

### 3.1 Styles (small, fixed set; no prompt editor in v1)

| Style | What it does | How it's done | Added latency |
|---|---|---|---|
| **原话 Verbatim** | ASR text with punctuation only; no LLM | The polish step is skipped (raw text) | −0.1 s (no polish) |
| **轻整理 Light** (default everywhere) | Today's polish: fillers, stutters, self-corrections, punctuation and paragraphs. **Never lists, never tone changes** | Unchanged | 0 |
| **结构化 Structured** | Light, plus spoken ordinal enumerations become a list, with any intro line kept ("有三点：" + 1. 2. 3.) | **Deterministic renderer** after stitch and guard (§3.3) | ≈ 0 (< 5 ms) |
| (later) 邮件 Email / 正式 Formal | Greeting, paragraphs, sign-off; tone | LLM pass over the whole text, explicit only | +0.5–1.5 s, accepted because the user asked |

Category variants of Light. They are part of the per-app default, not separate styles:
- **Chat** (WeChat, QQ, Slack, Telegram, Messages, Discord, Feishu/Lark, DingTalk…): keep sentence-final particles
  (吧 呢 啊 哈 嘛 呀) and casual wording, which answers the "robotic" complaint; no final 。 on a single-sentence
  message; no blank lines.
  - Today the repair treats 呢 as a removable discourse word. For chat, sentence-final particles move to "must keep".
- **Code / terminal** (Terminal, iTerm2, Warp, VS Code, Cursor, Xcode, JetBrains, Claude Code in a terminal): no line
  breaks unless Structured was asked for. Multi-line pastes collapse in Claude Code (Wispr had to fix the same thing).
  Identifiers and custom words stay as spoken.
- **Mail**: paragraphs allowed; no greeting or sign-off added.
- **Notes / docs** (Notes, Obsidian, Notion, Bear, Pages, Word): Light, plus a *suggestion* when a take looks like a
  list (§3.4). No auto-structure by default.

A user can set any category, or a single app, to Verbatim / Light / Structured / **Auto-structure**. Auto-structure
applies the renderer only when the detector is confident (≥ 3 ordinal markers in order). It ships off.

### 3.2 Zero-friction switching, compared

| Option | Friction at dictation time | Latency | False triggers | Verdict |
|---|---|---|---|---|
| **A. ⇧ tapped during the take** toggles Structured for *this take*; Fn+⇧ as the start press = start in Structured | Lowest: one key, any time, even halfway through when the user notices they are listing | 0 | None: it is explicit | **Build first.** Trigger change: a lone ⇧ press and release while dictating is a style toggle, not a cancel. Typeless uses Fn+Left ⇧ for translation, so Typeless users get a familiar chord (Settings already warns when Typeless runs). |
| **B. The island shows the style chip** (`轻整理` / `结构化 ≡`); a click toggles it | Low; also teaches A | 0 | None | **Build with A.** Clicks on Blurt's own island must not count as "a click cancels push-to-talk". The chip label shows ⇧ as the hint. |
| **C. Per-app default style** | None | 0: the bundle ID is already read for the context | Wrong-style takes in mixed-use apps (Notes for prose and for lists) | **Build first, but every default stays Light** (chat / code / mail variants above). Users opt categories into Structured or Auto. |
| **D. Spoken trigger at the start** (「列个清单」「分点说」「清单：」, "make a list") | None, but must be learned | 0: a regex on piece 1's ASR text, which is ready while the user still talks | Real risk: 「帮我列个清单」 can be content addressed to a colleague | **Dropped** (§3.6, step 5): the user dictates instructions to AI agents, where these phrases are content. |
| **E. "Reformat last"** hotkey (proposed ⌥⇧L, configurable), plus the island chip ≡ after a paste when the take looked like a list but wasn't formatted | One key after the fact; the safety net that lets the default stay conservative | Light ↔ Structured: < 50 ms (stored texts plus the renderer). The Email LLM pass: 0.5–1.5 s, off the dictation path | None | **Second wave, high value.** The history already keeps `raw` and `polished`, and `DictationWatch` already tracks the pasted span with anchors for 60 s. Pressing again cycles Verbatim → Light → Structured → back. Replace only while the anchors still match (user edits never get overwritten); otherwise copy to the clipboard with a toast. |
| F. Separate mode hotkeys (Superwhisper or VoiceInk style) | Higher: more keys to remember | 0 | None | Not needed beyond A and E. |

### 3.3 The renderer (why Structured needs no extra model call)

Spoken lists almost always come with **ordinal markers** at clause starts, and the speaker usually pauses between
items. Blurt's segmenter already cuts there, so items line up with pieces. Every piece is already polished, so the
list can be built **deterministically on the stitched, guarded text**:
- **Markers, in sequence (≥ 2 when the user asked, ≥ 3 for Auto):**
  - Chinese: 第一/第二/…, 一是/二是, 一来/二来, 其一/其二, 首先 … 其次/再次 … 最后, 一、二、, spoken 一 二 三
    at clause starts;
  - English: first(ly)/second(ly)/third(ly)/finally, number one/two, one…two…three at clause starts.
- **Never markers on their own:** 以及, 其他, 另外, 还有, 然后, 接着, also, and then. These are what make Typeless
  over-fire, turning everything into a list. 然后 and 另外 count only *inside* a sequence that already has an ordinal
  start and end.
- **Output:**
  - the intro before the first marker stays as a line ending in 「：」 / ":";
  - each item becomes `1. …`, with the marker word removed; 首先/其次 can optionally stay ("keep markers" setting);
  - the text after the last item stays as a closing paragraph.
- **Syntax per category:**
  - chat and plain-text apps: `1. ` lines; WeChat and QQ take pasted newlines;
  - Markdown apps (Obsidian, Notion, Slack, Claude Code): `1. ` / `- `;
  - rich-text apps (Notes, Pages): plain lines first; an RTF or HTML list on the pasteboard later.
- **At the cursor:** when the text before the cursor doesn't end a sentence (`DictationFit` already reads it), start
  with a line break instead of fitting the list inline.
- **Safety:** the renderer only removes marker words and adds digits and line breaks. A unit test asserts every other
  unit survives, and the guard's `novel` check already exempts digits. Without a confident sequence it is a no-op:
  the text is returned unchanged.

An LLM pass is needed only for structure the speaker did *not* say (headings, grouping, bullet points from prose).
That is exactly what users call over-editing, so it goes under Reformat → Email/Formal, on request only.

### 3.4 Router: rules, not a classifier

At key-down the router knows the app (category → default style). By stitch time it knows the explicit signals (⇧,
the island click, a spoken trigger) and the content (the renderer's own detector: marker count, item lengths, total
length). Order: **explicit this take > spoken trigger > app or category default > global default (Light)**.
Spokenly uses the same order and it reads naturally. (Shipped without the spoken trigger: step 5 was dropped, §3.6.)

- **Rules cost ~0 ms**, are deterministic, can be unit-tested, and explain themselves ("Structured, because you pressed
  ⇧").
- **Letting the polish model classify in the same pass** (say, a leading `<list>` tag) costs a few tokens per piece
  (~5–15 ms each), sees one piece at a time when a list spans several, and adds an instruction to a 2B model whose
  fidelity got worse with instruction-shaped prompts (`dictation.md`: fall-backs rose from 12 % to 63 % on Gemma 3 4B).
  **Not recommended.**
- **A separate small classifier** (an embedding model or a fine-tuned tiny model) means another load, more memory and
  ~10–30 ms, and solves a problem the rules haven't been shown to have. **Defer.** Log the features (`style`,
  `style_source`, `markers`, `list_likely`, per-app counts) in `history.jsonl` so the rules can be checked against
  real takes before anyone trains anything.

### 3.5 Learning the preference

Signals blurt can already see:
- **⇧ toggles and island clicks per app.** In Notes, a user who presses ⇧ in 4 of 5 list-like takes wants
  Auto-structure there.
- **Reformat-last**, and which result was kept.
- **Reverts**: Reformat cycled back, or `DictationWatch` sees the list markers or line breaks removed or merged within
  60 s.
- **Edits** in the watch window that re-add particles or remove a final 。 in chat refine the chat variant.

Policy: **suggest, never switch silently.** After ≥ 3 consistent signals in an app (≥ 70 % one way), the island
offers 「在 备忘录 里自动排清单？」 Yes / No once, like the existing *Learned "pull request"* · Undo pattern. Silent
drift is the root of the Typeless complaints about quality getting worse with updates. Learned app defaults show and
can be reset in Settings → Dictation.

### 3.6 What to build first, and the latency it costs

| Order | Item | Why now | Latency on the dictation path |
|---|---|---|---|
| 1 | Style plumbing: `record.dictation.styles` (category → style), the app → category table, `style` / `style_source` in the history | Everything else hangs on it; it also gives the data for §3.4 | 0 — **shipped** |
| 2 | Chat and code variants of Light (keep particles, no final 。, no newlines in terminals) | Answers the "robotic" and "[Pasted N lines]" complaints with no new UI | 0 (prompt and repair rule changes; check the eval sets still pass) — **shipped** |
| 3 | The deterministic list renderer, plus ⇧ during the take, plus the island style chip | The user's main request: structure on demand, no extra model call | ≈ 0 (< 5 ms) — **shipped** |
| 4 | Reformat-last and undo (⌥⇧L, the island ≡ suggestion) | The safety net in both directions; makes the conservative default painless | 0 on the dictation; < 50 ms on press (Light ↔ Structured) — **shipped** |
| 5 | Spoken triggers (strict list) | Hands-free power users; needs real takes to tune false positives | **Dropped: conflicts with dictating instructions to AI.** The user often dictates to AI agents, and 「帮我列个清单」 / 「写成邮件」 / "make a list" are then real content; treating them as commands would silently change what was meant. ⇧, Fn+⇧, the island and reformat-last are enough. |
| 6 | Preference suggestions from the signals | Needs 1–4 in the field first | 0 — **shipped** |
| 7 | Email / Formal through an LLM pass, Reformat only; optionally a speculative pass on the text so far while talking, to cut the key-up cost to ~0.1–0.2 s | Heavy rewriting stays opt-in, so the speed advantage holds | +0.5–1.5 s only when asked |

The default path stays at **≈ 0.3 s key-up → paste**. Steps 1–6 add nothing to it. Typeless is about 3 s in the one
published comparison, and Wispr 0.5–1.8 s depending on who measured.

### 3.7 What shipped (steps 1–4 and 6)

The implementation is described in `dictation.md` §Styles; in short:

- **1, plumbing**: `record.dictation.styles` (per category, per app, learned), the app → category table, and the
  history's `style`, `style_source`, `style_router` (category, the app's own style, ⇧ / the island / Fn+⇧, toggles,
  markers, `list_likely`, rendered, the variant) and `reformats`. Settings → Dictation → Style: one picker per category,
  Light (default) everywhere unless the user picks something else; no prompt editor.
- **2, variants of light**: chat keeps sentence-final particles (polish's repair puts back the ones the model dropped;
  the prompt and its cached prefix are unchanged) and drops the closing 。 of a one-sentence message; code and terminals
  get one line. Mail and notes as light.
- **3, the list renderer, ⇧ and the island chip**: deterministic, < 1 ms (the history event's `style_ms` was 0 on
  every take measured); ⇧ alone during a take (push-to-talk included), Fn+⇧ at the start, a click on the island; the
  ear shows a list mark while Structured. The Fn filter keeps that lone ⇧ from the app in front (input methods
  switch Chinese / English on it).
- **4, reformat-last** (`⌥⇧L`, configurable; none of Blurt's keys, ⌥⌘D or the lab's ⌥⌘L clash) with Undo, and the
  island's *Make a List* after a list-like take typed as prose. Replaces only untouched text, else the clipboard.
- **5, spoken triggers: dropped** (conflicts with dictating instructions to AI; see §3.6).
- **6, suggestions**: ≥ 3 consistent signals in an app (≥ 70 %) → asked once; never switched silently; learned apps
  show in Settings with Reset.

Found on the way, not changed here: on `say` clips that dictate a list piece by piece, the polish model (Gemma 4 E2B)
repeats the polished text so far in front of the new piece, the guard's `copied` check rightly refuses it, and the take
falls back to the transcript, which at short pauses has no mark at the seams (「…跑完第二，…」). The renderer copes
with those seams; the polish behaviour itself is the same before and after this work (latency runs). The Dictation Lab's
`style=` re-runs and its `listed` check are where to follow it up. Likewise the `say` clip of
「把这个，不对，这两个拿到那一边去」: the model keeps 「这个」 (「把这个拿到那一边去」), the guard's `correction` check
refuses it and the transcript is typed with the 不对 in it — before and after this work alike; the styles don't touch
self-corrections (the chat variant only adds a particle back after them).

## 4. Other improvements the feedback points to

1. **Never lose a take.** This is the #2 complaint everywhere. Keep the take's audio until the paste is confirmed (not
   only with `keep_audio`). Add "Paste last dictation" and "Retry transcript" in the menu and on the Dictation page.
   If ASR or polish fails, show it on the island instead of failing silently.
2. **Say "it types what you said" out loud.** Fidelity is blurt's strongest answer to the top complaint. Every
   history row has Raw / Light / Structured with one-click copy, like Wispr's "Undo AI edit".
3. **Language and script control.** Restrict recognition to the user's languages (for example zh + en) so it can't
   drift into a third one. Add 简体 / 繁體 output (deterministic OpenCC conversion after polish, ≈ 0 ms). Cantonese
   later.
4. **Dictionary.** Make learned replacements easy to see and undo (Typeless's "hot → long" kept coming back). Support
   a spoken fix of the last take ("X 不是 Y" / "dog, not fog") through Reformat-last's span tracking. Optionally take
   names from the window title and the field context (Voquill-style; blurt already reads them).
5. **Stream the text into the island while talking.** Committed pieces already exist; show the last line so a long
   take doesn't lose its thread (a Reddit request). It changes nothing on the critical path.
6. **Privacy, with proof.** Fully on-device, works offline; reads only the text around the cursor and the window
   title through Accessibility; no screenshots; mic open only from the key-down. That contrasts with the Typeless AWS
   finding and the Wispr screenshots episode. Add a "Privacy" panel that lists exactly what is read and kept.
7. **Hallucination on silence or noise.** Drop known filler hallucinations ("Thank you for watching", 「谢谢观看」,
   「字幕由…」) from low-energy pieces before polish.
8. **Publish the speed numbers.** Show the history's `total_ms` median on the Dictation page; "0.3 s vs about 3 s" is
   the headline compared with Typeless.
9. **Hotkey hygiene.** The Fn filter and the 🌐 guidance already cover what Typeless's help page tells users to do.
   Document ⇧ as the style toggle and ⌥⇧L, and check them against Blurt's existing keys (⌥⇧V, ⌥⌘D) before shipping.
