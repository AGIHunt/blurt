"""Exercise the wire protocol, worker supervision and actual detached CLI with synthetic inputs."""
import concurrent.futures
import contextlib
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "skills/blurt/scripts"
sys.path.insert(0, str(SCRIPTS))
from model_api_http import ModelHTTP
from model_api_pool import WorkerPool

FAKE = """
import json, os, pathlib, sys, time
for line in sys.stdin:
    kind, args = json.loads(line)
    def emit(tag, value): print("BLURT_MODEL_REPLY " + json.dumps([tag, value]), flush=True)
    if kind == "transcription":
        emit("done", str(pathlib.Path(args[1]).read_bytes() == b'clip'))
    elif kind == "ocr":
        emit("done", "read")
    elif args[1][-1]["content"] == "context overflow":
        emit("context_length_exceeded", {"prompt_tokens": 513, "context_window": 512})
    elif len(args) == 5 and args[4]["tools"]:
        fn = args[4]["tools"][0]["function"]
        emit("prompt_tokens", 8)
        emit("done", {"text": "", "finish_reason": "tool_calls", "usage": {
            "prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12}, "tool_calls": [
            {"id": "call_example", "type": "function", "function": {"name": fn["name"], "arguments": "{}"}}]})
    elif kind == "stream":
        emit("delta", "a")
        emit("delta", "b")
        emit("done", {"text": "", "finish_reason": "length", "usage": {
            "prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}})
    else:
        prompt = args[1][-1]["content"]
        if prompt == "slow": time.sleep(10)
        emit("done", str(os.getpid()))
"""


class Wire(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        script = Path(self.temp.name) / "engine.py"
        script.write_text(FAKE)
        self.pool = WorkerPool(lambda mid, _: [sys.executable, "-u", str(script)], timeout=3, idle=0.05)
        models = [{"id": m, "capability": m} for m in ["chat", "ocr", "transcription"]]
        self.http = ModelHTTP(("127.0.0.1", 0), "test-key", lambda: models, self.pool)
        t = threading.Thread(target=self.http.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        t.start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.pool.close)
        self.addCleanup(self.http.shutdown)

    def request(self, method, path, body=None, *, key="test-key", mime="application/json", headers=None):
        with contextlib.closing(http.client.HTTPConnection("127.0.0.1", self.http.server_port, timeout=5)) as c:
            c.request(method, "/v1/" + path, body, {"Authorization": "Bearer " + key, "Content-Type": mime, **(headers or {})})
            res = c.getresponse()
            return res.status, res.read().decode(), dict(res.getheaders())

    def chat(self, prompt, **opts):
        return self.request("POST", "chat/completions", json.dumps(
            {"model": "chat", "messages": [{"role": "user", "content": prompt}], **opts}))

    def test_models_auth_and_capability(self):
        self.assertEqual(self.request("GET", "models", key="wrong")[0], 401)
        status, body, _ = self.request("GET", "models")
        self.assertEqual(status, 200)
        self.assertEqual(len(json.loads(body)["data"]), 3)
        self.assertEqual(self.chat("x", model="missing")[0], 404)
        self.assertEqual(self.chat("x", model="transcription")[0], 400)
        self.assertEqual(self.chat("x", max_tokens=-2)[0], 400)
        self.assertEqual(self.chat("x", tools=[{}])[0], 400)

    def test_reuse_stream_and_expire(self):
        def pid():
            status, data, _ = self.chat("pid")
            self.assertEqual(status, 200, data)
            return json.loads(data)["choices"][0]["message"]["content"]
        first = pid()
        self.assertEqual(first, pid())
        status, events, headers = self.chat("stream", stream=True, stream_options={"include_usage": True})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "text/event-stream")
        self.assertIn('"content": "a"', events)
        self.assertIn('"content": "b"', events)
        self.assertIn('"finish_reason": "length"', events)
        self.assertIn('"total_tokens": 7', events)
        self.assertTrue(events.endswith("data: [DONE]\n\n"))
        time.sleep(0.08)
        self.pool.expire()
        self.assertIsNone(self.pool.process)
        self.assertNotEqual(first, pid())

    def test_provider_urls_auth_and_streamed_function_calls(self):
        history = [{"role": "user", "content": "Call lookup."}]
        tool = {"name": "lookup", "input_schema": {"type": "object", "properties": {}}}
        args = {"model": "chat", "messages": history, "tools": [tool], "stream": True, "max_tokens": 100}
        for path in ("messages", "v1/messages"):
            status, body, _ = self.request("POST", path, json.dumps(args), key="", headers={"x-api-key": "test-key"})
            self.assertEqual(status, 200, body)
            events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith("data: ")]
            self.assertEqual(events[0]["message"]["usage"]["input_tokens"], 8)
            self.assertEqual(events[1]["content_block"]["name"], "lookup")
            self.assertEqual(events[-2]["delta"]["stop_reason"], "tool_use")
            self.assertEqual(events[-1]["type"], "message_stop")
        args["tools"] = [{"type": "function", "function": {"name": "lookup", "parameters": tool["input_schema"]}}]
        for path in ("chat/completions", "v1/chat/completions"):
            status, body, _ = self.request("POST", path, json.dumps(args))
            self.assertEqual(status, 200, body)
            self.assertIn('"arguments": "{}"', body)
            self.assertIn('"finish_reason": "tool_calls"', body)
            self.assertTrue(body.endswith("data: [DONE]\n\n"))
        status, body, _ = self.request("POST", "messages", "{}", key="wrong")
        self.assertEqual((status, json.loads(body)["error"]["type"]), (401, "authentication_error"))

    def test_long_declarations_and_history_reach_worker_in_both_protocols(self):
        schema = {"type": "object", "properties": {}}
        description = "Read the named record. " * 3000
        history = [{"role": "user", "content": "Historical data. " * 4500}]
        for path, tool in (("messages", {"name": "lookup", "description": description, "input_schema": schema}),
                           ("chat/completions", {"type": "function", "function": {
                               "name": "lookup", "description": description, "parameters": schema}})):
            body = {"model": "chat", "max_tokens": 8, "messages": history, "tools": [tool]}
            status, response, _ = self.request("POST", path, json.dumps(body))
            self.assertEqual(status, 200, response)
            self.assertIn("call_example", response)

    def test_context_overflow_is_a_client_error_and_keeps_the_worker(self):
        self.pool.idle = 10
        before = self.chat("pid")[1]
        for path in ("chat/completions", "messages"):
            body = {"model": "chat", "max_tokens": 1, "stream": True,
                    "messages": [{"role": "user", "content": "context overflow"}]}
            status, response, _ = self.request("POST", path, json.dumps(body))
            error = json.loads(response)["error"]
            self.assertEqual(status, 400)
            self.assertIn("513", error["message"])
            self.assertIn("512", error["message"])
            if path == "chat/completions":
                self.assertEqual(error["code"], "context_length_exceeded")
        pid = lambda body: json.loads(body)["choices"][0]["message"]["content"]
        self.assertEqual(pid(before), pid(self.chat("pid")[1]))

    def test_busy_timeout_and_recovery(self):
        self.pool.timeout = 0.8
        with concurrent.futures.ThreadPoolExecutor() as ex:
            slow = ex.submit(self.chat, "slow")
            for _ in range(100):
                if self.pool.gate.locked():
                    break
                time.sleep(0.005)
            status, _, headers = self.chat("now")
            self.assertEqual((status, headers.get("Retry-After")), (429, "2"))
            self.assertEqual(slow.result()[0], 504)
        self.assertEqual(self.chat("again")[0], 200)

    def test_multipart_and_ocr(self):
        body = (b'--sample\r\nContent-Disposition: form-data; name="model"\r\n\r\ntranscription\r\n'
                b'--sample\r\nContent-Disposition: form-data; name="file"; filename="../../unsafe.wav"\r\n'
                b'Content-Type: audio/wav\r\n\r\nclip\r\n--sample--\r\n')
        status, result, _ = self.request("POST", "audio/transcriptions", body, mime="multipart/form-data; boundary=sample")
        self.assertEqual((status, json.loads(result)), (200, {"text": "True"}))
        def image(url):
            return self.chat([{"type": "image_url", "image_url": {"url": url}}], model="ocr")[0]
        self.assertEqual(image("file:///private/example.jpg"), 400)
        self.assertEqual(image("data:image/jpeg;base64,aW1hZ2U="), 200)


