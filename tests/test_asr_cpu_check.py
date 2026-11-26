"""Fun-ASR-Nano on the CPU only where it gives text (docs/design/windows-models.md §Processors): the CPU-flag rule,
the probe kept per model / runtime / processor, the recogniser Windows and Linux pick, and the server loading the
next model when the probe comes back empty. No model: a fake decoder stands in.

  uv run --with numpy --with pytest pytest tests/test_asr_cpu_check.py -q
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
os.environ.setdefault("BLURT_HOME", tempfile.mkdtemp(prefix="blurt-home-"))

import transcribe as T  # noqa: E402


class CpuCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.p = [mock.patch.object(T, "CPU_CHECK_FILE", self.tmp / "asr-cpu-check.json"),
                  mock.patch.object(T, "_cpu_checks", None),
                  mock.patch.object(T, "platform_key", lambda: "windows-x86_64")]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in reversed(self.p):
            p.stop()

    def state(self, vnni):
        with mock.patch.object(T, "x86_vnni", lambda: vnni):
            return T.fun_cpu_state()

    def test_flags_decide_until_the_probe_has_spoken(self):
        self.assertEqual(self.state(True), "ok")
        self.assertEqual(self.state(None), "unknown")      # Windows without AVX-512: maybe AVX-VNNI
        self.assertEqual(self.state(False), "no")
        T.save_cpu_check(T.FUN_CPU, False, "")
        self.assertEqual(self.state(True), "no")           # the probe wins over the flags
        T.save_cpu_check(T.FUN_CPU, True, "这个feature下周上线。")
        self.assertEqual(self.state(False), "ok")

    def test_not_x86_is_fine(self):
        with mock.patch.object(T, "platform_key", lambda: "linux-arm64"):
            self.assertEqual(self.state(None), "ok")

    def test_kept_per_processor_and_runtime(self):
        T.save_cpu_check(T.FUN_CPU, False, "")
        self.assertIs(T.cpu_check(T.FUN_CPU), False)
        with mock.patch.object(T, "_cpu_name", lambda: "another processor"):
            self.assertIsNone(T.cpu_check(T.FUN_CPU))

    def test_recogniser(self):
        hw = {"ram_gb": 16, "perf_cores": 6}
        self.assertEqual(T.cpu_recognizer(hw, ["zh"], fun_ok=True), T.FUN_CPU)
        self.assertEqual(T.cpu_recognizer(hw, ["zh"], fun_ok=False), T.QWEN_CPU)
        self.assertEqual(T.cpu_recognizer({"ram_gb": 4}, ["zh"], fun_ok=True), T.SV)
        with mock.patch.object(T, "x86_vnni", lambda: None):
            self.assertEqual(T.cpu_recognizer(hw, ["zh"]), T.QWEN_CPU)   # unknown: not picked by itself

    def test_runs_here(self):
        fun = T.entry(T.FUN_CPU)
        with mock.patch.object(T, "x86_vnni", lambda: None):
            self.assertTrue(T.runs_here(fun))              # here: its probe decides when it loads
        T.save_cpu_check(T.FUN_CPU, False, "")
        self.assertFalse(T.runs_here(fun))
        self.assertTrue(T.runs_here(fun, "windows-x86_64"))   # another machine's question: the registry only
        self.assertTrue(T.runs_here(T.entry(T.QWEN_CPU)))

    def probe(self, heard):
        b = object.__new__(T.FunAsrOnnx)
        b._decode = lambda x: (heard, "zh")
        return b._probe()

    def test_probe(self):
        self.assertTrue(T.PROBE_WAV.is_file())
        self.probe("这个feature下周上线。")
        self.assertIs(T.cpu_check(T.FUN_CPU), True)
        T.save_cpu_check(T.FUN_CPU, True, "")
        with mock.patch.object(T, "_cpu_name", lambda: "an AVX2 processor"):
            with self.assertRaises(T.Fail) as e:
                self.probe("。")
            self.assertEqual(e.exception.code, "cpu_unsupported")
            self.assertIs(T.cpu_check(T.FUN_CPU), False)

    def test_known_bad_is_refused_before_loading(self):
        T.save_cpu_check(T.FUN_CPU, False, "")
        with mock.patch.object(T, "_model_dir", lambda a, name: ROOT), \
                mock.patch.object(Path, "exists", lambda self: True):
            with self.assertRaises(T.Fail) as e:
                T.FunAsrOnnx(Namespace(threads=1))
        self.assertEqual(e.exception.code, "cpu_unsupported")


class NextModel(unittest.TestCase):
    def test_a_failed_load_forgets_the_closed_model(self):
        eng = T.NoteEngine()
        old = mock.Mock()
        eng.backend, eng.name, eng.model_id = old, "fun-asr-onnx", "x"

        def resolve(a, purpose):
            a.model_id = "fun-asr-nano-onnx"
            return "fun-asr-onnx"
        with mock.patch.object(T, "resolve_backend", resolve), \
                mock.patch.object(T, "make_backend", side_effect=T.Fail("no text", "cpu_unsupported")):
            with self.assertRaises(T.Fail):
                eng.load(None, "fun-asr-nano-onnx")
        old.close.assert_called_once()
        self.assertIsNone(eng.backend)
        self.assertIsNone(eng.model_id)


if __name__ == "__main__":
    unittest.main()
