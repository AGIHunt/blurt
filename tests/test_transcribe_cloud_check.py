"""Cloud speech failures that came back as a bare "error", and Settings' Test (`transcribe.py check-cloud`).

2026-10-31, the founder: Qwen3-ASR Flash chosen for dictation, every take "couldn't recognise". The key saved in
Settings ended in two "ç" (U+0063 U+0327 — what ⌥C types); the HTTP header can't carry them, urllib raised
UnicodeEncodeError, and the speech server answered {"code": "error"}. Now the key is checked first (an "auth" failure
that names the characters, never the key), and every way a request fails has a plain code. A local stand-in for the
service answers like DashScope / an OpenAI-compatible API. No network, no model.

  uv run pytest tests/test_transcribe_cloud_check.py -q
"""
from __future__ import annotations

import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import transcribe as T  # noqa: E402

KEY = "sk-test0000"
BAD_KEY = KEY + "çç"        # the shape the founder's key had: two decomposed ç after it


class Service(BaseHTTPRequestHandler):
    """DashScope's /chat/completions and OpenAI's /audio/transcriptions; 401 for any other key."""
    seen: list[dict] = []
    status = 200

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        j = json.loads(body) if self.headers.get("Content-Type") == "application/json" else {}
        Service.seen.append({"path": self.path, "auth": self.headers.get("Authorization"), "size": len(body),
                             "model": j.get("model"), "body": j})
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            code, out = 401, {"error": {"code": "invalid_api_key"}}
        elif Service.status != 200:
            code, out = Service.status, {"error": {"message": "rate" if Service.status == 429 else "refused"}}
        elif self.path.endswith("/multimodal-generation/generation"):     # Model Studio's own API, as measured
            m = j.get("model", "")
            if "realtime" in m:
                code, out = 200, {"output": {}}
            elif m.startswith(("qwen-audio", "fun-asr-flash")):
                code, out = 200, {"output": {"text": "Testing, one, two, three.", "sentence": {}}, "usage": {"duration": 2}}
            else:
                code, out = 400, {"code": "InvalidParameter", "message": "url error, please check url！"}
        elif self.path.endswith("/chat/completions") and "realtime" in j.get("model", ""):
            code, out = 500, {"error": {"code": "internal_error"}}
        elif self.path.endswith("/chat/completions") and (not j.get("model", "").startswith("qwen3-asr-flash")
                                                          or "filetrans" in j.get("model", "")):
            code, out = 404, {"error": {"message": f"Unsupported model `{j.get('model')}` for OpenAI compatibility mode.",
                                        "code": "model_not_supported"}}
        elif self.path.endswith("/chat/completions"):
            code, out = 200, {"choices": [{"message": {"content": "Testing, one, two, three."}}]}
        else:
            code, out = 200, {"text": "Testing one two three"}
        data = json.dumps(out).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_a):
        pass


