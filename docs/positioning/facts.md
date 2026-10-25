# Blurt positioning fact sheet

[English](facts.md) · [中文](facts.zh-CN.md)

Source material for the website, the README, launch articles and promo videos. Every number here has a source next
to it. When a number is unknown it says "not measured" or "not published".

- **Compiled:** 2026-10-25, branch `feat/live-snap` (after `fa798046`, live interim dictation text).
- **Competitor facts checked on:** 2026-10-25. Prices and policies change, so check them again before you publish.
- **Translations:** each language is one file, `facts.<lang>.md`, with the same section numbers and the same table
  rows in the same order. Numbers and sources stay as they are. Only the prose is translated.

---

## 0. Title and line

| | English | 中文 |
|---|---|---|
| Title | The keyboard for the agent era. | Agent 时代的输入法 |
| Supporting line | The quickest way to work with your agents: text, voice, screenshots, screen recordings and more. Runs on your computer. Free and open source. | 用最高效的方式与你的 Agent 们互动，支持文字、语音、截图、录屏等。本地运行、免费开源。 |

## 1. Positioning

### One paragraph

Blurt is a menu-bar app for people who work with AI agents such as Claude Code, Codex, Cursor, Claude and ChatGPT.
It handles the part before the agent starts: getting what you mean into the agent's input box. Press `Fn` and talk,
and the words are typed at your cursor in any app. Snap part of the screen, say what's wrong, and drop the picture
with its note into the chat or terminal where your agent runs. Record your screen while you talk, and your agent turns
the recording into separate items with frames, steps and the code that is probably responsible. Speech is turned into
text on your computer. Blurt works next to the agents you already use. It has no agent of its own, and it doesn't
rebuild integrations your agent already has.

### Three capabilities

**1. Dictation.** Press `Fn`, talk, and what you said is typed where your cursor is, in any app.

- `Fn` tap to start and tap to stop, or hold `Fn` while you talk. Double-tap `Fn` to send (Return). Right Option or
  either Option can be the key instead. (`docs/guide.md` §7)
- Recognition and polish both run on the Mac: Qwen3-ASR (1.7B on Macs with 32 GB or more, 0.6B on 16–24 GB) and
  Gemma 4 E2B for polish, through MLX. (`docs/design/dictation.md` §Recognition model, §Defaults by hardware tier)
- The default style, Light, removes fillers and stutters and adds punctuation. It doesn't rewrite, summarize,
  translate or turn speech into a list. Press `⇧` while talking for Structured, a list when you listed things. `⌥⇧L`
  reformats the last dictation. (`docs/guide.md` §7)
- The words show under the notch while you talk, about a second behind you, so you can decide whether to send or fix
  before the text goes in. (`docs/design/dictation.md` §Live text)
- Works in chat apps, mail, editors and terminals. In terminals and code editors the text stays on one line. It never
  types into a password field. (`docs/guide.md` §7)

**2. Snaps and voice notes as cards.** A snap or a voice note hangs as a card under the notch until you use it, and
you drag or paste it into any app.

- `⌥⇧A` snap: drag an area, say or type what's wrong, and stop talking for about 2 s to save it. Drag on the picture to
  circle the spot. `⌥⇧V` voice note: talk for up to 10 minutes. (`docs/guide.md` §1)
- Drag a card into Claude, ChatGPT, Slack, Notion, Feishu/Lark or WeChat: the picture goes in as an attachment, then
  Blurt pastes the note into the same message box. Drop it into Terminal, iTerm2, Ghostty or Warp: Claude Code or Codex
  gets the paths of the picture and of a Markdown file with the note. (`docs/guide.md` §3)
- Click a card to copy it, then `⌘V`. `⌘`-click several cards to copy them as one. `⌥⇧H` brings the cards down for the
  keyboard. (`docs/guide.md` §3)
- Cards you dragged out stay findable for 7 days. A deleted card can be brought back with Undo for 5 seconds.
  (`docs/guide.md` §3)

**3. Screen recording into items, and hand-off to agents.** Record your screen while you talk, and get back a list of
items your agent can work on.

- `⌥⇧R` starts and stops a recording of an area, a window or the full screen. Hold `⌃` and drag to circle something;
  the ink fades after 3 s. (`README.md` §How it feels)
