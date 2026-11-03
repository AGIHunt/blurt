"""Volcengine Seed-ASR 2.0 (transcribe.py's `volcengine` backend and `serve` cmd "stream"; docs/design/dictation.md
§Cloud recognition, dictation-eval-2026-10-31.md §6.3 B′): the request as the eval measured it (the words as hotwords,
the field's text as a dialogue turn, no language for a Chinese speaker, automatic for others), the binary frames over
the standard-library websocket, the refusals in plain codes (a wrong token: auth; "quota exceeded for types:
concurrency": quota), and a take streamed through the server while it is said. A local stand-in for the service
speaks the protocol. No network, no key.

  uv run pytest tests/test_transcribe_volcengine.py -q
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import socket
import struct
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import transcribe as T  # noqa: E402

TOKEN = "tok-test"


class FakeVolc:
    """One websocket service on 127.0.0.1: 401 for any other token; else reads the request and the audio packets and,
    at the packet with a negative sequence, answers the final text (or, in `mode` "concurrency", refuses after the
    request)."""

    def __init__(self, mode: str = "ok", text: str = "测试一下 Blurt。"):
        self.mode, self.text = mode, text
        self.requests: list[dict] = []
        self.audio = 0
        self.seqs: list[int] = []
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(4)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}/api/v3/sauc/bigmodel_nostream"

    def serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.session, args=(c,), daemon=True).start()

    @staticmethod
    def read(c, n, buf):
        while len(buf[0]) < n:
            d = c.recv(65536)
            if not d:
                raise ConnectionError
            buf[0] += d
        out, buf[0] = buf[0][:n], buf[0][n:]
        return out

    def frame(self, c, buf) -> bytes:
        b0, b1 = self.read(c, 2, buf)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self.read(c, 2, buf))[0]
        elif n == 127:
            n = struct.unpack(">Q", self.read(c, 8, buf))[0]
        mask = self.read(c, 4, buf)
        p = self.read(c, n, buf)
        return bytes(x ^ mask[i % 4] for i, x in enumerate(p)), b0 & 0x0F

    @staticmethod
    def send(c, payload: bytes):
        n = len(payload)
        head = bytes([0x82]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack(">H", n))
        c.sendall(head + payload)

    def session(self, c):
        buf = [b""]
        head = b""
        while b"\r\n\r\n" not in head:
            head += c.recv(4096)
        top, _, rest = head.partition(b"\r\n\r\n")
        buf[0] = rest
        hdr = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in top.decode().split("\r\n")[1:])}
        if hdr.get("x-api-access-key") != TOKEN or hdr.get("x-api-resource-id") != T.VOLC_RESOURCE:
            body = b'{"error":"load grant: requested grant not found in SaaS storage"}'
            c.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            c.close()
            return
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  b"X-Tt-Logid: test\r\n\r\n")
        try:
            while True:
                p, op = self.frame(c, buf)
                if op == 0x8:
                    break
                kind, flags = p[1] >> 4, p[1] & 0x0F
                seq = struct.unpack(">i", p[4:8])[0]
                n = struct.unpack(">I", p[8:12])[0]
                body = p[12:12 + n]
                if p[2] & 0x0F == 1:
                    body = gzip.decompress(body)
                self.seqs.append(seq)
                if kind == 0b0001:
                    self.requests.append(json.loads(body))
                    if self.mode == "concurrency":
                        msg = b'{"error":"quota exceeded for types: concurrency"}'
                        self.send(c, bytes([0x11, 0xF0, 0x10, 0]) + struct.pack(">II", 45000292, len(msg)) + msg)
                        break
                    continue
                self.audio += len(body)
                if seq < 0:
                    out = gzip.compress(json.dumps({"result": {"text": self.text}}).encode())
                    self.send(c, bytes([0x11, 0x93, 0x11, 0]) + struct.pack(">iI", seq, len(out)) + out)
                    break
        except (ConnectionError, OSError):
            pass
        finally:
            c.close()

    def close(self):
        self.srv.close()


def args(language=None):
    return argparse.Namespace(model=None, model_id="volcengine-seedasr", language=language, prompt=None)


KEYS = {"VOLC_APP_ID": "1234567890", "VOLC_ACCESS_TOKEN": TOKEN}


class Request(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, KEYS)
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def test_words_as_hotwords_and_the_field_as_a_dialogue_turn(self):
        b = T.Volcengine(args())
        self.assertTrue(b.set_vocab([{"term": "Blurt"}, {"term": "Claude Code"}, {"term": " "}]))
        b.set_field("我们在聊 Typeless")
        with mock.patch.object(T, "user_languages", return_value=["zh", "en"]):
            r = b.request()
        ctx = json.loads(r["request"]["corpus"]["context"])
        self.assertEqual(ctx["hotwords"], [{"word": "Blurt"}, {"word": "Claude Code"}])
        self.assertEqual(ctx["context_type"], "dialog_ctx")
        self.assertEqual(ctx["context_data"], [{"text": "我们在聊 Typeless"}])
        self.assertEqual(r["audio"], {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1})
        # a Chinese speaker: the zh-en default (2.18 % against 2.84 % with automatic language, §3)
        self.assertNotIn("enable_auto_lang", r["request"])
        self.assertEqual(r["request"]["model_name"], "bigmodel")

    def test_automatic_language_for_others_and_the_language_the_user_set(self):
        b = T.Volcengine(args())
        with mock.patch.object(T, "user_languages", return_value=["en", "de"]):
            r = b.request()
        self.assertTrue(r["request"]["enable_auto_lang"])
        self.assertNotIn("corpus", r["request"])
        self.assertEqual(T.Volcengine(args("en")).request()["audio"]["language"], "en-US")
        r = T.Volcengine(args("zh")).request()
        self.assertNotIn("language", r["audio"])
        self.assertNotIn("enable_auto_lang", r["request"])

    def test_both_credentials_or_none(self):
        with mock.patch.dict(os.environ, {"VOLC_ACCESS_TOKEN": ""}):
            with self.assertRaises(T.Fail) as e:
                T.Volcengine(args())
            self.assertEqual(e.exception.code, "auth")
            self.assertFalse(T.installed(T.entry("volcengine-seedasr")), "the App ID alone is not a key")
            self.assertIsNotNone(T.backend_ready("volcengine"))
        self.assertTrue(T.installed(T.entry("volcengine-seedasr")))
        self.assertIsNone(T.backend_ready("volcengine"))

    def test_the_services_refusals_in_plain_codes(self):
        self.assertEqual(T.volc_fail(45000292, '{"error":"quota exceeded for types: concurrency"}').code, "quota")
        self.assertEqual(T.volc_fail(55000031, "server is busy").code, "quota")
        self.assertEqual(T.volc_fail(45000151, "invalid access token").code, "auth")
        self.assertEqual(T.volc_fail(45000081, "wait timeout").code, "network")
        self.assertEqual(T.volc_fail(45000001, "invalid param").code, "bad_response")

    def test_frames_round_trip(self):
        f = T.volc_frame(0b1001, 0b0011, 1, json.dumps({"result": {"text": "好"}}).encode(), -7)
        d, last = T.volc_parse(f)
        self.assertEqual(d["result"]["text"], "好")
        self.assertTrue(last)
        d, last = T.volc_parse(T.volc_frame(0b1001, 0b0001, 1, json.dumps({"result": {"text": "半"}}).encode(), 3))
        self.assertFalse(last)

    def test_a_backlog_is_waited_for_longer(self):
        self.assertEqual(T.final_wait(60, 60), T.STREAM_FINAL_WAIT)
        self.assertAlmostEqual(T.final_wait(150, 0), T.STREAM_FINAL_WAIT + 0.4 * 150)


class Session(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, KEYS)
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def test_a_whole_recording_through_one_session(self):
        svc = FakeVolc()
        try:
            with mock.patch.object(T, "VOLC_URL", svc.url):
                b = T.Volcengine(args())
                x = np.zeros(T.SR * 3 + 123, np.float32)
                r = b.transcribe(x)
            self.assertEqual(r[0][2], "测试一下 Blurt。")
            self.assertEqual(svc.audio, len(x) * 2)
            # the request first (sequence 1), then 200 ms packets, the last one negative
            self.assertEqual(svc.seqs[0], 1)
            self.assertEqual(svc.seqs[1:-1], list(range(2, len(svc.seqs))))
            self.assertEqual(svc.seqs[-1], -len(svc.seqs))
        finally:
            svc.close()

    def test_a_wrong_token_is_auth(self):
        svc = FakeVolc()
        try:
            with mock.patch.object(T, "VOLC_URL", svc.url), mock.patch.dict(os.environ, {"VOLC_ACCESS_TOKEN": "nope"}):
                with self.assertRaises(T.Fail) as e:
                    T.Volcengine(args()).transcribe(np.zeros(T.SR, np.float32))
            self.assertEqual(e.exception.code, "auth")
            self.assertIn("HTTP 401", str(e.exception))
        finally:
            svc.close()

    def test_too_many_sessions_is_quota(self):
        svc = FakeVolc(mode="concurrency")
        try:
            with mock.patch.object(T, "VOLC_URL", svc.url):
                with self.assertRaises(T.Fail) as e:
                    T.Volcengine(args()).transcribe(np.zeros(T.SR, np.float32))
            self.assertEqual(e.exception.code, "quota")
            self.assertIn("concurrency", str(e.exception))
        finally:
            svc.close()


class Stream(unittest.TestCase):
    """serve cmd "stream": the app's connection after its JSON line — PCM as it comes, shut at key-up, one answer."""

    def setUp(self):
        self.env = mock.patch.dict(os.environ, KEYS)
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def run_stream(self, req: dict, pcm: bytes, svc: FakeVolc) -> dict:
        app, srv = socket.socketpair()
        with mock.patch.object(T, "VOLC_URL", svc.url), mock.patch.object(T, "local_only", return_value=False):
            t = threading.Thread(target=T.serve_stream, args=(srv, req, pcm[:1001]))     # PCM after the line, odd
            t.start()
            for i in range(1001, len(pcm), 3200):
                app.sendall(pcm[i:i + 3200])
            app.shutdown(socket.SHUT_WR)
            buf = b""
            while not buf.endswith(b"\n"):
                d = app.recv(65536)
                if not d:
                    break
                buf += d
            t.join(10)
        app.close()
        return json.loads(buf)

    def test_a_take_streamed_while_it_is_said(self):
        svc = FakeVolc(text="這是測試")       # traditional → the user's script, as every recogniser's text
        try:
            pcm = T.volc_pcm(np.zeros(T.SR * 2, np.float32))
            with mock.patch.object(T, "chinese_script", return_value="hans"):
                r = self.run_stream({"model_id": "volcengine-seedasr", "vocab": [{"term": "Blurt"}], "app": "Slack",
                                     "before": "x" * 500, "language": "auto"}, pcm, svc)
            self.assertTrue(r["ok"], r)
            self.assertEqual(r["text"], "这是测试")
            self.assertTrue(r["streamed"] and r["biased"])
            self.assertEqual(r["audio_seconds"], 2.0)
            self.assertEqual(r["field_context"], 300)
            self.assertEqual(svc.audio, len(pcm))
            ctx = json.loads(svc.requests[0]["request"]["corpus"]["context"])
            self.assertEqual([h["word"] for h in ctx["hotwords"]], ["Slack", "Blurt"])
        finally:
            svc.close()

    def test_a_refusal_is_answered_after_the_audio(self):
        svc = FakeVolc(mode="concurrency")
        try:
            r = self.run_stream({"model_id": "volcengine-seedasr"}, T.volc_pcm(np.zeros(T.SR, np.float32)), svc)
            self.assertEqual((r["ok"], r["code"]), (False, "quota"))
        finally:
            svc.close()

    def test_a_model_that_cant_take_a_stream(self):
        svc = FakeVolc()
        try:
            r = self.run_stream({"model_id": "qwen3-asr-flash"}, b"\0" * 6400, svc)
            self.assertEqual((r["ok"], r["code"]), (False, "usage"))
            self.assertEqual(svc.requests, [])
        finally:
            svc.close()


if __name__ == "__main__":
    unittest.main()
