"""Dictation's live text (docs/design/dictation.md §Live text): the open piece's audio so far goes to the warm speech
server as an *interim* request, and the server stops that decode as soon as another request is waiting — a final
piece never waits for an interim one. A model that can't stop halfway takes no interim requests. No model: fake
backends stand in.

  uv run --with numpy --with pytest pytest tests/test_transcribe_interim.py -q
"""
from __future__ import annotations

import tempfile
import threading
import time
import unittest
from argparse import Namespace
from pathlib import Path

import test_asr_select as A

T = A.T
SR = A.SR


class Stoppable(A.FakeBackend):
    """An interim decode takes 3 s, looking at stop_check every 10 ms (as Qwen3Mlx does between tokens); a final one
    is quick."""
    interruptible = True
    stop_check = None
    calls: list = []

    def transcribe(self, x):
        Stoppable.calls.append("interim" if self.stop_check else "final")
        if self.stop_check is not None:
            for _ in range(300):
                if self.stop_check():
                    raise T.Interrupted("waiting")
                time.sleep(0.01)
        return super().transcribe(x)


class Plain(A.FakeBackend):
    """A backend that can't stop halfway (SenseVoice, Whisper…)."""


class Interim(unittest.TestCase):
    def setUp(self):
        self.patches = {"BACKENDS": T.BACKENDS, "vad_segments": T.vad_segments}
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / SR)]
        self.real = A.fake_installed("sensevoice-small")
        self.tmp = Path(tempfile.mkdtemp())
        Stoppable.calls = []

    def tearDown(self):
        for k, v in self.patches.items():
            setattr(T, k, v)
        T.installed = self.real

    def serve(self, backend):
        T.BACKENDS = {**self.patches["BACKENDS"], "sensevoice": backend}
        n = A.Notes()
        th, _out = n.serve_in_thread(Namespace(preload=True, idle=600, exit_after=1800, parent=None))
        return th

    def stop(self, th):
        T._server_call({"cmd": "exit"})
        th.join(5)

    def note(self, seconds, **kw):
        return T._server_call({"cmd": "note", "wav": str(A.write_wav(self.tmp / f"{seconds}-{time.time()}.wav", seconds)),
                               "language": "auto", "purpose": None, **kw}, timeout=10)

    def test_a_final_piece_never_waits_for_an_interim_decode(self):
        with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
            th = self.serve(Stoppable)
            try:
                got = {}
                t = threading.Thread(target=lambda: got.update(self.note(8.0, interim=True)))
                t.start()
                time.sleep(0.3)                     # the interim decode is under way (it would take 3 s)
                t0 = time.perf_counter()
                final = self.note(4.0)
                waited = time.perf_counter() - t0
                t.join(5)
            finally:
                self.stop(th)
        self.assertEqual((final["ok"], final["text"]), (True, "heard 4.0s"))
        self.assertLess(waited, 0.5, waited)       # one 10 ms step and the request itself, not the remaining 2.7 s
        self.assertEqual((got.get("ok"), got.get("code"), got.get("interim")), (False, "interrupted", True), got)
        self.assertEqual(Stoppable.calls, ["interim", "final"])

    def test_an_interim_decode_alone_answers(self):
        with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
            th = self.serve(Stoppable)
            try:
                r = self.note(2.0, interim=True)
                # the stop check is off again for the next (final) request
                f = self.note(1.0)
            finally:
                self.stop(th)
        self.assertEqual((r["ok"], r["text"], r["interim"]), (True, "heard 2.0s", True))
        self.assertTrue(f["ok"])
        self.assertNotIn("interim", f)

    def test_a_model_that_cannot_stop_takes_no_interim_requests(self):
        with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
            th = self.serve(Plain)
            try:
                r = self.note(2.0, interim=True)
                f = self.note(2.0)
            finally:
                self.stop(th)
        self.assertEqual((r["ok"], r["code"]), (False, "interim_unsupported"))
        self.assertTrue(f["ok"])


class QwenStops(unittest.TestCase):
    """Qwen3Mlx without the model: an interrupted decode propagates (it is not taken for a broken tag-aware decoder),
    and an interim request uses the interruptible loop even when no language is preferred."""

    def backend(self, prefer=None):
        b = object.__new__(T.Qwen3Mlx)
        b.m, b.repo, b.args = None, "fake", type("A", (), {"language": None})()
        b.context = b.base_context = ""
        b.names, b.prefer, b.tagged, b.last = [], prefer, True, {}
        return b

    def test_interrupted_is_not_a_broken_decoder(self):
        b = self.backend("Chinese")

        def dec(x, ctx, prefer):
            raise T.Interrupted("waiting")
        b._decode_tagged = dec
        b.stop_check = lambda: True
        with self.assertRaises(T.Interrupted):
            b.decode([0.0] * SR)
        self.assertTrue(b.tagged)
        self.assertTrue(b.interruptible)

    def test_interim_without_a_preferred_language_uses_the_loop(self):
        b = self.backend(None)
        seen = []

        def dec(x, ctx, prefer):
            seen.append(prefer)
            return "hello", "en"
        b._decode_tagged = dec
        b.stop_check = lambda: False
        self.assertEqual(b.decode([0.0] * SR)[0][2], "hello")
        self.assertEqual(seen, [None])
        # a final request (no stop check, no preferred language) keeps the library's own decode
        b.stop_check = None
        b.m = type("M", (), {"transcribe": staticmethod(lambda x, **k: type("R", (), {"text": "plain", "language": "English"})())})
        self.assertEqual(b.decode([0.0] * SR)[0][2], "plain")
        self.assertEqual(seen, [None])