class Lifecycle(unittest.TestCase):
    def test_copy_stop_restart_and_rotation(self):
        with tempfile.TemporaryDirectory() as root:
            env = {**os.environ, "BLURT_HOME": root, "BLURT_WORKSPACE": str(Path(root) / "ws")}
            def cli(*args, ok=True):
                cmd = [sys.executable, str(SCRIPTS / "model_api.py"), *args]
                result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode == 0, ok, (args, result.stderr, result.stdout if "config" not in args else ""))
                return json.loads(result.stdout)
            self.assertFalse(cli("status")["running"])
            with socket.socket() as occupied:
                occupied.bind(("127.0.0.1", 0))
                occupied.listen()
                cli("start", "--port", str(occupied.getsockname()[1]), ok=False)
            try:
                started = cli("start", "--port", "0")
                self.assertTrue(started["running"])
                self.assertNotIn("api_key", started)
                self.assertEqual(started["base_url"], cli("start")["base_url"])
                self.assertNotIn("api_key", cli("status"))
                key = cli("config")["api_key"]
                self.assertFalse(started["needs_restart"])
                self.assertEqual(started["messages_base_url"] + "/v1", started["base_url"])
                # A daemon from the original Chat Completions build wrote no protocol revision.
                state_file = Path(root) / "model-api/state.json"
                previous = json.loads(state_file.read_text())
                previous.pop("protocol_revision")
                state_file.write_text(json.dumps(previous))
                self.assertTrue(cli("status")["needs_restart"])
                self.assertNotIn("messages_python_examples", cli("config"))
                cli("start", "--scope", "lan", ok=False)
                self.assertFalse(cli("stop")["running"])
                cli("config", ok=False)
                cli("start", "--port", "0")
                self.assertEqual(cli("config")["api_key"], key)
                self.assertFalse(cli("status")["needs_restart"])
                cli("stop")
                cli("rotate-key")
                cli("start", "--port", "0")
                self.assertNotEqual(cli("config")["api_key"], key)
            finally:
                cli("stop")
