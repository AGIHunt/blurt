"""DictationStitch / DictationStream's polish windows ported to Python (scripts/dictation_stitch.py) for the Dictation
Lab's `mode=windows`. tests/fixtures/dictation_seams.jsonl is shared with the Swift tests (DictationStitchTests): the
two implementations must agree. No model: the windows run against scripted polish answers.

  uv run --with pytest pytest tests/test_dictation_stitch.py -q
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import dictation_stitch as S  # noqa: E402
import polish  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "dictation_seams.jsonl"


def rows() -> list[dict]:
    return [json.loads(ln) for ln in FIXTURE.read_text(encoding="utf-8").splitlines() if ln.strip()]


def run(r: dict):
    fn = r["fn"]
    if fn == "joinPieces":
        return S.join_pieces(r["texts"], r["pauses"])
    if fn == "joinPiecesForFallback":
        return S.join_pieces(r["texts"], r["pauses"], fallback=True)
    if fn == "fallbackSeam":
        return S.fallback_seam(r["previous"], r["next"], r["pause"], r["heard"])
    if fn == "commaJoin":
        return S.comma_join(r["a"], r["b"])
    if fn == "commitSplit":
        return list(S.commit_split(r["text"]))
    if fn == "decapitalize":
        return S.decapitalize(r["text"])
    if fn == "midSentence":
        return S.mid_sentence(r["text"])
    if fn == "startsWithCorrection":
        return S.starts_with_correction(r["text"])
    if fn == "endsWithCorrection":
        return S.ends_with_correction(r["text"])
    if fn == "keepCase":
        return S.keep_case(r["input"], r["output"])
    raise AssertionError(fn)


def test_shared_fixture():
    rs = rows()
    assert len(rs) >= 30
    for r in rs:
        assert run(r) == r["want"], r


def scripted(answers: dict):
    """polish(text, context) → the answer for `text` (exact), else the text with a full stop; every call recorded."""
    calls = []

    def polish_fn(text, ctx):
        calls.append((text, ctx))
        a = answers.get(text)
        if callable(a):
            a = a(text, ctx)
        if a is None:
            a = {"text": text + "。", "polished": text + "。"}
        return {"ok": True, "fell_back": False, "ms": 1, **a}
    return polish_fn, calls


LIST = [{"raw": "明天要做三件事，第一，"}, {"raw": "把测试全部跑完。"}, {"raw": "第二，把文档更新一下。"},
        {"raw": "第三，提交代码，然后发给小王看看。"}]
PAUSES = [0.7, 0.8, 0.7, None]


def test_the_text_so_far_goes_as_its_own_key():
    fn, calls = scripted({})
    S.stream(LIST, PAUSES, fn)
    assert calls[0][1] is None
    assert all("dictated" in c[1] and "before" not in c[1] for c in calls[1:])
    # legacy (the lab's "before"): appended to the field's text before the cursor
    fn, calls = scripted({})
    S.stream(LIST, PAUSES, fn, legacy=True)
    assert all("before" in c[1] and "dictated" not in c[1] for c in calls[1:])


def test_one_window_falls_back_and_only_it():
    """A refused window types its own transcript — the other windows keep their polish — and its seam gets a comma."""
    def refuse(text, ctx):
        return {"text": text, "fell_back": True, "reason": "copied"}
    fn, calls = scripted({"第一把测试全部跑完": refuse})
    r = S.stream(LIST, PAUSES, fn)
    assert r["pieces"][1]["fell_back"] and not r["pieces"][2]["fell_back"]
    assert "第一，把测试全部跑完" in r["text"], r["text"]            # the seam inside the refused window
    assert r["text"].startswith("明天要做三件事，")
    # before: no punctuation at that seam
    fn, _ = scripted({"第一把测试全部跑完": refuse})
    assert "第一把测试全部跑完" in S.stream(LIST, PAUSES, fn, legacy=True)["text"]


def test_a_correction_piece_is_joined_with_a_comma():
    pieces = [{"raw": "把这个，"}, {"raw": "不对，这两个拿到那一边去。"}]
    fn, calls = scripted({})
    S.stream(pieces, [0.8, None], fn)
    assert calls[-1][0] == "把这个，不对，这两个拿到那一边去。"
    fn, calls = scripted({})
    S.stream(pieces, [0.8, None], fn, legacy=True)
    assert calls[-1][0] == "把这个不对，这两个拿到那一边去。"


def test_a_window_that_continues_a_sentence_loses_the_models_capital():
    pieces = [{"raw": "I looked at the new build this morning,"}, {"raw": "and the onboarding still feels long."}]

    def fn(text, ctx):           # the model writes every window as a sentence of its own
        t = text[0].upper() + text[1:]
        return {"text": t if t.endswith(".") else t + ".", "fell_back": False}
    r = S.stream(pieces, [0.7, None], fn)
    assert r["text"] == "I looked at the new build this morning. and the onboarding still feels long." or \
        "morning and the onboarding" in r["text"] or "morning, and the onboarding" in r["text"], r["text"]
    assert "And the" not in r["text"], r["text"]


def test_a_refused_take_types_the_fallback_text():
    fn, _ = scripted({})
    seen = {}

    def guard(raw, out, fb):
        seen["fb"] = fb
        return {"pass": False, "reason": "shrunk", "fallback_text": "FALLBACK"}
    r = S.stream(LIST, PAUSES, fn, guard)
    assert r["text"] == "FALLBACK" and r["reason"] == "stitch_shrunk"
    assert seen["fb"] == S.join_pieces([p["raw"] for p in LIST], PAUSES, fallback=True)


def test_the_real_guard_with_an_echoing_model():
    """End to end with polish.Engine's post-processing on a scripted model that repeats the text so far (the bug):
    the echo is trimmed, no window falls back."""
    class Echoing(polish.Engine):
        def load(self, model_id=None):
            self.model, self.model_id = object(), "fake"
            return self

        def generate(self, text, deadline, terms=None, context=None):
            so = (context or {}).get("dictated") or ""
            return (so + text + "。"), False
    e = Echoing()
    r = S.stream(LIST, PAUSES, lambda t, c: e.polish(t, "fake", 3, [], c))
    assert not r["fell_back"], r
    assert r["text"].count("明天要做三件事") == 1, r["text"]


def test_a_piece_that_ends_on_a_correction_waits_for_the_next():
    """「…晚上发群里，不对。」 + a pause + 「下午就发。」: polished alone, the model dropped the 不对 and kept both versions."""
    pieces = [{"raw": "资料我晚上发群里，不对。"}, {"raw": "下午就发。"}]
    fn, calls = scripted({})
    r = S.stream(pieces, [0.7, None], fn)
    assert [c[0] for c in calls] == ["资料我晚上发群里，不对，下午就发。"]
    assert r["pieces"][0].get("deferred")
