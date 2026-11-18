"""Native template / parser handoff without MLX or model weights."""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import model_api_engine as api
from model_api_native_tools import NativeReply, ToolGenerationError, ToolsUnsupported

TOOL = {"type": "function", "function": {"name": "lookup_number", "parameters": {"type": "object"}}}
MESSAGES = [{"role": "user", "content": "Look up the blue number."}]
CALL = '<tool_call>{"name":"lookup_number","arguments":{"label":"蓝"}}</tool_call>'


class Tokenizer:
    tool_call_start = "<tool_call>"
    tool_call_end = "</tool_call>"
    think_start = "<think>"
    think_end = "</think>"

    def apply_chat_template(self, messages, **kwargs):
        self.history = messages
        self.template_args = kwargs
        return [1, 2, 3]

    def encode(self, text, add_special_tokens):
        assert text == self.tool_call_start and add_special_tokens is False
        return [4]

    @staticmethod
    def tool_parser(text, tools):
        assert tools == [TOOL]
        return json.loads(text)


@pytest.fixture
def generate(monkeypatch, tmp_path):
    tok = Tokenizer()
    monkeypatch.setattr(api, "_find", lambda *_: SimpleNamespace(path=tmp_path))
    monkeypatch.setattr(api, "_offline", lambda: None)
    monkeypatch.setattr(api, "_chat_model", lambda _: (object(), tok))
    monkeypatch.setitem(sys.modules, "mlx_lm.sample_utils", SimpleNamespace(make_sampler=lambda temp: temp))

    def run(pieces, *, choice="auto", parallel=True, messages=MESSAGES, tools=None, reason="stop"):
        def stream(model, tokenizer, tokens, **kw):
            assert tokenizer is tok
            tok.tokens = tokens
            for piece in pieces:
                yield SimpleNamespace(text=piece, finish_reason=None)
            yield SimpleNamespace(text="", finish_reason=reason)

        monkeypatch.setitem(sys.modules, "mlx_lm", SimpleNamespace(stream_generate=stream))
        return list(api.chat_events("fixture", messages, 128, 0, {
            "tools": [TOOL] if tools is None else tools, "tool_choice": choice, "parallel_tool_calls": parallel}))

    return tok, run


def test_mixed_visible_text_reasoning_and_parallel_calls_across_every_chunk_boundary(generate):
    _, run = generate
    events = run("before<think>hidden</think>" + CALL * 2 + "after")
    assert events[0] == ("prompt_tokens", 3)
    assert "".join(v for k, v in events if k == "delta") == "beforeafter"
    done = events[-1][1]
    assert done["text"] == "beforeafter"
    assert done["finish_reason"] == "tool_calls"
    a, b = done["tool_calls"]
    assert a["id"] != b["id"]
    assert a["type"] == "function" and a["function"]["name"] == "lookup_number"
    assert json.loads(a["function"]["arguments"]) == {"label": "蓝"}


def test_context_counts_native_tool_prefix_and_limits_generation(generate, tmp_path, monkeypatch):
    tokenizer, run = generate
    (tmp_path / "config.json").write_text(json.dumps({"max_position_embeddings": 100, "text_config": {
        "max_position_embeddings": 4}}))
    tokenizer.model_max_length = 1000
    # The template produced three tokens. Forcing a tool adds one, leaving no room for generation.
    with pytest.raises(api.ContextLengthExceeded) as exc:
        run([], choice="required")
    assert (exc.value.prompt_tokens, exc.value.context_window) == (4, 4)
    observed = []
    def stream(model, tokenizer, tokens, **kw):
        observed.append(kw["max_tokens"])
        return iter([SimpleNamespace(text="ok", finish_reason="length")])
    monkeypatch.setitem(sys.modules, "mlx_lm", SimpleNamespace(stream_generate=stream))
    events = list(api.chat_events("fixture", MESSAGES, 128, 0))
    assert observed == [1] and events[-1][1]["finish_reason"] == "length"


def test_context_window_falls_back_to_flat_config_then_tokenizer(tmp_path):
    tokenizer = SimpleNamespace(model_max_length=200)
    assert api._context_window(tmp_path, tokenizer) == 200
    (tmp_path / "config.json").write_text('{"max_position_embeddings": 80}')
    assert api._context_window(tmp_path, tokenizer) == 80


