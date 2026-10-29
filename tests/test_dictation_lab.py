"""Dictation Lab (docs/design/dictation.md §Lab): the case schema, the metrics (CER / WER / punctuation / term
accuracy, the diff — shared with BlurtCore's DictationLab.swift through tests/fixtures/lab_metrics.jsonl), the
regression runner (with a fake pipeline: no models needed), the dataset export and the feature-detected learner.

  uv run --with pytest pytest tests/test_dictation_lab.py -q
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import wave
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import dictation_lab as L  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "lab_metrics.jsonl"


@pytest.fixture()
def home(tmp_path, monkeypatch):
    h = tmp_path / "home"
    (h / "dictation").mkdir(parents=True)
    monkeypatch.setenv("BLURT_HOME", str(h))
    return h


def tone(path: Path, seconds: float, rate: int = 16000, channels: int = 1) -> Path:
    import array
    import math
    n = int(seconds * rate)
    a = array.array("h", (int(8000 * math.sin(i / 7)) for i in range(n) for _ in range(channels)))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(a.tobytes())
    return path


def cli(*args, home: Path) -> dict:
    env = {**os.environ, "BLURT_HOME": str(home)}
    r = subprocess.run([sys.executable, str(SCRIPTS / "dictation_lab.py"), *args], capture_output=True, text=True, env=env)
    return json.loads(r.stdout.strip().splitlines()[-1])


# ------------------------------------------------------------------ metrics
def fixture_rows():
    return [json.loads(ln) for ln in FIXTURE.read_text(encoding="utf-8").splitlines() if ln.strip()]


@pytest.mark.parametrize("row", fixture_rows(), ids=lambda r: r["ref"][:12] or "empty")
def test_metrics_match_the_shared_fixture(row):
    s = L.score(row["ref"], row["hyp"], row["terms"] or None)
    assert s["wer"] == row["wer"] and s["cer"] == row["cer"] and s["punct"] == row["punct"] and s["exact"] == row["exact"]
    assert (s["terms"] or {}).get("accuracy") == row["term_accuracy"]
    assert L.units(row["ref"]) == row["units"]
    assert [[d["op"], d["ref"], d["hyp"]] for d in L.diff(row["ref"], row["hyp"])] == row["diff"]


def test_units_cjk_by_character_latin_by_word():
    assert L.units("用 Claude Code 写的 PR，好吗？") == ["用", "claude", "code", "写", "的", "pr", "好", "吗"]
    assert L.units("I don't know, 3.5 MB") == ["i", "don't", "know", "3", "5", "mb"]
    assert L.units("ＡＢＣ１２") == ["abc12"]                       # full-width forms count as their ASCII ones


def test_wer_and_cer_by_hand():
    s = L.score("我们明天开会", "我们后天开会")
    assert s["wer"] == round(1 / 6, 4) and s["cer"] == round(1 / 6, 4)
    s = L.score("move the meeting", "move meeting")
    assert s["wer"] == round(1 / 3, 4) and s["cer"] == round(3 / 14, 4)
    assert L.score("", "anything")["wer"] is None                   # no reference: no rate
    assert L.score("你好", "")["wer"] == 1.0
    assert L.score("今天开会。", "今天开会，")["wer"] == 0.0           # punctuation is not a word …
    assert L.score("今天开会。", "今天开会，")["punct"] == 1.0         # … it has its own rate


def test_term_accuracy_wants_the_spelling():
    hit, miss = L.term_hits(["Claude Code", "tmux", "口喷鸡"], "用 claude code 开 T mux，口喷鸡")
    assert hit == ["Claude Code", "口喷鸡"] and miss == ["tmux"]
    assert L.expected_terms("在 Claude Code 里用 Claude", ["Claude", "Claude Code", "Codex"]) == ["Claude Code", "Claude"]


def test_diff_joins_back_to_both_texts():
    ref, hyp = "We should move the meeting to Thursday.", "we should move meeting to thursday, OK"
    d = L.diff(ref, hyp)
    assert "".join(c["ref"] for c in d) == ref
    assert "".join(c["hyp"] for c in d) == hyp
    assert {c["op"] for c in d} == {"equal", "delete", "replace"}


# ------------------------------------------------------------------ the case schema
def test_blank_case_is_valid_and_validate_catches_mistakes():
    c = L.blank_case("20261024-120000-abcd", "take")
    assert L.validate(c) == []
    assert set(c) >= {"schema", "id", "created", "audio", "reference", "corrected", "scenario", "errors", "rating",
                      "note", "app", "context", "config", "take", "metrics", "app_version"}
    bad = {**c, "errors": ["term", "nonsense"], "rating": {"stars": 7}}
    assert set(L.validate(bad)) == {"errors: unknown tag", "rating.stars"}
    leak = {**c, "context": {"included": False, "before": "the field's text"}}
    assert L.validate(leak) == ["context: text kept without consent"]
    assert L.ERROR_TAGS == ["term", "code_switch", "punctuation", "filler", "dropped", "made_up", "segmentation",
                            "clipped", "slow"]


def test_add_converts_and_stores_a_case(home, tmp_path):
    src = tone(tmp_path / "in.wav", 1.5)
    out = cli("add", "--wav", str(src), "--reference", "今天下午三点开会", "--tags", "term,bogus", home=home)
    assert out["ok"]
    c = out["case"]
    d = home / "dictation" / "lab" / "cases" / c["id"]
    assert (d / "audio.wav").exists() and json.loads((d / "case.json").read_text())["id"] == c["id"]
    assert c["duration"] == 1.5 and c["errors"] == ["term"] and L.validate(c) == []
    with wave.open(str(d / "audio.wav")) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2)
    listed = cli("list", home=home)["cases"]
    assert [x["id"] for x in listed] == [c["id"]] and listed[0]["truth"] == "今天下午三点开会"
    assert cli("delete", c["id"], home=home)["deleted"] == [c["id"]] and not d.exists()


@pytest.mark.skipif(not (shutil.which("afconvert") or shutil.which("ffmpeg")), reason="no audio converter")
def test_add_resamples_other_audio(home, tmp_path):
    src = tone(tmp_path / "cd.wav", 1.0, rate=44100, channels=2)
    c = cli("add", "--wav", str(src), home=home)["case"]
    with wave.open(str(home / "dictation" / "lab" / "cases" / c["id"] / "audio.wav")) as w:
        assert (w.getframerate(), w.getnchannels()) == (16000, 1)
        assert abs(w.getnframes() / 16000 - 1.0) < 0.05


def test_from_history_with_and_without_audio(home):
    hd = home / "dictation"
    (hd / "audio").mkdir()
    tone(hd / "audio" / "d-1.wav", 1.0)
    rows = [{"id": "d-1", "t": "2026-10-24T10:00:00+08:00", "app": "WeChat", "bundle": "com.tencent.xinWeChat",
             "duration": 1.0, "raw": "用 cloud code 写", "polished": "用 Claude Code 写。", "text": "用 Claude Code 写。",
             "model": "gemma-4-e2b", "fell_back": False, "reason": None, "insert": "pasted", "audio": "audio/d-1.wav",
             "asr_model": "qwen3-asr-1.7b-mlx", "terms_applied": ["Claude Code"], "asr_ms": 120, "context": "secret text"},
            {"id": "d-2", "t": "2026-10-24T10:01:00+08:00", "app": "Notes", "bundle": "com.apple.Notes", "duration": 2.0,
             "raw": "hello", "polished": None, "text": "hello", "model": None, "fell_back": False, "reason": None,
             "insert": "pasted", "audio": None}]
    (hd / "history.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    a = cli("from-history", "d-1", home=home)["case"]
    assert a["audio"] == "audio.wav" and a["app"] == {"bundle": "com.tencent.xinWeChat"}
    assert a["take"]["raw"] == "用 cloud code 写" and a["take"]["timings"]["asr_ms"] == 120
    assert "secret" not in json.dumps(a, ensure_ascii=False)              # the history's context never comes along
    assert L.validate(a) == []
    b = cli("from-history", "d-2", home=home)["case"]
    assert b["audio"] is None and b["reference"] == "hello"                  # text only: a reference-only case
    assert cli("from-history", "d-1", home=home)["existed"] is True          # once per dictation
    assert cli("from-history", "nope", home=home)["code"] == "not_found"


def _kept_take(home: Path) -> dict:
    """A kept take (keep_audio): 3 s of audio, cut once at a 1.4 s pause, typed with a comma the pause put there."""
    hd = home / "dictation"
    (hd / "audio").mkdir(exist_ok=True)
    tone(hd / "audio" / "k-1.wav", 3.0)
    e = {"id": "k-1", "t": "2026-10-28T10:00:00+08:00", "app": "Lark", "bundle": "com.electron.lark", "duration": 3.0,
         "raw": "飞书绘画里面的消息", "polished": "飞书绘画，里面的消息。", "text": "飞书绘画，里面的消息。", "model": "gemma4-e2b",
         "fell_back": False, "reason": None, "insert": "pasted", "audio": "audio/k-1.wav", "asr_model": "qwen3-asr-1.7b-mlx",
         "pieces": [{"start": 0.0, "end": 1.5, "pause_after": 1.4, "asr_text": "飞书绘画。", "raw": "飞书绘画。",
                     "polish_in": "飞书绘画", "text": "", "polished": "飞书绘画", "fell_back": False},
                    {"start": 1.5, "end": 3.0, "asr_text": "里面的消息。", "raw": "里面的消息。",
                     "polish_in": "飞书绘画。里面的消息", "text": "飞书绘画，里面的消息。", "polished": "飞书绘画，里面的消息。",
                     "fell_back": False}]}
    (hd / "history.jsonl").write_text(json.dumps(e, ensure_ascii=False) + "\n", encoding="utf-8")
    return e


def test_from_history_keeps_the_pieces_and_the_correction(home):
    _kept_take(home)
    c = cli("from-history", "k-1", "--corrected", "飞书会话里面的消息。", "--tags", "term,punctuation", home=home)["case"]
    segs = c["take"]["segments"]
    assert [(s["start"], s["end"], s["pause_after"]) for s in segs] == [(0.0, 1.5, 1.4), (1.5, 3.0, None)]
    assert segs[1]["polish_in"] == "飞书绘画。里面的消息"                 # the window's input: where the comma came from
    assert c["corrected"] == "飞书会话里面的消息。" and c["errors"] == ["term", "punctuation"]
    assert L.validate(c) == []


def test_review_flags_what_one_pass_heard_differently_and_seam_marks(home):
    e = _kept_take(home)
    fake = FakePipeline({3.0: "飞书会话里面的消息。"})
    r = L.review_take(e, fake, L.parse_spec("mode=whole,polish=off"))
    assert [c["secs"] for c in fake.calls] == [3.0]                       # the whole take, once
    assert r["heard_once"] == "飞书会话里面的消息。"
    assert {"once": "会话", "streamed": "绘画"} in r["heard_diff"]
    assert "heard_differently" in r["flags"] and "seam_marks" in r["flags"]
    assert r["pieces"][0]["pause_after"] == 1.4


def test_review_counts_takes_without_audio(home):
    e = _kept_take(home)
    (home / "dictation" / "audio" / "k-1.wav").unlink()
    out = cli("review", home=home)
    assert out["takes"] == [] and out["no_audio"] == 1


# ------------------------------------------------------------------ the runner
class FakePipeline:
    """A speech model that answers from a table by audio length (seconds, 1 decimal), and a polish that capitalises."""

    def __init__(self, heard: dict[float, str], polish=None, structure=None, tags: dict[float, dict] | None = None):
        self.heard, self.calls, self.polish_fn, self.structure_fn = heard, [], polish, structure
        self.tags = tags or {}

    def asr(self, wav, model, vocab, prior, language, hint=""):
        with wave.open(str(wav)) as w:
            secs = round(w.getnframes() / 16000, 1)
        self.calls.append({"secs": secs, "model": model, "vocab": vocab, "prior": prior, "hint": hint})
        r = {"ok": True, "text": self.heard.get(secs, ""), "asr_text": self.heard.get(secs, ""), "model": model or "m-current",
             "language": "zh", "terms": []}
        if secs in self.tags:
            r["tag"] = self.tags[secs]
        return r

    def polish(self, text, model, vocab, context, timeout, variant=None):
        self.calls.append({"polish": text, "model": model, "context": context})
        out = self.polish_fn(text) if self.polish_fn else text
        return {"ok": True, "text": out, "polished": out, "fell_back": False, "model": model or "p-current", "context": bool(context)}

    def structure(self, text, model, vocab, timeout=None):
        """polish.py's structuring pass: `structure(text)` → the structured text (None: refused)."""
        self.calls.append({"structure": text})
        out = self.structure_fn(text) if self.structure_fn else text
        if out is None:
            return {"ok": True, "text": text, "fell_back": True, "reason": "dropped", "list": False, "ms": 1}
        return {"ok": True, "text": out, "structured": out, "fell_back": False, "ms": 1,
                "list": len([ln for ln in out.split("\n") if ln[:1].isdigit()]) >= 2}


