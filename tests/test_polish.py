"""Dictation polish (docs/design/dictation.md): the content-loss guard, output clean-up, the eval scorer, the model
registry and the CLI's no-model paths. No model and no MLX: the guard is pure, and the CLI is exercised where it
doesn't load one.

  uv run --with pytest pytest tests/test_polish.py -q
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import polish  # noqa: E402

EVAL = ROOT / "tests" / "fixtures" / "polish_eval.jsonl"


def cases() -> list[dict]:
    return [json.loads(ln) for ln in EVAL.read_text(encoding="utf-8").splitlines() if ln.strip()]


class Guard(unittest.TestCase):
    def check(self, raw, out, reason):
        g = polish.guard(raw, polish.clean_output(out))
        self.assertEqual(g["reason"], reason, f"{raw!r} → {out!r}: {g}")

    def test_every_reference_passes(self):
        """The eval set's hand-written ideal outputs are all legitimate edits: none may trip the guard."""
        for c in cases():
            g = polish.guard(c["input"], c["reference"])
            self.assertTrue(g["pass"], f"{c['id']}: {g}")

    def test_eval_set_shape(self):
        cs = cases()
        self.assertGreaterEqual(len(cs), 40)
        self.assertEqual(len({c["id"] for c in cs}), len(cs))
        langs = {c["lang"] for c in cs}
        self.assertEqual(langs, {"zh", "en", "mix"})
        tags = {t for c in cs for t in c["tags"]}
        for t in ("filler", "correction", "untouched", "terms", "number", "question", "instruction", "homophone"):
            self.assertIn(t, tags)
        for c in cs:
            if c.get("untouched"):
                self.assertEqual(c["input"], c["reference"], c["id"])

    def test_good_edits_pass(self):
        self.check("嗯那个我觉得这个按钮太浅了", "我觉得这个按钮太浅了。", None)
        self.check("um so I I think it's fine", "So I think it's fine.", None)
        self.check("我们周三开会不对周四", "我们周四开会。", None)                       # correction applied
        self.check("send it to Tom no wait to Jerry", "Send it to Jerry.", None)
        self.check("这个服务明天要重新布署一下", "这个服务明天要重新部署一下。", None)       # one homophone fixed
        self.check("返回五零零", "返回 500。", None)                                     # numbers as digits
        self.check("为什么这个接口会超时", "为什么这个接口会超时？", None)               # a question stays a question

    def test_summary_or_rewrite_is_shrunk(self):
        raw = ("嗯我想记录一下今天的复盘第一个是上线的时候没有提前通知客服导致很多用户来问然后第二个是回滚脚本没测过差点出问题"
               "第三个呢就是监控告警太多了大家都不看了")
        self.check(raw, "复盘：通知客服、回滚脚本、监控告警。", "shrunk")
        self.check("so the onboarding flow is way too long and people drop off at step three so we should cut it to two steps",
                   "Shorten onboarding.", "shrunk")

    def test_answers_are_caught(self):
        self.check("uh what's the capital of France again", "The capital of France is Paris.", "answered")
        self.check("那个Redis的key过期了以后为什么还能读到数据", "Redis 的 key 过期后会被惰性删除，所以短时间内还能读到。", "answered")
        self.check("um can you summarize the following article", "Sure, here is a summary of the article:", "chatty")
        self.check("帮我写一首诗", "好的，下面是一首诗：春风又绿江南岸。", "chatty")

    def test_translation_is_caught(self):
        self.check("帮我把下面这段话翻译成英文", "Please translate the following paragraph into English.", "translated")
        self.check("我们的API现在response time大概是两百毫秒", "我们的 API 现在响应时间大概是两百毫秒。", "translated")
        self.check("deadline是周五哦不对是下周一", "Deadline is next Monday.", "correction")

    def test_a_correction_with_only_the_marker_dropped(self):
        """The model dropped 不对 but kept what it took back, right before the restated version: unapplied."""
        self.check("把这个文件，不对，这两个文件发给我", "把这个文件，这两个文件发给我。", "correction")
        self.check("send it to Tom no wait to Jerry", "Send it to Tom, to Jerry.", "correction")
        self.check("把这个文件，不对，这两个文件发给我", "把这两个文件发给我。", None)
        self.check("我们下午两点不对三点开会", "我们下午三点开会。", None)

    def test_a_lead_in_may_go_with_the_marker(self):
        self.check("Let's meet at 2:30, no wait, make it 3:30", "Let's meet at 3:30.", None)
        self.check("deadline是周五不对是下周一", "deadline 是下周一。", None)
        self.check("send the report to Alice sorry I mean to Bob before Friday", "Send the report to Alice before Friday.",
                   "correction")                                   # "to" is no lead-in: Bob must stay

    def test_a_custom_word_said_only_in_the_taken_back_words_may_go(self):
        g = polish.guard("用 Claude 写，不对，用 Codex 写这个脚本", "用 Codex 写这个脚本。", terms=["Claude", "Codex"])
        self.assertTrue(g["pass"], g)
        g = polish.guard("Claude 先写，不对，用 Codex 写，Claude 来审", "用 Codex 写。", terms=["Claude", "Codex"])
        self.assertEqual(g["reason"], "term")                      # said again after the correction: it stays

    def test_wrong_side_of_a_correction(self):
        self.check("把这个文件发给小王哦不是发给小李", "把这个文件发给小王。", "correction")
        self.check("send the report to Alice sorry I mean to Bob before Friday", "Send the report to Alice before Friday.",
                   "correction")

    def test_additions_are_caught(self):
        self.check("按钮太浅了", "按钮太浅了，建议把颜色加深到品牌主色，并且增加悬停效果和点击动画，提升整体可用性。", "grew")
        self.check("the build is broken", "The build pipeline appears broken; investigate the failing CI runner.", "novel")

    def test_empty(self):
        self.check("嗯这个按钮有问题", "", "empty")

    def test_plural_is_not_translation(self):
        self.check("Figma里面那个design token还没同步", "Figma 里面那个 design tokens 还没同步。", None)


