"""A dictation never downloads a model (docs/design/dictation.md §Takes in flight): `note --no-download`, a request's
"no_download", and `serve --no-download`'s preload all answer model_missing instead — the app then says "No speech
model · Download…" rather than typing 110 s later. No model and no network: fake parts stand in.

  uv run --with numpy --with pytest pytest tests/test_transcribe_no_download.py -q
"""
from __future__ import annotations

import os
import unittest
from argparse import Namespace
from unittest import mock

import test_asr_select as A

T = A.T


class NoDownload(unittest.TestCase):
    def setUp(self):
        self._env = os.environ.pop("BLURT_NO_DOWNLOAD", None)

    def tearDown(self):
        os.environ.pop("BLURT_NO_DOWNLOAD", None)
        if self._env is not None:
            os.environ["BLURT_NO_DOWNLOAD"] = self._env

    def test_the_block_refuses_downloads_and_puts_things_back(self):
        def boom(*_a, **_k):
            raise AssertionError("a download started")
        with mock.patch.object(T, "_download_url", boom):
            with T.no_download(True):
                self.assertEqual(os.environ.get("BLURT_NO_DOWNLOAD"), "1")
                with self.assertRaises(T.Fail) as e:
                    T.download("never-here-for-this-test.onnx")
                self.assertEqual(e.exception.code, "model_missing")
            self.assertNotIn("BLURT_NO_DOWNLOAD", os.environ)
            # off: as before (nothing set)
            with T.no_download(False):
                self.assertNotIn("BLURT_NO_DOWNLOAD", os.environ)
        # set from outside (live.py): left as it was
        os.environ["BLURT_NO_DOWNLOAD"] = "1"
        with T.no_download(True):
            pass
        self.assertEqual(os.environ.get("BLURT_NO_DOWNLOAD"), "1")

    def test_note_no_download_never_asks_the_server_and_never_downloads(self):
        seen = {}

        class Engine:
            def note(self, *a, **k):
                seen["env"] = os.environ.get("BLURT_NO_DOWNLOAD")
                raise T.Fail("sensevoice-small is not downloaded", "model_missing")

        a = Namespace(wav=__file__, language="auto", model_id=None, no_server=True, dictation=True, vocab=False,
                      no_download=True)
        with mock.patch.object(T, "_server_call", side_effect=AssertionError("asked the server")), \
                mock.patch.object(T, "NoteEngine", Engine), mock.patch.object(T, "throttle", lambda *_: None):
            with self.assertRaises(T.Fail) as e:
                T.cmd_note(a)
        self.assertEqual(e.exception.code, "model_missing")
        self.assertEqual(seen["env"], "1")

    def test_the_cli_takes_the_flags(self):
        import inspect
        src = inspect.getsource(T.main)
        self.assertIn('"--no-download"', src)
        self.assertIn('"--no-server"', src)


class DictationReady(unittest.TestCase):
    """`dictation-models` says whether a take can run with nothing downloaded — the VAD included, and a selected model
    that isn't one of the local rows (a cloud one) judged by itself — so the key never refuses a working setup and
    never listens for a take that is bound to fail."""

    def _models(self, *, vad: bool, have: set[str], configured=None, note="sensevoice-small"):
        import tempfile
        from pathlib import Path
        d = Path(tempfile.mkdtemp())
        if vad:
            (d / "silero_vad.onnx").write_bytes(b"x")
        hw = {"kind": "apple", "tier": "standard", "ram_gb": 16, "chip": "Apple M2", "fingerprint": "t"}
        cfg = {"record": {"dictation": {"asr_model": configured}}} if configured else {}
        with mock.patch.object(T, "MODELS_DIR", d), mock.patch.object(T, "global_config", lambda: cfg), \
                mock.patch.object(T, "select", lambda _p: {"id": note}), \
                mock.patch.object(T, "installed", lambda m: m["id"] in have), \
                mock.patch.object(T, "runs_here", lambda m: True), mock.patch.object(T, "_fits", lambda m, h: True), \
                mock.patch.object(T, "hw_kind", lambda h: "apple"):
            return T.dictation_models(hw)

    def test_ready_needs_the_vad_too(self):
        r = self._models(vad=False, have={T.QWEN_MLX})
        self.assertEqual(r["selected"], T.QWEN_MLX)
        self.assertTrue(r["selected_installed"])
        self.assertFalse(r["ready"])
        self.assertEqual(r["missing"], ["silero-vad"])

    def test_ready_with_model_and_vad(self):
        r = self._models(vad=True, have={T.QWEN_MLX})
        self.assertTrue(r["ready"])
        self.assertEqual(r["missing"], [])

    def test_a_selected_model_outside_the_rows_is_judged_by_itself(self):
        cloud = next(m["id"] for m in T.entries() if not m.get("local", True))
        self.assertNotIn(cloud, T.DICTATION_MODELS)
        r = self._models(vad=True, have={cloud}, note=cloud)
        self.assertEqual(r["selected"], cloud)
        self.assertTrue(r["selected_installed"])
        self.assertTrue(r["ready"])

    def test_nothing_on_this_mac(self):
        r = self._models(vad=False, have=set())
        self.assertFalse(r["ready"])
        self.assertEqual(r["missing"], ["silero-vad", r["selected"]])

    def test_configured_installed(self):
        r = self._models(vad=True, have={T.SV}, configured=T.SV)
        self.assertEqual(r["configured"], T.SV)
        self.assertTrue(r["configured_installed"])
        self.assertEqual(r["selected"], T.SV)


if __name__ == "__main__":
    unittest.main()
