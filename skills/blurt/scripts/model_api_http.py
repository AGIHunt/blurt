"""Local model HTTP endpoints for OpenAI Chat Completions and Anthropic Messages clients."""
import base64
import binascii
from contextlib import closing, contextmanager
from email import policy
from email.parser import BytesParser
import hmac
from itertools import chain
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import re
import secrets
import socket
import tempfile
import threading
import time
from urllib.parse import urlsplit

import model_api_messages as messages_api
from model_api_pool import APIError

MIB = 1024 * 1024
AUDIO_LIMIT = 25 * MIB
IMAGE_LIMIT = 5 * MIB
FUNCTION_NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")



def invalid(message):
    return APIError(400, "invalid_request", message)


def multipart(content_type, body):
    if not content_type.lower().startswith("multipart/form-data;"):
        raise invalid("Use multipart/form-data with model and file fields.")
    if "\r" in content_type or "\n" in content_type:
        raise invalid("Invalid Content-Type.")
    message = BytesParser(policy=policy.default).parsebytes(
        b"Content-Type: " + content_type.encode("latin1") + b"\r\n\r\n" + body)
    if not message.is_multipart() or message.defects:
        raise invalid("Malformed multipart request.")
    fields = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="Content-Disposition")
        if part.is_multipart() or name not in ("file", "model", "language", "response_format") or name in fields:
            raise invalid("Unexpected or duplicate transcription field.")
        data = part.get_payload(decode=True)
        if name == "file":
            if len(data) > AUDIO_LIMIT:
                raise APIError(413, "upload_too_large", "Audio exceeds 25 MiB.")
            fields[name] = data
        else:
            if len(data) > 512:
                raise invalid("Transcription field is too long.")
            fields[name] = data.decode("utf-8")
    if not fields.get("file"):
        raise invalid("An audio file is required.")
    return fields


def function_name(value):
    if not isinstance(value, str) or not FUNCTION_NAME.fullmatch(value):
        raise invalid("Expected a function name of 1–64 letters, digits, underscores or hyphens.")
    return value


def tool_options(req):
    tools = req.get("tools", [])
    if not isinstance(tools, list) or len(tools) > 128:
        raise invalid("Provide at most 128 function tools.")
    definitions = []
    names = set()
    for tool in tools:
        if not isinstance(tool, dict) or tool.get("type") != "function" or not isinstance(tool.get("function"), dict):
            raise invalid("Only client-defined function tools are supported.")
        fn = tool["function"]
        name = function_name(fn.get("name"))
        params = fn.get("parameters", {"type": "object", "properties": {}})
        desc = fn.get("description", "")
        if name in names or not isinstance(params, dict) or not isinstance(desc, str):
            raise invalid("Each function must have a unique name and an object parameter schema.")
        if fn.get("strict") is True:
            raise invalid("Strict schema-constrained decoding is not supported.")
        definitions.append({"type": "function", "function": {"name": name, "description": desc, "parameters": params}})
        names.add(name)
    choice = req.get("tool_choice", "auto" if tools else "none")
    if isinstance(choice, dict):
        if (choice.get("type") != "function" or not isinstance(choice.get("function"), dict)
                or function_name(choice["function"].get("name")) not in names):
            raise invalid("tool_choice must name one of the declared functions.")
    elif choice not in ("none", "auto", "required") or (choice == "required" and not tools):
        raise invalid("Invalid tool_choice for the declared tools.")
    parallel = req.get("parallel_tool_calls", True)
    if type(parallel) is not bool:
        raise invalid("parallel_tool_calls must be a boolean.")
    return {"tools": definitions, "tool_choice": choice, "parallel_tool_calls": parallel}


def history_call(call):
    if not isinstance(call, dict) or call.get("type") != "function" or not isinstance(call.get("function"), dict):
        raise invalid("Malformed assistant tool call.")
    cid = call.get("id")
    if not isinstance(cid, str) or not 0 < len(cid) <= 256:
        raise invalid("A tool call must have an ID.")
    fn = call["function"]
    name = function_name(fn.get("name"))
    args = fn.get("arguments")
    if not isinstance(args, str) or not isinstance(json.loads(args), dict):
        raise invalid("Function arguments must be a JSON object encoded as a string.")
    return {"id": cid, "type": "function", "function": {"name": name, "arguments": args}}


