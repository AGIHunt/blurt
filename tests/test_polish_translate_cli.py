"""polish.py's translate CLI (⌥T's fallback, dictation's translate fallback): a payload read from stdin survives the
re-run under `uv run --with mlx-lm`, and nothing to translate is never a success. The dogfood found
`echo JSON | polish.py translate --stdin --no-server` answered {"ok": true, "text": ""}: the exec left the re-run an
empty stdin.

  uv run --with pytest pytest tests/test_polish_translate_cli.py -q
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import polish  # noqa: E402


class TranslateCLI(unittest.TestCase):
    def test_the_rerun_gets_the_payload_already_read(self):
        with tempfile.TemporaryDirectory() as d:
            uv = Path(d) / "uv"
            out = Path(d) / "got.txt"
            uv.write_text('#!/bin/sh\ncat > "$BLURT_TEST_UV_OUT"\n', encoding="utf-8")
            uv.chmod(uv.stat().st_mode | stat.S_IEXEC)
            env = {k: v for k, v in os.environ.items() if k != "BLURT_POLISH_REEXEC"}
            env["BLURT_TEST_UV_OUT"] = str(out)
            payload = '{"text": "The replica is billed by the hour.", "target": "auto"}'
            with mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.object(importlib.util, "find_spec", return_value=None), \
                    mock.patch.object(polish, "supported", return_value=True), \
                    mock.patch("shutil.which", return_value=str(uv)), \
                    mock.patch.object(sys, "argv", [str(SCRIPTS / "polish.py"), "translate", "--stdin", "--no-server"]):
                with self.assertRaises(SystemExit) as e:
                    polish.ensure_mlx(stdin=payload)
            self.assertEqual(e.exception.code, 0)
            self.assertEqual(out.read_text(encoding="utf-8"), payload)

    def test_nothing_to_translate_is_a_failure(self):
        a = argparse.Namespace(text="", target="auto", stdin=False, no_server=True, model_id=None)
        with self.assertRaises(polish.Fail) as e:
            polish.cmd_translate(a)
        self.assertEqual(e.exception.code, "empty_input")


if __name__ == "__main__":
    unittest.main()
