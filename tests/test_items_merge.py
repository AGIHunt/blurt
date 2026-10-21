"""The agent (items.py) and the review page (review.py) write the same items.json at the same time."""
import io
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import Mock

SCRIPTS = Path(__file__).resolve().parents[1] / "skills/blurt/scripts"
sys.path.insert(0, str(SCRIPTS))
import review  # noqa: E402
from _common import items_lock, load_session, save_session  # noqa: E402

DOC = {"session": "s", "source_video": "recording.mp4", "processing": True, "items": [
    {"id": f"I-00{n}", "kind": "issue", "title": f"item {n}", "actual": f"a{n}", "status": "draft"} for n in range(1, 6)]}


def items_py(session, *args, check=True):
    p = subprocess.run([sys.executable, str(SCRIPTS / "items.py"), *args[:1], str(session), *args[1:]],
                       capture_output=True, text=True, encoding="utf-8", timeout=60)
    if check and p.returncode:
        raise AssertionError(p.stderr)
    return json.loads(p.stdout) if p.returncode == 0 else p


class Merge(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.s = Path(tmp.name)
        (self.s / "frames").mkdir()
        for n in range(1, 6):
            (self.s / "frames" / f"I-00{n}-1.jpg").write_bytes(b"jpg")
        save_session(self.s, json.loads(json.dumps(DOC)))
        self.done = threading.Event()
        self.handler = review.make_handler(self.s, self.done)

    def request(self, method, path, data=None, headers=None):
        r = self.handler.__new__(self.handler)
        body = json.dumps(data).encode() if data is not None else b""
        r.path, r.command = path, method
        r.headers = {"Content-Length": str(len(body)), **(headers or {})}
        r.rfile, r._send = io.BytesIO(body), Mock()
        r.do_POST() if method == "POST" else r.do_GET()
        return r._send.call_args.args

    def ops(self, *ops, path="/api/items"):
        return self.request("POST", path, {"ops": list(ops)})

    def item(self, iid):
        return next((i for i in load_session(self.s)["items"] if i["id"] == iid), None)

    def test_user_edit_wins_and_agent_fields_land(self):
        self.ops({"op": "set", "id": "I-001", "set": {"title": "mine"}})
        out = items_py(self.s, "patch", "I-001", "--set", "title=agent's", "--set", 'code_refs=["a.py:3"]')
        self.assertEqual((out["written"], out["kept_user"]), (["code_refs"], ["title"]))
        items_py(self.s, "set-frames", "I-001", "frames/I-001-1.jpg@3.5#the button")
        i = self.item("I-001")
        self.assertEqual(i["title"], "mine")
        self.assertEqual(i["code_refs"], ["a.py:3"])
        self.assertEqual(i["frames"], [{"path": "frames/I-001-1.jpg", "t": 3.5, "caption": "the button"}])
        self.assertIn("title", i["_user"])
        self.assertNotIn("frames", i["_user"])
        # a later page save of another field must not drop what the agent wrote meanwhile
        code, body = self.ops({"op": "set", "id": "I-001", "set": {"actual": "edited"}})[:2]
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["items"][0]["frames"][0]["t"], 3.5)  # the page rebases on this
        self.assertEqual(self.item("I-001")["frames"][0]["path"], "frames/I-001-1.jpg")
        # --force: the user asked for it in chat
        items_py(self.s, "patch", "I-001", "--set", "title=from chat", "--force")
        self.assertEqual(self.item("I-001")["title"], "from chat")

    def test_concurrent_agent_and_user_writes_lose_nothing(self):
        def agent(n):
            items_py(self.s, "set-frames", f"I-00{n}", f"frames/I-00{n}-1.jpg@{n}")
            items_py(self.s, "patch", f"I-00{n}", "--set", f"module=m{n}")

        def user(n):
            for k in range(5):
                self.assertEqual(self.ops({"op": "set", "id": f"I-00{n}", "set": {"actual": f"u{n}-{k}"}})[0], 200)

        with ThreadPoolExecutor(10) as pool:
            for f in [pool.submit(agent, n) for n in range(1, 6)] + [pool.submit(user, n) for n in range(1, 6)]:
                f.result(60)
        for n in range(1, 6):
            i = self.item(f"I-00{n}")
            self.assertEqual((i["frames"][0]["t"], i["module"], i["actual"]), (n, f"m{n}", f"u{n}-4"))

    def test_dropped_and_merged_stay_gone(self):
        self.ops({"op": "set", "id": "I-002", "set": {"status": "deleted", "_dropped": True, "_touched": True}},
                 {"op": "set", "id": "I-003", "set": {"merged_from": ["I-004"], "quote": "x … y"}},
                 {"op": "remove", "id": "I-004", "into": "I-003"})
        out = items_py(self.s, "patch", "I-002", "--set", "status=draft", "--set", "severity=high")
        self.assertEqual(out["kept_user"], ["status"])
        self.assertIn("note", out)
        self.assertEqual(self.item("I-002")["status"], "deleted")
        out = items_py(self.s, "patch", "I-004", "--set", "title=back?")
        self.assertEqual(out["skipped"], "merged into I-003")
        self.assertIsNone(self.item("I-004"))
        out = items_py(self.s, "set-frames", "I-004", "frames/I-004-1.jpg")
        self.assertEqual(out["appended_to"], "I-003")  # its evidence goes to the item it was merged into
        self.assertEqual([f["path"] for f in self.item("I-003")["frames"]], ["frames/I-004-1.jpg"])
        p = items_py(self.s, "add", "--json", '{"id":"I-004","kind":"issue","title":"again"}', check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(items_py(self.s, "add", "--json", '{"kind":"idea","title":"new"}', "--after", "I-001")["id"],
                         "I-006")
        self.assertEqual([i["id"] for i in load_session(self.s)["items"]], ["I-001", "I-006", "I-002", "I-003", "I-005"])
        # undoing the merge on the page brings it back
        self.ops({"op": "add", "item": {"id": "I-004", "kind": "issue", "title": "item 4"}, "after": "I-003"})
        self.assertEqual(self.item("I-004")["title"], "item 4")
        self.assertNotIn("_removed", load_session(self.s))

    def test_confirm_while_processing(self):
        code = self.ops({"op": "set", "id": "I-001", "set": {"status": "confirmed"}}, path="/api/confirm")[0]
        self.assertEqual(code, 200)
        self.assertTrue(self.done.is_set())
        data = load_session(self.s)
        self.assertTrue(data["reviewed"] and data["processing"])
        self.assertEqual(self.ops({"op": "set", "id": "I-001", "set": {"title": "late"}})[0], 409)
        items_py(self.s, "set-frames", "I-005", "frames/I-005-1.jpg")  # the agent finishes the frames anyway
        out = items_py(self.s, "done")
        self.assertEqual(out["no_frames"], ["I-001", "I-002", "I-003", "I-004"])
        data = load_session(self.s)
        self.assertNotIn("processing", data)
        self.assertTrue(data["reviewed"])
        self.assertEqual(self.item("I-001")["status"], "confirmed")

    def test_lock_is_shared_across_processes(self):
        started = time.monotonic()
        held = threading.Event()

        def hold():
            with items_lock(self.s):
                held.set()
                time.sleep(1.2)

        t = threading.Thread(target=hold)
        t.start()
        held.wait(5)
        items_py(self.s, "patch", "I-001", "--set", "owner=x")  # another process: must wait for the lock
        self.assertGreaterEqual(time.monotonic() - started, 1.1)
        t.join()
        with items_lock(self.s):  # and the page's writes wait too
            box = []
            th = threading.Thread(target=lambda: box.append(self.ops({"op": "set", "id": "I-001", "set": {"due": "x"}})))
            th.start()
            th.join(0.4)
            self.assertTrue(th.is_alive(), "page write did not wait for the lock")
        th.join(5)
        self.assertEqual(box[0][0], 200)
        self.assertEqual((self.item("I-001")["owner"], self.item("I-001")["due"]), ("x", "x"))
        self.assertEqual(list(self.s.glob("*.tmp")), [])

    def test_poll_etag(self):
        code, body, _, extra = self.request("GET", "/api/items")
        self.assertEqual(code, 200)
        self.assertFalse(json.loads(body)["_video"])  # no recording.mp4 here, like a shots session
        self.assertEqual(self.request("GET", "/api/items", headers={"If-None-Match": extra["ETag"]})[0], 304)
        items_py(self.s, "patch", ".", "--set", "digest=## hi")
        self.assertEqual(self.request("GET", "/api/items", headers={"If-None-Match": extra["ETag"]})[0], 200)
        self.assertEqual(load_session(self.s)["digest"], "## hi")


if __name__ == "__main__":
    unittest.main()
