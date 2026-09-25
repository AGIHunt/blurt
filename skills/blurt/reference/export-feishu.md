# Export → Feishu / Lark Bitable

`scripts/feishu.py` does the whole export. Backends (auto-picked, override with `--via`):

- **lark-cli** (preferred): official CLI, the user's own identity, no app setup. If missing:
  `npx @larksuite/cli@latest install`, then the user runs `lark-cli config init` and `lark-cli auth login`.
- **openapi**: a self-built app — `FEISHU_APP_ID` / `FEISHU_APP_SECRET` (env or `~/.blurt/config.json` → `feishu`),
  scopes `bitable:app`, `drive:drive` (+ `wiki:wiki:readonly` for wiki-hosted bases), and the app added to the
  base (··· → 更多 → 添加文档应用). Lark international: `FEISHU_DOMAIN=open.larksuite.com`.

```
feishu.py create "项目 X 体验问题"                      # new base + table with default columns → prints URL
feishu.py fields "<table url>"                        # existing columns
feishu.py export <session> "<table url>" --dry-run    # what will be created / mapped
feishu.py export <session> "<table url>" [--map map.json]
```

Table URL: open the table in the browser and copy it — `…/base/<token>?table=<table_id>`.
Remember it in `.blurt/config.json` → `{"export": {"target": "feishu", "url": "…", "map": {…}}}`.

Default columns (zh): 异常描述 · 所属模块 · 预期效果与实际效果 · 复现步骤 · 截图或视频 · 对应 owner · 严重程度 ·
录屏时间点 · 原话 · 疑似代码位置 · 编号. For an existing table, map by meaning, e.g.
`{"title": "问题", "module": "模块", "actual": "现象", "expected": "期望", "steps": "步骤", "frames": "附件", "owner": "负责人"}`.
Several keys may share one column (values are joined with labels). Missing columns are created (text, or
attachment for frames/clip).

Behaviour worth knowing:
- Resumable: each issue stores `exported.feishu` (record id) as soon as it's created and `feishu_done` after its
  attachments; re-running only finishes what's missing — never duplicates.
- Bitable reads are eventually consistent; the script retries reads/uploads for a few seconds. lark-cli v1.0's
  attachment upload can overwrite a cell, so the script collects tokens and writes the full list back.
- Attachments ≤ 20 MB each (clips are small by default).
- Person-type owner columns need Feishu user ids; write owners to a text column, or resolve them
  (`lark-cli contact +search-user --query <name>`) and write `[{"id": "ou_…"}]` yourself.
