"""Messages API wire contract against the shared local chat request and result types."""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
from model_api_messages import message_events, message_response, to_chat_request


META = {"id": "msg_test", "model": "local", "created": 123}
REQUEST = {"model": "local", "max_tokens": 8192, "messages": [{"role": "user", "content": "hello"}]}
TOOL = {"name": "weather", "description": "Get local weather", "input_schema": {"type": "object"}}
CALL = {"id": "call_1", "type": "function", "function": {"name": "weather", "arguments": '{"city":"杭州"}'}}
USE = {"type": "tool_use", "id": "call_1", "name": "weather", "input": {"city": "杭州"}}
RESULT = {"type": "tool_result", "tool_use_id": "call_1", "content": [{"type": "text", "text": "Sunny"}]}
USAGE = {"prompt_tokens": 41, "completion_tokens": 9, "total_tokens": 50}


def test_system_blocks_metadata_and_generation_fields():
    cache = {"type": "ephemeral"}
    req = {**REQUEST, "system": [{"type": "text", "text": "a", "cache_control": cache},
                                {"type": "text", "text": "b"}], "cache_control": cache,
           "metadata": {"user_id": "local-client"}, "stream": True, "temperature": 0, "stop_sequences": []}
    assert to_chat_request(req) == {"model": "local", "max_tokens": 8192, "stream": True, "temperature": 0,
                                    "messages": [{"role": "system", "content": "a\nb"}, *REQUEST["messages"]]}
    assert to_chat_request({**REQUEST, "system": "simple"})["messages"][0]["content"] == "simple"


@pytest.mark.parametrize("effort", [None, "low", "medium", "high", "max", "xhigh"])
def test_custom_provider_adaptive_thinking_can_answer_directly(effort):
    req = {**REQUEST, "thinking": {"type": "adaptive"}, "stream": True, "tools": [TOOL],
           "metadata": {"user_id": "client"}, "system": [{"type": "text", "text": "Use tools when needed.",
                                                           "cache_control": {"type": "ephemeral"}}]}
    if effort is not None:
        req["output_config"] = {"effort": effort}
    expected = {key: value for key, value in req.items() if key not in ("thinking", "output_config")}
    assert to_chat_request(req) == to_chat_request(expected)


@pytest.mark.parametrize(("fields", "error"), [
    ({"thinking": {"type": "enabled", "budget_tokens": 1024}}, "thinking"),
    ({"thinking": {"type": "adaptive", "display": "summarized"}}, "thinking"),
    ({"output_config": {"effort": 500}}, "effort"),
    ({"output_config": {"effort": "unknown"}}, "effort"),
    ({"output_config": {"effort": "high", "format": {"type": "json_schema", "schema": {}}}}, "format"),
    ({"output_config": {"task_budget": {"type": "tokens", "total": 512}}}, "task_budget"),
])
def test_rejects_unsupported_thinking_and_output_options(fields, error):
    with pytest.raises(ValueError, match=error):
        to_chat_request({**REQUEST, **fields})


@pytest.mark.parametrize(("choice", "expected"), [
    ({"type": "none"}, "none"), ({"type": "auto"}, "auto"), ({"type": "any"}, "required"),
    ({"type": "tool", "name": "weather"}, {"type": "function", "function": {"name": "weather"}})])
def test_client_tool_choice(choice, expected):
    req = {**REQUEST, "tools": [{**TOOL, "type": "custom", "cache_control": {"type": "ephemeral"}}],
           "tool_choice": {**choice, "disable_parallel_tool_use": True}}
    normalized = to_chat_request(req)
    assert normalized["tools"] == [{"type": "function", "function": {"name": "weather",
                                    "description": "Get local weather", "parameters": {"type": "object"}}}]
    assert normalized["tool_choice"] == expected
    assert normalized["parallel_tool_calls"] is False


def test_parallel_tool_result_roundtrip_and_user_follow_up():
    stats = {"finish_reason": "tool_calls", "usage": USAGE,
             "tool_calls": [CALL, {**CALL, "id": "call_2"}]}
    response = message_response(META, "Checking", stats)
    assert response["stop_reason"] == "tool_use"
    assert response["content"] == [{"type": "text", "text": "Checking"}, USE, {**USE, "id": "call_2"}]
    assert response["usage"] == {"input_tokens": 41, "output_tokens": 9}
    req = {**REQUEST, "tools": [TOOL], "messages": [
        *REQUEST["messages"], {"role": "assistant", "content": response["content"]},
        {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "call_2", "is_error": True, "content": "Unavailable"},
            RESULT, {"type": "text", "text": "Summarize."}]}]}
    normalized = to_chat_request(req)
    assert normalized["messages"][1:] == [
        {"role": "assistant", "content": "Checking", "tool_calls": stats["tool_calls"]},
        {"role": "tool", "tool_call_id": "call_2", "content": "Tool error: Unavailable"},
        {"role": "tool", "tool_call_id": "call_1", "content": "Sunny"},
        {"role": "user", "content": "Summarize."}]


