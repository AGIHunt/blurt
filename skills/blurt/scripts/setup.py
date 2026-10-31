# /// script
# requires-python = ">=3.10"
# ///
"""Set up Blurt's models from an agent (docs/design/agent-setup.md; the flow: reference/setup-models.md). The running
Blurt app does the work — it tests each key, keeps it in the login Keychain and changes Settings → Models as the user
would — over its local control socket ($BLURT_HOME/run/control.sock, this user only). This CLI never writes a key to a
file, never takes one as an argument and never prints one.

  setup.py status                       the Mac (chip, memory, macOS, languages), dictation's models (installed,
                                        recommended) and choices with their measured levels, the connected services
                                        (never a key), each job's model, the curated options, where keys are made.
                                        Works without the app (from config.json: "source": "config", less detail).
  setup.py recommend [--audio local|cloud] [--text local|cloud] [--budget free|paid] [--languages zh,en]
                                        the plan for this Mac and the user's answers: what to connect, which model per
                                        job, what to download, the options worth mentioning (works without the app)
  setup.py connect PRESET [--region china|global]
                                        the key on stdin (Volcengine Speech: {"app_id": …, "access_token": …} on stdin);
                                        a terminal asks for it without echoing. Blurt tests it and stores it.
  setup.py test SERVICE                 one small request with the key Blurt holds
  setup.py use JOB OPTION [--custom]    JOB: polish | translate | vision | dictation. OPTION: auto | local | a service
                                        (its measured model) | service:model; dictation: auto or a choice id from
                                        `status` (dictation.choices[].option). --custom: a model Blurt didn't measure,
                                        saved only after the job's own test passes
  setup.py download MODEL [--wait]      a dictation or polish model (or "recommended"); --wait follows it to the end
  setup.py verify [--language zh|en]    a short spoken clip through the recogniser and polish dictation uses:
                                        what was said, what it heard, the polished text, the timings

Every command prints one JSON line: {"ok": true, …} or {"ok": false, "code", "error"} (exit 1). The app must be running
for every command but status and recommend: "code": "app_not_running" says so ("open -a Blurt"). Changes need the
user's consent in Blurt: a session started from Settings → Models → Set Up with Agent… carries it
($BLURT_SETUP_TOKEN); otherwise Blurt asks the user (Allow / Don't Allow) the first time, and "code": "denied" means
they said no.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
PROTOCOL = 1
MAX_SOCKET_PATH = 103

# Where each curated service's key is made — the app's own list (BlurtCore CloudServices.swift `keyPage`; a test keeps
# the two the same). Checked 2026-10-31: both Model Studio consoles answer, Volcengine's sends you to sign in and back.
KEY_PAGES = {
    "deepseek": {"any": "https://platform.deepseek.com/api_keys"},
    "dashscope": {"china": "https://bailian.console.aliyun.com/?tab=model#/api-key",
                  "global": "https://modelstudio.console.alibabacloud.com/?tab=model#/api-key"},
    "volcengine-speech": {"china": "https://console.volcengine.com/speech/app"},
}
PROVIDER_NAMES = {"deepseek": "DeepSeek", "dashscope": "Alibaba Cloud Model Studio (阿里云百炼)",
                  "volcengine-speech": "Volcengine Speech (火山引擎豆包语音)"}
TEXT_JOBS = ("polish", "translate", "vision")
LOCAL_RECOGNIZERS = ("qwen3-asr-0.6b-mlx", "fun-asr-nano-mlx", "qwen3-asr-1.7b-mlx")
CLOUD_RECOGNIZERS = {"qwen3-asr-flash": "dashscope", "volcengine-seedasr": "volcengine-speech"}
DICTATION_CHOICES = ("apple-speech", *LOCAL_RECOGNIZERS, "cloud-polish", *CLOUD_RECOGNIZERS)

NOT_RUNNING = {"ok": False, "code": "app_not_running",
               "error": "Blurt isn't running. Open it (open -a Blurt), then run this again.", "fix": "open -a Blurt"}


class SetupError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code

    def json(self) -> dict:
        return {"ok": False, "code": self.code, "error": str(self)}


# ------------------------------------------------------------------ the socket
def home() -> Path:
    return Path(os.environ.get("BLURT_HOME") or (Path.home() / ".blurt"))


def socket_path(h: Path | None = None, uid: int | None = None) -> str:
    """$BLURT_HOME/run/control.sock, or — when that is longer than a socket address holds — /tmp/blurt-<uid>/<12 hex of
    sha256(home)>.sock (the app's rule: BlurtCore AgentSetup.socketPath)."""
    h = h or home()
    p = str(h / "run" / "control.sock")
    if len(p.encode()) <= MAX_SOCKET_PATH:
        return p
    uid = os.getuid() if uid is None else uid
    return f"/tmp/blurt-{uid}/{hashlib.sha256(str(h).encode()).hexdigest()[:12]}.sock"


def call(req: dict, timeout: float = 30) -> dict:
    """One request to the running app → its answer. Raises SetupError("app_not_running") when nothing listens."""
    path = socket_path()
    if not os.path.exists(path):
        raise SetupError("app_not_running", NOT_RUNNING["error"])
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        try:
            s.connect(path)
        except (ConnectionRefusedError, FileNotFoundError):
            raise SetupError("app_not_running", NOT_RUNNING["error"]) from None
        s.sendall(json.dumps(req, ensure_ascii=False).encode() + b"\n")
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        raise SetupError("timeout", f"Blurt didn't answer within {int(timeout)} s") from None
    except OSError as e:
        raise SetupError("app_not_running", f"couldn't talk to Blurt: {e.strerror or e}") from None
    finally:
        s.close()
    line = buf.split(b"\n", 1)[0]
    try:
        out = json.loads(line)
    except ValueError:
        raise SetupError("bad_response", "Blurt's answer wasn't JSON") from None
    if not isinstance(out, dict):
        raise SetupError("bad_response", "Blurt's answer wasn't an object")
    return out


def request(op: str, timeout: float = 30, **fields) -> dict:
    """call() with the session's token (when Blurt started this agent) and no None fields; never raises."""
    req = {"op": op, **{k: v for k, v in fields.items() if v is not None}}
    tok = os.environ.get("BLURT_SETUP_TOKEN")
    if tok:
        req["token"] = tok
    try:
        return call(req, timeout)
    except SetupError as e:
        out = e.json()
        if e.code == "app_not_running":
            out["fix"] = NOT_RUNNING["fix"]
        return out


# ------------------------------------------------------------------ status
def status() -> dict:
    """The app's status when it runs, else what config.json and this Mac say (source "config")."""
    r = request("status", timeout=60)
    if r.get("ok"):
        r["source"] = "app"
        return r
    if r.get("code") != "app_not_running":
        return r
    return offline_status()


def _config() -> dict:
    sys.path.insert(0, str(SCRIPTS))
    from _common import parse_config_text  # noqa: PLC0415
    try:
        return parse_config_text((home() / "config.json").read_text(encoding="utf-8-sig")) or {}
    except OSError:
        return {}


def curated() -> dict:
    """scripts/curated_models.json (the list the app bundles; it may hold a newer one fetched from blurt.work)."""
    try:
        return json.loads((SCRIPTS / "curated_models.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"jobs": {}}


def dictation_models() -> dict | None:
    """`transcribe.py dictation-models` (the Mac, the recommended recogniser, what is installed), as the app reads it.
    None when it can't run (no uv yet)."""
    if os.environ.get("BLURT_SETUP_NO_PROBE") == "1":
        return None
    uv = os.environ.get("BLURT_UV") or "uv"
    try:
        p = subprocess.run([uv, "run", "-q", str(SCRIPTS / "transcribe.py"), "dictation-models"], capture_output=True,
                           text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in reversed(p.stdout.splitlines()):
        if line.startswith("{"):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            return o if o.get("ok") else None
    return None


def _mac() -> dict:
    def sysctl(name: str) -> str | None:
        try:
            return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=5).stdout.strip() or None
        except (OSError, subprocess.TimeoutExpired):
            return None
    mem = sysctl("hw.memsize")
    try:
        ver = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        ver = None
    try:
        langs = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True,
                               timeout=5).stdout
        langs = [x.strip().strip('",') for x in langs.strip("()\n ").split("\n") if x.strip().strip('",')]
    except (OSError, subprocess.TimeoutExpired):
        langs = []
    try:
        loc = subprocess.run(["defaults", "read", "-g", "AppleLocale"], capture_output=True, text=True,
                             timeout=5).stdout.strip()      # "zh_CN", "en_US@rg=cnzzzz"
    except (OSError, subprocess.TimeoutExpired):
        loc = ""
    rg = loc.split("@rg=")[1][:2].upper() if "@rg=" in loc else (loc.split("_")[1][:2].upper() if "_" in loc else None)
    chip = sysctl("machdep.cpu.brand_string")
    return {"chip": chip, "ram_gb": round(int(mem) / 2**30, 1) if mem and mem.isdigit() else None,
            "apple_silicon": bool(chip and chip.startswith("Apple")), "macos": ver, "languages": langs,
            "region": rg or None}


def offline_status() -> dict:
    """What can be said without the app: the Mac, config.json's services and jobs (whether a key is in the Keychain
    is the app's to say: "key": null), dictation's models (transcribe.py), the curated options."""
    cfg = _config()
    rec = cfg.get("record") or {}
    cloud = rec.get("cloud") if isinstance(rec.get("cloud"), dict) else {}
    dm = dictation_models()
    mac = _mac()
    if dm and isinstance(dm.get("plan"), dict):
        mac["tier"] = dm["plan"].get("tier")
    langs = ((cfg.get("asr") or {}).get("languages")) or mac.get("languages") or []
    if isinstance(langs, str):
        langs = [x.strip() for x in langs.split(",") if x.strip()]
    mac["languages"] = langs
    rec_local = None
    if dm:
        r = dm.get("recommended")
        rec_local = r if r in LOCAL_RECOGNIZERS else "apple-speech" if not (dm.get("plan") or {}).get("recognizer") else r
    services = []
    for s in (cloud.get("services") or []):
        if isinstance(s, dict) and s.get("id"):
            services.append({"id": s["id"], "preset": s.get("preset"), "region": s.get("region"), "key": None})
    jobs = {}
    for j in TEXT_JOBS:
        c = (cloud.get("jobs") or {}).get(j)
        jobs[j] = {"choice": c if c is not None else "auto"}
    options = {}
    for j, rows in (curated().get("jobs") or {}).items():
        options[j] = [{"option": f"{o['service']}:{o['model']}", "service": o["service"], "model": o["model"],
                       "name": o.get("name"), "regions": o.get("regions"), "note": o.get("note"),
                       "measured": o.get("measured")} for o in rows if isinstance(o, dict)]
    dict_cfg = rec.get("dictation") or {}
    out = {"ok": True, "source": "config", "app": "not_running", "protocol": PROTOCOL, "mac": mac,
           "dictation": {"recognizer": (dm or {}).get("selected"), "configured": dict_cfg.get("asr_model"),
                         "recommended_local": rec_local, "ready": (dm or {}).get("ready"),
                         "models": [{"id": m["id"], "name": m.get("name"), "installed": m.get("installed"),
                                     "size_mb": m.get("size_mb"), "fits": m.get("fits"),
                                     "recommended": m.get("recommended")} for m in (dm or {}).get("models") or []]},
           "services": services, "jobs": jobs, "options": options,
           "providers": [{"preset": p, "name": PROVIDER_NAMES[p], "key_pages": KEY_PAGES[p]} for p in KEY_PAGES],
           "note": "Blurt isn't running: which services have a key, the measured levels and the live progress come "
                   "from the app. Open it (open -a Blurt) for those and for every change."}
    if dm is None:
        out["note"] += " This Mac's models couldn't be read (transcribe.py needs uv)."
    return out


# ------------------------------------------------------------------ recommend
def _base(code: str) -> str:
    return code.lower().replace("_", "-").split("-")[0]


def plan(st: dict, audio: str = "local", text: str = "cloud", budget: str = "paid",
         languages: list[str] | None = None) -> dict:
    """The setup to propose, from `status` and the user's answers (agent-setup.md §3). Pure.

    audio: may the voice leave the Mac (cloud recognition); text: may the text of each dictation go to a cloud model
    (polish, translate, Copy Text from Screen); budget: free = nothing paid. The defaults are the eval's option A
    (dictation-eval-2026-10-31.md §6.3): this Mac's recogniser + DeepSeek V4.1 Flash for polish — as accurate as cloud
    recognition, no audio upload, works offline."""
    mac = st.get("mac") or {}
    langs = [_base(x) for x in (languages or mac.get("languages") or []) if x]
    chinese = any(x in ("zh", "yue") for x in langs)
    region = "china" if (mac.get("region") == "CN") else "global"
    d = st.get("dictation") or {}
    local = d.get("recommended_local") or "apple-speech"
    installed = {m["id"] for m in d.get("models") or [] if m.get("installed")}
    keyed = {s.get("preset"): s.get("id") for s in st.get("services") or [] if s.get("key")}
    paid = budget != "free"
    text_cloud = paid and text == "cloud"
    audio_cloud = paid and audio == "cloud"
    can_local = local in LOCAL_RECOGNIZERS
    out: dict = {"ok": True, "source": st.get("source"), "answers": {"audio": audio, "text": text, "budget": budget,
                                                                    "languages": langs},
                 "connect": [], "use": [], "download": [], "alternatives": [], "notes": []}

    def connect(preset: str, why: str) -> None:
        if any(c["preset"] == preset for c in out["connect"]):
            return
        r = region if preset == "dashscope" else ("china" if preset == "volcengine-speech" else None)
        pages = KEY_PAGES[preset]
        out["connect"].append({"preset": preset, "name": PROVIDER_NAMES[preset], "region": r,
                               "key_page": pages.get(r or "any") or next(iter(pages.values())),
                               "connected": preset in keyed, "why": why})

    # dictation's recogniser
    dictation = local
    if audio_cloud and not can_local:
        # no local model runs well here (Intel, under 8 GB): the cloud hears it (§6.3 B)
        dictation = "qwen3-asr-flash"
        connect("dashscope", "cloud recognition (Qwen3-ASR Flash): this Mac can't run a local speech model well")
    # the text jobs: one service for all three — the one connected already, else Model Studio when it hears speech
    # here too (one key, first-minute-speech.md §4.3), else DeepSeek (the founder's pick: cheap, one key)
    service = None
    if text_cloud:
        if "deepseek" in keyed:
            service = "deepseek"
        elif "dashscope" in keyed or dictation == "qwen3-asr-flash":
            service = "dashscope"
        else:
            service = "deepseek"
        connect(service, "polish, translate and Copy Text from Screen")
        if can_local and dictation == local:
            dictation = "cloud-polish"
    opts = st.get("options") or {}
    for job in TEXT_JOBS:
        if service:
            o = next((x for x in opts.get(job) or [] if x.get("service") == service
                      and (not x.get("regions") or service != "dashscope" or region in x["regions"])), None)
            out["use"].append({"job": job, "option": keyed.get(service, service) + (":" + o["model"] if o else ""),
                               "name": o.get("name") if o else None})
        else:
            out["use"].append({"job": job, "option": "local"})
    out["use"].insert(0, {"job": "dictation", "option": dictation})
    # what has to come down first: the local recogniser (cloud polish sits on it)
    if can_local and dictation in (local, "cloud-polish") and local not in installed:
        size = next((m.get("size_mb") for m in d.get("models") or [] if m.get("id") == local), None)
        out["download"].append({"model": local, "size_mb": size})
    # worth mentioning, never the default
    if audio_cloud and can_local:
        out["alternatives"].append({"dictation": "qwen3-asr-flash", "connect": "dashscope",
                                    "why": "cloud recognition: as accurate as the default, the voice goes to Alibaba "
                                           "Cloud, ~¥0.8 / $0.11 an hour of speech"})
    if audio_cloud and chinese:
        out["alternatives"].append({"dictation": "volcengine-seedasr", "connect": "volcengine-speech",
                                    "why": "Volcengine Seed-ASR 2.0, streamed while you speak: ~0.5 s after you stop "
                                           "even on long takes; mainland China accounts (real-name verification); "
                                           "~¥1 an hour; names are weaker, cloud polish fixes most"})
    if not paid:
        out["notes"].append("free: everything stays on this Mac; nothing to connect")
    if langs and not chinese:
        own = langs[0]
        if own == "ja":
            out["notes"].append("Japanese isn't rated (its test set mixes kanji and kana spellings); macOS Speech was the "
                                "best local engine measured on Japanese")
        elif own in ("en", "de"):
            out["notes"].append(f"measured on {own} public speech too: status → dictation.choices[].levels.{own}")
        else:
            out["notes"].append(f"{own} wasn't measured; the levels are from Chinese + English speech")
    out["steps"] = _steps(out)
    return out


def _steps(p: dict) -> list[str]:
    """The plan as the commands to run, in order."""
    s = [f"setup.py connect {c['preset']}" + (f" --region {c['region']}" if c["preset"] == "dashscope" else "")
         for c in p["connect"] if not c["connected"]]
    s += [f"setup.py download {d['model']} --wait" for d in p["download"]]
    s += [f"setup.py use {u['job']} {u['option']}" for u in p["use"]]
    s.append("setup.py verify")
    return s


def recommend(audio: str = "local", text: str = "cloud", budget: str = "paid", languages: list[str] | None = None,
              st: dict | None = None) -> dict:
    st = st or status()
    if not st.get("ok"):
        return st
    return plan(st, audio, text, budget, languages)


# ------------------------------------------------------------------ changes
def connect(preset: str, secret: dict, region: str | None = None) -> dict:
    """secret: {"key": …} or, for Volcengine Speech, {"app_id": …, "access_token": …}. Sent to the app once."""
    fields = {k: secret[k].strip() for k in ("key", "app_id", "access_token")
              if isinstance(secret.get(k), str) and secret[k].strip()}
    if not fields:
        return SetupError("no_key", "no key given: copy it, then pipe it in (pbpaste | setup.py connect …)").json()
    return request("connect", timeout=90, preset=preset, region=region, **fields)


def test(service: str) -> dict:
    return request("test", timeout=90, service=service)


def use(job: str, option: str, custom: bool = False) -> dict:
    return request("use", timeout=90, job=job, option=option, custom=bool(custom))


def download(model: str = "recommended", wait: bool = False, limit: float = 3600, every: float = 3) -> dict:
    r = request("download", timeout=120, model=model)
    if not r.get("ok") or not wait or not r.get("started"):
        return r
    want = set(r["started"])
    t0 = time.time()
    while time.time() - t0 < limit:
        time.sleep(every)
        st = request("status", timeout=60)
        if not st.get("ok"):
            return st
        if want & set(st.get("download_failed") or []):
            return {"ok": False, "code": "download_failed", "error": "the download stopped with an error; "
                    "Settings → Models shows why", "models": sorted(want)}
        if not want & {d["id"] for d in st.get("downloads") or []}:
            return {"ok": True, "installed": sorted(want), "seconds": int(time.time() - t0)}
    return {"ok": False, "code": "timeout", "error": "still downloading; run status to follow it", "models": sorted(want)}


def verify(language: str | None = None) -> dict:
    return request("verify", timeout=180, language=language)


# ------------------------------------------------------------------ CLI
def _read_secret(preset: str) -> dict:
    """The key from stdin (a pipe: the whole of it, or a JSON object), or typed without echo at a terminal."""
    pair = preset == "volcengine-speech"
    if sys.stdin.isatty():
        if pair:
            return {"app_id": input("App ID: ").strip(), "access_token": getpass.getpass("Access Token: ").strip()}
        return {"key": getpass.getpass("API key: ").strip()}
    raw = sys.stdin.read().strip()
    if raw.startswith("{"):
        try:
            o = json.loads(raw)
        except ValueError:
            raise SetupError("bad_request", "stdin looked like JSON but isn't") from None
        if not isinstance(o, dict):
            raise SetupError("bad_request", "stdin must be a JSON object")
        return {k: str(v) for k, v in o.items() if k in ("key", "app_id", "access_token") and v is not None}
    if pair:
        raise SetupError("bad_request", 'Volcengine Speech takes {"app_id": …, "access_token": …} on stdin')
    return {"key": raw}


def emit(o: dict) -> None:
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class _Parser(argparse.ArgumentParser):
    """Usage errors as one JSON line, without repeating what was typed (a key pasted as an argument stays unsaid)."""

    def error(self, message):
        said = message.split(":", 1)[0] if "unrecognized arguments" in message or "invalid choice" in message else message
        emit({"ok": False, "code": "bad_args", "error": f"{said} (see setup.py --help; a key goes on stdin, never as an "
                                                         "argument)"})
        sys.exit(2)


def main(argv: list[str] | None = None) -> int:
    ap = _Parser(prog="setup.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=_Parser)
    sub.add_parser("status")
    r = sub.add_parser("recommend")
    r.add_argument("--audio", choices=("local", "cloud"), default="local")
    r.add_argument("--text", choices=("local", "cloud"), default="cloud")
    r.add_argument("--budget", choices=("free", "paid"), default="paid")
    r.add_argument("--languages")
    c = sub.add_parser("connect")
    c.add_argument("preset")
    c.add_argument("--region", choices=("china", "global"))
    t = sub.add_parser("test")
    t.add_argument("service")
    u = sub.add_parser("use")
    u.add_argument("job", choices=("polish", "translate", "vision", "dictation"))
    u.add_argument("option")
    u.add_argument("--custom", action="store_true")
    d = sub.add_parser("download")
    d.add_argument("model", nargs="?", default="recommended")
    d.add_argument("--wait", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("--language")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "status":
            out = status()
        elif a.cmd == "recommend":
            langs = [x.strip() for x in a.languages.split(",") if x.strip()] if a.languages else None
            out = recommend(a.audio, a.text, a.budget, langs)
        elif a.cmd == "connect":
            out = connect(a.preset, _read_secret(a.preset), a.region)
        elif a.cmd == "test":
            out = test(a.service)
        elif a.cmd == "use":
            out = use(a.job, a.option, a.custom)
        elif a.cmd == "download":
            out = download(a.model, a.wait)
        else:
            out = verify(a.language)
    except SetupError as e:
        out = e.json()
    except KeyboardInterrupt:
        out = {"ok": False, "code": "interrupted", "error": "stopped"}
    emit(out)
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
