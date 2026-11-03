# Set up models (the agent's flow)

Blurt's speech and AI models can be set up by hand in Settings → Models. This flow lets you, the user's agent, do it
with them: read the Mac, ask a few questions, find or get each API key with them, hand it to Blurt, choose a model
per job and check it with a test dictation. These are principles, not a script: work out the details with the user. The contract behind the commands is
`docs/design/agent-setup.md`.

Run every command as `uv run <skill-dir>/scripts/setup.py …` (below: `setup.py …`). Each prints one JSON line:
`{"ok": true, …}` or `{"ok": false, "code", "error"}`. Talk to the user in their language; keep it short and plain.

## Rules

- **The user does the account steps.** Signing in, real-name verification, captchas, phone codes, payment and top-ups
  are theirs. Never fill in a password, solve a captcha or pay; stop where the user has to act and say what to do.
- **Keys stay out of the chat and the logs.** A key goes to `setup.py connect` on stdin and nowhere else: never on a
  command line, never into a file, never printed, never repeated back. Don't ask the user to paste it into the chat.
  Read a file that holds secrets (a `.env`, another tool's config) only with the user's OK, and pipe out just that
  one value without showing it.
- **Blurt asks before changes.** A session started from Blurt (Settings → Models → Set Up with Agent…) is already
  allowed. Otherwise the first change makes Blurt ask the user (Allow / Don't Allow); `"code": "denied"` means they
  said no or didn't answer — ask them, then retry.
- **Blurt must be running.** `"code": "app_not_running"`: ask the user to open Blurt (`open -a Blurt`; run it yourself
  only if they agree). `"code": "sandboxed"`: Blurt is running but your sandbox blocks its socket — run setup.py
  outside the sandbox (Codex: ask for approval to run it unsandboxed), never ask the user to open Blurt again.
- Change only what the user agreed to. Manual setup in Settings → Models stays available; say so if they'd rather.

## 1. Look

`setup.py status` → `mac` (chip, memory, macOS, languages, region), `dictation` (`recognizer` in use,
`recommended_local`, `choices` with `level` 3–5 stars, `delay_s`, `cost`, `uploads`, `fits`; `models` installed or
not), `services` (connected; `key` true when Blurt holds one), `jobs` (polish, translate, vision = Copy Text from
Screen: their `choice` and `route`), `options` (the curated models per job, with a measured `note`), `providers` (key
pages). `"source": "config"` means Blurt isn't running: fine for a first look, not for changes.

## 2. Ask (one message, at most three questions)

1. **May your voice leave this Mac?** No (default): recognition stays on the Mac. Yes: cloud recognition becomes an
   option (Qwen3-ASR Flash on Alibaba Cloud; for Chinese speakers also Volcengine Seed-ASR 2.0 in mainland China).
2. **May the text of each dictation go to a cloud model for polish and translation?** With DeepSeek it's about ¥1 per 1,000
   uses (≈ $1 per 10,000) — say it that way, a round batch, not a fraction of a cent per use. No = everything stays on the Mac, nothing to pay (budget free).
3. **Which languages do you mostly speak?** Suggest the answer from `mac.languages`; they confirm or correct.

Give the facts, not a sales pitch. Never quote error rates: say levels (★) or "more accurate".

## 3. Propose

`setup.py recommend --audio local|cloud --text local|cloud --budget free|paid --languages zh,en` → `connect` (with
`key_page`), `use` per job, `download` (size), `alternatives`, `notes`, and `steps` (the commands in order).

The default is the eval's best option: this Mac's recognizer (`recommended_local`, downloaded if missing) plus
DeepSeek V4.1 Flash for polish, translate and Copy Text from Screen. It is as accurate as cloud recognition, uploads
no audio and works offline (the local text is used when the cloud doesn't answer). Cloud recognition is an option,
never the default, except on a Mac that can't run a local model well (Intel, 8 GB) when the user allows audio.

For someone who doesn't speak Chinese: say what was measured for their language (`dictation.choices[].levels.<lang>`
for English and German; Japanese isn't rated — macOS Speech was the best local engine measured on it; other languages
weren't measured). Volcengine is for mainland China accounts only.

Say the plan in a few lines: each job and its model, what leaves the Mac and to whom, the cost, the download size.
Wait for a yes.

## 4. Keys

For each `connect` entry with `"connected": false`, ask the user whether they already have a key for that service
(and where) or want to create one. Then get it to `setup.py connect` on stdin, whichever way fits:

- they copied it (a key page's Copy button, a password manager): `pbpaste | setup.py connect deepseek`, then offer to
  clear the clipboard (`printf '' | pbcopy`);
- it is in an environment variable or a `.env` file they point to: with their OK, e.g.
  `printenv DEEPSEEK_API_KEY | setup.py connect deepseek` or
  `sed -n 's/^DEEPSEEK_API_KEY=//p' <file> | setup.py connect deepseek`;
- at a terminal, `setup.py connect deepseek` alone asks for it without echo.

Presets: `deepseek`; `dashscope --region china|global` (a Model Studio key works only in its own region);
`volcengine-speech`, which takes `{"app_id": …, "access_token": …}` on stdin (the App ID isn't secret). Blurt tests
the key before it stores it: `"code": "auth"` wrong key or region, `"rate_limited"` no balance or quota (the user tops
up), `"network"` check the connection.

To create a key, `open` the provider's key page (also in `status` → `providers`) and let the user do it there. The
pages change now and then: ask what they see rather than guessing.

| Provider | Key page | Notes |
|---|---|---|
| DeepSeek | https://platform.deepseek.com/api_keys | needs a small balance; a new key is shown only once |
| Alibaba Cloud Model Studio | China https://bailian.console.aliyun.com/?tab=model#/api-key · international https://modelstudio.console.alibabacloud.com/?tab=model#/api-key | China accounts: real-name verification; one key covers polish, translate, Copy Text from Screen and cloud recognition |
| Volcengine Speech | https://console.volcengine.com/speech/app | mainland China accounts, real-name verification; an app with streaming speech recognition (Doubao Seed-ASR 2.0) has the App ID and Access Token |

## 5. Download, choose, check

1. `setup.py download <model> --wait` for each `download` entry (tell the size first; it can take minutes). Without
   `--wait` it returns at once and `status` → `downloads` shows progress.
2. `setup.py use <job> <option>` for each `use` entry. A model that isn't in `options` needs `--custom` and the user's
   go-ahead; Blurt tests it on the job first and refuses it if the test fails. `"needs_key"`: connect its service
   first. `"doesnt_fit"`: this Mac can't run it — pick another. Choosing a local recognizer for dictation also moves
   polish to this Mac, as Settings' comparison does; `cloud-polish` keeps polish in the cloud.
3. `setup.py verify` (or `--language zh|en`): macOS speaks a short sentence, Blurt runs it through the recognizer and
   polish dictation uses (no microphone, nothing pasted) → `said`, `heard`, `text`, `match`, `asr_ms`, `polish_ms`.
   `passed: false` or a failure: tell the user plainly and offer to look at it (`status`, then `test <service>`).

## 6. Sum up

A few plain lines: what dictation, polish, translate and Copy Text from Screen use now; what leaves the Mac and to
whom; the cost; that everything can be changed in Settings → Models. No keys, no error rates.

## Notes by agent

- **Claude Code**: run the commands with Bash; with Claude in Chrome or computer use, open the key page in the
  browser and stop at sign-in. **Codex**: its sandbox blocks the socket to Blurt (setup.py answers
  `"code": "sandboxed"`), so run every setup.py command outside the sandbox, with the user's approval. If this session
  may not ask for that, ask the user to choose `/permissions` → Ask for approval, then retry (a session Blurt starts
  already asks). **Gemini CLI, Kimi, OpenCode, others**: any shell tool works.
- MCP: the same operations are the blurt MCP server's `setup_status`, `setup_recommend`, `setup_connect` (key as a
  parameter — prefer the CLI with the key on stdin, so it stays out of the conversation), `setup_test`, `setup_use`,
  `setup_download`, `setup_verify`.
