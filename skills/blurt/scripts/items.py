# /// script
# requires-python = ">=3.10"
# ///
"""The one writer of blurt items (contract K1 in docs/design/next-round.md): one Markdown file per item in a store
(<project>/.blurt/items/, or the inbox ~/Blurt/inbox/items/). The review page, the apps and other agents may have the
same items open: every write here is locked and atomic, and fields the user changed (listed in the item's "_user")
are kept unless you pass --force (only when the user asked for the change in chat).

Agents keep writing <session>/items.json once (SKILL.md §3); `ingest` turns it into items, and any write command
on a session ingests a pending items.json first.

REF = an item's uid | its id (BA-12, or a former id) | the path of its .md. The v2 form SESSION ID still works:
ID is the agent's draft id (I-001) or a uid; "." means the session itself (title, digest).

  ingest     SESSION                                   items.json → items + batch.json
  add        (SESSION | --project P|inbox) --json '{"kind":"issue","title":"…",…}' [--after REF]
  patch      REF | SESSION ID --set key=VALUE … [--unset key …] [--force]
             VALUE is JSON if it parses (list, object, number, true/false, "quoted"), else a plain string
  set-frames REF | SESSION ID PATH[@T][#CAPTION] … [--append]     PATH relative to SESSION, or absolute
  done       SESSION                                   processing finished (the page stops saying "still working")
  get        REF | SESSION ID                          → {"item": {…}, "session": …}; every path absolute
  list       [SESSION] [--project P|inbox] [--kind K]… [--state S]…     (--status / --work / --fix-state: old names)
  state      REF … (--state S | --action A) [--to session|external] [--agent A] [--job J] [--handoff H]
             [--claim fixed|wontfix] [--commit SHA] [--pr URL] [--note TEXT] [--by user|agent|app]
             S = new todo handed_off in_progress to_verify done wontfix discarded; A = the user's actions (keep
             hand_off done send_back take_back reopen restore wontfix discard). An agent's "done" is --state
             to_verify --claim fixed: only the user marks done, won't do, keeps or discards. `work` = old name.
  fix        REF | SESSION ID --state fixing|fixed|wontfix|reopened [--agent A] [--run-id R] [--commit] [--pr] [--note]
             v2 alias of state (fixing → in_progress, fixed / wontfix → to_verify with that claim, reopened → todo)
  move       REF … --project P|inbox [--from Q …]    the user's move (only the user moves items between projects;
             an organizing run leaves a suggested_project on Unassigned items instead). The suggestion stays on
             the item, so moving it back to Unassigned (⌘Z) shows it again. --from: only the items still in Q
             move; the rest (moved by the user since) stay and come back in "kept" (the island's Change / Undo)
  doc        SESSION | --project P|inbox [--state S]… [--kind K]… [--item REF]   what the review page shows; --item:
             that item is always in it, whatever the filters (the one a detail pane shows, a discarded one too);
             when its file can't be read it is listed in `_unreadable` [{uid, id, title, path}] instead (the page says
             so, never "gone"). The doc also carries `agents` {id: {name, desktop}} (names people know, never ids)
             and, on items with a session in the agent's desktop app, `_work_runner: "desktop"`
  poll       (as doc) --etag E                         → {"etag"} when nothing changed, else {"doc","etag"}
  user-ops   SESSION | --project P (--json OPS | --stdin) [--confirm] [--item REF]   the user's edits (apps)
  migrate    [--all [--no-projects] | SESSION … | --root DIR] [--dry-run]     v1/v2 sessions → items; --all also
             forgets the sessions unfinished items point at that no longer exist ("repaired": their files).
             --no-projects (the app, at every launch): only the v0.6 places — its recordings, the inbox, the repos it
             had bound — never the projects' own folders: a project opened later that held an old session (a scripted
             demo's items.json) got it turned into items at the next launch, unasked (v1.0.4)
  path       REF                                       → {"path","store","project","uid","id"}
  ensure-uids SESSION                                  a v2 session not ingested yet: write the missing uids

--agent / --job default to $BLURT_AGENT / $BLURT_JOB ($BLURT_RUN_ID). Output: one JSON line per call; "kept_user"
lists fields left alone because the user edited them. Errors: {"ok": false, "error", "code"} on stdout, the message
on stderr, exit 1 (bad arguments or data) or 3 (a lock stayed taken for $BLURT_LOCK_TIMEOUT s, default 15).
"""
from __future__ import annotations

import argparse
import contextlib
import getpass
import io
import json
import os
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (ACTIONS, FIX_STATES, FIX_TO_WORK, LEGACY_WORK, REVIEW_STATES, STATES, WORK_BY,  # noqa: E402
                     WORK_KEYS, WORK_TRACKED, InvalidEdit, action_target, append_job_event, blurt_home,
                     check_item_fields, file_etag, items_lock, legacy_filter_states, legacy_uid, load_json,
                     may_move, migrate_state, new_ulid, now_iso, real, state_of, to_epoch, write_text_atomic)
import store as st  # noqa: E402
from store import Store, Unparseable  # noqa: E402

PROTECTED = {"id", "uid", "_user", "_removed", "fix", "fix_history", "schema", "state", "restore_to", "work",
             "work_history", "project", "path", "store", "aliases", "created", "updated", "merged_into", "project_by",
             "_project", "_sections", "_preamble"}
BATCH_PROTECTED = {"schema", "session", "items", "local", "removed"}
# set only by items.py itself, never by a page's ops ("project" is a move, handled on its own)
SERVER_KEYS = PROTECTED - {"_removed"} | {"project_confidence", "suggested_project", "source_session", "status"}
EXIT_LOCKED = 3
UID_RE = re.compile(r"[0-9A-HJKMNP-TV-Z]{26}|L[0-9a-f]{25}")
LOCAL_RE = re.compile(r"(.*?)(\d+)")

TOUCHED: list[Path] = []  # files / dirs written by this call → index.update_paths at the end


class ItemsError(Exception):
    def __init__(self, msg: str, code: str = "bad_args", exit_code: int = 1):
        super().__init__(msg)
        self.code, self.exit_code = code, exit_code


def fail(msg: str, code: str = "bad_args", exit_code: int = 1):
    raise ItemsError(msg, code, exit_code)


def emit(out: dict) -> None:
    print(json.dumps(out, ensure_ascii=False), flush=True)


def parse_value(raw: str):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


# ------------------------------------------------------------------ stores and lookups
def all_stores() -> list[Store]:
    import projects  # noqa: PLC0415
    out = [st.inbox_store()]
    for e in projects.entries():
        s = projects.store_of(e)
        if s.exists and s not in out:
            out.append(s)
    return out


def store_for_project(pid: str) -> Store:
    import projects  # noqa: PLC0415
    try:
        return projects.store_for(pid)
    except projects.ProjectError as e:
        fail(str(e), e.code)


def resolve_project(ref: str) -> str:
    """--project P: an id, key, slug, name, folder, or inbox → the project id."""
    import projects  # noqa: PLC0415
    hit = projects.find(ref)
    if hit is None:
        fail(f"no project {ref!r} (projects.py list)", "no_project")
    return hit["id"]


def _index_path(uid: str) -> Path | None:
    db = blurt_home() / "index.db"
    if not db.is_file():
        return None
    try:
        import sqlite3  # noqa: PLC0415
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
        try:
            r = con.execute("SELECT path FROM items WHERE uid = ?", (uid,)).fetchone()
        finally:
            con.close()
    except Exception:
        return None
    if r and r[0] and not r[0].count("#") and Path(r[0]).is_file():
        return Path(r[0])
    return None


def find_path(ref: str, hint: Store | None = None) -> Path | None:
    """REF → the .md of the item: a path, an id (or a former id), a uid. The hint store is searched first."""
    if not isinstance(ref, str) or not ref:
        return None
    if ref.endswith(".md") and os.path.isfile(ref):
        return real(ref)
    stores = ([hint] if hint is not None else []) + [s for s in all_stores() if s != hint]
    if st.ID_RE.fullmatch(ref):
        for s in stores:
            p = s.path_for_id(ref)
            if p:
                return p
        for s in stores:
            p = s.find(alias=ref)
            if p:
                return p
        return None
    p = _index_path(ref)
    if p and st.salvage_header(p).get("uid") == ref:  # a broken file is found too: load() says it's unreadable
        return real(p)
    for s in stores:
        p = s.find(uid=ref)
        if p:
            return p
    return None


def load(path: Path) -> dict:
    try:
        return st.read_item(path)
    except FileNotFoundError:
        fail(f"{path}: gone", "not_found")
    except Unparseable as e:
        fail(f"{path}: can't be read back safely ({e}) — fix it by hand; blurt won't overwrite it", "unparseable")


def present(item: dict, path: Path, s: Store | None = None, names: dict | None = None) -> dict:
    """An item as hosts and agents see it: every path absolute, plus path / store / project / _project."""
    s = s or st.store_of_item(path)
    out = {k: v for k, v in item.items() if k not in st.INTERNAL}
    frames = []
    for f in item.get("frames") or []:
        if isinstance(f, dict) and isinstance(f.get("path"), str):
            f = {**f, "path": _abs(s, f["path"])}
        frames.append(f)
    if "frames" in item:
        out["frames"] = frames
    if isinstance(item.get("clip"), str) and item["clip"]:
        out["clip"] = _abs(s, item["clip"])
    pid = item.get("project") or s.project_id
    out["path"], out["store"], out["project"] = str(path), str(s.root), pid
    meta = (names or {}).get(pid) or _project_names().get(pid) or {"id": pid, "name": pid, "key": s.key}
    out["_project"] = {"id": meta["id"], "name": meta["name"], "key": meta["key"]}
    return out


