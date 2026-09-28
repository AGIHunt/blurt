# Recording history and post-review execution (macOS)

The macOS app opens a persistent local history page when it saves or begins processing a recording. Open it again from **History & results** in the menu. The page discovers recordings in `~/Blurt/recordings` and configured project `.blurt/sessions` directories.

## Workflow

1. Record a screen and voice session. The configured agent organizes it as before.
2. Watch processing progress in history. The visible page can navigate to review automatically when items are ready; this can be disabled on the page.
3. Review and confirm. Confirmation saves the decisions and returns to the same recording's history page. It does not authorize or start a follow-up task.
4. The page fills an editable task from retained items. Select an existing project and explicitly click **Start execution** to run Codex there.
5. Inspect the execution log, result text, and HTML artifacts. An ended execution is not a claim that its changes were accepted or visually verified.

Copy context is scoped to the selected recording and available at every stage. It copies text and local file references, not the video or images themselves. Unsubmitted task drafts are excluded. The adjacent folder icon opens the recording directory, including previous job snapshots and logs. Copying does not dispatch a task, and progress in an independent agent conversation is not tracked.

## Storage and local service

- `processing.json`: organizing status written by the macOS app.
- `review-state.json` and `reviews/*.json`: review presence and confirmation snapshots.
- `jobs/<id>/state.json`, `reviewed-items.json`, `agent.log`, `result.md`: follow-up execution state and materials.
- `~/.blurt/history-server.json`: loopback service URL and process ID.

The service binds to `127.0.0.1` and uses a random URL token, Host/Origin checks, and session/file path validation. Do not publish the service URL, recording files, or copied local context. Closing the browser does not stop a job. Stopping the history service while a job is running can lose its completion observation; check logs before retrying an interrupted job.

## Current scope

- The new history page has Chinese labels and is integrated into the macOS recorder. Windows integration and English localization remain follow-up work.
- Initial organization still follows the app's existing Codex/Claude selection. Follow-up execution currently supports Codex CLI only, with `workspace-write` and access to the recording directory.
- There is no automatic post-review execution, desktop-chat handoff, external-chat synchronization, or task cancellation in this contribution.
- Live output and copied results are tail excerpts; full logs and results remain in the recording directory.

## Validation

Run from the repository root:

```sh
python3 -m unittest discover -s tests -p 'test_history.py'
python3 tests/check_history_browser.py
```

The browser check additionally requires Playwright and its Chromium browser. Tests create synthetic recordings and use a fake CLI; they do not run a real model or modify a user's project. They cover execution completion/failure/interruption, duplicate rejection, running-state precedence, review round trips, draft persistence, theme sharing, and a narrow viewport.
