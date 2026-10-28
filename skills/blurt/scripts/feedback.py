# /// script
# requires-python = ">=3.10"
# ///
"""Feedback reports (docs/design/feedback.md): chosen dictations, what Blurt made of them and on what machine, packed
into one zip and sent to the Blurt developers. Nothing is sent without `send`, and only the takes named.

  feedback.py preview --ids A,B [--no-context] [--app-version V] [--app-build B]
        → {"ok", "takes": [{"id","t","app","duration","text","has_audio","has_context","bytes"}], "device", "models",
           "bytes" (the zip's size), "limit"}
  feedback.py send --ids A,B [--no-context] [--endpoint URL] [--app-version V] [--app-build B]
        → {"ok", "id", "bytes", "takes" (how many), "with_audio"}; each report sent is noted in
          $BLURT_HOME/feedback/sent.jsonl {"id","t","takes":[ids],"bytes"}

Errors ({"ok": false, "code"}): not_found (an id not in the history), too_large (over 100 000 000 bytes), network
(no answer), rate_limited (HTTP 429), server (any other HTTP error), usage.

The bundle: report.json, history.jsonl (the takes' lines as written, plus the edit lines naming them; "context"
dropped with --no-context), audio/<id>.wav (each kept recording; a take whose recording is gone goes as text only).
The endpoint: --endpoint, else $BLURT_FEEDBACK_URL, else https://blurt-feedback.agihunt.info.
"""
from __future__ import annotations

import argparse
import json
import locale
import os
import platform
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import IS_MAC, IS_WIN, _ram_gb, blurt_home, global_config, private_dir, use_system_certs  # noqa: E402

SCHEMA = 1
LIMIT = 100_000_000                 # the Worker refuses more (413); refused here first so nothing is uploaded for naught
ENDPOINT = "https://blurt-feedback.agihunt.info"
_SAFE_ID = re.compile(r"[A-Za-z0-9_.-]{1,128}")


class Fail(Exception):
    def __init__(self, message: str, code: str = "error"):
        super().__init__(message)
        self.code = code


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def dictation_dir() -> Path:
    return blurt_home() / "dictation"


# ------------------------------------------------------------------ the takes
def folded(ids: list[str]) -> list[dict]:
    """The chosen entries with their edits applied (dictation.py's reader), in the order asked; unknown → not_found."""
    import dictation  # noqa: PLC0415
    by_id = {e["id"]: e for e in dictation.load(dictation_dir() / "history.jsonl")}
    missing = [i for i in ids if i not in by_id]
    if missing:
        raise Fail(f"no dictation {', '.join(missing)}", "not_found")
    return [by_id[i] for i in ids]