def make_case(home: Path, cid: str, seconds: float, corrected: str, segments=None, context=None) -> dict:
    c = L.blank_case(cid, "take")
    d = L.case_path(cid)
    d.mkdir(parents=True)
    tone(d / "audio.wav", seconds)
    c.update(audio="audio.wav", duration=seconds, corrected=corrected, take={"segments": segments or [], "text": ""})
    if context:
        c["context"] = {"included": True, **context}
    L.save_case(c)
    return c


def test_pieces_replay_the_cuts_with_prior_and_seams(home):
    segs = [{"start": 0, "end": 1.0, "pause_after": 0.6}, {"start": 1.0, "end": 3.0, "pause_after": None}]
    c = make_case(home, "c1", 3.0, "我们明天开会讨论方案", segs)
    fake = FakePipeline({1.0: "我们明天开会。", 2.0: "讨论方案。"})
    r = L.run_case(c, L.parse_spec("rehear=off"), fake)
    assert r["outputs"]["raw"] == "我们明天开会讨论方案。"                  # the breath's full stop went
    assert [x.get("prior") for x in fake.calls if "secs" in x] == ["", "我们明天开会。"]
    assert r["metrics"]["wer"] == 0.0 and r["outputs"]["timings"]["segments"] == 2
    whole = L.run_case(c, L.parse_spec("mode=whole"), FakePipeline({3.0: "我们明天开会讨论方案"}))
    assert whole["outputs"]["timings"]["segments"] == 1


