"""Qwen3Mlx's language tag (docs/design/dictation.md §Code-switching, v0.9 dogfood): the tag is read from a prompt
without the Words — framed as an English sentence they pushed a mixed Chinese sentence's tag over the English line,
and a clean English translation was typed — while the text is decoded with the Words under that tag. A stand-in for
mlx / mlx-qwen3-asr (numpy) runs the real decode loop; its "model" tags English only when the Words are in the prompt,
as the app-captured mix09 take did (p_en 0.9956 with the Words, 0.948 without). No model, no network.

  uv run pytest tests/test_transcribe_language_tag.py -q
"""
from __future__ import annotations

import sys
import types
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import dictation_vocab as V  # noqa: E402
import transcribe as T  # noqa: E402

# the stand-in tokenizer's ids
EOS, LANG, T_EN, T_ZH, F_EN, F_ZH, A_EN, A_ZH, P_WORDS, P_BARE = 0, 1, 2, 3, 10, 11, 20, 21, 200, 201
VOCAB = 300
TEXT = {A_EN: "This feature will be launched next week.", A_ZH: "这个 feature 下周上线。"}


def logits_for(probs: dict[int, float]):
    v = np.full(VOCAB, -30.0, np.float32)
    for k, p in probs.items():
        v[k] = np.log(p)
    return v


class FakeMx(types.ModuleType):
    float16 = np.float16
    float32 = np.float32

    def __init__(self):
        super().__init__("mlx.core")

    array = staticmethod(np.array)
    arange = staticmethod(np.arange)
    exp = staticmethod(np.exp)
    argmax = staticmethod(np.argmax)

    @staticmethod
    def stack(xs, axis=0):
        return np.stack(xs, axis=axis)

    @staticmethod
    def logsumexp(x):
        m = np.max(x)
        return m + np.log(np.sum(np.exp(x - m)))


class Tok:
    def encode(self, s):
        return {"language": [LANG], " English": [T_EN], " Chinese": [T_ZH], " English<asr_text>": [F_EN],
                " Chinese<asr_text>": [F_ZH]}[s]

    def build_prompt_tokens(self, n_audio_tokens, language=None, context=""):
        Model.prompts.append(context)
        return [5] * 4 + [P_WORDS if "Notes about" in (context or "") else P_BARE]

    def decode(self, ids):
        return "".join(TEXT.get(i, "") for i in ids)


class Model:
    prompts: list[str] = []
    prefills = 0
    # the probabilities at the tag: the Words in the prompt tip it to English
    WITH_WORDS = {T_EN: 0.9956, T_ZH: 0.0043}
    BARE = {T_EN: 0.948, T_ZH: 0.051}

    def create_cache(self, max_seq_len):
        return {}

    def prefill(self, input_ids, audio_features, position_ids, cache):
        Model.prefills += 1
        ids = list(np.asarray(input_ids).reshape(-1))
        cache["words"] = P_WORDS in ids
        return logits_for(Model.WITH_WORDS if cache["words"] else Model.BARE)[None, None, :]

    def step_many(self, input_ids, position_ids, cache):
        tag = int(np.asarray(input_ids).reshape(-1)[0])
        cache["answer"] = A_EN if tag in (F_EN, T_EN) else A_ZH
        out = np.full((1, 1, VOCAB), -30.0, np.float32)
        out[0, -1, cache["answer"]] = 0
        return out

    def step(self, input_ids, position_ids, cache, validate_input_ids=True):
        return logits_for({EOS: 0.99})[None, None, :]

    def audio_tower(self, mel, fl):
        return np.zeros((1, 8, 4), np.float16), None


def parse_asr_output(raw, user_language=None):
    return user_language, raw


def fake_library(model: Model):
    mods = {}

    def mod(name, **attrs):
        m = types.ModuleType(name)
        for k, v in attrs.items():
            setattr(m, k, v)
        mods[name] = m
        return m

    holder = type("H", (), {"get": staticmethod(lambda repo, dtype=None: (model, None)),
                            "get_resolved_path": staticmethod(lambda repo, dtype=None: "fake")})
    mod("mlx_qwen3_asr")
    mod("mlx_qwen3_asr.audio", compute_features=lambda chunk: (np.zeros((1, 4), np.float32), None))
    mod("mlx_qwen3_asr.chunking", split_audio_into_chunks=lambda x, sr: [(x, 0)])
    mod("mlx_qwen3_asr.generate", GenerationConfig=lambda: type("G", (), {"eos_token_ids": [EOS]})(),
        detect_repetition=lambda out: False, resolve_max_new_tokens=lambda n, audio_duration_sec: 16)
    mod("mlx_qwen3_asr.load_models", _ModelHolder=holder)
    mod("mlx_qwen3_asr.tokenizer", _TokenizerHolder=type("TH", (), {"get": staticmethod(lambda path: Tok())}),
        parse_asr_output=parse_asr_output)
    return mods


