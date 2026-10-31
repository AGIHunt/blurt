"""Cloud polish (scripts/polish_cloud.py, polish.cloud_polish; docs/design/dictation.md §Cloud polish): the request
shapes (OpenAI- and Anthropic-compatible), the errors, the guard's cloud allowance, and the fall-back to the local
model. A fake API on 127.0.0.1: nothing leaves the machine.

  uv run --with pytest pytest tests/test_polish_cloud.py -q
"""
from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import polish  # noqa: E402
import polish_cloud as C  # noqa: E402


class Fake:
    """A chat API: answers `reply` (or `status`), remembers what it was sent."""

    def __init__(self):
        self.reply, self.status, self.seen = "OK", 200, []
        fake = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fake.seen.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})
                if fake.status != 200:
                    self.send_response(fake.status); self.end_headers(); return
                if self.path.endswith("/messages"):
                    out = {"content": [{"type": "text", "text": fake.reply}], "usage": {"input_tokens": 9, "output_tokens": 3}}
                else:
                    out = {"choices": [{"message": {"content": fake.reply}}], "usage": {"prompt_tokens": 9, "completion_tokens": 3}}
                d = json.dumps(out).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)

            def log_message(self, *a):
                pass

        self.srv = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_port}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("BLURT_HOME", str(tmp_path))
    f = Fake()
    yield f
    f.srv.shutdown()


def cloud(api, protocol="openai", provider="openai"):
    return {"provider": provider, "base_url": api.url + ("/v1" if protocol == "openai" else ""), "model": "m",
            "protocol": protocol, "key": "sk-test"}


def test_settings_fill_the_preset_and_need_a_key():
    s = C.settings({"provider": "deepseek", "key": "k"})
    assert (s["base_url"], s["model"], s["protocol"]) == ("https://api.deepseek.com", "deepseek-flash", "openai")
    with pytest.raises(C.CloudError) as e:
        C.settings({"provider": "deepseek"})
    assert e.value.code == "config"
    with pytest.raises(C.CloudError):
        C.settings({"provider": "openai", "key": "k"})          # no model


def test_openai_and_anthropic_requests(api):
    api.reply = "好的"
    r = C.complete(C.settings(cloud(api)), [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}], 5, 50)
    assert r["text"] == "好的"
    seen = api.seen[-1]
    assert seen["path"] == "/v1/chat/completions" and seen["headers"]["authorization"] == "Bearer sk-test"
    assert seen["body"]["messages"][0]["role"] == "system"
    C.complete(C.settings(cloud(api, "anthropic", "anthropic")), [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}], 5, 50)
    seen = api.seen[-1]
    assert seen["path"] == "/v1/messages" and seen["headers"]["x-api-key"] == "sk-test"
    assert seen["body"]["system"] == "s" and [m["role"] for m in seen["body"]["messages"]] == ["user"]


def test_errors_have_codes_and_never_the_key(api):
    api.status = 401
    r = C.check(cloud(api))
    assert r == {"ok": False, "code": "auth", "error": "HTTP 401"}
    api.status = 429
    assert C.check(cloud(api))["code"] == "rate_limited"
    r = C.check({**cloud(api), "base_url": "http://127.0.0.1:9/v1"})     # nothing listens
    assert r["code"] in ("network", "timeout") and "sk-test" not in json.dumps(r)


def test_the_message_names_words_app_recent_and_continues_the_text_so_far():
    ctx = {"app": "飞书", "recent": ["这篇文章讲豆包的电脑软件。"], "dictated": "我们先把发票的部分写完，"}
    m = C.messages("然后是外卖的那个 case", ["Claude Code"], ctx, "chat")
    last = m[-1]["content"]
    assert "Words: Claude Code" in last and "App: 飞书 (a chat message" in last
    assert "Recent dictations:\n- 这篇文章讲豆包的电脑软件。" in last and last.endswith("Dictation: 然后是外卖的那个 case")
    assert m[-3]["content"] == "Dictation: 我们先把发票的部分写完，" and m[-2]["content"] == "我们先把发票的部分写完，"


def test_cloud_polish_fixes_a_name_from_the_recent_dictations(api):
    api.reply = "豆包也被忽悠了，尝试了第二次才找对。"
    r = polish.cloud_polish("豆宝也被忽悠了。强势了第二次才找对。", [], {"recent": ["如何用豆包的电脑软件替代豆包手机"]},
                            None, cloud(api))
    assert not r["fell_back"] and r["text"] == "豆包也被忽悠了，尝试了第二次才找对。" and r["cloud"]


