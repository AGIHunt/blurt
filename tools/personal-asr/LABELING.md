# Labeling the user's dictations

You are fixing transcripts of one person's real dictations so they can be used to fine-tune a speech recognizer for
that person. You cannot hear the audio. For every piece (a stretch between pauses) you get three independent
transcripts from local models, the app and field it was dictated into, and the text that was finally typed. Decide
what the person actually **said**.

## The speaker

Read the speaker notes given with your batch (a local file, `~/.blurt/personal-asr/speaker.md` by default: who they
are, where they dictate, the words they use and their recurring mishearings; never committed). The word list the app
knows is in `terms` of each batch file. A mishearing stands for a class: English product names split, mis-cased or
turned into Chinese sound-alikes; Chinese words heard as similar-sounding ones.

## What to write for each piece

- `said`: what was spoken, in the style a speech recognizer writes. Start from the three transcripts and change only
  what is wrong.
  - Keep fillers (呃, 嗯), repetitions and false starts that the transcripts show. Do not polish, reorder, summarize or
    delete words that were spoken. Do not add words nobody heard.
  - Write English words and product names in their normal spelling and case (Claude Code, GitHub, LoRA).
  - Numbers: Arabic digits in the recognizer's output, whatever the models wrote. Use digits for
    anything that is a number or a code: versions (二点三点一 → 2.3.1), model sizes (七B → 7B), quantities and
    counts (三个 → 3 个, 二百五十条 → 250 条), money, percentages (百分之五十 → 50%), dates and times (十一月八号 →
    11 月 8 号, 十点半 → 10 点半), durations (五分钟 → 5 分钟), product numbers (iPhone 十六 → iPhone 16),
    ordinals and list items (第三个 → 第 3 个, 二、 → 2、). Keep Chinese where the numeral is part of a word, not a
    number: 一些, 一下, 一起, 一直, 一般, 一点儿 (a little), 一样, 万一, 三要三救, 一模一样, 十分 (very), 不一定.
    Read the meaning, not the characters: 一点 is 1. only when a decimal follows.
  - Simplified Chinese. Punctuation: normal Chinese punctuation, it is not scored.
  - When the models disagree, prefer the reading that makes sense in context (the rest of the dictation, the app,
    the field text, the typed text, what this speaker talks about). Sound-alike nonsense is a mishearing.
  - If the typed text differs from all transcripts in a way that looks like the person's own fix, it is strong evidence.
- `sure`: true when you are confident; false when the piece is unclear (models disagree and context does not settle
  it, possible names you cannot verify, mumbled or cut off). Be honest: unsure pieces go to the person to check.
- `note`: only when unsure, a few words on what is in doubt (for example "人名？" or "可能是 Sonnet").
- An empty or noise-only piece: `said` "" and `sure` true.

## What to write for each dictation

- `intended`: the text the person meant to send, cleanly written: fillers and restarts removed, mishearings fixed,
  punctuation and spacing tidy (space between Chinese and English), numbers in digits where natural, their own words
  and tone kept (do not formalize, do not translate). This is for evaluating polishing later.

## Output

One JSON object per line, in the same order as the input:

```json
{"id": "d-...", "pieces": [{"n": 0, "said": "...", "sure": true}, {"n": 1, "said": "...", "sure": false, "note": "..."}], "intended": "..."}
```

Every input piece `n` appears once. Write valid JSON only, no commentary in the file.
