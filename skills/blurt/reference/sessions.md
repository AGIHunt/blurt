# Agent sessions, jobs and hand-off notes

How Blurt hands items to Claude Code, Codex and other coding agents (contract K4–K6 in
`docs/design/next-round.md`). Read this when the user asks you to start, check or finish a session, or to hand
items to their own agent.

## Two ways to hand items over

- **A session in Blurt** — `sessions.py dispatch --items REF …` starts the agent interactively in a tmux window on
  Blurt's own socket (`tmux -L blurt`, never the user's tmux). One tmux session per project (`blurt-<slug>`), one
  window per dispatch, named after the item ids. The user can type into it at any time from the app or from their
  own terminal (`sessions.py open-external JOB`).
- **The user's own agent** — `handoff.py create --items REF …` writes a note and returns a one-line instruction to
  paste; `--mark` records the items as handed off (external) once the user has copied it.

Both write the same note: `$BLURT_HOME/handoff/H-0012.md` — titles, what the user said, actual / expected, steps,
suspected code, and screenshots as absolute paths. Agents finish an item with the blurt MCP tool `mark_fixed`
(or the `items.py state … --state to_verify` command in the note). An agent's "fixed" only reaches *to verify*;
the user confirms *done*.

## Dispatch

```
sessions.py dispatch --items BA-12 BA-13 [--agent claude|codex|…] [--mode together|parallel]
                     [--worktree on|off|auto] [--runner tmux|app|auto|desktop] [--dry-run] [--lang en|zh]
```

- `together` (default): one window, one conversation for all the items. `parallel`: one window per item, each in
  its own git worktree.