- Your coding agent splits the recording into items (bugs, ideas, notes, todos), picks a frame for each, marks the
  spot, and writes actual vs. expected, repro steps and suspected code. (`README.md`)
- You review each item with the keyboard (`A` keep, `X` discard, `J/K` next and previous), then export to
  Markdown/CSV, Feishu/Lark Bitable or GitHub Issues, or let the agent fix them. (`README.md`, `skills/blurt/reference/export-other.md`)
- **Hand Off to Agent** (`⌘↩`) starts Claude Code or Codex inside Blurt, in the project folder, optionally one git
  worktree per item. **Copy instruction** gives your own agent one line that points at a hand-off note with the
  items, what you said, steps, suspected code and screenshots. Agents report back through Blurt's MCP; "fixed" from an
  agent always means *to verify*. (`docs/guide.md` §5, `skills/blurt/reference/sessions.md`)
- Teammates without the code can record with the app and send the video; the developer's agent processes it with the
  code at hand. (`README.md` §Solo or team)

---

## 2. Comparison: Blurt, Typeless, Wispr Flow, Superwhisper, Aqua Voice

**Date of comparison: 2026-10-25.**

Read this first:
- Blurt's numbers come from its own tests on **one machine, an Apple M5 Max with 128 GB**, with speech generated by
  macOS `say` and fed in as the microphone. Synthetic speech is cleaner than a real microphone, so error rates are
  optimistic. Smaller Macs, real microphones and accents were **not measured**.
- Competitor numbers come from different people, machines and methods. They are not directly comparable with
  Blurt's or with each other. Several come from competing vendors; those are marked.

### 2.1 Dictation latency (end of speech → text at the cursor)

