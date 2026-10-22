"""Stand-in for P1's projects.py (contract K2), only what the session tests use: add, list, set. The tests use the
real one as soon as it exists (see p2_env.py)."""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")
WS = Path(os.environ.get("BLURT_WORKSPACE") or Path.home() / "Blurt")
REG = HOME / "projects.json"


def load():
    try:
        return json.loads(REG.read_text())
    except FileNotFoundError:
        return {"schema": 1, "current": "auto", "route_threshold": 0.75, "projects": []}


def save(d):
    REG.parent.mkdir(parents=True, exist_ok=True)
    REG.write_text(json.dumps(d, ensure_ascii=False, indent=1))


def is_git(path):
    return subprocess.run(["git", "-C", path, "rev-parse", "--git-dir"], capture_output=True).returncode == 0


def row(p):
    return {**p, "exists": Path(p["path"]).is_dir(), "git": is_git(p["path"]), "store": str(Path(p["path"]) / ".blurt"),
            "open_items": 0}


def inbox():
    return {"id": "inbox", "key": "IN", "name": "Unassigned", "path": str(WS / "inbox"), "store": str(WS / "inbox"),
            "slug": "inbox", "exists": True, "git": False, "open_items": 0, "unassigned": 0}


def main(a):
    d = load()
    if a[0] == "add":
        path = str(Path(a[1]).resolve())
        pid = hashlib.sha1(path.encode()).hexdigest()[:12]
        name = a[a.index("--name") + 1] if "--name" in a else Path(path).name
        key = a[a.index("--key") + 1] if "--key" in a else "".join(w[0] for w in re.split(r"[-_ .]", name) if w)[:3].upper()
        if len(key) < 2:
            key = name[:3].upper()
        cur = next((p for p in d["projects"] if p["id"] == pid), None)
        if cur is None:
            cur = {"id": pid, "path": path, "name": name, "key": key, "slug": re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-"),
                   "description": "", "default_agent": None, "worktree": True, "worktree_root": None, "modules": [],
                   "hints": {}, "opened": None, "last_used": None, "pinned": False}
            d["projects"].append(cur)
            save(d)
        (Path(path) / ".blurt").mkdir(exist_ok=True)
        print(json.dumps({"ok": True, "project": row(cur), "created": True}))
    elif a[0] == "list":
        print(json.dumps({"ok": True, "current": d["current"], "projects": [row(p) for p in d["projects"]], "inbox": inbox()}))
    elif a[0] == "set":
        cur = next(p for p in d["projects"] if p["id"] == a[1])
        cur.update(json.loads(a[a.index("--json") + 1]))
        save(d)
        print(json.dumps({"ok": True, "project": row(cur)}))
    else:
        print(json.dumps({"ok": False, "error": "stub: unsupported", "code": "bad_args"}))
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
