"""One warm model at a time, isolated from the desktop's dictation worker."""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time

from model_api_worker import PREFIX


class APIError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code


class WorkerPool:
    def __init__(self, command, *, idle=90, timeout=180):
        self.command = command
        self.idle = idle
        self.timeout = timeout
        self.gate = threading.Lock()
        self.stopping = threading.Event()
        self.process = None
        self.model = None
        self.used = 0
        self.completion = {}

    @staticmethod
    def _read(pipe, replies):
        try:
            with pipe:
                for line in pipe:
                    if line.startswith(PREFIX):
                        replies.put(json.loads(line[len(PREFIX):]))
        except (ValueError, OSError):
            pass
        finally:
            replies.put(("exit", ""))

    def retire(self):
        proc, self.process = self.process, None
        self.model = None
        if proc is None:
            return
        if proc.poll() is None:
            try:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                                   capture_output=True, timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
                else:
                    os.killpg(proc.pid, signal.SIGKILL)
            except (OSError, subprocess.TimeoutExpired):
                pass
            if proc.poll() is None:
                proc.kill()
        proc.wait()
        proc.stdin.close()

    def expire(self):
        if self.process is None or time.monotonic() - self.used <= self.idle:
            return
        if self.gate.acquire(blocking=False):
            try:
                if self.process and time.monotonic() - self.used > self.idle:
                    self.retire()
            finally:
                self.gate.release()

    def close(self):
        self.stopping.set()
        with self.gate:
            self.retire()

    def infer(self, kind, model, args):
        """Called with gate held. Closing the iterator early cancels and retires its worker."""
        if self.stopping.is_set():
            raise APIError(503, "stopping", "Service is stopping.")
        completed = False
        self.completion = {}
        try:
            if self.model != model or self.process is None or self.process.poll() is not None:
                self.retire()
                command = self.command(model, str(Path(__file__).with_name("model_api_worker.py")))
                options = ({"creationflags": subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS} if os.name == "nt"
                           else {"start_new_session": True})
                self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
                                                errors="replace", env={**os.environ, "HF_HUB_OFFLINE": "1",
                                                "TRANSFORMERS_OFFLINE": "1", "PYTHONUTF8": "1"}, **options)
                self.model = model
                self.replies = queue.Queue()
                threading.Thread(target=self._read, args=(self.process.stdout, self.replies), daemon=True).start()
            self.process.stdin.write(json.dumps([kind, [model, *args]]) + "\n")
            self.process.stdin.flush()
            deadline = time.monotonic() + self.timeout
            while not self.stopping.is_set():
                if time.monotonic() >= deadline:
                    raise APIError(504, "timeout", "Model timed out. Try a shorter input.")
                try:
                    tag, value = self.replies.get(timeout=0.25)
                except queue.Empty:
                    continue
                if tag == "done":
                    if isinstance(value, dict):
                        self.completion = {k: value[k] for k in ("finish_reason", "usage", "tool_calls") if k in value}
                        value = value["text"]
                    completed = True
                    if kind != "stream":
                        yield value
                    return
                if tag == "prompt_tokens":
                    self.completion["usage"] = {"prompt_tokens": value}
                    continue
                if tag == "context_length_exceeded":
                    # Validation finished before generation. The same worker can serve the next request.
                    completed = True
                    raise APIError(400, tag, f"The prompt uses {value['prompt_tokens']} tokens including tool definitions "
                                   f"and history. The model's context window is {value['context_window']} tokens. "
                                   "Shorten the history or tool definitions to leave room for a reply.")
                if tag == "delta":
                    yield value
                elif tag == "error" and value == "tool_generation_failed":
                    raise APIError(422, value, "Model did not produce a valid requested function call. Retry or simplify the tool definitions.")
                elif tag == "error" and value == "tools_unsupported":
                    raise APIError(400, value, "This model template does not support native tool calls.")
                elif tag == "error" and value == "invalid_input":
                    raise APIError(400, value, "Model could not read the input. Check format, size and duration.")
                elif tag == "error" and value == "model_not_found":
                    raise APIError(404, value, "Model is no longer available.")
                elif tag == "exit":
                    raise APIError(503, "runtime_unavailable", "Select this model in Blurt Settings > Models > External model API and choose Prepare runtime.")
                else:
                    raise APIError(503, "inference_failed", "Check the installed model and its local runtime in Blurt.")
            raise APIError(503, "stopping", "Service is stopping.")
        except (RuntimeError, LookupError, OSError) as exc:
            raise APIError(503, "runtime_unavailable", "The model runtime is unavailable. Try the model in Blurt first.") from exc
        finally:
            self.used = time.monotonic()
            if not completed:
                self.retire()
