# /// script
# requires-python = ">=3.10"
# ///
"""Projects = folders the user opened in Blurt (contract K2). The registry is $BLURT_HOME/projects.json; this script
is its only writer (lock $BLURT_HOME/.projects.lock, atomic replace). The apps read the file and watch it.

  projects.py list                         → {"ok","current","projects":[Row],"inbox":Row}
  projects.py add PATH [--name N] [--key K] [--description D]   open a folder: register it, create its store
                                           (<PATH>/.blurt, kept out of git via .git/info/exclude) → {"ok","project","created"}
                                           A folder with a store whose project moved away (renamed on disk) or was
                                           removed is that project again → + "relocated": the old path
  projects.py remove ID                    unregister only — never deletes .blurt → {"ok"}
  projects.py set ID --json '{patch}'      name description default_agent worktree worktree_root modules hints key
                                           pinned → {"ok","project"}   (key: only while the project has no items)
  projects.py use ID|auto                  the current project (captures go there) → {"ok","current"}
  projects.py current                      → {"ok","current","current_by","project":Row|null}
                                           current_by: "user" (chosen in Blurt) | "migrate" (carried over from
                                           v0.6's record.workspace — the app asks once whether to keep it) | null
  projects.py resolve PATH                 the (deepest) project PATH is in → {"ok","project":Row|null}
  projects.py route (--items REF … | --session DIR) [--apply] [--threshold X] [--agent ID] [--no-llm]
             --session: that batch's inbox items with no suggestion yet (the app, after an organizing run)
                                           suggest a project per item: rules first, then a small model →
                                           {"ok","suggestions":[{uid, project, confidence, reason, by}],"moved":[uid]}
  projects.py migrate                      v0.6 config record.workspace(s) → projects → {"ok","added","current"}

Row = the registry entry + {exists, git, store, open_items} (+ unassigned for the inbox). The inbox is not in the
list: {"id": "inbox", "key": "IN", "path": $BLURT_WORKSPACE/inbox}. Errors: {"ok": false, "error", "code"}, exit 1
(3 = projects.json stayed locked).
"""
from __future__ import annotations

import argparse
import contextlib
import functools
import io
import json
import locale
import os
import re
import shlex
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).parent))
from _common import (OPEN_STATES, blurt_home, blurt_workspace, file_lock, global_config, load_json,  # noqa: E402
                     now_iso, project_id, real, write_text_atomic)
import store as st  # noqa: E402

SCHEMA = 1
THRESHOLD = 0.75
KEY_RE = re.compile(r"[A-Z][A-Z0-9]{1,4}")
SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
SETTABLE = {"name", "description", "default_agent", "worktree", "worktree_root", "modules", "hints", "key", "pinned"}
ROUTE_TIMEOUT = 60
INBOX_NAMES = {"en": "Unassigned", "zh": "未归类"}


class ProjectError(Exception):
    def __init__(self, msg: str, code: str = "bad_args", exit_code: int = 1):
        super().__init__(msg)
        self.code, self.exit_code = code, exit_code


# ------------------------------------------------------------------ the registry
def registry_path() -> Path:
    return blurt_home() / "projects.json"


def load() -> dict:
    reg = load_json(registry_path(), None)
    if not isinstance(reg, dict):
        reg = {}
    reg.setdefault("schema", SCHEMA)
    reg.setdefault("current", "auto")
    reg.setdefault("route_threshold", THRESHOLD)
    if not isinstance(reg.get("projects"), list):
        reg["projects"] = []
    return reg


@contextmanager
def editing():
    """Read-modify-write projects.json under its lock."""
    with file_lock(blurt_home() / ".projects.lock"):
        reg = load()
        yield reg
        write_text_atomic(registry_path(), json.dumps(reg, ensure_ascii=False, indent=2) + "\n")


def entries() -> list[dict]:
    return [p for p in load()["projects"] if isinstance(p, dict) and p.get("id") and p.get("path")]


def by_id(pid: str) -> dict | None:
    return next((p for p in entries() if p["id"] == pid), None)


def ui_lang() -> str:
    """K10: config lang (auto | en | zh | zh-Hans) — auto follows the system's preferred language."""
    want = str(global_config().get("lang") or "auto")
    if want != "auto":
        return "zh" if want.lower().startswith("zh") else "en"
    return _system_lang()


