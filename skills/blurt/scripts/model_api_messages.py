"""Translate the text and client-tool subset of Anthropic Messages at the HTTP boundary."""
import json


def _fields(value, allowed, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object.")
    unknown = value.keys() - allowed
    if unknown:
        raise ValueError(f"Unsupported {label} field: {min(unknown)}.")
    # Cache breakpoints affect billing/retention at Anthropic. No prompt cache is used locally.
    hint = value.get("cache_control")
    if hint is not None and (not isinstance(hint, dict) or hint.get("type") != "ephemeral"
                             or hint.get("ttl", "5m") not in ("5m", "1h")):
        raise ValueError("Expected an ephemeral cache_control breakpoint.")


def _identifier(value, label):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a nonempty string.")
    return value


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def _text_block(block):
    _fields(block, {"type", "text", "cache_control", "citations"}, "text block")
    if block.get("type") != "text" or not isinstance(block.get("text"), str) or block.get("citations"):
        raise ValueError("Expected a text block without citations.")
    return block["text"]


def _text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        raise ValueError("Expected a string or an array of text blocks.")
    return "\n".join(_text_block(block) for block in content)


def _tool_call(block):
    _fields(block, {"type", "id", "name", "input", "cache_control", "caller"}, "tool_use")
    if block.get("caller") not in (None, {"type": "direct"}):
        raise ValueError("Only client tool calls are supported.")
    if not isinstance(block.get("input"), dict):
        raise ValueError("tool_use input must be a JSON object.")
    return {"type": "function", "id": _identifier(block.get("id"), "tool_use id"),
            "function": {"name": _identifier(block.get("name"), "tool name"), "arguments": _json(block["input"])}}


def _tool_result(block, pending):
    _fields(block, {"type", "tool_use_id", "content", "is_error", "cache_control"}, "tool_result")
    call_id = _identifier(block.get("tool_use_id"), "tool_use_id")
    if call_id not in pending:
        raise ValueError("tool_result must match an immediately preceding tool_use.")
    pending.remove(call_id)
    content = _text(block.get("content", ""))
    if type(block.get("is_error", False)) is not bool:
        raise ValueError("is_error must be a boolean.")
    if block.get("is_error"):
        content = "Tool error: " + content
    return {"role": "tool", "tool_call_id": call_id, "content": content}


def _messages(history):
    if not isinstance(history, list) or not history:
        raise ValueError("Provide a nonempty messages array.")
    messages = []
    pending = set()
    for message in history:
        _fields(message, {"role", "content"}, "message")
        role, content = message.get("role"), message.get("content")
        if role not in ("user", "assistant"):
            raise ValueError("Message role must be user or assistant.")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list) or not content:
            raise ValueError("Messages require text or a nonempty content block array.")

        text, calls = [], []
        for block in content:
            if not isinstance(block, dict):
                raise ValueError("Each message content block must be an object.")
            kind = block.get("type")
            if kind == "tool_result" and role == "user":
                if text:
                    raise ValueError("tool_result blocks must precede user text.")
                messages.append(_tool_result(block, pending))
            elif kind == "text":
                text.append(_text_block(block))
            elif kind == "tool_use" and role == "assistant":
                calls.append(_tool_call(block))
            else:
                raise ValueError("Supported content is text, assistant tool_use, or user tool_result.")
        if pending:
            raise ValueError("Provide a tool_result for each preceding tool_use in the next user message.")
        if calls:
            pending = {call["id"] for call in calls}
            if len(calls) != len(pending):
                raise ValueError("Duplicate tool_use id in the same assistant message.")
            messages.append({"role": role, "content": "\n".join(text) or None, "tool_calls": calls})
        elif text:
            messages.append({"role": role, "content": "\n".join(text)})
    if pending:
        raise ValueError("Missing tool_result for the final tool_use.")
    return messages

def _tools(tools):
    if not isinstance(tools, list):
        raise ValueError("tools must be an array.")
    functions = []
    for tool in tools:
        _fields(tool, {"type", "name", "description", "input_schema", "cache_control", "strict"}, "tool")
        if tool.get("type", "custom") != "custom" or tool.get("strict", False) is not False:
            raise ValueError("Only non-strict custom client tools are supported.")
        schema = tool.get("input_schema")
        if not isinstance(schema, dict) or schema.get("type") != "object":
            raise ValueError("Tool input_schema must describe a JSON object.")
        function = {"name": _identifier(tool.get("name"), "tool name"), "parameters": schema}
        if "description" in tool:
            if not isinstance(tool["description"], str):
                raise ValueError("Tool description must be a string.")
            function["description"] = tool["description"]
        functions.append({"type": "function", "function": function})
    return functions