OVERDELETE = ROOT / "tests" / "fixtures" / "polish_overdelete.jsonl"


class Repair(unittest.TestCase):
    """Polish dropping a meaningful phrase (a condition, an alternative, a number said its own way): the repair puts
    the transcript's words back instead of losing the meaning (docs/design/dictation.md §Repair)."""

    def overdelete(self) -> list[dict]:
        return [json.loads(ln) for ln in OVERDELETE.read_text(encoding="utf-8").splitlines() if ln.strip()]

    def test_good_outputs_are_left_alone(self):
        """No reference output of either eval set gets anything put back (fillers, stutters, restarts, corrections
        applied, numbers in digits, moved words, paragraphs are all fine)."""
        for c in cases() + self.overdelete():
            fixed, spans = polish.repair(c["input"], c["reference"])
            self.assertEqual(spans, [], c["id"])
            self.assertEqual(fixed, c["reference"], c["id"])

    def test_dropped_phrases_come_back(self):
        for c in self.overdelete():
            fixed, _spans = polish.repair(c["input"], c["bad"])
            for k in c["keep"]:
                self.assertIn(polish._norm(k), polish._norm(fixed), f"{c['id']}: {fixed}")
            self.assertTrue(polish.guard(c["input"], fixed)["pass"], f"{c['id']}: {fixed}")

    def test_a_dropped_condition_goes_back_where_it_was_said(self):
        raw = "那我估计它会比，呃，句子短的时候比 Siri 要快，句子长的时候就，嗯，比 Siri 要慢一些。"
        fixed, spans = polish.repair(raw, "那我估计它会比 Siri 要快，句子长的时候比 Siri 要慢一些。")
        self.assertEqual(fixed, "那我估计它会比，句子短的时候比 Siri 要快，句子长的时候比 Siri 要慢一些。")
        self.assertEqual(spans, ["比，句子短的时候"])

    def test_numbers_stay_as_said(self):
        fixed, spans = polish.repair("预算大概是一点二万，或者再多一点", "预算大概是一万二，或者再多一点。")
        self.assertEqual(fixed, "预算大概是一点二万，或者再多一点。")
        self.assertEqual(spans, ["一万二→一点二万"])
        for said, wrote, same in [("三十", "30", True), ("十七点二", "17.2", True), ("五零零", "500", True),
                                  ("二点三点一", "2.3.1", True), ("三万两千", "32000", True), ("一点二万", "12000", True),
                                  ("一点二万", "一万二", False), ("两百五", "250", False), ("三千五百", "三千五", False)]:
            self.assertEqual(polish.same_number(said, wrote), same, (said, wrote))

    def test_corrections_and_fillers_may_go(self):
        for raw, out in [("我们下午两点不对三点开会", "我们下午三点开会。"),
                         ("把文件发给小王哦不是发给小李", "把文件发给小李。"),
                         ("报价是两万，不对，是两万五，含税的。", "报价是两万五，含税的。"),
                         ("嗯嗯那个我我我想说的是这个先放一放", "我想说的是，这个先放一放。"),
                         ("这个按钮的，这个按钮的颜色要再深一点", "这个按钮的颜色要再深一点。"),
                         ("把这个，不对，这两个拿到那一边去", "把这两个拿到那一边去。"),
                         ("先放到左边，不对，放到右边那个盒子里", "放到右边那个盒子里。"),
                         ("send it to Tom no wait to Jerry", "Send it to Jerry."),
                         # a cancelled span with its lead-in: never put back (the Dictation Lab's find)
                         ("Let's meet at 2:30, no wait, make it 3:30", "Let's meet at 3:30."),
                         ("let's meet at two thirty no wait make it three thirty", "Let's meet at three thirty."),
                         ("把这个文件，不对，这两个文件发给我", "把这两个文件发给我。"),
                         ("用 Claude 写，不对，用 Codex 写这个脚本", "用 Codex 写这个脚本。")]:
            self.assertEqual(polish.repair(raw, out)[1], [], raw)
            self.assertTrue(polish.guard(raw, polish.repair(raw, out)[0])["pass"], raw)
        # "不是" that isn't a correction: what follows it was dropped too, so it goes back
        fixed, spans = polish.repair("这个接口不是每次都慢，只有在凌晨备份的时候才会慢。", "这个接口只有在备份的时候才会慢。")
        self.assertIn("不是每次都慢", fixed)
        self.assertIn("凌晨", fixed)

    def test_copying_the_context_is_caught(self):
        """A streamed piece gets the polished text so far as context; continuing it isn't polishing."""
        from dictation_vocab import allowed_units
        raw = "智能客服项目的数据接口还没联调，明天上午再看。"
        ctx = "数据看板项目下个月要上线，前端还差两个页面。"
        allowed = allowed_units([], ctx)
        g = polish.guard(raw, raw + "要上线，前端还差两个页面。", allowed, [], ctx)
        self.assertEqual(g["reason"], "copied")
        self.assertTrue(polish.guard(raw, "智能客服项目的数据接口还没联调，明天上午再看。", allowed, [], ctx)["pass"])
        # the same words said again (in the dictation itself) aren't a copy
        self.assertTrue(polish.guard("前端还差两个页面我们再看", "前端还差两个页面，我们再看。", allowed, [], ctx)["pass"])

    def test_too_much_put_back_is_a_bad_polish(self):
        raw = "嗯如果明天下雨的话我们就改成线上开会不下雨就还是去公司然后周五之前把方案发给我"
        fixed, spans = polish.repair(raw, "周五前发方案。")
        self.assertGreater(polish.repaired_share(raw, spans), polish.REPAIR_MAX)

    def test_adaptive_idle(self):
        from _common import adaptive_idle
        now = 10_000.0
        self.assertEqual(adaptive_idle(180, [], "pro", now=now), 180)
        self.assertEqual(adaptive_idle(180, [now - 60] * 3, "pro", now=now), 360)
        self.assertEqual(adaptive_idle(180, [now - 60] * 8, "standard", now=now), 900)
        self.assertEqual(adaptive_idle(600, [now - 60] * 9, "pro", now=now), 1800)        # capped
        self.assertEqual(adaptive_idle(180, [now - 4000] * 9, "pro", now=now), 180)       # long ago doesn't count
        self.assertEqual(adaptive_idle(180, [now - 60] * 9, "light", now=now), 180)       # small Macs: memory first


