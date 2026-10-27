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
    if fn == "commitSplit":
        return list(S.commit_split(r["text"]))
    if fn == "midSentence":
        return S.mid_sentence(r["text"])
    if fn == "keepCase":
        return S.keep_case(r["input"], r["output"])
    if fn == "windowInput":
        return S.window_input(r["carry"], r["piece"])
    raise AssertionError(fn)


def test_shared_fixture():
    rs = rows()
    assert len(rs) >= 30
    for r in rs:
        assert run(r) == r["want"], r


def test_no_word_lists_left():
    """Seams are pauses and marks (docs/design/dictation.md §Rules vs model): no stop words, no correction markers,
    no ordinary-word list."""
    for name in ("OPEN_ENDS_ZH", "OPEN_ENDS_EN", "OPEN_STARTS_ZH", "OPEN_STARTS_EN", "BINDING_ZH", "ORDINARY",
                 "plausibly_final", "decapitalize", "binds", "starts_with_correction", "ends_with_correction",
                 "comma_join", "_SC_ZH", "_EC_ZH"):
        assert not hasattr(S, name), name


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


def test_one_window_falls_back_and_only_it():
    """A refused window types its own transcript — the other windows keep their polish — and its seam gets a comma."""
    def refuse(text, ctx):
        return {"text": text, "fell_back": True, "reason": "copied"}
    fn, calls = scripted({"第一把测试全部跑完": refuse})
    r = S.stream(LIST, PAUSES, fn)
    assert r["pieces"][1]["fell_back"] and not r["pieces"][2]["fell_back"]
    assert "第一，把测试全部跑完" in r["text"], r["text"]            # the seam inside the refused window
    assert r["text"].startswith("明天要做三件事，")


def test_a_correction_across_a_pause_is_just_words():
    """No piece is merged or held back because of what it says: 「不对」 is polished like any other words (Light keeps
    them; Structured resolves them at key-up, over the whole take)."""
    pieces = [{"raw": "资料我晚上发群里，不对。"}, {"raw": "下午就发。"}]
    fn, calls = scripted({})
    r = S.stream(pieces, [0.7, None], fn)
    assert [c[0] for c in calls] == ["资料我晚上发群里，不对", "下午就发。"] or \
        [c[0] for c in calls][0].startswith("资料我晚上发群里，不对"), calls
    assert "不对" in r["text"] and not any(q.get("deferred") for q in r["pieces"])


def test_no_pause_puts_a_mark_into_the_window():
    """The carried clause goes into the next window with no mark, however long the pause: the mark the window before
    ended it with was polish's own, written without seeing what came next, and kept a mark at a thinking pause
    (「报过绘画班但是，我报的是」). Whether the sentence ended is the model's call from the words on both sides."""
    for pause in (0.6, 1.5, 3.0, None):
        pieces = [{"raw": "我小时候报过绘画班，但是。"}, {"raw": "我报的是一个线上的课。"}]
        fn, calls = scripted({"我小时候报过绘画班，但是": {"text": "我小时候报过绘画班，但是。"}})
        S.stream(pieces, [pause, None], fn)
        assert calls[-1][0] == "但是我报的是一个线上的课。", (pause, calls)
    # a real sentence end is the model's to write, seeing both sides
    pieces = [{"raw": "我们先开个短会。"}, {"raw": "下午修问题。"}]
    fn, calls = scripted({"我们先开个短会": {"text": "我们先开个短会。"},
                          "我们先开个短会下午修问题。": {"text": "我们先开个短会。下午修问题。"}})
    r = S.stream(pieces, [1.5, None], fn)
    assert calls[-1][0] == "我们先开个短会下午修问题。", calls
    assert r["text"] == "我们先开个短会。下午修问题。", r["text"]


def test_a_refused_window_after_a_long_pause_keeps_the_heard_mark():
    """A window that falls back types the transcript as said: after a long pause the seam rule's mark (the speech
    model's), as without polish."""
    def refuse(text, ctx):
        return {"text": text, "fell_back": True, "reason": "copied"}
    pieces = [{"raw": "我们先开个短会。"}, {"raw": "下午修问题。"}]
    fn, _ = scripted({"我们先开个短会": {"text": "我们先开个短会。"}, "我们先开个短会下午修问题。": refuse})
    r = S.stream(pieces, [1.5, None], fn)
    assert r["text"] == "我们先开个短会。下午修问题。", r["text"]


def test_a_window_that_continues_a_sentence_loses_the_models_capital():
    pieces = [{"raw": "I looked at the new build this morning,"}, {"raw": "and the onboarding still feels long."}]

    def fn(text, ctx):           # the model writes every window as a sentence of its own
        t = text[0].upper() + text[1:]
        return {"text": t if t.endswith(".") else t + ".", "fell_back": False}
    r = S.stream(pieces, [0.7, None], fn)
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

        def generate(self, text, deadline, terms=None, context=None, mode="light", variant=None):
            so = (context or {}).get("dictated") or ""
            return (so + text + "。"), False
    e = Echoing()
    r = S.stream(LIST, PAUSES, lambda t, c: e.polish(t, "fake", 3, [], c))
    assert not r["fell_back"], r
    assert r["text"].count("明天要做三件事") == 1, r["text"]


def test_structured_runs_once_on_lights_stitched_text():
    """Structured at key-up: the windows (polished while talking, the last one included) are stitched as Light's text,
    and that goes through one structuring pass."""
    fn, calls = scripted({})
    seen = []

    def structure(text):
        seen.append(text)
        return {"text": "明天要做三件事：\n1. 把测试全部跑完\n2. 把文档更新一下\n3. 提交代码，然后发给小王看看", "list": True,
                "fell_back": False, "ms": 5}
    r = S.stream(LIST, PAUSES, fn, structure=structure)
    light = S.stream(LIST, PAUSES, scripted({})[0])
    assert len(calls) == 4 and seen == [light["text"]]
    assert r["text"].startswith("明天要做三件事：\n1.") and r["structured"]["list"] and r["light"] == light["text"]


def test_a_refused_structure_types_light():
    fn, _calls = scripted({})
    r = S.stream(LIST, PAUSES, fn, structure=lambda t: {"text": t, "fell_back": True, "reason": "dropped"})
    assert r["text"] == S.stream(LIST, PAUSES, scripted({})[0])["text"]
    assert r["structured"]["fell_back"] and r["structured"]["reason"] == "dropped"
