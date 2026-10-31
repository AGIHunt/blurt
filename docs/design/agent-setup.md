# Agent-assisted model setup (2026-10-31)

Setting up models by hand costs users time: which service, which region, where the key page is, which model for which
job. Most Blurt users already run a capable coding agent (Claude Code, Codex, Gemini CLI, Kimi, OpenCode…), and many of
those can drive a browser. This lets that agent set up Blurt's speech, polish, translate and screen-text models with the
user: read the Mac, ask two or three questions, open each provider's key page, take the key the user creates, hand it
to Blurt, choose a model per job and check the result with a test dictation. Manual setup (Settings → Models) is
unchanged.

The pieces:

| | Where |
|---|---|
| CLI the agent runs (JSON in and out) | `skills/blurt/scripts/setup.py` |
| The flow the agent follows | `skills/blurt/reference/setup-models.md` (SKILL.md §9) |
| The app's control endpoint | `BlurtCore/ControlSocket.swift`, `App/AgentSetupServer.swift` |
| Pure rules (requests, grants, `use`, the live list) | `BlurtCore/AgentSetup.swift` (`AgentSetupTests`) |
| UI: Set Up with Agent…, the live list | `Settings/AgentSetupViews.swift`, `CloudServicesPane.swift`, `Onboarding.swift` |
| The session Blurt starts | `sessions.py setup-session` (`AgentSessions.setupSession`) |
| MCP tools | `mcp_server.py` `setup_*` (they import setup.py) |

## 1. The endpoint and its security

The running app listens on a unix domain socket: `$BLURT_HOME/run/control.sock`. When that path is longer than a socket
address holds (103 bytes; deep test folders), both sides use `/tmp/blurt-<uid>/<first 12 hex of sha256(home)>.sock`
(`AgentSetup.socketPath`, `setup.py socket_path`; `tests/fixtures/agent_setup_socket.jsonl` checks both).

- **Only this user.** `run/` (or the `/tmp` folder) is made 0700 and refused when it is a link, another user's, or
  can't be closed; the socket file is chmod 0600 right after bind. Every accepted connection is checked with
  `getpeereid`: a peer of another uid is closed before a byte is read.
- **Reads vs changes.** `hello` and `status` answer any process of this user. `connect`, `test`, `use`, `download` and
  `verify` need a grant (`AgentSetupGrant`):
  - a **session token** — 32 random bytes Blurt issues when the user clicks *Start* in *Set Up with Agent…*; it reaches
    the agent only through its environment (`BLURT_SETUP_TOKEN`, handed to `sessions.py setup-session` on stdin, never
    on Blurt's command lines, never in a job file), lives as long as the session (at most 2 h), and is compared in
    constant time; *Stop* or the session's end revokes it;
  - or the user's **Allow**: a request without a live grant makes Blurt ask (an alert naming the agent it finds among
    the requesting process's ancestors — `AgentSetupPeer` against agents.json's `bins`; else "an app on your Mac").
    Allow opens changes for 30 minutes; Don't Allow (or no answer in 3 minutes, when the alert closes itself) answers
    `denied`. Return doesn't press Allow (the user may be typing in the agent's terminal when it comes up); Esc is
    Don't Allow. One question at a
    time; requests waiting behind it get its answer.
- **Keys.** A key is read only from a `connect` request (`key`, or `app_id` + `access_token` for Volcengine Speech; a
  key on any other request is refused). It is checked (`CloudKeyCheck`, `VolcengineSpeech.problem`), sent to the test
  script on stdin, stored by `CloudStore.connect` in the login Keychain, and dropped. It is never logged (the request
  log has the op, the pid, the job and the preset), written to a file or sent back; an error never quotes it.
  `setup.py` takes it only on stdin (a terminal asks without echo), refuses it as an argument without repeating the
  argument, and never prints it.
- **Where a key can go.** `connect` takes only the curated services (Add Service's list: DeepSeek, Alibaba Cloud Model
  Studio, Volcengine Speech where offered). No request names an address: a key only ever goes to its preset's own host.
  `use --custom` takes a model id on an already connected service only — a new address is a Custom Model the user adds
  in Settings.
- **What a same-user process can still do.** Anything of this user can talk to the socket; the grant is a consent step,
  not a sandbox (a token in an environment is readable to this user's processes; tmux's `-e` puts it on tmux's command
  line for an instant). That is the same trust boundary as the user's Keychain prompt and config.json.

Protocol: one JSON object per line in, one per line out, then the connection closes; at most 64 KB a request
(`too_long`), a line that isn't a JSON object is `bad_request`. Each connection is answered on its own queue.

## 2. Operations (protocol 1)

Every answer has `ok`; a failure has `code` and an English `error` for the agent to put in the user's words.

