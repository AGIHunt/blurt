"""Stand-in for P1's items.py v3 (contract K1/K3), only what the session tests use: add, get, work, patch,
set-frames. Items live in one JSON file instead of Markdown; the work transitions follow the K3 table. The tests use
the real items.py as soon as it has `work` (see p2_env.py)."""
import json
import os
import secrets
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HOME = Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")
DB = HOME / "stub-items.json"
HERE = Path(__file__).resolve().parent

ALLOWED = {("todo", "handed_off"), ("handed_off", "in_progress"), ("handed_off", "to_verify"),
           ("in_progress", "to_verify"), ("to_verify", "done"), ("to_verify", "todo"), ("done", "todo"),
           ("wontfix", "todo")}
USER_ONLY = {"done", "wontfix"}


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def fail(code, msg):
    print(json.dumps({"ok": False, "error": msg, "code": code}))
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def load():
    try:
        return json.loads(DB.read_text())
    except FileNotFoundError:
        return {"items": {}, "next": {}}


def save(d):
    DB.write_text(json.dumps(d, ensure_ascii=False, indent=1))


def projects():
    out = subprocess.run([sys.executable, str(HERE / "projects.py"), "list"], capture_output=True, text=True).stdout
    reg = json.loads(out.splitlines()[-1])
    return {p["id"]: p for p in reg["projects"]} | {"inbox": reg["inbox"]}


def find(d, ref):
    for it in d["items"].values():
        if ref in (it["uid"], it["id"], it.get("path")) or ref in it.get("aliases", []):
            return it
    fail("no_item", f"no item {ref}")


def opt(a, name, default=None):
    return a[a.index(name) + 1] if name in a else default


def main(a):
    d = load()
    cmd = a[0]
    if cmd == "add":
        pid = opt(a, "--project")
        proj = projects()[pid]
        body = json.loads(opt(a, "--json"))
        n = d["next"].get(pid, 1)
        d["next"][pid] = n + 1
        uid = "01" + "".join(secrets.choice("0123456789ABCDEFGHJKMNPQRSTVWXYZ") for _ in range(24))
        store = Path(proj["store"])
        it = {"schema": 3, "id": f"{proj['key']}-{n}", "uid": uid, "kind": "issue", "title": "", "status": "draft",
              "work": {"state": "todo", "to": None, "agent": None, "job": None, "handoff": None, "claim": None,
                       "note": "", "commit": None, "pr": None, "at": now(), "by": "app"},
              "project": pid, "created": now(), "updated": now(), "frames": [], **body}
        it["path"] = str(store / "items" / f"{it['id']}.md")
        it["store"] = str(store)
        d["items"][uid] = it
        save(d)
        print(json.dumps({"ok": True, "id": it["id"], "uid": uid, "path": it["path"]}))
    elif cmd == "get":
        it = find(d, a[1])
        print(json.dumps({"ok": True, "item": it, "session": None}, ensure_ascii=False))
    elif cmd == "patch":
        it = find(d, a[1])
        for i, x in enumerate(a):
            if x == "--set":
                k, _, v = a[i + 1].partition("=")
                try:
                    it[k] = json.loads(v)
                except ValueError:
                    it[k] = v
        it["updated"] = now()
        save(d)
        print(json.dumps({"ok": True, "id": it["id"]}))
    elif cmd == "set-frames":
        it = find(d, a[1])
        store = Path(it["store"])
        frames = []
        for n, spec in enumerate([x for x in a[2:] if not x.startswith("--")], 1):
            path, _, cap = spec.partition("#")
            path, _, t = path.partition("@")
            dest = store / "assets" / it["uid"] / f"{n}{Path(path).suffix}"
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)
            frames.append({"path": str(dest.relative_to(store)), "t": float(t) if t else None, "caption": cap.strip('"')})
        it["frames"] = frames
        save(d)
        print(json.dumps({"ok": True}))
    elif cmd == "work":
        refs = []
        for x in a[1:]:
            if x.startswith("--"):
                break
            refs.append(x)
        state, by = opt(a, "--state"), opt(a, "--by", "agent")
        out = []
        targets = [find(d, r) for r in refs]
        for it in targets:
            cur = it["work"]["state"]
            if state != cur and (cur, state) not in ALLOWED and not (state == "wontfix" and by == "user"):
                fail("bad_transition", f"{it['id']}: {cur} → {state}")
            if state in USER_ONLY and by != "user":
                fail("bad_transition", f"{it['id']}: only the user sets {state}")
        for it in targets:
            w = dict(it["work"])
            if w["state"] != state:
                it.setdefault("work_history", []).append(w)
            w.update(state=state, at=now(), by=by)
            for k in ("to", "agent", "job", "handoff", "claim", "note", "commit", "pr"):
                v = opt(a, f"--{k}")
                if v is not None:
                    w[k] = v
            it["work"] = w
            out.append({"uid": it["uid"], "work": w})
        save(d)
        print(json.dumps({"ok": True, "items": out}))
    else:
        fail("bad_args", "stub: unsupported")


if __name__ == "__main__":
    import fcntl
    HOME.mkdir(parents=True, exist_ok=True)
    with open(HOME / ".stub-items.lock", "a") as lk:  # serialize writers (hooks' background syncs run concurrently)
        fcntl.flock(lk, fcntl.LOCK_EX)
        main(sys.argv[1:])