class CleanOutput(unittest.TestCase):
    def test_strips_wrappers(self):
        c = polish.clean_output
        self.assertEqual(c("<think>\nhmm\n</think>\n\n你好。"), "你好。")
        self.assertEqual(c("<think></think>Hello."), "Hello.")
        self.assertEqual(c("输出：你好。"), "你好。")
        self.assertEqual(c("Output: Hello."), "Hello.")
        self.assertEqual(c("“你好。”"), "你好。")
        self.assertEqual(c("```\nHello.\n```"), "Hello.")
        self.assertEqual(c('She said "hi" to me.'), 'She said "hi" to me.')       # inner quotes stay

    def test_units(self):
        self.assertEqual(polish.units("我们的API v2"), ["我", "们", "的", "api", "v", "2"])
        self.assertEqual(polish.units("They're here."), ["they're", "here"])
        self.assertNotIn("嗯", polish.units(polish.strip_fillers("嗯嗯那个我我我觉得")))
        self.assertEqual(polish.units(polish.strip_fillers("the the button")), ["the", "button"])


class Score(unittest.TestCase):
    def test_scores_a_case(self):
        c = {"input": "嗯我觉得按钮太浅了", "reference": "我觉得按钮太浅了。", "keep": ["我觉得", "按钮"], "drop": ["嗯"]}
        s = polish.score(c, "我觉得按钮太浅了。")
        self.assertTrue(s["kept"] and s["dropped_ok"])
        self.assertEqual(s["sim"], 1.0)
        s = polish.score(c, "嗯按钮太浅了")
        self.assertEqual(s["missing"], ["我觉得"])
        self.assertEqual(s["leaked"], ["嗯"])
        u = {"input": "Run npm install.", "reference": "Run npm install.", "untouched": True}
        self.assertTrue(polish.score(u, "Run npm install")["untouched_ok"])       # punctuation doesn't count
        self.assertFalse(polish.score(u, "Run `npm i`.")["untouched_ok"])


