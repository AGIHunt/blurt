"""The Chinese script a user reads (desi065, transcribe.py `chinese_script` / `to_user_script`): Whisper wrote
traditional characters (or a mix) for zh-Hans users; text heard as Chinese is now converted character by character
for them (OpenCC t2s: a script mapping, no meaning), and left alone for zh-Hant users, Japanese and everyone else.
Needs opencc-python-reimplemented (transcribe.py's own dependency); skipped without it.

  uv run --with numpy --with pytest --with opencc-python-reimplemented==0.1.7 pytest tests/test_transcribe_script.py -q
"""
from __future__ import annotations

import importlib.util
import unittest

import test_asr_select as A

T = A.T
HAS_OPENCC = importlib.util.find_spec("opencc") is not None


class Script(unittest.TestCase):
    def setUp(self):
        self.saved_tags, self.saved = T.system_language_tags, dict(T._script)
        T._script.pop("system", None)

    def tearDown(self):
        T.system_language_tags = self.saved_tags
        T._script.clear()
        T._script.update(self.saved)

    def script_for(self, tags, cfg=None):
        T.system_language_tags = lambda: tags
        T._script.pop("system", None)
        return T.chinese_script(cfg or {})

    def test_the_script_comes_from_the_users_languages(self):
        self.assertEqual(self.script_for(["zh-Hans-CN", "en-CN"]), "hans")
        self.assertEqual(self.script_for(["en-US", "zh-CN"]), "hans")
        self.assertEqual(self.script_for(["zh"]), "hans")
        self.assertEqual(self.script_for(["zh-Hant-TW", "en"]), "hant")
        self.assertEqual(self.script_for(["zh-TW"]), "hant")
        self.assertEqual(self.script_for(["zh-HK"]), "hant")
        self.assertEqual(self.script_for(["yue-Hant-HK"]), "hant")
        self.assertIsNone(self.script_for(["en-US", "ja-JP"]))
        # the first Chinese entry decides
        self.assertEqual(self.script_for(["zh-Hant-TW", "zh-Hans-CN"]), "hant")
        # a setting wins over the system
        self.assertEqual(self.script_for(["zh-Hant-TW"], {"chinese_script": "hans"}), "hans")

    def test_system_languages_still_reduce_to_codes(self):
        T.system_language_tags = lambda: ["zh-Hans-CN", "en-CN", "zh-HK", "yue-Hant-HK", "C"]
        self.assertEqual(T.system_languages(), ["zh", "en", "yue"])

    @unittest.skipUnless(HAS_OPENCC, "opencc-python-reimplemented not installed")
    def test_zh_hans_user_gets_simplified(self):
        heard = "登录頁面周五之前要上線，記得把按鈕顏色改深一點"
        self.assertEqual(T.to_user_script(heard, "zh", "hans"), "登录页面周五之前要上线，记得把按钮颜色改深一点")
        self.assertEqual(T.to_user_script(heard, None, "hans"), "登录页面周五之前要上线，记得把按钮颜色改深一点")
        # English inside stays as it is
        self.assertEqual(T.to_user_script("用 Claude Code 改一下 README 檔案", "zh", "hans"), "用 Claude Code 改一下 README 档案")

    def test_left_alone_for_everyone_else(self):
        heard = "登录頁面周五之前要上線"
        self.assertEqual(T.to_user_script(heard, "zh", "hant"), heard)          # zh-Hant users keep traditional
        T._script["system"] = None                                              # no Chinese among their languages
        self.assertEqual(T.to_user_script(heard, "zh"), heard)
        self.assertEqual(T.to_user_script("會議は明日です", None, "hans"), "會議は明日です")  # Japanese (kana)
        self.assertEqual(T.to_user_script("會議", "ja", "hans"), "會議")         # tagged Japanese
        self.assertEqual(T.to_user_script("the export button", "en", "hans"), "the export button")
        self.assertEqual(T.to_user_script("", "zh", "hans"), "")

    @unittest.skipUnless(HAS_OPENCC, "opencc-python-reimplemented not installed")
    def test_every_path_passes_through_decode_slice(self):
        class Trad(A.FakeBackend):
            def transcribe(self, x):
                return [(0.0, 1.0, "記得把按鈕顏色改深一點", "zh"), (1.0, 2.0, "the button", "en")]

        T._script["system"] = "hans"
        out = T.decode_slice(Trad(None), [0.0] * 32000, 10.0, 12.0)
        self.assertEqual([o[2] for o in out], ["记得把按钮颜色改深一点", "the button"])
        self.assertEqual(out[0][:2], (10.0, 11.0))


if __name__ == "__main__":
    unittest.main()
