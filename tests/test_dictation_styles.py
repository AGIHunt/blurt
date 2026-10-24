"""Dictation styles (docs/design/dictation-styles.md §3): which text a style types (Structured: the polish model's
structuring pass; Auto: only when that is a list), what Light must never do (lists, in any category), the category
variants, the chat variant asking the model to keep its particles, and the Dictation Lab's style dimension with its
"light never lists" check.

  uv run --with pytest pytest tests/test_dictation_styles.py -q
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import dictation_styles as S  # noqa: E402
import polish  # noqa: E402


# ------------------------------------------------------------------ no rule-based renderer
def test_no_list_renderer_left():
    """Lists are the model's call (polish.py `structure`): no ordinal-marker tables in the scripts or the app."""
    for name in ("render", "detect", "candidates", "best_run", "markers", "_PATTERNS", "_EN_ORD", "ASKED_MARKERS"):
        assert not hasattr(S, name), name
    assert not (ROOT / "tests/fixtures/dictation_lists.jsonl").exists()
    assert not (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/DictationList.swift").exists()


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


@pytest.mark.parametrize("text", ["帮我列个清单，把这周要做的事情整理一下。", "写成邮件发给小王。", "Make a list of the files that changed."])
def test_instructions_stay_content(text):
    """「帮我列个清单」 / "make a list" said to an agent is content: Light types it as said, and it never switches a style."""
    assert S.apply_style(text, "light", "notes")["text"] == text


# ------------------------------------------------------------------ styles, variants, categories
def test_apply_style():
    light = "明天要做三件事，第一跑测试，第二更新文档。"
    listed = "明天要做三件事：\n1. 跑测试\n2. 更新文档"
    assert S.apply_style(light, "light", structured=listed) == {"text": light, "rendered": False, "variant": []}
    assert S.apply_style(light, "structured", "notes", listed) == {"text": listed, "rendered": True, "variant": []}
    # Structured that stayed a paragraph (a correction resolved, no list) is typed too
    assert S.apply_style("我们周五交，哦不，下周一交。", "structured", structured="我们下周一交。")["text"] == "我们下周一交。"
    # Auto: only a list
    assert S.apply_style(light, "auto", structured=listed)["rendered"] is True
    assert S.apply_style("我们周五交，哦不，下周一交。", "auto", structured="我们下周一交。")["text"] == "我们周五交，哦不，下周一交。"
    # no structured text (the pass refused, or never ran): Light's
    assert S.apply_style(light, "structured")["text"] == light
    with pytest.raises(ValueError):
        S.apply_style(light, "email")


def test_list_lines():
    assert S.list_lines("intro:\n1. a\n2. b") == 2
    assert S.list_lines("- a\n- b") == 2
    assert S.list_lines("1.5 GB is fine\n2024 was long") == 0
    assert S.list_lines("第一，跑测试。第二，提交。") == 0


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
                        "--style", "structured", "--structured", "1. 跑测试\n2. 提交代码"], capture_output=True, text=True)
    assert json.loads(r.stdout)["text"] == "1. 跑测试\n2. 提交代码"


# ------------------------------------------------------------------ chat keeps its particles: the model is told
def test_chat_asks_the_model_to_keep_its_particles():
    """No particle list: the chat variant is a note in the request ("a chat message: keep its tone words and
    sentence-final particles"); the cached prefix is the same for every variant."""
    m = polish.messages("好的那我们晚上七点见吧", variant="chat")
    assert "chat message" in m[-1]["content"] and m[-1]["content"].endswith("好的那我们晚上七点见吧")
    plain = polish.messages("好的那我们晚上七点见吧")
    assert plain[-1]["content"] == "好的那我们晚上七点见吧"
    assert m[:-1] == plain[:-1]
    # a particle the model dropped anyway is one unit: the repair leaves it (the model's call)
    assert polish.repair("好的那我们晚上七点见吧", "好的，那我们晚上七点见。") == ("好的，那我们晚上七点见。", [])


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
    listed = "明天要做三件事：\n1. 跑测试\n2. 更新文档\n3. 提交"
    c = make_case(h, "c1", 1.0, said)
    light = L.run_case(c, L.parse_spec("current"), FakePipeline({1.0: said}))
    assert light["outputs"]["text"] == said and light["outputs"]["listed"] is False
    assert not light["outputs"]["style"]["rendered"] and "structured" not in light["outputs"]
    fake = FakePipeline({1.0: said}, structure=lambda t: listed)
    st = L.run_case(c, L.parse_spec("style=structured"), fake)
    assert st["outputs"]["text"] == listed and st["outputs"]["style"]["rendered"]
    assert [x["structure"] for x in fake.calls if "structure" in x] == [said]           # Light's text, once
    assert st["outputs"]["structured"]["list"] is True
    # windows mode: the same, on the stitched windows
    fake = FakePipeline({1.0: said}, structure=lambda t: listed)
    st = L.run_case(c, L.parse_spec("mode=windows,style=structured"), fake)
    assert st["outputs"]["text"] == listed and st["outputs"]["timings"]["structure_ms"] >= 0
    # a refusal types Light's text
    refused = FakePipeline({1.0: said}, structure=lambda t: None)
    assert L.run_case(c, L.parse_spec("style=structured"), refused)["outputs"]["text"] == said
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
