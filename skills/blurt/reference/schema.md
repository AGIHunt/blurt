# issues.json schema

```jsonc
{
  "session": "20260925-143200",
  "source_video": "recording.mp4",       // relative to the session dir
  "language": "zh",                       // language the user spoke; drives labels/columns
  "reviewed": false,                      // set true by review.py on Confirm
  "issues": [
    {
      "id": "B-001",                      // stable, sequential
      "title": "登录按钮点击后无响应",        // one sentence, specific
      "module": "登录页",                   // product's own naming
      "owner": "小王",                      // as named by the user, or inferred, or ""
      "severity": "high",                 // high | medium | low  (blocking / annoying / cosmetic)
      "type": "bug",                      // bug | ui | ux | copy | perf | idea
      "actual": "点击 Login 后页面无任何反应",
      "expected": "跳转到首页",
      "steps": ["打开登录页", "输入账号密码", "点击 Login"],
      "time": {"start": 12.4, "end": 30.1}, // seconds in the recording where it was discussed
      "quote": "这个登录按钮点了之后没有任何反应…", // what the user said (lightly cleaned)
      "frames": [{"path": "frames/B-001-1.jpg", "t": 14.2, "caption": "点击按钮后无变化"}], // first = primary
      "clip": "clips/B-001.mp4",          // optional
      "code_refs": ["src/pages/Login.tsx:42"],
      "confidence": "high",               // high | low
      "questions": [],                     // what the user must clarify
      "status": "draft",                  // draft | confirmed | deleted
      "merged_from": [],                   // ids merged into this one (review page)
      "exported": {"feishu": "recXXXX"}   // written by exporters; prevents duplicates
    }
  ]
}
```

Extra fields are fine — exporters ignore unknown keys and the review page preserves them.
