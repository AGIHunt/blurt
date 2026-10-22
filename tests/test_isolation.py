"""The suite never touches the real ~/.blurt or ~/Blurt (conftest.py points both at a scratch dir first)."""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))


class Isolation(unittest.TestCase):
    def test_scripts_resolve_a_scratch_home(self):
        import _common  # noqa: PLC0415
        import transcribe  # noqa: PLC0415
        real = Path.home() / ".blurt"
        for p in (_common.BLURT_HOME, transcribe.BLURT_HOME, Path(os.environ["BLURT_HOME"])):
            self.assertNotEqual(Path(p).resolve(), real.resolve())
        self.assertNotEqual(Path(os.environ["BLURT_WORKSPACE"]).resolve(), (Path.home() / "Blurt").resolve())
