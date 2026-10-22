# /// script
# requires-python = ">=3.10"
# ///
"""Hand items to an agent: one Markdown note with everything it needs (contract K6), in $BLURT_HOME/handoff/.
Sessions in Blurt (sessions.py dispatch) and "copy to your own agent" use the same note.

  handoff.py create --items REF … [--lang en|zh] [--to external|session] [--mark]
        → {"ok","id","path","instruction","full","items":[uid]}
        --mark (the app calls it once the user has copied): items → handed_off, to external, handoff H-….
  handoff.py get H-0012          → the same fields

REF = an item uid, its id (BA-12) or its .md path — whatever `items.py get` takes. Images are absolute paths:
Claude Code and Codex read local images directly.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import jobs  # noqa: E402

ITEMS_PY = SCRIPTS / "items.py"
PROJECTS_PY = SCRIPTS / "projects.py"


# ------------------------------------------------------------------ the storage CLIs (P1: items.py, projects.py)
class CliError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def cli(script: Path, *args: str, timeout: float = 60) -> dict:
    """Run one of the storage CLIs; its last stdout line is the JSON answer."""
    try:
        p = subprocess.run([sys.executable, str(script), *map(str, args)], capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise CliError("io", f"{script.name}: {e}") from None
    line = next((ln for ln in reversed(p.stdout.splitlines()) if ln.startswith("{")), "")
    try:
        out = json.loads(line) if line else {}
    except ValueError:
        out = {}
    if p.returncode != 0 or out.get("ok") is False or not out:
        raise CliError(out.get("code") or ("locked" if p.returncode == 3 else "items"),
                       out.get("error") or (p.stderr.strip() or p.stdout.strip())[-500:] or f"{script.name} failed")
    return out


def item(ref: str) -> dict:
    """items.py get REF → the item with "path", "store", "project" (absolute paths)."""
    out = cli(ITEMS_PY, "get", ref)
    it = dict(out.get("item") or {})
    if not it.get("uid"):
        raise CliError("no_item", f"no item {ref}")
    return it


def set_work(uids: list[str], state: str, *, to: str | None = None, agent: str | None = None, job: str | None = None,
             handoff: str | None = None, by: str = "app", note: str | None = None, claim: str | None = None,
             commit: str | None = None, pr: str | None = None) -> dict:
    args = ["work", *uids, "--state", state, "--by", by]
    for flag, v in (("--to", to), ("--agent", agent), ("--job", job), ("--handoff", handoff), ("--note", note),
                    ("--claim", claim), ("--commit", commit), ("--pr", pr)):
        if v:
            args += [flag, v]
    return cli(ITEMS_PY, *args)


def projects() -> dict:
    """projects.py list → {"current", "projects": [Row], "inbox": Row}."""
    return cli(PROJECTS_PY, "list")


def project(pid: str | None) -> dict | None:
    if not pid:
        return None
    reg = projects()
    if pid == "inbox":
        return reg.get("inbox") or {"id": "inbox", "key": "IN", "name": "Unassigned", "path": None}
    return next((p for p in reg.get("projects", []) if p.get("id") == pid), None)


# ------------------------------------------------------------------ language
def ui_lang(lang: str | None = None) -> str:
    """"en" | "zh": --lang, else config "lang" (auto = the system's first preferred language)."""
    v = (lang or "").strip().lower()
    if not v:
        try:
            v = str(json.loads((jobs.home() / "config.json").read_text(encoding="utf-8-sig")).get("lang") or "").lower()
        except (OSError, ValueError, AttributeError):
            v = ""
    if v.startswith("zh"):
        return "zh"
    if v and v != "auto":
        return "en"
    if sys.platform == "darwin":
        try:
            out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True,
                                 timeout=3).stdout
            first = re.search(r'"?([A-Za-z]{2,3}[-_A-Za-z]*)"?', out)
            if first:
                return "zh" if first.group(1).lower().startswith("zh") else "en"
        except (OSError, subprocess.SubprocessError):
            pass
    loc = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or ""
    return "zh" if loc.lower().startswith("zh") else "en"


