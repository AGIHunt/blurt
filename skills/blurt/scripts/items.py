# /// script
# requires-python = ">=3.10"
# ///
"""Change a session's items.json while the review page may be open. Never rewrite the file yourself after
review.py has started: the user is editing the same file. Every write here is locked and atomic, and fields the
user changed on the page (listed in the item's "_user") are kept unless you pass --force (only do that when the
user asked for the change in chat). Items the user dropped or merged away stay gone.

  items.py patch SESSION ID --set key=VALUE ... [--unset key ...] [--force]
        VALUE is JSON if it parses (list, object, number, true/false, "quoted"), else a plain string.
        ID "." means the session itself (title, digest).
  items.py set-frames SESSION ID PATH[@T][#CAPTION] ... [--append]
        frames relative to the session, first = primary; e.g. frames/I-003-1.jpg@14.2#"login button greyed out"
  items.py add SESSION --json '{"kind":"issue","title":"…",…}' [--after ID]    prints the new id
  items.py done SESSION        processing finished: the page stops showing "still working"

Output: one JSON line per call; "kept_user" lists fields left alone because the user edited them.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, find_item, items_lock, load_session, removed_into, save_session  # noqa: E402

PROTECTED = {"id", "_user", "_removed"}


def parse_value(raw: str):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def update(session: Path, fn):
    with items_lock(session):
        data = load_session(session)
        if data is None:
            die(f"{session}: no items.json yet — write it first (§3), then use items.py")
        out = fn(data)
        if out.pop("_write", True):
            data["agent_at"] = round(time.time(), 1)  # the page uses it to tell "still working" from "stalled"
            save_session(session, data)
    print(json.dumps(out, ensure_ascii=False), flush=True)
    return out


def apply_fields(target: dict, sets: dict, unsets: list[str], force: bool) -> dict:
    user = target.get("_user") or {}
    written, kept = [], []
    for k, v in sets.items():
        if k in PROTECTED:
            die(f"can't set {k}")
        if k in user and not force:
            kept.append(k)
            continue
        target[k] = v
        written.append(k)
    for k in unsets:
        if k in PROTECTED:
            die(f"can't unset {k}")
        if k in user and not force:
            kept.append(k)
        elif k in target:
            del target[k]
            written.append(k)
    return {"written": written, **({"kept_user": kept} if kept else {})}


def patch(data: dict, item_id: str, sets: dict, unsets: list[str], force: bool) -> dict:
    if item_id == ".":
        return {"ok": True, "id": ".", **apply_fields(data, sets, unsets, force)}
    item = find_item(data, item_id)
    if item is None:
        into = removed_into(data, item_id)
        if into is None:
            die(f"no item {item_id}")
        return {"ok": True, "id": item_id, "skipped": f"merged into {into}" if into else "removed by the user",
                "_write": False}
    out = {"ok": True, "id": item_id, **apply_fields(item, sets, unsets, force)}
    if item.get("status") == "deleted":
        out["note"] = "the user dropped this item — no need to spend more work on it"
    return out


def parse_frame(spec: str) -> dict:
    path, _, caption = spec.partition("#")
    m = re.fullmatch(r"(.+?)@(\d+(?:\.\d+)?)", path)
    f = {"path": m.group(1), "t": float(m.group(2))} if m else {"path": path}
    if caption:
        f["caption"] = caption
    return f


def set_frames(session: Path, data: dict, item_id: str, frames: list[dict], append: bool, force: bool) -> dict:
    for f in frames:
        if not (session / f["path"]).is_file():
            die(f"{f['path']}: no such file in {session}")
    item = find_item(data, item_id)
    redirected = None
    if item is None:
        into = removed_into(data, item_id)
        if into is None:
            die(f"no item {item_id}")
        item = find_item(data, into) if into else None
        if item is None:
            return {"ok": True, "id": item_id, "skipped": "removed by the user", "_write": False}
        redirected, append = into, True  # the user merged it: its evidence belongs to the item it went into
    if append:
        have = {f.get("path") for f in item.get("frames") or []}
        frames = (item.get("frames") or []) + [f for f in frames if f["path"] not in have]
    out = patch(data, item["id"], {"frames": frames}, [], force)
    if redirected:
        out.update(id=item_id, appended_to=redirected)
    return out


def add(data: dict, item: dict, after: str | None) -> dict:
    if not isinstance(item, dict) or not item.get("kind") or not item.get("title"):
        die("--json must be an object with at least kind and title")
    items = data.setdefault("items", [])
    gone = data.get("_removed") or {}
    taken = {i.get("id") for i in items} | set(gone)
    if item.get("id"):
        if item["id"] in taken:
            die(f"id {item['id']} is taken (or was merged away by the user) — omit id to get a new one")
    else:
        nums = [(m.group(1), int(m.group(2))) for x in taken if x and (m := re.fullmatch(r"(.*?)(\d+)", x))]
        prefix = max(nums, key=lambda p: p[1])[0] if nums else "I-"
        width = max((len(x) - len(prefix) for x in taken if x and x.startswith(prefix)), default=3)
        item["id"] = f"{prefix}{max((n for _, n in nums), default=0) + 1:0{width}d}"
    item.setdefault("status", "draft")
    item.pop("_user", None)
    pos = next((k + 1 for k, i in enumerate(items) if i.get("id") == after), len(items)) if after else len(items)
    items.insert(pos, item)
    out = {"ok": True, "id": item["id"]}
    if data.get("reviewed"):
        out["note"] = "the user already finished the review; mention the new item to them"
    return out


def done(data: dict) -> dict:
    data.pop("processing", None)
    live = [i for i in data.get("items", []) if i.get("status") != "deleted"]
    missing = [i["id"] for i in live if not i.get("frames")]
    return {"ok": True, "items": len(live), **({"no_frames": missing} if missing else {}),
            **({"reviewed": True} if data.get("reviewed") else {})}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("patch", help="set / unset fields of one item (or '.' = the session)")
    s.add_argument("session")
    s.add_argument("id")
    s.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    s.add_argument("--unset", action="append", default=[], metavar="KEY")
    s.add_argument("--force", action="store_true", help="overwrite fields the user edited (only if they asked)")
    s = sub.add_parser("set-frames", help="replace (or --append) an item's frames")
    s.add_argument("session")
    s.add_argument("id")
    s.add_argument("frames", nargs="+", metavar="PATH[@T][#CAPTION]")
    s.add_argument("--append", action="store_true")
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("add", help="add an item; prints its id")
    s.add_argument("session")
    s.add_argument("--json", required=True)
    s.add_argument("--after", metavar="ID")
    s = sub.add_parser("done", help="mark processing finished")
    s.add_argument("session")
    a = p.parse_args()
    session = Path(a.session)

    if a.cmd == "patch":
        sets = {}
        for kv in a.set:
            k, eq, v = kv.partition("=")
            if not eq or not k:
                die(f"--set {kv!r}: expected KEY=VALUE")
            sets[k] = parse_value(v)
        update(session, lambda d: patch(d, a.id, sets, a.unset, a.force))
    elif a.cmd == "set-frames":
        frames = [parse_frame(f) for f in a.frames]
        update(session, lambda d: set_frames(session, d, a.id, frames, a.append, a.force))
    elif a.cmd == "add":
        try:
            item = json.loads(a.json)
        except ValueError as e:
            die(f"--json: {e}")
        update(session, lambda d: add(d, item, a.after))
    elif a.cmd == "done":
        update(session, done)


if __name__ == "__main__":
    main()
