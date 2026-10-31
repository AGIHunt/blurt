"""The field's text as the speech model's context, and hearing again in windows of the model's length
(docs/design/dictation.md §Field context, §Hearing again; measured in docs/design/dictation-quality-2026-10-31.md).

The app sends the field's last 300 characters before the cursor (`before`) with every dictation request when "Use the
text around the cursor" is on; transcribe.py gives them to a model whose registry entry has field_context_chars
(Qwen3-ASR 1.7B, the cloud Qwen3-ASR Flash) ahead of the text so far, keeps the language tag's prompt without them, and
decodes once more without either when the answer echoes them. No model: fake backends stand in.

  uv run --with numpy --with pytest pytest tests/test_transcribe_field_context.py -q
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

import test_asr_select as A

T = A.T
sys.path.insert(0, str(Path(T.__file__).resolve().parent))
import dictation_stitch as S  # noqa: E402


class Registry(unittest.TestCase):
    def test_windows_and_field_context_per_model(self):
        win = {m["id"]: m.get("rehear_window_s") for m in T.entries()}
        field = {m["id"]: T.field_context_chars(m["id"]) for m in T.entries()}
        self.assertEqual(win["qwen3-asr-1.7b-mlx"], 30)
        self.assertEqual(win["qwen3-asr-0.6b-mlx"], 20)
        # everything else keeps the 10 s it was measured with (none of them measured longer)
        for mid in ("apple-speech", "sensevoice-small", "whisper-large-v3-turbo-mlx", "qwen3-asr-0.6b-onnx",
                    "qwen3-asr-flash", "openai-compatible"):
            self.assertIsNone(win[mid], mid)
            self.assertEqual(S.rehear_window(mid), S.REHEAR_WINDOW)
        self.assertEqual(field["qwen3-asr-1.7b-mlx"], 300)
        self.assertEqual(field["qwen3-asr-flash"], 300)
        self.assertEqual(field["qwen3-asr-0.6b-mlx"], 0)       # mixed on the founder's takes: not for it
        for mid in ("apple-speech", "sensevoice-small", "whisper-large-v3-turbo-mlx", "openai-compatible"):
            self.assertEqual(field[mid], 0, mid)
        self.assertEqual(T.field_context_chars(None), 0)

    def test_rehear_window_setting_wins_and_has_a_floor(self):
        self.assertEqual(S.rehear_window("qwen3-asr-1.7b-mlx"), 30.0)
        self.assertEqual(S.rehear_window("qwen3-asr-0.6b-mlx"), 20.0)
        self.assertEqual(S.rehear_window("qwen3-asr-1.7b-mlx", 12), 12.0)
        self.assertEqual(S.rehear_window("qwen3-asr-1.7b-mlx", 1), 4.0)
        self.assertEqual(S.rehear_window("qwen3-asr-1.7b-mlx", "x"), 30.0)
        self.assertEqual(S.rehear_window("no-such-model"), S.REHEAR_WINDOW)


class QwenField(unittest.TestCase):
    """Qwen3Mlx.decode without the model."""

    def backend(self):
        b = object.__new__(T.Qwen3Mlx)
        b.m, b.repo, b.args = None, "fake", type("A", (), {"language": None})()
        b.context = b.base_context = "Notes about Gemini."
        b.names, b.prefer, b.tagged, b.last = ["Gemini"], "Chinese", True, {}
        b.prior = b.field = ""
        return b

    def test_the_field_goes_after_the_words_and_before_the_text_so_far(self):
        b = self.backend()
        b.set_field("  我刚截了一张图 ")
        b.set_prior("然后")
        seen = []
        b._decode_tagged = lambda x, ctx, prefer: (seen.append((ctx, b.tag_context)), ("你看一下", "zh"))[1]
        out = b.decode([0.0] * (A.SR * 2))
        self.assertEqual(out[0][2], "你看一下")
        self.assertEqual(seen[0][0], "Notes about Gemini.\n我刚截了一张图\n然后")
        self.assertEqual(seen[0][1], "然后")              # the language tag is read without the field's text

    def test_without_a_field_nothing_changes(self):
        b = self.backend()
        b.set_prior("然后")
        seen = []
        b._decode_tagged = lambda x, ctx, prefer: (seen.append(ctx), ("你看一下", "zh"))[1]
        b.decode([0.0] * (A.SR * 2))
        self.assertEqual(seen, ["Notes about Gemini.\n然后"])

    def test_the_field_written_out_again_is_decoded_once_more_without_it(self):
        b = self.backend()
        field = "我们周五之前要把它改好，然后发给产品经理看一下。第一，修复登录按钮；"
        b.set_field(field)
        seen = []

        def dec(x, ctx, prefer):
            seen.append(ctx)
            return (field + "第二，更新定价页面。" if len(seen) == 1 else "第二，更新定价页面。", "zh")
        b._decode_tagged = dec
        out = b.decode([0.0] * (A.SR * 3))
        self.assertEqual(out[0][2], "第二，更新定价页面。")
        self.assertEqual(seen[1], "Notes about Gemini.")
        self.assertTrue(b.last.get("echo"))


class NoteField(unittest.TestCase):
    """NoteEngine.note: the field's text only for a model that takes it, its tail, cleared after; never answered back."""

    def run_note(self, chars: int, before: str | None, heard=("然后跑一遍评测",)):
        class Field(A.FakeBackend):
            fields, priors = [], []
            answers = list(heard)

            def set_vocab(self, terms):
                return bool(terms)

            def set_prior(self, text):
                Field.priors.append(text)

            def set_field(self, text):
                Field.fields.append(text)

            def transcribe(self, x):
                return [(0.0, len(x) / A.SR, Field.answers.pop(0) if Field.answers else "", "zh")]

        old, oldvad, oldchars = T.BACKENDS, T.vad_segments, T.field_context_chars
        T.BACKENDS = {**T.BACKENDS, "sensevoice": Field}
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / A.SR)]
        T.field_context_chars = lambda mid: chars
        real = A.fake_installed("sensevoice-small")
        try:
            with tempfile.TemporaryDirectory() as d, A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                wav = A.write_wav(Path(d) / "p.wav", 1.5)
                out = T.NoteEngine().note(wav, vocab=["Gemini"], before=before)
        finally:
            T.BACKENDS, T.vad_segments, T.installed, T.field_context_chars = old, oldvad, real, oldchars
        return out, Field.fields, Field.priors

    def test_a_model_that_takes_it_hears_the_tail(self):
        before = "无关的开头。" * 80 + "我刚截了"
        out, fields, _ = self.run_note(300, before)
        self.assertEqual(fields[0], T.prior_tail(before, 300))
        self.assertTrue(before.endswith(fields[0]) and len(fields[0]) == 300)
        self.assertEqual(fields[-1], "")                          # cleared for the next request
        self.assertEqual(out["field_context"], 300)
        self.assertNotIn(before[-20:], json.dumps(out, ensure_ascii=False))   # never answered back

    def test_a_model_without_it_hears_nothing(self):
        out, fields, _ = self.run_note(0, "我刚截了")
        self.assertEqual(fields, [])
        self.assertNotIn("field_context", out)

    def test_no_field_no_call(self):
        out, fields, _ = self.run_note(300, None)
        self.assertEqual(fields, [])
        self.assertNotIn("field_context", out)

    def test_an_empty_answer_is_heard_again_without_the_field(self):
        out, fields, priors = self.run_note(300, "我刚截了", heard=("", "截了一张图"))
        self.assertEqual(out["text"], "截了一张图")
        self.assertTrue(out.get("retried"))
        self.assertEqual(fields[:2], ["我刚截了", ""])


class DashScopeField(unittest.TestCase):
    def test_the_field_follows_the_words_in_the_context(self):
        d = object.__new__(T.DashScope)
        d.args = type("A", (), {"prompt": None, "language": None})()
        d.terms = []
        self.assertEqual(d.context_text(), "")
        d.set_vocab([{"term": "Blurt"}, {"term": "Typeless"}])
        self.assertEqual(d.context_text(), "Blurt, Typeless")
        d.set_field(" 我刚截了 ")
        self.assertEqual(d.context_text(), "Blurt, Typeless\n我刚截了")
        d.set_field("")
        self.assertEqual(d.context_text(), "Blurt, Typeless")


if __name__ == "__main__":
    unittest.main()