@functools.lru_cache(maxsize=1)
def _system_lang() -> str:
    langs = []
    if sys.platform == "darwin":
        try:
            out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True,
                                 timeout=2).stdout
            langs = re.findall(r'"?([A-Za-z]{2,3}(?:-[A-Za-z0-9]+)*)"?', out)
        except (OSError, subprocess.TimeoutExpired):
            pass
    langs += [os.environ.get(v, "") for v in ("LC_ALL", "LC_MESSAGES", "LANG")] + [locale.getlocale()[0] or ""]
    first = next((x for x in langs if x and x not in ("C", "POSIX")), "en")
    return "zh" if first.lower().startswith("zh") else "en"


def inbox_entry() -> dict:
    return {"id": st.INBOX, "key": st.INBOX_KEY, "name": INBOX_NAMES[ui_lang()], "slug": "inbox",
            "path": str(real(st.inbox_root())), "description": ""}


def _words(name: str) -> list[str]:
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", s)
    return [w for w in re.split(r"[-_ .]+", s) if w]


def default_key(name: str, taken: set[str]) -> str:
    """K2: initials of the first 2–3 words (bug-agent → BA), else the first 3 letters (airank → AIR); a name with
    no Latin letters → P01…; a clash gets a digit appended."""
    words = [re.sub(r"[^A-Za-z0-9]", "", w) for w in _words(name)]
    words = [w for w in words if w]
    if len(words) >= 2:
        cand = "".join(w[0] for w in words[:3]).upper()
    else:
        cand = (words[0][:3] if words else "").upper()
    cand = cand.lstrip("0123456789")
    if len(cand) < 2:
        letters = re.sub(r"[^A-Za-z]", "", name).upper()
        cand = letters[:3] if len(letters) >= 2 else ""
    taken = {t.upper() for t in taken} | {st.INBOX_KEY}
    if not cand:
        n = 1
        while f"P{n:02d}" in taken:
            n += 1
        return f"P{n:02d}"
    cand = cand[:4]
    if cand not in taken:
        return cand
    n = 2
    while f"{cand}{n}"[:5] in taken or not KEY_RE.fullmatch(f"{cand}{n}"[:5]):
        n += 1
    return f"{cand}{n}"[:5]


def default_slug(name: str, pid: str, taken: set[str]) -> str:
    s = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]", "-", name.lower())).strip("-")[:32].rstrip("-")
    if not s:
        s = f"p-{pid[:6]}"
    base, n = s, 2
    while s in taken:
        suffix = f"-{n}"
        s = base[:32 - len(suffix)] + suffix
        n += 1
    return s


def _new_entry(path: Path, reg: dict, name: str | None = None, key: str | None = None,
               description: str | None = None) -> dict:
    pid = project_id(path)
    others = [p for p in reg["projects"] if p.get("id") != pid]
    if key is not None:
        check_key(key, {p.get("key") for p in others})
    name = name or path.name or str(path)
    now = now_iso(timespec="milliseconds")  # the recent list orders by it
    return {"id": pid, "path": str(path), "name": name,
            "key": key or default_key(path.name or name, {p.get("key") for p in others}),
            "slug": default_slug(path.name or name, pid, {p.get("slug") for p in others}),
            "description": description or "", "default_agent": None, "worktree": True, "worktree_root": None,
            "modules": [], "hints": {"domains": [], "apps": []}, "opened": now, "last_used": now, "pinned": False}


def check_key(key: str, taken) -> None:
    if not isinstance(key, str) or not KEY_RE.fullmatch(key) or key == st.INBOX_KEY:
        raise ProjectError(f"key {key!r}: 2–5 characters, A–Z then A–Z / 0–9, not IN", "bad_key")
    if key in taken:
        raise ProjectError(f"key {key} is taken by another project", "key_taken")


def ensure_project(path: Path) -> dict:
    """The registry entry for a folder, registering it if needed (store.py, when a project store first appears)."""
    path = real(path)
    pid = project_id(path)
    hit = by_id(pid)
    if hit:
        return hit
    with editing() as reg:
        hit = next((p for p in reg["projects"] if p.get("id") == pid), None)
        if hit is None:
            hit = _new_entry(path, reg)
            reg["projects"].append(hit)
    return hit


def store_of(entry: dict) -> st.Store:
    return st.inbox_store() if entry["id"] == st.INBOX else st.Store(Path(entry["path"]) / ".blurt")


