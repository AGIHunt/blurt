# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.20,<2", "pillow"]
# ///
"""The blurt MCP server (contract C4): lets any coding agent browse the user's Blurt recordings — projects,
sessions, items with their screenshots, transcripts — and record fixes. stdio transport, official `mcp` SDK
(FastMCP; pinned < 2, where FastMCP was renamed).

  uv run --script mcp_server.py            serve on stdio (what agents launch)

Register it: `agents.py install <agent> --mcp` (claude / codex / kimi / opencode), or by hand, e.g.
  claude mcp add --scope user blurt -- uv run --script <this file>
  codex mcp add blurt -- uv run --script <this file>

Reads go through index.py's index.db (built on first use) and the session files; every write goes through
items.py (locked, keeps the user's own edits), never straight to a file.
"""
from __future__ import annotations

import base64
import io
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import index  # noqa: E402
from _common import load_json  # noqa: E402
from mcp.server.fastmcp import FastMCP  # noqa: E402
from mcp.types import ImageContent, TextContent  # noqa: E402

ITEMS_PY = SCRIPTS / "items.py"
MAX_SIDE = 1280
WRITE_RULE = ("Change items only with update_item / mark_fixed (or `items.py`); never write items.json or other "
              "files under .blurt/ or ~/Blurt yourself — the user may be editing the same file.")

mcp = FastMCP("blurt", instructions=(
    "Blurt holds the user's narrated screen recordings and screenshots, turned into items (issue / idea / note / "
    "task). Find items with search_items or list_sessions, read one with get_item (it shows its screenshots), and "
    "when you fix one, call mark_fixed(uid, state='fixing') first and mark_fixed(uid, state='fixed', note=…) after. "
    + WRITE_RULE))


# ------------------------------------------------------------------ helpers
def _db():
    index.ensure_index()
    return index.connect(readonly=True)


def _rows(sql: str, args=()) -> list[dict]:
    con = _db()
    try:
        return [dict(r) for r in con.execute(sql, args)]
    finally:
        con.close()


def _workspace(project: str | None) -> str | None:
    if not project:
        return None
    con = _db()
    try:
        return index._resolve(con, "workspaces", project)
    finally:
        con.close()


def _locate(uid: str) -> dict:
    """uid → {session_dir, item_id, session_id}; re-indexes once if the index doesn't know it yet."""
    for attempt in (0, 1):
        r = _rows("SELECT i.uid, i.item_id, i.session_id, s.dir AS session_dir FROM items i "
                  "JOIN sessions s ON s.id = i.session_id WHERE i.uid = ?", (uid,))
        if r:
            return r[0]
        if attempt == 0:
            index.scan()
    raise ValueError(f"no item with uid {uid!r} — find uids with search_items")


def _session_dir(session: str) -> Path:
    con = _db()
    try:
        sid = index._resolve(con, "sessions", session)
        r = con.execute("SELECT dir FROM sessions WHERE id = ?", (sid,)).fetchone()
    finally:
        con.close()
    if r:
        return Path(r["dir"])
    p = Path(session).expanduser()
    if p.is_dir():
        return p.resolve()
    raise ValueError(f"no session {session!r} — use list_sessions")


def _abs(session: Path, rel):
    return str((session / rel).resolve()) if isinstance(rel, str) and rel and not os.path.isabs(rel) else rel


def _items_py(*args: str) -> dict:
    env = dict(os.environ)
    p = subprocess.run([sys.executable, str(ITEMS_PY), *args], capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env, stdin=subprocess.DEVNULL, timeout=60)
    line = next((ln for ln in reversed(p.stdout.splitlines()) if ln.strip().startswith("{")), "")
    try:
        out = json.loads(line) if line else {}
    except ValueError:
        out = {}
    if p.returncode != 0:
        msg = out.get("error") or p.stderr.strip().removeprefix("ERROR: ") or f"items.py exit {p.returncode}"
        raise ValueError(msg)
    return out