class Registry(unittest.TestCase):
    def test_models(self):
        reg = polish.registry()
        ids = [m["id"] for m in reg["models"]]
        self.assertEqual(len(ids), len(set(ids)))
        for m in reg["models"]:
            self.assertIn(m["family"], ("qwen", "gemma"))                         # no Llama, by request
            self.assertNotIn("llama", m["repo"].lower())
            self.assertTrue(m["repo"].startswith("mlx-community/"), m)
            self.assertLess(m["size_mb"], 5200, m)
        for tier in ("pro", "standard", "light", "minimal"):
            self.assertIn(reg["defaults"][tier], ids)
        for m in reg["models"]:                                              # measured on the reference Mac
            self.assertTrue(m["ram_mb"] > 0 and m["warm_ms"] > 0 and 0 <= m["fallback"] <= 1, m["id"])
        # the default for each tier fits that tier's polish memory cap (25 % of 8 / 16 / 32 GB; minimal ≈ 8 GB too)
        cap = {"pro": 8192, "standard": 4096, "light": 2200, "minimal": 2048}
        for tier, mid in reg["defaults"].items():
            self.assertLessEqual(polish.entry(mid)["ram_mb"], cap[tier], tier)

    def test_lighter_tiers_get_smaller_models(self):
        reg = polish.registry()
        size = {m["id"]: m["size_mb"] for m in reg["models"]}
        d = reg["defaults"]
        self.assertLessEqual(size[d["light"]], size[d["standard"]])
        self.assertLessEqual(size[d["minimal"]], size[d["light"]])

    def test_prompt_disables_nothing_but_keeps_examples_out_of_the_eval(self):
        inputs = {c["input"] for c in cases()}
        for q, _a in polish.EXAMPLES:
            self.assertNotIn(q, inputs)
        m = polish.messages("你好")
        self.assertEqual(m[0]["role"], "system")
        self.assertEqual(m[-1], {"role": "user", "content": "你好"})

    def test_prompt_says_a_pause_is_not_a_sentence_end(self):
        # a streamed dictation is polished in windows cut at pauses (docs/design/dictation.md §Punctuation at seams)
        self.assertIn("fix punctuation across what are just pauses in speech; don't end a sentence at a pause unless "
                      "the sentence is complete", polish.SYSTEM)