T = {
    "en": {
        "title_one": "{id} for {project}", "title_many": "{n} items for {project}", "title_bare": "{n} items",
        "folder": "Project folder: {path}",
        "mcp": "When you finish an item, call the blurt MCP tool `mark_fixed` with its uid (state \"fixed\" or "
               "\"wontfix\", plus a short note).",
        "nomcp": "Without the MCP: `{items_cmd} work <uid> --state to_verify --claim fixed --note \"…\"`.",
        "verify": "The user confirms each item before it counts as done.",
        "rule_worktree": "Don't push. You're on your own branch, {branch}, in a separate worktree: commit your work "
                         "there.",
        "rule_direct": "Don't push, and don't commit — you're working directly in the project folder and the user "
                       "reviews the changes first.",
        "rule_external": "Don't push, and don't commit unless the user asks you to.",
        "said": "They said", "summary": "Summary", "why": "Why", "inspired_by": "Inspired by", "actual": "Actual",
        "expected": "Expected", "steps": "Steps", "details": "Details", "next_steps": "Next steps",
        "open_questions": "Open questions", "answer": "Their answer", "code": "Suspected code", "frame": "Frame",
        "module": "module", "project": "project",
        "kind": {"issue": "issue", "idea": "idea", "note": "note", "task": "task"},
        "severity": {},
        "instr_one": "Please handle {id} — details and screenshots are in {path}. When you're done, call mark_fixed if "
                     "the blurt MCP is available.",
        "instr_many": "Please handle these {n} items — details and screenshots are in {path}. When you're done, call "
                      "mark_fixed for each if the blurt MCP is available.",
    },
    "zh": {
        "title_one": "{project} · {id}", "title_many": "{project} 的 {n} 个条目", "title_bare": "{n} 个条目",
        "folder": "项目文件夹：{path}",
        "mcp": "每做完一条，用它的 uid 调用 blurt MCP 工具 `mark_fixed`（state 填 \"fixed\" 或 \"wontfix\"，附一句说明）。",
        "nomcp": "没有 MCP 时：`{items_cmd} work <uid> --state to_verify --claim fixed --note \"…\"`。",
        "verify": "每一条都要用户确认后才算完成。",
        "rule_worktree": "不要推送。你在单独的 worktree 和自己的分支 {branch} 上，改完在这个分支上提交。",
        "rule_direct": "不要推送，也不要提交：你直接在项目文件夹里改，用户会先看改动。",
        "rule_external": "不要推送；除非用户要求，也不要提交。",
        "said": "原话", "summary": "概要", "why": "为什么", "inspired_by": "灵感来源", "actual": "实际效果",
        "expected": "预期效果", "steps": "复现步骤", "details": "详情", "next_steps": "下一步", "open_questions": "待定问题",
        "answer": "用户的回答", "code": "疑似代码位置", "frame": "截图", "module": "模块", "project": "项目",
        "kind": {"issue": "问题", "idea": "想法", "note": "笔记", "task": "任务"},
        "severity": {"critical": "严重", "high": "高", "medium": "中", "low": "低"},
        "instr_one": "请处理 {id}，详情和截图见 {path}。做完后如果有 blurt MCP，调用 mark_fixed。",
        "instr_many": "请处理这 {n} 个条目，详情和截图见 {path}。做完后如果有 blurt MCP，逐条调用 mark_fixed。",
    },
}


def instruction(lang: str, ids: list[str], note: Path) -> str:
    t = T[lang]
    return (t["instr_one"].format(id=ids[0], path=note) if len(ids) == 1
            else t["instr_many"].format(n=len(ids), path=note))


# ------------------------------------------------------------------ the note
def _mmss(t) -> str | None:
    try:
        s = max(0, int(round(float(t))))
    except (TypeError, ValueError):
        return None
    return f"{s // 60}:{s % 60:02d}"


def _link(p: Path) -> str:
    s = str(p)
    return f"<{s}>" if re.search(r"[\s()<>]", s) else s


def _text(v) -> str:
    if v is None:
        return ""
    if isinstance(v, list):
        return "\n".join(str(x) for x in v if x not in (None, ""))
    return str(v).strip()


def frames_of(it: dict) -> list[tuple[Path, dict]]:
    """The item's frames that exist, as absolute paths (front-matter paths are relative to the store)."""
    store = Path(it["store"]) if it.get("store") else None
    out = []
    for f in it.get("frames") or []:
        if not isinstance(f, dict) or not f.get("path"):
            continue
        p = Path(f["path"]).expanduser()
        if not p.is_absolute():
            if store is None:
                continue
            p = store / p
        if p.is_file():
            out.append((p.resolve(), f))
    return out


