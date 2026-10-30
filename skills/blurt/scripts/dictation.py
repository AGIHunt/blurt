# /// script
# requires-python = ">=3.10"
# ///
"""Dictation history ($BLURT_HOME/dictation/history.jsonl, written by the macOS app; docs/design/dictation.md).

  dictation.py list [--query TEXT] [--days N] [--limit N]   → {"ok", "entries": [...]} newest first, edits applied
  dictation.py item ID [--project ID|inbox] [--lang en|zh]   turn one dictation into an item (items.py add, no agent)
                                                            → {"ok", "item": {"id","uid","title","kind","project","path"}}
  dictation.py prune [--days N]                             drop entries older than N days (record.dictation.retention_days,
                                                            30), and their audio, and any recording in audio/ no entry
                                                            keeps that is over an hour old → {"ok", "removed"}

The file is append-only: an entry per dictation, then edit lines applied in order —
{"op":"delete","ids":[…]}, {"op":"item","id","item","uid"}, {"op":"clear"}, {"op":"correct","id","text"} (→ "corrected"). `prune` rewrites it compacted.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import BLURT_HOME, global_config  # noqa: E402

DIR = BLURT_HOME / "dictation"
HISTORY = DIR / "history.jsonl"


class Fail(Exception):
    def __init__(self, message: str, code: str = "error"):
        super().__init__(message)
        self.code = code


def _time(e: dict) -> datetime:
    try:
        t = datetime.fromisoformat(str(e.get("t")).replace("Z", "+00:00"))
        return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.fromtimestamp(0, timezone.utc)


def load(path: Path = HISTORY) -> list[dict]:
    """Entries, newest first, with the edit lines applied."""
    order: list[str] = []
    by_id: dict[str, dict] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for ln in lines:
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        op = o.get("op")
        if op == "delete":
            for i in o.get("ids") or []:
                by_id.pop(i, None)
        elif op == "clear":
            by_id, order = {}, []
        elif op == "item":
            if o.get("id") in by_id:
                by_id[o["id"]].update({"item": o.get("item"), "item_uid": o.get("uid")})
        elif op == "correct":       # the user's corrected text (the Dictation page): kept as "corrected" on the entry
            if o.get("id") in by_id and isinstance(o.get("text"), str):
                by_id[o["id"]]["corrected"] = o["text"]
        elif isinstance(o.get("id"), str) and isinstance(o.get("raw"), str):
            if o["id"] not in by_id:
                order.append(o["id"])
            by_id[o["id"]] = o
    return sorted((by_id[i] for i in order if i in by_id), key=_time, reverse=True)


@contextmanager
def exclusive(path: Path = HISTORY):
    """One writer of history.jsonl at a time, with the app (DictationHistory.exclusive): an advisory flock on
    .history.lock beside it, so an append never lands between a prune's read and its rewrite."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path.parent / ".history.lock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def append(o: dict, path: Path = HISTORY) -> None:
    with exclusive(path):
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (json.dumps(o, ensure_ascii=False, sort_keys=True) + "\n").encode())
        finally:
            os.close(fd)


def retention_days() -> int:
    d = ((global_config().get("record") or {}).get("dictation") or {}).get("retention_days")
    return int(d) if isinstance(d, (int, float)) and d >= 0 else 30


TAKE_WAV = re.compile(r"d-\d{8}-\d{6}-[0-9a-f]{4}\.wav")


def prune_orphan_audio(entries: list[dict], path: Path = HISTORY, min_age: float = 3600,
                       now: float | None = None, days: int | None = None) -> list[str]:
    """Recordings in audio/ (a take's <id>.wav, its streamed pieces <id>-pN.wav) that no entry keeps: a take dropped,
    cancelled, or cut short by a quit or a crash. Only those older than `min_age` (a take still running is never that
    old); the Lab's own recordings (dictation/lab/) are not here. A take's own recording younger than `days` stays:
    the app turns it into an "interrupted" entry with Retry (DictationHistory.recoverInterrupted). The same rule as
    DictationHistory.pruneOrphanAudio."""
    audio = path.parent / "audio"
    if not audio.is_dir():
        return []
    kept = {(path.parent / e["audio"]).resolve() for e in entries if isinstance(e.get("audio"), str)}
    now = now or time.time()
    gone = []
    for f in sorted(audio.glob("*.wav")):
        age = now - f.stat().st_mtime
        if f.resolve() in kept or age < min_age:
            continue
        if days is not None and TAKE_WAV.fullmatch(f.name) and age < days * 86400:
            continue
        f.unlink(missing_ok=True)
        gone.append(f.name)
    return gone