class LanguageTag(unittest.TestCase):
    def setUp(self):
        Model.prompts, Model.prefills = [], 0
        self.saved = {k: sys.modules.get(k) for k in fake_library(Model())}
        sys.modules.update(fake_library(Model()))

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v

    def backend(self, words=("Claude Code", "Claude", "GitHub", "tmux", "Codex")):
        b = object.__new__(T.Qwen3Mlx)
        b.mx, b.m, b.repo, b.args = FakeMx(), None, "fake", type("A", (), {"language": None})()
        b.base_context = ""
        b.set_vocab(V.normalize(list(words)))
        b.prefer, b.tagged, b.last, b.prior, b.stop_check = "Chinese", True, {}, "", None
        return b

    def test_the_words_no_longer_turn_a_mixed_sentence_into_an_english_translation(self):
        b = self.backend()
        out = b.decode(np.zeros(16000, np.float32))
        self.assertEqual(out[0][2:], ("这个 feature 下周上线。", "zh"))
        # the tag from the prompt without the Words; the text from the one with them (the spelling bias stays)
        self.assertEqual(Model.prompts, ["", b.context])
        self.assertEqual(b.last["tag"], "Chinese")
        self.assertAlmostEqual(b.last["p_en"], 0.948, places=2)
        self.assertAlmostEqual(b.last["p_en_words"], 0.9956, places=2)
        self.assertLess(b.last["margin"], -V.FRAGILE_MARGIN)

    def test_english_speech_is_still_english(self):
        Model.BARE = {T_EN: 0.9995, T_ZH: 0.0004}
        try:
            out = self.backend().decode(np.zeros(16000, np.float32))
        finally:
            Model.BARE = {T_EN: 0.948, T_ZH: 0.051}
        self.assertEqual(out[0][2:], ("This feature will be launched next week.", "en"))

    def test_without_words_one_prefill_does_both(self):
        b = self.backend(words=())
        b.decode(np.zeros(16000, np.float32))
        self.assertEqual(Model.prefills, 1)
        self.assertNotIn("p_en_words", b.last)

    def test_the_text_so_far_goes_with_the_tag_prompt(self):
        b = self.backend()
        b.set_prior("我们先看一下这个需求")
        b.decode(np.zeros(16000, np.float32))
        self.assertEqual(Model.prompts[0], "我们先看一下这个需求")
        self.assertIn("Notes about", Model.prompts[1])


class StableOrder(unittest.TestCase):
    """The terms' order in the speech model's prompt doesn't follow the hit counts (it moved the tag before, and the
    Lab sent another order than the app): the app's payload and the file give the same request."""

    def test_hits_choose_which_terms_not_their_order(self):
        terms = V.normalize([{"term": "tmux", "hits": 9, "source": "default"}, {"term": "Codex", "hits": 1, "source": "default"},
                             {"term": "Atlas Web", "hits": 0, "source": "project"}, {"term": "Mine", "source": "manual"}])
        a = [t["term"] for t in V.ranked(terms, limit=64)]
        terms[0]["hits"], terms[1]["hits"] = 0, 30
        self.assertEqual([t["term"] for t in V.ranked(terms, limit=64)], a)
        self.assertEqual(a, ["Mine", "Atlas Web", "Codex", "tmux"])
        # with more terms than room, the most used make the cut
        self.assertEqual([t["term"] for t in V.ranked(terms, limit=2)], ["Mine", "Codex"])

    def test_a_term_heard_goes_first(self):
        terms = V.normalize([{"term": "Codex"}, {"term": "tmux"}])
        self.assertEqual(V.ranked(terms, "t mux 里面", limit=64)[0]["term"], "tmux")

    def test_margin(self):
        self.assertGreater(V.tag_margin(0.9999, 0.0001), 0)
        self.assertLess(V.tag_margin(0.948, 0.051), -0.02)
        self.assertAlmostEqual(V.tag_margin(0.0, 0.0), -V.EN_TAG_THRESHOLD)


if __name__ == "__main__":
    unittest.main()