def store_for(pid: str) -> st.Store:
    """The store of a project id ('inbox' included), created if it isn't there yet."""
    if pid == st.INBOX:
        s = st.inbox_store()
        s.ensure()
        return s
    e = by_id(pid)
    if e is None:
        raise ProjectError(f"no project {pid}", "no_project")
    s = store_of(e)
    s.ensure(e["id"], e["key"])
    return s


def counts(s: st.Store) -> tuple[int, int]:
    """(open items, live items) of a store, from the front-matter of its files."""
    open_, live = 0, 0
    for f in s.files():
        h = st.read_header(f)
        if not h or h.get("state") == "discarded":
            continue
        live += 1
        if h.get("state") in OPEN_STATES:
            open_ += 1
    return open_, live


def row(entry: dict) -> dict:
    s = store_of(entry)
    folder = Path(entry["path"])
    open_, live = counts(s)
    out = {**entry, "exists": folder.is_dir(), "git": bool(folder.is_dir() and st.git_toplevel(folder)),
           "store": str(s.root), "open_items": open_}
    if entry["id"] == st.INBOX:
        out.update(git=False, unassigned=live)
    return out


def _sorted(rows: list[dict]) -> list[dict]:
    return sorted(rows, key=lambda p: (not p.get("pinned"), _neg(p.get("last_used")), p.get("name") or ""))


def _neg(iso) -> float:
    from _common import to_epoch  # noqa: PLC0415
    return -(to_epoch(iso) or 0.0)


def resolve(path: Path | str) -> dict | None:
    """The registered project a path is in (the deepest folder), or the inbox entry for the inbox store."""
    p = real(path)
    if p == real(st.inbox_root()) or real(st.inbox_root()) in p.parents:
        return inbox_entry()
    best = None
    for e in entries():
        root = real(e["path"])
        if (p == root or root in p.parents) and (best is None or len(str(root)) > len(str(best["path"]))):
            best = {**e, "path": str(root)}
    return best


def find(ref: str) -> dict | None:
    """A project by id, key, slug, name or folder."""
    if ref == st.INBOX:
        return inbox_entry()
    es = entries()
    for k in ("id", "key", "slug", "name"):
        hit = next((e for e in es if e.get(k) == ref), None)
        if hit:
            return hit
    if os.path.isdir(os.path.expanduser(ref)):
        return next((e for e in es if real(e["path"]) == real(ref)), None)
    return None


# ------------------------------------------------------------------ commands
def cmd_list() -> dict:
    reg = load()
    return {"ok": True, "current": reg.get("current") or "auto", "current_by": reg.get("current_by"),
            "projects": _sorted([row(e) for e in entries()]), "inbox": row(inbox_entry())}


def _same_folder(registered, folder: Path) -> bool:
    try:
        return bool(registered) and real(registered) == folder
    except OSError:
        return False


def by_path(folder) -> dict | None:
    """The registered project of a folder, whatever its id (a project moved on disk keeps the id of its old path)."""
    f = real(os.path.expanduser(folder))
    return next((e for e in entries() if _same_folder(e.get("path"), f)), None)


def cmd_add(path: str, name=None, key=None, description=None) -> dict:
    folder = Path(os.path.expanduser(path))
    if not folder.exists():
        raise ProjectError(f"{path}: no such folder", "not_found")
    if not folder.is_dir():
        raise ProjectError(f"{path}: not a folder", "not_a_folder")
    folder = real(folder)
    if folder == real(st.inbox_root()) or folder == real(blurt_home()):
        raise ProjectError(f"{folder} is Blurt's own folder", "reserved")
    pid = project_id(folder)
    created, relocated = False, None
    # a folder that already has a store keeps the project its items belong to: moved or renamed on disk (the
    # registered path is gone), or removed from Blurt earlier — not a new, empty project next to the old one
    own = st.Store(folder / ".blurt")
    sid = own.meta.get("project") if own.exists else None
    with editing() as reg:
        e = next((p for p in reg["projects"] if p.get("id") == pid), None)
        # the folder is registered already (moved here earlier: its id is the old path's): that project, not a twin
        e = e or next((p for p in reg["projects"] if _same_folder(p.get("path"), folder)), None)
        if e is None and isinstance(sid, str) and sid and sid != st.INBOX and sid != pid:
            old = next((p for p in reg["projects"] if p.get("id") == sid), None)
            if old is not None and not Path(old["path"]).is_dir():
                relocated = old["path"]
                old["path"] = str(folder)
                old["last_used"] = now_iso(timespec="milliseconds")
                e = old
            elif old is None:
                mine = own.meta.get("key")
                keep = mine if mine and mine not in {p.get("key") for p in reg["projects"]} else None
                e = _new_entry(folder, reg, name, key or keep, description)
                e["id"] = sid
                reg["projects"].append(e)
                created = True
        if e is None:
            e = _new_entry(folder, reg, name, key, description)
            reg["projects"].append(e)
            created = True
        elif not created and relocated is None:
            e["last_used"] = now_iso(timespec="milliseconds")
    s = store_of(e)
    s.ensure(e["id"], e["key"])
    st.ensure_git_exclude(folder)
    if (relocated or (created and e["id"] != pid)) and (blurt_home() / "index.db").is_file() \
            and not os.environ.get("BLURT_NO_INDEX"):
        try:  # the items are still indexed at the old path: point the index at the new one (best effort, as items.py)
            import index  # noqa: PLC0415
            with contextlib.redirect_stdout(io.StringIO()):
                index.update_paths([s.root] + ([Path(relocated) / ".blurt"] if relocated else []))
        except (Exception, SystemExit):
            pass
    return {"ok": True, "project": row(e), "created": created, **({"relocated": relocated} if relocated else {})}