def render_item(n: int, it: dict, lang: str, show_project: bool = False) -> str:
    t = T[lang]
    kind = it.get("kind") or "item"
    meta = [f"uid {it['uid']}", t["kind"].get(kind, kind)]
    if it.get("severity"):
        meta.append(t["severity"].get(str(it["severity"]).lower(), str(it["severity"])))
    if it.get("module"):
        meta.append(f"{t['module']} {it['module']}")
    if show_project and isinstance(it.get("_project"), dict) and it["_project"].get("name"):
        meta.append(f"{t['project']} {it['_project']['name']}")
    title = _text(it.get("title")) or _text(it.get("summary"))[:80] or it.get("id") or it["uid"]
    head = f"## {n}. {it.get('id') or it['uid']} · {title}"
    parts = [head, " · ".join(meta)]
    quote = _text(it.get("quote"))
    if quote:
        parts.append(f"**{t['said']}**\n" + "\n".join(f"> {ln}" if ln else ">" for ln in quote.splitlines()))
    for key in ("summary", "why", "inspired_by", "actual", "expected"):
        v = _text(it.get(key))
        if v:
            parts.append(f"**{t[key]}**\n{v}")
    steps = [s for s in (it.get("steps") or []) if _text(s)] if isinstance(it.get("steps"), list) else []
    if steps:
        parts.append(f"**{t['steps']}**\n" + "\n".join(f"{i}. {_text(s)}" for i, s in enumerate(steps, 1)))
    if _text(it.get("details")):
        parts.append(f"**{t['details']}**\n{_text(it['details'])}")
    for key in ("next_steps", "open_questions"):
        vals = [x for x in (it.get(key) or []) if _text(x)] if isinstance(it.get(key), list) else []
        if vals:
            parts.append(f"**{t[key]}**\n" + "\n".join(f"- {_text(x)}" for x in vals))
    if _text(it.get("answer")):
        parts.append(f"**{t['answer']}**\n{_text(it['answer'])}")
    refs = [r for r in (it.get("code_refs") or []) if _text(r)] if isinstance(it.get("code_refs"), list) else []
    if refs:
        parts.append(f"**{t['code']}** " + ", ".join(f"`{_text(r)}`" for r in refs))
    for i, (p, f) in enumerate(frames_of(it), 1):
        label = f"{t['frame']} {i}"
        if _mmss(f.get("t")) is not None:
            label += f" · {_mmss(f.get('t'))}"
        cap = _text(f.get("caption")).replace("]", ")").replace("[", "(").replace("\n", " ")
        if cap:
            label += f" — {cap}"
        parts.append(f"![{label}]({_link(p)})")
    return "\n\n".join(parts)


def render(hid: str, created: str, items: list[dict], proj: dict | None, lang: str, to: str,
           branch: str | None = None, worktree: bool | None = None) -> str:
    t = T[lang]
    same = proj is not None
    pname = (proj or {}).get("name") or ""
    if len(items) == 1 and same:
        title = t["title_one"].format(id=items[0].get("id") or items[0]["uid"], project=pname)
    elif same:
        title = t["title_many"].format(n=len(items), project=pname)
    else:
        title = t["title_bare"].format(n=len(items))
    fm_project = {"id": proj.get("id"), "name": pname, "path": proj.get("path")} if same else None
    fm = ["---", f"handoff: {hid}", f"created: {json.dumps(created)}",
          f"project: {json.dumps(fm_project, ensure_ascii=False)}",
          f"items: {json.dumps([i['uid'] for i in items])}", f"to: {to}", f"lang: {lang}"]
    if branch:
        fm.append(f"branch: {json.dumps(branch)}")
    fm.append("---")
    rule = (t["rule_worktree"].format(branch=branch) if to == "session" and worktree
            else t["rule_direct"] if to == "session" else t["rule_external"])
    intro = []
    if same and proj.get("id") != "inbox" and proj.get("path"):
        intro.append(t["folder"].format(path=proj["path"]))
    intro += [t["mcp"], t["nomcp"].format(items_cmd=items_command()), t["verify"], rule]
    body = [f"# {title}", "\n".join(intro)] + [render_item(n, it, lang, show_project=not same)
                                                for n, it in enumerate(items, 1)]
    return "\n".join(fm) + "\n" + "\n\n".join(body) + "\n"


def items_command() -> str:
    """How an agent runs items.py without the MCP server: this interpreter (outside any venv), not `uv run` — a
    sandboxed agent (Codex) has to ask before it may touch uv's cache."""
    import agents
    return f"{agents._q(agents.hook_python())} {agents._q(str(ITEMS_PY))}"


