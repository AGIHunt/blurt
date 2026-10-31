"""A model switch never restarts the speech server in the middle of a request.

2026-10-31, the founder switched dictation to Whisper large-v3-turbo and dictation hung: the warm server had been
started for Qwen3-ASR (`uv run --with mlx-qwen3-asr`), and the first request for Whisper made it exec itself under
`uv run --with … mlx-whisper` right inside that request — no answer, and until the new process was up its run file
named a live pid with a closed port, so every piece of the take went to a cold CLI run (a ~30 s Whisper load each).
Now a server starts with the package of every installed model (serve_packages), and one it still lacks is a clean
restart between requests (NeedsRestart → "restarting"). Whisper also loads from its folder, not its repo id (no
huggingface.co round trip per load). No model, no network.

  uv run pytest tests/test_transcribe_serve_packages.py -q
"""
from __future__ import annotations

import argparse
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import transcribe as T  # noqa: E402


def model(mid, backend, platforms=("darwin-arm64",), local=True):
    return {"id": mid, "backend": backend, "platforms": list(platforms), "local": local}


class ServePackages(unittest.TestCase):
    def test_every_installed_local_model_on_this_platform(self):
        ms = [model("qwen3-asr-1.7b-mlx", "qwen3-asr-mlx"), model("whisper-large-v3-turbo-mlx", "mlx-whisper"),
              model("whisper-large-v3-turbo-q4-mlx", "mlx-whisper"), model("sensevoice-small", "sensevoice", ["*"]),
              model("whisper-large-v3-turbo-ct2", "faster-whisper", ["linux-x86_64"])]
        installed = {"qwen3-asr-1.7b-mlx", "whisper-large-v3-turbo-mlx", "sensevoice-small", "whisper-large-v3-turbo-ct2"}
        with mock.patch.object(T, "entries", return_value=ms), \
                mock.patch.object(T, "platform_key", return_value="darwin-arm64"), \
                mock.patch.object(T, "installed", side_effect=lambda m: m["id"] in installed):
            self.assertEqual(T.serve_packages(), ["mlx-qwen3-asr", "mlx-whisper"])

    def test_nothing_installed_nothing_added(self):
        with mock.patch.object(T, "entries", return_value=[model("whisper-large-v3-turbo-mlx", "mlx-whisper")]), \
                mock.patch.object(T, "platform_key", return_value="darwin-arm64"), \
                mock.patch.object(T, "installed", return_value=False):
            self.assertEqual(T.serve_packages(), [])


class EnsurePackage(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, T, "SERVING", False)
        p = mock.patch.dict(T.os.environ, {"BLURT_ASR_REEXEC": "mlx-qwen3-asr"})
        p.start()
        self.addCleanup(p.stop)

    def test_inside_a_server_it_is_a_restart_not_an_exec(self):
        T.SERVING = True
        with mock.patch.object(T, "_has_package", return_value=False), mock.patch.object(T, "_reexec_with") as rx:
            with self.assertRaises(T.NeedsRestart) as c:
                T.ensure_package("mlx-whisper")
        self.assertEqual(c.exception.pkg, "mlx-whisper")
        rx.assert_not_called()

    def test_a_cli_run_still_reruns_itself(self):
        with mock.patch.object(T, "_has_package", return_value=False), mock.patch.object(T, "_reexec_with") as rx:
            T.ensure_package("mlx-whisper")
        rx.assert_called_once_with(["mlx-whisper"])

    def test_a_package_already_tried_is_a_deps_failure_not_a_loop(self):
        T.SERVING = True
        with mock.patch.object(T, "_has_package", return_value=False), \
                mock.patch.object(T.os, "execvp") as ex:
            with self.assertRaises(T.Fail) as c:
                T.ensure_package("mlx-qwen3-asr")
        self.assertEqual(c.exception.code, "deps")
        ex.assert_not_called()

    def test_reexec_keeps_the_packages_already_added(self):
        with mock.patch.object(T.os, "execvp") as ex, mock.patch.object(T.shutil, "which", return_value=sys.executable), \
                mock.patch.object(T.sys, "argv", ["transcribe.py", "serve", "--preload"]):
            T._reexec_with(["mlx-whisper"])
        argv = ex.call_args[0][1]
        withs = [argv[i + 1] for i, x in enumerate(argv) if x == "--with"]
        self.assertEqual(withs, [T.PACKAGE_PINS["mlx-qwen3-asr"], T.PACKAGE_PINS["mlx-whisper"]])
        self.assertEqual(argv[-2:], ["serve", "--preload"])
        self.assertEqual(T.os.environ["BLURT_ASR_REEXEC"], "mlx-qwen3-asr,mlx-whisper")


class WhisperLoadsFromItsFolder(unittest.TestCase):
    def test_resolve_backend_gives_whisper_its_snapshot_folder(self):
        m = T.entry("whisper-large-v3-turbo-mlx")
        a = argparse.Namespace(backend=None, model=None, model_id="whisper-large-v3-turbo-mlx", language=None, prompt=None)
        snap = Path("/tmp/hf/models--mlx-community--whisper-large-v3-turbo/snapshots/abc")
        with mock.patch.object(T, "select", return_value=m), mock.patch.object(T, "model_path", return_value=snap):
            self.assertEqual(T.resolve_backend(a, "note"), "mlx-whisper")
        self.assertEqual(a.model, str(snap))

    def test_not_downloaded_keeps_the_repo_id(self):
        m = T.entry("whisper-large-v3-turbo-mlx")
        a = argparse.Namespace(backend=None, model=None, model_id=m["id"], language=None, prompt=None)
        with mock.patch.object(T, "select", return_value=m), mock.patch.object(T, "model_path", return_value=None):
            T.resolve_backend(a, "note")
        self.assertEqual(a.model, m["model"])


if __name__ == "__main__":
    unittest.main()
