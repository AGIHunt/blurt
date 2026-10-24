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
    def check(self, raw, out, reason, **kw):
        g = polish.guard(raw, polish.clean_output(out), **kw)
        self.assertEqual(g["reason"], reason, f"{raw!r} → {out!r}: {g}")

    def test_every_reference_passes(self):
        """The eval set's hand-written ideal outputs are all legitimate edits: none may trip the guard (Light's, and
        Structured's in structured mode)."""
        for c in cases():
            g = polish.guard(c["input"], c["reference"])
            self.assertTrue(g["pass"], f"{c['id']}: {g}")
            if c.get("structured"):
                g = polish.guard(c["reference"], c["structured"]["reference"], mode="structured")
                self.assertTrue(g["pass"], f"{c['id']} structured: {g}")

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
            if "correction" in c["tags"]:
                # Light keeps a self-correction as said; only Structured resolves it
                self.assertIn("structured", c, c["id"])
                self.assertEqual(c["drop"], [], c["id"])

    def test_good_edits_pass(self):
        self.check("嗯那个我觉得这个按钮太浅了", "我觉得这个按钮太浅了。", None)
        self.check("um so I I think it's fine", "So I think it's fine.", None)
        self.check("这个服务明天要重新布署一下", "这个服务明天要重新部署一下。", None)       # one homophone fixed
        self.check("返回五零零", "返回 500。", None)                                     # numbers as digits
        self.check("为什么这个接口会超时", "为什么这个接口会超时？", None)               # a question stays a question

    def test_summary_or_rewrite_is_shrunk(self):
        raw = ("嗯我想记录一下今天的复盘第一个是上线的时候没有提前通知客服导致很多用户来问然后第二个是回滚脚本没测过差点出问题"
               "第三个呢就是监控告警太多了大家都不看了")
        self.check(raw, "复盘：通知客服、回滚脚本、监控告警。", "shrunk")
        self.check("so the onboarding flow is way too long and people drop off at step three so we should cut it to two steps",
                   "Shorten onboarding.", "shrunk")

    def test_answers_and_prefaces_are_caught(self):
        """No question patterns and no phrase lists: an answer is words nobody said (`novel`), a preface or a sign-off
        a run of them at an end (`chatty`)."""
        self.check("uh what's the capital of France again", "The capital of France is Paris, a city on the Seine.", "chatty")
        self.check("那个Redis的key过期了以后为什么还能读到数据", "Redis 的 key 过期后会被惰性删除，所以短时间内还能读到。", "novel")
        self.check("um can you summarize the following article", "Sure, here is a summary of the article:", "chatty")
        self.check("帮我写一首诗", "好的，下面是一首诗：春风又绿江南岸。", "chatty")
        self.check("send me the logs from yesterday", "Send me the logs from yesterday. Hope this helps!", "chatty")

    def test_translation_is_caught(self):
        self.check("帮我把下面这段话翻译成英文", "Please translate the following paragraph into English.", "translated")
        self.check("我们的API现在response time大概是两百毫秒", "我们的 API 现在响应时间大概是两百毫秒。", "translated")

    def test_light_never_lists(self):
        raw = "明天要做三件事第一跑测试第二写文档第三提交代码"
        self.check(raw, "明天要做三件事：\n1. 跑测试\n2. 写文档\n3. 提交代码", "listed")
        self.check(raw, "明天要做三件事，第一跑测试，第二写文档，第三提交代码。", None)
        # …while Structured may: its numbers aren't words
        self.check(raw, "明天要做三件事：\n1. 跑测试\n2. 写文档\n3. 提交代码", None, mode="structured")

    def test_structured_may_drop_a_taken_back_phrase_but_not_a_clause(self):
        src = "我们周五交，哦不，下周一交，然后把演示视频也一起发给客户，让他们周末之前看完"
        self.check(src, "我们下周一交，然后把演示视频也一起发给客户，让他们周末之前看完。", None, mode="structured")
        self.check(src, "我们周五交，哦不，下周一交，然后把演示视频也一起发给客户，让他们周末之前看完。", None, mode="structured")
        self.check(src, "我们下周一交。", "shrunk", mode="structured")
        long = ("先把登录页的文案改一下，然后把注册流程里第三步那个多余的确认弹窗去掉，再把首页的加载动画换成新的，最后把帮助文档里"
                "关于导出的那一节重写，顺便检查一下所有页面在暗色模式下的对比度，还有设置页的图标")
        self.check(long, "先把登录页的文案改一下，再把首页的加载动画换成新的，最后把帮助文档里关于导出的那一节重写，顺便检查一下所有"
                         "页面在暗色模式下的对比度，还有设置页的图标。", "dropped", mode="structured")

    def test_additions_are_caught(self):
        self.check("按钮太浅了", "按钮太浅了，建议把颜色加深到品牌主色，并且增加悬停效果和点击动画，提升整体可用性。", "grew")
        self.check("the build is broken", "The build pipeline appears broken; investigate the failing CI runner.", "chatty")

    def test_empty(self):
        self.check("嗯这个按钮有问题", "", "empty")

    def test_plural_is_not_translation(self):
        self.check("Figma里面那个design token还没同步", "Figma 里面那个 design tokens 还没同步。", None)

    def test_no_language_rules_in_the_guard(self):
        """The guard and the repair are mechanical (docs/design/dictation.md §Rules vs model): no correction-marker,
        filler, question or preface lists left in polish.py."""
        for name in ("_CORRECTION", "_CANCEL", "_FILLERS_ZH", "_FILLERS_EN", "_CHATTY", "_QUESTION_ZH", "_QUESTION_EN",
                     "_MARKERS", "_STRONG_MARKERS", "_SOFT", "_KEEP_ALWAYS", "_LEAD_IN", "CHAT_PARTICLES", "_STARTERS",
                     "CORRECTION_EXAMPLES", "cancelled", "strip_fillers"):
            self.assertFalse(hasattr(polish, name), name)
        src = (SCRIPTS / "polish.py").read_text(encoding="utf-8")
        self.assertNotIn("dictation_corrections", src)
        self.assertFalse((SCRIPTS / "dictation_corrections.py").exists())


