"""The v0.9 dogfood regression with the real speech model: 「这个 feature 下周上线」 as the app captured it
(tests/fixtures/dictation_audio/mix09_app_captured.wav, 2.7 s) was typed as "This feature will be launched next week."
with the default Words on — their English sentence tipped the language tag (p_en 0.9958 against the 0.995 line). Run
through the app's own path (`transcribe.py note --dictation --vocab`, the VAD, the tag-aware decode) with those 24
words, and without words: Chinese both times, the English word kept.

Needs Qwen3-ASR 1.7B (MLX) and the VAD on this Mac, and runs under `uv run --with mlx-qwen3-asr`; skipped unless
BLURT_TEST_QWEN_MODEL names the model folder (the VAD is looked for two folders up, or BLURT_TEST_VAD). A throwaway
BLURT_HOME links to them read-only:

  BLURT_TEST_QWEN_MODEL=~/.blurt/models/asr/Qwen3-ASR-1.7B-8bit uv run pytest tests/test_dictation_codeswitch_model.py -q
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
SCRIPT = ROOT / "skills" / "blurt" / "scripts" / "transcribe.py"
WAV = ROOT / "tests" / "fixtures" / "dictation_audio" / "mix09_app_captured.wav"
MODEL = Path(os.path.expanduser(os.environ.get("BLURT_TEST_QWEN_MODEL", "") or "/nonexistent"))
VAD = Path(os.path.expanduser(os.environ.get("BLURT_TEST_VAD", "") or str(MODEL.parent.parent / "silero_vad.onnx")))
# the words the app sent that day, most used first: the defaults and one project's name and keys
WORDS = ["Claude Code", "Claude", "GitHub", "tmux", "Codex", "BA", "billing-api", "IOS", "Atlas Web", "AW", "Cursor",
         "Typeless", "MCP", "worktree", "OpenAI", "Anthropic", "ChatGPT", "DeepSeek", "Qwen", "Gemini", "Kimi",
         "Ollama", "blurt", "口喷鸡"]


@unittest.skipUnless(MODEL.is_dir() and VAD.is_file() and shutil.which("uv"), "BLURT_TEST_QWEN_MODEL not set")
class CodeSwitchWithTheModel(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="blurt-codeswitch-"))
        (self.home / "models" / "asr").mkdir(parents=True)
        os.symlink(MODEL, self.home / "models" / "asr" / MODEL.name)
        os.symlink(VAD, self.home / "models" / "silero_vad.onnx")
        (self.home / "config.json").write_text(json.dumps({"record": {"dictation": {"asr_model": "qwen3-asr-1.7b-mlx"}},
                                                           "asr": {"languages": ["zh", "en"]}}))
        (self.home / "dictation").mkdir()
        (self.home / "dictation" / "vocabulary.json").write_text(json.dumps({"schema": 2, "terms": [
            {"term": t, "source": "default", "state": "active", "hits": len(WORDS) - i} for i, t in enumerate(WORDS)]}))

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def note(self, *extra) -> dict:
        r = subprocess.run(["uv", "run", "-q", "--with", "mlx-qwen3-asr==0.4.4", str(SCRIPT), "note", str(WAV),
                            "--dictation", "--no-server", "--no-download", *extra],
                           capture_output=True, text=True, timeout=600, env={**os.environ, "BLURT_HOME": str(self.home)})
        lines = [ln for ln in r.stdout.splitlines() if ln.startswith("{")]
        self.assertTrue(lines, r.stderr[-2000:])
        return json.loads(lines[-1])

    def test_mixed_chinese_stays_chinese_with_the_default_words(self):
        for extra in (["--vocab"], []):
            with self.subTest(words=bool(extra)):
                o = self.note(*extra)
                self.assertEqual(o.get("language"), "zh", o)
                self.assertIn("feature", o["text"])
                self.assertRegex(o["text"], "[一-鿿]")
                self.assertEqual(o["tag"]["tag"], "Chinese")
                self.assertLess(o["tag"]["margin"], 0)


if __name__ == "__main__":
    unittest.main()
