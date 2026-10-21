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
  items.py add SESSION --json '{"kind":"issue","title":"…",…}' [--after ID]    prints the new id and uid
  items.py done SESSION        processing finished: the page stops showing "still working"
  items.py get SESSION ID      one item (always with its uid) → {"item": {…}, "session": "<abs dir>"}
  items.py list SESSION [--kind K] [--status S] [--fix-state F|none]     deleted items only with --status deleted
  items.py fix SESSION ID --state fixing|fixed|wontfix|reopened [--agent A] [--run-id R] [--commit SHA] [--pr URL]
        [--note TEXT]    record a fix attempt; the previous state goes to fix_history. --agent / --run-id default
        to $BLURT_AGENT / $BLURT_RUN_ID (set by the Blurt app when it starts you)
  items.py user-ops SESSION (--json '[op,…]' | --stdin) [--confirm]    the user's edits, from the Blurt app
  items.py ensure-uids SESSION    write the uid of every item that has none

ID is an item id ("I-003") or its uid. Output: one JSON line per call; "kept_user" lists fields left alone because
the user edited them. Errors: {"ok": false, "error": …} on stdout, the message on stderr, exit 1 (bad arguments or
data) or 3 (items.json stayed locked for $BLURT_LOCK_TIMEOUT s, default 15).
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (BLURT_HOME, FIX_STATES, apply_user_ops, file_etag, find_item, item_uid,  # noqa: E402
                     items_lock, legacy_uid, load_session, new_ulid, removed_into, save_session, session_name)

PROTECTED = {"id", "uid", "_user", "_removed", "fix", "fix_history", "schema"}
SCHEMA = 2
EXIT_LOCKED = 3


def fail(msg: str, code: int = 1):
    print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False), flush=True)
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def emit(out: dict) -> None:
    print(json.dumps(out, ensure_ascii=False), flush=True)


def parse_value(raw: str):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def read(session: Path) -> dict:
    try:
        data = load_session(session)
    except ValueError as e:
        fail(f"{session / 'items.json'}: not valid JSON ({e})")
    if data is None:
        fail(f"{session}: no items.json yet — write it first (§3), then use items.py")
    if not isinstance(data, dict) or not isinstance(data.get("items", []), list):
        fail(f"{session / 'items.json'}: expected an object with an \"items\" list")
    return data


def update(session: Path, fn, *, agent: bool = True, uids: bool = True, schema: bool = True) -> dict:
    """Read-modify-write under the session lock. agent: stamp agent_at (the page tells "still working" from
    "stalled" by it). uids: give every item its uid first. schema: mark the file "schema": 2. user-ops passes
    none of them, so its result is byte for byte what review.py writes for the same ops."""
    try:
        with items_lock(session, timeout=float(os.environ.get("BLURT_LOCK_TIMEOUT") or 15)):
            data = read(session)
            if uids:
                ensure_uids(session, data)
            out = fn(data)
            write = out.pop("_write", True)
            if write:
                if agent:
                    data["agent_at"] = round(time.time(), 1)
                if schema and not (isinstance(data.get("schema"), int) and data["schema"] >= SCHEMA):
                    data = {"schema": SCHEMA, **{k: v for k, v in data.items() if k != "schema"}}
                save_session(session, data)
                if out.pop("_etag", False):
                    out["etag"] = file_etag((session / "items.json").read_bytes())
    except TimeoutError as e:
        fail(str(e), EXIT_LOCKED)
    emit(out)
    if write:
        reindex(session)
    return out


def reindex(session: Path) -> None:
    """Best effort: keep ~/.blurt/index.db fresh (contract C2). Only when an index exists — nobody reads it
    otherwise — and never at the cost of the write that already happened."""
    home = Path(os.environ.get("BLURT_HOME") or BLURT_HOME)
    if os.environ.get("BLURT_NO_INDEX") or not (home / "index.db").is_file():
        return
    try:
        import index  # noqa: PLC0415 — skills/blurt/scripts/index.py (WP2)
        with contextlib.redirect_stdout(io.StringIO()):
            index.update_sessions([Path(session).resolve()])
    except (Exception, SystemExit):
        pass


