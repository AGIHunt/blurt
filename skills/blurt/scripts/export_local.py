# /// script
# requires-python = ">=3.10"
# ///
"""Export items to files, no services needed. Works for any mix of kinds (issue / idea / note / task / custom lenses).

Markdown + CSV: one Markdown document grouped by kind, one CSV per kind, images linked relatively.
  export_local.py SESSION_DIR [--out DIR] [--lang zh|en]          default --out: the session dir
  export_local.py --project P|inbox [--out DIR] [--lang zh|en]    default --out: <store>/exports

Hand-off bundle: one self-contained .zip to pass to a teammate or post wherever the team talks: summary.md (title,
counts by kind and state, one section per item with its state, quote, steps, suspected code and frames inline),
items/*.md (every field of each item) and frames/ + clips/. Only relative paths inside, so it opens on any machine.
Named "<project>-<date>-<n items>.zip". No item changes state. Grouping (by module, owner, …) is the caller's call:
one bundle per group.
  export_local.py bundle (--items REF … | --project P|inbox [--state S …] [--kind K …]) [-o DIR|FILE.zip]
                  [--title TEXT] [--lang zh|en]                   default -o: the project's <store>/exports
  → {"ok", "path", "name", "items", "kinds", "states", "summary", "missing", …}; "summary" is one paragraph to paste
  next to the file. REF = a uid, an id (BA-12) or an item's .md path. --state default: all but discarded.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import zipfile
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import STATES, die, fmt_ts, state_of  # noqa: E402
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
SKIP = {"kind", "state", "restore_to", "status", "exported", "confidence", "merged_from", "merged_into", "_touched", "_dropped", "_user",
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
    if sys.argv[1:2] == ["bundle"]:
        return bundle_main(sys.argv[2:])
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
    items = [i for i in data["items"] if state_of(i) != "discarded"]
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


# ------------------------------------------------------------------ hand-off bundle
# Every word the bundle writes, per language: adding a language is adding a table here (and to LABELS / KINDS).
B = {
    "en": {"title": "{project} hand-off", "title_bare": "Hand-off", "n_items": "{n} items", "n_item": "{n} item",
           "file_n": "{n}-items", "file_1": "1-item", "by_kind": "By kind", "by_state": "By state",
           "state": "State", "project": "Project", "full": "All fields", "frame": "Frame", "clip": "Clip",
           "read": "Each item also has its own file in items/ with every field; screenshots are in frames/, clips in "
                   "clips/.",
           "made": "Made with Blurt on {date}.",
           "para": "{title}: {n} ({kinds}; {states}). Open summary.md in the zip: each item with its state, what was "
                   "said, the steps, suspected code and screenshots. {list}",
           "list": "Items: {items}.", "more": "and {k} more", "sep": "; ", "comma": ", ", "colon": "**: ",
           "missing": "Not included, the file is gone: {files}",
           # counts: "6 issues", "1 idea"; "5 new", "2 to do" — (one, many) per kind, one form per state
           "kind_n": {"issue": ("{n} issue", "{n} issues"), "idea": ("{n} idea", "{n} ideas"),
                      "note": ("{n} note", "{n} notes"), "task": ("{n} task", "{n} tasks")},
           "kind_other": ("{n} {kind}", "{n} {kind}"),
           "state_n": "{n} {state}",
           "states_low": {"new": "new", "todo": "to do", "handed_off": "handed off", "in_progress": "in progress",
                          "to_verify": "to verify", "done": "done", "wontfix": "won't do", "discarded": "discarded"},
           "kind": {"issue": "Issue", "idea": "Idea", "note": "Note", "task": "Task"},
           "states": {"new": "New", "todo": "To do", "handed_off": "Handed off", "in_progress": "In progress",
                      "to_verify": "To verify", "done": "Done", "wontfix": "Won't do", "discarded": "Discarded"}},
    "zh": {"title": "{project} 交接包", "title_bare": "交接包", "n_items": "{n} 条", "n_item": "{n} 条",
           "file_n": "{n}条", "file_1": "1条", "by_kind": "按类型", "by_state": "按状态",
           "state": "状态", "project": "项目", "full": "全部字段", "frame": "截图", "clip": "录屏片段",
           "read": "items/ 里每一条还有单独的文件，字段齐全；截图在 frames/，录屏片段在 clips/。",
           "made": "{date} 用口喷鸡整理。",
           "para": "{title}：{n}（{kinds}；{states}）。解压后打开 summary.md：每一条都有状态、原话、复现步骤、疑似代码位置和截图。"
                   "{list}",
           "list": "包括：{items}。", "more": "等 {k} 条", "sep": "；", "comma": "，", "colon": "**：",
           "missing": "没有打包进来，文件已经不在了：{files}",
           "kind_n": {"issue": ("{n} 个问题", "{n} 个问题"), "idea": ("{n} 个想法", "{n} 个想法"),
                      "note": ("{n} 条笔记", "{n} 条笔记"), "task": ("{n} 条待办", "{n} 条待办")},
           "kind_other": ("{n} 条{kind}", "{n} 条{kind}"),
           "state_n": "{state} {n} 条",
           "states_low": {"new": "新", "todo": "要做", "handed_off": "已交给 Agent", "in_progress": "进行中",
                          "to_verify": "待验证", "done": "完成", "wontfix": "不做", "discarded": "已丢弃"},
           "kind": {"issue": "问题", "idea": "想法", "note": "笔记", "task": "待办"},
           "states": {"new": "新", "todo": "要做", "handed_off": "已交给 Agent", "in_progress": "进行中",
                      "to_verify": "待验证", "done": "完成", "wontfix": "不做", "discarded": "已丢弃"}},
}
# what items/*.md shows generically: not bookkeeping, not what has its own place, nothing that holds a local path
BUNDLE_SKIP = SKIP | {"id", "title", "kind", "frames", "clip", "quote", "time", "source", "tags", "questions", "answer",
                      "fix", "fix_history", "source_session", "project_reason", "handoff", "note", "steps",
                      "code_refs", "summary", "actual", "expected", "module", "owner", "severity", "type", "due"}
LEAD = ("summary", "actual", "expected")
# absolute paths left after the known roots are made relative: under these top folders it is this machine's file
# (a web route like "/api/v1/users" is not); keep only its last part
LOCAL_PATH = re.compile(r"(?<![\w:/.~-])/(?:Users|home|private|tmp|var|Volumes|mnt|media|root|opt|srv)"
                        r"(?:/[^\s/'\"`<>()\[\]|]+){2,}")
WIN_PATH = re.compile(r"(?<![\w])[A-Za-z]:\\(?:[^\s\\'\"`<>()\[\]|]+\\)+([^\s\\'\"`<>()\[\]|]+)")
UNSAFE = re.compile(r"[^\w.-]+")


class BundleError(Exception):
    def __init__(self, msg: str, code: str = "bad_args"):
        super().__init__(msg)
        self.code = code


def slug(s: str, fallback: str = "blurt", lower: bool = True) -> str:
    """A file-name-safe form of a name: letters (any script), digits, '.', '_' kept, the rest '-' (a project's name
    also ASCII-lowercased; an id keeps its case)."""
    out = re.sub(r"-{2,}", "-", UNSAFE.sub("-", (s or "").strip())).strip("-._")
    return "".join(c.lower() if lower and c.isascii() else c for c in out)[:60].strip("-._") or fallback


def bundle_name(project: str | None, n: int, lang: str, day: date | None = None) -> str:
    """"<project>-<date>-<n items>.zip". The Mac app suggests the same name in its Save panel (BlurtCore
    HandoffBundle.fileName): keep the two in step."""
    t = B[lang if lang in B else "en"]
    count = t["file_1"] if n == 1 else t["file_n"].format(n=n)
    return f"{slug(project or '')}-{(day or date.today()).isoformat()}-{count}.zip"


def _natural(i: dict):
    m = re.fullmatch(r"([A-Za-z0-9]+)-(\d+)", str(i.get("id") or ""))
    return (m.group(1), int(m.group(2))) if m else (str(i.get("id") or ""), 0)


def collect(refs: list[str] | None, project: str | None, states: list[str] | None, kinds: list[str] | None
            ) -> tuple[list[dict], Path]:
    """The items to bundle (every path absolute) and the default output folder. REFs keep their order (a REF given
    twice counts once); a project's items come by kind, then id. states None = all but discarded."""
    items_mod._NAMES = None
    bad = [s for s in states or [] if s not in STATES]
    if bad:
        raise BundleError(f"unknown state {bad[0]!r} (one of {', '.join(STATES)})")
    try:
        if refs:
            out, seen = [], set()
            for r in refs:
                it = items_mod.get(None, r)["item"]
                if it["uid"] not in seen:
                    seen.add(it["uid"])
                    out.append(it)
            pids = {i.get("project") for i in out}
            home = items_mod.store_for_project(next(iter(pids))) if len(pids) == 1 else items_mod.st.inbox_store()
            return out, home.root / "exports"
        if project:
            pid = items_mod.resolve_project(project)
            rows = items_mod.list_items(None, pid, kinds or (), states or None)["items"]
            rows.sort(key=lambda i: (KIND_ORDER.index(i["kind"]) if i.get("kind") in KIND_ORDER else 99,
                                     str(i.get("kind")), _natural(i)))
            return rows, items_mod.store_for_project(pid).root / "exports"
    except items_mod.ItemsError as e:
        raise BundleError(str(e), e.code) from None
    raise BundleError("pass --items REF … or --project P")


