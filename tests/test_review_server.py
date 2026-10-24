"""review.py as a server: only its own token path, its own address and JSON from its own origin get anything; the Blurt
app's handshake (api/attached, api/done, or batch.json turning reviewed) ends the wait; a page nobody uses closes; files
are served from disk in capped ranges.

  uv run --with pytest pytest tests/test_review_server.py -q
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_smoke import SCRIPTS, Base  # noqa: E402

import review  # noqa: E402


class ReviewServer(Base):
    def start(self, **env):
        proc = subprocess.Popen([sys.executable, str(SCRIPTS / "review.py"), str(self.session), "--no-open"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                env=self.env.env(**env))
        self.addCleanup(proc.kill)
        url = proc.stdout.readline().split()[-1]
        self.assertRegex(url, r"^http://127\.0\.0\.1:\d+/r/[A-Za-z0-9_-]{20,}/$")
        return proc, url

    def call(self, url, data=None, **headers):
        req = urllib.request.Request(url, data=None if data is None else json.dumps(data).encode(),
                                     method="GET" if data is None else "POST", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def summary(self, proc, timeout=10):
        return json.loads(proc.communicate(timeout=timeout)[0].strip().splitlines()[-1])

    def test_only_its_own_page_address_and_origin(self):
        proc, url = self.start()
        root = url.split("/r/")[0]
        port = root.rsplit(":", 1)[1]
        self.assertEqual(self.call(url + "api/items")[0], 200)
        self.assertEqual(self.call(url)[0], 200)
        self.assertEqual(self.call(root + "/api/items")[0], 404)  # no token
        self.assertEqual(self.call(root + "/r/not-the-token/api/items")[0], 404)
        self.assertEqual(self.call(url + "api/items", Host=f"evil.test:{port}")[0], 403)  # DNS rebinding
        self.assertEqual(self.call(url + "api/items", Host=f"localhost:{port}")[0], 200)
        ops = {"ops": []}
        self.assertEqual(self.call(url + "api/items", ops, **{"Content-Type": "text/plain"})[0], 415)  # a form post
        self.assertEqual(self.call(url + "api/items", ops, **{"Content-Type": "application/json",
                                                               "Origin": "https://evil.test"})[0], 403)
        self.assertEqual(self.call(url + "api/items", ops, **{"Content-Type": "application/json",
                                                               "Origin": root})[0], 200)
        self.assertEqual(self.call(url + "api/confirm", ops, **{"Content-Type": "text/plain"})[0], 415)
        self.assertIsNone(proc.poll())  # nothing above confirmed it

    def test_the_apps_confirm_ends_the_wait(self):
        proc, url = self.start()
        self.assertEqual(self.call(url + "api/attached")[0], 200)  # the app shows the batch: no browser
        # the app's page confirms through items.py (not this server), then tells review.py
        p = self.run_script(SCRIPTS / "items.py", "user-ops", self.session, "--json", "[]", "--confirm")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.call(url + "api/done", {}, **{"Content-Type": "application/json"})
        out = self.summary(proc)
        self.assertEqual((out["reviewed"], out["kept"]), (True, 4))

    def test_a_confirm_in_the_app_is_seen_even_without_its_answer(self):
        proc, url = self.start()
        p = self.run_script(SCRIPTS / "items.py", "user-ops", self.session, "--json", "[]", "--confirm")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.summary(proc)["reviewed"])  # batch.json turned reviewed

    def test_a_page_nobody_uses_closes(self):
        proc, url = self.start(BLURT_REVIEW_IDLE="1.5")
        t = time.time()
        out = self.summary(proc, timeout=15)
        self.assertFalse(out["reviewed"])
        self.assertLess(time.time() - t, 12)

    def test_files_stream_in_capped_ranges(self):
        big = self.session / "frames" / "clip.mp4"
        big.write_bytes(b"x" * (review.RANGE_CAP + 5 * 2**20))
        proc, url = self.start()
        f = url + "files/" + urllib.parse.quote(str(big), safe="")
        req = urllib.request.Request(f, headers={"Range": "bytes=0-"})
        with urllib.request.urlopen(req, timeout=10) as r:
            self.assertEqual((r.status, len(r.read())), (206, review.RANGE_CAP))
            self.assertEqual(r.headers["Content-Range"], f"bytes 0-{review.RANGE_CAP - 1}/{big.stat().st_size}")
        with urllib.request.urlopen(f, timeout=10) as r:  # whole: streamed, same bytes
            self.assertEqual(len(r.read()), big.stat().st_size)
        self.assertEqual(self.call(f, Range="bytes=-4")[1], b"xxxx")
        self.assertEqual(self.call(f, Range=f"bytes={big.stat().st_size}-")[0], 416)


def test_byte_range():
    cap = review.RANGE_CAP
    assert review.byte_range("bytes=2-4", 10) == (2, 4)
    assert review.byte_range("bytes=0-", 400 * 2**20) == (0, cap - 1)
    assert review.byte_range("bytes=-3", 10) == (7, 9)
    assert review.byte_range("bytes=5-100", 10) == (5, 9)
    assert review.byte_range("bytes=10-", 10) is None
    assert review.byte_range("bytes=x-", 10) is None