# ------------------------------------------------------------------ uid
def with_uid(session: Path, item: dict) -> dict:
    if item.get("uid") or not item.get("id"):
        return item
    return {"id": item["id"], "uid": item_uid(session, item), **{k: v for k, v in item.items() if k != "id"}}


def ensure_uids(session: Path, data: dict) -> int:
    """Items written before v2 get their legacy uid (the value index.py computes for them), right after "id"."""
    items = data.get("items", [])
    n = 0
    for k, item in enumerate(items):
        if isinstance(item, dict) and item.get("id") and not item.get("uid"):
            items[k] = with_uid(session, item)
            n += 1
    return n


def resolve_id(session: Path, data: dict, ref: str) -> str:
    """ID or uid → item id. Unknown refs come back unchanged (callers report "no item")."""
    if ref == "." or find_item(data, ref) is not None or removed_into(data, ref) is not None:
        return ref
    items = [i for i in data.get("items", []) if isinstance(i, dict)]
    hit = next((i["id"] for i in items if i.get("id") and item_uid(session, i) == ref), None)
    if hit:
        return hit
    name = session_name(session)  # an item the user merged away can still be addressed by its legacy uid
    gone = list(data.get("_removed") or {}) + [m for i in items for m in i.get("merged_from") or []]
    return next((g for g in gone if legacy_uid(name, g) == ref), ref)


# ------------------------------------------------------------------ agent writes
def apply_fields(target: dict, sets: dict, unsets: list[str], force: bool) -> dict:
    user = target.get("_user") or {}
    written, kept = [], []
    for k, v in sets.items():
        if k in PROTECTED:
            fail(f"can't set {k}" + (" — use items.py fix" if k.startswith("fix") else ""))
        if k in user and not force:
            kept.append(k)
            continue
        target[k] = v
        written.append(k)
    for k in unsets:
        if k in PROTECTED:
            fail(f"can't unset {k}")
        if k in user and not force:
            kept.append(k)
        elif k in target:
            del target[k]
            written.append(k)
    return {"written": written, **({"kept_user": kept} if kept else {})}


def skipped(data: dict, item_id: str) -> dict:
    into = removed_into(data, item_id)
    if into is None:
        fail(f"no item {item_id}")
    return {"ok": True, "id": item_id, "skipped": f"merged into {into}" if into else "removed by the user",
            "_write": False}


def patch(data: dict, item_id: str, sets: dict, unsets: list[str], force: bool) -> dict:
    if item_id == ".":
        return {"ok": True, "id": ".", **apply_fields(data, sets, unsets, force)}
    item = find_item(data, item_id)
    if item is None:
        return skipped(data, item_id)
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
            fail(f"{f['path']}: no such file in {session}")
    item = find_item(data, item_id)
    redirected = None
    if item is None:
        into = removed_into(data, item_id)
        if into is None:
            fail(f"no item {item_id}")
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
        fail("--json must be an object with at least kind and title")
    items = data.setdefault("items", [])
    gone = data.get("_removed") or {}
    taken = {i.get("id") for i in items} | set(gone)
    if item.get("id"):
        if item["id"] in taken:
            fail(f"id {item['id']} is taken (or was merged away by the user) — omit id to get a new one")
    else:
        nums = [(m.group(1), int(m.group(2))) for x in taken if x and (m := re.fullmatch(r"(.*?)(\d+)", x))]
        prefix = max(nums, key=lambda p: p[1])[0] if nums else "I-"
        width = max((len(x) - len(prefix) for x in taken if x and x.startswith(prefix)), default=3)
        item["id"] = f"{prefix}{max((n for _, n in nums), default=0) + 1:0{width}d}"
    uid = item.get("uid")
    if uid and (not isinstance(uid, str) or uid in {i.get("uid") for i in items}):
        fail(f"uid {uid!r} is taken or not a string — omit uid to get a new one")
    item = {"id": item["id"], "uid": uid or new_ulid(), **{k: v for k, v in item.items() if k not in ("id", "uid")}}
    item.setdefault("status", "draft")
    item.pop("_user", None)
    pos = next((k + 1 for k, i in enumerate(items) if i.get("id") == after), len(items)) if after else len(items)
    items.insert(pos, item)
    out = {"ok": True, "id": item["id"], "uid": item["uid"]}
    if data.get("reviewed"):
        out["note"] = "the user already finished the review; mention the new item to them"
    return out


