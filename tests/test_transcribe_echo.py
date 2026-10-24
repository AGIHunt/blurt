"""A streamed piece's context echoed back (dict023, docs/design/dictation.md §Streaming): the speech model gets only
the tail of the text so far (PRIOR_CHARS) and the most relevant words with it (PRIOR_TERMS), and a piece whose answer
looks like the context written out again (`echoes_prior`: too many syllables for its audio, or a long run of the
prior) is decoded once more without the prior; the shorter answer wins only when it is clearly shorter. Nothing here
reads the words for meaning. No model: fake backends stand in.

  uv run --with numpy --with pytest pytest tests/test_transcribe_echo.py -q
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import test_asr_select as A

T = A.T


class PriorTail(unittest.TestCase):
    def test_short_prior_goes_whole(self):
        self.assertEqual(T.prior_tail("  先检查一下配额 "), "先检查一下配额")
        self.assertEqual(T.prior_tail(""), "")

    def test_long_prior_keeps_the_last_characters(self):
        p = "第一句话说完了。" * 20
        self.assertEqual(len(T.prior_tail(p)), T.PRIOR_CHARS)
        self.assertTrue(p.endswith(T.prior_tail(p)))

    def test_never_starts_inside_a_latin_word(self):
        p = "Most of the team is traveling on Wednesday and the release has to wait until Friday afternoon."
        t = T.prior_tail(p, 40)
        self.assertTrue(p.endswith(t))
        self.assertLessEqual(len(t), 40)
        self.assertTrue(p[-len(t) - 1] == " ")          # cut at a space


class EchoesPrior(unittest.TestCase):
    PRIOR = "我们周五之前要把它改好，然后发给产品经理看一下。第一，修复登录按钮；第二，更新定价页面；"

    def test_the_prior_written_out_again_is_suspect(self):
        echoed = "第一，修复登录按钮；第二，更新定价页面；第三，给它写一个新的技能。"
        self.assertTrue(T.echoes_prior(echoed, self.PRIOR, 6.0))

    def test_too_many_syllables_for_the_audio(self):
        # 5.5 s can't hold 120 syllables, whatever they say
        self.assertTrue(T.echoes_prior("字" * 120, "无关的上文", 5.5))
        self.assertTrue(T.echoes_prior(" ".join(["banana"] * 40), "something else", 5.0))

    def test_an_ordinary_piece_is_not(self):
        self.assertFalse(T.echoes_prior("然后跑一遍评测，看看结果怎么样。", self.PRIOR, 4.0))
        self.assertFalse(T.echoes_prior("and won't be back in time", "Most of the team is traveling on Wednesday.", 2.0))
        self.assertFalse(T.echoes_prior("", self.PRIOR, 3.0))
        self.assertFalse(T.echoes_prior("任何文字", "", 3.0))

    def test_punctuation_and_spaces_do_not_hide_a_run(self):
        self.assertEqual(T.longest_shared_run("Claude Code, Codex!", "claudecodecodex"), len("claudecodecodex"))


class QwenRedo(unittest.TestCase):
    """Qwen3Mlx.decode without the model: an echo is decoded again with the word list only."""

    def backend(self):
        b = object.__new__(T.Qwen3Mlx)
        b.m, b.repo, b.args = None, "fake", type("A", (), {"language": None})()
        b.context = b.base_context = "Notes about Gemini."
        b.names, b.prefer, b.tagged, b.last = ["Gemini"], "Chinese", True, {}
        return b

    def test_an_echo_is_decoded_again_without_the_prior(self):
        b = self.backend()
        b.prior = EchoesPrior.PRIOR
        ctxs = []

        def dec(x, ctx, prefer):
            ctxs.append(ctx)
            return (EchoesPrior.PRIOR + "我们周五之前要把它改好。" if len(ctxs) == 1 else "我们周五之前要把它改好。", "zh")
        b._decode_tagged = dec
        out = b.decode([0.0] * (A.SR * 4))
        self.assertEqual(out[0][2], "我们周五之前要把它改好。")
        self.assertEqual(ctxs[1], "Notes about Gemini.")             # the words, not the text so far
        self.assertTrue(b.last.get("echo"))

    def test_a_speaker_who_repeats_themself_keeps_their_words(self):
        # the run is shared because it was said again: without the prior the answer is the same, so it stays
        b = self.backend()
        b.prior = EchoesPrior.PRIOR
        said = "第一，修复登录按钮；第二，更新定价页面；"
        b._decode_tagged = lambda x, ctx, prefer: (said, "zh")
        out = b.decode([0.0] * (A.SR * 5))
        self.assertEqual(out[0][2], said)
        self.assertFalse(b.last.get("echo"))

    def test_no_prior_no_second_decode(self):
        b = self.backend()
        b.prior = ""
        calls = []
        b._decode_tagged = lambda x, ctx, prefer: (calls.append(ctx), ("字" * 200, "zh"))[1]
        b.decode([0.0] * (A.SR * 2))
        self.assertEqual(len(calls), 1)


class NoteSendsTheTail(unittest.TestCase):
    def test_only_the_tail_and_the_most_relevant_words_go_with_a_prior(self):
        class Prior(A.FakeBackend):
            priors, vocabs = [], []

            def set_vocab(self, terms):
                Prior.vocabs.append(len(terms))
                return bool(terms)

            def set_prior(self, text):
                Prior.priors.append(text)

            def transcribe(self, x):
                return [(0.0, len(x) / A.SR, "然后跑一遍评测", "zh")]

        old, oldvad = T.BACKENDS, T.vad_segments
        T.BACKENDS = {**T.BACKENDS, "sensevoice": Prior}
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / A.SR)]
        real = A.fake_installed("sensevoice-small")
        words = [f"Term{i}" for i in range(100)]
        try:
            with tempfile.TemporaryDirectory() as d, A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                wav = A.write_wav(Path(d) / "p.wav", 1.5)
                T.NoteEngine().note(wav, vocab=words, prior="先检查一下 Gemini API 的配额" * 20)
                T.NoteEngine().note(wav, vocab=words)
        finally:
            T.BACKENDS, T.vad_segments, T.installed = old, oldvad, real
        self.assertEqual(len(Prior.priors[0]), T.PRIOR_CHARS)
        self.assertEqual(Prior.vocabs[0], T.PRIOR_TERMS)                    # with a prior: the most relevant 32
        self.assertEqual(Prior.vocabs[2], T.dictation_vocab.QWEN_MAX_TERMS)  # without: the usual list (64)


if __name__ == "__main__":
    unittest.main()