def cmd_remove(pid: str) -> dict:
    with editing() as reg:
        n = len(reg["projects"])
        reg["projects"] = [p for p in reg["projects"] if p.get("id") != pid]
        if len(reg["projects"]) == n:
            raise ProjectError(f"no project {pid}", "no_project")
        if reg.get("current") == pid:
            reg["current"] = "auto"
    return {"ok": True}


def cmd_set(pid: str, patch: dict) -> dict:
    if not isinstance(patch, dict):
        raise ProjectError("--json must be an object", "bad_args")
    bad = sorted(set(patch) - SETTABLE)
    if bad:
        raise ProjectError(f"can't set {', '.join(bad)} (settable: {', '.join(sorted(SETTABLE))})", "bad_field")
    if "name" in patch and (not isinstance(patch["name"], str) or not patch["name"].strip()):
        raise ProjectError("name can't be empty", "bad_field")
    if "modules" in patch and not (isinstance(patch["modules"], list) and all(isinstance(m, dict) and m.get("name")
                                                                              for m in patch["modules"])):
        raise ProjectError("modules: a list of {name, paths, description}", "bad_field")
    if "hints" in patch and not isinstance(patch["hints"], dict):
        raise ProjectError("hints: {domains: [...], apps: [...]}", "bad_field")
    with editing() as reg:
        e = next((p for p in reg["projects"] if p.get("id") == pid), None)
        if e is None:
            raise ProjectError(f"no project {pid}", "no_project")
        if "key" in patch and patch["key"] != e.get("key"):
            check_key(patch["key"], {p.get("key") for p in reg["projects"] if p is not e})
            s = store_of(e)
            if s.files():
                raise ProjectError("the key can only change while the project has no items", "key_in_use")
            if s.exists:
                s.set_meta(key=patch["key"])
        if "name" in patch:
            patch["name"] = patch["name"].strip()
        e.update(patch)
    return {"ok": True, "project": row(e)}


def cmd_use(pid: str, by: str = "user") -> dict:
    """by "user": the user chose it (in Blurt, or answering the app's "keep the old setting?" question);
    "migrate": carried over from v0.6 — the app asks about it once."""
    with editing() as reg:
        if pid != "auto":
            e = next((p for p in reg["projects"] if p.get("id") == pid), None)
            if e is None:
                raise ProjectError(f"no project {pid}", "no_project")
            e["last_used"] = now_iso(timespec="milliseconds")
        reg["current"] = pid
        reg["current_by"] = by
    return {"ok": True, "current": pid}


def cmd_current() -> dict:
    cur = load().get("current") or "auto"
    e = by_id(cur) if cur != "auto" else None
    if cur != "auto" and e is None:
        cur = "auto"
    return {"ok": True, "current": cur, "current_by": load().get("current_by"), "project": row(e) if e else None}


