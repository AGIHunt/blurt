"""The review handler serialises its writes: confirm waits for an autosave in flight, late writes are refused, a
failed confirm can be retried, and the server only exits after the final write."""
from __future__ import annotations

import io
import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
from test_store import TmpCase, ok  # noqa: E402

import items  # noqa: E402
import review  # noqa: E402


class ReviewPersistence(TmpCase):
    def setUp(self):
        super().setUp()
        self.session = self.e.ws / "inbox" / "sessions" / "20261022-101500"
        self.session.mkdir(parents=True)
        (self.session / "items.json").write_text(json.dumps({"items": [{"id": "I-001", "kind": "note", "title": "draft"}]}))
        ok("items.py", "ingest", self.session, env=self.e.env())
        self.done = threading.Event()
        self.handler = review.make_handler(self.session, self.done)

    def post(self, path, data, send=None):
        request = self.handler.__new__(self.handler)
        body = json.dumps(data).encode()
        request.path, request.command, request.headers = path, "POST", {"Content-Length": str(len(body))}
        request.rfile, request._send = io.BytesIO(body), Mock(side_effect=send)
        request.do_POST()
        return request._send.call_args.args[0]

    def title(self) -> str:
        return ok("items.py", "get", "IN-1", env=self.e.env())["item"]["title"]

    def batch(self) -> dict:
        return json.loads((self.session / "batch.json").read_text())

    def test_confirm_serializes_with_autosave_and_rejects_late_writes(self):
        saving, release, confirming, final_write = (threading.Event() for _ in range(4))
        original = items.save_batch

        def slow_save(session, b):
            if not b.get("reviewed"):
                saving.set()
                if not release.wait(5):
                    raise TimeoutError("autosave was not released")
            else:
                final_write.set()
            original(session, b)

        def confirm():
            confirming.set()
            return self.post("/api/confirm", {"ops": [{"op": "set", "id": "I-001", "set": {"title": "final"}}]})

        with patch.object(items, "save_batch", side_effect=slow_save), ThreadPoolExecutor(2) as pool:
            autosave = pool.submit(self.post, "/api/items", {"ops": [{"op": "set", "id": "I-001", "set": {"title": "x"}}]})
            try:
                self.assertTrue(saving.wait(5))
                confirmation = pool.submit(confirm)
                self.assertTrue(confirming.wait(5))
                self.assertFalse(final_write.wait(0.1), "writes overlapped")
            finally:
                release.set()
            self.assertEqual((autosave.result(5), confirmation.result(5)), (200, 200))
        self.assertEqual(self.post("/api/items", {"ops": []}), 409)
        self.assertEqual(self.title(), "final")
        self.assertTrue(self.batch()["reviewed"])
        self.assertTrue(self.done.is_set())

    def test_failed_confirm_can_retry_and_exit_waits_for_response(self):
        with patch.object(items, "save_batch", side_effect=OSError("disk full")):
            self.assertEqual(self.post("/api/confirm", {"ops": []}), 500)
        self.assertFalse(self.batch()["reviewed"])
        self.assertFalse(self.done.is_set())

        def disconnected(*_):
            self.assertFalse(self.done.is_set())
            self.assertEqual(self.post("/api/items", {"ops": []}), 409)
            raise BrokenPipeError("tab disconnected after the final write")

        with self.assertRaises(BrokenPipeError):
            self.post("/api/confirm", {"ops": []}, send=disconnected)
        self.assertTrue(self.done.is_set())
        self.assertTrue(self.batch()["reviewed"])

    def test_whole_documents_are_refused(self):
        """v0.5 pages posted the whole items.json; v3 takes the user's edits only (the agent's writes survive)."""
        self.assertEqual(self.post("/api/items", {"items": [{"id": "I-001", "title": "clobber"}]}), 400)
        self.assertEqual(self.title(), "draft")


if __name__ == "__main__":
    import unittest
    unittest.main()
