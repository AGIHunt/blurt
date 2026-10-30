"""The main window's copy follows the shared glossary (area D2): the macOS Main and Common tables and the review page's
catalogs (web/packages/review, web/packages/i18n common) say one thing.

  • the hand-off is one verb: "Hand Off to Agent" / "交给 Agent", its state "Handed off" / "已交给 Agent" — never
    "Start in Blurt", "With …", 交出 / 已交出;
  • zh writes "Agent" capitalised, and never 捕获, 拷贝, 刘海岛 or 语音输入;
  • no arrow glyphs as menu paths in the copy ("Settings → Agents"): say "in Settings, under Agents";
  • the inbox's count reads the same in the window subtitle and the menu bar menu ("9 new · 6 to verify").

These are checks on our own UI strings, not on anything a user dictates.

  uv run --with pytest pytest tests/test_ui_copy.py -q
"""
import json
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "skills" / "blurt" / "recorder" / "macos" / "Sources" / "BlurtApp" / "Resources"
WEB = ROOT / "web" / "packages"
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def strings(path: Path) -> dict:
    text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
    return {m.group(1): m.group(2) for m in map(ENTRY.match, text.splitlines()) if m}


def plural_forms(path: Path, key: str) -> list:
    d = plistlib.loads(path.read_bytes())[key]
    var = re.findall(r"%#@(\w+)@", d["NSStringLocalizedFormatKey"])[0]
    return [v for k, v in d[var].items() if not k.startswith("NSString")]


def tables(lang: str) -> dict:
    """{name: {key: value}} for the tables this area writes in one language"""
    out = {f"{t}.strings": strings(RES / f"{lang}.lproj" / f"{t}.strings") for t in ("Main", "Common")}
    out["review"] = json.loads((WEB / "review" / "src" / "locales" / f"{lang}.json").read_text(encoding="utf-8"))
    out["common"] = json.loads((WEB / "i18n" / "src" / "common" / f"{lang}.json").read_text(encoding="utf-8"))
    return out


class Glossary(unittest.TestCase):
    def test_zh_writes_agent_capitalised_and_the_glossary_words(self):
        for name, t in tables("zh-Hans").items():
            for k, v in t.items():
                self.assertNotRegex(v, r"(?<![A-Za-z{_])agent(?![A-Za-z}_])", f"{name} {k}: lowercase agent")
                for word in ("捕获", "拷贝", "刘海岛", "语音输入", "交出"):
                    self.assertNotIn(word, v, f"{name} {k}: {word}")

    def test_the_glossary_holds_in_every_table(self):
        # docs/positioning/facts.md and the README use the same words: the notch (never "the island"), cards (never
        # "hanging"), 事项 (never 条目, BA-57), 复制, 未归类, App; agents are "signed in"; suggestions say 可能属于 / 移过去
        def every(lang):
            out = {p.name: strings(p) for p in (RES / f"{lang}.lproj").glob("*.strings")}
            for p in (RES / f"{lang}.lproj").glob("*.stringsdict"):
                out[p.name] = {k: json.dumps(v, ensure_ascii=False) for k, v in plistlib.loads(p.read_bytes()).items()}
            out.update({n: t for n, t in tables(lang).items() if n in ("review", "common")})
            return out
        for name, t in every("zh-Hans").items():
            for k, v in t.items():
                for word in ("挂成", "挂着", "挂回", "岛", "其它", "归过去", "像是", "智能体", "条目", "交接单", "一键", "随手", "递给"):
                    self.assertNotIn(word, v, f"{name} {k}: {word}")
        for name, t in every("en").items():
            for k, v in t.items():
                self.assertNotRegex(v, r"(?i)\bisland\b|\bhanging\b|\bhang (as|back)\b|logged (in|out)|seamless|effortless|supercharge",
                                    f"{name} {k}")

    def test_one_name_for_the_hand_off(self):
        en, zh = tables("en"), tables("zh-Hans")
        for name, t in en.items():
            for k, v in t.items():
                self.assertNotIn("Start in Blurt", v, f"{name} {k}")
                self.assertFalse(v.startswith("With "), f"{name} {k}: {v!r}")
        self.assertEqual(en["Main.strings"]["main.menu.start_session"], "Hand Off to Agent")
        self.assertEqual(zh["Main.strings"]["main.menu.start_session"], "交给 Agent")
        self.assertEqual(en["review"]["handoff.dispatch"], "Hand Off to Agent")
        self.assertEqual(zh["review"]["handoff.dispatch"], "交给 Agent")
        for c in (zh["Common.strings"], zh["common"]):
            self.assertEqual(c["state.handed_off"], "已交给 Agent")
            self.assertEqual(c["action.hand_off"], "交给 Agent…")
        for c in (en["Common.strings"], en["common"]):
            self.assertEqual(c["action.hand_off"], "Hand off to agent…")  # menus title-case it: "Hand Off to Agent…"
        self.assertEqual(en["review"]["keys.hand_off"], en["common"]["action.hand_off"])
        self.assertEqual(en["Common.strings"]["state.handed_off.session"], "Handed off to %@")
        self.assertEqual(en["common"]["state.handed_off.session"], "Handed off to {agent}")

    def test_no_arrows_as_menu_paths(self):
        for lang in ("en", "zh-Hans"):
            for name, t in tables(lang).items():
                for k, v in t.items():
                    self.assertNotIn("→", v, f"{lang} {name} {k}")

    def test_the_inbox_count_reads_the_same_everywhere(self):
        for lang in ("en", "zh-Hans"):
            main = strings(RES / f"{lang}.lproj" / "Main.strings")
            menu = RES / f"{lang}.lproj" / "Main.stringsdict"
            self.assertNotIn("main.inbox.needs_you", main)         # the subtitle is just the parts, under "Inbox"
            self.assertIn(main["main.inbox.new"], plural_forms(menu, "app.menu.new"))
            self.assertIn(main["main.inbox.verify"], plural_forms(menu, "app.menu.to_verify"))
            island = plural_forms(RES / f"{lang}.lproj" / "Capture.stringsdict", "capture.island.to_review")
            self.assertTrue(all("review" not in f for f in island), island)

    def test_recently_dragged_out_has_one_name(self):
        # the main window's row said "Recently taken: 6" and opened a panel called "Recently Dragged Out"
        for lang in ("en", "zh-Hans"):
            main = strings(RES / f"{lang}.lproj" / "Main.strings")
            cap = strings(RES / f"{lang}.lproj" / "Capture.strings")
            name = cap["capture.taken.title"].lower()
            self.assertTrue(main["main.captures.taken"].lower().startswith(name), (lang, main["main.captures.taken"]))
            self.assertTrue(cap["capture.taken.menu"].lower().startswith(name), (lang, cap["capture.taken.menu"]))