class CLI(unittest.TestCase):
    def run_cli(self, *args, home: str, stdin: str | None = None) -> tuple[int, dict]:
        env = {**os.environ, "BLURT_HOME": home, "BLURT_POLISH_REEXEC": "1", "HF_HUB_CACHE": os.path.join(home, "hf")}
        p = subprocess.run([sys.executable, str(SCRIPTS / "polish.py"), *args], capture_output=True, text=True,
                           encoding="utf-8", env=env, input=stdin, timeout=120)
        return p.returncode, json.loads(p.stdout.strip().splitlines()[-1])

    def test_models_guard_and_missing_model(self):
        with tempfile.TemporaryDirectory() as home:
            code, o = self.run_cli("models", home=home)
            self.assertEqual(code, 0)
            self.assertTrue(o["ok"])
            self.assertIsNone(o["selected"])                              # nothing installed in a fresh home
            self.assertEqual(o["polish"], "light")
            self.assertEqual(o["timeout_ms"], 3000)
            self.assertTrue(all(not m["installed"] for m in o["models"]))
            code, o = self.run_cli("guard", "嗯我觉得按钮太浅了", "我觉得按钮太浅了。", home=home)
            self.assertTrue(o["pass"])
            code, o = self.run_cli("guard", "what's the capital of France", "Paris.", home=home)
            self.assertEqual(o["reason"], "answered")
            code, o = self.run_cli("run", "--no-server", "--stdin", home=home, stdin="嗯那个按钮太浅了")
            self.assertEqual(code, 1)
            self.assertEqual(o["code"], "model_missing")
            code, o = self.run_cli("run", "--no-server", "--text", "好的", home=home)      # too short to polish
            self.assertEqual((code, o["reason"], o["text"]), (0, "short", "好的"))

    def test_installed_copy_is_found(self):
        with tempfile.TemporaryDirectory() as home:
            d = Path(home) / "models" / "polish" / "Qwen3.5-0.8B-MLX-4bit"
            d.mkdir(parents=True)
            (d / "config.json").write_text("{}")
            (d / "model.safetensors").write_bytes(b"x")
            (Path(home) / "config.json").write_text(json.dumps({"record": {"dictation": {"polish_model": "qwen3.5-0.8b",
                                                                                          "polish_timeout_ms": 1500}}}))
            code, o = self.run_cli("models", home=home)
            self.assertEqual(o["selected"], "qwen3.5-0.8b")
            self.assertEqual(o["timeout_ms"], 1500)
            self.assertTrue(next(m for m in o["models"] if m["id"] == "qwen3.5-0.8b")["installed"])
            (d / "model.safetensors.part").write_bytes(b"x")              # a download in progress isn't installed
            code, o = self.run_cli("models", home=home)
            self.assertIsNone(o["selected"])


import dictation_corrections as corrections  # noqa: E402