def _lang(items: list[dict], lang: str | None) -> str:
    """--lang, else the language most items were spoken in, else the UI language (config "lang", else the system's)."""
    if lang:
        return "zh" if lang.lower().startswith("zh") else "en"
    spoken = [str(i.get("language")) for i in items if i.get("language")]
    if spoken:
        return "zh" if 2 * sum(s.startswith("zh") for s in spoken) >= len(spoken) else "en"
    import handoff  # noqa: PLC0415
    return handoff.ui_lang()


def _counts(items: list[dict], key, order: list[str]) -> list[tuple[str, int]]:
    seen: dict[str, int] = {}
    for i in items:
        seen[key(i)] = seen.get(key(i), 0) + 1
    return [(k, seen[k]) for k in sorted(seen, key=lambda k: (order.index(k) if k in order else 99, k))]


class _Scrub:
    """This machine's paths, made to mean something elsewhere. Applied to every text the bundle writes, so no
    absolute local path leaves in it: a path inside a project's folder → relative to it (code refs); the folder on its
    own → its name; the home folder → ~; any other path on this machine (/Volumes/…, /tmp/…, C:\\…) → its last
    part (file.ts:3)."""

    def __init__(self, items: list[dict]):
        names = items_mod._project_names()
        roots = {str(Path(r)) for i in items for r in ((names.get(i.get("project")) or {}).get("path"), i.get("store"))
                 if r}
        self.roots = [(r, re.compile(re.escape(r) + r"(?![\w.-])")) for r in sorted(roots, key=len, reverse=True)
                      if len(r) > 1]
        self.home = str(Path.home())

    def __call__(self, s: str) -> str:
        for r, bare in self.roots:
            s = bare.sub(lambda _m, r=r: Path(r).name, s.replace(r + os.sep, ""))
        if len(self.home) > 1:
            s = s.replace(self.home + os.sep, "~" + os.sep)
        s = LOCAL_PATH.sub(lambda m: m.group(0).rsplit("/", 1)[1], s)
        return WIN_PATH.sub(lambda m: m.group(1), s)