def history_lines(ids: list[str], context: bool) -> list[str]:
    """history.jsonl's lines for these takes, as written: their entry lines and the edit lines naming them. A
    delete line naming other takes too keeps only these (the others are not the user's to send). Without context,
    a line that has it is written again without it."""
    want = set(ids)
    out = []
    try:
        lines = (dictation_dir() / "history.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for ln in lines:
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        if o.get("op") is not None:
            named = set(o.get("ids") or []) if isinstance(o.get("ids"), list) else set()
            if o.get("id") in want:
                pass
            elif named & want:
                if named - want:
                    o = {**o, "ids": [i for i in o["ids"] if i in want]}
                    ln = json.dumps(o, ensure_ascii=False, sort_keys=True)
            else:
                continue
        elif o.get("id") not in want:
            continue
        if not context and "context" in o:
            o = {k: v for k, v in o.items() if k != "context"}
            ln = json.dumps(o, ensure_ascii=False, sort_keys=True)
        out.append(ln)
    return out


def audio_file(e: dict) -> Path | None:
    """The take's kept recording, only from inside dictation/ (the path comes from a file), or None when gone."""
    a = e.get("audio")
    if not isinstance(a, str) or not a:
        return None
    base = dictation_dir().resolve()
    p = (base / a).resolve()
    if not p.is_relative_to(base) or not p.is_file():
        return None
    return p


def arc_id(e: dict, i: int) -> str:
    """The take's id as a name in the zip (ids are the app's own; anything odd gets its position instead)."""
    hid = str(e.get("id") or "")
    return hid if _SAFE_ID.fullmatch(hid) and not hid.startswith(".") else f"take-{i + 1}"


# ------------------------------------------------------------------ the machine and the settings
def _sh(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _locale() -> str | None:
    if IS_MAC:
        v = _sh(["defaults", "read", "-g", "AppleLocale"])
        if v:
            return v
    try:
        return locale.getlocale()[0] or os.environ.get("LANG") or None
    except ValueError:
        return os.environ.get("LANG") or None


def platform_name() -> str:
    return "macos" if IS_MAC else "windows" if IS_WIN else "linux"


def device() -> dict:
    d = {"os": platform.system(), "os_version": platform.version(), "arch": platform.machine().lower(), "model": None,
         "chip": None, "cores": os.cpu_count(), "memory_gb": _ram_gb(), "locale": _locale()}
    if IS_MAC:
        d["os"] = "macOS"
        d["os_version"] = _sh(["sw_vers", "-productVersion"]) or platform.mac_ver()[0]
        build = _sh(["sw_vers", "-buildVersion"])
        if build:
            d["os_build"] = build
        d["model"] = _sh(["sysctl", "-n", "hw.model"]) or None
        d["chip"] = _sh(["sysctl", "-n", "machdep.cpu.brand_string"]) or None
        if (n := _sh(["sysctl", "-n", "hw.ncpu"])).isdigit():
            d["cores"] = int(n)
        if (m := _sh(["sysctl", "-n", "hw.memsize"])).isdigit():
            d["memory_gb"] = round(int(m) / 2**30, 1)
    elif IS_WIN:
        d["os_version"] = platform.version()
        d["chip"] = platform.processor() or None
    else:
        try:
            d["model"] = Path("/sys/devices/virtual/dmi/id/product_name").read_text().strip() or None
        except OSError:
            pass
        try:
            d["chip"] = next((ln.split(":", 1)[1].strip() for ln in Path("/proc/cpuinfo").read_text().splitlines()
                              if ln.startswith("model name")), None)
        except OSError:
            pass
        d["os_version"] = platform.release()
    return d


_SECRET = re.compile(r"api_?key|token|secret|password", re.I)


def _no_secrets(v):
    # no setting there holds one today; a later one (a cloud model's key) must not ride along by accident
    if isinstance(v, dict):
        return {k: _no_secrets(x) for k, x in v.items() if not _SECRET.search(str(k))}
    if isinstance(v, list):
        return [_no_secrets(x) for x in v]
    return v


def dictation_settings() -> dict:
    d = (global_config().get("record") or {}).get("dictation") or {}
    return _no_secrets(d) if isinstance(d, dict) else {}


def models(settings: dict) -> dict:
    """What dictation is set to use: the configured models and what the registries (asr_models.json,
    polish_models.json) pick on this machine. Each take's history line names the models that really ran."""
    out = {"asr": None, "polish": None, "polish_on": settings.get("polish", "light") != "off",
           "asr_configured": settings.get("asr_model") or ((global_config().get("asr") or {}).get("models") or {}).get("dictation"),
           "polish_configured": settings.get("polish_model"), "polish_recommended": None}
    try:
        import transcribe  # noqa: PLC0415
        out["asr"] = transcribe.select("dictation")["id"]
    except Exception:  # noqa: BLE001 — a report goes out without it rather than not at all
        pass
    try:
        import polish  # noqa: PLC0415
        out["polish_recommended"] = polish.recommended()
        out["polish"] = (polish.selected() or out["polish_configured"] or out["polish_recommended"]) if out["polish_on"] else None
    except Exception:  # noqa: BLE001
        pass
    return out


def terms() -> list[dict]:
    try:
        import dictation_vocab  # noqa: PLC0415
        return [{k: t[k] for k in ("term", "sounds_like", "source")} for t in dictation_vocab.load()]
    except Exception:  # noqa: BLE001
        return []


# ------------------------------------------------------------------ the bundle
def build(ids: list[str], context: bool, out: Path, app_version: str, app_build: str) -> dict:
    """Writes the zip to `out`; → {"takes": [preview rows], "device", "models", "bytes", "with_audio"}."""
    entries = folded(ids)
    lines = history_lines(ids, context)
    settings = dictation_settings()
    dev, mods = device(), models(settings)
    takes, rows, with_audio = [], [], 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for i, e in enumerate(entries):
            wav = audio_file(e)
            name = f"audio/{arc_id(e, i)}.wav" if wav else None
            if wav:
                z.write(wav, name, compress_type=zipfile.ZIP_STORED)   # PCM barely deflates; stored keeps it quick
                with_audio += 1
            takes.append({"id": e["id"], "audio": name})
            own = [ln for ln in lines if e["id"] in ln]
            rows.append({"id": e["id"], "t": e.get("t"), "app": e.get("app"), "duration": e.get("duration"),
                         "text": (e.get("text") or "")[:80], "has_audio": bool(wav),
                         "has_context": bool(context and e.get("context")),
                         "bytes": (wav.stat().st_size if wav else 0) + sum(len(ln.encode()) + 1 for ln in own)})
        report = {"schema": SCHEMA, "created": now_iso(), "platform": platform_name(),
                  "app": {"version": app_version, "build": app_build}, "device": dev, "dictation": settings,
                  "models": mods, "terms": terms(), "context_included": context, "takes": takes}
        z.writestr("report.json", json.dumps(report, ensure_ascii=False, indent=2))
        z.writestr("history.jsonl", "".join(ln + "\n" for ln in lines))
    return {"takes": rows, "device": dev, "models": mods, "bytes": out.stat().st_size, "with_audio": with_audio}


def post(path: Path, endpoint: str, app_version: str, takes: int, timeout: float = 120) -> dict:
    use_system_certs()
    size = path.stat().st_size
    url = endpoint.rstrip("/") + "/v1/report"
    with open(path, "rb") as f:
        req = urllib.request.Request(url, data=f, method="POST", headers={
            "Content-Type": "application/zip", "Content-Length": str(size), "X-Blurt-Version": app_version,
            # the Worker keeps these as the object's metadata (report.json is at the zip's end: it never unpacks it)
            "X-Blurt-Platform": platform_name(), "X-Blurt-Takes": str(takes), "User-Agent": f"blurt/{app_version}"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                body = r.read()
        except urllib.error.HTTPError as e:
            code = {429: "rate_limited", 413: "too_large"}.get(e.code, "server")
            raise Fail(f"the feedback service answered HTTP {e.code}", code) from None
        except (urllib.error.URLError, OSError) as e:
            raise Fail(f"could not reach the feedback service: {getattr(e, 'reason', e)}", "network") from None
    try:
        o = json.loads(body)
    except ValueError:
        raise Fail("the feedback service's answer is not JSON", "server") from None
    if not (isinstance(o, dict) and o.get("ok") and isinstance(o.get("id"), str)):
        raise Fail("the feedback service did not return a report id", "server")
    return o


def record_sent(rid: str, ids: list[str], size: int) -> None:
    d = private_dir(blurt_home() / "feedback")
    with open(d / "sent.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps({"id": rid, "t": now_iso(), "takes": ids, "bytes": size}, ensure_ascii=False) + "\n")


# ------------------------------------------------------------------ commands
def parse_ids(s: str) -> list[str]:
    ids = list(dict.fromkeys(x.strip() for x in (s or "").split(",") if x.strip()))
    if not ids:
        raise Fail("--ids needs at least one dictation id", "usage")
    return ids


def cmd_preview(a) -> None:
    ids = parse_ids(a.ids)
    with tempfile.TemporaryDirectory(prefix="blurt-feedback-") as tmp:
        r = build(ids, not a.no_context, Path(tmp) / "report.zip", a.app_version, a.app_build)
    emit({"ok": True, "takes": r["takes"], "device": r["device"], "models": r["models"], "bytes": r["bytes"],
          "limit": LIMIT})


def cmd_send(a) -> None:
    ids = parse_ids(a.ids)
    endpoint = a.endpoint or os.environ.get("BLURT_FEEDBACK_URL") or ENDPOINT
    with tempfile.TemporaryDirectory(prefix="blurt-feedback-") as tmp:
        z = Path(tmp) / "report.zip"
        r = build(ids, not a.no_context, z, a.app_version, a.app_build)
        if r["bytes"] > LIMIT:
            raise Fail(f"the report is {r['bytes']} bytes, over the {LIMIT} limit: choose fewer dictations", "too_large")
        o = post(z, endpoint, a.app_version, len(ids))
    record_sent(o["id"], ids, r["bytes"])
    emit({"ok": True, "id": o["id"], "bytes": r["bytes"], "takes": len(ids), "with_audio": r["with_audio"]})


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="feedback.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("preview", "send"):
        s = sub.add_parser(name)
        s.add_argument("--ids", required=True, help="comma-separated dictation history ids")
        s.add_argument("--no-context", action="store_true", help="leave out the text around the cursor")
        s.add_argument("--app-version", default="unknown")
        s.add_argument("--app-build", default="unknown")
        if name == "send":
            s.add_argument("--endpoint")
    a = p.parse_args(argv)
    try:
        {"preview": cmd_preview, "send": cmd_send}[a.cmd](a)
    except Fail as e:
        emit({"ok": False, "error": str(e), "code": e.code})
        sys.exit(1)


if __name__ == "__main__":
    main()
