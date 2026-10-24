"""Dictation styles (docs/design/dictation-styles.md §3): the list renderer's Python port against the fixture the app's
DictationList.swift is checked against too, what must never become a list, the category variants, the chat variant's
particles in polish.py's repair, and the Dictation Lab's style dimension with its "light never lists" check.

  uv run --with pytest pytest tests/test_dictation_styles.py -q
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import dictation_styles as S  # noqa: E402
import polish  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "dictation_lists.jsonl"


def rows():
    return [json.loads(ln) for ln in FIXTURE.read_text(encoding="utf-8").splitlines() if ln.strip()]


# ------------------------------------------------------------------ the renderer
@pytest.mark.parametrize("row", rows(), ids=lambda r: r["name"])
def test_lists_match_the_shared_fixture(row):
    assert S.markers(row["text"]) == row["markers"]
    assert S.render(row["text"], row["min"]) == row["expect"]


def test_fixture_covers_both_ways():
    rs = rows()
    assert sum(1 for r in rs if r["expect"]) >= 14 and sum(1 for r in rs if r["expect"] is None) >= 16


@pytest.mark.parametrize("row", [r for r in rows() if r["expect"]], ids=lambda r: r["name"])
def test_only_marker_words_go(row):
    d = S.detect(row["text"])
    text = row["text"]
    for m in reversed(S.best_run(S.candidates(text))):
        text = text[:m["start"]] + text[m["end"]:]
    out = "\n".join(re.sub(r"^[0-9]+\. ", "", ln) for ln in S.render(row["text"]).split("\n"))
    assert S.units(out) == S.units(text)
    assert len(d["removed"]) == d["markers"]


@pytest.mark.parametrize("text", ["以及我们的其他同事", "然后呢，然后我们就走了", "另外，还有一个问题", "这是第一次，也是第一天",
                                  "一是一，二是二", "一是一是，对对对", "We also need this, and then that.",
                                  "Then we left, and then we came back.", "帮我列个清单，把这周要做的事情整理一下。",
                                  "写成邮件发给小王。", "Make a list of the files that changed."])
def test_enumeration_words_and_instructions_stay_prose(text):
    assert S.render(text, 2) is None and S.render(text, 3) is None
    assert S.apply_style(text, "light", "notes")["text"] == text


def test_light_never_lists_the_polish_eval_sets():
    """Every input and reference of both polish eval sets (spoken lists included) through light, in every category:
    not one numbered line."""
    n = 0
    for f in ("polish_eval.jsonl", "polish_overdelete.jsonl"):
        for ln in (ROOT / "tests" / "fixtures" / f).read_text(encoding="utf-8").splitlines():
            case = json.loads(ln)
            for t in (case["input"], case.get("reference") or ""):
                for cat in S.CATEGORIES:
                    assert S.list_lines(S.apply_style(t, "light", cat)["text"]) == 0, (case["id"], cat)
                    assert S.list_lines(S.apply_style(t, "verbatim", cat)["text"]) == 0
                n += 1
    assert n >= 100


def test_renderer_is_fast():
    long = "明天要做三件事。第一，把测试全部跑完。第二，把文档更新一下。第三，提交代码。" * 20
    t0 = time.perf_counter()
    for _ in range(20):
        S.render(long)
    assert (time.perf_counter() - t0) / 20 < 0.02


# ------------------------------------------------------------------ styles, variants, categories
def test_apply_style():
    t = "明天要做三件事。第一，跑测试。第二，更新文档。第三，提交。"
    assert S.apply_style(t, "light")["text"] == t and not S.apply_style(t, "light")["rendered"]
    st = S.apply_style(t, "structured", "notes")
    assert st["rendered"] and st["text"].startswith("明天要做三件事：\n1. 跑测试") and st["markers"] == 3
    assert S.apply_style("我说两点：一是贵，二是慢。", "auto")["rendered"] is False         # Auto needs three
    with pytest.raises(ValueError):
        S.apply_style(t, "email")


def test_variants():
    assert S.variant("好的，那我们晚上七点见吧。", "chat", False) == ("好的，那我们晚上七点见吧", ["final_stop"])
    assert S.variant("好的。晚上见。", "chat", False)[0] == "好的。晚上见。"
    assert S.variant("你来吗？", "chat", False)[0] == "你来吗？"
    assert S.variant("It costs 3.5 dollars.", "chat", False)[0] == "It costs 3.5 dollars"
    assert S.variant("第一段。\n\n第二段。", "chat", False)[0] == "第一段。\n第二段。"
    assert S.variant("Run the tests.\n\nThen push.", "code", False)[0] == "Run the tests. Then push."
    assert S.variant("先跑测试。\n再推上去。", "code", False)[0] == "先跑测试。再推上去。"
    assert S.variant("1. A\n2. B", "code", True)[0] == "1. A\n2. B"
    assert S.variant("好的。", "mail", False)[0] == "好的。"


def test_categories_match_the_app():
    assert S.category("com.tencent.xinWeChat") == "chat"
    assert S.category("com.bytedance.macos.feishu") == "chat"
    assert S.category("com.googlecode.iterm2") == "code"
    assert S.category("com.jetbrains.pycharm") == "code"
    assert S.category("com.apple.mail") == "mail"
    assert S.category("md.obsidian") == "notes"
    assert S.category("com.1password.1password") == "other"
    assert S.category(None) == "other"
    # the same table as DictationStyle.swift
    swift = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/DictationStyle.swift").read_text(encoding="utf-8")
    exact = dict(re.findall(r'"([a-z0-9.\-]+)": \.(chat|code|mail|notes)', swift))
    assert exact == S._EXACT


def test_cli():
    import subprocess
    r = subprocess.run([sys.executable, str(SCRIPTS / "dictation_styles.py"), "style", "--text", "第一，跑测试。第二，提交代码。",
                        "--style", "structured"], capture_output=True, text=True)
    assert json.loads(r.stdout)["text"] == "1. 跑测试\n2. 提交代码"


# ------------------------------------------------------------------ chat keeps its particles (polish.py's repair)
def test_chat_puts_back_the_final_particles_polish_dropped():
    out, spans = polish.repair("好的那我们晚上七点见吧", "好的，那我们晚上七点见。", keep_particles=True)
    assert out == "好的，那我们晚上七点见吧。" and spans == ["particle:吧"]
    out, _ = polish.repair("呃我我我刚才试了一下登录然后呢然后就卡住了啊", "我刚才试了一下登录，然后就卡住了。", keep_particles=True)
    assert out.endswith("卡住了啊。")
    out, _ = polish.repair("你今天来不来呢", "你今天来不来？", keep_particles=True)
    assert out == "你今天来不来呢？"
    # not chat: as before (the eval sets' references stay untouched)
    assert polish.repair("好的那我们晚上七点见吧", "好的，那我们晚上七点见。") == ("好的，那我们晚上七点见。", [])
    # a filler in the middle is still a filler; a stutter of particles isn't put back
    out, _ = polish.repair("嗯我觉得啊这个方案还行", "我觉得这个方案还行。", keep_particles=True)
    assert "啊这" not in out
    # a particle put back is tone, not lost content
    assert polish.repaired_share("好的那我们晚上七点见吧", ["particle:吧"]) == 0


def test_chat_particles_keep_the_eval_references_and_self_corrections():
    # the self-correction still goes; only the particle at the end comes back
    out, _ = polish.repair("把这个，不对，这两个拿到那一边去吧", "把这两个拿到那一边去。", keep_particles=True)
    assert out == "把这两个拿到那一边去吧。"
    for ln in (ROOT / "tests" / "fixtures" / "polish_eval.jsonl").read_text(encoding="utf-8").splitlines():
        c = json.loads(ln)
        fixed, spans = polish.repair(c["input"], c["reference"], keep_particles=True)
        assert all(s.startswith("particle:") for s in spans), (c["id"], spans)
        assert polish.guard(c["input"], fixed)["pass"] or not polish.guard(c["input"], c["reference"])["pass"], c["id"]


# ------------------------------------------------------------------ the Dictation Lab's style dimension
def test_lab_style_specs():
    import dictation_lab as L
    assert L.parse_spec("style=structured")["style"] == "structured"
    assert L.parse_spec("style=structured")["key"].endswith(",style=structured")
    assert L.parse_spec("style=light")["key"] == L.parse_spec("current")["key"]       # light is the default: same runs
    assert L.parse_spec("category=chat")["category"] == "chat"
    with pytest.raises(L.Fail):
        L.parse_spec("style=email")


def test_lab_reruns_a_case_per_style_and_light_never_lists(tmp_path, monkeypatch):
    sys.path.insert(0, str(ROOT / "tests"))
    from test_dictation_lab import FakePipeline, make_case  # noqa: E402
    import dictation_lab as L
    h = tmp_path / "home"
    (h / "dictation").mkdir(parents=True)
    monkeypatch.setenv("BLURT_HOME", str(h))
    said = "明天要做三件事。第一，跑测试。第二，更新文档。第三，提交。"
    c = make_case(h, "c1", 1.0, said)
    light = L.run_case(c, L.parse_spec("current"), FakePipeline({1.0: said}))
    assert light["outputs"]["text"] == said and light["outputs"]["listed"] is False
    assert light["outputs"]["style"]["markers"] == 3 and not light["outputs"]["style"]["rendered"]
    st = L.run_case(c, L.parse_spec("style=structured"), FakePipeline({1.0: said}))
    assert st["outputs"]["text"].split("\n")[1] == "1. 跑测试" and st["outputs"]["style"]["rendered"]
    verb = FakePipeline({1.0: said})
    L.run_case(c, L.parse_spec("style=verbatim"), verb)
    assert not [x for x in verb.calls if "polish" in x]                                 # verbatim: no polish
    # a polish model that turns speech into a list under light: caught
    listing = FakePipeline({1.0: said}, polish=lambda t: "1. 跑测试\n2. 更新文档\n3. 提交")
    bad = L.run_case(c, L.parse_spec("current"), listing)
    assert bad["outputs"]["listed"] is True
    res = L.regression(L.parse_spec("current"), FakePipeline({1.0: said}, polish=lambda t: "1. 跑测试\n2. 更新文档\n3. 提交"),
                       save=False)
    assert res["overall"]["listed"] == 1 and res["rows"][0]["listed"]
    # a chat case's polish gets the chat variant
    chat = make_case(h, "c2", 2.0, "好的")
    chat["app"] = {"bundle": "com.tencent.xinWeChat"}
    L.save_case(chat)

    class Recording(FakePipeline):
        def polish(self, text, model, vocab, context, timeout, variant=None):
            self.calls.append({"polish": text, "variant": variant})
            return {"ok": True, "text": text, "polished": text, "fell_back": False}

    rec = Recording({2.0: "好的。"})
    out = L.run_case(L.load_case("c2"), L.parse_spec("current"), rec)
    assert [x["variant"] for x in rec.calls if "polish" in x] == ["chat"]
    assert out["outputs"]["text"] == "好的" and out["outputs"]["style"]["variant"] == ["final_stop"]
