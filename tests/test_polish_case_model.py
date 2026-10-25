"""The v0.9 dogfood regression with the real polish model: dictating "the new layout is fine" after "I think " typed
"I think The new layout is fine." The polish model is asked, as a language model, whether the capital is only a
sentence start's (polish.py `sentence_case`): a sentence word goes to lower case, a name keeps its capital.

Needs the polish model (MLX) on this Mac and runs through `polish.py run --no-server` (which adds mlx-lm); skipped
unless BLURT_TEST_POLISH_MODEL names the model folder. A throwaway BLURT_HOME links to it read-only:

  BLURT_TEST_POLISH_MODEL=~/.blurt/models/polish/gemma-4-e2b-it-4bit uv run pytest tests/test_polish_case_model.py -q
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills" / "blurt" / "scripts" / "polish.py"
MODEL = Path(os.path.expanduser(os.environ.get("BLURT_TEST_POLISH_MODEL", "") or "/nonexistent"))
IDS = {"gemma-4-e2b-it-4bit": "gemma4-e2b", "gemma-4-e4b-it-4bit": "gemma4-e4b", "Qwen3-1.7B-4bit": "qwen3-1.7b"}


@unittest.skipUnless(MODEL.is_dir() and MODEL.name in IDS and shutil.which("uv"), "BLURT_TEST_POLISH_MODEL not set")
class SentenceCaseWithTheModel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.home = Path(tempfile.mkdtemp(prefix="blurt-case-"))
        (cls.home / "models" / "polish").mkdir(parents=True)
        os.symlink(MODEL, cls.home / "models" / "polish" / MODEL.name)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.home, ignore_errors=True)

    def run_polish(self, before: str, text: str) -> dict:
        env = {**os.environ, "BLURT_HOME": str(self.home)}
        p = subprocess.run(["uv", "run", "-q", str(SCRIPT), "run", "--no-server", "--no-vocab", "--model", IDS[MODEL.name],
                            "--before", before, "--text", text], env=env, capture_output=True, text=True, timeout=600)
        self.assertEqual(p.returncode, 0, p.stderr[-800:])
        return json.loads(p.stdout)

    def test_a_sentence_word_goes_to_lower_case(self):
        r = self.run_polish("I think ", "The new layout is fine")
        self.assertTrue(r["text"].startswith("the new layout is fine"), r)
        self.assertTrue(r["case"]["lower"], r)

    def test_a_name_keeps_its_capital(self):
        for before, text in (("Let's meet on ", "Thursday after the review"), ("I talked to ", "John about the pricing page")):
            r = self.run_polish(before, text)
            self.assertEqual(r["text"][:1], text[:1], r)
            self.assertFalse(r["case"]["lower"], r)

    def test_after_a_sentence_end_nothing_changes(self):
        r = self.run_polish("Done. ", "The new layout is fine")
        self.assertTrue(r["text"].startswith("The new layout"), r)
        self.assertNotIn("case", r)


if __name__ == "__main__":
    unittest.main()