def test_windows_replay_the_apps_polish_windows(home):
    """mode=windows: each piece polished in a window (the carried clause + the piece), the text so far as `dictated`
    context — what the app does while the user talks (dictation_stitch.stream)."""
    segs = [{"start": 0, "end": 1.0, "pause_after": 0.7}, {"start": 1.0, "end": 3.0, "pause_after": None}]
    c = make_case(home, "w1", 3.0, "明天要做三件事，第一，把测试全部跑完。", segs)
    fake = FakePipeline({1.0: "明天要做三件事，第一，", 2.0: "把测试全部跑完。"}, polish=lambda t: t if t.endswith("。") else t + "。")
    r = L.run_case(c, L.parse_spec("mode=windows,rehear=off"), fake)
    pol = [x for x in fake.calls if "polish" in x]
    assert [x["polish"] for x in pol] == ["明天要做三件事，第一", "第一把测试全部跑完。"]
    assert pol[0]["context"] is None and pol[1]["context"] == {"dictated": "明天要做三件事，"}
    assert r["outputs"]["text"] == "明天要做三件事，第一把测试全部跑完。"
    assert r["outputs"]["windows"] == 2 and r["outputs"]["windows_fell_back"] == 0
    assert L.parse_spec("mode=windows,rehear=off")["key"].endswith("mode=windows")