def _md(v) -> str:
    if isinstance(v, list):
        return "\n".join(f"- {_md(x)}" for x in v if x not in (None, ""))
    if isinstance(v, dict):
        return " · ".join(f"{k}: {x}" for k, x in v.items() if x not in (None, "", [], {}))
    return "" if v is None else str(v).strip()


def _quote(q: str) -> list[str]:
    return ["\n".join(f"> {ln}" if ln else ">" for ln in q.strip().splitlines()), ""]


def _head(i: dict, t: dict, L: dict, show_project: bool) -> str:
    st_ = state_of(i)
    meta = [f"**{t['state']}**: {t['states'].get(st_, st_)}",
            f"**{L['kind']}**: {t['kind'].get(i.get('kind'), i.get('kind') or '')}"]
    meta += [f"**{L[k]}**: {_md(i[k])}" for k in ("module", "owner", "severity", "type", "due") if _md(i.get(k))]
    if show_project and (i.get("_project") or {}).get("name"):
        meta.append(f"**{t['project']}**: {i['_project']['name']}")  # bundle() names the inbox in its language
    if i.get("time") and text(i["time"]):
        meta.append(f"**{L['time']}**: {text(i['time'])}")
    url = i["source"].get("url") if isinstance(i.get("source"), dict) else None
    if isinstance(url, str) and url.startswith(("http://", "https://")):
        meta.append(f"**{L['source']}**: {url}")
    return " · ".join(meta)