# (what the speech model wrote, what the corrections pass makes of it): the user's case first, then the shapes the
# pass resolves — the speech model's own punctuation as on the `say` clips (「把这个不对，…」, "No, wait,", 「。哦，不，」)
RESOLVED = [
    ("把这个，不对，这两个拿到那一边去", "把这两个拿到那一边去"),
    ("把这个不对，这两个拿到那一边去。", "把这两个拿到那一边去。"),
    ("先放到左边，不对，放到右边", "先放到右边"),
    ("先放到左边，不对，放到右边那个盒子里。", "先放到右边那个盒子里。"),
    ("先放到左边，不对，右边那个盒子里", "先放到右边那个盒子里"),
    ("Let's meet at 2:30, no wait, 3:30.", "Let's meet at 3:30."),
    ("Let's meet at 2:30, no wait, make it 3:30, in the small room.", "Let's meet at 3:30, in the small room."),
    ("Let's meet at two thirty. No, wait, three thirty.", "Let's meet at three thirty."),
    ("2:30, no wait, 3:30", "3:30"),
    ("周三，不对，周四", "周四"),
    ("我们周三，不对，周四开会", "我们周四开会"),
    ("我们周三不对，周四开会。", "我们周四开会。"),
    ("我们周三开会，不对，周四", "我们周四开会"),
    ("我们明天去北京，不对，是后天", "我们后天去北京"),
    ("我们下午两点不对三点开会", "我们下午三点开会"),
    ("我们下午两点不对，三点开会。", "我们下午三点开会。"),
    ("发给张三，哦不，发给李四", "发给李四"),
    ("这个文件发给张三。哦，不，发给李四。", "这个文件发给李四。"),
    ("把文件发给小王哦不是发给小李", "把文件发给小李"),
    ("把这个文件发给小王哦不是发给小李让他明天之前看完", "把这个文件发给小李让他明天之前看完"),
    ("帮我订一张去上海的票，不对，去杭州的", "帮我订一张去杭州的票"),
    ("帮我订一张去上海的票。不对，去杭州的。", "帮我订一张去杭州的票。"),
    ("把这个文件，不对，这两个文件都拷到桌面上。", "把这两个文件都拷到桌面上。"),
    ("把这个文件，不对，这两个", "把这两个文件"),
    ("两万，不对，两万五", "两万五"),
    ("报价是两万，不对，是两万五，含税的。", "报价是两万五，含税的。"),
    ("预算大概是五万我是说八万块左右", "预算大概是八万块左右"),
    ("deadline是周五哦不对是下周一", "deadline是下周一"),
    ("用 Claude 写，不对，用 Codex 写这个脚本", "用 Codex 写这个脚本"),
    ("用 Claude 写不对，用 Codex 写这个脚本。", "用 Codex 写这个脚本。"),
    ("颜色改成蓝色，算了，还是改成绿色吧", "颜色改成绿色吧"),
    ("资料我晚上发群里，不对下午就发。", "资料我下午就发群里。"),
    ("我想吃苹果和香蕉，不对，我想吃梨", "我想吃梨"),
    ("send it to Tom no wait to Jerry", "send it to Jerry"),
    ("Send it to Tom. Sorry, to Jerry before lunch.", "Send it to Jerry before lunch."),
    ("let's meet on Tuesday no wait Wednesday at three", "let's meet on Wednesday at three"),
    ("We need two, I mean, three people.", "We need three people."),
    ("ok so the new logo goes on the left side no wait the right side of the header",
     "ok so the new logo goes on the right side of the header"),
    ("Version 3.5, no wait, 3.6 is out.", "Version 3.6 is out."),
]
# 不对 / 不是 / 算了 / sorry … as content, or a correction too loose to resolve without the model: left as said
UNCHANGED = [
    "这个不对", "这个不对。", "这个不对称", "感觉有点不对劲", "我不是故意的", "我不是故意的，你别生气了。", "是不是", "你是不是忘了带钥匙？",
    "答案是三不是四", "答案是三不对，是四", "这个方案不对，这个方案要改", "这个方案不对，我们得重新想一下。",
    "我觉得这个不对，那个对", "我觉得这个不对，那个是对的。", "这个不对，那个对", "他的说法不对，他说的是周三",
    "这个颜色不对，这个要改成红色", "你这样写不对，你应该这样写", "这么做不对，那么做才对", "你文档里写的周三不对，应该是周四",
    "你文档里写的周三不对，周四才对", "我不想去了，算了，你们去吧。", "哦，不，我没事。", "No, wait, I think it is fine.",
    "It's fine, actually, it's great.", "I mean it.", "Sorry, I'm late.", "I'd rather stay home.", "不是我说你，你这样不行",
    "应该是这样的", "他明天来，应该是下午", "他说错了", "我错了", "这道题错了，要重做", "把model换成GPT不对换成Claude Opus",
    "我们周三开会讨论这个方案不对周四周四下午三点", "",
]


