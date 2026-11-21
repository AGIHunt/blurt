"""The main window's copy follows the shared glossary (area D2): the macOS Main and Common tables and the review page's
catalogs (web/packages/review, web/packages/i18n common) say one thing.

  • the hand-off is one verb: "Copy instruction for agent" / "复制指令给 Agent", its state "Handed off" / "已交给 Agent" — never
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
        # "hanging"), 事项 (never 条目, BA-57), 复制, 未归类, App; agents are "signed in"; suggestions say 看起来是 / 移动
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
        # the Mac's menu item and the review page's button say the same thing, where both are still there (the
        # in-app sessions they used to open are gone; the wording is the apps' to choose, once)
        for main, review in ((en["Main.strings"], en["review"]), (zh["Main.strings"], zh["review"])):
            if "main.menu.start_session" in main and "handoff.dispatch" in review:
                self.assertEqual(main["main.menu.start_session"], review["handoff.dispatch"])
        for c in (zh["Common.strings"], zh["common"]):
            self.assertEqual(c["state.handed_off"], "已交给 Agent")
            self.assertEqual(c["action.hand_off"], "复制指令给 Agent")   # it copies; you paste it into any agent
        for c in (en["Common.strings"], en["common"]):
            self.assertEqual(c["action.hand_off"], "Copy instruction for agent")  # menus title-case it
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

    def test_used_cards_are_the_cards_pages_history_only(self):
        # v1.0.7: "Recently Dragged Out" (its own panel, menu-bar row, island menu row, main-window row and notice) is
        # gone; cards used in other apps are the Cards page's History section, reached by ⌥H — and the two sections
        # are "Current" / "History", never the stiff "Hanging / Used" ("挂着的 / 用过的"). v1.0.23: ⌥H's floating
        # Cards panel is gone too (the page is the one place for every card); how long History keeps a card follows
        # Settings → Cards → History, never a "7 days" written into the copy
        for lang in ("en", "zh-Hans"):
            main = strings(RES / f"{lang}.lproj" / "Main.strings")
            cap = strings(RES / f"{lang}.lproj" / "Capture.strings")
            cards = strings(RES / f"{lang}.lproj" / "Cards.strings")
            for k in ("main.captures.taken", "main.captures.taken.show", "main.captures.taken.tip", "main.sidebar.taken"):
                self.assertNotIn(k, main, (lang, k))
            for k in ("capture.taken.title", "capture.taken.menu", "capture.taken.show_all", "capture.taken.hint",
                      "capture.taken.empty_title", "capture.taken.kept", "capture.taken.drag_again",
                      "capture.cards.seg_current", "capture.cards.seg_history", "capture.cards.overview_heading",
                      "capture.cards.panel_keys", "capture.cards.history_hint"):
                self.assertNotIn(k, cap, (lang, k))
            for t in (main, cap, cards):
                for k, v in t.items():
                    for gone in ("Recently Dragged Out", "Recently dragged out", "最近拖走", "挂着的", "用过的", "Hanging %@", "“Used”",
                                 "Cards panel", "卡片面板", "7 days", "7 天"):
                        self.assertNotIn(gone, v, (lang, k))
            self.assertIn("%d", cards["cards.history.kept"], lang)
        self.assertEqual(strings(RES / "en.lproj" / "Cards.strings")["cards.section.current"], "Current")
        self.assertEqual(strings(RES / "en.lproj" / "Cards.strings")["cards.section.history"], "History")
        self.assertEqual(strings(RES / "zh-Hans.lproj" / "Cards.strings")["cards.section.current"], "当前")
        self.assertEqual(strings(RES / "zh-Hans.lproj" / "Cards.strings")["cards.section.history"], "历史")
        src = "\n".join(p.read_text() for p in (RES.parent).rglob("*.swift"))
        for gone in ("TakenBanner", "mShowTaken", "main.sidebar.taken", "capture.taken.menu", "CardsOverview", "overviewEsc"):
            self.assertNotIn(gone, src, gone)


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
        # beside the step's own action, going on without it is the quiet Skip This Step — never a second bordered Next,
        # and never Skip Setup beside it (two grey skips nobody could tell apart: dogfood 2026-11-21)
        self.assertIn('T("onboarding.skip_step")', footer)
        with_action = footer[footer.index("if let a = action {"):footer.index("} else {", footer.index("if let a = action {"))]
        self.assertNotIn("onboarding.skip_setup", with_action)
        self.assertNotIn("Button(nextTitle) { advance() }\n                Button(a.title)", footer)
        self.assertNotIn(".pickerStyle(.menu)", src, "the dictation key is a ChoicePopup, as the language row")
        self.assertNotIn("GlyphTile.symbol(", src, "one glyph family on every step: the line glyphs")


class OneWordPerConcept(unittest.TestCase):
    """docs/design/system.md §9a: one zh and one en word per concept on every surface — the Mac's tables, the Tauri
    app's catalogs, the review page and the phone apps. These hold the variants that lost (founder, 2026-11-16)."""

    DESKTOP = ROOT / "web" / "apps" / "desktop" / "src" / "locales"

    def every(self, lang):
        """{table: {key: value}} on every surface in one language"""
        out = {p.name: strings(p) for p in (RES / f"{lang}.lproj").glob("*.strings")}
        for p in (RES / f"{lang}.lproj").glob("*.stringsdict"):
            out[p.name] = {k: json.dumps(v, ensure_ascii=False) for k, v in plistlib.loads(p.read_bytes()).items()}
        for name in (f"{lang}.json", f"settings.{lang}.json"):
            out["desktop/" + name] = json.loads((self.DESKTOP / name).read_text(encoding="utf-8"))
        out.update({n: t for n, t in tables(lang).items() if n in ("review", "common")})
        return out

    def words(self, lang):
        for name, t in self.every(lang).items():
            for k, v in t.items():
                if ".kw." not in k and not k.startswith(("settings.kw", "st.settings.kw")):  # search words keep synonyms
                    yield name, k, v

    def test_recording_is_luping_and_its_action_one_name(self):
        zh, en = self.every("zh-Hans"), self.every("en")
        for t, k in (("Main.strings", "app.menu.record"), ("Main.strings", "main.action.record"),
                     ("Capture.strings", "capture.action.record"), ("Capture.strings", "capture.picker.start"),
                     ("desktop/zh-Hans.json", "main.action.record")):
            self.assertEqual(zh[t][k], "开始录屏", k)
        self.assertEqual(en["Main.strings"]["main.action.record"], en["Main.strings"]["app.menu.record"])
        # 录制 is for sound only (a voiceprint, a Lab take, system audio) and macOS's own 屏幕录制 permission
        sound = {"settings.general.system_audio", "st.settings.general.system_audio", "capture.note.record",
                 "capture.note.ph_voice_busy", "settings.storage.detail.lab", "st.settings.storage.detail.lab",
                 "st.win.keys.app.game_bar_record"}
        for name, k, v in self.words("zh-Hans"):
            if "录制" in v.replace("屏幕录制", "") and k not in sound and not k.startswith(("dictation.", "st.dictation.")):
                self.fail(f"{name} {k}: 录屏, not 录制 ({v})")

    def test_an_items_kind_is_zhonglei(self):
        # 类型 is the review page's separate issue *type* field and dictation's "kind of app"; an item's kind is 种类
        cap = self.every("zh-Hans")["Capture.strings"]
        for k in ("capture.note.kind_chip", "capture.note.kind_tip", "capture.note.kind_ax", "capture.note.kind_none_tip"):
            self.assertIn("种类", cap[k], k)
        self.assertEqual(self.every("en")["Capture.strings"]["capture.note.kind_chip"], "Kind")
        for name, k, v in self.words("zh-Hans"):
            if "类型" in v and name != "review" and "by_app" not in k:
                self.fail(f"{name} {k}: 种类, not 类型 ({v})")
        for lang in ("zh-Hans", "en"):
            self.assertEqual(self.every(lang)["Common.strings"]["kind.task"], {"zh-Hans": "待办", "en": "Task"}[lang])
        self.assertNotIn("笔记、任务", (ROOT / "README.zh-CN.md").read_text(encoding="utf-8"))

    def test_the_variants_that_lost(self):
        zh_lost = {"语音便签": "语音备注", "截屏": "截图", "截取": "截图", "屏幕翻译": "截图翻译", "复制屏幕文字": "截图取字",
                   "翻译屏幕文字": "截图翻译", "听写快捷键": "听写键", "挂在": "留在", "交出": "复制指令给 Agent", "首页": "主页",
                   "中继": "中转", "收件箱": "待处理", "未分类": "未归类", "历史记录": "历史", "取字记录": "历史"}
        # Windows' own feature keeps its own name (剪贴板历史记录, the app list of the key catcher)
        theirs = {"st.win.keys.app.clipboard_history"}
        for name, k, v in self.words("zh-Hans"):
            for lost, word in zh_lost.items():
                if k not in theirs:
                    self.assertNotIn(lost, v, f"{name} {k}: {word}, not {lost}")
        for name, k, v in self.words("en"):
            self.assertNotRegex(v, r"(?i:voice memo)|Away from Home|under Copy Text from Screen|\bhangs\b",
                                f"{name} {k}")
        # the phone apps' deck says 语音备注 too
        ios = (ROOT / "apps/ios/BlurtRemote/Resources/Localizable.xcstrings").read_text(encoding="utf-8")
        android = (ROOT / "apps/android/app/src/main/java/dev/blurt/remote/app/keys/DeckText.kt").read_text(encoding="utf-8")
        for src in (ios, android):
            self.assertNotIn("语音便签", src)

    def test_screen_text_is_the_capabilitys_name_wherever_the_feature_is_meant(self):
        for lang in ("zh-Hans", "en"):
            t = self.every(lang)
            name = t["Home.strings"]["feature.screen_text"]
            # the capability (its pane, its page) is 取字与翻译 / Text & Translation; the model job serves ⌥C only, so it
            # carries ⌥C's own name (2026-11-16)
            self.assertEqual(t["Settings.strings"]["settings.kit.screen_text"], name, lang)
            self.assertEqual(t["Models.strings"]["models.job.vision"], t["Capture.strings"]["capture.menu.text"], lang)
            self.assertIn(name, t["Capture.strings"]["capture.action.translate.detail"], lang)

    def test_an_agents_field_has_a_label_not_its_key(self):
        # an idea's next step written as `next` read "Next" in the Chinese detail (persona walkthrough)
        for lang in ("zh-Hans", "en"):
            review = self.every(lang)["review"]
            for k in ("field.next", "field.next_step", "field.next_steps"):
                self.assertEqual(review[k], review["field.next_steps"], (lang, k))