def cmd_migrate() -> dict:
    """v0.6 kept bound repos in config.json record.workspaces and the current one in record.workspace."""
    rec = global_config().get("record") or {}
    added = 0
    for w in rec.get("workspaces") or []:
        if not isinstance(w, str) or not os.path.isdir(os.path.expanduser(w)):
            continue
        if by_id(project_id(w)) is None and by_path(w) is None:
            cmd_add(w)
            added += 1
    cur = load().get("current") or "auto"
    w = rec.get("workspace")
    if isinstance(w, str) and os.path.isdir(os.path.expanduser(w)) and real(w) != real(blurt_workspace()) \
            and cur == "auto" and not load().get("_migrated"):
        e = by_id(project_id(w)) or by_path(w)
        if e is None:
            e = cmd_add(w)["project"]
            added += 1
        cmd_use(e["id"], by="migrate")
        cur = e["id"]
    with editing() as reg:
        # an earlier v0.7 build migrated without saying who chose the current project: treat it as carried over,
        # so the app asks once instead of filing captures there silently
        if reg.get("_migrated") and "current_by" not in reg and (reg.get("current") or "auto") != "auto":
            reg["current_by"] = "migrate"
        reg["_migrated"] = True  # once: a later `use auto` is the user's choice, not something to undo
    return {"ok": True, "added": added, "current": cur}


# ------------------------------------------------------------------ AI routing
def _domain(url) -> str:
    try:
        return (urlparse(url).hostname or "").lower().removeprefix("www.")
    except (ValueError, TypeError):
        return ""


def rule_route(item: dict, projects: list[dict]) -> dict | None:
    """K2 rules: code_refs that exist in exactly one project (0.95), source url / app in hints (0.9), module (0.8)."""
    refs = [re.split(r":\d", r, maxsplit=1)[0].strip() for r in item.get("code_refs") or [] if isinstance(r, str)]
    refs = [r for r in refs if r and not os.path.isabs(r)]
    if refs:
        hits = [p for p in projects if any((Path(p["path"]) / r).exists() for r in refs)]
        if len(hits) == 1:
            return {"project": hits[0]["id"], "confidence": 0.95, "reason": f"code_refs: {refs[0]}", "by": "rule"}
    src = item.get("source") if isinstance(item.get("source"), dict) else {}
    dom, app = _domain(src.get("url")), str(src.get("app") or "").lower()
    for p in projects:
        hints = p.get("hints") or {}
        doms = [str(d).lower().removeprefix("www.") for d in hints.get("domains") or []]
        if dom and any(dom == d or dom.endswith("." + d) for d in doms):
            return {"project": p["id"], "confidence": 0.9, "reason": f"source url {dom}", "by": "rule"}
        if app and app in [str(a).lower() for a in hints.get("apps") or []]:
            return {"project": p["id"], "confidence": 0.9, "reason": f"source app {src.get('app')}", "by": "rule"}
    mod = str(item.get("module") or "").strip().lower()
    if mod:
        hits = [p for p in projects if mod in [str(m.get("name", "")).lower() for m in p.get("modules") or []]]
        if len(hits) == 1:
            return {"project": hits[0]["id"], "confidence": 0.8, "reason": f"module {item['module']}", "by": "rule"}
    return None


ROUTE_PROMPT = """You sort captured work items into the user's projects. For each item pick the project it belongs
to, or null when none fits or you can't tell. confidence is 0–1: how sure you are (≥ 0.75 moves the item; lower
only suggests). Answer with JSON only: [{{"uid": "...", "project": "<project id>" | null, "confidence": 0.0,
"reason": "<a few words>"}}]

Projects:
{projects}

Items:
{items}
"""


def _ask_model(prompt: str, agent: str | None) -> str:
    """The same small model as live drafts: $BLURT_ROUTE_CMD (reads the prompt on stdin, prints the answer — tests,
    other agents), else the first installed claude / codex in record.agents order via agents.py command headless."""
    cwd = blurt_home() / "tmp"
    cwd.mkdir(parents=True, exist_ok=True)
    cmd = os.environ.get("BLURT_ROUTE_CMD")
    if cmd:
        p = subprocess.run(shlex.split(cmd), input=prompt, capture_output=True, text=True, encoding="utf-8",
                           timeout=ROUTE_TIMEOUT, cwd=cwd)
        if p.returncode:
            raise RuntimeError(f"route command exit {p.returncode}: {p.stderr[-300:]}")
        return p.stdout
    import agents  # noqa: PLC0415
    rec = global_config().get("record") or {}
    order = [agent] if agent else [rec.get("live_drafts_agent"), *agents.agent_order()]
    for a in dict.fromkeys(x for x in order if x in ("claude", "codex")):
        try:
            c = agents.command(a, "headless", prompt, cwd, events=False, mcp=False)
        except ValueError:
            continue
        argv = c["argv"]
        if not (shutil.which(argv[0]) or os.path.isfile(argv[0])):
            continue
        if a == "claude" and rec.get("live_drafts_model"):
            argv = [*argv, "--model", rec["live_drafts_model"]]
        p = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", timeout=ROUTE_TIMEOUT, cwd=cwd,
                           env={**os.environ, **(c.get("env") or {})}, stdin=subprocess.DEVNULL)
        if p.returncode == 0:
            return p.stdout
    raise RuntimeError("no agent CLI to ask")