| op | request | answer |
|---|---|---|
| `hello` | — | `app`, `protocol`, `version`, `pid`, `granted` |
| `status` | — | `mac` {chip, ram_gb, apple_silicon, macos, macos_speech, languages, region, ui_language}; `dictation` {recognizer, in_use, recommended, recommended_local, polish_base, auto, ready, own_language, `choices` [{option, level 3–5, levels {lang: level}, delay_s, cost {kind, cny, usd}, uploads nothing\|text\|voice, to, download_mb, fits, needs, recommended, in_use}], `models` [{id, name, installed, size_mb, fits, recommended}]}; `polish_local`; `downloads` [{id, name, size_mb, running, done_mb}], `download_failed`; `services` [{id, preset, name, region, key, speech, curated}]; `jobs` {polish\|translate\|vision: {choice, route}}; `options` {job: [{option "service:model", name, regions, note (the measured line, in the UI language), measured, connected}]} incl. `speech`; `providers` [{preset, name, pair, speech_only, key_pages {region: url}}]; `progress`; `granted` |
| `connect` | `preset`, `region`?, `key` \| `app_id` + `access_token` | tested first exactly as the Add Service sheet tests (polish_cloud.py check on the service's curated model; Volcengine: transcribe.py check-cloud's clip; Model Studio also its speech clip) → `ok`, `service`, `ms`, `speech`?; then `CloudStore.connect` + the jobs follow (`CloudServiceSheetModel.afterChange`). One service per preset: a new key replaces the old. Codes: `not_curated`, `unknown_preset`, `bad_region`, `no_key`, `bad_key`, `auth`, `network`, `rate_limited`… |
| `test` | `service` (id or preset) | the same check with the key Blurt holds |
| `use` | `job` polish\|translate\|vision\|dictation, `option`, `custom`? | text jobs: `auto`, `local`, a connected service (its curated model), `service:model` (curated → kept as the service alone, as Settings does; else only with `custom`, after `polish_cloud.py check --job` passes — the Custom Model gate). Dictation: `auto` or a `DictationChoice` id, through `DictationChoiceAction.use` (downloads the recogniser when missing: `downloading`). Codes: `not_connected`, `no_option`, `not_curated`, `bad_model`, `needs_key`, `doesnt_fit`, `unknown_job`, `unknown_option` |
| `download` | `model` (an id, or `recommended`) | through the one download manager → `started` [ids], `size_mb`, or `installed` |
| `verify` | `language`? | macOS `say` speaks a fixed sentence (Chinese for zh*, else English) into a 16 kHz wav; `Dictation.transcribe` (the recogniser a take uses, the user's words) and `Dictation.polish` (the take's polish: the cloud model when set, the local one as its fall-back) → `passed` (match ≥ 0.6), `said`, `heard`, `text`, `match`, `recognizer`, `polish` {where, model, fell_back}, `asr_ms`, `polish_ms`, `audio_s`. No microphone, no field, nothing pasted; a streaming recogniser (Volcengine) hears the file, not a live stream |

`setup.py` adds `recommend` (below) and, without the app, `status` from config.json + `transcribe.py dictation-models`
(`"source": "config"`; services with `"key": null`, no levels, no progress). Every other command answers
`app_not_running` with `"fix": "open -a Blurt"` (`sandboxed` when a sandbox blocks the socket: EPERM). `download --wait`
polls `status` until the model is in.

## 3. The plan (`setup.py recommend`)

Inputs: `status`, and the user's answers — `--audio local|cloud` (may the voice leave the Mac), `--text local|cloud`
(may each dictation's text go to a cloud model), `--budget free|paid`, `--languages`. Pure (`setup.plan`, tests in
`tests/test_setup.py`):

1. Dictation's recogniser is this Mac's (`recommended_local`: DictationTier / DictationChoices.recommendedLocal), its
   download first when missing.