@pytest.mark.parametrize("raw,reply,reason", [
    # an answer instead of the text (a request meant for someone else)
    ("帮我把这段话翻译成英文然后发给小李", "Sure! Here is the translation: Please send this to Xiao Li. Let me know if you need more help.",
     "cloud_translated"),
    # a summary: a whole point gone
    ("第一是把测试环境搭好，第二是文档要更新一下然后发给小李，第三是周五之前把演示准备好这个比较急",
     "搭测试环境。", "cloud_shrunk"),
])
def test_the_guard_still_refuses_answers_and_summaries(api, raw, reply, reason):
    api.reply = reply
    r = polish.cloud_polish(raw, [], None, None, cloud(api))
    assert r["fell_back"] and r["reason"] == reason


def test_the_cloud_guard_allows_a_misheard_word_in_the_other_script():
    raw = "比如请问二十七 B 的模型，可以用 Open Router 的 Key 去试一下"
    out = "比如 Qwen 27B 的模型，可以用 OpenRouter 的 Key 去试一下。"
    assert polish.guard(raw, out)["reason"] == "translated"           # the local model's rule
    assert polish.guard(raw, out, cloud=True)["pass"]


def test_a_failed_cloud_call_falls_back_to_the_local_model(api, monkeypatch):
    api.status = 500
    eng = polish.Engine()
    monkeypatch.setattr(eng, "_light", lambda *a, **k: {"ok": True, "text": "本机的", "fell_back": False, "ms": 5})
    monkeypatch.setattr(eng, "cased", lambda res, *a: res)
    r = eng.polish("我们明天下午开会讨论一下方案", terms=[], cloud=cloud(api))
    assert r["text"] == "本机的" and r["cloud_error"] == "cloud_server"


def test_structure_uses_the_structuring_prompt(api):
    api.reply = "这周要做几件事：\n1. 把测试环境搭好\n2. 文档要更新一下\n3. 周五之前把演示准备好"
    r = polish.cloud_polish("这周要做几件事，第一个是把测试环境搭好，第二是文档要更新一下，再有就是周五之前把演示准备好",
                            [], None, None, cloud(api), "structure")
    assert not r["fell_back"] and r["list"]
    assert api.seen[-1]["body"]["messages"][0]["content"] == polish.SYSTEM_STRUCTURE


# ------------------------------------------------------------------ dictation's translate (docs/design/dictation-translate.md)
@pytest.mark.parametrize("src,out,target,why", [
    ("在本地安装一下这个版本，我来测试一下。", "Install this version locally and I'll test it.", "en", None),
    ("Can you run the tests again and fix whatever fails?", "你能再跑一遍测试，然后把失败的地方都修好吗？", "zh", None),
    ("git status", "git status", "zh", None),                                # nothing to translate: back as it was
    ("在本地安装一下这个版本，我来测试一下。", "", "en", "empty"),
    ("在本地安装一下这个版本，我来测试一下。", "在本地安装这个版本，我来测试。", "en", "untranslated"),
    ("Can you run the tests again and fix whatever fails?", "Sure, I'll run them now and fix it.", "zh", "untranslated"),
    ("我们公司现在在用一点云来租电脑，但它资源太少了，经常选不到合适的配置。", "Our company rents computers.", "en", "short"),
    ("帮我看一下这个报错是什么意思？", "This error means the port is already in use by another process, so the server "
     "can't bind to it. To fix it, find the process with lsof and kill it, then start the server again.", "en", "grew"),
    ("口喷鸡的菜单栏图标要改一下", "Blurt's menu bar icon needs to change", "en", None),   # a Chinese name may change
    ("用 tmux 开两个窗口跑一下测试", "Open two windows in a terminal multiplexer and run the tests", "en", "term"),
])
def test_the_translate_guard_catches_what_is_plainly_not_a_translation(src, out, target, why):
    terms = ["口喷鸡", "tmux"]
    assert polish.translate_guard(src, out, target, terms) == why