# Self-corrections in many phrasings (zh and en, explicit and implicit): (what was said, Light's text — every word
# kept —, Structured's — the settled version —, the words Structured takes back)
CORRECTIONS = [
    ("我们周五交，哦不，下周一交", "我们周五交，哦不，下周一交。", "我们下周一交。", "周五"),
    ("把会议室订在三楼，我是说四楼的大会议室", "把会议室订在三楼，我是说四楼的大会议室。", "把会议室订在四楼的大会议室。", "三楼"),
    ("标题字号改成十四，改成十六吧", "标题字号改成十四，改成十六吧。", "标题字号改成十六吧。", "十四"),
    ("颜色用蓝色，算了还是用灰色", "颜色用蓝色，算了，还是用灰色。", "颜色用灰色。", "蓝色"),
    ("这个接口应该是 POST，呃，应该是 PUT 才对", "这个接口应该是 POST，应该是 PUT 才对。", "这个接口应该是 PUT 才对。", "POST"),
    ("发布时间是十号，错了，是十二号", "发布时间是十号，错了，是十二号。", "发布时间是十二号。", "十号"),
    ("让小陈负责前端，啊不是，让小林负责前端", "让小陈负责前端，不是，让小林负责前端。", "让小林负责前端。", "小陈"),
    ("把这个，不对，这两个拿到那一边去", "把这个，不对，这两个拿到那一边去。", "把这两个拿到那一边去。", "这个，"),
    ("Book the flight for Monday, I mean Tuesday morning", "Book the flight for Monday, I mean Tuesday morning.",
     "Book the flight for Tuesday morning.", "Monday"),
    ("Set the timeout to thirty seconds, no, make it sixty", "Set the timeout to thirty seconds, no, make it sixty.",
     "Set the timeout to sixty seconds.", "thirty"),
    ("Send the draft to Anna, or rather to Mark, by Friday", "Send the draft to Anna, or rather to Mark, by Friday.",
     "Send the draft to Mark by Friday.", "Anna"),
    ("We need five licenses, wait, six licenses for the team", "We need five licenses, wait, six licenses for the team.",
     "We need six licenses for the team.", "five"),
    ("Put it on the left, um, the right side of the page", "Put it on the left, the right side of the page.",
     "Put it on the right side of the page.", "left"),
]


