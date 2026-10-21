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
(or the `items.py work … --state to_verify` command in the note). An agent's "fixed" only reaches *to verify*;
the user confirms *done*.

## Dispatch

```
sessions.py dispatch --items BA-12 BA-13 [--agent claude|codex|…] [--mode together|parallel]
                     [--worktree on|off|auto] [--runner tmux|app|auto] [--dry-run] [--lang en|zh]
```

- `together` (default): one window, one conversation for all the items. `parallel`: one window per item, each in
  its own git worktree.
- Worktrees (default per project, `worktree: true`) live outside the repo in `<repo>/../.<repo>-worktrees/<id>`
  on a branch `blurt/<id>-<slug>`; the agent commits there and never pushes. Without a worktree the agent edits
  the project folder and doesn't commit.
- Two sessions editing the same folder directly is allowed; `--dry-run` returns a `concurrent_edit` warning first
  so the app can suggest a worktree. Other warnings: `no_git`, `no_tmux`, `draft_confirmed`.
- Items must be in one project with a folder (`needs_project` otherwise), not dropped, and *to do* or *handed off*.
- Without tmux (or on Windows) the app runs the returned `launch` argv in its own terminal and reports the exit
  with `sessions.py event --job J --event pane-dead --exit N`.

## Status

Every session is a job of type `agent` in `$BLURT_HOME/jobs/` (see `jobs.py`). Its `agent.status`:
`running` · `waiting_input` · `turn_done` · `exited` · `error`.

- Claude Code gets per-session hooks through `--settings <job>.claude-settings.json` (the user's settings are
  untouched); Codex gets `-c notify=[…]` and `-c hooks.*`. Both call `sessions.py hook`, which appends one event
  line and returns at once.
- Codex asks the user once to trust Blurt's hooks ("Hooks need review"); the hook command is the same for every
  session, so it asks only again when Blurt moves. Until then status comes from the terminal.
- Agents without hooks: `interactive.waiting_patterns` (agents.json) on the bottom lines of the window mean
  *waiting for you*; 8 s without output after running means *turn finished*.
- `sessions.py monitor` (the app keeps one running) also notices windows that exited and moves items along:
  the first sign of life → *in progress*; the agent exited → items still in progress go to *to verify*.

## Finishing

```
sessions.py finish JOB --action diff|merge|pr|discard|keep [--keep-branch]
```

`diff` writes `jobs/<id>.diff` and returns per-file counts; `merge` needs a stopped agent, a committed worktree
and the project folder clean on the base branch (`--no-ff`; a conflict is aborted and reported); `pr` pushes the
branch and opens a PR with `gh` when it is installed (otherwise a compare URL); `discard` removes the worktree and
branch. Only run `merge`, `pr` or `discard` when the user asked for it.

## Other commands

`sessions.py list [--project ID] [--all]`, `attach-cmd JOB` (argv for an embedded terminal: a grouped view per
terminal), `send JOB --text T [--enter]`, `stop JOB [--kill]`, `doctor`.
`jobs.py get|list|watch|gc`; `handoff.py get H-0012`; `agents.py prompt work --items …`.
