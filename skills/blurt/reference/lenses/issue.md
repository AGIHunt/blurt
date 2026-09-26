# lens: issue — something to fix or polish in the product

Use for: bugs, UI/UX rough edges, copy problems, performance, missing behaviour in something that exists.

Fields:
- `module` — the product's own name for the area (nav label, route).
- `owner` — who the user named; else infer (project config, CODEOWNERS, git history of `code_refs`); else "".
- `severity` — `high` (blocking / wrong) · `medium` (annoying) · `low` (cosmetic).
- `type` — `bug` · `ui` · `ux` · `copy` · `perf`.
- `actual` / `expected` — what happens vs what should happen. Don't invent; ask in `questions` when unsure.
- `steps` — list of repro steps.
- `code_refs` — `path:line`s you found by grepping visible text / routes / components (only inside a repo).

Frames: show the problem itself — box the exact spot (see SKILL §4).
Export default: a bug table (Feishu columns 异常描述 / 所属模块 / 预期效果与实际效果 / 复现步骤 / 截图或视频 / 对应 owner).