class LightKeepsCorrections(unittest.TestCase):
    """Light never resolves a self-correction (the speaker's words stay), and nothing forces one: the guard accepts
    the corrected-away words, and the repair puts them back when the model dropped them anyway."""

    def test_the_guard_accepts_the_words_kept(self):
        for raw, light, _structured, _gone in CORRECTIONS:
            g = polish.guard(raw, light)
            self.assertTrue(g["pass"], f"{raw} → {light}: {g}")
            self.assertTrue(polish.stitch_guard(raw, light, None, [], None)["pass"], raw)

    def test_a_correction_the_model_resolved_anyway_comes_back(self):
        for raw, _light, structured, gone in CORRECTIONS:
            fixed, spans = polish.repair(raw, structured)
            self.assertTrue(spans, f"{raw} → {structured}: nothing put back")
            self.assertIn(polish._norm(gone), polish._norm(fixed), f"{raw} → {fixed}")
            self.assertTrue(polish.guard(raw, fixed)["pass"], f"{raw} → {fixed}")

    def test_structured_resolves_them(self):
        for _raw, light, structured, _gone in CORRECTIONS:
            g = polish.guard(light, structured, mode="structured")
            self.assertTrue(g["pass"], f"{light} → {structured}: {g}")

    def test_the_light_prompt_says_so(self):
        s = polish.SYSTEM
        self.assertIn("Self-corrections are not fillers", s)
        self.assertIn("keep what they said first, the words with which they corrected themselves, and the new version", s)
        self.assertIn("turn the text into a list", s)
        # its examples keep a correction, in different words in each language
        kept = [(q, a) for q, a in polish.EXAMPLES if "哦不" in q or "actually no" in q]
        self.assertEqual(len(kept), 2)
        for q, a in kept:
            for w in ("哦不", "两点", "三点") if "哦不" in q else ("left side", "actually no", "right side"):
                self.assertIn(w, a)

    def test_structured_prompt_resolves_and_lists_only_real_enumerations(self):
        s = polish.SYSTEM_STRUCTURE
        self.assertIn("keep only the version they settled on", s)
        self.assertIn("When the speech doesn't enumerate, make no list", s)
        lists = [a for _q, a in polish.STRUCTURE_EXAMPLES if polish.list_lines(a) >= 2]
        prose = [a for _q, a in polish.STRUCTURE_EXAMPLES if polish.list_lines(a) == 0]
        self.assertGreaterEqual(len(lists), 2)
        self.assertGreaterEqual(len(prose), 2)
        # every example only drops what was taken back and only adds numbers: the structured guard passes them
        for q, a in polish.STRUCTURE_EXAMPLES:
            self.assertTrue(polish.guard(q, a, mode="structured")["pass"], q)


OVERDELETE = ROOT / "tests" / "fixtures" / "polish_overdelete.jsonl"


