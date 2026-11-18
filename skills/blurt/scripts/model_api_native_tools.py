"""Adapt the local tokenizer's native tool syntax to the external API pipe protocol."""
import json
import uuid


class ToolsUnsupported(Exception):
    pass


class ToolGenerationError(Exception):
    pass


def template_messages(messages):
    """Model templates format argument objects themselves; the API transports them as JSON strings."""
    result = []
    for message in messages:
        if not message.get("tool_calls"):
            result.append(message)
            continue
        calls = []
        for call in message["tool_calls"]:
            function = call["function"]
            arguments = json.loads(function["arguments"])
            if not isinstance(arguments, dict):
                raise ValueError("Tool call arguments must be a JSON object.")
            calls.append({**call, "function": {**function, "arguments": arguments}})
        result.append({**message, "tool_calls": calls})
    return result


class NativeReply:
    def __init__(self, tokenizer, messages, options):
        self.tools = options.get("tools", [])
        choice = options.get("tool_choice", "auto")
        self.force = choice == "required" or isinstance(choice, dict)
        self.parallel = options.get("parallel_tool_calls", True)
        self.start = getattr(tokenizer, "tool_call_start", None)
        end = getattr(tokenizer, "tool_call_end", None)
        self.parse = getattr(tokenizer, "tool_parser", None)
        history = any(m.get("tool_calls") or m["role"] == "tool" for m in messages)
        if (history or (self.tools and choice != "none")) and not (self.start and end and self.parse):
            raise ToolsUnsupported()
        if choice == "none":
            self.tools = []
        elif isinstance(choice, dict):
            name = choice["function"]["name"]
            self.tools = [t for t in self.tools if t["function"]["name"] == name]
        if self.force and not self.tools:
            raise ValueError("The chosen function must be declared.")
        self.names = {t["function"]["name"] for t in self.tools}

        # Split decoded text, since tokenizers can merge a marker's boundary with adjacent text.
        # Only markers relevant to the current state can trigger a transition.
        thinking = getattr(tokenizer, "think_start", None)
        thought_end = getattr(tokenizer, "think_end", None)
        self.markers = {
            "text": {k: v for k, v in ((self.start, "call"), (end, "invalid"), (thinking, "thought")) if k},
            "call": {end: "text", self.start: "invalid"},
            "thought": {thought_end: "text"} if thought_end else {},
        }
        if self.start == "<|tool_call>":
            # Some Gemma conversions decode the response boundary instead of treating it as EOS.
            self.markers["text"].update({"<|tool_response>": "wait_result", "<tool_response|>": "invalid",
                                         "<|tool>": "invalid", "<tool|>": "invalid"})
        elif self.start == "<tool_call>":
            self.markers["text"].update({"<tool_response>": "wait_result", "</tool_response>": "invalid"})
        self.state = "call" if self.force else "text"
        self.pending = ""
        self.call_body = []
        self.calls = []
        self.complete = False

    def _close_call(self):
        try:
            parsed = self.parse("".join(self.call_body), self.tools)
            functions = parsed if isinstance(parsed, list) else [parsed]
            if not functions:
                raise ToolGenerationError()
            for function in functions:
                name = function["name"]
                args = function["arguments"]
                if name not in self.names or not isinstance(args, dict):
                    raise ToolGenerationError()
                self.calls.append({"id": "call_" + uuid.uuid4().hex, "type": "function", "function": {
                    "name": name, "arguments": json.dumps(args, ensure_ascii=False, allow_nan=False)}})
                if not self.parallel:
                    self.complete = True
                    break
        except (KeyError, TypeError, ValueError, OverflowError, RecursionError) as exc:
            raise ToolGenerationError() from exc
        self.call_body.clear()

    def feed(self, piece):
        """Yield only visible text, retaining incomplete delimiter prefixes between pieces."""
        self.pending += piece
        while self.pending and not self.complete:
            markers = self.markers[self.state]
            hits = [(pos, marker) for marker in markers if (pos := self.pending.find(marker)) >= 0]
            if hits:
                end, marker = min(hits)
            else:
                # Keep the longest suffix that could become a delimiter with the next token.
                limit = min(len(self.pending), max(map(len, markers), default=1) - 1)
                keep = next((n for n in range(limit, 0, -1)
                             if any(m.startswith(self.pending[-n:]) for m in markers)), 0)
                end, marker = len(self.pending) - keep, ""
            text, self.pending = self.pending[:end], self.pending[end + len(marker):]
            if self.state == "call":
                self.call_body.append(text)
            elif self.state == "text" and text:
                yield text
            if not marker:
                return
            following = markers[marker]
            if following == "wait_result":
                if not self.calls:
                    raise ToolGenerationError()
                self.complete = True
                return
            if following == "invalid" or (following == "call" and not self.names):
                raise ToolGenerationError()
            if self.state == "call":
                self._close_call()
            self.state = following

    def finish(self, reason):
        if self.state == "call" or (self.force and not self.calls):
            raise ToolGenerationError()
        if self.state == "text" and self.pending and not self.complete:
            # A generation cap can split a marker before it enters the call state.
            # At a natural stop preserve ordinary text such as an isolated '<'.
            if (len(self.pending) >= 2 or reason == "length") and any(
                    m and m.startswith(self.pending) for m in self.markers["text"]):
                if self.pending.startswith(("<|tool", "<tool_", "</tool_")):
                    raise ToolGenerationError()
                return ""
            return self.pending
        return ""
