# Export → files, and every other destination

Blurt writes files; it has no connectors of its own. Anything else goes through the CLI, MCP server or skill the
user's agent (you) already has. Ask once where things go, then remember it in `.blurt/config.json` → `export`.

- **CSV / Markdown**: `export_local.py <session> [--out DIR]` (or `--project <key>`) → `items.md` (images linked
  relatively) and one CSV per kind (UTF-8 BOM, opens in Excel/Numbers/Sheets; importable into most trackers).
- **Hand-off bundle** (a teammate, a chat, anything that takes a file): `export_local.py bundle --items <uid|id> …`
  or `--project <key> [--state …] [--kind …]`, `[-o DIR|FILE.zip] [--title "…"]` (MCP: `bundle_items`). One
  self-contained `.zip`, `<project>-<date>-<n items>.zip`: `summary.md` + `items/*.md` + `frames/` + `clips/`, relative
  paths only (local paths in the text become relative, or just the file name). The JSON it prints has `path`
  (absolute) and `summary` (one paragraph to post with the file); an error is `{"ok": false, "code", "error"}`
  (`io`: the folder can't be written). Group by meaning
  (module, owner, what the user asked for) and make one bundle per group; bundling changes no item's state.
- **Feishu / Lark** (Base, docs, a group chat): with lark-cli or a Feishu MCP if the session has one. Rows: map
  fields by meaning (异常描述 / 所属模块 / 预期效果与实际效果 / 复现步骤 / 截图或视频 / 对应 owner for issues) and upload
  the frames as attachments if the tool can. A chat: send the bundle with its `summary`.
- **GitHub Issues** (`gh`): one `gh issue create --title … --body-file … --label …` per issue. The API can't
  upload images; options: (a) commit frames to a branch/`docs/blurt/` and link raw URLs, (b) attach the bundle to
  a single tracking issue, (c) ask the user to drag images in. Put `code_refs` as permalinks in the body.
- **Linear / Jira / Notion / Google Docs / Slack / email / etc.**: use the MCP server or CLI available in this
  session; map fields by meaning; attach the primary frame when the tool supports uploads, or the bundle.
- **No tool for it here**: say so in one line and offer the bundle or Markdown instead; don't install anything
  unasked.
- **"Just fix them"**: the issues + code_refs are a ready work queue. Confirm order/priority with the user.

Always confirm destination + number of items before creating or sending anything remotely, and report links
afterwards. Never export to external systems in an unattended run.
