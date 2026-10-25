# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp==1.26.0", "pillow==12.1.0"]
# ///
"""The blurt MCP server (contract C4, v0.7 behaviour in K1): lets any coding agent browse the user's Blurt items —
projects, sessions, items with their screenshots, transcripts — and report work on them. stdio transport, official
`mcp` SDK (FastMCP; pinned < 2, where FastMCP was renamed).

  uv run --script mcp_server.py            serve on stdio (what agents launch)

Register it: `agents.py install <agent> --mcp` (claude / codex / kimi / opencode), or by hand, e.g.
  claude mcp add --scope user blurt -- uv run --script <this file>
  codex mcp add blurt -- uv run --script <this file>

Reads go through index.py's index.db (built on first use) and the item files; every write goes through items.py
(locked, keeps the user's own edits), never straight to a file. The 7 tools keep their v0.6 names and parameters;
bundle_items (export_local.py bundle) packs items into a hand-off .zip for the agent to send with its own tools.
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
import items as items_mod  # noqa: E402
from _common import OPEN_STATES, STATES, load_json  # noqa: E402
from mcp.server.fastmcp import FastMCP  # noqa: E402
from mcp.types import ImageContent, TextContent  # noqa: E402

ITEMS_PY = SCRIPTS / "items.py"
MAX_SIDE = 1280
WRITE_RULE = ("Change items only with update_item / mark_fixed (or `items.py`); never write the item files "
              "(.blurt/items/*.md), items.json or anything else under .blurt/ or ~/Blurt yourself — the user may be "
              "editing the same item.")
DONE_RULE = ("When you say an item is fixed it goes to \"to verify\": it is done only once the user confirms it. "
             "Only the user keeps, finishes, declines (won't do) or discards items.")
STATE_HELP = ("state (one per item): new (the user hasn't looked yet) | todo | handed_off | in_progress | to_verify "
              "(an agent says it's finished; waits for the user) | done | wontfix | discarded. The user's inbox is new "
              "+ to_verify.")
MARK_STATES = {"fixing": ("in_progress", None), "fixed": ("to_verify", "fixed"), "wontfix": ("to_verify", "wontfix"),
               "reopened": ("todo", None)}

mcp = FastMCP("blurt", instructions=(
    "Blurt holds the user's captured work — narrated screen recordings, screenshots, voice notes — turned into items "
    "(issue / idea / note / task) and filed into projects. Find items with search_items or list_sessions, read one "
    "with get_item (it shows its screenshots), and when you work on one, call mark_fixed(uid, state='fixing') first "
    "and mark_fixed(uid, state='fixed', note=…) after. To pass items to someone (a teammate, a chat, a tracker), "
    "bundle_items packs them into one .zip and you send it with the tools you already have. " + DONE_RULE + " "
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


def _project(project: str | None) -> str | None:
    if not project:
        return None
    con = _db()
    try:
        return index.resolve_project(con, project)
    finally:
        con.close()


def _session_dir(session: str) -> Path:
    con = _db()
    try:
        sid = index.resolve_session(con, session)
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
    p = subprocess.run([sys.executable, str(ITEMS_PY), *args], capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=dict(os.environ), stdin=subprocess.DEVNULL, timeout=60)
    line = next((ln for ln in reversed(p.stdout.splitlines()) if ln.strip().startswith("{")), "")
    try:
        out = json.loads(line) if line else {}
    except ValueError:
        out = {}
    if p.returncode != 0:
        msg = out.get("error") or p.stderr.strip().removeprefix("ERROR: ") or f"items.py exit {p.returncode}"
        raise ValueError(msg)
    return out


def _known(uid: str) -> None:
    """A uid the store knows. An item still in a v0.6 session (the index shows it, the app hasn't migrated it yet)
    gets its session migrated first; an index that is behind is rescanned once."""
    if items_mod.find_path(uid) is not None:
        return
    rows = _rows("SELECT i.path, s.dir FROM items i LEFT JOIN sessions s ON s.id = i.session_id WHERE i.uid = ?", (uid,))
    if rows and "#" in rows[0]["path"]:
        _items_py("migrate", rows[0]["dir"] or str(Path(rows[0]["path"].split("#")[0]).parent))
    elif not rows:
        index.scan()
    if items_mod.find_path(uid) is None:
        raise ValueError(f"no item with uid {uid!r} — find uids with search_items")


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
    """The user's projects (folders opened in Blurt) and the inbox ("inbox": captures not filed into a project yet).
    open_items = items in state new, todo, handed_off or in_progress (not finished yet). unassigned = for the inbox,
    its items; for a project, inbox items the AI suggested for it."""
    rows = _rows(
        "SELECT p.id, p.name, p.key, p.path, p.kind, "
        "(SELECT COUNT(*) FROM items i WHERE i.project_id = p.id AND i.state IN "
        f"({','.join('?' * len(OPEN_STATES))})) AS open_items, "
        "CASE WHEN p.id = 'inbox' THEN (SELECT COUNT(*) FROM items i WHERE i.project_id = 'inbox' AND "
        "i.state != 'discarded') ELSE (SELECT COUNT(*) FROM items i WHERE i.project_id = 'inbox' AND "
        "i.state != 'discarded' AND i.suggested_project = p.id) END AS unassigned "
        "FROM projects p ORDER BY p.kind = 'inbox', p.name", OPEN_STATES)
    return rows


@mcp.tool()
def list_sessions(project: str | None = None, state: str | None = None, limit: int = 20) -> list[dict]:
    """Capture sessions (recordings, screenshot batches, voice notes), newest first. project = a list_projects id,
    name, key or folder. state: "unprocessed" (no items yet), "processing" (an agent is still writing them),
    "unreviewed" (items ready, the user hasn't confirmed), "reviewed"."""
    where, args = [], []
    pid = _project(project)
    if pid:
        where.append("project_id = ?")
        args.append(pid)
    cond = {"unprocessed": "processed = 0", "processing": "processing = 1",
            "unreviewed": "processed = 1 AND processing = 0 AND reviewed = 0", "reviewed": "reviewed = 1"}
    if state:
        if state not in cond:
            raise ValueError(f"state must be one of {', '.join(cond)}")
        where.append(cond[state])
    sql = ("SELECT id, project_id, dir, mode, title, created, item_count, processed, reviewed FROM sessions"
           + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY created DESC LIMIT ?")
    rows = _rows(sql, args + [int(limit)])
    for r in rows:
        r["processed"], r["reviewed"] = bool(r["processed"]), bool(r["reviewed"])
    return rows


@mcp.tool()
def search_items(query: str | None = None, project: str | None = None, kind: list[str] | None = None,
                 status: list[str] | None = None, fix_state: list[str] | None = None, limit: int = 20,
                 work_state: list[str] | None = None, state: list[str] | None = None) -> list[dict]:
    """Search items across all projects (full text over title, quote, body, tags; Chinese works). kind: issue | idea
    | note | task | a custom lens; state: [states] (default: all but discarded). status / work_state / fix_state are
    older filters, still accepted. Returns ItemRows with the uid to pass to get_item / mark_fixed."""
    bad = [x for x in state or [] if x not in STATES]
    if bad:
        raise ValueError(f"unknown state {bad[0]!r}: " + STATE_HELP)
    con = _db()
    try:
        pid = index.resolve_project(con, project) if project else None
        return index.search(query, kind, status, work_state, pid, None, "updated", int(limit), 0, con=con,
                            fix_state=fix_state, state=state)["items"]
    finally:
        con.close()


@mcp.tool(structured_output=False)
def get_item(uid: str, include_frames: bool = True, max_frames: int = 3) -> list:
    """One item in full (JSON, every path absolute; `path` is its Markdown file, `project` its project) plus up to
    max_frames of its screenshots (JPEG, long side ≤ 1280 px; the first is the primary one). Look at them — they are
    the evidence."""
    _known(uid)
    out = _items_py("get", uid)
    item = out["item"]
    session = Path(out["session"]) if out.get("session") else None
    batch = load_json(session / "batch.json", {}) if session else {}
    meta = load_json(session / "meta.json", {}) if session else {}
    video = (batch or {}).get("source_video")
    doc = {"item": item, "session": str(session) if session else None,
           "session_title": (batch or {}).get("title"), "language": item.get("language") or (batch or {}).get("language"),
           "source_video": _abs(session, video) if session and video else None,
           "author": (meta or {}).get("author"), "how_to_change": WRITE_RULE + " " + DONE_RULE}
    content: list = [TextContent(type="text", text=json.dumps(doc, ensure_ascii=False, indent=1))]
    if include_frames:
        frames = [f for f in item.get("frames") or [] if isinstance(f, dict) and f.get("path")]
        for f in frames[:max(0, min(int(max_frames), 10))]:
            data = _jpeg(Path(f["path"]))
            if data:
                content.append(ImageContent(type="image", data=base64.b64encode(data).decode(), mimeType="image/jpeg"))
    return content


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
            for k in ("speaker", "language"):
                if s.get(k) is not None:
                    row[k] = s[k]
            segs.append(row)
        return segs
    return [{"start": s.get("t"), "end": None, "text": s.get("said") or s.get("text") or "", "shot": s.get("n"),
             "file": _abs(d, s.get("file"))} for s in index.read_shots(d) if s.get("said") or s.get("text")]


@mcp.tool(description=(
    "Change fields of an item (same as `items.py patch`): set = {field: value}, unset = [field]. Fields the user "
    "edited on the review page are kept (listed in kept_user) — tell the user instead of forcing them. Its project "
    "and state have their own commands (mark_fixed). " + WRITE_RULE))
def update_item(uid: str, set: dict, unset: list[str] | None = None) -> dict:
    _known(uid)
    args = ["patch", uid]
    for k, v in (set or {}).items():
        args += ["--set", f"{k}={json.dumps(v, ensure_ascii=False)}"]
    for k in unset or []:
        args += ["--unset", k]
    return _items_py(*args)


@mcp.tool(description=(
    "Report your work on an item: state = fixing (call it when you start) | fixed | wontfix | reopened. note = one "
    "line on what changed (or why not); commit / pr if there is one. " + DONE_RULE + " fixed and wontfix are your "
    "claim, shown to the user as \"to verify\"; reopened takes your claim back. agent defaults to $BLURT_AGENT. The "
    "Blurt app shows it to the user right away. " + STATE_HELP + " " + WRITE_RULE))
def mark_fixed(uid: str, state: str = "fixed", commit: str | None = None, pr: str | None = None,
               note: str | None = None, agent: str | None = None) -> dict:
    if state not in MARK_STATES:
        raise ValueError("state must be fixing | fixed | wontfix | reopened")
    _known(uid)
    to, claim = MARK_STATES[state]
    args = ["state", uid, "--state", to, "--by", "agent"]
    for flag, v in (("--claim", claim), ("--commit", commit), ("--pr", pr), ("--note", note),
                    ("--agent", agent or os.environ.get("BLURT_AGENT") or "mcp")):
        if v:
            args += [flag, v]
    out = _items_py(*args)
    w = (out.get("items") or [{}])[0]
    return {"ok": True, "uid": uid, "id": w.get("id"), "state": w.get("state"), "work": w.get("work"),
            **({"note": w["note"]} if w.get("note") else {}),
            "next": "the user verifies it" if to == "to_verify" else None}


@mcp.tool(description=(
    "Pack items into one hand-off bundle: a self-contained .zip (summary.md with counts by kind and state and one "
    "section per item — state, what the user said, steps, suspected code, screenshots inline — plus items/*.md with "
    "every field, frames/ and clips/), relative paths only, so it opens on a teammate's machine. Named "
    "\"<project>-<date>-<n items>.zip\". Pass uids (from search_items), or a filter: project (+ state, kind; default "
    "every state but discarded). Grouping is yours: for \"the A module's issues for Zhang San\" pick those items and "
    "call once per group; title names the bundle (e.g. \"Payment issues for Zhang San\"). out_dir = an absolute "
    "folder or path ending in .zip (default: the project's .blurt/exports/). Returns the zip's absolute path and "
    "`summary`, one "
    "paragraph to paste next to the file. Blurt sends nothing anywhere: post or upload the zip with the tool you "
    "already have for that destination (Slack, Feishu/Lark, Notion, Google Drive, Linear, GitHub, email…), after the "
    "user confirms where. No item changes state."))
def bundle_items(uids: list[str] | None = None, project: str | None = None, state: list[str] | None = None,
                 kind: list[str] | None = None, title: str | None = None, out_dir: str | None = None,
                 lang: str | None = None) -> dict:
    import export_local  # noqa: PLC0415
    if not uids and not project:
        raise ValueError("pass uids, or project (+ state / kind)")
    for u in uids or []:
        _known(u)
    try:
        out = export_local.bundle_items(uids or None, _project(project) if project else None, state or None,
                                        kind or None, out_dir, title, lang)
    except export_local.BundleError as e:
        raise ValueError(str(e)) from None
    keep = ("path", "name", "title", "items", "kinds", "states", "uids", "bytes", "summary", "missing")
    return {k: out[k] for k in keep}


def main() -> None:
    mcp.run()  # stdio


if __name__ == "__main__":
    main()