def to_chat_request(request):
    """Normalize an Anthropic request to the shared chat validator's input."""
    _fields(request, {"model", "messages", "system", "tools", "tool_choice", "max_tokens", "stream",
                      "temperature", "cache_control", "metadata", "thinking", "output_config", "stop_sequences"},
            "Messages request")
    # Adaptive thinking allows an immediate answer. The local runtime takes that path at every effort level.
    if request.get("thinking", {"type": "disabled"}) not in ({"type": "adaptive"}, {"type": "disabled"}):
        raise ValueError("Local models accept adaptive or disabled thinking without additional options.")
    output = request.get("output_config", {})
    _fields(output, {"effort"}, "output_config")
    if output.get("effort") not in (None, "low", "medium", "high", "xhigh", "max"):
        raise ValueError("output_config.effort must be low, medium, high, xhigh or max.")
    if request.get("stop_sequences", []) != []:
        raise ValueError("Custom stop sequences are unsupported by this runtime.")
    if "metadata" in request:
        metadata = request["metadata"]
        _fields(metadata, {"user_id"}, "metadata")
        if metadata.get("user_id") is not None and not isinstance(metadata["user_id"], str):
            raise ValueError("metadata.user_id must be a string.")
    limit = request.get("max_tokens")
    if type(limit) is not int or limit < 1:
        raise ValueError("max_tokens must be a positive integer.")
    temperature = request.get("temperature", 1)
    if type(temperature) not in (float, int) or not 0 <= temperature <= 1:
        raise ValueError("temperature must be between 0 and 1.")
    if type(request.get("stream", False)) is not bool:
        raise ValueError("stream must be a boolean.")
    messages = _messages(request.get("messages"))
    if "system" in request:
        messages.insert(0, {"role": "system", "content": _text(request["system"])})
    chat = {"model": _identifier(request.get("model"), "model"), "messages": messages,
            "max_tokens": limit, "temperature": temperature, "stream": request.get("stream", False)}
    if "tools" in request:
        chat["tools"] = _tools(request["tools"])
    if "tool_choice" in request:
        choice = request["tool_choice"]
        _fields(choice, {"type", "name", "disable_parallel_tool_use"}, "tool_choice")
        kind = choice.get("type")
        if kind == "tool":
            name = _identifier(choice.get("name"), "tool_choice name")
            chat["tool_choice"] = {"type": "function", "function": {"name": name}}
        elif kind in ("any", "auto", "none") and "name" not in choice:
            chat["tool_choice"] = "required" if kind == "any" else kind
        else:
            raise ValueError("tool_choice type must be auto, any, none, or tool with a name.")
        if "disable_parallel_tool_use" in choice:
            if type(choice["disable_parallel_tool_use"]) is not bool:
                raise ValueError("disable_parallel_tool_use must be a boolean.")
            chat["parallel_tool_calls"] = not choice["disable_parallel_tool_use"]
    return chat


def _usage(stats):
    usage = stats.get("usage", {})
    return {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0)}


def _tool_blocks(stats):
    for call in stats.get("tool_calls", []):
        function = call["function"]
        inputs = json.loads(function["arguments"])
        if not isinstance(inputs, dict):
            raise ValueError("Model tool arguments must be a JSON object.")
        yield {"type": "tool_use", "id": call["id"], "name": function["name"], "input": inputs}


def _stop_reason(stats):
    if stats.get("finish_reason") == "length":
        return "max_tokens"
    if stats.get("tool_calls"):
        return "tool_use"
    return "end_turn"


def _message(meta, content, reason, usage):
    return {"id": meta["id"], "type": "message", "role": "assistant", "model": meta["model"],
            "content": content, "stop_reason": reason, "stop_sequence": None, "usage": usage}


def message_response(meta, text, stats):
    content = [{"type": "text", "text": text}] if text else []
    content.extend(_tool_blocks(stats))
    return _message(meta, content, _stop_reason(stats), _usage(stats))


def _event(kind, **fields):
    return kind, {"type": kind, **fields}


def message_events(meta, values, get_stats):
    """Text streams immediately. The worker returns parsed, complete tool calls at EOF."""
    initial_usage = _usage(get_stats())
    initial_usage["output_tokens"] = 0
    yield _event("message_start", message=_message(meta, [], None, initial_usage))
    index = 0
    has_text = False
    for text in values:
        if not text:
            continue
        if not has_text:
            yield _event("content_block_start", index=index, content_block={"type": "text", "text": ""})
            has_text = True
        yield _event("content_block_delta", index=index, delta={"type": "text_delta", "text": text})
    if has_text:
        yield _event("content_block_stop", index=index)
        index += 1
    stats = get_stats()
    for block in _tool_blocks(stats):
        inputs = block.pop("input")
        yield _event("content_block_start", index=index, content_block={**block, "input": {}})
        yield _event("content_block_delta", index=index, delta={"type": "input_json_delta", "partial_json": _json(inputs)})
        yield _event("content_block_stop", index=index)
        index += 1
    yield _event("message_delta", delta={"stop_reason": _stop_reason(stats), "stop_sequence": None}, usage=_usage(stats))
    yield _event("message_stop")