@pytest.mark.parametrize("choice", ["required", {"type": "function", "function": {"name": "lookup_number"}}])
def test_required_native_prefix_and_one_call_limit(generate, choice):
    tok, run = generate
    tools = [TOOL]
    if isinstance(choice, dict):
        tools += [{"type": "function", "function": {"name": "unselected"}}]
    events = run([CALL.removeprefix("<tool_call>") + CALL], choice=choice, parallel=False, tools=tools)
    assert tok.template_args["tools"] == [TOOL]
    assert tok.tokens == [1, 2, 3, 4]
    assert events[0] == ("prompt_tokens", len(tok.tokens))
    assert [k for k, _ in events] == ["prompt_tokens", "done"]
    assert len(events[-1][1]["tool_calls"]) == 1


@pytest.mark.parametrize("text,choice", [
    ('<tool_call>{"name":"unknown","arguments":{}}</tool_call>', "auto"),
    ('<tool_call>{"name":"lookup_number","arguments":[]}</tool_call>', "auto"),
    ('<tool_call>{"name":"lookup_number","arguments":{"x":NaN}}</tool_call>', "auto"),
    ('<tool_call>{"name":"lookup_number"}', "auto"),
    ('<tool_call>{}</tool_cal', "auto"),
    ('<tool_call>missing json</tool_call>', "auto"),
    ('<tool_', "auto"),
    ('</tool_call>', "auto"),
    ('plain text only', "required"),
    (CALL, "none"),
])
def test_invalid_and_truncated_calls_cannot_be_returned_as_text_or_calls(generate, text, choice):
    _, run = generate
    with pytest.raises(ToolGenerationError):
        run(text, choice=choice, reason="length")


def test_tool_result_history_is_rendered_with_object_arguments_and_original_ids(generate):
    tok, run = generate
    history = MESSAGES + [
        {"role": "assistant", "content": None, "tool_calls": [{"id": "call_test", "type": "function",
         "function": {"name": "lookup_number", "arguments": '{"label":"blue"}'}}]},
        {"role": "tool", "tool_call_id": "call_test", "name": "lookup_number", "content": "412"},
    ]
    events = run(["412"], messages=history, choice="none")
    assert "tools" not in tok.template_args
    assert tok.history[1]["tool_calls"][0]["function"]["arguments"] == {"label": "blue"}
    assert isinstance(history[1]["tool_calls"][0]["function"]["arguments"], str)
    assert tok.history[2] == history[2]
    assert events[-1][1] == {"text": "412", "finish_reason": "stop",
                             "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5}}


def test_unsupported_model_rejects_active_tools_but_accepts_none():
    with pytest.raises(ToolsUnsupported):
        NativeReply(object(), MESSAGES, {"tools": [TOOL]})
    reply = NativeReply(object(), MESSAGES, {"tools": [TOOL], "tool_choice": "none"})
    assert list(reply.feed("plain text")) == ["plain text"]


@pytest.mark.parametrize("has_generation_prompt", [True, False])
def test_gemma_tool_response_opens_exactly_one_generation_turn(generate, monkeypatch, has_generation_prompt):
    tok, run = generate
    tok.tool_call_start, tok.tool_call_end = "<|tool_call>", "<tool_call|>"
    response, model_turn = [33], [34, 35]
    monkeypatch.setattr(tok, "encode", lambda text, **kw: {
        "<tool_response|>": response, "<turn|>\n<|turn>model\n": model_turn}[text])
    monkeypatch.setattr(tok, "apply_chat_template", lambda *a, **kw: response + (model_turn if has_generation_prompt else []))
    run(["123"], messages=[*MESSAGES, {"role": "tool", "name": "lookup_number", "content": "123"}])
    assert tok.tokens == response + model_turn


def test_stop_at_tool_response_boundary_and_leave_execution_to_client(generate):
    _, run = generate
    events = run([CALL + "<tool_response>invented tool result</tool_response>"])
    assert [k for k, _ in events] == ["prompt_tokens", "done"]
    assert events[-1][1]["text"] == ""
    assert len(events[-1][1]["tool_calls"]) == 1
