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
  projects.py remove ID                    unregister only — never deletes .blurt → {"ok","removed":{entry,index,current}}
  projects.py restore --json REMOVED       undo of remove: that entry back at its place → {"ok","project"}
  projects.py order ID …                   the user's order (the app's sidebar): these first → {"ok","order"}
  projects.py set ID --json '{patch}'      name description default_agent worktree worktree_root modules key
                                           pinned → {"ok","project"}   (key: only while the project has no items)
  projects.py use ID|inbox                 the current project, set by the user: captures go there; inbox = none
                                           (captures go to Unassigned; "none" and "auto" — v0.8's word — mean the
                                           same) → {"ok","current": id|null}
  projects.py current                      → {"ok","current": id|null,"current_by","project":Row|null}
                                           current_by: "user" (chosen in Blurt) | "migrate" (carried over from
                                           v0.6's record.workspace — the app asks once whether to keep it) | null
  projects.py resolve PATH                 the (deepest) project PATH is in → {"ok","project":Row|null}
  projects.py candidates [--recent N]      what an organizing run of an Unassigned capture is told about the projects
                                           (it may suggest one per item; nothing moves): each project's id, key, name,
                                           description, folder and the titles of its newest N items (default 5) →
                                           {"ok","projects":[{id,key,name,description,path,recent}],"text"} — "text"
                                           is that list as the prompt says it ("" without projects)
  projects.py migrate                      v0.6 config record.workspace(s) → projects → {"ok","added","current"}

Nothing here guesses a project or moves an item: the user picks the current project (or none), and moves items
themselves — an organizing run only leaves a suggestion (items.py: suggested_project) for them to accept.

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
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (OPEN_STATES, blurt_home, blurt_workspace, file_lock, global_config, load_json,  # noqa: E402
                     now_iso, project_id, real, write_text_atomic)
import store as st  # noqa: E402

SCHEMA = 1
KEY_RE = re.compile(r"[A-Z][A-Z0-9]{1,4}")
SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
SETTABLE = {"name", "description", "default_agent", "worktree", "worktree_root", "modules", "key", "pinned"}
# the current project when the user picked none: captures go to Unassigned. "auto" is v0.8's word for it (the AI
# sorted captures into projects then; nothing does now), "inbox" / "none" what callers say.
NO_PROJECT = {None, "", "auto", "inbox", "none"}
RECENT = 5
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
    if reg.get("current") in NO_PROJECT:
        reg["current"] = None
    reg.pop("route_threshold", None)  # v0.8: the confidence at which the AI moved items — nothing moves them now
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
            "modules": [], "opened": now, "last_used": now, "pinned": False}


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
    """The store of a project id ('inbox' included), created if it isn't there yet. A project whose folder is gone
    (moved, renamed) → ProjectError "folder_missing": nothing is written at the old path — `add NEWPATH` relocates it."""
    if pid == st.INBOX:
        s = st.inbox_store()
        s.ensure()
        return s
    e = by_id(pid)
    if e is None:
        raise ProjectError(f"no project {pid}", "no_project")
    if not Path(e["path"]).is_dir():
        raise ProjectError(f"{e.get('name') or pid}: its folder {e['path']} isn't there (moved or renamed?) — "
                           "locate it: projects.py add NEWPATH", "folder_missing")
    s = store_of(e)
    try:
        s.ensure(e["id"], e["key"])
    except st.FolderMissing as x:
        raise ProjectError(str(x), "folder_missing") from x
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
    return {"ok": True, "current": reg.get("current"), "current_by": reg.get("current_by"),
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
    """Unregister. The answer carries the registry entry as it was (and where, and whether it was current): `restore`
    puts exactly that back — the app's Undo after Remove from Blurt loses nothing (name, key, description, agent,
    worktree, modules, its place in the list)."""
    with editing() as reg:
        k = next((n for n, p in enumerate(reg["projects"]) if p.get("id") == pid), None)
        if k is None:
            raise ProjectError(f"no project {pid}", "no_project")
        e = reg["projects"].pop(k)
        was_current = reg.get("current") == pid
        if was_current:
            reg["current"] = None
    return {"ok": True, "removed": {"entry": e, "index": k, "current": was_current}}


def cmd_restore(removed: dict) -> dict:
    """Undo of `remove`: the entry it answered, back at its place (and current again if it was)."""
    e = removed.get("entry") if isinstance(removed, dict) else None
    if not isinstance(e, dict) or not e.get("id") or not e.get("path"):
        raise ProjectError("restore: pass what remove answered as removed", "bad_args")
    with editing() as reg:
        if any(p.get("id") == e["id"] or _same_folder(p.get("path"), Path(e["path"])) for p in reg["projects"]):
            raise ProjectError(f"{e['path']} is registered again already", "exists")
        if e.get("key") in {p.get("key") for p in reg["projects"]}:
            raise ProjectError(f"another project uses the key {e.get('key')} now", "key_taken")
        k = removed.get("index")
        reg["projects"].insert(k if isinstance(k, int) and 0 <= k <= len(reg["projects"]) else len(reg["projects"]), e)
        if removed.get("current"):
            reg["current"] = e["id"]
    return {"ok": True, "project": row(e)}


def cmd_order(ids: list[str]) -> dict:
    """The user's order of the projects (the app's sidebar, dragged): these first, in this order; any other keeps its
    place after them. Opening a folder appends it; using a project never reorders (⌘5–⌘9 stay put)."""
    with editing() as reg:
        by = {p.get("id"): p for p in reg["projects"]}
        unknown = [i for i in ids if i not in by]
        if unknown:
            raise ProjectError(f"no project {', '.join(unknown)}", "no_project")
        first = [by[i] for i in dict.fromkeys(ids)]
        reg["projects"] = first + [p for p in reg["projects"] if p.get("id") not in set(ids)]
    return {"ok": True, "order": [p["id"] for p in first]}


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


def cmd_use(pid: str | None, by: str = "user") -> dict:
    """The current project — only ever the user's pick. pid inbox / none / auto (NO_PROJECT): none, captures go to
    Unassigned. by "user": the user chose it (in Blurt, or answering the app's "keep the old setting?" question);
    "migrate": carried over from v0.6 — the app asks about it once."""
    pid = None if pid in NO_PROJECT else pid
    with editing() as reg:
        if pid is not None:
            e = next((p for p in reg["projects"] if p.get("id") == pid), None)
            if e is None:
                raise ProjectError(f"no project {pid}", "no_project")
            e["last_used"] = now_iso(timespec="milliseconds")
        reg["current"] = pid
        reg["current_by"] = by
    return {"ok": True, "current": pid}


def cmd_current() -> dict:
    reg = load()
    e = by_id(reg["current"]) if reg.get("current") else None
    return {"ok": True, "current": e["id"] if e else None, "current_by": reg.get("current_by"),
            "project": row(e) if e else None}


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
    cur = load().get("current")
    w = rec.get("workspace")
    if isinstance(w, str) and os.path.isdir(os.path.expanduser(w)) and real(w) != real(blurt_workspace()) \
            and cur is None and not load().get("_migrated"):
        e = by_id(project_id(w)) or by_path(w)
        if e is None:
            e = cmd_add(w)["project"]
            added += 1
        cmd_use(e["id"], by="migrate")
        cur = e["id"]
    with editing() as reg:
        # an earlier v0.7 build migrated without saying who chose the current project: treat it as carried over,
        # so the app asks once instead of filing captures there silently
        if reg.get("_migrated") and "current_by" not in reg and reg.get("current") is not None:
            reg["current_by"] = "migrate"
        reg["_migrated"] = True  # once: a later `use inbox` is the user's choice, not something to undo
    return {"ok": True, "added": added, "current": cur}


# ------------------------------------------------------------------ what an organizing run is told
def recent_titles(entry: dict, n: int = RECENT) -> list[str]:
    """The titles of a project's newest n live items: the highest ids (a store hands them out in order, and an item
    moved in gets a new one), discarded ones skipped. Front-matter only, never more than a few dozen files."""
    s = store_of(entry)

    def num(p: Path) -> int:
        m = st.ID_RE.match(p.stem)
        return int(m.group(2)) if m else -1
    out = []
    for f in sorted(s.files(), key=num, reverse=True)[: n * 4]:
        h = st.read_header(f)
        t = str((h or {}).get("title") or "").strip()
        if h and t and h.get("state") != "discarded":
            out.append(t[:120])
        if len(out) >= n:
            break
    return out


CANDIDATES_HEAD = """The user hasn't picked a project for this capture: its items go to Unassigned. These are the projects on this
Mac. Where an item clearly belongs to one, put "project": "<its id>" and a few words in "project_reason" on that
item; leave "project" out when you can't tell. It is only a suggestion — the user moves the item with one click —
so don't spend effort on it: what you already know from the capture is enough. You may look in a project's folder
if that settles it quickly."""


def cmd_candidates(recent: int = RECENT) -> dict:
    """The candidate projects an organizing run of an Unassigned capture gets in its prompt (one prompt, no extra
    model call): computed now from the registry and the stores — no profile kept anywhere, nothing learnt."""
    rows = []
    for e in _sorted([x for x in entries() if os.path.isdir(x["path"])]):
        rows.append({"id": e["id"], "key": e.get("key"), "name": e.get("name") or Path(e["path"]).name,
                     "description": (e.get("description") or "").strip(), "path": str(real(e["path"])),
                     "recent": recent_titles(e, recent) if recent > 0 else []})
    lines = []
    for r in rows:
        lines.append(f"- {r['name']} — id {r['id']}, key {r['key']}, folder {r['path']}")
        if r["description"]:
            lines.append(f"  About: {r['description'][:300]}")
        if r["recent"]:
            lines.append("  Newest items: " + "; ".join(json.dumps(t, ensure_ascii=False) for t in r["recent"]))
    text = (CANDIDATES_HEAD + "\n" + "\n".join(lines)) if rows else ""
    return {"ok": True, "projects": rows, "text": text}

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
    s = sub.add_parser("restore")
    s.add_argument("--json", required=True)
    s = sub.add_parser("order")
    s.add_argument("ids", nargs="+")
    s = sub.add_parser("set")
    s.add_argument("id")
    s.add_argument("--json", required=True)
    s = sub.add_parser("use")
    s.add_argument("id")
    sub.add_parser("current")
    s = sub.add_parser("resolve")
    s.add_argument("path")
    s = sub.add_parser("candidates")
    s.add_argument("--recent", type=int, default=RECENT)
    sub.add_parser("migrate")
    try:
        a = p.parse_args(argv)
        if a.cmd == "list":
            out = cmd_list()
        elif a.cmd == "add":
            out = cmd_add(a.path, a.name, a.key, a.description)
        elif a.cmd == "remove":
            out = cmd_remove(a.id)
        elif a.cmd == "restore":
            try:
                removed = json.loads(a.json)
            except ValueError as e:
                raise ProjectError(f"--json: {e}")
            out = cmd_restore(removed)
        elif a.cmd == "order":
            out = cmd_order(a.ids)
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
        elif a.cmd == "candidates":
            out = cmd_candidates(max(0, a.recent))
        else:
            out = cmd_migrate()
    except ProjectError as e:
        _fail(str(e), e.code, e.exit_code)
    except TimeoutError as e:
        _fail(str(e), "locked", 3)
    except Exception as e:  # store.py / items.py errors carry a code
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