def prune(days: int, path: Path = HISTORY, now: datetime | None = None) -> int:
    with exclusive(path):
        return _prune(days, path, now)


def _prune(days: int, path: Path, now: datetime | None) -> int:
    entries = load(path)
    prune_orphan_audio(entries, path, days=days)
    if not path.exists():
        return 0
    cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=days)
    keep = [e for e in entries if _time(e) >= cutoff]
    drop = [e for e in entries if _time(e) < cutoff]
    for e in drop:
        if isinstance(e.get("audio"), str):
            (path.parent / e["audio"]).unlink(missing_ok=True)
    out = []
    for e in reversed(keep):
        extra = {k: e.pop(k) for k in ("item", "item_uid") if k in e}
        out.append(json.dumps(e, ensure_ascii=False, sort_keys=True))
        if extra.get("item"):
            out.append(json.dumps({"op": "item", "id": e["id"], "item": extra["item"], "uid": extra.get("item_uid")},
                                  ensure_ascii=False, sort_keys=True))
    tmp = path.with_suffix(".tmp")
    tmp.write_text("".join(x + "\n" for x in out), encoding="utf-8")
    os.replace(tmp, path)
    return len(drop)


def make_item(entry_id: str, project: str | None, lang: str | None) -> dict:
    """A dictation → an item, the way a captured note becomes one (captures.py): title = its first sentence,
    quote = the whole text, kind = the keyword guess, enrich: pending (AI fill-in can add the rest)."""
    import captures  # noqa: PLC0415
    import items  # noqa: PLC0415
    e = next((x for x in load() if x["id"] == entry_id), None)
    if not e:
        raise Fail(f"no dictation {entry_id}", "not_found")
    if e.get("item"):
        return {"id": e["item"], "uid": e.get("item_uid"), "already": True}
    text = (e.get("corrected") or e.get("text") or e.get("raw") or "").strip()
    if not text:
        raise Fail("this dictation has no text", "empty")
    fields = {"kind": captures.guess_kind(text), "title": captures.first_sentence(text), "quote": text,
              "source": {"type": "dictation", "app": e.get("app"), "dictation": e["id"]}, "enrich": "pending"}
    if e.get("language"):
        fields["language"] = e["language"]
    pid = items.resolve_project(project or "inbox")
    r = items.add(None, pid, fields, None)
    items.reindex_touched()
    append({"op": "item", "id": e["id"], "item": r["id"], "uid": r["uid"],
            "t": datetime.now().astimezone().isoformat(timespec="seconds")})
    return {"id": r["id"], "uid": r["uid"], "title": fields["title"], "kind": fields["kind"], "project": pid, "path": r["path"]}


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("list")
    s.add_argument("--query")
    s.add_argument("--days", type=float)
    s.add_argument("--limit", type=int, default=0)
    s = sub.add_parser("item")
    s.add_argument("id")
    s.add_argument("--project")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    s = sub.add_parser("prune")
    s.add_argument("--days", type=int)
    a = p.parse_args(argv)
    try:
        if a.cmd == "list":
            es = load()
            if a.days is not None:
                cut = datetime.now(timezone.utc) - timedelta(days=a.days)
                es = [e for e in es if _time(e) >= cut]
            if a.query:
                q = a.query.lower()
                es = [e for e in es if any(q in str(e.get(k) or "").lower() for k in ("text", "raw", "polished", "app"))]
            out = {"ok": True, "entries": es[:a.limit] if a.limit else es}
        elif a.cmd == "item":
            out = {"ok": True, "item": make_item(a.id, a.project, a.lang)}
        else:
            out = {"ok": True, "removed": prune(a.days if a.days is not None else retention_days())}
    except Fail as e:
        out = {"ok": False, "error": str(e), "code": e.code}
    except Exception as e:  # noqa: BLE001 — items.py's own errors carry a code
        out = {"ok": False, "error": str(e), "code": getattr(e, "code", "error")}
    print(json.dumps(out, ensure_ascii=False), flush=True)
    if not out.get("ok"):
        sys.exit(1)


if __name__ == "__main__":
    main()