def _abs(s: Store, p: str) -> str:
    return p if os.path.isabs(p) else str(s.root / p)


_NAMES: dict | None = None


def _project_names() -> dict:
    global _NAMES
    if _NAMES is None:
        import projects  # noqa: PLC0415
        _NAMES = {e["id"]: {"id": e["id"], "name": e.get("name") or e["id"], "key": e.get("key") or "",
                            "path": e["path"]} for e in [*projects.entries(), projects.inbox_entry()]}
    return _NAMES


# ------------------------------------------------------------------ sessions and their batch
def batch_path(session: Path) -> Path:
    return Path(session) / "batch.json"


def load_batch(session: Path) -> dict | None:
    try:
        b = load_json(batch_path(session))
    except ValueError:
        fail(f"{batch_path(session)}: not valid JSON", "bad_json")
    return b if isinstance(b, dict) else None


def save_batch(session: Path, b: dict) -> None:
    order = ["schema", "session", "title", "digest", "language", "project", "processing", "reviewed", "agent_at",
             "source_video", "items", "local", "removed"]
    b = {"schema": st.SCHEMA, **b}
    out = {k: b[k] for k in order if k in b} | {k: v for k, v in b.items() if k not in order}
    write_text_atomic(batch_path(session), json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    TOUCHED.append(real(session))


def new_batch(session: Path) -> dict:
    return {"schema": st.SCHEMA, "session": Path(session).name, "title": None, "digest": None, "language": None,
            "project": None, "processing": False, "reviewed": False, "agent_at": None, "source_video": None,
            "items": [], "local": {}, "removed": {}}


def is_session_dir(p: str) -> bool:
    return bool(p) and not p.endswith(".md") and os.path.isdir(p)


def prepare(session: Path) -> None:
    """Every command that takes a SESSION ingests a pending items.json first (the agent wrote it, §3)."""
    if (Path(session) / "items.json").is_file():
        ingest(Path(session))


def session_ref(session: Path, ident: str) -> tuple[Path | None, str, str | None]:
    """SESSION ID → (path, uid, removed_into): ID is a draft id (batch.local), a uid, or an item id."""
    b = load_batch(session) or new_batch(session)
    uid = (b.get("local") or {}).get(ident) or ident
    removed = b.get("removed") or {}
    if uid in removed:
        return None, uid, removed[uid] or ""
    return find_path(uid, st.store_of_session(session)), uid, None


def _id_of(uid: str | None) -> str:
    if not uid:
        return ""
    p = find_path(uid)
    return (st.read_header(p).get("id") if p else None) or uid


def target_of(args: list[str]) -> tuple[Path | None, list[str]]:
    """Positional args → (session or None, refs)."""
    if len(args) >= 2 and is_session_dir(args[0]):
        return real(args[0]), args[1:]
    if len(args) == 1 and is_session_dir(args[0]) and not os.path.isfile(args[0]):
        return real(args[0]), []
    return None, args


def locate(session: Path | None, ref: str) -> tuple[Path | None, str | None, str | None]:
    """→ (path, uid, merged_into) — path None with merged_into set: the user merged it away; all None: unknown."""
    if session is not None:
        path, uid, gone = session_ref(session, ref)
        if gone is not None:
            return None, uid, gone
    else:
        path = find_path(ref)
    if path is None:
        return None, None, None
    h = st.read_header(path)
    if h.get("state") == "discarded" and h.get("merged_into"):
        return path, h.get("uid"), h["merged_into"]
    return path, h.get("uid"), None


# ------------------------------------------------------------------ writing one item
def mutate(path: Path, fn) -> dict:
    """Read-modify-write one item under its store's lock. fn(item) → out; out["_write"] False = nothing changed."""
    s = st.store_of_item(path)
    with s.lock():
        item = load(path)
        out = fn(item)
        if out.pop("_write", True):
            item["updated"] = now_iso()
            st.write_item(path, item)
            TOUCHED.append(real(path))
    return out


def touch_batch(item: dict) -> None:
    """An agent wrote an item of a session still being processed: stamp agent_at (the page tells "still working"
    from "stalled" by it)."""
    session = (item.get("source") or {}).get("session") if isinstance(item.get("source"), dict) else None
    if not session or not batch_path(session).is_file():
        return
    with items_lock(Path(session)):
        b = load_batch(Path(session))
        if b and b.get("processing"):
            b["agent_at"] = now_iso()
            save_batch(Path(session), b)


def apply_fields(item: dict, sets: dict, unsets: list[str], force: bool, ctx: Path | None, root: Path) -> dict:
    user = item.get("_user") or {}
    written, kept = [], []
    for k, v in sets.items():
        if k in PROTECTED:
            fail(f"can't set {k}" + (" — use items.py state" if k.startswith(("fix", "work", "state")) else
                                     " — use items.py move" if k == "project" else ""), "protected")
        if k == "status":  # before K3's one state; kept for old callers: confirmed = keep, deleted = discard
            if v not in REVIEW_STATES:
                fail(f"status must be one of {', '.join(REVIEW_STATES)}", "bad_value")
            if v != "draft" and not force:
                fail("only the user keeps or discards items; leave it, or --force when they asked in chat",
                     "user_only")
            target = legacy_status_target(state_of(item), v)
            if target:
                set_state(item, target, {}, "user")
                written.append("state")
            continue
        if k in user and not force:
            kept.append(k)
            continue
        if k in ("frames", "clip"):
            v = import_media(item, k, v, ctx, root)
        item[k] = v
        written.append(k)
    for k in unsets:
        if k in PROTECTED:
            fail(f"can't unset {k}", "protected")
        if k in user and not force:
            kept.append(k)
        elif k in item:
            del item[k]
            written.append(k)
    return {"written": written, **({"kept_user": kept} if kept else {})}


def patch(path: Path, sets: dict, unsets: list[str], force: bool, ctx: Path | None) -> dict:
    try:
        check_item_fields(sets, unsets, f"{path.stem.split('-', 2)[0]}: ")
    except InvalidEdit as e:
        fail(str(e), "bad_value")

    root = st.store_of_item(path).root

    def fn(item):
        out = {"ok": True, "id": item.get("id"), "uid": item.get("uid"),
               **apply_fields(item, sets, unsets, force, ctx or _session_of(item), root)}
        if item.get("state") == "discarded":
            out["note"] = "the user discarded this item — no need to spend more work on it"
        if not out["written"]:
            out["_write"] = False
        return out
    return mutate(path, fn)


def _session_of(item: dict) -> Path | None:
    s = (item.get("source") or {}).get("session") if isinstance(item.get("source"), dict) else None
    return Path(s) if s else None


def _asset_name(adir: Path, src: Path, clip: bool = False) -> Path:
    ext = src.suffix.lower() or ".bin"
    if clip:
        name, n = f"clip{ext}", 2
        while (adir / name).exists():
            name, n = f"clip-{n}{ext}", n + 1
        return adir / name
    marked = ".marked" if src.name.endswith(f".marked{src.suffix}") else ""
    taken = {int(m.group(1)) for p in adir.glob("*") if (m := re.match(r"(\d+)\.", p.name))} if adir.is_dir() else set()
    n = 1
    while n in taken:
        n += 1
    return adir / f"{n}{marked}{ext}"


def import_media(item: dict, key: str, value, ctx: Path | None, root: Path):
    """frames / clip given relative to the session (or absolute) → copied into assets/<uid>/, stored relative to the
    store root. Paths already in this store's assets are kept; files that don't exist are kept as given."""
    def one(p, clip=False):
        if not isinstance(p, str) or not p:
            return p
        if not os.path.isabs(p) and p.startswith("assets/") and (root / p).is_file():
            return p
        src = Path(p) if os.path.isabs(p) else (ctx / p if ctx else root / p)
        if not src.is_file():
            return str(src) if ctx and not os.path.isabs(p) else p
        src = real(src)
        if (root / "assets") in src.parents:
            return os.path.relpath(src, root).replace(os.sep, "/")
        dst = _asset_name(root / "assets" / item["uid"], src, clip)
        st.link_or_copy(src, dst)
        return os.path.relpath(dst, root).replace(os.sep, "/")
    if key == "clip":
        return one(value, clip=True)
    if not isinstance(value, list):
        return value
    return [{**f, "path": one(f["path"])} if isinstance(f, dict) and isinstance(f.get("path"), str) else f
            for f in value]


def parse_frame(spec: str) -> dict:
    path, _, caption = spec.partition("#")
    m = re.fullmatch(r"(.+?)@(\d+(?:\.\d+)?)", path)
    f = {"path": m.group(1), "t": float(m.group(2))} if m else {"path": path}
    if caption:
        f["caption"] = caption
    return f


def set_frames(session: Path | None, ref: str, frames: list[dict], append: bool, force: bool) -> dict:
    path, uid, into = locate(session, ref)
    redirected = None
    if path is None and into is None:
        fail(f"no item {ref}", "not_found")
    if into is not None:  # the user merged it: its evidence belongs to the item it went into
        if not into:
            return {"ok": True, "id": ref, "skipped": "removed by the user"}
        path = find_path(into)
        if path is None:
            return {"ok": True, "id": ref, "skipped": "removed by the user"}
        redirected, append = _id_of(into), True
    item = st.read_header(path)
    ctx = session or _session_of(item)
    for f in frames:
        p = f["path"]
        if not (Path(p) if os.path.isabs(p) else (ctx or Path(".")) / p).is_file() \
                and not (st.store_of_item(path).root / p).is_file():
            fail(f"{p}: no such file" + (f" in {ctx}" if ctx else ""), "not_found")

    def fn(it):
        new = import_media(it, "frames", frames, ctx, st.store_of_item(path).root)
        if append:
            have = {f.get("path") for f in it.get("frames") or []}
            new = (it.get("frames") or []) + [f for f in new if f["path"] not in have]
        user = it.get("_user") or {}
        if "frames" in user and not force:
            return {"ok": True, "id": it["id"], "uid": it["uid"], "written": [], "kept_user": ["frames"],
                    "_write": False}
        it["frames"] = new
        return {"ok": True, "id": it["id"], "uid": it["uid"], "written": ["frames"]}
    out = mutate(path, fn)
    if redirected:
        out.update(id=ref, appended_to=redirected)
    return out


# ------------------------------------------------------------------ creating items (ingest / add / migrate)
def _source_type(session: Path, meta: dict) -> str:
    if meta.get("mode") == "voice" or session.name.endswith("-voice"):
        return "voice"
    if meta.get("mode") == "shots" or session.name.endswith("-shots"):
        return "snap"
    if (session / "recording.mp4").exists() or meta.get("video") or meta.get("mode") == "video":
        return "recording"
    return "import"


def _shot_of(it: dict) -> int | None:
    src = it.get("source") if isinstance(it.get("source"), dict) else {}
    if isinstance(src.get("shot"), int):
        return src["shot"]
    for f in it.get("frames") or []:
        m = re.match(r"shots/(\d+)(?:\.marked)?\.\w+$", str((f or {}).get("path") or "")) if isinstance(f, dict) else None
        if m:
            return int(m.group(1))
    return None


def read_shots(session: Path) -> dict[int, dict]:
    by_n: dict = {}
    try:
        lines = (session / "shots.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    for ln in lines:
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict) and isinstance(o.get("n"), int):
            by_n.setdefault(o["n"], {}).update(o)
    return by_n


def build_item(fields: dict, uid: str, s: Store, *, project_by: str, created: str, session: Path | None,
               meta: dict, local: str | None, language: str | None, shot: int | None) -> dict:
    """A new item for store s from v2-shaped fields (an items.json entry, add --json, a page's add op). The caller
    holds s.lock(); this allocates the id and copies frames / clip into assets/<uid>/."""
    item = {"id": s.next_id(), "uid": uid, "kind": str(fields.get("kind") or "note")}
    title = fields.get("title")
    if not isinstance(title, str) or not title.strip():
        title = (str(fields.get("quote") or "").strip().split("\n")[0][:80] or item["kind"])
    item["title"] = title
    # K3: the state from whatever shape the fields have (state, or v2 / early v0.7 status + work / fix)
    shaped = migrate_state({k: fields[k] for k in ("state", "restore_to", "status", "work", "fix", "fix_history",
                                                   "work_history") if k in fields})
    item["state"] = shaped["state"]
    for k in ("restore_to", "work", "work_history"):
        if shaped.get(k):
            item[k] = shaped[k]
    item["project"] = s.project_id
    item["project_by"] = project_by
    item["created"] = created
    item["updated"] = now_iso()
    src = dict(fields.get("source")) if isinstance(fields.get("source"), dict) else {}
    source = {"type": src.pop("type", None) or (_source_type(session, meta) if session else "import"),
              "by": src.pop("by", None) or meta.get("author") or _user_name(), "role": src.pop("role", None),
              "app": src.pop("app", None), "url": src.pop("url", None),
              "session": str(session) if session else src.pop("session", None),
              "shot": shot, "local_id": local, **{k: v for k, v in src.items() if k not in ("shot", "local_id")}}
    item["source"] = source
    lang = fields.get("language") or language
    if lang:
        item["language"] = lang
    skip = {"id", "uid", "kind", "title", "state", "restore_to", "status", "work", "fix", "fix_history", "source",
            "language", "frames", "clip", "project", "project_by", "created", "updated", "schema", "path", "store",
            "_project", "work_history", "aliases"}
    for k, v in fields.items():
        if k not in skip:
            item[k] = v
    if fields.get("frames") is not None:
        item["frames"] = import_media(item, "frames", fields["frames"], session, s.root)
    if fields.get("clip"):
        item["clip"] = import_media(item, "clip", fields["clip"], session, s.root)
    return item


def _user_name() -> str:
    try:
        return getpass.getuser()
    except Exception:
        return "me"


def _created_of(session: Path, meta: dict) -> str:
    t = to_epoch(meta.get("started_at"))
    if t is None:
        m = re.match(r"(\d{8}-\d{6})", session.name)
        if m:
            from datetime import datetime  # noqa: PLC0415
            try:
                t = datetime.strptime(m.group(1), "%Y%m%d-%H%M%S").timestamp()
            except ValueError:
                t = None
    return now_iso(t)


def write_new(s: Store, item: dict) -> Path:
    path = s.items_dir / st.item_filename(item["id"], item.get("title"))
    st.write_item(path, item)
    TOUCHED.append(real(path))
    return path


def ingest(session: Path, mode: str = "ingest") -> dict:
    """items.json (v2 shape, written by the agent — or a v1/v2 session) → one Markdown item per entry + batch.json.
    Entries already ingested (same draft id) are updated like `patch` (the user's fields kept); entries the user
    merged away stay gone. items.json is renamed to items.ingested.json (items.v2.json when migrating)."""
    session = real(session)
    home = st.store_of_session(session)
    with items_lock(session):
        src = session / "items.json"
        if not src.is_file():
            return {"ok": True, "items": [], "inbox": 0}
        try:
            data = json.loads(src.read_text(encoding="utf-8-sig"))
        except ValueError as e:
            fail(f"{src}: not valid JSON ({e}) — fix the file, then run items.py again", "bad_json")
        if not isinstance(data, dict) or not isinstance(data.get("items", []), list):
            fail(f"{src}: expected an object with an \"items\" list", "bad_json")
        home.ensure()
        meta = load_json(session / "meta.json", {}) or {}
        b = load_batch(session) or new_batch(session)
        shots = read_shots(session)
        # Where the items go is the user's word only: the batch, meta.json (the island's "Filed to X · Change"),
        # BLURT_PROJECT, the session's own store. A top-level "project" the organizing run wrote is never a
        # destination — for an Unassigned capture it is a suggestion like an item's own "project" (below). v1/v2
        # sessions being migrated kept their project there.
        legacy = data.get("project") if mode == "migrate" else None
        default = legacy or b.get("project") or meta.get("project") or os.environ.get("BLURT_PROJECT") \
            or (None if home.is_inbox else home.project_id)
        import projects  # noqa: PLC0415
        if default and default != st.INBOX and projects.by_id(default) is None:
            default = None
        if default == st.INBOX:
            default = None
        for k in ("title", "digest", "language", "source_video"):
            if data.get(k) is not None:
                b[k] = data[k]
        b["processing"] = bool(data.get("processing")) and mode == "ingest"
        b["reviewed"] = bool(b.get("reviewed") or data.get("reviewed"))
        b["agent_at"] = now_iso(data["agent_at"]) if isinstance(data.get("agent_at"), (int, float)) else now_iso()
        if b.get("project") is None and legacy:
            b["project"] = legacy
        local = b.setdefault("local", {})
        removed = b.setdefault("removed", {})
        order = b.setdefault("items", [])
        created = _created_of(session, meta)
        results = []
        known = set(order) | set(local.values())
        entries = [i for i in data["items"] if isinstance(i, dict)]
        v2_removed = data.get("_removed") if isinstance(data.get("_removed"), dict) else {}
        lmap = {**{str(i.get("id")): i["uid"] for i in entries if i.get("id") and isinstance(i.get("uid"), str)},
                **local}  # draft id → uid, for merged_from / _removed (v2 used draft ids there)

        def uid_for(lid):
            return lmap.get(lid) or legacy_uid(session.name, lid)
        for n, it in enumerate(entries):
            lid = str(it.get("id") or f"I-{n + 1:03d}")
            uid = local[lid] = local.get(lid) or uid_for(lid)
            if isinstance(it.get("merged_from"), list):
                it = {**it, "merged_from": [uid_for(str(x)) for x in it["merged_from"]]}
            if uid in removed:
                continue
            path = find_path(uid, home) if uid in known else None
            if path is not None:  # the agent rewrote items.json after an earlier ingest: patch, keep the user's edits
                sets = {k: v for k, v in it.items() if k not in PROTECTED and k != "status"
                        and not (k == "title" and not str(v or "").strip())}
                patch(path, sets, [], False, session)
                h = st.read_header(path)
                results.append({"local": lid, "uid": uid, "id": h.get("id"), "path": str(path),
                                "project": h.get("project")})
                if uid not in order:
                    order.append(uid)
                continue
            shot = _shot_of(it)
            by = "migrate" if mode == "migrate" else "capture"
            pid, suggestion = None, None
            if shot is not None and isinstance((shots.get(shot) or {}).get("project"), str):
                pid = shots[shot]["project"]  # the user filed this capture on the island (or it was taken with one)
                by = "user" if shots[shot].get("assigned_by") == "user" else by
            pid = pid or default
            said = it.get("project") if isinstance(it.get("project"), str) else \
                (data.get("project") if mode == "ingest" and isinstance(data.get("project"), str) else None)
            if not pid and said:
                # Unassigned: the organizing run may suggest a project (SKILL.md §3) — only a suggestion, the item
                # stays here until the user moves it. With a project (the user's current one) the items go there.
                hit = projects.find(said)
                if hit is not None and hit["id"] != st.INBOX:
                    c = it.get("project_confidence")
                    suggestion = {"id": hit["id"], "reason": str(it.get("project_reason") or "")[:200]}
                    if isinstance(c, (int, float)) and not isinstance(c, bool):
                        suggestion["confidence"] = round(max(0.0, min(1.0, float(c))), 2)
            target = store_for_project(pid) if pid else st.inbox_store()
            target.ensure()
            fields = {k: v for k, v in it.items() if k not in ("project", "project_confidence", "project_reason")}
            if shot is not None and (shots.get(shot) or {}).get("type") == "voice":
                # a voice input in a shots batch is a voice capture, not a snap (K1 source.type)
                fields["source"] = {**(it["source"] if isinstance(it.get("source"), dict) else {}), "type": "voice"}
            with target.lock():
                item = build_item(fields, uid, target, project_by=by, created=created, session=session, meta=meta,
                                  local=lid, language=data.get("language"), shot=shot)
                if suggestion and target.is_inbox:
                    item["suggested_project"] = suggestion
                p = write_new(target, item)
            order.append(uid)
            results.append({"local": lid, "uid": uid, "id": item["id"], "path": str(p), "project": item["project"]})
        for gone, into in v2_removed.items():  # v2 merges: no file for the merged item, the batch remembers it
            guid = local[gone] = local.get(gone) or uid_for(gone)
            removed[guid] = uid_for(into) if into else ""
        dest = session / ("items.v2.json" if mode == "migrate" else "items.ingested.json")
        os.replace(src, dest)
        save_batch(session, b)
    job = os.environ.get("BLURT_JOB") or os.environ.get("BLURT_RUN_ID")
    if mode == "ingest" and job:
        append_job_event(job, {"event": "step", "step": {"id": "write", "state": "done"},
                               "items": [r["uid"] for r in results]})
    return {"ok": True, "items": results, "inbox": sum(1 for r in results if r["project"] == st.INBOX)}


def add(session: Path | None, project: str | None, fields: dict, after: str | None) -> dict:
    if not isinstance(fields, dict) or not fields.get("kind") or not fields.get("title"):
        fail("--json must be an object with at least kind and title")
    try:
        check_item_fields({"title": fields["title"]})
    except InvalidEdit as e:
        fail(str(e), "bad_value")
    uid = fields.get("uid")
    if uid is not None and (not isinstance(uid, str) or find_path(uid)):
        fail(f"uid {uid!r} is taken or not a string — omit uid to get a new one", "taken")
    uid = uid or new_ulid()
    fields = {k: v for k, v in fields.items() if k not in ("_user",)}
    if session is not None:
        prepare(session)
        with items_lock(session):
            b = load_batch(session) or new_batch(session)
            lid = fields.pop("id", None)
            if lid and (lid in (b.get("local") or {})):
                fail(f"id {lid} is taken (or was merged away by the user) — omit id to get a new one", "taken")
            home = st.store_of_session(session)
            home.ensure()
            pid = project or b.get("project") or (None if home.is_inbox else home.project_id)
            target = store_for_project(pid) if pid else st.inbox_store()
            target.ensure()
            meta = load_json(session / "meta.json", {}) or {}
            with target.lock():
                item = build_item(fields, uid, target, project_by="capture", created=now_iso(), session=session,
                                  meta=meta, local=lid, language=b.get("language"), shot=_shot_of(fields))
                path = write_new(target, item)
            if lid:
                b.setdefault("local", {})[lid] = uid
            order = b.setdefault("items", [])
            pos = len(order)
            if after:
                ap, auid, _ = locate(session, after)
                if auid in order:
                    pos = order.index(auid) + 1
            order.insert(pos, uid)
            save_batch(session, b)
        out = {"ok": True, "id": item["id"], "uid": uid, "path": str(path)}
        if b.get("reviewed"):
            out["note"] = "the user already finished the review; mention the new item to them"
        return out
    pid = resolve_project(project or st.INBOX)
    target = store_for_project(pid)
    fields.pop("id", None)
    with target.lock():
        item = build_item(fields, uid, target, project_by="user" if os.environ.get("BLURT_BY") == "user" else "capture",
                          created=now_iso(), session=None, meta={}, local=None, language=fields.get("language"),
                          shot=None)
        path = write_new(target, item)
    return {"ok": True, "id": item["id"], "uid": uid, "path": str(path)}


def done(session: Path) -> dict:
    prepare(session)
    with items_lock(session):
        b = load_batch(session)
        if b is None:
            fail(f"{session}: nothing to finish — write items.json first (§3)", "not_found")
        b.pop("processing", None)
        b["processing"] = False
        b["agent_at"] = now_iso()
        save_batch(session, b)
    live, missing = 0, []
    for uid in b.get("items") or []:
        p = find_path(uid, st.store_of_session(session))
        h = st.read_header(p) if p else {}
        if not h or h.get("state") == "discarded":
            continue
        live += 1
        if not h.get("frames"):
            missing.append(h.get("id"))
    append_job_event(os.environ.get("BLURT_JOB") or os.environ.get("BLURT_RUN_ID"),
                     {"event": "step", "step": {"id": "frames", "state": "done"}})
    return {"ok": True, "items": live, **({"no_frames": missing} if missing else {}),
            **({"reviewed": True} if b.get("reviewed") else {})}


# ------------------------------------------------------------------ K3: the item's state
def set_state(item: dict, state: str, given: dict, by: str, undo: bool = False, force: bool = False) -> dict:
    """Move one item to `state` (K3). Keep / discard / restore only change `state` (and `restore_to`); a move into or
    out of the hand-off states rewrites `work` and appends the previous {state, …work} to work_history. undo = the
    user takes back their own last change (the page's undo): any state, the previous work comes back. force = an old
    caller's user decision (v2 `fix`, an old page's work op) that K3's table may not have: any state."""
    if state not in STATES:
        fail(f"state must be one of {', '.join(STATES)}", "bad_value")
    if by not in WORK_BY:
        fail(f"--by must be one of {', '.join(WORK_BY)}", "bad_value")
    cur = state_of(item)
    out = {"uid": item.get("uid"), "id": item.get("id"), "state": state}
    if (undo or force) and by != "user":
        fail("only the user's own change skips the transition table", "bad_args")
    if cur == "discarded" and state in ("handed_off", "in_progress") and by != "user":
        fail(f"{item.get('id')}: the user discarded this item — it can't be handed off", "deleted")
    same = cur == state
    if same and not may_move(cur, state, by):
        return {**out, "work": item.get("work"), "_write": False}  # already there: nothing to do
    if not same and not (undo or force) and not may_move(cur, state, by):
        who = "only the user" if state in ("todo", "done", "wontfix", "discarded") or cur == "discarded" \
            else f"not {by}"
        fail(f"{item.get('id')}: {cur} → {state} ({who} may do that)", "bad_transition")
    cur_work = item.get("work") if isinstance(item.get("work"), dict) else None
    hist = item.get("work_history") if isinstance(item.get("work_history"), list) else []
    if state == "discarded":
        item["restore_to"] = cur
    else:
        item.pop("restore_to", None)
    item["state"] = state
    if state == "discarded" or cur == "discarded" or (cur not in WORK_TRACKED and state not in WORK_TRACKED):
        return {**out, "work": item.get("work")}  # keep / discard / restore: the hand-off record stays as it was
    if undo and hist and isinstance(hist[-1], dict) and hist[-1].get("state") == state:
        prev = hist.pop()
        item["work"] = {k: prev.get(k) for k in WORK_KEYS}
        if not hist:
            item.pop("work_history", None)
        return {**out, "work": item["work"]}
    given = {k: v for k, v in given.items() if v is not None}
    now = now_iso()
    if same and cur_work:
        new = {**{k: cur_work.get(k) for k in WORK_KEYS}, **given, "at": now, "by": by}
    else:
        if cur_work:
            item["work_history"] = [*hist, {"state": cur, **{k: cur_work.get(k) for k in WORK_KEYS}}]
        w = cur_work or {}
        carry = w if cur in ("handed_off", "in_progress", "to_verify") and state != "todo" else {}
        new = {"to": given.get("to") or carry.get("to"),
               "agent": given.get("agent") or carry.get("agent") or ("human" if by == "user" else None),
               "job": given.get("job") or carry.get("job"), "handoff": given.get("handoff") or carry.get("handoff"),
               "claim": given.get("claim"), "note": given.get("note") or "",
               "commit": given.get("commit") or (carry.get("commit") if state != "in_progress" else None),
               "pr": given.get("pr") or (carry.get("pr") if state != "in_progress" else None), "at": now, "by": by}
    if state == "handed_off" and not new.get("to"):
        new["to"] = "external" if by == "user" else "session"
    if state != "to_verify":
        new["claim"] = None
    item["work"] = {k: new.get(k) for k in WORK_KEYS}
    return {**out, "work": item["work"]}


def legacy_status_target(cur: str, status: str) -> str | None:
    """An old review status written by an old caller (patch --set status=…, a page's set) → the state it means now."""
    if status == "deleted":
        return None if cur == "discarded" else "discarded"
    if status == "confirmed":
        return "todo" if cur == "new" else None
    return "new" if cur == "todo" else None  # draft: an old page undoing its keep


def change_state(session: Path | None, refs: list[str], state: str | None, action: str | None, given: dict,
                 by: str, undo: bool = False) -> dict:
    given = dict(given)
    given.setdefault("agent", None)
    if not given.get("agent") and os.environ.get("BLURT_AGENT") and by != "user":
        given["agent"] = os.environ["BLURT_AGENT"]
    if not given.get("job"):
        given["job"] = os.environ.get("BLURT_JOB") or os.environ.get("BLURT_RUN_ID") or None
    if given.get("to") not in (None, "session", "external"):
        fail("--to must be session or external", "bad_value")
    if given.get("claim") not in (None, "fixed", "wontfix"):
        fail("--claim must be fixed or wontfix", "bad_value")
    if (state is None) == (action is None):
        fail("pass --state S or --action A")
    if action is not None and action not in ACTIONS:
        fail(f"action must be one of {', '.join(ACTIONS)}", "bad_value")

    def target(it):
        if action is None:
            return state
        to = action_target(action, state_of(it), it.get("restore_to"))
        if to is None:
            fail(f"{it.get('id')}: can't {action.replace('_', ' ')} an item that is {state_of(it)}", "bad_transition")
        return to
    targets = []
    for ref in refs:
        path, uid, into = locate(session, ref)
        if path is None and into is None:
            fail(f"no item {ref}", "not_found")
        if path is None:
            targets.append((ref, None, into))
            continue
        it = load(path)
        set_state(json.loads(json.dumps(it)), target(it), given, by, undo)  # check every item before writing any
        targets.append((ref, path, into))
    out = []
    for ref, path, into in targets:
        if path is None:
            out.append({"uid": None, "id": ref, "skipped": f"merged into {_id_of(into)}" if into else
                        "removed by the user"})
            continue
        out.append(mutate(path, lambda it: set_state(it, target(it), given, by, undo)))
        touch_batch(st.read_header(path))
    return {"ok": True, "items": out}


def fix(session: Path | None, ref: str, state: str, given: dict) -> dict:
    """v2 `items.py fix` → K3. Without an agent (none given, no $BLURT_AGENT) it is the user's own call."""
    if state not in FIX_STATES:
        fail(f"state must be one of {', '.join(FIX_STATES)}", "bad_value")
    agent = given.get("agent") or os.environ.get("BLURT_AGENT") or "human"
    new, claim = FIX_TO_WORK[state]
    by = "user" if agent == "human" else "agent"
    if state == "wontfix" and by == "user":
        new, claim = "wontfix", None
    path, uid, into = locate(session, ref)
    if path is None and into is not None:
        return {"ok": True, "id": ref, "skipped": f"merged into {_id_of(into)}" if into else "removed by the user"}
    if path is None:
        fail(f"no item {ref}", "not_found")
    g = {"agent": agent, "job": given.get("run_id") or os.environ.get("BLURT_JOB") or os.environ.get("BLURT_RUN_ID"),
         "commit": given.get("commit"), "pr": given.get("pr"), "note": given.get("note"), "claim": claim}
    if by == "user":  # no agent: the user's own word — fixed by hand is done
        new = {"fixing": "in_progress", "fixed": "done", "wontfix": "wontfix", "reopened": "todo"}[state]
    out = mutate(path, lambda it: set_state(it, new, g, by, force=by == "user"))
    touch_batch(st.read_header(path))
    return {"ok": True, **out}


# ------------------------------------------------------------------ moving between projects
def move_items(paths: list[Path], pid: str, by: str = "user", only_from: set[str] | None = None,
               kept: list[dict] | None = None) -> list[dict]:
    """Items into another store. Only ever the user's choice (by "user"; "migrate" for the v0.6 carry-over): nothing
    moves an item on its own. A suggested_project stays (it is shown only while the item is in Unassigned).
    only_from: move only the items that are still in one of these projects; the others (moved since by the user)
    stay where they are and are listed in `kept`."""
    dst = store_for_project(pid)
    moved = []
    for path in paths:
        src = st.store_of_item(path)
        if only_from is not None and src.project_id not in only_from:
            if kept is not None:
                kept.append({"uid": st.read_header(path).get("uid"), "project": src.project_id})
            continue
        locks = sorted({src, dst}, key=lambda s: str(s.root))
        with contextlib.ExitStack() as stack:
            for s in locks:
                stack.enter_context(s.lock())
            item = load(path)
            old = item.get("id")
            if by == "user":
                item.setdefault("_user", {})["project"] = round(to_epoch(now_iso()) or 0, 1)
            item["project_by"] = by
            item.pop("project_confidence", None)  # v0.8's auto-sort wrote these
            item.pop("project_reason", None)
            if src == dst:
                item["updated"] = now_iso()
                st.write_item(path, item)
                TOUCHED.append(real(path))
                moved.append({"uid": item["uid"], "from": src.project_id, "to": dst.project_id, "id": old,
                              "path": str(path)})
                continue
            aliases = list(item.get("aliases") or [])
            back = _former_id(aliases, dst)
            item["id"] = back or dst.next_id()
            item["project"] = dst.project_id
            item["aliases"] = [*(a for a in aliases if a != back), *([old] if old else [])]
            a_src, a_dst = src.asset_dir(item["uid"]), dst.asset_dir(item["uid"])
            if a_src.is_dir():
                a_dst.parent.mkdir(parents=True, exist_ok=True)
                if a_dst.exists():
                    shutil.rmtree(a_dst)
                try:
                    os.rename(a_src, a_dst)
                except OSError:  # another volume
                    shutil.copytree(a_src, a_dst)
                    shutil.rmtree(a_src)
            item["updated"] = now_iso()
            new_path = write_new(dst, item)
            path.unlink()
            TOUCHED.append(real(path))
            moved.append({"uid": item["uid"], "from": src.project_id, "to": dst.project_id, "id": item["id"],
                          "path": str(new_path)})
    return moved


def _former_id(aliases: list[str], dst: Store) -> str | None:
    """An id this item had in `dst` before it left (the newest one), still free there: moving back — the user's
    ⌘Z after a move — gives the item its old id again instead of minting another. Only ids the store itself handed
    out (below its counter), so a key another project once used is never taken."""
    nxt = int(dst.meta.get("next") or 1)
    for a in reversed(aliases):
        k, _, n = a.rpartition("-")
        if k == dst.key and n.isdigit() and int(n) < nxt and dst.path_for_id(a) is None:
            return a
    return None


def move(session: Path | None, refs: list[str], project: str, only_from: list[str] | None = None) -> dict:
    """`move REF… --project P [--from Q …]`: --from moves only the items still in Q — "Filed to X · Change" on a
    recording, and its Undo, leave alone the items the user has moved by hand since."""
    pid = resolve_project(project)
    froms = {resolve_project(f) for f in only_from} if only_from else None
    paths = []
    for ref in refs:
        path, uid, into = locate(session, ref)
        if path is None:
            fail(f"no item {ref}" if into is None else f"{ref} was merged away by the user", "not_found")
        paths.append(path)
    kept: list[dict] = []
    out = {"ok": True, "moved": move_items(paths, pid, "user", froms, kept)}
    if froms is not None:
        out["kept"] = kept
    return out


# ------------------------------------------------------------------ reading: get / list / doc
def get(session: Path | None, ref: str) -> dict:
    if session is not None:
        prepare(session)
    path, uid, into = locate(session, ref)
    if path is None and into is None:
        fail(f"no item {ref}", "not_found")
    if into is not None:
        fail(f"{ref} was merged into {_id_of(into)} by the user" if into else f"{ref} was removed by the user",
             "merged")
    item = load(path)
    return {"ok": True, "item": present(item, path), "session": (item.get("source") or {}).get("session")
            if isinstance(item.get("source"), dict) else None}


def _matches(item: dict, kinds, states) -> bool:
    """states None = every state but discarded."""
    if kinds and item.get("kind") not in kinds:
        return False
    s = state_of(item)
    return s in states if states is not None else s != "discarded"


def filter_states(states=(), statuses=(), works=(), fix_states=()) -> list[str] | None:
    """--state, plus the old --status / --work / --fix-state names (K3), as one list of states (None = not given)."""
    old = legacy_filter_states(statuses, works, fix_states)
    if not states:
        return old
    return [s for s in states if old is None or s in old]


def scope_items(scope: dict, unreadable: list | None = None) -> tuple[list[tuple[Path, dict]], dict | None]:
    """The items a scope covers, in review order, and the session's batch (None for a project scope). Unreadable
    files are skipped (and their identity added to `unreadable`, when given: a page that asked for one says it can't
    be read, never that it's gone)."""
    def skip(p: Path) -> None:
        if unreadable is not None:
            h = st.salvage_header(p)
            unreadable.append({"uid": h.get("uid"), "id": h.get("id") or p.stem, "title": h.get("title"),
                               "path": str(p), "aliases": h.get("aliases") or []})
    if scope.get("session"):
        session = Path(scope["session"])
        b = load_batch(session) or new_batch(session)
        home = st.store_of_session(session)
        out = []
        for uid in b.get("items") or []:
            p = find_path(uid, home)
            if p is None:
                continue
            try:
                out.append((p, st.read_item(p)))
            except (Unparseable, OSError):
                skip(p)
        return out, b
    stores = [store_for_project(scope["project"])] if scope.get("project") else all_stores()
    out = []
    for s in stores:
        for p in s.files():
            try:
                out.append((p, st.read_item(p)))
            except (Unparseable, OSError):
                skip(p)
    out.sort(key=lambda x: (to_epoch(x[1].get("created")) or 0, x[1].get("id") or ""), reverse=True)
    return out, None


def list_items(session: Path | None, project: str | None, kinds, states) -> dict:
    if session is not None:
        prepare(session)
        scope = {"session": str(session)}
    else:
        scope = {"project": resolve_project(project)} if project else {}
    pairs, _ = scope_items(scope)
    rows = [present(i, p) for p, i in pairs if _matches(i, kinds, states)]
    return {"ok": True, "items": rows, **({"session": str(session)} if session else {})}


def make_doc(scope: dict, kinds=(), states=None, include: str | None = None) -> dict:
    """A session's doc lists every item it still has (discarded ones too: the page shows and restores them); a
    project's doc lists its items but the discarded, unless asked for them (states). `include` (a uid, id or alias):
    the one item a detail pane shows is always in its doc, whatever the filters say — a discarded item opened from
    the Discarded filter must not show its neighbour instead."""
    import projects  # noqa: PLC0415
    unreadable: list = []
    pairs, b = scope_items(scope, unreadable)
    names = _project_names()
    removed = dict((b or {}).get("removed") or {})
    items = []
    for p, it in pairs:
        if it.get("state") == "discarded" and it.get("merged_into"):
            removed.setdefault(it["uid"], it["merged_into"])
            continue
        if it["uid"] in removed:
            continue
        wanted = include is not None and include in (it.get("uid"), it.get("id"), *(it.get("aliases") or []))
        if not wanted and (b is None or states is not None or kinds) and not _matches(it, kinds, states):
            continue
        items.append(present(it, p, names=names))
    plist = [{"id": e["id"], "name": e.get("name"), "key": e.get("key"), "path": e["path"]}
             for e in [*projects.entries(), projects.inbox_entry()]]
    if b is not None:
        session = Path(scope["session"])
        video = b.get("source_video")
        vpath = (str(session / video) if video and not os.path.isabs(video) else video) if video else None
        doc = {"schema": st.SCHEMA, "scope": {"session": str(session)}, "title": b.get("title"),
               "digest": b.get("digest"), "language": b.get("language"), "processing": bool(b.get("processing")),
               "reviewed": bool(b.get("reviewed")), "agent_at": b.get("agent_at"), "source_video": vpath,
               "_video": bool(vpath) and Path(vpath).is_file(), "project": b.get("project")}
    else:
        pid = scope.get("project")
        meta = names.get(pid) or {}
        sc = {"project": pid, **({"state": list(states)} if states is not None else {}),
              **({"kind": list(kinds)} if kinds else {})}
        doc = {"schema": st.SCHEMA, "scope": sc, "title": meta.get("name"), "digest": None,
               "language": None, "processing": False, "reviewed": False, "agent_at": None, "source_video": None,
               "_video": False, "project": pid}
    for it in items:  # handed to the agent's desktop app: the page names that app, not the CLI
        jid = (it.get("work") or {}).get("job") if state_of(it) in ("handed_off", "in_progress") else None
        if jid and _job_runner(jid) == "desktop":
            it["_work_runner"] = "desktop"
    doc["items"] = items
    doc["_removed"] = removed
    doc["agents"] = _agent_names()
    doc["me"] = _user_name()  # who "by …" in an item's provenance is on this Mac: the page says "by you"
    if include is not None:  # the one item a detail pane asked for, when its file can't be read: the page says so
        doc["_unreadable"] = [u for u in unreadable if include in (u["uid"], u["id"], *u["aliases"])]
    doc["projects"] = plist
    return doc


def _agent_names() -> dict:
    """agent id → {name, desktop}: the names people know (agents.json plus their own agent_defs), never the ids."""
    try:
        import agents  # noqa: PLC0415
        return {k: {"name": d.get("name") or k, "desktop": (agents.desktop_spec(d) or {}).get("name")}
                for k, d in agents.definitions(agents.config(None)).items()}
    except Exception:  # noqa: BLE001 — names are a nicety: the page falls back to "Agent"
        return {}


def _job_runner(jid: str) -> str | None:
    try:
        o = json.loads((blurt_home() / "jobs" / f"{jid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return ((o.get("agent") or {}) if isinstance(o, dict) else {}).get("runner")


def doc_etag(doc: dict) -> str:
    return file_etag(json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode())


def scope_of(session: Path | None, project: str | None) -> dict:
    if session is not None:
        prepare(session)
        return {"session": str(session)}
    if project:
        return {"project": resolve_project(project)}
    fail("pass SESSION or --project P|inbox")


# ------------------------------------------------------------------ the user's edits (review page, apps)
OP_KINDS = {"set", "remove", "add", "state", "work"}  # work: the state op's old name


def parse_ops(raw: str) -> list[dict]:
    try:
        ops = json.loads(raw)
    except ValueError as e:
        fail(f"ops: not valid JSON ({e})")
    if isinstance(ops, dict) and isinstance(ops.get("ops"), list):  # the review page's POST body, as is
        ops = ops["ops"]
    if not isinstance(ops, list):
        fail("ops: expected a JSON list of ops")
    check_ops(ops)
    return ops


def check_ops(ops: list) -> None:
    """Shape and content of every op first (an invalid one raises and nothing is applied)."""
    for n, op in enumerate(ops):
        ok = isinstance(op, dict) and op.get("op") in OP_KINDS
        if ok and op["op"] == "set":
            ok = isinstance(op.get("id"), str) and isinstance(op.get("set") or {}, dict) \
                 and isinstance(op.get("unset") or [], list)
        elif ok and op["op"] == "remove":
            ok = isinstance(op.get("id"), str)
        elif ok and op["op"] in ("state", "work"):
            ok = isinstance(op.get("id"), str) and (
                op.get("action") in ACTIONS if op.get("action") is not None else op.get("state") in STATES)
        elif ok:
            ok = isinstance(op.get("item"), dict) and isinstance(op["item"].get("id") or op["item"].get("uid"), str)
        if not ok:
            fail(f"ops[{n}]: expected {{op: set, id, set?, unset?}} | {{op: remove, id, into?}} "
                 f"| {{op: add, item: {{id, …}}, after?}} | {{op: state, id, action | state, note?, undo?}}, got "
                 f"{json.dumps(op, ensure_ascii=False)[:200]}")
    for n, op in enumerate(ops):
        try:
            if op["op"] == "set":
                check_item_fields(op.get("set") or {}, op.get("unset") or [], f"ops[{n}] ({op.get('id')}): ")
            elif op["op"] == "add" and "title" in op["item"]:
                check_item_fields({"title": op["item"]["title"]}, (), f"ops[{n}] ({op['item'].get('id')}): ")
        except InvalidEdit as e:
            fail(str(e), "bad_value")


def _user_set(item: dict, sets: dict, unsets: list, now: float, root: Path, uid_of) -> None:
    user = item.setdefault("_user", {})
    for k, v in sets.items():
        if k in SERVER_KEYS:
            continue
        if k == "merged_from" and isinstance(v, list):
            v = [uid_of(x) or x for x in v]
        if k in ("frames", "clip"):
            v = _relativize(v, root)
        item[k] = v
        if not k.startswith("_"):
            user[k] = now
    for k in unsets:
        if k in SERVER_KEYS:
            continue
        item.pop(k, None)
        if not k.startswith("_"):
            user[k] = now


def _relativize(v, root: Path):
    """A page sends back the absolute paths the doc gave it: inside the store they become relative again."""
    def one(p):
        if isinstance(p, str) and os.path.isabs(p) and real(p).is_relative_to(root):
            return os.path.relpath(real(p), root).replace(os.sep, "/")
        return p
    if isinstance(v, list):
        return [{**f, "path": one(f.get("path"))} if isinstance(f, dict) else f for f in v]
    return one(v)


def apply_user_ops(scope: dict, ops: list[dict], confirm: bool = False, now: float | None = None) -> None:
    """The page sends what the user changed, not the whole list, so the agent's concurrent writes survive. Fields
    the user sets are recorded in the item's _user (field → epoch); items.py won't overwrite those. op ids may be
    uids (preferred: an id changes when an item changes project), ids or draft ids."""
    import time  # noqa: PLC0415
    check_ops(ops)
    now = round(time.time() if now is None else now, 1)
    session = Path(scope["session"]) if scope.get("session") else None
    home = st.store_of_session(session) if session else store_for_project(scope["project"])
    lock = items_lock(session) if session else home.lock()
    with lock:
        b = (load_batch(session) or new_batch(session)) if session else None

        def find(ident):
            if not isinstance(ident, str) or not ident:
                return None
            if b is not None:
                ident = (b.get("local") or {}).get(ident) or ident
            return find_path(ident, home)

        def uid_of(ident):
            p = find(ident)
            return st.read_header(p).get("uid") if p else None

        moves = []
        for op in ops:
            kind = op["op"]
            if kind == "add":
                _add_op(op, b, home, session, now, find, uid_of)
                continue
            path = find(op["id"])
            if path is None:
                continue  # unknown ids are ignored, as on the page
            if kind == "set":
                sets = dict(op.get("set") or {})
                proj = sets.pop("project", None)

                def edit(it, sets=sets, unsets=op.get("unset") or [], root=st.store_of_item(path).root):
                    # an old page's state change rides in a set: state as is, status the way it maps now (K3)
                    to = sets.get("state") if sets.get("state") in STATES else \
                        legacy_status_target(state_of(it), sets["status"]) if sets.get("status") in REVIEW_STATES \
                        else None
                    if to and to != state_of(it):
                        set_state(it, to, {}, "user", force=True)
                    _user_set(it, sets, unsets, now, root, uid_of)
                    return {}
                mutate(path, edit)
                h = st.read_header(path)
                if isinstance(proj, str) and proj and proj != h.get("project"):
                    moves.append((h.get("uid"), proj))
            elif kind == "remove":
                into = uid_of(op.get("into")) if op.get("into") else None

                def rm(it, into=into):
                    if state_of(it) != "discarded":
                        set_state(it, "discarded", {}, "user")
                    it["merged_into"] = into
                    return {}
                mutate(path, rm)
                uid = st.read_header(path).get("uid")
                if b is not None:
                    b.setdefault("removed", {})[uid] = into or ""
                    if uid in (b.get("items") or []):
                        b["items"].remove(uid)
            else:  # state (work: its old name, from a page before K3's one state: the user's word, any state)
                def decide(it, op=op):
                    cur = state_of(it)
                    to = action_target(op["action"], cur, it.get("restore_to")) if op.get("action") is not None \
                        else op["state"]
                    undo, force = bool(op.get("undo")), op["op"] == "work"
                    if to is None or to == cur or not (undo or force or may_move(cur, to, "user")):
                        return {"_write": False}  # no longer valid (another window got there first): the doc says
                    set_state(it, to, {"note": op.get("note")}, "user", undo=undo, force=force)
                    return {}
                mutate(path, decide)
        if b is not None:
            if confirm:
                b["reviewed"] = True
            save_batch(session, b)
    for uid, proj in moves:  # the user picked another project: same as `move --by user`
        try:
            pid = resolve_project(proj)
        except ItemsError:
            continue
        cur = find_path(uid) if uid else None
        if cur is not None:
            move_items([cur], pid, by="user")


def _add_op(op, b, home, session, now, find, uid_of) -> None:
    """Undoing a merge brings an item back; an item the page made up is created."""
    fields = dict(op["item"])
    ident = fields.get("uid") or fields.get("id")
    path = find(ident)
    if path is not None:
        def restore(it, root=st.store_of_item(path).root):
            merged = bool(it.get("merged_into"))
            for k, v in fields.items():
                if k not in SERVER_KEYS:
                    it[k] = _relativize(v, root) if k in ("frames", "clip") else v
            if merged and state_of(it) == "discarded":
                to = fields.get("state") if fields.get("state") in STATES and fields["state"] != "discarded" \
                    else it.get("restore_to") or "new"
                set_state(it, to, {}, "user", undo=True)
            it["merged_into"] = None
            return {}
        mutate(path, restore)
        uid = st.read_header(path).get("uid")
    else:
        uid = fields.get("uid") if isinstance(fields.get("uid"), str) and UID_RE.fullmatch(fields["uid"]) \
            and not find_path(fields["uid"]) else new_ulid()
        target = home
        if b is not None and b.get("project"):
            target = store_for_project(b["project"])
        target.ensure()
        with target.lock():
            fields.pop("_user", None)
            item = build_item({k: v for k, v in fields.items() if k != "id"}, uid, target, project_by="user",
                              created=now_iso(), session=session, meta={}, local=None, language=None, shot=None)
            item["_user"] = {}
            write_new(target, item)
    if b is not None:
        b.get("removed", {}).pop(uid, None)
        order = b.setdefault("items", [])
        if uid in order:
            order.remove(uid)
        after = op.get("after")
        auid = uid_of(after) if after else None
        pos = order.index(auid) + 1 if auid in order else (0 if after is None else len(order))
        order.insert(pos, uid)


# ------------------------------------------------------------------ v1 / v2 sessions → stores
def migrate_candidates(root: Path | None = None, projects_too: bool = True) -> list[Path]:
    import projects  # noqa: PLC0415
    containers = []
    if root is not None:
        root = real(root)
        containers += [root / ".blurt" / "sessions", root / "sessions", root]
    else:
        from _common import global_config  # noqa: PLC0415
        bound = (global_config().get("record") or {}).get("workspaces") or []  # v0.6, before projects.py migrate
        containers += [st.legacy_recordings(), st.inbox_root() / "sessions"]
        if projects_too:
            containers += [Path(e["path"]) / ".blurt" / "sessions" for e in projects.entries()]
        containers += [Path(os.path.expanduser(w)) / ".blurt" / "sessions" for w in bound if isinstance(w, str)]
    out = []
    for c in containers:
        if c.is_dir():
            out += [d for d in sorted(c.iterdir()) if d.is_dir() and not d.name.startswith(".")
                    and (d / "items.json").is_file()]
    return list(dict.fromkeys(real(d) for d in out))


def migrate(sessions: list[Path], dry_run: bool) -> dict:
    n_sessions, n_items, skipped = 0, 0, []
    for d in sessions:
        d = real(d)
        if not (d / "items.json").is_file():
            skipped.append({"dir": str(d), "why": "no items.json"})
            continue
        if batch_path(d).is_file():
            skipped.append({"dir": str(d), "why": "already migrated"})
            continue
        try:
            data = json.loads((d / "items.json").read_text(encoding="utf-8-sig"))
            if not isinstance(data, dict) or not isinstance(data.get("items", []), list):
                raise ValueError("expected an object with an items list")
        except ValueError as e:
            skipped.append({"dir": str(d), "why": f"items.json: {e}"[:200]})
            continue
        if dry_run:
            gone = set((data.get("_removed") or {}))
            n_items += sum(1 for i in data.get("items", []) if isinstance(i, dict) and i.get("id") not in gone)
            n_sessions += 1
            continue
        try:
            r = ingest(d, mode="migrate")
        except ItemsError as e:
            skipped.append({"dir": str(d), "why": str(e)[:200]})
            continue
        n_sessions += 1
        n_items += len(r["items"])
    return {"ok": True, "sessions": n_sessions, "items": n_items, "skipped": skipped,
            **({"dry_run": True} if dry_run else {})}


def dangling_work(con=None) -> list[tuple[Path, str]]:
    """(item file, work.job) for the unfinished items whose session no longer exists: a v0.6 headless run's id
    (r-…, removed with $BLURT_HOME/runs), a job file that is gone. From index.db; [] without one."""
    import index  # noqa: PLC0415
    try:
        own = con is None
        con = con or index.connect(readonly=True)
        try:
            rows = con.execute("SELECT path, work_job FROM items WHERE work_job IS NOT NULL AND work_job != ''"
                               " AND state IN ('handed_off', 'in_progress', 'to_verify')").fetchall()
        finally:
            if own:
                con.close()
    except Exception:  # noqa: BLE001 — no index (yet): the next launch repairs them
        return []
    jobs_dir = blurt_home() / "jobs"
    return [(Path(p), j) for p, j in rows if p.endswith(".md") and "/" not in j  # a legacy row is read-only
            and not (jobs_dir / f"{j}.json").is_file()]


def repair_work(dry_run: bool = False) -> list[str]:
    """Once per dangling reference (items.py migrate --all, at every app launch; idempotent): forget the session id
    so nothing offers to open it. The item keeps its state — the app says the session ended without reporting back,
    and the user takes it back or marks it done. A v0.6 run was a session Blurt started, so `to` says so."""
    fixed = []
    for path, job in dangling_work():
        if not path.is_file():
            continue
        if dry_run:
            fixed.append(str(path))
            continue

        def forget(it, job=job):
            w = it.get("work") if isinstance(it.get("work"), dict) else None
            if not w or w.get("job") != job:
                return {"_write": False}  # changed since the index saw it
            it["work"] = {**{k: w.get(k) for k in WORK_KEYS}, "job": None, "to": w.get("to") or "session"}
            return {}
        try:
            mutate(path, forget)
        except (ItemsError, Unparseable, OSError):
            continue
        fixed.append(str(path))
    return fixed


def ensure_uids(session: Path) -> dict:
    """A v2 session nobody ingested yet: persist the legacy uid of every item (as v2 did). Ingested: nothing to do."""
    src = session / "items.json"
    if not src.is_file():
        return {"ok": True, "assigned": 0}
    with items_lock(session):
        try:
            data = json.loads(src.read_text(encoding="utf-8-sig"))
        except ValueError as e:
            fail(f"{src}: not valid JSON ({e})", "bad_json")
        n = 0
        for k, it in enumerate(data.get("items") or []):
            if isinstance(it, dict) and it.get("id") and not it.get("uid"):
                data["items"][k] = {"id": it["id"], "uid": legacy_uid(session.name, it["id"]),
                                    **{x: v for x, v in it.items() if x != "id"}}
                n += 1
        if n or data.get("schema") != 2:
            data = {"schema": 2, **{k: v for k, v in data.items() if k != "schema"}}
            write_text_atomic(src, json.dumps(data, ensure_ascii=False, indent=2))
    return {"ok": True, "assigned": n}


# ------------------------------------------------------------------ the index (contract C2: best effort)
def reindex_touched() -> None:
    """Keep $BLURT_HOME/index.db fresh. Only when an index exists — nobody reads it otherwise — and never at the
    cost of the write that already happened."""
    paths = list(dict.fromkeys(TOUCHED))
    TOUCHED.clear()
    if not paths or os.environ.get("BLURT_NO_INDEX") or not (blurt_home() / "index.db").is_file():
        return
    try:
        import index  # noqa: PLC0415
        with contextlib.redirect_stdout(io.StringIO()):
            index.update_paths(paths)
    except (Exception, SystemExit):
        pass


# ------------------------------------------------------------------ CLI
class Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse exits 2; the contract says 1 for bad arguments
        fail(f"{self.prog}: {message}")


def add_state_filters(s, fix: bool = False) -> None:
    s.add_argument("--state", action="append", default=[], choices=list(STATES))
    s.add_argument("--kind", action="append", default=[])
    # before K3's one state (old callers): mapped to states
    s.add_argument("--status", action="append", default=[], choices=list(REVIEW_STATES), help=argparse.SUPPRESS)
    s.add_argument("--work", action="append", default=[], choices=list(LEGACY_WORK), help=argparse.SUPPRESS)
    if fix:
        s.add_argument("--fix-state", action="append", default=[], choices=[*FIX_STATES, "none"],
                       help=argparse.SUPPRESS)


def build_parser() -> Parser:
    p = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    s = sub.add_parser("ingest")
    s.add_argument("session")
    s = sub.add_parser("add")
    s.add_argument("session", nargs="?")
    s.add_argument("--project")
    s.add_argument("--json", required=True)
    s.add_argument("--after", metavar="REF")
    s = sub.add_parser("patch")
    s.add_argument("target", nargs="+", metavar="REF | SESSION ID")
    s.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    s.add_argument("--unset", action="append", default=[], metavar="KEY")
    s.add_argument("--force", action="store_true", help="overwrite fields the user edited (only if they asked)")
    s = sub.add_parser("set-frames")
    s.add_argument("target", nargs="+", metavar="REF | SESSION ID, then PATH[@T][#CAPTION] …")
    s.add_argument("--append", action="store_true")
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("done")
    s.add_argument("session")
    s = sub.add_parser("get")
    s.add_argument("target", nargs="+", metavar="REF | SESSION ID")
    s = sub.add_parser("list")
    s.add_argument("session", nargs="?")
    s.add_argument("--project")
    add_state_filters(s, fix=True)
    s = sub.add_parser("state", aliases=["work"])
    s.add_argument("target", nargs="+", metavar="REF")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--state", choices=list(STATES))
    g.add_argument("--action", choices=list(ACTIONS))
    s.add_argument("--undo", action="store_true", help=argparse.SUPPRESS)  # the user takes back their last change
    s.add_argument("--to", choices=["session", "external"])
    s.add_argument("--agent")
    s.add_argument("--job")
    s.add_argument("--handoff")
    s.add_argument("--claim", choices=["fixed", "wontfix"])
    s.add_argument("--commit")
    s.add_argument("--pr")
    s.add_argument("--note")
    s.add_argument("--by", choices=list(WORK_BY), default="agent")
    s = sub.add_parser("fix")
    s.add_argument("target", nargs="+", metavar="REF | SESSION ID")
    s.add_argument("--state", required=True, choices=list(FIX_STATES))
    s.add_argument("--agent", help="agents.json id, or 'human'")
    s.add_argument("--run-id")
    s.add_argument("--commit")
    s.add_argument("--pr")
    s.add_argument("--note")
    s = sub.add_parser("move")
    s.add_argument("target", nargs="+", metavar="REF")
    s.add_argument("--project", required=True)
    s.add_argument("--from", dest="only_from", action="append", metavar="PROJECT",
                   help="move only the items still in this project (repeatable); the rest stay where they are")
    s.add_argument("--by", choices=["user"], default="user", help=argparse.SUPPRESS)  # older callers pass it
    for name in ("doc", "poll"):
        s = sub.add_parser(name)
        s.add_argument("session", nargs="?")
        s.add_argument("--project")
        add_state_filters(s)
        s.add_argument("--item", metavar="REF", help="always include this item (the one a detail pane shows)")
        if name == "poll":
            s.add_argument("--etag", required=True)
    s = sub.add_parser("user-ops")
    s.add_argument("session", nargs="?")
    s.add_argument("--project")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--json", metavar="OPS")
    g.add_argument("--stdin", action="store_true")
    s.add_argument("--confirm", action="store_true", help="the user finished the review (reviewed: true)")
    add_state_filters(s)  # the doc that comes back
    s.add_argument("--item", metavar="REF", help="always include this item in the doc that comes back")
    s = sub.add_parser("migrate")
    s.add_argument("sessions", nargs="*")
    s.add_argument("--all", action="store_true")
    s.add_argument("--no-projects", action="store_true")
    s.add_argument("--root")
    s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("path")
    s.add_argument("ref")
    s = sub.add_parser("ensure-uids")
    s.add_argument("session")
    return p


def _session_arg(v: str | None) -> Path | None:
    if v is None:
        return None
    if not os.path.isdir(v):
        fail(f"{v}: no such session folder", "not_found")
    return real(v)


def run(a) -> dict:
    if a.cmd == "ingest":
        return ingest(_session_arg(a.session))
    if a.cmd == "add":
        try:
            fields = json.loads(a.json)
        except ValueError as e:
            fail(f"--json: {e}")
        return add(_session_arg(a.session), resolve_project(a.project) if a.project else None, fields, a.after)
    if a.cmd in ("patch", "get", "fix"):
        session, refs = target_of(a.target)
        if session is not None:
            prepare(session)
        if len(refs) != 1:
            fail(f"{a.cmd}: expected REF or SESSION ID")
        ref = refs[0]
        if a.cmd == "get":
            return get(session, ref)
        if a.cmd == "fix":
            return fix(session, ref, a.state, {"agent": a.agent, "run_id": a.run_id, "commit": a.commit,
                                               "pr": a.pr, "note": a.note})
        sets = {}
        for kv in a.set:
            k, eq, v = kv.partition("=")
            if not eq or not k:
                fail(f"--set {kv!r}: expected KEY=VALUE")
            sets[k] = parse_value(v)
        if ref == ".":
            if session is None:
                fail("'.' (the session itself) needs SESSION")
            return patch_batch(session, sets, a.unset)
        path, uid, into = locate(session, ref)
        if path is None:
            if into is None:
                fail(f"no item {ref}", "not_found")
            return {"ok": True, "id": ref, "skipped": f"merged into {_id_of(into)}" if into else "removed by the user"}
        if into is not None:
            return {"ok": True, "id": ref, "skipped": f"merged into {_id_of(into)}"}
        out = patch(path, sets, a.unset, a.force, session)
        touch_batch(st.read_header(path))
        return out
    if a.cmd == "set-frames":
        session, rest = target_of(a.target)
        if session is not None:
            prepare(session)
        if len(rest) < 2:
            fail("set-frames: expected REF (or SESSION ID) and at least one PATH")
        return set_frames(session, rest[0], [parse_frame(f) for f in rest[1:]], a.append, a.force)
    if a.cmd == "done":
        return done(_session_arg(a.session))
    if a.cmd == "list":
        return list_items(_session_arg(a.session), a.project, a.kind,
                          filter_states(a.state, a.status, a.work, a.fix_state))
    if a.cmd in ("state", "work"):
        session, refs = target_of(a.target)
        if session is not None:
            prepare(session)
        if not refs:
            fail(f"{a.cmd}: expected REF …")
        given = {"to": a.to, "agent": a.agent, "job": a.job, "handoff": a.handoff, "claim": a.claim,
                 "commit": a.commit, "pr": a.pr, "note": a.note}
        return change_state(session, refs, a.state, a.action, given, a.by, a.undo)
    if a.cmd == "move":
        session, refs = target_of(a.target)
        return move(session, refs, a.project, a.only_from)
    if a.cmd in ("doc", "poll"):
        scope = scope_of(_session_arg(a.session), a.project)
        doc = make_doc(scope, a.kind, filter_states(a.state, a.status, a.work), a.item)
        tag = doc_etag(doc)
        if a.cmd == "poll" and a.etag == tag:
            return {"ok": True, "etag": tag}
        return {"ok": True, "doc": doc, "etag": tag}
    if a.cmd == "user-ops":
        if a.stdin:
            raw = sys.stdin.buffer.read().decode("utf-8-sig")
        elif a.json is not None:
            raw = a.json
        elif a.confirm:
            raw = "[]"
        else:
            fail("user-ops: pass --json OPS or --stdin")
        ops = parse_ops(raw)
        scope = scope_of(_session_arg(a.session), a.project)
        apply_user_ops(scope, ops, a.confirm)
        doc = make_doc(scope, a.kind, filter_states(a.state, a.status, a.work), a.item)
        return {"ok": True, "etag": doc_etag(doc), "doc": doc}
    if a.cmd == "migrate":
        if a.all:
            import projects  # noqa: PLC0415
            if not a.dry_run:
                projects.cmd_migrate()
            out = migrate(migrate_candidates(projects_too=not a.no_projects), a.dry_run)
            return {**out, "repaired": repair_work(a.dry_run)}
        if a.root:
            sessions = migrate_candidates(Path(a.root))
        elif a.sessions:
            sessions = [Path(s) for s in a.sessions]
        else:
            fail("migrate: pass --all, --root DIR or SESSION …")
        return migrate(sessions, a.dry_run)
    if a.cmd == "path":
        path = find_path(a.ref)
        if path is None:
            fail(f"no item {a.ref}", "not_found")
        h = st.read_header(path)
        s = st.store_of_item(path)
        return {"ok": True, "path": str(path), "store": str(s.root), "project": h.get("project") or s.project_id,
                "uid": h.get("uid"), "id": h.get("id")}
    if a.cmd == "ensure-uids":
        return ensure_uids(_session_arg(a.session))
    fail(f"unknown command {a.cmd}")


def patch_batch(session: Path, sets: dict, unsets: list[str]) -> dict:
    with items_lock(session):
        b = load_batch(session)
        if b is None:
            fail(f"{session}: no items yet — write items.json first (§3)", "not_found")
        written = []
        for k, v in sets.items():
            if k in BATCH_PROTECTED:
                fail(f"can't set {k}", "protected")
            b[k] = v
            written.append(k)
        for k in unsets:
            if k in BATCH_PROTECTED:
                fail(f"can't unset {k}", "protected")
            if b.pop(k, None) is not None:
                written.append(k)
        b["agent_at"] = now_iso()
        save_batch(session, b)
    return {"ok": True, "id": ".", "written": written}


def main(argv: list[str] | None = None) -> dict | None:
    global _NAMES
    _NAMES = None
    TOUCHED.clear()
    try:
        out = run(build_parser().parse_args(argv))
    except ItemsError as e:
        _error(str(e), e.code, e.exit_code)
    except TimeoutError as e:
        _error(str(e), "locked", EXIT_LOCKED)
    emit(out)
    reindex_touched()
    return out


def _error(msg: str, code: str, exit_code: int):
    reindex_touched()
    print(json.dumps({"ok": False, "error": msg, "code": code}, ensure_ascii=False), flush=True)
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
