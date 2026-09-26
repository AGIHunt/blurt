# items.json — the output of one recording

One recording can mix several kinds of things (a bug, then an idea, then a todo). Each item carries a `kind`;
kind-specific fields come from its **lens** (`reference/lenses/<kind>.md`, or a custom lens — see below).

```jsonc
{
  "session": "20260926-101500",
  "source_video": "recording.mp4",       // relative to the session dir
  "language": "zh",                       // language the user spoke; drives labels
  "title": "官网改版的一些想法",             // one line for the whole recording
  "digest": "## 总览\n- …",                // optional markdown overview — write one for exploratory / idea sessions
  "reviewed": false,                      // set true by review.py when the user finishes
  "items": [
    {
      "id": "I-001",                      // stable, sequential
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

      // + the lens's own fields, e.g. for "issue": module, owner, severity, type, actual, expected, steps, code_refs
    }
  ]
}
```

Unknown fields are fine — the review page shows any extra string / list fields generically, exporters ignore them.

Backward compatibility: older sessions have `issues.json` with `issues: [...]` (no `kind`). Every script reads
`items.json` first and falls back to `issues.json`, treating those entries as `kind: "issue"`.

## Custom lenses

A team can add its own lens as a markdown file — `.blurt/lenses/<name>.md` in the project, or `~/.blurt/lenses/` —
describing when to use it and which fields to fill (same format as the built-in ones). Examples: `ux-research`,
`competitor`, `sales-call`, `sop` (a recorded how-to). Use it when the user asks for it or the content clearly fits.
