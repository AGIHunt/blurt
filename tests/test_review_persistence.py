"""Regression tests for the review handler's serialized writes and final snapshot."""
import io
import json
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/blurt/scripts"))
import review
from _common import load_session, save_session


class ReviewPersistence(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.session = Path(tmp.name)
        self.done = threading.Event()
        self.handler = review.make_handler(self.session, self.done)

    def post(self, path, data, send=None):
        request = self.handler.__new__(self.handler)
        body = json.dumps(data).encode()
        request.path, request.headers = path, {"Content-Length": str(len(body))}
        request.rfile, request._send = io.BytesIO(body), Mock(side_effect=send)
        request.do_POST()
        return request._send.call_args.args[0]

    def test_confirm_serializes_with_autosave_and_rejects_late_writes(self):
        saving, release, confirming, final_write = (threading.Event() for _ in range(4))
        original, final = {"items": [{"title": "draft"}]}, {"items": [{"title": "final"}]}

        def slow_save(session, data):
            if not data.get("reviewed"):
                saving.set()
                if not release.wait(5):
                    raise TimeoutError("autosave was not released")
            else:
                final_write.set()
            save_session(session, data)

        def confirm():
            confirming.set()
            return self.post("/api/confirm", final)

        with patch.object(review, "save_session", side_effect=slow_save), ThreadPoolExecutor(2) as pool:
            autosave = pool.submit(self.post, "/api/items", original)
            try:
                self.assertTrue(saving.wait(5))
                confirmation = pool.submit(confirm)
                self.assertTrue(confirming.wait(5))
                self.assertFalse(final_write.wait(0.1), "writes overlapped")
            finally:
                release.set()
            self.assertEqual((autosave.result(5), confirmation.result(5)), (200, 200))
        self.assertEqual(self.post("/api/items", original), 409)
        self.assertEqual(load_session(self.session), {**final, "reviewed": True})
        self.assertTrue(self.done.is_set())

    def test_failed_confirm_can_retry_and_exit_waits_for_response(self):
        original = {"items": [{"title": "keep this"}]}
        save_session(self.session, original)
        with patch.object(review, "save_session", side_effect=OSError("disk full")):
            self.assertEqual(self.post("/api/confirm", {"items": []}), 500)
        self.assertEqual(load_session(self.session), original)
        self.assertFalse(self.done.is_set())

        def disconnected(*_):
            self.assertFalse(self.done.is_set())
            self.assertEqual(self.post("/api/items", {"items": []}), 409)
            raise BrokenPipeError("tab disconnected after the final write")

        with self.assertRaises(BrokenPipeError):
            self.post("/api/confirm", original, send=disconnected)
        self.assertTrue(self.done.is_set())
        self.assertEqual(load_session(self.session), {**original, "reviewed": True})
