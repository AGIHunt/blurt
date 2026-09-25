# /// script
# requires-python = ">=3.10"
# ///
"""Export a session's issues.json to Markdown + CSV (no services needed).

  export_local.py SESSION_DIR [--out DIR] [--lang zh|en]
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, fmt_ts, load_json  # noqa: E402

LABELS = {
    "zh": {"id": "编号", "title": "问题描述", "module": "所属模块", "owner": "负责人", "severity": "严重程度", "type": "类型",
           "actual": "实际效果", "expected": "预期效果", "steps": "复现步骤", "time": "录屏时间点", "quote": "原话",
           "frames": "截图", "clip": "录屏片段", "code_refs": "疑似代码位置", "questions": "待确认"},
    "en": {"id": "ID", "title": "Summary", "module": "Module", "owner": "Owner", "severity": "Severity", "type": "Type",
           "actual": "Actual", "expected": "Expected", "steps": "Steps to reproduce", "time": "Time in recording",
           "quote": "Quote", "frames": "Screenshots", "clip": "Clip", "code_refs": "Suspected code", "questions": "Open questions"},
}


def live_issues(data: dict) -> list[dict]:
    return [i for i in data.get("issues", []) if i.get("status") != "deleted"]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("session")
    p.add_argument("--out")
    p.add_argument("--lang")
    a = p.parse_args()
    session = Path(a.session)
    data = load_json(session / "issues.json") or die("issues.json not found")
    lang = a.lang or ("zh" if str(data.get("language", "")).startswith("zh") else "en")
    L = LABELS[lang]
    out = Path(a.out or session)
    out.mkdir(parents=True, exist_ok=True)
    rel = lambda p: Path(os.path.relpath(session / p, out)).as_posix()  # noqa: E731
    issues = live_issues(data)

    md = [f"# {'问题清单' if lang == 'zh' else 'Issues'} ({len(issues)})", ""]
    for i in issues:
        tm = i.get("time") or {}
        md += [f"## {i.get('id', '')} {i.get('title', '')}", ""]
        meta = [f"**{L[k]}**: {i[k]}" for k in ("module", "owner", "severity", "type") if i.get(k)]
        if tm:
            meta.append(f"**{L['time']}**: {fmt_ts(tm.get('start', 0))}–{fmt_ts(tm.get('end', 0))}")
        md += [" · ".join(meta), ""]
        for k in ("actual", "expected"):
            if i.get(k):
                md += [f"**{L[k]}**: {i[k]}", ""]
        if i.get("steps"):
            md += [f"**{L['steps']}**:", *[f"{n}. {s}" for n, s in enumerate(i["steps"], 1)], ""]
        for f in i.get("frames", []):
            md += [f"![{f.get('caption', '')}]({rel(f['path'])})", ""]
        if i.get("clip"):
            md += [f"[{L['clip']}]({rel(i['clip'])})", ""]
        if i.get("quote"):
            md += [f"> {i['quote']}", ""]
        if i.get("code_refs"):
            md += [f"**{L['code_refs']}**: " + ", ".join(f"`{c}`" for c in i["code_refs"]), ""]
        if i.get("questions"):
            md += [f"**{L['questions']}**: " + "；".join(i["questions"]), ""]
    (out / "issues.md").write_text("\n".join(md), encoding="utf-8")

    cols = ["id", "title", "module", "owner", "severity", "type", "actual", "expected", "steps", "time", "quote",
            "frames", "clip", "code_refs", "questions"]
    with open(out / "issues.csv", "w", newline="", encoding="utf-8-sig") as fh:  # BOM so Excel reads CJK correctly
        w = csv.writer(fh)
        w.writerow([L[c] for c in cols])
        for i in issues:
            tm = i.get("time") or {}
            w.writerow([
                i.get("id", ""), i.get("title", ""), i.get("module", ""), i.get("owner", ""), i.get("severity", ""),
                i.get("type", ""), i.get("actual", ""), i.get("expected", ""),
                "\n".join(f"{n}. {s}" for n, s in enumerate(i.get("steps") or [], 1)),
                f"{fmt_ts(tm.get('start', 0))}-{fmt_ts(tm.get('end', 0))}" if tm else "", i.get("quote", ""),
                "\n".join(rel(f["path"]) for f in i.get("frames", [])), rel(i["clip"]) if i.get("clip") else "",
                "\n".join(i.get("code_refs") or []), "\n".join(i.get("questions") or []),
            ])
    print(json.dumps({"issues": len(issues), "files": [str(out / "issues.md"), str(out / "issues.csv")]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