class Corrections(unittest.TestCase):
    """The deterministic self-correction pass before polish (dictation_corrections.py): the plain shapes resolved,
    never content, nothing outside the cancelled span lost; the guard and the repair accept what it did."""

    def test_resolved(self):
        for raw, want in RESOLVED:
            got, fixes = corrections.resolve(raw)
            self.assertEqual(got, want, raw)
            self.assertTrue(fixes and fixes[0]["cancelled"], raw)

    def test_content_is_left_alone(self):
        for raw in UNCHANGED:
            self.assertEqual(corrections.resolve(raw), (raw, []), raw)

    def test_only_the_cancelled_span_and_the_marker_go(self):
        """Nothing new comes in, and what goes is only the cancelled span, the marker and a lead-in (counted unit by
        unit: words may move — 周三开会，不对，周四 → 周四开会 — but not vanish)."""
        from collections import Counter
        for raw, _want in RESOLVED:
            got, fixes = corrections.resolve(raw)
            r, o = Counter(polish.units(raw)), Counter(polish.units(got))
            self.assertEqual(o - r, Counter(), f"{raw} → {got}: new words")
            may = Counter()
            for f in fixes:
                may += Counter(polish.units(f["cancelled"])) + Counter(polish.units(f["marker"]))
            may += Counter(["是", "make", "it", "to", "还", "the", "at", "on", "in"])     # lead-ins
            self.assertEqual((r - o) - may, Counter(), f"{raw} → {got}: lost more than the cancelled words")
            self.assertLessEqual(sum(len(polish.units(f["cancelled"])) for f in fixes), 8 * len(fixes), raw)

    def test_guard_and_repair_accept_a_resolved_correction(self):
        for raw, want in RESOLVED:
            out = want.rstrip("。.") + ("。" if polish._is_cjk(want.rstrip("。.")[-1:] or "a") else ".")
            g = polish.guard(raw, out)
            self.assertTrue(g["pass"], f"{raw} → {out}: {g}")
            fixed, spans = polish.repair(corrections.resolve(raw)[0], out)
            self.assertEqual(spans, [], raw)
            # the stitch guard (the joined pieces against the joined transcript) too
            self.assertTrue(polish.stitch_guard(raw, out, None, [], None)["pass"], raw)

    def test_fixtures_without_a_correction_are_untouched(self):
        for c in cases() + [json.loads(ln) for ln in OVERDELETE.read_text(encoding="utf-8").splitlines() if ln.strip()]:
            if "correction" not in c.get("tags", []):
                self.assertEqual(corrections.resolve(c["input"])[1], [], c["id"])
        false = ROOT / "tests" / "fixtures" / "dictation_false_corrections.jsonl"
        for ln in false.read_text(encoding="utf-8").splitlines():
            if ln.strip():
                t = json.loads(ln).get("text") or ""
                self.assertEqual(corrections.resolve(t)[1], [], t)

    def test_fast(self):
        import time
        long = "，".join(r for r, _ in RESOLVED + [(u, u) for u in UNCHANGED]) * 3
        t0 = time.process_time()
        corrections.resolve(long)
        self.assertLess(time.process_time() - t0, 0.25)
        t0 = time.process_time()
        for raw, _ in RESOLVED:
            corrections.resolve(raw)
        self.assertLess((time.process_time() - t0) / len(RESOLVED), 0.002)


def test_no_space_between_two_cjk_characters():
    assert polish.clean_output("二 是改一下合同里的付款条款，三 是约设计师。") == "二是改一下合同里的付款条款，三是约设计师。"
    assert polish.clean_output("用 Claude Code 写一个 PR") == "用 Claude Code 写一个 PR"


class FakeEngine(polish.Engine):
    """Engine.polish with a scripted model: what it was asked, and what it answers."""

    def __init__(self, reply):
        super().__init__()
        self.reply, self.asked = reply, []

    def load(self, model_id=None):
        self.model, self.model_id = object(), model_id or "fake"
        return self

    def generate(self, text, deadline, terms=None, context=None):
        self.asked.append((text, polish.messages(text, terms, context)))
        return (self.reply(text) if callable(self.reply) else self.reply), False


class EngineCorrections(unittest.TestCase):
    def test_the_model_gets_the_corrected_text(self):
        e = FakeEngine(lambda t: t + "。")
        r = e.polish("把这个，不对，这两个拿到那一边去", "fake", 3, [], None)
        self.assertEqual(e.asked[0][0], "把这两个拿到那一边去")
        self.assertEqual((r["text"], r["fell_back"]), ("把这两个拿到那一边去。", False))
        self.assertEqual(r["corrections"][0]["cancelled"], "这个")

    def test_a_fall_back_types_the_corrected_text(self):
        """The bug: the model kept 「这个」, the guard refused it, and 「把这个，不对，这两个…」 was typed."""
        e = FakeEngine("好的，这是整理后的文字：把这个拿到那一边去。")      # refused (chatty)
        r = e.polish("把这个，不对，这两个拿到那一边去", "fake", 3, [], None)
        self.assertTrue(r["fell_back"])
        self.assertEqual(r["text"], "把这两个拿到那一边去")
        self.assertNotIn("不对", r["text"])

    def test_an_unresolved_marker_gets_the_correction_examples(self):
        e = FakeEngine(lambda t: t)
        e.polish("把model换成GPT不对换成Claude Opus", "fake", 3, [], None)
        e.polish("帮我把这个 PR 合并一下", "fake", 3, [], None)
        with_ex = [m["content"] for m in e.asked[0][1]]
        without = [m["content"] for m in e.asked[1][1]]
        self.assertIn(polish.CORRECTION_EXAMPLES[0][0], with_ex)
        self.assertNotIn(polish.CORRECTION_EXAMPLES[0][0], without)
        # the cached prefix (system + examples) is the same either way
        n = 1 + 2 * len(polish.EXAMPLES)
        self.assertEqual(with_ex[:n], without[:n])


