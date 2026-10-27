# items.json — what you write for one recording

One recording can mix several kinds of things (a bug, then an idea, then a todo). Each item carries a `kind`;
kind-specific fields come from its **lens** (`reference/lenses/<kind>.md`, or a custom lens — see below).

You write `<session>/items.json` **once** (SKILL.md §3). `items.py ingest <session>` (or any `items.py` command on
the session) turns it into one Markdown file per item in the project's store and renames it `items.ingested.json`;
from then on every change goes through `items.py`.

```jsonc
{
  "session": "20260926-101500",
  "source_video": "recording.mp4",       // relative to the session dir; none for screenshot / voice sessions
  "language": "zh",                       // language the user spoke: drives the item files' section headings
  "title": "官网改版的一些想法",             // one line for the whole recording
  "digest": "## 总览\n- …",                // optional markdown overview — write one for exploratory / idea sessions
  "processing": true,                     // you're still adding frames etc.; `items.py done` ends it
  "items": [
    {
      "id": "I-001",                      // your draft id, sequential; items.py gives the item its real id (BA-12)
      "kind": "issue",                    // issue | idea | note | task | <custom lens name>
      "title": "登录按钮点击后无响应",
      "quote": "这个登录按钮点了之后没有任何反应…",   // what the user said (lightly cleaned)
      "time": {"start": 12.4, "end": 30.1},  // seconds in the recording (null for screenshots)
      "frames": [{"path": "frames/I-001-1.jpg", "t": 14.2, "caption": "…"}],   // relative to the session; first = primary
      "clip": "clips/I-001.mp4",          // optional
      "source": {"url": "https://…", "app": "Chrome"},   // optional: where it was seen (read it off the frame)
      "tags": ["登录"],
      "confidence": "high",               // high | low
      "questions": [],                     // what the user must clarify; their reply lands in "answer"
      "project": "BA",                    // optional, Unassigned captures only: the project you suggest (id or key) …
      "project_reason": "code_refs in web/src",   // … and why, in a few words. Never moves it: suggested_project
      // no state: every item you write starts as "new" — keeping, finishing or discarding is the user's call

      // + the lens's own fields, e.g. for "issue": module, owner, severity, type, actual, expected, steps, code_refs
    }
  ]
}
```

Don't write `uid`, `work`, `fix`, `_user` or `exported`: items.py and the apps own them. Unknown fields are fine — the
review page shows extra string / list fields generically, exporters ignore them. Every item needs a `kind`, an `id`
and a `title`.

## The item file (what ingest makes; read it, never write it)

`<project>/.blurt/items/BA-12-登录按钮点击后无响应.md` (inbox: `~/Blurt/inbox/items/IN-3-….md`). Front-matter, one key
per line with a JSON value, then `## ` sections in the language of the item:

```markdown
---
schema: 3
id: BA-12
uid: 01JB7ZK3Q4M8W2E5R6T9Y0ABCD
kind: issue
title: "登录按钮点击后无响应"
state: to_verify
work: {"to": "session", "agent": "claude", "job": "j-…", "handoff": "H-0012", "claim": "fixed", "note": "…", "commit": "a1c3e5f", "pr": null, "at": "2026-10-22T10:20:41+08:00", "by": "agent"}
project: 3f2a9c1b7e44
project_by: capture
created: "2026-10-22T10:15:00+08:00"
updated: "2026-10-22T10:20:41+08:00"
source: {"type": "recording", "by": "john", "role": null, "app": "Chrome", "url": "https://…", "session": "/abs/…/sessions/20261022-101500", "shot": null, "local_id": "I-001"}
frames: [{"path": "assets/01JB…/1.png", "t": 14.2, "caption": "登录按钮是灰的"}]
---

## 原话

> 这个登录按钮点了之后没有任何反应

## 复现步骤

1. 打开 /login
2. 点击登录

## 截图

![登录按钮是灰的 · 0:14](../assets/01JB…/1.png)
```

- **id vs uid**: `BA-12` is a label (project key + number) and changes when the item moves to another project (the
  old one goes to `aliases`); `uid` never changes. Use the uid in anything you keep.
- **state** — one per item, the whole lifecycle:

  | state | means | who moves it there |
  |---|---|---|
  | `new` | captured, the user hasn't looked yet | items.py, when you write it |
  | `todo` | the user kept it | the user |
  | `handed_off` | given to an agent (a Blurt session, or an instruction copied to their own agent) | the app / the user |
  | `in_progress` | an agent is on it | you (`mark_fixed` fixing), the app |
  | `to_verify` | an agent says it's finished (`work.claim`: fixed or wontfix) | you (`mark_fixed` fixed / wontfix), the app |
  | `done` | the user confirmed it | the user only |
  | `wontfix` | the user decided not to | the user only |
  | `discarded` | thrown away (restorable; `restore_to` says where it goes back) | the user only |

  The user's inbox ("needs you") is `new` + `to_verify`. Files from before (a `status: draft|confirmed|deleted` plus
  `work.state`, or a v0.6 `fix`) read as the same states and are rewritten with `state` on their next write. A merged
  item is `discarded` with `merged_into` (the uid it went into); the target lists it in `merged_from`.
- **work** holds the details of the last hand-off: to (session | external), agent, job, handoff, claim, note,
  commit, pr, at, by. Earlier ones, with the state they belonged to, are in `work_history`.
- `_user`: fields the user edited (→ epoch); `items.py` won't overwrite them unless you pass `--force`.
- `project_by`: `capture` (filed when captured), `user` (the user moved it), `migrate`; `ai` only on items an
  earlier version sorted. An organizing run's suggestion for an Unassigned item is `suggested_project`
  (`{id, reason}`); it stays when the user moves the item, and shows only while the item is in Unassigned.

## Custom lenses

A team can add its own lens as a markdown file — `.blurt/lenses/<name>.md` in the project, or `~/.blurt/lenses/` —
describing when to use it and which fields to fill (same format as the built-in ones). Examples: `ux-research`,
`competitor`, `sales-call`, `sop` (a recorded how-to). Use it when the user asks for it or the content clearly fits.
Long text fields (several lines, or over 200 characters) become their own `## <field>` section in the item file.
