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


if __name__ == "__main__":
    unittest.main()