def parse_messages(messages):
    if not isinstance(messages, list) or not 0 < len(messages) <= 128:
        raise invalid("Provide between 1 and 128 messages.")
    text_messages, image = [], None
    pending, seen = {}, set()
    for msg in messages:
        if not isinstance(msg, dict) or msg.get("role") not in ("user", "assistant", "system", "developer", "tool"):
            raise invalid("Unsupported message role.")
        role = msg["role"]
        if pending and role != "tool":
            raise invalid("Return a result for each outstanding tool call before continuing.")
        calls = []
        if "tool_calls" in msg:
            if role != "assistant" or not isinstance(msg["tool_calls"], list) or not 1 <= len(msg["tool_calls"]) <= 128:
                raise invalid("Invalid assistant tool_calls array.")
            for obj in msg["tool_calls"]:
                call = history_call(obj)
                if call["id"] in seen:
                    raise invalid("Duplicate tool call ID.")
                seen.add(call["id"])
                pending[call["id"]] = call["function"]["name"]
                calls.append(call)
        content = msg.get("content")
        if calls and content is None:
            content = ""

        if isinstance(content, list):
            parts = []
            for part in content:
                if not isinstance(part, dict):
                    raise invalid("Invalid message content.")
                if part.get("type") == "text" and isinstance(part.get("text"), str):
                    parts.append(part["text"])
                elif part.get("type") == "image_url" and image is None and msg["role"] == "user":
                    source = part.get("image_url")
                    url = source.get("url") if isinstance(source, dict) else None
                    if not isinstance(url, str) or not url.startswith(("data:image/png;base64,", "data:image/jpeg;base64,")):
                        raise invalid("Supply an inline base64 PNG or JPEG image.")
                    try:
                        image = base64.b64decode(url.split(",", 1)[1], validate=True)
                    except (binascii.Error, ValueError):
                        raise invalid("Invalid image encoding.")
                    if not image or len(image) > IMAGE_LIMIT:
                        raise invalid("Image must be between 1 byte and 5 MiB.")
                else:
                    raise invalid("Unsupported content. Supply text or a single OCR image.")
            content = "\n".join(parts)
        if not isinstance(content, str):
            raise invalid("Message content must be text or a content array.")
        row = {"role": "system" if role == "developer" else role, "content": content}
        if calls:
            row["tool_calls"] = calls
        if role == "tool":
            cid = msg.get("tool_call_id")
            if not isinstance(cid, str) or cid not in pending:
                raise invalid("A tool result must match an outstanding tool call ID.")
            row.update(tool_call_id=cid, name=pending.pop(cid))
        text_messages.append(row)
    if pending:
        raise invalid("Tool results are missing.")
    return text_messages, image


@contextmanager
def uploaded(data, suffix):
    with tempfile.TemporaryDirectory(prefix="blurt-model-") as directory:
        path = Path(directory) / ("input" + suffix)
        path.write_bytes(data)
        yield str(path)


class ModelHTTP(ThreadingHTTPServer):
    allow_reuse_address = os.name != "nt"
    def __init__(self, addr, token, models, pool):
        self.token = token
        self.models = models
        self.pool = pool
        self.connections = threading.BoundedSemaphore(12)
        self.clients = set()
        self.client_lock = threading.Lock()
        super().__init__(addr, Handler)

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def process_request(self, request, client_address):
        if not self.connections.acquire(blocking=False):
            self.shutdown_request(request)
            return
        with self.client_lock:
            self.clients.add(request)
        super().process_request(request, client_address)

    def interrupt_clients(self):
        with self.client_lock:
            for client in self.clients:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.client_lock:
                self.clients.discard(request)
            self.connections.release()