def _extract_json(text: str):
    for m in re.finditer(r"[\[{]", text or ""):
        try:
            return json.JSONDecoder().raw_decode(text[m.start():])[0]
        except ValueError:
            continue
    return None


def llm_route(items: list[dict], projects: list[dict], agent: str | None) -> dict[str, dict]:
    proj = "\n".join(json.dumps({"id": p["id"], "name": p.get("name"), "description": p.get("description") or "",
                                 "modules": [m.get("name") for m in p.get("modules") or []]}, ensure_ascii=False)
                     for p in projects)
    its = "\n".join(json.dumps({"uid": i["uid"], "title": i.get("title"), "quote": (i.get("quote") or "")[:400],
                                "source": {k: (i.get("source") or {}).get(k) for k in ("app", "url")}},
                               ensure_ascii=False) for i in items)
    answer = _extract_json(_ask_model(ROUTE_PROMPT.format(projects=proj, items=its), agent))
    rows = answer if isinstance(answer, list) else [answer] if isinstance(answer, dict) else []
    ids = {p["id"] for p in projects}
    out = {}
    for r in rows:
        if not isinstance(r, dict) or not isinstance(r.get("uid"), str):
            continue
        pid = r.get("project") if r.get("project") in ids else None
        try:
            conf = max(0.0, min(1.0, float(r.get("confidence") or 0)))
        except (TypeError, ValueError):
            conf = 0.0
        out[r["uid"]] = {"project": pid, "confidence": conf if pid else 0.0,
                         "reason": str(r.get("reason") or "")[:200], "by": "llm"}
    return out


def cmd_route(refs: list[str], apply: bool, threshold: float | None, agent: str | None, no_llm: bool) -> dict:
    import items as items_mod  # noqa: PLC0415 — items imports projects
    reg = load()
    thr = float(threshold if threshold is not None else reg.get("route_threshold") or THRESHOLD)
    projects = [{**e, "path": str(real(e["path"]))} for e in entries() if os.path.isdir(e["path"])]
    found = []
    for ref in refs:
        path = items_mod.find_path(ref)
        if path is None:
            raise ProjectError(f"no item {ref}", "not_found")
        item = st.read_item(path)
        if not (item.get("_user") or {}).get("project"):  # the user chose: never overridden
            found.append((path, item))
    sugg: dict[str, dict] = {}
    rest = []
    for path, item in found:
        r = rule_route(item, projects) if projects else None
        if r:
            sugg[item["uid"]] = r
        else:
            rest.append(item)
    if rest and projects and not no_llm:
        try:
            sugg.update(llm_route(rest, projects, agent))
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as e:
            for i in rest:
                sugg.setdefault(i["uid"], {"project": None, "confidence": 0.0, "reason": f"model: {str(e)[:120]}",
                                           "by": "llm"})
    moved = []
    out = []
    for path, item in found:
        s = sugg.get(item["uid"]) or {"project": None, "confidence": 0.0, "reason": "", "by": "rule"}
        out.append({"uid": item["uid"], **s})
        if not apply or not s["project"]:
            continue
        if s["confidence"] >= thr:
            if s["project"] != item.get("project"):
                r = items_mod.move_items([path], s["project"], by="ai", confidence=s["confidence"],
                                         reason=s["reason"])
                moved += [m["uid"] for m in r]
        else:
            items_mod.suggest_project(path, s["project"], s["confidence"], s["reason"])
    items_mod.reindex_touched()
    return {"ok": True, "suggestions": out, "moved": moved}


