# items.json — the output of one recording

One recording can mix several kinds of things (a bug, then an idea, then a todo). Each item carries a `kind`;
kind-specific fields come from its **lens** (`reference/lenses/<kind>.md`, or a custom lens — see below).

```jsonc
{
  "schema": 2,                            // written by items.py (v1 files have none and read the same)
  "session": "20260926-101500",
  "source_video": "recording.mp4",       // relative to the session dir
  "language": "zh",                       // language the user spoke; drives labels
  "title": "官网改版的一些想法",             // one line for the whole recording
  "digest": "## 总览\n- …",                // optional markdown overview — write one for exploratory / idea sessions
  "reviewed": false,                      // set true by review.py when the user finishes
  "processing": true,                     // you're still adding frames etc.; `items.py done` removes it
  "agent_at": 1792560000.0,               // written by items.py on every change (the page shows a stall after 10 min)
  "_removed": {"I-004": "I-003"},         // by the page: items the user merged away (→ target id, "" = none)
  "items": [
    {
      "id": "I-001",                      // stable, sequential
      "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABCD", // by items.py — never write it yourself; unique across sessions.
                                          // `items.py add` assigns a ULID; an item written without one has
                                          // "L" + sha1("<session dir name>/<id>").hex[:25], persisted on the next
                                          // items.py write (`items.py get` / `list` always show it)
      "kind": "issue",                    // issue | idea | note | task | <custom lens name>
      "title": "登录按钮点击后无响应",
      "quote": "这个登录按钮点了之后没有任何反应…",   // what the user said (lightly cleaned)
      "time": {"start": 12.4, "end": 30.1},  // seconds in the recording
      "frames": [{"path": "frames/I-001-1.jpg", "t": 14.2, "caption": "…"}],   // first = primary
      "clip": "clips/I-001.mp4",          // optional
      "source": {"url": "https://…", "app": "Chrome"},   // optional: where it was seen (read it off the frame)
      "tags": ["登录"],
      "confidence": "high",               // high | low
      "questions": [],                     // what the user must clarify
      "answer": "",                        // filled in on the review page
      "status": "draft",                  // draft | confirmed | deleted
      "exported": {},                      // written by exporters; prevents duplicates
      "_user": {"title": 1792560123.4},    // by the page: fields the user edited (→ epoch); items.py won't overwrite them
      "fix": {                             // by `items.py fix` only; absent = never handed to an agent
        "state": "fixed",                  // fixing | fixed | wontfix | reopened
        "agent": "claude",                 // agents.json id, or "human"
        "run_id": "r-20261021-101500-ab12", // the app's agent run, or null
        "commit": "a1c3e5f", "pr": null, "note": "", "at": 1792560000.0
      },
      "fix_history": [],                   // earlier "fix" objects, oldest first

      // + the lens's own fields, e.g. for "issue": module, owner, severity, type, actual, expected, steps, code_refs
    }
  ]
}
```

Unknown fields are fine — the review page shows any extra string / list fields generically, exporters ignore them.

Every item must have a `kind` and an `id`.

`status` is the review state; whether a bug got fixed is `fix.state`, kept apart. Record a fix with
`items.py fix <session> <id|uid> --state fixing|fixed|wontfix|reopened [--commit SHA] [--pr URL] [--note …]`:
a new state moves the current `fix` onto `fix_history`; the same state again only adds to it (e.g. the commit).

**Who writes what.** You write the file once (§3: text, `"processing": true`, no picked frames — a snap's
`shots/<NNN>.png` is already its item's first frame). After `review.py` has
started, the user edits it too: change it only with `items.py` (locked, atomic, keeps the user's fields). Shots
sessions have no `source_video`; their frames point at `shots/<NNN>.png` with `"t": null`.

## Custom lenses

A team can add its own lens as a markdown file — `.blurt/lenses/<name>.md` in the project, or `~/.blurt/lenses/` —
describing when to use it and which fields to fill (same format as the built-in ones). Examples: `ux-research`,
`competitor`, `sales-call`, `sop` (a recorded how-to). Use it when the user asks for it or the content clearly fits.
