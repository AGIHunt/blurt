# /// script
# requires-python = ">=3.10"
# ///
"""Local review page for a session's items.json. Blocks until the user clicks "Confirm" in the browser
(or Ctrl+C), then exits — run it in the background and continue when it finishes.

  review.py SESSION_DIR [--port 0] [--no-open]
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, load_session, save_session  # noqa: E402

HTML = Path(__file__).with_name("review.html")


def make_handler(session: Path, done: threading.Event):
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
                self.wfile.write(body)

        def do_GET(self):
            path = unquote(urlparse(self.path).path)
            if path in ("/", "/index.html"):
                return self._send(200, HTML.read_bytes(), "text/html; charset=utf-8")
            if path in ("/icon.png", "/favicon.ico"):
                icon = Path(__file__).resolve().parent.parent / "assets" / "icon.png"
                return self._send(200, icon.read_bytes(), "image/png") if icon.exists() else self._send(404, b"", "text/plain")
            if path == "/api/items":
                return self._send(200, json.dumps(load_session(session) or {"items": []}).encode(), "application/json")
            if path.startswith("/files/"):
                return self._file(path[len("/files/"):])
            self._send(404, b"not found", "text/plain")

        do_HEAD = do_GET

        def _file(self, rel: str):
            f = (session / rel).resolve()
            if session.resolve() not in f.parents or not f.is_file():
                return self._send(404, b"not found", "text/plain")
            size = f.stat().st_size
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
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
            if path not in ("/api/items", "/api/confirm"):
                return self._send(404, b"not found", "text/plain")
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length < 0:
                    raise ValueError("negative content length")
                data = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeError):
                return self._send(400, b'{"error":"invalid JSON body"}', "application/json")
            if not isinstance(data, dict) or not isinstance(data.get("items"), list) or any(
                not isinstance(item, dict) or not isinstance(item.get("kind"), str) for item in data["items"]
            ):
                return self._send(400, b'{"error":"expected an items array with kind on each item"}', "application/json")

            # The check and write must be atomic: a delayed autosave must never replace a confirmed session.
            # Also serialize save_session's shared temporary file across request threads.
            with write_lock:
                if confirmed:
                    code, body = 409, b'{"error":"review already confirmed"}'
                else:
                    if path == "/api/confirm":
                        data["reviewed"] = True
                    try:
                        save_session(session, data)
                    except OSError:
                        code, body = 500, b'{"error":"could not save review"}'
                    else:
                        if path == "/api/confirm":
                            confirmed = True
                        code, body = 200, b'{"ok":true}'
            try:
                self._send(code, body, "application/json")
            finally:
                if path == "/api/confirm" and code == 200:
                    # Keep the server alive until the response is sent (or the browser disconnects).
                    done.set()

    return H


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("session")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--no-open", action="store_true")
    a = p.parse_args()
    session = Path(a.session)
    if load_session(session) is None:
        die(f"{session}: no items.json yet")
    done = threading.Event()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(session, done))
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"REVIEW {url}", flush=True)
    if not a.no_open:
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
    print(json.dumps({"reviewed": bool(data.get("reviewed")), "kept": len(kept), "kinds": kinds,
                      "deleted": len(items) - len(kept), "file": str(session / "items.json")}))


if __name__ == "__main__":
    main()