class Repair(unittest.TestCase):
    """Polish dropping a meaningful phrase (a condition, an alternative, a number said its own way): the repair puts
    the transcript's words back instead of losing the meaning (docs/design/dictation.md §Repair). Mechanical: what
    was said twice may go, and a span no longer than DROP_MAX units (a hesitation's size); anything else comes back."""

    def overdelete(self) -> list[dict]:
        return [json.loads(ln) for ln in OVERDELETE.read_text(encoding="utf-8").splitlines() if ln.strip()]

    # references that leave out a three-unit filler in the middle of a sentence: with no filler list the repair can't
    # tell 就是说 from 或辅导, so it puts the words back (the model itself mostly keeps those fillers anyway)
    FILLER_COMES_BACK = {"zh-01": ["就是说"], "zh-02": ["呢然后"], "zh-04": ["就是那个"], "en-02": ["you know it just"]}

    def test_good_outputs_are_left_alone(self):
        """No reference output of either eval set gets anything put back (hesitations, stutters, restarts, numbers in
        digits, moved words, paragraphs are all fine) — but the three-unit fillers above."""
        for c in cases() + self.overdelete():
            fixed, spans = polish.repair(c["input"], c["reference"])
            self.assertEqual(spans, self.FILLER_COMES_BACK.get(c["id"], []), c["id"])
            if not spans:
                self.assertEqual(fixed, c["reference"], c["id"])
            self.assertTrue(polish.guard(c["input"], fixed)["pass"], c["id"])

    def test_dropped_phrases_come_back(self):
        for c in self.overdelete():
            fixed, _spans = polish.repair(c["input"], c["bad"])
            if c["id"] == "od-09":
                # 「凌晨」, two units on their own: the size of a filler — the one loss the mechanical repair lets by
                self.assertNotIn("凌晨", fixed)
                continue
            for k in c["keep"]:
                self.assertIn(polish._norm(k), polish._norm(fixed).replace("uh", ""), f"{c['id']}: {fixed}")
            self.assertTrue(polish.guard(c["input"], fixed)["pass"], f"{c['id']}: {fixed}")

    def test_a_dropped_condition_goes_back_where_it_was_said(self):
        raw = "那我估计它会比，呃，句子短的时候比 Siri 要快，句子长的时候就，嗯，比 Siri 要慢一些。"
        fixed, spans = polish.repair(raw, "那我估计它会比 Siri 要快，句子长的时候比 Siri 要慢一些。")
        self.assertEqual(fixed, "那我估计它会比，呃，句子短的时候比 Siri 要快，句子长的时候比 Siri 要慢一些。")
        self.assertEqual(spans, ["比，呃，句子短的时候"])

    def test_numbers_stay_as_said(self):
        fixed, spans = polish.repair("预算大概是一点二万，或者再多一点", "预算大概是一万二，或者再多一点。")
        self.assertEqual(fixed, "预算大概是一点二万，或者再多一点。")
        self.assertEqual(spans, ["一万二→一点二万"])
        fixed, spans = polish.repair("我们这周新增了三千五百个用户，留存大概是百分之四十二点五。",
                                     "我们这周新增了三千五个用户，留存大概是百分之四十二。")
        self.assertEqual(fixed, "我们这周新增了三千五百个用户，留存大概是百分之四十二点五。")
        for said, wrote, same in [("三十", "30", True), ("十七点二", "17.2", True), ("五零零", "500", True),
                                  ("二点三点一", "2.3.1", True), ("三万两千", "32000", True), ("一点二万", "12000", True),
                                  ("一点二万", "一万二", False), ("两百五", "250", False), ("三千五百", "三千五", False)]:
            self.assertEqual(polish.same_number(said, wrote), same, (said, wrote))

    def test_hesitations_and_stutters_may_go(self):
        for raw, out in [("嗯嗯那个我我我想说的是这个先放一放", "我想说的是，这个先放一放。"),
                         ("这个按钮的，这个按钮的颜色要再深一点", "这个按钮的颜色要再深一点。"),
                         ("呃我我我刚才试了一下登录然后就卡住了", "我刚才试了一下登录，然后就卡住了。"),
                         ("um so I I think it's fine", "I think it's fine."),
                         ("那个新版本在 iPhone 上没问题", "新版本在 iPhone 上没问题。"),
                         ("the the build is broken", "The build is broken.")]:
            self.assertEqual(polish.repair(raw, out)[1], [], raw)
            self.assertTrue(polish.guard(raw, polish.repair(raw, out)[0])["pass"], raw)

    def test_a_restatement_is_not_a_stutter(self):
        """A restart that says something different the second time is the speaker's words (Light keeps them); only an
        exact repetition is a stumble."""
        fixed, spans = polish.repair("标题字号改成十四改成十六吧", "标题字号改成十六吧。")
        self.assertIn("十四", fixed)
        self.assertEqual(polish.repair("我想我想说的是这个", "我想说的是这个。")[1], [])

    def test_the_marks_around_a_span_come_back_with_it(self):
        self.assertEqual(polish.repair("报价是两万，不对，是两万五，含税的。", "报价是两万五。")[0], "报价是两万，不对，是两万五，含税的。")
        self.assertEqual(polish.repair("the build passed, but the deploy failed twice", "The build passed.")[0],
                         "The build passed, but the deploy failed twice.")

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
        self.assertEqual(c("Output: Hello."), "Hello.")
        self.assertEqual(c("Dictation (a chat message: keep its tone words and sentence-final particles): 好的吧"), "好的吧")
        self.assertEqual(c("“你好。”"), "你好。")
        self.assertEqual(c("```\nHello.\n```"), "Hello.")
        self.assertEqual(c('She said "hi" to me.'), 'She said "hi" to me.')       # inner quotes stay

    def test_structured_output(self):
        self.assertEqual(polish.clean_structured("**明天要做三件事：**\n\n1. 跑测试\n2. 写文档\n"), "明天要做三件事：\n1. 跑测试\n2. 写文档")
        self.assertEqual(polish.clean_structured("## Steps\n1. Run it"), "Steps\n1. Run it")
        self.assertEqual(polish.list_lines("intro:\n1. a\n2. b\n- c"), 3)
        self.assertEqual(polish.without_list_marks("1. a\n2、b"), "a\nb")

    def test_units(self):
        self.assertEqual(polish.units("我们的API v2"), ["我", "们", "的", "api", "v", "2"])
        self.assertEqual(polish.units("They're here."), ["they're", "here"])
        self.assertEqual(polish.units(polish.collapse_repeats("嗯嗯那个我我我觉得")), ["嗯", "那", "个", "我", "觉", "得"])
        self.assertEqual(polish.units(polish.collapse_repeats("the the button")), ["the", "button"])


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
            self.assertEqual(o["reason"], "novel")
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