def _reindex(session: Path) -> None:
    try:  # items.py does this itself (C2); repeat it so readers see the write even if that hook was skipped
        index.update_sessions([session])
    except Exception:
        pass


def _jpeg(path: Path) -> bytes | None:
    from PIL import Image
    try:
        with Image.open(path) as im:
            im = im.convert("RGB")
            im.thumbnail((MAX_SIDE, MAX_SIDE))
            buf = io.BytesIO()
            im.save(buf, "JPEG", quality=82)
            return buf.getvalue()
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------ tools
@mcp.tool()
def list_projects() -> list[dict]:
    """The places recordings live: the Blurt app's default workspace (~/Blurt) and every repo with
    .blurt/sessions. open_items = items not deleted and not fixed / wontfix."""
    return _rows(
        "SELECT w.id, w.name, w.path, w.kind, COUNT(DISTINCT s.id) AS sessions, "
        "(SELECT COUNT(*) FROM items i JOIN sessions s2 ON s2.id = i.session_id WHERE s2.workspace_id = w.id AND "
        " i.status != 'deleted' AND (i.fix_state IS NULL OR i.fix_state IN ('fixing', 'reopened'))) AS open_items "
        "FROM workspaces w LEFT JOIN sessions s ON s.workspace_id = w.id GROUP BY w.id ORDER BY w.kind, w.name")