def _lead(i: dict, L: dict) -> list[str]:
    out = _quote(str(i["quote"])) if _md(i.get("quote")) else []
    for k in LEAD:
        if _md(i.get(k)):
            out += [f"**{L[k]}**: {_md(i[k])}", ""]
    steps = [s for s in i["steps"] if _md(s)] if isinstance(i.get("steps"), list) else []
    if steps:
        out += [f"**{L['steps']}**", *[f"{n}. {_md(s)}" for n, s in enumerate(steps, 1)], ""]
    return out


def _refs(i: dict, L: dict) -> list[str]:
    refs = [r for r in i["code_refs"] if _md(r)] if isinstance(i.get("code_refs"), list) else []
    return [f"**{L['code_refs']}**: " + ", ".join(f"`{_md(r)}`" for r in refs), ""] if refs else []


def _media(m: dict, t: dict, up: str) -> list[str]:
    out = [f"_{t['missing'].format(files=t['comma'].join(m['missing']))}_", ""] if m.get("missing") else []
    for n, (rel, f) in enumerate(m.get("frames", []), 1):
        cap = str(f.get("caption") or "").replace("[", "(").replace("]", ")").replace("\n", " ").strip()
        out += [f"![{t['frame']} {n}{' — ' + cap if cap else ''}](<{up}{rel}>)", ""]
    if m.get("clip"):
        out += [f"[{t['clip']}](<{up}{m['clip']}>)", ""]
    return out


def _title(i: dict) -> str:
    return " · ".join(x for x in (str(i.get("id") or i["uid"]), _md(i.get("title"))) if x)


def _own(i: dict, L: dict) -> list[list[str]]:
    """The lens's own fields, in the item's order: why, inspired_by, next_steps, details, a custom lens's …"""
    return [[f"**{L.get(k, k)}**", _md(v), ""] if isinstance(v, list) else [f"**{L.get(k, k)}**: {_md(v)}", ""]
            for k, v in i.items() if k not in BUNDLE_SKIP and not k.startswith("_") and _md(v)]


def summary_section(i: dict, t: dict, L: dict, m: dict, file: str, show_project: bool) -> list[str]:
    # an item with none of summary / actual / expected (an idea with only a "why", a task's "details") still says
    # what it is about: its first own field
    own = [] if any(_md(i.get(k)) for k in LEAD) else (_own(i, L) or [[]])[0]
    return ([f"## {_title(i)}", "", _head(i, t, L, show_project), ""] + _lead(i, L) + own + _refs(i, L)
            + _media(m, t, "") + [f"[{t['full']}](<items/{file}>)", ""])


def item_file(i: dict, t: dict, L: dict, m: dict) -> str:
    out = [f"# {_title(i)}", "", _head(i, t, L, True), ""] + _lead(i, L)
    for lines in _own(i, L):
        out += lines
    out += _refs(i, L)
    if i.get("tags"):
        out += [" ".join(f"`#{x}`" for x in i["tags"]), ""]
    if i.get("questions"):
        out += [f"**{L['questions']}**", *[f"- {q}" for q in i["questions"]], ""]
        if _md(i.get("answer")):
            out += [f"**{L['answer']}**: {_md(i['answer'])}", ""]
    return "\n".join(out + _media(m, t, "../") + [f"uid `{i['uid']}`", ""])


