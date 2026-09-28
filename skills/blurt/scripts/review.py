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
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, load_session, save_session  # noqa: E402

HTML = Path(__file__).with_name("review.html")


def make_handler(session: Path, done: threading.Event, history_url: str = ""):

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
                return self._send(200, HTML.read_text().replace("<!-- HISTORY_LINK -->", ('<p><a class="btn primary" href="' + __import__('html').escape(history_url, quote=True) + '">查看完整处理记录 →</a></p>') if history_url else '').encode(), "text/html; charset=utf-8")
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
            path = urlparse(self.path).path
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if path in ("/api/items", "/api/confirm"):
                data = json.loads(body or b"{}")
                if path == "/api/confirm":
                    data["reviewed"] = True
                save_session(session, data)
                if path == "/api/confirm":
                    archive = session / "reviews"
                    archive.mkdir(exist_ok=True)
                    (archive / (str(time.time_ns()) + "-" + uuid.uuid4().hex[:6] + ".json")).write_text(
                        json.dumps({"confirmed_at": time.time(), "items": data.get("items", [])}, ensure_ascii=False), encoding="utf-8")
                self._send(200, b'{"ok":true}', "application/json")
                if path == "/api/confirm":
                    done.set()
                return
            self._send(404, b"not found", "text/plain")

    return H


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("session")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--no-open", action="store_true")
    p.add_argument("--history-url", default="")
    a = p.parse_args()
    session = Path(a.session)
    if load_session(session) is None:
        die(f"{session}: no items.json yet")
    done = threading.Event()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(session, done, a.history_url))
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