def test_rehear_hears_the_pieces_again_in_windows(home):
    """rehear (the app's default since v1.0.4): the pieces once more in ~10 s windows, closed only at a pause cut, the
    windows' text so far as context; polish then works window by window. A window the model gives nothing for keeps
    its pieces' text."""
    segs = [{"start": 0, "end": 8.0, "pause_after": 0.6}, {"start": 8.0, "end": 16.0, "pause_after": 0.7},
            {"start": 16.0, "end": 20.0, "pause_after": None}]
    c = make_case(home, "r1", 20.0, "豆包也被忽悠了，尝试了第二次才找对。", segs)
    fake = FakePipeline({8.0: "豆宝也被忽悠了。", 4.0: "才找对。", 16.0: "豆包也被忽悠了，尝试了第二次"})
    r = L.run_case(c, L.parse_spec("mode=windows"), fake)
    asr = [x for x in fake.calls if "secs" in x]
    assert [x["secs"] for x in asr] == [8.0, 8.0, 4.0, 16.0]          # the pieces, then the first window (0–16 s)
    assert asr[-1]["prior"] == ""
    assert [w["pieces"] for w in r["outputs"]["rehear"]] == [[0, 1], [2]]
    assert r["outputs"]["raw"].startswith("豆包也被忽悠了，尝试了第二次")
    assert [x["polish"] for x in fake.calls if "polish" in x][0].startswith("豆包也被忽悠了")
    assert r["outputs"]["timings"]["windows"] == 2


