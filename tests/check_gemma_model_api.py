# /// script
# requires-python = ">=3.12"
# dependencies = ["anthropic==2.10.0", "openai==3.54.0"]
# ///
"""Exercise a real installed Gemma through both SDKs. Serve on a temporary loopback port."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from anthropic import Anthropic
from openai import OpenAI

MODEL = "gemma4-e2b"
QUESTION = "Reply only with the name of the capital of France."
TASK = ("Use lookup_number to look up the test number for blue. "
        "Once you receive the result, reply with the number.")
SCHEMA = {"type": "object", "properties": {"color": {"type": "string"}}, "required": ["color"]}
FUNCTION = {"name": "lookup_number", "description": "Look up the test number for the requested color."}
OAI_TOOL = {"type": "function", "function": {**FUNCTION, "parameters": SCHEMA}}
MSG_TOOL = {**FUNCTION, "input_schema": SCHEMA}
COMMON = {"model": MODEL, "temperature": 0, "max_tokens": 160}
LARGE_TOOL_DECLARATION_MIN_CHARS = 64_000
LARGE_TOOL_TASK = ("Find the test number assigned to the color blue in the local catalog. "
                   "Use the matching read-only query tool, wait for its result, then reply with the number only.")


def lookup_number(name, arguments):
    assert name == FUNCTION["name"] and arguments == {"color": "blue"}, (name, arguments)
    return {"number": 74291}


def _large_tool_specs():
    """Build useful read-only client queries without putting the large list on normal requests."""
    specs = []
    for index in range(96):
        key = f"query-key-{index:03d}"
        specs.append({
            "name": f"query_local_catalog_{index:03d}",
            "description": (f"Safe read-only client query {index:03d}. Retrieve the local catalog record "
                            f"whose exact key is {key}; this query is informational and never writes, sends, "
                            "deletes, or changes data. Use it only when the user asks for that exact catalog "
                            "record, and return the result without inventing missing fields. The client may "
                            "cache this response locally because the operation has no side effects."),
            "schema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": f"Exact local catalog key: {key}."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 10,
                              "description": "Maximum number of read-only records to return."},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        })
    # Keep the real lookup in the middle of the list so auto selection cannot depend on a forced tool name.
    specs.insert(len(specs) // 2, {"name": FUNCTION["name"],
                                   "description": ("Safe read-only client query that returns the deterministic "
                                                   "test number assigned to a named color in the local catalog. "
                                                   "Use it when the user asks for the test number for a color."),
                                   "schema": SCHEMA})
    return specs


def _large_tools():
    specs = _large_tool_specs()
    openai_tools = [{"type": "function", "function": {"name": spec["name"],
                                                        "description": spec["description"],
                                                        "parameters": spec["schema"]}}
                    for spec in specs]
    messages_tools = [{"name": spec["name"], "description": spec["description"],
                       "input_schema": spec["schema"]} for spec in specs]
    sizes = {label: len(json.dumps(tools, ensure_ascii=False, separators=(",", ":")))
             for label, tools in (("OpenAI", openai_tools), ("Messages", messages_tools))}
    assert all(size > LARGE_TOOL_DECLARATION_MIN_CHARS for size in sizes.values()), sizes
    return openai_tools, messages_tools, sizes


def _assert_large_prompt_tokens(usage, declaration_chars, label, field):
    tokens = getattr(usage, field, 0)
    # A ten-to-one character/token bound is deliberately conservative, while catching a template
    # that silently omits most of the declared tools.
    assert tokens >= declaration_chars // 10, (label, declaration_chars, field, tokens)
    return tokens


def openai_turn(client, messages, stream, **opts):
    args = {**COMMON, "messages": messages, **opts}
    if not stream:
        res = client.chat.completions.create(**args)
        choice = res.choices[0]
        message = choice.message.model_dump(exclude_none=True)
        return message, choice.finish_reason, res.usage, 0
    text, calls, reason, usage, deltas = [], {}, None, None, 0
    with client.chat.completions.create(**args, stream=True, stream_options={"include_usage": True}) as chunks:
        for chunk in chunks:
            if chunk.usage:
                usage = chunk.usage
            for choice in chunk.choices:
                reason = choice.finish_reason or reason
                if choice.delta.content:
                    text.append(choice.delta.content)
                    deltas += 1
                for part in choice.delta.tool_calls or []:
                    call = calls.setdefault(part.index, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                    call["id"] += part.id or ""
                    if part.function:
                        call["function"]["name"] += part.function.name or ""
                        call["function"]["arguments"] += part.function.arguments or ""
                        deltas += 1
    message = {"role": "assistant", "content": "".join(text) or None}
    if calls:
        message["tool_calls"] = [calls[i] for i in sorted(calls)]
    return message, reason, usage, deltas


def test_openai(client, stream):
    first, reason, usage, n = openai_turn(client, [{"role": "user", "content": QUESTION}], stream)
    assert "paris" in first["content"].lower() and reason == "stop" and usage.prompt_tokens > 0
    assert usage.completion_tokens > 0 and (not stream or n > 0)
    print("OpenAI", "stream" if stream else "JSON", "chat:", first["content"], flush=True)
    history = [{"role": "user", "content": TASK}]
    choice = {"type": "function", "function": {"name": FUNCTION["name"]}} if stream else "auto"
    request, reason, usage, n = openai_turn(client, history, stream, tools=[OAI_TOOL], tool_choice=choice)
    assert reason == "tool_calls" and len(request["tool_calls"]) == 1 and (not stream or n > 0)
    call, = request["tool_calls"]
    assert call["id"] and usage.completion_tokens > 0
    value = lookup_number(call["function"]["name"], json.loads(call["function"]["arguments"]))
    history.extend([request, {"role": "tool", "tool_call_id": call["id"], "content": json.dumps(value)}])
    final, reason, usage, _ = openai_turn(client, history, stream, tools=[OAI_TOOL], tool_choice="auto")
    assert str(value["number"]) in final["content"] and reason == "stop" and usage.prompt_tokens > 0, final
    print("OpenAI", "stream" if stream else "JSON", "lookup_number(blue) ->", final["content"], flush=True)


def messages_turn(client, messages, stream, **opts):
    # DataAgent's custom provider supplies these hints on real conversations and omits them on its probe.
    args = {**COMMON, "messages": messages, "thinking": {"type": "adaptive"},
            "output_config": {"effort": "medium"}, "metadata": {"user_id": "local-sdk-test"},
            "system": [{"type": "text", "text": "Answer the user's request concisely.",
                        "cache_control": {"type": "ephemeral"}}], **opts}
    # This SDK exposes provider-specific sampling options through extra_body.
    args["extra_body"] = {"temperature": args.pop("temperature")}
    if not stream:
        return client.messages.create(**args), []
    with client.messages.stream(**args) as events:
        types = [event.delta.type if event.type == "content_block_delta" else event.type for event in events]
        assert types[0] == "message_start" and types[-1] == "message_stop", types
        return events.get_final_message(), types


def test_messages(client, stream):
    first, events = messages_turn(client, [{"role": "user", "content": QUESTION}], stream)
    assert "paris" in first.content[0].text.lower() and first.stop_reason == "end_turn"
    assert first.usage.input_tokens > 0 and first.usage.output_tokens > 0 and (not stream or "text_delta" in events)
    print("Messages", "stream" if stream else "JSON", "chat:", first.content[0].text, flush=True)
    history = [{"role": "user", "content": TASK}]
    choice = {"type": "tool", "name": FUNCTION["name"]} if stream else {"type": "auto"}
    reply, events = messages_turn(client, history, stream, tools=[MSG_TOOL], tool_choice=choice)
    assert reply.stop_reason == "tool_use" and reply.usage.output_tokens > 0 and (not stream or "input_json_delta" in events)
    call, = [block for block in reply.content if block.type == "tool_use"]
    assert call.id
    value = lookup_number(call.name, call.input)
    history.extend([{"role": "assistant", "content": [b.model_dump(exclude_none=True) for b in reply.content]},
                    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call.id, "content": json.dumps(value)}]}])
    final, _ = messages_turn(client, history, stream, tools=[MSG_TOOL])
    answer = "".join(b.text for b in final.content if b.type == "text")
    assert str(value["number"]) in answer and final.stop_reason == "end_turn", final
    print("Messages", "stream" if stream else "JSON", "lookup_number(blue) ->", answer, flush=True)


def test_openai_large_tools(client, stream=False):
    tools, _, sizes = _large_tools()
    history = [{"role": "user", "content": LARGE_TOOL_TASK}]
    request, reason, usage, n = openai_turn(client, history, stream, tools=tools, tool_choice="auto")
    prompt_tokens = _assert_large_prompt_tokens(usage, sizes["OpenAI"], "OpenAI first", "prompt_tokens")
    assert reason == "tool_calls" and len(request["tool_calls"]) == 1 and (not stream or n > 0), request
    call, = request["tool_calls"]
    assert call["id"] and usage.completion_tokens > 0
    value = lookup_number(call["function"]["name"], json.loads(call["function"]["arguments"]))
    history.extend([request, {"role": "tool", "tool_call_id": call["id"], "content": json.dumps(value)}])
    final, reason, usage, _ = openai_turn(client, history, stream, tools=tools, tool_choice="auto")
    final_prompt_tokens = _assert_large_prompt_tokens(usage, sizes["OpenAI"], "OpenAI final", "prompt_tokens")
    assert final_prompt_tokens >= prompt_tokens and reason == "stop" and str(value["number"]) in (final.get("content") or ""), final
    print("OpenAI", "stream" if stream else "JSON", "large tools:", sizes["OpenAI"],
          "prompt_tokens", prompt_tokens, "->", final_prompt_tokens, "lookup_number(blue) ->", final["content"],
          flush=True)


def test_messages_large_tools(client, stream=False):
    _, tools, sizes = _large_tools()
    history = [{"role": "user", "content": LARGE_TOOL_TASK}]
    reply, events = messages_turn(client, history, stream, tools=tools,
                                  tool_choice={"type": "auto", "disable_parallel_tool_use": True})
    prompt_tokens = _assert_large_prompt_tokens(reply.usage, sizes["Messages"], "Messages first", "input_tokens")
    assert reply.stop_reason == "tool_use" and reply.usage.output_tokens > 0 and (
        not stream or "input_json_delta" in events), reply
    call, = [block for block in reply.content if block.type == "tool_use"]
    assert call.id
    value = lookup_number(call.name, call.input)
    history.extend([{"role": "assistant", "content": [b.model_dump(exclude_none=True) for b in reply.content]},
                    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call.id,
                                                     "content": json.dumps(value)}]}])
    final, _ = messages_turn(client, history, stream, tools=tools,
                             tool_choice={"type": "auto", "disable_parallel_tool_use": True})
    final_prompt_tokens = _assert_large_prompt_tokens(final.usage, sizes["Messages"], "Messages final", "input_tokens")
    answer = "".join(block.text for block in final.content if block.type == "text")
    assert final_prompt_tokens >= prompt_tokens and str(value["number"]) in answer and final.stop_reason == "end_turn", final
    print("Messages", "stream" if stream else "JSON", "large tools:", sizes["Messages"],
          "input_tokens", prompt_tokens, "->", final_prompt_tokens, "lookup_number(blue) ->", answer, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", type=Path, default=Path(__file__).resolve().parents[1] / "skills/blurt/scripts/model_api.py")
    parser.add_argument("--source-home", type=Path, default=Path.home() / ".blurt", help="Blurt home with installed Gemma and prepared runtime")
    parser.add_argument("--large-tools", "--large-tool-regression", dest="large_tools", action="store_true",
                        help="Run the opt-in >64K-character auto-tool round trips.")
    args = parser.parse_args()
    weights = args.source_home / "models/polish/gemma-4-e2b-it-4bit"
    runtimes = args.source_home / "model-api/runtimes"
    if not weights.is_dir() or not runtimes.is_dir():
        parser.error("Prepare gemma4-e2b and its external model API runtime first.")
    with tempfile.TemporaryDirectory(prefix="blurt-sdk-test-") as tmp:
        home = Path(tmp)
        for target, relative in ((weights, weights.relative_to(args.source_home)), (runtimes, runtimes.relative_to(args.source_home))):
            dest = home / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(target.resolve(), target_is_directory=True)
        env = {**os.environ, "BLURT_HOME": tmp, "BLURT_WORKSPACE": str(home / "workspace"), "HF_HUB_CACHE": str(home / "hub"),
               "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1"}
        def control(*cmd):
            data = subprocess.check_output([sys.executable, str(args.controller), *cmd], env=env, text=True)
            return json.loads(data)
        try:
            started = control("start", "--scope", "local", "--port", "0")
            assert started["running"]
            cfg = control("config")
            opts = {"api_key": cfg["api_key"], "max_retries": 0, "timeout": 180}
            with OpenAI(base_url=cfg["base_url"], **opts) as oai, Anthropic(base_url=cfg["messages_base_url"], **opts) as msg:
                assert MODEL in [m.id for m in oai.models.list()] and MODEL in [m.id for m in msg.models.list()]
                for stream in (False, True):
                    test_openai(oai, stream)
                    test_messages(msg, stream)
                if args.large_tools:
                    test_openai_large_tools(oai)
                    test_messages_large_tools(msg)
                for label, field in (("OpenAI", "python_examples"), ("Messages", "messages_python_examples")):
                    example = cfg[field][MODEL]
                    # Feed the copied code over stdin, so its embedded key is never a process argument.
                    result = subprocess.run([sys.executable, "-"], input=example, text=True, capture_output=True,
                                            env=env, timeout=180)
                    assert result.returncode == 0 and result.stdout.strip(), f"{label} copied example failed"
                    print(label, "copied Python example: OK", flush=True)
        finally:
            stopped = control("stop")
            assert not stopped["running"]


if __name__ == "__main__":
    main()