class Handler(BaseHTTPRequestHandler):
    timeout = 15
    server_version = "Blurt"
    # Uploaded text, images and credentials do not belong in access logs.
    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, *")
        self.end_headers()

    def send_data(self, status, obj, mime="application/json"):
        data = (json.dumps(obj, ensure_ascii=True) if mime == "application/json" else obj).encode("utf-8")
        self.release_slot()
        self.send_response(status)
        if status == 429:
            self.send_header("Retry-After", "2")
        if status == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self, limit):
        length = self.headers.get("Content-Length", "")
        if not re.fullmatch(r"[0-9]{1,10}", length) or self.headers.get("Transfer-Encoding"):
            raise APIError(411, "length_required", "Send the request with a Content-Length.")
        size = int(length)
        if size > limit:
            raise APIError(413, "upload_too_large", "Request exceeds the upload limit.")
        data = bytearray()
        deadline = time.monotonic() + 45
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise APIError(408, "upload_timeout", "Upload took too long.")
            self.connection.settimeout(min(self.timeout, remaining))
            piece = self.rfile.read1(min(65536, size - len(data)))
            if not piece:
                raise invalid("Incomplete request.")
            data.extend(piece)
        self.connection.settimeout(self.timeout)
        return data

    def model(self, mid, capabilities):
        for model in self.server.models():
            if model["id"] == mid:
                if model["capability"] not in capabilities:
                    raise invalid("Model does not support this endpoint.")
                return model["capability"]
        raise APIError(404, "model_not_found", "Select an installed model from /v1/models.")

    def release_slot(self):
        if getattr(self, "owns_slot", False):
            self.owns_slot = False
            self.server.pool.gate.release()

    @property
    def api_path(self):
        path = urlsplit(self.path).path.rstrip("/")
        # A provider may append /v1 itself or ask for a base URL which already contains it.
        if path in ("/messages", "/chat/completions", "/models"):
            return "/v1" + path
        if path in ("/v1/v1/messages", "/v1/v1/chat/completions", "/v1/v1/models"):
            return path.removeprefix("/v1")
        return path

    def route(self):
        path = self.api_path
        bearer = self.headers.get("Authorization", "").encode("utf-8")
        key = self.headers.get("x-api-key", "").encode("utf-8")
        if not (hmac.compare_digest(bearer, ("Bearer " + self.server.token).encode("ascii"))
                or hmac.compare_digest(key, self.server.token.encode("ascii"))):
            raise APIError(401, "invalid_api_key", "Supply the API key copied from Blurt.")
        if self.command == "GET" and path == "/v1/models":
            models = self.server.models()
            if self.headers.get("anthropic-version"):
                rows = [{"id": m["id"], "type": "model", "display_name": m.get("name", m["id"]),
                         "created_at": "1970-01-01T00:00:00Z"} for m in models if m["capability"] == "chat"]
                return self.send_data(200, {"data": rows, "has_more": False,
                                           "first_id": rows[0]["id"] if rows else None, "last_id": rows[-1]["id"] if rows else None})
            return self.send_data(200, {"object": "list", "data": [
                {"id": m["id"], "object": "model", "created": 0, "owned_by": "blurt", "capability": m["capability"]}
                for m in models]})
        if self.command != "POST" or path not in ("/v1/chat/completions", "/v1/audio/transcriptions", "/v1/messages"):
            raise APIError(404, "unknown_endpoint", "Unknown API endpoint.")
        if not self.server.pool.gate.acquire(blocking=False):
            raise APIError(429, "model_busy", "Another request is running. Retry shortly.")
        self.owns_slot = True
        try:
            if path.endswith("/transcriptions"):
                fields = multipart(self.headers.get("Content-Type", ""), self.read_body(AUDIO_LIMIT + 65536))
                mid = fields.get("model")
                self.model(mid, {"transcription"})
                form = fields.get("response_format", "json")
                if form not in ("json", "text"):
                    raise invalid("Supported response_format values are json and text.")
                lang = fields.get("language")
                if lang and not re.fullmatch(r"[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})?", lang):
                    raise invalid("Invalid language code.")
                with uploaded(fields["file"], ".audio") as audio:
                    text = self.result("transcription", mid, [audio, lang])
                if form == "text":
                    return self.send_data(200, text, "text/plain")
                return self.send_data(200, {"text": text})
            req = json.loads(self.read_body(7 * MIB))
            is_messages = path == "/v1/messages"
            if is_messages:
                try:
                    req = messages_api.to_chat_request(req)
                except ValueError as e:
                    raise invalid(str(e)) from e
            self.complete(req, is_messages)
        finally:
            self.release_slot()

    def result(self, kind, mid, args):
        with closing(self.server.pool.infer(kind, mid, args)) as values:
            return "".join(values)

    def complete(self, req, is_messages=False):
        if not isinstance(req, dict):
            raise invalid("Expected a JSON object.")
        unsupported = set(req) - {"model", "messages", "stream", "stream_options", "temperature", "max_tokens", "max_completion_tokens", "n", "user",
                                  "tools", "tool_choice", "parallel_tool_calls"}
        if unsupported:
            raise invalid("Unsupported chat fields: " + ", ".join(sorted(unsupported)) + ".")
        if req.get("n", 1) != 1:
            raise invalid("Only one completion per request is supported.")
        mid = req.get("model")
        cap = self.model(mid, {"chat", "ocr"})
        if is_messages and cap != "chat":
            raise invalid("Select a chat model for Messages.")
        opts = tool_options(req)
        msgs, image = parse_messages(req.get("messages"))
        limit = req.get("max_completion_tokens", req.get("max_tokens", 512))
        temperature = req.get("temperature", 0.7)
        stream = req.get("stream", False)
        options = req.get("stream_options", {})
        if not isinstance(options, dict) or set(options) - {"include_usage"} or type(options.get("include_usage", False)) is not bool:
            raise invalid("Supported stream_options: include_usage.")
        usage = options.get("include_usage", False)
        if usage and (not stream or cap != "chat"):
            raise invalid("Streaming token usage requires a chat model and stream=true.")
        if type(limit) is not int or limit < 1 or type(stream) is not bool:
            raise invalid("max_tokens must be positive and stream must be a boolean.")
        if type(temperature) not in (float, int) or not 0 <= temperature <= 2 or not math.isfinite(temperature):
            raise invalid("temperature must be between 0 and 2.")
        if (cap == "ocr") != (image is not None):
            raise invalid("OCR models require one image. Chat models accept text.")
        if cap != "chat" and (opts["tools"] or any(m.get("tool_calls") or m["role"] == "tool" for m in msgs)):
            raise invalid("Only chat models can use function tools.")
        args = [msgs, min(limit, 2048), temperature]
        if opts["tools"] or any(m.get("tool_calls") or m["role"] == "tool" for m in msgs):
            args.append(opts)
        meta = {"id": ("msg_" if is_messages else "chatcmpl-") + secrets.token_hex(12), "created": int(time.time()), "model": mid}
        if image is not None:
            with uploaded(image, ".png" if image.startswith(b"\x89PNG") else ".jpg") as path:
                output = self.result("ocr", mid, [path])
            if stream:
                return self.stream_response(meta, iter([output]))
        elif stream:
            with closing(self.server.pool.infer("stream", mid, args)) as values:
                if is_messages:
                    return self.messages_stream(meta, values)
                return self.stream_response(meta, values, usage)
        else:
            output = self.result("chat", mid, args)
        stats = self.server.pool.completion
        if is_messages:
            return self.send_data(200, messages_api.message_response(meta, output, stats))
        message = {"role": "assistant", "content": output}
        if stats.get("tool_calls"):
            message.update(content=output or None, tool_calls=stats["tool_calls"])
        self.send_data(200, {**meta, **({"usage": stats["usage"]} if "usage" in stats else {}),
                             "object": "chat.completion", "choices": [{"index": 0, "finish_reason": stats.get("finish_reason", "stop"),
                              "message": message}]})

    def stream_response(self, meta, values, include_usage=False):
        # Get the first token before committing 200 so load failures reach SDKs as normal HTTP errors.
        first = next(values, "")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        def event(delta, finish=None):
            payload = {**meta, "object": "chat.completion.chunk", "choices": [
                {"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
            self.wfile.flush()
        event({"role": "assistant", "content": first})
        try:
            for piece in values:
                event({"content": piece})
            stats = self.server.pool.completion
            self.release_slot()
            for i, call in enumerate(stats.get("tool_calls", [])):
                event({"tool_calls": [{"index": i, **call}]})
            event({}, stats.get("finish_reason", "stop"))
            if include_usage and "usage" in stats:
                chunk = {**meta, "object": "chat.completion.chunk", "choices": [], "usage": stats["usage"]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        except APIError as exc:
            self.wfile.write(("data: " + json.dumps(error_body(exc)) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def messages_stream(self, meta, values):
        first = next(values, None)
        pieces = values if first is None else chain((first,), values)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        def write(event, payload):
            self.wfile.write(("event: " + event + "\ndata: " + json.dumps(payload) + "\n\n").encode())
            self.wfile.flush()
        try:
            for name, payload in messages_api.message_events(meta, pieces, lambda: self.server.pool.completion):
                if name == "message_stop":
                    self.release_slot()
                write(name, payload)
        except APIError as exc:
            write("error", self.error_body(exc))

    def error_body(self, exc):
        if self.api_path == "/v1/messages" or self.headers.get("anthropic-version"):
            types = {400: "invalid_request_error", 401: "authentication_error", 404: "not_found_error",
                     413: "request_too_large", 429: "rate_limit_error", 503: "overloaded_error"}
            return {"type": "error", "error": {"type": types.get(exc.status, "api_error"), "message": str(exc)}}
        return error_body(exc)

    def dispatch(self):
        try:
            try:
                self.route()
            except APIError as exc:
                self.send_data(exc.status, self.error_body(exc))
            except (ValueError, UnicodeError, RecursionError):
                self.send_data(400, self.error_body(invalid("Invalid request encoding or content.")))
            except (ConnectionError, TimeoutError):
                return
            except Exception:
                self.send_data(500, self.error_body(APIError(500, "service_error", "Model service could not complete the request.")))
        except OSError:
            pass

    do_GET = do_POST = dispatch


def error_body(exc):
    return {"error": {"message": str(exc), "type": "invalid_request_error" if exc.status < 500 else "server_error",
                      "code": exc.code, "param": None}}