def done(data: dict) -> dict:
    data.pop("processing", None)
    live = [i for i in data.get("items", []) if i.get("status") != "deleted"]
    missing = [i["id"] for i in live if not i.get("frames")]
    return {"ok": True, "items": len(live), **({"no_frames": missing} if missing else {}),
            **({"reviewed": True} if data.get("reviewed") else {})}


def fix(data: dict, item_id: str, state: str, given: dict) -> dict:
    """fix = the current attempt; fix_history = earlier ones, oldest first. A new state pushes the current fix
    onto fix_history; the same state again only updates the current fix (e.g. adding --commit or --pr).
    agent / run_id: flag, else $BLURT_AGENT / $BLURT_RUN_ID, else carried over from a "fixing" fix (the run
    that started it is finishing it), else "human" / null."""
    item = find_item(data, item_id)
    if item is None:
        return skipped(data, item_id)
    env = {"agent": os.environ.get("BLURT_AGENT") or None, "run_id": os.environ.get("BLURT_RUN_ID") or None}
    given = {k: v for k, v in given.items() if v is not None}
    for k, v in env.items():
        if v and k not in given:
            given[k] = v
    prev = item.get("fix") if isinstance(item.get("fix"), dict) else None
    now = round(time.time(), 1)
    if prev and prev.get("state") == state:
        new = {**prev, **given, "at": now}
    else:
        if prev:
            item.setdefault("fix_history", []).append(prev)
        carry = prev if prev and prev.get("state") == "fixing" else {}
        new = {"state": state, "agent": given.get("agent") or carry.get("agent") or "human",
               "run_id": given.get("run_id") or carry.get("run_id"), "commit": given.get("commit"),
               "pr": given.get("pr"), "note": given.get("note") or "", "at": now}
    item["fix"] = new
    out = {"ok": True, "id": item_id, "uid": item["uid"], "fix": new}
    if item.get("status") == "deleted":
        out["note"] = "the user dropped this item"
    return out


# ------------------------------------------------------------------ the user's writes (desktop apps)
OP_KINDS = {"set", "remove", "add"}


def parse_ops(raw: str) -> list[dict]:
    try:
        ops = json.loads(raw)
    except ValueError as e:
        fail(f"ops: not valid JSON ({e})")
    if isinstance(ops, dict) and isinstance(ops.get("ops"), list):  # the review page's POST body, as is
        ops = ops["ops"]
    if not isinstance(ops, list):
        fail("ops: expected a JSON list of ops")
    for n, op in enumerate(ops):
        ok = isinstance(op, dict) and op.get("op") in OP_KINDS
        if ok and op["op"] == "set":
            ok = isinstance(op.get("id"), str) and isinstance(op.get("set") or {}, dict) \
                 and isinstance(op.get("unset") or [], list)
        elif ok and op["op"] == "remove":
            ok = isinstance(op.get("id"), str)
        elif ok:
            ok = isinstance(op.get("item"), dict) and isinstance(op["item"].get("id"), str)
        if not ok:
            fail(f"ops[{n}]: expected {{op: set, id, set?, unset?}} | {{op: remove, id, into?}} "
                 f"| {{op: add, item: {{id, …}}, after?}}, got {json.dumps(op, ensure_ascii=False)[:200]}")
    return ops


def user_ops(data: dict, ops: list[dict], confirm: bool) -> dict:
    apply_user_ops(data, ops)
    if confirm:
        data["reviewed"] = True
    return {"ok": True, "_etag": True}


# ------------------------------------------------------------------ reads
def get(session: Path, ref: str) -> dict:
    data = read(session)
    iid = resolve_id(session, data, ref)
    item = find_item(data, iid)
    if item is None:
        into = removed_into(data, iid)
        if into is None:
            fail(f"no item {ref}")
        fail(f"{iid} was merged into {into} by the user" if into else f"{iid} was removed by the user")
    return {"ok": True, "item": with_uid(session, item), "session": str(Path(session).resolve())}