class Echo(unittest.TestCase):
    """A sliding window's polish repeated the text so far in front of the new piece (the guard's `copied`, the
    transcript typed with no marks at the pauses): the repetition goes before the guard."""

    def test_strip(self):
        before = "明天要做三件事，第一，把测试全部跑完，"
        self.assertEqual(polish.strip_echo("明天要做三件事，第一，把测试全部跑完，第二，把文档更新一下。", before, "第二把文档更新一下"),
                         ("第二，把文档更新一下。", 16))
        # near-exact: re-punctuated
        self.assertEqual(polish.strip_echo("明天要做三件事：第一，把测试全部跑完；第二，把文档更新一下。", before, "第二把文档更新一下")[0],
                         "第二，把文档更新一下。")
        self.assertEqual(polish.strip_echo("For the release, we need three things. First, run all the tests. Second, update the docs.",
                                           "For the release, we need three things. First, run all the tests,",
                                           "second update the docs")[0], "Second, update the docs.")
        # only the tail it repeated: an echo of the context ends where the context ends
        self.assertEqual(polish.strip_echo("明天要做三件事，第一把测试全部跑完。", "明天要做三件事，", "第一把测试全部跑完"),
                         ("第一把测试全部跑完。", 7))

    def test_words_said_again_stay(self):
        # the speaker did say them again
        self.assertEqual(polish.strip_echo("第一，把测试全部跑完。", "第一，", "第一把测试全部跑完"), ("第一，把测试全部跑完。", 0))
        self.assertEqual(polish.strip_echo("我们明天去公园。", "我们明天", "我们明天去公园"), ("我们明天去公园。", 0))
        self.assertEqual(polish.strip_echo("第二，把文档更新一下。", "", "第二把文档更新一下"), ("第二，把文档更新一下。", 0))
        # a single unit is never an echo
        self.assertEqual(polish.strip_echo("好，走吧。", "我说好", "好走吧"), ("好，走吧。", 0))

    def test_engine_strips_it_before_the_guard(self):
        e = FakeEngine("明天要做三件事，第一，把测试全部跑完，第二，把文档更新一下。")
        r = e.polish("第二把文档更新一下", "fake", 3, [], {"dictated": "明天要做三件事，第一，把测试全部跑完，"})
        self.assertEqual((r["text"], r["fell_back"], r["echo"]), ("第二，把文档更新一下。", False, 16))

    def test_the_text_so_far_is_the_turn_before(self):
        m = polish.messages("第二把文档更新一下", None, {"dictated": "明天要做三件事，第一，把测试全部跑完，", "title": "Notes"})
        self.assertEqual([x["role"] for x in m[-3:]], ["assistant", "assistant", "user"][:0] + ["user", "assistant", "user"])
        self.assertEqual(m[-3]["content"], "明天要做三件事，第一，把测试全部跑完，")
        self.assertEqual(m[-2]["content"], "明天要做三件事，第一，把测试全部跑完，")
        self.assertEqual(m[-1]["content"], "第二把文档更新一下")       # a title alone is no "Near the cursor" line
        # only its end, from a clause start
        long = "，".join(f"第{i}件事做完了" for i in range(40))
        tail = polish.dictated_tail(long)
        self.assertLessEqual(len(tail), polish.DICTATED_CHARS)
        self.assertTrue(long.endswith(tail) and tail.startswith("第"))
        # the guard still accepts its words and refuses a copy of them (`copied`)
        self.assertIn("跑完", polish.context_all({"dictated": "把测试全部跑完"}))

    def test_stitch_guard_types_a_fall_back_with_its_corrections_resolved(self):
        g = polish.stitch_guard("把这个，不对，这两个拿到那一边去", "当然可以！", None, [], None, "把这个，不对，这两个拿到那一边去")
        self.assertFalse(g["pass"])
        self.assertEqual(g["fallback_text"], "把这两个拿到那一边去")


if __name__ == "__main__":
    unittest.main()
