"""Private pipe protocol for the external model API. Stdout may also contain backend diagnostics."""
import json
import os
import sys
from model_api_native_tools import ToolGenerationError, ToolsUnsupported

PREFIX = "BLURT_MODEL_REPLY "


def emit(kind, value):
    print(PREFIX + json.dumps([kind, value], ensure_ascii=True), flush=True)


def main():
    if hasattr(os, "nice"):
        try:
            os.nice(5)
        except OSError:
            pass
    import model_api_engine as engine
    for line in sys.stdin.buffer:
        try:
            cmd, args = json.loads(line)
            if cmd in ("stream", "chat"):
                for kind, value in engine.chat_events(*args):
                    if cmd == "stream" or kind == "done":
                        emit(kind, value)
            else:
                call = {"transcription": engine.transcribe, "ocr": engine.ocr}[cmd]
                emit("done", call(*args))
        except engine.ContextLengthExceeded as exc:
            emit("context_length_exceeded", {"prompt_tokens": exc.prompt_tokens, "context_window": exc.context_window})
        except ToolGenerationError:
            emit("error", "tool_generation_failed")
        except ToolsUnsupported:
            emit("error", "tools_unsupported")
        except ValueError:
            emit("error", "invalid_input")
        except LookupError:
            emit("error", "model_not_found")
        except Exception:
            # Backend exceptions can contain prompts, paths or uploaded content.
            emit("error", "inference_failed")


if __name__ == "__main__":
    main()