- Worktrees (default per project, `worktree: true`) live outside the repo in `<repo>/../.<repo>-worktrees/<id>`
  on a branch `blurt/<id>-<slug>`; the agent commits there and never pushes. A sandboxed agent (agents.json
  `interactive.session.sandboxed`: Codex, whose sandbox can't write a linked worktree's index in the repo's `.git`)
  leaves its changes uncommitted instead, and `finish merge|pr` commits them. Without a worktree the agent edits
  the project folder and doesn't commit.
- Two sessions editing the same folder directly is allowed; `--dry-run` returns a `concurrent_edit` warning first
  so the app can suggest a worktree. Other warnings: `no_git`, `no_tmux`, `draft_confirmed`.
- Items must be in one project with a folder (`needs_project` otherwise), not dropped, and *to do* or *handed off*
  — and not handed off to a session that is still going (`already_dispatched`, with its `job`). One dispatch runs
  at a time (`$BLURT_HOME/run/dispatch.lock`).
- Without tmux (or on Windows) the app runs the returned `launch` argv in its own terminal and reports the exit
  with `sessions.py event --job J --event pane-dead --exit N`.

## The title line

Every hand-off prompt starts with a title line, then a blank line, then the instructions: one item
`AW-12 · <title> (Blurt hand-off)`, several `3 items · <project> (Blurt hand-off)` (Chinese: `（口喷鸡交接）`). Agents list a
conversation by its first message, so that is what the user sees there. Codex threads also get it as their name:
once a session's hooks report its thread id, `sessions.py name-thread` sets it through `codex app-server`
(`thread/name/set`, the session's own `CODEX_HOME`), best effort; the outcome is `agent.thread_name` on the job.

## Claude desktop

`sessions.py dispatch … --runner desktop` (agents with `interactive.desktop` in agents.json — Claude) makes the
worktree and the note as usual and returns each job's `url`: `claude://code/new?folder=<worktree>&q=<prompt>`, the note
inline while the link stays under about 14k characters, else the short prompt pointing at the note. Nothing starts:
the app opens the link and the user confirms the folder and presses Send in Claude. The job (`agent.runner:
"desktop"`) has no window and no live status; its items move only when you report (`mark_fixed` with state `fixing`
when you start an item, `fixed` when it's done), and it ends once none is still with it — then its worktree is
reviewed and merged as usual. Without the blurt MCP installed for Claude (the dry run's `mcp: false`) nothing can
report: the user marks the items by hand.

`sessions.py continue-desktop JOB` moves a running Claude session from Blurt's terminal to the desktop app (its agent
ends in the window, then `claude --desktop --resume <session id>`); `sessions.py desktop-check` says whether that is
available (Claude Code 2.1.285 or later, signed in with a subscription). Don't run either unless the user asked.

## Status

Every session is a job of type `agent` in `$BLURT_HOME/jobs/` (see `jobs.py`). Its `agent.status`:
`running` · `waiting_input` · `turn_done` · `exited` · `error`.

- Claude Code gets per-session hooks through `--settings <job>.claude-settings.json` (the user's settings are
  untouched); Codex gets `-c notify=[…]` and `-c hooks.*`. Both call `sessions.py hook`, which appends one event
  line and returns at once.
- Codex asks the user once to trust Blurt's hooks ("Hooks need review"); the hook command is the same for every
  session, so it asks only again when Blurt moves. Until then status comes from the terminal.
- Agents without hooks: `interactive.waiting_patterns` (agents.json) on the bottom lines of the window mean
  *waiting for you*; 8 s without output after running means *turn finished*. Claude Code's window is read the same
  way until its first hook: its workspace-trust dialog fires none (→ *waiting for you*), and
  `interactive.error_patterns` ("Not logged in · Please run /login") make the session an `error` with that line as
  `job.error`, its window left open to read.
- The watchdog: an agent with hooks whose hooks never spoke and whose window has been still for a minute since it
  started (a screen nothing recognises — an update notice, a login page) becomes `waiting_input` with
  `status_source: "watchdog"` and its last lines in `agent.last_output`; the app says *No response* and offers
  Restart Session. Any new output or hook takes it back to running.
- When an agent exits, its window's last lines are kept as `agent.last_output`; a non-zero exit becomes `job.error`
  (`agent_exit`, or the class its words fit: `auth`, `quota`…, message = the last line). A worktree session's
  `agent.changes` = `{ahead, dirty}` once it ended ("ready to review" only when there is something).
- tmux (`$BLURT_HOME/tmux.conf`): windows start at 80×24 and grow with the attached terminal (a big window shrunk
  on attach pushed the last lines out of view), `remain-on-exit` without tmux's "Pane is dead" line,
  `focus-events off` and `escape-time 50` (nothing reaches an agent while it starts). Codex starts with
  `-c check_for_update_on_startup=false`.
- `sessions.py monitor` (the app keeps one running) also notices windows that exited and moves items along:
  the first sign of life → *in progress*. An exit moves nothing: only your own report (`items.py state … --state
  to_verify --claim fixed|wontfix`, MCP `mark_fixed`) takes an item to *to verify*. Exit without it and the item
  stays *in progress*; the app tells the user the session ended without reporting back.

## Finishing

```
sessions.py finish JOB --action diff|merge|pr|discard|keep [--keep-branch]
```

`diff` writes `jobs/<id>.diff` and returns per-file counts, `uncommitted` and `ahead`; `merge` needs a stopped
agent and the project folder clean on the base branch, commits what the agent left uncommitted ("<IDs> <title>
(Blurt hand-off)", the user's own hooks apply), then merges (`--no-ff`; a conflict is aborted and reported); `pr`
needs a stopped agent too, commits the same way, pushes the branch and opens a PR with `gh` when it is installed
(otherwise a compare URL). Both refuse a branch with no changes (`nothing`). `discard` removes the worktree and
branch and takes the items still with the session back to *to do*. Only run `merge`, `pr` or `discard` when the
user asked for it.

```
sessions.py restart JOB
```

The same items, agent, model and worktree choice in a fresh session, for one that ended without changes (it
couldn't start, or stopped at once) or that the watchdog gave up on; one that left changes is refused
(`has_changes`). Once per job: a job already restarted (or merged, discarded…) is refused with `finished` (and the
new jobs) before anything is touched — the new session reuses the old worktree path and branch name. Everything is
checked first (the items, the agent's login), under the dispatch lock; then the old window, worktree and branch go
(only when no other session records them) and the old job's `agent.finish` = `{action: "restart", result: {jobs:
[new]}}`.

`dispatch` (and `restart`) refuse an agent its own status command reports logged out: code `auth`, with `agent` and
its `fix`. `--force` skips that check when the caller already made it (the app's hand-off panel does).

## Other commands

`sessions.py list [--project ID] [--all]`, `attach-cmd JOB` (argv for an embedded terminal: a grouped view per
terminal), `send JOB --text T [--enter]`, `stop JOB [--kill]`, `doctor`, `desktop-check [--agent claude]`,
`continue-desktop JOB`, `name-thread --job J --thread T` (the hooks run it).
`jobs.py get|list|watch|gc`; `handoff.py get H-0012`; `agents.py prompt work --items …`.
