# /// script
# requires-python = ">=3.10"
# ///
"""Control the local model API from Blurt settings or the CLI. Commands print one JSON object."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time

from _common import BLURT_HOME, file_lock, load_json, private_dir, save_json
from model_api_http import ModelHTTP
from model_api_pool import WorkerPool

ROOT = BLURT_HOME / "model-api"
STATE = ROOT / "state.json"
KEY = ROOT / "key.json"
DEFAULT_PORT = 11435
PROTOCOL_REVISION = 3


def models():
    from model_api_engine import available_models
    return available_models()


def running():
    try:
        with file_lock(ROOT / "service.lock", timeout=0):
            return False
    except TimeoutError:
        return True


def state():
    record = load_json(STATE, {}) if running() else {}
    if not record.get("base_url"):
        return {"running": False, "scope": "local", "base_url": ""}
    return {"running": True, "scope": record["scope"], "base_url": record["base_url"],
            "needs_restart": record.get("protocol_revision", 1) < PROTOCOL_REVISION,
            "messages_base_url": record["base_url"].removesuffix("/v1")}


def address(scope, host):
    if scope == "local":
        if host and host != "127.0.0.1":
            raise ValueError("Use LAN mode for other addresses.")
        return "127.0.0.1"
    candidates = [host] if host else []
    if not host:
        # UDP connect selects a route; it sends no packet.
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
                route.connect(("192.0.2.1", 9))
                candidates.append(route.getsockname()[0])
        except OSError:
            pass
        try:
            candidates.extend(socket.gethostbyname_ex(socket.gethostname())[2])
        except OSError:
            pass
    networks = [ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")]
    for item in candidates:
        ip = ipaddress.ip_address(item)
        if any(ip in net for net in networks):
            return str(ip)
    raise ValueError("No private IPv4 address found. Connect to a LAN or specify --host.")


def token():
    value = load_json(KEY, {}).get("api_key")
    if not value:
        value = "blurt-" + secrets.token_urlsafe(32)
        save_json(KEY, {"api_key": value})
    return value


def python_example(base_url, key, model):
    mid = repr(model["id"])
    setup = f"from openai import OpenAI\n\nclient = OpenAI(base_url={base_url!r}, api_key={key!r})\n"
    if model["capability"] == "transcription":
        return (setup + '\nwith open("audio.wav", "rb") as audio:\n'
                f"    response = client.audio.transcriptions.create(model={mid}, file=audio)\nprint(response.text)\n")
    if model["capability"] == "ocr":
        setup = "import base64\nfrom pathlib import Path\n" + setup
        setup += '\nimage = base64.b64encode(Path("image.png").read_bytes()).decode("ascii")\n'
        content = '[{"type": "image_url", "image_url": {"url": "data:image/png;base64," + image}}]'
    else:
        content = '"Hello!"'
    return (setup + f"response = client.chat.completions.create(\n    model={mid},\n"
            f'    messages=[{{"role": "user", "content": {content}}}],\n)\nprint(response.choices[0].message.content)\n')


def serve(args):
    from model_api_engine import worker_command
    pool = WorkerPool(worker_command)
    with file_lock(ROOT / "service.lock", timeout=0):
        try:
            with ModelHTTP((args.host, args.port), token(), models, pool) as server:
                url = f"http://{args.host}:{server.server_port}/v1"
                save_json(STATE, {"instance": args.instance, "base_url": url, "scope": args.scope, "protocol_revision": PROTOCOL_REVISION})
                server.timeout = 0.25
                try:
                    while not (ROOT / "stop").exists():
                        server.handle_request()
                        pool.expire()
                finally:
                    server.interrupt_clients()
                    pool.close()
        finally:
            STATE.unlink(missing_ok=True)


def start(args):
    current = state()
    if current["running"]:
        if current["scope"] != args.scope or (args.host and args.host != current["base_url"].split("/")[2].split(":")[0]):
            raise ValueError("Stop the running service before changing its address.")
        if args.port is not None and not current["base_url"].endswith(f":{args.port}/v1"):
            raise ValueError("Stop the running service before changing its port.")
        return
    host = address(args.scope, args.host)
    if args.port is not None and not 0 <= args.port <= 65535:
        raise ValueError("Port must be between 0 and 65535.")
    (ROOT / "stop").unlink(missing_ok=True)
    STATE.unlink(missing_ok=True)
    instance = secrets.token_hex(12)
    failure = ROOT / (instance + ".error")
    opts = ({"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
            if os.name == "nt" else {"start_new_session": True})
    # The Mac desktop can supply its cloud provider keys to ScriptRunner. A detached local
    # service only needs runtime paths/settings; it must not retain those provider credentials.
    env = {k: v for k, v in os.environ.items()
           if not k.upper().endswith(("_API_KEY", "_ACCESS_TOKEN", "_AUTH_TOKEN", "_SECRET_KEY"))
           and k.upper() not in {"HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "VOLC_APP_ID"}}
    # uv can remove its temporary environment as soon as the settings command returns.
    # The daemon only requires stdlib. Start it on the persistent interpreter in that case.
    interpreter = sys.executable
    if env.get("UV_RUN_RECURSION_DEPTH") and Path(sys.prefix).name.startswith(".tmp"):
        interpreter = sys._base_executable
        env.pop("VIRTUAL_ENV", None)
    proc = subprocess.Popen([interpreter, str(Path(__file__).resolve()), "_serve", "--scope", args.scope,
                             "--host", host, "--port", str(DEFAULT_PORT if args.port is None else args.port),
                             "--instance", instance], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, env=env, **opts)
    try:
        for _ in range(200):
            if load_json(STATE, {}).get("instance") == instance:
                return
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        raise RuntimeError(load_json(failure, {}).get("error", "Model API did not start."))
    finally:
        failure.unlink(missing_ok=True)


def control(args):
    private_dir(ROOT)
    if args.action == "_serve":
        try:
            serve(args)
        except Exception as exc:
            save_json(ROOT / (args.instance + ".error"), {"error": str(exc)})
            raise
        return {}
    if args.action == "prepare":
        # Independent of service state: preparing packages must not block stop/status.
        from model_api_engine import prepare_runtime
        prepare_runtime(args.model)
    with file_lock(ROOT / "control.lock", timeout=20):
        if args.action == "start":
            start(args)
        elif args.action == "stop" and running():
            (ROOT / "stop").touch()
            for _ in range(200):
                if not running():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("Service is still stopping.")
        elif args.action == "rotate-key":
            if running():
                raise ValueError("Stop the service before replacing its key.")
            save_json(KEY, {"api_key": "blurt-" + secrets.token_urlsafe(32)})
        result = state()
        if args.action == "config":
            if not result["running"]:
                raise ValueError("Start the model API before copying its configuration.")
            result["api_key"] = token()
    result["models"] = models()
    if args.action == "config":
        result["python_examples"] = {
            m["id"]: python_example(result["base_url"], result["api_key"], m) for m in result["models"]}
        if not result["needs_restart"]:
            result["messages_python_examples"] = {
                m["id"]: (f"from anthropic import Anthropic\n\nclient = Anthropic(base_url={result['messages_base_url']!r}, "
                          f"api_key={result['api_key']!r})\nresponse = client.messages.create(\n    model={m['id']!r}, "
                          'max_tokens=512, messages=[{"role": "user", "content": "Hello!"}]\n)\n'
                          'print(response.content[0].text)\n') for m in result["models"] if m["capability"] == "chat"}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    cmds = parser.add_subparsers(dest="action", required=True)
    for name in ["status", "stop", "config", "rotate-key"]:
        cmds.add_parser(name)
    prep = cmds.add_parser("prepare", help="Prepare this installed model's local Python runtime")
    prep.add_argument("--model", required=True)
    for name in ["start", "_serve"]:
        sub = cmds.add_parser(name)
        sub.add_argument("--scope", choices=["local", "lan"], default="local")
        sub.add_argument("--host", help="Private IPv4 interface to bind in LAN mode")
        sub.add_argument("--port", type=int, help=f"Default {DEFAULT_PORT}; 0 selects a free port")
        if name == "_serve":
            sub.add_argument("--instance", required=True)
    try:
        print(json.dumps(control(parser.parse_args()), ensure_ascii=True))
        return 0
    except (ValueError, LookupError, RuntimeError, OSError, ImportError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