def _target(out: Path, name: str) -> Path:
    """`out` a folder: the file in it, "~2" … when the name is taken (never overwrite an earlier bundle); a path
    ending in .zip: that file (a Save panel already asked about replacing it)."""
    if out.suffix.lower() == ".zip":
        return out
    path, n = out / name, 2
    while path.exists():
        path = out / f"{name[:-4]}~{n}.zip"
        n += 1
    return path


def bundle(items: list[dict], out: Path, *, title: str | None = None, lang: str | None = None,
           day: date | None = None) -> dict:
    """Write the zip; `out` = a folder (the file gets bundle_name) or a path ending in .zip."""
    if not items:
        raise BundleError("no items to bundle", "no_items")
    lang, day = _lang(items, lang), day or date.today()
    t, L = B[lang], LABELS[lang]
    import projects  # noqa: PLC0415
    for i in items:  # "Unassigned" / "未归类" follows the UI language; the bundle says it in its own
        if i.get("project") == items_mod.st.INBOX and isinstance(i.get("_project"), dict):
            i["_project"] = {**i["_project"], "name": projects.INBOX_NAMES.get(lang, projects.INBOX_NAMES["en"])}
    pids = {i.get("project") for i in items}
    pname = (items[0].get("_project") or {}).get("name") if len(pids) == 1 else None
    title = (title or "").strip() or (t["title"].format(project=pname) if pname else t["title_bare"])
    count = t["n_item" if len(items) == 1 else "n_items"].format(n=len(items))
    path = _target(Path(out).expanduser().resolve(), bundle_name(pname, len(items), lang, day))
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise BundleError(f"can't write {path}: {e.strerror or e}", "io") from None
    root, paths = path.stem, _Scrub(items)

    def scrub(s: str) -> str:  # no local paths; and "**状态**：" in Chinese, with its own colon
        s = paths(s)
        return s.replace("**: ", t["colon"]) if t["colon"] != "**: " else s

    # frames/<ID>-<n>.<ext>, clips/<ID>.<ext>, items/<the item's file name>; a file that is gone is listed, not fatal
    media: dict[str, dict] = {}
    copies: list[tuple[Path, str, Path]] = []
    missing: list[str] = []
    used: set[str] = set()

    def unique(name: str) -> str:
        base, ext = os.path.splitext(name)
        cand, k = name, 2
        while cand in used:
            cand, k = f"{base}-{k}{ext}", k + 1
        used.add(cand)
        return cand

    files: dict[str, str] = {}

    def media_file(i: dict, ref: str) -> Path:
        try:
            return items_mod.media_path(Path(i["store"]), ref)
        except items_mod.ItemsError as e:
            raise BundleError(str(e), e.code) from None

    for i in items:
        ident = slug(str(i.get("id") or ""), i["uid"], lower=False)
        m = media.setdefault(i["uid"], {"frames": [], "missing": []})
        for n, f in enumerate([f for f in i.get("frames") or [] if isinstance(f, dict) and f.get("path")], 1):
            src = media_file(i, f["path"])
            if not src.is_file():
                missing.append(f"{ident}: {src.name}")
                cap = str(f.get("caption") or "").replace("\n", " ").strip()
                m["missing"].append(f"{t['frame']} {n}{' — ' + cap if cap else ''}")
                continue
            m["frames"].append(("frames/" + unique(f"{ident}-{n}{src.suffix.lower() or '.png'}"), f))
            copies.append((src, m["frames"][-1][0], Path(i["store"])))
        if isinstance(i.get("clip"), str) and i["clip"]:
            src = media_file(i, i["clip"])
            if src.is_file():
                m["clip"] = "clips/" + unique(f"{ident}{src.suffix.lower() or '.mp4'}")
                copies.append((src, m["clip"], Path(i["store"])))
            else:
                missing.append(f"{ident}: {src.name}")
                m["missing"].append(t["clip"])
        files[i["uid"]] = unique("items/" + slug(Path(i.get("path") or "").stem, ident, lower=False) + ".md")[len("items/"):]

    kinds = _counts(items, lambda i: i.get("kind") or "", KIND_ORDER)
    states = _counts(items, state_of, list(STATES))
    kinds_t = [t["kind_n"].get(k, t["kind_other"])[n != 1].format(n=n, kind=k) for k, n in kinds]
    states_t = [t["state_n"].format(n=n, state=t["states_low"].get(k, k)) for k, n in states]
    md = [f"# {title}", "", " · ".join([count, *([pname] if pname else []), day.isoformat()]), "",
          f"**{t['by_kind']}**: " + " · ".join(kinds_t), "",
          f"**{t['by_state']}**: " + " · ".join(states_t), "", t["read"], ""]
    for i in items:
        md += summary_section(i, t, L, media[i["uid"]], files[i["uid"]], len(pids) > 1)
    md += [f"_{t['made'].format(date=day.isoformat())}_", ""]

    tmp = path.with_name(f".{path.name}.tmp")
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr(f"{root}/summary.md", scrub("\n".join(md)))
            for i in items:
                z.writestr(f"{root}/items/{files[i['uid']]}", scrub(item_file(i, t, L, media[i["uid"]])))
            for src, rel, store in copies:  # pictures and video are compressed already
                try:
                    src = media_file({"store": str(store)}, str(src))
                    z.write(src, f"{root}/{rel}", compress_type=zipfile.ZIP_STORED)
                except OSError as e:
                    raise BundleError(f"can't read {src.name}: {e.strerror or e}", "unreadable") from None
        os.replace(tmp, path)
    except OSError as e:  # a folder we may not write to, a file where the folder should be, a full disk
        raise BundleError(f"can't write {path}: {e.strerror or e}", "io") from None
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass

    shown = [_title(i).replace(" · ", " ", 1) for i in items[:5]]
    if len(items) > 5:
        shown.append(t["more"].format(k=len(items) - 5))
    para = t["para"].format(title=title, n=count, kinds=t["comma"].join(kinds_t), states=t["comma"].join(states_t),
                            list=t["list"].format(items=t["sep"].join(shown)))
    return {"ok": True, "path": str(path), "name": path.name, "title": title, "items": len(items),
            "kinds": dict(kinds), "states": dict(states), "uids": [i["uid"] for i in items], "files": len(copies),
            "bytes": path.stat().st_size, "summary": scrub(para), "missing": missing}


