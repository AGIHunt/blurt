# /// script
# requires-python = ">=3.10"
# ///
"""Which coding-agent CLI processes a recording, in what order, and why one couldn't.

  agents.py status [--json]        each agent in the configured order: installed? logged in? the fix command
  agents.py order                  the configured order (config record.agents), one id per line
  agents.py classify FILE          a failed run's log (agent.log) → {"class": "auth|quota|network|model|skill|null", …}

The registry is agents.json next to this file (also bundled into Blurt.app, which implements the same rules in
Agents.swift). Config ($BLURT_HOME/config.json → record): agents = ["claude", "codex", …] (order; agents not listed are
not used), agent_defs = {"<id>": {…same fields as agents.json…}} to add or override one.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import global_config  # noqa: E402

REGISTRY = Path(__file__).with_name("agents.json")
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
ERRORISH = re.compile(r"error|fail|fatal|exception|denied|invalid|expired|unauthori|limit|not logged|quota|refused|"
                      r"not found|couldn't|could not|unable|错误|失败", re.I)


def registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def definitions(cfg: dict | None = None) -> dict[str, dict]:
    """id → definition, in registry order, with record.agent_defs merged in (new ids go last)."""
    rec = (cfg if cfg is not None else global_config()).get("record", {})
    defs = {d["id"]: d for d in registry()["agents"]}
    for k, v in (rec.get("agent_defs") or {}).items():
        if isinstance(v, dict):
            defs[k] = {**defs.get(k, {}), **v, "id": k}
            defs[k].setdefault("name", k)
            defs[k].setdefault("bins", [k])
    return defs


def agent_order(cfg: dict | None = None) -> list[str]:
    """The order agents are tried in. record.agents if set (unknown ids dropped, duplicates removed); otherwise the
    registry order, with a legacy record.process = "claude" | "codex" moved to the front."""
    cfg = cfg if cfg is not None else global_config()
    rec = cfg.get("record", {})
    defs = definitions(cfg)
    want = rec.get("agents")
    if isinstance(want, str):
        want = [w.strip() for w in want.split(",")]
    if isinstance(want, list) and any(isinstance(w, str) and w in defs for w in want):
        return list(dict.fromkeys(w for w in want if isinstance(w, str) and w in defs))
    order = list(defs)
    legacy = rec.get("process")
    if legacy in defs:
        order.remove(legacy)
        order.insert(0, legacy)
    return order


def parse_status(defn: dict, code: int | None, text: str, env: dict | None = None, home: Path | None = None) -> str:
    """"ready" (verified logged in) | "configured" (has credentials, can't verify) | "logged_out" | "unknown".
    code None = the status command didn't run / timed out."""
    st = defn.get("status") or {}
    low = (text or "").lower()
    key = st.get("json_key")
    if key and "{" in low:
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])
            if isinstance(obj, dict) and isinstance(obj.get(key), bool):
                return "ready" if obj[key] else "logged_out"
        except ValueError:
            pass
    if any(s in low for s in st.get("logged_out", [])):
        return "logged_out"
    if code == 0 and any(s in low for s in st.get("ok_if", [])):
        return "ready"
    if st.get("configured_if") and re.search(st["configured_if"], text or "", re.I):
        return "configured"
    env = os.environ if env is None else env
    if any(env.get(k) for k in st.get("env_any", [])):
        return "configured"
    home = home or Path.home()
    if any((home / f[2:] if f.startswith("~/") else Path(f)).exists() for f in st.get("files_any", [])):
        return "configured"
    if st.get("otherwise") == "logged_out" and (code is not None or "args" not in st):
        return "logged_out"
    return "unknown"


def usable(state: str) -> bool:
    return state in ("ready", "configured", "unknown")


def check(defn: dict, env: dict | None = None, lang: str = "en") -> dict:
    env = dict(os.environ) if env is None else env
    path = next((p for p in (shutil.which(b, path=env.get("PATH")) for b in defn.get("bins", [defn["id"]])) if p), None)
    out = {"id": defn["id"], "name": defn.get("name", defn["id"]), "path": path}
    if not path:
        out.update(state="not_installed", why=("没安装" if lang == "zh" else "not installed"),
                   fix=(defn.get("install") or {}).get(lang, ""))
        return out
    code, text = None, ""
    args = (defn.get("status") or {}).get("args")
    if args:
        try:
            p = subprocess.run([path, *args], capture_output=True, text=True, encoding="utf-8", errors="replace",
                               timeout=15, env=env, stdin=subprocess.DEVNULL)
            code, text = p.returncode, p.stdout + p.stderr
        except (OSError, subprocess.TimeoutExpired):
            pass
    state = parse_status(defn, code, text, env)
    why = {"ready": ("已登录", "logged in"), "configured": ("已配置（无法预先验证）", "configured (can't verify in advance)"),
           "logged_out": ("没登录", "not logged in"), "unknown": ("登录状态未知，会直接试", "login unknown, will try")}[state]
    out.update(state=state, why=why[0] if lang == "zh" else why[1],
               fix=(defn.get("fix") or {}).get(lang, "") if state == "logged_out" else "")
    return out


def _tail_lines(text: str, chars: int = 6000, lines: int = 80) -> str:
    return "\n".join(text[-chars:].splitlines()[-lines:])


def classify(text: str) -> str | None:
    """A failed run's output → the first failure class (agents.json order) found on an error-looking line of the tail,
    else anywhere in the tail. Only the tail: codex logs echo tool output, which can mention "429" or "quota"."""
    tail = _tail_lines(ANSI.sub("", text or ""))
    errorish = "\n".join(ln for ln in tail.splitlines() if ERRORISH.search(ln))
    classes = registry()["failures"]
    for scope in (errorish, tail):
        for c in classes:
            if any(re.search(p, scope, re.I | re.M) for p in c["patterns"]):
                return c["id"]
    return None


def failure_reason(cls: str | None, name: str, fix: str = "", lang: str = "en", code: int | None = None) -> str:
    for c in registry()["failures"]:
        if c["id"] == cls:
            return c["reason"][lang].replace("{name}", name).replace("{fix}", fix or "")
    if lang == "zh":
        return f"{name} 没整理完（退出码 {code}）" if code is not None else f"{name} 没整理完"
    return f"{name} didn't finish (exit {code})" if code is not None else f"{name} didn't finish"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status")
    s.add_argument("--json", action="store_true")
    s.add_argument("--lang", default="zh" if os.environ.get("LANG", "").startswith("zh") else "en")
    sub.add_parser("order")
    c = sub.add_parser("classify")
    c.add_argument("file")
    a = p.parse_args()
    if a.cmd == "order":
        print("\n".join(agent_order()))
    elif a.cmd == "classify":
        text = Path(a.file).read_text(encoding="utf-8", errors="replace")
        cls = classify(text)
        print(json.dumps({"class": cls, "reason": failure_reason(cls, "the agent")}, ensure_ascii=False))
    else:
        defs = definitions()
        rows = [check(defs[i], lang=a.lang) for i in agent_order()]
        if a.json:
            print(json.dumps(rows, ensure_ascii=False, indent=2))
        else:
            for r in rows:
                print(f"{'✓' if usable(r['state']) and r['state'] != 'not_installed' else '✗'} {r['name']:<12} {r['why']}"
                      + (f" — {r['fix']}" if r.get("fix") else ""))


if __name__ == "__main__":
    main()