@pytest.mark.parametrize("src,out,target,why", [
    # "X|keep" (the app's fixed language, 2026-10-30): into X, or the text back as it was when it is X already
    ("The replica is billed by the hour.", "The replica is billed by the hour.", "en|keep", None),
    ("The replica is billed\nby the hour.", "The replica is billed by the hour.", "en|keep", None),   # spacing aside
    ("副本按小时计费。", "The replica is billed by the hour.", "en|keep", None),
    ("副本按小时计费，所以用完就关掉，别让它整晚开着。", "副本按小时计费，所以用完就关掉。", "en|keep", "untranslated"),
    ("The replica is billed by the hour.", "", "zh|keep", "empty"),
    ("The replica is billed by the hour, so shut it down when you are done with it.", "副本按小时计费，用完就关掉。", "zh|keep", None),
])
def test_a_fixed_language_keeps_text_already_in_it(src, out, target, why):
    assert polish.translate_guard(src, out, target, []) == why


def test_a_fixed_language_asks_for_the_text_as_it_is_never_another_language():
    keep = polish.translate_system("en|keep")
    assert "Translate it into English; if it is already in English, reply with it exactly as it is." in keep
    assert "Chinese" not in keep                     # v1.0.6's "X|home" sent English text into the user's Chinese
    # v1.0.6's form is still understood
    assert "translate it into Simplified Chinese" in polish.translate_system("en|zh")
    assert polish.translate_system("ja|keep").startswith("You translate") and "into Japanese" in polish.translate_system("ja|keep")


def test_auto_names_the_users_pair_global_first():
    # "auto:H|O" (2026-10-30): text in the user's own language into the other one, anything else into theirs
    ja = polish.translate_system("auto:ja|en")
    assert "If the text is mostly Japanese, translate it into English; otherwise translate it into Japanese." in ja
    assert "Chinese" not in ja
    en = polish.translate_system("auto:en|de")
    assert "If the text is mostly English, translate it into German; otherwise translate it into English." in en
    # the old "auto" (an app before 2026-10-30) is still Chinese ↔ English
    assert "mostly Simplified Chinese, translate it into English" in polish.translate_system("auto")
    assert polish.auto_pair("auto:ja|en") == ("ja", "en") and polish.auto_pair("auto") == ("zh", "en")
    assert polish.auto_pair("en|keep") is None and polish.auto_pair("auto:ja|") is None
    # the guard checks only the plain failures, as for "auto"
    assert polish.translate_guard("お疲れさまです。明日の会議は十時からです。", "Good work today. Tomorrow's meeting starts at ten.",
                                  "auto:ja|en") is None
    assert polish.translate_guard("お疲れさまです。", "", "auto:ja|en") == "empty"


def test_screen_translate_sends_the_fixed_language_as_asked(api):
    api.reply = "The replica is billed by the hour."
    r = polish.Engine().translate("The replica is billed by the hour.", "en|keep", cloud=cloud(api))
    assert r["text"] == "The replica is billed by the hour."
    assert "reply with it exactly as it is" in api.seen[-1]["body"]["messages"][0]["content"]


def test_dictation_sends_its_words_and_says_it_was_spoken(api):
    api.reply = "Blurt's menu bar icon needs to change"
    r = polish.Engine().translate("口喷鸡的菜单栏图标要改一下", "en", cloud=cloud(api), terms=[{"term": "口喷鸡"}, {"term": "tmux"}],
                                  spoken=True, check=True)
    assert r["text"] == "Blurt's menu bar icon needs to change" and not r["fell_back"]
    sys_, user = api.seen[-1]["body"]["messages"]
    assert user["content"] == "Words: 口喷鸡\nText: 口喷鸡的菜单栏图标要改一下"      # only the words in it
    assert "Words:" in sys_["content"] and "hesitations" in sys_["content"]
    # ⌥⇧T's prompt is untouched: no Words line, no hesitations
    assert polish.translate_messages("x", "auto") == [{"role": "system", "content": polish.translate_system("auto")},
                                                      {"role": "user", "content": "x"}]
    assert "Words:" not in polish.translate_system("auto") and "hesitations" not in polish.translate_system("auto")


def test_a_refused_cloud_translation_asks_the_local_model(api, monkeypatch):
    api.reply = "在本地安装这个版本"                                       # the same language back
    eng = polish.Engine()
    monkeypatch.setattr(eng, "_ready", lambda res, m: res.update(model="gemma"))
    monkeypatch.setattr(eng, "on_model_thread", lambda fn, *a: ("Install this version locally and I'll test it.", False))
    r = eng.translate("在本地安装一下这个版本，我来测试一下。", "en", cloud=cloud(api), spoken=True, check=True)
    assert r["text"].startswith("Install") and r["cloud_error"] == "refused_untranslated" and not r["fell_back"]