if __name__ == "__main__":
    unittest.main()


class ShellCopy(unittest.TestCase):
    """The setup assistant's and Settings' words (dogfood, shell): one term per thing, templates that read as sentences."""

    def every(self, lang):
        return {p.name: strings(p) for p in (RES / f"{lang}.lproj").glob("*.strings")}

    def test_the_dictation_key_fills_its_slot_without_doubling(self):
        # zh's inline key is " Fn 键" (its own leading space, its own 键): a template wraps it as 按%@就能, never "%@ 键"
        zh = self.every("zh-Hans")
        self.assertTrue(zh["Dictation.strings"]["dictation.key.fn.inline"].endswith("键"))
        self.assertEqual(zh["Settings.strings"]["settings.perm.done.no_model"], "下一步下载语音模型，之后按%@就能随处听写。")
        self.assertEqual(zh["Dictation.strings"]["dictation.status.other_instance_key"], "另一个口喷鸡正在听%@")

    def test_one_word_for_the_words_list_and_one_name_for_the_provider(self):
        zh, en = self.every("zh-Hans"), self.every("en")
        for name, t in zh.items():
            for k, v in t.items():
                if k.startswith("settings.kw."):
                    continue            # search keywords keep the other words people may type
                for word in ("词表", "词汇", "自定义词"):
                    self.assertNotIn(word, v, f"{name} {k}: 词库, not {word}")
        for lang, tables in (("zh", zh), ("en", en)):
            for name, t in tables.items():
                for k, v in t.items():
                    if k.startswith("settings.kw."):
                        continue
                    self.assertNotIn("DashScope", v, f"{lang} {name} {k}")
                    self.assertNotIn("(MLX)", v, f"{lang} {name} {k}")
        catalog = json.loads((ROOT / "skills/blurt/scripts/asr_models.json").read_text(encoding="utf-8"))
        names = [m["name"] for m in catalog["models"]]
        self.assertFalse([n for n in names if "(MLX)" in n or "DashScope" in n], names)
        self.assertEqual(len(names), len(set(names)), "two models never share a name")

    def test_the_setup_assistant_has_one_forward_action(self):
        src = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Onboarding/Onboarding.swift").read_text(encoding="utf-8")
        footer = src[src.index("var footer: some View"):src.index("/// The headline and its line")]
        # beside the step's own action, going on without it is the quiet Not Now — never a second bordered Next
        self.assertIn('T("onboarding.not_now")', footer)
        self.assertNotIn("Button(nextTitle) { advance() }\n                Button(a.title)", footer)
        self.assertNotIn(".pickerStyle(.menu)", src, "the dictation key is a ChoicePopup, as the language row")
        self.assertNotIn("GlyphTile.symbol(", src, "one glyph family on every step: the line glyphs")
