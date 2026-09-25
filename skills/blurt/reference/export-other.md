# Export → other destinations

Use what the user already has; ask once, then remember in `.blurt/config.json` → `export`.

- **CSV / Markdown**: `export_local.py <session> [--out DIR]` → `issues.md` (images linked relatively) and
  `issues.csv` (UTF-8 BOM, opens in Excel/Numbers/Sheets; importable into most trackers).
- **GitHub Issues** (`gh`): one `gh issue create --title … --body-file … --label …` per issue. The API can't
  upload images; options: (a) commit frames to a branch/`docs/blurt/` and link raw URLs, (b) leave local paths
  and tell the user, (c) ask the user to drag images in. Put `code_refs` as permalinks in the body.
- **Linear / Jira / Notion / Slack / etc.**: use the MCP server or CLI available in this session; map fields by
  meaning; attach the primary frame when the tool supports uploads.
- **"Just fix them"**: the issues + code_refs are a ready work queue. Confirm order/priority with the user.

Always confirm destination + number of items before creating anything remotely, and report links afterwards.