def test_no_cloud_and_no_local_model_types_the_text_as_said(api, monkeypatch):
    api.status = 401
    eng = polish.Engine()
    monkeypatch.setattr(polish, "selected", lambda: None)
    r = eng.translate("在本地安装一下这个版本，我来测试一下。", "en", cloud=cloud(api), check=True)
    assert r["fell_back"] and r["reason"] == "auth" and r["text"] == "在本地安装一下这个版本，我来测试一下。"
    r = eng.translate("在本地安装一下这个版本，我来测试一下。", "en", check=True)
    assert r["fell_back"] and r["reason"] == "model_missing"
    with pytest.raises(polish.Fail):                                       # ⌥⇧T still says what failed
        eng.translate("在本地安装一下这个版本", "en")


# Settings → Models → Cloud services (2026-10-31): every preset speaks one of the two protocols; the fields that differ
# by service, and the one retry without them when a model refuses one.

@pytest.mark.parametrize("base, field, value", [
    ("https://api.deepseek.com", "thinking", {"type": "disabled"}),
    ("https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "enable_thinking", False),
    ("https://ark.cn-beijing.volces.com/api/v3", "thinking", {"type": "disabled"}),
    ("https://open.bigmodel.cn/api/paas/v4", "thinking", {"type": "disabled"}),
    ("https://api.z.ai/api/paas/v4", "thinking", {"type": "disabled"}),
    ("https://api.xiaomimimo.com/v1", "thinking", {"type": "disabled"}),
    ("https://openrouter.ai/api/v1", "reasoning", {"enabled": False}),
])
def test_thinking_is_turned_off_where_the_service_allows_it(base, field, value):
    url, body, _ = C.request({"base_url": base, "model": "m", "protocol": "openai", "key": "k"}, [], 50)
    assert url == base + "/chat/completions" and body[field] == value and body["max_tokens"] == 50


def test_openai_and_fixed_temperature_services_get_no_temperature():
    _, body, _ = C.request({"base_url": "https://api.openai.com/v1", "model": "m", "protocol": "openai", "key": "k"}, [], 50)
    assert "temperature" not in body and body["max_completion_tokens"] == 50 and "max_tokens" not in body
    for base in ("https://api.moonshot.ai/v1", "https://api.minimax.io/v1"):
        _, body, _ = C.request({"base_url": base, "model": "m", "protocol": "openai", "key": "k"}, [], 50)
        assert "temperature" not in body
    _, body, h = C.request({"base_url": "https://api.anthropic.com", "model": "m", "protocol": "anthropic", "key": "k"}, [], 50)
    assert "temperature" not in body and h["x-api-key"] == "k"


def test_a_refused_field_is_dropped_once_and_remembered(api):
    calls = []
    orig = C._send

    def send(url, body, headers, timeout):
        calls.append(dict(body))
        if "temperature" in body:
            raise C.urllib.error.HTTPError(url, 400, "bad", {}, None)
        return orig(url, body, headers, timeout)
    C._send = send
    try:
        cfg = C.settings(cloud(api))
        assert C.complete(cfg, [{"role": "user", "content": "u"}], 5, 50)["text"] == "OK"
        assert "temperature" in calls[0] and "temperature" not in calls[1]
        C.complete(cfg, [{"role": "user", "content": "u"}], 5, 50)
        assert len(calls) == 3 and "temperature" not in calls[2]          # remembered: one request
    finally:
        C._send = orig
        C._bare.clear()


def test_check_counts_an_answer_that_only_thought(api):
    api.reply = ""
    assert C.check(cloud(api))["ok"] is True
    with pytest.raises(C.CloudError):
        C.complete(C.settings(cloud(api)), [{"role": "user", "content": "u"}], 5, 50)


def test_a_key_no_header_can_carry_is_an_auth_failure_that_never_shows_the_key(api):
    # the founder's key ended in two "ç" as ⌥C types them: c + U+0327, which no header can carry
    r = C.check({**cloud(api), "key": "sk-test" + "c\u0327" * 2})
    assert r["ok"] is False and r["code"] == "auth" and "sk-test" not in json.dumps(r)