def test_config_specs():
    cfg = L.parse_spec("asr=qwen3-asr-0.6b-mlx,polish=off,vocab=off")
    assert (cfg["asr"], cfg["polish"], cfg["vocab"], cfg["context"]) == ("qwen3-asr-0.6b-mlx", False, False, True)
    assert cfg["key"] == "asr=qwen3-asr-0.6b-mlx,polish=off,vocab=off,context=on,mode=pieces,rehear=on"
    assert L.parse_spec("polish=gemma-4-e4b")["polish_model"] == "gemma-4-e4b"
    assert L.parse_spec('{"asr": "x", "label": "mine"}')["label"] == "mine"
    assert L.parse_spec("current")["key"] == L.parse_spec("")["key"]
    with pytest.raises(L.Fail):
        L.parse_spec("speed=fast")


def test_context_goes_to_polish_only_when_the_user_included_it(home):
    a = make_case(home, "a", 1.0, "好的", context={"before": "我知道你就是", "after": "的。"})
    b = make_case(home, "b", 1.0, "好的")
    for c, want in ((a, {"before": "我知道你就是", "after": "的。"}), (b, None)):
        fake = FakePipeline({1.0: "好的"})
        L.run_case(c, L.parse_spec("current"), fake)
        assert [x["context"] for x in fake.calls if "polish" in x] == [want]
    fake = FakePipeline({1.0: "好的"})
    L.run_case(a, L.parse_spec("context=off"), fake)
    assert [x["context"] for x in fake.calls if "polish" in x] == [None]


def test_the_speech_request_gets_the_apps_hint(home):
    # the window title and the text around the cursor, as the app sends them (DictationContext.hint)
    a = make_case(home, "a", 1.0, "好的", context={"before": "用 tmux 跑", "after": "", "title": "Claude"})
    fake = FakePipeline({1.0: "好的"})
    L.run_case(a, L.parse_spec("current"), fake)
    assert [x["hint"] for x in fake.calls if "secs" in x] == ["Claude\n用 tmux 跑"]


def test_a_language_tag_near_the_line_is_flagged(home):
    # v0.9: the translated sentence sat 0.0006 over the English line; the Lab scored it as perfect and said nothing
    make_case(home, "near", 1.0, "这个 feature 下周上线")
    make_case(home, "clear", 2.0, "好的")
    fake = FakePipeline({1.0: "这个 feature 下周上线", 2.0: "好的"},
                        tags={1.0: {"tag": "Chinese", "p_en": 0.99, "p_zh": 0.01, "margin": -0.697},
                              2.0: {"tag": "Chinese", "p_en": 0.2, "p_zh": 0.8, "margin": -6.679}})
    res = L.regression(L.parse_spec("current"), fake, save=False)
    by = {r["id"]: r for r in res["rows"]}
    assert by["near"]["fragile_tag"] and by["near"]["tag_margin"] == -0.697
    assert not by["clear"]["fragile_tag"]
    assert res["overall"]["fragile_tags"] == 1
    assert L.tag_summary([]) == {"tag_margin": None, "fragile_tag": False}
    # a clear English piece (p_en 0.9999, +3.9 in log-odds) is no close call (v0.9 review: every English piece was)
    import dictation_vocab
    en = dictation_vocab.tag_margin(0.9999, 0.0001)
    assert L.tag_summary([{"tag": "English", "p_en": 0.9999, "p_zh": 0.0001, "margin": en}]) == {"tag_margin": en, "fragile_tag": False}


def test_regression_before_after_and_overall(home):
    make_case(home, "c1", 1.0, "今天下午三点开会")
    make_case(home, "c2", 2.0, "Claude Code is ready")
    c3 = L.blank_case("c3", "history")          # text only: not run
    c3["reference"] = "hello"
    L.save_case(c3)
    cfg = L.parse_spec("current")
    first = L.regression(cfg, FakePipeline({1.0: "今天下午三点开会", 2.0: "cloud code is ready"}))
    assert [r["change"] for r in first["rows"]] == ["new", "new"]
    assert first["overall"]["scored"] == 2 and first["overall"]["wer"] == 0.125
    second = L.regression(cfg, FakePipeline({1.0: "今天下午四点开会", 2.0: "Claude Code is ready"}))
    by = {r["id"]: r for r in second["rows"]}
    assert by["c1"]["change"] == "worse" and by["c2"]["change"] == "better" and by["c1"]["changed_text"]
    assert by["c1"]["before"]["wer"] == 0.0 and by["c1"]["after"]["wer"] == 0.125
    o = second["overall"]
    assert (o["better"], o["worse"], o["cases"]) == (1, 1, 2) and o["score"] == 93.8
    assert len(L.runs_of("c1")) == 2
    other = L.regression(L.parse_spec("polish=off"), FakePipeline({1.0: "x", 2.0: "y"}), save=False)
    assert {r["change"] for r in other["rows"]} == {"new"}                   # another configuration: its own history
    assert len(L.runs_of("c1")) == 2