def test_no_space_between_two_cjk_characters():
    assert polish.clean_output("二 是改一下合同里的付款条款，三 是约设计师。") == "二是改一下合同里的付款条款，三是约设计师。"
    assert polish.clean_output("用 Claude Code 写一个 PR") == "用 Claude Code 写一个 PR"


class FakeEngine(polish.Engine):
    """Engine.polish / structure with a scripted model: what it was asked (and in which mode), and what it answers."""

    def __init__(self, reply):
        super().__init__()
        self.reply, self.asked = reply, []

    def load(self, model_id=None):
        self.model, self.model_id = object(), model_id or "fake"
        return self

    def generate(self, text, deadline, terms=None, context=None, mode="light", variant=None):
        self.asked.append((text, polish.messages(text, terms, context, mode, variant), mode))
        r = self.reply.get(mode) if isinstance(self.reply, dict) else self.reply
        return (r(text) if callable(r) else r), False


class EngineLight(unittest.TestCase):
    def test_the_model_gets_the_words_as_said(self):
        """No pass in front of the model rewrites what was said: a self-correction reaches it as heard."""
        e = FakeEngine(lambda t: t + "。")
        r = e.polish("把这个，不对，这两个拿到那一边去", "fake", 3, [], None)
        self.assertEqual(e.asked[0][0], "把这个，不对，这两个拿到那一边去")
        self.assertEqual((r["text"], r["fell_back"]), ("把这个，不对，这两个拿到那一边去。", False))
        self.assertNotIn("corrections", r)

    def test_a_model_that_resolves_a_correction_anyway_gets_its_words_put_back(self):
        e = FakeEngine("我们下周一交，然后把演示视频发给客户。")
        r = e.polish("我们周五交，哦不，下周一交，然后把演示视频发给客户", "fake", 3, [], None)
        self.assertFalse(r["fell_back"])
        self.assertEqual(r["text"], "我们周五交，哦不，下周一交，然后把演示视频发给客户。")
        # most of a short take put back: the transcript is typed (every word, as heard)
        r = FakeEngine("我们下周一交。").polish("我们周五交，哦不，下周一交", "fake", 3, [], None)
        self.assertEqual((r["fell_back"], r["reason"], r["text"]), (True, "dropped", "我们周五交，哦不，下周一交"))
        e = FakeEngine("Book the flight for Tuesday morning.")
        r = e.polish("book the flight for Monday, I mean Tuesday morning", "fake", 3, [], None)
        self.assertIn("Monday, I mean", r["text"])

    def test_a_list_from_light_falls_back(self):
        e = FakeEngine("明天要做三件事：\n1. 跑测试\n2. 写文档")
        r = e.polish("明天要做三件事第一跑测试第二写文档", "fake", 3, [], None)
        self.assertEqual((r["fell_back"], r["reason"]), (True, "listed"))
        self.assertEqual(r["text"], "明天要做三件事第一跑测试第二写文档")

    def test_chat_says_so_in_the_request_and_keeps_the_prefix(self):
        e = FakeEngine(lambda t: t)
        e.polish("那我们晚上见吧", "fake", 3, [], None, variant="chat")
        e.polish("那我们晚上见吧", "fake", 3, [], None)
        chat, plain = e.asked[0][1], e.asked[1][1]
        self.assertIn("chat message", chat[-1]["content"])
        self.assertTrue(chat[-1]["content"].endswith("那我们晚上见吧"))
        self.assertEqual(plain[-1]["content"], "那我们晚上见吧")
        n = 1 + 2 * len(polish.EXAMPLES)
        self.assertEqual([m["content"] for m in chat[:n]], [m["content"] for m in plain[:n]])


