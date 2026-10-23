"""Dictation's custom words (docs/design/dictation.md §Custom words): the deterministic pass, ranking, the ASR prompt
formats, the content-loss guard with vocabulary and context, the polish prompt's shape, and the biased note path
(a fake backend stands in for the model). No model, no network.

  uv run --with pytest pytest tests/test_dictation_vocab.py -q
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(ROOT / "tests"))
import dictation_vocab as V  # noqa: E402
import polish  # noqa: E402

TERMS = V.normalize([
    {"term": "Claude Code", "sounds_like": ["cloud code", "clock code"], "source": "project"},
    {"term": "Claude", "source": "manual"},
    {"term": "SenseVoice"}, {"term": "GitHub"}, {"term": "Swift"},
    {"term": "口喷鸡", "sounds_like": ["口喷机", "鸡"], "source": "project"},
    {"term": "blurt", "sounds_like": ["blur", "blurred"]},
    {"term": "worktree", "sounds_like": ["work tree"]},
    {"term": "tmux", "sounds_like": ["t mux"]},
    {"term": "BA-12"},
    {"term": "Rejected", "state": "rejected"},
    {"term": "Pending", "state": "suggested", "source": "learned"},
])


class Store(unittest.TestCase):
    def test_only_active_terms_deduplicated(self):
        names = [t["term"] for t in TERMS]
        self.assertNotIn("Rejected", names)
        self.assertNotIn("Pending", names)
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(V.normalize(["a", "a", {"term": "b"}, 3, None]), [
            {"term": "a", "sounds_like": [], "hits": 0, "source": "manual"},
            {"term": "b", "sounds_like": [], "hits": 0, "source": "manual"}])

    def test_load_reads_the_apps_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "vocabulary.json"
            p.write_text(json.dumps({"schema": 1, "terms": [{"term": "Codex", "source": "project", "hits": 2}]}))
            self.assertEqual([t["term"] for t in V.load(p)], ["Codex"])
            p.write_text("not json")
            self.assertEqual(V.load(p), [])
            self.assertEqual(V.load(Path(d) / "missing.json"), [])


class Apply(unittest.TestCase):
    def fix(self, text):
        return V.apply(text, TERMS)

    def test_sounds_like_and_spacing(self):
        self.assertEqual(self.fix("我用cloud code在t mux里开了一个work tree"),
                         ("我用Claude Code在tmux里开了一个worktree", ["Claude Code", "worktree", "tmux"]))
        self.assertEqual(self.fix("口喷机现在支持了")[0], "口喷鸡现在支持了")

    def test_case_and_spacing_variants_of_a_term(self):
        self.assertEqual(self.fix("ask claude about sense voice on github")[0], "ask Claude about SenseVoice on GitHub")
        self.assertEqual(self.fix("see ba 12")[0], "see BA-12")

    def test_ordinary_words_are_left_alone(self):
        # "blur" / "cloud" are English words: a sounds-like on them is polish's call (it sees the context);
        # "swift" is the term "Swift" in lower case but also a word; a single CJK character is too ambiguous
        for s in ("the blur effect in swift", "upload it to the cloud", "我要吃鸡"):
            self.assertEqual(self.fix(s), (s, []))

    def test_already_right_is_not_counted(self):
        self.assertEqual(self.fix("Claude Code is great"), ("Claude Code is great", []))
        self.assertEqual(self.fix(""), ("", []))
        self.assertEqual(V.apply("cloud code", []), ("cloud code", []))

    def test_word_boundaries(self):
        self.assertEqual(self.fix("cloudcode and cloud coder")[0], "cloudcode and cloud coder")


class Ranking(unittest.TestCase):
    def test_heard_terms_first(self):
        order = [t["term"] for t in V.ranked(TERMS, "用 kodex 和 cloud code 跑一下")]
        self.assertEqual(order[0], "Claude Code")
        order = [t["term"] for t in V.ranked(TERMS, "nothing here", context="push it to GitHub")]
        self.assertEqual(order[0], "GitHub")
        self.assertEqual(len(V.ranked(TERMS * 10, "", limit=5)), 5)

    def test_similar(self):
        self.assertTrue(V.similar("cloud", "Claude"))
        self.assertTrue(V.similar("Sense Voice", "SenseVoice"))
        self.assertTrue(V.similar("kodex", "Codex"))
        self.assertFalse(V.similar("table", "Claude"))

    def test_prompt_formats(self):
        t = TERMS[:3]
        self.assertEqual(V.whisper_prompt(t), "Claude Code, Claude, SenseVoice")
        self.assertEqual(V.qwen_context(t), "Notes about Claude Code, Claude and SenseVoice.")
        self.assertEqual(V.qwen_context(t[:1]), "Notes about Claude Code.")
        self.assertEqual(V.qwen_context([]), "")
        # sherpa-onnx splits hotwords on ASCII commas: never one inside
        self.assertEqual(V.hotwords(V.normalize(["a, b", "c"])), "a  b; c")


class GuardWithVocab(unittest.TestCase):
    def allowed(self, terms, ctx=""):
        return V.allowed_units(V.normalize(terms), ctx)

    def test_a_fix_toward_a_listed_term_is_not_new_words(self):
        raw = "我刚才用cloud code在t mux里开了一个work tree然后跑了一下pie test和kodex"
        out = "我刚才用 Claude Code 在 tmux 里开了一个 worktree，然后跑了一下 pytest 和 Codex。"
        self.assertEqual(polish.guard(raw, out)["reason"], "novel")            # without the words: refused
        g = polish.guard(raw, out, self.allowed(["Claude Code", "tmux", "worktree", "pytest", "Codex"]))
        self.assertTrue(g["pass"], g)
        self.assertIn("claude", g["stats"]["vocab_units"])

    def test_context_words_are_allowed_but_only_those(self):
        raw = "so the jemma model and the quen model both run on m l x and the tool is called q wen chat"
        out = "So the Gemma model and the Qwen model both run on MLX, and the tool is called QwenChat."
        ctx = "Models: Gemma, Qwen, MLX. Tool: QwenChat"
        self.assertTrue(polish.guard(raw, out, self.allowed([], ctx))["pass"])
        # a word that is in neither the list nor the context is still new
        bad = "So the Gemma model and the Qwen model both run on MLX, and the tool is called Ollama Turbo Studio Pro Max Ultra."
        self.assertEqual(polish.guard(raw, bad, self.allowed([], ctx))["reason"], "novel")

    def test_misheard_cjk_to_term(self):
        g = polish.guard("口喷机现在可以用了吗", "口喷鸡现在可以用了吗？", self.allowed(["口喷鸡"]))
        self.assertTrue(g["pass"], g)

    def test_vocab_does_not_excuse_other_failures(self):
        allowed = self.allowed(["Claude Code"])
        self.assertEqual(polish.guard("为什么cloud code会超时", "因为网络慢。", allowed)["reason"], "answered")
        long_in = "嗯那个我们先用cloud code把登录页面的按钮颜色改一下然后再把设置页的保存逻辑重新写一遍最后跑一下测试"
        self.assertEqual(polish.guard(long_in, "用 Claude Code 改按钮。", allowed)["reason"], "shrunk")

    def test_a_spoken_term_must_stay(self):
        raw = "我觉得口喷鸡在菜单栏里的图标可以在做得大一点现在有点看不清"
        out = "我觉得菜单栏里的图标可以做得大一点，现在有点看不清。"
        self.assertTrue(polish.guard(raw, out)["pass"])                         # a small loss, inside the slack
        self.assertEqual(polish.guard(raw, out, terms=["口喷鸡"])["reason"], "term")
        self.assertTrue(polish.guard("用 claude code 跑", "用 Claude Code 跑。", terms=["Claude Code"])["pass"])

    def test_guard_cli_takes_terms_and_context(self):
        import subprocess
        p = subprocess.run([sys.executable, str(SCRIPTS / "polish.py"), "guard", "用cloud code跑一下",
                            "用 Claude Code 跑一下。", "--terms", "Claude Code"], capture_output=True, text=True)
        self.assertTrue(json.loads(p.stdout.splitlines()[-1])["pass"])


class Prompt(unittest.TestCase):
    def test_bare_dictation_without_words_or_context(self):
        self.assertEqual(polish.user_message("你好"), "你好")
        self.assertEqual(polish.messages("你好")[-1]["content"], "你好")

    def test_words_and_context_lines(self):
        m = polish.user_message("用cloud code", V.normalize(["Claude Code", "tmux"]),
                                {"before": "line one\n  line two " + "x" * 400, "after": "tail", "selection": "",
                                 "title": "notes.md", "app": "Xcode"})
        lines = m.split("\n")
        self.assertEqual(lines[0], "Words: Claude Code, tmux")
        self.assertTrue(lines[1].startswith("Near the cursor: "))
        self.assertIn(" ▮ tail", lines[1])
        self.assertLessEqual(len(lines[1]), len("Near the cursor: ") + polish.CONTEXT_CHARS + 10)
        self.assertEqual(lines[2], "Dictation: 用cloud code")
        # no text around the cursor: the window title stands in
        self.assertEqual(polish.context_text({"title": "Release notes — Pages"}), "Release notes — Pages")
        self.assertEqual(polish.context_text(None), "")

    def test_fixed_prefix_is_the_same_with_or_without_words(self):
        a = polish.messages("x")[:-1]
        b = polish.messages("x", V.normalize(["Claude"]), {"before": "y"})[:-1]
        self.assertEqual(a, b)          # the prompt cache covers both

    def test_clean_output_drops_a_dictation_label(self):
        self.assertEqual(polish.clean_output("Dictation: 我用 Claude Code。"), "我用 Claude Code。")

    def test_short_text_still_gets_the_deterministic_pass(self):
        r = polish.Engine().polish("cloud code", terms=["Claude Code"] and [{"term": "Claude Code", "sounds_like": ["cloud code"]}])
        self.assertEqual((r["text"], r["reason"], r["terms"]), ("Claude Code", "short", ["Claude Code"]))


class BiasedNote(unittest.TestCase):
    """transcribe.NoteEngine.note(vocab=…): set_vocab before decoding, cleared after, exact fixes applied."""

    def test_note_with_vocab(self):
        import test_asr_select as A
        T = A.T

        class Biasable(A.FakeBackend):
            seen = []

            def set_vocab(self, terms):
                Biasable.seen.append([t["term"] for t in terms])
                return bool(terms)

            def transcribe(self, x):
                return [(0.0, len(x) / A.SR, "我用cloud code开了work tree", "zh")]

        old = T.BACKENDS
        T.BACKENDS = {**T.BACKENDS, "sensevoice": Biasable}
        oldvad = T.vad_segments
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / A.SR)]
        real = A.fake_installed("sensevoice-small")
        try:
            with tempfile.TemporaryDirectory() as d, A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                wav = A.write_wav(Path(d) / "n.wav", 1.5)
                r = T.NoteEngine().note(wav, vocab=[{"term": "Claude Code", "sounds_like": ["cloud code"]}, "worktree"])
                plain = T.NoteEngine().note(wav)
        finally:
            T.BACKENDS, T.vad_segments, T.installed = old, oldvad, real
        self.assertEqual(r["text"], "我用Claude Code开了worktree")
        self.assertEqual(r["asr_text"], "我用cloud code开了work tree")
        self.assertEqual(r["terms"], ["Claude Code", "worktree"])
        self.assertTrue(r["biased"])
        self.assertEqual(Biasable.seen[0][:2], ["Claude Code", "worktree"])
        self.assertEqual(Biasable.seen[1], [])                # cleared: the next voice note isn't biased
        self.assertNotIn("asr_text", plain)                   # no vocab asked: the plain voice-note answer

    def test_streamed_piece_gets_the_text_so_far(self):
        """A streamed dictation's piece: `prior` (the text so far) reaches the backend for this request only."""
        import test_asr_select as A
        T = A.T

        class Prior(A.FakeBackend):
            seen = []

            def set_vocab(self, terms):
                return bool(terms)

            def set_prior(self, text):
                Prior.seen.append(text)

            def transcribe(self, x):
                return [(0.0, len(x) / A.SR, "然后跑一遍评测", "zh")]

        old = T.BACKENDS
        T.BACKENDS = {**T.BACKENDS, "sensevoice": Prior}
        oldvad = T.vad_segments
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / A.SR)]
        real = A.fake_installed("sensevoice-small")
        try:
            with tempfile.TemporaryDirectory() as d, A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                wav = A.write_wav(Path(d) / "p.wav", 1.5)
                r = T.NoteEngine().note(wav, vocab=["Gemini"], prior="先检查一下 Gemini API 的配额" * 20)
                T.NoteEngine().note(wav, vocab=["Gemini"])
        finally:
            T.BACKENDS, T.vad_segments, T.installed = old, oldvad, real
        self.assertEqual(r["text"], "然后跑一遍评测")
        self.assertEqual(len(Prior.seen), 2)                  # set, then cleared
        self.assertEqual(len(Prior.seen[0]), 200)             # the last 200 characters
        self.assertTrue(Prior.seen[0].endswith("的配额"))
        self.assertEqual(Prior.seen[1], "")
        self.assertIn("load_ms", r)

    def test_a_piece_that_comes_back_empty_with_the_prior_is_tried_once_without(self):
        """Qwen3-ASR sometimes says nothing for a short last piece after a whole sentence of context: the VAD heard
        speech, so the piece is decoded once more without the prior (and not when there was no prior)."""
        import test_asr_select as A
        T = A.T

        class Shy(A.FakeBackend):
            prior = ""
            calls = 0

            def set_vocab(self, terms):
                return bool(terms)

            def set_prior(self, text):
                Shy.prior = text

            def transcribe(self, x):
                Shy.calls += 1
                return [(0.0, len(x) / A.SR, "" if Shy.prior else "and won't be back in time", "en")]

        old = T.BACKENDS
        T.BACKENDS = {**T.BACKENDS, "sensevoice": Shy}
        oldvad = T.vad_segments
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / A.SR)]
        real = A.fake_installed("sensevoice-small")
        try:
            with tempfile.TemporaryDirectory() as d, A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                wav = A.write_wav(Path(d) / "p.wav", 1.5)
                r = T.NoteEngine().note(wav, vocab=["Gemini"], prior="Most of the team is traveling on Wednesday.")
                n = Shy.calls
                plain = T.NoteEngine().note(wav, vocab=["Gemini"])
        finally:
            T.BACKENDS, T.vad_segments, T.installed = old, oldvad, real
        self.assertEqual(r["text"], "and won't be back in time")
        self.assertTrue(r["retried"])
        self.assertEqual(n, 2)
        self.assertNotIn("retried", plain)

    def test_dictation_models_rows(self):
        import test_asr_select as A
        T = A.T
        real = A.fake_installed("sensevoice-small")
        try:
            with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                d = T.dictation_models(A.hw())
                self.assertEqual(d["recommended"], "qwen3-asr-1.7b-mlx")       # Apple silicon, pro (v0.8 speed eval)
                self.assertEqual(d["selected"], "sensevoice-small")             # … until it is installed
                self.assertEqual(d["models"][0]["id"], "qwen3-asr-1.7b-mlx")
                self.assertEqual({m["id"]: m["vocab"] for m in d["models"]}["sensevoice-small"], "none")
                self.assertEqual(T.dictation_models(A.hw(ram=16.0))["recommended"], "qwen3-asr-0.6b-mlx")   # standard
            T.installed = lambda m: m["id"] in ("sensevoice-small", "qwen3-asr-0.6b-mlx")
            with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                # a pro Mac with only the 0.6B keeps using it until the 1.7B is installed
                self.assertEqual(T.dictation_models(A.hw())["selected"], "qwen3-asr-0.6b-mlx")
            T.installed = lambda m: m["id"] in ("sensevoice-small", "qwen3-asr-0.6b-mlx", "qwen3-asr-1.7b-mlx")
            with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                self.assertEqual(T.dictation_models(A.hw())["selected"], "qwen3-asr-1.7b-mlx")
                self.assertEqual(T.dictation_models(A.hw(ram=16.0))["selected"], "qwen3-asr-0.6b-mlx")
            with A.config({"asr": {"auto": False, "backend": "sensevoice"},
                           "record": {"dictation": {"asr_model": "sensevoice-small"}}}):
                d = T.dictation_models(A.hw())
                self.assertEqual((d["configured"], d["selected"]), ("sensevoice-small", "sensevoice-small"))
            with A.config({"asr": {"auto": False, "backend": "sensevoice"}}):
                self.assertEqual(T.dictation_models(A.hw(ram=8.0))["recommended"], "sensevoice-small")
        finally:
            T.installed = real


if __name__ == "__main__":
    unittest.main()