def handoff_dir() -> Path:
    d = jobs.home() / "handoff"
    d.mkdir(parents=True, exist_ok=True)
    return d


def next_id() -> str:
    d = handoff_dir()
    with jobs.file_lock(d / ".seq.lock"):
        try:
            n = int((d / ".seq").read_text(encoding="utf-8").strip() or 0)
        except (OSError, ValueError):
            n = 0
        n += 1
        while (d / f"H-{n:04d}.md").exists():  # a lost .seq never reuses an id
            n += 1
        tmp = d / f".seq.{os.getpid()}.tmp"
        tmp.write_text(str(n), encoding="utf-8")
        os.replace(tmp, d / ".seq")
    return f"H-{n:04d}"


def strip_front_matter(text: str) -> str:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[end + 5:].lstrip("\n")
    return text


def front_matter(text: str) -> dict:
    out = {}
    if not text.startswith("---\n"):
        return out
    end = text.find("\n---\n", 4)
    for line in text[4:end if end != -1 else 0].splitlines():
        k, sep, v = line.partition(":")
        if not sep:
            continue
        v = v.strip()
        try:
            out[k.strip()] = json.loads(v)
        except ValueError:
            out[k.strip()] = v
    return out


def create(refs: list[str], lang: str | None = None, to: str = "external", mark: bool = False,
           branch: str | None = None, worktree: bool | None = None, items: list[dict] | None = None) -> dict:
    """Write a note for these items. `items` = already-fetched items (sessions.py), else each REF is looked up."""
    lang = ui_lang(lang)
    its = items if items is not None else [item(r) for r in refs]
    if not its:
        raise CliError("bad_args", "no items")
    seen, uniq = set(), []
    for it in its:
        if it["uid"] not in seen:
            seen.add(it["uid"])
            uniq.append(it)
    pids = {it.get("project") for it in uniq}
    proj = project(next(iter(pids))) if len(pids) == 1 else None
    if len(pids) != 1:
        reg = projects()
        rows = {p["id"]: p for p in reg.get("projects", [])}
        if reg.get("inbox"):
            rows["inbox"] = reg["inbox"]
        for it in uniq:
            it["_project"] = rows.get(it.get("project")) or {"name": it.get("project")}
    hid = next_id()
    note = handoff_dir() / f"{hid}.md"
    text = render(hid, jobs.now_iso(), uniq, proj, lang, to, branch=branch, worktree=worktree)
    tmp = note.with_name(f".{note.name}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, note)
    if mark:
        mark_external(hid, [it["uid"] for it in uniq])
    return describe(hid, text)


def mark_external(hid: str, uids: list[str]) -> None:
    set_work(uids, "handed_off", to="external", handoff=hid, by="user")


def describe(hid: str, text: str | None = None) -> dict:
    note = handoff_dir() / f"{hid}.md"
    if text is None:
        try:
            text = note.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise CliError("no_handoff", f"no hand-off note {hid}") from None
    fm = front_matter(text)
    uids = fm.get("items") or []
    body = strip_front_matter(text)
    ids = re.findall(r"^## \d+\. (\S+) · ", body, re.M) or uids
    lang = fm.get("lang") if fm.get("lang") in T else "en"
    return {"ok": True, "id": hid, "path": str(note), "instruction": instruction(lang, ids, note), "full": body,
            "items": uids}


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def fail(code: str, msg: str, exit_code: int = 1):
    emit({"ok": False, "error": msg, "code": code})
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(exit_code)


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        fail("bad_args", message)


def main(argv: list[str] | None = None) -> None:
    p = _Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=_Parser)
    s = sub.add_parser("create")
    s.add_argument("--items", nargs="+", required=True, metavar="REF")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    s.add_argument("--to", choices=["external", "session"], default="external")
    s.add_argument("--mark", action="store_true")
    s = sub.add_parser("get")
    s.add_argument("id")
    a = p.parse_args(argv)
    try:
        if a.cmd == "create":
            if a.mark and a.to != "external":
                fail("bad_args", "--mark is for --to external")
            emit(create(a.items, a.lang, a.to, a.mark))
        else:
            if not re.fullmatch(r"H-\d{4,}", a.id):
                fail("bad_args", "a hand-off id looks like H-0012")
            emit(describe(a.id))
    except CliError as e:
        fail(e.code, str(e), 3 if e.code == "locked" else 1)
    except jobs.JobError as e:
        fail(e.code, str(e), 3 if e.code == "locked" else 1)


if __name__ == "__main__":
    main()