@pytest.mark.parametrize("request_fields", [
    {"max_tokens": False}, {"max_tokens": 0}, {"temperature": 1.1}, {"stream": 1}, {"top_k": 5},
    {"cache_control": "ephemeral"}, {"metadata": {"user_id": 42}},
    {"stop_sequences": ["EOF"]}, {"thinking": {"type": "enabled", "budget_tokens": 1024}},
    {"tools": [{"name": "search", "type": "web_search_20250305"}]}, {"tools": [{**TOOL, "strict": True}]},
    {"messages": [{"role": "system", "content": "x"}]},
    {"messages": [{"role": "user", "content": [{"type": "image"}]}]},
    {"messages": [{"role": "user", "content": [RESULT]}]},
    {"messages": [{"role": "assistant", "content": [USE]}, {"role": "user", "content": "orphaned"}]},
    {"messages": [{"role": "assistant", "content": [USE]}, {"role": "user", "content": [
        {"type": "text", "text": "first"}, RESULT]}]},
    {"messages": [{"role": "assistant", "content": [{**USE, "input": []}]}]},
    {"messages": [{"role": "assistant", "content": [USE, USE]}]},
    {"messages": [{"role": "assistant", "content": [USE]}]},
])
def test_malformed_or_unsupported_requests(request_fields):
    with pytest.raises(ValueError):
        to_chat_request({**REQUEST, **request_fields})


@pytest.mark.parametrize(("text", "calls", "reason", "expected_reason"), [
    (["A", "", "B"], [], "stop", "end_turn"),
    (["part"], [], "length", "max_tokens"),
    (["", ""], [], "stop", "end_turn"),
    ([], [CALL], "tool_calls", "tool_use"),
    (["接下来"], [CALL, {**CALL, "id": "call_2"}], "tool_calls", "tool_use"),
])
def test_message_stream_matches_json_response(text, calls, reason, expected_reason):
    stats = {"usage": USAGE, "tool_calls": calls, "finish_reason": reason}
    events = list(message_events(META, iter(text), lambda: stats))
    start, delta, stop = events[0][1], events[-2][1], events[-1][1]
    assert start["type"] == "message_start" and start["message"]["stop_reason"] is None
    assert start["message"]["usage"] == {"input_tokens": 41, "output_tokens": 0}
    assert stop == {"type": "message_stop"}
    assert delta == {"type": "message_delta", "delta": {"stop_reason": expected_reason, "stop_sequence": None},
                     "usage": {"input_tokens": 41, "output_tokens": 9}}
    assert all(name == payload["type"] for name, payload in events)
    rebuilt = {**start["message"], **delta["delta"], "usage": delta["usage"]}
    open_index = None
    for name, payload in events[1:-2]:
        index = payload["index"]
        if name == "content_block_start":
            assert index == len(rebuilt["content"]) and open_index is None
            rebuilt["content"].append(dict(payload["content_block"]))
            open_index = index
        elif name == "content_block_stop":
            assert open_index == index
            open_index = None
        else:
            assert open_index == index and name == "content_block_delta"
            block = rebuilt["content"][index]
            if block["type"] == "text":
                block["text"] += payload["delta"]["text"]
            else:
                assert payload["delta"]["type"] == "input_json_delta"
                block["input"] = json.loads(payload["delta"]["partial_json"])
    assert open_index is None
    assert rebuilt == message_response(META, "".join(text), stats)


def test_stream_delivers_first_text_before_backend_finishes_and_propagates_failure():
    def broken():
        yield "hello"
        raise RuntimeError("generation interrupted")

    events = message_events(META, broken(), lambda: {"usage": {"prompt_tokens": 4}})
    assert [next(events)[0] for _ in range(2)] == ["message_start", "content_block_start"]
    assert next(events)[1]["delta"] == {"type": "text_delta", "text": "hello"}
    with pytest.raises(RuntimeError, match="generation interrupted"):
        next(events)
