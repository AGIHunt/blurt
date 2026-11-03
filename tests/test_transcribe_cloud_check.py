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
        Service.seen.append({"path": self.path, "auth": self.headers.get("Authorization"), "size": len(body),
                             "model": json.loads(body).get("model") if self.path.endswith("completions") else None})
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            code, out = 401, {"error": {"code": "invalid_api_key"}}
        elif Service.status != 200:
            code, out = Service.status, {"error": {"message": "rate"}}
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

    def test_answer_without_transcript_is_bad_response(self):
        with mock.patch.object(T, "_post", return_value={"output": {}}):
            os.environ["DASHSCOPE_API_KEY"] = KEY
            b = T.DashScope(type("A", (), {"model": None, "prompt": None, "language": None})())
            with self.assertRaises(T.Fail) as c:
                b.transcribe(T.np.zeros(1600, T.np.float32))
        self.assertEqual(c.exception.code, "bad_response")


if __name__ == "__main__":
    unittest.main()
