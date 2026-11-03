# Install paths and agents (2026-10-31)

How people get Blurt, how it gets into their agents, how they start it there, and what needs a restart. Checked on
this Mac (Claude Code 2.1.259, Codex 0.165.0, Kimi Code 0.36.0, OpenCode 1.1.56, Grok 1.0.70, WorkBuddy 5.5.1, Cursor
installed; Gemini CLI and CodeBuddy Code not installed) with every install and connect run in a scratch `HOME`
(plus `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `KIMI_CODE_HOME`); the user's own agent configs were not touched.

## The three paths

| Path | Who | Command | What it installs | Checked |
|---|---|---|---|---|
| A. App | people | [Blurt.dmg](https://github.com/AGIHunt/blurt/releases/latest/download/Blurt.dmg) → drag to Applications | the app; its skill copy goes to `~/.blurt/skill` at launch | dmg = the release `install.sh` downloads |
| B. Agent or terminal | anyone with a shell | `curl -fsSL https://blurt.work/install.sh \| sh` | same as A, then opens it | `BLURT_INSTALL_DIR=<scratch>`: downloaded 1.0.6, `spctl` passed, copied with its bundled skill; deployed script = repo script |
| C. Source, no app | developers | `npx skills add AGIHunt/blurt -g` or Claude Code `/plugin marketplace add AGIHunt/blurt` + `/plugin install blurt@blurt` | the skill (the plugin also the MCP server and a SessionEnd hook); the first "start blurt" builds the app into `~/Applications` | both run in a scratch HOME |

After A or B, connecting an agent is a separate step: *Settings → Agents → Connect…* (preview, then apply), or the
agent runs `uv run ~/.blurt/skill/scripts/agents.py install <id> [--dry-run]` (the steps are in `site/llms.txt`).

Findings that changed the docs:
- `npx skills add AGIHunt/blurt` without `-g` installs into the **current project** (`./.agents/skills`,
  `./.claude/skills`), not for the user. Run by an agent, it also picks every agent it knows. `-g -y` without `-a`
  wrote the skill into 55 agent folders in an empty HOME. The docs now say `-g`, and `-a claude-code -a codex` to choose.
- `/plugin marketplace add` alone installs nothing: `/plugin install blurt@blurt` is the second step (CLI:
  `claude plugin marketplace add AGIHunt/blurt` and `claude plugin install blurt@blurt`, both checked;
  `claude plugin validate` passes on the repo, with one warning: the marketplace has no description).
- llms.txt called the download "the v1.0.0 release"; it is the latest release.
- Nothing told the user that a connected agent needs a new session. The Connect sheet now says so after it connects
  (`install.next`).

## Which agent, how it is connected

| Agent | Skill folder | MCP server | Connect from the app | Headless organizing |
|---|---|---|---|---|
| Claude Code | `~/.claude/skills/blurt` | `claude mcp add --scope user` | yes (run) | yes |
| Codex | `~/.agents/skills/blurt` | `codex mcp add` → `$CODEX_HOME/config.toml` | yes (run) | yes |
| Gemini CLI | `~/.agents/skills/blurt` (alias of `~/.gemini/skills`) | `gemini mcp add --scope user` | yes (docs) | yes |
| Kimi Code | `~/.agents/skills/blurt` | `$KIMI_CODE_HOME/mcp.json` | yes (run) | yes |
| OpenCode | `~/.config/opencode/skills/blurt` | `~/.config/opencode/opencode.json` | yes (run) | yes |
| Grok | `~/.agents/skills/blurt` | `grok mcp add` | yes (run) | yes |
| CodeBuddy Code (new) | `~/.codebuddy/skills/blurt` | `~/.codebuddy/mcp.json` | yes (docs; CLI not installed here) | no (connect only) |
| WorkBuddy (new) | `~/.workbuddy/skills/blurt` | `~/.workbuddy/mcp.json`, uv by full path | yes (paths read from the app) | no (desktop app) |
| Cursor (new) | `~/.agents/skills/blurt` (Cursor also reads `~/.claude/skills`) | `~/.cursor/mcp.json`, uv by full path | yes (docs) | no (desktop app) |
| ZCode | — | — | by hand in ZCode's settings | no |
| Others (Qoder, Trae, Windsurf, Cline, Qwen Code…) | `npx skills add AGIHunt/blurt -g -a <agent>` | the agent's own MCP settings: `uv run --script ~/.blurt/skill/scripts/mcp_server.py` | no | no |

"run" = connected for real in a scratch HOME with the real CLI (`agents.py install <id>`, twice: the second run
reports everything as already there). "docs" = paths from the agent's documentation. WorkBuddy's paths come from
its app bundle (`~/.workbuddy/skills/<name>/SKILL.md`, `~/.workbuddy/mcp.json` with `mcpServers`, a file watcher on
it); whether it follows a symlinked skill folder is not verified. Desktop apps start MCP servers without the login
shell's PATH, so their entry gets uv's absolute path (`{uv}` in agents.json).

## Starting a recording: path × agent

| | Claude Code | Codex | Others with skills |
|---|---|---|---|
| Natural language ("start blurt", "开始口喷", "录屏提 bug") | yes: the skill's description lists them | yes: implicit skill use by description | yes where the agent reads skills |
| Slash command | `/blurt` (personal skill, from A/B Connect or `npx -g`); `/blurt:blurt` from the plugin (newer Claude Code also takes the bare `/blurt`) | no: `/blurt` gives "Unrecognized command" (codex-rs `chat_composer.rs`); use `$blurt` or `/skills` | Cursor: `/blurt`; Gemini: `/skills` |
| What records | with the app: the app (`open blurt://record`, one click in the notch, the app's own Screen Recording); without: `record.py start` as a child of the agent's terminal | same; Codex's sandbox may ask before running `open` or `record.py` (not checked) | same |

## What needs a restart

| Change | Takes effect |
|---|---|
| Microphone, Accessibility, Input Monitoring for Blurt | right away |
| Screen Recording for Blurt | after Blurt restarts; Settings has *Restart Blurt* |
| Connect… (skill + MCP) | the agent's next session. Claude Code: a new MCP server loads at session start; a skill folder added mid-session needs `/reload-skills` or a new session (edits to an existing skill reload live). Codex: skills are detected live, MCP servers (config.toml) at start. Others: at session start |
| Blurt itself after Connect | never: the app runs `agents.py` each time |
| Claude Code plugin | `/plugin` in the session activates it when you close the menu; from another terminal, `/reload-plugins` or a new session |
| Recording via `record.py start` (no app) | Screen Recording goes to the terminal app hosting the agent, which must restart after it is allowed — this ends the agent session. With the app installed the skill now starts the recording in the app instead |

## Choices

- **One primary way per audience.** People: the Download button. An agent: the `curl … | sh` line. It is the same
  for every agent, needs no web fetch, and also works pasted into a terminal. The site and README stay with it.
  llms.txt carries the full agent steps (check the Mac, run it, hand permissions to the user, connect with the user's
  OK, ask for a new session). install.sh's last lines point the agent there. A natural-language line ("Install Blurt:
  follow https://blurt.work/llms.txt") works in agents that can fetch a URL (Claude Code, Codex with network); a bare
  "安装口喷鸡" doesn't, since the agent doesn't know Blurt yet.
- **Recording from an agent goes through the app when there is one.** Before, the skill always ran `record.py
  start`. On a Mac with the app, that runs the app's recorder binary as a child of Terminal, iTerm or Codex. macOS
  then asks for Screen Recording for that host, and it only works after the host restarts. `blurt://record` already
  existed with a one-click confirmation, so SKILL.md §1 now uses it when the app is installed.
- **New agents are connect-only.** CodeBuddy Code's CLI mirrors Claude Code's flags (`-p`, `--permission-mode`,
  `--allowedTools`). A least-privilege headless run, like Claude's, could be added once it is checked on a real install.