class CloudCheck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), Service)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        Service.seen, Service.status = [], 200
        names = [n for v in T.CLOUD_ENV.values() for n in v.values()] + ["OPENAI_API_KEY", "GROQ_API_KEY", "BLURT_ASR_SPEED"]
        self.env = mock.patch.dict(os.environ, {n: "" for n in names})
        self.env.start()
        os.environ["BLURT_ASR_SPEED"] = "1"     # no ffmpeg pass: the clip goes as it is
        self.addCleanup(self.env.stop)
        # privacy.local_asr off, whatever this Mac's config says
        p = mock.patch.object(T, "local_only", return_value=False)
        p.start()
        self.addCleanup(p.stop)

    def test_key_with_characters_a_key_cant_have_is_auth_and_never_shown(self):
        os.environ["DASHSCOPE_API_KEY"] = BAD_KEY
        with self.assertRaises(T.Fail) as c:
            T.api_key("DASHSCOPE_API_KEY")
        self.assertEqual(c.exception.code, "auth")
        self.assertIn("U+0327", str(c.exception))
        self.assertNotIn(KEY, str(c.exception))
        # nothing went out
        r = T.cloud_check("qwen3-asr-flash", {"base_url": self.base})
        self.assertEqual((r["ok"], r["code"]), (False, "auth"))
        self.assertEqual(Service.seen, [])

    def test_key_is_trimmed(self):
        os.environ["DASHSCOPE_API_KEY"] = f"  {KEY}\n"
        self.assertEqual(T.api_key("DASHSCOPE_API_KEY"), KEY)

    def test_dashscope_check_ok_with_a_spoken_clip(self):
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["text"], "Testing, one, two, three.")
        self.assertTrue(r["heard"])
        self.assertEqual(Service.seen[0]["model"], "qwen3-asr-flash")
        self.assertEqual(len(Service.seen), 1)
        if r["spoken"]:                          # macOS `say`: real speech, more than half a second of it
            self.assertGreater(Service.seen[0]["size"], 30000)

    def test_dashscope_model_typed_in_settings(self):
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base, "model": "qwen3-asr-flash-2025-09-08"})
        self.assertTrue(r["ok"], r)
        self.assertEqual(Service.seen[0]["model"], "qwen3-asr-flash-2025-09-08")

    def test_wrong_key_is_auth(self):
        r = T.cloud_check("qwen3-asr-flash", {"key": "sk-other", "base_url": self.base})
        self.assertEqual((r["ok"], r["code"]), (False, "auth"))

    def test_rate_limit_is_quota_after_one_try(self):
        Service.status = 429
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base})
        self.assertEqual((r["ok"], r["code"]), (False, "quota"))
        self.assertEqual(len(Service.seen), 1)       # Settings' Test: one try, not four

    def test_unreachable_is_network(self):
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": "http://127.0.0.1:9/v1"})
        self.assertEqual((r["ok"], r["code"]), (False, "network"))

    def test_openai_compatible_check(self):
        r = T.cloud_check("openai-compatible", {"key": KEY, "base_url": self.base, "model": "whisper-large-v3-turbo"})
        self.assertTrue(r["ok"], r)
        self.assertEqual(Service.seen[0]["path"], "/v1/audio/transcriptions")

    def test_no_key_is_auth(self):
        r = T.cloud_check("qwen3-asr-flash", {"base_url": self.base})
        self.assertEqual((r["ok"], r["code"]), (False, "auth"))

    def test_local_model_is_usage(self):
        self.assertEqual(T.cloud_check("sensevoice-small")["code"], "usage")

    def test_privacy_local_only(self):
        with mock.patch.object(T, "local_only", return_value=True):
            r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base})
        self.assertEqual(r["code"], "privacy")
        self.assertEqual(Service.seen, [])

    # 2026-11-11: qwen-audio-3.1-asr-flash (千问音频 3.1) typed under Custom… went to chat/completions, which it isn't
    # served on; the 404 read "can't connect". Now the own API is asked next, and serves the model from then on.
    def test_qwen_audio_goes_to_model_studios_own_api(self):
        T._DASHSCOPE_OWN_API.discard("qwen-audio-3.1-asr-flash")      # as for any model not known to take only it
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base + "/compatible-mode/v1",
                                              "model": "qwen-audio-3.1-asr-flash"})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["text"], "Testing, one, two, three.")
        self.assertEqual(Service.seen[0]["path"], "/v1/compatible-mode/v1/chat/completions")      # refused: 404
        s = Service.seen[1]
        self.assertEqual(s["path"], "/v1/api/v1/services/aigc/multimodal-generation/generation")
        self.assertEqual(s["model"], "qwen-audio-3.1-asr-flash")
        self.assertEqual(s["body"]["parameters"], {"format": "wav", "sample_rate": "16000"})
        audio = s["body"]["input"]["messages"][-1]["content"][0]
        self.assertEqual(audio["type"], "input_audio")
        self.assertTrue(audio["input_audio"]["data"].startswith("data:audio/wav;base64,"))

    def test_native_request_carries_words_field_and_language(self):
        T._DASHSCOPE_OWN_API.add("qwen-audio-3.1-asr-flash")
        os.environ["DASHSCOPE_API_KEY"] = KEY
        os.environ["DASHSCOPE_BASE_URL"] = self.base + "/compatible-mode/v1"
        b = T.DashScope(type("A", (), {"model": "qwen-audio-3.1-asr-flash", "prompt": None, "language": "zh"})())
        b.speed = 1
        b.set_vocab([{"term": "Blurt"}, {"term": "口喷鸡"}])
        b.set_field("x" * 500 + "我刚截了")
        self.assertEqual(b.transcribe(T.np.zeros(1600, T.np.float32))[0][2], "Testing, one, two, three.")
        self.assertEqual(len(Service.seen), 1)        # known from the test before: straight to the own API
        body = Service.seen[0]["body"]
        self.assertEqual(body["parameters"]["vocabulary"], {"Blurt": 50, "口喷鸡": 50})
        self.assertEqual(body["parameters"]["language_hints"], ["zh"])
        ctx = body["input"]["messages"][0]
        self.assertEqual(ctx["role"], "user")
        self.assertEqual(len(ctx["content"][0]["text"]), 400)              # the service's limit: the end kept
        self.assertTrue(ctx["content"][0]["text"].endswith("我刚截了"))

    def test_any_model_that_works_on_either_api_is_used_none_blocked_by_name(self):
        T._DASHSCOPE_OWN_API.discard("qwen-audio-3.1-asr-flash")
        for m in ("qwen3-asr-flash", "qwen3-asr-flash-2025-09-08", "qwen-audio-3.1-asr-flash", "qwen-audio-3.0-asr-flash",
                  "fun-asr-flash-2026-06-15"):
            r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base, "model": m})
            self.assertTrue(r["ok"], (m, r))

    def test_super_hot_words_stop_at_50(self):
        T._DASHSCOPE_OWN_API.add("qwen-audio-3.1-asr-flash")
        os.environ["DASHSCOPE_API_KEY"] = KEY
        os.environ["DASHSCOPE_BASE_URL"] = self.base + "/compatible-mode/v1"
        b = T.DashScope(type("A", (), {"model": "qwen-audio-3.1-asr-flash", "prompt": None, "language": None})())
        b.speed = 1
        b.set_vocab([{"term": f"w{i}"} for i in range(60)])
        b.transcribe(T.np.zeros(1600, T.np.float32))
        v = Service.seen[0]["body"]["parameters"]["vocabulary"]
        self.assertEqual(sum(1 for w in v.values() if w == 50), 50)
        self.assertEqual(v["w59"], 5)

    def test_a_measured_own_api_model_goes_there_first(self):
        T._DASHSCOPE_OWN_API.add("qwen-audio-3.1-asr-flash")
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base, "model": "qwen-audio-3.1-asr-flash"})
        self.assertTrue(r["ok"], r)
        self.assertEqual([s["path"] for s in Service.seen], ["/api/v1/services/aigc/multimodal-generation/generation"])

    def test_models_that_only_stream_or_read_urls_say_so(self):
        # the answers measured 2026-11-11: realtime 500 on compatible, 200 without text on its own; URL-only 404 / 400
        for m in ("qwen3-asr-flash-realtime", "fun-asr-realtime", "qwen3-asr-flash-filetrans", "paraformer-v2", "fun-asr"):
            Service.seen = []
            r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base, "model": m})
            self.assertEqual((r["ok"], r["code"]), (False, "model"), m)
            self.assertEqual(len(Service.seen), 2, m)        # one try on each API
        self.assertNotIn("qwen3-asr-flash-realtime", T._DASHSCOPE_OWN_API)

    def test_a_refused_request_is_not_a_connection_problem(self):
        for status in (400, 404):
            Service.status = status
            r = T.cloud_check("openai-compatible", {"key": KEY, "base_url": self.base, "model": "whisper-9"})
            self.assertEqual((r["ok"], r["code"]), (False, "bad_response"), status)
        Service.status = 503
        r = T.cloud_check("qwen3-asr-flash", {"key": KEY, "base_url": self.base})
        self.assertEqual(r["code"], "network")
        # an address that isn't …/compatible-mode/v1: the same host's own API
        self.assertEqual(Service.seen[-1]["path"], "/api/v1/services/aigc/multimodal-generation/generation")

    def test_native_url_from_any_base(self):
        u = T.dashscope_native_url
        self.assertEqual(u("https://dashscope.aliyuncs.com/compatible-mode/v1"),
                         "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        self.assertEqual(u("https://ws1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/"),
                         "https://ws1.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        self.assertEqual(u("https://proxy.example.com/v1"),
                         "https://proxy.example.com/api/v1/services/aigc/multimodal-generation/generation")

    def test_answer_without_transcript_is_bad_response(self):
        with mock.patch.object(T, "_post", return_value={"output": {}}):
            os.environ["DASHSCOPE_API_KEY"] = KEY
            b = T.DashScope(type("A", (), {"model": None, "prompt": None, "language": None})())
            with self.assertRaises(T.Fail) as c:
                b.transcribe(T.np.zeros(1600, T.np.float32))
        self.assertEqual(c.exception.code, "model")       # no text from either API: the model, not the network


if __name__ == "__main__":
    unittest.main()