class EngineStructure(unittest.TestCase):
    """Structured: one pass of the same model over the whole take, its own prompt (cached separately), the guard in
    structured mode; a refusal leaves the text before the pass."""

    def test_a_list_and_a_resolved_correction(self):
        e = FakeEngine({"structure": "明天要做三件事：\n1. 把测试跑完\n2. 更新文档\n3. 发给小李"})
        src = "明天要做三件事，第一，把测试跑完，第二，更新文档，第三，发给小王，哦不是，发给小李。"
        r = e.structure(src, "fake", 10, [])
        self.assertEqual(e.asked[0][2], "structure")
        self.assertEqual(e.asked[0][1][0]["content"], polish.SYSTEM_STRUCTURE)
        self.assertEqual(e.asked[0][1][-1]["content"], src)
        self.assertEqual((r["fell_back"], r["list"]), (False, True))
        self.assertEqual(r["text"], "明天要做三件事：\n1. 把测试跑完\n2. 更新文档\n3. 发给小李")

    def test_prose_stays_prose(self):
        e = FakeEngine({"structure": "我们下周一交，然后把视频发给客户。"})
        r = e.structure("我们周五交，哦不，下周一交，然后把视频发给客户。", "fake", 10, [])
        self.assertEqual((r["fell_back"], r["list"], r["text"]), (False, False, "我们下周一交，然后把视频发给客户。"))

    def test_an_unresolved_correction_is_fine(self):
        src = "我们周五交，哦不，下周一交。"
        r = FakeEngine({"structure": src}).structure(src, "fake", 10, [])
        self.assertEqual((r["fell_back"], r["text"]), (False, src))

    def test_a_summary_or_an_answer_falls_back_to_the_text(self):
        src = "先把登录页的文案改一下，然后把注册流程里第三步那个多余的确认弹窗去掉，再把首页的加载动画换成新的，最后把帮助文档重写一下"
        for reply, why in [("改文案、去弹窗、换动画、重写文档。", "shrunk"), ("好的，我来帮你安排：" + src, "chatty")]:
            r = FakeEngine({"structure": reply}).structure(src, "fake", 10, [])
            self.assertEqual((r["fell_back"], r["reason"], r["text"]), (True, why, src), reply)

    def test_short_text_is_left_alone(self):
        e = FakeEngine({"structure": "x"})
        self.assertEqual(e.structure("好的", "fake", 10, [])["reason"], "short")
        self.assertEqual(e.asked, [])

    def test_two_cached_prefixes(self):
        light = polish.messages("你好")
        struct = polish.messages("你好", mode="structure")
        self.assertNotEqual(light[0]["content"], struct[0]["content"])
        self.assertEqual(len(struct), 2 + 2 * len(polish.STRUCTURE_EXAMPLES))
        self.assertEqual(polish.Engine.MODES, ("light", "structure"))


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

    def test_stitch_guard_types_a_fall_back_as_said(self):
        g = polish.stitch_guard("把这个，不对，这两个拿到那一边去", "当然可以！", None, [], None, "把这个，不对，这两个拿到那一边去")
        self.assertFalse(g["pass"])
        self.assertEqual(g["fallback_text"], "把这个，不对，这两个拿到那一边去")


if __name__ == "__main__":
    unittest.main()