2. Text to the cloud (paid): one service for polish, translate and Copy Text from Screen — the one connected already
   (DeepSeek, else Model Studio), else Model Studio when it also recognises speech here, else **DeepSeek** (the
   founder's pick). Each job gets that service's curated model (Model Studio: the region's). Dictation becomes
   `cloud-polish` over the local model (the eval's option A: 2.20 % on the founder's takes, no audio upload, works
   offline).
3. Audio to the cloud (paid): the recommendation only where no local model runs well (Intel, 8 GB) — Qwen3-ASR Flash on
   Model Studio, whose key then covers the text jobs too. Elsewhere it is an `alternative`: Qwen3-ASR Flash, and for
   Chinese speakers Volcengine Seed-ASR 2.0 (mainland accounts; DictationChoices never recommends it).
4. Free: everything on the Mac; nothing to connect.
5. Notes for other languages: English and German have measured levels (`choices[].levels`); Japanese isn't rated (its
   set mixes spellings; macOS Speech was the best local engine on it); others weren't measured.

`steps` lists the commands in order: connect (missing keys), download, use (dictation first), verify.

## 4. In the app

- **Set Up with Agent…** beside *Add Service…* (Settings → Models → Cloud services) and beside *Add…* on onboarding's
  cloud row; shown only when an agent with an interactive session is installed (agents.py detect + sessions.py doctor,
  as the hand-off panel reads them). Disabled while a session it started runs. When every curated service is in (the
  Add row is gone), it keeps a row of its own ("Set Up Models with an Agent"). The line about the key is in the sheet
  only (the Add row keeps one detail line).
- **The sheet** (460 pt): title, one line on what happens and what the user does, the Agent pop-up (installed agents;
  the last one used for sessions first), the same line about the key, Cancel / Start. Start issues the token, runs
  `sessions.py setup-session --agent ID --lang …` (token on stdin; refused like a hand-off when the agent is
  logged out or too old: the sheet shows the fix): a job in project `blurt-setup` (Sessions shows it
  as "Model Setup"), cwd `$BLURT_HOME/setup` (0700), no items, no worktree, the agent's own interactive command with
  the prompt (title + "follow reference/setup-models.md, run `uv run …/setup.py`, ask before changing, help find or
  create each key, never write a key back"; Codex also gets `approval_policy="on-request"`, §7) in tmux on Blurt's
  socket (window `model-setup`), else in the app's own terminal; then Blurt shows that terminal.
- **The live list** (`AgentSetupProgress`): under the services in Settings, and under the cloud row in onboarding. A
  heading ("Setting up with Claude Code"; "Agent setup ended" after), Show Terminal and Stop (Stop: `sessions.py stop`,
  every grant revoked), Done once it's over. One row per thing as the endpoint does it: "Connecting DeepSeek…" →
  "DeepSeek connected" / "DeepSeek: connection failed" (an older key may still be there), "Dictation polish: DeepSeek
  V4.1 Flash", "Dictation: Qwen3-ASR 1.7B + cloud polish", "Downloading Qwen3-ASR 1.7B…" → "… downloaded", "Testing
  dictation…" → "Dictation test passed". A later report about the same thing replaces its row; a new attempt at
  something already over (a second test dictation) moves to the end. Onboarding shows the latest three rows (a
  failed one kept): its page doesn't scroll. A new Allow window after an ended session starts a fresh list.
  The rows above it (services, job pop-ups, onboarding's key line) follow live: `CloudStore.changed`.

## 5. MCP

`mcp_server.py` adds `setup_status`, `setup_recommend`, `setup_connect` (the key as a parameter — MCP has no stdin; it
goes to the app once and is never logged or returned), `setup_test`, `setup_use`, `setup_download`, `setup_verify`.
They import setup.py's functions (one implementation). The skill prefers the CLI with the key on stdin (from wherever
the user keeps it: the clipboard, an environment variable, a file they name), so the key never enters the
conversation.

## 6. Provider pages (checked 2026-10-31)

| Preset | Key page | Checked |
|---|---|---|
| deepseek | https://platform.deepseek.com/api_keys | answers 429 to a script (bot protection); the page exists |
| dashscope (China) | https://bailian.console.aliyun.com/?tab=model#/api-key | 200 |
| dashscope (international) | https://modelstudio.console.alibabacloud.com/?tab=model#/api-key | 200 |
| volcengine-speech | https://console.volcengine.com/speech/app | 302 to sign-in, back to the page after |

`setup.py KEY_PAGES` must equal `CloudPreset.all`'s `keyPage` (a test reads the Swift source).

## 7. Dogfood (2026-10-31)

An isolated test build (`dev.blurt.recorder.layouttest`, scratch BLURT_HOME, keys in memory), screens in zh + en
(`~/blurt-shots-2026-10-31b/agent-setup/`, layoutcheck clean), and real sessions started from the button.

- **Claude Code**: the CLI on the test Mac wasn't logged in; the session sat at "Not logged in · Please run /login".
  setup-session now refuses a logged-out (or too old) agent first, as dispatch does. A logged-in Claude Code run is
  still to do. Its first screen in a new `$BLURT_HOME/setup` is the trust-this-folder question.
- **Codex** (0.165): its seatbelt blocks the socket (EPERM; setup.py said `app_not_running`, now `sandboxed`). With
  Blurt's hooks the session came up as "Workspace (granular)", where Codex may not ask to run a command outside the
  sandbox: the setup stopped at `status`. Started with `-c approval_policy="on-request"` it asks before each setup.py
  command (approve once per command, or the `setup.py` prefix) and ran status → recommend → connect (key piped from a
  file the user named) → use ×4 → verify zh + en → summary, the live list following each step. Stop ended it. A
  permission profile with `network.enabled = true` would let the socket through without approvals but opens all
  network to the session, so it isn't used. Codex also asks to review Blurt's hooks the first time (new paths).
- **verify** reported cloud polish `unavailable`: nothing had started the polish server (a take's key-down does).
  It starts it now and allows the cold load.
- **Keys**: grepped for each key's first and last characters in the tmux panes, the app logs, both Codex
  transcripts and history, the Claude transcript, every file under the scratch BLURT_HOME: not found.
- DeepSeek, Model Studio (China) and Volcengine Speech connected with real keys (one test call each); a wrong key
  answers `auth` and leaves the stored key as it was.

Still not verified: a logged-in Claude Code session end to end, `download` of a real model through the agent (the
recogniser was installed), dark mode of the new surfaces, Gemini CLI / Kimi / OpenCode sandboxes.