def bundle_items(refs: list[str] | None = None, project: str | None = None, states: list[str] | None = None,
                 kinds: list[str] | None = None, out: str | None = None, title: str | None = None,
                 lang: str | None = None) -> dict:
    """What the CLI and the MCP tool bundle_items call: collect, then bundle."""
    if refs and project:
        raise BundleError("pass --items or --project, not both")
    items, default_out = collect(refs, project, states, kinds)
    if not items:
        raise BundleError("no items match", "no_items")
    return bundle(items, Path(out) if out else default_out, title=title, lang=lang)


def bundle_main(argv: list[str]) -> None:
    p = argparse.ArgumentParser(prog="export_local.py bundle", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--items", nargs="+", metavar="REF")
    p.add_argument("--project")
    p.add_argument("--state", action="append", nargs="+", metavar="S")
    p.add_argument("--kind", action="append", nargs="+", metavar="K")
    p.add_argument("-o", "--out")
    p.add_argument("--title")
    p.add_argument("--lang")
    a = p.parse_args(argv)
    flat = lambda v: [x for group in v or [] for x in group] or None  # noqa: E731
    try:
        out = bundle_items(a.items, a.project, flat(a.state), flat(a.kind), a.out, a.title, a.lang)
    except BundleError as e:
        print(json.dumps({"ok": False, "error": str(e), "code": e.code}, ensure_ascii=False), flush=True)
        print(f"ERROR: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
    print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