| Product | Number | Source |
|---|---|---|
| **Blurt** | 0.29 s after a 3 s sentence, 0.35–0.38 s after 10 s, 0.52–0.54 s after 30 s, 0.39 s after 60 s (median of 3 takes, released 0.1 s after the last word, warm models). About 0.01 s when you pause ≥ 0.5 s before releasing. | `docs/design/dictation.md` §Streaming, latency table |
| Blurt, long takes with live text on | 0.51–1.55 s key-up → paste on 42–54 s clips (median 0.64 s over 12 takes); a 3-minute mixed take: 0.58 s | `promo/cases/v0.9-polish/livetext/results/summary-r3.txt`; `promo/cases/v0.9-dogfood/dictation/timeline.md` D46 |
| Typeless | about 3.0 s | VoiceDash comparison, a competing vendor, citing "2026 controlled benchmarks": [voicedash.ai](https://voicedash.ai/wispr-flow-vs-typeless/) |
| Wispr Flow | about 1.5 s | same VoiceDash article |
| Superwhisper | not published; not found | — |
| Aqua Voice | "about 450ms" (vendor's own claim) | [Aqua blog, 2026-08-17](https://aquavoice.com/blog/wispr-flow-alternatives) |

### 2.2 Live text while you speak (Blurt)

| Clip | First words shown | Average lag behind speech | Source |
|---|---|---|---|
| Chinese, 53.6 s | 0.64 s (was 20.5 s before interim decoding) | 0.86 s | `docs/design/dictation.md` §Live text; `promo/cases/v0.9-polish/livetext/results/summary-r3.txt` |
| English, 42.0 s | 0.63 s | 0.99 s | same |
| Chinese–English mixed, 45.1 s | 0.62 s | 1.26 s | same |

Interim decoding doesn't change key-up → paste (median 639 ms on, 652 ms off). On Macs with less than 16 GB the
live grey text is off and words appear after each pause. Competitors' live-text lag: not measured.

### 2.3 Accuracy

| Product | Chinese | English | Chinese–English mixed | Source |
|---|---|---|---|---|
| **Blurt**, recognition model alone (Qwen3-ASR 1.7B, MLX bf16), 7 product-feedback sentences × 2 voices per language | CER 1.3 % | WER 1.9 % | not measured separately | `docs/design/asr-benchmark.md` |
| **Blurt**, dictation test set, Qwen3-ASR 1.7B 8-bit, 20 Chinese and mixed clips with product names | CER 2.7 % (1.7 % with the text so far as context); 90–97 % of names right | — | (included in the Chinese column) | `docs/design/dictation.md` §Qwen3-ASR 1.7B |
| **Blurt**, the same model on a harder set (6 voices, room noise added) | CER 26.7 %; 38 % of names right | — | — | same |
| **Blurt**, full dictation path on 16–24 GB Macs (Qwen3-ASR 0.6B + Gemma 4 E2B polish, custom words; a v0.8 measurement) | CER 10.8 % (Chinese and mixed together); 86 % of names right | WER 0 % (10 clips) | (included in the Chinese column) | `docs/design/dictation.md` §Recognition model |
| Typeless | not published | WER about 7.9 % (the same article also says about 20 %) | not published | VoiceDash, competing vendor |
| Wispr Flow | not published | WER about 3.9 % | not published | VoiceDash, competing vendor |
| Superwhisper | depends on the model you pick; not published | not published | not published | — |
| Aqua Voice | not published | OpenASR leaderboard average WER 6.24 (Avalon v1); 97 % on its own coding-terms set | not published | [Aqua blog, 2025-10-08](https://aquavoice.com/blog/avalon-openasr-leaderboard) (vendor) |

What polish keeps (Blurt, synthetic eval sets):
- Light keeps every word of a self-correction in 66 of 68 takes (97 %); Structured settles on the corrected version in
  56 of 68 (82 %). `docs/design/dictation.md` §Self-corrections
- Gemma 4 E2B: 2.4 % of outputs fall back to the raw transcript, 88 % of fillers removed, every phrase of the
  over-deletion set kept after the repair, about 0.11 s per sentence warm. `docs/design/dictation.md` §Over-deletion

### 2.4 Price, privacy, platforms, offline, customisation

| | **Blurt** | Typeless | Wispr Flow | Superwhisper | Aqua Voice |
|---|---|---|---|---|---|
| Price | Free, MIT licence, no word limit. Turning recordings into items uses your own coding agent; three real sessions of 7–20 min cost about $2–2.6 each at API prices (`README.md` FAQ). | Free with a weekly limit; Pro $12/month billed yearly, $30 monthly ([pricing](https://www.typeless.com/pricing)). App Store reviewers report the free limit went from 8,000 to 2,000 words a week. | Free 2,000 words/week on desktop; Pro $15/month, $12/month yearly ([pricing](https://wisprflow.ai/pricing)) | Free with local Whisper models; Pro $8.49/month ([superwhisper.com](https://superwhisper.com/)); $84.99/year and $249.99 lifetime per third-party guides ([Voibe](https://www.getvoibe.com/resources/superwhisper-pricing/), a competitor) | Free 1,000 words; Pro $12/month, $10/month yearly; Max $24/month ([pricing](https://aquavoice.com/pricing)) |
| Where speech is processed | On your computer. Optional: your own Groq, OpenAI or DashScope key for recordings. Item writing is done by the agent you choose, which sends the transcript text and a few frames to that agent's provider. | Cloud: "Transcription is performed on the cloud" ([data controls](https://typeless.com/data-controls), updated 2026-10-13) | Cloud: "Transcription always occurs on the cloud" ([data controls](https://wisprflow.ai/data-controls), updated 2026-08-18) | Local models or cloud models, your choice ([docs](https://superwhisper.com/docs/llms-full.txt)) | Cloud: "dictation runs in the cloud" ([Aqua blog](https://aquavoice.com/blog/wispr-flow-alternatives)) |
| Platforms | Dictation and cards: macOS. Recording → items: macOS, Windows, Linux (X11). | macOS, Windows, Linux, iOS, Android ([home](https://www.typeless.com/)) | Mac, Windows, iOS, Android | Mac, Windows, iOS, Android | Mac, Windows, iOS, Android |
| Offline | Dictation needs no network once the models are downloaded; not yet tested with the network switched off. | No (transcription is in the cloud) | No (transcription is in the cloud) | Yes, with local models ("works offline") | No (cloud) |
| Styles | Verbatim, Light, Structured, Auto; a style per kind of app (chat, code and terminals, mail, notes, other); `⇧` during a take; `⌥⇧L` afterwards | No style picker; tone adapts per app automatically ([home](https://www.typeless.com/)) | Styles per category, English only; cleanup levels None to High ([docs](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)) | Modes with your own prompts, switchable during a take ([docs](https://superwhisper.com/docs/modes)) | Custom instructions (Pro) |
| Custom words | Words list, learned from your corrections (with Undo), plus the text around the cursor; words are hints, never replacements | Personal dictionary | Dictionary | Vocabulary and replacements | Personal dictionary (Pro) |
| Snap and voice-note cards for agents | Yes | No | No | No | No |
| Screen recording → items with frames and code pointers | Yes | No | No | No | No |
| Hand-off to coding agents, status back through MCP | Yes (Claude Code, Codex; Kimi Code, OpenCode, Gemini CLI for processing) | No | No | No | Lists "MCP/CLI" on its free plan; not examined |

---

## 3. What users complain about, and what Blurt does

**How the counts were made.** We read the App Store reviews of Typeless for iOS (US store, 131 reviews, 57 at 3★ or
below) and Wispr Flow for iOS (US store, 250 reviews, 29 at 3★ or below), pulled on 2026-10-24 through Apple's RSS
feed, and counted the low ratings by theme. One review can count under several themes. These are phone apps, and
Blurt is a Mac app, so some themes don't carry over. The rest of the research (r/macapps, V2EX, Product Hunt,
少数派, 爱范儿, 极客公园, vendor docs) is in `docs/design/dictation-styles.md` §1.

| Complaint | How common (rough) | Blurt's answer | Status |
|---|---|---|---|
| **Rewrites what I said**: paraphrases, summarizes, turns speech into lists. "now it just writes what it thinks I said" (akmeds301, Typeless iOS, 2026-10-22) | Ranked first in `dictation-styles.md`; 4 of 57 low Typeless ratings; Wispr's own changelog added cleanup levels after the same complaint | Light is the default and never restructures or summarizes. If polish drops or adds content, the raw transcript is typed instead. Verbatim types exactly what the speech model heard. Structured happens only when you press `⇧`, and `⌥⇧L` switches the last dictation back. | Done |
| **Takes lost or cut off**. "It keeps stopping mid-sentence and missing what I said" (er ep er, Typeless iOS, 2026-07-12); "everything i said was just eaten" (nerdhappy, Wispr Flow iOS, 2026-10-11) | 5 of 57 low Typeless ratings; 5 of 29 low Wispr ratings | Live text shows what was heard while you talk. Every dictation is kept in Dictation History for 30 days, with Copy. The mic opens on the key-down, so the first words aren't cut off (measured: audio from 5–6 ms after the key with a mic that starts at once). Keeping the audio until the paste is confirmed is planned, not built. | Partial |
| **Price and word limits**. "2000 is way too low" (Yeahyea588, Typeless iOS, 2026-09-28) | About 11 of 57 low Typeless ratings; 3 of 29 for Wispr | Free and open source, no word limit, no account. Recordings use your own agent's tokens. | Done |
| **Names, languages and scripts**. "I spoke in Cantonese, but it showed the simplified Chinese" (plchan, Typeless iOS) | About 6 of 57 low Typeless ratings; also V2EX and 极客公园 on names and mixed Chinese–English | A Words list the speech model listens for; learning from your fixes (it learns a word, never a replacement); the text around the cursor. Simplified-Chinese users get simplified characters; Traditional users keep what the model wrote. Cantonese was not measured. A setting to limit dictation to your languages: not yet. | Partial |
| **Microphone on in the background, privacy**. "the microphone stays on even when not using the keyboard" (RichardS_23, Typeless iOS) | About 8 of 57 low Typeless ratings, mostly about the iOS keyboard; Wispr once sent screenshots for context (`dictation-styles.md` §1) | Speech is processed on the Mac. The mic opens when you press the key and closes when you stop. Blurt reads about 500 characters around the cursor for spelling and keeps it only for that dictation; password fields are never read. No screenshots for dictation. | Done |
| **Slow**. Typeless measured at about 3.0 s in one comparison | Common on r/macapps and V2EX (`dictation-styles.md` §1, theme 6) | About 0.3–0.5 s from releasing the key to the paste on the test Mac (§2.1). Not measured on 16 GB or 8 GB Macs. | Done on the test Mac; other Macs not measured |
| **Can't see the words before sending**. "It doesn't add the punctuation in real time" (Karen Fanboy, Wispr Flow iOS, 2026-10-17) | Raised by Blurt's own users and in our dogfood run | Live text under the notch: first words after about 0.6 s, average lag 0.9–1.3 s (§2.2). | Done (16 GB Macs and up) |
| **Hotkey clashes** (the emoji key, macOS's own Fn action) | Product Hunt; Typeless's help page tells users to clear macOS's Fn settings | Blurt keeps the Fn press for dictation, shows when macOS's "Press 🌐 key to" setting would react too and opens the right page, and says when Typeless or Wispr Flow is also listening to Fn. Right Option or either Option can be used instead. | Done |
| **Long dictations collapse into "[Pasted N lines]" in Claude Code** | Fixed by Wispr in its changelog | Terminals and code editors get the text on one line. | Done |
| **Refuses or censors some words** | 3 of 57 low Typeless ratings | Polish runs on your Mac. If the model refuses or answers instead of tidying, the guard types the raw transcript. Not measured on a dedicated test set. | Done by design; not measured |
| **A learned replacement keeps coming back** (Typeless "hot" → "long", `dictation-styles.md` §1) | A few reports | Learned words are hints, never replacements. Each one shows *Learned "…"* with Undo, and the Words tab lists and removes them. | Done |
| **Battery, auto-lock, iOS keyboard switching** | The largest group: about 20 of 57 low Typeless ratings, about 10 of 29 low Wispr ratings | Not applicable: Blurt has no phone app. | Not applicable |

---

## 4. Proof points and demo moments

Each moment comes with the number or file that backs it.

1. **The words keep up with you.** Dictate 45 s of mixed Chinese and English without pausing; the words appear under
   the notch from 0.6 s on. Before interim decoding they appeared after 20 s. (`summary-r3.txt`)
2. **Release, and it's there.** A 60 s dictation goes in 0.39 s after you let go of `Fn`; a 3-minute one in 0.58 s.
   (`dictation.md` §Streaming; dogfood D46)
3. **It types what you said.** Say 「周三，不对，周四」 in Light: both stay. Press `⇧`: only 周四. (dogfood D30)
4. **Insert into the middle of a sentence.** Cursor in 「我知道你就是▮的。」, say 「就是从老家回来的」, get
   「我知道你就是从老家回来的。」. (dogfood D23)
5. **A snap card dragged into Claude.** `⌥⇧A`, circle the broken button, say one sentence, drag the card into the
   Claude desktop app: the picture goes in, then the note in the same message box.
6. **The same card dropped into a terminal.** Claude Code gets the picture path and a Markdown note, and nothing runs
   in the shell.
7. **A recording turned into items.** A 5-minute, 12-item session was ready for review 51 s after Finish; a 14-minute
   recording was transcribed locally in 12 s and became 23 items for about $2.6 of agent tokens. (`README.md` FAQ)
8. **Items handed to an agent and back.** `⌘↩` on an item starts Codex in a worktree; when the agent calls
   `mark_fixed`, the item shows *To verify* within 0.5 s. (`promo/cases/v0.9-dogfood/work/timeline.md`)
9. **A teammate's recording, your agent.** A designer records with the app and sends the video on Slack; you tell your
   agent "process this video". The hand-off note holds local file paths, so for now the video is what you share.
10. **Pull the network cable.** Dictation keeps working (models are local). Check this on camera before you claim it:
    it hasn't been tested with the network off.

Before filming, check these issues found in the October dogfood runs (`promo/cases/v0.9-dogfood/*/timeline.md`;
some may be fixed since): Codex in a worktree asked for approval before committing; in English mid-sentence inserts
the capital letter was kept ("I think The new layout is fine").

---

## 5. What Blurt doesn't do, and why

- **No connectors.** Your agent already has MCP servers and CLIs for Linear, Jira, Notion, Slack and the rest. Blurt
  gets your words, pictures and recordings into the agent and leaves delivery to it. The exports it ships are files
  (Markdown, CSV), Feishu/Lark Bitable and GitHub Issues through `gh`.
- **No agent of its own.** Recordings are processed by the first coding agent you have installed and signed in:
  Claude Code, then Codex, Kimi Code, OpenCode, Gemini CLI. Your agent gets better on its own schedule, and Blurt
  works with the next one too.
- **No cloud service.** There is no Blurt server and no account. Speech is transcribed on your computer. The only
  network traffic is the model downloads, a cloud speech key if you add one, and whatever your own agent sends to its
  provider.
- **No rewriting in dictation.** It doesn't summarize, translate, answer or change your tone. A tidier version is one
  key away (`⇧`, `⌥⇧L`).
- **No spoken commands.** 「帮我列个清单」 or "make a list" is typed as words, because you are often dictating an
  instruction for an agent.
- **No silent learning.** When Blurt notices you switch styles the same way in one app, it asks once. It changes
  nothing by itself.

---

## 6. FAQ seeds

**Does my voice leave my computer?** Not for dictation, snaps or voice notes: speech recognition and polish run on
your Mac. A dictation's audio is deleted right after transcription unless you choose to keep it, and the dictation
history is kept for 30 days. Snaps, voice notes and recordings stay in your folders until you delete them. When your agent turns a recording into items, the transcript text and a few frames go to that agent's
provider, as anything else you give that agent does.

**What does it cost?** Blurt is free and MIT-licensed, with no word limit. Turning a recording into items uses your
own agent: about $2–2.6 at API prices for each of three real 7–20 minute sessions (`README.md` FAQ).

**Which models, and how big?** (`skills/blurt/scripts/asr_models.json`, `polish_models.json`)

| Use | Model | Download | Memory (peak) |
|---|---|---|---|
| Dictation speech, Macs with 32 GB or more | Qwen3-ASR 1.7B, 8-bit, MLX | 2.5 GB | 3.1 GB |
| Dictation speech, 16–24 GB | Qwen3-ASR 0.6B, 8-bit, MLX | 1.0 GB | 2.1 GB |
| Polish, 16 GB and up | Gemma 4 E2B, 4-bit | 3.4 GB | 3.9 GB |
| Polish, 8 GB | Qwen3 1.7B, 4-bit | 0.9 GB | 2.1 GB |
| Voice notes; fallback; CPU-only machines | SenseVoice Small | 228 MB | 0.5 GB |
| Recordings (other languages) | Whisper large-v3-turbo, MLX (4-bit 442 MB) | 1.5 GB | 3.7 GB |

The recommended dictation pair is about 5.9 GB to download on a 32 GB Mac and about 4.4 GB on 16–24 GB (sum of the
two sizes above). Nothing is downloaded until you press Download. Idle models unload after 10 minutes.

**Which platforms?** Dictation, snaps, voice notes and the cards: macOS; the recommended models need Apple silicon.
Recording, local transcription, frames, the review page and exports: macOS, Windows and Linux (X11). Dictation on
Windows and Linux is planned, not built (`TODO.md`). No phone app.

**Which languages?** Dictation was tested in Chinese, English and mixed Chinese–English. Qwen3-ASR lists 30 languages
in Blurt's registry; others were not measured for dictation. Recordings: SenseVoice covers Chinese, English, Japanese,
Korean and Cantonese; Whisper covers 99 languages. Items come back in the language you spoke. The app is in English
and Simplified Chinese.

**Does it replace my agent?** No. It feeds the agents you use: Claude Code, Codex, Cursor, Claude, ChatGPT or any
chat box.

**What permissions does it need?** Microphone; Accessibility (to paste and to hear `Fn`); Input Monitoring (for the
other keys); Screen Recording (for snaps and recordings, asked the first time you need it).

---

## Numbers not sourced

These came up and have no source we could verify. Don't publish them.

- Superwhisper latency: no published or measured number found.
- Accuracy in Chinese and mixed Chinese–English for Typeless, Wispr Flow, Superwhisper and Aqua Voice: not published.
- Wispr Flow and Superwhisper latencies quoted in other vendors' blogs (700 ms, 1,805 ms, "1–2 s"): the pages could
  not be found or didn't contain the number.
- Aqua's Avalon 1.5 WER (5.55) and a 965 ms latency test: seen only in search summaries, not on a page we could read.
- Typeless's current free word limit: its pricing page says only "Limited, reset weekly"; the 2,000 figure comes from
  user reviews.
- Superwhisper yearly and lifetime prices: third-party guides only.
- Blurt on 8 GB and 16 GB Macs, on real microphones and with accents: not measured.
- Blurt dictation with the network off: not tested.
- Blurt live-text lag on Macs under 16 GB: not applicable (live grey text is off there); Blurt's Cantonese accuracy:
  not measured.