def test_regression_reports_a_failing_case_and_goes_on(home):
    make_case(home, "c1", 1.0, "好")
    make_case(home, "c2", 2.0, "好")

    class Flaky(FakePipeline):
        def asr(self, wav, *a):
            with wave.open(str(wav)) as w:
                if w.getnframes() == 16000:
                    raise L.Fail("speech model failed", "asr_failed")
            return super().asr(wav, *a)

    res = L.regression(L.parse_spec("current"), Flaky({2.0: "好"}))
    assert {r["id"]: r["change"] for r in res["rows"]} == {"c1": "error", "c2": "new"}
    assert res["overall"]["errors"] == 1


def test_run_cli_with_no_cases_needs_no_models(home):
    out = cli("run", "--json", home=home)
    assert out["ok"] and out["rows"] == [] and out["overall"]["cases"] == 0


# ------------------------------------------------------------------ export, learn
def test_export_is_a_dataset(home, tmp_path):
    make_case(home, "c1", 1.0, "今天开会", context={"before": "secret before"})
    c2 = L.blank_case("c2", "history")
    c2["reference"] = "hello"
    L.save_case(c2)
    out = cli("export", "--out", str(tmp_path / "ds.zip"), home=home)
    assert out["cases"] == 2 and out["with_audio"] == 1
    with zipfile.ZipFile(tmp_path / "ds.zip") as z:
        names = set(z.namelist())
        assert {"manifest.jsonl", "dataset.json", "audio/c1.wav"} <= names
        rows = [json.loads(x) for x in z.read("manifest.jsonl").decode().splitlines()]
        assert json.loads(z.read("dataset.json"))["sample_rate"] == 16000
    by = {r["id"]: r for r in rows}
    assert by["c1"]["text"] == "今天开会" and by["c1"]["audio"] == "audio/c1.wav" and by["c2"]["audio"] is None
    assert "context" not in by["c1"]                                           # only with --include-context
    out = cli("export", "--out", str(tmp_path / "ds2.zip"), "--include-context", home=home)
    with zipfile.ZipFile(tmp_path / "ds2.zip") as z:
        rows = [json.loads(x) for x in z.read("manifest.jsonl").decode().splitlines()]
    assert {r["id"]: r.get("context") for r in rows}["c1"] == {"before": "secret before"}


def test_learn_is_feature_detected(home, monkeypatch):
    import dictation_vocab
    monkeypatch.delattr(dictation_vocab, "learn", raising=False)
    assert L.learn("cloud code", "Claude Code") == {"ok": True, "available": False}
    vf = home / "dictation" / "vocabulary.json"
    vf.write_text(json.dumps({"schema": 1, "terms": [{"term": "tmux", "sounds_like": [], "state": "active"}]}))

    def fake_learn(raw, corrected):
        d = json.loads(vf.read_text())
        d["terms"].append({"term": "Claude Code", "sounds_like": ["cloud code"], "source": "learned", "state": "suggested"})
        d["terms"][0]["sounds_like"].append("t mux")
        vf.write_text(json.dumps(d))
        return [{"term": "Claude Code"}]

    monkeypatch.setattr(dictation_vocab, "learn", fake_learn, raising=False)
    r = L.learn("用 cloud code", "用 Claude Code")
    assert r["available"] and r["result"] == [{"term": "Claude Code"}]
    by = {x["term"]: x for x in r["changes"]}
    assert by["Claude Code"]["before"] is None and by["Claude Code"]["after"]["state"] == "suggested"
    assert by["tmux"]["before"]["sounds_like"] == [] and by["tmux"]["after"]["sounds_like"] == ["t mux"]

    def broken(raw, corrected):
        raise RuntimeError("nope")

    monkeypatch.setattr(dictation_vocab, "learn", broken, raising=False)
    assert L.learn("a", "b")["error"].startswith("RuntimeError")


