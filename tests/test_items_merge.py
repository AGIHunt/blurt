"""The agent (items.py) and the review page (review.py) write the same items at the same time (contract K1)."""
from __future__ import annotations

import io
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parent))
from test_store import TmpCase, ok  # noqa: E402

import review  # noqa: E402
import store as st  # noqa: E402

DOC = {"title": "s", "source_video": "recording.mp4", "processing": True, "language": "en", "items": [
    {"id": f"I-00{n}", "kind": "issue", "title": f"item {n}", "actual": f"a{n}", "status": "draft"} for n in range(1, 6)]}


class Merge(TmpCase):
    def setUp(self):
        super().setUp()
        proj = self.tmp / "my-app"
        proj.mkdir()
        ok("projects.py", "add", proj, env=self.e.env())
        self.s = proj / ".blurt" / "sessions" / "20261022-101500"
        (self.s / "frames").mkdir(parents=True)
        for n in range(1, 6):
            (self.s / "frames" / f"I-00{n}-1.jpg").write_bytes(b"jpg")
        (self.s / "items.json").write_text(json.dumps(DOC))
        ok("items.py", "ingest", self.s, env=self.e.env())
        self.done = threading.Event()
        self.handler = review.make_handler({"session": str(self.s)}, self.done)

    def items_py(self, *args, check=True):
        from test_store import run_cli  # noqa: PLC0415
        code, out = run_cli("items.py", *args, env=self.e.env())
        if check:
            assert code == 0, out
        return out

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

    def item(self, ref):
        p = ok("items.py", "path", ref, env=self.e.env())["path"]
        return st.read_item(Path(p))

    def test_user_edit_wins_and_agent_fields_land(self):
        self.ops({"op": "set", "id": "I-001", "set": {"title": "mine"}})
        out = self.items_py("patch", self.s, "I-001", "--set", "title=agent's", "--set", 'code_refs=["a.py:3"]')
        self.assertEqual((out["written"], out["kept_user"]), (["code_refs"], ["title"]))
        self.items_py("set-frames", self.s, "I-001", "frames/I-001-1.jpg@3.5#the button")
        i = self.item("MA-1")
        self.assertEqual((i["title"], i["code_refs"]), ("mine", ["a.py:3"]))
        self.assertEqual(i["frames"], [{"path": f"assets/{i['uid']}/1.jpg", "t": 3.5, "caption": "the button"}])
        self.assertIn("title", i["_user"])
        self.assertNotIn("frames", i["_user"])
        # a later page save of another field must not drop what the agent wrote meanwhile
        code, body = self.ops({"op": "set", "id": "I-001", "set": {"actual": "edited"}})[:2]
        self.assertEqual(code, 200)
        first = json.loads(body)["items"][0]
        self.assertEqual(first["frames"][0]["t"], 3.5)  # the page rebases on this
        self.assertTrue(first["frames"][0]["path"].startswith("/"))  # absolute in the doc …
        self.assertEqual(self.item("MA-1")["frames"][0]["path"], f"assets/{i['uid']}/1.jpg")  # … relative on disk
        # the page sends the frames back as it got them (absolute): they stay relative to the store
        self.ops({"op": "set", "id": first["uid"], "set": {"frames": list(reversed(first["frames"] * 2))[:1]}})
        self.assertEqual(self.item("MA-1")["frames"][0]["path"], f"assets/{i['uid']}/1.jpg")
        self.items_py("patch", "MA-1", "--set", "title=from chat", "--force")
        self.assertEqual(self.item("MA-1")["title"], "from chat")

    def test_concurrent_agent_and_user_writes_lose_nothing(self):
        def agent(n):
            self.items_py("set-frames", self.s, f"I-00{n}", f"frames/I-00{n}-1.jpg@{n}")
            self.items_py("patch", self.s, f"I-00{n}", "--set", f"module=m{n}")

        def user(n):
            for k in range(5):
                self.assertEqual(self.ops({"op": "set", "id": f"I-00{n}", "set": {"actual": f"u{n}-{k}"}})[0], 200)

        with ThreadPoolExecutor(10) as pool:
            for f in [pool.submit(agent, n) for n in range(1, 6)] + [pool.submit(user, n) for n in range(1, 6)]:
                f.result(120)
        for n in range(1, 6):
            i = self.item(f"MA-{n}")
            self.assertEqual((i["frames"][0]["t"], i["module"], i["actual"]), (n, f"m{n}", f"u{n}-4"))

    def test_dropped_and_merged_stay_gone(self):
        self.ops({"op": "set", "id": "I-002", "set": {"status": "deleted", "_dropped": True, "_touched": True}},
                 {"op": "set", "id": "I-003", "set": {"merged_from": ["I-004"], "quote": "x … y"}},
                 {"op": "remove", "id": "I-004", "into": "I-003"})
        out = self.items_py("patch", self.s, "I-002", "--set", "severity=high")
        self.assertIn("note", out)
        self.items_py("patch", self.s, "I-002", "--set", "status=draft")  # an agent can't bring it back
        self.assertEqual((self.item("MA-2")["state"], self.item("MA-2")["restore_to"]), ("discarded", "new"))
        out = self.items_py("patch", self.s, "I-004", "--set", "title=back?")
        self.assertEqual(out["skipped"], "merged into MA-3")
        out = self.items_py("set-frames", self.s, "I-004", "frames/I-004-1.jpg")
        self.assertEqual(out["appended_to"], "MA-3")  # its evidence goes to the item it was merged into
        self.assertEqual(len(self.item("MA-3")["frames"]), 1)
        out = self.items_py("add", self.s, "--json", '{"id":"I-004","kind":"issue","title":"again"}', check=False)
        self.assertEqual(out["code"], "taken")
        self.assertEqual(self.items_py("add", self.s, "--json", '{"kind":"idea","title":"new"}', "--after", "I-001")["id"],
                         "MA-6")
        doc = json.loads(self.request("GET", "/api/items")[1])
        self.assertEqual([i["id"] for i in doc["items"]], ["MA-1", "MA-6", "MA-2", "MA-3", "MA-5"])
        # undoing the merge on the page brings it back where it was
        self.ops({"op": "add", "item": {"id": "I-004", "kind": "issue", "title": "item 4"}, "after": "I-003"})
        doc = json.loads(self.request("GET", "/api/items")[1])
        self.assertEqual([i["id"] for i in doc["items"]], ["MA-1", "MA-6", "MA-2", "MA-3", "MA-4", "MA-5"])
        self.assertEqual(doc["_removed"], {})
        self.assertEqual((self.item("MA-4")["state"], self.item("MA-4").get("merged_into")), ("new", None))

    def test_confirm_while_processing(self):
        code = self.ops({"op": "state", "id": "I-001", "action": "keep"}, path="/api/confirm")[0]
        self.assertEqual(code, 200)
        self.assertTrue(self.done.is_set())
        b = json.loads((self.s / "batch.json").read_text())
        self.assertTrue(b["reviewed"] and b["processing"])
        self.assertEqual(self.ops({"op": "set", "id": "I-001", "set": {"title": "late"}})[0], 409)
        self.items_py("set-frames", self.s, "I-005", "frames/I-005-1.jpg")  # the agent finishes the frames anyway
        out = self.items_py("done", self.s)
        self.assertEqual(out["no_frames"], ["MA-1", "MA-2", "MA-3", "MA-4"])
        self.assertTrue(out["reviewed"])
        b = json.loads((self.s / "batch.json").read_text())
        self.assertFalse(b["processing"])
        self.assertEqual(self.item("MA-1")["state"], "todo")
        s = review.summary({"session": str(self.s)})
        self.assertEqual((s["reviewed"], s["kept"], s["kinds"]), (True, 5, {"issue": 5}))

    def test_lock_is_shared_across_processes(self):
        started = time.monotonic()
        held = threading.Event()
        store = st.Store(self.s.parent.parent)

        def hold():
            with store.lock():
                held.set()
                time.sleep(1.2)

        t = threading.Thread(target=hold)
        t.start()
        held.wait(5)
        self.items_py("patch", "MA-1", "--set", "owner=x")  # another process: waits for the lock
        self.assertGreaterEqual(time.monotonic() - started, 1.1)
        t.join()
        with store.lock():  # and the page's writes wait too
            box = []
            th = threading.Thread(target=lambda: box.append(self.ops({"op": "set", "id": "I-001", "set": {"due": "x"}})))
            th.start()
            th.join(0.4)
            self.assertTrue(th.is_alive(), "page write did not wait for the lock")
        th.join(5)
        self.assertEqual(box[0][0], 200)
        self.assertEqual((self.item("MA-1")["owner"], self.item("MA-1")["due"]), ("x", "x"))

    def test_poll_etag(self):
        code, body, _, extra = self.request("GET", "/api/items")
        self.assertEqual(code, 200)
        self.assertFalse(json.loads(body)["_video"])  # no recording.mp4 here, like a shots session
        self.assertEqual(self.request("GET", "/api/items", headers={"If-None-Match": extra["ETag"]})[0], 304)
        self.items_py("patch", self.s, ".", "--set", "digest=## hi")
        self.assertEqual(self.request("GET", "/api/items", headers={"If-None-Match": extra["ETag"]})[0], 200)
        self.assertEqual(json.loads((self.s / "batch.json").read_text())["digest"], "## hi")


if __name__ == "__main__":
    import unittest
    unittest.main()
