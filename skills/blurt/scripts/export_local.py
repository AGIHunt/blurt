# /// script
# requires-python = ">=3.10"
# ///
"""Export a session's items (or a project's) to Markdown + CSV (no services needed). Works for any mix of kinds
(issue / idea / note / task / custom lenses): one Markdown document grouped by kind, one CSV per kind.

  export_local.py SESSION_DIR [--out DIR] [--lang zh|en]          default --out: the session dir
  export_local.py --project P|inbox [--out DIR] [--lang zh|en]    default --out: <store>/exports
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, fmt_ts  # noqa: E402
import items as items_mod  # noqa: E402

LABELS = {
    "zh": {"id": "编号", "title": "标题", "module": "所属模块", "owner": "负责人", "severity": "严重程度", "type": "类型",
           "actual": "实际效果", "expected": "预期效果", "steps": "复现步骤", "time": "录屏时间点", "quote": "原话",
           "frames": "截图", "clip": "录屏片段", "code_refs": "疑似代码位置", "questions": "待确认", "answer": "回答",
           "summary": "概述", "why": "为什么", "inspired_by": "灵感来源", "next_steps": "下一步", "open_questions": "待想清楚",
           "details": "详情", "due": "截止", "tags": "标签", "source": "来源", "kind": "类型"},
    "en": {"id": "ID", "title": "Title", "module": "Module", "owner": "Owner", "severity": "Severity", "type": "Type",
           "actual": "Actual", "expected": "Expected", "steps": "Steps to reproduce", "time": "Time in recording",
           "quote": "Quote", "frames": "Screenshots", "clip": "Clip", "code_refs": "Suspected code",
           "questions": "Open questions", "answer": "Answer", "summary": "Summary", "why": "Why",
           "inspired_by": "Inspired by", "next_steps": "Next steps", "open_questions": "Open questions",
           "details": "Details", "due": "Due", "tags": "Tags", "source": "Source", "kind": "Kind"},
}
KINDS = {"zh": {"issue": "问题", "idea": "想法", "note": "笔记", "task": "待办"},
         "en": {"issue": "Issues", "idea": "Ideas", "note": "Notes", "task": "Tasks"}}
KIND_ORDER = ["issue", "idea", "task", "note"]
COMMON = ["id", "title", "time", "quote", "frames", "clip", "source", "tags", "questions", "answer"]
SKIP = {"kind", "status", "exported", "confidence", "merged_from", "merged_into", "_touched", "_dropped", "_user",
        "schema", "uid", "work", "work_history", "project", "project_by", "project_confidence", "suggested_project",
        "created", "updated", "aliases", "path", "store", "_project", "language", "assignee"}


def text(v) -> str:
    if isinstance(v, list):
        return "\n".join(f"{n}. {x}" if not isinstance(x, dict) else json.dumps(x, ensure_ascii=False) for n, x in enumerate(v, 1))
    if isinstance(v, dict):
        if "start" in v and "end" in v:
            if v["start"] is None:  # shots sessions: no recording time
                return ""
            return f"{fmt_ts(v['start'])}–{fmt_ts(v['end'] if v['end'] is not None else v['start'])}"
        return " · ".join(f"{k}: {x}" for k, x in v.items() if x)
    return "" if v is None else str(v)


def load_doc(session: str | None, project: str | None) -> tuple[dict, Path]:
    """The items to export (items.py doc: every path absolute) and the default output folder."""
    try:
        if session:
            s = Path(session)
            if not s.is_dir():
                die(f"{s}: no such session folder")
            items_mod.prepare(s)
            if not (s / "batch.json").is_file():
                die(f"{s}: no items in this session yet (write items.json first)")
            doc = items_mod.make_doc({"session": str(s.resolve())})
            return doc, s
        if project:
            pid = items_mod.resolve_project(project)
            return items_mod.make_doc({"project": pid}), items_mod.store_for_project(pid).root / "exports"
    except items_mod.ItemsError as e:
        die(str(e))
    finally:
        items_mod.reindex_touched()
    die("pass SESSION_DIR or --project P")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("session", nargs="?")
    p.add_argument("--project")
    p.add_argument("--out")
    p.add_argument("--lang")
    a = p.parse_args()
    data, default_out = load_doc(a.session, a.project)
    lang = a.lang or ("zh" if str(data.get("language") or "").startswith("zh") or (
        not data.get("language") and any(str(i.get("language", "")).startswith("zh") for i in data["items"])) else "en")
    L = LABELS[lang]
    out = Path(a.out or default_out)
    out.mkdir(parents=True, exist_ok=True)
    rel = lambda p: Path(os.path.relpath(p, out)).as_posix()  # noqa: E731  (paths in the doc are absolute)
    items = [i for i in data["items"] if i.get("status") != "deleted"]
    kinds = sorted({i["kind"] for i in items}, key=lambda k: (KIND_ORDER.index(k) if k in KIND_ORDER else 99, k))

    title = data.get("title") or ("录屏整理" if lang == "zh" else "Recording notes")
    md = [f"# {title}", ""]
    if data.get("digest"):
        md += [data["digest"].strip(), ""]
    files = []
    for kind in kinds:
        group = [i for i in items if i["kind"] == kind]
        md += [f"## {KINDS[lang].get(kind, kind)} ({len(group)})", ""]
        for i in group:
            md += [f"### {i.get('id', '')} {i.get('title', '')}", ""]
            meta = [f"**{L[k]}**: {i[k]}" for k in ("module", "owner", "severity", "type", "due") if i.get(k)]
            if i.get("time"):
                meta.append(f"**{L['time']}**: {text(i['time'])}")
            if (i.get("source") or {}).get("url"):
                meta.append(f"**{L['source']}**: {i['source']['url']}")
            if meta:
                md += [" · ".join(meta), ""]
            for k, v in i.items():
                if k in SKIP or k in COMMON or k in ("module", "owner", "severity", "type", "due") or not v:
                    continue
                if isinstance(v, list):
                    md += [f"**{L.get(k, k)}**:", *[f"{n}. {x}" if k in ("steps",) else f"- {x}" for n, x in enumerate(v, 1)], ""]
                else:
                    md += [f"**{L.get(k, k)}**: {text(v)}", ""]
            for f in i.get("frames", []):
                md += [f"![{f.get('caption', '')}]({rel(f['path'])})", ""]
            if i.get("clip"):
                md += [f"[{L['clip']}]({rel(i['clip'])})", ""]
            if i.get("quote"):
                md += [f"> {i['quote']}", ""]
            if i.get("tags"):
                md += [" ".join(f"`#{t}`" for t in i["tags"]), ""]
            if i.get("questions"):
                md += [f"**{L['questions']}**: " + "；".join(i["questions"]) + (f"  → {i['answer']}" if i.get("answer") else ""), ""]

        # one CSV per kind: common columns first, then whatever the lens added
        extra = []
        for i in group:
            for k in i:
                if k not in SKIP and k not in COMMON and k not in extra:
                    extra.append(k)
        cols = ["id", "title", *extra, "time", "quote", "source", "tags", "frames", "clip", "questions", "answer"]
        name = {"issue": "issues", "idea": "ideas", "note": "notes", "task": "tasks"}.get(kind, kind)
        path = out / f"{name}.csv"
        with open(path, "w", newline="", encoding="utf-8-sig") as fh:  # BOM so Excel reads CJK correctly
            w = csv.writer(fh)
            w.writerow([L.get(c, c) for c in cols])
            for i in group:
                row = []
                for c in cols:
                    v = i.get(c)
                    if c == "frames":
                        row.append("\n".join(rel(f["path"]) for f in v or []))
                    elif c == "clip":
                        row.append(rel(v) if v else "")
                    elif c == "tags":
                        row.append(", ".join(v or []))
                    elif c == "source":
                        row.append((v or {}).get("url", "") if isinstance(v, dict) else text(v))
                    else:
                        row.append(text(v))
                w.writerow(row)
        files.append(str(path))
    md_path = out / ("items.md" if len(kinds) != 1 or kinds[0] != "issue" else "issues.md")
    md_path.write_text("\n".join(md), encoding="utf-8")
    print(json.dumps({"items": len(items), "kinds": {k: sum(1 for i in items if i["kind"] == k) for k in kinds},
                      "files": [str(md_path), *files]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