# ------------------------------------------------------------------ reading scripts
def test_the_builtin_pack_is_valid_and_covers_every_dimension():
    p = json.loads((SCRIPTS / "lab_packs" / "builtin.json").read_text(encoding="utf-8"))
    assert L.validate_pack(p) == []
    tags = {(k, x) for q in p["prompts"] for k, v in q["tags"].items() for x in (v if isinstance(v, list) else [v])}
    for k, allowed in L.PACK_TAGS.items():
        assert {x for kk, x in tags if kk == k} == set(allowed), k
    # what a correction or a filler should type is spelled out
    for q in p["prompts"]:
        if {"correction", "fillers"} & set(q["tags"]["features"]):
            assert q.get("expected") and q["expected"] != q["read"], q["id"]


def test_pack_validation_and_import(home, tmp_path):
    assert "prompts" in L.validate_pack({"schema": 1, "id": "x", "name": "X", "prompts": []})
    bad = {"schema": 1, "id": "x", "name": "X", "prompts": [{"id": "a", "read": "hi", "tags": {"length": "huge"}},
                                                           {"id": "a", "read": "yo"}]}
    assert set(L.validate_pack(bad)) == {"prompts[0].tags.length", "prompts[1].id"}
    f = tmp_path / "mine.json"
    f.write_text(json.dumps({"schema": 1, "id": "mine", "name": "Mine", "prompts": [{"id": "p1", "read": "你好"}]}))
    out = cli("import-pack", str(f), home=home)
    assert out["ok"] and Path(out["path"]) == home / "dictation" / "lab" / "packs" / "mine.json"
    packs = {p["id"]: p for p in cli("packs", home=home)["packs"]}
    assert packs["mine"]["builtin"] is False and packs["builtin-basics"]["builtin"] is True
    f.write_text("{not json")
    assert cli("import-pack", str(f), home=home)["code"] == "bad_pack"


def test_progress_and_tags_follow_the_cases(home):
    p = L.load_pack("builtin-basics")
    c = make_case(home, "c1", 1.0, "好的，收到。")
    c["prompt"] = {"pack": p["id"], "id": "b001", "tags": p["prompts"][0]["tags"]}
    L.save_case(c)
    assert L.validate(c) == []
    pr = L.pack_progress(p)
    assert pr["done"] == 1 and pr["total"] == len(p["prompts"]) and pr["takes"]["b001"][0]["case"] == "c1"
    assert L.case_tags(c)[:4] == ["pack:builtin-basics", "length:short", "scenario:chat", "languages:zh"]
    res = L.regression(L.parse_spec("current"), FakePipeline({1.0: "好的收到"}))
    assert res["by_tag"]["length:short"] == {"cases": 1, "wer": 0.0, "worse": 0}


def test_generated_prompts_are_cleaned_and_appended(home):
    answer = 'Sure, here you go:\n```json\n[{"read": "先跑测试，不对，先 rebase。", "expected": "先 rebase。", ' \
             '"tags": {"length": "short", "scenario": "coding", "languages": "zh-terms", "features": ["correction", "bogus"]}},' \
             ' {"read": ""}, {"read": "好的，收到。", "tags": {}}, {"read": "Ship it.", "tags": {"length": "tiny"}}]\n```'
    got = L.parse_generated(answer)
    assert [g["read"] for g in got] == ["先跑测试，不对，先 rebase。", "好的，收到。", "Ship it."]
    assert got[0]["tags"]["features"] == ["correction"] and got[0]["expected"] == "先 rebase。"
    assert got[2]["tags"] == {}
    p = L.load_pack("builtin-basics")
    n0 = len(p["prompts"])
    seen = []
    r = L.generate(p, 5, runner=lambda prompt: seen.append(prompt) or answer)
    assert r["added"] == 2 and len(p["prompts"]) == n0 + 2          # the one already in the pack isn't added again
    assert "JSON array" in seen[0] and "Examples:" in seen[0]
    assert L.validate_pack(p) == []
    L.save_pack(p)                                                    # a built-in grows as the user's own copy
    assert (home / "dictation" / "lab" / "packs" / "builtin-basics.json").exists()
    assert len(L.load_pack("builtin-basics")["prompts"]) == n0 + 2
    with pytest.raises(L.Fail):
        L.generate(p, 3, runner=lambda prompt: "no json here")