@mcp.tool()
def list_sessions(project: str | None = None, state: str | None = None, limit: int = 20) -> list[dict]:
    """Recording sessions, newest first. project = a list_projects id, name or path. state: "unprocessed" (no items
    yet), "processing" (an agent is still writing them), "unreviewed" (items ready, the user hasn't confirmed),
    "reviewed"."""
    where, args = [], []
    ws = _workspace(project)
    if ws:
        where.append("workspace_id = ?")
        args.append(ws)
    cond = {"unprocessed": "processed = 0", "processing": "processing = 1",
            "unreviewed": "processed = 1 AND processing = 0 AND reviewed = 0", "reviewed": "reviewed = 1"}
    if state:
        if state not in cond:
            raise ValueError(f"state must be one of {', '.join(cond)}")
        where.append(cond[state])
    sql = ("SELECT id, dir, mode, title, created, item_count, processed, reviewed FROM sessions"
           + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY created DESC LIMIT ?")
    rows = _rows(sql, args + [int(limit)])
    for r in rows:
        r["processed"], r["reviewed"] = bool(r["processed"]), bool(r["reviewed"])
    return rows


@mcp.tool()
def search_items(query: str | None = None, project: str | None = None, kind: list[str] | None = None,
                 status: list[str] | None = None, fix_state: list[str] | None = None, limit: int = 20) -> list[dict]:
    """Search items across all recordings (full text over title, quote, body, tags; Chinese works). kind: issue |
    idea | note | task | a custom lens; status: draft | confirmed | deleted (default: all but deleted); fix_state:
    fixing | fixed | wontfix | reopened | none (never handed to an agent). Returns ItemRows with the uid to pass to
    get_item / mark_fixed."""
    con = _db()
    try:
        ws = index._resolve(con, "workspaces", project) if project else None
        return index.search(query, kind, status, fix_state, ws, None, "updated", int(limit), 0, con=con)["items"]
    finally:
        con.close()


@mcp.tool(structured_output=False)
def get_item(uid: str, include_frames: bool = True, max_frames: int = 3) -> list:
    """One item in full (JSON, every path absolute) plus up to max_frames of its screenshots (JPEG, long side
    ≤ 1280 px; the first is the primary one). Look at them — they are the evidence."""
    loc = _locate(uid)
    session = Path(loc["session_dir"])
    data = load_json(session / "items.json", {}) or {}
    item = next((i for i in data.get("items", []) if index.item_uid(session.name, i) == uid), None) or \
        next((i for i in data.get("items", []) if i.get("id") == loc["item_id"]), None)
    if item is None:
        index.update_sessions([session])
        raise ValueError(f"item {uid} is no longer in {session}")
    item = json.loads(json.dumps(item))
    item["uid"] = index.item_uid(session.name, item)
    frames = [f for f in item.get("frames") or [] if isinstance(f, dict)]
    for f in frames:
        f["path"] = _abs(session, f.get("path"))
    for k in ("clip",):
        if item.get(k):
            item[k] = _abs(session, item[k])
    meta = load_json(session / "meta.json", {}) or {}
    doc = {"item": item, "session": str(session), "session_id": loc["session_id"],
           "session_title": data.get("title"), "language": data.get("language"),
           "source_video": _abs(session, data.get("source_video")) if data.get("source_video") else None,
           "author": meta.get("author"), "how_to_change": WRITE_RULE}
    out: list = [TextContent(type="text", text=json.dumps(doc, ensure_ascii=False, indent=1))]
    if include_frames:
        for f in frames[:max(0, min(int(max_frames), 10))]:
            data_ = _jpeg(Path(f["path"])) if f.get("path") else None
            if data_:
                out.append(ImageContent(type="image", data=base64.b64encode(data_).decode(), mimeType="image/jpeg"))
    return out


@mcp.tool()
def get_transcript(session: str, start: float | None = None, end: float | None = None) -> list[dict]:
    """What the user said in a session (id from list_sessions / an ItemRow, or its directory), optionally only
    the part overlapping [start, end] seconds. Screenshot sessions return each shot's note (start = null)."""
    d = _session_dir(session)
    tr = load_json(d / "transcript.json")
    if isinstance(tr, dict) and isinstance(tr.get("segments"), list):
        segs = []
        for s in tr["segments"]:
            if not isinstance(s, dict):
                continue
            a, b = s.get("start"), s.get("end")
            if start is not None and isinstance(b, (int, float)) and b < start:
                continue
            if end is not None and isinstance(a, (int, float)) and a > end:
                continue
            row = {"start": a, "end": b, "text": s.get("text", "")}
            if s.get("speaker") is not None:
                row["speaker"] = s["speaker"]
            segs.append(row)
        return segs
    return [{"start": s.get("t"), "end": None, "text": s.get("text") or "", "shot": s.get("n"),
             "file": _abs(d, s.get("file"))} for s in index.read_shots(d) if s.get("text")]


@mcp.tool(description=(
    "Change fields of an item (same as `items.py patch`): set = {field: value}, unset = [field]. Fields the user "
    "edited on the review page are kept (listed in kept_user) — tell the user instead of forcing them. " + WRITE_RULE))
def update_item(uid: str, set: dict, unset: list[str] | None = None) -> dict:
    loc = _locate(uid)
    args = ["patch", loc["session_dir"], uid]
    for k, v in (set or {}).items():
        args += ["--set", f"{k}={json.dumps(v, ensure_ascii=False)}"]
    for k in unset or []:
        args += ["--unset", k]
    out = _items_py(*args)
    _reindex(Path(loc["session_dir"]))
    return out


@mcp.tool(description=(
    "Record a fix attempt (same as `items.py fix`): state = fixing (call it when you start) | fixed | wontfix | "
    "reopened. note = one line on what changed (or why not); commit / pr if there is one. agent defaults to "
    "$BLURT_AGENT. The Blurt app shows it to the user right away. " + WRITE_RULE))
def mark_fixed(uid: str, state: str = "fixed", commit: str | None = None, pr: str | None = None,
               note: str | None = None, agent: str | None = None) -> dict:
    if state not in ("fixing", "fixed", "wontfix", "reopened"):
        raise ValueError("state must be fixing | fixed | wontfix | reopened")
    loc = _locate(uid)
    args = ["fix", loc["session_dir"], uid, "--state", state]
    for flag, v in (("--commit", commit), ("--pr", pr), ("--note", note), ("--agent", agent)):
        if v:
            args += [flag, v]
    out = _items_py(*args)
    _reindex(Path(loc["session_dir"]))
    return out


def main() -> None:
    mcp.run()  # stdio


if __name__ == "__main__":
    main()
