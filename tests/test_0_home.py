"""Every test run gets its own BLURT_HOME and BLURT_WORKSPACE: never the real ~/.blurt or ~/Blurt.

pytest: conftest.py points both at a scratch dir before any test module is imported. unittest (python -m unittest
discover -s tests, an IDE's runner) loads no conftest, so the same floor is laid here: this module's name sorts first,
and a script reads $BLURT_HOME once, at import. Without it (2026-11-22, a run on a Mac in use) the suite rewrote the
real config.json, voiceprint.json and models/silero_vad.onnx — each put back, because the tests that write there
restore — and read the real dictation history: three tests failed there that pass on a fresh account.

Tests that need a fresh home still make their own; this is only the floor.

One module by name under unittest (`python -m unittest tests.test_live`) loads nothing else, so it has no floor: run it
with pytest, or point BLURT_HOME, BLURT_WORKSPACE and HF_HUB_CACHE at a scratch folder first.
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))


def _is_the_real_one(var: str, real: Path) -> bool:
    """Unset, or the real folder itself."""
    v = os.environ.get(var)
    return not v or Path(v).resolve() == real.resolve()


if _is_the_real_one("BLURT_HOME", Path.home() / ".blurt"):
    _root = tempfile.mkdtemp(prefix="blurt-tests-")
    os.environ["BLURT_HOME"] = os.path.join(_root, "home")
    os.makedirs(os.environ["BLURT_HOME"], exist_ok=True)
if _is_the_real_one("BLURT_WORKSPACE", Path.home() / "Blurt"):
    os.environ["BLURT_WORKSPACE"] = os.path.join(Path(os.environ["BLURT_HOME"]).parent, "ws")
    os.makedirs(os.environ["BLURT_WORKSPACE"], exist_ok=True)
# and an empty Hugging Face cache, as conftest.py does: a Whisper in this Mac's own ~/.cache/huggingface is a model
# Blurt didn't download, and it must not decide what a test sees
if not (os.environ.get("HF_HUB_CACHE") or os.environ.get("BLURT_ASR_SLOW") or os.environ.get("BLURT_E2E")):
    os.environ["HF_HUB_CACHE"] = os.path.join(Path(os.environ["BLURT_HOME"]).parent, "hf")


class Isolation(unittest.TestCase):
    def test_scripts_resolve_a_scratch_home(self):
        import _common  # noqa: PLC0415
        import transcribe  # noqa: PLC0415
        real = Path.home() / ".blurt"
        for p in (_common.BLURT_HOME, transcribe.BLURT_HOME, Path(os.environ["BLURT_HOME"])):
            self.assertNotEqual(Path(p).resolve(), real.resolve())
        self.assertNotEqual(Path(os.environ["BLURT_WORKSPACE"]).resolve(), (Path.home() / "Blurt").resolve())

    def test_this_module_is_collected_first(self):
        """The floor is laid at import: a test module that sorts before it would import the scripts with the real home."""
        first = sorted(p.name for p in Path(__file__).parent.glob("test*.py"))[0]
        self.assertEqual(first, Path(__file__).name)
