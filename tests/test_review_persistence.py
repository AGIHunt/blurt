"""Exercise the actual HTTP handler without opening a listening socket."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/blurt/scripts"))
import review
from _common import load_session, save_session


class Request:
    def __init__(self, path, body, *, gate=None, disconnected=False):
        headers = f"POST {path} HTTP/1.0\r\nContent-Length: {len(body)}\r\n\r\n".encode()
        self.output = bytearray()
        self.disconnected = disconnected

        class Reader(io.BytesIO):
            def read(self, size=-1):
                if gate:
                    started, release = gate
                    started.set()
                    if not release.wait(5):
                        raise TimeoutError("request body was not released")
                return super().read(size)

        self.input = Reader(headers + body)

    def makefile(self, *args):
        return self.input

    def sendall(self, body):
        if self.disconnected:
            raise BrokenPipeError("review tab disconnected")
        self.output.extend(body)

    @property
    def status(self):
        return int(self.output.split(b" ", 2)[1])


class ReviewPersistence(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.session = Path(tmp.name)
        self.original = {"items": [{"id": "I-1", "kind": "issue", "title": "Original"}]}
        save_session(self.session, self.original)
        self.done = threading.Event()
        self.handler = review.make_handler(self.session, self.done)

    def handle(self, request):
        self.handler(request, ("127.0.0.1", 12345), None)
        return request

    def post(self, path, data):
        return self.handle(Request(path, json.dumps(data).encode()))

    def test_delayed_autosave_cannot_overwrite_confirmation(self):
        started, release = threading.Event(), threading.Event()
        stale = Request("/api/items", json.dumps(self.original).encode(), gate=(started, release))
        errors = []

        def autosave():
            try:
                self.handle(stale)
            except Exception as exc:
                errors.append(exc)

        worker = threading.Thread(target=autosave, daemon=True)
        worker.start()
        try:
            self.assertTrue(started.wait(5))
            final = {"items": [{"id": "I-1", "kind": "issue", "title": "Final edit", "status": "confirmed"}]}
            self.assertEqual(self.post("/api/confirm", final).status, 200)
            saved = (self.session / "items.json").read_bytes()
        finally:
            release.set()
            worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(stale.status, 409)
        self.assertEqual((self.session / "items.json").read_bytes(), saved)
        self.assertTrue(self.done.is_set())
        self.assertTrue(load_session(self.session)["reviewed"])

    def test_repeated_confirmation_does_not_replace_final_snapshot(self):
        self.assertEqual(self.post("/api/confirm", self.original).status, 200)
        saved = (self.session / "items.json").read_bytes()
        self.assertEqual(self.post("/api/confirm", {"items": []}).status, 409)
        self.assertEqual((self.session / "items.json").read_bytes(), saved)

    def test_concurrent_requests_do_not_share_the_temporary_file(self):
        first_saving, release_first = threading.Event(), threading.Event()
        second_reading, second_saving = threading.Event(), threading.Event()
        body_ready = threading.Event()
        body_ready.set()
        errors = []
        first = Request("/api/items", json.dumps(self.original).encode())
        final = {"items": [{"id": "I-1", "kind": "issue", "title": "Final"}]}
        second = Request("/api/confirm", json.dumps(final).encode(), gate=(second_reading, body_ready))

        def slow_save(session, data):
            if data["items"][0]["title"] == "Original":
                first_saving.set()
                if not release_first.wait(5):
                    raise TimeoutError("first save was not released")
            else:
                second_saving.set()
            save_session(session, data)

        def handle(request):
            try:
                self.handle(request)
            except Exception as exc:
                errors.append(exc)

        workers = [threading.Thread(target=handle, args=(request,), daemon=True) for request in (first, second)]
        with patch.object(review, "save_session", side_effect=slow_save):
            workers[0].start()
            try:
                self.assertTrue(first_saving.wait(5))
                workers[1].start()
                self.assertTrue(second_reading.wait(5))
                overlapped = second_saving.wait(0.25)
            finally:
                release_first.set()
                for worker in workers:
                    if worker.ident is not None:
                        worker.join(5)
        self.assertFalse(any(worker.is_alive() for worker in workers))
        self.assertEqual(errors, [])
        self.assertFalse(overlapped, "two handlers entered save_session at the same time")
        self.assertTrue(second_saving.is_set())
        self.assertEqual((first.status, second.status), (200, 200))
        self.assertEqual(load_session(self.session), {**final, "reviewed": True})

    def test_confirmation_response_finishes_before_server_exit(self):
        sending, release = threading.Event(), threading.Event()
        errors = []

        class SlowResponse(Request):
            def sendall(inner, body):
                sending.set()
                if not release.wait(5):
                    raise TimeoutError("response was not released")
                super().sendall(body)

        request = SlowResponse("/api/confirm", json.dumps(self.original).encode())

        def confirm():
            try:
                self.handle(request)
            except Exception as exc:
                errors.append(exc)

        worker = threading.Thread(target=confirm, daemon=True)
        worker.start()
        try:
            self.assertTrue(sending.wait(5))
            self.assertFalse(self.done.is_set())
            # The file is final already, but the main process must wait for its response.
            self.assertTrue(load_session(self.session)["reviewed"])
            self.assertEqual(self.post("/api/items", {"items": []}).status, 409)
        finally:
            release.set()
            worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(request.status, 200)
        self.assertTrue(self.done.is_set())

    def test_disconnected_confirmation_still_signals_completion(self):
        request = Request("/api/confirm", json.dumps(self.original).encode(), disconnected=True)
        with self.assertRaises(BrokenPipeError):
            self.handle(request)
        self.assertTrue(load_session(self.session)["reviewed"])
        self.assertTrue(self.done.is_set())

    def test_failed_write_preserves_session_and_can_be_retried(self):
        for endpoint in ("/api/items", "/api/confirm"):
            with self.subTest(endpoint=endpoint):
                with patch.object(review, "save_session", side_effect=OSError("disk full")):
                    self.assertEqual(self.post(endpoint, {"items": []}).status, 500)
                self.assertFalse(self.done.is_set())
                self.assertEqual(load_session(self.session), self.original)
        self.assertEqual(self.post("/api/confirm", self.original).status, 200)
        self.assertTrue(self.done.is_set())

    def test_invalid_payload_does_not_replace_session(self):
        for body in (b"{", b"\xff", b"null", b"[]", b"{}", b'{"items":null}'):
            with self.subTest(body=body):
                request = Request("/api/confirm", body)
                self.assertEqual(self.handle(request).status, 400)
                self.assertFalse(self.done.is_set())
                self.assertEqual(load_session(self.session), self.original)

    def test_previously_reviewed_session_can_be_opened_for_editing(self):
        save_session(self.session, {**self.original, "reviewed": True})
        self.assertEqual(self.post("/api/items", {"items": []}).status, 200)
        self.assertEqual(load_session(self.session), {"items": []})
        self.assertFalse(self.done.is_set())


if __name__ == "__main__":
    unittest.main()