def list_items(session: Path, kinds: list[str], statuses: list[str], fix_states: list[str]) -> dict:
    data = read(session)
    out = []
    for i in data.get("items", []):
        if not isinstance(i, dict):
            continue
        st = i.get("status") or "draft"
        fs = (i.get("fix") or {}).get("state") if isinstance(i.get("fix"), dict) else None
        if kinds and i.get("kind") not in kinds:
            continue
        if (statuses and st not in statuses) or (not statuses and st == "deleted"):
            continue
        if fix_states and (fs or "none") not in fix_states:
            continue
        out.append(with_uid(session, i))
    return {"ok": True, "items": out, "session": str(Path(session).resolve())}


# ------------------------------------------------------------------ CLI
class Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse exits 2; the contract says 1 for bad arguments
        fail(f"{self.prog}: {message}")


def main(argv: list[str] | None = None):
    p = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
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
    s = sub.add_parser("add", help="add an item; prints its id and uid")
    s.add_argument("session")
    s.add_argument("--json", required=True)
    s.add_argument("--after", metavar="ID")
    s = sub.add_parser("done", help="mark processing finished")
    s.add_argument("session")
    s = sub.add_parser("get", help="one item, with its uid")
    s.add_argument("session")
    s.add_argument("id")
    s = sub.add_parser("list", help="items, optionally filtered (deleted ones only with --status deleted)")
    s.add_argument("session")
    s.add_argument("--kind", action="append", default=[])
    s.add_argument("--status", action="append", default=[], choices=["draft", "confirmed", "deleted"])
    s.add_argument("--fix-state", action="append", default=[], choices=[*FIX_STATES, "none"])
    s = sub.add_parser("fix", help="record a fix attempt (state, agent, commit, pr, note)")
    s.add_argument("session")
    s.add_argument("id")
    s.add_argument("--state", required=True, choices=FIX_STATES)
    s.add_argument("--agent", help="agents.json id, or 'human'")
    s.add_argument("--run-id")
    s.add_argument("--commit")
    s.add_argument("--pr")
    s.add_argument("--note")
    s = sub.add_parser("user-ops", help="apply the user's edits (same as the review page's POST /api/items)")
    s.add_argument("session")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--json", metavar="OPS")
    g.add_argument("--stdin", action="store_true")
    s.add_argument("--confirm", action="store_true", help="the user finished the review (reviewed: true)")
    s = sub.add_parser("ensure-uids", help="write a uid into every item that has none")
    s.add_argument("session")
    a = p.parse_args(argv)
    session = Path(a.session)

    if a.cmd == "patch":
        sets = {}
        for kv in a.set:
            k, eq, v = kv.partition("=")
            if not eq or not k:
                fail(f"--set {kv!r}: expected KEY=VALUE")
            sets[k] = parse_value(v)
        update(session, lambda d: patch(d, resolve_id(session, d, a.id), sets, a.unset, a.force))
    elif a.cmd == "set-frames":
        frames = [parse_frame(f) for f in a.frames]
        update(session, lambda d: set_frames(session, d, resolve_id(session, d, a.id), frames, a.append, a.force))
    elif a.cmd == "add":
        try:
            item = json.loads(a.json)
        except ValueError as e:
            fail(f"--json: {e}")
        update(session, lambda d: add(d, item, resolve_id(session, d, a.after) if a.after else None))
    elif a.cmd == "done":
        update(session, done)
    elif a.cmd == "get":
        emit(get(session, a.id))
    elif a.cmd == "list":
        emit(list_items(session, a.kind, a.status, a.fix_state))
    elif a.cmd == "fix":
        given = {"agent": a.agent, "run_id": a.run_id, "commit": a.commit, "pr": a.pr, "note": a.note}
        update(session, lambda d: fix(d, resolve_id(session, d, a.id), a.state, given))
    elif a.cmd == "user-ops":
        if a.stdin:
            raw = sys.stdin.buffer.read().decode("utf-8-sig")
        elif a.json is not None:
            raw = a.json
        elif a.confirm:
            raw = "[]"
        else:
            fail("user-ops: pass --json OPS or --stdin")
        ops = parse_ops(raw)
        update(session, lambda d: user_ops(d, ops, a.confirm), agent=False, uids=False, schema=False)
    elif a.cmd == "ensure-uids":
        def ensure(d):
            n = ensure_uids(session, d)
            return {"ok": True, "assigned": n, "_write": n > 0 or d.get("schema") != SCHEMA}
        update(session, ensure, agent=False, uids=False)


if __name__ == "__main__":
    main()