def session_unrouted(session: str) -> list[str]:
    """A batch's items still in the inbox with no project suggested — what ingest routes in the background, and what
    the app routes itself after an organizing run (that run doesn't: it is sandboxed, BLURT_NO_ROUTE)."""
    import items as items_mod  # noqa: PLC0415 — items imports projects
    rows, _ = items_mod.scope_items({"session": str(real(session))})
    return [it["uid"] for _, it in rows if (it.get("project") or st.INBOX) == st.INBOX and not it.get("suggested_project")
            and it.get("state") != "discarded" and it.get("uid")]


def route_job(refs: list[str], apply: bool, threshold: float | None, agent: str | None, no_llm: bool) -> dict:
    """cmd_route; with --apply (the background run after ingest) also a K4 route job this process owns, so the
    island and the main window show the inbox being sorted and what it moved. A preview (no --apply) writes none."""
    try:
        import jobs  # noqa: PLC0415
    except ImportError:
        jobs = None
    job = None
    if apply and jobs is not None:
        try:
            job = jobs.create("route", project="inbox", owner="projects.py")
            jobs.update(job["id"], lambda j: j["steps"][0].update(state="running", started=j["created"]))
        except Exception:  # noqa: BLE001 — the job is only a report; routing goes on without it
            job = None

    def close(state: str, uids: list[str], error: dict | None = None) -> None:
        if job is None:
            return
        try:
            def fn(j):
                j["items"] = uids
                j["steps"][0].update(state="done" if state == "done" else "failed", ended=jobs.now_iso())
                jobs.finish(j, state, error)
            jobs.update(job["id"], fn)
        except Exception:  # noqa: BLE001
            pass
    try:
        out = cmd_route(refs, apply, threshold, agent, no_llm)
    except Exception as e:
        close("failed", [], {"code": getattr(e, "code", None) or "unknown", "message": str(e)[:300], "hint_key": None})
        raise
    close("done", [x["uid"] for x in out.get("suggestions", [])])
    if job is not None:
        out["job"] = job["id"]
    return out


# ------------------------------------------------------------------ CLI
class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ProjectError(f"{self.prog}: {message}")


def main(argv: list[str] | None = None) -> None:
    p = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    sub.add_parser("list")
    s = sub.add_parser("add")
    s.add_argument("path")
    s.add_argument("--name")
    s.add_argument("--key")
    s.add_argument("--description")
    s = sub.add_parser("remove")
    s.add_argument("id")
    s = sub.add_parser("set")
    s.add_argument("id")
    s.add_argument("--json", required=True)
    s = sub.add_parser("use")
    s.add_argument("id")
    sub.add_parser("current")
    s = sub.add_parser("resolve")
    s.add_argument("path")
    s = sub.add_parser("route")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--items", nargs="+", metavar="REF")
    g.add_argument("--session", metavar="DIR")
    s.add_argument("--apply", action="store_true")
    s.add_argument("--threshold", type=float)
    s.add_argument("--agent")
    s.add_argument("--no-llm", action="store_true")
    sub.add_parser("migrate")
    try:
        a = p.parse_args(argv)
        if a.cmd == "list":
            out = cmd_list()
        elif a.cmd == "add":
            out = cmd_add(a.path, a.name, a.key, a.description)
        elif a.cmd == "remove":
            out = cmd_remove(a.id)
        elif a.cmd == "set":
            try:
                patch = json.loads(a.json)
            except ValueError as e:
                raise ProjectError(f"--json: {e}")
            out = cmd_set(a.id, patch)
        elif a.cmd == "use":
            out = cmd_use(a.id)
        elif a.cmd == "current":
            out = cmd_current()
        elif a.cmd == "resolve":
            e = resolve(a.path)
            out = {"ok": True, "project": row(e) if e else None}
        elif a.cmd == "route":
            refs = a.items or session_unrouted(a.session)
            out = route_job(refs, a.apply, a.threshold, a.agent, a.no_llm) if refs else {"ok": True, "suggestions": [], "moved": []}
        else:
            out = cmd_migrate()
    except ProjectError as e:
        _fail(str(e), e.code, e.exit_code)
    except TimeoutError as e:
        _fail(str(e), "locked", 3)
    except Exception as e:  # items.py errors raised through route
        code = getattr(e, "code", None)
        if code is None:
            raise
        _fail(str(e), code, getattr(e, "exit_code", 1))
    print(json.dumps(out, ensure_ascii=False), flush=True)


def _fail(msg: str, code: str, exit_code: int) -> None:
    print(json.dumps({"ok": False, "error": msg, "code": code}, ensure_ascii=False), flush=True)
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
