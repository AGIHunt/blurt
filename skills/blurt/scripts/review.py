# /// script
# requires-python = ">=3.10"
# ///
"""Local review page for a session's items (or a whole project's). Blocks until the user clicks "Confirm" on the page
(or Ctrl+C), then exits — run it in the background and continue when it finishes.

  review.py SESSION_DIR [--port 0] [--open app|browser|none] [--no-open]
  review.py --project P|inbox [--port 0] [--open …]

Where the page opens (--open, else config review.open_in, else "app" on macOS / "browser" elsewhere): "app" = a window
of the Blurt menu-bar app when it is installed (asked via a distributed notification if it is running, launched with
--background otherwise), falling back to the browser if no app window has loaded the page within a few seconds.

Start it as soon as items.json has text (frames can follow): it ingests items.json, and while the batch is still
"processing" the page polls and shows new frames / items as items.py writes them; the user's edits always win.

HTTP (contract K1): GET /api/items → the doc (`items.py doc`, ETag; 304 on If-None-Match); POST /api/items {ops} and
POST /api/confirm {ops} → the merged doc (same code path as `items.py user-ops`); POST /api/handoff {uids, what} →
{id, path, text} (handoff.py create --mark; the doc's `_caps` says so); GET /files/<percent-encoded absolute
path> for files in a known store, a session dir or $BLURT_HOME/handoff (the old /files/<path relative to the session>
works too).
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import subprocess
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, str(Path(__file__).parent))
from _common import BLURT_HOME, IS_LINUX, IS_MAC, blurt_home, die, file_etag, global_config, load_json, real  # noqa: E402
import items as items_mod  # noqa: E402
import store as st  # noqa: E402

HTML = Path(__file__).with_name("review.html")


def etag(raw: bytes) -> str:
    return file_etag(raw)


def allowed_roots(scope: dict) -> list[Path]:
    """What /files/ may serve: every known store (sessions are inside them), the scope's session, the v0.6
    recordings, $BLURT_HOME/handoff."""
    roots = [s.root for s in items_mod.all_stores()]
    if scope.get("session"):
        roots += [real(scope["session"]), st.store_of_session(Path(scope["session"])).root]
    roots += [real(st.legacy_recordings()), real(blurt_home() / "handoff")]
    return list(dict.fromkeys(roots))


def make_handler(scope: dict | Path, done: threading.Event, app_seen: threading.Event | None = None):
    if not isinstance(scope, dict):
        scope = {"session": str(real(scope))}
    write_lock = threading.Lock()
    confirmed = False
    session = Path(scope["session"]) if scope.get("session") else None

    def current_doc() -> tuple[dict, str]:
        items_mod._NAMES = None  # project names may have changed since the last request
        doc = items_mod.make_doc(scope)
        doc["_caps"] = ["handoff"]  # POST /api/handoff (host protocol v3): the page offers the copy buttons
        return doc, items_mod.doc_etag(doc)

    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):  # the browser dropped a video range request
                    pass

        def _json(self, code: int, obj, extra: dict | None = None):
            return self._send(code, json.dumps(obj, ensure_ascii=False).encode(), "application/json", extra)

        def do_GET(self):
            u = urlparse(self.path)
            path = unquote(u.path)
            if path in ("/", "/index.html"):
                if app_seen is not None and parse_qs(u.query).get("in") == ["app"]:
                    app_seen.set()  # the Blurt app's window has the page: no browser needed
                return self._send(200, HTML.read_bytes(), "text/html; charset=utf-8")
            if path in ("/icon.png", "/favicon.ico"):
                icon = Path(__file__).resolve().parent.parent / "assets" / "icon.png"
                return self._send(200, icon.read_bytes(), "image/png") if icon.exists() else self._send(404, b"", "text/plain")
            if path == "/api/items":
                return self._items()
            if u.path.startswith("/files/"):
                return self._file(unquote(u.path[len("/files/"):]), download=parse_qs(u.query).get("download") == ["1"])
            self._send(404, b"not found", "text/plain")

        do_HEAD = do_GET

        def _items(self, fresh: bool = False):
            try:
                doc, tag = current_doc()
            except items_mod.ItemsError as e:
                return self._json(500, {"ok": False, "error": str(e), "code": e.code})
            if not fresh and self.headers.get("If-None-Match") == tag:  # polled every 1.5 s: usually nothing new
                return self._send(304, b"", "application/json", {"ETag": tag})
            return self._json(200, doc, {"ETag": tag})

        def _file(self, ref: str, download: bool = False):
            # /files/%2FUsers%2F… (the contract), /files//Users/… (a page joining "files/" and an absolute path),
            # or /files/frames/… relative to the session (v0.6 pages)
            if os.path.isabs(ref) or (len(ref) > 2 and ref[1] == ":"):
                cands = [Path(ref)]
            else:
                cands = ([session / ref] if session else []) + [Path("/" + ref)]
            roots = allowed_roots(scope)
            f = next((real(c) for c in cands if real(c).is_file()
                      and any(r == real(c) or r in real(c).parents for r in roots)), None)
            if f is None:
                return self._send(404, b"not found", "text/plain")
            size = f.stat().st_size
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            if download:  # the page's download button: a name that says where it came from
                origin = session.name if session else f.parent.name
                name = f"{origin}-{f.name}".replace('"', "")
                return self._send(200, f.read_bytes(), ctype, {"Content-Disposition": f'attachment; filename="{name}"'})
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes="):  # video seeking needs range requests
                a, _, b = rng[6:].partition("-")
                start = int(a or 0)
                end = min(int(b) if b else size - 1, start + 8 * 2**20, size - 1)
                with open(f, "rb") as fh:
                    fh.seek(start)
                    body = fh.read(end - start + 1)
                return self._send(206, body, ctype, {"Content-Range": f"bytes {start}-{end}/{size}",
                                                     "Accept-Ranges": "bytes"})
            self._send(200, f.read_bytes(), ctype, {"Accept-Ranges": "bytes"})

        def do_POST(self):
            nonlocal confirmed
            path = urlparse(self.path).path
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if path not in ("/api/items", "/api/confirm", "/api/handoff"):
                return self._send(404, b"not found", "text/plain")
            try:
                data = json.loads(body or b"{}")
            except ValueError:
                return self._json(400, {"ok": False, "error": "not JSON", "code": "bad_json"})
            if path == "/api/handoff":
                return self._handoff(data)
            ops = data.get("ops") if isinstance(data, dict) else None
            if ops is None and path == "/api/items":
                return self._json(400, {"ok": False, "error": "send the user's edits as {ops: [...]}", "code": "bad_args"})
            with write_lock:
                if confirmed:
                    return self._send(409, b"already confirmed", "text/plain")
                try:
                    items_mod.TOUCHED.clear()
                    items_mod.apply_user_ops(scope, ops or [], confirm=path == "/api/confirm")
                except items_mod.ItemsError as e:  # e.g. an empty title: nothing saved, the page reverts
                    return self._json(400, {"ok": False, "error": str(e), "code": e.code})
                except (OSError, TimeoutError):
                    return self._send(500, b"could not save", "text/plain")
                finally:
                    items_mod.reindex_touched()
                confirmed = path == "/api/confirm"
            try:
                self._items(fresh=True)  # the merged result, so the page rebases on it
            finally:
                if path == "/api/confirm":
                    done.set()

        def _handoff(self, data):
            """{uids, what: instruction|full} → a hand-off note for the user's own agent (K6), its items marked
            handed off; → {id, path, text}, the text the page copies."""
            import handoff
            uids = data.get("uids") if isinstance(data, dict) else None
            if not isinstance(uids, list) or not uids or not all(isinstance(u, str) for u in uids):
                return self._json(400, {"ok": False, "error": "send {uids: [...], what}", "code": "bad_args"})
            what = data.get("what") if data.get("what") in ("instruction", "full") else "instruction"
            with write_lock:
                try:
                    h = handoff.create(uids, mark=True)
                except handoff.CliError as e:
                    return self._json(400, {"ok": False, "error": str(e), "code": e.code})
            return self._json(200, {"ok": True, "id": h["id"], "path": h["path"], "items": h["items"],
                                    "text": h["full"] if what == "full" else h["instruction"]})

    return H


def open_mode(arg: str | None, cfg: dict | None = None) -> str:
    """--open, else config review.open_in, else the app on macOS and the browser elsewhere."""
    if arg:
        return arg
    want = ((cfg if cfg is not None else global_config()).get("review") or {}).get("open_in")
    if want in ("app", "browser", "none"):
        return "browser" if want == "app" and not IS_MAC else want
    return "app" if IS_MAC else "browser"


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def app_candidates(info: dict) -> list[Path]:
    """Blurt.app bundles that would read this BLURT_HOME: the one that last ran, the built one, the installed one."""
    out = [Path(info["path"])] if info.get("path") else []
    out.append(BLURT_HOME / "Blurt.app")
    if "BLURT_HOME" not in os.environ:
        out.append(Path.home() / "Applications" / "Blurt.app")
    return [p for p in dict.fromkeys(out) if (p / "Contents" / "MacOS" / "blurt-recorder").exists()]


def ask_app(url: str, where: Path, title: str) -> str | None:
    """Ask the Blurt app to show the page: "running" (posted to it), "launched", or None (no app)."""
    info = load_json(BLURT_HOME / "app.json", {}) or {}
    if _pid_alive(info.get("pid")):
        js = ('function run(a){ObjC.import("Foundation");var d=$.NSDictionary.dictionaryWithObjectsForKeys('
              '$([a[0],a[1],a[2],a[3]]),$(["url","session","title","home"]));'
              '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('
              '"dev.blurt.recorder.review",$(),d,true);return "ok"}')
        r = subprocess.run(["osascript", "-l", "JavaScript", "-e", js, url, str(where), title, str(BLURT_HOME)],
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return "running"
    for app in app_candidates(info):
        env = [] if "BLURT_HOME" not in os.environ else ["--env", f"BLURT_HOME={BLURT_HOME}"]
        if os.environ.get("BLURT_WORKSPACE"):
            env += ["--env", f"BLURT_WORKSPACE={os.environ['BLURT_WORKSPACE']}"]
        r = subprocess.run(["open", "-n", "-g", "-a", str(app), *env, "--args", "--background", "--review", url,
                            "--review-session", str(where)], capture_output=True, text=True, timeout=20)
        if r.returncode == 0:
            return "launched"
    return None


def summary(scope: dict) -> dict:
    """What the agent reads when the page closes."""
    doc = items_mod.make_doc(scope)
    items = doc["items"]
    kept = [i for i in items if i.get("status") != "deleted"]
    kinds: dict[str, int] = {}
    for i in kept:
        kinds[i.get("kind") or "note"] = kinds.get(i.get("kind") or "note", 0) + 1
    # merged items leave the list; say so, or the agent reads the gap as data loss and restores them
    merged = {i["id"]: i["merged_from"] for i in items if i.get("merged_from")}
    where = Path(scope["session"]) / "batch.json" if scope.get("session") else Path(items_mod.store_for_project(
        scope["project"]).root)
    return {"reviewed": bool(doc.get("reviewed")), "kept": len(kept), "kinds": kinds,
            "deleted": len(items) - len(kept), **({"merged": merged} if merged else {}),
            # confirmed before all frames were in: finish them anyway, then `items.py done`
            **({"processing": True} if doc.get("processing") else {}), "file": str(where),
            "items": [{"id": i["id"], "uid": i["uid"], "path": i["path"]} for i in kept]}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("session", nargs="?")
    p.add_argument("--project")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--open", choices=("app", "browser", "none"), help="where to show the page (default: config review.open_in)")
    p.add_argument("--no-open", action="store_true", help="= --open none")
    a = p.parse_args()
    try:
        if a.session:
            session = real(a.session)
            items_mod.prepare(session)
            if not (session / "batch.json").is_file():
                die(f"{session}: no items yet — write items.json first")
            scope = {"session": str(session)}
            where = session
        elif a.project:
            scope = {"project": items_mod.resolve_project(a.project)}
            where = items_mod.store_for_project(scope["project"]).root
        else:
            die("pass SESSION_DIR or --project P")
    except items_mod.ItemsError as e:
        die(str(e))
    finally:
        items_mod.reindex_touched()
    done, app_seen = threading.Event(), threading.Event()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(scope, done, app_seen))
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"REVIEW {url}", flush=True)
    mode = "none" if a.no_open else open_mode(a.open)
    if mode == "app":
        how = ask_app(url, where, items_mod.make_doc(scope).get("title") or where.name)
        if how and app_seen.wait(6 if how == "running" else 20):
            print("(opened in a Blurt window)", file=sys.stderr, flush=True)
        else:
            print("(no Blurt app window — opening the browser)", file=sys.stderr, flush=True)
            mode = "browser"
    # Linux without a display (SSH, container): webbrowser would fall back to a console browser and block
    has_gui = not IS_LINUX or os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
    if mode == "browser" and has_gui:
        webbrowser.open(url)
    try:
        done.wait()
    except KeyboardInterrupt:
        pass
    srv.shutdown()
    print(json.dumps(summary(scope), ensure_ascii=False))


if __name__ == "__main__":
    main()
