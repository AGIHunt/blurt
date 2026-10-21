# /// script
# requires-python = ">=3.10"
# ///
"""Local review page for a session's items.json. Blocks until the user clicks "Confirm" on the page
(or Ctrl+C), then exits — run it in the background and continue when it finishes.

  review.py SESSION_DIR [--port 0] [--open app|browser|none] [--no-open]

Where the page opens (--open, else config review.open_in, else "app" on macOS / "browser" elsewhere): "app" = a window
of the Blurt menu-bar app when it is installed (asked via a distributed notification if it is running, launched with
--background otherwise), falling back to the browser if no app window has loaded the page within a few seconds.

Start it as soon as items.json has text (frames can follow): while items.json has "processing": true the page
polls and shows new frames / items as items.py writes them; the user's edits always win (see items.py).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, str(Path(__file__).parent))
from _common import (BLURT_HOME, IS_LINUX, IS_MAC, die, find_item, global_config, items_lock, load_json,  # noqa: E402
                     load_session, save_session)

HTML = Path(__file__).with_name("review.html")
SERVER_KEYS = {"id", "_user"}


def apply_user_ops(data: dict, ops: list[dict]) -> None:
    """The page sends what the user changed, not the whole list, so the agent's concurrent writes survive.
    Each field the user sets is recorded in the item's _user (field -> epoch); items.py won't overwrite those."""
    now = round(time.time(), 1)
    items = data.setdefault("items", [])
    removed = data.setdefault("_removed", {})
    for op in ops:
        kind, iid = op.get("op"), op.get("id") or (op.get("item") or {}).get("id")
        item = find_item(data, iid) if iid else None
        if kind == "set" and item is not None:
            user = item.setdefault("_user", {})
            for k, v in (op.get("set") or {}).items():
                if k not in SERVER_KEYS:
                    item[k] = v
                    if not k.startswith("_"):
                        user[k] = now
            for k in op.get("unset") or []:
                if k not in SERVER_KEYS:
                    item.pop(k, None)
                    if not k.startswith("_"):
                        user[k] = now
        elif kind == "remove" and item is not None:  # merged into another item by the user
            items.remove(item)
            removed[iid] = op.get("into") or ""
        elif kind == "add" and iid and item is None:  # e.g. undoing a merge brings the item back
            new = dict(op["item"])
            new.setdefault("_user", {})
            removed.pop(iid, None)
            after = op.get("after")
            pos = next((k + 1 for k, i in enumerate(items) if i.get("id") == after), 0 if after is None else len(items))
            items.insert(pos, new)
    if not removed:
        data.pop("_removed", None)


def etag(raw: bytes) -> str:
    return '"' + hashlib.sha1(raw).hexdigest()[:16] + '"'


def make_handler(session: Path, done: threading.Event, app_seen: threading.Event | None = None):
    write_lock = threading.Lock()
    confirmed = False

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
            if path.startswith("/files/"):
                return self._file(path[len("/files/"):], download=parse_qs(u.query).get("download") == ["1"])
            self._send(404, b"not found", "text/plain")

        do_HEAD = do_GET

        def _items(self, fresh: bool = False):
            try:
                raw = (session / "items.json").read_bytes()
            except FileNotFoundError:
                raw = b'{"items": []}'
            tag = etag(raw)
            if not fresh and self.headers.get("If-None-Match") == tag:  # polled every 1.5 s: usually nothing new
                return self._send(304, b"", "application/json", {"ETag": tag})
            data = json.loads(raw.decode("utf-8-sig") or "{}")
            video = data.get("source_video")
            data["_video"] = bool(video) and (session / video).is_file()  # shots sessions have no recording
            return self._send(200, json.dumps(data, ensure_ascii=False).encode(), "application/json", {"ETag": tag})

        def _file(self, rel: str, download: bool = False):
            f = (session / rel).resolve()
            if session.resolve() not in f.parents or not f.is_file():
                return self._send(404, b"not found", "text/plain")
            size = f.stat().st_size
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            if download:  # the page's ⤓ button: save it, with a name that says which session it came from
                name = f"{session.name}-{f.name}".replace('"', "")
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
            if path in ("/api/items", "/api/confirm"):
                data = json.loads(body or b"{}")
                ops = data.get("ops") if isinstance(data, dict) else None
                with write_lock:
                    if confirmed:
                        return self._send(409, b"already confirmed", "text/plain")
                    try:
                        with items_lock(session):
                            if ops is not None:  # current page: a patch, merged into what is on disk now
                                data = load_session(session) or {"items": []}
                                apply_user_ops(data, ops)
                            # else: an older page posting the whole document — last writer wins, as before
                            if path == "/api/confirm":
                                data["reviewed"] = True
                            save_session(session, data)
                    except (OSError, TimeoutError):
                        return self._send(500, b"could not save", "text/plain")
                    confirmed = path == "/api/confirm"
                try:
                    if ops is not None:
                        self._items(fresh=True)  # the merged result, so the page rebases on it
                    else:
                        self._send(200, b'{"ok":true}', "application/json")
                finally:
                    if path == "/api/confirm":
                        done.set()
                return
            self._send(404, b"not found", "text/plain")

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


def ask_app(url: str, session: Path, title: str) -> str | None:
    """Ask the Blurt app to show the page: "running" (posted to it), "launched", or None (no app)."""
    info = load_json(BLURT_HOME / "app.json", {}) or {}
    if _pid_alive(info.get("pid")):
        js = ('function run(a){ObjC.import("Foundation");var d=$.NSDictionary.dictionaryWithObjectsForKeys('
              '$([a[0],a[1],a[2],a[3]]),$(["url","session","title","home"]));'
              '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('
              '"dev.blurt.recorder.review",$(),d,true);return "ok"}')
        r = subprocess.run(["osascript", "-l", "JavaScript", "-e", js, url, str(session.resolve()), title, str(BLURT_HOME)],
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return "running"
    for app in app_candidates(info):
        env = [] if "BLURT_HOME" not in os.environ else ["--env", f"BLURT_HOME={BLURT_HOME}"]
        if os.environ.get("BLURT_WORKSPACE"):
            env += ["--env", f"BLURT_WORKSPACE={os.environ['BLURT_WORKSPACE']}"]
        r = subprocess.run(["open", "-n", "-g", "-a", str(app), *env, "--args", "--background", "--review", url,
                            "--review-session", str(session.resolve())], capture_output=True, text=True, timeout=20)
        if r.returncode == 0:
            return "launched"
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("session")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--open", choices=("app", "browser", "none"), help="where to show the page (default: config review.open_in)")
    p.add_argument("--no-open", action="store_true", help="= --open none")
    a = p.parse_args()
    session = Path(a.session)
    if load_session(session) is None:
        die(f"{session}: no items.json yet")
    done, app_seen = threading.Event(), threading.Event()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(session, done, app_seen))
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"REVIEW {url}", flush=True)
    mode = "none" if a.no_open else open_mode(a.open)
    if mode == "app":
        how = ask_app(url, session, (load_session(session) or {}).get("title") or session.name)
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
    data = load_session(session) or {}
    items = data.get("items", [])
    kept = [i for i in items if i.get("status") != "deleted"]
    kinds: dict[str, int] = {}
    for i in kept:
        kinds[i["kind"]] = kinds.get(i["kind"], 0) + 1
    # merged items leave the list; say so, or the agent reads the gap as data loss and restores them
    merged = {i["id"]: i["merged_from"] for i in items if i.get("merged_from")}
    print(json.dumps({"reviewed": bool(data.get("reviewed")), "kept": len(kept), "kinds": kinds,
                      "deleted": len(items) - len(kept), **({"merged": merged} if merged else {}),
                      # confirmed before all frames were in: finish them anyway, then `items.py done`
                      **({"processing": True} if data.get("processing") else {}),
                      "file": str(session / "items.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
